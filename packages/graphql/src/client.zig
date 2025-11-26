const std = @import("std");

/// GraphQL client implementation
/// Type-safe query builder and execution
pub const GraphQLClient = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    headers: std.StringHashMap([]const u8),

    pub const Error = error{
        HttpError,
        InvalidResponse,
        InvalidJSON,
        QueryError,
        NetworkError,
        OutOfMemory,
        InvalidEndpoint,
    };

    /// GraphQL response
    pub const Response = struct {
        data: ?std.json.Value,
        errors: ?[]GraphQLError,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Response) void {
            if (self.errors) |errors| {
                self.allocator.free(errors);
            }
        }
    };

    pub const GraphQLError = struct {
        message: []const u8,
        path: ?[]const []const u8,
        locations: ?[]Location,

        pub const Location = struct {
            line: usize,
            column: usize,
        };
    };

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !GraphQLClient {
        return GraphQLClient{
            .allocator = allocator,
            .endpoint = try allocator.dupe(u8, endpoint),
            .headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *GraphQLClient) void {
        self.allocator.free(self.endpoint);
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
    }

    /// Set HTTP header
    pub fn setHeader(self: *GraphQLClient, name: []const u8, value: []const u8) !void {
        const key = try self.allocator.dupe(u8, name);
        const val = try self.allocator.dupe(u8, value);
        try self.headers.put(key, val);
    }

    /// Execute a GraphQL query
    pub fn query(self: *GraphQLClient, query_str: []const u8, variables: ?std.json.Value) !Response {
        return try self.execute(query_str, variables, null);
    }

    /// Execute a GraphQL mutation
    pub fn mutation(self: *GraphQLClient, mutation_str: []const u8, variables: ?std.json.Value) !Response {
        return try self.execute(mutation_str, variables, null);
    }

    /// Execute a GraphQL subscription (returns immediately, use WebSocket for real subscriptions)
    pub fn subscription(self: *GraphQLClient, subscription_str: []const u8, variables: ?std.json.Value) !Response {
        return try self.execute(subscription_str, variables, null);
    }

    fn execute(self: *GraphQLClient, query_str: []const u8, variables: ?std.json.Value, operation_name: ?[]const u8) !Response {
        _ = operation_name; // Reserved for future use

        // Build request body
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        const writer = body.writer();
        try writer.writeAll("{\"query\":");
        try std.json.stringify(query_str, .{}, writer);

        if (variables) |vars| {
            try writer.writeAll(",\"variables\":");
            try std.json.stringify(vars, .{}, writer);
        }

        try writer.writeAll("}");

        // Simulate HTTP request (in real implementation, use HTTP client)
        // For testing, we'll return a mock response
        return Response{
            .data = null,
            .errors = null,
            .allocator = self.allocator,
        };
    }
};

/// GraphQL query builder for type-safe query construction
pub const QueryBuilder = struct {
    allocator: std.mem.Allocator,
    operation_type: OperationType,
    operation_name: ?[]const u8,
    fields: std.ArrayList(Field),
    variables: std.ArrayList(Variable),
    fragments: std.ArrayList(Fragment),

    pub const OperationType = enum {
        query,
        mutation,
        subscription,
    };

    pub const Field = struct {
        name: []const u8,
        alias: ?[]const u8,
        arguments: std.ArrayList(Argument),
        selections: std.ArrayList(Field),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, name: []const u8) Field {
            return Field{
                .name = name,
                .alias = null,
                .arguments = std.ArrayList(Argument).init(allocator),
                .selections = std.ArrayList(Field).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Field) void {
            self.arguments.deinit();
            for (self.selections.items) |*selection| {
                selection.deinit();
            }
            self.selections.deinit();
        }

        pub fn withAlias(self: *Field, alias: []const u8) *Field {
            self.alias = alias;
            return self;
        }

        pub fn withArg(self: *Field, name: []const u8, value: Value) !*Field {
            try self.arguments.append(Argument{
                .name = name,
                .value = value,
            });
            return self;
        }

        pub fn select(self: *Field, field: Field) !*Field {
            try self.selections.append(field);
            return self;
        }
    };

    pub const Argument = struct {
        name: []const u8,
        value: Value,
    };

    pub const Value = union(enum) {
        int: i64,
        float: f64,
        string: []const u8,
        boolean: bool,
        null: void,
        @"enum": []const u8,
        list: []const Value,
        object: []const ObjectField,
        variable: []const u8,

        pub const ObjectField = struct {
            name: []const u8,
            value: Value,
        };
    };

    pub const Variable = struct {
        name: []const u8,
        type_name: []const u8,
        default_value: ?Value,
    };

    pub const Fragment = struct {
        name: []const u8,
        type_condition: []const u8,
        selections: []const Field,
    };

    pub fn init(allocator: std.mem.Allocator, operation_type: OperationType) QueryBuilder {
        return QueryBuilder{
            .allocator = allocator,
            .operation_type = operation_type,
            .operation_name = null,
            .fields = std.ArrayList(Field).init(allocator),
            .variables = std.ArrayList(Variable).init(allocator),
            .fragments = std.ArrayList(Fragment).init(allocator),
        };
    }

    pub fn deinit(self: *QueryBuilder) void {
        for (self.fields.items) |*field| {
            field.deinit();
        }
        self.fields.deinit();
        self.variables.deinit();
        self.fragments.deinit();
    }

    pub fn withName(self: *QueryBuilder, name: []const u8) *QueryBuilder {
        self.operation_name = name;
        return self;
    }

    pub fn addVariable(self: *QueryBuilder, name: []const u8, type_name: []const u8, default_value: ?Value) !*QueryBuilder {
        try self.variables.append(Variable{
            .name = name,
            .type_name = type_name,
            .default_value = default_value,
        });
        return self;
    }

    pub fn addField(self: *QueryBuilder, field: Field) !*QueryBuilder {
        try self.fields.append(field);
        return self;
    }

    /// Build the GraphQL query string
    pub fn build(self: *QueryBuilder) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        const writer = output.writer();

        // Write operation type
        switch (self.operation_type) {
            .query => try writer.writeAll("query"),
            .mutation => try writer.writeAll("mutation"),
            .subscription => try writer.writeAll("subscription"),
        }

        // Write operation name if present
        if (self.operation_name) |name| {
            try writer.writeAll(" ");
            try writer.writeAll(name);
        }

        // Write variables if present
        if (self.variables.items.len > 0) {
            try writer.writeAll("(");
            for (self.variables.items, 0..) |variable, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll("$");
                try writer.writeAll(variable.name);
                try writer.writeAll(": ");
                try writer.writeAll(variable.type_name);

                if (variable.default_value) |default| {
                    try writer.writeAll(" = ");
                    try self.writeValue(writer, default);
                }
            }
            try writer.writeAll(")");
        }

        // Write selection set
        try writer.writeAll(" {\n");
        for (self.fields.items) |field| {
            try self.writeField(writer, field, 1);
        }
        try writer.writeAll("}");

        // Write fragments
        for (self.fragments.items) |fragment| {
            try writer.writeAll("\n\nfragment ");
            try writer.writeAll(fragment.name);
            try writer.writeAll(" on ");
            try writer.writeAll(fragment.type_condition);
            try writer.writeAll(" {\n");
            for (fragment.selections) |field| {
                try self.writeField(writer, field, 1);
            }
            try writer.writeAll("}");
        }

        return try output.toOwnedSlice();
    }

    fn writeField(self: *QueryBuilder, writer: anytype, field: Field, indent: usize) !void {
        // Indentation
        for (0..indent) |_| {
            try writer.writeAll("  ");
        }

        // Alias
        if (field.alias) |alias| {
            try writer.writeAll(alias);
            try writer.writeAll(": ");
        }

        // Field name
        try writer.writeAll(field.name);

        // Arguments
        if (field.arguments.items.len > 0) {
            try writer.writeAll("(");
            for (field.arguments.items, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(arg.name);
                try writer.writeAll(": ");
                try self.writeValue(writer, arg.value);
            }
            try writer.writeAll(")");
        }

        // Selection set
        if (field.selections.items.len > 0) {
            try writer.writeAll(" {\n");
            for (field.selections.items) |selection| {
                try self.writeField(writer, selection, indent + 1);
            }
            for (0..indent) |_| {
                try writer.writeAll("  ");
            }
            try writer.writeAll("}\n");
        } else {
            try writer.writeAll("\n");
        }
    }

    fn writeValue(self: *QueryBuilder, writer: anytype, value: Value) !void {
        _ = self;
        switch (value) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |v| {
                try writer.writeAll("\"");
                try writer.writeAll(v);
                try writer.writeAll("\"");
            },
            .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
            .null => try writer.writeAll("null"),
            .@"enum" => |v| try writer.writeAll(v),
            .list => |items| {
                try writer.writeAll("[");
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.writeValue(writer, item);
                }
                try writer.writeAll("]");
            },
            .object => |fields| {
                try writer.writeAll("{");
                for (fields, 0..) |field, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(field.name);
                    try writer.writeAll(": ");
                    try self.writeValue(writer, field.value);
                }
                try writer.writeAll("}");
            },
            .variable => |v| {
                try writer.writeAll("$");
                try writer.writeAll(v);
            },
        }
    }
};

/// Schema introspection helpers
pub const Introspection = struct {
    /// Build introspection query
    pub fn buildIntrospectionQuery(allocator: std.mem.Allocator) ![]u8 {
        var builder = QueryBuilder.init(allocator, .query);
        defer builder.deinit();

        var schema_field = QueryBuilder.Field.init(allocator, "__schema");
        var types_field = QueryBuilder.Field.init(allocator, "types");

        var name_field = QueryBuilder.Field.init(allocator, "name");
        var kind_field = QueryBuilder.Field.init(allocator, "kind");
        var description_field = QueryBuilder.Field.init(allocator, "description");

        try types_field.select(name_field);
        try types_field.select(kind_field);
        try types_field.select(description_field);

        try schema_field.select(types_field);
        try builder.addField(schema_field);

        return try builder.build();
    }
};

test "query builder basic query" {
    const allocator = std.testing.allocator;

    var builder = QueryBuilder.init(allocator, .query);
    defer builder.deinit();

    var user_field = QueryBuilder.Field.init(allocator, "user");
    try user_field.withArg("id", QueryBuilder.Value{ .int = 123 });

    var id_field = QueryBuilder.Field.init(allocator, "id");
    var name_field = QueryBuilder.Field.init(allocator, "name");

    try user_field.select(id_field);
    try user_field.select(name_field);

    try builder.addField(user_field);

    const query_str = try builder.build();
    defer allocator.free(query_str);

    try std.testing.expect(std.mem.indexOf(u8, query_str, "query {") != null);
    try std.testing.expect(std.mem.indexOf(u8, query_str, "user(id: 123)") != null);
    try std.testing.expect(std.mem.indexOf(u8, query_str, "id") != null);
    try std.testing.expect(std.mem.indexOf(u8, query_str, "name") != null);
}

test "query builder with variables" {
    const allocator = std.testing.allocator;

    var builder = QueryBuilder.init(allocator, .query);
    defer builder.deinit();

    _ = try builder.withName("GetUser")
        .addVariable("userId", "ID!", null);

    var user_field = QueryBuilder.Field.init(allocator, "user");
    try user_field.withArg("id", QueryBuilder.Value{ .variable = "userId" });

    var id_field = QueryBuilder.Field.init(allocator, "id");
    try user_field.select(id_field);

    try builder.addField(user_field);

    const query_str = try builder.build();
    defer allocator.free(query_str);

    try std.testing.expect(std.mem.indexOf(u8, query_str, "query GetUser($userId: ID!)") != null);
    try std.testing.expect(std.mem.indexOf(u8, query_str, "user(id: $userId)") != null);
}

test "query builder mutation" {
    const allocator = std.testing.allocator;

    var builder = QueryBuilder.init(allocator, .mutation);
    defer builder.deinit();

    var create_user_field = QueryBuilder.Field.init(allocator, "createUser");
    try create_user_field.withArg("name", QueryBuilder.Value{ .string = "John Doe" });
    try create_user_field.withArg("age", QueryBuilder.Value{ .int = 30 });

    var id_field = QueryBuilder.Field.init(allocator, "id");
    try create_user_field.select(id_field);

    try builder.addField(create_user_field);

    const mutation_str = try builder.build();
    defer allocator.free(mutation_str);

    try std.testing.expect(std.mem.indexOf(u8, mutation_str, "mutation {") != null);
    try std.testing.expect(std.mem.indexOf(u8, mutation_str, "createUser(") != null);
}

test "graphql client init" {
    const allocator = std.testing.allocator;

    var client = try GraphQLClient.init(allocator, "https://api.example.com/graphql");
    defer client.deinit();

    try client.setHeader("Authorization", "Bearer token123");

    try std.testing.expectEqualStrings("https://api.example.com/graphql", client.endpoint);
}

test "introspection query" {
    const allocator = std.testing.allocator;

    const query = try Introspection.buildIntrospectionQuery(allocator);
    defer allocator.free(query);

    try std.testing.expect(std.mem.indexOf(u8, query, "__schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "types") != null);
}
