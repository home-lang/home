// Home Video Library - VA-API Hardware Acceleration (Linux)
// Video Acceleration API for Linux systems (Intel, AMD)

const std = @import("std");
const core = @import("../core.zig");

/// VA-API profile
pub const VAProfile = enum {
    h264_baseline,
    h264_main,
    h264_high,
    hevc_main,
    hevc_main_10,
    vp8,
    vp9_profile_0,
    vp9_profile_2,
    av1_main,
    mpeg2_simple,
    mpeg2_main,
    vc1_simple,
    vc1_main,
    vc1_advanced,
    jpeg_baseline,
};

/// VA-API entrypoint (encode or decode)
pub const VAEntrypoint = enum {
    vld, // Variable Length Decoding (decode)
    encode,
    encode_slice,
    encode_picture,
    video_proc, // Video processing
};

/// VA-API device
pub const VADevice = struct {
    device_path: []const u8, // e.g., "/dev/dri/renderD128"
    vendor: []const u8,
    driver: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device_path: []const u8, vendor: []const u8, driver: []const u8) !Self {
        return .{
            .allocator = allocator,
            .device_path = try allocator.dupe(u8, device_path),
            .vendor = try allocator.dupe(u8, vendor),
            .driver = try allocator.dupe(u8, driver),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.device_path);
        self.allocator.free(self.vendor);
        self.allocator.free(self.driver);
    }
};

/// VA-API encoder configuration
pub const VAEncoderConfig = struct {
    profile: VAProfile,
    width: u32,
    height: u32,
    bitrate: u32, // bits per second
    fps: core.Rational,
    rc_mode: RateControlMode = .cbr,
    keyframe_interval: u32 = 30,
    quality: u32 = 50, // 0-100
    max_bitrate: ?u32 = null,
    slice_count: u32 = 1,
    low_power: bool = false, // Use low-power encoding mode if available

    pub const RateControlMode = enum {
        cqp, // Constant QP
        cbr, // Constant bitrate
        vbr, // Variable bitrate
        vcm, // Video Conferencing Mode
    };

    const Self = @This();

    pub fn h264(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .profile = .h264_high,
            .width = width,
            .height = height,
            .bitrate = bitrate,
            .fps = fps,
        };
    }

    pub fn hevc(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .profile = .hevc_main,
            .width = width,
            .height = height,
            .bitrate = bitrate,
            .fps = fps,
        };
    }
};

/// VA-API hardware encoder
pub const VAEncoder = struct {
    device: *VADevice,
    config: VAEncoderConfig,
    frame_count: u64 = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *VADevice, config: VAEncoderConfig) !Self {
        // Initialize VA-API context and config
        // vaCreateConfig()
        // vaCreateContext()

        return .{
            .allocator = allocator,
            .device = device,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // vaDestroyContext()
        // vaDestroyConfig()
    }

    pub fn encode(self: *Self, frame: *const core.VideoFrame) !EncodedPacket {
        // VA-API encoding process:
        // 1. vaCreateSurfaces() - create VA surface
        // 2. Upload frame data to surface
        // 3. vaCreateBuffer() for sequence, picture, slice params
        // 4. vaBeginPicture()
        // 5. vaRenderPicture() for each buffer
        // 6. vaEndPicture()
        // 7. vaSyncSurface() - wait for encoding
        // 8. vaMapBuffer() - get encoded data
        // 9. vaUnmapBuffer()

        self.frame_count += 1;

        const is_keyframe = (self.frame_count % self.config.keyframe_interval) == 0;

        return .{
            .data = &[_]u8{}, // Placeholder
            .size = 0,
            .pts = frame.pts,
            .dts = frame.pts,
            .is_keyframe = is_keyframe,
        };
    }

    pub fn flush(self: *Self) !?EncodedPacket {
        _ = self;
        return null;
    }
};

/// VA-API decoder configuration
pub const VADecoderConfig = struct {
    profile: VAProfile,
    width: u32,
    height: u32,
    output_format: core.PixelFormat = .yuv420p,
};

/// VA-API hardware decoder
pub const VADecoder = struct {
    device: *VADevice,
    config: VADecoderConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *VADevice, config: VADecoderConfig) !Self {
        // Initialize decoder context

        return .{
            .allocator = allocator,
            .device = device,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn decode(self: *Self, packet: *const EncodedPacket) !?*core.VideoFrame {
        // VA-API decoding process:
        // 1. vaCreateBuffer() with bitstream data
        // 2. vaBeginPicture()
        // 3. vaRenderPicture()
        // 4. vaEndPicture()
        // 5. vaSyncSurface()
        // 6. Download surface to VideoFrame

        const frame = try self.allocator.create(core.VideoFrame);
        frame.* = try core.VideoFrame.init(
            self.allocator,
            self.config.width,
            self.config.height,
            self.config.output_format,
        );

        frame.pts = packet.pts;

        return frame;
    }

    pub fn flush(self: *Self) !void {
        _ = self;
    }
};

/// Encoded packet
pub const EncodedPacket = struct {
    data: []const u8,
    size: usize,
    pts: core.Timestamp,
    dts: core.Timestamp,
    is_keyframe: bool,
};

/// VA-API capability query
pub const VACapabilities = struct {
    const Self = @This();

    pub fn isAvailable() bool {
        // Check if running on Linux and VA-API is available
        if (@import("builtin").os.tag != .linux) {
            return false;
        }

        // Check for /dev/dri/renderD*
        var dir = std.fs.openDirAbsolute("/dev/dri", .{ .iterate = true }) catch return false;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (std.mem.startsWith(u8, entry.name, "renderD")) {
                return true;
            }
        }

        return false;
    }

    pub fn listDevices(allocator: std.mem.Allocator) ![]VADevice {
        var devices = std.ArrayList(VADevice).init(allocator);

        if (@import("builtin").os.tag != .linux) {
            return devices.toOwnedSlice();
        }

        // Enumerate /dev/dri/renderD* devices
        var dir = std.fs.openDirAbsolute("/dev/dri", .{ .iterate = true }) catch {
            return devices.toOwnedSlice();
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (std.mem.startsWith(u8, entry.name, "renderD")) {
                const path = try std.fmt.allocPrint(allocator, "/dev/dri/{s}", .{entry.name});
                defer allocator.free(path);

                // Query device info (would use libva to get actual vendor/driver)
                const device = try VADevice.init(allocator, path, "Unknown", "Unknown");
                try devices.append(device);
            }
        }

        return devices.toOwnedSlice();
    }

    pub fn queryProfiles(device: *VADevice, allocator: std.mem.Allocator) ![]VAProfile {
        _ = device;

        var profiles = std.ArrayList(VAProfile).init(allocator);

        // Placeholder - would use vaQueryConfigProfiles()
        try profiles.append(.h264_main);
        try profiles.append(.h264_high);
        try profiles.append(.hevc_main);
        try profiles.append(.vp9_profile_0);

        return profiles.toOwnedSlice();
    }

    pub fn queryEntrypoints(device: *VADevice, profile: VAProfile, allocator: std.mem.Allocator) ![]VAEntrypoint {
        _ = device;
        _ = profile;

        var entrypoints = std.ArrayList(VAEntrypoint).init(allocator);

        // Placeholder - would use vaQueryConfigEntrypoints()
        try entrypoints.append(.vld);
        try entrypoints.append(.encode);

        return entrypoints.toOwnedSlice();
    }
};

/// VA-API surface
pub const VASurface = struct {
    width: u32,
    height: u32,
    format: core.PixelFormat,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: core.PixelFormat) !Self {
        // vaCreateSurfaces()

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .format = format,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // vaDestroySurfaces()
    }

    pub fn upload(self: *Self, frame: *const core.VideoFrame) !void {
        // Upload VideoFrame data to VA surface
        // vaCreateImage(), vaPutImage(), vaDestroyImage()
        _ = self;
        _ = frame;
    }

    pub fn download(self: *Self) !core.VideoFrame {
        // Download from VA surface to VideoFrame
        // vaCreateImage(), vaGetImage(), vaDestroyImage()
        return try core.VideoFrame.init(self.allocator, self.width, self.height, self.format);
    }
};

/// VA-API video processing (deinterlacing, scaling, color conversion)
pub const VAVideoProc = struct {
    device: *VADevice,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *VADevice) !Self {
        return .{
            .allocator = allocator,
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn deinterlace(self: *Self, frame: *const core.VideoFrame) !*core.VideoFrame {
        // Use VA-API video processing pipeline for deinterlacing
        _ = self;

        const output = try self.allocator.create(core.VideoFrame);
        output.* = try frame.clone(self.allocator);
        return output;
    }

    pub fn scale(self: *Self, frame: *const core.VideoFrame, new_width: u32, new_height: u32) !*core.VideoFrame {
        // Hardware-accelerated scaling
        _ = self;

        const output = try self.allocator.create(core.VideoFrame);
        output.* = try core.VideoFrame.init(self.allocator, new_width, new_height, frame.format);
        output.pts = frame.pts;
        return output;
    }

    pub fn convertColorSpace(self: *Self, frame: *const core.VideoFrame, target_format: core.PixelFormat) !*core.VideoFrame {
        // Hardware-accelerated color space conversion
        _ = self;

        const output = try self.allocator.create(core.VideoFrame);
        output.* = try core.VideoFrame.init(self.allocator, frame.width, frame.height, target_format);
        output.pts = frame.pts;
        return output;
    }
};
