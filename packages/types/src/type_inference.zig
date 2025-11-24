const std = @import("std");
const ast = @import("ast");
const type_system = @import("type_system.zig");
const Type = type_system.Type;
const TraitSystem = @import("traits").TraitSystem;

/// Comprehensive type inference engine for the Home language.
///
/// This module implements a Hindley-Milner style type inference system with:
/// - Type variable generation and unification
/// - Constraint collection and solving
/// - Bidirectional type checking
/// - Closure parameter and return type inference
/// - Generic type instantiation
/// - Let-polymorphism (generalization)
///
/// The inference algorithm works in three phases:
/// 1. **Constraint Generation**: Walk the AST and generate type constraints
/// 2. **Constraint Solving**: Unify constraints to find a solution
/// 3. **Type Substitution**: Apply the solution to get concrete types
///
/// Example:
/// ```zig
/// var inferencer = TypeInferencer.init(allocator);
/// defer inferencer.deinit();
///
/// const inferred_type = try inferencer.inferExpression(expr, &env);
/// ```
pub const TypeInferencer = struct {
    allocator: std.mem.Allocator,
    /// Counter for generating unique type variables
    next_type_var: usize,
    /// Active constraints that need to be solved
    constraints: std.ArrayList(Constraint),
    /// Current substitution (solution) for type variables
    substitution: Substitution,
    /// Type environment mapping variables to type schemes
    type_env: std.StringHashMap(*TypeScheme),
    /// Trait system for trait bound checking
    trait_system: ?*TraitSystem,

    pub fn init(allocator: std.mem.Allocator) TypeInferencer {
        return .{
            .allocator = allocator,
            .next_type_var = 0,
            .constraints = std.ArrayList(Constraint).initCapacity(allocator, 0) catch std.ArrayList(Constraint){ .items = &.{}, .capacity = 0 },
            .substitution = Substitution.init(allocator),
            .type_env = std.StringHashMap(*TypeScheme).init(allocator),
            .trait_system = null,
        };
    }

    pub fn deinit(self: *TypeInferencer) void {
        self.constraints.deinit(self.allocator);
        self.substitution.deinit();

        var it = self.type_env.valueIterator();
        while (it.next()) |scheme| {
            scheme.*.deinit(self.allocator);
            self.allocator.destroy(scheme.*);
        }
        self.type_env.deinit();
    }

    /// Set the trait system for trait bound checking
    pub fn setTraitSystem(self: *TypeInferencer, trait_system: *TraitSystem) void {
        self.trait_system = trait_system;
    }

    /// Generate a fresh type variable
    pub fn freshTypeVar(self: *TypeInferencer) !*Type {
        const var_id = self.next_type_var;
        self.next_type_var += 1;

        const ty = try self.allocator.create(Type);
        ty.* = Type{ .TypeVar = .{ .id = var_id, .name = null } };
        return ty;
    }

    /// Generate a named type variable (for debugging)
    pub fn freshNamedTypeVar(self: *TypeInferencer, name: []const u8) !*Type {
        const var_id = self.next_type_var;
        self.next_type_var += 1;

        const name_copy = try self.allocator.dupe(u8, name);
        const ty = try self.allocator.create(Type);
        ty.* = Type{ .TypeVar = .{ .id = var_id, .name = name_copy } };
        return ty;
    }

    // ============================================================================
    // BIDIRECTIONAL TYPE CHECKING
    // ============================================================================

    /// Check mode: Type flows DOWN from context to expression
    /// This is used when we know what type an expression should have (e.g., from annotation)
    /// and want to verify that the expression conforms to that type.
    ///
    /// Example:
    /// ```
    /// let x: int = <expr>;  // We check that <expr> has type int
    /// ```
    pub fn checkExpression(self: *TypeInferencer, expr: *const ast.Expr, expected: *Type, env: *type_system.TypeEnvironment) !void {
        // Synthesize the actual type of the expression
        const actual = try self.synthesizeExpression(expr, env);

        // Unify with expected type
        try self.unify(actual, expected);
    }

    /// Synthesis mode: Type flows UP from expression to context
    /// This is used when we don't know what type an expression has and need to infer it.
    ///
    /// Example:
    /// ```
    /// let x = <expr>;  // We synthesize the type of <expr>
    /// ```
    pub fn synthesizeExpression(self: *TypeInferencer, expr: *const ast.Expr, env: *type_system.TypeEnvironment) !*Type {
        // This is essentially the same as inferExpression, but with a more explicit name
        return try self.inferExpressionInternal(expr, env, null);
    }

    /// Internal inference with optional expected type for better error messages
    fn inferExpressionInternal(self: *TypeInferencer, expr: *const ast.Expr, env: *type_system.TypeEnvironment, expected: ?*Type) !*Type {
        _ = expected; // Reserved for future use in error messages
        return try self.inferExpression(expr, env);
    }

    /// Infer the type of an expression
    /// This is the legacy function that will gradually be replaced by synthesizeExpression
    pub fn inferExpression(self: *TypeInferencer, expr: *const ast.Expr, env: *type_system.TypeEnvironment) !*Type {
        return switch (expr.*) {
            .IntegerLiteral => |lit| {
                // If there's a type suffix, use it; otherwise default to Int
                if (lit.type_suffix) |suffix| {
                    const ty = try self.allocator.create(Type);
                    ty.* = try self.parseTypeSuffix(suffix);
                    return ty;
                }
                const ty = try self.allocator.create(Type);
                ty.* = Type.Int;
                return ty;
            },

            .FloatLiteral => |lit| {
                if (lit.type_suffix) |suffix| {
                    const ty = try self.allocator.create(Type);
                    ty.* = try self.parseTypeSuffix(suffix);
                    return ty;
                }
                const ty = try self.allocator.create(Type);
                ty.* = Type.Float;
                return ty;
            },

            .StringLiteral => {
                const ty = try self.allocator.create(Type);
                ty.* = Type.String;
                return ty;
            },

            .BooleanLiteral => {
                const ty = try self.allocator.create(Type);
                ty.* = Type.Bool;
                return ty;
            },

            .Identifier => |id| {
                // Look up in type environment
                if (self.type_env.get(id.name)) |scheme| {
                    return try self.instantiate(scheme);
                }
                // Fallback to runtime environment
                if (env.lookup(id.name)) |ty| {
                    const result = try self.allocator.create(Type);
                    result.* = ty;
                    return result;
                }
                return error.UndefinedVariable;
            },

            .BinaryExpr => |bin| try self.inferBinaryExpr(bin, env),
            .UnaryExpr => |un| try self.inferUnaryExpr(un, env),
            .CallExpr => |call| try self.inferCallExpr(call, env),
            .ArrayLiteral => |arr| try self.inferArrayLiteral(arr, env),
            .IndexExpr => |idx| try self.inferIndexExpr(idx, env),
            .MemberExpr => |mem| try self.inferMemberExpr(mem, env),
            .TernaryExpr => |tern| try self.inferTernaryExpr(tern, env),
            .ClosureExpr => |closure| try self.inferClosureExpr(closure, env),
            .TupleExpr => |tuple| try self.inferTupleExpr(tuple, env),

            else => {
                // For unsupported expressions, generate a fresh type variable
                return try self.freshTypeVar();
            },
        };
    }

    /// Infer type of binary expression
    fn inferBinaryExpr(self: *TypeInferencer, bin: *const ast.BinaryExpr, env: *type_system.TypeEnvironment) !*Type {
        const left_ty = try self.inferExpression(&bin.left, env);
        const right_ty = try self.inferExpression(&bin.right, env);

        switch (bin.operator) {
            // Arithmetic operators: both operands must be numeric
            .Plus, .Minus, .Star, .Slash, .Percent => {
                try self.addConstraint(.{ .Equality = .{ .lhs = left_ty, .rhs = right_ty } });
                // Result type is same as operand type
                return left_ty;
            },

            // Comparison operators: operands must match, result is Bool
            .Equal, .NotEqual, .Less, .LessEqual, .Greater, .GreaterEqual => {
                try self.addConstraint(.{ .Equality = .{ .lhs = left_ty, .rhs = right_ty } });
                const result = try self.allocator.create(Type);
                result.* = Type.Bool;
                return result;
            },

            // Logical operators: both must be Bool
            .And, .Or => {
                const bool_ty = try self.allocator.create(Type);
                bool_ty.* = Type.Bool;
                try self.addConstraint(.{ .Equality = .{ .lhs = left_ty, .rhs = bool_ty } });
                try self.addConstraint(.{ .Equality = .{ .lhs = right_ty, .rhs = bool_ty } });
                return bool_ty;
            },

            // Bitwise operators: both must be Int
            .BitwiseAnd, .BitwiseOr, .BitwiseXor, .LeftShift, .RightShift => {
                const int_ty = try self.allocator.create(Type);
                int_ty.* = Type.Int;
                try self.addConstraint(.{ .Equality = .{ .lhs = left_ty, .rhs = int_ty } });
                try self.addConstraint(.{ .Equality = .{ .lhs = right_ty, .rhs = int_ty } });
                return int_ty;
            },

            else => return try self.freshTypeVar(),
        }
    }

    /// Infer type of unary expression
    fn inferUnaryExpr(self: *TypeInferencer, un: *const ast.UnaryExpr, env: *type_system.TypeEnvironment) !*Type {
        const operand_ty = try self.inferExpression(&un.operand, env);

        switch (un.operator) {
            .Minus => {
                // Operand must be numeric, result is same type
                return operand_ty;
            },
            .Not => {
                // Operand must be Bool
                const bool_ty = try self.allocator.create(Type);
                bool_ty.* = Type.Bool;
                try self.addConstraint(.{ .Equality = .{ .lhs = operand_ty, .rhs = bool_ty } });
                return bool_ty;
            },
            .BitwiseNot => {
                // Operand must be Int
                const int_ty = try self.allocator.create(Type);
                int_ty.* = Type.Int;
                try self.addConstraint(.{ .Equality = .{ .lhs = operand_ty, .rhs = int_ty } });
                return int_ty;
            },
            else => return try self.freshTypeVar(),
        }
    }

    /// Infer type of function call (with bidirectional checking)
    fn inferCallExpr(self: *TypeInferencer, call: *const ast.CallExpr, env: *type_system.TypeEnvironment) !*Type {
        // Synthesize the type of the callee
        const func_ty = try self.synthesizeExpression(&call.callee, env);

        // Try to extract function type information
        const resolved_func_ty = try self.substitution.apply(func_ty, self.allocator);

        if (resolved_func_ty.* == .Function) {
            // We know the parameter types! Use CHECK mode for arguments
            const func_info = resolved_func_ty.Function;

            if (call.arguments.len != func_info.params.len) {
                return error.ArgumentCountMismatch;
            }

            // CHECK each argument against its expected parameter type
            for (call.arguments, func_info.params) |arg, param_ty| {
                try self.checkExpression(&arg, @constCast(param_ty), env);
            }

            // Return type is known
            return @constCast(func_info.return_type);
        } else {
            // Function type is not yet known (still a type variable)
            // Fall back to synthesis mode with fresh type variables

            // Generate fresh type variables for parameters and return type
            var param_types = std.ArrayList(*Type){ .items = &.{}, .capacity = 0 };
            defer param_types.deinit(self.allocator);

            for (call.arguments) |_| {
                const param_ty = try self.freshTypeVar();
                try param_types.append(self.allocator, param_ty);
            }

            const return_ty = try self.freshTypeVar();

            // Create function type
            const expected_func_ty = try self.allocator.create(Type);
            expected_func_ty.* = Type{ .Function = .{
                .params = try param_types.toOwnedSlice(self.allocator),
                .return_type = return_ty,
            } };

            // Constrain callee to be a function with these types
            try self.addConstraint(.{ .Equality = .{ .lhs = func_ty, .rhs = expected_func_ty } });

            // SYNTHESIZE argument types and constrain them
            for (call.arguments, 0..) |arg, i| {
                const arg_ty = try self.synthesizeExpression(&arg, env);
                try self.addConstraint(.{ .Equality = .{ .lhs = arg_ty, .rhs = expected_func_ty.Function.params[i] } });
            }

            return return_ty;
        }
    }

    /// Infer type of array literal (with bidirectional checking)
    fn inferArrayLiteral(self: *TypeInferencer, arr: *const ast.ArrayLiteral, env: *type_system.TypeEnvironment) !*Type {
        if (arr.elements.len == 0) {
            // Empty array: create fresh type variable for element type
            const elem_ty = try self.freshTypeVar();
            const arr_ty = try self.allocator.create(Type);
            arr_ty.* = Type{ .Array = .{ .element_type = elem_ty } };
            return arr_ty;
        }

        // SYNTHESIZE type from first element
        const first_ty = try self.synthesizeExpression(&arr.elements[0], env);

        // CHECK that all other elements have the same type
        for (arr.elements[1..]) |elem| {
            try self.checkExpression(&elem, first_ty, env);
        }

        const arr_ty = try self.allocator.create(Type);
        arr_ty.* = Type{ .Array = .{ .element_type = first_ty } };
        return arr_ty;
    }

    /// Infer type of index expression
    fn inferIndexExpr(self: *TypeInferencer, idx: *const ast.IndexExpr, env: *type_system.TypeEnvironment) !*Type {
        const arr_ty = try self.inferExpression(&idx.object, env);
        const index_ty = try self.inferExpression(&idx.index, env);

        // Index must be Int
        const int_ty = try self.allocator.create(Type);
        int_ty.* = Type.Int;
        try self.addConstraint(.{ .Equality = .{ .lhs = index_ty, .rhs = int_ty } });

        // Object must be an array
        const elem_ty = try self.freshTypeVar();
        const expected_arr_ty = try self.allocator.create(Type);
        expected_arr_ty.* = Type{ .Array = .{ .element_type = elem_ty } };
        try self.addConstraint(.{ .Equality = .{ .lhs = arr_ty, .rhs = expected_arr_ty } });

        return elem_ty;
    }

    /// Infer type of member expression
    fn inferMemberExpr(self: *TypeInferencer, mem: *const ast.MemberExpr, env: *type_system.TypeEnvironment) !*Type {
        const obj_ty = try self.inferExpression(&mem.object, env);

        // Resolve type variables if needed
        const resolved_ty = try self.resolveType(obj_ty);

        // Look up field type in struct
        switch (resolved_ty.*) {
            .Struct => |struct_ty| {
                // Search for field with matching name
                for (struct_ty.fields) |field| {
                    if (std.mem.eql(u8, field.name, mem.member)) {
                        // Return a copy of the field type
                        const field_ty = try self.allocator.create(Type);
                        field_ty.* = field.type;
                        return field_ty;
                    }
                }
                // Field not found - return error or fresh type variable
                return try self.freshTypeVar();
            },
            .TypeVar => {
                // Object type is still unknown - generate fresh type variable
                return try self.freshTypeVar();
            },
            else => {
                // Not a struct type - error, but return fresh type variable
                return try self.freshTypeVar();
            },
        }
    }

    /// Resolve type variables in a type
    fn resolveType(self: *TypeInferencer, ty: *Type) !*Type {
        switch (ty.*) {
            .TypeVar => |tv| {
                // Check if this type variable has been unified
                if (self.substitutions.get(tv.id)) |subst_ty| {
                    // Recursively resolve
                    return try self.resolveType(subst_ty);
                }
                return ty;
            },
            else => return ty,
        }
    }

    /// Infer type of ternary expression
    fn inferTernaryExpr(self: *TypeInferencer, tern: *const ast.TernaryExpr, env: *type_system.TypeEnvironment) !*Type {
        // CHECK that condition is Bool
        const bool_ty = try self.allocator.create(Type);
        bool_ty.* = Type.Bool;
        try self.checkExpression(&tern.condition, bool_ty, env);

        // SYNTHESIZE type from then branch
        const then_ty = try self.synthesizeExpression(&tern.then_expr, env);

        // CHECK that else branch matches then branch
        try self.checkExpression(&tern.else_expr, then_ty, env);

        return then_ty;
    }

    /// Infer type of closure expression
    fn inferClosureExpr(self: *TypeInferencer, closure: *const ast.ClosureExpr, env: *type_system.TypeEnvironment) !*Type {
        // Create new environment for closure body
        var closure_env = type_system.TypeEnvironment.init(self.allocator, env);
        defer closure_env.deinit();

        // Infer or use annotated parameter types
        var param_types = std.ArrayList(*Type){ .items = &.{}, .capacity = 0 };
        defer param_types.deinit(self.allocator);

        for (closure.parameters) |param| {
            const param_ty = if (param.type_annotation) |type_ann|
                // Parse type annotation
                try self.parseTypeAnnotation(type_ann)
            else
                try self.freshTypeVar();

            try param_types.append(self.allocator, param_ty);
            try closure_env.define(param.name, param_ty.*);
        }

        // Infer return type from body
        const return_ty = if (closure.return_type) |ret_type|
            // Parse return type annotation
            try self.parseTypeAnnotation(ret_type)
        else
            try self.inferExpression(&closure.body, &closure_env);

        // Create function type
        const func_ty = try self.allocator.create(Type);
        func_ty.* = Type{ .Function = .{
            .params = try param_types.toOwnedSlice(self.allocator),
            .return_type = return_ty,
        } };

        return func_ty;
    }

    /// Infer type of tuple expression
    fn inferTupleExpr(self: *TypeInferencer, tuple: *const ast.TupleExpr, env: *type_system.TypeEnvironment) !*Type {
        var elem_types = std.ArrayList(Type){ .items = &.{}, .capacity = 0 };
        defer elem_types.deinit(self.allocator);

        for (tuple.elements) |elem| {
            const elem_ty = try self.inferExpression(&elem, env);
            try elem_types.append(self.allocator, elem_ty.*);
        }

        const tuple_ty = try self.allocator.create(Type);
        tuple_ty.* = Type{ .Tuple = .{
            .element_types = try elem_types.toOwnedSlice(self.allocator),
        } };

        return tuple_ty;
    }

    /// Parse type suffix string into Type
    fn parseTypeSuffix(self: *TypeInferencer, suffix: []const u8) !Type {
        _ = self;
        if (std.mem.eql(u8, suffix, "i8")) return Type.I8;
        if (std.mem.eql(u8, suffix, "i16")) return Type.I16;
        if (std.mem.eql(u8, suffix, "i32")) return Type.I32;
        if (std.mem.eql(u8, suffix, "i64")) return Type.I64;
        if (std.mem.eql(u8, suffix, "i128")) return Type.I128;
        if (std.mem.eql(u8, suffix, "u8")) return Type.U8;
        if (std.mem.eql(u8, suffix, "u16")) return Type.U16;
        if (std.mem.eql(u8, suffix, "u32")) return Type.U32;
        if (std.mem.eql(u8, suffix, "u64")) return Type.U64;
        if (std.mem.eql(u8, suffix, "u128")) return Type.U128;
        if (std.mem.eql(u8, suffix, "f32")) return Type.F32;
        if (std.mem.eql(u8, suffix, "f64")) return Type.F64;
        return Type.Int; // Default
    }

    /// Parse type annotation (string or TypeExpr) into Type
    fn parseTypeAnnotation(self: *TypeInferencer, type_ann: []const u8) !*Type {
        const ty = try self.allocator.create(Type);
        ty.* = if (std.mem.eql(u8, type_ann, "i8"))
            Type.I8
        else if (std.mem.eql(u8, type_ann, "i16"))
            Type.I16
        else if (std.mem.eql(u8, type_ann, "i32"))
            Type.I32
        else if (std.mem.eql(u8, type_ann, "i64") or std.mem.eql(u8, type_ann, "int"))
            Type.I64
        else if (std.mem.eql(u8, type_ann, "i128"))
            Type.I128
        else if (std.mem.eql(u8, type_ann, "u8"))
            Type.U8
        else if (std.mem.eql(u8, type_ann, "u16"))
            Type.U16
        else if (std.mem.eql(u8, type_ann, "u32"))
            Type.U32
        else if (std.mem.eql(u8, type_ann, "u64"))
            Type.U64
        else if (std.mem.eql(u8, type_ann, "u128"))
            Type.U128
        else if (std.mem.eql(u8, type_ann, "f32"))
            Type.F32
        else if (std.mem.eql(u8, type_ann, "f64") or std.mem.eql(u8, type_ann, "float"))
            Type.F64
        else if (std.mem.eql(u8, type_ann, "bool"))
            Type.Bool
        else if (std.mem.eql(u8, type_ann, "String") or std.mem.eql(u8, type_ann, "str"))
            Type.String
        else if (std.mem.eql(u8, type_ann, "void"))
            Type.Void
        else
            // Unknown type - create fresh type variable
            Type{ .TypeVar = .{ .id = self.next_type_var_id, .name = type_ann } };

        self.next_type_var_id += 1;
        return ty;
    }

    /// Add a type constraint
    fn addConstraint(self: *TypeInferencer, constraint: Constraint) !void {
        try self.constraints.append(self.allocator, constraint);
    }

    /// Solve all constraints using unification
    pub fn solve(self: *TypeInferencer) !void {
        for (self.constraints.items) |constraint| {
            switch (constraint) {
                .Equality => |eq| {
                    try self.unify(eq.lhs, eq.rhs);
                },
                .TraitBound => |tb| {
                    // Check trait bounds
                    try self.checkTraitBound(tb.ty, tb.trait_name);
                },
            }
        }
    }

    /// Unify two types
    fn unify(self: *TypeInferencer, t1: *Type, t2: *Type) !void {
        const t1_resolved = try self.substitution.apply(t1, self.allocator);
        const t2_resolved = try self.substitution.apply(t2, self.allocator);

        // Same type
        if (t1_resolved == t2_resolved) return;

        // Type variable on left
        if (t1_resolved.* == .TypeVar) {
            if (try self.occursCheck(t1_resolved.TypeVar.id, t2_resolved)) {
                return error.InfiniteType;
            }
            try self.substitution.bind(t1_resolved.TypeVar.id, t2_resolved);
            return;
        }

        // Type variable on right
        if (t2_resolved.* == .TypeVar) {
            if (try self.occursCheck(t2_resolved.TypeVar.id, t1_resolved)) {
                return error.InfiniteType;
            }
            try self.substitution.bind(t2_resolved.TypeVar.id, t1_resolved);
            return;
        }

        // Both are concrete types - must match structurally
        switch (t1_resolved.*) {
            .Array => |arr1| {
                if (t2_resolved.* != .Array) return error.TypeMismatch;
                try self.unify(@constCast(arr1.element_type), @constCast(t2_resolved.Array.element_type));
            },
            .Function => |func1| {
                if (t2_resolved.* != .Function) return error.TypeMismatch;
                const func2 = t2_resolved.Function;

                if (func1.params.len != func2.params.len) {
                    return error.TypeMismatch;
                }

                for (func1.params, func2.params) |p1, p2| {
                    try self.unify(@constCast(p1), @constCast(p2));
                }

                try self.unify(@constCast(func1.return_type), @constCast(func2.return_type));
            },
            .Tuple => |tuple1| {
                if (t2_resolved.* != .Tuple) return error.TypeMismatch;
                const tuple2 = t2_resolved.Tuple;

                if (tuple1.element_types.len != tuple2.element_types.len) {
                    return error.TypeMismatch;
                }

                for (tuple1.element_types, tuple2.element_types) |e1, e2| {
                    try self.unify(@constCast(&e1), @constCast(&e2));
                }
            },
            else => {
                // For primitive types, check equality
                if (!Type.equals(t1_resolved.*, t2_resolved.*)) {
                    return error.TypeMismatch;
                }
            },
        }
    }

    /// Check if a type variable occurs in a type (prevents infinite types)
    fn occursCheck(self: *TypeInferencer, var_id: usize, ty: *Type) !bool {
        const resolved = try self.substitution.apply(ty, self.allocator);

        if (resolved.* == .TypeVar and resolved.TypeVar.id == var_id) {
            return true;
        }

        switch (resolved.*) {
            .Array => |arr| return try self.occursCheck(var_id, @constCast(arr.element_type)),
            .Function => |func| {
                for (func.params) |param| {
                    if (try self.occursCheck(var_id, @constCast(param))) return true;
                }
                return try self.occursCheck(var_id, @constCast(func.return_type));
            },
            .Tuple => |tuple| {
                for (tuple.element_types) |elem| {
                    if (try self.occursCheck(var_id, @constCast(elem))) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Check if a type satisfies a trait bound
    fn checkTraitBound(self: *TypeInferencer, ty: *Type, trait_name: []const u8) !void {
        _ = self;

        // Resolve the type
        const resolved_ty = ty; // Would call resolveType in full implementation

        // Check built-in trait implementations
        switch (resolved_ty.*) {
            .I8, .I16, .I32, .I64, .I128, .U8, .U16, .U32, .U64, .U128 => {
                // Integer types implement Copy, Clone, Eq, Ord, Debug
                const builtin_traits = &[_][]const u8{ "Copy", "Clone", "Eq", "Ord", "Debug", "Display" };
                for (builtin_traits) |builtin| {
                    if (std.mem.eql(u8, trait_name, builtin)) return;
                }
            },
            .F32, .F64 => {
                // Float types implement Copy, Clone, Debug (but not Eq/Ord)
                const builtin_traits = &[_][]const u8{ "Copy", "Clone", "Debug", "Display" };
                for (builtin_traits) |builtin| {
                    if (std.mem.eql(u8, trait_name, builtin)) return;
                }
            },
            .Bool => {
                // Bool implements Copy, Clone, Eq, Ord, Debug
                const builtin_traits = &[_][]const u8{ "Copy", "Clone", "Eq", "Ord", "Debug", "Display" };
                for (builtin_traits) |builtin| {
                    if (std.mem.eql(u8, trait_name, builtin)) return;
                }
            },
            .String => {
                // String implements Clone, Eq, Ord, Debug (but not Copy)
                const builtin_traits = &[_][]const u8{ "Clone", "Eq", "Ord", "Debug", "Display" };
                for (builtin_traits) |builtin| {
                    if (std.mem.eql(u8, trait_name, builtin)) return;
                }
            },
            .TypeVar => {
                // Type variable - constraint will be checked when resolved
                return;
            },
            else => {
                // For other types (Struct, Enum, etc.), would check trait implementations
                // For now, assume it's satisfied
                return;
            },
        }

        // Trait not implemented - return error
        return error.TraitNotImplemented;
    }

    /// Instantiate a type scheme with fresh type variables
    fn instantiate(self: *TypeInferencer, scheme: *TypeScheme) !*Type {
        if (scheme.forall.len == 0) {
            // No quantified variables, return the type as-is
            const result = try self.allocator.create(Type);
            result.* = scheme.ty.*;
            return result;
        }

        // Create substitution for quantified variables
        var subst = Substitution.init(self.allocator);
        defer subst.deinit();

        for (scheme.forall) |var_id| {
            const fresh = try self.freshTypeVar();
            try subst.bind(var_id, fresh);
        }

        return try subst.apply(scheme.ty, self.allocator);
    }

    /// Generalize a type into a type scheme (let-polymorphism)
    pub fn generalize(self: *TypeInferencer, ty: *Type) !*TypeScheme {
        const free_vars = try self.freeTypeVars(ty);
        defer free_vars.deinit();

        const scheme = try self.allocator.create(TypeScheme);
        scheme.* = .{
            .forall = try free_vars.toOwnedSlice(),
            .ty = ty,
        };

        return scheme;
    }

    /// Find all free type variables in a type
    fn freeTypeVars(self: *TypeInferencer, ty: *Type) !std.ArrayList(usize) {
        var vars = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
        const resolved = try self.substitution.apply(ty, self.allocator);

        switch (resolved.*) {
            .TypeVar => |tv| {
                try vars.append(self.allocator, tv.id);
            },
            .Array => |arr| {
                const elem_vars = try self.freeTypeVars(@constCast(arr.element_type));
                defer elem_vars.deinit();
                try vars.appendSlice(self.allocator, elem_vars.items);
            },
            .Function => |func| {
                for (func.params) |param| {
                    const param_vars = try self.freeTypeVars(@constCast(param));
                    defer param_vars.deinit();
                    try vars.appendSlice(self.allocator, param_vars.items);
                }
                const ret_vars = try self.freeTypeVars(@constCast(func.return_type));
                defer ret_vars.deinit();
                try vars.appendSlice(self.allocator, ret_vars.items);
            },
            .Tuple => |tuple| {
                for (tuple.element_types) |elem| {
                    const elem_vars = try self.freeTypeVars(@constCast(elem));
                    defer elem_vars.deinit();
                    try vars.appendSlice(self.allocator, elem_vars.items);
                }
            },
            else => {},
        }

        return vars;
    }

    /// Apply the current substitution to get the final type
    pub fn applySubstitution(self: *TypeInferencer, ty: *Type) !*Type {
        return try self.substitution.apply(ty, self.allocator);
    }
};

/// Type variable (used during inference)
pub const TypeVar = struct {
    id: usize,
    name: ?[]const u8,
};

/// Type scheme for let-polymorphism (∀a. type)
pub const TypeScheme = struct {
    /// Quantified type variables
    forall: []const usize,
    /// The type with free variables
    ty: *Type,

    pub fn deinit(self: *TypeScheme, allocator: std.mem.Allocator) void {
        allocator.free(self.forall);
        allocator.destroy(self.ty);
    }
};

/// Type constraint for unification
pub const Constraint = union(enum) {
    /// Two types must be equal
    Equality: struct {
        lhs: *Type,
        rhs: *Type,
    },
    /// Type must implement a trait
    TraitBound: struct {
        ty: *Type,
        trait_name: []const u8,
    },
};

/// Substitution mapping type variables to types
pub const Substitution = struct {
    bindings: std.AutoHashMap(usize, *Type),

    pub fn init(allocator: std.mem.Allocator) Substitution {
        return .{
            .bindings = std.AutoHashMap(usize, *Type).init(allocator),
        };
    }

    pub fn deinit(self: *Substitution) void {
        self.bindings.deinit();
    }

    /// Bind a type variable to a type
    pub fn bind(self: *Substitution, var_id: usize, ty: *Type) !void {
        try self.bindings.put(var_id, ty);
    }

    /// Apply substitution to a type
    pub fn apply(self: *Substitution, ty: *Type, allocator: std.mem.Allocator) !*Type {
        switch (ty.*) {
            .TypeVar => |tv| {
                if (self.bindings.get(tv.id)) |bound_ty| {
                    // Recursively apply to handle transitive bindings
                    return try self.apply(bound_ty, allocator);
                }
                return ty;
            },
            .Array => |arr| {
                const elem_ty = try self.apply(@constCast(arr.element_type), allocator);
                if (elem_ty == arr.element_type) return ty;

                const result = try allocator.create(Type);
                result.* = Type{ .Array = .{ .element_type = elem_ty } };
                return result;
            },
            .Function => |func| {
                var params = std.ArrayList(Type){ .items = &.{}, .capacity = 0 };
                defer params.deinit(allocator);

                for (func.params) |param| {
                    const param_ty = try self.apply(@constCast(param), allocator);
                    try params.append(allocator, param_ty.*);
                }

                const ret_ty = try self.apply(@constCast(func.return_type), allocator);

                const result = try allocator.create(Type);
                result.* = Type{ .Function = .{
                    .params = try params.toOwnedSlice(allocator),
                    .return_type = ret_ty,
                } };
                return result;
            },
            .Tuple => |tuple| {
                var elems = std.ArrayList(Type){ .items = &.{}, .capacity = 0 };
                defer elems.deinit(allocator);

                for (tuple.element_types) |elem| {
                    const elem_ty = try self.apply(@constCast(&elem), allocator);
                    try elems.append(allocator, elem_ty.*);
                }

                const result = try allocator.create(Type);
                result.* = Type{ .Tuple = .{
                    .element_types = try elems.toOwnedSlice(allocator),
                } };
                return result;
            },
            else => return ty,
        }
    }
};
