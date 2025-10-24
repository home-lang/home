const std = @import("std");
const database = @import("database.zig");

/// ORM (Object-Relational Mapping) for Home
/// Provides Laravel Eloquent / TypeORM-style model definitions and relationships

/// Field types supported by ORM
pub const FieldType = enum {
    integer,
    big_integer,
    text,
    varchar,
    boolean,
    float,
    double,
    date,
    datetime,
    timestamp,
    json,
    blob,
};

/// Field definition for model
pub const Field = struct {
    name: []const u8,
    field_type: FieldType,
    nullable: bool = false,
    primary_key: bool = false,
    unique: bool = false,
    default_value: ?[]const u8 = null,
    auto_increment: bool = false,
    index: bool = false,

    pub fn toSQL(self: *const Field) ![]const u8 {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        try writer.print("{s} ", .{self.name});

        // Type
        switch (self.field_type) {
            .integer => try writer.writeAll("INTEGER"),
            .big_integer => try writer.writeAll("BIGINT"),
            .text => try writer.writeAll("TEXT"),
            .varchar => try writer.writeAll("VARCHAR(255)"),
            .boolean => try writer.writeAll("BOOLEAN"),
            .float => try writer.writeAll("FLOAT"),
            .double => try writer.writeAll("DOUBLE"),
            .date => try writer.writeAll("DATE"),
            .datetime => try writer.writeAll("DATETIME"),
            .timestamp => try writer.writeAll("TIMESTAMP"),
            .json => try writer.writeAll("JSON"),
            .blob => try writer.writeAll("BLOB"),
        }

        // Constraints
        if (self.primary_key) {
            try writer.writeAll(" PRIMARY KEY");
            if (self.auto_increment) {
                try writer.writeAll(" AUTOINCREMENT");
            }
        }

        if (self.unique and !self.primary_key) {
            try writer.writeAll(" UNIQUE");
        }

        if (!self.nullable and !self.primary_key) {
            try writer.writeAll(" NOT NULL");
        }

        if (self.default_value) |default| {
            try writer.print(" DEFAULT {s}", .{default});
        }

        const written = stream.getWritten();
        return written;
    }
};

/// Model schema definition
pub const Schema = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    fields: std.ArrayList(Field),
    timestamps: bool = true, // created_at, updated_at

    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) Schema {
        return .{
            .allocator = allocator,
            .table_name = table_name,
            .fields = std.ArrayList(Field).init(allocator),
        };
    }

    pub fn deinit(self: *Schema) void {
        self.fields.deinit();
    }

    pub fn addField(self: *Schema, field: Field) !void {
        try self.fields.append(field);
    }

    /// Generate CREATE TABLE SQL
    pub fn toCreateSQL(self: *Schema) ![]const u8 {
        var sql = std.ArrayList(u8).init(self.allocator);
        defer sql.deinit();

        const writer = sql.writer();
        try writer.print("CREATE TABLE IF NOT EXISTS {s} (\n", .{self.table_name});

        for (self.fields.items, 0..) |*field, i| {
            const field_sql = try field.toSQL();
            try writer.print("  {s}", .{field_sql});

            if (i < self.fields.items.len - 1 or self.timestamps) {
                try writer.writeAll(",\n");
            }
        }

        if (self.timestamps) {
            try writer.writeAll("  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n");
            try writer.writeAll("  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP\n");
        } else {
            try writer.writeAll("\n");
        }

        try writer.writeAll(")");

        return try self.allocator.dupe(u8, sql.items);
    }
};

/// Relationship types
pub const RelationType = enum {
    has_one,
    has_many,
    belongs_to,
    many_to_many,
};

/// Relationship definition
pub const Relationship = struct {
    relation_type: RelationType,
    related_model: []const u8,
    foreign_key: []const u8,
    local_key: []const u8 = "id",
    pivot_table: ?[]const u8 = null, // For many-to-many
};

/// Query scopes for models
pub const Scope = struct {
    name: []const u8,
    apply: *const fn (*database.QueryBuilder) anyerror!void,
};

/// Base Model interface
pub const Model = struct {
    allocator: std.mem.Allocator,
    connection: *database.Connection,
    schema: Schema,
    relationships: std.StringHashMap(Relationship),
    scopes: std.StringHashMap(Scope),
    data: std.StringHashMap([]const u8),
    is_new: bool = true,
    is_dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, connection: *database.Connection, schema: Schema) Model {
        return .{
            .allocator = allocator,
            .connection = connection,
            .schema = schema,
            .relationships = std.StringHashMap(Relationship).init(allocator),
            .scopes = std.StringHashMap(Scope).init(allocator),
            .data = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Model) void {
        self.relationships.deinit();
        self.scopes.deinit();
        self.data.deinit();
    }

    /// Set attribute value
    pub fn set(self: *Model, key: []const u8, value: []const u8) !void {
        try self.data.put(key, value);
        self.is_dirty = true;
    }

    /// Get attribute value
    pub fn get(self: *Model, key: []const u8) ?[]const u8 {
        return self.data.get(key);
    }

    /// Save model to database
    pub fn save(self: *Model) !void {
        if (self.is_new) {
            try self.insert();
        } else if (self.is_dirty) {
            try self.update();
        }
    }

    /// Insert new record
    fn insert(self: *Model) !void {
        var builder = database.QueryBuilder.init(self.allocator);
        defer builder.deinit();

        _ = builder.into(self.schema.table_name);

        // Add fields
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            _ = try builder.columns(&.{entry.key_ptr.*});
            _ = try builder.values(&.{entry.value_ptr.*});
        }

        const sql = try builder.build();
        defer self.allocator.free(sql);

        try self.connection.exec(sql);

        self.is_new = false;
        self.is_dirty = false;
    }

    /// Update existing record
    fn update(self: *Model) !void {
        var builder = database.QueryBuilder.init(self.allocator);
        defer builder.deinit();

        _ = builder.update(self.schema.table_name);

        // Add SET clauses
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            const set_clause = try std.fmt.allocPrint(
                self.allocator,
                "{s} = '{s}'",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            );
            defer self.allocator.free(set_clause);
            _ = try builder.set(set_clause);
        }

        // Add WHERE clause for primary key
        const id_str = self.data.get("id") orelse return error.NoPrimaryKey;
        const where_clause = try std.fmt.allocPrint(
            self.allocator,
            "id = {s}",
            .{id_str},
        );
        defer self.allocator.free(where_clause);
        _ = builder.where(where_clause);

        const sql = try builder.build();
        defer self.allocator.free(sql);

        try self.connection.exec(sql);

        self.is_dirty = false;
    }

    /// Delete record
    pub fn delete(self: *Model) !void {
        const id_str = self.data.get("id") orelse return error.NoPrimaryKey;

        var builder = database.QueryBuilder.init(self.allocator);
        defer builder.deinit();

        _ = builder.deleteFrom(self.schema.table_name);

        const where_clause = try std.fmt.allocPrint(
            self.allocator,
            "id = {s}",
            .{id_str},
        );
        defer self.allocator.free(where_clause);
        _ = builder.where(where_clause);

        const sql = try builder.build();
        defer self.allocator.free(sql);

        try self.connection.exec(sql);
    }

    /// Refresh model from database
    pub fn refresh(self: *Model) !void {
        const id_str = self.data.get("id") orelse return error.NoPrimaryKey;

        var builder = database.QueryBuilder.init(self.allocator);
        defer builder.deinit();

        _ = builder.from(self.schema.table_name);
        _ = try builder.select(&.{"*"});

        const where_clause = try std.fmt.allocPrint(
            self.allocator,
            "id = {s}",
            .{id_str},
        );
        defer self.allocator.free(where_clause);
        _ = builder.where(where_clause);

        const sql = try builder.build();
        defer self.allocator.free(sql);

        // Execute query and update data
        // This would integrate with actual query execution
        _ = sql;
    }

    /// Define has-one relationship
    pub fn hasOne(self: *Model, name: []const u8, related_model: []const u8, foreign_key: []const u8) !void {
        try self.relationships.put(name, .{
            .relation_type = .has_one,
            .related_model = related_model,
            .foreign_key = foreign_key,
        });
    }

    /// Define has-many relationship
    pub fn hasMany(self: *Model, name: []const u8, related_model: []const u8, foreign_key: []const u8) !void {
        try self.relationships.put(name, .{
            .relation_type = .has_many,
            .related_model = related_model,
            .foreign_key = foreign_key,
        });
    }

    /// Define belongs-to relationship
    pub fn belongsTo(self: *Model, name: []const u8, related_model: []const u8, foreign_key: []const u8) !void {
        try self.relationships.put(name, .{
            .relation_type = .belongs_to,
            .related_model = related_model,
            .foreign_key = foreign_key,
        });
    }

    /// Define many-to-many relationship
    pub fn manyToMany(
        self: *Model,
        name: []const u8,
        related_model: []const u8,
        pivot_table: []const u8,
        foreign_key: []const u8,
    ) !void {
        try self.relationships.put(name, .{
            .relation_type = .many_to_many,
            .related_model = related_model,
            .foreign_key = foreign_key,
            .pivot_table = pivot_table,
        });
    }

    /// Add query scope
    pub fn addScope(self: *Model, scope: Scope) !void {
        try self.scopes.put(scope.name, scope);
    }
};

/// Query builder extensions for models
pub const ModelQuery = struct {
    allocator: std.mem.Allocator,
    connection: *database.Connection,
    builder: database.QueryBuilder,
    model_schema: Schema,

    pub fn init(allocator: std.mem.Allocator, connection: *database.Connection, schema: Schema) ModelQuery {
        return .{
            .allocator = allocator,
            .connection = connection,
            .builder = database.QueryBuilder.init(allocator),
            .model_schema = schema,
        };
    }

    pub fn deinit(self: *ModelQuery) void {
        self.builder.deinit();
    }

    /// Find by ID
    pub fn find(self: *ModelQuery, id: i64) !?Model {
        _ = self.builder.from(self.model_schema.table_name);
        _ = try self.builder.select(&.{"*"});

        const where_clause = try std.fmt.allocPrint(self.allocator, "id = {d}", .{id});
        defer self.allocator.free(where_clause);
        _ = self.builder.where(where_clause);

        const sql = try self.builder.build();
        defer self.allocator.free(sql);

        // Execute and return model
        // Would integrate with actual query execution
        _ = sql;
        return null;
    }

    /// Find all records
    pub fn all(self: *ModelQuery) ![]Model {
        _ = self.builder.from(self.model_schema.table_name);
        _ = try self.builder.select(&.{"*"});

        const sql = try self.builder.build();
        defer self.allocator.free(sql);

        // Execute and return models
        _ = sql;
        return &[_]Model{};
    }

    /// Find where condition
    pub fn where(self: *ModelQuery, condition: []const u8) *ModelQuery {
        _ = self.builder.where(condition);
        return self;
    }

    /// Order by
    pub fn orderBy(self: *ModelQuery, order: []const u8) *ModelQuery {
        _ = self.builder.orderBy(order);
        return self;
    }

    /// Limit results
    pub fn limit(self: *ModelQuery, n: usize) *ModelQuery {
        _ = self.builder.limit(n);
        return self;
    }

    /// Offset results
    pub fn offset(self: *ModelQuery, n: usize) *ModelQuery {
        _ = self.builder.offset(n);
        return self;
    }

    /// Execute query and get results
    pub fn get(self: *ModelQuery) ![]Model {
        const sql = try self.builder.build();
        defer self.allocator.free(sql);

        // Execute and return models
        _ = sql;
        return &[_]Model{};
    }

    /// Execute query and get first result
    pub fn first(self: *ModelQuery) !?Model {
        _ = self.builder.limit(1);

        const sql = try self.builder.build();
        defer self.allocator.free(sql);

        // Execute and return first model
        _ = sql;
        return null;
    }

    /// Count records
    pub fn count(self: *ModelQuery) !usize {
        _ = try self.builder.select(&.{"COUNT(*) as count"});

        const sql = try self.builder.build();
        defer self.allocator.free(sql);

        // Execute and return count
        _ = sql;
        return 0;
    }

    /// Check if any records exist
    pub fn exists(self: *ModelQuery) !bool {
        const c = try self.count();
        return c > 0;
    }
};

/// Pagination helper
pub const Paginator = struct {
    allocator: std.mem.Allocator,
    data: []Model,
    current_page: usize,
    per_page: usize,
    total: usize,
    last_page: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        data: []Model,
        current_page: usize,
        per_page: usize,
        total: usize,
    ) Paginator {
        const last_page = (total + per_page - 1) / per_page;

        return .{
            .allocator = allocator,
            .data = data,
            .current_page = current_page,
            .per_page = per_page,
            .total = total,
            .last_page = last_page,
        };
    }

    pub fn hasMore(self: *Paginator) bool {
        return self.current_page < self.last_page;
    }

    pub fn hasPrevious(self: *Paginator) bool {
        return self.current_page > 1;
    }

    pub fn toJSON(self: *Paginator) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"data\": [], \"current_page\": {d}, \"per_page\": {d}, \"total\": {d}, \"last_page\": {d}}}",
            .{ self.current_page, self.per_page, self.total, self.last_page },
        );
    }
};
