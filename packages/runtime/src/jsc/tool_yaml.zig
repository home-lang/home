//! Public-C bridge to Home's owned native YAML parser.
const std = @import("std");
const bun = @import("bun");
const yaml = @import("tool_yaml_parser");
const backend = bun.yaml_backend;
const callback = @import("callback.zig");
const evaluate = @import("evaluate.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");
const Value = std.json.Value;
const Expr = backend.ast.Expr;

fn tuple(allocator: std.mem.Allocator, values: []const Value) !Value {
    var array = std.array_list.Managed(Value).init(allocator);
    try array.appendSlice(values);
    return .{ .array = array };
}

const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.array_list.Managed(Value),
    seen: std.AutoHashMap(usize, usize),

    fn add(self: *Graph, expression: Expr, depth: usize) anyerror!usize {
        if (depth > 256) return error.UnsupportedDepth;
        const pointer: ?usize = switch (expression.data) {
            .e_array => |array| @intFromPtr(array),
            .e_object => |object| @intFromPtr(object),
            else => null,
        };
        if (pointer) |key| if (self.seen.get(key)) |id| return id;
        const id = self.nodes.items.len;
        try self.nodes.append(.null);
        if (pointer) |key| try self.seen.put(key, id);
        const node = switch (expression.data) {
            .e_null => try tuple(self.allocator, &.{.{ .string = "null" }}),
            .e_boolean => |boolean| try tuple(self.allocator, &.{ .{ .string = "boolean" }, .{ .bool = boolean.value } }),
            .e_number => |number| blk: {
                const text = if (std.math.isNan(number.value))
                    "NaN"
                else if (std.math.isInf(number.value))
                    (if (number.value < 0) "-Infinity" else "Infinity")
                else
                    try std.fmt.allocPrint(self.allocator, "{d}", .{number.value});
                break :blk try tuple(self.allocator, &.{ .{ .string = "number" }, .{ .string = text } });
            },
            .e_string => |string| blk: {
                if (!std.unicode.utf8ValidateSlice(string.data)) return error.UnsupportedUnicode;
                break :blk try tuple(self.allocator, &.{ .{ .string = "string" }, .{ .string = string.data } });
            },
            .e_array => |array| blk: {
                var entries = std.array_list.Managed(Value).init(self.allocator);
                for (array.items.slice()) |item| try entries.append(.{ .integer = @intCast(try self.add(item, depth + 1)) });
                break :blk try tuple(self.allocator, &.{ .{ .string = "array" }, .{ .array = entries } });
            },
            .e_object => |object| blk: {
                var entries = std.array_list.Managed(Value).init(self.allocator);
                for (object.properties.slice()) |property| {
                    const key = property.key orelse return error.UnsupportedKey;
                    if (key.data == .e_array or key.data == .e_object) return error.UnsupportedKey;
                    const value = property.value orelse return error.UnsupportedValue;
                    const key_id = try self.add(key, depth + 1);
                    const value_id = try self.add(value, depth + 1);
                    try entries.append(try tuple(self.allocator, &.{ .{ .integer = @intCast(key_id) }, .{ .integer = @intCast(value_id) } }));
                }
                break :blk try tuple(self.allocator, &.{ .{ .string = "object" }, .{ .array = entries } });
            },
            else => return error.UnsupportedValue,
        };
        // Visiting descendants can reallocate nodes. Resolve the destination
        // after that traversal rather than retaining a slot in the old buffer.
        self.nodes.items[id] = node;
        return id;
    }
};

fn stringValue(ctx: *opaques.JSContextRef, allocator: std.mem.Allocator, text: []const u8) ?*opaques.JSValue {
    const bytes = bun.dupeZ(allocator, u8, text) catch return null;
    const string = extern_fns.JSStringCreateWithUTF8CString(bytes.ptr) orelse return null;
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(ctx, string);
}

fn failure(ctx: *opaques.JSContextRef, allocator: std.mem.Allocator, kind: []const u8, message: []const u8) ?*opaques.JSValue {
    const encoded = std.json.Stringify.valueAlloc(allocator, .{ .kind = kind, .message = message }, .{}) catch return extern_fns.JSValueMakeNull(ctx);
    return stringValue(ctx, allocator, encoded);
}

fn parseNative(
    ctx: ?*opaques.JSContextRef,
    function: ?*opaques.JSObject,
    this_object: ?*opaques.JSObject,
    count: usize,
    arguments: [*c]const ?*opaques.JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*opaques.JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (count == 0 or arguments[0] == null) return extern_fns.JSValueMakeNull(c);
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scope = backend.Scope.enter(allocator);
    defer scope.deinit();
    const input_string = extern_fns.JSValueToStringCopy(c, arguments[0], null) orelse return extern_fns.JSValueMakeNull(c);
    defer extern_fns.JSStringRelease(input_string);
    const capacity = extern_fns.JSStringGetLength(input_string) * 4 + 1;
    const bytes = allocator.alloc(u8, capacity) catch return extern_fns.JSValueMakeNull(c);
    const written = extern_fns.JSStringGetUTF8CString(input_string, bytes.ptr, bytes.len);
    if (written == 0) return extern_fns.JSValueMakeNull(c);
    const input = bytes[0 .. written - 1];
    const unicode = std.unicode.Utf8View.init(input) catch return failure(c, allocator, "SyntaxError", "invalid_utf8");
    var characters = unicode.iterator();
    while (characters.nextCodepoint()) |point| {
        // YAML 1.2 c-printable excludes raw controls and surrogate code points;
        // escaped controls inside a quoted scalar are handled by the parser.
        if (!(point == 9 or point == 10 or point == 13 or
            (point >= 0x20 and point <= 0x7e) or point == 0x85 or
            (point >= 0xa0 and point <= 0xd7ff) or
            (point >= 0xe000 and point <= 0xfffd) or point >= 0x10000))
            return failure(c, allocator, "SyntaxError", "invalid_yaml_character");
    }
    const parsed = yaml.parse(.utf8, allocator, input);
    const stream = switch (parsed) {
        .result => |result| result.stream,
        .err => |err| return failure(c, allocator, if (err == .stack_overflow) "RangeError" else "SyntaxError", @tagName(err)),
    };
    var graph: Graph = .{ .allocator = allocator, .nodes = .init(allocator), .seen = .init(allocator) };
    var roots = std.array_list.Managed(Value).init(allocator);
    for (stream.docs.items) |document| {
        const id = graph.add(document.root, 0) catch |err| return failure(c, allocator, "ERR_HOME_UNSUPPORTED", @errorName(err));
        roots.append(.{ .integer = @intCast(id) }) catch return extern_fns.JSValueMakeNull(c);
    }
    const payload = std.json.Stringify.valueAlloc(allocator, .{ .nodes = Value{ .array = graph.nodes }, .roots = Value{ .array = roots } }, .{}) catch return extern_fns.JSValueMakeNull(c);
    return stringValue(c, allocator, payload);
}

pub fn install(allocator: std.mem.Allocator, ctx: *opaques.JSContextRef, global: *opaques.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_yaml_parse", parseNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_yaml.js"), "home:tool-yaml-install", 1) catch return;
    result.deinit(allocator);
}
