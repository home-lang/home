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

pub fn sendArpRequest(dev: *netdev.NetDevice, target_ip: IPv4Address) !void {
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

    if (arp.getOpcode() == .Request) {
        // TODO: Check if target_ip matches our IP, send reply
    } else if (arp.getOpcode() == .Reply) {
        // TODO: Update ARP cache
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
        .TCP => {}, // TODO
        .UDP => {}, // TODO
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
