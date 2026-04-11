//! Standalone tests for the cycle-detection logic added to
//! `monomorphization.zig`. We can't import the real Monomorphization type from
//! here because the surrounding file still uses zig 0.15 ArrayList API and
//! won't compile under zig 0.16-dev. Instead these tests reproduce the
//! relevant data structures (an in_progress set + a depth counter + a max)
//! and verify the algorithm directly. When the rest of monomorphization.zig
//! gets the zig-0.16 cleanup these tests should be folded back in.

const std = @import("std");

const CycleGuard = struct {
    in_progress: std.StringHashMap(void),
    current_depth: usize = 0,
    max_depth: usize = 32,

    fn init(allocator: std.mem.Allocator) CycleGuard {
        return .{ .in_progress = std.StringHashMap(void).init(allocator) };
    }
    fn deinit(self: *CycleGuard) void {
        self.in_progress.deinit();
    }

    /// Mirror of the prologue/epilogue in `monomorphizeFunction`. Returns an
    /// error if a cycle or depth overflow is detected. The caller is expected
    /// to free the dup'd name through whatever cleanup path the real impl
    /// uses; in the real code that's a defer block.
    fn enter(
        self: *CycleGuard,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) error{ RecursiveMonomorphization, OutOfMemory }!void {
        if (self.in_progress.contains(name)) return error.RecursiveMonomorphization;
        if (self.current_depth >= self.max_depth) return error.RecursiveMonomorphization;
        const owned = try allocator.dupe(u8, name);
        try self.in_progress.put(owned, {});
        self.current_depth += 1;
    }

    fn exit(self: *CycleGuard, allocator: std.mem.Allocator, name: []const u8) void {
        if (self.in_progress.fetchRemove(name)) |kv| {
            allocator.free(kv.key);
        }
        self.current_depth -= 1;
    }
};

test "cycle guard: fresh state" {
    var g = CycleGuard.init(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 0), g.current_depth);
    try std.testing.expectEqual(@as(usize, 32), g.max_depth);
}

test "cycle guard: enter then exit balances" {
    var g = CycleGuard.init(std.testing.allocator);
    defer g.deinit();
    try g.enter(std.testing.allocator, "Foo<int>");
    try std.testing.expectEqual(@as(usize, 1), g.current_depth);
    g.exit(std.testing.allocator, "Foo<int>");
    try std.testing.expectEqual(@as(usize, 0), g.current_depth);
}

test "cycle guard: detects direct recursion" {
    var g = CycleGuard.init(std.testing.allocator);
    defer g.deinit();
    try g.enter(std.testing.allocator, "Tree<int>");
    // Re-entering the same instantiation must fail.
    try std.testing.expectError(
        error.RecursiveMonomorphization,
        g.enter(std.testing.allocator, "Tree<int>"),
    );
    g.exit(std.testing.allocator, "Tree<int>");
}

test "cycle guard: indirect cycles also caught" {
    var g = CycleGuard.init(std.testing.allocator);
    defer g.deinit();

    try g.enter(std.testing.allocator, "A<int>");
    try g.enter(std.testing.allocator, "B<int>");
    // A → B → A would be a cycle.
    try std.testing.expectError(
        error.RecursiveMonomorphization,
        g.enter(std.testing.allocator, "A<int>"),
    );
    g.exit(std.testing.allocator, "B<int>");
    g.exit(std.testing.allocator, "A<int>");
}

test "cycle guard: depth limit refuses excessive nesting" {
    var g = CycleGuard.init(std.testing.allocator);
    defer g.deinit();
    g.max_depth = 4;

    var i: usize = 0;
    var name_buf: [16]u8 = undefined;
    while (i < g.max_depth) : (i += 1) {
        const n = try std.fmt.bufPrint(&name_buf, "T{d}", .{i});
        try g.enter(std.testing.allocator, n);
    }

    // The 5th level must be refused even though it's a fresh instantiation.
    try std.testing.expectError(
        error.RecursiveMonomorphization,
        g.enter(std.testing.allocator, "T_overflow"),
    );

    // Walk back out so the test cleanup is balanced.
    var j: usize = g.max_depth;
    while (j > 0) : (j -= 1) {
        const n = try std.fmt.bufPrint(&name_buf, "T{d}", .{j - 1});
        g.exit(std.testing.allocator, n);
    }
    try std.testing.expectEqual(@as(usize, 0), g.current_depth);
}

test "cycle guard: distinct instantiations of same generic don't false-positive" {
    var g = CycleGuard.init(std.testing.allocator);
    defer g.deinit();

    try g.enter(std.testing.allocator, "Vec<int>");
    // Different type args = different mangled name = not a cycle.
    try g.enter(std.testing.allocator, "Vec<string>");
    try std.testing.expectEqual(@as(usize, 2), g.current_depth);

    g.exit(std.testing.allocator, "Vec<string>");
    g.exit(std.testing.allocator, "Vec<int>");
}
