// Home Runtime — string utilities used by copied Bun source.
//
// Mirrors the small subset of Bun's `src/strings/` namespace that the
// leaf files under `src/cli/` and friends need. Each function reproduces
// the upstream semantics — we add complete coverage as more copies pull
// in additional helpers.

const std = @import("std");

pub const string = []const u8;

pub const CodepointIterator = @import("string/immutable.zig").CodepointIterator;
pub const Encoding = @import("string/immutable.zig").Encoding;
pub const EncodingNonAscii = @import("string/immutable.zig").EncodingNonAscii;
pub const UnsignedCodepointIterator = @import("string/immutable.zig").UnsignedCodepointIterator;
pub const decodeWTF8RuneTMultibyte = @import("string/immutable.zig").decodeWTF8RuneTMultibyte;
pub const containsNonBmpCodePointOrIsInvalidIdentifier = @import("string/immutable.zig").containsNonBmpCodePointOrIsInvalidIdentifier;
pub const decodeWTF8RuneT = @import("string/immutable.zig").decodeWTF8RuneT;
pub const encodeWTF8Rune = @import("string/immutable.zig").encodeWTF8Rune;
pub const encodeWTF8RuneT = @import("string/immutable.zig").encodeWTF8RuneT;
pub const indexOfNeedsEscapeForJavaScriptString = @import("string/immutable.zig").indexOfNeedsEscapeForJavaScriptString;
pub const charIsAnySlash = @import("string/immutable.zig").charIsAnySlash;
pub const hasPrefixComptime = @import("string/immutable.zig").hasPrefixComptime;
pub const eqlComptimeUTF16 = @import("string/immutable.zig").eqlComptimeUTF16;
pub const hasPrefixWithWordBoundary = @import("string/immutable.zig").hasPrefixWithWordBoundary;
pub const hasSuffixComptime = @import("string/immutable.zig").hasSuffixComptime;
pub const StringOrTinyString = @import("string/immutable.zig").StringOrTinyString;
pub const toUTF8AllocWithType = toUTF8Alloc;
pub const u3_fast = @import("string/immutable.zig").u3_fast;
pub const sortDesc = @import("string/immutable.zig").sortDesc;
pub const unicode_replacement = @import("string/immutable.zig").unicode_replacement;
pub const wtf8ByteSequenceLengthWithInvalid = @import("string/immutable.zig").wtf8ByteSequenceLengthWithInvalid;

pub fn indexOfChar(slice: []const u8, char: u8) ?usize {
    return std.mem.indexOfScalar(u8, slice, char);
}

pub fn lastIndexOfChar(slice: []const u8, char: u8) ?usize {
    return std.mem.lastIndexOfScalar(u8, slice, char);
}

pub fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

pub fn index(haystack: []const u8, needle: []const u8) i32 {
    return @intCast(indexOf(haystack, needle) orelse return -1);
}

pub fn lastIndex(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.lastIndexOf(u8, haystack, needle);
}

pub const lastIndexOf = lastIndex;

pub fn countChar(slice: []const u8, char: u8) usize {
    var count: usize = 0;
    for (slice) |value| {
        if (value == char) count += 1;
    }
    return count;
}

/// Find the first index in `slice` containing any byte from `needles`.
/// Mirrors `bun.strings.indexOfAny`. Used by `escapeRegExp` + assorted
/// scanner helpers.
pub fn indexOfAny(slice: []const u8, comptime needles: []const u8) ?usize {
    return std.mem.indexOfAny(u8, slice, needles);
}

pub fn indexEqualAny(in: anytype, target: []const u8) ?usize {
    for (in, 0..) |value, i| {
        if (eqlLong(value, target, true)) return i;
    }
    return null;
}

pub fn indexOfSpaceOrNewlineOrNonASCII(slice: []const u8, offset: u32) ?u32 {
    var i: usize = offset;
    while (i < slice.len) : (i += 1) {
        const c = slice[i];
        if (c > 127 or c == ' ' or c == '\r' or c == '\n') return @intCast(i);
    }
    return null;
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

pub fn withoutTrailingSlash(input: []const u8) []const u8 {
    var path = input;
    while (path.len > 1 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\')) {
        path.len -= 1;
    }
    return path;
}

pub fn withoutTrailingSlashWindowsPath(input: []const u8) []const u8 {
    if (input.len < 3 or input[1] != ':') return withoutTrailingSlash(input);

    var root_len: usize = 3;
    if (input.len >= 2 and input[0] == '\\' and input[1] == '\\') {
        var slash_count: usize = 0;
        root_len = input.len;
        for (input, 0..) |char, input_index| {
            if (char == '\\' or char == '/') {
                slash_count += 1;
                if (slash_count == 4) {
                    root_len = input_index + 1;
                    break;
                }
            }
        }
    }

    var path = input;
    while (path.len > root_len and (path[path.len - 1] == '/' or path[path.len - 1] == '\\')) {
        path.len -= 1;
    }
    return path;
}

pub fn pathContainsNodeModulesFolder(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "/node_modules/") != null) return true;
    if (std.mem.endsWith(u8, path, "/node_modules")) return true;
    if (std.mem.indexOf(u8, path, "\\node_modules\\") != null) return true;
    return std.mem.endsWith(u8, path, "\\node_modules");
}

pub fn allocateLatin1IntoUTF8(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var extra: usize = 0;
    for (input) |byte| {
        if (byte >= 0x80) extra += 1;
    }

    const output = try allocator.alloc(u8, input.len + extra);
    var out_i: usize = 0;
    for (input) |byte| {
        if (byte < 0x80) {
            output[out_i] = byte;
            out_i += 1;
        } else {
            output[out_i] = 0xC0 | @as(u8, @intCast(byte >> 6));
            output[out_i + 1] = 0x80 | (byte & 0x3F);
            out_i += 2;
        }
    }
    return output;
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
    return indexOf(slice, needle) != null;
}

pub const includes = contains;

pub fn containsComptime(slice: []const u8, comptime needle: []const u8) bool {
    if (comptime needle.len == 0) @compileError("containsComptime requires a non-empty needle");
    return std.mem.indexOf(u8, slice, needle) != null;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn eqlLong(a: []const u8, b: []const u8, comptime check_len: bool) bool {
    if (comptime check_len) {
        if (a.len != b.len) return false;
    } else if (b.len > a.len) {
        return false;
    }
    return std.mem.eql(u8, a[0..b.len], b);
}

pub fn eqlLongT(comptime T: type, a: []const T, b: []const T, comptime check_len: bool) bool {
    if (comptime check_len) {
        if (a.len != b.len) return false;
    } else if (b.len > a.len) {
        return false;
    }
    return std.mem.eql(T, a[0..b.len], b);
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

pub fn eqlCaseInsensitiveASCIIICheckLength(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

pub fn isAllASCII(slice: []const u8) bool {
    return firstNonASCII(slice) == null;
}

pub fn firstNonASCII(slice: []const u8) ?u32 {
    for (slice, 0..) |value, i| {
        if (value > 127) return @intCast(i);
    }
    return null;
}

pub fn firstNonASCII16(slice: []const u16) ?u32 {
    for (slice, 0..) |value, i| {
        if (value > 127) return @intCast(i);
    }
    return null;
}

pub fn copyU16IntoU8(output: []u8, input: []align(1) const u16) void {
    const count = @min(output.len, input.len);
    for (input[0..count], output[0..count]) |from, *to| {
        to.* = @truncate(from);
    }
}

pub fn utf16EqlString(text: []const u16, expected: []const u8) bool {
    var encoded = [4]u8{ 0, 0, 0, 0 };
    var byte_index: usize = 0;
    var unit_index: usize = 0;

    while (unit_index < text.len) : (unit_index += 1) {
        var code_point: u32 = text[unit_index];
        if (code_point >= 0xD800 and code_point <= 0xDBFF and unit_index + 1 < text.len) {
            const low: u32 = text[unit_index + 1];
            if (low >= 0xDC00 and low <= 0xDFFF) {
                code_point = 0x10000 + ((code_point - 0xD800) << 10) + (low - 0xDC00);
                unit_index += 1;
            }
        } else if (code_point >= 0xDC00 and code_point <= 0xDFFF) {
            code_point = 0xFFFD;
        }

        const width = encodeUTF8(&encoded, code_point);
        if (byte_index + width > expected.len) return false;
        if (!std.mem.eql(u8, encoded[0..width], expected[byte_index..][0..width])) return false;
        byte_index += width;
    }

    return byte_index == expected.len;
}

fn encodeUTF8(out: *[4]u8, code_point: u32) u3 {
    if (code_point <= 0x7F) {
        out[0] = @intCast(code_point);
        return 1;
    }
    if (code_point <= 0x7FF) {
        out[0] = 0xC0 | @as(u8, @intCast(code_point >> 6));
        out[1] = 0x80 | @as(u8, @intCast(code_point & 0x3F));
        return 2;
    }
    if (code_point <= 0xFFFF) {
        out[0] = 0xE0 | @as(u8, @intCast(code_point >> 12));
        out[1] = 0x80 | @as(u8, @intCast((code_point >> 6) & 0x3F));
        out[2] = 0x80 | @as(u8, @intCast(code_point & 0x3F));
        return 3;
    }

    out[0] = 0xF0 | @as(u8, @intCast(code_point >> 18));
    out[1] = 0x80 | @as(u8, @intCast((code_point >> 12) & 0x3F));
    out[2] = 0x80 | @as(u8, @intCast((code_point >> 6) & 0x3F));
    out[3] = 0x80 | @as(u8, @intCast(code_point & 0x3F));
    return 4;
}

pub fn append(allocator: std.mem.Allocator, first: []const u8, second: []const u8) std.mem.Allocator.Error![]u8 {
    return cat(allocator, first, second);
}

pub fn cat(allocator: std.mem.Allocator, first: []const u8, second: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, first.len + second.len);
    @memcpy(out[0..first.len], first);
    @memcpy(out[first.len..], second);
    return out;
}

pub fn concat(allocator: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error![]u8 {
    var total_length: usize = 0;
    for (args) |arg| total_length += arg.len;

    const out = try allocator.alloc(u8, total_length);
    copyJoined(out, args);
    return out;
}

pub fn concatIfNeeded(
    allocator: std.mem.Allocator,
    dest: *[]const u8,
    args: []const []const u8,
    interned_strings_to_check: []const []const u8,
) std.mem.Allocator.Error!void {
    var total_length: usize = 0;
    for (args) |arg| total_length += arg.len;

    if (total_length == 0) {
        dest.* = "";
        return;
    }

    for (interned_strings_to_check) |interned| {
        if (joinedEql(args, interned)) {
            dest.* = interned;
            return;
        }
    }

    if (joinedEql(args, dest.*)) return;

    const out = try allocator.alloc(u8, total_length);
    copyJoined(out, args);
    dest.* = out;
}

fn joinedEql(args: []const []const u8, candidate: []const u8) bool {
    var total_length: usize = 0;
    for (args) |arg| total_length += arg.len;
    if (candidate.len != total_length) return false;

    var offset: usize = 0;
    for (args) |arg| {
        if (!std.mem.eql(u8, candidate[offset..][0..arg.len], arg)) return false;
        offset += arg.len;
    }
    return true;
}

fn copyJoined(out: []u8, args: []const []const u8) void {
    var offset: usize = 0;
    for (args) |arg| {
        @memcpy(out[offset..][0..arg.len], arg);
        offset += arg.len;
    }
}

pub fn toUTF8AllocWithTypeWithoutInvalidSurrogatePairs(
    allocator: std.mem.Allocator,
    utf16: []const u16,
) std.mem.Allocator.Error![]u8 {
    return toUTF8Alloc(allocator, utf16);
}

pub fn toUTF16AllocForReal(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    comptime fail_if_invalid: bool,
    comptime sentinel: bool,
) !if (sentinel) [:0]u16 else []u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, bytes.len + if (sentinel) 1 else 0);

    var i: usize = 0;
    while (i < bytes.len) {
        const first = bytes[i];
        if (first < 0x80) {
            out.appendAssumeCapacity(first);
            i += 1;
            continue;
        }

        const decoded = decodeUTF8Codepoint(bytes[i..]) catch |err| {
            if (comptime fail_if_invalid) return err;
            out.appendAssumeCapacity(0xFFFD);
            i += 1;
            continue;
        };
        i += decoded.len;

        if (decoded.code_point <= 0xFFFF) {
            out.appendAssumeCapacity(@intCast(decoded.code_point));
        } else {
            const scalar = decoded.code_point - 0x10000;
            out.appendAssumeCapacity(@intCast(0xD800 + (scalar >> 10)));
            out.appendAssumeCapacity(@intCast(0xDC00 + (scalar & 0x3FF)));
        }
    }

    if (comptime sentinel) {
        out.appendAssumeCapacity(0);
        const owned = try out.toOwnedSlice(allocator);
        return owned[0 .. owned.len - 1 :0];
    }

    return out.toOwnedSlice(allocator);
}

pub fn toUTF16Alloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    comptime fail_if_invalid: bool,
    comptime sentinel: bool,
) !if (sentinel) ?[:0]u16 else ?[]u16 {
    if (firstNonASCII(bytes) == null) return null;
    return try toUTF16AllocForReal(allocator, bytes, fail_if_invalid, sentinel);
}

const DecodedCodepoint = struct {
    code_point: u32,
    len: u3,
};

fn decodeUTF8Codepoint(bytes: []const u8) error{InvalidByteSequence}!DecodedCodepoint {
    if (bytes.len == 0) return error.InvalidByteSequence;

    const first = bytes[0];
    if (first < 0x80) return .{ .code_point = first, .len = 1 };

    const len: u3 = if (first >= 0xC2 and first <= 0xDF)
        2
    else if (first >= 0xE0 and first <= 0xEF)
        3
    else if (first >= 0xF0 and first <= 0xF4)
        4
    else
        return error.InvalidByteSequence;

    if (bytes.len < len) return error.InvalidByteSequence;

    var code_point: u32 = first & switch (len) {
        2 => @as(u8, 0x1F),
        3 => @as(u8, 0x0F),
        4 => @as(u8, 0x07),
        else => unreachable,
    };

    for (bytes[1..len]) |byte| {
        if ((byte & 0xC0) != 0x80) return error.InvalidByteSequence;
        code_point = (code_point << 6) | (byte & 0x3F);
    }

    if ((len == 2 and code_point < 0x80) or
        (len == 3 and code_point < 0x800) or
        (len == 4 and code_point < 0x10000) or
        (code_point >= 0xD800 and code_point <= 0xDFFF) or
        code_point > 0x10FFFF)
    {
        return error.InvalidByteSequence;
    }

    return .{ .code_point = code_point, .len = len };
}

/// Convert a UTF-16 (Little Endian) code-unit slice to an owned
/// UTF-8 byte slice. Mirrors `bun.strings.toUTF8Alloc` — the caller
/// owns the returned bytes and frees via the same allocator.
/// Handles surrogate pairs (high+low → 4-byte UTF-8); emits U+FFFD
/// (0xEF 0xBF 0xBD) for unpaired surrogates so the output is always
/// valid UTF-8. Worst case is 3 bytes per code unit.
pub fn toUTF8Alloc(
    allocator: std.mem.Allocator,
    utf16: []const u16,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Worst case for BMP characters: 3 bytes per code unit. Surrogate
    // pairs collapse to 4 bytes for 2 code units (2 bytes/CU) so this
    // upper bound holds.
    try out.ensureTotalCapacityPrecise(allocator, utf16.len * 3);
    var i: usize = 0;
    while (i < utf16.len) : (i += 1) {
        const cu = utf16[i];
        if (cu < 0x80) {
            out.appendAssumeCapacity(@truncate(cu));
        } else if (cu < 0x800) {
            out.appendAssumeCapacity(@as(u8, 0xC0) | @as(u8, @truncate(cu >> 6)));
            out.appendAssumeCapacity(@as(u8, 0x80) | @as(u8, @truncate(cu & 0x3F)));
        } else if (cu >= 0xD800 and cu <= 0xDBFF) {
            // High surrogate — needs a paired low surrogate.
            if (i + 1 < utf16.len) {
                const next = utf16[i + 1];
                if (next >= 0xDC00 and next <= 0xDFFF) {
                    const code_point: u32 = 0x10000 +
                        ((@as(u32, cu) - 0xD800) << 10) +
                        (@as(u32, next) - 0xDC00);
                    out.appendAssumeCapacity(@as(u8, 0xF0) | @as(u8, @truncate(code_point >> 18)));
                    out.appendAssumeCapacity(@as(u8, 0x80) | @as(u8, @truncate((code_point >> 12) & 0x3F)));
                    out.appendAssumeCapacity(@as(u8, 0x80) | @as(u8, @truncate((code_point >> 6) & 0x3F)));
                    out.appendAssumeCapacity(@as(u8, 0x80) | @as(u8, @truncate(code_point & 0x3F)));
                    i += 1;
                    continue;
                }
            }
            // Unpaired high surrogate — emit U+FFFD.
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
        } else if (cu >= 0xDC00 and cu <= 0xDFFF) {
            // Unpaired low surrogate.
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
        } else {
            // BMP, non-surrogate: 3-byte UTF-8.
            out.appendAssumeCapacity(@as(u8, 0xE0) | @as(u8, @truncate(cu >> 12)));
            out.appendAssumeCapacity(@as(u8, 0x80) | @as(u8, @truncate((cu >> 6) & 0x3F)));
            out.appendAssumeCapacity(@as(u8, 0x80) | @as(u8, @truncate(cu & 0x3F)));
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Convert a Latin-1 (ISO 8859-1) byte slice to UTF-8. Returns `null`
/// when the input is pure ASCII (every byte <= 0x7F) so the caller
/// can reuse the original slice without an allocation. Otherwise
/// returns an `ArrayList` owning the freshly-allocated UTF-8 bytes.
/// Mirrors `bun.strings.toUTF8FromLatin1` — high bytes (0x80–0xFF)
/// each expand to a two-byte UTF-8 sequence (`110xxxxx 10xxxxxx`).
pub fn toUTF8FromLatin1(
    allocator: std.mem.Allocator,
    latin1: []const u8,
) std.mem.Allocator.Error!?std.ArrayList(u8) {
    // First pass: do we have any high bytes? If not, the input is
    // already valid UTF-8 — signal that by returning null so callers
    // skip the allocation.
    var has_high = false;
    for (latin1) |b| {
        if (b >= 0x80) {
            has_high = true;
            break;
        }
    }
    if (!has_high) return null;

    // Worst case: every byte is high → two-byte UTF-8 expansion.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, latin1.len * 2);
    for (latin1) |b| {
        if (b < 0x80) {
            out.appendAssumeCapacity(b);
        } else {
            // 0xC0 | (b >> 6) gives 0xC2 or 0xC3 (Latin-1 supplement
            // block lives entirely in U+0080..U+00FF, which the
            // 2-byte UTF-8 form encodes as `110000xx 10xxxxxx`).
            out.appendAssumeCapacity(0xC0 | (b >> 6));
            out.appendAssumeCapacity(0x80 | (b & 0x3F));
        }
    }
    return out;
}

test "indexOfChar finds the first occurrence" {
    try std.testing.expectEqual(@as(?usize, 3), indexOfChar("foo:bar", ':'));
    try std.testing.expectEqual(@as(?usize, null), indexOfChar("foobar", ':'));
}

test "toUTF8FromLatin1: returns null for pure ASCII input" {
    const out = try toUTF8FromLatin1(std.testing.allocator, "hello world");
    try std.testing.expect(out == null);
}

test "toUTF8FromLatin1: expands Latin-1 high bytes to 2-byte UTF-8" {
    const maybe = try toUTF8FromLatin1(std.testing.allocator, "caf\xE9");
    try std.testing.expect(maybe != null);
    var out = maybe.?;
    defer out.deinit(std.testing.allocator);
    // U+00E9 (é) encodes as 0xC3 0xA9 in UTF-8.
    try std.testing.expectEqualSlices(u8, "caf\xC3\xA9", out.items);
}

test "toUTF8FromLatin1: covers the full Latin-1 supplement block" {
    // 0x80 → C2 80, 0xFF → C3 BF. Spot-check both endpoints.
    const maybe = try toUTF8FromLatin1(std.testing.allocator, "\x80\xFF");
    try std.testing.expect(maybe != null);
    var out = maybe.?;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "\xC2\x80\xC3\xBF", out.items);
}

test "toUTF8Alloc: ASCII passes through unchanged" {
    const ascii: []const u16 = &.{ 'h', 'i', '!' };
    const out = try toUTF8Alloc(std.testing.allocator, ascii);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, "hi!", out);
}

test "toUTF8Alloc: BMP non-surrogate emits 3-byte UTF-8" {
    // U+00E9 (é) → C3 A9 (2-byte), U+4E2D (中) → E4 B8 AD (3-byte).
    const utf16: []const u16 = &.{ 0x00E9, 0x4E2D };
    const out = try toUTF8Alloc(std.testing.allocator, utf16);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, "\xC3\xA9\xE4\xB8\xAD", out);
}

test "toUTF8Alloc: surrogate pair encodes as 4-byte UTF-8" {
    // U+1F600 (😀) — high D83D, low DE00 → F0 9F 98 80.
    const utf16: []const u16 = &.{ 0xD83D, 0xDE00 };
    const out = try toUTF8Alloc(std.testing.allocator, utf16);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, "\xF0\x9F\x98\x80", out);
}

test "toUTF8Alloc: unpaired surrogate emits U+FFFD" {
    // High surrogate without a following low surrogate.
    const utf16: []const u16 = &.{ 0xD83D, 0x0041 }; // <high>, 'A'
    const out = try toUTF8Alloc(std.testing.allocator, utf16);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, "\xEF\xBF\xBDA", out);
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

test "eqlCaseInsensitiveASCIIICheckLength requires matching length" {
    try std.testing.expect(eqlCaseInsensitiveASCIIICheckLength("BROWSER", "browser"));
    try std.testing.expect(!eqlCaseInsensitiveASCIIICheckLength("bun", "bunny"));
}
