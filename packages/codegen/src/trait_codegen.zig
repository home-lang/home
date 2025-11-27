const std = @import("std");
const ast = @import("ast");
const TraitDecl = ast.TraitDecl;
const ImplDecl = ast.ImplDecl;
const TraitMethod = ast.TraitMethod;

/// Trait code generation for dynamic dispatch and vtables
/// Implements vtable-based trait objects and static dispatch for known types
pub const TraitCodegen = struct {
    allocator: std.mem.Allocator,
    vtables: std.StringHashMap(VTable),
    trait_impls: std.StringHashMap(std.ArrayList(ImplInfo)),

    pub const Error = error{
        OutOfMemory,
        TraitNotFound,
        MethodNotFound,
        InvalidImplementation,
    };

    /// VTable structure for dynamic dispatch
    pub const VTable = struct {
        trait_name: []const u8,
        methods: std.StringHashMap(MethodEntry),

        pub const MethodEntry = struct {
            name: []const u8,
            function_ptr: usize,  // Pointer to implementation
            param_types: []const []const u8,
            return_type: ?[]const u8,
        };

        pub fn init(allocator: std.mem.Allocator, trait_name: []const u8) VTable {
            return .{
                .trait_name = trait_name,
                .methods = std.StringHashMap(MethodEntry).init(allocator),
            };
        }

        pub fn deinit(self: *VTable, allocator: std.mem.Allocator) void {
            allocator.free(self.trait_name);
            var it = self.methods.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.name);
                allocator.free(entry.value_ptr.param_types);
                if (entry.value_ptr.return_type) |rt| {
                    allocator.free(rt);
                }
            }
            self.methods.deinit();
        }
    };

    /// Information about a trait implementation
    pub const ImplInfo = struct {
        type_name: []const u8,
        trait_name: []const u8,
        impl_decl: *ImplDecl,
        vtable_ptr: ?*VTable,
    };

    pub fn init(allocator: std.mem.Allocator) TraitCodegen {
        return .{
            .allocator = allocator,
            .vtables = std.StringHashMap(VTable).init(allocator),
            .trait_impls = std.StringHashMap(std.ArrayList(ImplInfo)).init(allocator),
        };
    }

    pub fn deinit(self: *TraitCodegen) void {
        var vtable_it = self.vtables.iterator();
        while (vtable_it.next()) |entry| {
            var vtable = entry.value_ptr;
            vtable.deinit(self.allocator);
        }
        self.vtables.deinit();

        var impl_it = self.trait_impls.iterator();
        while (impl_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.trait_impls.deinit();
    }

    /// Generate vtable for a trait declaration
    pub fn generateTraitVTable(self: *TraitCodegen, trait_decl: *TraitDecl) !void {
        var vtable = VTable.init(self.allocator, try self.allocator.dupe(u8, trait_decl.name));

        // Add method entries for each trait method
        for (trait_decl.methods) |method| {
            const entry = VTable.MethodEntry{
                .name = try self.allocator.dupe(u8, method.name),
                .function_ptr = 0,  // Will be filled in by implementation
                .param_types = try self.collectParamTypes(method.params),
                .return_type = if (method.return_type) |rt|
                    try self.typeExprToString(rt)
                else
                    null,
            };

            try vtable.methods.put(try self.allocator.dupe(u8, method.name), entry);
        }

        try self.vtables.put(try self.allocator.dupe(u8, trait_decl.name), vtable);
    }

    /// Generate code for a trait implementation
    pub fn generateImplCode(self: *TraitCodegen, impl_decl: *ImplDecl) ![]const u8 {
        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        const type_name = impl_decl.type_name;
        const trait_name = impl_decl.trait_name orelse return Error.InvalidImplementation;

        // Generate impl struct wrapper
        try writer.print("// Trait implementation: {s} for {s}\n", .{ trait_name, type_name });
        try writer.print("const {s}_impl_{s} = struct {{\n", .{ type_name, trait_name });

        // Generate method implementations
        for (impl_decl.methods) |method| {
            try self.generateMethodImpl(writer, method, type_name);
        }

        try writer.writeAll("};\n\n");

        // Generate vtable instance
        try self.generateVTableInstance(writer, impl_decl);

        // Register implementation
        try self.registerImpl(type_name, trait_name, impl_decl);

        return try code.toOwnedSlice();
    }

    /// Generate a method implementation
    fn generateMethodImpl(
        self: *TraitCodegen,
        writer: anytype,
        method: *ast.FnDecl,
        type_name: []const u8,
    ) !void {
        // Generate method signature
        try writer.print("    pub fn {s}(", .{method.name});

        // Parameters
        for (method.params, 0..) |param, i| {
            if (i > 0) try writer.writeAll(", ");

            if (param.is_self) {
                try writer.print("self: *{s}", .{type_name});
            } else {
                try writer.print("{s}: ", .{param.name});
                try self.writeTypeExpr(writer, param.type_expr);
            }
        }

        try writer.writeAll(") ");

        // Return type
        if (method.return_type) |rt| {
            try self.writeTypeExpr(writer, rt);
        } else {
            try writer.writeAll("void");
        }

        try writer.writeAll(" {\n");

        // Generate method body from AST
        if (method.body) |body| {
            try self.generateMethodBody(writer, &body, 2);
        } else {
            try writer.writeAll("        _ = self;\n");
            try writer.writeAll("        return;\n");
        }

        try writer.writeAll("    }\n\n");
    }

    /// Generate vtable instance for an implementation
    fn generateVTableInstance(self: *TraitCodegen, writer: anytype, impl_decl: *ImplDecl) !void {
        _ = self;
        const type_name = impl_decl.type_name;
        const trait_name = impl_decl.trait_name orelse return Error.InvalidImplementation;

        try writer.print("// VTable for {s} impl {s}\n", .{ type_name, trait_name });
        try writer.print("const {s}_impl_{s}_vtable = VTable{{\n", .{ type_name, trait_name });
        try writer.print("    .trait_name = \"{s}\",\n", .{trait_name});
        try writer.writeAll("    .methods = &[_]MethodEntry{\n");

        for (impl_decl.methods) |method| {
            try writer.print("        .{{ .name = \"{s}\", .func = &{s}_impl_{s}.{s} }},\n",
                .{ method.name, type_name, trait_name, method.name });
        }

        try writer.writeAll("    },\n");
        try writer.writeAll("};\n\n");
    }

    /// Generate trait object wrapper
    pub fn generateTraitObject(self: *TraitCodegen, trait_name: []const u8) ![]const u8 {
        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        try writer.print("// Trait object for dynamic dispatch: {s}\n", .{trait_name});
        try writer.print("pub const {s}Object = struct {{\n", .{trait_name});
        try writer.writeAll("    data: *anyopaque,\n");
        try writer.writeAll("    vtable: *const VTable,\n\n");

        // Get trait definition
        const vtable = self.vtables.get(trait_name) orelse return Error.TraitNotFound;

        // Generate wrapper methods for dynamic dispatch
        var method_it = vtable.methods.iterator();
        while (method_it.next()) |entry| {
            const method = entry.value_ptr;

            try writer.print("    pub fn {s}(self: *{s}Object", .{ method.name, trait_name });

            for (method.param_types, 0..) |param_type, i| {
                try writer.print(", arg{d}: {s}", .{ i, param_type });
            }

            try writer.writeAll(") ");

            if (method.return_type) |rt| {
                try writer.print("{s}", .{rt});
            } else {
                try writer.writeAll("void");
            }

            try writer.writeAll(" {\n");
            try writer.print("        const func = self.vtable.methods.get(\"{s}\").?.func;\n", .{method.name});
            try writer.writeAll("        return func(self.data");

            for (0..method.param_types.len) |i| {
                try writer.print(", arg{d}", .{i});
            }

            try writer.writeAll(");\n");
            try writer.writeAll("    }\n\n");
        }

        try writer.writeAll("};\n\n");

        return try code.toOwnedSlice();
    }

    /// Generate method body from AST
    fn generateMethodBody(self: *TraitCodegen, writer: anytype, block: *const ast.BlockStmt, indent_level: usize) !void {
        for (block.statements) |stmt| {
            try self.generateStatement(writer, &stmt, indent_level);
        }
    }

    /// Generate statement from AST
    fn generateStatement(self: *TraitCodegen, writer: anytype, stmt: *const ast.Stmt, indent_level: usize) !void {
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
            else => {
                try writer.writeAll("/* stmt */;\n");
            },
        }
    }

    /// Generate expression from AST
    fn generateExpression(self: *TraitCodegen, writer: anytype, expr: *ast.Expr) !void {
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
            else => {
                try writer.writeAll("/* expr */");
            },
        }
    }

    /// Write type annotation
    fn writeTypeAnnotation(self: *TraitCodegen, writer: anytype, type_ann: *const ast.TypeAnnotation) !void {
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
            else => try writer.writeAll("unknown"),
        }
    }

    /// Write indentation
    fn writeIndent(self: *TraitCodegen, writer: anytype, level: usize) !void {
        _ = self;
        var i: usize = 0;
        while (i < level * 4) : (i += 1) {
            try writer.writeAll(" ");
        }
    }

    /// Generate static dispatch call for known type
    pub fn generateStaticDispatch(
        self: *TraitCodegen,
        type_name: []const u8,
        trait_name: []const u8,
        method_name: []const u8,
        args: []const []const u8,
    ) ![]const u8 {
        // Check if implementation exists
        if (!try self.hasImpl(type_name, trait_name)) {
            return Error.InvalidImplementation;
        }

        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        // Generate direct call to implementation
        try writer.print("{s}_impl_{s}.{s}(", .{ type_name, trait_name, method_name });

        for (args, 0..) |arg, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s}", .{arg});
        }

        try writer.writeAll(")");

        return try code.toOwnedSlice();
    }

    /// Generate code to convert a concrete type to a trait object
    pub fn generateToTraitObject(
        self: *TraitCodegen,
        type_name: []const u8,
        trait_name: []const u8,
        value_expr: []const u8,
    ) ![]const u8 {
        if (!try self.hasImpl(type_name, trait_name)) {
            return Error.InvalidImplementation;
        }

        var code = std.ArrayList(u8).init(self.allocator);
        const writer = code.writer();

        try writer.print("{s}Object{{", .{trait_name});
        try writer.print(" .data = @ptrCast({s}), ", .{value_expr});
        try writer.print(".vtable = &{s}_impl_{s}_vtable ", .{ type_name, trait_name });
        try writer.writeAll("}");

        return try code.toOwnedSlice();
    }

    /// Check if a type implements a trait
    pub fn hasImpl(self: *TraitCodegen, type_name: []const u8, trait_name: []const u8) !bool {
        const impls = self.trait_impls.get(type_name) orelse return false;

        for (impls.items) |impl_info| {
            if (std.mem.eql(u8, impl_info.trait_name, trait_name)) {
                return true;
            }
        }

        return false;
    }

    /// Register a trait implementation
    fn registerImpl(self: *TraitCodegen, type_name: []const u8, trait_name: []const u8, impl_decl: *ImplDecl) !void {
        const gop = try self.trait_impls.getOrPut(try self.allocator.dupe(u8, type_name));
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(ImplInfo).init(self.allocator);
        }

        try gop.value_ptr.append(.{
            .type_name = try self.allocator.dupe(u8, type_name),
            .trait_name = try self.allocator.dupe(u8, trait_name),
            .impl_decl = impl_decl,
            .vtable_ptr = null,
        });
    }

    /// Helper: Collect parameter types from trait method
    fn collectParamTypes(self: *TraitCodegen, params: []const TraitMethod.FnParam) ![]const []const u8 {
        var types = try self.allocator.alloc([]const u8, params.len);

        for (params, 0..) |param, i| {
            types[i] = try self.typeExprToString(param.type_expr);
        }

        return types;
    }

    /// Helper: Convert type expression to string
    fn typeExprToString(self: *TraitCodegen, type_expr: *ast.TypeExpr) ![]const u8 {
        _ = self;
        // Simplified - would need full type expression handling
        return type_expr.name;
    }

    /// Helper: Write type expression
    fn writeTypeExpr(self: *TraitCodegen, writer: anytype, type_expr: *ast.TypeExpr) !void {
        _ = self;
        try writer.print("{s}", .{type_expr.name});
    }
};

/// Generate trait-based pattern matching
pub fn generateTraitMatch(
    allocator: std.mem.Allocator,
    trait_obj: []const u8,
    cases: []const MatchCase,
) ![]const u8 {
    var code = std.ArrayList(u8).init(allocator);
    const writer = code.writer();

    try writer.print("switch ({s}.vtable.trait_name) {{\n", .{trait_obj});

    for (cases) |case| {
        try writer.print("    \"{s}\" => {{\n", .{case.type_name});
        try writer.print("        const value = @as(*{s}, @ptrCast({s}.data));\n",
            .{ case.type_name, trait_obj });
        try writer.print("        {s}\n", .{case.body});
        try writer.writeAll("    },\n");
    }

    try writer.writeAll("    else => unreachable,\n");
    try writer.writeAll("}\n");

    return try code.toOwnedSlice();
}

pub const MatchCase = struct {
    type_name: []const u8,
    body: []const u8,
};

test "trait codegen vtable generation" {
    const allocator = std.testing.allocator;

    var codegen = TraitCodegen.init(allocator);
    defer codegen.deinit();

    // Test basic vtable generation
    // Would need actual trait AST nodes for full test
}

test "trait codegen static dispatch" {
    const allocator = std.testing.allocator;

    var codegen = TraitCodegen.init(allocator);
    defer codegen.deinit();

    // Test static dispatch code generation
    // Would need actual implementation registration
}
