// Home Video Library - CUDA GPU Compute
// Production CUDA GPU acceleration for NVIDIA GPUs
// https://developer.nvidia.com/cuda-toolkit

const std = @import("std");
const core = @import("../core/frame.zig");

pub const VideoFrame = core.VideoFrame;

// ============================================================================
// CUDA C FFI Bindings
// ============================================================================

// CUDA types
pub const CUdevice = c_int;
pub const CUcontext = *opaque {};
pub const CUmodule = *opaque {};
pub const CUfunction = *opaque {};
pub const CUstream = *opaque {};
pub const CUdeviceptr = u64;

pub const CUresult = enum(c_uint) {
    CUDA_SUCCESS = 0,
    CUDA_ERROR_INVALID_VALUE = 1,
    CUDA_ERROR_OUT_OF_MEMORY = 2,
    CUDA_ERROR_NOT_INITIALIZED = 3,
    CUDA_ERROR_DEINITIALIZED = 4,
    CUDA_ERROR_PROFILER_DISABLED = 5,
    CUDA_ERROR_PROFILER_NOT_INITIALIZED = 6,
    CUDA_ERROR_PROFILER_ALREADY_STARTED = 7,
    CUDA_ERROR_PROFILER_ALREADY_STOPPED = 8,
    CUDA_ERROR_NO_DEVICE = 100,
    CUDA_ERROR_INVALID_DEVICE = 101,
    CUDA_ERROR_INVALID_IMAGE = 200,
    CUDA_ERROR_INVALID_CONTEXT = 201,
    CUDA_ERROR_CONTEXT_ALREADY_CURRENT = 202,
    CUDA_ERROR_MAP_FAILED = 205,
    CUDA_ERROR_UNMAP_FAILED = 206,
    CUDA_ERROR_ARRAY_IS_MAPPED = 207,
    CUDA_ERROR_ALREADY_MAPPED = 208,
    CUDA_ERROR_NO_BINARY_FOR_GPU = 209,
    CUDA_ERROR_ALREADY_ACQUIRED = 210,
    CUDA_ERROR_NOT_MAPPED = 211,
    CUDA_ERROR_NOT_MAPPED_AS_ARRAY = 212,
    CUDA_ERROR_NOT_MAPPED_AS_POINTER = 213,
    CUDA_ERROR_ECC_UNCORRECTABLE = 214,
    CUDA_ERROR_UNSUPPORTED_LIMIT = 215,
    CUDA_ERROR_CONTEXT_ALREADY_IN_USE = 216,
    CUDA_ERROR_INVALID_SOURCE = 300,
    CUDA_ERROR_FILE_NOT_FOUND = 301,
    CUDA_ERROR_SHARED_OBJECT_SYMBOL_NOT_FOUND = 302,
    CUDA_ERROR_SHARED_OBJECT_INIT_FAILED = 303,
    CUDA_ERROR_OPERATING_SYSTEM = 304,
    CUDA_ERROR_INVALID_HANDLE = 400,
    CUDA_ERROR_NOT_FOUND = 500,
    CUDA_ERROR_NOT_READY = 600,
    CUDA_ERROR_LAUNCH_FAILED = 700,
    CUDA_ERROR_LAUNCH_OUT_OF_RESOURCES = 701,
    CUDA_ERROR_LAUNCH_TIMEOUT = 702,
    CUDA_ERROR_LAUNCH_INCOMPATIBLE_TEXTURING = 703,
    CUDA_ERROR_UNKNOWN = 999,
    _,
};

pub const CUjit_option = enum(c_uint) {
    CU_JIT_MAX_REGISTERS = 0,
    CU_JIT_THREADS_PER_BLOCK = 1,
    CU_JIT_WALL_TIME = 2,
    CU_JIT_INFO_LOG_BUFFER = 3,
    CU_JIT_INFO_LOG_BUFFER_SIZE_BYTES = 4,
    CU_JIT_ERROR_LOG_BUFFER = 5,
    CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES = 6,
    CU_JIT_OPTIMIZATION_LEVEL = 7,
    CU_JIT_TARGET_FROM_CUCONTEXT = 8,
    CU_JIT_TARGET = 9,
    CU_JIT_FALLBACK_STRATEGY = 10,
    _,
};

// CUDA Driver API functions
extern "c" fn cuInit(flags: c_uint) CUresult;
extern "c" fn cuDeviceGet(device: *CUdevice, ordinal: c_int) CUresult;
extern "c" fn cuDeviceGetCount(count: *c_int) CUresult;
extern "c" fn cuDeviceGetName(name: [*]u8, len: c_int, dev: CUdevice) CUresult;
extern "c" fn cuDeviceComputeCapability(
    major: *c_int,
    minor: *c_int,
    dev: CUdevice,
) CUresult;
extern "c" fn cuDeviceTotalMem_v2(bytes: *usize, dev: CUdevice) CUresult;
extern "c" fn cuDeviceGetAttribute(
    pi: *c_int,
    attrib: c_int,
    dev: CUdevice,
) CUresult;

extern "c" fn cuCtxCreate_v2(pctx: *?CUcontext, flags: c_uint, dev: CUdevice) CUresult;
extern "c" fn cuCtxDestroy_v2(ctx: CUcontext) CUresult;
extern "c" fn cuCtxPushCurrent_v2(ctx: CUcontext) CUresult;
extern "c" fn cuCtxPopCurrent_v2(pctx: *?CUcontext) CUresult;
extern "c" fn cuCtxSynchronize() CUresult;

extern "c" fn cuMemAlloc_v2(dptr: *CUdeviceptr, bytesize: usize) CUresult;
extern "c" fn cuMemFree_v2(dptr: CUdeviceptr) CUresult;
extern "c" fn cuMemcpyHtoD_v2(
    dstDevice: CUdeviceptr,
    srcHost: *const anyopaque,
    ByteCount: usize,
) CUresult;
extern "c" fn cuMemcpyDtoH_v2(
    dstHost: *anyopaque,
    srcDevice: CUdeviceptr,
    ByteCount: usize,
) CUresult;
extern "c" fn cuMemcpyDtoD_v2(
    dstDevice: CUdeviceptr,
    srcDevice: CUdeviceptr,
    ByteCount: usize,
) CUresult;

extern "c" fn cuModuleLoadDataEx(
    module: *?CUmodule,
    image: *const anyopaque,
    numOptions: c_uint,
    options: ?[*]CUjit_option,
    optionValues: ?[*]*anyopaque,
) CUresult;
extern "c" fn cuModuleUnload(module: CUmodule) CUresult;
extern "c" fn cuModuleGetFunction(
    hfunc: *?CUfunction,
    hmod: CUmodule,
    name: [*:0]const u8,
) CUresult;

extern "c" fn cuLaunchKernel(
    f: CUfunction,
    gridDimX: c_uint,
    gridDimY: c_uint,
    gridDimZ: c_uint,
    blockDimX: c_uint,
    blockDimY: c_uint,
    blockDimZ: c_uint,
    sharedMemBytes: c_uint,
    hStream: ?CUstream,
    kernelParams: ?[*]?*anyopaque,
    extra: ?[*]?*anyopaque,
) CUresult;

extern "c" fn cuStreamCreate(phStream: *?CUstream, Flags: c_uint) CUresult;
extern "c" fn cuStreamDestroy_v2(hStream: CUstream) CUresult;
extern "c" fn cuStreamSynchronize(hStream: CUstream) CUresult;

// Device attributes
pub const CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK: c_int = 1;
pub const CU_DEVICE_ATTRIBUTE_MAX_BLOCK_DIM_X: c_int = 2;
pub const CU_DEVICE_ATTRIBUTE_MAX_BLOCK_DIM_Y: c_int = 3;
pub const CU_DEVICE_ATTRIBUTE_MAX_BLOCK_DIM_Z: c_int = 4;
pub const CU_DEVICE_ATTRIBUTE_MAX_GRID_DIM_X: c_int = 5;
pub const CU_DEVICE_ATTRIBUTE_MAX_GRID_DIM_Y: c_int = 6;
pub const CU_DEVICE_ATTRIBUTE_MAX_GRID_DIM_Z: c_int = 7;
pub const CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT: c_int = 16;

// ============================================================================
// CUDA Kernels (PTX Assembly)
// ============================================================================

// YUV to RGB kernel (PTX for compute capability 5.0+)
const PTX_YUV_TO_RGB =
    \\.version 7.0
    \\.target sm_50
    \\.address_size 64
    \\
    \\.visible .entry yuv_to_rgb(
    \\    .param .u64 yuv_to_rgb_param_0,
    \\    .param .u64 yuv_to_rgb_param_1,
    \\    .param .u64 yuv_to_rgb_param_2,
    \\    .param .u64 yuv_to_rgb_param_3,
    \\    .param .u32 yuv_to_rgb_param_4,
    \\    .param .u32 yuv_to_rgb_param_5
    \\)
    \\{
    \\    .reg .pred %p<4>;
    \\    .reg .f32 %f<20>;
    \\    .reg .u32 %r<20>;
    \\    .reg .u64 %rd<20>;
    \\
    \\    ld.param.u64 %rd1, [yuv_to_rgb_param_0]; // Y plane
    \\    ld.param.u64 %rd2, [yuv_to_rgb_param_1]; // U plane
    \\    ld.param.u64 %rd3, [yuv_to_rgb_param_2]; // V plane
    \\    ld.param.u64 %rd4, [yuv_to_rgb_param_3]; // RGB output
    \\    ld.param.u32 %r1, [yuv_to_rgb_param_4];  // width
    \\    ld.param.u32 %r2, [yuv_to_rgb_param_5];  // height
    \\
    \\    mov.u32 %r3, %ctaid.x;
    \\    mov.u32 %r4, %ntid.x;
    \\    mov.u32 %r5, %tid.x;
    \\    mad.lo.u32 %r6, %r3, %r4, %r5; // x = blockIdx.x * blockDim.x + threadIdx.x
    \\
    \\    mov.u32 %r7, %ctaid.y;
    \\    mov.u32 %r8, %ntid.y;
    \\    mov.u32 %r9, %tid.y;
    \\    mad.lo.u32 %r10, %r7, %r8, %r9; // y = blockIdx.y * blockDim.y + threadIdx.y
    \\
    \\    setp.ge.u32 %p1, %r6, %r1; // if (x >= width) return
    \\    setp.ge.u32 %p2, %r10, %r2; // if (y >= height) return
    \\    or.pred %p3, %p1, %p2;
    \\    @%p3 bra EXIT;
    \\
    \\    // idx = y * width + x
    \\    mad.lo.u32 %r11, %r10, %r1, %r6;
    \\
    \\    // Load Y, U, V values
    \\    cvt.u64.u32 %rd5, %r11;
    \\    add.u64 %rd6, %rd1, %rd5;
    \\    ld.global.u8 %r12, [%rd6]; // Y
    \\
    \\    add.u64 %rd7, %rd2, %rd5;
    \\    ld.global.u8 %r13, [%rd7]; // U
    \\
    \\    add.u64 %rd8, %rd3, %rd5;
    \\    ld.global.u8 %r14, [%rd8]; // V
    \\
    \\    // Normalize to [0, 1]
    \\    cvt.rn.f32.u32 %f1, %r12;
    \\    div.rn.f32 %f2, %f1, 255.0;
    \\
    \\    cvt.rn.f32.u32 %f3, %r13;
    \\    div.rn.f32 %f4, %f3, 255.0;
    \\    sub.f32 %f5, %f4, 0.5;
    \\
    \\    cvt.rn.f32.u32 %f6, %r14;
    \\    div.rn.f32 %f7, %f6, 255.0;
    \\    sub.f32 %f8, %f7, 0.5;
    \\
    \\    // BT.709 conversion
    \\    // R = Y + 1.402 * V
    \\    fma.rn.f32 %f9, %f8, 1.402, %f2;
    \\    // G = Y - 0.344136 * U - 0.714136 * V
    \\    mul.f32 %f10, %f5, 0.344136;
    \\    mul.f32 %f11, %f8, 0.714136;
    \\    sub.f32 %f12, %f2, %f10;
    \\    sub.f32 %f13, %f12, %f11;
    \\    // B = Y + 1.772 * U
    \\    fma.rn.f32 %f14, %f5, 1.772, %f2;
    \\
    \\    // Clamp to [0, 1] and scale to [0, 255]
    \\    max.f32 %f15, %f9, 0.0;
    \\    min.f32 %f16, %f15, 1.0;
    \\    mul.f32 %f17, %f16, 255.0;
    \\    cvt.rni.u32.f32 %r15, %f17;
    \\
    \\    max.f32 %f15, %f13, 0.0;
    \\    min.f32 %f16, %f15, 1.0;
    \\    mul.f32 %f17, %f16, 255.0;
    \\    cvt.rni.u32.f32 %r16, %f17;
    \\
    \\    max.f32 %f15, %f14, 0.0;
    \\    min.f32 %f16, %f15, 1.0;
    \\    mul.f32 %f17, %f16, 255.0;
    \\    cvt.rni.u32.f32 %r17, %f17;
    \\
    \\    // Store RGB
    \\    mul.lo.u32 %r18, %r11, 3;
    \\    cvt.u64.u32 %rd9, %r18;
    \\    add.u64 %rd10, %rd4, %rd9;
    \\    st.global.u8 [%rd10], %r15;       // R
    \\
    \\    add.u64 %rd11, %rd10, 1;
    \\    st.global.u8 [%rd11], %r16;       // G
    \\
    \\    add.u64 %rd12, %rd10, 2;
    \\    st.global.u8 [%rd12], %r17;       // B
    \\
    \\EXIT:
    \\    ret;
    \\}
;

// RGB to YUV kernel
const PTX_RGB_TO_YUV =
    \\.version 7.0
    \\.target sm_50
    \\.address_size 64
    \\
    \\.visible .entry rgb_to_yuv(
    \\    .param .u64 rgb_to_yuv_param_0,
    \\    .param .u64 rgb_to_yuv_param_1,
    \\    .param .u64 rgb_to_yuv_param_2,
    \\    .param .u64 rgb_to_yuv_param_3,
    \\    .param .u32 rgb_to_yuv_param_4,
    \\    .param .u32 rgb_to_yuv_param_5
    \\)
    \\{
    \\    .reg .pred %p<4>;
    \\    .reg .f32 %f<20>;
    \\    .reg .u32 %r<20>;
    \\    .reg .u64 %rd<20>;
    \\
    \\    ld.param.u64 %rd1, [rgb_to_yuv_param_0]; // RGB input
    \\    ld.param.u64 %rd2, [rgb_to_yuv_param_1]; // Y plane
    \\    ld.param.u64 %rd3, [rgb_to_yuv_param_2]; // U plane
    \\    ld.param.u64 %rd4, [rgb_to_yuv_param_3]; // V plane
    \\    ld.param.u32 %r1, [rgb_to_yuv_param_4];  // width
    \\    ld.param.u32 %r2, [rgb_to_yuv_param_5];  // height
    \\
    \\    mov.u32 %r3, %ctaid.x;
    \\    mov.u32 %r4, %ntid.x;
    \\    mov.u32 %r5, %tid.x;
    \\    mad.lo.u32 %r6, %r3, %r4, %r5;
    \\
    \\    mov.u32 %r7, %ctaid.y;
    \\    mov.u32 %r8, %ntid.y;
    \\    mov.u32 %r9, %tid.y;
    \\    mad.lo.u32 %r10, %r7, %r8, %r9;
    \\
    \\    setp.ge.u32 %p1, %r6, %r1;
    \\    setp.ge.u32 %p2, %r10, %r2;
    \\    or.pred %p3, %p1, %p2;
    \\    @%p3 bra EXIT;
    \\
    \\    mad.lo.u32 %r11, %r10, %r1, %r6;
    \\
    \\    // Load RGB
    \\    mul.lo.u32 %r12, %r11, 3;
    \\    cvt.u64.u32 %rd5, %r12;
    \\    add.u64 %rd6, %rd1, %rd5;
    \\    ld.global.u8 %r13, [%rd6];       // R
    \\
    \\    add.u64 %rd7, %rd6, 1;
    \\    ld.global.u8 %r14, [%rd7];       // G
    \\
    \\    add.u64 %rd8, %rd6, 2;
    \\    ld.global.u8 %r15, [%rd8];       // B
    \\
    \\    // Normalize
    \\    cvt.rn.f32.u32 %f1, %r13;
    \\    div.rn.f32 %f2, %f1, 255.0;
    \\
    \\    cvt.rn.f32.u32 %f3, %r14;
    \\    div.rn.f32 %f4, %f3, 255.0;
    \\
    \\    cvt.rn.f32.u32 %f5, %r15;
    \\    div.rn.f32 %f6, %f5, 255.0;
    \\
    \\    // BT.709 conversion
    \\    // Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
    \\    mul.f32 %f7, %f2, 0.2126;
    \\    fma.rn.f32 %f8, %f4, 0.7152, %f7;
    \\    fma.rn.f32 %f9, %f6, 0.0722, %f8;
    \\
    \\    // U = -0.09991 * R - 0.33609 * G + 0.436 * B + 0.5
    \\    mul.f32 %f10, %f2, 0.09991;
    \\    neg.f32 %f11, %f10;
    \\    fma.rn.f32 %f12, %f4, -0.33609, %f11;
    \\    fma.rn.f32 %f13, %f6, 0.436, %f12;
    \\    add.f32 %f14, %f13, 0.5;
    \\
    \\    // V = 0.615 * R - 0.55861 * G - 0.05639 * B + 0.5
    \\    mul.f32 %f15, %f2, 0.615;
    \\    fma.rn.f32 %f16, %f4, -0.55861, %f15;
    \\    fma.rn.f32 %f17, %f6, -0.05639, %f16;
    \\    add.f32 %f18, %f17, 0.5;
    \\
    \\    // Clamp and scale
    \\    max.f32 %f9, %f9, 0.0;
    \\    min.f32 %f9, %f9, 1.0;
    \\    mul.f32 %f9, %f9, 255.0;
    \\    cvt.rni.u32.f32 %r16, %f9;
    \\
    \\    max.f32 %f14, %f14, 0.0;
    \\    min.f32 %f14, %f14, 1.0;
    \\    mul.f32 %f14, %f14, 255.0;
    \\    cvt.rni.u32.f32 %r17, %f14;
    \\
    \\    max.f32 %f18, %f18, 0.0;
    \\    min.f32 %f18, %f18, 1.0;
    \\    mul.f32 %f18, %f18, 255.0;
    \\    cvt.rni.u32.f32 %r18, %f18;
    \\
    \\    // Store YUV
    \\    cvt.u64.u32 %rd9, %r11;
    \\    add.u64 %rd10, %rd2, %rd9;
    \\    st.global.u8 [%rd10], %r16;      // Y
    \\
    \\    add.u64 %rd11, %rd3, %rd9;
    \\    st.global.u8 [%rd11], %r17;      // U
    \\
    \\    add.u64 %rd12, %rd4, %rd9;
    \\    st.global.u8 [%rd12], %r18;      // V
    \\
    \\EXIT:
    \\    ret;
    \\}
;

// ============================================================================
// Zig Wrapper
// ============================================================================

/// CUDA Device
pub const CUDADevice = struct {
    device: CUdevice,
    context: CUcontext,
    name: []u8,
    compute_capability: struct { major: i32, minor: i32 },
    total_memory: usize,
    multiprocessor_count: i32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device_id: u32) !Self {
        // Initialize CUDA
        var result = cuInit(0);
        if (result != .CUDA_SUCCESS) {
            return error.CUDAInitFailed;
        }

        // Get device
        var device: CUdevice = 0;
        result = cuDeviceGet(&device, @intCast(device_id));
        if (result != .CUDA_SUCCESS) {
            return error.InvalidDeviceId;
        }

        // Get device name
        var name_buf: [256]u8 = undefined;
        result = cuDeviceGetName(&name_buf, name_buf.len, device);
        if (result != .CUDA_SUCCESS) {
            return error.FailedToGetDeviceName;
        }

        const null_pos = std.mem.indexOfScalar(u8, &name_buf, 0) orelse name_buf.len;
        const name = try allocator.dupe(u8, name_buf[0..null_pos]);
        errdefer allocator.free(name);

        // Get compute capability
        var major: c_int = 0;
        var minor: c_int = 0;
        result = cuDeviceComputeCapability(&major, &minor, device);
        if (result != .CUDA_SUCCESS) {
            return error.FailedToGetComputeCapability;
        }

        // Get total memory
        var total_mem: usize = 0;
        result = cuDeviceTotalMem_v2(&total_mem, device);
        if (result != .CUDA_SUCCESS) {
            return error.FailedToGetTotalMemory;
        }

        // Get multiprocessor count
        var mp_count: c_int = 0;
        result = cuDeviceGetAttribute(&mp_count, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, device);
        if (result != .CUDA_SUCCESS) {
            return error.FailedToGetMultiprocessorCount;
        }

        // Create context
        var context: ?CUcontext = null;
        result = cuCtxCreate_v2(&context, 0, device);
        if (result != .CUDA_SUCCESS) {
            return error.FailedToCreateContext;
        }

        return .{
            .device = device,
            .context = context.?,
            .name = name,
            .compute_capability = .{ .major = major, .minor = minor },
            .total_memory = total_mem,
            .multiprocessor_count = mp_count,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = cuCtxDestroy_v2(self.context);
        self.allocator.free(self.name);
    }

    pub fn pushContext(self: *Self) !void {
        const result = cuCtxPushCurrent_v2(self.context);
        if (result != .CUDA_SUCCESS) {
            return error.FailedToPushContext;
        }
    }

    pub fn popContext() !void {
        var popped_ctx: ?CUcontext = null;
        const result = cuCtxPopCurrent_v2(&popped_ctx);
        if (result != .CUDA_SUCCESS) {
            return error.FailedToPopContext;
        }
    }

    pub fn synchronize() !void {
        const result = cuCtxSynchronize();
        if (result != .CUDA_SUCCESS) {
            return error.SynchronizeFailed;
        }
    }

    pub fn enumerateDevices(allocator: std.mem.Allocator) ![]Self {
        var result = cuInit(0);
        if (result != .CUDA_SUCCESS) {
            return error.CUDAInitFailed;
        }

        var device_count: c_int = 0;
        result = cuDeviceGetCount(&device_count);
        if (result != .CUDA_SUCCESS or device_count == 0) {
            return error.NoDevicesFound;
        }

        var devices = try allocator.alloc(Self, @intCast(device_count));
        errdefer allocator.free(devices);

        for (0..@intCast(device_count)) |i| {
            devices[i] = try init(allocator, @intCast(i));
        }

        return devices;
    }
};

/// CUDA Buffer
pub const CUDABuffer = struct {
    device_ptr: CUdeviceptr,
    size: usize,
    device: *CUDADevice,

    const Self = @This();

    pub fn init(device: *CUDADevice, size: usize) !Self {
        try device.pushContext();
        defer CUDADevice.popContext() catch {};

        var device_ptr: CUdeviceptr = 0;
        const result = cuMemAlloc_v2(&device_ptr, size);
        if (result != .CUDA_SUCCESS) {
            return error.AllocationFailed;
        }

        return .{
            .device_ptr = device_ptr,
            .size = size,
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        self.device.pushContext() catch return;
        defer CUDADevice.popContext() catch {};

        _ = cuMemFree_v2(self.device_ptr);
    }

    pub fn upload(self: *Self, data: []const u8) !void {
        if (data.len > self.size) return error.BufferTooSmall;

        try self.device.pushContext();
        defer CUDADevice.popContext() catch {};

        const result = cuMemcpyHtoD_v2(self.device_ptr, data.ptr, data.len);
        if (result != .CUDA_SUCCESS) {
            return error.UploadFailed;
        }
    }

    pub fn download(self: *Self, data: []u8) !void {
        if (data.len < self.size) return error.BufferTooSmall;

        try self.device.pushContext();
        defer CUDADevice.popContext() catch {};

        const result = cuMemcpyDtoH_v2(data.ptr, self.device_ptr, self.size);
        if (result != .CUDA_SUCCESS) {
            return error.DownloadFailed;
        }
    }
};

/// CUDA Module (compiled kernel)
pub const CUDAModule = struct {
    module: CUmodule,
    device: *CUDADevice,

    const Self = @This();

    pub fn initFromPTX(device: *CUDADevice, ptx: []const u8) !Self {
        try device.pushContext();
        defer CUDADevice.popContext() catch {};

        var module: ?CUmodule = null;
        const result = cuModuleLoadDataEx(&module, ptx.ptr, 0, null, null);
        if (result != .CUDA_SUCCESS) {
            return error.FailedToLoadModule;
        }

        return .{
            .module = module.?,
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        self.device.pushContext() catch return;
        defer CUDADevice.popContext() catch {};

        _ = cuModuleUnload(self.module);
    }

    pub fn getFunction(self: *Self, name: [:0]const u8) !CUfunction {
        try self.device.pushContext();
        defer CUDADevice.popContext() catch {};

        var function: ?CUfunction = null;
        const result = cuModuleGetFunction(&function, self.module, name.ptr);
        if (result != .CUDA_SUCCESS) {
            return error.FunctionNotFound;
        }

        return function.?;
    }
};

/// CUDA Compute Context
pub const CUDAComputeContext = struct {
    device: CUDADevice,
    yuv_to_rgb_module: ?CUDAModule = null,
    rgb_to_yuv_module: ?CUDAModule = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device_id: u32) !Self {
        var device = try CUDADevice.init(allocator, device_id);
        errdefer device.deinit();

        return .{
            .device = device,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.yuv_to_rgb_module) |*m| m.deinit();
        if (self.rgb_to_yuv_module) |*m| m.deinit();
        self.device.deinit();
    }

    pub fn yuvToRgb(
        self: *Self,
        y_buffer: *CUDABuffer,
        u_buffer: *CUDABuffer,
        v_buffer: *CUDABuffer,
        rgb_buffer: *CUDABuffer,
        width: u32,
        height: u32,
    ) !void {
        // Lazy load module
        if (self.yuv_to_rgb_module == null) {
            self.yuv_to_rgb_module = try CUDAModule.initFromPTX(&self.device, PTX_YUV_TO_RGB);
        }

        const function = try self.yuv_to_rgb_module.?.getFunction("yuv_to_rgb");

        // Prepare kernel parameters
        var params = [_]?*anyopaque{
            @ptrCast(&y_buffer.device_ptr),
            @ptrCast(&u_buffer.device_ptr),
            @ptrCast(&v_buffer.device_ptr),
            @ptrCast(&rgb_buffer.device_ptr),
            @ptrCast(&width),
            @ptrCast(&height),
        };

        // Launch kernel
        try self.device.pushContext();
        defer CUDADevice.popContext() catch {};

        const block_size_x: u32 = 16;
        const block_size_y: u32 = 16;
        const grid_size_x = (width + block_size_x - 1) / block_size_x;
        const grid_size_y = (height + block_size_y - 1) / block_size_y;

        const result = cuLaunchKernel(
            function,
            grid_size_x,
            grid_size_y,
            1,
            block_size_x,
            block_size_y,
            1,
            0,
            null,
            &params,
            null,
        );

        if (result != .CUDA_SUCCESS) {
            return error.KernelLaunchFailed;
        }

        try CUDADevice.synchronize();
    }

    pub fn rgbToYuv(
        self: *Self,
        rgb_buffer: *CUDABuffer,
        y_buffer: *CUDABuffer,
        u_buffer: *CUDABuffer,
        v_buffer: *CUDABuffer,
        width: u32,
        height: u32,
    ) !void {
        if (self.rgb_to_yuv_module == null) {
            self.rgb_to_yuv_module = try CUDAModule.initFromPTX(&self.device, PTX_RGB_TO_YUV);
        }

        const function = try self.rgb_to_yuv_module.?.getFunction("rgb_to_yuv");

        var params = [_]?*anyopaque{
            @ptrCast(&rgb_buffer.device_ptr),
            @ptrCast(&y_buffer.device_ptr),
            @ptrCast(&u_buffer.device_ptr),
            @ptrCast(&v_buffer.device_ptr),
            @ptrCast(&width),
            @ptrCast(&height),
        };

        try self.device.pushContext();
        defer CUDADevice.popContext() catch {};

        const block_size_x: u32 = 16;
        const block_size_y: u32 = 16;
        const grid_size_x = (width + block_size_x - 1) / block_size_x;
        const grid_size_y = (height + block_size_y - 1) / block_size_y;

        const result = cuLaunchKernel(
            function,
            grid_size_x,
            grid_size_y,
            1,
            block_size_x,
            block_size_y,
            1,
            0,
            null,
            &params,
            null,
        );

        if (result != .CUDA_SUCCESS) {
            return error.KernelLaunchFailed;
        }

        try CUDADevice.synchronize();
    }

    pub fn createBuffer(self: *Self, size: usize) !CUDABuffer {
        return CUDABuffer.init(&self.device, size);
    }
};
