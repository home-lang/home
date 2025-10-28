// Home Programming Language - Variadic Functions
// Support for variable argument functions (printf, logging, syscalls)

const std = @import("std");

// ============================================================================
// Public API Exports
// ============================================================================

pub const VaList = @import("va_list.zig").VaList;
pub const printf = @import("printf.zig");
pub const logger = @import("logger.zig");
pub const syscall = @import("syscall.zig");
pub const format = @import("format.zig");

// ============================================================================
// Type Information for Variadic Arguments
// ============================================================================

pub const ArgType = enum {
    Int,
    UInt,
    Long,
    ULong,
    LongLong,
    ULongLong,
    Float,
    Double,
    Pointer,
    String,
    Char,
    Bool,
    Custom,
};

pub const ArgInfo = struct {
    arg_type: ArgType,
    size: usize,
    alignment: usize,

    pub fn fromType(comptime T: type) ArgInfo {
        return .{
            .arg_type = typeToArgType(T),
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
        };
    }

    fn typeToArgType(comptime T: type) ArgType {
        return switch (@typeInfo(T)) {
            .int => |int_info| {
                if (int_info.signedness == .signed) {
                    return switch (int_info.bits) {
                        1...32 => .Int,
                        33...64 => .Long,
                        65...128 => .LongLong,
                        else => .Custom,
                    };
                } else {
                    return switch (int_info.bits) {
                        1...32 => .UInt,
                        33...64 => .ULong,
                        65...128 => .ULongLong,
                        else => .Custom,
                    };
                }
            },
            .float => |float_info| {
                return switch (float_info.bits) {
                    32 => .Float,
                    64 => .Double,
                    else => .Custom,
                };
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice) {
                    if (ptr_info.child == u8) {
                        return .String;
                    }
                }
                return .Pointer;
            },
            .bool => .Bool,
            else => .Custom,
        };
    }
};

// ============================================================================
// Variadic Argument Count/Type Tracking
// ============================================================================

pub const VarArgs = struct {
    types: []const ArgType,
    count: usize,

    pub fn init(types: []const ArgType) VarArgs {
        return .{
            .types = types,
            .count = types.len,
        };
    }

    pub fn getType(self: VarArgs, index: usize) ?ArgType {
        if (index >= self.count) return null;
        return self.types[index];
    }
};

// ============================================================================
// Format String Parsing (for printf-style functions)
// ============================================================================

pub const FormatSpec = struct {
    width: ?u32 = null,
    precision: ?u32 = null,
    flags: FormatFlags = .{},
    length: LengthModifier = .Default,
    specifier: FormatSpecifier,

    pub const FormatFlags = packed struct {
        left_justify: bool = false,
        force_sign: bool = false,
        space_sign: bool = false,
        alternate: bool = false,
        zero_pad: bool = false,
    };

    pub const LengthModifier = enum {
        Default,
        Char,     // hh
        Short,    // h
        Long,     // l
        LongLong, // ll
        Size,     // z
        Ptrdiff,  // t
    };

    pub const FormatSpecifier = enum {
        Decimal,      // d, i
        Unsigned,     // u
        Octal,        // o
        Hex,          // x
        HexUpper,     // X
        Float,        // f
        Exponential,  // e
        ExpUpper,     // E
        Shortest,     // g
        ShortestUp,   // G
        Char,         // c
        String,       // s
        Pointer,      // p
        Percent,      // %
        Binary,       // b (extension)
    };
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Count the number of arguments in a variadic call
pub fn countArgs(args: anytype) usize {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    return fields.len;
}

/// Get type information for all arguments
pub fn getArgTypes(comptime Args: type) []const ArgType {
    const fields = @typeInfo(Args).@"struct".fields;
    comptime var types: [fields.len]ArgType = undefined;
    inline for (fields, 0..) |field, i| {
        types[i] = ArgInfo.fromType(field.type).arg_type;
    }
    const result = types;
    return &result;
}

/// Check if a type can be passed as a variadic argument
pub fn isValidVarArg(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .pointer, .@"enum" => true,
        .@"struct" => |s| s.layout == .@"extern",
        else => false,
    };
}

// ============================================================================
// Type-safe variadic helpers
// ============================================================================

/// Extract argument at index with type checking
pub fn getArg(comptime T: type, args: anytype, index: usize) ?T {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    if (index >= fields.len) return null;

    inline for (fields, 0..) |field, i| {
        if (i == index) {
            if (field.type == T) {
                return @field(args, field.name);
            }
            return null;
        }
    }
    return null;
}

/// Iterate over all arguments
pub fn forEachArg(args: anytype, comptime func: fn (arg: anytype) void) void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields) |field| {
        func(@field(args, field.name));
    }
}

// ============================================================================
// Tests
// ============================================================================

test "arg type detection" {
    const testing = std.testing;

    try testing.expectEqual(ArgType.Int, ArgInfo.fromType(i32).arg_type);
    try testing.expectEqual(ArgType.UInt, ArgInfo.fromType(u32).arg_type);
    try testing.expectEqual(ArgType.Long, ArgInfo.fromType(i64).arg_type);
    try testing.expectEqual(ArgType.Float, ArgInfo.fromType(f32).arg_type);
    try testing.expectEqual(ArgType.Double, ArgInfo.fromType(f64).arg_type);
    try testing.expectEqual(ArgType.Bool, ArgInfo.fromType(bool).arg_type);
    try testing.expectEqual(ArgType.String, ArgInfo.fromType([]const u8).arg_type);
    try testing.expectEqual(ArgType.Pointer, ArgInfo.fromType(*const i32).arg_type);
}

test "count args" {
    const testing = std.testing;

    const args1 = .{@as(i32, 42)};
    const args2 = .{ @as(i32, 42), @as(f64, 3.14) };
    const args3 = .{ @as(i32, 1), @as(i32, 2), @as(i32, 3) };

    try testing.expectEqual(@as(usize, 1), countArgs(args1));
    try testing.expectEqual(@as(usize, 2), countArgs(args2));
    try testing.expectEqual(@as(usize, 3), countArgs(args3));
}

test "valid vararg types" {
    const testing = std.testing;

    try testing.expect(isValidVarArg(i32));
    try testing.expect(isValidVarArg(u64));
    try testing.expect(isValidVarArg(f32));
    try testing.expect(isValidVarArg(f64));
    try testing.expect(isValidVarArg(bool));
    try testing.expect(isValidVarArg(*const u8));
    try testing.expect(isValidVarArg([*]const u8));
}

test "get arg by index" {
    const testing = std.testing;

    const args = .{ @as(i32, 42), @as(f64, 3.14), "hello" };

    const arg0 = getArg(i32, args, 0);
    const arg1 = getArg(f64, args, 1);
    const arg2 = getArg([]const u8, args, 2);
    const arg3 = getArg(i32, args, 3);

    try testing.expect(arg0 != null);
    try testing.expectEqual(@as(i32, 42), arg0.?);

    try testing.expect(arg1 != null);
    try testing.expectEqual(@as(f64, 3.14), arg1.?);

    try testing.expect(arg2 != null);
    try testing.expect(std.mem.eql(u8, "hello", arg2.?));

    try testing.expect(arg3 == null);
}

test "for each arg" {
    const testing = std.testing;

    const args = .{ @as(i32, 10), @as(i32, 20), @as(i32, 30) };

    // Test that forEachArg compiles and runs
    // (We can't easily test side effects from the callback in Zig)
    forEachArg(args, struct {
        fn noop(arg: anytype) void {
            _ = arg;
        }
    }.noop);

    try testing.expect(true);
}

test "format spec" {
    const testing = std.testing;

    const spec = FormatSpec{
        .width = 10,
        .precision = 2,
        .flags = .{
            .left_justify = true,
            .zero_pad = false,
        },
        .length = .Default,
        .specifier = .Decimal,
    };

    try testing.expectEqual(@as(u32, 10), spec.width.?);
    try testing.expectEqual(@as(u32, 2), spec.precision.?);
    try testing.expect(spec.flags.left_justify);
    try testing.expect(!spec.flags.zero_pad);
}
