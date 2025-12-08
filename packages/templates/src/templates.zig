const std = @import("std");
const fs = std.fs;

/// Template value types
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    array: []const Value,
    object: std.StringHashMapUnmanaged(Value),
    null_val: void,

    pub fn toString(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| try allocator.dupe(u8, s),
            .int => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(allocator, "{d:.2}", .{f}),
            .boolean => |b| try allocator.dupe(u8, if (b) "true" else "false"),
            .null_val => try allocator.dupe(u8, ""),
            .array => try allocator.dupe(u8, "[Array]"),
            .object => try allocator.dupe(u8, "[Object]"),
        };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .string => |s| s.len > 0,
            .int => |i| i != 0,
            .float => |f| f != 0.0,
            .boolean => |b| b,
            .array => |a| a.len > 0,
            .object => true,
            .null_val => false,
        };
    }
};

/// Template context for variable resolution
pub const Context = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap(Value),
    parent: ?*const Context = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .data = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }

    pub fn set(self: *Self, key: []const u8, value: Value) !void {
        try self.data.put(key, value);
    }

    pub fn setString(self: *Self, key: []const u8, value: []const u8) !void {
        try self.set(key, .{ .string = value });
    }

    pub fn setInt(self: *Self, key: []const u8, value: i64) !void {
        try self.set(key, .{ .int = value });
    }

    pub fn setBool(self: *Self, key: []const u8, value: bool) !void {
        try self.set(key, .{ .boolean = value });
    }

    pub fn setArray(self: *Self, key: []const u8, value: []const Value) !void {
        try self.set(key, .{ .array = value });
    }

    pub fn get(self: *const Self, key: []const u8) ?Value {
        // Support dot notation: user.name
        if (std.mem.indexOfScalar(u8, key, '.')) |dot_idx| {
            const first = key[0..dot_idx];
            const rest = key[dot_idx + 1 ..];

            if (self.data.get(first)) |val| {
                if (val == .object) {
                    if (val.object.get(rest)) |nested| {
                        return nested;
                    }
                }
            }
        }

        if (self.data.get(key)) |val| {
            return val;
        }

        if (self.parent) |p| {
            return p.get(key);
        }

        return null;
    }

    pub fn child(self: *const Self, allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .data = std.StringHashMap(Value).init(allocator),
            .parent = self,
        };
    }
};

/// Template engine
pub const Engine = struct {
    allocator: std.mem.Allocator,
    templates: std.StringHashMap([]const u8),
    cache_enabled: bool = true,

    // Delimiters
    var_start: []const u8 = "{{",
    var_end: []const u8 = "}}",
    block_start: []const u8 = "{%",
    block_end: []const u8 = "%}",
    comment_start: []const u8 = "{#",
    comment_end: []const u8 = "#}",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .templates = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.templates.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.templates.deinit();
    }

    /// Register a template by name
    pub fn register(self: *Self, name: []const u8, content: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const content_copy = try self.allocator.dupe(u8, content);
        try self.templates.put(name_copy, content_copy);
    }

    /// Load template from file
    pub fn loadFile(self: *Self, name: []const u8, path: []const u8) !void {
        const file = try fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try self.allocator.alloc(u8, stat.size);
        _ = try file.preadAll(content, 0);

        const name_copy = try self.allocator.dupe(u8, name);
        try self.templates.put(name_copy, content);
    }

    /// Render a template with context
    pub fn render(self: *Self, name: []const u8, ctx: *const Context) ![]const u8 {
        const template = self.templates.get(name) orelse return error.TemplateNotFound;
        return self.renderString(template, ctx);
    }

    /// Render a template string directly
    pub fn renderString(self: *Self, template: []const u8, ctx: *const Context) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < template.len) {
            // Check for comment
            if (self.startsWith(template, i, self.comment_start)) {
                const end = self.findEnd(template, i + self.comment_start.len, self.comment_end) orelse {
                    try result.append(self.allocator, template[i]);
                    i += 1;
                    continue;
                };
                i = end + self.comment_end.len;
                continue;
            }

            // Check for block tag
            if (self.startsWith(template, i, self.block_start)) {
                const tag_end = self.findEnd(template, i + self.block_start.len, self.block_end) orelse {
                    try result.append(self.allocator, template[i]);
                    i += 1;
                    continue;
                };

                const tag_content = std.mem.trim(u8, template[i + self.block_start.len .. tag_end], " \t\n\r");
                const processed = try self.processBlock(template, tag_end + self.block_end.len, tag_content, ctx);
                try result.appendSlice(self.allocator, processed.content);
                self.allocator.free(processed.content);
                i = processed.end_pos;
                continue;
            }

            // Check for variable
            if (self.startsWith(template, i, self.var_start)) {
                const end = self.findEnd(template, i + self.var_start.len, self.var_end) orelse {
                    try result.append(self.allocator, template[i]);
                    i += 1;
                    continue;
                };

                const var_expr = std.mem.trim(u8, template[i + self.var_start.len .. end], " \t");
                const value = try self.evaluateExpr(var_expr, ctx);
                defer self.allocator.free(value);
                try result.appendSlice(self.allocator, value);
                i = end + self.var_end.len;
                continue;
            }

            try result.append(self.allocator, template[i]);
            i += 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn startsWith(self: *Self, template: []const u8, pos: usize, prefix: []const u8) bool {
        _ = self;
        if (pos + prefix.len > template.len) return false;
        return std.mem.eql(u8, template[pos .. pos + prefix.len], prefix);
    }

    fn findEnd(self: *Self, template: []const u8, start: usize, end_marker: []const u8) ?usize {
        _ = self;
        const offset = std.mem.indexOf(u8, template[start..], end_marker) orelse return null;
        return start + offset;
    }

    fn evaluateExpr(self: *Self, expr: []const u8, ctx: *const Context) ![]const u8 {
        // Check for filters (expr | filter)
        if (std.mem.indexOf(u8, expr, "|")) |pipe_pos| {
            const var_name = std.mem.trim(u8, expr[0..pipe_pos], " \t");
            const filter_name = std.mem.trim(u8, expr[pipe_pos + 1 ..], " \t");

            const value = ctx.get(var_name) orelse return try self.allocator.dupe(u8, "");
            const str_value = try value.toString(self.allocator);
            defer self.allocator.free(str_value);

            return self.applyFilter(str_value, filter_name);
        }

        // Simple variable lookup
        const value = ctx.get(expr) orelse return try self.allocator.dupe(u8, "");
        return value.toString(self.allocator);
    }

    fn applyFilter(self: *Self, value: []const u8, filter: []const u8) ![]const u8 {
        if (std.mem.eql(u8, filter, "upper")) {
            var result = try self.allocator.alloc(u8, value.len);
            for (value, 0..) |c, idx| {
                result[idx] = std.ascii.toUpper(c);
            }
            return result;
        }

        if (std.mem.eql(u8, filter, "lower")) {
            var result = try self.allocator.alloc(u8, value.len);
            for (value, 0..) |c, idx| {
                result[idx] = std.ascii.toLower(c);
            }
            return result;
        }

        if (std.mem.eql(u8, filter, "trim")) {
            const trimmed = std.mem.trim(u8, value, " \t\n\r");
            return try self.allocator.dupe(u8, trimmed);
        }

        if (std.mem.eql(u8, filter, "escape") or std.mem.eql(u8, filter, "e")) {
            return self.escapeHtml(value);
        }

        if (std.mem.eql(u8, filter, "length")) {
            return try std.fmt.allocPrint(self.allocator, "{d}", .{value.len});
        }

        // No filter match, return as-is
        return try self.allocator.dupe(u8, value);
    }

    fn escapeHtml(self: *Self, input: []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        for (input) |c| {
            switch (c) {
                '<' => try result.appendSlice(self.allocator, "&lt;"),
                '>' => try result.appendSlice(self.allocator, "&gt;"),
                '&' => try result.appendSlice(self.allocator, "&amp;"),
                '"' => try result.appendSlice(self.allocator, "&quot;"),
                '\'' => try result.appendSlice(self.allocator, "&#39;"),
                else => try result.append(self.allocator, c),
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    const BlockResult = struct {
        content: []const u8,
        end_pos: usize,
    };

    fn processBlock(self: *Self, template: []const u8, start: usize, tag: []const u8, ctx: *const Context) anyerror!BlockResult {
        // Parse tag type
        var tokens = std.mem.tokenizeAny(u8, tag, " \t");
        const keyword = tokens.next() orelse return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = start };

        // if block
        if (std.mem.eql(u8, keyword, "if")) {
            const condition = tokens.rest();
            return self.processIf(template, start, condition, ctx);
        }

        // for block
        if (std.mem.eql(u8, keyword, "for")) {
            return self.processFor(template, start, tokens.rest(), ctx);
        }

        // include
        if (std.mem.eql(u8, keyword, "include")) {
            const template_name = std.mem.trim(u8, tokens.rest(), " \t\"'");
            if (self.templates.get(template_name)) |included| {
                const rendered = try self.renderString(included, ctx);
                return .{ .content = rendered, .end_pos = start };
            }
            return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = start };
        }

        return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = start };
    }

    fn processIf(self: *Self, template: []const u8, start: usize, condition: []const u8, ctx: *const Context) !BlockResult {
        // Find endif
        const endif_tag = "{% endif %}";
        const else_tag = "{% else %}";

        var end_pos = start;
        var else_pos: ?usize = null;
        var depth: usize = 1;
        var i: usize = start;

        while (i < template.len) {
            if (self.startsWith(template, i, "{% if")) {
                depth += 1;
            } else if (self.startsWith(template, i, "{% endif %}")) {
                depth -= 1;
                if (depth == 0) {
                    end_pos = i + endif_tag.len;
                    break;
                }
            } else if (depth == 1 and self.startsWith(template, i, else_tag)) {
                else_pos = i;
            }
            i += 1;
        }

        // Evaluate condition
        const is_true = self.evaluateCondition(condition, ctx);

        const true_end = else_pos orelse (end_pos - endif_tag.len);
        const true_block = template[start..true_end];

        if (is_true) {
            const rendered = try self.renderString(true_block, ctx);
            return .{ .content = rendered, .end_pos = end_pos };
        } else if (else_pos) |ep| {
            const false_block = template[ep + else_tag.len .. end_pos - endif_tag.len];
            const rendered = try self.renderString(false_block, ctx);
            return .{ .content = rendered, .end_pos = end_pos };
        }

        return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = end_pos };
    }

    fn evaluateCondition(self: *Self, condition: []const u8, ctx: *const Context) bool {
        _ = self;
        const trimmed = std.mem.trim(u8, condition, " \t");

        // Check for "not" prefix
        if (std.mem.startsWith(u8, trimmed, "not ")) {
            const var_name = std.mem.trim(u8, trimmed[4..], " \t");
            const value = ctx.get(var_name) orelse return true;
            return !value.isTruthy();
        }

        // Simple variable check
        const value = ctx.get(trimmed) orelse return false;
        return value.isTruthy();
    }

    fn processFor(self: *Self, template: []const u8, start: usize, loop_expr: []const u8, ctx: *const Context) !BlockResult {
        // Parse "item in items"
        var parts = std.mem.tokenizeAny(u8, loop_expr, " \t");
        const item_name = parts.next() orelse return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = start };
        const in_keyword = parts.next() orelse return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = start };
        if (!std.mem.eql(u8, in_keyword, "in")) {
            return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = start };
        }
        const array_name = parts.next() orelse return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = start };

        // Find endfor
        const endfor_tag = "{% endfor %}";
        var end_pos = start;
        var depth: usize = 1;
        var i: usize = start;

        while (i < template.len) {
            if (self.startsWith(template, i, "{% for")) {
                depth += 1;
            } else if (self.startsWith(template, i, endfor_tag)) {
                depth -= 1;
                if (depth == 0) {
                    end_pos = i + endfor_tag.len;
                    break;
                }
            }
            i += 1;
        }

        const loop_body = template[start .. end_pos - endfor_tag.len];

        // Get array
        const array_value = ctx.get(array_name) orelse return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = end_pos };
        if (array_value != .array) {
            return .{ .content = try self.allocator.dupe(u8, ""), .end_pos = end_pos };
        }

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        for (array_value.array, 0..) |item, idx| {
            var loop_ctx = ctx.child(self.allocator);
            defer loop_ctx.deinit();

            try loop_ctx.set(item_name, item);
            try loop_ctx.setInt("loop.index", @intCast(idx));
            try loop_ctx.setInt("loop.index1", @intCast(idx + 1));
            try loop_ctx.setBool("loop.first", idx == 0);
            try loop_ctx.setBool("loop.last", idx == array_value.array.len - 1);

            const rendered = try self.renderString(loop_body, &loop_ctx);
            defer self.allocator.free(rendered);
            try result.appendSlice(self.allocator, rendered);
        }

        return .{ .content = try result.toOwnedSlice(self.allocator), .end_pos = end_pos };
    }
};

/// Quick render helper
pub fn render(allocator: std.mem.Allocator, template: []const u8, ctx: *const Context) ![]const u8 {
    var engine = Engine.init(allocator);
    defer engine.deinit();
    return engine.renderString(template, ctx);
}

// Tests
test "simple variable substitution" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.setString("name", "World");

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const result = try engine.renderString("Hello, {{ name }}!", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "multiple variables" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.setString("first", "John");
    try ctx.setString("last", "Doe");
    try ctx.setInt("age", 30);

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const result = try engine.renderString("{{ first }} {{ last }}, age {{ age }}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("John Doe, age 30", result);
}

test "filter upper" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.setString("name", "hello");

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const result = try engine.renderString("{{ name | upper }}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("HELLO", result);
}

test "filter escape" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.setString("html", "<script>alert('xss')</script>");

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const result = try engine.renderString("{{ html | escape }}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;", result);
}

test "if block true" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.setBool("show", true);

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const result = try engine.renderString("{% if show %}visible{% endif %}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("visible", result);
}

test "if block false" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.setBool("show", false);

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const result = try engine.renderString("{% if show %}visible{% endif %}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "if else block" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.setBool("logged_in", false);

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const result = try engine.renderString("{% if logged_in %}Welcome{% else %}Please login{% endif %}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Please login", result);
}

test "for loop" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const items = [_]Value{
        .{ .string = "apple" },
        .{ .string = "banana" },
        .{ .string = "cherry" },
    };
    try ctx.setArray("fruits", &items);

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const result = try engine.renderString("{% for fruit in fruits %}{{ fruit }} {% endfor %}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("apple banana cherry ", result);
}

test "comment ignored" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const result = try engine.renderString("Hello{# this is a comment #} World", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello World", result);
}

test "value truthiness" {
    const true_bool = Value{ .boolean = true };
    try std.testing.expect(true_bool.isTruthy());

    const false_bool = Value{ .boolean = false };
    try std.testing.expect(!false_bool.isTruthy());

    const hello_str = Value{ .string = "hello" };
    try std.testing.expect(hello_str.isTruthy());

    const empty_str = Value{ .string = "" };
    try std.testing.expect(!empty_str.isTruthy());

    const one_int = Value{ .int = 1 };
    try std.testing.expect(one_int.isTruthy());

    const zero_int = Value{ .int = 0 };
    try std.testing.expect(!zero_int.isTruthy());

    const null_val = Value{ .null_val = {} };
    try std.testing.expect(!null_val.isTruthy());
}
