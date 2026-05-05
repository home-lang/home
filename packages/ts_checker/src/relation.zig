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
//! L2 split is wired here as a single-worker placeholder.
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

/// Single-level relation cache (Phase 3 placeholder for the
/// Phase 5 two-level structure). The map is open-addressed on the
/// `u64` packed key.
pub const RelationCache = struct {
    gpa: std.mem.Allocator,
    table: std.AutoHashMapUnmanaged(u64, Result),

    pub fn init(gpa: std.mem.Allocator) RelationCache {
        return .{ .gpa = gpa, .table = .empty };
    }

    pub fn deinit(self: *RelationCache) void {
        self.table.deinit(self.gpa);
    }

    pub fn lookup(self: *const RelationCache, rel: Relation, src: TypeId, tgt: TypeId) Result {
        return self.table.get(packKey(rel, src, tgt)) orelse .miss;
    }

    pub fn put(self: *RelationCache, rel: Relation, src: TypeId, tgt: TypeId, r: Result) !void {
        try self.table.put(self.gpa, packKey(rel, src, tgt), r);
    }

    pub fn count(self: *const RelationCache) u32 {
        return self.table.count();
    }
};

/// Relation engine. Wraps the interner + cache and exposes the
/// `assignable`, `subtype`, `identity`, `comparable` queries.
pub const Engine = struct {
    interner: *Interner,
    cache: RelationCache,

    pub fn init(gpa: std.mem.Allocator, ti: *Interner) Engine {
        return .{
            .interner = ti,
            .cache = RelationCache.init(gpa),
        };
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
        // Intersection on the source: source assigns to target if any
        // constituent member does.
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

        // `null` and `undefined` assign to themselves only (in strict
        // mode). Without `--strictNullChecks`, they assign to all
        // reference types — the checker config will toggle this.
        if (source == Primitive.null_t or source == Primitive.undefined_t) {
            return false;
        }

        // Object types: structural subtyping. Source must have all
        // properties target requires, and each shared property type
        // must be assignable in the same direction (depth-checked).
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
    fn computeSignatureAssignable(self: *Engine, source: TypeId, target: TypeId) anyerror!bool {
        const sp = self.interner.signatureParams(source);
        const tp = self.interner.signatureParams(target);
        if (sp.len > tp.len) return false;
        for (sp, 0..) |s_param, i| {
            const t_param = tp[i];
            if (!try self.isAssignableTo(t_param, s_param)) return false;
        }
        const s_ret = self.interner.signatureReturn(source) orelse return true;
        const t_ret = self.interner.signatureReturn(target) orelse return true;
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
        for (target_members) |tm| {
            const sm = self.interner.objectMemberInfo(source, tm.name) orelse {
                if (tm.is_optional) continue;
                return false;
            };
            // readonly on target is fine even if source is mutable
            // (covariant). Mutable on target with readonly source is
            // unsound and should fail — Phase 6 enforces this; we
            // currently allow it to keep behavior matching tsgo's
            // default flag set.
            if (!try self.isAssignableTo(sm.type, tm.type)) return false;
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
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isIdenticalTo(Primitive.string_t, Primitive.string_t));
    try T.expect(!try e.isIdenticalTo(Primitive.string_t, Primitive.number_t));
}

test "Engine: any flows in both directions" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isAssignableTo(Primitive.any, Primitive.string_t));
    try T.expect(try e.isAssignableTo(Primitive.string_t, Primitive.any));
}

test "Engine: never assigns to anything" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isAssignableTo(Primitive.never, Primitive.string_t));
    try T.expect(try e.isAssignableTo(Primitive.never, Primitive.any));
    // Nothing but `never` assigns to `never`.
    try T.expect(!try e.isAssignableTo(Primitive.string_t, Primitive.never));
}

test "Engine: unknown is the universal sink" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isAssignableTo(Primitive.string_t, Primitive.unknown));
    try T.expect(try e.isAssignableTo(Primitive.number_t, Primitive.unknown));
    // `unknown` does *not* assign to `string` (without an assertion).
    try T.expect(!try e.isAssignableTo(Primitive.unknown, Primitive.string_t));
}

test "Engine: literal assigns to its primitive but not vice versa" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    const n42 = try ti.internNumberLiteral(42);
    try T.expect(try e.isAssignableTo(n42, Primitive.number_t));
    try T.expect(!try e.isAssignableTo(Primitive.number_t, n42));
}

test "Engine: union — every member of source assigns" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
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
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    const inter = try ti.internIntersection(&.{ Primitive.string_t, Primitive.number_t });
    // `string` does not satisfy `string & number` (that intersection
    // is `never` semantically; for now we just check the rule):
    try T.expect(!try e.isAssignableTo(Primitive.string_t, inter));
}

test "Engine: subtype — any is NOT a subtype" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(!try e.isSubtypeOf(Primitive.any, Primitive.string_t));
    try T.expect(!try e.isSubtypeOf(Primitive.string_t, Primitive.any));
    try T.expect(try e.isSubtypeOf(Primitive.never, Primitive.string_t));
    try T.expect(try e.isSubtypeOf(Primitive.string_t, Primitive.unknown));
}

test "Engine: comparable is symmetric" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    const u = try ti.internUnion(&.{ Primitive.string_t, Primitive.number_t });
    try T.expect(try e.isComparableTo(Primitive.string_t, u));
    try T.expect(try e.isComparableTo(u, Primitive.string_t));
}

test "Engine: undefined assigns to void" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    try T.expect(try e.isAssignableTo(Primitive.undefined_t, Primitive.void_t));
    try T.expect(!try e.isAssignableTo(Primitive.string_t, Primitive.void_t));
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
    var e = Engine.init(T.allocator, &ti);
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

test "Engine: structural object — source missing required prop fails" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
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
    var e = Engine.init(T.allocator, &ti);
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

test "Engine: structural object — extra source props allowed" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = Engine.init(T.allocator, &ti);
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
    var e = Engine.init(T.allocator, &ti);
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
    var e = Engine.init(T.allocator, &ti);
    defer e.deinit();
    const before = e.cache.count();
    _ = try e.isAssignableTo(Primitive.string_t, Primitive.unknown);
    // unknown short-circuits before cache write.
    try T.expectEqual(before, e.cache.count());
    const u = try ti.internUnion(&.{ Primitive.string_t, Primitive.number_t });
    _ = try e.isAssignableTo(Primitive.string_t, u);
    try T.expect(e.cache.count() > before);
}
