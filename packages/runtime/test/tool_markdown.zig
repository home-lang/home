const std = @import("std");
const md = @import("tool_markdown_parser");

test "owned Markdown renderer produces real HTML" {
    const html = try md.renderToHtmlWithOptions("# Actual\n\n**strong**\n", std.testing.allocator, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<h1>Actual</h1>\n<p><strong>strong</strong></p>\n", html);
}

test "owned Markdown renderer releases heading tracking storage" {
    const html = try md.renderToHtmlWithOptions("# Same\n\n# Same\n", std.testing.allocator, .{ .heading_ids = true, .autolink_headings = true });
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<h1 id=\"same\"><a href=\"#same\">Same</a></h1>\n<h1 id=\"same-1\"><a href=\"#same-1\">Same</a></h1>\n", html);
}

test "owned Markdown renderer propagates native allocation failure" {
    var storage: [1]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, md.renderToHtmlWithOptions("# Actual allocation\n", allocator.allocator(), .{}));
}
