//! Private inherited-fd supervision records. Consumer programs never inherit
//! this descriptor. All integers are little-endian; status is an exit code or
//! positive errno. This is control framing, not a media or IPC value protocol.
const std = @import("std");
pub const size = 32;
pub const Kind = enum(u32) { ready = 1, result = 2, problem = 3 };
pub const Message = struct { kind: Kind, status: u32 = 0, supervisor: u32, consumer: u32 };
pub fn encode(value: Message) ![size]u8 {
    if (value.supervisor == 0 or value.supervisor > std.math.maxInt(i32) or value.consumer > std.math.maxInt(i32) or
        (value.kind != .problem and value.consumer == 0) or
        (value.kind == .ready and value.status != 0) or
        (value.kind == .result and value.status > 255) or
        (value.kind == .problem and (value.status == 0 or value.status > 65535))) return error.InvalidMessage;
    var out: [size]u8 = @splat(0);
    @memcpy(out[0..4], "ZCO1");
    std.mem.writeInt(u32, out[4..8], @intFromEnum(value.kind), .little);
    std.mem.writeInt(u32, out[8..12], value.status, .little);
    std.mem.writeInt(u64, out[16..24], value.supervisor, .little);
    std.mem.writeInt(u64, out[24..32], value.consumer, .little);
    return out;
}
pub fn decode(input: []const u8) !Message {
    if (input.len != size or !std.mem.eql(u8, input[0..4], "ZCO1") or std.mem.readInt(u32, input[12..16], .little) != 0) return error.InvalidMessage;
    const supervisor = std.mem.readInt(u64, input[16..24], .little);
    const consumer = std.mem.readInt(u64, input[24..32], .little);
    if (supervisor > std.math.maxInt(u32) or consumer > std.math.maxInt(u32)) return error.InvalidMessage;
    const kind: Kind = switch (std.mem.readInt(u32, input[4..8], .little)) {
        1 => .ready,
        2 => .result,
        3 => .problem,
        else => return error.InvalidMessage,
    };
    const value = Message{ .kind = kind, .status = std.mem.readInt(u32, input[8..12], .little), .supervisor = @intCast(supervisor), .consumer = @intCast(consumer) };
    _ = try encode(value);
    return value;
}
test "process control records have exact independent bytes and reject every truncation" {
    const message = Message{ .kind = .ready, .supervisor = 123, .consumer = 456 };
    const bytes = try encode(message);
    try std.testing.expectEqualSlices(u8, &.{ 'Z', 'C', 'O', '1', 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 123, 0, 0, 0, 0, 0, 0, 0, 200, 1, 0, 0, 0, 0, 0, 0 }, &bytes);
    try std.testing.expectEqualDeep(message, try decode(&bytes));
    for (0..size) |length| try std.testing.expectError(error.InvalidMessage, decode(bytes[0..length]));
    var bad = bytes;
    for ([_]usize{ 0, 7, 8, 12, 20, 28 }) |index| {
        bad = bytes;
        bad[index] = 255;
        try std.testing.expectError(error.InvalidMessage, decode(&bad));
    }
    _ = try decode(&(try encode(.{ .kind = .result, .status = 255, .supervisor = 1, .consumer = 2 })));
    _ = try decode(&(try encode(.{ .kind = .problem, .status = 2, .supervisor = 1, .consumer = 0 })));
}
