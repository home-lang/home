// Copied from bun/src/string/HashedString.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Wraps a borrowed slice with a precomputed 32-bit Wyhash digest so
// repeated equality checks short-circuit on the hash. Used upstream as
// a key type in `bun.StringHashMap`-flavored maps where the same key
// gets compared many times (e.g. CSS selector identifiers).
//
// Imports rewritten: `@import("bun")` → `@import("home_rt")`,
// `bun.hash` → `home_rt.hash` (Wyhash with seed 0, identical formula).
// No JSC bridge.

const HashedString = @This();

ptr: [*]const u8,
len: u32,
hash: u32,

pub const empty = HashedString{ .ptr = @as([*]const u8, @ptrFromInt(0xDEADBEEF)), .len = 0, .hash = 0 };

pub fn init(buf: []const u8) HashedString {
    return HashedString{
        .ptr = buf.ptr,
        .len = @as(u32, @truncate(buf.len)),
        .hash = @as(u32, @truncate(home_rt.hash(buf))),
    };
}

pub fn initNoHash(buf: []const u8) HashedString {
    return HashedString{
        .ptr = buf.ptr,
        .len = @as(u32, @truncate(buf.len)),
        .hash = 0,
    };
}

pub fn eql(this: HashedString, other: anytype) bool {
    return Eql(this, @TypeOf(other), other);
}

fn Eql(this: HashedString, comptime Other: type, other: Other) bool {
    switch (comptime Other) {
        HashedString, *HashedString, *const HashedString => {
            return ((@max(this.hash, other.hash) > 0 and this.hash == other.hash) or (this.ptr == other.ptr)) and this.len == other.len;
        },
        else => {
            return @as(usize, this.len) == other.len and @as(u32, @truncate(home_rt.hash(other[0..other.len]))) == this.hash;
        },
    }
}

pub fn str(this: HashedString) []const u8 {
    return this.ptr[0..this.len];
}

const home_rt = @import("home_rt");

const std = @import("std");

test "HashedString: init round-trips slice and seeds the hash" {
    const s = HashedString.init("hello");
    try std.testing.expectEqualStrings("hello", s.str());
    try std.testing.expectEqual(@as(u32, 5), s.len);
    try std.testing.expect(s.hash != 0);
}

test "HashedString: initNoHash skips digest" {
    const s = HashedString.initNoHash("hello");
    try std.testing.expectEqualStrings("hello", s.str());
    try std.testing.expectEqual(@as(u32, 0), s.hash);
}

test "HashedString: eql self and another with matching hash" {
    const a = HashedString.init("home");
    const b = HashedString.init("home");
    try std.testing.expect(a.eql(b));

    const c = HashedString.init("nope");
    try std.testing.expect(!a.eql(c));
}

test "HashedString: eql against a raw slice" {
    const a = HashedString.init("home");
    try std.testing.expect(a.eql(@as([]const u8, "home")));
    try std.testing.expect(!a.eql(@as([]const u8, "nope")));
}

test "HashedString: empty constant is empty" {
    try std.testing.expectEqual(@as(u32, 0), HashedString.empty.len);
    try std.testing.expectEqual(@as(u32, 0), HashedString.empty.hash);
}
