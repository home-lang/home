const std = @import("std");
const ast = @import("ast");

/// Type checking errors
pub const TypeCheckError = error{
    TypeMismatch,
    UndefinedVariable,
    UndefinedFunction,
    ArgumentCountMismatch,
    ReturnTypeMismatch,
    InvalidOperandTypes,
    NotCallable,
} || std.mem.Allocator.Error;

/// Simple type representation for type checking
pub const SimpleType = union(enum) {
    I8,
    I16,
    I32,
    I64,
    F32,
    F64,
    Bool,
    String,
    Void,
    Array: *const SimpleType,
    Function: FunctionType,
    Struct: []const u8, // Just the name
    Enum: []const u8,   // Just the name
    Unknown, // For untyped expressions (will be inferred)

    pub const FunctionType = struct {
        param_types: []const SimpleType,
        return_type: *const SimpleType,
    };

    /// Check if two types are equal
    pub fn equals(self: SimpleType, other: SimpleType) bool {
        const self_tag = @as(std.meta.Tag(SimpleType), self);
        const other_tag = @as(std.meta.Tag(SimpleType), other);

        if (self_tag != other_tag) return false;

        return switch (self) {
            .I8, .I16, .I32, .I64, .F32, .F64, .Bool, .String, .Void, .Unknown => true,
            .Array => |elem_ty| elem_ty.equals(other.Array.*),
            .Function => |f1| {
                const f2 = other.Function;
                if (f1.param_types.len != f2.param_types.len) return false;
                for (f1.param_types, f2.param_types) |p1, p2| {
                    if (!p1.equals(p2)) return false;
                }
                return f1.return_type.equals(f2.return_type.*);
            },
            .Struct => |name1| std.mem.eql(u8, name1, other.Struct),
            .Enum => |name1| std.mem.eql(u8, name1, other.Enum),
        };
    }

    /// Format type for error messages
    pub fn format(
        self: SimpleType,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        switch (self) {
            .I8 => try writer.writeAll("i8"),
            .I16 => try writer.writeAll("i16"),
            .I32 => try writer.writeAll("i32"),
            .I64 => try writer.writeAll("i64"),
            .F32 => try writer.writeAll("f32"),
            .F64 => try writer.writeAll("f64"),
            .Bool => try writer.writeAll("bool"),
            .String => try writer.writeAll("string"),
            .Void => try writer.writeAll("void"),
            .Unknown => try writer.writeAll("?"),
            .Array => |elem| try writer.print("[{}]", .{elem.*}),
            .Function => |func| {
                try writer.writeAll("fn(");
                for (func.param_types, 0..) |param, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{param});
                }
                try writer.print(") -> {}", .{func.return_type.*});
            },
            .Struct => |name| try writer.print("struct {s}", .{name}),
            .Enum => |name| try writer.print("enum {s}", .{name}),
        }
    }
};

/// Type checker state
pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    /// Map of variable names to their types
    variables: std.StringHashMap(SimpleType),
    /// Map of function names to their signatures
    functions: std.StringHashMap(SimpleType.FunctionType),
    /// Map of struct names to field types
    structs: std.StringHashMap(std.StringHashMap(SimpleType)),
    /// Map of enum names to variant info
    enums: std.StringHashMap(void),
    /// Current function's return type (for validating return statements)
    current_function_return_type: ?SimpleType,
    /// Error list for accumulating type errors
    errors: std.ArrayList(TypeError),

    pub const TypeError = struct {
        message: []const u8,
        line: usize,
        column: usize,
    };

    pub fn init(allocator: std.mem.Allocator) TypeChecker {
        return .{
            .allocator = allocator,
            .variables = std.StringHashMap(SimpleType).init(allocator),
            .functions = std.StringHashMap(SimpleType.FunctionType).init(allocator),
            .structs = std.StringHashMap(std.StringHashMap(SimpleType)).init(allocator),
            .enums = std.StringHashMap(void).init(allocator),
            .current_function_return_type = null,
            .errors = std.ArrayList(TypeError).init(allocator),
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        self.variables.deinit();
        self.functions.deinit();

        var struct_iter = self.structs.valueIterator();
        while (struct_iter.next()) |fields| {
            fields.deinit();
        }
        self.structs.deinit();

        self.enums.deinit();

        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit();
    }

    /// Add a type error
    fn addError(self: *TypeChecker, message: []const u8, line: usize, column: usize) !void {
        const msg_copy = try self.allocator.dupe(u8, message);
        try self.errors.append(.{
            .message = msg_copy,
            .line = line,
            .column = column,
        });
    }

    /// Check if there are any type errors
    pub fn hasErrors(self: *TypeChecker) bool {
        return self.errors.items.len > 0;
    }

    /// Print all accumulated errors
    pub fn printErrors(self: *TypeChecker) void {
        if (self.errors.items.len == 0) return;

        std.debug.print("\n=== Type Errors ===\n", .{});
        for (self.errors.items) |err| {
            std.debug.print("Error at line {d}, column {d}: {s}\n", .{
                err.line,
                err.column,
                err.message,
            });
        }
        std.debug.print("Found {d} type error(s)\n\n", .{self.errors.items.len});
    }

    /// Parse a type annotation string into a SimpleType
    pub fn parseTypeAnnotation(self: *TypeChecker, type_str: []const u8) !SimpleType {
        if (std.mem.eql(u8, type_str, "i8")) return .I8;
        if (std.mem.eql(u8, type_str, "i16")) return .I16;
        if (std.mem.eql(u8, type_str, "i32")) return .I32;
        if (std.mem.eql(u8, type_str, "i64")) return .I64;
        if (std.mem.eql(u8, type_str, "f32")) return .F32;
        if (std.mem.eql(u8, type_str, "f64")) return .F64;
        if (std.mem.eql(u8, type_str, "bool")) return .Bool;
        if (std.mem.eql(u8, type_str, "string")) return .String;
        if (std.mem.eql(u8, type_str, "void")) return .Void;

        // Check for array type [T]
        if (type_str.len > 2 and type_str[0] == '[' and type_str[type_str.len - 1] == ']') {
            const elem_type_str = type_str[1..type_str.len - 1];
            const elem_type = try self.parseTypeAnnotation(elem_type_str);
            const elem_ptr = try self.allocator.create(SimpleType);
            elem_ptr.* = elem_type;
            return SimpleType{ .Array = elem_ptr };
        }

        // Check if it's a known struct or enum
        if (self.structs.contains(type_str)) {
            return SimpleType{ .Struct = type_str };
        }
        if (self.enums.contains(type_str)) {
            return SimpleType{ .Enum = type_str };
        }

        // Unknown type - will be treated as custom type
        return .Unknown;
    }

    /// Type check an expression and return its type
    pub fn checkExpression(self: *TypeChecker, expr: *const ast.Expr) TypeCheckError!SimpleType {
        return switch (expr.*) {
            .IntegerLiteral => .I32, // Default integer type
            .FloatLiteral => .F64,   // Default float type
            .StringLiteral => .String,
            .BooleanLiteral => .Bool,

            .Identifier => |id| {
                if (self.variables.get(id.name)) |var_type| {
                    return var_type;
                }
                try self.addError(
                    try std.fmt.allocPrint(self.allocator, "Undefined variable: {s}", .{id.name}),
                    id.node.loc.line,
                    id.node.loc.column,
                );
                return .Unknown;
            },

            .BinaryExpr => |bin| try self.checkBinaryExpr(bin),
            .UnaryExpr => |un| try self.checkUnaryExpr(un),
            .CallExpr => |call| try self.checkCallExpr(call),
            .ArrayLiteral => |arr| try self.checkArrayLiteral(arr),
            .IndexExpr => |idx| try self.checkIndexExpr(idx),
            .MemberExpr => |mem| try self.checkMemberExpr(mem),

            else => .Unknown, // For unsupported expressions
        };
    }

    /// Type check a binary expression
    fn checkBinaryExpr(self: *TypeChecker, bin: *const ast.BinaryExpr) TypeCheckError!SimpleType {
        const left_type = try self.checkExpression(&bin.left);
        const right_type = try self.checkExpression(&bin.right);

        // Comparison operators return bool
        switch (bin.operator) {
            .EqualEqual, .BangEqual, .Less, .LessEqual, .Greater, .GreaterEqual => {
                if (!left_type.equals(right_type)) {
                    try self.addError(
                        try std.fmt.allocPrint(
                            self.allocator,
                            "Type mismatch in comparison: {} vs {}",
                            .{left_type, right_type}
                        ),
                        bin.node.loc.line,
                        bin.node.loc.column,
                    );
                }
                return .Bool;
            },

            // Logical operators require bool and return bool
            .AmpersandAmpersand, .PipePipe => {
                if (!left_type.equals(.Bool)) {
                    try self.addError(
                        try std.fmt.allocPrint(
                            self.allocator,
                            "Left operand of logical operator must be bool, got {}",
                            .{left_type}
                        ),
                        bin.node.loc.line,
                        bin.node.loc.column,
                    );
                }
                if (!right_type.equals(.Bool)) {
                    try self.addError(
                        try std.fmt.allocPrint(
                            self.allocator,
                            "Right operand of logical operator must be bool, got {}",
                            .{right_type}
                        ),
                        bin.node.loc.line,
                        bin.node.loc.column,
                    );
                }
                return .Bool;
            },

            // Arithmetic operators require matching numeric types
            .Plus, .Minus, .Star, .Slash, .Percent => {
                if (!left_type.equals(right_type)) {
                    try self.addError(
                        try std.fmt.allocPrint(
                            self.allocator,
                            "Type mismatch in arithmetic: {} vs {}",
                            .{left_type, right_type}
                        ),
                        bin.node.loc.line,
                        bin.node.loc.column,
                    );
                    return .Unknown;
                }
                return left_type;
            },

            else => return .Unknown,
        }
    }

    /// Type check a unary expression
    fn checkUnaryExpr(self: *TypeChecker, un: *const ast.UnaryExpr) TypeCheckError!SimpleType {
        const operand_type = try self.checkExpression(&un.operand);

        switch (un.operator) {
            .Bang => {
                if (!operand_type.equals(.Bool)) {
                    try self.addError(
                        try std.fmt.allocPrint(
                            self.allocator,
                            "Logical NOT requires bool operand, got {}",
                            .{operand_type}
                        ),
                        un.node.loc.line,
                        un.node.loc.column,
                    );
                }
                return .Bool;
            },
            .Minus => return operand_type, // Numeric negation preserves type
            else => return .Unknown,
        }
    }

    /// Type check a function call
    fn checkCallExpr(self: *TypeChecker, call: *const ast.CallExpr) TypeCheckError!SimpleType {
        // Get the function name
        const func_name = switch (call.callee.*) {
            .Identifier => |id| id.name,
            else => {
                try self.addError(
                    "Complex call expressions not yet supported in type checker",
                    call.node.loc.line,
                    call.node.loc.column,
                );
                return .Unknown;
            },
        };

        // Look up function signature
        const func_sig = self.functions.get(func_name) orelse {
            try self.addError(
                try std.fmt.allocPrint(self.allocator, "Undefined function: {s}", .{func_name}),
                call.node.loc.line,
                call.node.loc.column,
            );
            return .Unknown;
        };

        // Check argument count
        if (call.arguments.len != func_sig.param_types.len) {
            try self.addError(
                try std.fmt.allocPrint(
                    self.allocator,
                    "Function {s} expects {d} arguments, got {d}",
                    .{func_name, func_sig.param_types.len, call.arguments.len}
                ),
                call.node.loc.line,
                call.node.loc.column,
            );
            return func_sig.return_type.*;
        }

        // Check argument types
        for (call.arguments, func_sig.param_types, 0..) |arg, expected_type, i| {
            const arg_type = try self.checkExpression(&arg);
            if (!arg_type.equals(expected_type) and !arg_type.equals(.Unknown)) {
                try self.addError(
                    try std.fmt.allocPrint(
                        self.allocator,
                        "Argument {d} of function {s}: expected {}, got {}",
                        .{i + 1, func_name, expected_type, arg_type}
                    ),
                    call.node.loc.line,
                    call.node.loc.column,
                );
            }
        }

        return func_sig.return_type.*;
    }

    /// Type check an array literal
    fn checkArrayLiteral(self: *TypeChecker, arr: *const ast.ArrayLiteral) TypeCheckError!SimpleType {
        if (arr.elements.len == 0) {
            return .Unknown; // Empty array - type cannot be inferred
        }

        // All elements must have the same type
        const first_type = try self.checkExpression(&arr.elements[0]);
        for (arr.elements[1..], 1..) |elem, i| {
            const elem_type = try self.checkExpression(&elem);
            if (!elem_type.equals(first_type)) {
                try self.addError(
                    try std.fmt.allocPrint(
                        self.allocator,
                        "Array element {d} has type {}, expected {}",
                        .{i, elem_type, first_type}
                    ),
                    arr.node.loc.line,
                    arr.node.loc.column,
                );
            }
        }

        const elem_ptr = try self.allocator.create(SimpleType);
        elem_ptr.* = first_type;
        return SimpleType{ .Array = elem_ptr };
    }

    /// Type check an index expression
    fn checkIndexExpr(self: *TypeChecker, idx: *const ast.IndexExpr) TypeCheckError!SimpleType {
        const array_type = try self.checkExpression(&idx.array);
        const index_type = try self.checkExpression(&idx.index);

        // Index must be an integer
        if (!index_type.equals(.I32) and !index_type.equals(.I64)) {
            try self.addError(
                try std.fmt.allocPrint(
                    self.allocator,
                    "Array index must be integer, got {}",
                    .{index_type}
                ),
                idx.node.loc.line,
                idx.node.loc.column,
            );
        }

        // Array type must be an array
        switch (array_type) {
            .Array => |elem_type| return elem_type.*,
            else => {
                try self.addError(
                    try std.fmt.allocPrint(
                        self.allocator,
                        "Cannot index into non-array type {}",
                        .{array_type}
                    ),
                    idx.node.loc.line,
                    idx.node.loc.column,
                );
                return .Unknown;
            },
        }
    }

    /// Type check a member access expression
    fn checkMemberExpr(self: *TypeChecker, mem: *const ast.MemberExpr) TypeCheckError!SimpleType {
        const object_type = try self.checkExpression(&mem.object);

        // For now, just return Unknown for struct member access
        // A complete implementation would look up the field type in struct_layouts
        _ = object_type;
        return .Unknown;
    }

    /// Type check a statement
    pub fn checkStatement(self: *TypeChecker, stmt: *const ast.Stmt) TypeCheckError!void {
        switch (stmt.*) {
            .LetDecl => |let_decl| try self.checkLetDecl(let_decl),
            .FnDecl => |fn_decl| try self.checkFnDecl(fn_decl),
            .ReturnStmt => |ret| try self.checkReturnStmt(ret),
            .ExprStmt => |expr_stmt| {
                _ = try self.checkExpression(&expr_stmt.expression);
            },
            .IfStmt => |if_stmt| try self.checkIfStmt(if_stmt),
            .WhileStmt => |while_stmt| try self.checkWhileStmt(while_stmt),
            .ForStmt => |for_stmt| try self.checkForStmt(for_stmt),
            .BlockStmt => |block| try self.checkBlock(block),
            .StructDecl => |struct_decl| try self.registerStruct(struct_decl),
            .EnumDecl => |enum_decl| try self.registerEnum(enum_decl),
            else => {}, // Skip unsupported statements
        }
    }

    /// Type check a let declaration
    fn checkLetDecl(self: *TypeChecker, let_decl: *const ast.LetDecl) TypeCheckError!void {
        // Check initializer type
        const init_type = if (let_decl.initializer) |init_expr|
            try self.checkExpression(&init_expr)
        else
            .Unknown;

        // If there's a type annotation, verify it matches
        if (let_decl.type_annotation) |type_str| {
            const declared_type = try self.parseTypeAnnotation(type_str);
            if (!init_type.equals(declared_type) and !init_type.equals(.Unknown)) {
                try self.addError(
                    try std.fmt.allocPrint(
                        self.allocator,
                        "Type mismatch in let declaration: declared {}, initialized with {}",
                        .{declared_type, init_type}
                    ),
                    let_decl.node.loc.line,
                    let_decl.node.loc.column,
                );
            }
            try self.variables.put(let_decl.name, declared_type);
        } else {
            // Infer type from initializer
            try self.variables.put(let_decl.name, init_type);
        }
    }

    /// Type check and register a function declaration
    fn checkFnDecl(self: *TypeChecker, fn_decl: *const ast.FnDecl) TypeCheckError!void {
        // Parse return type
        const return_type = if (fn_decl.return_type) |rt|
            try self.parseTypeAnnotation(rt)
        else
            .Void;

        // Parse parameter types
        var param_types = std.ArrayList(SimpleType).init(self.allocator);
        defer param_types.deinit();

        for (fn_decl.params) |param| {
            const param_type = if (param.type_annotation) |type_str|
                try self.parseTypeAnnotation(type_str)
            else
                .Unknown;
            try param_types.append(param_type);

            // Add parameters to variable scope
            try self.variables.put(param.name, param_type);
        }

        // Create function signature
        const return_type_ptr = try self.allocator.create(SimpleType);
        return_type_ptr.* = return_type;

        const func_sig = SimpleType.FunctionType{
            .param_types = try param_types.toOwnedSlice(),
            .return_type = return_type_ptr,
        };

        try self.functions.put(fn_decl.name, func_sig);

        // Set current function return type for checking return statements
        const old_return_type = self.current_function_return_type;
        self.current_function_return_type = return_type;

        // Check function body
        for (fn_decl.body.statements) |stmt| {
            try self.checkStatement(&stmt);
        }

        // Restore previous return type
        self.current_function_return_type = old_return_type;
    }

    /// Type check a return statement
    fn checkReturnStmt(self: *TypeChecker, ret: *const ast.ReturnStmt) TypeCheckError!void {
        const return_type = if (ret.value) |val|
            try self.checkExpression(&val)
        else
            .Void;

        if (self.current_function_return_type) |expected| {
            if (!return_type.equals(expected) and !return_type.equals(.Unknown)) {
                try self.addError(
                    try std.fmt.allocPrint(
                        self.allocator,
                        "Return type mismatch: expected {}, got {}",
                        .{expected, return_type}
                    ),
                    ret.node.loc.line,
                    ret.node.loc.column,
                );
            }
        }
    }

    /// Type check an if statement
    fn checkIfStmt(self: *TypeChecker, if_stmt: *const ast.IfStmt) TypeCheckError!void {
        const cond_type = try self.checkExpression(&if_stmt.condition);
        if (!cond_type.equals(.Bool)) {
            try self.addError(
                try std.fmt.allocPrint(
                    self.allocator,
                    "If condition must be bool, got {}",
                    .{cond_type}
                ),
                if_stmt.node.loc.line,
                if_stmt.node.loc.column,
            );
        }

        try self.checkBlock(if_stmt.then_block);
        if (if_stmt.else_block) |else_block| {
            try self.checkBlock(else_block);
        }
    }

    /// Type check a while statement
    fn checkWhileStmt(self: *TypeChecker, while_stmt: *const ast.WhileStmt) TypeCheckError!void {
        const cond_type = try self.checkExpression(&while_stmt.condition);
        if (!cond_type.equals(.Bool)) {
            try self.addError(
                try std.fmt.allocPrint(
                    self.allocator,
                    "While condition must be bool, got {}",
                    .{cond_type}
                ),
                while_stmt.node.loc.line,
                while_stmt.node.loc.column,
            );
        }

        try self.checkBlock(while_stmt.body);
    }

    /// Type check a for statement
    fn checkForStmt(self: *TypeChecker, for_stmt: *const ast.ForStmt) TypeCheckError!void {
        // Check range expression
        _ = try self.checkExpression(&for_stmt.iterable);

        // Add iterator variable (assume i32 for now)
        try self.variables.put(for_stmt.iterator, .I32);

        try self.checkBlock(for_stmt.body);
    }

    /// Type check a block
    fn checkBlock(self: *TypeChecker, block: *const ast.BlockStmt) TypeCheckError!void {
        for (block.statements) |stmt| {
            try self.checkStatement(&stmt);
        }
    }

    /// Register a struct declaration
    fn registerStruct(self: *TypeChecker, struct_decl: *const ast.StructDecl) TypeCheckError!void {
        var fields = std.StringHashMap(SimpleType).init(self.allocator);

        for (struct_decl.fields) |field| {
            const field_type = if (field.type_annotation) |type_str|
                try self.parseTypeAnnotation(type_str)
            else
                .Unknown;
            try fields.put(field.name, field_type);
        }

        try self.structs.put(struct_decl.name, fields);
    }

    /// Register an enum declaration
    fn registerEnum(self: *TypeChecker, enum_decl: *const ast.EnumDecl) TypeCheckError!void {
        try self.enums.put(enum_decl.name, {});
    }

    /// Type check the entire program
    pub fn checkProgram(self: *TypeChecker, program: *const ast.Program) TypeCheckError!void {
        for (program.statements) |stmt| {
            try self.checkStatement(&stmt);
        }
    }
};
