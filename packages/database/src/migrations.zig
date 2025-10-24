const std = @import("std");
const database = @import("database.zig");
const orm = @import("orm.zig");

/// Database Migration System for Home
/// Provides versioned schema changes with rollback support

/// Migration status
pub const MigrationStatus = enum {
    pending,
    applied,
    rolled_back,
    failed,
};

/// Migration record
pub const MigrationRecord = struct {
    id: i64,
    name: []const u8,
    batch: i32,
    applied_at: i64,
};

/// Schema builder for creating/modifying tables
pub const SchemaBuilder = struct {
    allocator: std.mem.Allocator,
    connection: *database.Connection,

    pub fn init(allocator: std.mem.Allocator, connection: *database.Connection) SchemaBuilder {
        return .{
            .allocator = allocator,
            .connection = connection,
        };
    }

    /// Create new table
    pub fn createTable(self: *SchemaBuilder, name: []const u8, callback: *const fn (*TableBuilder) anyerror!void) !void {
        var builder = TableBuilder.init(self.allocator, name);
        defer builder.deinit();

        try callback(&builder);

        const sql = try builder.toSQL(.create);
        defer self.allocator.free(sql);

        try self.connection.exec(sql);
    }

    /// Drop table
    pub fn dropTable(self: *SchemaBuilder, name: []const u8) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "DROP TABLE IF EXISTS {s}", .{name});
        defer self.allocator.free(sql);

        try self.connection.exec(sql);
    }

    /// Rename table
    pub fn renameTable(self: *SchemaBuilder, old_name: []const u8, new_name: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "ALTER TABLE {s} RENAME TO {s}",
            .{ old_name, new_name },
        );
        defer self.allocator.free(sql);

        try self.connection.exec(sql);
    }

    /// Modify existing table
    pub fn modifyTable(self: *SchemaBuilder, name: []const u8, callback: *const fn (*TableBuilder) anyerror!void) !void {
        var builder = TableBuilder.init(self.allocator, name);
        defer builder.deinit();

        try callback(&builder);

        const sql = try builder.toSQL(.alter);
        defer self.allocator.free(sql);

        try self.connection.exec(sql);
    }

    /// Check if table exists
    pub fn hasTable(self: *SchemaBuilder, name: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='{s}'",
            .{name},
        );
        defer self.allocator.free(sql);

        var result = try self.connection.query(sql);
        return result.next() != null;
    }

    /// Check if column exists in table
    pub fn hasColumn(self: *SchemaBuilder, table: []const u8, column: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "PRAGMA table_info({s})",
            .{table},
        );
        defer self.allocator.free(sql);

        var result = try self.connection.query(sql);
        while (result.next()) |row| {
            const col_name = row.getText(1);
            if (std.mem.eql(u8, col_name, column)) {
                return true;
            }
        }

        return false;
    }
};

/// Operation type for table modifications
pub const TableOperation = enum {
    create,
    alter,
};

/// Table builder for defining table structure
pub const TableBuilder = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    columns: std.ArrayList(ColumnDefinition),
    indexes: std.ArrayList(IndexDefinition),
    foreign_keys: std.ArrayList(ForeignKeyDefinition),

    pub const ColumnDefinition = struct {
        name: []const u8,
        column_type: []const u8,
        nullable: bool = false,
        default: ?[]const u8 = null,
        primary: bool = false,
        unique: bool = false,
        auto_increment: bool = false,
    };

    pub const IndexDefinition = struct {
        columns: []const []const u8,
        unique: bool = false,
        name: ?[]const u8 = null,
    };

    pub const ForeignKeyDefinition = struct {
        column: []const u8,
        references_table: []const u8,
        references_column: []const u8,
        on_delete: ?[]const u8 = null,
        on_update: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) TableBuilder {
        return .{
            .allocator = allocator,
            .table_name = table_name,
            .columns = std.ArrayList(ColumnDefinition).init(allocator),
            .indexes = std.ArrayList(IndexDefinition).init(allocator),
            .foreign_keys = std.ArrayList(ForeignKeyDefinition).init(allocator),
        };
    }

    pub fn deinit(self: *TableBuilder) void {
        self.columns.deinit();
        self.indexes.deinit();
        self.foreign_keys.deinit();
    }

    /// Add auto-incrementing ID column
    pub fn id(self: *TableBuilder) !void {
        try self.columns.append(.{
            .name = "id",
            .column_type = "INTEGER",
            .primary = true,
            .auto_increment = true,
        });
    }

    /// Add integer column
    pub fn integer(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "INTEGER",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add big integer column
    pub fn bigInteger(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "BIGINT",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add string column
    pub fn string(self: *TableBuilder, name: []const u8, length: ?usize) !*ColumnDefinition {
        const col_type = if (length) |len|
            try std.fmt.allocPrint(self.allocator, "VARCHAR({d})", .{len})
        else
            "VARCHAR(255)";

        try self.columns.append(.{
            .name = name,
            .column_type = col_type,
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add text column
    pub fn text(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "TEXT",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add boolean column
    pub fn boolean(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "BOOLEAN",
            .default = "0",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add float column
    pub fn float(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "FLOAT",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add double column
    pub fn double(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "DOUBLE",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add date column
    pub fn date(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "DATE",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add datetime column
    pub fn datetime(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "DATETIME",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add timestamp column
    pub fn timestamp(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "TIMESTAMP",
            .default = "CURRENT_TIMESTAMP",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add JSON column
    pub fn json(self: *TableBuilder, name: []const u8) !*ColumnDefinition {
        try self.columns.append(.{
            .name = name,
            .column_type = "JSON",
        });
        return &self.columns.items[self.columns.items.len - 1];
    }

    /// Add timestamps (created_at, updated_at)
    pub fn timestamps(self: *TableBuilder) !void {
        _ = try self.timestamp("created_at");
        _ = try self.timestamp("updated_at");
    }

    /// Add soft deletes (deleted_at)
    pub fn softDeletes(self: *TableBuilder) !void {
        var col = try self.timestamp("deleted_at");
        col.nullable = true;
    }

    /// Add index
    pub fn index(self: *TableBuilder, columns: []const []const u8, unique: bool) !void {
        try self.indexes.append(.{
            .columns = columns,
            .unique = unique,
        });
    }

    /// Add foreign key
    pub fn foreignKey(
        self: *TableBuilder,
        column: []const u8,
        references_table: []const u8,
        references_column: []const u8,
    ) !void {
        try self.foreign_keys.append(.{
            .column = column,
            .references_table = references_table,
            .references_column = references_column,
        });
    }

    /// Generate SQL for table creation/alteration
    pub fn toSQL(self: *TableBuilder, operation: TableOperation) ![]const u8 {
        var sql = std.ArrayList(u8).init(self.allocator);
        defer sql.deinit();

        const writer = sql.writer();

        switch (operation) {
            .create => {
                try writer.print("CREATE TABLE IF NOT EXISTS {s} (\n", .{self.table_name});

                for (self.columns.items, 0..) |col, i| {
                    try writer.print("  {s} {s}", .{ col.name, col.column_type });

                    if (col.primary) {
                        try writer.writeAll(" PRIMARY KEY");
                        if (col.auto_increment) {
                            try writer.writeAll(" AUTOINCREMENT");
                        }
                    }

                    if (col.unique and !col.primary) {
                        try writer.writeAll(" UNIQUE");
                    }

                    if (!col.nullable and !col.primary) {
                        try writer.writeAll(" NOT NULL");
                    }

                    if (col.default) |default| {
                        try writer.print(" DEFAULT {s}", .{default});
                    }

                    if (i < self.columns.items.len - 1 or self.foreign_keys.items.len > 0) {
                        try writer.writeAll(",\n");
                    }
                }

                // Add foreign keys
                for (self.foreign_keys.items, 0..) |fk, i| {
                    try writer.print("  FOREIGN KEY ({s}) REFERENCES {s}({s})", .{
                        fk.column,
                        fk.references_table,
                        fk.references_column,
                    });

                    if (fk.on_delete) |action| {
                        try writer.print(" ON DELETE {s}", .{action});
                    }

                    if (fk.on_update) |action| {
                        try writer.print(" ON UPDATE {s}", .{action});
                    }

                    if (i < self.foreign_keys.items.len - 1) {
                        try writer.writeAll(",\n");
                    }
                }

                try writer.writeAll("\n)");
            },
            .alter => {
                // SQLite has limited ALTER TABLE support
                // This is a simplified version
                try writer.print("ALTER TABLE {s}\n", .{self.table_name});

                for (self.columns.items, 0..) |col, i| {
                    try writer.print("ADD COLUMN {s} {s}", .{ col.name, col.column_type });

                    if (!col.nullable) {
                        try writer.writeAll(" NOT NULL");
                    }

                    if (col.default) |default| {
                        try writer.print(" DEFAULT {s}", .{default});
                    }

                    if (i < self.columns.items.len - 1) {
                        try writer.writeAll(",\n");
                    }
                }
            },
        }

        return try self.allocator.dupe(u8, sql.items);
    }
};

/// Migration definition
pub const Migration = struct {
    name: []const u8,
    up: *const fn (*SchemaBuilder) anyerror!void,
    down: *const fn (*SchemaBuilder) anyerror!void,
};

/// Migration manager
pub const Migrator = struct {
    allocator: std.mem.Allocator,
    connection: *database.Connection,
    migrations_table: []const u8 = "migrations",
    current_batch: i32 = 0,

    pub fn init(allocator: std.mem.Allocator, connection: *database.Connection) Migrator {
        return .{
            .allocator = allocator,
            .connection = connection,
        };
    }

    /// Initialize migrations table
    pub fn initialize(self: *Migrator) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS migrations (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL UNIQUE,
            \\  batch INTEGER NOT NULL,
            \\  applied_at INTEGER NOT NULL
            \\)
        ;

        try self.connection.exec(sql);

        // Get current batch number
        const batch_sql = "SELECT COALESCE(MAX(batch), 0) as max_batch FROM migrations";
        var result = try self.connection.query(batch_sql);

        if (result.next()) |row| {
            self.current_batch = row.getInt(0);
        }
    }

    /// Run pending migrations
    pub fn migrate(self: *Migrator, migrations: []const Migration) !void {
        try self.initialize();

        self.current_batch += 1;

        var schema_builder = SchemaBuilder.init(self.allocator, self.connection);

        for (migrations) |migration| {
            // Check if already applied
            if (try self.isApplied(migration.name)) {
                continue;
            }

            std.debug.print("Migrating: {s}\n", .{migration.name});

            // Run up migration
            migration.up(&schema_builder) catch |err| {
                std.debug.print("Migration failed: {s} - {}\n", .{ migration.name, err });
                return err;
            };

            // Record migration
            try self.recordMigration(migration.name);

            std.debug.print("Migrated: {s}\n", .{migration.name});
        }
    }

    /// Rollback last batch of migrations
    pub fn rollback(self: *Migrator, migrations: []const Migration) !void {
        try self.initialize();

        if (self.current_batch == 0) {
            std.debug.print("Nothing to rollback\n", .{});
            return;
        }

        // Get migrations from current batch
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT name FROM migrations WHERE batch = {d} ORDER BY id DESC",
            .{self.current_batch},
        );
        defer self.allocator.free(sql);

        var result = try self.connection.query(sql);
        var to_rollback = std.ArrayList([]const u8).init(self.allocator);
        defer to_rollback.deinit();

        while (result.next()) |row| {
            const name = row.getText(0);
            try to_rollback.append(name);
        }

        var schema_builder = SchemaBuilder.init(self.allocator, self.connection);

        // Rollback in reverse order
        for (to_rollback.items) |name| {
            // Find migration
            for (migrations) |migration| {
                if (std.mem.eql(u8, migration.name, name)) {
                    std.debug.print("Rolling back: {s}\n", .{migration.name});

                    // Run down migration
                    migration.down(&schema_builder) catch |err| {
                        std.debug.print("Rollback failed: {s} - {}\n", .{ migration.name, err });
                        return err;
                    };

                    // Remove migration record
                    try self.removeMigration(migration.name);

                    std.debug.print("Rolled back: {s}\n", .{migration.name});
                    break;
                }
            }
        }

        self.current_batch -= 1;
    }

    /// Reset all migrations
    pub fn reset(self: *Migrator, migrations: []const Migration) !void {
        while (self.current_batch > 0) {
            try self.rollback(migrations);
        }
    }

    /// Refresh all migrations (reset + migrate)
    pub fn refresh(self: *Migrator, migrations: []const Migration) !void {
        try self.reset(migrations);
        try self.migrate(migrations);
    }

    /// Check if migration is applied
    fn isApplied(self: *Migrator, name: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT COUNT(*) FROM migrations WHERE name = '{s}'",
            .{name},
        );
        defer self.allocator.free(sql);

        var result = try self.connection.query(sql);

        if (result.next()) |row| {
            return row.getInt(0) > 0;
        }

        return false;
    }

    /// Record migration as applied
    fn recordMigration(self: *Migrator, name: []const u8) !void {
        const timestamp = std.time.timestamp();
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO migrations (name, batch, applied_at) VALUES ('{s}', {d}, {d})",
            .{ name, self.current_batch, timestamp },
        );
        defer self.allocator.free(sql);

        try self.connection.exec(sql);
    }

    /// Remove migration record
    fn removeMigration(self: *Migrator, name: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "DELETE FROM migrations WHERE name = '{s}'",
            .{name},
        );
        defer self.allocator.free(sql);

        try self.connection.exec(sql);
    }

    /// Get applied migrations
    pub fn getApplied(self: *Migrator) ![]MigrationRecord {
        const sql = "SELECT id, name, batch, applied_at FROM migrations ORDER BY id";

        var result = try self.connection.query(sql);
        var migrations = std.ArrayList(MigrationRecord).init(self.allocator);

        while (result.next()) |row| {
            try migrations.append(.{
                .id = row.getInt(0),
                .name = row.getText(1),
                .batch = @intCast(row.getInt(2)),
                .applied_at = row.getInt(3),
            });
        }

        return migrations.toOwnedSlice();
    }
};
