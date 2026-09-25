const std = @import("std");
const runtime = @import("home_rt_no_jsc.zig");

test "native-only runtime startup hooks are available" {
    runtime.Output.configure();
    runtime.StackCheck.configureThread();
}

test "native-only runtime duplicates sentinel-terminated arguments" {
    const value = try runtime.dupeZ(std.testing.allocator, u8, "home");
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualStrings("home", value);
    try std.testing.expectEqual(@as(u8, 0), value[value.len]);
}
