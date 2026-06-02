// Copied from bun/src/sql/mysql/protocol/Query.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// COM_QUERY packet writer leaf.

pub const Execute = struct {
    query: []const u8,
    /// Parameter values to bind to the prepared statement
    params: []Data = &[_]Data{},
    /// Types of each parameter in the prepared statement
    param_types: []const Param,

    pub fn deinit(this: *Execute) void {
        for (this.params) |*param| {
            param.deinit();
        }
    }

    pub fn writeInternal(this: *const Execute, comptime Context: type, writer: NewWriter(Context)) !void {
        var packet = try writer.start(0);
        try writer.int1(@intFromEnum(CommandType.COM_QUERY));
        try writer.write(this.query);

        if (this.params.len > 0) {
            try writer.writeNullBitmap(this.params);

            // Always 1. Malformed packet error if not 1
            try writer.int1(1);
            // if 22 chars = u64 + 2 for :p and this should be more than enough
            var param_name_buf: [22]u8 = undefined;
            // Write parameter types
            for (this.param_types, 1..) |param_type, i| {
                debug("New params bind flag {s} unsigned? {}", .{ @tagName(param_type.type), param_type.flags.UNSIGNED });
                try writer.int1(@intFromEnum(param_type.type));
                try writer.int1(if (param_type.flags.UNSIGNED) 0x80 else 0);
                const param_name = std.fmt.bufPrint(&param_name_buf, ":p{d}", .{i}) catch return error.TooManyParameters;
                try writer.writeLengthEncodedString(param_name);
            }

            // Write parameter values
            for (this.params, this.param_types) |*param, param_type| {
                if (param.* == .empty or param_type.type == .MYSQL_TYPE_NULL) continue;

                const value = param.slice();
                debug("Write param type {s} len {d} hex {x}", .{ @tagName(param_type.type), value.len, value });
                if (param_type.type.isBinaryFormatSupported()) {
                    try writer.write(value);
                } else {
                    try writer.writeLengthEncodedString(value);
                }
            }
        }
        try packet.end();
    }

    pub const write = writeWrap(Execute, writeInternal).write;
};

pub fn execute(query: []const u8, writer: anytype) !void {
    var packet = try writer.start(0);
    try writer.int1(@intFromEnum(CommandType.COM_QUERY));
    try writer.write(query);
    try packet.end();
}

const debug = home_rt.Output.scoped(.MySQLQuery, .visible);

const home_rt = @import("home");
const std = @import("std");
const AnyMySQLError = @import("./AnyMySQLError.zig");
const CommandType = @import("./CommandType.zig").CommandType;
const Data = @import("../../shared/Data.zig").Data;
const Param = @import("../MySQLParam.zig").Param;

const NewWriter = @import("./NewWriter.zig").NewWriter;
const writeWrap = @import("./NewWriter.zig").writeWrap;

test "MySQL Query.Execute deinit is safe for empty params" {
    var query = Execute{
        .query = "select 1",
        .param_types = &.{},
    };
    query.deinit();
}

test "MySQL Query exports write entrypoints without instantiating writer body" {
    const testing = std.testing;
    try testing.expect(@typeInfo(@TypeOf(Execute.write)) == .@"fn");
    try testing.expectEqual(@as(u8, 0x03), @intFromEnum(CommandType.COM_QUERY));
}

test "MySQL Query.execute writes a COM_QUERY packet" {
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    const ctx = TestWriter.init(&buf, &len);
    const writer = NewWriter(TestWriter){ .wrapped = ctx };

    try execute("select 1", writer);

    try std.testing.expectEqualSlices(u8, &.{ 9, 0, 0, 0, 0x03, 's', 'e', 'l', 'e', 'c', 't', ' ', '1' }, ctx.slice());
}

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
