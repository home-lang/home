// Copied from bun/src/sql/postgres/protocol/ParameterDescription.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Postgres extended-query ParameterDescription ('t') backend packet.
// Carries the OID for each `$N` parameter the server has bound to a
// prepared statement. Imports rewritten:
//   `@import("bun")` → `@import("home_rt")` (bun.default_allocator
//   becomes home_rt.default_allocator). The decoder body reaches into
//   the wave-16 NewReader stub method surface (reader.length / .short /
//   .read) and trips a natural compile error until the real reader
//   lands (Phase 12.2).

const ParameterDescription = @This();

parameters: []int4 = &[_]int4{},

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    var remaining_bytes = try reader.length();
    remaining_bytes -|= 4;

    const count = try reader.short();
    const parameters = try home_rt.default_allocator.alloc(int4, @intCast(@max(count, 0)));

    var data = try reader.read(@as(usize, @intCast(@max(count, 0))) * @sizeOf((int4)));
    defer data.deinit();
    const input_params: []align(1) const int4 = toInt32Slice(int4, data.slice());
    for (input_params, parameters) |src, *dest| {
        dest.* = @byteSwap(src);
    }

    this.* = .{
        .parameters = parameters,
    };
}

pub const decode = DecoderWrap(ParameterDescription, decodeInternal).decode;

// workaround for zig compiler TODO
fn toInt32Slice(comptime Int: type, slice: []const u8) []align(1) const Int {
    return @as([*]align(1) const Int, @ptrCast(slice.ptr))[0 .. slice.len / @sizeOf((Int))];
}

test "ParameterDescription defaults to an empty parameter list" {
    const std_local = @import("std");
    const pd: ParameterDescription = .{};
    try std_local.testing.expectEqual(@as(usize, 0), pd.parameters.len);
}

test "ParameterDescription toInt32Slice big-endian round-trip" {
    const std_local = @import("std");
    // Two big-endian int4 values 0x00000001 and 0x00000002.
    const bytes: [8]u8 = .{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02 };
    const ints = toInt32Slice(int4, bytes[0..]);
    try std_local.testing.expectEqual(@as(usize, 2), ints.len);
    try std_local.testing.expectEqual(@as(int4, @byteSwap(@as(int4, 0x00000001))), ints[0]);
}

const home_rt = @import("home_rt");
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;

const types = @import("../types/int_types.zig");
const int4 = types.int4;
