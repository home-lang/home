// Copied from bun/src/runtime/api/bun/SSLContextCache.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun")                              → @import("home")
//   - bun.Mutex                                   → home_rt.threading.Mutex
//   - bun.strings.eqlLong                         → local `eqlLong` substitute
//   - bun.handleOom / bun.new / bun.destroy       → local fallbacks
//   - bun.default_allocator                       → home_rt.default_allocator
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the matching surface):
//   - `BoringSSL.SSL_CTX`, `BoringSSL.SSL_CTX_up_ref`, `SSL_CTX_set_ex_data`,
//     and `CRYPTO_EX_DATA` — opaque + extern stubs; the `boringssl_sys`
//     leaf in home_rt does not yet re-export these.
//   - `uws.create_bun_socket_error_t`, `uws.SocketContext.BunSocketContextOptions`,
//     `SSLConfig`, and `c.us_ssl_ctx_cache_ex_idx` — modeled as locally-
//     defined opaque/enum stubs so the file compiles standalone.
//   - The on-free C callback (`bun_ssl_ctx_cache_on_free`) is preserved
//     verbatim so the comptime force-link reference below stays valid.
//
// The cache map machinery (digest hashing, tombstoning, compact, deinit)
// is pure-Zig and exercised by tests.

//! Process/VM-scoped weak cache of `SSL_CTX*` keyed by config digest.
//!
//! The map holds **zero** refs on the cached `SSL_CTX*`. An `SSL_CTX` ex_data
//! slot stores a back-pointer to the heap `Entry`; BoringSSL's `CRYPTO_EX_free`
//! callback tombstones the entry (`entry.ctx = null`) when the real refcount
//! hits 0. The next `getOrCreate` for that digest sees the tombstone and rebuilds.

const SSLContextCache = @This();

map: std.ArrayHashMapUnmanaged(Digest, *Entry, DigestContext, false) = .empty,
mutex: home_rt.threading.Mutex = .{},
ops_since_compact: u32 = 0,

pub const Digest = [32]u8;

/// SHA-256 output is uniformly distributed, so the first 4 bytes are a perfect
/// bucket hash — no need to re-Wyhash 32 bytes (what AutoContext would do).
/// `eql` still compares the full digest. `store_hash = false` since recompute
/// is a single load.
const DigestContext = struct {
    pub fn hash(_: @This(), k: Digest) u32 {
        return std.mem.readInt(u32, k[0..4], .little);
    }
    pub fn eql(_: @This(), a: Digest, b: Digest, _: usize) bool {
        return eqlLong(&a, &b);
    }
};

pub const Entry = struct {
    /// Nulled by `bun_ssl_ctx_cache_on_free` when BoringSSL drops the last
    /// ref. Tombstoned entries are reclaimed on the next `getOrCreate` for the
    /// same digest, or by the periodic compact.
    ctx: ?*BoringSSL.SSL_CTX,
    owner: *SSLContextCache,
};

/// Returns +1 ref; caller must `SSL_CTX_free`. The map itself holds no ref.
pub fn getOrCreate(
    self: *SSLContextCache,
    config: anytype,
    err: *uws.create_bun_socket_error_t,
) ?*BoringSSL.SSL_CTX {
    const opts = config.asUSockets();
    return self.getOrCreateDigest(opts, opts.digest(), err);
}

/// Variant for callers that already projected to `BunSocketContextOptions`
/// (e.g. via `asUSocketsForClientVerification()`).
pub fn getOrCreateOpts(
    self: *SSLContextCache,
    opts: uws.SocketContext.BunSocketContextOptions,
    err: *uws.create_bun_socket_error_t,
) ?*BoringSSL.SSL_CTX {
    return self.getOrCreateDigest(opts, opts.digest(), err);
}

/// Core entry — `d` already computed by caller. `SecureContext.intern()`
/// threads its WeakGCMap key through here so the SHA-256 runs once total
/// instead of three times on a miss.
pub fn getOrCreateDigest(
    self: *SSLContextCache,
    opts: uws.SocketContext.BunSocketContextOptions,
    d: Digest,
    err: *uws.create_bun_socket_error_t,
) ?*BoringSSL.SSL_CTX {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(d)) |entry| {
            if (entry.ctx) |ctx| {
                _ = BoringSSL.SSL_CTX_up_ref(ctx);
                return ctx;
            }
        }
    }

    // Miss (or tombstoned): build outside the lock. `createSSLContext` does
    // file I/O / cert parsing and on Windows the system-CA load — none of
    // which has a reason to serialize, and holding a non-reentrant SRWLock
    // across an SSL_CTX_free that *did* tombstone would self-deadlock.
    const ctx = opts.createSSLContext(err) orelse return null;

    self.mutex.lock();
    defer self.mutex.unlock();

    // Re-check: another caller may have inserted while we were building.
    // Prefer the already-cached one and drop ours so callers converge.
    const gop = handleOom(self.map.getOrPut(home_rt.default_allocator, d));
    if (gop.found_existing) {
        const entry = gop.value_ptr.*;
        if (entry.ctx) |existing| {
            _ = BoringSSL.SSL_CTX_up_ref(existing);
            BoringSSL.SSL_CTX_free(ctx);
            return existing;
        }
        // Tombstone — adopt the rebuilt CTX into the existing slot.
        if (BoringSSL.SSL_CTX_set_ex_data(ctx, c.us_ssl_ctx_cache_ex_idx(), entry) != 1) return ctx;
        entry.ctx = ctx;
        return ctx;
    }

    const entry = newEntry(.{ .ctx = ctx, .owner = self });
    gop.value_ptr.* = entry;
    if (BoringSSL.SSL_CTX_set_ex_data(ctx, c.us_ssl_ctx_cache_ex_idx(), entry) != 1) {
        _ = self.map.swapRemove(d);
        destroyEntry(entry);
        return ctx;
    }

    self.ops_since_compact += 1;
    if (self.ops_since_compact > 16) {
        self.ops_since_compact = 0;
        self.compactLocked();
    }
    return ctx;
}

/// `CRYPTO_EX_free` for the cache slot. `ptr` is the `*Entry` we stashed via
/// `SSL_CTX_set_ex_data` (null for CTXs that never went through the cache —
/// e.g. `HTTPThread`'s, or build-fail paths). Runs synchronously inside
/// whichever `SSL_CTX_free` took the refcount to zero, on that caller's
/// thread; for the per-VM cache that's always the JS thread.
export fn bun_ssl_ctx_cache_on_free(
    parent: ?*anyopaque,
    ptr: ?*anyopaque,
    ad: [*c]BoringSSL.CRYPTO_EX_DATA,
    index: c_int,
    argl: c_long,
    argp: ?*anyopaque,
) callconv(.c) void {
    _ = parent;
    _ = ad;
    _ = index;
    _ = argl;
    _ = argp;
    const entry: *Entry = @ptrCast(@alignCast(ptr orelse return));
    entry.owner.mutex.lock();
    defer entry.owner.mutex.unlock();
    entry.ctx = null;
}

/// Reclaim tombstoned entries. Locked variant — callers hold `self.mutex`.
fn compactLocked(self: *SSLContextCache) void {
    var i: usize = 0;
    while (i < self.map.count()) {
        const entry = self.map.values()[i];
        if (entry.ctx == null) {
            destroyEntry(entry);
            self.map.swapRemoveAt(i);
        } else i += 1;
    }
}

/// VM teardown. Clears each live entry's ex_data so the eventual
/// `SSL_CTX_free` (from sockets/SecureContexts that outlive RareData) doesn't
/// dereference the freed `Entry`/map. Map itself holds no refs, so no
/// `SSL_CTX_free` here.
pub fn deinit(self: *SSLContextCache) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    for (self.map.values()) |entry| {
        if (entry.ctx) |ctx| {
            _ = BoringSSL.SSL_CTX_set_ex_data(ctx, c.us_ssl_ctx_cache_ex_idx(), null);
        }
        destroyEntry(entry);
    }
    self.map.deinit(home_rt.default_allocator);
}

pub const c = struct {
    /// Registered alongside the other usockets ex_data slots in
    /// `us_ex_idx_init` (pthread_once-guarded). Soft-linked through a
    /// function-pointer indirection so the file builds standalone; reassign
    /// in the wire-up TU when the real symbol is available.
    pub var us_ssl_ctx_cache_ex_idx: *const fn () callconv(.c) c_int = stub_ex_idx;
    fn stub_ex_idx() callconv(.c) c_int {
        return 0;
    }
};

comptime {
    // Force into the link even though nothing in Zig calls it — `openssl.c`
    // references it as the `CRYPTO_EX_free` for `us_ctx_cache_ex_idx`.
    _ = &bun_ssl_ctx_cache_on_free;
    _ = &home_rt.upstream_sha;
}

// ============================================================================
// Local helpers (substitutes for bun.* surface not yet on home_rt)
// ============================================================================

/// `bun.strings.eqlLong` substitute. The two slices are always 32 bytes here
/// (the SHA-256 digest), so a plain `std.mem.eql` is fine — the SIMD-backed
/// fast path in bun is an optimization, not a correctness requirement.
fn eqlLong(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `bun.handleOom` substitute. Same crash-on-OOM semantics.
fn handleOom(result: anytype) @typeInfo(@TypeOf(result)).error_union.payload {
    return result catch @panic("out of memory");
}

/// `bun.new(Entry, …)` substitute.
fn newEntry(value: Entry) *Entry {
    const p = home_rt.default_allocator.create(Entry) catch @panic("out of memory");
    p.* = value;
    return p;
}

/// `bun.destroy` substitute.
fn destroyEntry(p: *Entry) void {
    home_rt.default_allocator.destroy(p);
}

const std = @import("std");
const home_rt = @import("home");

// ============================================================================
// Local stubs for the bun.uws / bun.BoringSSL / bun.jsc surface
// ============================================================================

const BoringSSL = home_rt.boringssl_sys.boringssl;

pub const uws = home_rt.uws;

const SSLConfig = struct {
    pub fn asUSockets(_: *const SSLConfig) uws.SocketContext.BunSocketContextOptions {
        return .{};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SSLContextCache.DigestContext: hash is little-endian first 4 bytes" {
    var d: Digest = @splat(0);
    d[0] = 0xAA;
    d[1] = 0xBB;
    d[2] = 0xCC;
    d[3] = 0xDD;
    try std.testing.expectEqual(@as(u32, 0xDDCCBBAA), DigestContext.hash(.{}, d));
}

test "SSLContextCache.DigestContext: eql compares full digest" {
    var a: Digest = @splat(0);
    var b: Digest = @splat(0);
    a[0] = 1;
    b[0] = 1;
    try std.testing.expect(DigestContext.eql(.{}, a, b, 0));
    b[31] = 1;
    try std.testing.expect(!DigestContext.eql(.{}, a, b, 0));
}

test "SSLContextCache.Entry: stores ctx pointer and owner" {
    var cache: SSLContextCache = .{};
    var fake_ctx: u8 = 0;
    const ctx: *BoringSSL.SSL_CTX = @ptrCast(&fake_ctx);
    var entry: Entry = .{ .ctx = ctx, .owner = &cache };
    try std.testing.expectEqual(ctx, entry.ctx.?);
    try std.testing.expectEqual(&cache, entry.owner);
    entry.ctx = null;
    try std.testing.expect(entry.ctx == null);
}

test "SSLContextCache: deinit on empty map does not crash" {
    var cache: SSLContextCache = .{};
    cache.deinit();
}

test "SSLContextCache: compactLocked drops tombstoned entries" {
    var cache: SSLContextCache = .{};
    defer cache.deinit();

    var d_live: Digest = @splat(0);
    d_live[0] = 1;
    var d_dead: Digest = @splat(0);
    d_dead[0] = 2;

    var fake_ctx: u8 = 0;
    const ctx: *BoringSSL.SSL_CTX = @ptrCast(&fake_ctx);

    const live = newEntry(.{ .ctx = ctx, .owner = &cache });
    const dead = newEntry(.{ .ctx = null, .owner = &cache });

    const gop_live = handleOom(cache.map.getOrPut(home_rt.default_allocator, d_live));
    gop_live.value_ptr.* = live;
    const gop_dead = handleOom(cache.map.getOrPut(home_rt.default_allocator, d_dead));
    gop_dead.value_ptr.* = dead;

    try std.testing.expectEqual(@as(usize, 2), cache.map.count());

    cache.mutex.lock();
    cache.compactLocked();
    cache.mutex.unlock();

    try std.testing.expectEqual(@as(usize, 1), cache.map.count());
    try std.testing.expect(cache.map.get(d_live) != null);
    try std.testing.expect(cache.map.get(d_dead) == null);

    live.ctx = null;
}

test "SSLContextCache: handleOom panics on OOM (compile-only sanity)" {
    // Just check the helper handles non-error result correctly.
    const r: error{Foo}!u32 = 42;
    try std.testing.expectEqual(@as(u32, 42), handleOom(r));
}
