// Re-export lexer module
const lexer_mod = @import("lexer/lexer.zig");
pub const Lexer = lexer_mod.Lexer;
pub const Token = lexer_mod.Token;
pub const TokenType = lexer_mod.TokenType;
