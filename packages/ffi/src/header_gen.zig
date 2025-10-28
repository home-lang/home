// Home Programming Language - C Header Generation
// Automatically generate C header files from Home code for FFI

const std = @import("std");
const Basics = @import("basics");

// ============================================================================
// Header Generator
// ============================================================================

pub const HeaderGen = struct {
    allocator: Basics.Allocator,
    writer: std.ArrayList(u8).Writer,
    buffer: std.ArrayList(u8),
    indent_level: usize,

    pub fn init(allocator: Basics.Allocator) HeaderGen {
        var buffer = std.ArrayList(u8).init(allocator);
        return .{
            .allocator = allocator,
            .writer = buffer.writer(),
            .buffer = buffer,
            .indent_level = 0,
        };
    }

    pub fn deinit(self: *HeaderGen) void {
        self.buffer.deinit();
    }

    pub fn toSlice(self: *HeaderGen) []const u8 {
        return self.buffer.items;
    }

    // ========================================================================
    // High-Level API
    // ========================================================================

    pub fn generate(self: *HeaderGen, config: HeaderConfig) !void {
        try self.writeHeader(config);
        try self.writeIncludes(config.includes);
        try self.writeDefines(config.defines);
        try self.writeTypedefs(config.typedefs);
        try self.writeStructs(config.structs);
        try self.writeFunctions(config.functions);
        try self.writeFooter(config);
    }

    // ========================================================================
    // Header Components
    // ========================================================================

    fn writeHeader(self: *HeaderGen, config: HeaderConfig) !void {
        try self.writeLine("// Auto-generated C header from Home code");
        try self.writeLine("// DO NOT EDIT MANUALLY");
        try self.writeLine("");

        const guard = try std.fmt.allocPrint(
            self.allocator,
            "{s}_H",
            .{config.guard_name},
        );
        defer self.allocator.free(guard);

        try self.writeLineFmt("#ifndef {s}", .{guard});
        try self.writeLineFmt("#define {s}", .{guard});
        try self.writeLine("");

        try self.writeLine("#ifdef __cplusplus");
        try self.writeLine("extern \"C\" {");
        try self.writeLine("#endif");
        try self.writeLine("");
    }

    fn writeIncludes(self: *HeaderGen, includes: []const []const u8) !void {
        if (includes.len == 0) return;

        try self.writeLine("// Includes");
        for (includes) |inc| {
            try self.writeLineFmt("#include <{s}>", .{inc});
        }
        try self.writeLine("");
    }

    fn writeDefines(self: *HeaderGen, defines: []const Define) !void {
        if (defines.len == 0) return;

        try self.writeLine("// Defines");
        for (defines) |def| {
            try self.writeLineFmt("#define {s} {s}", .{ def.name, def.value });
        }
        try self.writeLine("");
    }

    fn writeTypedefs(self: *HeaderGen, typedefs: []const Typedef) !void {
        if (typedefs.len == 0) return;

        try self.writeLine("// Type definitions");
        for (typedefs) |td| {
            try self.writeLineFmt("typedef {s} {s};", .{ td.c_type, td.name });
        }
        try self.writeLine("");
    }

    fn writeStructs(self: *HeaderGen, structs: []const Struct) !void {
        if (structs.len == 0) return;

        try self.writeLine("// Structures");
        for (structs) |s| {
            try self.writeStruct(s);
        }
    }

    fn writeStruct(self: *HeaderGen, s: Struct) !void {
        if (s.is_packed) {
            try self.writeLineFmt("typedef struct __attribute__((packed)) {s} {{", .{s.name});
        } else {
            try self.writeLineFmt("typedef struct {s} {{", .{s.name});
        }

        self.indent_level += 1;
        for (s.fields) |field| {
            try self.writeIndented();
            try self.writeLineFmt("{s} {s};", .{ field.c_type, field.name });
        }
        self.indent_level -= 1;

        try self.writeLineFmt("}} {s};", .{s.name});
        try self.writeLine("");
    }

    fn writeFunctions(self: *HeaderGen, functions: []const Function) !void {
        if (functions.len == 0) return;

        try self.writeLine("// Functions");
        for (functions) |func| {
            try self.writeFunction(func);
        }
    }

    fn writeFunction(self: *HeaderGen, func: Function) !void {
        // Build parameter list
        var params = std.ArrayList(u8).init(self.allocator);
        defer params.deinit();

        if (func.params.len == 0) {
            try params.appendSlice("void");
        } else {
            for (func.params, 0..) |param, i| {
                if (i > 0) try params.appendSlice(", ");
                try params.writer().print("{s} {s}", .{ param.c_type, param.name });
            }

            if (func.is_variadic) {
                try params.appendSlice(", ...");
            }
        }

        // Write function declaration
        try self.writeLineFmt("{s} {s}({s});", .{
            func.return_type,
            func.name,
            params.items,
        });
    }

    fn writeFooter(self: *HeaderGen, config: HeaderConfig) !void {
        try self.writeLine("");
        try self.writeLine("#ifdef __cplusplus");
        try self.writeLine("}");
        try self.writeLine("#endif");
        try self.writeLine("");

        const guard = try std.fmt.allocPrint(
            self.allocator,
            "{s}_H",
            .{config.guard_name},
        );
        defer self.allocator.free(guard);

        try self.writeLineFmt("#endif // {s}", .{guard});
    }

    // ========================================================================
    // Utility Functions
    // ========================================================================

    fn writeLine(self: *HeaderGen, line: []const u8) !void {
        try self.writer.writeAll(line);
        try self.writer.writeByte('\n');
    }

    fn writeLineFmt(self: *HeaderGen, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
        try self.writer.writeByte('\n');
    }

    fn writeIndented(self: *HeaderGen) !void {
        var i: usize = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.writer.writeAll("    ");
        }
    }
};

// ============================================================================
// Configuration Types
// ============================================================================

pub const HeaderConfig = struct {
    guard_name: []const u8,
    includes: []const []const u8 = &.{},
    defines: []const Define = &.{},
    typedefs: []const Typedef = &.{},
    structs: []const Struct = &.{},
    functions: []const Function = &.{},
};

pub const Define = struct {
    name: []const u8,
    value: []const u8,
};

pub const Typedef = struct {
    name: []const u8,
    c_type: []const u8,
};

pub const Struct = struct {
    name: []const u8,
    fields: []const Field,
    is_packed: bool = false,
};

pub const Field = struct {
    name: []const u8,
    c_type: []const u8,
};

pub const Function = struct {
    name: []const u8,
    return_type: []const u8,
    params: []const Parameter,
    is_variadic: bool = false,
};

pub const Parameter = struct {
    name: []const u8,
    c_type: []const u8,
};

// ============================================================================
// Helper Functions
// ============================================================================

pub fn generateHeader(allocator: Basics.Allocator, config: HeaderConfig) ![]const u8 {
    var gen = HeaderGen.init(allocator);
    defer gen.deinit();

    try gen.generate(config);

    // Duplicate the buffer content before deinit
    return try allocator.dupe(u8, gen.toSlice());
}

// ============================================================================
// Type Mapping
// ============================================================================

pub const TypeMap = struct {
    /// Convert Zig type to C type string
    pub fn toCType(comptime T: type) []const u8 {
        const info = @typeInfo(T);
        return switch (info) {
            .Int => |int_info| switch (int_info.signedness) {
                .signed => switch (int_info.bits) {
                    8 => "int8_t",
                    16 => "int16_t",
                    32 => "int32_t",
                    64 => "int64_t",
                    else => "intptr_t",
                },
                .unsigned => switch (int_info.bits) {
                    8 => "uint8_t",
                    16 => "uint16_t",
                    32 => "uint32_t",
                    64 => "uint64_t",
                    else => "uintptr_t",
                },
            },
            .Float => |float_info| switch (float_info.bits) {
                32 => "float",
                64 => "double",
                else => "long double",
            },
            .Bool => "bool",
            .Pointer => "void*",
            .Void => "void",
            else => "void*",
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "header generation" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = HeaderConfig{
        .guard_name = "MY_HEADER",
        .includes = &.{ "stdint.h", "stdbool.h" },
        .defines = &.{
            .{ .name = "VERSION", .value = "1" },
        },
        .typedefs = &.{
            .{ .name = "my_int", .c_type = "int32_t" },
        },
        .structs = &.{
            .{
                .name = "Point",
                .fields = &.{
                    .{ .name = "x", .c_type = "int32_t" },
                    .{ .name = "y", .c_type = "int32_t" },
                },
            },
        },
        .functions = &.{
            .{
                .name = "add",
                .return_type = "int32_t",
                .params = &.{
                    .{ .name = "a", .c_type = "int32_t" },
                    .{ .name = "b", .c_type = "int32_t" },
                },
            },
        },
    };

    const header = try generateHeader(allocator, config);
    defer allocator.free(header);

    try testing.expect(header.len > 0);
    try testing.expect(std.mem.indexOf(u8, header, "#ifndef MY_HEADER_H") != null);
    try testing.expect(std.mem.indexOf(u8, header, "typedef struct Point") != null);
    try testing.expect(std.mem.indexOf(u8, header, "int32_t add") != null);
}

test "type mapping" {
    const testing = std.testing;

    try testing.expectEqualStrings("int32_t", TypeMap.toCType(i32));
    try testing.expectEqualStrings("uint64_t", TypeMap.toCType(u64));
    try testing.expectEqualStrings("float", TypeMap.toCType(f32));
    try testing.expectEqualStrings("double", TypeMap.toCType(f64));
    try testing.expectEqualStrings("bool", TypeMap.toCType(bool));
}
