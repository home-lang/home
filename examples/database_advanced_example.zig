const std = @import("std");
const database = @import("database");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Ion Database Client - Advanced Features ===\n\n", .{});

    // Example 1: Basic Connection & Transactions
    try exampleTransactions(allocator);

    // Example 2: Query Builder - INSERT, UPDATE, DELETE
    try exampleQueryBuilder(allocator);

    // Example 3: Connection Pool
    try exampleConnectionPool(allocator);

    // Example 4: BLOB Support
    try exampleBlobSupport(allocator);

    // Example 5: Table Existence Check
    try exampleTableCheck(allocator);

    std.debug.print("\n=== All Examples Completed Successfully! ===\n\n", .{});
}

fn exampleTransactions(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Example 1: Transactions ---\n", .{});

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    // Create table
    try conn.exec("CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT, balance INTEGER)");
    try conn.exec("INSERT INTO accounts VALUES (1, 'Alice', 1000)");
    try conn.exec("INSERT INTO accounts VALUES (2, 'Bob', 500)");

    // Transaction with auto-rollback on error
    try conn.transaction(struct {
        fn transfer(c: *database.Connection) !void {
            // Transfer $100 from Alice to Bob
            try c.exec("UPDATE accounts SET balance = balance - 100 WHERE id = 1");
            try c.exec("UPDATE accounts SET balance = balance + 100 WHERE id = 2");
        }
    }.transfer);

    // Verify transaction
    var result = try conn.query("SELECT name, balance FROM accounts ORDER BY id");
    defer result.deinit();

    std.debug.print("After transaction:\n", .{});
    while (try result.next()) |row| {
        const name = try row.getText(0);
        const balance = row.getInt(1);
        std.debug.print("  {s}: ${d}\n", .{ name, balance });
    }
    std.debug.print("\n", .{});
}

fn exampleQueryBuilder(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Example 2: Query Builder (INSERT/UPDATE/DELETE) ---\n", .{});

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE products (id INTEGER, name TEXT, price REAL, stock INTEGER)");

    // INSERT using query builder
    {
        var builder = database.QueryBuilder.init(allocator);
        defer builder.deinit();

        const cols = [_][]const u8{ "id", "name", "price", "stock" };
        const vals = [_][]const u8{ "1", "'Laptop'", "999.99", "10" };

        const sql = try builder.into("products").insert(&cols, &vals).build();
        defer allocator.free(sql);

        std.debug.print("INSERT SQL: {s}\n", .{sql});
        try conn.exec(sql);
    }

    // UPDATE using query builder
    {
        var builder = database.QueryBuilder.init(allocator);
        defer builder.deinit();

        const sql = try builder
            .update("products")
            .set("stock", "15")
            .set("price", "899.99")
            .where("id = 1")
            .build();
        defer allocator.free(sql);

        std.debug.print("UPDATE SQL: {s}\n", .{sql});
        try conn.exec(sql);
    }

    // SELECT to verify
    {
        var builder = database.QueryBuilder.init(allocator);
        defer builder.deinit();

        const fields = [_][]const u8{ "name", "price", "stock" };
        const sql = try builder.from("products").select(&fields).build();
        defer allocator.free(sql);

        var result = try conn.query(sql);
        defer result.deinit();

        std.debug.print("Current products:\n", .{});
        while (try result.next()) |row| {
            const name = try row.getText(0);
            const price = row.getDouble(1);
            const stock = row.getInt(2);
            std.debug.print("  {s}: ${d:.2} (Stock: {d})\n", .{ name, price, stock });
        }
    }

    // DELETE using query builder
    {
        var builder = database.QueryBuilder.init(allocator);
        defer builder.deinit();

        const sql = try builder.deleteFrom("products").where("stock = 0").build();
        defer allocator.free(sql);

        std.debug.print("DELETE SQL: {s}\n", .{sql});
    }
    std.debug.print("\n", .{});
}

fn exampleConnectionPool(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Example 3: Connection Pool ---\n", .{});

    var pool = try database.ConnectionPool.init(allocator, ":memory:", 3);
    defer pool.deinit();

    std.debug.print("Pool created with 3 connections\n", .{});
    std.debug.print("Available connections: {d}\n", .{pool.availableCount()});

    // Acquire a connection
    const conn1 = try pool.acquire();
    std.debug.print("After acquiring 1: {d} available\n", .{pool.availableCount()});

    // Use the connection
    try conn1.exec("CREATE TABLE test (id INTEGER)");

    // Release it back
    try pool.release(conn1);
    std.debug.print("After releasing: {d} available\n", .{pool.availableCount()});

    std.debug.print("\n", .{});
}

fn exampleBlobSupport(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Example 4: BLOB Support ---\n", .{});

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE files (id INTEGER, name TEXT, data BLOB)");

    // Insert blob data
    var stmt = try conn.prepare("INSERT INTO files VALUES (?, ?, ?)");
    defer stmt.finalize();

    const blob_data = "Binary data \x00\x01\x02\xFF";
    try stmt.bindInt(1, 1);
    try stmt.bindText(2, "example.bin");
    try stmt.bindBlob(3, blob_data);
    _ = try stmt.step();

    // Read blob data
    var result = try conn.query("SELECT name, data FROM files");
    defer result.deinit();

    while (try result.next()) |row| {
        const name = try row.getText(0);
        const data = row.getBlob(1);
        std.debug.print("File: {s}, Size: {d} bytes\n", .{ name, data.len });
    }

    std.debug.print("\n", .{});
}

fn exampleTableCheck(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Example 5: Table Existence Check ---\n", .{});

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    const exists_before = try conn.tableExists("users");
    std.debug.print("Table 'users' exists: {}\n", .{exists_before});

    try conn.exec("CREATE TABLE users (id INTEGER, name TEXT)");

    const exists_after = try conn.tableExists("users");
    std.debug.print("After CREATE TABLE, 'users' exists: {}\n", .{exists_after});

    std.debug.print("\n", .{});
}
