const std = @import("std");

const diff_format = @import("bun/diff_format.zig");

fn render(formatter: diff_format.DiffFormatter) ![]u8 {
    var writer_state: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer_state.deinit();

    try formatter.format(&writer_state.writer);
    return std.testing.allocator.dupe(u8, writer_state.written());
}

test "copied Bun DiffFormatter renders string mismatch through printDiff" {
    const output = try render(.{
        .globalThis = undefined,
        .received_string = "hallo",
        .expected_string = "hello",
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Expected: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Received: hallo") != null);
}

test "copied Bun DiffFormatter renders negated string mismatch" {
    const output = try render(.{
        .globalThis = undefined,
        .received_string = "same",
        .expected_string = "same",
        .not = true,
    });
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("Expected: not same", output);
}

test "copied Bun DiffFormatter ignores missing value pairs" {
    const output = try render(.{ .globalThis = undefined });
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("", output);
}
