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

test "Bun corpus test-file classifier matches Bun-style names" {
    try std.testing.expect(isTestFile("math.test.ts"));
    try std.testing.expect(isTestFile("math.test.tsx"));
    try std.testing.expect(isTestFile("math.test.js"));
    try std.testing.expect(isTestFile("math.test.mjs"));
    try std.testing.expect(isTestFile("test-fs.js"));
    try std.testing.expect(isTestFile("node-test-runner.mjs"));
    try std.testing.expect(!isTestFile("helper.ts"));
    try std.testing.expect(!isTestFile("snapshot.test.txt"));
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
