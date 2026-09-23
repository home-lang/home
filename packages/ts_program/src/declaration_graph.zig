//! Bound export bindings and one shared source-owned annotation graph.
//! Collection precedes file checking, so root order and worker scheduling do
//! not decide whether an imported signature retains its generic arguments.
const std = @import("std");
const hir = @import("hir");
const driver = @import("ts_driver");
const resolver_mod = @import("ts_resolver");
const schemas = @import("class_schema.zig");

pub const Source = schemas.Source;
const Binding = struct { source: usize, name: []const u8 };
const BindingContext = struct {
    pub fn hash(_: BindingContext, key: Binding) u64 {
        return std.hash.Wyhash.hash(@intCast(key.source), key.name);
    }
    pub fn eql(_: BindingContext, a: Binding, b: Binding) bool {
        return a.source == b.source and std.mem.eql(u8, a.name, b.name);
    }
};
const Position = struct { source: usize, position: u32 };

pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    values: []const driver.ProgramExportedValue = &.{},
    types: []const driver.ProgramExportedType = &.{},

    pub fn init(gpa: std.mem.Allocator) Graph {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Graph) void {
        self.arena.deinit();
    }
};

fn declarationName(c: *const driver.Compilation, node: hir.NodeId) ?[]const u8 {
    const name_node = switch (c.hir.kindOf(node)) {
        .interface_decl => hir.interfaceOf(&c.hir, node).name,
        .type_alias_decl => hir.typeAliasOf(&c.hir, node).name,
        else => return null,
    };
    if (name_node == hir.none_node_id or c.hir.kindOf(name_node) != .identifier) return null;
    return c.interner.get(hir.identifierOf(&c.hir, name_node).name);
}

fn appendNamespaceTypeRoute(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    builder: *schemas.Builder,
    supported: *std.AutoHashMapUnmanaged(*const driver.ProgramClassSchema.Declaration, bool),
    source_index: usize,
    source: Source,
    namespace_node: hir.NodeId,
    target_path: []const u8,
    namespace_path: []const u8,
    types: *std.ArrayListUnmanaged(driver.ProgramExportedType),
) !void {
    const c = source.compilation;
    for (hir.namespaceBody(&c.hir, namespace_node)) |raw| {
        if (c.hir.kindOf(raw) != .export_decl) continue;
        const member = hir.exportOf(&c.hir, raw).decl;
        if (member == hir.none_node_id) continue;
        switch (c.hir.kindOf(member)) {
            .interface_decl, .type_alias_decl => {
                const name = declarationName(c, member) orelse continue;
                const declaration = try builder.declaration(.{ .source = source_index, .node = member });
                const support = try supported.getOrPut(arena, declaration);
                if (!support.found_existing) {
                    support.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
                }
                var duplicate = false;
                for (types.items) |existing| {
                    if (existing.declaration == declaration and
                        std.mem.eql(u8, existing.target_path, target_path) and
                        std.mem.eql(u8, existing.namespace_path, namespace_path) and
                        std.mem.eql(u8, existing.export_name, name))
                    {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try types.append(arena, .{
                    .target_path = target_path,
                    .namespace_path = namespace_path,
                    .export_name = name,
                    .declaration = declaration,
                    .contextual_only = declaration.contextual_only,
                    .projection_only = !support.value_ptr.*,
                });
            },
            .namespace_decl => {
                const nested = hir.namespaceOf(&c.hir, member);
                if (nested.name == hir.none_node_id or c.hir.kindOf(nested.name) != .identifier) continue;
                const nested_name = c.interner.get(hir.identifierOf(&c.hir, nested.name).name);
                const nested_path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ namespace_path, nested_name });
                try appendNamespaceTypeRoute(
                    gpa,
                    arena,
                    builder,
                    supported,
                    source_index,
                    source,
                    member,
                    target_path,
                    nested_path,
                    types,
                );
            },
            else => {},
        }
    }
}

pub fn collect(gpa: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source) !Graph {
    var result = Graph.init(gpa);
    errdefer result.deinit();
    const arena = result.arena.allocator();
    var builder = try schemas.Builder.init(gpa, arena, resolver, sources);
    defer builder.query.deinit();
    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    var declarations: std.AutoHashMapUnmanaged(Position, hir.NodeId) = .empty;
    var pending: std.ArrayListUnmanaged(Binding) = .empty;
    var visited: std.HashMapUnmanaged(Binding, void, BindingContext, 80) = .empty;
    var supported: std.AutoHashMapUnmanaged(*const driver.ProgramClassSchema.Declaration, bool) = .empty;
    const importers = try arena.alloc(std.ArrayListUnmanaged(usize), sources.len);
    @memset(importers, .empty);
    var values: std.ArrayListUnmanaged(driver.ProgramExportedValue) = .empty;
    var types: std.ArrayListUnmanaged(driver.ProgramExportedType) = .empty;
    for (sources, 0..) |source, index| {
        try by_path.put(arena, source.path, index);
        const c = source.compilation;
        for (c.hir.kinds.items, 0..) |kind, node| {
            switch (kind) {
                .fn_decl, .var_decl, .let_decl, .const_decl, .interface_decl, .type_alias_decl => try declarations.put(arena, .{ .source = index, .position = c.hir.spanOf(@intCast(node)).start }, @intCast(node)),
                else => {},
            }
        }
        for (c.module.symbols.items) |symbol| {
            if (symbol.parent_scope != c.module.root or !symbol.flags.is_export) continue;
            try pending.append(arena, .{ .source = index, .name = if (symbol.flags.is_default_export) "default" else c.interner.get(symbol.name) });
        }
    }
    for (sources, 0..) |source, index| {
        const c = source.compilation;
        if (c.root == 0 or c.hir.kindOf(c.root) != .block_stmt) continue;
        for (hir.blockStmts(&c.hir, c.root)) |statement| {
            if (c.hir.kindOf(statement) != .export_decl) continue;
            const ex = hir.exportOf(&c.hir, statement);
            for (hir.exportNamed(&c.hir, statement)) |specifier| {
                const spec = hir.importSpecifierOf(&c.hir, specifier);
                try pending.append(arena, .{ .source = index, .name = c.interner.get(spec.local) });
            }
            if (!ex.is_namespace or c.interner.get(ex.namespace_alias).len != 0) continue;
            const specifier = c.interner.get(ex.module);
            if (specifier.len == 0) continue;
            const target = resolver.resolve(specifier, source.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (by_path.get(target.path)) |target_index| try importers[target_index].append(arena, index);
        }
    }
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        const binding = pending.items[cursor];
        const seen = try visited.getOrPut(arena, binding);
        if (seen.found_existing) continue;
        if (!std.mem.eql(u8, binding.name, "default")) {
            for (importers[binding.source].items) |index| try pending.append(arena, .{ .source = index, .name = binding.name });
        }
        const origins = try builder.query.resolve(sources[binding.source].path, binding.name);
        if (!origins.complete or origins.ambiguous) continue;
        for (0..2) |space| {
            const origin = (if (space == 1) origins.value orelse origins.type_only_value else origins.type) orelse continue;
            const owner = by_path.get(origin.path) orelse continue;
            const node = declarations.get(.{ .source = owner, .position = origin.position }) orelse continue;
            const declaration = try builder.declaration(.{ .source = owner, .node = node });
            const entry = try supported.getOrPut(arena, declaration);
            if (!entry.found_existing) entry.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
            if (space == 0) {
                try types.append(arena, .{
                    .target_path = sources[binding.source].path,
                    .export_name = binding.name,
                    .declaration = declaration,
                    .contextual_only = declaration.contextual_only,
                    .projection_only = !entry.value_ptr.*,
                });
            } else {
                // Parse-diagnostic files publish only the closed literal
                // recovery surface below. An unsupported declaration from a
                // malformed statement is not trustworthy projection metadata.
                if (!entry.value_ptr.* and sources[binding.source].compilation.has_syntactic_parse_diagnostics) continue;
                try values.append(arena, .{
                    .target_path = sources[binding.source].path,
                    .export_name = binding.name,
                    .kind = if (declaration.is_function) .function else .variable,
                    .declaration = declaration,
                    .projection_only = !entry.value_ptr.*,
                });
            }
        }
    }
    // A merged interface/namespace exports its nested types through the root
    // namespace binding. Route those exact source-owned declarations through
    // every direct or export-star target already proven unambiguous above.
    // This keeps `import type { Root }; Root.Member` on the same lossless
    // declaration graph as ordinary top-level imports.
    // `types` grows while nested declarations are appended, so retain a
    // stable snapshot of the proven top-level routes instead of iterating a
    // slice that an ArrayList reallocation could invalidate.
    const routed_types = try arena.dupe(driver.ProgramExportedType, types.items);
    for (sources, 0..) |source, source_index| {
        const c = source.compilation;
        if (c.root == hir.none_node_id or c.hir.kindOf(c.root) != .block_stmt) continue;
        for (hir.blockStmts(&c.hir, c.root)) |raw| {
            if (c.hir.kindOf(raw) != .export_decl) continue;
            const namespace_node = hir.exportOf(&c.hir, raw).decl;
            if (namespace_node == hir.none_node_id or c.hir.kindOf(namespace_node) != .namespace_decl) continue;
            const namespace = hir.namespaceOf(&c.hir, namespace_node);
            if (namespace.name == hir.none_node_id or c.hir.kindOf(namespace.name) != .identifier) continue;
            const namespace_name = c.interner.get(hir.identifierOf(&c.hir, namespace.name).name);
            for (routed_types) |route| {
                if (route.namespace_path.len != 0 or
                    !std.mem.eql(u8, route.declaration.path, source.path) or
                    !std.mem.eql(u8, route.declaration.name, namespace_name))
                {
                    continue;
                }
                try appendNamespaceTypeRoute(
                    gpa,
                    arena,
                    &builder,
                    &supported,
                    source_index,
                    source,
                    namespace_node,
                    route.target_path,
                    route.export_name,
                    &types,
                );
            }
        }
    }
    // A self-contained literal `export const` remains trustworthy even when
    // an unrelated parser diagnostic makes the file's broader export graph
    // incomplete. Publish only that closed form: no aliases, dependencies,
    // or partially reconstructed object/function shapes can leak through.
    for (sources, 0..) |source, index| {
        const c = source.compilation;
        if (!c.has_syntactic_parse_diagnostics) continue;
        var symbols = c.module.root.values.iterator();
        while (symbols.next()) |entry| {
            const symbol = entry.value_ptr.*;
            if (!symbol.flags.is_export or symbol.flags.is_import or symbol.decls.items.len != 1) continue;
            const node = symbol.decls.items[0];
            if (c.hir.kindOf(node) != .const_decl) continue;
            const variable = hir.varDeclOf(&c.hir, node);
            if (variable.type_annotation != hir.none_node_id or variable.init == hir.none_node_id) continue;
            switch (c.hir.kindOf(variable.init)) {
                .literal_string, .literal_number, .literal_bool => {},
                else => continue,
            }
            const export_name = if (symbol.flags.is_default_export) "default" else c.interner.get(entry.key_ptr.*);
            var present = false;
            for (values.items) |value| {
                if (std.mem.eql(u8, value.target_path, source.path) and std.mem.eql(u8, value.export_name, export_name)) {
                    present = true;
                    break;
                }
            }
            if (present) continue;
            const declaration = try builder.declaration(.{ .source = index, .node = node });
            const supported_entry = try supported.getOrPut(arena, declaration);
            if (!supported_entry.found_existing) supported_entry.value_ptr.* = try driver.ProgramClassSchema.Schema.declarationSupported(declaration, gpa);
            if (!supported_entry.value_ptr.*) continue;
            try values.append(arena, .{
                .target_path = source.path,
                .export_name = export_name,
                .kind = .variable,
                .declaration = declaration,
            });
        }
    }
    result.values = try values.toOwnedSlice(arena);
    result.types = try types.toOwnedSlice(arena);
    return result;
}
