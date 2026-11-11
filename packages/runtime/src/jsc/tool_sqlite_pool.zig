//! SQLite handles owned by one repository-tool context/owner thread.
//! Uses Home's existing native SQLite substrate; no JavaScript SQL evaluator.
const std = @import("std");
const sql = @import("tool_sqlite_native");
const Db = @FieldType(sql.Connection, "db");
const Stmt = @FieldType(sql.Statement, "stmt");
extern "c" fn sqlite3_open_v2([*:0]const u8, *Db, c_int, ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close_v2(Db) c_int;
extern "c" fn sqlite3_prepare_v2(Db, [*c]const u8, c_int, *Stmt, ?*[*c]const u8) c_int;
extern "c" fn sqlite3_extended_errcode(Db) c_int;
extern "c" fn sqlite3_error_offset(Db) c_int;
extern "c" fn sqlite3_get_autocommit(Db) c_int;
extern "c" fn sqlite3_stmt_readonly(Stmt) c_int;
extern "c" fn sqlite3_bind_parameter_name(Stmt, c_int) [*c]const u8;
extern "c" fn sqlite3_expanded_sql(Stmt) [*c]u8;
extern "c" fn sqlite3_free(?*anyopaque) void;
extern "c" fn sqlite3_total_changes64(Db) i64;
extern "c" fn sqlite3_changes64(Db) i64;

pub const Cell = struct { kind: enum { null_value, integer, real, text, blob }, value: []const u8 = "" };
pub const Named = struct { name: []const u8, value: Cell };
pub const Bindings = struct { specified: bool = false, strict: bool = false, values: ?[]const Cell = null, named: ?[]const Named = null };
pub const Request = struct {
    op: enum { open, close, prepare, finalize, execute, exec, begin, next, reset, info, statement_info },
    database: u64 = 0,
    statement: u64 = 0,
    path: []const u8 = ":memory:",
    flags: c_int = 6,
    sql: []const u8 = "",
    cached: bool = false,
    force: bool = false,
    bindings: Bindings = .{},
    mode: enum { all, get, run } = .all,
};
pub const Response = struct {
    id: ?u64 = null,
    columns: ?[]const []const u8 = null,
    names: ?[]const ?[]const u8 = null,
    readonly: ?bool = null,
    reader: ?bool = null,
    in_transaction: ?bool = null,
    rows: ?[]const []const Cell = null,
    changes: i64 = 0,
    last_insert_rowid: []const u8 = "0",
    expanded: ?[]const u8 = null,
};
pub const Failure = struct { number: c_int = 0, offset: c_int = -1, message: []u8 };
const Database = struct { id: u64, connection: sql.Connection, closing: bool = false };
const Statement = struct { id: u64, database: u64, statement: sql.Statement, cached: bool };

pub const Pool = struct {
    allocator: std.mem.Allocator,
    databases: std.ArrayList(Database) = .empty,
    statements: std.ArrayList(Statement) = .empty,
    next_id: u64 = 1,
    failure: ?Failure = null,

    pub fn init(allocator: std.mem.Allocator) Pool {
        return .{ .allocator = allocator };
    }
    pub fn clearFailure(self: *Pool) void {
        if (self.failure) |f| self.allocator.free(f.message);
        self.failure = null;
    }
    pub fn deinit(self: *Pool) void {
        while (self.statements.items.len > 0) self.finalize(self.statements.items[self.statements.items.len - 1].id);
        for (self.databases.items) |*entry| if (!entry.closing) entry.connection.close();
        self.statements.deinit(self.allocator);
        self.databases.deinit(self.allocator);
        self.clearFailure();
    }
    fn database(self: *Pool, id: u64, allow_closing: bool) !*Database {
        for (self.databases.items) |*entry| if (entry.id == id and (allow_closing or !entry.closing)) return entry;
        return error.ClosedDatabase;
    }
    fn statement(self: *Pool, id: u64) !*Statement {
        for (self.statements.items) |*entry| if (entry.id == id) return entry;
        return error.FinalizedStatement;
    }
    fn token(self: *Pool) !u64 {
        if (self.next_id >= 0x1fffffffffffff) return error.HandleLimit;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
    fn sqliteFailure(self: *Pool, connection: *sql.Connection) anyerror {
        self.clearFailure();
        self.failure = .{ .number = sqlite3_extended_errcode(connection.db), .offset = sqlite3_error_offset(connection.db), .message = self.allocator.dupe(u8, connection.getErrorMessage()) catch return error.OutOfMemory };
        return error.SQLite;
    }
    fn argumentFailure(self: *Pool, comptime format: []const u8, args: anytype) anyerror {
        self.clearFailure();
        self.failure = .{ .message = std.fmt.allocPrint(self.allocator, format, args) catch return error.OutOfMemory };
        return error.Argument;
    }
    pub fn finalize(self: *Pool, id: u64) void {
        for (self.statements.items, 0..) |*entry, index| {
            if (entry.id != id) continue;
            const db_id = entry.database;
            entry.statement.finalize();
            _ = self.statements.swapRemove(index);
            self.removeZombie(db_id);
            return;
        }
    }
    fn removeZombie(self: *Pool, id: u64) void {
        for (self.databases.items, 0..) |*entry, index| {
            if (entry.id != id or !entry.closing) continue;
            for (self.statements.items) |s| if (s.database == id) return;
            // close_v2 released the connection when its last statement finalized.
            entry.connection.db = null;
            _ = self.databases.swapRemove(index);
            return;
        }
    }
    fn info(allocator: std.mem.Allocator, statement_value: *sql.Statement) !Response {
        const count: usize = @intCast(statement_value.columnCount());
        const columns = try allocator.alloc([]const u8, count);
        for (columns, 0..) |*name, index| name.* = try allocator.dupe(u8, statement_value.columnName(@intCast(index)));
        const names = try allocator.alloc(?[]const u8, @intCast(statement_value.paramCount()));
        for (names, 1..) |*name, index| {
            const pointer = sqlite3_bind_parameter_name(statement_value.stmt, @intCast(index));
            name.* = if (pointer == null) null else try allocator.dupe(u8, std.mem.span(pointer));
        }
        return .{ .columns = columns, .names = names, .readonly = sqlite3_stmt_readonly(statement_value.stmt) != 0, .reader = count > 0 };
    }
    fn wrapInteger(text: []const u8) !i64 {
        if (text.len == 0) return error.InvalidBinding;
        const negative = text[0] == '-';
        const digits = if (negative) text[1..] else text;
        if (digits.len == 0) return error.InvalidBinding;
        var value: u64 = 0;
        for (digits) |digit| {
            if (digit < '0' or digit > '9') return error.InvalidBinding;
            value = value *% 10 +% (digit - '0');
        }
        return @bitCast(if (negative) @as(u64, 0) -% value else value);
    }
    fn bindOne(self: *Pool, allocator: std.mem.Allocator, connection: *sql.Connection, prepared: *sql.Statement, index: c_int, cell: Cell) !void {
        (switch (cell.kind) {
            .null_value => prepared.bindNull(index),
            .integer => prepared.bindInt(index, try wrapInteger(cell.value)),
            .real => prepared.bindDouble(index, std.fmt.parseFloat(f64, cell.value) catch return error.InvalidBinding),
            .text => prepared.bindText(index, cell.value),
            .blob => blob: {
                if (cell.value.len % 2 != 0) return error.InvalidBinding;
                const bytes = try allocator.alloc(u8, cell.value.len / 2);
                _ = std.fmt.hexToBytes(bytes, cell.value) catch return error.InvalidBinding;
                break :blob prepared.bindBlob(index, bytes);
            },
        }) catch return self.sqliteFailure(connection);
    }
    fn bind(self: *Pool, allocator: std.mem.Allocator, connection: *sql.Connection, prepared: *sql.Statement, bindings: Bindings) !void {
        if (!bindings.specified) return;
        const count: usize = @intCast(prepared.paramCount());
        if (bindings.values) |values| {
            if (values.len == 0 and count > 0) {
                var all_named = true;
                for (1..count + 1) |index| if (sqlite3_bind_parameter_name(prepared.stmt, @intCast(index)) == null) {
                    all_named = false;
                    break;
                };
                if (all_named) return self.bind(allocator, connection, prepared, .{ .specified = true, .strict = bindings.strict, .named = &.{} });
            }
            if (values.len != count) return self.argumentFailure("SQLite query expected {d} values, received {d}", .{ count, values.len });
            try prepared.clearBindings();
            for (values, 1..) |value, index| try self.bindOne(allocator, connection, prepared, @intCast(index), value);
        } else if (bindings.named) |pairs| {
            try prepared.clearBindings();
            for (1..count + 1) |index| {
                const raw = sqlite3_bind_parameter_name(prepared.stmt, @intCast(index));
                const name = if (raw != null) std.mem.span(raw) else "";
                const bare = if (name.len > 0 and std.mem.indexOfScalar(u8, "$:@", name[0]) != null) name[1..] else name;
                var found: ?Cell = null;
                for (pairs) |pair| if (std.mem.eql(u8, pair.name, name) or (bare.len > 0 and std.mem.eql(u8, pair.name, bare))) {
                    found = pair.value;
                    break;
                };
                if (found) |value| try self.bindOne(allocator, connection, prepared, @intCast(index), value) else if (bindings.strict) return self.argumentFailure("Missing parameter \"{s}\"", .{bare});
            }
        }
    }
    fn row(allocator: std.mem.Allocator, prepared: *sql.Statement) ![]Cell {
        const cells = try allocator.alloc(Cell, @intCast(prepared.columnCount()));
        for (cells, 0..) |*cell, i| {
            const index: c_int = @intCast(i);
            cell.* = switch (prepared.columnType(index)) {
                1 => .{ .kind = .integer, .value = try std.fmt.allocPrint(allocator, "{d}", .{prepared.columnInt(index)}) },
                2 => .{ .kind = .real, .value = if (std.math.isInf(prepared.columnDouble(index)))
                    (if (prepared.columnDouble(index) < 0) "-Infinity" else "Infinity")
                else
                    try std.fmt.allocPrint(allocator, "{d}", .{prepared.columnDouble(index)}) },
                // Hex preserves embedded NUL and malformed UTF-8 until the JS
                // decoder performs its specified replacement conversion.
                3 => .{ .kind = .text, .value = try std.fmt.allocPrint(allocator, "{x}", .{try prepared.columnText(index)}) },
                4 => .{ .kind = .blob, .value = try std.fmt.allocPrint(allocator, "{x}", .{prepared.columnBlob(index)}) },
                else => .{ .kind = .null_value },
            };
        }
        return cells;
    }
    fn step(self: *Pool, connection: *sql.Connection, prepared: *sql.Statement) !bool {
        return prepared.step() catch return self.sqliteFailure(connection);
    }
    pub fn perform(self: *Pool, allocator: std.mem.Allocator, request: Request) !Response {
        self.clearFailure();
        switch (request.op) {
            .open => {
                if (std.mem.indexOfScalar(u8, request.path, 0) != null) return error.InvalidPath;
                try self.databases.ensureUnusedCapacity(self.allocator, 1);
                const path = try allocator.allocSentinel(u8, request.path.len, 0);
                @memcpy(path, request.path);
                var connection = sql.Connection{ .allocator = self.allocator, .db = null };
                if (sqlite3_open_v2(path.ptr, &connection.db, request.flags | 0x10000 | 0x40, null) != 0) {
                    defer connection.close();
                    return self.sqliteFailure(&connection);
                }
                errdefer connection.close();
                const id = try self.token();
                self.databases.appendAssumeCapacity(.{ .id = id, .connection = connection });
                return .{ .id = id };
            },
            .close => {
                // Query-cache statements belong to the database. Explicit
                // prepare() statements can outlive close(false), as SQLite's
                // close_v2 zombie-connection contract permits.
                var i: usize = 0;
                while (i < self.statements.items.len) {
                    const entry = self.statements.items[i];
                    if (entry.database == request.database and (request.force or entry.cached)) self.finalize(entry.id) else i += 1;
                }
                const database_value = self.database(request.database, true) catch return .{};
                if (!database_value.closing) {
                    if (sqlite3_close_v2(database_value.connection.db) != 0) return self.sqliteFailure(&database_value.connection);
                    database_value.closing = true;
                }
                self.removeZombie(request.database);
                return .{};
            },
            .prepare => {
                const db = try self.database(request.database, false);
                try self.statements.ensureUnusedCapacity(self.allocator, 1);
                var prepared = db.connection.prepare(request.sql) catch return self.sqliteFailure(&db.connection);
                errdefer prepared.finalize();
                if (prepared.stmt == null) return error.EmptySQL;
                var result = try info(allocator, &prepared);
                const id = try self.token();
                result.id = id;
                self.statements.appendAssumeCapacity(.{ .id = id, .database = request.database, .statement = prepared, .cached = request.cached });
                return result;
            },
            .finalize => {
                self.finalize(request.statement);
                return .{};
            },
            .info => {
                const db = try self.database(request.database, false);
                return .{ .in_transaction = sqlite3_get_autocommit(db.connection.db) == 0 };
            },
            .statement_info => {
                const entry = try self.statement(request.statement);
                var result = try info(allocator, &entry.statement);
                const expanded = sqlite3_expanded_sql(entry.statement.stmt);
                if (expanded != null) {
                    defer sqlite3_free(expanded);
                    result.expanded = try allocator.dupe(u8, std.mem.span(expanded));
                }
                return result;
            },
            .reset => {
                const entry = try self.statement(request.statement);
                entry.statement.reset() catch {};
                return .{};
            },
            .begin, .execute, .next => {
                const entry = try self.statement(request.statement);
                const db = try self.database(entry.database, true);
                const prepared = &entry.statement;
                if (request.op != .next) {
                    prepared.reset() catch {};
                    try self.bind(allocator, &db.connection, prepared, request.bindings);
                }
                if (request.op == .begin) return .{};
                const total_before = sqlite3_total_changes64(db.connection.db);
                defer if (request.op == .execute) {
                    prepared.reset() catch {};
                };
                var rows: std.ArrayList([]Cell) = .empty;
                var bytes: usize = 0;
                while (try self.step(&db.connection, prepared)) {
                    if (request.mode != .run) {
                        const cells = try row(allocator, prepared);
                        for (cells) |cell| bytes += @sizeOf(Cell) + cell.value.len;
                        if (bytes > 32 * 1024 * 1024 or rows.items.len >= 100000) return error.ResultLimit;
                        try rows.append(allocator, cells);
                    }
                    if (request.op == .next or request.mode == .get) break;
                }
                var result = try info(allocator, prepared);
                result.rows = rows.items;
                result.changes = if (sqlite3_total_changes64(db.connection.db) != total_before) sqlite3_changes64(db.connection.db) else 0;
                result.last_insert_rowid = try std.fmt.allocPrint(allocator, "{d}", .{db.connection.lastInsertId()});
                return result;
            },
            .exec => {
                const db = try self.database(request.database, false);
                const text = try allocator.allocSentinel(u8, request.sql.len, 0);
                @memcpy(text, request.sql);
                var offset: usize = 0;
                var changes: i64 = 0;
                var first = true;
                while (offset < text.len and text[offset] != 0) {
                    var raw: Stmt = null;
                    var tail: [*c]const u8 = null;
                    if (sqlite3_prepare_v2(db.connection.db, text.ptr + offset, -1, &raw, &tail) != 0) return self.sqliteFailure(&db.connection);
                    if (tail == null) return error.InvalidSQL;
                    const next = @intFromPtr(tail) - @intFromPtr(text.ptr);
                    if (next <= offset) return error.InvalidSQL;
                    offset = next;
                    if (raw == null) continue;
                    var prepared = sql.Statement{ .stmt = raw, .allocator = self.allocator };
                    defer prepared.finalize();
                    if (first) try self.bind(allocator, &db.connection, &prepared, request.bindings);
                    first = false;
                    const before = sqlite3_total_changes64(db.connection.db);
                    while (try self.step(&db.connection, &prepared)) {}
                    if (sqlite3_total_changes64(db.connection.db) != before) changes += sqlite3_changes64(db.connection.db);
                }
                return .{ .changes = changes, .last_insert_rowid = try std.fmt.allocPrint(allocator, "{d}", .{db.connection.lastInsertId()}) };
            },
        }
    }
};

test "native SQLite executes rows bindings changes and real constraint failures" {
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = (try pool.perform(a, .{ .op = .open })).id.?;
    const created = try pool.perform(a, .{ .op = .exec, .database = db, .sql = "CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT UNIQUE); INSERT INTO items(value) VALUES ('one'); INSERT INTO items(value) VALUES ('two')" });
    try std.testing.expectEqual(@as(i64, 2), created.changes);
    const stmt = (try pool.perform(a, .{ .op = .prepare, .database = db, .sql = "SELECT id, value FROM items WHERE id > ? ORDER BY id" })).id.?;
    const result = try pool.perform(a, .{ .op = .execute, .statement = stmt, .bindings = .{ .specified = true, .values = &.{.{ .kind = .integer, .value = "0" }} } });
    try std.testing.expectEqual(@as(usize, 2), result.rows.?.len);
    try std.testing.expectEqualStrings("1", result.rows.?[0][0].value);
    try std.testing.expectEqualStrings("6f6e65", result.rows.?[0][1].value);
    try std.testing.expectError(error.SQLite, pool.perform(a, .{ .op = .exec, .database = db, .sql = "INSERT INTO items(value) VALUES ('one')" }));
    try std.testing.expectEqual(@as(c_int, 2067), pool.failure.?.number);
    try std.testing.expect(std.mem.indexOf(u8, pool.failure.?.message, "UNIQUE") != null);
}

test "native SQLite preserves explicit statements after close and rejects stale tokens" {
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = (try pool.perform(a, .{ .op = .open })).id.?;
    const cached = (try pool.perform(a, .{ .op = .prepare, .database = db, .sql = "SELECT 1", .cached = true })).id.?;
    const explicit = (try pool.perform(a, .{ .op = .prepare, .database = db, .sql = "SELECT 2" })).id.?;
    _ = try pool.perform(a, .{ .op = .close, .database = db });
    try std.testing.expectError(error.ClosedDatabase, pool.perform(a, .{ .op = .prepare, .database = db, .sql = "SELECT 3" }));
    try std.testing.expectError(error.FinalizedStatement, pool.perform(a, .{ .op = .execute, .statement = cached }));
    const result = try pool.perform(a, .{ .op = .execute, .statement = explicit });
    try std.testing.expectEqualStrings("2", result.rows.?[0][0].value);
    _ = try pool.perform(a, .{ .op = .finalize, .statement = explicit });
    try std.testing.expectEqual(@as(usize, 0), pool.databases.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.statements.items.len);
    const next = (try pool.perform(a, .{ .op = .open })).id.?;
    try std.testing.expect(next > explicit);
}

fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    var pool = Pool.init(allocator);
    defer pool.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = (try pool.perform(a, .{ .op = .open })).id.?;
    _ = try pool.perform(a, .{ .op = .exec, .database = db, .sql = "CREATE TABLE x(v BLOB)" });
    const statement_id = (try pool.perform(a, .{ .op = .prepare, .database = db, .sql = "INSERT INTO x VALUES(?)" })).id.?;
    _ = try pool.perform(a, .{ .op = .execute, .statement = statement_id, .mode = .run, .bindings = .{ .specified = true, .values = &.{.{ .kind = .blob, .value = "0001ff" }} } });
    _ = try pool.perform(a, .{ .op = .close, .database = db, .force = true });
}

test "native SQLite allocation failures retain no context-owned handles" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}
