const std = @import("std");
const ast = @import("ast");
const type_system = @import("types");
const Type = type_system.Type;

/// Type-guided optimizations for code generation.
///
/// Uses inferred type information to apply optimizations:
/// - Constant folding with known types
/// - Specialized operations for concrete types
/// - Dead code elimination based on type analysis
/// - Strength reduction for numeric operations
pub const TypeGuidedOptimizer = struct {
    allocator: std.mem.Allocator,
    /// Map from variable names to their inferred types
    type_map: std.StringHashMap(*Type),
    /// Map from variable names to known constant values (for constant propagation)
    const_values: std.StringHashMap(ConstValue),

    pub const ConstValue = union(enum) {
        int: i64,
        float: f64,
        bool: bool,
        string: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) TypeGuidedOptimizer {
        return .{
            .allocator = allocator,
            .type_map = std.StringHashMap(*Type).init(allocator),
            .const_values = std.StringHashMap(ConstValue).init(allocator),
        };
    }

    pub fn deinit(self: *TypeGuidedOptimizer) void {
        self.type_map.deinit();
        self.const_values.deinit();
    }

    /// Add type information for a variable
    pub fn addTypeInfo(self: *TypeGuidedOptimizer, var_name: []const u8, ty: *Type) !void {
        try self.type_map.put(var_name, ty);
    }

    /// Check if an expression can be constant-folded
    pub fn canConstantFold(self: *TypeGuidedOptimizer, expr: *const ast.Expr) bool {
        return switch (expr.*) {
            .IntLiteral, .FloatLiteral, .BoolLiteral, .StringLiteral => true,
            .BinaryExpr => |bin| {
                // Can fold if both sides are constants
                return self.canConstantFold(bin.left) and self.canConstantFold(bin.right);
            },
            .UnaryExpr => |un| {
                // Can fold if operand is constant
                return self.canConstantFold(un.operand);
            },
            .Identifier => |ident| {
                // Check if variable has known constant value
                if (self.const_values.get(ident.name)) |_| {
                    return true; // Variable has constant value
                }
                return false;
            },
            else => false,
        };
    }

    /// Optimize a binary operation based on type information
    pub fn optimizeBinaryOp(
        self: *TypeGuidedOptimizer,
        op: ast.BinaryOp,
        left_type: *Type,
        right_type: *Type,
    ) ?OptimizationHint {
        _ = self;

        // Integer operations can use specialized instructions
        if (isIntegerType(left_type) and isIntegerType(right_type)) {
            return switch (op) {
                .Mul => blk: {
                    // Check for power of 2 multiplication (can use shift)
                    break :blk OptimizationHint{ .UseShift = {} };
                },
                .Div => blk: {
                    // Check for power of 2 division (can use shift)
                    break :blk OptimizationHint{ .UseShift = {} };
                },
                .Add, .Sub => OptimizationHint{ .UseIntegerArithmetic = {} },
                else => null,
            };
        }

        // Floating point operations
        if (isFloatType(left_type) and isFloatType(right_type)) {
            return OptimizationHint{ .UseFloatArithmetic = {} };
        }

        return null;
    }

    /// Check if a branch is statically known (dead code)
    pub fn isStaticBranch(self: *TypeGuidedOptimizer, condition: *const ast.Expr) ?bool {
        return switch (condition.*) {
            .BoolLiteral => |val| val,
            .BinaryExpr => |bin| {
                // Check for comparisons with constants
                if (bin.op == .Eq or bin.op == .NotEq) {
                    const left_const = self.getConstValue(bin.left);
                    const right_const = self.getConstValue(bin.right);

                    if (left_const != null and right_const != null) {
                        const are_equal = self.areConstantsEqual(left_const.?, right_const.?);
                        return if (bin.op == .Eq) are_equal else !are_equal;
                    }
                }
                return null;
            },
            else => null,
        };
    }

    /// Get constant value from an expression
    pub fn getConstValue(self: *TypeGuidedOptimizer, expr: *const ast.Expr) ?ConstValue {
        return switch (expr.*) {
            .IntLiteral => |val| ConstValue{ .int = val },
            .FloatLiteral => |val| ConstValue{ .float = val },
            .BoolLiteral => |val| ConstValue{ .bool = val },
            .StringLiteral => |val| ConstValue{ .string = val },
            .Identifier => |ident| {
                // Look up in const_values map
                return self.const_values.get(ident.name);
            },
            else => null,
        };
    }

    /// Compare two constant values for equality
    pub fn areConstantsEqual(self: *TypeGuidedOptimizer, left: ConstValue, right: ConstValue) bool {
        _ = self;

        // Must be same type
        if (@as(std.meta.Tag(ConstValue), left) != @as(std.meta.Tag(ConstValue), right)) {
            return false;
        }

        return switch (left) {
            .int => |left_val| left_val == right.int,
            .float => |left_val| left_val == right.float,
            .bool => |left_val| left_val == right.bool,
            .string => |left_val| std.mem.eql(u8, left_val, right.string),
        };
    }

    /// Suggest array operation vectorization
    pub fn canVectorize(
        self: *TypeGuidedOptimizer,
        array_type: *Type,
        op: ast.BinaryOp,
    ) bool {
        _ = self;

        // Can vectorize if:
        // 1. Array of primitives (i32, f32, etc.)
        // 2. Operation is vectorizable (add, sub, mul)
        // 3. Array is large enough to benefit

        if (array_type.* != .Array) return false;

        const elem_type = array_type.Array.element_type;

        // Check if element type is vectorizable
        const vectorizable_elem = switch (elem_type.*) {
            .I32, .I64, .F32, .F64 => true,
            else => false,
        };

        if (!vectorizable_elem) return false;

        // Check if operation is vectorizable
        const vectorizable_op = switch (op) {
            .Add, .Sub, .Mul => true,
            else => false,
        };

        return vectorizable_op;
    }

    /// Get size in bytes for a type
    pub fn getTypeSize(self: *TypeGuidedOptimizer, ty: *Type) usize {
        _ = self;

        return switch (ty.*) {
            .I8 => 1,
            .I16 => 2,
            .I32, .F32 => 4,
            .I64, .F64 => 8,
            .Bool => 1,
            .String => 8, // Pointer size
            .Array => |arr| {
                // Array is a pointer on the stack (8 bytes)
                // Actual data is on heap
                _ = arr;
                return 8;
            },
            .Function => 8, // Function pointer
            .Struct => |s| {
                // Calculate struct size based on fields
                var total_size: usize = 0;
                for (s.fields) |field| {
                    // For simplicity, assume no padding (real implementation would need alignment)
                    const field_size = self.getTypeSize(&field.type);
                    total_size += field_size;
                }
                return total_size;
            },
            else => 8, // Default to pointer size
        };
    }

    /// Check if type is numeric (can use arithmetic)
    pub fn isNumericType(self: *TypeGuidedOptimizer, ty: *Type) bool {
        _ = self;
        return isIntegerType(ty) or isFloatType(ty);
    }

    /// Suggest inlining based on function type
    pub fn shouldInline(
        self: *TypeGuidedOptimizer,
        func_type: *Type,
        call_site_count: usize,
    ) bool {
        _ = self;

        if (func_type.* != .Function) return false;

        // Inline if:
        // 1. Function is small
        // 2. Called frequently
        // 3. No recursion

        // Simple heuristic: inline if called more than 3 times
        return call_site_count > 3;
    }
};

/// Optimization hints for code generator
pub const OptimizationHint = union(enum) {
    /// Use bit shift instead of multiply/divide
    UseShift,
    /// Use integer-specific instructions
    UseIntegerArithmetic,
    /// Use floating-point instructions
    UseFloatArithmetic,
    /// Vectorize operation using SIMD
    VectorizeOperation,
    /// Inline function call
    InlineFunction,
    /// Eliminate dead branch
    EliminateBranch: bool, // true = take if branch, false = take else branch
};

/// Check if type is an integer type
fn isIntegerType(ty: *Type) bool {
    return switch (ty.*) {
        .Int, .I8, .I16, .I32, .I64 => true,
        else => false,
    };
}

/// Check if type is a floating-point type
fn isFloatType(ty: *Type) bool {
    return switch (ty.*) {
        .Float, .F32, .F64 => true,
        else => false,
    };
}

/// Constant folding optimization
pub const ConstantFolder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConstantFolder {
        return .{ .allocator = allocator };
    }

    /// Fold a binary expression if possible
    pub fn foldBinaryExpr(
        self: *ConstantFolder,
        op: ast.BinaryOp,
        left: *const ast.Expr,
        right: *const ast.Expr,
    ) ?ast.Expr {
        _ = self;

        // Only fold if both sides are literals
        const left_int = if (left.* == .IntLiteral) left.IntLiteral else return null;
        const right_int = if (right.* == .IntLiteral) right.IntLiteral else return null;

        const result = switch (op) {
            .Add => left_int + right_int,
            .Sub => left_int - right_int,
            .Mul => left_int * right_int,
            .Div => if (right_int != 0) @divTrunc(left_int, right_int) else return null,
            .Mod => if (right_int != 0) @mod(left_int, right_int) else return null,
            .Lt => if (left_int < right_int) 1 else 0,
            .Gt => if (left_int > right_int) 1 else 0,
            .Eq => if (left_int == right_int) 1 else 0,
            .NotEq => if (left_int != right_int) 1 else 0,
            else => return null,
        };

        return ast.Expr{ .IntLiteral = result };
    }

    /// Fold a unary expression if possible
    pub fn foldUnaryExpr(
        self: *ConstantFolder,
        op: ast.UnaryOp,
        operand: *const ast.Expr,
    ) ?ast.Expr {
        _ = self;

        return switch (op) {
            .Negate => {
                if (operand.* == .IntLiteral) {
                    return ast.Expr{ .IntLiteral = -operand.IntLiteral };
                } else if (operand.* == .FloatLiteral) {
                    return ast.Expr{ .FloatLiteral = -operand.FloatLiteral };
                }
                return null;
            },
            .Not => {
                if (operand.* == .BoolLiteral) {
                    return ast.Expr{ .BoolLiteral = !operand.BoolLiteral };
                }
                return null;
            },
            else => null,
        };
    }
};

/// Strength reduction optimization
pub const StrengthReducer = struct {
    /// Check if multiplication can be replaced with shift
    pub fn canReplaceMultiplyWithShift(value: i64) ?u6 {
        // Check if value is a power of 2
        if (value <= 0) return null;
        if (@popCount(@as(u64, @intCast(value))) != 1) return null;

        // Calculate shift amount
        return @intCast(@ctz(@as(u64, @intCast(value))));
    }

    /// Check if division can be replaced with shift
    pub fn canReplaceDivideWithShift(value: i64) ?u6 {
        // Same logic as multiply
        return canReplaceMultiplyWithShift(value);
    }

    /// Suggest strength reduction for modulo
    pub fn canReplaceModuloWithAnd(value: i64) ?i64 {
        // Modulo by power of 2 can use AND with (value - 1)
        if (canReplaceMultiplyWithShift(value)) |_| {
            return value - 1;
        }
        return null;
    }
};

/// Type-based code specialization
pub const TypeSpecializer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeSpecializer {
        return .{ .allocator = allocator };
    }

    /// Determine best instruction for binary operation based on types
    pub fn selectBinaryInstruction(
        self: *TypeSpecializer,
        op: ast.BinaryOp,
        left_type: *Type,
        right_type: *Type,
    ) BinaryInstruction {
        _ = self;

        // Integer operations
        if (isIntegerType(left_type) and isIntegerType(right_type)) {
            return switch (op) {
                .Add => .IntAdd,
                .Sub => .IntSub,
                .Mul => .IntMul,
                .Div => .IntDiv,
                else => .Generic,
            };
        }

        // Floating-point operations
        if (isFloatType(left_type) and isFloatType(right_type)) {
            return switch (op) {
                .Add => .FloatAdd,
                .Sub => .FloatSub,
                .Mul => .FloatMul,
                .Div => .FloatDiv,
                else => .Generic,
            };
        }

        return .Generic;
    }
};

/// Binary instruction types
pub const BinaryInstruction = enum {
    IntAdd,
    IntSub,
    IntMul,
    IntDiv,
    FloatAdd,
    FloatSub,
    FloatMul,
    FloatDiv,
    Generic,
};
