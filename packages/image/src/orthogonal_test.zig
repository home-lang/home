const std = @import("std");
test {
    std.testing.refAllDecls(@import("ops/transform.zig"));
}
