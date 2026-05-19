// Copied from bun/src/sql/postgres/protocol/StartupMessage.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Postgres startup packet — client → server first message. Carries
// protocol-version constant (196608 = 3.0) + key/value pairs (`user`,
// `database`, `client_encoding`, optional additional `options`). No
// `@import("bun")` references upstream. Imports rewritten:
// `../PostgresTypes.zig` (re-exports int_types) is replaced with a
// direct import of `../types/int_types.zig`. The writer body reaches
// into the wave-16 NewWriter stub method surface (writer.write/.int4/
// .string) and trips a natural compile error if exercised today.

const StartupMessage = @This();

user: Data,
database: Data,
options: Data = Data{ .empty = {} },

pub fn writeInternal(
    this: *const @This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const user = this.user.slice();
    const database = this.database.slice();
    const options = this.options.slice();
    const count: usize = @sizeOf((int4)) + @sizeOf((int4)) + zFieldCount("user", user) + zFieldCount("database", database) + zFieldCount("client_encoding", "UTF8") + options.len + 1;

    const header = toBytes(Int32(@as(u32, @truncate(count))));
    try writer.write(&header);
    try writer.int4(196608);

    try writer.string("user");
    if (user.len > 0)
        try writer.string(user);

    try writer.string("database");

    if (database.len == 0) {
        // The database to connect to. Defaults to the user name.
        try writer.string(user);
    } else {
        try writer.string(database);
    }
    try writer.string("client_encoding");
    try writer.string("UTF8");
    if (options.len > 0) {
        try writer.write(options);
    }
    try writer.write(&[_]u8{0});
}

pub const write = WriteWrap(@This(), writeInternal).write;

test "StartupMessage holds user + database + options" {
    const s: StartupMessage = .{
        .user = .{ .empty = {} },
        .database = .{ .empty = {} },
    };
    try std.testing.expectEqualStrings("", s.user.slice());
    try std.testing.expectEqualStrings("", s.database.slice());
    try std.testing.expectEqualStrings("", s.options.slice());
}

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const NewWriter = @import("./NewWriter.zig").NewWriter;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
const zFieldCount = @import("./zHelpers.zig").zFieldCount;
const toBytes = std.mem.toBytes;

const int_types = @import("../types/int_types.zig");
const Int32 = int_types.Int32;
const int4 = int_types.int4;
