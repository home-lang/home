const std = @import("std");
const testing = std.testing;

// Generic function tests
test "generics - basic generic function" {
    const Max = struct {
        fn max(comptime T: type, a: T, b: T) T {
            return if (a > b) a else b;
        }
    };

    try testing.expect(Max.max(i32, 10, 5) == 10);
    try testing.expect(Max.max(f32, 3.14, 2.71) > 3.13);
}

test "generics - generic struct" {
    fn Pair(comptime T: type, comptime U: type) type {
        return struct {
            first: T,
            second: U,
        };
    }

    const PairType = Pair(i32, []const u8);
    const pair = PairType{
        .first = 42,
        .second = "hello",
    };

    try testing.expect(pair.first == 42);
    try testing.expectEqualStrings("hello", pair.second);
}

test "generics - generic container" {
    fn Container(comptime T: type) type {
        return struct {
            value: T,

            const Self = @This();

            pub fn init(val: T) Self {
                return .{ .value = val };
            }

            pub fn get(self: Self) T {
                return self.value;
            }
        };
    }

    const int_container = Container(i32).init(100);
    try testing.expect(int_container.get() == 100);

    const str_container = Container([]const u8).init("test");
    try testing.expectEqualStrings("test", str_container.get());
}

test "generics - type constraints via interface" {
    // Test that generic types work with different numeric types
    fn addGeneric(comptime T: type, a: T, b: T) T {
        // This implicitly constrains T to types that support '+'
        return a + b;
    }

    try testing.expect(addGeneric(i32, 5, 3) == 8);
    try testing.expect(addGeneric(u8, 200, 50) == 250);
    try testing.expect(addGeneric(f64, 1.5, 2.5) == 4.0);
}

test "generics - multiple type parameters" {
    fn convert(comptime From: type, comptime To: type, value: From) To {
        return @as(To, @intCast(value));
    }

    const result: i64 = convert(i32, i64, 42);
    try testing.expect(result == 42);
}

test "generics - generic array operations" {
    fn sum(comptime T: type, items: []const T) T {
        var total: T = 0;
        for (items) |item| {
            total += item;
        }
        return total;
    }

    const numbers = [_]i32{ 1, 2, 3, 4, 5 };
    try testing.expect(sum(i32, &numbers) == 15);
}
