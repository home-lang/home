const std = @import("std");
const comptime_mod = @import("comptime.zig");
const ComptimeValue = comptime_mod.ComptimeValue;
const ComptimeError = comptime_mod.ComptimeError;
const TypeInfo = comptime_mod.TypeInfo;

/// Enhanced comptime operations for type reflection, string manipulation, and array operations
/// Implements the TODOs at lines 152, 165, and 177 in comptime_eval.zig

/// Type Reflection Operations
pub const TypeReflection = struct {
    /// Get all field names from a struct type
    pub fn getFieldNames(allocator: std.mem.Allocator, type_info: TypeInfo) ![][]const u8 {
        const fields = type_info.fields orelse return error.NoFields;

        var names = try allocator.alloc([]const u8, fields.len);
        for (fields, 0..) |field, i| {
            names[i] = field.name;
        }
        return names;
    }

    /// Get field count
    pub fn getFieldCount(type_info: TypeInfo) usize {
        if (type_info.fields) |fields| {
            return fields.len;
        }
        return 0;
    }

    /// Get field by index
    pub fn getField(type_info: TypeInfo, index: usize) ?TypeInfo.FieldInfo {
        if (type_info.fields) |fields| {
            if (index < fields.len) {
                return fields[index];
            }
        }
        return null;
    }

    /// Check if type has a specific field
    pub fn hasField(type_info: TypeInfo, field_name: []const u8) bool {
        if (type_info.fields) |fields| {
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Get type kind as string
    pub fn getKindName(kind: TypeInfo.TypeKind) []const u8 {
        return switch (kind) {
            .Integer => "Integer",
            .Float => "Float",
            .Bool => "Bool",
            .String => "String",
            .Array => "Array",
            .Struct => "Struct",
            .Union => "Union",
            .Enum => "Enum",
            .Function => "Function",
            .Pointer => "Pointer",
            .Optional => "Optional",
        };
    }

    /// Check if type is numeric
    pub fn isNumeric(kind: TypeInfo.TypeKind) bool {
        return kind == .Integer or kind == .Float;
    }

    /// Check if type is aggregate
    pub fn isAggregate(kind: TypeInfo.TypeKind) bool {
        return kind == .Struct or kind == .Union or kind == .Array;
    }

    /// Check if type is callable
    pub fn isCallable(kind: TypeInfo.TypeKind) bool {
        return kind == .Function;
    }

    /// Get type alignment requirement
    pub fn getAlignment(type_info: TypeInfo) usize {
        return type_info.alignment;
    }

    /// Get type size in bytes
    pub fn getSize(type_info: TypeInfo) usize {
        return type_info.size;
    }

    /// Reflect on array type
    pub fn reflectArray(allocator: std.mem.Allocator, element_type: []const u8, length: usize) !TypeInfo {
        return TypeInfo{
            .name = try std.fmt.allocPrint(allocator, "[{}]{s}", .{ length, element_type }),
            .kind = .Array,
            .size = 0, // Would be element_size * length
            .alignment = 0,
            .fields = null,
        };
    }

    /// Reflect on optional type
    pub fn reflectOptional(allocator: std.mem.Allocator, inner_type: []const u8) !TypeInfo {
        return TypeInfo{
            .name = try std.fmt.allocPrint(allocator, "?{s}", .{inner_type}),
            .kind = .Optional,
            .size = 0,
            .alignment = 0,
            .fields = null,
        };
    }
};

/// String Manipulation Operations
pub const StringOps = struct {
    /// Concatenate two strings at compile time
    pub fn concat(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ a, b });
    }

    /// Get string length
    pub fn length(s: []const u8) i64 {
        return @intCast(s.len);
    }

    /// Get substring
    pub fn substring(allocator: std.mem.Allocator, s: []const u8, start: usize, end: usize) ![]const u8 {
        if (start > s.len or end > s.len or start > end) {
            return error.IndexOutOfBounds;
        }
        return try allocator.dupe(u8, s[start..end]);
    }

    /// Convert string to uppercase
    pub fn toUpper(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        var result = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            result[i] = std.ascii.toUpper(c);
        }
        return result;
    }

    /// Convert string to lowercase
    pub fn toLower(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        var result = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return result;
    }

    /// Check if string starts with prefix
    pub fn startsWith(s: []const u8, prefix: []const u8) bool {
        return std.mem.startsWith(u8, s, prefix);
    }

    /// Check if string ends with suffix
    pub fn endsWith(s: []const u8, suffix: []const u8) bool {
        return std.mem.endsWith(u8, s, suffix);
    }

    /// Check if string contains substring
    pub fn contains(s: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, s, needle) != null;
    }

    /// Find index of substring
    pub fn indexOf(s: []const u8, needle: []const u8) ?i64 {
        if (std.mem.indexOf(u8, s, needle)) |index| {
            return @intCast(index);
        }
        return null;
    }

    /// Replace all occurrences of substring
    pub fn replaceAll(allocator: std.mem.Allocator, s: []const u8, from: []const u8, to: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).fromOwnedSlice(&[_]u8{});
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < s.len) {
            if (i + from.len <= s.len and std.mem.eql(u8, s[i..][0..from.len], from)) {
                try result.appendSlice(allocator, to);
                i += from.len;
            } else {
                try result.append(allocator, s[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Split string by delimiter
    pub fn split(allocator: std.mem.Allocator, s: []const u8, delimiter: []const u8) ![][]const u8 {
        var parts = std.ArrayList([]const u8).fromOwnedSlice(&[_][]const u8{});
        defer parts.deinit(allocator);

        var iter = std.mem.splitSequence(u8, s, delimiter);
        while (iter.next()) |part| {
            try parts.append(allocator, try allocator.dupe(u8, part));
        }

        return parts.toOwnedSlice(allocator);
    }

    /// Join strings with separator
    pub fn join(allocator: std.mem.Allocator, strings: []const []const u8, separator: []const u8) ![]const u8 {
        if (strings.len == 0) {
            return try allocator.dupe(u8, "");
        }

        var total_len: usize = 0;
        for (strings) |s| {
            total_len += s.len;
        }
        total_len += separator.len * (strings.len - 1);

        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;

        for (strings, 0..) |s, i| {
            @memcpy(result[pos..][0..s.len], s);
            pos += s.len;

            if (i < strings.len - 1) {
                @memcpy(result[pos..][0..separator.len], separator);
                pos += separator.len;
            }
        }

        return result;
    }

    /// Trim whitespace from both ends
    pub fn trim(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, s, &std.ascii.whitespace);
        return try allocator.dupe(u8, trimmed);
    }

    /// Repeat string n times
    pub fn repeat(allocator: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
        var result = try allocator.alloc(u8, s.len * n);
        for (0..n) |i| {
            @memcpy(result[i * s.len ..][0..s.len], s);
        }
        return result;
    }

    /// Reverse string
    pub fn reverse(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        var result = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            result[s.len - 1 - i] = c;
        }
        return result;
    }
};

/// Array Operations
pub const ArrayOps = struct {
    /// Get array length
    pub fn length(array: []const ComptimeValue) i64 {
        return @intCast(array.len);
    }

    /// Get element at index
    pub fn get(array: []const ComptimeValue, index: usize) ?ComptimeValue {
        if (index < array.len) {
            return array[index];
        }
        return null;
    }

    /// Create a new array with an element appended
    pub fn append(allocator: std.mem.Allocator, array: []const ComptimeValue, element: ComptimeValue) ![]ComptimeValue {
        var result = try allocator.alloc(ComptimeValue, array.len + 1);
        @memcpy(result[0..array.len], array);
        result[array.len] = element;
        return result;
    }

    /// Create a new array with an element prepended
    pub fn prepend(allocator: std.mem.Allocator, element: ComptimeValue, array: []const ComptimeValue) ![]ComptimeValue {
        var result = try allocator.alloc(ComptimeValue, array.len + 1);
        result[0] = element;
        @memcpy(result[1..], array);
        return result;
    }

    /// Concatenate two arrays
    pub fn concat(allocator: std.mem.Allocator, a: []const ComptimeValue, b: []const ComptimeValue) ![]ComptimeValue {
        var result = try allocator.alloc(ComptimeValue, a.len + b.len);
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }

    /// Get a slice of the array
    pub fn slice(allocator: std.mem.Allocator, array: []const ComptimeValue, start: usize, end: usize) ![]ComptimeValue {
        if (start > array.len or end > array.len or start > end) {
            return error.IndexOutOfBounds;
        }
        const result = try allocator.alloc(ComptimeValue, end - start);
        @memcpy(result, array[start..end]);
        return result;
    }

    /// Reverse an array
    pub fn reverse(allocator: std.mem.Allocator, array: []const ComptimeValue) ![]ComptimeValue {
        var result = try allocator.alloc(ComptimeValue, array.len);
        for (array, 0..) |elem, i| {
            result[array.len - 1 - i] = elem;
        }
        return result;
    }

    /// Check if array contains an element
    pub fn contains(array: []const ComptimeValue, element: ComptimeValue) bool {
        for (array) |elem| {
            if (comptimeValuesEqual(elem, element)) {
                return true;
            }
        }
        return false;
    }

    /// Find index of element in array
    pub fn indexOf(array: []const ComptimeValue, element: ComptimeValue) ?i64 {
        for (array, 0..) |elem, i| {
            if (comptimeValuesEqual(elem, element)) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Map a function over array elements
    pub fn map(
        allocator: std.mem.Allocator,
        array: []const ComptimeValue,
        func: *const fn (ComptimeValue) ComptimeValue,
    ) ![]ComptimeValue {
        var result = try allocator.alloc(ComptimeValue, array.len);
        for (array, 0..) |elem, i| {
            result[i] = func(elem);
        }
        return result;
    }

    /// Filter array elements by predicate
    pub fn filter(
        allocator: std.mem.Allocator,
        array: []const ComptimeValue,
        predicate: *const fn (ComptimeValue) bool,
    ) ![]ComptimeValue {
        var temp = std.ArrayList(ComptimeValue).fromOwnedSlice(&[_]ComptimeValue{});
        defer temp.deinit(allocator);

        for (array) |elem| {
            if (predicate(elem)) {
                try temp.append(allocator, elem);
            }
        }

        return temp.toOwnedSlice(allocator);
    }

    /// Reduce array to a single value
    pub fn reduce(
        array: []const ComptimeValue,
        initial: ComptimeValue,
        func: *const fn (ComptimeValue, ComptimeValue) ComptimeValue,
    ) ComptimeValue {
        var accumulator = initial;
        for (array) |elem| {
            accumulator = func(accumulator, elem);
        }
        return accumulator;
    }

    /// Check if all elements satisfy predicate
    pub fn all(array: []const ComptimeValue, predicate: *const fn (ComptimeValue) bool) bool {
        for (array) |elem| {
            if (!predicate(elem)) {
                return false;
            }
        }
        return true;
    }

    /// Check if any element satisfies predicate
    pub fn any(array: []const ComptimeValue, predicate: *const fn (ComptimeValue) bool) bool {
        for (array) |elem| {
            if (predicate(elem)) {
                return true;
            }
        }
        return false;
    }

    /// Sum all numeric elements
    pub fn sum(array: []const ComptimeValue) !ComptimeValue {
        var int_sum: i64 = 0;
        var float_sum: f64 = 0.0;
        var has_int = false;
        var has_float = false;

        for (array) |elem| {
            switch (elem) {
                .int => |v| {
                    int_sum += v;
                    has_int = true;
                },
                .float => |v| {
                    float_sum += v;
                    has_float = true;
                },
                else => return error.TypeMismatch,
            }
        }

        if (has_float) {
            return ComptimeValue{ .float = float_sum + @as(f64, @floatFromInt(int_sum)) };
        }
        return ComptimeValue{ .int = int_sum };
    }

    /// Find minimum value
    pub fn min(array: []const ComptimeValue) !?ComptimeValue {
        if (array.len == 0) return null;

        var min_val = array[0];
        for (array[1..]) |elem| {
            if (try comptimeValueLessThan(elem, min_val)) {
                min_val = elem;
            }
        }
        return min_val;
    }

    /// Find maximum value
    pub fn max(array: []const ComptimeValue) !?ComptimeValue {
        if (array.len == 0) return null;

        var max_val = array[0];
        for (array[1..]) |elem| {
            if (try comptimeValueLessThan(max_val, elem)) {
                max_val = elem;
            }
        }
        return max_val;
    }
};

/// Helper function to compare ComptimeValues for equality
fn comptimeValuesEqual(a: ComptimeValue, b: ComptimeValue) bool {
    return switch (a) {
        .int => |av| b == .int and av == b.int,
        .float => |av| b == .float and av == b.float,
        .bool => |av| b == .bool and av == b.bool,
        .string => |av| b == .string and std.mem.eql(u8, av, b.string),
        else => false,
    };
}

/// Helper function to compare ComptimeValues for less-than
fn comptimeValueLessThan(a: ComptimeValue, b: ComptimeValue) !bool {
    switch (a) {
        .int => |av| {
            if (b == .int) return av < b.int;
            return error.TypeMismatch;
        },
        .float => |av| {
            if (b == .float) return av < b.float;
            return error.TypeMismatch;
        },
        else => return error.TypeMismatch,
    }
}

// Tests

test "TypeReflection - field operations" {
    const testing = std.testing;
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

    try testing.expectEqual(@as(usize, 3), TypeReflection.getFieldCount(type_info));
    try testing.expect(TypeReflection.hasField(type_info, "x"));
    try testing.expect(TypeReflection.hasField(type_info, "y"));
    try testing.expect(!TypeReflection.hasField(type_info, "w"));

    const names = try TypeReflection.getFieldNames(allocator, type_info);
    defer allocator.free(names);

    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("x", names[0]);
}

test "StringOps - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const hello = "Hello";
    const world = "World";

    const concatenated = try StringOps.concat(allocator, hello, world);
    defer allocator.free(concatenated);
    try testing.expectEqualStrings("HelloWorld", concatenated);

    try testing.expectEqual(@as(i64, 5), StringOps.length(hello));

    const upper = try StringOps.toUpper(allocator, hello);
    defer allocator.free(upper);
    try testing.expectEqualStrings("HELLO", upper);

    const lower = try StringOps.toLower(allocator, "WORLD");
    defer allocator.free(lower);
    try testing.expectEqualStrings("world", lower);

    try testing.expect(StringOps.startsWith("Hello World", "Hello"));
    try testing.expect(StringOps.endsWith("Hello World", "World"));
    try testing.expect(StringOps.contains("Hello World", "lo Wo"));
}

test "StringOps - advanced operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const replaced = try StringOps.replaceAll(allocator, "foo bar foo", "foo", "baz");
    defer allocator.free(replaced);
    try testing.expectEqualStrings("baz bar baz", replaced);

    const parts = try StringOps.split(allocator, "a,b,c", ",");
    defer {
        for (parts) |part| allocator.free(part);
        allocator.free(parts);
    }
    try testing.expectEqual(@as(usize, 3), parts.len);

    const joined = try StringOps.join(allocator, &[_][]const u8{ "a", "b", "c" }, "-");
    defer allocator.free(joined);
    try testing.expectEqualStrings("a-b-c", joined);

    const repeated = try StringOps.repeat(allocator, "ab", 3);
    defer allocator.free(repeated);
    try testing.expectEqualStrings("ababab", repeated);
}

test "ArrayOps - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const arr = [_]ComptimeValue{
        ComptimeValue{ .int = 1 },
        ComptimeValue{ .int = 2 },
        ComptimeValue{ .int = 3 },
    };

    try testing.expectEqual(@as(i64, 3), ArrayOps.length(&arr));

    const appended = try ArrayOps.append(allocator, &arr, ComptimeValue{ .int = 4 });
    defer allocator.free(appended);
    try testing.expectEqual(@as(usize, 4), appended.len);

    const concatenated = try ArrayOps.concat(allocator, &arr, &[_]ComptimeValue{ComptimeValue{ .int = 4 }});
    defer allocator.free(concatenated);
    try testing.expectEqual(@as(usize, 4), concatenated.len);

    try testing.expect(ArrayOps.contains(&arr, ComptimeValue{ .int = 2 }));
    try testing.expect(!ArrayOps.contains(&arr, ComptimeValue{ .int = 5 }));
}

test "ArrayOps - sum and min/max" {
    const testing = std.testing;
    _ = testing.allocator;

    const arr = [_]ComptimeValue{
        ComptimeValue{ .int = 1 },
        ComptimeValue{ .int = 2 },
        ComptimeValue{ .int = 3 },
    };

    const sum_val = try ArrayOps.sum(&arr);
    try testing.expectEqual(@as(i64, 6), sum_val.int);

    const min_val = try ArrayOps.min(&arr);
    try testing.expectEqual(@as(i64, 1), min_val.?.int);

    const max_val = try ArrayOps.max(&arr);
    try testing.expectEqual(@as(i64, 3), max_val.?.int);
}
