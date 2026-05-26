// Home Runtime — string utilities used by copied Bun source.
//
// Mirrors the small subset of Bun's `src/strings/` namespace that the
// leaf files under `src/cli/` and friends need. Each function reproduces
// the upstream semantics — we add complete coverage as more copies pull
// in additional helpers.

const std = @import("std");

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
