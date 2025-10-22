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

pub const codegen = struct {
    pub const NativeCodegen = @import("codegen/native_codegen.zig").NativeCodegen;
    pub const x64 = @import("codegen/x64.zig");
    pub const elf = @import("codegen/elf.zig");
};

pub const types = struct {
    pub const Type = @import("types/type_system.zig").Type;
    pub const TypeChecker = @import("types/type_system.zig").TypeChecker;
    pub const TypeEnvironment = @import("types/type_system.zig").TypeEnvironment;
};
