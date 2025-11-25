// Home Video Library - D3D11 Video Hardware Acceleration (Windows)
// Direct3D 11 Video API for hardware encoding/decoding on Windows

const std = @import("std");
const core = @import("../core.zig");

/// D3D11 video profile
pub const D3D11Profile = enum {
    h264_vld,
    h264_mvc,
    hevc_main,
    hevc_main10,
    vp9_profile0,
    vp9_profile2,
    av1_profile0,
    mpeg2_vld,
    vc1_vld,
    vc1_postproc,
    vc1_mocomp,
};

/// D3D11 adapter (GPU)
pub const D3D11Adapter = struct {
    adapter_index: u32,
    description: []const u8,
    vendor_id: u32,
    device_id: u32,
    dedicated_video_memory: u64,
    dedicated_system_memory: u64,
    shared_system_memory: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, index: u32, desc: []const u8, vendor: u32, device: u32, video_mem: u64, sys_mem: u64, shared_mem: u64) !Self {
        return .{
            .allocator = allocator,
            .adapter_index = index,
            .description = try allocator.dupe(u8, desc),
            .vendor_id = vendor,
            .device_id = device,
            .dedicated_video_memory = video_mem,
            .dedicated_system_memory = sys_mem,
            .shared_system_memory = shared_mem,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.description);
    }

    pub fn isNVIDIA(self: *const Self) bool {
        return self.vendor_id == 0x10DE;
    }

    pub fn isAMD(self: *const Self) bool {
        return self.vendor_id == 0x1002;
    }

    pub fn isIntel(self: *const Self) bool {
        return self.vendor_id == 0x8086;
    }
};

/// D3D11 video encoder configuration
pub const D3D11EncoderConfig = struct {
    profile: D3D11Profile,
    width: u32,
    height: u32,
    fps: core.Rational,
    bitrate: u32, // bits per second
    max_bitrate: ?u32 = null,
    quality: u32 = 50, // 0-100
    gop_size: u32 = 30,
    use_b_frames: bool = true,
    low_latency: bool = false,

    const Self = @This();

    pub fn h264(width: u32, height: u32, bitrate: u32, fps: core.Rational) Self {
        return .{
            .profile = .h264_vld,
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

/// D3D11 video encoder
pub const D3D11Encoder = struct {
    adapter: *D3D11Adapter,
    config: D3D11EncoderConfig,
    frame_count: u64 = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, adapter: *D3D11Adapter, config: D3D11EncoderConfig) !Self {
        // Initialize D3D11 video encoder:
        // 1. D3D11CreateDevice()
        // 2. QueryInterface for ID3D11VideoDevice
        // 3. CreateVideoEncoder()
        // 4. CreateVideoEncoderHeap()

        return .{
            .allocator = allocator,
            .adapter = adapter,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Release D3D11 resources
    }

    pub fn encode(self: *Self, frame: *const core.VideoFrame) !EncodedPacket {
        // D3D11 video encoding:
        // 1. Create/reuse ID3D11Texture2D
        // 2. Upload frame data to texture
        // 3. EncodeFrame()
        // 4. GetEncodedData()

        self.frame_count += 1;

        const is_keyframe = (self.frame_count % self.config.gop_size) == 0;

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

/// D3D11 video decoder configuration
pub const D3D11DecoderConfig = struct {
    profile: D3D11Profile,
    width: u32,
    height: u32,
    output_format: core.PixelFormat = .yuv420p,
};

/// D3D11 video decoder
pub const D3D11Decoder = struct {
    adapter: *D3D11Adapter,
    config: D3D11DecoderConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, adapter: *D3D11Adapter, config: D3D11DecoderConfig) !Self {
        // Initialize D3D11 video decoder:
        // 1. D3D11CreateDevice()
        // 2. QueryInterface for ID3D11VideoDevice
        // 3. CreateVideoDecoder()
        // 4. CreateVideoDecoderOutputView()

        return .{
            .allocator = allocator,
            .adapter = adapter,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn decode(self: *Self, packet: *const EncodedPacket) !?*core.VideoFrame {
        // D3D11 video decoding:
        // 1. BeginFrame()
        // 2. SubmitDecoderBuffers()
        // 3. EndFrame()
        // 4. Download decoded texture to VideoFrame

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

/// D3D11 capability query
pub const D3D11Capabilities = struct {
    const Self = @This();

    pub fn isAvailable() bool {
        // Check if running on Windows and D3D11 is available
        if (@import("builtin").os.tag != .windows) {
            return false;
        }

        return true;
    }

    pub fn listAdapters(allocator: std.mem.Allocator) ![]D3D11Adapter {
        var adapters = std.ArrayList(D3D11Adapter).init(allocator);

        if (@import("builtin").os.tag != .windows) {
            return adapters.toOwnedSlice();
        }

        // Enumerate adapters:
        // CreateDXGIFactory()
        // EnumAdapters()
        // GetDesc()

        // Placeholder - would enumerate actual adapters
        return adapters.toOwnedSlice();
    }

    pub fn queryDecoderProfiles(adapter: *D3D11Adapter, allocator: std.mem.Allocator) ![]D3D11Profile {
        _ = adapter;

        var profiles = std.ArrayList(D3D11Profile).init(allocator);

        // GetVideoDecoderProfileCount()
        // GetVideoDecoderProfile()

        // Placeholder
        try profiles.append(.h264_vld);
        try profiles.append(.hevc_main);
        try profiles.append(.vp9_profile0);

        return profiles.toOwnedSlice();
    }

    pub fn checkFormatSupport(adapter: *D3D11Adapter, profile: D3D11Profile, width: u32, height: u32) bool {
        // CheckVideoDecoderFormat()
        // CheckVideoProcessorFormat()
        _ = adapter;
        _ = profile;
        _ = width;
        _ = height;

        return true; // Placeholder
    }
};

/// D3D11 texture/surface
pub const D3D11Texture = struct {
    width: u32,
    height: u32,
    format: core.PixelFormat,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: core.PixelFormat) !Self {
        // CreateTexture2D() with D3D11_BIND_DECODER or D3D11_BIND_VIDEO_ENCODER

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .format = format,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Release texture
    }

    pub fn upload(self: *Self, frame: *const core.VideoFrame) !void {
        // Map(), copy data, Unmap()
        // or UpdateSubresource()
        _ = self;
        _ = frame;
    }

    pub fn download(self: *Self) !core.VideoFrame {
        // Create staging texture
        // CopyResource()
        // Map(), copy data, Unmap()
        return try core.VideoFrame.init(self.allocator, self.width, self.height, self.format);
    }
};

/// D3D11 video processor (scaling, color conversion, deinterlacing)
pub const D3D11VideoProcessor = struct {
    adapter: *D3D11Adapter,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, adapter: *D3D11Adapter) !Self {
        // CreateVideoProcessorEnumerator()
        // CreateVideoProcessor()

        return .{
            .allocator = allocator,
            .adapter = adapter,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn process(self: *Self, input: *const core.VideoFrame, output_width: u32, output_height: u32, output_format: core.PixelFormat) !*core.VideoFrame {
        // VideoProcessorBlt()
        _ = self;

        const output = try self.allocator.create(core.VideoFrame);
        output.* = try core.VideoFrame.init(self.allocator, output_width, output_height, output_format);
        output.pts = input.pts;
        return output;
    }

    pub fn deinterlace(self: *Self, frame: *const core.VideoFrame) !*core.VideoFrame {
        // VideoProcessorSetStreamAutoProcessingMode() with auto-deinterlace
        // VideoProcessorBlt()
        _ = self;

        const output = try self.allocator.create(core.VideoFrame);
        output.* = try frame.clone(self.allocator);
        return output;
    }
};
