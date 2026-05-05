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
    infer_type,
    template_literal_type,
    tuple_type,
    array_type,
    fn_type,
    constructor_type,

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

    /// Returns true if the kind is in the "expression" category.
    pub fn isExpression(self: NodeKind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(NodeKind.identifier) and
            v <= @intFromEnum(NodeKind.import_call);
    }

    /// Returns true if the kind is in the "type" category.
    pub fn isType(self: NodeKind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(NodeKind.type_ref) and
            v <= @intFromEnum(NodeKind.constructor_type);
    }

    /// Returns true if the kind is in the "statement" category (excludes
    /// declarations, which are conventionally separate).
    pub fn isStatement(self: NodeKind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(NodeKind.block_stmt) and
            v <= @intFromEnum(NodeKind.expression_stmt);
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

    pub fn empty() ColdData {
        return .{
            .jsdoc = .empty,
            .debug_names = .empty,
        };
    }

    pub fn deinit(self: *ColdData, gpa: std.mem.Allocator) void {
        self.jsdoc.deinit(gpa);
        self.debug_names.deinit(gpa);
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
        const args_start: u32 = @intCast(self.hir.child_pool.items.len);
        try self.hir.child_pool.appendSlice(self.hir.gpa, args);
        const args_len: u16 = @intCast(args.len);
        const payload_idx: u32 = @intCast(self.hir.call_payloads.items.len);
        try self.hir.call_payloads.append(self.hir.gpa, .{
            .callee = callee,
            .args_start = args_start,
            .args_len = args_len,
            .type_args_start = 0,
            .type_args_len = 0,
        });
        const id = try self.newNode(.call_expr, span, payload_idx);
        self.hir.setParent(callee, id);
        for (args) |arg| self.hir.setParent(arg, id);
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
    std.debug.assert(hir.kindOf(id) == .call_expr);
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

pub fn blockStmts(hir: *const Hir, id: NodeId) []const NodeId {
    const p = blockOf(hir, id);
    return hir.childSlice(p.stmts_start, p.stmts_len);
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

    try t.expectEqualStrings("hello", interner.get(literalStringOf(&hir, s).value));
    try t.expectApproxEqRel(@as(f64, 3.14159), literalNumberOf(&hir, n), 1e-12);
    try t.expectEqualStrings("99999999999999999999", interner.get(literalBigIntOf(&hir, big).digits));
    try t.expectEqual(true, literalBoolOf(&hir, tt));
    try t.expectEqual(false, literalBoolOf(&hir, ff));
    try t.expectEqual(NodeKind.literal_null, hir.kindOf(nullv));
    try t.expectEqual(NodeKind.literal_undefined, hir.kindOf(undef));
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
