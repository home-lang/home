// Home Runtime - Phase 12.7 port of `node:querystring` (Zig substrate).
//
// Bun implements this module in `src/js/node/querystring.ts`, with JS
// bindings for the public Node-compatible surface. This Zig substrate keeps
// the same data rules available to Home's native runtime while the JSC module
// loader is still coming online:
//
//   * `parse` / `decode` split legacy query strings into ordered entries.
//   * `stringify` / `encode` serialize ordered entries.
//   * `escape` percent-encodes bytes using Node querystring's no-escape set.
//   * `unescape` decodes percent escapes without throwing on malformed input.
//
// The JS object shape re-attaches in Phase 12.2; until then, duplicate keys
// are preserved explicitly as ordered entries.

const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

pub const ParseOptions = struct {
    sep: []const u8 = "&",
    eq: []const u8 = "=",
    max_keys: ?usize = 1000,
};

pub const StringifyOptions = struct {
    sep: []const u8 = "&",
    eq: []const u8 = "=",
};

pub const Parsed = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    pub fn init(allocator: std.mem.Allocator) Parsed {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(Entry).empty,
        };
    }

    pub fn deinit(self: *Parsed) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *const Parsed, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn getAll(self: *const Parsed, allocator: std.mem.Allocator, key: []const u8) ![][]const u8 {
        var out = std.ArrayList([]const u8).empty;
        errdefer out.deinit(allocator);

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) try out.append(allocator, entry.value);
        }

        return try out.toOwnedSlice(allocator);
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Parsed {
    return parseWithOptions(allocator, input, .{});
}

pub const decode = parse;

pub fn parseWithOptions(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) !Parsed {
    var out = Parsed.init(allocator);
    errdefer out.deinit();

    if (input.len == 0) return out;

    var rest = input;
    var count: usize = 0;
    while (rest.len > 0) {
        if (options.max_keys) |max| {
            if (count >= max) break;
        }

        const sep_index = if (options.sep.len == 0) null else std.mem.indexOf(u8, rest, options.sep);
        const segment = if (sep_index) |idx| rest[0..idx] else rest;
        rest = if (sep_index) |idx| rest[idx + options.sep.len ..] else "";

        if (segment.len == 0) continue;

        const eq_index = if (options.eq.len == 0) null else std.mem.indexOf(u8, segment, options.eq);
        const raw_key = if (eq_index) |idx| segment[0..idx] else segment;
        const raw_value = if (eq_index) |idx| segment[idx + options.eq.len ..] else "";

        const key = try decodeComponent(allocator, raw_key, true);
        errdefer allocator.free(key);
        const value = try decodeComponent(allocator, raw_value, true);
        errdefer allocator.free(value);

        try out.entries.append(allocator, .{ .key = key, .value = value });
        count += 1;
    }

    return out;
}

pub fn stringify(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    return stringifyWithOptions(allocator, entries, .{});
}

pub const encode = stringify;

pub fn stringifyWithOptions(allocator: std.mem.Allocator, entries: []const Entry, options: StringifyOptions) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (entries, 0..) |entry, index| {
        if (index > 0) try out.appendSlice(allocator, options.sep);
        try appendEscaped(allocator, &out, entry.key);
        try out.appendSlice(allocator, options.eq);
        try appendEscaped(allocator, &out, entry.value);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn escape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendEscaped(allocator, &out, input);
    return try out.toOwnedSlice(allocator);
}

pub fn unescape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return decodeComponent(allocator, input, false);
}

fn appendEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (isNoEscape(byte)) {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[byte >> 4]);
            try out.append(allocator, hex[byte & 0x0f]);
        }
    }
}

fn decodeComponent(allocator: std.mem.Allocator, input: []const u8, plus_to_space: bool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte == '+' and plus_to_space) {
            try out.append(allocator, ' ');
            index += 1;
            continue;
        }

        if (byte == '%' and index + 2 < input.len) {
            if (hexValue(input[index + 1])) |hi| {
                if (hexValue(input[index + 2])) |lo| {
                    try out.append(allocator, (hi << 4) | lo);
                    index += 3;
                    continue;
                }
            }
        }

        try out.append(allocator, byte);
        index += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn isNoEscape(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '!', '\'', '(', ')', '*', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

const testing = std.testing;

test "querystring parse decodes plus and percent escapes" {
    var parsed = try parse(testing.allocator, "name=Home+Lang&sym=%26&empty=");
    defer parsed.deinit();

    try testing.expectEqualStrings("Home Lang", parsed.get("name").?);
    try testing.expectEqualStrings("&", parsed.get("sym").?);
    try testing.expectEqualStrings("", parsed.get("empty").?);
}

test "querystring parse preserves duplicate keys" {
    var parsed = try parse(testing.allocator, "tag=zig&tag=bun");
    defer parsed.deinit();

    const tags = try parsed.getAll(testing.allocator, "tag");
    defer testing.allocator.free(tags);

    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("zig", tags[0]);
    try testing.expectEqualStrings("bun", tags[1]);
}

test "querystring stringify escapes values" {
    const entries = [_]Entry{
        .{ .key = "name", .value = "Home Lang" },
        .{ .key = "sym", .value = "&" },
    };

    const out = try stringify(testing.allocator, &entries);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("name=Home%20Lang&sym=%26", out);
}

test "querystring unescape keeps malformed escapes literal" {
    const out = try unescape(testing.allocator, "a%2Fb%zz%");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("a/b%zz%", out);
}
