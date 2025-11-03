const std = @import("std");
const testing = std.testing;
const Type = @import("types").Type;

test "integer type variants" {
    // Signed integers
    const i8_type = Type.I8;
    const i16_type = Type.I16;
    const i32_type = Type.I32;
    const i64_type = Type.I64;
    const i128_type = Type.I128;

    try testing.expect(!i8_type.isDefaultType());
    try testing.expect(!i16_type.isDefaultType());
    try testing.expect(!i32_type.isDefaultType());
    try testing.expect(!i64_type.isDefaultType());
    try testing.expect(!i128_type.isDefaultType());

    // Unsigned integers
    const u8_type = Type.U8;
    const u16_type = Type.U16;
    const u32_type = Type.U32;
    const u64_type = Type.U64;
    const u128_type = Type.U128;

    try testing.expect(!u8_type.isDefaultType());
    try testing.expect(!u16_type.isDefaultType());
    try testing.expect(!u32_type.isDefaultType());
    try testing.expect(!u64_type.isDefaultType());
    try testing.expect(!u128_type.isDefaultType());
}

test "float type variants" {
    const f32_type = Type.F32;
    const f64_type = Type.F64;

    try testing.expect(!f32_type.isDefaultType());
    try testing.expect(!f64_type.isDefaultType());
}

test "default type resolution" {
    const int_type = Type.Int;
    const float_type = Type.Float;

    try testing.expect(int_type.isDefaultType());
    try testing.expect(float_type.isDefaultType());

    const resolved_int = int_type.resolveDefault();
    const resolved_float = float_type.resolveDefault();

    try testing.expect(resolved_int.equals(Type.I64));
    try testing.expect(resolved_float.equals(Type.F64));
}

test "type equality - same types" {
    try testing.expect(Type.I8.equals(Type.I8));
    try testing.expect(Type.I16.equals(Type.I16));
    try testing.expect(Type.I32.equals(Type.I32));
    try testing.expect(Type.I64.equals(Type.I64));
    try testing.expect(Type.I128.equals(Type.I128));

    try testing.expect(Type.U8.equals(Type.U8));
    try testing.expect(Type.U16.equals(Type.U16));
    try testing.expect(Type.U32.equals(Type.U32));
    try testing.expect(Type.U64.equals(Type.U64));
    try testing.expect(Type.U128.equals(Type.U128));

    try testing.expect(Type.F32.equals(Type.F32));
    try testing.expect(Type.F64.equals(Type.F64));

    try testing.expect(Type.Bool.equals(Type.Bool));
    try testing.expect(Type.String.equals(Type.String));
    try testing.expect(Type.Void.equals(Type.Void));
}

test "type equality - different types" {
    try testing.expect(!Type.I8.equals(Type.I16));
    try testing.expect(!Type.I32.equals(Type.I64));
    try testing.expect(!Type.U8.equals(Type.I8));
    try testing.expect(!Type.F32.equals(Type.F64));
    try testing.expect(!Type.Int.equals(Type.Float));
    try testing.expect(!Type.Bool.equals(Type.String));
}

test "type equality - default vs concrete" {
    const int_type = Type.Int;
    const i64_type = Type.I64;

    // Default Int should equal I64 when resolved
    const resolved = int_type.resolveDefault();
    try testing.expect(resolved.equals(i64_type));

    // But unresolved Int should not equal I64
    try testing.expect(!int_type.equals(i64_type));
}

test "type format - integer types" {
    var buf: [50]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try Type.I8.format("", .{}, writer);
    try testing.expectEqualStrings("i8", fbs.getWritten());

    fbs.reset();
    try Type.I16.format("", .{}, writer);
    try testing.expectEqualStrings("i16", fbs.getWritten());

    fbs.reset();
    try Type.I32.format("", .{}, writer);
    try testing.expectEqualStrings("i32", fbs.getWritten());

    fbs.reset();
    try Type.I64.format("", .{}, writer);
    try testing.expectEqualStrings("i64", fbs.getWritten());

    fbs.reset();
    try Type.I128.format("", .{}, writer);
    try testing.expectEqualStrings("i128", fbs.getWritten());
}

test "type format - unsigned integer types" {
    var buf: [50]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try Type.U8.format("", .{}, writer);
    try testing.expectEqualStrings("u8", fbs.getWritten());

    fbs.reset();
    try Type.U16.format("", .{}, writer);
    try testing.expectEqualStrings("u16", fbs.getWritten());

    fbs.reset();
    try Type.U32.format("", .{}, writer);
    try testing.expectEqualStrings("u32", fbs.getWritten());

    fbs.reset();
    try Type.U64.format("", .{}, writer);
    try testing.expectEqualStrings("u64", fbs.getWritten());

    fbs.reset();
    try Type.U128.format("", .{}, writer);
    try testing.expectEqualStrings("u128", fbs.getWritten());
}

test "type format - float types" {
    var buf: [50]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try Type.F32.format("", .{}, writer);
    try testing.expectEqualStrings("f32", fbs.getWritten());

    fbs.reset();
    try Type.F64.format("", .{}, writer);
    try testing.expectEqualStrings("f64", fbs.getWritten());
}

test "type format - default types" {
    var buf: [50]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try Type.Int.format("", .{}, writer);
    try testing.expectEqualStrings("int", fbs.getWritten());

    fbs.reset();
    try Type.Float.format("", .{}, writer);
    try testing.expectEqualStrings("float", fbs.getWritten());
}

test "type format - basic types" {
    var buf: [50]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try Type.Bool.format("", .{}, writer);
    try testing.expectEqualStrings("bool", fbs.getWritten());

    fbs.reset();
    try Type.String.format("", .{}, writer);
    try testing.expectEqualStrings("string", fbs.getWritten());

    fbs.reset();
    try Type.Void.format("", .{}, writer);
    try testing.expectEqualStrings("void", fbs.getWritten());
}
