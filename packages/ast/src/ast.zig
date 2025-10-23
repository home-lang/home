const std = @import("std");
const Token = @import("lexer").Token;

/// AST Node types for the Ion language
pub const NodeType = enum {
    // Literals
    IntegerLiteral,
    FloatLiteral,
    StringLiteral,
    BooleanLiteral,
    ArrayLiteral,

    // Identifiers
    Identifier,

    // Expressions
    BinaryExpr,
    UnaryExpr,
    AssignmentExpr,
    CallExpr,
    TryExpr,
    IndexExpr,
    MemberExpr,
    RangeExpr,
    SliceExpr,
    TernaryExpr,
    PipeExpr,
    SpreadExpr,
    NullCoalesceExpr,
    SafeNavExpr,
    TupleExpr,
    GenericTypeExpr,
    AwaitExpr,

    // Statements
    LetDecl,
    ConstDecl,
    FnDecl,
    StructDecl,
    EnumDecl,
    TypeAliasDecl,
    UnionDecl,
    ReturnStmt,
    IfStmt,
    WhileStmt,
    DoWhileStmt,
    ForStmt,
    SwitchStmt,
    CaseClause,
    TryStmt,
    CatchClause,
    DeferStmt,
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
    BitAnd,   // &
    BitOr,    // |
    BitXor,   // ^
    LeftShift,  // <<
    RightShift, // >>
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

/// Assignment expression (e.g., x = 5)
pub const AssignmentExpr = struct {
    node: Node,
    target: *Expr, // Should be an Identifier, IndexExpr, or MemberExpr
    value: *Expr,

    pub fn init(allocator: std.mem.Allocator, target: *Expr, value: *Expr, loc: SourceLocation) !*AssignmentExpr {
        const expr = try allocator.create(AssignmentExpr);
        expr.* = .{
            .node = .{ .type = .AssignmentExpr, .loc = loc },
            .target = target,
            .value = value,
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

/// Try expression (error propagation with ?)
pub const TryExpr = struct {
    node: Node,
    operand: *Expr,

    pub fn init(allocator: std.mem.Allocator, operand: *Expr, loc: SourceLocation) !*TryExpr {
        const expr = try allocator.create(TryExpr);
        expr.* = .{
            .node = .{ .type = .TryExpr, .loc = loc },
            .operand = operand,
        };
        return expr;
    }
};

/// Array literal
pub const ArrayLiteral = struct {
    node: Node,
    elements: []const *Expr,

    pub fn init(allocator: std.mem.Allocator, elements: []const *Expr, loc: SourceLocation) !*ArrayLiteral {
        const expr = try allocator.create(ArrayLiteral);
        expr.* = .{
            .node = .{ .type = .ArrayLiteral, .loc = loc },
            .elements = elements,
        };
        return expr;
    }
};

/// Index expression (array[index])
pub const IndexExpr = struct {
    node: Node,
    array: *Expr,
    index: *Expr,

    pub fn init(allocator: std.mem.Allocator, array: *Expr, index: *Expr, loc: SourceLocation) !*IndexExpr {
        const expr = try allocator.create(IndexExpr);
        expr.* = .{
            .node = .{ .type = .IndexExpr, .loc = loc },
            .array = array,
            .index = index,
        };
        return expr;
    }
};

/// Member access expression (struct.field)
pub const MemberExpr = struct {
    node: Node,
    object: *Expr,
    member: []const u8,

    pub fn init(allocator: std.mem.Allocator, object: *Expr, member: []const u8, loc: SourceLocation) !*MemberExpr {
        const expr = try allocator.create(MemberExpr);
        expr.* = .{
            .node = .{ .type = .MemberExpr, .loc = loc },
            .object = object,
            .member = member,
        };
        return expr;
    }
};

/// Range expression (e.g., 0..10, 1..=100)
pub const RangeExpr = struct {
    node: Node,
    start: *Expr,
    end: *Expr,
    inclusive: bool, // true for ..=, false for ..

    pub fn init(allocator: std.mem.Allocator, start: *Expr, end: *Expr, inclusive: bool, loc: SourceLocation) !*RangeExpr {
        const expr = try allocator.create(RangeExpr);
        expr.* = .{
            .node = .{ .type = .RangeExpr, .loc = loc },
            .start = start,
            .end = end,
            .inclusive = inclusive,
        };
        return expr;
    }
};

/// Slice expression (e.g., array[1..3], array[..5], array[2..])
pub const SliceExpr = struct {
    node: Node,
    array: *Expr,
    start: ?*Expr, // null means slice from beginning
    end: ?*Expr, // null means slice to end
    inclusive: bool, // true for ..=, false for ..

    pub fn init(allocator: std.mem.Allocator, array: *Expr, start: ?*Expr, end: ?*Expr, inclusive: bool, loc: SourceLocation) !*SliceExpr {
        const expr = try allocator.create(SliceExpr);
        expr.* = .{
            .node = .{ .type = .SliceExpr, .loc = loc },
            .array = array,
            .start = start,
            .end = end,
            .inclusive = inclusive,
        };
        return expr;
    }
};

/// Ternary expression (condition ? true_val : false_val)
pub const TernaryExpr = struct {
    node: Node,
    condition: *Expr,
    true_val: *Expr,
    false_val: *Expr,

    pub fn init(allocator: std.mem.Allocator, condition: *Expr, true_val: *Expr, false_val: *Expr, loc: SourceLocation) !*TernaryExpr {
        const expr = try allocator.create(TernaryExpr);
        expr.* = .{
            .node = .{ .type = .TernaryExpr, .loc = loc },
            .condition = condition,
            .true_val = true_val,
            .false_val = false_val,
        };
        return expr;
    }
};

/// Pipe expression (value |> function)
pub const PipeExpr = struct {
    node: Node,
    left: *Expr,
    right: *Expr,

    pub fn init(allocator: std.mem.Allocator, left: *Expr, right: *Expr, loc: SourceLocation) !*PipeExpr {
        const expr = try allocator.create(PipeExpr);
        expr.* = .{
            .node = .{ .type = .PipeExpr, .loc = loc },
            .left = left,
            .right = right,
        };
        return expr;
    }
};

/// Spread expression (...array)
pub const SpreadExpr = struct {
    node: Node,
    operand: *Expr,

    pub fn init(allocator: std.mem.Allocator, operand: *Expr, loc: SourceLocation) !*SpreadExpr {
        const expr = try allocator.create(SpreadExpr);
        expr.* = .{
            .node = .{ .type = .SpreadExpr, .loc = loc },
            .operand = operand,
        };
        return expr;
    }
};

/// Null coalescing expression (value ?? default)
pub const NullCoalesceExpr = struct {
    node: Node,
    left: *Expr,
    right: *Expr,

    pub fn init(allocator: std.mem.Allocator, left: *Expr, right: *Expr, loc: SourceLocation) !*NullCoalesceExpr {
        const expr = try allocator.create(NullCoalesceExpr);
        expr.* = .{
            .node = .{ .type = .NullCoalesceExpr, .loc = loc },
            .left = left,
            .right = right,
        };
        return expr;
    }
};

/// Safe navigation expression (object?.member)
pub const SafeNavExpr = struct {
    node: Node,
    object: *Expr,
    member: []const u8,

    pub fn init(allocator: std.mem.Allocator, object: *Expr, member: []const u8, loc: SourceLocation) !*SafeNavExpr {
        const expr = try allocator.create(SafeNavExpr);
        expr.* = .{
            .node = .{ .type = .SafeNavExpr, .loc = loc },
            .object = object,
            .member = member,
        };
        return expr;
    }
};

/// Tuple expression ((a, b, c))
pub const TupleExpr = struct {
    node: Node,
    elements: []const *Expr,

    pub fn init(allocator: std.mem.Allocator, elements: []const *Expr, loc: SourceLocation) !*TupleExpr {
        const expr = try allocator.create(TupleExpr);
        expr.* = .{
            .node = .{ .type = .TupleExpr, .loc = loc },
            .elements = elements,
        };
        return expr;
    }
};

/// Generic type expression (e.g., Vec<T>, Option<String>)
pub const GenericTypeExpr = struct {
    node: Node,
    base_type: []const u8,
    type_args: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, base_type: []const u8, type_args: []const []const u8, loc: SourceLocation) !*GenericTypeExpr {
        const expr = try allocator.create(GenericTypeExpr);
        expr.* = .{
            .node = .{ .type = .GenericTypeExpr, .loc = loc },
            .base_type = base_type,
            .type_args = type_args,
        };
        return expr;
    }
};

/// Await expression (await future_expr)
pub const AwaitExpr = struct {
    node: Node,
    expression: *Expr,

    pub fn init(allocator: std.mem.Allocator, expression: *Expr, loc: SourceLocation) !*AwaitExpr {
        const expr = try allocator.create(AwaitExpr);
        expr.* = .{
            .node = .{ .type = .AwaitExpr, .loc = loc },
            .expression = expression,
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
    ArrayLiteral: *ArrayLiteral,
    Identifier: Identifier,
    BinaryExpr: *BinaryExpr,
    UnaryExpr: *UnaryExpr,
    AssignmentExpr: *AssignmentExpr,
    CallExpr: *CallExpr,
    TryExpr: *TryExpr,
    IndexExpr: *IndexExpr,
    MemberExpr: *MemberExpr,
    RangeExpr: *RangeExpr,
    SliceExpr: *SliceExpr,
    TernaryExpr: *TernaryExpr,
    PipeExpr: *PipeExpr,
    SpreadExpr: *SpreadExpr,
    NullCoalesceExpr: *NullCoalesceExpr,
    SafeNavExpr: *SafeNavExpr,
    TupleExpr: *TupleExpr,
    GenericTypeExpr: *GenericTypeExpr,
    AwaitExpr: *AwaitExpr,
    LetDecl: void,
    ConstDecl: void,
    FnDecl: void,
    StructDecl: void,
    EnumDecl: void,
    TypeAliasDecl: void,
    UnionDecl: void,
    ReturnStmt: void,
    IfStmt: void,
    WhileStmt: void,
    DoWhileStmt: void,
    ForStmt: void,
    SwitchStmt: void,
    CaseClause: void,
    TryStmt: void,
    CatchClause: void,
    DeferStmt: void,
    BlockStmt: void,
    ExprStmt: void,
    Program: void,

    pub fn getLocation(self: Expr) SourceLocation {
        return switch (self) {
            .IntegerLiteral => |lit| lit.node.loc,
            .FloatLiteral => |lit| lit.node.loc,
            .StringLiteral => |lit| lit.node.loc,
            .BooleanLiteral => |lit| lit.node.loc,
            .ArrayLiteral => |lit| lit.node.loc,
            .Identifier => |id| id.node.loc,
            .BinaryExpr => |expr| expr.node.loc,
            .UnaryExpr => |expr| expr.node.loc,
            .AssignmentExpr => |expr| expr.node.loc,
            .CallExpr => |expr| expr.node.loc,
            .TryExpr => |expr| expr.node.loc,
            .IndexExpr => |expr| expr.node.loc,
            .MemberExpr => |expr| expr.node.loc,
            .RangeExpr => |expr| expr.node.loc,
            .SliceExpr => |expr| expr.node.loc,
            .TernaryExpr => |expr| expr.node.loc,
            .PipeExpr => |expr| expr.node.loc,
            .SpreadExpr => |expr| expr.node.loc,
            .NullCoalesceExpr => |expr| expr.node.loc,
            .SafeNavExpr => |expr| expr.node.loc,
            .TupleExpr => |expr| expr.node.loc,
            .GenericTypeExpr => |expr| expr.node.loc,
            .AwaitExpr => |expr| expr.node.loc,
            else => std.debug.panic("getLocation called on non-expression variant: {s}", .{@tagName(self)}),
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

/// While statement
pub const WhileStmt = struct {
    node: Node,
    condition: *Expr,
    body: *BlockStmt,

    pub fn init(allocator: std.mem.Allocator, condition: *Expr, body: *BlockStmt, loc: SourceLocation) !*WhileStmt {
        const stmt = try allocator.create(WhileStmt);
        stmt.* = .{
            .node = .{ .type = .WhileStmt, .loc = loc },
            .condition = condition,
            .body = body,
        };
        return stmt;
    }
};

/// For statement
pub const ForStmt = struct {
    node: Node,
    iterator: []const u8,
    iterable: *Expr,
    body: *BlockStmt,

    pub fn init(allocator: std.mem.Allocator, iterator: []const u8, iterable: *Expr, body: *BlockStmt, loc: SourceLocation) !*ForStmt {
        const stmt = try allocator.create(ForStmt);
        stmt.* = .{
            .node = .{ .type = .ForStmt, .loc = loc },
            .iterator = iterator,
            .iterable = iterable,
            .body = body,
        };
        return stmt;
    }
};

/// Do-while statement (do { ... } while condition)
pub const DoWhileStmt = struct {
    node: Node,
    body: *BlockStmt,
    condition: *Expr,

    pub fn init(allocator: std.mem.Allocator, body: *BlockStmt, condition: *Expr, loc: SourceLocation) !*DoWhileStmt {
        const stmt = try allocator.create(DoWhileStmt);
        stmt.* = .{
            .node = .{ .type = .DoWhileStmt, .loc = loc },
            .body = body,
            .condition = condition,
        };
        return stmt;
    }
};

/// Case clause for switch statement
pub const CaseClause = struct {
    node: Node,
    patterns: []const *Expr, // Can match multiple patterns
    body: []const Stmt,
    is_default: bool,

    pub fn init(allocator: std.mem.Allocator, patterns: []const *Expr, body: []const Stmt, is_default: bool, loc: SourceLocation) !*CaseClause {
        const clause = try allocator.create(CaseClause);
        clause.* = .{
            .node = .{ .type = .CaseClause, .loc = loc },
            .patterns = patterns,
            .body = body,
            .is_default = is_default,
        };
        return clause;
    }
};

/// Switch statement (switch value { case 1: ..., default: ... })
pub const SwitchStmt = struct {
    node: Node,
    value: *Expr,
    cases: []const *CaseClause,

    pub fn init(allocator: std.mem.Allocator, value: *Expr, cases: []const *CaseClause, loc: SourceLocation) !*SwitchStmt {
        const stmt = try allocator.create(SwitchStmt);
        stmt.* = .{
            .node = .{ .type = .SwitchStmt, .loc = loc },
            .value = value,
            .cases = cases,
        };
        return stmt;
    }
};

/// Catch clause for try statement
pub const CatchClause = struct {
    node: Node,
    error_name: ?[]const u8, // null for catch-all
    body: *BlockStmt,

    pub fn init(allocator: std.mem.Allocator, error_name: ?[]const u8, body: *BlockStmt, loc: SourceLocation) !*CatchClause {
        const clause = try allocator.create(CatchClause);
        clause.* = .{
            .node = .{ .type = .CatchClause, .loc = loc },
            .error_name = error_name,
            .body = body,
        };
        return clause;
    }
};

/// Try-catch-finally statement
pub const TryStmt = struct {
    node: Node,
    try_block: *BlockStmt,
    catch_clauses: []const *CatchClause,
    finally_block: ?*BlockStmt,

    pub fn init(allocator: std.mem.Allocator, try_block: *BlockStmt, catch_clauses: []const *CatchClause, finally_block: ?*BlockStmt, loc: SourceLocation) !*TryStmt {
        const stmt = try allocator.create(TryStmt);
        stmt.* = .{
            .node = .{ .type = .TryStmt, .loc = loc },
            .try_block = try_block,
            .catch_clauses = catch_clauses,
            .finally_block = finally_block,
        };
        return stmt;
    }
};

/// Defer statement (defer expr)
pub const DeferStmt = struct {
    node: Node,
    body: *Expr,

    pub fn init(allocator: std.mem.Allocator, body: *Expr, loc: SourceLocation) !*DeferStmt {
        const stmt = try allocator.create(DeferStmt);
        stmt.* = .{
            .node = .{ .type = .DeferStmt, .loc = loc },
            .body = body,
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
    ArrayLiteral: void,
    Identifier: void,
    BinaryExpr: void,
    UnaryExpr: void,
    AssignmentExpr: void,
    CallExpr: void,
    TryExpr: void,
    IndexExpr: void,
    MemberExpr: void,
    RangeExpr: void,
    SliceExpr: void,
    TernaryExpr: void,
    PipeExpr: void,
    SpreadExpr: void,
    NullCoalesceExpr: void,
    SafeNavExpr: void,
    TupleExpr: void,
    GenericTypeExpr: void,
    AwaitExpr: void,

    // Statement variants (order must match NodeType enum)
    LetDecl: *LetDecl,
    ConstDecl: void,
    FnDecl: *FnDecl,
    StructDecl: *StructDecl,
    EnumDecl: *EnumDecl,
    TypeAliasDecl: *TypeAliasDecl,
    UnionDecl: *UnionDecl,
    ReturnStmt: *ReturnStmt,
    IfStmt: *IfStmt,
    WhileStmt: *WhileStmt,
    DoWhileStmt: *DoWhileStmt,
    ForStmt: *ForStmt,
    SwitchStmt: *SwitchStmt,
    CaseClause: *CaseClause,
    TryStmt: *TryStmt,
    CatchClause: *CatchClause,
    DeferStmt: *DeferStmt,
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

/// Struct field
pub const StructField = struct {
    name: []const u8,
    type_name: []const u8,
    loc: SourceLocation,
};

/// Struct declaration
pub const StructDecl = struct {
    node: Node,
    name: []const u8,
    fields: []const StructField,
    type_params: []const []const u8, // Generic type parameters e.g. ["T", "E"]

    pub fn init(allocator: std.mem.Allocator, name: []const u8, fields: []const StructField, type_params: []const []const u8, loc: SourceLocation) !*StructDecl {
        const decl = try allocator.create(StructDecl);
        decl.* = .{
            .node = .{ .type = .StructDecl, .loc = loc },
            .name = name,
            .fields = fields,
            .type_params = type_params,
        };
        return decl;
    }

    pub fn isGeneric(self: *const StructDecl) bool {
        return self.type_params.len > 0;
    }
};

/// Enum variant
pub const EnumVariant = struct {
    name: []const u8,
    data_type: ?[]const u8, // Optional associated data type
};

/// Enum declaration
pub const EnumDecl = struct {
    node: Node,
    name: []const u8,
    variants: []const EnumVariant,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, variants: []const EnumVariant, loc: SourceLocation) !*EnumDecl {
        const decl = try allocator.create(EnumDecl);
        decl.* = .{
            .node = .{ .type = .EnumDecl, .loc = loc },
            .name = name,
            .variants = variants,
        };
        return decl;
    }
};

/// Union variant (like enum with data)
pub const UnionVariant = struct {
    name: []const u8,
    type_name: ?[]const u8, // Type of the variant's data
};

/// Union declaration (discriminated union)
pub const UnionDecl = struct {
    node: Node,
    name: []const u8,
    variants: []const UnionVariant,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, variants: []const UnionVariant, loc: SourceLocation) !*UnionDecl {
        const decl = try allocator.create(UnionDecl);
        decl.* = .{
            .node = .{ .type = .UnionDecl, .loc = loc },
            .name = name,
            .variants = variants,
        };
        return decl;
    }
};

/// Type alias declaration
pub const TypeAliasDecl = struct {
    node: Node,
    name: []const u8,
    target_type: []const u8,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, target_type: []const u8, loc: SourceLocation) !*TypeAliasDecl {
        const decl = try allocator.create(TypeAliasDecl);
        decl.* = .{
            .node = .{ .type = .TypeAliasDecl, .loc = loc },
            .name = name,
            .target_type = target_type,
        };
        return decl;
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
    type_params: []const []const u8, // Generic type parameters e.g. ["T", "U"]

    pub fn init(allocator: std.mem.Allocator, name: []const u8, params: []const Parameter, return_type: ?[]const u8, body: *BlockStmt, is_async: bool, type_params: []const []const u8, loc: SourceLocation) !*FnDecl {
        const decl = try allocator.create(FnDecl);
        decl.* = .{
            .node = .{ .type = .FnDecl, .loc = loc },
            .name = name,
            .params = params,
            .return_type = return_type,
            .body = body,
            .is_async = is_async,
            .type_params = type_params,
        };
        return decl;
    }

    pub fn isGeneric(self: *const FnDecl) bool {
        return self.type_params.len > 0;
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

    pub fn deinitStmt(stmt: Stmt, allocator: std.mem.Allocator) void {
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
            .StructDecl => |decl| {
                allocator.free(decl.fields);
                allocator.destroy(decl);
            },
            .EnumDecl => |decl| {
                allocator.free(decl.variants);
                allocator.destroy(decl);
            },
            .TypeAliasDecl => |decl| {
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
            .WhileStmt => |while_stmt| {
                deinitExpr(while_stmt.condition, allocator);
                deinitBlockStmt(while_stmt.body, allocator);
                allocator.destroy(while_stmt);
            },
            .ForStmt => |for_stmt| {
                deinitExpr(for_stmt.iterable, allocator);
                deinitBlockStmt(for_stmt.body, allocator);
                allocator.destroy(for_stmt);
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

    pub fn deinitBlockStmt(block: *BlockStmt, allocator: std.mem.Allocator) void {
        for (block.statements) |stmt| {
            deinitStmt(stmt, allocator);
        }
        allocator.free(block.statements);
        allocator.destroy(block);
    }

    pub fn deinitExpr(expr: *Expr, allocator: std.mem.Allocator) void {
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
            .AssignmentExpr => |assign| {
                deinitExpr(assign.target, allocator);
                deinitExpr(assign.value, allocator);
                allocator.destroy(assign);
            },
            .CallExpr => |call| {
                deinitExpr(call.callee, allocator);
                for (call.args) |arg| {
                    deinitExpr(arg, allocator);
                }
                allocator.free(call.args);
                allocator.destroy(call);
            },
            .ArrayLiteral => |array| {
                for (array.elements) |elem| {
                    deinitExpr(elem, allocator);
                }
                allocator.free(array.elements);
                allocator.destroy(array);
            },
            .IndexExpr => |index| {
                deinitExpr(index.array, allocator);
                deinitExpr(index.index, allocator);
                allocator.destroy(index);
            },
            .MemberExpr => |member| {
                deinitExpr(member.object, allocator);
                allocator.destroy(member);
            },
            .RangeExpr => |range| {
                deinitExpr(range.start, allocator);
                deinitExpr(range.end, allocator);
                allocator.destroy(range);
            },
            .SliceExpr => |slice| {
                deinitExpr(slice.array, allocator);
                if (slice.start) |start| deinitExpr(start, allocator);
                if (slice.end) |end| deinitExpr(end, allocator);
                allocator.destroy(slice);
            },
            else => {},
        }
        allocator.destroy(expr);
    }
};
