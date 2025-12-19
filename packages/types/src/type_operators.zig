// Type Operators for Home Type System
//
// Type operators: keyof, typeof, infer
// Enable type-level programming and type extraction.

const std = @import("std");
const Type = @import("type_system.zig").Type;

// ============================================================================
// Keyof Type
// ============================================================================

/// keyof operator: keyof T
/// Produces a union of all property keys of type T.
pub const KeyofType = struct {
    /// The type to extract keys from
    target_type: *const Type,

    pub fn init(target: *const Type) KeyofType {
        return .{ .target_type = target };
    }

    /// Evaluate keyof to get the keys as a union of literal types
    pub fn evaluate(self: *const KeyofType, allocator: std.mem.Allocator) !*Type {
        switch (self.target_type.*) {
            .Struct => |s| {
                if (s.fields.len == 0) {
                    const result = try allocator.create(Type);
                    result.* = Type.Void;
                    return result;
                }

                // Create union of string literal types for each field name
                var variants = std.ArrayListUnmanaged(Type.UnionType.Variant){};
                defer variants.deinit(allocator);

                for (s.fields) |field| {
                    try variants.append(allocator, .{
                        .name = field.name,
                        .data_type = null, // Literal type - just the name
                    });
                }

                const result = try allocator.create(Type);
                result.* = Type{
                    .Union = .{
                        .name = "keyof",
                        .variants = try variants.toOwnedSlice(allocator),
                    },
                };
                return result;
            },
            .Map => {
                // keyof Map<K, V> = K
                const result = try allocator.create(Type);
                result.* = self.target_type.Map.key_type.*;
                return result;
            },
            .Tuple => |t| {
                // keyof (A, B, C) = 0 | 1 | 2
                var variants = std.ArrayListUnmanaged(Type.UnionType.Variant){};
                defer variants.deinit(allocator);

                for (t.element_types, 0..) |_, i| {
                    var name_buf: [20]u8 = undefined;
                    const name = std.fmt.bufPrint(&name_buf, "{}", .{i}) catch "?";
                    try variants.append(allocator, .{
                        .name = name,
                        .data_type = null,
                    });
                }

                const result = try allocator.create(Type);
                result.* = Type{
                    .Union = .{
                        .name = "keyof",
                        .variants = try variants.toOwnedSlice(allocator),
                    },
                };
                return result;
            },
            else => {
                // keyof on non-object types returns never
                const result = try allocator.create(Type);
                result.* = Type.Void;
                return result;
            },
        }
    }
};

// ============================================================================
// Typeof Type
// ============================================================================

/// typeof operator for extracting type from value expression
pub const TypeofType = struct {
    /// Variable/expression to get type of
    expression_name: []const u8,
    /// Resolved type (filled in during type checking)
    resolved_type: ?*const Type = null,

    pub fn init(expr: []const u8) TypeofType {
        return .{ .expression_name = expr };
    }
};

// ============================================================================
// Infer Type
// ============================================================================

/// infer keyword for type extraction in conditional types
pub const InferType = struct {
    /// Name for the inferred type variable
    name: []const u8,
    /// Constraint on the inferred type (optional)
    constraint: ?*const Type = null,

    pub fn init(name: []const u8) InferType {
        return .{ .name = name };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "keyof type - init" {
    const allocator = std.testing.allocator;

    const target = try allocator.create(Type);
    defer allocator.destroy(target);
    target.* = Type{ .Struct = .{ .name = "Test", .fields = &.{} } };

    const keyof = KeyofType.init(target);
    try std.testing.expectEqual(target, keyof.target_type);
}

test "typeof type - init" {
    const typeof_type = TypeofType.init("myVariable");
    try std.testing.expectEqualStrings("myVariable", typeof_type.expression_name);
    try std.testing.expect(typeof_type.resolved_type == null);
}

test "infer type - init" {
    const infer_type = InferType.init("T");
    try std.testing.expectEqualStrings("T", infer_type.name);
    try std.testing.expect(infer_type.constraint == null);
}
