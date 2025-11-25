// Home Video Library - Metal GPU Compute
// Production Metal GPU acceleration for macOS
// https://developer.apple.com/metal/

const std = @import("std");
const core = @import("../core/frame.zig");

pub const VideoFrame = core.VideoFrame;

// ============================================================================
// Metal C FFI Bindings
// ============================================================================

// Opaque types (defined in Metal framework)
pub const MTLDevice = opaque {};
pub const MTLCommandQueue = opaque {};
pub const MTLCommandBuffer = opaque {};
pub const MTLComputeCommandEncoder = opaque {};
pub const MTLLibrary = opaque {};
pub const MTLFunction = opaque {};
pub const MTLComputePipelineState = opaque {};
pub const MTLBuffer = opaque {};
pub const MTLTexture = opaque {};
pub const NS_String = opaque {};
pub const NS_Error = opaque {};
pub const NS_Array = opaque {};

// Objective-C runtime
extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn sel_registerName(str: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend() void; // Variadic

// Helper to call Objective-C methods
fn msgSend(comptime ReturnType: type) fn (id: ?*anyopaque, sel: ?*anyopaque, ...) callconv(.C) ReturnType {
    return @ptrCast(&objc_msgSend);
}

// Core Foundation
extern "c" fn CFRelease(cf: ?*anyopaque) void;

// MTLDevice
fn MTLCreateSystemDefaultDevice() ?*MTLDevice {
    const class = objc_getClass("MTLDevice");
    const sel = sel_registerName("systemDefaultDevice");
    const create_fn = msgSend(?*MTLDevice);
    return create_fn(class, sel);
}

fn MTLDevice_newCommandQueue(device: *MTLDevice) ?*MTLCommandQueue {
    const sel = sel_registerName("newCommandQueue");
    const new_fn = msgSend(?*MTLCommandQueue);
    return new_fn(device, sel);
}

fn MTLDevice_newBufferWithLength(
    device: *MTLDevice,
    length: usize,
    options: u64,
) ?*MTLBuffer {
    const sel = sel_registerName("newBufferWithLength:options:");
    const new_fn = msgSend(?*MTLBuffer);
    return new_fn(device, sel, length, options);
}

fn MTLDevice_newLibraryWithSource(
    device: *MTLDevice,
    source: *NS_String,
    options: ?*anyopaque,
    error_ptr: ?*?*NS_Error,
) ?*MTLLibrary {
    const sel = sel_registerName("newLibraryWithSource:options:error:");
    const new_fn = msgSend(?*MTLLibrary);
    return new_fn(device, sel, source, options, error_ptr);
}

fn MTLDevice_newComputePipelineStateWithFunction(
    device: *MTLDevice,
    function: *MTLFunction,
    error_ptr: ?*?*NS_Error,
) ?*MTLComputePipelineState {
    const sel = sel_registerName("newComputePipelineStateWithFunction:error:");
    const new_fn = msgSend(?*MTLComputePipelineState);
    return new_fn(device, sel, function, error_ptr);
}

fn MTLDevice_name(device: *MTLDevice) ?*NS_String {
    const sel = sel_registerName("name");
    const get_fn = msgSend(?*NS_String);
    return get_fn(device, sel);
}

// MTLCommandQueue
fn MTLCommandQueue_commandBuffer(queue: *MTLCommandQueue) ?*MTLCommandBuffer {
    const sel = sel_registerName("commandBuffer");
    const get_fn = msgSend(?*MTLCommandBuffer);
    return get_fn(queue, sel);
}

// MTLCommandBuffer
fn MTLCommandBuffer_computeCommandEncoder(buffer: *MTLCommandBuffer) ?*MTLComputeCommandEncoder {
    const sel = sel_registerName("computeCommandEncoder");
    const get_fn = msgSend(?*MTLComputeCommandEncoder);
    return get_fn(buffer, sel);
}

fn MTLCommandBuffer_commit(buffer: *MTLCommandBuffer) void {
    const sel = sel_registerName("commit");
    const commit_fn = msgSend(void);
    commit_fn(buffer, sel);
}

fn MTLCommandBuffer_waitUntilCompleted(buffer: *MTLCommandBuffer) void {
    const sel = sel_registerName("waitUntilCompleted");
    const wait_fn = msgSend(void);
    wait_fn(buffer, sel);
}

// MTLComputeCommandEncoder
fn MTLComputeCommandEncoder_setComputePipelineState(
    encoder: *MTLComputeCommandEncoder,
    state: *MTLComputePipelineState,
) void {
    const sel = sel_registerName("setComputePipelineState:");
    const set_fn = msgSend(void);
    set_fn(encoder, sel, state);
}

fn MTLComputeCommandEncoder_setBuffer(
    encoder: *MTLComputeCommandEncoder,
    buffer: *MTLBuffer,
    offset: usize,
    index: usize,
) void {
    const sel = sel_registerName("setBuffer:offset:atIndex:");
    const set_fn = msgSend(void);
    set_fn(encoder, sel, buffer, offset, index);
}

fn MTLComputeCommandEncoder_dispatchThreadgroups(
    encoder: *MTLComputeCommandEncoder,
    threadgroups_per_grid: MTLSize,
    threads_per_threadgroup: MTLSize,
) void {
    const sel = sel_registerName("dispatchThreadgroups:threadsPerThreadgroup:");
    const dispatch_fn = msgSend(void);
    dispatch_fn(encoder, sel, threadgroups_per_grid, threads_per_threadgroup);
}

fn MTLComputeCommandEncoder_endEncoding(encoder: *MTLComputeCommandEncoder) void {
    const sel = sel_registerName("endEncoding");
    const end_fn = msgSend(void);
    end_fn(encoder, sel);
}

// MTLLibrary
fn MTLLibrary_newFunctionWithName(library: *MTLLibrary, name: *NS_String) ?*MTLFunction {
    const sel = sel_registerName("newFunctionWithName:");
    const new_fn = msgSend(?*MTLFunction);
    return new_fn(library, sel, name);
}

// MTLBuffer
fn MTLBuffer_contents(buffer: *MTLBuffer) ?*anyopaque {
    const sel = sel_registerName("contents");
    const get_fn = msgSend(?*anyopaque);
    return get_fn(buffer, sel);
}

fn MTLBuffer_length(buffer: *MTLBuffer) usize {
    const sel = sel_registerName("length");
    const get_fn = msgSend(usize);
    return get_fn(buffer, sel);
}

// NSString
fn NSString_stringWithUTF8String(utf8_str: [*:0]const u8) ?*NS_String {
    const class = objc_getClass("NSString");
    const sel = sel_registerName("stringWithUTF8String:");
    const create_fn = msgSend(?*NS_String);
    return create_fn(class, sel, utf8_str);
}

fn NSString_UTF8String(string: *NS_String) [*:0]const u8 {
    const sel = sel_registerName("UTF8String");
    const get_fn = msgSend([*:0]const u8);
    return get_fn(string, sel);
}

// MTLSize
const MTLSize = extern struct {
    width: u64,
    height: u64,
    depth: u64,
};

// MTLResourceOptions
const MTLResourceStorageModeShared: u64 = 0 << 4;
const MTLResourceCPUCacheModeDefaultCache: u64 = 0 << 0;

// ============================================================================
// Metal Shaders (MSL - Metal Shading Language)
// ============================================================================

const METAL_SHADERS =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\// YUV to RGB conversion (BT.709)
    \\kernel void yuv_to_rgb(
    \\    device const uchar* y_plane [[buffer(0)]],
    \\    device const uchar* u_plane [[buffer(1)]],
    \\    device const uchar* v_plane [[buffer(2)]],
    \\    device uchar* rgb_output [[buffer(3)]],
    \\    constant uint& width [[buffer(4)]],
    \\    constant uint& height [[buffer(5)]],
    \\    uint2 gid [[thread_position_in_grid]])
    \\{
    \\    if (gid.x >= width || gid.y >= height) return;
    \\
    \\    uint idx = gid.y * width + gid.x;
    \\
    \\    float y = float(y_plane[idx]) / 255.0;
    \\    float u = float(u_plane[idx]) / 255.0 - 0.5;
    \\    float v = float(v_plane[idx]) / 255.0 - 0.5;
    \\
    \\    // BT.709 matrix
    \\    float r = y + 1.402 * v;
    \\    float g = y - 0.344136 * u - 0.714136 * v;
    \\    float b = y + 1.772 * u;
    \\
    \\    rgb_output[idx * 3 + 0] = uchar(clamp(r, 0.0f, 1.0f) * 255.0);
    \\    rgb_output[idx * 3 + 1] = uchar(clamp(g, 0.0f, 1.0f) * 255.0);
    \\    rgb_output[idx * 3 + 2] = uchar(clamp(b, 0.0f, 1.0f) * 255.0);
    \\}
    \\
    \\// RGB to YUV conversion (BT.709)
    \\kernel void rgb_to_yuv(
    \\    device const uchar* rgb_input [[buffer(0)]],
    \\    device uchar* y_plane [[buffer(1)]],
    \\    device uchar* u_plane [[buffer(2)]],
    \\    device uchar* v_plane [[buffer(3)]],
    \\    constant uint& width [[buffer(4)]],
    \\    constant uint& height [[buffer(5)]],
    \\    uint2 gid [[thread_position_in_grid]])
    \\{
    \\    if (gid.x >= width || gid.y >= height) return;
    \\
    \\    uint idx = gid.y * width + gid.x;
    \\
    \\    float r = float(rgb_input[idx * 3 + 0]) / 255.0;
    \\    float g = float(rgb_input[idx * 3 + 1]) / 255.0;
    \\    float b = float(rgb_input[idx * 3 + 2]) / 255.0;
    \\
    \\    // BT.709 matrix
    \\    float y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    \\    float u = -0.09991 * r - 0.33609 * g + 0.436 * b + 0.5;
    \\    float v = 0.615 * r - 0.55861 * g - 0.05639 * b + 0.5;
    \\
    \\    y_plane[idx] = uchar(clamp(y, 0.0f, 1.0f) * 255.0);
    \\    u_plane[idx] = uchar(clamp(u, 0.0f, 1.0f) * 255.0);
    \\    v_plane[idx] = uchar(clamp(v, 0.0f, 1.0f) * 255.0);
    \\}
    \\
    \\// Bilinear scaling
    \\kernel void bilinear_scale(
    \\    device const uchar* input [[buffer(0)]],
    \\    device uchar* output [[buffer(1)]],
    \\    constant uint& src_width [[buffer(2)]],
    \\    constant uint& src_height [[buffer(3)]],
    \\    constant uint& dst_width [[buffer(4)]],
    \\    constant uint& dst_height [[buffer(5)]],
    \\    constant uint& channels [[buffer(6)]],
    \\    uint2 gid [[thread_position_in_grid]])
    \\{
    \\    if (gid.x >= dst_width || gid.y >= dst_height) return;
    \\
    \\    float x_ratio = float(src_width) / float(dst_width);
    \\    float y_ratio = float(src_height) / float(dst_height);
    \\
    \\    float src_x = float(gid.x) * x_ratio;
    \\    float src_y = float(gid.y) * y_ratio;
    \\
    \\    uint x0 = uint(floor(src_x));
    \\    uint y0 = uint(floor(src_y));
    \\    uint x1 = min(x0 + 1, src_width - 1);
    \\    uint y1 = min(y0 + 1, src_height - 1);
    \\
    \\    float dx = src_x - float(x0);
    \\    float dy = src_y - float(y0);
    \\
    \\    for (uint c = 0; c < channels; c++) {
    \\        float p00 = float(input[(y0 * src_width + x0) * channels + c]);
    \\        float p10 = float(input[(y0 * src_width + x1) * channels + c]);
    \\        float p01 = float(input[(y1 * src_width + x0) * channels + c]);
    \\        float p11 = float(input[(y1 * src_width + x1) * channels + c]);
    \\
    \\        float top = mix(p00, p10, dx);
    \\        float bottom = mix(p01, p11, dx);
    \\        float result = mix(top, bottom, dy);
    \\
    \\        output[(gid.y * dst_width + gid.x) * channels + c] = uchar(result);
    \\    }
    \\}
    \\
    \\// Gaussian blur (3x3 kernel)
    \\kernel void gaussian_blur(
    \\    device const uchar* input [[buffer(0)]],
    \\    device uchar* output [[buffer(1)]],
    \\    constant uint& width [[buffer(2)]],
    \\    constant uint& height [[buffer(3)]],
    \\    constant uint& channels [[buffer(4)]],
    \\    uint2 gid [[thread_position_in_grid]])
    \\{
    \\    if (gid.x >= width || gid.y >= height) return;
    \\    if (gid.x == 0 || gid.y == 0 || gid.x >= width - 1 || gid.y >= height - 1) {
    \\        // Copy border pixels as-is
    \\        uint idx = gid.y * width + gid.x;
    \\        for (uint c = 0; c < channels; c++) {
    \\            output[idx * channels + c] = input[idx * channels + c];
    \\        }
    \\        return;
    \\    }
    \\
    \\    // Gaussian kernel (normalized)
    \\    constant float kernel[9] = {
    \\        1.0/16.0, 2.0/16.0, 1.0/16.0,
    \\        2.0/16.0, 4.0/16.0, 2.0/16.0,
    \\        1.0/16.0, 2.0/16.0, 1.0/16.0
    \\    };
    \\
    \\    for (uint c = 0; c < channels; c++) {
    \\        float sum = 0.0;
    \\
    \\        for (int dy = -1; dy <= 1; dy++) {
    \\            for (int dx = -1; dx <= 1; dx++) {
    \\                uint sx = uint(int(gid.x) + dx);
    \\                uint sy = uint(int(gid.y) + dy);
    \\                uint src_idx = sy * width + sx;
    \\
    \\                float pixel = float(input[src_idx * channels + c]);
    \\                int kernel_idx = (dy + 1) * 3 + (dx + 1);
    \\                sum += pixel * kernel[kernel_idx];
    \\            }
    \\        }
    \\
    \\        uint dst_idx = gid.y * width + gid.x;
    \\        output[dst_idx * channels + c] = uchar(clamp(sum, 0.0f, 255.0f));
    \\    }
    \\}
    \\
    \\// Unsharp mask (sharpening)
    \\kernel void unsharp_mask(
    \\    device const uchar* input [[buffer(0)]],
    \\    device const uchar* blurred [[buffer(1)]],
    \\    device uchar* output [[buffer(2)]],
    \\    constant uint& width [[buffer(3)]],
    \\    constant uint& height [[buffer(4)]],
    \\    constant uint& channels [[buffer(5)]],
    \\    constant float& amount [[buffer(6)]],
    \\    uint2 gid [[thread_position_in_grid]])
    \\{
    \\    if (gid.x >= width || gid.y >= height) return;
    \\
    \\    uint idx = gid.y * width + gid.x;
    \\
    \\    for (uint c = 0; c < channels; c++) {
    \\        float original = float(input[idx * channels + c]);
    \\        float blur = float(blurred[idx * channels + c]);
    \\        float sharpened = original + amount * (original - blur);
    \\        output[idx * channels + c] = uchar(clamp(sharpened, 0.0f, 255.0f));
    \\    }
    \\}
;

// ============================================================================
// Zig Wrapper
// ============================================================================

/// Metal Device
pub const MetalDevice = struct {
    device: *MTLDevice,
    name: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const device = MTLCreateSystemDefaultDevice() orelse {
            return error.NoMetalDevice;
        };

        const name_ns = MTLDevice_name(device) orelse {
            return error.FailedToGetDeviceName;
        };

        const name_cstr = NSString_UTF8String(name_ns);
        const name = try allocator.dupe(u8, std.mem.span(name_cstr));

        return .{
            .device = device,
            .name = name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        CFRelease(self.device);
    }
};

/// Metal Command Queue
pub const MetalCommandQueue = struct {
    queue: *MTLCommandQueue,

    const Self = @This();

    pub fn init(device: *MetalDevice) !Self {
        const queue = MTLDevice_newCommandQueue(device.device) orelse {
            return error.FailedToCreateCommandQueue;
        };

        return .{ .queue = queue };
    }

    pub fn deinit(self: *Self) void {
        CFRelease(self.queue);
    }
};

/// Metal Buffer
pub const MetalBuffer = struct {
    buffer: *MTLBuffer,
    size: usize,

    const Self = @This();

    pub fn init(device: *MetalDevice, size: usize) !Self {
        const options = MTLResourceStorageModeShared | MTLResourceCPUCacheModeDefaultCache;
        const buffer = MTLDevice_newBufferWithLength(device.device, size, options) orelse {
            return error.FailedToCreateBuffer;
        };

        return .{
            .buffer = buffer,
            .size = size,
        };
    }

    pub fn deinit(self: *Self) void {
        CFRelease(self.buffer);
    }

    pub fn upload(self: *Self, data: []const u8) !void {
        if (data.len > self.size) return error.BufferTooSmall;

        const contents = MTLBuffer_contents(self.buffer) orelse {
            return error.FailedToGetBufferContents;
        };

        @memcpy(@as([*]u8, @ptrCast(contents))[0..data.len], data);
    }

    pub fn download(self: *Self, data: []u8) !void {
        if (data.len < self.size) return error.BufferTooSmall;

        const contents = MTLBuffer_contents(self.buffer) orelse {
            return error.FailedToGetBufferContents;
        };

        @memcpy(data[0..self.size], @as([*]u8, @ptrCast(contents))[0..self.size]);
    }
};

/// Metal Compute Pipeline
pub const MetalComputePipeline = struct {
    pipeline_state: *MTLComputePipelineState,

    const Self = @This();

    pub fn init(device: *MetalDevice, function_name: []const u8) !Self {
        // Create library from shader source
        const source_ns = NSString_stringWithUTF8String(METAL_SHADERS) orelse {
            return error.FailedToCreateNSString;
        };

        var error_ptr: ?*NS_Error = null;
        const library = MTLDevice_newLibraryWithSource(
            device.device,
            source_ns,
            null,
            &error_ptr,
        ) orelse {
            return error.FailedToCompileShaders;
        };
        defer CFRelease(library);

        // Get function
        const function_name_z = try device.allocator.dupeZ(u8, function_name);
        defer device.allocator.free(function_name_z);

        const function_name_ns = NSString_stringWithUTF8String(function_name_z) orelse {
            return error.FailedToCreateNSString;
        };

        const function = MTLLibrary_newFunctionWithName(library, function_name_ns) orelse {
            return error.FailedToGetFunction;
        };
        defer CFRelease(function);

        // Create pipeline state
        error_ptr = null;
        const pipeline_state = MTLDevice_newComputePipelineStateWithFunction(
            device.device,
            function,
            &error_ptr,
        ) orelse {
            return error.FailedToCreatePipelineState;
        };

        return .{ .pipeline_state = pipeline_state };
    }

    pub fn deinit(self: *Self) void {
        CFRelease(self.pipeline_state);
    }
};

/// Metal Compute Encoder
pub const MetalComputeEncoder = struct {
    device: *MetalDevice,
    queue: *MetalCommandQueue,
    allocator: std.mem.Allocator,

    // Pipelines
    yuv_to_rgb_pipeline: ?MetalComputePipeline = null,
    rgb_to_yuv_pipeline: ?MetalComputePipeline = null,
    bilinear_scale_pipeline: ?MetalComputePipeline = null,
    gaussian_blur_pipeline: ?MetalComputePipeline = null,
    unsharp_mask_pipeline: ?MetalComputePipeline = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *MetalDevice, queue: *MetalCommandQueue) Self {
        return .{
            .device = device,
            .queue = queue,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.yuv_to_rgb_pipeline) |*p| p.deinit();
        if (self.rgb_to_yuv_pipeline) |*p| p.deinit();
        if (self.bilinear_scale_pipeline) |*p| p.deinit();
        if (self.gaussian_blur_pipeline) |*p| p.deinit();
        if (self.unsharp_mask_pipeline) |*p| p.deinit();
    }

    /// Convert YUV to RGB using Metal compute shader
    pub fn yuvToRgb(
        self: *Self,
        y_buffer: *MetalBuffer,
        u_buffer: *MetalBuffer,
        v_buffer: *MetalBuffer,
        rgb_buffer: *MetalBuffer,
        width: u32,
        height: u32,
    ) !void {
        // Lazy initialize pipeline
        if (self.yuv_to_rgb_pipeline == null) {
            self.yuv_to_rgb_pipeline = try MetalComputePipeline.init(self.device, "yuv_to_rgb");
        }

        // Create width/height buffers
        var width_buffer = try MetalBuffer.init(self.device, @sizeOf(u32));
        defer width_buffer.deinit();
        try width_buffer.upload(std.mem.asBytes(&width));

        var height_buffer = try MetalBuffer.init(self.device, @sizeOf(u32));
        defer height_buffer.deinit();
        try height_buffer.upload(std.mem.asBytes(&height));

        // Create command buffer
        const command_buffer = MTLCommandQueue_commandBuffer(self.queue.queue) orelse {
            return error.FailedToCreateCommandBuffer;
        };

        // Create compute encoder
        const encoder = MTLCommandBuffer_computeCommandEncoder(command_buffer) orelse {
            return error.FailedToCreateComputeEncoder;
        };

        // Set pipeline
        MTLComputeCommandEncoder_setComputePipelineState(encoder, self.yuv_to_rgb_pipeline.?.pipeline_state);

        // Set buffers
        MTLComputeCommandEncoder_setBuffer(encoder, y_buffer.buffer, 0, 0);
        MTLComputeCommandEncoder_setBuffer(encoder, u_buffer.buffer, 0, 1);
        MTLComputeCommandEncoder_setBuffer(encoder, v_buffer.buffer, 0, 2);
        MTLComputeCommandEncoder_setBuffer(encoder, rgb_buffer.buffer, 0, 3);
        MTLComputeCommandEncoder_setBuffer(encoder, width_buffer.buffer, 0, 4);
        MTLComputeCommandEncoder_setBuffer(encoder, height_buffer.buffer, 0, 5);

        // Dispatch
        const threadgroup_size = MTLSize{ .width = 16, .height = 16, .depth = 1 };
        const threadgroups = MTLSize{
            .width = (width + 15) / 16,
            .height = (height + 15) / 16,
            .depth = 1,
        };

        MTLComputeCommandEncoder_dispatchThreadgroups(encoder, threadgroups, threadgroup_size);
        MTLComputeCommandEncoder_endEncoding(encoder);

        // Commit and wait
        MTLCommandBuffer_commit(command_buffer);
        MTLCommandBuffer_waitUntilCompleted(command_buffer);
    }

    /// Convert RGB to YUV using Metal compute shader
    pub fn rgbToYuv(
        self: *Self,
        rgb_buffer: *MetalBuffer,
        y_buffer: *MetalBuffer,
        u_buffer: *MetalBuffer,
        v_buffer: *MetalBuffer,
        width: u32,
        height: u32,
    ) !void {
        if (self.rgb_to_yuv_pipeline == null) {
            self.rgb_to_yuv_pipeline = try MetalComputePipeline.init(self.device, "rgb_to_yuv");
        }

        var width_buffer = try MetalBuffer.init(self.device, @sizeOf(u32));
        defer width_buffer.deinit();
        try width_buffer.upload(std.mem.asBytes(&width));

        var height_buffer = try MetalBuffer.init(self.device, @sizeOf(u32));
        defer height_buffer.deinit();
        try height_buffer.upload(std.mem.asBytes(&height));

        const command_buffer = MTLCommandQueue_commandBuffer(self.queue.queue) orelse {
            return error.FailedToCreateCommandBuffer;
        };

        const encoder = MTLCommandBuffer_computeCommandEncoder(command_buffer) orelse {
            return error.FailedToCreateComputeEncoder;
        };

        MTLComputeCommandEncoder_setComputePipelineState(encoder, self.rgb_to_yuv_pipeline.?.pipeline_state);
        MTLComputeCommandEncoder_setBuffer(encoder, rgb_buffer.buffer, 0, 0);
        MTLComputeCommandEncoder_setBuffer(encoder, y_buffer.buffer, 0, 1);
        MTLComputeCommandEncoder_setBuffer(encoder, u_buffer.buffer, 0, 2);
        MTLComputeCommandEncoder_setBuffer(encoder, v_buffer.buffer, 0, 3);
        MTLComputeCommandEncoder_setBuffer(encoder, width_buffer.buffer, 0, 4);
        MTLComputeCommandEncoder_setBuffer(encoder, height_buffer.buffer, 0, 5);

        const threadgroup_size = MTLSize{ .width = 16, .height = 16, .depth = 1 };
        const threadgroups = MTLSize{
            .width = (width + 15) / 16,
            .height = (height + 15) / 16,
            .depth = 1,
        };

        MTLComputeCommandEncoder_dispatchThreadgroups(encoder, threadgroups, threadgroup_size);
        MTLComputeCommandEncoder_endEncoding(encoder);
        MTLCommandBuffer_commit(command_buffer);
        MTLCommandBuffer_waitUntilCompleted(command_buffer);
    }

    /// Bilinear scaling using Metal
    pub fn bilinearScale(
        self: *Self,
        input: *MetalBuffer,
        output: *MetalBuffer,
        src_width: u32,
        src_height: u32,
        dst_width: u32,
        dst_height: u32,
        channels: u32,
    ) !void {
        if (self.bilinear_scale_pipeline == null) {
            self.bilinear_scale_pipeline = try MetalComputePipeline.init(self.device, "bilinear_scale");
        }

        // Create parameter buffers
        var src_width_buf = try MetalBuffer.init(self.device, @sizeOf(u32));
        defer src_width_buf.deinit();
        try src_width_buf.upload(std.mem.asBytes(&src_width));

        var src_height_buf = try MetalBuffer.init(self.device, @sizeOf(u32));
        defer src_height_buf.deinit();
        try src_height_buf.upload(std.mem.asBytes(&src_height));

        var dst_width_buf = try MetalBuffer.init(self.device, @sizeOf(u32));
        defer dst_width_buf.deinit();
        try dst_width_buf.upload(std.mem.asBytes(&dst_width));

        var dst_height_buf = try MetalBuffer.init(self.device, @sizeOf(u32));
        defer dst_height_buf.deinit();
        try dst_height_buf.upload(std.mem.asBytes(&dst_height));

        var channels_buf = try MetalBuffer.init(self.device, @sizeOf(u32));
        defer channels_buf.deinit();
        try channels_buf.upload(std.mem.asBytes(&channels));

        const command_buffer = MTLCommandQueue_commandBuffer(self.queue.queue) orelse {
            return error.FailedToCreateCommandBuffer;
        };

        const encoder = MTLCommandBuffer_computeCommandEncoder(command_buffer) orelse {
            return error.FailedToCreateComputeEncoder;
        };

        MTLComputeCommandEncoder_setComputePipelineState(encoder, self.bilinear_scale_pipeline.?.pipeline_state);
        MTLComputeCommandEncoder_setBuffer(encoder, input.buffer, 0, 0);
        MTLComputeCommandEncoder_setBuffer(encoder, output.buffer, 0, 1);
        MTLComputeCommandEncoder_setBuffer(encoder, src_width_buf.buffer, 0, 2);
        MTLComputeCommandEncoder_setBuffer(encoder, src_height_buf.buffer, 0, 3);
        MTLComputeCommandEncoder_setBuffer(encoder, dst_width_buf.buffer, 0, 4);
        MTLComputeCommandEncoder_setBuffer(encoder, dst_height_buf.buffer, 0, 5);
        MTLComputeCommandEncoder_setBuffer(encoder, channels_buf.buffer, 0, 6);

        const threadgroup_size = MTLSize{ .width = 16, .height = 16, .depth = 1 };
        const threadgroups = MTLSize{
            .width = (dst_width + 15) / 16,
            .height = (dst_height + 15) / 16,
            .depth = 1,
        };

        MTLComputeCommandEncoder_dispatchThreadgroups(encoder, threadgroups, threadgroup_size);
        MTLComputeCommandEncoder_endEncoding(encoder);
        MTLCommandBuffer_commit(command_buffer);
        MTLCommandBuffer_waitUntilCompleted(command_buffer);
    }
};
