// Copied from bun/src/install/padding_checker.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"). This file is pure
// `std` and has no actual bun.X references, so the rewrite is a no-op; the
// banner is here so the provenance trail matches sibling files.

/// In some parts of lockfile serialization, Bun will use `std.mem.sliceAsBytes` to convert a struct into raw
/// bytes to write. This makes lockfile serialization/deserialization much simpler/faster, at the cost of not
/// having any pointers within these structs.
///
/// One major caveat of this is that if any of these structs have uninitialized memory, then that can leak
/// garbage memory into the lockfile. See https://github.com/oven-sh/bun/issues/4319
///
/// The obvious way to introduce undefined memory into a struct is via `.field = undefined`, but a much more
/// subtle way is to have implicit padding in an extern struct. For example:
/// ```zig
/// const Demo = struct {
///     a: u8,  // @sizeOf(Demo, "a") == 1,   @offsetOf(Demo, "a") == 0
///     b: u64, // @sizeOf(Demo, "b") == 8,   @offsetOf(Demo, "b") == 8
/// }
/// ```
///
/// `a` is only one byte long, but due to the alignment of `b`, there is 7 bytes of padding between `a` and `b`,
/// which is considered *undefined memory*.
///
/// The solution is to have it explicitly initialized to zero bytes, like:
/// ```zig
/// const Demo = extern struct {
///     a: u8,
///     _padding: [7]u8 = @splat(0),
///     b: u64, // same offset as before
/// }
/// ```
///
/// There is one other way to introduce undefined memory into a struct, which this does not check for, and that is
/// a union with unequal size fields.
pub fn assertNoUninitializedPadding(comptime T: type) void {
    const info_ = @typeInfo(T);
    const info = switch (info_) {
        .@"struct" => info_.@"struct",
        .@"union" => info_.@"union",
        .array => |a| {
            assertNoUninitializedPadding(a.child);
            return;
        },
        .optional => |a| {
            assertNoUninitializedPadding(a.child);
            return;
        },
        .pointer => |ptr| {
            // Pointers aren't allowed, but this just makes the assertion easier to invoke.
            assertNoUninitializedPadding(ptr.child);
            return;
        },
        else => {
            return;
        },
    };
    // if (info.layout != .Extern) {
    //     @compileError("assertNoUninitializedPadding(" ++ @typeName(T) ++ ") expects an extern struct type, got a struct of layout '" ++ @tagName(info.layout) ++ "'");
    // }
    for (info.field_names, info.field_types) |field_name, field_type| {
        const fieldInfo = @typeInfo(field_type);
        switch (fieldInfo) {
            .@"struct" => assertNoUninitializedPadding(field_type),
            .@"union" => assertNoUninitializedPadding(field_type),
            .array => |a| assertNoUninitializedPadding(a.child),
            .optional => |a| assertNoUninitializedPadding(a.child),
            .pointer => {
                @compileError("Expected no pointer types in " ++ @typeName(T) ++ ", found field '" ++ field_name ++ "' of type '" ++ @typeName(field_type) ++ "'");
            },
            else => {},
        }
    }

    if (info_ == .@"union") {
        return;
    }

    var i = 0;
    for (info.field_names, info.field_types, 0..) |field_name, field_type, j| {
        const offset = @offsetOf(T, field_name);
        if (offset != i) {
            @compileError(std.fmt.comptimePrint(
                \\Expected no possibly uninitialized bytes of memory in '{s}', but found a {d} byte gap between fields '{s}' and '{s}' This can be fixed by adding a padding field to the struct like `padding: [{d}]u8 = .{{0}} ** {d},` between these fields. For more information, look at `padding_checker.zig`
            ,
                .{
                    @typeName(T),
                    offset - i,
                    info.field_names[j - 1],
                    field_name,
                    offset - i,
                    offset - i,
                },
            ));
        }
        i = offset + @sizeOf(field_type);
    }

    if (i != @sizeOf(T)) {
        @compileError(std.fmt.comptimePrint(
            \\Expected no possibly uninitialized bytes of memory in '{s}', but found a {d} byte gap at the end of the struct. This can be fixed by adding a padding field to the struct like `padding: [{d}]u8 = .{{0}} ** {d},` between these fields. For more information, look at `padding_checker.zig`
        ,
            .{
                @typeName(T),
                @sizeOf(T) - i,
                @sizeOf(T) - i,
                @sizeOf(T) - i,
            },
        ));
    }
}

test "assertNoUninitializedPadding accepts a tightly-packed struct" {
    // Compile-time invocation: if the struct has implicit padding, this would
    // emit a `@compileError`. The fact that `zig test` compiles confirms the
    // checker accepts it.
    const Packed = extern struct {
        a: u32 = 0,
        b: u32 = 0,
    };
    comptime assertNoUninitializedPadding(Packed);
}

test "assertNoUninitializedPadding accepts a struct with explicit padding" {
    const PaddedExplicit = extern struct {
        a: u8 = 0,
        _pad: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
        b: u64 = 0,
    };
    comptime assertNoUninitializedPadding(PaddedExplicit);
}

test "assertNoUninitializedPadding accepts arrays of accepted types" {
    const Packed = extern struct {
        x: u32 = 0,
        y: u32 = 0,
    };
    const arr_t = [3]Packed;
    comptime assertNoUninitializedPadding(arr_t);
}

test "assertNoUninitializedPadding accepts optionals + non-aggregate types" {
    comptime assertNoUninitializedPadding(?u32);
    comptime assertNoUninitializedPadding(u8);
    comptime assertNoUninitializedPadding(i64);
}

const std = @import("std");
