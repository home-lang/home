// Ported from bun/src/runtime/shell/RefCountedStr.zig at pinned SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6.
//
// Wave-15 Tier-1 grinder copy. `bun.Output.scoped(...)` replaced by a
// local no-op `debug` stub until `home_rt.Output.scoped` lands.

const RefCountedStr = @This();

refcount: u32 = 1,
len: u32 = 0,
ptr: [*]const u8 = undefined,

/// Stub for `home_rt.Output.scoped(.RefCountedEnvStr, .hidden)`. Real
/// logger is a no-op in non-debug builds anyway; the seam re-attaches
/// when the scoped logger lands in `home_rt.Output`.
fn debug(comptime _: []const u8, _: anytype) void {}

pub fn init(slice: []const u8) *RefCountedStr {
    debug("init: {s}", .{slice});
    const this = home_rt.handleOom(home_rt.default_allocator.create(RefCountedStr));
    this.* = .{
        .refcount = 1,
        .len = @intCast(slice.len),
        .ptr = slice.ptr,
    };
    return this;
}

pub fn byteSlice(this: *RefCountedStr) []const u8 {
    if (this.len == 0) return "";
    return this.ptr[0..this.len];
}

pub fn ref(this: *RefCountedStr) void {
    this.refcount += 1;
}

pub fn deref(this: *RefCountedStr) void {
    this.refcount -= 1;
    if (this.refcount == 0) {
        this.deinit();
    }
}

fn deinit(this: *RefCountedStr) void {
    debug("deinit: {s}", .{this.byteSlice()});
    this.freeStr();
    home_rt.default_allocator.destroy(this);
}

fn freeStr(this: *RefCountedStr) void {
    if (this.len == 0) return;
    home_rt.default_allocator.free(this.ptr[0..this.len]);
}

const home_rt = @import("home_rt");

test "RefCountedStr: init/ref/deref balances refcount" {
    // The string buffer must be owned by the same allocator that
    // `freeStr` will release through.
    const owned = try home_rt.default_allocator.dupe(u8, "hello");
    var str = RefCountedStr.init(owned);
    try std.testing.expectEqual(@as(u32, 1), str.refcount);
    try std.testing.expectEqualStrings("hello", str.byteSlice());

    str.ref();
    try std.testing.expectEqual(@as(u32, 2), str.refcount);

    str.deref();
    try std.testing.expectEqual(@as(u32, 1), str.refcount);

    // Final deref frees both the struct and the buffer.
    str.deref();
}

test "RefCountedStr: empty slice byteSlice returns empty string" {
    var str = RefCountedStr.init("");
    defer str.deref();
    try std.testing.expectEqual(@as(u32, 0), str.len);
    try std.testing.expectEqualStrings("", str.byteSlice());
}

const std = @import("std");
