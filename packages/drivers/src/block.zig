// Home Programming Language - Block Device Layer
// Generic block device abstraction for storage devices

const std = @import("std");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");
const dma = @import("dma.zig");

// ============================================================================
// Block Device Types
// ============================================================================

pub const BlockDeviceType = enum {
    Unknown,
    HardDisk,
    SolidState,
    Optical,
    Floppy,
    RamDisk,
    Virtual,
};

pub const BlockDeviceFlags = packed struct(u32) {
    removable: bool = false,
    read_only: bool = false,
    rotational: bool = false,
    supports_trim: bool = false,
    supports_flush: bool = true,
    _padding: u27 = 0,
};

// ============================================================================
// Block Request
// ============================================================================

pub const BlockRequestType = enum(u8) {
    Read,
    Write,
    Flush,
    Trim,
};

pub const BlockRequest = struct {
    request_type: BlockRequestType,
    sector: u64,
    count: u32,
    buffer: []u8,
    callback: ?*const fn (*BlockRequest, err: ?anyerror) void,
    user_data: ?*anyopaque,
    next: ?*BlockRequest,
    prev: ?*BlockRequest,

    pub fn init(
        request_type: BlockRequestType,
        sector: u64,
        count: u32,
        buffer: []u8,
    ) BlockRequest {
        return .{
            .request_type = request_type,
            .sector = sector,
            .count = count,
            .buffer = buffer,
            .callback = null,
            .user_data = null,
            .next = null,
            .prev = null,
        };
    }

    pub fn complete(self: *BlockRequest, err: ?anyerror) void {
        if (self.callback) |cb| {
            cb(self, err);
        }
    }
};

// ============================================================================
// Request Queue
// ============================================================================

pub const RequestQueue = struct {
    head: ?*BlockRequest,
    tail: ?*BlockRequest,
    count: atomic.AtomicUsize,
    lock: sync.Spinlock,

    pub fn init() RequestQueue {
        return .{
            .head = null,
            .tail = null,
            .count = atomic.AtomicUsize.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    pub fn enqueue(self: *RequestQueue, request: *BlockRequest) void {
        self.lock.acquire();
        defer self.lock.release();

        request.next = null;
        request.prev = self.tail;

        if (self.tail) |tail| {
            tail.next = request;
        } else {
            self.head = request;
        }
        self.tail = request;

        _ = self.count.fetchAdd(1, .release);
    }

    pub fn dequeue(self: *RequestQueue) ?*BlockRequest {
        self.lock.acquire();
        defer self.lock.release();

        const request = self.head orelse return null;

        self.head = request.next;
        if (self.head == null) {
            self.tail = null;
        } else if (self.head) |head| {
            head.prev = null;
        }

        request.next = null;
        request.prev = null;

        _ = self.count.fetchSub(1, .release);
        return request;
    }

    pub fn peek(self: *const RequestQueue) ?*BlockRequest {
        return self.head;
    }

    pub fn isEmpty(self: *const RequestQueue) bool {
        return self.head == null;
    }

    pub fn len(self: *const RequestQueue) usize {
        return self.count.load(.acquire);
    }
};

// ============================================================================
// Block Device Operations
// ============================================================================

pub const BlockDeviceOps = struct {
    read: *const fn (*BlockDevice, u64, u32, []u8) anyerror!void,
    write: *const fn (*BlockDevice, u64, u32, []const u8) anyerror!void,
    flush: *const fn (*BlockDevice) anyerror!void,
    trim: ?*const fn (*BlockDevice, u64, u32) anyerror!void,
    ioctl: ?*const fn (*BlockDevice, u32, ?*anyopaque) anyerror!usize,
};

// ============================================================================
// Block Device
// ============================================================================

pub const BlockDevice = struct {
    name: [32]u8,
    name_len: usize,
    device_type: BlockDeviceType,
    flags: BlockDeviceFlags,
    sector_size: u32,
    total_sectors: u64,
    ops: BlockDeviceOps,
    request_queue: RequestQueue,
    driver_data: ?*anyopaque,
    lock: sync.Spinlock,
    refcount: atomic.AtomicU32,

    // Statistics
    read_requests: atomic.AtomicU64,
    write_requests: atomic.AtomicU64,
    read_sectors: atomic.AtomicU64,
    write_sectors: atomic.AtomicU64,
    errors: atomic.AtomicU64,

    pub fn init(
        name: []const u8,
        device_type: BlockDeviceType,
        sector_size: u32,
        total_sectors: u64,
        ops: BlockDeviceOps,
    ) BlockDevice {
        var device_name: [32]u8 = undefined;
        const len = std.math.min(name.len, 31);
        @memcpy(device_name[0..len], name[0..len]);

        return .{
            .name = device_name,
            .name_len = len,
            .device_type = device_type,
            .flags = .{},
            .sector_size = sector_size,
            .total_sectors = total_sectors,
            .ops = ops,
            .request_queue = RequestQueue.init(),
            .driver_data = null,
            .lock = sync.Spinlock.init(),
            .refcount = atomic.AtomicU32.init(1),
            .read_requests = atomic.AtomicU64.init(0),
            .write_requests = atomic.AtomicU64.init(0),
            .read_sectors = atomic.AtomicU64.init(0),
            .write_sectors = atomic.AtomicU64.init(0),
            .errors = atomic.AtomicU64.init(0),
        };
    }

    pub fn getName(self: *const BlockDevice) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getCapacity(self: *const BlockDevice) u64 {
        return self.total_sectors * self.sector_size;
    }

    /// Read sectors from device
    pub fn read(self: *BlockDevice, sector: u64, count: u32, buffer: []u8) !void {
        if (sector + count > self.total_sectors) {
            return error.OutOfBounds;
        }

        if (buffer.len < count * self.sector_size) {
            return error.BufferTooSmall;
        }

        _ = self.read_requests.fetchAdd(1, .monotonic);
        _ = self.read_sectors.fetchAdd(count, .monotonic);

        try self.ops.read(self, sector, count, buffer);
    }

    /// Write sectors to device
    pub fn write(self: *BlockDevice, sector: u64, count: u32, buffer: []const u8) !void {
        if (self.flags.read_only) {
            return error.ReadOnly;
        }

        if (sector + count > self.total_sectors) {
            return error.OutOfBounds;
        }

        if (buffer.len < count * self.sector_size) {
            return error.BufferTooSmall;
        }

        _ = self.write_requests.fetchAdd(1, .monotonic);
        _ = self.write_sectors.fetchAdd(count, .monotonic);

        try self.ops.write(self, sector, count, buffer);
    }

    /// Flush write cache
    pub fn flush(self: *BlockDevice) !void {
        if (!self.flags.supports_flush) {
            return;
        }

        try self.ops.flush(self);
    }

    /// Trim/discard sectors (for SSDs)
    pub fn trim(self: *BlockDevice, sector: u64, count: u32) !void {
        if (!self.flags.supports_trim) {
            return error.NotSupported;
        }

        if (self.ops.trim) |trim_fn| {
            try trim_fn(self, sector, count);
        }
    }

    /// Submit asynchronous request
    pub fn submitRequest(self: *BlockDevice, request: *BlockRequest) void {
        self.request_queue.enqueue(request);
    }

    /// Get next pending request
    pub fn getNextRequest(self: *BlockDevice) ?*BlockRequest {
        return self.request_queue.dequeue();
    }

    /// Increment reference count
    pub fn acquire(self: *BlockDevice) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    /// Decrement reference count
    pub fn release(self: *BlockDevice) void {
        const old = self.refcount.fetchSub(1, .release);
        if (old == 1) {
            // Last reference - perform device cleanup
            if (self.ops.cleanup) |cleanup_fn| {
                cleanup_fn(self);
            }
            // Clear device state
            self.flags.valid = false;
            self.flags.removable = false;
        }
    }

    /// Get device statistics
    pub fn getStats(self: *const BlockDevice) DeviceStats {
        return .{
            .read_requests = self.read_requests.load(.monotonic),
            .write_requests = self.write_requests.load(.monotonic),
            .read_sectors = self.read_sectors.load(.monotonic),
            .write_sectors = self.write_sectors.load(.monotonic),
            .errors = self.errors.load(.monotonic),
        };
    }

    pub fn format(
        self: *const BlockDevice,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "BlockDevice '{s}' {s} {d} sectors × {d} bytes = {d} MB",
            .{
                self.getName(),
                @tagName(self.device_type),
                self.total_sectors,
                self.sector_size,
                self.getCapacity() / (1024 * 1024),
            },
        );
    }
};

pub const DeviceStats = struct {
    read_requests: u64,
    write_requests: u64,
    read_sectors: u64,
    write_sectors: u64,
    errors: u64,

    pub fn totalRequests(self: DeviceStats) u64 {
        return self.read_requests + self.write_requests;
    }

    pub fn totalSectors(self: DeviceStats) u64 {
        return self.read_sectors + self.write_sectors;
    }
};

// ============================================================================
// Partition Support
// ============================================================================

pub const PartitionType = enum(u8) {
    Empty = 0x00,
    Fat12 = 0x01,
    Fat16 = 0x04,
    Extended = 0x05,
    Fat16B = 0x06,
    Ntfs = 0x07,
    Fat32 = 0x0B,
    Fat32Lba = 0x0C,
    ExtendedLba = 0x0F,
    LinuxSwap = 0x82,
    Linux = 0x83,
    LinuxExtended = 0x85,
    LinuxLvm = 0x8E,
    _,
};

pub const Partition = struct {
    parent: *BlockDevice,
    partition_type: PartitionType,
    start_sector: u64,
    sector_count: u64,
    partition_number: u8,

    pub fn init(
        parent: *BlockDevice,
        partition_type: PartitionType,
        start_sector: u64,
        sector_count: u64,
        partition_number: u8,
    ) Partition {
        return .{
            .parent = parent,
            .partition_type = partition_type,
            .start_sector = start_sector,
            .sector_count = sector_count,
            .partition_number = partition_number,
        };
    }

    pub fn read(self: *Partition, sector: u64, count: u32, buffer: []u8) !void {
        if (sector + count > self.sector_count) {
            return error.OutOfBounds;
        }

        const absolute_sector = self.start_sector + sector;
        try self.parent.read(absolute_sector, count, buffer);
    }

    pub fn write(self: *Partition, sector: u64, count: u32, buffer: []const u8) !void {
        if (sector + count > self.sector_count) {
            return error.OutOfBounds;
        }

        const absolute_sector = self.start_sector + sector;
        try self.parent.write(absolute_sector, count, buffer);
    }
};

// ============================================================================
// Global Block Device Registry
// ============================================================================

const MAX_BLOCK_DEVICES = 256;

var block_devices: [MAX_BLOCK_DEVICES]?*BlockDevice = [_]?*BlockDevice{null} ** MAX_BLOCK_DEVICES;
var device_count: atomic.AtomicUsize = atomic.AtomicUsize.init(0);
var registry_lock = sync.Spinlock.init();

/// Register a block device
pub fn registerDevice(device: *BlockDevice) !u32 {
    registry_lock.acquire();
    defer registry_lock.release();

    const count = device_count.load(.acquire);
    if (count >= MAX_BLOCK_DEVICES) {
        return error.TooManyDevices;
    }

    for (block_devices, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = device;
            device.acquire();
            _ = device_count.fetchAdd(1, .release);
            return @intCast(i);
        }
    }

    return error.NoSlotAvailable;
}

/// Unregister a block device
pub fn unregisterDevice(device_id: u32) void {
    registry_lock.acquire();
    defer registry_lock.release();

    if (device_id >= MAX_BLOCK_DEVICES) return;

    if (block_devices[device_id]) |device| {
        device.release();
        block_devices[device_id] = null;
        _ = device_count.fetchSub(1, .release);
    }
}

/// Get block device by ID
pub fn getDevice(device_id: u32) ?*BlockDevice {
    if (device_id >= MAX_BLOCK_DEVICES) return null;
    return block_devices[device_id];
}

/// Get device count
pub fn getDeviceCount() usize {
    return device_count.load(.acquire);
}

// ============================================================================
// Tests
// ============================================================================

test "block request" {
    var buffer: [512]u8 = undefined;
    const req = BlockRequest.init(.Read, 0, 1, &buffer);

    try std.testing.expectEqual(BlockRequestType.Read, req.request_type);
    try std.testing.expectEqual(@as(u64, 0), req.sector);
    try std.testing.expectEqual(@as(u32, 1), req.count);
}

test "request queue" {
    const allocator = std.testing.allocator;

    var buffer1: [512]u8 = undefined;
    var buffer2: [512]u8 = undefined;

    var req1 = BlockRequest.init(.Read, 0, 1, &buffer1);
    var req2 = BlockRequest.init(.Write, 1, 1, &buffer2);

    var queue = RequestQueue.init();
    try std.testing.expect(queue.isEmpty());

    queue.enqueue(&req1);
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    queue.enqueue(&req2);
    try std.testing.expectEqual(@as(usize, 2), queue.len());

    const first = queue.dequeue().?;
    try std.testing.expectEqual(&req1, first);

    const second = queue.dequeue().?;
    try std.testing.expectEqual(&req2, second);

    try std.testing.expect(queue.isEmpty());

    _ = allocator;
}
