const std = @import("std");
const logging = @import("logging");

test "public logging declarations compile" {
    std.testing.refAllDecls(logging);
    std.testing.refAllDecls(logging.Logger);
    std.testing.refAllDecls(logging.ConsoleHandler);
    std.testing.refAllDecls(logging.JsonHandler);
    std.testing.refAllDecls(logging.FileHandler);
    std.testing.refAllDecls(logging.MemoryHandler);
}

test "public memory handler records structured logs" {
    const handler = try logging.MemoryHandler.init(std.testing.allocator, std.testing.io);
    var logger = logging.Logger.init(std.testing.allocator, std.testing.io, "public-test");
    defer logger.deinit();
    try logger.addHandler(handler.handler());

    logger.infoWith("ready", &.{logging.Field.boolean("healthy", true)});

    const records = handler.getRecords();
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqual(logging.Level.info, records[0].level);
    try std.testing.expectEqualStrings("ready", records[0].message);
    try std.testing.expectEqualStrings("public-test", records[0].logger_name.?);
}
