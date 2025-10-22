const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const DatabaseError = error{
    OpenFailed,
    PrepareFailed,
    ExecuteFailed,
    BindFailed,
    StepFailed,
    FinalizeFailed,
    ColumnError,
    OutOfMemory,
} || std.mem.Allocator.Error;

/// SQLite database connection
pub const Connection = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Connection {
        var db: ?*c.sqlite3 = null;

        // Null-terminate the path
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const result = c.sqlite3_open(path_z.ptr, &db);
        if (result != c.SQLITE_OK) {
            if (db) |db_ptr| {
                _ = c.sqlite3_close(db_ptr);
            }
            return DatabaseError.OpenFailed;
        }

        return Connection{
            .db = db,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Connection) void {
        if (self.db) |db_ptr| {
            _ = c.sqlite3_close(db_ptr);
            self.db = null;
        }
    }

    pub fn exec(self: *Connection, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var err_msg: [*c]u8 = undefined;
        const result = c.sqlite3_exec(self.db, sql_z.ptr, null, null, &err_msg);

        if (result != c.SQLITE_OK) {
            if (err_msg != null) {
                c.sqlite3_free(err_msg);
            }
            return DatabaseError.ExecuteFailed;
        }
    }

    pub fn prepare(self: *Connection, sql: []const u8) !Statement {
        return Statement.prepare(self, sql);
    }

    pub fn query(self: *Connection, sql: []const u8) !QueryResult {
        const stmt = try self.prepare(sql);
        return QueryResult{
            .stmt = stmt,
            .allocator = self.allocator,
        };
    }

    pub fn lastInsertId(self: *Connection) i64 {
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub fn changesCount(self: *Connection) i32 {
        return c.sqlite3_changes(self.db);
    }

    /// Begin a transaction
    pub fn beginTransaction(self: *Connection) !void {
        try self.exec("BEGIN TRANSACTION");
    }

    /// Commit the current transaction
    pub fn commit(self: *Connection) !void {
        try self.exec("COMMIT");
    }

    /// Rollback the current transaction
    pub fn rollback(self: *Connection) !void {
        try self.exec("ROLLBACK");
    }

    /// Execute a function within a transaction (auto-rollback on error)
    pub fn transaction(self: *Connection, comptime func: fn (*Connection) anyerror!void) !void {
        try self.beginTransaction();
        errdefer self.rollback() catch {};

        try func(self);
        try self.commit();
    }

    /// Get the error message from the last operation
    pub fn getErrorMessage(self: *Connection) []const u8 {
        const msg_ptr = c.sqlite3_errmsg(self.db);
        if (msg_ptr == null) return "Unknown error";
        return std.mem.span(msg_ptr);
    }

    /// Get the total number of rows changed in the database
    pub fn totalChangesCount(self: *Connection) i32 {
        return c.sqlite3_total_changes(self.db);
    }

    /// Check if a table exists
    pub fn tableExists(self: *Connection, table_name: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            .{},
        );
        defer self.allocator.free(sql);

        var stmt = try self.prepare(sql);
        defer stmt.finalize();

        try stmt.bindText(1, table_name);
        return try stmt.step();
    }
};

/// Prepared statement
pub const Statement = struct {
    stmt: ?*c.sqlite3_stmt,
    allocator: std.mem.Allocator,

    fn prepare(conn: *Connection, sql: []const u8) !Statement {
        const sql_z = try conn.allocator.dupeZ(u8, sql);
        defer conn.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(
            conn.db,
            sql_z.ptr,
            -1,
            &stmt,
            null,
        );

        if (result != c.SQLITE_OK) {
            return DatabaseError.PrepareFailed;
        }

        return Statement{
            .stmt = stmt,
            .allocator = conn.allocator,
        };
    }

    pub fn finalize(self: *Statement) void {
        if (self.stmt) |stmt_ptr| {
            _ = c.sqlite3_finalize(stmt_ptr);
            self.stmt = null;
        }
    }

    pub fn reset(self: *Statement) !void {
        const result = c.sqlite3_reset(self.stmt);
        if (result != c.SQLITE_OK) {
            return DatabaseError.StepFailed;
        }
    }

    pub fn bindInt(self: *Statement, index: c_int, value: i64) !void {
        const result = c.sqlite3_bind_int64(self.stmt, index, value);
        if (result != c.SQLITE_OK) {
            return DatabaseError.BindFailed;
        }
    }

    pub fn bindText(self: *Statement, index: c_int, value: []const u8) !void {
        // Use SQLITE_STATIC (0)
        const result = c.sqlite3_bind_text(
            self.stmt,
            index,
            value.ptr,
            @intCast(value.len),
            @ptrFromInt(0), // SQLITE_STATIC
        );
        if (result != c.SQLITE_OK) {
            return DatabaseError.BindFailed;
        }
    }

    pub fn bindDouble(self: *Statement, index: c_int, value: f64) !void {
        const result = c.sqlite3_bind_double(self.stmt, index, value);
        if (result != c.SQLITE_OK) {
            return DatabaseError.BindFailed;
        }
    }

    pub fn bindNull(self: *Statement, index: c_int) !void {
        const result = c.sqlite3_bind_null(self.stmt, index);
        if (result != c.SQLITE_OK) {
            return DatabaseError.BindFailed;
        }
    }

    pub fn bindBlob(self: *Statement, index: c_int, value: []const u8) !void {
        const result = c.sqlite3_bind_blob(
            self.stmt,
            index,
            value.ptr,
            @intCast(value.len),
            @ptrFromInt(0), // SQLITE_STATIC
        );
        if (result != c.SQLITE_OK) {
            return DatabaseError.BindFailed;
        }
    }

    /// Clear all bindings on the prepared statement
    pub fn clearBindings(self: *Statement) !void {
        const result = c.sqlite3_clear_bindings(self.stmt);
        if (result != c.SQLITE_OK) {
            return DatabaseError.BindFailed;
        }
    }

    /// Get the number of parameters in the prepared statement
    pub fn paramCount(self: *Statement) i32 {
        return c.sqlite3_bind_parameter_count(self.stmt);
    }

    pub fn step(self: *Statement) !bool {
        const result = c.sqlite3_step(self.stmt);
        return switch (result) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => DatabaseError.StepFailed,
        };
    }

    pub fn columnCount(self: *Statement) i32 {
        return c.sqlite3_column_count(self.stmt);
    }

    pub fn columnInt(self: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, index);
    }

    pub fn columnDouble(self: *Statement, index: c_int) f64 {
        return c.sqlite3_column_double(self.stmt, index);
    }

    pub fn columnText(self: *Statement, index: c_int) ![]const u8 {
        const text_ptr = c.sqlite3_column_text(self.stmt, index);
        if (text_ptr == null) {
            return "";
        }

        const len = c.sqlite3_column_bytes(self.stmt, index);
        return text_ptr[0..@intCast(len)];
    }

    pub fn columnName(self: *Statement, index: c_int) []const u8 {
        const name_ptr = c.sqlite3_column_name(self.stmt, index);
        if (name_ptr == null) {
            return "";
        }
        return std.mem.span(name_ptr);
    }

    pub fn columnBlob(self: *Statement, index: c_int) []const u8 {
        const blob_ptr = c.sqlite3_column_blob(self.stmt, index);
        if (blob_ptr == null) {
            return &[_]u8{};
        }
        const len = c.sqlite3_column_bytes(self.stmt, index);
        const bytes: [*c]const u8 = @ptrCast(blob_ptr);
        return bytes[0..@intCast(len)];
    }

    pub fn columnType(self: *Statement, index: c_int) i32 {
        return c.sqlite3_column_type(self.stmt, index);
    }

    pub fn columnIsNull(self: *Statement, index: c_int) bool {
        return self.columnType(index) == c.SQLITE_NULL;
    }
};

/// Query result iterator
pub const QueryResult = struct {
    stmt: Statement,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        self.stmt.finalize();
    }

    pub fn next(self: *QueryResult) !?Row {
        const has_row = try self.stmt.step();
        if (!has_row) {
            return null;
        }

        return Row{
            .stmt = &self.stmt,
        };
    }
};

/// Database row
pub const Row = struct {
    stmt: *Statement,

    pub fn getInt(self: Row, index: c_int) i64 {
        return self.stmt.columnInt(index);
    }

    pub fn getDouble(self: Row, index: c_int) f64 {
        return self.stmt.columnDouble(index);
    }

    pub fn getText(self: Row, index: c_int) ![]const u8 {
        return try self.stmt.columnText(index);
    }

    pub fn getColumnName(self: Row, index: c_int) []const u8 {
        return self.stmt.columnName(index);
    }

    pub fn columnCount(self: Row) i32 {
        return self.stmt.columnCount();
    }

    pub fn getBlob(self: Row, index: c_int) []const u8 {
        return self.stmt.columnBlob(index);
    }

    pub fn isNull(self: Row, index: c_int) bool {
        return self.stmt.columnIsNull(index);
    }

    pub fn getType(self: Row, index: c_int) i32 {
        return self.stmt.columnType(index);
    }
};
