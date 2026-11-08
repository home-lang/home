//! Select logical root identities before any filesystem read. The host's
//! fixed filename policy determines aliases, not existence or real paths.
const std = @import("std");
const FileNameContext = @import("filename_case.zig").Context;

pub const Input = struct {
    authored_name: []const u8,
    file_name: []const u8,
    root_index: usize,
};

pub const Root = struct {
    /// Authored argument for display and provenance, not filesystem reads.
    authored_name: []const u8,
    /// Normalized latest spelling for both reads and Program identity.
    file_name: []const u8,
    selected_input_index: usize,
    /// Every authored origin, including exact repeats, in admission order.
    input_indices: []const usize,
};

pub const Selection = struct {
    arena: std.heap.ArenaAllocator,
    inputs: []const Input,
    roots: []const Root,
    file_names: []const []const u8,

    pub fn deinit(self: *Selection) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn normalizeSlashes(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    const result = try allocator.dupe(u8, path);
    for (result) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    return result;
}

/// Normalize against an absolute working directory without resolving symlinks.
/// Keep first-identity order and the latest authored spelling within each
/// identity. The result owns its strings and origin lists; inputs are never
/// mutated, including when allocation fails.
pub fn select(
    gpa: std.mem.Allocator,
    context: FileNameContext,
    cwd: []const u8,
    file_names: []const []const u8,
) (std.mem.Allocator.Error || error{InvalidWorkingDirectory})!Selection {
    if (!std.fs.path.isAbsolute(cwd)) return error.InvalidWorkingDirectory;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const working_directory = try normalizeSlashes(allocator, cwd);
    const Group = struct {
        latest: usize,
        indices: std.ArrayListUnmanaged(usize) = .empty,
    };
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    var by_name: std.HashMapUnmanaged([]const u8, usize, FileNameContext, 80) = .empty;
    const inputs = try allocator.alloc(Input, file_names.len);
    for (file_names, 0..) |name, index| {
        const normalized = try std.fs.path.resolve(allocator, &.{ working_directory, try normalizeSlashes(allocator, name) });
        // Native Windows resolution emits backslashes; compiler paths use '/'.
        for (normalized) |*byte| if (byte.* == '\\') {
            byte.* = '/';
        };
        const entry = try by_name.getOrPutContext(allocator, normalized, context);
        if (!entry.found_existing) {
            entry.value_ptr.* = groups.items.len;
            try groups.append(allocator, .{ .latest = index });
        }
        const root_index = entry.value_ptr.*;
        groups.items[root_index].latest = index;
        try groups.items[root_index].indices.append(allocator, index);
        inputs[index] = .{ .authored_name = try allocator.dupe(u8, name), .file_name = normalized, .root_index = root_index };
    }
    const roots = try allocator.alloc(Root, groups.items.len);
    const file_names_selected = try allocator.alloc([]const u8, groups.items.len);
    for (groups.items, roots, file_names_selected) |group, *root, *selected_name| {
        root.* = .{
            .authored_name = inputs[group.latest].authored_name,
            .file_name = inputs[group.latest].file_name,
            .selected_input_index = group.latest,
            .input_indices = group.indices.items,
        };
        selected_name.* = root.file_name;
    }
    return .{ .arena = arena, .inputs = inputs, .roots = roots, .file_names = file_names_selected };
}

test "root selection normalizes names, selects latest spelling and retains every origin" {
    var selection = try select(std.testing.allocator, .{ .case_sensitive = false }, "/repo", &.{
        "src/First.ts", "middle.ts", "./src/first.ts", "src/../src/FIRST.ts", "./middle.ts",
    });
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 2), selection.roots.len);
    try std.testing.expectEqualStrings("/repo/src/FIRST.ts", selection.file_names[0]);
    try std.testing.expectEqualStrings("/repo/src/FIRST.ts", selection.roots[0].file_name);
    try std.testing.expectEqualStrings("src/../src/FIRST.ts", selection.roots[0].authored_name);
    try std.testing.expectEqualStrings("src/First.ts", selection.inputs[0].authored_name);
    try std.testing.expectEqualStrings("/repo/middle.ts", selection.roots[1].file_name);
    try std.testing.expectEqual(@as(usize, 3), selection.roots[0].selected_input_index);
    try std.testing.expectEqual(@as(usize, 4), selection.roots[1].selected_input_index);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3 }, selection.roots[0].input_indices);
    try std.testing.expectEqualSlices(usize, &.{ 1, 4 }, selection.roots[1].input_indices);
    try std.testing.expectEqualStrings("/repo/src/First.ts", selection.inputs[0].file_name);
    try std.testing.expectEqualStrings("/repo/src/first.ts", selection.inputs[2].file_name);
    try std.testing.expectEqual(@as(usize, 0), selection.inputs[3].root_index);
    try std.testing.expectEqual(@as(usize, 1), selection.inputs[4].root_index);
}

test "root selection follows both Unicode host policies without merging distinct controls" {
    const names: []const []const u8 = &.{ "ΟΣ.ts", "οσ.ts", "K.ts", "k.ts", "𐐀.ts", "𐐨.ts", "İ.ts", "i.ts", "i̇.ts", "ß.ts", "ss.ts" };
    for ([_]bool{ true, false }) |sensitive| {
        var selection = try select(std.testing.allocator, .{ .case_sensitive = sensitive }, "/missing-project", names);
        defer selection.deinit();
        try std.testing.expectEqual(@as(usize, if (sensitive) 11 else 8), selection.roots.len);
        const selected: []const usize = if (sensitive) &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } else &.{ 1, 3, 5, 6, 7, 8, 9, 10 };
        for (selection.roots, selected) |root, index| {
            try std.testing.expectEqual(index, root.selected_input_index);
            try std.testing.expect(std.mem.endsWith(u8, root.file_name, names[index]));
        }
    }
}

test "root selection cleans up every allocation failure without changing authored inputs" {
    const Lifecycle = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const names: []const []const u8 = &.{ "./missing/First.ts", "missing\\first.ts", "/elsewhere.ts", "missing/../missing/FIRST.ts" };
            var selection = try select(allocator, .{ .case_sensitive = false }, "/repo", names);
            defer selection.deinit();
            try std.testing.expectEqual(@as(usize, 2), selection.roots.len);
            try std.testing.expectEqualStrings("/repo/missing/FIRST.ts", selection.roots[0].file_name);
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, selection.roots[0].input_indices);
            try std.testing.expectEqualStrings("./missing/First.ts", names[0]);
            try std.testing.expectEqualStrings("missing\\first.ts", names[1]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Lifecycle.run, .{});
}

test "root selection normalizes mixed separators before logical identity" {
    for ([_]bool{ true, false }) |sensitive| {
        var selection = try select(std.testing.allocator, .{ .case_sensitive = sensitive }, "/repo", &.{
            "src\\First.ts", "./src/First.ts", "src\\..\\src/First.ts",
        });
        defer selection.deinit();
        try std.testing.expectEqual(@as(usize, 1), selection.roots.len);
        try std.testing.expectEqualStrings("/repo/src/First.ts", selection.roots[0].file_name);
        try std.testing.expectEqualStrings("src\\..\\src/First.ts", selection.roots[0].authored_name);
        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, selection.roots[0].input_indices);
    }
}

test "root selection rejects an unanchored working directory and accepts no inputs" {
    try std.testing.expectError(error.InvalidWorkingDirectory, select(std.testing.allocator, .{ .case_sensitive = true }, "relative", &.{"entry.ts"}));
    var selection = try select(std.testing.allocator, .{ .case_sensitive = true }, "/repo", &.{});
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 0), selection.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), selection.roots.len);
}
