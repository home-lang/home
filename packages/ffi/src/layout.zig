// Home Programming Language - Memory Layout Utilities
// Helpers for understanding and working with C memory layouts

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Structure Layout Analysis
// ============================================================================

/// Get detailed layout information for a struct
pub fn StructLayout(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("StructLayout requires a struct type");
    }

    return struct {
        pub const size = @sizeOf(T);
        pub const alignment = @alignOf(T);
        pub const field_count = info.@"struct".fields.len;

        /// Get offset of a field by name
        pub fn fieldOffset(comptime name: []const u8) usize {
            return @offsetOf(T, name);
        }

        /// Get size of a field by name
        pub fn fieldSize(comptime name: []const u8) usize {
            inline for (info.@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    return @sizeOf(field.type);
                }
            }
            @compileError("Field not found: " ++ name);
        }

        /// Get alignment of a field by name
        pub fn fieldAlignment(comptime name: []const u8) usize {
            inline for (info.@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    return @alignOf(field.type);
                }
            }
            @compileError("Field not found: " ++ name);
        }

        /// Calculate padding between fields
        pub fn paddingBefore(comptime name: []const u8) usize {
            const offset = fieldOffset(name);
            var cumulative: usize = 0;

            inline for (info.@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    break;
                }
                cumulative += @sizeOf(field.type);
            }

            return offset - cumulative;
        }
    };
}

// ============================================================================
// Union Layout Analysis
// ============================================================================

/// Get layout information for a union
pub fn UnionLayout(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"union") {
        @compileError("UnionLayout requires a union type");
    }

    return struct {
        pub const size = @sizeOf(T);
        pub const alignment = @alignOf(T);
        pub const field_count = info.@"union".fields.len;
    };
}

// ============================================================================
// Array Layout
// ============================================================================

/// Get layout information for an array
pub fn ArrayLayout(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .array) {
        @compileError("ArrayLayout requires an array type");
    }

    return struct {
        pub const elem_type = info.array.child;
        pub const length = info.array.len;
        pub const elem_size = @sizeOf(elem_type);
        pub const total_size = @sizeOf(T);
        pub const alignment = @alignOf(T);

        /// Get offset for element at index
        pub fn elementOffset(index: usize) usize {
            return index * elem_size;
        }
    };
}

// ============================================================================
// Padding Utilities
// ============================================================================

/// Calculate padding needed for alignment
pub fn paddingFor(offset: usize, alignment: usize) usize {
    const remainder = offset % alignment;
    if (remainder == 0) return 0;
    return alignment - remainder;
}

/// Align value up to alignment
pub fn alignUp(value: usize, alignment: usize) usize {
    return value + paddingFor(value, alignment);
}

/// Align value down to alignment
pub fn alignDown(value: usize, alignment: usize) usize {
    return value - (value % alignment);
}

/// Check if value is aligned
pub fn isAligned(value: usize, alignment: usize) bool {
    return (value % alignment) == 0;
}

// ============================================================================
// Bit Fields
// ============================================================================

/// Extract bit field from integer
pub fn extractBits(value: anytype, comptime bit_offset: u8, comptime bit_count: u8) @TypeOf(value) {
    const T = @TypeOf(value);
    const mask = (@as(T, 1) << bit_count) - 1;
    return (value >> bit_offset) & mask;
}

/// Set bit field in integer
pub fn setBits(value: anytype, comptime bit_offset: u8, comptime bit_count: u8, new_value: @TypeOf(value)) @TypeOf(value) {
    const T = @TypeOf(value);
    const mask = (@as(T, 1) << bit_count) - 1;
    const clear_mask = ~(mask << bit_offset);
    return (value & clear_mask) | ((new_value & mask) << bit_offset);
}

// ============================================================================
// Endianness Conversion
// ============================================================================

/// Convert value to big endian
pub fn toBigEndian(value: anytype) @TypeOf(value) {
    if (builtin.cpu.arch.endian() == .big) {
        return value;
    }
    return @byteSwap(value);
}

/// Convert value to little endian
pub fn toLittleEndian(value: anytype) @TypeOf(value) {
    if (builtin.cpu.arch.endian() == .little) {
        return value;
    }
    return @byteSwap(value);
}

/// Convert value from big endian
pub fn fromBigEndian(value: anytype) @TypeOf(value) {
    return toBigEndian(value); // Same operation
}

/// Convert value from little endian
pub fn fromLittleEndian(value: anytype) @TypeOf(value) {
    return toLittleEndian(value); // Same operation
}

// ============================================================================
// Pointer Arithmetic
// ============================================================================

/// Add offset to pointer (in bytes)
pub fn ptrAdd(ptr: anytype, offset: usize) @TypeOf(ptr) {
    const bytes: [*]u8 = @ptrCast(ptr);
    return @ptrCast(@alignCast(bytes + offset));
}

/// Subtract offset from pointer (in bytes)
pub fn ptrSub(ptr: anytype, offset: usize) @TypeOf(ptr) {
    const bytes: [*]u8 = @ptrCast(ptr);
    return @ptrCast(@alignCast(bytes - offset));
}

/// Get distance between two pointers (in bytes)
pub fn ptrDistance(ptr1: anytype, ptr2: @TypeOf(ptr1)) isize {
    const bytes1: [*]u8 = @ptrCast(ptr1);
    const bytes2: [*]u8 = @ptrCast(ptr2);
    return @as(isize, @intCast(@intFromPtr(bytes2))) - @as(isize, @intCast(@intFromPtr(bytes1)));
}

// ============================================================================
// Type Punning (with safety checks)
// ============================================================================

/// Reinterpret bytes of one type as another (requires same size)
pub fn reinterpret(comptime To: type, value: anytype) To {
    const From = @TypeOf(value);
    if (@sizeOf(From) != @sizeOf(To)) {
        @compileError("Types must have same size for reinterpretation");
    }
    const bytes = std.mem.asBytes(&value);
    return @as(*const To, @ptrCast(@alignCast(bytes))).*;
}

// ============================================================================
// Tests
// ============================================================================

test "StructLayout" {
    const testing = std.testing;

    const TestStruct = struct {
        a: u8,
        b: u32,
        c: u8,
    };

    const layout = StructLayout(TestStruct);

    // Size will depend on platform struct packing
    try testing.expect(layout.size >= 8); // At least 1 + 4 + 1 = 6, rounded up
    try testing.expectEqual(@as(usize, 4), layout.alignment);
    try testing.expectEqual(@as(usize, 3), layout.field_count);

    // Field offsets depend on compiler layout
    const offset_a = layout.fieldOffset("a");
    const offset_b = layout.fieldOffset("b");
    const offset_c = layout.fieldOffset("c");

    // Just verify they're reasonable
    try testing.expect(offset_a < layout.size);
    try testing.expect(offset_b < layout.size);
    try testing.expect(offset_c < layout.size);
}

test "ArrayLayout" {
    const testing = std.testing;

    const TestArray = [5]u32;
    const layout = ArrayLayout(TestArray);

    try testing.expectEqual(u32, layout.elem_type);
    try testing.expectEqual(@as(usize, 5), layout.length);
    try testing.expectEqual(@as(usize, 4), layout.elem_size);
    try testing.expectEqual(@as(usize, 20), layout.total_size);
    try testing.expectEqual(@as(usize, 8), layout.elementOffset(2));
}

test "Padding utilities" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), paddingFor(0, 4));
    try testing.expectEqual(@as(usize, 3), paddingFor(1, 4));
    try testing.expectEqual(@as(usize, 0), paddingFor(4, 4));

    try testing.expectEqual(@as(usize, 4), alignUp(1, 4));
    try testing.expectEqual(@as(usize, 4), alignUp(4, 4));
    try testing.expectEqual(@as(usize, 8), alignUp(5, 4));

    try testing.expect(isAligned(4, 4));
    try testing.expect(!isAligned(5, 4));
}

test "Bit field extraction" {
    const testing = std.testing;

    const value: u32 = 0b11010110;

    try testing.expectEqual(@as(u32, 0b110), extractBits(value, 0, 3));
    try testing.expectEqual(@as(u32, 0b101), extractBits(value, 2, 3));
    try testing.expectEqual(@as(u32, 0b1101), extractBits(value, 4, 4));
}

test "Bit field setting" {
    const testing = std.testing;

    var value: u32 = 0b00000000;

    value = setBits(value, 0, 3, 0b110);
    try testing.expectEqual(@as(u32, 0b00000110), value);

    value = setBits(value, 4, 4, 0b1010);
    try testing.expectEqual(@as(u32, 0b10100110), value);
}

test "Endianness conversion" {
    const testing = std.testing;

    const value: u32 = 0x12345678;

    if (builtin.cpu.arch.endian() == .little) {
        try testing.expectEqual(@as(u32, 0x78563412), toBigEndian(value));
        try testing.expectEqual(value, toLittleEndian(value));
    } else {
        try testing.expectEqual(value, toBigEndian(value));
        try testing.expectEqual(@as(u32, 0x78563412), toLittleEndian(value));
    }
}

test "Pointer arithmetic" {
    const testing = std.testing;

    var array = [_]u32{ 1, 2, 3, 4, 5 };
    const ptr: [*]u32 = &array;

    const ptr_plus = ptrAdd(ptr, 4); // Add 4 bytes (1 u32)
    try testing.expectEqual(@as(u32, 2), ptr_plus[0]);

    const distance = ptrDistance(ptr, ptr_plus);
    try testing.expectEqual(@as(isize, 4), distance);
}
