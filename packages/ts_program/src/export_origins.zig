//! Resolve an exported name to its actual declaration origins.
//!
//! Worklist states are (file, name, export/local lookup, value visibility).
//! Visiting each state once terminates cycles without imposing a depth limit
//! or confusing two barrel paths to one declaration with two declarations.
//! This does not transfer TypeIds: all HIR/symbol inspection stays in its owner.

const std = @import("std");
const hir = @import("hir");
const binder = @import("binder");
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
        h.update(&.{ @intFromBool(state.local), @intFromBool(state.values) });
        return h.final();
    }

    pub fn eql(_: StateContext, a: State, b: State) bool {
        return a.local == b.local and a.values == b.values and
            std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.name, b.name);
    }
};

const Entry = struct { compilation: *driver.Compilation, owned: bool };

pub const Query = struct {
    gpa: std.mem.Allocator,
    resolver: *resolver_mod.Resolver,
    files: std.StringHashMapUnmanaged(Entry) = .empty,
    pending: std.ArrayListUnmanaged(State) = .empty,
    visited: std.HashMapUnmanaged(State, void, StateContext, 80) = .empty,
    result: Origins = .{},

    pub fn init(gpa: std.mem.Allocator, resolver: *resolver_mod.Resolver) Query {
        return .{ .gpa = gpa, .resolver = resolver };
    }

    pub fn deinit(self: *Query) void {
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

    fn compilation(self: *Query, path: []const u8) !?*driver.Compilation {
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

    fn enqueue(self: *Query, state: State) !void {
        const entry = try self.visited.getOrPut(self.gpa, state);
        if (!entry.found_existing) try self.pending.append(self.gpa, state);
    }

    fn target(self: *Query, specifier: []const u8, from: []const u8) !?[]const u8 {
        const resolved = self.resolver.resolve(specifier, from) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.result.complete = false;
                return null;
            },
        };
        return resolved.path;
    }

    /// Query-local traversal state is reset between names; bound source
    /// storage can be reused until the Query is destroyed. Results contain
    /// no pointers into that temporary HIR, symbol or string storage.
    pub fn resolve(self: *Query, path: []const u8, name: []const u8) !Origins {
        self.pending.clearRetainingCapacity();
        self.visited.clearRetainingCapacity();
        self.result = .{};
        try self.enqueue(.{ .path = path, .name = name });
        var cursor: usize = 0;
        while (cursor < self.pending.items.len) : (cursor += 1) {
            const state = self.pending.items[cursor];
            const c = try self.compilation(state.path) orelse {
                self.result.complete = false;
                continue;
            };
            if (c.hir.kindOf(c.root) != .block_stmt or c.has_syntactic_parse_diagnostics) {
                self.result.complete = false;
                continue;
            }
            if (state.local) try self.local(c, state) else try self.exported(c, state);
        }
        return self.result;
    }

    fn namespace(self: *Query, path: []const u8, values: bool, restriction: ?Restriction) void {
        const origin: Origin = .{ .path = path, .position = 0, .kind = .namespace };
        self.result.include("namespace", origin);
        if (values) self.result.include("value", origin) else self.result.include("type_only_value", origin);
        if (self.result.restriction == null) self.result.restriction = restriction;
    }

    fn local(self: *Query, c: *const driver.Compilation, state: State) !void {
        const name = c.interner.lookup(state.name) orelse return;
        // Imported bindings are aliases, not the declarations they expose.
        for (hir.blockStmts(&c.hir, c.root)) |node| {
            if (c.hir.kindOf(node) != .import_decl) continue;
            const import = hir.importOf(&c.hir, node);
            const specifier = c.interner.get(import.module);
            if (specifier.len == 0) continue;
            if (import.default_binding != 0 and c.hir.kindOf(import.default_binding) == .identifier and
                hir.identifierOf(&c.hir, import.default_binding).name == name)
            {
                if (import.is_require_equals) {
                    self.result.complete = false;
                    return;
                }
                const path = try self.target(specifier, state.path) orelse return;
                try self.enqueue(.{
                    .path = path,
                    .name = "default",
                    .values = state.values and !import.is_type_only,
                    .restriction = restrictionFor(state, import.is_type_only, .import_type, c.hir.spanOf(node).start),
                });
                return;
            }
            if (import.namespace_binding != 0 and c.hir.kindOf(import.namespace_binding) == .identifier and
                hir.identifierOf(&c.hir, import.namespace_binding).name == name)
            {
                const path = try self.target(specifier, state.path) orelse return;
                self.namespace(path, state.values and !import.is_type_only, restrictionFor(state, import.is_type_only, .import_type, c.hir.spanOf(node).start));
                return;
            }
            for (hir.importNamed(&c.hir, node)) |spec_node| {
                if (c.hir.kindOf(spec_node) != .import_specifier) continue;
                const spec = hir.importSpecifierOf(&c.hir, spec_node);
                if (spec.local != name) continue;
                const path = try self.target(specifier, state.path) orelse return;
                try self.enqueue(.{
                    .path = path,
                    .name = c.interner.get(spec.imported),
                    .values = state.values and !import.is_type_only and !spec.is_type_only,
                    .restriction = restrictionFor(state, import.is_type_only or spec.is_type_only, .import_type, c.hir.spanOf(spec_node).start),
                });
                return;
            }
        }
        inline for (.{ .{ "values", "value" }, .{ "types", "type" }, .{ "namespaces", "namespace" } }) |fields| {
            if (@field(c.module.root, fields[0]).get(name)) |symbol| resolved_symbol: {
                if (symbol.flags.is_import or symbol.decls.items.len == 0) break :resolved_symbol;
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
    }

    fn declaredWithin(c: *const driver.Compilation, symbol: *const binder.Symbol, declaration: hir.NodeId) bool {
        for (symbol.decls.items) |node| {
            var current = node;
            while (current != 0) : (current = c.hir.parentOf(current)) {
                if (current == declaration) return true;
            }
        }
        return false;
    }

    fn exported(self: *Query, c: *const driver.Compilation, state: State) !void {
        const wanted = c.interner.lookup(state.name);
        const is_default = std.mem.eql(u8, state.name, "default");
        var explicit = false;
        for (hir.blockStmts(&c.hir, c.root)) |node| {
            if (c.hir.kindOf(node) != .export_decl) continue;
            const export_info = hir.exportOf(&c.hir, node);
            const specifier = c.interner.get(export_info.module);
            for (hir.exportNamed(&c.hir, node)) |spec_node| {
                if (c.hir.kindOf(spec_node) != .import_specifier) continue;
                const spec = hir.importSpecifierOf(&c.hir, spec_node);
                if (wanted == null or spec.local != wanted.?) continue;
                explicit = true;
                const path = if (specifier.len > 0)
                    try self.target(specifier, state.path) orelse continue
                else
                    state.path;
                try self.enqueue(.{
                    .path = path,
                    .name = c.interner.get(spec.imported),
                    .local = specifier.len == 0,
                    .values = state.values and !export_info.is_type_only and !spec.is_type_only,
                    .restriction = restrictionFor(state, export_info.is_type_only or spec.is_type_only, .export_type, c.hir.spanOf(spec_node).start),
                });
            }
            if (wanted != null and export_info.namespace_alias == wanted.? and specifier.len > 0) {
                explicit = true;
                const path = try self.target(specifier, state.path) orelse continue;
                self.namespace(path, state.values and !export_info.is_type_only, restrictionFor(state, export_info.is_type_only, .export_type, c.hir.spanOf(node).start));
            }
            if (export_info.decl == 0 or export_info.is_export_equals) continue;
            if (export_info.is_default) {
                if (!is_default) continue;
                explicit = true;
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
                        .name = c.interner.get(hir.identifierOf(&c.hir, declared_name).name),
                        .local = true,
                        .values = state.values,
                        .restriction = state.restriction,
                    });
                    continue;
                }
                if (c.hir.kindOf(export_info.decl) == .identifier) {
                    try self.enqueue(.{
                        .path = state.path,
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
                continue;
            }
            if (wanted) |name| {
                inline for (.{ "values", "types", "namespaces" }) |field| {
                    if (@field(c.module.root, field).get(name)) |symbol| {
                        if (declaredWithin(c, symbol, export_info.decl)) {
                            explicit = true;
                            try self.enqueue(.{ .path = state.path, .name = state.name, .local = true, .values = state.values, .restriction = state.restriction });
                        }
                    }
                }
            }
        }
        if (explicit or is_default) return;
        for (hir.blockStmts(&c.hir, c.root)) |node| {
            if (c.hir.kindOf(node) != .export_decl) continue;
            const export_info = hir.exportOf(&c.hir, node);
            if (!export_info.is_namespace or c.interner.get(export_info.namespace_alias).len != 0) continue;
            const specifier = c.interner.get(export_info.module);
            if (specifier.len == 0) continue;
            const path = try self.target(specifier, state.path) orelse continue;
            try self.enqueue(.{
                .path = path,
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
    const missing = try query.resolve("/diamond.ts", "missing");
    try T.expect(missing.complete and missing.value == null and missing.type == null);
    try T.expect(!missing.sameDeclaration(missing));
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
