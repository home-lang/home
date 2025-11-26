const std = @import("std");

/// GraphQL package - client and query builder
pub const GraphQLClient = @import("client.zig").GraphQLClient;
pub const QueryBuilder = @import("client.zig").QueryBuilder;
pub const Introspection = @import("client.zig").Introspection;
pub const Field = @import("client.zig").QueryBuilder.Field;
pub const Value = @import("client.zig").QueryBuilder.Value;

test {
    @import("std").testing.refAllDecls(@This());
}
