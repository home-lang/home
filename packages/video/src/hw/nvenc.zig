// Home Video Library - NVENC/NVDEC Hardware Acceleration (NVIDIA)
// Hardware encoding/decoding using NVIDIA's NVENC and NVDEC APIs

const std = @import("std");
const core = @import("../core.zig");

/// NVENC codec GUID
pub const NVENCCodec = enum {
    h264,
    hevc,
    av1,
};

/// NVENC preset (quality vs speed)
pub const NVENCPreset = enum {
    p1, // Fastest (lowest quality)
    p2,
    p3,
    p4, // Balanced
    p5,
    p6,
    p7, // Slowest (highest quality)
};

/// NVENC tuning info
pub const NVENCTuningInfo = enum {
    high_quality,
    low_latency,
    ultra_low_latency,
    lossless,
};

/// NVENC rate control mode
pub const NVENCRateControl = enum {
    constqp, // Constant QP
    vbr, // Variable bitrate
    cbr, // Constant bitrate
};

/// NVENC multi-pass mode
pub const NVENCMultiPass = enum {
    disabled,
    quarter_resolution,
    full_resolution,
};

/// NVIDIA device information
pub const NVIDIADevice = struct {
    device_id: u32,
    name: []const u8,
    compute_capability: struct {
        major: u32,
        minor: u32,
    },
    total_memory: u64, // bytes
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device_id: u32, name: []const u8, compute_major: u32, compute_minor: u32, memory: u64) !Self {
        return .{
            .allocator = allocator,
            .device_id = device_id,
            .name = try allocator.dupe(u8, name),
            .compute_capability = .{
                .major = compute_major,
                .minor = compute_minor,
            },
            .total_memory = memory,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
    }
};

/// NVENC encoder configuration
pub const NVENCEncoderConfig = struct {
    codec: NVENCCodec,
    width: u32,
    height: u32,
    fps: core.Rational,
    bitrate: u32, // bits per second
    max_bitrate: u32,
    preset: NVENCPreset = .p4,
    tuning_info: NVENCTuningInfo = .high_quality,
    rc_mode: NVENCRateControl = .vbr,
    multi_pass: NVENCMultiPass = .quarter_resolution,
    gop_length: u32 = 250, // IDR interval
    num_b_frames: u32 = 2,
    enable_weighted_prediction: bool = true,
    enable_temporal_aq: bool = true,
    enable_spatial_aq: bool = true,
    aq_strength: u32 = 8, // 1-15
    lookahead: u32 = 0, // 0 = disabled, up to 32
    strict_gop: bool = false,

    const Self = @This();

    pub fn h264(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .codec = .h264,
            .width = width,
            .height = height,
            .bitrate = bitrate,
            .max_bitrate = bitrate * 2,
            .fps = fps,
        };
    }

    pub fn hevc(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .codec = .hevc,
            .width = width,
            .height = height,
            .bitrate = bitrate,
            .max_bitrate = bitrate * 2,
            .fps = fps,
        };
    }

    pub fn lowLatency(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .codec = .h264,
            .width = width,
            .height = height,
            .bitrate = bitrate,
            .max_bitrate = bitrate * 2,
            .fps = fps,
            .preset = .p1,
            .tuning_info = .ultra_low_latency,
            .rc_mode = .cbr,
            .gop_length = 60,
            .num_b_frames = 0,
            .lookahead = 0,
        };
    }
};

/// NVENC hardware encoder
pub const NVENCEncoder = struct {
    device: *NVIDIADevice,
    config: NVENCEncoderConfig,
    frame_count: u64 = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *NVIDIADevice, config: NVENCEncoderConfig) !Self {
        // Initialize NVENC:
        // 1. NvEncodeAPICreateInstance()
        // 2. NvEncOpenEncodeSessionEx()
        // 3. NvEncGetEncodeGUIDCount(), NvEncGetEncodeGUIDs()
        // 4. NvEncInitializeEncoder()

        return .{
            .allocator = allocator,
            .device = device,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // NvEncDestroyEncoder()
    }

    pub fn encode(self: *Self, frame: *const core.VideoFrame) !EncodedPacket {
        // NVENC encoding:
        // 1. Upload frame to CUDA memory (if not already there)
        // 2. NvEncMapInputResource()
        // 3. NvEncEncodePicture()
        // 4. NvEncLockBitstream() - get encoded data
        // 5. Copy data
        // 6. NvEncUnlockBitstream()
        // 7. NvEncUnmapInputResource()

        self.frame_count += 1;

        const is_keyframe = (self.frame_count % self.config.gop_length) == 0;

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
        // NvEncEncodePicture() with NV_ENC_PIC_PARAMS::encodePicFlags = NV_ENC_PIC_FLAG_EOS
        return null;
    }

    pub fn reconfigure(self: *Self, new_config: NVENCEncoderConfig) !void {
        // NvEncReconfigureEncoder()
        self.config = new_config;
    }
};

/// NVDEC decoder configuration
pub const NVDECDecoderConfig = struct {
    codec: NVENCCodec,
    max_width: u32,
    max_height: u32,
    output_format: core.PixelFormat = .yuv420p,
    max_decode_surfaces: u32 = 20,
};

/// NVDEC hardware decoder
pub const NVDECDecoder = struct {
    device: *NVIDIADevice,
    config: NVDECDecoderConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *NVIDIADevice, config: NVDECDecoderConfig) !Self {
        // Initialize NVDEC:
        // 1. cuvidCreateDecoder()
        // 2. cuvidCreateVideoParser()

        return .{
            .allocator = allocator,
            .device = device,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // cuvidDestroyDecoder()
        // cuvidDestroyVideoParser()
    }

    pub fn decode(self: *Self, packet: *const EncodedPacket) !?*core.VideoFrame {
        // NVDEC decoding:
        // 1. cuvidParseVideoData() - parse packet
        // 2. In callback: cuvidDecodePicture()
        // 3. cuvidMapVideoFrame() - get decoded surface
        // 4. Copy to VideoFrame
        // 5. cuvidUnmapVideoFrame()

        const frame = try self.allocator.create(core.VideoFrame);
        frame.* = try core.VideoFrame.init(
            self.allocator,
            self.config.max_width,
            self.config.max_height,
            self.config.output_format,
        );

        frame.pts = packet.pts;

        return frame;
    }

    pub fn flush(self: *Self) !void {
        _ = self;
        // cuvidParseVideoData() with CUVID_PKT_ENDOFSTREAM
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

/// NVIDIA capability query
pub const NVIDIACapabilities = struct {
    const Self = @This();

    pub fn isAvailable() bool {
        // Check if CUDA/NVENC is available
        // Would call cuInit() and check for devices
        return false; // Placeholder
    }

    pub fn listDevices(allocator: std.mem.Allocator) ![]NVIDIADevice {
        var devices = std.ArrayList(NVIDIADevice).init(allocator);

        // cuDeviceGetCount()
        // For each device:
        //   cuDeviceGet()
        //   cuDeviceGetName()
        //   cuDeviceComputeCapability()
        //   cuDeviceTotalMem()

        // Placeholder
        return devices.toOwnedSlice();
    }

    pub fn queryEncoderCaps(device: *NVIDIADevice, codec: NVENCCodec) EncoderCaps {
        _ = device;
        _ = codec;

        // NvEncGetEncodeCaps()
        return .{
            .max_width = 8192,
            .max_height = 8192,
            .max_level = 62, // H.264 Level 6.2
            .supports_temporal_aq = true,
            .supports_spatial_aq = true,
            .supports_lookahead = true,
            .supports_weighted_prediction = true,
            .max_bframes = 4,
            .max_lookahead_depth = 32,
        };
    }

    pub fn queryDecoderCaps(device: *NVIDIADevice, codec: NVENCCodec) DecoderCaps {
        _ = device;
        _ = codec;

        // cuvidGetDecoderCaps()
        return .{
            .max_width = 8192,
            .max_height = 8192,
            .max_mb_count = 0, // 0 = no limit
            .min_width = 48,
            .min_height = 16,
            .supports_10bit = true,
            .supports_12bit = false,
        };
    }
};

pub const EncoderCaps = struct {
    max_width: u32,
    max_height: u32,
    max_level: u32,
    supports_temporal_aq: bool,
    supports_spatial_aq: bool,
    supports_lookahead: bool,
    supports_weighted_prediction: bool,
    max_bframes: u32,
    max_lookahead_depth: u32,
};

pub const DecoderCaps = struct {
    max_width: u32,
    max_height: u32,
    max_mb_count: u32,
    min_width: u32,
    min_height: u32,
    supports_10bit: bool,
    supports_12bit: bool,
};

/// CUDA memory buffer
pub const CUDABuffer = struct {
    device_ptr: usize, // CUdeviceptr
    size: usize,
    device: *NVIDIADevice,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *NVIDIADevice, size: usize) !Self {
        // cuMemAlloc()

        return .{
            .allocator = allocator,
            .device = device,
            .device_ptr = 0, // Placeholder
            .size = size,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // cuMemFree()
    }

    pub fn upload(self: *Self, data: []const u8) !void {
        // cuMemcpyHtoD()
        _ = self;
        _ = data;
    }

    pub fn download(self: *Self, data: []u8) !void {
        // cuMemcpyDtoH()
        _ = self;
        _ = data;
    }
};

/// CUDA stream for async operations
pub const CUDAStream = struct {
    stream_handle: usize, // CUstream
    device: *NVIDIADevice,

    const Self = @This();

    pub fn init(device: *NVIDIADevice) !Self {
        // cuStreamCreate()

        return .{
            .device = device,
            .stream_handle = 0, // Placeholder
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // cuStreamDestroy()
    }

    pub fn synchronize(self: *Self) !void {
        // cuStreamSynchronize()
        _ = self;
    }
};
