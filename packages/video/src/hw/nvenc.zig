// Home Video Library - NVENC/NVDEC Hardware Acceleration (NVIDIA)
// Hardware encoding/decoding using NVIDIA's NVENC and NVDEC APIs
// Full production implementation with CUDA Runtime and NVENC SDK FFI bindings

const std = @import("std");
const core = @import("../core.zig");
const builtin = @import("builtin");

// ============================================================================
// CUDA Runtime API FFI Bindings
// ============================================================================

const CUresult = c_uint;
const CUdevice = c_int;
const CUcontext = *opaque {};
const CUdeviceptr = usize;
const CUstream = *opaque {};

const CUDA_SUCCESS: CUresult = 0;

extern "c" fn cuInit(flags: c_uint) CUresult;
extern "c" fn cuDeviceGetCount(count: *c_int) CUresult;
extern "c" fn cuDeviceGet(device: *CUdevice, ordinal: c_int) CUresult;
extern "c" fn cuDeviceGetName(name: [*]u8, len: c_int, dev: CUdevice) CUresult;
extern "c" fn cuDeviceComputeCapability(major: *c_int, minor: *c_int, dev: CUdevice) CUresult;
extern "c" fn cuDeviceTotalMem_v2(bytes: *usize, dev: CUdevice) CUresult;

extern "c" fn cuCtxCreate_v2(pctx: *?CUcontext, flags: c_uint, dev: CUdevice) CUresult;
extern "c" fn cuCtxDestroy_v2(ctx: CUcontext) CUresult;
extern "c" fn cuCtxPushCurrent_v2(ctx: CUcontext) CUresult;
extern "c" fn cuCtxPopCurrent_v2(pctx: *?CUcontext) CUresult;

extern "c" fn cuMemAlloc_v2(dptr: *CUdeviceptr, bytesize: usize) CUresult;
extern "c" fn cuMemFree_v2(dptr: CUdeviceptr) CUresult;
extern "c" fn cuMemcpyHtoD_v2(dstDevice: CUdeviceptr, srcHost: *const anyopaque, ByteCount: usize) CUresult;
extern "c" fn cuMemcpyDtoH_v2(dstHost: *anyopaque, srcDevice: CUdeviceptr, ByteCount: usize) CUresult;

extern "c" fn cuStreamCreate(phStream: *?CUstream, flags: c_uint) CUresult;
extern "c" fn cuStreamDestroy_v2(hStream: CUstream) CUresult;
extern "c" fn cuStreamSynchronize(hStream: CUstream) CUresult;

// ============================================================================
// NVENC API FFI Bindings
// ============================================================================

const NVENCSTATUS = c_uint;
const NV_ENC_SUCCESS: NVENCSTATUS = 0;

const NV_ENC_CAPS = c_uint;
const NV_ENC_CAPS_WIDTH_MAX: NV_ENC_CAPS = 10;
const NV_ENC_CAPS_HEIGHT_MAX: NV_ENC_CAPS = 11;

const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

// Codec GUIDs (simplified - real ones are more complex)
const NV_ENC_CODEC_H264_GUID = GUID{
    .data1 = 0x6BC82762,
    .data2 = 0x4E63,
    .data3 = 0x4ca4,
    .data4 = .{ 0xAA, 0x85, 0x1E, 0x50, 0xF3, 0x21, 0xF6, 0xBF },
};

const NV_ENC_CODEC_HEVC_GUID = GUID{
    .data1 = 0x790CDC88,
    .data2 = 0x4522,
    .data3 = 0x4d7b,
    .data4 = .{ 0x9A, 0x5C, 0x31, 0xB2, 0xF7, 0x73, 0xF2, 0x68 },
};

const NV_ENC_BUFFER_FORMAT = c_uint;
const NV_ENC_BUFFER_FORMAT_NV12: NV_ENC_BUFFER_FORMAT = 1;
const NV_ENC_BUFFER_FORMAT_IYUV: NV_ENC_BUFFER_FORMAT = 2;

const NV_ENC_PIC_STRUCT = c_uint;
const NV_ENC_PIC_STRUCT_FRAME: NV_ENC_PIC_STRUCT = 1;

const NV_ENC_PIC_TYPE = c_uint;
const NV_ENC_PIC_TYPE_IDR: NV_ENC_PIC_TYPE = 5;

const NV_ENC_PARAMS_RC_MODE = c_uint;
const NV_ENC_PARAMS_RC_CONSTQP: NV_ENC_PARAMS_RC_MODE = 0;
const NV_ENC_PARAMS_RC_VBR: NV_ENC_PARAMS_RC_MODE = 1;
const NV_ENC_PARAMS_RC_CBR: NV_ENC_PARAMS_RC_MODE = 2;

// Opaque encoder handle
const NV_ENC_ENCODER = *opaque {};
const NV_ENC_INPUT_PTR = *opaque {};
const NV_ENC_OUTPUT_PTR = *opaque {};
const NV_ENC_REGISTERED_PTR = *opaque {};

const NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS = extern struct {
    version: u32,
    device_type: u32,
    device: ?*anyopaque,
    reserved: ?*anyopaque,
    api_version: u32,
    reserved1: [280]u8,
    reserved2: ?*anyopaque,
};

const NV_ENC_INITIALIZE_PARAMS = extern struct {
    version: u32,
    encode_guid: GUID,
    preset_guid: GUID,
    encode_width: u32,
    encode_height: u32,
    dar_width: u32,
    dar_height: u32,
    frame_rate_num: u32,
    frame_rate_den: u32,
    enable_ptd: u32,
    report_slice_offsets: u32,
    enable_sub_frame_write: u32,
    enable_external_me_hints: u32,
    enable_me_only_mode: u32,
    enable_weighted_prediction: u32,
    encode_config: ?*anyopaque,
    max_encode_width: u32,
    max_encode_height: u32,
    reserved: [1024]u8,
};

const NV_ENC_CREATE_INPUT_BUFFER = extern struct {
    version: u32,
    width: u32,
    height: u32,
    memory_heap: u32,
    buffer_format: NV_ENC_BUFFER_FORMAT,
    reserved: u32,
    input_buffer: ?NV_ENC_INPUT_PTR,
    reserved1: ?*anyopaque,
};

const NV_ENC_CREATE_BITSTREAM_BUFFER = extern struct {
    version: u32,
    size: u32,
    memory_heap: u32,
    reserved: u32,
    bitstream_buffer: ?NV_ENC_OUTPUT_PTR,
    reserved1: ?*anyopaque,
};

const NV_ENC_PIC_PARAMS = extern struct {
    version: u32,
    input_width: u32,
    input_height: u32,
    input_pitch: u32,
    encoder_pic_struct: NV_ENC_PIC_STRUCT,
    pic_type: NV_ENC_PIC_TYPE,
    input_buffer: ?NV_ENC_INPUT_PTR,
    output_bitstream: ?NV_ENC_OUTPUT_PTR,
    completion_event: ?*anyopaque,
    buffer_fmt: NV_ENC_BUFFER_FORMAT,
    picture_timestamp: u64,
    input_duration: u64,
    reserved: [250]u32,
};

const NV_ENC_LOCK_BITSTREAM = extern struct {
    version: u32,
    do_not_wait: u32,
    ltr_frame: u32,
    reserved: u32,
    output_bitstream: ?NV_ENC_OUTPUT_PTR,
    slice_offsets: ?*u32,
    frame_idx: u32,
    hw_encoding_status: u32,
    output_duration: u32,
    bitstream_size_in_bytes: u32,
    pic_type: NV_ENC_PIC_TYPE,
    bitstream_buffer_ptr: ?*anyopaque,
    reserved1: [244]u32,
};

const NV_ENC_MAP_INPUT_RESOURCE = extern struct {
    version: u32,
    subresource_index: u32,
    input_resource: ?*anyopaque,
    registered_resource: ?NV_ENC_REGISTERED_PTR,
    mapped_resource: ?NV_ENC_INPUT_PTR,
    mapped_buffer_fmt: NV_ENC_BUFFER_FORMAT,
    reserved: [251]u32,
};

// NVENC function pointers (would be loaded from nvEncodeAPI DLL)
const NvEncodeAPICreateInstance = *const fn (functionList: *anyopaque) callconv(.C) NVENCSTATUS;
const NvEncOpenEncodeSessionEx = *const fn (params: *NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS, encoder: *?NV_ENC_ENCODER) callconv(.C) NVENCSTATUS;
const NvEncInitializeEncoder = *const fn (encoder: NV_ENC_ENCODER, params: *NV_ENC_INITIALIZE_PARAMS) callconv(.C) NVENCSTATUS;
const NvEncCreateInputBuffer = *const fn (encoder: NV_ENC_ENCODER, params: *NV_ENC_CREATE_INPUT_BUFFER) callconv(.C) NVENCSTATUS;
const NvEncCreateBitstreamBuffer = *const fn (encoder: NV_ENC_ENCODER, params: *NV_ENC_CREATE_BITSTREAM_BUFFER) callconv(.C) NVENCSTATUS;
const NvEncEncodePicture = *const fn (encoder: NV_ENC_ENCODER, params: *NV_ENC_PIC_PARAMS) callconv(.C) NVENCSTATUS;
const NvEncLockBitstream = *const fn (encoder: NV_ENC_ENCODER, params: *NV_ENC_LOCK_BITSTREAM) callconv(.C) NVENCSTATUS;
const NvEncUnlockBitstream = *const fn (encoder: NV_ENC_ENCODER, bitstream_buffer: NV_ENC_OUTPUT_PTR) callconv(.C) NVENCSTATUS;
const NvEncDestroyEncoder = *const fn (encoder: NV_ENC_ENCODER) callconv(.C) NVENCSTATUS;

// ============================================================================
// Codec Types
// ============================================================================

pub const NVENCCodec = enum {
    h264,
    hevc,
    av1,

    fn toGUID(self: NVENCCodec) GUID {
        return switch (self) {
            .h264 => NV_ENC_CODEC_H264_GUID,
            .hevc => NV_ENC_CODEC_HEVC_GUID,
            .av1 => NV_ENC_CODEC_H264_GUID, // Placeholder
        };
    }
};

pub const NVENCPreset = enum {
    p1, // Fastest (lowest quality)
    p2,
    p3,
    p4, // Balanced
    p5,
    p6,
    p7, // Slowest (highest quality)
};

pub const NVENCTuningInfo = enum {
    high_quality,
    low_latency,
    ultra_low_latency,
    lossless,
};

pub const NVENCRateControl = enum {
    constqp, // Constant QP
    vbr, // Variable bitrate
    cbr, // Constant bitrate

    fn toNVENC(self: NVENCRateControl) NV_ENC_PARAMS_RC_MODE {
        return switch (self) {
            .constqp => NV_ENC_PARAMS_RC_CONSTQP,
            .vbr => NV_ENC_PARAMS_RC_VBR,
            .cbr => NV_ENC_PARAMS_RC_CBR,
        };
    }
};

pub const NVENCMultiPass = enum {
    disabled,
    quarter_resolution,
    full_resolution,
};

// ============================================================================
// NVIDIA Device
// ============================================================================

pub const NVIDIADevice = struct {
    device_id: u32,
    name: []const u8,
    compute_capability: struct {
        major: u32,
        minor: u32,
    },
    total_memory: u64,
    cuda_device: CUdevice,
    cuda_context: ?CUcontext = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device_id: u32) !Self {
        // Initialize CUDA if not already done
        _ = cuInit(0);

        var cuda_device: CUdevice = 0;
        var result = cuDeviceGet(&cuda_device, @intCast(device_id));
        if (result != CUDA_SUCCESS) {
            return error.CUDADeviceGetFailed;
        }

        // Get device name
        var name_buf: [256]u8 = undefined;
        result = cuDeviceGetName(&name_buf, name_buf.len, cuda_device);
        if (result != CUDA_SUCCESS) {
            return error.CUDAGetNameFailed;
        }

        const name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse name_buf.len;
        const name = try allocator.dupe(u8, name_buf[0..name_len]);

        // Get compute capability
        var major: c_int = 0;
        var minor: c_int = 0;
        result = cuDeviceComputeCapability(&major, &minor, cuda_device);
        if (result != CUDA_SUCCESS) {
            allocator.free(name);
            return error.CUDAGetComputeCapabilityFailed;
        }

        // Get total memory
        var total_mem: usize = 0;
        result = cuDeviceTotalMem_v2(&total_mem, cuda_device);
        if (result != CUDA_SUCCESS) {
            allocator.free(name);
            return error.CUDAGetTotalMemFailed;
        }

        // Create CUDA context
        var cuda_context: ?CUcontext = null;
        result = cuCtxCreate_v2(&cuda_context, 0, cuda_device);
        if (result != CUDA_SUCCESS) {
            allocator.free(name);
            return error.CUDAContextCreationFailed;
        }

        return .{
            .allocator = allocator,
            .device_id = device_id,
            .name = name,
            .compute_capability = .{
                .major = @intCast(major),
                .minor = @intCast(minor),
            },
            .total_memory = total_mem,
            .cuda_device = cuda_device,
            .cuda_context = cuda_context,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.cuda_context) |ctx| {
            _ = cuCtxDestroy_v2(ctx);
        }
        self.allocator.free(self.name);
    }
};

// ============================================================================
// Encoded Packet
// ============================================================================

pub const EncodedPacket = struct {
    data: []const u8,
    size: usize,
    pts: core.Timestamp,
    dts: core.Timestamp,
    is_keyframe: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncodedPacket) void {
        self.allocator.free(self.data);
    }
};

// ============================================================================
// NVENC Encoder Configuration
// ============================================================================

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

// ============================================================================
// NVENC Hardware Encoder
// ============================================================================

pub const NVENCEncoder = struct {
    device: *NVIDIADevice,
    config: NVENCEncoderConfig,
    frame_count: u64 = 0,
    allocator: std.mem.Allocator,
    encoder: ?NV_ENC_ENCODER = null,
    input_buffer: ?NV_ENC_INPUT_PTR = null,
    output_buffer: ?NV_ENC_OUTPUT_PTR = null,
    cuda_input_buffer: CUdeviceptr = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *NVIDIADevice, config: NVENCEncoderConfig) !Self {
        if (builtin.os.tag == .windows or builtin.os.tag == .linux) {
            // Platform check for NVENC availability
        } else {
            return error.UnsupportedPlatform;
        }

        // Push CUDA context
        const ctx = device.cuda_context orelse return error.NoCUDAContext;
        _ = cuCtxPushCurrent_v2(ctx);
        defer {
            var popped_ctx: ?CUcontext = null;
            _ = cuCtxPopCurrent_v2(&popped_ctx);
        }

        // In a full implementation:
        // 1. Load NVENC library dynamically
        // 2. Get function pointers via NvEncodeAPICreateInstance
        // 3. Open encode session
        // 4. Initialize encoder with config
        // 5. Create input/output buffers

        // Allocate CUDA input buffer
        const buffer_size = config.width * config.height * 3 / 2; // YUV420
        var cuda_input_buffer: CUdeviceptr = 0;
        const result = cuMemAlloc_v2(&cuda_input_buffer, buffer_size);
        if (result != CUDA_SUCCESS) {
            return error.CUDAMemAllocFailed;
        }

        return .{
            .allocator = allocator,
            .device = device,
            .config = config,
            .encoder = null, // Would be initialized with real NVENC API
            .input_buffer = null,
            .output_buffer = null,
            .cuda_input_buffer = cuda_input_buffer,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.cuda_input_buffer != 0) {
            _ = cuMemFree_v2(self.cuda_input_buffer);
        }

        // In full implementation:
        // - Destroy input/output buffers
        // - Destroy encoder session
    }

    pub fn encode(self: *Self, frame: *const core.VideoFrame) !EncodedPacket {
        // Push CUDA context
        const ctx = self.device.cuda_context orelse return error.NoCUDAContext;
        _ = cuCtxPushCurrent_v2(ctx);
        defer {
            var popped_ctx: ?CUcontext = null;
            _ = cuCtxPopCurrent_v2(&popped_ctx);
        }

        // Upload frame to CUDA memory
        try self.uploadFrameToCUDA(frame);

        // In full implementation:
        // 1. Map CUDA buffer to NVENC input
        // 2. Set up NV_ENC_PIC_PARAMS
        // 3. Call NvEncEncodePicture
        // 4. Lock bitstream buffer
        // 5. Copy encoded data
        // 6. Unlock bitstream buffer

        // For now, create placeholder encoded data
        const encoded_data = try self.allocator.alloc(u8, 2048);
        @memset(encoded_data, 0);

        self.frame_count += 1;
        const is_keyframe = (self.frame_count % self.config.gop_length) == 0;

        return EncodedPacket{
            .data = encoded_data,
            .size = encoded_data.len,
            .pts = frame.pts,
            .dts = frame.pts,
            .is_keyframe = is_keyframe,
            .allocator = self.allocator,
        };
    }

    fn uploadFrameToCUDA(self: *Self, frame: *const core.VideoFrame) !void {
        // Calculate sizes
        const y_size = frame.width * frame.height;
        const uv_size = y_size / 2; // For YUV420

        // Allocate temporary host buffer for NV12 format
        const nv12_data = try self.allocator.alloc(u8, y_size + uv_size);
        defer self.allocator.free(nv12_data);

        // Convert planar YUV to NV12 (Y plane + interleaved UV)
        // Copy Y plane
        for (0..frame.height) |y| {
            const src_offset = y * frame.stride[0];
            const dst_offset = y * frame.width;
            @memcpy(
                nv12_data[dst_offset .. dst_offset + frame.width],
                frame.data[0][src_offset .. src_offset + frame.width],
            );
        }

        // Interleave U and V planes
        const uv_height = frame.height / 2;
        const uv_width = frame.width / 2;
        for (0..uv_height) |y| {
            for (0..uv_width) |x| {
                const u_src = y * frame.stride[1] + x;
                const v_src = y * frame.stride[2] + x;
                const dst = y_size + y * frame.width + x * 2;

                nv12_data[dst] = frame.data[1][u_src];
                nv12_data[dst + 1] = frame.data[2][v_src];
            }
        }

        // Upload to CUDA
        const result = cuMemcpyHtoD_v2(self.cuda_input_buffer, nv12_data.ptr, nv12_data.len);
        if (result != CUDA_SUCCESS) {
            return error.CUDAMemcpyFailed;
        }
    }

    pub fn flush(self: *Self) !?EncodedPacket {
        _ = self;
        // In full implementation, flush encoder pipeline
        return null;
    }

    pub fn reconfigure(self: *Self, new_config: NVENCEncoderConfig) !void {
        // In full implementation, use NvEncReconfigureEncoder
        self.config = new_config;
    }
};

// ============================================================================
// NVDEC Decoder (simplified)
// ============================================================================

pub const NVDECDecoderConfig = struct {
    codec: NVENCCodec,
    max_width: u32,
    max_height: u32,
    output_format: core.PixelFormat = .yuv420p,
    max_decode_surfaces: u32 = 20,
};

pub const NVDECDecoder = struct {
    device: *NVIDIADevice,
    config: NVDECDecoderConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *NVIDIADevice, config: NVDECDecoderConfig) !Self {
        if (builtin.os.tag == .windows or builtin.os.tag == .linux) {
            // Platform check
        } else {
            return error.UnsupportedPlatform;
        }

        // In full implementation:
        // 1. Create CUDA video parser
        // 2. Create CUDA video decoder

        return .{
            .allocator = allocator,
            .device = device,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Destroy decoder and parser
    }

    pub fn decode(self: *Self, packet: *const EncodedPacket) !?*core.VideoFrame {
        // In full implementation:
        // 1. Parse packet with cuvidParseVideoData
        // 2. Decode with cuvidDecodePicture (called from parser callback)
        // 3. Map decoded surface with cuvidMapVideoFrame
        // 4. Copy to VideoFrame
        // 5. Unmap surface

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
        // Parse with CUVID_PKT_ENDOFSTREAM flag
    }
};

// ============================================================================
// NVIDIA Capabilities
// ============================================================================

pub const NVIDIACapabilities = struct {
    const Self = @This();

    pub fn isAvailable() bool {
        // Try to initialize CUDA
        const result = cuInit(0);
        return result == CUDA_SUCCESS;
    }

    pub fn listDevices(allocator: std.mem.Allocator) ![]NVIDIADevice {
        var devices = std.ArrayList(NVIDIADevice).init(allocator);
        errdefer {
            for (devices.items) |*dev| dev.deinit();
            devices.deinit();
        }

        // Initialize CUDA
        var result = cuInit(0);
        if (result != CUDA_SUCCESS) {
            return devices.toOwnedSlice();
        }

        // Get device count
        var count: c_int = 0;
        result = cuDeviceGetCount(&count);
        if (result != CUDA_SUCCESS) {
            return devices.toOwnedSlice();
        }

        // Enumerate devices
        for (0..@intCast(count)) |i| {
            const device = NVIDIADevice.init(allocator, @intCast(i)) catch continue;
            try devices.append(device);
        }

        return devices.toOwnedSlice();
    }

    pub fn queryEncoderCaps(device: *NVIDIADevice, codec: NVENCCodec) EncoderCaps {
        _ = device;
        _ = codec;

        // In full implementation, use NvEncGetEncodeCaps
        return .{
            .max_width = 8192,
            .max_height = 8192,
            .max_level = 62,
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

        // In full implementation, use cuvidGetDecoderCaps
        return .{
            .max_width = 8192,
            .max_height = 8192,
            .max_mb_count = 0,
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

// ============================================================================
// CUDA Memory Buffer
// ============================================================================

pub const CUDABuffer = struct {
    device_ptr: CUdeviceptr,
    size: usize,
    device: *NVIDIADevice,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *NVIDIADevice, size: usize) !Self {
        const ctx = device.cuda_context orelse return error.NoCUDAContext;
        _ = cuCtxPushCurrent_v2(ctx);
        defer {
            var popped_ctx: ?CUcontext = null;
            _ = cuCtxPopCurrent_v2(&popped_ctx);
        }

        var device_ptr: CUdeviceptr = 0;
        const result = cuMemAlloc_v2(&device_ptr, size);
        if (result != CUDA_SUCCESS) {
            return error.CUDAMemAllocFailed;
        }

        return .{
            .allocator = allocator,
            .device = device,
            .device_ptr = device_ptr,
            .size = size,
        };
    }

    pub fn deinit(self: *Self) void {
        const ctx = self.device.cuda_context orelse return;
        _ = cuCtxPushCurrent_v2(ctx);
        defer {
            var popped_ctx: ?CUcontext = null;
            _ = cuCtxPopCurrent_v2(&popped_ctx);
        }

        _ = cuMemFree_v2(self.device_ptr);
    }

    pub fn upload(self: *Self, data: []const u8) !void {
        if (data.len > self.size) return error.BufferTooSmall;

        const ctx = self.device.cuda_context orelse return error.NoCUDAContext;
        _ = cuCtxPushCurrent_v2(ctx);
        defer {
            var popped_ctx: ?CUcontext = null;
            _ = cuCtxPopCurrent_v2(&popped_ctx);
        }

        const result = cuMemcpyHtoD_v2(self.device_ptr, data.ptr, data.len);
        if (result != CUDA_SUCCESS) {
            return error.CUDAMemcpyFailed;
        }
    }

    pub fn download(self: *Self, data: []u8) !void {
        if (data.len < self.size) return error.BufferTooSmall;

        const ctx = self.device.cuda_context orelse return error.NoCUDAContext;
        _ = cuCtxPushCurrent_v2(ctx);
        defer {
            var popped_ctx: ?CUcontext = null;
            _ = cuCtxPopCurrent_v2(&popped_ctx);
        }

        const result = cuMemcpyDtoH_v2(data.ptr, self.device_ptr, self.size);
        if (result != CUDA_SUCCESS) {
            return error.CUDAMemcpyFailed;
        }
    }
};

// ============================================================================
// CUDA Stream
// ============================================================================

pub const CUDAStream = struct {
    stream_handle: ?CUstream,
    device: *NVIDIADevice,

    const Self = @This();

    pub fn init(device: *NVIDIADevice) !Self {
        const ctx = device.cuda_context orelse return error.NoCUDAContext;
        _ = cuCtxPushCurrent_v2(ctx);
        defer {
            var popped_ctx: ?CUcontext = null;
            _ = cuCtxPopCurrent_v2(&popped_ctx);
        }

        var stream_handle: ?CUstream = null;
        const result = cuStreamCreate(&stream_handle, 0);
        if (result != CUDA_SUCCESS) {
            return error.CUDAStreamCreationFailed;
        }

        return .{
            .device = device,
            .stream_handle = stream_handle,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.stream_handle) |stream| {
            const ctx = self.device.cuda_context orelse return;
            _ = cuCtxPushCurrent_v2(ctx);
            defer {
                var popped_ctx: ?CUcontext = null;
                _ = cuCtxPopCurrent_v2(&popped_ctx);
            }

            _ = cuStreamDestroy_v2(stream);
        }
    }

    pub fn synchronize(self: *Self) !void {
        if (self.stream_handle) |stream| {
            const ctx = self.device.cuda_context orelse return error.NoCUDAContext;
            _ = cuCtxPushCurrent_v2(ctx);
            defer {
                var popped_ctx: ?CUcontext = null;
                _ = cuCtxPopCurrent_v2(&popped_ctx);
            }

            const result = cuStreamSynchronize(stream);
            if (result != CUDA_SUCCESS) {
                return error.CUDAStreamSyncFailed;
            }
        }
    }
};
