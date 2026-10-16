const std = @import("std");
const testing = @import("vitest");
const t = testing.t;

// Tests for snapshot functionality.
test "Vitest-compatible snapshot suite" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var framework = testing.ModernTest.initWithWriter(
        std.testing.allocator,
        std.testing.io,
        .{ .reporter = .minimal, .verbose = false },
        &output.writer,
    );
    defer framework.deinit();

    testing.global_test_framework = &framework;

    // Test snapshot functionality
    try t.describe("Snapshot Creation", testSnapshotCreation);
    try t.describe("Snapshot Matching", testSnapshotMatching);
    try t.describe("Snapshot Updates", testSnapshotUpdates);

    const results = try framework.run();

    try std.testing.expect(results.total > 0);
    try std.testing.expectEqual(@as(usize, 0), results.failed);
}

// ============================================================================
// Snapshot Creation Tests
// ============================================================================

fn testSnapshotCreation() !void {
    try t.describe("initialization", struct {
        fn run() !void {
            try t.it("creates snapshots instance", testCreateSnapshots);
            try t.it("initializes with empty map", testEmptySnapshots);
        }
    }.run);
}

fn testCreateSnapshots(expect: *testing.ModernTest.Expect) !void {
    var snapshots = testing.ModernTest.Snapshots.init(expect.allocator, "__test_snapshots__");
    defer snapshots.deinit();

    // Verify creation succeeded
    expect.* = t.expect(expect.allocator, snapshots.snapshots.count(), expect.failures);
    try expect.toBe(0);
}

fn testEmptySnapshots(expect: *testing.ModernTest.Expect) !void {
    var snapshots = testing.ModernTest.Snapshots.init(expect.allocator, "__test_snapshots__");
    defer snapshots.deinit();

    // No snapshots initially
    const count = snapshots.snapshots.count();
    expect.* = t.expect(expect.allocator, count, expect.failures);
    try expect.toBe(0);
}

// ============================================================================
// Snapshot Matching Tests
// ============================================================================

fn testSnapshotMatching() !void {
    try t.describe("matchSnapshot", struct {
        fn run() !void {
            try t.it("creates snapshot on first match", testFirstMatch);
            try t.it("matches existing snapshot", testExistingMatch);
            try t.it("detects mismatch", testMismatch);
        }
    }.run);
}

fn testFirstMatch(expect: *testing.ModernTest.Expect) !void {
    var snapshots = testing.ModernTest.Snapshots.init(expect.allocator, "__test_snapshots__");
    defer snapshots.deinit();

    const value = "hello world";
    const matches = try snapshots.matchSnapshot("test1", value);

    // First time should create snapshot and return true
    expect.* = t.expect(expect.allocator, matches, expect.failures);
    try expect.toBe(true);

    // Verify snapshot was stored
    expect.* = t.expect(expect.allocator, snapshots.snapshots.count(), expect.failures);
    try expect.toBe(1);
}

fn testExistingMatch(expect: *testing.ModernTest.Expect) !void {
    var snapshots = testing.ModernTest.Snapshots.init(expect.allocator, "__test_snapshots__");
    defer snapshots.deinit();

    const value = "hello world";

    // First match creates snapshot
    _ = try snapshots.matchSnapshot("test2", value);

    // Second match with same value should return true
    const matches = try snapshots.matchSnapshot("test2", value);
    expect.* = t.expect(expect.allocator, matches, expect.failures);
    try expect.toBe(true);
}

fn testMismatch(expect: *testing.ModernTest.Expect) !void {
    var snapshots = testing.ModernTest.Snapshots.init(expect.allocator, "__test_snapshots__");
    defer snapshots.deinit();

    // First match
    _ = try snapshots.matchSnapshot("test3", "original");

    // Second match with different value should return false
    const matches = try snapshots.matchSnapshot("test3", "modified");
    expect.* = t.expect(expect.allocator, matches, expect.failures);
    try expect.toBe(false);
}

// ============================================================================
// Snapshot Updates Tests
// ============================================================================

fn testSnapshotUpdates() !void {
    try t.describe("updateSnapshot", struct {
        fn run() !void {
            try t.it("updates existing snapshot", testUpdate);
            try t.it("creates new snapshot", testCreateNew);
        }
    }.run);
}

fn testUpdate(expect: *testing.ModernTest.Expect) !void {
    var snapshots = testing.ModernTest.Snapshots.init(expect.allocator, "__test_snapshots__");
    defer snapshots.deinit();

    // Create initial snapshot
    _ = try snapshots.matchSnapshot("test4", "original");

    // Update it
    try snapshots.updateSnapshot("test4", "updated");

    // Verify update worked
    const matches = try snapshots.matchSnapshot("test4", "updated");
    expect.* = t.expect(expect.allocator, matches, expect.failures);
    try expect.toBe(true);
}

fn testCreateNew(expect: *testing.ModernTest.Expect) !void {
    var snapshots = testing.ModernTest.Snapshots.init(expect.allocator, "__test_snapshots__");
    defer snapshots.deinit();

    // Update non-existent snapshot (should create it)
    try snapshots.updateSnapshot("test5", "new value");

    // Verify it was created
    const matches = try snapshots.matchSnapshot("test5", "new value");
    expect.* = t.expect(expect.allocator, matches, expect.failures);
    try expect.toBe(true);
}
