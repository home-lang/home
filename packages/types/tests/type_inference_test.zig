const std = @import("std");
const testing = std.testing;
const type_inference = @import("type_inference");
const TypeInferencer = type_inference.TypeInferencer;
const ast = @import("ast");
const type_system = @import("type_system");
const Type = type_system.Type;

test "type inference: integer literal" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    var env = type_system.TypeEnvironment.init(testing.allocator, null);
    defer env.deinit();

    // Create integer literal: 42
    const lit = ast.IntegerLiteral.init(42, ast.SourceLocation{ .line = 1, .column = 1 });
    const expr = ast.Expr{ .IntegerLiteral = lit };

    const inferred_type = try inferencer.inferExpression(&expr, &env);
    try inferencer.solve();
    const final_type = try inferencer.applySubstitution(inferred_type);

    try testing.expect(final_type.* == .Int);
}

test "type inference: integer literal with type suffix" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    var env = type_system.TypeEnvironment.init(testing.allocator, null);
    defer env.deinit();

    // Create integer literal with type suffix: 42i32
    var lit = ast.IntegerLiteral.init(42, ast.SourceLocation{ .line = 1, .column = 1 });
    lit.type_suffix = "i32";
    const expr = ast.Expr{ .IntegerLiteral = lit };

    const inferred_type = try inferencer.inferExpression(&expr, &env);
    try inferencer.solve();
    const final_type = try inferencer.applySubstitution(inferred_type);

    try testing.expect(final_type.* == .I32);
}

test "type inference: binary expression" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    var env = type_system.TypeEnvironment.init(testing.allocator, null);
    defer env.deinit();

    // Create: 1 + 2
    const left_lit = ast.IntegerLiteral.init(1, ast.SourceLocation{ .line = 1, .column = 1 });
    const right_lit = ast.IntegerLiteral.init(2, ast.SourceLocation{ .line = 1, .column = 5 });

    const left_expr = try testing.allocator.create(ast.Expr);
    left_expr.* = ast.Expr{ .IntegerLiteral = left_lit };

    const right_expr = try testing.allocator.create(ast.Expr);
    right_expr.* = ast.Expr{ .IntegerLiteral = right_lit };

    const bin = try ast.BinaryExpr.init(
        testing.allocator,
        left_expr.*,
        .Plus,
        right_expr.*,
        ast.SourceLocation{ .line = 1, .column = 1 },
    );

    const expr = ast.Expr{ .BinaryExpr = bin };

    const inferred_type = try inferencer.inferExpression(&expr, &env);
    try inferencer.solve();
    const final_type = try inferencer.applySubstitution(inferred_type);

    try testing.expect(final_type.* == .Int);
}

test "type inference: array literal homogeneous" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    var env = type_system.TypeEnvironment.init(testing.allocator, null);
    defer env.deinit();

    // Create: [1, 2, 3]
    var elements = std.ArrayList(ast.Expr){ .items = &.{}, .capacity = 0 };
    defer elements.deinit(testing.allocator);

    const lit1 = ast.IntegerLiteral.init(1, ast.SourceLocation{ .line = 1, .column = 2 });
    const lit2 = ast.IntegerLiteral.init(2, ast.SourceLocation{ .line = 1, .column = 5 });
    const lit3 = ast.IntegerLiteral.init(3, ast.SourceLocation{ .line = 1, .column = 8 });

    try elements.append(testing.allocator, ast.Expr{ .IntegerLiteral = lit1 });
    try elements.append(testing.allocator, ast.Expr{ .IntegerLiteral = lit2 });
    try elements.append(testing.allocator, ast.Expr{ .IntegerLiteral = lit3 });

    const arr = try ast.ArrayLiteral.init(
        testing.allocator,
        try elements.toOwnedSlice(testing.allocator),
        ast.SourceLocation{ .line = 1, .column = 1 },
    );

    const expr = ast.Expr{ .ArrayLiteral = arr };

    const inferred_type = try inferencer.inferExpression(&expr, &env);
    try inferencer.solve();
    const final_type = try inferencer.applySubstitution(inferred_type);

    try testing.expect(final_type.* == .Array);
    try testing.expect(final_type.Array.element_type.* == .Int);
}

test "type inference: empty array" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    var env = type_system.TypeEnvironment.init(testing.allocator, null);
    defer env.deinit();

    // Create: []
    const arr = try ast.ArrayLiteral.init(
        testing.allocator,
        &.{},
        ast.SourceLocation{ .line = 1, .column = 1 },
    );

    const expr = ast.Expr{ .ArrayLiteral = arr };

    const inferred_type = try inferencer.inferExpression(&expr, &env);
    try inferencer.solve();
    const final_type = try inferencer.applySubstitution(inferred_type);

    // Empty array should have Array type with type variable for element
    try testing.expect(final_type.* == .Array);
    // Element type should be a type variable (unresolved)
    try testing.expect(final_type.Array.element_type.* == .TypeVar);
}

test "type inference: unification of type variables" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    // Create two type variables
    const t1 = try inferencer.freshTypeVar();
    const t2 = try inferencer.freshTypeVar();

    // Unify t1 with Int
    const int_ty = try testing.allocator.create(Type);
    int_ty.* = Type.Int;
    try inferencer.unify(t1, int_ty);

    // Unify t2 with t1
    try inferencer.unify(t2, t1);

    // Apply substitution
    const resolved_t2 = try inferencer.substitution.apply(t2, testing.allocator);

    // t2 should now be Int
    try testing.expect(resolved_t2.* == .Int);
}

test "type inference: occurs check prevents infinite types" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    // Create type variable
    const tv = try inferencer.freshTypeVar();

    // Try to create infinite type: tv = [tv]
    const arr_ty = try testing.allocator.create(Type);
    arr_ty.* = Type{ .Array = .{ .element_type = tv } };

    // This should fail with InfiniteType error
    try testing.expectError(error.InfiniteType, inferencer.unify(tv, arr_ty));
}

test "type inference: function type unification" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    // Create function type: fn(Int) -> Bool
    const param_ty = try testing.allocator.create(Type);
    param_ty.* = Type.Int;

    const ret_ty = try testing.allocator.create(Type);
    ret_ty.* = Type.Bool;

    var params = [_]Type{param_ty.*};

    const func1 = try testing.allocator.create(Type);
    func1.* = Type{ .Function = .{
        .params = &params,
        .return_type = ret_ty,
    } };

    // Create another function type with same signature
    const func2 = try testing.allocator.create(Type);
    func2.* = Type{ .Function = .{
        .params = &params,
        .return_type = ret_ty,
    } };

    // These should unify successfully
    try inferencer.unify(func1, func2);
}

test "type inference: comparison operators return Bool" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    var env = type_system.TypeEnvironment.init(testing.allocator, null);
    defer env.deinit();

    // Create: 1 < 2
    const left_lit = ast.IntegerLiteral.init(1, ast.SourceLocation{ .line = 1, .column = 1 });
    const right_lit = ast.IntegerLiteral.init(2, ast.SourceLocation{ .line = 1, .column = 5 });

    const left_expr = try testing.allocator.create(ast.Expr);
    left_expr.* = ast.Expr{ .IntegerLiteral = left_lit };

    const right_expr = try testing.allocator.create(ast.Expr);
    right_expr.* = ast.Expr{ .IntegerLiteral = right_lit };

    const bin = try ast.BinaryExpr.init(
        testing.allocator,
        left_expr.*,
        .Less,
        right_expr.*,
        ast.SourceLocation{ .line = 1, .column = 1 },
    );

    const expr = ast.Expr{ .BinaryExpr = bin };

    const inferred_type = try inferencer.inferExpression(&expr, &env);
    try inferencer.solve();
    const final_type = try inferencer.applySubstitution(inferred_type);

    try testing.expect(final_type.* == .Bool);
}

test "type inference: tuple with heterogeneous types" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    var env = type_system.TypeEnvironment.init(testing.allocator, null);
    defer env.deinit();

    // Create: (42, "hello", true)
    var elements = std.ArrayList(ast.Expr){ .items = &.{}, .capacity = 0 };
    defer elements.deinit(testing.allocator);

    const int_lit = ast.IntegerLiteral.init(42, ast.SourceLocation{ .line = 1, .column = 2 });
    const str_lit = ast.StringLiteral.init("hello", ast.SourceLocation{ .line = 1, .column = 6 });
    const bool_lit = ast.BooleanLiteral.init(true, ast.SourceLocation{ .line = 1, .column = 15 });

    try elements.append(testing.allocator, ast.Expr{ .IntegerLiteral = int_lit });
    try elements.append(testing.allocator, ast.Expr{ .StringLiteral = str_lit });
    try elements.append(testing.allocator, ast.Expr{ .BooleanLiteral = bool_lit });

    const tuple = try ast.TupleExpr.init(
        testing.allocator,
        try elements.toOwnedSlice(testing.allocator),
        ast.SourceLocation{ .line = 1, .column = 1 },
    );

    const expr = ast.Expr{ .TupleExpr = tuple };

    const inferred_type = try inferencer.inferExpression(&expr, &env);
    try inferencer.solve();
    const final_type = try inferencer.applySubstitution(inferred_type);

    try testing.expect(final_type.* == .Tuple);
    try testing.expectEqual(@as(usize, 3), final_type.Tuple.element_types.len);
    try testing.expect(final_type.Tuple.element_types[0] == .Int);
    try testing.expect(final_type.Tuple.element_types[1] == .String);
    try testing.expect(final_type.Tuple.element_types[2] == .Bool);
}

test "type inference: let-polymorphism generalization" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    // Create a polymorphic type: forall a. a -> a
    const param_tv = try inferencer.freshTypeVar();
    const return_tv = try inferencer.freshTypeVar();

    // Unify them (identity function)
    try inferencer.unify(param_tv, return_tv);

    var params = [_]Type{param_tv.*};
    const func_ty = try testing.allocator.create(Type);
    func_ty.* = Type{ .Function = .{
        .params = &params,
        .return_type = return_tv,
    } };

    // Generalize to type scheme
    const scheme = try inferencer.generalize(func_ty);
    defer scheme.deinit(testing.allocator);

    // Should have one quantified variable
    try testing.expectEqual(@as(usize, 1), scheme.forall.len);
}

test "type inference: substitution transitivity" {
    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();

    // Create chain: t1 -> t2 -> t3 -> Int
    const t1 = try inferencer.freshTypeVar();
    const t2 = try inferencer.freshTypeVar();
    const t3 = try inferencer.freshTypeVar();

    try inferencer.substitution.bind(t1.TypeVar.id, t2);
    try inferencer.substitution.bind(t2.TypeVar.id, t3);

    const int_ty = try testing.allocator.create(Type);
    int_ty.* = Type.Int;
    try inferencer.substitution.bind(t3.TypeVar.id, int_ty);

    // Applying substitution to t1 should resolve to Int
    const resolved = try inferencer.substitution.apply(t1, testing.allocator);
    try testing.expect(resolved.* == .Int);
}
