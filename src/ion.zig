// Ion compiler library - root module

pub const lexer = struct {
    pub const Lexer = @import("lexer/lexer.zig").Lexer;
    pub const Token = @import("lexer/token.zig").Token;
    pub const TokenType = @import("lexer/token.zig").TokenType;
};

pub const ast = @import("ast/ast.zig");
pub const parser = struct {
    pub const Parser = @import("parser/parser.zig").Parser;
};

pub const interpreter = struct {
    pub const Interpreter = @import("interpreter/interpreter.zig").Interpreter;
    pub const Value = @import("interpreter/value.zig").Value;
    pub const Environment = @import("interpreter/environment.zig").Environment;
};
