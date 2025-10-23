const std = @import("std");
const database = @import("database");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Home Database (SQLite) Example ===\n\n", .{});

    // Example 1: Open in-memory database
    std.debug.print("1. Opening in-memory database...\n", .{});
    var conn = try database.Connection.open(allocator, ":memory:");
    defer conn.close();
    std.debug.print("   Database opened successfully\n\n", .{});

    // Example 2: Create tables
    std.debug.print("2. Creating tables...\n", .{});
    try conn.exec(
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  name TEXT NOT NULL,
        \\  email TEXT NOT NULL,
        \\  age INTEGER,
        \\  balance REAL DEFAULT 0.0
        \\)
    );
    try conn.exec(
        \\CREATE TABLE posts (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  user_id INTEGER,
        \\  title TEXT NOT NULL,
        \\  content TEXT,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  FOREIGN KEY (user_id) REFERENCES users(id)
        \\)
    );
    std.debug.print("   Tables created\n\n", .{});

    // Example 3: Insert data using exec
    std.debug.print("3. Inserting data with exec()...\n", .{});
    try conn.exec("INSERT INTO users (name, email, age, balance) VALUES ('Alice', 'alice@example.com', 30, 100.50)");
    try conn.exec("INSERT INTO users (name, email, age, balance) VALUES ('Bob', 'bob@example.com', 25, 250.75)");
    std.debug.print("   Inserted {} rows\n\n", .{conn.changesCount()});

    // Example 4: Insert with prepared statements
    std.debug.print("4. Inserting with prepared statements...\n", .{});
    var insert_stmt = try conn.prepare("INSERT INTO users (name, email, age, balance) VALUES (?, ?, ?, ?)");
    defer insert_stmt.finalize();

    const users = [_]struct { name: []const u8, email: []const u8, age: i64, balance: f64 }{
        .{ .name = "Charlie", .email = "charlie@example.com", .age = 35, .balance = 500.00 },
        .{ .name = "Diana", .email = "diana@example.com", .age = 28, .balance = 175.25 },
        .{ .name = "Eve", .email = "eve@example.com", .age = 42, .balance = 1000.00 },
    };

    for (users) |user| {
        try insert_stmt.bindText(1, user.name);
        try insert_stmt.bindText(2, user.email);
        try insert_stmt.bindInt(3, user.age);
        try insert_stmt.bindDouble(4, user.balance);
        _ = try insert_stmt.step();
        try insert_stmt.reset();
    }
    std.debug.print("   Inserted {} more users\n", .{users.len});
    std.debug.print("   Last insert ID: {}\n\n", .{conn.lastInsertId()});

    // Example 5: Query all users
    std.debug.print("5. Querying all users...\n", .{});
    var result = try conn.query("SELECT id, name, email, age, balance FROM users");
    defer result.deinit();

    std.debug.print("   ID | Name        | Email                   | Age | Balance\n", .{});
    std.debug.print("   ---|-------------|-------------------------|-----|----------\n", .{});

    while (try result.next()) |row| {
        const id = row.getInt(0);
        const name = try row.getText(1);
        const email = try row.getText(2);
        const age = row.getInt(3);
        const balance = row.getDouble(4);

        std.debug.print("   {d:3} | {s:11} | {s:23} | {d:3} | ${d:.2}\n", .{ id, name, email, age, balance });
    }
    std.debug.print("\n", .{});

    // Example 6: Query with WHERE clause
    std.debug.print("6. Querying users older than 30...\n", .{});
    var where_result = try conn.query("SELECT name, age FROM users WHERE age > 30");
    defer where_result.deinit();

    while (try where_result.next()) |row| {
        const name = try row.getText(0);
        const age = row.getInt(1);
        std.debug.print("   {s} (age: {})\n", .{ name, age });
    }
    std.debug.print("\n", .{});

    // Example 7: Using Query Builder
    std.debug.print("7. Using Query Builder...\n", .{});
    var builder = database.QueryBuilder.init(allocator);
    defer builder.deinit();

    const fields = [_][]const u8{ "name", "email", "balance" };
    _ = try builder.select(&fields);
    _ = builder.from("users");
    _ = try builder.where("balance > 200");
    _ = builder.orderBy("balance DESC");
    _ = builder.limit(3);
    const sql = try builder.build();
    defer allocator.free(sql);

    std.debug.print("   Generated SQL: {s}\n", .{sql});

    var builder_result = try conn.query(sql);
    defer builder_result.deinit();

    std.debug.print("   Results:\n", .{});
    while (try builder_result.next()) |row| {
        const name = try row.getText(0);
        const email = try row.getText(1);
        const balance = row.getDouble(2);
        std.debug.print("   - {s} ({s}): ${d:.2}\n", .{ name, email, balance });
    }
    std.debug.print("\n", .{});

    // Example 8: Insert posts
    std.debug.print("8. Creating posts...\n", .{});
    try conn.exec("INSERT INTO posts (user_id, title, content) VALUES (1, 'Hello World', 'My first post')");
    try conn.exec("INSERT INTO posts (user_id, title, content) VALUES (1, 'Zig is Great', 'Learning Zig language')");
    try conn.exec("INSERT INTO posts (user_id, title, content) VALUES (3, 'Database Tutorial', 'How to use SQLite')");
    std.debug.print("   Created {} posts\n\n", .{3});

    // Example 9: JOIN query
    std.debug.print("9. Querying posts with user names (JOIN)...\n", .{});
    var join_result = try conn.query(
        \\SELECT u.name, p.title, p.content
        \\FROM posts p
        \\JOIN users u ON p.user_id = u.id
        \\ORDER BY p.id
    );
    defer join_result.deinit();

    while (try join_result.next()) |row| {
        const user_name = try row.getText(0);
        const title = try row.getText(1);
        const content = try row.getText(2);
        std.debug.print("   [{s}] {s}\n", .{ user_name, title });
        std.debug.print("   {s}\n\n", .{content});
    }

    // Example 10: Aggregate functions
    std.debug.print("10. Aggregate functions...\n", .{});
    var agg_result = try conn.query(
        \\SELECT
        \\  COUNT(*) as user_count,
        \\  AVG(age) as avg_age,
        \\  SUM(balance) as total_balance,
        \\  MAX(balance) as max_balance
        \\FROM users
    );
    defer agg_result.deinit();

    if (try agg_result.next()) |row| {
        const user_count = row.getInt(0);
        const avg_age = row.getDouble(1);
        const total_balance = row.getDouble(2);
        const max_balance = row.getDouble(3);

        std.debug.print("   Total users: {}\n", .{user_count});
        std.debug.print("   Average age: {d:.1}\n", .{avg_age});
        std.debug.print("   Total balance: ${d:.2}\n", .{total_balance});
        std.debug.print("   Max balance: ${d:.2}\n", .{max_balance});
    }
    std.debug.print("\n", .{});

    // Example 11: Update records
    std.debug.print("11. Updating balances...\n", .{});
    try conn.exec("UPDATE users SET balance = balance * 1.10 WHERE age < 30");
    std.debug.print("   Applied 10% bonus to users under 30\n", .{});
    std.debug.print("   Updated {} rows\n\n", .{conn.changesCount()});

    // Example 12: Delete records
    std.debug.print("12. Deleting inactive users...\n", .{});
    try conn.exec("DELETE FROM users WHERE balance < 100");
    std.debug.print("   Deleted {} users\n\n", .{conn.changesCount()});

    // Final count
    var count_result = try conn.query("SELECT COUNT(*) FROM users");
    defer count_result.deinit();

    if (try count_result.next()) |row| {
        const final_count = row.getInt(0);
        std.debug.print("   Remaining users: {}\n", .{final_count});
    }

    std.debug.print("\n=== Example Complete ===\n\n", .{});
}
