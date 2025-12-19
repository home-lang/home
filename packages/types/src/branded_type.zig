// Branded and Index Access Types for Home Type System
//
// Branded types for nominal typing of primitives.
// Index access types for property access: T[K]

const std = @import("std");
const Type = @import("type_system.zig").Type;

// ============================================================================
// Branded Types
// ============================================================================

/// Branded type for nominal typing of primitives
/// Creates a distinct type from a base type without runtime overhead.
/// Example: type UserId = Brand<i64, "UserId">
/// Prevents accidentally mixing UserId with OrderId even though both are i64
pub const BrandedType = struct {
    /// The underlying base type
    base_type: *const Type,
    /// Unique brand identifier (compile-time string)
    brand: []const u8,

    pub fn init(base: *const Type, brand: []const u8) BrandedType {
        return .{
            .base_type = base,
            .brand = brand,
        };
    }

    /// Check if two branded types are equal (requires same brand)
    pub fn eql(self: BrandedType, other: BrandedType) bool {
        return std.mem.eql(u8, self.brand, other.brand) and
            self.base_type.equals(other.base_type.*);
    }

    /// Check if a value can be assigned to this branded type
    /// Only exact brand matches are allowed (no implicit conversion)
    pub fn isAssignableFrom(self: *const BrandedType, other: *const Type) bool {
        // Only branded types with same brand can be assigned
        if (std.meta.activeTag(other.*) == .Branded) {
            const other_branded = other.Branded;
            // Compare brand names and base types
            return std.mem.eql(u8, self.brand, other_branded.brand) and
                self.base_type.equals(other_branded.base_type.*);
        }
        return false;
    }
};

// ============================================================================
// Opaque Types
// ============================================================================

/// Opaque type - hides implementation details
/// Only the module that defines it can see the underlying type
pub const OpaqueType = struct {
    /// The hidden underlying type (only accessible within defining module)
    underlying_type: *const Type,
    /// Unique identifier for this opaque type
    name: []const u8,
    /// Module that defined this opaque type
    defining_module: ?[]const u8,

    pub fn init(underlying: *const Type, name: []const u8) OpaqueType {
        return .{
            .underlying_type = underlying,
            .name = name,
            .defining_module = null,
        };
    }
};

// ============================================================================
// Index Access Types
// ============================================================================

/// Index access type: T[K]
/// Accesses a property type from an object/tuple type using a key.
/// Example: User["email"] -> string, Tuple[0] -> FirstElementType
pub const IndexAccessType = struct {
    /// The object/tuple type to access
    object_type: *const Type,
    /// The index/key type (typically a literal or keyof result)
    index_type: *const Type,

    pub fn init(object: *const Type, index: *const Type) IndexAccessType {
        return .{
            .object_type = object,
            .index_type = index,
        };
    }

    /// Evaluate the index access to get the property type
    pub fn evaluate(self: *const IndexAccessType, allocator: std.mem.Allocator) !*Type {
        switch (self.object_type.*) {
            .Struct => |s| {
                // For struct, index must be a string literal
                if (std.meta.activeTag(self.index_type.*) == .Literal) {
                    const lit = self.index_type.Literal;
                    if (lit == .string) {
                        const key = lit.string;
                        for (s.fields) |field| {
                            if (std.mem.eql(u8, field.name, key)) {
                                const result = try allocator.create(Type);
                                result.* = field.type;
                                return result;
                            }
                        }
                    }
                }
                // Key not found - return never
                const result = try allocator.create(Type);
                result.* = Type.Never;
                return result;
            },
            .Tuple => |t| {
                // For tuple, index must be an integer literal
                if (std.meta.activeTag(self.index_type.*) == .Literal) {
                    const lit = self.index_type.Literal;
                    if (lit == .integer) {
                        const idx: usize = @intCast(lit.integer);
                        if (idx < t.element_types.len) {
                            const result = try allocator.create(Type);
                            result.* = t.element_types[idx];
                            return result;
                        }
                    }
                }
                // Index out of bounds - return never
                const result = try allocator.create(Type);
                result.* = Type.Never;
                return result;
            },
            .Array => |a| {
                // Array[number] returns element type
                const result = try allocator.create(Type);
                result.* = a.element_type.*;
                return result;
            },
            .Map => |m| {
                // Map[K] returns value type
                const result = try allocator.create(Type);
                result.* = m.value_type.*;
                return result;
            },
            else => {
                // Invalid index access - return never
                const result = try allocator.create(Type);
                result.* = Type.Never;
                return result;
            },
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "branded type - init" {
    const allocator = std.testing.allocator;

    const base = try allocator.create(Type);
    defer allocator.destroy(base);
    base.* = Type.I64;

    const branded = BrandedType.init(base, "UserId");
    try std.testing.expectEqualStrings("UserId", branded.brand);
}

test "branded type - equality" {
    const allocator = std.testing.allocator;

    const base1 = try allocator.create(Type);
    defer allocator.destroy(base1);
    base1.* = Type.I64;

    const base2 = try allocator.create(Type);
    defer allocator.destroy(base2);
    base2.* = Type.I64;

    const userId1 = BrandedType.init(base1, "UserId");
    const userId2 = BrandedType.init(base2, "UserId");
    const orderId = BrandedType.init(base1, "OrderId");

    try std.testing.expect(userId1.eql(userId2));
    try std.testing.expect(!userId1.eql(orderId));
}

test "branded type - different base types" {
    const allocator = std.testing.allocator;

    const i64_type = try allocator.create(Type);
    defer allocator.destroy(i64_type);
    i64_type.* = Type.I64;

    const string_type = try allocator.create(Type);
    defer allocator.destroy(string_type);
    string_type.* = Type.String;

    const brand1 = BrandedType.init(i64_type, "Id");
    const brand2 = BrandedType.init(string_type, "Id");

    // Same brand but different base types - not equal
    try std.testing.expect(!brand1.eql(brand2));
}

test "index access type - init" {
    const allocator = std.testing.allocator;

    const obj = try allocator.create(Type);
    defer allocator.destroy(obj);
    obj.* = Type{ .Struct = .{ .name = "User", .fields = &.{} } };

    const idx = try allocator.create(Type);
    defer allocator.destroy(idx);
    idx.* = Type{ .Literal = .{ .string = "name" } };

    const access = IndexAccessType.init(obj, idx);
    try std.testing.expectEqual(obj, access.object_type);
    try std.testing.expectEqual(idx, access.index_type);
}

test "opaque type - init" {
    const allocator = std.testing.allocator;

    const underlying = try allocator.create(Type);
    defer allocator.destroy(underlying);
    underlying.* = Type.I64;

    const opaque_type = OpaqueType.init(underlying, "FileHandle");
    try std.testing.expectEqualStrings("FileHandle", opaque_type.name);
    try std.testing.expect(opaque_type.defining_module == null);
}
