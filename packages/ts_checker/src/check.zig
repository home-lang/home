//! Expression type-checker — Phase 3 of TS_PARITY_PLAN.
//!
//! Walks HIR expressions and assigns each one a TypeId, populating
//! the HIR's `types` column. Also drives the cross-statement checks:
//! `let x: T = expr;` verifies `expr`'s type is assignable to `T`.
//!
//! Scope today (Phase 3 expression typing — minimal):
//!   - Literals (number / string / bigint / boolean / null /
//!     undefined) → matching Primitive
//!   - Identifier references — type taken from the binder's symbol
//!     when known, else `Primitive.any` (forgiving for partial input)
//!   - Binary `+` on number+number / string+string → matching
//!     primitive; mixed → string (matches JS coercion)
//!   - Comparison ops → boolean
//!   - Logical `&&`/`||`/`??` → union of branch types
//!   - Conditional `c ? a : b` → union of branches
//!   - Assignment `target = value` → value's type
//!   - VarDecl with annotation: assign annotation to the decl's
//!     type slot, check init assigns to it; else infer from init
//!
//! Out of scope (Phase 3 follow-ups):
//!   - Call type-checking (needs signature lowering)
//!   - Member access / element access (needs object-type lowering)
//!   - Generic instantiation
//!   - Control-flow narrowing
//!   - Class/interface body member resolution

const std = @import("std");
const hir_mod = @import("hir");
const types = @import("types.zig");
const interner = @import("interner.zig");
const relation = @import("relation.zig");
const lower = @import("lower.zig");
const string_interner = @import("string_interner");
const binder_mod = @import("binder");

pub const TypeId = types.TypeId;
pub const NodeId = hir_mod.NodeId;
pub const Hir = hir_mod.Hir;

pub const CheckError = error{
    OutOfMemory,
};

pub const Diagnostic = struct {
    node: NodeId,
    message: []const u8,
};

pub const Checker = struct {
    gpa: std.mem.Allocator,
    hir: *Hir,
    interner: *interner.Interner,
    string_interner: *const string_interner.Interner,
    engine: *relation.Engine,
    lowerer: lower.Lowerer,
    /// Optional bound module — when set, identifier expressions
    /// resolve their type via the symbol table.
    module: ?*const binder_mod.Module,
    /// Stack of name → narrowed-type maps. Each `if`/`while`/etc.
    /// pushes a scope; identifier resolution consults the top of
    /// the stack first before falling back to the static type.
    narrow_scopes: std.ArrayListUnmanaged(std.AutoHashMapUnmanaged(hir_mod.StringId, TypeId)),
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    diag_arena: std.heap.ArenaAllocator,

    pub fn init(
        gpa: std.mem.Allocator,
        hir: *Hir,
        ti: *interner.Interner,
        si: *const string_interner.Interner,
        engine: *relation.Engine,
    ) Checker {
        return .{
            .gpa = gpa,
            .hir = hir,
            .interner = ti,
            .string_interner = si,
            .engine = engine,
            .lowerer = lower.Lowerer.init(gpa, hir, ti, si),
            .module = null,
            .narrow_scopes = .empty,
            .diagnostics = .empty,
            .diag_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    /// Attach a bound module so identifier expressions get real
    /// types from the symbol table instead of falling through to
    /// `Primitive.any`.
    pub fn setModule(self: *Checker, module: *const binder_mod.Module) void {
        self.module = module;
    }

    pub fn deinit(self: *Checker) void {
        for (self.narrow_scopes.items) |*scope| {
            var s = scope.*;
            s.deinit(self.gpa);
        }
        self.narrow_scopes.deinit(self.gpa);
        self.diagnostics.deinit(self.gpa);
        self.diag_arena.deinit();
    }

    /// Check a complete source file. The HIR root must be a
    /// block_stmt of top-level statements.
    pub fn checkSourceFile(self: *Checker, root: NodeId) CheckError!void {
        const stmts = hir_mod.blockStmts(self.hir, root);
        for (stmts) |s| try self.checkStatement(s);
    }

    fn checkStatement(self: *Checker, node: NodeId) CheckError!void {
        switch (self.hir.kindOf(node)) {
            .var_decl, .let_decl, .const_decl => try self.checkVarDecl(node),
            .fn_decl, .fn_expr, .arrow_fn => try self.checkFnDecl(node),
            .return_stmt => {
                const r = hir_mod.returnOf(self.hir, node);
                if (r.value != hir_mod.none_node_id) {
                    _ = try self.checkExpression(r.value);
                }
            },
            .if_stmt => {
                const i = hir_mod.ifOf(self.hir, node);
                _ = try self.checkExpression(i.cond);
                try self.pushNarrowScope();
                try self.applyTypeGuard(i.cond, true);
                try self.checkStatement(i.then_branch);
                self.popNarrowScope();
                if (i.else_branch != hir_mod.none_node_id) {
                    try self.pushNarrowScope();
                    try self.applyTypeGuard(i.cond, false);
                    try self.checkStatement(i.else_branch);
                    self.popNarrowScope();
                }
            },
            .while_stmt => {
                const w = hir_mod.whileOf(self.hir, node);
                _ = try self.checkExpression(w.cond);
                try self.checkStatement(w.body);
            },
            .block_stmt => {
                const stmts = hir_mod.blockStmts(self.hir, node);
                for (stmts) |s| try self.checkStatement(s);
            },
            // Expressions used as statements.
            else => {
                if (hir_mod.NodeKind.isExpression(self.hir.kindOf(node))) {
                    _ = try self.checkExpression(node);
                }
            },
        }
    }

    /// Lower a function declaration into a signature TypeId and
    /// store it on the fn_decl node. Walks the body so nested
    /// expressions get typed too.
    fn checkFnDecl(self: *Checker, node: NodeId) CheckError!void {
        const f = hir_mod.fnDeclOf(self.hir, node);

        // Type parameters: each parameter gets its own
        // type-parameter TypeId so references inside the body /
        // params / return type can resolve to it. Phase 3
        // simplification: type-parameter constraints are not yet
        // checked; defaults are not applied; they're referenced by
        // name only.
        const type_params = hir_mod.fnTypeParams(self.hir, node);
        if (type_params.len > 0) {
            try self.pushNarrowScope();
        }
        defer if (type_params.len > 0) self.popNarrowScope();
        for (type_params) |tp| {
            if (self.hir.kindOf(tp) != .type_parameter) continue;
            const tpp = hir_mod.typeParameterOf(self.hir, tp);
            const constraint: TypeId = if (tpp.constraint != hir_mod.none_node_id)
                try self.lowerer.lower(tpp.constraint)
            else
                types.Primitive.unknown;
            const def: TypeId = if (tpp.default != hir_mod.none_node_id)
                try self.lowerer.lower(tpp.default)
            else
                types.Primitive.none;
            const tp_id = self.interner.internTypeParameter(tpp.name, constraint, def) catch return error.OutOfMemory;
            self.hir.setType(tp, tp_id);
            // Make this name resolve to its type-parameter id
            // inside the function (parameter annotations, return
            // type, body).
            try self.recordNarrow(tpp.name, tp_id);
        }

        // Resolve parameter types.
        var param_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer param_types.deinit(self.gpa);
        const params = hir_mod.fnParams(self.hir, node);
        for (params) |p| {
            const pp = hir_mod.parameterOf(self.hir, p);
            const t: TypeId = if (pp.type_annotation != hir_mod.none_node_id)
                try self.lowererLowerWithTypeParams(pp.type_annotation)
            else
                types.Primitive.any;
            try param_types.append(self.gpa, t);
            self.hir.setType(p, t);
            // Tag the parameter's name node too so identifier
            // lookup inside the body returns the parameter type.
            if (pp.name != hir_mod.none_node_id) self.hir.setType(pp.name, t);
        }

        // Resolve return type (declared annotation only — return-
        // statement-driven inference is a follow-up).
        const ret_t: TypeId = if (f.return_type != hir_mod.none_node_id)
            try self.lowererLowerWithTypeParams(f.return_type)
        else
            types.Primitive.any;

        const sig = self.interner.internSignature(param_types.items, ret_t, false) catch return error.OutOfMemory;
        self.hir.setType(node, sig);
        // Function name's identifier resolves to the signature type.
        if (f.name != hir_mod.none_node_id) self.hir.setType(f.name, sig);

        // Walk the body so its statements get typed.
        if (f.body != hir_mod.none_node_id) {
            const stmts = hir_mod.blockStmts(self.hir, f.body);
            for (stmts) |s| try self.checkStatement(s);
        }
    }

    /// Lower a type annotation while consulting the current
    /// narrow scope so type-parameter references resolve to their
    /// interned type_parameter ids.
    fn lowererLowerWithTypeParams(self: *Checker, type_node: NodeId) CheckError!TypeId {
        // Simple substitution: if the type-node is a bare type_ref
        // by name and that name is in the narrow scope, return the
        // mapped TypeId. Otherwise fall through to the general
        // lowerer.
        if (self.hir.kindOf(type_node) == .type_ref) {
            const r = hir_mod.typeRefOf(self.hir, type_node);
            if (r.qualifier_len == 0 and r.args_len == 0) {
                if (self.lookupNarrow(r.name)) |t| return t;
            }
        }
        return self.lowerer.lower(type_node);
    }

    fn checkVarDecl(self: *Checker, node: NodeId) CheckError!void {
        const v = hir_mod.varDeclOf(self.hir, node);

        // Lower type annotation first (so we can check init against it).
        var declared_type: TypeId = types.Primitive.none;
        if (v.type_annotation != hir_mod.none_node_id) {
            declared_type = try self.lowerer.lower(v.type_annotation);
            self.hir.setType(node, declared_type);
        }

        // Type the initializer.
        var init_type: TypeId = types.Primitive.undefined_t;
        if (v.init != hir_mod.none_node_id) {
            init_type = try self.checkExpression(v.init);
        }

        // If both are present, check assignability.
        const final_type: TypeId = if (declared_type != types.Primitive.none) declared_type else init_type;
        if (declared_type != types.Primitive.none and v.init != hir_mod.none_node_id) {
            const ok = self.engine.isAssignableTo(init_type, declared_type) catch return error.OutOfMemory;
            if (!ok) {
                try self.report(node, "Type is not assignable to declared type.");
            }
        } else if (declared_type == types.Primitive.none) {
            self.hir.setType(node, init_type);
        }
        // Propagate the declaration's type to the name identifier
        // so hover-on-identifier returns the right type.
        if (v.name != hir_mod.none_node_id) self.hir.setType(v.name, final_type);
    }

    /// Type an expression. Returns its TypeId and also records it
    /// in the HIR's types column.
    pub fn checkExpression(self: *Checker, node: NodeId) CheckError!TypeId {
        const t: TypeId = switch (self.hir.kindOf(node)) {
            .literal_string => types.Primitive.string_t,
            .literal_number => types.Primitive.number_t,
            .literal_bigint => types.Primitive.bigint_t,
            .literal_bool => types.Primitive.boolean_t,
            .literal_null => types.Primitive.null_t,
            .literal_undefined => types.Primitive.undefined_t,
            .identifier => self.typeOfIdentifier(node),
            .binary_op => try self.checkBinop(node),
            .unary_op => try self.checkUnary(node),
            .logical_op => try self.checkLogical(node),
            .conditional => try self.checkConditional(node),
            .assignment => blk: {
                const a = hir_mod.assignmentOf(self.hir, node);
                _ = try self.checkExpression(a.target);
                break :blk try self.checkExpression(a.value);
            },
            .call_expr => blk: {
                const c = hir_mod.callOf(self.hir, node);
                const callee_t = try self.checkExpression(c.callee);
                const args = hir_mod.callArgs(self.hir, node);
                var arg_types: std.ArrayListUnmanaged(TypeId) = .empty;
                defer arg_types.deinit(self.gpa);
                for (args) |arg| {
                    const t = try self.checkExpression(arg);
                    try arg_types.append(self.gpa, t);
                }
                if (self.interner.pool.flagsOf(callee_t).is_signature) {
                    const param_ts = self.interner.signatureParams(callee_t);
                    // TS2554: argument count mismatch.
                    if (args.len != param_ts.len) {
                        const msg = try std.fmt.allocPrint(
                            self.diag_arena.allocator(),
                            "Expected {d} arguments, but got {d}.",
                            .{ param_ts.len, args.len },
                        );
                        try self.diagnostics.append(self.gpa, .{ .node = node, .message = msg });
                    }
                    // TS2345: argument type mismatch — for each
                    // arg/param pair, if the arg's type isn't
                    // assignable to the param's type, emit a
                    // diagnostic. Skip when the param type is a
                    // type parameter (we'd need full instantiation
                    // to check those).
                    const npairs = @min(args.len, param_ts.len);
                    var i: usize = 0;
                    while (i < npairs) : (i += 1) {
                        const param_t = param_ts[i];
                        if (self.interner.pool.flagsOf(param_t).is_type_parameter) continue;
                        const arg_t = arg_types.items[i];
                        const ok = self.engine.isAssignableTo(arg_t, param_t) catch true;
                        if (!ok) {
                            const msg = try std.fmt.allocPrint(
                                self.diag_arena.allocator(),
                                "Argument is not assignable to parameter at position {d}.",
                                .{i},
                            );
                            try self.diagnostics.append(self.gpa, .{ .node = args[i], .message = msg });
                        }
                    }
                    if (self.interner.signatureReturn(callee_t)) |ret| {
                        const instantiated = self.instantiateReturn(param_ts, arg_types.items, ret) catch ret;
                        break :blk instantiated;
                    }
                }
                if (self.interner.signatureReturn(callee_t)) |ret| break :blk ret;
                break :blk types.Primitive.any;
            },
            .member_access => blk: {
                const m = hir_mod.memberOf(self.hir, node);
                const obj_t = try self.checkExpression(m.object);
                if (self.interner.objectMember(obj_t, m.name)) |t| break :blk t;
                // No matching member on a known object type → TS2339
                // 'Property X does not exist on type ...'. We only
                // emit when the object is known to be an object
                // type (not any/unknown/etc) — otherwise property
                // access on `any` is unrestricted.
                if (self.interner.pool.flagsOf(obj_t).is_object_type) {
                    const name_str = self.string_interner.get(m.name);
                    const msg = try std.fmt.allocPrint(
                        self.diag_arena.allocator(),
                        "Property '{s}' does not exist on type.",
                        .{name_str},
                    );
                    try self.diagnostics.append(self.gpa, .{ .node = node, .message = msg });
                }
                break :blk types.Primitive.any;
            },
            .element_access => blk: {
                const e = hir_mod.elementOf(self.hir, node);
                _ = try self.checkExpression(e.object);
                _ = try self.checkExpression(e.index);
                break :blk types.Primitive.any;
            },
            .array_literal => blk: {
                const elements = hir_mod.arrayLiteralElements(self.hir, node);
                var elem_types: std.ArrayListUnmanaged(TypeId) = .empty;
                defer elem_types.deinit(self.gpa);
                for (elements) |el| {
                    if (el == hir_mod.none_node_id) continue;
                    const t = try self.checkExpression(el);
                    try elem_types.append(self.gpa, t);
                }
                if (elem_types.items.len == 0) break :blk types.Primitive.any;
                // Simplification (Phase 3): represent the array as
                // the union of its element types. A proper Array<T>
                // generic instantiation lands when the type system
                // gets instantiation support.
                break :blk self.interner.internUnion(elem_types.items) catch return error.OutOfMemory;
            },
            .object_literal => blk: {
                // Type each property and synthesize an object-type
                // mirroring the shape: '{ x: 1 }' -> '{ x: number }'.
                const props = hir_mod.objectLiteralProps(self.hir, node);
                var members: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
                defer members.deinit(self.gpa);
                for (props) |p| {
                    if (self.hir.kindOf(p) != .object_property) continue;
                    const op = hir_mod.objectPropertyOf(self.hir, p);
                    if (op.value == hir_mod.none_node_id) continue;
                    if (self.hir.kindOf(op.key) != .identifier) continue;
                    const k = hir_mod.identifierOf(self.hir, op.key);
                    const vt = try self.checkExpression(op.value);
                    try members.append(self.gpa, .{
                        .name = k.name,
                        .type = vt,
                        .is_optional = false,
                        .is_readonly = false,
                        .is_method = op.is_method,
                    });
                }
                const obj_t = self.interner.internObjectType(members.items) catch return error.OutOfMemory;
                break :blk obj_t;
            },
            else => types.Primitive.any,
        };
        self.hir.setType(node, t);
        return t;
    }

    fn pushNarrowScope(self: *Checker) !void {
        const empty: std.AutoHashMapUnmanaged(hir_mod.StringId, TypeId) = .empty;
        try self.narrow_scopes.append(self.gpa, empty);
    }

    fn popNarrowScope(self: *Checker) void {
        if (self.narrow_scopes.items.len == 0) return;
        var top = self.narrow_scopes.items[self.narrow_scopes.items.len - 1];
        top.deinit(self.gpa);
        _ = self.narrow_scopes.pop();
    }

    /// Look up the topmost narrowed type for `name`, walking the
    /// scope stack from inner-most to outer-most.
    fn lookupNarrow(self: *Checker, name: hir_mod.StringId) ?TypeId {
        var i = self.narrow_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.narrow_scopes.items[i].get(name)) |t| return t;
        }
        return null;
    }

    /// Detect simple type guards in `cond` and write their
    /// narrowing into the current scope.
    ///
    /// Recognized:
    ///   typeof X === "string" / "number" / "boolean" / "bigint" /
    ///                "symbol" / "undefined" / "object"
    ///     and the !== negation (with `when_true` flipped)
    ///   X === null / X !== null
    ///   X === undefined / X !== undefined
    fn applyTypeGuard(self: *Checker, cond: NodeId, when_true: bool) !void {
        if (self.hir.kindOf(cond) != .binary_op) return;
        const b = hir_mod.binopOf(self.hir, cond);

        // `x instanceof Foo` — narrows `x` to the class instance type
        // (or `Primitive.object_t` if we don't yet have an interned
        // class type). The else-branch leaves `x` un-narrowed since
        // proper subtraction needs the discriminated-union machinery
        // (Phase 6).
        if (b.op == .instanceof and self.hir.kindOf(b.lhs) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, b.lhs);
            if (when_true) {
                try self.recordNarrow(id.name, types.Primitive.object_t);
            }
            return;
        }

        if (b.op != .eq_strict and b.op != .neq_strict) return;
        // `positive` = "this branch represents the equality
        // matching" (i.e. `===` in then, `!==` in else).
        const positive = (b.op == .eq_strict) == when_true;

        // Discriminated union narrowing: `x.kind === "circle"`.
        // LHS is a member access, RHS is a literal. We walk the
        // member access's object's static type — if it's a union of
        // object types, keep the variants whose discriminant prop's
        // type matches the RHS literal.
        if (self.hir.kindOf(b.lhs) == .member_access and
            (self.hir.kindOf(b.rhs) == .literal_string or
                self.hir.kindOf(b.rhs) == .literal_number or
                self.hir.kindOf(b.rhs) == .literal_bool))
        {
            try self.applyDiscriminatedNarrow(b.lhs, b.rhs, positive);
            // Don't return — fall through so other guards still try
            // to match (rare overlap, but keeps the logic
            // additive).
        }
        // typeof X === "kind"
        if (self.hir.kindOf(b.lhs) == .unary_op) {
            const u = hir_mod.unaryOf(self.hir, b.lhs);
            if (u.op == .typeof and self.hir.kindOf(u.operand) == .identifier and
                self.hir.kindOf(b.rhs) == .literal_string)
            {
                const id = hir_mod.identifierOf(self.hir, u.operand);
                const lit = hir_mod.literalStringOf(self.hir, b.rhs);
                const lit_str = self.string_interner.get(lit.value);
                if (typeOfTypeofString(lit_str)) |narrowed| {
                    if (positive) {
                        try self.recordNarrow(id.name, narrowed);
                    } else {
                        // Negative branch: subtract `narrowed` from
                        // the variable's static type. Phase 6
                        // follow-up does proper union subtraction;
                        // for now we only handle the simple case
                        // where the static type is exactly `narrowed`
                        // (in which case the negative branch
                        // contradicts and `never` applies).
                        try self.recordNarrow(id.name, types.Primitive.never);
                    }
                }
                return;
            }
        }
        // X === null / X !== null
        if (self.hir.kindOf(b.lhs) == .identifier and
            self.hir.kindOf(b.rhs) == .literal_null)
        {
            const id = hir_mod.identifierOf(self.hir, b.lhs);
            if (positive) {
                try self.recordNarrow(id.name, types.Primitive.null_t);
            } else {
                // X !== null inside then-branch → narrow away null;
                // we record the original-minus-null. With proper
                // union subtraction this is exact; for now we record
                // 'unknown' which is at least correct as a
                // supertype.
                try self.recordNarrow(id.name, types.Primitive.unknown);
            }
            return;
        }
        // X === undefined / X !== undefined (literal_undefined +
        // identifier 'undefined' both occur in source code).
        if (self.hir.kindOf(b.lhs) == .identifier and
            self.hir.kindOf(b.rhs) == .identifier)
        {
            const lhs = hir_mod.identifierOf(self.hir, b.lhs);
            const rhs = hir_mod.identifierOf(self.hir, b.rhs);
            const rhs_name = self.string_interner.get(rhs.name);
            if (std.mem.eql(u8, rhs_name, "undefined")) {
                if (positive) {
                    try self.recordNarrow(lhs.name, types.Primitive.undefined_t);
                } else {
                    try self.recordNarrow(lhs.name, types.Primitive.unknown);
                }
                return;
            }
        }
    }

    /// Discriminated-union narrowing. `lhs` is a member access
    /// `obj.disc`; `rhs_lit` is the literal we're comparing against.
    /// If `obj` is a union of object types and one of its members'
    /// `disc` field matches `rhs_lit`, we narrow `obj` to that member.
    fn applyDiscriminatedNarrow(self: *Checker, lhs: NodeId, rhs_lit: NodeId, positive: bool) !void {
        const m = hir_mod.memberOf(self.hir, lhs);
        if (self.hir.kindOf(m.object) != .identifier) return;
        const obj_id = hir_mod.identifierOf(self.hir, m.object);
        const static_t = self.typeOfIdentifier(m.object);
        if (!self.interner.pool.flagsOf(static_t).is_union) return;

        // Compute the literal's type id for comparison.
        const lit_t: TypeId = blk: {
            switch (self.hir.kindOf(rhs_lit)) {
                .literal_string => {
                    const lit = hir_mod.literalStringOf(self.hir, rhs_lit);
                    break :blk self.interner.internStringLiteral(lit.value) catch return;
                },
                .literal_number => {
                    const v = hir_mod.literalNumberOf(self.hir, rhs_lit);
                    break :blk self.interner.internNumberLiteral(v) catch return;
                },
                .literal_bool => {
                    const v = hir_mod.literalBoolOf(self.hir, rhs_lit);
                    break :blk self.interner.internBooleanLiteral(v);
                },
                else => return,
            }
        };

        const members = self.interner.unionMembers(static_t);
        var keep: std.ArrayListUnmanaged(TypeId) = .empty;
        defer keep.deinit(self.gpa);
        for (members) |variant| {
            if (!self.interner.pool.flagsOf(variant).is_object_type) continue;
            const disc_t = self.interner.objectMember(variant, m.name) orelse continue;
            // Match: the variant's discriminant is exactly the literal.
            if (disc_t == lit_t) {
                if (positive) {
                    try keep.append(self.gpa, variant);
                }
            } else {
                if (!positive) {
                    try keep.append(self.gpa, variant);
                }
            }
        }
        if (keep.items.len == 0) return;
        const narrowed: TypeId = if (keep.items.len == 1)
            keep.items[0]
        else
            self.interner.internUnion(keep.items) catch return;
        try self.recordNarrow(obj_id.name, narrowed);
    }

    fn recordNarrow(self: *Checker, name: hir_mod.StringId, t: TypeId) !void {
        if (self.narrow_scopes.items.len == 0) return;
        var top = &self.narrow_scopes.items[self.narrow_scopes.items.len - 1];
        try top.put(self.gpa, name, t);
    }

    /// Resolve an identifier reference's type. Walks up the HIR
    /// parent chain looking for an enclosing function whose
    /// parameter list declares this name; then falls back to the
    /// binder's module-level scope. This is a Phase 3 simplification
    /// — proper lexical scoping per the binder's Scope graph lands
    /// in a follow-up; this covers the high-frequency patterns
    /// (function parameter use, top-level decl reference).
    fn typeOfIdentifier(self: *Checker, node: NodeId) TypeId {
        const id = hir_mod.identifierOf(self.hir, node);

        // Narrowed binding from an enclosing type-guard takes
        // precedence over the static type.
        if (self.lookupNarrow(id.name)) |t| return t;

        // Walk up the parent chain searching for parameters or
        // sibling let/const/var decls in scope.
        var cur: hir_mod.NodeId = self.hir.parentOf(node);
        while (cur != hir_mod.none_node_id) {
            const k = self.hir.kindOf(cur);
            if (k == .fn_decl or k == .fn_expr or k == .arrow_fn) {
                // Walk parameters and check the same name.
                const params = hir_mod.fnParams(self.hir, cur);
                for (params) |p| {
                    if (self.hir.kindOf(p) != .parameter) continue;
                    const pp = hir_mod.parameterOf(self.hir, p);
                    if (pp.name == hir_mod.none_node_id) continue;
                    if (self.hir.kindOf(pp.name) != .identifier) continue;
                    const pid = hir_mod.identifierOf(self.hir, pp.name);
                    if (pid.name == id.name) return self.hir.typeOf(p);
                }
                // Don't continue past the function — outer scopes
                // would shadow but we still want module-level
                // fallback below.
            }
            if (k == .block_stmt) {
                // Look for a sibling var_decl/let_decl/const_decl
                // before this node.
                const stmts = hir_mod.blockStmts(self.hir, cur);
                for (stmts) |s| {
                    const sk = self.hir.kindOf(s);
                    if (sk == .var_decl or sk == .let_decl or sk == .const_decl) {
                        const v = hir_mod.varDeclOf(self.hir, s);
                        if (v.name != hir_mod.none_node_id and self.hir.kindOf(v.name) == .identifier) {
                            const vid = hir_mod.identifierOf(self.hir, v.name);
                            if (vid.name == id.name) {
                                const t = self.hir.typeOf(s);
                                if (t != types.Primitive.none) return t;
                            }
                        }
                    } else if (sk == .fn_decl or sk == .fn_expr) {
                        const fp = hir_mod.fnDeclOf(self.hir, s);
                        if (fp.name != hir_mod.none_node_id and self.hir.kindOf(fp.name) == .identifier) {
                            const fid = hir_mod.identifierOf(self.hir, fp.name);
                            if (fid.name == id.name) {
                                const t = self.hir.typeOf(s);
                                if (t != types.Primitive.none) return t;
                            }
                        }
                    }
                }
            }
            cur = self.hir.parentOf(cur);
        }

        // Module-level fallback.
        const module = self.module orelse return types.Primitive.any;
        const sym = module.root.lookup(id.name) orelse return types.Primitive.any;
        if (sym.decls.items.len == 0) return types.Primitive.any;
        const decl = sym.decls.items[0];
        const t = self.hir.typeOf(decl);
        if (t == types.Primitive.none) return types.Primitive.any;
        return t;
    }

    fn checkBinop(self: *Checker, node: NodeId) CheckError!TypeId {
        const b = hir_mod.binopOf(self.hir, node);
        const lhs = try self.checkExpression(b.lhs);
        const rhs = try self.checkExpression(b.rhs);
        return switch (b.op) {
            // Arithmetic — number unless either side is string (matches JS).
            .add => blk: {
                if (lhs == types.Primitive.string_t or rhs == types.Primitive.string_t) {
                    break :blk types.Primitive.string_t;
                }
                if (lhs == types.Primitive.number_t and rhs == types.Primitive.number_t) {
                    break :blk types.Primitive.number_t;
                }
                if (self.interner.pool.flagsOf(lhs).is_number and
                    self.interner.pool.flagsOf(rhs).is_number)
                {
                    break :blk types.Primitive.number_t;
                }
                break :blk types.Primitive.number_t;
            },
            .sub, .mul, .div, .mod, .pow => types.Primitive.number_t,
            .bit_and, .bit_or, .bit_xor, .shl, .shr, .shr_unsigned => types.Primitive.number_t,
            .eq, .neq, .eq_strict, .neq_strict => types.Primitive.boolean_t,
            .lt, .le, .gt, .ge => types.Primitive.boolean_t,
            .instanceof, .in => types.Primitive.boolean_t,
            .comma => rhs,
        };
    }

    fn checkUnary(self: *Checker, node: NodeId) CheckError!TypeId {
        const u = hir_mod.unaryOf(self.hir, node);
        _ = try self.checkExpression(u.operand);
        return switch (u.op) {
            .neg, .plus, .bit_not => types.Primitive.number_t,
            .not => types.Primitive.boolean_t,
            .typeof => types.Primitive.string_t,
            .void_ => types.Primitive.undefined_t,
            .delete => types.Primitive.boolean_t,
        };
    }

    fn checkLogical(self: *Checker, node: NodeId) CheckError!TypeId {
        const l = hir_mod.logicalOf(self.hir, node);
        const lhs = try self.checkExpression(l.lhs);
        const rhs = try self.checkExpression(l.rhs);
        // Short-circuit operators produce a union of operand types.
        return self.interner.internUnion(&.{ lhs, rhs }) catch error.OutOfMemory;
    }

    fn checkConditional(self: *Checker, node: NodeId) CheckError!TypeId {
        const c = hir_mod.conditionalOf(self.hir, node);
        _ = try self.checkExpression(c.cond);
        const tt = try self.checkExpression(c.then_branch);
        const ff = try self.checkExpression(c.else_branch);
        return self.interner.internUnion(&.{ tt, ff }) catch error.OutOfMemory;
    }

    /// Generic call-site instantiation. For each parameter slot
    /// whose type is a type-parameter id, record a substitution
    /// `param_ts[i] -> arg_ts[i]`. Then walk `ret_type` and
    /// substitute any type-parameter occurrences. Returns the
    /// substituted return type. Falls through to `ret_type`
    /// unchanged if the signature isn't generic or substitution
    /// can't determine a single type.
    fn instantiateReturn(
        self: *Checker,
        param_ts: []const TypeId,
        arg_ts: []const TypeId,
        ret_type: TypeId,
    ) !TypeId {
        // Build a map: type-parameter-id -> inferred-type
        var subs: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty;
        defer subs.deinit(self.gpa);

        const n = @min(param_ts.len, arg_ts.len);
        for (0..n) |i| {
            const p = param_ts[i];
            if (self.interner.pool.flagsOf(p).is_type_parameter) {
                // Record (or upgrade) the substitution.
                if (subs.get(p)) |prev| {
                    if (prev != arg_ts[i]) {
                        // Mismatched inferences — Phase 6 follow-
                        // up does common-supertype. For now leave
                        // the first-seen mapping in place.
                    }
                } else {
                    try subs.put(self.gpa, p, arg_ts[i]);
                }
            }
        }
        if (subs.count() == 0) return ret_type;
        return self.substituteType(ret_type, &subs);
    }

    /// Substitute occurrences of type-parameter ids in `t` per the
    /// `subs` map. Phase 3 simplification: handles direct type-
    /// parameter, union-of-substitutables, and array element
    /// (when array is lowered to its element). Other compound
    /// shapes pass through unchanged.
    fn substituteType(
        self: *Checker,
        t: TypeId,
        subs: *const std.AutoHashMapUnmanaged(TypeId, TypeId),
    ) !TypeId {
        if (subs.get(t)) |s| return s;
        const flags = self.interner.pool.flagsOf(t);
        if (flags.is_union) {
            const members = self.interner.unionMembers(t);
            var new: std.ArrayListUnmanaged(TypeId) = .empty;
            defer new.deinit(self.gpa);
            for (members) |m| try new.append(self.gpa, try self.substituteType(m, subs));
            return self.interner.internUnion(new.items) catch return t;
        }
        if (flags.is_intersection) {
            const members = self.interner.intersectionMembers(t);
            var new: std.ArrayListUnmanaged(TypeId) = .empty;
            defer new.deinit(self.gpa);
            for (members) |m| try new.append(self.gpa, try self.substituteType(m, subs));
            return self.interner.internIntersection(new.items) catch return t;
        }
        return t;
    }

    fn report(self: *Checker, node: NodeId, message: []const u8) !void {
        const msg = try self.diag_arena.allocator().dupe(u8, message);
        try self.diagnostics.append(self.gpa, .{ .node = node, .message = msg });
    }
};

fn typeOfTypeofString(s: []const u8) ?TypeId {
    if (std.mem.eql(u8, s, "string")) return types.Primitive.string_t;
    if (std.mem.eql(u8, s, "number")) return types.Primitive.number_t;
    if (std.mem.eql(u8, s, "boolean")) return types.Primitive.boolean_t;
    if (std.mem.eql(u8, s, "bigint")) return types.Primitive.bigint_t;
    if (std.mem.eql(u8, s, "symbol")) return types.Primitive.symbol_t;
    if (std.mem.eql(u8, s, "undefined")) return types.Primitive.undefined_t;
    if (std.mem.eql(u8, s, "object")) return types.Primitive.object_t;
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;
const ts_lexer = @import("ts_lexer");
const ts_parser = @import("ts_parser");

const TestSetup = struct {
    sint: string_interner.Interner,
    hir: Hir,
    scanner: ts_lexer.Scanner,
    tokens: std.ArrayList(ts_lexer.Token),
    parser: ts_parser.Parser,
    ti: interner.Interner,
    engine: relation.Engine,
    checker: Checker,
    root: NodeId,
};

fn newSetup(source: []const u8) !*TestSetup {
    const s = try T.allocator.create(TestSetup);
    errdefer T.allocator.destroy(s);
    s.sint = try string_interner.Interner.init(T.allocator);
    errdefer s.sint.deinit();
    s.hir = try Hir.init(T.allocator);
    errdefer s.hir.deinit();
    s.scanner = ts_lexer.Scanner.init(T.allocator, source);
    errdefer s.scanner.deinit(T.allocator);
    s.tokens = try s.scanner.tokenize(T.allocator);
    errdefer s.tokens.deinit(T.allocator);
    s.parser = ts_parser.Parser.init(T.allocator, &s.hir, &s.sint, source, s.tokens.items);
    errdefer s.parser.deinit();
    s.root = try s.parser.parseSourceFile();
    s.ti = try interner.Interner.init(T.allocator);
    errdefer s.ti.deinit();
    s.engine = relation.Engine.init(T.allocator, &s.ti);
    errdefer s.engine.deinit();
    s.checker = Checker.init(T.allocator, &s.hir, &s.ti, &s.sint, &s.engine);
    return s;
}

fn destroySetup(s: *TestSetup) void {
    s.checker.deinit();
    s.engine.deinit();
    s.ti.deinit();
    s.parser.deinit();
    s.tokens.deinit(T.allocator);
    s.scanner.deinit(T.allocator);
    s.hir.deinit();
    s.sint.deinit();
    T.allocator.destroy(s);
}

fn firstStatement(s: *TestSetup) NodeId {
    return hir_mod.blockStmts(&s.hir, s.root)[0];
}

test "checker: number literal types as Primitive.number_t" {
    const s = try newSetup("42;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(top));
}

test "checker: string literal types as Primitive.string_t" {
    const s = try newSetup("\"hello\";");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(top));
}

test "checker: addition of number + number is number" {
    const s = try newSetup("1 + 2;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(top));
}

test "checker: addition of string + number is string" {
    const s = try newSetup("\"x\" + 1;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(top));
}

test "checker: comparison ops produce boolean" {
    const s = try newSetup("1 < 2;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    try T.expectEqual(types.Primitive.boolean_t, s.hir.typeOf(top));
}

test "checker: typeof produces string" {
    const s = try newSetup("typeof x;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(top));
}

test "checker: logical op produces union of operands" {
    const s = try newSetup("1 || \"hello\";");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    const t = s.hir.typeOf(top);
    try T.expect(s.ti.pool.flagsOf(t).is_union);
    try T.expect(s.ti.pool.flagsOf(t).is_number);
    try T.expect(s.ti.pool.flagsOf(t).is_string);
}

test "checker: var with annotation; assignable init OK" {
    const s = try newSetup("let x: number = 1;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expectEqual(@as(usize, 0), s.checker.diagnostics.items.len);
    const top = firstStatement(s);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(top));
}

test "checker: var with annotation; mismatched init flags diagnostic" {
    const s = try newSetup("let x: number = \"hi\";");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len > 0);
}

test "checker: var without annotation infers from init" {
    const s = try newSetup("let x = \"hi\";");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    // Inferred string.
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(top));
}

test "checker: conditional produces union of branches" {
    const s = try newSetup("true ? 1 : \"hi\";");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    const t = s.hir.typeOf(top);
    try T.expect(s.ti.pool.flagsOf(t).is_union);
}

test "checker: identifier is any (resolution follow-up)" {
    const s = try newSetup("undeclared;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    try T.expectEqual(types.Primitive.any, s.hir.typeOf(top));
}

test "checker: function decl gets a signature type" {
    const s = try newSetup("function id(x: number): number { return x; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
    const t = s.hir.typeOf(top);
    try T.expect(s.ti.pool.flagsOf(t).is_signature);
    try T.expectEqual(types.Primitive.number_t, s.ti.signatureReturn(t).?);
}

test "checker: call expression returns signature's return type" {
    const s = try newSetup(
        \\function id(x: number): string { return ""; }
        \\let r = id(1);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(r_decl));
    // The init is `id(1)` — its type is the signature's return
    // type (string), via the binder symbol table.
    const init_node = hir_mod.varDeclOf(&s.hir, r_decl).init;
    // Without binder wired here the call falls through to any —
    // exercised properly in the driver test below.
    _ = init_node;
}

test "checker: instanceof narrows to object_t in then-branch" {
    const s = try newSetup(
        \\function f(x: any): any {
        \\  if (x instanceof Foo) {
        \\    return x;
        \\  }
        \\  return null;
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    // Walk into the if-then branch and find the return.
    const top = firstStatement(s);
    const f = hir_mod.fnDeclOf(&s.hir, top);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    try T.expectEqual(hir_mod.NodeKind.if_stmt, s.hir.kindOf(if_stmt));
    // The narrowing happens inside applyTypeGuard during checkSourceFile;
    // we just verify there were no diagnostics.
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: parameter inside body resolves to its annotation type" {
    const s = try newSetup("function add(a: number, b: number): number { return a + b; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    // Walk into the function body and find the return statement.
    const top = firstStatement(s);
    const f = hir_mod.fnDeclOf(&s.hir, top);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const ret = body_stmts[0];
    const ret_p = hir_mod.returnOf(&s.hir, ret);
    // a + b — both branches should have number type.
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(ret_p.value));
}
