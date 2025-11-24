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
    pub fn processExpression(self: *ComptimeIntegration, expr: *ast.Expr) !void {
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
                for (call_expr.arguments) |arg| {
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
                if (if_expr.else_branch) |else_br| {
                    try self.processExpression(else_br);
                }
            },

            .BlockExpr => |block_expr| {
                for (block_expr.statements) |stmt| {
                    try self.processStatement(stmt);
                }
            },

            // Leaf nodes - no sub-expressions
            .Literal, .Identifier => {},

            else => {
                // TODO: Handle other expression types as needed
            },
        }
    }

    /// Process a statement for comptime expressions
    pub fn processStatement(self: *ComptimeIntegration, stmt: *ast.Stmt) !void {
        switch (stmt.*) {
            .LetDecl => |let_decl| {
                if (let_decl.initializer) |initializer| {
                    try self.processExpression(initializer);
                }
            },

            .ConstDecl => |const_decl| {
                if (const_decl.initializer) |initializer| {
                    try self.processExpression(initializer);
                }
            },

            .ExprStmt => |expr_stmt| {
                try self.processExpression(expr_stmt.expression);
            },

            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    try self.processExpression(val);
                }
            },

            .IfStmt => |if_stmt| {
                try self.processExpression(if_stmt.condition);
                try self.processStatement(if_stmt.then_branch);
                if (if_stmt.else_branch) |else_br| {
                    try self.processStatement(else_br);
                }
            },

            .WhileStmt => |while_stmt| {
                try self.processExpression(while_stmt.condition);
                try self.processStatement(while_stmt.body);
            },

            .BlockStmt => |block_stmt| {
                for (block_stmt.statements) |s| {
                    try self.processStatement(s);
                }
            },

            else => {
                // TODO: Handle other statement types
            },
        }
    }

    /// Process an entire program for comptime expressions
    pub fn processProgram(self: *ComptimeIntegration, program: *ast.Program) !void {
        for (program.statements) |decl| {
            switch (decl) {
                .FnDecl => |func_decl| {
                    if (func_decl.body) |body| {
                        try self.processStatement(body);
                    }
                },

                .ConstDecl => |const_decl| {
                    if (const_decl.initializer) |initializer| {
                        try self.processExpression(initializer);
                    }
                },

                else => {
                    // TODO: Handle other declaration types
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
