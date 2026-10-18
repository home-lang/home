//! Safe optional Home AVC/HEVC integration. Compile native_encoder.c and link
//! x264/x265. Only Home's fixed scalar ABI crosses the boundary, never vendor
//! structures; this module works before/after Zig's removal of @cImport.
const std = @import("std");
const Handle = opaque {};
pub const Config = extern struct { codec: u32, width: u32, height: u32, fps_num: u32, fps_den: u32, bitrate: u32, quality: u32, gop: u32 };
const RawPacket = extern struct { data: [*]const u8, size: usize, pts: i64, key: c_int };
extern fn home_encoder_open(*const Config, *?*Handle) c_int;
extern fn home_encoder_headers(*Handle, *RawPacket) c_int;
extern fn home_encoder_encode(*Handle, *const [3][*]const u8, *const [3]c_int, i64, *RawPacket) c_int;
extern fn home_encoder_flush(*Handle, *RawPacket) c_int;
extern fn home_encoder_close(*Handle) void;
pub const Packet = struct { data: []const u8, pts: i64, key: bool };
pub const Encoder = struct {
    handle: *Handle,
    width: u32,
    height: u32,
    last_pts: ?i64 = null,
    draining: bool = false,
    failed: bool = false,
    pub fn init(config: Config) !Encoder {
        var out: ?*Handle = null;
        try check(home_encoder_open(&config, &out));
        return .{ .handle = out.?, .width = config.width, .height = config.height };
    }
    pub fn deinit(self: *Encoder) void {
        home_encoder_close(self.handle);
    }
    pub fn headers(self: *Encoder) ![]const u8 {
        var packet: RawPacket = undefined;
        try check(home_encoder_headers(self.handle, &packet));
        return packet.data[0..packet.size];
    }
    pub fn flush(self: *Encoder) !?Packet {
        if (self.failed) return error.EncoderFailed;
        self.draining = true;
        var packet: RawPacket = undefined;
        errdefer self.failed = true;
        try check(home_encoder_flush(self.handle, &packet));
        return view(packet);
    }
    /// Borrowed output lasts until the next call; input may be released on return.
    /// Null means buffered (AVC VFR retains one input); always drain flush().
    pub fn encode(self: *Encoder, planes: [3][]const u8, strides: [3]u32, width: u32, height: u32, pts: i64) !?Packet {
        if (self.failed or self.draining) return error.EncoderFailed;
        if (pts < 0 or (self.last_pts != null and pts <= self.last_pts.?)) return error.InvalidTimestamp;
        if (width != self.width or height != self.height) return error.InvalidFrame;
        for (0..3) |i| {
            const w = if (i == 0) width else width / 2;
            const h = if (i == 0) height else height / 2;
            if (strides[i] < w or strides[i] > std.math.maxInt(c_int) or planes[i].len < @as(u64, strides[i]) * (h - 1) + w) return error.InvalidFrame;
        }
        const pointers = [3][*]const u8{ planes[0].ptr, planes[1].ptr, planes[2].ptr };
        const pitch = [3]c_int{ @intCast(strides[0]), @intCast(strides[1]), @intCast(strides[2]) };
        var packet: RawPacket = undefined;
        check(home_encoder_encode(self.handle, &pointers, &pitch, pts, &packet)) catch |err| {
            self.failed = true;
            return err;
        };
        self.last_pts = pts;
        return view(packet);
    }
};
fn check(status: c_int) !void {
    return switch (status) {
        0 => {},
        -1 => error.InvalidConfiguration,
        -2 => error.OutOfMemory,
        else => error.EncodeFailed,
    };
}
fn view(packet: RawPacket) ?Packet {
    if (packet.size == 0) return null;
    return .{ .data = packet.data[0..packet.size], .pts = packet.pts, .key = packet.key != 0 };
}
