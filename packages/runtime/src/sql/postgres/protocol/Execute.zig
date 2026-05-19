// Copied verbatim from bun/src/sql/postgres/protocol/Execute.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres Execute (F) packet. Wire writer body references the wave-16
// NewWriter stub method surface (writer.write, writer.string,
// writer.int4, writer.length); calls trip `@compileError` until the
// real writer returns, so this leaf is declaration-only today.

max_rows: int4 = 0,
p: PortalOrPreparedStatement,

pub fn writeInternal(
    this: *const @This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    try writer.write("E");
    const length = try writer.length();
    if (this.p == .portal)
        try writer.string(this.p.portal)
    else
        try writer.write(&[_]u8{0});
    try writer.int4(this.max_rows);
    try length.write();
}

pub const write = WriteWrap(@This(), writeInternal).write;

test "Execute defaults to max_rows 0" {
    const std = @import("std");
    const e: @This() = .{ .p = .{ .portal = "p1" } };
    try std.testing.expectEqual(@as(int4, 0), e.max_rows);
    try std.testing.expectEqualStrings("p1", e.p.slice());
}

const NewWriter = @import("./NewWriter.zig").NewWriter;
const PortalOrPreparedStatement = @import("./PortalOrPreparedStatement.zig").PortalOrPreparedStatement;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;

const int_types = @import("../types/int_types.zig");
const int4 = int_types.int4;
