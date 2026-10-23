//! Exact primitive facts recovered from declaration-adjacent JSDoc.
//! The tag parser owns syntax recognition; this module only associates those
//! tags with Program declarations and direct constructor assignments.

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
        unsupported,
        union_type: []TypeExpression,
    },
    containers: []Container = &.{},

    pub fn deinit(self: TypeExpression, gpa: std.mem.Allocator) void {
        if (self.containers.len > 0) gpa.free(self.containers);
        switch (self.base) {
            .primitive, .number_literal, .boolean_literal, .unsupported => {},
            .string_literal => |value| gpa.free(value),
            .union_type => |members| {
                for (members) |member| member.deinit(gpa);
                gpa.free(members);
            },
        }
    }

    pub fn barePrimitive(self: TypeExpression) ?Primitive {
        if (self.containers.len > 0) return null;
        return switch (self.base) {
            .primitive => |primitive| primitive,
            .string_literal, .number_literal, .boolean_literal, .unsupported, .union_type => null,
        };
    }

    pub fn transferable(self: TypeExpression) bool {
        return switch (self.base) {
            .unsupported => false,
            .union_type => |members| blk: {
                for (members) |member| if (!member.transferable()) break :blk false;
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
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse return null;
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);
    for (tags) |tag| {
        if (tag.kind == .type_tag) return (try parseTypeExpression(gpa, tag.type_text)) orelse TypeExpression{ .base = .unsupported };
    }
    return null;
}

pub fn functionSignature(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId) !?FunctionSignature {
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse return null;
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);
    for (tags) |tag| if (tag.kind == .template_tag) return null;

    var result: ?TypeExpression = null;
    var result_transferred = false;
    defer if (!result_transferred) if (result) |value| value.deinit(gpa);
    for (tags) |tag| {
        if (tag.kind != .returns_tag) continue;
        if (result != null) return null;
        result = try parseTypeExpression(gpa, tag.type_text) orelse return null;
    }
    const return_type = result orelse return null;
    const nodes = hir.fnParams(&c.hir, node);
    for (nodes) |parameter_node| {
        const parameter = hir.parameterOf(&c.hir, parameter_node);
        if (c.hir.kindOf(parameter.name) != .identifier) return null;
        const name = c.interner.get(hir.identifierOf(&c.hir, parameter.name).name);
        const tag = uniqueParameterTag(tags, name) orelse return null;
        if (parameter.flags.is_rest and (tag.optional or parameter.default_value != hir.none_node_id)) return null;
        var parsed = try parameterTypeExpression(gpa, tag.type_text, parameter.flags.is_rest) orelse return null;
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
            .type_expression = (try parameterTypeExpression(gpa, tag.type_text, parameter.flags.is_rest)).?,
            .optional = tag.optional or parameter.flags.is_optional or parameter.default_value != hir.none_node_id,
            .rest = parameter.flags.is_rest,
        };
        initialized += 1;
    }
    result_transferred = true;
    return .{ .parameters = parameters, .result = return_type };
}

pub fn constructorAssignedFields(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId) ![]AssignedField {
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
        const type_expression = (try declarationType(gpa, c, statement)) orelse blk: {
            if (c.hir.kindOf(assignment.value) != .identifier) break :blk null;
            const value_name = hir.identifierOf(&c.hir, assignment.value).name;
            if (!isParameter(c, node, value_name)) break :blk null;
            break :blk try parameterType(gpa, tags, c.interner.get(value_name));
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

fn parameterType(gpa: std.mem.Allocator, tags: []const jsdoc.Tag, name: []const u8) !?TypeExpression {
    for (tags) |tag| {
        if (tag.kind == .param_tag and std.mem.eql(u8, tag.name, name)) return parseTypeExpression(gpa, tag.type_text);
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
            const member = try parseTypeExpression(gpa, trimmed[start..end]) orelse {
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
        const value = try parseTypeExpression(gpa, body) orelse return null;
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
    else if (outerGroupBody(current)) |body|
        (try parseTypeExpression(gpa, body) orelse {
            containers.deinit(gpa);
            return null;
        })
    else if (topLevelUnionEnd(current) != null or nullableBody(current) != null)
        (try parseTypeExpression(gpa, current) orelse {
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
    if (!rest) return parseTypeExpression(gpa, text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "...")) {
        var parsed = try parseTypeExpression(gpa, std.mem.trim(u8, trimmed[3..], " \t\r\n")) orelse return null;
        errdefer parsed.deinit(gpa);
        const containers = try gpa.alloc(Container, parsed.containers.len + 1);
        containers[0] = .array;
        @memcpy(containers[1..], parsed.containers);
        if (parsed.containers.len > 0) gpa.free(parsed.containers);
        parsed.containers = containers;
        return parsed;
    }
    const parsed = try parseTypeExpression(gpa, trimmed) orelse return null;
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
    try std.testing.expect((try parseTypeExpression(std.testing.allocator, "Array<string | { value: number }>")) == null);
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

fn leadingBody(source: []const u8, declaration_start: u32) ?[]const u8 {
    var limit = @min(@as(usize, declaration_start), source.len);
    var trimmed_end = limit;
    while (trimmed_end > 0 and std.ascii.isWhitespace(source[trimmed_end - 1])) : (trimmed_end -= 1) {}
    if (trimmed_end >= "export".len and
        std.mem.eql(u8, source[trimmed_end - "export".len .. trimmed_end], "export") and
        (trimmed_end == "export".len or !isIdentChar(source[trimmed_end - "export".len - 1])))
    {
        limit = trimmed_end - "export".len;
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
