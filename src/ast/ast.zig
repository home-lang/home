const std = @import("std");
const Token = @import("../lexer/token.zig").Token;

/// AST Node types for the Ion language
pub const NodeType = enum {
    // Literals
    IntegerLiteral,
    FloatLiteral,
    StringLiteral,
    BooleanLiteral,

    // Identifiers
    Identifier,

    // Expressions
    BinaryExpr,
    UnaryExpr,
    CallExpr,
    IndexExpr,
    MemberExpr,

    // Statements
    LetDecl,
    ConstDecl,
    FnDecl,
    StructDecl,
    ReturnStmt,
    IfStmt,
    WhileStmt,
    ForStmt,
    BlockStmt,
    ExprStmt,

    // Program
    Program,
};

/// Source location information
pub const SourceLocation = struct {
    line: usize,
    column: usize,

    pub fn fromToken(token: Token) SourceLocation {
        return .{
            .line = token.line,
            .column = token.column,
        };
    }
};

/// Base node interface
pub const Node = struct {
    type: NodeType,
    loc: SourceLocation,
};

/// Integer literal
pub const IntegerLiteral = struct {
    node: Node,
    value: i64,

    pub fn init(value: i64, loc: SourceLocation) IntegerLiteral {
        return .{
            .node = .{ .type = .IntegerLiteral, .loc = loc },
            .value = value,
        };
    }
};

/// Float literal
pub const FloatLiteral = struct {
    node: Node,
    value: f64,

    pub fn init(value: f64, loc: SourceLocation) FloatLiteral {
        return .{
            .node = .{ .type = .FloatLiteral, .loc = loc },
            .value = value,
        };
    }
};

/// String literal
pub const StringLiteral = struct {
    node: Node,
    value: []const u8,

    pub fn init(value: []const u8, loc: SourceLocation) StringLiteral {
        return .{
            .node = .{ .type = .StringLiteral, .loc = loc },
            .value = value,
        };
    }
};

/// Boolean literal
pub const BooleanLiteral = struct {
    node: Node,
    value: bool,

    pub fn init(value: bool, loc: SourceLocation) BooleanLiteral {
        return .{
            .node = .{ .type = .BooleanLiteral, .loc = loc },
            .value = value,
        };
    }
};

/// Identifier
pub const Identifier = struct {
    node: Node,
    name: []const u8,

    pub fn init(name: []const u8, loc: SourceLocation) Identifier {
        return .{
            .node = .{ .type = .Identifier, .loc = loc },
            .name = name,
        };
    }
};

/// Binary operator types
pub const BinaryOp = enum {
    Add,      // +
    Sub,      // -
    Mul,      // *
    Div,      // /
    Mod,      // %
    Equal,    // ==
    NotEqual, // !=
    Less,     // <
    LessEq,   // <=
    Greater,  // >
    GreaterEq,// >=
    And,      // &&
    Or,       // ||
    Assign,   // =
};

/// Binary expression
pub const BinaryExpr = struct {
    node: Node,
    op: BinaryOp,
    left: *Expr,
    right: *Expr,

    pub fn init(allocator: std.mem.Allocator, op: BinaryOp, left: *Expr, right: *Expr, loc: SourceLocation) !*BinaryExpr {
        const expr = try allocator.create(BinaryExpr);
        expr.* = .{
            .node = .{ .type = .BinaryExpr, .loc = loc },
            .op = op,
            .left = left,
            .right = right,
        };
        return expr;
    }
};

/// Unary operator types
pub const UnaryOp = enum {
    Neg,  // -
    Not,  // !
};

/// Unary expression
pub const UnaryExpr = struct {
    node: Node,
    op: UnaryOp,
    operand: *Expr,

    pub fn init(allocator: std.mem.Allocator, op: UnaryOp, operand: *Expr, loc: SourceLocation) !*UnaryExpr {
        const expr = try allocator.create(UnaryExpr);
        expr.* = .{
            .node = .{ .type = .UnaryExpr, .loc = loc },
            .op = op,
            .operand = operand,
        };
        return expr;
    }
};

/// Call expression
pub const CallExpr = struct {
    node: Node,
    callee: *Expr,
    args: []const *Expr,

    pub fn init(allocator: std.mem.Allocator, callee: *Expr, args: []const *Expr, loc: SourceLocation) !*CallExpr {
        const expr = try allocator.create(CallExpr);
        expr.* = .{
            .node = .{ .type = .CallExpr, .loc = loc },
            .callee = callee,
            .args = args,
        };
        return expr;
    }
};

/// Expression wrapper (tagged union)
pub const Expr = union(NodeType) {
    IntegerLiteral: IntegerLiteral,
    FloatLiteral: FloatLiteral,
    StringLiteral: StringLiteral,
    BooleanLiteral: BooleanLiteral,
    Identifier: Identifier,
    BinaryExpr: *BinaryExpr,
    UnaryExpr: *UnaryExpr,
    CallExpr: *CallExpr,

    // Unused variants (for now)
    IndexExpr: void,
    MemberExpr: void,
    LetDecl: void,
    ConstDecl: void,
    FnDecl: void,
    StructDecl: void,
    ReturnStmt: void,
    IfStmt: void,
    WhileStmt: void,
    ForStmt: void,
    BlockStmt: void,
    ExprStmt: void,
    Program: void,

    pub fn getLocation(self: Expr) SourceLocation {
        return switch (self) {
            .IntegerLiteral => |lit| lit.node.loc,
            .FloatLiteral => |lit| lit.node.loc,
            .StringLiteral => |lit| lit.node.loc,
            .BooleanLiteral => |lit| lit.node.loc,
            .Identifier => |id| id.node.loc,
            .BinaryExpr => |expr| expr.node.loc,
            .UnaryExpr => |expr| expr.node.loc,
            .CallExpr => |expr| expr.node.loc,
            else => unreachable,
        };
    }
};

/// Function parameter
pub const Parameter = struct {
    name: []const u8,
    type_name: []const u8,
    loc: SourceLocation,
};

/// Let declaration
pub const LetDecl = struct {
    node: Node,
    name: []const u8,
    type_name: ?[]const u8,
    value: ?*Expr,
    is_mutable: bool,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, type_name: ?[]const u8, value: ?*Expr, is_mutable: bool, loc: SourceLocation) !*LetDecl {
        const decl = try allocator.create(LetDecl);
        decl.* = .{
            .node = .{ .type = .LetDecl, .loc = loc },
            .name = name,
            .type_name = type_name,
            .value = value,
            .is_mutable = is_mutable,
        };
        return decl;
    }
};

/// Return statement
pub const ReturnStmt = struct {
    node: Node,
    value: ?*Expr,

    pub fn init(allocator: std.mem.Allocator, value: ?*Expr, loc: SourceLocation) !*ReturnStmt {
        const stmt = try allocator.create(ReturnStmt);
        stmt.* = .{
            .node = .{ .type = .ReturnStmt, .loc = loc },
            .value = value,
        };
        return stmt;
    }
};

/// If statement
pub const IfStmt = struct {
    node: Node,
    condition: *Expr,
    then_block: *BlockStmt,
    else_block: ?*BlockStmt,

    pub fn init(allocator: std.mem.Allocator, condition: *Expr, then_block: *BlockStmt, else_block: ?*BlockStmt, loc: SourceLocation) !*IfStmt {
        const stmt = try allocator.create(IfStmt);
        stmt.* = .{
            .node = .{ .type = .IfStmt, .loc = loc },
            .condition = condition,
            .then_block = then_block,
            .else_block = else_block,
        };
        return stmt;
    }
};

/// Statement wrapper
pub const Stmt = union(NodeType) {
    // Unused expression variants (for union completeness)
    IntegerLiteral: void,
    FloatLiteral: void,
    StringLiteral: void,
    BooleanLiteral: void,
    Identifier: void,
    BinaryExpr: void,
    UnaryExpr: void,
    CallExpr: void,
    IndexExpr: void,
    MemberExpr: void,

    // Statement variants (order must match NodeType enum)
    LetDecl: *LetDecl,
    ConstDecl: void,
    FnDecl: *FnDecl,
    StructDecl: void,
    ReturnStmt: *ReturnStmt,
    IfStmt: *IfStmt,
    WhileStmt: void,
    ForStmt: void,
    BlockStmt: *BlockStmt,
    ExprStmt: *Expr,
    Program: void,
};

/// Block statement
pub const BlockStmt = struct {
    node: Node,
    statements: []const Stmt,

    pub fn init(allocator: std.mem.Allocator, statements: []const Stmt, loc: SourceLocation) !*BlockStmt {
        const block = try allocator.create(BlockStmt);
        block.* = .{
            .node = .{ .type = .BlockStmt, .loc = loc },
            .statements = statements,
        };
        return block;
    }
};

/// Function declaration
pub const FnDecl = struct {
    node: Node,
    name: []const u8,
    params: []const Parameter,
    return_type: ?[]const u8,
    body: *BlockStmt,
    is_async: bool,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, params: []const Parameter, return_type: ?[]const u8, body: *BlockStmt, is_async: bool, loc: SourceLocation) !*FnDecl {
        const decl = try allocator.create(FnDecl);
        decl.* = .{
            .node = .{ .type = .FnDecl, .loc = loc },
            .name = name,
            .params = params,
            .return_type = return_type,
            .body = body,
            .is_async = is_async,
        };
        return decl;
    }
};

/// Program (top-level)
pub const Program = struct {
    statements: []const Stmt,

    pub fn init(allocator: std.mem.Allocator, statements: []const Stmt) !*Program {
        const program = try allocator.create(Program);
        program.* = .{
            .statements = statements,
        };
        return program;
    }

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        // Free all statements recursively
        for (self.statements) |stmt| {
            deinitStmt(stmt, allocator);
        }
        allocator.free(self.statements);
        allocator.destroy(self);
    }

    fn deinitStmt(stmt: Stmt, allocator: std.mem.Allocator) void {
        switch (stmt) {
            .LetDecl => |decl| {
                if (decl.value) |val| deinitExpr(val, allocator);
                allocator.destroy(decl);
            },
            .FnDecl => |decl| {
                allocator.free(decl.params);
                deinitBlockStmt(decl.body, allocator);
                allocator.destroy(decl);
            },
            .ReturnStmt => |ret| {
                if (ret.value) |val| deinitExpr(val, allocator);
                allocator.destroy(ret);
            },
            .IfStmt => |if_stmt| {
                deinitExpr(if_stmt.condition, allocator);
                deinitBlockStmt(if_stmt.then_block, allocator);
                if (if_stmt.else_block) |else_block| {
                    deinitBlockStmt(else_block, allocator);
                }
                allocator.destroy(if_stmt);
            },
            .BlockStmt => |block| {
                deinitBlockStmt(block, allocator);
            },
            .ExprStmt => |expr| {
                deinitExpr(expr, allocator);
            },
            else => {},
        }
    }

    fn deinitBlockStmt(block: *BlockStmt, allocator: std.mem.Allocator) void {
        for (block.statements) |stmt| {
            deinitStmt(stmt, allocator);
        }
        allocator.free(block.statements);
        allocator.destroy(block);
    }

    fn deinitExpr(expr: *Expr, allocator: std.mem.Allocator) void {
        switch (expr.*) {
            .BinaryExpr => |binary| {
                deinitExpr(binary.left, allocator);
                deinitExpr(binary.right, allocator);
                allocator.destroy(binary);
            },
            .UnaryExpr => |unary| {
                deinitExpr(unary.operand, allocator);
                allocator.destroy(unary);
            },
            .CallExpr => |call| {
                deinitExpr(call.callee, allocator);
                for (call.args) |arg| {
                    deinitExpr(arg, allocator);
                }
                allocator.free(call.args);
                allocator.destroy(call);
            },
            else => {},
        }
        allocator.destroy(expr);
    }
};
