//! Standalone adapter test; link native_encoder.c with system x264/x265.
const std = @import("std");
const native = @import("encoder");
fn observe(packet: native.Packet, codec: u32, seen: *[8]bool) !void {
    const index: usize = @intCast(@divTrunc(packet.pts, 41667));
    try std.testing.expect(index < 8 and !seen[index]);
    seen[index] = true;
    const key = index == 0 or index == 3 or index == 6;
    try std.testing.expectEqual(key, packet.key);
    var at: usize = 0;
    var idr = false;
    while (at < packet.data.len) {
        try std.testing.expect(packet.data.len - at >= 4);
        const n = std.mem.readInt(u32, packet.data[at..][0..4], .big);
        at += 4;
        try std.testing.expect(n > 0 and n <= packet.data.len - at);
        const kind = if (codec == 1) packet.data[at] & 31 else (packet.data[at] >> 1) & 63;
        idr = idr or (if (codec == 1) kind == 5 else kind == 19 or kind == 20);
        at += n;
    }
    try std.testing.expectEqual(key, idr);
}
test "requested IDRs override long GOP without losing delayed AVC frames" {
    const y: [128 * 96]u8 = @splat(64);
    const uv: [64 * 48]u8 = @splat(128);
    for ([_]u32{ 1, 2 }) |codec| {
        var encoder = try native.Encoder.init(.{ .codec = codec, .width = 128, .height = 96, .fps_num = 24, .fps_den = 1, .bitrate = 0, .quality = 90, .gop = 100 });
        defer encoder.deinit();
        var seen: [8]bool = @splat(false);
        for (0..8) |i| {
            if (i == 3 or i == 6) try encoder.requestKeyframe();
            if (try encoder.encode(.{ &y, &uv, &uv }, .{ 128, 64, 64 }, 128, 96, @intCast(i * 41667))) |packet| try observe(packet, codec, &seen);
        }
        while (try encoder.flush()) |packet| try observe(packet, codec, &seen);
        for (seen) |value| try std.testing.expect(value);
        try std.testing.expectError(error.EncoderFailed, encoder.requestKeyframe());
    }
}

test "profile and preset recipes construct compatible headers and preserve CQP IDR/drain behavior" {
    const y: [128 * 96]u8 = @splat(64);
    const uv: [64 * 48]u8 = @splat(128);
    for ([_]u32{ 1, 2 }) |codec| {
        for ([_]u32{ 0, 1, 2, 3, 4 }) |profile| {
            if (codec == 2 and profile != 0 and profile != 2) continue;
            for ([_]u32{ 0, 1, 5, 9 }) |preset| {
                var encoder = try native.Encoder.initWithOptions(.{ .codec = codec, .width = 128, .height = 96, .fps_num = 24, .fps_den = 1, .bitrate = 0, .quality = 90, .gop = 100 }, .{}, .{ .profile = profile, .preset = preset, .qp = 26 });
                defer encoder.deinit();
                const headers = try encoder.headers();
                var at: usize = 0;
                var found = false;
                while (at < headers.len) {
                    const n = std.mem.readInt(u32, headers[at..][0..4], .big);
                    at += 4;
                    try std.testing.expect(n > 0 and n <= headers.len - at);
                    if (codec == 1 and headers[at] & 31 == 7) {
                        found = true;
                        const idc = headers[at + 1];
                        switch (profile) {
                            1, 4 => {
                                try std.testing.expectEqual(@as(u8, 66), idc);
                                try std.testing.expect(headers[at + 2] & 64 != 0);
                            },
                            2 => try std.testing.expect(idc == 66 or idc == 77),
                            else => try std.testing.expect(idc == 66 or idc == 77 or idc == 100),
                        }
                    }
                    at += n;
                }
                if (codec == 1) try std.testing.expect(found);
                var seen: [8]bool = @splat(false);
                for (0..8) |i| {
                    if (i == 3 or i == 6) try encoder.requestKeyframe();
                    if (try encoder.encode(.{ &y, &uv, &uv }, .{ 128, 64, 64 }, 128, 96, @intCast(i * 41667))) |packet| try observe(packet, codec, &seen);
                }
                while (try encoder.flush()) |packet| try observe(packet, codec, &seen);
                for (seen) |value| try std.testing.expect(value);
            }
        }
    }
}

extern fn home_encoder_open_options(?*const native.Config, ?*const native.Color, ?*const native.Options, ?*?*anyopaque) c_int;
test "C option admission clears failed owners without changing scalar ABI" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 32), @sizeOf(native.Config));
    try t.expectEqual(@as(usize, 20), @sizeOf(native.Color));
    try t.expectEqual(@as(usize, 16), @sizeOf(native.Options));
    var cfg: native.Config = .{ .codec = 1, .width = 32, .height = 24, .fps_num = 30, .fps_den = 1, .bitrate = 0, .quality = 90, .gop = 30 };
    const color: native.Color = .{};
    var out: ?*anyopaque = @ptrFromInt(16);
    try t.expectEqual(@as(c_int, -1), home_encoder_open_options(&cfg, &color, null, &out));
    try t.expect(out == null);
    for ([_]native.Options{ .{ .struct_size = 15 }, .{ .profile = 5 }, .{ .preset = 10 }, .{ .qp = 52 } }) |bad| {
        out = @ptrFromInt(16);
        try t.expectEqual(@as(c_int, -1), home_encoder_open_options(&cfg, &color, &bad, &out));
        try t.expect(out == null);
    }
    var policy: native.Options = .{ .qp = 26 };
    cfg.bitrate = 1000000;
    try t.expectEqual(@as(c_int, -1), home_encoder_open_options(&cfg, &color, &policy, &out));
    try t.expect(out == null);
    cfg.codec = 2;
    cfg.bitrate = 0;
    policy.profile = 1;
    try t.expectEqual(@as(c_int, -1), home_encoder_open_options(&cfg, &color, &policy, &out));
    try t.expect(out == null);
    try t.expectEqual(@as(c_int, -1), home_encoder_open_options(null, null, null, null));
}
