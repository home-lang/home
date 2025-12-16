// Network Protocol Tests
const std = @import("std");
const testing = std.testing;

// Ethernet Frame Tests
test "Ethernet: frame header structure" {
    const EthernetHeader = packed struct {
        dst_mac: [6]u8,
        src_mac: [6]u8,
        ethertype: u16,
    };
    try testing.expectEqual(@as(usize, 14), @sizeOf(EthernetHeader));
}

// IPv4 Tests
test "IPv4: header structure" {
    const IPv4Header = packed struct {
        version_ihl: u8,
        dscp_ecn: u8,
        total_length: u16,
        identification: u16,
        flags_fragment: u16,
        ttl: u8,
        protocol: u8,
        checksum: u16,
        src_addr: u32,
        dst_addr: u32,
    };
    try testing.expectEqual(@as(usize, 20), @sizeOf(IPv4Header));
}

test "IPv4: checksum calculation" {
    const header_bytes = [_]u8{
        0x45, 0x00, 0x00, 0x3c, // version, IHL, DSCP, total length
        0x1c, 0x46, 0x40, 0x00, // identification, flags, fragment
        0x40, 0x06, 0x00, 0x00, // TTL, protocol (TCP), checksum placeholder
        0xac, 0x10, 0x0a, 0x63, // source IP (172.16.10.99)
        0xac, 0x10, 0x0a, 0x0c, // dest IP (172.16.10.12)
    };
    
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < header_bytes.len) : (i += 2) {
        const word = (@as(u32, header_bytes[i]) << 8) | header_bytes[i + 1];
        sum += word;
    }
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    _ = ~@as(u16, @truncate(sum));
}

// TCP Tests
test "TCP: header structure" {
    const TCPHeader = packed struct {
        src_port: u16,
        dst_port: u16,
        seq_num: u32,
        ack_num: u32,
        data_offset_flags: u16,
        window_size: u16,
        checksum: u16,
        urgent_ptr: u16,
    };
    try testing.expectEqual(@as(usize, 20), @sizeOf(TCPHeader));
}

test "TCP: flag parsing" {
    const flags: u16 = 0x5018; // Data offset 5, PSH + ACK
    const data_offset = (flags >> 12) & 0xF;
    try testing.expectEqual(@as(u16, 5), data_offset);
    const ack = (flags >> 4) & 1;
    try testing.expectEqual(@as(u16, 1), ack);
    const psh = (flags >> 3) & 1;
    try testing.expectEqual(@as(u16, 1), psh);
}

// UDP Tests
test "UDP: header structure" {
    const UDPHeader = packed struct {
        src_port: u16,
        dst_port: u16,
        length: u16,
        checksum: u16,
    };
    try testing.expectEqual(@as(usize, 8), @sizeOf(UDPHeader));
}

// DNS Tests
test "DNS: header structure" {
    const DNSHeader = packed struct {
        id: u16,
        flags: u16,
        qd_count: u16,
        an_count: u16,
        ns_count: u16,
        ar_count: u16,
    };
    try testing.expectEqual(@as(usize, 12), @sizeOf(DNSHeader));
}

test "DNS: query flags" {
    const flags: u16 = 0x0100; // Standard query, recursion desired
    const qr = (flags >> 15) & 1;
    try testing.expectEqual(@as(u16, 0), qr); // Query
    const rd = (flags >> 8) & 1;
    try testing.expectEqual(@as(u16, 1), rd); // Recursion desired
}

// ARP Tests
test "ARP: packet structure" {
    const ARPPacket = packed struct {
        hw_type: u16,
        proto_type: u16,
        hw_addr_len: u8,
        proto_addr_len: u8,
        operation: u16,
        sender_hw_addr: [6]u8,
        sender_proto_addr: u32,
        target_hw_addr: [6]u8,
        target_proto_addr: u32,
    };
    try testing.expectEqual(@as(usize, 28), @sizeOf(ARPPacket));
}

// ICMP Tests
test "ICMP: header structure" {
    const ICMPHeader = packed struct {
        icmp_type: u8,
        code: u8,
        checksum: u16,
        identifier: u16,
        sequence: u16,
    };
    try testing.expectEqual(@as(usize, 8), @sizeOf(ICMPHeader));
}

test "ICMP: echo request" {
    const ICMP_ECHO_REQUEST: u8 = 8;
    const ICMP_ECHO_REPLY: u8 = 0;
    try testing.expect(ICMP_ECHO_REQUEST != ICMP_ECHO_REPLY);
}
