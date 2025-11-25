// Home Programming Language - Comptime Integration Module
// Connects comptime execution with semantic analysis and codegen

const std = @import("std");
const ast = @import("ast");
const comptime_mod = @import("comptime.zig");
const ComptimeExecutor = comptime_mod.ComptimeExecutor;
const ComptimeValue = comptime_mod.ComptimeValue;

/// Store for compile-time computed values
/// This is populated during semantic analysis and used by codegen
pub const ComptimeValueStore = struct {
    allocator: std.mem.Allocator,
    /// Map from AST node pointer to computed value
    values: std.AutoHashMap(usize, ComptimeValue),

    pub fn init(allocator: std.mem.Allocator) ComptimeValueStore {
        return .{
            .allocator = allocator,
            .values = std.AutoHashMap(usize, ComptimeValue).init(allocator),
        };
    }

    pub fn deinit(self: *ComptimeValueStore) void {
        self.values.deinit();
    }

    /// Store a computed value for an expression
    pub fn store(self: *ComptimeValueStore, expr: *ast.Expr, value: ComptimeValue) !void {
        const key = @intFromPtr(expr);
        try self.values.put(key, value);
    }

    /// Retrieve a computed value for an expression
    pub fn get(self: *ComptimeValueStore, expr: *ast.Expr) ?ComptimeValue {
        const key = @intFromPtr(expr);
        return self.values.get(key);
    }

    /// Check if an expression has a computed value
    pub fn has(self: *ComptimeValueStore, expr: *ast.Expr) bool {
        const key = @intFromPtr(expr);
        return self.values.contains(key);
    }
};

/// Evaluator that integrates with type checking
pub const ComptimeIntegration = struct {
    allocator: std.mem.Allocator,
    executor: ComptimeExecutor,
    value_store: *ComptimeValueStore,

    pub fn init(allocator: std.mem.Allocator, value_store: *ComptimeValueStore) !ComptimeIntegration {
        return .{
            .allocator = allocator,
            .executor = try ComptimeExecutor.init(allocator),
            .value_store = value_store,
        };
    }

    pub fn deinit(self: *ComptimeIntegration) void {
        self.executor.deinit();
    }

    /// Evaluate a comptime expression during semantic analysis
    pub fn evaluateComptimeExpr(self: *ComptimeIntegration, comptime_expr: *ast.ComptimeExpr) !ComptimeValue {
        // Evaluate the inner expression
        const value = try self.executor.eval(comptime_expr.expression);

        // Store the computed value for later use by codegen
        try self.value_store.store(comptime_expr.expression, value);

        return value;
    }

    /// Walk an expression tree and evaluate all comptime sub-expressions
    pub fn processExpression(self: *ComptimeIntegration, expr: *ast.Expr) anyerror!void {
        switch (expr.*) {
            .ComptimeExpr => |comptime_expr| {
                _ = try self.evaluateComptimeExpr(comptime_expr);
            },

            .BinaryExpr => |bin_expr| {
                try self.processExpression(bin_expr.left);
                try self.processExpression(bin_expr.right);
            },

            .UnaryExpr => |unary_expr| {
                try self.processExpression(unary_expr.operand);
            },

            .CallExpr => |call_expr| {
                try self.processExpression(call_expr.callee);
                for (call_expr.args) |arg| {
                    try self.processExpression(arg);
                }
            },

            .ArrayLiteral => |array_lit| {
                for (array_lit.elements) |elem| {
                    try self.processExpression(elem);
                }
            },

            .StructLiteral => |struct_lit| {
                for (struct_lit.fields) |field| {
                    try self.processExpression(field.value);
                }
            },

            .IfExpr => |if_expr| {
                try self.processExpression(if_expr.condition);
                try self.processExpression(if_expr.then_branch);
                try self.processExpression(if_expr.else_branch);
            },

            .BlockExpr => |block_expr| {
                for (block_expr.statements) |stmt| {
                    try self.processStatement(&stmt);
                }
            },

            .AssignmentExpr => |assign_expr| {
                try self.processExpression(assign_expr.target);
                try self.processExpression(assign_expr.value);
            },

            .IndexExpr => |index_expr| {
                try self.processExpression(index_expr.array);
                try self.processExpression(index_expr.index);
            },

            .MemberExpr => |member_expr| {
                try self.processExpression(member_expr.object);
            },

            .RangeExpr => |range_expr| {
                try self.processExpression(range_expr.start);
                try self.processExpression(range_expr.end);
            },

            .SliceExpr => |slice_expr| {
                try self.processExpression(slice_expr.array);
                if (slice_expr.start) |start| {
                    try self.processExpression(start);
                }
                if (slice_expr.end) |end| {
                    try self.processExpression(end);
                }
            },

            .TernaryExpr => |ternary_expr| {
                try self.processExpression(ternary_expr.condition);
                try self.processExpression(ternary_expr.true_expr);
                try self.processExpression(ternary_expr.false_expr);
            },

            .TryExpr => |try_expr| {
                try self.processExpression(try_expr.expression);
            },

            .TypeCastExpr => |cast_expr| {
                try self.processExpression(cast_expr.expression);
            },

            .TupleExpr => |tuple_expr| {
                for (tuple_expr.elements) |elem| {
                    try self.processExpression(elem);
                }
            },

            .MatchExpr => |match_expr| {
                try self.processExpression(match_expr.target);
                for (match_expr.arms) |arm| {
                    if (arm.guard) |guard| {
                        try self.processExpression(guard);
                    }
                    try self.processExpression(arm.body);
                }
            },

            .AwaitExpr => |await_expr| {
                try self.processExpression(await_expr.expression);
            },

            .NullCoalesceExpr => |null_coalesce| {
                try self.processExpression(null_coalesce.left);
                try self.processExpression(null_coalesce.right);
            },

            .SafeNavExpr => |safe_nav| {
                try self.processExpression(safe_nav.target);
            },

            .ClosureExpr => |closure_expr| {
                for (closure_expr.body.statements) |stmt| {
                    try self.processStatement(&stmt);
                }
            },

            // Leaf nodes - no sub-expressions
            .IntegerLiteral,
            .FloatLiteral,
            .StringLiteral,
            .CharLiteral,
            .BooleanLiteral,
            .NullLiteral,
            .Identifier => {},

            else => {
                // Unsupported expression types can be added as needed
            },
        }
    }

    /// Process a statement for comptime expressions
    pub fn processStatement(self: *ComptimeIntegration, stmt: *const ast.Stmt) anyerror!void {
        switch (stmt.*) {
            .LetDecl => |let_decl| {
                if (let_decl.value) |value| {
                    try self.processExpression(value);
                }
            },

            .ExprStmt => |expr_stmt| {
                try self.processExpression(expr_stmt);
            },

            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    try self.processExpression(val);
                }
            },

            .IfStmt => |if_stmt| {
                try self.processExpression(if_stmt.condition);
                for (if_stmt.then_block.statements) |s| {
                    try self.processStatement(&s);
                }
                if (if_stmt.else_block) |else_block| {
                    for (else_block.statements) |s| {
                        try self.processStatement(&s);
                    }
                }
            },

            .WhileStmt => |while_stmt| {
                try self.processExpression(while_stmt.condition);
                for (while_stmt.body.statements) |s| {
                    try self.processStatement(&s);
                }
            },

            .BlockStmt => |block_stmt| {
                for (block_stmt.statements) |s| {
                    try self.processStatement(&s);
                }
            },

            .ForStmt => |for_stmt| {
                try self.processExpression(for_stmt.iterable);
                for (for_stmt.body.statements) |s| {
                    try self.processStatement(&s);
                }
            },

            .MatchStmt => |match_stmt| {
                try self.processExpression(match_stmt.value);
                // Note: arm bodies are Expr, not BlockStmt, so handled by MatchExpr
            },

            .ConstDecl => {
                // Marker only
            },

            .BreakStmt, .ContinueStmt, .DeferStmt => {
                // No expressions to process
            },

            else => {
                // Unsupported statement types can be added as needed
            },
        }
    }

    /// Process an entire program for comptime expressions
    pub fn processProgram(self: *ComptimeIntegration, program: *ast.Program) !void {
        for (program.statements) |decl| {
            switch (decl) {
                .FnDecl => |func_decl| {
                    // Process statements in the function body directly
                    for (func_decl.body.statements) |stmt| {
                        try self.processStatement(&stmt);
                    }
                },

                .StructDecl => |struct_decl| {
                    // Process method bodies
                    for (struct_decl.methods) |method| {
                        for (method.body.statements) |stmt| {
                            try self.processStatement(&stmt);
                        }
                    }
                },

                .ImplDecl => |impl_decl| {
                    // Process method implementations
                    for (impl_decl.methods) |method| {
                        for (method.body.statements) |stmt| {
                            try self.processStatement(&stmt);
                        }
                    }
                },

                .ConstDecl => {
                    // ConstDecl is a type alias in Stmt union, no fields to process
                },

                .LetDecl => |let_decl| {
                    if (let_decl.value) |value| {
                        try self.processExpression(value);
                    }
                },

                else => {
                    // Type declarations and other top-level constructs
                },
            }
        }
    }
};

// ============================================================================
// Usage Example / Integration Guide
// ============================================================================

// Example of how to integrate comptime into the compilation pipeline:
//
// ```zig
// // In main.zig or type checker:
// //
// // 1. Create value store (lives for entire compilation)
// var comptime_store = ComptimeValueStore.init(allocator);
// defer comptime_store.deinit();
//
// // 2. After parsing, before codegen:
// var comptime_integration = try ComptimeIntegration.init(allocator, &comptime_store);
// defer comptime_integration.deinit();
//
// // 3. Process the AST to evaluate all comptime expressions
// try comptime_integration.processProgram(program);
//
// // 4. Pass comptime_store to codegen
// var codegen = try NativeCodegen.init(allocator, program, &comptime_store);
// ```

// ============================================================================
// Tests
// ============================================================================

test "ComptimeValueStore - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = ComptimeValueStore.init(allocator);
    defer store.deinit();

    // Create a dummy expression
    var expr = ast.Expr{ .Literal = undefined };

    // Initially should not have value
    try testing.expect(!store.has(&expr));
    try testing.expect(store.get(&expr) == null);

    // Store a value
    const value = ComptimeValue{ .int = 42 };
    try store.store(&expr, value);

    // Should now have value
    try testing.expect(store.has(&expr));

    const retrieved = store.get(&expr);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(i64, 42), retrieved.?.int);
}
