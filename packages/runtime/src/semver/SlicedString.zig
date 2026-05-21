const SlicedString = @This();

buf: string,
slice: string,

pub inline fn init(buf: string, slice: string) SlicedString {
    if (Environment.allow_assert) {
        std.debug.assert(isSliceInBuffer(slice, buf));
    }
    return .{ .buf = buf, .slice = slice };
}

pub inline fn external(this: SlicedString) ExternalString {
    if (Environment.allow_assert) {
        std.debug.assert(isSliceInBuffer(this.slice, this.buf));
    }
    return ExternalString.init(this.buf, this.slice, String.stringHash(this.slice));
}

pub inline fn value(this: SlicedString) String {
    if (Environment.allow_assert) {
        std.debug.assert(isSliceInBuffer(this.slice, this.buf));
    }
    return String.init(this.buf, this.slice);
}

pub inline fn sub(this: SlicedString, input: string) SlicedString {
    if (Environment.allow_assert) {
        std.debug.assert(isSliceInBuffer(input, this.buf));
    }
    return .{ .buf = this.buf, .slice = input };
}

inline fn isSliceInBuffer(slice: string, buf: string) bool {
    if (slice.len == 0) return true;
    const buf_start = @intFromPtr(buf.ptr);
    const buf_end = buf_start + buf.len;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    return slice_start >= buf_start and slice_end <= buf_end;
}

const string = []const u8;

const std = @import("std");
const Environment = @import("shim.zig").Environment;
const ExternalString = @import("ExternalString.zig").ExternalString;
const String = @import("SemverString.zig").String;

