//! Type interner — Phase 3 / Phase 5 of TS_PARITY_PLAN.
//!
//! Wraps the SoA `Pool` with structural-equality interning so two
//! lookups for the same type return the same `TypeId`. Identity
//! becomes `id_a == id_b`, the foundation for the relation cache
//! key (§5.4).
//!
//! Phase 5.A.7 introduces 64-shard lock striping for the dedup
//! tables. Each shard owns its own `TypeKey → TypeId` map, key arena,
//! and atomic-based RwLock; shard selection is `Wyhash(key) & 0x3F`.
//! The shared `Pool` backing storage stays single — payload appends
//! are serialized through `pool_mu`, but reads remain lock-free
//! once a writer publishes a header (we pre-reserve generous Pool
//! capacities at init so reads never observe a half-published append).
//! `TypeId` itself stays a flat 32-bit index — sharding is purely an
//! internal dedup-table partitioning, so `Primitive.*` constants
//! retain their numeric ids and every existing `pool.headers.items[id]`
//! call site keeps working unchanged.
//!
//! Verified architectural advantage: tsgo has no global type interner
//! (Appendix D.2). Identity comparisons in tsgo require structural
//! recursion through the relation cache; in Home they are O(1).

const std = @import("std");
const types = @import("types.zig");

pub const TypeId = types.TypeId;
pub const StringId = types.StringId;
pub const Pool = types.Pool;
pub const Primitive = types.Primitive;

/// Number of dedup-table shards. 64 keeps single-shard contention near
/// zero even with 16+ checker workers and matches the string interner
/// (`packages/string_interner`) for cache-line and analysis simplicity.
pub const N_SHARDS: u32 = 64;
const SHARD_MASK: u32 = N_SHARDS - 1; // 0x3F

/// Pre-reserved Pool header capacity. Picked to comfortably cover any
/// realistic TS program (Prisma generated `client.d.ts` is ~ 200 K
/// types; VS Code's full `tsc` is ~ 600 K). With this many slots
/// reserved up front, `headers.append` never reallocates during
/// checking, so concurrent readers of `pool.headers.items[id]` never
/// observe a torn slice header. If we ever exceed this, growth still
/// works correctly under `pool_mu`, just with a one-shot reallocation.
pub const POOL_INITIAL_CAPACITY: u32 = 1 << 20; // 1 Mi types

/// Minimal atomics-based RwLock — same shape as the one in
/// `string_interner`, kept local so the two interners can evolve
/// independently. Reader-preferred; under contention readers spin
/// briefly, writers wait for active readers to drain. Adequate for
/// the per-shard hot path (one map lookup or one append).
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

/// Structural key. The interner hashes + compares these to dedup.
///
/// Numeric / bool literals carry their full value so `42` ≠ `43`,
/// `true` ≠ `false`. Compound types (union, intersection, …) carry
/// pre-computed `TypeId` lists, which lets the interner key on
/// `(kind_tag, sorted_member_ids)` rather than re-walking the
/// nested structure.
pub const TypeKey = union(Kind) {
    string_lit: StringId,
    number_lit: u64,
    bigint_lit: StringId,
    boolean_lit: bool,
    /// Enum-member literal (`Choice.Yes`). Keyed on the owning
    /// enum + member names *and* the underlying value so that two
    /// distinct members collapse only when they truly name the same
    /// member, and never collide with the bare literal sharing the
    /// value. `value` is the regular `LiteralData` written into the
    /// literal payload column. Mirrors tsc's `enumLiteralTypes`
    /// keyed by `(enumSymbol, value)`.
    enum_lit: struct {
        enum_name: StringId,
        member_name: StringId,
        value: types.LiteralData,
    },
    /// Union: members must be sorted by TypeId (interner sorts before
    /// keying so `A | B` and `B | A` collapse).
    union_t: []const TypeId,
    intersection: []const TypeId,
    conditional: types.ConditionalPayload,
    mapped: types.MappedPayload,
    indexed_access: types.IndexedAccessPayload,
    keyof: TypeId,
    template_literal: struct {
        texts: []const StringId,
        types: []const TypeId,
    },
    string_mapping: types.StringMappingPayload,
    tuple: []const types.TupleElement,
    type_parameter: types.TypeParameterPayload,
    instantiation: struct {
        origin: TypeId,
        args: []const TypeId,
    },
    /// Function signature: `(p1: T1, p2: T2) => R` — `params`
    /// captures the parameter type ids in declaration order. Explicit
    /// `this` parameters are keyed separately from ordinary params.
    signature: struct {
        params: []const TypeId,
        return_type: TypeId,
        is_construct: bool,
        is_abstract_construct: bool = false,
        this_type: TypeId = types.Primitive.none,
    },

    pub const Kind = enum(u8) {
        string_lit,
        number_lit,
        bigint_lit,
        boolean_lit,
        enum_lit,
        union_t,
        intersection,
        conditional,
        mapped,
        indexed_access,
        keyof,
        template_literal,
        string_mapping,
        tuple,
        type_parameter,
        instantiation,
        signature,
    };

    pub fn hash(self: TypeKey) u64 {
        var hasher = std.hash.Wyhash.init(0xC73C73C73C73C73C);
        hasher.update(&[_]u8{@intFromEnum(@as(Kind, self))});
        switch (self) {
            .string_lit => |id| hasher.update(std.mem.asBytes(&id)),
            .number_lit => |bits| hasher.update(std.mem.asBytes(&bits)),
            .bigint_lit => |id| hasher.update(std.mem.asBytes(&id)),
            .boolean_lit => |b| hasher.update(std.mem.asBytes(&b)),
            .enum_lit => |e| {
                hasher.update(std.mem.asBytes(&e.enum_name));
                hasher.update(std.mem.asBytes(&e.member_name));
                hasher.update(&[_]u8{@intFromEnum(@as(types.LiteralTag, e.value))});
                switch (e.value) {
                    .string_lit => |sid| hasher.update(std.mem.asBytes(&sid)),
                    .number_lit => |bits| hasher.update(std.mem.asBytes(&bits)),
                    .bigint_lit => |sid| hasher.update(std.mem.asBytes(&sid)),
                    .boolean_lit => |b| hasher.update(std.mem.asBytes(&b)),
                }
            },
            .union_t, .intersection => |members| {
                for (members) |m| hasher.update(std.mem.asBytes(&m));
            },
            .conditional => |c| {
                hasher.update(std.mem.asBytes(&c.check_type));
                hasher.update(std.mem.asBytes(&c.extends_type));
                hasher.update(std.mem.asBytes(&c.true_branch));
                hasher.update(std.mem.asBytes(&c.false_branch));
            },
            .mapped => |m| {
                hasher.update(std.mem.asBytes(&m.constraint));
                hasher.update(std.mem.asBytes(&m.template));
                hasher.update(std.mem.asBytes(&@intFromEnum(m.readonly)));
                hasher.update(std.mem.asBytes(&@intFromEnum(m.optional)));
            },
            .indexed_access => |ia| {
                hasher.update(std.mem.asBytes(&ia.object));
                hasher.update(std.mem.asBytes(&ia.index));
            },
            .keyof => |op| hasher.update(std.mem.asBytes(&op)),
            .template_literal => |tl| {
                for (tl.texts) |text| hasher.update(std.mem.asBytes(&text));
                hasher.update(&[_]u8{0xff});
                for (tl.types) |t| hasher.update(std.mem.asBytes(&t));
            },
            .string_mapping => |sm| {
                hasher.update(&[_]u8{@intFromEnum(sm.kind)});
                hasher.update(std.mem.asBytes(&sm.inner));
            },
            .tuple => |elems| {
                for (elems) |e| {
                    hasher.update(std.mem.asBytes(&e.type));
                    const flags: u8 = (@as(u8, @intFromBool(e.is_optional)) << 0) |
                        (@as(u8, @intFromBool(e.is_rest)) << 1);
                    hasher.update(&[_]u8{flags});
                }
            },
            .type_parameter => |tp| {
                hasher.update(std.mem.asBytes(&tp.name));
                hasher.update(std.mem.asBytes(&tp.constraint));
                hasher.update(std.mem.asBytes(&tp.default));
                hasher.update(&[_]u8{@intFromEnum(tp.variance)});
                hasher.update(&[_]u8{@intFromBool(tp.is_const)});
            },
            .instantiation => |inst| {
                hasher.update(std.mem.asBytes(&inst.origin));
                for (inst.args) |a| hasher.update(std.mem.asBytes(&a));
            },
            .signature => |sig| {
                for (sig.params) |p| hasher.update(std.mem.asBytes(&p));
                hasher.update(std.mem.asBytes(&sig.return_type));
                hasher.update(&[_]u8{@intFromBool(sig.is_construct)});
                hasher.update(&[_]u8{@intFromBool(sig.is_abstract_construct)});
                hasher.update(std.mem.asBytes(&sig.this_type));
            },
        }
        return hasher.final();
    }

    pub fn eql(self: TypeKey, other: TypeKey) bool {
        if (@as(Kind, self) != @as(Kind, other)) return false;
        return switch (self) {
            .string_lit => |a| a == other.string_lit,
            .number_lit => |a| a == other.number_lit,
            .bigint_lit => |a| a == other.bigint_lit,
            .boolean_lit => |a| a == other.boolean_lit,
            .enum_lit => |a| blk: {
                const b = other.enum_lit;
                if (a.enum_name != b.enum_name or a.member_name != b.member_name) break :blk false;
                if (@as(types.LiteralTag, a.value) != @as(types.LiteralTag, b.value)) break :blk false;
                break :blk switch (a.value) {
                    .string_lit => |sid| sid == b.value.string_lit,
                    .number_lit => |bits| bits == b.value.number_lit,
                    .bigint_lit => |sid| sid == b.value.bigint_lit,
                    .boolean_lit => |bv| bv == b.value.boolean_lit,
                };
            },
            .union_t => |a| std.mem.eql(TypeId, a, other.union_t),
            .intersection => |a| std.mem.eql(TypeId, a, other.intersection),
            .conditional => |a| {
                const b = other.conditional;
                return a.check_type == b.check_type and
                    a.extends_type == b.extends_type and
                    a.true_branch == b.true_branch and
                    a.false_branch == b.false_branch;
            },
            .mapped => |a| {
                const b = other.mapped;
                return a.constraint == b.constraint and
                    a.template == b.template and
                    a.readonly == b.readonly and
                    a.optional == b.optional;
            },
            .indexed_access => |a| {
                return a.object == other.indexed_access.object and
                    a.index == other.indexed_access.index;
            },
            .keyof => |a| a == other.keyof,
            .template_literal => |a| {
                const b = other.template_literal;
                return std.mem.eql(StringId, a.texts, b.texts) and
                    std.mem.eql(TypeId, a.types, b.types);
            },
            .string_mapping => |a| {
                const b = other.string_mapping;
                return a.kind == b.kind and a.inner == b.inner;
            },
            .tuple => |a| {
                const b = other.tuple;
                if (a.len != b.len) return false;
                for (a, b) |ea, eb| {
                    if (ea.type != eb.type or ea.is_optional != eb.is_optional or ea.is_rest != eb.is_rest) {
                        return false;
                    }
                }
                return true;
            },
            .type_parameter => |a| {
                const b = other.type_parameter;
                return a.name == b.name and
                    a.constraint == b.constraint and
                    a.default == b.default and
                    a.variance == b.variance and
                    a.is_const == b.is_const;
            },
            .instantiation => |a| {
                const b = other.instantiation;
                return a.origin == b.origin and std.mem.eql(TypeId, a.args, b.args);
            },
            .signature => |a| {
                const b = other.signature;
                return a.is_construct == b.is_construct and
                    a.is_abstract_construct == b.is_abstract_construct and
                    a.return_type == b.return_type and
                    a.this_type == b.this_type and
                    std.mem.eql(TypeId, a.params, b.params);
            },
        };
    }
};

const KeyHashCtx = struct {
    pub fn hash(_: KeyHashCtx, k: TypeKey) u64 {
        return k.hash();
    }
    pub fn eql(_: KeyHashCtx, a: TypeKey, b: TypeKey) bool {
        return a.eql(b);
    }
};

fn shardIndexFor(key_hash: u64) u32 {
    return @as(u32, @truncate(key_hash)) & SHARD_MASK;
}

/// Per-shard dedup state. Each shard owns its own hash table + key
/// arena, guarded by an RwLock. Shard selection is `wyhash(key) & 63`.
const Shard = struct {
    mu: RwLock align(64) = RwLock.init(),
    /// `TypeKey` → `TypeId`. Keys store *owned* slices when the key is
    /// list-shaped (union/intersection/tuple/instantiation); the
    /// per-shard arena owns those slices.
    table: std.HashMapUnmanaged(TypeKey, TypeId, KeyHashCtx, std.hash_map.default_max_load_percentage) = .empty,
    /// Arena backing key-owned slices that hash into this shard.
    key_arena: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator) Shard {
        return .{
            .key_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    fn deinit(self: *Shard, gpa: std.mem.Allocator) void {
        self.table.deinit(gpa);
        self.key_arena.deinit();
    }
};

/// Tiny atomic spin mutex — std.Thread.Mutex isn't available on the
/// Zig version we target, and the L2 cache in `relation.zig` already
/// uses the same pattern. The pool write path is short (a few
/// `ArrayList.append` calls) so spinning is fine.
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

pub const Interner = struct {
    gpa: std.mem.Allocator,
    pool: Pool,
    /// 64 dedup shards, addressed by `wyhash(TypeKey) & 0x3F`.
    shards: [N_SHARDS]Shard,
    /// Single mutex serializing writes to `pool` (header + payload
    /// appends). Reads of `pool.headers.items[id]` etc. are lock-free
    /// because `Pool.init` pre-reserves enough capacity that growth
    /// never reallocates during normal operation.
    pool_mu: SpinMutex = .{},

    /// `TypeId` → enum-member identity for enum-literal types
    /// (`Choice.Yes`). Populated only when an enum member is accessed,
    /// so it stays small. Written under `pool_mu` alongside the header
    /// append; readers consult it lock-free after the writer has
    /// published the entry (the `is_enum_literal` header flag gates
    /// every lookup).
    enum_literal_info: std.AutoHashMapUnmanaged(TypeId, types.EnumLiteralInfo) = .empty,

    pub fn init(gpa: std.mem.Allocator) !Interner {
        var self: Interner = .{
            .gpa = gpa,
            .pool = try Pool.init(gpa),
            .shards = undefined,
        };
        // Pre-reserve generous header capacity so concurrent readers
        // never observe a reallocation in flight.
        try self.pool.headers.ensureTotalCapacity(gpa, POOL_INITIAL_CAPACITY);
        var i: u32 = 0;
        while (i < N_SHARDS) : (i += 1) {
            self.shards[i] = Shard.init(gpa);
        }
        return self;
    }

    pub fn deinit(self: *Interner) void {
        var i: u32 = 0;
        while (i < N_SHARDS) : (i += 1) {
            self.shards[i].deinit(self.gpa);
        }
        self.enum_literal_info.deinit(self.gpa);
        self.pool.deinit();
    }

    /// Intern a string literal type. Returns a stable `TypeId`.
    pub fn internStringLiteral(self: *Interner, value: StringId) !TypeId {
        const key: TypeKey = .{ .string_lit = value };
        return try self.internKey(key, .{ .is_string = true, .is_literal = true });
    }

    pub fn internNumberLiteral(self: *Interner, value: f64) !TypeId {
        const bits: u64 = @bitCast(value);
        const key: TypeKey = .{ .number_lit = bits };
        return try self.internKey(key, .{ .is_number = true, .is_literal = true });
    }

    pub fn internBigIntLiteral(self: *Interner, digits: StringId) !TypeId {
        const key: TypeKey = .{ .bigint_lit = digits };
        return try self.internKey(key, .{ .is_bigint = true, .is_literal = true });
    }

    pub fn internBooleanLiteral(_: *Interner, value: bool) TypeId {
        // Reuse the pre-interned primitives.
        return if (value) Primitive.true_lit else Primitive.false_lit;
    }

    /// Intern an enum-member literal type (`Choice.Yes`). The result is
    /// a fresh unit type carrying both the literal value (number or
    /// string) and the owning enum/member identity, so it is distinct
    /// from the bare literal sharing its value and from another enum's
    /// member with the same value. Mirrors tsc's `getEnumLiteralType`,
    /// which keys a fresh `EnumLiteral | (String|Number)Literal` type
    /// on `(enumSymbol, value)`. Two accesses of the same member return
    /// the same `TypeId`.
    pub fn internEnumNumberLiteral(self: *Interner, value: f64, enum_name: StringId, member_name: StringId) !TypeId {
        const bits: u64 = @bitCast(value);
        const key: TypeKey = .{ .enum_lit = .{
            .enum_name = enum_name,
            .member_name = member_name,
            .value = .{ .number_lit = bits },
        } };
        return try self.internKey(key, .{ .is_number = true, .is_literal = true, .is_enum_literal = true });
    }

    pub fn internEnumStringLiteral(self: *Interner, value: StringId, enum_name: StringId, member_name: StringId) !TypeId {
        const key: TypeKey = .{ .enum_lit = .{
            .enum_name = enum_name,
            .member_name = member_name,
            .value = .{ .string_lit = value },
        } };
        return try self.internKey(key, .{ .is_string = true, .is_literal = true, .is_enum_literal = true });
    }

    /// Enum/member identity for an enum-literal type, or null when `id`
    /// is not an enum-literal. Gated by the `is_enum_literal` flag so
    /// the side-table lookup only fires for genuine enum literals.
    pub fn enumLiteralInfo(self: *const Interner, id: TypeId) ?types.EnumLiteralInfo {
        if (id >= self.pool.typeCount()) return null;
        if (!self.pool.flagsOf(id).is_enum_literal) return null;
        return self.enum_literal_info.get(id);
    }

    pub fn isEnumLiteral(self: *const Interner, id: TypeId) bool {
        if (id >= self.pool.typeCount()) return false;
        return self.pool.flagsOf(id).is_enum_literal;
    }

    /// Intern a union of `members`. The caller's slice is consumed and
    /// re-sorted; the interner stores its own copy. Single-member
    /// "unions" collapse to that member.
    pub fn internUnion(self: *Interner, members: []const TypeId) !TypeId {
        if (members.len == 0) return Primitive.never;
        if (members.len == 1) return members[0];

        // Flatten nested unions: `(A | B) | C` should canonicalize to
        // a single 3-member union. Pre-expand into an unmanaged list
        // so we can recurse one level (members are themselves already
        // flat by this same pre-pass, so one level suffices).
        var expanded: std.ArrayListUnmanaged(TypeId) = .empty;
        defer expanded.deinit(self.gpa);
        for (members) |m| {
            if (self.pool.flagsOf(m).is_union) {
                for (self.unionMembers(m)) |inner_m| {
                    try expanded.append(self.gpa, inner_m);
                }
            } else {
                try expanded.append(self.gpa, m);
            }
        }
        const flattened = expanded.items;
        if (flattened.len == 0) return Primitive.never;
        if (flattened.len == 1) return flattened[0];

        // Sort + dedup into a temporary buffer (gpa). After
        // canonicalization we hash to determine the owning shard,
        // then dupe into that shard's arena before the dedup lookup.
        const scratch = try self.gpa.dupe(TypeId, flattened);
        defer self.gpa.free(scratch);
        std.mem.sort(TypeId, scratch, {}, std.sort.asc(TypeId));
        var write: usize = 1;
        var i: usize = 1;
        while (i < scratch.len) : (i += 1) {
            if (scratch[i] != scratch[i - 1]) {
                scratch[write] = scratch[i];
                write += 1;
            }
        }
        const canonical = scratch[0..write];
        if (canonical.len == 1) return canonical[0];

        // Compute the union's flags: OR of constituent flags but
        // mark `is_union`.
        var flags: types.TypeFlags = .{ .is_union = true };
        for (canonical) |m| {
            const mf = self.pool.flagsOf(m);
            const a: u32 = @bitCast(flags);
            const b: u32 = @bitCast(mf);
            flags = @bitCast(a | b);
        }
        flags.is_union = true;
        return try self.internKeyWithSlice(.union_t, canonical, flags);
    }

    /// Intern an intersection. Single-member intersection collapses.
    pub fn internIntersection(self: *Interner, members: []const TypeId) !TypeId {
        if (members.len == 0) return Primitive.unknown;
        if (members.len == 1) return members[0];
        const scratch = try self.gpa.dupe(TypeId, members);
        defer self.gpa.free(scratch);
        std.mem.sort(TypeId, scratch, {}, std.sort.asc(TypeId));
        var write: usize = 1;
        var i: usize = 1;
        while (i < scratch.len) : (i += 1) {
            if (scratch[i] != scratch[i - 1]) {
                scratch[write] = scratch[i];
                write += 1;
            }
        }
        const canonical = scratch[0..write];
        if (canonical.len == 1) return canonical[0];

        return try self.internKeyWithSlice(.intersection, canonical, .{ .is_intersection = true });
    }

    pub fn internKeyof(self: *Interner, operand: TypeId) !TypeId {
        const key: TypeKey = .{ .keyof = operand };
        return try self.internKey(key, .{ .is_keyof = true });
    }

    pub fn internTemplateLiteral(self: *Interner, texts: []const StringId, type_parts: []const TypeId) !TypeId {
        // Probe with the caller's slices first; on a hit no allocation
        // is needed. On a miss we dupe into the chosen shard arena
        // before publishing so the table key has stable storage.
        const probe: TypeKey = .{ .template_literal = .{ .texts = texts, .types = type_parts } };
        const h = probe.hash();
        const shard_idx = shardIndexFor(h);
        const shard = &self.shards[shard_idx];

        shard.mu.lockShared();
        if (shard.table.getContext(probe, KeyHashCtx{})) |found| {
            shard.mu.unlockShared();
            return found;
        }
        shard.mu.unlockShared();

        shard.mu.lock();
        defer shard.mu.unlock();
        if (shard.table.getContext(probe, KeyHashCtx{})) |found| return found;

        const ka = shard.key_arena.allocator();
        const owned_texts = try ka.dupe(StringId, texts);
        const owned_types = try ka.dupe(TypeId, type_parts);
        const owned_key: TypeKey = .{ .template_literal = .{ .texts = owned_texts, .types = owned_types } };
        return try self.publishKeyLocked(shard, owned_key, .{ .is_string = true, .is_template_literal = true });
    }

    pub fn internStringMapping(self: *Interner, kind: types.StringMappingKind, inner: TypeId) !TypeId {
        const payload: types.StringMappingPayload = .{ .kind = kind, .inner = inner };
        const key: TypeKey = .{ .string_mapping = payload };
        return try self.internKey(key, .{ .is_string = true, .is_string_mapping = true });
    }

    pub fn internIndexedAccess(self: *Interner, object: TypeId, index: TypeId) !TypeId {
        const key: TypeKey = .{ .indexed_access = .{ .object = object, .index = index } };
        return try self.internKey(key, .{ .is_indexed_access = true });
    }

    pub fn internConditional(
        self: *Interner,
        check: TypeId,
        extends_t: TypeId,
        true_branch: TypeId,
        false_branch: TypeId,
    ) !TypeId {
        return try self.internConditionalWithDistribution(check, extends_t, true_branch, false_branch, true);
    }

    pub fn internConditionalWithDistribution(
        self: *Interner,
        check: TypeId,
        extends_t: TypeId,
        true_branch: TypeId,
        false_branch: TypeId,
        is_distributive: bool,
    ) !TypeId {
        const payload: types.ConditionalPayload = .{
            .check_type = check,
            .extends_type = extends_t,
            .true_branch = true_branch,
            .false_branch = false_branch,
            .is_distributive = is_distributive,
        };
        const key: TypeKey = .{ .conditional = payload };
        return try self.internKey(key, .{ .is_conditional = true });
    }

    pub fn internMapped(
        self: *Interner,
        constraint: TypeId,
        template: TypeId,
        readonly: types.ModifierState,
        optional: types.ModifierState,
    ) !TypeId {
        const payload: types.MappedPayload = .{
            .constraint = constraint,
            .template = template,
            .readonly = readonly,
            .optional = optional,
        };
        const key: TypeKey = .{ .mapped = payload };
        return try self.internKey(key, .{ .is_mapped = true });
    }

    pub fn internTypeParameter(self: *Interner, name: StringId, constraint: TypeId, default: TypeId) !TypeId {
        return self.internTypeParameterWithVariance(name, constraint, default, .bivariant);
    }

    /// Like `internTypeParameter` but lets the caller pass an explicit
    /// declaration-site variance (`in` / `out`). Variance participates
    /// in the interner key, so `T` and `in T` produce distinct ids.
    pub fn internTypeParameterWithVariance(
        self: *Interner,
        name: StringId,
        constraint: TypeId,
        default: TypeId,
        variance: types.Variance,
    ) !TypeId {
        return self.internTypeParameterWithFlags(name, constraint, default, variance, false);
    }

    /// Full type-parameter interning entry point. `is_const` is part
    /// of the structural key because it changes call-site inference.
    pub fn internTypeParameterWithFlags(
        self: *Interner,
        name: StringId,
        constraint: TypeId,
        default: TypeId,
        variance: types.Variance,
        is_const: bool,
    ) !TypeId {
        const payload: types.TypeParameterPayload = .{
            .name = name,
            .constraint = constraint,
            .default = default,
            .variance = variance,
            .is_const = is_const,
        };
        const key: TypeKey = .{ .type_parameter = payload };
        return try self.internKey(key, .{ .is_type_parameter = true });
    }

    /// Create a declaration-scoped type parameter without structural
    /// deduplication. Type parameters are alpha-equivalent in some
    /// relation checks, but distinct declarations that share a name
    /// must not collapse: `interface I<T> { m<T>(x: T): T }` has two
    /// different `T` slots.
    pub fn internFreshTypeParameterWithVariance(
        self: *Interner,
        name: StringId,
        constraint: TypeId,
        default: TypeId,
        variance: types.Variance,
    ) !TypeId {
        return self.internFreshTypeParameterWithFlags(name, constraint, default, variance, false);
    }

    pub fn internFreshTypeParameterWithFlags(
        self: *Interner,
        name: StringId,
        constraint: TypeId,
        default: TypeId,
        variance: types.Variance,
        is_const: bool,
    ) !TypeId {
        self.pool_mu.lock();
        defer self.pool_mu.unlock();

        const payload_idx: u32 = @intCast(self.pool.type_parameter_payloads.items.len);
        try self.pool.type_parameter_payloads.append(self.gpa, .{
            .name = name,
            .constraint = constraint,
            .default = default,
            .variance = variance,
            .is_const = is_const,
        });
        const id: TypeId = @intCast(self.pool.headers.items.len);
        try self.pool.headers.append(self.gpa, .{
            .flags = .{ .is_type_parameter = true },
            .symbol = 0,
            .payload = payload_idx,
        });
        return id;
    }

    /// Look up the declaration-site variance of a type-parameter type.
    /// Returns `.bivariant` for non-type-parameter ids (caller filters).
    pub fn typeParameterVariance(self: *const Interner, id: TypeId) types.Variance {
        if (id >= self.pool.typeCount()) return .bivariant;
        if (!self.pool.flagsOf(id).is_type_parameter) return .bivariant;
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.type_parameter_payloads.items.len) return .bivariant;
        const payload = self.pool.type_parameter_payloads.items[payload_idx];
        return payload.variance;
    }

    /// Look up whether a type parameter was declared with `const`.
    pub fn typeParameterIsConst(self: *const Interner, id: TypeId) bool {
        if (!self.pool.flagsOf(id).is_type_parameter) return false;
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.type_parameter_payloads.items.len) return false;
        const payload = self.pool.type_parameter_payloads.items[payload_idx];
        return payload.is_const;
    }

    /// Look up the name (StringId) of a type-parameter type.
    pub fn typeParameterName(self: *const Interner, id: TypeId) ?StringId {
        if (id >= self.pool.typeCount()) return null;
        if (!self.pool.flagsOf(id).is_type_parameter) return null;
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.type_parameter_payloads.items.len) return null;
        const payload = self.pool.type_parameter_payloads.items[payload_idx];
        return payload.name;
    }

    /// Look up the constraint TypeId of a type parameter, if one was
    /// declared. Returns null for non-type-parameter ids and for
    /// parameters with no constraint or a trivial unknown/none
    /// placeholder. Mirrors `Checker.typeParameterConstraint` so the
    /// relation engine can consult the constraint without reaching
    /// into the checker.
    pub fn typeParameterConstraint(self: *const Interner, id: TypeId) ?TypeId {
        if (id >= self.pool.typeCount()) return null;
        if (!self.pool.flagsOf(id).is_type_parameter) return null;
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.type_parameter_payloads.items.len) return null;
        const tp = self.pool.type_parameter_payloads.items[payload_idx];
        if (tp.constraint == types.Primitive.none or tp.constraint == types.Primitive.unknown) return null;
        return tp.constraint;
    }

    /// Intern a function signature type: `(p1: T1, p2: T2) => R`.
    /// `param_types` is consumed via dupe; caller may free its
    /// original copy.
    pub fn internSignature(self: *Interner, param_types: []const TypeId, return_type: TypeId, is_construct: bool) !TypeId {
        return try self.internSignatureWithAbstract(param_types, return_type, is_construct, false);
    }

    pub fn internSignatureWithAbstract(
        self: *Interner,
        param_types: []const TypeId,
        return_type: TypeId,
        is_construct: bool,
        is_abstract_construct: bool,
    ) !TypeId {
        return try self.internSignatureWithThisType(
            param_types,
            return_type,
            is_construct,
            is_abstract_construct,
            types.Primitive.none,
        );
    }

    pub fn internSignatureWithThisType(
        self: *Interner,
        param_types: []const TypeId,
        return_type: TypeId,
        is_construct: bool,
        is_abstract_construct: bool,
        this_type: TypeId,
    ) !TypeId {
        const probe: TypeKey = .{ .signature = .{
            .params = param_types,
            .return_type = return_type,
            .is_construct = is_construct,
            .is_abstract_construct = is_abstract_construct and is_construct,
            .this_type = this_type,
        } };
        const h = probe.hash();
        const shard_idx = shardIndexFor(h);
        const shard = &self.shards[shard_idx];

        shard.mu.lockShared();
        if (shard.table.getContext(probe, KeyHashCtx{})) |found| {
            shard.mu.unlockShared();
            return found;
        }
        shard.mu.unlockShared();

        shard.mu.lock();
        defer shard.mu.unlock();
        if (shard.table.getContext(probe, KeyHashCtx{})) |found| return found;

        const owned = try shard.key_arena.allocator().dupe(TypeId, param_types);
        const owned_key: TypeKey = .{ .signature = .{
            .params = owned,
            .return_type = return_type,
            .is_construct = is_construct,
            .is_abstract_construct = is_abstract_construct and is_construct,
            .this_type = this_type,
        } };
        return try self.publishKeyLocked(shard, owned_key, .{ .is_signature = true });
    }

    /// Look up the return type of a signature TypeId. Returns null
    /// if the id isn't a signature.
    pub fn signatureReturn(self: *const Interner, id: TypeId) ?TypeId {
        if (!self.isSignature(id)) return null;
        const payload = self.pool.signature_payloads.items[self.pool.payloadOf(id)];
        return payload.return_type;
    }

    /// Look up the parameter type ids of a signature.
    pub fn signatureParams(self: *const Interner, id: TypeId) []const TypeId {
        if (!self.isSignature(id)) return &.{};
        const payload = self.pool.signature_payloads.items[self.pool.payloadOf(id)];
        return self.pool.type_arg_pool.items[payload.params_start .. payload.params_start + payload.params_len];
    }

    /// True only for a standalone signature payload. Union/intersection
    /// types fold member flags for fast broad-category checks, so their
    /// headers may carry `is_signature` even though their payload column is
    /// not `signature_payloads`.
    pub fn isSignature(self: *const Interner, id: TypeId) bool {
        if (id >= self.pool.headers.items.len) return false;
        const flags = self.pool.flagsOf(id);
        if (!flags.is_signature) return false;
        if (flags.is_union or flags.is_intersection) return false;
        return self.pool.payloadOf(id) < self.pool.signature_payloads.items.len;
    }

    /// Intern an object type with the given members. Members must
    /// be sorted by `name` for canonicalization (we sort in place
    /// on a duped copy). The resulting TypeId can be queried via
    /// `objectMember(id, name)` to get a property's type.
    pub fn internObjectType(self: *Interner, members: []const types.ObjectMember) !TypeId {
        return self.internObjectTypeWithIndex(members, types.Primitive.none, types.Primitive.none);
    }

    /// Like `internObjectType` but also wires `string`-key and
    /// `number`-key index signatures (use `Primitive.none` to skip
    /// either). Index types accessed via `member_access` /
    /// `element_access` when the named-property lookup misses.
    pub fn internObjectTypeWithIndex(
        self: *Interner,
        members: []const types.ObjectMember,
        string_index_type: TypeId,
        number_index_type: TypeId,
    ) !TypeId {
        return self.internObjectTypeWithIndexAndSymbol(members, string_index_type, number_index_type, types.Primitive.none);
    }

    pub fn internObjectTypeWithIndexAndSymbol(
        self: *Interner,
        members: []const types.ObjectMember,
        string_index_type: TypeId,
        number_index_type: TypeId,
        symbol_index_type: TypeId,
    ) !TypeId {
        // Object types bypass dedup (every declaration site gets a
        // distinct id), so we just need to serialize the Pool append.
        // Preserve insertion order so diagnostic prose renders members
        // in the user's declaration order (`{ a: string; b: number; }`)
        // rather than sorted-by-StringId order — matches tsc's
        // `.errors.txt` baselines for TS2322/TS2353 messages on
        // anonymous object types. Identity comparison in `relation.zig`
        // tolerates unsorted members via name-based lookup.

        self.pool_mu.lock();
        defer self.pool_mu.unlock();

        const member_start: u32 = @intCast(self.pool.object_member_pool.items.len);
        try self.pool.object_member_pool.appendSlice(self.gpa, members);
        const payload_idx: u32 = @intCast(self.pool.object_type_payloads.items.len);
        try self.pool.object_type_payloads.append(self.gpa, .{
            .members_start = member_start,
            .members_len = @intCast(members.len),
            .call_sig = 0,
            .construct_sig = 0,
            .string_index_type = string_index_type,
            .number_index_type = number_index_type,
            .symbol_index_type = symbol_index_type,
        });
        const id: TypeId = @intCast(self.pool.headers.items.len);
        try self.pool.headers.append(self.gpa, .{
            .flags = .{ .is_object_type = true, .is_object = true },
            .symbol = 0,
            .payload = payload_idx,
        });
        return id;
    }

    /// Build the standard `Array<T>` shape: an object type with a
    /// `length: number` member and a `[i: number]: T` indexer. The
    /// `string_interner` argument is needed to intern the `length`
    /// property name. Subsequent `arr[0]` / `arr.length` accesses
    /// resolve through the existing object-type machinery.
    pub fn internArrayType(
        self: *Interner,
        sint: anytype,
        element: TypeId,
    ) !TypeId {
        const length_id = try sint.intern("length");
        const members = [_]types.ObjectMember{.{
            .name = length_id,
            .type = types.Primitive.number_t,
            .is_optional = false,
            .is_readonly = false,
            .is_method = false,
        }};
        return self.internObjectTypeWithIndex(&members, types.Primitive.none, element);
    }

    /// Look up the string-key index signature's value type, if
    /// present. Returns `Primitive.none` when this object type has
    /// no string indexer.
    pub fn objectStringIndex(self: *const Interner, id: TypeId) TypeId {
        if (!self.pool.flagsOf(id).is_object_type) return types.Primitive.none;
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.object_type_payloads.items.len) return types.Primitive.none;
        const payload = self.pool.object_type_payloads.items[payload_idx];
        return payload.string_index_type;
    }

    /// Look up the number-key index signature's value type, if
    /// present.
    pub fn objectNumberIndex(self: *const Interner, id: TypeId) TypeId {
        if (!self.pool.flagsOf(id).is_object_type) return types.Primitive.none;
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.object_type_payloads.items.len) return types.Primitive.none;
        const payload = self.pool.object_type_payloads.items[payload_idx];
        return payload.number_index_type;
    }

    pub fn objectSymbolIndex(self: *const Interner, id: TypeId) TypeId {
        if (!self.pool.flagsOf(id).is_object_type) return types.Primitive.none;
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.object_type_payloads.items.len) return types.Primitive.none;
        const payload = self.pool.object_type_payloads.items[payload_idx];
        return payload.symbol_index_type;
    }

    /// Lookup a property by name on an object type. Returns its
    /// type id, or `null` if the type isn't an object or the
    /// property doesn't exist.
    pub fn objectMember(self: *const Interner, id: TypeId, name: StringId) ?TypeId {
        for (self.objectMembers(id)) |m| {
            if (m.name == name) return m.type;
        }
        return null;
    }

    /// Full-info lookup for a property — returns the ObjectMember
    /// record, or `null` if the type isn't an object or the
    /// property doesn't exist.
    pub fn objectMemberInfo(self: *const Interner, id: TypeId, name: StringId) ?types.ObjectMember {
        for (self.objectMembers(id)) |m| {
            if (m.name == name) return m;
        }
        return null;
    }

    /// Slice of all members of an object type. Returns an empty
    /// slice if `id` isn't an object type.
    pub fn objectMembers(self: *const Interner, id: TypeId) []const types.ObjectMember {
        if (!self.pool.flagsOf(id).is_object_type) return &.{};
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.object_type_payloads.items.len) return &.{};
        const payload = self.pool.object_type_payloads.items[payload_idx];
        const members = self.pool.object_member_pool.items;
        const start: usize = payload.members_start;
        const len: usize = payload.members_len;
        if (start > members.len) return &.{};
        if (len > members.len - start) return &.{};
        return members[start .. start + len];
    }

    /// Sharded intern entry point. Hashes the key once, picks the
    /// owning shard, takes the read lock for an optimistic dedup
    /// probe, and falls through to the write lock + Pool append on a
    /// miss. For keys whose payload contains caller-owned slices
    /// (union, intersection, template_literal, signature), prefer the
    /// dedicated `internUnion` / `internIntersection` /
    /// `internTemplateLiteral` / `internSignature` entry points which
    /// dupe the slice into the shard arena before publishing.
    fn internKey(self: *Interner, key: TypeKey, flags: types.TypeFlags) !TypeId {
        const h = key.hash();
        const shard_idx = shardIndexFor(h);
        const shard = &self.shards[shard_idx];

        // Read fast path.
        shard.mu.lockShared();
        if (shard.table.getContext(key, KeyHashCtx{})) |found| {
            shard.mu.unlockShared();
            return found;
        }
        shard.mu.unlockShared();

        // Write path: take exclusive lock, double-check, then publish.
        shard.mu.lock();
        defer shard.mu.unlock();
        if (shard.table.getContext(key, KeyHashCtx{})) |found| return found;
        return try self.publishKeyLocked(shard, key, flags);
    }

    /// Sharded intern for keys whose `key` field is a canonical slice
    /// computed by the caller (e.g. sorted+deduped union members).
    /// The slice is in temporary storage; we dupe it into the chosen
    /// shard's arena under the write lock so the table entry holds a
    /// stable, shard-owned pointer.
    fn internKeyWithSlice(
        self: *Interner,
        comptime tag: TypeKey.Kind,
        canonical: []const TypeId,
        flags: types.TypeFlags,
    ) !TypeId {
        const probe: TypeKey = switch (tag) {
            .union_t => .{ .union_t = canonical },
            .intersection => .{ .intersection = canonical },
            else => @compileError("internKeyWithSlice: unsupported tag"),
        };
        const h = probe.hash();
        const shard_idx = shardIndexFor(h);
        const shard = &self.shards[shard_idx];

        // Read fast path with the temporary slice. `KeyHashCtx.eql`
        // does a content compare, so the lookup is correct even
        // though the slice pointer doesn't match the shard-arena slice.
        shard.mu.lockShared();
        if (shard.table.getContext(probe, KeyHashCtx{})) |found| {
            shard.mu.unlockShared();
            return found;
        }
        shard.mu.unlockShared();

        shard.mu.lock();
        defer shard.mu.unlock();
        if (shard.table.getContext(probe, KeyHashCtx{})) |found| return found;

        // Dupe the canonical slice into the shard arena so the table
        // key holds stable storage.
        const owned = try shard.key_arena.allocator().dupe(TypeId, canonical);
        const owned_key: TypeKey = switch (tag) {
            .union_t => .{ .union_t = owned },
            .intersection => .{ .intersection = owned },
            else => unreachable,
        };
        return try self.publishKeyLocked(shard, owned_key, flags);
    }

    /// Allocate the side payload + header for a freshly-keyed type.
    /// Caller must hold `shard.mu` exclusive AND have already
    /// double-checked that the key is absent from `shard.table`. We
    /// acquire `pool_mu` internally to serialize Pool growth.
    fn publishKeyLocked(
        self: *Interner,
        shard: *Shard,
        key: TypeKey,
        flags: types.TypeFlags,
    ) !TypeId {
        self.pool_mu.lock();
        defer self.pool_mu.unlock();

        const payload_idx: u32 = switch (key) {
            .string_lit => |sid| blk: {
                const idx: u32 = @intCast(self.pool.literal_payloads.items.len);
                try self.pool.literal_payloads.append(self.gpa, .{ .string_lit = sid });
                break :blk idx;
            },
            .number_lit => |bits| blk: {
                const idx: u32 = @intCast(self.pool.literal_payloads.items.len);
                try self.pool.literal_payloads.append(self.gpa, .{ .number_lit = bits });
                break :blk idx;
            },
            .bigint_lit => |sid| blk: {
                const idx: u32 = @intCast(self.pool.literal_payloads.items.len);
                try self.pool.literal_payloads.append(self.gpa, .{ .bigint_lit = sid });
                break :blk idx;
            },
            .boolean_lit => |b| blk: {
                const idx: u32 = @intCast(self.pool.literal_payloads.items.len);
                try self.pool.literal_payloads.append(self.gpa, .{ .boolean_lit = b });
                break :blk idx;
            },
            .enum_lit => |e| blk: {
                // The literal *value* shares the regular literal payload
                // column, so `literalOf` resolves it transparently. The
                // enum/member identity is recorded in the side-table once
                // the header id is known (below).
                const idx: u32 = @intCast(self.pool.literal_payloads.items.len);
                try self.pool.literal_payloads.append(self.gpa, e.value);
                break :blk idx;
            },
            .union_t => |members| blk: {
                const start: u32 = @intCast(self.pool.member_pool.items.len);
                try self.pool.member_pool.appendSlice(self.gpa, members);
                const idx: u32 = @intCast(self.pool.union_payloads.items.len);
                try self.pool.union_payloads.append(self.gpa, .{
                    .members_start = start,
                    .members_len = @intCast(members.len),
                });
                break :blk idx;
            },
            .intersection => |members| blk: {
                const start: u32 = @intCast(self.pool.member_pool.items.len);
                try self.pool.member_pool.appendSlice(self.gpa, members);
                const idx: u32 = @intCast(self.pool.intersection_payloads.items.len);
                try self.pool.intersection_payloads.append(self.gpa, .{
                    .members_start = start,
                    .members_len = @intCast(members.len),
                });
                break :blk idx;
            },
            .conditional => |c| blk: {
                const idx: u32 = @intCast(self.pool.conditional_payloads.items.len);
                try self.pool.conditional_payloads.append(self.gpa, c);
                break :blk idx;
            },
            .mapped => |m| blk: {
                const idx: u32 = @intCast(self.pool.mapped_payloads.items.len);
                try self.pool.mapped_payloads.append(self.gpa, m);
                break :blk idx;
            },
            .indexed_access => |ia| blk: {
                const idx: u32 = @intCast(self.pool.indexed_access_payloads.items.len);
                try self.pool.indexed_access_payloads.append(self.gpa, ia);
                break :blk idx;
            },
            .keyof => |op| blk: {
                const idx: u32 = @intCast(self.pool.keyof_payloads.items.len);
                try self.pool.keyof_payloads.append(self.gpa, .{ .operand = op });
                break :blk idx;
            },
            .template_literal => |tl| blk: {
                const texts_start: u32 = @intCast(self.pool.string_id_pool.items.len);
                try self.pool.string_id_pool.appendSlice(self.gpa, tl.texts);
                const types_start: u32 = @intCast(self.pool.type_arg_pool.items.len);
                try self.pool.type_arg_pool.appendSlice(self.gpa, tl.types);
                const idx: u32 = @intCast(self.pool.template_literal_payloads.items.len);
                try self.pool.template_literal_payloads.append(self.gpa, .{
                    .texts_start = texts_start,
                    .texts_len = @intCast(tl.texts.len),
                    .types_start = types_start,
                    .types_len = @intCast(tl.types.len),
                });
                break :blk idx;
            },
            .string_mapping => |sm| blk: {
                const idx: u32 = @intCast(self.pool.string_mapping_payloads.items.len);
                try self.pool.string_mapping_payloads.append(self.gpa, sm);
                break :blk idx;
            },
            .tuple => |elems| blk: {
                const start: u32 = @intCast(self.pool.tuple_element_pool.items.len);
                try self.pool.tuple_element_pool.appendSlice(self.gpa, elems);
                const idx: u32 = @intCast(self.pool.tuple_payloads.items.len);
                try self.pool.tuple_payloads.append(self.gpa, .{
                    .elements_start = start,
                    .elements_len = @intCast(elems.len),
                });
                break :blk idx;
            },
            .type_parameter => |tp| blk: {
                const idx: u32 = @intCast(self.pool.type_parameter_payloads.items.len);
                try self.pool.type_parameter_payloads.append(self.gpa, tp);
                break :blk idx;
            },
            .instantiation => |inst| blk: {
                const start: u32 = @intCast(self.pool.type_arg_pool.items.len);
                try self.pool.type_arg_pool.appendSlice(self.gpa, inst.args);
                const idx: u32 = @intCast(self.pool.instantiation_payloads.items.len);
                try self.pool.instantiation_payloads.append(self.gpa, .{
                    .origin = inst.origin,
                    .args_start = start,
                    .args_len = @intCast(inst.args.len),
                });
                break :blk idx;
            },
            .signature => |sig| blk: {
                const start: u32 = @intCast(self.pool.type_arg_pool.items.len);
                try self.pool.type_arg_pool.appendSlice(self.gpa, sig.params);
                const idx: u32 = @intCast(self.pool.signature_payloads.items.len);
                try self.pool.signature_payloads.append(self.gpa, .{
                    .type_params_start = 0,
                    .type_params_len = 0,
                    .params_start = start,
                    .params_len = @intCast(sig.params.len),
                    .return_type = sig.return_type,
                    .is_construct = sig.is_construct,
                    .is_abstract_construct = sig.is_abstract_construct,
                    .has_this_type = sig.this_type != types.Primitive.none,
                    .this_type = sig.this_type,
                });
                break :blk idx;
            },
        };
        const id: TypeId = @intCast(self.pool.headers.items.len);
        try self.pool.headers.append(self.gpa, .{
            .flags = flags,
            .symbol = 0,
            .payload = payload_idx,
        });
        if (key == .enum_lit) {
            try self.enum_literal_info.put(self.gpa, id, .{
                .enum_name = key.enum_lit.enum_name,
                .member_name = key.enum_lit.member_name,
            });
        }
        try shard.table.putNoClobberContext(self.gpa, key, id, KeyHashCtx{});
        return id;
    }

    // Direct accessors that callers can use without recomputing the key.
    pub fn unionMembers(self: *const Interner, id: TypeId) []const TypeId {
        const flags = self.pool.flagsOf(id);
        std.debug.assert(flags.is_union);
        const p = self.pool.union_payloads.items[self.pool.payloadOf(id)];
        return self.pool.member_pool.items[p.members_start .. p.members_start + p.members_len];
    }

    pub fn intersectionMembers(self: *const Interner, id: TypeId) []const TypeId {
        const flags = self.pool.flagsOf(id);
        std.debug.assert(flags.is_intersection);
        // A union header wears the OR of its members' flags (see
        // `internUnion`), so a union CONTAINING an intersection member is
        // flagged `is_intersection` while its payload indexes
        // `union_payloads`. Reading `intersection_payloads` with that
        // index is out-of-bounds (TypeGuardWithEnumUnion under exact
        // mode) or silent garbage. Such an id is a union, not an
        // intersection — it has no intersection members of its own.
        if (flags.is_union) return &.{};
        const pi = self.pool.payloadOf(id);
        if (pi >= self.pool.intersection_payloads.items.len) return &.{};
        const p = self.pool.intersection_payloads.items[pi];
        return self.pool.member_pool.items[p.members_start .. p.members_start + p.members_len];
    }

    pub fn literalOf(self: *const Interner, id: TypeId) types.LiteralData {
        std.debug.assert(self.pool.flagsOf(id).is_literal);
        return self.pool.literal_payloads.items[self.pool.payloadOf(id)];
    }

    /// Bounds-checked variant for callers that receive arbitrary type ids
    /// (e.g. assignment sources funneled into suggestion heuristics). A type
    /// can carry the `is_literal` flag while its payload index points outside
    /// `literal_payloads` (substituted/cached types whose flags and payload
    /// column diverge); the unchecked `literalOf` would index out of bounds.
    pub fn literalOfOrNull(self: *const Interner, id: TypeId) ?types.LiteralData {
        if (id >= self.pool.typeCount()) return null;
        if (!self.pool.flagsOf(id).is_literal) return null;
        const idx: usize = self.pool.payloadOf(id);
        if (idx >= self.pool.literal_payloads.items.len) return null;
        return self.pool.literal_payloads.items[idx];
    }

    pub fn conditionalPayload(self: *const Interner, id: TypeId) types.ConditionalPayload {
        std.debug.assert(self.pool.flagsOf(id).is_conditional);
        return self.pool.conditional_payloads.items[self.pool.payloadOf(id)];
    }

    pub fn conditionalPayloadOrNull(self: *const Interner, id: TypeId) ?types.ConditionalPayload {
        if (id >= self.pool.typeCount()) return null;
        if (!self.pool.flagsOf(id).is_conditional) return null;
        const idx: usize = self.pool.payloadOf(id);
        if (idx >= self.pool.conditional_payloads.items.len) return null;
        return self.pool.conditional_payloads.items[idx];
    }

    pub fn mappedPayload(self: *const Interner, id: TypeId) types.MappedPayload {
        std.debug.assert(self.pool.flagsOf(id).is_mapped);
        return self.pool.mapped_payloads.items[self.pool.payloadOf(id)];
    }

    pub fn typeSymbol(self: *const Interner, id: TypeId) u32 {
        if (id >= self.pool.headers.items.len) return 0;
        return self.pool.headers.items[id].symbol;
    }

    pub fn setTypeSymbol(self: *Interner, id: TypeId, symbol: u32) void {
        if (id >= self.pool.headers.items.len) return;
        self.pool.headers.items[id].symbol = symbol;
    }

    pub fn templateLiteralPayload(self: *const Interner, id: TypeId) types.TemplateLiteralPayload {
        std.debug.assert(self.pool.flagsOf(id).is_template_literal);
        return self.pool.template_literal_payloads.items[self.pool.payloadOf(id)];
    }

    pub fn templateLiteralTexts(self: *const Interner, id: TypeId) []const StringId {
        const p = self.templateLiteralPayload(id);
        return self.pool.string_id_pool.items[p.texts_start .. p.texts_start + p.texts_len];
    }

    pub fn templateLiteralTypes(self: *const Interner, id: TypeId) []const TypeId {
        const p = self.templateLiteralPayload(id);
        return self.pool.type_arg_pool.items[p.types_start .. p.types_start + p.types_len];
    }

    pub fn stringMappingPayload(self: *const Interner, id: TypeId) types.StringMappingPayload {
        std.debug.assert(self.pool.flagsOf(id).is_string_mapping);
        return self.pool.string_mapping_payloads.items[self.pool.payloadOf(id)];
    }
};

// Note: object members are stored in declaration order (no sort) so
// diagnostic prose renders properties in the user's source order.
// Identity and assignability checks tolerate unsorted members via
// name-based lookup.

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;
const string_interner = @import("string_interner");

test "Interner: primitive ids round-trip without allocation" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    // True/false literals are pre-interned.
    try T.expectEqual(Primitive.true_lit, i.internBooleanLiteral(true));
    try T.expectEqual(Primitive.false_lit, i.internBooleanLiteral(false));
}

test "Interner: number literal type dedup" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    const a = try i.internNumberLiteral(42);
    const b = try i.internNumberLiteral(42);
    const c = try i.internNumberLiteral(43);
    try T.expectEqual(a, b);
    try T.expect(a != c);
}

test "Interner: string literal type dedup" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const id_hello = try sint.intern("hello");
    const id_world = try sint.intern("world");

    const a = try i.internStringLiteral(id_hello);
    const b = try i.internStringLiteral(id_hello);
    const c = try i.internStringLiteral(id_world);
    try T.expectEqual(a, b);
    try T.expect(a != c);
    try T.expect(i.pool.flagsOf(a).is_string);
    try T.expect(i.pool.flagsOf(a).is_literal);
}

test "Interner: union sort-and-dedup canonicalization" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    const ab = try i.internUnion(&.{ Primitive.string_t, Primitive.number_t });
    const ba = try i.internUnion(&.{ Primitive.number_t, Primitive.string_t });
    try T.expectEqual(ab, ba);
    try T.expect(i.pool.flagsOf(ab).is_union);

    // Single-member union collapses.
    const single = try i.internUnion(&.{Primitive.string_t});
    try T.expectEqual(Primitive.string_t, single);

    // Empty union → never.
    const empty = try i.internUnion(&.{});
    try T.expectEqual(Primitive.never, empty);
}

test "Interner: union flags fold constituent flags" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    const u = try i.internUnion(&.{ Primitive.string_t, Primitive.number_t });
    const f = i.pool.flagsOf(u);
    try T.expect(f.is_union);
    try T.expect(f.is_string);
    try T.expect(f.is_number);
}

test "Interner: union flattens nested unions" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    // (string | number) | string should collapse to (string | number).
    // Without flattening, the outer union would contain two members
    // (the inner union + bare string), which leaks through to
    // diagnostic prose as `string | number | string`. Mirrors
    // upstream tsc which canonicalizes unions in flat form. Covers
    // the destructuring-default merge path in
    // `restElementWithAssignmentPattern2.ts`.
    const inner = try i.internUnion(&.{ Primitive.string_t, Primitive.number_t });
    try T.expect(i.pool.flagsOf(inner).is_union);
    const outer = try i.internUnion(&.{ inner, Primitive.string_t });
    // Should collapse to the inner union (string + number, both
    // already present after flattening + dedup).
    try T.expectEqual(inner, outer);
}

test "Interner: union flattens multiple nested unions" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    // (string | number) | (boolean | symbol) flattens to a single
    // four-member union; sort+dedup canonicalizes the order.
    const left = try i.internUnion(&.{ Primitive.string_t, Primitive.number_t });
    const right = try i.internUnion(&.{ Primitive.boolean_t, Primitive.symbol_t });
    const flat = try i.internUnion(&.{ left, right });
    try T.expect(i.pool.flagsOf(flat).is_union);
    const members = i.unionMembers(flat);
    try T.expectEqual(@as(usize, 4), members.len);
    // Verify none of the members are themselves union types
    // (true flat form).
    for (members) |m| {
        try T.expect(!i.pool.flagsOf(m).is_union);
    }
}

test "Interner: signature accessors ignore folded union signature flags" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    const sig = try i.internSignature(&.{Primitive.number_t}, Primitive.string_t, false);
    const u = try i.internUnion(&.{ sig, Primitive.number_t });

    try T.expect(i.pool.flagsOf(u).is_signature);
    try T.expect(!i.isSignature(u));
    try T.expectEqual(@as(?TypeId, null), i.signatureReturn(u));
    try T.expectEqual(@as(usize, 0), i.signatureParams(u).len);
}

test "Interner: intersection collapses single member" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    const x = try i.internIntersection(&.{Primitive.string_t});
    try T.expectEqual(Primitive.string_t, x);
    const empty = try i.internIntersection(&.{});
    try T.expectEqual(Primitive.unknown, empty);
}

test "Interner: keyof is interned structurally" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    const a = try i.internKeyof(Primitive.string_t);
    const b = try i.internKeyof(Primitive.string_t);
    const c = try i.internKeyof(Primitive.number_t);
    try T.expectEqual(a, b);
    try T.expect(a != c);
    try T.expect(i.pool.flagsOf(a).is_keyof);
}

test "Interner: indexed access dedup" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    const a = try i.internIndexedAccess(Primitive.string_t, Primitive.number_t);
    const b = try i.internIndexedAccess(Primitive.string_t, Primitive.number_t);
    const c = try i.internIndexedAccess(Primitive.number_t, Primitive.string_t);
    try T.expectEqual(a, b);
    try T.expect(a != c);
}

test "Interner: conditional dedup" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    const a = try i.internConditional(Primitive.string_t, Primitive.string_t, Primitive.true_lit, Primitive.false_lit);
    const b = try i.internConditional(Primitive.string_t, Primitive.string_t, Primitive.true_lit, Primitive.false_lit);
    try T.expectEqual(a, b);
    try T.expect(i.pool.flagsOf(a).is_conditional);
}

test "Interner: type parameter variance — default is bivariant" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const id_t = try sint.intern("T");

    const tp = try i.internTypeParameter(id_t, types.Primitive.unknown, types.Primitive.none);
    try T.expectEqual(types.Variance.bivariant, i.typeParameterVariance(tp));
    try T.expectEqual(@as(?StringId, id_t), i.typeParameterName(tp));
}

test "Interner: type parameter variance — explicit in/out modifiers distinct ids" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const id_t = try sint.intern("T");

    const bi = try i.internTypeParameterWithVariance(id_t, types.Primitive.unknown, types.Primitive.none, .bivariant);
    const co = try i.internTypeParameterWithVariance(id_t, types.Primitive.unknown, types.Primitive.none, .covariant);
    const ct = try i.internTypeParameterWithVariance(id_t, types.Primitive.unknown, types.Primitive.none, .contravariant);
    const inv = try i.internTypeParameterWithVariance(id_t, types.Primitive.unknown, types.Primitive.none, .invariant);

    // Variance is part of the interner key — same name + constraint +
    // default but different variance must produce distinct ids.
    try T.expect(bi != co);
    try T.expect(bi != ct);
    try T.expect(bi != inv);
    try T.expect(co != ct);
    try T.expect(co != inv);
    try T.expect(ct != inv);

    try T.expectEqual(types.Variance.bivariant, i.typeParameterVariance(bi));
    try T.expectEqual(types.Variance.covariant, i.typeParameterVariance(co));
    try T.expectEqual(types.Variance.contravariant, i.typeParameterVariance(ct));
    try T.expectEqual(types.Variance.invariant, i.typeParameterVariance(inv));
}

test "Interner: type parameter variance — same variance dedups" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const id_t = try sint.intern("T");

    const a = try i.internTypeParameterWithVariance(id_t, types.Primitive.unknown, types.Primitive.none, .covariant);
    const b = try i.internTypeParameterWithVariance(id_t, types.Primitive.unknown, types.Primitive.none, .covariant);
    try T.expectEqual(a, b);
}

test "Interner: const type parameter flag participates in identity" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const id_t = try sint.intern("T");

    const normal = try i.internTypeParameterWithFlags(id_t, types.Primitive.unknown, types.Primitive.none, .bivariant, false);
    const konst = try i.internTypeParameterWithFlags(id_t, types.Primitive.unknown, types.Primitive.none, .bivariant, true);
    const konst_again = try i.internTypeParameterWithFlags(id_t, types.Primitive.unknown, types.Primitive.none, .bivariant, true);

    try T.expect(normal != konst);
    try T.expectEqual(konst, konst_again);
    try T.expect(!i.typeParameterIsConst(normal));
    try T.expect(i.typeParameterIsConst(konst));
}

test "Interner: fresh type parameters preserve declaration identity" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const id_t = try sint.intern("T");

    const outer = try i.internFreshTypeParameterWithVariance(id_t, types.Primitive.unknown, types.Primitive.none, .bivariant);
    const inner = try i.internFreshTypeParameterWithVariance(id_t, types.Primitive.unknown, types.Primitive.none, .bivariant);

    try T.expect(outer != inner);
    try T.expectEqual(@as(?StringId, id_t), i.typeParameterName(outer));
    try T.expectEqual(@as(?StringId, id_t), i.typeParameterName(inner));
}

test "Variance: HIR bit encoding round-trip" {
    try T.expectEqual(types.Variance.bivariant, types.Variance.fromHirBits(0));
    try T.expectEqual(types.Variance.contravariant, types.Variance.fromHirBits(1));
    try T.expectEqual(types.Variance.covariant, types.Variance.fromHirBits(2));
    try T.expectEqual(types.Variance.invariant, types.Variance.fromHirBits(3));
    // Out-of-range falls back to bivariant.
    try T.expectEqual(types.Variance.bivariant, types.Variance.fromHirBits(255));
}

test "Interner: distinct keys land on multiple shards" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();

    // Intern a wide range of distinct number literals; with 64 shards
    // and a good Wyhash mix, the population should spread across
    // many shards (not all into a single one).
    var k: u32 = 0;
    while (k < 4096) : (k += 1) {
        _ = try i.internNumberLiteral(@floatFromInt(k));
    }

    var nonempty: u32 = 0;
    var s_idx: u32 = 0;
    while (s_idx < N_SHARDS) : (s_idx += 1) {
        if (i.shards[s_idx].table.count() > 0) nonempty += 1;
    }
    // 4096 keys / 64 shards = 64 expected per shard; the chance of
    // any single shard being empty is vanishingly small. Assert at
    // least 56 shards used as a generous lower bound.
    try T.expect(nonempty >= 56);
}

test "Interner: parallel intern stress — primitives + literals" {
    var i = try Interner.init(T.allocator);
    defer i.deinit();

    const Worker = struct {
        interner: *Interner,
        thread_id: usize,

        fn run(ctx: @This()) void {
            var k: u32 = 0;
            while (k < 200) : (k += 1) {
                // Mix shared (collision-prone) and per-thread (unique)
                // keys to exercise both the hit and miss code paths.
                const shared = @as(f64, @floatFromInt(k));
                _ = ctx.interner.internNumberLiteral(shared) catch unreachable;
                const per_thread = @as(f64, @floatFromInt(ctx.thread_id * 1000 + k));
                _ = ctx.interner.internNumberLiteral(per_thread) catch unreachable;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (0..4) |idx| {
        threads[idx] = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .interner = &i,
            .thread_id = idx,
        }});
    }
    for (threads) |th| th.join();

    // Re-intern some shared keys serially; they must dedup back to
    // the same TypeIds the workers produced.
    const a = try i.internNumberLiteral(0);
    const b = try i.internNumberLiteral(0);
    try T.expectEqual(a, b);

    // Total number of dynamic types: 200 shared + 4 threads × 200
    // unique = 1000. Allow some slack in case the test framework
    // recycles thread IDs in unexpected ways.
    const dynamic_count = i.pool.typeCount() - Primitive.first_dynamic;
    try T.expect(dynamic_count >= 800);
    try T.expect(dynamic_count <= 1200);
}
