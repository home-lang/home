// Home Runtime — string utilities used by copied Bun source.
//
// Mirrors the small subset of Bun's `src/strings/` namespace that the
// leaf files under `src/cli/` and friends need. Each function reproduces
// the upstream semantics — we add complete coverage as more copies pull
// in additional helpers.

const std = @import("std");

pub const repeatingAlloc = @import("string/immutable.zig").repeatingAlloc;

pub fn indexOfNotChar(haystack: []const u8, char: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c != char) return i;
    }
    return null;
}

pub const string = []const u8;

pub const CodepointIterator = @import("string/immutable.zig").CodepointIterator;
pub const trimSubsequentLeadingChars = @import("string/immutable.zig").trimSubsequentLeadingChars;
pub const formatEscapes = @import("string/immutable.zig").formatEscapes;
pub const isAllWhitespace = @import("string/immutable.zig").isAllWhitespace;
pub const isOnCharBoundary = @import("string/immutable.zig").isOnCharBoundary;
pub const trimLeadingChar = @import("string/immutable.zig").trimLeadingChar;
pub const getLinesInText = @import("string/immutable.zig").getLinesInText;
pub const startsWithCaseInsensitiveAscii = @import("string/immutable.zig").startsWithCaseInsensitiveAscii;
pub const splitFirst = @import("string/immutable.zig").splitFirst;
pub const splitFirstWithExpected = @import("string/immutable.zig").splitFirstWithExpected;
pub const utf8ByteSequenceLengthUnsafe = @import("string/immutable.zig").utf8ByteSequenceLengthUnsafe;
pub fn withoutSuffixComptime(input: []const u8, comptime suffix: []const u8) []const u8 {
    return if (hasSuffixComptime(input, suffix)) input[0 .. input.len - suffix.len] else input;
}

pub fn withoutPrefixIfPossibleComptime(input: []const u8, comptime prefix: []const u8) ?[]const u8 {
    return if (hasPrefixComptime(input, prefix)) input[prefix.len..] else null;
}

pub fn order(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}
/// Upstream bun.strings.utf8ByteSequenceLength returns u3 (0 for an invalid
/// leading byte) rather than std.unicode's error union.
pub fn utf8ByteSequenceLength(first_byte: u8) u3 {
    return @import("std").unicode.utf8ByteSequenceLength(first_byte) catch 0;
}

pub fn indexOfNewlineOrNonASCIIOrANSI(input: []const u8, start: usize) ?usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '\n' or c == 0x1b or c >= 0x80) return i;
    }
    return null;
}

pub fn trimLeadingPattern2(input: []const u8, a: u8, b: u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < input.len and input[i] == a and input[i + 1] == b) {
        i += 2;
    }
    return input[i..];
}

pub fn removeLeadingDotSlash(input: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, input, "./")) input[2..] else input;
}
pub const Encoding = @import("string/immutable.zig").Encoding;
pub const EncodingNonAscii = @import("string/immutable.zig").EncodingNonAscii;
pub const AsciiStatus = @import("string/immutable.zig").AsciiStatus;
pub const UnsignedCodepointIterator = @import("string/immutable.zig").UnsignedCodepointIterator;
pub const decodeWTF8RuneTMultibyte = @import("string/immutable.zig").decodeWTF8RuneTMultibyte;
pub const containsNonBmpCodePointOrIsInvalidIdentifier = @import("string/immutable.zig").containsNonBmpCodePointOrIsInvalidIdentifier;
pub const decodeWTF8RuneT = @import("string/immutable.zig").decodeWTF8RuneT;
pub const encodeWTF8Rune = @import("string/immutable.zig").encodeWTF8Rune;
pub const encodeWTF8RuneT = @import("string/immutable.zig").encodeWTF8RuneT;
pub const encodeUTF8Comptime = @import("string/immutable.zig").encodeUTF8Comptime;
pub const indexOfNeedsEscapeForJavaScriptString = @import("string/immutable.zig").indexOfNeedsEscapeForJavaScriptString;
pub const charIsAnySlash = @import("string/immutable.zig").charIsAnySlash;
pub const hasPrefixComptime = @import("string/immutable.zig").hasPrefixComptime;
pub const startsWithWindowsDriveLetter = @import("string/immutable.zig").startsWithWindowsDriveLetter;
pub const startsWithWindowsDriveLetterT = @import("string/immutable.zig").startsWithWindowsDriveLetterT;
pub const eqlComptimeUTF16 = @import("string/immutable.zig").eqlComptimeUTF16;
pub const hasPrefixWithWordBoundary = @import("string/immutable.zig").hasPrefixWithWordBoundary;
pub const hasSuffixComptime = @import("string/immutable.zig").hasSuffixComptime;
pub const StringOrTinyString = @import("string/immutable.zig").StringOrTinyString;
pub const toUTF8AllocWithType = toUTF8Alloc;
pub const u3_fast = @import("string/immutable.zig").u3_fast;
pub const sortDesc = @import("string/immutable.zig").sortDesc;
pub const cmpStringsAsc = @import("string/immutable.zig").cmpStringsAsc;
pub const cmpStringsDesc = @import("string/immutable.zig").cmpStringsDesc;
pub const unicode_replacement = @import("string/immutable.zig").unicode_replacement;
pub const wtf8ByteSequenceLength = @import("string/immutable.zig").wtf8ByteSequenceLength;
pub const indexOfCharUsize = @import("string/immutable.zig").indexOfCharUsize;
pub const indexOfChar16Usize = @import("string/immutable.zig").indexOfChar16Usize;
pub const utf16Codepoint = @import("string/immutable.zig").utf16Codepoint;
pub const utf16CodepointWithFFFD = @import("string/immutable.zig").utf16CodepointWithFFFD;
pub const convertUTF16ToUTF8Append = @import("string/immutable.zig").convertUTF16ToUTF8Append;
pub const whitespace_chars = @import("string/immutable.zig").whitespace_chars;
pub const grapheme = @import("string/immutable.zig").grapheme;
pub const isValidUTF8 = @import("string/immutable.zig").isValidUTF8;
pub const indexOfAny16 = @import("string/immutable.zig").indexOfAny16;
pub const decodeHexToBytes = @import("string/immutable.zig").decodeHexToBytes;
pub const decodeHexToBytesTruncate = @import("string/immutable.zig").decodeHexToBytesTruncate;
pub const trim = @import("string/immutable.zig").trim;
pub const copyLatin1IntoUTF16 = @import("string/immutable.zig").copyLatin1IntoUTF16;
pub const EncodeIntoResult = @import("string/immutable.zig").EncodeIntoResult;
pub const copyLatin1IntoASCII = @import("string/immutable.zig").copyLatin1IntoASCII;
pub const copyLatin1IntoUTF8 = @import("string/immutable.zig").copyLatin1IntoUTF8;
pub const copyUTF16IntoUTF8 = @import("string/immutable.zig").copyUTF16IntoUTF8;
pub const convertUTF8BytesIntoUTF16WithLength = @import("string/immutable.zig").convertUTF8BytesIntoUTF16WithLength;
pub const copyCP1252IntoUTF16 = @import("string/immutable.zig").copyCP1252IntoUTF16;
pub const withoutNTPrefix = @import("string/immutable.zig").withoutNTPrefix;
pub const inMapCaseInsensitive = @import("string/immutable.zig").inMapCaseInsensitive;
pub const isIPAddress = @import("string/immutable.zig").isIPAddress;
pub const toUTF16AllocMaybeBuffered = @import("string/immutable.zig").toUTF16AllocMaybeBuffered;
pub const withoutUTF8BOM = @import("string/immutable.zig").withoutUTF8BOM;
pub const toUTF8ListWithType = @import("string/immutable.zig").toUTF8ListWithType;
pub const allocateLatin1IntoUTF8WithList = @import("string/immutable.zig").allocateLatin1IntoUTF8WithList;
pub const toUTF8ListWithTypeBun = @import("string/immutable.zig").toUTF8ListWithTypeBun;
pub const toUTF8AllocZ = @import("string/immutable.zig").toUTF8AllocZ;
pub const toUTF8FromLatin1Z = @import("string/immutable.zig").toUTF8FromLatin1Z;
pub const elementLengthUTF16IntoUTF8 = @import("string/immutable.zig").elementLengthUTF16IntoUTF8;
pub const eqlCaseInsensitiveASCII = @import("string/immutable.zig").eqlCaseInsensitiveASCII;
pub const eqlCaseInsensitiveASCIIIgnoreLength = @import("string/immutable.zig").eqlCaseInsensitiveASCIIIgnoreLength;
pub const ascii_vector_size = @import("string/immutable.zig").ascii_vector_size;
pub const AsciiVector = @import("string/immutable.zig").AsciiVector;
pub const AsciiVectorU1 = @import("string/immutable.zig").AsciiVectorU1;
pub const AsciiVectorU16U1 = @import("string/immutable.zig").AsciiVectorU16U1;
pub const copyU8IntoU16 = @import("string/immutable.zig").copyU8IntoU16;
pub const copyUTF16IntoUTF8Impl = @import("string/immutable.zig").copyUTF16IntoUTF8Impl;
pub const elementLengthLatin1IntoUTF8 = @import("string/immutable.zig").elementLengthLatin1IntoUTF8;
pub const encodeBytesToHex = @import("string/immutable.zig").encodeBytesToHex;
pub const escapeHTMLForUTF16Input = @import("string/immutable.zig").escapeHTMLForUTF16Input;
pub const indexOfCharPos = @import("string/immutable.zig").indexOfCharPos;
pub const indexOfAnyPosComptime = @import("string/immutable.zig").indexOfAnyPosComptime;
pub const OptionalUsize = @import("string/immutable.zig").OptionalUsize;
pub const codepointSize = @import("string/immutable.zig").codepointSize;
pub const nonASCIISequenceLength = @import("string/immutable.zig").nonASCIISequenceLength;
pub const u16IsLead = @import("string/immutable.zig").u16IsLead;
pub const u16IsTrail = @import("string/immutable.zig").u16IsTrail;
pub const u16Lead = @import("string/immutable.zig").u16Lead;
pub const u16Trail = @import("string/immutable.zig").u16Trail;
pub const log = @import("string/immutable.zig").log;
pub const visible = @import("string/immutable.zig").visible;
pub const copyLatin1IntoUTF8StopOnNonASCII = @import("string/immutable.zig").copyLatin1IntoUTF8StopOnNonASCII;
pub const elementLengthCP1252IntoUTF16 = @import("string/immutable.zig").elementLengthCP1252IntoUTF16;
pub const literal = @import("string/immutable.zig").literal;
pub const wtf8ByteSequenceLengthWithInvalid = @import("string/immutable.zig").wtf8ByteSequenceLengthWithInvalid;
pub const copyLowercase = @import("string/immutable.zig").copyLowercase;
pub const copyLowercaseIfNeeded = @import("string/immutable.zig").copyLowercaseIfNeeded;
pub const wtf8Sequence = @import("string/immutable.zig").wtf8Sequence;
pub const StringArrayByIndexSorter = @import("string/immutable.zig").StringArrayByIndexSorter;
pub const startsWithChar = @import("string/immutable.zig").startsWithChar;
pub const split = @import("string/immutable.zig").split;
pub const SplitIterator = @import("string/immutable.zig").SplitIterator;
pub const ExactSizeMatcher = @import("string/immutable.zig").ExactSizeMatcher;
pub const toWPath = @import("string/immutable.zig").toWPath;
pub const toWPathMaybeDir = @import("string/immutable.zig").toWPathMaybeDir;
pub const toWPathNormalizeAutoExtend = @import("string/immutable.zig").toWPathNormalizeAutoExtend;
pub const toWPathNormalized = @import("string/immutable.zig").toWPathNormalized;
pub const toWPathNormalized16 = @import("string/immutable.zig").toWPathNormalized16;

pub fn normalizeSlashesOnly(buf: []u8, input: []const u8, sep: u8) []u8 {
    const len = @min(buf.len, input.len);
    for (input[0..len], 0..) |c, i| {
        buf[i] = if (c == '/' or c == '\\') sep else c;
    }
    return buf[0..len];
}

/// Faithful port of Bun's `string_paths.cloneNormalizingSeparators`
/// (src/paths/string_paths.zig). Collapses duplicate slashes AND emits a single
/// trailing separator — the latter is relied on by `ZigString.Slice
/// .cloneWithTrailingSlash` (FileSystemRouter's `path_to_use`). The previous
/// stub only swapped `\\`→`/` and produced NO trailing slash, so
/// `Routes.init`'s `route_dirname_len = relative_dir.len + (dir-has-no-trailing-
/// sep)` came out as 1 instead of 0 and stripped the leading `/` from every
/// route name → `router.zig` `bun.assert(name[0] == '/')` panic.
pub fn cloneNormalizingSeparators(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const sep = std.fs.path.sep;
    // remove duplicate slashes in the file path
    const base = withoutTrailingSlash(input);
    if (base.len == 0) {
        // Nothing to normalize (input was empty or all separators). Mirror the
        // upstream `assert(base.len > 0)` precondition without panicking.
        return allocator.dupe(u8, input);
    }
    var tokenized = std.mem.tokenizeScalar(u8, base, sep);
    var buf = try allocator.alloc(u8, base.len + 2);
    if (base[0] == sep) {
        buf[0] = sep;
    }
    var remain = buf[@as(usize, @intFromBool(base[0] == sep))..];

    while (tokenized.next()) |token| {
        if (token.len == 0) continue;
        @memcpy(remain[0..token.len], token);
        remain[token.len] = sep;
        remain = remain[token.len + 1 ..];
    }
    if ((remain.ptr - 1) != buf.ptr and (remain.ptr - 1)[0] != sep) {
        remain[0] = sep;
        remain = remain[1..];
    }

    // Upstream returns `buf[0..len]` — a sub-slice of the `base.len + 2`
    // allocation, then writes a trailing NUL it never includes. Upstream
    // callers free via an arena, so the size mismatch is harmless there. Home's
    // allocators (the test GeneralPurposeAllocator and the production mimalloc
    // arena) are size-strict: freeing a sub-slice corrupts the heap (mimalloc
    // segfault on the next alloc) or trips the GPA's free-size assert. Shrink to
    // the exact length so the returned slice is independently freeable.
    const len = @intFromPtr(remain.ptr) - @intFromPtr(buf.ptr);
    return try allocator.realloc(buf, len);
}

pub const escapeHTMLForLatin1Input = @import("string/immutable.zig").escapeHTMLForLatin1Input;

pub fn isIPV6Address(input: []const u8) bool {
    return std.mem.indexOfScalar(u8, input, ':') != null;
}

pub fn toUTF16Literal(comptime input: []const u8) [:0]const u16 {
    return @import("string/immutable.zig").toUTF16Literal(input);
}

pub fn copy(dest: []u8, src: []const u8) void {
    std.mem.copyForwards(u8, dest, src);
}

pub fn indexOfNewlineOrNonASCII(input: []const u8, offset: anytype) ?u32 {
    const start = @min(@as(usize, @intCast(offset)), input.len);
    for (input[start..], start..) |byte, i| {
        if (byte == '\n' or byte == '\r' or byte >= 0x80) return @intCast(i);
    }
    return null;
}

pub const substring = @import("string/immutable.zig").substring;
pub const trimSuffixComptime = @import("string/immutable.zig").trimSuffixComptime;
pub const trimPrefixComptime = @import("string/immutable.zig").trimPrefixComptime;
pub const withoutPrefixComptime = @import("string/immutable.zig").withoutPrefixComptime;
pub const withoutPrefixComptimeZ = @import("string/immutable.zig").withoutPrefixComptimeZ;
pub const lastIndexBeforeChar = @import("string/immutable.zig").lastIndexBeforeChar;
pub const endsWithChar = @import("string/immutable.zig").endsWithChar;
pub const endsWithCharOrIsZeroLength = @import("string/immutable.zig").endsWithCharOrIsZeroLength;
pub const indexAnyComptime = @import("string/immutable.zig").indexAnyComptime;
pub const indexAnyComptimeT = @import("string/immutable.zig").indexAnyComptimeT;
pub const indexOfCharNeg = @import("string/immutable.zig").indexOfCharNeg;
pub const withoutLeadingPathSeparator = @import("string/immutable.zig").withoutLeadingPathSeparator;
pub const isNPMPackageName = @import("string/immutable.zig").isNPMPackageName;
pub const isNPMPackageNameIgnoreLength = @import("string/immutable.zig").isNPMPackageNameIgnoreLength;
pub const endsWithAnyComptime = @import("string/immutable.zig").endsWithAnyComptime;
// Comparator factories for `std.sort.*`. `NewLengthSorter` orders by raw
// field length; `NewGlobLengthSorter` orders glob `exports`/`imports` keys by
// their pre-`*` base length (then full length), matching the Node module
// resolution `PATTERN_KEY_COMPARE`. The resolver cone spells the latter as
// `strings.NewGlobLengthSorter(Entry.Data.Map.MapEntry, "key")`
// (`resolver/package_json.zig`).
pub const NewLengthSorter = @import("string/immutable.zig").NewLengthSorter;
pub const NewGlobLengthSorter = @import("string/immutable.zig").NewGlobLengthSorter;

pub fn indexOfChar(slice: []const u8, char: u8) ?usize {
    return std.mem.indexOfScalar(u8, slice, char);
}

pub fn indexOfCharZ(slice: [:0]const u8, char: u8) ?usize {
    return std.mem.indexOfScalar(u8, slice, char);
}

pub fn lastIndexOfChar(slice: []const u8, char: u8) ?usize {
    return std.mem.lastIndexOfScalar(u8, slice, char);
}

pub fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    // Match upstream bun.strings.indexOf (string/immutable.zig): an empty
    // needle is "not found" (null), NOT index 0 like std.mem.indexOf returns.
    // Several call sites rely on this (e.g. expect().toContainEqual("")).
    if (needle.len == 0) return null;
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

pub fn trimRight(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    var end = slice.len;
    while (end > 0 and std.mem.indexOfScalar(T, values_to_strip, slice[end - 1]) != null) {
        end -= 1;
    }
    return slice[0..end];
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

/// Case-SENSITIVE byte equality. Upstream `eqlComptimeIgnoreLen` is
/// `eqlComptimeCheckLenWithType(u8, self, alt, false)` — the "ignore len" only
/// means it skips a redundant length recheck, NOT that it folds case. An earlier
/// Home copy folded case here, which silently made every `ComptimeStringMap.fromJS`
/// lookup (and `ZigString.eqlComptime`) case-insensitive — e.g. `Bun.color(x,"hex")`
/// resolving to the `HEX` (uppercase) format, and TOML `TRUE` parsing as `true`.
/// The case-insensitive map paths (`getCaseInsensitiveWithEql`) lowercase their
/// input before calling this against lowercase keys, so they still work.
pub fn eqlComptimeIgnoreLen(a: anytype, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (b, 0..) |c, i| {
        if (a[i] != c) return false;
    }
    return true;
}

/// Faithful port of upstream `BOM` (`src/bun_core/string/immutable/unicode.zig`
/// line 978). Byte-order-mark detection + stripping used by the resolver's
/// file reader. Home uses `std.mem` copy primitives in place of upstream's
/// `bun.c.memmove` and keeps the same "only utf8/utf16_le actually convert"
/// behavior.
pub const BOM = enum {
    utf8,
    utf16_le,
    utf16_be,
    utf32_le,
    utf32_be,

    pub const utf8_bytes = [_]u8{ 0xef, 0xbb, 0xbf };
    pub const utf16_le_bytes = [_]u8{ 0xff, 0xfe };
    pub const utf16_be_bytes = [_]u8{ 0xfe, 0xff };
    pub const utf32_le_bytes = [_]u8{ 0xff, 0xfe, 0x00, 0x00 };
    pub const utf32_be_bytes = [_]u8{ 0x00, 0x00, 0xfe, 0xff };

    pub fn detect(bytes: []const u8) ?BOM {
        if (bytes.len < 3) return null;
        if (std.mem.startsWith(u8, bytes, &utf8_bytes)) return .utf8;
        if (std.mem.startsWith(u8, bytes, &utf16_le_bytes)) return .utf16_le;
        return null;
    }

    /// Faithful to upstream `unicode.zig:1004`.
    pub fn detectAndSplit(bytes: []const u8) struct { ?BOM, []const u8 } {
        const bom = detect(bytes);
        if (bom == null) return .{ null, bytes };
        return .{ bom, bytes[bom.?.length()..] };
    }

    pub fn getHeader(bom: BOM) []const u8 {
        return switch (bom) {
            inline else => |t| comptime &@field(BOM, @tagName(t) ++ "_bytes"),
        };
    }

    pub fn length(bom: BOM) usize {
        return switch (bom) {
            inline else => |t| comptime (&@field(BOM, @tagName(t) ++ "_bytes")).len,
        };
    }

    /// If an allocation is needed, free the input and the caller will
    /// replace it with the new return.
    pub fn removeAndConvertToUTF8AndFree(bom: BOM, allocator: std.mem.Allocator, bytes: []u8) std.mem.Allocator.Error![]u8 {
        switch (bom) {
            .utf8 => {
                std.mem.copyForwards(u8, bytes[0 .. bytes.len - utf8_bytes.len], bytes[utf8_bytes.len..]);
                return bytes[0 .. bytes.len - utf8_bytes.len];
            },
            .utf16_le => {
                const trimmed_bytes = bytes[utf16_le_bytes.len..];
                const trimmed_bytes_u16: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, trimmed_bytes));
                const out = try toUTF8Alloc(allocator, trimmed_bytes_u16);
                allocator.free(bytes);
                return out;
            },
            else => {
                const bom_bytes = bom.getHeader();
                std.mem.copyForwards(u8, bytes[0 .. bytes.len - bom_bytes.len], bytes[bom_bytes.len..]);
                return bytes[0 .. bytes.len - bom_bytes.len];
            },
        }
    }

    /// Required for fs.zig's `use_shared_buffer` flag; cannot free the input.
    /// The returned slice always points to the base of the input.
    pub fn removeAndConvertToUTF8WithoutDealloc(bom: BOM, allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8)) ![]u8 {
        const bytes = list.items;
        switch (bom) {
            .utf8 => {
                std.mem.copyForwards(u8, bytes[0 .. bytes.len - utf8_bytes.len], bytes[utf8_bytes.len..]);
                return bytes[0 .. bytes.len - utf8_bytes.len];
            },
            .utf16_le => {
                const trimmed_bytes = bytes[utf16_le_bytes.len..];
                const trimmed_bytes_u16: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, trimmed_bytes));
                const out = try toUTF8Alloc(allocator, trimmed_bytes_u16);
                if (list.capacity < out.len) {
                    try list.ensureTotalCapacity(allocator, out.len);
                }
                list.items.len = out.len;
                @memcpy(list.items, out);
                return out;
            },
            else => {
                const bom_bytes = bom.getHeader();
                std.mem.copyForwards(u8, bytes[0 .. bytes.len - bom_bytes.len], bytes[bom_bytes.len..]);
                return bytes[0 .. bytes.len - bom_bytes.len];
            },
        }
    }
};

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

test "cloneNormalizingSeparators appends a trailing separator" {
    const a = std.testing.allocator;
    // Absolute path: leading sep preserved, single trailing sep appended.
    {
        const out = try cloneNormalizingSeparators(a, "/foo/bar");
        defer a.free(out);
        try std.testing.expectEqualStrings("/foo/bar/", out);
    }
    // Already-trailing-slash input: stays single (no double slash).
    {
        const out = try cloneNormalizingSeparators(a, "/foo/bar/");
        defer a.free(out);
        try std.testing.expectEqualStrings("/foo/bar/", out);
    }
    // Relative path (no leading sep) still gains a trailing sep.
    {
        const out = try cloneNormalizingSeparators(a, "foo/bar");
        defer a.free(out);
        try std.testing.expectEqualStrings("foo/bar/", out);
    }
    // Duplicate interior slashes collapse to one.
    {
        const out = try cloneNormalizingSeparators(a, "/foo//bar///baz");
        defer a.free(out);
        try std.testing.expectEqualStrings("/foo/bar/baz/", out);
    }
    // Single-segment path.
    {
        const out = try cloneNormalizingSeparators(a, "/tmp");
        defer a.free(out);
        try std.testing.expectEqualStrings("/tmp/", out);
    }
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

test "eqlComptimeIgnoreLen is case-sensitive (matches upstream byte compare)" {
    try std.testing.expect(eqlComptimeIgnoreLen("hello", "hello"));
    try std.testing.expect(!eqlComptimeIgnoreLen("HELLO", "hello"));
    try std.testing.expect(!eqlComptimeIgnoreLen("Hello", "hello"));
    try std.testing.expect(!eqlComptimeIgnoreLen("world", "hello"));
}

test "eqlCaseInsensitiveASCIIICheckLength requires matching length" {
    try std.testing.expect(eqlCaseInsensitiveASCIIICheckLength("BROWSER", "browser"));
    try std.testing.expect(!eqlCaseInsensitiveASCIIICheckLength("bun", "bunny"));
}

test "BOM.detect recognizes UTF-8 and UTF-16-LE markers" {
    try std.testing.expectEqual(@as(?BOM, .utf8), BOM.detect(&[_]u8{ 0xef, 0xbb, 0xbf, 'a' }));
    try std.testing.expectEqual(@as(?BOM, .utf16_le), BOM.detect(&[_]u8{ 0xff, 0xfe, 'a', 0 }));
    try std.testing.expectEqual(@as(?BOM, null), BOM.detect("hello"));
    // Fewer than 3 bytes can never carry a BOM.
    try std.testing.expectEqual(@as(?BOM, null), BOM.detect(&[_]u8{ 0xef, 0xbb }));
}

test "BOM length and getHeader match the marker bytes" {
    try std.testing.expectEqual(@as(usize, 3), BOM.length(.utf8));
    try std.testing.expectEqual(@as(usize, 2), BOM.length(.utf16_le));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xef, 0xbb, 0xbf }, BOM.getHeader(.utf8));
}

test "BOM.removeAndConvertToUTF8AndFree strips a UTF-8 marker in place" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, &[_]u8{ 0xef, 0xbb, 0xbf, 'h', 'i' });
    defer allocator.free(bytes);
    const out = try BOM.removeAndConvertToUTF8AndFree(.utf8, allocator, bytes);
    try std.testing.expectEqualStrings("hi", out);
}

test "BOM.removeAndConvertToUTF8WithoutDealloc keeps the base pointer for UTF-8" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, &[_]u8{ 0xef, 0xbb, 0xbf, 'o', 'k' });
    const base = list.items.ptr;
    const out = try BOM.removeAndConvertToUTF8WithoutDealloc(.utf8, allocator, &list);
    try std.testing.expectEqualStrings("ok", out);
    try std.testing.expectEqual(base, out.ptr);
}

// ---- NewLengthSorter / NewGlobLengthSorter ----------------------------
// Comparator factories used by `std.sort.*`. `lessThan(lhs, rhs)` is true
// when `lhs` is *more specific* than `rhs`, so a `pdq`/`sort` orders keys
// from most-specific to least-specific (Bun's `PATTERN_KEY_COMPARE`).
//
// The real factories instantiate against the native `string/immutable.zig`
// `indexOfChar`, which dispatches to the `highway` SIMD C entrypoint
// (`highway_index_of_char`). That C library is not linked into the pure-Zig
// `home_rt` test target, so calling `lessThan` here would fail to link. We
// therefore split coverage in two:
//
//   1. A comptime instantiation check that the exported generics type-check
//      against a `{ key }` entry and expose the `lessThan` comparator with
//      the expected signature — this exercises the re-export wiring.
//   2. A byte-identical mirror of the glob comparator (only swapping the
//      `highway`-backed `indexOfChar` for `std.mem.indexOfScalar`) so the
//      ordering semantics are pinned with executable assertions.

const GlobKeyTestEntry = struct { key: []const u8 };

// Mirror of `NewGlobLengthSorter(GlobKeyTestEntry, "key").lessThan` using the
// std `indexOfChar` so it can run without linking the highway C lib. Kept
// line-for-line aligned with `string/immutable.zig`'s `NewGlobLengthSorter`.
fn globLessThanMirror(lhs: GlobKeyTestEntry, rhs: GlobKeyTestEntry) bool {
    const key_a = lhs.key;
    const key_b = rhs.key;
    const star_a = std.mem.indexOfScalar(u8, key_a, '*');
    const star_b = std.mem.indexOfScalar(u8, key_b, '*');
    const base_length_a = star_a orelse key_a.len;
    const base_length_b = star_b orelse key_b.len;
    if (base_length_a > base_length_b) return true;
    if (base_length_b > base_length_a) return false;
    if (star_a == null) return false;
    if (star_b == null) return true;
    if (key_a.len > key_b.len) return true;
    if (key_b.len > key_a.len) return false;
    return false;
}

test "NewLengthSorter / NewGlobLengthSorter export + instantiate" {
    // Re-export wiring: the generics resolve and expose `lessThan` with the
    // upstream `fn (Sorter, T, T) bool` signature. Evaluated at comptime so we
    // never emit a runtime call into the unlinked highway entrypoint.
    comptime {
        const LenSorter = NewLengthSorter(GlobKeyTestEntry, "key");
        const GlobSorter = NewGlobLengthSorter(GlobKeyTestEntry, "key");
        const LenFn = @TypeOf(LenSorter.lessThan);
        const GlobFn = @TypeOf(GlobSorter.lessThan);
        std.debug.assert(@typeInfo(LenFn).@"fn".return_type.? == bool);
        std.debug.assert(@typeInfo(GlobFn).@"fn".return_type.? == bool);
        std.debug.assert(@typeInfo(LenFn).@"fn".params.len == 3);
        std.debug.assert(@typeInfo(GlobFn).@"fn".params.len == 3);
    }
}

test "glob sorter: longer pre-star base length is more specific" {
    // base length = chars before '*'. "./foo/*" (base 6) is more specific
    // than "./*" (base 2), so it sorts first (lessThan == true).
    try std.testing.expect(globLessThanMirror(.{ .key = "./foo/*" }, .{ .key = "./*" }));
    try std.testing.expect(!globLessThanMirror(.{ .key = "./*" }, .{ .key = "./foo/*" }));
}

test "glob sorter: a literal key (no star) loses the base-length tie to a glob" {
    // Upstream: when keyA has no '*' it returns "1" (sorts after) -> false;
    // when keyB has no '*' the glob keyA sorts before -> true.
    try std.testing.expect(!globLessThanMirror(.{ .key = "./foo" }, .{ .key = "./foo*" }));
    try std.testing.expect(globLessThanMirror(.{ .key = "./foo*" }, .{ .key = "./foo" }));
}

test "glob sorter: equal base length, both globs, longer total wins" {
    // Both base length 6 ("./foo/"). The longer total "./foo/*.js" is more
    // specific than "./foo/*", so it sorts first.
    try std.testing.expect(globLessThanMirror(.{ .key = "./foo/*.js" }, .{ .key = "./foo/*" }));
    try std.testing.expect(!globLessThanMirror(.{ .key = "./foo/*" }, .{ .key = "./foo/*.js" }));
}

test "glob sorter: identical keys are not strictly less" {
    try std.testing.expect(!globLessThanMirror(.{ .key = "./foo/*" }, .{ .key = "./foo/*" }));
}

test "glob sorter: pdq sort yields most-specific-first ordering" {
    var entries = [_]GlobKeyTestEntry{
        .{ .key = "./*" },
        .{ .key = "./foo/*.js" },
        .{ .key = "./foo/*" },
        .{ .key = "./foo/bar/*" },
    };
    std.sort.pdq(GlobKeyTestEntry, &entries, {}, struct {
        fn lt(_: void, a: GlobKeyTestEntry, b: GlobKeyTestEntry) bool {
            return globLessThanMirror(a, b);
        }
    }.lt);
    // Descending specificity: deepest base length first, then longer total.
    try std.testing.expectEqualStrings("./foo/bar/*", entries[0].key); // base 10
    try std.testing.expectEqualStrings("./foo/*.js", entries[1].key); // base 6, total 10
    try std.testing.expectEqualStrings("./foo/*", entries[2].key); // base 6, total 7
    try std.testing.expectEqualStrings("./*", entries[3].key); // base 2
}
