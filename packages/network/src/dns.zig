const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const network = @import("network.zig");
const Address = network.Address;
const Allocator = std.mem.Allocator;

/// DNS resolver for hostname lookups
pub const DnsResolver = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) DnsResolver {
        return .{ .allocator = allocator };
    }

    /// Lookup hostname and return all addresses (A and AAAA records)
    pub fn lookup(self: *DnsResolver, hostname: []const u8) ![]Address {
        if (comptime native_os == .linux) {
            // DNS resolution requires libc on Linux
            return error.DnsLookupFailed;
        } else {
            // Use libc getaddrinfo for DNS resolution
            var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
            hints.family = std.c.AF.UNSPEC; // Allow both IPv4 and IPv6
            hints.socktype = std.c.SOCK.STREAM;

            var result: ?*std.c.addrinfo = null;
            const ret = std.c.getaddrinfo(
                hostname.ptr,
                null,
                &hints,
                &result,
            );

            if (ret != 0) {
                return error.DnsLookupFailed;
            }

            defer if (result) |res| std.c.freeaddrinfo(res);

            // Count results
            var count: usize = 0;
            var current = result;
            while (current) |node| : (current = node.next) {
                count += 1;
            }

            if (count == 0) {
                return error.NoAddressFound;
            }

            // Allocate and populate addresses
            var addresses = try self.allocator.alloc(Address, count);
            var i: usize = 0;

            current = result;
            while (current) |node| : (current = node.next) {
                const addr = node.addr orelse continue;

                addresses[i] = switch (addr.family) {
                    std.c.AF.INET => blk: {
                        const addr_in = @as(*const std.c.sockaddr.in, @ptrCast(@alignCast(addr)));
                        var ip: [4]u8 = undefined;
                        @memcpy(&ip, &addr_in.addr);
                        break :blk Address.initIp4(ip, 0);
                    },
                    std.c.AF.INET6 => blk: {
                        const addr_in6 = @as(*const std.c.sockaddr.in6, @ptrCast(@alignCast(addr)));
                        var ip: [16]u8 = undefined;
                        @memcpy(&ip, &addr_in6.addr);
                        break :blk Address.initIp6(ip, 0);
                    },
                    else => continue,
                };

                i += 1;
            }

            return addresses[0..i];
        }
    }

    /// Lookup and return only IPv4 addresses (A records)
    pub fn lookupIpv4(self: *DnsResolver, hostname: []const u8) ![]Address {
        if (comptime native_os == .linux) {
            _ = self;
            _ = hostname;
            return error.DnsLookupFailed;
        } else {
            var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
            hints.family = std.c.AF.INET; // IPv4 only
            hints.socktype = std.c.SOCK.STREAM;

            var result: ?*std.c.addrinfo = null;
            const ret = std.c.getaddrinfo(
                hostname.ptr,
                null,
                &hints,
                &result,
            );

            if (ret != 0) {
                return error.DnsLookupFailed;
            }

            defer if (result) |res| std.c.freeaddrinfo(res);

            var addresses = std.ArrayList(Address).init(self.allocator);
            var current = result;
            while (current) |node| : (current = node.next) {
                const addr = node.addr orelse continue;
                if (addr.family != std.c.AF.INET) continue;

                const addr_in = @as(*const std.c.sockaddr.in, @ptrCast(@alignCast(addr)));
                var ip: [4]u8 = undefined;
                @memcpy(&ip, &addr_in.addr);
                try addresses.append(Address.initIp4(ip, 0));
            }

            return addresses.toOwnedSlice();
        }
    }

    /// Lookup and return only IPv6 addresses (AAAA records)
    pub fn lookupIpv6(self: *DnsResolver, hostname: []const u8) ![]Address {
        if (comptime native_os == .linux) {
            _ = self;
            _ = hostname;
            return error.DnsLookupFailed;
        } else {
            var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
            hints.family = std.c.AF.INET6; // IPv6 only
            hints.socktype = std.c.SOCK.STREAM;

            var result: ?*std.c.addrinfo = null;
            const ret = std.c.getaddrinfo(
                hostname.ptr,
                null,
                &hints,
                &result,
            );

            if (ret != 0) {
                return error.DnsLookupFailed;
            }

            defer if (result) |res| std.c.freeaddrinfo(res);

            var addresses = std.ArrayList(Address).init(self.allocator);
            var current = result;
            while (current) |node| : (current = node.next) {
                const addr = node.addr orelse continue;
                if (addr.family != std.c.AF.INET6) continue;

                const addr_in6 = @as(*const std.c.sockaddr.in6, @ptrCast(@alignCast(addr)));
                var ip: [16]u8 = undefined;
                @memcpy(&ip, &addr_in6.addr);
                try addresses.append(Address.initIp6(ip, 0));
            }

            return addresses.toOwnedSlice();
        }
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

            const stream = network.TcpStream.connect(addr_with_port) catch |err| {
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
            var hostname_buf: [1024]u8 = undefined;

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
        return .{
            .allocator = allocator,
            .resolver = DnsResolver.init(allocator),
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

    var resolver = DnsResolver.init(allocator);
    const addresses = try resolver.lookup("localhost");
    defer allocator.free(addresses);

    try testing.expect(addresses.len > 0);
}
