pub fn OptionalChild(comptime T: type) type {
    const tyinfo = @typeInfo(T);
    if (tyinfo != .pointer) @compileError("OptionalChild(T) requires that T be a pointer to an optional type.");
    const child = @typeInfo(tyinfo.pointer.child);
    if (child != .optional) @compileError("OptionalChild(T) requires that T be a pointer to an optional type.");
    return child.optional.child;
}

pub fn EnumFields(comptime T: type) []const std.builtin.Type.EnumField {
    const tyinfo = @typeInfo(T);
    return switch (tyinfo) {
        .@"union" => std.meta.fields(tyinfo.@"union".tag_type.?),
        .@"enum" => tyinfo.@"enum".fields,
        else => {
            @compileError("Used `EnumFields(T)` on a type that is not an `enum` or a `union(enum)`");
        },
    };
}

pub fn ReturnOfMaybe(comptime function: anytype) type {
    const Func = @TypeOf(function);
    const typeinfo: std.builtin.Type.Fn = @typeInfo(Func).@"fn";
    const MaybeType = typeinfo.return_type orelse @compileError("Expected the function to have a return type");
    return MaybeResult(MaybeType);
}

pub fn MaybeResult(comptime MaybeType: type) type {
    const maybe_ty_info = @typeInfo(MaybeType);

    const maybe = maybe_ty_info.@"union";
    if (maybe.fields.len != 2) @compileError("Expected the Maybe type to be a union(enum) with two variants");

    if (!std.mem.eql(u8, maybe.fields[0].name, "err")) {
        @compileError("Expected the first field of the Maybe type to be \"err\", got: " ++ maybe.fields[0].name);
    }

    if (!std.mem.eql(u8, maybe.fields[1].name, "result")) {
        @compileError("Expected the second field of the Maybe type to be \"result\"" ++ maybe.fields[1].name);
    }

    return maybe.fields[1].type;
}

pub fn ReturnOf(comptime function: anytype) type {
    return ReturnOfType(@TypeOf(function));
}

pub fn ReturnOfType(comptime Type: type) type {
    const typeinfo: std.builtin.Type.Fn = @typeInfo(Type).@"fn";
    return typeinfo.return_type orelse void;
}

pub fn typeName(comptime Type: type) []const u8 {
    const name = @typeName(Type);
    return typeBaseName(name);
}

/// partially emulates behaviour of @typeName in previous Zig versions,
/// converting "some.namespace.MyType" to "MyType"
pub inline fn typeBaseName(comptime fullname: [:0]const u8) [:0]const u8 {
    @setEvalBranchQuota(1_000_000);
    // leave type name like "namespace.WrapperType(namespace.MyType)" as it is
    const baseidx = comptime std.mem.indexOf(u8, fullname, "(");
    if (baseidx != null) return comptime fullname;

    const idx = comptime std.mem.lastIndexOf(u8, fullname, ".");

    const name = if (idx == null) fullname else fullname[(idx.? + 1)..];
    return comptime name;
}

pub fn enumFieldNames(comptime Type: type) []const []const u8 {
    const Filtered = struct {
        const raw = blk: {
            var filtered_names: [std.meta.fields(Type).len][]const u8 = std.meta.fieldNames(Type).*;
            var i: usize = 0;
            for (filtered_names) |name| {
                // zig seems to include "_" or an empty string in the list of enum field names
                // it makes sense, but humans don't want that
                if (eqlAnyComptime(name, &.{ "_none", "", "_" })) {
                    continue;
                }
                filtered_names[i] = name;
                i += 1;
            }
            break :blk .{ .names = filtered_names, .len = i };
        };
        const len = raw.len;
        const names: [raw.names.len][]const u8 = raw.names;
    };
    return Filtered.names[0..Filtered.len];
}

pub fn banFieldType(comptime Container: type, comptime T: type) void {
    comptime {
        for (std.meta.fields(Container)) |field| {
            if (field.type == T) {
                @compileError(std.fmt.comptimePrint(typeName(T) ++ " field \"" ++ field.name ++ "\" not allowed in " ++ typeName(Container), .{}));
            }
        }
    }
}

// []T -> T
// *const T -> T
// *[n]T -> T
pub fn Item(comptime T: type) type {
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .one) {
                switch (@typeInfo(ptr.child)) {
                    .array => |array| {
                        return array.child;
                    },
                    else => {},
                }
            }
            return ptr.child;
        },
        else => return std.meta.Child(T),
    }
}

/// Returns .{a, ...args_}
pub fn ConcatArgs1(
    comptime func: anytype,
    a: anytype,
    args_: anytype,
) std.meta.ArgsTuple(@TypeOf(func)) {
    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    args[0] = a;

    inline for (args_, 1..) |arg, i| {
        args[i] = arg;
    }

    return args;
}

/// Returns .{a, b, ...args_}
pub inline fn ConcatArgs2(
    comptime func: anytype,
    a: anytype,
    b: anytype,
    args_: anytype,
) std.meta.ArgsTuple(@TypeOf(func)) {
    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    args[0] = a;
    args[1] = b;

    inline for (args_, 2..) |arg, i| {
        args[i] = arg;
    }

    return args;
}

/// Returns .{a, b, c, d, ...args_}
pub inline fn ConcatArgs4(
    comptime func: anytype,
    a: anytype,
    b: anytype,
    c: anytype,
    d: anytype,
    args_: anytype,
) std.meta.ArgsTuple(@TypeOf(func)) {
    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    args[0] = a;
    args[1] = b;
    args[2] = c;
    args[3] = d;

    inline for (args_, 4..) |arg, i| {
        args[i] = arg;
    }

    return args;
}

// Copied from std.meta
fn CreateUniqueTuple(comptime N: comptime_int, comptime types: [N]type) type {
    return @Tuple(&types);
}

pub const TaggedUnion = @import("./tagged_union.zig").TaggedUnion;

pub fn hasStableMemoryLayout(comptime T: type) bool {
    const tyinfo = @typeInfo(T);
    return switch (tyinfo) {
        .type => true,
        .void => true,
        .bool => true,
        .int => true,
        .float => true,
        .@"enum" => {
            // not supporting this rn
            if (tyinfo.@"enum".is_exhaustive) return false;
            return hasStableMemoryLayout(tyinfo.@"enum".tag_type);
        },
        .@"struct" => switch (tyinfo.@"struct".layout) {
            .auto => {
                inline for (tyinfo.@"struct".fields) |field| {
                    if (!hasStableMemoryLayout(field.type)) return false;
                }
                return true;
            },
            .@"extern" => true,
            .@"packed" => false,
        },
        .@"union" => switch (tyinfo.@"union".layout) {
            .auto => {
                if (tyinfo.@"union".tag_type == null or !hasStableMemoryLayout(tyinfo.@"union".tag_type.?)) return false;

                inline for (tyinfo.@"union".fields) |field| {
                    if (!hasStableMemoryLayout(field.type)) return false;
                }

                return true;
            },
            .@"extern" => true,
            .@"packed" => false,
        },
        else => true,
    };
}

pub fn isSimpleCopyType(comptime T: type) bool {
    @setEvalBranchQuota(1_000_000);
    const tyinfo = @typeInfo(T);
    return switch (tyinfo) {
        .void => true,
        .bool => true,
        .int => true,
        .float => true,
        .@"enum" => true,
        .@"struct" => {
            inline for (tyinfo.@"struct".fields) |field| {
                if (!isSimpleCopyType(field.type)) return false;
            }
            return true;
        },
        .@"union" => {
            inline for (tyinfo.@"union".fields) |field| {
                if (!isSimpleCopyType(field.type)) return false;
            }
            return true;
        },
        .optional => return isSimpleCopyType(tyinfo.optional.child),
        else => false,
    };
}

pub fn isScalar(comptime T: type) bool {
    return switch (T) {
        i32, u32, i64, u64, f32, f64, bool => true,
        else => {
            const tyinfo = @typeInfo(T);
            if (tyinfo == .@"enum") return true;
            return false;
        },
    };
}

pub fn isSimpleEqlType(comptime T: type) bool {
    const tyinfo = @typeInfo(T);
    return switch (tyinfo) {
        .type => true,
        .void => true,
        .bool => true,
        .int => true,
        .float => true,
        .@"enum" => true,
        .@"struct" => |struct_info| struct_info.layout == .@"packed",
        else => false,
    };
}

pub const ListContainerType = enum {
    array_list,
    baby_list,
    small_list,
};
pub fn looksLikeListContainerType(comptime T: type) ?struct { list: ListContainerType, child: type } {
    const tyinfo = @typeInfo(T);
    if (tyinfo == .@"struct") {
        const fields = tyinfo.@"struct".fields;

        // Looks like array list
        if (fields.len == 2 and
            std.mem.eql(u8, fields[0].name, "items") and
            std.mem.eql(u8, fields[1].name, "capacity"))
            return .{ .list = .array_list, .child = std.meta.Child(fields[0].type) };

        // Looks like babylist
        if (@hasDecl(T, "looksLikeContainerTypeBabyList")) {
            return .{ .list = .baby_list, .child = T.looksLikeContainerTypeBabyList };
        }

        // Looks like SmallList
        if (@hasDecl(T, "looksLikeContainerTypeSmallList")) {
            return .{ .list = .small_list, .child = T.looksLikeContainerTypeSmallList };
        }
    }

    return null;
}

pub fn Tagged(comptime U: type, comptime T: type) type {
    const info: std.builtin.Type.Union = @typeInfo(U).@"union";
    var field_names: [info.fields.len][]const u8 = undefined;
    var field_types: [info.fields.len]type = undefined;
    var field_attrs: [info.fields.len]std.builtin.Type.UnionField.Attributes = undefined;
    for (info.fields, &field_names, &field_types, &field_attrs) |field, *name, *FieldType, *attrs| {
        name.* = field.name;
        FieldType.* = field.type;
        attrs.* = .{ .@"align" = field.alignment };
    }
    return @Union(.auto, T, &field_names, &field_types, &field_attrs);
}

pub fn SliceChild(comptime T: type) type {
    const tyinfo = @typeInfo(T);
    if (tyinfo == .pointer and tyinfo.pointer.size == .slice) {
        return tyinfo.pointer.child;
    }
    return T;
}

/// userland implementation of https://github.com/ziglang/zig/issues/21879
pub fn useAllFields(comptime T: type, _: VoidFields(T)) void {}

fn VoidFields(comptime T: type) type {
    const fields = @typeInfo(T).@"struct".fields;
    var field_names: [fields.len][]const u8 = undefined;
    var field_types: [fields.len]type = undefined;
    var field_attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, &field_names, &field_types, &field_attrs) |field, *name, *FieldType, *attrs| {
        name.* = field.name;
        FieldType.* = void;
        attrs.* = .{
            .@"comptime" = field.is_comptime,
            .@"align" = field.alignment,
            .default_value_ptr = null,
        };
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

pub fn voidFieldTypeDiscardHelper(data: anytype) void {
    _ = data;
}

pub fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

pub fn hasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasField(T, name),
        else => false,
    };
}

fn eqlAnyComptime(value: []const u8, comptime needles: []const []const u8) bool {
    inline for (needles) |needle| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

const std = @import("std");

test "meta helper leaves" {
    const testing = std.testing;

    const Maybe = union(enum) {
        err: void,
        result: u32,
    };
    const maybeFn = struct {
        fn call() Maybe {
            return .{ .result = 1 };
        }
    }.call;

    try testing.expectEqual(u32, OptionalChild(*?u32));
    try testing.expectEqual(u32, ReturnOfMaybe(maybeFn));
    try testing.expectEqual(u32, ReturnOfType(fn () u32));
    try testing.expectEqual(u8, Item(*const [4]u8));
    try testing.expectEqual(u8, SliceChild([]const u8));

    const CreatedTuple = CreateUniqueTuple(2, .{ u8, u16 });
    try testing.expectEqual(u8, @typeInfo(CreatedTuple).@"struct".fields[0].type);
    try testing.expectEqual(u16, @typeInfo(CreatedTuple).@"struct".fields[1].type);

    const E = enum(u8) { a, _none, b, _ };
    const names = enumFieldNames(E);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("a", names[0]);
    try testing.expectEqualStrings("b", names[1]);

    const U = union(enum) { a: u8, b: u16 };
    try testing.expectEqual(@as(usize, 2), EnumFields(U).len);

    const TaggedU = Tagged(union { a: u8, b: u16 }, enum { a, b });
    const tagged: TaggedU = .{ .a = 3 };
    try testing.expectEqual(@as(u8, 3), tagged.a);

    const UseFields = struct { a: u8, b: u16 };
    useAllFields(UseFields, .{ .a = {}, .b = {} });

    const Struct = struct {
        pub const marker = true;
        x: u32,
    };
    try testing.expect(hasDecl(Struct, "marker"));
    try testing.expect(hasField(Struct, "x"));
    try testing.expect(hasStableMemoryLayout(extern struct { x: u32 }));
    try testing.expect(isSimpleCopyType(?u32));
    try testing.expect(isSimpleEqlType(packed struct(u8) { a: bool, b: bool, rest: u6 }));
}
