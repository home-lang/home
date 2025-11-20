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

                // TODO: Proper liveness analysis
                const live_vars = try self.allocator.alloc([]const u8, 0);

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

        for (self.await_points, 0..) |_, i| {
            try writer.print("                .Await{d} => {{\n", .{i});
            try writer.writeAll("                    // Poll future\n");
            try writer.writeAll("                    // TODO: actual poll logic\n");
            if (i + 1 < self.await_points.len) {
                try writer.print("                    self.state = .Await{d};\n", .{i + 1});
            } else {
                try writer.writeAll("                    self.state = .Done;\n");
            }
            try writer.writeAll("                    return .Pending;\n");
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
