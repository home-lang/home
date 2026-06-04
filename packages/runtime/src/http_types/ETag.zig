// Copied from bun/src/http_types/ETag.zig at upstream
// SHA e643d7b085dfd29f675ade275197daedc2cdfc9c. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → local std helpers. The
// `appendToHeaders` helper takes an opaque `*Headers` because the full
// HTTP header container lands in Phase 12.5 — callers supply any type
// that exposes `append(name, value) !void`. Marker: HOME_RT_STUB_HEADERS.
// Zig 0.17 fixup: `std.mem.trimStart` → `std.mem.trimStart`.

const ETag = @This();

/// Parse a single entity tag from a string, returns the tag without quotes and whether it's weak
fn parse(tag_str: []const u8) struct { tag: []const u8, is_weak: bool } {
    var str = std.mem.trim(u8, tag_str, " \t");

    // Check for weak indicator
    var is_weak = false;
    if (std.mem.startsWith(u8, str, "W/")) {
        is_weak = true;
        str = str[2..];
        str = std.mem.trimStart(u8, str, " \t");
    }

    // Remove surrounding quotes
    if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"') {
        str = str[1 .. str.len - 1];
    }

    return .{ .tag = str, .is_weak = is_weak };
}

/// Perform weak comparison between two entity tags according to RFC 9110 Section 8.8.3.2
fn weakMatch(tag1: []const u8, is_weak1: bool, tag2: []const u8, is_weak2: bool) bool {
    _ = is_weak1;
    _ = is_weak2;
    // For weak comparison, we only compare the opaque tag values, ignoring weak indicators
    return std.mem.eql(u8, tag1, tag2);
}

/// HOME_RT_STUB_HEADERS: in Bun this took `*bun.http.Headers`, which is
/// the multi-map header container. The full type re-lands in Phase 12.5;
/// until then `appendToHeaders` is generic over any container exposing
/// an `append(name: []const u8, value: []const u8) !void` method, so
/// downstream call sites can pass whichever container Home settles on.
pub fn appendToHeaders(bytes: []const u8, headers: anytype) !void {
    const hash = std.hash.XxHash64.hash(0, bytes);

    var etag_buf: [40]u8 = undefined;
    const etag_str = std.fmt.bufPrint(&etag_buf, "\"{x:0>16}\"", .{hash}) catch unreachable;
    try headers.append("etag", etag_str);
}

pub fn ifNoneMatch(
    /// "ETag" header
    etag: []const u8,
    /// "If-None-Match" header
    if_none_match: []const u8,
) bool {
    const our_parsed = parse(etag);

    // Handle "*" case
    if (std.mem.eql(u8, std.mem.trim(u8, if_none_match, " \t"), "*")) {
        return true; // Condition is false, so we should return 304
    }

    // Parse comma-separated list of entity tags
    var iter = std.mem.splitScalar(u8, if_none_match, ',');
    while (iter.next()) |tag_str| {
        const parsed = parse(tag_str);
        if (weakMatch(our_parsed.tag, our_parsed.is_weak, parsed.tag, parsed.is_weak)) {
            return true; // Condition is false, so we should return 304
        }
    }

    return false; // Condition is true, continue with normal processing
}

const std = @import("std");

// ---- Tests -------------------------------------------------------------

const TestHeaders = struct {
    buf: [128]u8 = undefined,
    name: []const u8 = "",
    value: []const u8 = "",

    pub fn append(self: *TestHeaders, name: []const u8, value: []const u8) !void {
        self.name = name;
        // Copy into the owned buffer so the slice survives caller stack.
        @memcpy(self.buf[0..value.len], value);
        self.value = self.buf[0..value.len];
    }
};

test "parse strips quotes and detects weak indicator" {
    const a = parse("\"abc\"");
    try std.testing.expectEqualStrings("abc", a.tag);
    try std.testing.expect(!a.is_weak);

    const b = parse("W/\"xyz\"");
    try std.testing.expectEqualStrings("xyz", b.tag);
    try std.testing.expect(b.is_weak);

    const c = parse("  W/  \"trimmed\"  ");
    try std.testing.expectEqualStrings("trimmed", c.tag);
    try std.testing.expect(c.is_weak);
}

test "weakMatch ignores weak indicator and compares the opaque tag" {
    try std.testing.expect(weakMatch("abc", true, "abc", false));
    try std.testing.expect(weakMatch("abc", false, "abc", false));
    try std.testing.expect(!weakMatch("abc", false, "def", false));
}

test "ifNoneMatch round-trip — wildcard, single, list" {
    try std.testing.expect(ifNoneMatch("\"abc\"", "*"));
    try std.testing.expect(ifNoneMatch("\"abc\"", "\"abc\""));
    try std.testing.expect(ifNoneMatch("\"abc\"", "W/\"abc\""));
    try std.testing.expect(ifNoneMatch("\"abc\"", "\"foo\", \"abc\", \"bar\""));
    try std.testing.expect(!ifNoneMatch("\"abc\"", "\"foo\", \"bar\""));
    try std.testing.expect(!ifNoneMatch("\"abc\"", ""));
}

test "appendToHeaders writes a quoted xxhash64 lower-hex etag" {
    var headers = TestHeaders{};
    try appendToHeaders("hello", &headers);
    try std.testing.expectEqualStrings("etag", headers.name);
    // The value is "<16-hex>" — 18 bytes total (two quotes + 16 nibbles).
    try std.testing.expectEqual(@as(usize, 18), headers.value.len);
    try std.testing.expect(headers.value[0] == '"');
    try std.testing.expect(headers.value[headers.value.len - 1] == '"');
    // ifNoneMatch must accept the produced ETag against itself.
    try std.testing.expect(ifNoneMatch(headers.value, headers.value));
}
