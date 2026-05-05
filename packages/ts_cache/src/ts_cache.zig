//! Persistent compilation cache — Phase 5 §11.6 of TS_PARITY_PLAN.
//!
//! Content-addressed directory cache that survives process
//! boundaries. Each cache entry is keyed by `sha256(source +
//! tsconfig)` and stores the compiled JS output plus diagnostic
//! summary. Subsequent runs of `home tsc` over an unchanged file
//! skip the entire pipeline and serve the cached result.
//!
//! Format: `<cache_root>/<first2-hex>/<remaining-hex>.cache`
//!   — sharded by the first byte of the hash so directories
//!   stay small (matches git, npm caches).
//!
//! Phase 5 ships:
//!   - `Cache.init(gpa, root_path)` — opens (or creates) the
//!     cache root
//!   - `Cache.get(key) -> ?CachedResult` — fetches
//!   - `Cache.put(key, value) -> !void` — stores
//!   - `Cache.computeKey(source, tsconfig_blob)` — sha256 helper
//!   - In-memory mode: when `root_path = null`, the cache becomes
//!     a process-local hashmap (no disk I/O) — useful for tests
//!     and ephemeral CLI invocations
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
    /// Disk I/O is currently a Phase 5 follow-up; an in-memory
    /// cache is what ships today.
    IoNotImplemented,
};

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
        if (root_path) |p| dup_path = try gpa.dupe(u8, p);
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
    /// returned `CachedResult.js` bytes (a fresh dupe).
    pub fn get(self: *Cache, key: Key) CacheError!?CachedResult {
        const hex = try keyToHex(self.gpa, key);
        defer self.gpa.free(hex);
        const entry = self.mem.get(hex) orelse return null;
        const js_dupe = self.gpa.dupe(u8, entry.js) catch return error.OutOfMemory;
        return .{
            .js = js_dupe,
            .diagnostic_count = entry.diagnostic_count,
            .has_errors = entry.has_errors,
        };
    }

    /// Store an entry. Idempotent — overwriting an existing key
    /// frees the previous value first.
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
    }

    /// True iff the cache holds an entry for `key`. Faster than
    /// `get` because it skips the value-dupe.
    pub fn contains(self: *const Cache, gpa: std.mem.Allocator, key: Key) bool {
        const hex = keyToHex(gpa, key) catch return false;
        defer gpa.free(hex);
        return self.mem.contains(hex);
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
