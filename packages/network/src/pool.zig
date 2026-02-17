const std = @import("std");
const network = @import("network.zig");
const dns = @import("dns.zig");

/// Simple spinlock mutex (SpinMutex removed in Zig 0.16)
const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,
    pub fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};
const TcpStream = network.TcpStream;
const Address = network.Address;
const Allocator = std.mem.Allocator;

/// Connection pool for reusing TCP connections
/// Reduces connection overhead for frequently-accessed hosts
pub const ConnectionPool = struct {
    allocator: Allocator,
    connections: std.StringHashMap(std.ArrayList(PooledConnection)),
    config: Config,
    resolver: dns.DnsResolver,
    mutex: SpinMutex,

    pub const Config = struct {
        max_connections_per_host: usize = 10,
        max_idle_time_ms: u64 = 60_000, // 60 seconds
        connection_timeout_ms: u64 = 5_000, // 5 seconds
        enable_keepalive: bool = true,
    };

    pub const PooledConnection = struct {
        stream: TcpStream,
        address: Address,
        created_at: i64,
        last_used: i64,
        in_use: bool = false,

        pub fn isExpired(self: PooledConnection, max_idle_ms: u64) bool {
            const now = std.time.milliTimestamp();
            const idle_time = @as(u64, @intCast(now - self.last_used));
            return !self.in_use and idle_time > max_idle_ms;
        }
    };

    pub fn init(allocator: Allocator, config: Config) ConnectionPool {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(std.ArrayList(PooledConnection)).init(allocator),
            .config = config,
            .resolver = dns.DnsResolver.init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |*conn| {
                conn.stream.close();
            }
            entry.value_ptr.deinit();
        }
        self.connections.deinit();
    }

    /// Get a connection from the pool or create a new one
    pub fn get(self: *ConnectionPool, host: []const u8, port: u16) !TcpStream {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up expired connections first
        try self.cleanupExpired();

        // Try to reuse existing connection
        if (self.connections.get(host)) |pool| {
            for (pool.items) |*conn| {
                if (!conn.in_use and !conn.isExpired(self.config.max_idle_time_ms)) {
                    conn.in_use = true;
                    conn.last_used = std.time.milliTimestamp();
                    return conn.stream;
                }
            }
        }

        // No available connection, create new one
        return try self.createConnection(host, port);
    }

    /// Return a connection to the pool
    pub fn release(self: *ConnectionPool, host: []const u8, stream: TcpStream) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections.getPtr(host)) |pool| {
            for (pool.items) |*conn| {
                if (conn.stream.socket == stream.socket) {
                    conn.in_use = false;
                    conn.last_used = std.time.milliTimestamp();
                    return;
                }
            }
        }

        // Connection not found in pool, just close it
        var mutable_stream = stream;
        mutable_stream.close();
    }

    /// Create a new connection and add it to the pool
    fn createConnection(self: *ConnectionPool, host: []const u8, port: u16) !TcpStream {
        // Check if we've reached the limit for this host
        if (self.connections.get(host)) |pool| {
            if (pool.items.len >= self.config.max_connections_per_host) {
                return error.PoolLimitReached;
            }
        }

        // Resolve hostname and connect
        const stream = try self.resolver.lookupAndConnect(host, port);

        // Get the remote address
        const address = try stream.remoteAddress();

        // Add to pool
        var pool_entry = try self.connections.getOrPut(host);
        if (!pool_entry.found_existing) {
            pool_entry.key_ptr.* = try self.allocator.dupe(u8, host);
            pool_entry.value_ptr.* = std.ArrayList(PooledConnection).init(self.allocator);
        }

        const now = std.time.milliTimestamp();
        try pool_entry.value_ptr.append(.{
            .stream = stream,
            .address = address,
            .created_at = now,
            .last_used = now,
            .in_use = true,
        });

        return stream;
    }

    /// Clean up expired connections
    fn cleanupExpired(self: *ConnectionPool) !void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                if (entry.value_ptr.items[i].isExpired(self.config.max_idle_time_ms)) {
                    var conn = entry.value_ptr.orderedRemove(i);
                    conn.stream.close();
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Close all connections for a specific host
    pub fn closeHost(self: *ConnectionPool, host: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections.fetchRemove(host)) |entry| {
            self.allocator.free(entry.key);
            for (entry.value.items) |*conn| {
                conn.stream.close();
            }
            entry.value.deinit();
        }
    }

    /// Get pool statistics
    pub fn getStats(self: *ConnectionPool) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total_connections: usize = 0;
        var active_connections: usize = 0;
        var idle_connections: usize = 0;

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            total_connections += entry.value_ptr.items.len;
            for (entry.value_ptr.items) |conn| {
                if (conn.in_use) {
                    active_connections += 1;
                } else {
                    idle_connections += 1;
                }
            }
        }

        return .{
            .total_hosts = self.connections.count(),
            .total_connections = total_connections,
            .active_connections = active_connections,
            .idle_connections = idle_connections,
        };
    }

    pub const Stats = struct {
        total_hosts: usize,
        total_connections: usize,
        active_connections: usize,
        idle_connections: usize,
    };
};

/// Managed connection that automatically returns to pool on deinit
pub const ManagedConnection = struct {
    pool: *ConnectionPool,
    host: []const u8,
    stream: ?TcpStream,

    pub fn init(pool: *ConnectionPool, host: []const u8, port: u16) !ManagedConnection {
        const stream = try pool.get(host, port);
        return .{
            .pool = pool,
            .host = host,
            .stream = stream,
        };
    }

    pub fn getStream(self: *ManagedConnection) !*TcpStream {
        if (self.stream) |*s| {
            return s;
        }
        return error.ConnectionClosed;
    }

    pub fn deinit(self: *ManagedConnection) void {
        if (self.stream) |stream| {
            self.pool.release(self.host, stream) catch {
                // If release fails, close the connection
                var mutable_stream = stream;
                mutable_stream.close();
            };
            self.stream = null;
        }
    }
};

test "ConnectionPool - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = ConnectionPool.init(allocator, .{});
    defer pool.deinit();

    const stats = pool.getStats();
    try testing.expectEqual(@as(usize, 0), stats.total_connections);
}
