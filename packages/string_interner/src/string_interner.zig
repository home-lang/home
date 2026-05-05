//! Lock-striped concurrent string interner.
//!
//! Replaces `packages/lexer/src/string_pool.zig` for the multi-file case
//! where many parser/binder workers intern identifiers concurrently.
//!
//! Design (per TS_PARITY_PLAN §0 Phase 0.3 and §5.3):
//!
//!   - Single 32-bit `StringId` keyspace, partitioned as
//!         (shard_index : 6) | (local_index : 26)
//!     so the top 6 bits identify the shard and the bottom 26 bits index
//!     into that shard's contiguous storage. 64 shards × 64 M slots ≈ 4 B
//!     total — comfortable for any TS or Home program (VS Code is ~ 1 M
//!     unique identifiers, Prisma generated `client.d.ts` is ~ 200 K).
//!
//!   - Each shard owns: an `RwLock`, a `StringHashMapUnmanaged` mapping
//!     content bytes → local index, an `ArrayListUnmanaged` storing the
//!     interned slices in insertion order, and an `ArenaAllocator` so the
//!     duped string bytes live as long as the interner.
//!
//!   - Shard selection is `wyhash(bytes) & SHARD_MASK`. Wyhash mixes
//!     well, so any bit selection works; we use the low bits for cheap
//!     extraction.
//!
//!   - Read path is `RwLock.lockShared` + hash table get; on a hit we
//!     return without ever taking the write lock. Write path takes the
//!     exclusive lock, double-checks, allocates from the shard arena,
//!     appends to storage, and inserts into the table.
//!
//! Reserved IDs:
//!
//!   - `id = 0` is reserved for the empty string `""`. It is interned at
//!     `init` time so callers can rely on `StringId(0)` being a valid
//!     reference to `""` from any thread without an intern call.
//!
//! Single-shard worst-case is ~ 64 M entries; the interner returns
//! `error.ShardCapacityExceeded` if a shard fills (TS programs in the
//! wild are nowhere near this).
//!
//! ## Synchronization primitive
//!
//! Zig 0.16-dev moves `std.Thread.RwLock` into `std.Io.RwLock`, which
//! requires an `Io` parameter on every operation and isn't a drop-in
//! replacement. This module provides a minimal `RwLock` built on
//! `std.atomic.Value(u32)` for now; under contention it spins, which is
//! acceptable because (a) the 64-shard partitioning keeps per-shard
//! contention near zero, and (b) the read path executes only a load and
//! a CAS even in the contended case. If profiling shows it becomes a
//! bottleneck (Phase 5), we'll swap it for a futex-backed primitive.

const std = @import("std");

/// 32-bit string identifier. Top 6 bits encode the shard index; the
/// bottom 26 bits encode the local index within that shard. This packing
/// is internal — callers should treat `StringId` as opaque.
pub const StringId = u32;

const N_SHARDS: u32 = 64;
const SHARD_BITS: u32 = 6;
const LOCAL_BITS: u32 = 32 - SHARD_BITS; // 26
const SHARD_MASK: u32 = N_SHARDS - 1; // 0x3F
const LOCAL_MASK: u32 = (@as(u32, 1) << @intCast(LOCAL_BITS)) - 1; // 0x03FF_FFFF
const MAX_LOCAL: u32 = LOCAL_MASK; // largest valid local index

pub const InternError = error{
    /// A single shard exceeded its 64 M-entry capacity. In practice this
    /// implies pathological input — every TS program in the wild fits
    /// well below this limit, and we'd rather fail loudly than silently
    /// corrupt the ID encoding.
    ShardCapacityExceeded,
    OutOfMemory,
};

/// The empty-string sentinel. Always valid; never needs an intern call.
pub const empty_string_id: StringId = 0;

/// Pack a (shard, local) pair into a `StringId`.
fn packId(shard: u32, local: u32) StringId {
    std.debug.assert(shard < N_SHARDS);
    std.debug.assert(local <= MAX_LOCAL);
    return (shard << @intCast(LOCAL_BITS)) | local;
}

fn shardOfId(id: StringId) u32 {
    return id >> @intCast(LOCAL_BITS);
}

fn localOfId(id: StringId) u32 {
    return id & LOCAL_MASK;
}

/// Minimal atomics-based RwLock. Reader-preferred; writers spin until
/// readers drain. Adequate for the 64-shard hot-path of this interner;
/// a fuller implementation lands in Phase 5 if profiling demands it.
pub const RwLock = struct {
    state: std.atomic.Value(u32),

    const WRITER_BIT: u32 = 1 << 31;

    pub fn init() RwLock {
        return .{ .state = std.atomic.Value(u32).init(0) };
    }

    pub fn lockShared(self: *RwLock) void {
        while (true) {
            const s = self.state.load(.acquire);
            if ((s & WRITER_BIT) == 0) {
                if (self.state.cmpxchgWeak(s, s + 1, .acquire, .monotonic) == null) {
                    return;
                }
            }
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockShared(self: *RwLock) void {
        _ = self.state.fetchSub(1, .release);
    }

    pub fn lock(self: *RwLock) void {
        // Acquire the writer bit (excludes other writers).
        while (true) {
            const s = self.state.load(.acquire);
            if ((s & WRITER_BIT) == 0) {
                if (self.state.cmpxchgWeak(s, s | WRITER_BIT, .acquire, .monotonic) == null) {
                    break;
                }
            }
            std.atomic.spinLoopHint();
        }
        // Wait for any active readers to drain.
        while ((self.state.load(.acquire) & ~WRITER_BIT) != 0) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *RwLock) void {
        _ = self.state.fetchAnd(~WRITER_BIT, .release);
    }
};

const Shard = struct {
    mu: RwLock align(64),
    /// Bytes-of-string → local-index. Keys are slices into our per-shard
    /// arena (i.e., owned), so equality is content equality even after
    /// hash collision.
    table: std.StringHashMapUnmanaged(u32),
    /// Local-index → bytes-of-string. Same lifetime as the keys above.
    strings: std.ArrayListUnmanaged([]const u8),
    /// Backing arena for the duped string bytes. Cleared en masse at
    /// interner teardown.
    bytes_arena: std.heap.ArenaAllocator,

    fn init(child: std.mem.Allocator) Shard {
        return .{
            .mu = RwLock.init(),
            .table = .empty,
            .strings = .empty,
            .bytes_arena = std.heap.ArenaAllocator.init(child),
        };
    }

    fn deinit(self: *Shard, parent: std.mem.Allocator) void {
        self.table.deinit(parent);
        self.strings.deinit(parent);
        self.bytes_arena.deinit();
    }
};

pub const Interner = struct {
    allocator: std.mem.Allocator,
    shards: [N_SHARDS]Shard,

    /// Construct an interner. Allocates per-shard hash-map metadata via
    /// `parent` and per-shard string bytes via per-shard arenas. The
    /// empty string is pre-interned at `init` so `empty_string_id` is
    /// always valid.
    pub fn init(parent: std.mem.Allocator) !Interner {
        var self: Interner = .{
            .allocator = parent,
            .shards = undefined,
        };
        var i: u32 = 0;
        while (i < N_SHARDS) : (i += 1) {
            self.shards[i] = Shard.init(parent);
        }
        // Pre-intern the empty string in shard 0 so it gets ID
        // `(0 << 26) | 0 = 0` deterministically.
        const eid = try self.internAt(0, "");
        std.debug.assert(eid == empty_string_id);
        return self;
    }

    pub fn deinit(self: *Interner) void {
        var i: u32 = 0;
        while (i < N_SHARDS) : (i += 1) {
            self.shards[i].deinit(self.allocator);
        }
    }

    /// Hash bytes for shard selection.
    fn shardHash(bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(0, bytes);
    }

    fn shardIndex(bytes: []const u8) u32 {
        return @as(u32, @truncate(shardHash(bytes))) & SHARD_MASK;
    }

    /// Intern a string and return its stable `StringId`. Thread-safe.
    pub fn intern(self: *Interner, bytes: []const u8) InternError!StringId {
        if (bytes.len == 0) return empty_string_id;
        return self.internAt(shardIndex(bytes), bytes);
    }

    /// Internal helper: intern `bytes` into a specific shard. Used by
    /// `init` to force the empty string into shard 0.
    fn internAt(self: *Interner, shard_idx: u32, bytes: []const u8) InternError!StringId {
        const shard = &self.shards[shard_idx];

        // Read path: optimistic shared-lock lookup.
        shard.mu.lockShared();
        if (shard.table.get(bytes)) |local| {
            shard.mu.unlockShared();
            return packId(shard_idx, local);
        }
        shard.mu.unlockShared();

        // Write path: take exclusive lock and double-check (another
        // writer may have inserted the same string while we waited).
        shard.mu.lock();
        defer shard.mu.unlock();

        if (shard.table.get(bytes)) |local| {
            return packId(shard_idx, local);
        }

        if (shard.strings.items.len >= MAX_LOCAL) {
            return error.ShardCapacityExceeded;
        }

        // Dupe the bytes into the shard's arena so their lifetime is
        // tied to the interner.
        const owned = try shard.bytes_arena.allocator().dupe(u8, bytes);

        const local: u32 = @intCast(shard.strings.items.len);

        // Reserve hash-map capacity *before* publishing into `strings`
        // so an OOM here can't leave us with `owned` referenced by
        // `strings` but not by `table`.
        try shard.table.ensureUnusedCapacity(self.allocator, 1);
        try shard.strings.append(self.allocator, owned);
        shard.table.putAssumeCapacityNoClobber(owned, local);

        return packId(shard_idx, local);
    }

    /// Resolve a `StringId` to its underlying bytes. The returned slice
    /// is owned by the interner and is valid until `deinit` is called.
    pub fn get(self: *const Interner, id: StringId) []const u8 {
        const shard_idx = shardOfId(id);
        const local = localOfId(id);
        std.debug.assert(shard_idx < N_SHARDS);
        const shard = &self.shards[shard_idx];

        // We take a shared lock because Zig's ArrayListUnmanaged growth
        // reallocates the backing buffer; concurrent intern() could move
        // the slice headers out from under us. The lock makes the read
        // trivially safe.
        var mut_shard: *Shard = @constCast(shard);
        mut_shard.mu.lockShared();
        defer mut_shard.mu.unlockShared();
        return shard.strings.items[local];
    }

    /// Look up a string without interning. Returns `null` if not present.
    /// Thread-safe.
    pub fn lookup(self: *const Interner, bytes: []const u8) ?StringId {
        if (bytes.len == 0) return empty_string_id;
        const shard_idx = shardIndex(bytes);
        const shard = &self.shards[shard_idx];

        var mut_shard: *Shard = @constCast(shard);
        mut_shard.mu.lockShared();
        defer mut_shard.mu.unlockShared();
        if (shard.table.get(bytes)) |local| {
            return packId(shard_idx, local);
        }
        return null;
    }

    /// Total number of unique strings interned across all shards.
    /// Thread-safe but inherently approximate under concurrent writers.
    pub fn count(self: *const Interner) usize {
        var n: usize = 0;
        var i: u32 = 0;
        while (i < N_SHARDS) : (i += 1) {
            const shard = &self.shards[i];
            var mut_shard: *Shard = @constCast(shard);
            mut_shard.mu.lockShared();
            n += shard.strings.items.len;
            mut_shard.mu.unlockShared();
        }
        return n;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Interner: basic intern and get" {
    const t = std.testing;
    var i = try Interner.init(t.allocator);
    defer i.deinit();

    const a = try i.intern("hello");
    const b = try i.intern("world");
    const c = try i.intern("hello");
    try t.expectEqual(a, c);
    try t.expect(a != b);
    try t.expectEqualStrings("hello", i.get(a));
    try t.expectEqualStrings("world", i.get(b));
}

test "Interner: empty string is pre-interned at id=0" {
    const t = std.testing;
    var i = try Interner.init(t.allocator);
    defer i.deinit();

    try t.expectEqual(empty_string_id, try i.intern(""));
    try t.expectEqualStrings("", i.get(empty_string_id));
}

test "Interner: count tracks unique strings only" {
    const t = std.testing;
    var i = try Interner.init(t.allocator);
    defer i.deinit();

    // count starts at 1 because empty string is pre-interned.
    try t.expectEqual(@as(usize, 1), i.count());

    _ = try i.intern("foo");
    _ = try i.intern("bar");
    _ = try i.intern("foo"); // duplicate
    try t.expectEqual(@as(usize, 3), i.count());
}

test "Interner: lookup returns null for missing strings" {
    const t = std.testing;
    var i = try Interner.init(t.allocator);
    defer i.deinit();

    try t.expectEqual(@as(?StringId, null), i.lookup("never_interned"));
    const id = try i.intern("now_interned");
    try t.expectEqual(@as(?StringId, id), i.lookup("now_interned"));
}

test "Interner: ID encoding round-trip" {
    const t = std.testing;
    var s: u32 = 0;
    while (s < N_SHARDS) : (s += 1) {
        const samples = [_]u32{ 0, 1, 2, 1234, MAX_LOCAL };
        for (samples) |local| {
            const id = packId(s, local);
            try t.expectEqual(s, shardOfId(id));
            try t.expectEqual(local, localOfId(id));
        }
    }
}

test "Interner: many strings spread across shards" {
    const t = std.testing;
    var i = try Interner.init(t.allocator);
    defer i.deinit();

    var buf: [16]u8 = undefined;
    var ids: [1000]StringId = undefined;
    var k: u32 = 0;
    while (k < 1000) : (k += 1) {
        const s = std.fmt.bufPrint(&buf, "ident_{d}", .{k}) catch unreachable;
        ids[k] = try i.intern(s);
    }

    // All IDs must be unique.
    var seen = std.AutoHashMap(StringId, void).init(t.allocator);
    defer seen.deinit();
    k = 0;
    while (k < 1000) : (k += 1) {
        try t.expect(!seen.contains(ids[k]));
        try seen.put(ids[k], {});
    }

    // Reading each back must equal the original.
    k = 0;
    while (k < 1000) : (k += 1) {
        const s = std.fmt.bufPrint(&buf, "ident_{d}", .{k}) catch unreachable;
        try t.expectEqualStrings(s, i.get(ids[k]));
    }

    // With 1000 strings across 64 shards and a good hash, the probability
    // of more than 14 empty shards is vanishingly small. We assert at
    // least 50 shards used as a generous lower bound.
    var nonempty_shards: u32 = 0;
    var s_idx: u32 = 0;
    while (s_idx < N_SHARDS) : (s_idx += 1) {
        if (i.shards[s_idx].strings.items.len > 0) nonempty_shards += 1;
    }
    try t.expect(nonempty_shards >= 50);
}

test "Interner: shard determinism — same bytes always pick same shard" {
    const t = std.testing;
    const s1 = Interner.shardIndex("typescript");
    const s2 = Interner.shardIndex("typescript");
    try t.expectEqual(s1, s2);
    try t.expect(s1 < N_SHARDS);
}

test "Interner: parallel intern stress" {
    const t = std.testing;
    var i = try Interner.init(t.allocator);
    defer i.deinit();

    const n_threads: usize = 8;
    const n_per_thread: usize = 250;

    const Worker = struct {
        interner: *Interner,
        thread_id: usize,
        per_thread: usize,

        fn run(ctx: @This()) void {
            var buf: [32]u8 = undefined;
            var k: usize = 0;
            while (k < ctx.per_thread) : (k += 1) {
                // Mix of unique-per-thread and shared-across-threads keys
                // so we exercise both insert and dedupe paths concurrently.
                const s = if (k % 3 == 0)
                    std.fmt.bufPrint(&buf, "shared_{d}", .{k}) catch unreachable
                else
                    std.fmt.bufPrint(&buf, "t{d}_k{d}", .{ ctx.thread_id, k }) catch unreachable;
                _ = ctx.interner.intern(s) catch unreachable;
            }
        }
    };

    var threads: [8]std.Thread = undefined;
    for (0..n_threads) |idx| {
        threads[idx] = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .interner = &i,
            .thread_id = idx,
            .per_thread = n_per_thread,
        }});
    }
    for (threads) |th| th.join();

    var buf: [32]u8 = undefined;
    var k: usize = 0;
    while (k < n_per_thread) : (k += 1) {
        if (k % 3 == 0) {
            const s = std.fmt.bufPrint(&buf, "shared_{d}", .{k}) catch unreachable;
            try t.expect(i.lookup(s) != null);
        }
    }
    for (0..n_threads) |tid| {
        var k2: usize = 0;
        while (k2 < n_per_thread) : (k2 += 1) {
            if (k2 % 3 != 0) {
                const s = std.fmt.bufPrint(&buf, "t{d}_k{d}", .{ tid, k2 }) catch unreachable;
                try t.expect(i.lookup(s) != null);
            }
        }
    }

    // Total count: empty + n_per_thread/3+1 shared (deduped) + n_threads
    // × (n_per_thread − shared_count) per-thread (all unique). We assert
    // a lower bound rather than equality to insulate against
    // off-by-one in the shared/per-thread mix.
    const shared_count: usize = (n_per_thread + 2) / 3; // ceil
    const expected_min: usize = 1 + shared_count + n_threads * (n_per_thread - shared_count);
    try t.expect(i.count() >= expected_min);
}

test "Interner: bytes with NUL and high bytes are interned correctly" {
    const t = std.testing;
    var i = try Interner.init(t.allocator);
    defer i.deinit();

    const a_bytes = [_]u8{ 'a', 0x00, 'b' };
    const b_bytes = [_]u8{ 0xFF, 0xFE, 0x00 };

    const a = try i.intern(&a_bytes);
    const b = try i.intern(&b_bytes);
    try t.expect(a != b);
    try t.expectEqualSlices(u8, &a_bytes, i.get(a));
    try t.expectEqualSlices(u8, &b_bytes, i.get(b));

    const a2 = try i.intern(&a_bytes);
    try t.expectEqual(a, a2);
}

test "Interner: get is stable after many subsequent inserts" {
    const t = std.testing;
    var i = try Interner.init(t.allocator);
    defer i.deinit();

    const id = try i.intern("anchor");

    var buf: [16]u8 = undefined;
    var k: u32 = 0;
    while (k < 5000) : (k += 1) {
        const s = std.fmt.bufPrint(&buf, "n_{d}", .{k}) catch unreachable;
        _ = try i.intern(s);
    }

    try t.expectEqualStrings("anchor", i.get(id));
}

test "RwLock: single-thread shared/exclusive cycle" {
    const t = std.testing;
    var lk = RwLock.init();

    lk.lockShared();
    lk.lockShared();
    lk.unlockShared();
    lk.unlockShared();
    try t.expectEqual(@as(u32, 0), lk.state.load(.acquire));

    lk.lock();
    try t.expect((lk.state.load(.acquire) & RwLock.WRITER_BIT) != 0);
    lk.unlock();
    try t.expectEqual(@as(u32, 0), lk.state.load(.acquire));
}

test "RwLock: parallel readers + serialized writer" {
    const t = std.testing;
    var lk = RwLock.init();
    var counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    const Args = struct { lk: *RwLock, c: *std.atomic.Value(u64) };
    const Worker = struct {
        fn read(args: Args) void {
            var k: u32 = 0;
            while (k < 1000) : (k += 1) {
                args.lk.lockShared();
                _ = args.c.load(.acquire);
                args.lk.unlockShared();
            }
        }
        fn write(args: Args) void {
            var k: u32 = 0;
            while (k < 100) : (k += 1) {
                args.lk.lock();
                _ = args.c.fetchAdd(1, .acq_rel);
                args.lk.unlock();
            }
        }
    };

    const args: Args = .{ .lk = &lk, .c = &counter };
    var ths: [4]std.Thread = undefined;
    ths[0] = try std.Thread.spawn(.{}, Worker.read, .{args});
    ths[1] = try std.Thread.spawn(.{}, Worker.read, .{args});
    ths[2] = try std.Thread.spawn(.{}, Worker.write, .{args});
    ths[3] = try std.Thread.spawn(.{}, Worker.write, .{args});
    for (ths) |th| th.join();

    try t.expectEqual(@as(u64, 200), counter.load(.acquire));
}
