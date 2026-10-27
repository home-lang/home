//! Exact primitive facts recovered from declaration-adjacent JSDoc.
//! The tag parser owns syntax recognition; this module only associates those
//! tags with Program declarations, class fields, and direct constructor assignments.

const std = @import("std");
const hir = @import("hir");
const driver = @import("ts_driver");
const jsdoc = @import("ts_parser").jsdoc;

pub const Primitive = enum {
    any,
    unknown,
    never,
    void_t,
    null_t,
    undefined_t,
    string_t,
    number_t,
    boolean_t,
    bigint_t,
    symbol_t,
    object_t,
};

pub const Container = enum {
    array,
    readonly_array,
};

pub const ObjectMember = struct {
    /// Borrowed from the declaration's JSDoc source until the schema copies it.
    name: []const u8,
    type_expression: TypeExpression,
    optional: bool = false,
    readonly: bool = false,
};

pub const ObjectIndex = struct {
    /// Borrowed from the declaration's JSDoc source until the schema copies it.
    name: []const u8,
    key: TypeExpression,
    value: TypeExpression,
    readonly: bool = false,
};

pub const IndexedObject = struct {
    members: []ObjectMember,
    indices: []ObjectIndex,
};

/// A lossless subset of JSDoc type expressions that can cross Program-owned
/// checker pools without borrowing checker-local TypeIds. Containers are
/// stored from outermost to innermost, so `Array<ReadonlyArray<string>>` is
/// represented by `{ array, readonly_array }` around `string`.
pub const TypeExpression = struct {
    base: union(enum) {
        primitive: Primitive,
        string_literal: []u8,
        number_literal: f64,
        boolean_literal: bool,
        parameter: []const u8,
        unsupported,
        union_type: []TypeExpression,
        object_type: []ObjectMember,
        indexed_object: IndexedObject,
    },
    containers: []Container = &.{},

    pub fn deinit(self: TypeExpression, gpa: std.mem.Allocator) void {
        if (self.containers.len > 0) gpa.free(self.containers);
        switch (self.base) {
            .primitive, .number_literal, .boolean_literal, .parameter, .unsupported => {},
            .string_literal => |value| gpa.free(value),
            .union_type => |members| {
                for (members) |member| member.deinit(gpa);
                gpa.free(members);
            },
            .object_type => |members| {
                for (members) |member| member.type_expression.deinit(gpa);
                gpa.free(members);
            },
            .indexed_object => |object| {
                for (object.members) |member| member.type_expression.deinit(gpa);
                gpa.free(object.members);
                for (object.indices) |index| {
                    index.key.deinit(gpa);
                    index.value.deinit(gpa);
                }
                gpa.free(object.indices);
            },
        }
    }

    pub fn barePrimitive(self: TypeExpression) ?Primitive {
        if (self.containers.len > 0) return null;
        return switch (self.base) {
            .primitive => |primitive| primitive,
            .string_literal, .number_literal, .boolean_literal, .parameter, .unsupported, .union_type, .object_type, .indexed_object => null,
        };
    }

    pub fn transferable(self: TypeExpression) bool {
        return switch (self.base) {
            .unsupported => false,
            .union_type => |members| blk: {
                for (members) |member| if (!member.transferable()) break :blk false;
                break :blk true;
            },
            .object_type => |members| blk: {
                for (members) |member| if (!member.type_expression.transferable()) break :blk false;
                break :blk true;
            },
            .indexed_object => |object| blk: {
                for (object.members) |member| if (!member.type_expression.transferable()) break :blk false;
                for (object.indices) |index| {
                    if (!index.key.transferable() or !index.value.transferable()) break :blk false;
                }
                break :blk true;
            },
            else => true,
        };
    }
};

pub const AssignedField = struct {
    name: []const u8,
    type_expression: TypeExpression,
};

pub const FunctionParameter = struct {
    type_expression: TypeExpression,
    optional: bool,
    rest: bool,
};

pub const FunctionSignature = struct {
    parameters: []FunctionParameter,
    result: TypeExpression,

    pub fn deinit(self: FunctionSignature, gpa: std.mem.Allocator) void {
        for (self.parameters) |parameter| parameter.type_expression.deinit(gpa);
        gpa.free(self.parameters);
        self.result.deinit(gpa);
    }
};

pub fn isJavaScriptPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".jsx") or
        std.mem.endsWith(u8, path, ".mjs") or
        std.mem.endsWith(u8, path, ".cjs");
}

/// JavaScript widens primitive initializer literals even for `const`
/// declarations. TypeScript source keeps their fresh literal types instead,
/// so callers must also establish that the owner is a JavaScript file.
pub fn widenedInitializerPrimitive(c: *const driver.Compilation, node: hir.NodeId) ?Primitive {
    if (node == hir.none_node_id) return null;
    return switch (c.hir.kindOf(node)) {
        .literal_string, .template_literal => .string_t,
        .literal_number => .number_t,
        .literal_bool => .boolean_t,
        .literal_bigint => .bigint_t,
        .literal_undefined => .undefined_t,
        else => null,
    };
}

pub fn declarationType(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId) !?TypeExpression {
    return declarationTypeWithParameters(gpa, c, node, &.{});
}

pub fn declarationTypeWithParameters(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId, parameter_names: []const []const u8) !?TypeExpression {
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse return null;
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);
    for (tags) |tag| {
        if (tag.kind == .type_tag) return (try parseTypeExpressionWithParameters(gpa, tag.type_text, parameter_names)) orelse TypeExpression{ .base = .unsupported };
    }
    return null;
}

pub const TemplateParameter = struct {
    name: []const u8,
    constraint: ?TypeExpression = null,
    default: ?TypeExpression = null,
};

pub fn deinitTemplateParameters(gpa: std.mem.Allocator, parameters: []TemplateParameter) void {
    for (parameters) |parameter| {
        if (parameter.constraint) |value| value.deinit(gpa);
        if (parameter.default) |value| value.deinit(gpa);
    }
    gpa.free(parameters);
}

/// Declaration-level JSDoc templates are lowered using source-owned
/// parameter identities. A constraint or default is admitted only when its
/// whole type expression can be transferred.
pub fn declarationTemplateParameters(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId) !?[]TemplateParameter {
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse return &.{};
    if (std.mem.indexOf(u8, body, "@template") == null) return &.{};
    // In a mixed JSDoc block, templates preceding @overload belong to the
    // individual public signature, not to the exported function declaration.
    // The implementation is never callable through the import boundary.
    if (bodyHasOverloadTag(body)) return &.{};
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);
    const Raw = struct { name: []const u8, constraint_text: []const u8 = "", default_text: []const u8 = "" };
    var raw: std.ArrayListUnmanaged(Raw) = .empty;
    defer raw.deinit(gpa);
    for (tags) |tag| {
        if (tag.kind != .template_tag) continue;
        if (!identifierName(tag.name) or tag.is_const or tag.template_variance != .none or (tag.has_default and tag.default_text.len == 0)) return null;
        for (raw.items) |existing| if (std.mem.eql(u8, existing.name, tag.name)) return null;
        try raw.append(gpa, .{
            .name = tag.name,
            .constraint_text = tag.type_text,
            .default_text = if (tag.has_default) tag.default_text else "",
        });
        const extra = std.mem.trim(u8, tag.description, " \t\r\n");
        if (extra.len == 0) continue;
        if (extra[0] != ',') return null;
        var parts = std.mem.splitScalar(u8, extra[1..], ',');
        while (parts.next()) |part| {
            const name = std.mem.trim(u8, part, " \t\r\n");
            if (!identifierName(name)) return null;
            for (raw.items) |existing| if (std.mem.eql(u8, existing.name, name)) return null;
            try raw.append(gpa, .{ .name = name });
        }
    }
    if (raw.items.len == 0) return &.{};
    const names = try gpa.alloc([]const u8, raw.items.len);
    defer gpa.free(names);
    for (raw.items, names) |parameter, *name| name.* = parameter.name;
    const result = try gpa.alloc(TemplateParameter, raw.items.len);
    for (raw.items, result) |parameter, *out| out.* = .{ .name = parameter.name };
    var transferred = false;
    defer if (!transferred) deinitTemplateParameters(gpa, result);
    for (raw.items, result) |parameter, *out| {
        if (parameter.constraint_text.len > 0) {
            out.constraint = try parseTypeExpressionWithParameters(gpa, parameter.constraint_text, names) orelse return null;
            if (!out.constraint.?.transferable()) return null;
        }
        if (parameter.default_text.len > 0) {
            out.default = try parseTypeExpressionWithParameters(gpa, parameter.default_text, names) orelse return null;
            if (!out.default.?.transferable()) return null;
        }
    }
    transferred = true;
    return result;
}

fn bodyHasOverloadTag(body: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len > 0 and line[0] == '*') line = std.mem.trim(u8, line[1..], " \t\r");
        if (!std.mem.startsWith(u8, line, "@overload")) continue;
        if (line.len == "@overload".len or std.ascii.isWhitespace(line["@overload".len])) return true;
    }
    return false;
}

pub fn functionSignature(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId, parameter_names: []const []const u8) !?FunctionSignature {
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse return null;
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);
    // A malformed template must not be projected as a nongeneric callable.
    for (tags) |tag| if (tag.kind == .template_tag and parameter_names.len == 0) return null;
    var result: ?TypeExpression = null;
    var result_transferred = false;
    defer if (!result_transferred) if (result) |value| value.deinit(gpa);
    for (tags) |tag| {
        if (tag.kind != .returns_tag) continue;
        if (result != null) return null;
        result = try parseTypeExpressionWithParameters(gpa, tag.type_text, parameter_names) orelse return null;
    }
    const return_type = result orelse return null;
    const nodes = hir.fnParams(&c.hir, node);
    for (nodes) |parameter_node| {
        const parameter = hir.parameterOf(&c.hir, parameter_node);
        if (c.hir.kindOf(parameter.name) != .identifier) return null;
        const name = c.interner.get(hir.identifierOf(&c.hir, parameter.name).name);
        const tag = uniqueParameterTag(tags, name) orelse return null;
        if (parameter.flags.is_rest and (tag.optional or parameter.default_value != hir.none_node_id)) return null;
        var parsed = try parameterTypeExpressionWithParameters(gpa, tag.type_text, parameter.flags.is_rest, parameter_names) orelse return null;
        parsed.deinit(gpa);
    }
    const parameters = try gpa.alloc(FunctionParameter, nodes.len);
    var initialized: usize = 0;
    errdefer {
        for (parameters[0..initialized]) |parameter| parameter.type_expression.deinit(gpa);
        gpa.free(parameters);
    }
    for (nodes, parameters) |parameter_node, *parameter_result| {
        const parameter = hir.parameterOf(&c.hir, parameter_node);
        const name = c.interner.get(hir.identifierOf(&c.hir, parameter.name).name);
        const tag = uniqueParameterTag(tags, name).?;
        parameter_result.* = .{
            .type_expression = (try parameterTypeExpressionWithParameters(gpa, tag.type_text, parameter.flags.is_rest, parameter_names)).?,
            .optional = tag.optional or parameter.flags.is_optional or parameter.default_value != hir.none_node_id,
            .rest = parameter.flags.is_rest,
        };
        initialized += 1;
    }
    result_transferred = true;
    return .{ .parameters = parameters, .result = return_type };
}

/// A parameter-only JSDoc function needs its checked, inferred return type
/// before its complete signature can be transferred to an importing file.
pub fn hasParameterWithoutReturn(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId) !bool {
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse return false;
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);
    var has_parameter = false;
    for (tags) |tag| switch (tag.kind) {
        .param_tag => has_parameter = true,
        .returns_tag => return false,
        else => {},
    };
    return has_parameter;
}

pub fn constructorAssignedFields(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId, parameter_names: []const []const u8) ![]AssignedField {
    const function = hir.fnDeclOf(&c.hir, node);
    if (!function.flags.is_constructor or function.body == hir.none_node_id or c.hir.kindOf(function.body) != .block_stmt) return &.{};
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse "";
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);

    var fields: std.ArrayListUnmanaged(AssignedField) = .empty;
    errdefer {
        for (fields.items) |field| field.type_expression.deinit(gpa);
        fields.deinit(gpa);
    }
    for (hir.blockStmts(&c.hir, function.body)) |statement| {
        if (c.hir.kindOf(statement) != .assignment) continue;
        const assignment = hir.assignmentOf(&c.hir, statement);
        if (assignment.op != null or c.hir.kindOf(assignment.target) != .member_access) continue;
        const member = hir.memberOf(&c.hir, assignment.target);
        if (!isThisExpression(c, member.object)) continue;
        const field_name = c.interner.get(member.name);
        if (contains(fields.items, field_name)) continue;
        // A declaration-adjacent @type on the assignment is the field's
        // declared type. Without one, a direct assignment from an annotated
        // constructor parameter carries that parameter's type.
        const type_expression = (try declarationTypeWithParameters(gpa, c, statement, parameter_names)) orelse blk: {
            if (c.hir.kindOf(assignment.value) != .identifier) break :blk null;
            const value_name = hir.identifierOf(&c.hir, assignment.value).name;
            if (!isParameter(c, node, value_name)) break :blk null;
            break :blk try parameterType(gpa, tags, c.interner.get(value_name), parameter_names);
        } orelse continue;
        if (!type_expression.transferable()) {
            type_expression.deinit(gpa);
            continue;
        }
        errdefer type_expression.deinit(gpa);
        try fields.append(gpa, .{ .name = field_name, .type_expression = type_expression });
    }
    return fields.toOwnedSlice(gpa);
}

pub fn deinitAssignedFields(gpa: std.mem.Allocator, fields: []AssignedField) void {
    for (fields) |field| field.type_expression.deinit(gpa);
    gpa.free(fields);
}

/// Return a complete JSDoc constructor parameter list for source-owned class
/// schema transfer. A partial list cannot safely drive generic inference.
pub fn constructorParameters(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId, parameter_names: []const []const u8) !?[]FunctionParameter {
    const function = hir.fnDeclOf(&c.hir, node);
    if (!function.flags.is_constructor) return null;
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse return null;
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);
    const nodes = hir.fnParams(&c.hir, node);
    if (nodes.len == 0) return null;
    const parameters = try gpa.alloc(FunctionParameter, nodes.len);
    var initialized: usize = 0;
    var transferred = false;
    defer if (!transferred) {
        for (parameters[0..initialized]) |parameter| parameter.type_expression.deinit(gpa);
        gpa.free(parameters);
    };
    for (nodes, parameters) |parameter_node, *out| {
        const parameter = hir.parameterOf(&c.hir, parameter_node);
        if (parameter.flags.is_rest or c.hir.kindOf(parameter.name) != .identifier) return null;
        const name = c.interner.get(hir.identifierOf(&c.hir, parameter.name).name);
        const tag = uniqueParameterTag(tags, name) orelse return null;
        const typ = try parseTypeExpressionWithParameters(gpa, tag.type_text, parameter_names) orelse return null;
        if (!typ.transferable()) {
            typ.deinit(gpa);
            return null;
        }
        out.* = .{
            .type_expression = typ,
            .optional = tag.optional or parameter.flags.is_optional or parameter.default_value != hir.none_node_id,
            .rest = false,
        };
        initialized += 1;
    }
    transferred = true;
    return parameters;
}

pub fn deinitFunctionParameters(gpa: std.mem.Allocator, parameters: []FunctionParameter) void {
    for (parameters) |parameter| parameter.type_expression.deinit(gpa);
    gpa.free(parameters);
}

pub fn typeName(primitive: Primitive) []const u8 {
    return switch (primitive) {
        .any => "any",
        .unknown => "unknown",
        .never => "never",
        .void_t => "void",
        .null_t => "null",
        .undefined_t => "undefined",
        .string_t => "string",
        .number_t => "number",
        .boolean_t => "boolean",
        .bigint_t => "bigint",
        .symbol_t => "symbol",
        .object_t => "object",
    };
}

fn parameterType(gpa: std.mem.Allocator, tags: []const jsdoc.Tag, name: []const u8, parameter_names: []const []const u8) !?TypeExpression {
    for (tags) |tag| {
        if (tag.kind == .param_tag and std.mem.eql(u8, tag.name, name)) return parseTypeExpressionWithParameters(gpa, tag.type_text, parameter_names);
    }
    return null;
}

fn uniqueParameterTag(tags: []const jsdoc.Tag, name: []const u8) ?jsdoc.Tag {
    var result: ?jsdoc.Tag = null;
    for (tags) |tag| {
        if (tag.kind != .param_tag or !std.mem.eql(u8, tag.name, name)) continue;
        if (result != null) return null;
        result = tag;
    }
    return result;
}

fn parsePrimitive(text: []const u8) ?Primitive {
    const name = std.mem.trim(u8, text, " \t\r\n");
    const entries = .{
        .{ "any", Primitive.any },
        .{ "unknown", Primitive.unknown },
        .{ "never", Primitive.never },
        .{ "void", Primitive.void_t },
        .{ "null", Primitive.null_t },
        .{ "undefined", Primitive.undefined_t },
        .{ "string", Primitive.string_t },
        .{ "number", Primitive.number_t },
        .{ "boolean", Primitive.boolean_t },
        .{ "bigint", Primitive.bigint_t },
        .{ "symbol", Primitive.symbol_t },
        .{ "object", Primitive.object_t },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

fn parseTypeExpression(gpa: std.mem.Allocator, text: []const u8) !?TypeExpression {
    return parseTypeExpressionWithParameters(gpa, text, &.{});
}

fn parseTypeExpressionWithParameters(gpa: std.mem.Allocator, text: []const u8, parameter_names: []const []const u8) error{OutOfMemory}!?TypeExpression {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (topLevelUnionEnd(trimmed)) |first_end| {
        var members: std.ArrayListUnmanaged(TypeExpression) = .empty;
        errdefer {
            for (members.items) |member| member.deinit(gpa);
            members.deinit(gpa);
        }
        var start: usize = 0;
        var end = first_end;
        while (true) {
            const member = try parseTypeExpressionWithParameters(gpa, trimmed[start..end], parameter_names) orelse {
                for (members.items) |item| item.deinit(gpa);
                members.deinit(gpa);
                return null;
            };
            members.append(gpa, member) catch |err| {
                member.deinit(gpa);
                return err;
            };
            if (end == trimmed.len) break;
            start = end + 1;
            end = if (topLevelUnionEnd(trimmed[start..])) |relative_end| start + relative_end else trimmed.len;
        }
        return .{ .base = .{ .union_type = try members.toOwnedSlice(gpa) } };
    }
    if (nullableBody(trimmed)) |body| {
        const value = try parseTypeExpressionWithParameters(gpa, body, parameter_names) orelse return null;
        errdefer value.deinit(gpa);
        const members = try gpa.alloc(TypeExpression, 2);
        members[0] = value;
        members[1] = .{ .base = .{ .primitive = .null_t } };
        return .{ .base = .{ .union_type = members } };
    }

    var containers: std.ArrayListUnmanaged(Container) = .empty;
    errdefer containers.deinit(gpa);
    var current = trimmed;
    while (true) {
        if (std.mem.endsWith(u8, current, "[]")) {
            try containers.append(gpa, .array);
            current = std.mem.trim(u8, current[0 .. current.len - 2], " \t\r\n");
            continue;
        }
        if (genericBody(current, "ReadonlyArray")) |body| {
            try containers.append(gpa, .readonly_array);
            current = body;
            continue;
        }
        if (genericBody(current, "Array")) |body| {
            try containers.append(gpa, .array);
            current = body;
            continue;
        }
        break;
    }
    var base: TypeExpression = if (parsePrimitive(current)) |primitive|
        .{ .base = .{ .primitive = primitive } }
    else if (try parseLiteral(gpa, current)) |literal|
        literal
    else if (try parseObjectType(gpa, current, parameter_names)) |object|
        object
    else if (matchingParameter(current, parameter_names)) |name|
        .{ .base = .{ .parameter = name } }
    else if (outerGroupBody(current)) |body|
        (try parseTypeExpressionWithParameters(gpa, body, parameter_names) orelse {
            containers.deinit(gpa);
            return null;
        })
    else if (topLevelUnionEnd(current) != null or nullableBody(current) != null)
        (try parseTypeExpressionWithParameters(gpa, current, parameter_names) orelse {
            containers.deinit(gpa);
            return null;
        })
    else {
        containers.deinit(gpa);
        return null;
    };
    if (containers.items.len == 0) return base;
    errdefer base.deinit(gpa);
    const combined = try gpa.alloc(Container, containers.items.len + base.containers.len);
    @memcpy(combined[0..containers.items.len], containers.items);
    @memcpy(combined[containers.items.len..], base.containers);
    if (base.containers.len > 0) gpa.free(base.containers);
    base.containers = combined;
    containers.deinit(gpa);
    return base;
}

/// JSDoc object types retain named members and open string/number/symbol index
/// signatures. Methods, computed keys, and malformed members leave the whole
/// declaration unsupported rather than publishing a partial shape.
fn parseObjectType(gpa: std.mem.Allocator, text: []const u8, parameter_names: []const []const u8) error{OutOfMemory}!?TypeExpression {
    if (text.len < 2 or text[0] != '{' or text[text.len - 1] != '}') return null;
    const body = std.mem.trim(u8, text[1 .. text.len - 1], " \t\r\n");
    var members: std.ArrayListUnmanaged(ObjectMember) = .empty;
    defer {
        for (members.items) |member| member.type_expression.deinit(gpa);
        members.deinit(gpa);
    }
    var indices: std.ArrayListUnmanaged(ObjectIndex) = .empty;
    defer {
        for (indices.items) |index| {
            index.key.deinit(gpa);
            index.value.deinit(gpa);
        }
        indices.deinit(gpa);
    }
    var start: usize = 0;
    while (start < body.len) {
        const relative_end = topLevelObjectDelimiter(body[start..], ",;") orelse body.len - start;
        const end = start + relative_end;
        const segment = std.mem.trim(u8, body[start..end], " \t\r\n");
        if (segment.len == 0) return null;
        const colon = topLevelObjectDelimiter(segment, ":") orelse return null;
        var key = std.mem.trim(u8, segment[0..colon], " \t\r\n");
        var readonly = false;
        if (std.mem.startsWith(u8, key, "readonly") and key.len > "readonly".len and std.ascii.isWhitespace(key["readonly".len])) {
            readonly = true;
            key = std.mem.trim(u8, key["readonly".len..], " \t\r\n");
        }
        if (key.len >= 2 and key[0] == '[' and key[key.len - 1] == ']') {
            const header = std.mem.trim(u8, key[1 .. key.len - 1], " \t\r\n");
            const key_colon = std.mem.indexOfScalar(u8, header, ':') orelse return null;
            const parameter = std.mem.trim(u8, header[0..key_colon], " \t\r\n");
            const domain = std.mem.trim(u8, header[key_colon + 1 ..], " \t\r\n");
            if (!isObjectMemberName(parameter)) return null;
            const key_type = parsePrimitive(domain) orelse return null;
            if (key_type != .string_t and key_type != .number_t and key_type != .symbol_t) return null;
            for (indices.items) |index| if (index.key.base.primitive == key_type) return null;
            const value = try parseTypeExpressionWithParameters(gpa, segment[colon + 1 ..], parameter_names) orelse return null;
            indices.append(gpa, .{
                .name = parameter,
                .key = .{ .base = .{ .primitive = key_type } },
                .value = value,
                .readonly = readonly,
            }) catch |err| {
                value.deinit(gpa);
                return err;
            };
            start = end + 1;
            continue;
        }
        const optional = std.mem.endsWith(u8, key, "?");
        if (optional) key = std.mem.trimEnd(u8, key[0 .. key.len - 1], " \t\r\n");
        if (!isObjectMemberName(key)) return null;
        for (members.items) |member| if (std.mem.eql(u8, member.name, key)) return null;
        const value = try parseTypeExpressionWithParameters(gpa, segment[colon + 1 ..], parameter_names) orelse return null;
        members.append(gpa, .{
            .name = key,
            .type_expression = value,
            .optional = optional,
            .readonly = readonly,
        }) catch |err| {
            value.deinit(gpa);
            return err;
        };
        start = end + 1;
    }
    const owned_members = try members.toOwnedSlice(gpa);
    if (indices.items.len == 0) return .{ .base = .{ .object_type = owned_members } };
    errdefer {
        for (owned_members) |member| member.type_expression.deinit(gpa);
        gpa.free(owned_members);
    }
    return .{ .base = .{ .indexed_object = .{
        .members = owned_members,
        .indices = try indices.toOwnedSlice(gpa),
    } } };
}

fn isObjectMemberName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_' or name[0] == '$')) return false;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$')) return false;
    return true;
}

fn topLevelObjectDelimiter(text: []const u8, delimiters: []const u8) ?usize {
    var angle: usize = 0;
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (text, 0..) |byte, index| {
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        switch (byte) {
            '<' => angle += 1,
            '>' => if (angle == 0) return null else {
                angle -= 1;
            },
            '(' => paren += 1,
            ')' => if (paren == 0) return null else {
                paren -= 1;
            },
            '[' => bracket += 1,
            ']' => if (bracket == 0) return null else {
                bracket -= 1;
            },
            '{' => brace += 1,
            '}' => if (brace == 0) return null else {
                brace -= 1;
            },
            else => {},
        }
        if (angle == 0 and paren == 0 and bracket == 0 and brace == 0 and std.mem.indexOfScalar(u8, delimiters, byte) != null) return index;
    }
    return null;
}

fn matchingParameter(name: []const u8, parameters: []const []const u8) ?[]const u8 {
    for (parameters) |parameter| if (std.mem.eql(u8, name, parameter)) return parameter;
    return null;
}

fn parseLiteral(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?TypeExpression {
    if (text.len >= 2 and (text[0] == '\'' or text[0] == '"') and text[text.len - 1] == text[0]) {
        const raw = text[1 .. text.len - 1];
        var index: usize = 0;
        while (index < raw.len) : (index += 1) {
            if (raw[index] == '\n' or raw[index] == '\r' or raw[index] == text[0]) return null;
            if (raw[index] == '\\') {
                if (index + 1 == raw.len) return null;
                index += 1;
            }
        }
        var cooked: std.ArrayListUnmanaged(u8) = .empty;
        errdefer cooked.deinit(gpa);
        try driver.ProgramClassSchema.appendCookedStringText(gpa, raw, &cooked);
        return .{ .base = .{ .string_literal = try cooked.toOwnedSlice(gpa) } };
    }
    if (std.mem.eql(u8, text, "true")) return .{ .base = .{ .boolean_literal = true } };
    if (std.mem.eql(u8, text, "false")) return .{ .base = .{ .boolean_literal = false } };
    if (text.len == 0) return null;
    const first_digit: usize = if (text[0] == '-') 1 else 0;
    if (first_digit >= text.len or !std.ascii.isDigit(text[first_digit])) return null;
    const number = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(number)) return null;
    return .{ .base = .{ .number_literal = number } };
}

/// JSDoc accepts both prefix `?T` and postfix `T?` nullable forms. Parse
/// these before peeling containers so `?Array<T>` is nullable as a whole,
/// while `Array<?T>` has nullable elements.
fn nullableBody(text: []const u8) ?[]const u8 {
    if (text.len < 2) return null;
    if (text[0] == '?') return std.mem.trim(u8, text[1..], " \t\r\n");
    if (text[text.len - 1] == '?') return std.mem.trim(u8, text[0 .. text.len - 1], " \t\r\n");
    return null;
}

/// Only a pipe outside generic arguments, grouping, and array brackets
/// separates union members. Returning null also leaves unsupported object
/// and function syntax to the ordinary conservative parse failure.
fn topLevelUnionEnd(text: []const u8) ?usize {
    var angle: usize = 0;
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (text, 0..) |byte, index| {
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        switch (byte) {
            '<' => angle += 1,
            '>' => {
                if (angle == 0) return null;
                angle -= 1;
            },
            '(' => paren += 1,
            ')' => {
                if (paren == 0) return null;
                paren -= 1;
            },
            '[' => bracket += 1,
            ']' => {
                if (bracket == 0) return null;
                bracket -= 1;
            },
            '{' => brace += 1,
            '}' => {
                if (brace == 0) return null;
                brace -= 1;
            },
            '|' => if (angle == 0 and paren == 0 and bracket == 0 and brace == 0) return index,
            else => {},
        }
    }
    return null;
}

fn outerGroupBody(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[0] != '(' or text[text.len - 1] != ')') return null;
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (text, 0..) |byte, index| {
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        switch (byte) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0 and index + 1 != text.len) return null;
            },
            else => {},
        }
    }
    if (depth != 0) return null;
    return std.mem.trim(u8, text[1 .. text.len - 1], " \t\r\n");
}

fn parameterTypeExpression(gpa: std.mem.Allocator, text: []const u8, rest: bool) !?TypeExpression {
    return parameterTypeExpressionWithParameters(gpa, text, rest, &.{});
}

fn parameterTypeExpressionWithParameters(gpa: std.mem.Allocator, text: []const u8, rest: bool, parameter_names: []const []const u8) !?TypeExpression {
    if (!rest) return parseTypeExpressionWithParameters(gpa, text, parameter_names);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "...")) {
        var parsed = try parseTypeExpressionWithParameters(gpa, std.mem.trim(u8, trimmed[3..], " \t\r\n"), parameter_names) orelse return null;
        errdefer parsed.deinit(gpa);
        const containers = try gpa.alloc(Container, parsed.containers.len + 1);
        containers[0] = .array;
        @memcpy(containers[1..], parsed.containers);
        if (parsed.containers.len > 0) gpa.free(parsed.containers);
        parsed.containers = containers;
        return parsed;
    }
    const parsed = try parseTypeExpressionWithParameters(gpa, trimmed, parameter_names) orelse return null;
    if (parsed.containers.len > 0) return parsed;
    parsed.deinit(gpa);
    return null;
}

fn genericBody(text: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, name)) return null;
    var cursor = name.len;
    if (cursor < text.len and text[cursor] == '.') cursor += 1;
    if (cursor >= text.len or text[cursor] != '<' or text[text.len - 1] != '>') return null;
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (text[cursor..], cursor..) |byte, index| {
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        switch (byte) {
            '<' => depth += 1,
            '>' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0 and index + 1 != text.len) return null;
            },
            else => {},
        }
    }
    if (depth != 0) return null;
    return std.mem.trim(u8, text[cursor + 1 .. text.len - 1], " \t\r\n");
}

test "JSDoc primitive array expressions preserve nested mutable and readonly wrappers" {
    const parsed = (try parseTypeExpression(std.testing.allocator, "Array.<ReadonlyArray<string[]>>")).?;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Primitive.string_t, parsed.base.primitive);
    try std.testing.expectEqualSlices(Container, &.{ .array, .readonly_array, .array }, parsed.containers);
}

test "JSDoc numeric and boolean literal annotations retain exact values" {
    for ([_]struct { []const u8, f64 }{
        .{ "1", 1 },
        .{ "-2", -2 },
        .{ "1e2", 100 },
    }) |case| {
        const parsed = (try parseTypeExpression(std.testing.allocator, case[0])).?;
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[1], parsed.base.number_literal);
    }
    for ([_]struct { []const u8, bool }{
        .{ "true", true },
        .{ "false", false },
    }) |case| {
        const parsed = (try parseTypeExpression(std.testing.allocator, case[0])).?;
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[1], parsed.base.boolean_literal);
    }
    try std.testing.expect((try parseTypeExpression(std.testing.allocator, "'unterminated")) == null);
}

test "JSDoc string literal annotations retain cooked values and union boundaries" {
    for ([_]struct { []const u8, []const u8 }{
        .{ "'ready'", "ready" },
        .{ "\"ready\"", "ready" },
        .{ "'a|b'", "a|b" },
        .{ "'a\\'b'", "a'b" },
        .{ "'a\\u{1F600}'", "a😀" },
    }) |case| {
        const parsed = (try parseTypeExpression(std.testing.allocator, case[0])).?;
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case[1], parsed.base.string_literal);
    }
    const union_value = (try parseTypeExpression(std.testing.allocator, "'a|b' | 'idle'")).?;
    defer union_value.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), union_value.base.union_type.len);
    try std.testing.expectEqualStrings("a|b", union_value.base.union_type[0].base.string_literal);
    try std.testing.expectEqualStrings("idle", union_value.base.union_type[1].base.string_literal);
    const grouped = (try parseTypeExpression(std.testing.allocator, "('a)b' | 'c')")).?;
    defer grouped.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a)b", grouped.base.union_type[0].base.string_literal);
    const array = (try parseTypeExpression(std.testing.allocator, "Array<'a>b'>")).?;
    defer array.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Container, &.{.array}, array.containers);
    try std.testing.expectEqualStrings("a>b", array.base.string_literal);
    try std.testing.expect((try parseTypeExpression(std.testing.allocator, "'bad' tail")) == null);
}

test "JSDoc union expression parser preserves precedence and nested wrappers" {
    const union_array = (try parseTypeExpression(std.testing.allocator, "Array<string | number>")).?;
    defer union_array.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Container, &.{.array}, union_array.containers);
    try std.testing.expectEqual(@as(usize, 2), union_array.base.union_type.len);
    try std.testing.expectEqual(Primitive.string_t, union_array.base.union_type[0].base.primitive);
    try std.testing.expectEqual(Primitive.number_t, union_array.base.union_type[1].base.primitive);

    const mixed = (try parseTypeExpression(std.testing.allocator, "string | number[]")).?;
    defer mixed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), mixed.base.union_type.len);
    try std.testing.expectEqual(@as(usize, 0), mixed.base.union_type[0].containers.len);
    try std.testing.expectEqualSlices(Container, &.{.array}, mixed.base.union_type[1].containers);

    const readonly = (try parseTypeExpression(std.testing.allocator, "ReadonlyArray<(string | number)[]>")).?;
    defer readonly.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Container, &.{ .readonly_array, .array }, readonly.containers);
    try std.testing.expectEqual(@as(usize, 2), readonly.base.union_type.len);

    try std.testing.expect((try parseTypeExpression(std.testing.allocator, "string | ")) == null);
    const object_array = (try parseTypeExpression(std.testing.allocator, "Array<string | { value: number }>")).?;
    defer object_array.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), object_array.base.union_type.len);
    try std.testing.expectEqualStrings("value", object_array.base.union_type[1].base.object_type[0].name);
}

test "JSDoc finite object types preserve nested, optional and readonly members" {
    const parsed = (try parseTypeExpression(std.testing.allocator, "{ readonly count: number; label?: string; nested: { enabled: boolean | null } }")).?;
    defer parsed.deinit(std.testing.allocator);
    const members = parsed.base.object_type;
    try std.testing.expectEqual(@as(usize, 3), members.len);
    try std.testing.expectEqualStrings("count", members[0].name);
    try std.testing.expect(members[0].readonly and !members[0].optional);
    try std.testing.expect(members[1].optional and !members[1].readonly);
    try std.testing.expectEqualStrings("nested", members[2].name);
    try std.testing.expectEqual(@as(usize, 1), members[2].type_expression.base.object_type.len);
    try std.testing.expectEqual(@as(usize, 2), members[2].type_expression.base.object_type[0].type_expression.base.union_type.len);
    try std.testing.expect((try parseTypeExpression(std.testing.allocator, "{ value: string; value: number }")) == null);
    try std.testing.expect((try parseTypeExpression(std.testing.allocator, "{ run(): number }")) == null);
    const trailing = (try parseTypeExpression(std.testing.allocator, "{ count: number; label: string; }")).?;
    defer trailing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), trailing.base.object_type.len);
}

test "JSDoc object index signatures retain open key and value types" {
    const gpa = std.testing.allocator;
    const parsed = (try parseTypeExpression(gpa, "{ known: number; [key: string]: number; [position: number]: number; [token: symbol]: boolean }")).?;
    defer parsed.deinit(gpa);
    const object = parsed.base.indexed_object;
    try std.testing.expectEqual(@as(usize, 1), object.members.len);
    try std.testing.expectEqualStrings("known", object.members[0].name);
    try std.testing.expectEqual(@as(usize, 3), object.indices.len);
    try std.testing.expectEqual(Primitive.string_t, object.indices[0].key.base.primitive);
    try std.testing.expectEqualStrings("key", object.indices[0].name);
    try std.testing.expectEqual(Primitive.number_t, object.indices[0].value.base.primitive);
    try std.testing.expectEqual(Primitive.number_t, object.indices[1].key.base.primitive);
    try std.testing.expectEqual(Primitive.symbol_t, object.indices[2].key.base.primitive);
    try std.testing.expectEqual(Primitive.boolean_t, object.indices[2].value.base.primitive);
    try std.testing.expect(parsed.transferable());
    try std.testing.expect((try parseTypeExpression(gpa, "{ [key: string]: number; [other: string]: string }")) == null);
    const readonly_index = (try parseTypeExpression(gpa, "{ readonly [key: string]: number }")).?;
    defer readonly_index.deinit(gpa);
    try std.testing.expect(readonly_index.base.indexed_object.indices[0].readonly);
    try std.testing.expect((try parseTypeExpression(gpa, "{ [key: boolean]: number }")) == null);
}

test "JSDoc nullable expressions preserve whole-array and element precedence" {
    for ([_][]const u8{ "?string", "string?" }) |text| {
        const parsed = (try parseTypeExpression(std.testing.allocator, text)).?;
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), parsed.base.union_type.len);
        try std.testing.expectEqual(Primitive.string_t, parsed.base.union_type[0].base.primitive);
        try std.testing.expectEqual(Primitive.null_t, parsed.base.union_type[1].base.primitive);
    }

    const whole = (try parseTypeExpression(std.testing.allocator, "?Array<number>")).?;
    defer whole.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), whole.containers.len);
    try std.testing.expectEqualSlices(Container, &.{.array}, whole.base.union_type[0].containers);
    try std.testing.expectEqual(Primitive.null_t, whole.base.union_type[1].base.primitive);

    const elements = (try parseTypeExpression(std.testing.allocator, "ReadonlyArray<?number>")).?;
    defer elements.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Container, &.{.readonly_array}, elements.containers);
    try std.testing.expectEqual(Primitive.number_t, elements.base.union_type[0].base.primitive);
    try std.testing.expectEqual(Primitive.null_t, elements.base.union_type[1].base.primitive);

    try std.testing.expect((try parseTypeExpression(std.testing.allocator, "?")) == null);
    try std.testing.expect((try parseTypeExpression(std.testing.allocator, "?Array<MissingType>")) == null);
}

test "JSDoc rest parameter expressions preserve element and array forms" {
    const scalar = (try parameterTypeExpression(std.testing.allocator, "...number", true)).?;
    defer scalar.deinit(std.testing.allocator);
    try std.testing.expectEqual(Primitive.number_t, scalar.base.primitive);
    try std.testing.expectEqualSlices(Container, &.{.array}, scalar.containers);

    const arrays = (try parameterTypeExpression(std.testing.allocator, "...number[]", true)).?;
    defer arrays.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Container, &.{ .array, .array }, arrays.containers);

    const explicit = (try parameterTypeExpression(std.testing.allocator, "number[]", true)).?;
    defer explicit.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Container, &.{.array}, explicit.containers);
    try std.testing.expect((try parameterTypeExpression(std.testing.allocator, "number", true)) == null);

    const union_rest = (try parameterTypeExpression(std.testing.allocator, "...(string | number)", true)).?;
    defer union_rest.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Container, &.{.array}, union_rest.containers);
    try std.testing.expectEqual(@as(usize, 2), union_rest.base.union_type.len);
}

fn isParameter(c: *const driver.Compilation, function: hir.NodeId, name: hir.StringId) bool {
    for (hir.fnParams(&c.hir, function)) |node| {
        const parameter = hir.parameterOf(&c.hir, node);
        if (c.hir.kindOf(parameter.name) == .identifier and hir.identifierOf(&c.hir, parameter.name).name == name) return true;
    }
    return false;
}

fn isThisExpression(c: *const driver.Compilation, node: hir.NodeId) bool {
    return switch (c.hir.kindOf(node)) {
        .this_expr => true,
        .identifier => std.mem.eql(u8, c.interner.get(hir.identifierOf(&c.hir, node).name), "this"),
        else => false,
    };
}

fn contains(fields: []const AssignedField, name: []const u8) bool {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return true;
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn identifierName(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] != '$')) return false;
    for (name[1..]) |byte| if (!isIdentChar(byte)) return false;
    return true;
}

fn leadingBody(source: []const u8, declaration_start: u32) ?[]const u8 {
    var limit = @min(@as(usize, declaration_start), source.len);
    // HIR spans start after declaration modifiers. The JSDoc belongs to the
    // declaration before the full prefix (`export default async function`,
    // `export class`, or `static` class fields), not the final keyword.
    while (true) {
        var end = limit;
        while (end > 0 and std.ascii.isWhitespace(source[end - 1])) : (end -= 1) {}
        var prefix: ?usize = null;
        inline for (.{ "async", "default", "static", "export" }) |keyword| {
            if (end >= keyword.len and
                std.mem.eql(u8, source[end - keyword.len .. end], keyword) and
                (end == keyword.len or !isIdentChar(source[end - keyword.len - 1])))
            {
                prefix = end - keyword.len;
                break;
            }
        }
        limit = prefix orelse break;
    }
    var cursor = limit;
    const end = while (true) {
        while (cursor > 0 and std.ascii.isWhitespace(source[cursor - 1])) cursor -= 1;
        if (cursor >= 2 and std.mem.eql(u8, source[cursor - 2 .. cursor], "*/")) break cursor - 2;
        var line_start = cursor;
        while (line_start > 0 and source[line_start - 1] != '\n' and source[line_start - 1] != '\r') line_start -= 1;
        const line_comment = std.mem.indexOf(u8, source[line_start..cursor], "//") orelse return null;
        cursor = line_start + line_comment;
    };
    var start_cursor = end;
    const start = while (start_cursor > 0) {
        start_cursor -= 1;
        if (start_cursor + 2 > end or source[start_cursor] != '/' or source[start_cursor + 1] != '*') continue;
        if (start_cursor + 2 < source.len and source[start_cursor + 2] == '*') break start_cursor;
        return null;
    } else return null;
    return source[start + 3 .. end];
}

test "JSDoc leading body traverses complete default declaration modifiers" {
    for ([_][]const u8{
        "/** @returns {number} */ export function answer() {}",
        "/** @returns {number} */ export default function answer() {}",
        "/** @returns {number} */ export default async function answer() {}",
    }) |source| {
        const start = std.mem.indexOf(u8, source, "function") orelse unreachable;
        try std.testing.expectEqualStrings(" @returns {number} ", leadingBody(source, @intCast(start)).?);
    }
}

test "JSDoc overload tag detection ignores prose mentions" {
    try std.testing.expect(bodyHasOverloadTag("\n * @template T\n * @overload\n * @param {T} x\n "));
    try std.testing.expect(!bodyHasOverloadTag("\n * Call an @overload signature\n * @template T\n "));
    try std.testing.expect(!bodyHasOverloadTag("\n * @overloaded helper\n "));
}
