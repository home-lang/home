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

/// Pluggable stat interface. Real-disk implementations call
/// `std.fs.cwd().statFile(path)`; tests use VirtualWatchFs.
pub const StatFs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns Stat or null if the path doesn't exist.
        stat: *const fn (self: *anyopaque, path: []const u8) ?Stat,
    };

    pub fn stat(self: StatFs, path: []const u8) ?Stat {
        return self.vtable.stat(self.ptr, path);
    }
};

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    fs: StatFs,
    /// Tracked path → last-known stat.
    tracked: std.StringHashMapUnmanaged(Stat),

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
        const key = try self.gpa.dupe(u8, path);
        const stat = self.fs.stat(path) orelse Stat{ .mtime = 0, .size = 0 };
        try self.tracked.put(self.gpa, key, stat);
    }

    /// Stop tracking `path`. Does nothing if it isn't tracked.
    pub fn untrack(self: *Watcher, path: []const u8) void {
        if (self.tracked.fetchRemove(path)) |old| {
            self.gpa.free(old.key);
        }
    }

    /// Poll every tracked path and produce a `ChangeSet`. The
    /// caller owns the returned `ChangeSet` and must `deinit` it.
    pub fn tick(self: *Watcher) !ChangeSet {
        var cs = ChangeSet.empty();
        errdefer cs.deinit(self.gpa);

        var it = self.tracked.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const prev = entry.value_ptr.*;
            const cur = self.fs.stat(path);
            if (cur == null) {
                // Removed.
                try cs.changes.append(self.gpa, .{
                    .path = try self.gpa.dupe(u8, path),
                    .kind = .removed,
                });
                continue;
            }
            const c = cur.?;
            if (c.mtime != prev.mtime or c.size != prev.size) {
                // Modified — also catches `added` if prev was the
                // zero-stat from track(missing-path).
                const kind: ChangeKind = if (prev.mtime == 0 and prev.size == 0) .added else .modified;
                try cs.changes.append(self.gpa, .{
                    .path = try self.gpa.dupe(u8, path),
                    .kind = kind,
                });
                entry.value_ptr.* = c;
            }
        }
        return cs;
    }

    pub fn count(self: *const Watcher) usize {
        return self.tracked.count();
    }
};

// =============================================================================
// VirtualWatchFs — test harness
// =============================================================================

pub const VirtualWatchFs = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(Stat),

    pub fn init(gpa: std.mem.Allocator) VirtualWatchFs {
        return .{ .gpa = gpa, .files = .empty };
    }

    pub fn deinit(self: *VirtualWatchFs) void {
        var it = self.files.iterator();
        while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.files.deinit(self.gpa);
    }

    pub fn add(self: *VirtualWatchFs, path: []const u8, mtime: i128, size: u64) !void {
        if (self.files.fetchRemove(path)) |old| self.gpa.free(old.key);
        const key = try self.gpa.dupe(u8, path);
        try self.files.put(self.gpa, key, .{ .mtime = mtime, .size = size });
    }

    pub fn remove(self: *VirtualWatchFs, path: []const u8) void {
        if (self.files.fetchRemove(path)) |old| self.gpa.free(old.key);
    }

    pub fn fs(self: *VirtualWatchFs) StatFs {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: StatFs.VTable = .{ .stat = vfsStat };

    fn vfsStat(p: *anyopaque, path: []const u8) ?Stat {
        const self: *VirtualWatchFs = @ptrCast(@alignCast(p));
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
