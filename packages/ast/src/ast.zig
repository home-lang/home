const std = @import("std");
const Token = @import("lexer").Token;

// Export attribute-related AST nodes
pub const attribute_nodes = @import("attribute_nodes.zig");
pub const Attribute = attribute_nodes.Attribute;
pub const AttributeList = attribute_nodes.AttributeList;
pub const AttributeName = attribute_nodes.AttributeName;

// Export trait-related AST nodes
pub const trait_nodes = @import("trait_nodes.zig");
pub const TraitDecl = trait_nodes.TraitDecl;
pub const ImplDecl = trait_nodes.ImplDecl;
pub const TraitMethod = trait_nodes.TraitMethod;
pub const AssociatedType = trait_nodes.AssociatedType;
pub const WhereClause = trait_nodes.WhereClause;
pub const WhereBound = trait_nodes.WhereBound;
pub const GenericParam = trait_nodes.GenericParam;
pub const TypeExpr = trait_nodes.TypeExpr;
pub const FnParam = trait_nodes.FnParam;

// Export closure-related AST nodes
pub const closure_nodes = @import("closure_nodes.zig");
pub const ClosureExpr = closure_nodes.ClosureExpr;
pub const ClosureParam = closure_nodes.ClosureParam;
pub const ClosureBody = closure_nodes.ClosureBody;
pub const Capture = closure_nodes.Capture;
pub const ClosureTrait = closure_nodes.ClosureTrait;
pub const ClosureEnvironment = closure_nodes.ClosureEnvironment;
pub const ClosureAnalysis = closure_nodes.ClosureAnalysis;

// Export variadic-related AST nodes
pub const variadic_nodes = @import("variadic_nodes.zig");
pub const VariadicParam = variadic_nodes.VariadicParam;
pub const SpreadArg = variadic_nodes.SpreadArg;
pub const VariadicCall = variadic_nodes.VariadicCall;
pub const VariadicInfo = variadic_nodes.VariadicInfo;
pub const BuiltinVariadic = variadic_nodes.BuiltinVariadic;

// Export parameter-related AST nodes
pub const parameter_nodes = @import("parameter_nodes.zig");
pub const EnhancedParameter = parameter_nodes.EnhancedParameter;
pub const NamedArgument = parameter_nodes.NamedArgument;
pub const EnhancedCallExpr = parameter_nodes.EnhancedCallExpr;
pub const ParameterConfig = parameter_nodes.ParameterConfig;
pub const ArgumentMatch = parameter_nodes.ArgumentMatch;
pub const ArgumentResolver = parameter_nodes.ArgumentResolver;
pub const ParameterValidator = parameter_nodes.ParameterValidator;
pub const BuiltinDefaults = parameter_nodes.BuiltinDefaults;

// Export struct literal nodes
pub const struct_literal_nodes = @import("struct_literal_nodes.zig");
pub const StructLiteralExpr = struct_literal_nodes.StructLiteralExpr;
pub const FieldInit = struct_literal_nodes.FieldInit;
pub const StructUpdate = struct_literal_nodes.StructUpdate;
pub const TupleStructLiteral = struct_literal_nodes.TupleStructLiteral;
pub const AnonymousStruct = struct_literal_nodes.AnonymousStruct;
pub const FieldPunning = struct_literal_nodes.FieldPunning;
pub const StructLiteralPattern = struct_literal_nodes.StructLiteralPattern;
pub const StructLiteralBuilder = struct_literal_nodes.StructLiteralBuilder;

// Export comprehension nodes
pub const comprehension_nodes = @import("comprehension_nodes.zig");
pub const ArrayComprehension = comprehension_nodes.ArrayComprehension;
pub const DictComprehension = comprehension_nodes.DictComprehension;
pub const SetComprehension = comprehension_nodes.SetComprehension;
pub const NestedComprehension = comprehension_nodes.NestedComprehension;
pub const ComprehensionClause = comprehension_nodes.ComprehensionClause;
pub const GeneratorExpr = comprehension_nodes.GeneratorExpr;
pub const ComprehensionDesugarer = comprehension_nodes.ComprehensionDesugarer;
pub const ComprehensionTypeInference = comprehension_nodes.ComprehensionTypeInference;
pub const ComprehensionPattern = comprehension_nodes.ComprehensionPattern;

// Export splat/spread nodes
pub const splat_nodes = @import("splat_nodes.zig");
pub const SplatExpr = splat_nodes.SplatExpr;
pub const RestPattern = splat_nodes.RestPattern;
pub const ArrayDestructuring = splat_nodes.ArrayDestructuring;
pub const ObjectDestructuring = splat_nodes.ObjectDestructuring;
pub const SplatParameter = splat_nodes.SplatParameter;
pub const ArraySplat = splat_nodes.ArraySplat;
pub const CallWithSplat = splat_nodes.CallWithSplat;
pub const SplatValidator = splat_nodes.SplatValidator;
pub const SplatDesugarer = splat_nodes.SplatDesugarer;
pub const SplatPattern = splat_nodes.SplatPattern;

// Export multiple dispatch nodes
pub const dispatch_nodes = @import("dispatch_nodes.zig");
pub const MultiDispatchFn = dispatch_nodes.MultiDispatchFn;
pub const DispatchParam = dispatch_nodes.DispatchParam;
pub const DispatchTable = dispatch_nodes.DispatchTable;
pub const DispatchResolver = dispatch_nodes.DispatchResolver;
pub const DispatchCall = dispatch_nodes.DispatchCall;
pub const DispatchAmbiguity = dispatch_nodes.DispatchAmbiguity;
pub const DispatchValidator = dispatch_nodes.DispatchValidator;
pub const DispatchPattern = dispatch_nodes.DispatchPattern;

/// Enumeration of all Abstract Syntax Tree node types in Home.
///
/// This enum categorizes every kind of AST node that can appear in an
/// Home program. Each NodeType corresponds to a specific struct that
/// implements that node's data and behavior.
///
/// Categories:
/// - Literals: Constant values (integers, strings, booleans, arrays)
/// - Expressions: Computations that produce values
/// - Statements: Actions and declarations
/// - Special: Program root and control flow constructs
pub const NodeType = enum {
    // Literals
    IntegerLiteral,
    FloatLiteral,
    StringLiteral,
    InterpolatedString,
    BooleanLiteral,
    NullLiteral,
    ArrayLiteral,
    MapLiteral,

    // Identifiers
    Identifier,

    // Expressions
    BinaryExpr,
    UnaryExpr,
    AssignmentExpr,
    CallExpr,
    StaticCallExpr,
    TryExpr,
    TypeCastExpr,
    IndexExpr,
    MemberExpr,
    RangeExpr,
    SliceExpr,
    TernaryExpr,
    PipeExpr,
    SpreadExpr,
    NullCoalesceExpr,
    SafeNavExpr,
    ElvisExpr,
    SafeIndexExpr,
    IfExpr,
    MatchExpr,
    TupleExpr,
    GenericTypeExpr,
    AwaitExpr,
    ComptimeExpr,
    ReflectExpr,
    MacroExpr,
    InlineAsm,
    ClosureExpr,
    StructLiteral,
    TupleStructLiteral,
    AnonymousStruct,
    ArrayComprehension,
    DictComprehension,
    SetComprehension,
    NestedComprehension,
    GeneratorExpr,
    SplatExpr,
    ArrayDestructuring,
    ObjectDestructuring,
    DispatchCall,

    // Statements
    ImportDecl,
    LetDecl,
    ConstDecl,
    FnDecl,
    ItTestDecl,
    StructDecl,
    EnumDecl,
    TypeAliasDecl,
    UnionDecl,
    TraitDecl,
    ImplDecl,
    ReturnStmt,
    IfStmt,
    WhileStmt,
    DoWhileStmt,
    ForStmt,
    SwitchStmt,
    CaseClause,
    MatchStmt,
    MatchArm,
    TryStmt,
    CatchClause,
    DeferStmt,
    BlockStmt,
    ExprStmt,
    BreakStmt,
    ContinueStmt,

    // Program
    Program,
};

/// Source code location for error reporting and debugging.
///
/// Every AST node tracks its position in the source file to enable
/// helpful error messages with line and column numbers.
pub const SourceLocation = struct {
    /// Line number in source file (1-indexed)
    line: usize,
    /// Column number in source line (1-indexed)
    column: usize,

    /// Create a SourceLocation from a Token.
    ///
    /// Extracts location information from a lexer token.
    ///
    /// Parameters:
    ///   - token: Token to extract location from
    ///
    /// Returns: SourceLocation with token's position
    pub fn fromToken(token: Token) SourceLocation {
        return .{
            .line = token.line,
            .column = token.column,
        };
    }
};

/// Base node structure shared by all AST nodes.
///
/// Every AST node embeds this structure to provide common metadata:
/// - The specific type of node (for runtime type checking)
/// - Source location for error reporting
///
/// This enables polymorphic handling of AST nodes while maintaining
/// type safety through the NodeType tag.
pub const Node = struct {
    /// The specific kind of AST node
    type: NodeType,
    /// Source code location where this node appears
    loc: SourceLocation,
};

/// Integer literal expression.
///
/// Represents a constant integer value in the source code.
/// Currently supports 64-bit signed integers.
///
/// Example: `42`, `-17`, `0`
pub const IntegerLiteral = struct {
    /// Base node metadata
    node: Node,
    /// The integer value
    value: i64,
    /// Optional type suffix (e.g., "i32", "u64")
    type_suffix: ?[]const u8 = null,

    /// Create a new integer literal node.
    ///
    /// Parameters:
    ///   - value: The integer value
    ///   - loc: Source location
    ///
    /// Returns: Initialized IntegerLiteral
    pub fn init(value: i64, loc: SourceLocation) IntegerLiteral {
        return .{
            .node = .{ .type = .IntegerLiteral, .loc = loc },
            .value = value,
            .type_suffix = null,
        };
    }

    /// Create a new integer literal node with a type suffix.
    ///
    /// Parameters:
    ///   - value: The integer value
    ///   - type_suffix: The type suffix (e.g., "i32", "u64")
    ///   - loc: Source location
    ///
    /// Returns: Initialized IntegerLiteral with type suffix
    pub fn initWithType(value: i64, type_suffix: ?[]const u8, loc: SourceLocation) IntegerLiteral {
        return .{
            .node = .{ .type = .IntegerLiteral, .loc = loc },
            .value = value,
            .type_suffix = type_suffix,
        };
    }
};

/// Floating-point literal expression.
///
/// Represents a constant floating-point value using IEEE 754
/// double-precision (64-bit) format.
///
/// Example: `3.14`, `0.5`, `2.0`
pub const FloatLiteral = struct {
    /// Base node metadata
    node: Node,
    /// The floating-point value
    value: f64,
    /// Optional type suffix (e.g., "f32", "f64")
    type_suffix: ?[]const u8 = null,

    /// Create a new float literal node.
    ///
    /// Parameters:
    ///   - value: The floating-point value
    ///   - loc: Source location
    ///
    /// Returns: Initialized FloatLiteral
    pub fn init(value: f64, loc: SourceLocation) FloatLiteral {
        return .{
            .node = .{ .type = .FloatLiteral, .loc = loc },
            .value = value,
            .type_suffix = null,
        };
    }

    /// Create a new float literal node with a type suffix.
    ///
    /// Parameters:
    ///   - value: The floating-point value
    ///   - type_suffix: The type suffix (e.g., "f32", "f64")
    ///   - loc: Source location
    ///
    /// Returns: Initialized FloatLiteral with type suffix
    pub fn initWithType(value: f64, type_suffix: ?[]const u8, loc: SourceLocation) FloatLiteral {
        return .{
            .node = .{ .type = .FloatLiteral, .loc = loc },
            .value = value,
            .type_suffix = type_suffix,
        };
    }
};

/// String literal expression.
///
/// Represents a constant string value. The value slice includes
/// the surrounding quotes and any escape sequences as they appear
/// in source. Escape sequences are processed during interpretation.
///
/// Example: `"hello"`, `"world\n"`, `"foo\u{1F600}"`
pub const StringLiteral = struct {
    /// Base node metadata
    node: Node,
    /// The string value (with quotes and raw escapes)
    value: []const u8,

    /// Create a new string literal node.
    ///
    /// Parameters:
    ///   - value: The string slice (must remain valid)
    ///   - loc: Source location
    ///
    /// Returns: Initialized StringLiteral
    pub fn init(value: []const u8, loc: SourceLocation) StringLiteral {
        return .{
            .node = .{ .type = .StringLiteral, .loc = loc },
            .value = value,
        };
    }
};

/// Interpolated string expression.
///
/// Represents a string with embedded expressions using {} syntax.
/// The lexer produces StringInterpolationStart, StringInterpolationMid,
/// and StringInterpolationEnd tokens which the parser combines into
/// this AST node containing alternating string parts and expressions.
///
/// Example: `"Hello {name}!"` -> parts=["Hello ", "!"], exprs=[name_expr]
pub const InterpolatedString = struct {
    /// Base node metadata
    node: Node,
    /// String parts (literal text between expressions)
    parts: [][]const u8,
    /// Expressions to interpolate
    expressions: []Expr,

    /// Create a new interpolated string node.
    ///
    /// Parameters:
    ///   - parts: Array of string literal parts
    ///   - expressions: Array of expressions to interpolate
    ///   - loc: Source location
    ///
    /// Returns: Initialized InterpolatedString
    pub fn init(parts: [][]const u8, expressions: []Expr, loc: SourceLocation) InterpolatedString {
        return .{
            .node = .{ .type = .InterpolatedString, .loc = loc },
            .parts = parts,
            .expressions = expressions,
        };
    }
};

/// Boolean literal expression.
///
/// Represents the constant values `true` or `false`.
///
/// Example: `true`, `false`
pub const BooleanLiteral = struct {
    /// Base node metadata
    node: Node,
    /// The boolean value
    value: bool,

    /// Create a new boolean literal node.
    ///
    /// Parameters:
    ///   - value: The boolean value (true or false)
    ///   - loc: Source location
    ///
    /// Returns: Initialized BooleanLiteral
    pub fn init(value: bool, loc: SourceLocation) BooleanLiteral {
        return .{
            .node = .{ .type = .BooleanLiteral, .loc = loc },
            .value = value,
        };
    }
};

/// Null literal expression.
///
/// Represents the null value.
pub const NullLiteral = struct {
    /// Base node metadata
    node: Node,

    /// Create a new null literal node.
    pub fn init(loc: SourceLocation) NullLiteral {
        return .{
            .node = .{ .type = .NullLiteral, .loc = loc },
        };
    }
};

/// Identifier expression.
///
/// Represents a variable or function name. Identifiers are resolved
/// during semantic analysis to determine what they refer to.
///
/// Example: `x`, `foo`, `_temp`, `myVariable123`
pub const Identifier = struct {
    /// Base node metadata
    node: Node,
    /// The identifier name (without any qualification)
    name: []const u8,

    /// Create a new identifier node.
    ///
    /// Parameters:
    ///   - name: The identifier name (must remain valid)
    ///   - loc: Source location
    ///
    /// Returns: Initialized Identifier
    pub fn init(name: []const u8, loc: SourceLocation) Identifier {
        return .{
            .node = .{ .type = .Identifier, .loc = loc },
            .name = name,
        };
    }
};

/// Inline assembly expression.
///
/// Represents raw assembly code that should be emitted directly into
/// the generated output. Used for low-level operations like CPU instructions,
/// I/O port access, and other hardware-specific operations in kernel code.
///
/// Example: `asm("cli")`, `asm("hlt")`, `asm("outb %al, %dx")`
pub const InlineAsm = struct {
    /// Base node metadata
    node: Node,
    /// The assembly instruction string (without quotes)
    instruction: []const u8,

    /// Create a new inline assembly node.
    ///
    /// Parameters:
    ///   - instruction: The assembly instruction string (must remain valid)
    ///   - loc: Source location
    ///
    /// Returns: Initialized InlineAsm
    pub fn init(instruction: []const u8, loc: SourceLocation) InlineAsm {
        return .{
            .node = .{ .type = .InlineAsm, .loc = loc },
            .instruction = instruction,
        };
    }
};

/// Binary operator types for expressions.
///
/// These operators combine two operands to produce a result.
/// Includes arithmetic, comparison, logical, bitwise, and assignment operators.
///
/// Precedence and associativity are handled by the parser using
/// the Precedence enum in parser.zig.
pub const BinaryOp = enum {
    Add, // +
    Sub, // -
    Mul, // *
    Div, // /
    IntDiv, // ~/ (integer division)
    Mod, // %
    Power, // ** (exponentiation)
    Equal, // ==
    NotEqual, // !=
    Less, // <
    LessEq, // <=
    Greater, // >
    GreaterEq, // >=
    And, // &&
    Or, // ||
    BitAnd, // &
    BitOr, // |
    BitXor, // ^
    LeftShift, // <<
    RightShift, // >>
    Assign, // =
};

/// Binary expression combining two operands with an operator.
///
/// Represents operations like `a + b`, `x == y`, `foo && bar`.
/// The operands are full expressions that are evaluated before
/// applying the operator.
///
/// Examples:
/// - `2 + 3` (arithmetic)
/// - `x < 10` (comparison)
/// - `a && b` (logical)
/// - `flags | mask` (bitwise)
pub const BinaryExpr = struct {
    /// Base node metadata
    node: Node,
    /// The binary operator
    op: BinaryOp,
    /// Left operand expression
    left: *Expr,
    /// Right operand expression
    right: *Expr,

    /// Create a new binary expression node.
    ///
    /// Parameters:
    ///   - allocator: Allocator for the node
    ///   - op: Binary operator
    ///   - left: Left operand (owned by this node)
    ///   - right: Right operand (owned by this node)
    ///   - loc: Source location
    ///
    /// Returns: Pointer to allocated BinaryExpr
    /// Errors: OutOfMemory if allocation fails
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

/// Unary operator types for expressions.
///
/// These operators apply to a single operand.
pub const UnaryOp = enum {
    /// Negation: `-x` (arithmetic negation)
    Neg,
    /// Logical NOT: `!x` (boolean negation)
    Not,
    /// Bitwise NOT: `~x` (bitwise complement)
    BitNot,
    /// Dereference: `*ptr` (load value from pointer)
    Deref,
    /// Address-of: `&var` (get address of variable)
    AddressOf,
};

/// Unary expression applying an operator to a single operand.
///
/// Represents operations like `-x` (negation) or `!flag` (NOT).
///
/// Examples:
/// - `-42` (numeric negation)
/// - `!is_valid` (logical NOT)
pub const UnaryExpr = struct {
    /// Base node metadata
    node: Node,
    /// The unary operator
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

/// Named argument in function call (for named parameter support)
pub const NamedArg = struct {
    name: []const u8,
    value: *Expr,
};

/// Call expression
pub const CallExpr = struct {
    node: Node,
    callee: *Expr,
    args: []const *Expr,
    /// Named arguments (empty if none provided)
    named_args: []const NamedArg = &.{},

    pub fn init(allocator: std.mem.Allocator, callee: *Expr, args: []const *Expr, loc: SourceLocation) !*CallExpr {
        const expr = try allocator.create(CallExpr);
        expr.* = .{
            .node = .{ .type = .CallExpr, .loc = loc },
            .callee = callee,
            .args = args,
            .named_args = &.{},
        };
        return expr;
    }

    pub fn initWithNamedArgs(allocator: std.mem.Allocator, callee: *Expr, args: []const *Expr, named_args: []const NamedArg, loc: SourceLocation) !*CallExpr {
        const expr = try allocator.create(CallExpr);
        expr.* = .{
            .node = .{ .type = .CallExpr, .loc = loc },
            .callee = callee,
            .args = args,
            .named_args = named_args,
        };
        return expr;
    }
};

/// Static method call expression (Type::method())
///
/// Represents a call to a static/associated method on a type,
/// using the double-colon syntax common in Rust-like languages.
/// Example: HashMap::new(), Vec::with_capacity(10)
pub const StaticCallExpr = struct {
    node: Node,
    type_name: []const u8,
    method_name: []const u8,
    args: []const *Expr,

    pub fn init(allocator: std.mem.Allocator, type_name: []const u8, method_name: []const u8, args: []const *Expr, loc: SourceLocation) !*StaticCallExpr {
        const expr = try allocator.create(StaticCallExpr);
        expr.* = .{
            .node = .{ .type = .StaticCallExpr, .loc = loc },
            .type_name = type_name,
            .method_name = method_name,
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

/// Map/Dictionary literal entry
pub const MapEntry = struct {
    key: *Expr,
    value: *Expr,
};

/// Map/Dictionary literal expression.
///
/// Represents a dictionary/map literal with key-value pairs.
///
/// Example: `{"key": "value", "foo": 123}`
pub const MapLiteral = struct {
    node: Node,
    entries: []const MapEntry,

    pub fn init(allocator: std.mem.Allocator, entries: []const MapEntry, loc: SourceLocation) !*MapLiteral {
        const expr = try allocator.create(MapLiteral);
        expr.* = .{
            .node = .{ .type = .MapLiteral, .loc = loc },
            .entries = entries,
        };
        return expr;
    }
};

/// Type cast expression (value as Type)
pub const TypeCastExpr = struct {
    node: Node,
    value: *Expr,
    target_type: []const u8,

    pub fn init(allocator: std.mem.Allocator, value: *Expr, target_type: []const u8, loc: SourceLocation) !*TypeCastExpr {
        const expr = try allocator.create(TypeCastExpr);
        expr.* = .{
            .node = .{ .type = .TypeCastExpr, .loc = loc },
            .value = value,
            .target_type = target_type,
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

/// Elvis expression (value ?: default) - alias for null coalescing
pub const ElvisExpr = struct {
    node: Node,
    left: *Expr,
    right: *Expr,

    pub fn init(allocator: std.mem.Allocator, left: *Expr, right: *Expr, loc: SourceLocation) !*ElvisExpr {
        const expr = try allocator.create(ElvisExpr);
        expr.* = .{
            .node = .{ .type = .ElvisExpr, .loc = loc },
            .left = left,
            .right = right,
        };
        return expr;
    }
};

/// Safe index expression (array?[index]) - returns null if array is null or index out of bounds
pub const SafeIndexExpr = struct {
    node: Node,
    object: *Expr,
    index: *Expr,

    pub fn init(allocator: std.mem.Allocator, object: *Expr, index: *Expr, loc: SourceLocation) !*SafeIndexExpr {
        const expr = try allocator.create(SafeIndexExpr);
        expr.* = .{
            .node = .{ .type = .SafeIndexExpr, .loc = loc },
            .object = object,
            .index = index,
        };
        return expr;
    }
};

/// If expression - if as an expression that returns a value
/// Example: let x = if (cond) { value1 } else { value2 }
pub const IfExpr = struct {
    node: Node,
    condition: *Expr,
    then_branch: *Expr,
    else_branch: *Expr,

    pub fn init(allocator: std.mem.Allocator, condition: *Expr, then_branch: *Expr, else_branch: *Expr, loc: SourceLocation) !*IfExpr {
        const expr = try allocator.create(IfExpr);
        expr.* = .{
            .node = .{ .type = .IfExpr, .loc = loc },
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        };
        return expr;
    }
};

/// Match arm for match expressions
pub const MatchExprArm = struct {
    pattern: *Expr,
    guard: ?*Expr,
    body: *Expr,
};

/// Match expression - pattern matching as an expression
/// Example: let x = match value { Ok(v) => v, Err(_) => 0 }
pub const MatchExpr = struct {
    node: Node,
    value: *Expr,
    arms: []const MatchExprArm,

    pub fn init(allocator: std.mem.Allocator, value: *Expr, arms: []const MatchExprArm, loc: SourceLocation) !*MatchExpr {
        const expr = try allocator.create(MatchExpr);
        expr.* = .{
            .node = .{ .type = .MatchExpr, .loc = loc },
            .value = value,
            .arms = arms,
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

/// Comptime expression (comptime expr)
/// Evaluates expression at compile time
pub const ComptimeExpr = struct {
    node: Node,
    expression: *Expr,

    pub fn init(allocator: std.mem.Allocator, expression: *Expr, loc: SourceLocation) !*ComptimeExpr {
        const expr = try allocator.create(ComptimeExpr);
        expr.* = .{
            .node = .{ .type = .ComptimeExpr, .loc = loc },
            .expression = expression,
        };
        return expr;
    }
};

/// Reflection expression (@TypeOf, @sizeOf, @alignOf, @offsetOf, @typeInfo, @fieldName, @fieldType)
pub const ReflectExpr = struct {
    node: Node,
    kind: ReflectKind,
    target: *Expr,
    field_name: ?[]const u8, // For @offsetOf, @fieldName, @fieldType

    pub const ReflectKind = enum {
        TypeOf, // @TypeOf(expr) - returns type of expression
        SizeOf, // @sizeOf(Type) - returns size in bytes
        AlignOf, // @alignOf(Type) - returns alignment in bytes
        OffsetOf, // @offsetOf(Type, "field") - returns field offset
        TypeInfo, // @typeInfo(Type) - returns type metadata
        FieldName, // @fieldName(Type, index) - returns field name
        FieldType, // @fieldType(Type, "field") - returns field type
        IntFromPtr, // @intFromPtr(ptr) - convert pointer to integer
        PtrFromInt, // @ptrFromInt(int) - convert integer to pointer
        Truncate, // @truncate(value) - truncate to smaller type
        As, // @as(Type, value) - explicit type cast
        BitCast, // @bitCast(value) - reinterpret bits as different type
    };

    pub fn init(
        allocator: std.mem.Allocator,
        kind: ReflectKind,
        target: *Expr,
        field_name: ?[]const u8,
        loc: SourceLocation,
    ) !*ReflectExpr {
        const expr = try allocator.create(ReflectExpr);
        expr.* = .{
            .node = .{ .type = .ReflectExpr, .loc = loc },
            .kind = kind,
            .target = target,
            .field_name = field_name,
        };
        return expr;
    }
};

/// Macro expression (macro invocation with !)
/// Example: debug!("value = {}", value)
pub const MacroExpr = struct {
    node: Node,
    name: []const u8,
    args: []*Expr,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        args: []*Expr,
        loc: SourceLocation,
    ) !*MacroExpr {
        const expr = try allocator.create(MacroExpr);
        expr.* = .{
            .node = .{ .type = .MacroExpr, .loc = loc },
            .name = name,
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
    InterpolatedString: *InterpolatedString,
    BooleanLiteral: BooleanLiteral,
    NullLiteral: NullLiteral,
    ArrayLiteral: *ArrayLiteral,
    MapLiteral: *MapLiteral,
    Identifier: Identifier,
    BinaryExpr: *BinaryExpr,
    UnaryExpr: *UnaryExpr,
    AssignmentExpr: *AssignmentExpr,
    CallExpr: *CallExpr,
    StaticCallExpr: *StaticCallExpr,
    TryExpr: *TryExpr,
    TypeCastExpr: *TypeCastExpr,
    IndexExpr: *IndexExpr,
    MemberExpr: *MemberExpr,
    RangeExpr: *RangeExpr,
    SliceExpr: *SliceExpr,
    TernaryExpr: *TernaryExpr,
    PipeExpr: *PipeExpr,
    SpreadExpr: *SpreadExpr,
    NullCoalesceExpr: *NullCoalesceExpr,
    SafeNavExpr: *SafeNavExpr,
    ElvisExpr: *ElvisExpr,
    SafeIndexExpr: *SafeIndexExpr,
    IfExpr: *IfExpr,
    MatchExpr: *MatchExpr,
    TupleExpr: *TupleExpr,
    GenericTypeExpr: *GenericTypeExpr,
    AwaitExpr: *AwaitExpr,
    ComptimeExpr: *ComptimeExpr,
    ReflectExpr: *ReflectExpr,
    MacroExpr: *MacroExpr,
    InlineAsm: InlineAsm,
    ClosureExpr: *ClosureExpr,
    StructLiteral: *StructLiteralExpr,
    TupleStructLiteral: void,
    AnonymousStruct: void,
    ArrayComprehension: void,
    DictComprehension: void,
    SetComprehension: void,
    NestedComprehension: void,
    GeneratorExpr: void,
    SplatExpr: void,
    ArrayDestructuring: void,
    ObjectDestructuring: void,
    DispatchCall: void,
    ImportDecl: void,
    LetDecl: void,
    ConstDecl: void,
    FnDecl: void,
    ItTestDecl: void,
    StructDecl: void,
    EnumDecl: void,
    TypeAliasDecl: void,
    UnionDecl: void,
    TraitDecl: void,
    ImplDecl: void,
    ReturnStmt: void,
    IfStmt: void,
    WhileStmt: void,
    DoWhileStmt: void,
    ForStmt: void,
    SwitchStmt: void,
    CaseClause: void,
    MatchStmt: void,
    MatchArm: void,
    TryStmt: void,
    CatchClause: void,
    DeferStmt: void,
    BlockStmt: void,
    ExprStmt: void,
    BreakStmt: void,
    ContinueStmt: void,
    Program: void,

    pub fn getLocation(self: Expr) SourceLocation {
        return switch (self) {
            .IntegerLiteral => |lit| lit.node.loc,
            .FloatLiteral => |lit| lit.node.loc,
            .StringLiteral => |lit| lit.node.loc,
            .BooleanLiteral => |lit| lit.node.loc,
            .NullLiteral => |lit| lit.node.loc,
            .ArrayLiteral => |lit| lit.node.loc,
            .Identifier => |id| id.node.loc,
            .BinaryExpr => |expr| expr.node.loc,
            .UnaryExpr => |expr| expr.node.loc,
            .AssignmentExpr => |expr| expr.node.loc,
            .CallExpr => |expr| expr.node.loc,
            .StaticCallExpr => |expr| expr.node.loc,
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
            .ElvisExpr => |expr| expr.node.loc,
            .SafeIndexExpr => |expr| expr.node.loc,
            .IfExpr => |expr| expr.node.loc,
            .MatchExpr => |expr| expr.node.loc,
            .TupleExpr => |expr| expr.node.loc,
            .GenericTypeExpr => |expr| expr.node.loc,
            .AwaitExpr => |expr| expr.node.loc,
            .ClosureExpr => |expr| expr.node.loc,
            else => std.debug.panic("getLocation called on non-expression variant: {s}", .{@tagName(self)}),
        };
    }
};

/// Function parameter
pub const Parameter = struct {
    name: []const u8,
    type_name: []const u8,
    default_value: ?*Expr,
    loc: SourceLocation,
};

/// Import declaration
/// Represents an import statement like: import basics/os/serial
/// Supports aliasing: import basics/os/serial as Serial
pub const ImportDecl = struct {
    node: Node,
    /// Module path segments (e.g., ["basics", "os", "serial"])
    path: []const []const u8,
    /// Optional import list (e.g., { Serial, init })
    imports: ?[]const []const u8,
    /// Optional alias for the module (e.g., "as Serial")
    alias: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, path: []const []const u8, imports: ?[]const []const u8, alias: ?[]const u8, loc: SourceLocation) !*ImportDecl {
        const decl = try allocator.create(ImportDecl);
        decl.* = .{
            .node = .{ .type = .ImportDecl, .loc = loc },
            .path = path,
            .imports = imports,
            .alias = alias,
        };
        return decl;
    }
};

/// Let declaration
pub const LetDecl = struct {
    node: Node,
    name: []const u8,
    type_name: ?[]const u8,
    value: ?*Expr,
    is_mutable: bool,
    is_public: bool = false,

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
    /// Optional index variable for enumerate (e.g., for i, item in items)
    index: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, iterator: []const u8, iterable: *Expr, body: *BlockStmt, index: ?[]const u8, loc: SourceLocation) !*ForStmt {
        const stmt = try allocator.create(ForStmt);
        stmt.* = .{
            .node = .{ .type = .ForStmt, .loc = loc },
            .iterator = iterator,
            .iterable = iterable,
            .body = body,
            .index = index,
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

/// Pattern matching statement
/// match value {
///     Pattern1 => expr1,
///     Pattern2 if guard => expr2,
///     _ => default
/// }
pub const MatchStmt = struct {
    node: Node,
    value: *Expr,
    arms: []const *MatchArm,

    pub fn init(allocator: std.mem.Allocator, value: *Expr, arms: []const *MatchArm, loc: SourceLocation) !*MatchStmt {
        const stmt = try allocator.create(MatchStmt);
        stmt.* = .{
            .node = .{ .type = .MatchStmt, .loc = loc },
            .value = value,
            .arms = arms,
        };
        return stmt;
    }
};

/// Match arm with pattern and optional guard
pub const MatchArm = struct {
    node: Node,
    pattern: *Pattern,
    guard: ?*Expr, // Optional guard expression (if condition)
    body: *Expr, // Expression to evaluate if pattern matches

    pub fn init(
        allocator: std.mem.Allocator,
        pattern: *Pattern,
        guard: ?*Expr,
        body: *Expr,
        loc: SourceLocation,
    ) !*MatchArm {
        const arm = try allocator.create(MatchArm);
        arm.* = .{
            .node = .{ .type = .MatchArm, .loc = loc },
            .pattern = pattern,
            .guard = guard,
            .body = body,
        };
        return arm;
    }
};

/// Pattern for destructuring and pattern matching.
///
/// Patterns are used in match expressions and destructuring assignments
/// to match values and extract components. They support:
/// - Literal matching (exact value comparison)
/// - Variable binding (capture matched values)
/// - Structural destructuring (tuples, arrays, structs)
/// - Variant matching (enum pattern matching)
/// - Guards and or-patterns for complex conditions
///
/// Examples:
/// ```home
/// match value {
///   0 => "zero",                    // Literal pattern
///   x => "other",                   // Identifier binding
///   (a, b) => "tuple",              // Tuple destructure
///   [first, ...rest] => "array",    // Array with rest
///   Point { x, y } => "struct",     // Struct destructure
///   Some(v) => "variant",           // Enum variant
///   1..10 => "range",               // Range pattern
///   A | B | C => "alternatives",    // Or pattern
/// }
/// ```
pub const Pattern = union(enum) {
    // Literal patterns
    IntLiteral: i64,
    FloatLiteral: f64,
    StringLiteral: []const u8,
    BoolLiteral: bool,

    // Identifier pattern (binds variable)
    Identifier: []const u8,

    // Wildcard pattern (_)
    Wildcard,

    // Tuple pattern: (a, b, c)
    Tuple: []const *Pattern,

    // Array pattern: [a, b, c] or [head, ...tail]
    Array: struct {
        elements: []const *Pattern,
        rest: ?[]const u8, // For spread pattern
    },

    // Struct pattern: Point { x, y } or Point { x: px, y: py }
    Struct: struct {
        name: []const u8,
        fields: []const FieldPattern,
    },

    // Enum variant pattern: Some(value) or None
    EnumVariant: struct {
        variant: []const u8,
        payload: ?*Pattern,
    },

    // Range pattern: 1..10 or 'a'..'z'
    Range: struct {
        start: *Expr,
        end: *Expr,
        inclusive: bool,
    },

    // Or pattern: A | B | C
    Or: []const *Pattern,

    // As pattern: pattern @ identifier
    // Binds the matched value to a name while also matching the pattern
    // Example: Some(x) @ result => use both x and result
    As: struct {
        pattern: *Pattern,
        identifier: []const u8,
    },

    pub const FieldPattern = struct {
        name: []const u8,
        pattern: *Pattern,
        shorthand: bool, // true for { x } instead of { x: x }
    };
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

/// Break statement with optional label
/// Examples: break, break 'outer_loop
pub const BreakStmt = struct {
    node: Node,
    label: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, label: ?[]const u8, loc: SourceLocation) !*BreakStmt {
        const stmt = try allocator.create(BreakStmt);
        stmt.* = .{
            .node = .{ .type = .BreakStmt, .loc = loc },
            .label = label,
        };
        return stmt;
    }
};

/// Continue statement with optional label
/// Examples: continue, continue 'outer_loop
pub const ContinueStmt = struct {
    node: Node,
    label: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, label: ?[]const u8, loc: SourceLocation) !*ContinueStmt {
        const stmt = try allocator.create(ContinueStmt);
        stmt.* = .{
            .node = .{ .type = .ContinueStmt, .loc = loc },
            .label = label,
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
    InterpolatedString: void,
    BooleanLiteral: void,
    NullLiteral: void,
    ArrayLiteral: void,
    MapLiteral: void,
    Identifier: void,
    BinaryExpr: void,
    UnaryExpr: void,
    AssignmentExpr: void,
    CallExpr: void,
    StaticCallExpr: void,
    TryExpr: void,
    TypeCastExpr: void,
    IndexExpr: void,
    MemberExpr: void,
    RangeExpr: void,
    SliceExpr: void,
    TernaryExpr: void,
    PipeExpr: void,
    SpreadExpr: void,
    NullCoalesceExpr: void,
    SafeNavExpr: void,
    ElvisExpr: void,
    SafeIndexExpr: void,
    IfExpr: void,
    MatchExpr: void,
    TupleExpr: void,
    GenericTypeExpr: void,
    AwaitExpr: void,
    ComptimeExpr: void,
    ReflectExpr: void,
    MacroExpr: void,
    InlineAsm: void,
    ClosureExpr: void,
    StructLiteral: void,  // Handled via pointer deinit
    TupleStructLiteral: void,
    AnonymousStruct: void,
    ArrayComprehension: void,
    DictComprehension: void,
    SetComprehension: void,
    NestedComprehension: void,
    GeneratorExpr: void,
    SplatExpr: void,
    ArrayDestructuring: void,
    ObjectDestructuring: void,
    DispatchCall: void,

    // Statement variants (order must match NodeType enum)
    ImportDecl: *ImportDecl,
    LetDecl: *LetDecl,
    ConstDecl: void,
    FnDecl: *FnDecl,
    ItTestDecl: *ItTestDecl,
    StructDecl: *StructDecl,
    EnumDecl: *EnumDecl,
    TypeAliasDecl: *TypeAliasDecl,
    UnionDecl: *UnionDecl,
    TraitDecl: *TraitDecl,
    ImplDecl: *ImplDecl,
    ReturnStmt: *ReturnStmt,
    IfStmt: *IfStmt,
    WhileStmt: *WhileStmt,
    DoWhileStmt: *DoWhileStmt,
    ForStmt: *ForStmt,
    SwitchStmt: *SwitchStmt,
    CaseClause: *CaseClause,
    MatchStmt: *MatchStmt,
    MatchArm: *MatchArm,
    TryStmt: *TryStmt,
    CatchClause: *CatchClause,
    DeferStmt: *DeferStmt,
    BlockStmt: *BlockStmt,
    ExprStmt: *Expr,
    BreakStmt: *BreakStmt,
    ContinueStmt: *ContinueStmt,
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
    methods: []const *FnDecl = &.{}, // Methods defined inside struct body
    is_public: bool = false,
    attributes: []const Attribute = &.{},

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

    pub fn initWithMethods(allocator: std.mem.Allocator, name: []const u8, fields: []const StructField, type_params: []const []const u8, methods: []const *FnDecl, loc: SourceLocation) !*StructDecl {
        const decl = try allocator.create(StructDecl);
        decl.* = .{
            .node = .{ .type = .StructDecl, .loc = loc },
            .name = name,
            .fields = fields,
            .type_params = type_params,
            .methods = methods,
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
    is_public: bool = false,
    attributes: []const Attribute = &.{},

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
    is_public: bool = false,
    attributes: []const Attribute = &.{},

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
    is_public: bool = false,
    attributes: []const Attribute = &.{},

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
    type_params: []const []const u8,
    is_test: bool = false,
    is_public: bool = false,
    variadic_param: ?VariadicParam = null,
    attributes: []const Attribute = &.{}, // Attributes attached to this function

    pub fn init(allocator: std.mem.Allocator, name: []const u8, params: []const Parameter, return_type: ?[]const u8, body: *BlockStmt, is_async: bool, type_params: []const []const u8, is_test: bool, loc: SourceLocation) !*FnDecl {
        const decl = try allocator.create(FnDecl);
        decl.* = .{
            .node = .{ .type = .FnDecl, .loc = loc },
            .name = name,
            .params = params,
            .return_type = return_type,
            .body = body,
            .is_async = is_async,
            .type_params = type_params,
            .is_test = is_test,
        };
        return decl;
    }

    pub fn isGeneric(self: *const FnDecl) bool {
        return self.type_params.len > 0;
    }
};

/// Inline test declaration using it('description') syntax
/// Example: it('can add two numbers') { ... }
pub const ItTestDecl = struct {
    node: Node,
    description: []const u8,
    body: *BlockStmt,

    pub fn init(allocator: std.mem.Allocator, description: []const u8, body: *BlockStmt, loc: SourceLocation) !*ItTestDecl {
        const decl = try allocator.create(ItTestDecl);
        decl.* = .{
            .node = .{ .type = .ItTestDecl, .loc = loc },
            .description = description,
            .body = body,
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

    pub fn deinitStmt(stmt: Stmt, allocator: std.mem.Allocator) void {
        switch (stmt) {
            .ImportDecl => |decl| {
                allocator.free(decl.path);
                if (decl.imports) |imports| allocator.free(imports);
                allocator.destroy(decl);
            },
            .LetDecl => |decl| {
                if (decl.value) |val| deinitExpr(val, allocator);
                allocator.destroy(decl);
            },
            .FnDecl => |decl| {
                allocator.free(decl.params);
                deinitBlockStmt(decl.body, allocator);
                allocator.destroy(decl);
            },
            .ItTestDecl => |decl| {
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
