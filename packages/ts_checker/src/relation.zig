//! Type relations — Phase 3 of TS_PARITY_PLAN.
//!
//! Implements the four core relations:
//!   * **identity** — `A` and `B` are the *same* type structurally.
//!   * **assignable** — `A` is assignable to `B` (`let b: B = a;`).
//!   * **subtype** — `A` is a subtype of `B` (more strict than
//!     assignable; `any` is *not* a subtype of everything).
//!   * **comparable** — used for `==` / `!=` checks.
//!
//! Phase 3 ships the structural foundation; full conformance with tsc
//! lands during Phase 6. The cache layout (§5.4) is designed for
//! Phase 5 partition-parallel checking — the per-worker L1 + shared
//! L2 split is wired here even though only a single worker drives it
//! today, so wiring the parallel checker tomorrow is a no-op for the
//! relation surface.
//!
//! Verified architectural advantage: tsgo's relation cache is
//! per-checker (Appendix D.3) — N partitions duplicate work on
//! cross-cutting type pairs. Home's two-level cache eliminates this.

const std = @import("std");
const types = @import("types.zig");
const interner = @import("interner.zig");
const string_interner = @import("string_interner");

pub const TypeId = types.TypeId;
pub const Primitive = types.Primitive;
pub const Pool = types.Pool;
pub const Interner = interner.Interner;

/// Maximum `computeAssignable` nesting before the relation engine
/// treats the in-flight comparison as related and unwinds, guarding
/// against unbounded recursion on self-referential generic aliases
/// whose instantiations intern to fresh type ids each level. Chosen to
/// comfortably exceed any realistic hand-written nesting depth while
/// staying well under the native stack budget; mirrors the spirit of
/// tsc's `recursiveTypeRelatedTo` stack-depth==100 overflow cutoff.
pub const max_relate_depth: u32 = 200;

pub const Relation = enum(u8) {
    identity,
    assignable,
    subtype,
    comparable,
};

pub const Result = enum(u2) {
    /// Cache miss — caller should compute.
    miss = 0,
    /// `A` and `B` are in the relation.
    yes = 1,
    /// `A` and `B` are NOT in the relation.
    no = 2,
    /// Computation in flight — cycle detection.
    pending = 3,
};

/// Pack `(relation, source, target)` into a u64 for cache keys.
/// Layout: `rel:8 | source:28 | target:28`.
pub fn packKey(rel: Relation, src: TypeId, tgt: TypeId) u64 {
    return (@as(u64, @intFromEnum(rel)) << 56) |
        (@as(u64, src) << 28) |
        @as(u64, tgt);
}

/// L1 capacity — per-worker, lockless, sized to fit the hot working
/// set of a typical file's relation queries. When the table reaches
/// this size we evict the oldest half (FIFO via insertion-order ring).
pub const L1_CAPACITY: u32 = 256;

/// L2 capacity — shared across workers, locked, sized to retain
/// cross-cutting type-pair results (e.g. interfaces consulted by
/// many partitions). Same FIFO eviction policy at the boundary.
pub const L2_CAPACITY: u32 = 16384;

/// Promote every Nth L1 insertion into L2. A small power-of-two
/// stride keeps L2 hot for cross-worker sharing without flooding
/// the locked path on every miss.
pub const L2_PROMOTION_STRIDE: u32 = 4;

/// Tiny atomic spin mutex for the L2 cache. We roll our own rather
/// than depend on a specific `std.Thread.Mutex` shape — the std API
/// is in flux on the targeted Zig version. The L2 hot path is short
/// (one map lookup or insert), so a spin lock is fine.
pub const SpinMutex = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(false, .release);
    }
};

/// Per-worker L1 cache. Lockless; one of these lives inside each
/// `TwoLevelCache` and (in the eventual parallel checker) per worker.
/// Backed by an open-addressed `u64 → Result` map plus a small ring
/// buffer of recently inserted keys for FIFO eviction at the cap.
pub const L1Cache = struct {
    gpa: std.mem.Allocator,
    table: std.AutoHashMapUnmanaged(u64, Result),
    /// Ring of insertion-ordered keys; size matches `cap`. Oldest at
    /// `ring_head`; tail is `(ring_head + ring_len) % cap`.
    ring: []u64,
    ring_head: u32 = 0,
    ring_len: u32 = 0,
    cap: u32,

    pub fn init(gpa: std.mem.Allocator) !L1Cache {
        return initWithCapacity(gpa, L1_CAPACITY);
    }

    pub fn initWithCapacity(gpa: std.mem.Allocator, cap: u32) !L1Cache {
        const ring = try gpa.alloc(u64, cap);
        return .{
            .gpa = gpa,
            .table = .empty,
            .ring = ring,
            .cap = cap,
        };
    }

    pub fn deinit(self: *L1Cache) void {
        self.table.deinit(self.gpa);
        self.gpa.free(self.ring);
    }

    pub fn lookup(self: *const L1Cache, key: u64) Result {
        return self.table.get(key) orelse .miss;
    }

    /// Insert/overwrite; evicts the oldest half on overflow.
    pub fn insert(self: *L1Cache, key: u64, r: Result) !void {
        // Updating an existing key keeps insertion order — no eviction.
        if (self.table.getPtr(key)) |slot| {
            slot.* = r;
            return;
        }
        if (self.ring_len >= self.cap) {
            // Evict the oldest half of the ring in FIFO order.
            const drop = self.cap / 2;
            var i: u32 = 0;
            while (i < drop) : (i += 1) {
                const evict_key = self.ring[self.ring_head];
                _ = self.table.remove(evict_key);
                self.ring_head = (self.ring_head + 1) % self.cap;
                self.ring_len -= 1;
            }
        }
        try self.table.put(self.gpa, key, r);
        const tail = (self.ring_head + self.ring_len) % self.cap;
        self.ring[tail] = key;
        self.ring_len += 1;
    }

    pub fn count(self: *const L1Cache) u32 {
        return self.table.count();
    }
};

/// Shared L2 cache — locked, larger capacity. The mutex is held for
/// both lookups and inserts; lookups in the hot path should hit L1
/// and skip L2 entirely.
pub const L2Cache = struct {
    gpa: std.mem.Allocator,
    mu: SpinMutex = .{},
    table: std.AutoHashMapUnmanaged(u64, Result),
    ring: []u64,
    ring_head: u32 = 0,
    ring_len: u32 = 0,
    cap: u32,

    pub fn init(gpa: std.mem.Allocator) !L2Cache {
        return initWithCapacity(gpa, L2_CAPACITY);
    }

    pub fn initWithCapacity(gpa: std.mem.Allocator, cap: u32) !L2Cache {
        const ring = try gpa.alloc(u64, cap);
        return .{
            .gpa = gpa,
            .table = .empty,
            .ring = ring,
            .cap = cap,
        };
    }

    pub fn deinit(self: *L2Cache) void {
        self.table.deinit(self.gpa);
        self.gpa.free(self.ring);
    }

    pub fn lookup(self: *L2Cache, key: u64) Result {
        self.mu.lock();
        defer self.mu.unlock();
        return self.table.get(key) orelse .miss;
    }

    pub fn insert(self: *L2Cache, key: u64, r: Result) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.table.getPtr(key)) |slot| {
            slot.* = r;
            return;
        }
        if (self.ring_len >= self.cap) {
            const drop = self.cap / 2;
            var i: u32 = 0;
            while (i < drop) : (i += 1) {
                const evict_key = self.ring[self.ring_head];
                _ = self.table.remove(evict_key);
                self.ring_head = (self.ring_head + 1) % self.cap;
                self.ring_len -= 1;
            }
        }
        try self.table.put(self.gpa, key, r);
        const tail = (self.ring_head + self.ring_len) % self.cap;
        self.ring[tail] = key;
        self.ring_len += 1;
    }

    pub fn count(self: *L2Cache) u32 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.table.count();
    }
};

/// Two-level relation cache. `lookup` first probes the lockless L1;
/// on miss it falls through to the locked L2 and (on hit) repopulates
/// L1 so the next hit on this worker is lockless. `put` writes to L1
/// always and to L2 every `L2_PROMOTION_STRIDE`-th insertion to keep
/// L2 warm for cross-worker sharing without thrashing the lock.
///
/// Single-Engine usage works transparently: there's one L1 and one
/// L2, and the promotion logic is harmless under sequential access.
pub const TwoLevelCache = struct {
    l1: L1Cache,
    l2: L2Cache,
    /// Counts L1 inserts; promotes to L2 when `% stride == 0`.
    promotion_counter: u32 = 0,
    promotion_stride: u32 = L2_PROMOTION_STRIDE,

    pub fn init(gpa: std.mem.Allocator) !TwoLevelCache {
        return .{
            .l1 = try L1Cache.init(gpa),
            .l2 = try L2Cache.init(gpa),
        };
    }

    pub fn deinit(self: *TwoLevelCache) void {
        self.l1.deinit();
        self.l2.deinit();
    }

    /// Probe L1, then L2. On L2 hit, repopulate L1 (lockless after
    /// this call) so subsequent lookups on this worker stay fast.
    pub fn lookup(self: *TwoLevelCache, rel: Relation, src: TypeId, tgt: TypeId) Result {
        const key = packKey(rel, src, tgt);
        const l1_hit = self.l1.lookup(key);
        if (l1_hit != .miss) return l1_hit;
        const l2_hit = self.l2.lookup(key);
        if (l2_hit != .miss) {
            // Best-effort L1 backfill; allocation failure is non-fatal.
            self.l1.insert(key, l2_hit) catch {};
            return l2_hit;
        }
        return .miss;
    }

    pub fn put(self: *TwoLevelCache, rel: Relation, src: TypeId, tgt: TypeId, r: Result) !void {
        const key = packKey(rel, src, tgt);
        try self.l1.insert(key, r);
        self.promotion_counter +%= 1;
        // Promote every Nth insert to L2. `pending` markers are
        // transient and would just be overwritten — skip them so L2
        // doesn't fill with mid-computation noise.
        if (r != .pending and self.promotion_counter % self.promotion_stride == 0) {
            try self.l2.insert(key, r);
        }
    }

    /// Total entries across L1 and L2. Used by tests and diagnostics.
    /// Note: L1 ⊂ L2 is *not* guaranteed (entries can be evicted from
    /// either independently), so this is an upper bound on uniques.
    pub fn count(self: *TwoLevelCache) u32 {
        return self.l1.count() + self.l2.count();
    }
};

/// Backwards-compatible alias. The old single-level `RelationCache`
/// is now a two-level cache transparently — single-Engine consumers
/// see no behavioural change beyond cache eviction at large sizes.
pub const RelationCache = TwoLevelCache;

/// Relation engine. Wraps the interner + cache and exposes the
/// `assignable`, `subtype`, `identity`, `comparable` queries.
pub const Engine = struct {
    gpa: std.mem.Allocator,
    interner: *Interner,
    cache: RelationCache,
    /// When true, function-type parameters are checked
    /// contravariantly (sound — matches `strictFunctionTypes`).
    /// When false (TS default for method declarations), parameters
    /// are checked bivariantly: source `(p: T) => R` assigns to
    /// target `(p: U) => R` iff `T` and `U` are mutually assignable.
    strict_function_types: bool = false,
    /// `strictNullChecks`. When false (tsc default), `null` and
    /// `undefined` are assignable to every target except `never`.
    strict_null_checks: bool = false,
    /// Optional string-interner reference. When set, structural
    /// assignability uses property-name bytes for special-case
    /// handling (e.g. resolving numeric "0", "1", … keys via the
    /// source's number-key indexer for tuple-vs-array comparisons).
    string_interner: ?*const string_interner.Interner = null,
    /// Optional rest-signatures set. When a signature TypeId is in
    /// this set, the relation engine treats its last parameter as a
    /// rest param. When that rest param's type is a tuple (or a
    /// tuple after substitution), the engine expands its element
    /// types into positional params before comparing, which lets
    /// `(...args: [number, string]) => R` accept `(a: number, b: string) => R`
    /// (and the converse, under variance rules). Set by the checker
    /// to a reference of `Checker.rest_signatures` so the engine sees
    /// real-time updates.
    rest_signatures: ?*const std.AutoHashMapUnmanaged(TypeId, void) = null,
    /// Current nesting depth of `computeAssignable`. Recursive generic
    /// aliases such as `type Foo<T> = T | { x: Foo<T> }` can produce a
    /// fresh `TypeId` at each instantiation level, so the
    /// pending-result cycle cache (keyed on `(rel, src, tgt)`) never
    /// fires and the structural walk could recurse without bound.
    /// Mirrors tsc's `sourceStack`/`targetStack == 100 ⇒ overflow`
    /// guard (relater.go `recursiveTypeRelatedTo`): once we exceed the
    /// limit we treat the in-flight comparison as related (optimistic,
    /// same as a detected cycle) rather than overflowing the stack.
    relate_depth: u32 = 0,
    relation_stack_depth_overflowed: bool = false,
    source_stack: std.ArrayListUnmanaged(TypeId) = .empty,
    target_stack: std.ArrayListUnmanaged(TypeId) = .empty,

    pub fn init(gpa: std.mem.Allocator, ti: *Interner) !Engine {
        return .{
            .gpa = gpa,
            .interner = ti,
            .cache = try RelationCache.init(gpa),
        };
    }

    pub fn setStrictFunctionTypes(self: *Engine, on: bool) void {
        self.strict_function_types = on;
    }

    pub fn setStrictNullChecks(self: *Engine, on: bool) void {
        self.strict_null_checks = on;
    }

    pub fn setStringInterner(self: *Engine, si: *const string_interner.Interner) void {
        self.string_interner = si;
    }

    pub fn setRestSignatures(self: *Engine, rs: *const std.AutoHashMapUnmanaged(TypeId, void)) void {
        self.rest_signatures = rs;
    }

    pub fn clearRelationStackDepthOverflow(self: *Engine) void {
        self.relation_stack_depth_overflowed = false;
    }

    pub fn consumeRelationStackDepthOverflow(self: *Engine) bool {
        const overflowed = self.relation_stack_depth_overflowed;
        self.relation_stack_depth_overflowed = false;
        return overflowed;
    }

    /// §4.A.X TS 4.0 — when `sig`'s last param is a tuple (or a
    /// tuple-shaped object type) and the signature is marked as a
    /// rest signature, return the expanded param list (positional
    /// fixed params + tuple element types). Returns `null` if no
    /// expansion applies.
    fn expandRestTupleParams(
        self: *Engine,
        sig: TypeId,
        params: []const TypeId,
        out: *std.ArrayListUnmanaged(TypeId),
    ) anyerror!bool {
        const rs = self.rest_signatures orelse return false;
        if (!rs.contains(sig)) return false;
        if (params.len == 0) return false;
        const rest_t = params[params.len - 1];
        if (rest_t >= self.pool().typeCount()) return false;
        if (!self.pool().flagsOf(rest_t).is_object_type) return false;
        // Detect tuple shape by walking members and finding `length`
        // (number-literal-typed) + positional `"0"`, `"1"`, … by
        // name-string comparison through the string interner.
        const si = self.string_interner orelse return false;
        const members = self.interner.objectMembers(rest_t);
        var elem_count: ?usize = null;
        for (members) |m| {
            const name = si.get(m.name);
            if (std.mem.eql(u8, name, "length")) {
                const f = self.pool().flagsOf(m.type);
                if (!f.is_literal or !f.is_number) return false;
                const lit = self.interner.literalOf(m.type);
                switch (lit) {
                    .number_lit => |bits| {
                        const fv: f64 = @bitCast(bits);
                        if (fv < 0 or fv != @floor(fv) or fv > 1024) return false;
                        elem_count = @intFromFloat(fv);
                    },
                    else => return false,
                }
                break;
            }
        }
        const n = elem_count orelse return false;
        try out.appendSlice(self.gpa, params[0 .. params.len - 1]);
        var nbuf: [12]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const want = std.fmt.bufPrint(&nbuf, "{d}", .{i}) catch return false;
            var found: ?TypeId = null;
            for (members) |m| {
                const name = si.get(m.name);
                if (std.mem.eql(u8, name, want)) {
                    found = m.type;
                    break;
                }
            }
            try out.append(self.gpa, found orelse return false);
        }
        return true;
    }

    fn restArrayElementParam(self: *Engine, sig: TypeId, params: []const TypeId, index: usize, param: TypeId) TypeId {
        const rs = self.rest_signatures orelse return param;
        if (!rs.contains(sig) or params.len == 0 or index + 1 != params.len) return param;
        if (param >= self.pool().typeCount()) return param;
        const elem = self.interner.objectNumberIndex(param);
        return if (elem != Primitive.none) elem else param;
    }

    const SignatureParamPosition = struct {
        ty: TypeId,
        physical_index: usize,
    };

    fn signatureParamAtComparePosition(
        self: *Engine,
        sig: TypeId,
        params: []const TypeId,
        index: usize,
        rest_tuple_expanded: bool,
    ) ?SignatureParamPosition {
        if (index < params.len) return .{ .ty = params[index], .physical_index = index };
        if (rest_tuple_expanded or params.len == 0) return null;
        const rs = self.rest_signatures orelse return null;
        if (!rs.contains(sig)) return null;
        return .{ .ty = params[params.len - 1], .physical_index = params.len - 1 };
    }

    fn typeContainsTypeParameter(self: *Engine, t: TypeId) bool {
        if (t >= self.pool().typeCount()) return false;
        const flags = self.pool().flagsOf(t);
        if (flags.is_type_parameter) return true;
        if (flags.is_union) {
            for (self.interner.unionMembers(t)) |member| if (self.typeContainsTypeParameter(member)) return true;
            return false;
        }
        if (flags.is_intersection) {
            for (self.interner.intersectionMembers(t)) |member| if (self.typeContainsTypeParameter(member)) return true;
            return false;
        }
        if (flags.is_object_type) {
            for (self.interner.objectMembers(t)) |member| if (self.typeContainsTypeParameter(member.type)) return true;
            const str_idx = self.interner.objectStringIndex(t);
            const num_idx = self.interner.objectNumberIndex(t);
            const sym_idx = self.interner.objectSymbolIndex(t);
            return (str_idx != Primitive.none and self.typeContainsTypeParameter(str_idx)) or
                (num_idx != Primitive.none and self.typeContainsTypeParameter(num_idx)) or
                (sym_idx != Primitive.none and self.typeContainsTypeParameter(sym_idx));
        }
        if (flags.is_signature) {
            for (self.interner.signatureParams(t)) |param| if (self.typeContainsTypeParameter(param)) return true;
            if (self.interner.signatureReturn(t)) |ret| return self.typeContainsTypeParameter(ret);
        }
        return false;
    }

    fn signatureParamAssignableTo(
        self: *Engine,
        source_param: TypeId,
        target_param: TypeId,
        reject_target_type_parameter: bool,
    ) anyerror!bool {
        if (source_param == target_param) return true;
        if (reject_target_type_parameter and
            target_param < self.pool().typeCount() and
            self.pool().flagsOf(target_param).is_type_parameter)
        {
            if (source_param < self.pool().typeCount() and self.pool().flagsOf(source_param).is_type_parameter) {
                return self.typeParameterConstraintReaches(source_param, target_param);
            }
            return false;
        }
        return self.isAssignableTo(source_param, target_param);
    }

    pub fn deinit(self: *Engine) void {
        self.cache.deinit();
        self.source_stack.deinit(self.gpa);
        self.target_stack.deinit(self.gpa);
    }

    fn pool(self: *const Engine) *const Pool {
        return &self.interner.pool;
    }

    /// True if `a` and `b` are structurally identical.
    pub fn isIdenticalTo(self: *Engine, a: TypeId, b: TypeId) anyerror!bool {
        if (a == b) return true; // interner identity short-circuit
        switch (self.cache.lookup(.identity, a, b)) {
            .yes => return true,
            .no => return false,
            .pending, .miss => {},
        }
        try self.cache.put(.identity, a, b, .pending);
        const result = try self.computeIdentity(a, b);
        try self.cache.put(.identity, a, b, if (result) .yes else .no);
        return result;
    }

    fn computeIdentity(self: *Engine, a: TypeId, b: TypeId) anyerror!bool {
        if (a == b) return true;
        const fa = self.pool().flagsOf(a);
        const fb = self.pool().flagsOf(b);
        // Different "kind" implies non-identical.
        const fa_bits: u32 = @bitCast(fa);
        const fb_bits: u32 = @bitCast(fb);
        if (fa_bits != fb_bits) return false;

        // Union: identity is "same set of members" — interner already
        // sorted, so just compare member slices.
        if (fa.is_union) {
            const am = self.interner.unionMembers(a);
            const bm = self.interner.unionMembers(b);
            return std.mem.eql(TypeId, am, bm);
        }
        if (fa.is_intersection) {
            const am = self.interner.intersectionMembers(a);
            const bm = self.interner.intersectionMembers(b);
            return std.mem.eql(TypeId, am, bm);
        }
        // Object types: structurally identical iff they have the
        // same members with the same names + types. Members are
        // stored in source declaration order (not sorted), so we
        // compare order-independently via name lookup.
        if (fa.is_object_type) {
            const am = self.interner.objectMembers(a);
            const bm = self.interner.objectMembers(b);
            if (am.len != bm.len) return false;
            for (am) |x| {
                var matched = false;
                for (bm) |y| {
                    if (x.name != y.name) continue;
                    if (x.is_optional != y.is_optional) return false;
                    if (x.is_readonly != y.is_readonly) return false;
                    if (!try self.isIdenticalTo(x.type, y.type)) return false;
                    matched = true;
                    break;
                }
                if (!matched) return false;
            }
            return true;
        }
        // Two literals with the same flags but different payloads
        // (e.g. `42` vs. `43`) — already filtered by interner identity
        // above (`a == b` check at function start), so reaching here
        // means they shared the interned id, contradicting `a != b`.
        return false;
    }

    /// True if `source` is assignable to `target`. Phase 3 implements
    /// the *fundamental* rules; conformance hardening lands in Phase 6.
    pub fn isAssignableTo(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        if (source == target) return true;

        // `any` is assignable to any type and any type is assignable
        // to `any` (per tsc; this is the source of most "TS doesn't
        // catch X" complaints, but it's what we have to match).
        if (source == Primitive.any or target == Primitive.any) return true;

        // `unknown` accepts anything.
        if (target == Primitive.unknown) return true;

        // `never` is assignable to everything (bottom type).
        if (source == Primitive.never) return true;

        // Anything assignable to `never` ⇒ source must be `never`.
        if (target == Primitive.never) return false;

        // `void` accepts undefined under some flag combos; Phase 3
        // matches the strict-mode rule: only `undefined` and `void`
        // assign to `void`.
        if (target == Primitive.void_t) {
            if (!self.strict_null_checks and (source == Primitive.null_t or source == Primitive.undefined_t)) return true;
            return source == Primitive.void_t or source == Primitive.undefined_t;
        }

        switch (self.cache.lookup(.assignable, source, target)) {
            .yes => return true,
            .no => return false,
            .pending => return true, // cycle: optimistic
            .miss => {},
        }
        // Overflow guard for recursive generic aliases whose
        // per-level instantiations intern to fresh ids (so the
        // pending-cache cycle check above never triggers). Treat an
        // over-deep comparison as related — the optimistic answer that
        // tsc's `recursiveTypeRelatedTo` overflow path effectively
        // produces for assignability — instead of overflowing the
        // native stack. The limit is generous so genuine (finite)
        // deep object graphs still get a real structural answer.
        if (self.relate_depth >= max_relate_depth) {
            self.relation_stack_depth_overflowed = true;
            return true;
        }
        if (self.isDeeplyNestedPair(source, target)) return true;

        try self.cache.put(.assignable, source, target, .pending);
        try self.source_stack.append(self.gpa, source);
        try self.target_stack.append(self.gpa, target);
        self.relate_depth += 1;
        const result = self.computeAssignable(source, target) catch |err| {
            self.relate_depth -= 1;
            _ = self.source_stack.pop();
            _ = self.target_stack.pop();
            return err;
        };
        self.relate_depth -= 1;
        _ = self.source_stack.pop();
        _ = self.target_stack.pop();
        try self.cache.put(.assignable, source, target, if (result) .yes else .no);
        return result;
    }

    fn isDeeplyNestedPair(self: *Engine, source: TypeId, target: TypeId) bool {
        return self.isDeeplyNestedType(source, self.source_stack.items, 3) and
            self.isDeeplyNestedType(target, self.target_stack.items, 3);
    }

    fn isDeeplyNestedType(self: *Engine, t: TypeId, stack: []const TypeId, max_depth: usize) bool {
        if (max_depth == 0) return true;
        if (stack.len + 1 < max_depth) return false;
        const identity = self.recursionIdentity(t) orelse return false;
        var count: usize = 1;
        for (stack) |entry| {
            if (!self.recursionIdentitiesMatch(entry, identity)) continue;
            count += 1;
            if (count >= max_depth) return true;
        }
        return false;
    }

    const RecursionIdentity = u32;

    fn recursionIdentity(self: *Engine, t: TypeId) ?RecursionIdentity {
        if (t < Primitive.first_dynamic or t >= self.pool().typeCount()) return null;
        const flags = self.pool().flagsOf(t);
        if (flags.is_union) {
            for (self.interner.unionMembers(t)) |member| {
                if (self.recursionIdentity(member)) |identity| return identity;
            }
            return null;
        }
        if (flags.is_intersection) {
            for (self.interner.intersectionMembers(t)) |member| {
                if (self.recursionIdentity(member)) |identity| return identity;
            }
            return null;
        }
        if (!flags.is_object_type) return null;
        const symbol = self.interner.typeSymbol(t);
        if (symbol != 0) return symbol;
        return null;
    }

    fn recursionIdentitiesMatch(self: *Engine, t: TypeId, identity: RecursionIdentity) bool {
        const other = self.recursionIdentity(t) orelse return false;
        return other == identity;
    }

    fn computeAssignable(self: *Engine, source: TypeId, target: TypeId) !bool {
        const sf = self.pool().flagsOf(source);
        const tf = self.pool().flagsOf(target);

        // Union on the source: every member must assign to target.
        if (sf.is_union) {
            const members = self.interner.unionMembers(source);
            const snapshot = try self.interner.gpa.dupe(TypeId, members);
            defer self.interner.gpa.free(snapshot);
            for (snapshot) |m| {
                if (!try self.isAssignableTo(m, target)) return false;
            }
            return true;
        }
        // Union on the target: source must assign to *some* member.
        if (tf.is_union) {
            if (source == Primitive.boolean_t and self.unionContainsBooleanLiterals(target)) return true;
            const members = self.interner.unionMembers(target);
            const snapshot = try self.interner.gpa.dupe(TypeId, members);
            defer self.interner.gpa.free(snapshot);
            for (snapshot) |m| {
                if (sf.is_type_parameter and
                    m < self.pool().typeCount() and
                    self.pool().flagsOf(m).is_type_parameter and
                    source != m and
                    !self.typeParameterConstraintReaches(source, m))
                {
                    continue;
                }
                if (try self.isAssignableTo(source, m)) return true;
            }
            // Discriminated-union fallback: if S is an object (or
            // intersection of objects) and T is a union with a common
            // discriminant property, S may still be related to T even
            // though no single constituent accepts S, provided that for
            // every combination of S's discriminant values there is a
            // matching constituent whose non-discriminant properties S
            // also satisfies. Mirrors tsc's `typeRelatedToDiscriminatedType`
            // (relater.go). Only the object/intersection source case
            // enters this path — primitives, type parameters, etc. fall
            // through to the plain rejection below.
            if (sf.is_object_type or sf.is_intersection) {
                if (try self.typeRelatedToDiscriminatedType(source, target)) return true;
            }
            return false;
        }

        // Weak-type / common-property rule (TS2559). When the target is
        // a weak type (all members optional, no signatures/index infos —
        // or an intersection of such) and the source object/intersection
        // shares no property name with it, the relation fails even though
        // the all-optional target would otherwise accept it vacuously.
        // Source and target unions are handled above, so by here neither
        // is a union. Mirrors tsc's `isPerformingCommonPropertyChecks`.
        // Numeric-enum nominal intersections (`number & { __enum:E }`) are
        // excluded via the `isWeakType` signature/property gates below.
        if ((sf.is_object_type or sf.is_intersection) and self.weakTypeNoCommonProperties(source, target)) {
            return false;
        }

        // A numeric enum-member literal is assignable to its *own*
        // enum's nominal type (`E1.X` → `E1`), but not to a foreign
        // enum's nominal (`E2.X` → `E1` fails). The whole-enum nominal
        // brands the owning enum name in its `__enum:` member, which we
        // match against the literal's recorded enum identity.
        if (tf.is_intersection and sf.is_enum_literal and self.isNumericEnumNominal(target)) {
            if (self.string_interner) |si| {
                if (self.interner.enumLiteralInfo(source)) |info| {
                    if (self.numericEnumNominalName(target)) |target_enum| {
                        const src_enum = si.getOptional(info.enum_name) orelse "";
                        // The whole-enum nominal brand is scope-qualified
                        // (`__enum:<scopeId>:E1`) while the enum-member
                        // literal records the bare enum name (`E1`).
                        // Compare the bare names (after the last `:`) so a
                        // member literal still matches its own enum's
                        // nominal. Mirrors `bestCommonTypeOfTuple.ts`.
                        if (std.mem.eql(u8, bareEnumName(target_enum), bareEnumName(src_enum))) return true;
                    }
                }
            }
            return false;
        }

        // Whole numeric enum nominals can carry either a bare brand
        // (`__enum:E`) or a scope-qualified brand (`__enum:<scope>:E`)
        // depending on whether the type came from widening an enum
        // member or from a declaration-scoped type reference. They
        // still denote the same enum for assignability purposes.
        if (sf.is_intersection and tf.is_intersection and
            self.isNumericEnumNominal(source) and self.isNumericEnumNominal(target))
        {
            if (self.numericEnumNominalName(source)) |source_enum| {
                if (self.numericEnumNominalName(target)) |target_enum| {
                    if (std.mem.eql(u8, bareEnumName(source_enum), bareEnumName(target_enum))) return true;
                }
            }
        }

        // Numeric enum types are represented as branded
        // intersections (`number & { __enum:E: never }`), while TS
        // still allows plain numbers to flow into numeric enum
        // variables for historical compatibility.
        if (tf.is_intersection and self.isNumericEnumNominal(target) and self.isNumberLikeForEnumAssign(source)) return true;

        // Intersection on the target: source must assign to *every*
        // member.
        if (tf.is_intersection) {
            const members = self.interner.intersectionMembers(target);
            const snapshot = try self.interner.gpa.dupe(TypeId, members);
            defer self.interner.gpa.free(snapshot);
            for (snapshot) |m| {
                if (!try self.isAssignableTo(source, m)) return false;
            }
            return true;
        }
        // Object intersections accumulate members from each constituent.
        // This matters for generic object spreads such as
        // `{ ...t, ...u, id: "id" }`, whose instantiated return type is
        // `T & U & { id: string }`.
        if (sf.is_intersection and tf.is_object_type) {
            return self.computeIntersectionObjectAssignable(source, target);
        }
        // Non-object intersection fallback: source assigns to target if
        // any constituent member does.
        if (sf.is_intersection) {
            const members = self.interner.intersectionMembers(source);
            const snapshot = try self.interner.gpa.dupe(TypeId, members);
            defer self.interner.gpa.free(snapshot);
            for (snapshot) |m| {
                if (try self.isAssignableTo(m, target)) return true;
            }
            return false;
        }

        // Enum-member literals (`Choice.Yes`). Mirrors tsc's relater
        // rules (`isRelatedToWorker`):
        //   * identical enum literals collapse to one `TypeId`, so the
        //     `source == target` short-circuit at the top already
        //     accepts member↔same-member.
        //   * an enum literal IS assignable to its base primitive
        //     (`number`/`string`) — handled by the literal-reduction
        //     block below since enum literals carry `is_number`/`is_string`.
        //   * a *bare* literal (non-enum) IS assignable to an enum-literal
        //     target with a matching value (so `0`/`"UP"` flow into a
        //     `Choice.Yes` slot), but broad `number`, a *different* enum
        //     literal, or a value mismatch is rejected.
        //   * an enum literal is assignable to a bare literal target with
        //     the same value (tsc 222/228).
        if (tf.is_enum_literal) {
            // Target is an enum literal. Already handled `source == target`.
            if (sf.is_enum_literal) {
                // Different enum literal: accept only when the owning
                // enum matches *and* values match (covers merged-enum /
                // re-interned cases that didn't unify to one id).
                return self.enumLiteralsRelated(source, target);
            }
            // Bare literal source into an enum-literal target: tsc accepts
            // a literal whose value matches, but not broad `number`.
            if (sf.is_literal and self.literalValuesEqual(source, target)) return true;
            return false;
        }
        if (sf.is_enum_literal and tf.is_literal and !tf.is_enum_literal) {
            // Enum literal into a bare literal target: same value only.
            return self.literalValuesEqual(source, target);
        }

        // Literal types reduce to their primitive when target is the
        // primitive. `42` is assignable to `number`, but `number` is
        // *not* assignable to `42`.
        if (sf.is_literal) {
            if (sf.is_string and target == Primitive.string_t) return true;
            if (sf.is_number and target == Primitive.number_t) return true;
            if (sf.is_bigint and target == Primitive.bigint_t) return true;
            if (sf.is_boolean and target == Primitive.boolean_t) return true;
        }
        if ((sf.is_template_literal or sf.is_string_mapping) and target == Primitive.string_t) return true;
        if (tf.is_template_literal or tf.is_string_mapping) return false;

        // `null` and `undefined` assign to themselves only under
        // `strictNullChecks`. Without it, tsc treats both as
        // assignable to every target except `never` (handled above).
        if (source == Primitive.null_t or source == Primitive.undefined_t) {
            return !self.strict_null_checks;
        }

        // Target type parameters stand for inference slots in many
        // contextual generic comparisons. The checker records the
        // actual substitution elsewhere; relation only needs to avoid
        // rejecting the candidate at the slot boundary.
        if (tf.is_type_parameter) return true;

        // Non-strict mode keeps TS's historical permissiveness for
        // unconstrained generics flowing into all-optional object
        // shapes. Under strict/null-aware checking, upstream
        // conformance expects `T` to be rejected without an explicit
        // constraint.
        if (!self.strict_null_checks and sf.is_type_parameter and tf.is_object_type) {
            if (self.interner.objectStringIndex(target) != Primitive.none) return false;
            if (self.interner.objectNumberIndex(target) != Primitive.none) return false;
            for (self.interner.objectMembers(target)) |tm| {
                if (!tm.is_optional) return false;
            }
            return true;
        }

        // Lowercase `object` accepts non-primitive object-like values
        // while still rejecting primitive values such as `string` and
        // `number`. A bare type parameter is accepted only when its
        // constraint is itself assignable to `object` (e.g.
        // `T extends object`, `T extends {a:number}`); an unconstrained
        // `T` is rejected — upstream conformance flags
        // `let o: object = t` as TS2322 with a related "might need
        // `extends object` constraint" note (see nonPrimitiveInGeneric
        // / nonPrimitiveAndTypeVariables).
        if (target == Primitive.object_t) {
            if (sf.is_type_parameter) {
                const constraint = self.typeParameterConstraint(source) orelse return false;
                if (constraint == Primitive.object_t) return true;
                if (constraint == source) return false;
                return self.isAssignableTo(constraint, Primitive.object_t) catch false;
            }
            return sf.is_object or
                sf.is_object_type or
                sf.is_signature or
                sf.is_tuple or
                sf.is_intersection;
        }

        // The empty object type (`{}` / uppercase `Object` in our
        // current lib approximation) accepts every non-nullish value,
        // including primitives. Lowercase `object` remains the
        // primitive `object_t` sentinel and is intentionally stricter.
        if (tf.is_object_type and
            self.interner.objectMembers(target).len == 0 and
            self.interner.objectStringIndex(target) == Primitive.none and
            self.interner.objectNumberIndex(target) == Primitive.none and
            self.interner.objectSymbolIndex(target) == Primitive.none)
        {
            if (sf.is_type_parameter) {
                const constraint = self.typeParameterConstraint(source) orelse return false;
                if (constraint == source) return false;
                return self.isAssignableTo(constraint, target) catch false;
            }
            return source != Primitive.null_t and
                source != Primitive.undefined_t and
                source != Primitive.void_t and
                source != Primitive.unknown;
        }

        if (tf.is_object_type and self.primitiveApparentAssignableToObject(source, target)) return true;

        // Object types: structural subtyping. Source must have all
        // properties target requires, and each shared property type
        // must be assignable in the same direction (depth-checked).
        if (sf.is_signature and tf.is_object_type) {
            return self.computeSignatureAssignableToCallableObject(source, target);
        }
        if (sf.is_object_type and tf.is_signature) {
            return self.computeCallableObjectAssignableToSignature(source, target);
        }
        if (sf.is_object_type and tf.is_object_type) {
            return self.computeObjectAssignable(source, target);
        }

        // Signatures: contravariant parameters, covariant return.
        if (sf.is_signature and tf.is_signature) {
            return self.computeSignatureAssignable(source, target);
        }

        // Source type-parameter against a non-type-parameter target:
        // a type parameter is assignable to `T` when its constraint is
        // assignable to `T` (tsc's `getConstraintOfType` on the source).
        // This is the polymorphic-`this` case — inside `class A2`, the
        // `this` type is a type parameter constrained to `A2`, so
        // `let a: A2 = this;` must NOT report TS2322. The earlier
        // `tf.is_type_parameter => return true` short-circuit handles a
        // type-parameter *target*; this handles a type-parameter *source*
        // flowing into the concrete class/object it is constrained to.
        // Guarded to a non-self constraint so unconstrained `T` (whose
        // constraint resolves to `unknown`/none) still fails against a
        // concrete target.
        if (sf.is_type_parameter and !tf.is_type_parameter) {
            if (self.typeParameterConstraint(source)) |constraint| {
                if (constraint != source and constraint != target) {
                    return self.isAssignableTo(constraint, target) catch false;
                }
                if (constraint == target) return true;
            }
        }

        // Primitive-vs-primitive: only identity matches at this layer.
        return false;
    }

    fn isNumberLikeForEnumAssign(self: *Engine, source: TypeId) bool {
        if (source == Primitive.number_t) return true;
        const sf = self.pool().flagsOf(source);
        // A bare numeric literal flows into a numeric enum for the
        // historical bit-flag rule, but an *enum* literal must not —
        // `E2.X` is not assignable to `E1` just because both are
        // number-backed. Foreign enum literals are routed through the
        // strict enum-relatedness check instead. Mirrors tsc's
        // `s&TypeFlagsEnumLiteral == 0` guard on the number-literal rule.
        if (sf.is_enum_literal) return false;
        if (sf.is_literal and sf.is_number) return true;
        return false;
    }

    /// Compare the underlying literal values of two literal types,
    /// ignoring any enum branding. Used so a bare `0` and `Choice.Yes`
    /// (value 0), or a `Choice.Yes`/`Choice.No` swap, relate strictly
    /// by value. Both ids must be literal types.
    fn literalValuesEqual(self: *Engine, a: TypeId, b: TypeId) bool {
        const af = self.pool().flagsOf(a);
        const bf = self.pool().flagsOf(b);
        if (!af.is_literal or !bf.is_literal) return false;
        const la = self.interner.literalOf(a);
        const lb = self.interner.literalOf(b);
        if (@as(types.LiteralTag, la) != @as(types.LiteralTag, lb)) return false;
        return switch (la) {
            .string_lit => |sid| sid == lb.string_lit,
            .number_lit => |bits| bits == lb.number_lit,
            .bigint_lit => |sid| sid == lb.bigint_lit,
            .boolean_lit => |v| v == lb.boolean_lit,
        };
    }

    /// Two distinct enum-literal types relate only when they name the
    /// same owning enum and carry the same value — i.e. they are the
    /// same member that, for some reason (merged decls, re-intern), did
    /// not collapse to a single `TypeId`. A member of one enum is never
    /// assignable to a member of another, nor to a sibling member.
    /// Mirrors tsc's `isEnumTypeRelatedTo` + value check (relater 247).
    fn enumLiteralsRelated(self: *Engine, source: TypeId, target: TypeId) bool {
        const si = self.interner.enumLiteralInfo(source) orelse return false;
        const ti_info = self.interner.enumLiteralInfo(target) orelse return false;
        if (si.enum_name != ti_info.enum_name) return false;
        return self.literalValuesEqual(source, target);
    }

    fn isNumericEnumNominal(self: *Engine, t: TypeId) bool {
        const si = self.string_interner orelse return false;
        if (t >= self.pool().typeCount()) return false;
        const flags = self.pool().flagsOf(t);
        if (!flags.is_intersection) return false;
        var saw_number = false;
        var saw_enum_brand = false;
        for (self.interner.intersectionMembers(t)) |member| {
            if (member == Primitive.number_t) {
                saw_number = true;
                continue;
            }
            if (member >= self.pool().typeCount()) continue;
            const mf = self.pool().flagsOf(member);
            if (!mf.is_object_type) continue;
            for (self.interner.objectMembers(member)) |om| {
                const name = si.getOptional(om.name) orelse continue;
                if (std.mem.startsWith(u8, name, "__enum:")) {
                    saw_enum_brand = true;
                    break;
                }
            }
        }
        return saw_number and saw_enum_brand;
    }

    /// Extract the owning enum's name (as a string slice) from a
    /// numeric enum nominal intersection's `__enum:NAME` brand member,
    /// or null when `t` is not such a nominal. Used to match an
    /// enum-member literal against its own enum's nominal type.
    /// The bare enum name, stripping any `<scopeId>:` qualifier prefix
    /// that the nominal brand carries but the member-literal record does
    /// not (`26:E1` -> `E1`, `E1` -> `E1`).
    fn bareEnumName(name: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, name, ':')) |idx| return name[idx + 1 ..];
        return name;
    }

    fn numericEnumNominalName(self: *Engine, t: TypeId) ?[]const u8 {
        const si = self.string_interner orelse return null;
        if (t >= self.pool().typeCount()) return null;
        if (!self.pool().flagsOf(t).is_intersection) return null;
        for (self.interner.intersectionMembers(t)) |member| {
            if (member >= self.pool().typeCount()) continue;
            if (!self.pool().flagsOf(member).is_object_type) continue;
            for (self.interner.objectMembers(member)) |om| {
                const name = si.getOptional(om.name) orelse continue;
                if (std.mem.startsWith(u8, name, "__enum:")) {
                    return name["__enum:".len..];
                }
            }
        }
        return null;
    }

    /// Mirrors tsc's `isWeakType`: an object type is "weak" when it has
    /// at least one property, every property is optional, and it has no
    /// index/call/construct signatures. An intersection is weak when
    /// every constituent is itself weak. Weak targets feed the
    /// common-property check that surfaces TS2559 — see
    /// `weakTypeNoCommonProperties` and the upstream relater's
    /// `isPerformingCommonPropertyChecks` block.
    pub fn isWeakType(self: *Engine, t: TypeId) bool {
        if (t < Primitive.first_dynamic or t >= self.pool().typeCount()) return false;
        const flags = self.pool().flagsOf(t);
        if (flags.is_intersection) {
            const members = self.interner.intersectionMembers(t);
            if (members.len == 0) return false;
            for (members) |m| {
                if (!self.isWeakType(m)) return false;
            }
            return true;
        }
        if (!flags.is_object_type) return false;
        if (self.interner.objectStringIndex(t) != Primitive.none) return false;
        if (self.interner.objectNumberIndex(t) != Primitive.none) return false;
        if (self.interner.objectSymbolIndex(t) != Primitive.none) return false;
        const members = self.interner.objectMembers(t);
        if (members.len == 0) return false;
        for (members) |m| {
            if (self.isCallOrConstructMember(m.name)) return false;
            if (!m.is_optional) return false;
        }
        return true;
    }

    /// True when a member's name is a synthetic call (`__call`) or
    /// construct (`__construct`) signature slot. Compares by the
    /// interned bytes so it works against the read-only interner.
    fn isCallOrConstructMember(self: *Engine, name: types.StringId) bool {
        const si = self.string_interner orelse return false;
        const bytes = si.getOptional(name) orelse return false;
        return std.mem.eql(u8, bytes, "__call") or std.mem.eql(u8, bytes, "__construct");
    }

    /// True if `t` (object or intersection of objects) declares a named
    /// property `name` in any constituent. Used to detect common
    /// properties between a source and a weak target.
    fn objectOrIntersectionHasMemberNamed(self: *Engine, t: TypeId, name: types.StringId) bool {
        if (t < Primitive.first_dynamic or t >= self.pool().typeCount()) return false;
        const flags = self.pool().flagsOf(t);
        if (flags.is_intersection) {
            for (self.interner.intersectionMembers(t)) |m| {
                if (self.objectOrIntersectionHasMemberNamed(m, name)) return true;
            }
            return false;
        }
        if (!flags.is_object_type) return false;
        for (self.interner.objectMembers(t)) |m| {
            if (m.name == name) return true;
        }
        return false;
    }

    /// Counts the source's named properties and how many of them appear
    /// in `target`. Mirrors tsc's `hasCommonProperties`: the weak-type
    /// error fires only when the source has at least one property and
    /// none of them appear anywhere in the (weak) target.
    fn collectSourcePropertyOverlap(
        self: *Engine,
        source: TypeId,
        target: TypeId,
        had_props: *bool,
        had_common: *bool,
    ) void {
        if (source < Primitive.first_dynamic or source >= self.pool().typeCount()) return;
        const flags = self.pool().flagsOf(source);
        if (flags.is_intersection) {
            for (self.interner.intersectionMembers(source)) |m| {
                self.collectSourcePropertyOverlap(m, target, had_props, had_common);
            }
            return;
        }
        if (!flags.is_object_type) return;
        for (self.interner.objectMembers(source)) |m| {
            // Skip synthetic call/construct members — they are not
            // "common properties" in tsc's name-overlap sense.
            if (self.isCallOrConstructMember(m.name)) continue;
            had_props.* = true;
            if (self.objectOrIntersectionHasMemberNamed(target, m.name)) had_common.* = true;
        }
    }

    fn sourceHasCallOrConstructSignature(self: *Engine, source: TypeId) bool {
        if (source < Primitive.first_dynamic or source >= self.pool().typeCount()) return false;
        const flags = self.pool().flagsOf(source);
        if (flags.is_signature) return true;
        if (flags.is_intersection) {
            for (self.interner.intersectionMembers(source)) |member| {
                if (self.sourceHasCallOrConstructSignature(member)) return true;
            }
            return false;
        }
        if (!flags.is_object_type) return false;
        for (self.interner.objectMembers(source)) |member| {
            if (self.isCallOrConstructMember(member.name) and self.interner.isSignature(member.type)) return true;
        }
        return false;
    }

    /// tsc's weak-type / common-property rule (TS2559): when the target
    /// is a weak type and the source (an object/intersection with at
    /// least one property or a call/construct signature) shares NO
    /// property name with it, the relation fails. This is checked
    /// independently of the structural relation — an all-optional
    /// target would otherwise accept the source vacuously. See relater.go's
    /// `isPerformingCommonPropertyChecks`/`hasCommonProperties`.
    pub fn weakTypeNoCommonProperties(self: *Engine, source: TypeId, target: TypeId) bool {
        if (source < Primitive.first_dynamic or source >= self.pool().typeCount()) return false;
        if (target < Primitive.first_dynamic or target >= self.pool().typeCount()) return false;
        const sf = self.pool().flagsOf(source);
        // Object/intersection sources qualify when they carry
        // properties, and callable/constructable signature sources
        // qualify through the same common-property check.
        if (!sf.is_object_type and !sf.is_intersection and !sf.is_signature) return false;
        if (!self.isWeakType(target)) return false;
        var had_props = false;
        var had_common = false;
        self.collectSourcePropertyOverlap(source, target, &had_props, &had_common);
        const had_signature = self.sourceHasCallOrConstructSignature(source);
        return (had_props or had_signature) and !had_common;
    }

    fn primitiveApparentAssignableToObject(self: *Engine, source: TypeId, target: TypeId) bool {
        if (self.interner.objectStringIndex(target) != Primitive.none) return false;
        if (self.interner.objectNumberIndex(target) != Primitive.none) return false;
        if (self.interner.objectSymbolIndex(target) != Primitive.none) return false;
        const sf = self.pool().flagsOf(source);
        const is_string = source == Primitive.string_t or
            (sf.is_literal and sf.is_string) or
            sf.is_template_literal or
            sf.is_string_mapping;
        const is_number = source == Primitive.number_t or (sf.is_literal and sf.is_number);
        // `boolean`, `true`, and `false` are all boxable into `Boolean`,
        // so the apparent-type check must accept them too. The `Boolean`
        // lib shape only exposes the universal `toString`/`valueOf`,
        // both of which are whitelisted regardless of source — but the
        // gate above rejects non-string/number sources outright, so add
        // boolean to the accept list. Pins `validBooleanAssignments.ts(6,5)`.
        const is_boolean = source == Primitive.boolean_t or
            source == Primitive.true_lit or
            source == Primitive.false_lit;
        // `symbol` boxes into the `Symbol` interface (apparent type). The
        // `Symbol` shape's required members are only the universal
        // `toString`/`valueOf` (`description` is optional), so the member
        // loop below accepts it. Pins `symbolType15` (`var x: Symbol = sym`).
        const is_symbol = source == Primitive.symbol_t;
        if (!is_string and !is_number and !is_boolean and !is_symbol) return false;
        for (self.interner.objectMembers(target)) |member| {
            if (member.is_optional) continue;
            if (!self.primitiveApparentHasMember(member.name, is_string, is_number)) return false;
        }
        return true;
    }

    fn primitiveApparentHasMember(self: *Engine, name_id: string_interner.StringId, is_string: bool, is_number: bool) bool {
        const si = self.string_interner orelse return false;
        const name = si.getOptional(name_id) orelse return false;
        if (std.mem.eql(u8, name, "toString") or
            std.mem.eql(u8, name, "valueOf") or
            std.mem.eql(u8, name, "hasOwnProperty") or
            std.mem.eql(u8, name, "propertyIsEnumerable"))
        {
            return true;
        }
        if (is_string and (std.mem.eql(u8, name, "length") or
            std.mem.eql(u8, name, "charAt") or
            std.mem.eql(u8, name, "charCodeAt") or
            std.mem.eql(u8, name, "toUpperCase") or
            std.mem.eql(u8, name, "toLowerCase") or
            std.mem.eql(u8, name, "toLocaleUpperCase") or
            std.mem.eql(u8, name, "toLocaleLowerCase") or
            std.mem.eql(u8, name, "startsWith") or
            std.mem.eql(u8, name, "endsWith") or
            std.mem.eql(u8, name, "includes") or
            std.mem.eql(u8, name, "split") or
            std.mem.eql(u8, name, "indexOf") or
            std.mem.eql(u8, name, "slice") or
            std.mem.eql(u8, name, "substring") or
            std.mem.eql(u8, name, "trim") or
            std.mem.eql(u8, name, "concat") or
            std.mem.eql(u8, name, "repeat") or
            // Members added to `lib.stringProto`. The wrapper `String`
            // type reuses the same proto object, so any string member we
            // expose must be acknowledged here or `var x: String = s`
            // wrongly trips TS2322. Keep in sync with `lib.zig:stringProto`.
            std.mem.eql(u8, name, "replace") or
            std.mem.eql(u8, name, "replaceAll") or
            std.mem.eql(u8, name, "match") or
            std.mem.eql(u8, name, "matchAll") or
            std.mem.eql(u8, name, "search") or
            std.mem.eql(u8, name, "padStart") or
            std.mem.eql(u8, name, "padEnd") or
            std.mem.eql(u8, name, "trimStart") or
            std.mem.eql(u8, name, "trimEnd") or
            std.mem.eql(u8, name, "at") or
            std.mem.eql(u8, name, "codePointAt") or
            std.mem.eql(u8, name, "normalize") or
            std.mem.eql(u8, name, "localeCompare") or
            std.mem.eql(u8, name, "lastIndexOf") or
            std.mem.eql(u8, name, "substr")))
        {
            return true;
        }
        if (is_number and (std.mem.eql(u8, name, "toFixed") or
            std.mem.eql(u8, name, "toExponential") or
            std.mem.eql(u8, name, "toPrecision")))
        {
            return true;
        }
        return false;
    }

    fn unionContainsBooleanLiterals(self: *const Engine, t: TypeId) bool {
        if (t >= self.interner.pool.typeCount()) return false;
        if (!self.interner.pool.flagsOf(t).is_union) return false;
        var saw_true = false;
        var saw_false = false;
        for (self.interner.unionMembers(t)) |member| {
            if (member == Primitive.true_lit) saw_true = true;
            if (member == Primitive.false_lit) saw_false = true;
        }
        return saw_true and saw_false;
    }

    /// Positional type-parameter rewrite entry: `from` (a target
    /// type-parameter id) is treated as `to` (the source's tp at the
    /// matching position) for the remainder of a signature comparison.
    const TpPair = struct { from: TypeId, to: TypeId };

    /// Apply a tiny positional tp-map at the surface level. The map
    /// is short (one entry per generic position) so a linear scan is
    /// the right shape; a hash map would be overkill. Only the head
    /// type id is rewritten — deep substitution lands when generic
    /// instantiation does (Phase 6).
    fn substituteTp(t: TypeId, map: []const TpPair) TypeId {
        for (map) |pair| {
            if (pair.from == t) return pair.to;
        }
        return t;
    }

    fn substituteTpDeep(self: *Engine, t: TypeId, map: []const TpPair) anyerror!TypeId {
        return self.substituteTpDeepLimit(t, map, 0);
    }

    fn substituteTpDeepLimit(self: *Engine, t: TypeId, map: []const TpPair, depth: u8) anyerror!TypeId {
        if (depth > 64) return t;
        if (mappedTp(t, map)) |replacement| {
            if (replacement == t) return replacement;
            return self.substituteTpDeepLimit(replacement, map, depth + 1);
        }
        if (t < Primitive.first_dynamic or t >= self.interner.pool.typeCount()) return t;
        const flags = self.interner.pool.flagsOf(t);
        const payload_idx = self.interner.pool.payloadOf(t);
        if (flags.is_union) {
            if (payload_idx >= self.interner.pool.union_payloads.items.len) return t;
            const source_members = self.interner.unionMembers(t);
            const snapshot = try self.interner.gpa.dupe(TypeId, source_members);
            defer self.interner.gpa.free(snapshot);
            var members: std.ArrayListUnmanaged(TypeId) = .empty;
            defer members.deinit(self.interner.gpa);
            for (snapshot) |m| {
                const subbed = try self.substituteTpDeepLimit(m, map, depth + 1);
                try members.append(self.interner.gpa, if (subbed < self.interner.pool.typeCount()) subbed else Primitive.unknown);
            }
            return self.interner.internUnion(members.items) catch t;
        }
        if (flags.is_intersection) {
            if (payload_idx >= self.interner.pool.intersection_payloads.items.len) return t;
            const source_members = self.interner.intersectionMembers(t);
            const snapshot = try self.interner.gpa.dupe(TypeId, source_members);
            defer self.interner.gpa.free(snapshot);
            var members: std.ArrayListUnmanaged(TypeId) = .empty;
            defer members.deinit(self.interner.gpa);
            for (snapshot) |m| {
                const subbed = try self.substituteTpDeepLimit(m, map, depth + 1);
                try members.append(self.interner.gpa, if (subbed < self.interner.pool.typeCount()) subbed else Primitive.unknown);
            }
            return self.interner.internIntersection(members.items) catch t;
        }
        if (flags.is_template_literal) {
            if (payload_idx >= self.interner.pool.template_literal_payloads.items.len) return t;
            const texts = self.interner.templateLiteralTexts(t);
            const source_parts = self.interner.templateLiteralTypes(t);
            const snapshot = try self.interner.gpa.dupe(TypeId, source_parts);
            defer self.interner.gpa.free(snapshot);
            var parts: std.ArrayListUnmanaged(TypeId) = .empty;
            defer parts.deinit(self.interner.gpa);
            var changed = false;
            for (snapshot) |part| {
                const subbed = self.validOrUnknown(try self.substituteTpDeepLimit(part, map, depth + 1));
                if (subbed != part) changed = true;
                try parts.append(self.interner.gpa, subbed);
            }
            if (!changed) return t;
            return self.interner.internTemplateLiteral(texts, parts.items) catch t;
        }
        if (flags.is_object_type) {
            if (payload_idx >= self.interner.pool.object_type_payloads.items.len) return t;
            const source_members = self.interner.objectMembers(t);
            const snapshot = try self.interner.gpa.dupe(types.ObjectMember, source_members);
            defer self.interner.gpa.free(snapshot);
            var members: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
            defer members.deinit(self.interner.gpa);
            for (snapshot) |m| {
                const member_t = try self.substituteTpDeepLimit(m.type, map, depth + 1);
                try members.append(self.interner.gpa, .{
                    .name = m.name,
                    .type = self.validOrUnknown(member_t),
                    .is_optional = m.is_optional,
                    .is_readonly = m.is_readonly,
                    .is_method = m.is_method,
                });
            }
            const str_idx = self.interner.objectStringIndex(t);
            const num_idx = self.interner.objectNumberIndex(t);
            const sym_idx = self.interner.objectSymbolIndex(t);
            const new_str = if (str_idx != Primitive.none) self.validOrUnknown(try self.substituteTpDeepLimit(str_idx, map, depth + 1)) else Primitive.none;
            const new_num = if (num_idx != Primitive.none) self.validOrUnknown(try self.substituteTpDeepLimit(num_idx, map, depth + 1)) else Primitive.none;
            const new_sym = if (sym_idx != Primitive.none) self.validOrUnknown(try self.substituteTpDeepLimit(sym_idx, map, depth + 1)) else Primitive.none;
            if (new_str == Primitive.none and new_num == Primitive.none and new_sym == Primitive.none) {
                return self.interner.internObjectType(members.items) catch t;
            }
            return self.interner.internObjectTypeWithIndexAndSymbol(members.items, new_str, new_num, new_sym) catch t;
        }
        if (flags.is_signature) {
            if (payload_idx >= self.interner.pool.signature_payloads.items.len) return t;
            const sig_payload = self.interner.pool.signature_payloads.items[payload_idx];
            const source_params = self.interner.signatureParams(t);
            const snapshot = try self.interner.gpa.dupe(TypeId, source_params);
            defer self.interner.gpa.free(snapshot);
            var params: std.ArrayListUnmanaged(TypeId) = .empty;
            defer params.deinit(self.interner.gpa);
            for (snapshot) |p| {
                try params.append(self.interner.gpa, self.validOrUnknown(try self.substituteTpDeepLimit(p, map, depth + 1)));
            }
            const ret = if (self.interner.signatureReturn(t)) |r|
                self.validOrUnknown(try self.substituteTpDeepLimit(r, map, depth + 1))
            else
                Primitive.void_t;
            return self.interner.internSignatureWithAbstract(
                params.items,
                ret,
                sig_payload.is_construct,
                sig_payload.is_abstract_construct,
            ) catch t;
        }
        return t;
    }

    fn validOrUnknown(self: *Engine, t: TypeId) TypeId {
        return if (t < self.interner.pool.typeCount()) t else Primitive.unknown;
    }

    fn typeParameterConstraint(self: *Engine, t: TypeId) ?TypeId {
        if (t >= self.interner.pool.typeCount()) return null;
        if (!self.pool().flagsOf(t).is_type_parameter) return null;
        const payload_idx = self.pool().payloadOf(t);
        if (payload_idx >= self.interner.pool.type_parameter_payloads.items.len) return null;
        const tp = self.interner.pool.type_parameter_payloads.items[payload_idx];
        if (tp.constraint == Primitive.none or tp.constraint == Primitive.unknown) return null;
        return tp.constraint;
    }

    fn typeParameterConstraintReaches(self: *Engine, source: TypeId, target: TypeId) bool {
        var cur = source;
        var hops: u32 = 0;
        while (hops < 16) : (hops += 1) {
            const constraint = self.typeParameterConstraint(cur) orelse return false;
            if (constraint == target) return true;
            if (constraint == cur) return false;
            if (constraint >= self.pool().typeCount()) return false;
            if (!self.pool().flagsOf(constraint).is_type_parameter) return false;
            cur = constraint;
        }
        return false;
    }

    fn mappedTp(t: TypeId, map: []const TpPair) ?TypeId {
        for (map) |pair| {
            if (pair.from == t) return pair.to;
        }
        return null;
    }

    /// Function-signature assignability:
    ///
    ///   source: (P1', P2') => R'
    ///   target: (P1, P2) => R
    ///
    /// Source assigns to target iff:
    ///   * source has at most as many params as target (extras on
    ///     source would mean it expects more than callers supply),
    ///   * each `target.params[i]` is assignable to `source.params[i]`
    ///     (CONTRAVARIANT — caller passes in the target's input type),
    ///   * source return is assignable to target return (COVARIANT).
    ///
    /// `any` on either side flows in both directions per tsc.
    ///
    /// Generic identity: when both `source.params[i]` and
    /// `target.params[i]` are type-parameter types, we treat them as
    /// the *same* type-parameter for the rest of the comparison —
    /// `<T>(x: T) => T` is structurally identical to `<U>(x: U) => U`.
    /// This is a minimal positional unification: each target tp is
    /// mapped to the source tp at the matching position, and that
    /// substitution is honoured when comparing the return types.
    fn computeSignatureAssignable(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        return self.computeSignatureAssignableWithMode(source, target, false, false);
    }

    fn computeSignatureAssignableWithMode(
        self: *Engine,
        source: TypeId,
        target: TypeId,
        force_strict_params: bool,
        force_bivariant_params: bool,
    ) anyerror!bool {
        const source_payload = self.interner.pool.signature_payloads.items[self.interner.pool.payloadOf(source)];
        const target_payload = self.interner.pool.signature_payloads.items[self.interner.pool.payloadOf(target)];
        if (source_payload.is_construct and target_payload.is_construct and
            source_payload.is_abstract_construct and !target_payload.is_abstract_construct)
        {
            return false;
        }

        const sp_raw = try self.gpa.dupe(TypeId, self.interner.signatureParams(source));
        defer self.gpa.free(sp_raw);
        const tp_raw = try self.gpa.dupe(TypeId, self.interner.signatureParams(target));
        defer self.gpa.free(tp_raw);
        // §4.A.X TS 4.0 — when either signature is a rest signature
        // whose rest type is a known tuple, expand the tuple into
        // positional params so a variadic `(...args: [number, string]) => R`
        // matches a regular `(a: number, b: string) => R` (and vice
        // versa, under variance rules).
        var sp_expanded: std.ArrayListUnmanaged(TypeId) = .empty;
        defer sp_expanded.deinit(self.gpa);
        var tp_expanded: std.ArrayListUnmanaged(TypeId) = .empty;
        defer tp_expanded.deinit(self.gpa);
        const source_rest_tuple_expanded = try self.expandRestTupleParams(source, sp_raw, &sp_expanded);
        const target_rest_tuple_expanded = try self.expandRestTupleParams(target, tp_raw, &tp_expanded);
        const sp: []const TypeId = if (source_rest_tuple_expanded) sp_expanded.items else sp_raw;
        const tp: []const TypeId = if (target_rest_tuple_expanded) tp_expanded.items else tp_raw;
        var source_required: usize = sp.len;
        // A trailing rest parameter (`...args: T[]`) accepts zero
        // arguments, so it never contributes to the source's minimum
        // arity. Drop it before counting trailing optional/undefined-y
        // params — otherwise a variadic source like `(...args: any[]) =>
        // R` (the synthetic call signature of the global `Function`
        // type) would spuriously require one argument and fail against a
        // zero-parameter target like `() => void`. The tuple-rest path
        // already expands its params positionally, so only the
        // unexpanded array-rest case needs this adjustment.
        if (!source_rest_tuple_expanded and source_required > 0 and
            self.rest_signatures != null and self.rest_signatures.?.contains(source))
        {
            source_required -= 1;
        }
        while (source_required > 0) {
            if (!self.typeIncludesUndefined(sp[source_required - 1]) and
                sp[source_required - 1] != Primitive.void_t) break;
            source_required -= 1;
        }
        if (source_required > tp.len) return false;

        // Positional type-parameter map: target tp -> source tp at the
        // same param position. Stack-bounded to keep the hot path
        // allocation-free for typical signature arities.
        var tp_map_buf: [16]TpPair = undefined;
        var tp_map_len: usize = 0;
        var source_context_buf: [16]TpPair = undefined;
        var source_context_len: usize = 0;
        const reject_target_type_parameter = self.typeContainsTypeParameter(source) and
            self.typeContainsTypeParameter(target);

        const compare_len = @max(sp.len, tp.len);
        var i: usize = 0;
        while (i < compare_len) : (i += 1) {
            const s_pos = self.signatureParamAtComparePosition(source, sp, i, source_rest_tuple_expanded) orelse continue;
            const t_pos = self.signatureParamAtComparePosition(target, tp, i, target_rest_tuple_expanded) orelse continue;
            // A malformed signature can carry an out-of-range parameter
            // TypeId (e.g. a partially-lowered nested generic construct
            // signature); recover to `unknown` rather than indexing the
            // type pool out of bounds, matching `substituteTpDeep`'s
            // `validOrUnknown` idiom above.
            const s_param = self.validOrUnknown(s_pos.ty);
            const t_param = self.validOrUnknown(t_pos.ty);
            const sf = self.pool().flagsOf(s_param);
            const tf = self.pool().flagsOf(t_param);
            // Contextually instantiate a generic source callback
            // against a concrete target callback. Repeated source type
            // params must see the same target type; `g<T>(T, T)` fits
            // `(number, number) => V` but not `(number, string) => V`.
            if (sf.is_type_parameter and !tf.is_type_parameter) {
                if (mappedTp(s_param, source_context_buf[0..source_context_len])) |existing| {
                    if (existing != t_param) return false;
                } else if (source_context_len < source_context_buf.len) {
                    source_context_buf[source_context_len] = .{ .from = s_param, .to = t_param };
                    source_context_len += 1;
                }
            }
            const s_param_ctx = try self.substituteTpDeep(s_param, source_context_buf[0..source_context_len]);
            // Both sides are type-parameters at the same position —
            // unify them as the same tp for the rest of the
            // comparison and skip the assignability check (the
            // caller can pass anything for `T`/`U`, so the param-type
            // constraint is the type-parameter itself).
            if (sf.is_type_parameter and tf.is_type_parameter) {
                if (tp_map_len < tp_map_buf.len) {
                    tp_map_buf[tp_map_len] = .{ .from = t_param, .to = s_param };
                    tp_map_len += 1;
                }
                const s_constraint = self.typeParameterConstraint(s_param);
                const t_constraint_raw = self.typeParameterConstraint(t_param);
                if (s_constraint != null and t_constraint_raw != null) {
                    const t_constraint = try self.substituteTpDeep(t_constraint_raw.?, tp_map_buf[0..tp_map_len]);
                    if (!try self.isAssignableTo(s_constraint.?, t_constraint)) return false;
                }
                continue;
            }
            const t_param_ctx_raw = try self.substituteTpDeep(t_param, tp_map_buf[0..tp_map_len]);
            const s_param_cmp = if (!source_rest_tuple_expanded)
                self.restArrayElementParam(source, sp, s_pos.physical_index, s_param_ctx)
            else
                s_param_ctx;
            const t_param_cmp = if (!target_rest_tuple_expanded)
                self.restArrayElementParam(target, tp, t_pos.physical_index, t_param_ctx_raw)
            else
                t_param_ctx_raw;
            const comparing_rest_array_elements = !source_rest_tuple_expanded and
                !target_rest_tuple_expanded and
                ((self.rest_signatures != null and self.rest_signatures.?.contains(source) and s_pos.physical_index + 1 == sp.len) or
                    (self.rest_signatures != null and self.rest_signatures.?.contains(target) and t_pos.physical_index + 1 == tp.len));
            const reject_param_inference = reject_target_type_parameter and comparing_rest_array_elements;
            // Strict mode: target's param must be assignable to
            // source's (contravariant). Non-strict: bivariant —
            // accept either direction.
            if (!force_bivariant_params and (force_strict_params or self.strict_function_types)) {
                if (!try self.signatureParamAssignableTo(t_param_cmp, s_param_cmp, reject_param_inference)) return false;
            } else {
                const ct = try self.signatureParamAssignableTo(t_param_cmp, s_param_cmp, reject_param_inference);
                const co = try self.signatureParamAssignableTo(s_param_cmp, t_param_cmp, reject_param_inference);
                if (!ct and !co) return false;
            }
        }
        const s_ret_raw = self.interner.signatureReturn(source) orelse return true;
        const s_ret = try self.substituteTpDeep(s_ret_raw, source_context_buf[0..source_context_len]);
        const t_ret_raw = self.interner.signatureReturn(target) orelse return true;
        if (t_ret_raw == Primitive.void_t) return true;
        // Substitute target type-parameters with their source
        // counterparts so `<T>(x: T) => T` matches `<U>(x: U) => U`
        // even though `T` and `U` intern to distinct ids.
        const t_ret = try self.substituteTpDeep(t_ret_raw, tp_map_buf[0..tp_map_len]);
        return self.isAssignableTo(s_ret, t_ret);
    }

    /// Collect the property names + types that `source` exposes as an
    /// object. For an intersection source we merge members from every
    /// object constituent (later constituents win on name collision,
    /// matching tsc's `getPropertiesOfType` last-wins for intersections
    /// well enough for discriminant matching). Returns owned slices the
    /// caller must free.
    const SourceProp = struct { name: types.StringId, type: TypeId };

    fn collectSourceProps(self: *Engine, source: TypeId) anyerror![]SourceProp {
        var list: std.ArrayListUnmanaged(SourceProp) = .empty;
        errdefer list.deinit(self.gpa);
        const sf = self.pool().flagsOf(source);
        if (sf.is_object_type) {
            for (self.interner.objectMembers(source)) |m| {
                try list.append(self.gpa, .{ .name = m.name, .type = m.type });
            }
        } else if (sf.is_intersection) {
            for (self.interner.intersectionMembers(source)) |member_t| {
                if (member_t >= self.pool().typeCount()) continue;
                if (!self.pool().flagsOf(member_t).is_object_type) continue;
                for (self.interner.objectMembers(member_t)) |m| {
                    var replaced = false;
                    for (list.items) |*existing| {
                        if (existing.name == m.name) {
                            existing.type = m.type;
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) try list.append(self.gpa, .{ .name = m.name, .type = m.type });
                }
            }
        }
        return list.toOwnedSlice(self.gpa);
    }

    /// True when `name` is a discriminant property of the union `target`:
    /// every constituent that is an object type declares `name`, the
    /// per-constituent types are not all identical (non-uniform), and
    /// each is a unit/literal type (literal, enum literal, or the
    /// `null`/`undefined`/`true`/`false`/`void` unit primitives).
    /// Mirrors tsc's `isDiscriminantProperty` /
    /// `CheckFlagsNonUniformAndLiteral` gate (relater.go:1085).
    fn isDiscriminantProperty(self: *Engine, target_union: TypeId, name: types.StringId) bool {
        const members = self.interner.unionMembers(target_union);
        var first_type: TypeId = Primitive.none;
        var saw_any = false;
        var non_uniform = false;
        var has_literal = false;
        for (members) |constituent| {
            if (constituent >= self.pool().typeCount()) return false;
            const cf = self.pool().flagsOf(constituent);
            if (!cf.is_object_type) return false;
            const pt = self.interner.objectMember(constituent, name) orelse return false;
            // tsc's `CheckFlagsHasLiteralType` is OR'd across the
            // constituents' property types: it is enough that ONE
            // constituent contributes a unit/literal type. A
            // non-literal constituent (e.g. `value: number` alongside
            // `value: undefined`) does not disqualify the property —
            // mirrors `{ value: number } | { value: undefined }` in the
            // GH58603 `Foo` discriminated union.
            if (self.typeContainsUnit(pt)) has_literal = true;
            if (!saw_any) {
                first_type = pt;
                saw_any = true;
            } else if (pt != first_type) {
                non_uniform = true;
            }
        }
        return saw_any and non_uniform and has_literal;
    }

    /// True when `t` is a unit type, or a union with at least one unit
    /// member. Mirrors the per-constituent `isLiteralType` test tsc
    /// applies when computing `CheckFlagsHasLiteralType` for a synthetic
    /// union property.
    fn typeContainsUnit(self: *Engine, t: TypeId) bool {
        if (self.isUnitType(t)) return true;
        if (t < self.pool().typeCount() and self.pool().flagsOf(t).is_union) {
            for (self.interner.unionMembers(t)) |m| {
                if (self.isUnitType(m)) return true;
            }
        }
        return false;
    }

    /// A "unit" type in tsc's sense: a single concrete value type. We
    /// accept literal/enum-literal types plus the unit primitives that
    /// participate in discriminants (`true`, `false`, `null`,
    /// `undefined`, `void`). Bare `boolean`/`string`/`number` are NOT
    /// unit types.
    fn isUnitType(self: *Engine, t: TypeId) bool {
        if (t == Primitive.true_lit or t == Primitive.false_lit or
            t == Primitive.null_t or t == Primitive.undefined_t or
            t == Primitive.void_t) return true;
        if (t >= self.pool().typeCount()) return false;
        const f = self.pool().flagsOf(t);
        return f.is_literal or f.is_enum_literal;
    }

    /// Distribute a type over its union members for the discriminant
    /// cartesian product. A non-union type distributes to a single
    /// element. Returns an owned slice.
    fn distributeType(self: *Engine, t: TypeId) anyerror![]TypeId {
        // `boolean` is the union `true | false` in tsc; distribute it so
        // a `done: boolean` source discriminant matches `true`/`false`
        // constituents (IteratorResult pattern).
        if (t == Primitive.boolean_t) {
            const pair = try self.gpa.alloc(TypeId, 2);
            pair[0] = Primitive.true_lit;
            pair[1] = Primitive.false_lit;
            return pair;
        }
        if (t < self.pool().typeCount() and self.pool().flagsOf(t).is_union) {
            return self.gpa.dupe(TypeId, self.interner.unionMembers(t));
        }
        const one = try self.gpa.alloc(TypeId, 1);
        one[0] = t;
        return one;
    }

    /// Port of tsc's `typeRelatedToDiscriminatedType` (relater.go:3962).
    /// Source is an object/intersection, target is a union. Returns true
    /// when, for every combination of source's discriminant property
    /// values, there is a matching target constituent, and the
    /// non-discriminant properties of every matched constituent are
    /// satisfied by source.
    fn typeRelatedToDiscriminatedType(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        const source_props = try self.collectSourceProps(source);
        defer self.gpa.free(source_props);
        if (source_props.len == 0) return false;

        // 1. Filter to source props that are discriminants of target.
        var disc: std.ArrayListUnmanaged(SourceProp) = .empty;
        defer disc.deinit(self.gpa);
        for (source_props) |sp| {
            if (self.isDiscriminantProperty(target, sp.name)) {
                try disc.append(self.gpa, sp);
            }
        }
        if (disc.items.len == 0) return false;

        // 2. Compute discriminant value sets + combination count (cap 25).
        var num_combinations: usize = 1;
        var disc_types = try self.gpa.alloc([]TypeId, disc.items.len);
        var built: usize = 0;
        defer {
            var i: usize = 0;
            while (i < built) : (i += 1) self.gpa.free(disc_types[i]);
            self.gpa.free(disc_types);
        }
        for (disc.items, 0..) |sp, i| {
            const dist = try self.distributeType(sp.type);
            disc_types[i] = dist;
            built += 1;
            if (dist.len == 0) return false;
            num_combinations *= dist.len;
            if (num_combinations > 25) return false;
        }

        const target_members = self.interner.unionMembers(target);
        const target_snapshot = try self.gpa.dupe(TypeId, target_members);
        defer self.gpa.free(target_snapshot);

        // 3. Build the cartesian product; for each combination find at
        //    least one matching target constituent. Track all matches.
        var matching: std.ArrayListUnmanaged(TypeId) = .empty;
        defer matching.deinit(self.gpa);

        var combination = try self.gpa.alloc(TypeId, disc.items.len);
        defer self.gpa.free(combination);

        var c: usize = 0;
        while (c < num_combinations) : (c += 1) {
            // Decode combination index into per-discriminant choices.
            var n = c;
            var j: usize = disc.items.len;
            while (j > 0) {
                j -= 1;
                const len = disc_types[j].len;
                combination[j] = disc_types[j][n % len];
                n /= len;
            }
            var has_match = false;
            for (target_snapshot) |t| {
                if (t >= self.pool().typeCount()) continue;
                if (!self.pool().flagsOf(t).is_object_type) continue;
                var all_disc_ok = true;
                for (disc.items, 0..) |sp, i| {
                    const tpi = self.interner.objectMemberInfo(t, sp.name) orelse {
                        all_disc_ok = false;
                        break;
                    };
                    // Compare the chosen combination value (a unit type)
                    // to the target's discriminant property type. An
                    // optional target discriminant accepts `undefined`
                    // (its declared type implicitly includes it under
                    // strictNullChecks) — mirrors tsc matching the
                    // `undefined` combination of `{ color?: 'yellow' }`.
                    const tp = try self.effectiveOptionalMemberType(tpi);
                    if (!try self.isAssignableTo(combination[i], tp)) {
                        all_disc_ok = false;
                        break;
                    }
                }
                if (all_disc_ok) {
                    var already = false;
                    for (matching.items) |existing| {
                        if (existing == t) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) try matching.append(self.gpa, t);
                    has_match = true;
                }
            }
            if (!has_match) return false;
        }

        // 4. For every matched constituent, the non-discriminant
        //    properties must relate (source ⊑ constituent, skipping the
        //    discriminant props which were handled per-combination).
        for (matching.items) |t| {
            if (!try self.nonDiscriminantPropertiesRelated(source, t, disc.items)) return false;
        }
        return true;
    }

    /// Check that source satisfies all of target constituent `t`'s
    /// properties except the discriminant ones (which were validated
    /// per-combination). Excess source props are fine.
    fn nonDiscriminantPropertiesRelated(
        self: *Engine,
        source: TypeId,
        t: TypeId,
        disc: []const SourceProp,
    ) anyerror!bool {
        const source_props = try self.collectSourceProps(source);
        defer self.gpa.free(source_props);
        const target_members = try self.gpa.dupe(types.ObjectMember, self.interner.objectMembers(t));
        defer self.gpa.free(target_members);
        for (target_members) |tm| {
            var is_disc = false;
            for (disc) |d| {
                if (d.name == tm.name) {
                    is_disc = true;
                    break;
                }
            }
            if (is_disc) continue;
            // Find source property of the same name.
            var found_type: ?TypeId = null;
            for (source_props) |sp| {
                if (sp.name == tm.name) {
                    found_type = sp.type;
                    break;
                }
            }
            if (found_type) |st| {
                const effective_target = try self.effectiveOptionalMemberType(tm);
                if (!try self.isAssignableTo(st, effective_target)) return false;
            } else {
                // Missing on source: fine only if optional.
                if (!tm.is_optional) return false;
            }
        }
        return true;
    }

    /// Structural object-type assignability per TypeScript's
    /// "duck typing" rule:
    ///
    ///   For every required property `p: T` on `target`, `source`
    ///   must declare `p: S` such that `S` is assignable to `T`.
    ///   Optional `target` properties may be missing on `source`.
    ///   Excess `source` properties are allowed (object-literal
    ///   "fresh"-type checks happen at the call-site, not here).
    ///   Method-vs-property mismatch is not yet enforced (Phase 6).
    fn computeObjectAssignable(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        const target_members = self.interner.objectMembers(target);
        const target_str_idx = self.interner.objectStringIndex(target);
        const target_num_idx = self.interner.objectNumberIndex(target);
        const target_sym_idx = self.interner.objectSymbolIndex(target);
        const source_str_idx = self.interner.objectStringIndex(source);
        const source_num_idx = self.interner.objectNumberIndex(source);
        const source_sym_idx = self.interner.objectSymbolIndex(source);
        if (source_num_idx != Primitive.none and
            self.fixedTupleLength(target) != null and
            self.fixedTupleLength(source) == null and
            self.targetHasRequiredNumericMembers(target))
        {
            return false;
        }
        if (target_members.len > 0) {
            var target_has_required = false;
            var source_has_named_member = false;
            var has_common_member = false;
            const source_members = try self.gpa.dupe(types.ObjectMember, self.interner.objectMembers(source));
            defer self.gpa.free(source_members);
            for (target_members) |tm| {
                if (!tm.is_optional) target_has_required = true;
                for (source_members) |sm| {
                    source_has_named_member = true;
                    if (sm.name == tm.name) has_common_member = true;
                }
            }
            if (!target_has_required and source_has_named_member and !has_common_member) return false;
        }
        if (self.strict_null_checks) {
            const source_members_for_index = self.interner.objectMembers(source);
            if (target_str_idx != Primitive.none) {
                // Prefer a structural indexer; otherwise — but only
                // when the source actually has named members — every
                // named property must be assignable to the target's
                // index value type. Without this fallback, object
                // literals like `{ y: '' }` were wrongly rejected
                // against `{ [x: string]: string }` because the
                // literal doesn't carry an explicit string indexer
                // of its own. A source with NO members (eg another
                // indexer-only type like `{ [i: number]: T }`) still
                // can't satisfy a string indexer — keep the original
                // rejection path so `indexSignatureTypeInference.ts`
                // continues to flag `stringMapToArray(numberMap)`.
                // Pins `multipleStringIndexers.ts(18,5)`.
                if (source_str_idx != Primitive.none) {
                    if (!try self.isAssignableTo(source_str_idx, target_str_idx)) return false;
                } else if (source_members_for_index.len == 0) {
                    return false;
                } else {
                    for (source_members_for_index) |sm| {
                        if (!try self.isAssignableTo(sm.type, target_str_idx)) return false;
                    }
                }
            }
            if (target_num_idx != Primitive.none) {
                // Number indexers accept either a matching source
                // indexer, the source's string indexer (numeric keys
                // collapse to strings at runtime), or every
                // numeric-named source property when the source is
                // a literal-shaped object with members.
                // Pins `multipleNumericIndexers.ts(18,5)`.
                const source_idx_alt = if (source_num_idx != Primitive.none) source_num_idx else source_str_idx;
                if (source_idx_alt != Primitive.none) {
                    if (!try self.isAssignableTo(source_idx_alt, target_num_idx)) return false;
                } else if (source_members_for_index.len == 0) {
                    return false;
                } else if (self.string_interner) |sint| {
                    for (source_members_for_index) |sm| {
                        const name_bytes = sint.getOptional(sm.name) orelse continue;
                        if (!isNumericName(name_bytes)) continue;
                        // A numeric-named optional property contributes its
                        // implicit `| undefined` to the number-index check
                        // under strictNullChecks: `{ 1?: string }` is NOT
                        // assignable to `{ [key: number]: string }` because
                        // `obj[1]` may be `undefined`. (The string-index
                        // loop above intentionally keeps the bare declared
                        // type — tsc exempts optional properties' implicit
                        // undefined for string/dictionary indexers.) Mirrors
                        // `optionalPropertyAssignableToStringIndexSignature.ts`.
                        const sm_eff = try self.effectiveOptionalMemberType(sm);
                        if (!try self.isAssignableTo(sm_eff, target_num_idx)) return false;
                    }
                }
            }
            if (target_sym_idx != Primitive.none) {
                if (source_sym_idx == Primitive.none) return false;
                if (!try self.isAssignableTo(source_sym_idx, target_sym_idx)) return false;
            }
        }
        const stable_target_members = try self.gpa.dupe(types.ObjectMember, target_members);
        defer self.gpa.free(stable_target_members);
        const stable_source_members = try self.gpa.dupe(types.ObjectMember, self.interner.objectMembers(source));
        defer self.gpa.free(stable_source_members);
        for (stable_target_members) |tm| {
            if (try self.someSourceMemberAssignableToTargetFromMembers(stable_source_members, tm)) {
                continue;
            }
            if (sourceObjectMembersHaveName(stable_source_members, tm.name)) return false;
            // No same-named member on source. For purely numeric
            // property names ("0", "1", …) fall back to source's
            // number-key indexer when wired. This is what makes
            // array-literal → tuple assignability work — the literal
            // lowers to `Array<T>`-shape (only `length` + indexer)
            // while the tuple target carries positional "0", "1", …
            // members.
            if (tm.is_optional) continue;
            if (source_num_idx != Primitive.none and self.string_interner != null) {
                if (self.string_interner.?.getOptional(tm.name)) |name_bytes| if (isNumericName(name_bytes)) {
                    if (!try self.isAssignableTo(source_num_idx, tm.type)) return false;
                    continue;
                };
            }
            return false;
        }
        return true;
    }

    fn sourceObjectHasMemberNamed(self: *Engine, source: TypeId, name: types.StringId) bool {
        return sourceObjectMembersHaveName(self.interner.objectMembers(source), name);
    }

    fn sourceObjectMembersHaveName(source_members: []const types.ObjectMember, name: types.StringId) bool {
        for (source_members) |sm| if (sm.name == name) return true;
        return false;
    }

    fn fixedTupleLength(self: *Engine, t: TypeId) ?u64 {
        if (t >= self.pool().typeCount()) return null;
        if (!self.pool().flagsOf(t).is_object_type) return null;
        const si = self.string_interner orelse return null;
        for (self.interner.objectMembers(t)) |m| {
            const name = si.getOptional(m.name) orelse continue;
            if (!std.mem.eql(u8, name, "length")) continue;
            if (m.type >= self.pool().typeCount()) return null;
            const flags = self.pool().flagsOf(m.type);
            if (!flags.is_literal or !flags.is_number) return null;
            return switch (self.interner.literalOf(m.type)) {
                .number_lit => |bits| blk: {
                    const fv: f64 = @bitCast(bits);
                    if (fv < 0 or fv != @floor(fv) or fv > 1024) break :blk null;
                    break :blk @intFromFloat(fv);
                },
                else => null,
            };
        }
        return null;
    }

    fn targetHasRequiredNumericMembers(self: *Engine, target: TypeId) bool {
        const si = self.string_interner orelse return false;
        for (self.interner.objectMembers(target)) |tm| {
            if (tm.is_optional) continue;
            const name = si.getOptional(tm.name) orelse continue;
            if (isNumericName(name)) return true;
        }
        return false;
    }

    fn computeIntersectionObjectAssignable(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        const source_members = self.interner.intersectionMembers(source);
        const target_members = self.interner.objectMembers(target);
        if (self.strict_null_checks) {
            const target_str_idx = self.interner.objectStringIndex(target);
            if (target_str_idx != Primitive.none and
                !try self.intersectionObjectAssignableToStringIndex(source, target_str_idx))
            {
                return false;
            }
            const target_num_idx = self.interner.objectNumberIndex(target);
            if (target_num_idx != Primitive.none and
                !try self.intersectionObjectAssignableToNumberIndex(source, target_num_idx))
            {
                return false;
            }
            const target_sym_idx = self.interner.objectSymbolIndex(target);
            if (target_sym_idx != Primitive.none and
                !try self.intersectionObjectAssignableToSymbolIndex(source, target_sym_idx))
            {
                return false;
            }
        }
        for (target_members) |tm| {
            var found = false;
            for (source_members) |member_t| {
                if (member_t >= self.interner.pool.typeCount()) continue;
                const mf = self.pool().flagsOf(member_t);
                if (mf.is_intersection) {
                    if (try self.computeIntersectionObjectMemberAssignable(member_t, tm)) {
                        found = true;
                        break;
                    }
                    continue;
                }
                if (!mf.is_object_type) continue;
                if (try self.someSourceMemberAssignableToTarget(member_t, tm)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (try self.intersectionObjectHasMemberNamed(source, tm.name)) return false;
                if (!tm.is_optional) return false;
            }
        }
        return true;
    }

    fn intersectionObjectAssignableToStringIndex(
        self: *Engine,
        source: TypeId,
        target_idx: TypeId,
    ) anyerror!bool {
        var flat_members: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
        defer flat_members.deinit(self.gpa);
        var saw_contributing_member = try self.collectIntersectionStringIndexContributors(source, target_idx, &flat_members);
        var seen_names: std.AutoHashMapUnmanaged(types.StringId, void) = .empty;
        defer seen_names.deinit(self.gpa);
        for (flat_members.items) |member| {
            const gop = try seen_names.getOrPut(self.gpa, member.name);
            if (gop.found_existing) continue;
            saw_contributing_member = true;
            var same_name_types: std.ArrayListUnmanaged(TypeId) = .empty;
            defer same_name_types.deinit(self.gpa);
            for (flat_members.items) |candidate| {
                if (candidate.name != member.name) continue;
                try same_name_types.append(self.gpa, candidate.type);
            }
            const apparent_member_t = if (same_name_types.items.len == 1)
                same_name_types.items[0]
            else
                self.interner.internIntersection(same_name_types.items) catch return error.OutOfMemory;
            if (!try self.isAssignableTo(apparent_member_t, target_idx)) return false;
        }
        return saw_contributing_member;
    }

    fn collectIntersectionStringIndexContributors(
        self: *Engine,
        source: TypeId,
        target_idx: TypeId,
        flat_members: *std.ArrayListUnmanaged(types.ObjectMember),
    ) anyerror!bool {
        var saw_contributing_member = false;
        for (self.interner.intersectionMembers(source)) |member_t| {
            if (member_t >= self.interner.pool.typeCount()) continue;
            const mf = self.pool().flagsOf(member_t);
            if (mf.is_intersection) {
                if (try self.collectIntersectionStringIndexContributors(member_t, target_idx, flat_members)) {
                    saw_contributing_member = true;
                }
                continue;
            }
            if (!mf.is_object_type) continue;
            const source_str_idx = self.interner.objectStringIndex(member_t);
            if (source_str_idx != Primitive.none) {
                saw_contributing_member = true;
                if (!try self.isAssignableTo(source_str_idx, target_idx)) return false;
                continue;
            }
            const object_members = self.interner.objectMembers(member_t);
            if (object_members.len > 0) saw_contributing_member = true;
            try flat_members.appendSlice(self.gpa, object_members);
        }
        return saw_contributing_member;
    }

    fn intersectionObjectAssignableToNumberIndex(
        self: *Engine,
        source: TypeId,
        target_idx: TypeId,
    ) anyerror!bool {
        for (self.interner.intersectionMembers(source)) |member_t| {
            if (member_t >= self.interner.pool.typeCount()) continue;
            const mf = self.pool().flagsOf(member_t);
            if (mf.is_intersection) {
                if (!try self.intersectionObjectAssignableToNumberIndex(member_t, target_idx)) return false;
                continue;
            }
            if (!mf.is_object_type) continue;
            const source_num_idx = self.interner.objectNumberIndex(member_t);
            const source_str_idx = self.interner.objectStringIndex(member_t);
            const source_idx_alt = if (source_num_idx != Primitive.none) source_num_idx else source_str_idx;
            if (source_idx_alt != Primitive.none) {
                if (!try self.isAssignableTo(source_idx_alt, target_idx)) return false;
                continue;
            }
            const si = self.string_interner orelse continue;
            for (self.interner.objectMembers(member_t)) |sm| {
                const name_bytes = si.getOptional(sm.name) orelse continue;
                if (!isNumericName(name_bytes)) continue;
                const sm_eff = try self.effectiveOptionalMemberType(sm);
                if (!try self.isAssignableTo(sm_eff, target_idx)) return false;
            }
        }
        return true;
    }

    fn intersectionObjectAssignableToSymbolIndex(
        self: *Engine,
        source: TypeId,
        target_idx: TypeId,
    ) anyerror!bool {
        var saw_symbol_index = false;
        for (self.interner.intersectionMembers(source)) |member_t| {
            if (member_t >= self.interner.pool.typeCount()) continue;
            const mf = self.pool().flagsOf(member_t);
            if (mf.is_intersection) {
                if (!try self.intersectionObjectAssignableToSymbolIndex(member_t, target_idx)) return false;
                continue;
            }
            if (!mf.is_object_type) continue;
            const source_sym_idx = self.interner.objectSymbolIndex(member_t);
            if (source_sym_idx == Primitive.none) continue;
            saw_symbol_index = true;
            if (!try self.isAssignableTo(source_sym_idx, target_idx)) return false;
        }
        return saw_symbol_index;
    }

    fn intersectionObjectHasMemberNamed(self: *Engine, source: TypeId, name: types.StringId) anyerror!bool {
        for (self.interner.intersectionMembers(source)) |member_t| {
            if (member_t >= self.interner.pool.typeCount()) continue;
            const mf = self.pool().flagsOf(member_t);
            if (mf.is_intersection) {
                if (try self.intersectionObjectHasMemberNamed(member_t, name)) return true;
                continue;
            }
            if (!mf.is_object_type) continue;
            if (self.sourceObjectHasMemberNamed(member_t, name)) return true;
        }
        return false;
    }

    fn computeIntersectionObjectMemberAssignable(
        self: *Engine,
        source: TypeId,
        target_member: types.ObjectMember,
    ) anyerror!bool {
        for (self.interner.intersectionMembers(source)) |member_t| {
            if (member_t >= self.interner.pool.typeCount()) continue;
            const mf = self.pool().flagsOf(member_t);
            if (mf.is_intersection) {
                if (try self.computeIntersectionObjectMemberAssignable(member_t, target_member)) return true;
                continue;
            }
            if (!mf.is_object_type) continue;
            if (try self.someSourceMemberAssignableToTarget(member_t, target_member)) return true;
        }
        return false;
    }

    fn computeSignatureAssignableToCallableObject(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        var saw_signature_member = false;
        var signature_member_count: usize = 0;
        const target_members = try self.gpa.dupe(types.ObjectMember, self.interner.objectMembers(target));
        defer self.gpa.free(target_members);
        const has_synthetic_call = self.objectMembersHaveSyntheticSignature(target_members);
        for (target_members) |tm| {
            if (tm.type >= self.interner.pool.typeCount()) continue;
            if (self.pool().flagsOf(tm.type).is_signature) signature_member_count += 1;
        }
        for (target_members) |tm| {
            if (tm.type >= self.interner.pool.typeCount()) return false;
            const tf = self.pool().flagsOf(tm.type);
            if (tf.is_signature) {
                if (has_synthetic_call and
                    !self.isCallOrConstructMember(tm.name) and
                    self.isFunctionPrototypeSignatureName(tm.name))
                {
                    continue;
                }
                saw_signature_member = true;
                const ok = if (signature_member_count > 1)
                    try self.computeSignatureAssignableWithMode(source, tm.type, true, false)
                else
                    try self.isAssignableTo(source, tm.type);
                if (!ok) return false;
                continue;
            }
            if (!tm.is_optional) return false;
        }
        return saw_signature_member;
    }

    fn objectMembersHaveSyntheticSignature(self: *Engine, members: []const types.ObjectMember) bool {
        for (members) |m| {
            if (!self.isCallOrConstructMember(m.name)) continue;
            if (m.type >= self.interner.pool.typeCount()) continue;
            if (self.pool().flagsOf(m.type).is_signature) return true;
        }
        return false;
    }

    fn isFunctionPrototypeSignatureName(self: *Engine, name: types.StringId) bool {
        const si = self.string_interner orelse return false;
        const bytes = si.getOptional(name) orelse return false;
        return std.mem.eql(u8, bytes, "call") or
            std.mem.eql(u8, bytes, "apply") or
            std.mem.eql(u8, bytes, "bind");
    }

    fn computeCallableObjectAssignableToSignature(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        const source_members = try self.gpa.dupe(types.ObjectMember, self.interner.objectMembers(source));
        defer self.gpa.free(source_members);
        for (source_members) |sm| {
            if (sm.type >= self.interner.pool.typeCount()) continue;
            const sf = self.pool().flagsOf(sm.type);
            if (!sf.is_signature) continue;
            if (try self.isAssignableTo(sm.type, target)) return true;
        }
        return false;
    }

    fn typeIncludesUndefined(self: *Engine, t: TypeId) bool {
        if (t == Primitive.undefined_t) return true;
        if (t < Primitive.first_dynamic or t >= self.pool().typeCount()) return false;
        const flags = self.pool().flagsOf(t);
        if (!flags.is_union) return false;
        for (self.interner.unionMembers(t)) |m| {
            if (m == Primitive.undefined_t) return true;
        }
        return false;
    }

    fn someSourceMemberAssignableToTarget(
        self: *Engine,
        source: TypeId,
        target_member: types.ObjectMember,
    ) anyerror!bool {
        const source_members = try self.gpa.dupe(types.ObjectMember, self.interner.objectMembers(source));
        defer self.gpa.free(source_members);
        return self.someSourceMemberAssignableToTargetFromMembers(source_members, target_member);
    }

    fn someSourceMemberAssignableToTargetFromMembers(
        self: *Engine,
        source_members: []const types.ObjectMember,
        target_member: types.ObjectMember,
    ) anyerror!bool {
        const effective_target = try self.effectiveOptionalMemberType(target_member);
        for (source_members) |sm| {
            if (sm.name != target_member.name) continue;
            if (!target_member.is_optional and sm.is_optional) return false;
            // readonly on target is fine even if source is mutable
            // (covariant). Mutable on target with readonly source is
            // still allowed for now to match the current default flag
            // surface.
            if (sm.is_method and target_member.is_method and
                self.pool().flagsOf(sm.type).is_signature and
                self.pool().flagsOf(effective_target).is_signature)
            {
                if (try self.computeSignatureAssignableWithMode(sm.type, effective_target, false, true)) return true;
                continue;
            }
            if (try self.isAssignableTo(sm.type, effective_target)) return true;
        }
        return false;
    }

    /// Effective type of a (possibly optional) object property for
    /// assignability. Mirrors tsc: an optional property's declared
    /// type already includes `undefined` under strictNullChecks (it is
    /// added at declaration time by `addOptionalityEx`), so a source
    /// value of `undefined` satisfies an optional target property. We
    /// fold that in lazily here — appending `undefined` to the target
    /// member's declared type when the member is optional and
    /// strictNullChecks is on. Without strictNullChecks `undefined` is
    /// already assignable to everything, so the augmentation is a no-op.
    fn effectiveOptionalMemberType(self: *Engine, member: types.ObjectMember) anyerror!TypeId {
        if (!member.is_optional or !self.strict_null_checks) return member.type;
        if (member.type == Primitive.undefined_t) return member.type;
        if (self.pool().flagsOf(member.type).is_union) {
            for (self.interner.unionMembers(member.type)) |m| {
                if (m == Primitive.undefined_t) return member.type;
            }
        }
        return try self.interner.internUnion(&.{ member.type, Primitive.undefined_t });
    }

    /// True iff every byte of `s` is an ASCII digit (0-9). Mirrors
    /// the TS rule that `"12"` is a numeric property name but
    /// `"12abc"` is not.
    fn isNumericName(s: []const u8) bool {
        if (s.len == 0) return false;
        for (s) |c| {
            if (c < '0' or c > '9') return false;
        }
        return true;
    }

    /// Subtype is stricter than assignable: `any` is *not* a subtype of
    /// arbitrary types. Used by overload selection.
    pub fn isSubtypeOf(self: *Engine, source: TypeId, target: TypeId) !bool {
        if (source == target) return true;
        if (source == Primitive.never) return true;
        if (target == Primitive.unknown) return true;
        // Crucial difference vs. assignable: `any` is *not* a subtype.
        if (source == Primitive.any) return false;
        if (target == Primitive.any) return false;

        switch (self.cache.lookup(.subtype, source, target)) {
            .yes => return true,
            .no => return false,
            .pending => return true,
            .miss => {},
        }
        // Reuse assignable for the structural part; the difference is
        // the `any` handling above and the "no excess property check"
        // distinction (which Phase 3 doesn't yet exercise).
        const result = try self.isAssignableTo(source, target);
        try self.cache.put(.subtype, source, target, if (result) .yes else .no);
        return result;
    }

    /// Comparable: used for `==` / `!=`. `A` is comparable to `B` if
    /// `A` is assignable to `B` *or* `B` is assignable to `A`.
    pub fn isComparableTo(self: *Engine, a: TypeId, b: TypeId) !bool {
        if (a == b) return true;
        if (a == Primitive.any or b == Primitive.any) return true;
        if (try self.isAssignableTo(a, b)) return true;
        return try self.isAssignableTo(b, a);
    }
};

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "Engine: identity short-circuits via interned ids" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isIdenticalTo(Primitive.string_t, Primitive.string_t));
    try T.expect(!try e.isIdenticalTo(Primitive.string_t, Primitive.number_t));
}

test "Engine: any flows in both directions" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isAssignableTo(Primitive.any, Primitive.string_t));
    try T.expect(try e.isAssignableTo(Primitive.string_t, Primitive.any));
}

test "Engine: never assigns to anything" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isAssignableTo(Primitive.never, Primitive.string_t));
    try T.expect(try e.isAssignableTo(Primitive.never, Primitive.any));
    // Nothing but `never` assigns to `never`.
    try T.expect(!try e.isAssignableTo(Primitive.string_t, Primitive.never));
}

test "Engine: unknown is the universal sink" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isAssignableTo(Primitive.string_t, Primitive.unknown));
    try T.expect(try e.isAssignableTo(Primitive.number_t, Primitive.unknown));
    // `unknown` does *not* assign to `string` (without an assertion).
    try T.expect(!try e.isAssignableTo(Primitive.unknown, Primitive.string_t));
}

test "Engine: literal assigns to its primitive but not vice versa" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    const n42 = try ti.internNumberLiteral(42);
    try T.expect(try e.isAssignableTo(n42, Primitive.number_t));
    try T.expect(!try e.isAssignableTo(Primitive.number_t, n42));
}

test "Engine: boolean assigns to true-or-false union" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    const bool_union = try ti.internUnion(&.{ Primitive.true_lit, Primitive.false_lit });
    try T.expect(try e.isAssignableTo(Primitive.boolean_t, bool_union));
}

test "Engine: union — every member of source assigns" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    const u = try ti.internUnion(&.{ Primitive.string_t, Primitive.number_t });
    // `string | number` does NOT assign to `string`.
    try T.expect(!try e.isAssignableTo(u, Primitive.string_t));
    // `string` DOES assign to `string | number`.
    try T.expect(try e.isAssignableTo(Primitive.string_t, u));
}

test "Engine: intersection — every member of target must accept" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    const inter = try ti.internIntersection(&.{ Primitive.string_t, Primitive.number_t });
    // `string` does not satisfy `string & number` (that intersection
    // is `never` semantically; for now we just check the rule):
    try T.expect(!try e.isAssignableTo(Primitive.string_t, inter));
}

test "Engine: intersection of object types — accepts object with all required props" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const x = try sint.intern("x");
    const y = try sint.intern("y");
    // Target: `{ x: number } & { y: string }`.
    const a = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const b = try ti.internObjectType(&.{
        .{ .name = y, .type = Primitive.string_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const inter = try ti.internIntersection(&.{ a, b });
    // Source: `{ x: 1, y: "hi" }` — has both `x: number` and `y: string`.
    const src_full = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = y, .type = Primitive.string_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    try T.expect(try e.isAssignableTo(src_full, inter));
}

test "Engine: intersection of object types — rejects source missing a member's prop" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const x = try sint.intern("x");
    const y = try sint.intern("y");
    // Target: `{ x: number } & { y: string }`.
    const a = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const b = try ti.internObjectType(&.{
        .{ .name = y, .type = Primitive.string_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const inter = try ti.internIntersection(&.{ a, b });
    // Source: `{ x: 1 }` — missing required `y`, should fail the
    // intersection (assigns to `a` but not to `b`).
    const src_partial = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    try T.expect(!try e.isAssignableTo(src_partial, inter));
}

test "Engine: subtype — any is NOT a subtype" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(!try e.isSubtypeOf(Primitive.any, Primitive.string_t));
    try T.expect(!try e.isSubtypeOf(Primitive.string_t, Primitive.any));
    try T.expect(try e.isSubtypeOf(Primitive.never, Primitive.string_t));
    try T.expect(try e.isSubtypeOf(Primitive.string_t, Primitive.unknown));
}

test "Engine: comparable is symmetric" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    const u = try ti.internUnion(&.{ Primitive.string_t, Primitive.number_t });
    try T.expect(try e.isComparableTo(Primitive.string_t, u));
    try T.expect(try e.isComparableTo(u, Primitive.string_t));
}

test "Engine: undefined assigns to void" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isAssignableTo(Primitive.undefined_t, Primitive.void_t));
    try T.expect(!try e.isAssignableTo(Primitive.string_t, Primitive.void_t));
}

test "Engine: strictNullChecks toggles nullish assignability" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isAssignableTo(Primitive.null_t, Primitive.string_t));
    try T.expect(try e.isAssignableTo(Primitive.undefined_t, Primitive.number_t));
    try T.expect(try e.isAssignableTo(Primitive.null_t, Primitive.void_t));
    var strict_e = try Engine.init(T.allocator, &ti);
    defer strict_e.deinit();
    strict_e.setStrictNullChecks(true);
    try T.expect(!try strict_e.isAssignableTo(Primitive.null_t, Primitive.string_t));
    try T.expect(!try strict_e.isAssignableTo(Primitive.undefined_t, Primitive.number_t));
    try T.expect(try strict_e.isAssignableTo(Primitive.undefined_t, Primitive.void_t));
}

test "RelationCache: pack/unpack key" {
    const k1 = packKey(.assignable, 0xABCDE, 0x12345);
    const k2 = packKey(.assignable, 0xABCDE, 0x12345);
    const k3 = packKey(.subtype, 0xABCDE, 0x12345);
    try T.expectEqual(k1, k2);
    try T.expect(k1 != k3);
}

test "Engine: structural object assignability — exact match" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();

    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const x_id = try sint.intern("x");
    const a = try ti.internObjectType(&.{
        .{ .name = x_id, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const b = try ti.internObjectType(&.{
        .{ .name = x_id, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    try T.expect(try e.isAssignableTo(a, b));
    try T.expect(try e.isIdenticalTo(a, b));
}

test "Engine: object primitive accepts object-like sources only" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();

    const empty_obj = try ti.internObjectType(&.{});
    try T.expect(try e.isAssignableTo(empty_obj, Primitive.object_t));
    try T.expect(!try e.isAssignableTo(Primitive.string_t, Primitive.object_t));
    try T.expect(!try e.isAssignableTo(Primitive.number_t, Primitive.object_t));
}

test "Engine: structural object — source missing required prop fails" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const x = try sint.intern("x");
    const y = try sint.intern("y");
    const src = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const tgt = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = y, .type = Primitive.string_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    try T.expect(!try e.isAssignableTo(src, tgt));
}

test "Engine: structural object — optional target prop allowed missing" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const x = try sint.intern("x");
    const y = try sint.intern("y");
    const src = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const tgt = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = y, .type = Primitive.string_t, .is_optional = true, .is_readonly = false, .is_method = false },
    });
    try T.expect(try e.isAssignableTo(src, tgt));
}

test "Engine: structural object — optional source prop cannot satisfy required target" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const x = try sint.intern("x");
    const src = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = true, .is_readonly = false, .is_method = false },
    });
    const tgt = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    try T.expect(!try e.isAssignableTo(src, tgt));
}

test "Engine: plain array is not assignable to fixed tuple target" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);

    const length_id = try sint.intern("length");
    const zero_id = try sint.intern("0");
    const one_id = try sint.intern("1");
    const len_two = try ti.internNumberLiteral(2);
    const src = try ti.internArrayType(&sint, Primitive.string_t);
    const tgt = try ti.internObjectType(&.{
        .{ .name = length_id, .type = len_two, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = zero_id, .type = Primitive.any, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = one_id, .type = Primitive.any, .is_optional = false, .is_readonly = false, .is_method = false },
    });

    try T.expect(!try e.isAssignableTo(src, tgt));
}

test "Engine: signature is assignable to Function callable object" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);

    const any_array = try ti.internArrayType(&sint, Primitive.any);
    const source = try ti.internSignature(&.{}, Primitive.any, false);
    const function_call = try ti.internSignature(&.{any_array}, Primitive.any, false);
    const function_proto_call = try ti.internSignature(&.{ Primitive.any, any_array }, Primitive.any, false);
    const call_id = try sint.intern("__call");
    const proto_call_id = try sint.intern("call");
    const function_t = try ti.internObjectType(&.{
        .{ .name = call_id, .type = function_call, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = proto_call_id, .type = function_proto_call, .is_optional = false, .is_readonly = false, .is_method = true },
    });

    try T.expect(try e.isAssignableTo(source, function_t));
}

test "Engine: Function callable object is assignable to a zero-parameter signature target" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);

    const any_array = try ti.internArrayType(&sint, Primitive.any);
    const function_call = try ti.internSignature(&.{any_array}, Primitive.any, false);
    const function_proto_call = try ti.internSignature(&.{ Primitive.any, any_array }, Primitive.any, false);
    var rest: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest.deinit(T.allocator);
    try rest.put(T.allocator, function_call, {});
    try rest.put(T.allocator, function_proto_call, {});
    e.setRestSignatures(&rest);
    const call_id = try sint.intern("__call");
    const proto_call_id = try sint.intern("call");
    const function_t = try ti.internObjectType(&.{
        .{ .name = call_id, .type = function_call, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = proto_call_id, .type = function_proto_call, .is_optional = false, .is_readonly = false, .is_method = true },
    });
    const target = try ti.internSignature(&.{}, Primitive.void_t, false);
    try T.expect(try e.isAssignableTo(function_t, target));
    // A genuine required parameter ahead of the rest still constrains
    // arity: `(a: number, ...rest: any[]) => any` is NOT assignable to
    // `() => void` because the target supplies no `a`.
    const with_required = try ti.internSignature(&.{ Primitive.number_t, any_array }, Primitive.any, false);
    try rest.put(T.allocator, with_required, {});
    const with_required_obj = try ti.internObjectType(&.{
        .{ .name = call_id, .type = with_required, .is_optional = false, .is_readonly = false, .is_method = true },
    });
    try T.expect(!try e.isAssignableTo(with_required_obj, target));
}

test "Engine: structural object — weak optional target requires common source property" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const x = try sint.intern("x");
    const y = try sint.intern("y");
    const src = try ti.internObjectType(&.{
        .{ .name = y, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const tgt = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = true, .is_readonly = false, .is_method = false },
    });
    try T.expect(!try e.isAssignableTo(src, tgt));
}

test "Engine: structural object — extra source props allowed" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const x = try sint.intern("x");
    const y = try sint.intern("y");
    const src = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = y, .type = Primitive.string_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const tgt = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    try T.expect(try e.isAssignableTo(src, tgt));
}

test "Engine: structural object — depth-checked" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const x = try sint.intern("x");
    const wrap = try sint.intern("wrap");
    const inner_src = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.number_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const inner_tgt = try ti.internObjectType(&.{
        .{ .name = x, .type = Primitive.string_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const src = try ti.internObjectType(&.{
        .{ .name = wrap, .type = inner_src, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const tgt = try ti.internObjectType(&.{
        .{ .name = wrap, .type = inner_tgt, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    try T.expect(!try e.isAssignableTo(src, tgt));
}

test "Engine: structural object — method signatures compare bivariantly under strictFunctionTypes" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    e.setStrictFunctionTypes(true);
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const compare = try sint.intern("compare");
    const animal_prop = try sint.intern("animal");
    const dog_prop = try sint.intern("dog");
    const animal = try ti.internObjectType(&.{
        .{ .name = animal_prop, .type = Primitive.void_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const dog = try ti.internObjectType(&.{
        .{ .name = animal_prop, .type = Primitive.void_t, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = dog_prop, .type = Primitive.void_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const animal_sig = try ti.internSignature(&.{ animal, animal }, Primitive.number_t, false);
    const dog_sig = try ti.internSignature(&.{ dog, dog }, Primitive.number_t, false);
    const src = try ti.internObjectType(&.{
        .{ .name = compare, .type = dog_sig, .is_optional = false, .is_readonly = false, .is_method = true },
    });
    const tgt = try ti.internObjectType(&.{
        .{ .name = compare, .type = animal_sig, .is_optional = false, .is_readonly = false, .is_method = true },
    });
    try T.expect(try e.isAssignableTo(src, tgt));
}

test "Engine: structural object — function properties stay strict under strictFunctionTypes" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    e.setStrictFunctionTypes(true);
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const compare = try sint.intern("compare");
    const animal_prop = try sint.intern("animal");
    const dog_prop = try sint.intern("dog");
    const animal = try ti.internObjectType(&.{
        .{ .name = animal_prop, .type = Primitive.void_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const dog = try ti.internObjectType(&.{
        .{ .name = animal_prop, .type = Primitive.void_t, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = dog_prop, .type = Primitive.void_t, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const animal_sig = try ti.internSignature(&.{ animal, animal }, Primitive.number_t, false);
    const dog_sig = try ti.internSignature(&.{ dog, dog }, Primitive.number_t, false);
    const src = try ti.internObjectType(&.{
        .{ .name = compare, .type = dog_sig, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const tgt = try ti.internObjectType(&.{
        .{ .name = compare, .type = animal_sig, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    try T.expect(!try e.isAssignableTo(src, tgt));
}

test "Engine: constructor signature with required parameter is not assignable to zero-arg target" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();

    const src = try ti.internSignature(&.{Primitive.number_t}, Primitive.number_t, true);
    const tgt = try ti.internSignature(&.{}, Primitive.number_t, true);
    try T.expect(!try e.isAssignableTo(src, tgt));
}

test "Engine: rest signature assignment compares array element types" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);

    const number_array = try ti.internArrayType(&sint, Primitive.number_t);
    const string_array = try ti.internArrayType(&sint, Primitive.string_t);
    const src = try ti.internSignature(&.{string_array}, Primitive.number_t, false);
    const tgt = try ti.internSignature(&.{number_array}, Primitive.number_t, false);
    var rest: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest.deinit(T.allocator);
    try rest.put(T.allocator, src, {});
    try rest.put(T.allocator, tgt, {});
    e.setRestSignatures(&rest);

    try T.expect(!try e.isAssignableTo(src, tgt));
}

test "Engine: cache populates on lookup" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    const before = e.cache.count();
    _ = try e.isAssignableTo(Primitive.string_t, Primitive.unknown);
    // unknown short-circuits before cache write.
    try T.expectEqual(before, e.cache.count());
    const u = try ti.internUnion(&.{ Primitive.string_t, Primitive.number_t });
    _ = try e.isAssignableTo(Primitive.string_t, u);
    try T.expect(e.cache.count() > before);
}

test "L1Cache: insert + lookup + FIFO eviction" {
    var l1 = try L1Cache.initWithCapacity(T.allocator, 8);
    defer l1.deinit();
    // Fill exactly to capacity.
    var i: u32 = 0;
    while (i < 8) : (i += 1) try l1.insert(@as(u64, i), .yes);
    try T.expectEqual(@as(u32, 8), l1.count());
    // The 9th insert evicts the oldest half (4 entries).
    try l1.insert(100, .no);
    try T.expectEqual(@as(u32, 5), l1.count());
    try T.expectEqual(Result.miss, l1.lookup(0));
    try T.expectEqual(Result.miss, l1.lookup(3));
    try T.expectEqual(Result.yes, l1.lookup(4));
    try T.expectEqual(Result.yes, l1.lookup(7));
    try T.expectEqual(Result.no, l1.lookup(100));
}

test "L1Cache: overwrite preserves capacity" {
    var l1 = try L1Cache.initWithCapacity(T.allocator, 4);
    defer l1.deinit();
    try l1.insert(1, .yes);
    try l1.insert(1, .no);
    try T.expectEqual(@as(u32, 1), l1.count());
    try T.expectEqual(Result.no, l1.lookup(1));
}

test "L2Cache: insert + lookup under lock" {
    var l2 = try L2Cache.initWithCapacity(T.allocator, 4);
    defer l2.deinit();
    try l2.insert(42, .yes);
    try T.expectEqual(Result.yes, l2.lookup(42));
    try T.expectEqual(Result.miss, l2.lookup(43));
}

test "TwoLevelCache: L1 hit avoids L2 entirely" {
    var c = try TwoLevelCache.init(T.allocator);
    defer c.deinit();
    try c.put(.assignable, 1, 2, .yes);
    // First insert went to L1 only (counter=1, not divisible by 4).
    try T.expectEqual(@as(u32, 1), c.l1.count());
    try T.expectEqual(@as(u32, 0), c.l2.count());
    try T.expectEqual(Result.yes, c.lookup(.assignable, 1, 2));
}

test "TwoLevelCache: L2 promotion every Nth insert" {
    var c = try TwoLevelCache.init(T.allocator);
    defer c.deinit();
    // Stride is 4 — the 4th insert (counter 4) lands in L2.
    try c.put(.assignable, 1, 2, .yes);
    try c.put(.assignable, 1, 3, .yes);
    try c.put(.assignable, 1, 4, .yes);
    try T.expectEqual(@as(u32, 0), c.l2.count());
    try c.put(.assignable, 1, 5, .yes);
    try T.expectEqual(@as(u32, 1), c.l2.count());
}

test "TwoLevelCache: L2 hit backfills L1" {
    var c = try TwoLevelCache.init(T.allocator);
    defer c.deinit();
    // Seed L2 directly to simulate cross-worker promotion.
    try c.l2.insert(packKey(.subtype, 7, 9), .yes);
    // L1 is empty.
    try T.expectEqual(@as(u32, 0), c.l1.count());
    // First lookup pulls from L2 and warms L1.
    try T.expectEqual(Result.yes, c.lookup(.subtype, 7, 9));
    try T.expectEqual(@as(u32, 1), c.l1.count());
    // Subsequent lookups are L1-only — verify by clearing L2 and re-checking.
    c.l2.table.clearRetainingCapacity();
    c.l2.ring_head = 0;
    c.l2.ring_len = 0;
    try T.expectEqual(Result.yes, c.lookup(.subtype, 7, 9));
}

test "Engine: generic identity — <T>(x: T) => T assigns to <U>(x: U) => U" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();

    const t_name = try sint.intern("T");
    const u_name = try sint.intern("U");
    const t_tp = try ti.internTypeParameter(t_name, Primitive.unknown, Primitive.none);
    const u_tp = try ti.internTypeParameter(u_name, Primitive.unknown, Primitive.none);
    // `T` and `U` intern to distinct ids (different StringId names).
    try T.expect(t_tp != u_tp);

    // Source: `<U>(x: U) => U` ; Target: `<T>(x: T) => T`.
    const src = try ti.internSignature(&.{u_tp}, u_tp, false);
    const tgt = try ti.internSignature(&.{t_tp}, t_tp, false);
    try T.expect(try e.isAssignableTo(src, tgt));
    // Symmetric: also assignable in the opposite direction.
    try T.expect(try e.isAssignableTo(tgt, src));
}

test "TwoLevelCache: pending markers are not promoted to L2" {
    var c = try TwoLevelCache.init(T.allocator);
    defer c.deinit();
    // Burn 4 pending inserts — L2 must stay empty.
    var i: u32 = 0;
    while (i < 16) : (i += 1) try c.put(.identity, i, i + 1, .pending);
    try T.expectEqual(@as(u32, 0), c.l2.count());
}

// --- Discriminated-union assignability (typeRelatedToDiscriminatedType) ---

fn mkMember(name: types.StringId, ty: TypeId, optional: bool) types.ObjectMember {
    return .{ .name = name, .type = ty, .is_optional = optional, .is_readonly = false, .is_method = false };
}

test "Engine: discriminated union — IteratorResult (Example1)" {
    // type S = { done: boolean, value: number }
    // type T = { done: true, value: number } | { done: false, value: number }
    // S is assignable to T even though neither constituent alone accepts S.
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);
    const done = try sint.intern("done");
    const value = try sint.intern("value");

    const s = try ti.internObjectType(&.{
        mkMember(done, Primitive.boolean_t, false),
        mkMember(value, Primitive.number_t, false),
    });
    const t0 = try ti.internObjectType(&.{
        mkMember(done, Primitive.true_lit, false),
        mkMember(value, Primitive.number_t, false),
    });
    const t1 = try ti.internObjectType(&.{
        mkMember(done, Primitive.false_lit, false),
        mkMember(value, Primitive.number_t, false),
    });
    const t = try ti.internUnion(&.{ t0, t1 });
    try T.expect(try e.isAssignableTo(s, t));
}

test "Engine: discriminated union — dropping constituents (Example2)" {
    // type S = { a: 0 | 2, b: 4 }
    // type T = { a: 0, b: 1|4 } | { a: 1, b: 2 } | { a: 2, b: 3|4 }
    // S relates: a=0 matches T0 (b:4 ⊑ 1|4), a=2 matches T2 (b:4 ⊑ 3|4).
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);
    const a = try sint.intern("a");
    const b = try sint.intern("b");
    const n0 = try ti.internNumberLiteral(0);
    const n1 = try ti.internNumberLiteral(1);
    const n2 = try ti.internNumberLiteral(2);
    const n3 = try ti.internNumberLiteral(3);
    const n4 = try ti.internNumberLiteral(4);

    const s = try ti.internObjectType(&.{
        mkMember(a, try ti.internUnion(&.{ n0, n2 }), false),
        mkMember(b, n4, false),
    });
    const t0 = try ti.internObjectType(&.{
        mkMember(a, n0, false),
        mkMember(b, try ti.internUnion(&.{ n1, n4 }), false),
    });
    const t1 = try ti.internObjectType(&.{
        mkMember(a, n1, false),
        mkMember(b, n2, false),
    });
    const t2 = try ti.internObjectType(&.{
        mkMember(a, n2, false),
        mkMember(b, try ti.internUnion(&.{ n3, n4 }), false),
    });
    const t = try ti.internUnion(&.{ t0, t1, t2 });
    try T.expect(try e.isAssignableTo(s, t));
}

test "Engine: discriminated union — unmatched discriminant still errors (Example3)" {
    // type S = { a: 0 | 2, b: 4 }
    // type T = { a: 0, b: 1|4 } | { a: 1, b: 2|4 } | { a: 2, b: 3 }
    // a=2 forces T2 but b:4 is NOT ⊑ 3 ⇒ S is NOT assignable.
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);
    const a = try sint.intern("a");
    const b = try sint.intern("b");
    const n0 = try ti.internNumberLiteral(0);
    const n1 = try ti.internNumberLiteral(1);
    const n2 = try ti.internNumberLiteral(2);
    const n3 = try ti.internNumberLiteral(3);
    const n4 = try ti.internNumberLiteral(4);

    const s = try ti.internObjectType(&.{
        mkMember(a, try ti.internUnion(&.{ n0, n2 }), false),
        mkMember(b, n4, false),
    });
    const t0 = try ti.internObjectType(&.{
        mkMember(a, n0, false),
        mkMember(b, try ti.internUnion(&.{ n1, n4 }), false),
    });
    const t1 = try ti.internObjectType(&.{
        mkMember(a, n1, false),
        mkMember(b, try ti.internUnion(&.{ n2, n4 }), false),
    });
    const t2 = try ti.internObjectType(&.{
        mkMember(a, n2, false),
        mkMember(b, n3, false),
    });
    const t = try ti.internUnion(&.{ t0, t1, t2 });
    try T.expect(!try e.isAssignableTo(s, t));
}

test "Engine: discriminated union — missing non-discriminant prop still errors (Example4)" {
    // type S = { a: 0 | 2, b: 4 }
    // type T = { a:0, b:1|4 } | { a:1, b:2 } | { a:2, b:3|4, c:string }
    // a=2 forces T2 but S lacks required `c` ⇒ NOT assignable.
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);
    const a = try sint.intern("a");
    const b = try sint.intern("b");
    const c = try sint.intern("c");
    const n0 = try ti.internNumberLiteral(0);
    const n1 = try ti.internNumberLiteral(1);
    const n2 = try ti.internNumberLiteral(2);
    const n3 = try ti.internNumberLiteral(3);
    const n4 = try ti.internNumberLiteral(4);

    const s = try ti.internObjectType(&.{
        mkMember(a, try ti.internUnion(&.{ n0, n2 }), false),
        mkMember(b, n4, false),
    });
    const t0 = try ti.internObjectType(&.{
        mkMember(a, n0, false),
        mkMember(b, try ti.internUnion(&.{ n1, n4 }), false),
    });
    const t1 = try ti.internObjectType(&.{
        mkMember(a, n1, false),
        mkMember(b, n2, false),
    });
    const t2 = try ti.internObjectType(&.{
        mkMember(a, n2, false),
        mkMember(b, try ti.internUnion(&.{ n3, n4 }), false),
        mkMember(c, Primitive.string_t, false),
    });
    const t = try ti.internUnion(&.{ t0, t1, t2 });
    try T.expect(!try e.isAssignableTo(s, t));
}

test "Engine: discriminated union — genuine type mismatch on non-discriminant still errors" {
    // S = { kind: "a"|"b", val: string }
    // T = { kind:"a", val:number } | { kind:"b", val:number }
    // Discriminant `kind` matches both, but `val: string` is NOT ⊑ number.
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);
    const kind = try sint.intern("kind");
    const val = try sint.intern("val");
    const lit_a = try ti.internStringLiteral(try sint.intern("a"));
    const lit_b = try ti.internStringLiteral(try sint.intern("b"));

    const s = try ti.internObjectType(&.{
        mkMember(kind, try ti.internUnion(&.{ lit_a, lit_b }), false),
        mkMember(val, Primitive.string_t, false),
    });
    const t0 = try ti.internObjectType(&.{
        mkMember(kind, lit_a, false),
        mkMember(val, Primitive.number_t, false),
    });
    const t1 = try ti.internObjectType(&.{
        mkMember(kind, lit_b, false),
        mkMember(val, Primitive.number_t, false),
    });
    const t = try ti.internUnion(&.{ t0, t1 });
    try T.expect(!try e.isAssignableTo(s, t));
}

test "Engine: non-discriminant union still rejects unrelated object" {
    // Target union with a uniform `kind` (not a discriminant) must not
    // be tricked into accepting a structurally-incompatible source.
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);
    const x = try sint.intern("x");
    const y = try sint.intern("y");

    // S = { x: number } ; T = { y: string } | { y: number }
    // No common discriminant; S has no `y` ⇒ not assignable.
    const s = try ti.internObjectType(&.{mkMember(x, Primitive.number_t, false)});
    const t0 = try ti.internObjectType(&.{mkMember(y, Primitive.string_t, false)});
    const t1 = try ti.internObjectType(&.{mkMember(y, Primitive.number_t, false)});
    const t = try ti.internUnion(&.{ t0, t1 });
    try T.expect(!try e.isAssignableTo(s, t));
}

// --- Recursive / deeply-nested structural relation (depth guard) ---

/// Build a left-nested object chain `{ x: { x: { x: ... leaf } } }`
/// of the requested depth, each level a *distinct* interned object id
/// so the relation engine must walk all the way down (no `src==tgt`
/// short-circuit collapses the recursion).
fn buildNestedChain(ti: *Interner, x: types.StringId, leaf: TypeId, depth: usize, tag: TypeId) !TypeId {
    var cur = leaf;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        // Mix in a per-level marker member so successive chains intern
        // to fresh ids rather than collapsing to one cached object.
        cur = try ti.internObjectType(&.{
            mkMember(x, cur, false),
            mkMember(tag, Primitive.number_t, false),
        });
    }
    return cur;
}

fn buildGeneratedNestedRecordLikeChain(
    ti: *Interner,
    names: []const types.StringId,
    leaf: TypeId,
    origin: u32,
) !TypeId {
    var cur = leaf;
    var i: usize = names.len;
    while (i > 0) {
        i -= 1;
        cur = try ti.internObjectType(&.{mkMember(names[i], cur, false)});
        ti.setTypeSymbol(cur, origin);
    }
    return cur;
}

fn buildGeneratedRecursiveUnionIndexerChain(
    ti: *Interner,
    leaf: TypeId,
    origin: u32,
    depth: usize,
) !TypeId {
    var cur = leaf;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const obj = try ti.internObjectTypeWithIndex(&.{}, cur, Primitive.none);
        ti.setTypeSymbol(obj, origin);
        cur = try ti.internUnion(&.{ Primitive.string_t, obj });
    }
    return cur;
}

test "Engine: deeply-nested finite chain relates structurally (no false negative)" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);
    const x = try sint.intern("x");
    const tag = try sint.intern("tag");

    // A 40-deep chain over `number` should assign to a 40-deep chain
    // over `number` — well within the depth budget, so the engine must
    // give the real structural answer (true), not the overflow default.
    const src = try buildNestedChain(&ti, x, Primitive.number_t, 40, tag);
    const tgt = try buildNestedChain(&ti, x, Primitive.number_t, 40, tag);
    try T.expect(try e.isAssignableTo(src, tgt));
}

test "Engine: deeply-nested finite chain rejects genuine leaf mismatch" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);
    const x = try sint.intern("x");
    const tag = try sint.intern("tag");

    // Same shape, incompatible leaf (`string` source vs `number`
    // target). Within depth budget the engine must still report the
    // real mismatch (false). A short depth keeps the leaf reachable
    // before any overflow cutoff.
    const src = try buildNestedChain(&ti, x, Primitive.string_t, 20, tag);
    const tgt = try buildNestedChain(&ti, x, Primitive.number_t, 20, tag);
    try T.expect(!try e.isAssignableTo(src, tgt));
}

test "Engine: over-deep comparison unwinds via depth guard without overflow" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);
    const x = try sint.intern("x");
    const tag = try sint.intern("tag");

    // Chains far deeper than `max_relate_depth`. The engine must NOT
    // overflow the native stack; it returns the optimistic
    // (related/true) answer once the guard trips — matching tsc's
    // overflow-as-related behaviour for assignability. The key
    // assertion is that this terminates and produces a boolean at all.
    const deep = max_relate_depth + 50;
    const src = try buildNestedChain(&ti, x, Primitive.number_t, deep, tag);
    const tgt = try buildNestedChain(&ti, x, Primitive.number_t, deep, tag);
    try T.expect(try e.isAssignableTo(src, tgt));
    try T.expect(e.consumeRelationStackDepthOverflow());
    try T.expect(!e.consumeRelationStackDepthOverflow());
}

test "Engine: same-origin generated recursive chains short-circuit when deeply nested" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);

    const names = [_]types.StringId{
        try sint.intern("x"),
        try sint.intern("y"),
        try sint.intern("z"),
        try sint.intern("a"),
        try sint.intern("b"),
        try sint.intern("c"),
    };
    const origin: u32 = 4242;
    const src = try buildGeneratedNestedRecordLikeChain(&ti, &names, Primitive.number_t, origin);
    const tgt = try buildGeneratedNestedRecordLikeChain(&ti, &names, Primitive.string_t, origin);

    try T.expect(try e.isAssignableTo(src, tgt));
}

test "Engine: recursive union indexer aliases short-circuit through union identity" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();
    e.setStrictNullChecks(true);
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    e.setStringInterner(&sint);

    const src_alias = try buildGeneratedRecursiveUnionIndexerChain(&ti, Primitive.number_t, 701, 6);
    const tgt_alias = try buildGeneratedRecursiveUnionIndexerChain(&ti, Primitive.string_t, 702, 6);

    try T.expect(try e.isAssignableTo(src_alias, tgt_alias));
}
