const std = @import("std");
const ast = @import("../ast/ast.zig");
const interpreter = @import("../interpreter/interpreter.zig");
const types = @import("../types/type_system.zig");

/// Compile-time execution context
pub const ComptimeContext = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap(ComptimeValue),
    types_evaluated: std.StringHashMap(types.Type),
    file_system_access: bool,
    network_access: bool,
    errors: std.ArrayList(ComptimeError),

    pub fn init(allocator: std.mem.Allocator) ComptimeContext {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap(ComptimeValue).init(allocator),
            .types_evaluated = std.StringHashMap(types.Type).init(allocator),
            .file_system_access = true, // Allow filesystem access at compile time
            .network_access = false, // Disallow network by default for security
            .errors = std.ArrayList(ComptimeError).init(allocator),
        };
    }

    pub fn deinit(self: *ComptimeContext) void {
        var value_iter = self.values.iterator();
        while (value_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.values.deinit();
        self.types_evaluated.deinit();
        self.errors.deinit();
    }

    /// Store a compile-time value
    pub fn setValue(self: *ComptimeContext, name: []const u8, value: ComptimeValue) !void {
        try self.values.put(name, value);
    }

    /// Get a compile-time value
    pub fn getValue(self: *ComptimeContext, name: []const u8) ?ComptimeValue {
        return self.values.get(name);
    }

    /// Evaluate a type at compile time
    pub fn evaluateType(self: *ComptimeContext, name: []const u8, typ: types.Type) !void {
        try self.types_evaluated.put(name, typ);
    }

    fn addError(self: *ComptimeContext, err: ComptimeError) !void {
        try self.errors.append(err);
    }
};

/// Values that can be known at compile time
pub const ComptimeValue = union(enum) {
    Int: i64,
    Float: f64,
    Bool: bool,
    String: []const u8,
    Array: []ComptimeValue,
    Struct: std.StringHashMap(ComptimeValue),
    Function: *ast.FunctionDecl,
    Type: types.Type,
    Null: void,

    pub fn deinit(self: *ComptimeValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Array => |arr| allocator.free(arr),
            .Struct => |*map| map.deinit(),
            else => {},
        }
    }
};

/// Compile-time executor
pub const ComptimeExecutor = struct {
    allocator: std.mem.Allocator,
    context: *ComptimeContext,
    interpreter_instance: ?*interpreter.Interpreter,

    pub fn init(allocator: std.mem.Allocator, context: *ComptimeContext) ComptimeExecutor {
        return .{
            .allocator = allocator,
            .context = context,
            .interpreter_instance = null,
        };
    }

    pub fn deinit(self: *ComptimeExecutor) void {
        if (self.interpreter_instance) |interp| {
            interp.deinit();
            self.allocator.destroy(interp);
        }
    }

    /// Execute an expression at compile time
    pub fn execute(self: *ComptimeExecutor, expr: ast.Expr) !ComptimeValue {
        switch (expr) {
            .IntLiteral => |int_lit| {
                return ComptimeValue{ .Int = int_lit.value };
            },
            .FloatLiteral => |float_lit| {
                return ComptimeValue{ .Float = float_lit.value };
            },
            .BoolLiteral => |bool_lit| {
                return ComptimeValue{ .Bool = bool_lit.value };
            },
            .StringLiteral => |str_lit| {
                return ComptimeValue{ .String = str_lit.value };
            },
            .BinaryOp => |bin_op| {
                const left = try self.execute(bin_op.left.*);
                const right = try self.execute(bin_op.right.*);
                return try self.evaluateBinaryOp(left, bin_op.op, right);
            },
            .UnaryOp => |unary_op| {
                const operand = try self.execute(unary_op.operand.*);
                return try self.evaluateUnaryOp(unary_op.op, operand);
            },
            .Call => |call| {
                return try self.executeCall(call);
            },
            else => {
                try self.context.addError(.{
                    .kind = .UnsupportedExpr,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "expression cannot be evaluated at compile time",
                        .{},
                    ),
                    .loc = ast.SourceLocation{ .line = 0, .column = 0 },
                });
                return error.UnsupportedExpr;
            },
        }
    }

    /// Execute a statement at compile time
    pub fn executeStatement(self: *ComptimeExecutor, stmt: ast.Stmt) !void {
        switch (stmt) {
            .LetDecl => |let_decl| {
                const value = try self.execute(let_decl.value.*);
                try self.context.setValue(let_decl.name, value);
            },
            .Return => |ret| {
                _ = ret;
                // Handle return in comptime context
            },
            else => {
                try self.context.addError(.{
                    .kind = .UnsupportedStmt,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "statement cannot be executed at compile time",
                        .{},
                    ),
                    .loc = ast.SourceLocation{ .line = 0, .column = 0 },
                });
                return error.UnsupportedStmt;
            },
        }
    }

    /// Execute a function call at compile time
    fn executeCall(self: *ComptimeExecutor, call: ast.CallExpr) !ComptimeValue {
        // Check for built-in comptime functions
        if (call.callee.* == .Identifier) {
            const ident = call.callee.Identifier;

            // Built-in: @embed(path) - embed file contents
            if (std.mem.eql(u8, ident.name, "@embed")) {
                return try self.executeEmbed(call.args);
            }

            // Built-in: @sizeof(type) - get size of type
            if (std.mem.eql(u8, ident.name, "@sizeof")) {
                return try self.executeSizeof(call.args);
            }

            // Built-in: @typeof(expr) - get type of expression
            if (std.mem.eql(u8, ident.name, "@typeof")) {
                return try self.executeTypeof(call.args);
            }

            // Built-in: @typeInfo(type) - get type information
            if (std.mem.eql(u8, ident.name, "@typeInfo")) {
                return try self.executeTypeInfo(call.args);
            }

            // Built-in: @read_file(path) - read file at compile time
            if (std.mem.eql(u8, ident.name, "@read_file")) {
                return try self.executeReadFile(call.args);
            }

            // Built-in: @compile_error(message) - emit compile error
            if (std.mem.eql(u8, ident.name, "@compile_error")) {
                return try self.executeCompileError(call.args);
            }
        }

        // Regular function call - would need to execute the function
        try self.context.addError(.{
            .kind = .UnsupportedCall,
            .message = try std.fmt.allocPrint(
                self.allocator,
                "function call cannot be evaluated at compile time",
                .{},
            ),
            .loc = ast.SourceLocation{ .line = 0, .column = 0 },
        });
        return error.UnsupportedCall;
    }

    /// @embed(path) - embed file contents as string
    fn executeEmbed(self: *ComptimeExecutor, args: []ast.Expr) !ComptimeValue {
        if (args.len != 1) {
            return error.InvalidArgCount;
        }

        const path_value = try self.execute(args[0]);
        if (path_value != .String) {
            return error.ExpectedString;
        }

        if (!self.context.file_system_access) {
            try self.context.addError(.{
                .kind = .FileSystemAccessDenied,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "filesystem access not allowed in this context",
                    .{},
                ),
                .loc = ast.SourceLocation{ .line = 0, .column = 0 },
            });
            return error.FileSystemAccessDenied;
        }

        // Read file contents
        const file = try std.fs.cwd().openFile(path_value.String, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB limit
        return ComptimeValue{ .String = contents };
    }

    /// @sizeof(type) - get size of type in bytes
    fn executeSizeof(self: *ComptimeExecutor, args: []ast.Expr) !ComptimeValue {
        if (args.len != 1) {
            return error.InvalidArgCount;
        }

        // In a real implementation, would evaluate the type and return its size
        _ = self;
        _ = args;
        return ComptimeValue{ .Int = 8 }; // Placeholder
    }

    /// @typeof(expr) - get type of expression
    fn executeTypeof(self: *ComptimeExecutor, args: []ast.Expr) !ComptimeValue {
        if (args.len != 1) {
            return error.InvalidArgCount;
        }

        _ = self;
        _ = args;
        // Would need type inference here
        return ComptimeValue{ .Type = types.Type.Int };
    }

    /// @typeInfo(type) - get reflection information about a type
    fn executeTypeInfo(self: *ComptimeExecutor, args: []ast.Expr) !ComptimeValue {
        if (args.len != 1) {
            return error.InvalidArgCount;
        }

        _ = self;
        _ = args;
        // Would return a struct with type information
        var info = std.StringHashMap(ComptimeValue).init(self.allocator);
        try info.put("name", ComptimeValue{ .String = "int" });
        try info.put("size", ComptimeValue{ .Int = 8 });

        return ComptimeValue{ .Struct = info };
    }

    /// @read_file(path) - read file at compile time
    fn executeReadFile(self: *ComptimeExecutor, args: []ast.Expr) !ComptimeValue {
        return try self.executeEmbed(args); // Same implementation as embed
    }

    /// @compile_error(message) - emit a compile error
    fn executeCompileError(self: *ComptimeExecutor, args: []ast.Expr) !ComptimeValue {
        if (args.len != 1) {
            return error.InvalidArgCount;
        }

        const message_value = try self.execute(args[0]);
        if (message_value != .String) {
            return error.ExpectedString;
        }

        try self.context.addError(.{
            .kind = .UserError,
            .message = message_value.String,
            .loc = ast.SourceLocation{ .line = 0, .column = 0 },
        });

        return error.CompileError;
    }

    /// Evaluate binary operation at compile time
    fn evaluateBinaryOp(self: *ComptimeExecutor, left: ComptimeValue, op: ast.BinaryOperator, right: ComptimeValue) !ComptimeValue {
        _ = self;

        // Integer operations
        if (left == .Int and right == .Int) {
            return switch (op) {
                .Add => ComptimeValue{ .Int = left.Int + right.Int },
                .Subtract => ComptimeValue{ .Int = left.Int - right.Int },
                .Multiply => ComptimeValue{ .Int = left.Int * right.Int },
                .Divide => ComptimeValue{ .Int = @divTrunc(left.Int, right.Int) },
                .Modulo => ComptimeValue{ .Int = @mod(left.Int, right.Int) },
                .Equal => ComptimeValue{ .Bool = left.Int == right.Int },
                .NotEqual => ComptimeValue{ .Bool = left.Int != right.Int },
                .LessThan => ComptimeValue{ .Bool = left.Int < right.Int },
                .LessThanOrEqual => ComptimeValue{ .Bool = left.Int <= right.Int },
                .GreaterThan => ComptimeValue{ .Bool = left.Int > right.Int },
                .GreaterThanOrEqual => ComptimeValue{ .Bool = left.Int >= right.Int },
                else => error.UnsupportedOperation,
            };
        }

        // Boolean operations
        if (left == .Bool and right == .Bool) {
            return switch (op) {
                .And => ComptimeValue{ .Bool = left.Bool and right.Bool },
                .Or => ComptimeValue{ .Bool = left.Bool or right.Bool },
                .Equal => ComptimeValue{ .Bool = left.Bool == right.Bool },
                .NotEqual => ComptimeValue{ .Bool = left.Bool != right.Bool },
                else => error.UnsupportedOperation,
            };
        }

        return error.TypeMismatch;
    }

    /// Evaluate unary operation at compile time
    fn evaluateUnaryOp(self: *ComptimeExecutor, op: ast.UnaryOperator, operand: ComptimeValue) !ComptimeValue {
        _ = self;

        return switch (op) {
            .Negate => switch (operand) {
                .Int => |i| ComptimeValue{ .Int = -i },
                .Float => |f| ComptimeValue{ .Float = -f },
                else => error.TypeMismatch,
            },
            .Not => switch (operand) {
                .Bool => |b| ComptimeValue{ .Bool = !b },
                else => error.TypeMismatch,
            },
            else => error.UnsupportedOperation,
        };
    }
};

/// Compile-time errors
pub const ComptimeError = struct {
    kind: ComptimeErrorKind,
    message: []const u8,
    loc: ast.SourceLocation,
};

pub const ComptimeErrorKind = enum {
    UnsupportedExpr,
    UnsupportedStmt,
    UnsupportedCall,
    FileSystemAccessDenied,
    NetworkAccessDenied,
    TypeMismatch,
    InvalidArgCount,
    UserError,
};

/// Type introspection at compile time
pub const TypeIntrospection = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeIntrospection {
        return .{ .allocator = allocator };
    }

    /// Get fields of a struct type
    pub fn getFields(self: *TypeIntrospection, typ: types.Type) ![]FieldInfo {
        _ = self;
        _ = typ;
        // Would return list of fields
        return &[_]FieldInfo{};
    }

    /// Get methods of a type
    pub fn getMethods(self: *TypeIntrospection, typ: types.Type) ![]MethodInfo {
        _ = self;
        _ = typ;
        // Would return list of methods
        return &[_]MethodInfo{};
    }

    /// Check if a type implements a trait
    pub fn implementsTrait(self: *TypeIntrospection, typ: types.Type, trait_name: []const u8) bool {
        _ = self;
        _ = typ;
        _ = trait_name;
        return false;
    }
};

pub const FieldInfo = struct {
    name: []const u8,
    typ: types.Type,
    offset: usize,
};

pub const MethodInfo = struct {
    name: []const u8,
    params: []types.Type,
    return_type: types.Type,
};
