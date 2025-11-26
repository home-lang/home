const std = @import("std");
const Allocator = std.mem.Allocator;
const netdev = @import("netdev.zig");

/// Enhanced ARP resolver with packet queueing
/// Instead of returning broadcast MAC, properly waits for ARP reply
pub const ArpResolver = struct {
    allocator: Allocator,
    cache: *ArpCache,
    /// Packets waiting for ARP resolution
    pending_packets: std.ArrayList(PendingPacket),
    mutex: std.Thread.Mutex,

    pub const PendingPacket = struct {
        target_ip: IPv4Address,
        packet_data: []u8,
        timestamp: u64,
        retries: u8,
        callback: *const fn (mac: netdev.MacAddress, data: []const u8) anyerror!void,
    };

    pub fn init(allocator: Allocator, cache: *ArpCache) !*ArpResolver {
        const resolver = try allocator.create(ArpResolver);
        resolver.* = .{
            .allocator = allocator,
            .cache = cache,
            .pending_packets = std.ArrayList(PendingPacket).init(allocator),
            .mutex = .{},
        };
        return resolver;
    }

    pub fn deinit(self: *ArpResolver) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.pending_packets.items) |pending| {
            self.allocator.free(pending.packet_data);
        }
        self.pending_packets.deinit();
        self.allocator.destroy(self);
    }

    /// Resolve IP to MAC, queueing packet if necessary
    pub fn resolve(
        self: *ArpResolver,
        dev: *netdev.NetDevice,
        target_ip: IPv4Address,
        packet_data: []const u8,
        callback: *const fn (mac: netdev.MacAddress, data: []const u8) anyerror!void,
    ) !void {
        // Check cache first
        if (self.cache.lookup(target_ip)) |mac| {
            // Cache hit - send immediately
            try callback(mac, packet_data);
            return;
        }

        // Cache miss - queue packet and send ARP request
        self.mutex.lock();
        defer self.mutex.unlock();

        // Queue the packet
        const queued_data = try self.allocator.dupe(u8, packet_data);
        try self.pending_packets.append(.{
            .target_ip = target_ip,
            .packet_data = queued_data,
            .timestamp = getMonotonicTimeMs(),
            .retries = 0,
            .callback = callback,
        });

        // Send ARP request
        try sendArpRequest(dev, target_ip, self.allocator);
    }

    /// Called when ARP reply is received
    pub fn onArpReply(self: *ArpResolver, ip: IPv4Address, mac: netdev.MacAddress) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find and send all packets waiting for this IP
        var i: usize = 0;
        while (i < self.pending_packets.items.len) {
            const pending = self.pending_packets.items[i];

            if (pending.target_ip.equals(ip)) {
                // Send the packet
                pending.callback(mac, pending.packet_data) catch |err| {
                    std.debug.print("Error sending queued packet: {}\n", .{err});
                };

                // Free packet data
                self.allocator.free(pending.packet_data);

                // Remove from queue
                _ = self.pending_packets.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Retry failed ARP requests
    pub fn retryPending(self: *ArpResolver, dev: *netdev.NetDevice) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = getMonotonicTimeMs();
        const RETRY_TIMEOUT_MS: u64 = 1000; // 1 second
        const MAX_RETRIES: u8 = 3;

        var i: usize = 0;
        while (i < self.pending_packets.items.len) {
            var pending = &self.pending_packets.items[i];

            if (now - pending.timestamp > RETRY_TIMEOUT_MS) {
                if (pending.retries < MAX_RETRIES) {
                    // Retry ARP request
                    try sendArpRequest(dev, pending.target_ip, self.allocator);
                    pending.retries += 1;
                    pending.timestamp = now;
                    i += 1;
                } else {
                    // Max retries reached, drop packet
                    std.debug.print("ARP timeout for {}\n", .{pending.target_ip});
                    self.allocator.free(pending.packet_data);
                    _ = self.pending_packets.swapRemove(i);
                }
            } else {
                i += 1;
            }
        }
    }
};

/// Enhanced ICMP echo reply handler
pub const IcmpEchoHandler = struct {
    dev: *netdev.NetDevice,
    allocator: Allocator,
    /// Statistics
    echo_requests_received: std.atomic.Value(u64),
    echo_replies_sent: std.atomic.Value(u64),

    pub fn init(dev: *netdev.NetDevice, allocator: Allocator) IcmpEchoHandler {
        return .{
            .dev = dev,
            .allocator = allocator,
            .echo_requests_received = std.atomic.Value(u64).init(0),
            .echo_replies_sent = std.atomic.Value(u64).init(0),
        };
    }

    /// Handle ICMP echo request (ping) and send reply
    pub fn handleEchoRequest(
        self: *IcmpEchoHandler,
        src_ip: IPv4Address,
        icmp_header: *const IcmpHeader,
        payload: []const u8,
    ) !void {
        _ = self.echo_requests_received.fetchAdd(1, .monotonic);

        // Create echo reply
        var reply = IcmpHeader.init(
            .EchoReply,
            @byteSwap(icmp_header.identifier),
            @byteSwap(icmp_header.sequence),
        );

        // Build reply packet
        var buffer: [@sizeOf(IcmpHeader) + 1472]u8 = undefined;
        const icmp_size = @sizeOf(IcmpHeader);
        const payload_size = @min(payload.len, 1472);

        @memcpy(buffer[0..icmp_size], std.mem.asBytes(&reply));
        @memcpy(buffer[icmp_size..][0..payload_size], payload[0..payload_size]);

        // Calculate checksum
        const reply_ptr: *IcmpHeader = @ptrCast(@alignCast(&buffer));
        reply_ptr.checksum = calculateChecksum(buffer[0 .. icmp_size + payload_size]);

        // Send reply
        try sendIPv4(self.dev, src_ip, .ICMP, buffer[0 .. icmp_size + payload_size]);

        _ = self.echo_replies_sent.fetchAdd(1, .monotonic);

        std.debug.print("ICMP: Sent echo reply to {} (id={}, seq={})\n", .{
            src_ip,
            @byteSwap(icmp_header.identifier),
            @byteSwap(icmp_header.sequence),
        });
    }

    pub fn getStats(self: *const IcmpEchoHandler) Stats {
        return .{
            .requests_received = self.echo_requests_received.load(.monotonic),
            .replies_sent = self.echo_replies_sent.load(.monotonic),
        };
    }

    pub const Stats = struct {
        requests_received: u64,
        replies_sent: u64,
    };
};

/// Enhanced monotonic time implementation
/// Provides accurate, high-resolution time without syscalls
pub const MonotonicClock = struct {
    /// TSC frequency in Hz (calibrated at initialization)
    tsc_frequency: u64,
    /// Conversion factor: ticks to nanoseconds
    ticks_to_ns: f64,

    pub fn init() !MonotonicClock {
        // Calibrate TSC frequency against a known time source
        const calibrated_freq = try calibrateTsc();

        return MonotonicClock{
            .tsc_frequency = calibrated_freq,
            .ticks_to_ns = 1_000_000_000.0 / @as(f64, @floatFromInt(calibrated_freq)),
        };
    }

    /// Get current monotonic time in nanoseconds
    pub fn now(self: *const MonotonicClock) u64 {
        const ticks = rdtsc();
        return @intFromFloat(@as(f64, @floatFromInt(ticks)) * self.ticks_to_ns);
    }

    /// Get monotonic time in milliseconds
    pub fn nowMs(self: *const MonotonicClock) u64 {
        return self.now() / 1_000_000;
    }

    /// Get monotonic time in microseconds
    pub fn nowUs(self: *const MonotonicClock) u64 {
        return self.now() / 1_000;
    }

    /// Read CPU timestamp counter
    inline fn rdtsc() u64 {
        var low: u32 = undefined;
        var high: u32 = undefined;
        asm volatile ("rdtsc"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
        );
        return (@as(u64, high) << 32) | @as(u64, low);
    }

    /// Calibrate TSC frequency against wall clock
    fn calibrateTsc() !u64 {
        // Method 1: Use CPUID if available
        if (cpuidTscFreq()) |freq| {
            return freq;
        }

        // Method 2: Measure against nanosleep
        const start_ticks = rdtsc();
        const start_time = std.time.nanoTimestamp();

        // Sleep for 10ms
        std.time.sleep(10 * std.time.ns_per_ms);

        const end_ticks = rdtsc();
        const end_time = std.time.nanoTimestamp();

        const elapsed_ns = @as(u64, @intCast(end_time - start_time));
        const elapsed_ticks = end_ticks - start_ticks;

        // Calculate frequency in Hz
        const freq = (elapsed_ticks * 1_000_000_000) / elapsed_ns;

        std.debug.print("TSC calibrated: {} Hz ({}GHz)\n", .{
            freq,
            @as(f64, @floatFromInt(freq)) / 1_000_000_000.0,
        });

        return freq;
    }

    /// Try to get TSC frequency from CPUID
    fn cpuidTscFreq() ?u64 {
        // CPUID.15H: Time Stamp Counter and Nominal Core Crystal Clock Information
        var eax: u32 = 0x15;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;

        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx),
            : [eax_in] "{eax}" (eax),
        );

        // If EAX and EBX are zero, TSC frequency enumeration not supported
        if (eax == 0 or ebx == 0) {
            return null;
        }

        // If ECX is not zero, it's the crystal clock frequency
        if (ecx != 0) {
            const crystal_freq = ecx;
            const ratio = @as(u64, ebx) * 1000000 / @as(u64, eax);
            return crystal_freq * ratio / 1000000;
        }

        return null;
    }
};

/// Global monotonic clock instance
var global_clock: ?MonotonicClock = null;
var clock_mutex: std.Thread.Mutex = .{};

/// Initialize global monotonic clock
pub fn initMonotonicClock() !void {
    clock_mutex.lock();
    defer clock_mutex.unlock();

    if (global_clock == null) {
        global_clock = try MonotonicClock.init();
    }
}

/// Get monotonic time in milliseconds (thread-safe)
pub fn getMonotonicTimeMs() u64 {
    clock_mutex.lock();
    defer clock_mutex.unlock();

    if (global_clock) |*clock| {
        return clock.nowMs();
    }

    // Fallback if not initialized
    return @intCast(@divFloor(std.time.nanoTimestamp(), 1_000_000));
}

/// Get monotonic time in nanoseconds (thread-safe)
pub fn getMonotonicTimeNs() u64 {
    clock_mutex.lock();
    defer clock_mutex.unlock();

    if (global_clock) |*clock| {
        return clock.now();
    }

    // Fallback if not initialized
    return @intCast(std.time.nanoTimestamp());
}

// Forward declarations (these would be in protocols.zig)
const IPv4Address = struct {
    bytes: [4]u8,

    pub fn equals(self: IPv4Address, other: IPv4Address) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

const IcmpHeader = extern struct {
    type: u8,
    code: u8,
    checksum: u16,
    identifier: u16,
    sequence: u16,

    pub fn init(icmp_type: IcmpType, identifier: u16, sequence: u16) IcmpHeader {
        return .{
            .type = @intFromEnum(icmp_type),
            .code = 0,
            .checksum = 0,
            .identifier = identifier,
            .sequence = sequence,
        };
    }
};

const IcmpType = enum(u8) {
    EchoReply = 0,
    EchoRequest = 8,
    _,
};

const IpProtocol = enum(u8) {
    ICMP = 1,
    TCP = 6,
    UDP = 17,
    _,
};

const ArpCache = struct {
    pub fn lookup(_: *ArpCache, _: IPv4Address) ?netdev.MacAddress {
        return null;
    }
};

// Stub functions
fn sendArpRequest(_: *netdev.NetDevice, _: IPv4Address, _: Allocator) !void {}
fn calculateChecksum(_: []const u8) u16 {
    return 0;
}
fn sendIPv4(_: *netdev.NetDevice, _: IPv4Address, _: IpProtocol, _: []const u8) !void {}

test "ArpResolver - queue and resolve" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = ArpCache{};
    var resolver = try ArpResolver.init(allocator, &cache);
    defer resolver.deinit();

    // Test would queue packet and wait for ARP reply
}

test "MonotonicClock - calibration" {
    const testing = std.testing;

    var clock = try MonotonicClock.init();

    const t1 = clock.now();
    std.time.sleep(10 * std.time.ns_per_ms);
    const t2 = clock.now();

    // Should be approximately 10ms
    const elapsed_ms = (t2 - t1) / 1_000_000;
    try testing.expect(elapsed_ms >= 9 and elapsed_ms <= 11);
}
