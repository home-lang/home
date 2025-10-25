// Home Programming Language - Network Device Abstraction
// Generic network interface layer

const Basics = @import("basics");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");
const dma = @import("dma.zig");

// ============================================================================
// Network Device Types
// ============================================================================

pub const NetDeviceType = enum {
    Ethernet,
    Loopback,
    Wireless,
    Ppp,
    Tunnel,
};

pub const NetDeviceFlags = packed struct(u32) {
    up: bool = false,
    broadcast: bool = false,
    loopback: bool = false,
    point_to_point: bool = false,
    running: bool = false,
    multicast: bool = false,
    promisc: bool = false,
    _padding: u25 = 0,
};

// ============================================================================
// MAC Address
// ============================================================================

pub const MacAddress = struct {
    bytes: [6]u8,

    pub fn init(bytes: [6]u8) MacAddress {
        return .{ .bytes = bytes };
    }

    pub fn fromSlice(slice: []const u8) !MacAddress {
        if (slice.len != 6) return error.InvalidMacAddress;
        var mac: MacAddress = undefined;
        @memcpy(&mac.bytes, slice);
        return mac;
    }

    pub fn equals(self: MacAddress, other: MacAddress) bool {
        return Basics.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn isBroadcast(self: MacAddress) bool {
        return Basics.mem.eql(u8, &self.bytes, &[_]u8{0xFF} ** 6);
    }

    pub fn isMulticast(self: MacAddress) bool {
        return (self.bytes[0] & 0x01) != 0;
    }

    pub fn format(
        self: MacAddress,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}",
            .{ self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3], self.bytes[4], self.bytes[5] },
        );
    }
};

// ============================================================================
// Packet Buffer (sk_buff equivalent)
// ============================================================================

pub const PacketBuffer = struct {
    data: []u8,
    len: usize,
    head: usize,
    tail: usize,
    protocol: u16,
    dev: ?*NetDevice,
    next: ?*PacketBuffer,
    allocator: Basics.Allocator,

    pub fn alloc(allocator: Basics.Allocator, size: usize) !*PacketBuffer {
        const skb = try allocator.create(PacketBuffer);
        errdefer allocator.destroy(skb);

        const data = try allocator.alloc(u8, size);
        errdefer allocator.free(data);

        skb.* = .{
            .data = data,
            .len = 0,
            .head = 0,
            .tail = 0,
            .protocol = 0,
            .dev = null,
            .next = null,
            .allocator = allocator,
        };

        return skb;
    }

    pub fn free(self: *PacketBuffer) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    pub fn reserve(self: *PacketBuffer, amount: usize) !void {
        if (amount > self.data.len) return error.NoSpace;
        self.head = amount;
        self.tail = amount;
    }

    pub fn put(self: *PacketBuffer, amount: usize) ![]u8 {
        if (self.tail + amount > self.data.len) return error.NoSpace;
        const old_tail = self.tail;
        self.tail += amount;
        self.len += amount;
        return self.data[old_tail..self.tail];
    }

    pub fn push(self: *PacketBuffer, amount: usize) ![]u8 {
        if (self.head < amount) return error.NoSpace;
        self.head -= amount;
        self.len += amount;
        return self.data[self.head..][0..amount];
    }

    pub fn pull(self: *PacketBuffer, amount: usize) ![]u8 {
        if (self.len < amount) return error.NoData;
        const old_head = self.head;
        self.head += amount;
        self.len -= amount;
        return self.data[old_head..][0..amount];
    }

    pub fn getData(self: *const PacketBuffer) []u8 {
        return self.data[self.head..][0..self.len];
    }
};

// ============================================================================
// Network Device Operations
// ============================================================================

pub const NetDeviceOps = struct {
    open: *const fn (*NetDevice) anyerror!void,
    stop: *const fn (*NetDevice) anyerror!void,
    xmit: *const fn (*NetDevice, *PacketBuffer) anyerror!void,
    set_mac: ?*const fn (*NetDevice, MacAddress) anyerror!void,
    get_stats: ?*const fn (*NetDevice) NetDeviceStats,
};

// ============================================================================
// Network Device
// ============================================================================

pub const NetDevice = struct {
    name: [16]u8,
    name_len: usize,
    device_type: NetDeviceType,
    flags: NetDeviceFlags,
    mac_address: MacAddress,
    mtu: u32,
    ops: *const NetDeviceOps,
    rx_queue: PacketQueue,
    tx_queue: PacketQueue,
    driver_data: ?*anyopaque,
    lock: sync.Spinlock,
    refcount: atomic.AtomicU32,

    // Statistics
    rx_packets: atomic.AtomicU64,
    tx_packets: atomic.AtomicU64,
    rx_bytes: atomic.AtomicU64,
    tx_bytes: atomic.AtomicU64,
    rx_errors: atomic.AtomicU64,
    tx_errors: atomic.AtomicU64,
    rx_dropped: atomic.AtomicU64,
    tx_dropped: atomic.AtomicU64,

    pub fn init(
        name: []const u8,
        device_type: NetDeviceType,
        mac: MacAddress,
        mtu: u32,
        ops: *const NetDeviceOps,
    ) NetDevice {
        var dev_name: [16]u8 = undefined;
        const len = Basics.math.min(name.len, 15);
        @memcpy(dev_name[0..len], name[0..len]);

        return .{
            .name = dev_name,
            .name_len = len,
            .device_type = device_type,
            .flags = .{},
            .mac_address = mac,
            .mtu = mtu,
            .ops = ops,
            .rx_queue = PacketQueue.init(),
            .tx_queue = PacketQueue.init(),
            .driver_data = null,
            .lock = sync.Spinlock.init(),
            .refcount = atomic.AtomicU32.init(1),
            .rx_packets = atomic.AtomicU64.init(0),
            .tx_packets = atomic.AtomicU64.init(0),
            .rx_bytes = atomic.AtomicU64.init(0),
            .tx_bytes = atomic.AtomicU64.init(0),
            .rx_errors = atomic.AtomicU64.init(0),
            .tx_errors = atomic.AtomicU64.init(0),
            .rx_dropped = atomic.AtomicU64.init(0),
            .tx_dropped = atomic.AtomicU64.init(0),
        };
    }

    pub fn getName(self: *const NetDevice) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn open(self: *NetDevice) !void {
        try self.ops.open(self);
        self.flags.up = true;
        self.flags.running = true;
    }

    pub fn stop(self: *NetDevice) !void {
        try self.ops.stop(self);
        self.flags.up = false;
        self.flags.running = false;
    }

    pub fn transmit(self: *NetDevice, skb: *PacketBuffer) !void {
        if (!self.flags.up) return error.DeviceDown;
        if (!self.flags.running) return error.DeviceNotRunning;

        _ = self.tx_packets.fetchAdd(1, .Monotonic);
        _ = self.tx_bytes.fetchAdd(skb.len, .Monotonic);

        try self.ops.xmit(self, skb);
    }

    pub fn receive(self: *NetDevice, skb: *PacketBuffer) void {
        _ = self.rx_packets.fetchAdd(1, .Monotonic);
        _ = self.rx_bytes.fetchAdd(skb.len, .Monotonic);

        skb.dev = self;
        self.rx_queue.enqueue(skb);

        // TODO: Wake up network stack
    }

    pub fn getStats(self: *const NetDevice) NetDeviceStats {
        return .{
            .rx_packets = self.rx_packets.load(.Monotonic),
            .tx_packets = self.tx_packets.load(.Monotonic),
            .rx_bytes = self.rx_bytes.load(.Monotonic),
            .tx_bytes = self.tx_bytes.load(.Monotonic),
            .rx_errors = self.rx_errors.load(.Monotonic),
            .tx_errors = self.tx_errors.load(.Monotonic),
            .rx_dropped = self.rx_dropped.load(.Monotonic),
            .tx_dropped = self.tx_dropped.load(.Monotonic),
        };
    }

    pub fn format(
        self: NetDevice,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "NetDevice '{s}' {} MAC={} MTU={d}",
            .{ self.getName(), self.mac_address, self.mtu },
        );
    }
};

pub const NetDeviceStats = struct {
    rx_packets: u64,
    tx_packets: u64,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_errors: u64,
    tx_errors: u64,
    rx_dropped: u64,
    tx_dropped: u64,
};

// ============================================================================
// Packet Queue
// ============================================================================

pub const PacketQueue = struct {
    head: ?*PacketBuffer,
    tail: ?*PacketBuffer,
    count: atomic.AtomicUsize,
    lock: sync.Spinlock,

    pub fn init() PacketQueue {
        return .{
            .head = null,
            .tail = null,
            .count = atomic.AtomicUsize.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    pub fn enqueue(self: *PacketQueue, skb: *PacketBuffer) void {
        self.lock.acquire();
        defer self.lock.release();

        skb.next = null;

        if (self.tail) |tail| {
            tail.next = skb;
        } else {
            self.head = skb;
        }
        self.tail = skb;

        _ = self.count.fetchAdd(1, .Release);
    }

    pub fn dequeue(self: *PacketQueue) ?*PacketBuffer {
        self.lock.acquire();
        defer self.lock.release();

        const skb = self.head orelse return null;

        self.head = skb.next;
        if (self.head == null) {
            self.tail = null;
        }

        skb.next = null;

        _ = self.count.fetchSub(1, .Release);
        return skb;
    }

    pub fn len(self: *const PacketQueue) usize {
        return self.count.load(.Acquire);
    }
};

// ============================================================================
// Global Device Registry
// ============================================================================

const MAX_NET_DEVICES = 64;

var net_devices: [MAX_NET_DEVICES]?*NetDevice = [_]?*NetDevice{null} ** MAX_NET_DEVICES;
var device_count: atomic.AtomicUsize = atomic.AtomicUsize.init(0);
var registry_lock = sync.Spinlock.init();

pub fn registerDevice(device: *NetDevice) !u32 {
    registry_lock.acquire();
    defer registry_lock.release();

    const count = device_count.load(.Acquire);
    if (count >= MAX_NET_DEVICES) {
        return error.TooManyDevices;
    }

    for (net_devices, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = device;
            _ = device_count.fetchAdd(1, .Release);
            return @intCast(i);
        }
    }

    return error.NoSlotAvailable;
}

pub fn unregisterDevice(device_id: u32) void {
    registry_lock.acquire();
    defer registry_lock.release();

    if (device_id >= MAX_NET_DEVICES) return;

    if (net_devices[device_id]) |_| {
        net_devices[device_id] = null;
        _ = device_count.fetchSub(1, .Release);
    }
}

pub fn getDevice(device_id: u32) ?*NetDevice {
    if (device_id >= MAX_NET_DEVICES) return null;
    return net_devices[device_id];
}

pub fn getDeviceCount() usize {
    return device_count.load(.Acquire);
}

// ============================================================================
// Tests
// ============================================================================

test "MAC address" {
    const mac = MacAddress.init([_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 });

    try Basics.testing.expect(!mac.isBroadcast());
    try Basics.testing.expect(!mac.isMulticast());

    const broadcast = MacAddress.init([_]u8{0xFF} ** 6);
    try Basics.testing.expect(broadcast.isBroadcast());
}

test "packet buffer" {
    const allocator = Basics.testing.allocator;

    var skb = try PacketBuffer.alloc(allocator, 1500);
    defer skb.free();

    try skb.reserve(100);
    try Basics.testing.expectEqual(@as(usize, 0), skb.len);

    const data = try skb.put(50);
    try Basics.testing.expectEqual(@as(usize, 50), data.len);
    try Basics.testing.expectEqual(@as(usize, 50), skb.len);
}
