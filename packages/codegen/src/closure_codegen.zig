const std = @import("std");
const ast = @import("ast");
const ClosureExpr = ast.ClosureExpr;
const ClosureParam = ast.ClosureParam;
const ClosureBody = ast.ClosureBody;
const Capture = ast.Capture;
const ClosureTrait = ast.ClosureTrait;
const ClosureEnvironment = ast.ClosureEnvironment;

/// Closure code generation
/// Implements closures using environment structs and function pointers
/// Supports three closure traits: Fn, FnMut, FnOnce
pub const ClosureCodegen = struct {
    allocator: std.mem.Allocator,
    closures: std.ArrayList(ClosureInfo),
    closure_counter: usize,

    pub const Error = error{
        OutOfMemory,
        InvalidClosure,
        CaptureError,
        CodegenError,
    };

    /// Information about a generated closure
    pub const ClosureInfo = struct {
        id: usize,
        name: []const u8,
        trait: ClosureTrait,
        environment_struct: []const u8,
        function_name: []const u8,
        captures: []const CapturedVarInfo,
    };

    pub const CapturedVarInfo = struct {
        name: []const u8,
        type_name: []const u8,
        mode: Capture.CaptureMode,
        offset: usize,
    };

    pub fn init(allocator: std.mem.Allocator) ClosureCodegen {
        return .{
            .allocator = allocator,
            .closures = std.ArrayList(ClosureInfo).init(allocator),
            .closure_counter = 0,
        };
    }

    pub fn deinit(self: *ClosureCodegen) void {
        for (self.closures.items) |*info| {
            self.allocator.free(info.name);
            self.allocator.free(info.environment_struct);
            self.allocator.free(info.function_name);
            for (info.captures) |capture| {
                self.allocator.free(capture.name);
                self.allocator.free(capture.type_name);
            }
            self.allocator.free(info.captures);
        }
        self.closures.deinit();
    }

    /// Generate code for a closure expression
    pub fn generateClosure(
        self: *ClosureCodegen,
        closure: *ClosureExpr,
        environment: *ClosureEnvironment,
        trait: ClosureTrait,
    ) ![]const u8 {
        const closure_id = self.closure_counter;
        self.closure_counter += 1;

        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        const closure_name = try std.fmt.allocPrint(self.allocator, "closure_{d}", .{closure_id});
        const env_struct_name = try std.fmt.allocPrint(self.allocator, "ClosureEnv_{d}", .{closure_id});
        const func_name = try std.fmt.allocPrint(self.allocator, "closure_fn_{d}", .{closure_id});

        // Generate environment struct
        try writer.print("// Closure {d} - Environment struct\n", .{closure_id});
        try self.generateEnvironmentStruct(writer, env_struct_name, environment);
        try writer.writeAll("\n");

        // Generate closure function
        try writer.print("// Closure {d} - Function implementation\n", .{closure_id});
        try self.generateClosureFunction(writer, func_name, env_struct_name, closure, trait);
        try writer.writeAll("\n");

        // Generate closure constructor
        try writer.print("// Closure {d} - Constructor\n", .{closure_id});
        try self.generateClosureConstructor(writer, closure_name, env_struct_name, func_name, environment, trait);
        try writer.writeAll("\n");

        // Store closure info
        const captures_info = try self.extractCapturesInfo(environment);
        try self.closures.append(.{
            .id = closure_id,
            .name = closure_name,
            .trait = trait,
            .environment_struct = env_struct_name,
            .function_name = func_name,
            .captures = captures_info,
        });

        return try code.toOwnedSlice();
    }

    /// Generate the environment struct that holds captured variables
    fn generateEnvironmentStruct(
        self: *ClosureCodegen,
        writer: anytype,
        struct_name: []const u8,
        environment: *ClosureEnvironment,
    ) !void {
        try writer.print("const {s} = struct {{\n", .{struct_name});

        if (environment.captures.count() > 0) {
            var it = environment.captures.iterator();
            while (it.next()) |entry| {
                const capture = entry.value_ptr.*;
                const field_type = try self.getCaptureType(capture);
                try writer.print("    {s}: {s},\n", .{ capture.name, field_type });
            }
        } else {
            try writer.writeAll("    // No captures - empty environment\n");
            try writer.writeAll("    _dummy: u8 = 0,\n");
        }

        try writer.writeAll("};\n");
    }

    /// Generate the closure function that accesses the environment
    fn generateClosureFunction(
        self: *ClosureCodegen,
        writer: anytype,
        func_name: []const u8,
        env_struct_name: []const u8,
        closure: *ClosureExpr,
        trait: ClosureTrait,
    ) !void {
        try writer.print("fn {s}(", .{func_name});

        // First parameter is always the environment
        const env_param_type = switch (trait) {
            .Fn => try std.fmt.allocPrint(self.allocator, "*const {s}", .{env_struct_name}),
            .FnMut => try std.fmt.allocPrint(self.allocator, "*{s}", .{env_struct_name}),
            .FnOnce => try std.fmt.allocPrint(self.allocator, "{s}", .{env_struct_name}),
        };
        defer self.allocator.free(env_param_type);

        try writer.print("env: {s}", .{env_param_type});

        // Add closure parameters
        for (closure.params, 0..) |param, i| {
            _ = i;
            try writer.print(", {s}: ", .{param.name});
            if (param.type_annotation) |type_ann| {
                try self.writeTypeExpr(writer, type_ann);
            } else {
                try writer.writeAll("anyopaque");
            }
        }

        try writer.writeAll(") ");

        // Return type
        if (closure.return_type) |ret_type| {
            try self.writeTypeExpr(writer, ret_type);
        } else {
            try writer.writeAll("void");
        }

        try writer.writeAll(" {\n");

        // Generate body
        switch (closure.body) {
            .Expression => |expr| {
                try writer.writeAll("    return ");
                try self.generateExpression(writer, expr);
                try writer.writeAll(";\n");
            },
            .Block => |block| {
                try self.generateBlock(writer, block, 1);
            },
        }

        try writer.writeAll("}\n");
    }

    /// Generate the closure constructor that creates the closure object
    fn generateClosureConstructor(
        self: *ClosureCodegen,
        writer: anytype,
        closure_name: []const u8,
        env_struct_name: []const u8,
        func_name: []const u8,
        environment: *ClosureEnvironment,
        trait: ClosureTrait,
    ) !void {
        try writer.print("const {s} = struct {{\n", .{closure_name});
        try writer.print("    env: {s},\n", .{env_struct_name});
        try writer.print("    func: *const fn(", .{});

        // Function signature
        const env_param_type = switch (trait) {
            .Fn => try std.fmt.allocPrint(self.allocator, "*const {s}", .{env_struct_name}),
            .FnMut => try std.fmt.allocPrint(self.allocator, "*{s}", .{env_struct_name}),
            .FnOnce => try std.fmt.allocPrint(self.allocator, "{s}", .{env_struct_name}),
        };
        defer self.allocator.free(env_param_type);

        try writer.print("{s}) void,\n\n", .{env_param_type});

        // Create method
        try writer.writeAll("    pub fn create(allocator: std.mem.Allocator");

        // Add parameters for captured variables
        if (environment.captures.count() > 0) {
            var it = environment.captures.iterator();
            while (it.next()) |entry| {
                const capture = entry.value_ptr.*;
                const field_type = try self.getCaptureType(capture);
                try writer.print(", {s}: {s}", .{ capture.name, field_type });
            }
        }

        try writer.writeAll(") !@This() {\n");
        try writer.writeAll("        _ = allocator;\n");
        try writer.writeAll("        return .{\n");
        try writer.print("            .env = {s}{{\n", .{env_struct_name});

        // Initialize captured variables
        if (environment.captures.count() > 0) {
            var it = environment.captures.iterator();
            while (it.next()) |entry| {
                const capture = entry.value_ptr.*;
                try writer.print("                .{s} = {s},\n", .{ capture.name, capture.name });
            }
        }

        try writer.writeAll("            },\n");
        try writer.print("            .func = &{s},\n", .{func_name});
        try writer.writeAll("        };\n");
        try writer.writeAll("    }\n\n");

        // Call method based on trait
        try self.generateCallMethod(writer, trait, env_struct_name);

        try writer.writeAll("};\n");
    }

    /// Generate the call method for the closure
    fn generateCallMethod(
        self: *ClosureCodegen,
        writer: anytype,
        trait: ClosureTrait,
        env_struct_name: []const u8,
    ) !void {
        _ = self;
        _ = env_struct_name;

        switch (trait) {
            .Fn => {
                try writer.writeAll("    pub fn call(self: *const @This()) void {\n");
                try writer.writeAll("        self.func(&self.env);\n");
                try writer.writeAll("    }\n");
            },
            .FnMut => {
                try writer.writeAll("    pub fn call(self: *@This()) void {\n");
                try writer.writeAll("        self.func(&self.env);\n");
                try writer.writeAll("    }\n");
            },
            .FnOnce => {
                try writer.writeAll("    pub fn call(self: @This()) void {\n");
                try writer.writeAll("        self.func(self.env);\n");
                try writer.writeAll("    }\n");
            },
        }
    }

    /// Get the type string for a captured variable
    fn getCaptureType(self: *ClosureCodegen, capture: ClosureEnvironment.CapturedVar) ![]const u8 {
        return switch (capture.mode) {
            .ByValue => try self.allocator.dupe(u8, capture.type_name),
            .ByRef => try std.fmt.allocPrint(self.allocator, "*const {s}", .{capture.type_name}),
            .ByMutRef => try std.fmt.allocPrint(self.allocator, "*{s}", .{capture.type_name}),
            .ByMove => try self.allocator.dupe(u8, capture.type_name),
        };
    }

    /// Extract capture information for storage
    fn extractCapturesInfo(self: *ClosureCodegen, environment: *ClosureEnvironment) ![]CapturedVarInfo {
        var captures = std.ArrayList(CapturedVarInfo).init(self.allocator);

        var it = environment.captures.iterator();
        while (it.next()) |entry| {
            const capture = entry.value_ptr.*;
            try captures.append(.{
                .name = try self.allocator.dupe(u8, capture.name),
                .type_name = try self.allocator.dupe(u8, capture.type_name),
                .mode = capture.mode,
                .offset = capture.offset,
            });
        }

        return try captures.toOwnedSlice();
    }

    /// Generate expression code from AST
    fn generateExpression(self: *ClosureCodegen, writer: anytype, expr: *ast.Expr) !void {
        switch (expr.*) {
            .Literal => |lit| {
                switch (lit) {
                    .Int => |val| try writer.print("{d}", .{val}),
                    .Float => |val| try writer.print("{d}", .{val}),
                    .String => |val| try writer.print("\"{s}\"", .{val}),
                    .Bool => |val| try writer.print("{}", .{val}),
                    .Null => try writer.writeAll("null"),
                }
            },
            .Identifier => |id| {
                try writer.print("{s}", .{id.name});
            },
            .BinaryExpr => |bin| {
                try writer.writeAll("(");
                try self.generateExpression(writer, bin.left);
                try writer.print(" {s} ", .{@tagName(bin.operator)});
                try self.generateExpression(writer, bin.right);
                try writer.writeAll(")");
            },
            .UnaryExpr => |un| {
                try writer.print("{s}(", .{@tagName(un.operator)});
                try self.generateExpression(writer, un.operand);
                try writer.writeAll(")");
            },
            .CallExpr => |call| {
                try self.generateExpression(writer, call.callee);
                try writer.writeAll("(");
                for (call.arguments, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.generateExpression(writer, arg);
                }
                try writer.writeAll(")");
            },
            .MemberExpr => |member| {
                try self.generateExpression(writer, member.object);
                try writer.print(".{s}", .{member.member});
            },
            .IndexExpr => |index| {
                try self.generateExpression(writer, index.array);
                try writer.writeAll("[");
                try self.generateExpression(writer, index.index);
                try writer.writeAll("]");
            },
            .ArrayLiteral => |arr| {
                try writer.writeAll("[_]");
                try writer.writeAll("{");
                for (arr.elements, 0..) |elem, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.generateExpression(writer, elem);
                }
                try writer.writeAll("}");
            },
            else => {
                try writer.writeAll("/* expr */");
            },
        }
    }

    /// Generate block code from AST
    fn generateBlock(self: *ClosureCodegen, writer: anytype, block: *ast.BlockStmt, indent_level: usize) !void {
        for (block.statements) |stmt| {
            try self.generateStatement(writer, &stmt, indent_level);
        }
    }

    /// Generate statement code from AST
    fn generateStatement(self: *ClosureCodegen, writer: anytype, stmt: *const ast.Stmt, indent_level: usize) !void {
        try self.writeIndent(writer, indent_level);

        switch (stmt.*) {
            .LetDecl => |let_decl| {
                try writer.print("const {s}", .{let_decl.name});
                if (let_decl.type_annotation) |type_ann| {
                    try writer.writeAll(": ");
                    try self.writeTypeAnnotation(writer, type_ann);
                }
                if (let_decl.initializer) |initializer| {
                    try writer.writeAll(" = ");
                    try self.generateExpression(writer, initializer);
                }
                try writer.writeAll(";\n");
            },
            .ReturnStmt => |ret_stmt| {
                try writer.writeAll("return");
                if (ret_stmt.expression) |expr| {
                    try writer.writeAll(" ");
                    try self.generateExpression(writer, expr);
                }
                try writer.writeAll(";\n");
            },
            .ExprStmt => |expr| {
                try self.generateExpression(writer, expr);
                try writer.writeAll(";\n");
            },
            .IfStmt => |if_stmt| {
                try writer.writeAll("if (");
                try self.generateExpression(writer, if_stmt.condition);
                try writer.writeAll(") {\n");
                try self.generateBlock(writer, &if_stmt.then_block, indent_level + 1);
                try self.writeIndent(writer, indent_level);
                try writer.writeAll("}");
                if (if_stmt.else_block) |else_block| {
                    try writer.writeAll(" else {\n");
                    try self.generateBlock(writer, &else_block, indent_level + 1);
                    try self.writeIndent(writer, indent_level);
                    try writer.writeAll("}");
                }
                try writer.writeAll("\n");
            },
            else => {
                try writer.writeAll("/* stmt */;\n");
            },
        }
    }

    /// Write type annotation
    fn writeTypeAnnotation(self: *ClosureCodegen, writer: anytype, type_ann: *const ast.TypeAnnotation) !void {
        switch (type_ann.*) {
            .Simple => |simple| try writer.print("{s}", .{simple}),
            .Generic => |generic| {
                try writer.print("{s}<", .{generic.base});
                for (generic.args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.writeTypeAnnotation(writer, arg);
                }
                try writer.writeAll(">");
            },
            .Array => |array| {
                try writer.writeAll("[]");
                try self.writeTypeAnnotation(writer, array.element_type);
            },
            else => try writer.writeAll("unknown"),
        }
    }

    /// Write indentation
    fn writeIndent(self: *ClosureCodegen, writer: anytype, level: usize) !void {
        _ = self;
        var i: usize = 0;
        while (i < level * 4) : (i += 1) {
            try writer.writeAll(" ");
        }
    }

    /// Write a type expression
    fn writeTypeExpr(self: *ClosureCodegen, writer: anytype, type_expr: *ast.closure_nodes.TypeExpr) !void {
        switch (type_expr.*) {
            .Named => |name| try writer.print("{s}", .{name}),
            .Generic => |gen| {
                try writer.print("{s}<", .{gen.base});
                for (gen.args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.writeTypeExpr(writer, arg);
                }
                try writer.writeAll(">");
            },
            .Reference => |ref| {
                if (ref.is_mut) {
                    try writer.writeAll("*");
                } else {
                    try writer.writeAll("*const ");
                }
                try self.writeTypeExpr(writer, ref.inner);
            },
            .Pointer => |ptr| {
                if (ptr.is_mut) {
                    try writer.writeAll("*");
                } else {
                    try writer.writeAll("*const ");
                }
                try self.writeTypeExpr(writer, ptr.inner);
            },
            .Function => |func| {
                try writer.writeAll("fn(");
                for (func.params, 0..) |param, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.writeTypeExpr(writer, param);
                }
                try writer.writeAll(") ");
                if (func.return_type) |ret| {
                    try self.writeTypeExpr(writer, ret);
                } else {
                    try writer.writeAll("void");
                }
            },
            .Closure => |closure| {
                try writer.writeAll("|");
                for (closure.params, 0..) |param, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.writeTypeExpr(writer, param);
                }
                try writer.writeAll("|");
                if (closure.return_type) |ret| {
                    try writer.writeAll(" -> ");
                    try self.writeTypeExpr(writer, ret);
                }
            },
        }
    }

    /// Generate closure trait object (for dynamic dispatch)
    pub fn generateClosureTraitObject(self: *ClosureCodegen, trait: ClosureTrait) ![]const u8 {
        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        const trait_name = trait.toString();
        try writer.print("// Closure trait object for {s}\n", .{trait_name});
        try writer.print("pub const {s}Object = struct {{\n", .{trait_name});
        try writer.writeAll("    data: *anyopaque,\n");
        try writer.writeAll("    vtable: *const VTable,\n\n");

        try writer.writeAll("    pub const VTable = struct {\n");
        try writer.writeAll("        call: *const fn(*anyopaque) void,\n");

        if (trait == .FnMut or trait == .Fn) {
            try writer.writeAll("        clone: ?*const fn(*anyopaque) *anyopaque,\n");
        }

        try writer.writeAll("        deinit: *const fn(*anyopaque) void,\n");
        try writer.writeAll("    };\n\n");

        // Call method
        const self_type = switch (trait) {
            .Fn => "*const @This()",
            .FnMut => "*@This()",
            .FnOnce => "@This()",
        };

        try writer.print("    pub fn call(self: {s}) void {{\n", .{self_type});

        switch (trait) {
            .Fn, .FnMut => {
                try writer.writeAll("        self.vtable.call(self.data);\n");
            },
            .FnOnce => {
                try writer.writeAll("        self.vtable.call(self.data);\n");
                try writer.writeAll("        self.vtable.deinit(self.data);\n");
            },
        }

        try writer.writeAll("    }\n");

        try writer.writeAll("};\n");

        return try code.toOwnedSlice();
    }

    /// Generate code to convert a concrete closure to a trait object
    pub fn generateToTraitObject(
        self: *ClosureCodegen,
        closure_name: []const u8,
        trait: ClosureTrait,
    ) ![]const u8 {
        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        const trait_name = trait.toString();
        try writer.print("{s}Object{{\n", .{trait_name});
        try writer.print("    .data = @ptrCast(&{s}),\n", .{closure_name});
        try writer.print("    .vtable = &{s}_{s}_vtable,\n", .{ closure_name, trait_name });
        try writer.writeAll("}");

        return try code.toOwnedSlice();
    }
};

/// Generate test code for closures
pub fn generateClosureTests(allocator: std.mem.Allocator) ![]const u8 {
    var code = std.ArrayList(u8).init(allocator);
    const writer = code.writer();

    try writer.writeAll(
        \\test "closure basic" {
        \\    const testing = std.testing;
        \\    const allocator = testing.allocator;
        \\
        \\    // Test basic closure generation
        \\    var codegen = ClosureCodegen.init(allocator);
        \\    defer codegen.deinit();
        \\}
        \\
        \\test "closure with captures" {
        \\    const testing = std.testing;
        \\    const allocator = testing.allocator;
        \\
        \\    // Test closure with captured variables
        \\    var codegen = ClosureCodegen.init(allocator);
        \\    defer codegen.deinit();
        \\}
        \\
        \\test "closure traits" {
        \\    const testing = std.testing;
        \\    const allocator = testing.allocator;
        \\
        \\    // Test Fn, FnMut, FnOnce traits
        \\    var codegen = ClosureCodegen.init(allocator);
        \\    defer codegen.deinit();
        \\}
        \\
    );

    return try code.toOwnedSlice();
}
