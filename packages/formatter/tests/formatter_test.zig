const std = @import("std");
const testing = std.testing;

// Formatter requires a full AST Program to work, so we test the
// formatter options struct which doesn't require complex setup

const Formatter = @import("formatter").Formatter;

test "formatter: options defaults" {
    const options = Formatter.FormatterOptions{};

    try testing.expectEqual(@as(usize, 4), options.indent_size);
    try testing.expectEqual(true, options.use_spaces);
    try testing.expectEqual(@as(usize, 100), options.max_line_length);
}

test "formatter: custom options" {
    const options = Formatter.FormatterOptions{
        .indent_size = 2,
        .use_spaces = false,
        .max_line_length = 80,
    };

    try testing.expectEqual(@as(usize, 2), options.indent_size);
    try testing.expectEqual(false, options.use_spaces);
    try testing.expectEqual(@as(usize, 80), options.max_line_length);
}
