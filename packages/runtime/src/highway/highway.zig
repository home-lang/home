// Copied from bun/src/highway/highway.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten:
//   `@import("bun")`           → `@import("home")`
//   `bun.debugAssert`          → `home_rt.assert`   (same semantics: debug-only)
//   `bun.Environment.isDebug`  → `home_rt.Environment.isDebug`
//   The unused `bun.strings` alias was dropped (upstream imports it but
//   never references it in this file).
// Scalar Zig implementations of the `highway_*` C ABI symbols.
//
// Upstream Bun links a vendored Google Highway (SIMD) C++ object
// (`src/jsc/bindings/highway_strings.cpp`) that provides these symbols.
// Home does not vendor that C++ object, so we provide faithful *scalar*
// reimplementations here. Each routine matches the byte-exact semantics of
// the corresponding `*Impl` scalar tail loop in the upstream C++ — i.e. the
// "interesting"/"needs-escape" character set, the return convention (the
// first matching index, or `len` when nothing matches), and the in/out
// behaviour. They are `export fn` so the C ABI symbol name is preserved for
// any caller that links against `highway_*` directly; the wrappers below
// call them in-process.
//
// Correctness over speed: a straightforward byte loop is sufficient. The
// `noalias` qualifiers from upstream are dropped because they only matter
// for the SIMD codegen and are not part of the observable contract.

/// Count frequencies of [a-zA-Z0-9_$] characters, adding `delta` per match
/// into a 64-entry table. Index layout: a-z → 0..25, A-Z → 26..51,
/// 0-9 → 52..61, '_' → 62, '$' → 63. Mirrors `ScanCharFrequencyImpl`.
pub fn highway_char_frequency(
    text: [*]const u8,
    text_len: usize,
    freqs: [*]i32,
    delta: i32,
) callconv(.c) void {
    if (text_len == 0 or delta == 0) return;
    var i: usize = 0;
    while (i < text_len) : (i += 1) {
        const c = text[i];
        if (c >= 'a' and c <= 'z') {
            freqs[c - 'a'] += delta;
        } else if (c >= 'A' and c <= 'Z') {
            freqs[c - 'A' + 26] += delta;
        } else if (c >= '0' and c <= '9') {
            freqs[c - '0' + 52] += delta;
        } else if (c == '_') {
            freqs[62] += delta;
        } else if (c == '$') {
            freqs[63] += delta;
        }
    }
}

/// Index of the first byte equal to `needle`, or `haystack_len` if absent.
/// Mirrors `IndexOfCharImpl`.
pub fn highway_index_of_char(
    haystack: [*]const u8,
    haystack_len: usize,
    needle: u8,
) callconv(.c) usize {
    var i: usize = 0;
    while (i < haystack_len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }
    return haystack_len;
}

/// Index of the first "interesting" byte inside a string literal:
/// the closing `quote`, a backslash, or any byte outside printable ASCII
/// (`< 0x20` or `> 0x7E`). Returns `text_len` if none. Mirrors
/// `IndexOfInterestingCharacterInStringLiteralImpl`.
pub fn highway_index_of_interesting_character_in_string_literal(
    text: [*]const u8,
    text_len: usize,
    quote: u8,
) callconv(.c) usize {
    var i: usize = 0;
    while (i < text_len) : (i += 1) {
        const c = text[i];
        if (c == quote or c == '\\' or c < 0x20 or c > 0x7E) return i;
    }
    return text_len;
}

/// Index of the first newline or non-ASCII byte (`< 0x20` or `> 127`).
/// Returns `haystack_len` if none. Mirrors `IndexOfNewlineOrNonASCIIImpl`.
pub fn highway_index_of_newline_or_non_ascii(
    haystack: [*]const u8,
    haystack_len: usize,
) callconv(.c) usize {
    var i: usize = 0;
    while (i < haystack_len) : (i += 1) {
        const c = haystack[i];
        if (c > 127 or c < 0x20) return i;
    }
    return haystack_len;
}

/// Same interesting set as `highway_index_of_newline_or_non_ascii`.
/// Upstream aliases `indexOfNewlineOrNonASCIIOrANSI` to
/// `indexOfNewlineOrNonASCII` (see Bun `src/string/immutable.zig`), so this
/// scan uses identical semantics: first byte `< 0x20` or `> 127`.
pub fn highway_index_of_newline_or_non_ascii_or_ansi(
    haystack: [*]const u8,
    haystack_len: usize,
) callconv(.c) usize {
    var i: usize = 0;
    while (i < haystack_len) : (i += 1) {
        const c = haystack[i];
        if (c > 127 or c < 0x20) return i;
    }
    return haystack_len;
}

/// Index of the first `#`, `@`, newline, or non-ASCII byte
/// (`< 0x20` or `> 127`). Returns `haystack_len` if none. Mirrors
/// `IndexOfNewlineOrNonASCIIOrHashOrAtImpl`.
pub fn highway_index_of_newline_or_non_ascii_or_hash_or_at(
    haystack: [*]const u8,
    haystack_len: usize,
) callconv(.c) usize {
    var i: usize = 0;
    while (i < haystack_len) : (i += 1) {
        const c = haystack[i];
        if (c == '#' or c == '@' or c < 0x20 or c > 127) return i;
    }
    return haystack_len;
}

/// Index of the first space-or-below byte (`<= ' '`) or non-ASCII byte
/// (`> 127`). Returns `haystack_len` if none. Mirrors
/// `IndexOfSpaceOrNewlineOrNonASCIIImpl`.
pub fn highway_index_of_space_or_newline_or_non_ascii(
    haystack: [*]const u8,
    haystack_len: usize,
) callconv(.c) usize {
    var i: usize = 0;
    while (i < haystack_len) : (i += 1) {
        const c = haystack[i];
        if (c <= ' ' or c > 127) return i;
    }
    return haystack_len;
}

/// True if the text contains any newline/control byte (`< 0x20`),
/// non-ASCII byte (`> 127`), or a double-quote (`"`). Mirrors
/// `ContainsNewlineOrNonASCIIOrQuoteImpl`.
pub fn highway_contains_newline_or_non_ascii_or_quote(
    text: [*]const u8,
    text_len: usize,
) callconv(.c) bool {
    var i: usize = 0;
    while (i < text_len) : (i += 1) {
        const c = text[i];
        if (c > 127 or c < 0x20 or c == '"') return true;
    }
    return false;
}

/// Index of the first byte that needs escaping in a JavaScript string:
/// `>= 127`, `< 0x20`, backslash, the `quote_char`, and — when `quote_char`
/// is a backtick — also `$`. Returns `text_len` if none. Mirrors
/// `IndexOfNeedsEscapeForJavaScriptStringImpl<is_backtick>` with the
/// `is_backtick` branch selected by `quote_char == '`'`.
pub fn highway_index_of_needs_escape_for_javascript_string(
    text: [*]const u8,
    text_len: usize,
    quote_char: u8,
) callconv(.c) usize {
    const is_backtick = quote_char == '`';
    var i: usize = 0;
    while (i < text_len) : (i += 1) {
        const c = text[i];
        if (c >= 127 or c < 0x20 or c == '\\' or c == quote_char or (is_backtick and c == '$')) return i;
    }
    return text_len;
}

/// Index of the first byte in `text` equal to any byte in `chars`.
/// Returns `text_len` if none. Mirrors `IndexOfAnyCharImpl`.
pub fn highway_index_of_any_char(
    text: [*]const u8,
    text_len: usize,
    chars: [*]const u8,
    chars_len: usize,
) callconv(.c) usize {
    if (text_len == 0) return 0;
    var i: usize = 0;
    while (i < text_len) : (i += 1) {
        const c = text[i];
        var j: usize = 0;
        while (j < chars_len) : (j += 1) {
            if (c == chars[j]) return i;
        }
    }
    return text_len;
}

/// Apply a 4-byte WebSocket mask (XOR) to `input`, writing to `output`.
/// When `skip_mask` is set the input is copied verbatim. Mirrors
/// `FillWithSkipMaskImpl`.
pub fn highway_fill_with_skip_mask(
    mask: [*]const u8,
    mask_len: usize,
    output: [*]u8,
    input: [*]const u8,
    length: usize,
    skip_mask: bool,
) callconv(.c) void {
    home_rt.assert(mask_len == 4);
    if (length == 0) return;
    if (skip_mask) {
        @memcpy(output[0..length], input[0..length]);
        return;
    }
    var i: usize = 0;
    while (i < length) : (i += 1) {
        output[i] = input[i] ^ mask[i % 4];
    }
}

/// Count frequencies of [a-zA-Z0-9_$] characters in a string
/// Updates the provided frequency array with counts (adds delta for each occurrence)
pub fn scanCharFrequency(text: string, freqs: *[64]i32, delta: i32) void {
    if (text.len == 0 or delta == 0) {
        return;
    }

    highway_char_frequency(
        text.ptr,
        text.len,
        freqs.ptr,
        delta,
    );
}

pub fn indexOfChar(haystack: string, needle: u8) ?usize {
    if (haystack.len == 0) {
        return null;
    }

    const result = highway_index_of_char(
        haystack.ptr,
        haystack.len,
        needle,
    );

    if (result == haystack.len) {
        return null;
    }

    home_rt.assert(haystack[result] == needle);

    return result;
}

pub fn indexOfInterestingCharacterInStringLiteral(slice: string, quote_type: u8) ?usize {
    if (slice.len == 0) {
        return null;
    }

    const result = highway_index_of_interesting_character_in_string_literal(
        slice.ptr,
        slice.len,
        quote_type,
    );

    if (result == slice.len) {
        return null;
    }

    return result;
}

pub fn indexOfNewlineOrNonASCII(haystack: string) ?usize {
    home_rt.assert(haystack.len > 0);

    const result = highway_index_of_newline_or_non_ascii(
        haystack.ptr,
        haystack.len,
    );

    if (result == haystack.len) {
        return null;
    }
    if (comptime Environment.isDebug) {
        const haystack_char = haystack[result];
        if (!(haystack_char > 127 or haystack_char < 0x20 or haystack_char == '\r' or haystack_char == '\n')) {
            @panic("Invalid character found in indexOfNewlineOrNonASCII");
        }
    }

    return result;
}

pub fn indexOfNewlineOrNonASCIIOrANSI(haystack: string) ?usize {
    home_rt.assert(haystack.len > 0);

    const result = highway_index_of_newline_or_non_ascii_or_ansi(
        haystack.ptr,
        haystack.len,
    );

    if (result == haystack.len) {
        return null;
    }
    if (comptime Environment.isDebug) {
        const haystack_char = haystack[result];
        if (!(haystack_char > 127 or haystack_char < 0x20 or haystack_char == '\r' or haystack_char == '\n')) {
            @panic("Invalid character found in indexOfNewlineOrNonASCIIOrANSI");
        }
    }

    return result;
}

/// Checks if the string contains any newlines, non-ASCII characters, or quotes
pub fn containsNewlineOrNonASCIIOrQuote(text: string) bool {
    if (text.len == 0) {
        return false;
    }

    return highway_contains_newline_or_non_ascii_or_quote(
        text.ptr,
        text.len,
    );
}

/// Finds the first character that needs escaping in a JavaScript string
/// Looks for characters above ASCII (> 127), control characters (< 0x20),
/// backslash characters (`\`), the quote character itself, and for backtick
/// strings also the dollar sign (`$`)
pub fn indexOfNeedsEscapeForJavaScriptString(slice: string, quote_char: u8) ?u32 {
    if (slice.len == 0) {
        return null;
    }

    const result = highway_index_of_needs_escape_for_javascript_string(
        slice.ptr,
        slice.len,
        quote_char,
    );

    if (result == slice.len) {
        return null;
    }

    if (comptime Environment.isDebug) {
        const haystack_char = slice[result];
        if (!(haystack_char >= 127 or haystack_char < 0x20 or haystack_char == '\\' or haystack_char == quote_char or haystack_char == '$' or haystack_char == '\r' or haystack_char == '\n')) {
            std.debug.panic("Invalid character found in indexOfNeedsEscapeForJavaScriptString: U+{x}. Full string: \"{f}\"", .{ haystack_char, std.zig.fmtString(slice) });
        }
    }

    return @truncate(result);
}

pub fn indexOfAnyChar(haystack: string, chars: string) ?usize {
    if (haystack.len == 0 or chars.len == 0) {
        return null;
    }

    const result = highway_index_of_any_char(haystack.ptr, haystack.len, chars.ptr, chars.len);

    if (result == haystack.len) {
        return null;
    }

    if (comptime Environment.isDebug) {
        const haystack_char = haystack[result];
        var found = false;
        for (chars) |c| {
            if (c == haystack_char) {
                found = true;
                break;
            }
        }
        if (!found) {
            @panic("Invalid character found in indexOfAnyChar");
        }
    }

    return result;
}

/// Truncate each u16 to a u8 (low byte) into `output`. Mirrors
/// `CopyU16ToU8Impl` (the scalar `output[i] = (u8)input[i]` body).
pub fn highway_copy_u16_to_u8(
    input: [*]align(1) const u16,
    count: usize,
    output: [*]u8,
) callconv(.c) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        output[i] = @truncate(input[i]);
    }
}

comptime {
    @export(&highway_char_frequency, .{ .name = "highway_char_frequency", .linkage = .weak });
    @export(&highway_index_of_char, .{ .name = "highway_index_of_char", .linkage = .weak });
    @export(&highway_index_of_interesting_character_in_string_literal, .{ .name = "highway_index_of_interesting_character_in_string_literal", .linkage = .weak });
    @export(&highway_index_of_newline_or_non_ascii, .{ .name = "highway_index_of_newline_or_non_ascii", .linkage = .weak });
    @export(&highway_index_of_newline_or_non_ascii_or_ansi, .{ .name = "highway_index_of_newline_or_non_ascii_or_ansi", .linkage = .weak });
    @export(&highway_index_of_newline_or_non_ascii_or_hash_or_at, .{ .name = "highway_index_of_newline_or_non_ascii_or_hash_or_at", .linkage = .weak });
    @export(&highway_index_of_space_or_newline_or_non_ascii, .{ .name = "highway_index_of_space_or_newline_or_non_ascii", .linkage = .weak });
    @export(&highway_contains_newline_or_non_ascii_or_quote, .{ .name = "highway_contains_newline_or_non_ascii_or_quote", .linkage = .weak });
    @export(&highway_index_of_needs_escape_for_javascript_string, .{ .name = "highway_index_of_needs_escape_for_javascript_string", .linkage = .weak });
    @export(&highway_index_of_any_char, .{ .name = "highway_index_of_any_char", .linkage = .weak });
    @export(&highway_fill_with_skip_mask, .{ .name = "highway_fill_with_skip_mask", .linkage = .weak });
    @export(&highway_copy_u16_to_u8, .{ .name = "highway_copy_u16_to_u8", .linkage = .weak });
}

pub fn copyU16ToU8(input: []align(1) const u16, output: []u8) void {
    highway_copy_u16_to_u8(input.ptr, input.len, output.ptr);
}

/// Apply a WebSocket mask to data using SIMD acceleration
/// If skip_mask is true, data is copied without masking
pub fn fillWithSkipMask(mask: [4]u8, output: []u8, input: []const u8, skip_mask: bool) void {
    if (input.len == 0) {
        return;
    }

    highway_fill_with_skip_mask(
        &mask,
        4,
        output.ptr,
        input.ptr,
        input.len,
        skip_mask,
    );
}

/// Useful for single-line JavaScript comments.
/// Scans for:
/// - `\n`, `\r`
/// - Non-ASCII characters (which implicitly include `\n`, `\r`)
/// - `#`
/// - `@`
pub fn indexOfNewlineOrNonASCIIOrHashOrAt(haystack: string) ?usize {
    if (haystack.len == 0) {
        return null;
    }

    const result = highway_index_of_newline_or_non_ascii_or_hash_or_at(
        haystack.ptr,
        haystack.len,
    );

    if (result == haystack.len) {
        return null;
    }

    return result;
}

/// Scans for:
/// - " "
/// - Non-ASCII characters (which implicitly include `\n`, `\r`, '\t')
pub fn indexOfSpaceOrNewlineOrNonASCII(haystack: string) ?usize {
    if (haystack.len == 0) {
        return null;
    }

    const result = highway_index_of_space_or_newline_or_non_ascii(
        haystack.ptr,
        haystack.len,
    );

    if (result == haystack.len) {
        return null;
    }

    return result;
}

const string = []const u8;

const std = @import("std");

const home_rt = @import("home");
const Environment = home_rt.Environment;

test "highway symbols and wrappers have well-formed type signatures" {
    // These were once `extern "c"` linker stubs for a vendored Google
    // Highway SIMD object. They are now scalar Zig `export fn`s, so they can
    // be invoked directly (see the functional tests below); this test just
    // pins the Zig-side signatures.
    _ = @typeName(@TypeOf(highway_char_frequency));
    _ = @typeName(@TypeOf(highway_index_of_char));
    _ = @typeName(@TypeOf(highway_index_of_interesting_character_in_string_literal));
    _ = @typeName(@TypeOf(highway_index_of_newline_or_non_ascii));
    _ = @typeName(@TypeOf(highway_index_of_newline_or_non_ascii_or_ansi));
    _ = @typeName(@TypeOf(highway_index_of_newline_or_non_ascii_or_hash_or_at));
    _ = @typeName(@TypeOf(highway_index_of_space_or_newline_or_non_ascii));
    _ = @typeName(@TypeOf(highway_contains_newline_or_non_ascii_or_quote));
    _ = @typeName(@TypeOf(highway_index_of_needs_escape_for_javascript_string));
    _ = @typeName(@TypeOf(highway_index_of_any_char));
    _ = @typeName(@TypeOf(highway_fill_with_skip_mask));
    _ = @typeName(@TypeOf(highway_copy_u16_to_u8));

    _ = @typeName(@TypeOf(scanCharFrequency));
    _ = @typeName(@TypeOf(indexOfChar));
    _ = @typeName(@TypeOf(indexOfInterestingCharacterInStringLiteral));
    _ = @typeName(@TypeOf(indexOfNewlineOrNonASCII));
    _ = @typeName(@TypeOf(indexOfNewlineOrNonASCIIOrANSI));
    _ = @typeName(@TypeOf(containsNewlineOrNonASCIIOrQuote));
    _ = @typeName(@TypeOf(indexOfNeedsEscapeForJavaScriptString));
    _ = @typeName(@TypeOf(indexOfAnyChar));
    _ = @typeName(@TypeOf(copyU16ToU8));
    _ = @typeName(@TypeOf(fillWithSkipMask));
    _ = @typeName(@TypeOf(indexOfNewlineOrNonASCIIOrHashOrAt));
    _ = @typeName(@TypeOf(indexOfSpaceOrNewlineOrNonASCII));
}

const testing = std.testing;

test "indexOfChar finds first match or returns null" {
    try testing.expectEqual(@as(?usize, 3), indexOfChar("abcde", 'd'));
    try testing.expectEqual(@as(?usize, 0), indexOfChar("xyz", 'x'));
    try testing.expectEqual(@as(?usize, null), indexOfChar("abc", 'z'));
    // Empty haystack short-circuits in the wrapper.
    try testing.expectEqual(@as(?usize, null), indexOfChar("", 'a'));
    // Returns the *first* of multiple matches.
    try testing.expectEqual(@as(?usize, 1), indexOfChar("aXaXa", 'X'));
}

test "indexOfInterestingCharacterInStringLiteral matches quote, backslash, and non-printable" {
    // Plain printable text: nothing interesting.
    try testing.expectEqual(@as(?usize, null), indexOfInterestingCharacterInStringLiteral("hello world", '"'));
    // The closing quote.
    try testing.expectEqual(@as(?usize, 5), indexOfInterestingCharacterInStringLiteral("hello\"x", '"'));
    // A different quote char is honoured.
    try testing.expectEqual(@as(?usize, 2), indexOfInterestingCharacterInStringLiteral("ab'cd", '\''));
    // Backslash is always interesting.
    try testing.expectEqual(@as(?usize, 3), indexOfInterestingCharacterInStringLiteral("abc\\d", '"'));
    // Below 0x20 (newline).
    try testing.expectEqual(@as(?usize, 1), indexOfInterestingCharacterInStringLiteral("a\nb", '"'));
    // Above 0x7E (non-ASCII byte).
    try testing.expectEqual(@as(?usize, 1), indexOfInterestingCharacterInStringLiteral("a\xC3b", '"'));
    // 0x7E ('~') itself is the boundary: still printable, not interesting.
    try testing.expectEqual(@as(?usize, null), indexOfInterestingCharacterInStringLiteral("a~b", '"'));
}

test "indexOfNewlineOrNonASCII matches control and high bytes" {
    try testing.expectEqual(@as(?usize, null), indexOfNewlineOrNonASCII("plain ascii"));
    try testing.expectEqual(@as(?usize, 1), indexOfNewlineOrNonASCII("a\nb"));
    try testing.expectEqual(@as(?usize, 1), indexOfNewlineOrNonASCII("a\rb"));
    try testing.expectEqual(@as(?usize, 2), indexOfNewlineOrNonASCII("ab\x80"));
    // Space (0x20) is the boundary and is NOT interesting here.
    try testing.expectEqual(@as(?usize, null), indexOfNewlineOrNonASCII("a b c"));
}

test "indexOfNewlineOrNonASCIIOrANSI aliases the plain newline/non-ascii scan" {
    const samples = [_]string{ "plain ascii", "a\nb", "a\x80b", "a b c", "~~~~" };
    for (samples) |s| {
        try testing.expectEqual(indexOfNewlineOrNonASCII(s), indexOfNewlineOrNonASCIIOrANSI(s));
    }
}

test "indexOfNewlineOrNonASCIIOrHashOrAt matches hash, at, control, and high bytes" {
    try testing.expectEqual(@as(?usize, null), indexOfNewlineOrNonASCIIOrHashOrAt("plain comment"));
    try testing.expectEqual(@as(?usize, 5), indexOfNewlineOrNonASCIIOrHashOrAt("hello#world"));
    try testing.expectEqual(@as(?usize, 3), indexOfNewlineOrNonASCIIOrHashOrAt("abc@d"));
    try testing.expectEqual(@as(?usize, 2), indexOfNewlineOrNonASCIIOrHashOrAt("ab\nc"));
    try testing.expectEqual(@as(?usize, 1), indexOfNewlineOrNonASCIIOrHashOrAt("a\xFFb"));
    // Earliest of multiple candidates wins.
    try testing.expectEqual(@as(?usize, 1), indexOfNewlineOrNonASCIIOrHashOrAt("a@#b"));
}

test "indexOfSpaceOrNewlineOrNonASCII treats <= space and high bytes as interesting" {
    try testing.expectEqual(@as(?usize, null), indexOfSpaceOrNewlineOrNonASCII("nospace"));
    try testing.expectEqual(@as(?usize, 5), indexOfSpaceOrNewlineOrNonASCII("hello world"));
    // Tab (0x09) is <= ' '.
    try testing.expectEqual(@as(?usize, 1), indexOfSpaceOrNewlineOrNonASCII("a\tb"));
    try testing.expectEqual(@as(?usize, 2), indexOfSpaceOrNewlineOrNonASCII("ab\x90"));
    // '!' (0x21) is just above space and is NOT interesting.
    try testing.expectEqual(@as(?usize, null), indexOfSpaceOrNewlineOrNonASCII("a!b"));
}

test "containsNewlineOrNonASCIIOrQuote detects control, high byte, and double-quote" {
    try testing.expect(!containsNewlineOrNonASCIIOrQuote("plain ascii"));
    try testing.expect(containsNewlineOrNonASCIIOrQuote("has\"quote"));
    try testing.expect(containsNewlineOrNonASCIIOrQuote("line\nbreak"));
    try testing.expect(containsNewlineOrNonASCIIOrQuote("hi\xC3"));
    // Single quote is not in the interesting set here.
    try testing.expect(!containsNewlineOrNonASCIIOrQuote("it's fine"));
    // Empty short-circuits to false in the wrapper.
    try testing.expect(!containsNewlineOrNonASCIIOrQuote(""));
}

test "indexOfNeedsEscapeForJavaScriptString matches escapes for double quote" {
    try testing.expectEqual(@as(?u32, null), indexOfNeedsEscapeForJavaScriptString("plain", '"'));
    try testing.expectEqual(@as(?u32, 2), indexOfNeedsEscapeForJavaScriptString("ab\"c", '"'));
    try testing.expectEqual(@as(?u32, 1), indexOfNeedsEscapeForJavaScriptString("a\\b", '"'));
    // 0x7F (DEL) is >= 127 and needs escaping.
    try testing.expectEqual(@as(?u32, 1), indexOfNeedsEscapeForJavaScriptString("a\x7Fb", '"'));
    // For a non-backtick quote, '$' is fine.
    try testing.expectEqual(@as(?u32, null), indexOfNeedsEscapeForJavaScriptString("a$b", '"'));
}

test "indexOfNeedsEscapeForJavaScriptString escapes dollar only for backtick" {
    // Backtick quote: '$' must be escaped.
    try testing.expectEqual(@as(?u32, 1), indexOfNeedsEscapeForJavaScriptString("a$b", '`'));
    // The backtick itself is the quote char.
    try testing.expectEqual(@as(?u32, 2), indexOfNeedsEscapeForJavaScriptString("ab`c", '`'));
    // Plain backtick literal text with no specials.
    try testing.expectEqual(@as(?u32, null), indexOfNeedsEscapeForJavaScriptString("plain", '`'));
}

test "indexOfAnyChar finds the earliest byte present in the needle set" {
    try testing.expectEqual(@as(?usize, 3), indexOfAnyChar("abc\rdef", "\r\n"));
    try testing.expectEqual(@as(?usize, 0), indexOfAnyChar("/path", "\\/"));
    try testing.expectEqual(@as(?usize, null), indexOfAnyChar("abcdef", "xyz"));
    // Empty inputs short-circuit in the wrapper.
    try testing.expectEqual(@as(?usize, null), indexOfAnyChar("", "ab"));
    try testing.expectEqual(@as(?usize, null), indexOfAnyChar("abc", ""));
}

test "scanCharFrequency tallies [a-zA-Z0-9_$] with delta and index layout" {
    var freqs: [64]i32 = @splat(0);
    scanCharFrequency("aA0_$ .!", &freqs, 1);
    try testing.expectEqual(@as(i32, 1), freqs[0]); // 'a'
    try testing.expectEqual(@as(i32, 1), freqs[26]); // 'A'
    try testing.expectEqual(@as(i32, 1), freqs[52]); // '0'
    try testing.expectEqual(@as(i32, 1), freqs[62]); // '_'
    try testing.expectEqual(@as(i32, 1), freqs[63]); // '$'
    // Repeated chars accumulate; delta can subtract.
    scanCharFrequency("aaa", &freqs, 2);
    try testing.expectEqual(@as(i32, 7), freqs[0]);
    scanCharFrequency("a", &freqs, -3);
    try testing.expectEqual(@as(i32, 4), freqs[0]);
    // delta == 0 is a no-op.
    scanCharFrequency("a", &freqs, 0);
    try testing.expectEqual(@as(i32, 4), freqs[0]);
}

test "copyU16ToU8 truncates each unit to its low byte" {
    const input = [_]u16{ 0x0041, 0x00FF, 0x1234, 0x0000 };
    var output: [4]u8 = @splat(0);
    copyU16ToU8(&input, &output);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0xFF, 0x34, 0x00 }, &output);
}

test "fillWithSkipMask XORs with the 4-byte mask or copies when skipping" {
    const mask = [4]u8{ 0x10, 0x20, 0x30, 0x40 };
    const input = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    var output: [5]u8 = @splat(0);
    fillWithSkipMask(mask, &output, &input, false);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x15 }, &output);

    var copy_out: [5]u8 = @splat(0);
    fillWithSkipMask(mask, &copy_out, &input, true);
    try testing.expectEqualSlices(u8, &input, &copy_out);
}
