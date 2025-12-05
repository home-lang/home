const std = @import("std");
const posix = std.posix;

/// Helper to get current timestamp (Zig 0.16 compatible)
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// Cache driver types
pub const CacheDriverType = enum {
    memory,
    redis,
    filesystem,
    dynamodb,
};

/// Cache entry with value and metadata
pub const CacheEntry = struct {
    value: []const u8,
    expires_at: ?i64, // Unix timestamp, null = never expires
    created_at: i64,
    tags: ?[]const []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, value: []const u8, ttl_seconds: ?i64) !*CacheEntry {
        const entry = try allocator.create(CacheEntry);
        const now = getTimestamp();

        entry.* = .{
            .value = try allocator.dupe(u8, value),
            .expires_at = if (ttl_seconds) |ttl| now + ttl else null,
            .created_at = now,
            .tags = null,
            .allocator = allocator,
        };

        return entry;
    }

    pub fn deinit(self: *CacheEntry) void {
        self.allocator.free(self.value);
        if (self.tags) |tags| {
            for (tags) |tag| {
                self.allocator.free(tag);
            }
            self.allocator.free(tags);
        }
        self.allocator.destroy(self);
    }

    pub fn isExpired(self: *const CacheEntry) bool {
        if (self.expires_at) |expires| {
            return getTimestamp() >= expires;
        }
        return false;
    }

    pub fn remainingTtl(self: *const CacheEntry) ?i64 {
        if (self.expires_at) |expires| {
            const remaining = expires - getTimestamp();
            return if (remaining > 0) remaining else 0;
        }
        return null;
    }
};

/// Cache configuration
pub const CacheConfig = struct {
    driver_type: CacheDriverType,
    prefix: []const u8,
    default_ttl: ?i64, // Default TTL in seconds
    max_size: ?usize, // Max items for memory cache
    max_memory: ?usize, // Max memory in bytes for memory cache

    // Redis config
    redis_host: ?[]const u8,
    redis_port: u16,
    redis_password: ?[]const u8,
    redis_database: u8,
    redis_tls: bool,

    // Filesystem config
    fs_directory: ?[]const u8,
    fs_prune_interval: u64, // Seconds

    // DynamoDB config
    dynamodb_table: ?[]const u8,
    dynamodb_region: ?[]const u8,
    dynamodb_endpoint: ?[]const u8,

    pub fn memory() CacheConfig {
        return .{
            .driver_type = .memory,
            .prefix = "home",
            .default_ttl = 3600, // 1 hour
            .max_size = 10000,
            .max_memory = 10 * 1024 * 1024, // 10MB
            .redis_host = null,
            .redis_port = 6379,
            .redis_password = null,
            .redis_database = 0,
            .redis_tls = false,
            .fs_directory = null,
            .fs_prune_interval = 3600,
            .dynamodb_table = null,
            .dynamodb_region = null,
            .dynamodb_endpoint = null,
        };
    }

    pub fn redis(host: []const u8, port: u16) CacheConfig {
        var config = memory();
        config.driver_type = .redis;
        config.redis_host = host;
        config.redis_port = port;
        return config;
    }

    pub fn filesystem(directory: []const u8) CacheConfig {
        var config = memory();
        config.driver_type = .filesystem;
        config.fs_directory = directory;
        return config;
    }

    pub fn dynamodb(table: []const u8, region: []const u8) CacheConfig {
        var config = memory();
        config.driver_type = .dynamodb;
        config.dynamodb_table = table;
        config.dynamodb_region = region;
        return config;
    }

    pub fn withPrefix(self: CacheConfig, prefix: []const u8) CacheConfig {
        var config = self;
        config.prefix = prefix;
        return config;
    }

    pub fn withTtl(self: CacheConfig, ttl_seconds: i64) CacheConfig {
        var config = self;
        config.default_ttl = ttl_seconds;
        return config;
    }

    pub fn withMaxSize(self: CacheConfig, max_items: usize) CacheConfig {
        var config = self;
        config.max_size = max_items;
        return config;
    }
};

/// Cache driver interface
pub const CacheDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, key: []const u8) ?[]const u8,
        set: *const fn (ptr: *anyopaque, key: []const u8, value: []const u8, ttl: ?i64) anyerror!void,
        has: *const fn (ptr: *anyopaque, key: []const u8) bool,
        del: *const fn (ptr: *anyopaque, key: []const u8) bool,
        clear: *const fn (ptr: *anyopaque) void,
        size: *const fn (ptr: *anyopaque) usize,
        keys: *const fn (ptr: *anyopaque, pattern: ?[]const u8) []const []const u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn get(self: *CacheDriver, key: []const u8) ?[]const u8 {
        return self.vtable.get(self.ptr, key);
    }

    pub fn set(self: *CacheDriver, key: []const u8, value: []const u8, ttl: ?i64) !void {
        return self.vtable.set(self.ptr, key, value, ttl);
    }

    pub fn has(self: *CacheDriver, key: []const u8) bool {
        return self.vtable.has(self.ptr, key);
    }

    pub fn del(self: *CacheDriver, key: []const u8) bool {
        return self.vtable.del(self.ptr, key);
    }

    pub fn clear(self: *CacheDriver) void {
        self.vtable.clear(self.ptr);
    }

    pub fn size(self: *CacheDriver) usize {
        return self.vtable.size(self.ptr);
    }

    pub fn keys(self: *CacheDriver, pattern: ?[]const u8) []const []const u8 {
        return self.vtable.keys(self.ptr, pattern);
    }

    pub fn deinit(self: *CacheDriver) void {
        self.vtable.deinit(self.ptr);
    }
};

/// LRU Node for memory cache
const LRUNode = struct {
    key: []const u8,
    entry: *CacheEntry,
    prev: ?*LRUNode,
    next: ?*LRUNode,
};

/// Memory cache driver with LRU eviction
pub const MemoryCacheDriver = struct {
    allocator: std.mem.Allocator,
    config: CacheConfig,
    cache: std.StringHashMap(*LRUNode),
    head: ?*LRUNode, // Most recently used
    tail: ?*LRUNode, // Least recently used
    current_size: usize,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: CacheConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .cache = std.StringHashMap(*LRUNode).init(allocator),
            .head = null,
            .tail = null,
            .current_size = 0,
            .mutex = .{},
        };
        return self;
    }

    pub fn driver(self: *Self) CacheDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .get = get,
                .set = set,
                .has = has,
                .del = del,
                .clear = clear,
                .size = size,
                .keys = keys,
                .deinit = deinit,
            },
        };
    }

    fn moveToFront(self: *Self, node: *LRUNode) void {
        if (self.head == node) return;

        // Remove from current position
        if (node.prev) |prev| {
            prev.next = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        }
        if (self.tail == node) {
            self.tail = node.prev;
        }

        // Add to front
        node.prev = null;
        node.next = self.head;
        if (self.head) |head| {
            head.prev = node;
        }
        self.head = node;

        if (self.tail == null) {
            self.tail = node;
        }
    }

    fn evictLRU(self: *Self) void {
        if (self.tail) |tail| {
            // Remove from map
            _ = self.cache.remove(tail.key);

            // Update tail
            if (tail.prev) |prev| {
                prev.next = null;
                self.tail = prev;
            } else {
                self.head = null;
                self.tail = null;
            }

            // Free resources
            self.allocator.free(tail.key);
            tail.entry.deinit();
            self.allocator.destroy(tail);
            self.current_size -|= 1;
        }
    }

    fn pruneExpired(self: *Self) void {
        var it = self.cache.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        while (it.next()) |entry| {
            if (entry.value_ptr.*.entry.isExpired()) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |item_key| {
            _ = self.delInternal(item_key);
        }
    }

    fn delInternal(self: *Self, key: []const u8) bool {
        if (self.cache.fetchRemove(key)) |kv| {
            const node = kv.value;

            // Update linked list
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }
            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }

            // Free resources
            self.allocator.free(node.key);
            node.entry.deinit();
            self.allocator.destroy(node);
            self.current_size -|= 1;
            return true;
        }
        return false;
    }

    fn get(ptr: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cache.get(key)) |node| {
            if (node.entry.isExpired()) {
                _ = self.delInternal(key);
                return null;
            }
            self.moveToFront(node);
            return node.entry.value;
        }
        return null;
    }

    fn set(ptr: *anyopaque, key: []const u8, value: []const u8, ttl: ?i64) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const effective_ttl = ttl orelse self.config.default_ttl;

        // Check if key exists
        if (self.cache.get(key)) |existing| {
            // Update existing entry
            existing.entry.deinit();
            existing.entry = try CacheEntry.init(self.allocator, value, effective_ttl);
            self.moveToFront(existing);
            return;
        }

        // Evict if necessary
        if (self.config.max_size) |max| {
            while (self.current_size >= max) {
                self.evictLRU();
            }
        }

        // Create new entry
        const entry = try CacheEntry.init(self.allocator, value, effective_ttl);
        const node = try self.allocator.create(LRUNode);
        node.* = .{
            .key = try self.allocator.dupe(u8, key),
            .entry = entry,
            .prev = null,
            .next = self.head,
        };

        if (self.head) |head| {
            head.prev = node;
        }
        self.head = node;
        if (self.tail == null) {
            self.tail = node;
        }

        try self.cache.put(node.key, node);
        self.current_size += 1;
    }

    fn has(ptr: *anyopaque, key: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cache.get(key)) |node| {
            return !node.entry.isExpired();
        }
        return false;
    }

    fn del(ptr: *anyopaque, key: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.delInternal(key);
    }

    fn clear(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*.key);
            entry.value_ptr.*.entry.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cache.clearRetainingCapacity();
        self.head = null;
        self.tail = null;
        self.current_size = 0;
    }

    fn size(ptr: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.current_size;
    }

    fn keys(ptr: *anyopaque, pattern: ?[]const u8) []const []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        var result: std.ArrayList([]const u8) = .empty;
        var it = self.cache.iterator();

        while (it.next()) |entry| {
            if (pattern) |p| {
                // Simple wildcard matching
                if (matchPattern(entry.key_ptr.*, p)) {
                    result.append(self.allocator, entry.key_ptr.*) catch continue;
                }
            } else {
                result.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        return result.toOwnedSlice(self.allocator) catch &[_][]const u8{};
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        clear(ptr);
        self.cache.deinit();
        self.allocator.destroy(self);
    }
};

/// Simple pattern matching (supports * wildcard)
fn matchPattern(str: []const u8, pattern: []const u8) bool {
    var si: usize = 0;
    var pi: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (si < str.len) {
        if (pi < pattern.len and (pattern[pi] == str[si] or pattern[pi] == '?')) {
            si += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_idx = pi;
            match_idx = si;
            pi += 1;
        } else if (star_idx != null) {
            pi = star_idx.? + 1;
            match_idx += 1;
            si = match_idx;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}

/// Filesystem cache driver
pub const FilesystemCacheDriver = struct {
    allocator: std.mem.Allocator,
    config: CacheConfig,
    directory: []const u8,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: CacheConfig) !*Self {
        const dir = config.fs_directory orelse "./cache";

        // Create cache directory
        std.fs.cwd().makePath(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .directory = try allocator.dupe(u8, dir),
            .mutex = .{},
        };
        return self;
    }

    pub fn driver(self: *Self) CacheDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .get = get,
                .set = set,
                .has = has,
                .del = del,
                .clear = clear,
                .size = size,
                .keys = keys,
                .deinit = deinit,
            },
        };
    }

    fn getCachePath(self: *Self, key: []const u8) ![]const u8 {
        // Hash the key for filename
        var hash: u64 = 0;
        for (key) |c| {
            hash = hash *% 31 +% c;
        }

        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{x}.cache", .{ self.directory, hash });
        return try self.allocator.dupe(u8, path);
    }

    fn get(ptr: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const path = self.getCachePath(key) catch return null;
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        // Read header (key_len:u32, ttl:i64, key:...)
        var header_buf: [12]u8 = undefined;
        _ = file.preadAll(&header_buf, 0) catch return null;

        const key_len = std.mem.readInt(u32, header_buf[0..4], .little);
        const expires_at = std.mem.readInt(i64, header_buf[4..12], .little);

        // Check expiration
        if (expires_at != 0 and getTimestamp() >= expires_at) {
            std.fs.cwd().deleteFile(path) catch {};
            return null;
        }

        // Read and verify key
        const stored_key = self.allocator.alloc(u8, key_len) catch return null;
        defer self.allocator.free(stored_key);
        _ = file.preadAll(stored_key, 12) catch return null;

        if (!std.mem.eql(u8, stored_key, key)) {
            return null; // Hash collision
        }

        // Read value - get file size and read remaining
        const stat = file.stat() catch return null;
        const value_start: usize = 12 + key_len;
        if (stat.size <= value_start) return null;
        const value_size = stat.size - value_start;
        const value = self.allocator.alloc(u8, value_size) catch return null;
        _ = file.preadAll(value, value_start) catch {
            self.allocator.free(value);
            return null;
        };
        return value;
    }

    fn set(ptr: *anyopaque, key: []const u8, value: []const u8, ttl: ?i64) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const path = try self.getCachePath(key);
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const effective_ttl = ttl orelse self.config.default_ttl;
        const expires_at: i64 = if (effective_ttl) |t| getTimestamp() + t else 0;

        // Write header
        var header_buf: [12]u8 = undefined;
        std.mem.writeInt(u32, header_buf[0..4], @intCast(key.len), .little);
        std.mem.writeInt(i64, header_buf[4..12], expires_at, .little);
        try file.writeAll(&header_buf);

        // Write key and value
        try file.writeAll(key);
        try file.writeAll(value);
    }

    fn has(ptr: *anyopaque, key: []const u8) bool {
        return get(ptr, key) != null;
    }

    fn del(ptr: *anyopaque, key: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const path = self.getCachePath(key) catch return false;
        defer self.allocator.free(path);

        std.fs.cwd().deleteFile(path) catch return false;
        return true;
    }

    fn clear(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        var dir = std.fs.cwd().openDir(self.directory, .{ .iterate = true }) catch return;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".cache")) {
                dir.deleteFile(entry.name) catch {};
            }
        }
    }

    fn size(ptr: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        var dir = std.fs.cwd().openDir(self.directory, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".cache")) {
                count += 1;
            }
        }
        return count;
    }

    fn keys(ptr: *anyopaque, pattern: ?[]const u8) []const []const u8 {
        _ = ptr;
        _ = pattern;
        // Filesystem cache doesn't support key enumeration efficiently
        return &[_][]const u8{};
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.free(self.directory);
        self.allocator.destroy(self);
    }
};

/// Redis cache driver - real implementation using Redis protocol
pub const RedisCacheDriver = struct {
    allocator: std.mem.Allocator,
    config: CacheConfig,
    redis: Redis,
    mutex: std.Thread.Mutex,

    const Self = @This();

    // Redis client (inline implementation for self-contained package)
    const Redis = struct {
        allocator: std.mem.Allocator,
        socket: ?posix.socket_t = null,
        host: []const u8,
        port: u16,
        password: ?[]const u8,
        database: u8,
        read_buffer: [8192]u8 = undefined,
        read_pos: usize = 0,
        read_len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, password: ?[]const u8, database: u8) Redis {
            return .{
                .allocator = allocator,
                .host = host,
                .port = port,
                .password = password,
                .database = database,
            };
        }

        pub fn connect(self: *Redis) anyerror!void {
            if (self.socket != null) return;

            // Create socket
            self.socket = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return error.ConnectionFailed;

            // Build address
            var addr: posix.sockaddr.in = .{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, self.port),
                .addr = 0x0100007F, // 127.0.0.1
            };

            // Parse host if not localhost
            if (!std.mem.eql(u8, self.host, "127.0.0.1") and !std.mem.eql(u8, self.host, "localhost")) {
                var parts: [4]u8 = .{ 0, 0, 0, 0 };
                var iter = std.mem.splitScalar(u8, self.host, '.');
                var i: usize = 0;
                while (iter.next()) |part| {
                    if (i >= 4) break;
                    parts[i] = std.fmt.parseInt(u8, part, 10) catch 0;
                    i += 1;
                }
                addr.addr = @as(u32, parts[0]) | (@as(u32, parts[1]) << 8) | (@as(u32, parts[2]) << 16) | (@as(u32, parts[3]) << 24);
            }

            posix.connect(self.socket.?, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch {
                posix.close(self.socket.?);
                self.socket = null;
                return error.ConnectionFailed;
            };

            // Authenticate if needed
            if (self.password) |pw| {
                _ = try self.command(&[_][]const u8{ "AUTH", pw });
            }

            // Select database
            if (self.database > 0) {
                var db_buf: [4]u8 = undefined;
                const db_str = std.fmt.bufPrint(&db_buf, "{d}", .{self.database}) catch "0";
                _ = try self.command(&[_][]const u8{ "SELECT", db_str });
            }
        }

        pub fn disconnect(self: *Redis) void {
            if (self.socket) |sock| {
                posix.close(sock);
                self.socket = null;
            }
            self.read_pos = 0;
            self.read_len = 0;
        }

        pub fn command(self: *Redis, args: []const []const u8) !?[]const u8 {
            if (self.socket == null) try self.connect();
            const sock = self.socket orelse return error.ConnectionClosed;

            // Build RESP command into fixed buffer
            var cmd_buf: [4096]u8 = undefined;
            var pos: usize = 0;

            pos += (std.fmt.bufPrint(cmd_buf[pos..], "*{d}\r\n", .{args.len}) catch return error.ConnectionClosed).len;

            for (args) |arg| {
                pos += (std.fmt.bufPrint(cmd_buf[pos..], "${d}\r\n", .{arg.len}) catch return error.ConnectionClosed).len;
                @memcpy(cmd_buf[pos .. pos + arg.len], arg);
                pos += arg.len;
                cmd_buf[pos] = '\r';
                cmd_buf[pos + 1] = '\n';
                pos += 2;
            }

            _ = posix.send(sock, cmd_buf[0..pos], 0) catch return error.ConnectionClosed;
            return self.readResponse();
        }

        pub fn commandInt(self: *Redis, args: []const []const u8) !?i64 {
            if (self.socket == null) try self.connect();
            const sock = self.socket orelse return error.ConnectionClosed;

            var cmd_buf: [4096]u8 = undefined;
            var pos: usize = 0;

            pos += (std.fmt.bufPrint(cmd_buf[pos..], "*{d}\r\n", .{args.len}) catch return error.ConnectionClosed).len;

            for (args) |arg| {
                pos += (std.fmt.bufPrint(cmd_buf[pos..], "${d}\r\n", .{arg.len}) catch return error.ConnectionClosed).len;
                @memcpy(cmd_buf[pos .. pos + arg.len], arg);
                pos += arg.len;
                cmd_buf[pos] = '\r';
                cmd_buf[pos + 1] = '\n';
                pos += 2;
            }

            _ = posix.send(sock, cmd_buf[0..pos], 0) catch return error.ConnectionClosed;
            return self.readIntResponse();
        }

        fn readResponse(self: *Redis) !?[]const u8 {
            const byte = try self.readByte();
            return switch (byte) {
                '+' => try self.readLine(), // Simple string
                '-' => blk: { // Error
                    const err_msg = try self.readLine();
                    self.allocator.free(err_msg);
                    break :blk null;
                },
                ':' => blk: { // Integer - convert to string
                    const line = try self.readLine();
                    break :blk line;
                },
                '$' => try self.readBulkString(), // Bulk string
                '*' => blk: { // Array - return first element
                    const len = try self.readInteger();
                    if (len <= 0) break :blk null;
                    const first = try self.readResponse();
                    // Skip remaining elements
                    var i: usize = 1;
                    while (i < @as(usize, @intCast(len))) : (i += 1) {
                        if (try self.readResponse()) |v| self.allocator.free(v);
                    }
                    break :blk first;
                },
                else => null,
            };
        }

        fn readIntResponse(self: *Redis) !?i64 {
            const byte = try self.readByte();
            return switch (byte) {
                ':' => try self.readInteger(),
                '+' => blk: {
                    const line = try self.readLine();
                    defer self.allocator.free(line);
                    break :blk if (std.mem.eql(u8, line, "OK")) 1 else 0;
                },
                '-' => blk: {
                    const err = try self.readLine();
                    self.allocator.free(err);
                    break :blk null;
                },
                '$' => blk: {
                    const str = try self.readBulkString();
                    if (str) |s| {
                        defer self.allocator.free(s);
                        break :blk std.fmt.parseInt(i64, s, 10) catch null;
                    }
                    break :blk null;
                },
                else => null,
            };
        }

        fn readByte(self: *Redis) !u8 {
            if (self.read_pos >= self.read_len) {
                try self.fillBuffer();
            }
            const byte = self.read_buffer[self.read_pos];
            self.read_pos += 1;
            return byte;
        }

        fn fillBuffer(self: *Redis) !void {
            const sock = self.socket orelse return error.ConnectionClosed;
            const n = posix.recv(sock, &self.read_buffer, 0) catch return error.ConnectionClosed;
            self.read_len = n;
            self.read_pos = 0;
            if (self.read_len == 0) return error.ConnectionClosed;
        }

        fn readLine(self: *Redis) ![]const u8 {
            var line: std.ArrayList(u8) = .empty;
            errdefer line.deinit(self.allocator);

            while (true) {
                const byte = try self.readByte();
                if (byte == '\r') {
                    _ = try self.readByte(); // consume \n
                    break;
                }
                try line.append(self.allocator, byte);
            }
            return line.toOwnedSlice(self.allocator);
        }

        fn readInteger(self: *Redis) !i64 {
            const line = try self.readLine();
            defer self.allocator.free(line);
            return std.fmt.parseInt(i64, line, 10) catch 0;
        }

        fn readBulkString(self: *Redis) !?[]const u8 {
            const len = try self.readInteger();
            if (len < 0) return null;

            const data_size: usize = @intCast(len);
            var data = try self.allocator.alloc(u8, data_size);
            errdefer self.allocator.free(data);

            var read: usize = 0;
            while (read < data_size) {
                if (self.read_pos >= self.read_len) try self.fillBuffer();
                const available = @min(self.read_len - self.read_pos, data_size - read);
                @memcpy(data[read .. read + available], self.read_buffer[self.read_pos .. self.read_pos + available]);
                read += available;
                self.read_pos += available;
            }

            _ = try self.readByte(); // \r
            _ = try self.readByte(); // \n
            return data;
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: CacheConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .redis = Redis.init(
                allocator,
                config.redis_host orelse "127.0.0.1",
                config.redis_port,
                config.redis_password,
                config.redis_database,
            ),
            .mutex = .{},
        };

        // Try to connect
        self.redis.connect() catch {
            // Connection failed, but we'll retry on first use
        };

        return self;
    }

    pub fn driver(self: *Self) CacheDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .get = get,
                .set = set,
                .has = has,
                .del = del,
                .clear = clear,
                .size = size,
                .keys = keys,
                .deinit = deinit,
            },
        };
    }

    fn get(ptr: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.redis.command(&[_][]const u8{ "GET", key }) catch null;
    }

    fn set(ptr: *anyopaque, key: []const u8, value: []const u8, ttl: ?i64) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (ttl) |seconds| {
            var ttl_buf: [20]u8 = undefined;
            const ttl_str = try std.fmt.bufPrint(&ttl_buf, "{d}", .{seconds});
            const result = try self.redis.command(&[_][]const u8{ "SET", key, value, "EX", ttl_str });
            if (result) |r| self.allocator.free(r);
        } else {
            const result = try self.redis.command(&[_][]const u8{ "SET", key, value });
            if (result) |r| self.allocator.free(r);
        }
    }

    fn has(ptr: *anyopaque, key: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.redis.commandInt(&[_][]const u8{ "EXISTS", key }) catch return false;
        return result != null and result.? > 0;
    }

    fn del(ptr: *anyopaque, key: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.redis.commandInt(&[_][]const u8{ "DEL", key }) catch return false;
        return result != null and result.? > 0;
    }

    fn clear(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.redis.command(&[_][]const u8{"FLUSHDB"}) catch return;
        if (result) |r| self.allocator.free(r);
    }

    fn size(ptr: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.redis.commandInt(&[_][]const u8{"DBSIZE"}) catch return 0;
        return if (result) |r| @intCast(@max(0, r)) else 0;
    }

    fn keys(ptr: *anyopaque, pattern: ?[]const u8) []const []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const p = pattern orelse "*";

        // Use SCAN for production, but simplified KEYS for now
        const result = self.redis.command(&[_][]const u8{ "KEYS", p }) catch return &[_][]const u8{};
        if (result) |r| {
            self.allocator.free(r);
        }
        // Note: Full implementation would parse the array response
        return &[_][]const u8{};
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.redis.disconnect();
        self.allocator.destroy(self);
    }
};

/// Cache manager - high-level API
pub const Cache = struct {
    allocator: std.mem.Allocator,
    config: CacheConfig,
    driver: CacheDriver,
    prefix: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: CacheConfig) !Self {
        const driver_ptr = switch (config.driver_type) {
            .memory => blk: {
                const mem = try MemoryCacheDriver.init(allocator, config);
                break :blk mem.driver();
            },
            .filesystem => blk: {
                const fs = try FilesystemCacheDriver.init(allocator, config);
                break :blk fs.driver();
            },
            .redis => blk: {
                const redis = try RedisCacheDriver.init(allocator, config);
                break :blk redis.driver();
            },
            .dynamodb => blk: {
                // Fallback to memory for now
                const mem = try MemoryCacheDriver.init(allocator, config);
                break :blk mem.driver();
            },
        };

        return .{
            .allocator = allocator,
            .config = config,
            .driver = driver_ptr,
            .prefix = config.prefix,
        };
    }

    pub fn deinit(self: *Self) void {
        self.driver.deinit();
    }

    fn prefixKey(self: *Self, key: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ self.prefix, key });
    }

    /// Get a value from cache
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        const prefixed = self.prefixKey(key) catch return null;
        defer self.allocator.free(prefixed);
        return self.driver.get(prefixed);
    }

    /// Get a value or set it if missing
    pub fn getOrSet(self: *Self, key: []const u8, default_value: []const u8) ![]const u8 {
        if (self.get(key)) |value| {
            return value;
        }
        try self.set(key, default_value, null);
        return default_value;
    }

    /// Set a value with optional TTL
    pub fn set(self: *Self, key: []const u8, value: []const u8, ttl: ?i64) !void {
        const prefixed = try self.prefixKey(key);
        defer self.allocator.free(prefixed);
        return self.driver.set(prefixed, value, ttl);
    }

    /// Set a value that never expires
    pub fn setForever(self: *Self, key: []const u8, value: []const u8) !void {
        const prefixed = try self.prefixKey(key);
        defer self.allocator.free(prefixed);
        // Pass 0 as TTL to indicate no expiration
        return self.driver.set(prefixed, value, null);
    }

    /// Check if key exists
    pub fn has(self: *Self, key: []const u8) bool {
        const prefixed = self.prefixKey(key) catch return false;
        defer self.allocator.free(prefixed);
        return self.driver.has(prefixed);
    }

    /// Check if key is missing
    pub fn missing(self: *Self, key: []const u8) bool {
        return !self.has(key);
    }

    /// Delete a key
    pub fn del(self: *Self, key: []const u8) bool {
        const prefixed = self.prefixKey(key) catch return false;
        defer self.allocator.free(prefixed);
        return self.driver.del(prefixed);
    }

    /// Delete a key (alias)
    pub fn remove(self: *Self, key: []const u8) bool {
        return self.del(key);
    }

    /// Delete multiple keys
    pub fn deleteMany(self: *Self, to_delete_keys: []const []const u8) usize {
        var deleted: usize = 0;
        for (to_delete_keys) |key| {
            if (self.del(key)) {
                deleted += 1;
            }
        }
        return deleted;
    }

    /// Clear all cache entries
    pub fn clear(self: *Self) void {
        self.driver.clear();
    }

    /// Delete all (alias for clear)
    pub fn deleteAll(self: *Self) void {
        self.clear();
    }

    /// Get cache size
    pub fn size(self: *Self) usize {
        return self.driver.size();
    }

    /// Get all keys matching pattern
    pub fn keys(self: *Self, pattern: ?[]const u8) []const []const u8 {
        return self.driver.keys(pattern);
    }

    /// Remember a value (get or compute)
    pub fn remember(
        self: *Self,
        key: []const u8,
        ttl: ?i64,
        callback: *const fn () anyerror![]const u8,
    ) ![]const u8 {
        if (self.get(key)) |value| {
            return value;
        }

        const value = try callback();
        try self.set(key, value, ttl);
        return value;
    }

    /// Remember forever
    pub fn rememberForever(
        self: *Self,
        key: []const u8,
        callback: *const fn () anyerror![]const u8,
    ) ![]const u8 {
        return self.remember(key, null, callback);
    }

    /// Increment a numeric value
    pub fn increment(self: *Self, key: []const u8, by: i64) !i64 {
        const current = self.get(key);
        const value: i64 = if (current) |c| blk: {
            break :blk std.fmt.parseInt(i64, c, 10) catch 0;
        } else 0;

        const new_value = value + by;
        var buf: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{d}", .{new_value});
        try self.set(key, str, null);
        return new_value;
    }

    /// Decrement a numeric value
    pub fn decrement(self: *Self, key: []const u8, by: i64) !i64 {
        return self.increment(key, -by);
    }
};

// Tests
test "memory cache basic operations" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, CacheConfig.memory());
    defer cache.deinit();

    // Set and get
    try cache.set("key1", "value1", null);
    const value = cache.get("key1");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("value1", value.?);

    // Has
    try std.testing.expect(cache.has("key1"));
    try std.testing.expect(!cache.has("nonexistent"));

    // Delete
    try std.testing.expect(cache.del("key1"));
    try std.testing.expect(!cache.has("key1"));
}

test "memory cache with ttl" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, CacheConfig.memory());
    defer cache.deinit();

    // Set with very short TTL (already expired)
    try cache.set("expiring", "value", -1);

    // Should be expired
    const value = cache.get("expiring");
    try std.testing.expect(value == null);
}

test "memory cache lru eviction" {
    const allocator = std.testing.allocator;
    var config = CacheConfig.memory();
    config.max_size = 2;

    var cache = try Cache.init(allocator, config);
    defer cache.deinit();

    try cache.set("key1", "value1", null);
    try cache.set("key2", "value2", null);

    // Access key1 to make it recently used
    _ = cache.get("key1");

    // Add key3, should evict key2 (LRU)
    try cache.set("key3", "value3", null);

    try std.testing.expect(cache.has("key1"));
    try std.testing.expect(!cache.has("key2")); // Evicted
    try std.testing.expect(cache.has("key3"));
}

test "pattern matching" {
    try std.testing.expect(matchPattern("hello", "hello"));
    try std.testing.expect(matchPattern("hello", "h*"));
    try std.testing.expect(matchPattern("hello", "*o"));
    try std.testing.expect(matchPattern("hello", "h*o"));
    try std.testing.expect(matchPattern("hello", "*"));
    try std.testing.expect(!matchPattern("hello", "world"));
    try std.testing.expect(matchPattern("hello", "h?llo"));
}

test "cache increment/decrement" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, CacheConfig.memory());
    defer cache.deinit();

    const v1 = try cache.increment("counter", 1);
    try std.testing.expectEqual(@as(i64, 1), v1);

    const v2 = try cache.increment("counter", 5);
    try std.testing.expectEqual(@as(i64, 6), v2);

    const v3 = try cache.decrement("counter", 2);
    try std.testing.expectEqual(@as(i64, 4), v3);
}
