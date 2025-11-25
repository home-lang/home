// Home Video Library - Vulkan GPU Compute
// Production Vulkan GPU acceleration for cross-platform
// https://www.vulkan.org/

const std = @import("std");
const core = @import("../core/frame.zig");

pub const VideoFrame = core.VideoFrame;

// ============================================================================
// Vulkan C FFI Bindings
// ============================================================================

// Vulkan types
pub const VkInstance = *opaque {};
pub const VkPhysicalDevice = *opaque {};
pub const VkDevice = *opaque {};
pub const VkQueue = *opaque {};
pub const VkCommandPool = *opaque {};
pub const VkCommandBuffer = *opaque {};
pub const VkBuffer = *opaque {};
pub const VkDeviceMemory = *opaque {};
pub const VkDescriptorSetLayout = *opaque {};
pub const VkPipelineLayout = *opaque {};
pub const VkShaderModule = *opaque {};
pub const VkPipeline = *opaque {};
pub const VkDescriptorPool = *opaque {};
pub const VkDescriptorSet = *opaque {};

pub const VkResult = enum(i32) {
    SUCCESS = 0,
    NOT_READY = 1,
    TIMEOUT = 2,
    EVENT_SET = 3,
    EVENT_RESET = 4,
    INCOMPLETE = 5,
    ERROR_OUT_OF_HOST_MEMORY = -1,
    ERROR_OUT_OF_DEVICE_MEMORY = -2,
    ERROR_INITIALIZATION_FAILED = -3,
    ERROR_DEVICE_LOST = -4,
    ERROR_MEMORY_MAP_FAILED = -5,
    _,
};

pub const VkStructureType = enum(i32) {
    APPLICATION_INFO = 0,
    INSTANCE_CREATE_INFO = 1,
    DEVICE_QUEUE_CREATE_INFO = 2,
    DEVICE_CREATE_INFO = 3,
    SUBMIT_INFO = 4,
    MEMORY_ALLOCATE_INFO = 5,
    MAPPED_MEMORY_RANGE = 6,
    BIND_SPARSE_INFO = 7,
    FENCE_CREATE_INFO = 8,
    SEMAPHORE_CREATE_INFO = 9,
    EVENT_CREATE_INFO = 10,
    QUERY_POOL_CREATE_INFO = 11,
    BUFFER_CREATE_INFO = 12,
    BUFFER_VIEW_CREATE_INFO = 13,
    IMAGE_CREATE_INFO = 14,
    IMAGE_VIEW_CREATE_INFO = 15,
    SHADER_MODULE_CREATE_INFO = 16,
    PIPELINE_CACHE_CREATE_INFO = 17,
    PIPELINE_SHADER_STAGE_CREATE_INFO = 18,
    PIPELINE_LAYOUT_CREATE_INFO = 30,
    DESCRIPTOR_SET_LAYOUT_CREATE_INFO = 32,
    DESCRIPTOR_POOL_CREATE_INFO = 33,
    DESCRIPTOR_SET_ALLOCATE_INFO = 34,
    WRITE_DESCRIPTOR_SET = 35,
    COMMAND_POOL_CREATE_INFO = 39,
    COMMAND_BUFFER_ALLOCATE_INFO = 40,
    COMMAND_BUFFER_BEGIN_INFO = 42,
    SUBMIT_INFO_2 = 43,
    COMPUTE_PIPELINE_CREATE_INFO = 29,
    _,
};

pub const VkPhysicalDeviceType = enum(i32) {
    OTHER = 0,
    INTEGRATED_GPU = 1,
    DISCRETE_GPU = 2,
    VIRTUAL_GPU = 3,
    CPU = 4,
    _,
};

pub const VkQueueFlagBits = packed struct(u32) {
    graphics: bool = false,
    compute: bool = false,
    transfer: bool = false,
    sparse_binding: bool = false,
    _padding: u28 = 0,
};

pub const VkMemoryPropertyFlagBits = packed struct(u32) {
    device_local: bool = false,
    host_visible: bool = false,
    host_coherent: bool = false,
    host_cached: bool = false,
    lazily_allocated: bool = false,
    _padding: u27 = 0,
};

pub const VkBufferUsageFlagBits = packed struct(u32) {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    uniform_texel_buffer: bool = false,
    storage_texel_buffer: bool = false,
    uniform_buffer: bool = false,
    storage_buffer: bool = false,
    index_buffer: bool = false,
    vertex_buffer: bool = false,
    indirect_buffer: bool = false,
    _padding: u23 = 0,
};

pub const VkApplicationInfo = extern struct {
    sType: VkStructureType = .APPLICATION_INFO,
    pNext: ?*const anyopaque = null,
    pApplicationName: [*:0]const u8,
    applicationVersion: u32,
    pEngineName: [*:0]const u8,
    engineVersion: u32,
    apiVersion: u32,
};

pub const VkInstanceCreateInfo = extern struct {
    sType: VkStructureType = .INSTANCE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pApplicationInfo: *const VkApplicationInfo,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};

pub const VkPhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: VkPhysicalDeviceType,
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    limits: VkPhysicalDeviceLimits,
    sparseProperties: VkPhysicalDeviceSparseProperties,
};

pub const VkPhysicalDeviceLimits = extern struct {
    maxImageDimension1D: u32,
    maxImageDimension2D: u32,
    maxImageDimension3D: u32,
    maxImageDimensionCube: u32,
    maxImageArrayLayers: u32,
    maxTexelBufferElements: u32,
    maxUniformBufferRange: u32,
    maxStorageBufferRange: u32,
    maxPushConstantsSize: u32,
    maxMemoryAllocationCount: u32,
    maxSamplerAllocationCount: u32,
    bufferImageGranularity: u64,
    sparseAddressSpaceSize: u64,
    maxBoundDescriptorSets: u32,
    maxPerStageDescriptorSamplers: u32,
    maxPerStageDescriptorUniformBuffers: u32,
    maxPerStageDescriptorStorageBuffers: u32,
    maxPerStageDescriptorSampledImages: u32,
    maxPerStageDescriptorStorageImages: u32,
    maxPerStageDescriptorInputAttachments: u32,
    maxPerStageResources: u32,
    maxDescriptorSetSamplers: u32,
    maxDescriptorSetUniformBuffers: u32,
    maxDescriptorSetUniformBuffersDynamic: u32,
    maxDescriptorSetStorageBuffers: u32,
    maxDescriptorSetStorageBuffersDynamic: u32,
    maxDescriptorSetSampledImages: u32,
    maxDescriptorSetStorageImages: u32,
    maxDescriptorSetInputAttachments: u32,
    maxVertexInputAttributes: u32,
    maxVertexInputBindings: u32,
    maxVertexInputAttributeOffset: u32,
    maxVertexInputBindingStride: u32,
    maxVertexOutputComponents: u32,
    // ... many more fields (truncated for brevity)
    _reserved: [512]u8 = undefined,
};

pub const VkPhysicalDeviceSparseProperties = extern struct {
    residencyStandard2DBlockShape: u32,
    residencyStandard2DMultisampleBlockShape: u32,
    residencyStandard3DBlockShape: u32,
    residencyAlignedMipSize: u32,
    residencyNonResidentStrict: u32,
};

pub const VkQueueFamilyProperties = extern struct {
    queueFlags: VkQueueFlagBits,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

pub const VkExtent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

pub const VkDeviceQueueCreateInfo = extern struct {
    sType: VkStructureType = .DEVICE_QUEUE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: [*]const f32,
};

pub const VkDeviceCreateInfo = extern struct {
    sType: VkStructureType = .DEVICE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: [*]const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    pEnabledFeatures: ?*const VkPhysicalDeviceFeatures = null,
};

pub const VkPhysicalDeviceFeatures = extern struct {
    robustBufferAccess: u32 = 0,
    fullDrawIndexUint32: u32 = 0,
    imageCubeArray: u32 = 0,
    // ... many more fields
    _reserved: [256]u8 = undefined,
};

pub const VkBufferCreateInfo = extern struct {
    sType: VkStructureType = .BUFFER_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64,
    usage: VkBufferUsageFlagBits,
    sharingMode: VkSharingMode = .EXCLUSIVE,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
};

pub const VkSharingMode = enum(i32) {
    EXCLUSIVE = 0,
    CONCURRENT = 1,
    _,
};

pub const VkMemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memoryTypeBits: u32,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: VkStructureType = .MEMORY_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    allocationSize: u64,
    memoryTypeIndex: u32,
};

pub const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

pub const VkMemoryType = extern struct {
    propertyFlags: VkMemoryPropertyFlagBits,
    heapIndex: u32,
};

pub const VkMemoryHeap = extern struct {
    size: u64,
    flags: u32,
};

pub const VkShaderModuleCreateInfo = extern struct {
    sType: VkStructureType = .SHADER_MODULE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    codeSize: usize,
    pCode: [*]const u32,
};

pub const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: VkDescriptorType,
    descriptorCount: u32,
    stageFlags: u32,
    pImmutableSamplers: ?*const anyopaque = null,
};

pub const VkDescriptorType = enum(i32) {
    SAMPLER = 0,
    COMBINED_IMAGE_SAMPLER = 1,
    SAMPLED_IMAGE = 2,
    STORAGE_IMAGE = 3,
    UNIFORM_TEXEL_BUFFER = 4,
    STORAGE_TEXEL_BUFFER = 5,
    UNIFORM_BUFFER = 6,
    STORAGE_BUFFER = 7,
    _,
};

pub const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: VkStructureType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    bindingCount: u32,
    pBindings: [*]const VkDescriptorSetLayoutBinding,
};

pub const VkPipelineLayoutCreateInfo = extern struct {
    sType: VkStructureType = .PIPELINE_LAYOUT_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    setLayoutCount: u32,
    pSetLayouts: [*]const VkDescriptorSetLayout,
    pushConstantRangeCount: u32 = 0,
    pPushConstantRanges: ?*const anyopaque = null,
};

pub const VkComputePipelineCreateInfo = extern struct {
    sType: VkStructureType = .COMPUTE_PIPELINE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: VkPipelineShaderStageCreateInfo,
    layout: VkPipelineLayout,
    basePipelineHandle: ?VkPipeline = null,
    basePipelineIndex: i32 = -1,
};

pub const VkPipelineShaderStageCreateInfo = extern struct {
    sType: VkStructureType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: u32, // VK_SHADER_STAGE_COMPUTE_BIT = 0x00000020
    module: VkShaderModule,
    pName: [*:0]const u8,
    pSpecializationInfo: ?*const anyopaque = null,
};

pub const VkCommandPoolCreateInfo = extern struct {
    sType: VkStructureType = .COMMAND_POOL_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32,
};

pub const VkCommandBufferAllocateInfo = extern struct {
    sType: VkStructureType = .COMMAND_BUFFER_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    commandPool: VkCommandPool,
    level: VkCommandBufferLevel = .PRIMARY,
    commandBufferCount: u32,
};

pub const VkCommandBufferLevel = enum(i32) {
    PRIMARY = 0,
    SECONDARY = 1,
    _,
};

pub const VkCommandBufferBeginInfo = extern struct {
    sType: VkStructureType = .COMMAND_BUFFER_BEGIN_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pInheritanceInfo: ?*const anyopaque = null,
};

pub const VkSubmitInfo = extern struct {
    sType: VkStructureType = .SUBMIT_INFO,
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 0,
    pWaitSemaphores: ?*const anyopaque = null,
    pWaitDstStageMask: ?*const u32 = null,
    commandBufferCount: u32,
    pCommandBuffers: [*]const VkCommandBuffer,
    signalSemaphoreCount: u32 = 0,
    pSignalSemaphores: ?*const anyopaque = null,
};

// Vulkan API Version
pub const VK_API_VERSION_1_0: u32 = (1 << 22) | (0 << 12) | 0;
pub const VK_SHADER_STAGE_COMPUTE_BIT: u32 = 0x00000020;

// Vulkan functions
extern "c" fn vkCreateInstance(
    pCreateInfo: *const VkInstanceCreateInfo,
    pAllocator: ?*const anyopaque,
    pInstance: *VkInstance,
) VkResult;

extern "c" fn vkDestroyInstance(
    instance: VkInstance,
    pAllocator: ?*const anyopaque,
) void;

extern "c" fn vkEnumeratePhysicalDevices(
    instance: VkInstance,
    pPhysicalDeviceCount: *u32,
    pPhysicalDevices: ?[*]VkPhysicalDevice,
) VkResult;

extern "c" fn vkGetPhysicalDeviceProperties(
    physicalDevice: VkPhysicalDevice,
    pProperties: *VkPhysicalDeviceProperties,
) void;

extern "c" fn vkGetPhysicalDeviceQueueFamilyProperties(
    physicalDevice: VkPhysicalDevice,
    pQueueFamilyPropertyCount: *u32,
    pQueueFamilyProperties: ?[*]VkQueueFamilyProperties,
) void;

extern "c" fn vkGetPhysicalDeviceMemoryProperties(
    physicalDevice: VkPhysicalDevice,
    pMemoryProperties: *VkPhysicalDeviceMemoryProperties,
) void;

extern "c" fn vkCreateDevice(
    physicalDevice: VkPhysicalDevice,
    pCreateInfo: *const VkDeviceCreateInfo,
    pAllocator: ?*const anyopaque,
    pDevice: *VkDevice,
) VkResult;

extern "c" fn vkDestroyDevice(
    device: VkDevice,
    pAllocator: ?*const anyopaque,
) void;

extern "c" fn vkGetDeviceQueue(
    device: VkDevice,
    queueFamilyIndex: u32,
    queueIndex: u32,
    pQueue: *VkQueue,
) void;

extern "c" fn vkCreateBuffer(
    device: VkDevice,
    pCreateInfo: *const VkBufferCreateInfo,
    pAllocator: ?*const anyopaque,
    pBuffer: *VkBuffer,
) VkResult;

extern "c" fn vkDestroyBuffer(
    device: VkDevice,
    buffer: VkBuffer,
    pAllocator: ?*const anyopaque,
) void;

extern "c" fn vkGetBufferMemoryRequirements(
    device: VkDevice,
    buffer: VkBuffer,
    pMemoryRequirements: *VkMemoryRequirements,
) void;

extern "c" fn vkAllocateMemory(
    device: VkDevice,
    pAllocateInfo: *const VkMemoryAllocateInfo,
    pAllocator: ?*const anyopaque,
    pMemory: *VkDeviceMemory,
) VkResult;

extern "c" fn vkFreeMemory(
    device: VkDevice,
    memory: VkDeviceMemory,
    pAllocator: ?*const anyopaque,
) void;

extern "c" fn vkBindBufferMemory(
    device: VkDevice,
    buffer: VkBuffer,
    memory: VkDeviceMemory,
    memoryOffset: u64,
) VkResult;

extern "c" fn vkMapMemory(
    device: VkDevice,
    memory: VkDeviceMemory,
    offset: u64,
    size: u64,
    flags: u32,
    ppData: *?*anyopaque,
) VkResult;

extern "c" fn vkUnmapMemory(
    device: VkDevice,
    memory: VkDeviceMemory,
) void;

extern "c" fn vkCreateShaderModule(
    device: VkDevice,
    pCreateInfo: *const VkShaderModuleCreateInfo,
    pAllocator: ?*const anyopaque,
    pShaderModule: *VkShaderModule,
) VkResult;

extern "c" fn vkDestroyShaderModule(
    device: VkDevice,
    shaderModule: VkShaderModule,
    pAllocator: ?*const anyopaque,
) void;

extern "c" fn vkCreateDescriptorSetLayout(
    device: VkDevice,
    pCreateInfo: *const VkDescriptorSetLayoutCreateInfo,
    pAllocator: ?*const anyopaque,
    pSetLayout: *VkDescriptorSetLayout,
) VkResult;

extern "c" fn vkDestroyDescriptorSetLayout(
    device: VkDevice,
    descriptorSetLayout: VkDescriptorSetLayout,
    pAllocator: ?*const anyopaque,
) void;

extern "c" fn vkCreatePipelineLayout(
    device: VkDevice,
    pCreateInfo: *const VkPipelineLayoutCreateInfo,
    pAllocator: ?*const anyopaque,
    pPipelineLayout: *VkPipelineLayout,
) VkResult;

extern "c" fn vkDestroyPipelineLayout(
    device: VkDevice,
    pipelineLayout: VkPipelineLayout,
    pAllocator: ?*const anyopaque,
) void;

extern "c" fn vkCreateComputePipelines(
    device: VkDevice,
    pipelineCache: ?*anyopaque,
    createInfoCount: u32,
    pCreateInfos: [*]const VkComputePipelineCreateInfo,
    pAllocator: ?*const anyopaque,
    pPipelines: [*]VkPipeline,
) VkResult;

extern "c" fn vkDestroyPipeline(
    device: VkDevice,
    pipeline: VkPipeline,
    pAllocator: ?*const anyopaque,
) void;

extern "c" fn vkCreateCommandPool(
    device: VkDevice,
    pCreateInfo: *const VkCommandPoolCreateInfo,
    pAllocator: ?*const anyopaque,
    pCommandPool: *VkCommandPool,
) VkResult;

extern "c" fn vkDestroyCommandPool(
    device: VkDevice,
    commandPool: VkCommandPool,
    pAllocator: ?*const anyopaque,
) void;

extern "c" fn vkAllocateCommandBuffers(
    device: VkDevice,
    pAllocateInfo: *const VkCommandBufferAllocateInfo,
    pCommandBuffers: [*]VkCommandBuffer,
) VkResult;

extern "c" fn vkBeginCommandBuffer(
    commandBuffer: VkCommandBuffer,
    pBeginInfo: *const VkCommandBufferBeginInfo,
) VkResult;

extern "c" fn vkEndCommandBuffer(
    commandBuffer: VkCommandBuffer,
) VkResult;

extern "c" fn vkCmdBindPipeline(
    commandBuffer: VkCommandBuffer,
    pipelineBindPoint: u32, // VK_PIPELINE_BIND_POINT_COMPUTE = 1
    pipeline: VkPipeline,
) void;

extern "c" fn vkCmdDispatch(
    commandBuffer: VkCommandBuffer,
    groupCountX: u32,
    groupCountY: u32,
    groupCountZ: u32,
) void;

extern "c" fn vkQueueSubmit(
    queue: VkQueue,
    submitCount: u32,
    pSubmits: [*]const VkSubmitInfo,
    fence: ?*anyopaque,
) VkResult;

extern "c" fn vkQueueWaitIdle(
    queue: VkQueue,
) VkResult;

extern "c" fn vkDeviceWaitIdle(
    device: VkDevice,
) VkResult;

pub const VK_PIPELINE_BIND_POINT_COMPUTE: u32 = 1;

// ============================================================================
// Zig Wrapper
// ============================================================================

/// Vulkan Instance
pub const VulkanInstance = struct {
    instance: VkInstance,

    const Self = @This();

    pub fn init() !Self {
        const app_info = VkApplicationInfo{
            .pApplicationName = "Home Video Library",
            .applicationVersion = 1,
            .pEngineName = "Home",
            .engineVersion = 1,
            .apiVersion = VK_API_VERSION_1_0,
        };

        const create_info = VkInstanceCreateInfo{
            .pApplicationInfo = &app_info,
        };

        var instance: VkInstance = undefined;
        const result = vkCreateInstance(&create_info, null, &instance);

        if (result != .SUCCESS) {
            return error.FailedToCreateInstance;
        }

        return .{ .instance = instance };
    }

    pub fn deinit(self: *Self) void {
        vkDestroyInstance(self.instance, null);
    }
};

/// Vulkan Physical Device
pub const VulkanPhysicalDevice = struct {
    device: VkPhysicalDevice,
    properties: VkPhysicalDeviceProperties,
    memory_properties: VkPhysicalDeviceMemoryProperties,
    compute_queue_family: u32,

    const Self = @This();

    pub fn enumerate(instance: *VulkanInstance, allocator: std.mem.Allocator) ![]Self {
        var device_count: u32 = 0;
        var result = vkEnumeratePhysicalDevices(instance.instance, &device_count, null);
        if (result != .SUCCESS or device_count == 0) {
            return error.NoPhysicalDevices;
        }

        const devices = try allocator.alloc(VkPhysicalDevice, device_count);
        defer allocator.free(devices);

        result = vkEnumeratePhysicalDevices(instance.instance, &device_count, devices.ptr);
        if (result != .SUCCESS) {
            return error.FailedToEnumerateDevices;
        }

        var physical_devices = std.ArrayList(Self).init(allocator);
        errdefer physical_devices.deinit();

        for (devices) |device| {
            var properties: VkPhysicalDeviceProperties = undefined;
            vkGetPhysicalDeviceProperties(device, &properties);

            var memory_properties: VkPhysicalDeviceMemoryProperties = undefined;
            vkGetPhysicalDeviceMemoryProperties(device, &memory_properties);

            // Find compute queue family
            var queue_family_count: u32 = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

            const queue_families = try allocator.alloc(VkQueueFamilyProperties, queue_family_count);
            defer allocator.free(queue_families);

            vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

            var compute_queue_family: ?u32 = null;
            for (queue_families, 0..) |family, i| {
                if (family.queueFlags.compute) {
                    compute_queue_family = @intCast(i);
                    break;
                }
            }

            if (compute_queue_family) |qf| {
                try physical_devices.append(.{
                    .device = device,
                    .properties = properties,
                    .memory_properties = memory_properties,
                    .compute_queue_family = qf,
                });
            }
        }

        return physical_devices.toOwnedSlice();
    }

    pub fn getName(self: *const Self) []const u8 {
        const null_pos = std.mem.indexOfScalar(u8, &self.properties.deviceName, 0) orelse self.properties.deviceName.len;
        return self.properties.deviceName[0..null_pos];
    }
};

/// Vulkan Logical Device
pub const VulkanDevice = struct {
    device: VkDevice,
    queue: VkQueue,
    queue_family: u32,
    memory_properties: VkPhysicalDeviceMemoryProperties,

    const Self = @This();

    pub fn init(physical_device: *const VulkanPhysicalDevice) !Self {
        const queue_priority: f32 = 1.0;
        const queue_create_info = VkDeviceQueueCreateInfo{
            .queueFamilyIndex = physical_device.compute_queue_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        const device_create_info = VkDeviceCreateInfo{
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
        };

        var device: VkDevice = undefined;
        const result = vkCreateDevice(physical_device.device, &device_create_info, null, &device);
        if (result != .SUCCESS) {
            return error.FailedToCreateDevice;
        }

        var queue: VkQueue = undefined;
        vkGetDeviceQueue(device, physical_device.compute_queue_family, 0, &queue);

        return .{
            .device = device,
            .queue = queue,
            .queue_family = physical_device.compute_queue_family,
            .memory_properties = physical_device.memory_properties,
        };
    }

    pub fn deinit(self: *Self) void {
        vkDestroyDevice(self.device, null);
    }

    pub fn waitIdle(self: *Self) !void {
        const result = vkDeviceWaitIdle(self.device);
        if (result != .SUCCESS) {
            return error.WaitIdleFailed;
        }
    }
};

/// Vulkan Buffer
pub const VulkanBuffer = struct {
    buffer: VkBuffer,
    memory: VkDeviceMemory,
    size: usize,
    device: *VulkanDevice,

    const Self = @This();

    pub fn init(device: *VulkanDevice, size: usize, usage: VkBufferUsageFlagBits) !Self {
        const buffer_info = VkBufferCreateInfo{
            .size = size,
            .usage = usage,
        };

        var buffer: VkBuffer = undefined;
        var result = vkCreateBuffer(device.device, &buffer_info, null, &buffer);
        if (result != .SUCCESS) {
            return error.FailedToCreateBuffer;
        }
        errdefer vkDestroyBuffer(device.device, buffer, null);

        var mem_reqs: VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(device.device, buffer, &mem_reqs);

        // Find host-visible memory type
        var memory_type_index: ?u32 = null;
        for (0..device.memory_properties.memoryTypeCount) |i| {
            const mem_type = device.memory_properties.memoryTypes[i];
            if ((mem_reqs.memoryTypeBits & (@as(u32, 1) << @intCast(i))) != 0 and
                mem_type.propertyFlags.host_visible and
                mem_type.propertyFlags.host_coherent)
            {
                memory_type_index = @intCast(i);
                break;
            }
        }

        if (memory_type_index == null) {
            return error.NoSuitableMemoryType;
        }

        const alloc_info = VkMemoryAllocateInfo{
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = memory_type_index.?,
        };

        var memory: VkDeviceMemory = undefined;
        result = vkAllocateMemory(device.device, &alloc_info, null, &memory);
        if (result != .SUCCESS) {
            return error.FailedToAllocateMemory;
        }
        errdefer vkFreeMemory(device.device, memory, null);

        result = vkBindBufferMemory(device.device, buffer, memory, 0);
        if (result != .SUCCESS) {
            return error.FailedToBindMemory;
        }

        return .{
            .buffer = buffer,
            .memory = memory,
            .size = size,
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        vkDestroyBuffer(self.device.device, self.buffer, null);
        vkFreeMemory(self.device.device, self.memory, null);
    }

    pub fn upload(self: *Self, data: []const u8) !void {
        if (data.len > self.size) return error.BufferTooSmall;

        var mapped_ptr: ?*anyopaque = null;
        const result = vkMapMemory(self.device.device, self.memory, 0, self.size, 0, &mapped_ptr);
        if (result != .SUCCESS) {
            return error.FailedToMapMemory;
        }

        @memcpy(@as([*]u8, @ptrCast(mapped_ptr.?))[0..data.len], data);
        vkUnmapMemory(self.device.device, self.memory);
    }

    pub fn download(self: *Self, data: []u8) !void {
        if (data.len < self.size) return error.BufferTooSmall;

        var mapped_ptr: ?*anyopaque = null;
        const result = vkMapMemory(self.device.device, self.memory, 0, self.size, 0, &mapped_ptr);
        if (result != .SUCCESS) {
            return error.FailedToMapMemory;
        }

        @memcpy(data[0..self.size], @as([*]u8, @ptrCast(mapped_ptr.?))[0..self.size]);
        vkUnmapMemory(self.device.device, self.memory);
    }
};

/// Vulkan Compute Context (simplified - full implementation would include descriptor sets, etc.)
pub const VulkanComputeContext = struct {
    instance: VulkanInstance,
    physical_device: VulkanPhysicalDevice,
    device: VulkanDevice,
    command_pool: VkCommandPool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var instance = try VulkanInstance.init();
        errdefer instance.deinit();

        const physical_devices = try VulkanPhysicalDevice.enumerate(&instance, allocator);
        defer allocator.free(physical_devices);

        if (physical_devices.len == 0) {
            return error.NoSuitableDevices;
        }

        // Use first device (could be enhanced to select best device)
        const physical_device = physical_devices[0];

        var device = try VulkanDevice.init(&physical_device);
        errdefer device.deinit();

        // Create command pool
        const pool_info = VkCommandPoolCreateInfo{
            .queueFamilyIndex = device.queue_family,
        };

        var command_pool: VkCommandPool = undefined;
        const result = vkCreateCommandPool(device.device, &pool_info, null, &command_pool);
        if (result != .SUCCESS) {
            return error.FailedToCreateCommandPool;
        }

        return .{
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .command_pool = command_pool,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        vkDestroyCommandPool(self.device.device, self.command_pool, null);
        self.device.deinit();
        self.instance.deinit();
    }

    pub fn createBuffer(self: *Self, size: usize, usage: VkBufferUsageFlagBits) !VulkanBuffer {
        return VulkanBuffer.init(&self.device, size, usage);
    }
};
