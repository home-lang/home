// Home Runtime — string utilities used by copied Bun source.
//
// Mirrors the small subset of Bun's `src/strings/` namespace that the
// leaf files under `src/cli/` and friends need. Each function reproduces
// the upstream semantics — we add complete coverage as more copies pull
// in additional helpers.

const std = @import("std");

pub const u3_fast = u3;
pub const unicode_replacement: u21 = 0xFFFD;
pub const StringOrTinyString = @import("string/immutable.zig").StringOrTinyString;

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

pub fn lastIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.lastIndexOf(u8, haystack, needle);
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

pub fn hasPrefixComptime(slice: []const u8, comptime prefix: []const u8) bool {
    if (slice.len < prefix.len) return false;
    return eqlComptime(slice[0..prefix.len], prefix);
}

pub fn hasPrefixComptimeUTF16(slice: []const u16, comptime prefix: []const u8) bool {
    if (slice.len < prefix.len) return false;
    inline for (prefix, 0..) |c, i| {
        if (slice[i] != c) return false;
    }
    return true;
}

pub fn hasPrefixComptimeType(comptime T: type, slice: []const T, comptime prefix: anytype) bool {
    if (slice.len < prefix.len) return false;
    inline for (prefix, 0..) |c, i| {
        if (slice[i] != c) return false;
    }
    return true;
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

pub fn contains(slice: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, slice, needle) != null;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn eqlCaseInsensitiveASCII(a: []const u8, b: []const u8, comptime check_len: bool) bool {
    if (check_len and a.len != b.len) return false;
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
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

pub fn convertUTF16ToUTF8Append(list: *std.array_list.Managed(u8), utf16: []const u16) !void {
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
}

pub fn split(slice: []const u8, delimiter: []const u8) std.mem.SplitIterator(u8, .sequence) {
    return std.mem.splitSequence(u8, slice, delimiter);
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

pub const CodepointIterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub const Cursor = struct {
        c: u21 = 0,
        i: usize = 0,
        width: usize = 0,
    };

    pub fn next(this: *CodepointIterator, cursor: *Cursor) bool {
        if (this.i >= this.bytes.len) return false;
        const start = this.i;
        const width = std.unicode.utf8ByteSequenceLength(this.bytes[start]) catch 1;
        const end = @min(start + width, this.bytes.len);
        const codepoint = std.unicode.utf8Decode(this.bytes[start..end]) catch this.bytes[start];
        this.i = end;
        cursor.* = .{ .c = codepoint, .i = start, .width = end - start };
        return true;
    }
};

pub const EncodeIntoResult = struct {
    read: usize,
    written: usize,
};

pub fn copyLatin1IntoASCII(dest: []u8, src: []const u8) void {
    const len = @min(dest.len, src.len);
    for (src[0..len], 0..) |byte, i| {
        dest[i] = byte & 0x7f;
    }
}

pub fn copyLatin1IntoUTF8(dest: []u8, src: []const u8) EncodeIntoResult {
    var read: usize = 0;
    var written: usize = 0;
    while (read < src.len) : (read += 1) {
        const byte = src[read];
        if (byte < 0x80) {
            if (written >= dest.len) break;
            dest[written] = byte;
            written += 1;
        } else {
            if (written + 2 > dest.len) break;
            dest[written] = 0xC0 | @as(u8, @intCast(byte >> 6));
            dest[written + 1] = 0x80 | (byte & 0x3F);
            written += 2;
        }
    }
    return .{ .read = read, .written = written };
}

pub fn copyLatin1IntoUTF16(comptime Buffer: type, dest: Buffer, src: []const u8) EncodeIntoResult {
    const len = @min(dest.len, src.len);
    for (src[0..len], 0..) |byte, i| {
        dest[i] = byte;
    }
    return .{ .read = len, .written = len };
}

pub fn elementLengthLatin1IntoUTF8(src: []const u8) usize {
    var len: usize = 0;
    for (src) |byte| len += if (byte < 0x80) @as(usize, 1) else 2;
    return len;
}

pub fn elementLengthUTF8IntoUTF16(src: []const u8) usize {
    const view = std.unicode.Utf8View.init(src) catch return src.len;
    var iter = view.iterator();
    var len: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        len += if (cp > 0xffff) @as(usize, 2) else 1;
    }
    return len;
}

pub fn copyUTF16IntoUTF8Impl(dest: []u8, src: []const u16, comptime allow_partial_write: bool) EncodeIntoResult {
    var read: usize = 0;
    var written: usize = 0;
    while (read < src.len) {
        const cp = std.unicode.utf16DecodeSurrogatePair(src[read..]) catch blk: {
            const value: u21 = src[read];
            read += 1;
            break :blk value;
        };
        if (cp > 0xffff) read += 2;
        var buf: [4]u8 = undefined;
        const width = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(unicode_replacement, &buf) catch unreachable;
        if (written + width > dest.len) {
            if (!allow_partial_write) break;
            const remaining = dest.len - written;
            @memcpy(dest[written..][0..remaining], buf[0..remaining]);
            written += remaining;
            break;
        }
        @memcpy(dest[written..][0..width], buf[0..width]);
        written += width;
    }
    return .{ .read = read, .written = written };
}

pub fn copyU16IntoU8(dest: []u8, src: []const u16) void {
    const len = @min(dest.len, src.len);
    for (src[0..len], 0..) |value, i| {
        dest[i] = @truncate(value);
    }
}

pub fn allocateLatin1IntoUTF8(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const dest = try allocator.alloc(u8, elementLengthLatin1IntoUTF8(src));
    const wrote = copyLatin1IntoUTF8(dest, src).written;
    return dest[0..wrote];
}

pub fn toUTF16Alloc(allocator: std.mem.Allocator, bytes: []const u8, comptime fail_if_invalid: bool, comptime sentinel: bool) !if (sentinel) ?[:0]u16 else ?[]u16 {
    _ = fail_if_invalid;
    if (isAllASCII(bytes)) return null;
    var list = std.array_list.Managed(u16).init(allocator);
    errdefer list.deinit();
    const view = std.unicode.Utf8View.init(bytes) catch {
        for (bytes) |byte| try list.append(byte);
        return if (sentinel) try list.toOwnedSliceSentinel(0) else try list.toOwnedSlice();
    };
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (cp <= 0xffff) {
            try list.append(@intCast(cp));
        } else {
            var pair: [2]u16 = undefined;
            const adjusted = cp - 0x10000;
            pair[0] = 0xD800 + @as(u16, @intCast(adjusted >> 10));
            pair[1] = 0xDC00 + @as(u16, @intCast(adjusted & 0x3FF));
            try list.appendSlice(&pair);
        }
    }
    return if (sentinel) try list.toOwnedSliceSentinel(0) else try list.toOwnedSlice();
}

pub fn toUTF8AllocWithType(allocator: std.mem.Allocator, utf16: []const u16) ![]u8 {
    return toUTF8Alloc(allocator, utf16);
}

pub fn trim(slice: anytype, comptime values_to_strip: []const u8) @TypeOf(slice) {
    return std.mem.trim(@typeInfo(@TypeOf(slice)).pointer.child, slice, values_to_strip);
}

pub fn withoutUTF8BOM(slice: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, slice, "\xEF\xBB\xBF")) slice[3..] else slice;
}

fn hexValue(comptime T: type, c: T) ?u8 {
    const byte: u8 = @truncate(c);
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

pub fn decodeHexToBytesTruncate(dest: []u8, comptime T: type, src: []const T) usize {
    var read: usize = 0;
    var written: usize = 0;
    while (read + 1 < src.len and written < dest.len) : (read += 2) {
        const hi = hexValue(T, src[read]) orelse break;
        const lo = hexValue(T, src[read + 1]) orelse break;
        dest[written] = (hi << 4) | lo;
        written += 1;
    }
    return written;
}

pub fn encodeBytesToHex(dest: []u8, src: []const u8) usize {
    const alphabet = "0123456789abcdef";
    var written: usize = 0;
    for (src) |byte| {
        if (written + 2 > dest.len) break;
        dest[written] = alphabet[byte >> 4];
        dest[written + 1] = alphabet[byte & 0x0f];
        written += 2;
    }
    return written;
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
