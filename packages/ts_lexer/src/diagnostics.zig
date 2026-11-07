//! Shared scanner diagnostic identities for parser and driver consumers.
const std = @import("std");

pub const NormalizedScannerDiagnostic = struct {
    code: u32 = 0,
    message: []const u8,
};

pub fn scannerDiagnosticIsUnexpectedCharacter(message: []const u8) bool {
    return std.mem.eql(u8, message, "unexpected character") or
        std.mem.eql(u8, message, "Invalid character.");
}

pub fn scannerDiagnosticIsSuppressedInJsxText(message: []const u8) bool {
    return scannerDiagnosticIsUnexpectedCharacter(message) or
        std.mem.eql(u8, message, "An identifier or keyword cannot immediately follow a numeric literal.");
}

pub fn normalizeScannerDiagnostic(message: []const u8) NormalizedScannerDiagnostic {
    if (scannerDiagnosticIsUnexpectedCharacter(message)) {
        return .{ .code = 1127, .message = "Invalid character." };
    }
    // The scanner emits a lowercase "unterminated template literal"
    // message when it walks off the end of a backtick literal.
    // Upstream tsc reports this as TS1160 with sentence-case
    // ("Unterminated template literal.") — matching that here so
    // exact-baseline conformance fixtures like
    // `labeledStatementDeclarationListInLoopNoCrash3/4` pass.
    if (std.mem.eql(u8, message, "unterminated template literal")) {
        return .{ .code = 1160, .message = "Unterminated template literal." };
    }
    // The scanner emits a lowercase "unterminated string literal" (with
    // an optional " at EOF" suffix when it walks past EOF without seeing
    // the closing quote). tsc reports both shapes uniformly as TS1002
    // with sentence-case ("Unterminated string literal.") — match that
    // exactly so exact-baseline fixtures like `scannerStringLiterals`
    // ratchet through.
    if (std.mem.eql(u8, message, "unterminated string literal") or
        std.mem.eql(u8, message, "unterminated string literal at EOF"))
    {
        return .{ .code = 1002, .message = "Unterminated string literal." };
    }
    // TS1126 — backslash immediately before EOF inside a string
    // literal. tsc emits "Unexpected end of text." instead of the
    // generic TS1002 for this specific shape. Mirrors
    // `unterminatedStringLiteralWithBackslash1.ts(1,3)`.
    if (std.mem.eql(u8, message, "Unexpected end of text.")) {
        return .{ .code = 1126, .message = "Unexpected end of text." };
    }
    if (std.mem.eql(u8, message, "'*/' expected") or std.mem.eql(u8, message, "'*/' expected.")) {
        return .{ .code = 1010, .message = "'*/' expected." };
    }
    if (std.mem.eql(u8, message, "Numeric separators are not allowed here.")) {
        return .{ .code = 6188, .message = message };
    }
    if (std.mem.eql(u8, message, "Multiple consecutive numeric separators are not permitted.")) {
        return .{ .code = 6189, .message = message };
    }
    if (std.mem.eql(u8, message, "An identifier or keyword cannot immediately follow a numeric literal.")) {
        return .{ .code = 1351, .message = message };
    }
    if (std.mem.eql(u8, message, "A bigint literal cannot use exponential notation.")) {
        return .{ .code = 1352, .message = message };
    }
    if (std.mem.eql(u8, message, "A bigint literal must be an integer.")) {
        return .{ .code = 1353, .message = message };
    }
    if (std.mem.eql(u8, message, "Digit expected.")) {
        return .{ .code = 1124, .message = message };
    }
    if (std.mem.eql(u8, message, "Hexadecimal digit expected.")) {
        return .{ .code = 1125, .message = message };
    }
    if (std.mem.eql(u8, message, "Binary digit expected.")) {
        return .{ .code = 1177, .message = message };
    }
    if (std.mem.eql(u8, message, "Octal digit expected.")) {
        return .{ .code = 1178, .message = message };
    }
    if (std.mem.eql(u8, message, "Unterminated Unicode escape sequence.")) {
        return .{ .code = 1199, .message = message };
    }
    // TS1198 — `\u{N}` extended unicode escape whose codepoint
    // exceeds the Unicode Scalar Value cap (0x10FFFF). Scanner
    // emits at the first hex digit so `(line, col)` matches the
    // upstream baseline (`unicodeExtendedEscapesIn{Strings,Templates}07/12`).
    if (std.mem.eql(u8, message, "An extended Unicode escape value must be between 0x0 and 0x10FFFF inclusive.")) {
        return .{ .code = 1198, .message = message };
    }
    // Sentence-case + TS1002 for the scanner's lowercase
    // "unterminated string literal" messages. Mirrors tsc which
    // emits `Unterminated string literal.` when a string token
    // hits EOL/EOF without its closing quote — fixture
    // `unicodeExtendedEscapesInStrings25` baselines this exact
    // text/code pair.
    if (std.mem.eql(u8, message, "unterminated string literal") or
        std.mem.eql(u8, message, "unterminated string literal at EOF"))
    {
        return .{ .code = 1002, .message = "Unterminated string literal." };
    }
    if (std.mem.eql(u8, message, "Unexpected '}'. Did you mean to escape it with backslash?")) {
        return .{ .code = 1508, .message = message };
    }
    if (std.mem.startsWith(u8, message, "Octal escape sequences are not allowed. Use the syntax ")) {
        return .{ .code = 1487, .message = message };
    }
    if (std.mem.startsWith(u8, message, "Escape sequence '") and
        std.mem.endsWith(u8, message, "' is not allowed."))
    {
        return .{ .code = 1488, .message = message };
    }
    // TS1499 — invalid regex flag character (anything outside the
    // ES2024 set g/i/m/s/u/y/d/v). Scanner emits at the offending
    // flag column so the (line, col) anchor matches tsc.
    if (std.mem.eql(u8, message, "Unknown regular expression flag.")) {
        return .{ .code = 1499, .message = message };
    }
    if (std.mem.eql(u8, message, "File appears to be binary.")) {
        return .{ .code = 1490, .message = message };
    }
    if (std.mem.eql(u8, message, "Merge conflict marker encountered.")) {
        return .{ .code = 1185, .message = message };
    }
    if (std.mem.eql(u8, message, "'#!' can only be used at the start of a file.")) {
        return .{ .code = 18026, .message = message };
    }
    return .{ .message = message };
}

pub fn scannerDiagnosticIsInvalidStringTemplateEscape(d: NormalizedScannerDiagnostic) bool {
    return switch (d.code) {
        1125, 1127, 1199, 1487, 1488 => true,
        else => false,
    };
}
