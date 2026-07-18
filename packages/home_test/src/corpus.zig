//! Bun corpus discovery for Home's native `home test` runner.
//!
//! This is intentionally execution-free: it owns the file classification and
//! counting logic used before the real Bun-compatible JS test runner starts.
//! Passing the corpus still requires the JSC bridge and `home_test` runner
//! activation; this module makes the preflight deterministic and reusable.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const default_root = "packages/runtime/test/bun-corpus";
pub const expected_copied_bun_test_files = 4708;

const local_bun_filtered_files = [_][]const u8{
    "fixtures/copy/kitchen-sink/README.md",
};

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
            .file, .sym_link => {
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

const FileSelection = enum {
    all,
    tests,
};

pub fn collectFiles(io: Io, allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    return collectFilesMatching(io, allocator, path, .all);
}

pub fn collectTestFiles(io: Io, allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    return collectFilesMatching(io, allocator, path, .tests);
}

fn collectFilesMatching(io: Io, allocator: std.mem.Allocator, path: []const u8, selection: FileSelection) ![][]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var files = std.ArrayList([]const u8).empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    try collectOpenDir(io, allocator, &dir, "", selection, &files);
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
    selection: FileSelection,
    files: *std.ArrayList([]const u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {
                if (selection == .tests and !isTestFile(entry.name)) continue;
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
                try collectOpenDir(io, allocator, &child, child_prefix, selection, files);
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
    const have_symlink = builtin.os.tag != .windows and builtin.os.tag != .wasi;
    if (have_symlink) try tmp.dir.symLink(std.testing.io, "a.test.js", "linked.spec.js", .{});

    var files = std.ArrayList([]const u8).empty;
    defer {
        for (files.items) |file| std.testing.allocator.free(file);
        files.deinit(std.testing.allocator);
    }

    try collectOpenDir(std.testing.io, std.testing.allocator, &tmp.dir, "", .tests, &files);
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

    try std.testing.expectEqual(@as(usize, if (have_symlink) 4 else 3), owned.len);
    try std.testing.expectEqualStrings("a.test.js", owned[0]);
    try std.testing.expectEqualStrings("js/node/fs/test-readfile.js", owned[1]);
    if (have_symlink) {
        try std.testing.expectEqualStrings("linked.spec.js", owned[2]);
        try std.testing.expectEqualStrings("z.test.ts", owned[3]);
    } else {
        try std.testing.expectEqualStrings("z.test.ts", owned[2]);
    }
}

test "Bun corpus counter walks nested directories" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "js/node/fs", .{});
    nested.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package-json-lint.test.ts", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "js/node/fs/test-readfile.js", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "js/node/fs/helper.ts", .data = "" });
    const have_symlink = builtin.os.tag != .windows and builtin.os.tag != .wasi;
    if (have_symlink) try tmp.dir.symLink(std.testing.io, "package-json-lint.test.ts", "linked.spec.js", .{});

    var counts = Counts{};
    try countOpenDir(std.testing.io, &tmp.dir, &counts);
    try std.testing.expectEqual(@as(usize, if (have_symlink) 4 else 3), counts.files);
    try std.testing.expectEqual(@as(usize, if (have_symlink) 3 else 2), counts.tests);
}

test "Bun corpus collector sees vendored upstream tests" {
    const counts = try countPath(std.testing.io, default_root);
    try std.testing.expectEqual(@as(usize, expected_copied_bun_test_files), counts.tests);

    const files = try collectTestFiles(std.testing.io, std.testing.allocator, default_root);
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

test "Bun corpus collector includes every upstream test file" {
    const upstream_root = "packages/runtime/upstream/test";
    const upstream_files = collectTestFiles(std.testing.io, std.testing.allocator, upstream_root) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer freeTestFiles(std.testing.allocator, upstream_files);

    const copied_files = try collectTestFiles(std.testing.io, std.testing.allocator, default_root);
    defer freeTestFiles(std.testing.allocator, copied_files);

    try std.testing.expect(copied_files.len >= upstream_files.len);
    for (upstream_files) |upstream_file| {
        var found = false;
        for (copied_files) |copied_file| {
            if (std.mem.eql(u8, upstream_file, copied_file)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("missing upstream Bun test in corpus: {s}\n", .{upstream_file});
            try std.testing.expect(found);
        }
    }
}

test "Bun corpus collector matches local Bun checkout when present" {
    const upstream_root = localBunTestRoot(std.testing.allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(upstream_root);

    const upstream_files = collectTestFiles(std.testing.io, std.testing.allocator, upstream_root) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        error.NotDir => return error.SkipZigTest,
        else => return err,
    };
    defer freeTestFiles(std.testing.allocator, upstream_files);

    const copied_files = try collectTestFiles(std.testing.io, std.testing.allocator, default_root);
    defer freeTestFiles(std.testing.allocator, copied_files);

    if (upstream_files.len != copied_files.len) {
        std.debug.print("local Bun checkout test count={d}, copied Home corpus test count={d}\n", .{ upstream_files.len, copied_files.len });
    }
    try std.testing.expectEqual(upstream_files.len, copied_files.len);

    for (upstream_files, 0..) |upstream_file, index| {
        if (!std.mem.eql(u8, upstream_file, copied_files[index])) {
            std.debug.print(
                "local Bun checkout corpus mismatch at index {d}: upstream={s}, copied={s}\n",
                .{ index, upstream_file, copied_files[index] },
            );
        }
        try std.testing.expectEqualStrings(upstream_file, copied_files[index]);
    }
}

test "Bun corpus mirror includes every local Bun test-tree file when present" {
    const upstream_root = localBunTestRoot(std.testing.allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(upstream_root);

    const upstream_files = collectFiles(std.testing.io, std.testing.allocator, upstream_root) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        error.NotDir => return error.SkipZigTest,
        else => return err,
    };
    defer freeTestFiles(std.testing.allocator, upstream_files);

    const copied_files = try collectFiles(std.testing.io, std.testing.allocator, default_root);
    defer freeTestFiles(std.testing.allocator, copied_files);

    var upstream_set = std.StringHashMap(void).init(std.testing.allocator);
    defer upstream_set.deinit();
    for (upstream_files) |file| try upstream_set.put(file, {});

    var copied_set = std.StringHashMap(void).init(std.testing.allocator);
    defer copied_set.deinit();
    for (copied_files) |file| try copied_set.put(file, {});

    var expected_copied_from_upstream: usize = 0;
    for (upstream_files) |upstream_file| {
        if (isIntentionallyFilteredLocalBunFile(upstream_file)) continue;
        expected_copied_from_upstream += 1;
        if (!copied_set.contains(upstream_file)) {
            std.debug.print("missing local Bun test-tree file in corpus: {s}\n", .{upstream_file});
            try std.testing.expect(false);
        }
    }

    var copied_from_upstream: usize = 0;
    for (copied_files) |copied_file| {
        if (isGeneratedHomeCorpusFile(copied_file)) continue;
        copied_from_upstream += 1;
        if (!upstream_set.contains(copied_file)) {
            std.debug.print("extra non-upstream file in Bun corpus mirror: {s}\n", .{copied_file});
            try std.testing.expect(false);
        }
    }

    try std.testing.expectEqual(expected_copied_from_upstream, copied_from_upstream);
}

fn localBunTestRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("BUN_REPO")) |raw| {
        return std.fs.path.join(allocator, &.{ std.mem.span(raw), "test" });
    }
    const home = std.c.getenv("HOME") orelse return error.SkipZigTest;
    return std.fs.path.join(allocator, &.{ std.mem.span(home), "Code", "bun", "test" });
}

fn isGeneratedHomeCorpusFile(file: []const u8) bool {
    return std.mem.eql(u8, file, "UPSTREAM_SHA.txt") or
        std.mem.eql(u8, file, "FILTERED_FILES.txt");
}

fn isIntentionallyFilteredLocalBunFile(file: []const u8) bool {
    for (local_bun_filtered_files) |filtered| {
        if (std.mem.eql(u8, file, filtered)) return true;
    }
    return false;
}
