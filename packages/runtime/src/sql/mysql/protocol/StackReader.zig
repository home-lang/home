// Copied from bun/src/sql/mysql/protocol/StackReader.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Zero-copy MySQL wire `Reader` backed by an in-memory byte buffer
// plus two cursor pointers (offset + message_start). Import rewrites:
// `bun.strings.indexOfChar` now routes through `home_rt.strings`.

const StackReader = @This();

buffer: []const u8 = "",
offset: *usize,
message_start: *usize,

pub fn markMessageStart(this: @This()) void {
    this.message_start.* = this.offset.*;
}

pub fn setOffsetFromStart(this: @This(), offset: usize) void {
    this.offset.* = this.message_start.* + offset;
}

pub fn ensureCapacity(this: @This(), length: usize) bool {
    // offset + length can overflow usize on a hostile packet, wrapping small and
    // passing the bounds check; use a checked add so overflow fails closed.
    const end, const overflow = @addWithOverflow(this.offset.*, length);
    if (overflow != 0) return false;
    return this.buffer.len >= end;
}

pub fn init(buffer: []const u8, offset: *usize, message_start: *usize) NewReader(StackReader) {
    return .{
        .wrapped = .{
            .buffer = buffer,
            .offset = offset,
            .message_start = message_start,
        },
    };
}

pub fn peek(this: StackReader) []const u8 {
    return this.buffer[this.offset.*..];
}

pub fn skip(this: StackReader, count: isize) void {
    if (count < 0) {
        const abs_count = @abs(count);
        if (abs_count > this.offset.*) {
            this.offset.* = 0;
            return;
        }
        this.offset.* -= @intCast(abs_count);
        return;
    }

    const ucount: usize = @intCast(count);
    if (this.offset.* + ucount > this.buffer.len) {
        this.offset.* = this.buffer.len;
        return;
    }

    this.offset.* += ucount;
}

pub fn read(this: StackReader, count: usize) AnyMySQLError.Error!Data {
    const offset = this.offset.*;
    if (!this.ensureCapacity(count)) {
        return AnyMySQLError.Error.ShortRead;
    }

    this.skip(@intCast(count));
    return Data{
        .temporary = this.buffer[offset..this.offset.*],
    };
}

pub fn readZ(this: StackReader) AnyMySQLError.Error!Data {
    const remaining = this.peek();
    if (home_rt.strings.indexOfChar(remaining, 0)) |zero| {
        this.skip(@intCast(zero + 1));
        return Data{
            .temporary = remaining[0..zero],
        };
    }

    return error.ShortRead;
}

const home_rt = @import("home");
const AnyMySQLError = @import("./AnyMySQLError.zig");
const Data = @import("../../shared/Data.zig").Data;
const NewReader = @import("./NewReader.zig").NewReader;

test "MySQL StackReader.init wraps the buffer and shared cursors" {
    const std = @import("std");
    var offset: usize = 1;
    var message_start: usize = 0;
    const reader = StackReader.init("abc", &offset, &message_start);

    try std.testing.expectEqualStrings("bc", reader.wrapped.peek());
    reader.wrapped.markMessageStart();
    try std.testing.expectEqual(@as(usize, 1), message_start);
    reader.wrapped.setOffsetFromStart(2);
    try std.testing.expectEqual(@as(usize, 3), offset);
}

test "MySQL StackReader.read returns temporary data and advances offset" {
    const std = @import("std");
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader{
        .buffer = "abcdef",
        .offset = &offset,
        .message_start = &message_start,
    };

    const data = try reader.read(3);
    try std.testing.expectEqualStrings("abc", data.slice());
    try std.testing.expectEqual(@as(usize, 3), offset);
    try std.testing.expectError(AnyMySQLError.Error.ShortRead, reader.read(10));
}

test "MySQL StackReader.readZ splits at NUL and advances past it" {
    const std = @import("std");
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader{
        .buffer = "hello\x00world",
        .offset = &offset,
        .message_start = &message_start,
    };

    const data = try reader.readZ();
    try std.testing.expectEqualStrings("hello", data.slice());
    try std.testing.expectEqual(@as(usize, 6), offset);
    try std.testing.expectEqualStrings("world", reader.peek());
}

test "MySQL StackReader.skip clamps backwards and forwards" {
    const std = @import("std");
    var offset: usize = 3;
    var message_start: usize = 0;
    const reader = StackReader{
        .buffer = "abcdef",
        .offset = &offset,
        .message_start = &message_start,
    };

    reader.skip(-10);
    try std.testing.expectEqual(@as(usize, 0), offset);
    reader.skip(100);
    try std.testing.expectEqual(@as(usize, reader.buffer.len), offset);
}
