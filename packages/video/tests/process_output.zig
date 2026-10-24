const std = @import("std");
const video = @import("video");
test "public bounded diagnostics retain the exact raw suffix and discarded count" {
    var arena: [4]u8 = undefined;
    var tail = video.ByteTail.init(&arena);
    try tail.append("012345");
    var copy: [4]u8 = undefined;
    try std.testing.expectEqualStrings("2345", try tail.copy(&copy));
    try std.testing.expectEqual(@as(u64, 6), tail.total);
}
test "public process framing rejects unknown records and preserves exit status" {
    const message = video.process_output_wire.Message{ .kind = .result, .status = 42, .supervisor = 123, .consumer = 456 };
    const bytes = try video.process_output_wire.encode(message);
    try std.testing.expectEqualDeep(message, try video.process_output_wire.decode(&bytes));
}
