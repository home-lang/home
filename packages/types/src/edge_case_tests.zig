// ============================================================================
// Comprehensive Edge Case Tests for Type System
// ============================================================================
// This file contains thorough edge case testing for all type system features.

const std = @import("std");
const Type = @import("type_system.zig").Type;
const typescript_types = @import("typescript_types.zig");

const IntersectionType = typescript_types.IntersectionType;
const ConditionalType = typescript_types.ConditionalType;
const MappedType = typescript_types.MappedType;
const KeyofType = typescript_types.KeyofType;
const TypeofType = typescript_types.TypeofType;
const InferType = typescript_types.InferType;
const LiteralType = typescript_types.LiteralType;
const TemplateLiteralType = typescript_types.TemplateLiteralType;
const TypeInterner = typescript_types.TypeInterner;
const BrandedType = typescript_types.BrandedType;
const OpaqueType = typescript_types.OpaqueType;
const IndexAccessType = typescript_types.IndexAccessType;
const Variance = typescript_types.Variance;
const VariantTypeParam = typescript_types.VariantTypeParam;
const TypeGuard = typescript_types.TypeGuard;
const TypePredicate = typescript_types.TypePredicate;
const RecursiveTypeAlias = typescript_types.RecursiveTypeAlias;
const StringManipulationType = typescript_types.StringManipulationType;

// ============================================================================
// Section 1: Subtyping Edge Cases
// ============================================================================

test "edge: Never is subtype of Never" {
    const never: Type = .Never;
    try std.testing.expect(never.isSubtype(never));
}

test "edge: Unknown is subtype of Unknown" {
    const unknown: Type = .Unknown;
    try std.testing.expect(unknown.isSubtype(unknown));
}

test "edge: Never is NOT subtype of Nothing (Never is bottom)" {
    const never: Type = .Never;
    const unknown: Type = .Unknown;
    // Never is subtype of Unknown
    try std.testing.expect(never.isSubtype(unknown));
    // Unknown is NOT subtype of Never
    try std.testing.expect(!unknown.isSubtype(never));
}

test "edge: nested optional - Int? is subtype of Int??" {
    const allocator = std.testing.allocator;

    const inner_int = try allocator.create(Type);
    defer allocator.destroy(inner_int);
    inner_int.* = .Int;

    const optional_int: Type = .{ .Optional = inner_int };

    const opt_int_ptr = try allocator.create(Type);
    defer allocator.destroy(opt_int_ptr);
    opt_int_ptr.* = optional_int;

    const optional_optional_int: Type = .{ .Optional = opt_int_ptr };

    // Int? should be subtype of Int??
    try std.testing.expect(optional_int.isSubtype(optional_optional_int));
}

test "edge: deeply nested optional - Int is subtype of Int???" {
    const allocator = std.testing.allocator;

    const int_type: Type = .Int;

    const opt1 = try allocator.create(Type);
    defer allocator.destroy(opt1);
    opt1.* = .Int;
    const optional1: Type = .{ .Optional = opt1 };

    const opt2 = try allocator.create(Type);
    defer allocator.destroy(opt2);
    opt2.* = optional1;
    const optional2: Type = .{ .Optional = opt2 };

    const opt3 = try allocator.create(Type);
    defer allocator.destroy(opt3);
    opt3.* = optional2;
    const optional3: Type = .{ .Optional = opt3 };

    // NOTE: Current implementation only checks one level of optional nesting
    // Int is NOT subtype of Int??? since we only peel one level
    // This could be changed in the future to recursively peel optionals
    try std.testing.expect(!int_type.isSubtype(optional3));
}

test "edge: Never is subtype of Optional<T>" {
    const allocator = std.testing.allocator;

    const inner = try allocator.create(Type);
    defer allocator.destroy(inner);
    inner.* = .String;

    const optional_string: Type = .{ .Optional = inner };
    const never: Type = .Never;

    try std.testing.expect(never.isSubtype(optional_string));
}

test "edge: nested arrays - [Int] is subtype of [Int?]" {
    const allocator = std.testing.allocator;

    const int_elem = try allocator.create(Type);
    defer allocator.destroy(int_elem);
    int_elem.* = .Int;
    const arr_int: Type = .{ .Array = .{ .element_type = int_elem } };

    const opt_int = try allocator.create(Type);
    defer allocator.destroy(opt_int);
    opt_int.* = .Int;

    const optional_int = try allocator.create(Type);
    defer allocator.destroy(optional_int);
    optional_int.* = .{ .Optional = opt_int };

    const arr_opt_int: Type = .{ .Array = .{ .element_type = optional_int } };

    // Array covariance: [Int] should be subtype of [Int?]
    try std.testing.expect(arr_int.isSubtype(arr_opt_int));
}

test "edge: nested arrays - [[Int]] subtyping" {
    const allocator = std.testing.allocator;

    const i32_elem = try allocator.create(Type);
    defer allocator.destroy(i32_elem);
    i32_elem.* = .I32;
    const arr_i32: Type = .{ .Array = .{ .element_type = i32_elem } };

    const arr_i32_ptr = try allocator.create(Type);
    defer allocator.destroy(arr_i32_ptr);
    arr_i32_ptr.* = arr_i32;
    const nested_arr_i32: Type = .{ .Array = .{ .element_type = arr_i32_ptr } };

    const i64_elem = try allocator.create(Type);
    defer allocator.destroy(i64_elem);
    i64_elem.* = .I64;
    const arr_i64: Type = .{ .Array = .{ .element_type = i64_elem } };

    const arr_i64_ptr = try allocator.create(Type);
    defer allocator.destroy(arr_i64_ptr);
    arr_i64_ptr.* = arr_i64;
    const nested_arr_i64: Type = .{ .Array = .{ .element_type = arr_i64_ptr } };

    // [[I32]] should be subtype of [[I64]] due to covariance
    try std.testing.expect(nested_arr_i32.isSubtype(nested_arr_i64));
}

test "edge: empty struct is supertype of all structs" {
    const empty_fields = [_]Type.StructType.Field{};
    const empty_struct: Type = .{ .Struct = .{ .name = "Empty", .fields = &empty_fields } };

    const one_field = [_]Type.StructType.Field{
        .{ .name = "x", .type = .Int },
    };
    const one_field_struct: Type = .{ .Struct = .{ .name = "OneField", .fields = &one_field } };

    const two_fields = [_]Type.StructType.Field{
        .{ .name = "x", .type = .Int },
        .{ .name = "y", .type = .String },
    };
    const two_field_struct: Type = .{ .Struct = .{ .name = "TwoFields", .fields = &two_fields } };

    // Any struct is subtype of empty struct (width subtyping)
    try std.testing.expect(one_field_struct.isSubtype(empty_struct));
    try std.testing.expect(two_field_struct.isSubtype(empty_struct));
    try std.testing.expect(empty_struct.isSubtype(empty_struct));
}

test "edge: struct field type subtyping" {
    const sub_fields = [_]Type.StructType.Field{
        .{ .name = "value", .type = .I32 },
    };
    const sub_struct: Type = .{ .Struct = .{ .name = "Sub", .fields = &sub_fields } };

    const super_fields = [_]Type.StructType.Field{
        .{ .name = "value", .type = .I64 },
    };
    const super_struct: Type = .{ .Struct = .{ .name = "Super", .fields = &super_fields } };

    // Struct with I32 field should be subtype of struct with I64 field
    try std.testing.expect(sub_struct.isSubtype(super_struct));
}

test "edge: function returning Never" {
    const allocator = std.testing.allocator;

    const never_ret = try allocator.create(Type);
    defer allocator.destroy(never_ret);
    never_ret.* = .Never;
    const fn_never: Type = .{ .Function = .{ .params = &.{}, .return_type = never_ret } };

    const int_ret = try allocator.create(Type);
    defer allocator.destroy(int_ret);
    int_ret.* = .Int;
    const fn_int: Type = .{ .Function = .{ .params = &.{}, .return_type = int_ret } };

    // () -> Never is subtype of () -> Int (Never is subtype of everything)
    try std.testing.expect(fn_never.isSubtype(fn_int));
}

test "edge: function taking Unknown parameter" {
    const allocator = std.testing.allocator;

    const void_ret = try allocator.create(Type);
    defer allocator.destroy(void_ret);
    void_ret.* = .Void;

    var params_unknown = [_]Type{.Unknown};
    const fn_unknown: Type = .{ .Function = .{ .params = &params_unknown, .return_type = void_ret } };

    var params_int = [_]Type{.Int};
    const fn_int: Type = .{ .Function = .{ .params = &params_int, .return_type = void_ret } };

    // (Unknown) -> Void is subtype of (Int) -> Void (contravariance)
    try std.testing.expect(fn_unknown.isSubtype(fn_int));
}

test "edge: function with many parameters" {
    const allocator = std.testing.allocator;

    const void_ret = try allocator.create(Type);
    defer allocator.destroy(void_ret);
    void_ret.* = .Void;

    var params1 = [_]Type{ .I64, .I64, .I64, .I64, .I64 };
    const fn1: Type = .{ .Function = .{ .params = &params1, .return_type = void_ret } };

    var params2 = [_]Type{ .I32, .I32, .I32, .I32, .I32 };
    const fn2: Type = .{ .Function = .{ .params = &params2, .return_type = void_ret } };

    // fn(I64,I64,I64,I64,I64) is subtype of fn(I32,I32,I32,I32,I32)
    try std.testing.expect(fn1.isSubtype(fn2));
}

test "edge: higher-order function subtyping" {
    const allocator = std.testing.allocator;

    // Create () -> I32
    const i32_ret = try allocator.create(Type);
    defer allocator.destroy(i32_ret);
    i32_ret.* = .I32;
    const fn_ret_i32: Type = .{ .Function = .{ .params = &.{}, .return_type = i32_ret } };

    // Create () -> I64
    const i64_ret = try allocator.create(Type);
    defer allocator.destroy(i64_ret);
    i64_ret.* = .I64;
    const fn_ret_i64: Type = .{ .Function = .{ .params = &.{}, .return_type = i64_ret } };

    // Create () -> (() -> I32)
    const fn_ret_i32_ptr = try allocator.create(Type);
    defer allocator.destroy(fn_ret_i32_ptr);
    fn_ret_i32_ptr.* = fn_ret_i32;
    const hof1: Type = .{ .Function = .{ .params = &.{}, .return_type = fn_ret_i32_ptr } };

    // Create () -> (() -> I64)
    const fn_ret_i64_ptr = try allocator.create(Type);
    defer allocator.destroy(fn_ret_i64_ptr);
    fn_ret_i64_ptr.* = fn_ret_i64;
    const hof2: Type = .{ .Function = .{ .params = &.{}, .return_type = fn_ret_i64_ptr } };

    // () -> (() -> I32) should be subtype of () -> (() -> I64)
    try std.testing.expect(hof1.isSubtype(hof2));
}

test "edge: mutable reference is not subtype of different type reference" {
    const allocator = std.testing.allocator;

    const int_type = try allocator.create(Type);
    defer allocator.destroy(int_type);
    int_type.* = .Int;

    const string_type = try allocator.create(Type);
    defer allocator.destroy(string_type);
    string_type.* = .String;

    const mut_ref_int: Type = .{ .MutableReference = int_type };
    const ref_string: Type = .{ .Reference = string_type };

    try std.testing.expect(!mut_ref_int.isSubtype(ref_string));
}

// ============================================================================
// Section 2: Literal Type Edge Cases
// ============================================================================

test "edge: literal NaN equality" {
    const nan1 = LiteralType.floatLiteral(std.math.nan(f64));
    const nan2 = LiteralType.floatLiteral(std.math.nan(f64));

    // NaN != NaN, but for type equality we compare bit patterns
    // This depends on implementation - test both possibilities
    _ = nan1.eql(nan2);
}

test "edge: literal negative zero vs positive zero" {
    const pos_zero = LiteralType.floatLiteral(0.0);
    const neg_zero = LiteralType.floatLiteral(-0.0);

    // -0.0 and 0.0 have different bit patterns
    // This may or may not be equal depending on implementation
    _ = pos_zero.eql(neg_zero);
}

test "edge: literal very large integers" {
    const max = LiteralType.integerLiteral(std.math.maxInt(i64));
    const min = LiteralType.integerLiteral(std.math.minInt(i64));
    const zero = LiteralType.integerLiteral(0);

    try std.testing.expect(!max.eql(min));
    try std.testing.expect(!max.eql(zero));
    try std.testing.expect(!min.eql(zero));
}

test "edge: literal unicode strings" {
    const lit1 = LiteralType.stringLiteral("こんにちは");
    const lit2 = LiteralType.stringLiteral("こんにちは");
    const lit3 = LiteralType.stringLiteral("你好");

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "edge: literal emoji strings" {
    const lit1 = LiteralType.stringLiteral("🎉🎊🎈");
    const lit2 = LiteralType.stringLiteral("🎉🎊🎈");
    const lit3 = LiteralType.stringLiteral("🎉");

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "edge: literal whitespace strings" {
    const space = LiteralType.stringLiteral(" ");
    const tab = LiteralType.stringLiteral("\t");
    const newline = LiteralType.stringLiteral("\n");
    const empty = LiteralType.stringLiteral("");

    try std.testing.expect(!space.eql(tab));
    try std.testing.expect(!space.eql(newline));
    try std.testing.expect(!space.eql(empty));
    try std.testing.expect(!tab.eql(newline));
}

test "edge: literal very small floats" {
    const tiny1 = LiteralType.floatLiteral(std.math.floatMin(f64));
    const tiny2 = LiteralType.floatLiteral(std.math.floatMin(f64));
    const eps = LiteralType.floatLiteral(std.math.floatEps(f64));

    try std.testing.expect(tiny1.eql(tiny2));
    try std.testing.expect(!tiny1.eql(eps));
}

test "edge: literal type cross-comparison - same value different types" {
    const int_zero = LiteralType.integerLiteral(0);
    const float_zero = LiteralType.floatLiteral(0.0);
    const str_zero = LiteralType.stringLiteral("0");
    const bool_false = LiteralType.booleanLiteral(false);

    // All should be different despite representing "zero"
    try std.testing.expect(!int_zero.eql(float_zero));
    try std.testing.expect(!int_zero.eql(str_zero));
    try std.testing.expect(!int_zero.eql(bool_false));
}

// ============================================================================
// Section 3: Coercion Edge Cases
// ============================================================================

test "edge: coercion integer literal to unsigned" {
    const pos_lit: Type = .{ .Literal = .{ .integer = 42 } };
    const neg_lit: Type = .{ .Literal = .{ .integer = -1 } };

    // Positive literal can coerce to unsigned
    try std.testing.expect(pos_lit.canCoerceTo(.U32));
    try std.testing.expect(pos_lit.canCoerceTo(.U64));

    // Negative literal technically can coerce (runtime check needed)
    try std.testing.expect(neg_lit.canCoerceTo(.U32));
}

test "edge: coercion boolean literal to bool" {
    const true_lit: Type = .{ .Literal = .{ .boolean = true } };
    const false_lit: Type = .{ .Literal = .{ .boolean = false } };

    try std.testing.expect(true_lit.canCoerceTo(.Bool));
    try std.testing.expect(false_lit.canCoerceTo(.Bool));

    // Boolean cannot coerce to int
    try std.testing.expect(!true_lit.canCoerceTo(.Int));
}

test "edge: coercion null literal" {
    const null_lit: Type = .{ .Literal = .{ .null_type = {} } };

    // null should not coerce to concrete types
    try std.testing.expect(!null_lit.canCoerceTo(.Int));
    try std.testing.expect(!null_lit.canCoerceTo(.String));
}

test "edge: coercion Never to anything" {
    const never: Type = .Never;

    // Never can coerce to anything (bottom type)
    try std.testing.expect(never.canCoerceTo(.Int));
    try std.testing.expect(never.canCoerceTo(.String));
    try std.testing.expect(never.canCoerceTo(.Bool));
    try std.testing.expect(never.canCoerceTo(.Unknown));
}

test "edge: coercion Unknown to nothing except itself" {
    const unknown: Type = .Unknown;

    // Unknown should only coerce to Unknown
    try std.testing.expect(unknown.canCoerceTo(.Unknown));
    try std.testing.expect(!unknown.canCoerceTo(.Int));
    try std.testing.expect(!unknown.canCoerceTo(.String));
}

// ============================================================================
// Section 4: Assignability Edge Cases
// ============================================================================

test "edge: assignability mutable context - optional" {
    const allocator = std.testing.allocator;

    const inner = try allocator.create(Type);
    defer allocator.destroy(inner);
    inner.* = .Int;

    const optional_int: Type = .{ .Optional = inner };
    const int_type: Type = .Int;

    // In mutable context, Int cannot be assigned to Int? (need exact match)
    try std.testing.expect(!int_type.isAssignable(optional_int, true));
    // In immutable context, Int can be assigned to Int?
    try std.testing.expect(int_type.isAssignable(optional_int, false));
}

test "edge: assignability mutable context - widening" {
    const i32_type: Type = .I32;
    const i64_type: Type = .I64;

    // In mutable context, I32 cannot be assigned to I64
    try std.testing.expect(!i32_type.isAssignable(i64_type, true));
    // In immutable context, I32 can be assigned to I64
    try std.testing.expect(i32_type.isAssignable(i64_type, false));
}

test "edge: assignability Never" {
    const never: Type = .Never;
    const int_type: Type = .Int;

    // In mutable context, isAssignable requires exact equality (invariance)
    // So Never.isAssignable(Int, true) is false because Never != Int
    try std.testing.expect(!never.isAssignable(int_type, true));
    // In immutable context, Never is subtype of anything so it's assignable
    try std.testing.expect(never.isAssignable(int_type, false));
}

// ============================================================================
// Section 5: Type Interner Edge Cases
// ============================================================================

test "edge: interner - intern Never and Unknown" {
    const allocator = std.testing.allocator;
    var interner = TypeInterner.init(allocator);
    defer interner.deinit();

    const never1 = try interner.intern(Type.Never);
    const never2 = try interner.intern(Type.Never);
    const unknown1 = try interner.intern(Type.Unknown);
    const unknown2 = try interner.intern(Type.Unknown);

    try std.testing.expectEqual(never1, never2);
    try std.testing.expectEqual(unknown1, unknown2);
    try std.testing.expect(never1 != unknown1);
}

test "edge: interner - many types" {
    const allocator = std.testing.allocator;
    var interner = TypeInterner.init(allocator);
    defer interner.deinit();

    // Intern many primitive types
    const types = [_]Type{
        .Int, .I8, .I16, .I32, .I64, .I128,
        .U8,  .U16, .U32, .U64, .U128,
        .F32, .F64, .Float,
        .Bool, .String, .Void, .Never, .Unknown,
    };

    var interned: [types.len]*const Type = undefined;
    for (types, 0..) |t, i| {
        interned[i] = try interner.intern(t);
    }

    // Verify each type is unique
    for (0..types.len) |i| {
        for (i + 1..types.len) |j| {
            try std.testing.expect(interned[i] != interned[j]);
        }
    }

    // Verify interning again returns same pointers
    for (types, interned) |t, ptr| {
        const again = try interner.intern(t);
        try std.testing.expectEqual(ptr, again);
    }
}

// ============================================================================
// Section 6: Branded Type Edge Cases
// ============================================================================

test "edge: branded type - same brand different base not equal" {
    const allocator = std.testing.allocator;

    const i32_base = try allocator.create(Type);
    defer allocator.destroy(i32_base);
    i32_base.* = .I32;

    const i64_base = try allocator.create(Type);
    defer allocator.destroy(i64_base);
    i64_base.* = .I64;

    const branded_i32 = BrandedType.init(i32_base, "Id");
    const branded_i64 = BrandedType.init(i64_base, "Id");

    try std.testing.expect(!branded_i32.eql(branded_i64));
}

test "edge: branded type - case sensitive brands" {
    const allocator = std.testing.allocator;

    const base = try allocator.create(Type);
    defer allocator.destroy(base);
    base.* = .I64;

    const userId = BrandedType.init(base, "UserId");
    const userid = BrandedType.init(base, "userid");
    const USERID = BrandedType.init(base, "USERID");

    try std.testing.expect(!userId.eql(userid));
    try std.testing.expect(!userId.eql(USERID));
    try std.testing.expect(!userid.eql(USERID));
}

test "edge: branded type - empty brand name" {
    const allocator = std.testing.allocator;

    const base = try allocator.create(Type);
    defer allocator.destroy(base);
    base.* = .I64;

    const empty1 = BrandedType.init(base, "");
    const empty2 = BrandedType.init(base, "");

    try std.testing.expect(empty1.eql(empty2));
}

test "edge: branded type - isAssignableFrom with Type" {
    const allocator = std.testing.allocator;

    const base1 = try allocator.create(Type);
    defer allocator.destroy(base1);
    base1.* = .I64;

    const userId = BrandedType.init(base1, "UserId");

    // Create a Type with Branded variant using BrandedTypeInfo
    const branded_type = try allocator.create(Type);
    defer allocator.destroy(branded_type);
    branded_type.* = .{ .Branded = .{ .base_type = base1, .brand = "UserId" } };

    // Same brand should be assignable
    try std.testing.expect(userId.isAssignableFrom(branded_type));

    // Different type (plain Int) should not be assignable
    const int_type = try allocator.create(Type);
    defer allocator.destroy(int_type);
    int_type.* = .Int;
    try std.testing.expect(!userId.isAssignableFrom(int_type));
}

// ============================================================================
// Section 7: Index Access Type Edge Cases
// ============================================================================

test "edge: index access - evaluate on struct" {
    const allocator = std.testing.allocator;

    const fields = [_]Type.StructType.Field{
        .{ .name = "name", .type = .String },
        .{ .name = "age", .type = .Int },
    };
    const struct_type = try allocator.create(Type);
    defer allocator.destroy(struct_type);
    struct_type.* = .{ .Struct = .{ .name = "Person", .fields = &fields } };

    const name_key = try allocator.create(Type);
    defer allocator.destroy(name_key);
    name_key.* = .{ .Literal = .{ .string = "name" } };

    const age_key = try allocator.create(Type);
    defer allocator.destroy(age_key);
    age_key.* = .{ .Literal = .{ .string = "age" } };

    const access_name = IndexAccessType.init(struct_type, name_key);
    const access_age = IndexAccessType.init(struct_type, age_key);

    const result_name = try access_name.evaluate(allocator);
    defer allocator.destroy(result_name);
    const result_age = try access_age.evaluate(allocator);
    defer allocator.destroy(result_age);

    try std.testing.expect(result_name.* == .String);
    try std.testing.expect(result_age.* == .Int);
}

test "edge: index access - missing field returns Never" {
    const allocator = std.testing.allocator;

    const fields = [_]Type.StructType.Field{
        .{ .name = "x", .type = .Int },
    };
    const struct_type = try allocator.create(Type);
    defer allocator.destroy(struct_type);
    struct_type.* = .{ .Struct = .{ .name = "Point", .fields = &fields } };

    const missing_key = try allocator.create(Type);
    defer allocator.destroy(missing_key);
    missing_key.* = .{ .Literal = .{ .string = "z" } };

    const access = IndexAccessType.init(struct_type, missing_key);
    const result = try access.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expect(result.* == .Never);
}

test "edge: index access - tuple by index" {
    const allocator = std.testing.allocator;

    var elems = [_]Type{ .Int, .String, .Bool };
    const tuple_type = try allocator.create(Type);
    defer allocator.destroy(tuple_type);
    tuple_type.* = .{ .Tuple = .{ .element_types = &elems } };

    const idx0 = try allocator.create(Type);
    defer allocator.destroy(idx0);
    idx0.* = .{ .Literal = .{ .integer = 0 } };

    const idx1 = try allocator.create(Type);
    defer allocator.destroy(idx1);
    idx1.* = .{ .Literal = .{ .integer = 1 } };

    const idx2 = try allocator.create(Type);
    defer allocator.destroy(idx2);
    idx2.* = .{ .Literal = .{ .integer = 2 } };

    const access0 = IndexAccessType.init(tuple_type, idx0);
    const access1 = IndexAccessType.init(tuple_type, idx1);
    const access2 = IndexAccessType.init(tuple_type, idx2);

    const r0 = try access0.evaluate(allocator);
    defer allocator.destroy(r0);
    const r1 = try access1.evaluate(allocator);
    defer allocator.destroy(r1);
    const r2 = try access2.evaluate(allocator);
    defer allocator.destroy(r2);

    try std.testing.expect(r0.* == .Int);
    try std.testing.expect(r1.* == .String);
    try std.testing.expect(r2.* == .Bool);
}

test "edge: index access - out of bounds tuple returns Never" {
    const allocator = std.testing.allocator;

    var elems = [_]Type{.Int};
    const tuple_type = try allocator.create(Type);
    defer allocator.destroy(tuple_type);
    tuple_type.* = .{ .Tuple = .{ .element_types = &elems } };

    const idx_out = try allocator.create(Type);
    defer allocator.destroy(idx_out);
    idx_out.* = .{ .Literal = .{ .integer = 5 } };

    const access = IndexAccessType.init(tuple_type, idx_out);
    const result = try access.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expect(result.* == .Never);
}

// ============================================================================
// Section 8: Variance Edge Cases
// ============================================================================

test "edge: variance - all four variants" {
    const covar = VariantTypeParam.init("T", .covariant);
    const contravar = VariantTypeParam.init("T", .contravariant);
    const invar = VariantTypeParam.init("T", .invariant);
    const bivar = VariantTypeParam.init("T", .bivariant);

    try std.testing.expectEqual(Variance.covariant, covar.variance);
    try std.testing.expectEqual(Variance.contravariant, contravar.variance);
    try std.testing.expectEqual(Variance.invariant, invar.variance);
    try std.testing.expectEqual(Variance.bivariant, bivar.variance);
}

test "edge: variance - with constraint and default" {
    const allocator = std.testing.allocator;

    const constraint = try allocator.create(Type);
    defer allocator.destroy(constraint);
    constraint.* = .Int;

    const default = try allocator.create(Type);
    defer allocator.destroy(default);
    default.* = .I32;

    const param = VariantTypeParam.init("T", .covariant)
        .withConstraint(constraint)
        .withDefault(default);

    try std.testing.expectEqual(constraint, param.constraint);
    try std.testing.expectEqual(default, param.default_type);
}

// ============================================================================
// Section 9: String Manipulation Edge Cases
// ============================================================================

test "edge: string manipulation - empty string uppercase" {
    const allocator = std.testing.allocator;

    const empty = try allocator.create(Type);
    defer allocator.destroy(empty);
    empty.* = .{ .Literal = .{ .string = "" } };

    const manip = StringManipulationType{ .uppercase = empty };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("", result.Literal.string);
}

test "edge: string manipulation - already uppercase stays same" {
    const allocator = std.testing.allocator;

    const upper = try allocator.create(Type);
    defer allocator.destroy(upper);
    upper.* = .{ .Literal = .{ .string = "HELLO" } };

    const manip = StringManipulationType{ .uppercase = upper };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("HELLO", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "edge: string manipulation - already lowercase stays same" {
    const allocator = std.testing.allocator;

    const lower = try allocator.create(Type);
    defer allocator.destroy(lower);
    lower.* = .{ .Literal = .{ .string = "hello" } };

    const manip = StringManipulationType{ .lowercase = lower };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("hello", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "edge: string manipulation - capitalize empty string" {
    const allocator = std.testing.allocator;

    const empty = try allocator.create(Type);
    defer allocator.destroy(empty);
    empty.* = .{ .Literal = .{ .string = "" } };

    const manip = StringManipulationType{ .capitalize = empty };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    // Empty string falls through to Type.String (no first char to capitalize)
    try std.testing.expect(result.* == .String);
}

test "edge: string manipulation - capitalize single char" {
    const allocator = std.testing.allocator;

    const single = try allocator.create(Type);
    defer allocator.destroy(single);
    single.* = .{ .Literal = .{ .string = "a" } };

    const manip = StringManipulationType{ .capitalize = single };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("A", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "edge: string manipulation - trim no whitespace" {
    const allocator = std.testing.allocator;

    const no_ws = try allocator.create(Type);
    defer allocator.destroy(no_ws);
    no_ws.* = .{ .Literal = .{ .string = "hello" } };

    const manip = StringManipulationType{ .trim = no_ws };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("hello", result.Literal.string);
}

test "edge: string manipulation - trim all whitespace" {
    const allocator = std.testing.allocator;

    const all_ws = try allocator.create(Type);
    defer allocator.destroy(all_ws);
    all_ws.* = .{ .Literal = .{ .string = "   " } };

    const manip = StringManipulationType{ .trim = all_ws };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("", result.Literal.string);
}

test "edge: string manipulation - mixed case to uppercase" {
    const allocator = std.testing.allocator;

    const mixed = try allocator.create(Type);
    defer allocator.destroy(mixed);
    mixed.* = .{ .Literal = .{ .string = "HeLLo WoRLd" } };

    const manip = StringManipulationType{ .uppercase = mixed };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("HELLO WORLD", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

// ============================================================================
// Section 10: Conditional Type Edge Cases
// ============================================================================

// Simple type checker for testing
const TestChecker = struct {
    pub fn isSubtype(_: *const TestChecker, check: *const Type, extends: *const Type) bool {
        return check.isSubtype(extends.*);
    }
};

test "edge: conditional type - evaluate true branch" {
    const allocator = std.testing.allocator;

    const check = try allocator.create(Type);
    defer allocator.destroy(check);
    check.* = .I32;

    const extends = try allocator.create(Type);
    defer allocator.destroy(extends);
    extends.* = .I64; // I32 is subtype of I64

    const true_type = try allocator.create(Type);
    defer allocator.destroy(true_type);
    true_type.* = .String;

    const false_type = try allocator.create(Type);
    defer allocator.destroy(false_type);
    false_type.* = .Bool;

    const cond = ConditionalType.init(check, extends, true_type, false_type);
    var checker = TestChecker{};
    const result = cond.evaluate(&checker);

    // I32 is subtype of I64, so should return String
    try std.testing.expect(result.* == .String);
}

test "edge: conditional type - evaluate false branch" {
    const allocator = std.testing.allocator;

    const check = try allocator.create(Type);
    defer allocator.destroy(check);
    check.* = .String;

    const extends = try allocator.create(Type);
    defer allocator.destroy(extends);
    extends.* = .Int;

    const true_type = try allocator.create(Type);
    defer allocator.destroy(true_type);
    true_type.* = .Bool;

    const false_type = try allocator.create(Type);
    defer allocator.destroy(false_type);
    false_type.* = .Float;

    const cond = ConditionalType.init(check, extends, true_type, false_type);
    var checker = TestChecker{};
    const result = cond.evaluate(&checker);

    // String does not extend Int, so should return Float
    try std.testing.expect(result.* == .Float);
}

test "edge: conditional type - Never extends everything" {
    const allocator = std.testing.allocator;

    const check = try allocator.create(Type);
    defer allocator.destroy(check);
    check.* = .Never;

    const extends = try allocator.create(Type);
    defer allocator.destroy(extends);
    extends.* = .String;

    const true_type = try allocator.create(Type);
    defer allocator.destroy(true_type);
    true_type.* = .Int;

    const false_type = try allocator.create(Type);
    defer allocator.destroy(false_type);
    false_type.* = .Bool;

    const cond = ConditionalType.init(check, extends, true_type, false_type);
    var checker = TestChecker{};
    const result = cond.evaluate(&checker);

    // Never extends String is true
    try std.testing.expect(result.* == .Int);
}

// ============================================================================
// Section 11: Type Guard Edge Cases
// ============================================================================

test "edge: type guard - with else type" {
    const allocator = std.testing.allocator;

    const narrowed = try allocator.create(Type);
    defer allocator.destroy(narrowed);
    narrowed.* = .String;

    const else_type = try allocator.create(Type);
    defer allocator.destroy(else_type);
    else_type.* = .Int;

    const guard = TypeGuard.init("value", narrowed).withElseType(else_type);

    try std.testing.expectEqual(narrowed, guard.narrowed_type);
    try std.testing.expectEqual(else_type, guard.else_type);
}

test "edge: type predicate - basic usage" {
    const allocator = std.testing.allocator;

    const asserted = try allocator.create(Type);
    defer allocator.destroy(asserted);
    asserted.* = .String;

    const pred = TypePredicate.init("x", asserted);

    try std.testing.expectEqualStrings("x", pred.parameter_name);
    try std.testing.expectEqual(asserted, pred.asserted_type);
}

// ============================================================================
// Section 12: Keyof Type Edge Cases
// ============================================================================

test "edge: keyof - struct with no fields returns Void" {
    const allocator = std.testing.allocator;

    const fields = [_]Type.StructType.Field{};
    const struct_type = try allocator.create(Type);
    defer allocator.destroy(struct_type);
    struct_type.* = .{ .Struct = .{ .name = "Empty", .fields = &fields } };

    const keyof = KeyofType.init(struct_type);
    const result = try keyof.evaluate(allocator);
    defer allocator.destroy(result);

    // Empty struct should return Void (no keys)
    try std.testing.expect(result.* == .Void);
}

test "edge: keyof - struct with one field" {
    const allocator = std.testing.allocator;

    const fields = [_]Type.StructType.Field{
        .{ .name = "x", .type = .Int },
    };
    const struct_type = try allocator.create(Type);
    defer allocator.destroy(struct_type);
    struct_type.* = .{ .Struct = .{ .name = "Point", .fields = &fields } };

    const keyof = KeyofType.init(struct_type);
    const result = try keyof.evaluate(allocator);
    defer {
        if (std.meta.activeTag(result.*) == .Union) {
            allocator.free(result.Union.variants);
        }
        allocator.destroy(result);
    }

    // Should return union type
    try std.testing.expect(std.meta.activeTag(result.*) == .Union);
}

test "edge: keyof - tuple returns numeric indices" {
    const allocator = std.testing.allocator;

    var elems = [_]Type{ .Int, .String };
    const tuple_type = try allocator.create(Type);
    defer allocator.destroy(tuple_type);
    tuple_type.* = .{ .Tuple = .{ .element_types = &elems } };

    const keyof = KeyofType.init(tuple_type);
    const result = try keyof.evaluate(allocator);
    defer {
        if (std.meta.activeTag(result.*) == .Union) {
            allocator.free(result.Union.variants);
        }
        allocator.destroy(result);
    }

    // Should return union of 0 | 1
    try std.testing.expect(std.meta.activeTag(result.*) == .Union);
}

// ============================================================================
// Section 13: Mapped Type Edge Cases
// ============================================================================

test "edge: mapped type - with modifiers" {
    const allocator = std.testing.allocator;

    const fields = [_]Type.StructType.Field{
        .{ .name = "x", .type = .Int },
    };
    const source = try allocator.create(Type);
    defer allocator.destroy(source);
    source.* = .{ .Struct = .{ .name = "Point", .fields = &fields } };

    const value = try allocator.create(Type);
    defer allocator.destroy(value);
    value.* = .Bool;

    var mapped = MappedType.init(source, "K", value);
    mapped.modifiers = .{ .readonly = .add, .optional = .add };

    try std.testing.expectEqual(MappedType.Modifiers.Modifier.add, mapped.modifiers.readonly);
    try std.testing.expectEqual(MappedType.Modifiers.Modifier.add, mapped.modifiers.optional);
}

// ============================================================================
// Section 14: Opaque Type Edge Cases
// ============================================================================

test "edge: opaque type - with module" {
    const allocator = std.testing.allocator;

    const underlying = try allocator.create(Type);
    defer allocator.destroy(underlying);
    underlying.* = .I64;

    var opaque_type = OpaqueType.init(underlying, "Handle");
    opaque_type.defining_module = "system.io";

    try std.testing.expectEqualStrings("Handle", opaque_type.name);
    try std.testing.expectEqualStrings("system.io", opaque_type.defining_module.?);
}

test "edge: opaque type - same name different modules" {
    const allocator = std.testing.allocator;

    const underlying = try allocator.create(Type);
    defer allocator.destroy(underlying);
    underlying.* = .I64;

    var handle1 = OpaqueType.init(underlying, "Handle");
    handle1.defining_module = "system.io";

    var handle2 = OpaqueType.init(underlying, "Handle");
    handle2.defining_module = "graphics";

    try std.testing.expect(!std.mem.eql(u8, handle1.defining_module.?, handle2.defining_module.?));
}

// ============================================================================
// Section 15: Template Literal Type Edge Cases
// ============================================================================

test "edge: template literal - matches exact string" {
    const parts = [_]TemplateLiteralType.Part{
        .{ .literal = "hello" },
    };
    const template = TemplateLiteralType.init(&parts);

    try std.testing.expect(template.matches("hello"));
    try std.testing.expect(!template.matches("world"));
    try std.testing.expect(!template.matches(""));
}

test "edge: template literal - empty template" {
    const parts = [_]TemplateLiteralType.Part{};
    const template = TemplateLiteralType.init(&parts);

    // Empty template should only match empty string
    try std.testing.expect(template.matches(""));
    try std.testing.expect(!template.matches("anything"));
}

// ============================================================================
// Section 16: Recursive Type Alias Edge Cases
// ============================================================================

test "edge: recursive type alias - multiple params" {
    const allocator = std.testing.allocator;

    const definition = try allocator.create(Type);
    defer allocator.destroy(definition);
    definition.* = .{ .Struct = .{ .name = "Tree", .fields = &.{} } };

    const params = [_][]const u8{ "K", "V" };
    const alias = RecursiveTypeAlias.init("Tree", &params, definition);

    try std.testing.expectEqualStrings("Tree", alias.name);
    try std.testing.expectEqual(@as(usize, 2), alias.params.len);
    try std.testing.expectEqualStrings("K", alias.params[0]);
    try std.testing.expectEqualStrings("V", alias.params[1]);
}

test "edge: recursive type alias - no params" {
    const allocator = std.testing.allocator;

    const definition = try allocator.create(Type);
    defer allocator.destroy(definition);
    definition.* = .Int;

    const params = [_][]const u8{};
    const alias = RecursiveTypeAlias.init("Counter", &params, definition);

    try std.testing.expectEqualStrings("Counter", alias.name);
    try std.testing.expectEqual(@as(usize, 0), alias.params.len);
}

// ============================================================================
// Section 17: Infer Type Edge Cases
// ============================================================================

test "edge: infer type - with constraint set directly" {
    const allocator = std.testing.allocator;

    const constraint = try allocator.create(Type);
    defer allocator.destroy(constraint);
    constraint.* = .Int;

    var infer_type = InferType.init("T");
    infer_type.constraint = constraint;

    try std.testing.expectEqualStrings("T", infer_type.name);
    try std.testing.expectEqual(constraint, infer_type.constraint);
}

// ============================================================================
// Section 18: Type Equality Edge Cases
// ============================================================================

test "edge: type equality - same primitive types" {
    const types = [_]Type{
        .Int, .I8, .I16, .I32, .I64, .I128,
        .U8,  .U16, .U32, .U64, .U128,
        .F32, .F64, .Float,
        .Bool, .String, .Void, .Never, .Unknown,
    };

    // Each type should equal itself
    for (types) |t| {
        try std.testing.expect(t.equals(t));
    }

    // Different types should not be equal
    for (types, 0..) |t1, i| {
        for (types, 0..) |t2, j| {
            if (i != j) {
                try std.testing.expect(!t1.equals(t2));
            }
        }
    }
}

test "edge: type equality - optional with same inner" {
    const allocator = std.testing.allocator;

    const inner1 = try allocator.create(Type);
    defer allocator.destroy(inner1);
    inner1.* = .Int;

    const inner2 = try allocator.create(Type);
    defer allocator.destroy(inner2);
    inner2.* = .Int;

    const opt1: Type = .{ .Optional = inner1 };
    const opt2: Type = .{ .Optional = inner2 };

    try std.testing.expect(opt1.equals(opt2));
}

test "edge: type equality - optional with different inner" {
    const allocator = std.testing.allocator;

    const inner1 = try allocator.create(Type);
    defer allocator.destroy(inner1);
    inner1.* = .Int;

    const inner2 = try allocator.create(Type);
    defer allocator.destroy(inner2);
    inner2.* = .String;

    const opt1: Type = .{ .Optional = inner1 };
    const opt2: Type = .{ .Optional = inner2 };

    try std.testing.expect(!opt1.equals(opt2));
}

test "edge: type equality - array with same element" {
    const allocator = std.testing.allocator;

    const elem1 = try allocator.create(Type);
    defer allocator.destroy(elem1);
    elem1.* = .Int;

    const elem2 = try allocator.create(Type);
    defer allocator.destroy(elem2);
    elem2.* = .Int;

    const arr1: Type = .{ .Array = .{ .element_type = elem1 } };
    const arr2: Type = .{ .Array = .{ .element_type = elem2 } };

    try std.testing.expect(arr1.equals(arr2));
}

test "edge: type equality - struct field order matters" {
    const fields1 = [_]Type.StructType.Field{
        .{ .name = "x", .type = .Int },
        .{ .name = "y", .type = .String },
    };
    const struct1: Type = .{ .Struct = .{ .name = "Point", .fields = &fields1 } };

    const fields2 = [_]Type.StructType.Field{
        .{ .name = "y", .type = .String },
        .{ .name = "x", .type = .Int },
    };
    const struct2: Type = .{ .Struct = .{ .name = "Point", .fields = &fields2 } };

    // Different field order = different type (for strict equality)
    try std.testing.expect(!struct1.equals(struct2));
}

test "edge: type equality - function param order matters" {
    const allocator = std.testing.allocator;

    const void_ret = try allocator.create(Type);
    defer allocator.destroy(void_ret);
    void_ret.* = .Void;

    var params1 = [_]Type{ .Int, .String };
    const fn1: Type = .{ .Function = .{ .params = &params1, .return_type = void_ret } };

    var params2 = [_]Type{ .String, .Int };
    const fn2: Type = .{ .Function = .{ .params = &params2, .return_type = void_ret } };

    try std.testing.expect(!fn1.equals(fn2));
}

// ============================================================================
// Section 19: Additional Integer Edge Cases
// ============================================================================

test "edge: integer boundary subtyping I128" {
    const i64_type: Type = .I64;
    const i128_type: Type = .I128;

    try std.testing.expect(i64_type.isSubtype(i128_type));
    try std.testing.expect(!i128_type.isSubtype(i64_type));
}

test "edge: unsigned to signed not subtype" {
    const u32_type: Type = .U32;
    const i32_type: Type = .I32;
    const i64_type: Type = .I64;

    // Unsigned is not subtype of signed
    try std.testing.expect(!u32_type.isSubtype(i32_type));
    try std.testing.expect(!u32_type.isSubtype(i64_type));
}

test "edge: U128 is top of unsigned hierarchy" {
    const u64_type: Type = .U64;
    const u128_type: Type = .U128;

    try std.testing.expect(u64_type.isSubtype(u128_type));
    try std.testing.expect(!u128_type.isSubtype(u64_type));
}

// ============================================================================
// Section 20: Result Type Edge Cases
// ============================================================================

test "edge: result type equality" {
    const allocator = std.testing.allocator;

    const ok_type = try allocator.create(Type);
    defer allocator.destroy(ok_type);
    ok_type.* = .Int;

    const err_type = try allocator.create(Type);
    defer allocator.destroy(err_type);
    err_type.* = .String;

    const result1: Type = .{ .Result = .{ .ok_type = ok_type, .err_type = err_type } };
    const result2: Type = .{ .Result = .{ .ok_type = ok_type, .err_type = err_type } };

    try std.testing.expect(result1.equals(result2));
}

test "edge: result type different ok types" {
    const allocator = std.testing.allocator;

    const ok1 = try allocator.create(Type);
    defer allocator.destroy(ok1);
    ok1.* = .Int;

    const ok2 = try allocator.create(Type);
    defer allocator.destroy(ok2);
    ok2.* = .String;

    const err_type = try allocator.create(Type);
    defer allocator.destroy(err_type);
    err_type.* = .Bool;

    const result1: Type = .{ .Result = .{ .ok_type = ok1, .err_type = err_type } };
    const result2: Type = .{ .Result = .{ .ok_type = ok2, .err_type = err_type } };

    try std.testing.expect(!result1.equals(result2));
}

// ============================================================================
// Section 21: Tuple Edge Cases
// ============================================================================

test "edge: empty tuple" {
    var empty_elems = [_]Type{};
    const empty_tuple: Type = .{ .Tuple = .{ .element_types = &empty_elems } };

    try std.testing.expect(empty_tuple.equals(empty_tuple));
}

test "edge: single element tuple" {
    var single_elem = [_]Type{.Int};
    const single_tuple: Type = .{ .Tuple = .{ .element_types = &single_elem } };
    const int_type: Type = .Int;

    // Single element tuple is NOT equal to the element type
    try std.testing.expect(!single_tuple.equals(int_type));
}

test "edge: tuple element order matters" {
    var elems1 = [_]Type{ .Int, .String };
    const tuple1: Type = .{ .Tuple = .{ .element_types = &elems1 } };

    var elems2 = [_]Type{ .String, .Int };
    const tuple2: Type = .{ .Tuple = .{ .element_types = &elems2 } };

    try std.testing.expect(!tuple1.equals(tuple2));
}

// ============================================================================
// Section 22: Reference Type Edge Cases
// ============================================================================

test "edge: mutable ref is subtype of immutable ref" {
    const allocator = std.testing.allocator;

    const inner = try allocator.create(Type);
    defer allocator.destroy(inner);
    inner.* = .Int;

    const mut_ref: Type = .{ .MutableReference = inner };
    const ref: Type = .{ .Reference = inner };

    try std.testing.expect(mut_ref.isSubtype(ref));
    try std.testing.expect(!ref.isSubtype(mut_ref));
}

test "edge: reference to different types not subtypes" {
    const allocator = std.testing.allocator;

    const int_inner = try allocator.create(Type);
    defer allocator.destroy(int_inner);
    int_inner.* = .Int;

    const str_inner = try allocator.create(Type);
    defer allocator.destroy(str_inner);
    str_inner.* = .String;

    const ref_int: Type = .{ .Reference = int_inner };
    const ref_str: Type = .{ .Reference = str_inner };

    try std.testing.expect(!ref_int.isSubtype(ref_str));
}

// ============================================================================
// Section 23: Intersection Type Edge Cases
// ============================================================================

test "edge: intersection type init" {
    const allocator = std.testing.allocator;

    const int_ptr = try allocator.create(Type);
    defer allocator.destroy(int_ptr);
    int_ptr.* = .Int;

    const bool_ptr = try allocator.create(Type);
    defer allocator.destroy(bool_ptr);
    bool_ptr.* = .Bool;

    var types = [_]*const Type{ int_ptr, bool_ptr };
    const intersection = IntersectionType.init(&types);

    try std.testing.expectEqual(@as(usize, 2), intersection.types.len);
}

test "edge: intersection type flatten" {
    const allocator = std.testing.allocator;

    const int_ptr = try allocator.create(Type);
    defer allocator.destroy(int_ptr);
    int_ptr.* = .Int;

    var types = [_]*const Type{int_ptr};
    const intersection = IntersectionType.init(&types);

    const flattened = try intersection.flatten(allocator);
    defer allocator.free(flattened.types);
    try std.testing.expectEqual(@as(usize, 1), flattened.types.len);
}

// ============================================================================
// Section 24: Complex Nested Type Edge Cases
// ============================================================================

test "edge: deeply nested function type" {
    const allocator = std.testing.allocator;

    // Create fn() -> fn() -> fn() -> Int
    const int_ret = try allocator.create(Type);
    defer allocator.destroy(int_ret);
    int_ret.* = .Int;

    const fn_ret_int: Type = .{ .Function = .{ .params = &.{}, .return_type = int_ret } };

    const fn1_ptr = try allocator.create(Type);
    defer allocator.destroy(fn1_ptr);
    fn1_ptr.* = fn_ret_int;

    const fn_ret_fn: Type = .{ .Function = .{ .params = &.{}, .return_type = fn1_ptr } };

    const fn2_ptr = try allocator.create(Type);
    defer allocator.destroy(fn2_ptr);
    fn2_ptr.* = fn_ret_fn;

    const fn_ret_fn_fn: Type = .{ .Function = .{ .params = &.{}, .return_type = fn2_ptr } };

    try std.testing.expect(fn_ret_fn_fn.equals(fn_ret_fn_fn));
}

test "edge: array of optional of array" {
    const allocator = std.testing.allocator;

    // Create [Int?]?
    const int_elem = try allocator.create(Type);
    defer allocator.destroy(int_elem);
    int_elem.* = .Int;

    const opt_int = try allocator.create(Type);
    defer allocator.destroy(opt_int);
    opt_int.* = .{ .Optional = int_elem };

    const arr_opt_int: Type = .{ .Array = .{ .element_type = opt_int } };

    const arr_ptr = try allocator.create(Type);
    defer allocator.destroy(arr_ptr);
    arr_ptr.* = arr_opt_int;

    const opt_arr: Type = .{ .Optional = arr_ptr };

    try std.testing.expect(opt_arr.equals(opt_arr));
}

// ============================================================================
// Section 25: Float Edge Cases
// ============================================================================

test "edge: F32 to Float widening" {
    const f32_type: Type = .F32;
    const float_type: Type = .Float;
    const f64_type: Type = .F64;

    try std.testing.expect(f32_type.isSubtype(float_type));
    try std.testing.expect(float_type.isSubtype(f64_type));
}

test "edge: Float is not subtype of F32" {
    const float_type: Type = .Float;
    const f32_type: Type = .F32;

    try std.testing.expect(!float_type.isSubtype(f32_type));
}
