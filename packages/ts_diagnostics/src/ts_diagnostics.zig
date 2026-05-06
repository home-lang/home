//! tsc-compatible diagnostic formatting.
//!
//! Per TS_PARITY_PLAN §2.4. Tools that scrape `tsc` output rely on a
//! specific text format; this module produces byte-equivalent output.
//!
//!   - **Default**: `path/file.ts(line,col): error TSxxxx: message`
//!   - **--pretty**: ANSI-colored with source-code excerpts and
//!     squiggly underlines. Default on TTY.
//!   - **Localized**: messages routed through a catalog table; ship
//!     `en` first, others as data files.
//!
//! Error codes follow tsc's `TSxxxx` numeric scheme; Home-specific
//! diagnostics use `HMxxxx`. Exit codes match tsc: 0 success, 1 type
//! errors, 2 CLI/config errors, 3 internal errors.

const std = @import("std");

pub const Severity = enum(u8) {
    err,
    warning,
    suggestion,
    message,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .suggestion => "suggestion",
            .message => "message",
        };
    }

    /// Process exit code for the most-severe diagnostic of this level.
    pub fn exitCode(self: Severity) u8 {
        return switch (self) {
            .err => 1,
            .warning => 0,
            .suggestion => 0,
            .message => 0,
        };
    }
};

pub const Diagnostic = struct {
    /// File path the diagnostic relates to. Empty for whole-program
    /// diagnostics.
    file: []const u8,
    /// 1-based line number, 1-based column number.
    line: u32,
    col: u32,
    /// Numeric code (e.g. 2304 for "Cannot find name"). 0 for
    /// uncategorized.
    code: u32,
    /// `TS` for upstream-compatible codes; `HM` for Home-only codes.
    code_prefix: CodePrefix,
    severity: Severity,
    message: []const u8,
    /// Length of the source excerpt to underline (in source bytes).
    /// 0 means no specific extent.
    span_len: u32,

    pub const CodePrefix = enum { TS, HM };
};

/// Produce a tsc-compatible single-line diagnostic header:
/// `path/file.ts(line,col): error TS2304: Cannot find name 'foo'.`
/// Caller owns the returned slice.
pub fn formatDefault(gpa: std.mem.Allocator, d: Diagnostic) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    if (d.file.len > 0) {
        try buf.appendSlice(gpa, d.file);
        var nbuf: [32]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&nbuf, "({d},{d}): ", .{ d.line, d.col });
        try buf.appendSlice(gpa, formatted);
    }
    try buf.appendSlice(gpa, d.severity.label());
    try buf.append(gpa, ' ');
    try writeCode(&buf, gpa, d.code_prefix, d.code);
    try buf.appendSlice(gpa, ": ");
    try buf.appendSlice(gpa, d.message);
    return try buf.toOwnedSlice(gpa);
}

/// Pretty format with source excerpt and squiggly underline. Used
/// when stdout is a TTY (the CLI driver toggles via `--pretty`).
///
/// Output shape:
///
/// ```
/// path/file.ts:line:col - error TS2304: Cannot find name 'foo'.
///
/// 12  let x = foo + 1;
///             ~~~
/// ```
pub fn formatPretty(
    gpa: std.mem.Allocator,
    d: Diagnostic,
    source: ?[]const u8,
    color: bool,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);

    if (d.file.len > 0) {
        if (color) try buf.appendSlice(gpa, "\x1b[36m"); // cyan
        try buf.appendSlice(gpa, d.file);
        if (color) try buf.appendSlice(gpa, "\x1b[0m");
        var nbuf: [32]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, ":{d}:{d} - ", .{ d.line, d.col }));
    }
    if (color) {
        const ansi = switch (d.severity) {
            .err => "\x1b[31m", // red
            .warning => "\x1b[33m", // yellow
            .suggestion => "\x1b[34m", // blue
            .message => "\x1b[39m",
        };
        try buf.appendSlice(gpa, ansi);
    }
    try buf.appendSlice(gpa, d.severity.label());
    if (color) try buf.appendSlice(gpa, "\x1b[0m");
    try buf.append(gpa, ' ');
    try writeCode(&buf, gpa, d.code_prefix, d.code);
    try buf.appendSlice(gpa, ": ");
    try buf.appendSlice(gpa, d.message);
    try buf.append(gpa, '\n');

    if (source) |src| {
        if (extractLine(src, d.line)) |line_text| {
            try buf.append(gpa, '\n');
            var nbuf: [16]u8 = undefined;
            try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d:>4}  ", .{d.line}));
            try buf.appendSlice(gpa, line_text);
            try buf.append(gpa, '\n');
            // Underline.
            try buf.appendSlice(gpa, "      ");
            const start_col = if (d.col > 0) d.col - 1 else 0;
            var i: u32 = 0;
            while (i < start_col) : (i += 1) try buf.append(gpa, ' ');
            const len = @max(@as(u32, 1), d.span_len);
            i = 0;
            if (color) try buf.appendSlice(gpa, "\x1b[31m");
            while (i < len) : (i += 1) try buf.append(gpa, '~');
            if (color) try buf.appendSlice(gpa, "\x1b[0m");
            try buf.append(gpa, '\n');
        }
    }

    return try buf.toOwnedSlice(gpa);
}

fn writeCode(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, prefix: Diagnostic.CodePrefix, code: u32) !void {
    try buf.appendSlice(gpa, switch (prefix) {
        .TS => "TS",
        .HM => "HM",
    });
    var nbuf: [16]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{code}));
}

/// Extract `line_no` (1-based) from `source`. Returns null if the
/// line is past EOF.
fn extractLine(source: []const u8, line_no: u32) ?[]const u8 {
    var current_line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            if (current_line == line_no) {
                return source[line_start..i];
            }
            current_line += 1;
            line_start = i + 1;
        }
    }
    if (current_line == line_no and line_start < source.len) {
        return source[line_start..source.len];
    }
    return null;
}

/// Convert a byte position (0-based) into a (line, col) pair (1-based,
/// matching tsc).
pub fn positionToLineCol(source: []const u8, pos: u32) struct { line: u32, col: u32 } {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: u32 = 0;
    while (i < pos and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

// =============================================================================
// Common error codes (subset; full table lives in TS source)
// =============================================================================

pub const TsCodes = struct {
    pub const cannot_find_name: u32 = 2304;
    pub const cannot_find_module: u32 = 2307;
    pub const type_not_assignable: u32 = 2322;
    pub const property_does_not_exist: u32 = 2339;
    pub const expected_n_arguments: u32 = 2554;
    pub const argument_type_mismatch: u32 = 2345;
    pub const duplicate_identifier: u32 = 2300;
    pub const generic_type_requires_args: u32 = 2314;
    pub const expected_token: u32 = 1005;
    pub const unexpected_token: u32 = 1109;
    pub const unterminated_string: u32 = 1002;
    pub const unterminated_regex: u32 = 1161;
};

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "formatDefault: tsc-compatible header" {
    const d: Diagnostic = .{
        .file = "src/main.ts",
        .line = 12,
        .col = 5,
        .code = TsCodes.cannot_find_name,
        .code_prefix = .TS,
        .severity = .err,
        .message = "Cannot find name 'foo'.",
        .span_len = 3,
    };
    const out = try formatDefault(T.allocator, d);
    defer T.allocator.free(out);
    try T.expectEqualStrings("src/main.ts(12,5): error TS2304: Cannot find name 'foo'.", out);
}

test "formatDefault: HM prefix for Home-only codes" {
    const d: Diagnostic = .{
        .file = "x.ts",
        .line = 1,
        .col = 1,
        .code = 9001,
        .code_prefix = .HM,
        .severity = .warning,
        .message = "Home-only warning.",
        .span_len = 0,
    };
    const out = try formatDefault(T.allocator, d);
    defer T.allocator.free(out);
    try T.expectEqualStrings("x.ts(1,1): warning HM9001: Home-only warning.", out);
}

test "formatDefault: empty file path is omitted" {
    const d: Diagnostic = .{
        .file = "",
        .line = 0,
        .col = 0,
        .code = 1109,
        .code_prefix = .TS,
        .severity = .err,
        .message = "Expression expected.",
        .span_len = 0,
    };
    const out = try formatDefault(T.allocator, d);
    defer T.allocator.free(out);
    try T.expectEqualStrings("error TS1109: Expression expected.", out);
}

test "extractLine: 1-based line addressing" {
    const src = "alpha\nbeta\ngamma\n";
    try T.expectEqualStrings("alpha", extractLine(src, 1).?);
    try T.expectEqualStrings("beta", extractLine(src, 2).?);
    try T.expectEqualStrings("gamma", extractLine(src, 3).?);
    try T.expect(extractLine(src, 99) == null);
}

test "extractLine: last line without trailing newline" {
    const src = "alpha\nbeta";
    try T.expectEqualStrings("beta", extractLine(src, 2).?);
}

test "positionToLineCol: tracks newlines" {
    const src = "abc\ndef\nghi";
    const p1 = positionToLineCol(src, 0);
    try T.expectEqual(@as(u32, 1), p1.line);
    try T.expectEqual(@as(u32, 1), p1.col);
    const p2 = positionToLineCol(src, 4);
    try T.expectEqual(@as(u32, 2), p2.line);
    try T.expectEqual(@as(u32, 1), p2.col);
    const p3 = positionToLineCol(src, 9);
    try T.expectEqual(@as(u32, 3), p3.line);
    try T.expectEqual(@as(u32, 2), p3.col);
}

test "formatPretty: includes source excerpt and underline" {
    const src =
        \\let x = foo + 1;
        \\let y = bar + 2;
    ;
    const d: Diagnostic = .{
        .file = "demo.ts",
        .line = 1,
        .col = 9,
        .code = 2304,
        .code_prefix = .TS,
        .severity = .err,
        .message = "Cannot find name 'foo'.",
        .span_len = 3,
    };
    const out = try formatPretty(T.allocator, d, src, false);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "demo.ts:1:9 - error TS2304:") != null);
    try T.expect(std.mem.indexOf(u8, out, "let x = foo + 1;") != null);
    try T.expect(std.mem.indexOf(u8, out, "~~~") != null);
}

test "formatPretty: 5-char span produces 5 squigglies at correct column" {
    const src = "const value = hello + 1;";
    const d: Diagnostic = .{
        .file = "demo.ts",
        .line = 1,
        .col = 15,
        .code = 2304,
        .code_prefix = .TS,
        .severity = .err,
        .message = "Cannot find name 'hello'.",
        .span_len = 5,
    };
    const out = try formatPretty(T.allocator, d, src, false);
    defer T.allocator.free(out);
    // Header in pretty form uses ':' separators.
    try T.expect(std.mem.indexOf(u8, out, "demo.ts:1:15 - error TS2304: Cannot find name 'hello'.") != null);
    // Source line present.
    try T.expect(std.mem.indexOf(u8, out, "const value = hello + 1;") != null);
    // Squiggly: 6-char gutter ("   1  ") + (col-1=14) spaces + 5 tildes.
    const expected_underline = "      " ++ "              " ++ "~~~~~";
    try T.expect(std.mem.indexOf(u8, out, expected_underline) != null);
    // Exactly 5 tildes (no more, no less).
    try T.expect(std.mem.indexOf(u8, out, "~~~~~~") == null);
}

test "formatPretty: line 1 col 1 has correct gutter alignment" {
    const src = "x;\ny;\n";
    const d: Diagnostic = .{
        .file = "a.ts",
        .line = 1,
        .col = 1,
        .code = 2304,
        .code_prefix = .TS,
        .severity = .err,
        .message = "Cannot find name 'x'.",
        .span_len = 1,
    };
    const out = try formatPretty(T.allocator, d, src, false);
    defer T.allocator.free(out);
    // Gutter renders as "   1  " (4-wide right-aligned line number + 2 spaces).
    try T.expect(std.mem.indexOf(u8, out, "   1  x;") != null);
    // Underline gutter is 6 spaces, then a single tilde at col 1 (no leading spaces).
    try T.expect(std.mem.indexOf(u8, out, "\n      ~\n") != null);
}

test "formatPretty: ANSI color when enabled" {
    const d: Diagnostic = .{
        .file = "x.ts",
        .line = 1,
        .col = 1,
        .code = 1,
        .code_prefix = .TS,
        .severity = .err,
        .message = "test",
        .span_len = 1,
    };
    const out = try formatPretty(T.allocator, d, null, true);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\x1b[31m") != null); // red for err
    try T.expect(std.mem.indexOf(u8, out, "\x1b[36m") != null); // cyan for path
}

test "formatPretty: ANSI escapes only present when with_colors=true" {
    const src = "let x = foo + 1;";
    const d: Diagnostic = .{
        .file = "demo.ts",
        .line = 1,
        .col = 9,
        .code = 2304,
        .code_prefix = .TS,
        .severity = .err,
        .message = "Cannot find name 'foo'.",
        .span_len = 3,
    };
    const colored = try formatPretty(T.allocator, d, src, true);
    defer T.allocator.free(colored);
    try T.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);

    const plain = try formatPretty(T.allocator, d, src, false);
    defer T.allocator.free(plain);
    try T.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
}

test "Severity: exit codes match tsc" {
    try T.expectEqual(@as(u8, 1), Severity.err.exitCode());
    try T.expectEqual(@as(u8, 0), Severity.warning.exitCode());
    try T.expectEqual(@as(u8, 0), Severity.suggestion.exitCode());
}

test "Severity: labels match tsc" {
    try T.expectEqualStrings("error", Severity.err.label());
    try T.expectEqualStrings("warning", Severity.warning.label());
}
