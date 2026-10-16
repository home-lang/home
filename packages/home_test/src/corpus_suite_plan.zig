const std = @import("std");

/// A suite executes every inventoried file in one native process. Its outer
/// capture budget must cover those files without changing any test deadline.
pub fn captureTimeout(file_count: usize, per_file_ms: i64) error{InvalidSuiteBudget}!i64 {
    if (file_count == 0 or per_file_ms <= 0 or file_count > std.math.maxInt(i64)) return error.InvalidSuiteBudget;
    return std.math.mul(i64, @intCast(file_count), per_file_ms) catch error.InvalidSuiteBudget;
}

test "suite capture budget scales with distinct sources and rejects invalid sizes" {
    try std.testing.expectEqual(@as(i64, 120_000), try captureTimeout(1, 120_000));
    try std.testing.expectEqual(@as(i64, 2_880_000), try captureTimeout(24, 120_000));
    try std.testing.expectError(error.InvalidSuiteBudget, captureTimeout(0, 120_000));
    try std.testing.expectError(error.InvalidSuiteBudget, captureTimeout(1, 0));
    try std.testing.expectError(error.InvalidSuiteBudget, captureTimeout(std.math.maxInt(usize), 120_000));
    try std.testing.expectError(error.InvalidSuiteBudget, captureTimeout(2, std.math.maxInt(i64)));
}

pub const SuiteContext = struct {
    execution_cwd: ?[]const u8,
    case_source_base: ?[]const u8,
    roots: []const [:0]u8,
};

pub const Plan = struct {
    evidence_root: []const u8,
    context: SuiteContext,
};

/// Owns the canonical corpus roots collected from one coordinated invocation.
/// `retain` consumes its allocation: duplicate spellings are freed immediately,
/// while the first canonical spelling remains owned until `deinit`.
pub const RootSet = struct {
    allocator: std.mem.Allocator,
    roots: std.ArrayList([:0]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) RootSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RootSet) void {
        for (self.roots.items) |root| self.allocator.free(root);
        self.roots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn retain(self: *RootSet, canonical_root: [:0]u8) ![:0]const u8 {
        for (self.roots.items) |known_root| {
            if (!std.mem.eql(u8, known_root, canonical_root)) continue;
            self.allocator.free(canonical_root);
            return known_root;
        }
        errdefer self.allocator.free(canonical_root);
        try self.roots.append(self.allocator, canonical_root);
        return canonical_root;
    }

    pub fn items(self: *const RootSet) []const [:0]u8 {
        return self.roots.items;
    }

    pub fn plan(self: *const RootSet, caller_cwd: []const u8, source_base: []const u8, explicit_context: bool) error{MissingCorpusSuiteRoot}!Plan {
        if (self.roots.items.len == 0) return error.MissingCorpusSuiteRoot;
        const mixed_roots = self.roots.items.len > 1;
        return .{
            .evidence_root = if (mixed_roots) caller_cwd else self.roots.items[0],
            .context = .{
                .execution_cwd = if (explicit_context or mixed_roots) caller_cwd else null,
                .case_source_base = if (explicit_context or mixed_roots) source_base else null,
                .roots = self.items(),
            },
        };
    }
};

/// Owns the canonical source paths and copied hashes in a native suite
/// inventory. `appendOwned` takes ownership of `path` only on success; a
/// failed hash copy or list growth leaves the caller responsible for it.
pub const SourceInventory = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        path: [:0]u8,
        sha256: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) SourceInventory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SourceInventory) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.path);
            self.allocator.free(entry.sha256);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn contains(self: *const SourceInventory, path: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return true;
        }
        return false;
    }

    pub fn appendOwned(self: *SourceInventory, path: [:0]u8, hash: [64]u8) !void {
        const sha256 = try self.allocator.dupe(u8, &hash);
        errdefer self.allocator.free(sha256);
        try self.entries.append(self.allocator, .{ .path = path, .sha256 = sha256 });
    }

    pub fn items(self: *const SourceInventory) []const Entry {
        return self.entries.items;
    }
};

test "suite source inventory transfers paths only after allocation succeeds" {
    for (0..3) |fail_index| {
        var inventory = SourceInventory.init(std.testing.allocator);
        defer inventory.deinit();
        const path = try std.testing.allocator.dupeSentinel(u8, "/tmp/corpus/a.test.ts", 0);
        const hash: [64]u8 = @splat('a');
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        inventory.allocator = failing.allocator();
        const added = inventory.appendOwned(path, hash);
        inventory.allocator = std.testing.allocator;
        if (added) |_| {
            try std.testing.expect(inventory.contains(path));
            try std.testing.expectEqualStrings(&hash, inventory.items()[0].sha256);
        } else |err| {
            std.testing.allocator.free(path);
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), inventory.items().len);
        }
    }
}

test "root set deduplicates canonical roots and owns every retained allocation" {
    var roots = RootSet.init(std.testing.allocator);
    defer roots.deinit();

    const first = try roots.retain(try std.testing.allocator.dupeSentinel(u8, "/tmp/first/packages/runtime/test/test", 0));
    const duplicate = try roots.retain(try std.testing.allocator.dupeSentinel(u8, "/tmp/first/packages/runtime/test/test", 0));
    try std.testing.expectEqual(@as(usize, 1), roots.items().len);
    try std.testing.expectEqual(first.ptr, duplicate.ptr);

    _ = try roots.retain(try std.testing.allocator.dupeSentinel(u8, "/tmp/second/packages/runtime/test/test", 0));
    try std.testing.expectEqual(@as(usize, 2), roots.items().len);
}

test "single-root plans retain the corpus project default" {
    var roots = RootSet.init(std.testing.allocator);
    defer roots.deinit();
    try std.testing.expectError(error.MissingCorpusSuiteRoot, roots.plan("/tmp/caller", "/tmp/source", false));
    _ = try roots.retain(try std.testing.allocator.dupeSentinel(u8, "/tmp/project/packages/runtime/test/test", 0));

    const implicit = try roots.plan("/tmp/caller", "/tmp/source", false);
    try std.testing.expectEqualStrings(roots.items()[0], implicit.evidence_root);
    try std.testing.expectEqual(@as(?[]const u8, null), implicit.context.execution_cwd);
    try std.testing.expectEqual(@as(?[]const u8, null), implicit.context.case_source_base);
    try std.testing.expectEqual(@as(usize, 1), implicit.context.roots.len);

    const explicit = try roots.plan("/tmp/caller", "/tmp/source", true);
    try std.testing.expectEqualStrings("/tmp/caller", explicit.context.execution_cwd.?);
    try std.testing.expectEqualStrings("/tmp/source", explicit.context.case_source_base.?);
}

test "mixed-root plans execute from the caller and retain source provenance" {
    var roots = RootSet.init(std.testing.allocator);
    defer roots.deinit();
    _ = try roots.retain(try std.testing.allocator.dupeSentinel(u8, "/tmp/first/packages/runtime/test/test", 0));
    _ = try roots.retain(try std.testing.allocator.dupeSentinel(u8, "/tmp/second/packages/runtime/test/test", 0));

    const plan = try roots.plan("/tmp/caller", "/tmp/source", false);
    try std.testing.expectEqualStrings("/tmp/caller", plan.evidence_root);
    try std.testing.expectEqualStrings("/tmp/caller", plan.context.execution_cwd.?);
    try std.testing.expectEqualStrings("/tmp/source", plan.context.case_source_base.?);
    try std.testing.expectEqual(@as(usize, 2), plan.context.roots.len);

    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .roots = plan.context.roots }, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("{\"roots\":[\"/tmp/first/packages/runtime/test/test\",\"/tmp/second/packages/runtime/test/test\"]}", encoded);
}
