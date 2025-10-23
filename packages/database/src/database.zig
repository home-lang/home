const std = @import("std");
pub const sqlite = @import("sqlite.zig");

// Re-export main SQLite types for convenience
/// Database connection handle
pub const Connection = sqlite.Connection;
/// Prepared SQL statement
pub const Statement = sqlite.Statement;
/// Result row from a query
pub const Row = sqlite.Row;
/// Query result set
pub const QueryResult = sqlite.QueryResult;
/// Database operation errors
pub const DatabaseError = sqlite.DatabaseError;

/// SQL query types supported by the query builder.
pub const QueryType = enum {
    /// SELECT query for reading data
    Select,
    /// INSERT query for adding rows
    Insert,
    /// UPDATE query for modifying rows
    Update,
    /// DELETE query for removing rows
    Delete,
};

/// Fluent SQL query builder for type-safe database queries.
///
/// The QueryBuilder provides a chainable API for constructing SQL queries
/// without writing raw SQL strings. This helps prevent SQL injection and
/// provides a more ergonomic interface.
///
/// Features:
/// - Method chaining for readable query construction
/// - Type-safe query building
/// - Automatic SQL generation
/// - Support for all common SQL clauses (WHERE, ORDER BY, LIMIT, etc.)
///
/// Example:
/// ```zig
/// var builder = QueryBuilder.init(allocator);
/// defer builder.deinit();
///
/// const query = try builder
///     .from("users")
///     .select(&.{"name", "email"})
///     .where("age > ?")
///     .orderBy("name ASC")
///     .limit(10)
///     .build();
/// ```
pub const QueryBuilder = struct {
    /// Memory allocator for query components
    allocator: std.mem.Allocator,
    /// Type of SQL query being built
    query_type: QueryType,
    /// Target table name
    table: ?[]const u8,
    /// Fields to select (SELECT queries)
    select_fields: std.ArrayList([]const u8),
    /// WHERE clause conditions
    where_conditions: std.ArrayList([]const u8),
    /// ORDER BY clause
    order_by: ?[]const u8,
    /// LIMIT value (max rows)
    limit_value: ?usize,
    /// OFFSET value (skip rows)
    offset_value: ?usize,
    // For INSERT queries
    /// Column names for INSERT
    insert_columns: std.ArrayList([]const u8),
    /// Values for INSERT
    insert_values: std.ArrayList([]const u8),
    // For UPDATE queries
    /// SET clauses for UPDATE
    update_sets: std.ArrayList([]const u8),

    /// Create a new query builder.
    ///
    /// Parameters:
    ///   - allocator: Allocator for query components
    ///
    /// Returns: Initialized QueryBuilder (defaults to SELECT)
    pub fn init(allocator: std.mem.Allocator) QueryBuilder {
        return .{
            .allocator = allocator,
            .query_type = .Select,
            .table = null,
            .select_fields = std.ArrayList([]const u8){},
            .where_conditions = std.ArrayList([]const u8){},
            .order_by = null,
            .limit_value = null,
            .offset_value = null,
            .insert_columns = std.ArrayList([]const u8){},
            .insert_values = std.ArrayList([]const u8){},
            .update_sets = std.ArrayList([]const u8){},
        };
    }

    /// Clean up query builder resources.
    ///
    /// Frees all allocated query component lists.
    pub fn deinit(self: *QueryBuilder) void {
        self.select_fields.deinit(self.allocator);
        self.where_conditions.deinit(self.allocator);
        self.insert_columns.deinit(self.allocator);
        self.insert_values.deinit(self.allocator);
        self.update_sets.deinit(self.allocator);
    }

    /// Set the source table for a SELECT query.
    ///
    /// Parameters:
    ///   - table_name: Name of the table to query
    ///
    /// Returns: Self for method chaining
    pub fn from(self: *QueryBuilder, table_name: []const u8) *QueryBuilder {
        self.table = table_name;
        return self;
    }

    /// Set the target table for an INSERT query.
    ///
    /// Changes query type to INSERT and sets the table.
    ///
    /// Parameters:
    ///   - table_name: Name of the table to insert into
    ///
    /// Returns: Self for method chaining
    pub fn into(self: *QueryBuilder, table_name: []const u8) *QueryBuilder {
        self.query_type = .Insert;
        self.table = table_name;
        return self;
    }

    /// Set the target table for an UPDATE query.
    ///
    /// Changes query type to UPDATE and sets the table.
    ///
    /// Parameters:
    ///   - table_name: Name of the table to update
    ///
    /// Returns: Self for method chaining
    pub fn update(self: *QueryBuilder, table_name: []const u8) *QueryBuilder {
        self.query_type = .Update;
        self.table = table_name;
        return self;
    }

    /// Set the target table for a DELETE query.
    ///
    /// Changes query type to DELETE and sets the table.
    ///
    /// Parameters:
    ///   - table_name: Name of the table to delete from
    ///
    /// Returns: Self for method chaining
    pub fn deleteFrom(self: *QueryBuilder, table_name: []const u8) *QueryBuilder {
        self.query_type = .Delete;
        self.table = table_name;
        return self;
    }

    pub fn select(self: *QueryBuilder, fields: []const []const u8) !*QueryBuilder {
        self.query_type = .Select;
        for (fields) |field| {
            try self.select_fields.append(self.allocator, field);
        }
        return self;
    }

    pub fn insert(self: *QueryBuilder, columns: []const []const u8, values: []const []const u8) !*QueryBuilder {
        self.query_type = .Insert;
        for (columns) |col| {
            try self.insert_columns.append(self.allocator, col);
        }
        for (values) |val| {
            try self.insert_values.append(self.allocator, val);
        }
        return self;
    }

    pub fn set(self: *QueryBuilder, column: []const u8, value: []const u8) !*QueryBuilder {
        const set_str = try std.fmt.allocPrint(self.allocator, "{s} = {s}", .{ column, value });
        try self.update_sets.append(self.allocator, set_str);
        return self;
    }

    pub fn where(self: *QueryBuilder, condition: []const u8) !*QueryBuilder {
        try self.where_conditions.append(self.allocator, condition);
        return self;
    }

    pub fn orderBy(self: *QueryBuilder, order: []const u8) *QueryBuilder {
        self.order_by = order;
        return self;
    }

    pub fn limit(self: *QueryBuilder, value: usize) *QueryBuilder {
        self.limit_value = value;
        return self;
    }

    pub fn offset(self: *QueryBuilder, value: usize) *QueryBuilder {
        self.offset_value = value;
        return self;
    }

    pub fn build(self: *QueryBuilder) ![]const u8 {
        var sql = std.ArrayList(u8){};
        defer sql.deinit(self.allocator);

        switch (self.query_type) {
            .Select => try self.buildSelect(&sql),
            .Insert => try self.buildInsert(&sql),
            .Update => try self.buildUpdate(&sql),
            .Delete => try self.buildDelete(&sql),
        }

        return try sql.toOwnedSlice(self.allocator);
    }

    fn buildSelect(self: *QueryBuilder, sql: *std.ArrayList(u8)) !void {
        // SELECT clause
        try sql.appendSlice(self.allocator, "SELECT ");
        if (self.select_fields.items.len == 0) {
            try sql.appendSlice(self.allocator, "*");
        } else {
            for (self.select_fields.items, 0..) |field, i| {
                if (i > 0) try sql.appendSlice(self.allocator, ", ");
                try sql.appendSlice(self.allocator, field);
            }
        }

        // FROM clause
        if (self.table) |table_name| {
            try sql.appendSlice(self.allocator, " FROM ");
            try sql.appendSlice(self.allocator, table_name);
        }

        try self.appendWhere(sql);
        try self.appendOrderBy(sql);
        try self.appendLimit(sql);
        try self.appendOffset(sql);
    }

    fn buildInsert(self: *QueryBuilder, sql: *std.ArrayList(u8)) !void {
        try sql.appendSlice(self.allocator, "INSERT INTO ");

        if (self.table) |table_name| {
            try sql.appendSlice(self.allocator, table_name);
        }

        // Columns
        if (self.insert_columns.items.len > 0) {
            try sql.appendSlice(self.allocator, " (");
            for (self.insert_columns.items, 0..) |col, i| {
                if (i > 0) try sql.appendSlice(self.allocator, ", ");
                try sql.appendSlice(self.allocator, col);
            }
            try sql.appendSlice(self.allocator, ")");
        }

        // Values
        if (self.insert_values.items.len > 0) {
            try sql.appendSlice(self.allocator, " VALUES (");
            for (self.insert_values.items, 0..) |val, i| {
                if (i > 0) try sql.appendSlice(self.allocator, ", ");
                try sql.appendSlice(self.allocator, val);
            }
            try sql.appendSlice(self.allocator, ")");
        }
    }

    fn buildUpdate(self: *QueryBuilder, sql: *std.ArrayList(u8)) !void {
        try sql.appendSlice(self.allocator, "UPDATE ");

        if (self.table) |table_name| {
            try sql.appendSlice(self.allocator, table_name);
        }

        // SET clause
        if (self.update_sets.items.len > 0) {
            try sql.appendSlice(self.allocator, " SET ");
            for (self.update_sets.items, 0..) |set_clause, i| {
                if (i > 0) try sql.appendSlice(self.allocator, ", ");
                try sql.appendSlice(self.allocator, set_clause);
            }
        }

        try self.appendWhere(sql);
    }

    fn buildDelete(self: *QueryBuilder, sql: *std.ArrayList(u8)) !void {
        try sql.appendSlice(self.allocator, "DELETE FROM ");

        if (self.table) |table_name| {
            try sql.appendSlice(self.allocator, table_name);
        }

        try self.appendWhere(sql);
    }

    fn appendWhere(self: *QueryBuilder, sql: *std.ArrayList(u8)) !void {
        if (self.where_conditions.items.len > 0) {
            try sql.appendSlice(self.allocator, " WHERE ");
            for (self.where_conditions.items, 0..) |cond, i| {
                if (i > 0) try sql.appendSlice(self.allocator, " AND ");
                try sql.appendSlice(self.allocator, cond);
            }
        }
    }

    fn appendOrderBy(self: *QueryBuilder, sql: *std.ArrayList(u8)) !void {
        if (self.order_by) |order| {
            try sql.appendSlice(self.allocator, " ORDER BY ");
            try sql.appendSlice(self.allocator, order);
        }
    }

    fn appendLimit(self: *QueryBuilder, sql: *std.ArrayList(u8)) !void {
        if (self.limit_value) |limit_val| {
            const limit_str = try std.fmt.allocPrint(self.allocator, " LIMIT {d}", .{limit_val});
            defer self.allocator.free(limit_str);
            try sql.appendSlice(self.allocator, limit_str);
        }
    }

    fn appendOffset(self: *QueryBuilder, sql: *std.ArrayList(u8)) !void {
        if (self.offset_value) |offset_val| {
            const offset_str = try std.fmt.allocPrint(self.allocator, " OFFSET {d}", .{offset_val});
            defer self.allocator.free(offset_str);
            try sql.appendSlice(self.allocator, offset_str);
        }
    }
};

/// Connection pool for managing multiple database connections
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayList(*Connection),
    available: std.ArrayList(*Connection),
    mutex: std.Thread.Mutex,
    max_connections: usize,
    db_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8, max_connections: usize) !ConnectionPool {
        var pool = ConnectionPool{
            .allocator = allocator,
            .connections = std.ArrayList(*Connection){},
            .available = std.ArrayList(*Connection){},
            .mutex = std.Thread.Mutex{},
            .max_connections = max_connections,
            .db_path = try allocator.dupe(u8, db_path),
        };

        // Pre-create connections
        var i: usize = 0;
        while (i < max_connections) : (i += 1) {
            const conn = try allocator.create(Connection);
            conn.* = try Connection.open(allocator, db_path);
            try pool.connections.append(allocator, conn);
            try pool.available.append(allocator, conn);
        }

        return pool;
    }

    pub fn deinit(self: *ConnectionPool) void {
        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
        self.allocator.free(self.db_path);
    }

    /// Acquire a connection from the pool
    pub fn acquire(self: *ConnectionPool) !*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.items.len == 0) {
            return error.NoAvailableConnections;
        }

        return self.available.orderedRemove(0);
    }

    /// Release a connection back to the pool
    pub fn release(self: *ConnectionPool, conn: *Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.available.append(self.allocator, conn);
    }

    /// Get the number of available connections
    pub fn availableCount(self: *ConnectionPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.available.items.len;
    }
};
