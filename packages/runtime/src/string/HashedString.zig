// Ported from bun/src/string/HashedString.zig at pinned SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6.
//
// Wave-15 Tier-1 grinder copy. `bun.hash` re-exports `home_rt.hash`
// (the Wyhash wrapper we added to the aggregator alongside this port).

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
            // Length + hash then an actual byte compare: a hash collision must
            // not make two distinct strings compare equal (key confusion).
            return @as(usize, this.len) == other.len and
                @as(u32, @truncate(home_rt.hash(other[0..other.len]))) == this.hash and
                std.mem.eql(u8, this.str(), other[0..other.len]);
        },
    }
}

pub fn str(this: HashedString) []const u8 {
    return this.ptr[0..this.len];
}

const home_rt = @import("home");

test "HashedString: init + str round-trip" {
    const s = HashedString.init("hello");
    try std.testing.expectEqual(@as(u32, 5), s.len);
    try std.testing.expectEqualStrings("hello", s.str());
    try std.testing.expect(s.hash != 0);
}

test "HashedString: eql matches like-content strings" {
    const a = HashedString.init("home");
    const b = HashedString.init("home");
    const c = HashedString.init("rust");
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "HashedString: eql against raw slice" {
    const a = HashedString.init("home");
    try std.testing.expect(a.eql("home"));
    try std.testing.expect(!a.eql("rust"));
}

test "HashedString: initNoHash leaves hash at 0" {
    const s = HashedString.initNoHash("hello");
    try std.testing.expectEqual(@as(u32, 0), s.hash);
    try std.testing.expectEqualStrings("hello", s.str());
}

const std = @import("std");
