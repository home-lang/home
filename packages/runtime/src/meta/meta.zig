pub fn OptionalChild(comptime T: type) type {
    const tyinfo = @typeInfo(T);
    if (tyinfo != .pointer) @compileError("OptionalChild(T) requires that T be a pointer to an optional type.");
    const child = @typeInfo(tyinfo.pointer.child);
    if (child != .optional) @compileError("OptionalChild(T) requires that T be a pointer to an optional type.");
    return child.optional.child;
}

/// Zig 0.17 removed the unified `@typeInfo(T).@"kind".fields` view (now parallel
/// arrays). `fieldsOf` restores the pre-0.17 `[]const Field` shape with the
/// `.name`/`.type`/`.value`/`.is_comptime`/`.alignment` members the copied Bun
/// source relies on, for structs, unions and enums.
pub const Field = struct {
    name: [:0]const u8,
    type: type = void,
    value: comptime_int = 0,
    is_comptime: bool = false,
    /// `null` means "default alignment for the field type" (mirrors the new
    /// `FieldAttributes.@"align"` shape the copied Bun source expects).
    alignment: ?usize = null,
};
pub inline fn fieldsOf(comptime T: type) []const Field {
    comptime {
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                var arr: [s.field_names.len]Field = undefined;
                for (s.field_names, s.field_types, s.field_attrs, &arr) |n, t, a, *e| {
                    e.* = .{ .name = n, .type = t, .is_comptime = a.@"comptime", .alignment = a.@"align" };
                }
                const final = arr;
                return &final;
            },
            .@"union" => |u| {
                var arr: [u.field_names.len]Field = undefined;
                for (u.field_names, u.field_types, u.field_attrs, &arr) |n, t, a, *e| {
                    e.* = .{ .name = n, .type = t, .alignment = a.@"align" };
                }
                const final = arr;
                return &final;
            },
            .@"enum" => |en| {
                var arr: [en.field_names.len]Field = undefined;
                for (en.field_names, en.field_values, &arr) |n, v, *e| {
                    e.* = .{ .name = n, .value = v };
                }
                const final = arr;
                return &final;
            },
            else => @compileError("fieldsOf on unsupported type " ++ @typeName(T)),
        }
    }
}

pub const EnumField = struct { name: [:0]const u8, value: comptime_int };
pub inline fn EnumFields(comptime T: type) []const EnumField {
    const tyinfo = @typeInfo(T);
    const en = switch (tyinfo) {
        .@"union" => @typeInfo(tyinfo.@"union".tag_type.?).@"enum",
        .@"enum" => tyinfo.@"enum",
        else => {
            @compileError("Used `EnumFields(T)` on a type that is not an `enum` or a `union(enum)`");
        },
    };
    comptime {
        var fields: [en.field_names.len]EnumField = undefined;
        for (en.field_names, en.field_values, &fields) |name, value, *f| {
            f.* = .{ .name = name, .value = value };
        }
        const final = fields;
        return &final;
    }
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
    if (maybe.field_names.len != 2) @compileError("Expected the Maybe type to be a union(enum) with two variants");

    if (!std.mem.eql(u8, maybe.field_names[0], "err")) {
        @compileError("Expected the first field of the Maybe type to be \"err\", got: " ++ maybe.field_names[0]);
    }

    if (!std.mem.eql(u8, maybe.field_names[1], "result")) {
        @compileError("Expected the second field of the Maybe type to be \"result\"" ++ maybe.field_names[1]);
    }

    return maybe.field_types[1];
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
            const src = std.meta.fieldNames(Type);
            var filtered_names: [src.len][]const u8 = undefined;
            for (src, &filtered_names) |s, *d| d.* = s;
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
        for (std.meta.fieldNames(Container), std.meta.fieldTypes(Container)) |fname, ftype| {
            if (ftype == T) {
                @compileError(std.fmt.comptimePrint(typeName(T) ++ " field \"" ++ fname ++ "\" not allowed in " ++ typeName(Container), .{}));
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
            if (tyinfo.@"enum".mode == .exhaustive) return false;
            return hasStableMemoryLayout(tyinfo.@"enum".tag_type);
        },
        .@"struct" => switch (tyinfo.@"struct".layout) {
            .auto => {
                inline for (tyinfo.@"struct".field_types) |FieldType| {
                    if (!hasStableMemoryLayout(FieldType)) return false;
                }
                return true;
            },
            .@"extern" => true,
            .@"packed" => false,
        },
        .@"union" => switch (tyinfo.@"union".layout) {
            .auto => {
                if (tyinfo.@"union".tag_type == null or !hasStableMemoryLayout(tyinfo.@"union".tag_type.?)) return false;

                inline for (tyinfo.@"union".field_types) |FieldType| {
                    if (!hasStableMemoryLayout(FieldType)) return false;
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
            inline for (tyinfo.@"struct".field_types) |FieldType| {
                if (!isSimpleCopyType(FieldType)) return false;
            }
            return true;
        },
        .@"union" => {
            inline for (tyinfo.@"union".field_types) |FieldType| {
                if (!isSimpleCopyType(FieldType)) return false;
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
        const st = tyinfo.@"struct";

        // Looks like array list
        if (st.field_names.len == 2 and
            std.mem.eql(u8, st.field_names[0], "items") and
            std.mem.eql(u8, st.field_names[1], "capacity"))
            return .{ .list = .array_list, .child = std.meta.Child(st.field_types[0]) };

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
    const n = info.field_names.len;
    return @Union(.auto, T, info.field_names[0..n], info.field_types[0..n], info.field_attrs[0..n]);
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
    const info = @typeInfo(T).@"struct";
    const n = info.field_names.len;
    var field_types: [n]type = undefined;
    var field_attrs: [n]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (info.field_attrs, &field_types, &field_attrs) |src, *FieldType, *attrs| {
        FieldType.* = void;
        attrs.* = .{
            .@"comptime" = src.@"comptime",
            .@"align" = src.@"align",
            .default_value_ptr = null,
        };
    }
    return @Struct(.auto, null, info.field_names[0..n], &field_types, &field_attrs);
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
    try testing.expectEqual(u8, @typeInfo(CreatedTuple).@"struct".field_types[0]);
    try testing.expectEqual(u16, @typeInfo(CreatedTuple).@"struct".field_types[1]);

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
