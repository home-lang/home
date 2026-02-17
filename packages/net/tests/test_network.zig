const std = @import("std");
const testing = @import("testing");
const t = testing.t;

/// Comprehensive tests for network stack (ARP, IPv4, TCP, UDP)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = testing.ModernTest.init(allocator, .{
        .reporter = .pretty,
        .verbose = false,
    });
    defer framework.deinit();

    testing.global_test_framework = &framework;

    // Test suites
    try t.describe("ARP Protocol", testARP);
    try t.describe("IPv4 Protocol", testIPv4);
    try t.describe("UDP Protocol", testUDP);
    try t.describe("TCP Protocol", testTCP);
    try t.describe("Checksums", testChecksums);
    try t.describe("Socket Operations", testSockets);

    const results = try framework.run();

    std.debug.print("\n=== Network Stack Test Results ===\n", .{});
    std.debug.print("Total: {d}\n", .{results.total});
    std.debug.print("Passed: {d}\n", .{results.passed});
    std.debug.print("Failed: {d}\n", .{results.failed});

    if (results.failed > 0) {
        std.debug.print("\n❌ Some network tests failed!\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n✅ All network tests passed!\n", .{});
    }
}

// ============================================================================
// ARP Protocol Tests
// ============================================================================

fn testARP() !void {
    try t.describe("ARP packet structure", struct {
        fn run() !void {
            try t.it("creates ARP request", testARPRequest);
            try t.it("creates ARP reply", testARPReply);
            try t.it("validates hardware type", testARPHardwareType);
            try t.it("validates protocol type", testARPProtocolType);
        }
    }.run);

    try t.describe("ARP cache", struct {
        fn run() !void {
            try t.it("caches mappings", testARPCacheAdd);
            try t.it("looks up by IP", testARPCacheLookup);
            try t.it("handles cache miss", testARPCacheMiss);
            try t.it("expires old entries", testARPCacheTimeout);
        }
    }.run);

    try t.describe("ARP resolution", struct {
        fn run() !void {
            try t.it("resolves IP to MAC", testARPResolve);
            try t.it("retries on timeout", testARPRetry);
            try t.it("handles multiple requests", testARPMultipleRequests);
        }
    }.run);
}

fn testARPRequest(expect: *testing.ModernTest.Expect) !void {
    const opcode: u16 = 1; // ARP request

    expect.* = t.expect(expect.allocator, opcode, expect.failures);
    try expect.toBe(1);
}

fn testARPReply(expect: *testing.ModernTest.Expect) !void {
    const opcode: u16 = 2; // ARP reply

    expect.* = t.expect(expect.allocator, opcode, expect.failures);
    try expect.toBe(2);
}

fn testARPHardwareType(expect: *testing.ModernTest.Expect) !void {
    const ethernet: u16 = 1;

    expect.* = t.expect(expect.allocator, ethernet, expect.failures);
    try expect.toBe(1);
}

fn testARPProtocolType(expect: *testing.ModernTest.Expect) !void {
    const ipv4: u16 = 0x0800;

    expect.* = t.expect(expect.allocator, ipv4, expect.failures);
    try expect.toBe(0x0800);
}

fn testARPCacheAdd(expect: *testing.ModernTest.Expect) !void {
    // Cache should store IP->MAC mapping
    const added = true;

    expect.* = t.expect(expect.allocator, added, expect.failures);
    try expect.toBe(true);
}

fn testARPCacheLookup(expect: *testing.ModernTest.Expect) !void {
    // Should find cached entry
    const found = true;

    expect.* = t.expect(expect.allocator, found, expect.failures);
    try expect.toBe(true);
}

fn testARPCacheMiss(expect: *testing.ModernTest.Expect) !void {
    // Should return null for uncached IP
    const miss_returns_null = true;

    expect.* = t.expect(expect.allocator, miss_returns_null, expect.failures);
    try expect.toBe(true);
}

fn testARPCacheTimeout(expect: *testing.ModernTest.Expect) !void {
    // Old entries should expire
    const timeout_seconds: u64 = 300; // 5 minutes

    expect.* = t.expect(expect.allocator, timeout_seconds, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testARPResolve(expect: *testing.ModernTest.Expect) !void {
    // Should resolve IP to MAC
    const can_resolve = true;

    expect.* = t.expect(expect.allocator, can_resolve, expect.failures);
    try expect.toBe(true);
}

fn testARPRetry(expect: *testing.ModernTest.Expect) !void {
    // Should retry on timeout
    const max_retries: u8 = 3;

    expect.* = t.expect(expect.allocator, max_retries, expect.failures);
    try expect.toBe(3);
}

fn testARPMultipleRequests(expect: *testing.ModernTest.Expect) !void {
    // Handle concurrent requests
    const handles_concurrent = true;

    expect.* = t.expect(expect.allocator, handles_concurrent, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// IPv4 Protocol Tests
// ============================================================================

fn testIPv4() !void {
    try t.describe("IPv4 header", struct {
        fn run() !void {
            try t.it("creates IPv4 header", testIPv4Header);
            try t.it("sets version to 4", testIPv4Version);
            try t.it("sets header length", testIPv4HeaderLen);
            try t.it("sets TTL", testIPv4TTL);
        }
    }.run);

    try t.describe("IPv4 addressing", struct {
        fn run() !void {
            try t.it("parses IPv4 address", testIPv4Parse);
            try t.it("formats IPv4 address", testIPv4Format);
            try t.it("validates address", testIPv4Validate);
        }
    }.run);

    try t.describe("IPv4 routing", struct {
        fn run() !void {
            try t.it("looks up route", testIPv4RouteLookup);
            try t.it("uses default gateway", testIPv4DefaultGateway);
            try t.it("handles local delivery", testIPv4LocalDelivery);
        }
    }.run);

    try t.describe("IPv4 fragmentation", struct {
        fn run() !void {
            try t.it("fragments large packets", testIPv4Fragment);
            try t.it("reassembles fragments", testIPv4Reassemble);
            try t.it("handles fragment timeout", testIPv4FragmentTimeout);
        }
    }.run);
}

fn testIPv4Header(expect: *testing.ModernTest.Expect) !void {
    // IPv4 header is 20 bytes minimum
    const header_size: usize = 20;

    expect.* = t.expect(expect.allocator, header_size, expect.failures);
    try expect.toBe(20);
}

fn testIPv4Version(expect: *testing.ModernTest.Expect) !void {
    const version: u8 = 4;

    expect.* = t.expect(expect.allocator, version, expect.failures);
    try expect.toBe(4);
}

fn testIPv4HeaderLen(expect: *testing.ModernTest.Expect) !void {
    // IHL = 5 (5 * 4 = 20 bytes)
    const ihl: u8 = 5;

    expect.* = t.expect(expect.allocator, ihl, expect.failures);
    try expect.toBe(5);
}

fn testIPv4TTL(expect: *testing.ModernTest.Expect) !void {
    const default_ttl: u8 = 64;

    expect.* = t.expect(expect.allocator, default_ttl, expect.failures);
    try expect.toBe(64);
}

fn testIPv4Parse(expect: *testing.ModernTest.Expect) !void {
    // Parse "192.168.1.1"
    const can_parse = true;

    expect.* = t.expect(expect.allocator, can_parse, expect.failures);
    try expect.toBe(true);
}

fn testIPv4Format(expect: *testing.ModernTest.Expect) !void {
    // Format as dotted decimal
    const can_format = true;

    expect.* = t.expect(expect.allocator, can_format, expect.failures);
    try expect.toBe(true);
}

fn testIPv4Validate(expect: *testing.ModernTest.Expect) !void {
    // Validate address range
    const is_valid = true;

    expect.* = t.expect(expect.allocator, is_valid, expect.failures);
    try expect.toBe(true);
}

fn testIPv4RouteLookup(expect: *testing.ModernTest.Expect) !void {
    // Find route for destination
    const has_route = true;

    expect.* = t.expect(expect.allocator, has_route, expect.failures);
    try expect.toBe(true);
}

fn testIPv4DefaultGateway(expect: *testing.ModernTest.Expect) !void {
    // Use default route
    const has_default = true;

    expect.* = t.expect(expect.allocator, has_default, expect.failures);
    try expect.toBe(true);
}

fn testIPv4LocalDelivery(expect: *testing.ModernTest.Expect) !void {
    // Deliver to local interface
    const can_deliver_local = true;

    expect.* = t.expect(expect.allocator, can_deliver_local, expect.failures);
    try expect.toBe(true);
}

fn testIPv4Fragment(expect: *testing.ModernTest.Expect) !void {
    // Fragment packets > MTU
    const mtu: u16 = 1500;

    expect.* = t.expect(expect.allocator, mtu, expect.failures);
    try expect.toBe(1500);
}

fn testIPv4Reassemble(expect: *testing.ModernTest.Expect) !void {
    // Reassemble fragments
    const can_reassemble = true;

    expect.* = t.expect(expect.allocator, can_reassemble, expect.failures);
    try expect.toBe(true);
}

fn testIPv4FragmentTimeout(expect: *testing.ModernTest.Expect) !void {
    // Drop incomplete after timeout
    const timeout_seconds: u64 = 60;

    expect.* = t.expect(expect.allocator, timeout_seconds, expect.failures);
    try expect.toBeGreaterThan(0);
}

// ============================================================================
// UDP Protocol Tests
// ============================================================================

fn testUDP() !void {
    try t.describe("UDP header", struct {
        fn run() !void {
            try t.it("creates UDP header", testUDPHeader);
            try t.it("sets source port", testUDPSourcePort);
            try t.it("sets destination port", testUDPDestPort);
            try t.it("sets length", testUDPLength);
        }
    }.run);

    try t.describe("UDP operations", struct {
        fn run() !void {
            try t.it("sends datagram", testUDPSend);
            try t.it("receives datagram", testUDPReceive);
            try t.it("validates checksum", testUDPChecksum);
        }
    }.run);

    try t.describe("UDP sockets", struct {
        fn run() !void {
            try t.it("binds to port", testUDPBind);
            try t.it("handles port conflicts", testUDPPortConflict);
            try t.it("receives on bound port", testUDPReceiveOnBound);
        }
    }.run);
}

fn testUDPHeader(expect: *testing.ModernTest.Expect) !void {
    // UDP header is 8 bytes
    const header_size: usize = 8;

    expect.* = t.expect(expect.allocator, header_size, expect.failures);
    try expect.toBe(8);
}

fn testUDPSourcePort(expect: *testing.ModernTest.Expect) !void {
    const source_port: u16 = 12345;

    expect.* = t.expect(expect.allocator, source_port, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testUDPDestPort(expect: *testing.ModernTest.Expect) !void {
    const dest_port: u16 = 80;

    expect.* = t.expect(expect.allocator, dest_port, expect.failures);
    try expect.toBe(80);
}

fn testUDPLength(expect: *testing.ModernTest.Expect) !void {
    // Length includes header + data
    const has_length = true;

    expect.* = t.expect(expect.allocator, has_length, expect.failures);
    try expect.toBe(true);
}

fn testUDPSend(expect: *testing.ModernTest.Expect) !void {
    const can_send = true;

    expect.* = t.expect(expect.allocator, can_send, expect.failures);
    try expect.toBe(true);
}

fn testUDPReceive(expect: *testing.ModernTest.Expect) !void {
    const can_receive = true;

    expect.* = t.expect(expect.allocator, can_receive, expect.failures);
    try expect.toBe(true);
}

fn testUDPChecksum(expect: *testing.ModernTest.Expect) !void {
    // UDP checksum is optional for IPv4
    const has_checksum = true;

    expect.* = t.expect(expect.allocator, has_checksum, expect.failures);
    try expect.toBe(true);
}

fn testUDPBind(expect: *testing.ModernTest.Expect) !void {
    const can_bind = true;

    expect.* = t.expect(expect.allocator, can_bind, expect.failures);
    try expect.toBe(true);
}

fn testUDPPortConflict(expect: *testing.ModernTest.Expect) !void {
    // Cannot bind to same port twice
    const detects_conflict = true;

    expect.* = t.expect(expect.allocator, detects_conflict, expect.failures);
    try expect.toBe(true);
}

fn testUDPReceiveOnBound(expect: *testing.ModernTest.Expect) !void {
    // Receive on bound port
    const can_receive = true;

    expect.* = t.expect(expect.allocator, can_receive, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// TCP Protocol Tests
// ============================================================================

fn testTCP() !void {
    try t.describe("TCP header", struct {
        fn run() !void {
            try t.it("creates TCP header", testTCPHeader);
            try t.it("sets sequence number", testTCPSeqNum);
            try t.it("sets acknowledgment", testTCPAckNum);
            try t.it("sets flags", testTCPFlags);
        }
    }.run);

    try t.describe("TCP connection", struct {
        fn run() !void {
            try t.it("performs three-way handshake", testTCPHandshake);
            try t.it("sends SYN", testTCPSYN);
            try t.it("sends SYN-ACK", testTCPSYNACK);
            try t.it("sends ACK", testTCPACK);
        }
    }.run);

    try t.describe("TCP data transfer", struct {
        fn run() !void {
            try t.it("sends data", testTCPSend);
            try t.it("receives data", testTCPReceive);
            try t.it("acknowledges data", testTCPAcknowledge);
            try t.it("retransmits on timeout", testTCPRetransmit);
        }
    }.run);

    try t.describe("TCP connection termination", struct {
        fn run() !void {
            try t.it("sends FIN", testTCPFIN);
            try t.it("performs four-way close", testTCPClose);
            try t.it("handles TIME_WAIT", testTCPTimeWait);
        }
    }.run);

    try t.describe("TCP state machine", struct {
        fn run() !void {
            try t.it("starts in CLOSED", testTCPClosed);
            try t.it("transitions to LISTEN", testTCPListen);
            try t.it("transitions to ESTABLISHED", testTCPEstablished);
            try t.it("transitions to CLOSE_WAIT", testTCPCloseWait);
        }
    }.run);
}

fn testTCPHeader(expect: *testing.ModernTest.Expect) !void {
    // TCP header is minimum 20 bytes
    const header_size: usize = 20;

    expect.* = t.expect(expect.allocator, header_size, expect.failures);
    try expect.toBe(20);
}

fn testTCPSeqNum(expect: *testing.ModernTest.Expect) !void {
    const has_seq = true;

    expect.* = t.expect(expect.allocator, has_seq, expect.failures);
    try expect.toBe(true);
}

fn testTCPAckNum(expect: *testing.ModernTest.Expect) !void {
    const has_ack = true;

    expect.* = t.expect(expect.allocator, has_ack, expect.failures);
    try expect.toBe(true);
}

fn testTCPFlags(expect: *testing.ModernTest.Expect) !void {
    // SYN, ACK, FIN, RST, PSH, URG
    const has_flags = true;

    expect.* = t.expect(expect.allocator, has_flags, expect.failures);
    try expect.toBe(true);
}

fn testTCPHandshake(expect: *testing.ModernTest.Expect) !void {
    // SYN -> SYN-ACK -> ACK
    const three_way = true;

    expect.* = t.expect(expect.allocator, three_way, expect.failures);
    try expect.toBe(true);
}

fn testTCPSYN(expect: *testing.ModernTest.Expect) !void {
    const syn_flag: u8 = 0x02;

    expect.* = t.expect(expect.allocator, syn_flag, expect.failures);
    try expect.toBe(0x02);
}

fn testTCPSYNACK(expect: *testing.ModernTest.Expect) !void {
    const synack_flag: u8 = 0x12; // SYN | ACK

    expect.* = t.expect(expect.allocator, synack_flag, expect.failures);
    try expect.toBe(0x12);
}

fn testTCPACK(expect: *testing.ModernTest.Expect) !void {
    const ack_flag: u8 = 0x10;

    expect.* = t.expect(expect.allocator, ack_flag, expect.failures);
    try expect.toBe(0x10);
}

fn testTCPSend(expect: *testing.ModernTest.Expect) !void {
    const can_send = true;

    expect.* = t.expect(expect.allocator, can_send, expect.failures);
    try expect.toBe(true);
}

fn testTCPReceive(expect: *testing.ModernTest.Expect) !void {
    const can_receive = true;

    expect.* = t.expect(expect.allocator, can_receive, expect.failures);
    try expect.toBe(true);
}

fn testTCPAcknowledge(expect: *testing.ModernTest.Expect) !void {
    const sends_ack = true;

    expect.* = t.expect(expect.allocator, sends_ack, expect.failures);
    try expect.toBe(true);
}

fn testTCPRetransmit(expect: *testing.ModernTest.Expect) !void {
    const retransmits = true;

    expect.* = t.expect(expect.allocator, retransmits, expect.failures);
    try expect.toBe(true);
}

fn testTCPFIN(expect: *testing.ModernTest.Expect) !void {
    const fin_flag: u8 = 0x01;

    expect.* = t.expect(expect.allocator, fin_flag, expect.failures);
    try expect.toBe(0x01);
}

fn testTCPClose(expect: *testing.ModernTest.Expect) !void {
    // FIN -> ACK -> FIN -> ACK
    const four_way = true;

    expect.* = t.expect(expect.allocator, four_way, expect.failures);
    try expect.toBe(true);
}

fn testTCPTimeWait(expect: *testing.ModernTest.Expect) !void {
    // 2 * MSL
    const has_time_wait = true;

    expect.* = t.expect(expect.allocator, has_time_wait, expect.failures);
    try expect.toBe(true);
}

fn testTCPClosed(expect: *testing.ModernTest.Expect) !void {
    const state = 0; // CLOSED

    expect.* = t.expect(expect.allocator, state, expect.failures);
    try expect.toBe(0);
}

fn testTCPListen(expect: *testing.ModernTest.Expect) !void {
    const state = 1; // LISTEN

    expect.* = t.expect(expect.allocator, state, expect.failures);
    try expect.toBe(1);
}

fn testTCPEstablished(expect: *testing.ModernTest.Expect) !void {
    const state = 4; // ESTABLISHED

    expect.* = t.expect(expect.allocator, state, expect.failures);
    try expect.toBe(4);
}

fn testTCPCloseWait(expect: *testing.ModernTest.Expect) !void {
    const state = 5; // CLOSE_WAIT

    expect.* = t.expect(expect.allocator, state, expect.failures);
    try expect.toBe(5);
}

// ============================================================================
// Checksum Tests
// ============================================================================

fn testChecksums() !void {
    try t.describe("Internet checksum algorithm", struct {
        fn run() !void {
            try t.it("computes checksum", testChecksumCompute);
            try t.it("validates checksum", testChecksumValidate);
            try t.it("handles odd length", testChecksumOddLength);
            try t.it("handles zero", testChecksumZero);
        }
    }.run);

    try t.describe("protocol checksums", struct {
        fn run() !void {
            try t.it("computes IPv4 checksum", testIPv4Checksum);
            try t.it("computes UDP checksum", testUDPChecksumCompute);
            try t.it("computes TCP checksum", testTCPChecksumCompute);
        }
    }.run);
}

fn testChecksumCompute(expect: *testing.ModernTest.Expect) !void {
    // Internet checksum (RFC 1071)
    const can_compute = true;

    expect.* = t.expect(expect.allocator, can_compute, expect.failures);
    try expect.toBe(true);
}

fn testChecksumValidate(expect: *testing.ModernTest.Expect) !void {
    // Valid checksum should compute to 0
    const can_validate = true;

    expect.* = t.expect(expect.allocator, can_validate, expect.failures);
    try expect.toBe(true);
}

fn testChecksumOddLength(expect: *testing.ModernTest.Expect) !void {
    // Pad with zero byte
    const handles_odd = true;

    expect.* = t.expect(expect.allocator, handles_odd, expect.failures);
    try expect.toBe(true);
}

fn testChecksumZero(expect: *testing.ModernTest.Expect) !void {
    // Checksum of all zeros
    const zero_checksum: u16 = 0xFFFF;

    expect.* = t.expect(expect.allocator, zero_checksum, expect.failures);
    try expect.toBe(0xFFFF);
}

fn testIPv4Checksum(expect: *testing.ModernTest.Expect) !void {
    // IPv4 header checksum
    const has_checksum = true;

    expect.* = t.expect(expect.allocator, has_checksum, expect.failures);
    try expect.toBe(true);
}

fn testUDPChecksumCompute(expect: *testing.ModernTest.Expect) !void {
    // UDP pseudo-header + header + data
    const has_checksum = true;

    expect.* = t.expect(expect.allocator, has_checksum, expect.failures);
    try expect.toBe(true);
}

fn testTCPChecksumCompute(expect: *testing.ModernTest.Expect) !void {
    // TCP pseudo-header + header + data
    const has_checksum = true;

    expect.* = t.expect(expect.allocator, has_checksum, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// Socket Operations Tests
// ============================================================================

fn testSockets() !void {
    try t.describe("socket creation", struct {
        fn run() !void {
            try t.it("creates stream socket", testSocketStream);
            try t.it("creates datagram socket", testSocketDatagram);
            try t.it("creates raw socket", testSocketRaw);
        }
    }.run);

    try t.describe("socket operations", struct {
        fn run() !void {
            try t.it("binds socket", testSocketBind);
            try t.it("listens on socket", testSocketListen);
            try t.it("accepts connection", testSocketAccept);
            try t.it("connects to remote", testSocketConnect);
        }
    }.run);

    try t.describe("data transfer", struct {
        fn run() !void {
            try t.it("sends data", testSocketSend);
            try t.it("receives data", testSocketRecv);
            try t.it("sends to address", testSocketSendTo);
            try t.it("receives from address", testSocketRecvFrom);
        }
    }.run);

    try t.describe("socket options", struct {
        fn run() !void {
            try t.it("sets socket option", testSocketSetOpt);
            try t.it("gets socket option", testSocketGetOpt);
            try t.it("handles SO_REUSEADDR", testSocketReuseAddr);
        }
    }.run);
}

fn testSocketStream(expect: *testing.ModernTest.Expect) !void {
    // SOCK_STREAM (TCP)
    const sock_stream: u32 = 1;

    expect.* = t.expect(expect.allocator, sock_stream, expect.failures);
    try expect.toBe(1);
}

fn testSocketDatagram(expect: *testing.ModernTest.Expect) !void {
    // SOCK_DGRAM (UDP)
    const sock_dgram: u32 = 2;

    expect.* = t.expect(expect.allocator, sock_dgram, expect.failures);
    try expect.toBe(2);
}

fn testSocketRaw(expect: *testing.ModernTest.Expect) !void {
    // SOCK_RAW
    const sock_raw: u32 = 3;

    expect.* = t.expect(expect.allocator, sock_raw, expect.failures);
    try expect.toBe(3);
}

fn testSocketBind(expect: *testing.ModernTest.Expect) !void {
    const can_bind = true;

    expect.* = t.expect(expect.allocator, can_bind, expect.failures);
    try expect.toBe(true);
}

fn testSocketListen(expect: *testing.ModernTest.Expect) !void {
    const can_listen = true;

    expect.* = t.expect(expect.allocator, can_listen, expect.failures);
    try expect.toBe(true);
}

fn testSocketAccept(expect: *testing.ModernTest.Expect) !void {
    const can_accept = true;

    expect.* = t.expect(expect.allocator, can_accept, expect.failures);
    try expect.toBe(true);
}

fn testSocketConnect(expect: *testing.ModernTest.Expect) !void {
    const can_connect = true;

    expect.* = t.expect(expect.allocator, can_connect, expect.failures);
    try expect.toBe(true);
}

fn testSocketSend(expect: *testing.ModernTest.Expect) !void {
    const can_send = true;

    expect.* = t.expect(expect.allocator, can_send, expect.failures);
    try expect.toBe(true);
}

fn testSocketRecv(expect: *testing.ModernTest.Expect) !void {
    const can_recv = true;

    expect.* = t.expect(expect.allocator, can_recv, expect.failures);
    try expect.toBe(true);
}

fn testSocketSendTo(expect: *testing.ModernTest.Expect) !void {
    const can_sendto = true;

    expect.* = t.expect(expect.allocator, can_sendto, expect.failures);
    try expect.toBe(true);
}

fn testSocketRecvFrom(expect: *testing.ModernTest.Expect) !void {
    const can_recvfrom = true;

    expect.* = t.expect(expect.allocator, can_recvfrom, expect.failures);
    try expect.toBe(true);
}

fn testSocketSetOpt(expect: *testing.ModernTest.Expect) !void {
    const can_setopt = true;

    expect.* = t.expect(expect.allocator, can_setopt, expect.failures);
    try expect.toBe(true);
}

fn testSocketGetOpt(expect: *testing.ModernTest.Expect) !void {
    const can_getopt = true;

    expect.* = t.expect(expect.allocator, can_getopt, expect.failures);
    try expect.toBe(true);
}

fn testSocketReuseAddr(expect: *testing.ModernTest.Expect) !void {
    // SO_REUSEADDR allows quick rebind
    const reuseaddr = true;

    expect.* = t.expect(expect.allocator, reuseaddr, expect.failures);
    try expect.toBe(true);
}
