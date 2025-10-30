// Home compiler library - root module
// Re-exports all Home packages for convenient importing

const lexer_pkg = @import("lexer");
const ast_pkg = @import("ast");
const parser_pkg = @import("parser");
const interpreter_pkg = @import("interpreter");
const codegen_pkg = @import("codegen");
const types_pkg = @import("types");
const linter_pkg = @import("linter");
const formatter_pkg = @import("formatter");

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

pub const linter = struct {
    pub const Linter = linter_pkg.Linter;
    pub const LinterConfig = linter_pkg.LinterConfig;
    pub const LintDiagnostic = linter_pkg.LintDiagnostic;
    pub const Severity = linter_pkg.Severity;
    pub const createDefaultConfig = linter_pkg.createDefaultConfig;
};

pub const formatter = struct {
    pub const Formatter = formatter_pkg.Formatter;
};
