// Home Programming Language - SQLite FFI Example
// Demonstrates real-world C library integration

const std = @import("std");
const ffi = @import("ffi");

// ============================================================================
// SQLite FFI Bindings
// ============================================================================

pub const SQLite = struct {
    // SQLite types
    pub const Database = opaque {};
    pub const Statement = opaque {};
    pub const sqlite3 = Database;
    pub const sqlite3_stmt = Statement;

    // Result codes
    pub const SQLITE_OK = 0;
    pub const SQLITE_ROW = 100;
    pub const SQLITE_DONE = 101;
    pub const SQLITE_ERROR = 1;

    // SQLite Functions
    pub extern "c" fn sqlite3_open(
        filename: [*:0]const u8,
        ppDb: *?*sqlite3,
    ) ffi.c_int;

    pub extern "c" fn sqlite3_close(db: ?*sqlite3) ffi.c_int;

    pub extern "c" fn sqlite3_prepare_v2(
        db: ?*sqlite3,
        zSql: [*:0]const u8,
        nByte: ffi.c_int,
        ppStmt: *?*sqlite3_stmt,
        pzTail: ?*[*:0]const u8,
    ) ffi.c_int;

    pub extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) ffi.c_int;

    pub extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) ffi.c_int;

    pub extern "c" fn sqlite3_column_int(stmt: ?*sqlite3_stmt, iCol: ffi.c_int) ffi.c_int;

    pub extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: ffi.c_int) [*:0]const u8;

    pub extern "c" fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;

    pub extern "c" fn sqlite3_exec(
        db: ?*sqlite3,
        sql: [*:0]const u8,
        callback: ?*const fn (
            ?*anyopaque,
            ffi.c_int,
            [*c][*c]u8,
            [*c][*c]u8,
        ) callconv(.C) ffi.c_int,
        arg: ?*anyopaque,
        errmsg: ?*[*:0]u8,
    ) ffi.c_int;
};

// ============================================================================
// Home-style SQLite Wrapper
// ============================================================================

pub const DB = struct {
    db: ?*SQLite.sqlite3,

    pub fn open(path: []const u8, allocator: std.mem.Allocator) !DB {
        const c_path = try ffi.CString.fromHome(allocator, path);
        defer allocator.free(c_path);

        var db: ?*SQLite.sqlite3 = null;
        const result = SQLite.sqlite3_open(c_path, &db);

        if (result != SQLite.SQLITE_OK) {
            return error.OpenFailed;
        }

        return DB{ .db = db };
    }

    pub fn close(self: *DB) void {
        _ = SQLite.sqlite3_close(self.db);
        self.db = null;
    }

    pub fn exec(self: *DB, sql: []const u8, allocator: std.mem.Allocator) !void {
        const c_sql = try ffi.CString.fromHome(allocator, sql);
        defer allocator.free(c_sql);

        const result = SQLite.sqlite3_exec(self.db, c_sql, null, null, null);

        if (result != SQLite.SQLITE_OK) {
            const err_msg = SQLite.sqlite3_errmsg(self.db);
            std.debug.print("SQL error: {s}\n", .{ffi.CString.toHome(err_msg)});
            return error.ExecFailed;
        }
    }

    pub fn prepare(self: *DB, sql: []const u8, allocator: std.mem.Allocator) !Statement {
        const c_sql = try ffi.CString.fromHome(allocator, sql);
        defer allocator.free(c_sql);

        var stmt: ?*SQLite.sqlite3_stmt = null;
        const result = SQLite.sqlite3_prepare_v2(
            self.db,
            c_sql,
            @intCast(sql.len),
            &stmt,
            null,
        );

        if (result != SQLite.SQLITE_OK) {
            return error.PrepareFailed;
        }

        return Statement{ .stmt = stmt };
    }
};

pub const Statement = struct {
    stmt: ?*SQLite.sqlite3_stmt,

    pub fn step(self: *Statement) !bool {
        const result = SQLite.sqlite3_step(self.stmt);

        if (result == SQLite.SQLITE_ROW) {
            return true;
        } else if (result == SQLite.SQLITE_DONE) {
            return false;
        } else {
            return error.StepFailed;
        }
    }

    pub fn columnInt(self: *Statement, col: i32) i32 {
        return SQLite.sqlite3_column_int(self.stmt, col);
    }

    pub fn columnText(self: *Statement, col: i32) []const u8 {
        const c_str = SQLite.sqlite3_column_text(self.stmt, col);
        return ffi.CString.toHome(c_str);
    }

    pub fn finalize(self: *Statement) void {
        _ = SQLite.sqlite3_finalize(self.stmt);
        self.stmt = null;
    }
};

// ============================================================================
// Example Usage
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open database
    var db = try DB.open(":memory:", allocator);
    defer db.close();

    std.debug.print("✓ Database opened\n", .{});

    // Create table
    try db.exec(
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  age INTEGER
        \\)
    , allocator);

    std.debug.print("✓ Table created\n", .{});

    // Insert data
    try db.exec("INSERT INTO users (name, age) VALUES ('Alice', 30)", allocator);
    try db.exec("INSERT INTO users (name, age) VALUES ('Bob', 25)", allocator);
    try db.exec("INSERT INTO users (name, age) VALUES ('Charlie', 35)", allocator);

    std.debug.print("✓ Data inserted\n", .{});

    // Query data
    var stmt = try db.prepare("SELECT id, name, age FROM users", allocator);
    defer stmt.finalize();

    std.debug.print("\nUsers:\n", .{});
    std.debug.print("ID | Name    | Age\n", .{});
    std.debug.print("---|---------|----\n", .{});

    while (try stmt.step()) {
        const id = stmt.columnInt(0);
        const name = stmt.columnText(1);
        const age = stmt.columnInt(2);

        std.debug.print("{d:2} | {s:7} | {d}\n", .{ id, name, age });
    }

    std.debug.print("\n✓ FFI Example Complete!\n", .{});
}
