const std = @import("std");

const print_diff = @import("bun/diff/printDiff.zig");

fn renderPrintDiff(not: bool, received: []const u8, expected: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var writer_state: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer_state.deinit();

    try print_diff.printDiffMain(
        arena,
        not,
        received,
        expected,
        &writer_state.writer,
        print_diff.DiffConfig.default(false, false),
    );
    return std.testing.allocator.dupe(u8, writer_state.written());
}

test "copied Bun printDiff renders single-line mismatch" {
    const output = try renderPrintDiff(false, "hallo", "hello");
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Expected: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Received: hallo") != null);
}

test "copied Bun printDiff renders multiline mismatch" {
    const output = try renderPrintDiff(false, "alpha\nbravo\ncharlie\n", "alpha\nbeta\ncharlie\n");
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Expected") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Received") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "bravo") != null);
}

test "copied Bun printDiff renders negated expectation" {
    const output = try renderPrintDiff(true, "ignored", "same");
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("Expected: not same", output);
}
