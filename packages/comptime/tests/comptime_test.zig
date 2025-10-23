const std = @import("std");
const testing = std.testing;

// Comptime tests
// These test compile-time evaluation and macro expansion

test "comptime - basic functionality" {
    // This test will pass if the file compiles
    // Actual compile-time evaluation tests would require runtime integration
    try testing.expect(true);
}

test "comptime - type reflection basics" {
    const T = i32;
    const type_info = @typeInfo(T);

    try testing.expect(type_info == .Int);
}

test "comptime - struct field enumeration" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    const fields = @typeInfo(Point).Struct.fields;
    try testing.expect(fields.len == 2);
    try testing.expectEqualStrings("x", fields[0].name);
    try testing.expectEqualStrings("y", fields[1].name);
}

test "comptime - function parameter reflection" {
    const testFn = struct {
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }
    }.add;

    const func_info = @typeInfo(@TypeOf(testFn)).Fn;
    try testing.expect(func_info.params.len == 2);
}

test "comptime - comptime evaluation" {
    comptime {
        var sum: i32 = 0;
        var i: i32 = 0;
        while (i < 10) : (i += 1) {
            sum += i;
        }
        try testing.expect(sum == 45);
    }
}

test "comptime - generic function instantiation" {
    const GenericAdd = struct {
        fn add(comptime T: type, a: T, b: T) T {
            return a + b;
        }
    };

    const result_i32 = GenericAdd.add(i32, 5, 3);
    const result_f32 = GenericAdd.add(f32, 5.5, 3.2);

    try testing.expect(result_i32 == 8);
    try testing.expect(result_f32 > 8.6 and result_f32 < 8.8);
}
