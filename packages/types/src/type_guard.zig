// Type Guards and Predicates for Home Type System
//
// Type narrowing through control flow analysis.
// Type guards narrow types in conditional branches.

const std = @import("std");
const Type = @import("type_system.zig").Type;

/// Type guard for control-flow based type narrowing
/// Represents a predicate that narrows a type
pub const TypeGuard = struct {
    /// The variable/expression being narrowed
    target: []const u8,
    /// The narrowed type when guard is true
    narrowed_type: *const Type,
    /// The remaining type when guard is false (optional)
    else_type: ?*const Type,

    pub fn init(target: []const u8, narrowed: *const Type) TypeGuard {
        return .{
            .target = target,
            .narrowed_type = narrowed,
            .else_type = null,
        };
    }

    pub fn withElseType(self: TypeGuard, else_type: *const Type) TypeGuard {
        var result = self;
        result.else_type = else_type;
        return result;
    }
};

/// Type predicate for user-defined type guards
/// Example: fn isString(x: unknown) -> x is string
pub const TypePredicate = struct {
    /// Parameter being tested
    parameter_name: []const u8,
    /// The type that parameter is narrowed to
    asserted_type: *const Type,

    pub fn init(param: []const u8, asserted: *const Type) TypePredicate {
        return .{
            .parameter_name = param,
            .asserted_type = asserted,
        };
    }
};

// ============================================================================
// Recursive Type Alias
// ============================================================================

/// Recursive type alias for self-referential types
/// Example: type LinkedList<T> = { value: T, next: LinkedList<T>? }
pub const RecursiveTypeAlias = struct {
    /// Alias name
    name: []const u8,
    /// Type parameters
    params: []const []const u8,
    /// The type definition (may reference itself by name)
    definition: *const Type,

    pub fn init(name: []const u8, params: []const []const u8, definition: *const Type) RecursiveTypeAlias {
        return .{
            .name = name,
            .params = params,
            .definition = definition,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "type guard - init" {
    const allocator = std.testing.allocator;

    const narrowed = try allocator.create(Type);
    defer allocator.destroy(narrowed);
    narrowed.* = Type.String;

    const guard = TypeGuard.init("value", narrowed);
    try std.testing.expectEqualStrings("value", guard.target);
    try std.testing.expectEqual(narrowed, guard.narrowed_type);
    try std.testing.expect(guard.else_type == null);
}

test "type guard - with else type" {
    const allocator = std.testing.allocator;

    const narrowed = try allocator.create(Type);
    defer allocator.destroy(narrowed);
    narrowed.* = Type.String;

    const else_type = try allocator.create(Type);
    defer allocator.destroy(else_type);
    else_type.* = Type.Int;

    const guard = TypeGuard.init("value", narrowed).withElseType(else_type);
    try std.testing.expectEqual(else_type, guard.else_type);
}

test "type predicate - init" {
    const allocator = std.testing.allocator;

    const asserted = try allocator.create(Type);
    defer allocator.destroy(asserted);
    asserted.* = Type.String;

    const predicate = TypePredicate.init("x", asserted);
    try std.testing.expectEqualStrings("x", predicate.parameter_name);
    try std.testing.expectEqual(asserted, predicate.asserted_type);
}

test "recursive type alias - init" {
    const allocator = std.testing.allocator;

    const definition = try allocator.create(Type);
    defer allocator.destroy(definition);
    definition.* = Type{ .Struct = .{ .name = "LinkedList", .fields = &.{} } };

    const params = [_][]const u8{"T"};
    const alias = RecursiveTypeAlias.init("LinkedList", &params, definition);

    try std.testing.expectEqualStrings("LinkedList", alias.name);
    try std.testing.expectEqual(@as(usize, 1), alias.params.len);
}
