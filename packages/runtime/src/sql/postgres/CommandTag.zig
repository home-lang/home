// Copied from bun/src/sql/postgres/CommandTag.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Rewrites:
//   - @import("bun") -> @import("home")
//   - bun.ComptimeEnumMap -> home_rt.ComptimeEnumMap
//   - bun.strings.indexOfChar -> home_rt.strings.indexOfChar
//   - bun.Output.scoped -> home_rt.Output.scoped
//
// JSC-bridge `toJSTag` / `toJSNumber` re-exports are omitted until the
// matching sql_jsc/postgres bridge lands in Home.

pub const CommandTag = union(enum) {
    // For an INSERT command, the tag is INSERT oid rows, where rows is the
    // number of rows inserted. oid used to be the object ID of the inserted
    // row if rows was 1 and the target table had OIDs, but OIDs system
    // columns are not supported anymore; therefore oid is always 0.
    INSERT: u64,
    // For a DELETE command, the tag is DELETE rows where rows is the number
    // of rows deleted.
    DELETE: u64,
    // For an UPDATE command, the tag is UPDATE rows where rows is the
    // number of rows updated.
    UPDATE: u64,
    // For a MERGE command, the tag is MERGE rows where rows is the number
    // of rows inserted, updated, or deleted.
    MERGE: u64,
    // For a SELECT or CREATE TABLE AS command, the tag is SELECT rows where
    // rows is the number of rows retrieved.
    SELECT: u64,
    // For a MOVE command, the tag is MOVE rows where rows is the number of
    // rows the cursor's position has been changed by.
    MOVE: u64,
    // For a FETCH command, the tag is FETCH rows where rows is the number
    // of rows that have been retrieved from the cursor.
    FETCH: u64,
    // For a COPY command, the tag is COPY rows where rows is the number of
    // rows copied. (Note: the row count appears only in PostgreSQL 8.2 and
    // later.)
    COPY: u64,

    other: []const u8,

    const KnownCommand = enum {
        INSERT,
        DELETE,
        UPDATE,
        MERGE,
        SELECT,
        MOVE,
        FETCH,
        COPY,

        pub const Map = home_rt.ComptimeEnumMap(KnownCommand);
    };

    /// JSC-bridge re-exports (now that sql_jsc/postgres is wired).
    pub const toJSTag = @import("../../sql_jsc/postgres/command_tag_jsc.zig").toJSTag;
    pub const toJSNumber = @import("../../sql_jsc/postgres/command_tag_jsc.zig").toJSNumber;

    pub fn init(tag: []const u8) CommandTag {
        const first_space_index = home_rt.strings.indexOfChar(tag, ' ') orelse return .{ .other = tag };
        const cmd = KnownCommand.Map.get(tag[0..first_space_index]) orelse return .{
            .other = tag,
        };

        const number = brk: {
            switch (cmd) {
                .INSERT => {
                    var remaining = tag[@min(first_space_index + 1, tag.len)..];
                    const second_space = home_rt.strings.indexOfChar(remaining, ' ') orelse return .{ .other = tag };
                    remaining = remaining[@min(second_space + 1, remaining.len)..];
                    break :brk std.fmt.parseInt(u64, remaining, 0) catch |err| {
                        debug("CommandTag failed to parse number: {s}", .{@errorName(err)});
                        return .{ .other = tag };
                    };
                },
                else => {
                    const after_tag = tag[@min(first_space_index + 1, tag.len)..];
                    break :brk std.fmt.parseInt(u64, after_tag, 0) catch |err| {
                        debug("CommandTag failed to parse number: {s}", .{@errorName(err)});
                        return .{ .other = tag };
                    };
                },
            }
        };

        switch (cmd) {
            inline else => |t| return @unionInit(CommandTag, @tagName(t), number),
        }
    }
};

const debug = home_rt.Output.scoped(.Postgres, .visible);

const home_rt = @import("home");
const std = @import("std");

test "CommandTag parses known row-count tags" {
    try std.testing.expectEqual(CommandTag{ .INSERT = 3 }, CommandTag.init("INSERT 0 3"));
    try std.testing.expectEqual(CommandTag{ .SELECT = 12 }, CommandTag.init("SELECT 12"));
    try std.testing.expectEqual(CommandTag{ .UPDATE = 2 }, CommandTag.init("UPDATE 2"));
    try std.testing.expectEqual(CommandTag{ .MERGE = 7 }, CommandTag.init("MERGE 7"));
    try std.testing.expectEqual(CommandTag{ .COPY = 4 }, CommandTag.init("COPY 4"));
}

test "CommandTag preserves unknown or malformed tags as other" {
    try std.testing.expectEqualStrings("VACUUM", CommandTag.init("VACUUM").other);
    try std.testing.expectEqualStrings("SELECT nope", CommandTag.init("SELECT nope").other);
    try std.testing.expectEqualStrings("INSERT 0 nope", CommandTag.init("INSERT 0 nope").other);
}
