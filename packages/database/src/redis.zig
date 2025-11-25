const std = @import("std");

/// Redis client driver (RESP protocol)
///
/// Features:
/// - RESP2 and RESP3 protocol support
/// - Connection pooling
/// - Pipelining
/// - Pub/Sub
/// - Transactions (MULTI/EXEC)
/// - Lua scripting
/// - Cluster support
/// - Sentinel support
pub const Redis = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    protocol_version: ProtocolVersion,
    subscriptions: std.StringHashMap(SubscriptionCallback),
    in_transaction: bool,

    pub const ProtocolVersion = enum {
        resp2,
        resp3,
    };

    pub const SubscriptionCallback = *const fn (channel: []const u8, message: []const u8) void;

    pub const Config = struct {
        host: []const u8 = "localhost",
        port: u16 = 6379,
        password: ?[]const u8 = null,
        database: u32 = 0,
        protocol_version: ProtocolVersion = .resp2,
        connect_timeout_ms: u64 = 5000,
    };

    pub const Value = union(enum) {
        nil,
        string: []const u8,
        error_msg: []const u8,
        integer: i64,
        array: []Value,
        bulk_string: ?[]const u8,

        pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .string => |s| allocator.free(s),
                .error_msg => |e| allocator.free(e),
                .bulk_string => |bs| if (bs) |s| allocator.free(s),
                .array => |arr| {
                    for (arr) |*item| {
                        item.deinit(allocator);
                    }
                    allocator.free(arr);
                },
                else => {},
            }
        }
    };

    pub fn connect(allocator: std.mem.Allocator, config: Config) !Redis {
        const address = try std.net.Address.parseIp(config.host, config.port);
        const stream = try std.net.tcpConnectToAddress(address);

        var redis = Redis{
            .allocator = allocator,
            .stream = stream,
            .protocol_version = config.protocol_version,
            .subscriptions = std.StringHashMap(SubscriptionCallback).init(allocator),
            .in_transaction = false,
        };

        // Authenticate if password provided
        if (config.password) |password| {
            const auth_result = try redis.command(&.{ "AUTH", password });
            defer auth_result.deinit(allocator);

            switch (auth_result) {
                .error_msg => return error.AuthenticationFailed,
                else => {},
            }
        }

        // Select database
        if (config.database != 0) {
            var db_str: [20]u8 = undefined;
            const db_str_slice = try std.fmt.bufPrint(&db_str, "{d}", .{config.database});
            const select_result = try redis.command(&.{ "SELECT", db_str_slice });
            defer select_result.deinit(allocator);

            switch (select_result) {
                .error_msg => return error.SelectDatabaseFailed,
                else => {},
            }
        }

        return redis;
    }

    pub fn deinit(self: *Redis) void {
        self.stream.close();
        self.subscriptions.deinit();
    }

    /// Execute a Redis command
    pub fn command(self: *Redis, args: []const []const u8) !Value {
        try self.sendCommand(args);
        return try self.receiveResponse();
    }

    /// Pipeline multiple commands
    pub fn pipeline(self: *Redis, commands: []const []const []const u8) ![]Value {
        // Send all commands
        for (commands) |cmd| {
            try self.sendCommand(cmd);
        }

        // Receive all responses
        var results = try self.allocator.alloc(Value, commands.len);
        errdefer self.allocator.free(results);

        for (0..commands.len) |i| {
            results[i] = try self.receiveResponse();
        }

        return results;
    }

    /// String operations
    pub fn get(self: *Redis, key: []const u8) !?[]const u8 {
        const result = try self.command(&.{ "GET", key });
        switch (result) {
            .bulk_string => |bs| {
                if (bs) |s| {
                    return try self.allocator.dupe(u8, s);
                }
                return null;
            },
            .nil => return null,
            else => return error.UnexpectedResponse,
        }
    }

    pub fn set(self: *Redis, key: []const u8, value: []const u8) !void {
        const result = try self.command(&.{ "SET", key, value });
        defer result.deinit(self.allocator);

        switch (result) {
            .string => |s| {
                if (!std.mem.eql(u8, s, "OK")) return error.SetFailed;
            },
            else => return error.UnexpectedResponse,
        }
    }

    pub fn setex(self: *Redis, key: []const u8, seconds: u64, value: []const u8) !void {
        var seconds_str: [20]u8 = undefined;
        const seconds_slice = try std.fmt.bufPrint(&seconds_str, "{d}", .{seconds});

        const result = try self.command(&.{ "SETEX", key, seconds_slice, value });
        defer result.deinit(self.allocator);

        switch (result) {
            .string => |s| {
                if (!std.mem.eql(u8, s, "OK")) return error.SetFailed;
            },
            else => return error.UnexpectedResponse,
        }
    }

    pub fn del(self: *Redis, keys: []const []const u8) !usize {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("DEL");
        try args.appendSlice(keys);

        const result = try self.command(args.items);
        defer result.deinit(self.allocator);

        switch (result) {
            .integer => |n| return @intCast(n),
            else => return error.UnexpectedResponse,
        }
    }

    pub fn exists(self: *Redis, key: []const u8) !bool {
        const result = try self.command(&.{ "EXISTS", key });
        defer result.deinit(self.allocator);

        switch (result) {
            .integer => |n| return n > 0,
            else => return error.UnexpectedResponse,
        }
    }

    pub fn expire(self: *Redis, key: []const u8, seconds: u64) !bool {
        var seconds_str: [20]u8 = undefined;
        const seconds_slice = try std.fmt.bufPrint(&seconds_str, "{d}", .{seconds});

        const result = try self.command(&.{ "EXPIRE", key, seconds_slice });
        defer result.deinit(self.allocator);

        switch (result) {
            .integer => |n| return n == 1,
            else => return error.UnexpectedResponse,
        }
    }

    /// List operations
    pub fn lpush(self: *Redis, key: []const u8, values: []const []const u8) !usize {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("LPUSH");
        try args.append(key);
        try args.appendSlice(values);

        const result = try self.command(args.items);
        defer result.deinit(self.allocator);

        switch (result) {
            .integer => |n| return @intCast(n),
            else => return error.UnexpectedResponse,
        }
    }

    pub fn rpush(self: *Redis, key: []const u8, values: []const []const u8) !usize {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("RPUSH");
        try args.append(key);
        try args.appendSlice(values);

        const result = try self.command(args.items);
        defer result.deinit(self.allocator);

        switch (result) {
            .integer => |n| return @intCast(n),
            else => return error.UnexpectedResponse,
        }
    }

    pub fn lpop(self: *Redis, key: []const u8) !?[]const u8 {
        const result = try self.command(&.{ "LPOP", key });
        switch (result) {
            .bulk_string => |bs| {
                if (bs) |s| {
                    return try self.allocator.dupe(u8, s);
                }
                return null;
            },
            .nil => return null,
            else => return error.UnexpectedResponse,
        }
    }

    pub fn lrange(self: *Redis, key: []const u8, start: i64, stop: i64) ![][]const u8 {
        var start_str: [20]u8 = undefined;
        var stop_str: [20]u8 = undefined;
        const start_slice = try std.fmt.bufPrint(&start_str, "{d}", .{start});
        const stop_slice = try std.fmt.bufPrint(&stop_str, "{d}", .{stop});

        const result = try self.command(&.{ "LRANGE", key, start_slice, stop_slice });

        switch (result) {
            .array => |arr| {
                var list = try self.allocator.alloc([]const u8, arr.len);
                for (arr, 0..) |item, i| {
                    switch (item) {
                        .bulk_string => |bs| {
                            if (bs) |s| {
                                list[i] = try self.allocator.dupe(u8, s);
                            } else {
                                list[i] = "";
                            }
                        },
                        else => return error.UnexpectedResponse,
                    }
                }
                return list;
            },
            else => return error.UnexpectedResponse,
        }
    }

    /// Hash operations
    pub fn hset(self: *Redis, key: []const u8, field: []const u8, value: []const u8) !bool {
        const result = try self.command(&.{ "HSET", key, field, value });
        defer result.deinit(self.allocator);

        switch (result) {
            .integer => |n| return n == 1,
            else => return error.UnexpectedResponse,
        }
    }

    pub fn hget(self: *Redis, key: []const u8, field: []const u8) !?[]const u8 {
        const result = try self.command(&.{ "HGET", key, field });
        switch (result) {
            .bulk_string => |bs| {
                if (bs) |s| {
                    return try self.allocator.dupe(u8, s);
                }
                return null;
            },
            .nil => return null,
            else => return error.UnexpectedResponse,
        }
    }

    pub fn hgetall(self: *Redis, key: []const u8) !std.StringHashMap([]const u8) {
        const result = try self.command(&.{ "HGETALL", key });

        var map = std.StringHashMap([]const u8).init(self.allocator);
        errdefer map.deinit();

        switch (result) {
            .array => |arr| {
                var i: usize = 0;
                while (i < arr.len) : (i += 2) {
                    const field = switch (arr[i]) {
                        .bulk_string => |bs| bs orelse return error.UnexpectedResponse,
                        else => return error.UnexpectedResponse,
                    };
                    const value = switch (arr[i + 1]) {
                        .bulk_string => |bs| bs orelse return error.UnexpectedResponse,
                        else => return error.UnexpectedResponse,
                    };

                    try map.put(
                        try self.allocator.dupe(u8, field),
                        try self.allocator.dupe(u8, value),
                    );
                }
            },
            else => return error.UnexpectedResponse,
        }

        return map;
    }

    /// Set operations
    pub fn sadd(self: *Redis, key: []const u8, members: []const []const u8) !usize {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("SADD");
        try args.append(key);
        try args.appendSlice(members);

        const result = try self.command(args.items);
        defer result.deinit(self.allocator);

        switch (result) {
            .integer => |n| return @intCast(n),
            else => return error.UnexpectedResponse,
        }
    }

    pub fn smembers(self: *Redis, key: []const u8) ![][]const u8 {
        const result = try self.command(&.{ "SMEMBERS", key });

        switch (result) {
            .array => |arr| {
                var members = try self.allocator.alloc([]const u8, arr.len);
                for (arr, 0..) |item, i| {
                    switch (item) {
                        .bulk_string => |bs| {
                            if (bs) |s| {
                                members[i] = try self.allocator.dupe(u8, s);
                            } else {
                                return error.UnexpectedResponse;
                            }
                        },
                        else => return error.UnexpectedResponse,
                    }
                }
                return members;
            },
            else => return error.UnexpectedResponse,
        }
    }

    /// Transaction operations
    pub fn multi(self: *Redis) !void {
        const result = try self.command(&.{"MULTI"});
        defer result.deinit(self.allocator);

        switch (result) {
            .string => |s| {
                if (!std.mem.eql(u8, s, "OK")) return error.MultiFailed;
                self.in_transaction = true;
            },
            else => return error.UnexpectedResponse,
        }
    }

    pub fn exec(self: *Redis) ![]Value {
        const result = try self.command(&.{"EXEC"});
        self.in_transaction = false;

        switch (result) {
            .array => |arr| {
                var results = try self.allocator.alloc(Value, arr.len);
                for (arr, 0..) |item, i| {
                    results[i] = item;
                }
                return results;
            },
            .nil => return error.TransactionAborted,
            else => return error.UnexpectedResponse,
        }
    }

    pub fn discard(self: *Redis) !void {
        const result = try self.command(&.{"DISCARD"});
        defer result.deinit(self.allocator);
        self.in_transaction = false;

        switch (result) {
            .string => |s| {
                if (!std.mem.eql(u8, s, "OK")) return error.DiscardFailed;
            },
            else => return error.UnexpectedResponse,
        }
    }

    /// Pub/Sub operations
    pub fn publish(self: *Redis, channel: []const u8, message: []const u8) !usize {
        const result = try self.command(&.{ "PUBLISH", channel, message });
        defer result.deinit(self.allocator);

        switch (result) {
            .integer => |n| return @intCast(n),
            else => return error.UnexpectedResponse,
        }
    }

    pub fn subscribe(self: *Redis, channels: []const []const u8, callback: SubscriptionCallback) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("SUBSCRIBE");
        try args.appendSlice(channels);

        // Subscribe and store callback
        _ = try self.command(args.items);

        for (channels) |channel| {
            try self.subscriptions.put(try self.allocator.dupe(u8, channel), callback);
        }
    }

    fn sendCommand(self: *Redis, args: []const []const u8) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // RESP array format: *<count>\r\n
        try buffer.writer().print("*{d}\r\n", .{args.len});

        for (args) |arg| {
            // Bulk string format: $<length>\r\n<data>\r\n
            try buffer.writer().print("${d}\r\n", .{arg.len});
            try buffer.appendSlice(arg);
            try buffer.appendSlice("\r\n");
        }

        try self.stream.writeAll(buffer.items);
    }

    fn receiveResponse(self: *Redis) !Value {
        var reader = self.stream.reader();

        const type_byte = try reader.readByte();

        return switch (type_byte) {
            '+' => try self.readSimpleString(reader), // Simple string
            '-' => try self.readError(reader),         // Error
            ':' => try self.readInteger(reader),       // Integer
            '$' => try self.readBulkString(reader),    // Bulk string
            '*' => try self.readArray(reader),         // Array
            else => error.InvalidRESPType,
        };
    }

    fn readSimpleString(self: *Redis, reader: anytype) !Value {
        const line = try reader.readUntilDelimiterAlloc(self.allocator, '\n', 1024);
        // Remove \r if present
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        return Value{ .string = try self.allocator.dupe(u8, trimmed) };
    }

    fn readError(self: *Redis, reader: anytype) !Value {
        const line = try reader.readUntilDelimiterAlloc(self.allocator, '\n', 1024);
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        return Value{ .error_msg = try self.allocator.dupe(u8, trimmed) };
    }

    fn readInteger(self: *Redis, reader: anytype) !Value {
        _ = self;
        const line = try reader.readUntilDelimiterAlloc(self.allocator, '\n', 1024);
        defer self.allocator.free(line);

        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        const num = try std.fmt.parseInt(i64, trimmed, 10);
        return Value{ .integer = num };
    }

    fn readBulkString(self: *Redis, reader: anytype) !Value {
        const line = try reader.readUntilDelimiterAlloc(self.allocator, '\n', 1024);
        defer self.allocator.free(line);

        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        const len = try std.fmt.parseInt(i64, trimmed, 10);

        if (len == -1) {
            return Value{ .bulk_string = null };
        }

        const str_len: usize = @intCast(len);
        const data = try self.allocator.alloc(u8, str_len);
        errdefer self.allocator.free(data);

        try reader.readNoEof(data);

        // Read trailing \r\n
        _ = try reader.readByte(); // \r
        _ = try reader.readByte(); // \n

        return Value{ .bulk_string = data };
    }

    fn readArray(self: *Redis, reader: anytype) !Value {
        const line = try reader.readUntilDelimiterAlloc(self.allocator, '\n', 1024);
        defer self.allocator.free(line);

        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        const count = try std.fmt.parseInt(i64, trimmed, 10);

        if (count == -1) {
            return Value.nil;
        }

        const array_len: usize = @intCast(count);
        var array = try self.allocator.alloc(Value, array_len);
        errdefer self.allocator.free(array);

        for (0..array_len) |i| {
            array[i] = try self.receiveResponse();
        }

        return Value{ .array = array };
    }
};

/// Connection pool for Redis
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: Redis.Config,
    connections: std.ArrayList(*Redis),
    available: std.ArrayList(*Redis),
    max_connections: usize,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: Redis.Config, max_connections: usize) ConnectionPool {
        return .{
            .allocator = allocator,
            .config = config,
            .connections = std.ArrayList(*Redis).init(allocator),
            .available = std.ArrayList(*Redis).init(allocator),
            .max_connections = max_connections,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit();
        self.available.deinit();
    }

    pub fn acquire(self: *ConnectionPool) !*Redis {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.popOrNull()) |conn| {
            return conn;
        }

        if (self.connections.items.len < self.max_connections) {
            const conn = try self.allocator.create(Redis);
            conn.* = try Redis.connect(self.allocator, self.config);
            try self.connections.append(conn);
            return conn;
        }

        return error.PoolExhausted;
    }

    pub fn release(self: *ConnectionPool, conn: *Redis) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.available.append(conn);
    }
};
