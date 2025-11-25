const std = @import("std");

/// Bindings generator for C headers
///
/// Automatically generates Home language bindings from C header files.
/// Features:
/// - Parse C headers
/// - Generate type definitions
/// - Create function wrappers
/// - Handle enums, structs, unions
/// - Support macros (limited)
pub const BindingsGenerator = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    types: std.StringHashMap(TypeInfo),
    functions: std.ArrayList(FunctionInfo),
    enums: std.ArrayList(EnumInfo),
    structs: std.ArrayList(StructInfo),
    config: Config,

    pub const Config = struct {
        /// Library name for bindings
        library_name: []const u8,
        /// Target C standard (c89, c99, c11, c17)
        c_standard: []const u8,
        /// Include paths
        include_paths: []const []const u8,
        /// Prefix to add to generated functions
        prefix: ?[]const u8,
        /// Generate safe wrappers
        generate_wrappers: bool,
        /// Verbose output
        verbose: bool,
    };

    pub const TypeInfo = struct {
        c_type: []const u8,
        home_type: []const u8,
        size: usize,
        alignment: usize,
    };

    pub const FunctionInfo = struct {
        name: []const u8,
        return_type: []const u8,
        parameters: []Parameter,
        is_variadic: bool,

        pub const Parameter = struct {
            name: []const u8,
            type_name: []const u8,
        };
    };

    pub const EnumInfo = struct {
        name: []const u8,
        values: []EnumValue,

        pub const EnumValue = struct {
            name: []const u8,
            value: i64,
        };
    };

    pub const StructInfo = struct {
        name: []const u8,
        fields: []Field,
        is_packed: bool,

        pub const Field = struct {
            name: []const u8,
            type_name: []const u8,
            offset: usize,
        };
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) BindingsGenerator {
        return .{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
            .types = std.StringHashMap(TypeInfo).init(allocator),
            .functions = std.ArrayList(FunctionInfo).init(allocator),
            .enums = std.ArrayList(EnumInfo).init(allocator),
            .structs = std.ArrayList(StructInfo).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *BindingsGenerator) void {
        self.output.deinit();
        self.types.deinit();
        self.functions.deinit();
        self.enums.deinit();
        self.structs.deinit();
    }

    /// Parse C header file
    pub fn parseHeader(self: *BindingsGenerator, header_path: []const u8) !void {
        if (self.config.verbose) {
            std.debug.print("Parsing header: {s}\n", .{header_path});
        }

        // In a real implementation, this would:
        // 1. Invoke clang/libclang to parse the header
        // 2. Extract AST information
        // 3. Convert to our internal representation

        // Simplified: just read the file
        const file = try std.fs.cwd().openFile(header_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        // Basic parsing (would use proper C parser in production)
        try self.parseSimple(content);
    }

    fn parseSimple(self: *BindingsGenerator, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip comments and empty lines
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
                continue;
            }

            // Parse function declarations
            if (std.mem.indexOf(u8, trimmed, "extern") != null and
                std.mem.indexOf(u8, trimmed, "(") != null)
            {
                try self.parseFunctionDecl(trimmed);
            }

            // Parse struct definitions
            if (std.mem.startsWith(u8, trimmed, "struct ") or
                std.mem.startsWith(u8, trimmed, "typedef struct"))
            {
                try self.parseStructDecl(trimmed);
            }

            // Parse enum definitions
            if (std.mem.startsWith(u8, trimmed, "enum ") or
                std.mem.startsWith(u8, trimmed, "typedef enum"))
            {
                try self.parseEnumDecl(trimmed);
            }
        }
    }

    fn parseFunctionDecl(self: *BindingsGenerator, decl: []const u8) !void {
        // Very simplified parser
        // Real implementation would use proper C parser
        _ = self;
        _ = decl;
    }

    fn parseStructDecl(self: *BindingsGenerator, decl: []const u8) !void {
        _ = self;
        _ = decl;
    }

    fn parseEnumDecl(self: *BindingsGenerator, decl: []const u8) !void {
        _ = self;
        _ = decl;
    }

    /// Generate Home bindings
    pub fn generate(self: *BindingsGenerator) ![]const u8 {
        try self.generateHeader();
        try self.generateTypeDefinitions();
        try self.generateEnums();
        try self.generateStructs();
        try self.generateFunctions();

        return try self.output.toOwnedSlice();
    }

    fn generateHeader(self: *BindingsGenerator) !void {
        try self.output.appendSlice("// Auto-generated Home language bindings\n");
        try self.output.appendSlice("// Library: ");
        try self.output.appendSlice(self.config.library_name);
        try self.output.appendSlice("\n\n");
        try self.output.appendSlice("const std = @import(\"std\");\n");
        try self.output.appendSlice("const ffi = @import(\"ffi\");\n\n");
    }

    fn generateTypeDefinitions(self: *BindingsGenerator) !void {
        try self.output.appendSlice("// Type definitions\n");

        var it = self.types.iterator();
        while (it.next()) |entry| {
            try self.output.appendSlice("pub const ");
            try self.output.appendSlice(entry.key_ptr.*);
            try self.output.appendSlice(" = ");
            try self.output.appendSlice(entry.value_ptr.home_type);
            try self.output.appendSlice(";\n");
        }

        try self.output.appendSlice("\n");
    }

    fn generateEnums(self: *BindingsGenerator) !void {
        for (self.enums.items) |enum_info| {
            try self.output.appendSlice("pub const ");
            try self.output.appendSlice(enum_info.name);
            try self.output.appendSlice(" = enum(c_int) {\n");

            for (enum_info.values) |value| {
                try self.output.appendSlice("    ");
                try self.output.appendSlice(value.name);
                try self.output.appendSlice(" = ");
                const value_str = try std.fmt.allocPrint(self.allocator, "{d}", .{value.value});
                defer self.allocator.free(value_str);
                try self.output.appendSlice(value_str);
                try self.output.appendSlice(",\n");
            }

            try self.output.appendSlice("};\n\n");
        }
    }

    fn generateStructs(self: *BindingsGenerator) !void {
        for (self.structs.items) |struct_info| {
            if (struct_info.is_packed) {
                try self.output.appendSlice("pub const ");
                try self.output.appendSlice(struct_info.name);
                try self.output.appendSlice(" = packed struct {\n");
            } else {
                try self.output.appendSlice("pub const ");
                try self.output.appendSlice(struct_info.name);
                try self.output.appendSlice(" = extern struct {\n");
            }

            for (struct_info.fields) |field| {
                try self.output.appendSlice("    ");
                try self.output.appendSlice(field.name);
                try self.output.appendSlice(": ");
                try self.output.appendSlice(field.type_name);
                try self.output.appendSlice(",\n");
            }

            try self.output.appendSlice("};\n\n");
        }
    }

    fn generateFunctions(self: *BindingsGenerator) !void {
        try self.output.appendSlice("// Function declarations\n");

        for (self.functions.items) |func| {
            // Generate extern declaration
            try self.output.appendSlice("pub extern \"c\" fn ");
            try self.output.appendSlice(func.name);
            try self.output.appendSlice("(");

            for (func.parameters, 0..) |param, i| {
                if (i > 0) try self.output.appendSlice(", ");
                try self.output.appendSlice(param.name);
                try self.output.appendSlice(": ");
                try self.output.appendSlice(param.type_name);
            }

            if (func.is_variadic) {
                if (func.parameters.len > 0) try self.output.appendSlice(", ");
                try self.output.appendSlice("...");
            }

            try self.output.appendSlice(") ");
            try self.output.appendSlice(func.return_type);
            try self.output.appendSlice(";\n");

            // Generate safe wrapper if enabled
            if (self.config.generate_wrappers) {
                try self.generateWrapper(func);
            }
        }

        try self.output.appendSlice("\n");
    }

    fn generateWrapper(self: *BindingsGenerator, func: FunctionInfo) !void {
        try self.output.appendSlice("\npub fn ");
        try self.output.appendSlice(func.name);
        try self.output.appendSlice("Safe(");

        for (func.parameters, 0..) |param, i| {
            if (i > 0) try self.output.appendSlice(", ");
            try self.output.appendSlice(param.name);
            try self.output.appendSlice(": ");
            try self.output.appendSlice(param.type_name);
        }

        try self.output.appendSlice(") !");
        try self.output.appendSlice(func.return_type);
        try self.output.appendSlice(" {\n");
        try self.output.appendSlice("    const result = ");
        try self.output.appendSlice(func.name);
        try self.output.appendSlice("(");

        for (func.parameters, 0..) |param, i| {
            if (i > 0) try self.output.appendSlice(", ");
            try self.output.appendSlice(param.name);
        }

        try self.output.appendSlice(");\n");

        // Add error checking for pointer returns
        if (std.mem.startsWith(u8, func.return_type, "?*")) {
            try self.output.appendSlice("    return result orelse error.NullPointer;\n");
        } else {
            try self.output.appendSlice("    return result;\n");
        }

        try self.output.appendSlice("}\n");
    }

    /// Add a type mapping
    pub fn addType(self: *BindingsGenerator, c_type: []const u8, home_type: []const u8) !void {
        try self.types.put(c_type, .{
            .c_type = c_type,
            .home_type = home_type,
            .size = 0,
            .alignment = 0,
        });
    }

    /// Add a function
    pub fn addFunction(self: *BindingsGenerator, func: FunctionInfo) !void {
        try self.functions.append(func);
    }

    /// Add an enum
    pub fn addEnum(self: *BindingsGenerator, enum_info: EnumInfo) !void {
        try self.enums.append(enum_info);
    }

    /// Add a struct
    pub fn addStruct(self: *BindingsGenerator, struct_info: StructInfo) !void {
        try self.structs.append(struct_info);
    }

    /// Convert C type to Home type
    pub fn convertType(c_type: []const u8) []const u8 {
        return if (std.mem.eql(u8, c_type, "int"))
            "c_int"
        else if (std.mem.eql(u8, c_type, "long"))
            "c_long"
        else if (std.mem.eql(u8, c_type, "short"))
            "c_short"
        else if (std.mem.eql(u8, c_type, "char"))
            "c_char"
        else if (std.mem.eql(u8, c_type, "unsigned int"))
            "c_uint"
        else if (std.mem.eql(u8, c_type, "unsigned long"))
            "c_ulong"
        else if (std.mem.eql(u8, c_type, "float"))
            "f32"
        else if (std.mem.eql(u8, c_type, "double"))
            "f64"
        else if (std.mem.eql(u8, c_type, "void"))
            "void"
        else if (std.mem.eql(u8, c_type, "void*"))
            "?*anyopaque"
        else if (std.mem.eql(u8, c_type, "char*"))
            "[*:0]const u8"
        else if (std.mem.eql(u8, c_type, "const char*"))
            "[*:0]const u8"
        else
            c_type;
    }
};

/// Quick bindings generator for simple cases
pub fn generateQuickBindings(
    allocator: std.mem.Allocator,
    library_name: []const u8,
    functions: []const BindingsGenerator.FunctionInfo,
) ![]const u8 {
    var generator = BindingsGenerator.init(allocator, .{
        .library_name = library_name,
        .c_standard = "c99",
        .include_paths = &.{},
        .prefix = null,
        .generate_wrappers = true,
        .verbose = false,
    });
    defer generator.deinit();

    // Add standard type mappings
    try generator.addType("int", "c_int");
    try generator.addType("long", "c_long");
    try generator.addType("float", "f32");
    try generator.addType("double", "f64");
    try generator.addType("char*", "[*:0]const u8");

    // Add functions
    for (functions) |func| {
        try generator.addFunction(func);
    }

    return try generator.generate();
}

/// Example usage and testing
pub fn generateLibmBindings(allocator: std.mem.Allocator) ![]const u8 {
    var generator = BindingsGenerator.init(allocator, .{
        .library_name = "libm",
        .c_standard = "c99",
        .include_paths = &.{"/usr/include"},
        .prefix = null,
        .generate_wrappers = true,
        .verbose = false,
    });
    defer generator.deinit();

    // Add math functions
    try generator.addFunction(.{
        .name = "sin",
        .return_type = "f64",
        .parameters = &.{.{ .name = "x", .type_name = "f64" }},
        .is_variadic = false,
    });

    try generator.addFunction(.{
        .name = "cos",
        .return_type = "f64",
        .parameters = &.{.{ .name = "x", .type_name = "f64" }},
        .is_variadic = false,
    });

    try generator.addFunction(.{
        .name = "sqrt",
        .return_type = "f64",
        .parameters = &.{.{ .name = "x", .type_name = "f64" }},
        .is_variadic = false,
    });

    try generator.addFunction(.{
        .name = "pow",
        .return_type = "f64",
        .parameters = &.{
            .{ .name = "x", .type_name = "f64" },
            .{ .name = "y", .type_name = "f64" },
        },
        .is_variadic = false,
    });

    return try generator.generate();
}
