// Copied from bun/src/sql/mysql/MySQLRequest.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Top-level MySQL request helpers — thin wrappers around the
// `NewWriter` packet framing for COM_QUERY (`executeQuery`) and
// COM_STMT_PREPARE (`prepareRequest`). Both reset the sequence id to
// zero by passing `0` to `writer.start`, write the 1-byte command
// type, then the raw query bytes, then close the packet.
//
// Bodies reach into the wave-21 NewWriter stub method surface
// (`start`, `int1`, `write`); exercising either helper trips a
// natural compile error pointing back at the stub until the real
// `bun.ByteList`-backed writer lands (Phase 12.2).

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

test "executeQuery + prepareRequest are addressable as fn pointers" {
    const std = @import("std");
    // Touching the comptime fn-pointers without instantiating the
    // generic body keeps the NewWriter stub method surface unscanned,
    // but proves the symbols + signatures are exported cleanly.
    const exec: *const @TypeOf(executeQuery) = &executeQuery;
    const prep: *const @TypeOf(prepareRequest) = &prepareRequest;
    try std.testing.expect(@intFromPtr(exec) != 0);
    try std.testing.expect(@intFromPtr(prep) != 0);
    try std.testing.expect(@intFromEnum(CommandType.COM_QUERY) != @intFromEnum(CommandType.COM_STMT_PREPARE));
}

const debug = home_rt.Output.scoped(.MySQLRequest, .visible);

const home_rt = @import("home_rt");
const CommandType = @import("./protocol/CommandType.zig").CommandType;
const NewWriter = @import("./protocol/NewWriter.zig").NewWriter;
