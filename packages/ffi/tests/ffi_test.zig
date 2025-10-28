// Home Programming Language - FFI Comprehensive Tests
// Tests for C compatibility, type conversions, and interop

const std = @import("std");
const testing = std.testing;
const ffi = @import("ffi");
const header_gen = @import("header_gen");

// ============================================================================
// C Type Tests
// ============================================================================

test "C type sizes" {
    // Verify C type sizes match C ABI
    try testing.expectEqual(@as(usize, 1), @sizeOf(ffi.c_char));
    try testing.expectEqual(@as(usize, 4), @sizeOf(ffi.c_int));
    try testing.expectEqual(@as(usize, 8), @sizeOf(ffi.c_long));
    try testing.expectEqual(@as(usize, 4), @sizeOf(ffi.c_float));
    try testing.expectEqual(@as(usize, 8), @sizeOf(ffi.c_double));
}

test "C type alignment" {
    // Verify C type alignment matches C ABI
    try testing.expectEqual(@as(usize, 1), @alignOf(ffi.c_char));
    try testing.expectEqual(@as(usize, 4), @alignOf(ffi.c_int));
    try testing.expectEqual(@as(usize, 8), @alignOf(ffi.c_long));
    try testing.expectEqual(@as(usize, 4), @alignOf(ffi.c_float));
    try testing.expectEqual(@as(usize, 8), @alignOf(ffi.c_double));
}

test "C type value ranges" {
    const max_int: ffi.c_int = std.math.maxInt(ffi.c_int);
    const min_int: ffi.c_int = std.math.minInt(ffi.c_int);

    try testing.expectEqual(@as(ffi.c_int, 2147483647), max_int);
    try testing.expectEqual(@as(ffi.c_int, -2147483648), min_int);
}

// ============================================================================
// C String Tests
// ============================================================================

test "Home string to C string conversion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const home_str = "Hello, World!";
    const c_str = try ffi.CString.fromHome(allocator, home_str);
    defer allocator.free(c_str);

    try testing.expectEqual(@as(usize, 13), ffi.CString.len(c_str));
    try testing.expectEqual(@as(u8, 0), c_str[13]); // Null terminator
}

test "C string to Home string conversion" {
    const c_str: [*:0]const u8 = "Test string";
    const home_str = ffi.CString.toHome(c_str);

    try testing.expectEqualStrings("Test string", home_str);
}

test "C string length" {
    const str1: [*:0]const u8 = "Hello";
    const str2: [*:0]const u8 = "A much longer string";

    try testing.expectEqual(@as(usize, 5), ffi.CString.len(str1));
    try testing.expectEqual(@as(usize, 20), ffi.CString.len(str2));
}

test "C string comparison" {
    const str1: [*:0]const u8 = "Apple";
    const str2: [*:0]const u8 = "Banana";
    const str3: [*:0]const u8 = "Apple";

    try testing.expect(ffi.CString.cmp(str1, str2) < 0);
    try testing.expect(ffi.CString.cmp(str2, str1) > 0);
    try testing.expectEqual(@as(ffi.c_int, 0), ffi.CString.cmp(str1, str3));
}

test "C string concatenation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const str1: [*:0]const u8 = "Hello, ";
    const str2: [*:0]const u8 = "World!";

    const result = try ffi.CString.concat(allocator, str1, str2);
    defer allocator.free(result);

    const home_str = ffi.CString.toHome(result);
    try testing.expectEqualStrings("Hello, World!", home_str);
}

// ============================================================================
// Type Conversion Tests
// ============================================================================

test "integer type conversions" {
    const home_i32: i32 = 42;
    const c_val = ffi.Convert.toC(ffi.c_int, home_i32);
    try testing.expectEqual(@as(ffi.c_int, 42), c_val);

    const back = ffi.Convert.fromC(i32, c_val);
    try testing.expectEqual(home_i32, back);
}

test "large integer conversions" {
    const home_i64: i64 = 9_223_372_036_854_775_807;
    const c_val = ffi.Convert.toC(ffi.c_long, home_i64);
    try testing.expectEqual(@as(ffi.c_long, 9_223_372_036_854_775_807), c_val);
}

test "negative integer conversions" {
    const home_val: i32 = -12345;
    const c_val = ffi.Convert.toC(ffi.c_int, home_val);
    try testing.expectEqual(@as(ffi.c_int, -12345), c_val);
}

test "array to C pointer conversion" {
    var arr = [_]ffi.c_int{ 1, 2, 3, 4, 5 };
    const c_ptr = ffi.Convert.arrayToC(ffi.c_int, &arr);

    try testing.expectEqual(@as(ffi.c_int, 1), c_ptr[0]);
    try testing.expectEqual(@as(ffi.c_int, 3), c_ptr[2]);
    try testing.expectEqual(@as(ffi.c_int, 5), c_ptr[4]);
}

test "C pointer to array conversion" {
    var c_array = [_]ffi.c_int{ 10, 20, 30, 40, 50 };
    const c_ptr: [*]ffi.c_int = &c_array;

    const home_slice = ffi.Convert.arrayFromC(ffi.c_int, c_ptr, 5);

    try testing.expectEqual(@as(usize, 5), home_slice.len);
    try testing.expectEqual(@as(ffi.c_int, 10), home_slice[0]);
    try testing.expectEqual(@as(ffi.c_int, 50), home_slice[4]);
}

// ============================================================================
// Calling Convention Tests
// ============================================================================

test "calling convention to Zig conversion" {
    const c_conv = ffi.CallingConvention.C;
    const zig_conv = c_conv.toZig();
    try testing.expectEqual(std.builtin.CallingConvention.C, zig_conv);

    const stdcall_conv = ffi.CallingConvention.Stdcall;
    const zig_stdcall = stdcall_conv.toZig();
    try testing.expectEqual(std.builtin.CallingConvention.Stdcall, zig_stdcall);
}

test "all calling conventions" {
    const conventions = [_]ffi.CallingConvention{
        .C,
        .Stdcall,
        .Fastcall,
        .Vectorcall,
        .Thiscall,
        .AAPCS,
        .SysV,
        .Win64,
    };

    for (conventions) |cc| {
        _ = cc.toZig(); // Should not crash
    }
}

// ============================================================================
// Alignment Tests
// ============================================================================

test "pointer alignment check" {
    const aligned_ptr: usize = 16;
    const unaligned_ptr: usize = 15;

    try testing.expect(ffi.Alignment.isAligned(aligned_ptr, 8));
    try testing.expect(!ffi.Alignment.isAligned(unaligned_ptr, 8));
}

test "pointer alignment" {
    const unaligned: usize = 13;
    const aligned = ffi.Alignment.alignPtr(unaligned, 8);

    try testing.expectEqual(@as(usize, 16), aligned);
    try testing.expect(ffi.Alignment.isAligned(aligned, 8));
}

test "size alignment" {
    try testing.expectEqual(@as(usize, 8), ffi.Alignment.alignSize(5, 8));
    try testing.expectEqual(@as(usize, 16), ffi.Alignment.alignSize(9, 8));
    try testing.expectEqual(@as(usize, 16), ffi.Alignment.alignSize(16, 8));
}

test "type alignment" {
    try testing.expectEqual(@as(comptime_int, 4), ffi.Alignment.ofType(ffi.c_int));
    try testing.expectEqual(@as(comptime_int, 8), ffi.Alignment.ofType(ffi.c_long));
    try testing.expectEqual(@as(comptime_int, 8), ffi.Alignment.ofType(ffi.c_double));
}

// ============================================================================
// Structure Layout Tests
// ============================================================================

test "C struct layout" {
    const Point = extern struct {
        x: ffi.c_int,
        y: ffi.c_int,
    };

    try testing.expectEqual(@as(usize, 8), @sizeOf(Point));
    try testing.expectEqual(@as(usize, 4), @alignOf(Point));
}

test "packed struct layout" {
    const PackedData = packed struct {
        a: u8,
        b: u16,
        c: u8,
    };

    // Packed struct should be 4 bytes (no padding)
    try testing.expectEqual(@as(usize, 4), @sizeOf(PackedData));
}

test "extern struct padding" {
    const WithPadding = extern struct {
        a: u8,      // 1 byte
        // 3 bytes padding
        b: u32,     // 4 bytes
        c: u8,      // 1 byte
        // 3 bytes padding
    };

    // Should have padding to maintain alignment
    try testing.expectEqual(@as(usize, 12), @sizeOf(WithPadding));
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "null pointer check" {
    const valid_ptr: ?*ffi.c_int = @ptrFromInt(0x1000);
    const null_ptr: ?*ffi.c_int = null;

    const result = try ffi.checkNull(valid_ptr);
    try testing.expect(result != null);

    try testing.expectError(ffi.CError.NullPointer, ffi.checkNull(null_ptr));
}

test "C result code check" {
    try ffi.checkResult(0);
    try ffi.checkResult(1);
    try ffi.checkResult(100);

    try testing.expectError(ffi.CError.InvalidParameter, ffi.checkResult(-1));
    try testing.expectError(ffi.CError.InvalidParameter, ffi.checkResult(-100));
}

// ============================================================================
// C Standard Library Tests
// ============================================================================

test "C stdlib memset" {
    var buffer: [16]u8 = undefined;

    _ = ffi.CStdLib.memset(&buffer, 0x42, buffer.len);

    for (buffer) |byte| {
        try testing.expectEqual(@as(u8, 0x42), byte);
    }
}

test "C stdlib memcpy" {
    const src = [_]u8{ 1, 2, 3, 4, 5 };
    var dest: [5]u8 = undefined;

    _ = ffi.CStdLib.memcpy(&dest, &src, src.len);

    for (src, dest) |s, d| {
        try testing.expectEqual(s, d);
    }
}

test "C stdlib memcmp" {
    const arr1 = [_]u8{ 1, 2, 3, 4, 5 };
    const arr2 = [_]u8{ 1, 2, 3, 4, 5 };
    const arr3 = [_]u8{ 1, 2, 3, 9, 9 };

    const result1 = ffi.CStdLib.memcmp(&arr1, &arr2, arr1.len);
    try testing.expectEqual(@as(ffi.c_int, 0), result1);

    const result2 = ffi.CStdLib.memcmp(&arr1, &arr3, arr1.len);
    try testing.expect(result2 != 0);
}

test "C stdlib strlen" {
    const str: [*:0]const u8 = "Hello, World!";
    const len = ffi.CStdLib.strlen(str);

    try testing.expectEqual(@as(ffi.size_t, 13), len);
}

test "C stdlib strcmp" {
    const str1: [*:0]const u8 = "Apple";
    const str2: [*:0]const u8 = "Apple";
    const str3: [*:0]const u8 = "Banana";

    const result1 = ffi.CStdLib.strcmp(str1, str2);
    try testing.expectEqual(@as(ffi.c_int, 0), result1);

    const result2 = ffi.CStdLib.strcmp(str1, str3);
    try testing.expect(result2 < 0);
}

// ============================================================================
// Header Generation Tests
// ============================================================================

test "basic header generation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = header_gen.HeaderConfig{
        .guard_name = "TEST_HEADER",
    };

    const header = try header_gen.generateHeader(allocator, config);
    defer allocator.free(header);

    try testing.expect(header.len > 0);
    try testing.expect(std.mem.indexOf(u8, header, "#ifndef TEST_HEADER_H") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#define TEST_HEADER_H") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#endif") != null);
}

test "header with includes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = header_gen.HeaderConfig{
        .guard_name = "MY_HEADER",
        .includes = &.{ "stdint.h", "stdbool.h", "stdio.h" },
    };

    const header = try header_gen.generateHeader(allocator, config);
    defer allocator.free(header);

    try testing.expect(std.mem.indexOf(u8, header, "#include <stdint.h>") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#include <stdbool.h>") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#include <stdio.h>") != null);
}

test "header with defines" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = header_gen.HeaderConfig{
        .guard_name = "DEFINES_TEST",
        .defines = &.{
            .{ .name = "VERSION", .value = "1" },
            .{ .name = "MAX_SIZE", .value = "256" },
        },
    };

    const header = try header_gen.generateHeader(allocator, config);
    defer allocator.free(header);

    try testing.expect(std.mem.indexOf(u8, header, "#define VERSION 1") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#define MAX_SIZE 256") != null);
}

test "header with structs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = header_gen.HeaderConfig{
        .guard_name = "STRUCTS_TEST",
        .structs = &.{
            .{
                .name = "Point",
                .fields = &.{
                    .{ .name = "x", .c_type = "int32_t" },
                    .{ .name = "y", .c_type = "int32_t" },
                },
            },
        },
    };

    const header = try header_gen.generateHeader(allocator, config);
    defer allocator.free(header);

    try testing.expect(std.mem.indexOf(u8, header, "typedef struct Point") != null);
    try testing.expect(std.mem.indexOf(u8, header, "int32_t x;") != null);
    try testing.expect(std.mem.indexOf(u8, header, "int32_t y;") != null);
}

test "header with functions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = header_gen.HeaderConfig{
        .guard_name = "FUNCTIONS_TEST",
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

    const header = try header_gen.generateHeader(allocator, config);
    defer allocator.free(header);

    try testing.expect(std.mem.indexOf(u8, header, "int32_t add(int32_t a, int32_t b);") != null);
}

test "header with variadic function" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = header_gen.HeaderConfig{
        .guard_name = "VARIADIC_TEST",
        .functions = &.{
            .{
                .name = "printf_wrapper",
                .return_type = "int",
                .params = &.{
                    .{ .name = "fmt", .c_type = "const char*" },
                },
                .is_variadic = true,
            },
        },
    };

    const header = try header_gen.generateHeader(allocator, config);
    defer allocator.free(header);

    try testing.expect(std.mem.indexOf(u8, header, "printf_wrapper(const char* fmt, ...);") != null);
}

test "type mapping" {
    try testing.expectEqualStrings("int32_t", header_gen.TypeMap.toCType(i32));
    try testing.expectEqualStrings("uint64_t", header_gen.TypeMap.toCType(u64));
    try testing.expectEqualStrings("float", header_gen.TypeMap.toCType(f32));
    try testing.expectEqualStrings("double", header_gen.TypeMap.toCType(f64));
    try testing.expectEqualStrings("bool", header_gen.TypeMap.toCType(bool));
}

// ============================================================================
// Performance Tests
// ============================================================================

test "bulk C string conversions performance" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const iterations = 1000;
    var i: usize = 0;

    while (i < iterations) : (i += 1) {
        const c_str = try ffi.CString.fromHome(allocator, "Test string for performance");
        allocator.free(c_str);
    }
}

test "bulk type conversions performance" {
    const iterations = 10000;
    var sum: i64 = 0;

    var i: i64 = 0;
    while (i < iterations) : (i += 1) {
        const c_val = ffi.Convert.toC(ffi.c_int, i);
        const back = ffi.Convert.fromC(i64, c_val);
        sum += back;
    }

    try testing.expect(sum > 0);
}
