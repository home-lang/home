// TypeScript-like Type System Extensions for Home
//
// This module provides TypeScript-inspired type features:
// - Intersection types (A & B)
// - Conditional types (T extends U ? X : Y)
// - Mapped types ({[K in keyof T]: V})
// - Utility types (Partial, Required, Pick, Omit, etc.)
// - Type operators (keyof, typeof, infer)
// - Literal types
// - Template literal types
//
// Each type is now in its own dedicated file for better organization.
// This file re-exports all types for backward compatibility.

const std = @import("std");
pub const Type = @import("type_system.zig").Type;

// ============================================================================
// Re-exports from individual type files
// ============================================================================

// Module re-exports for direct access
pub const intersection_mod = @import("intersection_type.zig");
pub const conditional_mod = @import("conditional_type.zig");
pub const mapped_mod = @import("mapped_type.zig");
pub const operators_mod = @import("type_operators.zig");
pub const literal_mod = @import("literal_type.zig");
pub const utility_mod = @import("utility_types.zig");
pub const interner_mod = @import("type_interner.zig");
pub const branded_mod = @import("branded_type.zig");
pub const variance_mod = @import("variance.zig");
pub const guard_mod = @import("type_guard.zig");
pub const string_manip_mod = @import("string_manipulation_type.zig");

// ============================================================================
// Type Re-exports (Backward Compatibility)
// ============================================================================

// Intersection Types
pub const IntersectionType = intersection_mod.IntersectionType;

// Conditional Types
pub const ConditionalType = conditional_mod.ConditionalType;

// Mapped Types
pub const MappedType = mapped_mod.MappedType;

// Type Operators
pub const KeyofType = operators_mod.KeyofType;
pub const TypeofType = operators_mod.TypeofType;
pub const InferType = operators_mod.InferType;

// Literal Types
pub const LiteralType = literal_mod.LiteralType;
pub const TemplateLiteralType = literal_mod.TemplateLiteralType;

// Utility Types
pub const UtilityTypes = utility_mod.UtilityTypes;

// Type Interner
pub const TypeInterner = interner_mod.TypeInterner;

// Branded and Index Access Types
pub const IndexAccessType = branded_mod.IndexAccessType;
pub const BrandedType = branded_mod.BrandedType;
pub const OpaqueType = branded_mod.OpaqueType;

// String Manipulation Types
pub const StringManipulationType = string_manip_mod.StringManipulationType;

// Variance
pub const Variance = variance_mod.Variance;
pub const VariantTypeParam = variance_mod.VariantTypeParam;
pub const checkVariance = variance_mod.checkVariance;

// Type Guards
pub const TypeGuard = guard_mod.TypeGuard;
pub const TypePredicate = guard_mod.TypePredicate;
pub const RecursiveTypeAlias = guard_mod.RecursiveTypeAlias;

// ============================================================================
// Helper Functions
// ============================================================================

/// Helper to create a union type from multiple types
pub fn createUnionType(allocator: std.mem.Allocator, types: []*const Type) !*const Type {
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
            .name = "union_result",
            .variants = try variants.toOwnedSlice(),
        },
    };
    return result;
}

// ============================================================================
// Tests - Re-export tests from individual modules
// ============================================================================

test "intersection type satisfaction" {
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

test "literal type equality" {
    const lit1 = LiteralType{ .string = "hello" };
    const lit2 = LiteralType{ .string = "hello" };
    const lit3 = LiteralType{ .string = "world" };

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "type interner deduplication" {
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

test "literal type - string equality" {
    const lit1 = LiteralType{ .string = "hello" };
    const lit2 = LiteralType{ .string = "hello" };
    const lit3 = LiteralType{ .string = "world" };

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "literal type - float equality" {
    const lit1 = LiteralType.floatLiteral(3.14);
    const lit2 = LiteralType.floatLiteral(3.14);
    const lit3 = LiteralType.floatLiteral(2.71);

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "literal type - boolean equality" {
    const lit1 = LiteralType.booleanLiteral(true);
    const lit2 = LiteralType.booleanLiteral(true);
    const lit3 = LiteralType.booleanLiteral(false);

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "literal type - null and undefined" {
    const null1 = LiteralType{ .null_type = {} };
    const null2 = LiteralType{ .null_type = {} };
    const undef = LiteralType{ .undefined_type = {} };

    try std.testing.expect(null1.eql(null2));
    try std.testing.expect(!null1.eql(undef));
}

test "literal type - cross-type inequality" {
    const str = LiteralType.stringLiteral("42");
    const int = LiteralType.integerLiteral(42);

    try std.testing.expect(!str.eql(int));
}

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

test "template literal type - init" {
    const allocator = std.testing.allocator;

    const str_type = try allocator.create(Type);
    defer allocator.destroy(str_type);
    str_type.* = Type.String;

    const parts = [_]TemplateLiteralType.Part{
        .{ .literal = "hello_" },
        .{ .type_placeholder = str_type },
    };
    const template = TemplateLiteralType.init(&parts);
    try std.testing.expectEqual(@as(usize, 2), template.parts.len);
}

test "edge case - literal type with empty string" {
    const lit1 = LiteralType.stringLiteral("");
    const lit2 = LiteralType.stringLiteral("");
    try std.testing.expect(lit1.eql(lit2));
}

test "edge case - literal type with max i64" {
    const lit1 = LiteralType.integerLiteral(std.math.maxInt(i64));
    const lit2 = LiteralType.integerLiteral(std.math.maxInt(i64));
    try std.testing.expect(lit1.eql(lit2));
}

test "edge case - literal type with min i64" {
    const lit1 = LiteralType.integerLiteral(std.math.minInt(i64));
    const lit2 = LiteralType.integerLiteral(std.math.minInt(i64));
    try std.testing.expect(lit1.eql(lit2));
}

test "edge case - literal type with infinity" {
    const lit1 = LiteralType.floatLiteral(std.math.inf(f64));
    const lit2 = LiteralType.floatLiteral(std.math.inf(f64));
    try std.testing.expect(lit1.eql(lit2));
}

test "edge case - literal type with negative infinity" {
    const lit1 = LiteralType.floatLiteral(-std.math.inf(f64));
    const lit2 = LiteralType.floatLiteral(-std.math.inf(f64));
    try std.testing.expect(lit1.eql(lit2));
}

test "never type - basic usage" {
    const never_type: Type = .Never;
    const int_type: Type = .Int;

    try std.testing.expect(!never_type.equals(int_type));
    try std.testing.expect(never_type.equals(Type.Never));
}

test "unknown type - basic usage" {
    const unknown_type: Type = .Unknown;
    const int_type: Type = .Int;

    try std.testing.expect(!unknown_type.equals(int_type));
    try std.testing.expect(unknown_type.equals(Type.Unknown));
}

test "never and unknown equality" {
    const never_type: Type = .Never;
    const unknown_type: Type = .Unknown;

    try std.testing.expect(!never_type.equals(unknown_type));
}

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

test "opaque type - init" {
    const allocator = std.testing.allocator;

    const underlying = try allocator.create(Type);
    defer allocator.destroy(underlying);
    underlying.* = Type.I64;

    const opaque_type = OpaqueType.init(underlying, "FileHandle");
    try std.testing.expectEqualStrings("FileHandle", opaque_type.name);
    try std.testing.expect(opaque_type.defining_module == null);
}

test "string manipulation - uppercase" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "hello" } };

    const manip = StringManipulationType{ .uppercase = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("HELLO", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "string manipulation - lowercase" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "HELLO" } };

    const manip = StringManipulationType{ .lowercase = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("hello", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "string manipulation - capitalize" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "hello" } };

    const manip = StringManipulationType{ .capitalize = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("Hello", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "string manipulation - trim" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "  hello  " } };

    const manip = StringManipulationType{ .trim = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("hello", result.Literal.string);
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

// ============================================================================
// Subtyping Tests
// ============================================================================

test "isSubtype - equal types" {
    const int_type: Type = .Int;
    const bool_type: Type = .Bool;
    const string_type: Type = .String;

    try std.testing.expect(int_type.isSubtype(int_type));
    try std.testing.expect(bool_type.isSubtype(bool_type));
    try std.testing.expect(string_type.isSubtype(string_type));
}

test "isSubtype - Never is subtype of everything" {
    const never_type: Type = .Never;
    const int_type: Type = .Int;
    const bool_type: Type = .Bool;
    const string_type: Type = .String;

    try std.testing.expect(never_type.isSubtype(int_type));
    try std.testing.expect(never_type.isSubtype(bool_type));
    try std.testing.expect(never_type.isSubtype(string_type));
    try std.testing.expect(never_type.isSubtype(never_type));
}

test "isSubtype - everything is subtype of Unknown" {
    const unknown_type: Type = .Unknown;
    const int_type: Type = .Int;
    const bool_type: Type = .Bool;
    const string_type: Type = .String;
    const never_type: Type = .Never;

    try std.testing.expect(int_type.isSubtype(unknown_type));
    try std.testing.expect(bool_type.isSubtype(unknown_type));
    try std.testing.expect(string_type.isSubtype(unknown_type));
    try std.testing.expect(never_type.isSubtype(unknown_type));
}

test "isSubtype - integer widening" {
    const i8_type: Type = .I8;
    const i16_type: Type = .I16;
    const i32_type: Type = .I32;
    const i64_type: Type = .I64;
    const int_type: Type = .Int;

    try std.testing.expect(i8_type.isSubtype(i16_type));
    try std.testing.expect(i8_type.isSubtype(i32_type));
    try std.testing.expect(i8_type.isSubtype(i64_type));
    try std.testing.expect(i16_type.isSubtype(i32_type));
    try std.testing.expect(i16_type.isSubtype(i64_type));
    try std.testing.expect(i32_type.isSubtype(i64_type));
    try std.testing.expect(i32_type.isSubtype(int_type));

    try std.testing.expect(!i64_type.isSubtype(i32_type));
    try std.testing.expect(!i32_type.isSubtype(i16_type));
}

test "isSubtype - unsigned integer widening" {
    const u8_type: Type = .U8;
    const u16_type: Type = .U16;
    const u32_type: Type = .U32;
    const u64_type: Type = .U64;
    const i8_type: Type = .I8;

    try std.testing.expect(u8_type.isSubtype(u16_type));
    try std.testing.expect(u8_type.isSubtype(u32_type));
    try std.testing.expect(u8_type.isSubtype(u64_type));
    try std.testing.expect(u16_type.isSubtype(u32_type));
    try std.testing.expect(u32_type.isSubtype(u64_type));

    try std.testing.expect(!u8_type.isSubtype(i8_type));
}

test "isSubtype - float widening" {
    const f32_type: Type = .F32;
    const f64_type: Type = .F64;
    const float_type: Type = .Float;

    try std.testing.expect(f32_type.isSubtype(f64_type));
    try std.testing.expect(f32_type.isSubtype(float_type));
    try std.testing.expect(!f64_type.isSubtype(f32_type));
}

test "isSubtype - value to optional" {
    const allocator = std.testing.allocator;

    const inner_int = try allocator.create(Type);
    defer allocator.destroy(inner_int);
    inner_int.* = .Int;

    const optional_int: Type = .{ .Optional = inner_int };
    const int_type: Type = .Int;
    const string_type: Type = .String;

    try std.testing.expect(int_type.isSubtype(optional_int));
    try std.testing.expect(!string_type.isSubtype(optional_int));
}

test "isSubtype - function covariant return" {
    const allocator = std.testing.allocator;

    const i32_ret = try allocator.create(Type);
    defer allocator.destroy(i32_ret);
    i32_ret.* = .I32;
    const fn1: Type = .{ .Function = .{ .params = &.{}, .return_type = i32_ret } };

    const i64_ret = try allocator.create(Type);
    defer allocator.destroy(i64_ret);
    i64_ret.* = .I64;
    const fn2: Type = .{ .Function = .{ .params = &.{}, .return_type = i64_ret } };

    try std.testing.expect(fn1.isSubtype(fn2));
    try std.testing.expect(!fn2.isSubtype(fn1));
}

test "isSubtype - function contravariant params" {
    const allocator = std.testing.allocator;

    const void_ret = try allocator.create(Type);
    defer allocator.destroy(void_ret);
    void_ret.* = .Void;

    var params1 = [_]Type{.I64};
    const fn1: Type = .{ .Function = .{ .params = &params1, .return_type = void_ret } };

    var params2 = [_]Type{.I32};
    const fn2: Type = .{ .Function = .{ .params = &params2, .return_type = void_ret } };

    try std.testing.expect(fn1.isSubtype(fn2));
    try std.testing.expect(!fn2.isSubtype(fn1));
}

test "isSubtype - array covariance" {
    const allocator = std.testing.allocator;

    const i32_elem = try allocator.create(Type);
    defer allocator.destroy(i32_elem);
    i32_elem.* = .I32;
    const arr1: Type = .{ .Array = .{ .element_type = i32_elem } };

    const i64_elem = try allocator.create(Type);
    defer allocator.destroy(i64_elem);
    i64_elem.* = .I64;
    const arr2: Type = .{ .Array = .{ .element_type = i64_elem } };

    try std.testing.expect(arr1.isSubtype(arr2));
}

test "isSubtype - struct width subtyping" {
    const sub_fields = [_]Type.StructType.Field{
        .{ .name = "x", .type = .Int },
        .{ .name = "y", .type = .Int },
        .{ .name = "z", .type = .Int },
    };
    const sub_struct: Type = .{ .Struct = .{ .name = "Point3D", .fields = &sub_fields } };

    const super_fields = [_]Type.StructType.Field{
        .{ .name = "x", .type = .Int },
        .{ .name = "y", .type = .Int },
    };
    const super_struct: Type = .{ .Struct = .{ .name = "Point2D", .fields = &super_fields } };

    try std.testing.expect(sub_struct.isSubtype(super_struct));
    try std.testing.expect(!super_struct.isSubtype(sub_struct));
}

test "isSubtype - no subtype for unrelated types" {
    const int_type: Type = .Int;
    const bool_type: Type = .Bool;
    const string_type: Type = .String;

    try std.testing.expect(!int_type.isSubtype(bool_type));
    try std.testing.expect(!string_type.isSubtype(int_type));
    try std.testing.expect(!bool_type.isSubtype(string_type));
}

// ============================================================================
// Assignability Tests
// ============================================================================

test "isAssignable - immutable context uses subtyping" {
    const i32_type: Type = .I32;
    const i64_type: Type = .I64;
    const never_type: Type = .Never;
    const int_type: Type = .Int;

    try std.testing.expect(i32_type.isAssignable(i64_type, false));
    try std.testing.expect(never_type.isAssignable(int_type, false));
}

test "isAssignable - mutable context requires exact equality" {
    const i32_type: Type = .I32;
    const i64_type: Type = .I64;

    try std.testing.expect(!i32_type.isAssignable(i64_type, true));
    try std.testing.expect(i32_type.isAssignable(i32_type, true));
}

// ============================================================================
// Coercion Tests
// ============================================================================

test "canCoerceTo - subtype allows coercion" {
    const i32_type: Type = .I32;
    const i64_type: Type = .I64;
    const never_type: Type = .Never;
    const int_type: Type = .Int;

    try std.testing.expect(i32_type.canCoerceTo(i64_type));
    try std.testing.expect(never_type.canCoerceTo(int_type));
}

test "canCoerceTo - integer literal to any integer" {
    const int_lit: Type = .{ .Literal = .{ .integer = 42 } };
    const int_type: Type = .Int;
    const i32_type: Type = .I32;
    const u64_type: Type = .U64;
    const string_type: Type = .String;

    try std.testing.expect(int_lit.canCoerceTo(int_type));
    try std.testing.expect(int_lit.canCoerceTo(i32_type));
    try std.testing.expect(int_lit.canCoerceTo(u64_type));
    try std.testing.expect(!int_lit.canCoerceTo(string_type));
}

test "canCoerceTo - float literal to any float" {
    const float_lit: Type = .{ .Literal = .{ .float = 3.14 } };
    const float_type: Type = .Float;
    const f32_type: Type = .F32;
    const f64_type: Type = .F64;
    const int_type: Type = .Int;

    try std.testing.expect(float_lit.canCoerceTo(float_type));
    try std.testing.expect(float_lit.canCoerceTo(f32_type));
    try std.testing.expect(float_lit.canCoerceTo(f64_type));
    try std.testing.expect(!float_lit.canCoerceTo(int_type));
}

test "canCoerceTo - string literal to string" {
    const str_lit: Type = .{ .Literal = .{ .string = "hello" } };
    const string_type: Type = .String;
    const int_type: Type = .Int;

    try std.testing.expect(str_lit.canCoerceTo(string_type));
    try std.testing.expect(!str_lit.canCoerceTo(int_type));
}

test "canCoerceTo - boolean literal to bool" {
    const bool_lit: Type = .{ .Literal = .{ .boolean = true } };
    const bool_type: Type = .Bool;
    const string_type: Type = .String;

    try std.testing.expect(bool_lit.canCoerceTo(bool_type));
    try std.testing.expect(!bool_lit.canCoerceTo(string_type));
}
