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
            .diagnostics = .empty,
            .diag_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Checker) void {
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
            .return_stmt => {
                const r = hir_mod.returnOf(self.hir, node);
                if (r.value != hir_mod.none_node_id) {
                    _ = try self.checkExpression(r.value);
                }
            },
            .if_stmt => {
                const i = hir_mod.ifOf(self.hir, node);
                _ = try self.checkExpression(i.cond);
                try self.checkStatement(i.then_branch);
                if (i.else_branch != hir_mod.none_node_id) try self.checkStatement(i.else_branch);
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
        if (declared_type != types.Primitive.none and v.init != hir_mod.none_node_id) {
            const ok = self.engine.isAssignableTo(init_type, declared_type) catch return error.OutOfMemory;
            if (!ok) {
                try self.report(node, "Type is not assignable to declared type.");
            }
        } else if (declared_type == types.Primitive.none) {
            // Inferred from init.
            self.hir.setType(node, init_type);
        }
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
            .identifier => types.Primitive.any, // resolved via binder in follow-up
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
                _ = try self.checkExpression(c.callee);
                for (hir_mod.callArgs(self.hir, node)) |arg| {
                    _ = try self.checkExpression(arg);
                }
                // Without signature lowering we can't infer the
                // return type — treat as `any` for now.
                break :blk types.Primitive.any;
            },
            .member_access => blk: {
                const m = hir_mod.memberOf(self.hir, node);
                _ = try self.checkExpression(m.object);
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
                for (elements) |el| {
                    if (el != hir_mod.none_node_id) _ = try self.checkExpression(el);
                }
                break :blk types.Primitive.any;
            },
            .object_literal => blk: {
                const props = hir_mod.objectLiteralProps(self.hir, node);
                for (props) |p| {
                    if (self.hir.kindOf(p) == .object_property) {
                        const op = hir_mod.objectPropertyOf(self.hir, p);
                        if (op.value != hir_mod.none_node_id) _ = try self.checkExpression(op.value);
                    }
                }
                break :blk types.Primitive.any;
            },
            else => types.Primitive.any,
        };
        self.hir.setType(node, t);
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

    fn report(self: *Checker, node: NodeId, message: []const u8) !void {
        const msg = try self.diag_arena.allocator().dupe(u8, message);
        try self.diagnostics.append(self.gpa, .{ .node = node, .message = msg });
    }
};

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
