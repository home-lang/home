const std = @import("std");
const posix = std.posix;
const net = std.net;

/// Redis error types
pub const RedisError = error{
    ConnectionFailed,
    ConnectionClosed,
    AuthenticationFailed,
    InvalidResponse,
    CommandFailed,
    Timeout,
    OutOfMemory,
    InvalidArgument,
    WrongType,
    NoScript,
    Loading,
    Busy,
    NoAuth,
    ClusterDown,
    TryAgain,
    Moved,
    Ask,
};

/// RESP (Redis Serialization Protocol) value types
pub const RespValue = union(enum) {
    simple_string: []const u8,
    err: []const u8,
    integer: i64,
    bulk_string: ?[]const u8,
    array: ?[]const RespValue,

    pub fn deinit(self: *RespValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .simple_string => |s| allocator.free(s),
            .err => |e| allocator.free(e),
            .bulk_string => |bs| if (bs) |s| allocator.free(s),
            .array => |arr| if (arr) |a| {
                for (a) |*item| {
                    var mutable_item = item.*;
                    mutable_item.deinit(allocator);
                }
                allocator.free(a);
            },
            .integer => {},
        }
    }

    pub fn isOk(self: *const RespValue) bool {
        return switch (self.*) {
            .simple_string => |s| std.mem.eql(u8, s, "OK"),
            else => false,
        };
    }

    pub fn isNull(self: *const RespValue) bool {
        return switch (self.*) {
            .bulk_string => |bs| bs == null,
            .array => |arr| arr == null,
            else => false,
        };
    }

    pub fn asString(self: *const RespValue) ?[]const u8 {
        return switch (self.*) {
            .simple_string => |s| s,
            .bulk_string => |bs| bs,
            else => null,
        };
    }

    pub fn asInt(self: *const RespValue) ?i64 {
        return switch (self.*) {
            .integer => |i| i,
            .bulk_string => |bs| if (bs) |s| std.fmt.parseInt(i64, s, 10) catch null else null,
            else => null,
        };
    }

    pub fn asArray(self: *const RespValue) ?[]const RespValue {
        return switch (self.*) {
            .array => |arr| arr,
            else => null,
        };
    }
};

/// Redis connection configuration
pub const RedisConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    password: ?[]const u8 = null,
    database: u8 = 0,
    username: ?[]const u8 = null, // Redis 6+ ACL
    connect_timeout_ms: u32 = 5000,
    read_timeout_ms: u32 = 5000,
    write_timeout_ms: u32 = 5000,
    max_retries: u32 = 3,
    retry_delay_ms: u32 = 100,
    tls: bool = false,
    pool_size: u32 = 10,

    pub fn default() RedisConfig {
        return .{};
    }

    pub fn fromUrl(url: []const u8) !RedisConfig {
        // Parse redis://[username:password@]host[:port][/database]
        var config = RedisConfig.default();

        var remaining = url;

        // Skip protocol
        if (std.mem.startsWith(u8, remaining, "redis://")) {
            remaining = remaining[8..];
        } else if (std.mem.startsWith(u8, remaining, "rediss://")) {
            remaining = remaining[9..];
            config.tls = true;
        }

        // Check for auth
        if (std.mem.indexOf(u8, remaining, "@")) |at_idx| {
            const auth_part = remaining[0..at_idx];
            remaining = remaining[at_idx + 1 ..];

            if (std.mem.indexOf(u8, auth_part, ":")) |colon_idx| {
                if (colon_idx > 0) {
                    config.username = auth_part[0..colon_idx];
                }
                config.password = auth_part[colon_idx + 1 ..];
            } else {
                config.password = auth_part;
            }
        }

        // Parse host:port/database
        if (std.mem.indexOf(u8, remaining, "/")) |slash_idx| {
            const db_str = remaining[slash_idx + 1 ..];
            config.database = std.fmt.parseInt(u8, db_str, 10) catch 0;
            remaining = remaining[0..slash_idx];
        }

        if (std.mem.indexOf(u8, remaining, ":")) |colon_idx| {
            config.host = remaining[0..colon_idx];
            config.port = std.fmt.parseInt(u16, remaining[colon_idx + 1 ..], 10) catch 6379;
        } else {
            config.host = remaining;
        }

        return config;
    }
};

/// Redis client
pub const Redis = struct {
    allocator: std.mem.Allocator,
    config: RedisConfig,
    stream: ?net.Stream = null,
    read_buffer: [8192]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: RedisConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
    }

    /// Connect to Redis server
    pub fn connect(self: *Self) !void {
        if (self.stream != null) return;

        const address = net.Address.resolveIp(self.config.host, self.config.port) catch {
            return RedisError.ConnectionFailed;
        };

        self.stream = net.tcpConnectToAddress(address) catch {
            return RedisError.ConnectionFailed;
        };

        // Authenticate if password is set
        if (self.config.password) |password| {
            if (self.config.username) |username| {
                // Redis 6+ ACL auth
                _ = try self.command(&[_][]const u8{ "AUTH", username, password });
            } else {
                _ = try self.command(&[_][]const u8{ "AUTH", password });
            }
        }

        // Select database
        if (self.config.database > 0) {
            var db_buf: [4]u8 = undefined;
            const db_str = std.fmt.bufPrint(&db_buf, "{d}", .{self.config.database}) catch "0";
            _ = try self.command(&[_][]const u8{ "SELECT", db_str });
        }
    }

    /// Disconnect from Redis
    pub fn disconnect(self: *Self) void {
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
        self.read_pos = 0;
        self.read_len = 0;
    }

    /// Check if connected
    pub fn isConnected(self: *Self) bool {
        return self.stream != null;
    }

    /// Ping the server
    pub fn ping(self: *Self) !bool {
        const result = try self.command(&[_][]const u8{"PING"});
        defer {
            var r = result;
            r.deinit(self.allocator);
        }
        return result.asString() != null and std.mem.eql(u8, result.asString().?, "PONG");
    }

    /// Execute a Redis command
    pub fn command(self: *Self, args: []const []const u8) !RespValue {
        try self.ensureConnected();
        try self.sendCommand(args);
        return self.readResponse();
    }

    /// Execute command and return string result
    pub fn commandString(self: *Self, args: []const []const u8) !?[]const u8 {
        var result = try self.command(args);
        const str = result.asString();
        if (str) |s| {
            const owned = try self.allocator.dupe(u8, s);
            result.deinit(self.allocator);
            return owned;
        }
        result.deinit(self.allocator);
        return null;
    }

    /// Execute command and return integer result
    pub fn commandInt(self: *Self, args: []const []const u8) !?i64 {
        var result = try self.command(args);
        defer result.deinit(self.allocator);
        return result.asInt();
    }

    // ============ String Commands ============

    /// GET key
    pub fn get(self: *Self, key: []const u8) !?[]const u8 {
        return self.commandString(&[_][]const u8{ "GET", key });
    }

    /// SET key value [EX seconds] [PX milliseconds] [NX|XX]
    pub fn set(self: *Self, key: []const u8, value: []const u8) !bool {
        var result = try self.command(&[_][]const u8{ "SET", key, value });
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// SET with expiration in seconds
    pub fn setex(self: *Self, key: []const u8, seconds: i64, value: []const u8) !bool {
        var sec_buf: [20]u8 = undefined;
        const sec_str = std.fmt.bufPrint(&sec_buf, "{d}", .{seconds}) catch return error.InvalidArgument;
        var result = try self.command(&[_][]const u8{ "SET", key, value, "EX", sec_str });
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// SET with expiration in milliseconds
    pub fn psetex(self: *Self, key: []const u8, milliseconds: i64, value: []const u8) !bool {
        var ms_buf: [20]u8 = undefined;
        const ms_str = std.fmt.bufPrint(&ms_buf, "{d}", .{milliseconds}) catch return error.InvalidArgument;
        var result = try self.command(&[_][]const u8{ "SET", key, value, "PX", ms_str });
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// SET if not exists
    pub fn setnx(self: *Self, key: []const u8, value: []const u8) !bool {
        const result = try self.commandInt(&[_][]const u8{ "SETNX", key, value });
        return result != null and result.? == 1;
    }

    /// MGET key [key ...]
    pub fn mget(self: *Self, keys: []const []const u8) ![]?[]const u8 {
        var args = try self.allocator.alloc([]const u8, keys.len + 1);
        defer self.allocator.free(args);

        args[0] = "MGET";
        for (keys, 0..) |key, i| {
            args[i + 1] = key;
        }

        var result = try self.command(args);
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            var values = try self.allocator.alloc(?[]const u8, arr.len);
            for (arr, 0..) |item, i| {
                values[i] = if (item.asString()) |s| try self.allocator.dupe(u8, s) else null;
            }
            return values;
        }
        return &[_]?[]const u8{};
    }

    /// MSET key value [key value ...]
    pub fn mset(self: *Self, pairs: []const [2][]const u8) !bool {
        var args = try self.allocator.alloc([]const u8, pairs.len * 2 + 1);
        defer self.allocator.free(args);

        args[0] = "MSET";
        for (pairs, 0..) |pair, i| {
            args[i * 2 + 1] = pair[0];
            args[i * 2 + 2] = pair[1];
        }

        var result = try self.command(args);
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// INCR key
    pub fn incr(self: *Self, key: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "INCR", key });
        return result orelse 0;
    }

    /// INCRBY key increment
    pub fn incrby(self: *Self, key: []const u8, increment: i64) !i64 {
        var inc_buf: [20]u8 = undefined;
        const inc_str = std.fmt.bufPrint(&inc_buf, "{d}", .{increment}) catch return 0;
        const result = try self.commandInt(&[_][]const u8{ "INCRBY", key, inc_str });
        return result orelse 0;
    }

    /// DECR key
    pub fn decr(self: *Self, key: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "DECR", key });
        return result orelse 0;
    }

    /// DECRBY key decrement
    pub fn decrby(self: *Self, key: []const u8, decrement: i64) !i64 {
        var dec_buf: [20]u8 = undefined;
        const dec_str = std.fmt.bufPrint(&dec_buf, "{d}", .{decrement}) catch return 0;
        const result = try self.commandInt(&[_][]const u8{ "DECRBY", key, dec_str });
        return result orelse 0;
    }

    /// APPEND key value
    pub fn append(self: *Self, key: []const u8, value: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "APPEND", key, value });
        return result orelse 0;
    }

    /// STRLEN key
    pub fn strlen(self: *Self, key: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "STRLEN", key });
        return result orelse 0;
    }

    // ============ Key Commands ============

    /// DEL key [key ...]
    pub fn del(self: *Self, keys: []const []const u8) !i64 {
        var args = try self.allocator.alloc([]const u8, keys.len + 1);
        defer self.allocator.free(args);

        args[0] = "DEL";
        for (keys, 0..) |key, i| {
            args[i + 1] = key;
        }

        const result = try self.commandInt(args);
        return result orelse 0;
    }

    /// EXISTS key [key ...]
    pub fn exists(self: *Self, keys: []const []const u8) !i64 {
        var args = try self.allocator.alloc([]const u8, keys.len + 1);
        defer self.allocator.free(args);

        args[0] = "EXISTS";
        for (keys, 0..) |key, i| {
            args[i + 1] = key;
        }

        const result = try self.commandInt(args);
        return result orelse 0;
    }

    /// EXPIRE key seconds
    pub fn expire(self: *Self, key: []const u8, seconds: i64) !bool {
        var sec_buf: [20]u8 = undefined;
        const sec_str = std.fmt.bufPrint(&sec_buf, "{d}", .{seconds}) catch return false;
        const result = try self.commandInt(&[_][]const u8{ "EXPIRE", key, sec_str });
        return result != null and result.? == 1;
    }

    /// PEXPIRE key milliseconds
    pub fn pexpire(self: *Self, key: []const u8, milliseconds: i64) !bool {
        var ms_buf: [20]u8 = undefined;
        const ms_str = std.fmt.bufPrint(&ms_buf, "{d}", .{milliseconds}) catch return false;
        const result = try self.commandInt(&[_][]const u8{ "PEXPIRE", key, ms_str });
        return result != null and result.? == 1;
    }

    /// TTL key
    pub fn ttl(self: *Self, key: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "TTL", key });
        return result orelse -2;
    }

    /// PTTL key
    pub fn pttl(self: *Self, key: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "PTTL", key });
        return result orelse -2;
    }

    /// PERSIST key
    pub fn persist(self: *Self, key: []const u8) !bool {
        const result = try self.commandInt(&[_][]const u8{ "PERSIST", key });
        return result != null and result.? == 1;
    }

    /// RENAME key newkey
    pub fn rename(self: *Self, key: []const u8, newkey: []const u8) !bool {
        var result = try self.command(&[_][]const u8{ "RENAME", key, newkey });
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// TYPE key
    pub fn keyType(self: *Self, key: []const u8) !?[]const u8 {
        return self.commandString(&[_][]const u8{ "TYPE", key });
    }

    /// KEYS pattern
    pub fn keys(self: *Self, pattern: []const u8) ![][]const u8 {
        var result = try self.command(&[_][]const u8{ "KEYS", pattern });
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            var key_list = try self.allocator.alloc([]const u8, arr.len);
            var count: usize = 0;
            for (arr) |item| {
                if (item.asString()) |s| {
                    key_list[count] = try self.allocator.dupe(u8, s);
                    count += 1;
                }
            }
            return key_list[0..count];
        }
        return &[_][]const u8{};
    }

    /// SCAN cursor [MATCH pattern] [COUNT count]
    pub fn scan(self: *Self, cursor: u64, pattern: ?[]const u8, count: ?u64) !struct { cursor: u64, keys: [][]const u8 } {
        var args_buf: [7][]const u8 = undefined;
        var args_len: usize = 2;

        var cursor_buf: [20]u8 = undefined;
        const cursor_str = std.fmt.bufPrint(&cursor_buf, "{d}", .{cursor}) catch "0";

        args_buf[0] = "SCAN";
        args_buf[1] = cursor_str;

        if (pattern) |p| {
            args_buf[args_len] = "MATCH";
            args_buf[args_len + 1] = p;
            args_len += 2;
        }

        if (count) |c| {
            var count_buf: [20]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{c}) catch "10";
            args_buf[args_len] = "COUNT";
            args_buf[args_len + 1] = count_str;
            args_len += 2;
        }

        var result = try self.command(args_buf[0..args_len]);
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            if (arr.len >= 2) {
                const new_cursor = if (arr[0].asString()) |s|
                    std.fmt.parseInt(u64, s, 10) catch 0
                else
                    0;

                if (arr[1].asArray()) |key_arr| {
                    var key_list = try self.allocator.alloc([]const u8, key_arr.len);
                    var key_count: usize = 0;
                    for (key_arr) |item| {
                        if (item.asString()) |s| {
                            key_list[key_count] = try self.allocator.dupe(u8, s);
                            key_count += 1;
                        }
                    }
                    return .{ .cursor = new_cursor, .keys = key_list[0..key_count] };
                }
            }
        }

        return .{ .cursor = 0, .keys = &[_][]const u8{} };
    }

    /// FLUSHDB [ASYNC|SYNC]
    pub fn flushdb(self: *Self) !bool {
        var result = try self.command(&[_][]const u8{"FLUSHDB"});
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// DBSIZE
    pub fn dbsize(self: *Self) !i64 {
        const result = try self.commandInt(&[_][]const u8{"DBSIZE"});
        return result orelse 0;
    }

    // ============ Hash Commands ============

    /// HGET key field
    pub fn hget(self: *Self, key: []const u8, field: []const u8) !?[]const u8 {
        return self.commandString(&[_][]const u8{ "HGET", key, field });
    }

    /// HSET key field value
    pub fn hset(self: *Self, key: []const u8, field: []const u8, value: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "HSET", key, field, value });
        return result orelse 0;
    }

    /// HMSET key field value [field value ...]
    pub fn hmset(self: *Self, key: []const u8, pairs: []const [2][]const u8) !bool {
        var args = try self.allocator.alloc([]const u8, pairs.len * 2 + 2);
        defer self.allocator.free(args);

        args[0] = "HMSET";
        args[1] = key;
        for (pairs, 0..) |pair, i| {
            args[i * 2 + 2] = pair[0];
            args[i * 2 + 3] = pair[1];
        }

        var result = try self.command(args);
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// HMGET key field [field ...]
    pub fn hmget(self: *Self, key: []const u8, fields: []const []const u8) ![]?[]const u8 {
        var args = try self.allocator.alloc([]const u8, fields.len + 2);
        defer self.allocator.free(args);

        args[0] = "HMGET";
        args[1] = key;
        for (fields, 0..) |field, i| {
            args[i + 2] = field;
        }

        var result = try self.command(args);
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            var values = try self.allocator.alloc(?[]const u8, arr.len);
            for (arr, 0..) |item, i| {
                values[i] = if (item.asString()) |s| try self.allocator.dupe(u8, s) else null;
            }
            return values;
        }
        return &[_]?[]const u8{};
    }

    /// HGETALL key
    pub fn hgetall(self: *Self, key: []const u8) !std.StringHashMap([]const u8) {
        var result = try self.command(&[_][]const u8{ "HGETALL", key });
        defer result.deinit(self.allocator);

        var map = std.StringHashMap([]const u8).init(self.allocator);

        if (result.asArray()) |arr| {
            var i: usize = 0;
            while (i + 1 < arr.len) : (i += 2) {
                if (arr[i].asString()) |field| {
                    if (arr[i + 1].asString()) |value| {
                        const owned_field = try self.allocator.dupe(u8, field);
                        const owned_value = try self.allocator.dupe(u8, value);
                        try map.put(owned_field, owned_value);
                    }
                }
            }
        }

        return map;
    }

    /// HDEL key field [field ...]
    pub fn hdel(self: *Self, key: []const u8, fields: []const []const u8) !i64 {
        var args = try self.allocator.alloc([]const u8, fields.len + 2);
        defer self.allocator.free(args);

        args[0] = "HDEL";
        args[1] = key;
        for (fields, 0..) |field, i| {
            args[i + 2] = field;
        }

        const result = try self.commandInt(args);
        return result orelse 0;
    }

    /// HEXISTS key field
    pub fn hexists(self: *Self, key: []const u8, field: []const u8) !bool {
        const result = try self.commandInt(&[_][]const u8{ "HEXISTS", key, field });
        return result != null and result.? == 1;
    }

    /// HLEN key
    pub fn hlen(self: *Self, key: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "HLEN", key });
        return result orelse 0;
    }

    /// HKEYS key
    pub fn hkeys(self: *Self, key: []const u8) ![][]const u8 {
        var result = try self.command(&[_][]const u8{ "HKEYS", key });
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            var field_list = try self.allocator.alloc([]const u8, arr.len);
            var count: usize = 0;
            for (arr) |item| {
                if (item.asString()) |s| {
                    field_list[count] = try self.allocator.dupe(u8, s);
                    count += 1;
                }
            }
            return field_list[0..count];
        }
        return &[_][]const u8{};
    }

    /// HINCRBY key field increment
    pub fn hincrby(self: *Self, key: []const u8, field: []const u8, increment: i64) !i64 {
        var inc_buf: [20]u8 = undefined;
        const inc_str = std.fmt.bufPrint(&inc_buf, "{d}", .{increment}) catch return 0;
        const result = try self.commandInt(&[_][]const u8{ "HINCRBY", key, field, inc_str });
        return result orelse 0;
    }

    // ============ List Commands ============

    /// LPUSH key element [element ...]
    pub fn lpush(self: *Self, key: []const u8, elements: []const []const u8) !i64 {
        var args = try self.allocator.alloc([]const u8, elements.len + 2);
        defer self.allocator.free(args);

        args[0] = "LPUSH";
        args[1] = key;
        for (elements, 0..) |elem, i| {
            args[i + 2] = elem;
        }

        const result = try self.commandInt(args);
        return result orelse 0;
    }

    /// RPUSH key element [element ...]
    pub fn rpush(self: *Self, key: []const u8, elements: []const []const u8) !i64 {
        var args = try self.allocator.alloc([]const u8, elements.len + 2);
        defer self.allocator.free(args);

        args[0] = "RPUSH";
        args[1] = key;
        for (elements, 0..) |elem, i| {
            args[i + 2] = elem;
        }

        const result = try self.commandInt(args);
        return result orelse 0;
    }

    /// LPOP key
    pub fn lpop(self: *Self, key: []const u8) !?[]const u8 {
        return self.commandString(&[_][]const u8{ "LPOP", key });
    }

    /// RPOP key
    pub fn rpop(self: *Self, key: []const u8) !?[]const u8 {
        return self.commandString(&[_][]const u8{ "RPOP", key });
    }

    /// BLPOP key [key ...] timeout
    pub fn blpop(self: *Self, key_list: []const []const u8, timeout: u64) !?struct { key: []const u8, value: []const u8 } {
        var args = try self.allocator.alloc([]const u8, key_list.len + 2);
        defer self.allocator.free(args);

        args[0] = "BLPOP";
        for (key_list, 0..) |key, i| {
            args[i + 1] = key;
        }
        var timeout_buf: [20]u8 = undefined;
        const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout}) catch "0";
        args[key_list.len + 1] = timeout_str;

        var result = try self.command(args);
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            if (arr.len >= 2) {
                if (arr[0].asString()) |k| {
                    if (arr[1].asString()) |v| {
                        return .{
                            .key = try self.allocator.dupe(u8, k),
                            .value = try self.allocator.dupe(u8, v),
                        };
                    }
                }
            }
        }
        return null;
    }

    /// BRPOP key [key ...] timeout
    pub fn brpop(self: *Self, key_list: []const []const u8, timeout: u64) !?struct { key: []const u8, value: []const u8 } {
        var args = try self.allocator.alloc([]const u8, key_list.len + 2);
        defer self.allocator.free(args);

        args[0] = "BRPOP";
        for (key_list, 0..) |key, i| {
            args[i + 1] = key;
        }
        var timeout_buf: [20]u8 = undefined;
        const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout}) catch "0";
        args[key_list.len + 1] = timeout_str;

        var result = try self.command(args);
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            if (arr.len >= 2) {
                if (arr[0].asString()) |k| {
                    if (arr[1].asString()) |v| {
                        return .{
                            .key = try self.allocator.dupe(u8, k),
                            .value = try self.allocator.dupe(u8, v),
                        };
                    }
                }
            }
        }
        return null;
    }

    /// LRANGE key start stop
    pub fn lrange(self: *Self, key: []const u8, start: i64, stop: i64) ![][]const u8 {
        var start_buf: [20]u8 = undefined;
        var stop_buf: [20]u8 = undefined;
        const start_str = std.fmt.bufPrint(&start_buf, "{d}", .{start}) catch "0";
        const stop_str = std.fmt.bufPrint(&stop_buf, "{d}", .{stop}) catch "-1";

        var result = try self.command(&[_][]const u8{ "LRANGE", key, start_str, stop_str });
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            var list = try self.allocator.alloc([]const u8, arr.len);
            var count: usize = 0;
            for (arr) |item| {
                if (item.asString()) |s| {
                    list[count] = try self.allocator.dupe(u8, s);
                    count += 1;
                }
            }
            return list[0..count];
        }
        return &[_][]const u8{};
    }

    /// LLEN key
    pub fn llen(self: *Self, key: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "LLEN", key });
        return result orelse 0;
    }

    /// LINDEX key index
    pub fn lindex(self: *Self, key: []const u8, index: i64) !?[]const u8 {
        var idx_buf: [20]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch "0";
        return self.commandString(&[_][]const u8{ "LINDEX", key, idx_str });
    }

    /// LTRIM key start stop
    pub fn ltrim(self: *Self, key: []const u8, start: i64, stop: i64) !bool {
        var start_buf: [20]u8 = undefined;
        var stop_buf: [20]u8 = undefined;
        const start_str = std.fmt.bufPrint(&start_buf, "{d}", .{start}) catch "0";
        const stop_str = std.fmt.bufPrint(&stop_buf, "{d}", .{stop}) catch "-1";

        var result = try self.command(&[_][]const u8{ "LTRIM", key, start_str, stop_str });
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    // ============ Set Commands ============

    /// SADD key member [member ...]
    pub fn sadd(self: *Self, key: []const u8, members: []const []const u8) !i64 {
        var args = try self.allocator.alloc([]const u8, members.len + 2);
        defer self.allocator.free(args);

        args[0] = "SADD";
        args[1] = key;
        for (members, 0..) |member, i| {
            args[i + 2] = member;
        }

        const result = try self.commandInt(args);
        return result orelse 0;
    }

    /// SREM key member [member ...]
    pub fn srem(self: *Self, key: []const u8, members: []const []const u8) !i64 {
        var args = try self.allocator.alloc([]const u8, members.len + 2);
        defer self.allocator.free(args);

        args[0] = "SREM";
        args[1] = key;
        for (members, 0..) |member, i| {
            args[i + 2] = member;
        }

        const result = try self.commandInt(args);
        return result orelse 0;
    }

    /// SMEMBERS key
    pub fn smembers(self: *Self, key: []const u8) ![][]const u8 {
        var result = try self.command(&[_][]const u8{ "SMEMBERS", key });
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            var members = try self.allocator.alloc([]const u8, arr.len);
            var count: usize = 0;
            for (arr) |item| {
                if (item.asString()) |s| {
                    members[count] = try self.allocator.dupe(u8, s);
                    count += 1;
                }
            }
            return members[0..count];
        }
        return &[_][]const u8{};
    }

    /// SISMEMBER key member
    pub fn sismember(self: *Self, key: []const u8, member: []const u8) !bool {
        const result = try self.commandInt(&[_][]const u8{ "SISMEMBER", key, member });
        return result != null and result.? == 1;
    }

    /// SCARD key
    pub fn scard(self: *Self, key: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "SCARD", key });
        return result orelse 0;
    }

    /// SPOP key
    pub fn spop(self: *Self, key: []const u8) !?[]const u8 {
        return self.commandString(&[_][]const u8{ "SPOP", key });
    }

    // ============ Sorted Set Commands ============

    /// ZADD key score member [score member ...]
    pub fn zadd(self: *Self, key: []const u8, pairs: []const struct { score: f64, member: []const u8 }) !i64 {
        var args = try self.allocator.alloc([]const u8, pairs.len * 2 + 2);
        defer self.allocator.free(args);

        var score_bufs = try self.allocator.alloc([32]u8, pairs.len);
        defer self.allocator.free(score_bufs);

        args[0] = "ZADD";
        args[1] = key;
        for (pairs, 0..) |pair, i| {
            const score_str = std.fmt.bufPrint(&score_bufs[i], "{d}", .{pair.score}) catch "0";
            args[i * 2 + 2] = score_str;
            args[i * 2 + 3] = pair.member;
        }

        const result = try self.commandInt(args);
        return result orelse 0;
    }

    /// ZREM key member [member ...]
    pub fn zrem(self: *Self, key: []const u8, members: []const []const u8) !i64 {
        var args = try self.allocator.alloc([]const u8, members.len + 2);
        defer self.allocator.free(args);

        args[0] = "ZREM";
        args[1] = key;
        for (members, 0..) |member, i| {
            args[i + 2] = member;
        }

        const result = try self.commandInt(args);
        return result orelse 0;
    }

    /// ZRANGE key start stop [WITHSCORES]
    pub fn zrange(self: *Self, key: []const u8, start: i64, stop: i64, with_scores: bool) ![][]const u8 {
        var start_buf: [20]u8 = undefined;
        var stop_buf: [20]u8 = undefined;
        const start_str = std.fmt.bufPrint(&start_buf, "{d}", .{start}) catch "0";
        const stop_str = std.fmt.bufPrint(&stop_buf, "{d}", .{stop}) catch "-1";

        var result = if (with_scores)
            try self.command(&[_][]const u8{ "ZRANGE", key, start_str, stop_str, "WITHSCORES" })
        else
            try self.command(&[_][]const u8{ "ZRANGE", key, start_str, stop_str });
        defer result.deinit(self.allocator);

        if (result.asArray()) |arr| {
            var list = try self.allocator.alloc([]const u8, arr.len);
            var count: usize = 0;
            for (arr) |item| {
                if (item.asString()) |s| {
                    list[count] = try self.allocator.dupe(u8, s);
                    count += 1;
                }
            }
            return list[0..count];
        }
        return &[_][]const u8{};
    }

    /// ZSCORE key member
    pub fn zscore(self: *Self, key: []const u8, member: []const u8) !?f64 {
        const str = try self.commandString(&[_][]const u8{ "ZSCORE", key, member });
        if (str) |s| {
            defer self.allocator.free(s);
            return std.fmt.parseFloat(f64, s) catch null;
        }
        return null;
    }

    /// ZCARD key
    pub fn zcard(self: *Self, key: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "ZCARD", key });
        return result orelse 0;
    }

    /// ZRANK key member
    pub fn zrank(self: *Self, key: []const u8, member: []const u8) !?i64 {
        return self.commandInt(&[_][]const u8{ "ZRANK", key, member });
    }

    /// ZINCRBY key increment member
    pub fn zincrby(self: *Self, key: []const u8, increment: f64, member: []const u8) !f64 {
        var inc_buf: [32]u8 = undefined;
        const inc_str = std.fmt.bufPrint(&inc_buf, "{d}", .{increment}) catch "0";

        const str = try self.commandString(&[_][]const u8{ "ZINCRBY", key, inc_str, member });
        if (str) |s| {
            defer self.allocator.free(s);
            return std.fmt.parseFloat(f64, s) catch 0;
        }
        return 0;
    }

    // ============ Pub/Sub Commands ============

    /// PUBLISH channel message
    pub fn publish(self: *Self, channel: []const u8, message: []const u8) !i64 {
        const result = try self.commandInt(&[_][]const u8{ "PUBLISH", channel, message });
        return result orelse 0;
    }

    // ============ Transaction Commands ============

    /// MULTI
    pub fn multi(self: *Self) !bool {
        var result = try self.command(&[_][]const u8{"MULTI"});
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// EXEC
    pub fn exec(self: *Self) !?[]RespValue {
        var result = try self.command(&[_][]const u8{"EXEC"});

        if (result.asArray()) |arr| {
            const owned = try self.allocator.dupe(RespValue, arr);
            return owned;
        }
        result.deinit(self.allocator);
        return null;
    }

    /// DISCARD
    pub fn discard(self: *Self) !bool {
        var result = try self.command(&[_][]const u8{"DISCARD"});
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// WATCH key [key ...]
    pub fn watch(self: *Self, key_list: []const []const u8) !bool {
        var args = try self.allocator.alloc([]const u8, key_list.len + 1);
        defer self.allocator.free(args);

        args[0] = "WATCH";
        for (key_list, 0..) |key, i| {
            args[i + 1] = key;
        }

        var result = try self.command(args);
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    /// UNWATCH
    pub fn unwatch(self: *Self) !bool {
        var result = try self.command(&[_][]const u8{"UNWATCH"});
        defer result.deinit(self.allocator);
        return result.isOk();
    }

    // ============ Script Commands ============

    /// EVAL script numkeys key [key ...] arg [arg ...]
    pub fn eval(self: *Self, script: []const u8, key_list: []const []const u8, script_args: []const []const u8) !RespValue {
        var args = try self.allocator.alloc([]const u8, 3 + key_list.len + script_args.len);
        defer self.allocator.free(args);

        var numkeys_buf: [10]u8 = undefined;
        const numkeys_str = std.fmt.bufPrint(&numkeys_buf, "{d}", .{key_list.len}) catch "0";

        args[0] = "EVAL";
        args[1] = script;
        args[2] = numkeys_str;

        for (key_list, 0..) |key, i| {
            args[3 + i] = key;
        }
        for (script_args, 0..) |arg, i| {
            args[3 + key_list.len + i] = arg;
        }

        return self.command(args);
    }

    // ============ Internal Methods ============

    fn ensureConnected(self: *Self) !void {
        if (self.stream == null) {
            try self.connect();
        }
    }

    fn sendCommand(self: *Self, args: []const []const u8) !void {
        const stream = self.stream orelse return RedisError.ConnectionClosed;
        const writer = stream.writer();

        // Write RESP array header
        try writer.print("*{d}\r\n", .{args.len});

        // Write each argument as bulk string
        for (args) |arg| {
            try writer.print("${d}\r\n", .{arg.len});
            try writer.writeAll(arg);
            try writer.writeAll("\r\n");
        }
    }

    fn readResponse(self: *Self) !RespValue {
        const byte = try self.readByte();

        return switch (byte) {
            '+' => RespValue{ .simple_string = try self.readLine() },
            '-' => RespValue{ .err = try self.readLine() },
            ':' => RespValue{ .integer = try self.readInteger() },
            '$' => try self.readBulkString(),
            '*' => try self.readArray(),
            else => RedisError.InvalidResponse,
        };
    }

    fn readByte(self: *Self) !u8 {
        if (self.read_pos >= self.read_len) {
            try self.fillBuffer();
        }
        const byte = self.read_buffer[self.read_pos];
        self.read_pos += 1;
        return byte;
    }

    fn fillBuffer(self: *Self) !void {
        const stream = self.stream orelse return RedisError.ConnectionClosed;
        self.read_len = stream.read(&self.read_buffer) catch return RedisError.ConnectionClosed;
        self.read_pos = 0;
        if (self.read_len == 0) {
            return RedisError.ConnectionClosed;
        }
    }

    fn readLine(self: *Self) ![]const u8 {
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

    fn readInteger(self: *Self) !i64 {
        const line = try self.readLine();
        defer self.allocator.free(line);
        return std.fmt.parseInt(i64, line, 10) catch 0;
    }

    fn readBulkString(self: *Self) !RespValue {
        const len = try self.readInteger();
        if (len < 0) {
            return RespValue{ .bulk_string = null };
        }

        const size: usize = @intCast(len);
        var data = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(data);

        var read: usize = 0;
        while (read < size) {
            if (self.read_pos >= self.read_len) {
                try self.fillBuffer();
            }
            const available = @min(self.read_len - self.read_pos, size - read);
            @memcpy(data[read .. read + available], self.read_buffer[self.read_pos .. self.read_pos + available]);
            read += available;
            self.read_pos += available;
        }

        // Consume trailing \r\n
        _ = try self.readByte();
        _ = try self.readByte();

        return RespValue{ .bulk_string = data };
    }

    fn readArray(self: *Self) !RespValue {
        const len = try self.readInteger();
        if (len < 0) {
            return RespValue{ .array = null };
        }

        const size: usize = @intCast(len);
        var items = try self.allocator.alloc(RespValue, size);
        errdefer self.allocator.free(items);

        for (0..size) |i| {
            items[i] = try self.readResponse();
        }

        return RespValue{ .array = items };
    }
};

/// Connection pool for Redis
pub const RedisPool = struct {
    allocator: std.mem.Allocator,
    config: RedisConfig,
    connections: std.ArrayList(*Redis),
    available: std.ArrayList(*Redis),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: RedisConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .connections = .empty,
            .available = .empty,
            .mutex = .{},
        };

        // Pre-create connections
        for (0..config.pool_size) |_| {
            const conn = try allocator.create(Redis);
            conn.* = Redis.init(allocator, config);
            try conn.connect();
            try self.connections.append(allocator, conn);
            try self.available.append(allocator, conn);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn acquire(self: *Self) !*Redis {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.items.len > 0) {
            return self.available.pop();
        }

        // Create new connection if under limit
        if (self.connections.items.len < self.config.pool_size * 2) {
            const conn = try self.allocator.create(Redis);
            conn.* = Redis.init(self.allocator, self.config);
            try conn.connect();
            try self.connections.append(self.allocator, conn);
            return conn;
        }

        return RedisError.ConnectionFailed;
    }

    pub fn release(self: *Self, conn: *Redis) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.available.append(self.allocator, conn) catch {};
    }
};

// Tests
test "redis config from url" {
    const config = try RedisConfig.fromUrl("redis://user:pass@localhost:6380/5");
    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(u16, 6380), config.port);
    try std.testing.expectEqualStrings("pass", config.password.?);
    try std.testing.expectEqualStrings("user", config.username.?);
    try std.testing.expectEqual(@as(u8, 5), config.database);
}

test "redis config default" {
    const config = RedisConfig.default();
    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 6379), config.port);
    try std.testing.expect(config.password == null);
}

test "resp value helpers" {
    const ok = RespValue{ .simple_string = "OK" };
    try std.testing.expect(ok.isOk());
    try std.testing.expectEqualStrings("OK", ok.asString().?);

    const null_bulk = RespValue{ .bulk_string = null };
    try std.testing.expect(null_bulk.isNull());

    const int_val = RespValue{ .integer = 42 };
    try std.testing.expectEqual(@as(i64, 42), int_val.asInt().?);
}
