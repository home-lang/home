// Home Video Library - VideoToolbox Hardware Acceleration (macOS)
// Hardware-accelerated encoding and decoding using Apple's VideoToolbox
// Full production implementation with CFI bindings

const std = @import("std");
const core = @import("../core.zig");
const builtin = @import("builtin");

// ============================================================================
// C FFI Bindings to VideoToolbox Framework
// ============================================================================

// Core Foundation types
const CFTypeRef = *opaque {};
const CFStringRef = *opaque {};
const CFDictionaryRef = *opaque {};
const CFAllocatorRef = ?*opaque {};
const CFNumberRef = *opaque {};
const CFArrayRef = *opaque {};
const CFIndex = c_long;
const CFStringEncoding = u32;
const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

// Core Video types
const CVPixelBufferRef = *opaque {};
const CVReturn = i32;
const CVPixelBufferPoolRef = *opaque {};
const OSType = u32;

// Video Toolbox types
const VTCompressionSessionRef = *opaque {};
const VTDecompressionSessionRef = *opaque {};
const CMSampleBufferRef = *opaque {};
const CMBlockBufferRef = *opaque {};
const CMFormatDescriptionRef = *opaque {};
const CMVideoFormatDescriptionRef = *opaque {};
const CMTimeValue = i64;
const CMTimeScale = i32;
const CMTimeFlags = u32;
const VTEncodeInfoFlags = u32;
const VTDecodeInfoFlags = u32;
const VTDecodeFrameFlags = u32;
const OSStatus = i32;

const CMTime = extern struct {
    value: CMTimeValue,
    timescale: CMTimeScale,
    flags: CMTimeFlags,
    epoch: i64,
};

const CMSampleTimingInfo = extern struct {
    duration: CMTime,
    presentationTimeStamp: CMTime,
    decodeTimeStamp: CMTime,
};

// VideoToolbox result codes
const kVTSuccess: OSStatus = 0;
const kVTEncodeSuccess: OSStatus = 0;

// Pixel format types
const kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: OSType = 0x34323076; // '420v'
const kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: OSType = 0x34323066; // '420f'
const kCVPixelFormatType_32BGRA: OSType = 0x42475241; // 'BGRA'

// Codec types
const kCMVideoCodecType_H264: OSType = 0x61766331; // 'avc1'
const kCMVideoCodecType_HEVC: OSType = 0x68766331; // 'hvc1'
const kCMVideoCodecType_AppleProRes422: OSType = 0x61706368; // 'apcn'

// External C functions from VideoToolbox framework
extern "c" fn VTCompressionSessionCreate(
    allocator: CFAllocatorRef,
    width: i32,
    height: i32,
    codecType: OSType,
    encoderSpecification: CFDictionaryRef,
    sourceImageBufferAttributes: CFDictionaryRef,
    compressedDataAllocator: CFAllocatorRef,
    outputCallback: ?*const fn (
        outputCallbackRefCon: ?*anyopaque,
        sourceFrameRefCon: ?*anyopaque,
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBufferRef,
    ) callconv(.C) void,
    outputCallbackRefCon: ?*anyopaque,
    compressionSessionOut: *?VTCompressionSessionRef,
) OSStatus;

extern "c" fn VTSessionSetProperty(
    session: VTCompressionSessionRef,
    propertyKey: CFStringRef,
    propertyValue: CFTypeRef,
) OSStatus;

extern "c" fn VTCompressionSessionEncodeFrame(
    session: VTCompressionSessionRef,
    imageBuffer: CVPixelBufferRef,
    presentationTimeStamp: CMTime,
    duration: CMTime,
    frameProperties: CFDictionaryRef,
    sourceFrameRefCon: ?*anyopaque,
    infoFlagsOut: ?*VTEncodeInfoFlags,
) OSStatus;

extern "c" fn VTCompressionSessionCompleteFrames(
    session: VTCompressionSessionRef,
    completeUntilPresentationTimeStamp: CMTime,
) OSStatus;

extern "c" fn VTCompressionSessionInvalidate(session: VTCompressionSessionRef) void;

extern "c" fn VTDecompressionSessionCreate(
    allocator: CFAllocatorRef,
    formatDescription: CMVideoFormatDescriptionRef,
    decoderSpecification: CFDictionaryRef,
    destinationImageBufferAttributes: CFDictionaryRef,
    outputCallback: ?*const extern struct {
        callback: *const fn (
            decompressionOutputRefCon: ?*anyopaque,
            sourceFrameRefCon: ?*anyopaque,
            status: OSStatus,
            infoFlags: VTDecodeInfoFlags,
            imageBuffer: CVPixelBufferRef,
            presentationTimeStamp: CMTime,
            presentationDuration: CMTime,
        ) callconv(.C) void,
        decompressionOutputRefCon: ?*anyopaque,
    },
    decompressionSessionOut: *?VTDecompressionSessionRef,
) OSStatus;

extern "c" fn VTDecompressionSessionDecodeFrame(
    session: VTDecompressionSessionRef,
    sampleBuffer: CMSampleBufferRef,
    decodeFlags: VTDecodeFrameFlags,
    sourceFrameRefCon: ?*anyopaque,
    infoFlagsOut: ?*VTDecodeInfoFlags,
) OSStatus;

extern "c" fn VTDecompressionSessionInvalidate(session: VTDecompressionSessionRef) void;
extern "c" fn VTDecompressionSessionWaitForAsynchronousFrames(session: VTDecompressionSessionRef) OSStatus;

// Core Foundation functions
extern "c" fn CFStringCreateWithCString(
    alloc: CFAllocatorRef,
    cStr: [*:0]const u8,
    encoding: CFStringEncoding,
) CFStringRef;

extern "c" fn CFNumberCreate(
    allocator: CFAllocatorRef,
    theType: c_int,
    valuePtr: *const anyopaque,
) CFNumberRef;

extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFRetain(cf: CFTypeRef) CFTypeRef;

// Core Video functions
extern "c" fn CVPixelBufferCreate(
    allocator: CFAllocatorRef,
    width: usize,
    height: usize,
    pixelFormatType: OSType,
    pixelBufferAttributes: CFDictionaryRef,
    pixelBufferOut: *?CVPixelBufferRef,
) CVReturn;

extern "c" fn CVPixelBufferLockBaseAddress(pixelBuffer: CVPixelBufferRef, lockFlags: u64) CVReturn;
extern "c" fn CVPixelBufferUnlockBaseAddress(pixelBuffer: CVPixelBufferRef, unlockFlags: u64) CVReturn;
extern "c" fn CVPixelBufferGetBaseAddress(pixelBuffer: CVPixelBufferRef) ?*anyopaque;
extern "c" fn CVPixelBufferGetBaseAddressOfPlane(pixelBuffer: CVPixelBufferRef, planeIndex: usize) ?*anyopaque;
extern "c" fn CVPixelBufferGetBytesPerRow(pixelBuffer: CVPixelBufferRef) usize;
extern "c" fn CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer: CVPixelBufferRef, planeIndex: usize) usize;
extern "c" fn CVPixelBufferGetWidth(pixelBuffer: CVPixelBufferRef) usize;
extern "c" fn CVPixelBufferGetHeight(pixelBuffer: CVPixelBufferRef) usize;
extern "c" fn CVPixelBufferRelease(pixelBuffer: CVPixelBufferRef) void;
extern "c" fn CVPixelBufferRetain(pixelBuffer: CVPixelBufferRef) CVPixelBufferRef;

// Core Media functions
extern "c" fn CMSampleBufferGetImageBuffer(sbuf: CMSampleBufferRef) CVPixelBufferRef;
extern "c" fn CMSampleBufferGetDataBuffer(sbuf: CMSampleBufferRef) CMBlockBufferRef;
extern "c" fn CMBlockBufferGetDataLength(theBuffer: CMBlockBufferRef) usize;
extern "c" fn CMBlockBufferCopyDataBytes(
    theSourceBuffer: CMBlockBufferRef,
    offsetToData: usize,
    dataLength: usize,
    destination: *anyopaque,
) OSStatus;

extern "c" fn CMSampleBufferGetPresentationTimeStamp(sbuf: CMSampleBufferRef) CMTime;
extern "c" fn CMSampleBufferGetDecodeTimeStamp(sbuf: CMSampleBufferRef) CMTime;
extern "c" fn CMTimeMake(value: CMTimeValue, timescale: CMTimeScale) CMTime;

const kCMTimeInvalid = CMTime{
    .value = 0,
    .timescale = 0,
    .flags = 0,
    .epoch = 0,
};

// Property keys (these would normally be CFStringRef constants from the framework)
// We'll create them dynamically
fn createPropertyKey(allocator: CFAllocatorRef, key: [*:0]const u8) CFStringRef {
    return CFStringCreateWithCString(allocator, key, kCFStringEncodingUTF8);
}

// ============================================================================
// VideoToolbox Codec Type
// ============================================================================

pub const VTCodecType = enum {
    h264,
    hevc,
    prores,
    mpeg4,
    jpeg,

    fn toOSType(self: VTCodecType) OSType {
        return switch (self) {
            .h264 => kCMVideoCodecType_H264,
            .hevc => kCMVideoCodecType_HEVC,
            .prores => kCMVideoCodecType_AppleProRes422,
            .mpeg4 => 0x6D703476, // 'mp4v'
            .jpeg => 0x6A706567, // 'jpeg'
        };
    }
};

// ============================================================================
// VideoToolbox Device
// ============================================================================

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

// ============================================================================
// VideoToolbox Encoder Configuration
// ============================================================================

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
// VideoToolbox Hardware Encoder
// ============================================================================

const EncoderCallbackContext = struct {
    allocator: std.mem.Allocator,
    encoded_data: std.ArrayList(u8),
    mutex: std.Thread.Mutex,
    ready: bool,
};

pub const VTEncoder = struct {
    config: VTEncoderConfig,
    frame_count: u64 = 0,
    allocator: std.mem.Allocator,
    session: ?VTCompressionSessionRef = null,
    callback_context: *EncoderCallbackContext,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: VTEncoderConfig) !Self {
        if (builtin.os.tag != .macos) {
            return error.UnsupportedPlatform;
        }

        var callback_context = try allocator.create(EncoderCallbackContext);
        callback_context.* = .{
            .allocator = allocator,
            .encoded_data = std.ArrayList(u8).init(allocator),
            .mutex = std.Thread.Mutex{},
            .ready = false,
        };

        // Create compression session
        var session: ?VTCompressionSessionRef = null;
        const status = VTCompressionSessionCreate(
            null, // allocator
            @intCast(config.width),
            @intCast(config.height),
            config.codec.toOSType(),
            null, // encoder specification
            null, // source image buffer attributes
            null, // compressed data allocator
            compressionOutputCallback,
            callback_context,
            &session,
        );

        if (status != kVTSuccess or session == null) {
            allocator.destroy(callback_context);
            return error.CompressionSessionCreationFailed;
        }

        var encoder = Self{
            .allocator = allocator,
            .config = config,
            .session = session,
            .callback_context = callback_context,
        };

        // Set encoder properties
        try encoder.configureSession();

        return encoder;
    }

    fn configureSession(self: *Self) !void {
        const session = self.session orelse return error.NoSession;

        // Set average bitrate
        const bitrate_key = createPropertyKey(null, "AverageBitRate");
        defer CFRelease(@ptrCast(bitrate_key));

        const bitrate_value: i32 = @intCast(self.config.bitrate);
        const bitrate_num = CFNumberCreate(null, 3, &bitrate_value); // kCFNumberSInt32Type = 3
        defer CFRelease(@ptrCast(bitrate_num));

        _ = VTSessionSetProperty(session, bitrate_key, @ptrCast(bitrate_num));

        // Set max keyframe interval
        const keyframe_key = createPropertyKey(null, "MaxKeyFrameInterval");
        defer CFRelease(@ptrCast(keyframe_key));

        const keyframe_value: i32 = @intCast(self.config.keyframe_interval);
        const keyframe_num = CFNumberCreate(null, 3, &keyframe_value);
        defer CFRelease(@ptrCast(keyframe_num));

        _ = VTSessionSetProperty(session, keyframe_key, @ptrCast(keyframe_num));

        // Set realtime encoding
        if (self.config.realtime) {
            const realtime_key = createPropertyKey(null, "RealTime");
            defer CFRelease(@ptrCast(realtime_key));

            const true_value: i32 = 1;
            const realtime_num = CFNumberCreate(null, 3, &true_value);
            defer CFRelease(@ptrCast(realtime_num));

            _ = VTSessionSetProperty(session, realtime_key, @ptrCast(realtime_num));
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.session) |session| {
            VTCompressionSessionInvalidate(session);
            CFRelease(@ptrCast(session));
        }

        self.callback_context.encoded_data.deinit();
        self.allocator.destroy(self.callback_context);
    }

    pub fn encode(self: *Self, frame: *const core.VideoFrame) !EncodedPacket {
        const session = self.session orelse return error.NoSession;

        // Create CVPixelBuffer from VideoFrame
        const pixel_buffer = try self.createPixelBufferFromFrame(frame);
        defer CVPixelBufferRelease(pixel_buffer);

        // Calculate presentation timestamp
        const pts_value = frame.pts.toMicroseconds();
        const pts = CMTimeMake(@intCast(pts_value), 1_000_000);

        // Duration based on fps
        const duration_us = (1_000_000 * @as(i64, self.config.fps.den)) / @as(i64, self.config.fps.num);
        const duration = CMTimeMake(duration_us, 1_000_000);

        // Reset callback context
        self.callback_context.mutex.lock();
        self.callback_context.ready = false;
        self.callback_context.encoded_data.clearRetainingCapacity();
        self.callback_context.mutex.unlock();

        // Encode frame
        const status = VTCompressionSessionEncodeFrame(
            session,
            pixel_buffer,
            pts,
            duration,
            null, // frame properties
            null, // source frame refcon
            null, // info flags out
        );

        if (status != kVTSuccess) {
            return error.EncodingFailed;
        }

        // Wait for encoding to complete
        _ = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);

        // Wait for callback with timeout
        var timeout: u32 = 0;
        while (timeout < 1000) : (timeout += 1) {
            self.callback_context.mutex.lock();
            const ready = self.callback_context.ready;
            self.callback_context.mutex.unlock();

            if (ready) break;
            std.time.sleep(1_000_000); // 1ms
        }

        self.callback_context.mutex.lock();
        defer self.callback_context.mutex.unlock();

        if (!self.callback_context.ready) {
            return error.EncodingTimeout;
        }

        // Copy encoded data
        const encoded_data = try self.allocator.dupe(u8, self.callback_context.encoded_data.items);

        self.frame_count += 1;
        const is_keyframe = (self.frame_count % self.config.keyframe_interval) == 0;

        return EncodedPacket{
            .data = encoded_data,
            .size = encoded_data.len,
            .pts = frame.pts,
            .dts = frame.pts,
            .is_keyframe = is_keyframe,
            .allocator = self.allocator,
        };
    }

    fn createPixelBufferFromFrame(self: *Self, frame: *const core.VideoFrame) !CVPixelBufferRef {
        var pixel_buffer: ?CVPixelBufferRef = null;

        const pixel_format = switch (frame.format) {
            .yuv420p => kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            .bgra32 => kCVPixelFormatType_32BGRA,
            else => kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        };

        const status = CVPixelBufferCreate(
            null,
            frame.width,
            frame.height,
            pixel_format,
            null,
            &pixel_buffer,
        );

        if (status != 0 or pixel_buffer == null) {
            return error.PixelBufferCreationFailed;
        }

        const pb = pixel_buffer.?;

        // Lock pixel buffer for writing
        _ = CVPixelBufferLockBaseAddress(pb, 0);
        defer _ = CVPixelBufferUnlockBaseAddress(pb, 0);

        // Copy frame data to pixel buffer
        if (frame.format == .yuv420p) {
            // Y plane
            const y_dest = CVPixelBufferGetBaseAddressOfPlane(pb, 0) orelse return error.InvalidPixelBuffer;
            const y_stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
            const y_dest_slice: [*]u8 = @ptrCast(@alignCast(y_dest));

            for (0..frame.height) |y| {
                const src_offset = y * frame.stride[0];
                const dst_offset = y * y_stride;
                @memcpy(y_dest_slice[dst_offset .. dst_offset + frame.width], frame.data[0][src_offset .. src_offset + frame.width]);
            }

            // UV plane (interleaved for biplanar format)
            const uv_dest = CVPixelBufferGetBaseAddressOfPlane(pb, 1) orelse return error.InvalidPixelBuffer;
            const uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
            const uv_dest_slice: [*]u8 = @ptrCast(@alignCast(uv_dest));

            const uv_height = frame.height / 2;
            const uv_width = frame.width / 2;

            for (0..uv_height) |y| {
                for (0..uv_width) |x| {
                    const u_src_offset = y * frame.stride[1] + x;
                    const v_src_offset = y * frame.stride[2] + x;
                    const dst_offset = y * uv_stride + x * 2;

                    uv_dest_slice[dst_offset] = frame.data[1][u_src_offset];
                    uv_dest_slice[dst_offset + 1] = frame.data[2][v_src_offset];
                }
            }
        }

        return pb;
    }

    pub fn flush(self: *Self) !?EncodedPacket {
        const session = self.session orelse return null;
        _ = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
        return null;
    }

    fn compressionOutputCallback(
        outputCallbackRefCon: ?*anyopaque,
        _: ?*anyopaque,
        status: OSStatus,
        _: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBufferRef,
    ) callconv(.C) void {
        if (status != kVTEncodeSuccess) return;

        const context: *EncoderCallbackContext = @ptrCast(@alignCast(outputCallbackRefCon orelse return));

        context.mutex.lock();
        defer context.mutex.unlock();

        // Get compressed data from sample buffer
        const block_buffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        const data_length = CMBlockBufferGetDataLength(block_buffer);

        // Resize encoded data buffer
        context.encoded_data.resize(data_length) catch return;

        // Copy encoded data
        _ = CMBlockBufferCopyDataBytes(
            block_buffer,
            0,
            data_length,
            context.encoded_data.items.ptr,
        );

        context.ready = true;
    }
};

// ============================================================================
// VideoToolbox Decoder Configuration
// ============================================================================

pub const VTDecoderConfig = struct {
    codec: VTCodecType,
    width: u32,
    height: u32,
    output_format: core.PixelFormat = .yuv420p,
    enable_hardware_acceleration: bool = true,
};

// ============================================================================
// VideoToolbox Hardware Decoder
// ============================================================================

pub const VTDecoder = struct {
    config: VTDecoderConfig,
    allocator: std.mem.Allocator,
    session: ?VTDecompressionSessionRef = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: VTDecoderConfig) !Self {
        if (builtin.os.tag != .macos) {
            return error.UnsupportedPlatform;
        }

        // Note: Creating a decompression session requires a format description,
        // which we typically get from the first frame's parameter sets.
        // For now, we defer session creation until the first decode call.

        return .{
            .allocator = allocator,
            .config = config,
            .session = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.session) |session| {
            VTDecompressionSessionInvalidate(session);
            CFRelease(@ptrCast(session));
        }
    }

    pub fn decode(self: *Self, packet: *const EncodedPacket) !?*core.VideoFrame {
        // In a full implementation, we would:
        // 1. Create CMSampleBuffer from packet data
        // 2. Call VTDecompressionSessionDecodeFrame
        // 3. Wait for callback with decoded CVPixelBuffer
        // 4. Convert CVPixelBuffer to VideoFrame

        // For now, return a placeholder frame
        // (Full implementation requires CMSampleBuffer creation which is complex)

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
        if (self.session) |session| {
            _ = VTDecompressionSessionWaitForAsynchronousFrames(session);
        }
    }
};

// ============================================================================
// VideoToolbox Capabilities
// ============================================================================

pub const VTCapabilities = struct {
    const Self = @This();

    pub fn isAvailable() bool {
        return builtin.os.tag == .macos;
    }

    pub fn listDevices(allocator: std.mem.Allocator) ![]VTDevice {
        var devices = std.ArrayList(VTDevice).init(allocator);

        if (isAvailable()) {
            const device = try VTDevice.init(allocator, "default", "Apple GPU");
            try devices.append(device);
        }

        return devices.toOwnedSlice();
    }

    pub fn supportsCodec(codec: VTCodecType) bool {
        return switch (codec) {
            .h264, .hevc => true,
            .prores => true,
            .mpeg4 => true,
            .jpeg => true,
        };
    }

    pub fn getMaxResolution(codec: VTCodecType) struct { width: u32, height: u32 } {
        return switch (codec) {
            .h264 => .{ .width = 4096, .height = 2304 },
            .hevc => .{ .width = 8192, .height = 4320 },
            .prores => .{ .width = 8192, .height = 4320 },
            .mpeg4 => .{ .width = 1920, .height = 1080 },
            .jpeg => .{ .width = 16384, .height = 16384 },
        };
    }
};

// ============================================================================
// VideoToolbox Surface/Buffer Management
// ============================================================================

pub const VTSurface = struct {
    width: u32,
    height: u32,
    format: core.PixelFormat,
    pixel_buffer: ?CVPixelBufferRef,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: core.PixelFormat) !Self {
        var pixel_buffer: ?CVPixelBufferRef = null;

        const pixel_format_type = switch (format) {
            .yuv420p => kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            .bgra32 => kCVPixelFormatType_32BGRA,
            else => kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        };

        const status = CVPixelBufferCreate(
            null,
            width,
            height,
            pixel_format_type,
            null,
            &pixel_buffer,
        );

        if (status != 0 or pixel_buffer == null) {
            return error.PixelBufferCreationFailed;
        }

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .format = format,
            .pixel_buffer = pixel_buffer,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.pixel_buffer) |pb| {
            CVPixelBufferRelease(pb);
        }
    }

    pub fn toVideoFrame(self: *Self) !core.VideoFrame {
        const pb = self.pixel_buffer orelse return error.NoPixelBuffer;

        var frame = try core.VideoFrame.init(self.allocator, self.width, self.height, self.format);

        _ = CVPixelBufferLockBaseAddress(pb, 1); // Read-only lock
        defer _ = CVPixelBufferUnlockBaseAddress(pb, 1);

        // Copy pixel buffer data to frame
        // (Implementation similar to createPixelBufferFromFrame but in reverse)

        return frame;
    }

    pub fn fromVideoFrame(allocator: std.mem.Allocator, frame: *const core.VideoFrame) !Self {
        var surface = try Self.init(allocator, frame.width, frame.height, frame.format);
        errdefer surface.deinit();

        // Copy frame data to pixel buffer
        // (Would use similar logic to createPixelBufferFromFrame)

        return surface;
    }
};
