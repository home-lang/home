//! Independent bounded SPS/VUI and nclx inspection for Home's 8-bit low-latency
//! adapters. This is a test oracle, not a general-purpose media parser.
const std = @import("std");
const native = @import("encoder");
const mp4 = @import("mp4");
const description = @import("color");
const t = std.testing;
extern fn home_encoder_open_color(?*const native.Config, ?*const native.Color, ?*?*anyopaque) c_int;
const Bits = struct {
    data: []const u8,
    bit: usize = 0,
    fn read(self: *Bits, n: usize) !u32 {
        if (n > 32 or self.bit > self.data.len * 8 or n > self.data.len * 8 - self.bit) return error.Truncated;
        var result: u32 = 0;
        for (0..n) |_| {
            result = (result << 1) | ((self.data[self.bit / 8] >> @as(u3, @intCast(7 - self.bit % 8))) & 1);
            self.bit += 1;
        }
        return result;
    }
    fn skip(self: *Bits, n: usize) !void {
        var left = n;
        while (left > 0) {
            const step = @min(left, 32);
            _ = try self.read(step);
            left -= step;
        }
    }
    fn flag(self: *Bits) !bool {
        return try self.read(1) != 0;
    }
    fn ue(self: *Bits) !u32 {
        var zeros: usize = 0;
        while (!try self.flag()) {
            zeros += 1;
            if (zeros > 30) return error.InvalidExpGolomb;
        }
        return (@as(u32, 1) << @as(u5, @intCast(zeros))) - 1 + try self.read(zeros);
    }
};
fn vui(bits: *Bits) !description.Signal {
    if (try bits.flag()) {
        if (try bits.read(8) == 255) try bits.skip(32);
    }
    if (try bits.flag()) try bits.skip(1);
    if (!try bits.flag()) return error.MissingVideoSignal;
    try bits.skip(3);
    const full = try bits.flag();
    if (!try bits.flag()) return error.MissingColorDescription;
    return .{ .primaries = @intCast(try bits.read(8)), .transfer = @intCast(try bits.read(8)), .matrix = @intCast(try bits.read(8)), .full_range = full };
}
fn inspectSps(codec: u32, nal: []const u8) !description.Signal {
    var rbsp: [2048]u8 = undefined;
    var len: usize = 0;
    var zeros: usize = 0;
    for (nal[if (codec == 1) @as(usize, 1) else 2..]) |byte| {
        if (zeros >= 2 and byte == 3) {
            zeros = 0;
            continue;
        }
        if (len == rbsp.len) return error.HeaderTooLarge;
        rbsp[len] = byte;
        len += 1;
        zeros = if (byte == 0) zeros + 1 else 0;
    }
    var b: Bits = .{ .data = rbsp[0..len] };
    if (codec == 1) {
        try t.expectEqual(@as(u32, 100), try b.read(8));
        try b.skip(16);
        _ = try b.ue();
        try t.expectEqual(@as(u32, 1), try b.ue());
        try t.expectEqual(@as(u32, 0), try b.ue());
        try t.expectEqual(@as(u32, 0), try b.ue());
        try b.skip(1);
        if (try b.flag()) return error.UnexpectedScalingLists;
        _ = try b.ue();
        const poc = try b.ue();
        if (poc == 0) {
            _ = try b.ue();
        } else if (poc != 2) return error.UnexpectedPoc;
        _ = try b.ue();
        try b.skip(1);
        _ = try b.ue();
        _ = try b.ue();
        if (!try b.flag()) try b.skip(1);
        try b.skip(1);
        if (try b.flag()) {
            for (0..4) |_| {
                _ = try b.ue();
            }
        }
    } else {
        try b.skip(4);
        try t.expectEqual(@as(u32, 0), try b.read(3)); // no temporal sublayers
        try b.skip(1 + 96); // general profile_tier_level
        _ = try b.ue();
        try t.expectEqual(@as(u32, 1), try b.ue());
        _ = try b.ue();
        _ = try b.ue();
        if (try b.flag()) {
            for (0..4) |_| {
                _ = try b.ue();
            }
        }
        try t.expectEqual(@as(u32, 0), try b.ue());
        try t.expectEqual(@as(u32, 0), try b.ue());
        const poc_bits = (try b.ue()) + 4;
        _ = try b.flag(); // one sublayer, so ordering loop always has one entry
        for (0..9) |_| {
            _ = try b.ue();
        } // 3 ordering + 6 coding/transform fields
        if (try b.flag()) {
            if (try b.flag()) return error.UnexpectedScalingLists;
        }
        try b.skip(2); // AMP, SAO
        if (try b.flag()) {
            try b.skip(8);
            _ = try b.ue();
            _ = try b.ue();
            try b.skip(1);
        }
        // The zerolatency adapter emits explicit reference picture sets. Keep
        // this oracle bounded and reject unhandled syntax instead of guessing.
        const sets = try b.ue();
        if (sets > 64) return error.TooManyReferenceSets;
        for (0..sets) |i| {
            if (i != 0 and try b.flag()) return error.UnexpectedPredictedReferenceSet;
            const negative = try b.ue();
            const positive = try b.ue();
            if (negative + positive > 64) return error.TooManyReferences;
            for (0..negative + positive) |_| {
                _ = try b.ue();
                try b.skip(1);
            }
        }
        if (try b.flag()) {
            const count = try b.ue();
            if (count > 32) return error.TooManyReferences;
            for (0..count) |_| try b.skip(poc_bits + 1);
        }
        try b.skip(2); // temporal MVP, strong smoothing
    }
    if (!try b.flag()) return error.MissingVui;
    return vui(&b);
}
fn inspectHeaders(codec: u32, headers: []const u8) !description.Signal {
    var nals: mp4.Nals = .{ .data = headers };
    while (try nals.next()) |nal| {
        const kind = if (codec == 1) nal[0] & 31 else (nal[0] >> 1) & 63;
        if (kind == (if (codec == 1) @as(u8, 7) else 33)) return inspectSps(codec, nal);
    }
    return error.MissingSps;
}
const Out = struct {
    data: [16384]u8 = undefined,
    len: usize = 0,
    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (bytes.len > self.data.len - self.len) return error.NoSpace;
        @memcpy(self.data[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn patch(ctx: *anyopaque, offset: u64, bytes: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (offset > self.len or bytes.len > self.len - offset) return error.NoSpace;
        @memcpy(self.data[@intCast(offset)..][0..bytes.len], bytes);
    }
    fn signal(self: *@This()) !description.Signal {
        const at = std.mem.indexOf(u8, self.data[0..self.len], "colrnclx") orelse return error.MissingNclx;
        try t.expectEqual(@as(u32, 19), std.mem.readInt(u32, self.data[at - 4 ..][0..4], .big));
        try t.expectEqual(@as(u8, 0), self.data[at + 14] & 127);
        return .{ .primaries = std.mem.readInt(u16, self.data[at + 8 ..][0..2], .big), .transfer = std.mem.readInt(u16, self.data[at + 10 ..][0..2], .big), .matrix = std.mem.readInt(u16, self.data[at + 12 ..][0..2], .big), .full_range = self.data[at + 14] == 128 };
    }
};
fn cfg(codec: u32) native.Config {
    return .{ .codec = codec, .width = 32, .height = 32, .fps_num = 25, .fps_den = 1, .bitrate = 0, .quality = 90, .gop = 60 };
}
const audio: mp4.AudioConfig = .{ .sample_rate = 48000, .channels = 2, .bitrate = 128000, .delay = 2048, .config = .{ 0x11, 0x90 } };
test "actual AVC HEVC SPS VUI matches MP4 nclx for every supported color combination" {
    for ([_]u32{ 1, 2 }) |codec| {
        for ([_]u16{ 1, 6, 9 }) |primaries| {
            for ([_]u16{ 1, 8, 13 }) |transfer| {
                for ([_]u16{ 1, 6, 9 }) |matrix| {
                    for ([_]bool{ false, true }) |full| {
                        const expected: description.Signal = .{ .primaries = primaries, .transfer = transfer, .matrix = matrix, .full_range = full };
                        var encoder = try native.Encoder.initWithColor(cfg(codec), .{ .primaries = primaries, .transfer = transfer, .matrix = matrix, .full_range = @intFromBool(full) });
                        defer encoder.deinit();
                        const headers = try encoder.headers();
                        try t.expectEqualDeep(expected, try inspectHeaders(codec, headers));
                        var out: Out = .{};
                        const sink: mp4.Sink = .{ .context = &out, .write = Out.write, .patch = Out.patch };
                        const color: mp4.Color = .{ .primaries = primaries, .transfer = transfer, .matrix = matrix, .full_range = full };
                        _ = try mp4.Writer.initWithColor(sink, 32, 32, if (codec == 1) .h264 else .hevc, headers, color);
                        try t.expectEqualDeep(expected, try out.signal());
                        out.len = 0;
                        _ = try mp4.Writer.initAvWithColor(sink, 32, 32, if (codec == 1) .h264 else .hevc, headers, audio, color);
                        try t.expectEqualDeep(expected, try out.signal());
                    }
                }
            }
        }
    }
}
test "legacy constructors preserve signaling and invalid color fails before output" {
    try t.expectEqual(@as(usize, 32), @sizeOf(native.Config));
    try t.expectEqual(@as(usize, 20), @sizeOf(native.Color));
    const expected: description.Signal = .{ .primaries = 1, .transfer = 13, .matrix = 6, .full_range = false };
    for ([_]u32{ 1, 2 }) |codec| {
        var encoder = try native.Encoder.init(cfg(codec));
        defer encoder.deinit();
        const headers = try encoder.headers();
        try t.expectEqualDeep(expected, try inspectHeaders(codec, headers));
        var out: Out = .{};
        const sink: mp4.Sink = .{ .context = &out, .write = Out.write, .patch = Out.patch };
        _ = try mp4.Writer.init(sink, 32, 32, if (codec == 1) .h264 else .hevc, headers);
        try t.expectEqualDeep(expected, try out.signal());
        out.len = 0;
        _ = try mp4.Writer.initAv(sink, 32, 32, if (codec == 1) .h264 else .hevc, headers, audio);
        try t.expectEqualDeep(expected, try out.signal());
        inline for (.{ "primaries", "transfer", "matrix", "full_range", "struct_size" }) |field| {
            for ([_]u32{ 0, 2, std.math.maxInt(u32) }) |value| {
                var bad: native.Color = .{};
                @field(bad, field) = value;
                if (comptime std.mem.eql(u8, field, "full_range")) {
                    if (value == 0) continue;
                }
                try t.expectError(error.InvalidConfiguration, native.Encoder.initWithColor(cfg(codec), bad));
            }
        }
        inline for (.{ "primaries", "transfer", "matrix" }) |field| {
            var bad: mp4.Color = .{};
            @field(bad, field) = 0;
            out.len = 0;
            try t.expectError(error.InvalidConfiguration, mp4.Writer.initWithColor(sink, 32, 32, if (codec == 1) .h264 else .hevc, headers, bad));
            try t.expectEqual(@as(usize, 0), out.len);
            try t.expectError(error.InvalidConfiguration, mp4.Writer.initAvWithColor(sink, 32, 32, if (codec == 1) .h264 else .hevc, headers, audio, bad));
            try t.expectEqual(@as(usize, 0), out.len);
        }
    }
}
test "C color construction rejects null recipes and clears failed handles" {
    const config = cfg(1);
    const color: native.Color = .{};
    try t.expectEqual(@as(c_int, -1), home_encoder_open_color(&config, &color, null));
    var out: ?*anyopaque = @ptrFromInt(16);
    try t.expectEqual(@as(c_int, -1), home_encoder_open_color(null, &color, &out));
    try t.expect(out == null);
    out = @ptrFromInt(16);
    try t.expectEqual(@as(c_int, -1), home_encoder_open_color(&config, null, &out));
    try t.expect(out == null);
    var bad = color;
    bad.struct_size -= 1;
    out = @ptrFromInt(16);
    try t.expectEqual(@as(c_int, -1), home_encoder_open_color(&config, &bad, &out));
    try t.expect(out == null);
}
