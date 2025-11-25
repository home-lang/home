// Home Video Library - VideoToolbox Hardware Acceleration (macOS)
// Hardware-accelerated encoding and decoding using Apple's VideoToolbox

const std = @import("std");
const core = @import("../core.zig");

/// VideoToolbox codec type
pub const VTCodecType = enum {
    h264,
    hevc,
    prores,
    mpeg4,
    jpeg,
};

/// VideoToolbox hardware device
pub const VTDevice = struct {
    device_id: []const u8,
    name: []const u8,
    is_available: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device_id: []const u8, name: []const u8) !Self {
        return .{
            .allocator = allocator,
            .device_id = try allocator.dupe(u8, device_id),
            .name = try allocator.dupe(u8, name),
            .is_available = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.device_id);
        self.allocator.free(self.name);
    }
};

/// VideoToolbox encoder configuration
pub const VTEncoderConfig = struct {
    codec: VTCodecType,
    width: u32,
    height: u32,
    bitrate: u32, // bits per second
    fps: core.Rational,
    keyframe_interval: u32 = 30,
    profile: ?[]const u8 = null,
    level: ?[]const u8 = null,
    realtime: bool = true,
    enable_hardware_acceleration: bool = true,
    max_bitrate: ?u32 = null,
    quality: f32 = 0.7, // 0.0 - 1.0

    const Self = @This();

    pub fn h264(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .codec = .h264,
            .width = width,
            .height = height,
            .bitrate = bitrate,
            .fps = fps,
            .profile = "high",
        };
    }

    pub fn hevc(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .codec = .hevc,
            .width = width,
            .height = height,
            .bitrate = bitrate,
            .fps = fps,
            .profile = "main",
        };
    }

    pub fn prores(width: u32, height: u32, fps: core.Rational) Self {
        return .{
            .codec = .prores,
            .width = width,
            .height = height,
            .bitrate = 0, // ProRes doesn't use fixed bitrate
            .fps = fps,
            .realtime = false,
        };
    }
};

/// VideoToolbox hardware encoder
pub const VTEncoder = struct {
    config: VTEncoderConfig,
    frame_count: u64 = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: VTEncoderConfig) !Self {
        // In a real implementation, this would initialize the VideoToolbox session
        // For now, we return a placeholder

        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Clean up VideoToolbox session
    }

    pub fn encode(self: *Self, frame: *const core.VideoFrame) !EncodedPacket {
        // Placeholder for VideoToolbox encoding
        // Real implementation would:
        // 1. Convert VideoFrame to CVPixelBuffer
        // 2. Submit to VTCompressionSession
        // 3. Receive encoded data in callback
        // 4. Return as EncodedPacket

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
        // Flush any buffered frames
        return null;
    }
};

/// VideoToolbox decoder configuration
pub const VTDecoderConfig = struct {
    codec: VTCodecType,
    width: u32,
    height: u32,
    output_format: core.PixelFormat = .yuv420p,
    enable_hardware_acceleration: bool = true,
};

/// VideoToolbox hardware decoder
pub const VTDecoder = struct {
    config: VTDecoderConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: VTDecoderConfig) !Self {
        // Initialize VideoToolbox decompression session

        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Clean up decompression session
    }

    pub fn decode(self: *Self, packet: *const EncodedPacket) !?*core.VideoFrame {
        // Placeholder for VideoToolbox decoding
        // Real implementation would:
        // 1. Submit packet to VTDecompressionSession
        // 2. Receive CVPixelBuffer in callback
        // 3. Convert to VideoFrame
        // 4. Return decoded frame

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
        // Flush decoder
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

/// VideoToolbox capability query
pub const VTCapabilities = struct {
    const Self = @This();

    pub fn isAvailable() bool {
        // Check if running on macOS and VideoToolbox is available
        if (@import("builtin").os.tag != .macos) {
            return false;
        }

        return true;
    }

    pub fn listDevices(allocator: std.mem.Allocator) ![]VTDevice {
        var devices = std.ArrayList(VTDevice).init(allocator);

        // On macOS, typically only one device (integrated GPU)
        if (isAvailable()) {
            const device = try VTDevice.init(allocator, "default", "Apple GPU");
            try devices.append(device);
        }

        return devices.toOwnedSlice();
    }

    pub fn supportsCodec(codec: VTCodecType) bool {
        // All modern Apple devices support H.264 and HEVC
        return switch (codec) {
            .h264, .hevc => true,
            .prores => true, // M1+ Macs have ProRes encode/decode
            .mpeg4 => true,
            .jpeg => true,
        };
    }

    pub fn getMaxResolution(codec: VTCodecType) struct { width: u32, height: u32 } {
        return switch (codec) {
            .h264 => .{ .width = 4096, .height = 2304 },
            .hevc => .{ .width = 8192, .height = 4320 }, // 8K
            .prores => .{ .width = 8192, .height = 4320 },
            .mpeg4 => .{ .width = 1920, .height = 1080 },
            .jpeg => .{ .width = 16384, .height = 16384 },
        };
    }
};

/// VideoToolbox surface/buffer management
pub const VTSurface = struct {
    width: u32,
    height: u32,
    format: core.PixelFormat,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: core.PixelFormat) !Self {
        // Create CVPixelBuffer or IOSurface

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .format = format,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Release surface
    }

    pub fn toVideoFrame(self: *Self) !core.VideoFrame {
        // Convert CVPixelBuffer to VideoFrame
        return try core.VideoFrame.init(self.allocator, self.width, self.height, self.format);
    }

    pub fn fromVideoFrame(allocator: std.mem.Allocator, frame: *const core.VideoFrame) !Self {
        // Convert VideoFrame to CVPixelBuffer
        return try Self.init(allocator, frame.width, frame.height, frame.format);
    }
};
