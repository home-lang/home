// Home Video Library - Hardware Acceleration Abstraction Layer
// Unified interface for hardware-accelerated encoding/decoding across platforms

const std = @import("std");
const core = @import("../core.zig");
const builtin = @import("builtin");

// Platform-specific imports
const videotoolbox = @import("videotoolbox.zig");
const vaapi = @import("vaapi.zig");
const nvenc = @import("nvenc.zig");
const d3d11 = @import("d3d11.zig");

/// Hardware acceleration backend type
pub const HWAccelType = enum {
    none,
    videotoolbox, // macOS
    vaapi, // Linux (Intel, AMD)
    nvenc, // NVIDIA (cross-platform)
    d3d11, // Windows
    qsv, // Intel Quick Sync Video
    amf, // AMD Media Framework
};

/// Hardware device (unified)
pub const HWDevice = union(HWAccelType) {
    none: void,
    videotoolbox: *videotoolbox.VTDevice,
    vaapi: *vaapi.VADevice,
    nvenc: *nvenc.NVIDIADevice,
    d3d11: *d3d11.D3D11Adapter,
    qsv: void, // Placeholder
    amf: void, // Placeholder

    pub fn deinit(self: *HWDevice, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .videotoolbox => |dev| {
                dev.deinit();
                allocator.destroy(dev);
            },
            .vaapi => |dev| {
                dev.deinit();
                allocator.destroy(dev);
            },
            .nvenc => |dev| {
                dev.deinit();
                allocator.destroy(dev);
            },
            .d3d11 => |dev| {
                dev.deinit();
                allocator.destroy(dev);
            },
            else => {},
        }
    }
};

/// Codec type (unified)
pub const HWCodec = enum {
    h264,
    hevc,
    vp8,
    vp9,
    av1,
    mpeg2,
    mpeg4,
    prores,
    jpeg,
};

/// Hardware encoder configuration (unified)
pub const HWEncoderConfig = struct {
    codec: HWCodec,
    width: u32,
    height: u32,
    fps: core.Rational,
    bitrate: u32, // bits per second
    quality: f32 = 0.75, // 0.0-1.0 (quality vs speed tradeoff)
    keyframe_interval: u32 = 30,
    low_latency: bool = false,
    max_bitrate: ?u32 = null,

    const Self = @This();

    pub fn h264(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .codec = .h264,
            .width = width,
            .height = height,
            .bitrate = bitrate,
            .fps = fps,
        };
    }

    pub fn hevc(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .codec = .hevc,
            .width = width,
            .height = height,
            .bitrate = bitrate,
            .fps = fps,
        };
    }
};

/// Hardware encoder (unified)
pub const HWEncoder = struct {
    device: HWDevice,
    config: HWEncoderConfig,
    backend: union(HWAccelType) {
        none: void,
        videotoolbox: videotoolbox.VTEncoder,
        vaapi: vaapi.VAEncoder,
        nvenc: nvenc.NVENCEncoder,
        d3d11: d3d11.D3D11Encoder,
        qsv: void,
        amf: void,
    },
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: HWDevice, config: HWEncoderConfig) !Self {
        const backend_type = @as(HWAccelType, device);

        var backend = switch (backend_type) {
            .videotoolbox => blk: {
                const vt_config = videotoolbox.VTEncoderConfig{
                    .codec = switch (config.codec) {
                        .h264 => .h264,
                        .hevc => .hevc,
                        .prores => .prores,
                        else => return error.UnsupportedCodec,
                    },
                    .width = config.width,
                    .height = config.height,
                    .bitrate = config.bitrate,
                    .fps = config.fps,
                    .keyframe_interval = config.keyframe_interval,
                };

                const encoder = try videotoolbox.VTEncoder.init(allocator, vt_config);
                break :blk .{ .videotoolbox = encoder };
            },
            .vaapi => blk: {
                const va_profile = switch (config.codec) {
                    .h264 => vaapi.VAProfile.h264_high,
                    .hevc => vaapi.VAProfile.hevc_main,
                    .vp8 => vaapi.VAProfile.vp8,
                    .vp9 => vaapi.VAProfile.vp9_profile_0,
                    else => return error.UnsupportedCodec,
                };

                const va_config = vaapi.VAEncoderConfig{
                    .profile = va_profile,
                    .width = config.width,
                    .height = config.height,
                    .bitrate = config.bitrate,
                    .fps = config.fps,
                };

                const encoder = try vaapi.VAEncoder.init(allocator, device.vaapi, va_config);
                break :blk .{ .vaapi = encoder };
            },
            .nvenc => blk: {
                const nv_codec = switch (config.codec) {
                    .h264 => nvenc.NVENCCodec.h264,
                    .hevc => nvenc.NVENCCodec.hevc,
                    .av1 => nvenc.NVENCCodec.av1,
                    else => return error.UnsupportedCodec,
                };

                const nv_config = nvenc.NVENCEncoderConfig{
                    .codec = nv_codec,
                    .width = config.width,
                    .height = config.height,
                    .bitrate = config.bitrate,
                    .max_bitrate = config.max_bitrate orelse config.bitrate * 2,
                    .fps = config.fps,
                };

                const encoder = try nvenc.NVENCEncoder.init(allocator, device.nvenc, nv_config);
                break :blk .{ .nvenc = encoder };
            },
            .d3d11 => blk: {
                const d3d_profile = switch (config.codec) {
                    .h264 => d3d11.D3D11Profile.h264_vld,
                    .hevc => d3d11.D3D11Profile.hevc_main,
                    .vp9 => d3d11.D3D11Profile.vp9_profile0,
                    else => return error.UnsupportedCodec,
                };

                const d3d_config = d3d11.D3D11EncoderConfig{
                    .profile = d3d_profile,
                    .width = config.width,
                    .height = config.height,
                    .bitrate = config.bitrate,
                    .fps = config.fps,
                };

                const encoder = try d3d11.D3D11Encoder.init(allocator, device.d3d11, d3d_config);
                break :blk .{ .d3d11 = encoder };
            },
            else => return error.UnsupportedBackend,
        };

        return .{
            .allocator = allocator,
            .device = device,
            .config = config,
            .backend = backend,
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.backend) {
            .videotoolbox => |*enc| enc.deinit(),
            .vaapi => |*enc| enc.deinit(),
            .nvenc => |*enc| enc.deinit(),
            .d3d11 => |*enc| enc.deinit(),
            else => {},
        }
    }

    pub fn encode(self: *Self, frame: *const core.VideoFrame) !EncodedPacket {
        return switch (self.backend) {
            .videotoolbox => |*enc| try enc.encode(frame),
            .vaapi => |*enc| try enc.encode(frame),
            .nvenc => |*enc| try enc.encode(frame),
            .d3d11 => |*enc| try enc.encode(frame),
            else => error.UnsupportedBackend,
        };
    }

    pub fn flush(self: *Self) !?EncodedPacket {
        return switch (self.backend) {
            .videotoolbox => |*enc| try enc.flush(),
            .vaapi => |*enc| try enc.flush(),
            .nvenc => |*enc| try enc.flush(),
            .d3d11 => |*enc| try enc.flush(),
            else => null,
        };
    }
};

/// Hardware decoder configuration (unified)
pub const HWDecoderConfig = struct {
    codec: HWCodec,
    width: u32,
    height: u32,
    output_format: core.PixelFormat = .yuv420p,
};

/// Hardware decoder (unified)
pub const HWDecoder = struct {
    device: HWDevice,
    config: HWDecoderConfig,
    backend: union(HWAccelType) {
        none: void,
        videotoolbox: videotoolbox.VTDecoder,
        vaapi: vaapi.VADecoder,
        nvenc: nvenc.NVDECDecoder,
        d3d11: d3d11.D3D11Decoder,
        qsv: void,
        amf: void,
    },
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: HWDevice, config: HWDecoderConfig) !Self {
        const backend_type = @as(HWAccelType, device);

        var backend = switch (backend_type) {
            .videotoolbox => blk: {
                const vt_config = videotoolbox.VTDecoderConfig{
                    .codec = switch (config.codec) {
                        .h264 => .h264,
                        .hevc => .hevc,
                        else => return error.UnsupportedCodec,
                    },
                    .width = config.width,
                    .height = config.height,
                    .output_format = config.output_format,
                };

                const decoder = try videotoolbox.VTDecoder.init(allocator, vt_config);
                break :blk .{ .videotoolbox = decoder };
            },
            .vaapi => blk: {
                const va_profile = switch (config.codec) {
                    .h264 => vaapi.VAProfile.h264_high,
                    .hevc => vaapi.VAProfile.hevc_main,
                    else => return error.UnsupportedCodec,
                };

                const va_config = vaapi.VADecoderConfig{
                    .profile = va_profile,
                    .width = config.width,
                    .height = config.height,
                    .output_format = config.output_format,
                };

                const decoder = try vaapi.VADecoder.init(allocator, device.vaapi, va_config);
                break :blk .{ .vaapi = decoder };
            },
            .nvenc => blk: {
                const nv_codec = switch (config.codec) {
                    .h264 => nvenc.NVENCCodec.h264,
                    .hevc => nvenc.NVENCCodec.hevc,
                    else => return error.UnsupportedCodec,
                };

                const nv_config = nvenc.NVDECDecoderConfig{
                    .codec = nv_codec,
                    .max_width = config.width,
                    .max_height = config.height,
                    .output_format = config.output_format,
                };

                const decoder = try nvenc.NVDECDecoder.init(allocator, device.nvenc, nv_config);
                break :blk .{ .nvenc = decoder };
            },
            .d3d11 => blk: {
                const d3d_profile = switch (config.codec) {
                    .h264 => d3d11.D3D11Profile.h264_vld,
                    .hevc => d3d11.D3D11Profile.hevc_main,
                    else => return error.UnsupportedCodec,
                },

                const d3d_config = d3d11.D3D11DecoderConfig{
                    .profile = d3d_profile,
                    .width = config.width,
                    .height = config.height,
                    .output_format = config.output_format,
                };

                const decoder = try d3d11.D3D11Decoder.init(allocator, device.d3d11, d3d_config);
                break :blk .{ .d3d11 = decoder };
            },
            else => return error.UnsupportedBackend,
        };

        return .{
            .allocator = allocator,
            .device = device,
            .config = config,
            .backend = backend,
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.backend) {
            .videotoolbox => |*dec| dec.deinit(),
            .vaapi => |*dec| dec.deinit(),
            .nvenc => |*dec| dec.deinit(),
            .d3d11 => |*dec| dec.deinit(),
            else => {},
        }
    }

    pub fn decode(self: *Self, packet: *const EncodedPacket) !?*core.VideoFrame {
        return switch (self.backend) {
            .videotoolbox => |*dec| try dec.decode(packet),
            .vaapi => |*dec| try dec.decode(packet),
            .nvenc => |*dec| try dec.decode(packet),
            .d3d11 => |*dec| try dec.decode(packet),
            else => null,
        };
    }

    pub fn flush(self: *Self) !void {
        switch (self.backend) {
            .videotoolbox => |*dec| try dec.flush(),
            .vaapi => |*dec| try dec.flush(),
            .nvenc => |*dec| try dec.flush(),
            .d3d11 => |*dec| try dec.flush(),
            else => {},
        }
    }
};

/// Encoded packet (unified)
pub const EncodedPacket = struct {
    data: []const u8,
    size: usize,
    pts: core.Timestamp,
    dts: core.Timestamp,
    is_keyframe: bool,
};

/// Hardware capabilities (unified)
pub const HWCapabilities = struct {
    const Self = @This();

    /// Get default hardware acceleration backend for the current platform
    pub fn getDefaultBackend() HWAccelType {
        return switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => .videotoolbox,
            .linux => .vaapi, // Prefer VA-API on Linux
            .windows => .d3d11,
            else => .none,
        };
    }

    /// List all available hardware devices
    pub fn listDevices(allocator: std.mem.Allocator) ![]HWDevice {
        var devices = std.ArrayList(HWDevice).init(allocator);

        // Check platform-specific backends
        switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => {
                if (videotoolbox.VTCapabilities.isAvailable()) {
                    const vt_devices = try videotoolbox.VTCapabilities.listDevices(allocator);
                    for (vt_devices) |*dev| {
                        try devices.append(.{ .videotoolbox = dev });
                    }
                }
            },
            .linux => {
                if (vaapi.VACapabilities.isAvailable()) {
                    const va_devices = try vaapi.VACapabilities.listDevices(allocator);
                    for (va_devices) |*dev| {
                        try devices.append(.{ .vaapi = dev });
                    }
                }
            },
            .windows => {
                if (d3d11.D3D11Capabilities.isAvailable()) {
                    const d3d_adapters = try d3d11.D3D11Capabilities.listAdapters(allocator);
                    for (d3d_adapters) |*adapter| {
                        try devices.append(.{ .d3d11 = adapter });
                    }
                }
            },
            else => {},
        }

        // Check NVIDIA devices (cross-platform)
        if (nvenc.NVIDIACapabilities.isAvailable()) {
            const nv_devices = try nvenc.NVIDIACapabilities.listDevices(allocator);
            for (nv_devices) |*dev| {
                try devices.append(.{ .nvenc = dev });
            }
        }

        return devices.toOwnedSlice();
    }

    /// Check if a specific codec is supported
    pub fn supportsCodec(device: HWDevice, codec: HWCodec) bool {
        return switch (device) {
            .videotoolbox => videotoolbox.VTCapabilities.supportsCodec(switch (codec) {
                .h264 => .h264,
                .hevc => .hevc,
                .prores => .prores,
                else => return false,
            }),
            .vaapi => true, // VA-API typically supports most codecs
            .nvenc => true, // NVENC supports H.264, HEVC, AV1
            .d3d11 => true, // D3D11 supports most modern codecs
            else => false,
        };
    }
};
