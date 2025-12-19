// Variance Annotations for Home Type System
//
// Variance controls how generic types interact with subtyping.
// Covariant (out), Contravariant (in), Invariant, Bivariant

const std = @import("std");
const Type = @import("type_system.zig").Type;

/// Variance annotation for generic type parameters
/// Controls how generic types interact with subtyping
pub const Variance = enum {
    /// Covariant (out T) - T only appears in output positions
    /// If A <: B, then Container<A> <: Container<B>
    covariant,

    /// Contravariant (in T) - T only appears in input positions
    /// If A <: B, then Container<B> <: Container<A>
    contravariant,

    /// Invariant - T appears in both input and output positions
    /// Container<A> is only subtype of Container<B> if A = B
    invariant,

    /// Bivariant - special case (usually unsound but sometimes needed)
    /// Container<A> <: Container<B> regardless of A and B relationship
    bivariant,
};

/// Generic type parameter with variance annotation
pub const VariantTypeParam = struct {
    /// Parameter name (e.g., "T", "K", "V")
    name: []const u8,
    /// Variance annotation
    variance: Variance,
    /// Optional constraint/bound
    constraint: ?*const Type,
    /// Optional default type
    default_type: ?*const Type,

    pub fn init(name: []const u8, variance: Variance) VariantTypeParam {
        return .{
            .name = name,
            .variance = variance,
            .constraint = null,
            .default_type = null,
        };
    }

    pub fn withConstraint(self: VariantTypeParam, constraint: *const Type) VariantTypeParam {
        var result = self;
        result.constraint = constraint;
        return result;
    }

    pub fn withDefault(self: VariantTypeParam, default: *const Type) VariantTypeParam {
        var result = self;
        result.default_type = default;
        return result;
    }
};

/// Check if a type assignment respects variance rules
pub fn checkVariance(
    param: VariantTypeParam,
    from_type: *const Type,
    to_type: *const Type,
    isSubtype: fn (*const Type, *const Type) bool,
) bool {
    return switch (param.variance) {
        .covariant => isSubtype(from_type, to_type),
        .contravariant => isSubtype(to_type, from_type),
        .invariant => from_type.equals(to_type.*),
        .bivariant => true,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "variance - enum values" {
    try std.testing.expect(@intFromEnum(Variance.covariant) == 0);
    try std.testing.expect(@intFromEnum(Variance.contravariant) == 1);
    try std.testing.expect(@intFromEnum(Variance.invariant) == 2);
    try std.testing.expect(@intFromEnum(Variance.bivariant) == 3);
}

test "variant type param - init" {
    const param = VariantTypeParam.init("T", .covariant);
    try std.testing.expectEqualStrings("T", param.name);
    try std.testing.expectEqual(Variance.covariant, param.variance);
    try std.testing.expect(param.constraint == null);
    try std.testing.expect(param.default_type == null);
}

test "variant type param - with constraint" {
    const allocator = std.testing.allocator;

    const constraint = try allocator.create(Type);
    defer allocator.destroy(constraint);
    constraint.* = Type.Int;

    const param = VariantTypeParam.init("T", .invariant).withConstraint(constraint);
    try std.testing.expectEqual(constraint, param.constraint);
}
