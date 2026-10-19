const std = @import("std");
const temporal = @import("basics_temporal");
const testing = std.testing;

test "Temporal.Now uses the real std.Io clock" {
    const before = std.Io.Clock.real.now(testing.io).toNanoseconds();
    const instant = temporal.Now.instant();
    const after = std.Io.Clock.real.now(testing.io).toNanoseconds();
    try testing.expect(instant.epochNanoseconds() >= before);
    try testing.expect(instant.epochNanoseconds() <= after);
    try testing.expect(instant.epochSeconds() > 1_700_000_000);
}

test "Temporal.Now keeps the process TZ override when libc is linked" {
    const expected: []const u8 = if (std.c.getenv("TZ")) |tz_ptr| blk: {
        const value = std.mem.span(tz_ptr);
        break :blk if (value.len > 0) value else "UTC";
    } else "UTC";
    try testing.expectEqualStrings(expected, temporal.Now.timeZoneId());
    try testing.expectEqualStrings(expected, temporal.Now.zonedDateTimeISO(null).time_zone);
}
