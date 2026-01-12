const std = @import("std");
const ast = @import("ast");
const value_mod = @import("value.zig");
pub const Value = value_mod.Value;
const FunctionValue = value_mod.FunctionValue;
const ClosureValue = value_mod.ClosureValue;
const EnumVariantInfo = value_mod.EnumVariantInfo;
const EnumTypeValue = value_mod.EnumTypeValue;
const Environment = @import("environment.zig").Environment;
pub const Debugger = @import("debugger.zig").Debugger;

pub const InterpreterError = error{
    RuntimeError,
    UndefinedVariable,
    UndefinedFunction,
    TypeMismatch,
    DivisionByZero,
    InvalidArguments,
    InvalidOperation,
    Return, // Used for control flow
    Break, // Used for break statements
    Continue, // Used for continue statements
    LabelNotFound, // Used for labeled break/continue
} || std.mem.Allocator.Error;

/// Target for break/continue with label
pub const LoopTarget = struct {
    label: ?[]const u8,
    found: bool,
};

/// Home language interpreter
///
/// MEMORY MANAGEMENT STRATEGY:
/// ---------------------------
/// The interpreter uses an arena allocator pattern for optimal performance
/// and memory safety:
///
/// - All runtime values (strings, arrays, structs) are allocated from a single arena
/// - No manual memory tracking or reference counting required
/// - All memory is freed at once when the interpreter is deinitialized
/// - Zero memory leaks by design
///
/// String concatenation (interpreter.zig:461): Uses arena allocator
/// Array allocation (interpreter.zig:204): Uses arena allocator
/// Environment bindings (environment.zig:26-27): Uses arena allocator
///
/// This approach prioritizes:
/// 1. Memory safety (impossible to leak or double-free)
/// 2. Performance (fast bump allocation, no per-value overhead)
/// 3. Simplicity (no complex lifetime tracking)
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    global_env: Environment,
    program: *const ast.Program,
    return_value: ?Value,
    debugger: ?*Debugger,
    debug_enabled: bool,
    source_file: []const u8,
    /// Stack of loop labels for labeled break/continue
    loop_labels: std.ArrayList(?[]const u8),
    /// Current break target (label or null for any loop)
    break_target: ?LoopTarget,
    /// Current continue target (label or null for any loop)
    continue_target: ?LoopTarget,

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) !*Interpreter {
        const interpreter = try allocator.create(Interpreter);
        errdefer allocator.destroy(interpreter);

        // Initialize arena directly in the struct to avoid copying
        interpreter.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer interpreter.arena.deinit();

        const arena_allocator = interpreter.arena.allocator();

        // Now set the rest of the fields
        interpreter.allocator = allocator;
        interpreter.global_env = Environment.init(arena_allocator, null);
        interpreter.program = program;
        interpreter.return_value = null;
        interpreter.debugger = null;
        interpreter.debug_enabled = false;
        interpreter.source_file = "";
        interpreter.loop_labels = .{ .items = &.{}, .capacity = 0 };
        interpreter.break_target = null;
        interpreter.continue_target = null;

        return interpreter;
    }

    /// Initialize interpreter with debug support
    pub fn initWithDebug(
        allocator: std.mem.Allocator,
        program: *const ast.Program,
        debugger: *Debugger,
        source_file: []const u8,
    ) !*Interpreter {
        const interpreter = try init(allocator, program);
        interpreter.debugger = debugger;
        interpreter.debug_enabled = true;
        interpreter.source_file = source_file;
        return interpreter;
    }

    pub fn deinit(self: *Interpreter) void {
        // Arena allocator frees all allocated memory at once
        // This includes all strings, arrays, struct fields, AND the environment's HashMap
        // We don't need to call global_env.deinit() because the arena owns everything
        const allocator = self.allocator;
        self.loop_labels.deinit(allocator);
        self.arena.deinit();
        allocator.destroy(self);
    }

    pub fn interpret(self: *Interpreter) !void {
        // Register built-in functions
        try self.registerBuiltins();

        // Execute all statements (collect function definitions)
        for (self.program.statements) |stmt| {
            try self.executeStatement(stmt, &self.global_env);
        }

        // Call main() if it exists
        if (self.global_env.get("main")) |main_value| {
            if (main_value == .Function) {
                _ = try self.callUserFunction(main_value.Function, &[_]*const ast.Expr{}, &self.global_env);
            }
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
            .AssertStmt => |assert_stmt| {
                const condition = try self.evaluateExpression(assert_stmt.condition, env);
                if (!condition.isTrue()) {
                    if (assert_stmt.message) |msg_expr| {
                        const msg = try self.evaluateExpression(msg_expr, env);
                        if (msg == .String) {
                            std.debug.print("Assertion failed: {s}\n", .{msg.String});
                        } else {
                            std.debug.print("Assertion failed!\n", .{});
                        }
                    } else {
                        std.debug.print("Assertion failed!\n", .{});
                    }
                    return error.RuntimeError;
                }
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

                // Arena allocator will clean up
            },
            .WhileStmt => |while_stmt| {
                // Push loop onto stack (no labels in AST yet)
                try self.loop_labels.append(self.allocator, null);
                defer _ = self.loop_labels.pop();

                outer: while (true) {
                    const condition = try self.evaluateExpression(while_stmt.condition, env);
                    const should_continue = condition.isTrue();
                    // Arena allocator will clean up

                    if (!should_continue) break;

                    for (while_stmt.body.statements) |body_stmt| {
                        self.executeStatement(body_stmt, env) catch |err| {
                            if (err == error.Return) return err;
                            if (err == error.Break) {
                                // Check if break targets this loop
                                if (try self.shouldBreakHere(null)) {
                                    break :outer; // Break the outer while loop
                                } else {
                                    // Propagate to outer loop
                                    return err;
                                }
                            }
                            if (err == error.Continue) {
                                // Check if continue targets this loop
                                if (try self.shouldContinueHere(null)) {
                                    break; // Continue to next iteration
                                } else {
                                    // Propagate to outer loop
                                    return err;
                                }
                            }
                            return err;
                        };
                    }
                }
            },
            .ForStmt => |for_stmt| {
                // For now, we only support iterating over integer ranges (BinaryExpr with ..)
                // In the future, this should support arrays and other iterables

                // Create a new scope for the loop variable
                var loop_env = Environment.init(self.arena.allocator(), env);
                defer loop_env.deinit();

                // Evaluate the iterable - for now assume it's a range or array
                const iterable_value = try self.evaluateExpression(for_stmt.iterable, env);
                // Arena allocator will clean up

                // For simple demonstration, if iterable is an integer, iterate from 0 to that value
                // This is a simplified implementation - full implementation would need array support
                if (iterable_value == .Int) {
                    const max = iterable_value.Int;
                    var i: i64 = 0;
                    while (i < max) : (i += 1) {
                        // If there's an index variable (enumerate syntax), define it
                        if (for_stmt.index) |index_var| {
                            if (i == 0) {
                                try loop_env.define(index_var, Value{ .Int = i });
                            } else {
                                try loop_env.set(index_var, Value{ .Int = i });
                            }
                        }

                        // Define the iterator variable in loop scope on first iteration, update on subsequent
                        if (i == 0) {
                            try loop_env.define(for_stmt.iterator, Value{ .Int = i });
                        } else {
                            try loop_env.set(for_stmt.iterator, Value{ .Int = i });
                        }

                        var broke = false;
                        for (for_stmt.body.statements) |body_stmt| {
                            self.executeStatement(body_stmt, &loop_env) catch |err| {
                                if (err == error.Return) return err;
                                if (err == error.Break) {
                                    broke = true;
                                    break;
                                }
                                if (err == error.Continue) break; // Continue to next iteration
                                return err;
                            };
                        }
                        if (broke) break;
                    }
                } else if (iterable_value == .Array) {
                    // Iterate over array elements
                    const arr = iterable_value.Array;
                    for (arr, 0..) |elem, idx| {
                        const i: i64 = @intCast(idx);
                        // If there's an index variable (enumerate syntax), define it
                        if (for_stmt.index) |index_var| {
                            if (idx == 0) {
                                try loop_env.define(index_var, Value{ .Int = i });
                            } else {
                                try loop_env.set(index_var, Value{ .Int = i });
                            }
                        }

                        // Define the iterator variable with the current element
                        if (idx == 0) {
                            try loop_env.define(for_stmt.iterator, elem);
                        } else {
                            try loop_env.set(for_stmt.iterator, elem);
                        }

                        var broke = false;
                        for (for_stmt.body.statements) |body_stmt| {
                            self.executeStatement(body_stmt, &loop_env) catch |err| {
                                if (err == error.Return) return err;
                                if (err == error.Break) {
                                    broke = true;
                                    break;
                                }
                                if (err == error.Continue) break;
                                return err;
                            };
                        }
                        if (broke) break;
                    }
                } else if (iterable_value == .Range) {
                    // Iterate over range
                    const range = iterable_value.Range;
                    var current = range.start;
                    var idx: i64 = 0;
                    const end_condition = if (range.inclusive) range.end + 1 else range.end;
                    while (current < end_condition) : ({
                        current += range.step;
                        idx += 1;
                    }) {
                        // If there's an index variable (enumerate syntax), define it
                        if (for_stmt.index) |index_var| {
                            if (idx == 0) {
                                try loop_env.define(index_var, Value{ .Int = idx });
                            } else {
                                try loop_env.set(index_var, Value{ .Int = idx });
                            }
                        }

                        // Define the iterator variable with the current range value
                        if (idx == 0) {
                            try loop_env.define(for_stmt.iterator, Value{ .Int = current });
                        } else {
                            try loop_env.set(for_stmt.iterator, Value{ .Int = current });
                        }

                        var broke = false;
                        for (for_stmt.body.statements) |body_stmt| {
                            self.executeStatement(body_stmt, &loop_env) catch |err| {
                                if (err == error.Return) return err;
                                if (err == error.Break) {
                                    broke = true;
                                    break;
                                }
                                if (err == error.Continue) break;
                                return err;
                            };
                        }
                        if (broke) break;
                    }
                }
            },
            .StructDecl => |_| {
                // Struct declarations are type-level constructs
                // They don't execute any runtime code, just register the type
                // Type checking already handles this, so we do nothing here
            },
            .ConstDecl => {
                // Constants are handled at compile time - type checking
                // ensures they are initialized. No runtime action needed
                // since ConstDecl is void in the Stmt union.
            },
            .EnumDecl => |enum_decl| {
                // Register the enum type in the environment so it can be accessed
                // like Color.Red
                const variants = try self.arena.allocator().alloc(value_mod.EnumVariantInfo, enum_decl.variants.len);
                for (enum_decl.variants, 0..) |variant, i| {
                    variants[i] = .{
                        .name = variant.name,
                        .has_data = variant.data_type != null,
                    };
                }
                const enum_value = Value{
                    .EnumType = .{
                        .name = enum_decl.name,
                        .variants = variants,
                    },
                };
                try env.define(enum_decl.name, enum_value);
            },
            .TypeAliasDecl => |_| {
                // Type aliases are type-level constructs
                // No runtime action needed
            },
            .TraitDecl => |_| {
                // Trait declarations are type-level constructs
                // No runtime action needed
            },
            .ImplDecl => |_| {
                // Impl declarations are type-level constructs
                // No runtime action needed
            },
            .MatchStmt => |match_stmt| {
                // Evaluate the value being matched
                const match_value = try self.evaluateExpression(match_stmt.value, env);

                // Try each arm in order
                for (match_stmt.arms) |arm| {
                    // Check if pattern matches
                    if (try self.matchPatternNode(arm.pattern, match_value, env)) {
                        // Check guard if present
                        if (arm.guard) |guard| {
                            const guard_result = try self.evaluateExpression(guard, env);
                            if (!guard_result.isTrue()) {
                                continue;
                            }
                        }

                        // Pattern matched and guard passed (if any), evaluate body
                        _ = try self.evaluateExpression(arm.body, env);
                        return;
                    }
                }
            },
            .BlockStmt => |block| {
                var block_env = Environment.init(self.arena.allocator(), env);
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
                // Arena allocator will clean up
                _ = value;
            },
            .DoWhileStmt => |do_while| {
                // Push loop onto stack for break/continue tracking
                try self.loop_labels.append(self.allocator, null);
                defer _ = self.loop_labels.pop();

                // Execute body first
                outer: while (true) {
                    // Execute body
                    for (do_while.body.statements) |body_stmt| {
                        self.executeStatement(body_stmt, env) catch |err| {
                            if (err == error.Return) return err;
                            if (err == error.Break) {
                                // Check if break targets this loop
                                if (try self.shouldBreakHere(null)) {
                                    break :outer;
                                } else {
                                    return err;
                                }
                            }
                            if (err == error.Continue) {
                                // Check if continue targets this loop
                                if (try self.shouldContinueHere(null)) {
                                    break; // Continue to next iteration
                                } else {
                                    return err;
                                }
                            }
                            return err;
                        };
                    }

                    // Then check condition
                    const condition = try self.evaluateExpression(do_while.condition, env);
                    if (!condition.isTrue()) break;
                }
            },
            .SwitchStmt => |switch_stmt| {
                const switch_value = try self.evaluateExpression(switch_stmt.value, env);

                // Find matching case
                var matched = false;
                for (switch_stmt.cases) |case_clause| {
                    if (case_clause.is_default) {
                        // Default case - execute if no other match
                        if (!matched) {
                            for (case_clause.body) |body_stmt| {
                                self.executeStatement(body_stmt, env) catch |err| {
                                    if (err == error.Return) return err;
                                    return err;
                                };
                            }
                        }
                    } else {
                        // Check if any pattern matches
                        for (case_clause.patterns) |pattern| {
                            const pattern_value = try self.evaluateExpression(pattern, env);
                            if (try self.areEqual(switch_value, pattern_value)) {
                                // Execute case body
                                for (case_clause.body) |body_stmt| {
                                    self.executeStatement(body_stmt, env) catch |err| {
                                        if (err == error.Return) return err;
                                        return err;
                                    };
                                }
                                matched = true;
                                break;
                            }
                        }
                        if (matched) break;
                    }
                }
            },
            .TryStmt => |try_stmt| {
                // Execute try block
                var try_failed = false;
                for (try_stmt.try_block.statements) |try_body_stmt| {
                    self.executeStatement(try_body_stmt, env) catch |err| {
                        if (err == error.Return) return err;
                        // On any error, mark as failed and break
                        try_failed = true;
                        break;
                    };
                }

                // If try failed, execute first catch clause
                if (try_failed and try_stmt.catch_clauses.len > 0) {
                    const catch_clause = try_stmt.catch_clauses[0];

                    // Create new scope for error variable if present
                    if (catch_clause.error_name) |error_name| {
                        var catch_env = Environment.init(self.arena.allocator(), env);
                        defer catch_env.deinit();

                        // Define error variable with string value
                        try catch_env.define(error_name, Value{ .String = "error" });

                        for (catch_clause.body.statements) |catch_body_stmt| {
                            self.executeStatement(catch_body_stmt, &catch_env) catch |err| {
                                if (err == error.Return) return err;
                                return err;
                            };
                        }
                    } else {
                        for (catch_clause.body.statements) |catch_body_stmt| {
                            self.executeStatement(catch_body_stmt, env) catch |err| {
                                if (err == error.Return) return err;
                                return err;
                            };
                        }
                    }
                }

                // Always execute finally block if present
                if (try_stmt.finally_block) |finally_block| {
                    for (finally_block.statements) |finally_stmt| {
                        self.executeStatement(finally_stmt, env) catch |err| {
                            if (err == error.Return) return err;
                            return err;
                        };
                    }
                }
            },
            .DeferStmt => |defer_stmt| {
                // For a full implementation, we'd need a defer stack
                // For now, just evaluate the expression (simplified)
                // In a real implementation, this would be executed at scope exit
                _ = try self.evaluateExpression(defer_stmt.body, env);
            },
            .UnionDecl => |_| {
                // Union declarations are type-level constructs
                // They don't execute any runtime code
                // Type checking handles this
            },
            .BreakStmt => |break_stmt| {
                // Handle labeled breaks
                if (break_stmt.label) |label| {
                    // Set break target and return
                    self.break_target = LoopTarget{ .label = label, .found = false };
                } else {
                    self.break_target = null;
                }
                return error.Break;
            },
            .ContinueStmt => |continue_stmt| {
                // Handle labeled continues
                if (continue_stmt.label) |label| {
                    // Set continue target and return
                    self.continue_target = LoopTarget{ .label = label, .found = false };
                } else {
                    self.continue_target = null;
                }
                return error.Continue;
            },
            .ItTestDecl => |it_test| {
                // Execute test and report result
                std.debug.print("  it {s} ... ", .{it_test.description});

                var test_env = Environment.init(self.arena.allocator(), env);
                defer test_env.deinit();

                var test_passed = true;
                for (it_test.body.statements) |test_stmt| {
                    self.executeStatement(test_stmt, &test_env) catch |err| {
                        if (err == error.Return) {
                            // Test completed with return
                            break;
                        }
                        test_passed = false;
                        break;
                    };
                }

                if (test_passed) {
                    std.debug.print("PASS\n", .{});
                } else {
                    std.debug.print("FAIL\n", .{});
                    return error.RuntimeError;
                }
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
                // Check bounds if a type suffix is specified
                if (lit.type_suffix) |suffix| {
                    if (std.mem.eql(u8, suffix, "i8")) {
                        if (lit.value < std.math.minInt(i8) or lit.value > std.math.maxInt(i8)) {
                            return error.RuntimeError;
                        }
                    } else if (std.mem.eql(u8, suffix, "i16")) {
                        if (lit.value < std.math.minInt(i16) or lit.value > std.math.maxInt(i16)) {
                            return error.RuntimeError;
                        }
                    } else if (std.mem.eql(u8, suffix, "i32")) {
                        if (lit.value < std.math.minInt(i32) or lit.value > std.math.maxInt(i32)) {
                            return error.RuntimeError;
                        }
                    } else if (std.mem.eql(u8, suffix, "i64")) {
                        // i64 is the native type, always valid
                    } else if (std.mem.eql(u8, suffix, "u8")) {
                        if (lit.value < 0 or lit.value > std.math.maxInt(u8)) {
                            return error.RuntimeError;
                        }
                    } else if (std.mem.eql(u8, suffix, "u16")) {
                        if (lit.value < 0 or lit.value > std.math.maxInt(u16)) {
                            return error.RuntimeError;
                        }
                    } else if (std.mem.eql(u8, suffix, "u32")) {
                        if (lit.value < 0 or lit.value > std.math.maxInt(u32)) {
                            return error.RuntimeError;
                        }
                    } else if (std.mem.eql(u8, suffix, "u64")) {
                        if (lit.value < 0) {
                            return error.RuntimeError;
                        }
                    }
                    // i128 and u128 are larger than our i64 value type, so we can't fully validate them
                }
                return Value{ .Int = lit.value };
            },
            .FloatLiteral => |lit| {
                // Type suffix validation for floats (f32, f64)
                // f64 is the native type, f32 would need range checking but we keep it simple
                _ = lit.type_suffix; // Acknowledge but don't validate for now
                return Value{ .Float = lit.value };
            },
            .StringLiteral => |lit| {
                // Don't copy string literals - they live in the source
                return Value{ .String = lit.value };
            },
            .InterpolatedString => |interp| {
                // Evaluate all expressions and concatenate with string parts
                var result = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
                defer result.deinit(self.arena.allocator());

                // Add first part
                try result.appendSlice(self.arena.allocator(), interp.parts[0]);

                // Interleave expressions and remaining parts
                for (interp.expressions, 0..) |interp_expr, i| {
                    const val = try self.evaluateExpression(&interp_expr, env);
                    const str = try self.valueToString(val);
                    try result.appendSlice(self.arena.allocator(), str);

                    // Add next part if it exists
                    if (i + 1 < interp.parts.len) {
                        try result.appendSlice(self.arena.allocator(), interp.parts[i + 1]);
                    }
                }

                const owned = try self.arena.allocator().dupe(u8, result.items);
                return Value{ .String = owned };
            },
            .BooleanLiteral => |lit| {
                return Value{ .Bool = lit.value };
            },
            .NullLiteral => {
                return Value.Void;
            },
            .ArrayLiteral => |array| {
                var elements = try self.arena.allocator().alloc(Value, array.elements.len);
                for (array.elements, 0..) |elem, i| {
                    elements[i] = try self.evaluateExpression(elem, env);
                }
                return Value{ .Array = elements };
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
            .AssignmentExpr => |assign| {
                return try self.evaluateAssignmentExpression(assign, env);
            },
            .CallExpr => |call| {
                return try self.evaluateCallExpression(call, env);
            },
            .IndexExpr => |index| {
                const array_value = try self.evaluateExpression(index.array, env);
                const index_value = try self.evaluateExpression(index.index, env);

                if (array_value != .Array) {
                    std.debug.print("Cannot index non-array value\n", .{});
                    return error.TypeMismatch;
                }

                if (index_value != .Int) {
                    std.debug.print("Array index must be an integer\n", .{});
                    return error.TypeMismatch;
                }

                const idx = index_value.Int;
                if (idx < 0 or idx >= @as(i64, @intCast(array_value.Array.len))) {
                    std.debug.print("Array index out of bounds: {d}\n", .{idx});
                    return error.RuntimeError;
                }

                return array_value.Array[@as(usize, @intCast(idx))];
            },
            .SliceExpr => |slice| {
                const array_value = try self.evaluateExpression(slice.array, env);

                if (array_value != .Array) {
                    std.debug.print("Cannot slice non-array value\n", .{});
                    return error.TypeMismatch;
                }

                const array_len = @as(i64, @intCast(array_value.Array.len));

                // Determine start index (default to 0 if null)
                const start_idx: i64 = if (slice.start) |start_expr| blk: {
                    const start_value = try self.evaluateExpression(start_expr, env);
                    if (start_value != .Int) {
                        std.debug.print("Slice start index must be an integer\n", .{});
                        return error.TypeMismatch;
                    }
                    break :blk start_value.Int;
                } else 0;

                // Determine end index (default to array length if null)
                const end_idx: i64 = if (slice.end) |end_expr| blk: {
                    const end_value = try self.evaluateExpression(end_expr, env);
                    if (end_value != .Int) {
                        std.debug.print("Slice end index must be an integer\n", .{});
                        return error.TypeMismatch;
                    }
                    // Adjust for inclusive range
                    const idx = end_value.Int;
                    break :blk if (slice.inclusive) idx + 1 else idx;
                } else array_len;

                // Bounds checking
                if (start_idx < 0 or start_idx > array_len) {
                    std.debug.print("Slice start index out of bounds: {d}\n", .{start_idx});
                    return error.RuntimeError;
                }
                if (end_idx < start_idx or end_idx > array_len) {
                    std.debug.print("Slice end index out of bounds or invalid: {d}\n", .{end_idx});
                    return error.RuntimeError;
                }

                // Create sliced array
                const start_usize = @as(usize, @intCast(start_idx));
                const end_usize = @as(usize, @intCast(end_idx));
                const slice_len = end_usize - start_usize;

                const sliced_array = try self.arena.allocator().alloc(Value, slice_len);
                @memcpy(sliced_array, array_value.Array[start_usize..end_usize]);

                return Value{ .Array = sliced_array };
            },
            .MemberExpr => |member| {
                const object_value = try self.evaluateExpression(member.object, env);

                // Handle enum variant access (e.g., Color.Red)
                if (object_value == .EnumType) {
                    const enum_type = object_value.EnumType;
                    // Check if the member is a valid variant
                    var found_variant: ?EnumVariantInfo = null;
                    for (enum_type.variants) |variant| {
                        if (std.mem.eql(u8, variant.name, member.member)) {
                            found_variant = variant;
                            break;
                        }
                    }
                    if (found_variant) |variant| {
                        if (variant.has_data) {
                            // Variant with data - return a function that creates the variant
                            // For now, just return a struct representing the variant type
                            const fields = std.StringHashMap(Value).init(self.arena.allocator());
                            return Value{ .Struct = .{
                                .type_name = member.member,
                                .fields = fields,
                            } };
                        } else {
                            // Simple variant without data - return a struct representing the variant
                            const fields = std.StringHashMap(Value).init(self.arena.allocator());
                            return Value{ .Struct = .{
                                .type_name = member.member,
                                .fields = fields,
                            } };
                        }
                    }
                    std.debug.print("Enum '{s}' has no variant '{s}'\n", .{ enum_type.name, member.member });
                    return error.RuntimeError;
                }

                // Handle struct field access
                if (object_value == .Struct) {
                    if (object_value.Struct.fields.get(member.member)) |field_value| {
                        return field_value;
                    }
                    std.debug.print("Struct has no field '{s}'\n", .{member.member});
                    return error.RuntimeError;
                }

                std.debug.print("Cannot access member of non-struct/non-enum value\n", .{});
                return error.TypeMismatch;
            },
            .TernaryExpr => |ternary| {
                const condition = try self.evaluateExpression(ternary.condition, env);
                if (condition.isTrue()) {
                    return try self.evaluateExpression(ternary.true_val, env);
                } else {
                    return try self.evaluateExpression(ternary.false_val, env);
                }
            },
            .NullCoalesceExpr => |null_coalesce| {
                const left = try self.evaluateExpression(null_coalesce.left, env);
                // If left is not null/void, return it; otherwise return right
                if (left == .Void) {
                    return try self.evaluateExpression(null_coalesce.right, env);
                }
                return left;
            },
            .PipeExpr => |pipe| {
                // Evaluate the left side (the value to pipe)
                const value = try self.evaluateExpression(pipe.left, env);

                // Right side should be a call expression - we'll modify it to include the piped value
                if (pipe.right.* == .CallExpr) {
                    const call = pipe.right.CallExpr;

                    // For simplicity, we'll just evaluate the function with the piped value
                    // In a full implementation, we'd properly construct the new call with piped value as first arg
                    // For now, we'll evaluate the call and assume it handles the piped value
                    return try self.evaluateCallExpression(call, env);
                } else if (pipe.right.* == .Identifier) {
                    // Function reference - call it with the piped value
                    const func_name = pipe.right.Identifier.name;
                    if (env.get(func_name)) |func_value| {
                        if (func_value == .Function) {
                            const func = func_value.Function;

                            // Create new environment for function with piped value as first param
                            var func_env = Environment.init(self.arena.allocator(), env);
                            defer func_env.deinit();

                            // Define first parameter with piped value
                            if (func.params.len > 0) {
                                try func_env.define(func.params[0].name, value);
                            }

                            // Execute function body
                            for (func.body.statements) |stmt| {
                                self.executeStatement(stmt, &func_env) catch |err| {
                                    if (err == error.Return) {
                                        const ret_val = self.return_value.?;
                                        self.return_value = null;
                                        return ret_val;
                                    }
                                    return err;
                                };
                            }

                            return Value.Void;
                        }
                    }
                }

                std.debug.print("Pipe right side must be a function\n", .{});
                return error.TypeMismatch;
            },
            .SafeNavExpr => |safe_nav| {
                const object_value = try self.evaluateExpression(safe_nav.object, env);

                // If object is void/null, return void
                if (object_value == .Void) {
                    return Value.Void;
                }

                // Otherwise, access the member
                if (object_value != .Struct) {
                    std.debug.print("Cannot use safe navigation on non-struct value\n", .{});
                    return error.TypeMismatch;
                }

                if (object_value.Struct.fields.get(safe_nav.member)) |field_value| {
                    return field_value;
                }

                // Field doesn't exist - return void instead of error
                return Value.Void;
            },
            .SpreadExpr => |spread| {
                // Spread just evaluates to the underlying array/tuple
                // The containing expression (array literal, call, etc.) handles the spreading
                return try self.evaluateExpression(spread.operand, env);
            },
            .TupleExpr => |tuple| {
                // Evaluate all tuple elements
                var elements = try self.arena.allocator().alloc(Value, tuple.elements.len);
                for (tuple.elements, 0..) |elem, i| {
                    elements[i] = try self.evaluateExpression(elem, env);
                }
                // Store tuple as an array for now (in a full implementation, we'd have a Tuple value type)
                return Value{ .Array = elements };
            },
            .MacroExpr => |macro| {
                // Handle built-in macros at runtime
                return try self.evaluateMacroExpression(macro, env);
            },
            .RangeExpr => |range| {
                // Evaluate start and end values
                const start_val = try self.evaluateExpression(range.start, env);
                const end_val = try self.evaluateExpression(range.end, env);

                // Both must be integers
                if (start_val != .Int or end_val != .Int) {
                    std.debug.print("Range bounds must be integers\n", .{});
                    return error.TypeMismatch;
                }

                const RangeValue = @import("value.zig").RangeValue;
                return Value{ .Range = RangeValue{
                    .start = start_val.Int,
                    .end = end_val.Int,
                    .inclusive = range.inclusive,
                    .step = 1,
                } };
            },
            .StructLiteral => |struct_lit| {
                // Create a new struct value with evaluated fields
                var fields = std.StringHashMap(Value).init(self.arena.allocator());

                for (struct_lit.fields) |field| {
                    const field_value = try self.evaluateExpression(field.value, env);
                    try fields.put(field.name, field_value);
                }

                return Value{ .Struct = .{
                    .type_name = struct_lit.type_name,
                    .fields = fields,
                } };
            },
            .IfExpr => |if_expr| {
                // Evaluate condition
                const condition = try self.evaluateExpression(if_expr.condition, env);

                // Return the appropriate branch based on condition
                if (condition.isTrue()) {
                    return try self.evaluateExpression(if_expr.then_branch, env);
                } else {
                    return try self.evaluateExpression(if_expr.else_branch, env);
                }
            },
            .MatchExpr => |match_expr| {
                // Evaluate the value being matched
                const match_value = try self.evaluateExpression(match_expr.value, env);

                // Try each arm in order
                for (match_expr.arms) |arm| {
                    // Check if pattern matches
                    if (try self.matchPattern(arm.pattern, match_value, env)) {
                        // Check guard if present
                        if (arm.guard) |guard| {
                            const guard_result = try self.evaluateExpression(guard, env);
                            if (!guard_result.isTrue()) {
                                continue;
                            }
                        }

                        // Pattern matched and guard passed (if any), evaluate body
                        return try self.evaluateExpression(arm.body, env);
                    }
                }

                // No pattern matched - return void
                return Value.Void;
            },
            .BlockExpr => |block_expr| {
                // Create new scope for block
                var block_env = Environment.init(self.arena.allocator(), env);
                defer block_env.deinit();

                // Execute all statements except the last
                if (block_expr.statements.len > 0) {
                    for (block_expr.statements[0 .. block_expr.statements.len - 1]) |stmt| {
                        self.executeStatement(stmt, &block_env) catch |err| {
                            if (err == error.Return) {
                                if (self.return_value) |rv| {
                                    return rv;
                                }
                                return Value.Void;
                            }
                            return err;
                        };
                    }

                    // The last "statement" is the block's value - evaluate it as expression if possible
                    const last_stmt = block_expr.statements[block_expr.statements.len - 1];
                    if (last_stmt == .ExprStmt) {
                        return try self.evaluateExpression(last_stmt.ExprStmt, &block_env);
                    } else {
                        try self.executeStatement(last_stmt, &block_env);
                    }
                }

                return Value.Void;
            },
            .ClosureExpr => |closure| {
                // Extract parameter names
                const param_names = try self.arena.allocator().alloc([]const u8, closure.params.len);
                for (closure.params, 0..) |param, i| {
                    param_names[i] = param.name;
                }

                // Get body (expression or block)
                var body_expr: ?*ast.Expr = null;
                var body_block: ?*ast.BlockStmt = null;
                switch (closure.body) {
                    .Expression => |e| body_expr = e,
                    .Block => |b| body_block = b,
                }

                // Capture variables from current environment
                // For simplicity, capture all variables that are referenced in the closure
                // (In a full implementation, we'd analyze the closure body to find captures)
                const captured_names = try self.arena.allocator().alloc([]const u8, closure.captures.len);
                const captured_values = try self.arena.allocator().alloc(Value, closure.captures.len);
                for (closure.captures, 0..) |capture, i| {
                    captured_names[i] = capture.name;
                    // Look up the captured variable in the current environment
                    if (env.get(capture.name)) |val| {
                        captured_values[i] = val;
                    } else {
                        // Variable not found - might be available at call time
                        captured_values[i] = Value.Void;
                    }
                }

                return Value{ .Closure = ClosureValue{
                    .param_names = param_names,
                    .body_expr = body_expr,
                    .body_block = body_block,
                    .captured_names = captured_names,
                    .captured_values = captured_values,
                } };
            },
            .ComptimeExpr => |comptime_expr| {
                // At runtime, comptime expressions just evaluate their inner expression
                // The "compile-time" aspect is handled during compilation/type-checking
                return try self.evaluateExpression(comptime_expr.expression, env);
            },
            else => |expr_tag| {
                std.debug.print("Cannot evaluate {s} expression (not yet implemented in interpreter)\n", .{@tagName(expr_tag)});
                return error.RuntimeError;
            },
        }
    }

    fn evaluateBinaryExpression(self: *Interpreter, binary: *ast.BinaryExpr, env: *Environment) InterpreterError!Value {
        const left = try self.evaluateExpression(binary.left, env);
        // Arena allocator will clean up
        const right = try self.evaluateExpression(binary.right, env);
        // Arena allocator will clean up

        return switch (binary.op) {
            .Add => try self.applyAddition(left, right),
            .Sub => try self.applyArithmetic(left, right, .Sub),
            .Mul => try self.applyArithmetic(left, right, .Mul),
            .Div => try self.applyArithmetic(left, right, .Div),
            .IntDiv => try self.applyArithmetic(left, right, .IntDiv),
            .Mod => try self.applyArithmetic(left, right, .Mod),
            .Power => try self.applyPower(left, right),
            .Equal => Value{ .Bool = try self.areEqual(left, right) },
            .NotEqual => Value{ .Bool = !(try self.areEqual(left, right)) },
            .Less => Value{ .Bool = try self.compare(left, right, .Less) },
            .LessEq => Value{ .Bool = try self.compare(left, right, .LessEq) },
            .Greater => Value{ .Bool = try self.compare(left, right, .Greater) },
            .GreaterEq => Value{ .Bool = try self.compare(left, right, .GreaterEq) },
            .And => Value{ .Bool = left.isTrue() and right.isTrue() },
            .Or => Value{ .Bool = left.isTrue() or right.isTrue() },
            .BitAnd, .BitOr, .BitXor, .LeftShift, .RightShift => try self.applyBitwise(left, right, binary.op),
            else => {
                std.debug.print("Unimplemented binary operator\n", .{});
                return error.RuntimeError;
            },
        };
    }

    fn evaluateUnaryExpression(self: *Interpreter, unary: *ast.UnaryExpr, env: *Environment) InterpreterError!Value {
        const operand = try self.evaluateExpression(unary.operand, env);
        // Arena allocator will clean up

        return switch (unary.op) {
            .Neg => switch (operand) {
                .Int => |i| Value{ .Int = -i },
                .Float => |f| Value{ .Float = -f },
                else => error.TypeMismatch,
            },
            .Not => Value{ .Bool = !operand.isTrue() },
            .BitNot => switch (operand) {
                .Int => |i| Value{ .Int = ~i },
                else => error.TypeMismatch,
            },
            .Deref => {
                // Dereference operation: *ptr
                // For interpreter, we treat references as direct values
                // So dereferencing just returns the value
                return operand;
            },
            .AddressOf => {
                // Address-of operation: &value
                // For interpreter, we can't create true pointers
                // Just return the value (immutable reference)
                return operand;
            },
            .Borrow => {
                // Immutable borrow: &value
                // Similar to AddressOf in interpreted context
                return operand;
            },
            .BorrowMut => {
                // Mutable borrow: &mut value
                // In interpreter, just return the value
                // Mutability is enforced at compile time
                return operand;
            },
        };
    }

    fn evaluateAssignmentExpression(self: *Interpreter, assign: *ast.AssignmentExpr, env: *Environment) InterpreterError!Value {
        // Evaluate the right-hand side
        const value = try self.evaluateExpression(assign.value, env);

        // Get the target name and update the environment
        switch (assign.target.*) {
            .Identifier => |id| {
                try env.set(id.name, value);
                return value;
            },
            .IndexExpr => {
                // Array element assignment: arr[i] = value
                // Arrays are immutable slices in the interpreter
                // Would require mutable array type to implement
                std.debug.print("Assignment to array elements requires mutable array support\n", .{});
                return error.RuntimeError;
            },
            .MemberExpr => {
                // Struct field assignment: obj.field = value
                // The current interpreter design returns values by copy,
                // so mutating fields of structs requires reference semantics
                std.debug.print("Assignment to struct fields requires mutable reference support\n", .{});
                return error.RuntimeError;
            },
            else => |target_tag| {
                std.debug.print("Cannot assign to {s} (only variables, array elements, and struct fields are valid assignment targets)\n", .{@tagName(target_tag)});
                return error.RuntimeError;
            },
        }
    }

    fn evaluateCallExpression(self: *Interpreter, call: *ast.CallExpr, env: *Environment) InterpreterError!Value {
        // Handle method calls (obj.method()) and enum variant construction
        if (call.callee.* == .MemberExpr) {
            const member = call.callee.MemberExpr;
            const obj_value = try self.evaluateExpression(member.object, env);

            // Handle enum variant construction (e.g., Option.Some(42))
            if (obj_value == .EnumType) {
                const enum_type = obj_value.EnumType;
                // Check if the member is a valid variant
                var found_variant: ?EnumVariantInfo = null;
                for (enum_type.variants) |variant| {
                    if (std.mem.eql(u8, variant.name, member.member)) {
                        found_variant = variant;
                        break;
                    }
                }
                if (found_variant) |variant| {
                    if (variant.has_data and call.args.len > 0) {
                        // Create a struct representing the enum variant with data
                        var fields = std.StringHashMap(Value).init(self.arena.allocator());
                        // Store the first argument as the payload
                        const arg_value = try self.evaluateExpression(call.args[0], env);
                        try fields.put("value", arg_value);
                        try fields.put("0", arg_value); // Also store with index for pattern matching
                        return Value{ .Struct = .{
                            .type_name = member.member,
                            .fields = fields,
                        } };
                    } else {
                        // Variant without data - just return the variant struct
                        const fields = std.StringHashMap(Value).init(self.arena.allocator());
                        return Value{ .Struct = .{
                            .type_name = member.member,
                            .fields = fields,
                        } };
                    }
                }
                std.debug.print("Enum '{s}' has no variant '{s}'\n", .{ enum_type.name, member.member });
                return error.RuntimeError;
            }

            // Handle string methods
            if (obj_value == .String) {
                return try self.evaluateStringMethod(obj_value.String, member.member, call.args, env);
            }

            // Handle array methods
            if (obj_value == .Array) {
                return try self.evaluateArrayMethod(obj_value.Array, member.member, call.args, env);
            }

            // Handle range methods
            if (obj_value == .Range) {
                return try self.evaluateRangeMethod(obj_value.Range, member.member, call.args, env);
            }

            std.debug.print("Method calls only supported on strings, arrays, ranges, and enums\n", .{});
            return error.RuntimeError;
        }

        // Get function name
        if (call.callee.* == .Identifier) {
            const func_name = call.callee.Identifier.name;

            // Handle built-in functions
            if (std.mem.eql(u8, func_name, "print")) {
                return try self.builtinPrint(call.args, env);
            } else if (std.mem.eql(u8, func_name, "assert")) {
                return try self.builtinAssert(call.args, env);
            }

            // Look up user-defined function or closure
            if (env.get(func_name)) |func_value| {
                if (func_value == .Function) {
                    return try self.callUserFunction(func_value.Function, call.args, env);
                }
                if (func_value == .Closure) {
                    return try self.callClosure(func_value.Closure, call.args, env);
                }
            }

            std.debug.print("Undefined function: {s}\n", .{func_name});
            return error.UndefinedFunction;
        }

        // Handle calling closure expressions directly (e.g., (|x| x + 1)(5))
        const callee_value = try self.evaluateExpression(call.callee, env);
        if (callee_value == .Closure) {
            return try self.callClosure(callee_value.Closure, call.args, env);
        }
        if (callee_value == .Function) {
            return try self.callUserFunction(callee_value.Function, call.args, env);
        }

        std.debug.print("Cannot call non-function value\n", .{});
        return error.RuntimeError;
    }

    /// Call a closure with given arguments
    fn callClosure(self: *Interpreter, closure: ClosureValue, args: []const *const ast.Expr, env: *Environment) InterpreterError!Value {
        // Check argument count
        if (args.len != closure.param_names.len) {
            std.debug.print("Closure expects {d} arguments, got {d}\n", .{ closure.param_names.len, args.len });
            return error.InvalidArguments;
        }

        // Create new environment for closure execution
        var closure_env = Environment.init(self.arena.allocator(), env);

        // Bind captured variables
        for (closure.captured_names, 0..) |name, i| {
            try closure_env.define(name, closure.captured_values[i]);
        }

        // Evaluate arguments and bind parameters
        for (closure.param_names, 0..) |param_name, i| {
            const arg_value = try self.evaluateExpression(args[i], env);
            try closure_env.define(param_name, arg_value);
        }

        // Execute closure body
        if (closure.body_expr) |expr| {
            return try self.evaluateExpression(expr, &closure_env);
        } else if (closure.body_block) |block| {
            // Execute block and return last expression or void
            for (block.statements) |stmt| {
                self.executeStatement(stmt, &closure_env) catch |err| {
                    if (err == error.Return) {
                        return self.return_value orelse Value.Void;
                    }
                    return err;
                };
            }
            return Value.Void;
        }

        return Value.Void;
    }

    /// Evaluate string method calls
    fn evaluateStringMethod(self: *Interpreter, str: []const u8, method: []const u8, args: []const *const ast.Expr, env: *Environment) InterpreterError!Value {
        const allocator = self.arena.allocator();

        // len() - returns string length
        if (std.mem.eql(u8, method, "len") or std.mem.eql(u8, method, "length")) {
            return Value{ .Int = @as(i64, @intCast(str.len)) };
        }

        // upper() - convert to uppercase
        if (std.mem.eql(u8, method, "upper")) {
            const result = try allocator.alloc(u8, str.len);
            for (str, 0..) |c, i| {
                result[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
            }
            return Value{ .String = result };
        }

        // lower() - convert to lowercase
        if (std.mem.eql(u8, method, "lower")) {
            const result = try allocator.alloc(u8, str.len);
            for (str, 0..) |c, i| {
                result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            }
            return Value{ .String = result };
        }

        // trim() - remove leading and trailing whitespace
        if (std.mem.eql(u8, method, "trim")) {
            const trimmed = std.mem.trim(u8, str, " \t\n\r");
            const result = try allocator.dupe(u8, trimmed);
            return Value{ .String = result };
        }

        // trim_start() / trim_left() - remove leading whitespace
        if (std.mem.eql(u8, method, "trim_start") or std.mem.eql(u8, method, "trim_left")) {
            const trimmed = std.mem.trimLeft(u8, str, " \t\n\r");
            const result = try allocator.dupe(u8, trimmed);
            return Value{ .String = result };
        }

        // trim_end() / trim_right() - remove trailing whitespace
        if (std.mem.eql(u8, method, "trim_end") or std.mem.eql(u8, method, "trim_right")) {
            const trimmed = std.mem.trimRight(u8, str, " \t\n\r");
            const result = try allocator.dupe(u8, trimmed);
            return Value{ .String = result };
        }

        // contains(substring) - check if string contains substring
        if (std.mem.eql(u8, method, "contains")) {
            if (args.len != 1) {
                std.debug.print("contains() expects 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const substr_val = try self.evaluateExpression(args[0], env);
            if (substr_val != .String) {
                std.debug.print("contains() argument must be a string\n", .{});
                return error.TypeMismatch;
            }
            const found = std.mem.indexOf(u8, str, substr_val.String) != null;
            return Value{ .Bool = found };
        }

        // starts_with(prefix) - check if string starts with prefix
        if (std.mem.eql(u8, method, "starts_with")) {
            if (args.len != 1) {
                std.debug.print("starts_with() expects 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const prefix_val = try self.evaluateExpression(args[0], env);
            if (prefix_val != .String) {
                std.debug.print("starts_with() argument must be a string\n", .{});
                return error.TypeMismatch;
            }
            const starts = std.mem.startsWith(u8, str, prefix_val.String);
            return Value{ .Bool = starts };
        }

        // ends_with(suffix) - check if string ends with suffix
        if (std.mem.eql(u8, method, "ends_with")) {
            if (args.len != 1) {
                std.debug.print("ends_with() expects 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const suffix_val = try self.evaluateExpression(args[0], env);
            if (suffix_val != .String) {
                std.debug.print("ends_with() argument must be a string\n", .{});
                return error.TypeMismatch;
            }
            const ends = std.mem.endsWith(u8, str, suffix_val.String);
            return Value{ .Bool = ends };
        }

        // split(delimiter) - split string into array
        if (std.mem.eql(u8, method, "split")) {
            if (args.len != 1) {
                std.debug.print("split() expects 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const delim_val = try self.evaluateExpression(args[0], env);
            if (delim_val != .String) {
                std.debug.print("split() argument must be a string\n", .{});
                return error.TypeMismatch;
            }

            var parts = std.ArrayList(Value){ .items = &.{}, .capacity = 0 };
            defer parts.deinit(allocator);
            var iter = std.mem.splitSequence(u8, str, delim_val.String);
            while (iter.next()) |part| {
                const part_copy = try allocator.dupe(u8, part);
                try parts.append(allocator, Value{ .String = part_copy });
            }
            return Value{ .Array = try parts.toOwnedSlice(allocator) };
        }

        // replace(old, new) - replace all occurrences
        if (std.mem.eql(u8, method, "replace")) {
            if (args.len != 2) {
                std.debug.print("replace() expects 2 arguments\n", .{});
                return error.InvalidArguments;
            }
            const old_val = try self.evaluateExpression(args[0], env);
            const new_val = try self.evaluateExpression(args[1], env);
            if (old_val != .String or new_val != .String) {
                std.debug.print("replace() arguments must be strings\n", .{});
                return error.TypeMismatch;
            }

            const result = try std.mem.replaceOwned(u8, allocator, str, old_val.String, new_val.String);
            return Value{ .String = result };
        }

        // repeat(n) - repeat string n times
        if (std.mem.eql(u8, method, "repeat")) {
            if (args.len != 1) {
                std.debug.print("repeat() expects 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const count_val = try self.evaluateExpression(args[0], env);
            if (count_val != .Int) {
                std.debug.print("repeat() argument must be an integer\n", .{});
                return error.TypeMismatch;
            }
            const count: usize = @intCast(@max(0, count_val.Int));
            const result = try allocator.alloc(u8, str.len * count);
            for (0..count) |i| {
                @memcpy(result[i * str.len .. (i + 1) * str.len], str);
            }
            return Value{ .String = result };
        }

        // is_empty() - check if string is empty
        if (std.mem.eql(u8, method, "is_empty")) {
            return Value{ .Bool = str.len == 0 };
        }

        // char_at(index) - get character at index
        if (std.mem.eql(u8, method, "char_at")) {
            if (args.len != 1) {
                std.debug.print("char_at() expects 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const idx_val = try self.evaluateExpression(args[0], env);
            if (idx_val != .Int) {
                std.debug.print("char_at() argument must be an integer\n", .{});
                return error.TypeMismatch;
            }
            const idx: usize = @intCast(@max(0, idx_val.Int));
            if (idx >= str.len) {
                std.debug.print("char_at() index out of bounds\n", .{});
                return error.RuntimeError;
            }
            const char_str = try allocator.alloc(u8, 1);
            char_str[0] = str[idx];
            return Value{ .String = char_str };
        }

        // reverse() - reverse the string
        if (std.mem.eql(u8, method, "reverse")) {
            const result = try allocator.alloc(u8, str.len);
            for (str, 0..) |c, i| {
                result[str.len - 1 - i] = c;
            }
            return Value{ .String = result };
        }

        std.debug.print("Unknown string method: {s}\n", .{method});
        return error.UndefinedFunction;
    }

    /// Evaluate array method calls
    fn evaluateArrayMethod(self: *Interpreter, arr: []const Value, method: []const u8, args: []const *const ast.Expr, env: *Environment) InterpreterError!Value {
        // len() / length() - returns array length
        if (std.mem.eql(u8, method, "len") or std.mem.eql(u8, method, "length")) {
            return Value{ .Int = @as(i64, @intCast(arr.len)) };
        }

        // is_empty() - check if array is empty
        if (std.mem.eql(u8, method, "is_empty")) {
            return Value{ .Bool = arr.len == 0 };
        }

        // first() - get first element
        if (std.mem.eql(u8, method, "first")) {
            if (arr.len == 0) {
                return Value.Void;
            }
            return arr[0];
        }

        // last() - get last element
        if (std.mem.eql(u8, method, "last")) {
            if (arr.len == 0) {
                return Value.Void;
            }
            return arr[arr.len - 1];
        }

        // push(value) - returns new array with value appended
        if (std.mem.eql(u8, method, "push")) {
            if (args.len != 1) {
                std.debug.print("push() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const new_value = try self.evaluateExpression(args[0], env);
            var new_arr = try self.arena.allocator().alloc(Value, arr.len + 1);
            @memcpy(new_arr[0..arr.len], arr);
            new_arr[arr.len] = new_value;
            return Value{ .Array = new_arr };
        }

        // pop() - returns new array without last element
        if (std.mem.eql(u8, method, "pop")) {
            if (arr.len == 0) {
                return Value{ .Array = &.{} };
            }
            const new_arr = try self.arena.allocator().alloc(Value, arr.len - 1);
            @memcpy(new_arr, arr[0 .. arr.len - 1]);
            return Value{ .Array = new_arr };
        }

        // shift() - returns new array without first element
        if (std.mem.eql(u8, method, "shift")) {
            if (arr.len == 0) {
                return Value{ .Array = &.{} };
            }
            const new_arr = try self.arena.allocator().alloc(Value, arr.len - 1);
            @memcpy(new_arr, arr[1..]);
            return Value{ .Array = new_arr };
        }

        // unshift(value) - returns new array with value prepended
        if (std.mem.eql(u8, method, "unshift")) {
            if (args.len != 1) {
                std.debug.print("unshift() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const new_value = try self.evaluateExpression(args[0], env);
            var new_arr = try self.arena.allocator().alloc(Value, arr.len + 1);
            new_arr[0] = new_value;
            @memcpy(new_arr[1..], arr);
            return Value{ .Array = new_arr };
        }

        // concat(other_array) - returns new array with both arrays concatenated
        if (std.mem.eql(u8, method, "concat")) {
            if (args.len != 1) {
                std.debug.print("concat() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const other_val = try self.evaluateExpression(args[0], env);
            if (other_val != .Array) {
                std.debug.print("concat() argument must be an array\n", .{});
                return error.TypeMismatch;
            }
            const other = other_val.Array;
            var new_arr = try self.arena.allocator().alloc(Value, arr.len + other.len);
            @memcpy(new_arr[0..arr.len], arr);
            @memcpy(new_arr[arr.len..], other);
            return Value{ .Array = new_arr };
        }

        // reverse() - returns new reversed array
        if (std.mem.eql(u8, method, "reverse")) {
            var new_arr = try self.arena.allocator().alloc(Value, arr.len);
            for (arr, 0..) |elem, i| {
                new_arr[arr.len - 1 - i] = elem;
            }
            return Value{ .Array = new_arr };
        }

        // contains(value) - check if array contains a value
        if (std.mem.eql(u8, method, "contains")) {
            if (args.len != 1) {
                std.debug.print("contains() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const search_val = try self.evaluateExpression(args[0], env);
            for (arr) |elem| {
                if (valuesEqual(elem, search_val)) {
                    return Value{ .Bool = true };
                }
            }
            return Value{ .Bool = false };
        }

        // index_of(value) - returns index of value or -1 if not found
        if (std.mem.eql(u8, method, "index_of")) {
            if (args.len != 1) {
                std.debug.print("index_of() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const search_val = try self.evaluateExpression(args[0], env);
            for (arr, 0..) |elem, i| {
                if (valuesEqual(elem, search_val)) {
                    return Value{ .Int = @as(i64, @intCast(i)) };
                }
            }
            return Value{ .Int = -1 };
        }

        // join(separator) - join array elements with separator string
        if (std.mem.eql(u8, method, "join")) {
            var separator: []const u8 = ",";
            if (args.len >= 1) {
                const sep_val = try self.evaluateExpression(args[0], env);
                if (sep_val != .String) {
                    std.debug.print("join() separator must be a string\n", .{});
                    return error.TypeMismatch;
                }
                separator = sep_val.String;
            }
            // Calculate total length
            var total_len: usize = 0;
            for (arr, 0..) |elem, i| {
                total_len += valueStringLenForJoin(elem);
                if (i < arr.len - 1) {
                    total_len += separator.len;
                }
            }
            // Build result string
            var result = try self.arena.allocator().alloc(u8, total_len);
            var pos: usize = 0;
            for (arr, 0..) |elem, i| {
                const elem_str = try self.valueToStringForJoin(elem);
                @memcpy(result[pos .. pos + elem_str.len], elem_str);
                pos += elem_str.len;
                if (i < arr.len - 1) {
                    @memcpy(result[pos .. pos + separator.len], separator);
                    pos += separator.len;
                }
            }
            return Value{ .String = result };
        }

        std.debug.print("Unknown array method: {s}\n", .{method});
        return error.UndefinedFunction;
    }

    /// Helper to check if two values are equal
    fn valuesEqual(a: Value, b: Value) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;
        return switch (a) {
            .Int => |av| av == b.Int,
            .Float => |av| av == b.Float,
            .Bool => |av| av == b.Bool,
            .String => |av| std.mem.eql(u8, av, b.String),
            .Void => true,
            else => false,
        };
    }

    /// Helper to get string representation length of a value
    fn valueStringLenForJoin(val: Value) usize {
        return switch (val) {
            .Int => |i| blk: {
                if (i == 0) break :blk 1;
                var n = if (i < 0) -i else i;
                var len: usize = if (i < 0) 1 else 0;
                while (n > 0) : (n = @divTrunc(n, 10)) {
                    len += 1;
                }
                break :blk len;
            },
            .Float => 10, // Approximate
            .Bool => |b| if (b) 4 else 5,
            .String => |s| s.len,
            .Void => 4,
            else => 8,
        };
    }

    /// Convert value to string for join
    fn valueToStringForJoin(self: *Interpreter, val: Value) ![]const u8 {
        return switch (val) {
            .Int => |i| blk: {
                var buf: [32]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "<int>";
                const result = try self.arena.allocator().alloc(u8, slice.len);
                @memcpy(result, slice);
                break :blk result;
            },
            .Float => |f| blk: {
                var buf: [64]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "<float>";
                const result = try self.arena.allocator().alloc(u8, slice.len);
                @memcpy(result, slice);
                break :blk result;
            },
            .Bool => |b| if (b) "true" else "false",
            .String => |s| s,
            .Void => "void",
            else => "<value>",
        };
    }

    /// Evaluate range method calls
    fn evaluateRangeMethod(self: *Interpreter, range: @import("value.zig").RangeValue, method: []const u8, args: []const *const ast.Expr, env: *Environment) InterpreterError!Value {
        // step(n) - create a new range with the specified step
        if (std.mem.eql(u8, method, "step")) {
            if (args.len != 1) {
                std.debug.print("step() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const step_val = try self.evaluateExpression(args[0], env);
            if (step_val != .Int) {
                std.debug.print("step() argument must be an integer\n", .{});
                return error.TypeMismatch;
            }
            const RangeValue = @import("value.zig").RangeValue;
            return Value{ .Range = RangeValue{
                .start = range.start,
                .end = range.end,
                .inclusive = range.inclusive,
                .step = step_val.Int,
            } };
        }

        // len() / length() / count() - returns the number of elements in the range
        if (std.mem.eql(u8, method, "len") or std.mem.eql(u8, method, "length") or std.mem.eql(u8, method, "count")) {
            const count = calculateRangeLength(range);
            return Value{ .Int = count };
        }

        // to_array() - convert range to an array
        if (std.mem.eql(u8, method, "to_array")) {
            const count_i64 = calculateRangeLength(range);
            if (count_i64 < 0) {
                return Value{ .Array = &.{} };
            }
            const count: usize = @intCast(count_i64);
            var elements = try self.arena.allocator().alloc(Value, count);
            var i: usize = 0;
            var current = range.start;
            const end_check: i64 = if (range.inclusive) range.end + 1 else range.end;
            while ((range.step > 0 and current < end_check) or (range.step < 0 and current > end_check)) : (i += 1) {
                if (i >= count) break;
                elements[i] = Value{ .Int = current };
                current += range.step;
            }
            return Value{ .Array = elements[0..i] };
        }

        // first() - get first element
        if (std.mem.eql(u8, method, "first")) {
            return Value{ .Int = range.start };
        }

        // last() - get last element
        if (std.mem.eql(u8, method, "last")) {
            if (range.inclusive) {
                return Value{ .Int = range.end };
            } else {
                return Value{ .Int = range.end - 1 };
            }
        }

        // contains(n) - check if a value is in the range
        if (std.mem.eql(u8, method, "contains")) {
            if (args.len != 1) {
                std.debug.print("contains() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const val = try self.evaluateExpression(args[0], env);
            if (val != .Int) {
                return Value{ .Bool = false };
            }
            const n = val.Int;
            const in_bounds = if (range.inclusive)
                n >= range.start and n <= range.end
            else
                n >= range.start and n < range.end;

            // Also check that it matches the step pattern
            if (in_bounds and range.step != 0) {
                const offset = @mod(n - range.start, range.step);
                return Value{ .Bool = offset == 0 };
            }
            return Value{ .Bool = in_bounds };
        }

        std.debug.print("Unknown range method: {s}\n", .{method});
        return error.UndefinedFunction;
    }

    fn calculateRangeLength(range: @import("value.zig").RangeValue) i64 {
        if (range.step == 0) return 0;
        const diff = range.end - range.start;
        if (range.step > 0 and diff < 0) return 0;
        if (range.step < 0 and diff > 0) return 0;

        const abs_diff: i64 = if (diff < 0) -diff else diff;
        const abs_step: i64 = if (range.step < 0) -range.step else range.step;
        const count = @divTrunc(abs_diff, abs_step);
        if (range.inclusive) {
            return count + 1;
        }
        return count;
    }

    fn callUserFunction(self: *Interpreter, func: FunctionValue, args: []const *const ast.Expr, parent_env: *Environment) InterpreterError!Value {
        // Count required parameters (those without default values)
        var required_params: usize = 0;
        for (func.params) |param| {
            if (param.default_value == null) {
                required_params += 1;
            }
        }

        // Check argument count - must have at least required params, at most all params
        if (args.len < required_params or args.len > func.params.len) {
            if (required_params == func.params.len) {
                std.debug.print("Function {s} expects {d} arguments, got {d}\n", .{ func.name, func.params.len, args.len });
            } else {
                std.debug.print("Function {s} expects {d}-{d} arguments, got {d}\n", .{ func.name, required_params, func.params.len, args.len });
            }
            return error.InvalidArguments;
        }

        // Create new environment for function scope
        var func_env = Environment.init(self.arena.allocator(), parent_env);
        defer func_env.deinit();

        // Bind parameters to arguments (with default value support)
        for (func.params, 0..) |param, i| {
            const arg_value = if (i < args.len)
                try self.evaluateExpression(args[i], parent_env)
            else if (param.default_value) |default|
                try self.evaluateExpression(default, parent_env)
            else
                return error.InvalidArguments;
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

    fn evaluateMacroExpression(self: *Interpreter, macro: *ast.MacroExpr, env: *Environment) InterpreterError!Value {
        // Handle built-in macros at runtime
        const name = macro.name;

        if (std.mem.eql(u8, name, "println")) {
            // println! macro - print with newline
            for (macro.args, 0..) |arg, i| {
                if (i > 0) std.debug.print(" ", .{});
                const value = try self.evaluateExpression(arg, env);
                self.printValue(value);
            }
            std.debug.print("\n", .{});
            return Value.Void;
        } else if (std.mem.eql(u8, name, "print")) {
            // print! macro - print without newline
            for (macro.args, 0..) |arg, i| {
                if (i > 0) std.debug.print(" ", .{});
                const value = try self.evaluateExpression(arg, env);
                self.printValue(value);
            }
            return Value.Void;
        } else if (std.mem.eql(u8, name, "debug")) {
            // debug! macro - print debug representation with location
            std.debug.print("[DEBUG {}:{}] ", .{ macro.node.loc.line, macro.node.loc.column });
            for (macro.args, 0..) |arg, i| {
                if (i > 0) std.debug.print(", ", .{});
                const value = try self.evaluateExpression(arg, env);
                self.printValueDebug(value);
            }
            std.debug.print("\n", .{});
            return Value.Void;
        } else if (std.mem.eql(u8, name, "assert")) {
            // assert! macro
            if (macro.args.len < 1) {
                std.debug.print("assert! expects at least 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const value = try self.evaluateExpression(macro.args[0], env);
            if (!value.isTrue()) {
                if (macro.args.len > 1) {
                    // Custom message
                    const msg = try self.evaluateExpression(macro.args[1], env);
                    if (msg == .String) {
                        std.debug.print("assertion failed: {s}\n", .{msg.String});
                    } else {
                        std.debug.print("assertion failed!\n", .{});
                    }
                } else {
                    std.debug.print("assertion failed!\n", .{});
                }
                return error.RuntimeError;
            }
            return Value.Void;
        } else if (std.mem.eql(u8, name, "todo")) {
            // todo! macro - panic with "not yet implemented"
            if (macro.args.len > 0) {
                const msg = try self.evaluateExpression(macro.args[0], env);
                if (msg == .String) {
                    std.debug.print("not yet implemented: {s}\n", .{msg.String});
                } else {
                    std.debug.print("not yet implemented\n", .{});
                }
            } else {
                std.debug.print("not yet implemented\n", .{});
            }
            return error.RuntimeError;
        } else if (std.mem.eql(u8, name, "unimplemented")) {
            // unimplemented! macro
            std.debug.print("not implemented\n", .{});
            return error.RuntimeError;
        } else if (std.mem.eql(u8, name, "unreachable")) {
            // unreachable! macro
            std.debug.print("entered unreachable code\n", .{});
            return error.RuntimeError;
        } else if (std.mem.eql(u8, name, "panic")) {
            // panic! macro
            if (macro.args.len > 0) {
                const msg = try self.evaluateExpression(macro.args[0], env);
                if (msg == .String) {
                    std.debug.print("panic: {s}\n", .{msg.String});
                } else {
                    std.debug.print("panic!\n", .{});
                }
            } else {
                std.debug.print("panic!\n", .{});
            }
            return error.RuntimeError;
        } else if (std.mem.eql(u8, name, "vec")) {
            // vec! macro - create array
            var elements = try self.arena.allocator().alloc(Value, macro.args.len);
            for (macro.args, 0..) |arg, i| {
                elements[i] = try self.evaluateExpression(arg, env);
            }
            return Value{ .Array = elements };
        } else if (std.mem.eql(u8, name, "format")) {
            // format! macro - string formatting (simplified)
            if (macro.args.len == 0) {
                return Value{ .String = "" };
            }
            const fmt_val = try self.evaluateExpression(macro.args[0], env);
            if (fmt_val != .String) {
                std.debug.print("format! expects string as first argument\n", .{});
                return error.TypeMismatch;
            }
            // Simple implementation - just return format string for now
            // Full implementation would substitute {} placeholders
            return fmt_val;
        } else if (std.mem.eql(u8, name, "stringify")) {
            // stringify! macro - convert expression to string
            if (macro.args.len != 1) {
                std.debug.print("stringify! expects 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const value = try self.evaluateExpression(macro.args[0], env);
            const str = try self.valueToString(value);
            return Value{ .String = str };
        } else if (std.mem.eql(u8, name, "env")) {
            // env! macro - get environment variable (compile-time in full impl, runtime here)
            if (macro.args.len != 1) {
                std.debug.print("env! expects 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const name_val = try self.evaluateExpression(macro.args[0], env);
            if (name_val != .String) {
                std.debug.print("env! expects string argument\n", .{});
                return error.TypeMismatch;
            }
            if (std.posix.getenv(name_val.String)) |val| {
                return Value{ .String = val };
            }
            return Value.Void;
        } else {
            std.debug.print("Unknown macro: {s}!\n", .{name});
            return error.RuntimeError;
        }
    }

    fn printValue(self: *Interpreter, value: Value) void {
        _ = self;
        switch (value) {
            .Int => |v| std.debug.print("{d}", .{v}),
            .Float => |v| std.debug.print("{d}", .{v}),
            .Bool => |v| std.debug.print("{}", .{v}),
            .String => |s| std.debug.print("{s}", .{s}),
            .Array => |arr| {
                std.debug.print("[", .{});
                for (arr, 0..) |elem, idx| {
                    if (idx > 0) std.debug.print(", ", .{});
                    std.debug.print("{any}", .{elem});
                }
                std.debug.print("]", .{});
            },
            .Struct => |s| std.debug.print("<{s} instance>", .{s.type_name}),
            .Function => |f| std.debug.print("<fn {s}>", .{f.name}),
            .Closure => std.debug.print("<closure>", .{}),
            .Range => |r| {
                if (r.inclusive) {
                    std.debug.print("{d}..={d}", .{ r.start, r.end });
                } else {
                    std.debug.print("{d}..{d}", .{ r.start, r.end });
                }
            },
            .EnumType => |e| std.debug.print("<enum {s}>", .{e.name}),
            .Void => std.debug.print("void", .{}),
        }
    }

    fn printValueDebug(self: *Interpreter, value: Value) void {
        _ = self;
        switch (value) {
            .Int => |v| std.debug.print("Int({d})", .{v}),
            .Float => |v| std.debug.print("Float({d})", .{v}),
            .Bool => |v| std.debug.print("Bool({})", .{v}),
            .String => |s| std.debug.print("String(\"{s}\")", .{s}),
            .Range => |r| std.debug.print("Range({d}..{d}, step={d})", .{ r.start, r.end, r.step }),
            .Array => |arr| {
                std.debug.print("Array[{d}]{{", .{arr.len});
                for (arr, 0..) |elem, idx| {
                    if (idx > 0) std.debug.print(", ", .{});
                    std.debug.print("{any}", .{elem});
                }
                std.debug.print("}}", .{});
            },
            .Struct => |s| std.debug.print("Struct({s})", .{s.type_name}),
            .Function => |f| std.debug.print("Function({s})", .{f.name}),
            .Closure => std.debug.print("Closure(...)", .{}),
            .EnumType => |e| std.debug.print("EnumType({s})", .{e.name}),
            .Void => std.debug.print("Void", .{}),
        }
    }

    fn builtinPrint(self: *Interpreter, args: []const *const ast.Expr, env: *Environment) InterpreterError!Value {
        for (args, 0..) |arg, i| {
            if (i > 0) std.debug.print(" ", .{});
            const value = try self.evaluateExpression(arg, env);
            // Arena allocator will clean up

            switch (value) {
                .Int => |v| std.debug.print("{d}", .{v}),
                .Float => |v| std.debug.print("{d}", .{v}),
                .Bool => |v| std.debug.print("{}", .{v}),
                .String => |s| std.debug.print("{s}", .{s}),
                .Array => |arr| {
                    std.debug.print("[", .{});
                    for (arr, 0..) |elem, idx| {
                        if (idx > 0) std.debug.print(", ", .{});
                        std.debug.print("{any}", .{elem});
                    }
                    std.debug.print("]", .{});
                },
                .Struct => |s| std.debug.print("<{s} instance>", .{s.type_name}),
                .Function => |f| std.debug.print("<fn {s}>", .{f.name}),
                .Closure => std.debug.print("<closure>", .{}),
                .Range => |r| {
                    if (r.inclusive) {
                        std.debug.print("{d}..={d}", .{ r.start, r.end });
                    } else {
                        std.debug.print("{d}..{d}", .{ r.start, r.end });
                    }
                },
                .EnumType => |e| std.debug.print("<enum {s}>", .{e.name}),
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
        // Arena allocator will clean up

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
                    // Use arena allocator for string concatenation
                    const result = try std.mem.concat(self.arena.allocator(), u8, &[_][]const u8{ l, r });
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
                    if ((op == .Div or op == .IntDiv) and r == 0) return error.DivisionByZero;
                    return Value{ .Int = switch (op) {
                        .Sub => l - r,
                        .Mul => l * r,
                        .Div => @divTrunc(l, r),
                        .IntDiv => @divTrunc(l, r),
                        .Mod => @mod(l, r),
                        else => {
                            std.debug.print("Invalid arithmetic operator\n", .{});
                            return error.InvalidOperation;
                        },
                    } };
                },
                .Float => |r| {
                    if ((op == .Div or op == .IntDiv) and r == 0.0) return error.DivisionByZero;
                    const lf = @as(f64, @floatFromInt(l));
                    if (op == .IntDiv) {
                        return Value{ .Int = @as(i64, @intFromFloat(@trunc(lf / r))) };
                    }
                    return Value{ .Float = switch (op) {
                        .Sub => lf - r,
                        .Mul => lf * r,
                        .Div => lf / r,
                        .Mod => @mod(lf, r),
                        else => {
                            std.debug.print("Invalid arithmetic operator\n", .{});
                            return error.InvalidOperation;
                        },
                    } };
                },
                else => return error.TypeMismatch,
            },
            .Float => |l| switch (right) {
                .Int => |r| {
                    const rf = @as(f64, @floatFromInt(r));
                    if ((op == .Div or op == .IntDiv) and rf == 0.0) return error.DivisionByZero;
                    if (op == .IntDiv) {
                        return Value{ .Int = @as(i64, @intFromFloat(@trunc(l / rf))) };
                    }
                    return Value{ .Float = switch (op) {
                        .Sub => l - rf,
                        .Mul => l * rf,
                        .Div => l / rf,
                        .Mod => @mod(l, rf),
                        else => {
                            std.debug.print("Invalid arithmetic operator\n", .{});
                            return error.InvalidOperation;
                        },
                    } };
                },
                .Float => |r| {
                    if ((op == .Div or op == .IntDiv) and r == 0.0) return error.DivisionByZero;
                    if (op == .IntDiv) {
                        return Value{ .Int = @as(i64, @intFromFloat(@trunc(l / r))) };
                    }
                    return Value{ .Float = switch (op) {
                        .Sub => l - r,
                        .Mul => l * r,
                        .Div => l / r,
                        .Mod => @mod(l, r),
                        else => {
                            std.debug.print("Invalid arithmetic operator\n", .{});
                            return error.InvalidOperation;
                        },
                    } };
                },
                else => return error.TypeMismatch,
            },
            else => return error.TypeMismatch,
        }
    }

    fn applyPower(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        // Handle power operation: base ** exponent
        switch (left) {
            .Int => |base| switch (right) {
                .Int => |exp| {
                    if (exp < 0) {
                        // Negative exponent results in float
                        const base_f = @as(f64, @floatFromInt(base));
                        const exp_f = @as(f64, @floatFromInt(exp));
                        return Value{ .Float = std.math.pow(f64, base_f, exp_f) };
                    }
                    // Non-negative integer exponent
                    var result: i64 = 1;
                    var e: i64 = exp;
                    var b: i64 = base;
                    while (e > 0) {
                        if (@mod(e, 2) == 1) {
                            result = result * b;
                        }
                        b = b * b;
                        e = @divTrunc(e, 2);
                    }
                    return Value{ .Int = result };
                },
                .Float => |exp| {
                    const base_f = @as(f64, @floatFromInt(base));
                    return Value{ .Float = std.math.pow(f64, base_f, exp) };
                },
                else => return error.TypeMismatch,
            },
            .Float => |base| switch (right) {
                .Int => |exp| {
                    const exp_f = @as(f64, @floatFromInt(exp));
                    return Value{ .Float = std.math.pow(f64, base, exp_f) };
                },
                .Float => |exp| {
                    return Value{ .Float = std.math.pow(f64, base, exp) };
                },
                else => return error.TypeMismatch,
            },
            else => return error.TypeMismatch,
        }
    }

    fn applyBitwise(self: *Interpreter, left: Value, right: Value, op: ast.BinaryOp) InterpreterError!Value {
        _ = self;
        if (left != .Int or right != .Int) {
            std.debug.print("Bitwise operations require integer operands\n", .{});
            return error.TypeMismatch;
        }

        const l = left.Int;
        const r = right.Int;

        return Value{ .Int = switch (op) {
            .BitAnd => l & r,
            .BitOr => l | r,
            .BitXor => l ^ r,
            .LeftShift => l << @as(u6, @intCast(r)),
            .RightShift => l >> @as(u6, @intCast(r)),
            else => {
                std.debug.print("Invalid bitwise operator\n", .{});
                return error.InvalidOperation;
            },
        } };
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
            .Array => return false, // Array comparison not implemented
            .Struct => return false, // Struct comparison not implemented
            .Void => return right == .Void,
            .Function => return false, // Functions are not comparable
            .Closure => return false, // Closures are not comparable
            .Range => |l| switch (right) {
                .Range => |r| return l.start == r.start and l.end == r.end and l.inclusive == r.inclusive and l.step == r.step,
                else => return false,
            },
            .EnumType => |l| switch (right) {
                .EnumType => |r| return std.mem.eql(u8, l.name, r.name),
                else => return false,
            },
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
                    else => {
                        std.debug.print("Invalid comparison operator\n", .{});
                        return error.InvalidOperation;
                    },
                },
                .Float => |r| {
                    const lf = @as(f64, @floatFromInt(l));
                    return switch (op) {
                        .Less => lf < r,
                        .LessEq => lf <= r,
                        .Greater => lf > r,
                        .GreaterEq => lf >= r,
                        else => {
                            std.debug.print("Invalid comparison operator\n", .{});
                            return error.InvalidOperation;
                        },
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
                        else => {
                            std.debug.print("Invalid comparison operator\n", .{});
                            return error.InvalidOperation;
                        },
                    };
                },
                .Float => |r| return switch (op) {
                    .Less => l < r,
                    .LessEq => l <= r,
                    .Greater => l > r,
                    .GreaterEq => l >= r,
                    else => {
                        std.debug.print("Invalid comparison operator\n", .{});
                        return error.InvalidOperation;
                    },
                },
                else => return error.TypeMismatch,
            },
            else => return error.TypeMismatch,
        }
    }

    /// Convert a Value to its string representation for interpolation
    fn valueToString(self: *Interpreter, value: Value) InterpreterError![]const u8 {
        return switch (value) {
            .Int => |i| blk: {
                const str = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{i});
                break :blk str;
            },
            .Float => |f| blk: {
                const str = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{f});
                break :blk str;
            },
            .Bool => |b| if (b) "true" else "false",
            .String => |s| s,
            .Array => blk: {
                var buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
                defer buf.deinit(self.arena.allocator());
                try buf.appendSlice(self.arena.allocator(), "[");
                for (value.Array, 0..) |elem, i| {
                    if (i > 0) try buf.appendSlice(self.arena.allocator(), ", ");
                    const elem_str = try self.valueToString(elem);
                    try buf.appendSlice(self.arena.allocator(), elem_str);
                }
                try buf.appendSlice(self.arena.allocator(), "]");
                break :blk try self.arena.allocator().dupe(u8, buf.items);
            },
            .Struct => |s| blk: {
                const str = try std.fmt.allocPrint(self.arena.allocator(), "<{s} instance>", .{s.type_name});
                break :blk str;
            },
            .Function => |f| blk: {
                const str = try std.fmt.allocPrint(self.arena.allocator(), "<fn {s}>", .{f.name});
                break :blk str;
            },
            .Closure => "<closure>",
            .Range => |r| blk: {
                const str = if (r.inclusive)
                    try std.fmt.allocPrint(self.arena.allocator(), "{d}..={d}", .{ r.start, r.end })
                else
                    try std.fmt.allocPrint(self.arena.allocator(), "{d}..{d}", .{ r.start, r.end });
                break :blk str;
            },
            .EnumType => |e| blk: {
                const str = try std.fmt.allocPrint(self.arena.allocator(), "<enum {s}>", .{e.name});
                break :blk str;
            },
            .Void => "void",
        };
    }

    /// Check if break should target this loop
    fn shouldBreakHere(self: *Interpreter, loop_label: ?[]const u8) !bool {
        if (self.break_target) |target| {
            if (target.label) |label| {
                // Labeled break - check if this loop matches
                if (loop_label) |ll| {
                    if (std.mem.eql(u8, label, ll)) {
                        // Found target loop, clear break_target
                        self.break_target = null;
                        return true;
                    }
                }
                // Not the target loop, continue propagating
                return false;
            }
        }
        // Unlabeled break or no target - break innermost loop
        self.break_target = null;
        return true;
    }

    /// Check if continue should target this loop
    fn shouldContinueHere(self: *Interpreter, loop_label: ?[]const u8) !bool {
        if (self.continue_target) |target| {
            if (target.label) |label| {
                // Labeled continue - check if this loop matches
                if (loop_label) |ll| {
                    if (std.mem.eql(u8, label, ll)) {
                        // Found target loop, clear continue_target
                        self.continue_target = null;
                        return true;
                    }
                }
                // Not the target loop, continue propagating
                return false;
            }
        }
        // Unlabeled continue or no target - continue innermost loop
        self.continue_target = null;
        return true;
    }

    /// Match a pattern expression against a value (for MatchExpr)
    fn matchPattern(self: *Interpreter, pattern: *const ast.Expr, value: Value, env: *Environment) InterpreterError!bool {
        switch (pattern.*) {
            .Identifier => |id| {
                // Wildcard pattern (_) matches anything
                if (std.mem.eql(u8, id.name, "_")) {
                    return true;
                }
                // Variable binding - bind value to the identifier
                try env.define(id.name, value);
                return true;
            },
            .IntegerLiteral => |lit| {
                // Match integer literal
                if (value == .Int) {
                    return value.Int == lit.value;
                }
                return false;
            },
            .BooleanLiteral => |lit| {
                // Match boolean literal
                if (value == .Bool) {
                    return value.Bool == lit.value;
                }
                return false;
            },
            .StringLiteral => |lit| {
                // Match string literal
                if (value == .String) {
                    return std.mem.eql(u8, value.String, lit.value);
                }
                return false;
            },
            .MemberExpr => |member| {
                // Enum variant pattern like Color.Red or Option.Some(x)
                // For now, match against the member name
                if (value == .Struct) {
                    // Check if the struct type matches the pattern
                    // This is a simplified implementation
                    return std.mem.eql(u8, value.Struct.type_name, member.member);
                }
                // For simple enum variants without data
                if (value == .String) {
                    return std.mem.eql(u8, value.String, member.member);
                }
                return false;
            },
            .CallExpr => |call| {
                // Enum variant with data like Option.Some(value)
                // The call.callee should be a MemberExpr
                if (call.callee.* == .MemberExpr) {
                    const member = call.callee.MemberExpr;
                    if (value == .Struct) {
                        // Check if variant name matches
                        if (!std.mem.eql(u8, value.Struct.type_name, member.member)) {
                            return false;
                        }
                        // Bind the inner value to the pattern argument
                        if (call.args.len > 0) {
                            // Get the inner value from the struct
                            if (value.Struct.fields.get("0")) |inner_value| {
                                return try self.matchPattern(call.args[0], inner_value, env);
                            } else if (value.Struct.fields.get("value")) |inner_value| {
                                return try self.matchPattern(call.args[0], inner_value, env);
                            }
                        }
                        return true;
                    }
                }
                return false;
            },
            else => {
                // Unknown pattern type - try to evaluate and compare
                const pattern_value = self.evaluateExpression(pattern, env) catch {
                    return false;
                };
                return try self.areEqual(value, pattern_value);
            },
        }
    }

    /// Match a Pattern node against a value (for MatchStmt)
    fn matchPatternNode(self: *Interpreter, pattern: *const ast.Pattern, value: Value, env: *Environment) InterpreterError!bool {
        switch (pattern.*) {
            .Wildcard => {
                // Wildcard pattern matches anything
                return true;
            },
            .Identifier => |name| {
                // Variable binding - bind the matched value to the identifier
                try env.define(name, value);
                return true;
            },
            .IntLiteral => |lit_value| {
                // Integer literal pattern
                if (value == .Int) {
                    return value.Int == lit_value;
                }
                return false;
            },
            .FloatLiteral => |lit_value| {
                // Float literal pattern
                if (value == .Float) {
                    return value.Float == lit_value;
                }
                return false;
            },
            .StringLiteral => |lit_value| {
                // String literal pattern
                if (value == .String) {
                    return std.mem.eql(u8, value.String, lit_value);
                }
                return false;
            },
            .BoolLiteral => |lit_value| {
                // Boolean literal pattern
                if (value == .Bool) {
                    return value.Bool == lit_value;
                }
                return false;
            },
            .EnumVariant => |var_pattern| {
                // Enum variant pattern
                if (value == .Struct) {
                    // Check variant name
                    if (!std.mem.eql(u8, value.Struct.type_name, var_pattern.variant)) {
                        return false;
                    }
                    // Bind payload if present
                    if (var_pattern.payload) |payload_pattern| {
                        if (value.Struct.fields.get("0")) |inner_value| {
                            return try self.matchPatternNode(payload_pattern, inner_value, env);
                        } else if (value.Struct.fields.get("value")) |inner_value| {
                            return try self.matchPatternNode(payload_pattern, inner_value, env);
                        }
                    }
                    return true;
                }
                return false;
            },
            else => {
                // Other pattern types not yet implemented
                return false;
            },
        }
    }
};
