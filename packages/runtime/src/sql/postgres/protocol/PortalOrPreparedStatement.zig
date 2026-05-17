// Copied verbatim from bun/src/sql/postgres/protocol/PortalOrPreparedStatement.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.

pub const PortalOrPreparedStatement = union(enum) {
    portal: []const u8,
    prepared_statement: []const u8,

    pub fn slice(this: @This()) []const u8 {
        return switch (this) {
            .portal => this.portal,
            .prepared_statement => this.prepared_statement,
        };
    }

    pub fn tag(this: @This()) u8 {
        return switch (this) {
            .portal => 'P',
            .prepared_statement => 'S',
        };
    }
};
