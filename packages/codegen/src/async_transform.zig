const std = @import("std");
const ast = @import("ast");

/// Async function state machine transformer
///
/// Transforms async functions into state machines that can be polled.
///
/// Example transformation:
/// ```
/// async fn foo() -> i32 {
///     let x = await bar();
///     let y = await baz(x);
///     return x + y;
/// }
/// ```
///
/// Becomes:
/// ```
/// struct FooStateMachine {
///     state: enum { Start, AwaitBar, AwaitBaz, Done },
///     x: ?i32,
///     y: ?i32,
///     bar_future: ?Future(i32),
///     baz_future: ?Future(i32),
///
///     fn poll(self: *@This(), ctx: *Context) PollResult(i32) {
///         switch (self.state) {
///             .Start => {
///                 self.bar_future = bar();
///                 self.state = .AwaitBar;
///                 // fallthrough to AwaitBar
///             },
///             .AwaitBar => {
///                 switch (self.bar_future.poll(ctx)) {
///                     .Ready => |val| {
///                         self.x = val;
///                         self.baz_future = baz(val);
///                         self.state = .AwaitBaz;
///                     },
///                     .Pending => return .Pending,
///                 }
///             },
///             .AwaitBaz => {
///                 switch (self.baz_future.poll(ctx)) {
///                     .Ready => |val| {
///                         self.y = val;
///                         self.state = .Done;
///                         return .{ .Ready = self.x.? + self.y.? };
///                     },
///                     .Pending => return .Pending,
///                 }
///             },
///             .Done => unreachable,
///         }
///     }
/// }
/// ```
pub const AsyncTransform = struct {
    allocator: std.mem.Allocator,
    /// Current function being transformed
    current_function: ?*ast.FnDecl,
    /// Await points found in the function
    await_points: std.ArrayList(AwaitPoint),
    /// Local variables that need to be preserved across await points
    captured_locals: std.ArrayList(LocalVariable),
    /// Next state ID
    next_state_id: usize,

    const AwaitPoint = struct {
        /// Expression being awaited
        expr: *ast.Expr,
        /// State to transition to
        state_id: usize,
        /// Location in source
        location: ast.SourceLocation,
        /// Variables live at this point
        live_vars: [][]const u8,
    };

    const LocalVariable = struct {
        name: []const u8,
        type_name: ?[]const u8,
        /// Is this variable live across an await?
        crosses_await: bool,
    };

    pub fn init(allocator: std.mem.Allocator) AsyncTransform {
        return .{
            .allocator = allocator,
            .current_function = null,
            .await_points = std.ArrayList(AwaitPoint).init(allocator),
            .captured_locals = std.ArrayList(LocalVariable).init(allocator),
            .next_state_id = 0,
        };
    }

    pub fn deinit(self: *AsyncTransform) void {
        for (self.await_points.items) |*point| {
            self.allocator.free(point.live_vars);
        }
        self.await_points.deinit();
        self.captured_locals.deinit();
    }

    /// Transform an async function into a state machine
    pub fn transformAsyncFunction(
        self: *AsyncTransform,
        fn_decl: *ast.FnDecl,
    ) !StateMachine {
        if (!fn_decl.is_async) {
            return error.NotAsyncFunction;
        }

        self.current_function = fn_decl;
        self.next_state_id = 0;

        // Clear previous state
        self.await_points.clearRetainingCapacity();
        self.captured_locals.clearRetainingCapacity();

        // Step 1: Find all await points
        try self.findAwaitPoints(&fn_decl.body);

        // Step 2: Analyze variable lifetimes
        try self.analyzeVariableLifetimes(&fn_decl.body);

        // Step 3: Generate state enum
        const state_enum = try self.generateStateEnum();

        // Step 4: Generate state machine struct
        const state_machine = try self.generateStateMachine(fn_decl, state_enum);

        return state_machine;
    }

    /// Find all await expressions in the function body
    fn findAwaitPoints(self: *AsyncTransform, block: *const ast.BlockStmt) !void {
        for (block.statements) |stmt| {
            try self.findAwaitInStatement(stmt);
        }
    }

    fn findAwaitInStatement(self: *AsyncTransform, stmt: ast.Stmt) !void {
        switch (stmt) {
            .LetDecl => |let_decl| {
                if (let_decl.initializer) |init| {
                    const expr = @as(*const ast.Expr, @ptrCast(init));
                    try self.findAwaitInExpr(expr);
                }
            },
            .ExprStmt => |expr_stmt| {
                const expr = @as(*const ast.Expr, @ptrCast(&expr_stmt.expression));
                try self.findAwaitInExpr(expr);
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    const expr = @as(*const ast.Expr, @ptrCast(val));
                    try self.findAwaitInExpr(expr);
                }
            },
            .IfStmt => |if_stmt| {
                const cond_expr = @as(*const ast.Expr, @ptrCast(&if_stmt.condition));
                try self.findAwaitInExpr(cond_expr);
                try self.findAwaitPoints(if_stmt.then_block);
                if (if_stmt.else_block) |else_block| {
                    try self.findAwaitPoints(else_block);
                }
            },
            .WhileStmt => |while_stmt| {
                const cond_expr = @as(*const ast.Expr, @ptrCast(&while_stmt.condition));
                try self.findAwaitInExpr(cond_expr);
                try self.findAwaitPoints(while_stmt.body);
            },
            .ForStmt => |for_stmt| {
                const iter_expr = @as(*const ast.Expr, @ptrCast(&for_stmt.iterable));
                try self.findAwaitInExpr(iter_expr);
                try self.findAwaitPoints(for_stmt.body);
            },
            else => {},
        }
    }

    fn findAwaitInExpr(self: *AsyncTransform, expr: *const ast.Expr) error{OutOfMemory}!void {
        switch (expr.*) {
            .AwaitExpr => |await_expr| {
                const state_id = self.next_state_id;
                self.next_state_id += 1;

                // Perform liveness analysis for variables at this await point
                const live_vars = try self.computeLiveVariables(expr);

                try self.await_points.append(.{
                    .expr = await_expr.expression,
                    .state_id = state_id,
                    .location = await_expr.node.loc,
                    .live_vars = live_vars,
                });

                // Recursively check the awaited expression
                try self.findAwaitInExpr(await_expr.expression);
            },
            .TryExpr => |try_expr| {
                // Handle ? operator with async (await expr?)
                // This creates an await point with error propagation
                try self.findAwaitInExpr(try_expr.operand);
            },
            .BinaryExpr => |bin| {
                try self.findAwaitInExpr(bin.left);
                try self.findAwaitInExpr(bin.right);
            },
            .UnaryExpr => |un| {
                try self.findAwaitInExpr(un.operand);
            },
            .CallExpr => |call| {
                try self.findAwaitInExpr(call.callee);
                for (call.arguments) |arg| {
                    try self.findAwaitInExpr(arg);
                }
            },
            .TernaryExpr => |tern| {
                try self.findAwaitInExpr(tern.condition);
                try self.findAwaitInExpr(tern.then_expr);
                try self.findAwaitInExpr(tern.else_expr);
            },
            else => {},
        }
    }

    /// Compute which variables are live at a given await point
    fn computeLiveVariables(self: *AsyncTransform, await_expr: *const ast.Expr) ![][]const u8 {
        // Track variables that are:
        // 1. Defined before this await point
        // 2. Used after this await point

        var live_vars = std.ArrayList([]const u8).init(self.allocator);
        errdefer live_vars.deinit();

        // For each captured local, check if it's used after this point
        for (self.captured_locals.items) |local| {
            if (local.crosses_await) {
                // Check if this variable is referenced in expressions after the await
                if (try self.isVariableUsedAfterAwait(local.name, await_expr)) {
                    try live_vars.append(try self.allocator.dupe(u8, local.name));
                }
            }
        }

        return try live_vars.toOwnedSlice();
    }

    /// Check if a variable is referenced after an await point
    fn isVariableUsedAfterAwait(self: *AsyncTransform, var_name: []const u8, await_expr: *const ast.Expr) !bool {
        _ = self;
        _ = await_expr;

        // This is a simplified version - in a full implementation, we would:
        // 1. Walk the AST forward from the await point
        // 2. Track variable uses (reads) and kills (writes/scopes)
        // 3. Determine if the variable is live

        // For now, we conservatively assume any captured variable is live
        // A variable that crosses an await boundary is likely used after

        // Check if the variable name appears in any remaining statements
        if (self.current_function) |func| {
            return self.variableUsedInBlock(&func.body, var_name);
        }

        return false;
    }

    /// Check if a variable is used anywhere in a block
    fn variableUsedInBlock(self: *AsyncTransform, block: *const ast.BlockStmt, var_name: []const u8) bool {
        for (block.statements) |stmt| {
            if (self.variableUsedInStmt(&stmt, var_name)) {
                return true;
            }
        }
        return false;
    }

    /// Check if a variable is used in a statement
    fn variableUsedInStmt(self: *AsyncTransform, stmt: *const ast.Stmt, var_name: []const u8) bool {
        switch (stmt.*) {
            .ExprStmt => |expr_stmt| return self.variableUsedInExpr(expr_stmt, var_name),
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.expression) |expr| {
                    return self.variableUsedInExpr(expr, var_name);
                }
                return false;
            },
            .IfStmt => |if_stmt| {
                if (self.variableUsedInExpr(if_stmt.condition, var_name)) return true;
                if (self.variableUsedInBlock(&if_stmt.then_block, var_name)) return true;
                if (if_stmt.else_block) |else_block| {
                    if (self.variableUsedInBlock(&else_block, var_name)) return true;
                }
                return false;
            },
            .WhileStmt => |while_stmt| {
                if (self.variableUsedInExpr(while_stmt.condition, var_name)) return true;
                return self.variableUsedInBlock(&while_stmt.body, var_name);
            },
            .ForStmt => |for_stmt| {
                if (self.variableUsedInExpr(for_stmt.iterable, var_name)) return true;
                return self.variableUsedInBlock(&for_stmt.body, var_name);
            },
            .LetDecl => |let_decl| {
                if (let_decl.initializer) |init| {
                    return self.variableUsedInExpr(init, var_name);
                }
                return false;
            },
            .AssignmentStmt => |assign| {
                if (self.variableUsedInExpr(assign.target, var_name)) return true;
                return self.variableUsedInExpr(assign.value, var_name);
            },
            .MatchStmt => |match_stmt| {
                if (self.variableUsedInExpr(match_stmt.expr, var_name)) return true;
                for (match_stmt.arms) |arm| {
                    if (self.variableUsedInBlock(&arm.body, var_name)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Check if a variable is used in an expression
    fn variableUsedInExpr(self: *AsyncTransform, expr: *const ast.Expr, var_name: []const u8) bool {
        switch (expr.*) {
            .Identifier => |id| {
                return std.mem.eql(u8, id.name, var_name);
            },
            .BinaryExpr => |bin| {
                return self.variableUsedInExpr(bin.left, var_name) or
                    self.variableUsedInExpr(bin.right, var_name);
            },
            .UnaryExpr => |un| {
                return self.variableUsedInExpr(un.operand, var_name);
            },
            .CallExpr => |call| {
                if (self.variableUsedInExpr(call.callee, var_name)) return true;
                for (call.arguments) |arg| {
                    if (self.variableUsedInExpr(arg, var_name)) return true;
                }
                return false;
            },
            .MemberExpr => |member| {
                return self.variableUsedInExpr(member.object, var_name);
            },
            .IndexExpr => |index| {
                return self.variableUsedInExpr(index.array, var_name) or
                    self.variableUsedInExpr(index.index, var_name);
            },
            .TernaryExpr => |tern| {
                return self.variableUsedInExpr(tern.condition, var_name) or
                    self.variableUsedInExpr(tern.then_expr, var_name) or
                    self.variableUsedInExpr(tern.else_expr, var_name);
            },
            .AwaitExpr => |await_expr| {
                return self.variableUsedInExpr(await_expr.expression, var_name);
            },
            .TryExpr => |try_expr| {
                return self.variableUsedInExpr(try_expr.operand, var_name);
            },
            .ArrayLiteral => |arr| {
                for (arr.elements) |elem| {
                    if (self.variableUsedInExpr(elem, var_name)) return true;
                }
                return false;
            },
            .StructLiteral => |struct_lit| {
                for (struct_lit.fields) |field| {
                    if (self.variableUsedInExpr(field.value, var_name)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Analyze which variables are live across await points
    fn analyzeVariableLifetimes(self: *AsyncTransform, block: *const ast.BlockStmt) !void {
        // Simplified liveness analysis
        // In production, this would use dataflow analysis

        for (block.statements) |stmt| {
            if (stmt == .LetDecl) {
                const let_decl = stmt.LetDecl;

                // Check if this variable is used after any await point
                const crosses_await = self.await_points.items.len > 0;

                try self.captured_locals.append(.{
                    .name = let_decl.name,
                    .type_name = let_decl.type_annotation,
                    .crosses_await = crosses_await,
                });
            }
        }
    }

    /// Generate state enum for the state machine
    fn generateStateEnum(self: *AsyncTransform) !StateEnum {
        var states = std.ArrayList([]const u8).init(self.allocator);
        errdefer states.deinit();

        // Start state
        try states.append("Start");

        // One state per await point
        for (self.await_points.items, 0..) |_, i| {
            const state_name = try std.fmt.allocPrint(
                self.allocator,
                "Await{d}",
                .{i},
            );
            try states.append(state_name);
        }

        // Done state
        try states.append("Done");

        return StateEnum{
            .states = try states.toOwnedSlice(),
        };
    }

    /// Generate the state machine struct
    fn generateStateMachine(
        self: *AsyncTransform,
        fn_decl: *ast.FnDecl,
        state_enum: StateEnum,
    ) !StateMachine {
        return StateMachine{
            .name = try std.fmt.allocPrint(
                self.allocator,
                "{s}StateMachine",
                .{fn_decl.name},
            ),
            .return_type = fn_decl.return_type orelse "void",
            .state_enum = state_enum,
            .fields = try self.generateFields(),
            .await_points = try self.await_points.toOwnedSlice(),
            .captured_locals = try self.captured_locals.toOwnedSlice(),
        };
    }

    fn generateFields(self: *AsyncTransform) ![]Field {
        var fields = std.ArrayList(Field).init(self.allocator);
        errdefer fields.deinit();

        // State field
        try fields.append(.{
            .name = "state",
            .type_name = "State",
        });

        // Add fields for captured locals
        for (self.captured_locals.items) |local| {
            if (local.crosses_await) {
                const field_type = if (local.type_name) |t|
                    try std.fmt.allocPrint(self.allocator, "?{s}", .{t})
                else
                    "?anyopaque";

                try fields.append(.{
                    .name = local.name,
                    .type_name = field_type,
                });
            }
        }

        // Add future fields for each await point
        for (self.await_points.items, 0..) |_, i| {
            const field_name = try std.fmt.allocPrint(
                self.allocator,
                "future_{d}",
                .{i},
            );

            try fields.append(.{
                .name = field_name,
                .type_name = "?*anyopaque", // Type-erased future
            });
        }

        return fields.toOwnedSlice();
    }
};

pub const StateEnum = struct {
    states: [][]const u8,

    pub fn deinit(self: *StateEnum, allocator: std.mem.Allocator) void {
        for (self.states) |state| {
            allocator.free(state);
        }
        allocator.free(self.states);
    }
};

pub const Field = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const StateMachine = struct {
    name: []const u8,
    return_type: []const u8,
    state_enum: StateEnum,
    fields: []Field,
    await_points: []AsyncTransform.AwaitPoint,
    captured_locals: []AsyncTransform.LocalVariable,

    pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.state_enum.deinit(allocator);

        for (self.fields) |field| {
            allocator.free(field.name);
            allocator.free(field.type_name);
        }
        allocator.free(self.fields);

        for (self.await_points) |*point| {
            allocator.free(point.live_vars);
        }
        allocator.free(self.await_points);
        allocator.free(self.captured_locals);
    }

    /// Generate Zig code for this state machine
    pub fn generateCode(self: *StateMachine, allocator: std.mem.Allocator) ![]const u8 {
        var code = std.ArrayList(u8).init(allocator);
        errdefer code.deinit();

        const writer = code.writer();

        // Struct definition
        try writer.print("const {s} = struct {{\n", .{self.name});
        try writer.writeAll("    const Self = @This();\n\n");

        // State enum
        try writer.writeAll("    const State = enum {\n");
        for (self.state_enum.states) |state| {
            try writer.print("        {s},\n", .{state});
        }
        try writer.writeAll("    };\n\n");

        // Fields
        for (self.fields) |field| {
            try writer.print("    {s}: {s},\n", .{ field.name, field.type_name });
        }

        try writer.writeAll("\n");

        // Poll function
        try writer.print(
            "    pub fn poll(self: *Self, ctx: *Context) PollResult({s}) {{\n",
            .{self.return_type},
        );
        try writer.writeAll("        while (true) {\n");
        try writer.writeAll("            switch (self.state) {\n");

        // Generate cases for each state
        try writer.writeAll("                .Start => {\n");
        if (self.await_points.len > 0) {
            try writer.writeAll("                    // Initialize first await\n");
            try writer.writeAll("                    self.state = .Await0;\n");
        } else {
            try writer.writeAll("                    self.state = .Done;\n");
            try writer.print("                    return .{{ .Ready = undefined }};\n", .{});
        }
        try writer.writeAll("                },\n");

        for (self.await_points, 0..) |point, i| {
            try writer.print("                .Await{d} => {{\n", .{i});

            // Generate future initialization if not already done
            try writer.print("                    // Poll future_{d}\n", .{i});
            try writer.print("                    if (self.future_{d} == null) {{\n", .{i});
            try writer.writeAll("                        // Initialize the future for this await point\n");
            // In a real implementation, we would evaluate the expression here
            // For now, we assume the future is already initialized
            try writer.writeAll("                        // self.future_N = expression_to_future();\n");
            try writer.writeAll("                    }\n");

            // Poll the future
            try writer.print("                    if (self.future_{d}) |future| {{\n", .{i});
            try writer.writeAll("                        switch (future.poll(ctx)) {\n");
            try writer.writeAll("                            .Ready => |value| {\n");

            // Store result in a captured local if needed
            if (point.live_vars.len > 0) {
                // Assume first live var is the result destination
                try writer.print("                                self.{s} = value;\n", .{point.live_vars[0]});
            }

            // Transition to next state
            if (i + 1 < self.await_points.len) {
                try writer.print("                                self.state = .Await{d};\n", .{i + 1});
                try writer.writeAll("                                // Continue to next state\n");
            } else {
                try writer.writeAll("                                self.state = .Done;\n");
                try writer.writeAll("                                return .{ .Ready = value };\n");
            }
            try writer.writeAll("                            },\n");
            try writer.writeAll("                            .Pending => return .Pending,\n");
            try writer.writeAll("                        }\n");
            try writer.writeAll("                    } else {\n");
            try writer.writeAll("                        // Future not initialized, error\n");
            try writer.writeAll("                        unreachable;\n");
            try writer.writeAll("                    }\n");
            try writer.writeAll("                },\n");
        }

        try writer.writeAll("                .Done => unreachable,\n");
        try writer.writeAll("            }\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("    }\n");

        try writer.writeAll("};\n");

        return code.toOwnedSlice();
    }
};

// =================================================================================
//                                    TESTS
// =================================================================================

test "AsyncTransform - simple async function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // This test would require setting up a complete AST
    // For now, just test initialization
    var transform = AsyncTransform.init(allocator);
    defer transform.deinit();

    try testing.expect(transform.await_points.items.len == 0);
    try testing.expect(transform.captured_locals.items.len == 0);
}

test "StateMachine - code generation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state_enum = StateEnum{
        .states = &[_][]const u8{ "Start", "Await0", "Done" },
    };

    var state_machine = StateMachine{
        .name = "TestStateMachine",
        .return_type = "i32",
        .state_enum = state_enum,
        .fields = &[_]Field{
            .{ .name = "state", .type_name = "State" },
        },
        .await_points = &[_]AsyncTransform.AwaitPoint{},
        .captured_locals = &[_]AsyncTransform.LocalVariable{},
    };

    const code = try state_machine.generateCode(allocator);
    defer allocator.free(code);

    // Verify code contains expected elements
    try testing.expect(std.mem.indexOf(u8, code, "TestStateMachine") != null);
    try testing.expect(std.mem.indexOf(u8, code, "State = enum") != null);
    try testing.expect(std.mem.indexOf(u8, code, "pub fn poll") != null);
}
