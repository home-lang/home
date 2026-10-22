//! Resolve an exported name to its actual declaration origins.
//!
//! Worklist states are (file, scope, name, export/local lookup, value visibility).
//! Visiting each state once terminates cycles without imposing a depth limit
//! or confusing two barrel paths to one declaration with two declarations.
//! This does not transfer TypeIds: all HIR/symbol inspection stays in its owner.

const std = @import("std");
const builtin = @import("builtin");
const hir = @import("hir");
const driver = @import("ts_driver");
const resolver_mod = @import("ts_resolver");
const program = @import("ts_program.zig");

pub const Origin = struct {
    // Borrowed from the caller's root path or the resolver's path storage.
    path: []const u8,
    position: u32,
    kind: enum { declaration, expression, namespace },
    generic_function: bool = false,
    call_only_function: bool = false,

    pub fn same(a: Origin, b: Origin) bool {
        return a.position == b.position and a.kind == b.kind and std.mem.eql(u8, a.path, b.path);
    }
};

pub const Origins = struct {
    value: ?Origin = null,
    /// Value-symbol identity retained through an `import/export type` path.
    /// It remains available to `typeof`, but is not a runtime value export.
    type_only_value: ?Origin = null,
    type: ?Origin = null,
    namespace: ?Origin = null,
    restriction: ?Restriction = null,
    ambiguous: bool = false,
    complete: bool = true,

    fn include(self: *Origins, comptime space: []const u8, origin: Origin) void {
        if (comptime std.mem.eql(u8, space, "value") or std.mem.eql(u8, space, "type_only_value")) {
            const other = if (comptime std.mem.eql(u8, space, "value")) self.type_only_value else self.value;
            if (other) |previous| {
                if (!previous.same(origin)) self.ambiguous = true;
            }
        }
        if (@field(self, space)) |previous| {
            if (!previous.same(origin)) self.ambiguous = true;
        } else @field(self, space) = origin;
    }

    /// Equality is proven by real overlapping meanings, not name spelling.
    /// A type-only path may omit a value meaning of the same declaration.
    pub fn sameDeclaration(a: Origins, b: Origins) bool {
        if (!a.complete or !b.complete or a.ambiguous or b.ambiguous) return false;
        var overlap = false;
        inline for (.{ "value", "type", "namespace" }) |space| {
            const a_origin = if (comptime std.mem.eql(u8, space, "value")) a.value orelse a.type_only_value else @field(a, space);
            const b_origin = if (comptime std.mem.eql(u8, space, "value")) b.value orelse b.type_only_value else @field(b, space);
            if (a_origin) |left| {
                if (b_origin) |right| {
                    if (!left.same(right)) return false;
                    overlap = true;
                }
            }
        }
        return overlap;
    }
};

pub const Restriction = struct {
    path: []const u8,
    position: u32,
    kind: enum { import_type, export_type },
};

const State = struct {
    path: []const u8,
    scope: hir.NodeId = 0,
    name: []const u8,
    local: bool = false,
    values: bool = true,
    restriction: ?Restriction = null,
};

fn restrictionFor(state: State, type_only: bool, kind: @FieldType(Restriction, "kind"), position: u32) ?Restriction {
    return state.restriction orelse if (type_only)
        Restriction{ .path = state.path, .position = position, .kind = kind }
    else
        null;
}

const StateContext = struct {
    pub fn hash(_: StateContext, state: State) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(state.path);
        h.update(&.{0});
        h.update(state.name);
        h.update(std.mem.asBytes(&state.scope));
        h.update(&.{ @intFromBool(state.local), @intFromBool(state.values) });
        return h.final();
    }

    pub fn eql(_: StateContext, a: State, b: State) bool {
        return a.scope == b.scope and a.local == b.local and a.values == b.values and
            std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.name, b.name);
    }
};

const Entry = struct { compilation: *driver.Compilation, owned: bool };

const ImportEdge = struct {
    node: hir.NodeId,
    specifier: hir.NodeId = 0,
    kind: enum { default, namespace, named },
};
const ExportEdge = struct {
    node: hir.NodeId,
    specifier: hir.NodeId = 0,
    order: usize,
    kind: enum { named, namespace, default, local, implicit },

    fn lessThan(c: *const driver.Compilation, a: ExportEdge, b: ExportEdge) bool {
        if (a.order != b.order) return a.order < b.order;
        if (a.kind != b.kind) return @backingInt(a.kind) < @backingInt(b.kind);
        return c.hir.spanOf(a.specifier).start < c.hir.spanOf(b.specifier).start;
    }
};
const SourceIndex = struct {
    imports: std.AutoHashMapUnmanaged(hir.StringId, ImportEdge) = .empty,
    exports: std.AutoHashMapUnmanaged(hir.StringId, std.ArrayListUnmanaged(ExportEdge)) = .empty,
    defaults: std.ArrayListUnmanaged(ExportEdge) = .empty,
    stars: std.ArrayListUnmanaged(hir.NodeId) = .empty,
    unknown_exports: bool = false,

    fn addImport(self: *SourceIndex, arena: std.mem.Allocator, name: hir.StringId, edge: ImportEdge) !void {
        // Match the existing source-order lookup even for invalid duplicate
        // imports. Import diagnostics remain the checker's responsibility.
        const entry = try self.imports.getOrPut(arena, name);
        if (!entry.found_existing) entry.value_ptr.* = edge;
    }

    fn addExport(self: *SourceIndex, arena: std.mem.Allocator, c: *const driver.Compilation, name: hir.StringId, edge: ExportEdge) !void {
        if (std.mem.eql(u8, c.interner.get(name), "default")) return self.defaults.append(arena, edge);
        const entry = try self.exports.getOrPut(arena, name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, edge);
    }
};

const ScopedOwner = struct { path: []const u8, node: hir.NodeId, default_visible: bool = true };
const IndexKey = struct { owner: *const driver.Compilation, scope: hir.NodeId };

pub const Query = struct {
    pub const SourceFilter = struct {
        context: *const anyopaque,
        allows: *const fn (*const anyopaque, []const u8) bool,
    };
    /// A compiler host may resolve physical paths that are outside its
    /// current Program. Apply admission before consulting cached owners too.
    source_filter: ?SourceFilter = null,
    gpa: std.mem.Allocator,
    resolver: *resolver_mod.Resolver,
    files: std.StringHashMapUnmanaged(Entry) = .empty,
    index_arena: std.heap.ArenaAllocator,
    indexes: std.AutoHashMapUnmanaged(IndexKey, *const SourceIndex) = .empty,
    ambient_indexed: std.AutoHashMapUnmanaged(*const driver.Compilation, void) = .empty,
    ambient_modules: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(ScopedOwner)) = .empty,
    pending: std.ArrayListUnmanaged(State) = .empty,
    visited: std.HashMapUnmanaged(State, void, StateContext, 80) = .empty,
    result: Origins = .{},
    // Algorithmic regression accounting only; absent from production builds.
    stats: if (builtin.is_test) struct { source_statements: usize = 0 } else struct {} = .{},

    pub fn init(gpa: std.mem.Allocator, resolver: *resolver_mod.Resolver) Query {
        return .{ .gpa = gpa, .resolver = resolver, .index_arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Query) void {
        self.indexes.deinit(self.gpa);
        self.ambient_indexed.deinit(self.gpa);
        self.ambient_modules.deinit(self.gpa);
        self.index_arena.deinit();
        self.pending.deinit(self.gpa);
        self.visited.deinit(self.gpa);
        var entries = self.files.valueIterator();
        while (entries.next()) |entry| {
            if (!entry.owned) continue;
            const source = entry.compilation.source;
            entry.compilation.deinit();
            self.gpa.destroy(entry.compilation);
            self.gpa.free(source);
        }
        self.files.deinit(self.gpa);
    }

    pub fn borrow(self: *Query, path: []const u8, source: *driver.Compilation) !void {
        std.debug.assert(!self.files.contains(path));
        try self.files.put(self.gpa, path, .{ .compilation = source, .owned = false });
    }

    fn sourceAllowed(self: *const Query, path: []const u8) bool {
        const filter = self.source_filter orelse return true;
        return filter.allows(filter.context, path);
    }

    /// Retain an immutable bound owner for export facts as well as origin
    /// traversal. Repeated queries must inspect this same source identity.
    pub fn compilation(self: *Query, path: []const u8) !?*driver.Compilation {
        if (!self.sourceAllowed(path)) return null;
        if (self.files.get(path)) |entry| return entry.compilation;
        const source = self.resolver.fs.readFile(self.gpa, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        errdefer self.gpa.free(source);
        const c = try program.compileModuleForExportFacts(self.gpa, path, source);
        errdefer {
            c.deinit();
            self.gpa.destroy(c);
        }
        try self.files.put(self.gpa, path, .{ .compilation = c, .owned = true });
        return c;
    }

    fn statements(c: *const driver.Compilation, scope: hir.NodeId) []const hir.NodeId {
        return if (scope == 0) hir.blockStmts(&c.hir, c.root) else hir.namespaceBody(&c.hir, scope);
    }

    fn boundScope(c: *const driver.Compilation, scope: hir.NodeId) ?*const @import("binder").Scope {
        if (scope == 0) return c.module.root;
        for (c.module.scopes.items) |candidate| if (candidate.introducing_node == scope) return candidate;
        return null;
    }

    fn indexAmbientModules(self: *Query) !void {
        const arena = self.index_arena.allocator();
        var files = self.files.iterator();
        while (files.next()) |entry| {
            if (!self.sourceAllowed(entry.key_ptr.*)) continue;
            const c = entry.value_ptr.compilation;
            if (self.ambient_indexed.contains(c)) continue;
            if (c.hir.kindOf(c.root) != .block_stmt) continue;
            const body = hir.blockStmts(&c.hir, c.root);
            const external = program.Program.boundSourceIsExternalModule(c);
            if (!external) for (body) |node| {
                if (c.hir.kindOf(node) != .namespace_decl) continue;
                const module_decl = hir.namespaceOf(&c.hir, node);
                if (module_decl.name == 0) continue;
                const span = c.hir.spanOf(module_decl.name);
                if (span.start >= c.source.len or (c.source[span.start] != '"' and c.source[span.start] != '\'')) continue;
                const name = switch (c.hir.kindOf(module_decl.name)) {
                    .identifier => c.interner.get(hir.identifierOf(&c.hir, module_decl.name).name),
                    .literal_string => c.interner.get(hir.literalStringOf(&c.hir, module_decl.name).value),
                    else => continue,
                };
                const modules = try self.ambient_modules.getOrPut(self.gpa, name);
                if (!modules.found_existing) modules.value_ptr.* = .empty;
                // Allocation failure must not leave a duplicate on retry.
                var present = false;
                for (modules.value_ptr.items) |owner| if (owner.node == node and std.mem.eql(u8, owner.path, entry.key_ptr.*)) {
                    present = true;
                    break;
                };
                if (!present) try modules.value_ptr.append(arena, .{ .path = entry.key_ptr.*, .node = node });
            };
            try self.ambient_indexed.put(self.gpa, c, {});
        }
    }

    pub fn hasAmbientModule(self: *Query, name: []const u8) !bool {
        try self.indexAmbientModules();
        const owners = self.ambient_modules.get(name) orelse return false;
        for (owners.items) |owner| if (self.sourceAllowed(owner.path)) return true;
        return false;
    }

    fn enqueueModule(self: *Query, specifier: []const u8, from: []const u8, state: State) !void {
        if (try self.hasAmbientModule(specifier)) {
            const owners = self.ambient_modules.get(specifier).?;
            for (owners.items) |owner| {
                if (!self.sourceAllowed(owner.path)) continue;
                var next = state;
                next.path = owner.path;
                next.scope = owner.node;
                try self.enqueue(next);
            }
        } else if (try self.target(specifier, from)) |path| {
            var next = state;
            next.path = path;
            next.scope = 0;
            try self.enqueue(next);
        }
    }

    fn moduleNamespace(self: *Query, specifier: []const u8, from: []const u8, values: bool, restriction: ?Restriction) !void {
        if (try self.hasAmbientModule(specifier)) {
            const owners = self.ambient_modules.get(specifier).?;
            for (owners.items) |owner| {
                if (!self.sourceAllowed(owner.path)) continue;
                // All declaration fragments contribute to one ambient module
                // namespace. Their distinct source positions are not distinct
                // competing exports of `export * as name from "module"`.
                self.namespace(owner.path, owner.node, values, restriction);
                return;
            }
            self.result.complete = false;
        } else if (try self.target(specifier, from)) |path| self.namespace(path, 0, values, restriction);
    }

    fn enqueue(self: *Query, state: State) !void {
        const entry = try self.visited.getOrPut(self.gpa, state);
        if (!entry.found_existing) try self.pending.append(self.gpa, state);
    }

    /// Snapshot the prepared owner's selected scope bindings. The index contains
    /// unresolved edges, not cached answers: every query still traverses all
    /// relevant alias/star paths with its own visibility and cycle state.
    fn index(self: *Query, c: *const driver.Compilation, scope: hir.NodeId) !*const SourceIndex {
        const key: IndexKey = .{ .owner = c, .scope = scope };
        if (self.indexes.get(key)) |existing| return existing;
        const arena = self.index_arena.allocator();
        const result = try arena.create(SourceIndex);
        result.* = .{};
        var declarations: std.AutoHashMapUnmanaged(hir.NodeId, ExportEdge) = .empty;
        const body = statements(c, scope);
        var implicit = scope != 0 and (c.is_declaration_file or hir.namespaceOf(&c.hir, scope).is_ambient);
        for (body) |node| if (c.hir.kindOf(node) == .export_decl) {
            const export_info = hir.exportOf(&c.hir, node);
            if (export_info.decl == 0 or export_info.is_export_equals) implicit = false;
        };
        for (body, 0..) |node, order| {
            if (builtin.is_test) self.stats.source_statements += 1;
            if (c.hir.kindOf(node) == .import_decl) {
                const import = hir.importOf(&c.hir, node);
                if (c.interner.get(import.module).len == 0) continue;
                if (import.default_binding != 0 and c.hir.kindOf(import.default_binding) == .identifier)
                    try result.addImport(arena, hir.identifierOf(&c.hir, import.default_binding).name, .{ .node = node, .kind = .default });
                if (import.namespace_binding != 0 and c.hir.kindOf(import.namespace_binding) == .identifier)
                    try result.addImport(arena, hir.identifierOf(&c.hir, import.namespace_binding).name, .{ .node = node, .kind = .namespace });
                for (hir.importNamed(&c.hir, node)) |specifier| {
                    if (c.hir.kindOf(specifier) != .import_specifier) continue;
                    try result.addImport(arena, hir.importSpecifierOf(&c.hir, specifier).local, .{ .node = node, .specifier = specifier, .kind = .named });
                }
                continue;
            }
            if (c.hir.kindOf(node) != .export_decl) {
                if (implicit) try declarations.put(arena, node, .{ .node = node, .order = order, .kind = .implicit });
                continue;
            }
            const ex = hir.exportOf(&c.hir, node);
            if (ex.is_export_equals) result.unknown_exports = true;
            for (hir.exportNamed(&c.hir, node)) |specifier| {
                if (c.hir.kindOf(specifier) != .import_specifier) continue;
                try result.addExport(arena, c, hir.importSpecifierOf(&c.hir, specifier).local, .{ .node = node, .specifier = specifier, .order = order, .kind = .named });
            }
            if (c.interner.get(ex.module).len != 0) {
                if (c.interner.get(ex.namespace_alias).len != 0)
                    try result.addExport(arena, c, ex.namespace_alias, .{ .node = node, .order = order, .kind = .namespace })
                else if (ex.is_namespace)
                    try result.stars.append(arena, node);
            }
            if (ex.decl == 0 or ex.is_export_equals) continue;
            if (ex.is_default) {
                try result.defaults.append(arena, .{ .node = node, .order = order, .kind = .default });
            } else {
                try declarations.put(arena, ex.decl, .{ .node = node, .order = order, .kind = .local });
            }
        }
        // Associate real root symbols with their exported declaration owners.
        // This handles destructured/comma declarations and merged symbols
        // without comparing each symbol against every export statement.
        inline for (.{ "values", "types", "namespaces" }) |field| {
            var symbols = @field(boundScope(c, scope).?, field).iterator();
            while (symbols.next()) |entry| {
                for (entry.value_ptr.*.decls.items) |decl| {
                    var current = decl;
                    while (current != 0 and current != (if (scope == 0) c.root else scope)) : (current = c.hir.parentOf(current)) {
                        if (declarations.get(current)) |edge| try result.addExport(arena, c, entry.key_ptr.*, edge);
                    }
                }
            }
        }
        // Local declaration edges came from the symbol maps; restore lexical
        // order so first-origin and type-only diagnostic provenance stay stable.
        var exports = result.exports.valueIterator();
        while (exports.next()) |edges| std.mem.sort(ExportEdge, edges.items, c, ExportEdge.lessThan);
        std.mem.sort(ExportEdge, result.defaults.items, c, ExportEdge.lessThan);
        try self.indexes.put(self.gpa, key, result);
        return result;
    }

    fn target(self: *Query, specifier: []const u8, from: []const u8) !?[]const u8 {
        const resolved = self.resolver.resolve(specifier, from) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.result.complete = false;
                return null;
            },
        };
        if (!self.sourceAllowed(resolved.path)) {
            self.result.complete = false;
            return null;
        }
        return resolved.path;
    }

    /// Query-local traversal state is reset between names; bound source
    /// storage can be reused until the Query is destroyed. Results contain
    /// no pointers into that temporary HIR, symbol or string storage.
    /// Explicit aliases remain declared exports when their target is unknown.
    /// An unresolved export-star does not declare arbitrary named symbols.
    pub fn hasExplicitExport(self: *Query, path: []const u8, name: []const u8) !bool {
        const c = try self.compilation(path) orelse return false;
        if (c.hir.kindOf(c.root) != .block_stmt) return false;
        const source_index = try self.index(c, 0);
        if (std.mem.eql(u8, name, "default")) return source_index.defaults.items.len != 0;
        const id = c.interner.lookup(name) orelse return false;
        return source_index.exports.contains(id);
    }

    pub fn resolve(self: *Query, path: []const u8, name: []const u8) !Origins {
        self.pending.clearRetainingCapacity();
        self.visited.clearRetainingCapacity();
        self.result = .{};
        try self.enqueue(.{ .path = path, .name = name });
        return self.finish();
    }

    pub fn resolveModule(self: *Query, specifier: []const u8, from: []const u8, name: []const u8) !Origins {
        self.pending.clearRetainingCapacity();
        self.visited.clearRetainingCapacity();
        self.result = .{};
        try self.enqueueModule(specifier, from, .{ .path = from, .name = name });
        return self.finish();
    }

    pub fn resolveInNamespace(self: *Query, path: []const u8, scope: hir.NodeId, name: []const u8) !Origins {
        self.pending.clearRetainingCapacity();
        self.visited.clearRetainingCapacity();
        self.result = .{};
        try self.enqueue(.{ .path = path, .scope = scope, .name = name });
        return self.finish();
    }

    pub const ExportNames = struct { names: []const []const u8, complete: bool };
    const ScopeContext = struct {
        pub fn hash(_: ScopeContext, owner: ScopedOwner) u64 {
            return std.hash.Wyhash.hash(@as(u64, owner.node) * 2 + @intFromBool(owner.default_visible), owner.path);
        }
        pub fn eql(_: ScopeContext, left: ScopedOwner, right: ScopedOwner) bool {
            return left.node == right.node and left.default_visible == right.default_visible and std.mem.eql(u8, left.path, right.path);
        }
    };

    fn appendModuleScopes(self: *Query, pending: *std.ArrayListUnmanaged(ScopedOwner), specifier: []const u8, from: []const u8) !bool {
        if (try self.hasAmbientModule(specifier)) {
            const owners = self.ambient_modules.get(specifier).?;
            for (owners.items) |owner| {
                if (self.sourceAllowed(owner.path)) try pending.append(self.gpa, owner);
            }
            return true;
        }
        if (try self.target(specifier, from)) |path| {
            try pending.append(self.gpa, .{ .path = path, .node = 0 });
            return true;
        }
        return false;
    }

    pub fn exportNamesForModule(self: *Query, specifier: []const u8, from: []const u8) !ExportNames {
        var pending: std.ArrayListUnmanaged(ScopedOwner) = .empty;
        defer pending.deinit(self.gpa);
        const found = try self.appendModuleScopes(&pending, specifier, from);
        return self.exportNames(&pending, found);
    }

    pub fn exportNamesInNamespace(self: *Query, path: []const u8, scope: hir.NodeId) !ExportNames {
        var pending: std.ArrayListUnmanaged(ScopedOwner) = .empty;
        defer pending.deinit(self.gpa);
        try pending.append(self.gpa, .{ .path = path, .node = scope });
        return self.exportNames(&pending, true);
    }

    fn exportNames(self: *Query, pending: *std.ArrayListUnmanaged(ScopedOwner), initially_complete: bool) !ExportNames {
        var complete = initially_complete;
        var visited: std.HashMapUnmanaged(ScopedOwner, void, ScopeContext, 80) = .empty;
        defer visited.deinit(self.gpa);
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(self.gpa);
        var cursor: usize = 0;
        while (cursor < pending.items.len) : (cursor += 1) {
            const owner = pending.items[cursor];
            const previous = try visited.getOrPut(self.gpa, owner);
            if (previous.found_existing) continue;
            const c = try self.compilation(owner.path) orelse {
                complete = false;
                continue;
            };
            if (c.hir.kindOf(c.root) != .block_stmt) {
                complete = false;
                continue;
            }
            const bindings = try self.index(c, owner.node);
            if (bindings.unknown_exports or c.has_syntactic_parse_diagnostics) complete = false;
            var exported_names = bindings.exports.keyIterator();
            while (exported_names.next()) |name| {
                const text = c.interner.get(name.*);
                if (!owner.default_visible and std.mem.eql(u8, text, "default")) continue;
                try names.put(self.gpa, text, {});
            }
            if (owner.default_visible and bindings.defaults.items.len != 0) try names.put(self.gpa, "default", {});
            for (bindings.stars.items) |node| {
                const export_info = hir.exportOf(&c.hir, node);
                const first = pending.items.len;
                if (!try self.appendModuleScopes(pending, c.interner.get(export_info.module), owner.path)) complete = false;
                for (pending.items[first..]) |*target_owner| target_owner.default_visible = false;
            }
        }
        const arena = self.index_arena.allocator();
        const result = try arena.alloc([]const u8, names.count());
        var iterator = names.keyIterator();
        var output_index: usize = 0;
        while (iterator.next()) |name| : (output_index += 1) result[output_index] = name.*;
        std.mem.sort([]const u8, result, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.less);
        return .{ .names = result, .complete = complete };
    }

    fn finish(self: *Query) !Origins {
        var cursor: usize = 0;
        while (cursor < self.pending.items.len) : (cursor += 1) {
            const state = self.pending.items[cursor];
            const c = try self.compilation(state.path) orelse {
                self.result.complete = false;
                continue;
            };
            // Syntax diagnostics do not invalidate the recovered export
            // table. TypeScript still binds declarations around malformed
            // statements, so traverse the HIR and let real recovered
            // conflicts mark the query ambiguous. Only a missing root makes
            // the export graph unknowable.
            if (c.hir.kindOf(c.root) != .block_stmt) {
                self.result.complete = false;
                continue;
            }
            if (state.local) try self.local(c, state) else try self.exported(c, state);
        }
        return self.result;
    }

    fn namespace(self: *Query, path: []const u8, scope: hir.NodeId, values: bool, restriction: ?Restriction) void {
        if (!self.sourceAllowed(path)) {
            self.result.complete = false;
            return;
        }
        const origin: Origin = .{ .path = path, .position = if (scope == 0) 0 else self.files.get(path).?.compilation.hir.spanOf(scope).start, .kind = if (scope == 0) .namespace else .declaration };
        self.result.include("namespace", origin);
        if (values) self.result.include("value", origin) else self.result.include("type_only_value", origin);
        if (self.result.restriction == null) self.result.restriction = restriction;
    }

    fn local(self: *Query, c: *const driver.Compilation, state: State) !void {
        const name = c.interner.lookup(state.name) orelse {
            self.result.complete = false;
            return;
        };
        const bindings = try self.index(c, state.scope);
        if (bindings.imports.get(name)) |edge| {
            const import = hir.importOf(&c.hir, edge.node);
            const specifier = c.interner.get(import.module);
            if (edge.kind == .default and import.is_require_equals) {
                self.result.complete = false;
                return;
            }
            switch (edge.kind) {
                .default => try self.enqueueModule(specifier, state.path, .{
                    .path = state.path,
                    .name = "default",
                    .values = state.values and !import.is_type_only,
                    .restriction = restrictionFor(state, import.is_type_only, .import_type, c.hir.spanOf(edge.node).start),
                }),
                .namespace => try self.moduleNamespace(specifier, state.path, state.values and !import.is_type_only, restrictionFor(state, import.is_type_only, .import_type, c.hir.spanOf(edge.node).start)),
                .named => {
                    const spec = hir.importSpecifierOf(&c.hir, edge.specifier);
                    try self.enqueueModule(specifier, state.path, .{
                        .path = state.path,
                        .name = c.interner.get(spec.imported),
                        .values = state.values and !import.is_type_only and !spec.is_type_only,
                        .restriction = restrictionFor(state, import.is_type_only or spec.is_type_only, .import_type, c.hir.spanOf(edge.specifier).start),
                    });
                },
            }
            return;
        }
        var found_local = false;
        inline for (.{ .{ "values", "value" }, .{ "types", "type" }, .{ "namespaces", "namespace" } }) |fields| {
            if (@field(boundScope(c, state.scope).?, fields[0]).get(name)) |symbol| resolved_symbol: {
                if (symbol.flags.is_import or symbol.decls.items.len == 0) break :resolved_symbol;
                found_local = true;
                var origin: Origin = .{
                    .path = state.path,
                    .position = c.hir.spanOf(symbol.decls.items[0]).start,
                    .kind = .declaration,
                    .call_only_function = symbol.flags.is_function and !symbol.flags.is_class,
                };
                for (symbol.decls.items) |decl| {
                    if (c.hir.kindOf(decl) == .fn_decl and hir.fnTypeParams(&c.hir, decl).len > 0)
                        origin.generic_function = true;
                }
                if (std.mem.eql(u8, fields[1], "value") and !state.values)
                    self.result.include("type_only_value", origin)
                else
                    self.result.include(fields[1], origin);
                if (self.result.restriction == null) self.result.restriction = state.restriction;
            }
        }
        // A declared alias can target a global or an invalid/recovered name.
        // Failure to resolve that target is not proof the export is absent.
        if (!found_local) self.result.complete = false;
    }

    const FirstAmbientOwner = struct {
        state: ?State = null,
        complete: bool = true,
    };

    /// Walk one ambient star path in source order to the first declaration
    /// that actually exports `state.name`. Keeping the current recursion path
    /// (rather than a global visited set) lets a later edge escape a cycle.
    fn firstAmbientStarOwner(
        self: *Query,
        specifier: []const u8,
        from: []const u8,
        state: State,
        visiting: *std.HashMapUnmanaged(ScopedOwner, void, ScopeContext, 80),
    ) !FirstAmbientOwner {
        var owners: std.ArrayListUnmanaged(ScopedOwner) = .empty;
        defer owners.deinit(self.gpa);
        if (!try self.appendModuleScopes(&owners, specifier, from)) return .{ .complete = false };
        for (owners.items) |owner| {
            const seen = try visiting.getOrPut(self.gpa, owner);
            if (seen.found_existing) continue;
            const c = try self.compilation(owner.path) orelse {
                _ = visiting.remove(owner);
                return .{ .complete = false };
            };
            if (c.hir.kindOf(c.root) != .block_stmt or c.has_syntactic_parse_diagnostics) {
                _ = visiting.remove(owner);
                return .{ .complete = false };
            }
            const bindings = try self.index(c, owner.node);
            if (bindings.unknown_exports) {
                _ = visiting.remove(owner);
                return .{ .complete = false };
            }
            if (c.interner.lookup(state.name)) |name| {
                if (bindings.exports.contains(name)) {
                    _ = visiting.remove(owner);
                    var direct = state;
                    direct.path = owner.path;
                    direct.scope = owner.node;
                    return .{ .state = direct };
                }
            }
            for (bindings.stars.items) |node| {
                const export_info = hir.exportOf(&c.hir, node);
                var next = state;
                next.values = state.values and !export_info.is_type_only;
                next.restriction = restrictionFor(state, export_info.is_type_only, .export_type, c.hir.spanOf(node).start);
                const found = try self.firstAmbientStarOwner(c.interner.get(export_info.module), owner.path, next, visiting);
                if (found.state != null or !found.complete) {
                    _ = visiting.remove(owner);
                    return found;
                }
            }
            _ = visiting.remove(owner);
        }
        return .{};
    }

    fn exported(self: *Query, c: *const driver.Compilation, state: State) !void {
        const bindings = try self.index(c, state.scope);
        const wanted = c.interner.lookup(state.name);
        const is_default = std.mem.eql(u8, state.name, "default");
        const edges = if (is_default)
            bindings.defaults.items
        else if (wanted) |name|
            if (bindings.exports.get(name)) |found| found.items else &.{}
        else
            &.{};
        for (edges) |edge| {
            if (edge.kind == .implicit) {
                try self.enqueue(.{ .path = state.path, .scope = state.scope, .name = state.name, .local = true, .values = state.values, .restriction = state.restriction });
                continue;
            }
            const export_info = hir.exportOf(&c.hir, edge.node);
            const specifier = c.interner.get(export_info.module);
            switch (edge.kind) {
                .named => {
                    const spec = hir.importSpecifierOf(&c.hir, edge.specifier);
                    const next: State = .{
                        .path = state.path,
                        .scope = state.scope,
                        .name = c.interner.get(spec.imported),
                        .local = specifier.len == 0,
                        .values = state.values and !export_info.is_type_only and !spec.is_type_only,
                        .restriction = restrictionFor(state, export_info.is_type_only or spec.is_type_only, .export_type, c.hir.spanOf(edge.specifier).start),
                    };
                    if (specifier.len > 0) try self.enqueueModule(specifier, state.path, next) else try self.enqueue(next);
                },
                .namespace => {
                    try self.moduleNamespace(specifier, state.path, state.values and !export_info.is_type_only, restrictionFor(state, export_info.is_type_only, .export_type, c.hir.spanOf(edge.node).start));
                },
                .default => {
                    const kind = c.hir.kindOf(export_info.decl);
                    const declared_name = switch (kind) {
                        .fn_decl, .fn_expr => hir.fnDeclOf(&c.hir, export_info.decl).name,
                        .class_decl, .class_expr => hir.classOf(&c.hir, export_info.decl).name,
                        .interface_decl => hir.interfaceOf(&c.hir, export_info.decl).name,
                        else => hir.none_node_id,
                    };
                    if (declared_name != 0 and c.hir.kindOf(declared_name) == .identifier) {
                        try self.enqueue(.{
                            .path = state.path,
                            .scope = state.scope,
                            .name = c.interner.get(hir.identifierOf(&c.hir, declared_name).name),
                            .local = true,
                            .values = state.values,
                            .restriction = state.restriction,
                        });
                        continue;
                    }
                    if (kind == .identifier) {
                        try self.enqueue(.{
                            .path = state.path,
                            .scope = state.scope,
                            .name = c.interner.get(hir.identifierOf(&c.hir, export_info.decl).name),
                            .local = true,
                            .values = state.values,
                            .restriction = state.restriction,
                        });
                    } else {
                        const origin: Origin = .{ .path = state.path, .position = c.hir.spanOf(export_info.decl).start, .kind = .expression };
                        if (kind == .class_decl or kind == .class_expr or kind == .interface_decl)
                            self.result.include("type", origin);
                        if (kind != .interface_decl) {
                            if (state.values) self.result.include("value", origin) else self.result.include("type_only_value", origin);
                        }
                        if (self.result.restriction == null) self.result.restriction = state.restriction;
                    }
                },
                .implicit => unreachable,
                .local => try self.enqueue(.{ .path = state.path, .scope = state.scope, .name = state.name, .local = true, .values = state.values, .restriction = state.restriction }),
            }
        }
        if (edges.len != 0 or is_default) return;
        const ambient_module_stars = blk: {
            if (state.scope == 0 or c.hir.kindOf(state.scope) != .namespace_decl) break :blk false;
            const name_node = hir.namespaceOf(&c.hir, state.scope).name;
            if (name_node == hir.none_node_id) break :blk false;
            const span = c.hir.spanOf(name_node);
            break :blk span.start < c.source.len and (c.source[span.start] == '"' or c.source[span.start] == '\'');
        };
        if (ambient_module_stars) {
            var visiting: std.HashMapUnmanaged(ScopedOwner, void, ScopeContext, 80) = .empty;
            defer visiting.deinit(self.gpa);
            try visiting.put(self.gpa, .{ .path = state.path, .node = state.scope }, {});
            for (bindings.stars.items) |node| {
                const export_info = hir.exportOf(&c.hir, node);
                var next = state;
                next.values = state.values and !export_info.is_type_only;
                next.restriction = restrictionFor(state, export_info.is_type_only, .export_type, c.hir.spanOf(node).start);
                const found = try self.firstAmbientStarOwner(c.interner.get(export_info.module), state.path, next, &visiting);
                if (!found.complete) {
                    self.result.complete = false;
                    return;
                }
                if (found.state) |owner| {
                    try self.enqueue(owner);
                    return;
                }
            }
            return;
        }
        for (bindings.stars.items) |node| {
            const export_info = hir.exportOf(&c.hir, node);
            const specifier = c.interner.get(export_info.module);
            try self.enqueueModule(specifier, state.path, .{
                .path = state.path,
                .name = state.name,
                .values = state.values and !export_info.is_type_only,
                .restriction = restrictionFor(state, export_info.is_type_only, .export_type, c.hir.spanOf(node).start),
            });
        }
    }
};

const T = std.testing;

test "export origins: aliases cycles and diamonds keep real declarations distinct" {
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/leaf.ts", "export function identity<T>(value: T): T { return value; } export interface Shape { value: number; }");
    try vfs.addFile("/alias.ts", "import { identity as local, Shape } from './leaf'; export { local as publicIdentity, Shape };");
    try vfs.addFile("/left.ts", "export * from './right'; export * from './leaf';");
    try vfs.addFile("/right.ts", "export * from './left'; export * from './leaf';");
    try vfs.addFile("/diamond.ts", "export * from './left'; export * from './right';");
    try vfs.addFile("/other.ts", "export const identity = 1;");
    try vfs.addFile("/ambiguous.ts", "export * from './leaf'; export * from './other';");
    try vfs.addFile("/explicit.ts", "export { identity } from './leaf'; export * from './other';");
    try vfs.addFile("/broken-unrelated.ts", "export const unrelated = ;");
    try vfs.addFile("/recovered.ts", "export * from './leaf'; export * from './broken-unrelated';");
    try vfs.addFile("/broken-conflict.ts", "export const identity = ;");
    try vfs.addFile("/recovered-ambiguous.ts", "export * from './leaf'; export * from './broken-conflict';");
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    const original = try query.resolve("/leaf.ts", "identity");
    const alias = try query.resolve("/alias.ts", "publicIdentity");
    try T.expect(original.sameDeclaration(alias));
    try T.expect(alias.value.?.generic_function and alias.value.?.call_only_function);
    try T.expectEqualStrings("/leaf.ts", alias.value.?.path);
    const diamond = try query.resolve("/diamond.ts", "identity");
    try T.expect(diamond.sameDeclaration(original));
    try T.expect(!diamond.ambiguous);
    const shape = try query.resolve("/diamond.ts", "Shape");
    try T.expect(shape.type != null and shape.value == null);
    try T.expect((try query.resolve("/ambiguous.ts", "identity")).ambiguous);
    try T.expect((try query.resolve("/explicit.ts", "identity")).sameDeclaration(original));
    try T.expect((try query.resolve("/recovered.ts", "identity")).sameDeclaration(original));
    try T.expect((try query.resolve("/recovered-ambiguous.ts", "identity")).ambiguous);
    const missing = try query.resolve("/diamond.ts", "missing");
    try T.expect(missing.complete and missing.value == null and missing.type == null);
    try T.expect(!missing.sameDeclaration(missing));
}

test "export origins: ambient module stars retain the first exporting owner" {
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    const files = [_]struct { path: []const u8, source: []const u8 }{
        .{ .path = "/pkg.d.ts", .source = "declare module 'pkg' { export namespace Nested { export class Box { constructor(value: 'ready'); } } }" },
        .{ .path = "/pkg-extra.d.ts", .source = "declare module 'pkg' { export namespace Nested.Box { export const extra: 2; } }" },
        .{ .path = "/other.d.ts", .source = "declare module 'other' { export namespace Nested { export class Box { constructor(value: number); } } }" },
        .{ .path = "/empty.d.ts", .source = "declare module 'empty' { export const unrelated: 1; }" },
        .{ .path = "/barrel.d.ts", .source =
        \\declare module 'first' { export * from 'pkg'; export * from 'other'; }
        \\declare module 'reversed' { export * from 'other'; export * from 'pkg'; }
        \\declare module 'fallback' { export * from 'empty'; export * from 'pkg'; }
        \\declare module 'alias' { export * as API from 'pkg'; }
        },
    };
    var compilations: [files.len]*driver.Compilation = undefined;
    var compiled: usize = 0;
    defer for (compilations[0..compiled]) |c| {
        c.deinit();
        T.allocator.destroy(c);
    };
    for (files) |file| {
        try vfs.addFile(file.path, file.source);
        const c = try program.compileModuleForExportFacts(T.allocator, file.path, file.source);
        compilations[compiled] = c;
        compiled += 1;
    }
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    for (files, compilations) |file, c| try query.borrow(file.path, c);
    for ([_][]const u8{ "first", "reversed", "fallback" }, [_][]const u8{ "/pkg.d.ts", "/other.d.ts", "/pkg.d.ts" }) |module, owner| {
        const resolved = try query.resolveModule(module, "/main.ts", "Nested");
        try T.expect(resolved.complete and !resolved.ambiguous);
        try T.expectEqualStrings(owner, resolved.namespace.?.path);
        try T.expectEqualStrings(owner, resolved.value.?.path);
    }
    const namespace_alias = try query.resolveModule("alias", "/main.ts", "API");
    try T.expect(namespace_alias.complete and !namespace_alias.ambiguous);
    try T.expect(namespace_alias.value != null and namespace_alias.namespace != null);
    const namespace_path = namespace_alias.namespace.?.path;
    try T.expect(std.mem.eql(u8, namespace_path, "/pkg.d.ts") or std.mem.eql(u8, namespace_path, "/pkg-extra.d.ts"));
    try T.expectEqualStrings(namespace_path, namespace_alias.value.?.path);
}

test "export origins: default namespace and type-only aliases preserve owner and visibility" {
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/leaf.ts", "export default class Item {} export { Item }; export const value = 1;");
    try vfs.addFile("/default.ts", "import Item from './leaf'; export { Item };");
    try vfs.addFile("/type.ts", "import type { Item } from './leaf'; export { Item };");
    try vfs.addFile("/namespace.ts", "export * as group from './leaf';");
    try vfs.addFile("/namespace-alias.ts", "import * as local from './leaf'; export { local as group };");
    try vfs.addFile("/star.ts", "export * from './leaf';");
    try vfs.addFile("/function.ts", "export function fn(value: number): number { return value; }");
    try vfs.addFile("/function-type.ts", "import type { fn } from './function'; export { fn };");
    try vfs.addFile("/function-barrel.ts", "export { fn } from './function-type';");
    try vfs.addFile("/function-export-type.ts", "export type { fn } from './function';");
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    const item = try query.resolve("/leaf.ts", "Item");
    try T.expect(item.value != null and item.type != null);
    try T.expect(item.sameDeclaration(try query.resolve("/default.ts", "Item")));
    const type_only = try query.resolve("/type.ts", "Item");
    try T.expect(type_only.value == null and type_only.type != null);
    try T.expect(type_only.type_only_value != null);
    try T.expect(type_only.sameDeclaration(item));
    const ns = try query.resolve("/namespace.ts", "group");
    try T.expect(ns.sameDeclaration(try query.resolve("/namespace-alias.ts", "group")));
    try T.expectEqual(.namespace, ns.namespace.?.kind);
    const missing_default = try query.resolve("/star.ts", "default");
    try T.expect(missing_default.value == null and missing_default.type == null);
    const fn_type = try query.resolve("/function-type.ts", "fn");
    try T.expect(fn_type.value == null and fn_type.type == null and fn_type.type_only_value != null);
    try T.expect(fn_type.sameDeclaration(try query.resolve("/function.ts", "fn")));
    try T.expectEqual(.import_type, fn_type.restriction.?.kind);
    try T.expectEqualStrings("/function-type.ts", fn_type.restriction.?.path);
    const through_barrel = try query.resolve("/function-barrel.ts", "fn");
    try T.expect(through_barrel.sameDeclaration(fn_type));
    try T.expectEqual(.import_type, through_barrel.restriction.?.kind);
    try T.expectEqualStrings("/function-type.ts", through_barrel.restriction.?.path);
    const exported_type = try query.resolve("/function-export-type.ts", "fn");
    try T.expect(exported_type.value == null and exported_type.type_only_value != null);
    try T.expectEqual(.export_type, exported_type.restriction.?.kind);
    try T.expectEqualStrings("/function-export-type.ts", exported_type.restriction.?.path);
}

test "export origins: deep re-export chains do not impose an arbitrary depth cutoff" {
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    for (0..96) |i| {
        const path = try std.fmt.allocPrint(T.allocator, "/module-{d}.ts", .{i});
        defer T.allocator.free(path);
        const source = if (i == 95)
            try T.allocator.dupe(u8, "export const answer = 1;")
        else
            try std.fmt.allocPrint(T.allocator, "export * from './module-{d}';", .{i + 1});
        defer T.allocator.free(source);
        try vfs.addFile(path, source);
    }
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    const result = try query.resolve("/module-0.ts", "answer");
    try T.expect(result.complete and !result.ambiguous);
    try T.expectEqualStrings("/module-95.ts", result.value.?.path);
    try T.expectEqual(@as(usize, 96), query.files.count());
}

test "export origins: independent names inspect their source block only once" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(T.allocator);
    for (0..128) |i| {
        const line = try std.fmt.allocPrint(T.allocator, "const hidden{d} = 0; export const item{d}: number = {d};\n", .{ i, i, i });
        defer T.allocator.free(line);
        try source.appendSlice(T.allocator, line);
    }
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/owner.ts", source.items);
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    for (0..128) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "item{d}", .{i});
        const result = try query.resolve("/owner.ts", name);
        try T.expect(result.complete and !result.ambiguous and result.value != null and result.type == null);
        const owner = query.files.get("/owner.ts").?.compilation;
        const symbol = owner.module.root.values.get(owner.interner.lookup(name).?).?;
        try T.expectEqual(owner.hir.spanOf(symbol.decls.items[0]).start, result.value.?.position);
    }
    const owner = query.files.get("/owner.ts").?.compilation;
    try T.expectEqual(hir.blockStmts(&owner.hir, owner.root).len, query.stats.source_statements);
    const inspected = query.stats.source_statements;
    const hidden = try query.resolve("/owner.ts", "hidden0");
    try T.expect(hidden.complete and hidden.value == null and hidden.type == null);
    const missing = try query.resolve("/owner.ts", "absent");
    try T.expect(missing.complete and missing.value == null and missing.type == null);
    try T.expectEqual(inspected, query.stats.source_statements);
}

test "export origins: indexed declarations retain comma destructuring and merged owners" {
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/owner.ts",
        \\export const first = 1, second = 2;
        \\export const { left, nested: { right } } = { left: 1, nested: { right: 2 } };
        \\export interface Shape { first: number; }
        \\export interface Shape { second: number; }
        \\export namespace Shape { export const marker = 1; }
        \\const hidden = 1;
        \\function nested() { const stray = 2; }
        \\export { first as alias, second as default };
    );
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    for ([_][]const u8{ "first", "second", "left", "right" }) |name| {
        const origin = try query.resolve("/owner.ts", name);
        try T.expect(origin.complete and !origin.ambiguous and origin.value != null);
        const owner = query.files.get("/owner.ts").?.compilation;
        const symbol = owner.module.root.values.get(owner.interner.lookup(name).?).?;
        try T.expectEqual(owner.hir.spanOf(symbol.decls.items[0]).start, origin.value.?.position);
    }
    try T.expect((try query.resolve("/owner.ts", "first")).sameDeclaration(try query.resolve("/owner.ts", "alias")));
    try T.expect((try query.resolve("/owner.ts", "second")).sameDeclaration(try query.resolve("/owner.ts", "default")));
    const shape = try query.resolve("/owner.ts", "Shape");
    try T.expect(shape.complete and !shape.ambiguous and shape.type != null and shape.namespace != null);
    for ([_][]const u8{ "hidden", "nested", "stray", "marker" }) |name| {
        const origin = try query.resolve("/owner.ts", name);
        try T.expect(origin.complete and origin.value == null and origin.type == null and origin.namespace == null);
    }
    try T.expectEqual(@as(usize, 1), query.indexes.count());
}

test "export origins: indexed explicit aliases retain restriction order and star precedence" {
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/first.ts", "export class Item {} export const value = 1;");
    try vfs.addFile("/other.ts", "export class Item {} export const value = 2;");
    try vfs.addFile("/barrel.ts",
        \\export type { Item } from './first';
        \\export { Item } from './first';
        \\export * from './other';
        \\export const value = 3;
    );
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    const item = try query.resolve("/barrel.ts", "Item");
    try T.expect(item.complete and !item.ambiguous and item.value != null and item.type_only_value != null);
    try T.expectEqualStrings("/first.ts", item.value.?.path);
    try T.expectEqualStrings("/barrel.ts", item.restriction.?.path);
    try T.expectEqual(.export_type, item.restriction.?.kind);
    const owner = query.files.get("/barrel.ts").?.compilation;
    const first = hir.blockStmts(&owner.hir, owner.root)[0];
    try T.expectEqual(owner.hir.spanOf(hir.exportNamed(&owner.hir, first)[0]).start, item.restriction.?.position);
    const value = try query.resolve("/barrel.ts", "value");
    try T.expect(value.complete and !value.ambiguous);
    try T.expectEqualStrings("/barrel.ts", value.value.?.path);
    try T.expect(!query.files.contains("/other.ts"));
}

test "export origins: index allocation failures do not leak or own borrowed compilations" {
    const source = "export const first: number = 1; export { first as alias };";
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    const c = try program.compileModuleForExportFacts(T.allocator, "/owner.ts", source);
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const Probe = struct {
        fn run(gpa: std.mem.Allocator, r: *resolver_mod.Resolver, owner: *driver.Compilation) !void {
            var query = Query.init(gpa, r);
            defer query.deinit();
            try query.borrow("/owner.ts", owner);
            const first = try query.resolve("/owner.ts", "first");
            const alias = try query.resolve("/owner.ts", "alias");
            try T.expect(first.sameDeclaration(alias));
        }
    };
    try T.checkAllAllocationFailures(T.allocator, Probe.run, .{ &resolver, c });
}

test "export origins: ambient module imports keep sibling scopes and reexport owners distinct" {
    const source = "declare module 'left'{export type Path=string;}declare module 'right'{export type Path=number;}declare module 'api-left'{import type {Path} from 'left';export {Path};}declare module 'api-right'{import type {Path} from 'right';export {Path};}declare module 'barrel'{export type {Path} from 'api-left';}";
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    const c = try program.compileModuleForExportFacts(T.allocator, "/types.d.ts", source);
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    try query.borrow("/types.d.ts", c);
    const left = try query.resolveModule("left", "/main.ts", "Path");
    const right = try query.resolveModule("right", "/main.ts", "Path");
    try T.expect(left.complete and left.type != null);
    try T.expect(right.complete and right.type != null);
    try T.expect(!left.sameDeclaration(right));
    try T.expect(left.sameDeclaration(try query.resolveModule("api-left", "/main.ts", "Path")));
    try T.expect(right.sameDeclaration(try query.resolveModule("api-right", "/main.ts", "Path")));
    try T.expect(left.sameDeclaration(try query.resolveModule("barrel", "/main.ts", "Path")));
}

test "export origins: ambient export lists control visibility and cycles terminate" {
    const source = "declare module 'owner'{type Hidden=string;type Visible=number;export {Visible};}declare module 'implicit'{type Hidden=string;export interface Public{}}declare module 'one'{export * from 'two';export * from 'owner';}declare module 'two'{export * from 'one';}";
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    const c = try program.compileModuleForExportFacts(T.allocator, "/types.d.ts", source);
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    try query.borrow("/types.d.ts", c);
    const hidden = try query.resolveModule("owner", "/main.ts", "Hidden");
    try T.expect(hidden.complete and hidden.type == null);
    const visible = try query.resolveModule("owner", "/main.ts", "Visible");
    try T.expect(visible.complete and visible.type != null);
    const implicit = try query.resolveModule("implicit", "/main.ts", "Hidden");
    try T.expect(implicit.complete and implicit.type != null);
    try T.expect(visible.sameDeclaration(try query.resolveModule("one", "/main.ts", "Visible")));
}

test "export origins: scoped export enumeration and aliases survive allocation failures" {
    const source = "declare module 'owner'{type Hidden=string;type Visible=number;export {Visible};}declare module 'api'{export * from 'owner';export default function take(value:string):void;}";
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    const c = try program.compileModuleForExportFacts(T.allocator, "/types.d.ts", source);
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const Probe = struct {
        fn run(gpa: std.mem.Allocator, r: *resolver_mod.Resolver, owner: *driver.Compilation) !void {
            var query = Query.init(gpa, r);
            defer query.deinit();
            try query.borrow("/types.d.ts", owner);
            const names = try query.exportNamesForModule("api", "/main.ts");
            try T.expect(names.complete);
            try T.expectEqual(@as(usize, 2), names.names.len);
            try T.expectEqualStrings("Visible", names.names[0]);
            try T.expectEqualStrings("default", names.names[1]);
            const visible = try query.resolveModule("api", "/main.ts", "Visible");
            try T.expect(visible.complete and visible.type != null);
            const hidden = try query.resolveModule("api", "/main.ts", "Hidden");
            try T.expect(hidden.complete and hidden.type == null);
        }
    };
    try T.checkAllAllocationFailures(T.allocator, Probe.run, .{ &resolver, c });
}

test "export origins: unresolved local aliases do not prove missing exports" {
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/owner.d.ts", "export {Unknown};");
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    const alias = try query.resolve("/owner.d.ts", "Unknown");
    try T.expect(!alias.complete and alias.type == null and alias.value == null);
    const absent = try query.resolve("/owner.d.ts", "Absent");
    try T.expect(absent.complete and absent.type == null and absent.value == null);
}

test "export origins: admission filters apply to cached owners and transitive reexports" {
    var vfs = resolver_mod.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/owner.ts", "export { value } from './leaf'; export * as child from './leaf';");
    try vfs.addFile("/leaf.ts", "export const value = 1;");
    try vfs.addFile("/ambient.d.ts", "declare module 'ambient' { export const value: number; }");
    var resolver = resolver_mod.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer resolver.deinit();
    var query = Query.init(T.allocator, &resolver);
    defer query.deinit();
    const admitted = try query.resolve("/owner.ts", "value");
    try T.expect(admitted.value != null);
    const admitted_namespace = try query.resolve("/owner.ts", "child");
    try T.expect(admitted_namespace.namespace != null);
    try T.expect(try query.compilation("/ambient.d.ts") != null);
    try T.expect(try query.hasAmbientModule("ambient"));
    const Admission = struct {
        allow_imported: bool = false,
        fn allows(context: *const anyopaque, path: []const u8) bool {
            const self: *const @This() = @ptrCast(@alignCast(context));
            return self.allow_imported or (!std.mem.eql(u8, path, "/leaf.ts") and !std.mem.eql(u8, path, "/ambient.d.ts"));
        }
    };
    var admission: Admission = .{};
    query.source_filter = .{ .context = &admission, .allows = Admission.allows };
    try T.expect(try query.compilation("/leaf.ts") == null);
    const excluded = try query.resolve("/owner.ts", "value");
    try T.expect(!excluded.complete and excluded.value == null);
    try T.expect(try query.hasExplicitExport("/owner.ts", "value"));
    try T.expect(try query.hasExplicitExport("/owner.ts", "child"));
    try T.expect(!try query.hasExplicitExport("/owner.ts", "absent"));
    const excluded_namespace = try query.resolve("/owner.ts", "child");
    try T.expect(!excluded_namespace.complete and excluded_namespace.namespace == null);
    try T.expect(!try query.hasAmbientModule("ambient"));
    admission.allow_imported = true;
    const restored = try query.resolve("/owner.ts", "value");
    try T.expect(admitted.sameDeclaration(restored));
    try T.expect(admitted_namespace.sameDeclaration(try query.resolve("/owner.ts", "child")));
    try T.expect(try query.hasAmbientModule("ambient"));
}
