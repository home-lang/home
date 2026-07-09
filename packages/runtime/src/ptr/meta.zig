// Copied from bun/src/ptr/meta.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Zig 0.17 compat rewrites:
//   * `pointer_info.alignment` is now `?usize` (null = default). The default
//     check is folded into the optional unwrap.
//   * `@Type(type_info)` was split into per-kind builtins in 0.17. `AddConst`
//     is reimplemented with `@Pointer(size, attrs, child, sentinel)` and direct
//     recursion through `.optional`, matching `std.meta.Sentinel` in 0.17.
//
//! Private utilities used in smart pointer implementations.

pub const PointerInfo = struct {
    const Self = @This();

    /// A possibly optional slice or single-item pointer type.
    /// E.g., `*u8`, `[]u8`, `?*u8`, `?[]u8`.
    Pointer: type,

    /// If `Pointer` is an optional pointer, this is the non-optional equivalent. Otherwise, this
    /// is the same as `Pointer`.
    ///
    /// For example, if `Pointer` is `?[]u8`, this is `[]u8`.
    NonOptionalPointer: type,

    /// The type of data stored by the pointer, i.e., the type obtained by dereferencing a
    /// single-item pointer or accessing an element of a slice.
    ///
    /// For example, if `Pointer` is `?[]u8`, this is `u8`.
    Child: type,

    pub fn kind(self: Self) enum { single, slice } {
        return switch (@typeInfo(self.NonOptionalPointer).pointer.size) {
            .one => .single,
            .slice => .slice,
            else => @compileError("unreachable"),
        };
    }

    pub fn isOptional(self: Self) bool {
        return @typeInfo(self.Pointer) == .optional;
    }

    pub fn isConst(self: Self) bool {
        return @typeInfo(self.NonOptionalPointer).pointer.attrs.@"const";
    }

    pub const ParseOptions = struct {
        allow_const: bool = true,
        allow_slices: bool = true,
    };

    pub fn parse(comptime Pointer: type, comptime options: ParseOptions) Self {
        const NonOptionalPointer = switch (@typeInfo(Pointer)) {
            .optional => |opt| opt.child,
            else => Pointer,
        };

        const pointer_info = switch (@typeInfo(NonOptionalPointer)) {
            .pointer => |ptr| ptr,
            else => @compileError("type must be a (possibly optional) pointer"),
        };
        const Child = pointer_info.child;

        switch (pointer_info.size) {
            .one => {},
            .slice => if (!options.allow_slices) @compileError("slices not supported"),
            .many => @compileError("many-item pointers not supported"),
            .c => @compileError("C pointers not supported"),
        }

        if (pointer_info.attrs.@"const" and !options.allow_const) {
            @compileError("const pointers not supported");
        }
        if (pointer_info.attrs.@"volatile") {
            @compileError("volatile pointers not supported");
        }
        // Zig 0.17: `align` is `?usize`; null means "default for Child".
        if (pointer_info.attrs.@"align") |a| {
            if (a != @alignOf(Child)) {
                @compileError("non-default alignment not supported");
            }
        }
        if (pointer_info.attrs.@"allowzero") {
            @compileError("allowzero not supported");
        }
        if (pointer_info.sentinel_ptr != null) {
            @compileError("sentinel-terminated pointers not supported");
        }

        return .{
            .Pointer = Pointer,
            .NonOptionalPointer = NonOptionalPointer,
            .Child = Child,
        };
    }
};

pub fn AddConst(Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| @Pointer(info.size, blk: {
            var a = info.attrs;
            a.@"const" = true;
            break :blk a;
        }, info.child, info.sentinel()),
        .optional => |opt| ?AddConst(opt.child),
        // Technically this function accepts things like `?????[]u8`, but `PointerInfo.parse`
        // verifies that's not the case.
        else => @compileError("`Pointer` must be a (possibly optional) pointer or slice"),
    };
}

const std = @import("std");
const testing = std.testing;

test "PointerInfo.parse single pointer" {
    const info = PointerInfo.parse(*u32, .{});
    try testing.expectEqual(*u32, info.Pointer);
    try testing.expectEqual(*u32, info.NonOptionalPointer);
    try testing.expectEqual(u32, info.Child);
    try testing.expect(!info.isOptional());
    try testing.expect(!info.isConst());
    try testing.expectEqual(@as(@TypeOf(info.kind()), .single), info.kind());
}

test "PointerInfo.parse optional slice" {
    const info = PointerInfo.parse(?[]const u8, .{});
    try testing.expectEqual(?[]const u8, info.Pointer);
    try testing.expectEqual([]const u8, info.NonOptionalPointer);
    try testing.expectEqual(u8, info.Child);
    try testing.expect(info.isOptional());
    try testing.expect(info.isConst());
    try testing.expectEqual(@as(@TypeOf(info.kind()), .slice), info.kind());
}

test "AddConst on pointer and optional" {
    try testing.expectEqual(*const u32, AddConst(*u32));
    try testing.expectEqual(?*const u32, AddConst(?*u32));
    try testing.expectEqual([]const u8, AddConst([]u8));
    try testing.expectEqual(?[]const u8, AddConst(?[]u8));
}
