const std = @import("std");
const ast = @import("../ast/ast.zig");
const Value = @import("value.zig").Value;
const FunctionValue = @import("value.zig").FunctionValue;
const Environment = @import("environment.zig").Environment;

pub const InterpreterError = error{
    RuntimeError,
    UndefinedVariable,
    UndefinedFunction,
    TypeMismatch,
    DivisionByZero,
    InvalidArguments,
    Return, // Used for control flow
} || std.mem.Allocator.Error;

pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    global_env: Environment,
    program: *const ast.Program,
    return_value: ?Value,

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) Interpreter {
        return .{
            .allocator = allocator,
            .global_env = Environment.init(allocator, null),
            .program = program,
            .return_value = null,
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.global_env.deinit();
        if (self.return_value) |val| {
            val.deinit(self.allocator);
        }
    }

    pub fn interpret(self: *Interpreter) !void {
        // Register built-in functions
        try self.registerBuiltins();

        // Execute all statements
        for (self.program.statements) |stmt| {
            try self.executeStatement(stmt, &self.global_env);
        }
    }

    fn registerBuiltins(self: *Interpreter) !void {
        // Built-ins will be handled specially in function calls
        _ = self;
    }

    fn executeStatement(self: *Interpreter, stmt: ast.Stmt, env: *Environment) InterpreterError!void {
        switch (stmt) {
            .LetDecl => |decl| {
                const value = if (decl.value) |val_expr|
                    try self.evaluateExpression(val_expr, env)
                else
                    Value.Void;

                try env.define(decl.name, value);
            },
            .FnDecl => |fn_decl| {
                // Store function in environment
                const func_value = Value{
                    .Function = .{
                        .name = fn_decl.name,
                        .params = fn_decl.params,
                        .body = fn_decl.body,
                    },
                };
                try env.define(fn_decl.name, func_value);
            },
            .ReturnStmt => |ret| {
                const value = if (ret.value) |val_expr|
                    try self.evaluateExpression(val_expr, env)
                else
                    Value.Void;

                self.return_value = value;
                return error.Return;
            },
            .IfStmt => |if_stmt| {
                const condition = try self.evaluateExpression(if_stmt.condition, env);

                if (condition.isTrue()) {
                    for (if_stmt.then_block.statements) |then_stmt| {
                        self.executeStatement(then_stmt, env) catch |err| {
                            if (err == error.Return) return err;
                            return err;
                        };
                    }
                } else if (if_stmt.else_block) |else_block| {
                    for (else_block.statements) |else_stmt| {
                        self.executeStatement(else_stmt, env) catch |err| {
                            if (err == error.Return) return err;
                            return err;
                        };
                    }
                }

                condition.deinit(self.allocator);
            },
            .BlockStmt => |block| {
                var block_env = Environment.init(self.allocator, env);
                defer block_env.deinit();

                for (block.statements) |block_stmt| {
                    self.executeStatement(block_stmt, &block_env) catch |err| {
                        if (err == error.Return) return err;
                        return err;
                    };
                }
            },
            .ExprStmt => |expr| {
                const value = try self.evaluateExpression(expr, env);
                value.deinit(self.allocator);
            },
            else => {
                std.debug.print("Unimplemented statement type\n", .{});
                return error.RuntimeError;
            },
        }
    }

    fn evaluateExpression(self: *Interpreter, expr: *const ast.Expr, env: *Environment) InterpreterError!Value {
        switch (expr.*) {
            .IntegerLiteral => |lit| {
                return Value{ .Int = lit.value };
            },
            .FloatLiteral => |lit| {
                return Value{ .Float = lit.value };
            },
            .StringLiteral => |lit| {
                // Don't copy string literals - they live in the source
                return Value{ .String = lit.value };
            },
            .BooleanLiteral => |lit| {
                return Value{ .Bool = lit.value };
            },
            .Identifier => |id| {
                if (env.get(id.name)) |value| {
                    return value;
                }
                std.debug.print("Undefined variable: {s}\n", .{id.name});
                return error.UndefinedVariable;
            },
            .BinaryExpr => |binary| {
                return try self.evaluateBinaryExpression(binary, env);
            },
            .UnaryExpr => |unary| {
                return try self.evaluateUnaryExpression(unary, env);
            },
            .CallExpr => |call| {
                return try self.evaluateCallExpression(call, env);
            },
            else => {
                std.debug.print("Unimplemented expression type\n", .{});
                return error.RuntimeError;
            },
        }
    }

    fn evaluateBinaryExpression(self: *Interpreter, binary: *ast.BinaryExpr, env: *Environment) InterpreterError!Value {
        const left = try self.evaluateExpression(binary.left, env);
        defer left.deinit(self.allocator);
        const right = try self.evaluateExpression(binary.right, env);
        defer right.deinit(self.allocator);

        return switch (binary.op) {
            .Add => try self.applyAddition(left, right),
            .Sub => try self.applyArithmetic(left, right, .Sub),
            .Mul => try self.applyArithmetic(left, right, .Mul),
            .Div => try self.applyArithmetic(left, right, .Div),
            .Mod => try self.applyArithmetic(left, right, .Mod),
            .Equal => Value{ .Bool = try self.areEqual(left, right) },
            .NotEqual => Value{ .Bool = !(try self.areEqual(left, right)) },
            .Less => Value{ .Bool = try self.compare(left, right, .Less) },
            .LessEq => Value{ .Bool = try self.compare(left, right, .LessEq) },
            .Greater => Value{ .Bool = try self.compare(left, right, .Greater) },
            .GreaterEq => Value{ .Bool = try self.compare(left, right, .GreaterEq) },
            .And => Value{ .Bool = left.isTrue() and right.isTrue() },
            .Or => Value{ .Bool = left.isTrue() or right.isTrue() },
            else => {
                std.debug.print("Unimplemented binary operator\n", .{});
                return error.RuntimeError;
            },
        };
    }

    fn evaluateUnaryExpression(self: *Interpreter, unary: *ast.UnaryExpr, env: *Environment) InterpreterError!Value {
        const operand = try self.evaluateExpression(unary.operand, env);
        defer operand.deinit(self.allocator);

        return switch (unary.op) {
            .Neg => switch (operand) {
                .Int => |i| Value{ .Int = -i },
                .Float => |f| Value{ .Float = -f },
                else => error.TypeMismatch,
            },
            .Not => Value{ .Bool = !operand.isTrue() },
        };
    }

    fn evaluateCallExpression(self: *Interpreter, call: *ast.CallExpr, env: *Environment) InterpreterError!Value {
        // Get function name
        if (call.callee.* == .Identifier) {
            const func_name = call.callee.Identifier.name;

            // Handle built-in functions
            if (std.mem.eql(u8, func_name, "print")) {
                return try self.builtinPrint(call.args, env);
            } else if (std.mem.eql(u8, func_name, "assert")) {
                return try self.builtinAssert(call.args, env);
            }

            // Look up user-defined function
            if (env.get(func_name)) |func_value| {
                if (func_value == .Function) {
                    return try self.callUserFunction(func_value.Function, call.args, env);
                }
            }

            std.debug.print("Undefined function: {s}\n", .{func_name});
            return error.UndefinedFunction;
        }

        std.debug.print("Complex function calls not yet supported\n", .{});
        return error.RuntimeError;
    }

    fn callUserFunction(self: *Interpreter, func: FunctionValue, args: []const *const ast.Expr, parent_env: *Environment) InterpreterError!Value {
        // Check argument count
        if (args.len != func.params.len) {
            std.debug.print("Function {s} expects {d} arguments, got {d}\n", .{ func.name, func.params.len, args.len });
            return error.InvalidArguments;
        }

        // Create new environment for function scope
        var func_env = Environment.init(self.allocator, parent_env);
        defer func_env.deinit();

        // Bind parameters to arguments
        for (func.params, 0..) |param, i| {
            const arg_value = try self.evaluateExpression(args[i], parent_env);
            try func_env.define(param.name, arg_value);
        }

        // Execute function body
        for (func.body.statements) |stmt| {
            self.executeStatement(stmt, &func_env) catch |err| {
                if (err == error.Return) {
                    // Return statement was executed
                    const ret_value = self.return_value.?;
                    self.return_value = null;
                    return ret_value;
                }
                return err;
            };
        }

        // No explicit return, return void
        return Value.Void;
    }

    fn builtinPrint(self: *Interpreter, args: []const *const ast.Expr, env: *Environment) InterpreterError!Value {
        for (args, 0..) |arg, i| {
            if (i > 0) std.debug.print(" ", .{});
            const value = try self.evaluateExpression(arg, env);
            defer value.deinit(self.allocator);

            switch (value) {
                .Int => |v| std.debug.print("{d}", .{v}),
                .Float => |v| std.debug.print("{d}", .{v}),
                .Bool => |v| std.debug.print("{}", .{v}),
                .String => |s| std.debug.print("{s}", .{s}),
                .Function => |f| std.debug.print("<fn {s}>", .{f.name}),
                .Void => std.debug.print("void", .{}),
            }
        }
        std.debug.print("\n", .{});

        return Value.Void;
    }

    fn builtinAssert(self: *Interpreter, args: []const *const ast.Expr, env: *Environment) InterpreterError!Value {
        if (args.len != 1) {
            std.debug.print("assert() expects 1 argument, got {d}\n", .{args.len});
            return error.InvalidArguments;
        }

        const value = try self.evaluateExpression(args[0], env);
        defer value.deinit(self.allocator);

        if (!value.isTrue()) {
            std.debug.print("Assertion failed!\n", .{});
            return error.RuntimeError;
        }

        return Value.Void;
    }

    fn applyAddition(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        switch (left) {
            .Int => |l| switch (right) {
                .Int => |r| return Value{ .Int = l + r },
                .Float => |r| return Value{ .Float = @as(f64, @floatFromInt(l)) + r },
                else => return error.TypeMismatch,
            },
            .Float => |l| switch (right) {
                .Int => |r| return Value{ .Float = l + @as(f64, @floatFromInt(r)) },
                .Float => |r| return Value{ .Float = l + r },
                else => return error.TypeMismatch,
            },
            .String => |l| switch (right) {
                .String => |r| {
                    const result = try std.mem.concat(self.allocator, u8, &[_][]const u8{ l, r });
                    return Value{ .String = result };
                },
                else => return error.TypeMismatch,
            },
            else => return error.TypeMismatch,
        }
    }

    fn applyArithmetic(self: *Interpreter, left: Value, right: Value, op: ast.BinaryOp) InterpreterError!Value {
        _ = self;
        switch (left) {
            .Int => |l| switch (right) {
                .Int => |r| {
                    if (op == .Div and r == 0) return error.DivisionByZero;
                    return Value{ .Int = switch (op) {
                        .Sub => l - r,
                        .Mul => l * r,
                        .Div => @divTrunc(l, r),
                        .Mod => @mod(l, r),
                        else => unreachable,
                    } };
                },
                .Float => |r| {
                    if (op == .Div and r == 0.0) return error.DivisionByZero;
                    const lf = @as(f64, @floatFromInt(l));
                    return Value{ .Float = switch (op) {
                        .Sub => lf - r,
                        .Mul => lf * r,
                        .Div => lf / r,
                        .Mod => @mod(lf, r),
                        else => unreachable,
                    } };
                },
                else => return error.TypeMismatch,
            },
            .Float => |l| switch (right) {
                .Int => |r| {
                    const rf = @as(f64, @floatFromInt(r));
                    if (op == .Div and rf == 0.0) return error.DivisionByZero;
                    return Value{ .Float = switch (op) {
                        .Sub => l - rf,
                        .Mul => l * rf,
                        .Div => l / rf,
                        .Mod => @mod(l, rf),
                        else => unreachable,
                    } };
                },
                .Float => |r| {
                    if (op == .Div and r == 0.0) return error.DivisionByZero;
                    return Value{ .Float = switch (op) {
                        .Sub => l - r,
                        .Mul => l * r,
                        .Div => l / r,
                        .Mod => @mod(l, r),
                        else => unreachable,
                    } };
                },
                else => return error.TypeMismatch,
            },
            else => return error.TypeMismatch,
        }
    }

    fn areEqual(self: *Interpreter, left: Value, right: Value) InterpreterError!bool {
        _ = self;
        switch (left) {
            .Int => |l| switch (right) {
                .Int => |r| return l == r,
                .Float => |r| return @as(f64, @floatFromInt(l)) == r,
                else => return false,
            },
            .Float => |l| switch (right) {
                .Int => |r| return l == @as(f64, @floatFromInt(r)),
                .Float => |r| return l == r,
                else => return false,
            },
            .Bool => |l| switch (right) {
                .Bool => |r| return l == r,
                else => return false,
            },
            .String => |l| switch (right) {
                .String => |r| return std.mem.eql(u8, l, r),
                else => return false,
            },
            .Void => return right == .Void,
            .Function => return false, // Functions are not comparable
        }
    }

    fn compare(self: *Interpreter, left: Value, right: Value, op: ast.BinaryOp) InterpreterError!bool {
        _ = self;
        switch (left) {
            .Int => |l| switch (right) {
                .Int => |r| return switch (op) {
                    .Less => l < r,
                    .LessEq => l <= r,
                    .Greater => l > r,
                    .GreaterEq => l >= r,
                    else => unreachable,
                },
                .Float => |r| {
                    const lf = @as(f64, @floatFromInt(l));
                    return switch (op) {
                        .Less => lf < r,
                        .LessEq => lf <= r,
                        .Greater => lf > r,
                        .GreaterEq => lf >= r,
                        else => unreachable,
                    };
                },
                else => return error.TypeMismatch,
            },
            .Float => |l| switch (right) {
                .Int => |r| {
                    const rf = @as(f64, @floatFromInt(r));
                    return switch (op) {
                        .Less => l < rf,
                        .LessEq => l <= rf,
                        .Greater => l > rf,
                        .GreaterEq => l >= rf,
                        else => unreachable,
                    };
                },
                .Float => |r| return switch (op) {
                    .Less => l < r,
                    .LessEq => l <= r,
                    .Greater => l > r,
                    .GreaterEq => l >= r,
                    else => unreachable,
                },
                else => return error.TypeMismatch,
            },
            else => return error.TypeMismatch,
        }
    }
};
