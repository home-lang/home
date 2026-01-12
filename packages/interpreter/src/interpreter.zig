const std = @import("std");
const ast = @import("ast");
const value_mod = @import("value.zig");
pub const Value = value_mod.Value;
const FunctionValue = value_mod.FunctionValue;
const ClosureValue = value_mod.ClosureValue;
const ReferenceValue = value_mod.ReferenceValue;
const EnumVariantInfo = value_mod.EnumVariantInfo;
const EnumTypeValue = value_mod.EnumTypeValue;
const MapValue = value_mod.MapValue;
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
    /// Registry for impl methods: type_name -> (method_name -> FnDecl)
    impl_methods: std.StringHashMap(std.StringHashMap(*ast.FnDecl)),
    /// Whether to print verbose test output (each test name)
    verbose_tests: bool,

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
        interpreter.impl_methods = std.StringHashMap(std.StringHashMap(*ast.FnDecl)).init(arena_allocator);
        interpreter.verbose_tests = true; // Default to verbose for backward compatibility

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

    /// Set whether to print verbose test output (each test name)
    pub fn setVerboseTests(self: *Interpreter, verbose: bool) void {
        self.verbose_tests = verbose;
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
                    // Create scope for then block (for defer support)
                    var then_env = Environment.init(self.arena.allocator(), env);
                    defer then_env.deinit();

                    var then_err: ?InterpreterError = null;
                    for (if_stmt.then_block.statements) |then_stmt| {
                        self.executeStatement(then_stmt, &then_env) catch |err| {
                            then_err = err;
                            break;
                        };
                    }

                    // Execute defers at end of then block
                    const defers = then_env.getDefers();
                    var i: usize = defers.len;
                    while (i > 0) {
                        i -= 1;
                        _ = self.evaluateExpression(defers[i], &then_env) catch {};
                    }

                    if (then_err) |err| return err;
                } else if (if_stmt.else_block) |else_block| {
                    // Create scope for else block
                    var else_env = Environment.init(self.arena.allocator(), env);
                    defer else_env.deinit();

                    var else_err: ?InterpreterError = null;
                    for (else_block.statements) |else_stmt| {
                        self.executeStatement(else_stmt, &else_env) catch |err| {
                            else_err = err;
                            break;
                        };
                    }

                    // Execute defers at end of else block
                    const defers = else_env.getDefers();
                    var i: usize = defers.len;
                    while (i > 0) {
                        i -= 1;
                        _ = self.evaluateExpression(defers[i], &else_env) catch {};
                    }

                    if (else_err) |err| return err;
                }
            },
            .WhileStmt => |while_stmt| {
                // Push loop onto stack with its label
                try self.loop_labels.append(self.allocator, while_stmt.label);
                defer _ = self.loop_labels.pop();

                outer: while (true) {
                    const condition = try self.evaluateExpression(while_stmt.condition, env);
                    const should_continue = condition.isTrue();

                    if (!should_continue) break;

                    // Create a new scope for each iteration (for defer support)
                    var iter_env = Environment.init(self.arena.allocator(), env);
                    defer iter_env.deinit();

                    var iter_err: ?InterpreterError = null;
                    for (while_stmt.body.statements) |body_stmt| {
                        self.executeStatement(body_stmt, &iter_env) catch |err| {
                            iter_err = err;
                            break;
                        };
                    }

                    // Execute defers at end of iteration
                    const defers = iter_env.getDefers();
                    var i: usize = defers.len;
                    while (i > 0) {
                        i -= 1;
                        _ = self.evaluateExpression(defers[i], &iter_env) catch {};
                    }

                    // Handle errors after defers
                    if (iter_err) |err| {
                        if (err == error.Return) return err;
                        if (err == error.Break) {
                            if (try self.shouldBreakHere(while_stmt.label)) {
                                break :outer;
                            } else {
                                return err;
                            }
                        }
                        if (err == error.Continue) {
                            if (try self.shouldContinueHere(while_stmt.label)) {
                                continue :outer;
                            } else {
                                return err;
                            }
                        }
                        return err;
                    }
                }
            },
            .ForStmt => |for_stmt| {
                // Evaluate the iterable
                const iterable_value = try self.evaluateExpression(for_stmt.iterable, env);

                if (iterable_value == .Int) {
                    const max = iterable_value.Int;
                    var i: i64 = 0;
                    outer_int: while (i < max) : (i += 1) {
                        // Create per-iteration scope for defer support
                        var iter_env = Environment.init(self.arena.allocator(), env);
                        defer iter_env.deinit();

                        if (for_stmt.index) |index_var| {
                            try iter_env.define(index_var, Value{ .Int = i });
                        }
                        try iter_env.define(for_stmt.iterator, Value{ .Int = i });

                        var iter_err: ?InterpreterError = null;
                        for (for_stmt.body.statements) |body_stmt| {
                            self.executeStatement(body_stmt, &iter_env) catch |err| {
                                iter_err = err;
                                break;
                            };
                        }

                        // Execute defers at end of iteration
                        const defers = iter_env.getDefers();
                        var di: usize = defers.len;
                        while (di > 0) {
                            di -= 1;
                            _ = self.evaluateExpression(defers[di], &iter_env) catch {};
                        }

                        if (iter_err) |err| {
                            if (err == error.Return) return err;
                            if (err == error.Break) {
                                if (try self.shouldBreakHere(for_stmt.label)) {
                                    break :outer_int;
                                } else {
                                    return err;
                                }
                            }
                            if (err == error.Continue) {
                                if (try self.shouldContinueHere(for_stmt.label)) {
                                    continue :outer_int;
                                } else {
                                    return err;
                                }
                            }
                            return err;
                        }
                    }
                } else if (iterable_value == .Array) {
                    const arr = iterable_value.Array;
                    outer_arr: for (arr, 0..) |elem, idx| {
                        var iter_env = Environment.init(self.arena.allocator(), env);
                        defer iter_env.deinit();

                        const i: i64 = @intCast(idx);
                        if (for_stmt.index) |index_var| {
                            try iter_env.define(index_var, Value{ .Int = i });
                        }
                        try iter_env.define(for_stmt.iterator, elem);

                        var iter_err: ?InterpreterError = null;
                        for (for_stmt.body.statements) |body_stmt| {
                            self.executeStatement(body_stmt, &iter_env) catch |err| {
                                iter_err = err;
                                break;
                            };
                        }

                        const defers = iter_env.getDefers();
                        var di: usize = defers.len;
                        while (di > 0) {
                            di -= 1;
                            _ = self.evaluateExpression(defers[di], &iter_env) catch {};
                        }

                        if (iter_err) |err| {
                            if (err == error.Return) return err;
                            if (err == error.Break) {
                                if (try self.shouldBreakHere(for_stmt.label)) {
                                    break :outer_arr;
                                } else {
                                    return err;
                                }
                            }
                            if (err == error.Continue) {
                                if (try self.shouldContinueHere(for_stmt.label)) {
                                    continue :outer_arr;
                                } else {
                                    return err;
                                }
                            }
                            return err;
                        }
                    }
                } else if (iterable_value == .Range) {
                    const range = iterable_value.Range;
                    var current = range.start;
                    var idx: i64 = 0;
                    const end_condition = if (range.inclusive) range.end + 1 else range.end;
                    outer_range: while (current < end_condition) : ({
                        current += range.step;
                        idx += 1;
                    }) {
                        var iter_env = Environment.init(self.arena.allocator(), env);
                        defer iter_env.deinit();

                        if (for_stmt.index) |index_var| {
                            try iter_env.define(index_var, Value{ .Int = idx });
                        }
                        try iter_env.define(for_stmt.iterator, Value{ .Int = current });

                        var iter_err: ?InterpreterError = null;
                        for (for_stmt.body.statements) |body_stmt| {
                            self.executeStatement(body_stmt, &iter_env) catch |err| {
                                iter_err = err;
                                break;
                            };
                        }

                        const defers = iter_env.getDefers();
                        var di: usize = defers.len;
                        while (di > 0) {
                            di -= 1;
                            _ = self.evaluateExpression(defers[di], &iter_env) catch {};
                        }

                        if (iter_err) |err| {
                            if (err == error.Return) return err;
                            if (err == error.Break) {
                                if (try self.shouldBreakHere(for_stmt.label)) {
                                    break :outer_range;
                                } else {
                                    return err;
                                }
                            }
                            if (err == error.Continue) {
                                if (try self.shouldContinueHere(for_stmt.label)) {
                                    continue :outer_range;
                                } else {
                                    return err;
                                }
                            }
                            return err;
                        }
                    }
                } else if (iterable_value == .String) {
                    // String iteration - iterate over characters as integers (char codes)
                    const str = iterable_value.String;
                    outer_str: for (str, 0..) |byte, idx| {
                        var iter_env = Environment.init(self.arena.allocator(), env);
                        defer iter_env.deinit();

                        const i: i64 = @intCast(idx);
                        if (for_stmt.index) |index_var| {
                            try iter_env.define(index_var, Value{ .Int = i });
                        }
                        // Each character is represented as its integer code (like char literals)
                        try iter_env.define(for_stmt.iterator, Value{ .Int = @as(i64, byte) });

                        var iter_err: ?InterpreterError = null;
                        for (for_stmt.body.statements) |body_stmt| {
                            self.executeStatement(body_stmt, &iter_env) catch |err| {
                                iter_err = err;
                                break;
                            };
                        }

                        const defers = iter_env.getDefers();
                        var di: usize = defers.len;
                        while (di > 0) {
                            di -= 1;
                            _ = self.evaluateExpression(defers[di], &iter_env) catch {};
                        }

                        if (iter_err) |err| {
                            if (err == error.Return) return err;
                            if (err == error.Break) {
                                if (try self.shouldBreakHere(for_stmt.label)) {
                                    break :outer_str;
                                } else {
                                    return err;
                                }
                            }
                            if (err == error.Continue) {
                                if (try self.shouldContinueHere(for_stmt.label)) {
                                    continue :outer_str;
                                } else {
                                    return err;
                                }
                            }
                            return err;
                        }
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
            .ImplDecl => |impl_decl| {
                // Register impl methods in the method registry
                // Get the type name from the for_type (TypeExpr union)
                const type_name: []const u8 = switch (impl_decl.for_type.*) {
                    .Named => |name| name,
                    .Generic => |gen| gen.base,
                    else => "unknown",
                };

                // Get or create the method map for this type
                const result = self.impl_methods.getOrPut(type_name) catch {
                    return error.RuntimeError;
                };
                if (!result.found_existing) {
                    result.value_ptr.* = std.StringHashMap(*ast.FnDecl).init(self.arena.allocator());
                }
                var method_map = result.value_ptr;

                // Register each method
                for (impl_decl.methods) |method| {
                    method_map.put(method.name, method) catch {
                        return error.RuntimeError;
                    };
                }
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

                var block_err: ?InterpreterError = null;
                for (block.statements) |block_stmt| {
                    self.executeStatement(block_stmt, &block_env) catch |err| {
                        block_err = err;
                        break;
                    };
                }

                // Execute defers in reverse order (LIFO)
                const defers = block_env.getDefers();
                var i: usize = defers.len;
                while (i > 0) {
                    i -= 1;
                    _ = self.evaluateExpression(defers[i], &block_env) catch {};
                }

                // Propagate any error that occurred
                if (block_err) |err| {
                    return err;
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
                // Add the deferred expression to the current scope's defer list
                // It will be executed when the scope exits (in reverse order)
                try env.addDefer(defer_stmt.body);
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
                if (self.verbose_tests) {
                    std.debug.print("  it {s} ... ", .{it_test.description});
                }

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
                    if (self.verbose_tests) {
                        std.debug.print("PASS\n", .{});
                    }
                } else {
                    if (self.verbose_tests) {
                        std.debug.print("FAIL\n", .{});
                    } else {
                        // In quiet mode, still show which test failed
                        std.debug.print("  FAIL: {s}\n", .{it_test.description});
                    }
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
                // Process escape sequences in string literals
                const processed = try self.processStringEscapes(lit.value);
                return Value{ .String = processed };
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
                // Handle built-in constants
                if (std.mem.eql(u8, id.name, "None")) {
                    // None - the empty Option variant
                    const fields = std.StringHashMap(Value).init(self.arena.allocator());
                    return Value{ .Struct = .{ .type_name = "None", .fields = fields }};
                }
                if (std.mem.eql(u8, id.name, "true")) {
                    return Value{ .Bool = true };
                }
                if (std.mem.eql(u8, id.name, "false")) {
                    return Value{ .Bool = false };
                }

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

                // Handle map indexing - key can be string or int converted to string
                if (array_value == .Map) {
                    const key_str = switch (index_value) {
                        .String => |s| s,
                        .Int => |i| blk: {
                            const buf = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{i});
                            break :blk buf;
                        },
                        else => {
                            std.debug.print("Map key must be a string or integer\n", .{});
                            return error.TypeMismatch;
                        },
                    };
                    if (array_value.Map.entries.get(key_str)) |val| {
                        return val;
                    }
                    std.debug.print("Map key not found: {s}\n", .{key_str});
                    return error.RuntimeError;
                }

                if (index_value != .Int) {
                    std.debug.print("Array/string index must be an integer\n", .{});
                    return error.TypeMismatch;
                }

                const idx = index_value.Int;

                // Handle array indexing
                if (array_value == .Array) {
                    if (idx < 0 or idx >= @as(i64, @intCast(array_value.Array.len))) {
                        std.debug.print("Array index out of bounds: {d}\n", .{idx});
                        return error.RuntimeError;
                    }
                    return array_value.Array[@as(usize, @intCast(idx))];
                }

                // Handle string indexing - returns character code (Int)
                if (array_value == .String) {
                    const str = array_value.String;
                    if (idx < 0 or idx >= @as(i64, @intCast(str.len))) {
                        std.debug.print("String index out of bounds: {d}\n", .{idx});
                        return error.RuntimeError;
                    }
                    // Return the character code as an integer (like char literal)
                    return Value{ .Int = @as(i64, str[@as(usize, @intCast(idx))]) };
                }

                std.debug.print("Cannot index non-array/non-string/non-map value\n", .{});
                return error.TypeMismatch;
            },
            .SliceExpr => |slice| {
                const array_value = try self.evaluateExpression(slice.array, env);

                // Handle string slicing
                if (array_value == .String) {
                    const str = array_value.String;
                    const str_len = @as(i64, @intCast(str.len));

                    // Determine start index (default to 0 if null)
                    const start_idx: i64 = if (slice.start) |start_expr| blk: {
                        const start_value = try self.evaluateExpression(start_expr, env);
                        if (start_value != .Int) {
                            std.debug.print("Slice start index must be an integer\n", .{});
                            return error.TypeMismatch;
                        }
                        break :blk start_value.Int;
                    } else 0;

                    // Determine end index (default to string length if null)
                    const end_idx: i64 = if (slice.end) |end_expr| blk: {
                        const end_value = try self.evaluateExpression(end_expr, env);
                        if (end_value != .Int) {
                            std.debug.print("Slice end index must be an integer\n", .{});
                            return error.TypeMismatch;
                        }
                        const idx = end_value.Int;
                        break :blk if (slice.inclusive) idx + 1 else idx;
                    } else str_len;

                    // Bounds checking
                    if (start_idx < 0 or start_idx > str_len) {
                        std.debug.print("String slice start index out of bounds: {d}\n", .{start_idx});
                        return error.RuntimeError;
                    }
                    if (end_idx < start_idx or end_idx > str_len) {
                        std.debug.print("String slice end index out of bounds: {d}\n", .{end_idx});
                        return error.RuntimeError;
                    }

                    // Create sliced string
                    const start_usize = @as(usize, @intCast(start_idx));
                    const end_usize = @as(usize, @intCast(end_idx));
                    const sliced_str = try self.arena.allocator().dupe(u8, str[start_usize..end_usize]);
                    return Value{ .String = sliced_str };
                }

                if (array_value != .Array) {
                    std.debug.print("Cannot slice non-array/non-string value\n", .{});
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
            .AwaitExpr => |await_expr| {
                // Evaluate the awaited expression
                const awaited_value = try self.evaluateExpression(await_expr.expression, env);

                // If it's a Future, resolve it
                if (awaited_value == .Future) {
                    const future = awaited_value.Future;
                    if (future.is_resolved) {
                        if (future.resolved) |resolved_ptr| {
                            return resolved_ptr.*;
                        }
                        return Value.Void;
                    }
                    // Pending future - in synchronous interpreter, just return void
                    return Value.Void;
                }

                // Not a future - just return the value (synchronous await)
                return awaited_value;
            },
            .ElvisExpr => |elvis| {
                // Elvis operator: left ?: right
                // Returns left if truthy, otherwise right
                const left = try self.evaluateExpression(elvis.left, env);

                // Check if left is "falsy"
                const is_falsy = switch (left) {
                    .Void => true,
                    .Bool => |b| !b,
                    .Int => |i| i == 0,
                    .String => |s| s.len == 0,
                    else => false,
                };

                if (is_falsy) {
                    return try self.evaluateExpression(elvis.right, env);
                }
                return left;
            },
            .CharLiteral => |lit| {
                // Parse character literal (e.g., 'a', '\n', '\x41')
                const char_str = lit.value;

                // Remove surrounding quotes if present
                const inner = if (char_str.len >= 2 and char_str[0] == '\'' and char_str[char_str.len - 1] == '\'')
                    char_str[1 .. char_str.len - 1]
                else
                    char_str;

                if (inner.len == 0) {
                    std.debug.print("Empty character literal\n", .{});
                    return error.RuntimeError;
                }

                // Handle escape sequences
                if (inner[0] == '\\' and inner.len >= 2) {
                    const char_val: i64 = switch (inner[1]) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '\\' => '\\',
                        '\'' => '\'',
                        '"' => '"',
                        '0' => 0,
                        'x' => blk: {
                            // Hex escape \xNN
                            if (inner.len >= 4) {
                                const hex_val = std.fmt.parseInt(u8, inner[2..4], 16) catch 0;
                                break :blk hex_val;
                            }
                            break :blk 0;
                        },
                        else => inner[1],
                    };
                    return Value{ .Int = char_val };
                }

                // Simple character
                return Value{ .Int = @as(i64, inner[0]) };
            },
            .TypeCastExpr => |cast| {
                // Type cast: value as TargetType
                const value = try self.evaluateExpression(cast.value, env);
                const target = cast.target_type;

                // Integer to integer casts
                if (value == .Int) {
                    const int_val = value.Int;
                    if (std.mem.eql(u8, target, "i8")) {
                        return Value{ .Int = @as(i64, @as(i8, @truncate(int_val))) };
                    } else if (std.mem.eql(u8, target, "i16")) {
                        return Value{ .Int = @as(i64, @as(i16, @truncate(int_val))) };
                    } else if (std.mem.eql(u8, target, "i32")) {
                        return Value{ .Int = @as(i64, @as(i32, @truncate(int_val))) };
                    } else if (std.mem.eql(u8, target, "i64")) {
                        return Value{ .Int = int_val };
                    } else if (std.mem.eql(u8, target, "u8")) {
                        return Value{ .Int = @as(i64, @as(u8, @truncate(@as(u64, @bitCast(int_val))))) };
                    } else if (std.mem.eql(u8, target, "u16")) {
                        return Value{ .Int = @as(i64, @as(u16, @truncate(@as(u64, @bitCast(int_val))))) };
                    } else if (std.mem.eql(u8, target, "u32")) {
                        return Value{ .Int = @as(i64, @as(u32, @truncate(@as(u64, @bitCast(int_val))))) };
                    } else if (std.mem.eql(u8, target, "u64")) {
                        return Value{ .Int = @as(i64, @bitCast(@as(u64, @bitCast(int_val)))) };
                    } else if (std.mem.eql(u8, target, "f32") or std.mem.eql(u8, target, "f64")) {
                        return Value{ .Float = @as(f64, @floatFromInt(int_val)) };
                    } else if (std.mem.eql(u8, target, "char")) {
                        return Value{ .Int = int_val };
                    } else if (std.mem.eql(u8, target, "bool")) {
                        return Value{ .Bool = int_val != 0 };
                    }
                }

                // Float to integer casts
                if (value == .Float) {
                    const float_val = value.Float;
                    if (std.mem.eql(u8, target, "i32") or std.mem.eql(u8, target, "i64") or
                        std.mem.eql(u8, target, "i8") or std.mem.eql(u8, target, "i16")) {
                        return Value{ .Int = @as(i64, @intFromFloat(float_val)) };
                    } else if (std.mem.eql(u8, target, "f32") or std.mem.eql(u8, target, "f64")) {
                        return Value{ .Float = float_val };
                    }
                }

                // Bool to integer cast
                if (value == .Bool) {
                    const bool_val = value.Bool;
                    if (std.mem.eql(u8, target, "i32") or std.mem.eql(u8, target, "i64") or
                        std.mem.eql(u8, target, "i8") or std.mem.eql(u8, target, "i16")) {
                        return Value{ .Int = if (bool_val) 1 else 0 };
                    }
                }

                // Return original value if cast type not recognized
                return value;
            },
            .ArrayRepeat => |repeat| {
                // Array repeat: [value; count]
                const value = try self.evaluateExpression(repeat.value, env);

                // Get count from either count_expr or count string
                const count: usize = if (repeat.count_expr) |count_expr| blk: {
                    const count_val = try self.evaluateExpression(count_expr, env);
                    if (count_val != .Int) {
                        std.debug.print("Array repeat count must be an integer\n", .{});
                        return error.TypeMismatch;
                    }
                    if (count_val.Int < 0) {
                        std.debug.print("Array repeat count cannot be negative\n", .{});
                        return error.RuntimeError;
                    }
                    break :blk @as(usize, @intCast(count_val.Int));
                } else blk: {
                    const parsed = std.fmt.parseInt(usize, repeat.count, 10) catch {
                        std.debug.print("Invalid array repeat count: {s}\n", .{repeat.count});
                        return error.RuntimeError;
                    };
                    break :blk parsed;
                };

                // Create array with repeated values
                const elements = try self.arena.allocator().alloc(Value, count);
                for (elements) |*elem| {
                    elem.* = value;
                }

                return Value{ .Array = elements };
            },
            .TryExpr => |try_expr| {
                // Try expression: expr? or expr else default
                const operand_result = self.evaluateExpression(try_expr.operand, env) catch |err| {
                    // If there's an else branch, use it as default
                    if (try_expr.else_branch) |else_branch| {
                        return try self.evaluateExpression(else_branch, env);
                    }
                    // Otherwise propagate the error
                    return err;
                };

                // Check if the result is an error variant (Err)
                if (operand_result == .Struct) {
                    if (std.mem.eql(u8, operand_result.Struct.type_name, "Err")) {
                        if (try_expr.else_branch) |else_branch| {
                            return try self.evaluateExpression(else_branch, env);
                        }
                        // Propagate error by returning it
                        return error.RuntimeError;
                    }
                    // If it's Ok, unwrap the value
                    if (std.mem.eql(u8, operand_result.Struct.type_name, "Ok")) {
                        if (operand_result.Struct.fields.get("value")) |inner_value| {
                            return inner_value;
                        }
                        if (operand_result.Struct.fields.get("0")) |inner_value| {
                            return inner_value;
                        }
                        return operand_result;
                    }
                }

                // Check for None (Option type)
                if (operand_result == .Void) {
                    if (try_expr.else_branch) |else_branch| {
                        return try self.evaluateExpression(else_branch, env);
                    }
                    return error.RuntimeError;
                }

                // If result has Some wrapper, unwrap it
                if (operand_result == .Struct) {
                    if (std.mem.eql(u8, operand_result.Struct.type_name, "Some")) {
                        if (operand_result.Struct.fields.get("value")) |inner_value| {
                            return inner_value;
                        }
                        if (operand_result.Struct.fields.get("0")) |inner_value| {
                            return inner_value;
                        }
                    }
                }

                return operand_result;
            },
            .SafeIndexExpr => |safe_index| {
                // Safe index: arr?[idx] or map?[key] - returns null for out of bounds / missing key
                const container_value = try self.evaluateExpression(safe_index.object, env);
                const index_value = try self.evaluateExpression(safe_index.index, env);

                // If container is null/void, return void
                if (container_value == .Void) {
                    return Value.Void;
                }

                // Handle map safe access
                if (container_value == .Map) {
                    const key_str = switch (index_value) {
                        .String => |s| s,
                        .Int => |i| blk: {
                            const buf = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{i});
                            break :blk buf;
                        },
                        else => return Value.Void,
                    };
                    if (container_value.Map.entries.get(key_str)) |val| {
                        return val;
                    }
                    return Value.Void;
                }

                // Handle array safe access
                if (container_value != .Array) {
                    return Value.Void;
                }

                if (index_value != .Int) {
                    return Value.Void;
                }

                const idx = index_value.Int;
                const arr_len = @as(i64, @intCast(container_value.Array.len));

                // Return void for out of bounds instead of error
                if (idx < 0 or idx >= arr_len) {
                    return Value.Void;
                }

                return container_value.Array[@as(usize, @intCast(idx))];
            },
            .IsExpr => |is_expr| {
                // Is expression: value is Type
                const value = try self.evaluateExpression(is_expr.value, env);
                const type_name = is_expr.type_name;
                const negated = is_expr.negated;

                const matches = switch (value) {
                    .Int => std.mem.eql(u8, type_name, "i32") or
                            std.mem.eql(u8, type_name, "i64") or
                            std.mem.eql(u8, type_name, "int") or
                            std.mem.eql(u8, type_name, "number"),
                    .Float => std.mem.eql(u8, type_name, "f32") or
                              std.mem.eql(u8, type_name, "f64") or
                              std.mem.eql(u8, type_name, "float") or
                              std.mem.eql(u8, type_name, "number"),
                    .Bool => std.mem.eql(u8, type_name, "bool") or
                             std.mem.eql(u8, type_name, "boolean"),
                    .String => std.mem.eql(u8, type_name, "string") or
                               std.mem.eql(u8, type_name, "str"),
                    .Array => std.mem.eql(u8, type_name, "array") or
                              std.mem.startsWith(u8, type_name, "["),
                    .Struct => |s| std.mem.eql(u8, type_name, s.type_name) or
                                   std.mem.eql(u8, type_name, "Ok") and std.mem.eql(u8, s.type_name, "Ok") or
                                   std.mem.eql(u8, type_name, "Err") and std.mem.eql(u8, s.type_name, "Err") or
                                   std.mem.eql(u8, type_name, "Some") and std.mem.eql(u8, s.type_name, "Some"),
                    .Void => std.mem.eql(u8, type_name, "null") or
                             std.mem.eql(u8, type_name, "None") or
                             std.mem.eql(u8, type_name, "void"),
                    .Function, .Closure => std.mem.eql(u8, type_name, "function") or
                                           std.mem.eql(u8, type_name, "fn"),
                    else => false,
                };

                const result = if (negated) !matches else matches;
                return Value{ .Bool = result };
            },
            .MapLiteral => |map_lit| {
                var entries = std.StringHashMap(Value).init(self.arena.allocator());
                for (map_lit.entries) |entry| {
                    const key_value = try self.evaluateExpression(entry.key, env);
                    const value = try self.evaluateExpression(entry.value, env);

                    // Key must be a string for now
                    const key_str = switch (key_value) {
                        .String => |s| s,
                        .Int => |i| blk: {
                            const buf = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{i});
                            break :blk buf;
                        },
                        else => {
                            std.debug.print("Map keys must be strings or integers\n", .{});
                            return error.TypeMismatch;
                        },
                    };

                    try entries.put(key_str, value);
                }
                return Value{ .Map = .{ .entries = entries } };
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
            // Checked arithmetic with Option (returns Option-like value)
            .SaturatingAdd => try self.applyCheckedArithmetic(left, right, .SaturatingAdd),
            .SaturatingSub => try self.applyCheckedArithmetic(left, right, .SaturatingSub),
            .SaturatingMul => try self.applyCheckedArithmetic(left, right, .SaturatingMul),
            .SaturatingDiv => try self.applyCheckedArithmetic(left, right, .SaturatingDiv),
            // Clamping arithmetic (clamps to bounds)
            .ClampAdd => try self.applyClampingArithmetic(left, right, .ClampAdd),
            .ClampSub => try self.applyClampingArithmetic(left, right, .ClampSub),
            .ClampMul => try self.applyClampingArithmetic(left, right, .ClampMul),
            // Panic-on-overflow arithmetic
            .CheckedAdd => try self.applyPanicArithmetic(left, right, .CheckedAdd),
            .CheckedSub => try self.applyPanicArithmetic(left, right, .CheckedSub),
            .CheckedMul => try self.applyPanicArithmetic(left, right, .CheckedMul),
            .CheckedDiv => try self.applyPanicArithmetic(left, right, .CheckedDiv),
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
                // If it's a reference, get the actual value
                if (operand == .Reference) {
                    const ref = operand.Reference;
                    if (env.get(ref.var_name)) |val| {
                        return val;
                    }
                    std.debug.print("Dereferenced variable '{s}' not found\n", .{ref.var_name});
                    return error.UndefinedVariable;
                }
                // Otherwise just return the value
                return operand;
            },
            .AddressOf => {
                // Address-of operation: &value
                // Get the variable name if it's an identifier
                if (unary.operand.* == .Identifier) {
                    const name = unary.operand.Identifier.name;
                    return Value{ .Reference = ReferenceValue{
                        .var_name = name,
                        .is_mutable = false,
                    } };
                }
                return operand;
            },
            .Borrow => {
                // Immutable borrow: &value
                if (unary.operand.* == .Identifier) {
                    const name = unary.operand.Identifier.name;
                    return Value{ .Reference = ReferenceValue{
                        .var_name = name,
                        .is_mutable = false,
                    } };
                }
                return operand;
            },
            .BorrowMut => {
                // Mutable borrow: &mut value
                if (unary.operand.* == .Identifier) {
                    const name = unary.operand.Identifier.name;
                    return Value{ .Reference = ReferenceValue{
                        .var_name = name,
                        .is_mutable = true,
                    } };
                }
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
            .IndexExpr => |index_expr| {
                // Array or Map element assignment: arr[i] = value or map[key] = value
                const index_value = try self.evaluateExpression(index_expr.index, env);

                // Handle simple identifier case: arr[i] = value or map[key] = value
                if (index_expr.array.* == .Identifier) {
                    const id = index_expr.array.Identifier;
                    const container_value = env.get(id.name) orelse {
                        std.debug.print("Undefined variable: {s}\n", .{id.name});
                        return error.RuntimeError;
                    };

                    // Handle Map assignment
                    if (container_value == .Map) {
                        const key_str = switch (index_value) {
                            .String => |s| s,
                            .Int => |i| blk: {
                                const buf = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{i});
                                break :blk buf;
                            },
                            else => {
                                std.debug.print("Map key must be a string or integer\n", .{});
                                return error.RuntimeError;
                            },
                        };

                        // Create new map with updated entry
                        var new_entries = std.StringHashMap(Value).init(self.arena.allocator());
                        var iter = container_value.Map.entries.iterator();
                        while (iter.next()) |entry| {
                            try new_entries.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                        try new_entries.put(key_str, value);

                        try env.set(id.name, Value{ .Map = .{ .entries = new_entries } });
                        return value;
                    }

                    // Handle Array assignment
                    if (container_value != .Array) {
                        std.debug.print("Cannot index into non-array/non-map value\n", .{});
                        return error.RuntimeError;
                    }

                    const idx = switch (index_value) {
                        .Int => |i| blk: {
                            if (i < 0) {
                                std.debug.print("Array index cannot be negative: {d}\n", .{i});
                                return error.RuntimeError;
                            }
                            break :blk @as(usize, @intCast(i));
                        },
                        else => {
                            std.debug.print("Array index must be an integer\n", .{});
                            return error.RuntimeError;
                        },
                    };

                    const arr = container_value.Array;
                    if (idx >= arr.len) {
                        std.debug.print("Array index out of bounds: {d} >= {d}\n", .{idx, arr.len});
                        return error.RuntimeError;
                    }

                    // Create a mutable copy of the array
                    const new_arr = try self.arena.allocator().alloc(Value, arr.len);
                    @memcpy(new_arr, arr);

                    // Update the element
                    new_arr[idx] = value;

                    // Store the new array back
                    try env.set(id.name, Value{ .Array = new_arr });
                    return value;
                }

                // Handle nested access like obj.arr[i] = value
                if (index_expr.array.* == .MemberExpr) {
                    const member = index_expr.array.MemberExpr;

                    // Compute index for nested access
                    const nested_idx = switch (index_value) {
                        .Int => |i| blk: {
                            if (i < 0) {
                                std.debug.print("Array index cannot be negative: {d}\n", .{i});
                                return error.RuntimeError;
                            }
                            break :blk @as(usize, @intCast(i));
                        },
                        else => {
                            std.debug.print("Array index must be an integer\n", .{});
                            return error.RuntimeError;
                        },
                    };

                    // Get the base object identifier
                    if (member.object.* == .Identifier) {
                        const obj_id = member.object.Identifier;
                        const obj_value = env.get(obj_id.name) orelse {
                            std.debug.print("Undefined object: {s}\n", .{obj_id.name});
                            return error.RuntimeError;
                        };

                        if (obj_value == .Struct) {
                            const inst = obj_value.Struct;

                            // Get the array field
                            const arr_field = inst.fields.get(member.member) orelse {
                                std.debug.print("Unknown field: {s}\n", .{member.member});
                                return error.RuntimeError;
                            };

                            if (arr_field != .Array) {
                                std.debug.print("Cannot index into non-array field\n", .{});
                                return error.RuntimeError;
                            }

                            const arr = arr_field.Array;
                            if (nested_idx >= arr.len) {
                                std.debug.print("Array index out of bounds: {d} >= {d}\n", .{nested_idx, arr.len});
                                return error.RuntimeError;
                            }

                            // Create a mutable copy of the array
                            const new_arr = try self.arena.allocator().alloc(Value, arr.len);
                            @memcpy(new_arr, arr);
                            new_arr[nested_idx] = value;

                            // Create new fields map with updated array
                            var new_fields = std.StringHashMap(Value).init(self.arena.allocator());
                            var it = inst.fields.iterator();
                            while (it.next()) |entry| {
                                if (std.mem.eql(u8, entry.key_ptr.*, member.member)) {
                                    try new_fields.put(entry.key_ptr.*, Value{ .Array = new_arr });
                                } else {
                                    try new_fields.put(entry.key_ptr.*, entry.value_ptr.*);
                                }
                            }

                            // Store the updated struct back
                            const new_struct = Value{ .Struct = .{
                                .type_name = inst.type_name,
                                .fields = new_fields,
                            }};
                            try env.set(obj_id.name, new_struct);
                            return value;
                        }
                    }
                }

                std.debug.print("Complex array element assignment not supported\n", .{});
                return error.RuntimeError;
            },
            .MemberExpr => |member| {
                // Struct field assignment: obj.field = value
                // Handle simple case: identifier.field = value
                if (member.object.* == .Identifier) {
                    const obj_id = member.object.Identifier;
                    const obj_value = env.get(obj_id.name) orelse {
                        std.debug.print("Undefined variable: {s}\n", .{obj_id.name});
                        return error.RuntimeError;
                    };

                    if (obj_value == .Struct) {
                        const inst = obj_value.Struct;

                        // Create new fields map with updated field
                        var new_fields = std.StringHashMap(Value).init(self.arena.allocator());
                        var it = inst.fields.iterator();
                        var found = false;
                        while (it.next()) |entry| {
                            if (std.mem.eql(u8, entry.key_ptr.*, member.member)) {
                                try new_fields.put(entry.key_ptr.*, value);
                                found = true;
                            } else {
                                try new_fields.put(entry.key_ptr.*, entry.value_ptr.*);
                            }
                        }

                        if (!found) {
                            std.debug.print("Unknown field: {s}\n", .{member.member});
                            return error.RuntimeError;
                        }

                        // Store the updated struct back
                        const new_struct = Value{ .Struct = .{
                            .type_name = inst.type_name,
                            .fields = new_fields,
                        }};
                        try env.set(obj_id.name, new_struct);
                        return value;
                    }
                }

                std.debug.print("Complex struct field assignment not supported\n", .{});
                return error.RuntimeError;
            },
            .UnaryExpr => |unary| {
                // Handle dereference assignment: *r = value
                if (unary.op == .Deref) {
                    // Evaluate the operand to get the reference
                    const ref_value = try self.evaluateExpression(unary.operand, env);
                    if (ref_value == .Reference) {
                        const ref = ref_value.Reference;
                        if (!ref.is_mutable) {
                            std.debug.print("Cannot assign through immutable reference\n", .{});
                            return error.RuntimeError;
                        }
                        try env.set(ref.var_name, value);
                        return value;
                    }
                    std.debug.print("Cannot dereference non-reference value\n", .{});
                    return error.RuntimeError;
                }
                std.debug.print("Cannot assign to unary expression\n", .{});
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
                // Check if object is an identifier (for in-place mutation of mutating methods)
                const var_name: ?[]const u8 = if (member.object.* == .Identifier) member.object.Identifier.name else null;
                return try self.evaluateArrayMethod(obj_value.Array, member.member, call.args, env, var_name);
            }

            // Handle map methods
            if (obj_value == .Map) {
                const var_name: ?[]const u8 = if (member.object.* == .Identifier) member.object.Identifier.name else null;
                return try self.evaluateMapMethod(obj_value.Map, member.member, call.args, env, var_name);
            }

            // Handle range methods
            if (obj_value == .Range) {
                return try self.evaluateRangeMethod(obj_value.Range, member.member, call.args, env);
            }

            // Handle struct methods (from impl blocks)
            if (obj_value == .Struct) {
                const struct_val = obj_value.Struct;
                // Look up method in impl_methods registry
                if (self.impl_methods.get(struct_val.type_name)) |method_map| {
                    if (method_map.get(member.member)) |method| {
                        return try self.callImplMethod(method, obj_value, call.args, env);
                    }
                }
                std.debug.print("No method '{s}' found for type '{s}'\n", .{ member.member, struct_val.type_name });
                return error.UndefinedFunction;
            }

            std.debug.print("Method calls only supported on strings, arrays, maps, ranges, enums, and structs\n", .{});
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
            } else if (std.mem.eql(u8, func_name, "Ok")) {
                // Ok(value) - creates Result success variant
                if (call.args.len != 1) {
                    std.debug.print("Ok() requires exactly 1 argument\n", .{});
                    return error.InvalidArguments;
                }
                const inner_value = try self.evaluateExpression(call.args[0], env);
                var fields = std.StringHashMap(Value).init(self.arena.allocator());
                try fields.put("value", inner_value);
                try fields.put("0", inner_value);
                return Value{ .Struct = .{ .type_name = "Ok", .fields = fields }};
            } else if (std.mem.eql(u8, func_name, "Err")) {
                // Err(value) - creates Result error variant
                if (call.args.len != 1) {
                    std.debug.print("Err() requires exactly 1 argument\n", .{});
                    return error.InvalidArguments;
                }
                const inner_value = try self.evaluateExpression(call.args[0], env);
                var fields = std.StringHashMap(Value).init(self.arena.allocator());
                try fields.put("value", inner_value);
                try fields.put("0", inner_value);
                return Value{ .Struct = .{ .type_name = "Err", .fields = fields }};
            } else if (std.mem.eql(u8, func_name, "Some")) {
                // Some(value) - creates Option some variant
                if (call.args.len != 1) {
                    std.debug.print("Some() requires exactly 1 argument\n", .{});
                    return error.InvalidArguments;
                }
                const inner_value = try self.evaluateExpression(call.args[0], env);
                var fields = std.StringHashMap(Value).init(self.arena.allocator());
                try fields.put("value", inner_value);
                try fields.put("0", inner_value);
                return Value{ .Struct = .{ .type_name = "Some", .fields = fields }};
            }

            // Look up user-defined function or closure
            if (env.get(func_name)) |func_value| {
                if (func_value == .Function) {
                    return try self.callUserFunctionWithNamed(func_value.Function, call.args, call.named_args, env);
                }
                if (func_value == .Closure) {
                    return try self.callClosureWithNamed(func_value.Closure, call.args, call.named_args, env);
                }
            }

            std.debug.print("Undefined function: {s}\n", .{func_name});
            return error.UndefinedFunction;
        }

        // Handle calling closure expressions directly (e.g., (|x| x + 1)(5))
        const callee_value = try self.evaluateExpression(call.callee, env);
        if (callee_value == .Closure) {
            return try self.callClosureWithNamed(callee_value.Closure, call.args, call.named_args, env);
        }
        if (callee_value == .Function) {
            return try self.callUserFunctionWithNamed(callee_value.Function, call.args, call.named_args, env);
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
            var closure_err: ?InterpreterError = null;
            for (block.statements) |stmt| {
                self.executeStatement(stmt, &closure_env) catch |err| {
                    closure_err = err;
                    break;
                };
            }

            // Execute defers in reverse order before returning
            const defers = closure_env.getDefers();
            var i: usize = defers.len;
            while (i > 0) {
                i -= 1;
                _ = self.evaluateExpression(defers[i], &closure_env) catch {};
            }

            // Handle return or error
            if (closure_err) |err| {
                if (err == error.Return) {
                    return self.return_value orelse Value.Void;
                }
                return err;
            }
            return Value.Void;
        }

        return Value.Void;
    }

    /// Call a closure with named arguments support
    fn callClosureWithNamed(self: *Interpreter, closure: ClosureValue, args: []const *const ast.Expr, named_args: []const ast.NamedArg, env: *Environment) InterpreterError!Value {
        // For closures without named arguments, use the simple path
        if (named_args.len == 0) {
            return self.callClosure(closure, args, env);
        }

        // Create new environment for closure execution
        var closure_env = Environment.init(self.arena.allocator(), env);

        // Bind captured variables
        for (closure.captured_names, 0..) |name, i| {
            try closure_env.define(name, closure.captured_values[i]);
        }

        // Track which parameters have been bound
        var bound = try self.arena.allocator().alloc(bool, closure.param_names.len);
        for (bound) |*b| b.* = false;

        // First, bind positional arguments
        for (args, 0..) |arg, i| {
            if (i >= closure.param_names.len) {
                std.debug.print("Too many positional arguments for closure\n", .{});
                return error.InvalidArguments;
            }
            const arg_value = try self.evaluateExpression(arg, env);
            try closure_env.define(closure.param_names[i], arg_value);
            bound[i] = true;
        }

        // Then, bind named arguments
        for (named_args) |named_arg| {
            var found_idx: ?usize = null;
            for (closure.param_names, 0..) |param_name, idx| {
                if (std.mem.eql(u8, param_name, named_arg.name)) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                if (bound[idx]) {
                    std.debug.print("Duplicate argument for parameter '{s}'\n", .{named_arg.name});
                    return error.InvalidArguments;
                }
                const arg_value = try self.evaluateExpression(named_arg.value, env);
                try closure_env.define(named_arg.name, arg_value);
                bound[idx] = true;
            } else {
                std.debug.print("Unknown parameter '{s}' for closure\n", .{named_arg.name});
                return error.InvalidArguments;
            }
        }

        // Check that all parameters are bound (closures don't have defaults)
        for (closure.param_names, 0..) |param_name, i| {
            if (!bound[i]) {
                std.debug.print("Missing required argument '{s}' for closure\n", .{param_name});
                return error.InvalidArguments;
            }
        }

        // Execute closure body
        if (closure.body_expr) |expr| {
            return try self.evaluateExpression(expr, &closure_env);
        } else if (closure.body_block) |block| {
            var closure_err: ?InterpreterError = null;
            for (block.statements) |stmt| {
                self.executeStatement(stmt, &closure_env) catch |err| {
                    closure_err = err;
                    break;
                };
            }

            const defers = closure_env.getDefers();
            var i: usize = defers.len;
            while (i > 0) {
                i -= 1;
                _ = self.evaluateExpression(defers[i], &closure_env) catch {};
            }

            if (closure_err) |err| {
                if (err == error.Return) {
                    return self.return_value orelse Value.Void;
                }
                return err;
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

        // upper() / to_upper() - convert to uppercase
        if (std.mem.eql(u8, method, "upper") or std.mem.eql(u8, method, "to_upper")) {
            const result = try allocator.alloc(u8, str.len);
            for (str, 0..) |c, i| {
                result[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
            }
            return Value{ .String = result };
        }

        // lower() / to_lower() - convert to lowercase
        if (std.mem.eql(u8, method, "lower") or std.mem.eql(u8, method, "to_lower")) {
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
    /// var_name is provided when the array comes from a variable (for in-place mutation)
    fn evaluateArrayMethod(self: *Interpreter, arr: []const Value, method: []const u8, args: []const *const ast.Expr, env: *Environment, var_name: ?[]const u8) InterpreterError!Value {
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

        // push(value) - returns new array with value appended (functional style, does not mutate)
        if (std.mem.eql(u8, method, "push")) {
            _ = var_name; // Not used - functional style
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

        // pop() - returns new array with last element removed (functional style, does not mutate)
        if (std.mem.eql(u8, method, "pop")) {
            _ = var_name; // Not used - functional style
            if (arr.len == 0) {
                return Value{ .Array = &.{} };
            }
            const new_arr = try self.arena.allocator().alloc(Value, arr.len - 1);
            @memcpy(new_arr, arr[0 .. arr.len - 1]);
            return Value{ .Array = new_arr };
        }

        // shift() - returns new array with first element removed (functional style, does not mutate)
        if (std.mem.eql(u8, method, "shift")) {
            _ = var_name; // Not used - functional style
            if (arr.len == 0) {
                return Value{ .Array = &.{} };
            }
            const new_arr = try self.arena.allocator().alloc(Value, arr.len - 1);
            @memcpy(new_arr, arr[1..]);
            return Value{ .Array = new_arr };
        }

        // unshift(value) - returns new array with value prepended (functional style, does not mutate)
        if (std.mem.eql(u8, method, "unshift")) {
            _ = var_name; // Not used - functional style
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

    /// Evaluate map/dictionary method calls
    fn evaluateMapMethod(self: *Interpreter, map: MapValue, method: []const u8, args: []const *const ast.Expr, env: *Environment, var_name: ?[]const u8) InterpreterError!Value {
        // len() / length() - returns map size
        if (std.mem.eql(u8, method, "len") or std.mem.eql(u8, method, "length")) {
            return Value{ .Int = @as(i64, @intCast(map.entries.count())) };
        }

        // is_empty() - check if map is empty
        if (std.mem.eql(u8, method, "is_empty")) {
            return Value{ .Bool = map.entries.count() == 0 };
        }

        // contains_key(key) - check if key exists
        if (std.mem.eql(u8, method, "contains_key")) {
            if (args.len != 1) {
                std.debug.print("contains_key() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const key_val = try self.evaluateExpression(args[0], env);
            const key_str = switch (key_val) {
                .String => |s| s,
                .Int => |i| blk: {
                    const buf = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{i});
                    break :blk buf;
                },
                else => {
                    std.debug.print("contains_key() argument must be a string or integer\n", .{});
                    return error.TypeMismatch;
                },
            };
            return Value{ .Bool = map.entries.contains(key_str) };
        }

        // get(key) - returns Some(value) or None
        if (std.mem.eql(u8, method, "get")) {
            if (args.len != 1) {
                std.debug.print("get() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const key_val = try self.evaluateExpression(args[0], env);
            const key_str = switch (key_val) {
                .String => |s| s,
                .Int => |i| blk: {
                    const buf = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{i});
                    break :blk buf;
                },
                else => {
                    std.debug.print("get() argument must be a string or integer\n", .{});
                    return error.TypeMismatch;
                },
            };
            if (map.entries.get(key_str)) |val| {
                // Return Some(value)
                var fields = std.StringHashMap(Value).init(self.arena.allocator());
                try fields.put("value", val);
                return Value{ .Struct = .{ .type_name = "Some", .fields = fields } };
            }
            // Return None
            const none_fields = std.StringHashMap(Value).init(self.arena.allocator());
            return Value{ .Struct = .{ .type_name = "None", .fields = none_fields } };
        }

        // remove(key) - removes key and returns Some(value) or None
        if (std.mem.eql(u8, method, "remove")) {
            if (args.len != 1) {
                std.debug.print("remove() requires exactly 1 argument\n", .{});
                return error.InvalidArguments;
            }
            const key_val = try self.evaluateExpression(args[0], env);
            const key_str = switch (key_val) {
                .String => |s| s,
                .Int => |i| blk: {
                    const buf = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{i});
                    break :blk buf;
                },
                else => {
                    std.debug.print("remove() argument must be a string or integer\n", .{});
                    return error.TypeMismatch;
                },
            };

            // Create new map without the key
            var new_entries = std.StringHashMap(Value).init(self.arena.allocator());
            var removed_value: ?Value = null;
            var iter = map.entries.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, key_str)) {
                    removed_value = entry.value_ptr.*;
                } else {
                    try new_entries.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }

            // Update variable if we have a name
            if (var_name) |name| {
                try env.set(name, Value{ .Map = .{ .entries = new_entries } });
            }

            if (removed_value) |val| {
                var fields = std.StringHashMap(Value).init(self.arena.allocator());
                try fields.put("value", val);
                return Value{ .Struct = .{ .type_name = "Some", .fields = fields } };
            }
            const none_fields = std.StringHashMap(Value).init(self.arena.allocator());
            return Value{ .Struct = .{ .type_name = "None", .fields = none_fields } };
        }

        // clear() - removes all entries
        if (std.mem.eql(u8, method, "clear")) {
            if (var_name) |name| {
                const new_entries = std.StringHashMap(Value).init(self.arena.allocator());
                try env.set(name, Value{ .Map = .{ .entries = new_entries } });
            }
            return Value.Void;
        }

        // keys() - returns array of keys
        if (std.mem.eql(u8, method, "keys")) {
            var keys_list = std.ArrayList(Value){ .items = &.{}, .capacity = 0 };
            var iter = map.entries.keyIterator();
            while (iter.next()) |key| {
                try keys_list.append(self.arena.allocator(), Value{ .String = key.* });
            }
            return Value{ .Array = try keys_list.toOwnedSlice(self.arena.allocator()) };
        }

        // values() - returns array of values
        if (std.mem.eql(u8, method, "values")) {
            var values_list = std.ArrayList(Value){ .items = &.{}, .capacity = 0 };
            var iter = map.entries.valueIterator();
            while (iter.next()) |val| {
                try values_list.append(self.arena.allocator(), val.*);
            }
            return Value{ .Array = try values_list.toOwnedSlice(self.arena.allocator()) };
        }

        // entries() - returns array of [key, value] pairs
        if (std.mem.eql(u8, method, "entries")) {
            var entries_list = std.ArrayList(Value){ .items = &.{}, .capacity = 0 };
            var iter = map.entries.iterator();
            while (iter.next()) |entry| {
                const pair = try self.arena.allocator().alloc(Value, 2);
                pair[0] = Value{ .String = entry.key_ptr.* };
                pair[1] = entry.value_ptr.*;
                try entries_list.append(self.arena.allocator(), Value{ .Array = pair });
            }
            return Value{ .Array = try entries_list.toOwnedSlice(self.arena.allocator()) };
        }

        std.debug.print("Unknown map method: {s}\n", .{method});
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
        return self.callUserFunctionWithNamed(func, args, &.{}, parent_env);
    }

    fn callUserFunctionWithNamed(self: *Interpreter, func: FunctionValue, args: []const *const ast.Expr, named_args: []const ast.NamedArg, parent_env: *Environment) InterpreterError!Value {
        // Create new environment for function scope
        var func_env = Environment.init(self.arena.allocator(), parent_env);
        defer func_env.deinit();

        // Track which parameters have been bound
        var bound = try self.arena.allocator().alloc(bool, func.params.len);
        for (bound) |*b| b.* = false;

        // First, bind positional arguments
        for (args, 0..) |arg, i| {
            if (i >= func.params.len) {
                std.debug.print("Too many positional arguments for function {s}\n", .{func.name});
                return error.InvalidArguments;
            }
            const arg_value = try self.evaluateExpression(arg, parent_env);
            try func_env.define(func.params[i].name, arg_value);
            bound[i] = true;
        }

        // Then, bind named arguments
        for (named_args) |named_arg| {
            // Find the parameter index by name
            var found_idx: ?usize = null;
            for (func.params, 0..) |param, idx| {
                if (std.mem.eql(u8, param.name, named_arg.name)) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                if (bound[idx]) {
                    std.debug.print("Duplicate argument for parameter '{s}'\n", .{named_arg.name});
                    return error.InvalidArguments;
                }
                const arg_value = try self.evaluateExpression(named_arg.value, parent_env);
                try func_env.define(named_arg.name, arg_value);
                bound[idx] = true;
            } else {
                std.debug.print("Unknown parameter '{s}' for function {s}\n", .{ named_arg.name, func.name });
                return error.InvalidArguments;
            }
        }

        // Finally, fill in defaults for any unbound parameters
        for (func.params, 0..) |param, i| {
            if (!bound[i]) {
                if (param.default_value) |default| {
                    const default_value = try self.evaluateExpression(default, parent_env);
                    try func_env.define(param.name, default_value);
                } else {
                    std.debug.print("Missing required argument '{s}' for function {s}\n", .{ param.name, func.name });
                    return error.InvalidArguments;
                }
            }
        }

        // Execute function body
        var func_err: ?InterpreterError = null;
        for (func.body.statements) |stmt| {
            self.executeStatement(stmt, &func_env) catch |err| {
                func_err = err;
                break;
            };
        }

        // Execute defers in reverse order before returning
        const defers = func_env.getDefers();
        var i: usize = defers.len;
        while (i > 0) {
            i -= 1;
            _ = self.evaluateExpression(defers[i], &func_env) catch {};
        }

        // Handle return or error
        if (func_err) |err| {
            if (err == error.Return) {
                // Return statement was executed
                const ret_value = self.return_value.?;
                self.return_value = null;
                return ret_value;
            }
            return err;
        }

        // No explicit return, return void
        return Value.Void;
    }

    /// Call an impl method with self binding
    fn callImplMethod(self: *Interpreter, method: *ast.FnDecl, self_value: Value, args: []const *const ast.Expr, parent_env: *Environment) InterpreterError!Value {
        // Check if method has 'self' parameter (first param named "self")
        const has_self_param = method.params.len > 0 and std.mem.eql(u8, method.params[0].name, "self");

        // Calculate actual parameters (excluding self)
        const actual_params = if (has_self_param) method.params[1..] else method.params;

        // Count required parameters (those without default values)
        var required_params: usize = 0;
        for (actual_params) |param| {
            if (param.default_value == null) {
                required_params += 1;
            }
        }

        // Check argument count
        if (args.len < required_params or args.len > actual_params.len) {
            if (required_params == actual_params.len) {
                std.debug.print("Method {s} expects {d} arguments, got {d}\n", .{ method.name, actual_params.len, args.len });
            } else {
                std.debug.print("Method {s} expects {d}-{d} arguments, got {d}\n", .{ method.name, required_params, actual_params.len, args.len });
            }
            return error.InvalidArguments;
        }

        // Create new environment for method scope
        var method_env = Environment.init(self.arena.allocator(), parent_env);
        defer method_env.deinit();

        // Bind self to the struct value
        if (has_self_param) {
            try method_env.define("self", self_value);
        }

        // Bind parameters to arguments (with default value support)
        for (actual_params, 0..) |param, i| {
            const arg_value = if (i < args.len)
                try self.evaluateExpression(args[i], parent_env)
            else if (param.default_value) |default|
                try self.evaluateExpression(default, parent_env)
            else
                return error.InvalidArguments;
            try method_env.define(param.name, arg_value);
        }

        // Execute method body
        var method_err: ?InterpreterError = null;
        for (method.body.statements) |stmt| {
            self.executeStatement(stmt, &method_env) catch |err| {
                method_err = err;
                break;
            };
        }

        // Execute defers in reverse order before returning
        const defers = method_env.getDefers();
        var i: usize = defers.len;
        while (i > 0) {
            i -= 1;
            _ = self.evaluateExpression(defers[i], &method_env) catch {};
        }

        // Handle return or error
        if (method_err) |err| {
            if (err == error.Return) {
                // Return statement was executed
                const ret_value = self.return_value.?;
                self.return_value = null;
                return ret_value;
            }
            return err;
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
            .Reference => |r| std.debug.print("&{s}", .{r.var_name}),
            .Future => |f| {
                if (f.is_resolved) {
                    std.debug.print("<resolved future>", .{});
                } else {
                    std.debug.print("<pending future>", .{});
                }
            },
            .Map => |m| {
                std.debug.print("{{", .{});
                var iter = m.entries.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) std.debug.print(", ", .{});
                    first = false;
                    std.debug.print("\"{s}\": {any}", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
                std.debug.print("}}", .{});
            },
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
            .Reference => |r| std.debug.print("Reference(&{s})", .{r.var_name}),
            .Future => |f| {
                if (f.is_resolved) {
                    std.debug.print("Future(resolved)", .{});
                } else {
                    std.debug.print("Future(pending)", .{});
                }
            },
            .Map => |m| std.debug.print("Map({d} entries)", .{m.entries.count()}),
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
                .Reference => |r| std.debug.print("&{s}", .{r.var_name}),
                .Future => |f| {
                    if (f.is_resolved) {
                        std.debug.print("<resolved future>", .{});
                    } else {
                        std.debug.print("<pending future>", .{});
                    }
                },
                .Map => |m| {
                    std.debug.print("{{", .{});
                    var iter = m.entries.iterator();
                    var first = true;
                    while (iter.next()) |entry| {
                        if (!first) std.debug.print(", ", .{});
                        first = false;
                        std.debug.print("\"{s}\": {any}", .{ entry.key_ptr.*, entry.value_ptr.* });
                    }
                    std.debug.print("}}", .{});
                },
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

    /// Apply checked arithmetic that returns Option (Some/None)
    fn applyCheckedArithmetic(self: *Interpreter, left: Value, right: Value, op: ast.BinaryOp) InterpreterError!Value {
        if (left != .Int or right != .Int) {
            std.debug.print("Checked arithmetic requires integer operands\n", .{});
            return error.TypeMismatch;
        }

        const l = left.Int;
        const r = right.Int;

        // Perform checked arithmetic and return Some(result) or None
        const result_opt: ?i64 = switch (op) {
            .SaturatingAdd => std.math.add(i64, l, r) catch null,
            .SaturatingSub => std.math.sub(i64, l, r) catch null,
            .SaturatingMul => std.math.mul(i64, l, r) catch null,
            .SaturatingDiv => if (r == 0) null else @divTrunc(l, r),
            else => null,
        };

        if (result_opt) |result| {
            // Return Some(value) as a struct
            var fields = std.StringHashMap(Value).init(self.arena.allocator());
            fields.put("value", Value{ .Int = result }) catch {
                return error.RuntimeError;
            };
            return Value{ .Struct = value_mod.StructValue{
                .type_name = "Some",
                .fields = fields,
            } };
        } else {
            // Return None (represented as Void)
            return Value.Void;
        }
    }

    /// Apply clamping/saturating arithmetic (clamps to i64 bounds)
    fn applyClampingArithmetic(self: *Interpreter, left: Value, right: Value, op: ast.BinaryOp) InterpreterError!Value {
        _ = self;
        if (left != .Int or right != .Int) {
            std.debug.print("Clamping arithmetic requires integer operands\n", .{});
            return error.TypeMismatch;
        }

        const l = left.Int;
        const r = right.Int;

        // Perform saturating arithmetic (clamp to bounds on overflow)
        const result: i64 = switch (op) {
            .ClampAdd => std.math.add(i64, l, r) catch if (l > 0) std.math.maxInt(i64) else std.math.minInt(i64),
            .ClampSub => std.math.sub(i64, l, r) catch if (l > 0) std.math.maxInt(i64) else std.math.minInt(i64),
            .ClampMul => std.math.mul(i64, l, r) catch if ((l > 0) == (r > 0)) std.math.maxInt(i64) else std.math.minInt(i64),
            else => l,
        };

        return Value{ .Int = result };
    }

    /// Apply panic-on-overflow arithmetic
    fn applyPanicArithmetic(self: *Interpreter, left: Value, right: Value, op: ast.BinaryOp) InterpreterError!Value {
        _ = self;
        if (left != .Int or right != .Int) {
            std.debug.print("Panic arithmetic requires integer operands\n", .{});
            return error.TypeMismatch;
        }

        const l = left.Int;
        const r = right.Int;

        // Perform checked arithmetic, panic on overflow
        const result: i64 = switch (op) {
            .CheckedAdd => std.math.add(i64, l, r) catch {
                std.debug.print("Integer overflow in checked addition\n", .{});
                return error.RuntimeError;
            },
            .CheckedSub => std.math.sub(i64, l, r) catch {
                std.debug.print("Integer overflow in checked subtraction\n", .{});
                return error.RuntimeError;
            },
            .CheckedMul => std.math.mul(i64, l, r) catch {
                std.debug.print("Integer overflow in checked multiplication\n", .{});
                return error.RuntimeError;
            },
            .CheckedDiv => if (r == 0) {
                std.debug.print("Division by zero in checked division\n", .{});
                return error.RuntimeError;
            } else @divTrunc(l, r),
            else => l,
        };

        return Value{ .Int = result };
    }

    fn areEqual(self: *Interpreter, left: Value, right: Value) InterpreterError!bool {
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
            .Array => |l_arr| switch (right) {
                .Array => |r_arr| {
                    if (l_arr.len != r_arr.len) return false;
                    for (l_arr, r_arr) |l_elem, r_elem| {
                        if (!try self.areEqual(l_elem, r_elem)) return false;
                    }
                    return true;
                },
                else => return false,
            },
            .Struct => |l| switch (right) {
                .Struct => |r| {
                    // Compare type names first
                    if (!std.mem.eql(u8, l.type_name, r.type_name)) return false;
                    // Compare field counts
                    if (l.fields.count() != r.fields.count()) return false;
                    // Compare each field
                    var iter = l.fields.iterator();
                    while (iter.next()) |entry| {
                        const r_val = r.fields.get(entry.key_ptr.*) orelse return false;
                        if (!try self.areEqual(entry.value_ptr.*, r_val)) return false;
                    }
                    return true;
                },
                else => return false,
            },
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
            .Reference => return false, // References are not directly comparable
            .Future => return false, // Futures are not directly comparable
            .Map => return false, // Maps are not directly comparable
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
            .Reference => |r| blk: {
                const str = try std.fmt.allocPrint(self.arena.allocator(), "&{s}", .{r.var_name});
                break :blk str;
            },
            .Future => |f| blk: {
                const str = if (f.is_resolved)
                    try std.fmt.allocPrint(self.arena.allocator(), "<resolved future>", .{})
                else
                    try std.fmt.allocPrint(self.arena.allocator(), "<pending future>", .{});
                break :blk str;
            },
            .Map => |m| blk: {
                var buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
                defer buf.deinit(self.arena.allocator());
                try buf.appendSlice(self.arena.allocator(), "{");
                var iter = m.entries.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try buf.appendSlice(self.arena.allocator(), ", ");
                    first = false;
                    try buf.appendSlice(self.arena.allocator(), "\"");
                    try buf.appendSlice(self.arena.allocator(), entry.key_ptr.*);
                    try buf.appendSlice(self.arena.allocator(), "\": ");
                    const val_str = try self.valueToString(entry.value_ptr.*);
                    try buf.appendSlice(self.arena.allocator(), val_str);
                }
                try buf.appendSlice(self.arena.allocator(), "}");
                break :blk try self.arena.allocator().dupe(u8, buf.items);
            },
        };
    }

    /// Process escape sequences in a string literal
    /// Converts \n, \t, \r, \\, \", \', \0, \xNN to their actual character values
    fn processStringEscapes(self: *Interpreter, input: []const u8) InterpreterError![]const u8 {
        // Quick check: if no backslashes, return as-is
        var has_escape = false;
        for (input) |c| {
            if (c == '\\') {
                has_escape = true;
                break;
            }
        }
        if (!has_escape) {
            return input;
        }

        var result = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '\\' and i + 1 < input.len) {
                const escape_char = input[i + 1];
                switch (escape_char) {
                    'n' => {
                        try result.append(self.arena.allocator(), '\n');
                        i += 2;
                    },
                    't' => {
                        try result.append(self.arena.allocator(), '\t');
                        i += 2;
                    },
                    'r' => {
                        try result.append(self.arena.allocator(), '\r');
                        i += 2;
                    },
                    '\\' => {
                        try result.append(self.arena.allocator(), '\\');
                        i += 2;
                    },
                    '"' => {
                        try result.append(self.arena.allocator(), '"');
                        i += 2;
                    },
                    '\'' => {
                        try result.append(self.arena.allocator(), '\'');
                        i += 2;
                    },
                    '0' => {
                        try result.append(self.arena.allocator(), 0);
                        i += 2;
                    },
                    'x' => {
                        // Hex escape \xNN
                        if (i + 3 < input.len) {
                            const hex_str = input[i + 2 .. i + 4];
                            const hex_val = std.fmt.parseInt(u8, hex_str, 16) catch {
                                // Invalid hex, just copy literal
                                try result.append(self.arena.allocator(), '\\');
                                i += 1;
                                continue;
                            };
                            try result.append(self.arena.allocator(), hex_val);
                            i += 4;
                        } else {
                            try result.append(self.arena.allocator(), '\\');
                            i += 1;
                        }
                    },
                    else => {
                        // Unknown escape, keep the backslash and character
                        try result.append(self.arena.allocator(), '\\');
                        try result.append(self.arena.allocator(), escape_char);
                        i += 2;
                    },
                }
            } else {
                try result.append(self.arena.allocator(), input[i]);
                i += 1;
            }
        }
        return try self.arena.allocator().dupe(u8, result.items);
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
