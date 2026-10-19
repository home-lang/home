//! Watch mode foundation — Phase 5 §5.7 of TS_PARITY_PLAN.
//!
//! Tracks a set of source paths, polls their mtimes (or on macOS,
//! Linux, Windows, hooks platform-native FS events when available),
//! and emits a `ChangeSet` describing which files have been added,
//! modified, or removed since the previous tick.
//!
//! Phase 5 ships the foundation; the query DB (Phase 5 §5.7 also)
//! plugs in on top so a 1-line edit only re-runs the affected
//! queries instead of full-recompiling. Until then, the driver
//! does a full re-emit of every changed file.
//!
//! Filesystem abstraction matches `ts_resolver.FileSystem` so
//! tests can drive the watcher with an in-memory VirtualFs.

const std = @import("std");

pub const Stat = struct {
    /// Modification time in nanoseconds since epoch (or any
    /// monotonically-incrementing tick the FS reports).
    mtime: i128,
    /// File size in bytes.
    size: u64,
};

pub const ChangeKind = enum { added, modified, removed };

pub const Change = struct {
    path: []const u8,
    kind: ChangeKind,
};

pub const ChangeSet = struct {
    changes: std.ArrayListUnmanaged(Change),

    pub fn empty() ChangeSet {
        return .{ .changes = .empty };
    }

    pub fn deinit(self: *ChangeSet, gpa: std.mem.Allocator) void {
        for (self.changes.items) |c| gpa.free(c.path);
        self.changes.deinit(gpa);
    }

    pub fn isEmpty(self: *const ChangeSet) bool {
        return self.changes.items.len == 0;
    }
};

/// A filesystem snapshot whose changes remain pending until the caller has
/// successfully processed the whole batch. Paths in `updates` borrow the
/// owned paths in `changes`, not slots in the tracked hash map: admitting new
/// imports between observation and commit may grow and rehash that map.
pub const Observation = struct {
    gpa: std.mem.Allocator,
    changes: ChangeSet,
    updates: std.ArrayListUnmanaged(Update),

    const Update = struct {
        path: []const u8,
        previous: ?Stat,
        value: ?Stat,
    };

    pub fn deinit(self: *Observation) void {
        self.updates.deinit(self.gpa);
        self.changes.deinit(self.gpa);
    }

    /// Publish baselines only after the consumer has completed successfully.
    /// A path untracked or independently advanced since observation is left
    /// alone; committing the same observation twice is harmless.
    pub fn commit(self: *const Observation, watcher: *Watcher) void {
        for (self.updates.items) |update| {
            const slot = watcher.tracked.getPtr(update.path) orelse continue;
            if (std.meta.eql(slot.*, update.previous)) slot.* = update.value;
        }
    }
};

/// Pluggable stat interface. Null means the path is absent; other filesystem
/// failures must be reported, not mistaken for a removal.
pub const StatFs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = std.Io.Dir.StatFileError;

    pub const VTable = struct {
        /// Returns Stat or null if the path doesn't exist.
        stat: *const fn (self: *anyopaque, path: []const u8) Error!?Stat,
    };

    pub fn stat(self: StatFs, path: []const u8) Error!?Stat {
        return self.vtable.stat(self.ptr, path);
    }
};

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    fs: StatFs,
    /// Tracked path → last-known presence and stat. Null is absent, not a
    /// zero-size file with an epoch-zero modification time.
    tracked: std.StringHashMapUnmanaged(?Stat),

    pub fn init(gpa: std.mem.Allocator, fs: StatFs) Watcher {
        return .{ .gpa = gpa, .fs = fs, .tracked = .empty };
    }

    pub fn deinit(self: *Watcher) void {
        var it = self.tracked.iterator();
        while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.tracked.deinit(self.gpa);
    }

    /// Add `path` to the tracked set. Records its current stat as
    /// the baseline (so a subsequent `tick` won't report it as a
    /// change unless the file has actually moved since `track`).
    pub fn track(self: *Watcher, path: []const u8) !void {
        if (self.tracked.contains(path)) return;
        const stat = try self.fs.stat(path);
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        try self.tracked.put(self.gpa, key, stat);
    }

    /// Add a discovered group as one observation. A failed stat, allocation,
    /// or map growth leaves the tracked set and its baselines unchanged, so
    /// the caller can retry the whole group on the next watch iteration.
    pub fn trackMany(self: *Watcher, paths: []const []const u8) !void {
        var staged: std.StringHashMapUnmanaged(?Stat) = .empty;
        defer {
            var it = staged.iterator();
            while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
            staged.deinit(self.gpa);
        }

        for (paths) |path| {
            if (self.tracked.contains(path) or staged.contains(path)) continue;
            const stat = try self.fs.stat(path);
            const key = try self.gpa.dupe(u8, path);
            staged.put(self.gpa, key, stat) catch |err| {
                self.gpa.free(key);
                return err;
            };
        }

        try self.tracked.ensureUnusedCapacity(self.gpa, staged.count());
        var it = staged.iterator();
        while (it.next()) |entry| {
            self.tracked.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
        }
        // Ownership of every staged key moved to `tracked` above.
        staged.clearRetainingCapacity();
    }

    /// Stop tracking `path`. Does nothing if it isn't tracked.
    pub fn untrack(self: *Watcher, path: []const u8) void {
        if (self.tracked.fetchRemove(path)) |old| {
            self.gpa.free(old.key);
        }
    }

    /// Poll every tracked path without consuming any change. The caller owns
    /// the observation and must either commit it after processing succeeds or
    /// drop it so the same changes can be retried on the next poll.
    pub fn observe(self: *Watcher) !Observation {
        var observation: Observation = .{
            .gpa = self.gpa,
            .changes = ChangeSet.empty(),
            .updates = .empty,
        };
        errdefer observation.deinit();

        var it = self.tracked.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const prev = entry.value_ptr.*;
            const cur = try self.fs.stat(path);
            if (cur) |c| {
                if (prev) |p| {
                    if (c.mtime == p.mtime and c.size == p.size) continue;
                }
                try self.appendChange(&observation.changes, path, if (prev == null) .added else .modified);
                const owned_path = observation.changes.changes.items[observation.changes.changes.items.len - 1].path;
                try observation.updates.append(self.gpa, .{ .path = owned_path, .previous = prev, .value = c });
            } else if (prev != null) {
                try self.appendChange(&observation.changes, path, .removed);
                const owned_path = observation.changes.changes.items[observation.changes.changes.items.len - 1].path;
                try observation.updates.append(self.gpa, .{ .path = owned_path, .previous = prev, .value = null });
            }
        }
        return observation;
    }

    /// Eager-commit convenience for consumers that finish processing during
    /// the poll. Watch-mode compilation uses `observe` instead so a failed
    /// read or recompile cannot lose the event.
    pub fn tick(self: *Watcher) !ChangeSet {
        var observation = try self.observe();
        observation.commit(self);
        const changes = observation.changes;
        observation.changes = ChangeSet.empty();
        observation.deinit();
        return changes;
    }

    fn appendChange(self: *Watcher, changes: *ChangeSet, path: []const u8, kind: ChangeKind) !void {
        const owned_path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned_path);
        try changes.changes.append(self.gpa, .{ .path = owned_path, .kind = kind });
    }

    pub fn count(self: *const Watcher) usize {
        return self.tracked.count();
    }
};

// =============================================================================
// RealStatFs — real-disk implementation of `StatFs`
// =============================================================================
//
// Walks paths via `std.Io.Dir.cwd().statFile`, threading a short-
// lived `std.Io.Threaded` instance per call (matching the pattern
// in `ts_cache.zig`). Only missing paths return null. Permission, resource,
// cancellation and other stat failures propagate to the polling caller.

pub const RealStatFs = struct {
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) RealStatFs {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RealStatFs) void {
        _ = self;
    }

    pub fn fs(self: *RealStatFs) StatFs {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: StatFs.VTable = .{ .stat = realStat };

    fn realStat(p: *anyopaque, path: []const u8) StatFs.Error!?Stat {
        const self: *RealStatFs = @ptrCast(@alignCast(p));
        var threaded = std.Io.Threaded.init(self.gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();
        const s = cwd.statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        return .{
            .mtime = s.mtime.nanoseconds,
            .size = s.size,
        };
    }
};

// =============================================================================
// VirtualWatchFs — test harness
// =============================================================================

pub const VirtualWatchFs = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(Stat),
    stat_error: ?StatFs.Error = null,
    error_path: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator) VirtualWatchFs {
        return .{ .gpa = gpa, .files = .empty };
    }

    pub fn deinit(self: *VirtualWatchFs) void {
        var it = self.files.iterator();
        while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.files.deinit(self.gpa);
    }

    pub fn add(self: *VirtualWatchFs, path: []const u8, mtime: i128, size: u64) !void {
        if (self.files.getPtr(path)) |existing| {
            existing.* = .{ .mtime = mtime, .size = size };
            return;
        }
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        try self.files.put(self.gpa, key, .{ .mtime = mtime, .size = size });
    }

    pub fn remove(self: *VirtualWatchFs, path: []const u8) void {
        if (self.files.fetchRemove(path)) |old| self.gpa.free(old.key);
    }

    pub fn fs(self: *VirtualWatchFs) StatFs {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: StatFs.VTable = .{ .stat = vfsStat };

    fn vfsStat(p: *anyopaque, path: []const u8) StatFs.Error!?Stat {
        const self: *VirtualWatchFs = @ptrCast(@alignCast(p));
        if (self.stat_error) |err| {
            if (self.error_path == null or std.mem.eql(u8, self.error_path.?, path)) return err;
        }
        return self.files.get(path);
    }
};

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "Watcher: tracking unchanged file produces no changes on tick" {
    var vfs = VirtualWatchFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.add("/a.ts", 1000, 100);
    var w = Watcher.init(T.allocator, vfs.fs());
    defer w.deinit();
    try w.track("/a.ts");
    var cs = try w.tick();
    defer cs.deinit(T.allocator);
    try T.expect(cs.isEmpty());
}

test "Watcher: modified mtime surfaces as modified" {
    var vfs = VirtualWatchFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.add("/a.ts", 1000, 100);
    var w = Watcher.init(T.allocator, vfs.fs());
    defer w.deinit();
    try w.track("/a.ts");

    // Touch the file — mtime advances.
    try vfs.add("/a.ts", 2000, 100);
    var cs = try w.tick();
    defer cs.deinit(T.allocator);
    try T.expectEqual(@as(usize, 1), cs.changes.items.len);
    try T.expectEqual(ChangeKind.modified, cs.changes.items[0].kind);
}

test "Watcher: size change surfaces as modified" {
    var vfs = VirtualWatchFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.add("/a.ts", 1000, 100);
    var w = Watcher.init(T.allocator, vfs.fs());
    defer w.deinit();
    try w.track("/a.ts");

    try vfs.add("/a.ts", 1000, 200); // same mtime, larger size
    var cs = try w.tick();
    defer cs.deinit(T.allocator);
    try T.expectEqual(ChangeKind.modified, cs.changes.items[0].kind);
}

test "Watcher: removed file surfaces as removed" {
    var vfs = VirtualWatchFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.add("/a.ts", 1000, 100);
    var w = Watcher.init(T.allocator, vfs.fs());
    defer w.deinit();
    try w.track("/a.ts");

    vfs.remove("/a.ts");
    var cs = try w.tick();
    defer cs.deinit(T.allocator);
    try T.expectEqual(ChangeKind.removed, cs.changes.items[0].kind);
}

test "Watcher: track-missing then create surfaces as added" {
    var vfs = VirtualWatchFs.init(T.allocator);
    defer vfs.deinit();
    var w = Watcher.init(T.allocator, vfs.fs());
    defer w.deinit();
    try w.track("/a.ts"); // not yet on disk

    try vfs.add("/a.ts", 1000, 100);
    var cs = try w.tick();
    defer cs.deinit(T.allocator);
    try T.expectEqual(ChangeKind.added, cs.changes.items[0].kind);
}

test "Watcher: untrack stops surfacing changes" {
    var vfs = VirtualWatchFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.add("/a.ts", 1000, 100);
    var w = Watcher.init(T.allocator, vfs.fs());
    defer w.deinit();
    try w.track("/a.ts");
    w.untrack("/a.ts");
    try T.expectEqual(@as(usize, 0), w.count());

    try vfs.add("/a.ts", 9999, 9999);
    var cs = try w.tick();
    defer cs.deinit(T.allocator);
    try T.expect(cs.isEmpty());
}

test "Watcher: track is idempotent" {
    var vfs = VirtualWatchFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.add("/a.ts", 1000, 100);
    var w = Watcher.init(T.allocator, vfs.fs());
    defer w.deinit();
    try w.track("/a.ts");
    try w.track("/a.ts");
    try T.expectEqual(@as(usize, 1), w.count());
}

test "RealStatFs: stat on a known repo file returns non-null" {
    var rfs = RealStatFs.init(T.allocator);
    defer rfs.deinit();
    // `build.zig` lives at the repo root, which is the cwd when
    // `zig build test` invokes this test binary.
    const s = try rfs.fs().stat("build.zig");
    try T.expect(s != null);
    try T.expect(s.?.size > 0);
}

var nonexistent_counter: std.atomic.Value(u64) = .{ .raw = 0 };

test "RealStatFs: stat on a nonexistent path returns null" {
    var rfs = RealStatFs.init(T.allocator);
    defer rfs.deinit();
    var pbuf: [128]u8 = undefined;
    // Const-folded seed + atomic counter avoids collisions across
    // parallel runs without needing the (removed-in-0.16-dev) wall-
    // clock API. Even on collision the assertion still holds — the
    // path must not exist on disk.
    const n = nonexistent_counter.fetchAdd(1, .monotonic);
    const path = try std.fmt.bufPrint(&pbuf, "/tmp/nonexistent-home-ts-watch-{x}-{d}", .{ @as(u64, 0xCAFEBABEDEADBEEF), n });
    const s = try rfs.fs().stat(path);
    try T.expect(s == null);
}

test "Watcher: multiple files with mixed changes" {
    var vfs = VirtualWatchFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.add("/a.ts", 1000, 100);
    try vfs.add("/b.ts", 1000, 200);
    try vfs.add("/c.ts", 1000, 300);
    var w = Watcher.init(T.allocator, vfs.fs());
    defer w.deinit();
    try w.track("/a.ts");
    try w.track("/b.ts");
    try w.track("/c.ts");

    // a unchanged, b modified, c removed.
    try vfs.add("/b.ts", 2000, 200);
    vfs.remove("/c.ts");

    var cs = try w.tick();
    defer cs.deinit(T.allocator);
    try T.expectEqual(@as(usize, 2), cs.changes.items.len);

    var saw_modified = false;
    var saw_removed = false;
    for (cs.changes.items) |ch| {
        if (ch.kind == .modified) saw_modified = true;
        if (ch.kind == .removed) saw_removed = true;
    }
    try T.expect(saw_modified);
    try T.expect(saw_removed);
}
