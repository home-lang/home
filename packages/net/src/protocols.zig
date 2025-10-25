// Home Programming Language - Network Protocols
// Ethernet, ARP, IPv4, ICMP implementations

const Basics = @import("basics");
const netdev = @import("netdev.zig");
const sync = @import("sync.zig");

// ============================================================================
// Ethernet Protocol
// ============================================================================

pub const EtherType = enum(u16) {
    IPv4 = 0x0800,
    ARP = 0x0806,
    IPv6 = 0x86DD,
    _,
};

pub const EthernetHeader = extern struct {
    dest_mac: [6]u8,
    src_mac: [6]u8,
    ether_type: u16,

    pub fn init(dest: netdev.MacAddress, src: netdev.MacAddress, ether_type: EtherType) EthernetHeader {
        return .{
            .dest_mac = dest.bytes,
            .src_mac = src.bytes,
            .ether_type = @byteSwap(@intFromEnum(ether_type)),
        };
    }

    pub fn getEtherType(self: *const EthernetHeader) EtherType {
        return @enumFromInt(@byteSwap(self.ether_type));
    }
};

pub fn sendEthernet(dev: *netdev.NetDevice, dest: netdev.MacAddress, ether_type: EtherType, payload: []const u8) !void {
    const skb = try netdev.PacketBuffer.alloc(dev.allocator, @sizeOf(EthernetHeader) + payload.len);
    errdefer skb.free();

    // Add Ethernet header
    const eth_data = try skb.put(@sizeOf(EthernetHeader));
    const eth_header: *EthernetHeader = @ptrCast(@alignCast(eth_data.ptr));
    eth_header.* = EthernetHeader.init(dest, dev.mac_address, ether_type);

    // Add payload
    const payload_data = try skb.put(payload.len);
    @memcpy(payload_data, payload);

    try dev.transmit(skb);
}

pub fn receiveEthernet(skb: *netdev.PacketBuffer) !void {
    const eth_data = try skb.pull(@sizeOf(EthernetHeader));
    const eth_header: *const EthernetHeader = @ptrCast(@alignCast(eth_data.ptr));

    switch (eth_header.getEtherType()) {
        .IPv4 => try receiveIPv4(skb),
        .ARP => try receiveARP(skb),
        else => {},
    }
}

// ============================================================================
// ARP Cache with Timeout
// ============================================================================

const atomic = Basics.atomic;

pub const ArpCacheEntry = struct {
    ip: IPv4Address,
    mac: netdev.MacAddress,
    timestamp: u64, // Monotonic time in milliseconds
    state: EntryState,
    retries: u8,

    const EntryState = enum {
        Incomplete, // Waiting for ARP reply
        Reachable,  // Valid entry
        Stale,      // Entry timeout, needs refresh
    };

    const TIMEOUT_MS: u64 = 300000; // 5 minutes
    const STALE_MS: u64 = 60000;    // 1 minute before marking stale
    const MAX_RETRIES: u8 = 3;

    pub fn init(ip: IPv4Address) ArpCacheEntry {
        return .{
            .ip = ip,
            .mac = netdev.MacAddress.init([_]u8{0} ** 6),
            .timestamp = getMonotonicTime(),
            .state = .Incomplete,
            .retries = 0,
        };
    }

    pub fn isValid(self: *const ArpCacheEntry) bool {
        const now = getMonotonicTime();
        return self.state == .Reachable and (now - self.timestamp) < TIMEOUT_MS;
    }

    pub fn isStale(self: *const ArpCacheEntry) bool {
        const now = getMonotonicTime();
        return (now - self.timestamp) > STALE_MS;
    }

    pub fn needsRetry(self: *const ArpCacheEntry) bool {
        return self.state == .Incomplete and self.retries < MAX_RETRIES;
    }

    pub fn update(self: *ArpCacheEntry, mac: netdev.MacAddress) void {
        self.mac = mac;
        self.timestamp = getMonotonicTime();
        self.state = .Reachable;
        self.retries = 0;
    }

    pub fn markStale(self: *ArpCacheEntry) void {
        self.state = .Stale;
    }
};

pub const ArpCache = struct {
    entries: Basics.HashMap(u32, ArpCacheEntry, Basics.hash_map.AutoContext(u32), 80),
    lock: sync.RwLock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) !ArpCache {
        return .{
            .entries = Basics.HashMap(u32, ArpCacheEntry, Basics.hash_map.AutoContext(u32), 80).init(allocator),
            .lock = sync.RwLock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArpCache) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();
        self.entries.deinit();
    }

    /// Lookup MAC address for IP (returns null if not found or expired)
    pub fn lookup(self: *ArpCache, ip: IPv4Address) ?netdev.MacAddress {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        const key = ip.toU32();
        if (self.entries.get(key)) |entry| {
            if (entry.isValid()) {
                return entry.mac;
            }
        }
        return null;
    }

    /// Add or update entry
    pub fn update(self: *ArpCache, ip: IPv4Address, mac: netdev.MacAddress) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const key = ip.toU32();
        if (self.entries.getPtr(key)) |entry| {
            entry.update(mac);
        } else {
            var new_entry = ArpCacheEntry.init(ip);
            new_entry.update(mac);
            try self.entries.put(key, new_entry);
        }
    }

    /// Mark entry as incomplete (waiting for ARP reply)
    pub fn markIncomplete(self: *ArpCache, ip: IPv4Address) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const key = ip.toU32();
        if (self.entries.getPtr(key)) |entry| {
            if (entry.state == .Incomplete) {
                entry.retries += 1;
            }
        } else {
            const entry = ArpCacheEntry.init(ip);
            try self.entries.put(key, entry);
        }
    }

    /// Check if entry needs retry
    pub fn needsRetry(self: *ArpCache, ip: IPv4Address) bool {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        const key = ip.toU32();
        if (self.entries.get(key)) |entry| {
            return entry.needsRetry();
        }
        return false;
    }

    /// Remove expired entries
    pub fn evictExpired(self: *ArpCache) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var to_remove = Basics.ArrayList(u32).init(self.allocator);
        defer to_remove.deinit();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.*.isValid()) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            _ = self.entries.remove(key);
        }
    }
};

/// Global ARP cache (per network device in real implementation)
var global_arp_cache: ?*ArpCache = null;
var arp_cache_init_lock: sync.Spinlock = sync.Spinlock.init();

pub fn getArpCache(allocator: Basics.Allocator) !*ArpCache {
    if (global_arp_cache) |cache| {
        return cache;
    }

    arp_cache_init_lock.acquire();
    defer arp_cache_init_lock.release();

    if (global_arp_cache == null) {
        const cache = try allocator.create(ArpCache);
        cache.* = try ArpCache.init(allocator);
        global_arp_cache = cache;
    }

    return global_arp_cache.?;
}

fn getMonotonicTime() u64 {
    // TODO: Get actual monotonic time from timer
    return 0;
}

// ============================================================================
// ARP Protocol
// ============================================================================

pub const ArpOpcode = enum(u16) {
    Request = 1,
    Reply = 2,
    _,
};

pub const ArpHeader = extern struct {
    hardware_type: u16,
    protocol_type: u16,
    hardware_addr_len: u8,
    protocol_addr_len: u8,
    opcode: u16,
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    target_mac: [6]u8,
    target_ip: [4]u8,

    pub fn init(opcode: ArpOpcode, sender_mac: netdev.MacAddress, sender_ip: IPv4Address, target_ip: IPv4Address) ArpHeader {
        return .{
            .hardware_type = @byteSwap(@as(u16, 1)), // Ethernet
            .protocol_type = @byteSwap(@as(u16, 0x0800)), // IPv4
            .hardware_addr_len = 6,
            .protocol_addr_len = 4,
            .opcode = @byteSwap(@intFromEnum(opcode)),
            .sender_mac = sender_mac.bytes,
            .sender_ip = sender_ip.bytes,
            .target_mac = [_]u8{0} ** 6,
            .target_ip = target_ip.bytes,
        };
    }

    pub fn getOpcode(self: *const ArpHeader) ArpOpcode {
        return @enumFromInt(@byteSwap(self.opcode));
    }
};

pub fn sendArpRequest(dev: *netdev.NetDevice, target_ip: IPv4Address, allocator: Basics.Allocator) !void {
    // Mark as incomplete in cache (will increment retry count)
    const cache = try getArpCache(allocator);
    try cache.markIncomplete(target_ip);

    const arp = ArpHeader.init(.Request, dev.mac_address, getDeviceIP(dev), target_ip);

    var buffer: [@sizeOf(ArpHeader)]u8 = undefined;
    @memcpy(&buffer, Basics.mem.asBytes(&arp));

    const broadcast = netdev.MacAddress.init([_]u8{0xFF} ** 6);
    try sendEthernet(dev, broadcast, .ARP, &buffer);
}

pub fn receiveARP(skb: *netdev.PacketBuffer) !void {
    const arp_data = skb.getData();
    if (arp_data.len < @sizeOf(ArpHeader)) return error.InvalidARP;

    const arp: *const ArpHeader = @ptrCast(@alignCast(arp_data.ptr));
    const sender_ip = IPv4Address{ .bytes = arp.sender_ip };
    const sender_mac = netdev.MacAddress{ .bytes = arp.sender_mac };

    // Update ARP cache with sender info (for both request and reply)
    const cache = try getArpCache(skb.allocator);
    try cache.update(sender_ip, sender_mac);

    if (arp.getOpcode() == .Request) {
        const target_ip = IPv4Address{ .bytes = arp.target_ip };
        const our_ip = getDeviceIP(skb.dev);

        // Check if target_ip matches our IP
        if (target_ip.equals(our_ip)) {
            // Send ARP reply
            const reply = ArpHeader.init(.Reply, skb.dev.mac_address, our_ip, sender_ip);
            var buffer: [@sizeOf(ArpHeader)]u8 = undefined;
            @memcpy(&buffer, Basics.mem.asBytes(&reply));
            try sendEthernet(skb.dev, sender_mac, .ARP, &buffer);
        }
    } else if (arp.getOpcode() == .Reply) {
        // Cache already updated above
    }
}

// ============================================================================
// IPv4 Protocol
// ============================================================================

pub const IPv4Address = struct {
    bytes: [4]u8,

    pub fn init(a: u8, b: u8, c: u8, d: u8) IPv4Address {
        return .{ .bytes = [_]u8{ a, b, c, d } };
    }

    pub fn fromU32(addr: u32) IPv4Address {
        return .{ .bytes = @bitCast(@byteSwap(addr)) };
    }

    pub fn toU32(self: IPv4Address) u32 {
        return @byteSwap(@as(u32, @bitCast(self.bytes)));
    }

    pub fn equals(self: IPv4Address, other: IPv4Address) bool {
        return Basics.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn format(
        self: IPv4Address,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d}.{d}.{d}.{d}", .{ self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3] });
    }
};

pub const IpProtocol = enum(u8) {
    ICMP = 1,
    TCP = 6,
    UDP = 17,
    _,
};

// ============================================================================
// Internet Checksum (RFC 1071)
// ============================================================================

/// Calculate Internet checksum (used for IP, ICMP, TCP, UDP)
pub fn internetChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    // Sum 16-bit words
    while (i + 1 < data.len) : (i += 2) {
        const word = @as(u16, data[i]) << 8 | @as(u16, data[i + 1]);
        sum +%= word;
    }

    // Add remaining byte if odd length
    if (i < data.len) {
        sum +%= @as(u16, data[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) +% (sum >> 16);
    }

    // Return one's complement
    return @truncate(~sum);
}

/// Calculate pseudo-header checksum for TCP/UDP
pub fn pseudoHeaderChecksum(src_ip: IPv4Address, dest_ip: IPv4Address, protocol: IpProtocol, length: u16) u32 {
    var sum: u32 = 0;

    // Source IP
    sum +%= @as(u16, src_ip.bytes[0]) << 8 | @as(u16, src_ip.bytes[1]);
    sum +%= @as(u16, src_ip.bytes[2]) << 8 | @as(u16, src_ip.bytes[3]);

    // Dest IP
    sum +%= @as(u16, dest_ip.bytes[0]) << 8 | @as(u16, dest_ip.bytes[1]);
    sum +%= @as(u16, dest_ip.bytes[2]) << 8 | @as(u16, dest_ip.bytes[3]);

    // Protocol
    sum +%= @intFromEnum(protocol);

    // Length
    sum +%= length;

    return sum;
}

pub const IPv4Header = extern struct {
    version_ihl: u8,
    tos: u8,
    total_length: u16,
    identification: u16,
    flags_fragment: u16,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    src_ip: [4]u8,
    dest_ip: [4]u8,

    pub fn init(src: IPv4Address, dest: IPv4Address, protocol: IpProtocol, payload_len: u16) IPv4Header {
        return .{
            .version_ihl = 0x45, // IPv4, 20-byte header
            .tos = 0,
            .total_length = @byteSwap(20 + payload_len),
            .identification = 0,
            .flags_fragment = 0,
            .ttl = 64,
            .protocol = @intFromEnum(protocol),
            .checksum = 0,
            .src_ip = src.bytes,
            .dest_ip = dest.bytes,
        };
    }

    pub fn getProtocol(self: *const IPv4Header) IpProtocol {
        return @enumFromInt(self.protocol);
    }

    /// Calculate IP header checksum
    pub fn calculateChecksum(self: *const IPv4Header) u16 {
        const header_bytes = Basics.mem.asBytes(self);
        return internetChecksum(header_bytes);
    }

    /// Verify IP header checksum
    pub fn verifyChecksum(self: *const IPv4Header) bool {
        const header_bytes = Basics.mem.asBytes(self);
        const checksum = internetChecksum(header_bytes);
        return checksum == 0; // Should be 0 when checksum field is included
    }

    /// Set checksum field (call after header initialization)
    pub fn setChecksum(self: *IPv4Header) void {
        self.checksum = 0;
        self.checksum = self.calculateChecksum();
    }
};

pub fn sendIPv4(dev: *netdev.NetDevice, dest_ip: IPv4Address, protocol: IpProtocol, payload: []const u8) !void {
    const src_ip = getDeviceIP(dev);

    var ip_header = IPv4Header.init(src_ip, dest_ip, protocol, @intCast(payload.len));
    ip_header.checksum = calculateChecksum(Basics.mem.asBytes(&ip_header));

    var buffer: [@sizeOf(IPv4Header) + 1500]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(IPv4Header)], Basics.mem.asBytes(&ip_header));
    @memcpy(buffer[@sizeOf(IPv4Header)..][0..payload.len], payload);

    // TODO: ARP lookup for dest_mac
    const dest_mac = netdev.MacAddress.init([_]u8{0xFF} ** 6);

    try sendEthernet(dev, dest_mac, .IPv4, buffer[0 .. @sizeOf(IPv4Header) + payload.len]);
}

pub fn receiveIPv4(skb: *netdev.PacketBuffer) !void {
    const ip_data = skb.getData();
    if (ip_data.len < @sizeOf(IPv4Header)) return error.InvalidIPv4;

    const ip_header: *const IPv4Header = @ptrCast(@alignCast(ip_data.ptr));

    switch (ip_header.getProtocol()) {
        .ICMP => try receiveICMP(skb),
        .TCP => try receiveTCP(skb),
        .UDP => try receiveUDP(skb),
        else => {},
    }
}

// ============================================================================
// ICMP Protocol (Ping)
// ============================================================================

pub const IcmpType = enum(u8) {
    EchoReply = 0,
    EchoRequest = 8,
    _,
};

pub const IcmpHeader = extern struct {
    icmp_type: u8,
    code: u8,
    checksum: u16,
    identifier: u16,
    sequence: u16,

    pub fn init(icmp_type: IcmpType, identifier: u16, sequence: u16) IcmpHeader {
        return .{
            .icmp_type = @intFromEnum(icmp_type),
            .code = 0,
            .checksum = 0,
            .identifier = @byteSwap(identifier),
            .sequence = @byteSwap(sequence),
        };
    }

    pub fn getType(self: *const IcmpHeader) IcmpType {
        return @enumFromInt(self.icmp_type);
    }
};

pub fn sendPing(dev: *netdev.NetDevice, dest_ip: IPv4Address, identifier: u16, sequence: u16) !void {
    var icmp = IcmpHeader.init(.EchoRequest, identifier, sequence);

    const payload = "abcdefghijklmnopqrstuvwxyz012345";
    var buffer: [@sizeOf(IcmpHeader) + payload.len]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(IcmpHeader)], Basics.mem.asBytes(&icmp));
    @memcpy(buffer[@sizeOf(IcmpHeader)..], payload);

    const icmp_ptr: *IcmpHeader = @ptrCast(@alignCast(&buffer));
    icmp_ptr.checksum = calculateChecksum(&buffer);

    try sendIPv4(dev, dest_ip, .ICMP, &buffer);
}

pub fn receiveICMP(skb: *netdev.PacketBuffer) !void {
    _ = try skb.pull(@sizeOf(IPv4Header));

    const icmp_data = skb.getData();
    if (icmp_data.len < @sizeOf(IcmpHeader)) return error.InvalidICMP;

    const icmp: *const IcmpHeader = @ptrCast(@alignCast(icmp_data.ptr));

    if (icmp.getType() == .EchoRequest) {
        // TODO: Send echo reply
    }
}

// ============================================================================
// UDP Protocol
// ============================================================================

pub const UdpHeader = extern struct {
    src_port: u16,
    dest_port: u16,
    length: u16,
    checksum: u16,

    pub fn init(src_port: u16, dest_port: u16, payload_len: u16) UdpHeader {
        return .{
            .src_port = @byteSwap(src_port),
            .dest_port = @byteSwap(dest_port),
            .length = @byteSwap(@sizeOf(UdpHeader) + payload_len),
            .checksum = 0, // Optional for IPv4
        };
    }

    pub fn getSrcPort(self: *const UdpHeader) u16 {
        return @byteSwap(self.src_port);
    }

    pub fn getDestPort(self: *const UdpHeader) u16 {
        return @byteSwap(self.dest_port);
    }

    pub fn getLength(self: *const UdpHeader) u16 {
        return @byteSwap(self.length);
    }

    /// Calculate UDP checksum with pseudo-header
    pub fn calculateChecksum(self: *const UdpHeader, src_ip: IPv4Address, dest_ip: IPv4Address, payload: []const u8) u16 {
        var sum = pseudoHeaderChecksum(src_ip, dest_ip, .UDP, self.getLength());

        // Add UDP header
        const header_bytes = Basics.mem.asBytes(self);
        var i: usize = 0;
        while (i + 1 < header_bytes.len) : (i += 2) {
            if (i == 6) { // Skip checksum field
                i += 2;
                continue;
            }
            const word = @as(u16, header_bytes[i]) << 8 | @as(u16, header_bytes[i + 1]);
            sum +%= word;
        }

        // Add payload
        i = 0;
        while (i + 1 < payload.len) : (i += 2) {
            const word = @as(u16, payload[i]) << 8 | @as(u16, payload[i + 1]);
            sum +%= word;
        }
        if (i < payload.len) {
            sum +%= @as(u16, payload[i]) << 8;
        }

        // Fold and complement
        while (sum >> 16 != 0) {
            sum = (sum & 0xFFFF) +% (sum >> 16);
        }
        return @truncate(~sum);
    }

    /// Verify UDP checksum (checksum of 0 means no checksum for IPv4)
    pub fn verifyChecksum(self: *const UdpHeader, src_ip: IPv4Address, dest_ip: IPv4Address, payload: []const u8) bool {
        if (self.checksum == 0) return true; // No checksum
        const calculated = self.calculateChecksum(src_ip, dest_ip, payload);
        return calculated == 0 or calculated == self.checksum;
    }

    /// Set checksum field
    pub fn setChecksum(self: *UdpHeader, src_ip: IPv4Address, dest_ip: IPv4Address, payload: []const u8) void {
        self.checksum = 0;
        self.checksum = self.calculateChecksum(src_ip, dest_ip, payload);
    }
};

pub const UdpSocket = struct {
    port: u16,
    bound: bool,
    receive_queue: Basics.ArrayList(UdpPacket),
    allocator: Basics.Allocator,
    mutex: sync.Mutex,

    pub fn init(allocator: Basics.Allocator) UdpSocket {
        return .{
            .port = 0,
            .bound = false,
            .receive_queue = Basics.ArrayList(UdpPacket).init(allocator),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }

    pub fn bind(self: *UdpSocket, port: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.bound) return error.AlreadyBound;
        self.port = port;
        self.bound = true;

        // TODO: Register socket with UDP layer
    }

    pub fn sendTo(self: *UdpSocket, dev: *netdev.NetDevice, dest_ip: IPv4Address, dest_port: u16, data: []const u8) !void {
        _ = self;
        try sendUDP(dev, dest_port, dest_port, dest_ip, data);
    }

    pub fn receive(self: *UdpSocket, buffer: []u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.receive_queue.items.len == 0) return error.WouldBlock;

        const packet = self.receive_queue.orderedRemove(0);
        defer packet.deinit();

        const copy_len = @min(buffer.len, packet.data.len);
        @memcpy(buffer[0..copy_len], packet.data[0..copy_len]);
        return copy_len;
    }
};

pub const UdpPacket = struct {
    src_ip: IPv4Address,
    src_port: u16,
    dest_port: u16,
    data: []u8,
    allocator: Basics.Allocator,

    pub fn deinit(self: UdpPacket) void {
        self.allocator.free(self.data);
    }
};

var udp_sockets: ?Basics.ArrayList(*UdpSocket) = null;
var udp_mutex: sync.Mutex = sync.Mutex.init();

pub fn sendUDP(dev: *netdev.NetDevice, src_port: u16, dest_port: u16, dest_ip: IPv4Address, payload: []const u8) !void {
    var udp_header = UdpHeader.init(src_port, dest_port, @intCast(payload.len));

    var buffer: [@sizeOf(UdpHeader) + 1472]u8 = undefined; // Max UDP payload
    @memcpy(buffer[0..@sizeOf(UdpHeader)], Basics.mem.asBytes(&udp_header));
    @memcpy(buffer[@sizeOf(UdpHeader)..][0..payload.len], payload);

    try sendIPv4(dev, dest_ip, .UDP, buffer[0 .. @sizeOf(UdpHeader) + payload.len]);
}

pub fn receiveUDP(skb: *netdev.PacketBuffer) !void {
    _ = try skb.pull(@sizeOf(IPv4Header));

    const udp_data = skb.getData();
    if (udp_data.len < @sizeOf(UdpHeader)) return error.InvalidUDP;

    const udp_header: *const UdpHeader = @ptrCast(@alignCast(udp_data.ptr));
    const payload_offset = @sizeOf(UdpHeader);
    const payload_len = udp_header.getLength() - @sizeOf(UdpHeader);

    if (udp_data.len < payload_offset + payload_len) return error.TruncatedUDP;

    const dest_port = udp_header.getDestPort();

    // Find socket bound to this port
    udp_mutex.lock();
    defer udp_mutex.unlock();

    if (udp_sockets) |sockets| {
        for (sockets.items) |sock| {
            if (sock.bound and sock.port == dest_port) {
                // Queue packet for socket
                const payload_data = try sock.allocator.alloc(u8, payload_len);
                @memcpy(payload_data, udp_data[payload_offset..][0..payload_len]);

                // Get source IP from IPv4 header (we need to go back)
                const ip_start = skb.data.ptr - @sizeOf(IPv4Header);
                const ip_header: *const IPv4Header = @ptrCast(@alignCast(ip_start));
                const src_ip = IPv4Address{ .bytes = ip_header.src_ip };

                const packet = UdpPacket{
                    .src_ip = src_ip,
                    .src_port = udp_header.getSrcPort(),
                    .dest_port = dest_port,
                    .data = payload_data,
                    .allocator = sock.allocator,
                };

                try sock.receive_queue.append(packet);
                break;
            }
        }
    }
}

// ============================================================================
// TCP Protocol
// ============================================================================

pub const TcpFlags = packed struct(u8) {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    urg: bool = false,
    ece: bool = false,
    cwr: bool = false,
};

pub const TcpHeader = extern struct {
    src_port: u16,
    dest_port: u16,
    seq_num: u32,
    ack_num: u32,
    data_offset_flags: u16, // 4 bits offset, 4 bits reserved, 8 bits flags
    window_size: u16,
    checksum: u16,
    urgent_pointer: u16,

    pub fn init(src_port: u16, dest_port: u16, seq: u32, ack: u32, flags: TcpFlags) TcpHeader {
        const flags_byte: u8 = @bitCast(flags);
        return .{
            .src_port = @byteSwap(src_port),
            .dest_port = @byteSwap(dest_port),
            .seq_num = @byteSwap(seq),
            .ack_num = @byteSwap(ack),
            .data_offset_flags = @byteSwap((@as(u16, 5) << 12) | @as(u16, flags_byte)), // 5 = 20 bytes
            .window_size = @byteSwap(@as(u16, 65535)),
            .checksum = 0,
            .urgent_pointer = 0,
        };
    }

    pub fn getSrcPort(self: *const TcpHeader) u16 {
        return @byteSwap(self.src_port);
    }

    pub fn getDestPort(self: *const TcpHeader) u16 {
        return @byteSwap(self.dest_port);
    }

    pub fn getSeqNum(self: *const TcpHeader) u32 {
        return @byteSwap(self.seq_num);
    }

    pub fn getAckNum(self: *const TcpHeader) u32 {
        return @byteSwap(self.ack_num);
    }

    pub fn getFlags(self: *const TcpHeader) TcpFlags {
        const flags_word = @byteSwap(self.data_offset_flags);
        const flags_byte: u8 = @truncate(flags_word);
        return @bitCast(flags_byte);
    }

    pub fn getDataOffset(self: *const TcpHeader) u8 {
        const flags_word = @byteSwap(self.data_offset_flags);
        return @truncate(flags_word >> 12);
    }

    pub fn getWindowSize(self: *const TcpHeader) u16 {
        return @byteSwap(self.window_size);
    }

    /// Calculate TCP checksum with pseudo-header
    pub fn calculateChecksum(self: *const TcpHeader, src_ip: IPv4Address, dest_ip: IPv4Address, payload: []const u8) u16 {
        const tcp_len: u16 = @sizeOf(TcpHeader) + @as(u16, @intCast(payload.len));
        var sum = pseudoHeaderChecksum(src_ip, dest_ip, .TCP, tcp_len);

        // Add TCP header
        const header_bytes = Basics.mem.asBytes(self);
        var i: usize = 0;
        while (i + 1 < header_bytes.len) : (i += 2) {
            if (i == 16) { // Skip checksum field (offset 16 in TCP header)
                continue;
            }
            const word = @as(u16, header_bytes[i]) << 8 | @as(u16, header_bytes[i + 1]);
            sum +%= word;
        }

        // Add payload
        i = 0;
        while (i + 1 < payload.len) : (i += 2) {
            const word = @as(u16, payload[i]) << 8 | @as(u16, payload[i + 1]);
            sum +%= word;
        }
        if (i < payload.len) {
            sum +%= @as(u16, payload[i]) << 8;
        }

        // Fold and complement
        while (sum >> 16 != 0) {
            sum = (sum & 0xFFFF) +% (sum >> 16);
        }
        return @truncate(~sum);
    }

    /// Verify TCP checksum
    pub fn verifyChecksum(self: *const TcpHeader, src_ip: IPv4Address, dest_ip: IPv4Address, payload: []const u8) bool {
        const calculated = self.calculateChecksum(src_ip, dest_ip, payload);
        return calculated == 0;
    }

    /// Set checksum field
    pub fn setChecksum(self: *TcpHeader, src_ip: IPv4Address, dest_ip: IPv4Address, payload: []const u8) void {
        self.checksum = 0;
        self.checksum = self.calculateChecksum(src_ip, dest_ip, payload);
    }
};

pub const TcpState = enum {
    Closed,
    Listen,
    SynSent,
    SynReceived,
    Established,
    FinWait1,
    FinWait2,
    CloseWait,
    Closing,
    LastAck,
    TimeWait,
};

pub const TcpSocket = struct {
    local_port: u16,
    remote_ip: IPv4Address,
    remote_port: u16,
    state: TcpState,
    seq_num: u32,
    ack_num: u32,
    send_buffer: Basics.ArrayList(u8),
    recv_buffer: Basics.ArrayList(u8),
    allocator: Basics.Allocator,
    mutex: sync.Mutex,

    pub fn init(allocator: Basics.Allocator) TcpSocket {
        return .{
            .local_port = 0,
            .remote_ip = IPv4Address.init(0, 0, 0, 0),
            .remote_port = 0,
            .state = .Closed,
            .seq_num = 0,
            .ack_num = 0,
            .send_buffer = Basics.ArrayList(u8).init(allocator),
            .recv_buffer = Basics.ArrayList(u8).init(allocator),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }

    pub fn deinit(self: *TcpSocket) void {
        self.send_buffer.deinit();
        self.recv_buffer.deinit();
    }

    pub fn connect(self: *TcpSocket, dev: *netdev.NetDevice, remote_ip: IPv4Address, remote_port: u16, local_port: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .Closed) return error.InvalidState;

        self.remote_ip = remote_ip;
        self.remote_port = remote_port;
        self.local_port = local_port;
        self.seq_num = @truncate(@as(u64, @intCast(Basics.time.nanoTimestamp())) & 0xFFFFFFFF);
        self.state = .SynSent;

        // Send SYN
        var flags = TcpFlags{};
        flags.syn = true;
        try sendTCP(dev, local_port, remote_port, remote_ip, self.seq_num, 0, flags, &[_]u8{});
    }

    pub fn listen(self: *TcpSocket, port: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .Closed) return error.InvalidState;

        self.local_port = port;
        self.state = .Listen;

        // TODO: Register listening socket
    }

    pub fn send(self: *TcpSocket, dev: *netdev.NetDevice, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .Established) return error.NotConnected;

        // Send data with PSH+ACK
        var flags = TcpFlags{};
        flags.psh = true;
        flags.ack = true;

        try sendTCP(dev, self.local_port, self.remote_port, self.remote_ip, self.seq_num, self.ack_num, flags, data);
        self.seq_num += @intCast(data.len);
    }

    pub fn receive(self: *TcpSocket, buffer: []u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.recv_buffer.items.len == 0) return error.WouldBlock;

        const copy_len = @min(buffer.len, self.recv_buffer.items.len);
        @memcpy(buffer[0..copy_len], self.recv_buffer.items[0..copy_len]);

        // Remove received data from buffer
        const remaining = self.recv_buffer.items.len - copy_len;
        if (remaining > 0) {
            Basics.mem.copyForwards(u8, self.recv_buffer.items[0..remaining], self.recv_buffer.items[copy_len..]);
        }
        try self.recv_buffer.resize(remaining);

        return copy_len;
    }

    pub fn close(self: *TcpSocket, dev: *netdev.NetDevice) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state == .Established) {
            self.state = .FinWait1;

            // Send FIN
            var flags = TcpFlags{};
            flags.fin = true;
            flags.ack = true;
            try sendTCP(dev, self.local_port, self.remote_port, self.remote_ip, self.seq_num, self.ack_num, flags, &[_]u8{});
            self.seq_num += 1;
        } else {
            self.state = .Closed;
        }
    }
};

var tcp_sockets: ?Basics.ArrayList(*TcpSocket) = null;
var tcp_mutex: sync.Mutex = sync.Mutex.init();

pub fn sendTCP(dev: *netdev.NetDevice, src_port: u16, dest_port: u16, dest_ip: IPv4Address, seq: u32, ack: u32, flags: TcpFlags, payload: []const u8) !void {
    var tcp_header = TcpHeader.init(src_port, dest_port, seq, ack, flags);

    var buffer: [@sizeOf(TcpHeader) + 1460]u8 = undefined; // Max TCP payload (MSS)
    @memcpy(buffer[0..@sizeOf(TcpHeader)], Basics.mem.asBytes(&tcp_header));
    @memcpy(buffer[@sizeOf(TcpHeader)..][0..payload.len], payload);

    // Calculate TCP checksum (includes pseudo-header)
    const src_ip = getDeviceIP(dev);
    const checksum = calculateTcpChecksum(src_ip, dest_ip, &tcp_header, payload);
    const tcp_ptr: *TcpHeader = @ptrCast(@alignCast(&buffer));
    tcp_ptr.checksum = checksum;

    try sendIPv4(dev, dest_ip, .TCP, buffer[0 .. @sizeOf(TcpHeader) + payload.len]);
}

pub fn receiveTCP(skb: *netdev.PacketBuffer) !void {
    _ = try skb.pull(@sizeOf(IPv4Header));

    const tcp_data = skb.getData();
    if (tcp_data.len < @sizeOf(TcpHeader)) return error.InvalidTCP;

    const tcp_header: *const TcpHeader = @ptrCast(@alignCast(tcp_data.ptr));
    const header_len = tcp_header.getDataOffset() * 4;
    const payload_len = tcp_data.len - header_len;

    const dest_port = tcp_header.getDestPort();
    const flags = tcp_header.getFlags();

    // Find matching socket
    tcp_mutex.lock();
    defer tcp_mutex.unlock();

    if (tcp_sockets) |sockets| {
        for (sockets.items) |sock| {
            sock.mutex.lock();
            defer sock.mutex.unlock();

            if (sock.local_port == dest_port) {
                // State machine processing
                switch (sock.state) {
                    .Listen => {
                        if (flags.syn) {
                            // SYN received, send SYN-ACK
                            sock.ack_num = tcp_header.getSeqNum() + 1;
                            sock.state = .SynReceived;
                        }
                    },
                    .SynSent => {
                        if (flags.syn and flags.ack) {
                            // SYN-ACK received, send ACK
                            sock.ack_num = tcp_header.getSeqNum() + 1;
                            sock.state = .Established;
                        }
                    },
                    .Established => {
                        if (flags.fin) {
                            // FIN received
                            sock.ack_num = tcp_header.getSeqNum() + 1;
                            sock.state = .CloseWait;
                        } else if (payload_len > 0) {
                            // Data received
                            try sock.recv_buffer.appendSlice(tcp_data[header_len..][0..payload_len]);
                            sock.ack_num = tcp_header.getSeqNum() + @as(u32, @intCast(payload_len));
                        }
                    },
                    .FinWait1 => {
                        if (flags.fin and flags.ack) {
                            sock.ack_num = tcp_header.getSeqNum() + 1;
                            sock.state = .TimeWait;
                        } else if (flags.ack) {
                            sock.state = .FinWait2;
                        }
                    },
                    .FinWait2 => {
                        if (flags.fin) {
                            sock.ack_num = tcp_header.getSeqNum() + 1;
                            sock.state = .TimeWait;
                        }
                    },
                    else => {},
                }
                break;
            }
        }
    }
}

fn calculateTcpChecksum(src_ip: IPv4Address, dest_ip: IPv4Address, tcp_header: *const TcpHeader, payload: []const u8) u16 {
    var sum: u32 = 0;

    // Pseudo-header
    sum += (@as(u32, src_ip.bytes[0]) << 8) | src_ip.bytes[1];
    sum += (@as(u32, src_ip.bytes[2]) << 8) | src_ip.bytes[3];
    sum += (@as(u32, dest_ip.bytes[0]) << 8) | dest_ip.bytes[1];
    sum += (@as(u32, dest_ip.bytes[2]) << 8) | dest_ip.bytes[3];
    sum += @intFromEnum(IpProtocol.TCP);
    sum += @sizeOf(TcpHeader) + payload.len;

    // TCP header
    const header_bytes = Basics.mem.asBytes(tcp_header);
    var i: usize = 0;
    while (i + 1 < header_bytes.len) : (i += 2) {
        if (i == 16) { // Skip checksum field
            i += 2;
            continue;
        }
        const word = (@as(u16, header_bytes[i]) << 8) | header_bytes[i + 1];
        sum += word;
    }

    // Payload
    i = 0;
    while (i + 1 < payload.len) : (i += 2) {
        const word = (@as(u16, payload[i]) << 8) | payload[i + 1];
        sum += word;
    }
    if (i < payload.len) {
        sum += @as(u16, payload[i]) << 8;
    }

    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @truncate(~sum);
}

// ============================================================================
// Checksum Calculation
// ============================================================================

fn calculateChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        const word = (@as(u16, data[i]) << 8) | data[i + 1];
        sum += word;
    }

    if (i < data.len) {
        sum += @as(u16, data[i]) << 8;
    }

    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @truncate(~sum);
}

// ============================================================================
// Helper Functions
// ============================================================================

fn getDeviceIP(dev: *netdev.NetDevice) IPv4Address {
    _ = dev;
    // TODO: Get from device configuration
    return IPv4Address.init(192, 168, 1, 100);
}

// ============================================================================
// Tests
// ============================================================================

test "IPv4 address" {
    const addr = IPv4Address.init(192, 168, 1, 1);
    try Basics.testing.expectEqual(@as(u8, 192), addr.bytes[0]);
    try Basics.testing.expectEqual(@as(u8, 168), addr.bytes[1]);
    try Basics.testing.expectEqual(@as(u8, 1), addr.bytes[2]);
    try Basics.testing.expectEqual(@as(u8, 1), addr.bytes[3]);
}

test "checksum" {
    const data = [_]u8{ 0x45, 0x00, 0x00, 0x3c };
    const checksum = calculateChecksum(&data);
    try Basics.testing.expect(checksum != 0);
}

test "UDP header" {
    const header = UdpHeader.init(1234, 5678, 100);
    try Basics.testing.expectEqual(@as(u16, 1234), header.getSrcPort());
    try Basics.testing.expectEqual(@as(u16, 5678), header.getDestPort());
    try Basics.testing.expectEqual(@as(u16, @sizeOf(UdpHeader) + 100), header.getLength());
}

test "TCP header and flags" {
    var flags = TcpFlags{};
    flags.syn = true;
    flags.ack = true;

    const header = TcpHeader.init(8080, 80, 1000, 2000, flags);
    try Basics.testing.expectEqual(@as(u16, 8080), header.getSrcPort());
    try Basics.testing.expectEqual(@as(u16, 80), header.getDestPort());
    try Basics.testing.expectEqual(@as(u32, 1000), header.getSeqNum());
    try Basics.testing.expectEqual(@as(u32, 2000), header.getAckNum());

    const parsed_flags = header.getFlags();
    try Basics.testing.expect(parsed_flags.syn);
    try Basics.testing.expect(parsed_flags.ack);
    try Basics.testing.expect(!parsed_flags.fin);
}

test "TCP state transitions" {
    const allocator = Basics.testing.allocator;
    var sock = TcpSocket.init(allocator);
    defer sock.deinit();

    try Basics.testing.expectEqual(TcpState.Closed, sock.state);
}
