//! Project a checked owner type into the source-owned program schema.
//!
//! Unlike the declaration/HIR projector, this starts from the checker's final
//! TypeId. Inferred fields, reassignment unions and literal widening therefore
//! come from checked semantics rather than source-expression guesses.

const std = @import("std");
const hir = @import("hir");
const driver = @import("ts_driver");

const schema = driver.ProgramClassSchema;
const TypeId = driver.TypeId;
const Primitive = driver.Primitive;

/// Lower one final checked owner type into a caller-owned schema arena.
/// Unlike the HIR projector, this retains inferred parameter and return
/// types even when a JavaScript function has only a partial JSDoc signature.
pub fn lowerTypeInArena(
    arena: std.mem.Allocator,
    path: []const u8,
    compilation: *const driver.Compilation,
    typ: TypeId,
) !*const schema.Expression {
    var builder: Builder = .{
        .arena = arena,
        .path = path,
        .compilation = compilation,
    };
    return builder.lower(typ);
}

/// Project the public call signatures of an owner-checked overload set.
/// The implementation signature is deliberately excluded: it checks the
/// JavaScript body but is not a callable overload in an importing module.
pub fn lowerVisibleOverloadsInArena(
    arena: std.mem.Allocator,
    path: []const u8,
    compilation: *const driver.Compilation,
    signatures: []const TypeId,
) !*const schema.Expression {
    var builder: Builder = .{
        .arena = arena,
        .path = path,
        .compilation = compilation,
    };
    if (signatures.len == 0) return builder.unsupported();
    if (signatures.len == 1) return builder.lower(signatures[0]);
    const members = try arena.alloc(*const schema.Expression, signatures.len);
    for (signatures, members) |signature, *member| member.* = try builder.lower(signature);
    const expression = try arena.create(schema.Expression);
    expression.* = .{ .intersection = members };
    return expression;
}

/// Lower a checked generic function against the declaration projected from
/// that same owner. Type parameters are matched by source identity and name;
/// an unmatched graph stays unsupported instead of becoming an unbound `any`.
pub fn lowerGenericSignatureInArena(
    arena: std.mem.Allocator,
    path: []const u8,
    compilation: *const driver.Compilation,
    typ: TypeId,
    declaration: *const schema.Declaration,
) !*const schema.Expression {
    var builder: Builder = .{
        .arena = arena,
        .path = path,
        .compilation = compilation,
    };
    const generic_types = compilation.checked_types.generic_signature_params.get(typ) orelse return builder.unsupported();
    if (generic_types.len == 0 or generic_types.len != declaration.parameters.len) return builder.unsupported();
    for (generic_types, declaration.parameters) |source_type, parameter| {
        const source_name = compilation.type_interner.typeParameterName(source_type) orelse return builder.unsupported();
        if (!std.mem.eql(u8, compilation.interner.get(source_name), parameter.name)) return builder.unsupported();
    }
    builder.generic_signature = typ;
    builder.generic_type_ids = generic_types;
    builder.generic_parameters = declaration.parameters;
    return builder.lower(typ);
}

pub fn wholeExportTypes(
    gpa: std.mem.Allocator,
    compilation: *const driver.Compilation,
) ![]const TypeId {
    var result: std.ArrayListUnmanaged(TypeId) = .empty;
    errdefer result.deinit(gpa);
    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return result.toOwnedSlice(gpa);
    for (hir.blockStmts(&compilation.hir, compilation.root)) |statement| {
        if (compilation.hir.kindOf(statement) == .export_decl) {
            const exported = hir.exportOf(&compilation.hir, statement);
            if (exported.is_export_equals and exported.decl != hir.none_node_id) {
                const typ = compilation.hir.typeOf(exported.decl);
                if (typ != Primitive.none and std.mem.indexOfScalar(TypeId, result.items, typ) == null)
                    try result.append(gpa, typ);
            }
            continue;
        }
        if (compilation.hir.kindOf(statement) != .assignment) continue;
        var assignment = hir.assignmentOf(&compilation.hir, statement);
        while (true) {
            if (wholeExportTarget(compilation, assignment.target)) {
                const typ = compilation.hir.typeOf(assignment.value);
                if (typ != Primitive.none and std.mem.indexOfScalar(TypeId, result.items, typ) == null)
                    try result.append(gpa, typ);
            }
            if (assignment.value == hir.none_node_id or compilation.hir.kindOf(assignment.value) != .assignment) break;
            assignment = hir.assignmentOf(&compilation.hir, assignment.value);
            if (assignment.op != null) break;
        }
    }
    return result.toOwnedSlice(gpa);
}

pub fn namedExportTypes(
    gpa: std.mem.Allocator,
    compilation: *const driver.Compilation,
    name: []const u8,
) ![]const TypeId {
    var result: std.ArrayListUnmanaged(TypeId) = .empty;
    errdefer result.deinit(gpa);
    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return result.toOwnedSlice(gpa);
    for (hir.blockStmts(&compilation.hir, compilation.root)) |statement| {
        if (compilation.hir.kindOf(statement) != .assignment) continue;
        var assignment = hir.assignmentOf(&compilation.hir, statement);
        while (true) {
            if (namedExportTarget(compilation, assignment.target)) |target_name| {
                if (std.mem.eql(u8, target_name, name)) {
                    // The checked flow table retains the fresh assignment
                    // constraint on a CommonJS module object's mutable
                    // property. Importing checkers regularize this for reads
                    // (`number` for `exports.value = 1`) while retaining the
                    // fresh `1` for writes such as
                    // `require("./owner").value = 2`.
                    const typ = namedExportFlowType(compilation, assignment.target) orelse
                        compilation.hir.typeOf(assignment.value);
                    if (typ != Primitive.none and std.mem.indexOfScalar(TypeId, result.items, typ) == null)
                        try result.append(gpa, typ);
                }
            }
            if (assignment.value == hir.none_node_id or compilation.hir.kindOf(assignment.value) != .assignment) break;
            assignment = hir.assignmentOf(&compilation.hir, assignment.value);
            if (assignment.op != null) break;
        }
    }
    return result.toOwnedSlice(gpa);
}

fn namedExportFlowType(compilation: *const driver.Compilation, target: hir.NodeId) ?TypeId {
    const prop_name = propertyAccessName(compilation, target) orelse return null;
    const object = propertyAccessObject(compilation, target) orelse return null;
    const object_name = if (compilation.hir.kindOf(object) == .identifier) blk: {
        const identifier = hir.identifierOf(&compilation.hir, object);
        if (!std.mem.eql(u8, compilation.interner.get(identifier.name), "exports")) return null;
        break :blk identifier.name;
    } else if (wholeExportTarget(compilation, object))
        compilation.interner.lookup("module.exports") orelse return null
    else
        return null;
    return compilation.checked_types.commonjs_export_narrows.get(.{
        .obj_name = object_name,
        .prop_name = prop_name,
    });
}

fn wholeExportTarget(compilation: *const driver.Compilation, target: hir.NodeId) bool {
    const member = switch (compilation.hir.kindOf(target)) {
        .member_access => hir.memberOf(&compilation.hir, target),
        .element_access => blk: {
            const element = hir.elementOf(&compilation.hir, target);
            if (compilation.hir.kindOf(element.index) != .literal_string) return false;
            break :blk hir.MemberPayload{
                .object = element.object,
                .name = hir.literalStringOf(&compilation.hir, element.index).value,
                .optional = false,
            };
        },
        else => return false,
    };
    return compilation.hir.kindOf(member.object) == .identifier and
        std.mem.eql(u8, compilation.interner.get(hir.identifierOf(&compilation.hir, member.object).name), "module") and
        std.mem.eql(u8, compilation.interner.get(member.name), "exports");
}

fn namedExportTarget(compilation: *const driver.Compilation, target: hir.NodeId) ?[]const u8 {
    const name = propertyAccessName(compilation, target) orelse return null;
    const object = propertyAccessObject(compilation, target) orelse return null;
    if (compilation.hir.kindOf(object) == .identifier and
        std.mem.eql(u8, compilation.interner.get(hir.identifierOf(&compilation.hir, object).name), "exports"))
    {
        return compilation.interner.get(name);
    }
    const exports_name = propertyAccessName(compilation, object) orelse return null;
    if (!std.mem.eql(u8, compilation.interner.get(exports_name), "exports")) return null;
    const module_object = propertyAccessObject(compilation, object) orelse return null;
    if (compilation.hir.kindOf(module_object) != .identifier or
        !std.mem.eql(u8, compilation.interner.get(hir.identifierOf(&compilation.hir, module_object).name), "module"))
    {
        return null;
    }
    return compilation.interner.get(name);
}

fn propertyAccessName(compilation: *const driver.Compilation, node: hir.NodeId) ?hir.StringId {
    return switch (compilation.hir.kindOf(node)) {
        .member_access => hir.memberOf(&compilation.hir, node).name,
        .element_access => blk: {
            const index = hir.elementOf(&compilation.hir, node).index;
            if (compilation.hir.kindOf(index) != .literal_string) break :blk null;
            break :blk hir.literalStringOf(&compilation.hir, index).value;
        },
        else => null,
    };
}

fn propertyAccessObject(compilation: *const driver.Compilation, node: hir.NodeId) ?hir.NodeId {
    return switch (compilation.hir.kindOf(node)) {
        .member_access => hir.memberOf(&compilation.hir, node).object,
        .element_access => hir.elementOf(&compilation.hir, node).object,
        else => null,
    };
}

pub fn collect(
    gpa: std.mem.Allocator,
    path: []const u8,
    compilation: *const driver.Compilation,
    root_types: []const TypeId,
    position: u32,
) !*const schema.Schema {
    const result = try gpa.create(schema.Schema);
    result.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .declaration = undefined };
    errdefer result.deinit(gpa);
    var builder: Builder = .{
        .arena = result.arena.allocator(),
        .path = path,
        .compilation = compilation,
    };
    const root_declaration = if (root_types.len == 1)
        try builder.classDeclaration(root_types[0])
    else
        null;
    if (root_declaration) |declaration| {
        result.declaration = declaration;
    } else {
        const declaration = try builder.arena.create(schema.Declaration);
        const body = if (root_types.len == 1)
            try builder.lower(root_types[0])
        else
            try builder.typeList(root_types, true);
        declaration.* = .{
            .path = path,
            .position = position,
            .name = "",
            .body = body,
        };
        result.declaration = declaration;
    }
    return result;
}

const Builder = struct {
    arena: std.mem.Allocator,
    path: []const u8,
    compilation: *const driver.Compilation,
    expressions: std.AutoHashMapUnmanaged(TypeId, *const schema.Expression) = .empty,
    active: std.AutoHashMapUnmanaged(TypeId, void) = .empty,
    declarations: std.AutoHashMapUnmanaged(TypeId, *schema.Declaration) = .empty,
    generic_signature: ?TypeId = null,
    generic_type_ids: []const TypeId = &.{},
    generic_parameters: []const schema.Parameter = &.{},

    fn expression(self: *Builder, value: schema.Expression) error{OutOfMemory}!*const schema.Expression {
        const result = try self.arena.create(schema.Expression);
        result.* = value;
        return result;
    }

    fn unsupported(self: *Builder) error{OutOfMemory}!*const schema.Expression {
        return self.expression(.unsupported);
    }

    fn classDeclaration(self: *Builder, typ: TypeId) error{OutOfMemory}!?*schema.Declaration {
        if (self.declarations.get(typ)) |existing| return existing;
        const node = self.compilation.checked_types.class_decl_by_instance.get(typ) orelse return null;
        if (node == hir.none_node_id or node >= self.compilation.hir.nodeCount()) return null;
        const declaration = try self.arena.create(schema.Declaration);
        declaration.* = .{
            .path = self.path,
            .position = self.compilation.hir.spanOf(node).start,
            .name = if (self.compilation.checked_types.class_name_by_instance.get(typ)) |name|
                self.compilation.interner.get(name)
            else
                "",
            .is_class = true,
        };
        try self.declarations.put(self.arena, typ, declaration);
        declaration.body = try self.objectBody(typ, declaration);
        return declaration;
    }

    fn lower(self: *Builder, typ: TypeId) error{OutOfMemory}!*const schema.Expression {
        if (typ == Primitive.true_lit) return self.expression(.{ .boolean = true });
        if (typ == Primitive.false_lit) return self.expression(.{ .boolean = false });
        if (typ > Primitive.none and typ < Primitive.first_dynamic) return self.expression(.{ .primitive = typ });
        if (typ < Primitive.first_dynamic or typ >= self.compilation.type_interner.pool.typeCount()) return self.unsupported();

        if (self.compilation.checked_types.class_decl_by_instance.get(typ) != null) {
            const declaration = (try self.classDeclaration(typ)) orelse return self.unsupported();
            return self.expression(.{ .reference = .{ .declaration = declaration, .arguments = &.{} } });
        }
        if (self.expressions.get(typ)) |existing| return existing;
        if (self.active.contains(typ)) return self.unsupported();
        try self.active.put(self.arena, typ, {});
        defer _ = self.active.remove(typ);

        const value = try self.lowerUncached(typ);
        try self.expressions.put(self.arena, typ, value);
        return value;
    }

    fn lowerUncached(self: *Builder, typ: TypeId) error{OutOfMemory}!*const schema.Expression {
        const interner = &self.compilation.type_interner;
        const flags = interner.pool.flagsOf(typ);
        if (self.compilation.checked_types.builtin_generic_kinds.get(typ)) |kind| {
            const source = self.compilation.checked_types.alias_type_args.get(typ) orelse return self.unsupported();
            const arguments = try self.arena.alloc(*const schema.Expression, source.len);
            for (source, arguments) |argument, *out| out.* = try self.lower(argument);
            return self.expression(.{ .builtin_reference = .{ .name = kind.name(), .arguments = arguments } });
        }
        if (flags.is_union) return self.typeList(interner.unionMembers(typ), true);
        if (flags.is_intersection) return self.typeList(interner.intersectionMembers(typ), false);
        if (flags.is_literal) {
            const literal = interner.literalOfOrNull(typ) orelse return self.unsupported();
            return switch (literal) {
                .string_lit => |name| self.expression(.{ .string = self.compilation.interner.get(name) }),
                .number_lit => |bits| self.expression(.{ .number = @bitCast(bits) }),
                .boolean_lit => |value| self.expression(.{ .boolean = value }),
                .bigint_lit => self.unsupported(),
            };
        }
        if (flags.is_type_parameter) {
            for (self.generic_type_ids, self.generic_parameters) |source_type, *parameter| {
                if (source_type == typ) return self.expression(.{ .parameter = parameter });
            }
            const name = interner.typeParameterName(typ) orelse return self.unsupported();
            if (std.mem.eql(u8, self.compilation.interner.get(name), "this"))
                return self.expression(.polymorphic_this);
            return self.unsupported();
        }
        if (flags.is_tuple) {
            const payload = interner.pool.tuple_payloads.items[interner.pool.payloadOf(typ)];
            const source = interner.pool.tuple_element_pool.items[payload.elements_start..][0..payload.elements_len];
            const elements = try self.arena.alloc(schema.Element, source.len);
            for (source, elements) |item, *out| out.* = .{
                .type = try self.lower(item.type),
                .optional = item.is_optional,
                .rest = item.is_rest,
            };
            return self.expression(.{ .tuple = elements });
        }
        if (interner.isSignature(typ)) return self.signature(typ);
        if (flags.is_object_type) {
            const payload = interner.pool.object_type_payloads.items[interner.pool.payloadOf(typ)];
            if (self.compilation.checked_types.array_origin_types.contains(typ) and
                payload.number_index_type != Primitive.none)
            {
                const element = try self.lower(payload.number_index_type);
                return self.expression(if (self.compilation.checked_types.readonly_index_types.contains(typ))
                    .{ .readonly_array = element }
                else
                    .{ .array = element });
            }
            if (payload.call_sig != 0 or payload.construct_sig != 0 or
                payload.string_index_type != Primitive.none or payload.number_index_type != Primitive.none or
                payload.symbol_index_type != Primitive.none) return self.unsupported();
            return self.objectBody(typ, null);
        }
        return self.unsupported();
    }

    fn typeList(self: *Builder, source: []const TypeId, union_type: bool) error{OutOfMemory}!*const schema.Expression {
        const values = try self.arena.alloc(*const schema.Expression, source.len);
        for (source, values) |typ, *out| out.* = try self.lower(typ);
        return self.expression(if (union_type) .{ .union_type = values } else .{ .intersection = values });
    }

    fn objectBody(self: *Builder, typ: TypeId, declaration: ?*const schema.Declaration) error{OutOfMemory}!*const schema.Expression {
        const source = self.compilation.type_interner.objectMembers(typ);
        const members = try self.arena.alloc(schema.Member, source.len);
        for (source, members) |member, *out| {
            if (member.visibility != .public and declaration == null) return self.unsupported();
            out.* = .{
                .name = self.compilation.interner.get(member.name),
                .type = try self.lower(member.type),
                .optional = member.is_optional,
                .readonly = member.is_readonly,
                .method = member.is_method,
                .visibility = member.visibility,
            };
        }
        return self.expression(.{ .object = members });
    }

    fn signature(self: *Builder, typ: TypeId) error{OutOfMemory}!*const schema.Expression {
        if (self.compilation.checked_types.generic_signature_params.contains(typ) and
            (self.generic_signature == null or self.generic_signature.? != typ)) return self.unsupported();
        const interner = &self.compilation.type_interner;
        const payload = interner.pool.signature_payloads.items[interner.pool.payloadOf(typ)];
        if (payload.is_construct) return self.unsupported();
        const source = interner.signatureParams(typ);
        const parameters = try self.arena.alloc(schema.Element, source.len);
        const minimum = self.compilation.checked_types.signature_min_args.get(typ) orelse source.len;
        const is_rest = self.compilation.checked_types.rest_signatures.contains(typ);
        const names = self.compilation.checked_types.signature_param_names.get(typ);
        for (source, parameters, 0..) |param, *out, index| out.* = .{
            .type = try self.lower(param),
            .name = if (names) |signature_names|
                if (index < signature_names.len) self.compilation.interner.get(signature_names[index]) else null
            else
                null,
            .optional = index >= minimum,
            .rest = is_rest and index + 1 == source.len,
        };
        return self.expression(.{ .function = .{
            .parameters = parameters,
            .result = try self.lower(payload.return_type),
            .this_type = if (payload.has_this_type) try self.lower(payload.this_type) else null,
            .has_literal_types = payload.has_literal_types,
        } });
    }
};

const T = std.testing;

test "checked schema: whole CommonJS export retains inferred class fields and reassignment unions" {
    const source =
        \\class Service { value = 'text'; }
        \\class Other { value = 1; }
        \\module.exports = new Service();
        \\module.exports = new Other();
    ;
    const compilation = try driver.compileSource(T.allocator, source, .{
        .allow_js = true,
        .check_js = true,
        .no_emit = true,
        .importer_path = "/owner.js",
    });
    defer {
        compilation.deinit();
        T.allocator.destroy(compilation);
    }
    const types = try wholeExportTypes(T.allocator, compilation);
    defer T.allocator.free(types);
    try T.expectEqual(@as(usize, 2), types.len);
    const result = try collect(T.allocator, "/owner.js", compilation, types, 65);
    defer @constCast(result).deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const body = result.declaration.body orelse return error.TestUnexpectedResult;
    try T.expect(body.* == .union_type);
    try T.expectEqual(@as(usize, 2), body.union_type.len);
    for (body.union_type) |member| {
        try T.expect(member.* == .reference);
        const class_body = member.reference.declaration.body orelse return error.TestUnexpectedResult;
        try T.expect(class_body.* == .object);
        try T.expectEqualStrings("value", class_body.object[0].name);
        try T.expect(class_body.object[0].type.* == .primitive);
    }
}

test "checked schema: named CommonJS export retains its fresh checked assignment type" {
    const source = "exports.value = 1;";
    const compilation = try driver.compileSource(T.allocator, source, .{
        .allow_js = true,
        .check_js = true,
        .no_emit = true,
        .importer_path = "/owner.js",
    });
    defer {
        compilation.deinit();
        T.allocator.destroy(compilation);
    }
    const export_types = try namedExportTypes(T.allocator, compilation, "value");
    defer T.allocator.free(export_types);
    try T.expectEqual(@as(usize, 1), export_types.len);
    const result = try collect(T.allocator, "/owner.js", compilation, export_types, 0);
    defer @constCast(result).deinit(T.allocator);
    try T.expect(try result.isSupported(T.allocator));
    const body = result.declaration.body orelse return error.TestUnexpectedResult;
    try T.expect(body.* == .number);
    try T.expectEqual(@as(f64, 1), body.number);
}

test "checked schema: projected callable retains declared literal priority" {
    for ([_][]const u8{ "\"ok\"", "(\"ok\")", "Alias" }, [_]bool{ true, false, false }) |annotation, literal| {
        const source = try std.fmt.allocPrint(T.allocator, "type Alias='ok';declare const module:{{exports:any}};function pick(value:{s}):'yes'{{return 'yes'}}module.exports=pick;", .{annotation});
        defer T.allocator.free(source);
        const compilation = try driver.compileSource(T.allocator, source, .{ .no_emit = true, .importer_path = "/owner.cts" });
        defer {
            compilation.deinit();
            T.allocator.destroy(compilation);
        }
        try T.expect(!compilation.has_errors);
        const signatures = try wholeExportTypes(T.allocator, compilation);
        defer T.allocator.free(signatures);
        try T.expectEqual(@as(usize, 1), signatures.len);
        const result = try collect(T.allocator, "/owner.cts", compilation, signatures, 0);
        defer @constCast(result).deinit(T.allocator);
        try T.expect(try result.isSupported(T.allocator));
        const body = result.declaration.body orelse return error.TestUnexpectedResult;
        try T.expect(body.* == .function);
        try T.expectEqual(literal, body.function.has_literal_types);
    }
}
