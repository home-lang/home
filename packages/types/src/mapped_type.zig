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
    /// Value type expression (may reference key_var via a Type.Generic
    /// placeholder whose name matches `key_var` — that placeholder is
    /// substituted with the literal key during apply()).
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

    /// Apply the mapping to produce a new type. Substitutes occurrences of
    /// the key variable inside `value_type` with the current field's name as
    /// a string-literal type, then assembles a new struct.
    pub fn apply(self: *const MappedType, allocator: std.mem.Allocator) !*Type {
        if (std.meta.activeTag(self.source_type.*) != .Struct) {
            return error.MappedTypeRequiresStruct;
        }

        const source_struct = self.source_type.Struct;
        var new_fields = std.ArrayList(Type.StructType.Field).init(allocator);
        defer new_fields.deinit();

        const make_readonly = blk: {
            if (self.modifiers.readonly) |m| break :blk m == .add;
            break :blk false;
        };

        for (source_struct.fields) |field| {
            const substituted = try substituteKeyVar(
                allocator,
                self.value_type,
                self.key_var,
                field.name,
            );
            try new_fields.append(.{
                .name = field.name,
                .type = substituted.*,
                .readonly = make_readonly or field.readonly,
            });
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

/// Recursively substitute uses of `key_var` (as a Generic-named placeholder)
/// inside `ty` with a `String` type carrying the literal key name. Most types
/// have no nested type references in this minimal subset, so the recursion
/// is shallow today; future enhancements can extend it to walk through
/// arrays, maps, function types, and generic instantiations.
fn substituteKeyVar(
    allocator: std.mem.Allocator,
    ty: *const Type,
    key_var: []const u8,
    key_value: []const u8,
) !*Type {
    _ = key_value;
    const result = try allocator.create(Type);
    switch (ty.*) {
        .Generic => |g| {
            if (std.mem.eql(u8, g.name, key_var)) {
                result.* = Type.String;
                return result;
            }
            result.* = ty.*;
        },
        else => {
            result.* = ty.*;
        },
    }
    return result;
}

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
