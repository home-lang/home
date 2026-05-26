// Home Runtime — string utilities used by copied Bun source.
//
// Mirrors the small subset of Bun's `src/strings/` namespace that the
// leaf files under `src/cli/` and friends need. Each function reproduces
// the upstream semantics — we add complete coverage as more copies pull
// in additional helpers.

const std = @import("std");

pub const u3_fast = u3;
pub const unicode_replacement: u21 = 0xFFFD;

pub const AsciiStatus = enum {
    unknown,
    all_ascii,
    non_ascii,

    pub fn fromBool(is_all_ascii: ?bool) AsciiStatus {
        return if (is_all_ascii orelse return .unknown) .all_ascii else .non_ascii;
    }
};

pub fn indexOfChar(slice: []const u8, char: u8) ?usize {
    return std.mem.indexOfScalar(u8, slice, char);
}

pub fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

/// Find the first index in `slice` containing any byte from `needles`.
/// Mirrors `bun.strings.indexOfAny`. Used by `escapeRegExp` + assorted
/// scanner helpers.
pub fn indexOfAny(slice: []const u8, comptime needles: []const u8) ?usize {
    return std.mem.indexOfAny(u8, slice, needles);
}

pub fn startsWith(slice: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, slice, prefix);
}

/// Upstream Bun spells this `hasPrefix`; keep both so copied source
/// compiles without per-callsite rewrites.
pub fn hasPrefix(slice: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, slice, prefix);
}

pub fn endsWith(slice: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, slice, suffix);
}

/// Comptime-known suffix match. Mirrors `bun.strings.endsWithComptime`.
pub fn endsWithComptime(slice: []const u8, comptime suffix: []const u8) bool {
    if (slice.len < suffix.len) return false;
    return eqlComptime(slice[slice.len - suffix.len ..], suffix);
}

pub fn containsChar(slice: []const u8, char: u8) bool {
    return std.mem.indexOfScalar(u8, slice, char) != null;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Comptime-aware equality check that asserts the comptime length
/// matches at compile time. Used by the `ComptimeStringMap` family
/// to short-circuit per-length buckets without re-checking `len`
/// at runtime. The `check_len` flag mirrors the upstream signature
/// — when false the caller has already proven the lengths match.
pub fn eqlComptime(self: []const u8, comptime alt: []const u8) bool {
    return eqlComptimeCheckLenWithType(u8, self, alt, true);
}

pub fn eqlComptimeCheckLenWithType(
    comptime CodeUnit: type,
    a: []const CodeUnit,
    comptime b: []const CodeUnit,
    comptime check_len: bool,
) bool {
    if (comptime check_len) {
        if (a.len != b.len) return false;
    } else {
        if (a.len != b.len) return false;
    }
    inline for (b, 0..) |c, i| {
        if (a[i] != c) return false;
    }
    return true;
}

/// Case-insensitive equality that ignores the length difference (upstream
/// behavior: callers ensure the length matches at the call site). Mirrors
/// `bun.strings.eqlComptimeIgnoreLen` — but Home's copy is conservative
/// and still checks length, since the only caller is the comptime-map
/// lowercase path which has already established length parity.
pub fn eqlComptimeIgnoreLen(a: anytype, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (b, 0..) |c, i| {
        const ac = a[i];
        const lower_ac: u8 = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const lower_b: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (lower_ac != lower_b) return false;
    }
    return true;
}

pub fn isAllASCII(slice: []const u8) bool {
    for (slice) |byte| {
        if (byte > 0x7f) return false;
    }
    return true;
}

pub fn eqlComptimeUTF16(self: []const u16, comptime alt: []const u8) bool {
    if (self.len != alt.len) return false;
    inline for (alt, 0..) |c, i| {
        if (self[i] != c) return false;
    }
    return true;
}

pub fn elementLengthUTF16IntoUTF8(utf16: []const u16) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < utf16.len) {
        const cp = std.unicode.utf16DecodeSurrogatePair(utf16[i..]) catch blk: {
            const value: u21 = utf16[i];
            i += 1;
            break :blk value;
        };
        if (cp > 0xFFFF) i += 2;
        len += std.unicode.utf8CodepointSequenceLength(cp) catch 3;
    }
    return len;
}

pub fn toUTF8ListWithType(list_: std.array_list.Managed(u8), utf16: []const u16) !std.array_list.Managed(u8) {
    var list = list_;
    try list.ensureUnusedCapacity(elementLengthUTF16IntoUTF8(utf16));
    var i: usize = 0;
    while (i < utf16.len) {
        const cp = std.unicode.utf16DecodeSurrogatePair(utf16[i..]) catch blk: {
            const value: u21 = utf16[i];
            i += 1;
            break :blk value;
        };
        if (cp > 0xFFFF) i += 2;
        var buf: [4]u8 = undefined;
        const width = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(unicode_replacement, &buf) catch unreachable;
        list.appendSliceAssumeCapacity(buf[0..width]);
    }
    return list;
}

pub fn allocateLatin1IntoUTF8WithList(list_: std.array_list.Managed(u8), offset_into_list: usize, latin1: []const u8) !std.array_list.Managed(u8) {
    var list = list_;
    try list.ensureTotalCapacity(offset_into_list + latin1.len * 2);
    if (list.items.len < offset_into_list) list.items.len = offset_into_list;
    for (latin1) |byte| {
        if (byte < 0x80) {
            list.appendAssumeCapacity(byte);
        } else {
            list.appendAssumeCapacity(0xC0 | @as(u8, @intCast(byte >> 6)));
            list.appendAssumeCapacity(0x80 | (byte & 0x3F));
        }
    }
    return list;
}

pub fn toUTF8FromLatin1(allocator: std.mem.Allocator, latin1: []const u8) !?std.array_list.Managed(u8) {
    if (isAllASCII(latin1)) return null;
    return try allocateLatin1IntoUTF8WithList(std.array_list.Managed(u8).init(allocator), 0, latin1);
}

pub fn toUTF8FromLatin1Z(allocator: std.mem.Allocator, latin1: []const u8) !?std.array_list.Managed(u8) {
    var list = (try toUTF8FromLatin1(allocator, latin1)) orelse return null;
    try list.append(0);
    return list;
}

pub fn toUTF8Alloc(allocator: std.mem.Allocator, utf16: []const u16) ![]u8 {
    var list = try toUTF8ListWithType(std.array_list.Managed(u8).init(allocator), utf16);
    return try list.toOwnedSlice();
}

pub fn toUTF8AllocZ(allocator: std.mem.Allocator, utf16: []const u16) ![:0]u8 {
    var list = try toUTF8ListWithType(std.array_list.Managed(u8).init(allocator), utf16);
    return try list.toOwnedSliceSentinel(0);
}

test "indexOfChar finds the first occurrence" {
    try std.testing.expectEqual(@as(?usize, 3), indexOfChar("foo:bar", ':'));
    try std.testing.expectEqual(@as(?usize, null), indexOfChar("foobar", ':'));
}

test "eqlComptimeCheckLenWithType matches identical strings" {
    try std.testing.expect(eqlComptimeCheckLenWithType(u8, "hello", "hello", true));
    try std.testing.expect(!eqlComptimeCheckLenWithType(u8, "hello", "world", true));
    try std.testing.expect(!eqlComptimeCheckLenWithType(u8, "hi", "hello", true));
}

test "eqlComptimeIgnoreLen is case-insensitive" {
    try std.testing.expect(eqlComptimeIgnoreLen("HELLO", "hello"));
    try std.testing.expect(eqlComptimeIgnoreLen("Hello", "hello"));
    try std.testing.expect(!eqlComptimeIgnoreLen("world", "hello"));
}
