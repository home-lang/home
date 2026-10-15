const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const network = @import("network.zig");
const compat = @import("compat.zig");
const net = std.Io.net;
const Address = network.Address;
const Allocator = std.mem.Allocator;

/// DNS resolver for hostname lookups
pub const DnsResolver = struct {
    allocator: Allocator,
    io: std.Io,

    pub fn init(allocator: Allocator) DnsResolver {
        return initWithIo(compat.io(), allocator);
    }

    pub fn initWithIo(io: std.Io, allocator: Allocator) DnsResolver {
        return .{ .allocator = allocator, .io = io };
    }

    /// Lookup hostname and return all addresses (A and AAAA records)
    pub fn lookup(self: *DnsResolver, hostname: []const u8) ![]Address {
        return self.lookupFamily(hostname, null);
    }

    /// Lookup and return only IPv4 addresses (A records)
    pub fn lookupIpv4(self: *DnsResolver, hostname: []const u8) ![]Address {
        return self.lookupFamily(hostname, .ip4);
    }

    /// Lookup and return only IPv6 addresses (AAAA records)
    pub fn lookupIpv6(self: *DnsResolver, hostname: []const u8) ![]Address {
        return self.lookupFamily(hostname, .ip6);
    }

    fn lookupFamily(self: *DnsResolver, hostname: []const u8, family: ?net.IpAddress.Family) ![]Address {
        const host_name = try net.HostName.init(hostname);
        var results_buffer: [16]net.HostName.LookupResult = undefined;
        var results: std.Io.Queue(net.HostName.LookupResult) = .init(&results_buffer);
        try host_name.lookup(self.io, &results, .{ .port = 0, .family = family });

        var addresses: std.ArrayList(Address) = .empty;
        errdefer addresses.deinit(self.allocator);
        while (results.getOneUncancelable(self.io)) |result| switch (result) {
            .address => |address| try addresses.append(self.allocator, .fromIo(address)),
            .canonical_name => {},
        } else |err| switch (err) {
            error.Closed => {},
        }

        if (addresses.items.len == 0) return error.NoAddressFound;
        return addresses.toOwnedSlice(self.allocator);
    }

    /// Lookup and connect to first available address
    pub fn lookupAndConnect(self: *DnsResolver, hostname: []const u8, port: u16) !network.TcpStream {
        const addresses = try self.lookup(hostname);
        defer self.allocator.free(addresses);

        // Try each address until one connects
        var last_error: anyerror = error.ConnectionFailed;
        for (addresses) |addr| {
            // Set port on the address
            var addr_with_port = addr;
            switch (addr_with_port) {
                .ipv4 => |*ipv4| ipv4.port = port,
                .ipv6 => |*ipv6| ipv6.port = port,
            }

            const stream = network.TcpStream.connectWithIo(self.io, addr_with_port) catch |err| {
                last_error = err;
                continue;
            };

            return stream;
        }

        return last_error;
    }

    /// Reverse DNS lookup (address to hostname)
    pub fn reverseLookup(self: *DnsResolver, address: Address) ![]const u8 {
        if (comptime native_os == .linux) {
            return error.ReverseLookupFailed;
        } else {
            var hostname_buf: [1024]u8 = @splat(0);

            const addr = address.toSockAddr();
            const addr_len = @as(std.c.socklen_t, @intCast(address.getSockAddrSize()));

            const ret = std.c.getnameinfo(
                &addr,
                addr_len,
                &hostname_buf,
                hostname_buf.len,
                null,
                0,
                0,
            );

            if (ret != 0) {
                return error.ReverseLookupFailed;
            }

            const len = std.mem.indexOfScalar(u8, &hostname_buf, 0) orelse hostname_buf.len;
            return try self.allocator.dupe(u8, hostname_buf[0..len]);
        }
    }
};

/// Async DNS resolver (basic implementation)
pub const AsyncDnsResolver = struct {
    allocator: Allocator,
    resolver: DnsResolver,

    pub fn init(allocator: Allocator) AsyncDnsResolver {
        return initWithIo(compat.io(), allocator);
    }

    pub fn initWithIo(io: std.Io, allocator: Allocator) AsyncDnsResolver {
        return .{
            .allocator = allocator,
            .resolver = DnsResolver.initWithIo(io, allocator),
        };
    }

    /// Lookup hostname asynchronously
    /// Returns immediately and resolves in background thread
    pub fn lookup(self: *AsyncDnsResolver, hostname: []const u8) !LookupTask {
        const hostname_copy = try self.allocator.dupe(u8, hostname);

        const task = LookupTask{
            .allocator = self.allocator,
            .hostname = hostname_copy,
            .resolver = &self.resolver,
            .result = null,
            .error_value = null,
            .completed = false,
        };

        return task;
    }

    pub const LookupTask = struct {
        allocator: Allocator,
        hostname: []const u8,
        resolver: *DnsResolver,
        result: ?[]Address,
        error_value: ?anyerror,
        completed: bool,

        pub fn start(self: *LookupTask) !std.Thread {
            return try std.Thread.spawn(.{}, run, .{self});
        }

        fn run(self: *LookupTask) void {
            self.result = self.resolver.lookup(self.hostname) catch |err| {
                self.error_value = err;
                self.completed = true;
                return;
            };
            self.completed = true;
        }

        pub fn isComplete(self: *const LookupTask) bool {
            return self.completed;
        }

        pub fn getResult(self: *LookupTask) ![]Address {
            if (!self.completed) {
                return error.NotComplete;
            }

            if (self.error_value) |err| {
                return err;
            }

            return self.result orelse error.NoResult;
        }

        pub fn deinit(self: *LookupTask) void {
            self.allocator.free(self.hostname);
            if (self.result) |result| {
                self.allocator.free(result);
            }
        }
    };
};

test "DNS - localhost lookup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var resolver = DnsResolver.initWithIo(std.testing.io, allocator);
    const addresses = try resolver.lookup("localhost");
    defer allocator.free(addresses);

    try testing.expect(addresses.len > 0);
}
