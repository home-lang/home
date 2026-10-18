//! Home opaque, header-checked ALSA capture. Build C boundary and link libasound.
//! Calls serialize; close only after read returns. S16LE mono/stereo, BOOTTIME ns.
const Handle = opaque {};
pub const Config = extern struct { sample_rate: u32, channels: u32, block_frames: u32 };
extern fn home_audio_open(*const Config, [*:0]const u8, *?*Handle) c_int;
extern fn home_audio_read(*Handle, [*]u8, u32, u32, *u32, *u64, *i64) c_int;
extern fn home_audio_close(*Handle) void;
pub const Block = struct { frames: u32, timestamp_ns: u64, clock_error_ns: i64 };
pub const Capture = struct {
    handle: *Handle,
    config: Config,
    failed: bool = false,
    pub fn init(cfg: Config, device: [:0]const u8) !Capture {
        var out: ?*Handle = null;
        try check(home_audio_open(&cfg, device.ptr, &out));
        return .{ .handle = out.?, .config = cfg };
    }
    pub fn deinit(s: *Capture) void {
        home_audio_close(s.handle);
    }
    pub fn read(s: *Capture, data: []u8, timeout_ms: u32) !?Block {
        if (s.failed) return error.CaptureFailed;
        if (data.len < @as(u64, s.config.block_frames) * s.config.channels * 2 or timeout_ms > 1000) return error.InvalidConfiguration;
        var block: Block = undefined;
        const rc = home_audio_read(s.handle, data.ptr, @intCast(s.config.block_frames), timeout_ms, &block.frames, &block.timestamp_ns, &block.clock_error_ns);
        if (rc == 1) return null;
        check(rc) catch |err| {
            s.failed = true;
            return err;
        };
        return block;
    }
};
fn check(rc: c_int) !void {
    return switch (rc) {
        0 => {},
        -1 => error.InvalidConfiguration,
        -2 => error.OutOfMemory,
        else => error.CaptureFailed,
    };
}
