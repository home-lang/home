// Copied from bun/src/install/ExternalSlice.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../cli/LICENSE.bun.md.
// Imports rewritten:
//   `bun.Environment` / `bun.assert` -> local Debug-mode assert shim
//   `bun.install.PackageNameHash` -> sibling `PackageID.zig`
//   `bun.Semver` -> sibling `../semver/semver.zig`

pub fn ExternalSlice(comptime Type: type) type {
    return extern struct {
        pub const Slice = @This();

        pub const Child: type = Type;

        off: u32 = 0,
        len: u32 = 0,

        pub const invalid: @This() = .{ .off = std.math.maxInt(u32), .len = std.math.maxInt(u32) };

        pub inline fn isInvalid(this: Slice) bool {
            return this.off == std.math.maxInt(u32) and this.len == std.math.maxInt(u32);
        }

        pub inline fn contains(this: Slice, id: u32) bool {
            return id >= this.off and id < (this.len + this.off);
        }

        pub inline fn get(this: Slice, in: []const Type) []const Type {
            if (comptime allow_assert) {
                std.debug.assert(this.off + this.len <= in.len);
            }
            // it should be impossible to address this out of bounds due to the minimum here
            return in.ptr[this.off..@min(in.len, this.off + this.len)];
        }

        pub inline fn mut(this: Slice, in: []Type) []Type {
            if (comptime allow_assert) {
                std.debug.assert(this.off + this.len <= in.len);
            }
            return in.ptr[this.off..@min(in.len, this.off + this.len)];
        }

        pub inline fn begin(this: Slice) u32 {
            return this.off;
        }

        pub inline fn end(this: Slice) u32 {
            return this.off + this.len;
        }

        pub fn init(buf: []const Type, in: []const Type) Slice {
            // if (comptime Environment.allow_assert) {
            //     std.debug.assert(isSliceInBuffer(in, buf));
            // }

            return Slice{
                .off = @as(u32, @truncate((@intFromPtr(in.ptr) - @intFromPtr(buf.ptr)) / @sizeOf(Type))),
                .len = @as(u32, @truncate(in.len)),
            };
        }
    };
}

pub const ExternalStringMap = extern struct {
    name: ExternalStringList = .{},
    value: ExternalStringList = .{},
};

pub const ExternalStringList = ExternalSlice(ExternalString);
pub const ExternalPackageNameHashList = ExternalSlice(PackageNameHash);
pub const VersionSlice = ExternalSlice(Semver.Version);

test "ExternalSlice.init computes offset/length from pointer arithmetic" {
    var buf = [_]u32{ 10, 20, 30, 40, 50 };
    const window = buf[1..4];
    const slice = ExternalSlice(u32).init(&buf, window);
    try std.testing.expectEqual(@as(u32, 1), slice.off);
    try std.testing.expectEqual(@as(u32, 3), slice.len);
    try std.testing.expectEqualSlices(u32, window, slice.get(&buf));
}

test "ExternalSlice.invalid round-trips through isInvalid" {
    const inv = ExternalSlice(u8).invalid;
    try std.testing.expect(inv.isInvalid());
    const ok: ExternalSlice(u8) = .{ .off = 0, .len = 0 };
    try std.testing.expect(!ok.isInvalid());
}

test "ExternalSlice.contains tests inclusive range" {
    const s: ExternalSlice(u8) = .{ .off = 2, .len = 3 }; // covers [2, 5)
    try std.testing.expect(!s.contains(1));
    try std.testing.expect(s.contains(2));
    try std.testing.expect(s.contains(3));
    try std.testing.expect(s.contains(4));
    try std.testing.expect(!s.contains(5));
}

test "ExternalSlice.begin / end report the half-open range" {
    const s: ExternalSlice(u32) = .{ .off = 7, .len = 4 };
    try std.testing.expectEqual(@as(u32, 7), s.begin());
    try std.testing.expectEqual(@as(u32, 11), s.end());
}

test "ExternalSlice.mut returns a mutable view into the buffer" {
    var buf = [_]u8{ 'a', 'b', 'c', 'd' };
    const slice = ExternalSlice(u8).init(&buf, buf[1..3]);
    const mut_view = slice.mut(&buf);
    mut_view[0] = 'Z';
    try std.testing.expectEqual(@as(u8, 'Z'), buf[1]);
}

test "ExternalStringList slices ExternalString buffers" {
    var buf = [_]ExternalString{
        ExternalString.from("alpha"),
        ExternalString.from("beta"),
        ExternalString.from("gamma"),
    };
    const slice = ExternalStringList.init(&buf, buf[1..]);
    try std.testing.expectEqual(@as(u32, 1), slice.off);
    try std.testing.expectEqual(@as(u32, 2), slice.len);
    try std.testing.expectEqualStrings("beta", slice.get(&buf)[0].slice(""));
}

test "ExternalPackageNameHashList slices package name hashes" {
    const buf = [_]PackageNameHash{ 11, 22, 33 };
    const slice = ExternalPackageNameHashList.init(&buf, buf[0..2]);
    try std.testing.expectEqualSlices(PackageNameHash, &.{ 11, 22 }, slice.get(&buf));
}

test "VersionSlice slices semver versions" {
    const buf = [_]Semver.Version{
        .{ .major = 1, .minor = 0, .patch = 0 },
        .{ .major = 2, .minor = 0, .patch = 0 },
    };
    const slice = VersionSlice.init(&buf, buf[1..]);
    try std.testing.expectEqual(@as(u64, 2), slice.get(&buf)[0].major);
}

test "ExternalStringMap defaults to empty name/value lists" {
    const map = ExternalStringMap{};
    try std.testing.expectEqual(@as(u32, 0), map.name.len);
    try std.testing.expectEqual(@as(u32, 0), map.value.len);
}

const std = @import("std");
const allow_assert = @import("builtin").mode == .Debug;
const PackageNameHash = @import("PackageID.zig").PackageNameHash;

const Semver = @import("../semver/semver.zig");
const ExternalString = Semver.ExternalString;
