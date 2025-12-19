// Mapped Types for Home Type System
//
// Mapped type: { [K in keyof T]: V }
// Transforms each property of a type according to a mapping function.

const std = @import("std");
const Type = @import("type_system.zig").Type;

/// Mapped type: { [K in keyof T]: V }
/// Transforms each property of a type according to a mapping function.
pub const MappedType = struct {
    /// Source type to map over
    source_type: *const Type,
    /// Key variable name (e.g., "K" in [K in keyof T])
    key_var: []const u8,
    /// Value type expression (can reference key_var)
    value_type: *const Type,
    /// Optional modifiers
    modifiers: Modifiers = .{},

    pub const Modifiers = struct {
        /// Add/remove readonly modifier
        readonly: ?Modifier = null,
        /// Add/remove optional modifier
        optional: ?Modifier = null,

        pub const Modifier = enum {
            add, // +readonly or +?
            remove, // -readonly or -?
        };
    };

    pub fn init(source: *const Type, key_var: []const u8, value: *const Type) MappedType {
        return .{
            .source_type = source,
            .key_var = key_var,
            .value_type = value,
        };
    }

    /// Apply the mapping to produce a new type
    pub fn apply(self: *const MappedType, allocator: std.mem.Allocator) !*Type {
        // Source must be a struct type
        if (std.meta.activeTag(self.source_type.*) != .Struct) {
            return error.MappedTypeRequiresStruct;
        }

        const source_struct = self.source_type.Struct;
        var new_fields = std.ArrayList(Type.StructType.Field).init(allocator);
        defer new_fields.deinit();

        for (source_struct.fields) |field| {
            // Apply value type transformation
            // In a full implementation, we'd substitute key_var with field.name
            const new_field = Type.StructType.Field{
                .name = field.name,
                .type = self.value_type.*,
            };
            try new_fields.append(new_field);
        }

        const result = try allocator.create(Type);
        result.* = Type{
            .Struct = .{
                .name = source_struct.name,
                .fields = try new_fields.toOwnedSlice(),
            },
        };
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "mapped type - init" {
    const allocator = std.testing.allocator;

    const source = try allocator.create(Type);
    defer allocator.destroy(source);
    source.* = Type{ .Struct = .{ .name = "Test", .fields = &.{} } };

    const value = try allocator.create(Type);
    defer allocator.destroy(value);
    value.* = Type.Bool;

    const mapped = MappedType.init(source, "K", value);
    try std.testing.expectEqualStrings("K", mapped.key_var);
}
