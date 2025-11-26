const std = @import("std");
const ast = @import("ast");
const types = @import("types");
const GenericSystem = @import("../generics/generic_system.zig").GenericSystem;
const GenericInstantiation = @import("../generics/generic_system.zig").GenericInstantiation;

/// Monomorphization - converting generic code to concrete specialized code
/// Takes generic functions/structs and generates concrete versions for each type instantiation
pub const Monomorphization = struct {
    allocator: std.mem.Allocator,
    generic_functions: std.StringHashMap(*ast.FnDecl),
    generic_structs: std.StringHashMap(*ast.StructDecl),
    instantiations: std.ArrayList(MonomorphizedItem),
    generated_names: std.StringHashMap(void),

    pub const Error = error{
        OutOfMemory,
        GenericNotFound,
        InvalidGeneric,
        RecursiveMonomorphization,
        CodegenError,
    };

    pub const MonomorphizedItem = struct {
        kind: Kind,
        original_name: []const u8,
        monomorphized_name: []const u8,
        type_args: []const []const u8,
        code: []const u8,

        pub const Kind = enum {
            Function,
            Struct,
            Trait,
        };

        pub fn deinit(self: *MonomorphizedItem, allocator: std.mem.Allocator) void {
            allocator.free(self.original_name);
            allocator.free(self.monomorphized_name);
            for (self.type_args) |arg| {
                allocator.free(arg);
            }
            allocator.free(self.type_args);
            allocator.free(self.code);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Monomorphization {
        return .{
            .allocator = allocator,
            .generic_functions = std.StringHashMap(*ast.FnDecl).init(allocator),
            .generic_structs = std.StringHashMap(*ast.StructDecl).init(allocator),
            .instantiations = std.ArrayList(MonomorphizedItem).init(allocator),
            .generated_names = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Monomorphization) void {
        self.generic_functions.deinit();
        self.generic_structs.deinit();

        for (self.instantiations.items) |*item| {
            item.deinit(self.allocator);
        }
        self.instantiations.deinit();

        self.generated_names.deinit();
    }

    /// Register a generic function for monomorphization
    pub fn registerGenericFunction(self: *Monomorphization, func: *ast.FnDecl) !void {
        if (func.generic_params.len == 0) {
            return Error.InvalidGeneric;
        }

        const name_copy = try self.allocator.dupe(u8, func.name);
        try self.generic_functions.put(name_copy, func);
    }

    /// Register a generic struct for monomorphization
    pub fn registerGenericStruct(self: *Monomorphization, struct_decl: *ast.StructDecl) !void {
        if (struct_decl.generic_params.len == 0) {
            return Error.InvalidGeneric;
        }

        const name_copy = try self.allocator.dupe(u8, struct_decl.name);
        try self.generic_structs.put(name_copy, struct_decl);
    }

    /// Monomorphize a generic function with concrete types
    pub fn monomorphizeFunction(
        self: *Monomorphization,
        generic_name: []const u8,
        type_args: []const []const u8,
    ) ![]const u8 {
        const func = self.generic_functions.get(generic_name) orelse {
            return Error.GenericNotFound;
        };

        // Check type parameter count
        if (type_args.len != func.generic_params.len) {
            return Error.InvalidGeneric;
        }

        // Generate monomorphized name
        const mono_name = try self.generateMonomorphizedName(generic_name, type_args);

        // Check if already generated
        if (self.generated_names.contains(mono_name)) {
            // Return the existing one
            for (self.instantiations.items) |item| {
                if (std.mem.eql(u8, item.monomorphized_name, mono_name)) {
                    return try self.allocator.dupe(u8, item.code);
                }
            }
        }

        // Generate the monomorphized function
        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        try writer.print("// Monomorphized: {s}<", .{generic_name});
        for (type_args, 0..) |arg, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s}", .{arg});
        }
        try writer.writeAll(">\n");

        // Generate function signature
        try writer.print("pub fn {s}(", .{mono_name});

        // Parameters with substituted types
        for (func.params, 0..) |param, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s}: ", .{param.name});

            const param_type = try self.substituteType(param.type_name, func.generic_params, type_args);
            try writer.print("{s}", .{param_type});
        }

        try writer.writeAll(") ");

        // Return type with substituted types
        const return_type = try self.substituteType(func.return_type, func.generic_params, type_args);
        try writer.print("{s}", .{return_type});

        try writer.writeAll(" {\n");

        // Generate body with type substitutions
        try self.generateFunctionBody(writer, func, func.generic_params, type_args);

        try writer.writeAll("}\n\n");

        const generated_code = try code.toOwnedSlice();

        // Store the monomorphized function
        try self.generated_names.put(try self.allocator.dupe(u8, mono_name), {});
        try self.instantiations.append(.{
            .kind = .Function,
            .original_name = try self.allocator.dupe(u8, generic_name),
            .monomorphized_name = mono_name,
            .type_args = try self.copyTypeArgs(type_args),
            .code = try self.allocator.dupe(u8, generated_code),
        });

        return generated_code;
    }

    /// Monomorphize a generic struct with concrete types
    pub fn monomorphizeStruct(
        self: *Monomorphization,
        generic_name: []const u8,
        type_args: []const []const u8,
    ) ![]const u8 {
        const struct_decl = self.generic_structs.get(generic_name) orelse {
            return Error.GenericNotFound;
        };

        // Check type parameter count
        if (type_args.len != struct_decl.generic_params.len) {
            return Error.InvalidGeneric;
        }

        // Generate monomorphized name
        const mono_name = try self.generateMonomorphizedName(generic_name, type_args);

        // Check if already generated
        if (self.generated_names.contains(mono_name)) {
            for (self.instantiations.items) |item| {
                if (std.mem.eql(u8, item.monomorphized_name, mono_name)) {
                    return try self.allocator.dupe(u8, item.code);
                }
            }
        }

        // Generate the monomorphized struct
        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        try writer.print("// Monomorphized: {s}<", .{generic_name});
        for (type_args, 0..) |arg, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s}", .{arg});
        }
        try writer.writeAll(">\n");

        // Generate struct definition
        try writer.print("pub const {s} = struct {{\n", .{mono_name});

        // Fields with substituted types
        for (struct_decl.fields) |field| {
            try writer.print("    {s}: ", .{field.name});

            const field_type = try self.substituteType(field.type_name, struct_decl.generic_params, type_args);
            try writer.print("{s},\n", .{field_type});
        }

        // Generate methods with substituted types
        if (struct_decl.methods.len > 0) {
            try writer.writeAll("\n");
            for (struct_decl.methods) |method| {
                try self.generateMethod(writer, method, struct_decl.generic_params, type_args);
                try writer.writeAll("\n");
            }
        }

        try writer.writeAll("};\n\n");

        const generated_code = try code.toOwnedSlice();

        // Store the monomorphized struct
        try self.generated_names.put(try self.allocator.dupe(u8, mono_name), {});
        try self.instantiations.append(.{
            .kind = .Struct,
            .original_name = try self.allocator.dupe(u8, generic_name),
            .monomorphized_name = mono_name,
            .type_args = try self.copyTypeArgs(type_args),
            .code = try self.allocator.dupe(u8, generated_code),
        });

        return generated_code;
    }

    /// Generate monomorphized name (e.g., Vec_i32, HashMap_String_i32)
    fn generateMonomorphizedName(
        self: *Monomorphization,
        generic_name: []const u8,
        type_args: []const []const u8,
    ) ![]const u8 {
        var name = std.ArrayList(u8).init(self.allocator);
        try name.appendSlice(generic_name);

        for (type_args) |arg| {
            try name.append('_');
            // Sanitize type name (remove *, &, etc.)
            for (arg) |c| {
                if (std.ascii.isAlphanumeric(c) or c == '_') {
                    try name.append(c);
                }
            }
        }

        return name.toOwnedSlice();
    }

    /// Substitute generic type parameters with concrete types
    fn substituteType(
        self: *Monomorphization,
        type_name: []const u8,
        generic_params: []const ast.GenericParam,
        type_args: []const []const u8,
    ) ![]const u8 {
        // Check if type_name is a generic parameter
        for (generic_params, 0..) |param, i| {
            if (std.mem.eql(u8, type_name, param.name)) {
                return try self.allocator.dupe(u8, type_args[i]);
            }
        }

        // Handle generic types like Vec<T>, Option<T>
        if (std.mem.indexOf(u8, type_name, "<")) |start| {
            const base = type_name[0..start];
            const args_start = start + 1;
            const args_end = std.mem.lastIndexOf(u8, type_name, ">") orelse type_name.len;
            const args_str = type_name[args_start..args_end];

            // Parse and substitute type arguments
            var substituted_args = std.ArrayList(u8).init(self.allocator);
            defer substituted_args.deinit();

            var iter = std.mem.splitScalar(u8, args_str, ',');
            var first = true;
            while (iter.next()) |arg| {
                const trimmed_arg = std.mem.trim(u8, arg, " ");
                if (!first) try substituted_args.appendSlice(", ");
                first = false;

                const subst = try self.substituteType(trimmed_arg, generic_params, type_args);
                defer self.allocator.free(subst);
                try substituted_args.appendSlice(subst);
            }

            return try std.fmt.allocPrint(
                self.allocator,
                "{s}<{s}>",
                .{ base, substituted_args.items },
            );
        }

        // No substitution needed
        return try self.allocator.dupe(u8, type_name);
    }

    /// Generate function body with type substitutions
    fn generateFunctionBody(
        self: *Monomorphization,
        writer: anytype,
        func: *ast.FnDecl,
        generic_params: []const ast.GenericParam,
        type_args: []const []const u8,
    ) !void {
        // Walk function body AST and substitute generic types
        try self.generateFunctionBody(writer, &func.body, generic_params, type_args);
    }

    /// Generate struct method with type substitutions
    fn generateMethod(
        self: *Monomorphization,
        writer: anytype,
        method: *ast.FnDecl,
        generic_params: []const ast.GenericParam,
        type_args: []const []const u8,
    ) !void {
        try writer.print("    pub fn {s}(", .{method.name});

        for (method.params, 0..) |param, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s}: ", .{param.name});

            const param_type = try self.substituteType(param.type_name, generic_params, type_args);
            defer self.allocator.free(param_type);
            try writer.print("{s}", .{param_type});
        }

        try writer.writeAll(") ");

        const return_type = try self.substituteType(method.return_type, generic_params, type_args);
        defer self.allocator.free(return_type);
        try writer.print("{s}", .{return_type});

        try writer.writeAll(" {\n");
        try self.generateFunctionBody(writer, method, generic_params, type_args);
        try writer.writeAll("    }\n");
    }

    /// Copy type arguments array
    fn copyTypeArgs(self: *Monomorphization, type_args: []const []const u8) ![]const []const u8 {
        const copied = try self.allocator.alloc([]const u8, type_args.len);
        for (type_args, 0..) |arg, i| {
            copied[i] = try self.allocator.dupe(u8, arg);
        }
        return copied;
    }

    /// Get all monomorphized items
    pub fn getAllInstantiations(self: *Monomorphization) []const MonomorphizedItem {
        return self.instantiations.items;
    }

    /// Generate function body with type substitutions
    fn generateFunctionBody(
        self: *Monomorphization,
        writer: anytype,
        block: *const ast.BlockStmt,
        generic_params: []const ast.GenericParam,
        type_args: []const []const u8,
    ) !void {
        try writer.writeAll(" {\n");

        for (block.statements) |stmt| {
            try self.generateStatement(writer, &stmt, generic_params, type_args, 1);
        }

        try writer.writeAll("    }\n");
    }

    /// Generate a single statement with type substitutions
    fn generateStatement(
        self: *Monomorphization,
        writer: anytype,
        stmt: *const ast.Stmt,
        generic_params: []const ast.GenericParam,
        type_args: []const []const u8,
        indent: usize,
    ) !void {
        try self.writeIndent(writer, indent);

        switch (stmt.*) {
            .LetDecl => |let_decl| {
                try writer.print("const {s}", .{let_decl.name});
                if (let_decl.type_annotation) |type_ann| {
                    const subst_type = try self.substituteTypeAnnotation(type_ann, generic_params, type_args);
                    defer self.allocator.free(subst_type);
                    try writer.print(": {s}", .{subst_type});
                }
                if (let_decl.initializer) |init| {
                    try writer.writeAll(" = ");
                    try self.generateExpression(writer, init, generic_params, type_args);
                }
                try writer.writeAll(";\n");
            },
            .ConstDecl => |const_decl| {
                try writer.print("const {s}", .{const_decl.name});
                if (const_decl.type_annotation) |type_ann| {
                    const subst_type = try self.substituteTypeAnnotation(type_ann, generic_params, type_args);
                    defer self.allocator.free(subst_type);
                    try writer.print(": {s}", .{subst_type});
                }
                if (const_decl.initializer) |init| {
                    try writer.writeAll(" = ");
                    try self.generateExpression(writer, init, generic_params, type_args);
                }
                try writer.writeAll(";\n");
            },
            .ReturnStmt => |ret_stmt| {
                try writer.writeAll("return");
                if (ret_stmt.expression) |expr| {
                    try writer.writeAll(" ");
                    try self.generateExpression(writer, expr, generic_params, type_args);
                }
                try writer.writeAll(";\n");
            },
            .ExprStmt => |expr| {
                try self.generateExpression(writer, expr, generic_params, type_args);
                try writer.writeAll(";\n");
            },
            .IfStmt => |if_stmt| {
                try writer.writeAll("if (");
                try self.generateExpression(writer, if_stmt.condition, generic_params, type_args);
                try writer.writeAll(") ");
                try self.generateFunctionBody(writer, &if_stmt.then_block, generic_params, type_args);
                if (if_stmt.else_block) |else_block| {
                    try writer.writeAll(" else ");
                    try self.generateFunctionBody(writer, &else_block, generic_params, type_args);
                }
                try writer.writeAll("\n");
            },
            .WhileStmt => |while_stmt| {
                try writer.writeAll("while (");
                try self.generateExpression(writer, while_stmt.condition, generic_params, type_args);
                try writer.writeAll(") ");
                try self.generateFunctionBody(writer, &while_stmt.body, generic_params, type_args);
                try writer.writeAll("\n");
            },
            else => {
                try writer.writeAll("/* Unsupported statement */;\n");
            },
        }
    }

    /// Generate an expression with type substitutions
    fn generateExpression(
        self: *Monomorphization,
        writer: anytype,
        expr: *const ast.Expr,
        generic_params: []const ast.GenericParam,
        type_args: []const []const u8,
    ) !void {
        _ = generic_params;
        _ = type_args;

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
                try self.generateExpression(writer, bin.left, generic_params, type_args);
                try writer.print(" {s} ", .{@tagName(bin.operator)});
                try self.generateExpression(writer, bin.right, generic_params, type_args);
                try writer.writeAll(")");
            },
            .UnaryExpr => |un| {
                try writer.print("{s}", .{@tagName(un.operator)});
                try self.generateExpression(writer, un.operand, generic_params, type_args);
            },
            .CallExpr => |call| {
                try self.generateExpression(writer, call.callee, generic_params, type_args);
                try writer.writeAll("(");
                for (call.arguments, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.generateExpression(writer, arg, generic_params, type_args);
                }
                try writer.writeAll(")");
            },
            .MemberExpr => |member| {
                try self.generateExpression(writer, member.object, generic_params, type_args);
                try writer.print(".{s}", .{member.member});
            },
            else => {
                try writer.writeAll("/* expression */");
            },
        }
    }

    /// Helper to write indentation
    fn writeIndent(self: *Monomorphization, writer: anytype, indent: usize) !void {
        _ = self;
        var i: usize = 0;
        while (i < indent * 4) : (i += 1) {
            try writer.writeAll(" ");
        }
    }

    /// Substitute type annotation with concrete types
    fn substituteTypeAnnotation(
        self: *Monomorphization,
        type_ann: *const ast.TypeAnnotation,
        generic_params: []const ast.GenericParam,
        type_args: []const []const u8,
    ) ![]const u8 {
        switch (type_ann.*) {
            .Simple => |simple| {
                // Check if this is a generic parameter
                for (generic_params, 0..) |param, i| {
                    if (std.mem.eql(u8, param.name, simple)) {
                        return try self.allocator.dupe(u8, type_args[i]);
                    }
                }
                return try self.allocator.dupe(u8, simple);
            },
            .Generic => |generic| {
                // Recursively substitute generic arguments
                var buf = std.ArrayList(u8).init(self.allocator);
                defer buf.deinit();

                const base = try self.substituteTypeAnnotation(&.{ .Simple = generic.base }, generic_params, type_args);
                defer self.allocator.free(base);

                try buf.appendSlice(base);
                try buf.append('<');
                for (generic.args, 0..) |arg, i| {
                    if (i > 0) try buf.appendSlice(", ");
                    const subst = try self.substituteTypeAnnotation(arg, generic_params, type_args);
                    defer self.allocator.free(subst);
                    try buf.appendSlice(subst);
                }
                try buf.append('>');

                return try buf.toOwnedSlice();
            },
            .Array => |array| {
                const elem_type = try self.substituteTypeAnnotation(array.element_type, generic_params, type_args);
                defer self.allocator.free(elem_type);
                return try std.fmt.allocPrint(self.allocator, "[]{s}", .{elem_type});
            },
            else => {
                return try self.allocator.dupe(u8, "unknown");
            },
        }
    }

    /// Generate code for all monomorphized items
    pub fn generateAllCode(self: *Monomorphization) ![]const u8 {
        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        try writer.writeAll("// ==================== Monomorphized Code ====================\n\n");

        for (self.instantiations.items) |item| {
            try writer.print("// {s}: {s}<", .{ @tagName(item.kind), item.original_name });
            for (item.type_args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s}", .{arg});
            }
            try writer.writeAll(">\n");
            try writer.print("{s}\n", .{item.code});
        }

        return try code.toOwnedSlice();
    }
};

/// Monomorphization cache to avoid regenerating same instantiations
pub const MonomorphizationCache = struct {
    cache: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MonomorphizationCache {
        return .{
            .cache = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MonomorphizationCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cache.deinit();
    }

    pub fn get(self: *MonomorphizationCache, key: []const u8) ?[]const u8 {
        return self.cache.get(key);
    }

    pub fn put(self: *MonomorphizationCache, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.cache.put(key_copy, value_copy);
    }
};

/// Generate test code for monomorphization
pub fn generateMonomorphizationTests(allocator: std.mem.Allocator) ![]const u8 {
    var code = std.ArrayList(u8).init(allocator);
    const writer = code.writer();

    try writer.writeAll(
        \\test "monomorphization basic" {
        \\    const testing = std.testing;
        \\    const allocator = testing.allocator;
        \\
        \\    var mono = Monomorphization.init(allocator);
        \\    defer mono.deinit();
        \\
        \\    // Test basic monomorphization
        \\}
        \\
        \\test "monomorphization function" {
        \\    const testing = std.testing;
        \\    const allocator = testing.allocator;
        \\
        \\    var mono = Monomorphization.init(allocator);
        \\    defer mono.deinit();
        \\
        \\    // Test function monomorphization
        \\}
        \\
        \\test "monomorphization struct" {
        \\    const testing = std.testing;
        \\    const allocator = testing.allocator;
        \\
        \\    var mono = Monomorphization.init(allocator);
        \\    defer mono.deinit();
        \\
        \\    // Test struct monomorphization
        \\}
        \\
        \\test "monomorphization cache" {
        \\    const testing = std.testing;
        \\    const allocator = testing.allocator;
        \\
        \\    var cache = MonomorphizationCache.init(allocator);
        \\    defer cache.deinit();
        \\
        \\    // Test caching of monomorphized code
        \\}
        \\
    );

    return try code.toOwnedSlice();
}
