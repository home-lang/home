//! Native host probe audit; observations are not passing corpus test cases.
const std = @import("std");
const platform = @import("corpus_platform.zig");
const Case = struct { os: []const u8, arch: []const u8, observations: platform.Observations = .{}, expected: platform.Expected = .{} };
const Input = struct { cases: []const Case };
const Result = struct { host: platform.Host, mismatches: []const platform.Mismatch, successful: bool };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.ExpectedInputAndOutputPaths;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(4 * 1024 * 1024));
    const input = try std.json.parseFromSlice(Input, allocator, bytes, .{});
    var outputs: std.ArrayList(Result) = .empty;
    for (input.value.cases) |case| {
        const host = try platform.detectWith(case.observations, allocator, case.os, case.arch);
        const checked = platform.check(host, case.expected);
        try outputs.append(allocator, .{ .host = host, .mismatches = try allocator.dupe(platform.Mismatch, checked.items()), .successful = checked.len == 0 });
    }
    var live = try platform.detect(allocator, init.io);
    defer live.deinit();
    const expected = platform.Expected.fromEnvironment(init.environ_map);
    const checked = platform.check(live.host, expected);
    const output = try std.json.Stringify.valueAlloc(allocator, .{ .kind = "native-platform-observations", .cases = outputs.items, .live = .{ .host = live.host, .expected = expected, .mismatches = checked.items(), .is_ci = platform.isCI(init.environ_map) } }, .{});
    const file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .exclusive = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, output);
    try file.writeStreamingAll(init.io, "\n");
    try file.sync(init.io);
}
