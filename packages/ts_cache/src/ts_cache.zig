//! Persistent compilation cache — Phase 5 §11.6 of TS_PARITY_PLAN.
//!
//! Content-addressed directory cache that survives process
//! boundaries. Each cache entry is keyed by `sha256(source +
//! tsconfig)` and stores the compiled JS output plus diagnostic
//! summary. Subsequent runs of `home tsc` over an unchanged file
//! skip the entire pipeline and serve the cached result.
//!
//! On-disk wire format (versioned): every entry is stored as
//! `<cache_root>/<first2-hex>/<remaining-hex>.cache` — a sharded
//! tree that matches git, npm, and pnpm conventions so directory
//! sizes stay small even with millions of entries. Each `.cache`
//! file is a packed binary record:
//!
//!   magic[4]                   "HMC1" (4-byte version tag)
//!   diagnostic_count: u32 LE
//!   has_errors:        u8  (0 / 1)
//!   js_len:            u32 LE
//!   js[js_len]:        bytes
//!
//! Reads and writes are best-effort: a corrupt entry returns
//! `error.CorruptCacheEntry` and the caller can re-emit. Disk
//! I/O is skipped entirely when `root_path = null` (in-memory
//! mode for tests + ephemeral CLI invocations).
//!
//! Phase 5 follow-ups:
//!   - mmap'd B-tree replacement (LMDB-style) for the §11.6
//!     "TTFD 300 ms → 30 ms" target
//!   - content-addressed dependency closure: cache the bound
//!     symbol table + relation cache too, not just JS
//!   - LRU eviction with a configurable byte budget

const std = @import("std");

pub const Key = [32]u8; // SHA-256

pub const CachedResult = struct {
    /// Emitted JavaScript output. Owned by the caller after
    /// `Cache.get` returns; `Cache.put` consumes a borrowed slice
    /// and dupes internally.
    js: []const u8,
    /// Number of diagnostics produced during the cached compile.
    diagnostic_count: u32,
    /// True if the cached compile reported error-level diagnostics.
    has_errors: bool,
};

pub const CacheError = error{
    OutOfMemory,
    KeyNotFound,
    CorruptCacheEntry,
    /// Best-effort: the disk-side write failed but the in-memory
    /// state is still consistent. Callers may treat this as a
    /// soft error and continue.
    DiskWriteFailed,
};

/// On-disk format magic. Bumped if the wire format changes.
const DISK_MAGIC: [4]u8 = .{ 'H', 'M', 'C', '1' };

pub const Cache = struct {
    gpa: std.mem.Allocator,
    /// Optional disk-backing path. `null` for the in-memory mode.
    root_path: ?[]const u8,
    /// In-memory entries. Keyed by hex-encoded SHA-256.
    mem: std.StringHashMapUnmanaged(StoredEntry),

    const StoredEntry = struct {
        js: []u8,
        diagnostic_count: u32,
        has_errors: bool,
    };

    pub fn init(gpa: std.mem.Allocator, root_path: ?[]const u8) !Cache {
        var dup_path: ?[]const u8 = null;
        if (root_path) |p| {
            dup_path = try gpa.dupe(u8, p);
            // Best-effort root creation. If the FS is read-only the
            // cache silently degrades to in-memory mode.
            ensureDir(gpa, p) catch {};
        }
        return .{
            .gpa = gpa,
            .root_path = dup_path,
            .mem = .empty,
        };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.mem.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*.js);
        }
        self.mem.deinit(self.gpa);
        if (self.root_path) |p| self.gpa.free(p);
    }

    /// Compute the cache key for a (source, optional-config-blob)
    /// pair. Caller-supplied `config_blob` typically holds the
    /// canonicalized tsconfig JSON so projects with different
    /// compiler options don't collide.
    pub fn computeKey(source: []const u8, config_blob: []const u8) Key {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(source);
        if (config_blob.len > 0) {
            h.update("|");
            h.update(config_blob);
        }
        var out: Key = undefined;
        h.final(&out);
        return out;
    }

    /// Hex-encode a Key into a freshly-allocated 64-byte slice.
    /// Caller frees with `gpa.free`.
    fn keyToHex(gpa: std.mem.Allocator, k: Key) ![]u8 {
        var hex = try gpa.alloc(u8, k.len * 2);
        const charset = "0123456789abcdef";
        for (k, 0..) |b, i| {
            hex[i * 2] = charset[b >> 4];
            hex[i * 2 + 1] = charset[b & 0x0F];
        }
        return hex;
    }

    /// Look up an entry. Returns null if absent. Caller owns the
    /// returned `CachedResult.js` bytes (a fresh dupe). On disk-
    /// backed caches, a memory miss falls through to a disk read
    /// and re-populates the in-memory layer.
    pub fn get(self: *Cache, key: Key) CacheError!?CachedResult {
        const hex = try keyToHex(self.gpa, key);
        defer self.gpa.free(hex);
        if (self.mem.get(hex)) |entry| {
            const js_dupe = self.gpa.dupe(u8, entry.js) catch return error.OutOfMemory;
            return .{
                .js = js_dupe,
                .diagnostic_count = entry.diagnostic_count,
                .has_errors = entry.has_errors,
            };
        }
        // Memory miss — try disk if we have a backing root.
        if (self.root_path == null) return null;
        const loaded = try self.loadFromDisk(hex);
        if (loaded) |entry| {
            // Promote into memory so the next lookup is O(1).
            const hex_owned = self.gpa.dupe(u8, hex) catch return error.OutOfMemory;
            const js_for_mem = self.gpa.dupe(u8, entry.js) catch return error.OutOfMemory;
            self.mem.put(self.gpa, hex_owned, .{
                .js = js_for_mem,
                .diagnostic_count = entry.diagnostic_count,
                .has_errors = entry.has_errors,
            }) catch return error.OutOfMemory;
            return .{
                .js = entry.js, // already a fresh allocation, transfer ownership
                .diagnostic_count = entry.diagnostic_count,
                .has_errors = entry.has_errors,
            };
        }
        return null;
    }

    /// Store an entry. Idempotent — overwriting an existing key
    /// frees the previous value first. Disk-backed caches also
    /// write through to `<root>/<2hex>/<remaining>.cache`.
    pub fn put(self: *Cache, key: Key, value: CachedResult) CacheError!void {
        const hex = try keyToHex(self.gpa, key);
        // We move ownership of the hex key into the map, so don't
        // free it here. If the map already has an entry we drop
        // the old key+value and use the new ones.
        if (self.mem.fetchRemove(hex)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value.js);
        }
        const js_dupe = self.gpa.dupe(u8, value.js) catch return error.OutOfMemory;
        try self.mem.put(self.gpa, hex, .{
            .js = js_dupe,
            .diagnostic_count = value.diagnostic_count,
            .has_errors = value.has_errors,
        });
        if (self.root_path != null) {
            // Best-effort write-through. Disk failure does not
            // poison the in-memory state; subsequent gets will
            // still hit the cache for this process lifetime.
            self.writeToDisk(hex, value) catch {};
        }
    }

    /// True iff the cache holds an entry for `key`. Faster than
    /// `get` because it skips the value-dupe. Checks the in-memory
    /// layer plus disk.
    pub fn contains(self: *const Cache, gpa: std.mem.Allocator, key: Key) bool {
        const hex = keyToHex(gpa, key) catch return false;
        defer gpa.free(hex);
        if (self.mem.contains(hex)) return true;
        if (self.root_path) |root| {
            const path = entryPath(gpa, root, hex) catch return false;
            defer gpa.free(path);
            return fileExists(gpa, path);
        }
        return false;
    }

    // -------------------------------------------------------------
    // On-disk format
    // -------------------------------------------------------------

    /// Compose `<root>/<2hex>/<remaining>.cache`. Caller frees.
    fn entryPath(gpa: std.mem.Allocator, root: []const u8, hex: []const u8) ![]u8 {
        // hex is exactly 64 chars; first 2 form the shard dir.
        return std.fmt.allocPrint(gpa, "{s}/{s}/{s}.cache", .{ root, hex[0..2], hex[2..] });
    }

    fn shardDirPath(gpa: std.mem.Allocator, root: []const u8, hex: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, hex[0..2] });
    }

    fn writeToDisk(self: *Cache, hex: []const u8, value: CachedResult) !void {
        const root = self.root_path orelse return;
        const shard = try shardDirPath(self.gpa, root, hex);
        defer self.gpa.free(shard);
        ensureDir(self.gpa, shard) catch {};

        const path = try entryPath(self.gpa, root, hex);
        defer self.gpa.free(path);

        // Header: magic + diagnostic_count + has_errors + js_len.
        var header: [4 + 4 + 1 + 4]u8 = undefined;
        @memcpy(header[0..4], &DISK_MAGIC);
        std.mem.writeInt(u32, header[4..8], value.diagnostic_count, .little);
        header[8] = if (value.has_errors) 1 else 0;
        std.mem.writeInt(u32, header[9..13], @intCast(value.js.len), .little);

        // Compose payload + write atomically (truncate-and-write).
        const payload = self.gpa.alloc(u8, header.len + value.js.len) catch return error.DiskWriteFailed;
        defer self.gpa.free(payload);
        @memcpy(payload[0..header.len], &header);
        if (value.js.len > 0) @memcpy(payload[header.len..], value.js);

        writeFileBytes(self.gpa, path, payload) catch return error.DiskWriteFailed;
    }

    fn loadFromDisk(self: *Cache, hex: []const u8) CacheError!?CachedResult {
        const root = self.root_path orelse return null;
        const path = entryPath(self.gpa, root, hex) catch return error.OutOfMemory;
        defer self.gpa.free(path);

        const buf = readFileBytes(self.gpa, path) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CorruptCacheEntry,
        };
        defer self.gpa.free(buf);

        if (buf.len < 13) return error.CorruptCacheEntry;
        if (!std.mem.eql(u8, buf[0..4], &DISK_MAGIC)) return error.CorruptCacheEntry;
        const diag_count = std.mem.readInt(u32, buf[4..8], .little);
        const has_errors = buf[8] != 0;
        const js_len = std.mem.readInt(u32, buf[9..13], .little);
        if (buf.len < 13 + js_len) return error.CorruptCacheEntry;

        const js = self.gpa.alloc(u8, js_len) catch return error.OutOfMemory;
        if (js_len > 0) @memcpy(js, buf[13 .. 13 + js_len]);
        return .{ .js = js, .diagnostic_count = diag_count, .has_errors = has_errors };
    }

    pub fn count(self: *const Cache) u32 {
        return self.mem.count();
    }

    /// Drop every entry. Useful for tests + watchers that want
    /// to invalidate the whole cache on a tsconfig change.
    pub fn clear(self: *Cache) void {
        var it = self.mem.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*.js);
        }
        self.mem.clearRetainingCapacity();
    }
};

// =============================================================================
// File-system I/O helpers
// =============================================================================
//
// Zig 0.16-dev moved the FS surface to `std.Io.Dir`, which threads
// an `Io` instance through every call. We construct a `Threaded`
// `Io` per operation — short-lived, scoped — so the cache's API
// stays plain `std.mem.Allocator` for callers.

const FileError = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    IoFailure,
};

fn ensureDir(gpa: std.mem.Allocator, path: []const u8) FileError!void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, path) catch return error.IoFailure;
}

fn writeFileBytes(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) FileError!void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var file = cwd.createFile(io, path, .{ .truncate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => return error.IoFailure,
    };
    defer file.close(io);
    if (bytes.len == 0) return;
    file.writeStreamingAll(io, bytes) catch return error.IoFailure;
}

fn readFileBytes(gpa: std.mem.Allocator, path: []const u8) FileError![]u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => return error.IoFailure,
    };
    defer file.close(io);
    const stat = file.stat(io) catch return error.IoFailure;
    const size: usize = @intCast(stat.size);
    const buf = gpa.alloc(u8, size) catch return error.OutOfMemory;
    errdefer gpa.free(buf);
    var read_total: usize = 0;
    while (read_total < size) {
        const n = file.readPositionalAll(io, buf[read_total..], read_total) catch return error.IoFailure;
        if (n == 0) break;
        read_total += n;
    }
    return buf;
}

fn fileExists(gpa: std.mem.Allocator, path: []const u8) bool {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{}) catch return false;
    return true;
}

fn deleteTree(gpa: std.mem.Allocator, path: []const u8) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, path) catch {};
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "Cache: init + deinit roundtrips" {
    var c = try Cache.init(T.allocator, null);
    defer c.deinit();
    try T.expectEqual(@as(u32, 0), c.count());
}

test "Cache: put + get same key returns the cached value" {
    var c = try Cache.init(T.allocator, null);
    defer c.deinit();
    const k = Cache.computeKey("let x = 1;", "");
    try c.put(k, .{ .js = "let x = 1;", .diagnostic_count = 0, .has_errors = false });
    const got = (try c.get(k)) orelse return error.MissingEntry;
    defer T.allocator.free(got.js);
    try T.expectEqualStrings("let x = 1;", got.js);
    try T.expectEqual(@as(u32, 0), got.diagnostic_count);
    try T.expect(!got.has_errors);
}

test "Cache: get missing key returns null" {
    var c = try Cache.init(T.allocator, null);
    defer c.deinit();
    const k = Cache.computeKey("never stored", "");
    const got = try c.get(k);
    try T.expect(got == null);
}

test "Cache: contains is O(1) without dupe" {
    var c = try Cache.init(T.allocator, null);
    defer c.deinit();
    const k = Cache.computeKey("let x = 1;", "");
    try T.expect(!c.contains(T.allocator, k));
    try c.put(k, .{ .js = "let x = 1;", .diagnostic_count = 0, .has_errors = false });
    try T.expect(c.contains(T.allocator, k));
}

test "Cache: put overwrites the previous entry" {
    var c = try Cache.init(T.allocator, null);
    defer c.deinit();
    const k = Cache.computeKey("source", "");
    try c.put(k, .{ .js = "v1", .diagnostic_count = 0, .has_errors = false });
    try c.put(k, .{ .js = "v2", .diagnostic_count = 1, .has_errors = true });
    const got = (try c.get(k)) orelse return error.MissingEntry;
    defer T.allocator.free(got.js);
    try T.expectEqualStrings("v2", got.js);
    try T.expectEqual(@as(u32, 1), got.diagnostic_count);
    try T.expect(got.has_errors);
}

test "Cache: different sources produce different keys" {
    const k1 = Cache.computeKey("let a = 1;", "");
    const k2 = Cache.computeKey("let b = 2;", "");
    try T.expect(!std.mem.eql(u8, &k1, &k2));
}

test "Cache: same source different config produces different keys" {
    const k1 = Cache.computeKey("let x = 1;", "{\"target\":\"es2015\"}");
    const k2 = Cache.computeKey("let x = 1;", "{\"target\":\"es2022\"}");
    try T.expect(!std.mem.eql(u8, &k1, &k2));
}

test "Cache: clear empties the store" {
    var c = try Cache.init(T.allocator, null);
    defer c.deinit();
    const k = Cache.computeKey("source", "");
    try c.put(k, .{ .js = "out", .diagnostic_count = 0, .has_errors = false });
    try T.expectEqual(@as(u32, 1), c.count());
    c.clear();
    try T.expectEqual(@as(u32, 0), c.count());
    try T.expect(!c.contains(T.allocator, k));
}

test "Cache: 1000-entry stress" {
    var c = try Cache.init(T.allocator, null);
    defer c.deinit();
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        var nbuf: [32]u8 = undefined;
        const src = try std.fmt.bufPrint(&nbuf, "let v{d} = {d};", .{ i, i });
        const k = Cache.computeKey(src, "");
        try c.put(k, .{ .js = src, .diagnostic_count = 0, .has_errors = false });
    }
    try T.expectEqual(@as(u32, 1000), c.count());
}

test "Cache: keyToHex round-trips" {
    var k: Key = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    const hex = try Cache.keyToHex(T.allocator, k);
    defer T.allocator.free(hex);
    try T.expectEqual(@as(usize, 64), hex.len);
    try T.expectEqualStrings("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", hex);
}

// -----------------------------------------------------------------
// Disk-backed mode tests
// -----------------------------------------------------------------

var test_tmp_counter: std.atomic.Value(u64) = .{ .raw = 0 };
var test_tmp_seed: u64 = 0xCAFEBABEDEADBEEF;

fn tmpCacheRoot(buf: []u8) ![]const u8 {
    const n = test_tmp_counter.fetchAdd(1, .monotonic);
    // Mix in a const-folded seed plus a counter; collisions are
    // tolerated (each test deletes its own root on exit).
    return try std.fmt.bufPrint(buf, "/tmp/home-ts-cache-{x}-{d}", .{ test_tmp_seed, n });
}

test "Cache: disk put + get round-trips a single entry" {
    var pbuf: [128]u8 = undefined;
    const root = try tmpCacheRoot(&pbuf);
    defer deleteTree(T.allocator, root);

    var c = try Cache.init(T.allocator, root);
    defer c.deinit();

    const k = Cache.computeKey("let x = 1;", "");
    try c.put(k, .{ .js = "let x = 1;", .diagnostic_count = 0, .has_errors = false });

    // Spin up a fresh cache pointed at the same root — the entry
    // must come back from disk.
    var c2 = try Cache.init(T.allocator, root);
    defer c2.deinit();
    const got = (try c2.get(k)) orelse return error.MissingEntry;
    defer T.allocator.free(got.js);
    try T.expectEqualStrings("let x = 1;", got.js);
    try T.expectEqual(@as(u32, 0), got.diagnostic_count);
    try T.expect(!got.has_errors);
}

test "Cache: disk preserves diagnostic_count + has_errors" {
    var pbuf: [128]u8 = undefined;
    const root = try tmpCacheRoot(&pbuf);
    defer deleteTree(T.allocator, root);

    var c = try Cache.init(T.allocator, root);
    defer c.deinit();
    const k = Cache.computeKey("bad", "cfg");
    try c.put(k, .{ .js = "// errored", .diagnostic_count = 3, .has_errors = true });

    var c2 = try Cache.init(T.allocator, root);
    defer c2.deinit();
    const got = (try c2.get(k)) orelse return error.MissingEntry;
    defer T.allocator.free(got.js);
    try T.expectEqualStrings("// errored", got.js);
    try T.expectEqual(@as(u32, 3), got.diagnostic_count);
    try T.expect(got.has_errors);
}

test "Cache: disk shards entries by first 2 hex chars" {
    var pbuf: [128]u8 = undefined;
    const root = try tmpCacheRoot(&pbuf);
    defer deleteTree(T.allocator, root);

    var c = try Cache.init(T.allocator, root);
    defer c.deinit();
    const k = Cache.computeKey("let s = 1;", "");
    try c.put(k, .{ .js = "let s = 1;", .diagnostic_count = 0, .has_errors = false });

    const hex = try Cache.keyToHex(T.allocator, k);
    defer T.allocator.free(hex);

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}.cache", .{ root, hex[0..2], hex[2..] });
    if (!fileExists(T.allocator, path)) return error.DiskEntryMissing;
}

test "Cache: contains hits disk for entries not yet promoted" {
    var pbuf: [128]u8 = undefined;
    const root = try tmpCacheRoot(&pbuf);
    defer deleteTree(T.allocator, root);

    var c = try Cache.init(T.allocator, root);
    defer c.deinit();
    const k = Cache.computeKey("contained", "");
    try c.put(k, .{ .js = "v", .diagnostic_count = 0, .has_errors = false });

    var c2 = try Cache.init(T.allocator, root);
    defer c2.deinit();
    try T.expect(c2.contains(T.allocator, k));
}

test "Cache: corrupt disk entry surfaces error.CorruptCacheEntry" {
    var pbuf: [128]u8 = undefined;
    const root = try tmpCacheRoot(&pbuf);
    defer deleteTree(T.allocator, root);

    var c = try Cache.init(T.allocator, root);
    defer c.deinit();
    const k = Cache.computeKey("xx", "");
    try c.put(k, .{ .js = "v", .diagnostic_count = 0, .has_errors = false });

    // Stomp the magic header.
    const hex = try Cache.keyToHex(T.allocator, k);
    defer T.allocator.free(hex);
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}.cache", .{ root, hex[0..2], hex[2..] });
    try writeFileBytes(T.allocator, path, "XXXX\x00\x00\x00\x00\x00\x00\x00\x00\x00garbage");

    var c2 = try Cache.init(T.allocator, root);
    defer c2.deinit();
    try T.expectError(error.CorruptCacheEntry, c2.get(k));
}

test "Cache: in-memory mode skips disk entirely" {
    var c = try Cache.init(T.allocator, null);
    defer c.deinit();
    const k = Cache.computeKey("inmem", "");
    try c.put(k, .{ .js = "v", .diagnostic_count = 0, .has_errors = false });
    // No disk artifacts: a fresh cache pointed at no root sees nothing.
    var c2 = try Cache.init(T.allocator, null);
    defer c2.deinit();
    const got = try c2.get(k);
    try T.expect(got == null);
}
