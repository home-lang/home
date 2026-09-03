//! Retain bound generic class annotations and the declarations they reference.
const std = @import("std");
const hir = @import("hir");
const binder = @import("binder");
const driver = @import("ts_driver");
const resolver_mod = @import("ts_resolver");
const origins = @import("export_origins.zig");
const schema = driver.ProgramClassSchema;
const Primitive = schema.Primitive;

pub const Source = struct { path: []const u8, compilation: *driver.Compilation };
pub const Key = struct { source: usize, node: hir.NodeId };
const Resolution = union(enum) { declaration: Key, missing, external, unsupported };
const Context = struct {
    source: usize,
    declaration: *schema.Declaration,
    locals: []const *const schema.Parameter = &.{},
    allow_opaque: bool = false,
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

pub const Builder = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    sources: []const Source,
    resolver: *resolver_mod.Resolver,
    query: origins.Query,
    declarations: std.AutoHashMapUnmanaged(Key, *schema.Declaration) = .empty,

    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source) !Builder {
        var result: Builder = .{ .gpa = gpa, .arena = arena, .sources = sources, .resolver = resolver, .query = origins.Query.init(gpa, resolver) };
        errdefer result.query.deinit();
        for (sources) |owner| try result.query.borrow(owner.path, owner.compilation);
        return result;
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

    fn lowerTransferable(self: *Builder, context: Context, node: hir.NodeId) !*const schema.Expression {
        const lowered = try self.lower(context, node);
        if (!context.allow_opaque) return lowered;
        const result = try self.transferable(lowered);
        if (result != lowered) context.declaration.contextual_only = true;
        return result;
    }

    fn extendContext(self: *Builder, context: Context, parameters: []const *const schema.Parameter) !Context {
        const locals = try self.arena.alloc(*const schema.Parameter, context.locals.len + parameters.len);
        @memcpy(locals[0..context.locals.len], context.locals);
        @memcpy(locals[context.locals.len..], parameters);
        return .{ .source = context.source, .declaration = context.declaration, .locals = locals, .allow_opaque = context.allow_opaque };
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

    pub fn declaration(self: *Builder, key: Key) error{OutOfMemory}!*schema.Declaration {
        if (self.declarations.get(key)) |existing| return existing;
        const source = self.sources[key.source];
        const c = source.compilation;
        const kind = c.hir.kindOf(key.node);
        const def = try self.arena.create(schema.Declaration);
        def.* = .{ .path = source.path, .position = c.hir.spanOf(key.node).start, .name = "", .is_class = kind == .class_decl or kind == .class_expr, .is_function = kind == .fn_decl };
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
        if ((kind == .fn_decl or kind == .interface_decl) and info.name != 0 and c.hir.kindOf(info.name) == .identifier) {
            const name = hir.identifierOf(&c.hir, info.name).name;
            const symbol = if (kind == .fn_decl) c.module.root.values.get(name) else c.module.root.types.get(name);
            if (symbol) |bound| {
                if (bound.decls.items.len != 1 and std.mem.indexOfScalar(hir.NodeId, bound.decls.items, key.node) != null) {
                    def.body = try self.expression(.unsupported);
                    return def;
                }
            }
        }
        def.parameters = try self.arena.alloc(schema.Parameter, info.params.len);
        for (info.params, def.parameters) |node, *param| param.* = .{ .name = c.interner.get(hir.typeParameterOf(&c.hir, node).name) };
        const allow_opaque = kind == .type_alias_decl and switch (c.hir.kindOf(hir.typeAliasOf(&c.hir, key.node).aliased)) {
            .fn_type, .constructor_type => true,
            else => false,
        };
        const context: Context = .{ .source = key.source, .declaration = def, .allow_opaque = allow_opaque };
        for (info.params, def.parameters) |node, *param| {
            const value = hir.typeParameterOf(&c.hir, node);
            param.variance = value.variance;
            param.is_const = value.is_const;
            if (value.constraint != 0) param.constraint = try self.lowerTransferable(context, value.constraint);
            if (value.default != 0) param.default = try self.lowerTransferable(context, value.default);
        }
        def.body = if (kind == .type_alias_decl)
            try self.lower(context, hir.typeAliasOf(&c.hir, key.node).aliased)
        else if (kind == .fn_decl)
            try self.functionType(context, &.{}, hir.fnParams(&c.hir, key.node), hir.fnDeclOf(&c.hir, key.node).return_type, false)
        else if (kind == .var_decl or kind == .let_decl or kind == .const_decl) blk: {
            const variable = hir.varDeclOf(&c.hir, key.node);
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
        return def;
    }

    fn interfaceBody(self: *Builder, context: Context, node: hir.NodeId) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        const own = try self.object(context, hir.interfaceMembers(&c.hir, node));
        const bases = hir.interfaceExtends(&c.hir, node);
        if (bases.len == 0) return own;
        const members = try self.arena.alloc(*const schema.Expression, bases.len + 1);
        for (bases, members[0..bases.len]) |base, *result| result.* = try self.lower(context, base);
        members[bases.len] = own;
        return self.expression(.{ .intersection = members });
    }

    fn classBody(self: *Builder, context: Context, node: hir.NodeId) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        if (hir.classOf(&c.hir, node).extends != 0) return self.expression(.unsupported);
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
                    if (std.mem.startsWith(u8, name, "#") or property.is_method) return self.expression(.unsupported);
                    // Inferred fields and computed methods require the owner's
                    // checked type, not a guess from an initializer expression.
                    const value = property.type_annotation;
                    try members.append(self.arena, .{ .name = name, .type = try self.lower(context, value), .optional = property.is_optional, .readonly = property.is_readonly, .visibility = switch (property.visibility) {
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
                    if (function.flags.is_getter or function.flags.is_setter) return self.expression(.unsupported);
                    if (c.hir.kindOf(function.name) != .identifier) return self.expression(.unsupported);
                    try members.append(self.arena, .{ .name = c.interner.get(hir.identifierOf(&c.hir, function.name).name), .type = try self.functionType(context, hir.fnTypeParams(&c.hir, member), params, function.return_type, false), .method = true, .optional = function.flags.is_optional, .visibility = if (function.flags.is_private) .private else if (function.flags.is_protected) .protected else .public });
                },
                .index_signature => return self.expression(.unsupported),
                else => {},
            }
        }
        return self.expression(.{ .object = try members.toOwnedSlice(self.arena) });
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
                        .key = try self.lower(context, index.key_type),
                        .value = try self.lower(context, index.value_type),
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
            if (value.constraint != 0) parameter.constraint = try self.lowerTransferable(function_context, value.constraint);
            if (value.default != 0) parameter.default = try self.lowerTransferable(function_context, value.default);
        }
        var params: std.ArrayListUnmanaged(schema.Element) = .empty;
        var this_type: ?*const schema.Expression = null;
        for (nodes, 0..) |node, i| {
            const value = hir.parameterOf(&c.hir, node);
            if (i == 0 and c.hir.kindOf(value.name) == .identifier and std.mem.eql(u8, c.interner.get(hir.identifierOf(&c.hir, value.name).name), "this")) {
                this_type = try self.lowerTransferable(function_context, value.type_annotation);
                continue;
            }
            try params.append(self.arena, .{ .type = try self.lowerTransferable(function_context, value.type_annotation), .optional = value.flags.is_optional or value.default_value != 0, .rest = value.flags.is_rest });
        }
        const predicate = if (result != 0 and c.hir.kindOf(result) == .type_predicate_type) blk: {
            const value = hir.typePredicateOf(&c.hir, result);
            break :blk schema.TypePredicate{
                .param_index = value.param_index,
                .target = try self.lowerTransferable(function_context, value.target_type),
                .is_asserts = value.is_asserts,
            };
        } else null;
        const result_type = if (predicate) |value|
            try self.expression(.{ .primitive = if (value.is_asserts) Primitive.void_t else Primitive.boolean_t })
        else
            try self.lowerTransferable(function_context, result);
        return self.expression(.{ .function = .{
            .type_parameters = type_parameters,
            .parameters = try params.toOwnedSlice(self.arena),
            .result = result_type,
            .this_type = this_type,
            .predicate = predicate,
            .is_construct = is_construct,
        } });
    }

    fn lower(self: *Builder, context: Context, node: hir.NodeId) error{OutOfMemory}!*const schema.Expression {
        const c = self.sources[context.source].compilation;
        if (node == 0) return self.expression(.unsupported);
        switch (c.hir.kindOf(node)) {
            .type_ref => {
                const ref = hir.typeRefOf(&c.hir, node);
                const name = c.interner.get(ref.name);
                if (ref.qualifier_len == 0) {
                    if (localParameter(context, name)) |parameter| return self.expression(.{ .parameter = parameter });
                    for (context.declaration.parameters) |*param| {
                        if (std.mem.eql(u8, param.name, name)) return self.expression(.{ .parameter = param });
                    }
                } else {
                    if (!context.allow_opaque) return self.expression(.unsupported);
                    context.declaration.contextual_only = true;
                    const qualifiers = hir.typeRefQualifier(&c.hir, node);
                    if (qualifiers.len > 0 and c.hir.kindOf(qualifiers[0]) == .identifier) {
                        const root_name = c.interner.get(hir.identifierOf(&c.hir, qualifiers[0]).name);
                        if (localParameter(context, root_name) != null) return self.expression(.unsupported);
                        for (context.declaration.parameters) |*param| {
                            if (std.mem.eql(u8, param.name, root_name)) return self.expression(.unsupported);
                        }
                    }
                }
                const primitive = if (ref.qualifier_len == 0) std.StaticStringMap(u32).initComptime(.{
                    .{ "any", Primitive.any },               .{ "unknown", Primitive.unknown }, .{ "never", Primitive.never },
                    .{ "string", Primitive.string_t },       .{ "number", Primitive.number_t }, .{ "boolean", Primitive.boolean_t },
                    .{ "undefined", Primitive.undefined_t }, .{ "null", Primitive.null_t },     .{ "void", Primitive.void_t },
                    .{ "object", Primitive.object_t },       .{ "bigint", Primitive.bigint_t }, .{ "symbol", Primitive.symbol_t },
                }).get(name) else null;
                if (primitive) |value| return self.expression(.{ .primitive = value });
                const args = try self.arena.alloc(*const schema.Expression, ref.args_len);
                for (hir.typeRefArgs(&c.hir, node), args) |arg, *out| out.* = try self.lower(context, arg);
                switch (if (ref.qualifier_len == 0) try self.resolve(context.source, node, ref.name) else try self.resolveQualified(context.source, node, ref)) {
                    .declaration => |key| return self.expression(.{ .reference = .{ .declaration = try self.declaration(key), .arguments = args } }),
                    .unsupported => return self.expression(.unsupported),
                    .missing => {
                        // Built-in object shapes live in each checker's local
                        // type pool. Transfer their stable spelling and let the
                        // consumer materialize the same canonical shape.
                        if (args.len == 0 and std.mem.eql(u8, name, "Error"))
                            return self.expression(.{ .builtin_object = name });
                    },
                    .external => {},
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
            .literal_string => return self.expression(.{ .string = c.interner.get(hir.literalStringOf(&c.hir, node).value) }),
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
                const local_context = try self.extendContext(context, &.{parameter});
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
        const bound = self.scopedSymbol(source, node, name) orelse return .missing;
        if (!bound.flags.is_import) {
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
        for (hir.blockStmts(&c.hir, c.root)) |statement| {
            if (c.hir.kindOf(statement) != .import_decl) continue;
            const import = hir.importOf(&c.hir, statement);
            if (import.default_binding != 0 and c.hir.kindOf(import.default_binding) == .identifier and
                hir.identifierOf(&c.hir, import.default_binding).name == name)
                return self.resolveImported(source, c.interner.get(import.module), "default");
            for (hir.importNamed(&c.hir, statement)) |specifier| {
                const value = hir.importSpecifierOf(&c.hir, specifier);
                if (value.local != name) continue;
                return self.resolveImported(source, c.interner.get(import.module), c.interner.get(value.imported));
            }
        }
        return .unsupported;
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

    fn resolveQualified(self: *Builder, source: usize, node: hir.NodeId, ref: hir.TypeRefPayload) error{OutOfMemory}!Resolution {
        const c = self.sources[source].compilation;
        const qualifiers = hir.typeRefQualifier(&c.hir, node);
        if (qualifiers.len != 1 or c.hir.kindOf(qualifiers[0]) != .identifier) return .unsupported;
        const namespace_name = hir.identifierOf(&c.hir, qualifiers[0]).name;
        const bound = self.scopedSymbol(source, qualifiers[0], namespace_name) orelse return .unsupported;
        if (!bound.flags.is_import) return .unsupported;
        for (hir.blockStmts(&c.hir, c.root)) |statement| {
            if (c.hir.kindOf(statement) != .import_decl) continue;
            const import = hir.importOf(&c.hir, statement);
            if (import.namespace_binding == 0 or c.hir.kindOf(import.namespace_binding) != .identifier) continue;
            if (hir.identifierOf(&c.hir, import.namespace_binding).name != namespace_name) continue;
            return self.resolveImported(source, c.interner.get(import.module), c.interner.get(ref.name));
        }
        return .unsupported;
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
        const target = self.resolver.resolve(specifier, self.sources[source].path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .unsupported,
        };
        if (self.resolveDirectExport(target.path, name)) |direct| return direct;
        const resolved = self.query.resolve(target.path, name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .unsupported,
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
const TestFile = struct { path: []const u8, text: []const u8 };
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
            const compilation = try driver.prepareSource(T.allocator, file.text, .{});
            errdefer {
                compilation.deinit();
                T.allocator.destroy(compilation);
            }
            try T.expect(!compilation.has_errors);
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

test "class schema: local Array aliases are not replaced by builtin array shapes" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text = "type Array<X> = { item: X }; export declare class Box<T> { value: Array<T>; }" }});
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    try T.expectEqualStrings("Array", result.declaration.body.?.object[0].type.reference.declaration.name);
}

test "class schema: unsupported type forms remain explicit beside generic functions" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export declare class Box<T> { value: readonly [T]; generic: <T>(x: T) => T; }
        \\export declare class Derived<T> extends Box<T> { extra: T; }
    }});
    defer graph.deinit();
    const box = try graph.class(0, "Box");
    defer box.deinit(T.allocator);
    try T.expect(box.declaration.body.?.object[0].type.* == .unsupported);
    const generic = box.declaration.body.?.object[1].type.function;
    try T.expectEqual(@as(usize, 1), generic.type_parameters.len);
    try T.expect(generic.parameters[0].type.parameter == &generic.type_parameters[0]);
    try T.expect(generic.result.parameter == &generic.type_parameters[0]);
    const derived = try graph.class(0, "Derived");
    defer derived.deinit(T.allocator);
    try T.expect(derived.declaration.body.?.* == .unsupported);
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
