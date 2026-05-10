//! Type interner — Phase 3 / Phase 5 of TS_PARITY_PLAN.
//!
//! Wraps the SoA `Pool` with structural-equality interning so two
//! lookups for the same type return the same `TypeId`. Identity
//! becomes `id_a == id_b`, the foundation for the relation cache
//! key (§5.4).
//!
//! Phase 3 ships a *single-threaded* implementation. Phase 5 will add
//! 64-shard lock striping and the seqlock-based read fast path on top
//! of this same Pool layout — the public API does not change.
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
    /// Union: members must be sorted by TypeId (interner sorts before
    /// keying so `A | B` and `B | A` collapse).
    union_t: []const TypeId,
    intersection: []const TypeId,
    conditional: types.ConditionalPayload,
    mapped: types.MappedPayload,
    indexed_access: types.IndexedAccessPayload,
    keyof: TypeId,
    tuple: []const types.TupleElement,
    type_parameter: types.TypeParameterPayload,
    instantiation: struct {
        origin: TypeId,
        args: []const TypeId,
    },
    /// Function signature: `(p1: T1, p2: T2) => R` — `params`
    /// captures the parameter type ids in declaration order; the
    /// final element is conventionally the return type.
    signature: struct {
        params: []const TypeId,
        return_type: TypeId,
        is_construct: bool,
    },

    pub const Kind = enum(u8) {
        string_lit,
        number_lit,
        bigint_lit,
        boolean_lit,
        union_t,
        intersection,
        conditional,
        mapped,
        indexed_access,
        keyof,
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
                    a.return_type == b.return_type and
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

pub const Interner = struct {
    gpa: std.mem.Allocator,
    pool: Pool,
    /// `TypeKey` → `TypeId`. Keys store *owned* slices when the key is
    /// list-shaped (union/intersection/tuple/instantiation); the interner
    /// arena owns those slices.
    table: std.HashMapUnmanaged(TypeKey, TypeId, KeyHashCtx, std.hash_map.default_max_load_percentage),
    /// Arena backing all key-owned slices.
    key_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) !Interner {
        return .{
            .gpa = gpa,
            .pool = try Pool.init(gpa),
            .table = .empty,
            .key_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Interner) void {
        self.table.deinit(self.gpa);
        self.pool.deinit();
        self.key_arena.deinit();
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

    /// Intern a union of `members`. The caller's slice is consumed and
    /// re-sorted; the interner stores its own copy. Single-member
    /// "unions" collapse to that member.
    pub fn internUnion(self: *Interner, members: []const TypeId) !TypeId {
        if (members.len == 0) return Primitive.never;
        if (members.len == 1) return members[0];

        // Sort + dedup into a fresh slice owned by the key arena so
        // the lookup is canonical.
        const sorted = try self.key_arena.allocator().dupe(TypeId, members);
        std.mem.sort(TypeId, sorted, {}, std.sort.asc(TypeId));
        var write: usize = 1;
        var i: usize = 1;
        while (i < sorted.len) : (i += 1) {
            if (sorted[i] != sorted[i - 1]) {
                sorted[write] = sorted[i];
                write += 1;
            }
        }
        const canonical = sorted[0..write];
        if (canonical.len == 1) return canonical[0];

        const key: TypeKey = .{ .union_t = canonical };
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
        return try self.internKey(key, flags);
    }

    /// Intern an intersection. Single-member intersection collapses.
    pub fn internIntersection(self: *Interner, members: []const TypeId) !TypeId {
        if (members.len == 0) return Primitive.unknown;
        if (members.len == 1) return members[0];
        const sorted = try self.key_arena.allocator().dupe(TypeId, members);
        std.mem.sort(TypeId, sorted, {}, std.sort.asc(TypeId));
        var write: usize = 1;
        var i: usize = 1;
        while (i < sorted.len) : (i += 1) {
            if (sorted[i] != sorted[i - 1]) {
                sorted[write] = sorted[i];
                write += 1;
            }
        }
        const canonical = sorted[0..write];
        if (canonical.len == 1) return canonical[0];

        const key: TypeKey = .{ .intersection = canonical };
        return try self.internKey(key, .{ .is_intersection = true });
    }

    pub fn internKeyof(self: *Interner, operand: TypeId) !TypeId {
        const key: TypeKey = .{ .keyof = operand };
        return try self.internKey(key, .{ .is_keyof = true });
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
        const payload: types.ConditionalPayload = .{
            .check_type = check,
            .extends_type = extends_t,
            .true_branch = true_branch,
            .false_branch = false_branch,
        };
        const key: TypeKey = .{ .conditional = payload };
        return try self.internKey(key, .{ .is_conditional = true });
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
        if (!self.pool.flagsOf(id).is_type_parameter) return .bivariant;
        const payload = self.pool.type_parameter_payloads.items[self.pool.payloadOf(id)];
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
        if (!self.pool.flagsOf(id).is_type_parameter) return null;
        const payload = self.pool.type_parameter_payloads.items[self.pool.payloadOf(id)];
        return payload.name;
    }

    /// Intern a function signature type: `(p1: T1, p2: T2) => R`.
    /// `param_types` is consumed via dupe; caller may free its
    /// original copy.
    pub fn internSignature(self: *Interner, param_types: []const TypeId, return_type: TypeId, is_construct: bool) !TypeId {
        const dup = try self.key_arena.allocator().dupe(TypeId, param_types);
        const key: TypeKey = .{ .signature = .{
            .params = dup,
            .return_type = return_type,
            .is_construct = is_construct,
        } };
        return try self.internKey(key, .{ .is_signature = true });
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
        const dup = try self.key_arena.allocator().dupe(types.ObjectMember, members);
        std.mem.sort(types.ObjectMember, dup, {}, objectMemberLessThan);
        const member_start: u32 = @intCast(self.pool.object_member_pool.items.len);
        try self.pool.object_member_pool.appendSlice(self.gpa, dup);
        const payload_idx: u32 = @intCast(self.pool.object_type_payloads.items.len);
        try self.pool.object_type_payloads.append(self.gpa, .{
            .members_start = member_start,
            .members_len = @intCast(dup.len),
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
        if (!self.pool.flagsOf(id).is_object_type) return null;
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.object_type_payloads.items.len) return null;
        const payload = self.pool.object_type_payloads.items[payload_idx];
        const members = self.pool.object_member_pool.items[payload.members_start .. payload.members_start + payload.members_len];
        for (members) |m| {
            if (m.name == name) return m.type;
        }
        return null;
    }

    /// Full-info lookup for a property — returns the ObjectMember
    /// record, or `null` if the type isn't an object or the
    /// property doesn't exist.
    pub fn objectMemberInfo(self: *const Interner, id: TypeId, name: StringId) ?types.ObjectMember {
        if (!self.pool.flagsOf(id).is_object_type) return null;
        const payload_idx = self.pool.payloadOf(id);
        if (payload_idx >= self.pool.object_type_payloads.items.len) return null;
        const payload = self.pool.object_type_payloads.items[payload_idx];
        const members = self.pool.object_member_pool.items[payload.members_start .. payload.members_start + payload.members_len];
        for (members) |m| {
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
        return self.pool.object_member_pool.items[payload.members_start .. payload.members_start + payload.members_len];
    }

    /// Insert a key+flags pair, allocating the side payload as needed.
    /// Returns existing TypeId on a duplicate.
    fn internKey(self: *Interner, key: TypeKey, flags: types.TypeFlags) !TypeId {
        const gop = try self.table.getOrPut(self.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        // Allocate the side payload first, then the header.
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
                    .has_this_type = false,
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
        gop.value_ptr.* = id;
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
        const p = self.pool.intersection_payloads.items[self.pool.payloadOf(id)];
        return self.pool.member_pool.items[p.members_start .. p.members_start + p.members_len];
    }

    pub fn literalOf(self: *const Interner, id: TypeId) types.LiteralData {
        std.debug.assert(self.pool.flagsOf(id).is_literal);
        return self.pool.literal_payloads.items[self.pool.payloadOf(id)];
    }

    pub fn conditionalPayload(self: *const Interner, id: TypeId) types.ConditionalPayload {
        std.debug.assert(self.pool.flagsOf(id).is_conditional);
        return self.pool.conditional_payloads.items[self.pool.payloadOf(id)];
    }

    pub fn mappedPayload(self: *const Interner, id: TypeId) types.MappedPayload {
        std.debug.assert(self.pool.flagsOf(id).is_mapped);
        return self.pool.mapped_payloads.items[self.pool.payloadOf(id)];
    }
};

fn objectMemberLessThan(_: void, a: types.ObjectMember, b: types.ObjectMember) bool {
    return a.name < b.name;
}

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
