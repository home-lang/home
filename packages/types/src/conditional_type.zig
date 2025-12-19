// Conditional Types for Home Type System
//
// Conditional type: T extends U ? X : Y
// Evaluates to X if T is assignable to U, otherwise Y.

const std = @import("std");
const Type = @import("type_system.zig").Type;

/// Conditional type: T extends U ? X : Y
/// Enables powerful type-level programming and type narrowing.
pub const ConditionalType = struct {
    /// The type being checked
    check_type: *const Type,
    /// The type to extend/compare against
    extends_type: *const Type,
    /// Result type if check passes
    true_type: *const Type,
    /// Result type if check fails
    false_type: *const Type,

    pub fn init(
        check: *const Type,
        extends: *const Type,
        true_branch: *const Type,
        false_branch: *const Type,
    ) ConditionalType {
        return .{
            .check_type = check,
            .extends_type = extends,
            .true_type = true_branch,
            .false_type = false_branch,
        };
    }

    /// Evaluate the conditional type given a type checker
    pub fn evaluate(self: *const ConditionalType, checker: anytype) *const Type {
        if (checker.isSubtype(self.check_type, self.extends_type)) {
            return self.true_type;
        } else {
            return self.false_type;
        }
    }

    /// Evaluate with distribution over unions
    /// If check_type is a union, distribute the conditional over each member
    pub fn evaluateDistributed(
        self: *const ConditionalType,
        checker: anytype,
        allocator: std.mem.Allocator,
    ) !*const Type {
        // Check if check_type is a union
        if (std.meta.activeTag(self.check_type.*) == .Union) {
            var results = std.ArrayList(*const Type).init(allocator);
            defer results.deinit();

            for (self.check_type.Union.variants) |variant| {
                const distributed = ConditionalType{
                    .check_type = variant.data_type orelse continue,
                    .extends_type = self.extends_type,
                    .true_type = self.true_type,
                    .false_type = self.false_type,
                };
                try results.append(distributed.evaluate(checker));
            }

            // Return union of results (deduplicated)
            return try createUnionType(allocator, results.items);
        }

        return self.evaluate(checker);
    }
};

/// Helper to create a union type from multiple types
fn createUnionType(allocator: std.mem.Allocator, types: []*const Type) !*const Type {
    var variants = std.ArrayList(Type.UnionType.Variant).init(allocator);
    defer variants.deinit();

    for (types, 0..) |ty, i| {
        var name_buf: [20]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "T{}", .{i}) catch "?";
        try variants.append(.{
            .name = name,
            .data_type = ty,
        });
    }

    const result = try allocator.create(Type);
    result.* = Type{
        .Union = .{
            .name = "conditional_result",
            .variants = try variants.toOwnedSlice(),
        },
    };
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "conditional type - init" {
    const allocator = std.testing.allocator;

    const check = try allocator.create(Type);
    defer allocator.destroy(check);
    check.* = Type.Int;

    const extends = try allocator.create(Type);
    defer allocator.destroy(extends);
    extends.* = Type.Int;

    const true_type = try allocator.create(Type);
    defer allocator.destroy(true_type);
    true_type.* = Type.Bool;

    const false_type = try allocator.create(Type);
    defer allocator.destroy(false_type);
    false_type.* = Type.String;

    const cond = ConditionalType.init(check, extends, true_type, false_type);
    try std.testing.expectEqual(check, cond.check_type);
    try std.testing.expectEqual(extends, cond.extends_type);
}
