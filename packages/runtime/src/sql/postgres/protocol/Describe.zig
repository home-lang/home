// Copied verbatim from bun/src/sql/postgres/protocol/Describe.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres Describe (F) packet. Wire writer body references the wave-16
// NewWriter stub method surface (writer.write, writer.string,
// writer.length); calls trip `@compileError` until the real writer
// returns, so this leaf is declaration-only today.

p: PortalOrPreparedStatement,

pub fn writeInternal(
    this: *const @This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const message = this.p.slice();
    try writer.write(&[_]u8{
        'D',
    });
    const length = try writer.length();
    try writer.write(&[_]u8{
        this.p.tag(),
    });
    try writer.string(message);
    try length.write();
}

pub const write = WriteWrap(@This(), writeInternal).write;

test "Describe holds a PortalOrPreparedStatement" {
    const std = @import("std");
    const d: @This() = .{ .p = .{ .prepared_statement = "stmt_x" } };
    try std.testing.expectEqualStrings("stmt_x", d.p.slice());
    try std.testing.expectEqual(@as(u8, 'S'), d.p.tag());
}

const NewWriter = @import("./NewWriter.zig").NewWriter;

const PortalOrPreparedStatement = @import("./PortalOrPreparedStatement.zig").PortalOrPreparedStatement;

const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
