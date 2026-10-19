const std = @import("std");
const image = @import("image");

test "image async result waits for a published value" {
    const Result = image.Utils.AsyncResult(u32);
    var result: Result = .{};
    const producer = try std.Thread.spawn(.{}, struct {
        fn publish(out: *Result) void {
            out.result = 42;
            out.completed.store(true, .release);
        }
    }.publish, .{&result});
    defer producer.join();

    try std.testing.expectEqual(@as(u32, 42), try result.wait(std.testing.io));
    try std.testing.expect(result.isCompleted());
}

test "image async result preserves the producer error" {
    const Result = image.Utils.AsyncResult(u32);
    var result: Result = .{
        .err = error.ImageDecodeFailed,
        .completed = std.atomic.Value(bool).init(true),
    };

    try std.testing.expectError(error.ImageDecodeFailed, result.wait(std.testing.io));
}
