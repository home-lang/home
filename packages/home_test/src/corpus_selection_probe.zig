//! Native selection audit CLI. Inputs and outputs describe file selection only;
//! this program does not execute or claim passing corpus tests.
const std = @import("std");
const selection = @import("corpus_selection.zig");

pub const Input = struct {
    files: []const []const u8,
    upstream_expectations: []const u8,
    home_expectations: ?[]const u8 = null,
    runs: []const struct { context: selection.Context, options: selection.Options = .{} },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.ExpectedInputAndOutputPaths;
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(64 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(Input, allocator, source, .{});
    const upstream = try selection.parseExpectations(allocator, parsed.value.upstream_expectations);
    const home = try selection.parseExpectations(allocator, parsed.value.home_expectations orelse parsed.value.upstream_expectations);
    const Output = struct { selected: []usize, excluded: []selection.Excluded, modifiers: [][]const u8, additional_home_coverage: []usize };
    var outputs: std.ArrayList(Output) = .empty;
    for (parsed.value.runs) |run| {
        const modifiers = try run.context.modifiers(allocator);
        try selection.validateHomeExpectations(parsed.value.files, upstream, home, modifiers);
        const result = try selection.select(allocator, parsed.value.files, run.context, home, run.options);
        var extra: std.ArrayList(usize) = .empty;
        for (result.selected) |index| if (selection.matchingRule(parsed.value.files[index], upstream, modifiers) != null) try extra.append(allocator, index);
        try outputs.append(allocator, .{ .selected = result.selected, .excluded = result.excluded, .modifiers = modifiers, .additional_home_coverage = try extra.toOwnedSlice(allocator) });
    }
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .kind = "selection-only", .runs = outputs.items }, .{});
    const file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .exclusive = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, json);
    try file.writeStreamingAll(init.io, "\n");
    try file.sync(init.io);
}
