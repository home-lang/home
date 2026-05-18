// Copied verbatim from bun/src/sql/mysql/protocol/CommandType.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.

// Command packet types
pub const CommandType = enum(u8) {
    COM_QUIT = 0x01,
    COM_INIT_DB = 0x02,
    COM_QUERY = 0x03,
    COM_FIELD_LIST = 0x04,
    COM_CREATE_DB = 0x05,
    COM_DROP_DB = 0x06,
    COM_REFRESH = 0x07,
    COM_SHUTDOWN = 0x08,
    COM_STATISTICS = 0x09,
    COM_PROCESS_INFO = 0x0a,
    COM_CONNECT = 0x0b,
    COM_PROCESS_KILL = 0x0c,
    COM_DEBUG = 0x0d,
    COM_PING = 0x0e,
    COM_TIME = 0x0f,
    COM_DELAYED_INSERT = 0x10,
    COM_CHANGE_USER = 0x11,
    COM_BINLOG_DUMP = 0x12,
    COM_TABLE_DUMP = 0x13,
    COM_CONNECT_OUT = 0x14,
    COM_REGISTER_SLAVE = 0x15,
    COM_STMT_PREPARE = 0x16,
    COM_STMT_EXECUTE = 0x17,
    COM_STMT_SEND_LONG_DATA = 0x18,
    COM_STMT_CLOSE = 0x19,
    COM_STMT_RESET = 0x1a,
    COM_SET_OPTION = 0x1b,
    COM_STMT_FETCH = 0x1c,
    COM_DAEMON = 0x1d,
    COM_BINLOG_DUMP_GTID = 0x1e,
    COM_RESET_CONNECTION = 0x1f,
};

test "CommandType encodes canonical wire bytes" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(CommandType.COM_QUIT));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(CommandType.COM_QUERY));
    try std.testing.expectEqual(@as(u8, 0x16), @intFromEnum(CommandType.COM_STMT_PREPARE));
    try std.testing.expectEqual(@as(u8, 0x17), @intFromEnum(CommandType.COM_STMT_EXECUTE));
    try std.testing.expectEqual(@as(u8, 0x1f), @intFromEnum(CommandType.COM_RESET_CONNECTION));
}
