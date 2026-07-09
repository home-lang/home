// Copied from bun/src/bun_core/util.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6.
//
// Imports rewritten:
//   * `@import("bun")` → `@import("home")`.
//   * `bun.trait.{isContainer, isIndexable, isSlice, isConstPtr}` →
//     `home_rt.meta.traits.{isContainer, isIndexable, isSlice, isConstPtr}`.
//
// Zig 0.17 compat fixes (upstream targets 0.11-era stdlib):
//   * `field.field_type` → `field.type` (stdlib rename).
//   * Reference to the removed `std.meta.trait.isSlice` replaced with
//     `home_rt.meta.traits.isSlice`.

// Things that maybe should go in Zig standard library at some point

pub fn Key(comptime Map: type) type {
    return FieldType(Map.KV, "key").?;
}

pub fn Value(comptime Map: type) type {
    return FieldType(Map.KV, "value").?;
}

pub fn fromEntries(
    comptime Map: type,
    allocator: std.mem.Allocator,
    comptime EntryType: type,
    entries: EntryType,
) !Map {
    var map: Map = undefined;
    if (@hasField(Map, "allocator")) {
        map = Map.init(allocator);
    } else {
        map = Map{};
    }

    if (comptime home_rt.meta.traits.isIndexable(EntryType)) {
        if (comptime !needsAllocator(Map.ensureUnusedCapacity)) {
            try map.ensureUnusedCapacity(entries.len);
        } else {
            try map.ensureUnusedCapacity(allocator, entries.len);
        }

        inline for (entries) |entry| {
            map.putAssumeCapacity(entry[0], entry[1]);
        }

        return map;
    } else if (std.meta.hasFn(EntryType, "count")) {
        if (comptime !needsAllocator(Map.ensureUnusedCapacity)) {
            try map.ensureUnusedCapacity(entries.count());
        } else {
            try map.ensureUnusedCapacity(allocator, entries.count());
        }

        if (comptime @hasDecl(EntryType, "iterator")) {
            var iter = entries.iterator();
            while (iter.next()) |entry| {
                map.putAssumeCapacity(entry[0], entry[1]);
            }

            return map;
        }
    } else if (comptime home_rt.meta.traits.isContainer(EntryType) and std.meta.fieldNames(EntryType).len > 0) {
        if (comptime !needsAllocator(Map.ensureUnusedCapacity)) {
            try map.ensureUnusedCapacity(std.meta.fieldNames(EntryType).len);
        } else {
            try map.ensureUnusedCapacity(allocator, std.meta.fieldNames(EntryType).len);
        }

        inline for (comptime std.meta.fieldNames(@TypeOf(EntryType))) |entry| {
            map.putAssumeCapacity(entry[0], entry[1]);
        }

        return map;
    } else if (comptime home_rt.meta.traits.isConstPtr(EntryType) and std.meta.fieldNames(std.meta.Child(EntryType)).len > 0) {
        if (comptime !needsAllocator(Map.ensureUnusedCapacity)) {
            try map.ensureUnusedCapacity(std.meta.fieldNames(std.meta.Child(EntryType)).len);
        } else {
            try map.ensureUnusedCapacity(allocator, std.meta.fieldNames(std.meta.Child(EntryType)).len);
        }

        inline for (entries) |entry| {
            map.putAssumeCapacity(entry[0], entry[1]);
        }

        return map;
    }

    @compileError("Cannot construct Map from entries of type " ++ @typeName(EntryType));
}

pub fn fromMapLike(
    comptime Map: type,
    allocator: std.mem.Allocator,
    entries: []const struct { @FieldType(Map.KV, "key"), @FieldType(Map.KV, "value") },
) !Map {
    var map: Map = undefined;
    if (comptime @hasField(Map, "allocator")) {
        map = Map.init(allocator);
    } else {
        map = Map{};
    }

    try map.ensureUnusedCapacity(allocator, entries.len);

    for (entries) |entry| {
        map.putAssumeCapacityNoClobber(entry[0], entry[1]);
    }

    return map;
}

pub fn FieldType(comptime Map: type, comptime name: []const u8) ?type {
    const i = std.meta.fieldIndex(Map, name) orelse return null;
    const field = bun.meta.fieldsOf(Map)[i];
    // Zig 0.17: `field_type` was renamed to `type`.
    return field.type;
}

pub fn Of(comptime ArrayLike: type) type {
    if (home_rt.meta.traits.isSlice(ArrayLike)) {
        return std.meta.Child(ArrayLike);
    }

    if (comptime @hasDecl(ArrayLike, "Elem")) {
        return ArrayLike.Elem;
    }

    if (comptime @hasField(ArrayLike, "items")) {
        return std.meta.Child(FieldType(ArrayLike, "items").?);
    }

    if (comptime @hasField(ArrayLike, "ptr")) {
        return std.meta.Child(FieldType(ArrayLike, "ptr").?);
    }

    @compileError("Cannot infer type within " ++ @typeName(ArrayLike));
}

pub inline fn from(
    comptime Array: type,
    allocator: std.mem.Allocator,
    default: anytype,
) !Array {
    const DefaultType = @TypeOf(default);
    if (comptime home_rt.meta.traits.isSlice(DefaultType)) {
        return fromSlice(Array, allocator, DefaultType, default);
    }

    if (comptime home_rt.meta.traits.isContainer(DefaultType)) {
        if (comptime home_rt.meta.traits.isContainer(Array) and @hasDecl(DefaultType, "put")) {
            return fromMapLike(Array, allocator, default);
        }

        if (comptime @hasField(DefaultType, "items")) {
            if (Of(FieldType(DefaultType, "items").?) == Of(Array)) {
                return fromSlice(Array, allocator, @TypeOf(default.items), default.items);
            }
        }
    }

    if (comptime home_rt.meta.traits.isContainer(Array) and @hasDecl(Array, "put")) {
        if (comptime home_rt.meta.traits.isConstPtr(DefaultType) and std.meta.fieldNames(std.meta.Child(DefaultType)).len > 0) {
            return fromEntries(Array, allocator, @TypeOf(default.*), default.*);
        }
        return fromEntries(Array, allocator, DefaultType, default);
    }

    if (comptime @typeInfo(DefaultType) == .@"struct") {
        return fromSlice(Array, allocator, DefaultType, default);
    }

    if (comptime @typeInfo(DefaultType) == .array) {
        return fromSlice(Array, allocator, []const Of(Array), @as([]const Of(Array), &default));
    }

    return fromSlice(Array, allocator, []const Of(Array), @as([]const Of(Array), default));
}

pub fn fromSlice(
    comptime Array: type,
    allocator: std.mem.Allocator,
    comptime DefaultType: type,
    default: DefaultType,
) !Array {
    var map: Array = undefined;
    if (comptime home_rt.meta.traits.isSlice(Array)) {} else if (comptime @hasField(Array, "allocator")) {
        map = Array.init(allocator);
    } else {
        map = Array{};
    }

    // is it a MultiArrayList?
    if (comptime !home_rt.meta.traits.isSlice(Array) and @hasField(Array, "bytes")) {
        try map.ensureUnusedCapacity(allocator, default.len);
        for (default) |elem| {
            map.appendAssumeCapacity(elem);
        }

        return map;
    } else {
        var slice: []Of(Array) = undefined;
        if (comptime !home_rt.meta.traits.isSlice(Array)) {
            // is it an ArrayList with an allocator?
            if (comptime !needsAllocator(Array.ensureUnusedCapacity)) {
                try map.ensureUnusedCapacity(default.len);
                // is it an ArrayList without an allocator?
            } else {
                try map.ensureUnusedCapacity(allocator, default.len);
            }
            if (comptime @hasField(Array, "items")) {
                map.items.len = default.len;
                slice = map.items;
            } else if (comptime @hasField(Array, "len")) {
                map.len = @as(u32, @intCast(default.len));
                slice = map.slice();
            } else {
                @compileError("Cannot set length of " ++ @typeName(Array));
            }
            // Upstream branch on `std.meta.trait.isSlice(Array)` (removed
            // in Zig 0.17) and on `@hasField(map, "ptr")` retained verbatim.
        } else if (comptime home_rt.meta.traits.isSlice(Array)) {
            slice = try allocator.alloc(Of(Array), default.len);
        } else if (comptime @hasField(Array, "ptr")) {
            slice = try allocator.alloc(Of(Array), default.len);
            map = .{
                .ptr = slice.ptr,
                .len = @as(u32, @truncate(default.len)),
                .cap = @as(u32, @truncate(default.len)),
            };
        }

        const in = std.mem.sliceAsBytes(default);
        var out = std.mem.sliceAsBytes(slice);
        @memcpy(out[0..in.len], in);

        if (home_rt.meta.traits.isSlice(Array)) {
            return slice;
        }

        return map;
    }
}

fn needsAllocator(comptime Fn: anytype) bool {
    return std.meta.fieldNames(std.meta.ArgsTuple(@TypeOf(Fn))).len > 2;
}

test "util: Of returns the slice child type" {
    try std.testing.expectEqual(u8, Of([]const u8));
    try std.testing.expectEqual(u32, Of([]u32));
}

test "util: FieldType locates a named struct field" {
    const S = struct {
        a: u32,
        b: []const u8,
    };
    try std.testing.expectEqual(u32, FieldType(S, "a").?);
    try std.testing.expectEqual([]const u8, FieldType(S, "b").?);
    try std.testing.expect(FieldType(S, "missing") == null);
}

test "util: needsAllocator distinguishes ArrayList styles" {
    // Two-arg fn -> ensureUnusedCapacity(self, n) -> needs no allocator.
    const NoAllocCtx = struct {
        pub fn ensureUnusedCapacity(self: *@This(), n: usize) !void {
            _ = self;
            _ = n;
        }
    };
    try std.testing.expect(!needsAllocator(NoAllocCtx.ensureUnusedCapacity));

    // Three-arg fn -> ensureUnusedCapacity(self, allocator, n) -> needs allocator.
    const WithAllocCtx = struct {
        pub fn ensureUnusedCapacity(self: *@This(), allocator: std.mem.Allocator, n: usize) !void {
            _ = self;
            _ = allocator;
            _ = n;
        }
    };
    try std.testing.expect(needsAllocator(WithAllocCtx.ensureUnusedCapacity));
}

const home_rt = @import("home");
const std = @import("std");
const bun = @import("bun");
