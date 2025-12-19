// Type Interner for Home Type System
//
// Type interner for canonical type representation.
// Ensures each unique type is stored only once, enabling pointer equality.

const std = @import("std");
const Type = @import("type_system.zig").Type;

/// Type interner for canonical type representation
/// Ensures each unique type is stored only once, enabling pointer equality
pub const TypeInterner = struct {
    allocator: std.mem.Allocator,
    /// Interned types indexed by hash
    types: std.AutoHashMap(u64, *Type),
    /// All allocated types for cleanup
    all_types: std.ArrayListUnmanaged(*Type),

    pub fn init(allocator: std.mem.Allocator) TypeInterner {
        return .{
            .allocator = allocator,
            .types = std.AutoHashMap(u64, *Type).init(allocator),
            .all_types = .{},
        };
    }

    pub fn deinit(self: *TypeInterner) void {
        for (self.all_types.items) |ty| {
            self.allocator.destroy(ty);
        }
        self.all_types.deinit(self.allocator);
        self.types.deinit();
    }

    /// Intern a type, returning canonical pointer
    pub fn intern(self: *TypeInterner, ty: Type) !*Type {
        const hash_val = hashType(&ty);

        if (self.types.get(hash_val)) |existing| {
            return existing;
        }

        const interned = try self.allocator.create(Type);
        interned.* = ty;
        try self.types.put(hash_val, interned);
        try self.all_types.append(self.allocator, interned);
        return interned;
    }

    /// Hash a type for interning
    fn hashType(ty: *const Type) u64 {
        var hasher = std.hash.Wyhash.init(0);

        switch (ty.*) {
            .Int => hasher.update("Int"),
            .I8 => hasher.update("I8"),
            .I16 => hasher.update("I16"),
            .I32 => hasher.update("I32"),
            .I64 => hasher.update("I64"),
            .I128 => hasher.update("I128"),
            .U8 => hasher.update("U8"),
            .U16 => hasher.update("U16"),
            .U32 => hasher.update("U32"),
            .U64 => hasher.update("U64"),
            .U128 => hasher.update("U128"),
            .Float => hasher.update("Float"),
            .F32 => hasher.update("F32"),
            .F64 => hasher.update("F64"),
            .Bool => hasher.update("Bool"),
            .String => hasher.update("String"),
            .Void => hasher.update("Void"),
            .Never => hasher.update("Never"),
            .Unknown => hasher.update("Unknown"),
            .Array => |arr| {
                hasher.update("Array");
                hasher.update(std.mem.asBytes(&hashType(arr.element_type)));
            },
            .Optional => |opt| {
                hasher.update("Optional");
                hasher.update(std.mem.asBytes(&hashType(opt)));
            },
            .Reference => |ref| {
                hasher.update("Reference");
                hasher.update(std.mem.asBytes(&hashType(ref)));
            },
            .Struct => |s| {
                hasher.update("Struct");
                hasher.update(s.name);
            },
            .Enum => |e| {
                hasher.update("Enum");
                hasher.update(e.name);
            },
            else => hasher.update("Other"),
        }

        return hasher.final();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "type interner - deduplication" {
    const allocator = std.testing.allocator;
    var interner = TypeInterner.init(allocator);
    defer interner.deinit();

    const int1 = try interner.intern(Type.Int);
    const int2 = try interner.intern(Type.Int);

    // Same type should return same pointer
    try std.testing.expectEqual(int1, int2);
}

test "type interner - different types get different pointers" {
    const allocator = std.testing.allocator;
    var interner = TypeInterner.init(allocator);
    defer interner.deinit();

    const int_type = try interner.intern(Type.Int);
    const bool_type = try interner.intern(Type.Bool);

    // Different types should have different pointers
    try std.testing.expect(int_type != bool_type);
}
