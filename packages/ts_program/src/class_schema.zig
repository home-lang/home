//! Retain bound generic class annotations and the declarations they reference.
const std = @import("std");
const hir = @import("hir");
const binder = @import("binder");
const driver = @import("ts_driver");
const resolver_mod = @import("ts_resolver");
const origins = @import("export_origins.zig");
const jsdoc_types = @import("jsdoc_types.zig");
const schema = driver.ProgramClassSchema;
const Primitive = schema.Primitive;

const builtin_object_type_name_set = blk: {
    var entries: [schema.builtin_object_type_names.len]struct { []const u8 } = undefined;
    for (schema.builtin_object_type_names, 0..) |name, i| entries[i] = .{name};
    break :blk std.StaticStringMap(void).initComptime(entries);
};

const builtin_generic_type_name_set = blk: {
    var entries: [schema.builtin_generic_type_names.len]struct { []const u8 } = undefined;
    for (schema.builtin_generic_type_names, 0..) |name, i| entries[i] = .{name};
    break :blk std.StaticStringMap(void).initComptime(entries);
};

pub const Source = struct { path: []const u8, compilation: *driver.Compilation };
pub const Key = struct { source: usize, node: hir.NodeId };
const Resolution = union(enum) { declaration: Key, missing, external, unsupported };
const Context = struct {
    source: usize,
    declaration: *schema.Declaration,
    locals: []const *const schema.Parameter = &.{},
    allow_opaque: bool = false,
    allow_contextual_projection: bool = false,
    visible_parameters: ?[]const schema.Parameter = null,
};

pub fn collect(gpa: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source, source: Source, node: hir.NodeId) !*const schema.Schema {
    const result = try gpa.create(schema.Schema);
    result.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .declaration = undefined };
    errdefer result.deinit(gpa);
    var builder = try Builder.init(gpa, result.arena.allocator(), resolver, sources);
    defer builder.query.deinit();
    for (sources, 0..) |owner, index| {
        if (owner.compilation == source.compilation) {
            result.declaration = try builder.declaration(.{ .source = index, .node = node });
            return result;
        }
    }
    unreachable;
}

/// One declaration graph per bound source snapshot. Export aliases retain
/// independent schema views while sharing exact declaration identities.
pub const Collection = struct {
    gpa: std.mem.Allocator,
    graph: *schema.Schema.SharedGraph,
    builder: Builder,

    pub fn init(gpa: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source) !Collection {
        const graph = try gpa.create(schema.Schema.SharedGraph);
        graph.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer graph.release(gpa);
        return .{ .gpa = gpa, .graph = graph, .builder = try Builder.init(gpa, graph.arena.allocator(), resolver, sources) };
    }

    pub fn deinit(self: *Collection) void {
        self.builder.query.deinit();
        self.graph.release(self.gpa);
    }

    pub fn collect(self: *Collection, source: Source, node: hir.NodeId) !*const schema.Schema {
        for (self.builder.sources, 0..) |owner, index| {
            if (owner.compilation != source.compilation) continue;
            const declaration = try self.builder.declaration(.{ .source = index, .node = node });
            const result = try self.gpa.create(schema.Schema);
            result.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa), .declaration = declaration, .shared_graph = self.graph };
            self.graph.references += 1;
            return result;
        }
        unreachable;
    }

    pub fn staticMembers(self: *Collection, source: Source, node: hir.NodeId) !?[]const schema.Member {
        for (self.builder.sources, 0..) |owner, index| {
            if (owner.compilation == source.compilation) return self.builder.classStaticMembers(.{ .source = index, .node = node });
        }
        unreachable;
    }

    pub fn staticJSDocFieldMembers(self: *Collection, source: Source, node: hir.NodeId) !?[]const schema.Member {
        for (self.builder.sources, 0..) |owner, index| {
            if (owner.compilation == source.compilation) return self.builder.classStaticJSDocFieldMembers(.{ .source = index, .node = node });
        }
        unreachable;
    }
};

pub const Builder = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    sources: []const Source,
    resolver: *resolver_mod.Resolver,
    query: origins.Query,
    declarations: std.AutoHashMapUnmanaged(Key, *schema.Declaration) = .empty,
    global_types: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Key)) = .empty,
    ambient_class_types: std.StringHashMapUnmanaged(AmbientClassType) = .empty,

    const AmbientClassType = struct {
        class: ?Key = null,
        conflicting_type: bool = false,
    };

    const ReadMode = enum { all, pick, omit };
    const ReadCoverage = struct {
        source: *const schema.Expression,
        keys: ?*const schema.Expression = null,
        mode: ReadMode = .all,
        transformed: bool = false,
        deferred: bool = false,
        optional_keys: ?*const schema.Expression = null,
        optional_all: bool = false,
        string_index: ?*const schema.Expression = null,
    };
    const ReadBinding = struct {
        parameter: *const schema.Parameter,
        argument: *const schema.Expression,
    };

    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source) !Builder {
        var result: Builder = .{ .gpa = gpa, .arena = arena, .sources = sources, .resolver = resolver, .query = origins.Query.init(gpa, resolver) };
        errdefer result.query.deinit();
        for (sources, 0..) |owner, source| {
            try result.query.borrow(owner.path, owner.compilation);
            const c = owner.compilation;
            for (c.module.scopes.items) |scope| {
                if (!globalScope(c, scope)) continue;
                var symbols = scope.types.iterator();
                while (symbols.next()) |entry| {
                    if (entry.value_ptr.*.flags.is_import) continue;
                    for (entry.value_ptr.*.decls.items) |node| {
                        if (!declarationHasName(c, node, entry.key_ptr.*)) continue;
                        const group = try result.global_types.getOrPut(arena, c.interner.get(entry.key_ptr.*));
                        if (!group.found_existing) group.value_ptr.* = .empty;
                        const key: Key = .{ .source = source, .node = node };
                        var found = false;
                        for (group.value_ptr.items) |existing| if (std.meta.eql(existing, key)) {
                            found = true;
                            break;
                        };
                        if (!found) try group.value_ptr.append(arena, key);
                    }
                }
            }
            // A class merged with a same-named ambient namespace may live in
            // another declaration fragment. Index its exact module and
            // enclosing namespace path once, so a reference from a namespace
            // member can resolve the class without guessing from one origin.
            var node: hir.NodeId = 1;
            while (node < c.hir.nodeCount()) : (node += 1) {
                if (c.hir.kindOf(node) != .class_decl) continue;
                const name_node = hir.classOf(&c.hir, node).name;
                if (name_node == 0 or c.hir.kindOf(name_node) != .identifier) continue;
                const scope = enclosingNamespace(c, node);
                if (scope == 0) continue;
                const parent = c.hir.parentOf(node);
                if (c.hir.kindOf(parent) != .export_decl and !c.is_declaration_file and !hir.namespaceOf(&c.hir, scope).is_ambient) continue;
                const text = c.interner.get(hir.identifierOf(&c.hir, name_node).name);
                const scope_key = (try ambientNamespaceKey(arena, c, scope, text)) orelse continue;
                const entry = try result.ambient_class_types.getOrPut(arena, scope_key);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                if (entry.value_ptr.class != null) entry.value_ptr.conflicting_type = true;
                entry.value_ptr.class = .{ .source = source, .node = node };
            }
        }
        return result;
    }

    fn enclosingNamespace(c: *const driver.Compilation, node: hir.NodeId) hir.NodeId {
        var current = c.hir.parentOf(node);
        while (current != 0) : (current = c.hir.parentOf(current)) {
            if (c.hir.kindOf(current) == .namespace_decl) return current;
        }
        return 0;
    }

    fn ambientNamespaceKey(arena: std.mem.Allocator, c: *const driver.Compilation, scope: hir.NodeId, name: []const u8) !?[]const u8 {
        var components: std.ArrayListUnmanaged([]const u8) = .empty;
        var current = scope;
        while (current != 0) : (current = enclosingNamespace(c, current)) {
            const namespace = hir.namespaceOf(&c.hir, current);
            if (namespace.name == 0) return null;
            switch (c.hir.kindOf(namespace.name)) {
                .identifier, .literal_string => {
                    // Quoted ambient module names are represented as HIR
                    // identifiers by the parser. The source span, not the HIR
                    // tag, distinguishes `module "pkg"` from `namespace pkg`.
                    const span = c.hir.spanOf(namespace.name);
                    const quoted = span.start < c.source.len and (c.source[span.start] == '"' or c.source[span.start] == '\'');
                    const text = if (c.hir.kindOf(namespace.name) == .identifier)
                        c.interner.get(hir.identifierOf(&c.hir, namespace.name).name)
                    else
                        c.interner.get(hir.literalStringOf(&c.hir, namespace.name).value);
                    if (!quoted) {
                        try components.append(arena, text);
                        continue;
                    }
                    const module = text;
                    var key = try std.fmt.allocPrint(arena, "{d}:{s}", .{ module.len, module });
                    var index = components.items.len;
                    while (index > 0) {
                        index -= 1;
                        const part = components.items[index];
                        key = try std.fmt.allocPrint(arena, "{s}{d}:{s}", .{ key, part.len, part });
                    }
                    return try std.fmt.allocPrint(arena, "{s}{d}:{s}", .{ key, name.len, name });
                },
                else => return null,
            }
        }
        return null;
    }

    fn mergedAmbientClass(self: *Builder, source: usize, node: hir.NodeId, name: []const u8) !?Resolution {
        const c = self.sources[source].compilation;
        var current = node;
        while (current != 0) : (current = c.hir.parentOf(current)) {
            if (c.hir.kindOf(current) != .namespace_decl) continue;
            const namespace = hir.namespaceOf(&c.hir, current);
            if (namespace.name == 0 or c.hir.kindOf(namespace.name) != .identifier) continue;
            if (!std.mem.eql(u8, c.interner.get(hir.identifierOf(&c.hir, namespace.name).name), name)) continue;
            const parent_scope = enclosingNamespace(c, current);
            if (parent_scope == 0) continue;
            const key = (try ambientNamespaceKey(self.arena, c, parent_scope, name)) orelse continue;
            const entry = self.ambient_class_types.get(key) orelse continue;
            if (entry.conflicting_type) return .unsupported;
            if (entry.class) |class| {
                if (try self.ambientClassHasConflictingType(key, name)) return .unsupported;
                return .{ .declaration = class };
            }
        }
        return null;
    }

    fn ambientClassHasConflictingType(self: *Builder, key: []const u8, name: []const u8) !bool {
        for (self.sources) |source| {
            const c = source.compilation;
            var node: hir.NodeId = 1;
            while (node < c.hir.nodeCount()) : (node += 1) {
                const kind = c.hir.kindOf(node);
                if (kind != .interface_decl and kind != .type_alias_decl) continue;
                const name_node = if (kind == .interface_decl) hir.interfaceOf(&c.hir, node).name else hir.typeAliasOf(&c.hir, node).name;
                if (name_node == 0 or c.hir.kindOf(name_node) != .identifier or
                    !std.mem.eql(u8, c.interner.get(hir.identifierOf(&c.hir, name_node).name), name)) continue;
                const scope = enclosingNamespace(c, node);
                if (scope == 0) continue;
                const parent = c.hir.parentOf(node);
                if (c.hir.kindOf(parent) != .export_decl and !c.is_declaration_file and !hir.namespaceOf(&c.hir, scope).is_ambient) continue;
                const candidate_key = (try ambientNamespaceKey(self.arena, c, scope, name)) orelse continue;
                if (std.mem.eql(u8, candidate_key, key)) return true;
            }
        }
        return false;
    }

    fn globalScope(c: *const driver.Compilation, scope: *const binder.Scope) bool {
        if (scope == c.module.root) return !@import("ts_program.zig").Program.boundSourceIsExternalModule(c);
        if (scope.kind != .namespace) return false;
        const node = scope.introducing_node;
        if (node == 0 or c.hir.kindOf(node) != .namespace_decl) return false;
        const namespace = hir.namespaceOf(&c.hir, node);
        if (namespace.name == 0 or c.hir.kindOf(namespace.name) != .identifier) return false;
        return std.mem.eql(u8, c.interner.get(hir.identifierOf(&c.hir, namespace.name).name), "global") and
            c.hir.spanOf(node).start == c.hir.spanOf(namespace.name).start;
    }

    fn globalFragments(self: *Builder, key: Key) []const Key {
        const c = self.sources[key.source].compilation;
        const node = key.node;
        const name_node = switch (c.hir.kindOf(node)) {
            .interface_decl => hir.interfaceOf(&c.hir, node).name,
            else => return &.{},
        };
        if (name_node == 0 or c.hir.kindOf(name_node) != .identifier) return &.{};
        const name = c.interner.get(hir.identifierOf(&c.hir, name_node).name);
        const group = self.global_types.get(name) orelse return &.{};
        for (group.items) |member| if (std.meta.eql(member, key)) return group.items;
        return &.{};
    }

    fn expression(self: *Builder, value: schema.Expression) !*const schema.Expression {
        const node = try self.arena.create(schema.Expression);
        node.* = value;
        return node;
    }

    fn transferable(self: *Builder, value: *const schema.Expression) !*const schema.Expression {
        switch (value.*) {
            .primitive, .opaque_leaf, .builtin_object, .parameter, .string, .number, .boolean => return value,
            .unsupported => return self.expression(.opaque_leaf),
            else => {},
        }
        if (try schema.Schema.expressionSupported(value, self.gpa)) return value;
        // The surrounding declaration still carries exact arity, optionality,
        // generic parameters, and every supported sibling. `any` is the only
        // sound cross-pool representation for this one unprojectable leaf.
        return self.expression(.opaque_leaf);
    }

    fn contextualReadArgument(expr: *const schema.Expression, bindings: []const ReadBinding) *const schema.Expression {
        var current = expr;
        var remaining = bindings.len + 1;
        while (remaining > 0 and current.* == .parameter) : (remaining -= 1) {
            var index = bindings.len;
            var next = current;
            while (index > 0) {
                index -= 1;
                if (bindings[index].parameter == current.parameter) {
                    next = bindings[index].argument;
                    break;
                }
            }
            if (next == current) break;
            current = next;
        }
        return current;
    }

    fn contextualMappedCopiesSource(
        mapped: schema.Mapped,
        source: *const schema.Expression,
        projected_source: *const schema.Expression,
        bindings: []const ReadBinding,
    ) bool {
        if (mapped.constraint.* != .keyof) return false;
        return switch (mapped.template.*) {
            .indexed_access => |indexed| (contextualReadExpressionsEqual(contextualReadArgument(indexed.object, bindings), source) or
                contextualReadExpressionsEqual(indexed.object, projected_source)) and
                indexed.index.* == .parameter and indexed.index.parameter == mapped.parameter,
            .union_type => |members| blk: {
                var found = false;
                for (members) |member| switch (member.*) {
                    .primitive => |primitive| if (primitive != Primitive.undefined_t) break :blk false,
                    else => if (contextualMappedTemplateCopiesSource(member, source, projected_source, mapped.parameter, bindings)) {
                        if (found) break :blk false;
                        found = true;
                    } else break :blk false,
                };
                break :blk found;
            },
            else => false,
        };
    }

    fn contextualReadExpressionsEqual(a: *const schema.Expression, b: *const schema.Expression) bool {
        if (a == b) return true;
        return a.* == .parameter and b.* == .parameter and a.parameter == b.parameter;
    }

    fn contextualMappedTemplateCopiesSource(
        expr: *const schema.Expression,
        source: *const schema.Expression,
        projected_source: *const schema.Expression,
        parameter: *const schema.Parameter,
        bindings: []const ReadBinding,
    ) bool {
        return switch (expr.*) {
            .indexed_access => |indexed| (contextualReadExpressionsEqual(contextualReadArgument(indexed.object, bindings), source) or
                contextualReadExpressionsEqual(indexed.object, projected_source)) and
                indexed.index.* == .parameter and indexed.index.parameter == parameter,
            else => false,
        };
    }

    fn contextualReadCoverage(
        self: *Builder,
        expr: *const schema.Expression,
        bindings: []const ReadBinding,
        active: *std.AutoHashMapUnmanaged(*const schema.Declaration, void),
    ) !?ReadCoverage {
        switch (expr.*) {
            .parameter => {
                const argument = contextualReadArgument(expr, bindings);
                if (argument != expr) return self.contextualReadCoverage(argument, bindings, active);
                return .{ .source = expr };
            },
            .reference => |reference| {
                if (active.contains(reference.declaration)) return null;
                try active.put(self.gpa, reference.declaration, {});
                defer _ = active.remove(reference.declaration);
                if (reference.arguments.len > reference.declaration.parameters.len or reference.declaration.body == null) return null;
                const nested = try self.gpa.alloc(ReadBinding, bindings.len + reference.declaration.parameters.len);
                defer self.gpa.free(nested);
                @memcpy(nested[0..bindings.len], bindings);
                for (reference.declaration.parameters[0..reference.arguments.len], reference.arguments, nested[bindings.len..][0..reference.arguments.len]) |*parameter, argument, *binding| binding.* = .{
                    .parameter = parameter,
                    .argument = contextualReadArgument(argument, bindings),
                };
                for (reference.declaration.parameters[reference.arguments.len..], reference.arguments.len..) |*parameter, index| {
                    const default = parameter.default orelse return null;
                    nested[bindings.len + index] = .{
                        .parameter = parameter,
                        .argument = contextualReadArgument(default, nested[0 .. bindings.len + index]),
                    };
                }
                return self.contextualReadCoverage(reference.declaration.body.?, nested, active);
            },
            .conditional => |conditional| {
                if (conditional.true_branch.* == .primitive and conditional.true_branch.primitive == Primitive.never) {
                    var coverage = (try self.contextualReadCoverage(conditional.false_branch, bindings, active)) orelse return null;
                    coverage.transformed = true;
                    coverage.deferred = true;
                    return coverage;
                }
                if (conditional.false_branch.* == .primitive and conditional.false_branch.primitive == Primitive.never) {
                    var coverage = (try self.contextualReadCoverage(conditional.true_branch, bindings, active)) orelse return null;
                    coverage.transformed = true;
                    coverage.deferred = true;
                    return coverage;
                }
                if (conditional.extends_type.* != .primitive or
                    (conditional.extends_type.primitive != Primitive.any and
                        conditional.extends_type.primitive != Primitive.unknown)) return null;
                var coverage = (try self.contextualReadCoverage(conditional.true_branch, bindings, active)) orelse return null;
                coverage.transformed = true;
                return coverage;
            },
            .mapped => |mapped| {
                if (mapped.constraint.* != .keyof) return null;
                const raw_source = mapped.constraint.keyof;
                const source = contextualReadArgument(raw_source, bindings);
                var coverage = (try self.contextualReadCoverage(source, bindings, active)) orelse ReadCoverage{ .source = source };
                if (!contextualMappedCopiesSource(mapped, source, coverage.source, bindings)) return null;
                if (!contextualReadExpressionsEqual(source, coverage.source)) coverage.deferred = true;
                coverage.transformed = true;
                if (mapped.optional == 1) coverage.optional_all = true;
                return coverage;
            },
            .utility => |utility| {
                if (utility.kind == .exclude) return null;
                const source_expression = contextualReadArgument(utility.source, bindings);
                var source = (try self.contextualReadCoverage(source_expression, bindings, active)) orelse
                    ReadCoverage{ .source = source_expression };
                source.transformed = true;
                return switch (utility.kind) {
                    .partial => blk: {
                        source.optional_all = true;
                        break :blk source;
                    },
                    .required, .readonly => source,
                    .pick => if (source.mode == .all) blk: {
                        const raw_keys = utility.keys.?;
                        if (raw_keys.* == .utility and raw_keys.utility.kind == .exclude) {
                            const excluded = raw_keys.utility;
                            if (excluded.source.* == .keyof and
                                contextualReadExpressionsEqual(
                                    contextualReadArgument(excluded.source.keyof, bindings),
                                    source.source,
                                ))
                            {
                                break :blk .{
                                    .source = source.source,
                                    .keys = contextualReadArgument(excluded.keys.?, bindings),
                                    .mode = .omit,
                                    .transformed = true,
                                    .optional_keys = source.optional_keys,
                                    .optional_all = source.optional_all,
                                };
                            }
                        }
                        break :blk .{
                            .source = source.source,
                            .keys = contextualReadArgument(raw_keys, bindings),
                            .mode = .pick,
                            .transformed = true,
                            .optional_keys = source.optional_keys,
                            .optional_all = source.optional_all,
                        };
                    } else null,
                    .omit => if (source.mode == .all)
                        .{
                            .source = source.source,
                            .keys = contextualReadArgument(utility.keys.?, bindings),
                            .mode = .omit,
                            .transformed = true,
                            .optional_keys = source.optional_keys,
                            .optional_all = source.optional_all,
                        }
                    else
                        null,
                    .extract, .exclude => null,
                };
            },
            .intersection => |members| {
                // A projection of one base cannot stand in for concrete
                // sibling fields. Keep a fully supported intersection exact;
                // unsupported utility scaffolding still uses its read surface.
                for (members) |member| {
                    const has_members = switch (member.*) {
                        .object => |own| own.len != 0,
                        .indexed_object => |own| own.members.len != 0,
                        else => false,
                    };
                    if (has_members and try schema.Schema.expressionSupported(expr, self.gpa)) return null;
                }
                var all: ?ReadCoverage = null;
                var picked: ?ReadCoverage = null;
                var omitted: ?ReadCoverage = null;
                var string_index: ?*const schema.Expression = null;
                for (members) |member| {
                    if (member.* == .record) {
                        const record = member.record;
                        const key = contextualReadArgument(record.key, bindings);
                        if (key.* == .primitive and key.primitive == Primitive.string_t) {
                            string_index = contextualReadArgument(record.value, bindings);
                        }
                        continue;
                    }
                    var coverage = (try self.contextualReadCoverage(member, bindings, active)) orelse continue;
                    coverage.transformed = true;
                    if (coverage.string_index) |index| string_index = index;
                    if (coverage.mode == .all and all == null) all = coverage;
                    if (coverage.mode == .pick and picked == null) picked = coverage;
                    if (coverage.mode == .omit and omitted == null) omitted = coverage;
                }
                var result = all;
                if (result == null) if (picked) |pick| if (omitted) |omit| {
                    if (pick.source == omit.source and pick.keys == omit.keys) {
                        if (pick.optional_all and omit.optional_all) result = .{
                            .source = pick.source,
                            .transformed = true,
                            .optional_all = true,
                        } else if (pick.optional_all and !omit.optional_all) result = .{
                            .source = pick.source,
                            .transformed = true,
                            .optional_keys = pick.keys,
                        } else if (!pick.optional_all and !omit.optional_all) result = .{
                            .source = pick.source,
                            .transformed = true,
                        };
                    }
                };
                if (result == null) if (omitted) |omit| {
                    var deferred = omit;
                    deferred.deferred = true;
                    result = deferred;
                };
                if (result) |*coverage| {
                    coverage.string_index = string_index orelse coverage.string_index;
                    return coverage.*;
                }
                return null;
            },
            else => return null,
        }
    }

    fn contextualReadProjection(self: *Builder, reference: schema.Reference) !?ReadCoverage {
        if (reference.arguments.len > reference.declaration.parameters.len or reference.declaration.body == null) return null;
        const bindings = try self.gpa.alloc(ReadBinding, reference.declaration.parameters.len);
        defer self.gpa.free(bindings);
        for (reference.declaration.parameters[0..reference.arguments.len], reference.arguments, bindings[0..reference.arguments.len]) |*parameter, argument, *binding| binding.* = .{
            .parameter = parameter,
            .argument = argument,
        };
        for (reference.declaration.parameters[reference.arguments.len..], reference.arguments.len..) |*parameter, index| {
            const default = parameter.default orelse return null;
            bindings[index] = .{
                .parameter = parameter,
                .argument = contextualReadArgument(default, bindings[0..index]),
            };
        }
        var active: std.AutoHashMapUnmanaged(*const schema.Declaration, void) = .empty;
        defer active.deinit(self.gpa);
        try active.put(self.gpa, reference.declaration, {});
        const coverage = (try self.contextualReadCoverage(reference.declaration.body.?, bindings, &active)) orelse return null;
        return if (coverage.transformed and (coverage.mode == .all or coverage.deferred)) coverage else null;
    }

    fn contextualShallowStructuralReferenceSupported(self: *Builder, reference: schema.Reference) !bool {
        if (reference.arguments.len > reference.declaration.parameters.len or reference.declaration.body == null) return false;
        var pending: std.ArrayListUnmanaged(*const schema.Expression) = .empty;
        defer pending.deinit(self.gpa);
        var visited: std.AutoHashMapUnmanaged(*const schema.Expression, void) = .empty;
        defer visited.deinit(self.gpa);
        try pending.append(self.gpa, reference.declaration.body.?);
        while (pending.pop()) |expr| {
            const entry = try visited.getOrPut(self.gpa, expr);
            if (entry.found_existing) continue;
            switch (expr.*) {
                .primitive, .opaque_leaf, .builtin_object, .parameter, .string, .number, .boolean, .object, .class_value, .indexed_object => {},
                .builtin_reference => |builtin| try pending.appendSlice(self.gpa, builtin.arguments),
                .array, .readonly_array => |element| try pending.append(self.gpa, element),
                .tuple => |elements| for (elements) |element| try pending.append(self.gpa, element.type),
                .union_type, .intersection => |members| try pending.appendSlice(self.gpa, members),
                .reference => |nested| {
                    if (nested.arguments.len > nested.declaration.parameters.len or nested.declaration.body == null) return false;
                    try pending.append(self.gpa, nested.declaration.body.?);
                },
                .unsupported => return false,
                else => return false,
            }
        }
        return true;
    }

    /// Qualified aliases are ordinary declaration edges when their complete
    /// graph is already losslessly representable by the Program schema. Keep
    /// contextual/projection-only edges, classes, declared functions,
    /// and unsupported built-in instantiations out of whole-type admission.
    fn qualifiedDeclarationGraphSupported(self: *Builder, target: *const schema.Declaration) !bool {
        if (target.contextual_only or target.is_class or target.is_function) return false;
        var pending: std.ArrayListUnmanaged(*const schema.Expression) = .empty;
        defer pending.deinit(self.gpa);
        var visited: std.AutoHashMapUnmanaged(*const schema.Expression, void) = .empty;
        defer visited.deinit(self.gpa);
        if (target.body) |body| try pending.append(self.gpa, body) else return false;
        for (target.parameters) |parameter| {
            if (parameter.constraint) |constraint| try pending.append(self.gpa, constraint);
            if (parameter.default) |default| try pending.append(self.gpa, default);
        }
        while (pending.pop()) |expr| {
            const entry = try visited.getOrPut(self.gpa, expr);
            if (entry.found_existing) continue;
            switch (expr.*) {
                .primitive, .builtin_object, .parameter, .string, .number, .boolean, .polymorphic_this => {},
                .array, .readonly_array, .keyof, .this_type => |element| try pending.append(self.gpa, element),
                .object => |members| for (members) |member| {
                    try pending.append(self.gpa, member.type);
                    if (member.write_type) |write_type| try pending.append(self.gpa, write_type);
                },
                .class_value => |value| for (value.members) |member| {
                    try pending.append(self.gpa, member.type);
                    if (member.write_type) |write_type| try pending.append(self.gpa, write_type);
                },
                .indexed_object => |indexed_object| {
                    for (indexed_object.members) |member| {
                        try pending.append(self.gpa, member.type);
                        if (member.write_type) |write_type| try pending.append(self.gpa, write_type);
                    }
                    for (indexed_object.indices) |index| {
                        try pending.append(self.gpa, index.key);
                        try pending.append(self.gpa, index.value);
                    }
                },
                .record => |record| {
                    if (!try schema.Schema.recordIndexKeySupported(record.key, self.gpa)) return false;
                    try pending.append(self.gpa, record.key);
                    try pending.append(self.gpa, record.value);
                },
                .utility => |utility| {
                    if (utility.kind != .extract and utility.kind != .exclude) return false;
                    try pending.append(self.gpa, utility.source);
                    if (utility.keys) |keys| try pending.append(self.gpa, keys);
                },
                .tuple => |elements| for (elements) |element| try pending.append(self.gpa, element.type),
                .union_type, .intersection => |members| try pending.appendSlice(self.gpa, members),
                .function => |function| {
                    for (function.type_parameters) |parameter| {
                        if (parameter.constraint) |constraint| try pending.append(self.gpa, constraint);
                        if (parameter.default) |default| try pending.append(self.gpa, default);
                    }
                    if (function.this_type) |receiver| try pending.append(self.gpa, receiver);
                    for (function.parameters) |parameter| try pending.append(self.gpa, parameter.type);
                    try pending.append(self.gpa, function.result);
                    if (function.predicate) |predicate| try pending.append(self.gpa, predicate.target);
                },
                .reference => |reference| {
                    if (reference.declaration.contextual_only or
                        reference.declaration.is_class or
                        reference.declaration.is_function or
                        reference.projection_only or
                        reference.contextual_projection)
                        return false;
                    if (reference.declaration.body) |body| try pending.append(self.gpa, body) else return false;
                    for (reference.declaration.parameters) |parameter| {
                        if (parameter.constraint) |constraint| try pending.append(self.gpa, constraint);
                        if (parameter.default) |default| try pending.append(self.gpa, default);
                    }
                    try pending.appendSlice(self.gpa, reference.arguments);
                },
                .indexed_access => |indexed| {
                    try pending.append(self.gpa, indexed.object);
                    try pending.append(self.gpa, indexed.index);
                },
                .conditional => |conditional| {
                    try pending.append(self.gpa, conditional.check);
                    try pending.append(self.gpa, conditional.extends_type);
                    try pending.append(self.gpa, conditional.true_branch);
                    try pending.append(self.gpa, conditional.false_branch);
                },
                .mapped => |mapped| {
                    try pending.append(self.gpa, mapped.constraint);
                    try pending.append(self.gpa, mapped.template);
                },
                .infer => |parameter| if (parameter.constraint) |constraint| try pending.append(self.gpa, constraint),
                .builtin_reference => |builtin| try pending.appendSlice(self.gpa, builtin.arguments),
                .opaque_leaf, .typeof_class, .inherited_constructors, .unsupported => return false,
            }
        }
        return true;
    }

    fn lowerTransferableWithStructuralDefault(self: *Builder, context: Context, node: hir.NodeId, allow_structural_default: bool) !*const schema.Expression {
        const lowered = try self.lower(context, node);
        if (!context.allow_opaque) return lowered;
        if (try schema.Schema.expressionSupported(lowered, self.gpa)) return lowered;
        const result = switch (lowered.*) {
            .reference => |reference| blk: {
                const contextual_read = try self.contextualReadProjection(reference);
                const can_project_declaration = (context.allow_contextual_projection or reference.declaration.contextual_only) and
                    reference.declaration.body != null and
                    !reference.declaration.is_class and
                    !reference.declaration.is_function;
                if (contextual_read == null and
                    !can_project_declaration and
                    (!allow_structural_default or !try self.contextualShallowStructuralReferenceSupported(reference)))
                    break :blk try self.expression(.opaque_leaf);
                break :blk try self.expression(.{ .reference = .{
                    .declaration = reference.declaration,
                    .arguments = reference.arguments,
                    .projection_only = reference.projection_only,
                    .contextual_projection = true,
                    .contextual_read = if (contextual_read) |read| read.source else null,
                    .contextual_read_optional_keys = if (contextual_read) |read| read.optional_keys else null,
                    .contextual_read_optional_all = if (contextual_read) |read| read.optional_all else false,
                    .contextual_read_string_index = if (contextual_read) |read| read.string_index else null,
                } });
            },
            else => try self.transferable(lowered),
        };
        if (result != lowered) context.declaration.contextual_only = true;
        return result;
    }

    fn lowerTransferable(self: *Builder, context: Context, node: hir.NodeId) !*const schema.Expression {
        return self.lowerTransferableWithStructuralDefault(context, node, false);
    }

    fn lowerContextualDefault(self: *Builder, context: Context, node: hir.NodeId) !*const schema.Expression {
        return self.lowerTransferableWithStructuralDefault(context, node, true);
    }

    fn standardUtility(
        self: *Builder,
        name: []const u8,
        args: []const *const schema.Expression,
    ) !?*const schema.Expression {
        const kind: ?schema.UtilityKind = if (args.len == 1 and std.mem.eql(u8, name, "Partial"))
            .partial
        else if (args.len == 1 and std.mem.eql(u8, name, "Required"))
            .required
        else if (args.len == 1 and std.mem.eql(u8, name, "Readonly"))
            .readonly
        else if (args.len == 2 and std.mem.eql(u8, name, "Pick"))
            .pick
        else if (args.len == 2 and std.mem.eql(u8, name, "Omit"))
            .omit
        else if (args.len == 2 and std.mem.eql(u8, name, "Extract"))
            .extract
        else if (args.len == 2 and std.mem.eql(u8, name, "Exclude"))
            .exclude
        else
            null;
        const utility = kind orelse return null;
        return try self.expression(.{ .utility = .{
            .kind = utility,
            .source = args[0],
            .keys = if (args.len == 2) args[1] else null,
        } });
    }

    fn extendContext(self: *Builder, context: Context, parameters: []const *const schema.Parameter) !Context {
        const locals = try self.arena.alloc(*const schema.Parameter, context.locals.len + parameters.len);
        @memcpy(locals[0..context.locals.len], context.locals);
        @memcpy(locals[context.locals.len..], parameters);
        return .{
            .source = context.source,
            .declaration = context.declaration,
            .visible_parameters = context.visible_parameters,
            .locals = locals,
            .allow_opaque = context.allow_opaque,
            .allow_contextual_projection = context.allow_contextual_projection,
        };
    }

    fn localParameter(context: Context, name: []const u8) ?*const schema.Parameter {
        var index = context.locals.len;
        while (index > 0) {
            index -= 1;
            const parameter = context.locals[index];
            if (std.mem.eql(u8, parameter.name, name)) return parameter;
        }
        return null;
    }

    fn declarationSymbol(c: *const driver.Compilation, node: hir.NodeId, name: hir.StringId, value: bool) ?*binder.Symbol {
        var current = c.hir.parentOf(node);
        while (current != 0) : (current = c.hir.parentOf(current)) {
            for (c.module.scopes.items) |scope| {
                if (scope.introducing_node != current) continue;
                const symbol = (if (value) scope.values.get(name) else scope.types.get(name)) orelse return null;
                return if (std.mem.indexOfScalar(hir.NodeId, symbol.decls.items, node) != null) symbol else null;
            }
        }
        const symbol = (if (value) c.module.root.values.get(name) else c.module.root.types.get(name)) orelse return null;
        return if (std.mem.indexOfScalar(hir.NodeId, symbol.decls.items, node) != null) symbol else null;
    }

    pub fn declaration(self: *Builder, key: Key) error{OutOfMemory}!*schema.Declaration {
        if (self.declarations.get(key)) |existing| return existing;
        const source = self.sources[key.source];
        const c = source.compilation;
        const kind = c.hir.kindOf(key.node);
        const interface_name = if (kind == .interface_decl) hir.interfaceOf(&c.hir, key.node).name else 0;
        if (interface_name != 0 and c.hir.kindOf(interface_name) == .identifier) {
            const globals = self.globalFragments(key);
            if (globals.len > 1) return self.mergedInterface(globals);
            const name = hir.identifierOf(&c.hir, hir.interfaceOf(&c.hir, key.node).name).name;
            if (declarationSymbol(c, key.node, name, false)) |symbol| {
                if (symbol.decls.items.len > 1) {
                    const fragments = try self.arena.alloc(Key, symbol.decls.items.len);
                    for (symbol.decls.items, fragments) |node, *fragment| fragment.* = .{ .source = key.source, .node = node };
                    return self.mergedInterface(fragments);
                }
            }
        }
        const def = try self.arena.create(schema.Declaration);
        def.* = .{ .path = source.path, .position = c.hir.spanOf(key.node).start, .name = "", .is_class = kind == .class_decl or kind == .class_expr, .is_function = kind == .fn_decl, .is_interface = kind == .interface_decl };
        try self.declarations.put(self.arena, key, def);
        const info: struct { name: hir.NodeId, params: []const hir.NodeId } = switch (kind) {
            .class_decl, .class_expr => blk: {
                const value = hir.classOf(&c.hir, key.node);
                break :blk .{ .name = value.name, .params = c.hir.child_pool.items[value.type_params_start..][0..value.type_params_len] };
            },
            .type_alias_decl => blk: {
                const value = hir.typeAliasOf(&c.hir, key.node);
                break :blk .{ .name = value.name, .params = c.hir.child_pool.items[value.type_params_start..][0..value.type_params_len] };
            },
            .interface_decl => blk: {
                const value = hir.interfaceOf(&c.hir, key.node);
                break :blk .{ .name = value.name, .params = c.hir.child_pool.items[value.type_params_start..][0..value.type_params_len] };
            },
            .fn_decl => blk: {
                const value = hir.fnDeclOf(&c.hir, key.node);
                break :blk .{ .name = value.name, .params = hir.fnTypeParams(&c.hir, key.node) };
            },
            .var_decl, .let_decl, .const_decl => .{ .name = hir.varDeclOf(&c.hir, key.node).name, .params = &.{} },
            else => {
                def.body = try self.expression(.unsupported);
                return def;
            },
        };
        if (info.name != 0 and c.hir.kindOf(info.name) == .identifier) def.name = c.interner.get(hir.identifierOf(&c.hir, info.name).name);
        var overload_declarations: ?[]const hir.NodeId = null;
        if ((kind == .fn_decl or kind == .interface_decl) and info.name != 0 and c.hir.kindOf(info.name) == .identifier) {
            const name = hir.identifierOf(&c.hir, info.name).name;
            const symbol = declarationSymbol(c, key.node, name, kind == .fn_decl);
            if (symbol) |bound| {
                if (bound.decls.items.len != 1 and std.mem.indexOfScalar(hir.NodeId, bound.decls.items, key.node) != null) {
                    if (kind == .fn_decl) {
                        overload_declarations = bound.decls.items;
                    } else {
                        def.body = try self.expression(.unsupported);
                        return def;
                    }
                }
            }
        }
        const declaration_parameters = if (overload_declarations == null) info.params else &.{};
        const jsdoc_parameters = if ((def.is_class or kind == .fn_decl) and declaration_parameters.len == 0 and jsdoc_types.isJavaScriptPath(source.path))
            try jsdoc_types.declarationTemplateParameters(self.gpa, c, key.node)
        else
            null;
        defer if (jsdoc_parameters) |parameters| if (parameters.len > 0) jsdoc_types.deinitTemplateParameters(self.gpa, parameters);
        def.parameters = try self.arena.alloc(schema.Parameter, if (jsdoc_parameters) |parameters| parameters.len else declaration_parameters.len);
        if (jsdoc_parameters) |parameters| {
            for (parameters, def.parameters) |parameter, *param| param.* = .{ .name = parameter.name };
        } else {
            for (declaration_parameters, def.parameters) |node, *param| param.* = .{ .name = c.interner.get(hir.typeParameterOf(&c.hir, node).name) };
        }
        const allow_opaque = switch (kind) {
            .type_alias_decl => switch (c.hir.kindOf(hir.typeAliasOf(&c.hir, key.node).aliased)) {
                .fn_type, .constructor_type => true,
                else => false,
            },
            .interface_decl => blk: {
                for (hir.interfaceMembers(&c.hir, key.node)) |member_node| {
                    if (c.hir.kindOf(member_node) != .interface_member) continue;
                    const member = hir.interfaceMemberOf(&c.hir, member_node);
                    if (std.mem.eql(u8, c.interner.get(member.name), "__call")) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
        const context: Context = .{ .source = key.source, .declaration = def, .allow_opaque = allow_opaque };
        if (jsdoc_parameters) |parameters| {
            for (parameters, def.parameters) |parameter, *param| {
                if (parameter.constraint) |constraint| param.constraint = try self.jsdocTypeInContext(constraint, context);
                if (parameter.default) |default| param.default = try self.jsdocTypeInContext(default, context);
            }
        }
        for (declaration_parameters, def.parameters[0..declaration_parameters.len]) |node, *param| {
            const value = hir.typeParameterOf(&c.hir, node);
            param.variance = value.variance;
            param.is_const = value.is_const;
            if (value.constraint != 0) param.constraint = try self.lowerTransferable(context, value.constraint);
            if (value.default != 0) param.default = try self.lowerContextualDefault(context, value.default);
        }
        def.body = if (kind == .type_alias_decl)
            try self.lower(context, hir.typeAliasOf(&c.hir, key.node).aliased)
        else if (kind == .fn_decl) blk: {
            if (overload_declarations) |declarations|
                break :blk try self.functionOverloadType(context, declarations);
            if (jsdoc_types.isJavaScriptPath(source.path)) {
                if (try jsdoc_types.functionSignature(self.gpa, c, key.node, try self.contextParameterNames(context))) |signature| {
                    defer signature.deinit(self.gpa);
                    break :blk try self.jsdocFunctionType(signature, context);
                }
            }
            break :blk try self.functionType(context, &.{}, hir.fnParams(&c.hir, key.node), hir.fnDeclOf(&c.hir, key.node).return_type, false);
        } else if (kind == .var_decl or kind == .let_decl or kind == .const_decl) blk: {
            const variable = hir.varDeclOf(&c.hir, key.node);
            if (variable.type_annotation == 0 and jsdoc_types.isJavaScriptPath(source.path)) {
                if (try jsdoc_types.declarationType(self.gpa, c, key.node)) |type_expression| {
                    defer type_expression.deinit(self.gpa);
                    break :blk try self.jsdocType(type_expression);
                }
                if (kind == .const_decl) {
                    if (jsdoc_types.widenedInitializerPrimitive(c, variable.init)) |primitive|
                        break :blk try self.expression(.{ .primitive = schemaPrimitive(primitive) });
                }
            }
            if (variable.type_annotation == 0 and variable.init != hir.none_node_id and
                (c.hir.kindOf(variable.init) == .object_literal or c.hir.kindOf(variable.init) == .array_literal))
            {
                var active: std.AutoHashMapUnmanaged(Key, void) = .empty;
                defer active.deinit(self.gpa);
                break :blk try self.inferredInitializerType(context, variable.init, &active);
            }
            if (kind == .const_decl and variable.type_annotation == 0 and
                c.hir.kindOf(variable.init) == .identifier)
            {
                if (try self.importedConstInitializer(context, variable.init)) |imported_type|
                    break :blk imported_type;
            }
            const type_source = if (variable.type_annotation != 0)
                variable.type_annotation
            else if (kind == .const_decl)
                variable.init
            else
                hir.none_node_id;
            break :blk try self.lower(context, type_source);
        } else if (kind == .interface_decl)
            try self.interfaceBody(context, key.node)
        else
            try self.classBody(context, key.node);
        if (def.is_class) {
            def.is_abstract_class = hir.classOf(&c.hir, key.node).is_abstract;
            def.constructors = try self.classConstructors(context, key.node);
        }
        return def;
    }

    fn mergedInterface(self: *Builder, fragments: []const Key) error{OutOfMemory}!*schema.Declaration {
        const first = fragments[0];
        if (self.declarations.get(first)) |existing| return existing;
        const owner = self.sources[first.source];
        const c = owner.compilation;
        const def = try self.arena.create(schema.Declaration);
        def.* = .{ .path = owner.path, .position = c.hir.spanOf(first.node).start, .name = "", .is_interface = true };
        // Publish every fragment identity before lowering recursive members.
        for (fragments) |key| try self.declarations.put(self.arena, key, def);
        var template = first;
        var max_parameters: usize = 0;
        for (fragments) |key| {
            const source = self.sources[key.source].compilation;
            if (source.hir.kindOf(key.node) != .interface_decl) {
                def.body = try self.expression(.unsupported);
                return def;
            }
            const declaration_info = hir.interfaceOf(&source.hir, key.node);
            if (declaration_info.type_params_len > max_parameters) {
                max_parameters = declaration_info.type_params_len;
                template = key;
            }
        }
        def.name = c.interner.get(hir.identifierOf(&c.hir, hir.interfaceOf(&c.hir, first.node).name).name);
        def.parameters = try self.arena.alloc(schema.Parameter, max_parameters);
        const template_source = self.sources[template.source].compilation;
        const template_info = hir.interfaceOf(&template_source.hir, template.node);
        const template_nodes = template_source.hir.child_pool.items[template_info.type_params_start..][0..template_info.type_params_len];
        for (template_nodes, def.parameters) |node, *parameter| parameter.* = .{ .name = template_source.interner.get(hir.typeParameterOf(&template_source.hir, node).name) };
        var minimum_parameters = max_parameters;
        // Merge metadata in source order while resolving each expression in
        // its own lexical scope. All fragments bind the canonical parameters.
        for (fragments) |key| {
            const source = self.sources[key.source].compilation;
            const info = hir.interfaceOf(&source.hir, key.node);
            minimum_parameters = @min(minimum_parameters, info.type_params_len);
            const context: Context = .{ .source = key.source, .declaration = def, .visible_parameters = def.parameters[0..info.type_params_len] };
            for (source.hir.child_pool.items[info.type_params_start..][0..info.type_params_len], 0..) |node, index| {
                const value = hir.typeParameterOf(&source.hir, node);
                const parameter = &def.parameters[index];
                if (!std.mem.eql(u8, source.interner.get(value.name), parameter.name)) {
                    def.body = try self.expression(.unsupported);
                    return def;
                }
                parameter.variance = value.variance;
                parameter.is_const = value.is_const;
                if (value.constraint != 0 and parameter.constraint == null) parameter.constraint = try self.lowerTransferable(context, value.constraint);
                if (value.default != 0 and parameter.default == null) parameter.default = try self.lowerContextualDefault(context, value.default);
            }
        }
        for (def.parameters[minimum_parameters..]) |parameter| if (parameter.default == null) {
            def.body = try self.expression(.unsupported);
            return def;
        };
        var members: std.ArrayListUnmanaged(schema.Member) = .empty;
        var indices: std.ArrayListUnmanaged(schema.IndexSignature) = .empty;
        var bases: std.ArrayListUnmanaged(*const schema.Expression) = .empty;
        // Later declaration groups have overload priority; signatures within
        // each group keep their source order. Retain separate method slots
        // so the checker sees an ordered overload set, not a sorted type union.
        for (0..fragments.len) |fragment_index| {
            const key = fragments[fragments.len - 1 - fragment_index];
            const source = self.sources[key.source].compilation;
            const context: Context = .{ .source = key.source, .declaration = def, .visible_parameters = def.parameters[0..hir.interfaceOf(&source.hir, key.node).type_params_len] };
            const own = try self.object(context, hir.interfaceMembers(&source.hir, key.node));
            const own_members = switch (own.*) {
                .object => |value| value,
                .indexed_object => |value| blk: {
                    try indices.appendSlice(self.arena, value.indices);
                    break :blk value.members;
                },
                else => {
                    def.body = try self.expression(.unsupported);
                    return def;
                },
            };
            for (own_members) |member| {
                var duplicate = false;
                for (members.items) |*existing| {
                    if (!std.mem.eql(u8, existing.name, member.name)) continue;
                    if (existing.method and member.method) continue;
                    // Data properties retain the first declaration's type,
                    // including when skipLibCheck suppresses a conflict.
                    existing.* = member;
                    duplicate = true;
                    break;
                }
                if (!duplicate) try members.append(self.arena, member);
            }
            for (hir.interfaceExtends(&source.hir, key.node)) |base| try bases.append(self.arena, try self.lower(context, base));
        }
        const own = if (indices.items.len == 0)
            try self.expression(.{ .object = try members.toOwnedSlice(self.arena) })
        else
            try self.expression(.{ .indexed_object = .{ .members = try members.toOwnedSlice(self.arena), .indices = try indices.toOwnedSlice(self.arena) } });
        def.interface_own_body = own;
        if (bases.items.len == 0) def.body = own else {
            try bases.append(self.arena, own);
            def.body = try self.expression(.{ .intersection = try bases.toOwnedSlice(self.arena) });
        }
        return def;
    }

    /// A source-owned const initialized from a named import has the imported
    /// value's type. Retain the resolved declaration identity across the
    /// Program boundary; an unsupported or ambiguous owner stays unsupported
    /// instead of manufacturing an `any` type for the consumer.
    fn importedConstInitializer(self: *Builder, context: Context, node: hir.NodeId) !?*const schema.Expression {
        const c = self.sources[context.source].compilation;
        const name = hir.identifierOf(&c.hir, node).name;
        const bound = self.scopedValueSymbol(context.source, node, name) orelse return null;
        if (!bound.flags.is_import) return null;
        const imported = importForSymbol(c, bound) orelse return null;
        if (imported.namespace or imported.is_type_only) return null;
        const specifier = c.interner.get(hir.importOf(&c.hir, imported.node).module);
        const resolved = try self.resolveImportedValue(context.source, specifier, imported.name);
        return switch (resolved) {
            .declaration => |key| blk: {
                const target = try self.declaration(key);
                // A value-initializer cycle has no inferred type to transfer.
                // Type aliases can be recursive, but `const a = b; const b = a`
                // is not a productive value declaration.
                if (target.body == null) break :blk null;
                break :blk try self.expression(.{ .reference = .{
                    .declaration = target,
                    .arguments = &.{},
                } });
            },
            .missing, .external, .unsupported => null,
        };
    }

    fn classConstructors(self: *Builder, context: Context, node: hir.NodeId) !?*const schema.Expression {
        const c = self.sources[context.source].compilation;
        var overloads: usize = 0;
        for (hir.classMembers(&c.hir, node)) |member| {
            if (c.hir.kindOf(member) != .fn_decl and c.hir.kindOf(member) != .fn_expr and c.hir.kindOf(member) != .arrow_fn) continue;
            const function = hir.fnDeclOf(&c.hir, member);
            if (function.flags.is_constructor and function.body == 0) overloads += 1;
        }
        var signatures: std.ArrayListUnmanaged(*const schema.Expression) = .empty;
        for (hir.classMembers(&c.hir, node)) |member| {
            if (c.hir.kindOf(member) != .fn_decl and c.hir.kindOf(member) != .fn_expr and c.hir.kindOf(member) != .arrow_fn) continue;
            const function = hir.fnDeclOf(&c.hir, member);
            if (!function.flags.is_constructor or (overloads != 0 and function.body != 0)) continue;
            var signature = try self.functionType(context, &.{}, hir.fnParams(&c.hir, member), 0, true);
            if (context.declaration.parameters.len > 0 and jsdoc_types.isJavaScriptPath(self.sources[context.source].path)) {
                const parameter_names = try self.contextParameterNames(context);
                if (try jsdoc_types.constructorParameters(self.gpa, c, member, parameter_names)) |jsdoc_parameters| {
                    defer jsdoc_types.deinitFunctionParameters(self.gpa, jsdoc_parameters);
                    const elements = try self.arena.alloc(schema.Element, jsdoc_parameters.len);
                    for (jsdoc_parameters, elements) |parameter, *out| out.* = .{
                        .type = try self.jsdocTypeInContext(parameter.type_expression, context),
                        .optional = parameter.optional,
                        .rest = parameter.rest,
                    };
                    signature = try self.expression(.{ .function = .{
                        .parameters = elements,
                        .result = try self.expression(.{ .primitive = Primitive.any }),
                        .is_construct = true,
                    } });
                }
            }
            var constructor = signature.function;
            constructor.construct_visibility = if (function.flags.is_private) .private else if (function.flags.is_protected) .protected else .public;
            constructor.result = try self.expression(.{ .primitive = Primitive.any });
            try signatures.append(self.arena, try self.expression(.{ .function = constructor }));
        }
        if (signatures.items.len == 1) return signatures.items[0];
        if (signatures.items.len > 1) return self.expression(.{ .intersection = try signatures.toOwnedSlice(self.arena) });
        // An implicit derived constructor inherits the base's signatures,
        // instantiated with the exact heritage arguments. Keep that source
        // identity until the consuming checker can lower the base signature.
        if (hir.classOf(&c.hir, node).extends != 0) {
            const base = try self.classHeritage(context, hir.classOf(&c.hir, node).extends);
            if (base.* != .reference or !base.reference.declaration.is_class) return null;
            return self.expression(.{ .inherited_constructors = base.reference });
        }
        return self.expression(.{ .function = .{ .parameters = &.{}, .result = try self.expression(.{ .primitive = Primitive.any }), .is_construct = true } });
    }

    fn functionOverloadType(
        self: *Builder,
        context: Context,
        declarations: []const hir.NodeId,
    ) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        var signatures: std.ArrayListUnmanaged(*const schema.Expression) = .empty;
        for (declarations) |node| {
            if (c.hir.kindOf(node) != .fn_decl) return self.expression(.unsupported);
            const function = hir.fnDeclOf(&c.hir, node);
            if (function.body != hir.none_node_id) continue;
            try signatures.append(self.arena, try self.functionType(
                context,
                hir.fnTypeParams(&c.hir, node),
                hir.fnParams(&c.hir, node),
                function.return_type,
                false,
            ));
        }
        if (signatures.items.len == 0) return self.expression(.unsupported);
        if (signatures.items.len == 1) return signatures.items[0];
        return self.expression(.{ .intersection = try signatures.toOwnedSlice(self.arena) });
    }

    fn jsdocFunctionType(self: *Builder, signature: jsdoc_types.FunctionSignature, context: Context) !*const schema.Expression {
        const parameters = try self.arena.alloc(schema.Element, signature.parameters.len);
        for (signature.parameters, parameters) |parameter, *result| {
            result.* = .{
                .type = try self.jsdocTypeInContext(parameter.type_expression, context),
                .optional = parameter.optional,
                .rest = parameter.rest,
            };
        }
        return self.expression(.{ .function = .{
            .parameters = parameters,
            .result = try self.jsdocTypeInContext(signature.result, context),
        } });
    }

    fn jsdocType(self: *Builder, type_expression: jsdoc_types.TypeExpression) !*const schema.Expression {
        return self.jsdocTypeInContext(type_expression, null);
    }

    fn jsdocTypeInContext(self: *Builder, type_expression: jsdoc_types.TypeExpression, context: ?Context) !*const schema.Expression {
        var result = switch (type_expression.base) {
            .primitive => |primitive| try self.expression(.{ .primitive = schemaPrimitive(primitive) }),
            .string_literal => |value| try self.expression(.{ .string = try self.arena.dupe(u8, value) }),
            .number_literal => |number| try self.expression(.{ .number = number }),
            .boolean_literal => |boolean| try self.expression(.{ .boolean = boolean }),
            .parameter => |name| blk: {
                if (context) |ctx| {
                    for (ctx.declaration.parameters) |*parameter| {
                        if (std.mem.eql(u8, parameter.name, name))
                            break :blk try self.expression(.{ .parameter = parameter });
                    }
                }
                break :blk try self.expression(.unsupported);
            },
            .unsupported => try self.expression(.unsupported),
            .union_type => |members| union_expression: {
                const expressions = try self.arena.alloc(*const schema.Expression, members.len);
                for (members, expressions) |member, *out| out.* = try self.jsdocTypeInContext(member, context);
                break :union_expression try self.expression(.{ .union_type = expressions });
            },
            .object_type => |members| object_expression: {
                const expressions = try self.arena.alloc(schema.Member, members.len);
                for (members, expressions) |member, *out| out.* = .{
                    .name = try self.arena.dupe(u8, member.name),
                    .type = try self.jsdocTypeInContext(member.type_expression, context),
                    .optional = member.optional,
                    .readonly = member.readonly,
                };
                break :object_expression try self.expression(.{ .object = expressions });
            },
            .indexed_object => |indexed| object_expression: {
                const members = try self.arena.alloc(schema.Member, indexed.members.len);
                for (indexed.members, members) |member, *out| out.* = .{
                    .name = try self.arena.dupe(u8, member.name),
                    .type = try self.jsdocTypeInContext(member.type_expression, context),
                    .optional = member.optional,
                    .readonly = member.readonly,
                };
                const indices = try self.arena.alloc(schema.IndexSignature, indexed.indices.len);
                for (indexed.indices, indices) |index, *out| out.* = .{
                    .name = try self.arena.dupe(u8, index.name),
                    .key = try self.jsdocTypeInContext(index.key, context),
                    .value = try self.jsdocTypeInContext(index.value, context),
                    .readonly = index.readonly,
                };
                break :object_expression try self.expression(.{ .indexed_object = .{
                    .members = members,
                    .indices = indices,
                } });
            },
        };
        var index = type_expression.containers.len;
        while (index > 0) {
            index -= 1;
            result = try self.expression(switch (type_expression.containers[index]) {
                .array => .{ .array = result },
                .readonly_array => .{ .readonly_array = result },
            });
        }
        return result;
    }

    fn contextParameterNames(self: *Builder, context: Context) ![]const []const u8 {
        const names = try self.arena.alloc([]const u8, context.declaration.parameters.len);
        for (context.declaration.parameters, names) |parameter, *out| out.* = parameter.name;
        return names;
    }

    fn classFieldJSDocType(self: *Builder, context: Context, member: hir.NodeId) !?*const schema.Expression {
        const source = self.sources[context.source];
        if (!jsdoc_types.isJavaScriptPath(source.path)) return null;
        const parameter_names = try self.contextParameterNames(context);
        const type_expression = try jsdoc_types.declarationTypeWithParameters(self.gpa, source.compilation, member, parameter_names) orelse return null;
        defer type_expression.deinit(self.gpa);
        return try self.jsdocTypeInContext(type_expression, context);
    }

    fn interfaceBody(self: *Builder, context: Context, node: hir.NodeId) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        const own = try self.object(context, hir.interfaceMembers(&c.hir, node));
        context.declaration.interface_own_body = own;
        const bases = hir.interfaceExtends(&c.hir, node);
        if (bases.len == 0) return own;
        const members = try self.arena.alloc(*const schema.Expression, bases.len + 1);
        for (bases, members[0..bases.len]) |base, *result| result.* = try self.lower(context, base);
        members[bases.len] = own;
        return self.expression(.{ .intersection = members });
    }

    /// A setter-only member reads and writes through this annotated input.
    fn accessorSetterType(self: *Builder, context: Context, setter_node: hir.NodeId) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        const params = hir.fnParams(&c.hir, setter_node);
        if (params.len != 1 or c.hir.kindOf(params[0]) != .parameter) return self.expression(.unsupported);
        const param = hir.parameterOf(&c.hir, params[0]);
        if (param.type_annotation == hir.none_node_id or param.flags.is_optional or param.flags.is_rest)
            return self.expression(.unsupported);
        return self.lower(context, param.type_annotation);
    }

    /// Determine whether this setter is instead paired with a getter.
    fn hasAccessorGetter(self: *Builder, context: Context, class_node: hir.NodeId, accessor_name: []const u8, is_static: bool) bool {
        const c = self.sources[context.source].compilation;
        for (hir.classMembers(&c.hir, class_node)) |candidate| {
            switch (c.hir.kindOf(candidate)) {
                .fn_decl, .fn_expr, .arrow_fn => {},
                else => continue,
            }
            const function = hir.fnDeclOf(&c.hir, candidate);
            if (!function.flags.is_getter or function.flags.is_static != is_static or
                function.name == hir.none_node_id or c.hir.kindOf(function.name) != .identifier) continue;
            if (std.mem.eql(u8, c.interner.get(hir.identifierOf(&c.hir, function.name).name), accessor_name)) return true;
        }
        return false;
    }

    /// Pair an annotated getter with its setter before publishing either
    /// side. Setter inputs are independent of the getter's read type.
    fn pairedAccessorWriteType(self: *Builder, context: Context, class_node: hir.NodeId, getter_name: []const u8, is_static: bool) !?*const schema.Expression {
        const c = self.sources[context.source].compilation;
        var result: ?*const schema.Expression = null;
        for (hir.classMembers(&c.hir, class_node)) |candidate| {
            switch (c.hir.kindOf(candidate)) {
                .fn_decl, .fn_expr, .arrow_fn => {},
                else => continue,
            }
            const function = hir.fnDeclOf(&c.hir, candidate);
            if (!function.flags.is_setter or function.flags.is_static != is_static or
                function.name == hir.none_node_id or c.hir.kindOf(function.name) != .identifier) continue;
            const name = c.interner.get(hir.identifierOf(&c.hir, function.name).name);
            if (!std.mem.eql(u8, name, getter_name)) continue;
            if (result != null) return self.expression(.unsupported);
            result = try self.accessorSetterType(context, candidate);
        }
        return result;
    }

    fn hasWritableAccessor(members: []const schema.Member, name: []const u8) bool {
        for (members) |member| {
            if (std.mem.eql(u8, member.name, name) and member.write_type != null) return true;
        }
        return false;
    }

    fn memberCount(members: []const schema.Member, name: []const u8) usize {
        var count: usize = 0;
        for (members) |member| {
            if (std.mem.eql(u8, member.name, name)) count += 1;
        }
        return count;
    }

    pub fn classStaticMembers(self: *Builder, key: Key) !?[]const schema.Member {
        const c = self.sources[key.source].compilation;
        const source_decl = try self.declaration(key);
        const context: Context = .{ .source = key.source, .declaration = source_decl };
        var members: std.ArrayListUnmanaged(schema.Member) = .empty;
        for (hir.classMembers(&c.hir, key.node)) |member| {
            const kind = c.hir.kindOf(member);
            const is_static = switch (kind) {
                .object_property => hir.objectPropertyOf(&c.hir, member).is_static,
                .fn_decl, .fn_expr, .arrow_fn => hir.fnDeclOf(&c.hir, member).flags.is_static,
                else => false,
            };
            if (!is_static) continue;
            const name_node = switch (kind) {
                .object_property => hir.objectPropertyOf(&c.hir, member).key,
                .fn_decl, .fn_expr, .arrow_fn => hir.fnDeclOf(&c.hir, member).name,
                else => unreachable,
            };
            if (c.hir.kindOf(name_node) != .identifier) return null;
            const name = c.interner.get(hir.identifierOf(&c.hir, name_node).name);
            const is_setter = kind != .object_property and hir.fnDeclOf(&c.hir, member).flags.is_setter;
            const setter_only = is_setter and !self.hasAccessorGetter(context, key.node, name, true);
            if (is_setter and !setter_only) continue;
            if (setter_only and hasMember(members.items, name)) return null;
            const write_type = if (setter_only)
                try self.accessorSetterType(context, member)
            else if (kind != .object_property and hir.fnDeclOf(&c.hir, member).flags.is_getter)
                try self.pairedAccessorWriteType(context, key.node, name, true)
            else
                null;
            const type_expression = if (setter_only) write_type.? else switch (kind) {
                .object_property => blk: {
                    const property = hir.objectPropertyOf(&c.hir, member);
                    if (property.is_computed) return null;
                    if (try self.classFieldJSDocType(context, member)) |jsdoc_type| break :blk jsdoc_type;
                    if (property.type_annotation == hir.none_node_id) return null;
                    break :blk try self.lower(context, property.type_annotation);
                },
                .fn_decl, .fn_expr, .arrow_fn => blk: {
                    const function = hir.fnDeclOf(&c.hir, member);
                    if (function.flags.is_getter) {
                        if (function.return_type == hir.none_node_id or hir.fnParams(&c.hir, member).len != 0) return null;
                        break :blk try self.lower(context, function.return_type);
                    }
                    break :blk try self.functionType(context, hir.fnTypeParams(&c.hir, member), hir.fnParams(&c.hir, member), function.return_type, false);
                },
                else => unreachable,
            };
            if (!try schema.Schema.expressionSupported(type_expression, self.gpa)) return null;
            if (write_type) |setter_type| if (!try schema.Schema.expressionSupported(setter_type, self.gpa)) return null;
            try members.append(self.arena, .{
                .name = name,
                .type = type_expression,
                .write_type = write_type,
                .optional = if (kind == .object_property) hir.objectPropertyOf(&c.hir, member).is_optional else hir.fnDeclOf(&c.hir, member).flags.is_optional,
                .readonly = if (kind == .object_property) hir.objectPropertyOf(&c.hir, member).is_readonly else hir.fnDeclOf(&c.hir, member).flags.is_getter and write_type == null,
                .method = kind != .object_property and !hir.fnDeclOf(&c.hir, member).flags.is_getter and !setter_only,
                .visibility = if (kind == .object_property) switch (hir.objectPropertyOf(&c.hir, member).visibility) {
                    .public => .public,
                    .private => .private,
                    .protected => .protected,
                } else if (hir.fnDeclOf(&c.hir, member).flags.is_private) .private else if (hir.fnDeclOf(&c.hir, member).flags.is_protected) .protected else .public,
            });
        }
        for (hir.classMembers(&c.hir, key.node)) |member| {
            switch (c.hir.kindOf(member)) {
                .fn_decl, .fn_expr, .arrow_fn => {},
                else => continue,
            }
            const function = hir.fnDeclOf(&c.hir, member);
            if (!function.flags.is_static or !function.flags.is_setter) continue;
            if (function.name == hir.none_node_id or c.hir.kindOf(function.name) != .identifier or
                !hasWritableAccessor(members.items, c.interner.get(hir.identifierOf(&c.hir, function.name).name))) return null;
            const name = c.interner.get(hir.identifierOf(&c.hir, function.name).name);
            if (!self.hasAccessorGetter(context, key.node, name, true) and memberCount(members.items, name) != 1) return null;
        }
        return try members.toOwnedSlice(self.arena);
    }

    /// Preserve independently typed checked-JS static fields even when an
    /// unrelated static method cannot enter the complete schema surface.
    pub fn classStaticJSDocFieldMembers(self: *Builder, key: Key) !?[]const schema.Member {
        const source = self.sources[key.source];
        if (!jsdoc_types.isJavaScriptPath(source.path)) return null;
        const c = source.compilation;
        const source_decl = try self.declaration(key);
        const context: Context = .{ .source = key.source, .declaration = source_decl };
        var members: std.ArrayListUnmanaged(schema.Member) = .empty;
        for (hir.classMembers(&c.hir, key.node)) |member| {
            if (c.hir.kindOf(member) != .object_property) continue;
            const property = hir.objectPropertyOf(&c.hir, member);
            if (!property.is_static or property.is_computed) continue;
            if (c.hir.kindOf(property.key) != .identifier) continue;
            const type_expression = (try self.classFieldJSDocType(context, member)) orelse continue;
            if (!try schema.Schema.expressionSupported(type_expression, self.gpa)) continue;
            try members.append(self.arena, .{
                .name = c.interner.get(hir.identifierOf(&c.hir, property.key).name),
                .type = type_expression,
                .optional = property.is_optional,
                .readonly = property.is_readonly,
                .visibility = switch (property.visibility) {
                    .public => .public,
                    .private => .private,
                    .protected => .protected,
                },
            });
        }
        if (members.items.len == 0) return null;
        return try members.toOwnedSlice(self.arena);
    }

    fn classBody(self: *Builder, context: Context, node: hir.NodeId) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        var members: std.ArrayListUnmanaged(schema.Member) = .empty;
        for (hir.classMembers(&c.hir, node)) |member| {
            switch (c.hir.kindOf(member)) {
                .object_property => {
                    const property = hir.objectPropertyOf(&c.hir, member);
                    if (property.is_static) continue;
                    const name = switch (c.hir.kindOf(property.key)) {
                        .identifier => c.interner.get(hir.identifierOf(&c.hir, property.key).name),
                        .literal_string => c.interner.get(hir.literalStringOf(&c.hir, property.key).value),
                        else => return self.expression(.unsupported),
                    };
                    if (property.is_method) return self.expression(.unsupported);
                    if (std.mem.startsWith(u8, name, "#")) {
                        try members.append(self.arena, .{ .name = name, .type = try self.expression(.unsupported), .visibility = .private });
                        continue;
                    }
                    // A declared JSDoc type governs a checked-JS field even
                    // when its initializer is `any` or a different literal.
                    // Otherwise use the owner's checked field type, not a
                    // guess from the initializer expression.
                    const field_type = (try self.classFieldJSDocType(context, member)) orelse try self.lower(context, property.type_annotation);
                    try members.append(self.arena, .{ .name = name, .type = field_type, .optional = property.is_optional, .readonly = property.is_readonly, .visibility = switch (property.visibility) {
                        .public => .public,
                        .private => .private,
                        .protected => .protected,
                    } });
                },
                .fn_decl, .fn_expr, .arrow_fn => {
                    const function = hir.fnDeclOf(&c.hir, member);
                    if (function.flags.is_static) continue;
                    const params = c.hir.child_pool.items[function.params_start..][0..function.params_len];
                    if (function.flags.is_constructor) {
                        for (params) |param| if (hir.parameterOf(&c.hir, param).flags.is_parameter_property) return self.expression(.unsupported);
                        continue;
                    }
                    if (function.name == 0) return self.expression(.unsupported);
                    if (c.hir.kindOf(function.name) != .identifier) return self.expression(.unsupported);
                    if (function.flags.is_setter) {
                        const name = c.interner.get(hir.identifierOf(&c.hir, function.name).name);
                        if (self.hasAccessorGetter(context, node, name, false)) continue;
                        if (hasMember(members.items, name)) return self.expression(.unsupported);
                        const setter_type = try self.accessorSetterType(context, member);
                        if (!try schema.Schema.expressionSupported(setter_type, self.gpa)) return self.expression(.unsupported);
                        try members.append(self.arena, .{
                            .name = name,
                            .type = setter_type,
                            .write_type = setter_type,
                            .visibility = if (function.flags.is_private) .private else if (function.flags.is_protected) .protected else .public,
                        });
                        continue;
                    }
                    if (function.flags.is_getter) {
                        if (function.return_type == hir.none_node_id or params.len != 0) return self.expression(.unsupported);
                        const name = c.interner.get(hir.identifierOf(&c.hir, function.name).name);
                        const write_type = try self.pairedAccessorWriteType(context, node, name, false);
                        try members.append(self.arena, .{
                            .name = name,
                            .type = try self.lower(context, function.return_type),
                            .write_type = write_type,
                            .readonly = write_type == null,
                            .visibility = if (function.flags.is_private) .private else if (function.flags.is_protected) .protected else .public,
                        });
                        continue;
                    }
                    try members.append(self.arena, .{ .name = c.interner.get(hir.identifierOf(&c.hir, function.name).name), .type = try self.functionType(context, hir.fnTypeParams(&c.hir, member), params, function.return_type, false), .method = true, .optional = function.flags.is_optional, .visibility = if (function.flags.is_private) .private else if (function.flags.is_protected) .protected else .public });
                },
                .index_signature => return self.expression(.unsupported),
                else => {},
            }
        }
        for (hir.classMembers(&c.hir, node)) |member| {
            switch (c.hir.kindOf(member)) {
                .fn_decl, .fn_expr, .arrow_fn => {},
                else => continue,
            }
            const function = hir.fnDeclOf(&c.hir, member);
            if (function.flags.is_static or !function.flags.is_setter) continue;
            if (function.name == hir.none_node_id or c.hir.kindOf(function.name) != .identifier or
                !hasWritableAccessor(members.items, c.interner.get(hir.identifierOf(&c.hir, function.name).name)))
                return self.expression(.unsupported);
            const name = c.interner.get(hir.identifierOf(&c.hir, function.name).name);
            if (!self.hasAccessorGetter(context, node, name, false) and memberCount(members.items, name) != 1)
                return self.expression(.unsupported);
        }
        if (jsdoc_types.isJavaScriptPath(self.sources[context.source].path)) {
            const parameter_names = try self.contextParameterNames(context);
            for (hir.classMembers(&c.hir, node)) |member| {
                switch (c.hir.kindOf(member)) {
                    .fn_decl, .fn_expr, .arrow_fn => {
                        const function = hir.fnDeclOf(&c.hir, member);
                        if (!function.flags.is_constructor) continue;
                        const fields = try jsdoc_types.constructorAssignedFields(self.gpa, c, member, parameter_names);
                        defer jsdoc_types.deinitAssignedFields(self.gpa, fields);
                        for (fields) |field| {
                            if (hasMember(members.items, field.name)) continue;
                            try members.append(self.arena, .{
                                .name = field.name,
                                .type = try self.jsdocTypeInContext(field.type_expression, context),
                            });
                        }
                    },
                    else => {},
                }
            }
        }
        const own = try self.expression(.{ .object = try members.toOwnedSlice(self.arena) });
        const base = hir.classOf(&c.hir, node).extends;
        if (base == 0) return own;
        return self.expression(.{ .intersection = try self.arena.dupe(*const schema.Expression, &.{
            try self.classHeritage(context, base),
            own,
        }) });
    }

    fn hasMember(members: []const schema.Member, name: []const u8) bool {
        for (members) |member| if (std.mem.eql(u8, member.name, name)) return true;
        return false;
    }

    fn schemaPrimitive(primitive: jsdoc_types.Primitive) hir.TypeId {
        return switch (primitive) {
            .any => Primitive.any,
            .unknown => Primitive.unknown,
            .never => Primitive.never,
            .void_t => Primitive.void_t,
            .null_t => Primitive.null_t,
            .undefined_t => Primitive.undefined_t,
            .string_t => Primitive.string_t,
            .number_t => Primitive.number_t,
            .boolean_t => Primitive.boolean_t,
            .bigint_t => Primitive.bigint_t,
            .symbol_t => Primitive.symbol_t,
            .object_t => Primitive.object_t,
        };
    }

    fn classHeritage(self: *Builder, context: Context, node: hir.NodeId) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        if (c.hir.kindOf(node) == .type_ref) return self.lower(context, node);
        if (c.hir.kindOf(node) != .identifier) return self.expression(.unsupported);
        const name = hir.identifierOf(&c.hir, node).name;
        return switch (try self.resolve(context.source, node, name)) {
            .declaration => |key| self.expression(.{ .reference = .{
                .declaration = try self.declaration(key),
                .arguments = &.{},
            } }),
            .missing => if (builtin_object_type_name_set.has(c.interner.get(name)))
                self.expression(.{ .builtin_object = c.interner.get(name) })
            else
                self.expression(.unsupported),
            .external, .unsupported => self.expression(.unsupported),
        };
    }

    fn object(self: *Builder, context: Context, nodes: []const hir.NodeId) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        var members: std.ArrayListUnmanaged(schema.Member) = .empty;
        var indices: std.ArrayListUnmanaged(schema.IndexSignature) = .empty;
        for (nodes) |node| {
            switch (c.hir.kindOf(node)) {
                .interface_member => {
                    const member = hir.interfaceMemberOf(&c.hir, node);
                    if (member.name == 0) return self.expression(.unsupported);
                    try members.append(self.arena, .{ .name = c.interner.get(member.name), .type = try self.lower(context, member.type_node), .optional = member.is_optional, .readonly = member.is_readonly, .method = member.is_method });
                },
                .index_signature => {
                    const index = hir.indexSignatureOf(&c.hir, node);
                    try indices.append(self.arena, .{
                        .name = if (index.key_name == 0) "" else c.interner.get(index.key_name),
                        .key = try self.lower(context, index.key_type),
                        .value = try self.lower(context, index.value_type),
                        .readonly = index.is_readonly,
                    });
                },
                else => return self.expression(.unsupported),
            }
        }
        const owned_members = try members.toOwnedSlice(self.arena);
        if (indices.items.len == 0) return self.expression(.{ .object = owned_members });
        return self.expression(.{ .indexed_object = .{
            .members = owned_members,
            .indices = try indices.toOwnedSlice(self.arena),
        } });
    }

    /// A const binding cannot change between its initializer and a shorthand
    /// property read. TypeScript keeps an initialized string/number literal
    /// when its annotation contains that literal but not the corresponding
    /// broad primitive. Other union arms may have different primitive domains:
    /// `'ready' | number` still reads as `'ready'`, while `'ready' | string`
    /// widens to string. This graph is built before checking, so decline
    /// symbolic/object arms whose relationship to the literal is unresolved.
    fn constUnionMember(self: *Builder, context: Context, initializer: hir.NodeId, declared: *const schema.Expression) error{OutOfMemory}!?*const schema.Expression {
        const c = self.sources[context.source].compilation;
        if (declared.* != .union_type) return null;
        const kind = c.hir.kindOf(initializer);
        if (kind != .literal_string and kind != .literal_number) return null;
        const literal = try self.lower(context, initializer);
        const broad_primitive = switch (literal.*) {
            .string => Primitive.string_t,
            .number => Primitive.number_t,
            else => return null,
        };
        var found = false;
        for (declared.union_type) |member| {
            switch (member.*) {
                .string => |value| {
                    if (literal.* == .string and std.mem.eql(u8, value, literal.string)) found = true;
                },
                .number => |value| {
                    if (literal.* == .number and value == literal.number) found = true;
                },
                .boolean => {},
                .primitive => |primitive| {
                    if (primitive == broad_primitive) return null;
                    switch (primitive) {
                        Primitive.string_t,
                        Primitive.number_t,
                        Primitive.boolean_t,
                        Primitive.bigint_t,
                        Primitive.symbol_t,
                        Primitive.null_t,
                        Primitive.undefined_t,
                        Primitive.void_t,
                        Primitive.never,
                        => {},
                        else => return null,
                    }
                },
                else => return null,
            }
        }
        return if (found) literal else null;
    }

    /// Transfer the exact, closed shape of a data initializer. A mutable
    /// property widens its literal value in both TypeScript and JavaScript;
    /// computed/dynamic members cannot be represented by a finite schema, so
    /// they invalidate the whole inferred value rather than publishing a
    /// misleading subset of its members.
    fn inferredInitializerType(self: *Builder, context: Context, node: hir.NodeId, active: *std.AutoHashMapUnmanaged(Key, void)) error{OutOfMemory}!*const schema.Expression {
        const c = self.sources[context.source].compilation;
        if (node == hir.none_node_id) return self.expression(.unsupported);
        switch (c.hir.kindOf(node)) {
            .literal_string, .template_literal => return self.expression(.{ .primitive = Primitive.string_t }),
            .literal_number => return self.expression(.{ .primitive = Primitive.number_t }),
            .literal_bigint => return self.expression(.{ .primitive = Primitive.bigint_t }),
            .literal_bool => return self.expression(.{ .primitive = Primitive.boolean_t }),
            .literal_null => return self.expression(.{ .primitive = Primitive.null_t }),
            .literal_undefined => return self.expression(.{ .primitive = Primitive.undefined_t }),
            .identifier => {
                const name = hir.identifierOf(&c.hir, node).name;
                const bound = self.scopedValueSymbol(context.source, node, name) orelse return self.expression(.unsupported);
                if (bound.flags.is_import or bound.decls.items.len != 1) return self.expression(.unsupported);
                const declaration_node = bound.decls.items[0];
                const kind = c.hir.kindOf(declaration_node);
                if (kind != .var_decl and kind != .let_decl and kind != .const_decl) return self.expression(.unsupported);
                const variable = hir.varDeclOf(&c.hir, declaration_node);
                if (c.hir.kindOf(variable.name) != .identifier or
                    hir.identifierOf(&c.hir, variable.name).name != name) return self.expression(.unsupported);
                const key: Key = .{ .source = context.source, .node = declaration_node };
                if (active.contains(key)) return self.expression(.unsupported);
                try active.put(self.gpa, key, {});
                defer _ = active.remove(key);
                if (variable.type_annotation != hir.none_node_id) {
                    const declared = try self.lower(context, variable.type_annotation);
                    if (kind == .const_decl and variable.init != hir.none_node_id)
                        if (try self.constUnionMember(context, variable.init, declared)) |member| return member;
                    return declared;
                }
                if (jsdoc_types.isJavaScriptPath(self.sources[context.source].path)) {
                    if (try jsdoc_types.declarationType(self.gpa, c, declaration_node)) |type_expression| {
                        defer type_expression.deinit(self.gpa);
                        const declared = try self.jsdocType(type_expression);
                        if (kind == .const_decl and variable.init != hir.none_node_id)
                            if (try self.constUnionMember(context, variable.init, declared)) |member| return member;
                        return declared;
                    }
                }
                return self.inferredInitializerType(context, variable.init, active);
            },
            .object_literal => {
                var members: std.ArrayListUnmanaged(schema.Member) = .empty;
                for (hir.objectLiteralProps(&c.hir, node)) |property_node| {
                    if (c.hir.kindOf(property_node) != .object_property) return self.expression(.unsupported);
                    const property = hir.objectPropertyOf(&c.hir, property_node);
                    if (property.is_method or property.is_computed or
                        property.value == hir.none_node_id or property.type_annotation != hir.none_node_id)
                        return self.expression(.unsupported);
                    const name = switch (c.hir.kindOf(property.key)) {
                        .identifier => c.interner.get(hir.identifierOf(&c.hir, property.key).name),
                        .literal_string => name: {
                            const decoded = try self.lower(context, property.key);
                            break :name if (decoded.* == .string) decoded.string else return self.expression(.unsupported);
                        },
                        else => return self.expression(.unsupported),
                    };
                    const value = try self.inferredInitializerType(context, property.value, active);
                    if (value.* == .unsupported) return value;
                    var previous: ?*schema.Member = null;
                    for (members.items) |*member| if (std.mem.eql(u8, member.name, name)) {
                        previous = member;
                        break;
                    };
                    const next: schema.Member = .{ .name = name, .type = value };
                    if (previous) |member| member.* = next else try members.append(self.arena, next);
                }
                return self.expression(.{ .object = try members.toOwnedSlice(self.arena) });
            },
            .array_literal => {
                const elements = hir.arrayLiteralElements(&c.hir, node);
                if (elements.len == 0) return self.expression(.unsupported);
                const types = try self.arena.alloc(*const schema.Expression, elements.len);
                for (elements, types) |element, *value| {
                    value.* = try self.inferredInitializerType(context, element, active);
                    if (value.*.* == .unsupported) return value.*;
                }
                const element_type = if (types.len == 1) types[0] else try self.expression(.{ .union_type = types });
                return self.expression(.{ .array = element_type });
            },
            else => return self.expression(.unsupported),
        }
    }

    fn functionType(
        self: *Builder,
        context: Context,
        type_parameter_nodes: []const hir.NodeId,
        nodes: []const hir.NodeId,
        result: hir.NodeId,
        is_construct: bool,
    ) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        const type_parameters = try self.arena.alloc(schema.Parameter, type_parameter_nodes.len);
        const type_parameter_refs = try self.arena.alloc(*const schema.Parameter, type_parameter_nodes.len);
        for (type_parameter_nodes, type_parameters, type_parameter_refs) |node, *parameter, *parameter_ref| {
            parameter.* = .{ .name = c.interner.get(hir.typeParameterOf(&c.hir, node).name) };
            parameter_ref.* = parameter;
        }
        const function_context = try self.extendContext(context, type_parameter_refs);
        for (type_parameter_nodes, type_parameters) |node, *parameter| {
            const value = hir.typeParameterOf(&c.hir, node);
            parameter.variance = value.variance;
            parameter.is_const = value.is_const;
            if (value.constraint != 0) {
                var constraint_context = function_context;
                constraint_context.allow_contextual_projection = true;
                parameter.constraint = try self.lowerTransferable(constraint_context, value.constraint);
            }
            if (value.default != 0) parameter.default = try self.lowerContextualDefault(function_context, value.default);
        }
        var params: std.ArrayListUnmanaged(schema.Element) = .empty;
        var this_type: ?*const schema.Expression = null;
        var has_literal_types = false;
        for (nodes, 0..) |node, i| {
            const value = hir.parameterOf(&c.hir, node);
            has_literal_types = has_literal_types or value.flags.has_literal_type_annotation;
            if (i == 0 and c.hir.kindOf(value.name) == .identifier and std.mem.eql(u8, c.interner.get(hir.identifierOf(&c.hir, value.name).name), "this")) {
                this_type = try self.lowerTransferable(function_context, value.type_annotation);
                continue;
            }
            var param_type = try self.lowerTransferable(function_context, value.type_annotation);
            if (param_type.* == .reference) {
                const reference = param_type.reference;
                if (try self.contextualReadProjection(reference)) |read| {
                    context.declaration.contextual_only = true;
                    param_type = try self.expression(.{ .reference = .{
                        .declaration = reference.declaration,
                        .arguments = reference.arguments,
                        .projection_only = reference.projection_only,
                        .contextual_projection = true,
                        .contextual_read = read.source,
                        .contextual_read_optional_keys = read.optional_keys,
                        .contextual_read_optional_all = read.optional_all,
                        .contextual_read_string_index = read.string_index,
                    } });
                } else if (reference.declaration.contextual_only) {
                    var contextual_parameter = function_context;
                    contextual_parameter.allow_opaque = true;
                    param_type = try self.lowerTransferable(contextual_parameter, value.type_annotation);
                }
            }
            try params.append(self.arena, .{ .type = param_type, .optional = value.flags.is_optional or value.default_value != 0, .rest = value.flags.is_rest });
        }
        const predicate = if (result != 0 and c.hir.kindOf(result) == .type_predicate_type) blk: {
            const value = hir.typePredicateOf(&c.hir, result);
            break :blk schema.TypePredicate{
                .param_index = value.param_index,
                .target = try self.lowerTransferable(function_context, value.target_type),
                .is_asserts = value.is_asserts,
            };
        } else null;
        var result_type = if (predicate) |value|
            try self.expression(.{ .primitive = if (value.is_asserts) Primitive.void_t else Primitive.boolean_t })
        else
            try self.lowerTransferable(function_context, result);
        if (result_type.* == .reference) {
            const reference = result_type.reference;
            if (try self.contextualReadProjection(reference)) |read| if (read.deferred) {
                context.declaration.contextual_only = true;
                result_type = try self.expression(.{ .reference = .{
                    .declaration = reference.declaration,
                    .arguments = reference.arguments,
                    .projection_only = reference.projection_only,
                    .contextual_projection = true,
                    .contextual_deferred_read = true,
                    .contextual_read = read.source,
                    .contextual_read_optional_keys = read.optional_keys,
                    .contextual_read_optional_all = read.optional_all,
                    .contextual_read_string_index = read.string_index,
                } });
            };
        }
        return self.expression(.{ .function = .{
            .type_parameters = type_parameters,
            .parameters = try params.toOwnedSlice(self.arena),
            .result = result_type,
            .this_type = this_type,
            .predicate = predicate,
            .is_construct = is_construct,
            .has_literal_types = has_literal_types,
        } });
    }

    fn lower(self: *Builder, context: Context, node: hir.NodeId) error{OutOfMemory}!*const schema.Expression {
        const c = self.sources[context.source].compilation;
        if (node == 0) return self.expression(.unsupported);
        switch (c.hir.kindOf(node)) {
            .type_ref => {
                const ref = hir.typeRefOf(&c.hir, node);
                const name = c.interner.get(ref.name);
                var qualified_unresolved = ref.qualifier_len != 0 or ref.import_module != null;
                defer if (qualified_unresolved and context.allow_opaque) {
                    context.declaration.contextual_only = true;
                };
                if (ref.import_module == null and ref.qualifier_len == 0) {
                    if (std.mem.eql(u8, name, "this")) return self.expression(.polymorphic_this);
                    if (localParameter(context, name)) |parameter| return self.expression(.{ .parameter = parameter });
                    for (context.visible_parameters orelse context.declaration.parameters) |*param| {
                        if (std.mem.eql(u8, param.name, name)) return self.expression(.{ .parameter = param });
                    }
                } else {
                    const qualifiers = hir.typeRefQualifier(&c.hir, node);
                    if (qualifiers.len > 0 and c.hir.kindOf(qualifiers[0]) == .identifier) {
                        const root_name = c.interner.get(hir.identifierOf(&c.hir, qualifiers[0]).name);
                        if (localParameter(context, root_name) != null) return self.expression(.unsupported);
                        for (context.visible_parameters orelse context.declaration.parameters) |*param| {
                            if (std.mem.eql(u8, param.name, root_name)) return self.expression(.unsupported);
                        }
                    }
                }
                const primitive = if (ref.import_module == null and ref.qualifier_len == 0) std.StaticStringMap(u32).initComptime(.{
                    .{ "any", Primitive.any },               .{ "unknown", Primitive.unknown }, .{ "never", Primitive.never },
                    .{ "string", Primitive.string_t },       .{ "number", Primitive.number_t }, .{ "boolean", Primitive.boolean_t },
                    .{ "undefined", Primitive.undefined_t }, .{ "null", Primitive.null_t },     .{ "void", Primitive.void_t },
                    .{ "object", Primitive.object_t },       .{ "bigint", Primitive.bigint_t }, .{ "symbol", Primitive.symbol_t },
                }).get(name) else null;
                if (primitive) |value| return self.expression(.{ .primitive = value });
                const args = try self.arena.alloc(*const schema.Expression, ref.args_len);
                for (hir.typeRefArgs(&c.hir, node), args) |arg, *out| out.* = try self.lower(context, arg);
                switch (if (ref.import_module != null or ref.qualifier_len != 0) try self.resolveQualified(context.source, node, ref) else try self.resolve(context.source, node, ref.name)) {
                    .declaration => |key| {
                        const target = try self.declaration(key);
                        const whole_graph_supported = ref.qualifier_len == 0 or try self.qualifiedDeclarationGraphSupported(target);
                        const projection_only = ref.qualifier_len != 0 and
                            !context.allow_opaque and
                            !whole_graph_supported;
                        if (ref.qualifier_len != 0 and context.allow_opaque and !whole_graph_supported) context.declaration.contextual_only = true;
                        qualified_unresolved = false;
                        if (projection_only) {
                            const projected = schema.Reference{
                                .declaration = target,
                                .arguments = args,
                                .projection_only = true,
                            };
                            if (try self.contextualReadProjection(projected)) |read| {
                                return self.expression(.{ .reference = .{
                                    .declaration = target,
                                    .arguments = args,
                                    .projection_only = true,
                                    .contextual_projection = true,
                                    .contextual_read = read.source,
                                    .contextual_read_optional_keys = read.optional_keys,
                                    .contextual_read_optional_all = read.optional_all,
                                    .contextual_read_string_index = read.string_index,
                                } });
                            }
                        }
                        return self.expression(.{ .reference = .{
                            .declaration = target,
                            .arguments = args,
                            .projection_only = projection_only,
                        } });
                    },
                    .unsupported => return self.expression(.unsupported),
                    .missing => {
                        if (ref.import_module != null) return self.expression(.unsupported);
                        // Built-in object shapes live in each checker's local
                        // type pool. Transfer their stable spelling and let the
                        // consumer materialize the same canonical shape.
                        if (args.len == 0 and builtin_object_type_name_set.has(name))
                            return self.expression(.{ .builtin_object = name });
                        if (args.len == 0 and std.mem.eql(u8, name, "PropertyKey")) {
                            const members = try self.arena.alloc(*const schema.Expression, 3);
                            members[0] = try self.expression(.{ .primitive = Primitive.string_t });
                            members[1] = try self.expression(.{ .primitive = Primitive.number_t });
                            members[2] = try self.expression(.{ .primitive = Primitive.symbol_t });
                            return self.expression(.{ .union_type = members });
                        }
                        if (args.len > 0 and builtin_generic_type_name_set.has(name))
                            return self.expression(.{ .builtin_reference = .{ .name = name, .arguments = args } });
                        if (args.len == 2 and std.mem.eql(u8, name, "Record"))
                            return self.expression(.{ .record = .{ .key = args[0], .value = args[1] } });
                        if (args.len == 1 and std.mem.eql(u8, name, "Readonly")) switch (args[0].*) {
                            .record => |record| return self.expression(.{ .record = .{
                                .key = record.key,
                                .value = record.value,
                                .readonly = true,
                            } }),
                            else => {},
                        };
                    },
                    .external => {},
                }
                if (ref.qualifier_len == 0) {
                    if (try self.standardUtility(name, args)) |utility| return utility;
                }
                if (args.len == 1 and (std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "ReadonlyArray")))
                    return self.expression(if (std.mem.eql(u8, name, "Array")) .{ .array = args[0] } else .{ .readonly_array = args[0] });
                if (args.len == 1 and std.mem.eql(u8, name, "ThisType")) return self.expression(.{ .this_type = args[0] });
                return self.expression(.unsupported);
            },
            .type_literal => {
                const literal = hir.literalTypeOf(&c.hir, node);
                if (c.hir.kindOf(literal.literal) == .literal_number) {
                    const value = hir.literalNumberOf(&c.hir, literal.literal);
                    return self.expression(.{ .number = if (literal.negative and value > 0) -value else value });
                }
                return self.lower(context, literal.literal);
            },
            .template_literal_type => {
                const texts = hir.templateLiteralTypeTexts(&c.hir, node);
                if (hir.templateLiteralTypeTypes(&c.hir, node).len != 0 or texts.len != 1) return self.expression(.unsupported);
                return self.lower(context, texts[0]);
            },
            .literal_string => {
                const raw = c.interner.get(hir.literalStringOf(&c.hir, node).value);
                if (std.mem.indexOfAny(u8, raw, "\\\r") == null) return self.expression(.{ .string = raw });
                var cooked: std.ArrayListUnmanaged(u8) = .empty;
                try schema.appendCookedStringText(self.arena, raw, &cooked);
                return self.expression(.{ .string = try cooked.toOwnedSlice(self.arena) });
            },
            .literal_number => return self.expression(.{ .number = hir.literalNumberOf(&c.hir, node) }),
            .literal_bool => return self.expression(.{ .boolean = hir.literalBoolOf(&c.hir, node) }),
            .array_type => return self.expression(.{ .array = try self.lower(context, hir.arrayTypeOf(&c.hir, node).element) }),
            .readonly_type => {
                const operand = hir.readonlyTypeOf(&c.hir, node).operand;
                if (c.hir.kindOf(operand) == .array_type) return self.expression(.{ .readonly_array = try self.lower(context, hir.arrayTypeOf(&c.hir, operand).element) });
                return self.expression(.unsupported);
            },
            .object_type => return self.object(context, hir.objectTypeMembers(&c.hir, node)),
            .tuple_type => {
                const nodes = hir.tupleTypeElements(&c.hir, node);
                const elements = try self.arena.alloc(schema.Element, nodes.len);
                for (nodes, elements) |item, *element| {
                    const optional = c.hir.kindOf(item) == .optional_type;
                    const rest = c.hir.kindOf(item) == .rest_type;
                    const value = if (optional) hir.optionalTypeOf(&c.hir, item).operand else if (rest) hir.restTypeOf(&c.hir, item).operand else item;
                    element.* = .{ .type = try self.lower(context, value), .optional = optional, .rest = rest };
                }
                return self.expression(.{ .tuple = elements });
            },
            .union_type, .intersection_type => {
                const union_type = c.hir.kindOf(node) == .union_type;
                const nodes = if (union_type) hir.unionTypeMembers(&c.hir, node) else hir.intersectionTypeMembers(&c.hir, node);
                const values = try self.arena.alloc(*const schema.Expression, nodes.len);
                for (nodes, values) |item, *value| value.* = try self.lower(context, item);
                return self.expression(if (union_type) .{ .union_type = values } else .{ .intersection = values });
            },
            .fn_type, .constructor_type => {
                const value = hir.fnTypeOf(&c.hir, node);
                return self.functionType(
                    context,
                    c.hir.child_pool.items[value.type_params_start..][0..value.type_params_len],
                    c.hir.child_pool.items[value.params_start..][0..value.params_len],
                    value.return_type,
                    c.hir.kindOf(node) == .constructor_type,
                );
            },
            .indexed_access_type => {
                const indexed = hir.indexedAccessTypeOf(&c.hir, node);
                return self.expression(.{ .indexed_access = .{
                    .object = try self.lower(context, indexed.object),
                    .index = try self.lower(context, indexed.index),
                } });
            },
            .keyof_type => return self.expression(.{ .keyof = try self.lower(context, hir.keyofTypeOf(&c.hir, node).operand) }),
            .mapped_type => {
                const mapped = hir.mappedTypeOf(&c.hir, node);
                if (mapped.remap != 0) return self.expression(.unsupported);
                const parameter_node = mapped.type_param;
                if (parameter_node == 0 or c.hir.kindOf(parameter_node) != .type_parameter) return self.expression(.unsupported);
                const payload = hir.typeParameterOf(&c.hir, parameter_node);
                const parameter = try self.arena.create(schema.Parameter);
                parameter.* = .{ .name = c.interner.get(payload.name) };
                var local_context = try self.extendContext(context, &.{parameter});
                if (c.hir.kindOf(mapped.value) == .fn_type or c.hir.kindOf(mapped.value) == .constructor_type) {
                    local_context.allow_opaque = true;
                    local_context.allow_contextual_projection = true;
                }
                return self.expression(.{ .mapped = .{
                    .parameter = parameter,
                    .constraint = try self.lower(context, mapped.constraint),
                    .template = try self.lower(local_context, mapped.value),
                    .readonly = mapped.readonly,
                    .optional = mapped.optional,
                } });
            },
            .conditional_type => return self.lowerConditional(context, node),
            .infer_type => {
                const payload = hir.inferTypeOf(&c.hir, node);
                const parameter = localParameter(context, c.interner.get(payload.name)) orelse return self.expression(.unsupported);
                return self.expression(.{ .infer = parameter });
            },
            .typeof_type => {
                const operand = hir.typeofTypeOf(&c.hir, node).operand;
                if (c.hir.kindOf(operand) != .identifier) return self.expression(.unsupported);
                const identifier = hir.identifierOf(&c.hir, operand);
                return switch (try self.resolve(context.source, operand, identifier.name)) {
                    .declaration => |key| blk: {
                        const target = try self.declaration(key);
                        break :blk self.expression(if (target.is_class) .{ .typeof_class = target } else .unsupported);
                    },
                    .missing, .external, .unsupported => self.expression(.unsupported),
                };
            },
            else => return self.expression(.unsupported),
        }
    }

    fn collectInferNodes(c: *const driver.Compilation, node: hir.NodeId, result: *std.ArrayListUnmanaged(hir.NodeId), arena: std.mem.Allocator) !void {
        if (node == 0) return;
        switch (c.hir.kindOf(node)) {
            .infer_type => {
                const name = hir.inferTypeOf(&c.hir, node).name;
                for (result.items) |existing| {
                    if (hir.inferTypeOf(&c.hir, existing).name == name) return;
                }
                try result.append(arena, node);
            },
            .array_type => try collectInferNodes(c, hir.arrayTypeOf(&c.hir, node).element, result, arena),
            .readonly_type => try collectInferNodes(c, hir.readonlyTypeOf(&c.hir, node).operand, result, arena),
            .optional_type => try collectInferNodes(c, hir.optionalTypeOf(&c.hir, node).operand, result, arena),
            .rest_type => try collectInferNodes(c, hir.restTypeOf(&c.hir, node).operand, result, arena),
            .union_type, .intersection_type => {
                const members = if (c.hir.kindOf(node) == .union_type)
                    hir.unionTypeMembers(&c.hir, node)
                else
                    hir.intersectionTypeMembers(&c.hir, node);
                for (members) |member| try collectInferNodes(c, member, result, arena);
            },
            .tuple_type => for (hir.tupleTypeElements(&c.hir, node)) |element| try collectInferNodes(c, element, result, arena),
            .type_ref => for (hir.typeRefArgs(&c.hir, node)) |argument| try collectInferNodes(c, argument, result, arena),
            .indexed_access_type => {
                const indexed = hir.indexedAccessTypeOf(&c.hir, node);
                try collectInferNodes(c, indexed.object, result, arena);
                try collectInferNodes(c, indexed.index, result, arena);
            },
            .keyof_type => try collectInferNodes(c, hir.keyofTypeOf(&c.hir, node).operand, result, arena),
            .conditional_type => {
                const conditional = hir.conditionalTypeOf(&c.hir, node);
                try collectInferNodes(c, conditional.check, result, arena);
                try collectInferNodes(c, conditional.extends, result, arena);
                try collectInferNodes(c, conditional.true_branch, result, arena);
                try collectInferNodes(c, conditional.false_branch, result, arena);
            },
            .fn_type, .constructor_type => {
                const function = hir.fnTypeOf(&c.hir, node);
                for (c.hir.child_pool.items[function.params_start..][0..function.params_len]) |parameter_node| {
                    try collectInferNodes(c, hir.parameterOf(&c.hir, parameter_node).type_annotation, result, arena);
                }
                try collectInferNodes(c, function.return_type, result, arena);
            },
            else => {},
        }
    }

    fn lowerConditional(self: *Builder, context: Context, node: hir.NodeId) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        const conditional = hir.conditionalTypeOf(&c.hir, node);
        var infer_nodes: std.ArrayListUnmanaged(hir.NodeId) = .empty;
        try collectInferNodes(c, conditional.extends, &infer_nodes, self.arena);
        const parameters = try self.arena.alloc(*const schema.Parameter, infer_nodes.items.len);
        for (infer_nodes.items, parameters) |infer_node, *out| {
            const payload = hir.inferTypeOf(&c.hir, infer_node);
            const parameter = try self.arena.create(schema.Parameter);
            parameter.* = .{ .name = c.interner.get(payload.name) };
            out.* = parameter;
        }
        const infer_context = try self.extendContext(context, parameters);
        for (infer_nodes.items, parameters) |infer_node, parameter_const| {
            const constraint_node = hir.inferTypeOf(&c.hir, infer_node).constraint;
            if (constraint_node == 0) continue;
            const parameter: *schema.Parameter = @constCast(parameter_const);
            parameter.constraint = try self.lower(infer_context, constraint_node);
        }
        return self.expression(.{ .conditional = .{
            .check = try self.lower(context, conditional.check),
            .extends_type = try self.lower(infer_context, conditional.extends),
            .true_branch = try self.lower(infer_context, conditional.true_branch),
            .false_branch = try self.lower(context, conditional.false_branch),
        } });
    }

    fn resolve(self: *Builder, source: usize, node: hir.NodeId, name: hir.StringId) error{OutOfMemory}!Resolution {
        const c = self.sources[source].compilation;
        const bound = self.scopedSymbol(source, node, name) orelse {
            const text = c.interner.get(name);
            if (try self.mergedAmbientClass(source, node, text)) |resolved| return resolved;
            // Canonical library identities keep the existing consumer-owned
            // lowering path; ordinary globals carry their actual owners.
            if (builtin_object_type_name_set.has(text) or builtin_generic_type_name_set.has(text) or
                std.mem.eql(u8, text, "Array") or std.mem.eql(u8, text, "ReadonlyArray") or
                std.mem.eql(u8, text, "Record") or std.mem.eql(u8, text, "ThisType") or
                std.mem.eql(u8, text, "PropertyKey") or std.StaticStringMap(void).initComptime(.{
                .{"Partial"}, .{"Required"}, .{"Readonly"}, .{"Pick"}, .{"Omit"}, .{"Extract"}, .{"Exclude"},
            }).has(text)) return .missing;
            if (self.global_types.get(text)) |group| {
                if (group.items.len == 1) return .{ .declaration = group.items[0] };
                for (group.items) |key| if (self.sources[key.source].compilation.hir.kindOf(key.node) != .interface_decl) return .unsupported;
                return .{ .declaration = group.items[0] };
            }
            return .missing;
        };
        if (!bound.flags.is_import) {
            if (self.global_types.get(c.interner.get(name))) |group| {
                for (group.items) |member| {
                    if (member.source != source or std.mem.indexOfScalar(hir.NodeId, bound.decls.items, member.node) == null) continue;
                    for (group.items) |fragment| if (self.sources[fragment.source].compilation.hir.kindOf(fragment.node) != .interface_decl and group.items.len > 1) return .unsupported;
                    return .{ .declaration = group.items[0] };
                }
            }
            // Interfaces share a declaration shell; their fragment bodies
            // retain source-local imports and canonical parameter bindings.
            if (bound.decls.items.len > 1) {
                var all_interfaces = true;
                for (bound.decls.items) |decl| if (c.hir.kindOf(decl) != .interface_decl) {
                    all_interfaces = false;
                    break;
                };
                if (all_interfaces) return .{ .declaration = .{ .source = source, .node = bound.decls.items[0] } };
            }
            var local_declaration: ?hir.NodeId = null;
            for (bound.decls.items) |declaration_node| {
                if (!declarationHasName(c, declaration_node, name)) continue;
                if (local_declaration != null) return .unsupported;
                local_declaration = declaration_node;
            }
            return if (local_declaration) |declaration_node|
                .{ .declaration = .{ .source = source, .node = declaration_node } }
            else
                .external;
        }
        const imported = importForSymbol(c, bound) orelse return .unsupported;
        return self.resolveImported(source, c.interner.get(hir.importOf(&c.hir, imported.node).module), imported.name);
    }

    const ImportedBinding = struct { node: hir.NodeId, name: []const u8, namespace: bool = false, is_type_only: bool = false };

    fn importForSymbol(c: *const driver.Compilation, symbol: *const binder.Symbol) ?ImportedBinding {
        var found: ?ImportedBinding = null;
        for (symbol.decls.items) |declaration_node| {
            const statement = c.hir.parentOf(declaration_node);
            if (statement == hir.none_node_id or c.hir.kindOf(statement) != .import_decl) return null;
            const import = hir.importOf(&c.hir, statement);
            const candidate: ImportedBinding = if (c.hir.kindOf(declaration_node) == .import_specifier)
                .{
                    .node = statement,
                    .name = c.interner.get(hir.importSpecifierOf(&c.hir, declaration_node).imported),
                    .is_type_only = import.is_type_only or hir.importSpecifierOf(&c.hir, declaration_node).is_type_only,
                }
            else if (import.namespace_binding == declaration_node)
                .{ .node = statement, .name = "", .namespace = true, .is_type_only = import.is_type_only }
            else if (import.default_binding == declaration_node and !import.is_require_equals)
                .{ .node = statement, .name = "default", .is_type_only = import.is_type_only }
            else
                return null;
            if (found != null) return null;
            found = candidate;
        }
        return found;
    }

    fn scopedSymbol(self: *Builder, source: usize, node: hir.NodeId, name: hir.StringId) ?*binder.Symbol {
        const c = self.sources[source].compilation;
        var current = node;
        var scope = c.module.root;
        while (current != 0) : (current = c.hir.parentOf(current)) {
            var found = false;
            for (c.module.scopes.items) |candidate| if (candidate.introducing_node == current) {
                scope = candidate;
                found = true;
                break;
            };
            if (found) break;
        }
        var current_scope: ?*binder.Scope = scope;
        var symbol: ?*binder.Symbol = null;
        while (current_scope) |candidate| : (current_scope = candidate.parent) {
            if (candidate.types.get(name)) |found| {
                symbol = found;
                break;
            }
            if (candidate.values.get(name)) |found| if (found.flags.is_import) {
                symbol = found;
                break;
            };
        }
        return symbol;
    }

    fn scopedValueSymbol(self: *Builder, source: usize, node: hir.NodeId, name: hir.StringId) ?*binder.Symbol {
        const c = self.sources[source].compilation;
        var current = node;
        var scope = c.module.root;
        while (current != 0) : (current = c.hir.parentOf(current)) {
            var found = false;
            for (c.module.scopes.items) |candidate| if (candidate.introducing_node == current) {
                scope = candidate;
                found = true;
                break;
            };
            if (found) break;
        }
        var current_scope: ?*binder.Scope = scope;
        while (current_scope) |candidate| : (current_scope = candidate.parent) {
            if (candidate.values.get(name)) |symbol| return symbol;
        }
        return null;
    }

    fn scopedNamespaceSymbol(self: *Builder, source: usize, node: hir.NodeId, name: hir.StringId) ?*binder.Symbol {
        const c = self.sources[source].compilation;
        var current = node;
        var scope = c.module.root;
        while (current != 0) : (current = c.hir.parentOf(current)) {
            var found = false;
            for (c.module.scopes.items) |candidate| if (candidate.introducing_node == current) {
                scope = candidate;
                found = true;
                break;
            };
            if (found) break;
        }
        var current_scope: ?*binder.Scope = scope;
        while (current_scope) |candidate| : (current_scope = candidate.parent) {
            if (candidate.namespaces.get(name)) |symbol| return symbol;
        }
        return null;
    }

    fn resolveQualified(self: *Builder, source: usize, node: hir.NodeId, ref: hir.TypeRefPayload) error{OutOfMemory}!Resolution {
        const c = self.sources[source].compilation;
        const qualifiers = hir.typeRefQualifier(&c.hir, node);
        if (ref.import_module) |module| {
            if (qualifiers.len != 0 or !ref.import_qualified) return .unsupported;
            return self.resolveImported(source, c.interner.get(module), c.interner.get(ref.name));
        }
        if (qualifiers.len != 1 or c.hir.kindOf(qualifiers[0]) != .identifier) return .unsupported;
        const namespace_name = hir.identifierOf(&c.hir, qualifiers[0]).name;
        const bound = self.scopedSymbol(source, qualifiers[0], namespace_name) orelse return .unsupported;
        if (!bound.flags.is_import) {
            const namespace_bound = self.scopedNamespaceSymbol(source, qualifiers[0], namespace_name) orelse return .unsupported;
            var matched: ?hir.NodeId = null;
            for (namespace_bound.decls.items) |declaration_node| {
                if (declaration_node == hir.none_node_id or c.hir.kindOf(declaration_node) != .namespace_decl) continue;
                for (hir.namespaceBody(&c.hir, declaration_node)) |raw| {
                    // Only exported namespace members have meaning through a
                    // qualified reference outside their declaration block.
                    if (c.hir.kindOf(raw) != .export_decl) continue;
                    const candidate = hir.exportOf(&c.hir, raw).decl;
                    if (!declarationHasName(c, candidate, ref.name)) continue;
                    if (matched != null and matched.? != candidate) return .unsupported;
                    matched = candidate;
                }
            }
            return if (matched) |declaration_node|
                .{ .declaration = .{ .source = source, .node = declaration_node } }
            else
                .unsupported;
        }
        const imported = importForSymbol(c, bound) orelse return .unsupported;
        if (!imported.namespace) return .unsupported;
        return self.resolveImported(source, c.interner.get(hir.importOf(&c.hir, imported.node).module), c.interner.get(ref.name));
    }

    fn declarationHasName(c: *const driver.Compilation, node: hir.NodeId, name: hir.StringId) bool {
        if (node == 0 or node >= c.hir.nodeCount()) return false;
        const name_node = switch (c.hir.kindOf(node)) {
            .type_alias_decl => hir.typeAliasOf(&c.hir, node).name,
            .interface_decl => hir.interfaceOf(&c.hir, node).name,
            .class_decl, .class_expr => hir.classOf(&c.hir, node).name,
            else => return false,
        };
        return name_node != 0 and c.hir.kindOf(name_node) == .identifier and hir.identifierOf(&c.hir, name_node).name == name;
    }

    fn resolveImported(self: *Builder, source: usize, specifier: []const u8, name: []const u8) error{OutOfMemory}!Resolution {
        const resolved = if (try self.query.hasAmbientModule(specifier))
            self.query.resolveModule(specifier, self.sources[source].path, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .unsupported,
            }
        else filesystem: {
            const target = self.resolver.resolve(specifier, self.sources[source].path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .unsupported,
            };
            if (self.resolveDirectExport(target.path, name)) |direct| return direct;
            break :filesystem self.query.resolve(target.path, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .unsupported,
            };
        };
        if (!resolved.complete or resolved.ambiguous) return .unsupported;
        const origin = resolved.type orelse return .unsupported;
        for (self.sources, 0..) |owner, index| {
            if (!std.mem.eql(u8, owner.path, origin.path)) continue;
            for (owner.compilation.hir.spans.items, 0..) |span, id| {
                if (span.start != origin.position) continue;
                switch (owner.compilation.hir.kindOf(@intCast(id))) {
                    .type_alias_decl, .interface_decl, .class_decl => return .{ .declaration = .{ .source = index, .node = @intCast(id) } },
                    else => {},
                }
            }
        }
        return .unsupported;
    }

    fn resolveImportedValue(self: *Builder, source: usize, specifier: []const u8, name: []const u8) error{OutOfMemory}!Resolution {
        const resolved = if (try self.query.hasAmbientModule(specifier))
            self.query.resolveModule(specifier, self.sources[source].path, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .unsupported,
            }
        else filesystem: {
            const target = self.resolver.resolve(specifier, self.sources[source].path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .unsupported,
            };
            break :filesystem self.query.resolve(target.path, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .unsupported,
            };
        };
        if (!resolved.complete or resolved.ambiguous) return .unsupported;
        const origin = resolved.value orelse return .unsupported;
        for (self.sources, 0..) |owner, index| {
            if (!std.mem.eql(u8, owner.path, origin.path)) continue;
            for (owner.compilation.hir.spans.items, 0..) |span, id| {
                if (span.start != origin.position) continue;
                switch (owner.compilation.hir.kindOf(@intCast(id))) {
                    .const_decl, .let_decl, .var_decl => return .{ .declaration = .{ .source = index, .node = @intCast(id) } },
                    else => {},
                }
            }
        }
        return .unsupported;
    }

    /// A direct local export remains authoritative even when an unrelated
    /// star export makes the module's aggregate origin query incomplete.
    fn resolveDirectExport(self: *Builder, path: []const u8, name: []const u8) ?Resolution {
        for (self.sources, 0..) |owner, index| {
            if (!std.mem.eql(u8, owner.path, path)) continue;
            const symbol = owner.compilation.lookupTopLevel(name) orelse return null;
            if (!symbol.flags.is_export or symbol.flags.is_import) return null;
            var result: ?hir.NodeId = null;
            for (symbol.decls.items) |node| {
                if (!declarationHasName(owner.compilation, node, symbol.name)) continue;
                if (result != null) return .unsupported;
                result = node;
            }
            return if (result) |node| .{ .declaration = .{ .source = index, .node = node } } else null;
        }
        return null;
    }
};

const T = std.testing;
const TestFile = struct { path: []const u8, text: []const u8, syntax_target_es2015: bool = false, expect_parse_error: bool = false };
const TestGraph = struct {
    vfs: resolver_mod.VirtualFs,
    resolver: resolver_mod.Resolver,
    sources: std.ArrayListUnmanaged(Source) = .empty,

    fn init(files: []const TestFile) !*TestGraph {
        const graph = try T.allocator.create(TestGraph);
        graph.* = .{ .vfs = resolver_mod.VirtualFs.init(T.allocator), .resolver = undefined };
        graph.resolver = resolver_mod.Resolver.init(T.allocator, graph.vfs.fs(), .{});
        errdefer graph.deinit();
        for (files) |file| {
            try graph.vfs.addFile(file.path, file.text);
            const compilation = try driver.prepareSource(T.allocator, file.text, .{ .syntax_target_es2015 = file.syntax_target_es2015 });
            errdefer {
                compilation.deinit();
                T.allocator.destroy(compilation);
            }
            try T.expectEqual(file.expect_parse_error, compilation.has_errors);
            try graph.sources.append(T.allocator, .{ .path = file.path, .compilation = compilation });
        }
        return graph;
    }

    fn deinit(self: *TestGraph) void {
        for (self.sources.items) |source| {
            source.compilation.deinit();
            T.allocator.destroy(source.compilation);
        }
        self.sources.deinit(T.allocator);
        self.resolver.deinit();
        self.vfs.deinit();
        T.allocator.destroy(self);
    }

    fn class(self: *TestGraph, index: usize, name: []const u8) !*schema.Schema {
        const source = self.sources.items[index];
        const symbol = source.compilation.lookupTopLevel(name) orelse return error.MissingClass;
        return @constCast(try collect(T.allocator, &self.resolver, self.sources.items, source, symbol.decls.items[0]));
    }
};

test "class schema: supported inherited callable types keep their complete declaration" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface Request { index: string; page?: number; }
        \\export interface Driver<T> { search: (request: Request) => T; }
        \\export interface Options<T> extends Omit<Request, "index"> { index: string; driver: Driver<T>; ranking?: string; }
        \\export declare function create<T>(options: Options<T>): Driver<T>;
    }});
    defer graph.deinit();
    const result = try graph.class(0, "create");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const parameter = result.declaration.body.?.function.parameters[0].type.reference;
    try T.expect(!parameter.contextual_projection);
    try T.expect(parameter.contextual_read == null);
    const body = parameter.declaration.body.?.intersection;
    try T.expectEqual(@as(usize, 3), body[1].object.len);
    try T.expectEqualStrings("driver", body[1].object[1].name);
}

test "class schema: parameters defaults constraints and nested members keep owner identities" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\type Item = { id: string };
        \\export declare class Box<T extends Item = Item, U = T[]> {
        \\  private key: string;
        \\  readonly value?: U;
        \\  nested: { readonly item?: T; list: readonly U[]; pair: [T, U?]; choice: T | undefined };
        \\  identity(value: T, fallback?: U): T;
        \\}
    }});
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    const def = result.declaration;
    const params = def.parameters;
    try T.expectEqual(@as(usize, 2), params.len);
    try T.expect(params[0].constraint.?.reference.declaration == params[0].default.?.reference.declaration);
    try T.expectEqualStrings("Item", params[0].constraint.?.reference.declaration.name);
    try T.expect(params[1].default.?.array.parameter == &params[0]);
    const members = def.body.?.object;
    try T.expectEqual(@as(usize, 4), members.len);
    try T.expect(members[0].visibility == .private);
    try T.expect(members[1].optional and members[1].readonly and members[1].type.parameter == &params[1]);
    const nested = members[2].type.object;
    try T.expect(nested[0].optional and nested[0].readonly and nested[0].type.parameter == &params[0]);
    try T.expect(nested[1].type.readonly_array.parameter == &params[1]);
    try T.expect(nested[2].type.tuple[1].optional);
    try T.expect(nested[3].type.union_type[0].parameter == &params[0]);
    const method = members[3].type.function;
    try T.expect(members[3].method and method.parameters[1].optional);
    try T.expect(method.parameters[0].type.parameter == &params[0] and method.result.parameter == &params[0]);
}

test "class schema: recursive alias references do not expand or capture the class parameter" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\type Link<T> = { item: T; next?: Link<T> };
        \\export declare class Box<T> { value: Link<T>; }
    }});
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    const box = result.declaration;
    const ref = box.body.?.object[0].type.reference;
    const link = ref.declaration;
    try T.expect(ref.arguments[0].parameter == &box.parameters[0]);
    try T.expect(&link.parameters[0] != &box.parameters[0]);
    try T.expect(link.body.?.object[0].type.parameter == &link.parameters[0]);
    const next = link.body.?.object[1];
    try T.expect(next.optional and next.type.reference.declaration == link);
    try T.expect(next.type.reference.arguments[0].parameter == &link.parameters[0]);
}

test "class schema: imported aliases use the defining file through reexports" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/app.ts", .text = "type Wrap<X> = { wrong: number }; export declare class Local<T> { value: Wrap<T>; }" },
        .{ .path = "/owner.ts", .text = "import { Renamed as Wrap } from './barrel'; export declare class Box<T> { value: Wrap<T>; }" },
        .{ .path = "/barrel.ts", .text = "export { Wrap as Renamed } from './helper';" },
        .{ .path = "/helper.ts", .text = "export type Wrap<X> = { item: X };" },
    });
    defer graph.deinit();
    const result = try graph.class(1, "Box");
    defer result.deinit(T.allocator);
    const ref = result.declaration.body.?.object[0].type.reference;
    try T.expectEqualStrings("/helper.ts", ref.declaration.path);
    try T.expectEqualStrings("item", ref.declaration.body.?.object[0].name);
    try T.expect(ref.arguments[0].parameter == &result.declaration.parameters[0]);
    try T.expect(ref.declaration.body.?.object[0].type.parameter == &ref.declaration.parameters[0]);
}

test "class schema: qualified references admit supported declaration graphs" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/shapes.ts", .text =
        \\export type Value = string | number;
        \\export type Structured = { label: string };
        \\export type Opaque = Set<string>;
        },
        .{ .path = "/owner.ts", .text =
        \\import type * as Shapes from "./shapes";
        \\export interface Box { items: Shapes.Value[]; }
        \\export interface StructuredBox { details: Shapes.Structured; }
        \\export type Callback = (value: Shapes.Value, opaque: Shapes.Opaque) => Shapes.Value;
        },
    });
    defer graph.deinit();

    const box_result = try graph.class(1, "Box");
    defer box_result.deinit(T.allocator);
    const item = box_result.declaration.body.?.object[0].type.array.reference;
    try T.expectEqualStrings("Value", item.declaration.name);
    try T.expect(!box_result.declaration.contextual_only);

    const structured_result = try graph.class(1, "StructuredBox");
    defer structured_result.deinit(T.allocator);
    const structured = structured_result.declaration.body.?.object[0].type.reference;
    try T.expect(!structured.projection_only);
    try T.expectEqualStrings("Structured", structured.declaration.name);
    try T.expect(try structured_result.isSupported(T.allocator));

    const callback_result = try graph.class(1, "Callback");
    defer callback_result.deinit(T.allocator);
    const callback = callback_result.declaration.body.?.function;
    try T.expectEqualStrings("Value", callback.parameters[0].type.reference.declaration.name);
    const opaque_ref = callback.parameters[1].type.reference;
    try T.expect(!opaque_ref.projection_only);
    try T.expectEqualStrings("Opaque", opaque_ref.declaration.name);
    try T.expectEqualStrings("Set", opaque_ref.declaration.body.?.builtin_reference.name);
    try T.expectEqualStrings("Value", callback.result.reference.declaration.name);
    try T.expect(!callback_result.declaration.contextual_only);
}

test "class schema: callable utility projections retain a proven read surface" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface IssueBase { readonly code?: string; readonly path: PropertyKey[]; readonly message: string; }
        \\export interface InvalidType extends IssueBase { readonly code: "invalid_type"; readonly expected: string; }
        \\export interface InvalidValue extends IssueBase { readonly code: "invalid_value"; readonly values: string[]; }
        \\export type Issue = InvalidType | InvalidValue;
        \\type MakePartial<T, K extends keyof T> = Omit<T, K> & Partial<Pick<T, K>>;
        \\type Flatten<T> = { [K in keyof T]: T[K] } & {};
        \\type InternalIssue<T extends IssueBase> = T extends any ? Flatten<MakePartial<T, "message"> & { input: unknown }> : never;
        \\export interface ErrorMap<T extends IssueBase = Issue> {
        \\  (issue: InternalIssue<T>): { message: string } | string | undefined;
        \\}
    }});
    defer graph.deinit();

    const result = try graph.class(0, "ErrorMap");
    defer result.deinit(T.allocator);
    const declaration = result.declaration;
    try T.expect(declaration.contextual_only);
    const default = declaration.parameters[0].default.?.reference;
    try T.expect(!default.contextual_projection);
    try T.expect(default.contextual_read == null);
    const call = declaration.body.?.object[0].type.function;
    const issue = call.parameters[0].type.reference;
    try T.expect(issue.contextual_projection);
    try T.expect(issue.contextual_read.?.parameter == &declaration.parameters[0]);
    try T.expect(try result.isSupported(T.allocator));

    const owner = graph.sources.items[0].compilation;
    const node_count = owner.hir.nodeCount();
    const type_count = owner.type_interner.pool.typeCount();
    const diagnostics = owner.diagnostics.items.len;
    owner.source = "";
    for (0..32) |_| {
        const repeated = try graph.class(0, "ErrorMap");
        repeated.deinit(T.allocator);
    }
    try T.expectEqual(node_count, owner.hir.nodeCount());
    try T.expectEqual(type_count, owner.type_interner.pool.typeCount());
    try T.expectEqual(diagnostics, owner.diagnostics.items.len);
    try T.expect(!owner.checked_types_ready);
}

test "class schema: normalize return projections retain filtered source reads" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\type Identity<T> = T;
        \\type Flatten<T> = Identity<{ [K in keyof T]: T[K] }>;
        \\type Normalize<T> = T extends undefined
        \\  ? never
        \\  : T extends Record<any, any>
        \\    ? Flatten<
        \\        { [K in keyof Omit<T, "error" | "message">]: T[K] } &
        \\        ("error" extends keyof T ? { error?: Exclude<T["error"], string> } : unknown)
        \\      >
        \\    : never;
        \\export declare function normalizeParams<T>(value: T): Normalize<T>;
    }});
    defer graph.deinit();

    const result = try graph.class(0, "normalizeParams");
    defer result.deinit(T.allocator);
    const return_type = result.declaration.body.?.function.result;
    try T.expect(return_type.* == .reference);
    const normalized = return_type.reference;
    try T.expect(normalized.contextual_projection);
    try T.expect(normalized.contextual_deferred_read);
    try T.expect(normalized.contextual_read != null);
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: homomorphic callable aliases retain imported union reads" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/utilities.ts", .text =
        \\export type Primitive = string | number | bigint | boolean | null | undefined;
        \\export type Omit<T, K extends keyof T> = Pick<T, Exclude<keyof T, K>>;
        \\export type InexactPartial<T> = { [P in keyof T]?: T[P] | undefined };
        \\export type MakePartial<T, K extends keyof T> = Omit<T, K> & InexactPartial<Pick<T, K>>;
        \\export type Identity<T> = T;
        \\export type Flatten<T> = Identity<{ [K in keyof T]: T[K] }>;
        },
        .{ .path = "/owner.ts", .text =
        \\import type * as util from "./utilities";
        \\interface Base { code?: string; path: PropertyKey[]; message: string }
        \\export interface NoMatch extends Base { code: "invalid_union"; options?: util.Primitive[] }
        \\interface Other extends Base { code: "other" }
        \\export type Issue = NoMatch | Other;
        \\export type Raw<T extends Base> = T extends any
        \\  ? util.Flatten<util.MakePartial<T, "message" | "path"> & { readonly input: unknown } & Record<string, unknown>>
        \\  : never;
        \\export type ErrorMap = (issue: Raw<Issue>) => string | undefined;
        },
    });
    defer graph.deinit();

    const result = try graph.class(1, "ErrorMap");
    defer result.deinit(T.allocator);
    try T.expect(result.declaration.contextual_only);
    const issue = result.declaration.body.?.function.parameters[0].type.reference;
    try T.expect(issue.contextual_projection);
    try T.expect(issue.contextual_read != null);
    try T.expect(!issue.contextual_read_optional_all);
    try T.expect(issue.contextual_read_optional_keys != null);
    try T.expect(issue.contextual_read_string_index != null);
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: function signatures retain readonly record domains" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export type Value = string | number;
        \\export type ValueMap = Readonly<Record<string, Value>>;
        \\export function values(entries: ValueMap): Value[] { void entries; return []; }
    }});
    defer graph.deinit();

    const result = try graph.class(0, "values");
    defer result.deinit(T.allocator);
    const function = result.declaration.body.?.function;
    const map = function.parameters[0].type.reference.declaration.body.?.record;
    try T.expect(map.readonly);
    try T.expectEqual(Primitive.string_t, map.key.primitive);
    try T.expectEqualStrings("Value", map.value.reference.declaration.name);
    try T.expectEqualStrings("Value", function.result.array.reference.declaration.name);
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: JavaScript nullable JSDoc keeps whole arrays distinct from nullable elements" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.js", .text =
        \\/**
        \\ * @param {?Array<number>} values
        \\ * @returns {?Array<number>}
        \\ */
        \\export function maybeArray(values) { return values; }
        \\/**
        \\ * @param {Array<?number>} values
        \\ * @returns {ReadonlyArray<?number>}
        \\ */
        \\export function maybeElements(values) { return values; }
    }});
    defer graph.deinit();

    const whole = try graph.class(0, "maybeArray");
    defer whole.deinit(T.allocator);
    try T.expect(try whole.isSupported(T.allocator));
    const whole_parameter = whole.declaration.body.?.function.parameters[0].type.union_type;
    try T.expectEqual(@as(usize, 2), whole_parameter.len);
    try T.expectEqual(Primitive.number_t, whole_parameter[0].array.primitive);
    try T.expectEqual(Primitive.null_t, whole_parameter[1].primitive);

    const elements = try graph.class(0, "maybeElements");
    defer elements.deinit(T.allocator);
    try T.expect(try elements.isSupported(T.allocator));
    const element_parameter = elements.declaration.body.?.function.parameters[0].type.array.union_type;
    try T.expectEqual(@as(usize, 2), element_parameter.len);
    try T.expectEqual(Primitive.number_t, element_parameter[0].primitive);
    try T.expectEqual(Primitive.null_t, element_parameter[1].primitive);
    const element_result = elements.declaration.body.?.function.result.readonly_array.union_type;
    try T.expectEqual(Primitive.null_t, element_result[1].primitive);
}

test "class schema: Record index domains are whole-type transferable" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface Metadata {
        \\  strings: Record<string, string>;
        \\  numbers: Record<number, boolean>;
        \\  symbols: Record<symbol, number>;
        \\  mixed: Record<string | number | symbol, string>;
        \\  frozen: Readonly<Record<string, number>>;
        \\}
    }});
    defer graph.deinit();
    const result = try graph.class(0, "Metadata");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const members = result.declaration.body.?.object;
    try T.expectEqual(@as(usize, 5), members.len);
    try T.expect(members[4].type.record.readonly);
    try T.expect(!result.declaration.contextual_only);
}

test "class schema: Record admission preserves finite keys and rejects unsupported value domains" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface Finite { data: Record<"left" | "right", string>; }
        \\export interface Unsupported { data: Record<string, MissingType>; }
    }});
    defer graph.deinit();
    const finite = try graph.class(0, "Finite");
    defer finite.deinit(T.allocator);
    try T.expect(try finite.isSupported(T.allocator));
    const record = finite.declaration.body.?.object[0].type.record;
    try T.expectEqual(@as(usize, 2), record.key.union_type.len);
    try T.expectEqualStrings("left", record.key.union_type[0].string);
    try T.expectEqualStrings("right", record.key.union_type[1].string);
    try T.expectEqual(Primitive.string_t, record.value.primitive);
    const unsupported = try graph.class(0, "Unsupported");
    defer unsupported.deinit(T.allocator);
    try T.expect(!try unsupported.isSupported(T.allocator));
}

test "class schema: qualified generic Record aliases retain constrained key parameters" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/maps.ts", .text = "export type GenericMap<K extends PropertyKey, V> = Record<K, V>;" },
        .{ .path = "/owner.ts", .text =
        \\import type * as maps from "./maps";
        \\export type QualifiedMap<K extends PropertyKey, V> = maps.GenericMap<K, V>;
        },
    });
    defer graph.deinit();
    const result = try graph.class(1, "QualifiedMap");
    defer result.deinit(T.allocator);
    const qualified = result.declaration;
    const reference = qualified.body.?.reference;
    try T.expect(!reference.projection_only);
    try T.expectEqualStrings("GenericMap", reference.declaration.name);
    try T.expect(reference.arguments[0].parameter == &qualified.parameters[0]);
    try T.expect(reference.arguments[1].parameter == &qualified.parameters[1]);
    const record = reference.declaration.body.?.record;
    try T.expect(record.key.parameter == &reference.declaration.parameters[0]);
    try T.expect(record.value.parameter == &reference.declaration.parameters[1]);
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: Record keys retain nested generic alias substitutions" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/keys.ts", .text = "export type ExtendedKeys<K extends PropertyKey> = K | \"fixed\";" },
        .{ .path = "/maps.ts", .text =
        \\import type * as keys from "./keys";
        \\export type ExtendedMap<K extends PropertyKey, V> = Record<keys.ExtendedKeys<K>, V>;
        },
    });
    defer graph.deinit();
    const result = try graph.class(1, "ExtendedMap");
    defer result.deinit(T.allocator);
    const declaration = result.declaration;
    const record = declaration.body.?.record;
    const key_reference = record.key.reference;
    try T.expectEqualStrings("ExtendedKeys", key_reference.declaration.name);
    try T.expect(key_reference.arguments[0].parameter == &declaration.parameters[0]);
    try T.expect(record.value.parameter == &declaration.parameters[1]);
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: built-in Error heritage retains its checker-owned shape" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface TypedError<T> extends Error { value: T; }
    }});
    defer graph.deinit();
    const result = try graph.class(0, "TypedError");
    defer result.deinit(T.allocator);
    const body = result.declaration.body.?.intersection;
    try T.expectEqual(@as(usize, 2), body.len);
    try T.expectEqualStrings("Error", body[0].builtin_object);
    try T.expect(body[1].object[0].type.parameter == &result.declaration.parameters[0]);
}

test "class schema: built-in RegExp members retain their checker-owned shape" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface Pattern { value?: RegExp; }
    }});
    defer graph.deinit();
    const result = try graph.class(0, "Pattern");
    defer result.deinit(T.allocator);
    const value = result.declaration.body.?.object[0];
    try T.expect(value.optional);
    try T.expectEqualStrings("RegExp", value.type.builtin_object);
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: parameterized built-ins retain their arguments" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface Remote<T> { check(value: T): T | Promise<T>; }
    }});
    defer graph.deinit();
    const result = try graph.class(0, "Remote");
    defer result.deinit(T.allocator);
    const function = result.declaration.body.?.object[0].type.function;
    const promise = function.result.union_type[1].builtin_reference;
    try T.expectEqualStrings("Promise", promise.name);
    try T.expectEqual(@as(usize, 1), promise.arguments.len);
    try T.expect(promise.arguments[0].parameter == &result.declaration.parameters[0]);
    try T.expect(try schema.Schema.expressionSupported(function.result, T.allocator));
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: generator and error constructor built-ins retain canonical identities" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface Remote<T> {
        \\  bare: Generator;
        \\  generated: Generator<T>;
        \\  asyncGenerated: AsyncGenerator<T, string>;
        \\  error: ErrorConstructor;
        \\}
    }});
    defer graph.deinit();
    const result = try graph.class(0, "Remote");
    defer result.deinit(T.allocator);
    const members = result.declaration.body.?.object;
    try T.expectEqualStrings("Generator", members[0].type.builtin_object);
    try T.expectEqualStrings("Generator", members[1].type.builtin_reference.name);
    try T.expectEqual(@as(usize, 1), members[1].type.builtin_reference.arguments.len);
    try T.expect(members[1].type.builtin_reference.arguments[0].parameter == &result.declaration.parameters[0]);
    try T.expectEqualStrings("AsyncGenerator", members[2].type.builtin_reference.name);
    try T.expectEqual(@as(usize, 2), members[2].type.builtin_reference.arguments.len);
    try T.expectEqualStrings("ErrorConstructor", members[3].type.builtin_object);
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: local Array aliases are not replaced by builtin array shapes" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text = "type Array<X> = { item: X }; export declare class Box<T> { value: Array<T>; }" }});
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    try T.expectEqualStrings("Array", result.declaration.body.?.object[0].type.reference.declaration.name);
}

test "class schema: local Promise aliases are not replaced by builtin references" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text = "type Promise<X> = { local: X }; export interface Box<T> { value: Promise<T>; }" }});
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    const promise = result.declaration.body.?.object[0].type.reference;
    try T.expectEqualStrings("Promise", promise.declaration.name);
    try T.expectEqualStrings("local", promise.declaration.body.?.object[0].name);
    try T.expect(promise.arguments[0].parameter == &result.declaration.parameters[0]);
}

test "class schema: unsupported type forms remain explicit beside generic functions and heritage" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export declare class Secret { private key: string; }
        \\export declare class Child extends Secret {}
        \\export declare class Box<T> { value: readonly [T]; generic: <T>(x: T) => T; }
        \\export declare class Derived<T> extends Box<T> { extra: T; }
    }});
    defer graph.deinit();
    const child = try graph.class(0, "Child");
    defer child.deinit(T.allocator);
    const child_heritage = child.declaration.body.?.intersection;
    try T.expectEqual(@as(usize, 2), child_heritage.len);
    try T.expectEqualStrings("Secret", child_heritage[0].reference.declaration.name);
    try T.expectEqual(@as(usize, 0), child_heritage[0].reference.arguments.len);
    const box = try graph.class(0, "Box");
    defer box.deinit(T.allocator);
    try T.expect(box.declaration.body.?.object[0].type.* == .unsupported);
    const generic = box.declaration.body.?.object[1].type.function;
    try T.expectEqual(@as(usize, 1), generic.type_parameters.len);
    try T.expect(generic.parameters[0].type.parameter == &generic.type_parameters[0]);
    try T.expect(generic.result.parameter == &generic.type_parameters[0]);
    const derived = try graph.class(0, "Derived");
    defer derived.deinit(T.allocator);
    const heritage = derived.declaration.body.?.intersection;
    try T.expectEqual(@as(usize, 2), heritage.len);
    try T.expectEqualStrings("Box", heritage[0].reference.declaration.name);
    try T.expect(heritage[0].reference.arguments[0].parameter == &derived.declaration.parameters[0]);
    try T.expectEqualStrings("extra", heritage[1].object[0].name);
    try T.expect(heritage[1].object[0].type.parameter == &derived.declaration.parameters[0]);
}

test "class schema: ambiguous imported types never select an arbitrary declaration" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/owner.ts", .text = "import { Wrap } from './barrel'; export declare class Box<T> { value: Wrap<T>; }" },
        .{ .path = "/barrel.ts", .text = "export * from './left'; export * from './right';" },
        .{ .path = "/left.ts", .text = "export type Wrap<X> = { left: X };" },
        .{ .path = "/right.ts", .text = "export type Wrap<X> = { right: X };" },
    });
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    try T.expect(result.declaration.body.?.object[0].type.* == .unsupported);
}

test "class schema: numeric literals retain their sign" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text = "export declare class Box<T> { positive: 3; negative: -3; flag: true; text: 'ok'; }" }});
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    const members = result.declaration.body.?.object;
    try T.expectEqual(@as(f64, 3), members[0].type.number);
    try T.expectEqual(@as(f64, -3), members[1].type.number);
    try T.expect(members[2].type.boolean);
    try T.expectEqualStrings("ok", members[3].type.string);
}

test "class schema: unannotated const literal remains exact" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text = "export const KEY = '~tag';" }});
    defer graph.deinit();
    const result = try graph.class(0, "KEY");
    defer result.deinit(T.allocator);
    try T.expectEqualStrings("~tag", result.declaration.body.?.string);
}

test "class schema: annotated const union shorthand uses its initialized member" {
    inline for (.{ false, true }) |javascript| {
        const graph = try TestGraph.init(&.{.{
            .path = if (javascript) "/owner.js" else "/owner.ts",
            .text = if (javascript)
                "/** @type {'ready' | 'idle'} */ const state = 'ready'; export const box = { state, nested: { state } };"
            else
                "const state: 'ready' | 'idle' = 'ready'; export const box = { state, nested: { state } };",
        }});
        defer graph.deinit();
        const result = try graph.class(0, "box");
        defer result.deinit(T.allocator);
        try T.expect(try result.isSupported(T.allocator));
        const members = result.declaration.body.?.object;
        try T.expectEqualStrings("ready", members[0].type.string);
        try T.expectEqualStrings("ready", members[1].type.object[0].type.string);
    }
}

test "class schema: mixed-domain annotated const union keeps its initialized member" {
    inline for (.{ false, true }) |javascript| {
        const graph = try TestGraph.init(&.{.{
            .path = if (javascript) "/owner.js" else "/owner.ts",
            .text = if (javascript)
                "/** @type {'ready' | 7} */ const state = 'ready'; export const box = { state, nested: { state } };"
            else
                "const state: 'ready' | 7 = 'ready'; export const box = { state, nested: { state } };",
        }});
        defer graph.deinit();
        const result = try graph.class(0, "box");
        defer result.deinit(T.allocator);
        try T.expect(try result.isSupported(T.allocator));
        const members = result.declaration.body.?.object;
        try T.expectEqualStrings("ready", members[0].type.string);
        try T.expectEqualStrings("ready", members[1].type.object[0].type.string);
    }
}

test "class schema: a broad primitive in another domain does not erase the initialized literal" {
    inline for (.{ false, true }) |javascript| {
        const graph = try TestGraph.init(&.{.{
            .path = if (javascript) "/owner.js" else "/owner.ts",
            .text = if (javascript)
                "/** @type {'ready' | number} */ const text = 'ready'; /** @type {7 | string} */ const count = 7; export const textBox = { text }; export const countBox = { count };"
            else
                "const text: 'ready' | number = 'ready'; const count: 7 | string = 7; export const textBox = { text }; export const countBox = { count };",
        }});
        defer graph.deinit();
        const text_box = try graph.class(0, "textBox");
        defer text_box.deinit(T.allocator);
        const count_box = try graph.class(0, "countBox");
        defer count_box.deinit(T.allocator);
        try T.expect(try text_box.isSupported(T.allocator));
        try T.expect(try count_box.isSupported(T.allocator));
        try T.expectEqualStrings("ready", text_box.declaration.body.?.object[0].type.string);
        try T.expectEqual(@as(f64, 7), count_box.declaration.body.?.object[0].type.number);
    }
}

test "class schema: broad annotated union does not acquire an initializer literal" {
    const graph = try TestGraph.init(&.{.{
        .path = "/owner.ts",
        .text = "const state: 'ready' | string = 'ready'; export const box = { state };",
    }});
    defer graph.deinit();
    const result = try graph.class(0, "box");
    defer result.deinit(T.allocator);
    const state = result.declaration.body.?.object[0].type;
    try T.expect(state.* == .union_type);
    try T.expectEqual(@as(usize, 2), state.union_type.len);
    try T.expectEqualStrings("ready", state.union_type[0].string);
    try T.expectEqual(Primitive.string_t, state.union_type[1].primitive);
}

test "class schema: imported const initializer retains value declaration identity across hops" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/leaf.ts", .text = "export const leafValue: string = 'text';" },
        .{ .path = "/barrel.ts", .text = "export { leafValue as renamed } from './leaf';" },
        .{ .path = "/middle.ts", .text = "import { renamed as local } from './barrel'; export const value = local;" },
        .{ .path = "/outer.ts", .text = "import { value } from './middle'; export const forwarded = value;" },
    });
    defer graph.deinit();
    const result = try graph.class(3, "forwarded");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const middle = result.declaration.body.?.reference.declaration;
    try T.expectEqualStrings("/middle.ts", middle.path);
    const leaf = middle.body.?.reference.declaration;
    try T.expectEqualStrings("/leaf.ts", leaf.path);
    try T.expectEqual(Primitive.string_t, leaf.body.?.primitive);
}

test "class schema: ambiguous and circular imported values stay unsupported" {
    {
        const graph = try TestGraph.init(&.{
            .{ .path = "/owner.ts", .text = "import { value } from './barrel'; export const forwarded = value;" },
            .{ .path = "/barrel.ts", .text = "export * from './left'; export * from './right';" },
            .{ .path = "/left.ts", .text = "export const value: string = 'left';" },
            .{ .path = "/right.ts", .text = "export const value: number = 1;" },
        });
        defer graph.deinit();
        const result = try graph.class(0, "forwarded");
        defer result.deinit(T.allocator);
        try T.expect(!try result.isSupported(T.allocator));
    }
    {
        const graph = try TestGraph.init(&.{
            .{ .path = "/a.ts", .text = "import { b } from './b'; export const a = b;" },
            .{ .path = "/b.ts", .text = "import { a } from './a'; export const b = a;" },
        });
        defer graph.deinit();
        const result = try graph.class(0, "a");
        defer result.deinit(T.allocator);
        try T.expect(!try result.isSupported(T.allocator));
    }
    {
        const graph = try TestGraph.init(&.{
            .{ .path = "/owner.ts", .text = "import { type value } from './leaf'; export const copied = value;" },
            .{ .path = "/leaf.ts", .text = "export const value: string = 'text';" },
        });
        defer graph.deinit();
        const result = try graph.class(0, "copied");
        defer result.deinit(T.allocator);
        try T.expect(!try result.isSupported(T.allocator));
    }
}

test "class schema: unresolved imported Array is not a builtin array" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/owner.ts", .text = "import { Missing as Array } from './helper'; export declare class Box<T> { value: Array<T>; }" },
        .{ .path = "/helper.ts", .text = "export type Other = string;" },
    });
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    try T.expect(result.declaration.body.?.object[0].type.* == .unsupported);
}

test "class schema: variance and const parameters remain declaration metadata" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text = "export declare class Box<const T, in out U> { value: T; other: U; }" }});
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    try T.expect(result.declaration.parameters[0].is_const);
    try T.expectEqual(@as(u8, 3), result.declaration.parameters[1].variance);
}

test "class schema: explicit this is a receiver rather than a positional parameter" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text = "export declare class Box<T> { value: T; identity(this: { value: T }, value: T): T; }" }});
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    const function = result.declaration.body.?.object[1].type.function;
    try T.expectEqual(@as(usize, 1), function.parameters.len);
    try T.expectEqualStrings("value", function.this_type.?.object[0].name);
    try T.expect(function.this_type.?.object[0].type.parameter == &result.declaration.parameters[0]);
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: polymorphic this remains distinct from ThisType markers" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text = "export interface Fluent { clone(): this; }" }});
    defer graph.deinit();
    const result = try graph.class(0, "Fluent");
    defer result.deinit(T.allocator);
    const function = result.declaration.body.?.object[0].type.function;
    try T.expect(function.result.* == .polymorphic_this);
    try T.expect(function.this_type == null);
    try T.expect(try result.isSupported(T.allocator));
}

test "class schema: mapped conditional aliases retain exported function signatures" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/owner.ts", .text =
        \\import type { Class, ProtoOf } from "./util.js";
        \\type Trait = { value: unknown };
        \\interface FactoryParams { Parent?: typeof Class }
        \\export function factory<T extends Trait, D = T["value"]>(name: string, initializer: (instance: T, definition: D) => void, prototype?: ProtoOf<T>, params?: FactoryParams): void {
        \\  void name;
        \\  void initializer;
        \\  void prototype;
        \\  void params;
        \\}
        },
        .{ .path = "/util.ts", .text =
        \\export * from "./missing.js";
        \\export abstract class Class { constructor(...args: any[]) { void args; } }
        \\export type ProtoOf<T> = {
        \\  [K in keyof T]?: (T[K] extends (...args: infer A) => infer R ? (...args: A) => R : T[K]) | undefined;
        \\} & ThisType<T>;
        },
    });
    defer graph.deinit();
    const result = try graph.class(0, "factory");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const function = result.declaration.body.?.function;
    try T.expectEqual(@as(usize, 4), function.parameters.len);
    const proto_reference = function.parameters[2].type.reference;
    const proto = proto_reference.declaration.body.?.intersection;
    try T.expect(proto_reference.arguments[0].parameter == &result.declaration.parameters[0]);
    try T.expect(proto[0].mapped.constraint.keyof.parameter == &proto_reference.declaration.parameters[0]);
    try T.expect(proto[1].this_type.parameter == &proto_reference.declaration.parameters[0]);
    try T.expect(function.parameters[3].type.reference.declaration.body.?.object[0].type.* == .typeof_class);
}

test "class schema: Extract remains lossless through overloaded mapped handlers" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export type Kind = "a" | "b";
        \\export interface A { kind: "a"; a: number }
        \\export interface B { kind: "b"; b: string }
        \\export type Item = A | B;
        \\export type ItemOfKind<K extends Kind> = [Extract<Item, { kind: K }>] extends [never] ? Item : Extract<Item, { kind: K }>;
        \\export type Handler = (item: Item, rewritten: boolean) => Item;
        \\export type Handlers = { [K in Kind]?: (item: ItemOfKind<K>, rewritten: boolean) => Item };
        \\export declare function visit(item: Item, handler: Handler): Item;
        \\export declare function visit(item: Item, handlers: Handlers): Item;
    }});
    defer graph.deinit();
    const result = try graph.class(0, "visit");
    defer result.deinit(T.allocator);

    try T.expect(try result.isSupported(T.allocator));
    const overloads = result.declaration.body.?.intersection;
    try T.expectEqual(@as(usize, 2), overloads.len);
    const handlers = overloads[1].function.parameters[1].type.reference.declaration.body.?.mapped;
    const item_of_kind = handlers.template.function.parameters[0].type.reference.declaration.body.?.conditional;
    try T.expect(item_of_kind.check.tuple[0].type.utility.kind == .extract);
    try T.expect(item_of_kind.false_branch.utility.kind == .extract);
}

test "class schema: indexed access key domains survive mapped handlers" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface A { _zod: { def: { type: "a" } }; a: number }
        \\export interface B { _zod: { def: { type: "b" } }; b: string }
        \\export type Item = A | B;
        \\export type Kind = Item["_zod"]["def"]["type"];
        \\export type Handlers = { [K in Kind]?: (item: Extract<Item, { _zod: { def: { type: K } } }>) => Item };
        \\export declare function visit(item: Item, handlers: Handlers): Item;
    }});
    defer graph.deinit();
    const result = try graph.class(0, "visit");
    defer result.deinit(T.allocator);

    try T.expect(try result.isSupported(T.allocator));
    const handlers = result.declaration.body.?.function.parameters[1].type.reference.declaration.body.?.mapped;
    const kind = handlers.constraint.reference.declaration.body.?.indexed_access;
    try T.expect(kind.index.* == .string);
    try T.expectEqualStrings("type", kind.index.string);
    try T.expect(kind.object.* == .indexed_access);
}

test "class schema: namespace-qualified handler graphs remain lossless" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/schemas.ts", .text =
        \\export interface A { _zod: { def: { type: "a" } }; a: number }
        \\export interface B { _zod: { def: { type: "b" } }; b: string }
        \\export interface TypeDef { type: "a" | "b" }
        \\export type Types = A | B;
        \\export type SomeType = Types;
        },
        .{ .path = "/visit.ts", .text =
        \\import * as schemas from "./schemas.js";
        \\type AnyType = schemas.Types;
        \\type Kind = schemas.TypeDef["type"];
        \\type TypeOfKind<K extends Kind> = [Extract<schemas.Types, { _zod: { def: { type: K } } }>] extends [never]
        \\  ? AnyType
        \\  : Extract<schemas.Types, { _zod: { def: { type: K } } }>;
        \\export type Handlers = { [K in Kind]?: (item: TypeOfKind<K>, rewritten: boolean) => AnyType };
        \\export declare function visit(item: schemas.SomeType, handler: (item: AnyType, rewritten: boolean) => AnyType): AnyType;
        \\export declare function visit(item: schemas.SomeType, handlers: Handlers): AnyType;
        },
    });
    defer graph.deinit();
    const result = try graph.class(1, "visit");
    defer result.deinit(T.allocator);

    try T.expect(try result.isSupported(T.allocator));
    const overloads = result.declaration.body.?.intersection;
    try T.expectEqual(@as(usize, 2), overloads.len);
    const handlers_reference = overloads[1].function.parameters[1].type.reference;
    try T.expect(!handlers_reference.projection_only);
    const handlers = handlers_reference.declaration.body.?.mapped;
    const kind = handlers.constraint.reference.declaration.body.?.indexed_access;
    try T.expect(!kind.object.reference.projection_only);
    const item_of_kind = handlers.template.function.parameters[0].type.reference.declaration.body.?.conditional;
    const extracted = item_of_kind.check.tuple[0].type.utility;
    try T.expect(extracted.kind == .extract);
    try T.expect(!extracted.source.reference.projection_only);
}

test "class schema: qualified handler graphs preserve paths beside collection references" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/schemas.ts", .text =
        \\export interface A { _zod: { def: { type: "a" }; opaque: Set<string> }; a: number }
        \\export interface B { _zod: { def: { type: "b" }; opaque: Set<string> }; b: string }
        \\export interface TypeDef { type: "a" | "b" }
        \\export type Types = A | B;
        \\export type SomeType = Types;
        },
        .{ .path = "/visit.ts", .text =
        \\import * as schemas from "./schemas.js";
        \\type AnyType = schemas.Types;
        \\type Kind = schemas.TypeDef["type"];
        \\type TypeOfKind<K extends Kind> = Extract<schemas.Types, { _zod: { def: { type: K } } }>;
        \\export type Handlers = { [K in Kind]?: (item: TypeOfKind<K>, rewritten: boolean) => AnyType };
        \\export declare function visit(item: schemas.SomeType, handlers: Handlers): AnyType;
        },
    });
    defer graph.deinit();

    const visit = try graph.class(1, "visit");
    defer visit.deinit(T.allocator);
    try T.expect(!visit.declaration.contextual_only);
    try T.expect(try visit.isSupported(T.allocator));
    const handlers_reference = visit.declaration.body.?.function.parameters[1].type.reference;
    try T.expect(!handlers_reference.contextual_projection);
    try T.expect(!handlers_reference.declaration.contextual_only);
    const item = handlers_reference.declaration.body.?.mapped.template.function.parameters[0].type;
    try T.expect(item.* == .reference);
    try T.expect(!item.reference.contextual_projection);

    const handlers = try graph.class(1, "Handlers");
    defer handlers.deinit(T.allocator);
    try T.expect(!handlers.declaration.contextual_only);
    try T.expect(try handlers.isSupported(T.allocator));
}

test "class schema: qualified imports retain callable shells around opaque leaves" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/owner.ts", .text =
        \\import type * as Shapes from "./shapes.js";
        \\export type Processor<T extends Shapes.Base = Shapes.Base> =
        \\  (schema: T, context: Shapes.Context, params: Shapes.Params) => void;
        \\export type Shadowed<Shapes> = Shapes.Context;
        },
        .{ .path = "/shapes.ts", .text =
        \\export interface Base { value: unknown; }
        \\export interface Context { nested: readonly [string]; }
        \\export interface Params { path: string[]; }
        },
    });
    defer graph.deinit();
    const result = try graph.class(0, "Processor");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    try T.expect(result.declaration.parameters[0].constraint.?.* == .reference);
    const function = result.declaration.body.?.function;
    try T.expect(function.parameters[0].type.parameter == &result.declaration.parameters[0]);
    try T.expect(function.parameters[1].type.* == .opaque_leaf);
    const params = function.parameters[2].type.reference.declaration.body.?.object;
    try T.expectEqualStrings("path", params[0].name);
    try T.expect(params[0].type.* == .array);
    const shadowed = try graph.class(0, "Shadowed");
    defer shadowed.deinit(T.allocator);
    try T.expect(shadowed.declaration.body.?.* == .unsupported);
}

test "class schema: imported callable constraints retain whole qualified Record issue arrays" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/errors.ts", .text =
        \\export type QualifiedRawIssue = Record<string, unknown> & { readonly code: string };
        },
        .{ .path = "/schemas.ts", .text =
        \\import type * as errors from "./errors.js";
        \\export interface ParsePayload { value: unknown; issues: errors.QualifiedRawIssue[]; }
        \\export interface Schema { _zod: { run(payload: ParsePayload): ParsePayload } }
        },
        .{ .path = "/consumer.ts", .text =
        \\import type * as schemas from "./schemas.js";
        \\export type Parse = <T extends schemas.Schema>(schema: T) => unknown;
        },
    });
    defer graph.deinit();
    const result = try graph.class(2, "Parse");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const constraint = result.declaration.body.?.function.type_parameters[0].constraint.?;
    try T.expect(constraint.* == .reference);
    try T.expect(!constraint.reference.contextual_projection);
    try T.expect(!constraint.reference.projection_only);
    const schema_members = constraint.reference.declaration.body.?.object;
    try T.expectEqualStrings("_zod", schema_members[0].name);
    const payload = schema_members[0].type.object[0].type.function.result.reference.declaration.body.?.object;
    try T.expectEqualStrings("issues", payload[1].name);
    try T.expect(payload[1].type.* == .array);
    try T.expect(payload[1].type.array.* == .reference);
    const issue = payload[1].type.array.reference;
    try T.expect(!issue.projection_only);
    const intersection = issue.declaration.body.?.intersection;
    try T.expectEqual(Primitive.string_t, intersection[0].record.key.primitive);
    try T.expectEqual(Primitive.unknown, intersection[0].record.value.primitive);
    try T.expectEqualStrings("code", intersection[1].object[0].name);
    try T.expectEqual(Primitive.string_t, intersection[1].object[0].type.primitive);
}

test "class schema: contextual read coverage follows defaulted qualified aliases" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/errors.ts", .text =
        \\export interface Issue { readonly code: string; readonly message: string; }
        \\type Flatten<T> = { [K in keyof T]: T[K] } & {};
        \\type MakePartial<T, K extends keyof T> = Omit<T, K> & Partial<Pick<T, K>>;
        \\type Raw<T extends Issue = Issue> = T extends any
        \\  ? Flatten<MakePartial<T, "message"> & Record<string, unknown>>
        \\  : never;
        \\export type QualifiedRawIssue<T extends Issue = Issue> = Raw<T>;
        },
        .{ .path = "/schemas.ts", .text =
        \\import type * as errors from "./errors.js";
        \\export interface ParsePayload { issues: errors.QualifiedRawIssue[]; }
        },
    });
    defer graph.deinit();
    const payload = try graph.class(1, "ParsePayload");
    defer payload.deinit(T.allocator);
    const reference = payload.declaration.body.?.object[0].type.array.reference;
    try T.expectEqual(@as(usize, 0), reference.arguments.len);
    try T.expectEqual(@as(usize, 1), reference.declaration.parameters.len);
    try T.expect(reference.projection_only);
    try T.expect(reference.contextual_projection);
    try T.expect(reference.contextual_read != null);
    var builder = try Builder.init(T.allocator, payload.arena.allocator(), &graph.resolver, graph.sources.items);
    defer builder.query.deinit();
    const read = try builder.contextualReadProjection(reference);
    try T.expect(read != null);
    try T.expect(read.?.transformed);
}

test "class schema: generic interface methods retain local type parameters" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export interface Memoizer {
        \\  alloc<T extends object = { fallback: true }>(value: T, fallback?: T): T;
        \\}
    }});
    defer graph.deinit();
    const result = try graph.class(0, "Memoizer");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const function = result.declaration.body.?.object[0].type.function;
    try T.expectEqual(@as(usize, 1), function.type_parameters.len);
    try T.expectEqualStrings("T", function.type_parameters[0].name);
    try T.expect(function.type_parameters[0].constraint.?.* == .primitive);
    try T.expect(function.type_parameters[0].default.?.* == .object);
    try T.expect(function.parameters[0].type.parameter == &function.type_parameters[0]);
    try T.expect(function.parameters[1].type.parameter == &function.type_parameters[0]);
    try T.expect(function.result.parameter == &function.type_parameters[0]);
}

test "class schema: collection shares declarations and survives collector release" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export class Base<T> { value: T; }
        \\export class Derived<T> extends Base<T> { label: string; }
    }});
    defer graph.deinit();
    var collection = try Collection.init(T.allocator, &graph.resolver, graph.sources.items);
    var collection_live = true;
    defer if (collection_live) collection.deinit();
    const source = graph.sources.items[0];
    const base_node = source.compilation.lookupTopLevel("Base").?.decls.items[0];
    const derived_node = source.compilation.lookupTopLevel("Derived").?.decls.items[0];
    const base = @constCast(try collection.collect(source, base_node));
    defer base.deinit(T.allocator);
    const derived = @constCast(try collection.collect(source, derived_node));
    defer derived.deinit(T.allocator);
    const declaration_count = collection.builder.declarations.count();
    const alias = @constCast(try collection.collect(source, base_node));
    defer alias.deinit(T.allocator);
    try T.expectEqual(base.declaration, alias.declaration);
    try T.expectEqual(declaration_count, collection.builder.declarations.count());
    try T.expectEqual(base.shared_graph, derived.shared_graph);
    try T.expectEqual(@as(usize, 4), base.shared_graph.?.references);
    collection.deinit();
    collection_live = false;
    try T.expectEqual(@as(usize, 3), base.shared_graph.?.references);
    try T.expect(try base.isSupported(T.allocator));
    try T.expect(try derived.isSupported(T.allocator));
}

test "class schema: private inferred fields retain independently typed sibling methods" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .syntax_target_es2015 = true, .text =
        \\export class Driver<T> { readonly #data = []; search(): Promise<T[]> { return [] as any; } }
    }});
    defer graph.deinit();
    const driver_schema = try graph.class(0, "Driver");
    defer driver_schema.deinit(T.allocator);
    try T.expect(!try driver_schema.isSupported(T.allocator));
    const members = driver_schema.declaration.body.?.object;
    try T.expectEqual(@as(usize, 2), members.len);
    try T.expect(members[0].type.* == .unsupported);
    try T.expectEqualStrings("search", members[1].name);
    try T.expect(members[1].type.* == .function);
}

test "class schema: cross-file global interfaces retain all source owners" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/first.d.ts", .text = "interface Payload { left: string; }" },
        .{ .path = "/second.d.ts", .text = "interface Payload { right: number; }" },
        .{ .path = "/api.ts", .text = "export declare function take(value: Payload): void;" },
    });
    defer graph.deinit();
    const result = try graph.class(2, "take");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const target = result.declaration.body.?.function.parameters[0].type.reference.declaration;
    try T.expectEqualStrings("/first.d.ts", target.path);
    try T.expectEqual(@as(usize, 2), target.body.?.object.len);
    try T.expectEqualStrings("right", target.body.?.object[0].name);
    try T.expectEqualStrings("left", target.body.?.object[1].name);
}

test "class schema: added default parameters do not rebind earlier fragment names" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/first.d.ts", .text = "type T=number; interface Box { first:T; }" },
        .{ .path = "/second.d.ts", .text = "interface Box<T=string> { second:T; }" },
        .{ .path = "/api.ts", .text = "export declare function take(value:Box):void;" },
    });
    defer graph.deinit();
    const result = try graph.class(2, "take");
    defer result.deinit(T.allocator);
    const target = result.declaration.body.?.function.parameters[0].type.reference.declaration;
    try T.expectEqual(@as(usize, 1), target.parameters.len);
    try T.expect(target.parameters[0].default.?.primitive == Primitive.string_t);
    const first = target.body.?.object[1].type.reference.declaration;
    try T.expectEqualStrings("/first.d.ts", first.path);
    try T.expect(first.body.?.primitive == Primitive.number_t);
    try T.expect(target.body.?.object[0].type.parameter == &target.parameters[0]);
}

test "class schema: recovered unnamed interfaces do not crash owner collection" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/owner.d.ts", .text = "export default interface { value:string; }", .expect_parse_error = true },
        .{ .path = "/api.ts", .text = "import type Value from './owner';export declare function take(value:Value):void;" },
    });
    defer graph.deinit();
    const result = try graph.class(1, "take");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const target = result.declaration.body.?.function.parameters[0].type.reference.declaration;
    try T.expectEqualStrings("value", target.body.?.object[0].name);
}

test "class schema: merged global owner collection releases partial allocations" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/first.d.ts", .text = "interface Payload<T=string>{left:T;next?:Payload<T>}" },
        .{ .path = "/second.d.ts", .text = "interface Payload<T=string>{right:T}" },
        .{ .path = "/api.ts", .text = "export declare function take(value:Payload):void;" },
    });
    defer graph.deinit();
    const Probe = struct {
        fn run(gpa: std.mem.Allocator, owner: *TestGraph) !void {
            const source = owner.sources.items[2];
            const symbol = source.compilation.lookupTopLevel("take").?;
            const result = try collect(gpa, &owner.resolver, owner.sources.items, source, symbol.decls.items[0]);
            defer @constCast(result).deinit(gpa);
            try T.expect(try result.isSupported(gpa));
        }
    };
    try T.checkAllAllocationFailures(T.allocator, Probe.run, .{graph});
}

test "class schema: merged interface overload groups keep declaration priority" {
    const graph = try TestGraph.init(&.{
        .{ .path = "/first.d.ts", .text = "interface Payload{(value:string):1;(value:number):2;new(value:string):3;}" },
        .{ .path = "/second.d.ts", .text = "interface Payload{(value:boolean):4;new(value:boolean):5;}" },
        .{ .path = "/api.ts", .text = "export declare function get():Payload;" },
    });
    defer graph.deinit();
    const result = try graph.class(2, "get");
    defer result.deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const members = result.declaration.body.?.function.result.reference.declaration.body.?.object;
    try T.expectEqual(@as(usize, 5), members.len);
    try T.expectEqualStrings("__call", members[0].name);
    try T.expectEqualStrings("__construct", members[1].name);
    try T.expectEqual(@as(f64, 4), members[0].type.function.result.number);
    try T.expectEqual(@as(f64, 5), members[1].type.function.result.number);
    try T.expectEqual(@as(f64, 1), members[2].type.function.result.number);
    try T.expectEqual(@as(f64, 2), members[3].type.function.result.number);
    try T.expectEqual(@as(f64, 3), members[4].type.function.result.number);
}

test "class schema: duplicate data members retain the first declaration type" {
    for ([_][]const u8{ "string", "number" }) |first| {
        const first_text = try std.fmt.allocPrint(T.allocator, "interface Payload{{value:{s}}}", .{first});
        defer T.allocator.free(first_text);
        const graph = try TestGraph.init(&.{
            .{ .path = "/first.d.ts", .text = first_text },
            .{ .path = "/second.d.ts", .text = "interface Payload{value:boolean}" },
            .{ .path = "/api.ts", .text = "export declare function take(value:Payload):void;" },
        });
        defer graph.deinit();
        const result = try graph.class(2, "take");
        defer result.deinit(T.allocator);
        const target = result.declaration.body.?.function.parameters[0].type.reference.declaration;
        try T.expect(target.interface_own_body.? == target.body.?);
        const members = target.body.?.object;
        try T.expectEqual(@as(usize, 1), members.len);
        const expected = if (std.mem.eql(u8, first, "string")) Primitive.string_t else Primitive.number_t;
        try T.expectEqual(expected, members[0].type.primitive);
    }
}

test "class schema: declared literal priority survives owner lowering" {
    const graph = try TestGraph.init(&.{.{
        .path = "/api.ts",
        .text = "type Alias=\"ok\";interface Holder{value:\"ok\"}" ++
            "export declare function pick(a:\"ok\",b:(\"ok\"),c:null,d:null|string,e:Holder[\"value\"],f:Alias):void;" ++
            "export declare function ordinary(value:(\"ok\")):void;" ++
            "export declare function receiver(this:\"scope\",value:string):void;" ++
            "export declare function templated(value:`ok`):void;",
    }});
    defer graph.deinit();
    for ([_][]const u8{ "pick", "ordinary", "receiver", "templated" }, [_]bool{ true, false, true, true }) |name, literal| {
        const result = try graph.class(0, name);
        defer result.deinit(T.allocator);
        try T.expectEqual(literal, result.declaration.body.?.function.has_literal_types);
    }
}
