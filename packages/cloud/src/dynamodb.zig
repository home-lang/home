const std = @import("std");
const aws = @import("aws.zig");

/// DynamoDB attribute value types
pub const AttributeValue = union(enum) {
    S: []const u8, // String
    N: []const u8, // Number (as string)
    B: []const u8, // Binary
    SS: []const []const u8, // String Set
    NS: []const []const u8, // Number Set
    BS: []const []const u8, // Binary Set
    M: std.StringHashMap(AttributeValue), // Map
    L: []const AttributeValue, // List
    NULL: bool,
    BOOL: bool,

    pub fn string(value: []const u8) AttributeValue {
        return .{ .S = value };
    }

    pub fn number(value: []const u8) AttributeValue {
        return .{ .N = value };
    }

    pub fn boolean(value: bool) AttributeValue {
        return .{ .BOOL = value };
    }

    pub fn nil() AttributeValue {
        return .{ .NULL = true };
    }
};

/// Key schema element
pub const KeySchemaElement = struct {
    attribute_name: []const u8,
    key_type: KeyType,
};

pub const KeyType = enum {
    HASH,
    RANGE,

    pub fn toString(self: KeyType) []const u8 {
        return switch (self) {
            .HASH => "HASH",
            .RANGE => "RANGE",
        };
    }
};

/// Attribute definition
pub const AttributeDefinition = struct {
    attribute_name: []const u8,
    attribute_type: ScalarAttributeType,
};

pub const ScalarAttributeType = enum {
    S,
    N,
    B,

    pub fn toString(self: ScalarAttributeType) []const u8 {
        return switch (self) {
            .S => "S",
            .N => "N",
            .B => "B",
        };
    }
};

/// Provisioned throughput
pub const ProvisionedThroughput = struct {
    read_capacity_units: u64,
    write_capacity_units: u64,
};

/// Billing mode
pub const BillingMode = enum {
    PROVISIONED,
    PAY_PER_REQUEST,

    pub fn toString(self: BillingMode) []const u8 {
        return switch (self) {
            .PROVISIONED => "PROVISIONED",
            .PAY_PER_REQUEST => "PAY_PER_REQUEST",
        };
    }
};

/// Comparison operator for conditions
pub const ComparisonOperator = enum {
    EQ,
    NE,
    LE,
    LT,
    GE,
    GT,
    BETWEEN,
    BEGINS_WITH,
    CONTAINS,
    NOT_CONTAINS,
    EXISTS,
    NOT_EXISTS,
    IN,

    pub fn toString(self: ComparisonOperator) []const u8 {
        return switch (self) {
            .EQ => "=",
            .NE => "<>",
            .LE => "<=",
            .LT => "<",
            .GE => ">=",
            .GT => ">",
            .BETWEEN => "BETWEEN",
            .BEGINS_WITH => "begins_with",
            .CONTAINS => "contains",
            .NOT_CONTAINS => "NOT contains",
            .EXISTS => "attribute_exists",
            .NOT_EXISTS => "attribute_not_exists",
            .IN => "IN",
        };
    }
};

/// Return values for update/put operations
pub const ReturnValue = enum {
    NONE,
    ALL_OLD,
    UPDATED_OLD,
    ALL_NEW,
    UPDATED_NEW,

    pub fn toString(self: ReturnValue) []const u8 {
        return switch (self) {
            .NONE => "NONE",
            .ALL_OLD => "ALL_OLD",
            .UPDATED_OLD => "UPDATED_OLD",
            .ALL_NEW => "ALL_NEW",
            .UPDATED_NEW => "UPDATED_NEW",
        };
    }
};

/// Item type alias
pub const Item = std.StringHashMap(AttributeValue);

/// DynamoDB client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: aws.Config,
    signer: aws.Signer,

    const Self = @This();
    const SERVICE = "dynamodb";

    pub fn init(allocator: std.mem.Allocator, config: aws.Config) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .signer = aws.Signer.init(allocator, config.credentials, config.region.toString(), SERVICE),
        };
    }

    /// Create a table
    pub fn createTable(
        self: *Self,
        table_name: []const u8,
        key_schema: []const KeySchemaElement,
        attribute_definitions: []const AttributeDefinition,
        billing_mode: BillingMode,
    ) !void {
        _ = self;
        _ = table_name;
        _ = key_schema;
        _ = attribute_definitions;
        _ = billing_mode;
    }

    /// Delete a table
    pub fn deleteTable(self: *Self, table_name: []const u8) !void {
        _ = self;
        _ = table_name;
    }

    /// List all tables
    pub fn listTables(self: *Self) ![][]const u8 {
        return &[_][]const u8{};
    }

    /// Describe a table
    pub fn describeTable(self: *Self, table_name: []const u8) !TableDescription {
        _ = table_name;
        return TableDescription{
            .table_name = try self.allocator.dupe(u8, table_name),
            .table_status = .ACTIVE,
            .item_count = 0,
            .allocator = self.allocator,
        };
    }

    /// Put an item
    pub fn putItem(self: *Self, table_name: []const u8, item: Item) !void {
        _ = self;
        _ = table_name;
        _ = item;
    }

    /// Put an item with options
    pub const PutItemOptions = struct {
        condition_expression: ?[]const u8 = null,
        expression_attribute_names: ?std.StringHashMap([]const u8) = null,
        expression_attribute_values: ?std.StringHashMap(AttributeValue) = null,
        return_values: ReturnValue = .NONE,
    };

    pub fn putItemWithOptions(
        self: *Self,
        table_name: []const u8,
        item: Item,
        options: PutItemOptions,
    ) !?Item {
        _ = self;
        _ = table_name;
        _ = item;
        _ = options;
        return null;
    }

    /// Get an item
    pub fn getItem(self: *Self, table_name: []const u8, key: Item) !?Item {
        _ = self;
        _ = table_name;
        _ = key;
        return null;
    }

    /// Get an item with options
    pub const GetItemOptions = struct {
        consistent_read: bool = false,
        projection_expression: ?[]const u8 = null,
        expression_attribute_names: ?std.StringHashMap([]const u8) = null,
    };

    pub fn getItemWithOptions(
        self: *Self,
        table_name: []const u8,
        key: Item,
        options: GetItemOptions,
    ) !?Item {
        _ = self;
        _ = table_name;
        _ = key;
        _ = options;
        return null;
    }

    /// Delete an item
    pub fn deleteItem(self: *Self, table_name: []const u8, key: Item) !void {
        _ = self;
        _ = table_name;
        _ = key;
    }

    /// Update an item
    pub const UpdateItemOptions = struct {
        update_expression: []const u8,
        condition_expression: ?[]const u8 = null,
        expression_attribute_names: ?std.StringHashMap([]const u8) = null,
        expression_attribute_values: ?std.StringHashMap(AttributeValue) = null,
        return_values: ReturnValue = .NONE,
    };

    pub fn updateItem(
        self: *Self,
        table_name: []const u8,
        key: Item,
        options: UpdateItemOptions,
    ) !?Item {
        _ = self;
        _ = table_name;
        _ = key;
        _ = options;
        return null;
    }

    /// Query items
    pub const QueryOptions = struct {
        key_condition_expression: []const u8,
        filter_expression: ?[]const u8 = null,
        projection_expression: ?[]const u8 = null,
        expression_attribute_names: ?std.StringHashMap([]const u8) = null,
        expression_attribute_values: ?std.StringHashMap(AttributeValue) = null,
        limit: ?u32 = null,
        scan_index_forward: bool = true,
        consistent_read: bool = false,
        index_name: ?[]const u8 = null,
        exclusive_start_key: ?Item = null,
    };

    pub fn query(self: *Self, table_name: []const u8, options: QueryOptions) !QueryResult {
        _ = self;
        _ = table_name;
        _ = options;

        return QueryResult{
            .items = &[_]Item{},
            .count = 0,
            .scanned_count = 0,
            .last_evaluated_key = null,
        };
    }

    /// Scan all items
    pub const ScanOptions = struct {
        filter_expression: ?[]const u8 = null,
        projection_expression: ?[]const u8 = null,
        expression_attribute_names: ?std.StringHashMap([]const u8) = null,
        expression_attribute_values: ?std.StringHashMap(AttributeValue) = null,
        limit: ?u32 = null,
        consistent_read: bool = false,
        index_name: ?[]const u8 = null,
        exclusive_start_key: ?Item = null,
        segment: ?u32 = null,
        total_segments: ?u32 = null,
    };

    pub fn scan(self: *Self, table_name: []const u8, options: ScanOptions) !QueryResult {
        _ = self;
        _ = table_name;
        _ = options;

        return QueryResult{
            .items = &[_]Item{},
            .count = 0,
            .scanned_count = 0,
            .last_evaluated_key = null,
        };
    }

    /// Batch get items
    pub fn batchGetItem(
        self: *Self,
        request_items: std.StringHashMap(BatchGetRequest),
    ) !std.StringHashMap([]Item) {
        _ = self;
        _ = request_items;

        return std.StringHashMap([]Item).init(self.allocator);
    }

    /// Batch write items
    pub fn batchWriteItem(
        self: *Self,
        request_items: std.StringHashMap([]WriteRequest),
    ) !void {
        _ = self;
        _ = request_items;
    }

    /// Transaction write
    pub fn transactWriteItems(self: *Self, items: []const TransactWriteItem) !void {
        _ = self;
        _ = items;
    }

    /// Transaction get
    pub fn transactGetItems(self: *Self, items: []const TransactGetItem) ![]?Item {
        _ = self;
        _ = items;
        return &[_]?Item{};
    }
};

/// Query/Scan result
pub const QueryResult = struct {
    items: []const Item,
    count: u32,
    scanned_count: u32,
    last_evaluated_key: ?Item,
};

/// Table description
pub const TableDescription = struct {
    table_name: []const u8,
    table_status: TableStatus,
    item_count: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TableDescription) void {
        self.allocator.free(self.table_name);
    }
};

pub const TableStatus = enum {
    CREATING,
    UPDATING,
    DELETING,
    ACTIVE,
    INACCESSIBLE_ENCRYPTION_CREDENTIALS,
    ARCHIVING,
    ARCHIVED,
};

/// Batch get request
pub const BatchGetRequest = struct {
    keys: []const Item,
    consistent_read: bool = false,
    projection_expression: ?[]const u8 = null,
};

/// Write request for batch operations
pub const WriteRequest = union(enum) {
    put_request: Item,
    delete_request: Item,
};

/// Transaction write item
pub const TransactWriteItem = union(enum) {
    put: struct { table_name: []const u8, item: Item },
    update: struct { table_name: []const u8, key: Item, update_expression: []const u8 },
    delete: struct { table_name: []const u8, key: Item },
    condition_check: struct { table_name: []const u8, key: Item, condition_expression: []const u8 },
};

/// Transaction get item
pub const TransactGetItem = struct {
    table_name: []const u8,
    key: Item,
    projection_expression: ?[]const u8 = null,
};

// Tests
test "dynamodb client init" {
    const creds = aws.Credentials.init("key", "secret");
    const config = aws.Config.init(creds, .us_east_1);
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, config);
    _ = &client;
}

test "attribute value creation" {
    const s = AttributeValue.string("hello");
    try std.testing.expectEqualStrings("hello", s.S);

    const n = AttributeValue.number("42");
    try std.testing.expectEqualStrings("42", n.N);

    const b = AttributeValue.boolean(true);
    try std.testing.expect(b.BOOL);
}
