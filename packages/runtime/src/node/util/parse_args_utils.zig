// Copied from bun/src/runtime/node/util/parse_args_utils.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// `node:util.parseArgs` (Node's RFC4180-style flag parser) shape vocabulary:
//   * `OptionValueType` — `boolean` or `string`
//   * `TokenSubtype` — the 7-way classification `parseArgs` lexes each argv
//     into (`positional`, lone short/long option, short option group, etc.)
//   * `isOptionLikeValue(value)` — a pure UTF-8 predicate, doesn't touch JSC
//
// What's omitted (re-attaches with the `bun.String` rope-string substrate):
//   * `OptionDefinition` — its `long_name`/`short_name` fields are
//     `bun.String` and `default_value` is `jsc.JSValue`. Both unported.
//   * `classifyToken` / `findOptionByShortName` — they take `[]const
//     OptionDefinition` slices, so they wait on the same substrate.
//
// Imports rewritten: @import("bun") → @import("home_rt"). Only `std` and
// `home_rt.strings` are actually pulled in by what's ported.

const std = @import("std");

const home_rt = @import("home_rt");
const strings = home_rt.strings;

pub const OptionValueType = enum { boolean, string };

pub const TokenSubtype = enum {
    /// '--'
    option_terminator,
    /// e.g. '-f'
    lone_short_option,
    /// e.g. '-fXzy'
    short_option_group,
    /// e.g. '-fFILE'
    short_option_and_value,
    /// e.g. '--foo'
    lone_long_option,
    /// e.g. '--foo=barconst'
    long_option_and_value,

    positional,
};

/// Detect whether there is possible confusion and user may have omitted
/// the option argument, like `--port --verbose` when `port` of type:string.
/// In strict mode we throw errors if value is option-like.
///
/// Upstream takes a `bun.String` (rope string) and calls `.length()` /
/// `.hasPrefixComptime()`; ported here over `[]const u8` since the rope
/// substrate hasn't landed. Same semantics — bytes starting with `-` past
/// one character qualify.
pub fn isOptionLikeValue(value: []const u8) bool {
    return value.len > 1 and strings.hasPrefix(value, "-");
}

test "parse_args_utils: OptionValueType tag layout" {
    try std.testing.expectEqual(@as(u1, 0), @intFromEnum(OptionValueType.boolean));
    try std.testing.expectEqual(@as(u1, 1), @intFromEnum(OptionValueType.string));
}

test "parse_args_utils: TokenSubtype tag layout matches upstream ordering" {
    // The ordinal positions are load-bearing: upstream's bitmask checks
    // rely on `option_terminator` being 0 and `positional` being the
    // sentinel at the tail.
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(TokenSubtype.option_terminator));
    try std.testing.expectEqual(@as(u3, 1), @intFromEnum(TokenSubtype.lone_short_option));
    try std.testing.expectEqual(@as(u3, 2), @intFromEnum(TokenSubtype.short_option_group));
    try std.testing.expectEqual(@as(u3, 3), @intFromEnum(TokenSubtype.short_option_and_value));
    try std.testing.expectEqual(@as(u3, 4), @intFromEnum(TokenSubtype.lone_long_option));
    try std.testing.expectEqual(@as(u3, 5), @intFromEnum(TokenSubtype.long_option_and_value));
    try std.testing.expectEqual(@as(u3, 6), @intFromEnum(TokenSubtype.positional));
}

test "parse_args_utils: isOptionLikeValue catches --flag and -f but not bare - or positionals" {
    try std.testing.expect(isOptionLikeValue("--foo"));
    try std.testing.expect(isOptionLikeValue("-f"));
    try std.testing.expect(isOptionLikeValue("-fFILE"));
    // Bare `-` is positional (stdin sentinel), not option-like.
    try std.testing.expect(!isOptionLikeValue("-"));
    try std.testing.expect(!isOptionLikeValue(""));
    try std.testing.expect(!isOptionLikeValue("bar"));
    try std.testing.expect(!isOptionLikeValue("/tmp/x"));
}
