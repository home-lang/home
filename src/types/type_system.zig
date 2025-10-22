const std = @import("std");
const ast = @import("../ast/ast.zig");
const ownership = @import("ownership.zig");
const diagnostics = @import("../diagnostics/diagnostics.zig");

/// Ion type system
pub const Type = union(enum) {
    Int,
    Float,
    Bool,
    String,
    Void,
    Function: FunctionType,
    Struct: StructType,
    Generic: GenericType,
    Result: ResultType,
    Reference: *const Type, // Borrowed reference
    MutableReference: *const Type, // Mutable borrow

    pub const FunctionType = struct {
        params: []const Type,
        return_type: *const Type,
    };

    pub const StructType = struct {
        name: []const u8,
        fields: []const Field,

        pub const Field = struct {
            name: []const u8,
            type: Type,
        };
    };

    pub const GenericType = struct {
        name: []const u8,
        bounds: []const Type, // Trait bounds
    };

    pub const ResultType = struct {
        ok_type: *const Type,
        err_type: *const Type,
    };

    pub fn equals(self: Type, other: Type) bool {
        const self_tag = @as(std.meta.Tag(Type), self);
        const other_tag = @as(std.meta.Tag(Type), other);
        if (self_tag != other_tag) {
            return false;
        }

        return switch (self) {
            .Int, .Float, .Bool, .String, .Void => true,
            .Function => |f1| {
                const f2 = other.Function;
                if (f1.params.len != f2.params.len) return false;
                for (f1.params, f2.params) |p1, p2| {
                    if (!p1.equals(p2)) return false;
                }
                return f1.return_type.equals(f2.return_type.*);
            },
            .Reference => |r1| r1.equals(other.Reference.*),
            .MutableReference => |r1| r1.equals(other.MutableReference.*),
            else => false, // TODO: implement for other types
        };
    }

    pub fn format(self: Type, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .Int => try writer.writeAll("int"),
            .Float => try writer.writeAll("float"),
            .Bool => try writer.writeAll("bool"),
            .String => try writer.writeAll("string"),
            .Void => try writer.writeAll("void"),
            .Function => |f| {
                try writer.writeAll("fn(");
                for (f.params, 0..) |param, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{param});
                }
                try writer.print(") -> {}", .{f.return_type.*});
            },
            .Reference => |r| try writer.print("&{}", .{r.*}),
            .MutableReference => |r| try writer.print("&mut {}", .{r.*}),
            .Result => |r| try writer.print("Result<{}, {}>", .{ r.ok_type.*, r.err_type.* }),
            else => try writer.writeAll("<complex-type>"),
        }
    }
};

pub const TypeError = error{
    TypeMismatch,
    UndefinedVariable,
    UndefinedFunction,
    WrongNumberOfArguments,
    InvalidOperation,
    CannotInferType,
    UseAfterMove,
    MultipleMutableBorrows,
    BorrowWhileMutablyBorrowed,
    MutBorrowWhileBorrowed,
} || std.mem.Allocator.Error;

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    env: TypeEnvironment,
    errors: std.ArrayList(TypeErrorInfo),
    allocated_types: std.ArrayList(*Type),
    allocated_slices: std.ArrayList([]Type),
    ownership_tracker: ownership.OwnershipTracker,

    pub const TypeErrorInfo = struct {
        message: []const u8,
        loc: ast.SourceLocation,
    };

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) TypeChecker {
        return .{
            .allocator = allocator,
            .program = program,
            .env = TypeEnvironment.init(allocator),
            .errors = std.ArrayList(TypeErrorInfo){},
            .allocated_types = std.ArrayList(*Type){},
            .allocated_slices = std.ArrayList([]Type){},
            .ownership_tracker = ownership.OwnershipTracker.init(allocator),
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        self.env.deinit();
        for (self.errors.items) |err_info| {
            self.allocator.free(err_info.message);
        }
        self.errors.deinit(self.allocator);

        // Free all allocated types
        for (self.allocated_types.items) |typ| {
            self.allocator.destroy(typ);
        }
        self.allocated_types.deinit(self.allocator);

        // Free all allocated slices
        for (self.allocated_slices.items) |slice| {
            self.allocator.free(slice);
        }
        self.allocated_slices.deinit(self.allocator);

        self.ownership_tracker.deinit();
    }

    pub fn check(self: *TypeChecker) !bool {
        // Register built-in types
        try self.registerBuiltins();

        // First pass: collect function signatures
        for (self.program.statements) |stmt| {
            if (stmt == .FnDecl) {
                try self.collectFunctionSignature(stmt.FnDecl);
            }
        }

        // Second pass: type check all statements
        for (self.program.statements) |stmt| {
            self.checkStatement(stmt) catch |err| {
                if (err != error.TypeMismatch) return err;
                // Continue checking to find more errors
            };
        }

        // Collect ownership errors into main error list
        for (self.ownership_tracker.errors.items) |err_info| {
            const msg = try self.allocator.dupe(u8, err_info.message);
            try self.errors.append(self.allocator, .{ .message = msg, .loc = err_info.loc });
        }

        return self.errors.items.len == 0;
    }

    fn registerBuiltins(self: *TypeChecker) !void {
        // Create static Void type for return types
        const void_type = try self.allocator.create(Type);
        void_type.* = Type.Void;
        try self.allocated_types.append(self.allocator, void_type);

        // print: fn(...) -> void
        const print_type = Type{
            .Function = .{
                .params = &[_]Type{}, // Variadic, we'll handle specially
                .return_type = void_type,
            },
        };
        try self.env.define("print", print_type);

        // assert: fn(bool) -> void
        const assert_params = try self.allocator.alloc(Type, 1);
        try self.allocated_slices.append(self.allocator, assert_params);
        assert_params[0] = Type.Bool;
        const assert_type = Type{
            .Function = .{
                .params = assert_params,
                .return_type = void_type,
            },
        };
        try self.env.define("assert", assert_type);
    }

    fn collectFunctionSignature(self: *TypeChecker, fn_decl: *const ast.FnDecl) !void {
        var param_types = try self.allocator.alloc(Type, fn_decl.params.len);
        try self.allocated_slices.append(self.allocator, param_types);

        for (fn_decl.params, 0..) |param, i| {
            param_types[i] = try self.parseTypeName(param.type_name);
        }

        const return_type = try self.allocator.create(Type);
        try self.allocated_types.append(self.allocator, return_type);
        if (fn_decl.return_type) |rt| {
            return_type.* = try self.parseTypeName(rt);
        } else {
            return_type.* = Type.Void;
        }

        const func_type = Type{
            .Function = .{
                .params = param_types,
                .return_type = return_type,
            },
        };

        try self.env.define(fn_decl.name, func_type);
    }

    fn checkStatement(self: *TypeChecker, stmt: ast.Stmt) TypeError!void {
        switch (stmt) {
            .LetDecl => |decl| {
                if (decl.value) |value| {
                    const value_type = try self.inferExpression(value);

                    if (decl.type_name) |type_name| {
                        const declared_type = try self.parseTypeName(type_name);
                        if (!value_type.equals(declared_type)) {
                            try self.addError("Type mismatch in let declaration", .{ .line = 0, .column = 0 });
                            return error.TypeMismatch;
                        }
                    }

                    try self.env.define(decl.name, value_type);
                    // Track ownership of the new variable
                    try self.ownership_tracker.define(decl.name, value_type, .{ .line = 0, .column = 0 });
                } else if (decl.type_name) |type_name| {
                    const var_type = try self.parseTypeName(type_name);
                    try self.env.define(decl.name, var_type);
                    try self.ownership_tracker.define(decl.name, var_type, .{ .line = 0, .column = 0 });
                }
            },
            .FnDecl => |fn_decl| {
                // Create new scope for function
                var func_env = TypeEnvironment.init(self.allocator);
                func_env.parent = &self.env;
                defer func_env.deinit();

                // Add parameters to function scope
                for (fn_decl.params) |param| {
                    const param_type = try self.parseTypeName(param.type_name);
                    try func_env.define(param.name, param_type);
                }

                // Type check function body
                // TODO: Implement body checking with func_env
            },
            .ExprStmt => |expr| {
                _ = try self.inferExpression(expr);
            },
            else => {},
        }
    }

    fn inferExpression(self: *TypeChecker, expr: *const ast.Expr) TypeError!Type {
        return switch (expr.*) {
            .IntegerLiteral => Type.Int,
            .FloatLiteral => Type.Float,
            .StringLiteral => Type.String,
            .BooleanLiteral => Type.Bool,
            .Identifier => |id| {
                // Check ownership before use
                self.ownership_tracker.checkUse(id.name, id.node.loc) catch |err| {
                    if (err != error.UseAfterMove) return err;
                    // Error already added to ownership tracker
                };

                return self.env.get(id.name) orelse {
                    try self.addError("Undefined variable", .{ .line = 0, .column = 0 });
                    return error.UndefinedVariable;
                };
            },
            .BinaryExpr => |binary| try self.inferBinaryExpression(binary),
            .CallExpr => |call| try self.inferCallExpression(call),
            .TryExpr => |try_expr| try self.inferTryExpression(try_expr),
            else => Type.Void,
        };
    }

    fn inferBinaryExpression(self: *TypeChecker, binary: *const ast.BinaryExpr) TypeError!Type {
        const left_type = try self.inferExpression(binary.left);
        const right_type = try self.inferExpression(binary.right);

        return switch (binary.op) {
            .Add, .Sub, .Mul, .Div, .Mod => {
                if (left_type.equals(Type.Int) and right_type.equals(Type.Int)) {
                    return Type.Int;
                } else if (left_type.equals(Type.Float) or right_type.equals(Type.Float)) {
                    return Type.Float;
                } else {
                    try self.addError("Arithmetic operation requires numeric types", .{ .line = 0, .column = 0 });
                    return error.TypeMismatch;
                }
            },
            .Equal, .NotEqual, .Less, .LessEq, .Greater, .GreaterEq => Type.Bool,
            .And, .Or => {
                if (!left_type.equals(Type.Bool) or !right_type.equals(Type.Bool)) {
                    try self.addError("Logical operation requires boolean types", .{ .line = 0, .column = 0 });
                    return error.TypeMismatch;
                }
                return Type.Bool;
            },
            else => Type.Void,
        };
    }

    fn inferCallExpression(self: *TypeChecker, call: *const ast.CallExpr) TypeError!Type {
        if (call.callee.* == .Identifier) {
            const func_name = call.callee.Identifier.name;
            const func_type = self.env.get(func_name) orelse {
                try self.addError("Undefined function", .{ .line = 0, .column = 0 });
                return error.UndefinedFunction;
            };

            if (func_type == .Function) {
                // Check argument types
                const expected_params = func_type.Function.params;

                // Special case for print (variadic)
                if (!std.mem.eql(u8, func_name, "print")) {
                    if (call.args.len != expected_params.len) {
                        try self.addError("Wrong number of arguments", .{ .line = 0, .column = 0 });
                        return error.WrongNumberOfArguments;
                    }

                    for (call.args, 0..) |arg, i| {
                        const arg_type = try self.inferExpression(arg);
                        if (!arg_type.equals(expected_params[i])) {
                            try self.addError("Argument type mismatch", .{ .line = 0, .column = 0 });
                            return error.TypeMismatch;
                        }
                    }
                }

                return func_type.Function.return_type.*;
            }
        }

        return Type.Void;
    }

    fn inferTryExpression(self: *TypeChecker, try_expr: *const ast.TryExpr) TypeError!Type {
        const operand_type = try self.inferExpression(try_expr.operand);

        // The operand must be a Result<T, E> type
        if (operand_type != .Result) {
            try self.addError("Try operator (?) can only be used on Result types", .{ .line = 0, .column = 0 });
            return error.TypeMismatch;
        }

        // The try operator unwraps the Ok value, or propagates the error
        // So the type of `expr?` is T from Result<T, E>
        return operand_type.Result.ok_type.*;
    }

    fn parseTypeName(self: *TypeChecker, name: []const u8) !Type {
        _ = self;
        if (std.mem.eql(u8, name, "int")) return Type.Int;
        if (std.mem.eql(u8, name, "float")) return Type.Float;
        if (std.mem.eql(u8, name, "bool")) return Type.Bool;
        if (std.mem.eql(u8, name, "string")) return Type.String;
        if (std.mem.eql(u8, name, "void")) return Type.Void;

        // TODO: Handle complex types
        return Type.Void;
    }

    fn addError(self: *TypeChecker, message: []const u8, loc: ast.SourceLocation) !void {
        const msg = try self.allocator.dupe(u8, message);
        try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
    }
};

pub const TypeEnvironment = struct {
    bindings: std.StringHashMap(Type),
    parent: ?*TypeEnvironment,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeEnvironment {
        return .{
            .bindings = std.StringHashMap(Type).init(allocator),
            .parent = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TypeEnvironment) void {
        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.bindings.deinit();
    }

    pub fn define(self: *TypeEnvironment, name: []const u8, typ: Type) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.bindings.put(name_copy, typ);
    }

    pub fn get(self: *TypeEnvironment, name: []const u8) ?Type {
        if (self.bindings.get(name)) |typ| {
            return typ;
        }
        if (self.parent) |parent| {
            return parent.get(name);
        }
        return null;
    }
};
