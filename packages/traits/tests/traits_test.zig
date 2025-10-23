const std = @import("std");
const testing = std.testing;

// Trait system tests
// Tests for trait definitions and implementations

test "traits - basic compilation" {
    // Ensure trait system compiles
    try testing.expect(true);
}

test "traits - interface simulation via comptime" {
    const Drawable = struct {
        pub fn hasDrawFn(comptime T: type) bool {
            return @hasDecl(T, "draw");
        }
    };

    const Circle = struct {
        radius: f32,

        pub fn draw(self: @This()) void {
            _ = self;
            // Draw implementation
        }
    };

    const Square = struct {
        side: f32,
        // No draw method
    };

    try testing.expect(Drawable.hasDrawFn(Circle));
    try testing.expect(!Drawable.hasDrawFn(Square));
}

test "traits - trait bounds simulation" {
    fn requiresAdd(comptime T: type) void {
        // This function requires T to support addition
        // In a real implementation, this would be enforced at compile time
        _ = @as(T, undefined) + @as(T, undefined);
    }

    // These should compile
    requiresAdd(i32);
    requiresAdd(f64);

    try testing.expect(true);
}

test "traits - trait object simulation" {
    const Animal = struct {
        vtable: *const VTable,
        data: *anyopaque,

        const VTable = struct {
            speak: *const fn (*anyopaque) []const u8,
        };

        pub fn speak(self: @This()) []const u8 {
            return self.vtable.speak(self.data);
        }
    };

    const Dog = struct {
        name: []const u8,

        fn speak(ptr: *anyopaque) []const u8 {
            _ = @as(*@This(), @ptrCast(@alignCast(ptr)));
            return "Woof!";
        }

        const vtable = Animal.VTable{
            .speak = speak,
        };
    };

    var dog = Dog{ .name = "Rex" };
    const animal = Animal{
        .vtable = &Dog.vtable,
        .data = @ptrCast(&dog),
    };

    try testing.expectEqualStrings("Woof!", animal.speak());
}

test "traits - multiple trait bounds" {
    fn requiresMultiple(comptime T: type) void {
        // Requires T to have both addition and comparison
        _ = @as(T, undefined) + @as(T, undefined);
        _ = @as(T, undefined) < @as(T, undefined);
    }

    requiresMultiple(i32);
    requiresMultiple(f32);

    try testing.expect(true);
}

test "traits - default implementations" {
    const Comparator = struct {
        pub fn lessThan(comptime T: type, a: T, b: T) bool {
            return a < b;
        }

        pub fn greaterThan(comptime T: type, a: T, b: T) bool {
            return a > b;
        }

        pub fn lessOrEqual(comptime T: type, a: T, b: T) bool {
            return !greaterThan(T, a, b);
        }
    };

    try testing.expect(Comparator.lessThan(i32, 5, 10));
    try testing.expect(Comparator.greaterThan(i32, 10, 5));
    try testing.expect(Comparator.lessOrEqual(i32, 5, 5));
}

test "traits - associated types simulation" {
    fn Container(comptime T: type) type {
        return struct {
            pub const Item = T;
            pub const Size = usize;

            items: []Item,

            pub fn len(self: @This()) Size {
                return self.items.len;
            }

            pub fn get(self: @This(), index: Size) ?Item {
                if (index >= self.items.len) return null;
                return self.items[index];
            }
        };
    }

    const IntContainer = Container(i32);
    const items = [_]i32{ 1, 2, 3 };
    const container = IntContainer{ .items = &items };

    try testing.expect(container.len() == 3);
    try testing.expect(container.get(1).? == 2);
}

test "traits - marker traits" {
    const Copy = struct {
        pub fn isCopy(comptime T: type) bool {
            const info = @typeInfo(T);
            return switch (info) {
                .Int, .Float, .Bool => true,
                .Pointer => |ptr| ptr.size == .One,
                else => false,
            };
        }
    };

    try testing.expect(Copy.isCopy(i32));
    try testing.expect(Copy.isCopy(f64));
    try testing.expect(!Copy.isCopy([]const u8));
}

test "traits - supertraits simulation" {
    const Eq = struct {
        pub fn hasEq(comptime T: type) bool {
            return @hasDecl(T, "eq");
        }
    };

    const Ord = struct {
        pub fn hasOrd(comptime T: type) bool {
            // Ord requires Eq
            return Eq.hasEq(T) and @hasDecl(T, "cmp");
        }
    };

    const Number = struct {
        value: i32,

        pub fn eq(self: @This(), other: @This()) bool {
            return self.value == other.value;
        }

        pub fn cmp(self: @This(), other: @This()) i32 {
            if (self.value < other.value) return -1;
            if (self.value > other.value) return 1;
            return 0;
        }
    };

    try testing.expect(Eq.hasEq(Number));
    try testing.expect(Ord.hasOrd(Number));
}
