// Intersection Types for Home Type System
//
// Intersection type: A & B
// Represents a value that satisfies ALL constituent types simultaneously.

const std = @import("std");
const Type = @import("type_system.zig").Type;

/// Intersection type: A & B
/// Unlike unions (A | B) where a value is ONE of the types,
/// intersections require the value to be ALL types at once.
pub const IntersectionType = struct {
    /// Types that must all be satisfied
    types: []const *const Type,

    pub fn init(types: []const *const Type) IntersectionType {
        return .{ .types = types };
    }

    /// Check if a type satisfies this intersection
    pub fn isSatisfiedBy(self: *const IntersectionType, candidate: *const Type, checker: anytype) bool {
        for (self.types) |required| {
            if (!checker.isSubtype(candidate, required)) {
                return false;
            }
        }
        return true;
    }

    /// Flatten nested intersections: (A & B) & C -> A & B & C
    pub fn flatten(self: *const IntersectionType, allocator: std.mem.Allocator) !IntersectionType {
        var flattened = std.ArrayListUnmanaged(*const Type){};
        defer flattened.deinit(allocator);

        for (self.types) |ty| {
            if (std.meta.activeTag(ty.*) == .Intersection) {
                const nested = ty.Intersection;
                for (nested.types) |inner| {
                    try flattened.append(allocator, inner);
                }
            } else {
                try flattened.append(allocator, ty);
            }
        }

        return .{ .types = try flattened.toOwnedSlice(allocator) };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "intersection type - init" {
    const allocator = std.testing.allocator;
    const int_type_ptr = try allocator.create(Type);
    defer allocator.destroy(int_type_ptr);
    int_type_ptr.* = Type.Int;

    const bool_type_ptr = try allocator.create(Type);
    defer allocator.destroy(bool_type_ptr);
    bool_type_ptr.* = Type.Bool;

    var types = [_]*const Type{ int_type_ptr, bool_type_ptr };
    const intersection = IntersectionType.init(&types);
    try std.testing.expectEqual(@as(usize, 2), intersection.types.len);
}
