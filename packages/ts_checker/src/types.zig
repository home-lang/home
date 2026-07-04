//! Type representation for the TS checker.
//!
//! Per TS_PARITY_PLAN §5.3 / §11.3. Types are addressed by 32-bit
//! `TypeId`s. The first 16 ids are reserved for primitive/literal-type
//! sentinels (matching `hir.reserved_type_ids`), so tests like
//! "is this `any`?" become a single-integer compare.
//!
//! All non-primitive types live in a single `type_pool` indexed by
//! `TypeId`. The intern table at `interner.zig` deduplicates structural
//! types so identity becomes physical equality.
//!
//! tsgo verification (Appendix D.2):
//!   - `TypeId uint32` exists at `internal/checker/types.go:116`.
//!   - **No global intern table** — each Checker constructs its own
//!     types per-file. Cross-checker partitions duplicate work on
//!     identical types.
//!   - Home's globally-interned pool eliminates this redundancy.

const std = @import("std");
const hir = @import("hir");
const string_interner = @import("string_interner");

pub const TypeId = hir.TypeId;
pub const StringId = hir.StringId;

/// Pre-interned primitive/literal-type sentinels. Reserved ids match
/// `hir.reserved_type_ids` so the HIR `types[NodeId]` column can use
/// these directly.
pub const Primitive = struct {
    pub const none: TypeId = 0;
    pub const any: TypeId = 1;
    pub const unknown: TypeId = 2;
    pub const never: TypeId = 3;
    pub const void_t: TypeId = 4;
    pub const null_t: TypeId = 5;
    pub const undefined_t: TypeId = 6;
    pub const string_t: TypeId = 7;
    pub const number_t: TypeId = 8;
    pub const boolean_t: TypeId = 9;
    pub const bigint_t: TypeId = 10;
    pub const symbol_t: TypeId = 11;
    pub const object_t: TypeId = 12;
    pub const true_lit: TypeId = 13;
    pub const false_lit: TypeId = 14;
    /// First TypeId allocated by the interner is 16; everything below
    /// is reserved for primitives. Matches `hir.reserved_type_ids.first_dynamic`.
    pub const first_dynamic: TypeId = 16;
};

/// Bitfield for fast type-category checks. Many relation queries
/// short-circuit based on these flags before touching the structural
/// payload.
pub const TypeFlags = packed struct(u32) {
    is_any: bool = false,
    is_unknown: bool = false,
    is_never: bool = false,
    is_void: bool = false,
    is_null: bool = false,
    is_undefined: bool = false,
    is_string: bool = false,
    is_number: bool = false,
    is_boolean: bool = false,
    is_bigint: bool = false,
    is_symbol: bool = false,
    is_object: bool = false,

    /// `string_lit`, `number_lit`, `bigint_lit`, `boolean_lit`.
    is_literal: bool = false,
    /// Union of two or more types (`A | B`).
    is_union: bool = false,
    /// Intersection of two or more types (`A & B`).
    is_intersection: bool = false,
    /// `T extends U ? X : Y`.
    is_conditional: bool = false,
    /// `{ [K in keyof T]: V }`.
    is_mapped: bool = false,
    /// `T[K]`.
    is_indexed_access: bool = false,
    /// `keyof T`.
    is_keyof: bool = false,
    /// `typeof expr`.
    is_typeof: bool = false,
    /// `infer X` — placeholder inside a conditional type.
    is_infer: bool = false,
    /// Template-literal type, e.g. `` `${A}.${B}` ``.
    is_template_literal: bool = false,
    /// Intrinsic string mapping type, e.g. `Uppercase<T>`.
    is_string_mapping: bool = false,
    /// Tuple type — fixed-arity ordered element types.
    is_tuple: bool = false,
    /// Generic instantiation reference (`Array<T>` after substitution).
    is_instantiation: bool = false,
    /// Type parameter binding (the unresolved `T` inside a generic).
    is_type_parameter: bool = false,
    /// Function/method/constructor signature.
    is_signature: bool = false,
    /// Class/interface object type with declared members.
    is_object_type: bool = false,

    /// Enum-member literal type (`Choice.Yes`). Always combined with
    /// `is_literal` + (`is_number` | `is_string`). Distinguishes an
    /// enum member's fresh literal type from the bare numeric/string
    /// literal that shares its value: `Choice.Yes` is a distinct unit
    /// type that displays as `Choice.Yes`, while plain `1` is not. The
    /// owning enum/member identity is held in the interner's
    /// `enum_literal_info` side-table, keyed by `TypeId`. Mirrors tsc's
    /// `TypeFlagsEnumLiteral` (always paired with String/Number literal).
    is_enum_literal: bool = false,

    _padding: u3 = 0,
};

/// A union literal-type tag. Lives in the `LiteralData` payload of
/// types whose `is_literal` is set.
pub const LiteralTag = enum(u8) {
    string_lit,
    number_lit,
    bigint_lit,
    boolean_lit,
};

pub const LiteralData = union(LiteralTag) {
    string_lit: StringId,
    number_lit: u64, // bit pattern of f64
    bigint_lit: StringId,
    boolean_lit: bool,
};

/// Identity of an enum-member literal type (`Choice.Yes`). Stored in
/// the interner's `enum_literal_info` side-table keyed by the literal
/// `TypeId`. `enum_name` + `member_name` drive the `Enum.Member`
/// display form and the nominal enum-relatedness check; the literal
/// value itself lives in the regular `LiteralData` payload so all
/// existing literal logic (value equality, widening, narrowing)
/// keeps working unchanged.
pub const EnumLiteralInfo = struct {
    enum_name: StringId,
    member_name: StringId,
};

/// Header for every interned type. Side payload is in a separate column
/// indexed by the same `TypeId` (SoA — see `Pool` below).
pub const TypeHeader = struct {
    flags: TypeFlags,
    /// Symbol that introduced this type (class / interface / type alias),
    /// or 0 if synthetic.
    symbol: u32,
    /// Index into the appropriate side-table column (literal_payloads,
    /// union_payloads, …). Zero is a valid "none" sentinel for the
    /// primitive types that have no side payload.
    payload: u32,
};

pub const UnionPayload = struct {
    /// Index into the shared `member_pool`.
    members_start: u32,
    members_len: u32,
};

pub const IntersectionPayload = struct {
    members_start: u32,
    members_len: u32,
};

pub const ConditionalPayload = struct {
    /// `T extends U ? X : Y`.
    check_type: TypeId,
    extends_type: TypeId,
    true_branch: TypeId,
    false_branch: TypeId,
    /// True when the conditional was introduced with a naked type
    /// parameter check type (`T extends U ? ...`) and should distribute
    /// over substitutions of `T`.
    is_distributive: bool = true,
};

pub const MappedPayload = struct {
    /// `K`'s constraint, typically `keyof T`.
    constraint: TypeId,
    /// Property type — `T[K]` or whatever the rhs evaluates to.
    template: TypeId,
    /// `+/- readonly` modifiers.
    readonly: ModifierState,
    /// `+/- ?` modifiers.
    optional: ModifierState,
};

pub const ModifierState = enum(u8) {
    none, // unspecified
    add, // `readonly`, `?`
    remove, // `-readonly`, `-?`
};

pub const IndexedAccessPayload = struct {
    object: TypeId,
    index: TypeId,
};

pub const KeyofPayload = struct {
    operand: TypeId,
};

pub const TemplateLiteralPayload = struct {
    texts_start: u32,
    texts_len: u32,
    types_start: u32,
    types_len: u32,
};

pub const StringMappingKind = enum(u8) {
    lowercase,
    uppercase,
    capitalize,
    uncapitalize,
};

pub const StringMappingPayload = struct {
    kind: StringMappingKind,
    inner: TypeId,
};

pub const TupleElement = struct {
    type: TypeId,
    /// `?` after the element type.
    is_optional: bool,
    /// `...` rest element prefix.
    is_rest: bool,
};

pub const TuplePayload = struct {
    elements_start: u32,
    elements_len: u32,
};

/// Variance of a generic type parameter at its declaration site.
/// Honors the explicit `in` / `out` modifiers introduced in TS 4.7
/// (auto-variance inference is a §3.A.5 follow-up). Matches the
/// HIR-level encoding (`hir.TypeParameterPayload.variance`).
///
///   - `bivariant`: no modifier; default for parameters that don't
///     drive `strictFunctionTypes` flow. Both directions accepted.
///   - `covariant`: `out T` — T appears only in output (read) position.
///     `Foo<Dog>` assigns to `Foo<Animal>`.
///   - `contravariant`: `in T` — T appears only in input (write) position.
///     `Foo<Animal>` assigns to `Foo<Dog>`.
///   - `invariant`: `in out T` — both directions; types must match exactly.
pub const Variance = enum(u8) {
    bivariant = 0,
    contravariant = 1, // `in`
    covariant = 2, //     `out`
    invariant = 3, //     `in out`

    pub fn fromHirBits(bits: u8) Variance {
        return switch (bits) {
            0 => .bivariant,
            1 => .contravariant,
            2 => .covariant,
            3 => .invariant,
            else => .bivariant,
        };
    }
};

pub const TypeParameterPayload = struct {
    name: StringId,
    /// Constraint type (`extends Foo`), `Primitive.none` if none.
    constraint: TypeId,
    /// Default value type (`= Bar`), `Primitive.none` if none.
    default: TypeId,
    /// Declaration-site variance (`in` / `out` modifiers).
    variance: Variance = .bivariant,
    /// TS 5.0 `const` type-parameter modifier. Const parameters use
    /// literal-preserving inference instead of normal widening.
    is_const: bool = false,
};

pub const SignatureParameter = struct {
    name: StringId,
    type: TypeId,
    is_optional: bool,
    is_rest: bool,
};

pub const SignaturePayload = struct {
    type_params_start: u32,
    type_params_len: u32,
    params_start: u32,
    params_len: u32,
    return_type: TypeId,
    /// True for constructor signatures.
    is_construct: bool,
    /// True for `abstract new` constructor signatures.
    is_abstract_construct: bool = false,
    /// True if this is the `this` parameter signature variant.
    has_this_type: bool,
    /// Explicit `this` parameter type when `has_this_type` is true.
    this_type: TypeId = Primitive.none,
};

/// Member accessibility, mirroring TS's legacy `public`/`protected`/
/// `private` modifiers (NOT JS `#private` fields). Default `.public`
/// so the many synthetic `ObjectMember` construction sites compile
/// unchanged; only class field/method lowering populates the non-public
/// variants. The relater consults this to emit TS2325 when a property's
/// visibility differs across two related types.
pub const MemberVisibility = enum(u2) {
    public,
    protected,
    private,
};

pub const ObjectMember = struct {
    name: StringId,
    type: TypeId,
    is_optional: bool,
    is_readonly: bool,
    is_method: bool,
    visibility: MemberVisibility = .public,
    decl_node: hir.NodeId = hir.none_node_id,
};

pub const ObjectTypePayload = struct {
    members_start: u32,
    members_len: u32,
    /// Index of a call-signature into `signature_payloads`, or 0.
    call_sig: u32,
    /// Index of a construct-signature, or 0.
    construct_sig: u32,
    /// Index-signature: `[k: string]: V` lowered as a single signature.
    string_index_type: TypeId,
    number_index_type: TypeId,
    symbol_index_type: TypeId,
};

pub const InstantiationPayload = struct {
    /// The generic origin (a class/interface/type-alias type).
    origin: TypeId,
    /// Type-argument slice into `type_arg_pool`.
    args_start: u32,
    args_len: u32,
};

/// SoA pool of all interned types. The `Interner` (in `interner.zig`)
/// owns this and exposes the `intern()` API.
pub const Pool = struct {
    gpa: std.mem.Allocator,

    headers: std.ArrayListUnmanaged(TypeHeader),
    /// Per-kind side tables. Index 0 of each is reserved as "no payload."
    literal_payloads: std.ArrayListUnmanaged(LiteralData),
    union_payloads: std.ArrayListUnmanaged(UnionPayload),
    intersection_payloads: std.ArrayListUnmanaged(IntersectionPayload),
    conditional_payloads: std.ArrayListUnmanaged(ConditionalPayload),
    mapped_payloads: std.ArrayListUnmanaged(MappedPayload),
    indexed_access_payloads: std.ArrayListUnmanaged(IndexedAccessPayload),
    keyof_payloads: std.ArrayListUnmanaged(KeyofPayload),
    template_literal_payloads: std.ArrayListUnmanaged(TemplateLiteralPayload),
    string_mapping_payloads: std.ArrayListUnmanaged(StringMappingPayload),
    tuple_payloads: std.ArrayListUnmanaged(TuplePayload),
    type_parameter_payloads: std.ArrayListUnmanaged(TypeParameterPayload),
    signature_payloads: std.ArrayListUnmanaged(SignaturePayload),
    object_type_payloads: std.ArrayListUnmanaged(ObjectTypePayload),
    instantiation_payloads: std.ArrayListUnmanaged(InstantiationPayload),

    /// Variable-arity element pools.
    member_pool: std.ArrayListUnmanaged(TypeId),
    string_id_pool: std.ArrayListUnmanaged(StringId),
    tuple_element_pool: std.ArrayListUnmanaged(TupleElement),
    type_arg_pool: std.ArrayListUnmanaged(TypeId),
    signature_param_pool: std.ArrayListUnmanaged(SignatureParameter),
    object_member_pool: std.ArrayListUnmanaged(ObjectMember),

    pub fn init(gpa: std.mem.Allocator) !Pool {
        var p: Pool = .{
            .gpa = gpa,
            .headers = .empty,
            .literal_payloads = .empty,
            .union_payloads = .empty,
            .intersection_payloads = .empty,
            .conditional_payloads = .empty,
            .mapped_payloads = .empty,
            .indexed_access_payloads = .empty,
            .keyof_payloads = .empty,
            .template_literal_payloads = .empty,
            .string_mapping_payloads = .empty,
            .tuple_payloads = .empty,
            .type_parameter_payloads = .empty,
            .signature_payloads = .empty,
            .object_type_payloads = .empty,
            .instantiation_payloads = .empty,
            .member_pool = .empty,
            .string_id_pool = .empty,
            .tuple_element_pool = .empty,
            .type_arg_pool = .empty,
            .signature_param_pool = .empty,
            .object_member_pool = .empty,
        };
        // Reserve slot 0 in every payload column ("no payload").
        try p.literal_payloads.append(gpa, .{ .boolean_lit = false });
        try p.union_payloads.append(gpa, .{ .members_start = 0, .members_len = 0 });
        try p.intersection_payloads.append(gpa, .{ .members_start = 0, .members_len = 0 });
        try p.conditional_payloads.append(gpa, std.mem.zeroes(ConditionalPayload));
        try p.mapped_payloads.append(gpa, std.mem.zeroes(MappedPayload));
        try p.indexed_access_payloads.append(gpa, std.mem.zeroes(IndexedAccessPayload));
        try p.keyof_payloads.append(gpa, .{ .operand = Primitive.none });
        try p.template_literal_payloads.append(gpa, std.mem.zeroes(TemplateLiteralPayload));
        try p.string_mapping_payloads.append(gpa, .{ .kind = .lowercase, .inner = Primitive.none });
        try p.tuple_payloads.append(gpa, .{ .elements_start = 0, .elements_len = 0 });
        try p.type_parameter_payloads.append(gpa, std.mem.zeroes(TypeParameterPayload));
        try p.signature_payloads.append(gpa, std.mem.zeroes(SignaturePayload));
        try p.object_type_payloads.append(gpa, std.mem.zeroes(ObjectTypePayload));
        try p.instantiation_payloads.append(gpa, std.mem.zeroes(InstantiationPayload));
        try p.member_pool.append(gpa, Primitive.none);
        try p.string_id_pool.append(gpa, 0);
        try p.tuple_element_pool.append(gpa, .{ .type = Primitive.none, .is_optional = false, .is_rest = false });
        try p.type_arg_pool.append(gpa, Primitive.none);
        try p.signature_param_pool.append(gpa, std.mem.zeroes(SignatureParameter));
        try p.object_member_pool.append(gpa, std.mem.zeroes(ObjectMember));

        // Populate the primitive header table — ids 0..15.
        try p.headers.append(gpa, .{ .flags = .{}, .symbol = 0, .payload = 0 }); // none
        try p.headers.append(gpa, .{ .flags = .{ .is_any = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_unknown = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_never = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_void = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_null = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_undefined = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_string = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_number = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_boolean = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_bigint = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_symbol = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_object = true }, .symbol = 0, .payload = 0 });
        try p.headers.append(gpa, .{ .flags = .{ .is_boolean = true, .is_literal = true }, .symbol = 0, .payload = 0 }); // true_lit
        try p.headers.append(gpa, .{ .flags = .{ .is_boolean = true, .is_literal = true }, .symbol = 0, .payload = 0 }); // false_lit
        try p.headers.append(gpa, .{ .flags = .{}, .symbol = 0, .payload = 0 }); // reserved 15

        std.debug.assert(p.headers.items.len == Primitive.first_dynamic);

        return p;
    }

    pub fn deinit(self: *Pool) void {
        const g = self.gpa;
        self.headers.deinit(g);
        self.literal_payloads.deinit(g);
        self.union_payloads.deinit(g);
        self.intersection_payloads.deinit(g);
        self.conditional_payloads.deinit(g);
        self.mapped_payloads.deinit(g);
        self.indexed_access_payloads.deinit(g);
        self.keyof_payloads.deinit(g);
        self.template_literal_payloads.deinit(g);
        self.string_mapping_payloads.deinit(g);
        self.tuple_payloads.deinit(g);
        self.type_parameter_payloads.deinit(g);
        self.signature_payloads.deinit(g);
        self.object_type_payloads.deinit(g);
        self.instantiation_payloads.deinit(g);
        self.member_pool.deinit(g);
        self.string_id_pool.deinit(g);
        self.tuple_element_pool.deinit(g);
        self.type_arg_pool.deinit(g);
        self.signature_param_pool.deinit(g);
        self.object_member_pool.deinit(g);
    }

    pub fn flagsOf(self: *const Pool, id: TypeId) TypeFlags {
        return self.headers.items[id].flags;
    }

    pub fn payloadOf(self: *const Pool, id: TypeId) u32 {
        return self.headers.items[id].payload;
    }

    pub fn typeCount(self: *const Pool) u32 {
        return @intCast(self.headers.items.len);
    }
};

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "Pool: primitive ids match hir.reserved_type_ids" {
    var p = try Pool.init(T.allocator);
    defer p.deinit();
    try T.expectEqual(hir.reserved_type_ids.any, Primitive.any);
    try T.expectEqual(hir.reserved_type_ids.string_t, Primitive.string_t);
    try T.expectEqual(hir.reserved_type_ids.true_lit, Primitive.true_lit);
    try T.expectEqual(hir.reserved_type_ids.first_dynamic, Primitive.first_dynamic);
}

test "Pool: primitives have the expected flags" {
    var p = try Pool.init(T.allocator);
    defer p.deinit();
    try T.expect(p.flagsOf(Primitive.any).is_any);
    try T.expect(p.flagsOf(Primitive.unknown).is_unknown);
    try T.expect(p.flagsOf(Primitive.never).is_never);
    try T.expect(p.flagsOf(Primitive.string_t).is_string);
    try T.expect(p.flagsOf(Primitive.number_t).is_number);
    try T.expect(p.flagsOf(Primitive.boolean_t).is_boolean);
    try T.expect(p.flagsOf(Primitive.true_lit).is_literal);
    try T.expect(p.flagsOf(Primitive.true_lit).is_boolean);
    try T.expect(p.flagsOf(Primitive.false_lit).is_literal);
}

test "Pool: typeCount starts at first_dynamic" {
    var p = try Pool.init(T.allocator);
    defer p.deinit();
    try T.expectEqual(Primitive.first_dynamic, p.typeCount());
}

test "TypeFlags: 4 bytes" {
    try T.expectEqual(@as(usize, 4), @sizeOf(TypeFlags));
}
