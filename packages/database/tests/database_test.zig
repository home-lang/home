const std = @import("std");
const testing = std.testing;
const database = @import("database");

test "database: open in-memory database" {
    const allocator = testing.allocator;

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try testing.expect(conn.db != null);
}

test "database: create table" {
    const allocator = testing.allocator;

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec(
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  email TEXT NOT NULL
        \\)
    );
}

test "database: insert data" {
    const allocator = testing.allocator;

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.exec("INSERT INTO users (name) VALUES ('Alice')");
    try conn.exec("INSERT INTO users (name) VALUES ('Bob')");

    try testing.expectEqual(@as(i32, 1), conn.changesCount());
}

test "database: query data" {
    const allocator = testing.allocator;

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.exec("INSERT INTO users (name) VALUES ('Alice')");

    var result = try conn.query("SELECT * FROM users");
    defer result.deinit();

    var count: usize = 0;
    while (try result.next()) |row| {
        count += 1;
        try testing.expectEqual(@as(i64, 1), row.getInt(0));
        const name = try row.getText(1);
        try testing.expectEqualStrings("Alice", name);
    }

    try testing.expectEqual(@as(usize, 1), count);
}

test "database: prepared statement with bindings" {
    const allocator = testing.allocator;

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var stmt = try conn.prepare("INSERT INTO users (name, age) VALUES (?, ?)");
    defer stmt.finalize();

    try stmt.bindText(1, "Charlie");
    try stmt.bindInt(2, 30);
    _ = try stmt.step();

    try stmt.reset();
    try stmt.bindText(1, "Diana");
    try stmt.bindInt(2, 25);
    _ = try stmt.step();
}

test "database: last insert ID" {
    const allocator = testing.allocator;

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)");
    try conn.exec("INSERT INTO users (name) VALUES ('Alice')");

    const last_id = conn.lastInsertId();
    try testing.expectEqual(@as(i64, 1), last_id);

    try conn.exec("INSERT INTO users (name) VALUES ('Bob')");
    const last_id2 = conn.lastInsertId();
    try testing.expectEqual(@as(i64, 2), last_id2);
}

test "database: query builder - simple select" {
    const allocator = testing.allocator;

    var builder = database.QueryBuilder.init(allocator);
    defer builder.deinit();

    const sql = try builder.from("users").build();
    defer allocator.free(sql);

    try testing.expectEqualStrings("SELECT * FROM users", sql);
}

test "database: query builder - select with fields" {
    const allocator = testing.allocator;

    var builder = database.QueryBuilder.init(allocator);
    defer builder.deinit();

    const fields = [_][]const u8{ "id", "name", "email" };
    const sql = try (try builder
        .from("users")
        .select(&fields))
        .build();
    defer allocator.free(sql);

    try testing.expectEqualStrings("SELECT id, name, email FROM users", sql);
}

test "database: query builder - where clause" {
    const allocator = testing.allocator;

    var builder = database.QueryBuilder.init(allocator);
    defer builder.deinit();

    const sql = try (try builder
        .from("users")
        .where("age > 18"))
        .build();
    defer allocator.free(sql);

    try testing.expectEqualStrings("SELECT * FROM users WHERE age > 18", sql);
}

test "database: query builder - order by" {
    const allocator = testing.allocator;

    var builder = database.QueryBuilder.init(allocator);
    defer builder.deinit();

    const sql = try builder
        .from("users")
        .orderBy("name ASC")
        .build();
    defer allocator.free(sql);

    try testing.expectEqualStrings("SELECT * FROM users ORDER BY name ASC", sql);
}

test "database: query builder - limit and offset" {
    const allocator = testing.allocator;

    var builder = database.QueryBuilder.init(allocator);
    defer builder.deinit();

    const sql = try builder
        .from("users")
        .limit(10)
        .offset(20)
        .build();
    defer allocator.free(sql);

    try testing.expectEqualStrings("SELECT * FROM users LIMIT 10 OFFSET 20", sql);
}

test "database: query builder - complex query" {
    const allocator = testing.allocator;

    var builder = database.QueryBuilder.init(allocator);
    defer builder.deinit();

    const fields = [_][]const u8{ "id", "name" };
    const sql = try (try (try (try builder
        .from("users")
        .select(&fields))
        .where("age > 18"))
        .where("active = 1"))
        .orderBy("name DESC")
        .limit(5)
        .build();
    defer allocator.free(sql);

    try testing.expectEqualStrings(
        "SELECT id, name FROM users WHERE age > 18 AND active = 1 ORDER BY name DESC LIMIT 5",
        sql,
    );
}

test "database: bind null value" {
    const allocator = testing.allocator;

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE users (id INTEGER, name TEXT, email TEXT)");

    var stmt = try conn.prepare("INSERT INTO users (id, name, email) VALUES (?, ?, ?)");
    defer stmt.finalize();

    try stmt.bindInt(1, 1);
    try stmt.bindText(2, "Alice");
    try stmt.bindNull(3); // NULL email
    _ = try stmt.step();
}

test "database: bind double value" {
    const allocator = testing.allocator;

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE products (id INTEGER, price REAL)");

    var stmt = try conn.prepare("INSERT INTO products (id, price) VALUES (?, ?)");
    defer stmt.finalize();

    try stmt.bindInt(1, 1);
    try stmt.bindDouble(2, 19.99);
    _ = try stmt.step();

    var result = try conn.query("SELECT price FROM products WHERE id = 1");
    defer result.deinit();

    if (try result.next()) |row| {
        const price = row.getDouble(0);
        try testing.expectEqual(@as(f64, 19.99), price);
    }
}

test "database: column names" {
    const allocator = testing.allocator;

    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE users (id INTEGER, name TEXT)");
    try conn.exec("INSERT INTO users VALUES (1, 'Alice')");

    var result = try conn.query("SELECT id, name FROM users");
    defer result.deinit();

    if (try result.next()) |row| {
        const col1_name = row.getColumnName(0);
        const col2_name = row.getColumnName(1);

        try testing.expectEqualStrings("id", col1_name);
        try testing.expectEqualStrings("name", col2_name);
    }
}
