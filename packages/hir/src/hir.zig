//! HIR — High-level Intermediate Representation.
//!
//! Per TS_PARITY_PLAN §5.2 ("the single most important data-structure
//! decision"). HIR is the shared IR consumed by both the Home and TS
//! frontends after binding, and produced for the type checker, JS
//! emitter, declaration emitter, and native codegen.
//!
//! Layout: struct-of-arrays.
//!
//!     kinds   : []NodeKind   //  1 B/node
//!     spans   : []Span       //  8 B/node (start: u32, end: u32)
//!     parents : []NodeId     //  4 B/node
//!     types   : []TypeId     //  4 B/node — populated post-bind
//!     payloads: []u32        //  4 B/node — per-kind side-table index
//!
//! That's 21 bytes for the always-present hot fields, with payload
//! indices selecting into per-kind columns (e.g., `binop_payloads`,
//! `call_payloads`) where the kind-specific data lives. Average over a
//! representative TS workload is ~24 B/node — versus tsgo's verified
//! ~120–130 B/node (`internal/ast/ast.go:178` + per-kind concrete
//! struct via interface dispatch).
//!
//! Why this matters: the type-checker spends most of its time iterating
//! `(kind, type)` pairs and following parent links. SoA wins this by
//! 4–8× on cache-line utilization vs. tsgo's pointer tree.
//!
//! Reserved indices:
//!
//!   - `none_node_id = 0` is the "no such node" sentinel. Every column
//!     reserves index 0; `Hir.kindOf(none_node_id) == .none`.
//!   - Reserved primitive `TypeId`s in `0..16` (Tier 1 §11.3): commonly
//!     queried types (`any`, `unknown`, `never`, `void`, `null`,
//!     `undefined`, `string`, `number`, `boolean`, `bigint`, `symbol`,
//!     `object`, `true_lit`, `false_lit`, plus two reserved). Comparisons
//!     against these can short-circuit the relation cache entirely.
//!
//! Hot/cold split (Tier 1 §11.4): rare fields (JSDoc text, original
//! source comment text, debug names) are *not* in the per-node columns;
//! they live in `cold_jsdoc`, `cold_debug` side tables keyed by node id.
//! Hot iteration ignores them.

const std = @import("std");
const string_interner = @import("string_interner");

pub const StringId = string_interner.StringId;

/// 32-bit node identifier. Index into the HIR's column arrays.
/// Node 0 is the reserved "none" sentinel.
pub const NodeId = u32;
pub const none_node_id: NodeId = 0;

/// 32-bit type identifier. Top 16 ids reserved for primitive types
/// (Tier 1 §11.3 bit-packed primitives).
pub const TypeId = u32;

pub const reserved_type_ids = struct {
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
    /// First TypeId allocated by the interner is 16; everything below is
    /// reserved for primitives. Test assertion enforces this in the
    /// future type-interner.
    pub const first_dynamic: TypeId = 16;
};

pub const Span = struct {
    /// Byte offset into the source where this node starts.
    start: u32,
    /// Byte offset where this node ends (exclusive).
    end: u32,

    pub fn empty() Span {
        return .{ .start = 0, .end = 0 };
    }

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }
};

/// HIR node kind. The set is *open* — Phase 1 (TS frontend) and the
/// existing Home AST will both register their kinds here. We start with
/// the kinds the type checker needs to recognize categorically; per-kind
/// payload columns are added incrementally as features land.
///
/// Reserved: `none = 0` so the all-zeros column initialization implies
/// "no node here."
pub const NodeKind = enum(u8) {
    /// Sentinel — index 0 of every column.
    none = 0,

    // ----- Module-level -----
    source_file,

    // ----- Declarations -----
    fn_decl,
    var_decl,
    let_decl,
    const_decl,
    type_alias_decl,
    interface_decl,
    class_decl,
    enum_decl,
    namespace_decl,
    module_decl,
    import_decl,
    export_decl,

    // ----- Statements -----
    block_stmt,
    if_stmt,
    while_stmt,
    do_while_stmt,
    for_stmt,
    for_in_stmt,
    for_of_stmt,
    return_stmt,
    break_stmt,
    continue_stmt,
    throw_stmt,
    try_stmt,
    switch_stmt,
    expression_stmt,
    labeled_stmt,

    // ----- Expressions -----
    identifier,
    literal_string,
    literal_number,
    literal_bigint,
    literal_bool,
    literal_null,
    literal_undefined,
    literal_regex,
    template_literal,
    array_literal,
    object_literal,
    binary_op,
    unary_op,
    update_op,
    logical_op,
    assignment,
    conditional,
    call_expr,
    new_expr,
    member_access,
    element_access,
    arrow_fn,
    fn_expr,
    class_expr,
    type_assertion,
    satisfies_expr,
    as_expr,
    non_null_expr,
    index_signature,
    spread,
    yield_expr,
    await_expr,
    this_expr,
    super_expr,
    new_target,
    import_meta,
    import_call,

    // ----- Types -----
    type_ref,
    type_literal,
    union_type,
    intersection_type,
    conditional_type,
    mapped_type,
    indexed_access_type,
    keyof_type,
    typeof_type,
    readonly_type,
    infer_type,
    template_literal_type,
    tuple_type,
    array_type,
    fn_type,
    constructor_type,
    /// `T?` optional element marker inside a tuple type. Only meaningful
    /// as a child of `tuple_type`.
    optional_type,
    /// `...T` rest element inside a tuple type (variadic tuple
    /// support). Only meaningful as a child of `tuple_type`.
    rest_type,
    object_type,
    /// `arg is T` or `asserts arg is T` in return-type position.
    type_predicate_type,

    // ----- JSX (TS frontend) -----
    jsx_element,
    jsx_self_closing,
    jsx_fragment,
    jsx_attribute,
    jsx_spread_attribute,
    jsx_expression,
    jsx_text,

    // ----- Patterns -----
    object_pattern,
    array_pattern,
    rest_pattern,

    // ----- Misc -----
    parameter,
    type_parameter,
    decorator,
    switch_case,
    import_specifier,
    export_specifier,
    object_property,
    enum_member,
    interface_member,

    /// Returns true if the kind is in the "expression" category.
    pub fn isExpression(self: NodeKind) bool {
        const v = @intFromEnum(self);
        if (v >= @intFromEnum(NodeKind.identifier) and
            v <= @intFromEnum(NodeKind.import_call)) return true;
        return self == .jsx_element or
            self == .jsx_self_closing or
            self == .jsx_fragment or
            self == .jsx_expression or
            self == .jsx_text;
    }

    /// Returns true if the kind is in the "type" category.
    pub fn isType(self: NodeKind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(NodeKind.type_ref) and
            v <= @intFromEnum(NodeKind.object_type);
    }

    /// Returns true if the kind is in the "statement" category (excludes
    /// declarations, which are conventionally separate).
    pub fn isStatement(self: NodeKind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(NodeKind.block_stmt) and
            v <= @intFromEnum(NodeKind.labeled_stmt);
    }

    /// Returns true if the kind is in the "declaration" category.
    pub fn isDeclaration(self: NodeKind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(NodeKind.fn_decl) and
            v <= @intFromEnum(NodeKind.export_decl);
    }
};

/// Binary operator (subset of TS/Home operators; expanded as Phase 1
/// frontends land).
pub const BinOp = enum(u8) {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    eq,
    neq,
    eq_strict,
    neq_strict,
    lt,
    le,
    gt,
    ge,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    shr_unsigned,
    instanceof,
    in,
    comma,
    // Logical-assignment operators (`||=`, `&&=`, `??=`). Only valid as an
    // `AssignmentPayload.op` (the non-assigning `||`/`&&`/`??` use
    // `LogicalOp`, a separate enum). ES2021.
    logical_or,
    logical_and,
    nullish_coalesce,
};

pub const UnaryOp = enum(u8) {
    neg,
    plus,
    not,
    bit_not,
    typeof,
    void_,
    delete,
};

pub const LogicalOp = enum(u8) {
    @"and", // &&
    @"or", // ||
    nullish, // ??
};

pub const UpdateOp = enum(u8) {
    pre_inc,
    post_inc,
    pre_dec,
    post_dec,
};

// ============================================================================
// Per-kind payload columns
// ============================================================================
//
// Each "shape" of node has a side-table column. The hot-path `payloads`
// column on `Hir` stores a u32 *index* into the appropriate side table
// (the kind tells you which side table to consult).
//
// We intentionally keep these small and fixed-width. Nodes with variable
// arity (call args, block stmts, type-param lists) reference contiguous
// slices in the shared `child_pool` indexed by `(start, len)`.

pub const BinopPayload = struct {
    lhs: NodeId,
    rhs: NodeId,
    op: BinOp,
};

pub const UnaryPayload = struct {
    operand: NodeId,
    op: UnaryOp,
};

pub const LogicalPayload = struct {
    lhs: NodeId,
    rhs: NodeId,
    op: LogicalOp,
};

pub const UpdatePayload = struct {
    operand: NodeId,
    op: UpdateOp,
};

pub const CallPayload = struct {
    callee: NodeId,
    /// Children-pool slice: arguments.
    args_start: u32,
    args_len: u16,
    /// Children-pool slice: type arguments (for `f<T>(x)`).
    type_args_start: u32,
    type_args_len: u16,
    /// True for `?.(...)` optional call chains.
    optional: bool,
    /// True when this call is the desugaring of a tagged template
    /// (`tag`…``): arg 0 is the cooked-strings array, args 1.. are the
    /// substitutions. The emitter re-renders it natively as `` tag`…` ``.
    is_tagged_template: bool = false,
};

pub const MemberPayload = struct {
    object: NodeId,
    /// Property name as an interned string.
    name: StringId,
    /// True for `?.` (optional chaining).
    optional: bool,
};

pub const ElementPayload = struct {
    object: NodeId,
    index: NodeId,
    optional: bool,
};

pub const IdentifierPayload = struct {
    name: StringId,
};

pub const LiteralStringPayload = struct {
    /// Interned string content (after escape resolution).
    value: StringId,
};

pub const LiteralNumberPayload = struct {
    /// IEEE-754 binary representation. We store as u64 so layout is
    /// stable across cross-compilation targets.
    bits: u64,
};

pub const LiteralBigIntPayload = struct {
    /// Interned digit string (decimal, no `n` suffix). We defer
    /// arbitrary-precision arithmetic to the type checker.
    digits: StringId,
};

pub const LiteralBoolPayload = struct {
    value: bool,
};

pub const ConditionalPayload = struct {
    cond: NodeId,
    then_branch: NodeId,
    else_branch: NodeId,
};

pub const AssignmentPayload = struct {
    target: NodeId,
    value: NodeId,
    /// Compound assignment op (e.g. `+=`); `none` for plain `=`.
    op: ?BinOp,
};

pub const BlockPayload = struct {
    /// Children-pool slice: statements in this block.
    stmts_start: u32,
    stmts_len: u32,
};

pub const IfPayload = struct {
    cond: NodeId,
    then_branch: NodeId,
    /// `none_node_id` if no else.
    else_branch: NodeId,
};

pub const ReturnPayload = struct {
    /// `none_node_id` if `return;`.
    value: NodeId,
};

pub const WhilePayload = struct {
    cond: NodeId,
    body: NodeId,
};

pub const DoWhilePayload = struct {
    body: NodeId,
    cond: NodeId,
};

/// Classic three-part `for (init; cond; update) body`. Any of the
/// header slots may be `none_node_id`.
pub const ForPayload = struct {
    init: NodeId,
    cond: NodeId,
    update: NodeId,
    body: NodeId,
};

/// `for (let x in obj) body` and `for (let x of iter) body`. The
/// kind on the node distinguishes the two forms.
pub const ForInOfPayload = struct {
    /// Binding declaration or expression on the left of `in` / `of`.
    target: NodeId,
    /// Right-hand side expression.
    source: NodeId,
    body: NodeId,
    /// `for await (... of ...)` async-iteration form. Only valid for
    /// `for_of_stmt`.
    is_await: bool = false,
};

pub const ThrowPayload = struct {
    value: NodeId,
};

pub const TryPayload = struct {
    block: NodeId,
    /// `none_node_id` if no catch clause.
    catch_param: NodeId,
    /// `none_node_id` if no catch clause.
    catch_block: NodeId,
    /// `none_node_id` if no finally clause.
    finally_block: NodeId,
};

/// `case <value>: <stmts...>` and `default: <stmts...>`. `value`
/// is `none_node_id` for the default clause.
pub const SwitchCasePayload = struct {
    value: NodeId,
    /// Children pool slice: case body statements.
    stmts_start: u32,
    stmts_len: u32,
};

pub const SwitchPayload = struct {
    discriminant: NodeId,
    /// Children pool slice: switch_case nodes.
    cases_start: u32,
    cases_len: u32,
};

pub const LabelPayload = struct {
    /// `none_node_id` for an unlabeled `break` / `continue`.
    label: NodeId,
};

/// `L: <stmt>` — a labeled statement. `label` is the identifier node, and
/// `body` the labeled statement (commonly a loop or block).
pub const LabeledStmtPayload = struct {
    label: NodeId,
    body: NodeId,
};

pub const FnDeclPayload = struct {
    /// Function name. `none_node_id` for anonymous function expression.
    name: NodeId,
    /// Children pool slice: type-parameter nodes
    /// (`type_parameter` kind) for generic functions. Empty for
    /// non-generic decls.
    type_params_start: u32,
    type_params_len: u32,
    /// Children pool slice: parameter nodes (`parameter` kind).
    params_start: u32,
    params_len: u32,
    /// Return-type type node, or `none_node_id`.
    return_type: NodeId,
    /// Body block, or `none_node_id` for ambient declarations.
    body: NodeId,
    flags: FnFlags,
};

pub const FnFlags = packed struct(u16) {
    is_async: bool = false,
    is_generator: bool = false,
    is_arrow: bool = false,
    is_expression: bool = false,
    is_method: bool = false,
    is_constructor: bool = false,
    is_getter: bool = false,
    is_setter: bool = false,
    /// TS legacy `private` modifier on a class method.
    is_private: bool = false,
    /// TS legacy `protected` modifier on a class method.
    /// Accessible from within the declaring class and any
    /// subclass (transitive `extends` chain).
    is_protected: bool = false,
    /// TS/JS `static` class method modifier.
    is_static: bool = false,
    /// TS 4.3 `override` modifier on a class method.
    is_override: bool = false,
    /// TS `abstract` modifier on a class method.
    is_abstract: bool = false,
    /// TS optional-method modifier: `foo?(): T`. Bodyless optional
    /// methods do NOT require a subsequent implementation; the
    /// checker uses this to suppress TS2389 mismatches.
    is_optional: bool = false,
    /// Parser-recovery marker for an already-diagnosed malformed tail
    /// after a signature (for example `function f(...) => ...` or
    /// `class C { m()?: T }`). Used by the checker to suppress TS2391
    /// ("Function implementation is missing ...") on these declarations,
    /// since tsc treats the parser diagnostic as covering the broken shape.
    has_errant_arrow: bool = false,
    _pad: u1 = 0,
};

pub const ParameterPayload = struct {
    name: NodeId,
    /// `none_node_id` if no annotation.
    type_annotation: NodeId,
    /// `none_node_id` if no default value.
    default_value: NodeId,
    /// True for `?:` optional parameter, rest params (`...x`), etc.
    flags: ParamFlags,
    /// Slice into `child_pool` for parameter decorators (`@inject`).
    /// Length 0 when none. Used by the emitter to produce
    /// `__param(N, dec)` calls during legacy decorator emission.
    decorators_start: u32 = 0,
    decorators_len: u16 = 0,
};

pub const ParamFlags = packed struct(u16) {
    is_optional: bool = false,
    is_rest: bool = false,
    is_readonly: bool = false,
    /// Synthetic pattern element carrying an object binding computed-key
    /// expression (`{ [expr]: name }`). It is not a binding slot.
    is_computed_binding_key: bool = false,
    /// True when the constructor parameter declares an instance
    /// property via `public` / `protected` / `private` / `readonly`.
    is_parameter_property: bool = false,
    /// TS 4.3 `override` modifier on a constructor parameter property.
    is_override: bool = false,
    is_private: bool = false,
    is_protected: bool = false,
    /// Synthetic pattern element carrying an object binding *rename* key
    /// (`{ key: target }`). The key identifier is stored in the element's
    /// `default_value`; the following element is the binding target.
    is_rename_binding_key: bool = false,
    _pad: u7 = 0,
};

pub const TypeAliasPayload = struct {
    name: NodeId,
    /// Children pool slice: type-parameter nodes.
    type_params_start: u32,
    type_params_len: u32,
    /// The aliased type node.
    aliased: NodeId,
};

pub const InterfacePayload = struct {
    name: NodeId,
    /// Children pool slice: type-parameter nodes.
    type_params_start: u32,
    type_params_len: u32,
    /// Children pool slice: extends type references.
    extends_start: u32,
    extends_len: u32,
    /// Children pool slice: member nodes (signatures).
    members_start: u32,
    members_len: u32,
};

pub const ClassPayload = struct {
    /// `none_node_id` for a class expression with no name.
    name: NodeId,
    /// Children pool slice: type-parameter nodes.
    type_params_start: u32,
    type_params_len: u32,
    /// Optional `extends` parent expression.
    extends: NodeId,
    /// Children pool slice: implements type refs.
    implements_start: u32,
    implements_len: u32,
    /// Children pool slice: class member nodes.
    members_start: u32,
    members_len: u32,
    /// True if the class declaration was prefixed with `abstract`.
    /// Abstract classes can't be instantiated directly (TS2511) and
    /// may declare abstract members that subclasses must implement.
    is_abstract: bool = false,
};

pub const EnumPayload = struct {
    name: NodeId,
    /// Children pool slice: enum-member nodes.
    members_start: u32,
    members_len: u32,
    is_const: bool,
};

pub const NamespacePayload = struct {
    name: NodeId,
    /// Children pool slice: statements / nested decls.
    body_start: u32,
    body_len: u32,
};

pub const ImportPayload = struct {
    /// Module specifier as an interned string.
    module: StringId,
    /// Source position of the module string literal's opening quote. Keeping
    /// the parser's token position lets diagnostics report on the actual
    /// module specifier instead of rediscovering it from statement text.
    module_specifier_pos: ?u32 = null,
    /// `none_node_id` if no default-import binding (`import x from "m"`).
    default_binding: NodeId,
    /// `none_node_id` if no namespace import (`import * as ns from "m"`).
    namespace_binding: NodeId,
    /// Qualified entity name for `import Alias = Namespace.Member`.
    /// `none_node_id` for ES imports and `import Alias = require("m")`.
    import_equals: NodeId,
    /// Children pool slice: named-import-specifier nodes.
    named_start: u32,
    named_len: u32,
    /// True for `import type ...`.
    is_type_only: bool,
    /// True for an import-equals declaration carrying the `export`
    /// modifier (`export import Foo = ns.Foo;`). Only meaningful when
    /// `import_equals != none_node_id`. Used by the checker to surface
    /// TS1269 ("Cannot use 'export import' on a type or type-only
    /// namespace …") when the alias target resolves to a type.
    is_export: bool = false,
    /// True for `import name = require("module")` — distinguishes it from a
    /// plain default import (same `default_binding`/`module` shape).
    /// Lowered to `const name = require("module");`.
    is_require_equals: bool = false,
    /// True for a deferred import (`import defer * as ns from "m"`). Drives
    /// the checker's TS18058/TS18059/TS18060 grammar diagnostics.
    is_deferred: bool = false,
    /// Source span of the deferred import clause (`defer * as ns`), used to
    /// anchor the deferred-import grammar diagnostics. Only meaningful when
    /// `is_deferred` is true.
    deferred_clause_start: u32 = 0,
    deferred_clause_end: u32 = 0,
};

pub const ExportPayload = struct {
    /// `none_node_id` if no declaration is being re-exported (e.g.
    /// `export { a, b }`).
    decl: NodeId,
    /// Children pool slice: named-export-specifier nodes.
    named_start: u32,
    named_len: u32,
    /// `string_interner.empty_id` if this isn't a re-export.
    module: StringId,
    is_type_only: bool,
    is_default: bool,
    /// `export * from "m"` / `export * as ns from "m"`. When set,
    /// `module` is non-empty and `named_len` is 0.
    is_namespace: bool,
    /// For `export * as ns from "m"` — the local namespace binding,
    /// or `string_interner.empty_id` for plain `export *`.
    namespace_alias: StringId,
    namespace_alias_is_string_literal: bool = false,
    namespace_alias_pos: u32 = 0,
    /// True for a TypeScript `export = <expr>;` assignment (CommonJS-style
    /// default export). `decl` holds the exported expression. Lowered to
    /// `module.exports = <expr>;`.
    is_export_equals: bool = false,
};

pub const ImportSpecifierPayload = struct {
    /// Imported name in the foreign module.
    imported: StringId,
    /// Local binding (defaults to `imported` if no `as` rename).
    local: StringId,
    is_type_only: bool,
    imported_is_string_literal: bool = false,
    local_is_string_literal: bool = false,
    imported_pos: u32 = 0,
    local_pos: u32 = 0,
};

pub const ArrayLiteralPayload = struct {
    /// Children pool slice: element expressions (or `none_node_id` for holes).
    elements_start: u32,
    elements_len: u32,
};

pub const ObjectLiteralPayload = struct {
    /// Children pool slice: property nodes.
    props_start: u32,
    props_len: u32,
};

/// TS member visibility. Applies to class fields and methods.
/// For object-literal properties this stays `.public`. The
/// `private` keyword is the legacy TS modifier (compile-time
/// only) — distinct from JS `#field` (runtime-private), which
/// is modeled separately via the identifier's leading `#`.
pub const Visibility = enum(u2) {
    public,
    protected,
    private,
};

pub const ObjectPropertyPayload = struct {
    /// Property key — identifier, string, number, or computed expression.
    key: NodeId,
    /// Property value.
    value: NodeId,
    /// Optional type annotation (for class fields with `: T`).
    /// `none_node_id` if no annotation.
    type_annotation: NodeId,
    is_computed: bool,
    is_shorthand: bool,
    is_method: bool,
    /// TS/JS `static` class field modifier.
    is_static: bool = false,
    /// TS legacy member visibility. `.public` for object-literal
    /// props. Class field/method parsing sets it from the modifier
    /// keyword consumed before the name.
    visibility: Visibility = .public,
    /// TS 4.3 `override` modifier on a class field/accessor property.
    is_override: bool = false,
    /// TS 4.9 / Stage 3 `accessor` modifier on a class field. The
    /// field becomes an auto-generated paired getter/setter backed
    /// by a private storage slot; Stage 3 decorators receive
    /// `kind: "accessor"` in their context object.
    is_accessor: bool = false,
};

// ============================================================================
// Type-system node payloads
// ============================================================================
//
// HIR carries type annotations as a separate node graph; the same `Hir`
// stores both expression nodes and type nodes, distinguished by kind
// (NodeKind.type_ref through NodeKind.constructor_type).
//
// Phase 1 follow-up: the type parser produces these nodes; the type
// checker (Phase 3) consumes them via `hir.Pool` lowering to TypeIds.

/// `Foo`, `Foo.Bar`, `Foo<T, U>`. The base reference is identified via
/// a name (interned string) for `Foo`; qualified-name continuations
/// chain through `qualifier` references.
pub const TypeRefPayload = struct {
    /// Name of the referenced type. For qualified names like
    /// `A.B.C`, this stores the *rightmost* segment; the qualifier
    /// chain lives in `qualifier_start..len`.
    name: StringId,
    /// Children pool slice: type-argument nodes (for `Foo<T, U>`).
    args_start: u32,
    args_len: u32,
    /// Children pool slice: qualifier identifiers (`A.B.C` stores
    /// `[A, B]` here; `name` is `C`).
    qualifier_start: u32,
    qualifier_len: u32,
};

/// `T | U | V`.
pub const UnionTypePayload = struct {
    members_start: u32,
    members_len: u32,
};

/// `T & U & V`.
pub const IntersectionTypePayload = struct {
    members_start: u32,
    members_len: u32,
};

/// `T[]` — postfix array shorthand.
pub const ArrayTypePayload = struct {
    element: NodeId,
};

/// `[T, U, V]`.
pub const TupleTypePayload = struct {
    elements_start: u32,
    elements_len: u32,
};

/// `T?` optional element inside a tuple type. Only valid as a
/// tuple-type element.
pub const OptionalTypePayload = struct {
    operand: NodeId,
};

/// `...T` element inside a tuple type. Only valid as a tuple-type
/// element. When `T` is an array type (`U[]`) the rest expands to
/// any number of `U` elements; when `T` is itself a tuple it
/// expands inline.
pub const RestTypePayload = struct {
    operand: NodeId,
};

/// `(a: T, b?: U) => R` and `new (a: T) => R`.
pub const FnTypePayload = struct {
    params_start: u32,
    params_len: u32,
    type_params_start: u32,
    type_params_len: u32,
    return_type: NodeId,
    is_constructor: bool,
    is_abstract_constructor: bool = false,
};

/// `T[K]`.
pub const IndexedAccessTypePayload = struct {
    object: NodeId,
    index: NodeId,
};

/// `keyof T`.
pub const KeyofTypePayload = struct {
    operand: NodeId,
};

/// `typeof expr` (TS, in type position).
pub const TypeofTypePayload = struct {
    operand: NodeId,
};

/// `readonly T` in type position. The checker keeps this wrapper for grammar
/// parity, then lowering unwraps it to the operand's semantic type.
pub const ReadonlyTypePayload = struct {
    operand: NodeId,
    operand_parenthesized: bool,
};

/// `\`hello ${name}\`` — template-literal *expression* (value
/// position). Text parts are `literal_string` HIR nodes; there
/// are exactly `exprs_len + 1` of them.
pub const TemplateLiteralPayload = struct {
    texts_start: u32,
    texts_len: u16,
    exprs_start: u32,
    exprs_len: u16,
};

/// `\`hello-${T}-${U}\`` — template-literal type.
/// `text_parts` and `type_parts` interleave: there are exactly
/// `type_parts.len + 1` text parts. For `\`a${T}b${U}c\``,
/// text_parts = ["a", "b", "c"], type_parts = [T, U].
pub const TemplateLiteralTypePayload = struct {
    /// Slice into `child_pool` of NodeIds — each is a `literal_string`
    /// HIR node holding the constant chunk's source text. Length
    /// always equals `type_parts_len + 1`.
    text_parts_start: u32,
    text_parts_len: u16,
    /// Slice into `child_pool` — each is a type-position HIR node
    /// (e.g. `type_ref`).
    type_parts_start: u32,
    type_parts_len: u16,
};

/// `arg is T` or `asserts arg is T` in return-type position. The
/// param_index records which positional parameter `arg` refers to
/// (resolved at parse time) so the checker can apply narrowing on
/// the argument at call sites.
pub const TypePredicatePayload = struct {
    /// 0xFFFF when the predicate is on `this` (`this is T`).
    param_index: u16,
    /// Interned name of the parameter (or "this") — informational.
    param_name: StringId,
    /// The asserted type.
    target_type: NodeId,
    /// True for `asserts arg is T` (assertion function — narrows in
    /// fall-through, not just then-branch).
    is_asserts: bool,
};

/// `expr as T` / `expr satisfies T` / `<T>expr` (legacy form). All
/// three share the same shape — the kind enum disambiguates.
pub const AsExpressionPayload = struct {
    expr: NodeId,
    type_node: NodeId,
};

/// `[k: K]: V` index signature inside an interface or object type.
pub const IndexSignaturePayload = struct {
    /// Key type — typically a `type_ref` to `string` or `number`.
    key_type: NodeId,
    /// Value type — the type of any indexed access.
    value_type: NodeId,
    is_readonly: bool,
    /// `static [k: string]: T` inside a class declares an indexer
    /// on the constructor side, not on instances.
    is_static: bool = false,
    /// The declared index parameter name (`key` in `[key: string]: T`),
    /// preserved so diagnostic prose can render the user's chosen
    /// name instead of the synthetic `x`. `0` (unset) means the name
    /// was not captured; renderers then fall back to tsc's default
    /// `x`. Mirrors upstream `getNameFromIndexInfo`.
    key_name: StringId = 0,
};

/// `T extends U ? X : Y`.
pub const ConditionalTypePayload = struct {
    check: NodeId,
    extends: NodeId,
    true_branch: NodeId,
    false_branch: NodeId,
};

/// `infer X` placeholder.
pub const InferTypePayload = struct {
    name: StringId,
    /// Constraint type (`infer X extends Constraint`), `none_node_id` if absent.
    constraint: NodeId,
};

/// `{ [K in keyof T]: V }`.
pub const MappedTypePayload = struct {
    /// Type-parameter being iterated.
    type_param: NodeId,
    /// Constraint of `K`, typically `keyof T`.
    constraint: NodeId,
    /// Value type of each member.
    value: NodeId,
    /// Optional key remapping clause (`as X` after `[K in T]`),
    /// `none_node_id` if absent. When present, each iterated key
    /// is renamed to the value of this type with `K` substituted;
    /// keys whose remap evaluates to `never` are dropped.
    remap: NodeId,
    /// `+/- readonly` modifier state.
    readonly: u8, // 0=none, 1=add, 2=remove
    /// `+/- ?` modifier state.
    optional: u8,
};

/// Literal type — `"hello"`, `42`, `true`. Reuses the same payload as
/// the value-position literal nodes (number / string / bigint / bool);
/// the kind distinguishes "literal-as-type" from value literals.
pub const LiteralTypePayload = struct {
    /// Pointer to the literal-bearing child node (`literal_string`,
    /// `literal_number`, `literal_bigint`, `literal_bool`).
    literal: NodeId,
    /// True for `-42` (negative numeric literal type).
    negative: bool,
};

/// `<T extends U = D>` — type parameter declaration (used in
/// fn / class / interface / type-alias generics).
pub const TypeParameterPayload = struct {
    name: StringId,
    /// `none_node_id` if no `extends`.
    constraint: NodeId,
    /// `none_node_id` if no default.
    default: NodeId,
    /// `in` / `out` variance modifier (0=none, 1=in, 2=out, 3=in_out).
    variance: u8,
    /// TS 5.0 `const` type parameter modifier — `<const T>`. When true,
    /// argument inference for T should be performed `as const` (readonly +
    /// literal types preserved). TODO(checker): currently parsed-only.
    is_const: bool = false,
};

/// `let`/`const`/`var` declaration. The `kind` on the `Hir.kindOf(node)`
/// distinguishes `var_decl` / `let_decl` / `const_decl`. `is_ambient`
/// records a leading `declare` modifier. The `is_using` /
/// `is_await_using` flags carry the Stage 3 explicit resource
/// management qualifier (`using x = …` / `await using x = …`) — for v0
/// the parser stores these on a `const_decl`-shaped node so downstream
/// consumers continue to treat the binding as `const`.
pub const VarDeclPayload = struct {
    /// Identifier (or destructuring pattern).
    name: NodeId,
    /// Type annotation, or `none_node_id`.
    type_annotation: NodeId,
    /// Initializer, or `none_node_id`.
    init: NodeId,
    /// `declare let x: T;` ambient declaration.
    is_ambient: bool = false,
    /// `using x = expr` — disposes via `[Symbol.dispose]()` at scope exit.
    is_using: bool = false,
    /// `await using x = expr` — disposes via `[Symbol.asyncDispose]()`.
    is_await_using: bool = false,
};

/// Object/array destructuring pattern payload. Each element is a
/// `parameter` HIR node (re-using `ParameterPayload` for `name`,
/// `default_value`, and `flags.is_rest`). For v0 only shorthand
/// `{ key }` / `{ key = default }` and array element bindings
/// `[ name ]` / `[ name = default ]` / `[ ...rest ]` are supported.
pub const PatternPayload = struct {
    /// Children-pool slice: `parameter` nodes describing each binding.
    elements_start: u32,
    elements_len: u32,
};

/// Arrow function payload. Reuses `FnDeclPayload`'s shape with the
/// `is_arrow` flag set in `FnFlags`.
pub const ArrowPayload = FnDeclPayload;

// ============================================================================
// JSX node payloads
// ============================================================================

pub const JsxElementPayload = struct {
    /// Tag identifier for `<Foo>`. For namespaced tags (`<svg:rect>`)
    /// the qualifier list provides the namespace prefix.
    tag: NodeId,
    /// Children-pool slice: attributes (`jsx_attribute` /
    /// `jsx_spread_attribute`).
    attrs_start: u32,
    attrs_len: u32,
    /// Children-pool slice: nested children (other jsx_element /
    /// jsx_fragment / jsx_expression / jsx_text).
    children_start: u32,
    children_len: u32,
    /// True when the opening tag is self-closing: `<Foo />`.
    self_closing: bool,
};

pub const JsxAttributePayload = struct {
    /// Attribute name (interned).
    name: StringId,
    /// `none_node_id` for boolean shorthand attributes (`<Foo bar />`).
    /// Otherwise points to a string literal or a jsx_expression.
    value: NodeId,
};

pub const JsxSpreadAttributePayload = struct {
    /// `{...expr}` — the expression to spread.
    expression: NodeId,
};

pub const JsxExpressionPayload = struct {
    /// `{expr}` — the contained value expression. `none_node_id`
    /// for empty `{}`.
    expression: NodeId,
};

pub const JsxFragmentPayload = struct {
    /// Children-pool slice.
    children_start: u32,
    children_len: u32,
};

/// `@dec` or `@dec(args)` — a single decorator.
pub const DecoratorPayload = struct {
    /// The decorator expression (LeftHandSideExpression).
    expression: NodeId,
};

/// One member of an interface body or object-type literal.
/// Examples:
///   `x: number;` → property with name='x', type=number, optional=false
///   `y?: string;` → property with name='y', optional=true
///   `f(): void;` → method-like, type is a fn_type referencing the
///     params + return type
pub const InterfaceMemberPayload = struct {
    /// Property name (interned). For computed keys this is `0` and
    /// the parser emits a `key_expr` that lives in the cold side
    /// table — Phase 1 follow-up.
    name: StringId,
    /// Type of this member. For methods this is a fn_type node.
    type_node: NodeId,
    is_optional: bool,
    is_readonly: bool,
    is_method: bool,
    is_override: bool = false,
};

/// `{ x: number; y: string }` — anonymous object type. Members
/// live in the children pool.
pub const ObjectTypePayload = struct {
    members_start: u32,
    members_len: u32,
};

// ============================================================================
// Hir storage
// ============================================================================

/// Cold side-table for rare fields. Per Tier 1 §11.4: JSDoc text,
/// original-source comments, debug strings — all kept off the hot path.
pub const ColdData = struct {
    /// Maps NodeId → interned JSDoc comment text (single string, raw).
    jsdoc: std.AutoHashMapUnmanaged(NodeId, StringId),
    /// Maps NodeId → debug name (used by `--explainFiles` and source-map
    /// `names` field).
    debug_names: std.AutoHashMapUnmanaged(NodeId, StringId),
    /// Maps `interface_member` NodeId → its computed key-expression
    /// node (when the member declared a `[expr]:` computed name). Used
    /// by the checker to emit per-key diagnostics (TS2467 type-param
    /// references inside a computed interface-member name) without
    /// adding the field to the hot `InterfaceMemberPayload`. Mirrors
    /// `computedPropertyNames35_ES{5,6}`.
    interface_member_key_expr: std.AutoHashMapUnmanaged(NodeId, NodeId),

    pub fn empty() ColdData {
        return .{
            .jsdoc = .empty,
            .debug_names = .empty,
            .interface_member_key_expr = .empty,
        };
    }

    pub fn deinit(self: *ColdData, gpa: std.mem.Allocator) void {
        self.jsdoc.deinit(gpa);
        self.debug_names.deinit(gpa);
        self.interface_member_key_expr.deinit(gpa);
    }
};

/// SoA HIR.
pub const Hir = struct {
    gpa: std.mem.Allocator,

    // ----- Hot columns: 21 B/node before alignment padding -----
    kinds: std.ArrayListUnmanaged(NodeKind),
    spans: std.ArrayListUnmanaged(Span),
    parents: std.ArrayListUnmanaged(NodeId),
    types: std.ArrayListUnmanaged(TypeId),
    /// Index into the per-kind side table appropriate to `kinds[i]`.
    payloads: std.ArrayListUnmanaged(u32),

    // ----- Per-kind side tables -----
    binop_payloads: std.ArrayListUnmanaged(BinopPayload),
    unary_payloads: std.ArrayListUnmanaged(UnaryPayload),
    logical_payloads: std.ArrayListUnmanaged(LogicalPayload),
    update_payloads: std.ArrayListUnmanaged(UpdatePayload),
    call_payloads: std.ArrayListUnmanaged(CallPayload),
    member_payloads: std.ArrayListUnmanaged(MemberPayload),
    element_payloads: std.ArrayListUnmanaged(ElementPayload),
    identifier_payloads: std.ArrayListUnmanaged(IdentifierPayload),
    string_payloads: std.ArrayListUnmanaged(LiteralStringPayload),
    number_payloads: std.ArrayListUnmanaged(LiteralNumberPayload),
    bigint_payloads: std.ArrayListUnmanaged(LiteralBigIntPayload),
    bool_payloads: std.ArrayListUnmanaged(LiteralBoolPayload),
    conditional_payloads: std.ArrayListUnmanaged(ConditionalPayload),
    assignment_payloads: std.ArrayListUnmanaged(AssignmentPayload),
    block_payloads: std.ArrayListUnmanaged(BlockPayload),
    if_payloads: std.ArrayListUnmanaged(IfPayload),
    return_payloads: std.ArrayListUnmanaged(ReturnPayload),
    while_payloads: std.ArrayListUnmanaged(WhilePayload),
    do_while_payloads: std.ArrayListUnmanaged(DoWhilePayload),
    for_payloads: std.ArrayListUnmanaged(ForPayload),
    for_in_of_payloads: std.ArrayListUnmanaged(ForInOfPayload),
    throw_payloads: std.ArrayListUnmanaged(ThrowPayload),
    try_payloads: std.ArrayListUnmanaged(TryPayload),
    switch_case_payloads: std.ArrayListUnmanaged(SwitchCasePayload),
    switch_payloads: std.ArrayListUnmanaged(SwitchPayload),
    label_payloads: std.ArrayListUnmanaged(LabelPayload),
    labeled_stmt_payloads: std.ArrayListUnmanaged(LabeledStmtPayload),
    fn_decl_payloads: std.ArrayListUnmanaged(FnDeclPayload),
    parameter_payloads: std.ArrayListUnmanaged(ParameterPayload),
    type_alias_payloads: std.ArrayListUnmanaged(TypeAliasPayload),
    interface_payloads: std.ArrayListUnmanaged(InterfacePayload),
    class_payloads: std.ArrayListUnmanaged(ClassPayload),
    enum_payloads: std.ArrayListUnmanaged(EnumPayload),
    namespace_payloads: std.ArrayListUnmanaged(NamespacePayload),
    import_payloads: std.ArrayListUnmanaged(ImportPayload),
    export_payloads: std.ArrayListUnmanaged(ExportPayload),
    import_specifier_payloads: std.ArrayListUnmanaged(ImportSpecifierPayload),
    array_literal_payloads: std.ArrayListUnmanaged(ArrayLiteralPayload),
    object_literal_payloads: std.ArrayListUnmanaged(ObjectLiteralPayload),
    object_property_payloads: std.ArrayListUnmanaged(ObjectPropertyPayload),
    var_decl_payloads: std.ArrayListUnmanaged(VarDeclPayload),
    type_ref_payloads: std.ArrayListUnmanaged(TypeRefPayload),
    union_type_payloads: std.ArrayListUnmanaged(UnionTypePayload),
    intersection_type_payloads: std.ArrayListUnmanaged(IntersectionTypePayload),
    array_type_payloads: std.ArrayListUnmanaged(ArrayTypePayload),
    tuple_type_payloads: std.ArrayListUnmanaged(TupleTypePayload),
    optional_type_payloads: std.ArrayListUnmanaged(OptionalTypePayload),
    rest_type_payloads: std.ArrayListUnmanaged(RestTypePayload),
    fn_type_payloads: std.ArrayListUnmanaged(FnTypePayload),
    indexed_access_type_payloads: std.ArrayListUnmanaged(IndexedAccessTypePayload),
    keyof_type_payloads: std.ArrayListUnmanaged(KeyofTypePayload),
    typeof_type_payloads: std.ArrayListUnmanaged(TypeofTypePayload),
    readonly_type_payloads: std.ArrayListUnmanaged(ReadonlyTypePayload),
    type_predicate_payloads: std.ArrayListUnmanaged(TypePredicatePayload),
    template_literal_type_payloads: std.ArrayListUnmanaged(TemplateLiteralTypePayload),
    template_literal_payloads: std.ArrayListUnmanaged(TemplateLiteralPayload),
    as_expression_payloads: std.ArrayListUnmanaged(AsExpressionPayload),
    index_signature_payloads: std.ArrayListUnmanaged(IndexSignaturePayload),
    conditional_type_payloads: std.ArrayListUnmanaged(ConditionalTypePayload),
    infer_type_payloads: std.ArrayListUnmanaged(InferTypePayload),
    mapped_type_payloads: std.ArrayListUnmanaged(MappedTypePayload),
    literal_type_payloads: std.ArrayListUnmanaged(LiteralTypePayload),
    type_parameter_payloads: std.ArrayListUnmanaged(TypeParameterPayload),
    jsx_element_payloads: std.ArrayListUnmanaged(JsxElementPayload),
    jsx_attribute_payloads: std.ArrayListUnmanaged(JsxAttributePayload),
    jsx_spread_attribute_payloads: std.ArrayListUnmanaged(JsxSpreadAttributePayload),
    jsx_expression_payloads: std.ArrayListUnmanaged(JsxExpressionPayload),
    jsx_fragment_payloads: std.ArrayListUnmanaged(JsxFragmentPayload),
    decorator_payloads: std.ArrayListUnmanaged(DecoratorPayload),
    interface_member_payloads: std.ArrayListUnmanaged(InterfaceMemberPayload),
    object_type_payloads: std.ArrayListUnmanaged(ObjectTypePayload),
    pattern_payloads: std.ArrayListUnmanaged(PatternPayload),

    /// Shared variable-arity child pool. Per-node payloads reference
    /// slices into this with `(start: u32, len: u32)`.
    child_pool: std.ArrayListUnmanaged(NodeId),

    /// Cold data — never read on the hot path.
    cold: ColdData,

    pub fn init(gpa: std.mem.Allocator) !Hir {
        var self: Hir = .{
            .gpa = gpa,
            .kinds = .empty,
            .spans = .empty,
            .parents = .empty,
            .types = .empty,
            .payloads = .empty,
            .binop_payloads = .empty,
            .unary_payloads = .empty,
            .logical_payloads = .empty,
            .update_payloads = .empty,
            .call_payloads = .empty,
            .member_payloads = .empty,
            .element_payloads = .empty,
            .identifier_payloads = .empty,
            .string_payloads = .empty,
            .number_payloads = .empty,
            .bigint_payloads = .empty,
            .bool_payloads = .empty,
            .conditional_payloads = .empty,
            .assignment_payloads = .empty,
            .block_payloads = .empty,
            .if_payloads = .empty,
            .return_payloads = .empty,
            .while_payloads = .empty,
            .do_while_payloads = .empty,
            .for_payloads = .empty,
            .for_in_of_payloads = .empty,
            .throw_payloads = .empty,
            .try_payloads = .empty,
            .switch_case_payloads = .empty,
            .switch_payloads = .empty,
            .label_payloads = .empty,
            .labeled_stmt_payloads = .empty,
            .fn_decl_payloads = .empty,
            .parameter_payloads = .empty,
            .type_alias_payloads = .empty,
            .interface_payloads = .empty,
            .class_payloads = .empty,
            .enum_payloads = .empty,
            .namespace_payloads = .empty,
            .import_payloads = .empty,
            .export_payloads = .empty,
            .import_specifier_payloads = .empty,
            .array_literal_payloads = .empty,
            .object_literal_payloads = .empty,
            .object_property_payloads = .empty,
            .var_decl_payloads = .empty,
            .type_ref_payloads = .empty,
            .union_type_payloads = .empty,
            .intersection_type_payloads = .empty,
            .array_type_payloads = .empty,
            .tuple_type_payloads = .empty,
            .optional_type_payloads = .empty,
            .rest_type_payloads = .empty,
            .fn_type_payloads = .empty,
            .indexed_access_type_payloads = .empty,
            .keyof_type_payloads = .empty,
            .typeof_type_payloads = .empty,
            .readonly_type_payloads = .empty,
            .type_predicate_payloads = .empty,
            .template_literal_type_payloads = .empty,
            .template_literal_payloads = .empty,
            .as_expression_payloads = .empty,
            .index_signature_payloads = .empty,
            .conditional_type_payloads = .empty,
            .infer_type_payloads = .empty,
            .mapped_type_payloads = .empty,
            .literal_type_payloads = .empty,
            .type_parameter_payloads = .empty,
            .jsx_element_payloads = .empty,
            .jsx_attribute_payloads = .empty,
            .jsx_spread_attribute_payloads = .empty,
            .jsx_expression_payloads = .empty,
            .jsx_fragment_payloads = .empty,
            .decorator_payloads = .empty,
            .interface_member_payloads = .empty,
            .object_type_payloads = .empty,
            .pattern_payloads = .empty,
            .child_pool = .empty,
            .cold = ColdData.empty(),
        };

        // Reserve index 0 in every hot column for the `none` sentinel.
        try self.kinds.append(gpa, .none);
        try self.spans.append(gpa, Span.empty());
        try self.parents.append(gpa, none_node_id);
        try self.types.append(gpa, reserved_type_ids.none);
        try self.payloads.append(gpa, 0);
        // Reserve index 0 in the child pool too — `(start: 0, len: 0)`
        // is a valid empty-slice reference.
        try self.child_pool.append(gpa, none_node_id);

        return self;
    }

    pub fn deinit(self: *Hir) void {
        self.kinds.deinit(self.gpa);
        self.spans.deinit(self.gpa);
        self.parents.deinit(self.gpa);
        self.types.deinit(self.gpa);
        self.payloads.deinit(self.gpa);
        self.binop_payloads.deinit(self.gpa);
        self.unary_payloads.deinit(self.gpa);
        self.logical_payloads.deinit(self.gpa);
        self.update_payloads.deinit(self.gpa);
        self.call_payloads.deinit(self.gpa);
        self.member_payloads.deinit(self.gpa);
        self.element_payloads.deinit(self.gpa);
        self.identifier_payloads.deinit(self.gpa);
        self.string_payloads.deinit(self.gpa);
        self.number_payloads.deinit(self.gpa);
        self.bigint_payloads.deinit(self.gpa);
        self.bool_payloads.deinit(self.gpa);
        self.conditional_payloads.deinit(self.gpa);
        self.assignment_payloads.deinit(self.gpa);
        self.block_payloads.deinit(self.gpa);
        self.if_payloads.deinit(self.gpa);
        self.return_payloads.deinit(self.gpa);
        self.while_payloads.deinit(self.gpa);
        self.do_while_payloads.deinit(self.gpa);
        self.for_payloads.deinit(self.gpa);
        self.for_in_of_payloads.deinit(self.gpa);
        self.throw_payloads.deinit(self.gpa);
        self.try_payloads.deinit(self.gpa);
        self.switch_case_payloads.deinit(self.gpa);
        self.switch_payloads.deinit(self.gpa);
        self.label_payloads.deinit(self.gpa);
        self.labeled_stmt_payloads.deinit(self.gpa);
        self.fn_decl_payloads.deinit(self.gpa);
        self.parameter_payloads.deinit(self.gpa);
        self.type_alias_payloads.deinit(self.gpa);
        self.interface_payloads.deinit(self.gpa);
        self.class_payloads.deinit(self.gpa);
        self.enum_payloads.deinit(self.gpa);
        self.namespace_payloads.deinit(self.gpa);
        self.import_payloads.deinit(self.gpa);
        self.export_payloads.deinit(self.gpa);
        self.import_specifier_payloads.deinit(self.gpa);
        self.array_literal_payloads.deinit(self.gpa);
        self.object_literal_payloads.deinit(self.gpa);
        self.object_property_payloads.deinit(self.gpa);
        self.var_decl_payloads.deinit(self.gpa);
        self.type_ref_payloads.deinit(self.gpa);
        self.union_type_payloads.deinit(self.gpa);
        self.intersection_type_payloads.deinit(self.gpa);
        self.array_type_payloads.deinit(self.gpa);
        self.tuple_type_payloads.deinit(self.gpa);
        self.optional_type_payloads.deinit(self.gpa);
        self.rest_type_payloads.deinit(self.gpa);
        self.fn_type_payloads.deinit(self.gpa);
        self.indexed_access_type_payloads.deinit(self.gpa);
        self.keyof_type_payloads.deinit(self.gpa);
        self.typeof_type_payloads.deinit(self.gpa);
        self.readonly_type_payloads.deinit(self.gpa);
        self.type_predicate_payloads.deinit(self.gpa);
        self.template_literal_type_payloads.deinit(self.gpa);
        self.template_literal_payloads.deinit(self.gpa);
        self.as_expression_payloads.deinit(self.gpa);
        self.index_signature_payloads.deinit(self.gpa);
        self.conditional_type_payloads.deinit(self.gpa);
        self.infer_type_payloads.deinit(self.gpa);
        self.mapped_type_payloads.deinit(self.gpa);
        self.literal_type_payloads.deinit(self.gpa);
        self.type_parameter_payloads.deinit(self.gpa);
        self.jsx_element_payloads.deinit(self.gpa);
        self.jsx_attribute_payloads.deinit(self.gpa);
        self.jsx_spread_attribute_payloads.deinit(self.gpa);
        self.jsx_expression_payloads.deinit(self.gpa);
        self.jsx_fragment_payloads.deinit(self.gpa);
        self.decorator_payloads.deinit(self.gpa);
        self.interface_member_payloads.deinit(self.gpa);
        self.object_type_payloads.deinit(self.gpa);
        self.pattern_payloads.deinit(self.gpa);
        self.child_pool.deinit(self.gpa);
        self.cold.deinit(self.gpa);
    }

    pub fn nodeCount(self: *const Hir) u32 {
        return @intCast(self.kinds.items.len);
    }

    pub fn kindOf(self: *const Hir, id: NodeId) NodeKind {
        return self.kinds.items[id];
    }

    pub fn spanOf(self: *const Hir, id: NodeId) Span {
        return self.spans.items[id];
    }

    pub fn parentOf(self: *const Hir, id: NodeId) NodeId {
        return self.parents.items[id];
    }

    pub fn typeOf(self: *const Hir, id: NodeId) TypeId {
        return self.types.items[id];
    }

    pub fn setType(self: *Hir, id: NodeId, t: TypeId) void {
        self.types.items[id] = t;
    }

    pub fn setParent(self: *Hir, id: NodeId, parent: NodeId) void {
        self.parents.items[id] = parent;
    }

    /// Return the slice of NodeIds in the child pool from [start, start+len).
    pub fn childSlice(self: *const Hir, start: u32, len: u32) []const NodeId {
        return self.child_pool.items[start .. start + len];
    }

    /// Set the `is_async` flag on an existing fn-decl. Used by the
    /// parser when `async function f()` is parsed as a statement —
    /// the inner `parseFunctionDeclaration` doesn't see the leading
    /// `async`, so we patch the flag in afterward.
    pub fn markFnAsync(self: *Hir, id: NodeId) void {
        const k = self.kindOf(id);
        std.debug.assert(k == .fn_decl or k == .fn_expr or k == .arrow_fn);
        const payload_idx = self.payloads.items[id];
        self.fn_decl_payloads.items[payload_idx].flags.is_async = true;
    }

    /// Set the `is_const` flag on an existing enum decl. Used by the
    /// parser when `const enum E { ... }` is parsed at statement
    /// position — the leading `const` is consumed before
    /// `parseEnumDeclaration` runs, so we patch the flag afterward.
    pub fn markEnumConst(self: *Hir, id: NodeId) void {
        std.debug.assert(self.kindOf(id) == .enum_decl);
        const payload_idx = self.payloads.items[id];
        self.enum_payloads.items[payload_idx].is_const = true;
    }

    /// Set the `is_export` flag on an existing import-equals decl. Used
    /// by the parser for `export import Foo = ns.Foo;` — the leading
    /// `export` modifier is consumed before `parseImportDeclaration`
    /// runs, so we patch the flag afterward.
    pub fn markImportExported(self: *Hir, id: NodeId) void {
        std.debug.assert(self.kindOf(id) == .import_decl);
        const payload_idx = self.payloads.items[id];
        self.import_payloads.items[payload_idx].is_export = true;
    }
};

// ============================================================================
// Builder
// ============================================================================
//
// All node-creation helpers go through the builder. The builder keeps
// track of the current parent chain so callers can do
//     b.beginBlock(span);
//     b.addStmt(...);
//     b.addStmt(...);
//     const block = b.endBlock();
// without manually wiring `parent` fields.

pub const Builder = struct {
    hir: *Hir,
    /// LIFO stack of in-progress parent NodeIds, used by `pushParent`/
    /// `popParent`. The top of the stack is the implicit parent for any
    /// new node created via `add*`.
    parent_stack: std.ArrayListUnmanaged(NodeId),

    pub fn init(hir: *Hir) Builder {
        return .{
            .hir = hir,
            .parent_stack = .empty,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.parent_stack.deinit(self.hir.gpa);
    }

    fn currentParent(self: *const Builder) NodeId {
        if (self.parent_stack.items.len == 0) return none_node_id;
        return self.parent_stack.items[self.parent_stack.items.len - 1];
    }

    pub fn pushParent(self: *Builder, id: NodeId) !void {
        try self.parent_stack.append(self.hir.gpa, id);
    }

    pub fn popParent(self: *Builder) void {
        std.debug.assert(self.parent_stack.items.len > 0);
        _ = self.parent_stack.pop();
    }

    /// Allocate a new node and return its NodeId.
    fn newNode(self: *Builder, kind: NodeKind, span: Span, payload: u32) !NodeId {
        const id: NodeId = @intCast(self.hir.kinds.items.len);
        try self.hir.kinds.append(self.hir.gpa, kind);
        try self.hir.spans.append(self.hir.gpa, span);
        try self.hir.parents.append(self.hir.gpa, self.currentParent());
        try self.hir.types.append(self.hir.gpa, reserved_type_ids.none);
        try self.hir.payloads.append(self.hir.gpa, payload);
        return id;
    }

    // ---- Identifiers and literals ----------------------------------------

    pub fn addIdentifier(self: *Builder, span: Span, name: StringId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.identifier_payloads.items.len);
        try self.hir.identifier_payloads.append(self.hir.gpa, .{ .name = name });
        return self.newNode(.identifier, span, payload_idx);
    }

    pub fn addLiteralString(self: *Builder, span: Span, value: StringId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.string_payloads.items.len);
        try self.hir.string_payloads.append(self.hir.gpa, .{ .value = value });
        return self.newNode(.literal_string, span, payload_idx);
    }

    pub fn addLiteralNumber(self: *Builder, span: Span, value: f64) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.number_payloads.items.len);
        try self.hir.number_payloads.append(self.hir.gpa, .{ .bits = @bitCast(value) });
        return self.newNode(.literal_number, span, payload_idx);
    }

    pub fn addLiteralBigInt(self: *Builder, span: Span, digits: StringId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.bigint_payloads.items.len);
        try self.hir.bigint_payloads.append(self.hir.gpa, .{ .digits = digits });
        return self.newNode(.literal_bigint, span, payload_idx);
    }

    pub fn addLiteralBool(self: *Builder, span: Span, value: bool) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.bool_payloads.items.len);
        try self.hir.bool_payloads.append(self.hir.gpa, .{ .value = value });
        return self.newNode(.literal_bool, span, payload_idx);
    }

    pub fn addLiteralNull(self: *Builder, span: Span) !NodeId {
        return self.newNode(.literal_null, span, 0);
    }

    pub fn addLiteralUndefined(self: *Builder, span: Span) !NodeId {
        return self.newNode(.literal_undefined, span, 0);
    }

    pub fn addLiteralRegex(self: *Builder, span: Span) !NodeId {
        return self.newNode(.literal_regex, span, 0);
    }

    // ---- Compound expressions --------------------------------------------

    pub fn addBinaryOp(self: *Builder, span: Span, op: BinOp, lhs: NodeId, rhs: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.binop_payloads.items.len);
        try self.hir.binop_payloads.append(self.hir.gpa, .{
            .lhs = lhs,
            .rhs = rhs,
            .op = op,
        });
        const id = try self.newNode(.binary_op, span, payload_idx);
        self.hir.setParent(lhs, id);
        self.hir.setParent(rhs, id);
        return id;
    }

    pub fn addUnaryOp(self: *Builder, span: Span, op: UnaryOp, operand: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.unary_payloads.items.len);
        try self.hir.unary_payloads.append(self.hir.gpa, .{
            .operand = operand,
            .op = op,
        });
        const id = try self.newNode(.unary_op, span, payload_idx);
        self.hir.setParent(operand, id);
        return id;
    }

    pub fn addLogicalOp(self: *Builder, span: Span, op: LogicalOp, lhs: NodeId, rhs: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.logical_payloads.items.len);
        try self.hir.logical_payloads.append(self.hir.gpa, .{
            .lhs = lhs,
            .rhs = rhs,
            .op = op,
        });
        const id = try self.newNode(.logical_op, span, payload_idx);
        self.hir.setParent(lhs, id);
        self.hir.setParent(rhs, id);
        return id;
    }

    pub fn addConditional(self: *Builder, span: Span, cond: NodeId, then_branch: NodeId, else_branch: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.conditional_payloads.items.len);
        try self.hir.conditional_payloads.append(self.hir.gpa, .{
            .cond = cond,
            .then_branch = then_branch,
            .else_branch = else_branch,
        });
        const id = try self.newNode(.conditional, span, payload_idx);
        self.hir.setParent(cond, id);
        self.hir.setParent(then_branch, id);
        self.hir.setParent(else_branch, id);
        return id;
    }

    /// Add a call expression with `args` (already-allocated child nodes).
    /// Copies `args` into the shared child pool.
    pub fn addCall(self: *Builder, span: Span, callee: NodeId, args: []const NodeId) !NodeId {
        return self.addCallWithTypeArgs(span, callee, args, &.{});
    }

    pub fn addOptionalCall(self: *Builder, span: Span, callee: NodeId, args: []const NodeId) !NodeId {
        return self.addCallWithTypeArgsAndOptional(span, callee, args, &.{}, true);
    }

    /// `callee<T1, T2>(args)` — explicit type arguments threaded through
    /// to the checker so they override call-site inference.
    pub fn addCallWithTypeArgs(self: *Builder, span: Span, callee: NodeId, args: []const NodeId, type_args: []const NodeId) !NodeId {
        return self.addCallWithTypeArgsAndOptional(span, callee, args, type_args, false);
    }

    fn addCallWithTypeArgsAndOptional(self: *Builder, span: Span, callee: NodeId, args: []const NodeId, type_args: []const NodeId, optional: bool) !NodeId {
        const args_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, args);
        const args_len: u16 = @intCast(args.len);
        const type_args_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, type_args);
        const type_args_len: u16 = @intCast(type_args.len);
        const payload_idx: u32 = @intCast(self.hir.call_payloads.items.len);
        try self.hir.call_payloads.append(self.hir.gpa, .{
            .callee = callee,
            .args_start = args_start,
            .args_len = args_len,
            .type_args_start = type_args_start,
            .type_args_len = type_args_len,
            .optional = optional,
        });
        const id = try self.newNode(.call_expr, span, payload_idx);
        self.hir.setParent(callee, id);
        for (args) |arg| self.hir.setParent(arg, id);
        for (type_args) |t| self.hir.setParent(t, id);
        return id;
    }

    /// Add a `new Foo(args)` expression. Same payload shape as a
    /// call, but emitted as `.new_expr` so the checker can produce
    /// the class instance type rather than the constructor's return.
    pub fn addNew(self: *Builder, span: Span, callee: NodeId, args: []const NodeId) !NodeId {
        return self.addNewWithTypeArgs(span, callee, args, &.{});
    }

    pub fn addNewWithTypeArgs(self: *Builder, span: Span, callee: NodeId, args: []const NodeId, type_args: []const NodeId) !NodeId {
        const args_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, args);
        const args_len: u16 = @intCast(args.len);
        const type_args_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, type_args);
        const type_args_len: u16 = @intCast(type_args.len);
        const payload_idx: u32 = @intCast(self.hir.call_payloads.items.len);
        try self.hir.call_payloads.append(self.hir.gpa, .{
            .callee = callee,
            .args_start = args_start,
            .args_len = args_len,
            .type_args_start = type_args_start,
            .type_args_len = type_args_len,
            .optional = false,
        });
        const id = try self.newNode(.new_expr, span, payload_idx);
        self.hir.setParent(callee, id);
        for (args) |arg| self.hir.setParent(arg, id);
        for (type_args) |t| self.hir.setParent(t, id);
        return id;
    }

    pub fn addMemberAccess(self: *Builder, span: Span, object: NodeId, name: StringId, optional: bool) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.member_payloads.items.len);
        try self.hir.member_payloads.append(self.hir.gpa, .{
            .object = object,
            .name = name,
            .optional = optional,
        });
        const id = try self.newNode(.member_access, span, payload_idx);
        self.hir.setParent(object, id);
        return id;
    }

    pub fn addElementAccess(self: *Builder, span: Span, object: NodeId, index: NodeId, optional: bool) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.element_payloads.items.len);
        try self.hir.element_payloads.append(self.hir.gpa, .{
            .object = object,
            .index = index,
            .optional = optional,
        });
        const id = try self.newNode(.element_access, span, payload_idx);
        self.hir.setParent(object, id);
        self.hir.setParent(index, id);
        return id;
    }

    pub fn addAssignment(self: *Builder, span: Span, target: NodeId, value: NodeId, op: ?BinOp) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.assignment_payloads.items.len);
        try self.hir.assignment_payloads.append(self.hir.gpa, .{
            .target = target,
            .value = value,
            .op = op,
        });
        const id = try self.newNode(.assignment, span, payload_idx);
        self.hir.setParent(target, id);
        self.hir.setParent(value, id);
        return id;
    }

    // ---- Statements ------------------------------------------------------

    /// Build a block statement from a list of statement node ids.
    pub fn addBlock(self: *Builder, span: Span, stmts: []const NodeId) !NodeId {
        const stmts_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, stmts);
        const payload_idx: u32 = @intCast(self.hir.block_payloads.items.len);
        try self.hir.block_payloads.append(self.hir.gpa, .{
            .stmts_start = stmts_start,
            .stmts_len = @intCast(stmts.len),
        });
        const id = try self.newNode(.block_stmt, span, payload_idx);
        for (stmts) |s| self.hir.setParent(s, id);
        return id;
    }

    pub fn addIf(self: *Builder, span: Span, cond: NodeId, then_branch: NodeId, else_branch: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.if_payloads.items.len);
        try self.hir.if_payloads.append(self.hir.gpa, .{
            .cond = cond,
            .then_branch = then_branch,
            .else_branch = else_branch,
        });
        const id = try self.newNode(.if_stmt, span, payload_idx);
        self.hir.setParent(cond, id);
        self.hir.setParent(then_branch, id);
        if (else_branch != none_node_id) self.hir.setParent(else_branch, id);
        return id;
    }

    pub fn addReturn(self: *Builder, span: Span, value: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.return_payloads.items.len);
        try self.hir.return_payloads.append(self.hir.gpa, .{ .value = value });
        const id = try self.newNode(.return_stmt, span, payload_idx);
        if (value != none_node_id) self.hir.setParent(value, id);
        return id;
    }

    pub fn addWhile(self: *Builder, span: Span, cond: NodeId, body: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.while_payloads.items.len);
        try self.hir.while_payloads.append(self.hir.gpa, .{ .cond = cond, .body = body });
        const id = try self.newNode(.while_stmt, span, payload_idx);
        self.hir.setParent(cond, id);
        self.hir.setParent(body, id);
        return id;
    }

    pub fn addDoWhile(self: *Builder, span: Span, body: NodeId, cond: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.do_while_payloads.items.len);
        try self.hir.do_while_payloads.append(self.hir.gpa, .{ .body = body, .cond = cond });
        const id = try self.newNode(.do_while_stmt, span, payload_idx);
        self.hir.setParent(body, id);
        self.hir.setParent(cond, id);
        return id;
    }

    pub fn addFor(self: *Builder, span: Span, init_n: NodeId, cond: NodeId, update: NodeId, body: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.for_payloads.items.len);
        try self.hir.for_payloads.append(self.hir.gpa, .{
            .init = init_n,
            .cond = cond,
            .update = update,
            .body = body,
        });
        const id = try self.newNode(.for_stmt, span, payload_idx);
        if (init_n != none_node_id) self.hir.setParent(init_n, id);
        if (cond != none_node_id) self.hir.setParent(cond, id);
        if (update != none_node_id) self.hir.setParent(update, id);
        self.hir.setParent(body, id);
        return id;
    }

    pub fn addForIn(self: *Builder, span: Span, target: NodeId, source: NodeId, body: NodeId) !NodeId {
        return self.addForInOf(.for_in_stmt, span, target, source, body, false);
    }

    pub fn addForOf(self: *Builder, span: Span, target: NodeId, source: NodeId, body: NodeId) !NodeId {
        return self.addForInOf(.for_of_stmt, span, target, source, body, false);
    }

    pub fn addForAwaitOf(self: *Builder, span: Span, target: NodeId, source: NodeId, body: NodeId) !NodeId {
        return self.addForInOf(.for_of_stmt, span, target, source, body, true);
    }

    fn addForInOf(self: *Builder, kind: NodeKind, span: Span, target: NodeId, source: NodeId, body: NodeId, is_await: bool) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.for_in_of_payloads.items.len);
        try self.hir.for_in_of_payloads.append(self.hir.gpa, .{
            .target = target,
            .source = source,
            .body = body,
            .is_await = is_await,
        });
        const id = try self.newNode(kind, span, payload_idx);
        self.hir.setParent(target, id);
        self.hir.setParent(source, id);
        self.hir.setParent(body, id);
        return id;
    }

    pub fn addThrow(self: *Builder, span: Span, value: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.throw_payloads.items.len);
        try self.hir.throw_payloads.append(self.hir.gpa, .{ .value = value });
        const id = try self.newNode(.throw_stmt, span, payload_idx);
        self.hir.setParent(value, id);
        return id;
    }

    pub fn addTry(
        self: *Builder,
        span: Span,
        block: NodeId,
        catch_param: NodeId,
        catch_block: NodeId,
        finally_block: NodeId,
    ) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.try_payloads.items.len);
        try self.hir.try_payloads.append(self.hir.gpa, .{
            .block = block,
            .catch_param = catch_param,
            .catch_block = catch_block,
            .finally_block = finally_block,
        });
        const id = try self.newNode(.try_stmt, span, payload_idx);
        self.hir.setParent(block, id);
        if (catch_param != none_node_id) self.hir.setParent(catch_param, id);
        if (catch_block != none_node_id) self.hir.setParent(catch_block, id);
        if (finally_block != none_node_id) self.hir.setParent(finally_block, id);
        return id;
    }

    pub fn addSwitchCase(self: *Builder, span: Span, value: NodeId, stmts: []const NodeId) !NodeId {
        const stmts_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, stmts);
        const payload_idx: u32 = @intCast(self.hir.switch_case_payloads.items.len);
        try self.hir.switch_case_payloads.append(self.hir.gpa, .{
            .value = value,
            .stmts_start = stmts_start,
            .stmts_len = @intCast(stmts.len),
        });
        const id = try self.newNode(.switch_case, span, payload_idx);
        if (value != none_node_id) self.hir.setParent(value, id);
        for (stmts) |s| self.hir.setParent(s, id);
        return id;
    }

    pub fn addSwitch(self: *Builder, span: Span, discriminant: NodeId, cases: []const NodeId) !NodeId {
        const cases_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, cases);
        const payload_idx: u32 = @intCast(self.hir.switch_payloads.items.len);
        try self.hir.switch_payloads.append(self.hir.gpa, .{
            .discriminant = discriminant,
            .cases_start = cases_start,
            .cases_len = @intCast(cases.len),
        });
        const id = try self.newNode(.switch_stmt, span, payload_idx);
        self.hir.setParent(discriminant, id);
        for (cases) |c| self.hir.setParent(c, id);
        return id;
    }

    pub fn addLabeledStmt(self: *Builder, span: Span, label: NodeId, body: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.labeled_stmt_payloads.items.len);
        try self.hir.labeled_stmt_payloads.append(self.hir.gpa, .{ .label = label, .body = body });
        const id = try self.newNode(.labeled_stmt, span, payload_idx);
        if (label != none_node_id) self.hir.setParent(label, id);
        if (body != none_node_id) self.hir.setParent(body, id);
        return id;
    }

    pub fn addBreak(self: *Builder, span: Span, label: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.label_payloads.items.len);
        try self.hir.label_payloads.append(self.hir.gpa, .{ .label = label });
        const id = try self.newNode(.break_stmt, span, payload_idx);
        if (label != none_node_id) self.hir.setParent(label, id);
        return id;
    }

    pub fn addContinue(self: *Builder, span: Span, label: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.label_payloads.items.len);
        try self.hir.label_payloads.append(self.hir.gpa, .{ .label = label });
        const id = try self.newNode(.continue_stmt, span, payload_idx);
        if (label != none_node_id) self.hir.setParent(label, id);
        return id;
    }

    pub fn addParameter(
        self: *Builder,
        span: Span,
        name: NodeId,
        type_annotation: NodeId,
        default_value: NodeId,
        flags: ParamFlags,
    ) !NodeId {
        return self.addParameterWithDecorators(span, name, type_annotation, default_value, flags, &.{});
    }

    pub fn addParameterWithDecorators(
        self: *Builder,
        span: Span,
        name: NodeId,
        type_annotation: NodeId,
        default_value: NodeId,
        flags: ParamFlags,
        decorators: []const NodeId,
    ) !NodeId {
        const dec_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, decorators);
        const dec_len: u16 = @intCast(decorators.len);
        const payload_idx: u32 = @intCast(self.hir.parameter_payloads.items.len);
        try self.hir.parameter_payloads.append(self.hir.gpa, .{
            .name = name,
            .type_annotation = type_annotation,
            .default_value = default_value,
            .flags = flags,
            .decorators_start = dec_start,
            .decorators_len = dec_len,
        });
        const id = try self.newNode(.parameter, span, payload_idx);
        if (name != none_node_id) self.hir.setParent(name, id);
        if (type_annotation != none_node_id) self.hir.setParent(type_annotation, id);
        if (default_value != none_node_id) self.hir.setParent(default_value, id);
        for (decorators) |d| if (d != none_node_id) self.hir.setParent(d, id);
        return id;
    }

    /// Build an object/array destructuring pattern node. `elements`
    /// is a slice of `parameter` HIR nodes — one per binding in the
    /// pattern. Each element's `name` is the bound identifier (or
    /// nested pattern), `default_value` carries any `= expr` form,
    /// and `flags.is_rest` marks `...rest` elements.
    pub fn addPattern(
        self: *Builder,
        kind: NodeKind,
        span: Span,
        elements: []const NodeId,
    ) !NodeId {
        std.debug.assert(kind == .object_pattern or kind == .array_pattern);
        const elements_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, elements);
        const payload_idx: u32 = @intCast(self.hir.pattern_payloads.items.len);
        try self.hir.pattern_payloads.append(self.hir.gpa, .{
            .elements_start = elements_start,
            .elements_len = @intCast(elements.len),
        });
        const id = try self.newNode(kind, span, payload_idx);
        for (elements) |e| if (e != none_node_id) self.hir.setParent(e, id);
        return id;
    }

    pub fn addFnDecl(
        self: *Builder,
        span: Span,
        name: NodeId,
        params: []const NodeId,
        return_type: NodeId,
        body: NodeId,
        flags: FnFlags,
    ) !NodeId {
        return self.addFnDeclGeneric(span, name, &.{}, params, return_type, body, flags);
    }

    /// Generic-aware fn-decl builder. `type_params` is the list of
    /// `type_parameter` HIR nodes; pass `&.{}` for non-generic decls.
    pub fn addFnDeclGeneric(
        self: *Builder,
        span: Span,
        name: NodeId,
        type_params: []const NodeId,
        params: []const NodeId,
        return_type: NodeId,
        body: NodeId,
        flags: FnFlags,
    ) !NodeId {
        const tp_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, type_params);
        const params_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, params);
        const payload_idx: u32 = @intCast(self.hir.fn_decl_payloads.items.len);
        try self.hir.fn_decl_payloads.append(self.hir.gpa, .{
            .name = name,
            .type_params_start = tp_start,
            .type_params_len = @intCast(type_params.len),
            .params_start = params_start,
            .params_len = @intCast(params.len),
            .return_type = return_type,
            .body = body,
            .flags = flags,
        });
        const kind: NodeKind = if (flags.is_arrow) .arrow_fn else if (flags.is_method or flags.is_constructor) .fn_expr else .fn_decl;
        const id = try self.newNode(kind, span, payload_idx);
        if (name != none_node_id) self.hir.setParent(name, id);
        for (type_params) |tp| self.hir.setParent(tp, id);
        for (params) |p| self.hir.setParent(p, id);
        if (return_type != none_node_id) self.hir.setParent(return_type, id);
        if (body != none_node_id) self.hir.setParent(body, id);
        return id;
    }

    pub fn addTypeAlias(
        self: *Builder,
        span: Span,
        name: NodeId,
        type_params: []const NodeId,
        aliased: NodeId,
    ) !NodeId {
        const tp_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, type_params);
        const payload_idx: u32 = @intCast(self.hir.type_alias_payloads.items.len);
        try self.hir.type_alias_payloads.append(self.hir.gpa, .{
            .name = name,
            .type_params_start = tp_start,
            .type_params_len = @intCast(type_params.len),
            .aliased = aliased,
        });
        const id = try self.newNode(.type_alias_decl, span, payload_idx);
        self.hir.setParent(name, id);
        for (type_params) |tp| self.hir.setParent(tp, id);
        if (aliased != none_node_id) self.hir.setParent(aliased, id);
        return id;
    }

    pub fn addInterface(
        self: *Builder,
        span: Span,
        name: NodeId,
        type_params: []const NodeId,
        extends: []const NodeId,
        members: []const NodeId,
    ) !NodeId {
        const tp_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, type_params);
        const ext_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, extends);
        const mem_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, members);
        const payload_idx: u32 = @intCast(self.hir.interface_payloads.items.len);
        try self.hir.interface_payloads.append(self.hir.gpa, .{
            .name = name,
            .type_params_start = tp_start,
            .type_params_len = @intCast(type_params.len),
            .extends_start = ext_start,
            .extends_len = @intCast(extends.len),
            .members_start = mem_start,
            .members_len = @intCast(members.len),
        });
        const id = try self.newNode(.interface_decl, span, payload_idx);
        self.hir.setParent(name, id);
        for (type_params) |tp| self.hir.setParent(tp, id);
        for (extends) |e| self.hir.setParent(e, id);
        for (members) |m| self.hir.setParent(m, id);
        return id;
    }

    pub fn addClass(
        self: *Builder,
        span: Span,
        name: NodeId,
        type_params: []const NodeId,
        extends: NodeId,
        implements: []const NodeId,
        members: []const NodeId,
        is_abstract: bool,
    ) !NodeId {
        const tp_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, type_params);
        const impl_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, implements);
        const mem_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, members);
        const payload_idx: u32 = @intCast(self.hir.class_payloads.items.len);
        try self.hir.class_payloads.append(self.hir.gpa, .{
            .name = name,
            .type_params_start = tp_start,
            .type_params_len = @intCast(type_params.len),
            .extends = extends,
            .implements_start = impl_start,
            .implements_len = @intCast(implements.len),
            .members_start = mem_start,
            .members_len = @intCast(members.len),
            .is_abstract = is_abstract,
        });
        const id = try self.newNode(.class_decl, span, payload_idx);
        if (name != none_node_id) self.hir.setParent(name, id);
        for (type_params) |tp| self.hir.setParent(tp, id);
        if (extends != none_node_id) self.hir.setParent(extends, id);
        for (implements) |i| self.hir.setParent(i, id);
        for (members) |m| self.hir.setParent(m, id);
        return id;
    }

    pub fn addEnum(self: *Builder, span: Span, name: NodeId, members: []const NodeId, is_const: bool) !NodeId {
        const mem_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, members);
        const payload_idx: u32 = @intCast(self.hir.enum_payloads.items.len);
        try self.hir.enum_payloads.append(self.hir.gpa, .{
            .name = name,
            .members_start = mem_start,
            .members_len = @intCast(members.len),
            .is_const = is_const,
        });
        const id = try self.newNode(.enum_decl, span, payload_idx);
        self.hir.setParent(name, id);
        for (members) |m| self.hir.setParent(m, id);
        return id;
    }

    pub fn addNamespace(self: *Builder, span: Span, name: NodeId, body: []const NodeId) !NodeId {
        const body_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, body);
        const payload_idx: u32 = @intCast(self.hir.namespace_payloads.items.len);
        try self.hir.namespace_payloads.append(self.hir.gpa, .{
            .name = name,
            .body_start = body_start,
            .body_len = @intCast(body.len),
        });
        const id = try self.newNode(.namespace_decl, span, payload_idx);
        self.hir.setParent(name, id);
        for (body) |b| self.hir.setParent(b, id);
        return id;
    }

    pub fn addImportSpecifier(
        self: *Builder,
        span: Span,
        imported: StringId,
        local: StringId,
        is_type_only: bool,
    ) !NodeId {
        return self.addImportSpecifierFull(span, imported, local, is_type_only, false, false, span.start, span.start);
    }

    pub fn addImportSpecifierFull(
        self: *Builder,
        span: Span,
        imported: StringId,
        local: StringId,
        is_type_only: bool,
        imported_is_string_literal: bool,
        local_is_string_literal: bool,
        imported_pos: u32,
        local_pos: u32,
    ) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.import_specifier_payloads.items.len);
        try self.hir.import_specifier_payloads.append(self.hir.gpa, .{
            .imported = imported,
            .local = local,
            .is_type_only = is_type_only,
            .imported_is_string_literal = imported_is_string_literal,
            .local_is_string_literal = local_is_string_literal,
            .imported_pos = imported_pos,
            .local_pos = local_pos,
        });
        return self.newNode(.import_specifier, span, payload_idx);
    }

    pub fn addImport(
        self: *Builder,
        span: Span,
        module: StringId,
        default_binding: NodeId,
        namespace_binding: NodeId,
        import_equals: NodeId,
        named: []const NodeId,
        is_type_only: bool,
    ) !NodeId {
        const named_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, named);
        const payload_idx: u32 = @intCast(self.hir.import_payloads.items.len);
        try self.hir.import_payloads.append(self.hir.gpa, .{
            .module = module,
            .default_binding = default_binding,
            .namespace_binding = namespace_binding,
            .import_equals = import_equals,
            .named_start = named_start,
            .named_len = @intCast(named.len),
            .is_type_only = is_type_only,
        });
        const id = try self.newNode(.import_decl, span, payload_idx);
        if (default_binding != none_node_id) self.hir.setParent(default_binding, id);
        if (namespace_binding != none_node_id) self.hir.setParent(namespace_binding, id);
        if (import_equals != none_node_id) self.hir.setParent(import_equals, id);
        for (named) |n| self.hir.setParent(n, id);
        return id;
    }

    pub fn addExport(
        self: *Builder,
        span: Span,
        decl: NodeId,
        named: []const NodeId,
        module: StringId,
        is_type_only: bool,
        is_default: bool,
    ) !NodeId {
        return self.addExportFull(span, decl, named, module, is_type_only, is_default, false, 0);
    }

    /// `export = <expr>;` (TypeScript export assignment). `expr` is stored
    /// as the export's `decl`; the node is flagged `is_export_equals`.
    pub fn addExportEquals(self: *Builder, span: Span, expr: NodeId, empty_module: StringId) !NodeId {
        const node = try self.addExport(span, expr, &.{}, empty_module, false, false);
        self.hir.export_payloads.items[self.hir.payloads.items[node]].is_export_equals = true;
        return node;
    }

    /// Extended form of `addExport` for `export * [as ns] from "m"`
    /// re-exports. `is_namespace = true` marks the namespace re-export
    /// shape (so the printer can distinguish it from an empty-named
    /// `export {} from`); `namespace_alias` is the local binding name
    /// for `export * as ns from "m"`, or the interner's empty id for
    /// plain `export *`.
    pub fn addExportFull(
        self: *Builder,
        span: Span,
        decl: NodeId,
        named: []const NodeId,
        module: StringId,
        is_type_only: bool,
        is_default: bool,
        is_namespace: bool,
        namespace_alias: StringId,
    ) !NodeId {
        return self.addExportFullWithNamespaceAliasPos(span, decl, named, module, is_type_only, is_default, is_namespace, namespace_alias, false, 0);
    }

    pub fn addExportFullWithNamespaceAliasPos(
        self: *Builder,
        span: Span,
        decl: NodeId,
        named: []const NodeId,
        module: StringId,
        is_type_only: bool,
        is_default: bool,
        is_namespace: bool,
        namespace_alias: StringId,
        namespace_alias_is_string_literal: bool,
        namespace_alias_pos: u32,
    ) !NodeId {
        const named_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, named);
        const payload_idx: u32 = @intCast(self.hir.export_payloads.items.len);
        try self.hir.export_payloads.append(self.hir.gpa, .{
            .decl = decl,
            .named_start = named_start,
            .named_len = @intCast(named.len),
            .module = module,
            .is_type_only = is_type_only,
            .is_default = is_default,
            .is_namespace = is_namespace,
            .namespace_alias = namespace_alias,
            .namespace_alias_is_string_literal = namespace_alias_is_string_literal,
            .namespace_alias_pos = namespace_alias_pos,
        });
        const id = try self.newNode(.export_decl, span, payload_idx);
        if (decl != none_node_id) self.hir.setParent(decl, id);
        for (named) |n| self.hir.setParent(n, id);
        return id;
    }

    pub fn addArrayLiteral(self: *Builder, span: Span, elements: []const NodeId) !NodeId {
        const elements_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, elements);
        const payload_idx: u32 = @intCast(self.hir.array_literal_payloads.items.len);
        try self.hir.array_literal_payloads.append(self.hir.gpa, .{
            .elements_start = elements_start,
            .elements_len = @intCast(elements.len),
        });
        const id = try self.newNode(.array_literal, span, payload_idx);
        for (elements) |e| if (e != none_node_id) self.hir.setParent(e, id);
        return id;
    }

    pub fn addObjectProperty(
        self: *Builder,
        span: Span,
        key: NodeId,
        value: NodeId,
        is_computed: bool,
        is_shorthand: bool,
        is_method: bool,
    ) !NodeId {
        return self.addObjectPropertyTyped(span, key, value, none_node_id, is_computed, is_shorthand, is_method);
    }

    pub fn addObjectPropertyTyped(
        self: *Builder,
        span: Span,
        key: NodeId,
        value: NodeId,
        type_annotation: NodeId,
        is_computed: bool,
        is_shorthand: bool,
        is_method: bool,
    ) !NodeId {
        return self.addObjectPropertyFull(
            span,
            key,
            value,
            type_annotation,
            is_computed,
            is_shorthand,
            is_method,
            false,
            .public,
            false,
        );
    }

    /// Variant of `addObjectPropertyTyped` that also records TS
    /// member visibility. Class members go through this path so
    /// the checker can enforce `private` at the access site.
    pub fn addObjectPropertyFull(
        self: *Builder,
        span: Span,
        key: NodeId,
        value: NodeId,
        type_annotation: NodeId,
        is_computed: bool,
        is_shorthand: bool,
        is_method: bool,
        is_static: bool,
        visibility: Visibility,
        is_override: bool,
    ) !NodeId {
        return self.addObjectPropertyFullEx(span, key, value, type_annotation, is_computed, is_shorthand, is_method, is_static, visibility, is_override, false);
    }

    /// Extended variant that also records the TS 4.9 `accessor` field
    /// modifier. Callers that need to mark a field as an auto-accessor
    /// (paired getter/setter backed by private storage) go through this
    /// path so the emit + Stage 3 decorator emitter can detect it.
    pub fn addObjectPropertyFullEx(
        self: *Builder,
        span: Span,
        key: NodeId,
        value: NodeId,
        type_annotation: NodeId,
        is_computed: bool,
        is_shorthand: bool,
        is_method: bool,
        is_static: bool,
        visibility: Visibility,
        is_override: bool,
        is_accessor: bool,
    ) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.object_property_payloads.items.len);
        try self.hir.object_property_payloads.append(self.hir.gpa, .{
            .key = key,
            .value = value,
            .type_annotation = type_annotation,
            .is_computed = is_computed,
            .is_shorthand = is_shorthand,
            .is_method = is_method,
            .is_static = is_static,
            .visibility = visibility,
            .is_override = is_override,
            .is_accessor = is_accessor,
        });
        const id = try self.newNode(.object_property, span, payload_idx);
        self.hir.setParent(key, id);
        if (value != none_node_id) self.hir.setParent(value, id);
        if (type_annotation != none_node_id) self.hir.setParent(type_annotation, id);
        return id;
    }

    /// Add a variable declaration. `kind` must be one of
    /// `.var_decl`, `.let_decl`, `.const_decl`.
    pub fn addVarDecl(
        self: *Builder,
        kind: NodeKind,
        span: Span,
        name: NodeId,
        type_annotation: NodeId,
        init_node: NodeId,
    ) !NodeId {
        return self.addVarDeclEx(kind, span, name, type_annotation, init_node, false, false, false);
    }

    /// Variant of `addVarDecl` that records the Stage 3 resource
    /// management flags (`using` / `await using`). The binding is still
    /// represented as a `const_decl` node — the flags ride on the
    /// payload so v0 consumers continue to treat it as `const`.
    pub fn addVarDeclEx(
        self: *Builder,
        kind: NodeKind,
        span: Span,
        name: NodeId,
        type_annotation: NodeId,
        init_node: NodeId,
        is_using: bool,
        is_await_using: bool,
        is_ambient: bool,
    ) !NodeId {
        std.debug.assert(kind == .var_decl or kind == .let_decl or kind == .const_decl);
        const payload_idx: u32 = @intCast(self.hir.var_decl_payloads.items.len);
        try self.hir.var_decl_payloads.append(self.hir.gpa, .{
            .name = name,
            .type_annotation = type_annotation,
            .init = init_node,
            .is_ambient = is_ambient,
            .is_using = is_using,
            .is_await_using = is_await_using,
        });
        const id = try self.newNode(kind, span, payload_idx);
        if (name != none_node_id) self.hir.setParent(name, id);
        if (type_annotation != none_node_id) self.hir.setParent(type_annotation, id);
        if (init_node != none_node_id) self.hir.setParent(init_node, id);
        return id;
    }

    pub fn addObjectLiteral(self: *Builder, span: Span, props: []const NodeId) !NodeId {
        const props_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, props);
        const payload_idx: u32 = @intCast(self.hir.object_literal_payloads.items.len);
        try self.hir.object_literal_payloads.append(self.hir.gpa, .{
            .props_start = props_start,
            .props_len = @intCast(props.len),
        });
        const id = try self.newNode(.object_literal, span, payload_idx);
        for (props) |p| self.hir.setParent(p, id);
        return id;
    }

    // ---- Type-system nodes -----------------------------------------------

    pub fn addTypeRef(
        self: *Builder,
        span: Span,
        name: StringId,
        qualifier: []const NodeId,
        args: []const NodeId,
    ) !NodeId {
        const q_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, qualifier);
        const a_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, args);
        const payload_idx: u32 = @intCast(self.hir.type_ref_payloads.items.len);
        try self.hir.type_ref_payloads.append(self.hir.gpa, .{
            .name = name,
            .qualifier_start = q_start,
            .qualifier_len = @intCast(qualifier.len),
            .args_start = a_start,
            .args_len = @intCast(args.len),
        });
        const id = try self.newNode(.type_ref, span, payload_idx);
        for (qualifier) |q| self.hir.setParent(q, id);
        for (args) |a| self.hir.setParent(a, id);
        return id;
    }

    pub fn addUnionType(self: *Builder, span: Span, members: []const NodeId) !NodeId {
        const start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, members);
        const payload_idx: u32 = @intCast(self.hir.union_type_payloads.items.len);
        try self.hir.union_type_payloads.append(self.hir.gpa, .{
            .members_start = start,
            .members_len = @intCast(members.len),
        });
        const id = try self.newNode(.union_type, span, payload_idx);
        for (members) |m| self.hir.setParent(m, id);
        return id;
    }

    pub fn addIntersectionType(self: *Builder, span: Span, members: []const NodeId) !NodeId {
        const start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, members);
        const payload_idx: u32 = @intCast(self.hir.intersection_type_payloads.items.len);
        try self.hir.intersection_type_payloads.append(self.hir.gpa, .{
            .members_start = start,
            .members_len = @intCast(members.len),
        });
        const id = try self.newNode(.intersection_type, span, payload_idx);
        for (members) |m| self.hir.setParent(m, id);
        return id;
    }

    pub fn addArrayType(self: *Builder, span: Span, element: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.array_type_payloads.items.len);
        try self.hir.array_type_payloads.append(self.hir.gpa, .{ .element = element });
        const id = try self.newNode(.array_type, span, payload_idx);
        self.hir.setParent(element, id);
        return id;
    }

    pub fn addRestType(self: *Builder, span: Span, operand: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.rest_type_payloads.items.len);
        try self.hir.rest_type_payloads.append(self.hir.gpa, .{ .operand = operand });
        const id = try self.newNode(.rest_type, span, payload_idx);
        self.hir.setParent(operand, id);
        return id;
    }

    pub fn addOptionalType(self: *Builder, span: Span, operand: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.optional_type_payloads.items.len);
        try self.hir.optional_type_payloads.append(self.hir.gpa, .{ .operand = operand });
        const id = try self.newNode(.optional_type, span, payload_idx);
        self.hir.setParent(operand, id);
        return id;
    }

    pub fn addTupleType(self: *Builder, span: Span, elements: []const NodeId) !NodeId {
        const start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, elements);
        const payload_idx: u32 = @intCast(self.hir.tuple_type_payloads.items.len);
        try self.hir.tuple_type_payloads.append(self.hir.gpa, .{
            .elements_start = start,
            .elements_len = @intCast(elements.len),
        });
        const id = try self.newNode(.tuple_type, span, payload_idx);
        for (elements) |e| self.hir.setParent(e, id);
        return id;
    }

    pub fn addFnType(
        self: *Builder,
        span: Span,
        type_params: []const NodeId,
        params: []const NodeId,
        return_type: NodeId,
        is_constructor: bool,
        is_abstract_constructor: bool,
    ) !NodeId {
        const tp_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, type_params);
        const p_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, params);
        const payload_idx: u32 = @intCast(self.hir.fn_type_payloads.items.len);
        try self.hir.fn_type_payloads.append(self.hir.gpa, .{
            .type_params_start = tp_start,
            .type_params_len = @intCast(type_params.len),
            .params_start = p_start,
            .params_len = @intCast(params.len),
            .return_type = return_type,
            .is_constructor = is_constructor,
            .is_abstract_constructor = is_abstract_constructor,
        });
        const kind: NodeKind = if (is_constructor) .constructor_type else .fn_type;
        const id = try self.newNode(kind, span, payload_idx);
        for (type_params) |tp| self.hir.setParent(tp, id);
        for (params) |p| self.hir.setParent(p, id);
        if (return_type != none_node_id) self.hir.setParent(return_type, id);
        return id;
    }

    pub fn addIndexedAccessType(self: *Builder, span: Span, object: NodeId, index: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.indexed_access_type_payloads.items.len);
        try self.hir.indexed_access_type_payloads.append(self.hir.gpa, .{
            .object = object,
            .index = index,
        });
        const id = try self.newNode(.indexed_access_type, span, payload_idx);
        self.hir.setParent(object, id);
        self.hir.setParent(index, id);
        return id;
    }

    pub fn addKeyofType(self: *Builder, span: Span, operand: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.keyof_type_payloads.items.len);
        try self.hir.keyof_type_payloads.append(self.hir.gpa, .{ .operand = operand });
        const id = try self.newNode(.keyof_type, span, payload_idx);
        self.hir.setParent(operand, id);
        return id;
    }

    pub fn addTypeofType(self: *Builder, span: Span, operand: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.typeof_type_payloads.items.len);
        try self.hir.typeof_type_payloads.append(self.hir.gpa, .{ .operand = operand });
        const id = try self.newNode(.typeof_type, span, payload_idx);
        self.hir.setParent(operand, id);
        return id;
    }

    pub fn addReadonlyType(self: *Builder, span: Span, operand: NodeId, operand_parenthesized: bool) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.readonly_type_payloads.items.len);
        try self.hir.readonly_type_payloads.append(self.hir.gpa, .{
            .operand = operand,
            .operand_parenthesized = operand_parenthesized,
        });
        const id = try self.newNode(.readonly_type, span, payload_idx);
        self.hir.setParent(operand, id);
        return id;
    }

    pub fn addTemplateLiteralType(
        self: *Builder,
        span: Span,
        text_parts: []const NodeId,
        type_parts: []const NodeId,
    ) !NodeId {
        std.debug.assert(text_parts.len == type_parts.len + 1);
        const tp_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, text_parts);
        const tp_len: u16 = @intCast(text_parts.len);
        const tt_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, type_parts);
        const tt_len: u16 = @intCast(type_parts.len);
        const payload_idx: u32 = @intCast(self.hir.template_literal_type_payloads.items.len);
        try self.hir.template_literal_type_payloads.append(self.hir.gpa, .{
            .text_parts_start = tp_start,
            .text_parts_len = tp_len,
            .type_parts_start = tt_start,
            .type_parts_len = tt_len,
        });
        const id = try self.newNode(.template_literal_type, span, payload_idx);
        for (text_parts) |t| if (t != none_node_id) self.hir.setParent(t, id);
        for (type_parts) |t| if (t != none_node_id) self.hir.setParent(t, id);
        return id;
    }

    /// Build a template-literal *expression* (value position):
    /// `\`a${x}b${y}c\``. `texts` are `literal_string` nodes (one
    /// more than `exprs`); `exprs` are arbitrary expression nodes.
    pub fn addTemplateLiteralExpr(
        self: *Builder,
        span: Span,
        texts: []const NodeId,
        exprs: []const NodeId,
    ) !NodeId {
        std.debug.assert(texts.len == exprs.len + 1);
        const tx_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, texts);
        const tx_len: u16 = @intCast(texts.len);
        const ex_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, exprs);
        const ex_len: u16 = @intCast(exprs.len);
        const payload_idx: u32 = @intCast(self.hir.template_literal_payloads.items.len);
        try self.hir.template_literal_payloads.append(self.hir.gpa, .{
            .texts_start = tx_start,
            .texts_len = tx_len,
            .exprs_start = ex_start,
            .exprs_len = ex_len,
        });
        const id = try self.newNode(.template_literal, span, payload_idx);
        for (texts) |t| if (t != none_node_id) self.hir.setParent(t, id);
        for (exprs) |e| if (e != none_node_id) self.hir.setParent(e, id);
        return id;
    }

    pub fn addTypePredicate(
        self: *Builder,
        span: Span,
        param_index: u16,
        param_name: StringId,
        target_type: NodeId,
        is_asserts: bool,
    ) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.type_predicate_payloads.items.len);
        try self.hir.type_predicate_payloads.append(self.hir.gpa, .{
            .param_index = param_index,
            .param_name = param_name,
            .target_type = target_type,
            .is_asserts = is_asserts,
        });
        const id = try self.newNode(.type_predicate_type, span, payload_idx);
        if (target_type != none_node_id) self.hir.setParent(target_type, id);
        return id;
    }

    /// Build an `as` / `satisfies` / legacy `<T>x` type-assertion
    /// expression. `kind` must be one of `.as_expr`, `.satisfies_expr`,
    /// `.type_assertion`. The shape is the same — `expr` is the
    /// inner runtime expression, `type_node` is the asserted type.
    pub fn addAsExpression(
        self: *Builder,
        kind: NodeKind,
        span: Span,
        expr: NodeId,
        type_node: NodeId,
    ) !NodeId {
        std.debug.assert(kind == .as_expr or kind == .satisfies_expr or kind == .type_assertion);
        const payload_idx: u32 = @intCast(self.hir.as_expression_payloads.items.len);
        try self.hir.as_expression_payloads.append(self.hir.gpa, .{
            .expr = expr,
            .type_node = type_node,
        });
        const id = try self.newNode(kind, span, payload_idx);
        self.hir.setParent(expr, id);
        if (type_node != none_node_id) self.hir.setParent(type_node, id);
        return id;
    }

    /// Build a postfix non-null assertion `expr!`. Reuses the
    /// `AsExpressionPayload` shape with `type_node = none_node_id`
    /// — the checker subtracts `null | undefined` from `expr`'s
    /// type rather than substituting an asserted type.
    pub fn addNonNullExpression(self: *Builder, span: Span, expr: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.as_expression_payloads.items.len);
        try self.hir.as_expression_payloads.append(self.hir.gpa, .{
            .expr = expr,
            .type_node = none_node_id,
        });
        const id = try self.newNode(.non_null_expr, span, payload_idx);
        self.hir.setParent(expr, id);
        return id;
    }

    /// `await expr` — reuses the AsExpression shape with no type-node.
    /// The checker types it as `T` when the operand is `Promise<T>`.
    pub fn addAwaitExpr(self: *Builder, span: Span, expr: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.as_expression_payloads.items.len);
        try self.hir.as_expression_payloads.append(self.hir.gpa, .{
            .expr = expr,
            .type_node = none_node_id,
        });
        const id = try self.newNode(.await_expr, span, payload_idx);
        self.hir.setParent(expr, id);
        return id;
    }

    /// `yield expr` / `yield* expr` — reuses the AsExpression shape;
    /// `type_node` is `none_node_id` for plain yield, set to a
    /// sentinel-shape for `yield*` (delegated yield).
    pub fn addYieldExpr(self: *Builder, span: Span, expr: NodeId, is_delegated: bool) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.as_expression_payloads.items.len);
        try self.hir.as_expression_payloads.append(self.hir.gpa, .{
            .expr = expr,
            // We encode is_delegated as a non-zero sentinel in
            // type_node — yield's `type_node` slot is otherwise unused.
            .type_node = if (is_delegated) 1 else none_node_id,
        });
        const id = try self.newNode(.yield_expr, span, payload_idx);
        if (expr != none_node_id) self.hir.setParent(expr, id);
        return id;
    }

    /// Build an `[k: K]: V` index signature member.
    pub fn addIndexSignature(
        self: *Builder,
        span: Span,
        key_type: NodeId,
        value_type: NodeId,
        is_readonly: bool,
        is_static: bool,
        key_name: StringId,
    ) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.index_signature_payloads.items.len);
        try self.hir.index_signature_payloads.append(self.hir.gpa, .{
            .key_type = key_type,
            .value_type = value_type,
            .is_readonly = is_readonly,
            .is_static = is_static,
            .key_name = key_name,
        });
        const id = try self.newNode(.index_signature, span, payload_idx);
        if (key_type != none_node_id) self.hir.setParent(key_type, id);
        if (value_type != none_node_id) self.hir.setParent(value_type, id);
        return id;
    }

    pub fn addConditionalType(
        self: *Builder,
        span: Span,
        check: NodeId,
        extends: NodeId,
        true_branch: NodeId,
        false_branch: NodeId,
    ) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.conditional_type_payloads.items.len);
        try self.hir.conditional_type_payloads.append(self.hir.gpa, .{
            .check = check,
            .extends = extends,
            .true_branch = true_branch,
            .false_branch = false_branch,
        });
        const id = try self.newNode(.conditional_type, span, payload_idx);
        self.hir.setParent(check, id);
        self.hir.setParent(extends, id);
        self.hir.setParent(true_branch, id);
        self.hir.setParent(false_branch, id);
        return id;
    }

    pub fn addInferType(self: *Builder, span: Span, name: StringId, constraint: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.infer_type_payloads.items.len);
        try self.hir.infer_type_payloads.append(self.hir.gpa, .{
            .name = name,
            .constraint = constraint,
        });
        const id = try self.newNode(.infer_type, span, payload_idx);
        if (constraint != none_node_id) self.hir.setParent(constraint, id);
        return id;
    }

    pub fn addLiteralType(self: *Builder, span: Span, literal: NodeId, negative: bool) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.literal_type_payloads.items.len);
        try self.hir.literal_type_payloads.append(self.hir.gpa, .{
            .literal = literal,
            .negative = negative,
        });
        const id = try self.newNode(.type_literal, span, payload_idx);
        self.hir.setParent(literal, id);
        return id;
    }

    pub fn addTypeParameter(
        self: *Builder,
        span: Span,
        name: StringId,
        constraint: NodeId,
        default: NodeId,
        variance: u8,
        is_const: bool,
    ) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.type_parameter_payloads.items.len);
        try self.hir.type_parameter_payloads.append(self.hir.gpa, .{
            .name = name,
            .constraint = constraint,
            .default = default,
            .variance = variance,
            .is_const = is_const,
        });
        const id = try self.newNode(.type_parameter, span, payload_idx);
        if (constraint != none_node_id) self.hir.setParent(constraint, id);
        if (default != none_node_id) self.hir.setParent(default, id);
        return id;
    }

    // ---- JSX nodes -------------------------------------------------------

    pub fn addJsxAttribute(self: *Builder, span: Span, name: StringId, value: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.jsx_attribute_payloads.items.len);
        try self.hir.jsx_attribute_payloads.append(self.hir.gpa, .{ .name = name, .value = value });
        const id = try self.newNode(.jsx_attribute, span, payload_idx);
        if (value != none_node_id) self.hir.setParent(value, id);
        return id;
    }

    pub fn addJsxSpreadAttribute(self: *Builder, span: Span, expr: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.jsx_spread_attribute_payloads.items.len);
        try self.hir.jsx_spread_attribute_payloads.append(self.hir.gpa, .{ .expression = expr });
        const id = try self.newNode(.jsx_spread_attribute, span, payload_idx);
        self.hir.setParent(expr, id);
        return id;
    }

    /// `...expr` — a spread element inside an array literal or
    /// argument list. Reuses `JsxSpreadAttributePayload`'s
    /// `{ expression: NodeId }` shape.
    pub fn addSpread(self: *Builder, span: Span, expr: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.jsx_spread_attribute_payloads.items.len);
        try self.hir.jsx_spread_attribute_payloads.append(self.hir.gpa, .{ .expression = expr });
        const id = try self.newNode(.spread, span, payload_idx);
        self.hir.setParent(expr, id);
        return id;
    }

    pub fn addJsxExpression(self: *Builder, span: Span, expr: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.jsx_expression_payloads.items.len);
        try self.hir.jsx_expression_payloads.append(self.hir.gpa, .{ .expression = expr });
        const id = try self.newNode(.jsx_expression, span, payload_idx);
        if (expr != none_node_id) self.hir.setParent(expr, id);
        return id;
    }

    pub fn addJsxElement(
        self: *Builder,
        span: Span,
        tag: NodeId,
        attrs: []const NodeId,
        children: []const NodeId,
        self_closing: bool,
    ) !NodeId {
        const a_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, attrs);
        const c_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, children);
        const payload_idx: u32 = @intCast(self.hir.jsx_element_payloads.items.len);
        try self.hir.jsx_element_payloads.append(self.hir.gpa, .{
            .tag = tag,
            .attrs_start = a_start,
            .attrs_len = @intCast(attrs.len),
            .children_start = c_start,
            .children_len = @intCast(children.len),
            .self_closing = self_closing,
        });
        const kind: NodeKind = if (self_closing) .jsx_self_closing else .jsx_element;
        const id = try self.newNode(kind, span, payload_idx);
        self.hir.setParent(tag, id);
        for (attrs) |a| self.hir.setParent(a, id);
        for (children) |c| self.hir.setParent(c, id);
        return id;
    }

    pub fn addInterfaceMember(
        self: *Builder,
        span: Span,
        name: StringId,
        type_node: NodeId,
        is_optional: bool,
        is_readonly: bool,
        is_method: bool,
        is_override: bool,
    ) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.interface_member_payloads.items.len);
        try self.hir.interface_member_payloads.append(self.hir.gpa, .{
            .name = name,
            .type_node = type_node,
            .is_optional = is_optional,
            .is_readonly = is_readonly,
            .is_method = is_method,
            .is_override = is_override,
        });
        const id = try self.newNode(.interface_member, span, payload_idx);
        if (type_node != none_node_id) self.hir.setParent(type_node, id);
        return id;
    }

    /// Record the computed key-expression for an `interface_member`
    /// (declared with `[expr]:` form). Stored in `ColdData` rather
    /// than the hot payload because only a handful of interface
    /// members are computed in real codebases.
    pub fn setInterfaceMemberKeyExpr(self: *Builder, member: NodeId, key_expr: NodeId) !void {
        std.debug.assert(self.hir.kindOf(member) == .interface_member);
        if (key_expr == none_node_id) return;
        try self.hir.cold.interface_member_key_expr.put(self.hir.gpa, member, key_expr);
        self.hir.setParent(key_expr, member);
    }

    pub fn addObjectType(self: *Builder, span: Span, members: []const NodeId) !NodeId {
        const start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, members);
        const payload_idx: u32 = @intCast(self.hir.object_type_payloads.items.len);
        try self.hir.object_type_payloads.append(self.hir.gpa, .{
            .members_start = start,
            .members_len = @intCast(members.len),
        });
        const id = try self.newNode(.object_type, span, payload_idx);
        for (members) |m| self.hir.setParent(m, id);
        return id;
    }

    pub fn addDecorator(self: *Builder, span: Span, expression: NodeId) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.decorator_payloads.items.len);
        try self.hir.decorator_payloads.append(self.hir.gpa, .{ .expression = expression });
        const id = try self.newNode(.decorator, span, payload_idx);
        self.hir.setParent(expression, id);
        return id;
    }

    pub fn addJsxFragment(self: *Builder, span: Span, children: []const NodeId) !NodeId {
        const c_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, children);
        const payload_idx: u32 = @intCast(self.hir.jsx_fragment_payloads.items.len);
        try self.hir.jsx_fragment_payloads.append(self.hir.gpa, .{
            .children_start = c_start,
            .children_len = @intCast(children.len),
        });
        const id = try self.newNode(.jsx_fragment, span, payload_idx);
        for (children) |c| self.hir.setParent(c, id);
        return id;
    }

    pub fn addMappedType(
        self: *Builder,
        span: Span,
        type_param: NodeId,
        constraint: NodeId,
        value: NodeId,
        remap: NodeId,
        readonly: u8,
        optional: u8,
    ) !NodeId {
        const payload_idx: u32 = @intCast(self.hir.mapped_type_payloads.items.len);
        try self.hir.mapped_type_payloads.append(self.hir.gpa, .{
            .type_param = type_param,
            .constraint = constraint,
            .value = value,
            .remap = remap,
            .readonly = readonly,
            .optional = optional,
        });
        const id = try self.newNode(.mapped_type, span, payload_idx);
        self.hir.setParent(type_param, id);
        if (constraint != none_node_id) self.hir.setParent(constraint, id);
        if (value != none_node_id) self.hir.setParent(value, id);
        if (remap != none_node_id) self.hir.setParent(remap, id);
        return id;
    }
};

// ============================================================================
// Payload accessors
// ============================================================================

pub fn binopOf(hir: *const Hir, id: NodeId) BinopPayload {
    std.debug.assert(hir.kindOf(id) == .binary_op);
    return hir.binop_payloads.items[hir.payloads.items[id]];
}

pub fn unaryOf(hir: *const Hir, id: NodeId) UnaryPayload {
    std.debug.assert(hir.kindOf(id) == .unary_op);
    return hir.unary_payloads.items[hir.payloads.items[id]];
}

pub fn logicalOf(hir: *const Hir, id: NodeId) LogicalPayload {
    std.debug.assert(hir.kindOf(id) == .logical_op);
    return hir.logical_payloads.items[hir.payloads.items[id]];
}

pub fn callOf(hir: *const Hir, id: NodeId) CallPayload {
    const k = hir.kindOf(id);
    std.debug.assert(k == .call_expr or k == .new_expr);
    return hir.call_payloads.items[hir.payloads.items[id]];
}

pub fn memberOf(hir: *const Hir, id: NodeId) MemberPayload {
    std.debug.assert(hir.kindOf(id) == .member_access);
    return hir.member_payloads.items[hir.payloads.items[id]];
}

pub fn elementOf(hir: *const Hir, id: NodeId) ElementPayload {
    std.debug.assert(hir.kindOf(id) == .element_access);
    return hir.element_payloads.items[hir.payloads.items[id]];
}

pub fn identifierOf(hir: *const Hir, id: NodeId) IdentifierPayload {
    std.debug.assert(hir.kindOf(id) == .identifier);
    return hir.identifier_payloads.items[hir.payloads.items[id]];
}

pub fn literalStringOf(hir: *const Hir, id: NodeId) LiteralStringPayload {
    std.debug.assert(hir.kindOf(id) == .literal_string);
    return hir.string_payloads.items[hir.payloads.items[id]];
}

pub fn literalNumberOf(hir: *const Hir, id: NodeId) f64 {
    std.debug.assert(hir.kindOf(id) == .literal_number);
    const p = hir.number_payloads.items[hir.payloads.items[id]];
    return @bitCast(p.bits);
}

pub fn literalBigIntOf(hir: *const Hir, id: NodeId) LiteralBigIntPayload {
    std.debug.assert(hir.kindOf(id) == .literal_bigint);
    return hir.bigint_payloads.items[hir.payloads.items[id]];
}

pub fn literalBoolOf(hir: *const Hir, id: NodeId) bool {
    std.debug.assert(hir.kindOf(id) == .literal_bool);
    return hir.bool_payloads.items[hir.payloads.items[id]].value;
}

pub fn conditionalOf(hir: *const Hir, id: NodeId) ConditionalPayload {
    std.debug.assert(hir.kindOf(id) == .conditional);
    return hir.conditional_payloads.items[hir.payloads.items[id]];
}

pub fn assignmentOf(hir: *const Hir, id: NodeId) AssignmentPayload {
    std.debug.assert(hir.kindOf(id) == .assignment);
    return hir.assignment_payloads.items[hir.payloads.items[id]];
}

pub fn blockOf(hir: *const Hir, id: NodeId) BlockPayload {
    std.debug.assert(hir.kindOf(id) == .block_stmt);
    return hir.block_payloads.items[hir.payloads.items[id]];
}

pub fn ifOf(hir: *const Hir, id: NodeId) IfPayload {
    std.debug.assert(hir.kindOf(id) == .if_stmt);
    return hir.if_payloads.items[hir.payloads.items[id]];
}

pub fn returnOf(hir: *const Hir, id: NodeId) ReturnPayload {
    std.debug.assert(hir.kindOf(id) == .return_stmt);
    return hir.return_payloads.items[hir.payloads.items[id]];
}

pub fn callArgs(hir: *const Hir, id: NodeId) []const NodeId {
    const p = callOf(hir, id);
    return hir.childSlice(p.args_start, p.args_len);
}

/// Explicit type arguments on a generic call (`f<T>(args)`).
/// Empty if the call site uses inference only.
pub fn callTypeArgs(hir: *const Hir, id: NodeId) []const NodeId {
    const p = callOf(hir, id);
    return hir.childSlice(p.type_args_start, p.type_args_len);
}

pub fn blockStmts(hir: *const Hir, id: NodeId) []const NodeId {
    const p = blockOf(hir, id);
    return hir.childSlice(p.stmts_start, p.stmts_len);
}

pub fn whileOf(hir: *const Hir, id: NodeId) WhilePayload {
    std.debug.assert(hir.kindOf(id) == .while_stmt);
    return hir.while_payloads.items[hir.payloads.items[id]];
}

pub fn doWhileOf(hir: *const Hir, id: NodeId) DoWhilePayload {
    std.debug.assert(hir.kindOf(id) == .do_while_stmt);
    return hir.do_while_payloads.items[hir.payloads.items[id]];
}

pub fn forStmtOf(hir: *const Hir, id: NodeId) ForPayload {
    std.debug.assert(hir.kindOf(id) == .for_stmt);
    return hir.for_payloads.items[hir.payloads.items[id]];
}

pub fn forInOf(hir: *const Hir, id: NodeId) ForInOfPayload {
    const k = hir.kindOf(id);
    std.debug.assert(k == .for_in_stmt or k == .for_of_stmt);
    return hir.for_in_of_payloads.items[hir.payloads.items[id]];
}

pub fn throwOf(hir: *const Hir, id: NodeId) ThrowPayload {
    std.debug.assert(hir.kindOf(id) == .throw_stmt);
    return hir.throw_payloads.items[hir.payloads.items[id]];
}

pub fn tryOf(hir: *const Hir, id: NodeId) TryPayload {
    std.debug.assert(hir.kindOf(id) == .try_stmt);
    return hir.try_payloads.items[hir.payloads.items[id]];
}

pub fn switchCaseOf(hir: *const Hir, id: NodeId) SwitchCasePayload {
    std.debug.assert(hir.kindOf(id) == .switch_case);
    return hir.switch_case_payloads.items[hir.payloads.items[id]];
}

pub fn switchCaseStmts(hir: *const Hir, id: NodeId) []const NodeId {
    const p = switchCaseOf(hir, id);
    return hir.childSlice(p.stmts_start, p.stmts_len);
}

pub fn switchOf(hir: *const Hir, id: NodeId) SwitchPayload {
    std.debug.assert(hir.kindOf(id) == .switch_stmt);
    return hir.switch_payloads.items[hir.payloads.items[id]];
}

pub fn switchCases(hir: *const Hir, id: NodeId) []const NodeId {
    const p = switchOf(hir, id);
    return hir.childSlice(p.cases_start, p.cases_len);
}

pub fn labelOf(hir: *const Hir, id: NodeId) LabelPayload {
    const k = hir.kindOf(id);
    std.debug.assert(k == .break_stmt or k == .continue_stmt);
    return hir.label_payloads.items[hir.payloads.items[id]];
}

pub fn labeledStmtOf(hir: *const Hir, id: NodeId) LabeledStmtPayload {
    std.debug.assert(hir.kindOf(id) == .labeled_stmt);
    return hir.labeled_stmt_payloads.items[hir.payloads.items[id]];
}

pub fn fnDeclOf(hir: *const Hir, id: NodeId) FnDeclPayload {
    const k = hir.kindOf(id);
    std.debug.assert(k == .fn_decl or k == .fn_expr or k == .arrow_fn);
    return hir.fn_decl_payloads.items[hir.payloads.items[id]];
}

pub fn fnParams(hir: *const Hir, id: NodeId) []const NodeId {
    const p = fnDeclOf(hir, id);
    return hir.childSlice(p.params_start, p.params_len);
}

pub fn fnTypeParams(hir: *const Hir, id: NodeId) []const NodeId {
    const p = fnDeclOf(hir, id);
    return hir.childSlice(p.type_params_start, p.type_params_len);
}

pub fn parameterOf(hir: *const Hir, id: NodeId) ParameterPayload {
    std.debug.assert(hir.kindOf(id) == .parameter);
    return hir.parameter_payloads.items[hir.payloads.items[id]];
}

/// Decorator nodes attached to a parameter. Empty when the parameter
/// has no `@dec` annotations.
pub fn parameterDecorators(hir: *const Hir, id: NodeId) []const NodeId {
    const p = parameterOf(hir, id);
    return hir.childSlice(p.decorators_start, p.decorators_len);
}

pub fn patternOf(hir: *const Hir, id: NodeId) PatternPayload {
    std.debug.assert(hir.kindOf(id) == .object_pattern or hir.kindOf(id) == .array_pattern);
    return hir.pattern_payloads.items[hir.payloads.items[id]];
}

pub fn patternElements(hir: *const Hir, id: NodeId) []const NodeId {
    const p = patternOf(hir, id);
    return hir.childSlice(p.elements_start, p.elements_len);
}

pub fn typeAliasOf(hir: *const Hir, id: NodeId) TypeAliasPayload {
    std.debug.assert(hir.kindOf(id) == .type_alias_decl);
    return hir.type_alias_payloads.items[hir.payloads.items[id]];
}

pub fn interfaceOf(hir: *const Hir, id: NodeId) InterfacePayload {
    std.debug.assert(hir.kindOf(id) == .interface_decl);
    return hir.interface_payloads.items[hir.payloads.items[id]];
}

pub fn interfaceMembers(hir: *const Hir, id: NodeId) []const NodeId {
    const p = interfaceOf(hir, id);
    return hir.childSlice(p.members_start, p.members_len);
}

pub fn interfaceExtends(hir: *const Hir, id: NodeId) []const NodeId {
    const p = interfaceOf(hir, id);
    return hir.childSlice(p.extends_start, p.extends_len);
}

pub fn classOf(hir: *const Hir, id: NodeId) ClassPayload {
    std.debug.assert(hir.kindOf(id) == .class_decl or hir.kindOf(id) == .class_expr);
    return hir.class_payloads.items[hir.payloads.items[id]];
}

pub fn classMembers(hir: *const Hir, id: NodeId) []const NodeId {
    const p = classOf(hir, id);
    return hir.childSlice(p.members_start, p.members_len);
}

pub fn enumOf(hir: *const Hir, id: NodeId) EnumPayload {
    std.debug.assert(hir.kindOf(id) == .enum_decl);
    return hir.enum_payloads.items[hir.payloads.items[id]];
}

pub fn enumMembers(hir: *const Hir, id: NodeId) []const NodeId {
    const p = enumOf(hir, id);
    return hir.childSlice(p.members_start, p.members_len);
}

pub fn namespaceOf(hir: *const Hir, id: NodeId) NamespacePayload {
    std.debug.assert(hir.kindOf(id) == .namespace_decl);
    return hir.namespace_payloads.items[hir.payloads.items[id]];
}

pub fn namespaceBody(hir: *const Hir, id: NodeId) []const NodeId {
    const p = namespaceOf(hir, id);
    return hir.childSlice(p.body_start, p.body_len);
}

pub fn importOf(hir: *const Hir, id: NodeId) ImportPayload {
    std.debug.assert(hir.kindOf(id) == .import_decl);
    return hir.import_payloads.items[hir.payloads.items[id]];
}

pub fn importNamed(hir: *const Hir, id: NodeId) []const NodeId {
    const p = importOf(hir, id);
    return hir.childSlice(p.named_start, p.named_len);
}

pub fn exportOf(hir: *const Hir, id: NodeId) ExportPayload {
    std.debug.assert(hir.kindOf(id) == .export_decl);
    return hir.export_payloads.items[hir.payloads.items[id]];
}

pub fn exportNamed(hir: *const Hir, id: NodeId) []const NodeId {
    const p = exportOf(hir, id);
    return hir.childSlice(p.named_start, p.named_len);
}

pub fn importSpecifierOf(hir: *const Hir, id: NodeId) ImportSpecifierPayload {
    std.debug.assert(hir.kindOf(id) == .import_specifier);
    return hir.import_specifier_payloads.items[hir.payloads.items[id]];
}

pub fn arrayLiteralOf(hir: *const Hir, id: NodeId) ArrayLiteralPayload {
    std.debug.assert(hir.kindOf(id) == .array_literal);
    return hir.array_literal_payloads.items[hir.payloads.items[id]];
}

pub fn arrayLiteralElements(hir: *const Hir, id: NodeId) []const NodeId {
    const p = arrayLiteralOf(hir, id);
    return hir.childSlice(p.elements_start, p.elements_len);
}

pub fn objectLiteralOf(hir: *const Hir, id: NodeId) ObjectLiteralPayload {
    std.debug.assert(hir.kindOf(id) == .object_literal);
    return hir.object_literal_payloads.items[hir.payloads.items[id]];
}

pub fn objectLiteralProps(hir: *const Hir, id: NodeId) []const NodeId {
    const p = objectLiteralOf(hir, id);
    return hir.childSlice(p.props_start, p.props_len);
}

pub fn objectPropertyOf(hir: *const Hir, id: NodeId) ObjectPropertyPayload {
    std.debug.assert(hir.kindOf(id) == .object_property);
    return hir.object_property_payloads.items[hir.payloads.items[id]];
}

pub fn varDeclOf(hir: *const Hir, id: NodeId) VarDeclPayload {
    const k = hir.kindOf(id);
    std.debug.assert(k == .var_decl or k == .let_decl or k == .const_decl);
    return hir.var_decl_payloads.items[hir.payloads.items[id]];
}

pub fn typeRefOf(hir: *const Hir, id: NodeId) TypeRefPayload {
    std.debug.assert(hir.kindOf(id) == .type_ref);
    return hir.type_ref_payloads.items[hir.payloads.items[id]];
}

pub fn typeRefArgs(hir: *const Hir, id: NodeId) []const NodeId {
    const p = typeRefOf(hir, id);
    return hir.childSlice(p.args_start, p.args_len);
}

pub fn typeRefQualifier(hir: *const Hir, id: NodeId) []const NodeId {
    const p = typeRefOf(hir, id);
    return hir.childSlice(p.qualifier_start, p.qualifier_len);
}

pub fn unionTypeOf(hir: *const Hir, id: NodeId) UnionTypePayload {
    std.debug.assert(hir.kindOf(id) == .union_type);
    return hir.union_type_payloads.items[hir.payloads.items[id]];
}

pub fn unionTypeMembers(hir: *const Hir, id: NodeId) []const NodeId {
    const p = unionTypeOf(hir, id);
    return hir.childSlice(p.members_start, p.members_len);
}

pub fn intersectionTypeOf(hir: *const Hir, id: NodeId) IntersectionTypePayload {
    std.debug.assert(hir.kindOf(id) == .intersection_type);
    return hir.intersection_type_payloads.items[hir.payloads.items[id]];
}

pub fn intersectionTypeMembers(hir: *const Hir, id: NodeId) []const NodeId {
    const p = intersectionTypeOf(hir, id);
    return hir.childSlice(p.members_start, p.members_len);
}

pub fn arrayTypeOf(hir: *const Hir, id: NodeId) ArrayTypePayload {
    std.debug.assert(hir.kindOf(id) == .array_type);
    return hir.array_type_payloads.items[hir.payloads.items[id]];
}

pub fn tupleTypeOf(hir: *const Hir, id: NodeId) TupleTypePayload {
    std.debug.assert(hir.kindOf(id) == .tuple_type);
    return hir.tuple_type_payloads.items[hir.payloads.items[id]];
}

pub fn restTypeOf(hir: *const Hir, id: NodeId) RestTypePayload {
    std.debug.assert(hir.kindOf(id) == .rest_type);
    return hir.rest_type_payloads.items[hir.payloads.items[id]];
}

pub fn optionalTypeOf(hir: *const Hir, id: NodeId) OptionalTypePayload {
    std.debug.assert(hir.kindOf(id) == .optional_type);
    return hir.optional_type_payloads.items[hir.payloads.items[id]];
}

pub fn tupleTypeElements(hir: *const Hir, id: NodeId) []const NodeId {
    const p = tupleTypeOf(hir, id);
    return hir.childSlice(p.elements_start, p.elements_len);
}

pub fn fnTypeOf(hir: *const Hir, id: NodeId) FnTypePayload {
    const k = hir.kindOf(id);
    std.debug.assert(k == .fn_type or k == .constructor_type);
    return hir.fn_type_payloads.items[hir.payloads.items[id]];
}

pub fn indexedAccessTypeOf(hir: *const Hir, id: NodeId) IndexedAccessTypePayload {
    std.debug.assert(hir.kindOf(id) == .indexed_access_type);
    return hir.indexed_access_type_payloads.items[hir.payloads.items[id]];
}

pub fn keyofTypeOf(hir: *const Hir, id: NodeId) KeyofTypePayload {
    std.debug.assert(hir.kindOf(id) == .keyof_type);
    return hir.keyof_type_payloads.items[hir.payloads.items[id]];
}

pub fn awaitExprOf(hir: *const Hir, id: NodeId) AsExpressionPayload {
    std.debug.assert(hir.kindOf(id) == .await_expr);
    return hir.as_expression_payloads.items[hir.payloads.items[id]];
}

pub fn yieldExprOf(hir: *const Hir, id: NodeId) AsExpressionPayload {
    std.debug.assert(hir.kindOf(id) == .yield_expr);
    return hir.as_expression_payloads.items[hir.payloads.items[id]];
}

pub fn asExpressionOf(hir: *const Hir, id: NodeId) AsExpressionPayload {
    const k = hir.kindOf(id);
    std.debug.assert(k == .as_expr or k == .satisfies_expr or k == .type_assertion or k == .non_null_expr);
    return hir.as_expression_payloads.items[hir.payloads.items[id]];
}

pub fn indexSignatureOf(hir: *const Hir, id: NodeId) IndexSignaturePayload {
    std.debug.assert(hir.kindOf(id) == .index_signature);
    return hir.index_signature_payloads.items[hir.payloads.items[id]];
}

pub fn typeofTypeOf(hir: *const Hir, id: NodeId) TypeofTypePayload {
    std.debug.assert(hir.kindOf(id) == .typeof_type);
    return hir.typeof_type_payloads.items[hir.payloads.items[id]];
}

pub fn readonlyTypeOf(hir: *const Hir, id: NodeId) ReadonlyTypePayload {
    std.debug.assert(hir.kindOf(id) == .readonly_type);
    return hir.readonly_type_payloads.items[hir.payloads.items[id]];
}

pub fn typePredicateOf(hir: *const Hir, id: NodeId) TypePredicatePayload {
    std.debug.assert(hir.kindOf(id) == .type_predicate_type);
    return hir.type_predicate_payloads.items[hir.payloads.items[id]];
}

pub fn templateLiteralTypeOf(hir: *const Hir, id: NodeId) TemplateLiteralTypePayload {
    std.debug.assert(hir.kindOf(id) == .template_literal_type);
    return hir.template_literal_type_payloads.items[hir.payloads.items[id]];
}

pub fn templateLiteralTypeTexts(hir: *const Hir, id: NodeId) []const NodeId {
    const p = templateLiteralTypeOf(hir, id);
    return hir.childSlice(p.text_parts_start, p.text_parts_len);
}

pub fn templateLiteralTypeTypes(hir: *const Hir, id: NodeId) []const NodeId {
    const p = templateLiteralTypeOf(hir, id);
    return hir.childSlice(p.type_parts_start, p.type_parts_len);
}

pub fn templateLiteralOf(hir: *const Hir, id: NodeId) TemplateLiteralPayload {
    std.debug.assert(hir.kindOf(id) == .template_literal);
    return hir.template_literal_payloads.items[hir.payloads.items[id]];
}

pub fn templateLiteralTexts(hir: *const Hir, id: NodeId) []const NodeId {
    const p = templateLiteralOf(hir, id);
    return hir.childSlice(p.texts_start, p.texts_len);
}

pub fn templateLiteralExprs(hir: *const Hir, id: NodeId) []const NodeId {
    const p = templateLiteralOf(hir, id);
    return hir.childSlice(p.exprs_start, p.exprs_len);
}

pub fn conditionalTypeOf(hir: *const Hir, id: NodeId) ConditionalTypePayload {
    std.debug.assert(hir.kindOf(id) == .conditional_type);
    return hir.conditional_type_payloads.items[hir.payloads.items[id]];
}

pub fn inferTypeOf(hir: *const Hir, id: NodeId) InferTypePayload {
    std.debug.assert(hir.kindOf(id) == .infer_type);
    return hir.infer_type_payloads.items[hir.payloads.items[id]];
}

pub fn literalTypeOf(hir: *const Hir, id: NodeId) LiteralTypePayload {
    std.debug.assert(hir.kindOf(id) == .type_literal);
    return hir.literal_type_payloads.items[hir.payloads.items[id]];
}

pub fn typeParameterOf(hir: *const Hir, id: NodeId) TypeParameterPayload {
    std.debug.assert(hir.kindOf(id) == .type_parameter);
    return hir.type_parameter_payloads.items[hir.payloads.items[id]];
}

pub fn mappedTypeOf(hir: *const Hir, id: NodeId) MappedTypePayload {
    std.debug.assert(hir.kindOf(id) == .mapped_type);
    return hir.mapped_type_payloads.items[hir.payloads.items[id]];
}

pub fn jsxElementOf(hir: *const Hir, id: NodeId) JsxElementPayload {
    const k = hir.kindOf(id);
    std.debug.assert(k == .jsx_element or k == .jsx_self_closing);
    return hir.jsx_element_payloads.items[hir.payloads.items[id]];
}

pub fn jsxAttrs(hir: *const Hir, id: NodeId) []const NodeId {
    const p = jsxElementOf(hir, id);
    return hir.childSlice(p.attrs_start, p.attrs_len);
}

pub fn jsxChildren(hir: *const Hir, id: NodeId) []const NodeId {
    const p = jsxElementOf(hir, id);
    return hir.childSlice(p.children_start, p.children_len);
}

pub fn jsxAttributeOf(hir: *const Hir, id: NodeId) JsxAttributePayload {
    std.debug.assert(hir.kindOf(id) == .jsx_attribute);
    return hir.jsx_attribute_payloads.items[hir.payloads.items[id]];
}

pub fn jsxSpreadAttributeOf(hir: *const Hir, id: NodeId) JsxSpreadAttributePayload {
    std.debug.assert(hir.kindOf(id) == .jsx_spread_attribute);
    return hir.jsx_spread_attribute_payloads.items[hir.payloads.items[id]];
}

pub fn spreadOf(hir: *const Hir, id: NodeId) JsxSpreadAttributePayload {
    std.debug.assert(hir.kindOf(id) == .spread);
    return hir.jsx_spread_attribute_payloads.items[hir.payloads.items[id]];
}

pub fn jsxExpressionOf(hir: *const Hir, id: NodeId) JsxExpressionPayload {
    std.debug.assert(hir.kindOf(id) == .jsx_expression);
    return hir.jsx_expression_payloads.items[hir.payloads.items[id]];
}

pub fn jsxFragmentOf(hir: *const Hir, id: NodeId) JsxFragmentPayload {
    std.debug.assert(hir.kindOf(id) == .jsx_fragment);
    return hir.jsx_fragment_payloads.items[hir.payloads.items[id]];
}

pub fn jsxFragmentChildren(hir: *const Hir, id: NodeId) []const NodeId {
    const p = jsxFragmentOf(hir, id);
    return hir.childSlice(p.children_start, p.children_len);
}

pub fn decoratorOf(hir: *const Hir, id: NodeId) DecoratorPayload {
    std.debug.assert(hir.kindOf(id) == .decorator);
    return hir.decorator_payloads.items[hir.payloads.items[id]];
}

pub fn interfaceMemberOf(hir: *const Hir, id: NodeId) InterfaceMemberPayload {
    std.debug.assert(hir.kindOf(id) == .interface_member);
    return hir.interface_member_payloads.items[hir.payloads.items[id]];
}

/// Returns the recorded computed key-expression for an interface
/// member declared with `[expr]:` form, or `none_node_id` otherwise.
/// The mapping lives in `ColdData.interface_member_key_expr` (set by
/// the parser via `setInterfaceMemberKeyExpr`).
pub fn interfaceMemberKeyExpr(hir: *const Hir, id: NodeId) NodeId {
    if (hir.kindOf(id) != .interface_member) return none_node_id;
    return hir.cold.interface_member_key_expr.get(id) orelse none_node_id;
}

pub fn objectTypeOf(hir: *const Hir, id: NodeId) ObjectTypePayload {
    std.debug.assert(hir.kindOf(id) == .object_type);
    return hir.object_type_payloads.items[hir.payloads.items[id]];
}

pub fn objectTypeMembers(hir: *const Hir, id: NodeId) []const NodeId {
    const p = objectTypeOf(hir, id);
    return hir.childSlice(p.members_start, p.members_len);
}

// ============================================================================
// Footprint metrics — load-bearing for the §0 perf claim
// ============================================================================

/// Bytes of hot-column storage per node, summed across the always-present
/// columns. This is the number that has to stay ≤ ~24 (per §5.2 plan
/// claim) for the cache-locality argument to hold.
///
/// Hot columns are: `kinds` + `spans` + `parents` + `types` + `payloads`.
pub const hot_bytes_per_node: usize =
    @sizeOf(NodeKind) +
    @sizeOf(Span) +
    @sizeOf(NodeId) +
    @sizeOf(TypeId) +
    @sizeOf(u32);

comptime {
    // Plan §5.2: average hot-path footprint ~24 bytes/node. We pin the
    // upper bound at 24 here as a compile-time gate so refactors that
    // accidentally fatten the hot columns fail to build.
    if (hot_bytes_per_node > 24) {
        @compileError("HIR hot-column footprint exceeds the 24 B/node budget set by TS_PARITY_PLAN §5.2");
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Hir: footprint is within the §5.2 budget" {
    const t = std.testing;
    // hot_bytes_per_node is asserted at compile time; this just makes
    // the value appear in test reports and double-checks runtime
    // accounting.
    try t.expect(hot_bytes_per_node <= 24);
    try t.expectEqual(@as(usize, 1 + 8 + 4 + 4 + 4), hot_bytes_per_node);
}

test "Hir: init reserves index 0 in every column" {
    const t = std.testing;
    var hir = try Hir.init(t.allocator);
    defer hir.deinit();

    try t.expectEqual(@as(u32, 1), hir.nodeCount());
    try t.expectEqual(NodeKind.none, hir.kindOf(none_node_id));
    try t.expectEqual(reserved_type_ids.none, hir.typeOf(none_node_id));
    try t.expectEqual(none_node_id, hir.parentOf(none_node_id));
}

test "Hir: build a small program and read it back" {
    const t = std.testing;
    var interner = try string_interner.Interner.init(t.allocator);
    defer interner.deinit();
    var hir = try Hir.init(t.allocator);
    defer hir.deinit();
    var b = Builder.init(&hir);
    defer b.deinit();

    // Program: `x + 1`
    const x_name = try interner.intern("x");
    const x = try b.addIdentifier(.{ .start = 0, .end = 1 }, x_name);
    const one = try b.addLiteralNumber(.{ .start = 4, .end = 5 }, 1);
    const add = try b.addBinaryOp(.{ .start = 0, .end = 5 }, .add, x, one);

    try t.expectEqual(NodeKind.binary_op, hir.kindOf(add));
    const p = binopOf(&hir, add);
    try t.expectEqual(BinOp.add, p.op);
    try t.expectEqual(x, p.lhs);
    try t.expectEqual(one, p.rhs);
    try t.expectEqual(add, hir.parentOf(x));
    try t.expectEqual(add, hir.parentOf(one));
    try t.expectEqual(@as(f64, 1.0), literalNumberOf(&hir, one));

    const ident = identifierOf(&hir, x);
    try t.expectEqualStrings("x", interner.get(ident.name));
}

test "Hir: literal kinds round-trip" {
    const t = std.testing;
    var interner = try string_interner.Interner.init(t.allocator);
    defer interner.deinit();
    var hir = try Hir.init(t.allocator);
    defer hir.deinit();
    var b = Builder.init(&hir);
    defer b.deinit();

    const s_id = try interner.intern("hello");
    const big_id = try interner.intern("99999999999999999999");

    const s = try b.addLiteralString(.{ .start = 0, .end = 7 }, s_id);
    const n = try b.addLiteralNumber(.{ .start = 8, .end = 15 }, 3.14159);
    const big = try b.addLiteralBigInt(.{ .start = 16, .end = 36 }, big_id);
    const tt = try b.addLiteralBool(.{ .start = 37, .end = 41 }, true);
    const ff = try b.addLiteralBool(.{ .start = 42, .end = 47 }, false);
    const nullv = try b.addLiteralNull(.{ .start = 48, .end = 52 });
    const undef = try b.addLiteralUndefined(.{ .start = 53, .end = 62 });
    const regex = try b.addLiteralRegex(.{ .start = 63, .end = 66 });

    try t.expectEqualStrings("hello", interner.get(literalStringOf(&hir, s).value));
    try t.expectApproxEqRel(@as(f64, 3.14159), literalNumberOf(&hir, n), 1e-12);
    try t.expectEqualStrings("99999999999999999999", interner.get(literalBigIntOf(&hir, big).digits));
    try t.expectEqual(true, literalBoolOf(&hir, tt));
    try t.expectEqual(false, literalBoolOf(&hir, ff));
    try t.expectEqual(NodeKind.literal_null, hir.kindOf(nullv));
    try t.expectEqual(NodeKind.literal_undefined, hir.kindOf(undef));
    try t.expectEqual(NodeKind.literal_regex, hir.kindOf(regex));
}

test "Hir: call expression with multiple args" {
    const t = std.testing;
    var interner = try string_interner.Interner.init(t.allocator);
    defer interner.deinit();
    var hir = try Hir.init(t.allocator);
    defer hir.deinit();
    var b = Builder.init(&hir);
    defer b.deinit();

    const f_id = try interner.intern("f");
    const f = try b.addIdentifier(.{ .start = 0, .end = 1 }, f_id);
    const a1 = try b.addLiteralNumber(.{ .start = 2, .end = 3 }, 1);
    const a2 = try b.addLiteralNumber(.{ .start = 4, .end = 5 }, 2);
    const a3 = try b.addLiteralNumber(.{ .start = 6, .end = 7 }, 3);
    const args = [_]NodeId{ a1, a2, a3 };
    const call = try b.addCall(.{ .start = 0, .end = 8 }, f, &args);

    try t.expectEqual(NodeKind.call_expr, hir.kindOf(call));
    const slice = callArgs(&hir, call);
    try t.expectEqual(@as(usize, 3), slice.len);
    try t.expectEqual(a1, slice[0]);
    try t.expectEqual(a2, slice[1]);
    try t.expectEqual(a3, slice[2]);
    try t.expectEqual(call, hir.parentOf(f));
    try t.expectEqual(call, hir.parentOf(a1));
    try t.expectEqual(call, hir.parentOf(a2));
    try t.expectEqual(call, hir.parentOf(a3));
}

test "Hir: block statement holds many stmts" {
    const t = std.testing;
    var interner = try string_interner.Interner.init(t.allocator);
    defer interner.deinit();
    var hir = try Hir.init(t.allocator);
    defer hir.deinit();
    var b = Builder.init(&hir);
    defer b.deinit();

    const a_id = try interner.intern("a");
    const b_id = try interner.intern("b");
    _ = a_id;
    _ = b_id;

    var stmts: [10]NodeId = undefined;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        stmts[i] = try b.addLiteralNumber(.{ .start = 0, .end = 0 }, @floatFromInt(i));
    }
    const blk = try b.addBlock(.{ .start = 0, .end = 100 }, &stmts);
    const slice = blockStmts(&hir, blk);
    try t.expectEqual(@as(usize, 10), slice.len);
    i = 0;
    while (i < 10) : (i += 1) {
        try t.expectEqual(stmts[i], slice[i]);
        try t.expectEqual(blk, hir.parentOf(stmts[i]));
    }
}

test "Hir: NodeKind category predicates" {
    const t = std.testing;
    try t.expect(NodeKind.identifier.isExpression());
    try t.expect(NodeKind.binary_op.isExpression());
    try t.expect(NodeKind.jsx_self_closing.isExpression());
    try t.expect(NodeKind.jsx_element.isExpression());
    try t.expect(NodeKind.jsx_fragment.isExpression());
    try t.expect(NodeKind.jsx_expression.isExpression());
    try t.expect(!NodeKind.identifier.isStatement());
    try t.expect(NodeKind.if_stmt.isStatement());
    try t.expect(NodeKind.fn_decl.isDeclaration());
    try t.expect(NodeKind.union_type.isType());
    try t.expect(!NodeKind.union_type.isExpression());
}

test "Hir: types column writable post-bind" {
    const t = std.testing;
    var hir = try Hir.init(t.allocator);
    defer hir.deinit();
    var b = Builder.init(&hir);
    defer b.deinit();

    const n = try b.addLiteralBool(.{ .start = 0, .end = 4 }, true);
    try t.expectEqual(reserved_type_ids.none, hir.typeOf(n));
    hir.setType(n, reserved_type_ids.true_lit);
    try t.expectEqual(reserved_type_ids.true_lit, hir.typeOf(n));
}

test "Hir: nested expressions correctly track parents" {
    const t = std.testing;
    var interner = try string_interner.Interner.init(t.allocator);
    defer interner.deinit();
    var hir = try Hir.init(t.allocator);
    defer hir.deinit();
    var b = Builder.init(&hir);
    defer b.deinit();

    // Build (a + b) * (c + d)
    const names = [_][]const u8{ "a", "b", "c", "d" };
    var ids: [4]NodeId = undefined;
    for (names, 0..) |n, idx| {
        const sid = try interner.intern(n);
        ids[idx] = try b.addIdentifier(.{ .start = 0, .end = 1 }, sid);
    }
    const ab = try b.addBinaryOp(.{ .start = 0, .end = 5 }, .add, ids[0], ids[1]);
    const cd = try b.addBinaryOp(.{ .start = 8, .end = 13 }, .add, ids[2], ids[3]);
    const all = try b.addBinaryOp(.{ .start = 0, .end = 13 }, .mul, ab, cd);

    try t.expectEqual(ab, hir.parentOf(ids[0]));
    try t.expectEqual(ab, hir.parentOf(ids[1]));
    try t.expectEqual(cd, hir.parentOf(ids[2]));
    try t.expectEqual(cd, hir.parentOf(ids[3]));
    try t.expectEqual(all, hir.parentOf(ab));
    try t.expectEqual(all, hir.parentOf(cd));
    try t.expectEqual(none_node_id, hir.parentOf(all));
}

test "Hir: pushParent / popParent override defaults" {
    const t = std.testing;
    var interner = try string_interner.Interner.init(t.allocator);
    defer interner.deinit();
    var hir = try Hir.init(t.allocator);
    defer hir.deinit();
    var b = Builder.init(&hir);
    defer b.deinit();

    const id = try interner.intern("x");

    // Reserve a parent NodeId by allocating a placeholder identifier.
    const placeholder = try b.addIdentifier(.{ .start = 0, .end = 1 }, id);
    try b.pushParent(placeholder);
    const child = try b.addIdentifier(.{ .start = 2, .end = 3 }, id);
    b.popParent();
    const sibling = try b.addIdentifier(.{ .start = 4, .end = 5 }, id);

    try t.expectEqual(placeholder, hir.parentOf(child));
    try t.expectEqual(none_node_id, hir.parentOf(sibling));
}

test "Hir: cold side-table for JSDoc and debug names" {
    const t = std.testing;
    var interner = try string_interner.Interner.init(t.allocator);
    defer interner.deinit();
    var hir = try Hir.init(t.allocator);
    defer hir.deinit();
    var b = Builder.init(&hir);
    defer b.deinit();

    const id_x = try interner.intern("x");
    const node = try b.addIdentifier(.{ .start = 0, .end = 1 }, id_x);

    const jsdoc = try interner.intern("@param {number} x");
    const dbg = try interner.intern("locals.x");
    try hir.cold.jsdoc.put(t.allocator, node, jsdoc);
    try hir.cold.debug_names.put(t.allocator, node, dbg);

    try t.expectEqualStrings("@param {number} x", interner.get(hir.cold.jsdoc.get(node).?));
    try t.expectEqualStrings("locals.x", interner.get(hir.cold.debug_names.get(node).?));
}

test "Hir: reserved primitive TypeIds are stable" {
    const t = std.testing;
    try t.expectEqual(@as(TypeId, 0), reserved_type_ids.none);
    try t.expectEqual(@as(TypeId, 1), reserved_type_ids.any);
    try t.expectEqual(@as(TypeId, 14), reserved_type_ids.false_lit);
    try t.expectEqual(@as(TypeId, 16), reserved_type_ids.first_dynamic);
    try t.expect(reserved_type_ids.first_dynamic > reserved_type_ids.false_lit);
}
