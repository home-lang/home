const std = @import("std");
const testing = std.testing;

// Import just the standalone operation modules
const TypeInfo = struct {
    name: []const u8,
    kind: TypeKind,
    size: usize,
    alignment: usize,
    fields: ?[]FieldInfo,

    pub const TypeKind = enum {
        Integer,
        Float,
        Bool,
        String,
        Array,
        Struct,
        Union,
        Enum,
        Function,
        Pointer,
        Optional,
    };

    pub const FieldInfo = struct {
        name: []const u8,
        type_name: []const u8,
        offset: usize,
    };
};

// Test string operations directly
test "String concatenation" {
    const allocator = testing.allocator;
    const result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ "Hello", "World" });
    defer allocator.free(result);
    try testing.expectEqualStrings("HelloWorld", result);
}

test "String uppercase" {
    const allocator = testing.allocator;
    const s = "hello";
    var result = try allocator.alloc(u8, s.len);
    defer allocator.free(result);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }
    try testing.expectEqualStrings("HELLO", result);
}

test "Type reflection - field count" {
    const allocator = testing.allocator;
    const fields = try allocator.alloc(TypeInfo.FieldInfo, 3);
    defer allocator.free(fields);

    fields[0] = .{ .name = "x", .type_name = "i32", .offset = 0 };
    fields[1] = .{ .name = "y", .type_name = "i32", .offset = 4 };
    fields[2] = .{ .name = "z", .type_name = "i32", .offset = 8 };

    const type_info = TypeInfo{
        .name = "Vec3",
        .kind = .Struct,
        .size = 12,
        .alignment = 4,
        .fields = fields,
    };

    try testing.expectEqual(@as(usize, 3), type_info.fields.?.len);
}

test "Array operations" {
    const allocator = testing.allocator;

    const Value = union(enum) {
        int: i64,
        float: f64,
        bool: bool,
        string: []const u8,
    };

    const arr = [_]Value{
        Value{ .int = 1 },
        Value{ .int = 2 },
        Value{ .int = 3 },
    };

    try testing.expectEqual(@as(usize, 3), arr.len);

    // Array concatenation
    const arr2 = [_]Value{Value{ .int = 4 }};
    var result = try allocator.alloc(Value, arr.len + arr2.len);
    defer allocator.free(result);

    @memcpy(result[0..arr.len], &arr);
    @memcpy(result[arr.len..], &arr2);

    try testing.expectEqual(@as(usize, 4), result.len);
}
