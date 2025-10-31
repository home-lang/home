// VirtIO Network Driver
// Virtual network device for QEMU/KVM and other virtualization platforms

const std = @import("std");

/// VirtIO Net Feature Bits
pub const Feature = struct {
    pub const CSUM: u64 = 1 << 0; // Checksum offload
    pub const GUEST_CSUM: u64 = 1 << 1; // Guest handles checksums
    pub const CTRL_GUEST_OFFLOADS: u64 = 1 << 2;
    pub const MTU: u64 = 1 << 3; // MTU configuration
    pub const MAC: u64 = 1 << 5; // MAC address configuration
    pub const GUEST_TSO4: u64 = 1 << 7; // Guest can receive TSOv4
    pub const GUEST_TSO6: u64 = 1 << 8; // Guest can receive TSOv6
    pub const GUEST_ECN: u64 = 1 << 9; // Guest can receive ECN
    pub const GUEST_UFO: u64 = 1 << 10; // Guest can receive UFO
    pub const HOST_TSO4: u64 = 1 << 11; // Host can receive TSOv4
    pub const HOST_TSO6: u64 = 1 << 12; // Host can receive TSOv6
    pub const HOST_ECN: u64 = 1 << 13; // Host can receive ECN
    pub const HOST_UFO: u64 = 1 << 14; // Host can receive UFO
    pub const MRG_RXBUF: u64 = 1 << 15; // Merge receive buffers
    pub const STATUS: u64 = 1 << 16; // Configuration status available
    pub const CTRL_VQ: u64 = 1 << 17; // Control channel available
    pub const CTRL_RX: u64 = 1 << 18; // Control channel RX mode
    pub const CTRL_VLAN: u64 = 1 << 19; // Control channel VLAN filtering
    pub const GUEST_ANNOUNCE: u64 = 1 << 21; // Guest can send gratuitous ARP
    pub const MQ: u64 = 1 << 22; // Multiple queue pairs
    pub const CTRL_MAC_ADDR: u64 = 1 << 23; // MAC address control
};

/// VirtIO Net Configuration
pub const Config = extern struct {
    mac: [6]u8,
    status: u16,
    max_virtqueue_pairs: u16,
    mtu: u16,

    pub fn getMacAddress(self: *const Config) [6]u8 {
        return self.mac;
    }

    pub fn isLinkUp(self: *const Config) bool {
        return (self.status & 1) != 0;
    }
};

/// VirtIO Net Header
pub const Header = extern struct {
    flags: u8,
    gso_type: u8,
    hdr_len: u16,
    gso_size: u16,
    csum_start: u16,
    csum_offset: u16,
    num_buffers: u16, // Only if MRG_RXBUF

    pub const GSO_NONE: u8 = 0;
    pub const GSO_TCPV4: u8 = 1;
    pub const GSO_UDP: u8 = 3;
    pub const GSO_TCPV6: u8 = 4;
    pub const GSO_ECN: u8 = 0x80;

    pub fn init() Header {
        return .{
            .flags = 0,
            .gso_type = GSO_NONE,
            .hdr_len = 0,
            .gso_size = 0,
            .csum_start = 0,
            .csum_offset = 0,
            .num_buffers = 0,
        };
    }
};

/// VirtIO Net Control Commands
pub const CtrlCommand = struct {
    pub const RX = struct {
        pub const PROMISC: u8 = 0;
        pub const ALLMULTI: u8 = 1;
        pub const ALLUNI: u8 = 2;
        pub const NOMULTI: u8 = 3;
        pub const NOUNI: u8 = 4;
        pub const NOBCAST: u8 = 5;
    };

    pub const MAC = struct {
        pub const TABLE_SET: u8 = 0;
        pub const ADDR_SET: u8 = 1;
    };

    pub const VLAN = struct {
        pub const ADD: u8 = 0;
        pub const DEL: u8 = 1;
    };

    pub const ANNOUNCE = struct {
        pub const ACK: u8 = 0;
    };

    pub const MQ = struct {
        pub const VQ_PAIRS_SET: u8 = 0;
        pub const VQ_PAIRS_MIN: u16 = 1;
        pub const VQ_PAIRS_MAX: u16 = 0x8000;
    };
};

/// VirtQueue descriptor for virtio-net
pub const Descriptor = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,

    pub const FLAG_NEXT: u16 = 1;
    pub const FLAG_WRITE: u16 = 2;
    pub const FLAG_INDIRECT: u16 = 4;
};

/// VirtQueue available ring
pub const Available = extern struct {
    flags: u16,
    idx: u16,
    // ring follows (u16 array)
    // used_event follows ring

    pub const FLAG_NO_INTERRUPT: u16 = 1;
};

/// VirtQueue used ring element
pub const UsedElement = extern struct {
    id: u32,
    len: u32,
};

/// VirtQueue used ring
pub const Used = extern struct {
    flags: u16,
    idx: u16,
    // ring follows (UsedElement array)
    // avail_event follows ring

    pub const FLAG_NO_NOTIFY: u16 = 1;
};

/// VirtIO Net Queue
pub const Queue = struct {
    descriptors: []Descriptor,
    available: *Available,
    used: *Used,
    queue_size: u16,
    last_used_idx: u16,
    free_head: u16,
    num_free: u16,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, queue_size: u16) !Queue {
        const desc_size = @sizeOf(Descriptor) * queue_size;
        const avail_size = @sizeOf(Available) + (@sizeOf(u16) * queue_size) + @sizeOf(u16);
        const used_size = @sizeOf(Used) + (@sizeOf(UsedElement) * queue_size) + @sizeOf(u16);

        // Allocate aligned memory for queue
        const total_size = desc_size + avail_size + used_size;
        const memory = try allocator.alignedAlloc(u8, 4096, total_size);

        const descriptors = @as([*]Descriptor, @ptrCast(@alignCast(memory.ptr)))[0..queue_size];
        const available = @as(*Available, @ptrCast(@alignCast(&memory[desc_size])));
        const used = @as(*Used, @ptrCast(@alignCast(&memory[desc_size + avail_size])));

        // Initialize descriptor chain
        for (0..queue_size) |i| {
            descriptors[i].next = @intCast((i + 1) % queue_size);
        }

        return Queue{
            .descriptors = descriptors,
            .available = available,
            .used = used,
            .queue_size = queue_size,
            .last_used_idx = 0,
            .free_head = 0,
            .num_free = queue_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Queue) void {
        const desc_ptr: [*]u8 = @ptrCast(self.descriptors.ptr);
        self.allocator.free(desc_ptr[0 .. @sizeOf(Descriptor) * self.queue_size]);
    }

    pub fn addBuffer(self: *Queue, addr: u64, len: u32, writable: bool) !u16 {
        if (self.num_free == 0) {
            return error.QueueFull;
        }

        const desc_idx = self.free_head;
        const desc = &self.descriptors[desc_idx];

        desc.addr = addr;
        desc.len = len;
        desc.flags = if (writable) Descriptor.FLAG_WRITE else 0;

        self.free_head = desc.next;
        self.num_free -= 1;

        return desc_idx;
    }

    pub fn addBufferChain(self: *Queue, buffers: []const Buffer) !u16 {
        if (self.num_free < buffers.len) {
            return error.QueueFull;
        }

        const head = self.free_head;
        var prev_idx: u16 = undefined;

        for (buffers, 0..) |buf, i| {
            const desc_idx = self.free_head;
            const desc = &self.descriptors[desc_idx];

            desc.addr = buf.addr;
            desc.len = buf.len;
            desc.flags = if (buf.writable) Descriptor.FLAG_WRITE else 0;

            if (i > 0) {
                self.descriptors[prev_idx].flags |= Descriptor.FLAG_NEXT;
            }

            prev_idx = desc_idx;
            self.free_head = desc.next;
            self.num_free -= 1;
        }

        return head;
    }

    pub fn submit(self: *Queue, desc_idx: u16) void {
        const avail_idx = self.available.idx;
        const ring = @as([*]u16, @ptrFromInt(@intFromPtr(self.available) + @sizeOf(Available)));
        ring[avail_idx % self.queue_size] = desc_idx;

        // Memory barrier (compiler fence to prevent reordering)
        std.atomic.compilerFence(.seq_cst);

        self.available.idx +%= 1;
    }

    pub const Buffer = struct {
        addr: u64,
        len: u32,
        writable: bool,
    };
};

/// VirtIO Net Device
pub const Device = struct {
    config: *volatile Config,
    rx_queue: Queue,
    tx_queue: Queue,
    ctrl_queue: ?Queue,
    features: u64,
    mac_address: [6]u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        config_base: usize,
        features: u64,
    ) !Device {
        const config = @as(*volatile Config, @ptrFromInt(config_base));

        const rx_queue = try Queue.init(allocator, 256);
        const tx_queue = try Queue.init(allocator, 256);
        const ctrl_queue = if ((features & Feature.CTRL_VQ) != 0)
            try Queue.init(allocator, 64)
        else
            null;

        return Device{
            .config = config,
            .rx_queue = rx_queue,
            .tx_queue = tx_queue,
            .ctrl_queue = ctrl_queue,
            .features = features,
            .mac_address = config.mac,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Device) void {
        self.rx_queue.deinit();
        self.tx_queue.deinit();
        if (self.ctrl_queue) |*q| {
            q.deinit();
        }
    }

    /// Send a packet
    pub fn sendPacket(self: *Device, data: []const u8) !void {
        // Allocate buffer for header + data
        const buffer = try self.allocator.alloc(u8, @sizeOf(Header) + data.len);
        defer self.allocator.free(buffer);

        // Write header
        const header = Header.init();
        @memcpy(buffer[0..@sizeOf(Header)], std.mem.asBytes(&header));

        // Write data
        @memcpy(buffer[@sizeOf(Header)..], data);

        // Add to TX queue
        const buffers = [_]Queue.Buffer{
            .{
                .addr = @intFromPtr(buffer.ptr),
                .len = @intCast(buffer.len),
                .writable = false,
            },
        };

        const desc_idx = try self.tx_queue.addBufferChain(&buffers);
        self.tx_queue.submit(desc_idx);

        // Notify device (implementation specific)
        self.notifyTx();
    }

    /// Receive a packet
    pub fn receivePacket(self: *Device, buffer: []u8) !usize {
        // Check if there are any used buffers
        const used_idx = self.rx_queue.used.idx;
        if (self.rx_queue.last_used_idx == used_idx) {
            return error.NoPackets;
        }

        const ring = @as([*]UsedElement, @ptrFromInt(@intFromPtr(self.rx_queue.used) + @sizeOf(Used)));
        const elem = ring[self.rx_queue.last_used_idx % self.rx_queue.queue_size];

        self.rx_queue.last_used_idx +%= 1;

        // Validate length
        if (elem.len < @sizeOf(Header)) {
            return error.PacketTooSmall;
        }

        const packet_len = elem.len - @sizeOf(Header);
        if (packet_len > buffer.len) {
            return error.BufferTooSmall;
        }

        // Copy packet data (skipping header)
        const desc = &self.rx_queue.descriptors[elem.id];
        const packet_data = @as([*]const u8, @ptrFromInt(desc.addr))[@sizeOf(Header)..elem.len];
        @memcpy(buffer[0..packet_len], packet_data);

        return packet_len;
    }

    /// Set MAC address
    pub fn setMacAddress(self: *Device, mac: [6]u8) !void {
        if ((self.features & Feature.CTRL_MAC_ADDR) == 0) {
            return error.NotSupported;
        }

        self.mac_address = mac;
        @memcpy(&self.config.mac, &mac);
    }

    /// Enable promiscuous mode
    pub fn setPromiscuous(self: *Device, enabled: bool) !void {
        if ((self.features & Feature.CTRL_RX) == 0) {
            return error.NotSupported;
        }

        // Send control command (implementation specific)
        _ = enabled;
    }

    /// Get link status
    pub fn isLinkUp(self: *Device) bool {
        if ((self.features & Feature.STATUS) == 0) {
            return true; // Assume up if status not available
        }

        return self.config.isLinkUp();
    }

    /// Get MTU
    pub fn getMtu(self: *Device) u16 {
        if ((self.features & Feature.MTU) != 0) {
            return self.config.mtu;
        }
        return 1500; // Default Ethernet MTU
    }

    /// Notify device about TX
    fn notifyTx(self: *Device) void {
        _ = self;
        // Write to notify register (implementation specific)
        // This would typically write to a PCI register
    }

    /// Notify device about RX
    fn notifyRx(self: *Device) void {
        _ = self;
        // Write to notify register (implementation specific)
    }
};

/// Statistics
pub const Statistics = struct {
    tx_packets: u64,
    tx_bytes: u64,
    tx_errors: u64,
    rx_packets: u64,
    rx_bytes: u64,
    rx_errors: u64,
    rx_dropped: u64,

    pub fn init() Statistics {
        return .{
            .tx_packets = 0,
            .tx_bytes = 0,
            .tx_errors = 0,
            .rx_packets = 0,
            .rx_bytes = 0,
            .rx_errors = 0,
            .rx_dropped = 0,
        };
    }
};

test "virtio-net header" {
    const testing = std.testing;

    const header = Header.init();
    try testing.expectEqual(@as(u8, Header.GSO_NONE), header.gso_type);
    try testing.expectEqual(@as(u8, 0), header.flags);
}

test "virtio-net config" {
    const testing = std.testing;

    var config = Config{
        .mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 },
        .status = 1,
        .max_virtqueue_pairs = 1,
        .mtu = 1500,
    };

    try testing.expect(config.isLinkUp());

    const mac = config.getMacAddress();
    try testing.expectEqual(@as(u8, 0x52), mac[0]);
    try testing.expectEqual(@as(u8, 0x54), mac[1]);
}
