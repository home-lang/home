const std = @import("std");
const ast = @import("ast");
const comptime_mod = @import("comptime.zig");

/// Reflection API for Ion types and values
pub const Reflection = struct {
    allocator: std.mem.Allocator,
    type_database: TypeDatabase,

    pub const TypeDatabase = struct {
        structs: std.StringHashMap(StructMetadata),
        enums: std.StringHashMap(EnumMetadata),
        functions: std.StringHashMap(FunctionMetadata),

        pub const StructMetadata = struct {
            name: []const u8,
            fields: []FieldMetadata,
            size: usize,
            alignment: usize,
            generic_params: []const []const u8,
        };

        pub const FieldMetadata = struct {
            name: []const u8,
            type_name: []const u8,
            offset: usize,
            is_public: bool,
        };

        pub const EnumMetadata = struct {
            name: []const u8,
            variants: []VariantMetadata,
            underlying_type: []const u8,
        };

        pub const VariantMetadata = struct {
            name: []const u8,
            value: i64,
        };

        pub const FunctionMetadata = struct {
            name: []const u8,
            params: []ParamMetadata,
            return_type: []const u8,
            generic_params: []const []const u8,
            is_async: bool,
        };

        pub const ParamMetadata = struct {
            name: []const u8,
            type_name: []const u8,
        };

        pub fn init(allocator: std.mem.Allocator) TypeDatabase {
            return .{
                .structs = std.StringHashMap(StructMetadata).init(allocator),
                .enums = std.StringHashMap(EnumMetadata).init(allocator),
                .functions = std.StringHashMap(FunctionMetadata).init(allocator),
            };
        }

        pub fn deinit(self: *TypeDatabase) void {
            self.structs.deinit();
            self.enums.deinit();
            self.functions.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) Reflection {
        return .{
            .allocator = allocator,
            .type_database = TypeDatabase.init(allocator),
        };
    }

    pub fn deinit(self: *Reflection) void {
        self.type_database.deinit();
    }

    /// Build type metadata from AST
    pub fn buildMetadata(self: *Reflection, program: *ast.Program) !void {
        for (program.statements) |stmt| {
            try self.analyzeStatement(stmt);
        }
    }

    fn analyzeStatement(self: *Reflection, stmt: *ast.Stmt) !void {
        switch (stmt.*) {
            .StructDecl => |struct_decl| {
                var fields = try std.ArrayList(TypeDatabase.FieldMetadata).initCapacity(
                    self.allocator,
                    struct_decl.fields.len,
                );
                defer fields.deinit();

                var offset: usize = 0;
                for (struct_decl.fields) |field| {
                    try fields.append(.{
                        .name = field.name,
                        .type_name = field.type_name,
                        .offset = offset,
                        .is_public = true, // Ion doesn't have visibility modifiers yet
                    });
                    // Simplistic offset calculation (would need proper alignment)
                    offset += 8; // Assume 8 bytes per field for now
                }

                const metadata = TypeDatabase.StructMetadata{
                    .name = struct_decl.name,
                    .fields = try fields.toOwnedSlice(),
                    .size = offset,
                    .alignment = 8,
                    .generic_params = struct_decl.type_params,
                };

                try self.type_database.structs.put(struct_decl.name, metadata);
            },

            .EnumDecl => |enum_decl| {
                var variants = try std.ArrayList(TypeDatabase.VariantMetadata).initCapacity(
                    self.allocator,
                    enum_decl.variants.len,
                );
                defer variants.deinit();

                for (enum_decl.variants, 0..) |variant, i| {
                    try variants.append(.{
                        .name = variant,
                        .value = @intCast(i),
                    });
                }

                const metadata = TypeDatabase.EnumMetadata{
                    .name = enum_decl.name,
                    .variants = try variants.toOwnedSlice(),
                    .underlying_type = "int",
                };

                try self.type_database.enums.put(enum_decl.name, metadata);
            },

            .FnDecl => |fn_decl| {
                var params = try std.ArrayList(TypeDatabase.ParamMetadata).initCapacity(
                    self.allocator,
                    fn_decl.params.len,
                );
                defer params.deinit();

                for (fn_decl.params) |param| {
                    try params.append(.{
                        .name = param.name,
                        .type_name = param.type_name,
                    });
                }

                const metadata = TypeDatabase.FunctionMetadata{
                    .name = fn_decl.name,
                    .params = try params.toOwnedSlice(),
                    .return_type = fn_decl.return_type orelse "void",
                    .generic_params = fn_decl.type_params,
                    .is_async = fn_decl.is_async,
                };

                try self.type_database.functions.put(fn_decl.name, metadata);
            },

            else => {},
        }
    }

    /// Get struct metadata by name
    pub fn getStructMetadata(self: *Reflection, name: []const u8) ?TypeDatabase.StructMetadata {
        return self.type_database.structs.get(name);
    }

    /// Get enum metadata by name
    pub fn getEnumMetadata(self: *Reflection, name: []const u8) ?TypeDatabase.EnumMetadata {
        return self.type_database.enums.get(name);
    }

    /// Get function metadata by name
    pub fn getFunctionMetadata(self: *Reflection, name: []const u8) ?TypeDatabase.FunctionMetadata {
        return self.type_database.functions.get(name);
    }

    /// List all struct names
    pub fn listStructs(self: *Reflection, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8).init(allocator);
        defer names.deinit();

        var it = self.type_database.structs.keyIterator();
        while (it.next()) |key| {
            try names.append(key.*);
        }

        return try names.toOwnedSlice();
    }

    /// List all enum names
    pub fn listEnums(self: *Reflection, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8).init(allocator);
        defer names.deinit();

        var it = self.type_database.enums.keyIterator();
        while (it.next()) |key| {
            try names.append(key.*);
        }

        return try names.toOwnedSlice();
    }

    /// List all function names
    pub fn listFunctions(self: *Reflection, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8).init(allocator);
        defer names.deinit();

        var it = self.type_database.functions.keyIterator();
        while (it.next()) |key| {
            try names.append(key.*);
        }

        return try names.toOwnedSlice();
    }

    /// Generate code based on type metadata
    pub fn generateCode(
        self: *Reflection,
        template: CodeTemplate,
        type_name: []const u8,
    ) ![]const u8 {
        return switch (template) {
            .ToString => try self.generateToString(type_name),
            .Deserialize => try self.generateDeserialize(type_name),
            .Builder => try self.generateBuilder(type_name),
        };
    }

    pub const CodeTemplate = enum {
        ToString,
        Deserialize,
        Builder,
    };

    fn generateToString(self: *Reflection, type_name: []const u8) ![]const u8 {
        const metadata = self.getStructMetadata(type_name) orelse return error.TypeNotFound;

        var code = std.ArrayList(u8).init(self.allocator);
        defer code.deinit();

        const writer = code.writer();

        try writer.print("fn toString(self: *const {s}) -> string {{\n", .{metadata.name});
        try writer.writeAll("    let result = \"\";\n");
        try writer.print("    result += \"{s} {{ \";\n", .{metadata.name});

        for (metadata.fields, 0..) |field, i| {
            if (i > 0) {
                try writer.writeAll("    result += \", \";\n");
            }
            try writer.print("    result += \"{s}: \" + self.{s}.toString();\n", .{ field.name, field.name });
        }

        try writer.writeAll("    result += \" }\";\n");
        try writer.writeAll("    return result;\n");
        try writer.writeAll("}\n");

        return try code.toOwnedSlice();
    }

    fn generateDeserialize(self: *Reflection, type_name: []const u8) ![]const u8 {
        const metadata = self.getStructMetadata(type_name) orelse return error.TypeNotFound;

        var code = std.ArrayList(u8).init(self.allocator);
        defer code.deinit();

        const writer = code.writer();

        try writer.print("fn deserialize(json: string) -> {s} {{\n", .{metadata.name});
        try writer.print("    let result = {s} {{}};\n", .{metadata.name});

        for (metadata.fields) |field| {
            try writer.print("    result.{s} = parseField(json, \"{s}\");\n", .{ field.name, field.name });
        }

        try writer.writeAll("    return result;\n");
        try writer.writeAll("}\n");

        return try code.toOwnedSlice();
    }

    fn generateBuilder(self: *Reflection, type_name: []const u8) ![]const u8 {
        const metadata = self.getStructMetadata(type_name) orelse return error.TypeNotFound;

        var code = std.ArrayList(u8).init(self.allocator);
        defer code.deinit();

        const writer = code.writer();

        try writer.print("struct {s}Builder {{\n", .{metadata.name});

        for (metadata.fields) |field| {
            try writer.print("    {s}: {s},\n", .{ field.name, field.type_name });
        }

        try writer.writeAll("\n");

        // Setter methods
        for (metadata.fields) |field| {
            try writer.print("    fn with_{s}(self: *{s}Builder, value: {s}) -> *{s}Builder {{\n", .{
                field.name,
                metadata.name,
                field.type_name,
                metadata.name,
            });
            try writer.print("        self.{s} = value;\n", .{field.name});
            try writer.writeAll("        return self;\n");
            try writer.writeAll("    }\n\n");
        }

        // Build method
        try writer.print("    fn build(self: *{s}Builder) -> {s} {{\n", .{ metadata.name, metadata.name });
        try writer.print("        return {s} {{\n", .{metadata.name});

        for (metadata.fields) |field| {
            try writer.print("            {s}: self.{s},\n", .{ field.name, field.name });
        }

        try writer.writeAll("        };\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("}\n");

        return try code.toOwnedSlice();
    }
};
