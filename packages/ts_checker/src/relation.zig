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

    pub fn init(gpa: std.mem.Allocator, ti: *Interner) !Engine {
        return .{
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

    pub fn deinit(self: *Engine) void {
        self.cache.deinit();
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
        // already sorted on intern, so we can compare position-wise.
        if (fa.is_object_type) {
            const am = self.interner.objectMembers(a);
            const bm = self.interner.objectMembers(b);
            if (am.len != bm.len) return false;
            for (am, bm) |x, y| {
                if (x.name != y.name) return false;
                if (x.is_optional != y.is_optional) return false;
                if (x.is_readonly != y.is_readonly) return false;
                if (!try self.isIdenticalTo(x.type, y.type)) return false;
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
        try self.cache.put(.assignable, source, target, .pending);
        const result = try self.computeAssignable(source, target);
        try self.cache.put(.assignable, source, target, if (result) .yes else .no);
        return result;
    }

    fn computeAssignable(self: *Engine, source: TypeId, target: TypeId) !bool {
        const sf = self.pool().flagsOf(source);
        const tf = self.pool().flagsOf(target);

        // Union on the source: every member must assign to target.
        if (sf.is_union) {
            const members = self.interner.unionMembers(source);
            for (members) |m| {
                if (!try self.isAssignableTo(m, target)) return false;
            }
            return true;
        }
        // Union on the target: source must assign to *some* member.
        if (tf.is_union) {
            if (source == Primitive.boolean_t and self.unionContainsBooleanLiterals(target)) return true;
            const members = self.interner.unionMembers(target);
            for (members) |m| {
                if (try self.isAssignableTo(source, m)) return true;
            }
            return false;
        }

        // Intersection on the target: source must assign to *every*
        // member.
        if (tf.is_intersection) {
            const members = self.interner.intersectionMembers(target);
            for (members) |m| {
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
            for (members) |m| {
                if (try self.isAssignableTo(m, target)) return true;
            }
            return false;
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
        // `number`.
        if (target == Primitive.object_t) {
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
            if (sf.is_type_parameter) return false;
            return source != Primitive.null_t and
                source != Primitive.undefined_t and
                source != Primitive.void_t and
                source != Primitive.unknown;
        }

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

        // Primitive-vs-primitive: only identity matches at this layer.
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
            var members: std.ArrayListUnmanaged(TypeId) = .empty;
            defer members.deinit(self.interner.gpa);
            for (self.interner.unionMembers(t)) |m| {
                const subbed = try self.substituteTpDeepLimit(m, map, depth + 1);
                try members.append(self.interner.gpa, if (subbed < self.interner.pool.typeCount()) subbed else Primitive.unknown);
            }
            return self.interner.internUnion(members.items) catch t;
        }
        if (flags.is_intersection) {
            if (payload_idx >= self.interner.pool.intersection_payloads.items.len) return t;
            var members: std.ArrayListUnmanaged(TypeId) = .empty;
            defer members.deinit(self.interner.gpa);
            for (self.interner.intersectionMembers(t)) |m| {
                const subbed = try self.substituteTpDeepLimit(m, map, depth + 1);
                try members.append(self.interner.gpa, if (subbed < self.interner.pool.typeCount()) subbed else Primitive.unknown);
            }
            return self.interner.internIntersection(members.items) catch t;
        }
        if (flags.is_object_type) {
            if (payload_idx >= self.interner.pool.object_type_payloads.items.len) return t;
            var members: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
            defer members.deinit(self.interner.gpa);
            for (self.interner.objectMembers(t)) |m| {
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
            var params: std.ArrayListUnmanaged(TypeId) = .empty;
            defer params.deinit(self.interner.gpa);
            for (self.interner.signatureParams(t)) |p| {
                try params.append(self.interner.gpa, self.validOrUnknown(try self.substituteTpDeepLimit(p, map, depth + 1)));
            }
            const ret = if (self.interner.signatureReturn(t)) |r|
                self.validOrUnknown(try self.substituteTpDeepLimit(r, map, depth + 1))
            else
                Primitive.void_t;
            return self.interner.internSignature(params.items, ret, sig_payload.is_construct) catch t;
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
        return self.computeSignatureAssignableWithMode(source, target, false);
    }

    fn computeSignatureAssignableWithMode(
        self: *Engine,
        source: TypeId,
        target: TypeId,
        force_strict_params: bool,
    ) anyerror!bool {
        const sp = self.interner.signatureParams(source);
        const tp = self.interner.signatureParams(target);
        var source_required: usize = sp.len;
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

        const compare_len = @min(sp.len, tp.len);
        for (sp[0..compare_len], 0..) |s_param, i| {
            const t_param = tp[i];
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
            // Strict mode: target's param must be assignable to
            // source's (contravariant). Non-strict: bivariant —
            // accept either direction.
            if (force_strict_params or self.strict_function_types) {
                if (!try self.isAssignableTo(t_param, s_param_ctx)) return false;
            } else {
                const ct = try self.isAssignableTo(t_param, s_param_ctx);
                const co = try self.isAssignableTo(s_param_ctx, t_param);
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
        if (target_members.len > 0) {
            var target_has_required = false;
            var source_has_named_member = false;
            var has_common_member = false;
            const source_members = self.interner.objectMembers(source);
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
            if (target_str_idx != Primitive.none) {
                if (source_str_idx == Primitive.none) return false;
                if (!try self.isAssignableTo(source_str_idx, target_str_idx)) return false;
            }
            if (target_num_idx != Primitive.none) {
                const source_idx = if (source_num_idx != Primitive.none) source_num_idx else source_str_idx;
                if (source_idx == Primitive.none) return false;
                if (!try self.isAssignableTo(source_idx, target_num_idx)) return false;
            }
            if (target_sym_idx != Primitive.none) {
                if (source_sym_idx == Primitive.none) return false;
                if (!try self.isAssignableTo(source_sym_idx, target_sym_idx)) return false;
            }
        }
        for (target_members) |tm| {
            if (try self.someSourceMemberAssignableToTarget(source, tm)) {
                continue;
            }
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

    fn computeIntersectionObjectAssignable(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        const source_members = self.interner.intersectionMembers(source);
        const target_members = self.interner.objectMembers(target);
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
            if (!found and !tm.is_optional) return false;
        }
        return true;
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
        for (self.interner.objectMembers(target)) |tm| {
            if (tm.type >= self.interner.pool.typeCount()) continue;
            if (self.pool().flagsOf(tm.type).is_signature) signature_member_count += 1;
        }
        for (self.interner.objectMembers(target)) |tm| {
            if (tm.type >= self.interner.pool.typeCount()) return false;
            const tf = self.pool().flagsOf(tm.type);
            if (tf.is_signature) {
                saw_signature_member = true;
                const ok = if (signature_member_count > 1)
                    try self.computeSignatureAssignableWithMode(source, tm.type, true)
                else
                    try self.isAssignableTo(source, tm.type);
                if (!ok) return false;
                continue;
            }
            if (!tm.is_optional) return false;
        }
        return saw_signature_member;
    }

    fn computeCallableObjectAssignableToSignature(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        for (self.interner.objectMembers(source)) |sm| {
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
        for (self.interner.objectMembers(source)) |sm| {
            if (sm.name != target_member.name) continue;
            if (!target_member.is_optional and sm.is_optional) return false;
            // readonly on target is fine even if source is mutable
            // (covariant). Mutable on target with readonly source is
            // still allowed for now to match the current default flag
            // surface.
            if (try self.isAssignableTo(sm.type, target_member.type)) return true;
        }
        return false;
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
