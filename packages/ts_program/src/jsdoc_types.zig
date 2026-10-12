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

pub const AssignedField = struct {
    name: []const u8,
    primitive: Primitive,
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

pub fn declarationPrimitive(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId) !?Primitive {
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse return null;
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);
    for (tags) |tag| {
        if (tag.kind == .type_tag) return parsePrimitive(tag.type_text);
    }
    return null;
}

pub fn constructorAssignedFields(gpa: std.mem.Allocator, c: *const driver.Compilation, node: hir.NodeId) ![]AssignedField {
    const function = hir.fnDeclOf(&c.hir, node);
    if (!function.flags.is_constructor or function.body == hir.none_node_id or c.hir.kindOf(function.body) != .block_stmt) return &.{};
    const body = leadingBody(c.source, c.hir.spanOf(node).start) orelse return &.{};
    const tags = try jsdoc.parse(gpa, body);
    defer gpa.free(tags);

    var fields: std.ArrayListUnmanaged(AssignedField) = .empty;
    errdefer fields.deinit(gpa);
    for (hir.blockStmts(&c.hir, function.body)) |statement| {
        if (c.hir.kindOf(statement) != .assignment) continue;
        const assignment = hir.assignmentOf(&c.hir, statement);
        if (assignment.op != null or c.hir.kindOf(assignment.target) != .member_access or c.hir.kindOf(assignment.value) != .identifier) continue;
        const member = hir.memberOf(&c.hir, assignment.target);
        if (!isThisExpression(c, member.object)) continue;
        const value_name = hir.identifierOf(&c.hir, assignment.value).name;
        if (!isParameter(c, node, value_name)) continue;
        const primitive = parameterPrimitive(tags, c.interner.get(value_name)) orelse continue;
        const field_name = c.interner.get(member.name);
        if (contains(fields.items, field_name)) continue;
        try fields.append(gpa, .{ .name = field_name, .primitive = primitive });
    }
    return fields.toOwnedSlice(gpa);
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

fn parameterPrimitive(tags: []const jsdoc.Tag, name: []const u8) ?Primitive {
    for (tags) |tag| {
        if (tag.kind == .param_tag and std.mem.eql(u8, tag.name, name)) return parsePrimitive(tag.type_text);
    }
    return null;
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
