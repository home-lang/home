const std = @import("std");
const database = @import("database.zig");

/// Fully Typed ORM for Home
/// Compile-time type-safe models with zero runtime overhead

/// Field metadata for compile-time reflection
pub fn Field(comptime T: type) type {
    return struct {
        name: []const u8,
        field_type: T,
        nullable: bool = false,
        primary_key: bool = false,
        unique: bool = false,
        auto_increment: bool = false,
        default_value: ?T = null,
    };
}

/// Column annotation for struct fields
pub fn Column(comptime options: anytype) type {
    return struct {
        pub const column_options = options;
    };
}

/// Table annotation for structs
pub fn Table(comptime table_name: []const u8) type {
    return struct {
        pub const table = table_name;
    };
}

/// Primary key annotation
pub const PrimaryKey = struct {
    pub const is_primary = true;
    pub const auto_increment = true;
};

/// Unique constraint annotation
pub const Unique = struct {
    pub const is_unique = true;
};

/// Nullable field annotation
pub const Nullable = struct {
    pub const nullable = true;
};

/// Model trait - implement this for your models
pub fn Model(comptime T: type) type {
    // Validate that T is a struct
    const type_info = @typeInfo(T);
    if (type_info != .Struct) {
        @compileError("Model can only be implemented for struct types");
    }

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        connection: *database.Connection,
        data: T,
        is_persisted: bool = false,
        is_dirty: bool = false,

        /// Get table name from struct or use default
        pub fn tableName() []const u8 {
            if (@hasDecl(T, "table")) {
                return T.table;
            }
            // Default: lowercase struct name with 's'
            const name = @typeName(T);
            return name; // In production, would convert to snake_case + 's'
        }

        /// Initialize new model instance
        pub fn init(allocator: std.mem.Allocator, connection: *database.Connection, data: T) Self {
            return .{
                .allocator = allocator,
                .connection = connection,
                .data = data,
            };
        }

        /// Create new empty model
        pub fn new(allocator: std.mem.Allocator, connection: *database.Connection) Self {
            return .{
                .allocator = allocator,
                .connection = connection,
                .data = std.mem.zeroes(T),
            };
        }

        /// Get field value by name at compile time
        pub fn get(self: *const Self, comptime field_name: []const u8) FieldType(field_name) {
            return @field(self.data, field_name);
        }

        /// Set field value by name at compile time
        pub fn set(self: *Self, comptime field_name: []const u8, value: FieldType(field_name)) void {
            @field(self.data, field_name) = value;
            self.is_dirty = true;
        }

        /// Get the type of a field
        fn FieldType(comptime field_name: []const u8) type {
            const fields = @typeInfo(T).Struct.fields;
            inline for (fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return field.type;
                }
            }
            @compileError("Field '" ++ field_name ++ "' not found in " ++ @typeName(T));
        }

        /// Save model to database (insert or update)
        pub fn save(self: *Self) !void {
            if (self.is_persisted) {
                if (self.is_dirty) {
                    try self.update();
                }
            } else {
                try self.insert();
            }
        }

        /// Insert new record
        fn insert(self: *Self) !void {
            var builder = database.QueryBuilder.init(self.allocator);
            defer builder.deinit();

            _ = builder.into(tableName());

            // Build INSERT query from struct fields
            const fields = @typeInfo(T).Struct.fields;
            inline for (fields) |field| {
                // Skip auto-increment primary keys
                if (isPrimaryKey(field.name) and isAutoIncrement(field.name)) {
                    continue;
                }

                const value = @field(self.data, field.name);
                const value_str = try valueToString(self.allocator, value);
                defer self.allocator.free(value_str);

                _ = try builder.columns(&.{field.name});
                _ = try builder.values(&.{value_str});
            }

            const sql = try builder.build();
            defer self.allocator.free(sql);

            try self.connection.exec(sql);

            self.is_persisted = true;
            self.is_dirty = false;
        }

        /// Update existing record
        fn update(self: *Self) !void {
            var builder = database.QueryBuilder.init(self.allocator);
            defer builder.deinit();

            _ = builder.update(tableName());

            // Build UPDATE SET clauses
            const fields = @typeInfo(T).Struct.fields;
            inline for (fields) |field| {
                if (isPrimaryKey(field.name)) {
                    continue; // Don't update primary key
                }

                const value = @field(self.data, field.name);
                const value_str = try valueToString(self.allocator, value);
                defer self.allocator.free(value_str);

                const set_clause = try std.fmt.allocPrint(
                    self.allocator,
                    "{s} = {s}",
                    .{ field.name, value_str },
                );
                defer self.allocator.free(set_clause);

                _ = try builder.set(set_clause);
            }

            // Add WHERE clause for primary key
            const pk_field = comptime getPrimaryKeyField();
            const pk_value = @field(self.data, pk_field);
            const pk_str = try valueToString(self.allocator, pk_value);
            defer self.allocator.free(pk_str);

            const where_clause = try std.fmt.allocPrint(
                self.allocator,
                "{s} = {s}",
                .{ pk_field, pk_str },
            );
            defer self.allocator.free(where_clause);

            _ = builder.where(where_clause);

            const sql = try builder.build();
            defer self.allocator.free(sql);

            try self.connection.exec(sql);

            self.is_dirty = false;
        }

        /// Delete record
        pub fn delete(self: *Self) !void {
            var builder = database.QueryBuilder.init(self.allocator);
            defer builder.deinit();

            _ = builder.deleteFrom(tableName());

            const pk_field = comptime getPrimaryKeyField();
            const pk_value = @field(self.data, pk_field);
            const pk_str = try valueToString(self.allocator, pk_value);
            defer self.allocator.free(pk_str);

            const where_clause = try std.fmt.allocPrint(
                self.allocator,
                "{s} = {s}",
                .{ pk_field, pk_str },
            );
            defer self.allocator.free(where_clause);

            _ = builder.where(where_clause);

            const sql = try builder.build();
            defer self.allocator.free(sql);

            try self.connection.exec(sql);

            self.is_persisted = false;
        }

        /// Get primary key field name at compile time
        fn getPrimaryKeyField() []const u8 {
            const fields = @typeInfo(T).Struct.fields;
            inline for (fields) |field| {
                if (isPrimaryKey(field.name)) {
                    return field.name;
                }
            }
            // Default to "id"
            return "id";
        }

        /// Check if field is primary key
        fn isPrimaryKey(comptime field_name: []const u8) bool {
            if (@hasDecl(T, field_name ++ "_options")) {
                const options = @field(T, field_name ++ "_options");
                if (@hasDecl(@TypeOf(options), "is_primary")) {
                    return options.is_primary;
                }
            }
            // Default: field named "id" is primary key
            return std.mem.eql(u8, field_name, "id");
        }

        /// Check if field is auto-increment
        fn isAutoIncrement(comptime field_name: []const u8) bool {
            if (@hasDecl(T, field_name ++ "_options")) {
                const options = @field(T, field_name ++ "_options");
                if (@hasDecl(@TypeOf(options), "auto_increment")) {
                    return options.auto_increment;
                }
            }
            return isPrimaryKey(field_name);
        }

        /// Convert value to SQL string
        fn valueToString(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
            const ValueType = @TypeOf(value);
            const type_info = @typeInfo(ValueType);

            return switch (type_info) {
                .Int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
                .Float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
                .Bool => try std.fmt.allocPrint(allocator, "{d}", .{@intFromBool(value)}),
                .Optional => |opt| {
                    if (value) |v| {
                        return try valueToString(allocator, v);
                    } else {
                        return try allocator.dupe(u8, "NULL");
                    }
                },
                .Pointer => |ptr| {
                    if (ptr.size == .Slice and ptr.child == u8) {
                        // String
                        return try std.fmt.allocPrint(allocator, "'{s}'", .{value});
                    }
                    @compileError("Unsupported pointer type for ORM");
                },
                else => @compileError("Unsupported type for ORM: " ++ @typeName(ValueType)),
            };
        }

        /// Generate CREATE TABLE SQL at compile time
        pub fn createTableSQL(allocator: std.mem.Allocator) ![]const u8 {
            var sql = std.ArrayList(u8).init(allocator);
            const writer = sql.writer();

            try writer.print("CREATE TABLE IF NOT EXISTS {s} (\n", .{tableName()});

            const fields = @typeInfo(T).Struct.fields;
            inline for (fields, 0..) |field, i| {
                try writer.print("  {s} ", .{field.name});

                // Determine SQL type from Zig type
                const sql_type = sqlTypeForField(field.type);
                try writer.writeAll(sql_type);

                // Constraints
                if (isPrimaryKey(field.name)) {
                    try writer.writeAll(" PRIMARY KEY");
                    if (isAutoIncrement(field.name)) {
                        try writer.writeAll(" AUTOINCREMENT");
                    }
                }

                if (i < fields.len - 1) {
                    try writer.writeAll(",\n");
                }
            }

            try writer.writeAll("\n)");

            return try sql.toOwnedSlice();
        }

        /// Map Zig type to SQL type
        fn sqlTypeForField(comptime FieldT: type) []const u8 {
            const type_info = @typeInfo(FieldT);

            return switch (type_info) {
                .Int => |int_info| {
                    if (int_info.bits <= 32) {
                        return "INTEGER";
                    } else {
                        return "BIGINT";
                    }
                },
                .Float => "REAL",
                .Bool => "BOOLEAN",
                .Optional => |opt| sqlTypeForField(opt.child),
                .Pointer => |ptr| {
                    if (ptr.size == .Slice and ptr.child == u8) {
                        return "TEXT";
                    }
                    @compileError("Unsupported pointer type");
                },
                else => @compileError("Unsupported field type: " ++ @typeName(FieldT)),
            };
        }
    };
}

/// Query builder for typed models
pub fn Query(comptime T: type) type {
    return struct {
        const Self = @This();
        const ModelType = Model(T);

        allocator: std.mem.Allocator,
        connection: *database.Connection,
        builder: database.QueryBuilder,

        pub fn init(allocator: std.mem.Allocator, connection: *database.Connection) Self {
            var builder = database.QueryBuilder.init(allocator);
            _ = builder.from(ModelType.tableName());

            return .{
                .allocator = allocator,
                .connection = connection,
                .builder = builder,
            };
        }

        pub fn deinit(self: *Self) void {
            self.builder.deinit();
        }

        /// Select specific fields (type-checked at compile time)
        pub fn select(self: *Self, comptime fields: []const []const u8) *Self {
            // Validate fields exist at compile time
            comptime {
                const struct_fields = @typeInfo(T).Struct.fields;
                for (fields) |field_name| {
                    var found = false;
                    for (struct_fields) |struct_field| {
                        if (std.mem.eql(u8, field_name, struct_field.name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        @compileError("Field '" ++ field_name ++ "' does not exist in " ++ @typeName(T));
                    }
                }
            }

            _ = self.builder.select(fields) catch unreachable;
            return self;
        }

        /// Where clause with compile-time field validation
        pub fn where(self: *Self, comptime field: []const u8, operator: []const u8, value: anytype) !*Self {
            // Validate field exists at compile time
            comptime {
                const fields = @typeInfo(T).Struct.fields;
                var found = false;
                for (fields) |f| {
                    if (std.mem.eql(u8, field, f.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("Field '" ++ field ++ "' does not exist in " ++ @typeName(T));
                }
            }

            const value_str = try ModelType.valueToString(self.allocator, value);
            defer self.allocator.free(value_str);

            const clause = try std.fmt.allocPrint(
                self.allocator,
                "{s} {s} {s}",
                .{ field, operator, value_str },
            );
            defer self.allocator.free(clause);

            _ = self.builder.where(clause);
            return self;
        }

        /// Order by with compile-time field validation
        pub fn orderBy(self: *Self, comptime field: []const u8, direction: enum { asc, desc }) *Self {
            // Validate field exists at compile time
            comptime {
                const fields = @typeInfo(T).Struct.fields;
                var found = false;
                for (fields) |f| {
                    if (std.mem.eql(u8, field, f.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("Field '" ++ field ++ "' does not exist in " ++ @typeName(T));
                }
            }

            const dir_str = if (direction == .asc) "ASC" else "DESC";
            const order = std.fmt.allocPrint(
                self.allocator,
                "{s} {s}",
                .{ field, dir_str },
            ) catch unreachable;
            defer self.allocator.free(order);

            _ = self.builder.orderBy(order);
            return self;
        }

        /// Limit results
        pub fn limit(self: *Self, n: usize) *Self {
            _ = self.builder.limit(n);
            return self;
        }

        /// Offset results
        pub fn offset(self: *Self, n: usize) *Self {
            _ = self.builder.offset(n);
            return self;
        }

        /// Execute query and return typed results
        pub fn get(self: *Self) ![]ModelType {
            _ = self.builder.select(&.{"*"}) catch unreachable;

            const sql = try self.builder.build();
            defer self.allocator.free(sql);

            // Execute query
            var result = try self.connection.query(sql);

            var models = std.ArrayList(ModelType).init(self.allocator);

            while (result.next()) |row| {
                const model = try self.rowToModel(row);
                try models.append(model);
            }

            return try models.toOwnedSlice();
        }

        /// Get first result
        pub fn first(self: *Self) !?ModelType {
            _ = self.builder.limit(1);
            const results = try self.get();

            if (results.len == 0) {
                return null;
            }

            return results[0];
        }

        /// Find by primary key
        pub fn find(allocator: std.mem.Allocator, connection: *database.Connection, id: anytype) !?ModelType {
            var query = Query(T).init(allocator, connection);
            defer query.deinit();

            const pk_field = comptime ModelType.getPrimaryKeyField();
            _ = try query.where(pk_field, "=", id);

            return try query.first();
        }

        /// Count records
        pub fn count(self: *Self) !usize {
            _ = self.builder.select(&.{"COUNT(*) as count"}) catch unreachable;

            const sql = try self.builder.build();
            defer self.allocator.free(sql);

            var result = try self.connection.query(sql);

            if (result.next()) |row| {
                return @intCast(row.getInt(0));
            }

            return 0;
        }

        /// Check if any records exist
        pub fn exists(self: *Self) !bool {
            const c = try self.count();
            return c > 0;
        }

        /// Convert database row to typed model
        fn rowToModel(self: *Self, row: *database.Row) !ModelType {
            var data: T = undefined;

            const fields = @typeInfo(T).Struct.fields;
            inline for (fields, 0..) |field, i| {
                const value = try self.parseValue(field.type, row, i);
                @field(data, field.name) = value;
            }

            var model = ModelType.init(self.allocator, self.connection, data);
            model.is_persisted = true;
            model.is_dirty = false;

            return model;
        }

        /// Parse value from row based on type
        fn parseValue(self: *Self, comptime FieldType: type, row: *database.Row, index: usize) !FieldType {
            _ = self;
            const type_info = @typeInfo(FieldType);

            return switch (type_info) {
                .Int => @intCast(row.getInt(index)),
                .Float => @floatCast(row.getFloat(index)),
                .Bool => row.getInt(index) != 0,
                .Optional => |opt| {
                    const raw = row.get(index);
                    if (raw == null) {
                        return null;
                    }
                    return try parseValue(self, opt.child, row, index);
                },
                .Pointer => |ptr| {
                    if (ptr.size == .Slice and ptr.child == u8) {
                        return row.getText(index);
                    }
                    @compileError("Unsupported pointer type");
                },
                else => @compileError("Unsupported field type: " ++ @typeName(FieldType)),
            };
        }
    };
}

/// Relationship types for typed models
pub fn HasOne(comptime Parent: type, comptime Child: type, comptime foreign_key: []const u8) type {
    return struct {
        pub fn get(allocator: std.mem.Allocator, connection: *database.Connection, parent: *const Model(Parent)) !?Model(Child) {
            const pk_field = comptime Model(Parent).getPrimaryKeyField();
            const parent_id = parent.get(pk_field);

            var query = Query(Child).init(allocator, connection);
            defer query.deinit();

            _ = try query.where(foreign_key, "=", parent_id);
            return try query.first();
        }
    };
}

pub fn HasMany(comptime Parent: type, comptime Child: type, comptime foreign_key: []const u8) type {
    return struct {
        pub fn get(allocator: std.mem.Allocator, connection: *database.Connection, parent: *const Model(Parent)) ![]Model(Child) {
            const pk_field = comptime Model(Parent).getPrimaryKeyField();
            const parent_id = parent.get(pk_field);

            var query = Query(Child).init(allocator, connection);
            defer query.deinit();

            _ = try query.where(foreign_key, "=", parent_id);
            return try query.get();
        }
    };
}

pub fn BelongsTo(comptime Child: type, comptime Parent: type, comptime foreign_key: []const u8) type {
    return struct {
        pub fn get(allocator: std.mem.Allocator, connection: *database.Connection, child: *const Model(Child)) !?Model(Parent) {
            const fk_value = child.get(foreign_key);

            const pk_field = comptime Model(Parent).getPrimaryKeyField();

            var query = Query(Parent).init(allocator, connection);
            defer query.deinit();

            _ = try query.where(pk_field, "=", fk_value);
            return try query.first();
        }
    };
}
