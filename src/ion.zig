// Ion compiler library - root module
// Re-exports all Ion packages for convenient importing

const lexer_pkg = @import("lexer");
const ast_pkg = @import("ast");
const parser_pkg = @import("parser");
const interpreter_pkg = @import("interpreter");
const codegen_pkg = @import("codegen");
const types_pkg = @import("types");

pub const lexer = struct {
    pub const Lexer = lexer_pkg.Lexer;
    pub const Token = lexer_pkg.Token;
    pub const TokenType = lexer_pkg.TokenType;
};

pub const ast = ast_pkg;
pub const parser = struct {
    pub const Parser = parser_pkg.Parser;
};

pub const interpreter = struct {
    pub const Interpreter = interpreter_pkg.Interpreter;
    // Note: Value and Environment are internal to interpreter package
};

pub const codegen = struct {
    pub const NativeCodegen = codegen_pkg.NativeCodegen;
    // Note: x64 and elf are internal to codegen package
};

pub const types = struct {
    pub const Type = types_pkg.Type;
    pub const TypeChecker = types_pkg.TypeChecker;
    pub const TypeEnvironment = types_pkg.TypeEnvironment;
};
