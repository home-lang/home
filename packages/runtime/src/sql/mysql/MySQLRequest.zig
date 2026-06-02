// Copied from bun/src/sql/mysql/MySQLRequest.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Top-level MySQL request helpers — thin wrappers around the
// `NewWriter` packet framing for COM_QUERY (`executeQuery`) and
// COM_STMT_PREPARE (`prepareRequest`). Both reset the sequence id to
// zero by passing `0` to `writer.start`, write the 1-byte command
// type, then the raw query bytes, then close the packet.
//
pub fn executeQuery(
    query: []const u8,
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    debug("executeQuery len: {d} {s}", .{ query.len, query });
    // resets the sequence id to zero every time we send a query
    var packet = try writer.start(0);
    try writer.int1(@intFromEnum(CommandType.COM_QUERY));
    try writer.write(query);

    try packet.end();
}

pub fn prepareRequest(
    query: []const u8,
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    debug("prepareRequest {s}", .{query});
    var packet = try writer.start(0);
    try writer.int1(@intFromEnum(CommandType.COM_STMT_PREPARE));
    try writer.write(query);

    try packet.end();
}

test "executeQuery writes a COM_QUERY packet" {
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    const ctx = TestWriter.init(&buf, &len);
    const writer = NewWriter(TestWriter){ .wrapped = ctx };

    try executeQuery("select 1", TestWriter, writer);

    try std.testing.expectEqualSlices(u8, &.{ 9, 0, 0, 0, 0x03, 's', 'e', 'l', 'e', 'c', 't', ' ', '1' }, ctx.slice());
}

test "prepareRequest writes a COM_STMT_PREPARE packet" {
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    const ctx = TestWriter.init(&buf, &len);
    const writer = NewWriter(TestWriter){ .wrapped = ctx };

    try prepareRequest("select 1", TestWriter, writer);

    try std.testing.expectEqualSlices(u8, &.{ 9, 0, 0, 0, 0x16, 's', 'e', 'l', 'e', 'c', 't', ' ', '1' }, ctx.slice());
}

const debug = home_rt.Output.scoped(.MySQLRequest, .visible);

const home_rt = @import("home");
const std = @import("std");
const AnyMySQLError = @import("./protocol/AnyMySQLError.zig");
const CommandType = @import("./protocol/CommandType.zig").CommandType;
const NewWriter = @import("./protocol/NewWriter.zig").NewWriter;

const TestWriter = struct {
    bytes: []u8,
    len: *usize,

    fn init(bytes: []u8, len: *usize) TestWriter {
        len.* = 0;
        return .{ .bytes = bytes, .len = len };
    }

    fn slice(this: TestWriter) []const u8 {
        return this.bytes[0..this.len.*];
    }

    pub fn offset(this: TestWriter) usize {
        return this.len.*;
    }

    pub fn write(this: TestWriter, bytes: []const u8) AnyMySQLError.Error!void {
        if (this.len.* + bytes.len > this.bytes.len) return error.ShortRead;
        @memcpy(this.bytes[this.len.*..][0..bytes.len], bytes);
        this.len.* += bytes.len;
    }

    pub fn pwrite(this: TestWriter, bytes: []const u8, offset_value: usize) AnyMySQLError.Error!void {
        if (offset_value + bytes.len > this.len.*) return error.ShortRead;
        @memcpy(this.bytes[offset_value..][0..bytes.len], bytes);
    }
};
