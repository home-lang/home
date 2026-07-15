// Copied from bun/src/sql/mysql/protocol/AuthSwitchRequest.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// MySQL Authentication Switch Request packet decoder (header byte 0xfe).
// Splits the remaining packet bytes at the first NUL into (plugin_name,
// plugin_data). The body uses `bun.strings.indexOfChar` and `bun.assert`;
// rewritten to `home_rt.strings.indexOfChar` / `home_rt.assert`. The
// `NewReader` and `decoderWrap` factories live in this directory's
// concrete `NewReader.zig`; the decode test below exercises that path.

const AuthSwitchRequest = @This();
header: u8 = 0xfe,
plugin_name: Data = .{ .empty = {} },
plugin_data: Data = .{ .empty = {} },
packet_size: u24,

pub fn deinit(this: *AuthSwitchRequest) void {
    this.plugin_name.deinit();
    this.plugin_data.deinit();
}

pub fn decodeInternal(this: *AuthSwitchRequest, comptime Context: type, reader: NewReader(Context)) !void {
    this.header = try reader.int(u8);
    if (this.header != 0xfe) {
        return error.InvalidAuthSwitchRequest;
    }

    // `packet_size` counts the header byte we just consumed. A malformed packet
    // reporting size 0 would underflow the u24 to 0xFFFFFF and force a 16MB
    // over-read; reject it before subtracting.
    if (this.packet_size == 0) {
        return error.InvalidAuthSwitchRequest;
    }
    const remaining = try reader.read(this.packet_size - 1);
    const remaining_slice = remaining.slice();
    home_rt.assert(remaining == .temporary);

    if (home_rt.strings.indexOfChar(remaining_slice, 0)) |zero| {
        // EOF String
        this.plugin_name = .{
            .temporary = remaining_slice[0..zero],
        };
        // End Of The Packet String
        this.plugin_data = .{
            .temporary = remaining_slice[zero + 1 ..],
        };
        return;
    }
    return error.InvalidAuthSwitchRequest;
}

pub const decode = decoderWrap(AuthSwitchRequest, decodeInternal).decode;

const home_rt = @import("home");
const Data = @import("../../shared/Data.zig").Data;

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;

test "AuthSwitchRequest defaults expose 0xfe header + empty plugin payload" {
    const std = @import("std");
    const req = AuthSwitchRequest{ .packet_size = 0 };
    try std.testing.expectEqual(@as(u8, 0xfe), req.header);
    try std.testing.expect(req.plugin_name == .empty);
    try std.testing.expect(req.plugin_data == .empty);
}

test "AuthSwitchRequest decodes plugin name and data" {
    const std = @import("std");
    const packet = "\xfemysql_native_password\x00salt";
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(packet, &offset, &message_start);

    var req = AuthSwitchRequest{ .packet_size = packet.len };
    defer req.deinit();
    try req.decode(reader);

    try std.testing.expectEqual(@as(u8, 0xfe), req.header);
    try std.testing.expectEqualStrings("mysql_native_password", req.plugin_name.slice());
    try std.testing.expectEqualStrings("salt", req.plugin_data.slice());
    try std.testing.expectEqual(@as(usize, packet.len), offset);
}

const StackReader = @import("./StackReader.zig");
