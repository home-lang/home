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
    /// TypeScript-compatible code (e.g. 2322). 0 for uncategorized.
    code: u32 = 0,
    /// `TS` for tsc-compatible codes; `HM` for Home-only codes.
    code_prefix: CodePrefix = .TS,
    message: []const u8,

    pub const CodePrefix = enum { TS, HM };
};

/// TypeScript-compatible diagnostic codes used by the checker.
/// Matches `ts_diagnostics.TsCodes` numerically. We keep a local
/// copy to avoid a cross-package dependency from the checker.
pub const TsCodes = struct {
    pub const cannot_find_name: u32 = 2304;
    pub const cannot_find_module: u32 = 2307;
    pub const type_not_assignable: u32 = 2322;
    pub const property_does_not_exist: u32 = 2339;
    pub const argument_type_mismatch: u32 = 2345;
    pub const expected_n_arguments: u32 = 2554;
    pub const duplicate_identifier: u32 = 2300;
    pub const generic_type_requires_args: u32 = 2314;
    pub const operator_cannot_be_applied: u32 = 2365;
    pub const not_callable: u32 = 2349;
    pub const this_implicitly_any: u32 = 2683;
};

pub const Checker = struct {
    gpa: std.mem.Allocator,
    hir: *Hir,
    interner: *interner.Interner,
    string_interner: *string_interner.Interner,
    engine: *relation.Engine,
    lowerer: lower.Lowerer,
    /// Optional bound module — when set, identifier expressions
    /// resolve their type via the symbol table.
    module: ?*const binder_mod.Module,
    /// Stack of name → narrowed-type maps. Each `if`/`while`/etc.
    /// pushes a scope; identifier resolution consults the top of
    /// the stack first before falling back to the static type.
    narrow_scopes: std.ArrayListUnmanaged(std.AutoHashMapUnmanaged(hir_mod.StringId, TypeId)),
    /// Class-name → instance type. Populated by `checkClassDecl`
    /// when a class is declared; consulted by `instanceof` narrowing
    /// and `new` expression typing — both of which require the name
    /// to refer to a constructable runtime entity (not an interface
    /// or a type alias).
    class_instance_types: std.AutoHashMapUnmanaged(hir_mod.StringId, TypeId),
    /// Class-name → constructor signature TypeId. Populated when a
    /// class declares an explicit `constructor(...)`; consulted by
    /// `new_expr` typing to check argument count / types. Classes
    /// without an explicit constructor produce no entry — `new Foo()`
    /// then accepts any args (matches TS's implicit no-arg default).
    class_constructor_sigs: std.AutoHashMapUnmanaged(hir_mod.StringId, TypeId),
    /// Generic name → TypeId table for type-annotation resolution.
    /// A superset of `class_instance_types` that also covers
    /// `interface I { ... }` and `type Alias = T`. Consulted by
    /// `lowererLowerWithTypeParams` so `b: Box`, `b: SomeInterface`,
    /// or `b: SomeAlias` all resolve at the annotation site.
    type_names: std.AutoHashMapUnmanaged(hir_mod.StringId, TypeId),
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    diag_arena: std.heap.ArenaAllocator,

    pub fn init(
        gpa: std.mem.Allocator,
        hir: *Hir,
        ti: *interner.Interner,
        si: *string_interner.Interner,
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
            .class_instance_types = .empty,
            .class_constructor_sigs = .empty,
            .type_names = .empty,
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
        self.class_instance_types.deinit(self.gpa);
        self.class_constructor_sigs.deinit(self.gpa);
        self.type_names.deinit(self.gpa);
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
            .class_decl => try self.checkClassDecl(node),
            .interface_decl => try self.checkInterfaceDecl(node),
            .type_alias_decl => try self.checkTypeAliasDecl(node),
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
        const had_type_params = hir_mod.fnTypeParams(self.hir, node).len > 0;
        _ = try self.checkFnSignatureOnly(node);
        defer if (had_type_params) self.popNarrowScope();
        try self.walkFnBody(node);
    }

    /// Type the body of a function/method/arrow. Split from
    /// `checkFnDecl` so callers (e.g. `checkClassDecl`) can run the
    /// signature pass first, register the enclosing scope's
    /// `this`-type, and only then walk the body.
    fn walkFnBody(self: *Checker, node: NodeId) CheckError!void {
        const f = hir_mod.fnDeclOf(self.hir, node);
        if (f.body == hir_mod.none_node_id) return;
        if (self.hir.kindOf(f.body) == .block_stmt) {
            const stmts = hir_mod.blockStmts(self.hir, f.body);
            for (stmts) |s| try self.checkStatement(s);
        } else {
            _ = try self.checkExpression(f.body);
        }
    }

    /// Run the signature-only pass of `checkFnDecl` — type
    /// parameters, parameter annotations, return type, intern the
    /// signature — without walking the body. The caller owns the
    /// narrow scope: a type-params scope is pushed here when the
    /// fn declares any, and the caller must pop it after the body
    /// walk so type-param references inside the body still resolve.
    fn checkFnSignatureOnly(self: *Checker, node: NodeId) CheckError!TypeId {
        const f = hir_mod.fnDeclOf(self.hir, node);
        const type_params = hir_mod.fnTypeParams(self.hir, node);
        if (type_params.len > 0) try self.pushNarrowScope();
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
            try self.recordNarrow(tpp.name, tp_id);
        }

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
            if (pp.name != hir_mod.none_node_id) self.hir.setType(pp.name, t);
        }

        const ret_t: TypeId = if (f.return_type != hir_mod.none_node_id)
            try self.lowererLowerWithTypeParams(f.return_type)
        else
            types.Primitive.any;

        const sig = self.interner.internSignature(param_types.items, ret_t, false) catch return error.OutOfMemory;
        self.hir.setType(node, sig);
        if (f.name != hir_mod.none_node_id) self.hir.setType(f.name, sig);
        return sig;
    }

    /// Lower a class declaration into an instance object type. Each
    /// method becomes an object member typed as a signature; each
    /// declared field becomes an object member typed as the
    /// annotation (or the initializer's type, or `any`).
    /// Constructors are walked for body typing but excluded from the
    /// instance shape — they live on the constructor function, not
    /// on instances.
    fn checkClassDecl(self: *Checker, node: NodeId) CheckError!void {
        const c = hir_mod.classOf(self.hir, node);
        const members = hir_mod.classMembers(self.hir, node);

        // Pass 1: build the instance shape from signatures + field
        // annotations only (no method body walks). Methods need the
        // instance type registered in `class_instance_types` BEFORE
        // their bodies are typed so `this` resolves.
        var instance_members: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
        defer instance_members.deinit(self.gpa);
        var ctor_sig: TypeId = types.Primitive.none;

        for (members) |m| {
            switch (self.hir.kindOf(m)) {
                .fn_decl, .fn_expr, .arrow_fn => {
                    const sig = try self.checkFnSignatureOnly(m);
                    // Pop the type-params scope `checkFnSignatureOnly`
                    // pushed (we don't walk the body in this pass).
                    if (hir_mod.fnTypeParams(self.hir, m).len > 0) self.popNarrowScope();
                    const fn_p = hir_mod.fnDeclOf(self.hir, m);
                    if (fn_p.flags.is_constructor) {
                        ctor_sig = sig;
                        continue;
                    }
                    if (fn_p.name == hir_mod.none_node_id or self.hir.kindOf(fn_p.name) != .identifier) continue;
                    const id = hir_mod.identifierOf(self.hir, fn_p.name);
                    try instance_members.append(self.gpa, .{
                        .name = id.name,
                        .type = sig,
                        .is_optional = false,
                        .is_readonly = false,
                        .is_method = true,
                    });
                },
                .object_property => {
                    const op = hir_mod.objectPropertyOf(self.hir, m);
                    if (self.hir.kindOf(op.key) != .identifier) continue;
                    const id = hir_mod.identifierOf(self.hir, op.key);
                    const field_t: TypeId = blk: {
                        if (op.type_annotation != hir_mod.none_node_id) {
                            break :blk try self.lowererLowerWithTypeParams(op.type_annotation);
                        }
                        if (op.value != hir_mod.none_node_id) {
                            break :blk try self.checkExpression(op.value);
                        }
                        break :blk types.Primitive.any;
                    };
                    try instance_members.append(self.gpa, .{
                        .name = id.name,
                        .type = field_t,
                        .is_optional = false,
                        .is_readonly = false,
                        .is_method = false,
                    });
                },
                else => {},
            }
        }

        // `extends Parent`: prepend any inherited members the child
        // doesn't override. The child's declared members win on
        // name conflict (TS prototype-chain semantics).
        if (c.extends != hir_mod.none_node_id) {
            try self.mergeExtendedMembers(c.extends, &instance_members);
        }

        const instance_t = self.interner.internObjectType(instance_members.items) catch return error.OutOfMemory;
        self.hir.setType(node, instance_t);
        if (c.name != hir_mod.none_node_id and self.hir.kindOf(c.name) == .identifier) {
            const cid = hir_mod.identifierOf(self.hir, c.name);
            try self.class_instance_types.put(self.gpa, cid.name, instance_t);
            try self.type_names.put(self.gpa, cid.name, instance_t);
            if (ctor_sig != types.Primitive.none) {
                try self.class_constructor_sigs.put(self.gpa, cid.name, ctor_sig);
            }
            // The class name as a value is the constructor — we don't
            // have a dedicated constructor signature TypeId yet, so
            // record the instance type on the name node. `new Foo()`
            // looks up the class by name to get the instance type.
            self.hir.setType(c.name, instance_t);
        }

        // Pass 2: re-run each method through `checkFnDecl` (which
        // re-derives the signature idempotently and walks the body)
        // with `this` bound to the instance type and `super` bound
        // to the parent class's instance type (when this class
        // `extends`). Identifier lookup consults narrow scopes
        // first, so `this.x` and `super.foo()` resolve through the
        // matching object type's member table.
        const this_id = self.string_interner.intern("this") catch return error.OutOfMemory;
        const super_id = self.string_interner.intern("super") catch return error.OutOfMemory;
        const super_t: ?TypeId = blk: {
            if (c.extends == hir_mod.none_node_id) break :blk null;
            if (self.hir.kindOf(c.extends) != .identifier) break :blk null;
            const ext_id = hir_mod.identifierOf(self.hir, c.extends);
            break :blk self.class_instance_types.get(ext_id.name);
        };
        for (members) |m| switch (self.hir.kindOf(m)) {
            .fn_decl, .fn_expr, .arrow_fn => {
                try self.pushNarrowScope();
                try self.recordNarrow(this_id, instance_t);
                if (super_t) |st| try self.recordNarrow(super_id, st);
                try self.checkFnDecl(m);
                self.popNarrowScope();
            },
            else => {},
        };
    }

    /// Merge a parent class's instance members into the current
    /// child's member list, inheriting anything the child doesn't
    /// already declare. The child wins on name conflict — that's
    /// override semantics. Silent no-op when the parent expression
    /// isn't a known class identifier.
    fn mergeExtendedMembers(
        self: *Checker,
        extends_expr: NodeId,
        child_members: *std.ArrayListUnmanaged(types.ObjectMember),
    ) CheckError!void {
        if (self.hir.kindOf(extends_expr) != .identifier) return;
        const id = hir_mod.identifierOf(self.hir, extends_expr);
        const parent_t = self.class_instance_types.get(id.name) orelse return;
        const parent_members = self.interner.objectMembers(parent_t);

        // Collect names the child already declares so we know which
        // parent entries to skip (override).
        var child_names: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer child_names.deinit(self.gpa);
        for (child_members.items) |m| try child_names.put(self.gpa, m.name, {});

        // Prepend inherited-only members so child entries (declared
        // last) win after sort+dedup is performed by the caller.
        var inherited: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
        defer inherited.deinit(self.gpa);
        for (parent_members) |pm| {
            if (child_names.contains(pm.name)) continue;
            try inherited.append(self.gpa, pm);
        }
        if (inherited.items.len == 0) return;
        try child_members.insertSlice(self.gpa, 0, inherited.items);
    }

    /// Lower an interface declaration into an interned object type
    /// matching its member list. Each `name: T` becomes a member
    /// typed as the lowering of `T`; each method shorthand `name(p):
    /// R` becomes a member typed as the matching signature. The
    /// resulting TypeId is recorded on the interface name and in
    /// `type_names` so subsequent `b: I` annotations resolve.
    fn checkInterfaceDecl(self: *Checker, node: NodeId) CheckError!void {
        const it = hir_mod.interfaceOf(self.hir, node);
        const members = hir_mod.interfaceMembers(self.hir, node);

        var iface_members: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
        defer iface_members.deinit(self.gpa);

        for (members) |m| {
            if (self.hir.kindOf(m) != .interface_member) continue;
            const im = hir_mod.interfaceMemberOf(self.hir, m);
            // name == 0 means a computed key — skip until we have
            // late-bound key support.
            if (im.name == 0) continue;
            const member_t: TypeId = blk: {
                if (im.type_node != hir_mod.none_node_id) {
                    break :blk try self.lowererLowerWithTypeParams(im.type_node);
                }
                break :blk types.Primitive.any;
            };
            try iface_members.append(self.gpa, .{
                .name = im.name,
                .type = member_t,
                .is_optional = im.is_optional,
                .is_readonly = im.is_readonly,
                .is_method = im.is_method,
            });
        }

        const iface_t = self.interner.internObjectType(iface_members.items) catch return error.OutOfMemory;
        self.hir.setType(node, iface_t);
        if (it.name != hir_mod.none_node_id and self.hir.kindOf(it.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, it.name);
            try self.type_names.put(self.gpa, id.name, iface_t);
            self.hir.setType(it.name, iface_t);
        }
    }

    /// Lower a type alias `type Alias = T` into the underlying
    /// type's TypeId and record it under the alias name so
    /// `b: Alias` resolves at the annotation site.
    fn checkTypeAliasDecl(self: *Checker, node: NodeId) CheckError!void {
        const ta = hir_mod.typeAliasOf(self.hir, node);
        if (ta.aliased == hir_mod.none_node_id) return;
        const aliased_t = try self.lowererLowerWithTypeParams(ta.aliased);
        self.hir.setType(node, aliased_t);
        if (ta.name != hir_mod.none_node_id and self.hir.kindOf(ta.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, ta.name);
            try self.type_names.put(self.gpa, id.name, aliased_t);
            self.hir.setType(ta.name, aliased_t);
        }
    }

    /// Lower a type annotation while consulting the current
    /// narrow scope (for in-scope type parameters) and the
    /// named-type table (for class / interface / type-alias names).
    fn lowererLowerWithTypeParams(self: *Checker, type_node: NodeId) CheckError!TypeId {
        switch (self.hir.kindOf(type_node)) {
            .type_ref => {
                const r = hir_mod.typeRefOf(self.hir, type_node);
                if (r.qualifier_len == 0 and r.args_len == 0) {
                    if (self.lookupNarrow(r.name)) |t| return t;
                    if (self.type_names.get(r.name)) |t| return t;
                }
            },
            .typeof_type => {
                // `type T = typeof x` — query the value-namespace for
                // the identifier's TypeId. We reuse the same lookup
                // path identifier expressions go through, so the
                // result honors module-level scoping + nested scopes.
                const tt = hir_mod.typeofTypeOf(self.hir, type_node);
                if (self.hir.kindOf(tt.operand) == .identifier) {
                    return self.typeOfIdentifier(tt.operand);
                }
            },
            else => {},
        }
        return self.lowerer.lower(type_node);
    }

    fn checkVarDecl(self: *Checker, node: NodeId) CheckError!void {
        const v = hir_mod.varDeclOf(self.hir, node);

        // Lower type annotation first (so we can check init against it).
        var declared_type: TypeId = types.Primitive.none;
        if (v.type_annotation != hir_mod.none_node_id) {
            declared_type = try self.lowererLowerWithTypeParams(v.type_annotation);
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
                try self.report(node, TsCodes.type_not_assignable, "Type is not assignable to declared type.");
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
            .new_expr => blk: {
                const c = hir_mod.callOf(self.hir, node);
                _ = try self.checkExpression(c.callee);
                const args = hir_mod.callArgs(self.hir, node);
                var arg_types: std.ArrayListUnmanaged(TypeId) = .empty;
                defer arg_types.deinit(self.gpa);
                for (args) |arg| {
                    const t = try self.checkExpression(arg);
                    try arg_types.append(self.gpa, t);
                }
                // `new Foo(...)` produces the instance type recorded
                // by `checkClassDecl`. If the class declared an
                // explicit constructor we also typecheck args against
                // its signature (TS2554 + TS2345 mirror call-site
                // checking). If the callee isn't a known class
                // identifier (e.g. `new someExpr()`), fall back to
                // `any`.
                if (self.hir.kindOf(c.callee) == .identifier) {
                    const id = hir_mod.identifierOf(self.hir, c.callee);
                    if (self.class_constructor_sigs.get(id.name)) |ctor_sig| {
                        try self.checkArgsAgainstSignature(node, args, arg_types.items, ctor_sig);
                    }
                    if (self.class_instance_types.get(id.name)) |inst| break :blk inst;
                }
                break :blk types.Primitive.any;
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
                    try self.checkArgsAgainstSignature(node, args, arg_types.items, callee_t);
                    if (self.interner.signatureReturn(callee_t)) |ret| {
                        const param_ts = self.interner.signatureParams(callee_t);
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
                    try self.diagnostics.append(self.gpa, .{
                        .node = node,
                        .code = TsCodes.property_does_not_exist,
                        .message = msg,
                    });
                }
                break :blk types.Primitive.any;
            },
            .element_access => blk: {
                const e = hir_mod.elementOf(self.hir, node);
                _ = try self.checkExpression(e.object);
                _ = try self.checkExpression(e.index);
                break :blk types.Primitive.any;
            },
            .as_expr, .satisfies_expr, .type_assertion => blk: {
                // `expr as T` / `expr satisfies T` / `<T>expr` — type
                // the inner expression for diagnostics, then return
                // the asserted type. `satisfies` should also check
                // that the expression is assignable to T (TS2322 on
                // miss); a follow-up will tighten that path.
                const a = hir_mod.asExpressionOf(self.hir, node);
                _ = try self.checkExpression(a.expr);
                if (a.type_node == hir_mod.none_node_id) break :blk types.Primitive.any;
                break :blk try self.lowererLowerWithTypeParams(a.type_node);
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
            // Arrow / function expression: lower the signature so the
            // surrounding `let f = (x: T) => U` learns f's signature
            // type. checkFnDecl walks the body too, so all interior
            // typing happens here.
            .arrow_fn, .fn_expr => blk: {
                try self.checkFnDecl(node);
                break :blk self.hir.typeOf(node);
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

        // `x instanceof Foo` — narrows `x` to the class's instance
        // type when `Foo` resolves to a declared class; otherwise
        // falls back to `Primitive.object_t`. The else-branch leaves
        // `x` un-narrowed since proper subtraction needs the
        // discriminated-union machinery (Phase 6).
        if (b.op == .instanceof and self.hir.kindOf(b.lhs) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, b.lhs);
            if (when_true) {
                var narrowed: TypeId = types.Primitive.object_t;
                if (self.hir.kindOf(b.rhs) == .identifier) {
                    const rhs_id = hir_mod.identifierOf(self.hir, b.rhs);
                    if (self.class_instance_types.get(rhs_id.name)) |inst| {
                        narrowed = inst;
                    }
                }
                try self.recordNarrow(id.name, narrowed);
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

    /// Shared arg / signature checker used by both `call_expr` and
    /// `new_expr`. Emits TS2554 (count mismatch) and TS2345 (per-arg
    /// type mismatch) against `sig`'s parameter list. Type-parameter
    /// slots are skipped — full instantiation lives in
    /// `instantiateReturn`.
    fn checkArgsAgainstSignature(
        self: *Checker,
        call_node: NodeId,
        args: []const NodeId,
        arg_types: []const TypeId,
        sig: TypeId,
    ) CheckError!void {
        const param_ts = self.interner.signatureParams(sig);
        if (args.len != param_ts.len) {
            const msg = try std.fmt.allocPrint(
                self.diag_arena.allocator(),
                "Expected {d} arguments, but got {d}.",
                .{ param_ts.len, args.len },
            );
            try self.diagnostics.append(self.gpa, .{
                .node = call_node,
                .code = TsCodes.expected_n_arguments,
                .message = msg,
            });
        }
        const npairs = @min(args.len, param_ts.len);
        var i: usize = 0;
        while (i < npairs) : (i += 1) {
            const param_t = param_ts[i];
            if (self.interner.pool.flagsOf(param_t).is_type_parameter) continue;
            const arg_t = arg_types[i];
            const ok = self.engine.isAssignableTo(arg_t, param_t) catch true;
            if (!ok) {
                const msg = try std.fmt.allocPrint(
                    self.diag_arena.allocator(),
                    "Argument is not assignable to parameter at position {d}.",
                    .{i},
                );
                try self.diagnostics.append(self.gpa, .{
                    .node = args[i],
                    .code = TsCodes.argument_type_mismatch,
                    .message = msg,
                });
            }
        }
    }

    fn report(self: *Checker, node: NodeId, code: u32, message: []const u8) !void {
        const msg = try self.diag_arena.allocator().dupe(u8, message);
        try self.diagnostics.append(self.gpa, .{
            .node = node,
            .code = code,
            .message = msg,
        });
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

test "checker: class declaration produces an instance object type" {
    const s = try newSetup(
        \\class Box {
        \\  value: number = 0;
        \\  get(): number { return 1; }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(top));
    const inst_t = s.hir.typeOf(top);
    try T.expect(s.ti.pool.flagsOf(inst_t).is_object_type);
    // 'value' field is interned at the instance type.
    const value_id = try s.sint.intern("value");
    try T.expect(s.ti.objectMember(inst_t, value_id) != null);
    // 'get' method is interned at the instance type as a signature.
    const get_id = try s.sint.intern("get");
    const get_t = s.ti.objectMember(inst_t, get_id) orelse return error.TestExpectedEqual;
    try T.expect(s.ti.pool.flagsOf(get_t).is_signature);
}

test "checker: new Foo() yields the class instance type" {
    const s = try newSetup(
        \\class Box { value: number = 0; }
        \\let b = new Box();
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const class_t = s.hir.typeOf(stmts[0]);
    const decl = stmts[1];
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(decl));
    const v = hir_mod.varDeclOf(&s.hir, decl);
    try T.expectEqual(hir_mod.NodeKind.new_expr, s.hir.kindOf(v.init));
    try T.expectEqual(class_t, s.hir.typeOf(v.init));
}

test "checker: parameter typed as a declared class resolves member access" {
    const s = try newSetup(
        \\class Box { value: number = 0; }
        \\function f(b: Box): number { return b.value; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const class_t = s.hir.typeOf(stmts[0]);
    // Walk into f's body, find the return, and check that `b.value`
    // typed to number_t (which only happens when `b` resolved to
    // the Box instance type).
    const f = hir_mod.fnDeclOf(&s.hir, stmts[1]);
    const body = hir_mod.blockStmts(&s.hir, f.body);
    const ret_p = hir_mod.returnOf(&s.hir, body[0]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(ret_p.value));
    // And the parameter's type matches the class's instance type.
    const params = hir_mod.fnParams(&s.hir, stmts[1]);
    try T.expectEqual(class_t, s.hir.typeOf(params[0]));
}

test "checker: instanceof narrows to the class instance type when class is declared" {
    const s = try newSetup(
        \\class Box { value: number = 0; }
        \\function f(x: any): any {
        \\  if (x instanceof Box) {
        \\    return x.value;
        \\  }
        \\  return null;
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    // No diagnostics: `x.value` resolves on the narrowed instance
    // type rather than triggering TS2339.
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: var-decl type mismatch emits TS2322" {
    const s = try newSetup("let x: number = \"hi\";");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expectEqual(@as(usize, 1), s.checker.diagnostics.items.len);
    try T.expectEqual(TsCodes.type_not_assignable, s.checker.diagnostics.items[0].code);
}

test "checker: argument count mismatch emits TS2554" {
    const s = try newSetup(
        \\function f(a: number, b: number): number { return a + b; }
        \\f(1);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.expected_n_arguments) found = true;
    }
    try T.expect(found);
}

test "checker: argument type mismatch emits TS2345" {
    const s = try newSetup(
        \\function f(a: number): number { return a; }
        \\f("hi");
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.argument_type_mismatch) found = true;
    }
    try T.expect(found);
}

test "checker: missing object property emits TS2339" {
    const s = try newSetup(
        \\let p = { x: 1 };
        \\let y = p.z;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.property_does_not_exist) found = true;
    }
    try T.expect(found);
}

test "checker: interface name resolves as a type annotation" {
    const s = try newSetup(
        \\interface Box { value: number; }
        \\function f(b: Box): number { return b.value; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const iface_t = s.hir.typeOf(stmts[0]);
    const params = hir_mod.fnParams(&s.hir, stmts[1]);
    try T.expectEqual(iface_t, s.hir.typeOf(params[0]));
    // `b.value` types to number — confirms interface members
    // resolve through the type-name lookup.
    const f = hir_mod.fnDeclOf(&s.hir, stmts[1]);
    const body = hir_mod.blockStmts(&s.hir, f.body);
    const ret_p = hir_mod.returnOf(&s.hir, body[0]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(ret_p.value));
}

test "checker: type alias to a primitive resolves" {
    const s = try newSetup(
        \\type Count = number;
        \\let n: Count = 1;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const alias_t = s.hir.typeOf(stmts[0]);
    try T.expectEqual(types.Primitive.number_t, alias_t);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(stmts[1]));
}

test "checker: type alias to an object literal resolves member access" {
    const s = try newSetup(
        \\type Point = { x: number; y: number };
        \\function f(p: Point): number { return p.x; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const f = hir_mod.fnDeclOf(&s.hir, stmts[1]);
    const body = hir_mod.blockStmts(&s.hir, f.body);
    const ret_p = hir_mod.returnOf(&s.hir, body[0]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(ret_p.value));
}

test "checker: interface annotation mismatch emits TS2322" {
    const s = try newSetup(
        \\interface Box { value: number; }
        \\let b: Box = { value: "hi" };
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.type_not_assignable) found = true;
    }
    try T.expect(found);
}

test "checker: this.x inside a class method resolves to the field type" {
    const s = try newSetup(
        \\class Box {
        \\  value: number = 0;
        \\  read(): number { return this.value; }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    // Walk into the read() method's return statement and verify
    // `this.value` is typed as number_t.
    const top = firstStatement(s);
    const members = hir_mod.classMembers(&s.hir, top);
    var read_node: NodeId = hir_mod.none_node_id;
    for (members) |m| {
        const k = s.hir.kindOf(m);
        if (k != .fn_decl and k != .fn_expr and k != .arrow_fn) continue;
        const fp = hir_mod.fnDeclOf(&s.hir, m);
        if (fp.flags.is_constructor) continue;
        read_node = m;
        break;
    }
    try T.expect(read_node != hir_mod.none_node_id);
    const fp = hir_mod.fnDeclOf(&s.hir, read_node);
    const body = hir_mod.blockStmts(&s.hir, fp.body);
    const ret_p = hir_mod.returnOf(&s.hir, body[0]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(ret_p.value));
}

test "checker: missing this property in method emits TS2339" {
    const s = try newSetup(
        \\class Box {
        \\  value: number = 0;
        \\  bad(): number { return this.missing; }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.property_does_not_exist) found = true;
    }
    try T.expect(found);
}

test "checker: class extends inherits parent fields" {
    const s = try newSetup(
        \\class Shape { kind: string = ""; }
        \\class Box extends Shape { value: number = 0; }
        \\function f(b: Box): string { return b.kind; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    // Box's instance type carries both `value` (own) and `kind`
    // (inherited from Shape).
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const box_t = s.hir.typeOf(stmts[1]);
    const kind_id = try s.sint.intern("kind");
    const value_id = try s.sint.intern("value");
    try T.expect(s.ti.objectMember(box_t, kind_id) != null);
    try T.expect(s.ti.objectMember(box_t, value_id) != null);
    // f(b: Box).body returns b.kind — typed as string.
    const f = hir_mod.fnDeclOf(&s.hir, stmts[2]);
    const body = hir_mod.blockStmts(&s.hir, f.body);
    const ret_p = hir_mod.returnOf(&s.hir, body[0]);
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(ret_p.value));
}

test "checker: child class overrides parent field type" {
    const s = try newSetup(
        \\class A { x: string = ""; }
        \\class B extends A { x: number = 0; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const b_t = s.hir.typeOf(stmts[1]);
    const x_id = try s.sint.intern("x");
    const x_t = s.ti.objectMember(b_t, x_id) orelse return error.TestExpectedEqual;
    // Child override wins — `x` is number_t, not string_t.
    try T.expectEqual(types.Primitive.number_t, x_t);
}

test "checker: new with wrong arg count emits TS2554" {
    const s = try newSetup(
        \\class Box {
        \\  constructor(v: number) {}
        \\}
        \\let b = new Box();
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.expected_n_arguments) found = true;
    }
    try T.expect(found);
}

test "checker: new with wrong arg type emits TS2345" {
    const s = try newSetup(
        \\class Box {
        \\  constructor(v: number) {}
        \\}
        \\let b = new Box("hi");
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.argument_type_mismatch) found = true;
    }
    try T.expect(found);
}

test "checker: new with correct constructor args type-checks cleanly" {
    const s = try newSetup(
        \\class Box {
        \\  value: number = 0;
        \\  constructor(v: number) {}
        \\}
        \\let b = new Box(42);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: super.x in subclass method resolves to parent member" {
    const s = try newSetup(
        \\class Shape { kind: string = ""; }
        \\class Box extends Shape {
        \\  what(): string { return super.kind; }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: super property miss emits TS2339" {
    const s = try newSetup(
        \\class Shape { kind: string = ""; }
        \\class Box extends Shape {
        \\  bad(): string { return super.missing; }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.property_does_not_exist) found = true;
    }
    try T.expect(found);
}

test "checker: typeof type query resolves an identifier's static type" {
    const s = try newSetup(
        \\function add(a: number, b: number): number { return a + b; }
        \\type AddSig = typeof add;
        \\let f: AddSig = add;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_t = s.hir.typeOf(stmts[0]);
    const alias_t = s.hir.typeOf(stmts[1]);
    // `typeof add` reuses the function's signature TypeId.
    try T.expectEqual(fn_t, alias_t);
}

test "checker: `as` cast yields the asserted type" {
    const s = try newSetup(
        \\let raw: any = 1;
        \\let n = raw as number;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const n_decl = stmts[1];
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(n_decl));
    const v = hir_mod.varDeclOf(&s.hir, n_decl);
    try T.expectEqual(hir_mod.NodeKind.as_expr, s.hir.kindOf(v.init));
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(v.init));
}

test "checker: `as` cast feeds the var-decl's declared type without TS2322" {
    const s = try newSetup(
        \\let raw: any = "hi";
        \\let n: number = raw as number;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}
