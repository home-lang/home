fn deinitImpl(comptime Union: type, value: *Union) void {
    switch (std.meta.activeTag(value.*)) {
        inline else => |tag| deinitValue(&@field(value, @tagName(tag))),
    }
    value.* = undefined;
}

fn deinitValue(ptr_or_slice: anytype) void {
    const PtrType = @TypeOf(ptr_or_slice);
    const ptr_info = @typeInfo(PtrType);
    if (ptr_info != .pointer) @compileError("deinitValue expects a pointer or slice");

    switch (comptime ptr_info.pointer.size) {
        .slice => {
            for (ptr_or_slice) |*elem| {
                deinitValue(elem);
            }
            return;
        },
        .one => {},
        else => @compileError("unsupported pointer type: " ++ @typeName(PtrType)),
    }

    const Child = ptr_info.pointer.child;
    const mutable = !ptr_info.pointer.attrs.@"const";
    defer {
        if (comptime mutable) {
            ptr_or_slice.* = undefined;
        }
    }

    switch (comptime @typeInfo(Child)) {
        .void, .bool, .int, .float, .pointer, .comptime_float, .comptime_int => return,
        .undefined, .null, .error_set, .@"enum", .vector => return,
        .array => {
            for (ptr_or_slice) |*elem| {
                deinitValue(elem);
            }
            return;
        },
        .optional => {
            if (ptr_or_slice.*) |*payload| {
                deinitValue(payload);
            }
            return;
        },
        .error_union => {
            if (ptr_or_slice.*) |*payload| {
                deinitValue(payload);
            } else |_| {}
            return;
        },
        .@"struct" => {},
        .@"union" => |u| {
            if (comptime u.tag_type == null) {
                @compileError("cannot deinit an untagged union: " ++ @typeName(Child));
            }
        },
        .type, .noreturn, .@"fn", .@"opaque", .frame, .@"anyframe", .enum_literal => {
            @compileError("unsupported type for deinit: " ++ @typeName(Child));
        },
    }

    if (comptime hasCallableDeinit(Child)) {
        ptr_or_slice.deinit();
    }
}

fn hasCallableDeinit(comptime T: type) bool {
    if (!@hasDecl(T, "deinit")) return false;
    return switch (@TypeOf(T.deinit)) {
        type => T.deinit != void,
        void => false,
        else => true,
    };
}

/// Creates a tagged union with fields corresponding to `field_types`. The fields are named
/// @"0", @"1", @"2", etc.
pub fn TaggedUnion(comptime field_types: []const type) type {
    // Types created with @Type can't contain decls, so in order to have a `deinit` method, we
    // have to do it this way...
    return switch (comptime field_types.len) {
        0 => @compileError("cannot create an empty tagged union"),
        1 => union(enum) {
            @"0": field_types[0],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        2 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        3 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        4 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        5 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        6 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        7 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        8 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            @"7": field_types[7],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        9 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            @"7": field_types[7],
            @"8": field_types[8],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        10 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            @"7": field_types[7],
            @"8": field_types[8],
            @"9": field_types[9],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        11 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            @"7": field_types[7],
            @"8": field_types[8],
            @"9": field_types[9],
            @"10": field_types[10],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        12 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            @"7": field_types[7],
            @"8": field_types[8],
            @"9": field_types[9],
            @"10": field_types[10],
            @"11": field_types[11],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        13 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            @"7": field_types[7],
            @"8": field_types[8],
            @"9": field_types[9],
            @"10": field_types[10],
            @"11": field_types[11],
            @"12": field_types[12],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        14 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            @"7": field_types[7],
            @"8": field_types[8],
            @"9": field_types[9],
            @"10": field_types[10],
            @"11": field_types[11],
            @"12": field_types[12],
            @"13": field_types[13],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        15 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            @"7": field_types[7],
            @"8": field_types[8],
            @"9": field_types[9],
            @"10": field_types[10],
            @"11": field_types[11],
            @"12": field_types[12],
            @"13": field_types[13],
            @"14": field_types[14],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        16 => union(enum) {
            @"0": field_types[0],
            @"1": field_types[1],
            @"2": field_types[2],
            @"3": field_types[3],
            @"4": field_types[4],
            @"5": field_types[5],
            @"6": field_types[6],
            @"7": field_types[7],
            @"8": field_types[8],
            @"9": field_types[9],
            @"10": field_types[10],
            @"11": field_types[11],
            @"12": field_types[12],
            @"13": field_types[13],
            @"14": field_types[14],
            @"15": field_types[15],
            pub fn deinit(self: *@This()) void {
                deinitImpl(@This(), self);
            }
        },
        else => @compileError("too many union fields"),
    };
}

const std = @import("std");
const bun = @import("bun");

test "TaggedUnion constructs fields and deinitializes active payload" {
    const testing = std.testing;

    const Payload = struct {
        did_deinit: *bool,

        pub fn deinit(self: *@This()) void {
            self.did_deinit.* = true;
        }
    };

    const U = TaggedUnion(&.{ u8, Payload });
    var did_deinit = false;
    var value: U = .{ .@"1" = .{ .did_deinit = &did_deinit } };

    try testing.expectEqual(@as(usize, 2), @typeInfo(U).@"union".field_names.len);
    try testing.expectEqualStrings("0", bun.meta.fieldsOf(U)[0].name);
    try testing.expectEqual(@as(@typeInfo(U).@"union".tag_type.?, .@"1"), std.meta.activeTag(value));

    value.deinit();
    try testing.expect(did_deinit);
}
