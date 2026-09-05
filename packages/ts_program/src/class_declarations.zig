//! Project the currently supported imported-class facts from their bound owners.
//! Export bindings and declaration coordinates are deliberately separate. This
//! is not checked-type transfer; complex member types and heritage still need
//! the source-owned semantic environment.

const std = @import("std");
const hir = @import("hir");
const driver = @import("ts_driver");
const resolver_mod = @import("ts_resolver");
const origins = @import("export_origins.zig");
const class_schema = @import("class_schema.zig");

pub const Source = class_schema.Source;
const Binding = struct { source: usize, name: []const u8 };
const BindingContext = struct {
    pub fn hash(_: BindingContext, key: Binding) u64 {
        return std.hash.Wyhash.hash(@intCast(key.source), key.name);
    }
    pub fn eql(_: BindingContext, a: Binding, b: Binding) bool {
        return a.source == b.source and std.mem.eql(u8, a.name, b.name);
    }
};
const Declaration = struct { source: usize, position: u32 };

pub fn free(gpa: std.mem.Allocator, classes: []const driver.ProgramExportedClass) void {
    for (classes) |class| freeClass(gpa, class);
    gpa.free(classes);
}

fn freeClass(gpa: std.mem.Allocator, class: driver.ProgramExportedClass) void {
    if (class.schema) |schema| @constCast(schema).deinit(gpa);
    gpa.free(class.type_parameter_names);
    gpa.free(class.members);
    gpa.free(class.static_members);
}

pub fn collect(gpa: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source) ![]const driver.ProgramExportedClass {
    var query = origins.Query.init(gpa, resolver);
    defer query.deinit();
    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_path.deinit(gpa);
    var declarations: std.AutoHashMapUnmanaged(Declaration, hir.NodeId) = .empty;
    defer declarations.deinit(gpa);
    var pending: std.ArrayListUnmanaged(Binding) = .empty;
    defer pending.deinit(gpa);
    var visited: std.HashMapUnmanaged(Binding, void, BindingContext, 80) = .empty;
    defer visited.deinit(gpa);
    const importers = try gpa.alloc(std.ArrayListUnmanaged(usize), sources.len);
    @memset(importers, .empty);
    defer {
        for (importers) |*list| list.deinit(gpa);
        gpa.free(importers);
    }
    var out: std.ArrayListUnmanaged(driver.ProgramExportedClass) = .empty;
    errdefer {
        for (out.items) |class| freeClass(gpa, class);
        out.deinit(gpa);
    }
    for (sources, 0..) |source, index| {
        try query.borrow(source.path, source.compilation);
        try by_path.put(gpa, source.path, index);
        const c = source.compilation;
        for (c.hir.kinds.items, 0..) |kind, node| {
            if (kind != .class_decl and kind != .class_expr) continue;
            try declarations.put(gpa, .{ .source = index, .position = c.hir.spanOf(@intCast(node)).start }, @intCast(node));
        }
    }
    for (sources, 0..) |source, index| {
        const c = source.compilation;
        if (c.root == 0 or c.hir.kindOf(c.root) != .block_stmt) continue;
        const statements = hir.blockStmts(&c.hir, c.root);
        try collectAmbient(gpa, resolver, sources, source, statements, &out);
        for (statements) |statement| {
            if (c.hir.kindOf(statement) != .export_decl) continue;
            const ex = hir.exportOf(&c.hir, statement);
            if (ex.is_default) try pending.append(gpa, .{ .source = index, .name = "default" });
            if (ex.decl != 0 and c.hir.kindOf(ex.decl) == .class_decl) {
                if (nodeName(c, hir.classOf(&c.hir, ex.decl).name)) |name|
                    if (!ex.is_default) try pending.append(gpa, .{ .source = index, .name = name });
            }
            for (hir.exportNamed(&c.hir, statement)) |spec_node| {
                const spec = hir.importSpecifierOf(&c.hir, spec_node);
                try pending.append(gpa, .{ .source = index, .name = c.interner.get(spec.local) });
            }
            if (!ex.is_namespace or c.interner.get(ex.namespace_alias).len != 0) continue;
            const specifier = c.interner.get(ex.module);
            if (specifier.len == 0) continue;
            const target = resolver.resolve(specifier, source.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (by_path.get(target.path)) |target_index| try importers[target_index].append(gpa, index);
        }
    }
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        const binding = pending.items[cursor];
        const entry = try visited.getOrPut(gpa, binding);
        if (entry.found_existing) continue;
        // Candidate propagation is independent of successful resolution: an
        // explicit non-class declaration may shadow a same-named star export.
        if (!std.mem.eql(u8, binding.name, "default")) {
            for (importers[binding.source].items) |index|
                try pending.append(gpa, .{ .source = index, .name = binding.name });
        }
        const resolved = try query.resolve(sources[binding.source].path, binding.name);
        if (!resolved.complete or resolved.ambiguous) continue;
        const origin = resolved.type orelse continue;
        const owner = by_path.get(origin.path) orelse continue;
        const node = declarations.get(.{ .source = owner, .position = origin.position }) orelse continue;
        var class = try classFacts(gpa, resolver, sources, sources[owner], node);
        errdefer freeClass(gpa, class);
        class.target_path = sources[binding.source].path;
        class.export_name = binding.name;
        class.is_default = std.mem.eql(u8, binding.name, "default");
        try out.append(gpa, class);
    }
    // Use the same declaration-owned generic graph for local references.
    // Export visibility is separate metadata; adding a local declaration here
    // must not make it available through a module import or namespace value.
    var represented_classes: std.AutoHashMapUnmanaged(Declaration, void) = .empty;
    defer represented_classes.deinit(gpa);
    for (out.items) |class| {
        if (class.declaration_pos) |position| {
            if (by_path.get(class.declaration_path)) |owner| try represented_classes.put(gpa, .{ .source = owner, .position = position }, {});
        }
    }
    for (sources, 0..) |source, source_index| {
        const c = source.compilation;
        for (c.hir.kinds.items, 0..) |kind, index| {
            if (kind != .class_decl) continue;
            const node: hir.NodeId = @intCast(index);
            if (hir.classOf(&c.hir, node).type_params_len == 0) continue;
            const position = c.hir.spanOf(node).start;
            if (represented_classes.contains(.{ .source = source_index, .position = position })) continue;
            var class = try classFacts(gpa, resolver, sources, source, node);
            errdefer freeClass(gpa, class);
            class.local_only = true;
            try out.append(gpa, class);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn nodeName(c: *const driver.Compilation, node: hir.NodeId) ?[]const u8 {
    if (node == 0) return null;
    return switch (c.hir.kindOf(node)) {
        .identifier => c.interner.get(hir.identifierOf(&c.hir, node).name),
        .literal_string => c.interner.get(hir.literalStringOf(&c.hir, node).value),
        else => null,
    };
}

fn unwrap(c: *const driver.Compilation, node: hir.NodeId) hir.NodeId {
    return if (c.hir.kindOf(node) == .export_decl) hir.exportOf(&c.hir, node).decl else node;
}

fn classFacts(gpa: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source, source: Source, node: hir.NodeId) !driver.ProgramExportedClass {
    const c = source.compilation;
    const class = hir.classOf(&c.hir, node);
    var params: std.ArrayListUnmanaged([]const u8) = .empty;
    defer params.deinit(gpa);
    for (c.hir.child_pool.items[class.type_params_start..][0..class.type_params_len]) |param| {
        const parameter = hir.typeParameterOf(&c.hir, param);
        try params.append(gpa, c.interner.get(parameter.name));
    }
    var members: std.ArrayListUnmanaged(driver.ProgramExportedClassMember) = .empty;
    defer members.deinit(gpa);
    var statics: std.ArrayListUnmanaged(driver.ProgramExportedClassMember) = .empty;
    defer statics.deinit(gpa);
    for (hir.classMembers(&c.hir, node)) |member_node| {
        switch (c.hir.kindOf(member_node)) {
            .object_property => {
                const property = hir.objectPropertyOf(&c.hir, member_node);
                if (property.is_computed and c.hir.kindOf(property.key) != .literal_string) continue;
                const name = nodeName(c, property.key) orelse continue;
                const list = if (property.is_static) &statics else &members;
                try list.append(gpa, .{
                    .name = name,
                    .type_name = simpleTypeName(c, property.type_annotation, property.value),
                    .visibility = switch (property.visibility) {
                        .public => .public,
                        .private => .private,
                        .protected => .protected,
                    },
                });
            },
            .fn_decl, .fn_expr, .arrow_fn => {
                const function = hir.fnDeclOf(&c.hir, member_node);
                if (function.flags.is_constructor) continue;
                const name = nodeName(c, function.name) orelse continue;
                const list = if (function.flags.is_static) &statics else &members;
                try list.append(gpa, .{
                    .name = name,
                    // Function signatures still require source-owned checked
                    // metadata; retain the legacy projection's explicit limit.
                    .type_name = "any",
                    .is_method = true,
                    .visibility = if (function.flags.is_private) .private else if (function.flags.is_protected) .protected else .public,
                });
            },
            else => {},
        }
    }
    const name = nodeName(c, class.name) orelse "default";
    const parent = c.hir.parentOf(node);
    const container = if (parent != 0 and c.hir.kindOf(parent) == .export_decl) c.hir.parentOf(parent) else parent;
    const siblings = if (container != 0 and c.hir.kindOf(container) == .namespace_decl)
        hir.namespaceBody(&c.hir, container)
    else if (c.root != 0 and c.hir.kindOf(c.root) == .block_stmt)
        hir.blockStmts(&c.hir, c.root)
    else
        &.{};
    try namespaceStatics(gpa, c, siblings, name, &statics);
    const owned_params = try params.toOwnedSlice(gpa);
    errdefer gpa.free(owned_params);
    const owned_members = try members.toOwnedSlice(gpa);
    errdefer gpa.free(owned_members);
    const owned_statics = try statics.toOwnedSlice(gpa);
    errdefer gpa.free(owned_statics);
    return .{
        .target_path = source.path,
        .declaration_path = source.path,
        .declaration_pos = c.hir.spanOf(node).start,
        .class_name = name,
        .type_parameter_names = owned_params,
        .schema = if (class.type_params_len > 0 or class.extends != 0) try class_schema.collect(gpa, resolver, sources, source, node) else null,
        .members = owned_members,
        .static_members = owned_statics,
    };
}

fn simpleTypeName(c: *const driver.Compilation, annotation: hir.NodeId, initializer: hir.NodeId) []const u8 {
    if (annotation != 0 and c.hir.kindOf(annotation) == .type_ref) return c.interner.get(hir.typeRefOf(&c.hir, annotation).name);
    if (initializer != 0) return switch (c.hir.kindOf(initializer)) {
        .literal_string, .template_literal => "string",
        .literal_number => "number",
        .literal_bool => "boolean",
        .literal_null => "null",
        else => "any",
    };
    return "any";
}

fn namespaceStatics(gpa: std.mem.Allocator, c: *const driver.Compilation, statements: []const hir.NodeId, class_name: []const u8, out: *std.ArrayListUnmanaged(driver.ProgramExportedClassMember)) !void {
    for (statements) |statement| {
        const node = unwrap(c, statement);
        if (node == 0 or c.hir.kindOf(node) != .namespace_decl) continue;
        const namespace = hir.namespaceOf(&c.hir, node);
        if (namespace.is_string_named) continue;
        const name = nodeName(c, namespace.name) orelse continue;
        if (!std.mem.eql(u8, name, class_name)) continue;
        const body = hir.namespaceBody(&c.hir, node);
        const implicit_exports = (namespace.is_ambient or c.is_declaration_file) and !hasExplicitExports(c, body);
        for (body) |child| {
            if (!implicit_exports and c.hir.kindOf(child) != .export_decl) continue;
            const declaration = unwrap(c, child);
            if (declaration == 0) continue;
            switch (c.hir.kindOf(declaration)) {
                .var_decl, .let_decl, .const_decl => {
                    const variable = hir.varDeclOf(&c.hir, declaration);
                    const member_name = nodeName(c, variable.name) orelse continue;
                    try out.append(gpa, .{ .name = member_name, .type_name = simpleTypeName(c, variable.type_annotation, variable.init) });
                },
                else => {},
            }
        }
    }
}

fn hasExplicitExports(c: *const driver.Compilation, statements: []const hir.NodeId) bool {
    for (statements) |statement| if (c.hir.kindOf(statement) == .export_decl) return true;
    return false;
}

fn collectAmbient(gpa: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source, source: Source, statements: []const hir.NodeId, out: *std.ArrayListUnmanaged(driver.ProgramExportedClass)) !void {
    const c = source.compilation;
    for (statements) |statement| {
        const node = unwrap(c, statement);
        if (node == 0 or c.hir.kindOf(node) != .namespace_decl) continue;
        const namespace = hir.namespaceOf(&c.hir, node);
        const module_name = namespace.name;
        if (!namespace.is_string_named) continue;
        const specifier = nodeName(c, module_name) orelse continue;
        if (std.mem.startsWith(u8, specifier, ".")) continue;
        const body = hir.namespaceBody(&c.hir, node);
        const explicit_exports = hasExplicitExports(c, body);
        var assignment: ?[]const u8 = null;
        for (body) |child| {
            if (c.hir.kindOf(child) != .export_decl) continue;
            const ex = hir.exportOf(&c.hir, child);
            if (ex.is_export_equals) assignment = nodeName(c, ex.decl);
        }
        for (body) |child| {
            const declaration = unwrap(c, child);
            if (declaration == 0 or c.hir.kindOf(declaration) != .class_decl) continue;
            if (explicit_exports and c.hir.kindOf(child) != .export_decl) {
                const name = nodeName(c, hir.classOf(&c.hir, declaration).name) orelse continue;
                if (assignment == null or !std.mem.eql(u8, assignment.?, name)) continue;
            }
            var class = try classFacts(gpa, resolver, sources, source, declaration);
            errdefer freeClass(gpa, class);
            class.ambient_module_name = specifier;
            class.is_export_assignment_target = if (assignment) |name| std.mem.eql(u8, name, class.class_name) else false;
            try out.append(gpa, class);
        }
    }
}
