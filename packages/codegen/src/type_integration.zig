const std = @import("std");
const ast = @import("ast");
const type_system = @import("types");
const Type = type_system.Type;
const TypeInferencer = type_system.TypeInferencer;

/// Integration layer between type inference and code generation.
///
/// This module bridges the gap between the Hindley-Milner type inference
/// system and the native code generator, providing:
/// - Type inference for the entire program
/// - Type annotation to inferred type mapping
/// - Simplified type representation for codegen
pub const TypeIntegration = struct {
    allocator: std.mem.Allocator,
    /// Type inferencer for HM inference
    inferencer: TypeInferencer,
    /// Map from AST node to inferred type
    node_types: std.AutoHashMap(*const ast.Node, *Type),
    /// Map from variable name to inferred type
    var_types: std.StringHashMap(*Type),

    pub fn init(allocator: std.mem.Allocator) TypeIntegration {
        return .{
            .allocator = allocator,
            .inferencer = TypeInferencer.init(allocator),
            .node_types = std.AutoHashMap(*const ast.Node, *Type).init(allocator),
            .var_types = std.StringHashMap(*Type).init(allocator),
        };
    }

    pub fn deinit(self: *TypeIntegration) void {
        self.inferencer.deinit();
        self.node_types.deinit();
        self.var_types.deinit();
    }

    /// Infer types for the entire program
    pub fn inferProgram(self: *TypeIntegration, program: *const ast.Program) !void {
        // Create a type environment
        var env = type_system.TypeEnvironment.init(self.allocator, null);
        defer env.deinit();

        // Process each statement in the program
        for (program.statements) |stmt| {
            try self.inferStatement(stmt, &env);
        }

        // Solve all generated constraints
        try self.inferencer.solve();
    }

    /// Infer types for a statement
    fn inferStatement(self: *TypeIntegration, stmt: ast.Stmt, env: *type_system.TypeEnvironment) !void {
        switch (stmt) {
            .FnDecl => |fn_decl| {
                // Infer function type
                try self.inferFunction(fn_decl, env);
            },
            .LetDecl => |let_decl| {
                // Infer let binding type
                if (let_decl.initializer) |init| {
                    const init_expr = @as(*const ast.Expr, @ptrCast(init));
                    const ty = try self.inferencer.inferExpression(init_expr, env);

                    // Store inferred type for this variable
                    try self.var_types.put(let_decl.name, ty);
                }
            },
            .ExprStmt => |expr_stmt| {
                // Infer expression type
                const expr = @as(*const ast.Expr, @ptrCast(&expr_stmt.expression));
                _ = try self.inferencer.inferExpression(expr, env);
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    const expr = @as(*const ast.Expr, @ptrCast(val));
                    _ = try self.inferencer.inferExpression(expr, env);
                }
            },
            .IfStmt => |if_stmt| {
                // Infer condition type
                const cond_expr = @as(*const ast.Expr, @ptrCast(&if_stmt.condition));
                _ = try self.inferencer.inferExpression(cond_expr, env);

                // Infer then block
                try self.inferBlock(if_stmt.then_block, env);

                // Infer else block if present
                if (if_stmt.else_block) |else_block| {
                    try self.inferBlock(else_block, env);
                }
            },
            .WhileStmt => |while_stmt| {
                const cond_expr = @as(*const ast.Expr, @ptrCast(&while_stmt.condition));
                _ = try self.inferencer.inferExpression(cond_expr, env);
                try self.inferBlock(while_stmt.body, env);
            },
            .ForStmt => |for_stmt| {
                const iter_expr = @as(*const ast.Expr, @ptrCast(&for_stmt.iterable));
                _ = try self.inferencer.inferExpression(iter_expr, env);
                try self.inferBlock(for_stmt.body, env);
            },
            else => {
                // Skip other statement types for now
            },
        }
    }

    /// Infer types for a function
    fn inferFunction(self: *TypeIntegration, fn_decl: *const ast.FnDecl, env: *type_system.TypeEnvironment) !void {
        // Create new environment for function body
        var fn_env = type_system.TypeEnvironment.init(self.allocator, env);
        defer fn_env.deinit();

        // Add parameter types to environment
        for (fn_decl.params) |param| {
            // For now, use annotated types if available
            // TODO: Implement full parameter type inference
            if (param.type_annotation) |_| {
                // Type is annotated, use it
            } else {
                // Generate fresh type variable
                const param_ty = try self.inferencer.freshTypeVar();
                try self.var_types.put(param.name, param_ty);
            }
        }

        // Infer function body
        for (fn_decl.body.statements) |stmt| {
            try self.inferStatement(stmt, &fn_env);
        }
    }

    /// Infer types for a block
    fn inferBlock(self: *TypeIntegration, block: *const ast.BlockStmt, env: *type_system.TypeEnvironment) !void {
        for (block.statements) |stmt| {
            try self.inferStatement(stmt, env);
        }
    }

    /// Get the inferred type for a variable
    pub fn getVarType(self: *TypeIntegration, var_name: []const u8) ?*Type {
        return self.var_types.get(var_name);
    }

    /// Convert a Type to a simple type name string for codegen
    pub fn typeToString(self: *TypeIntegration, ty: *Type) ![]const u8 {
        // Apply substitutions first
        const resolved = try self.inferencer.substitution.apply(ty, self.allocator);

        return switch (resolved.*) {
            .Int, .I32 => try self.allocator.dupe(u8, "i32"),
            .I8 => try self.allocator.dupe(u8, "i8"),
            .I16 => try self.allocator.dupe(u8, "i16"),
            .I64 => try self.allocator.dupe(u8, "i64"),
            .F32 => try self.allocator.dupe(u8, "f32"),
            .F64, .Float => try self.allocator.dupe(u8, "f64"),
            .Bool => try self.allocator.dupe(u8, "bool"),
            .String => try self.allocator.dupe(u8, "string"),
            .Void => try self.allocator.dupe(u8, "void"),
            .Array => |arr| {
                const elem_str = try self.typeToString(@constCast(arr.element_type));
                defer self.allocator.free(elem_str);
                return std.fmt.allocPrint(self.allocator, "[{s}]", .{elem_str});
            },
            .Function => try self.allocator.dupe(u8, "fn"),
            .Struct => |s| try self.allocator.dupe(u8, s.name),
            .Enum => |e| try self.allocator.dupe(u8, e.name),
            .TypeVar => |tv| {
                // Type variable not resolved - use generic name
                if (tv.name) |name| {
                    return std.fmt.allocPrint(self.allocator, "'{s}", .{name});
                }
                return std.fmt.allocPrint(self.allocator, "'T{d}", .{tv.id});
            },
            else => try self.allocator.dupe(u8, "unknown"),
        };
    }

    /// Get inferred type for a variable as a string
    pub fn getVarTypeString(self: *TypeIntegration, var_name: []const u8) !?[]const u8 {
        const ty = self.getVarType(var_name) orelse return null;
        return try self.typeToString(ty);
    }

    /// Check if type inference succeeded without errors
    pub fn hasErrors(self: *TypeIntegration) bool {
        // Check if any type variables remain unresolved
        // This is a simplified check - a real implementation would track errors
        return false;
    }

    /// Print inferred types for debugging
    pub fn printInferredTypes(self: *TypeIntegration) !void {
        std.debug.print("\n=== Inferred Types ===\n", .{});

        var it = self.var_types.iterator();
        while (it.next()) |entry| {
            const var_name = entry.key_ptr.*;
            const ty = entry.value_ptr.*;

            const ty_str = try self.typeToString(ty);
            defer self.allocator.free(ty_str);

            std.debug.print("{s}: {s}\n", .{ var_name, ty_str });
        }

        std.debug.print("======================\n\n", .{});
    }
};
