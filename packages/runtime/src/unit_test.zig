test {
    _ = @import("./shell_parser/braces.zig");
    _ = @import("./runtime/node/assert/myers_diff.zig");
}

test "basic string usage" {
    var s = home_rt.String.cloneUTF8("hi");
    defer s.deref();
    try t.expect(s.tag != .Dead and s.tag != .Empty);
    try t.expectEqual(s.length(), 2);
    try t.expectEqualStrings(s.asUTF8().?, "hi");
}

test "generated Node error discriminants match the linked C++ ABI" {
    const Error = home_rt.jsc.Error;
    try t.expectEqual(@as(u16, 121), @intFromEnum(Error.INVALID_ARG_VALUE_RangeError));
    try t.expectEqual(@as(u16, 159), @intFromEnum(Error.OPERATION_FAILED));
    try t.expectEqual(@as(u16, 233), @intFromEnum(Error.STREAM_ITER_MISSING_FLAG));
    try t.expectEqual(@as(u16, 327), @intFromEnum(Error.DIR_CONCURRENT_OPERATION));
}

const home_rt = @import("home");

const std = @import("std");
const t = std.testing;
