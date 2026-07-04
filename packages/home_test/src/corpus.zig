//! Bun corpus discovery for Home's native `home test` runner.
//!
//! This is intentionally execution-free: it owns the file classification and
//! counting logic used before the real Bun-compatible JS test runner starts.
//! Passing the corpus still requires the JSC bridge and `home_test` runner
//! activation; this module makes the preflight deterministic and reusable.

const std = @import("std");
const Io = std.Io;

pub const Counts = struct {
    files: usize = 0,
    tests: usize = 0,
};

pub fn isTestFile(name: []const u8) bool {
    const test_exts = [_][]const u8{
        ".test.ts",
        ".test.tsx",
        ".test.js",
        ".test.jsx",
        ".test.mjs",
        ".test.cjs",
        ".spec.ts",
        ".spec.tsx",
        ".spec.js",
        ".spec.jsx",
        ".spec.mjs",
        ".spec.cjs",
    };

    for (test_exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }

    return (std.mem.startsWith(u8, name, "test-") or std.mem.startsWith(u8, name, "node-test-")) and
        (std.mem.endsWith(u8, name, ".js") or
            std.mem.endsWith(u8, name, ".mjs") or
            std.mem.endsWith(u8, name, ".cjs"));
}

pub fn countPath(io: Io, path: []const u8) !Counts {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var counts = Counts{};
    try countOpenDir(io, &dir, &counts);
    return counts;
}

pub fn countOpenDir(io: Io, dir: *Io.Dir, counts: *Counts) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                counts.files += 1;
                if (isTestFile(entry.name)) counts.tests += 1;
            },
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                try countOpenDir(io, &child, counts);
            },
            else => {},
        }
    }
}

pub fn collectTestFiles(io: Io, allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var files = std.ArrayList([]const u8).empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    try collectOpenDir(io, allocator, &dir, "", &files);
    const owned = try files.toOwnedSlice(allocator);
    std.mem.sort([]const u8, owned, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return owned;
}

pub fn freeTestFiles(allocator: std.mem.Allocator, files: []const []const u8) void {
    for (files) |file| allocator.free(file);
    allocator.free(files);
}

fn collectOpenDir(
    io: Io,
    allocator: std.mem.Allocator,
    dir: *Io.Dir,
    prefix: []const u8,
    files: *std.ArrayList([]const u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (!isTestFile(entry.name)) continue;
                const relative = if (prefix.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ prefix, entry.name });
                try files.append(allocator, relative);
            },
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                const child_prefix = if (prefix.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ prefix, entry.name });
                defer allocator.free(child_prefix);
                try collectOpenDir(io, allocator, &child, child_prefix, files);
            },
            else => {},
        }
    }
}

test "Bun corpus test-file classifier matches Bun-style names" {
    try std.testing.expect(isTestFile("math.test.ts"));
    try std.testing.expect(isTestFile("math.test.tsx"));
    try std.testing.expect(isTestFile("math.test.js"));
    try std.testing.expect(isTestFile("math.test.mjs"));
    try std.testing.expect(isTestFile("math.spec.ts"));
    try std.testing.expect(isTestFile("math.spec.js"));
    try std.testing.expect(isTestFile("test-fs.js"));
    try std.testing.expect(isTestFile("node-test-runner.mjs"));
    try std.testing.expect(!isTestFile("helper.ts"));
    try std.testing.expect(!isTestFile("snapshot.test.txt"));
}

test "Bun corpus collector returns sorted relative test paths" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "js/node/fs", .{});
    nested.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "z.test.ts", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.test.js", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "js/node/fs/test-readfile.js", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "js/node/fs/helper.ts", .data = "" });

    var files = std.ArrayList([]const u8).empty;
    defer {
        for (files.items) |file| std.testing.allocator.free(file);
        files.deinit(std.testing.allocator);
    }

    try collectOpenDir(std.testing.io, std.testing.allocator, &tmp.dir, "", &files);
    const owned = try files.toOwnedSlice(std.testing.allocator);
    defer {
        for (owned) |file| std.testing.allocator.free(file);
        std.testing.allocator.free(owned);
    }
    files = .empty;

    std.mem.sort([]const u8, owned, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    try std.testing.expectEqual(@as(usize, 3), owned.len);
    try std.testing.expectEqualStrings("a.test.js", owned[0]);
    try std.testing.expectEqualStrings("js/node/fs/test-readfile.js", owned[1]);
    try std.testing.expectEqualStrings("z.test.ts", owned[2]);
}

test "Bun corpus counter walks nested directories" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "js/node/fs", .{});
    nested.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package-json-lint.test.ts", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "js/node/fs/test-readfile.js", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "js/node/fs/helper.ts", .data = "" });

    var counts = Counts{};
    try countOpenDir(std.testing.io, &tmp.dir, &counts);
    try std.testing.expectEqual(@as(usize, 3), counts.files);
    try std.testing.expectEqual(@as(usize, 2), counts.tests);
}

test "Bun corpus collector sees vendored upstream tests" {
    const root = "packages/runtime/test/bun-corpus";
    const counts = try countPath(std.testing.io, root);
    try std.testing.expectEqual(@as(usize, 4019), counts.tests);

    const files = try collectTestFiles(std.testing.io, std.testing.allocator, root);
    defer freeTestFiles(std.testing.allocator, files);

    try std.testing.expectEqual(counts.tests, files.len);
    var found_cp = false;
    var found_spec = false;
    for (files) |file| {
        if (std.mem.eql(u8, file, "js/bun/shell/commands/cp.test.ts")) {
            found_cp = true;
        } else if (std.mem.eql(u8, file, "js/node/assert/assert.spec.ts")) {
            found_spec = true;
        }
    }
    try std.testing.expect(found_cp);
    try std.testing.expect(found_spec);
}
