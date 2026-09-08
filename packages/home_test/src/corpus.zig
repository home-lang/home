//! Bun corpus discovery for Home's native `home test` runner.
//!
//! This is intentionally execution-free: it owns the file classification and
//! counting logic used before the real Bun-compatible JS test runner starts.
//! Passing the corpus still requires the JSC bridge and `home_test` runner
//! activation; this module makes the preflight deterministic and reusable.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const default_root = "packages/runtime/test/test";
pub const expected_copied_bun_test_tree_entries = 12996;
pub const expected_copied_bun_test_files = 4754;
pub const tracked_manifest_name = "BUN_TRACKED_FILES.txt";

pub const Counts = struct {
    files: usize = 0,
    tests: usize = 0,
};

/// Pinned upstream CI discovery before expectation/platform exclusions.
/// Paths are relative to the corpus root; helper filenames alone do not make
/// a Node test. Preserve the parent directory when classifying a nested shard.
pub fn isTestFile(path: []const u8) bool {
    if (!isJavaScriptFile(path) or isHiddenCorpusPath(path)) return false;
    if (isNodeTestFile(path)) return true;
    if (corpusPathIndexOf(path, "js/node/cluster/test-") != null and std.mem.endsWith(u8, path, ".ts")) return true;
    return isTestStrictFile(path);
}

pub fn isTestStrictFile(path: []const u8) bool {
    if (!isJavaScriptFile(path)) return false;
    const name = std.fs.path.basename(path);
    return std.mem.indexOf(u8, name, ".test") != null or std.mem.indexOf(u8, name, "spec.") != null;
}

pub fn isJavaScriptFile(path: []const u8) bool {
    inline for (.{ ".js", ".jsx", ".ts", ".tsx", ".cjs", ".cjsx", ".cts", ".ctsx", ".mjs", ".mjsx", ".mts", ".mtsx" }) |extension| {
        if (std.mem.endsWith(u8, path, extension)) return true;
    }
    return false;
}

pub fn isNodeTestFile(path: []const u8) bool {
    return isJavaScriptFile(path) and
        (corpusPathIndexOf(path, "js/node/test/parallel/") != null or
            corpusPathIndexOf(path, "js/node/test/sequential/") != null or
            corpusPathIndexOf(path, "js/bun/test/parallel/") != null);
}

fn isHiddenCorpusPath(path: []const u8) bool {
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (component.len > 0 and component[0] == '.') return true;
    }
    const parent = path[0..(std.mem.lastIndexOfAny(u8, path, "/\\") orelse return false)];
    if (std.mem.indexOf(u8, parent, "node_modules") != null) return true;
    // Match the pinned runner's /node.js/ expression, including its wildcard.
    if (parent.len >= 7) {
        for (0..parent.len - 6) |i| {
            if (std.mem.eql(u8, parent[i .. i + 4], "node") and parent[i + 4] != '\n' and std.mem.eql(u8, parent[i + 5 .. i + 7], "js")) return true;
        }
    }
    return false;
}

fn corpusPathIndexOf(path: []const u8, fragment: []const u8) ?usize {
    if (path.len < fragment.len) return null;
    for (0..path.len - fragment.len + 1) |offset| {
        for (fragment, path[offset .. offset + fragment.len]) |expected, actual| {
            if (expected == '/' and (actual == '/' or actual == '\\')) continue;
            if (expected != actual) break;
        } else return offset;
    }
    return null;
}

fn discoveryPrefix(path: []const u8) []const u8 {
    if (corpusPathIndexOf(path, default_root)) |start| {
        return std.mem.trim(u8, path[start + default_root.len ..], "/\\");
    }
    return "";
}

pub fn countPath(io: Io, path: []const u8) !Counts {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var counts = Counts{};
    try countOpenDirRelative(io, &dir, discoveryPrefix(path), &counts);
    return counts;
}

pub fn countOpenDir(io: Io, dir: *Io.Dir, counts: *Counts) !void {
    return countOpenDirRelative(io, dir, "", counts);
}

fn countOpenDirRelative(io: Io, dir: *Io.Dir, prefix: []const u8, counts: *Counts) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const relative = try std.fs.path.join(std.heap.page_allocator, &.{ prefix, entry.name });
        defer std.heap.page_allocator.free(relative);
        switch (entry.kind) {
            .file, .sym_link => {
                counts.files += 1;
                if (entry.kind == .file and isTestFile(relative)) counts.tests += 1;
            },
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                try countOpenDirRelative(io, &child, relative, counts);
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

pub fn countTrackedCorpus(io: Io, allocator: std.mem.Allocator, corpus_root: []const u8) !Counts {
    const files = try collectTrackedFilesMatching(io, allocator, corpus_root, "", .all);
    defer freeTestFiles(allocator, files);

    var counts = Counts{ .files = files.len };
    for (files) |file| {
        if (isTestFile(file)) counts.tests += 1;
    }
    return counts;
}

pub fn collectTrackedTestFiles(
    io: Io,
    allocator: std.mem.Allocator,
    corpus_root: []const u8,
) ![][]const u8 {
    return collectTrackedFilesMatching(io, allocator, corpus_root, "", .tests);
}

pub fn collectTrackedDirectoryTestFiles(
    io: Io,
    allocator: std.mem.Allocator,
    corpus_root: []const u8,
    relative_directory: []const u8,
) ![][]const u8 {
    return collectTrackedFilesMatching(io, allocator, corpus_root, relative_directory, .tests);
}

fn collectTrackedFilesMatching(
    io: Io,
    allocator: std.mem.Allocator,
    corpus_root: []const u8,
    relative_directory: []const u8,
    selection: FileSelection,
) ![][]const u8 {
    const manifest_path = try std.fs.path.join(allocator, &.{ corpus_root, tracked_manifest_name });
    defer allocator.free(manifest_path);
    const manifest = try Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        allocator,
        std.Io.Limit.limited(2 * 1024 * 1024),
    );
    defer allocator.free(manifest);

    return collectTrackedFilesFromManifest(allocator, manifest, relative_directory, selection);
}

fn collectTrackedFilesFromManifest(
    allocator: std.mem.Allocator,
    manifest: []const u8,
    relative_directory: []const u8,
    selection: FileSelection,
) ![][]const u8 {
    const directory_prefix = if (relative_directory.len == 0)
        null
    else
        try std.fmt.allocPrint(allocator, "{s}/", .{std.mem.trimEnd(u8, relative_directory, "/")});
    defer if (directory_prefix) |prefix| allocator.free(prefix);

    var files = std.ArrayList([]const u8).empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const relative = if (directory_prefix) |prefix| blk: {
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            break :blk line[prefix.len..];
        } else line;
        if (selection == .tests and !isTestFile(line)) continue;
        try files.append(allocator, try allocator.dupe(u8, relative));
    }

    return files.toOwnedSlice(allocator);
}

fn collectFilesMatching(io: Io, allocator: std.mem.Allocator, path: []const u8, selection: FileSelection) ![][]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var files = std.ArrayList([]const u8).empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    try collectOpenDir(io, allocator, &dir, "", discoveryPrefix(path), selection, &files);
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
    corpus_prefix: []const u8,
    selection: FileSelection,
    files: *std.ArrayList([]const u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {
                if (selection == .tests and entry.kind == .sym_link) continue;
                const relative = if (prefix.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ prefix, entry.name });
                errdefer allocator.free(relative);
                if (selection == .tests) {
                    const classification_path = try std.fs.path.join(allocator, &.{ corpus_prefix, relative });
                    defer allocator.free(classification_path);
                    if (!isTestFile(classification_path)) {
                        allocator.free(relative);
                        continue;
                    }
                }
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
                try collectOpenDir(io, allocator, &child, child_prefix, corpus_prefix, selection, files);
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
    try std.testing.expect(isTestFile("js/node/test/parallel/test-fs.js"));
    try std.testing.expect(!isTestFile("node-test-runner.mjs"));
    try std.testing.expect(!isTestFile("helper.ts"));
    try std.testing.expect(!isTestFile("snapshot.test.txt"));
}

test "Bun corpus collector returns sorted relative test paths" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "js/node/fs", .{});
    nested.close(std.testing.io);
    var parallel = try tmp.dir.createDirPathOpen(std.testing.io, "js/node/test/parallel", .{});
    parallel.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "js/node/test/parallel/test-readfile.js", .data = "" });
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

    try collectOpenDir(std.testing.io, std.testing.allocator, &tmp.dir, "", "", .tests, &files);
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
    try std.testing.expectEqualStrings("js/node/test/parallel/test-readfile.js", owned[1]);
    try std.testing.expectEqualStrings("z.test.ts", owned[2]);
}

test "Bun corpus manifest excludes generated and provisioned test-shaped files" {
    const manifest =
        \\bake/bake.test.ts
        \\js/node/test/fixtures/es-modules/node_modules/pkg/index.js
    ;
    const files = try collectTrackedFilesFromManifest(
        std.testing.allocator,
        manifest,
        "",
        .tests,
    );
    defer freeTestFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("bake/bake.test.ts", files[0]);

    // Neither an ignored bake output nor tests installed under a dependency
    // become corpus entries unless the pinned Bun Git tree names them.
    try std.testing.expect(!containsPath(files, "bake/fixtures/deinitialization/.bake-debug/generated.test.ts"));
    try std.testing.expect(!containsPath(files, "napi/napi-app/node_modules/retry/test/test-retry.js"));
}

test "Bun corpus manifest scopes directory runs to tracked tests" {
    const manifest =
        \\napi/napi-app/app.test.js
        \\napi/napi-app/fixture.js
        \\napi/other.test.js
    ;
    const files = try collectTrackedFilesFromManifest(
        std.testing.allocator,
        manifest,
        "napi/napi-app",
        .tests,
    );
    defer freeTestFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("app.test.js", files[0]);
}

fn containsPath(files: []const []const u8, expected: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file, expected)) return true;
    }
    return false;
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
    try std.testing.expectEqual(@as(usize, 1), counts.tests);
}

test "Bun corpus collector sees vendored upstream tests" {
    const counts = try countTrackedCorpus(std.testing.io, std.testing.allocator, default_root);
    try std.testing.expectEqual(@as(usize, expected_copied_bun_test_tree_entries), counts.files);
    try std.testing.expectEqual(@as(usize, expected_copied_bun_test_files), counts.tests);

    const tracked_files = try collectTrackedFilesMatching(
        std.testing.io,
        std.testing.allocator,
        default_root,
        "",
        .all,
    );
    defer freeTestFiles(std.testing.allocator, tracked_files);
    for (tracked_files, 0..) |file, index| {
        if (index > 0) try std.testing.expect(std.mem.lessThan(u8, tracked_files[index - 1], file));
        const full_path = try std.fs.path.join(std.testing.allocator, &.{ default_root, file });
        defer std.testing.allocator.free(full_path);
        Io.Dir.cwd().access(std.testing.io, full_path, .{ .follow_symlinks = false }) catch |err| {
            std.debug.print("tracked Bun corpus file missing from checkout: {s}\n", .{file});
            return err;
        };
    }

    const files = try collectTrackedTestFiles(std.testing.io, std.testing.allocator, default_root);
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

test "Bun corpus sync does not filter upstream test-tree files" {
    const filtered = try Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        default_root ++ "/FILTERED_FILES.txt",
        std.testing.allocator,
        std.Io.Limit.limited(64 * 1024),
    );
    defer std.testing.allocator.free(filtered);

    var lines = std.mem.splitScalar(u8, filtered, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        std.debug.print("unexpected filtered Bun corpus file: {s}\n", .{trimmed});
        try std.testing.expect(false);
    }
}

test "Bun corpus collector includes every upstream test file" {
    const upstream_root = "packages/runtime/upstream/test";
    const upstream_files = collectTestFiles(std.testing.io, std.testing.allocator, upstream_root) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer freeTestFiles(std.testing.allocator, upstream_files);

    const copied_files = try collectTrackedTestFiles(std.testing.io, std.testing.allocator, default_root);
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

    const copied_files = try collectTrackedTestFiles(std.testing.io, std.testing.allocator, default_root);
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

test "Bun corpus manifest includes every pinned file in local Bun checkout when present" {
    const upstream_root = localBunTestRoot(std.testing.allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(upstream_root);

    const tracked_files = try collectTrackedFilesMatching(
        std.testing.io,
        std.testing.allocator,
        default_root,
        "",
        .all,
    );
    defer freeTestFiles(std.testing.allocator, tracked_files);

    for (tracked_files) |file| {
        const upstream_path = try std.fs.path.join(std.testing.allocator, &.{ upstream_root, file });
        defer std.testing.allocator.free(upstream_path);
        Io.Dir.cwd().access(std.testing.io, upstream_path, .{ .follow_symlinks = false }) catch |err| {
            std.debug.print("pinned Bun file missing from local checkout: {s}\n", .{file});
            return err;
        };

        const copied_path = try std.fs.path.join(std.testing.allocator, &.{ default_root, file });
        defer std.testing.allocator.free(copied_path);
        Io.Dir.cwd().access(std.testing.io, copied_path, .{ .follow_symlinks = false }) catch |err| {
            std.debug.print("pinned Bun file missing from copied corpus: {s}\n", .{file});
            return err;
        };
    }
}

fn localBunTestRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("BUN_REPO")) |raw| {
        return std.fs.path.join(allocator, &.{ std.mem.span(raw), "test" });
    }
    const home = std.c.getenv("HOME") orelse return error.SkipZigTest;
    return std.fs.path.join(allocator, &.{ std.mem.span(home), "Code", "bun", "test" });
}

test "Bun corpus discovery keeps original directory semantics and omitted extensions" {
    for ([_][]const u8{
        "js/bun/test/parallel/test-http.ts",
        "js/node/cluster/test-worker-no-exit-http.ts",
        "js/node/http/node-http-agent-tls-options.test.mts",
        "js/node/http2/node-http2-upgrade.test.mts",
        "js/bun/http/http-spec.ts",
        "js/node/test/sequential/any-script.cjs",
    }) |path| try std.testing.expect(isTestFile(path));
    for ([_][]const u8{
        "js/node/test/fixtures/test-child.js",
        "js/third_party/jsonwebtoken/test-utils.js",
        "js/node/parallel/test-http.js",
        "js/bun/test/parallel/node_modules/pkg/test-child.js",
        "js/bun/test/parallel/.hidden/test-child.ts",
        "js/web/html/helper_test.ts",
        "js/web/html/one.test.mts.snap",
    }) |path| try std.testing.expect(!isTestFile(path));
    const files = try collectTrackedFilesFromManifest(std.testing.allocator, "js/bun/test/parallel/test-http.ts\njs/bun/test/parallel/helper.txt\n", "js/bun/test/parallel", .tests);
    defer freeTestFiles(std.testing.allocator, files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("test-http.ts", files[0]);
}
