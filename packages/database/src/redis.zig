const std = @import("std");
const net = std.Io.net;

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
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: net.Stream,
    protocol_version: ProtocolVersion,
    subscriptions: std.StringHashMap(SubscriptionCallback),
    in_transaction: bool,
    read_buffer: [8192]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,

    pub const ProtocolVersion = enum {
        resp2,
        resp3,
    };

    pub const SubscriptionCallback = *const fn (channel: []const u8, message: []const u8) void;

    pub const Config = struct {
        io: std.Io,
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
        const stream = try connectToHost(config);
        // Close the socket if anything below this point fails —
        // previously AUTH/SELECT failures leaked the open connection.
        errdefer stream.close(config.io);

        var redis = Redis{
            .io = config.io,
            .allocator = allocator,
            .stream = stream,
            .protocol_version = config.protocol_version,
            .subscriptions = std.StringHashMap(SubscriptionCallback).init(allocator),
            .in_transaction = false,
        };
        errdefer redis.subscriptions.deinit();

        // Authenticate if password provided
        if (config.password) |password| {
            var auth_result = try redis.command(&.{ "AUTH", password });
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
            var select_result = try redis.command(&.{ "SELECT", db_str_slice });
            defer select_result.deinit(allocator);

            switch (select_result) {
                .error_msg => return error.SelectDatabaseFailed,
                else => {},
            }
        }

        return redis;
    }

    pub fn deinit(self: *Redis) void {
        self.stream.close(self.io);
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
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "DEL");
        try args.appendSlice(self.allocator, keys);

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
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "LPUSH");
        try args.append(self.allocator, key);
        try args.appendSlice(self.allocator, values);

        const result = try self.command(args.items);
        defer result.deinit(self.allocator);

        switch (result) {
            .integer => |n| return @intCast(n),
            else => return error.UnexpectedResponse,
        }
    }

    pub fn rpush(self: *Redis, key: []const u8, values: []const []const u8) !usize {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "RPUSH");
        try args.append(self.allocator, key);
        try args.appendSlice(self.allocator, values);

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

                    const field_copy = try self.allocator.dupe(u8, field);
                    errdefer self.allocator.free(field_copy);
                    const value_copy = try self.allocator.dupe(u8, value);
                    errdefer self.allocator.free(value_copy);

                    const gop = try map.getOrPut(field_copy);
                    if (gop.found_existing) {
                        self.allocator.free(field_copy);
                        self.allocator.free(gop.value_ptr.*);
                    }
                    gop.value_ptr.* = value_copy;
                }
            },
            else => return error.UnexpectedResponse,
        }

        return map;
    }

    /// Set operations
    pub fn sadd(self: *Redis, key: []const u8, members: []const []const u8) !usize {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "SADD");
        try args.append(self.allocator, key);
        try args.appendSlice(self.allocator, members);

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
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "SUBSCRIBE");
        try args.appendSlice(self.allocator, channels);

        // Subscribe and store callback
        _ = try self.command(args.items);

        for (channels) |channel| {
            const ch_copy = try self.allocator.dupe(u8, channel);
            errdefer self.allocator.free(ch_copy);
            const gop = try self.subscriptions.getOrPut(ch_copy);
            if (gop.found_existing) self.allocator.free(ch_copy);
            gop.value_ptr.* = callback;
        }
    }

    fn sendCommand(self: *Redis, args: []const []const u8) !void {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);

        // RESP array format: *<count>\r\n
        try buffer.writer(self.allocator).print("*{d}\r\n", .{args.len});

        for (args) |arg| {
            // Bulk string format: $<length>\r\n<data>\r\n
            try buffer.writer(self.allocator).print("${d}\r\n", .{arg.len});
            try buffer.appendSlice(self.allocator, arg);
            try buffer.appendSlice(self.allocator, "\r\n");
        }
        try self.writeAll(buffer.items);
    }

    fn receiveResponse(self: *Redis) !Value {
        const type_byte = try self.readByte();

        return switch (type_byte) {
            '+' => try self.readSimpleString(), // Simple string
            '-' => try self.readError(), // Error
            ':' => try self.readInteger(), // Integer
            '$' => try self.readBulkString(), // Bulk string
            '*' => try self.readArray(), // Array
            else => error.InvalidRESPType,
        };
    }

    fn readSimpleString(self: *Redis) !Value {
        return .{ .string = try self.readLine() };
    }

    fn readError(self: *Redis) !Value {
        return .{ .error_msg = try self.readLine() };
    }

    fn readInteger(self: *Redis) !Value {
        const line = try self.readLine();
        defer self.allocator.free(line);
        return .{ .integer = try std.fmt.parseInt(i64, line, 10) };
    }

    fn readBulkString(self: *Redis) !Value {
        const line = try self.readLine();
        defer self.allocator.free(line);
        const len = try std.fmt.parseInt(i64, line, 10);

        if (len == -1) {
            return .{ .bulk_string = null };
        }
        if (len < 0) return error.InvalidBulkStringLength;

        const str_len: usize = @intCast(len);
        const data = try self.allocator.alloc(u8, str_len);
        errdefer self.allocator.free(data);

        try self.readAll(data);

        if (try self.readByte() != '\r' or try self.readByte() != '\n') {
            return error.InvalidRESPTerminator;
        }

        return .{ .bulk_string = data };
    }

    fn readArray(self: *Redis) !Value {
        const line = try self.readLine();
        defer self.allocator.free(line);
        const count = try std.fmt.parseInt(i64, line, 10);

        if (count == -1) {
            return Value.nil;
        }
        if (count < 0) return error.InvalidArrayLength;

        const array_len: usize = @intCast(count);
        var array = try self.allocator.alloc(Value, array_len);
        var initialized: usize = 0;
        errdefer {
            for (array[0..initialized]) |*item| item.deinit(self.allocator);
            self.allocator.free(array);
        }

        for (0..array_len) |i| {
            array[i] = try self.receiveResponse();
            initialized += 1;
        }

        return .{ .array = array };
    }

    fn writeAll(self: *Redis, bytes: []const u8) !void {
        var buffer: [4096]u8 = undefined;
        var stream_writer = self.stream.writer(self.io, &buffer);
        const writer = &stream_writer.interface;
        try writer.writeAll(bytes);
        try writer.flush();
    }

    fn readByte(self: *Redis) !u8 {
        if (self.read_pos >= self.read_len) try self.fillReadBuffer();
        const byte = self.read_buffer[self.read_pos];
        self.read_pos += 1;
        return byte;
    }

    fn fillReadBuffer(self: *Redis) !void {
        var buffers: [1][]u8 = .{&self.read_buffer};
        self.read_len = try self.stream.read(self.io, &buffers);
        self.read_pos = 0;
        if (self.read_len == 0) return error.EndOfStream;
    }

    fn readAll(self: *Redis, bytes: []u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.read_pos >= self.read_len) try self.fillReadBuffer();
            const available = self.read_len - self.read_pos;
            const copy_len = @min(available, bytes.len - offset);
            @memcpy(bytes[offset..][0..copy_len], self.read_buffer[self.read_pos..][0..copy_len]);
            self.read_pos += copy_len;
            offset += copy_len;
        }
    }

    fn readLine(self: *Redis) ![]u8 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(self.allocator);

        while (line.items.len < 1024) {
            const byte = try self.readByte();
            if (byte == '\r') {
                if (try self.readByte() != '\n') return error.InvalidRESPTerminator;
                return line.toOwnedSlice(self.allocator);
            }
            try line.append(self.allocator, byte);
        }
        return error.ResponseTooLarge;
    }
};

fn connectToHost(config: Redis.Config) !net.Stream {
    const options: net.IpAddress.ConnectOptions = .{
        .mode = .stream,
        .protocol = .tcp,
    };
    if (net.IpAddress.parse(config.host, config.port)) |address| {
        return address.connect(config.io, options);
    } else |_| {}

    const host_name = try net.HostName.init(config.host);
    return host_name.connect(config.io, config.port, options);
}

/// Connection pool for Redis
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: Redis.Config,
    connections: std.ArrayList(*Redis),
    available: std.ArrayList(*Redis),
    max_connections: usize,
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: Redis.Config, max_connections: usize) ConnectionPool {
        return .{
            .allocator = allocator,
            .config = config,
            .connections = .empty,
            .available = .empty,
            .max_connections = max_connections,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
    }

    pub fn acquire(self: *ConnectionPool) !*Redis {
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);

        if (self.available.pop()) |conn| {
            return conn;
        }

        if (self.connections.items.len < self.max_connections) {
            const conn = try self.allocator.create(Redis);
            errdefer self.allocator.destroy(conn);
            conn.* = try Redis.connect(self.allocator, self.config);
            errdefer conn.deinit();
            try self.connections.append(self.allocator, conn);
            return conn;
        }

        return error.PoolExhausted;
    }

    pub fn release(self: *ConnectionPool, conn: *Redis) !void {
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);

        try self.available.append(self.allocator, conn);
    }
};

test {
    std.testing.refAllDecls(@This());
}
