// Copied from bun/src/sql/mysql/protocol/ErrorPacket.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// MySQL server → client error response packet (`0xff` header). Carries
// the protocol error code, optional `#NNNNN` SQL state + the
// human-readable message. Imports rewritten:
//   - `createMySQLError` / `toJS` JSC-bridge re-exports omitted —
//     re-land in Phase 12.2 once `sql_jsc/mysql/protocol/error_packet_jsc.zig`
//     is brought up.
// Decoder body reaches into the wave-18 NewReader stub method surface
// (reader.int / .read / .skip / .peek); those trip a natural compile
// error if exercised today.

const ErrorPacket = @This();
header: u8 = 0xff,
error_code: u16 = 0,
sql_state_marker: ?u8 = null,
sql_state: ?[5]u8 = null,
error_message: Data = .{ .empty = {} },

pub fn deinit(this: *ErrorPacket) void {
    this.error_message.deinit();
}
pub const MySQLErrorOptions = struct {
    code: []const u8,
    errno: ?u16 = null,
    sqlState: ?[5]u8 = null,
};

// JSC-bridge createMySQLError omitted — Phase 12.2

pub fn decodeInternal(this: *ErrorPacket, comptime Context: type, reader: NewReader(Context)) !void {
    this.header = try reader.int(u8);
    if (this.header != 0xff) {
        return error.InvalidErrorPacket;
    }

    this.error_code = try reader.int(u16);

    // Check if we have a SQL state marker
    const next_byte = try reader.int(u8);
    if (next_byte == '#') {
        this.sql_state_marker = '#';
        var sql_state_data = try reader.read(5);
        defer sql_state_data.deinit();
        this.sql_state = sql_state_data.slice()[0..5].*;
    } else {
        // No SQL state, rewind one byte
        reader.skip(-1);
    }

    // Read the error message (rest of packet)
    this.error_message = try reader.read(reader.peek().len);
}

pub const decode = decoderWrap(ErrorPacket, decodeInternal).decode;

pub fn toJS(_: *const ErrorPacket, _: *@import("home").jsc.JSGlobalObject) @import("home").jsc.JSValue {
    return .zero;
}

test "ErrorPacket defaults match upstream" {
    const std = @import("std");
    var p: ErrorPacket = .{};
    defer p.deinit();
    try std.testing.expectEqual(@as(u8, 0xff), p.header);
    try std.testing.expectEqual(@as(u16, 0), p.error_code);
    try std.testing.expect(p.sql_state_marker == null);
    try std.testing.expect(p.sql_state == null);
    try std.testing.expectEqualStrings("", p.error_message.slice());
}

test "ErrorPacket: MySQLErrorOptions composite carries code+errno+state" {
    const std = @import("std");
    const opts: MySQLErrorOptions = .{
        .code = "ER_BAD_FIELD_ERROR",
        .errno = 1054,
        .sqlState = [_]u8{ '4', '2', 'S', '2', '2' },
    };
    try std.testing.expectEqualStrings("ER_BAD_FIELD_ERROR", opts.code);
    try std.testing.expectEqual(@as(?u16, 1054), opts.errno);
    try std.testing.expectEqualSlices(u8, "42S22", &opts.sqlState.?);
}

const Data = @import("../../shared/Data.zig").Data;

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
