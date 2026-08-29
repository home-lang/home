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
const Resolution = union(enum) { declaration: Key, missing, unsupported };
const Context = struct { source: usize, declaration: *schema.Declaration };

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
    arena: std.mem.Allocator,
    sources: []const Source,
    resolver: *resolver_mod.Resolver,
    query: origins.Query,
    declarations: std.AutoHashMapUnmanaged(Key, *schema.Declaration) = .empty,

    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, resolver: *resolver_mod.Resolver, sources: []const Source) !Builder {
        var result: Builder = .{ .arena = arena, .sources = sources, .resolver = resolver, .query = origins.Query.init(gpa, resolver) };
        errdefer result.query.deinit();
        for (sources) |owner| try result.query.borrow(owner.path, owner.compilation);
        return result;
    }

    fn expression(self: *Builder, value: schema.Expression) !*const schema.Expression {
        const node = try self.arena.create(schema.Expression);
        node.* = value;
        return node;
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
        const context: Context = .{ .source = key.source, .declaration = def };
        for (info.params, def.parameters) |node, *param| {
            const value = hir.typeParameterOf(&c.hir, node);
            param.variance = value.variance;
            param.is_const = value.is_const;
            if (value.constraint != 0) param.constraint = try self.lower(context, value.constraint);
            if (value.default != 0) param.default = try self.lower(context, value.default);
        }
        def.body = if (kind == .type_alias_decl)
            try self.lower(context, hir.typeAliasOf(&c.hir, key.node).aliased)
        else if (kind == .fn_decl)
            try self.functionType(context, hir.fnParams(&c.hir, key.node), hir.fnDeclOf(&c.hir, key.node).return_type)
        else if (kind == .var_decl or kind == .let_decl or kind == .const_decl)
            try self.lower(context, hir.varDeclOf(&c.hir, key.node).type_annotation)
        else if (kind == .interface_decl)
            if (hir.interfaceOf(&c.hir, key.node).extends_len != 0) try self.expression(.unsupported) else try self.object(context, hir.interfaceMembers(&c.hir, key.node))
        else
            try self.classBody(context, key.node);
        return def;
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
                    if (function.type_params_len != 0 or function.flags.is_getter or function.flags.is_setter) return self.expression(.unsupported);
                    if (c.hir.kindOf(function.name) != .identifier) return self.expression(.unsupported);
                    try members.append(self.arena, .{ .name = c.interner.get(hir.identifierOf(&c.hir, function.name).name), .type = try self.functionType(context, params, function.return_type), .method = true, .optional = function.flags.is_optional, .visibility = if (function.flags.is_private) .private else if (function.flags.is_protected) .protected else .public });
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

    fn functionType(self: *Builder, context: Context, nodes: []const hir.NodeId, result: hir.NodeId) !*const schema.Expression {
        const c = self.sources[context.source].compilation;
        var params: std.ArrayListUnmanaged(schema.Element) = .empty;
        var this_type: ?*const schema.Expression = null;
        for (nodes, 0..) |node, i| {
            const value = hir.parameterOf(&c.hir, node);
            if (i == 0 and c.hir.kindOf(value.name) == .identifier and std.mem.eql(u8, c.interner.get(hir.identifierOf(&c.hir, value.name).name), "this")) {
                this_type = try self.lower(context, value.type_annotation);
                continue;
            }
            try params.append(self.arena, .{ .type = try self.lower(context, value.type_annotation), .optional = value.flags.is_optional or value.default_value != 0, .rest = value.flags.is_rest });
        }
        return self.expression(.{ .function = .{ .parameters = try params.toOwnedSlice(self.arena), .result = try self.lower(context, result), .this_type = this_type } });
    }

    fn lower(self: *Builder, context: Context, node: hir.NodeId) error{OutOfMemory}!*const schema.Expression {
        const c = self.sources[context.source].compilation;
        if (node == 0) return self.expression(.unsupported);
        switch (c.hir.kindOf(node)) {
            .type_ref => {
                const ref = hir.typeRefOf(&c.hir, node);
                const name = c.interner.get(ref.name);
                if (ref.qualifier_len != 0) return self.expression(.unsupported);
                for (context.declaration.parameters) |*param| {
                    if (std.mem.eql(u8, param.name, name)) return self.expression(.{ .parameter = param });
                }
                const primitive = std.StaticStringMap(u32).initComptime(.{
                    .{ "any", Primitive.any },               .{ "unknown", Primitive.unknown }, .{ "never", Primitive.never },
                    .{ "string", Primitive.string_t },       .{ "number", Primitive.number_t }, .{ "boolean", Primitive.boolean_t },
                    .{ "undefined", Primitive.undefined_t }, .{ "null", Primitive.null_t },     .{ "void", Primitive.void_t },
                    .{ "object", Primitive.object_t },       .{ "bigint", Primitive.bigint_t }, .{ "symbol", Primitive.symbol_t },
                }).get(name);
                if (primitive) |value| return self.expression(.{ .primitive = value });
                const args = try self.arena.alloc(*const schema.Expression, ref.args_len);
                for (hir.typeRefArgs(&c.hir, node), args) |arg, *out| out.* = try self.lower(context, arg);
                switch (try self.resolve(context.source, node, ref.name)) {
                    .declaration => |key| return self.expression(.{ .reference = .{ .declaration = try self.declaration(key), .arguments = args } }),
                    .unsupported => return self.expression(.unsupported),
                    .missing => {},
                }
                if (args.len == 1 and (std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "ReadonlyArray")))
                    return self.expression(if (std.mem.eql(u8, name, "Array")) .{ .array = args[0] } else .{ .readonly_array = args[0] });
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
            .fn_type => {
                const value = hir.fnTypeOf(&c.hir, node);
                if (value.type_params_len != 0 or value.is_constructor) return self.expression(.unsupported);
                return self.functionType(context, c.hir.child_pool.items[value.params_start..][0..value.params_len], value.return_type);
            },
            .indexed_access_type => {
                const indexed = hir.indexedAccessTypeOf(&c.hir, node);
                return self.expression(.{ .indexed_access = .{
                    .object = try self.lower(context, indexed.object),
                    .index = try self.lower(context, indexed.index),
                } });
            },
            else => return self.expression(.unsupported),
        }
    }

    fn resolve(self: *Builder, source: usize, node: hir.NodeId, name: hir.StringId) error{OutOfMemory}!Resolution {
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
        const bound = symbol orelse return .missing;
        if (!bound.flags.is_import) {
            if (bound.decls.items.len != 1) return .unsupported;
            return .{ .declaration = .{ .source = source, .node = bound.decls.items[0] } };
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

    fn resolveImported(self: *Builder, source: usize, specifier: []const u8, name: []const u8) error{OutOfMemory}!Resolution {
        const target = self.resolver.resolve(specifier, self.sources[source].path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .unsupported,
        };
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

test "class schema: local Array aliases are not replaced by builtin array shapes" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text = "type Array<X> = { item: X }; export declare class Box<T> { value: Array<T>; }" }});
    defer graph.deinit();
    const result = try graph.class(0, "Box");
    defer result.deinit(T.allocator);
    try T.expectEqualStrings("Array", result.declaration.body.?.object[0].type.reference.declaration.name);
}

test "class schema: unsupported type forms remain explicit instead of dropping structure" {
    const graph = try TestGraph.init(&.{.{ .path = "/owner.ts", .text =
        \\export declare class Box<T> { value: readonly [T]; generic: <T>(x: T) => T; }
        \\export declare class Derived<T> extends Box<T> { extra: T; }
    }});
    defer graph.deinit();
    const box = try graph.class(0, "Box");
    defer box.deinit(T.allocator);
    try T.expect(box.declaration.body.?.object[0].type.* == .unsupported);
    try T.expect(box.declaration.body.?.object[1].type.* == .unsupported);
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
