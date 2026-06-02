// Copied from bun/src/sql/postgres/protocol/StackReader.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Zero-copy postgres-wire `Reader` backed by an in-memory byte buffer
// plus two cursor pointers (offset + message_start). Used when decoding
// already-received bytes without an event-loop pull.

const StackReader = @This();

buffer: []const u8 = "",
offset: *usize,
message_start: *usize,

pub fn markMessageStart(this: @This()) void {
    this.message_start.* = this.offset.*;
}

pub fn ensureLength(this: @This(), length: usize) bool {
    return this.buffer.len >= (this.offset.* + length);
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
pub fn skip(this: StackReader, count: usize) void {
    if (this.offset.* + count > this.buffer.len) {
        this.offset.* = this.buffer.len;
        return;
    }

    this.offset.* += count;
}
pub fn ensureCapacity(this: StackReader, count: usize) bool {
    return this.buffer.len >= (this.offset.* + count);
}
pub fn read(this: StackReader, count: usize) AnyPostgresError!Data {
    const offset = this.offset.*;
    if (!this.ensureCapacity(count)) {
        return error.ShortRead;
    }

    this.skip(count);
    return Data{
        .temporary = this.buffer[offset..this.offset.*],
    };
}
pub fn readZ(this: StackReader) AnyPostgresError!Data {
    const remaining = this.peek();
    if (home_rt.strings.indexOfChar(remaining, 0)) |zero| {
        this.skip(zero + 1);
        return Data{
            .temporary = remaining[0..zero],
        };
    }

    return error.ShortRead;
}

const home_rt = @import("home");
const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;
const Data = @import("../../shared/Data.zig").Data;
const NewReader = @import("./NewReader.zig").NewReader;

test "StackReader.peek + skip + ensureCapacity track cursor against buffer" {
    const std = @import("std");
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader{
        .buffer = "ABCDEF",
        .offset = &offset,
        .message_start = &message_start,
    };

    try std.testing.expectEqualStrings("ABCDEF", reader.peek());
    try std.testing.expect(reader.ensureCapacity(4));
    try std.testing.expect(!reader.ensureCapacity(10));

    reader.skip(2);
    try std.testing.expectEqual(@as(usize, 2), offset);
    try std.testing.expectEqualStrings("CDEF", reader.peek());

    // skip past the end clamps to buffer.len rather than overflowing.
    reader.skip(100);
    try std.testing.expectEqual(@as(usize, reader.buffer.len), offset);
}

test "StackReader.markMessageStart snapshots the current offset" {
    const std = @import("std");
    var offset: usize = 3;
    var message_start: usize = 0;
    const reader = StackReader{
        .buffer = "abcdef",
        .offset = &offset,
        .message_start = &message_start,
    };

    reader.markMessageStart();
    try std.testing.expectEqual(@as(usize, 3), message_start);
}
