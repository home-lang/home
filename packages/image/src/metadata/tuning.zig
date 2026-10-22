//! Owned, bounded JSON tuning documents. Unknown parameters and exact numeric
//! lexemes are preserved. This edits data; it never applies sensor/ISP settings.
const std = @import("std");
pub const Limits = struct { bytes: usize = 16 * 1024 * 1024, tokens: usize = 262144, depth: usize = 64 };
pub const name_limit = 256;
fn preflight(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !void {
    if (limits.bytes == 0 or limits.tokens == 0 or limits.depth == 0 or limits.depth > 256) return error.InvalidLimits;
    if (bytes.len == 0 or bytes.len > limits.bytes) return error.DocumentLimit;
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = try scanner.next();
        if (token == .end_of_document) break;
        if (tokens == limits.tokens) return error.DocumentLimit;
        tokens += 1;
        switch (token) {
            .object_begin, .array_begin => {
                if (depth == limits.depth) return error.DocumentLimit;
                depth += 1;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidDocument;
                depth -= 1;
            },
            else => {},
        }
    }
    if (depth != 0) return error.InvalidDocument;
}
fn owned(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !std.json.Parsed(std.json.Value) {
    try preflight(allocator, bytes, limits);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always, .parse_numbers = false, .duplicate_field_behavior = .@"error", .max_value_len = limits.bytes });
}
fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= name_limit and std.unicode.utf8ValidateSlice(name) and std.mem.indexOfScalar(u8, name, 0) == null;
}
pub const Document = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    parsed: std.json.Parsed(std.json.Value),
    limits: Limits,
    pub fn init(allocator: std.mem.Allocator, input: []const u8, limits: Limits) !Document {
        // Bound before allocating the owned input. The scanner/parser validate
        // structure and duplicate fields without a second JSON implementation.
        if (input.len == 0 or input.len > limits.bytes) return error.DocumentLimit;
        const bytes = try allocator.dupe(u8, input);
        errdefer allocator.free(bytes);
        var parsed = try owned(allocator, bytes, limits);
        errdefer parsed.deinit();
        var result: Document = .{ .allocator = allocator, .bytes = bytes, .parsed = parsed, .limits = limits };
        try result.validate();
        return result;
    }
    pub fn deinit(self: *Document) void {
        self.parsed.deinit();
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
    pub fn version(self: *const Document) !u32 {
        if (self.parsed.value != .object) return error.InvalidDocument;
        const v = self.parsed.value.object.get("version") orelse return 1;
        const lexeme = switch (v) {
            .number_string => |text| text,
            else => return error.InvalidVersion,
        };
        // Compare the decimal exactly: rounding via f64 would accept values
        // such as 2.00000000000000000001 as version 2.
        const end = std.mem.indexOfAny(u8, lexeme, "eE") orelse lexeme.len;
        const exponent: i32 = if (end == lexeme.len) 0 else std.fmt.parseInt(i32, lexeme[end + 1 ..], 10) catch return error.InvalidVersion;
        var digit: u32 = 0;
        var fractional: i64 = 0;
        var trailing: i64 = 0;
        var decimal = false;
        for (lexeme[0..end]) |ch| {
            if (ch == '.') {
                decimal = true;
                continue;
            }
            if (ch < '0' or ch > '9') return error.InvalidVersion;
            if (decimal) fractional += 1;
            if (ch != '0') {
                if (digit != 0 or (ch != '1' and ch != '2')) return error.InvalidVersion;
                digit = ch - '0';
            } else if (digit != 0) trailing += 1;
        }
        if (digit == 0 or trailing - fractional + exponent != 0) return error.InvalidVersion;
        return digit;
    }
    fn validate(self: *const Document) !void {
        if (try self.version() == 2) {
            const algorithms = self.parsed.value.object.get("algorithms") orelse return error.InvalidDocument;
            if (algorithms != .array) return error.InvalidDocument;
            for (algorithms.array.items) |entry| if (entry != .object) return error.InvalidDocument;
        }
    }
    fn algorithmPtr(self: *Document, name: []const u8) !*std.json.Value {
        if (!validName(name)) return error.InvalidName;
        if (try self.version() == 1) return self.parsed.value.object.getPtr(name) orelse error.AlgorithmNotFound;
        var found: ?*std.json.Value = null;
        const algorithms = self.parsed.value.object.getPtr("algorithms").?;
        for (algorithms.array.items) |*entry| if (entry.object.getPtr(name)) |value| {
            if (found != null) return error.AmbiguousAlgorithm;
            found = value;
        };
        return found orelse error.AlgorithmNotFound;
    }
    pub fn algorithm(self: *Document, name: []const u8) !std.json.Value {
        return (try self.algorithmPtr(name)).*;
    }
    /// Owned exact JSON, including integers/decimals beyond f64 precision.
    pub fn algorithmJSON(self: *Document, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, try self.algorithm(name), .{});
    }
    /// Replace one existing algorithm transactionally. Every candidate owner is
    /// retired before failure; the original document survives parse/schema/OOM.
    pub fn replaceAlgorithm(self: *Document, name: []const u8, input: []const u8) !void {
        _ = try self.algorithmPtr(name);
        var replacement = try owned(self.allocator, input, self.limits);
        defer replacement.deinit();
        var candidate = try Document.init(self.allocator, self.bytes, self.limits);
        defer candidate.deinit();
        (try candidate.algorithmPtr(name)).* = replacement.value;
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, candidate.parsed.value, .{});
        defer self.allocator.free(bytes);
        const ready = try Document.init(self.allocator, bytes, self.limits);
        self.deinit();
        self.* = ready;
    }
};
test "version one and two tuning preserve unknown values and exact numeric lexemes" {
    const t = std.testing;
    var first = try Document.init(t.allocator, "{\"rpi.agc\":{\"n\":9007199254740993,\"x\":1.2300000000000000001e-20},\"target\":\"pisp\"}", .{});
    defer first.deinit();
    try t.expectEqual(@as(u32, 1), try first.version());
    const exact = try first.algorithmJSON(t.allocator, "rpi.agc");
    defer t.allocator.free(exact);
    try t.expectEqualStrings("{\"n\":9007199254740993,\"x\":1.2300000000000000001e-20}", exact);
    var second = try Document.init(t.allocator, "{\"version\":2.0,\"algorithms\":[{\"rpi.af\":{\"map\":[1,2]}},{\"custom\":false}],\"unknown\":\"湖\"}", .{});
    defer second.deinit();
    try t.expectEqual(@as(u32, 2), try second.version());
    try second.replaceAlgorithm("rpi.af", "{\"map\":[3,4],\"precise\":123456789012345678901234567890}");
    const after = try second.algorithmJSON(t.allocator, "rpi.af");
    defer t.allocator.free(after);
    try t.expectEqualStrings("{\"map\":[3,4],\"precise\":123456789012345678901234567890}", after);
    try t.expect(std.mem.indexOf(u8, second.bytes, "湖") != null);
    try t.expectEqual(false, (try second.algorithm("custom")).bool);
}
test "invalid schemas duplicate fields missing and ambiguous algorithms reject without changing a document" {
    const t = std.testing;
    for ([_][]const u8{ "{} {}", "[]", "{\"version\":3}", "{\"version\":2.00000000000000000001}", "{\"version\":1.99999999999999999999}", "{\"version\":\"2\"}", "{\"version\":2}", "{\"version\":2,\"algorithms\":[1]}", "{\"rpi.agc\":1,\"rpi.agc\":2}" }) |input| {
        if (Document.init(t.allocator, input, .{})) |value| {
            var invalid = value;
            invalid.deinit();
            return error.UnexpectedAcceptedDocument;
        } else |_| {}
    }
    var doc = try Document.init(t.allocator, "{\"version\":2,\"algorithms\":[{\"same\":1},{\"same\":2},{\"one\":3}]}", .{});
    defer doc.deinit();
    try t.expectError(error.AmbiguousAlgorithm, doc.algorithm("same"));
    try t.expectError(error.AlgorithmNotFound, doc.algorithm("missing"));
    try t.expectError(error.InvalidName, doc.algorithm(""));
    const before = try t.allocator.dupe(u8, doc.bytes);
    defer t.allocator.free(before);
    try t.expectError(error.AmbiguousAlgorithm, doc.replaceAlgorithm("same", "4"));
    if (doc.replaceAlgorithm("one", "[")) |_| return error.UnexpectedAcceptedDocument else |_| {}
    try t.expectEqualSlices(u8, before, doc.bytes);
}
test "version decimal and exponent spelling must be exactly one or two" {
    for ([_][]const u8{ "1", "1.0000", "10e-1", "0.01e2", "2", "2.0", "0.002e3", "20E-1" }, 0..) |text, i| {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"version\":{s},\"algorithms\":[]}}", .{text});
        defer std.testing.allocator.free(bytes);
        var doc = try Document.init(std.testing.allocator, bytes, .{});
        defer doc.deinit();
        try std.testing.expectEqual(@as(u32, if (i < 4) 1 else 2), try doc.version());
    }
}
test "byte token and depth budgets include replacement publication" {
    const t = std.testing;
    try t.expectError(error.DocumentLimit, Document.init(t.allocator, "{}", .{ .bytes = 1 }));
    try t.expectError(error.DocumentLimit, Document.init(t.allocator, "{\"a\":[1]}", .{ .depth = 1 }));
    try t.expectError(error.DocumentLimit, Document.init(t.allocator, "{\"a\":1}", .{ .tokens = 2 }));
    var doc = try Document.init(t.allocator, "{\"one\":1}", .{ .bytes = 24 });
    defer doc.deinit();
    const before = try t.allocator.dupe(u8, doc.bytes);
    defer t.allocator.free(before);
    try t.expectError(error.DocumentLimit, doc.replaceAlgorithm("one", "\"01234567890123456789\""));
    try t.expectEqualSlices(u8, before, doc.bytes);
    try doc.replaceAlgorithm("one", "2");
    try t.expectEqualStrings("{\"one\":2}", doc.bytes);
}
fn allocationFailures(allocator: std.mem.Allocator) !void {
    var doc = try Document.init(allocator, "{\"version\":2,\"algorithms\":[{\"one\":1}]}", .{});
    defer doc.deinit();
    doc.replaceAlgorithm("one", "{\"nested\":[1,2,3]}") catch |err| {
        try std.testing.expectEqualStrings("{\"version\":2,\"algorithms\":[{\"one\":1}]}", doc.bytes);
        return err;
    };
}
test "allocation failures retire every candidate and keep the original mutation owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
