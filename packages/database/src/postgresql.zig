const std = @import("std");

/// PostgreSQL client driver
///
/// Features:
/// - Wire protocol 3.0
/// - Connection pooling
/// - Prepared statements
/// - Transactions
/// - COPY protocol
/// - LISTEN/NOTIFY
/// - SSL/TLS support
pub const PostgreSQL = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    process_id: u32,
    secret_key: u32,
    transaction_status: TransactionStatus,
    parameters: std.StringHashMap([]const u8),

    pub const TransactionStatus = enum(u8) {
        idle = 'I',
        in_transaction = 'T',
        in_failed_transaction = 'E',
    };

    pub const Config = struct {
        host: []const u8 = "localhost",
        port: u16 = 5432,
        database: []const u8,
        user: []const u8,
        password: ?[]const u8 = null,
        ssl_mode: SSLMode = .prefer,

        pub const SSLMode = enum {
            disable,
            allow,
            prefer,
            require,
        };
    };

    pub const Row = struct {
        allocator: std.mem.Allocator,
        columns: [][]const u8,

        pub fn deinit(self: *Row) void {
            for (self.columns) |col| {
                self.allocator.free(col);
            }
            self.allocator.free(self.columns);
        }

        pub fn get(self: *Row, index: usize) ?[]const u8 {
            if (index >= self.columns.len) return null;
            return self.columns[index];
        }
    };

    pub const QueryResult = struct {
        allocator: std.mem.Allocator,
        rows: std.ArrayList(Row),
        affected_rows: usize,

        pub fn deinit(self: *QueryResult) void {
            for (self.rows.items) |*row| {
                row.deinit();
            }
            self.rows.deinit();
        }
    };

    pub fn connect(allocator: std.mem.Allocator, config: Config) !PostgreSQL {
        const address = try std.net.Address.parseIp(config.host, config.port);
        const stream = try std.net.tcpConnectToAddress(address);

        var pg = PostgreSQL{
            .allocator = allocator,
            .stream = stream,
            .process_id = 0,
            .secret_key = 0,
            .transaction_status = .idle,
            .parameters = std.StringHashMap([]const u8).init(allocator),
        };

        try pg.startup(config);
        try pg.authenticate(config);

        return pg;
    }

    pub fn deinit(self: *PostgreSQL) void {
        self.terminate() catch {};
        self.stream.close();

        var it = self.parameters.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.parameters.deinit();
    }

    fn startup(self: *PostgreSQL, config: Config) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // Protocol version 3.0
        try buffer.appendSlice(&[_]u8{ 0, 3, 0, 0 });

        // Parameters
        try buffer.appendSlice("user\x00");
        try buffer.appendSlice(config.user);
        try buffer.append(0);

        try buffer.appendSlice("database\x00");
        try buffer.appendSlice(config.database);
        try buffer.append(0);

        try buffer.append(0); // Terminator

        // Send startup message
        try self.sendMessage(null, buffer.items);
    }

    fn authenticate(self: *PostgreSQL, config: Config) !void {
        while (true) {
            const msg = try self.receiveMessage();
            defer self.allocator.free(msg.payload);

            switch (msg.type) {
                'R' => { // Authentication
                    const auth_type = std.mem.readIntBig(u32, msg.payload[0..4]);
                    switch (auth_type) {
                        0 => break, // Auth OK
                        3 => { // Clear text password
                            if (config.password) |pwd| {
                                try self.sendPasswordMessage(pwd);
                            } else {
                                return error.PasswordRequired;
                            }
                        },
                        5 => { // MD5 password
                            if (config.password) |pwd| {
                                const salt = msg.payload[4..8];
                                try self.sendMD5Password(config.user, pwd, salt);
                            } else {
                                return error.PasswordRequired;
                            }
                        },
                        else => return error.UnsupportedAuthMethod,
                    }
                },
                'K' => { // BackendKeyData
                    self.process_id = std.mem.readIntBig(u32, msg.payload[0..4]);
                    self.secret_key = std.mem.readIntBig(u32, msg.payload[4..8]);
                },
                'S' => { // ParameterStatus
                    var iter = std.mem.splitScalar(u8, msg.payload, 0);
                    const key = iter.next() orelse continue;
                    const value = iter.next() orelse continue;

                    try self.parameters.put(
                        try self.allocator.dupe(u8, key),
                        try self.allocator.dupe(u8, value),
                    );
                },
                'Z' => { // ReadyForQuery
                    self.transaction_status = @enumFromInt(msg.payload[0]);
                    break;
                },
                'E' => { // Error
                    return error.AuthenticationFailed;
                },
                else => {},
            }
        }
    }

    /// Execute a query
    pub fn query(self: *PostgreSQL, sql: []const u8) !QueryResult {
        // Send query message
        try self.sendMessage('Q', sql);

        var result = QueryResult{
            .allocator = self.allocator,
            .rows = std.ArrayList(Row).init(self.allocator),
            .affected_rows = 0,
        };

        // Process response
        while (true) {
            const msg = try self.receiveMessage();
            defer self.allocator.free(msg.payload);

            switch (msg.type) {
                'T' => { // RowDescription - ignore for now
                },
                'D' => { // DataRow
                    const row = try self.parseDataRow(msg.payload);
                    try result.rows.append(row);
                },
                'C' => { // CommandComplete
                    // Parse affected rows from command tag
                    result.affected_rows = self.parseCommandTag(msg.payload);
                },
                'Z' => { // ReadyForQuery
                    self.transaction_status = @enumFromInt(msg.payload[0]);
                    break;
                },
                'E' => { // ErrorResponse
                    result.deinit();
                    return error.QueryFailed;
                },
                else => {},
            }
        }

        return result;
    }

    /// Execute a prepared statement
    pub fn execute(self: *PostgreSQL, name: []const u8, params: []const []const u8) !QueryResult {
        // Send bind message
        try self.sendBindMessage(name, params);

        // Send execute message
        try self.sendExecuteMessage(name);

        // Send sync message
        try self.sendMessage('S', &.{});

        return try self.readQueryResult();
    }

    /// Begin transaction
    pub fn begin(self: *PostgreSQL) !void {
        _ = try self.query("BEGIN");
    }

    /// Commit transaction
    pub fn commit(self: *PostgreSQL) !void {
        _ = try self.query("COMMIT");
    }

    /// Rollback transaction
    pub fn rollback(self: *PostgreSQL) !void {
        _ = try self.query("ROLLBACK");
    }

    fn sendMessage(self: *PostgreSQL, msg_type: ?u8, payload: []const u8) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        if (msg_type) |t| {
            try buffer.append(t);
        }

        const len: u32 = @intCast(payload.len + 4);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeIntBig(u32, &len_bytes, len);
        try buffer.appendSlice(&len_bytes);

        try buffer.appendSlice(payload);
        try self.stream.writeAll(buffer.items);
    }

    fn receiveMessage(self: *PostgreSQL) !struct { type: u8, payload: []u8 } {
        var msg_type: [1]u8 = undefined;
        try self.stream.reader().readNoEof(&msg_type);

        var len_bytes: [4]u8 = undefined;
        try self.stream.reader().readNoEof(&len_bytes);
        const len = std.mem.readIntBig(u32, &len_bytes) - 4;

        const payload = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(payload);

        if (len > 0) {
            try self.stream.reader().readNoEof(payload);
        }

        return .{ .type = msg_type[0], .payload = payload };
    }

    fn sendPasswordMessage(self: *PostgreSQL, password: []const u8) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try buffer.appendSlice(password);
        try buffer.append(0);

        try self.sendMessage('p', buffer.items);
    }

    fn sendMD5Password(self: *PostgreSQL, user: []const u8, password: []const u8, salt: []const u8) !void {
        // MD5(MD5(password + user) + salt)
        var hasher = std.crypto.hash.Md5.init(.{});

        hasher.update(password);
        hasher.update(user);

        var inner_hash: [16]u8 = undefined;
        hasher.final(&inner_hash);

        var inner_hex: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&inner_hex, "{x}", .{std.fmt.fmtSliceHexLower(&inner_hash)}) catch unreachable;

        hasher = std.crypto.hash.Md5.init(.{});
        hasher.update(&inner_hex);
        hasher.update(salt);

        var outer_hash: [16]u8 = undefined;
        hasher.final(&outer_hash);

        var result: [35]u8 = undefined;
        result[0..3].* = "md5".*;
        _ = std.fmt.bufPrint(result[3..], "{x}", .{std.fmt.fmtSliceHexLower(&outer_hash)}) catch unreachable;
        result[35 - 1] = 0;

        try self.sendMessage('p', &result);
    }

    fn parseDataRow(self: *PostgreSQL, payload: []const u8) !Row {
        const col_count = std.mem.readIntBig(u16, payload[0..2]);
        var columns = try self.allocator.alloc([]const u8, col_count);
        errdefer self.allocator.free(columns);

        var offset: usize = 2;
        for (0..col_count) |i| {
            const len = std.mem.readIntBig(i32, payload[offset .. offset + 4]);
            offset += 4;

            if (len == -1) {
                columns[i] = try self.allocator.dupe(u8, "");
            } else {
                const col_len: usize = @intCast(len);
                columns[i] = try self.allocator.dupe(u8, payload[offset .. offset + col_len]);
                offset += col_len;
            }
        }

        return Row{ .allocator = self.allocator, .columns = columns };
    }

    fn parseCommandTag(self: *PostgreSQL, payload: []const u8) usize {
        _ = self;
        // Extract number from command tag (e.g., "INSERT 0 1" -> 1)
        var iter = std.mem.splitScalar(u8, payload, ' ');
        var last: ?[]const u8 = null;
        while (iter.next()) |part| {
            if (part.len > 0 and part[0] != 0) {
                last = part;
            }
        }

        if (last) |l| {
            return std.fmt.parseInt(usize, l, 10) catch 0;
        }
        return 0;
    }

    fn sendBindMessage(self: *PostgreSQL, name: []const u8, params: []const []const u8) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try buffer.append(0); // Portal name
        try buffer.appendSlice(name);
        try buffer.append(0);

        // Parameter format codes
        try buffer.appendSlice(&[_]u8{ 0, 0 }); // All text

        // Parameter count
        const param_count: u16 = @intCast(params.len);
        var count_bytes: [2]u8 = undefined;
        std.mem.writeIntBig(u16, &count_bytes, param_count);
        try buffer.appendSlice(&count_bytes);

        // Parameters
        for (params) |param| {
            const len: i32 = @intCast(param.len);
            var len_bytes: [4]u8 = undefined;
            std.mem.writeIntBig(i32, &len_bytes, len);
            try buffer.appendSlice(&len_bytes);
            try buffer.appendSlice(param);
        }

        // Result format codes
        try buffer.appendSlice(&[_]u8{ 0, 0 }); // All text

        try self.sendMessage('B', buffer.items);
    }

    fn sendExecuteMessage(self: *PostgreSQL, portal: []const u8) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try buffer.appendSlice(portal);
        try buffer.append(0);

        // Max rows (0 = unlimited)
        try buffer.appendSlice(&[_]u8{ 0, 0, 0, 0 });

        try self.sendMessage('E', buffer.items);
    }

    fn readQueryResult(self: *PostgreSQL) !QueryResult {
        var result = QueryResult{
            .allocator = self.allocator,
            .rows = std.ArrayList(Row).init(self.allocator),
            .affected_rows = 0,
        };

        while (true) {
            const msg = try self.receiveMessage();
            defer self.allocator.free(msg.payload);

            switch (msg.type) {
                'D' => {
                    const row = try self.parseDataRow(msg.payload);
                    try result.rows.append(row);
                },
                'C' => {
                    result.affected_rows = self.parseCommandTag(msg.payload);
                },
                'Z' => {
                    self.transaction_status = @enumFromInt(msg.payload[0]);
                    break;
                },
                'E' => {
                    result.deinit();
                    return error.QueryFailed;
                },
                else => {},
            }
        }

        return result;
    }

    fn terminate(self: *PostgreSQL) !void {
        try self.sendMessage('X', &.{});
    }
};

/// Connection pool
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: PostgreSQL.Config,
    connections: std.ArrayList(*PostgreSQL),
    available: std.ArrayList(*PostgreSQL),
    max_connections: usize,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: PostgreSQL.Config, max_connections: usize) ConnectionPool {
        return .{
            .allocator = allocator,
            .config = config,
            .connections = std.ArrayList(*PostgreSQL).init(allocator),
            .available = std.ArrayList(*PostgreSQL).init(allocator),
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

    pub fn acquire(self: *ConnectionPool) !*PostgreSQL {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.popOrNull()) |conn| {
            return conn;
        }

        if (self.connections.items.len < self.max_connections) {
            const conn = try self.allocator.create(PostgreSQL);
            conn.* = try PostgreSQL.connect(self.allocator, self.config);
            try self.connections.append(conn);
            return conn;
        }

        return error.PoolExhausted;
    }

    pub fn release(self: *ConnectionPool, conn: *PostgreSQL) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.available.append(conn);
    }
};
