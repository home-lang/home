//! Bounded POSIX directory enumeration using Home's shared glob matcher.
const std = @import("std");
const matcher = @import("tool_glob_matcher");
const io = std.Io.Threaded.global_single_threaded.io();
pub const Options = struct { dot: bool = false, absolute: bool = false, only_files: bool = true };

fn parts(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(allocator);
    var split = std.mem.splitScalar(u8, text, '/');
    while (split.next()) |part| try result.append(allocator, part);
    return result.toOwnedSlice(allocator);
}

fn matchParts(pattern: []const []const u8, path: []const []const u8, dot: bool, prefix: bool, budget: *usize) anyerror!bool {
    if (budget.* == 0) return error.GlobLimit;
    budget.* -= 1;
    if (path.len == 0) {
        if (prefix) return true;
        for (pattern) |part| if (!std.mem.eql(u8, part, "**")) return false;
        return true;
    }
    if (pattern.len == 0) return false;
    const hidden = std.mem.startsWith(u8, path[0], ".");
    if (std.mem.eql(u8, pattern[0], "**")) {
        if (try matchParts(pattern[1..], path, dot, prefix, budget)) return true;
        return (dot or !hidden) and try matchParts(pattern, path[1..], dot, prefix, budget);
    }
    // Explicit dot components work without enabling wildcard dot matching.
    // Leading-dot brace alternatives are refused at scan validation until
    // they have the same per-alternative dot policy as the full Bun walker.
    if (!dot and hidden and !std.mem.startsWith(u8, pattern[0], ".") and
        !std.mem.startsWith(u8, pattern[0], "\\.")) return false;
    return matcher.match(pattern[0], path[0]).matches() and try matchParts(pattern[1..], path[1..], dot, prefix, budget);
}

pub fn validate(pattern: []const u8) !void {
    if (pattern.len > 4096 or std.mem.startsWith(u8, pattern, "/") or std.mem.startsWith(u8, pattern, "!")) return error.Unsupported;
    var braces: usize = 0;
    var escaped = false;
    for (pattern) |byte| {
        if (byte == 0) return error.Unsupported;
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '{') braces += 1;
        if (byte == '}' and braces > 0) braces -= 1;
        if (byte == '/' and braces > 0) return error.Unsupported;
    }
    var split = std.mem.splitScalar(u8, pattern, '/');
    var count: usize = 0;
    while (split.next()) |part| {
        count += 1;
        if (count > 128 or std.mem.eql(u8, part, "..")) return error.Unsupported;
        if (std.mem.startsWith(u8, part, "{") and (std.mem.find(u8, part, "{.") != null or std.mem.find(u8, part, ",.") != null)) return error.Unsupported;
    }
}

const Walker = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    pattern: []const []const u8,
    options: Options,
    leading_dot_slash: bool,
    entries: usize = 0,
    output: std.ArrayList([]const u8) = .empty,

    fn walk(self: *Walker, relative: []const u8, depth: usize) anyerror!void {
        if (depth > 128) return error.GlobLimit;
        const absolute = try std.fs.path.join(self.allocator, &.{ self.root, relative });
        defer self.allocator.free(absolute);
        var directory = try std.Io.Dir.cwd().openDir(io, absolute, .{ .iterate = true });
        defer directory.close(io);
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            if (!std.unicode.utf8ValidateSlice(entry.name)) return error.Unsupported;
            self.entries += 1;
            if (self.entries > 100_000) return error.GlobLimit;
            const path = try std.fs.path.join(self.allocator, &.{ relative, entry.name });
            defer self.allocator.free(path);
            const path_parts = try parts(self.allocator, path);
            defer self.allocator.free(path_parts);
            var budget: usize = 100_000;
            const matches = try matchParts(self.pattern, path_parts, self.options.dot, false, &budget);
            // Do not follow symbolic links. Default onlyFiles excludes them;
            // onlyFiles:false yields their own names, including broken links.
            var kind = entry.kind;
            if (kind == .unknown) {
                const full_path = try std.fs.path.join(self.allocator, &.{ self.root, path });
                defer self.allocator.free(full_path);
                kind = (try std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = false })).kind;
            }
            if (matches and (!self.options.only_files or kind == .file)) {
                const output = if (self.options.absolute)
                    try std.fs.path.join(self.allocator, &.{ self.root, path })
                else if (self.leading_dot_slash)
                    try std.mem.concat(self.allocator, u8, &.{ "./", path })
                else
                    try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(output);
                try self.output.append(self.allocator, output);
            }
            budget = 100_000;
            if (kind == .directory and try matchParts(self.pattern, path_parts, self.options.dot, true, &budget))
                try self.walk(path, depth + 1);
        }
    }
};

pub fn scan(allocator: std.mem.Allocator, cwd: []const u8, pattern: []const u8, options: Options) ![][]const u8 {
    try validate(pattern);
    const current = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(current);
    const root = try std.fs.path.resolve(allocator, &.{ current, cwd });
    defer allocator.free(root);
    const leading = std.mem.startsWith(u8, pattern, "./");
    var normalized = pattern;
    while (std.mem.startsWith(u8, normalized, "./")) normalized = normalized[2..];
    const pattern_parts = try parts(allocator, normalized);
    defer allocator.free(pattern_parts);
    var walker: Walker = .{ .allocator = allocator, .root = root, .pattern = pattern_parts, .options = options, .leading_dot_slash = leading };
    errdefer {
        for (walker.output.items) |path| allocator.free(path);
        walker.output.deinit(allocator);
    }
    try walker.walk("", 0);
    return walker.output.toOwnedSlice(allocator);
}

test "glob scans actual files and observes subsequent filesystem changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "first.ts", .data = "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/second.ts", .data = "second" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first = try scan(arena.allocator(), root, "**/*.ts", .{});
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try tmp.dir.writeFile(io, .{ .sub_path = "third.ts", .data = "third" });
    const next = try scan(arena.allocator(), root, "**/*.ts", .{});
    try std.testing.expectEqual(@as(usize, 3), next.len);
    try std.testing.expectError(error.FileNotFound, scan(arena.allocator(), "/__home_missing_glob_directory__", "**", .{}));
}
