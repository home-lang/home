// Copied from bun/src/sql/mysql/MySQLParam.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Pure parameter descriptor used by the wire-protocol encoders
// (`Query.zig`, `PreparedStatement.zig`). Split from `MySQLStatement`
// so the protocol layer has no dependency on the JSC-coupled statement
// struct that lives in `sql_jsc/`. Imports rewritten: none required
// — both `FieldType` (from MySQLTypes) and `ColumnDefinition41.ColumnFlags`
// (from the wave-23 protocol port) are already in tree.

pub const Param = struct {
    type: types.FieldType,
    flags: ColumnDefinition41.ColumnFlags,
};

test "MySQLParam.Param defaults compile with zero ColumnFlags" {
    const std = @import("std");
    const p: Param = .{
        .type = .MYSQL_TYPE_NULL,
        .flags = .{},
    };
    try std.testing.expectEqual(types.FieldType.MYSQL_TYPE_NULL, p.type);
    try std.testing.expectEqual(false, p.flags.NOT_NULL);
}

const ColumnDefinition41 = @import("./protocol/ColumnDefinition41.zig");
const types = @import("./MySQLTypes.zig");
