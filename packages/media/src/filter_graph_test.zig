const std = @import("std");
const filter_graph = @import("pipeline/filter_graph.zig");
const stream = @import("core/stream.zig");
const error_types = @import("core/error.zig");

const FilterGraph = filter_graph.FilterGraph;
const Frame = stream.Frame;
const MediaError = error_types.MediaError;

test "FilterGraph scale and crop preserve frame ownership" {
    const allocator = std.testing.allocator;
    var graph = FilterGraph.init(allocator);
    defer graph.deinit();

    try graph.addVideoFilter(.{ .scale = .{ .width = 4, .height = 4 } });
    try graph.addVideoFilter(.{ .crop = .{ .x = 1, .y = 1, .width = 2, .height = 2 } });
    try graph.configure(.rgba, null);

    var frame = try Frame.initVideo(allocator, 2, 2, .rgba);
    defer frame.deinit();
    @memset(frame.data[0], 17);

    const output = try graph.processVideoFrame(&frame);
    try std.testing.expect(output == &frame);
    try std.testing.expectEqual(@as(u32, 2), frame.width);
    try std.testing.expectEqual(@as(u32, 2), frame.height);
    try std.testing.expectEqual(@as(u8, 17), frame.data[0][0]);
}

test "FilterGraph rejects invalid crop without replacing the frame" {
    const allocator = std.testing.allocator;
    var graph = FilterGraph.init(allocator);
    defer graph.deinit();

    try graph.addVideoFilter(.{ .crop = .{ .x = 1, .y = 1, .width = 2, .height = 2 } });
    try graph.configure(.rgba, null);

    var frame = try Frame.initVideo(allocator, 2, 2, .rgba);
    defer frame.deinit();
    const original_data = frame.data[0].ptr;

    try std.testing.expectError(MediaError.InvalidArgument, graph.processVideoFrame(&frame));
    try std.testing.expectEqual(original_data, frame.data[0].ptr);
    try std.testing.expectEqual(@as(u32, 2), frame.width);
    try std.testing.expectEqual(@as(u32, 2), frame.height);
}
