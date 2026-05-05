//! `ts_lexer` package root — re-exports the public TS lexer surface.
//!
//! Per TS_PARITY_PLAN §0 / Phase 1.A.

const scanner = @import("scanner.zig");
const tk = @import("token.zig");
const keywords_mod = @import("keywords.zig");

pub const Scanner = scanner.Scanner;
pub const ScanError = scanner.ScanError;
pub const Diagnostic = scanner.Diagnostic;
pub const Token = tk.Token;
pub const TokenKind = tk.TokenKind;
pub const TokenFlags = tk.TokenFlags;
pub const Span = tk.Span;
pub const lookupKeyword = keywords_mod.lookup;

test {
    _ = scanner;
    _ = tk;
    _ = keywords_mod;
}
