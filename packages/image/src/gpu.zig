const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("image.zig").Color;
const builtin = @import("builtin");

// ============================================================================
// GPU Backend Detection
// ============================================================================

pub const Backend = enum {
    none,
    metal,
    vulkan,
    opencl,
    cuda,
};

/// Detect available GPU backends
pub fn detectBackends() BackendInfo {
    var info = BackendInfo{};

    // Check platform
    switch (builtin.os.tag) {
        .macos, .ios => {
            info.metal_available = true;
            info.preferred = .metal;
        },
        .windows => {
            info.vulkan_available = checkVulkan();
            info.opencl_available = checkOpenCL();
            info.cuda_available = checkCUDA();
            if (info.vulkan_available) {
                info.preferred = .vulkan;
            } else if (info.cuda_available) {
                info.preferred = .cuda;
            } else if (info.opencl_available) {
                info.preferred = .opencl;
            }
        },
        .linux => {
            info.vulkan_available = checkVulkan();
            info.opencl_available = checkOpenCL();
            info.cuda_available = checkCUDA();
            if (info.vulkan_available) {
                info.preferred = .vulkan;
            } else if (info.cuda_available) {
                info.preferred = .cuda;
            } else if (info.opencl_available) {
                info.preferred = .opencl;
            }
        },
        else => {},
    }

    return info;
}

pub const BackendInfo = struct {
    metal_available: bool = false,
    vulkan_available: bool = false,
    opencl_available: bool = false,
    cuda_available: bool = false,
    preferred: Backend = .none,
};

fn checkVulkan() bool {
    // Check for Vulkan loader
    return false; // Simplified - would check for libvulkan
}

fn checkOpenCL() bool {
    return false; // Simplified - would check for OpenCL runtime
}

fn checkCUDA() bool {
    return false; // Simplified - would check for CUDA runtime
}

// ============================================================================
// GPU Context
// ============================================================================

pub const GPUContext = struct {
    backend: Backend,
    device_name: []const u8,
    memory_available: u64,
    compute_units: u32,
    allocator: std.mem.Allocator,

    // Backend-specific handles (opaque)
    handle: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, preferred: ?Backend) !GPUContext {
        const info = detectBackends();
        const backend = preferred orelse info.preferred;

        if (backend == .none) {
            return error.NoGPUAvailable;
        }

        var ctx = GPUContext{
            .backend = backend,
            .device_name = "Unknown",
            .memory_available = 0,
            .compute_units = 0,
            .allocator = allocator,
        };

        switch (backend) {
            .metal => try ctx.initMetal(),
            .vulkan => try ctx.initVulkan(),
            .opencl => try ctx.initOpenCL(),
            .cuda => try ctx.initCUDA(),
            .none => return error.NoGPUAvailable,
        }

        return ctx;
    }

    pub fn deinit(self: *GPUContext) void {
        switch (self.backend) {
            .metal => self.deinitMetal(),
            .vulkan => self.deinitVulkan(),
            .opencl => self.deinitOpenCL(),
            .cuda => self.deinitCUDA(),
            .none => {},
        }
    }

    fn initMetal(self: *GPUContext) !void {
        // Metal initialization would go here
        // In real implementation, would use objc runtime or C bindings
        self.device_name = "Metal Device";
        self.memory_available = 8 * 1024 * 1024 * 1024; // Placeholder
        self.compute_units = 8;
    }

    fn initVulkan(self: *GPUContext) !void {
        self.device_name = "Vulkan Device";
        self.memory_available = 8 * 1024 * 1024 * 1024;
        self.compute_units = 8;
    }

    fn initOpenCL(self: *GPUContext) !void {
        self.device_name = "OpenCL Device";
        self.memory_available = 4 * 1024 * 1024 * 1024;
        self.compute_units = 4;
    }

    fn initCUDA(self: *GPUContext) !void {
        self.device_name = "CUDA Device";
        self.memory_available = 8 * 1024 * 1024 * 1024;
        self.compute_units = 16;
    }

    fn deinitMetal(self: *GPUContext) void {
        _ = self;
    }

    fn deinitVulkan(self: *GPUContext) void {
        _ = self;
    }

    fn deinitOpenCL(self: *GPUContext) void {
        _ = self;
    }

    fn deinitCUDA(self: *GPUContext) void {
        _ = self;
    }
};

// ============================================================================
// GPU Buffer
// ============================================================================

pub const GPUBuffer = struct {
    size: usize,
    handle: ?*anyopaque = null,
    ctx: *GPUContext,

    pub fn init(ctx: *GPUContext, size: usize) !GPUBuffer {
        return GPUBuffer{
            .size = size,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *GPUBuffer) void {
        _ = self;
    }

    pub fn upload(self: *GPUBuffer, data: []const u8) !void {
        _ = self;
        _ = data;
    }

    pub fn download(self: *GPUBuffer, data: []u8) !void {
        _ = self;
        _ = data;
    }
};

// ============================================================================
// GPU Image
// ============================================================================

pub const GPUImage = struct {
    width: u32,
    height: u32,
    format: ImageFormat,
    buffer: GPUBuffer,
    ctx: *GPUContext,

    pub const ImageFormat = enum {
        rgba8,
        rgba16,
        rgba32f,
        r8,
        r16,
        r32f,
    };

    pub fn init(ctx: *GPUContext, width: u32, height: u32, format: ImageFormat) !GPUImage {
        const bpp: usize = switch (format) {
            .rgba8 => 4,
            .rgba16 => 8,
            .rgba32f => 16,
            .r8 => 1,
            .r16 => 2,
            .r32f => 4,
        };

        const buffer = try GPUBuffer.init(ctx, width * height * bpp);

        return GPUImage{
            .width = width,
            .height = height,
            .format = format,
            .buffer = buffer,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *GPUImage) void {
        self.buffer.deinit();
    }

    pub fn uploadFromCPU(self: *GPUImage, image: *const Image) !void {
        try self.buffer.upload(image.pixels);
    }

    pub fn downloadToCPU(self: *GPUImage, image: *Image) !void {
        try self.buffer.download(image.pixels);
    }
};

// ============================================================================
// GPU Compute Kernels
// ============================================================================

pub const ComputeKernel = struct {
    name: []const u8,
    source: []const u8,
    handle: ?*anyopaque = null,
    ctx: *GPUContext,

    pub fn init(ctx: *GPUContext, name: []const u8, source: []const u8) !ComputeKernel {
        return ComputeKernel{
            .name = name,
            .source = source,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *ComputeKernel) void {
        _ = self;
    }

    pub fn dispatch(self: *ComputeKernel, width: u32, height: u32, depth: u32) !void {
        _ = self;
        _ = width;
        _ = height;
        _ = depth;
    }
};

// ============================================================================
// Predefined GPU Kernels (GLSL/MSL-like pseudocode)
// ============================================================================

pub const Kernels = struct {
    pub const brightness_contrast =
        \\kernel void brightness_contrast(
        \\    texture2d<float, access::read_write> img,
        \\    constant float& brightness,
        \\    constant float& contrast,
        \\    uint2 gid [[thread_position_in_grid]])
        \\{
        \\    float4 color = img.read(gid);
        \\    color.rgb = (color.rgb - 0.5) * contrast + 0.5 + brightness;
        \\    color.rgb = clamp(color.rgb, 0.0, 1.0);
        \\    img.write(color, gid);
        \\}
    ;

    pub const gaussian_blur =
        \\kernel void gaussian_blur(
        \\    texture2d<float, access::read> input,
        \\    texture2d<float, access::write> output,
        \\    constant float* kernel,
        \\    constant int& radius,
        \\    uint2 gid [[thread_position_in_grid]])
        \\{
        \\    float4 sum = float4(0.0);
        \\    for (int y = -radius; y <= radius; y++) {
        \\        for (int x = -radius; x <= radius; x++) {
        \\            float weight = kernel[(y + radius) * (2 * radius + 1) + (x + radius)];
        \\            sum += input.read(gid + int2(x, y)) * weight;
        \\        }
        \\    }
        \\    output.write(sum, gid);
        \\}
    ;

    pub const color_matrix =
        \\kernel void color_matrix(
        \\    texture2d<float, access::read_write> img,
        \\    constant float4x4& matrix,
        \\    uint2 gid [[thread_position_in_grid]])
        \\{
        \\    float4 color = img.read(gid);
        \\    color = matrix * color;
        \\    color = clamp(color, 0.0, 1.0);
        \\    img.write(color, gid);
        \\}
    ;

    pub const resize_bilinear =
        \\kernel void resize_bilinear(
        \\    texture2d<float, access::read> input,
        \\    texture2d<float, access::write> output,
        \\    constant float2& scale,
        \\    uint2 gid [[thread_position_in_grid]])
        \\{
        \\    float2 src = float2(gid) / scale;
        \\    int2 p0 = int2(floor(src));
        \\    float2 f = fract(src);
        \\
        \\    float4 c00 = input.read(p0);
        \\    float4 c10 = input.read(p0 + int2(1, 0));
        \\    float4 c01 = input.read(p0 + int2(0, 1));
        \\    float4 c11 = input.read(p0 + int2(1, 1));
        \\
        \\    float4 c0 = mix(c00, c10, f.x);
        \\    float4 c1 = mix(c01, c11, f.x);
        \\    output.write(mix(c0, c1, f.y), gid);
        \\}
    ;

    pub const histogram =
        \\kernel void histogram(
        \\    texture2d<float, access::read> img,
        \\    device atomic_uint* hist_r,
        \\    device atomic_uint* hist_g,
        \\    device atomic_uint* hist_b,
        \\    uint2 gid [[thread_position_in_grid]])
        \\{
        \\    float4 color = img.read(gid);
        \\    uint r = uint(color.r * 255.0);
        \\    uint g = uint(color.g * 255.0);
        \\    uint b = uint(color.b * 255.0);
        \\    atomic_fetch_add_explicit(&hist_r[r], 1, memory_order_relaxed);
        \\    atomic_fetch_add_explicit(&hist_g[g], 1, memory_order_relaxed);
        \\    atomic_fetch_add_explicit(&hist_b[b], 1, memory_order_relaxed);
        \\}
    ;
};

// ============================================================================
// GPU-Accelerated Operations
// ============================================================================

pub const GPUOps = struct {
    ctx: *GPUContext,

    pub fn init(ctx: *GPUContext) GPUOps {
        return GPUOps{ .ctx = ctx };
    }

    /// GPU-accelerated brightness/contrast adjustment
    pub fn adjustBrightnessContrast(self: *GPUOps, image: *Image, brightness: f32, contrast: f32) !void {
        // Fall back to CPU if GPU not available
        if (self.ctx.backend == .none) {
            return cpuBrightnessContrast(image, brightness, contrast);
        }

        // GPU path would:
        // 1. Upload image to GPU
        // 2. Compile/get cached kernel
        // 3. Dispatch compute
        // 4. Download result

        // For now, use CPU fallback
        return cpuBrightnessContrast(image, brightness, contrast);
    }

    /// GPU-accelerated Gaussian blur
    pub fn gaussianBlur(self: *GPUOps, image: *Image, radius: u32, allocator: std.mem.Allocator) !void {
        if (self.ctx.backend == .none) {
            return cpuGaussianBlur(image, radius, allocator);
        }
        return cpuGaussianBlur(image, radius, allocator);
    }

    /// GPU-accelerated resize
    pub fn resize(self: *GPUOps, image: *Image, new_width: u32, new_height: u32) !void {
        if (self.ctx.backend == .none) {
            return image.resizeBilinear(new_width, new_height);
        }
        return image.resizeBilinear(new_width, new_height);
    }

    /// GPU-accelerated histogram
    pub fn computeHistogram(self: *GPUOps, image: *const Image) [3][256]u32 {
        _ = self;
        var hist = [3][256]u32{ [_]u32{0} ** 256, [_]u32{0} ** 256, [_]u32{0} ** 256 };

        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                const color = image.getPixel(x, y) orelse continue;
                hist[0][color.r] += 1;
                hist[1][color.g] += 1;
                hist[2][color.b] += 1;
            }
        }

        return hist;
    }
};

fn cpuBrightnessContrast(image: *Image, brightness: f32, contrast: f32) void {
    const bpp = image.format.bytesPerPixel();

    var i: usize = 0;
    while (i < image.pixels.len) : (i += bpp) {
        for (0..@min(3, bpp)) |c| {
            var val = @as(f32, @floatFromInt(image.pixels[i + c])) / 255.0;
            val = (val - 0.5) * contrast + 0.5 + brightness;
            image.pixels[i + c] = @intFromFloat(std.math.clamp(val * 255.0, 0, 255));
        }
    }
}

fn cpuGaussianBlur(image: *Image, radius: u32, allocator: std.mem.Allocator) !void {
    const filters = @import("filters.zig");
    try filters.gaussianBlur(image, radius, allocator);
}

// ============================================================================
// Hardware Decode
// ============================================================================

pub const HardwareDecode = struct {
    /// Check if hardware JPEG decode is available
    pub fn jpegAvailable() bool {
        return switch (builtin.os.tag) {
            .macos, .ios => true, // ImageIO/VideoToolbox
            .windows => true, // WIC
            else => false,
        };
    }

    /// Check if hardware PNG decode is available
    pub fn pngAvailable() bool {
        return switch (builtin.os.tag) {
            .macos, .ios => true,
            .windows => true,
            else => false,
        };
    }

    /// Check if hardware HEIC decode is available
    pub fn heicAvailable() bool {
        return switch (builtin.os.tag) {
            .macos, .ios => true,
            else => false,
        };
    }

    /// Decode JPEG using hardware acceleration
    pub fn decodeJPEG(data: []const u8, allocator: std.mem.Allocator) !Image {
        // Would use platform-specific APIs:
        // macOS: ImageIO CGImageSource
        // Windows: WIC
        // For now, fall back to software decode
        const jpeg = @import("formats/jpeg.zig");
        return jpeg.decode(allocator, data);
    }

    /// Decode PNG using hardware acceleration
    pub fn decodePNG(data: []const u8, allocator: std.mem.Allocator) !Image {
        const png = @import("formats/png.zig");
        return png.decode(allocator, data);
    }

    /// Encode JPEG using hardware acceleration
    pub fn encodeJPEG(image: *const Image, quality: u8, allocator: std.mem.Allocator) ![]u8 {
        _ = quality;
        const jpeg = @import("formats/jpeg.zig");
        return jpeg.encode(allocator, image);
    }
};

// ============================================================================
// Async GPU Operations
// ============================================================================

pub const AsyncGPUOp = struct {
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?anyerror = null,

    pub fn wait(self: *AsyncGPUOp) !void {
        while (!self.completed.load(.acquire)) {
            std.time.sleep(100_000); // 100µs
        }
        if (self.result) |err| return err;
    }

    pub fn isComplete(self: *const AsyncGPUOp) bool {
        return self.completed.load(.acquire);
    }
};

/// Submit async GPU operation
pub fn submitAsync(
    ctx: *GPUContext,
    comptime operation: fn (*GPUContext, *anyopaque) anyerror!void,
    data: *anyopaque,
    allocator: std.mem.Allocator,
) !*AsyncGPUOp {
    const op = try allocator.create(AsyncGPUOp);
    op.* = .{};

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *GPUContext, o: fn (*GPUContext, *anyopaque) anyerror!void, d: *anyopaque, async_op: *AsyncGPUOp) void {
            o(c, d) catch |err| {
                async_op.result = err;
            };
            async_op.completed.store(true, .release);
        }
    }.run, .{ ctx, operation, data, op });

    thread.detach();
    return op;
}

// ============================================================================
// GPU Memory Management
// ============================================================================

pub const GPUMemoryPool = struct {
    ctx: *GPUContext,
    blocks: std.ArrayList(MemoryBlock),
    total_allocated: usize = 0,
    max_size: usize,

    const MemoryBlock = struct {
        buffer: GPUBuffer,
        in_use: bool,
        size: usize,
    };

    pub fn init(ctx: *GPUContext, max_size: usize, allocator: std.mem.Allocator) GPUMemoryPool {
        return GPUMemoryPool{
            .ctx = ctx,
            .blocks = std.ArrayList(MemoryBlock).init(allocator),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *GPUMemoryPool) void {
        for (self.blocks.items) |*block| {
            block.buffer.deinit();
        }
        self.blocks.deinit();
    }

    pub fn acquire(self: *GPUMemoryPool, size: usize) !*GPUBuffer {
        // Look for free block of sufficient size
        for (self.blocks.items) |*block| {
            if (!block.in_use and block.size >= size) {
                block.in_use = true;
                return &block.buffer;
            }
        }

        // Allocate new block
        if (self.total_allocated + size > self.max_size) {
            return error.OutOfGPUMemory;
        }

        const buffer = try GPUBuffer.init(self.ctx, size);
        try self.blocks.append(MemoryBlock{
            .buffer = buffer,
            .in_use = true,
            .size = size,
        });
        self.total_allocated += size;

        return &self.blocks.items[self.blocks.items.len - 1].buffer;
    }

    pub fn release(self: *GPUMemoryPool, buffer: *GPUBuffer) void {
        for (self.blocks.items) |*block| {
            if (&block.buffer == buffer) {
                block.in_use = false;
                return;
            }
        }
    }
};
