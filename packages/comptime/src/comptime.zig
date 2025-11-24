const std = @import("std");
const ast = @import("ast");

/// Compile-time value representation
pub const ComptimeValue = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    type_info: TypeInfo,
    @"null": void,
    @"undefined": void,
    array: []ComptimeValue,
    @"struct": StructValue,
    function: FunctionValue,

    pub const StructValue = struct {
        fields: std.StringHashMap(ComptimeValue),
    };

    pub const FunctionValue = struct {
        params: []const []const u8,
        body: *ast.Expr,
    };

    pub fn format(
        self: ComptimeValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;

        switch (self) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .bool => |v| try writer.print("{}", .{v}),
            .string => |v| try writer.print("\"{s}\"", .{v}),
            .type_info => |v| try writer.print("Type({s})", .{v.name}),
            .@"null" => try writer.writeAll("null"),
            .@"undefined" => try writer.writeAll("undefined"),
            .array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", options, writer);
                }
                try writer.writeAll("]");
            },
            .@"struct" => try writer.writeAll("struct{...}"),
            .function => try writer.writeAll("fn(...) { ... }"),
        }
    }
};

/// Type information for reflection
pub const TypeInfo = struct {
    name: []const u8,
    kind: TypeKind,
    size: usize,
    alignment: usize,
    fields: ?[]FieldInfo,

    pub const TypeKind = enum {
        Integer,
        Float,
        Bool,
        String,
        Array,
        Struct,
        Union,
        Enum,
        Function,
        Pointer,
        Optional,
    };

    pub const FieldInfo = struct {
        name: []const u8,
        type_name: []const u8,
        offset: usize,
    };
};

/// Compile-time execution environment
pub const ComptimeExecutor = struct {
    allocator: std.mem.Allocator,
    scope: Scope,
    type_registry: TypeRegistry,

    pub const Scope = struct {
        bindings: std.StringHashMap(ComptimeValue),
        parent: ?*Scope,

        pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
            return .{
                .bindings = std.StringHashMap(ComptimeValue).init(allocator),
                .parent = parent,
            };
        }

        pub fn deinit(self: *Scope) void {
            self.bindings.deinit();
        }

        pub fn get(self: *Scope, name: []const u8) ?ComptimeValue {
            if (self.bindings.get(name)) |value| {
                return value;
            }
            if (self.parent) |parent| {
                return parent.get(name);
            }
            return null;
        }

        pub fn set(self: *Scope, name: []const u8, value: ComptimeValue) !void {
            try self.bindings.put(name, value);
        }
    };

    pub const TypeRegistry = struct {
        types: std.StringHashMap(TypeInfo),

        pub fn init(allocator: std.mem.Allocator) TypeRegistry {
            return .{
                .types = std.StringHashMap(TypeInfo).init(allocator),
            };
        }

        pub fn deinit(self: *TypeRegistry) void {
            self.types.deinit();
        }

        pub fn registerType(self: *TypeRegistry, info: TypeInfo) !void {
            try self.types.put(info.name, info);
        }

        pub fn getType(self: *TypeRegistry, name: []const u8) ?TypeInfo {
            return self.types.get(name);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !ComptimeExecutor {
        var executor = ComptimeExecutor{
            .allocator = allocator,
            .scope = Scope.init(allocator, null),
            .type_registry = TypeRegistry.init(allocator),
        };

        // Register built-in types
        try executor.registerBuiltinTypes();

        return executor;
    }

    pub fn deinit(self: *ComptimeExecutor) void {
        self.scope.deinit();
        self.type_registry.deinit();
    }

    fn registerBuiltinTypes(self: *ComptimeExecutor) !void {
        // Register primitive types
        try self.type_registry.registerType(.{
            .name = "int",
            .kind = .Integer,
            .size = @sizeOf(i64),
            .alignment = @alignOf(i64),
            .fields = null,
        });

        try self.type_registry.registerType(.{
            .name = "float",
            .kind = .Float,
            .size = @sizeOf(f64),
            .alignment = @alignOf(f64),
            .fields = null,
        });

        try self.type_registry.registerType(.{
            .name = "bool",
            .kind = .Bool,
            .size = @sizeOf(bool),
            .alignment = @alignOf(bool),
            .fields = null,
        });

        try self.type_registry.registerType(.{
            .name = "string",
            .kind = .String,
            .size = @sizeOf([]const u8),
            .alignment = @alignOf([]const u8),
            .fields = null,
        });
    }

    /// Execute an expression at compile time
    pub fn eval(self: *ComptimeExecutor, expr: *ast.Expr) !ComptimeValue {
        return switch (expr.*) {
            .IntegerLiteral => |lit| ComptimeValue{ .int = lit.value },
            .FloatLiteral => |lit| ComptimeValue{ .float = lit.value },
            .BooleanLiteral => |lit| ComptimeValue{ .bool = lit.value },
            .StringLiteral => |lit| ComptimeValue{ .string = lit.value },

            .Identifier => |ident| blk: {
                if (self.scope.get(ident.name)) |value| {
                    break :blk value;
                }
                return error.UndefinedVariable;
            },

            .BinaryExpr => |bin| try self.evalBinaryExpr(bin),
            .UnaryExpr => |un| try self.evalUnaryExpr(un),
            .CallExpr => |call| try self.evalCallExpr(call),
            .ComptimeExpr => |comptime_expr| try self.eval(comptime_expr.expression),
            .ReflectExpr => |reflect| try self.evalReflectExpr(reflect),

            else => error.UnsupportedComptimeExpression,
        };
    }

    fn evalBinaryExpr(self: *ComptimeExecutor, expr: *ast.BinaryExpr) !ComptimeValue {
        const left = try self.eval(expr.left);
        const right = try self.eval(expr.right);

        return switch (expr.op) {
            .Add => blk: {
                if (left == .int and right == .int) {
                    break :blk ComptimeValue{ .int = left.int + right.int };
                }
                if (left == .float and right == .float) {
                    break :blk ComptimeValue{ .float = left.float + right.float };
                }
                return error.TypeMismatch;
            },
            .Subtract => blk: {
                if (left == .int and right == .int) {
                    break :blk ComptimeValue{ .int = left.int - right.int };
                }
                if (left == .float and right == .float) {
                    break :blk ComptimeValue{ .float = left.float - right.float };
                }
                return error.TypeMismatch;
            },
            .Multiply => blk: {
                if (left == .int and right == .int) {
                    break :blk ComptimeValue{ .int = left.int * right.int };
                }
                if (left == .float and right == .float) {
                    break :blk ComptimeValue{ .float = left.float * right.float };
                }
                return error.TypeMismatch;
            },
            .Divide => blk: {
                if (left == .int and right == .int) {
                    if (right.int == 0) return error.DivisionByZero;
                    break :blk ComptimeValue{ .int = @divTrunc(left.int, right.int) };
                }
                if (left == .float and right == .float) {
                    if (right.float == 0.0) return error.DivisionByZero;
                    break :blk ComptimeValue{ .float = left.float / right.float };
                }
                return error.TypeMismatch;
            },
            .Modulo => blk: {
                if (left == .int and right == .int) {
                    if (right.int == 0) return error.DivisionByZero;
                    break :blk ComptimeValue{ .int = @rem(left.int, right.int) };
                }
                return error.TypeMismatch;
            },
            .Equal => blk: {
                const result = switch (left) {
                    .int => |lv| right == .int and lv == right.int,
                    .float => |lv| right == .float and lv == right.float,
                    .bool => |lv| right == .bool and lv == right.bool,
                    .string => |lv| right == .string and std.mem.eql(u8, lv, right.string),
                    else => false,
                };
                break :blk ComptimeValue{ .bool = result };
            },
            .NotEqual => blk: {
                const result = switch (left) {
                    .int => |lv| right != .int or lv != right.int,
                    .float => |lv| right != .float or lv != right.float,
                    .bool => |lv| right != .bool or lv != right.bool,
                    .string => |lv| right != .string or !std.mem.eql(u8, lv, right.string),
                    else => true,
                };
                break :blk ComptimeValue{ .bool = result };
            },
            .LessThan => blk: {
                if (left == .int and right == .int) {
                    break :blk ComptimeValue{ .bool = left.int < right.int };
                }
                if (left == .float and right == .float) {
                    break :blk ComptimeValue{ .bool = left.float < right.float };
                }
                return error.TypeMismatch;
            },
            .LessEqual => blk: {
                if (left == .int and right == .int) {
                    break :blk ComptimeValue{ .bool = left.int <= right.int };
                }
                if (left == .float and right == .float) {
                    break :blk ComptimeValue{ .bool = left.float <= right.float };
                }
                return error.TypeMismatch;
            },
            .GreaterThan => blk: {
                if (left == .int and right == .int) {
                    break :blk ComptimeValue{ .bool = left.int > right.int };
                }
                if (left == .float and right == .float) {
                    break :blk ComptimeValue{ .bool = left.float > right.float };
                }
                return error.TypeMismatch;
            },
            .GreaterEqual => blk: {
                if (left == .int and right == .int) {
                    break :blk ComptimeValue{ .bool = left.int >= right.int };
                }
                if (left == .float and right == .float) {
                    break :blk ComptimeValue{ .bool = left.float >= right.float };
                }
                return error.TypeMismatch;
            },
            .LogicalAnd => blk: {
                if (left == .bool and right == .bool) {
                    break :blk ComptimeValue{ .bool = left.bool and right.bool };
                }
                return error.TypeMismatch;
            },
            .LogicalOr => blk: {
                if (left == .bool and right == .bool) {
                    break :blk ComptimeValue{ .bool = left.bool or right.bool };
                }
                return error.TypeMismatch;
            },
            else => error.UnsupportedBinaryOp,
        };
    }

    fn evalUnaryExpr(self: *ComptimeExecutor, expr: *ast.UnaryExpr) !ComptimeValue {
        const operand = try self.eval(expr.operand);

        return switch (expr.op) {
            .Neg => blk: {
                if (operand == .int) {
                    break :blk ComptimeValue{ .int = -operand.int };
                }
                if (operand == .float) {
                    break :blk ComptimeValue{ .float = -operand.float };
                }
                return error.TypeMismatch;
            },
            .Not => blk: {
                if (operand == .bool) {
                    break :blk ComptimeValue{ .bool = !operand.bool };
                }
                return error.TypeMismatch;
            },
        };
    }

    fn evalCallExpr(self: *ComptimeExecutor, expr: *ast.CallExpr) !ComptimeValue {
        const callee = try self.eval(expr.callee);

        if (callee != .function) {
            return error.NotAFunction;
        }

        const func = callee.function;

        // Evaluate arguments
        var args = try std.ArrayList(ComptimeValue).initCapacity(self.allocator, expr.arguments.len);
        defer args.deinit();

        for (expr.arguments) |arg| {
            const value = try self.eval(arg);
            try args.append(value);
        }

        // Create new scope for function execution
        var func_scope = Scope.init(self.allocator, &self.scope);
        defer func_scope.deinit();

        // Bind parameters
        if (func.params.len != args.items.len) {
            return error.ArgumentCountMismatch;
        }

        for (func.params, args.items) |param, arg| {
            try func_scope.set(param, arg);
        }

        // Temporarily swap scope
        const old_scope = self.scope;
        self.scope = func_scope;
        defer self.scope = old_scope;

        // Execute function body
        return try self.eval(func.body);
    }

    fn evalReflectExpr(self: *ComptimeExecutor, expr: *ast.ReflectExpr) !ComptimeValue {
        return switch (expr.kind) {
            .TypeOf => blk: {
                const value = try self.eval(expr.target);
                const type_name = switch (value) {
                    .int => "int",
                    .float => "float",
                    .bool => "bool",
                    .string => "string",
                    .type_info => |ti| ti.name,
                    else => "unknown",
                };

                const type_info = self.type_registry.getType(type_name) orelse return error.UnknownType;
                break :blk ComptimeValue{ .type_info = type_info };
            },

            .SizeOf => blk: {
                // Target should be a type expression
                const target = try self.eval(expr.target);
                if (target != .type_info) {
                    return error.ExpectedType;
                }
                break :blk ComptimeValue{ .int = @intCast(target.type_info.size) };
            },

            .AlignOf => blk: {
                const target = try self.eval(expr.target);
                if (target != .type_info) {
                    return error.ExpectedType;
                }
                break :blk ComptimeValue{ .int = @intCast(target.type_info.alignment) };
            },

            .OffsetOf => blk: {
                const target = try self.eval(expr.target);
                if (target != .type_info) {
                    return error.ExpectedType;
                }

                const field_name = expr.field_name orelse return error.MissingFieldName;
                const fields = target.type_info.fields orelse return error.NoFields;

                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        break :blk ComptimeValue{ .int = @intCast(field.offset) };
                    }
                }
                return error.FieldNotFound;
            },

            .TypeInfo => blk: {
                const target = try self.eval(expr.target);
                if (target != .type_info) {
                    return error.ExpectedType;
                }
                break :blk target;
            },

            .FieldName => blk: {
                const target = try self.eval(expr.target);
                if (target != .type_info) {
                    return error.ExpectedType;
                }

                const fields = target.type_info.fields orelse return error.NoFields;

                // For simplicity, return first field name
                // In production, would need index parameter
                if (fields.len > 0) {
                    break :blk ComptimeValue{ .string = fields[0].name };
                }
                return error.NoFields;
            },

            .FieldType => blk: {
                const target = try self.eval(expr.target);
                if (target != .type_info) {
                    return error.ExpectedType;
                }

                const field_name = expr.field_name orelse return error.MissingFieldName;
                const fields = target.type_info.fields orelse return error.NoFields;

                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        const field_type = self.type_registry.getType(field.type_name) orelse return error.UnknownType;
                        break :blk ComptimeValue{ .type_info = field_type };
                    }
                }
                return error.FieldNotFound;
            },
        };
    }

    /// Execute a full program at compile time
    pub fn execProgram(self: *ComptimeExecutor, program: *ast.Program) !void {
        for (program.statements) |stmt| {
            try self.execStatement(stmt);
        }
    }

    fn execStatement(self: *ComptimeExecutor, stmt: *ast.Stmt) !void {
        switch (stmt.*) {
            .LetDecl => |decl| {
                const value = if (decl.initializer) |initializer|
                    try self.eval(initializer)
                else
                    ComptimeValue{ .@"undefined" = {} };

                try self.scope.set(decl.name, value);
            },

            .ConstDecl => {
                // Similar to let
                // Would need to extract from const decl
            },

            .ExprStmt => |expr_stmt| {
                _ = try self.eval(expr_stmt.expression);
            },

            else => {
                // Other statements not supported at comptime
            },
        }
    }
};
