// Copied from bun/src/runtime/webcore/EncodingLabel.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Rewritten imports: `@import("bun")` → `@import("home_rt")`,
// `bun.ComptimeStringMap` → `home_rt.ComptimeStringMap`.
// The upstream `string_map.getAnyCase(...)` (which used Bun's
// `ComptimeStringMap.getCaseInsensitiveWithEql`, not yet ported into
// the Home substrate) is replaced by a small stack-buffered lowercase
// + `string_map.get` call. Identical semantics: all alias keys are
// ASCII lowercase, so a lowercased lookup is exactly equivalent.
//
// The upstream `strings.trim(input, " \t\r\n\x0C")` call is inlined
// against a fixed 5-byte whitespace set — `home_rt.strings` does not
// yet expose a generic `trim`.
//
// `./encoding.zig` is JSC-heavy (consumes `jsc.JSValue`, `BunString`,
// `jsc.JSGlobalObject`) and is not ported here. The `pub const latin1`
// + `which()` surface is the only thing other ported files reach for,
// and both fit in this file without pulling encoding.zig along.

const std = @import("std");
const home_rt = @import("home_rt");
const strings = home_rt.strings;

/// https://encoding.spec.whatwg.org/encodings.json
pub const EncodingLabel = enum {
    @"UTF-8",
    IBM866,
    @"ISO-8859-3",
    @"ISO-8859-6",
    @"ISO-8859-7",
    @"ISO-8859-8",
    @"ISO-8859-8-I",
    @"KOI8-U",
    @"windows-874",
    /// Also known as
    /// - ASCII
    /// - latin1
    @"windows-1252",
    @"windows-1253",
    @"windows-1255",
    @"windows-1257",
    Big5,
    @"EUC-JP",
    @"ISO-2022-JP",
    Shift_JIS,
    @"EUC-KR",
    @"UTF-16BE",
    @"UTF-16LE",
    @"x-user-defined",
    replacement,
    GBK,
    GB18030,

    pub fn getLabel(this: EncodingLabel) []const u8 {
        return switch (this) {
            .@"UTF-8" => "utf-8",
            .@"UTF-16LE" => "utf-16le",
            .@"UTF-16BE" => "utf-16be",
            .@"windows-1252" => "windows-1252",
            .IBM866 => "ibm866",
            .@"ISO-8859-3" => "iso-8859-3",
            .@"ISO-8859-6" => "iso-8859-6",
            .@"ISO-8859-7" => "iso-8859-7",
            .@"ISO-8859-8" => "iso-8859-8",
            .@"ISO-8859-8-I" => "iso-8859-8-i",
            .@"KOI8-U" => "koi8-u",
            .@"windows-874" => "windows-874",
            .@"windows-1253" => "windows-1253",
            .@"windows-1255" => "windows-1255",
            .@"windows-1257" => "windows-1257",
            .Big5 => "big5",
            .@"EUC-JP" => "euc-jp",
            .@"ISO-2022-JP" => "iso-2022-jp",
            .Shift_JIS => "shift_jis",
            .@"EUC-KR" => "euc-kr",
            .@"x-user-defined" => "x-user-defined",
            .replacement => "replacement",
            .GBK => "gbk",
            .GB18030 => "gb18030",
        };
    }

    pub const latin1 = EncodingLabel.@"windows-1252";

    const string_map = home_rt.ComptimeStringMap(EncodingLabel, .{
        // Windows-1252 (Latin1) aliases
        .{ "l1", latin1 },
        .{ "ascii", latin1 },
        .{ "cp819", latin1 },
        .{ "cp1252", latin1 },
        .{ "ibm819", latin1 },
        .{ "latin1", latin1 },
        .{ "iso88591", latin1 },
        .{ "us-ascii", latin1 },
        .{ "x-cp1252", latin1 },
        .{ "iso8859-1", latin1 },
        .{ "iso_8859-1", latin1 },
        .{ "iso-8859-1", latin1 },
        .{ "iso-ir-100", latin1 },
        .{ "csisolatin1", latin1 },
        .{ "windows-1252", latin1 },
        .{ "ansi_x3.4-1968", latin1 },
        .{ "iso_8859-1:1987", latin1 },

        // UTF-16LE aliases
        .{ "ucs-2", .@"UTF-16LE" },
        .{ "utf-16", .@"UTF-16LE" },
        .{ "unicode", .@"UTF-16LE" },
        .{ "utf-16le", .@"UTF-16LE" },
        .{ "csunicode", .@"UTF-16LE" },
        .{ "unicodefeff", .@"UTF-16LE" },
        .{ "iso-10646-ucs-2", .@"UTF-16LE" },

        // UTF-16BE aliases
        .{ "utf-16be", .@"UTF-16BE" },

        // UTF-8 aliases
        .{ "utf8", .@"UTF-8" },
        .{ "utf-8", .@"UTF-8" },
        .{ "unicode11utf8", .@"UTF-8" },
        .{ "unicode20utf8", .@"UTF-8" },
        .{ "x-unicode20utf8", .@"UTF-8" },
        .{ "unicode-1-1-utf-8", .@"UTF-8" },

        // IBM866 aliases
        .{ "ibm866", .IBM866 },
        .{ "cp866", .IBM866 },
        .{ "866", .IBM866 },
        .{ "csibm866", .IBM866 },

        // ISO-8859-3 aliases
        .{ "iso-8859-3", .@"ISO-8859-3" },
        .{ "iso8859-3", .@"ISO-8859-3" },
        .{ "iso_8859-3", .@"ISO-8859-3" },
        .{ "latin3", .@"ISO-8859-3" },
        .{ "csisolatin3", .@"ISO-8859-3" },
        .{ "iso-ir-109", .@"ISO-8859-3" },
        .{ "l3", .@"ISO-8859-3" },

        // ISO-8859-6 aliases
        .{ "iso-8859-6", .@"ISO-8859-6" },
        .{ "iso8859-6", .@"ISO-8859-6" },
        .{ "iso_8859-6", .@"ISO-8859-6" },
        .{ "arabic", .@"ISO-8859-6" },
        .{ "csisolatinarabic", .@"ISO-8859-6" },
        .{ "iso-ir-127", .@"ISO-8859-6" },
        .{ "asmo-708", .@"ISO-8859-6" },
        .{ "ecma-114", .@"ISO-8859-6" },

        // ISO-8859-7 aliases
        .{ "iso-8859-7", .@"ISO-8859-7" },
        .{ "iso8859-7", .@"ISO-8859-7" },
        .{ "iso_8859-7", .@"ISO-8859-7" },
        .{ "greek", .@"ISO-8859-7" },
        .{ "greek8", .@"ISO-8859-7" },
        .{ "csisolatingreek", .@"ISO-8859-7" },
        .{ "iso-ir-126", .@"ISO-8859-7" },
        .{ "ecma-118", .@"ISO-8859-7" },
        .{ "elot_928", .@"ISO-8859-7" },

        // ISO-8859-8 aliases
        .{ "iso-8859-8", .@"ISO-8859-8" },
        .{ "iso8859-8", .@"ISO-8859-8" },
        .{ "iso_8859-8", .@"ISO-8859-8" },
        .{ "hebrew", .@"ISO-8859-8" },
        .{ "csisolatinhebrew", .@"ISO-8859-8" },
        .{ "iso-ir-138", .@"ISO-8859-8" },
        .{ "visual", .@"ISO-8859-8" },

        // ISO-8859-8-I aliases
        .{ "iso-8859-8-i", .@"ISO-8859-8-I" },
        .{ "logical", .@"ISO-8859-8-I" },
        .{ "csiso88598i", .@"ISO-8859-8-I" },

        // KOI8-U aliases
        .{ "koi8-u", .@"KOI8-U" },
        .{ "koi8-ru", .@"KOI8-U" },

        // Windows code pages
        .{ "windows-874", .@"windows-874" },
        .{ "dos-874", .@"windows-874" },
        .{ "iso-8859-11", .@"windows-874" },
        .{ "iso8859-11", .@"windows-874" },
        .{ "iso885911", .@"windows-874" },
        .{ "iso_8859-11", .@"windows-874" },
        .{ "tis-620", .@"windows-874" },

        .{ "windows-1253", .@"windows-1253" },
        .{ "cp1253", .@"windows-1253" },
        .{ "x-cp1253", .@"windows-1253" },

        .{ "windows-1255", .@"windows-1255" },
        .{ "cp1255", .@"windows-1255" },
        .{ "x-cp1255", .@"windows-1255" },

        .{ "windows-1257", .@"windows-1257" },
        .{ "cp1257", .@"windows-1257" },
        .{ "x-cp1257", .@"windows-1257" },

        // CJK encodings
        .{ "big5", .Big5 },
        .{ "big5-hkscs", .Big5 },
        .{ "cn-big5", .Big5 },
        .{ "csbig5", .Big5 },
        .{ "x-x-big5", .Big5 },

        .{ "euc-jp", .@"EUC-JP" },
        .{ "cseucpkdfmtjapanese", .@"EUC-JP" },
        .{ "x-euc-jp", .@"EUC-JP" },

        .{ "iso-2022-jp", .@"ISO-2022-JP" },
        .{ "csiso2022jp", .@"ISO-2022-JP" },

        .{ "shift_jis", .Shift_JIS },
        .{ "shift-jis", .Shift_JIS },
        .{ "sjis", .Shift_JIS },
        .{ "csshiftjis", .Shift_JIS },
        .{ "ms932", .Shift_JIS },
        .{ "ms_kanji", .Shift_JIS },
        .{ "windows-31j", .Shift_JIS },
        .{ "x-sjis", .Shift_JIS },

        .{ "euc-kr", .@"EUC-KR" },
        .{ "cseuckr", .@"EUC-KR" },
        .{ "csksc56011987", .@"EUC-KR" },
        .{ "iso-ir-149", .@"EUC-KR" },
        .{ "korean", .@"EUC-KR" },
        .{ "ks_c_5601-1987", .@"EUC-KR" },
        .{ "ks_c_5601-1989", .@"EUC-KR" },
        .{ "ksc5601", .@"EUC-KR" },
        .{ "ksc_5601", .@"EUC-KR" },
        .{ "windows-949", .@"EUC-KR" },

        // Chinese encodings
        .{ "gbk", .GBK },
        .{ "gb2312", .GBK },
        .{ "chinese", .GBK },
        .{ "csgb2312", .GBK },
        .{ "csiso58gb231280", .GBK },
        .{ "gb_2312", .GBK },
        .{ "gb_2312-80", .GBK },
        .{ "iso-ir-58", .GBK },
        .{ "x-gbk", .GBK },

        .{ "gb18030", .GB18030 },

        // Other
        .{ "x-user-defined", .@"x-user-defined" },
        .{ "replacement", .replacement },
    });

    /// Whitespace set per WHATWG: U+0009, U+000A, U+000C, U+000D, U+0020.
    /// Mirrors upstream `bun.strings.trim(input_, " \t\r\n\x0C")`.
    fn trimAsciiWhitespace(input: []const u8) []const u8 {
        var begin: usize = 0;
        var end: usize = input.len;
        while (begin < end and isWs(input[begin])) : (begin += 1) {}
        while (end > begin and isWs(input[end - 1])) : (end -= 1) {}
        return input[begin..end];
    }

    inline fn isWs(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\r', '\n', 0x0C => true,
            else => false,
        };
    }

    pub fn which(input_: []const u8) ?EncodingLabel {
        const input = trimAsciiWhitespace(input_);

        // Upstream uses `string_map.getAnyCase(input)`. The Home substrate's
        // `ComptimeStringMap` doesn't yet expose case-insensitive lookup, so
        // lowercase into a stack buffer first. All alias keys are ASCII
        // lowercase, so a `get` on the lowercased input is equivalent.
        // The longest alias is "ansi_x3.4-1968" (14 chars); 64 bytes is a
        // generous bound with no overflow risk.
        const max_label_len = 64;
        if (input.len == 0 or input.len > max_label_len) return null;
        var buf: [max_label_len]u8 = undefined;
        for (input, 0..) |c, i| {
            buf[i] = switch (c) {
                'A'...'Z' => c + 32,
                else => c,
            };
        }
        return string_map.get(buf[0..input.len]);
    }
};

// Keep `strings` referenced even when none of the helpers above resolve to
// it directly — its inclusion in this module's import set documents the
// substrate dependency and matches the upstream `bun.strings` reference.
comptime {
    _ = strings.indexOfChar;
}

// ---- Inline tests ------------------------------------------------------

test "EncodingLabel: getLabel mirrors spec casing" {
    try std.testing.expectEqualStrings("utf-8", EncodingLabel.@"UTF-8".getLabel());
    try std.testing.expectEqualStrings("windows-1252", EncodingLabel.@"windows-1252".getLabel());
    try std.testing.expectEqualStrings("shift_jis", EncodingLabel.Shift_JIS.getLabel());
    try std.testing.expectEqualStrings("gb18030", EncodingLabel.GB18030.getLabel());
}

test "EncodingLabel: latin1 alias points at windows-1252" {
    try std.testing.expectEqual(EncodingLabel.@"windows-1252", EncodingLabel.latin1);
}

test "EncodingLabel: which() resolves canonical lowercase aliases" {
    try std.testing.expectEqual(EncodingLabel.@"UTF-8", EncodingLabel.which("utf-8").?);
    try std.testing.expectEqual(EncodingLabel.@"UTF-8", EncodingLabel.which("utf8").?);
    try std.testing.expectEqual(EncodingLabel.@"UTF-16LE", EncodingLabel.which("utf-16").?);
    try std.testing.expectEqual(EncodingLabel.@"UTF-16BE", EncodingLabel.which("utf-16be").?);
    try std.testing.expectEqual(EncodingLabel.Shift_JIS, EncodingLabel.which("sjis").?);
    try std.testing.expectEqual(EncodingLabel.GBK, EncodingLabel.which("gbk").?);
}

test "EncodingLabel: which() is case-insensitive (matches getAnyCase)" {
    try std.testing.expectEqual(EncodingLabel.@"UTF-8", EncodingLabel.which("UTF-8").?);
    try std.testing.expectEqual(EncodingLabel.@"UTF-8", EncodingLabel.which("UtF-8").?);
    try std.testing.expectEqual(EncodingLabel.@"windows-1252", EncodingLabel.which("Latin1").?);
    try std.testing.expectEqual(EncodingLabel.@"windows-1252", EncodingLabel.which("ASCII").?);
}

test "EncodingLabel: which() trims WHATWG whitespace" {
    try std.testing.expectEqual(EncodingLabel.@"UTF-8", EncodingLabel.which("  utf-8\t").?);
    try std.testing.expectEqual(EncodingLabel.@"UTF-8", EncodingLabel.which("\r\nutf-8\n").?);
    try std.testing.expectEqual(EncodingLabel.@"UTF-8", EncodingLabel.which("\x0cutf-8\x0c").?);
}

test "EncodingLabel: which() rejects unknown labels" {
    try std.testing.expectEqual(@as(?EncodingLabel, null), EncodingLabel.which("not-a-real-encoding"));
    try std.testing.expectEqual(@as(?EncodingLabel, null), EncodingLabel.which(""));
    try std.testing.expectEqual(@as(?EncodingLabel, null), EncodingLabel.which("   "));
}

test "EncodingLabel: aliases for windows-1252 family resolve to latin1" {
    const expected = EncodingLabel.@"windows-1252";
    try std.testing.expectEqual(expected, EncodingLabel.which("l1").?);
    try std.testing.expectEqual(expected, EncodingLabel.which("cp1252").?);
    try std.testing.expectEqual(expected, EncodingLabel.which("iso-8859-1").?);
    try std.testing.expectEqual(expected, EncodingLabel.which("ansi_x3.4-1968").?);
}
