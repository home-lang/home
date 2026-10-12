const std = @import("std");
const home_io = @import("io");

test "public fs API round trip and size" {
    const allocator = std.testing.allocator;
    const path = "home_io_public_api_test.txt";
    const contents = "Home std.Io migration";
    const io = std.Io.Threaded.global_single_threaded.io();

    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try home_io.fs.writeFile(allocator, path, contents);

    try std.testing.expect(home_io.fs.exists(path));
    try std.testing.expectEqual(contents.len, try home_io.fs.getSize(path));

    const actual = try home_io.fs.readFile(allocator, path);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(contents, actual);
}

test "configured async runtime performs file IO" {
    const allocator = std.testing.allocator;
    const path = "home_io_async_runtime_test.txt";
    const contents = "bounded worker pool";

    var runtime = home_io.AsyncRuntime.initWithThreads(allocator, 1);
    defer runtime.deinit();
    defer std.Io.Dir.cwd().deleteFile(runtime.io(), path) catch {};

    try runtime.writeFile(path, contents);
    try std.testing.expect(runtime.fileExists(path));

    const actual = try runtime.readFile(path);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(contents, actual);
}
