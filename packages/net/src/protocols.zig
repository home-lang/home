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
    // Read CPU timestamp counter for monotonic time
    // This provides high-resolution timing without syscalls
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : "={eax}" (low),
          "={edx}" (high),
    );
    // Convert to nanoseconds (assuming ~3GHz CPU for approximation)
    // In a real system, this would be calibrated against a known time source
    const ticks = (@as(u64, high) << 32) | @as(u64, low);
    return ticks / 3; // Approximate nanoseconds at 3GHz
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

// ============================================================================
// IP Routing Table
// ============================================================================

pub const RouteEntry = struct {
    destination: IPv4Address,
    netmask: IPv4Address,
    gateway: IPv4Address,
    interface: ?*netdev.NetDevice,
    metric: u32,
    flags: RouteFlags,

    pub const RouteFlags = packed struct(u8) {
        up: bool = true,
        gateway: bool = false, // Route uses a gateway
        host: bool = false, // Host route (not network)
        reject: bool = false, // Reject route
        local: bool = false, // Local interface route
        _padding: u3 = 0,
    };

    /// Check if an IP matches this route
    pub fn matches(self: *const RouteEntry, ip: IPv4Address) bool {
        const masked_ip = IPv4Address{ .bytes = .{
            ip.bytes[0] & self.netmask.bytes[0],
            ip.bytes[1] & self.netmask.bytes[1],
            ip.bytes[2] & self.netmask.bytes[2],
            ip.bytes[3] & self.netmask.bytes[3],
        } };
        return masked_ip.equals(self.destination);
    }

    /// Get prefix length from netmask (for sorting by specificity)
    pub fn prefixLen(self: *const RouteEntry) u8 {
        var count: u8 = 0;
        for (self.netmask.bytes) |b| {
            var byte = b;
            while (byte & 0x80 != 0) : (byte <<= 1) {
                count += 1;
            }
        }
        return count;
    }
};

pub const RoutingTable = struct {
    routes: Basics.ArrayList(RouteEntry),
    lock: sync.RwLock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) RoutingTable {
        return .{
            .routes = Basics.ArrayList(RouteEntry).init(allocator),
            .lock = sync.RwLock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RoutingTable) void {
        self.routes.deinit();
    }

    /// Add a route to the table
    pub fn addRoute(self: *RoutingTable, route: RouteEntry) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Insert sorted by prefix length (longest prefix match first)
        const new_prefix = route.prefixLen();
        var insert_idx: usize = self.routes.items.len;

        for (self.routes.items, 0..) |existing, i| {
            if (new_prefix > existing.prefixLen()) {
                insert_idx = i;
                break;
            }
        }

        try self.routes.insert(insert_idx, route);
    }

    /// Remove a route from the table
    pub fn removeRoute(self: *RoutingTable, dest: IPv4Address, netmask: IPv4Address) bool {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        for (self.routes.items, 0..) |route, i| {
            if (route.destination.equals(dest) and route.netmask.equals(netmask)) {
                _ = self.routes.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Look up the best route for a destination
    pub fn lookup(self: *RoutingTable, dest_ip: IPv4Address) ?RouteEntry {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        // Routes are sorted by prefix length, so first match is best
        for (self.routes.items) |route| {
            if (route.flags.up and route.matches(dest_ip)) {
                return route;
            }
        }
        return null;
    }

    /// Get the interface and next-hop for a destination
    pub fn resolveNextHop(self: *RoutingTable, dest_ip: IPv4Address) ?struct { dev: *netdev.NetDevice, next_hop: IPv4Address } {
        const route = self.lookup(dest_ip) orelse return null;
        const dev = route.interface orelse return null;

        // If route has gateway, use it; otherwise direct to destination
        const next_hop = if (route.flags.gateway) route.gateway else dest_ip;

        return .{ .dev = dev, .next_hop = next_hop };
    }
};

var global_routing_table: ?*RoutingTable = null;
var routing_table_lock: sync.Spinlock = sync.Spinlock.init();

pub fn getRoutingTable(allocator: Basics.Allocator) !*RoutingTable {
    if (global_routing_table) |table| {
        return table;
    }

    routing_table_lock.acquire();
    defer routing_table_lock.release();

    if (global_routing_table == null) {
        const table = try allocator.create(RoutingTable);
        table.* = RoutingTable.init(allocator);
        global_routing_table = table;
    }

    return global_routing_table.?;
}

// ============================================================================
// IP Fragmentation and Reassembly
// ============================================================================

/// Fragment ID generator
var fragment_id_counter: atomic.AtomicU16 = atomic.AtomicU16.init(0);

fn nextFragmentId() u16 {
    return fragment_id_counter.fetchAdd(1, .Monotonic);
}

/// Fragment offset is in units of 8 bytes
const FRAGMENT_OFFSET_UNIT: usize = 8;

/// Max fragment payload (MTU - IP header)
const MAX_FRAGMENT_PAYLOAD: usize = 1480;

/// IP fragmentation flags
const IP_FLAG_DF: u16 = 0x4000; // Don't Fragment
const IP_FLAG_MF: u16 = 0x2000; // More Fragments
const IP_OFFSET_MASK: u16 = 0x1FFF;

/// Fragment a large IP packet
pub fn fragmentIPv4(
    allocator: Basics.Allocator,
    src_ip: IPv4Address,
    dest_ip: IPv4Address,
    protocol: IpProtocol,
    payload: []const u8,
    mtu: usize,
) !Basics.ArrayList([]u8) {
    var fragments = Basics.ArrayList([]u8).init(allocator);
    errdefer {
        for (fragments.items) |frag| {
            allocator.free(frag);
        }
        fragments.deinit();
    }

    const max_payload = mtu - @sizeOf(IPv4Header);
    // Fragment offset must be multiple of 8
    const payload_per_fragment = (max_payload / FRAGMENT_OFFSET_UNIT) * FRAGMENT_OFFSET_UNIT;

    const frag_id = nextFragmentId();
    var offset: usize = 0;

    while (offset < payload.len) {
        const remaining = payload.len - offset;
        const this_payload_len = @min(payload_per_fragment, remaining);
        const is_last = (offset + this_payload_len >= payload.len);

        // Create fragment
        var header = IPv4Header.init(src_ip, dest_ip, protocol, @intCast(this_payload_len));
        header.identification = @byteSwap(frag_id);

        // Set fragment flags and offset
        var flags_offset: u16 = @intCast(offset / FRAGMENT_OFFSET_UNIT);
        if (!is_last) {
            flags_offset |= IP_FLAG_MF;
        }
        header.flags_fragment = @byteSwap(flags_offset);

        // Calculate checksum
        header.checksum = 0;
        header.checksum = header.calculateChecksum();

        // Build fragment packet
        const frag_buf = try allocator.alloc(u8, @sizeOf(IPv4Header) + this_payload_len);
        @memcpy(frag_buf[0..@sizeOf(IPv4Header)], Basics.mem.asBytes(&header));
        @memcpy(frag_buf[@sizeOf(IPv4Header)..], payload[offset..][0..this_payload_len]);

        try fragments.append(frag_buf);
        offset += this_payload_len;
    }

    return fragments;
}

/// Reassembly buffer for fragmented packets
const ReassemblyEntry = struct {
    src_ip: IPv4Address,
    dest_ip: IPv4Address,
    id: u16,
    protocol: IpProtocol,
    fragments: [64]?FragmentData, // Max 64 fragments
    total_len: usize,
    received_len: usize,
    last_fragment_received: bool,
    timestamp: u64,
    allocator: Basics.Allocator,

    const FragmentData = struct {
        offset: usize,
        data: []u8,
    };

    const TIMEOUT_NS: u64 = 30_000_000_000; // 30 seconds

    pub fn init(allocator: Basics.Allocator, src: IPv4Address, dest: IPv4Address, id: u16, proto: IpProtocol) ReassemblyEntry {
        return .{
            .src_ip = src,
            .dest_ip = dest,
            .id = id,
            .protocol = proto,
            .fragments = [_]?FragmentData{null} ** 64,
            .total_len = 0,
            .received_len = 0,
            .last_fragment_received = false,
            .timestamp = getMonotonicTime(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ReassemblyEntry) void {
        for (&self.fragments) |*frag| {
            if (frag.*) |f| {
                self.allocator.free(f.data);
                frag.* = null;
            }
        }
    }

    /// Add a fragment to the reassembly buffer
    pub fn addFragment(self: *ReassemblyEntry, offset: usize, data: []const u8, more_fragments: bool) !bool {
        // Find slot for this fragment
        const slot_idx = offset / MAX_FRAGMENT_PAYLOAD;
        if (slot_idx >= 64) return error.TooManyFragments;

        // Copy data
        const data_copy = try self.allocator.alloc(u8, data.len);
        @memcpy(data_copy, data);

        self.fragments[slot_idx] = .{
            .offset = offset,
            .data = data_copy,
        };

        self.received_len += data.len;

        if (!more_fragments) {
            self.last_fragment_received = true;
            self.total_len = offset + data.len;
        }

        // Check if complete
        return self.isComplete();
    }

    /// Check if all fragments received
    pub fn isComplete(self: *const ReassemblyEntry) bool {
        if (!self.last_fragment_received) return false;
        return self.received_len >= self.total_len;
    }

    /// Check if timed out
    pub fn isExpired(self: *const ReassemblyEntry) bool {
        return (getMonotonicTime() - self.timestamp) > TIMEOUT_NS;
    }

    /// Reassemble the complete packet
    pub fn reassemble(self: *ReassemblyEntry) ![]u8 {
        if (!self.isComplete()) return error.IncompletePacket;

        const result = try self.allocator.alloc(u8, self.total_len);
        errdefer self.allocator.free(result);

        for (self.fragments) |frag| {
            if (frag) |f| {
                @memcpy(result[f.offset..][0..f.data.len], f.data);
            }
        }

        return result;
    }
};

var reassembly_buffer: [32]?ReassemblyEntry = [_]?ReassemblyEntry{null} ** 32;
var reassembly_lock: sync.Mutex = sync.Mutex.init();

/// Process incoming IP fragment
pub fn processIPFragment(
    allocator: Basics.Allocator,
    src_ip: IPv4Address,
    dest_ip: IPv4Address,
    id: u16,
    protocol: IpProtocol,
    offset: usize,
    data: []const u8,
    more_fragments: bool,
) !?[]u8 {
    reassembly_lock.lock();
    defer reassembly_lock.unlock();

    // Find existing entry or create new
    var entry_idx: ?usize = null;
    var free_idx: ?usize = null;

    for (&reassembly_buffer, 0..) |*entry, i| {
        if (entry.*) |*e| {
            if (e.src_ip.equals(src_ip) and e.dest_ip.equals(dest_ip) and e.id == id) {
                entry_idx = i;
                break;
            }
            if (e.isExpired()) {
                e.deinit();
                entry.* = null;
                free_idx = i;
            }
        } else {
            if (free_idx == null) free_idx = i;
        }
    }

    if (entry_idx == null) {
        if (free_idx == null) {
            // No space - drop oldest
            return error.ReassemblyBufferFull;
        }
        reassembly_buffer[free_idx.?] = ReassemblyEntry.init(allocator, src_ip, dest_ip, id, protocol);
        entry_idx = free_idx;
    }

    const entry = &reassembly_buffer[entry_idx.?].?;
    const complete = try entry.addFragment(offset, data, more_fragments);

    if (complete) {
        const result = try entry.reassemble();
        entry.deinit();
        reassembly_buffer[entry_idx.?] = null;
        return result;
    }

    return null;
}

pub fn sendIPv4(dev: *netdev.NetDevice, dest_ip: IPv4Address, protocol: IpProtocol, payload: []const u8) !void {
    const src_ip = getDeviceIP(dev);

    // Check if fragmentation is needed
    if (payload.len > dev.mtu - @sizeOf(IPv4Header)) {
        // Need to fragment
        var fragments = try fragmentIPv4(dev.allocator, src_ip, dest_ip, protocol, payload, dev.mtu);
        defer {
            for (fragments.items) |frag| {
                dev.allocator.free(frag);
            }
            fragments.deinit();
        }

        for (fragments.items) |frag| {
            const dest_mac = try resolveDestMac(dev, dest_ip);
            try sendEthernet(dev, dest_mac, .IPv4, frag);
        }
    } else {
        // No fragmentation needed
        var ip_header = IPv4Header.init(src_ip, dest_ip, protocol, @intCast(payload.len));
        ip_header.checksum = 0;
        ip_header.checksum = ip_header.calculateChecksum();

        var buffer: [@sizeOf(IPv4Header) + 1500]u8 = undefined;
        @memcpy(buffer[0..@sizeOf(IPv4Header)], Basics.mem.asBytes(&ip_header));
        @memcpy(buffer[@sizeOf(IPv4Header)..][0..payload.len], payload);

        const dest_mac = try resolveDestMac(dev, dest_ip);
        try sendEthernet(dev, dest_mac, .IPv4, buffer[0 .. @sizeOf(IPv4Header) + payload.len]);
    }
}

/// Resolve destination MAC address using ARP
fn resolveDestMac(dev: *netdev.NetDevice, dest_ip: IPv4Address) !netdev.MacAddress {
    // Check if on same subnet or need gateway
    const our_ip = getDeviceIP(dev);
    const netmask = getDeviceNetmask(dev);

    // Mask both addresses
    const our_network = IPv4Address{ .bytes = .{
        our_ip.bytes[0] & netmask.bytes[0],
        our_ip.bytes[1] & netmask.bytes[1],
        our_ip.bytes[2] & netmask.bytes[2],
        our_ip.bytes[3] & netmask.bytes[3],
    } };
    const dest_network = IPv4Address{ .bytes = .{
        dest_ip.bytes[0] & netmask.bytes[0],
        dest_ip.bytes[1] & netmask.bytes[1],
        dest_ip.bytes[2] & netmask.bytes[2],
        dest_ip.bytes[3] & netmask.bytes[3],
    } };

    // Determine next-hop IP (gateway or direct)
    const next_hop_ip = if (our_network.equals(dest_network))
        dest_ip // Same network, direct
    else blk: {
        // Different network, use routing table
        if (global_routing_table) |table| {
            if (table.resolveNextHop(dest_ip)) |resolved| {
                break :blk resolved.next_hop;
            }
        }
        // No route, try default gateway
        break :blk getDefaultGateway();
    };

    // Look up MAC in ARP cache
    const cache = try getArpCache(dev.allocator);
    if (cache.lookup(next_hop_ip)) |mac| {
        return mac;
    }

    // Not in cache - send ARP request
    try sendArpRequest(dev, next_hop_ip, dev.allocator);

    // Return broadcast for now (ARP reply will update cache)
    // In real implementation, queue packet and wait for ARP reply
    return netdev.MacAddress.init([_]u8{0xFF} ** 6);
}

fn getDeviceNetmask(dev: *netdev.NetDevice) IPv4Address {
    // Get netmask from device IP configuration
    if (dev.ip_config) |config| {
        return config.netmask;
    }
    // Default to /24 if not configured
    return IPv4Address.init(255, 255, 255, 0);
}

fn getDefaultGateway() IPv4Address {
    // Get default gateway from routing table
    if (global_routing_table) |table| {
        // Look for default route (0.0.0.0/0)
        const default_dest = IPv4Address.init(0, 0, 0, 0);
        if (table.lookup(default_dest)) |route| {
            if (route.flags.gateway) {
                return route.gateway;
            }
        }
    }
    // Fallback to common default gateway
    return IPv4Address.init(192, 168, 1, 1);
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
    // Get the IP header first (we need source IP for reply)
    const full_data = skb.data[skb.head - @sizeOf(IPv4Header) ..];
    const ip_header: *const IPv4Header = @ptrCast(@alignCast(full_data.ptr));
    const src_ip = IPv4Address{ .bytes = ip_header.src_ip };

    _ = try skb.pull(@sizeOf(IPv4Header));

    const icmp_data = skb.getData();
    if (icmp_data.len < @sizeOf(IcmpHeader)) return error.InvalidICMP;

    const icmp: *const IcmpHeader = @ptrCast(@alignCast(icmp_data.ptr));

    switch (icmp.getType()) {
        .EchoRequest => {
            // Send echo reply back to sender
            try sendEchoReply(skb.dev.?, src_ip, icmp, icmp_data[@sizeOf(IcmpHeader)..]);
        },
        .EchoReply => {
            // Notify waiting ping requests
            notifyPingReply(icmp.identifier, icmp.sequence, src_ip);
        },
        else => {
            // Handle other ICMP types (DestinationUnreachable, TimeExceeded, etc.)
            handleIcmpError(icmp, src_ip);
        },
    }
}

/// Send ICMP echo reply
fn sendEchoReply(dev: *netdev.NetDevice, dest_ip: IPv4Address, request: *const IcmpHeader, payload: []const u8) !void {
    var reply = IcmpHeader.init(.EchoReply, @byteSwap(request.identifier), @byteSwap(request.sequence));

    var buffer: [@sizeOf(IcmpHeader) + 1472]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(IcmpHeader)], Basics.mem.asBytes(&reply));
    @memcpy(buffer[@sizeOf(IcmpHeader)..][0..payload.len], payload);

    const reply_ptr: *IcmpHeader = @ptrCast(@alignCast(&buffer));
    reply_ptr.checksum = calculateChecksum(buffer[0 .. @sizeOf(IcmpHeader) + payload.len]);

    try sendIPv4(dev, dest_ip, .ICMP, buffer[0 .. @sizeOf(IcmpHeader) + payload.len]);
}

/// Pending ping requests waiting for replies
const PingRequest = struct {
    identifier: u16,
    sequence: u16,
    timestamp: u64,
    completed: bool,
    rtt_ns: u64,
    reply_ip: IPv4Address,
};

var pending_pings: [64]?PingRequest = [_]?PingRequest{null} ** 64;
var ping_mutex: sync.Mutex = sync.Mutex.init();

/// Notify waiting ping request of reply
fn notifyPingReply(identifier: u16, sequence: u16, from_ip: IPv4Address) void {
    ping_mutex.lock();
    defer ping_mutex.unlock();

    const id = @byteSwap(identifier);
    const seq = @byteSwap(sequence);

    for (&pending_pings) |*slot| {
        if (slot.*) |*req| {
            if (req.identifier == id and req.sequence == seq) {
                req.completed = true;
                req.rtt_ns = getMonotonicTime() - req.timestamp;
                req.reply_ip = from_ip;
                break;
            }
        }
    }
}

/// Handle ICMP error messages
fn handleIcmpError(icmp: *const IcmpHeader, from_ip: IPv4Address) void {
    _ = icmp;
    _ = from_ip;
    // Log or handle ICMP errors (destination unreachable, time exceeded, etc.)
    // These can be used to notify TCP/UDP of path issues
}

/// Ping with timeout - returns RTT in nanoseconds or error
pub fn ping(dev: *netdev.NetDevice, dest_ip: IPv4Address, timeout_ms: u64) !u64 {
    const identifier: u16 = @truncate(getMonotonicTime() & 0xFFFF);
    const sequence: u16 = 1;

    // Register pending ping
    var slot_idx: ?usize = null;
    {
        ping_mutex.lock();
        defer ping_mutex.unlock();

        for (&pending_pings, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = .{
                    .identifier = identifier,
                    .sequence = sequence,
                    .timestamp = getMonotonicTime(),
                    .completed = false,
                    .rtt_ns = 0,
                    .reply_ip = IPv4Address.init(0, 0, 0, 0),
                };
                slot_idx = i;
                break;
            }
        }
    }

    if (slot_idx == null) return error.TooManyPendingPings;
    defer {
        ping_mutex.lock();
        pending_pings[slot_idx.?] = null;
        ping_mutex.unlock();
    }

    // Send ping
    try sendPing(dev, dest_ip, identifier, sequence);

    // Wait for reply with timeout
    const deadline = getMonotonicTime() + (timeout_ms * 1_000_000);
    while (getMonotonicTime() < deadline) {
        ping_mutex.lock();
        if (pending_pings[slot_idx.?]) |req| {
            if (req.completed) {
                const rtt = req.rtt_ns;
                ping_mutex.unlock();
                return rtt;
            }
        }
        ping_mutex.unlock();

        // Small sleep to avoid busy-waiting (yield to scheduler)
        // In real implementation, use a condition variable
    }

    return error.PingTimeout;
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

        // Register socket with UDP layer for incoming packet delivery
        udp_mutex.lock();
        defer udp_mutex.unlock();

        if (udp_sockets == null) {
            udp_sockets = Basics.ArrayList(*UdpSocket).init(self.allocator);
        }
        try udp_sockets.?.append(self);
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

/// TCP retransmission segment
const TcpRetransmitSegment = struct {
    data: []u8,
    seq_num: u32,
    sent_time: u64,
    retries: u8,
    allocator: Basics.Allocator,

    const MAX_RETRIES: u8 = 5;
    const INITIAL_RTO_MS: u64 = 1000; // 1 second initial RTO

    pub fn deinit(self: *TcpRetransmitSegment) void {
        self.allocator.free(self.data);
    }
};

/// Pending connection from SYN received
const TcpPendingConnection = struct {
    remote_ip: IPv4Address,
    remote_port: u16,
    seq_num: u32,
    ack_num: u32,
    timestamp: u64,
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
    retransmit_queue: Basics.ArrayList(TcpRetransmitSegment),
    pending_connections: Basics.ArrayList(TcpPendingConnection),
    backlog: u16,
    window_size: u16,
    congestion_window: u32,
    ssthresh: u32,
    rtt_estimate: u64, // RTT in nanoseconds
    rto: u64, // Retransmission timeout in nanoseconds
    last_ack_received: u32,
    dup_ack_count: u8,
    dev: ?*netdev.NetDevice,
    allocator: Basics.Allocator,
    mutex: sync.Mutex,

    const INITIAL_WINDOW: u16 = 65535;
    const INITIAL_CWND: u32 = 10 * 1460; // 10 segments
    const INITIAL_SSTHRESH: u32 = 65535;

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
            .retransmit_queue = Basics.ArrayList(TcpRetransmitSegment).init(allocator),
            .pending_connections = Basics.ArrayList(TcpPendingConnection).init(allocator),
            .backlog = 0,
            .window_size = INITIAL_WINDOW,
            .congestion_window = INITIAL_CWND,
            .ssthresh = INITIAL_SSTHRESH,
            .rtt_estimate = 100_000_000, // 100ms initial
            .rto = 1_000_000_000, // 1s initial RTO
            .last_ack_received = 0,
            .dup_ack_count = 0,
            .dev = null,
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }

    pub fn deinit(self: *TcpSocket) void {
        self.send_buffer.deinit();
        self.recv_buffer.deinit();
        for (self.retransmit_queue.items) |*seg| {
            seg.deinit();
        }
        self.retransmit_queue.deinit();
        self.pending_connections.deinit();
    }

    pub fn connect(self: *TcpSocket, dev: *netdev.NetDevice, remote_ip: IPv4Address, remote_port: u16, local_port: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .Closed) return error.InvalidState;

        self.remote_ip = remote_ip;
        self.remote_port = remote_port;
        self.local_port = local_port;
        self.seq_num = generateInitialSeqNum();
        self.state = .SynSent;
        self.dev = dev;

        // Send SYN
        var flags = TcpFlags{};
        flags.syn = true;
        try sendTCP(dev, local_port, remote_port, remote_ip, self.seq_num, 0, flags, &[_]u8{});

        // Queue for retransmission
        try self.queueRetransmit(&[_]u8{}, self.seq_num);
        self.seq_num += 1; // SYN consumes a sequence number
    }

    pub fn listen(self: *TcpSocket, port: u16, backlog_size: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .Closed) return error.InvalidState;

        self.local_port = port;
        self.backlog = backlog_size;
        self.state = .Listen;

        // Register this socket with global TCP socket list
        try registerTcpSocket(self);
    }

    /// Accept an incoming connection (blocking)
    pub fn accept(self: *TcpSocket, allocator: Basics.Allocator) !*TcpSocket {
        while (true) {
            self.mutex.lock();

            if (self.state != .Listen) {
                self.mutex.unlock();
                return error.NotListening;
            }

            // Check for pending connections
            if (self.pending_connections.items.len > 0) {
                const pending = self.pending_connections.orderedRemove(0);
                self.mutex.unlock();

                // Create new socket for this connection
                const new_socket = try allocator.create(TcpSocket);
                new_socket.* = TcpSocket.init(allocator);
                new_socket.local_port = self.local_port;
                new_socket.remote_ip = pending.remote_ip;
                new_socket.remote_port = pending.remote_port;
                new_socket.seq_num = pending.seq_num;
                new_socket.ack_num = pending.ack_num;
                new_socket.state = .Established;
                new_socket.dev = self.dev;

                // Register new socket
                try registerTcpSocket(new_socket);

                return new_socket;
            }

            self.mutex.unlock();

            // Yield to allow other processing
            // In real implementation, use condition variable wait
        }
    }

    /// Accept with timeout (non-blocking variant)
    pub fn acceptTimeout(self: *TcpSocket, allocator: Basics.Allocator, timeout_ms: u64) !?*TcpSocket {
        const deadline = getMonotonicTime() + (timeout_ms * 1_000_000);

        while (getMonotonicTime() < deadline) {
            self.mutex.lock();

            if (self.state != .Listen) {
                self.mutex.unlock();
                return error.NotListening;
            }

            if (self.pending_connections.items.len > 0) {
                const pending = self.pending_connections.orderedRemove(0);
                self.mutex.unlock();

                const new_socket = try allocator.create(TcpSocket);
                new_socket.* = TcpSocket.init(allocator);
                new_socket.local_port = self.local_port;
                new_socket.remote_ip = pending.remote_ip;
                new_socket.remote_port = pending.remote_port;
                new_socket.seq_num = pending.seq_num;
                new_socket.ack_num = pending.ack_num;
                new_socket.state = .Established;
                new_socket.dev = self.dev;

                try registerTcpSocket(new_socket);
                return new_socket;
            }

            self.mutex.unlock();
        }

        return null; // Timeout
    }

    /// Handle incoming SYN (for listening socket)
    pub fn handleIncomingSyn(self: *TcpSocket, dev: *netdev.NetDevice, remote_ip: IPv4Address, remote_port: u16, client_seq: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .Listen) return error.NotListening;

        // Check backlog
        if (self.pending_connections.items.len >= self.backlog) {
            return error.BacklogFull;
        }

        // Generate our sequence number and send SYN-ACK
        const our_seq = generateInitialSeqNum();
        const their_ack = client_seq + 1;

        var flags = TcpFlags{};
        flags.syn = true;
        flags.ack = true;

        try sendTCP(dev, self.local_port, remote_port, remote_ip, our_seq, their_ack, flags, &[_]u8{});

        // Add to pending connections (will be completed when we get ACK)
        try self.pending_connections.append(.{
            .remote_ip = remote_ip,
            .remote_port = remote_port,
            .seq_num = our_seq + 1, // Our seq after SYN-ACK
            .ack_num = their_ack,
            .timestamp = getMonotonicTime(),
        });

        self.dev = dev;
    }

    pub fn send(self: *TcpSocket, dev: *netdev.NetDevice, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .Established) return error.NotConnected;

        // Segment data if larger than MSS
        const MSS: usize = 1460;
        var offset: usize = 0;

        while (offset < data.len) {
            const segment_len = @min(MSS, data.len - offset);
            const segment = data[offset..][0..segment_len];

            var flags = TcpFlags{};
            flags.ack = true;
            if (offset + segment_len >= data.len) {
                flags.psh = true; // PSH on last segment
            }

            try sendTCP(dev, self.local_port, self.remote_port, self.remote_ip, self.seq_num, self.ack_num, flags, segment);

            // Queue for retransmission
            try self.queueRetransmit(segment, self.seq_num);

            self.seq_num += @intCast(segment_len);
            offset += segment_len;
        }
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

    /// Handle incoming ACK - process retransmission queue
    pub fn handleAck(self: *TcpSocket, ack_num: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check for duplicate ACK (fast retransmit)
        if (ack_num == self.last_ack_received) {
            self.dup_ack_count += 1;
            if (self.dup_ack_count >= 3) {
                // Fast retransmit - retransmit first unacked segment
                if (self.retransmit_queue.items.len > 0) {
                    self.retransmitFirst() catch {};
                }
                // Fast recovery
                self.ssthresh = self.congestion_window / 2;
                self.congestion_window = self.ssthresh + 3 * 1460;
            }
        } else {
            self.last_ack_received = ack_num;
            self.dup_ack_count = 0;

            // Remove acknowledged segments from retransmit queue
            var i: usize = 0;
            while (i < self.retransmit_queue.items.len) {
                const seg = &self.retransmit_queue.items[i];
                if (seqLessThan(seg.seq_num + @as(u32, @intCast(seg.data.len)), ack_num) or
                    seg.seq_num + @as(u32, @intCast(seg.data.len)) == ack_num)
                {
                    // Segment fully acknowledged
                    seg.deinit();
                    _ = self.retransmit_queue.orderedRemove(i);
                    // Don't increment i since we removed
                } else {
                    i += 1;
                }
            }

            // Congestion control: increase window
            if (self.congestion_window < self.ssthresh) {
                // Slow start
                self.congestion_window += 1460;
            } else {
                // Congestion avoidance
                self.congestion_window += 1460 * 1460 / self.congestion_window;
            }
        }
    }

    fn retransmitFirst(self: *TcpSocket) !void {
        if (self.retransmit_queue.items.len == 0) return;

        const seg = &self.retransmit_queue.items[0];
        if (seg.retries >= TcpRetransmitSegment.MAX_RETRIES) {
            // Connection failed
            self.state = .Closed;
            return error.ConnectionTimeout;
        }

        var flags = TcpFlags{};
        flags.ack = true;

        if (self.dev) |dev| {
            try sendTCP(dev, self.local_port, self.remote_port, self.remote_ip, seg.seq_num, self.ack_num, flags, seg.data);
        }

        seg.retries += 1;
        seg.sent_time = getMonotonicTime();
    }

    fn queueRetransmit(self: *TcpSocket, data: []const u8, seq: u32) !void {
        const data_copy = try self.allocator.alloc(u8, data.len);
        @memcpy(data_copy, data);

        try self.retransmit_queue.append(.{
            .data = data_copy,
            .seq_num = seq,
            .sent_time = getMonotonicTime(),
            .retries = 0,
            .allocator = self.allocator,
        });
    }

    /// Check and process retransmission timeouts
    pub fn processRetransmitTimer(self: *TcpSocket) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = getMonotonicTime();

        for (self.retransmit_queue.items) |*seg| {
            if (now - seg.sent_time > self.rto) {
                // Timeout - retransmit
                if (seg.retries >= TcpRetransmitSegment.MAX_RETRIES) {
                    self.state = .Closed;
                    return error.ConnectionTimeout;
                }

                var flags = TcpFlags{};
                flags.ack = true;

                if (self.dev) |dev| {
                    try sendTCP(dev, self.local_port, self.remote_port, self.remote_ip, seg.seq_num, self.ack_num, flags, seg.data);
                }

                seg.retries += 1;
                seg.sent_time = now;

                // Exponential backoff
                self.rto *= 2;
                if (self.rto > 60_000_000_000) { // Max 60 seconds
                    self.rto = 60_000_000_000;
                }

                // Congestion: reduce window
                self.ssthresh = self.congestion_window / 2;
                self.congestion_window = 1460; // Reset to 1 segment
            }
        }
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
        } else if (self.state == .CloseWait) {
            self.state = .LastAck;

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

/// Generate initial sequence number (should be random in production)
fn generateInitialSeqNum() u32 {
    return @truncate(getMonotonicTime() & 0xFFFFFFFF);
}

/// Sequence number comparison (handles wraparound)
fn seqLessThan(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

/// Register TCP socket with global list
fn registerTcpSocket(sock: *TcpSocket) !void {
    tcp_mutex.lock();
    defer tcp_mutex.unlock();

    if (tcp_sockets == null) {
        tcp_sockets = Basics.ArrayList(*TcpSocket).init(sock.allocator);
    }
    try tcp_sockets.?.append(sock);
}

/// Unregister TCP socket
fn unregisterTcpSocket(sock: *TcpSocket) void {
    tcp_mutex.lock();
    defer tcp_mutex.unlock();

    if (tcp_sockets) |*sockets| {
        for (sockets.items, 0..) |s, i| {
            if (s == sock) {
                _ = sockets.orderedRemove(i);
                break;
            }
        }
    }
}

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
    // Get IP address from device configuration
    if (dev.ip_config) |config| {
        return config.address;
    }
    // Return zero address if not configured (will fail to communicate)
    return IPv4Address.init(0, 0, 0, 0);
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

test "routing table prefix matching" {
    const route = RouteEntry{
        .destination = IPv4Address.init(192, 168, 1, 0),
        .netmask = IPv4Address.init(255, 255, 255, 0),
        .gateway = IPv4Address.init(0, 0, 0, 0),
        .interface = null,
        .metric = 0,
        .flags = .{},
    };

    // Should match IPs in 192.168.1.0/24
    try Basics.testing.expect(route.matches(IPv4Address.init(192, 168, 1, 100)));
    try Basics.testing.expect(route.matches(IPv4Address.init(192, 168, 1, 1)));
    try Basics.testing.expect(route.matches(IPv4Address.init(192, 168, 1, 255)));

    // Should not match IPs outside the network
    try Basics.testing.expect(!route.matches(IPv4Address.init(192, 168, 2, 1)));
    try Basics.testing.expect(!route.matches(IPv4Address.init(10, 0, 0, 1)));

    // Check prefix length
    try Basics.testing.expectEqual(@as(u8, 24), route.prefixLen());
}

test "routing table lookup" {
    const allocator = Basics.testing.allocator;
    var table = RoutingTable.init(allocator);
    defer table.deinit();

    // Add routes with different prefix lengths
    try table.addRoute(.{
        .destination = IPv4Address.init(0, 0, 0, 0),
        .netmask = IPv4Address.init(0, 0, 0, 0),
        .gateway = IPv4Address.init(192, 168, 1, 1),
        .interface = null,
        .metric = 100,
        .flags = .{ .gateway = true },
    });

    try table.addRoute(.{
        .destination = IPv4Address.init(192, 168, 1, 0),
        .netmask = IPv4Address.init(255, 255, 255, 0),
        .gateway = IPv4Address.init(0, 0, 0, 0),
        .interface = null,
        .metric = 0,
        .flags = .{ .local = true },
    });

    // Lookup should find most specific route first (longest prefix match)
    const local_route = table.lookup(IPv4Address.init(192, 168, 1, 50));
    try Basics.testing.expect(local_route != null);
    try Basics.testing.expect(local_route.?.flags.local);

    // External IP should match default route
    const external_route = table.lookup(IPv4Address.init(8, 8, 8, 8));
    try Basics.testing.expect(external_route != null);
    try Basics.testing.expect(external_route.?.flags.gateway);
}

test "ICMP header" {
    const icmp = IcmpHeader.init(.EchoRequest, 0x1234, 1);
    try Basics.testing.expectEqual(IcmpType.EchoRequest, icmp.getType());
}

test "IP fragmentation calculation" {
    // Fragment offset must be multiple of 8 bytes
    const offset1: usize = 1480 / FRAGMENT_OFFSET_UNIT;
    try Basics.testing.expectEqual(@as(usize, 185), offset1);

    // IP_FLAG_MF should be set for non-last fragments
    var flags: u16 = 0;
    flags |= IP_FLAG_MF;
    try Basics.testing.expect(flags & IP_FLAG_MF != 0);
}

test "sequence number comparison" {
    // Test wraparound handling
    try Basics.testing.expect(seqLessThan(0xFFFFFFFF, 0));
    try Basics.testing.expect(!seqLessThan(0, 0xFFFFFFFF));
    try Basics.testing.expect(seqLessThan(100, 200));
    try Basics.testing.expect(!seqLessThan(200, 100));
}

test "ARP cache entry" {
    var entry = ArpCacheEntry.init(IPv4Address.init(192, 168, 1, 1));
    try Basics.testing.expectEqual(ArpCacheEntry.EntryState.Incomplete, entry.state);
    try Basics.testing.expect(entry.needsRetry());

    // Update with MAC
    entry.update(netdev.MacAddress.init([_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 }));
    try Basics.testing.expectEqual(ArpCacheEntry.EntryState.Reachable, entry.state);
    try Basics.testing.expect(!entry.needsRetry());
}

test "TCP congestion window" {
    const allocator = Basics.testing.allocator;
    var sock = TcpSocket.init(allocator);
    defer sock.deinit();

    // Initial values
    try Basics.testing.expectEqual(@as(u32, TcpSocket.INITIAL_CWND), sock.congestion_window);
    try Basics.testing.expectEqual(@as(u32, TcpSocket.INITIAL_SSTHRESH), sock.ssthresh);
}
