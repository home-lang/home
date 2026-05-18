// Copied from bun/src/options_types/CodeCoverageOptions.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Rewrites: @import("bun") → @import("home_rt"); bun.SourceMap.coverage.Fraction
// is upstream-located in sourcemap_jsc/CodeCoverage.zig (JSC-bridge file, not
// yet ported), so the tiny POD `Fraction` struct it defines is inlined here.
// Defaults match upstream byte-for-byte. Re-attach to the real symbol once
// sourcemap_jsc lands.

//! `bun test --coverage` option struct, extracted from `cli/test_command.zig`
//! so `options_types/Context.zig` (and `cli/cli.zig` `TestOptions`) can hold
//! it without depending on `cli/`.

pub const CodeCoverageOptions = struct {
    skip_test_files: bool = !home_rt.Environment.allow_assert,
    reporters: Reporters = .{ .text = true, .lcov = false },
    reports_directory: []const u8 = "coverage",
    fractions: Fraction = .{},
    ignore_sourcemap: bool = false,
    enabled: bool = false,
    fail_on_low_coverage: bool = false,
    ignore_patterns: []const []const u8 = &.{},
};

pub const Reporter = enum {
    text,
    lcov,
};

pub const Reporters = struct {
    text: bool,
    lcov: bool,
};

/// Mirror of `bun.SourceMap.coverage.Fraction` (see
/// `bun/src/sourcemap_jsc/CodeCoverage.zig`). Inlined here because the
/// sourcemap_jsc file is JSC-bridged and not yet ported into Home. Field
/// names, types, and defaults are byte-identical to upstream so the
/// re-attachment to `home_rt.SourceMap.coverage.Fraction` is a one-line
/// swap once that namespace lands.
pub const Fraction = struct {
    functions: f64 = 0.9,
    lines: f64 = 0.9,

    // This metric is less accurate right now
    stmts: f64 = 0.75,

    failing: bool = false,
};

const home_rt = @import("home_rt");

test "CodeCoverageOptions defaults match upstream" {
    const std = @import("std");
    const opts: CodeCoverageOptions = .{};
    try std.testing.expectEqualStrings("coverage", opts.reports_directory);
    try std.testing.expect(opts.reporters.text);
    try std.testing.expect(!opts.reporters.lcov);
    try std.testing.expect(!opts.ignore_sourcemap);
    try std.testing.expect(!opts.enabled);
    try std.testing.expect(!opts.fail_on_low_coverage);
    try std.testing.expectEqual(@as(usize, 0), opts.ignore_patterns.len);
    try std.testing.expectEqual(@as(f64, 0.9), opts.fractions.functions);
    try std.testing.expectEqual(@as(f64, 0.9), opts.fractions.lines);
    try std.testing.expectEqual(@as(f64, 0.75), opts.fractions.stmts);
    try std.testing.expect(!opts.fractions.failing);
}

test "Reporter enum round-trip" {
    const std = @import("std");
    try std.testing.expectEqualStrings("text", @tagName(Reporter.text));
    try std.testing.expectEqualStrings("lcov", @tagName(Reporter.lcov));
    try std.testing.expectEqual(Reporter.text, @as(Reporter, @enumFromInt(@intFromEnum(Reporter.text))));
}
