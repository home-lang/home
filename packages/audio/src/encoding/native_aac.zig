//! Opt-in AAC-LC using Home's header-checked standalone FDK boundary.
//! Serialize calls. Packet storage is borrowed until the next encode/flush call.
const Handle = opaque {};
pub const Config = extern struct { sample_rate: u32, channels: u32, bitrate: u32 };
pub const Info = extern struct { frame_length: u32, delay: u32, config_size: u32, config: [64]u8 };
extern fn home_aac_open(*const Config, *?*Handle, *Info) c_int;
extern fn home_aac_encode(*Handle, [*]const u8, u32, [*]u8, u32, *u32, *u32) c_int;
extern fn home_aac_flush(*Handle, [*]u8, u32, *u32) c_int;
extern fn home_aac_close(*Handle) void;
pub const Result = struct { consumed_frames: u32, data: []const u8 };
pub const Encoder = struct {
    handle: *Handle,
    config: Config,
    info: Info,
    output: [8192]u8 = undefined,
    draining: bool = false,
    failed: bool = false,
    pub fn init(config: Config) !Encoder {
        var handle: ?*Handle = null;
        var info: Info = undefined;
        try check(home_aac_open(&config, &handle, &info));
        return .{ .handle = handle.?, .config = config, .info = info };
    }
    pub fn deinit(s: *Encoder) void {
        home_aac_close(s.handle);
    }
    pub fn encode(s: *Encoder, data: []const u8) !Result {
        if (s.failed or s.draining) return error.EncoderFailed;
        const stride = s.config.channels * 2;
        if (data.len == 0 or data.len % stride != 0 or data.len / stride > 1024) return error.InvalidPcm;
        var bytes: u32 = 0;
        var consumed: u32 = 0;
        check(home_aac_encode(s.handle, data.ptr, @intCast(data.len / stride), &s.output, s.output.len, &bytes, &consumed)) catch |err| {
            s.failed = true;
            return err;
        };
        return .{ .consumed_frames = consumed, .data = s.output[0..bytes] };
    }
    pub fn flush(s: *Encoder) !?[]const u8 {
        if (s.failed) return error.EncoderFailed;
        s.draining = true;
        for (0..16) |_| {
            var bytes: u32 = 0;
            const rc = home_aac_flush(s.handle, &s.output, s.output.len, &bytes);
            if (rc == 1) return null;
            check(rc) catch |err| {
                s.failed = true;
                return err;
            };
            if (bytes != 0) return s.output[0..bytes];
        }
        s.failed = true;
        return error.EncoderFailed;
    }
};
fn check(rc: c_int) !void {
    return switch (rc) {
        0 => {},
        -1 => error.InvalidConfiguration,
        -2 => error.OutOfMemory,
        else => error.EncoderFailed,
    };
}
