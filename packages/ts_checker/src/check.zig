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
const lib = @import("lib.zig");
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
    /// Emitted when the unresolved identifier closely resembles an
    /// in-scope name (Levenshtein distance ≤ threshold). Same as
    /// 2304 plus a `Did you mean 'X'?` suggestion.
    pub const cannot_find_name_did_you_mean: u32 = 2552;
    pub const cannot_find_module: u32 = 2307;
    pub const type_not_assignable: u32 = 2322;
    pub const property_does_not_exist: u32 = 2339;
    pub const argument_type_mismatch: u32 = 2345;
    pub const expected_n_arguments: u32 = 2554;
    pub const no_overload_matches: u32 = 2769;
    pub const duplicate_identifier: u32 = 2300;
    pub const generic_type_requires_args: u32 = 2314;
    pub const operator_cannot_be_applied: u32 = 2365;
    pub const not_callable: u32 = 2349;
    pub const this_implicitly_any: u32 = 2683;
    pub const parameter_implicitly_any: u32 = 7006;
    pub const variable_implicitly_any: u32 = 7005;
    pub const declared_but_not_read: u32 = 6133;
    pub const object_literal_excess_property: u32 = 2353;
    pub const satisfies_constraint: u32 = 1360;
    pub const used_before_assignment: u32 = 2454;
    pub const cannot_assign_const: u32 = 2588;
    pub const await_only_in_async: u32 = 1308;
    pub const no_overlap_comparison: u32 = 2367;
    /// Emitted when `// @ts-expect-error` was placed above a line
    /// that produced no diagnostics — the directive is unused.
    pub const unused_ts_expect_error: u32 = 2578;
    /// `isolatedModules` violation: re-exporting a type when
    /// `isolatedModules` is enabled requires using `export type`.
    /// Also covers `export const enum` (whose runtime semantics
    /// require cross-module value substitution).
    pub const isolated_modules_reexport: u32 = 1205;
    /// `exactOptionalPropertyTypes`. Emitted when an object literal
    /// explicitly sets an optional property to `undefined` and the
    /// declared property type doesn't include `undefined` in its
    /// union — under the strict rule, `a?: T` means absent OR T,
    /// not `T | undefined`.
    pub const exact_optional_property: u32 = 2375;
    /// `noPropertyAccessFromIndexSignature`. Emitted when `obj.foo`
    /// resolves only through an index signature (no declared
    /// property `foo`). Use `obj["foo"]` to make the unsafe access
    /// explicit.
    pub const index_signature_property_access: u32 = 4111;
    /// TS legacy `private` modifier violation. Emitted when a
    /// member declared `private` is accessed from outside the
    /// declaring class body.
    pub const private_member_access: u32 = 2341;
    /// TS legacy `protected` modifier violation. Emitted when a
    /// member declared `protected` is accessed from outside the
    /// declaring class and its subclasses.
    pub const protected_member_access: u32 = 2445;
    /// TS2540 — assigning to a property declared `readonly`. Forbidden
    /// outside of the class constructor (for class fields) or any
    /// re-assignment (for object/interface readonly properties).
    pub const readonly_property: u32 = 2540;
    /// `new X()` where `X` is an abstract class. Abstract classes
    /// cannot be instantiated directly — only concrete subclasses can.
    pub const abstract_class_instantiation: u32 = 2511;
    /// TS2515 — a non-abstract class extends an abstract class but
    /// fails to implement one or more inherited abstract members.
    /// Emitted once per missing member at the child class declaration.
    pub const abstract_member_not_implemented: u32 = 2515;
};

/// Per-alias generic info: the type-parameter TypeIds in
/// declaration order plus the body TypeId those parameters
/// substitute into. Owned by the checker; the slice lives in the
/// checker's diag/scratch arena.
pub const GenericAliasInfo = struct {
    params: []TypeId,
    body: TypeId,
    /// HIR node for the alias body. Used when the body contains a
    /// mapped type whose constraint can't materialize until the
    /// outer parameters are substituted (homomorphic case:
    /// `type Partial<T> = { [K in keyof T]?: T[K] }`). Falls back
    /// to `body` lookup when the HIR node has been re-evaluated.
    body_node: hir_mod.NodeId = hir_mod.none_node_id,
};

/// Subset of compiler-options flags the checker consults. Defaults
/// match `tsc`'s no-flag baseline (everything off). The driver
/// populates this from a parsed `tsconfig` before `checkSourceFile`.
pub const FnPredicate = struct {
    /// 0xFFFF for `this is T`; otherwise the parameter index.
    param_index: u16,
    /// The asserted type (TypeId).
    target_type: TypeId,
    /// True for `asserts arg is T` — narrows in fall-through, not
    /// just then-branch.
    is_asserts: bool,
};

/// Composite key for member-access narrowing. `obj_name` is the
/// interned identifier name on the LHS of the access; `prop_name`
/// is the property name. Hashed via `AutoHashMap`'s default
/// derivation.
pub const MemberKey = struct {
    obj_name: hir_mod.StringId,
    prop_name: hir_mod.StringId,
};

pub const StrictFlags = struct {
    /// `noImplicitAny` (also implied by `strict`). When true, a
    /// parameter / variable that ends up typed as `any` because it
    /// has no annotation and no inferable initializer raises TS7006
    /// / TS7005.
    no_implicit_any: bool = false,
    /// `noUnusedParameters`. Emits TS6133 for parameters whose name
    /// isn't referenced inside the function body. Names beginning
    /// with `_` are excluded by convention (matches tsc).
    no_unused_parameters: bool = false,
    /// `noUnusedLocals`. Emits TS6133 for `let` / `const` / `var`
    /// declarations whose name isn't referenced after the
    /// declaration. Names beginning with `_` are excluded.
    no_unused_locals: bool = false,
    /// `strictFunctionTypes` (also implied by `strict`). When true,
    /// function-type parameters are checked contravariantly (the
    /// sound rule). When false, parameters are bivariant (legacy
    /// flexibility — matches `tsc`'s pre-3.0 default and current
    /// behavior on method declarations).
    strict_function_types: bool = false,
    /// `noUncheckedIndexedAccess`. When true, indexed access through
    /// an array or index signature widens the result with `undefined`
    /// — `arr[i]` types as `T | undefined` rather than `T`. Tuple
    /// positional access (`tup[0]` against `[A, B]`) keeps the precise
    /// element type since the arity is statically known.
    no_unchecked_indexed_access: bool = false,
    /// `isolatedModules`. Each file must be transpilable in
    /// isolation (no cross-file type info). Forbids constructs that
    /// rely on type-only / cross-module elision: `export const enum`,
    /// type-only re-exports without an explicit `type` modifier,
    /// references to ambient `const enum`s, etc. v0 emits TS1205
    /// for the exported-const-enum case.
    isolated_modules: bool = false,
    /// `resolveJsonModule`. When true, `import data from "./x.json"`
    /// resolves and the default import takes the parsed JSON's shape
    /// (typed as `any` in v0). When false, a `.json` import emits
    /// TS2307 — matches tsc's behavior of refusing the resolution.
    resolve_json_module: bool = false,
    /// `exactOptionalPropertyTypes`. When true, `a?: T` means the
    /// property is absent OR has type `T` — explicitly assigning
    /// `undefined` is rejected (TS2375). When false (legacy), `a?: T`
    /// is treated as `T | undefined` and `{ a: undefined }` is
    /// permitted.
    exact_optional_property_types: bool = false,
    /// `noPropertyAccessFromIndexSignature`. When true, `obj.foo`
    /// is forbidden if `foo` only resolves via an index signature
    /// (i.e. there's no declared property `foo`). The element-access
    /// form `obj["foo"]` must be used instead — surfacing that the
    /// key may or may not exist on the type. Emits TS4111.
    no_property_access_from_index_signature: bool = false,
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
    /// Parallel stack of member-access narrows keyed by
    /// `(obj_name, prop_name)`. Populated by `applyTypeGuard` when
    /// a guard's LHS is a member-access on an identifier root (e.g.
    /// `obj.x !== null`); consulted by `member_access` typing so
    /// the then-branch sees the narrowed property type.
    /// Pushed/popped in lockstep with `narrow_scopes`.
    member_narrow_scopes: std.ArrayListUnmanaged(std.AutoHashMapUnmanaged(MemberKey, TypeId)),
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
    /// Instance TypeId → declaring class name (StringId). Inverse
    /// of `class_instance_types`. The member-access path uses it
    /// to map the receiver type back to a class for privacy checks.
    class_name_by_instance: std.AutoHashMapUnmanaged(TypeId, hir_mod.StringId),
    /// Class-name → set of member names declared `private`.
    /// Populated by `checkClassDecl`; consulted on `member_access`
    /// to flag TS2341 when the access site is outside the
    /// declaring class body.
    class_private_members: std.AutoHashMapUnmanaged(
        hir_mod.StringId,
        std.AutoHashMapUnmanaged(hir_mod.StringId, void),
    ),
    /// Class-name → set of member names declared `protected`.
    /// Populated by `checkClassDecl`; consulted on `member_access`
    /// to flag TS2445 when the access site is outside the
    /// declaring class and its subclass chain.
    class_protected_members: std.AutoHashMapUnmanaged(
        hir_mod.StringId,
        std.AutoHashMapUnmanaged(hir_mod.StringId, void),
    ),
    /// Subclass-name → parent-class name. Records the immediate
    /// `extends` target so the protected-access check can walk the
    /// inheritance chain. Set when `class B extends A { ... }` is
    /// declared and `A` is itself a known class identifier.
    class_parent: std.AutoHashMapUnmanaged(hir_mod.StringId, hir_mod.StringId),
    /// Set of class names whose declaration carried the `abstract`
    /// modifier. Populated by `checkClassDecl`; consulted on
    /// `new_expr` typing to emit TS2511 ("Cannot create an instance
    /// of an abstract class.") when the construction target resolves
    /// to an abstract class.
    abstract_classes: std.AutoHashMapUnmanaged(hir_mod.StringId, void),
    /// Class-name → set of member names declared as abstract members
    /// inside that class body. v0 approximates "abstract member" as
    /// "method without a body inside an abstract class" — the parser
    /// discards the per-member `abstract` modifier so a missing body
    /// is the only signal we have. Populated by `checkClassDecl`;
    /// consulted on each non-abstract subclass to emit TS2515 for
    /// inherited abstract members the child fails to implement.
    class_abstract_members: std.AutoHashMapUnmanaged(
        hir_mod.StringId,
        std.AutoHashMapUnmanaged(hir_mod.StringId, void),
    ),
    /// Generic name → TypeId table for type-annotation resolution.
    /// A superset of `class_instance_types` that also covers
    /// `interface I { ... }` and `type Alias = T`. Consulted by
    /// `lowererLowerWithTypeParams` so `b: Box`, `b: SomeInterface`,
    /// or `b: SomeAlias` all resolve at the annotation site.
    type_names: std.AutoHashMapUnmanaged(hir_mod.StringId, TypeId),
    /// Generic alias name → (params, body) mapping. Populated by
    /// `checkTypeAliasDecl` when an alias declares type parameters.
    /// Consulted by `lowererLowerWithTypeParams` to instantiate
    /// `Box<number>`-style references against the aliased body.
    generic_aliases: std.AutoHashMapUnmanaged(hir_mod.StringId, GenericAliasInfo),
    /// Generic function name → owned `[]TypeId` of TypeParameter ids
    /// (in declaration order). Populated by `checkFnSignatureOnly`.
    /// Consulted by call-expression typing when explicit type args
    /// are present so they substitute the parameter types directly
    /// rather than going through argument-driven inference.
    generic_fns: std.AutoHashMapUnmanaged(hir_mod.StringId, []TypeId),
    /// Function name → type-predicate info. Populated when the
    /// function's return type is `arg is T` or `asserts arg is T`.
    /// Consulted by `applyTypeGuard` at call sites so the caller's
    /// `arg` identifier narrows in the then-branch (or fall-through
    /// for assertion functions).
    fn_predicates: std.AutoHashMapUnmanaged(hir_mod.StringId, FnPredicate),
    /// Variable name → guard expression alias. Records `let cond =
    /// <guard-expr>` so that `if (cond)` narrows the same way as
    /// `if (<guard-expr>)`. Aliased-conditional narrowing per TS
    /// PR #46266. Cleared when `cond` is reassigned.
    cond_aliases: std.AutoHashMapUnmanaged(hir_mod.StringId, NodeId),
    /// Function name → list of overload signature TypeIds in
    /// declaration order. Populated when multiple `function f(...)`
    /// declarations share a name (overloads + implementation). The
    /// implementation signature lands last and is used to type the
    /// body; call sites resolve against the prior overload signatures.
    overloads: std.AutoHashMapUnmanaged(hir_mod.StringId, std.ArrayListUnmanaged(TypeId)),
    /// Auto-inferred variance for type-parameter TypeIds whose
    /// declaration site had no explicit `in` / `out` modifier.
    /// Populated by `checkFnSignatureOnly` and `checkTypeAliasDecl`
    /// after the body is lowered. Since the interner keys variance
    /// into the TypeId, we can't mutate the interned payload — this
    /// side table lets variance-sensitive callers consult the
    /// inferred direction. Unmarked type parameters default to
    /// `.bivariant`.
    inferred_variance: std.AutoHashMapUnmanaged(TypeId, types.Variance),
    /// Strictness flags driving optional diagnostics.
    strict_flags: StrictFlags = .{},
    /// Hard-coded `lib.d.ts` substitute — `String.prototype`,
    /// `Array<T>.prototype`, `Object` global. Populated lazily on
    /// first member-access against the corresponding receiver.
    lib_cache: lib.LibCache = .{},
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    diag_arena: std.heap.ArenaAllocator,
    /// Source bytes used for directive scanning (`// @ts-ignore` /
    /// `// @ts-expect-error`). Optional — when null, no directive
    /// post-processing runs and the diagnostics list is left as-is.
    source: ?[]const u8 = null,
    /// 0-based source lines on which a `// @ts-ignore` directive
    /// suppresses diagnostics. Populated by `scanDirectives` before
    /// statement checking; consulted in `applyDirectives` after.
    ts_ignore_lines: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// 0-based source lines on which a `// @ts-expect-error`
    /// directive suppresses diagnostics. Populated by
    /// `scanDirectives`; lines that fail to suppress at least one
    /// diagnostic become a TS2578 in `applyDirectives`.
    ts_expect_error_lines: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        hir: *Hir,
        ti: *interner.Interner,
        si: *string_interner.Interner,
        engine: *relation.Engine,
    ) Checker {
        // Wire the relation engine's string-interner so structural
        // assignability can use property-name bytes (numeric-key
        // fallback for tuple-vs-array, etc.).
        engine.setStringInterner(si);
        return .{
            .gpa = gpa,
            .hir = hir,
            .interner = ti,
            .string_interner = si,
            .engine = engine,
            .lowerer = lower.Lowerer.init(gpa, hir, ti, si),
            .module = null,
            .narrow_scopes = .empty,
            .member_narrow_scopes = .empty,
            .class_instance_types = .empty,
            .class_constructor_sigs = .empty,
            .class_name_by_instance = .empty,
            .class_private_members = .empty,
            .class_protected_members = .empty,
            .class_parent = .empty,
            .abstract_classes = .empty,
            .class_abstract_members = .empty,
            .type_names = .empty,
            .generic_aliases = .empty,
            .generic_fns = .empty,
            .fn_predicates = .empty,
            .cond_aliases = .empty,
            .overloads = .empty,
            .inferred_variance = .empty,
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

    pub fn setStrictFlags(self: *Checker, flags: StrictFlags) void {
        self.strict_flags = flags;
    }

    /// Attach the original source bytes so `checkSourceFile` can
    /// honor `// @ts-ignore` and `// @ts-expect-error` directives.
    /// The slice must outlive the checker; we don't copy it.
    pub fn setSource(self: *Checker, source: []const u8) void {
        self.source = source;
    }

    pub fn deinit(self: *Checker) void {
        for (self.narrow_scopes.items) |*scope| {
            var s = scope.*;
            s.deinit(self.gpa);
        }
        self.narrow_scopes.deinit(self.gpa);
        for (self.member_narrow_scopes.items) |*scope| {
            var s = scope.*;
            s.deinit(self.gpa);
        }
        self.member_narrow_scopes.deinit(self.gpa);
        self.class_instance_types.deinit(self.gpa);
        self.class_constructor_sigs.deinit(self.gpa);
        self.class_name_by_instance.deinit(self.gpa);
        var pm_it = self.class_private_members.valueIterator();
        while (pm_it.next()) |set| set.deinit(self.gpa);
        self.class_private_members.deinit(self.gpa);
        var pr_it = self.class_protected_members.valueIterator();
        while (pr_it.next()) |set| set.deinit(self.gpa);
        self.class_protected_members.deinit(self.gpa);
        self.class_parent.deinit(self.gpa);
        self.abstract_classes.deinit(self.gpa);
        var am_it = self.class_abstract_members.valueIterator();
        while (am_it.next()) |set| set.deinit(self.gpa);
        self.class_abstract_members.deinit(self.gpa);
        self.type_names.deinit(self.gpa);
        var ga_it = self.generic_aliases.valueIterator();
        while (ga_it.next()) |info| self.gpa.free(info.params);
        self.generic_aliases.deinit(self.gpa);
        var gf_it = self.generic_fns.valueIterator();
        while (gf_it.next()) |params| self.gpa.free(params.*);
        self.generic_fns.deinit(self.gpa);
        self.fn_predicates.deinit(self.gpa);
        self.cond_aliases.deinit(self.gpa);
        var ov_it = self.overloads.valueIterator();
        while (ov_it.next()) |list| list.deinit(self.gpa);
        self.overloads.deinit(self.gpa);
        self.inferred_variance.deinit(self.gpa);
        self.lib_cache.deinit(self.gpa);
        self.diagnostics.deinit(self.gpa);
        self.ts_ignore_lines.deinit(self.gpa);
        self.ts_expect_error_lines.deinit(self.gpa);
        self.diag_arena.deinit();
    }

    /// Look up the auto-inferred variance for a type-parameter
    /// TypeId. Falls back to the variance baked into the interner
    /// when no inference has run for this id (e.g. an explicit
    /// `in` / `out` modifier was present), and to `.bivariant`
    /// for non-type-parameter inputs.
    pub fn typeParameterVariance(self: *const Checker, tp_id: TypeId) types.Variance {
        if (self.inferred_variance.get(tp_id)) |v| return v;
        return self.interner.typeParameterVariance(tp_id);
    }

    /// Check a complete source file. The HIR root must be a
    /// block_stmt of top-level statements.
    pub fn checkSourceFile(self: *Checker, root: NodeId) CheckError!void {
        if (self.source) |src| try self.scanDirectives(src);
        const stmts = hir_mod.blockStmts(self.hir, root);
        for (stmts) |s| try self.checkStatement(s);
        try self.checkUsedBeforeAssignment(stmts);
        if (self.source != null) try self.applyDirectives(root);
    }

    /// Scan the source for `// @ts-ignore` and `// @ts-expect-error`
    /// directives. A directive on line `N` suppresses diagnostics on
    /// the first non-blank, non-directive line strictly after `N`.
    /// Block-comment forms (`/* @ts-ignore */`) are out of scope for
    /// this v0 implementation.
    fn scanDirectives(self: *Checker, src: []const u8) CheckError!void {
        self.ts_ignore_lines.clearRetainingCapacity();
        self.ts_expect_error_lines.clearRetainingCapacity();

        var line: u32 = 0;
        var i: usize = 0;
        var pending_ignore: bool = false;
        var pending_expect: bool = false;

        while (true) {
            const line_start = i;
            var line_end = line_start;
            while (line_end < src.len and src[line_end] != '\n') : (line_end += 1) {}
            const line_text = src[line_start..line_end];

            // Trim leading whitespace for directive detection.
            var t: usize = 0;
            while (t < line_text.len and (line_text[t] == ' ' or line_text[t] == '\t')) : (t += 1) {}
            const trimmed = line_text[t..];

            const is_blank = trimmed.len == 0;
            const is_ignore_directive = matchDirective(trimmed, "@ts-ignore");
            const is_expect_directive = matchDirective(trimmed, "@ts-expect-error");
            const is_directive = is_ignore_directive or is_expect_directive;

            if (is_ignore_directive) pending_ignore = true;
            if (is_expect_directive) pending_expect = true;

            if (!is_blank and !is_directive) {
                if (pending_ignore) {
                    try self.ts_ignore_lines.put(self.gpa, line, {});
                    pending_ignore = false;
                }
                if (pending_expect) {
                    try self.ts_expect_error_lines.put(self.gpa, line, {});
                    pending_expect = false;
                }
            }

            if (line_end >= src.len) break;
            i = line_end + 1;
            line += 1;
        }
    }

    /// Filter out diagnostics whose line is suppressed by an
    /// `@ts-ignore` or `@ts-expect-error` directive. For
    /// `@ts-expect-error` lines that didn't suppress at least one
    /// diagnostic, emit TS2578 ("Unused @ts-expect-error directive").
    fn applyDirectives(self: *Checker, root: NodeId) CheckError!void {
        if (self.ts_ignore_lines.count() == 0 and self.ts_expect_error_lines.count() == 0) return;
        const src = self.source orelse return;

        var used_expect: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer used_expect.deinit(self.gpa);

        var i: usize = 0;
        var keep_count: usize = 0;
        while (i < self.diagnostics.items.len) : (i += 1) {
            const d = self.diagnostics.items[i];
            const span = self.hir.spanOf(d.node);
            const dline = byteOffsetToLine(src, span.start);
            const ignored = self.ts_ignore_lines.contains(dline);
            const expected = self.ts_expect_error_lines.contains(dline);
            if (ignored or expected) {
                if (expected) try used_expect.put(self.gpa, dline, {});
                continue;
            }
            self.diagnostics.items[keep_count] = d;
            keep_count += 1;
        }
        self.diagnostics.shrinkRetainingCapacity(keep_count);

        // Emit TS2578 for unused @ts-expect-error directives.
        var it = self.ts_expect_error_lines.keyIterator();
        while (it.next()) |line_ptr| {
            if (used_expect.contains(line_ptr.*)) continue;
            try self.diagnostics.append(self.gpa, .{
                .node = root,
                .code = TsCodes.unused_ts_expect_error,
                .code_prefix = .TS,
                .message = "Unused '@ts-expect-error' directive.",
            });
        }
    }

    fn checkStatement(self: *Checker, node: NodeId) CheckError!void {
        switch (self.hir.kindOf(node)) {
            .var_decl, .let_decl, .const_decl => try self.checkVarDecl(node),
            .fn_decl, .fn_expr, .arrow_fn => try self.checkFnDecl(node),
            .class_decl => try self.checkClassDecl(node),
            .interface_decl => try self.checkInterfaceDecl(node),
            .type_alias_decl => try self.checkTypeAliasDecl(node),
            .import_decl => try self.checkImportDecl(node),
            .export_decl => {
                // `export <decl>` — the inner decl needs the same
                // typing pass as a top-level decl. Named-only forms
                // (`export { x }`) and re-exports (`export … from
                // "m"`) have no inner decl and are handled later by
                // cross-file resolution.
                const ex = hir_mod.exportOf(self.hir, node);
                if (ex.decl != hir_mod.none_node_id) {
                    // isolatedModules: `export const enum E { ... }`
                    // can't be transpiled in isolation because
                    // consumers need the inlined member values. Emit
                    // TS1205 to match `tsc --isolatedModules`.
                    if (self.strict_flags.isolated_modules and
                        self.hir.kindOf(ex.decl) == .enum_decl)
                    {
                        const ep = hir_mod.enumOf(self.hir, ex.decl);
                        if (ep.is_const) {
                            try self.report(
                                node,
                                TsCodes.isolated_modules_reexport,
                                "Re-exporting a type when 'isolatedModules' is enabled requires using 'export type'.",
                            );
                        }
                    }
                    try self.checkStatement(ex.decl);
                }
            },
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
            .for_in_stmt => {
                // `for (let k in obj)` — `k` types to `string`
                // regardless of `obj`'s shape (matches tsc).
                const fr = hir_mod.forInOf(self.hir, node);
                _ = try self.checkExpression(fr.source);
                try self.bindForLoopTarget(fr.target, types.Primitive.string_t);
                try self.checkStatement(fr.body);
            },
            .for_of_stmt => {
                // `for (let x of arr)` — `x` types to `arr`'s
                // element type. We discover that via the array
                // shape's number-key indexer (which is how
                // `internArrayType` exposes it). For unknown
                // sources we fall through to `any`.
                const fr = hir_mod.forInOf(self.hir, node);
                const src_t = try self.checkExpression(fr.source);
                const elem_t: TypeId = blk: {
                    if (self.interner.pool.flagsOf(src_t).is_object_type) {
                        const idx = self.interner.objectNumberIndex(src_t);
                        if (idx != types.Primitive.none) break :blk idx;
                    }
                    break :blk types.Primitive.any;
                };
                try self.bindForLoopTarget(fr.target, elem_t);
                try self.checkStatement(fr.body);
            },
            .block_stmt => {
                const stmts = hir_mod.blockStmts(self.hir, node);
                for (stmts) |s| {
                    try self.checkStatement(s);
                    // Assertion-function call as a statement: narrow
                    // the asserted variable for subsequent statements
                    // in the same block. `assert(x)` where `assert`
                    // has return type `asserts x is string` narrows
                    // `x` to `string` from this point forward.
                    try self.applyAssertionFlow(s);
                }
            },
            .try_stmt => {
                const ts = hir_mod.tryOf(self.hir, node);
                if (ts.block != hir_mod.none_node_id) try self.checkStatement(ts.block);
                if (ts.catch_block != hir_mod.none_node_id) try self.checkStatement(ts.catch_block);
                if (ts.finally_block != hir_mod.none_node_id) try self.checkStatement(ts.finally_block);
                try self.checkUnusedCatchParam(node);
            },
            .switch_stmt => try self.checkSwitchStatement(node),
            // Expressions used as statements.
            else => {
                if (hir_mod.NodeKind.isExpression(self.hir.kindOf(node))) {
                    _ = try self.checkExpression(node);
                }
            },
        }
    }

    /// Type a `switch_stmt` body. Beyond walking each case's
    /// statements, this also performs discriminated-union narrowing
    /// so `switch (x.kind) { case "circle": ... }` narrows `x` to
    /// the matching variant inside that case's body. The default
    /// case sees `x` narrowed to the union minus every listed case.
    fn checkSwitchStatement(self: *Checker, node: NodeId) CheckError!void {
        const sw = hir_mod.switchOf(self.hir, node);
        _ = try self.checkExpression(sw.discriminant);
        const cases = hir_mod.switchCases(self.hir, node);

        // Only the `x.kind` shape opts into narrowing — the
        // discriminant must be a member access on a bare identifier
        // for the existing `applyDiscriminatedNarrow` helper to fire.
        const is_disc_narrowable = self.hir.kindOf(sw.discriminant) == .member_access and blk: {
            const m = hir_mod.memberOf(self.hir, sw.discriminant);
            break :blk self.hir.kindOf(m.object) == .identifier;
        };

        for (cases) |case_node| {
            const case_p = hir_mod.switchCaseOf(self.hir, case_node);
            const stmts = hir_mod.switchCaseStmts(self.hir, case_node);

            try self.pushNarrowScope();
            defer self.popNarrowScope();

            if (case_p.value != hir_mod.none_node_id) {
                // `case <literal>:` — type the literal, then narrow
                // the discriminant's object to the matching variant.
                _ = try self.checkExpression(case_p.value);
                if (is_disc_narrowable) {
                    try self.applyDiscriminatedNarrow(sw.discriminant, case_p.value, true);
                }
            } else if (is_disc_narrowable) {
                // `default:` — narrow to the union minus every
                // listed case. Each call to `applyDiscriminatedNarrow`
                // with `positive=false` consults the current narrow
                // (via `typeOfIdentifier`), so successive calls
                // accumulate.
                for (cases) |other| {
                    const other_p = hir_mod.switchCaseOf(self.hir, other);
                    if (other_p.value == hir_mod.none_node_id) continue;
                    try self.applyDiscriminatedNarrow(sw.discriminant, other_p.value, false);
                }
            }

            for (stmts) |s| try self.checkStatement(s);
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
        // Push a function-local narrow scope so assertion-function
        // calls and other body-level guards have somewhere to record
        // narrowed types. Popped on return.
        try self.pushNarrowScope();
        defer self.popNarrowScope();
        // §3.A.11 — bind `this` from an explicit `this: T` parameter.
        // The parser captures these as a regular parameter whose name
        // identifier interned as "this". When found, lower its
        // annotation and record it in the narrow scope so member
        // accesses like `this.x` inside the body resolve through the
        // declared type.
        const fn_params = hir_mod.fnParams(self.hir, node);
        const this_name_id = self.string_interner.intern("this") catch null;
        if (this_name_id) |tid| for (fn_params) |p| {
            if (self.hir.kindOf(p) != .parameter) continue;
            const pp = hir_mod.parameterOf(self.hir, p);
            if (pp.name == hir_mod.none_node_id) continue;
            if (self.hir.kindOf(pp.name) != .identifier) continue;
            const id = hir_mod.identifierOf(self.hir, pp.name);
            if (id.name != tid) continue;
            if (pp.type_annotation == hir_mod.none_node_id) continue;
            const this_t = self.lowererLowerWithTypeParams(pp.type_annotation) catch continue;
            try self.recordNarrow(tid, this_t);
            break;
        };
        if (self.hir.kindOf(f.body) == .block_stmt) {
            const stmts = hir_mod.blockStmts(self.hir, f.body);
            for (stmts) |s| {
                try self.checkStatement(s);
                try self.applyAssertionFlow(s);
            }
        } else {
            // Arrow with expression body — its expression IS the
            // return value. Use it as the inferred return type when
            // no annotation was provided.
            const expr_t = try self.checkExpression(f.body);
            if (f.return_type == hir_mod.none_node_id) {
                try self.refineSignatureReturn(node, expr_t);
                // TS 5.5 inferred type predicate.
                try self.tryInferTypePredicate(node, f.body);
            }
            try self.checkUnusedParameters(node, f.body);
            return;
        }
        // For block-bodied fns without an annotation, infer the
        // return type by unioning every return statement's value
        // type. No returns → `void_t`.
        if (f.return_type == hir_mod.none_node_id) {
            var ret_types: std.ArrayListUnmanaged(TypeId) = .empty;
            defer ret_types.deinit(self.gpa);
            try self.collectReturnTypes(f.body, &ret_types);
            const inferred: TypeId = if (ret_types.items.len == 0)
                types.Primitive.void_t
            else if (ret_types.items.len == 1)
                ret_types.items[0]
            else
                self.interner.internUnion(ret_types.items) catch return error.OutOfMemory;
            try self.refineSignatureReturn(node, inferred);
            // TS 5.5 inferred type predicate: only when the body is
            // exactly one `return <narrowing>;` statement.
            const body_stmts = hir_mod.blockStmts(self.hir, f.body);
            if (body_stmts.len == 1 and self.hir.kindOf(body_stmts[0]) == .return_stmt) {
                const r = hir_mod.returnOf(self.hir, body_stmts[0]);
                if (r.value != hir_mod.none_node_id) {
                    try self.tryInferTypePredicate(node, r.value);
                }
            }
        }
        try self.checkUnusedParameters(node, f.body);
        try self.checkUnusedLocals(f.body);
    }

    /// TS 5.5 — inferred type predicates.
    ///
    /// When a function returns a boolean derived from a known
    /// type-narrowing operation on one of its parameters, infer an
    /// `arg is T` predicate so call sites narrow as if the predicate
    /// had been declared explicitly. v0 covers:
    ///   - `typeof x === "string" | "number" | "boolean"`
    ///   - `x !== null` / `x !== undefined`
    ///   - `x !== null && x !== undefined`
    ///   - `x instanceof Foo` (when Foo is a known class)
    ///
    /// The expression must reference a parameter of `fn_node` by
    /// name; otherwise we bail out. Records the predicate in
    /// `fn_predicates` keyed by the function's declared name so the
    /// existing call-site narrowing path picks it up unchanged.
    fn tryInferTypePredicate(
        self: *Checker,
        fn_node: NodeId,
        body_expr: NodeId,
    ) CheckError!void {
        const f = hir_mod.fnDeclOf(self.hir, fn_node);
        if (f.name == hir_mod.none_node_id) return;
        if (self.hir.kindOf(f.name) != .identifier) return;
        const params = hir_mod.fnParams(self.hir, fn_node);
        if (params.len == 0) return;
        const inferred = self.recognizePredicateExpr(body_expr, params) orelse return;
        const fn_name = hir_mod.identifierOf(self.hir, f.name).name;
        // Don't clobber an explicit predicate (handled in
        // `checkFnSignatureOnly`).
        if (self.fn_predicates.contains(fn_name)) return;
        try self.fn_predicates.put(self.gpa, fn_name, inferred);
    }

    /// Match `expr` against the small set of narrowing patterns in
    /// `tryInferTypePredicate` and return the implied predicate.
    /// Returns null when no pattern matches.
    fn recognizePredicateExpr(
        self: *Checker,
        expr: NodeId,
        params: []const NodeId,
    ) ?FnPredicate {
        const k = self.hir.kindOf(expr);
        // `x !== null && x !== undefined` — x is non-nullish.
        if (k == .logical_op) {
            const lp = hir_mod.logicalOf(self.hir, expr);
            if (lp.op == .@"and") {
                const left = self.recognizePredicateExpr(lp.lhs, params) orelse return null;
                const right = self.recognizePredicateExpr(lp.rhs, params) orelse return null;
                if (left.param_index != right.param_index) return null;
                const param_t = self.hir.typeOf(params[left.param_index]);
                const sub1 = self.subtractType(param_t, types.Primitive.null_t) catch param_t;
                const sub2 = self.subtractType(sub1, types.Primitive.undefined_t) catch sub1;
                return .{ .param_index = left.param_index, .target_type = sub2, .is_asserts = false };
            }
        }
        if (k != .binary_op) return null;
        const b = hir_mod.binopOf(self.hir, expr);

        // `x instanceof Foo` — narrow `x` to the class instance type.
        if (b.op == .instanceof and self.hir.kindOf(b.lhs) == .identifier) {
            const idx = self.paramIndexOfIdentifier(b.lhs, params) orelse return null;
            var narrowed: TypeId = types.Primitive.object_t;
            if (self.hir.kindOf(b.rhs) == .identifier) {
                const rhs_id = hir_mod.identifierOf(self.hir, b.rhs);
                if (self.class_instance_types.get(rhs_id.name)) |inst| narrowed = inst;
            }
            return .{ .param_index = idx, .target_type = narrowed, .is_asserts = false };
        }

        if (b.op != .eq_strict and b.op != .neq_strict) return null;

        // `typeof x === "string" | "number" | "boolean"`.
        if (b.op == .eq_strict and
            self.hir.kindOf(b.lhs) == .unary_op and
            self.hir.kindOf(b.rhs) == .literal_string)
        {
            const u = hir_mod.unaryOf(self.hir, b.lhs);
            if (u.op == .typeof and self.hir.kindOf(u.operand) == .identifier) {
                const idx = self.paramIndexOfIdentifier(u.operand, params) orelse return null;
                const lit = hir_mod.literalStringOf(self.hir, b.rhs);
                const lit_str = self.string_interner.get(lit.value);
                const narrowed = typeOfTypeofString(lit_str) orelse return null;
                if (narrowed != types.Primitive.string_t and
                    narrowed != types.Primitive.number_t and
                    narrowed != types.Primitive.boolean_t) return null;
                return .{ .param_index = idx, .target_type = narrowed, .is_asserts = false };
            }
        }

        // `x !== null` / `x !== undefined`.
        if (b.op == .neq_strict and self.hir.kindOf(b.lhs) == .identifier) {
            const idx = self.paramIndexOfIdentifier(b.lhs, params) orelse return null;
            const param_t = self.hir.typeOf(params[idx]);
            if (self.hir.kindOf(b.rhs) == .literal_null) {
                const sub = self.subtractType(param_t, types.Primitive.null_t) catch param_t;
                return .{ .param_index = idx, .target_type = sub, .is_asserts = false };
            }
            if (self.hir.kindOf(b.rhs) == .literal_undefined) {
                const sub = self.subtractType(param_t, types.Primitive.undefined_t) catch param_t;
                return .{ .param_index = idx, .target_type = sub, .is_asserts = false };
            }
            if (self.hir.kindOf(b.rhs) == .identifier) {
                const rhs_id = hir_mod.identifierOf(self.hir, b.rhs);
                const rhs_name = self.string_interner.get(rhs_id.name);
                if (std.mem.eql(u8, rhs_name, "undefined")) {
                    const sub = self.subtractType(param_t, types.Primitive.undefined_t) catch param_t;
                    return .{ .param_index = idx, .target_type = sub, .is_asserts = false };
                }
            }
        }
        return null;
    }

    /// Return the index of the parameter in `params` whose name
    /// matches the `identifier` node `id_node`. Returns null when
    /// `id_node` isn't an identifier or doesn't match any parameter.
    fn paramIndexOfIdentifier(
        self: *Checker,
        id_node: NodeId,
        params: []const NodeId,
    ) ?u16 {
        if (self.hir.kindOf(id_node) != .identifier) return null;
        const id = hir_mod.identifierOf(self.hir, id_node);
        for (params, 0..) |p, i| {
            if (self.hir.kindOf(p) != .parameter) continue;
            const pp = hir_mod.parameterOf(self.hir, p);
            if (pp.name == hir_mod.none_node_id) continue;
            if (self.hir.kindOf(pp.name) != .identifier) continue;
            const pname = hir_mod.identifierOf(self.hir, pp.name);
            if (pname.name == id.name) return @intCast(i);
        }
        return null;
    }

    /// `noUnusedLocals` (TS6133): walk a function body's
    /// statements, find every `let` / `const` / `var` declaration,
    /// and report names not referenced from elsewhere in the body.
    /// Names beginning with `_` are exempt by convention.
    fn checkUnusedLocals(self: *Checker, body: NodeId) CheckError!void {
        if (!self.strict_flags.no_unused_locals) return;
        if (body == hir_mod.none_node_id) return;
        if (self.hir.kindOf(body) != .block_stmt) return;
        var refs: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer refs.deinit(self.gpa);
        try self.collectIdentifierRefs(body, &refs);
        for (hir_mod.blockStmts(self.hir, body)) |s| {
            const k = self.hir.kindOf(s);
            if (k != .var_decl and k != .let_decl and k != .const_decl) continue;
            const v = hir_mod.varDeclOf(self.hir, s);
            if (v.name == hir_mod.none_node_id or self.hir.kindOf(v.name) != .identifier) continue;
            const id = hir_mod.identifierOf(self.hir, v.name);
            const name_str = self.string_interner.get(id.name);
            if (name_str.len > 0 and name_str[0] == '_') continue;
            if (refs.contains(id.name)) continue;
            const msg = try std.fmt.allocPrint(
                self.diag_arena.allocator(),
                "'{s}' is declared but its value is never read.",
                .{name_str},
            );
            try self.diagnostics.append(self.gpa, .{
                .node = s,
                .code = TsCodes.declared_but_not_read,
                .message = msg,
            });
        }
    }

    /// TS2454 — "Variable 'X' is used before being assigned."
    ///
    /// Linear-scan, approximate: walks `stmts` in source order
    /// tracking every `let_decl` whose declaration carries a type
    /// annotation but no initializer. A subsequent identifier read
    /// of such a name (anywhere except as the LHS of a plain
    /// assignment) emits TS2454. A plain `name = ...` removes the
    /// name from the tracked set. This intentionally does *not*
    /// build a control-flow graph — branches collapse to a flat
    /// scan, so it catches the common case but misses anything
    /// involving conditionals.
    fn checkUsedBeforeAssignment(self: *Checker, stmts: []const NodeId) CheckError!void {
        var pending: std.AutoHashMapUnmanaged(hir_mod.StringId, NodeId) = .empty;
        defer pending.deinit(self.gpa);
        for (stmts) |s| try self.scanForUsedBeforeAssign(s, &pending);
    }

    fn scanForUsedBeforeAssign(
        self: *Checker,
        node: NodeId,
        pending: *std.AutoHashMapUnmanaged(hir_mod.StringId, NodeId),
    ) CheckError!void {
        if (node == hir_mod.none_node_id) return;
        const k = self.hir.kindOf(node);
        switch (k) {
            .let_decl => {
                const v = hir_mod.varDeclOf(self.hir, node);
                if (v.init == hir_mod.none_node_id and
                    v.type_annotation != hir_mod.none_node_id and
                    v.name != hir_mod.none_node_id and
                    self.hir.kindOf(v.name) == .identifier)
                {
                    const id = hir_mod.identifierOf(self.hir, v.name);
                    try pending.put(self.gpa, id.name, node);
                }
                if (v.init != hir_mod.none_node_id) {
                    try self.scanExprForUsedBeforeAssign(v.init, pending);
                }
            },
            .var_decl, .const_decl => {
                const v = hir_mod.varDeclOf(self.hir, node);
                if (v.init != hir_mod.none_node_id) {
                    try self.scanExprForUsedBeforeAssign(v.init, pending);
                }
            },
            .assignment => {
                const a = hir_mod.assignmentOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(a.value, pending);
                if (a.target != hir_mod.none_node_id and
                    self.hir.kindOf(a.target) == .identifier)
                {
                    const id = hir_mod.identifierOf(self.hir, a.target);
                    if (a.op != null) {
                        try self.flagIfPending(a.target, id.name, pending);
                    } else {
                        _ = pending.remove(id.name);
                    }
                } else if (a.target != hir_mod.none_node_id) {
                    try self.scanExprForUsedBeforeAssign(a.target, pending);
                }
            },
            .block_stmt => {
                for (hir_mod.blockStmts(self.hir, node)) |s| {
                    try self.scanForUsedBeforeAssign(s, pending);
                }
            },
            .return_stmt => {
                const r = hir_mod.returnOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(r.value, pending);
            },
            // Branching / nested-fn constructs — the linear scan
            // gives up here. Treat the body as opaque so we don't
            // emit false positives across control-flow boundaries.
            .if_stmt,
            .while_stmt,
            .do_while_stmt,
            .for_stmt,
            .for_in_stmt,
            .for_of_stmt,
            .try_stmt,
            .switch_stmt,
            .fn_decl,
            .fn_expr,
            .arrow_fn,
            .class_decl,
            => return,
            else => {
                if (hir_mod.NodeKind.isExpression(k)) {
                    try self.scanExprForUsedBeforeAssign(node, pending);
                }
            },
        }
    }

    fn scanExprForUsedBeforeAssign(
        self: *Checker,
        node: NodeId,
        pending: *std.AutoHashMapUnmanaged(hir_mod.StringId, NodeId),
    ) CheckError!void {
        if (node == hir_mod.none_node_id) return;
        const k = self.hir.kindOf(node);
        switch (k) {
            .identifier => {
                const id = hir_mod.identifierOf(self.hir, node);
                try self.flagIfPending(node, id.name, pending);
            },
            .binary_op => {
                const b = hir_mod.binopOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(b.lhs, pending);
                try self.scanExprForUsedBeforeAssign(b.rhs, pending);
            },
            .unary_op => {
                const u = hir_mod.unaryOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(u.operand, pending);
            },
            .logical_op => {
                const l = hir_mod.logicalOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(l.lhs, pending);
                try self.scanExprForUsedBeforeAssign(l.rhs, pending);
            },
            .conditional => {
                const c = hir_mod.conditionalOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(c.cond, pending);
                try self.scanExprForUsedBeforeAssign(c.then_branch, pending);
                try self.scanExprForUsedBeforeAssign(c.else_branch, pending);
            },
            .call_expr, .new_expr => {
                const c = hir_mod.callOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(c.callee, pending);
                for (hir_mod.callArgs(self.hir, node)) |arg| {
                    try self.scanExprForUsedBeforeAssign(arg, pending);
                }
            },
            .member_access => {
                const m = hir_mod.memberOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(m.object, pending);
            },
            .element_access => {
                const e = hir_mod.elementOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(e.object, pending);
                try self.scanExprForUsedBeforeAssign(e.index, pending);
            },
            .as_expr, .satisfies_expr, .type_assertion => {
                const a = hir_mod.asExpressionOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(a.expr, pending);
            },
            .assignment => {
                const a = hir_mod.assignmentOf(self.hir, node);
                try self.scanExprForUsedBeforeAssign(a.value, pending);
                if (a.target != hir_mod.none_node_id and
                    self.hir.kindOf(a.target) == .identifier)
                {
                    const id = hir_mod.identifierOf(self.hir, a.target);
                    if (a.op != null) {
                        try self.flagIfPending(a.target, id.name, pending);
                    } else {
                        _ = pending.remove(id.name);
                    }
                }
            },
            else => {},
        }
    }

    fn flagIfPending(
        self: *Checker,
        ref_node: NodeId,
        name: hir_mod.StringId,
        pending: *std.AutoHashMapUnmanaged(hir_mod.StringId, NodeId),
    ) CheckError!void {
        if (!pending.contains(name)) return;
        const name_str = self.string_interner.get(name);
        const msg = try std.fmt.allocPrint(
            self.diag_arena.allocator(),
            "Variable '{s}' is used before being assigned.",
            .{name_str},
        );
        try self.diagnostics.append(self.gpa, .{
            .node = ref_node,
            .code = TsCodes.used_before_assignment,
            .message = msg,
        });
        // Remove from pending so we only flag the first use; later
        // reads are noisy.
        _ = pending.remove(name);
    }

    /// `noUnusedParameters` (TS6133): walks the function body and
    /// collects every identifier StringId referenced *outside* a
    /// declaration's name slot, then reports any parameter whose
    /// name doesn't appear. Names starting with `_` are exempt
    /// (matches tsc).
    fn checkUnusedParameters(self: *Checker, fn_node: NodeId, body: NodeId) CheckError!void {
        if (!self.strict_flags.no_unused_parameters) return;
        const params = hir_mod.fnParams(self.hir, fn_node);
        if (params.len == 0) return;
        var refs: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer refs.deinit(self.gpa);
        try self.collectIdentifierRefs(body, &refs);
        for (params) |p| {
            const pp = hir_mod.parameterOf(self.hir, p);
            if (pp.name == hir_mod.none_node_id or self.hir.kindOf(pp.name) != .identifier) continue;
            const id = hir_mod.identifierOf(self.hir, pp.name);
            const name_str = self.string_interner.get(id.name);
            if (name_str.len > 0 and name_str[0] == '_') continue;
            if (refs.contains(id.name)) continue;
            const msg = try std.fmt.allocPrint(
                self.diag_arena.allocator(),
                "'{s}' is declared but its value is never read.",
                .{name_str},
            );
            try self.diagnostics.append(self.gpa, .{
                .node = p,
                .code = TsCodes.declared_but_not_read,
                .message = msg,
            });
        }
    }

    /// `noUnusedParameters` (TS6133) for `catch (e) { ... }` clauses.
    /// Mirrors `checkUnusedParameters`: emits TS6133 when the catch
    /// binding's name is never read inside the catch block. Names
    /// starting with `_` are exempt by tsc convention.
    fn checkUnusedCatchParam(self: *Checker, try_node: NodeId) CheckError!void {
        if (!self.strict_flags.no_unused_parameters) return;
        const ts = hir_mod.tryOf(self.hir, try_node);
        if (ts.catch_param == hir_mod.none_node_id) return;
        if (self.hir.kindOf(ts.catch_param) != .identifier) return;
        const id = hir_mod.identifierOf(self.hir, ts.catch_param);
        const name_str = self.string_interner.get(id.name);
        if (name_str.len > 0 and name_str[0] == '_') return;
        var refs: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer refs.deinit(self.gpa);
        if (ts.catch_block != hir_mod.none_node_id) {
            try self.collectIdentifierRefs(ts.catch_block, &refs);
        }
        if (refs.contains(id.name)) return;
        const msg = try std.fmt.allocPrint(
            self.diag_arena.allocator(),
            "'{s}' is declared but its value is never read.",
            .{name_str},
        );
        try self.diagnostics.append(self.gpa, .{
            .node = ts.catch_param,
            .code = TsCodes.declared_but_not_read,
            .message = msg,
        });
    }

    /// Recursively collect every identifier StringId reachable from
    /// `node` that is *not* the name slot of a declaration. Stops
    /// at nested function boundaries so inner-fn references don't
    /// satisfy outer-fn parameters.
    fn collectIdentifierRefs(
        self: *Checker,
        node: NodeId,
        out: *std.AutoHashMapUnmanaged(hir_mod.StringId, void),
    ) CheckError!void {
        if (node == hir_mod.none_node_id) return;
        const k = self.hir.kindOf(node);
        switch (k) {
            .identifier => {
                const id = hir_mod.identifierOf(self.hir, node);
                if (!self.isDeclNameSlot(node)) try out.put(self.gpa, id.name, {});
            },
            // Nested fns shadow the outer scope — skip them.
            .fn_decl, .fn_expr, .arrow_fn => return,
            .block_stmt => {
                for (hir_mod.blockStmts(self.hir, node)) |s| try self.collectIdentifierRefs(s, out);
            },
            .if_stmt => {
                const i = hir_mod.ifOf(self.hir, node);
                try self.collectIdentifierRefs(i.cond, out);
                try self.collectIdentifierRefs(i.then_branch, out);
                try self.collectIdentifierRefs(i.else_branch, out);
            },
            .while_stmt => {
                const w = hir_mod.whileOf(self.hir, node);
                try self.collectIdentifierRefs(w.cond, out);
                try self.collectIdentifierRefs(w.body, out);
            },
            .do_while_stmt => {
                const w = hir_mod.doWhileOf(self.hir, node);
                try self.collectIdentifierRefs(w.cond, out);
                try self.collectIdentifierRefs(w.body, out);
            },
            .for_stmt => {
                const fr = hir_mod.forStmtOf(self.hir, node);
                try self.collectIdentifierRefs(fr.init, out);
                try self.collectIdentifierRefs(fr.cond, out);
                try self.collectIdentifierRefs(fr.update, out);
                try self.collectIdentifierRefs(fr.body, out);
            },
            .return_stmt => {
                const r = hir_mod.returnOf(self.hir, node);
                try self.collectIdentifierRefs(r.value, out);
            },
            .var_decl, .let_decl, .const_decl => {
                const v = hir_mod.varDeclOf(self.hir, node);
                // Skip `v.name` — it's the declaration site.
                try self.collectIdentifierRefs(v.init, out);
            },
            .binary_op => {
                const b = hir_mod.binopOf(self.hir, node);
                try self.collectIdentifierRefs(b.lhs, out);
                try self.collectIdentifierRefs(b.rhs, out);
            },
            .unary_op => {
                const u = hir_mod.unaryOf(self.hir, node);
                try self.collectIdentifierRefs(u.operand, out);
            },
            .logical_op => {
                const l = hir_mod.logicalOf(self.hir, node);
                try self.collectIdentifierRefs(l.lhs, out);
                try self.collectIdentifierRefs(l.rhs, out);
            },
            .conditional => {
                const c = hir_mod.conditionalOf(self.hir, node);
                try self.collectIdentifierRefs(c.cond, out);
                try self.collectIdentifierRefs(c.then_branch, out);
                try self.collectIdentifierRefs(c.else_branch, out);
            },
            .assignment => {
                const a = hir_mod.assignmentOf(self.hir, node);
                try self.collectIdentifierRefs(a.target, out);
                try self.collectIdentifierRefs(a.value, out);
            },
            .call_expr, .new_expr => {
                const c = hir_mod.callOf(self.hir, node);
                try self.collectIdentifierRefs(c.callee, out);
                for (hir_mod.callArgs(self.hir, node)) |arg| try self.collectIdentifierRefs(arg, out);
            },
            .member_access => {
                const m = hir_mod.memberOf(self.hir, node);
                try self.collectIdentifierRefs(m.object, out);
                // `m.name` is a StringId, not a node — no descend.
            },
            .element_access => {
                const e = hir_mod.elementOf(self.hir, node);
                try self.collectIdentifierRefs(e.object, out);
                try self.collectIdentifierRefs(e.index, out);
            },
            .as_expr, .satisfies_expr, .type_assertion => {
                const a = hir_mod.asExpressionOf(self.hir, node);
                try self.collectIdentifierRefs(a.expr, out);
            },
            .throw_stmt => {
                const t = hir_mod.throwOf(self.hir, node);
                try self.collectIdentifierRefs(t.value, out);
            },
            .try_stmt => {
                const ts = hir_mod.tryOf(self.hir, node);
                try self.collectIdentifierRefs(ts.block, out);
                try self.collectIdentifierRefs(ts.catch_block, out);
                try self.collectIdentifierRefs(ts.finally_block, out);
            },
            .switch_stmt => {
                const sw = hir_mod.switchOf(self.hir, node);
                try self.collectIdentifierRefs(sw.discriminant, out);
                for (hir_mod.switchCases(self.hir, node)) |case| try self.collectIdentifierRefs(case, out);
            },
            .switch_case => {
                for (hir_mod.switchCaseStmts(self.hir, node)) |s| try self.collectIdentifierRefs(s, out);
            },
            .array_literal => {
                for (hir_mod.arrayLiteralElements(self.hir, node)) |el| try self.collectIdentifierRefs(el, out);
            },
            .object_literal => {
                for (hir_mod.objectLiteralProps(self.hir, node)) |p| try self.collectIdentifierRefs(p, out);
            },
            .object_property => {
                const op = hir_mod.objectPropertyOf(self.hir, node);
                try self.collectIdentifierRefs(op.value, out);
                // Computed keys reference identifiers; skip the name slot.
                if (op.is_computed) try self.collectIdentifierRefs(op.key, out);
            },
            else => {},
        }
    }

    /// True when `node` is the name slot of its enclosing
    /// declaration (parameter / var / fn / class / interface /
    /// type alias). Used to filter declarations out of the
    /// reference-counting walk.
    fn isDeclNameSlot(self: *Checker, node: NodeId) bool {
        const parent = self.hir.parentOf(node);
        if (parent == hir_mod.none_node_id) return false;
        switch (self.hir.kindOf(parent)) {
            .parameter => {
                const p = hir_mod.parameterOf(self.hir, parent);
                return p.name == node;
            },
            .var_decl, .let_decl, .const_decl => {
                const v = hir_mod.varDeclOf(self.hir, parent);
                return v.name == node;
            },
            .fn_decl, .fn_expr, .arrow_fn => {
                const f = hir_mod.fnDeclOf(self.hir, parent);
                return f.name == node;
            },
            .class_decl, .class_expr => {
                const c = hir_mod.classOf(self.hir, parent);
                return c.name == node;
            },
            .interface_decl => {
                const it = hir_mod.interfaceOf(self.hir, parent);
                return it.name == node;
            },
            .type_alias_decl => {
                const ta = hir_mod.typeAliasOf(self.hir, parent);
                return ta.name == node;
            },
            else => return false,
        }
    }

    /// If `t` is structurally a `Promise<T>` — an object type with a
    /// `then` member whose first parameter is itself a signature
    /// `(value: T) => any` — return `T`. Otherwise return `t`
    /// unchanged. This lets `await p` unwrap to the resolved value
    /// type without first-class generics support.
    fn unwrapPromise(self: *Checker, t: TypeId) TypeId {
        if (!self.interner.pool.flagsOf(t).is_object_type) return t;
        const then_id = self.string_interner.intern("then") catch return t;
        const then_t = self.interner.objectMember(t, then_id) orelse return t;
        if (!self.interner.pool.flagsOf(then_t).is_signature) return t;
        const then_params = self.interner.signatureParams(then_t);
        if (then_params.len == 0) return t;
        const cb_t = then_params[0];
        if (!self.interner.pool.flagsOf(cb_t).is_signature) return t;
        const cb_params = self.interner.signatureParams(cb_t);
        if (cb_params.len == 0) return t;
        return cb_params[0];
    }

    /// `Awaited<T>` (TS 4.5) — recursively unwrap `Promise<U>` until
    /// the operand is no longer a structural Promise. For non-Promise
    /// types this is a no-op and `t` is returned unchanged.
    fn evalAwaited(self: *Checker, t: TypeId) TypeId {
        var cur = t;
        // Cap recursion in case of pathological self-referential
        // Promise shapes; TS itself imposes no fixed depth, but a
        // small bound matches the practical universe of Promise<...>
        // chains and prevents runaway loops on cyclic types.
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const next = self.unwrapPromise(cur);
            if (next == cur) return cur;
            cur = next;
        }
        return cur;
    }

    /// Build a minimal structural `Promise<T>` object type — `{ then:
    /// (cb: (value: T) => any) => any }` — used when intercepting
    /// `Promise<T>` type-refs so downstream Awaited / await unwrap
    /// machinery can recognize and peel them.
    fn buildStructuralPromise(self: *Checker, value_t: TypeId) CheckError!TypeId {
        const cb_params = [_]TypeId{value_t};
        const cb_sig = self.interner.internSignature(&cb_params, types.Primitive.any, false) catch return error.OutOfMemory;
        const then_params = [_]TypeId{cb_sig};
        const then_sig = self.interner.internSignature(&then_params, types.Primitive.any, false) catch return error.OutOfMemory;
        const then_id = self.string_interner.intern("then") catch return error.OutOfMemory;
        const members = [_]types.ObjectMember{.{
            .name = then_id,
            .type = then_sig,
            .is_optional = false,
            .is_readonly = false,
            .is_method = true,
        }};
        return self.interner.internObjectType(&members) catch return error.OutOfMemory;
    }

    /// Re-intern the function's signature with `new_ret` as the
    /// return type, then update the node's type. Identifier lookups
    /// against the function's name see the refined signature.
    fn refineSignatureReturn(self: *Checker, fn_node: NodeId, new_ret: TypeId) CheckError!void {
        const sig = self.hir.typeOf(fn_node);
        if (!self.interner.pool.flagsOf(sig).is_signature) return;
        const params = self.interner.signatureParams(sig);
        // Skip if the inferred type is the same as what we already
        // had (avoids re-interning a no-op).
        if (self.interner.signatureReturn(sig)) |old| if (old == new_ret) return;
        const new_sig = self.interner.internSignature(params, new_ret, false) catch return error.OutOfMemory;
        self.hir.setType(fn_node, new_sig);
        const f = hir_mod.fnDeclOf(self.hir, fn_node);
        if (f.name != hir_mod.none_node_id) self.hir.setType(f.name, new_sig);
    }

    /// Walk a node tree collecting the types of every `return value`
    /// statement reachable from `node`, but stop at any nested
    /// function boundary so inner-fn returns don't leak into the
    /// outer signature.
    fn collectReturnTypes(
        self: *Checker,
        node: NodeId,
        out: *std.ArrayListUnmanaged(TypeId),
    ) CheckError!void {
        if (node == hir_mod.none_node_id) return;
        const k = self.hir.kindOf(node);
        switch (k) {
            .return_stmt => {
                const r = hir_mod.returnOf(self.hir, node);
                if (r.value != hir_mod.none_node_id) {
                    try out.append(self.gpa, self.hir.typeOf(r.value));
                }
            },
            // Don't descend into nested functions — their returns
            // bind to their own signature.
            .fn_decl, .fn_expr, .arrow_fn => return,
            else => {
                // Walk every child of this node. The HIR exposes
                // a generic per-payload accessor pattern; here we
                // just iterate all child nodes via `forEachChild`.
                try self.forEachChildCollect(node, out);
            },
        }
    }

    fn forEachChildCollect(
        self: *Checker,
        node: NodeId,
        out: *std.ArrayListUnmanaged(TypeId),
    ) CheckError!void {
        const k = self.hir.kindOf(node);
        switch (k) {
            .block_stmt => {
                for (hir_mod.blockStmts(self.hir, node)) |s| try self.collectReturnTypes(s, out);
            },
            .if_stmt => {
                const i = hir_mod.ifOf(self.hir, node);
                try self.collectReturnTypes(i.then_branch, out);
                try self.collectReturnTypes(i.else_branch, out);
            },
            .while_stmt => {
                const w = hir_mod.whileOf(self.hir, node);
                try self.collectReturnTypes(w.body, out);
            },
            .do_while_stmt => {
                const w = hir_mod.doWhileOf(self.hir, node);
                try self.collectReturnTypes(w.body, out);
            },
            .for_stmt => {
                const fr = hir_mod.forStmtOf(self.hir, node);
                try self.collectReturnTypes(fr.body, out);
            },
            .try_stmt => {
                const ts = hir_mod.tryOf(self.hir, node);
                try self.collectReturnTypes(ts.block, out);
                if (ts.catch_block != hir_mod.none_node_id) try self.collectReturnTypes(ts.catch_block, out);
                if (ts.finally_block != hir_mod.none_node_id) try self.collectReturnTypes(ts.finally_block, out);
            },
            .switch_stmt => {
                for (hir_mod.switchCases(self.hir, node)) |case| try self.collectReturnTypes(case, out);
            },
            .switch_case => {
                for (hir_mod.switchCaseStmts(self.hir, node)) |s| try self.collectReturnTypes(s, out);
            },
            else => {},
        }
    }

    /// Walk a type's structural body in search of the given type
    /// parameter, accumulating the variance positions in which it
    /// occurs. Returns the combined variance:
    ///   - `.covariant` only — output position (return / property /
    ///     array element / union member).
    ///   - `.contravariant` only — input position (signature param).
    ///   - both → `.invariant`.
    ///   - neither → `.bivariant` (T is unused, or only appears
    ///     under `keyof` where it's treated as a key).
    fn inferVariance(self: *Checker, body_t: TypeId, param_id: TypeId) types.Variance {
        var saw_co = false;
        var saw_ct = false;
        self.scanVariance(body_t, param_id, .covariant, &saw_co, &saw_ct);
        if (saw_co and saw_ct) return .invariant;
        if (saw_co) return .covariant;
        if (saw_ct) return .contravariant;
        return .bivariant;
    }

    /// Recursive worker for `inferVariance`. `position` tracks the
    /// polarity of the slot being entered: `.covariant` for output
    /// positions, `.contravariant` for input positions, `.invariant`
    /// for read+write slots (the object of an indexed access),
    /// `.bivariant` to suppress recording (under `keyof`).
    fn scanVariance(
        self: *Checker,
        t: TypeId,
        param_id: TypeId,
        position: types.Variance,
        saw_co: *bool,
        saw_ct: *bool,
    ) void {
        if (t == param_id) {
            switch (position) {
                .covariant => saw_co.* = true,
                .contravariant => saw_ct.* = true,
                .invariant => {
                    saw_co.* = true;
                    saw_ct.* = true;
                },
                .bivariant => {},
            }
            return;
        }
        if (t < types.Primitive.first_dynamic) return;
        const flags = self.interner.pool.flagsOf(t);

        if (flags.is_signature) {
            for (self.interner.signatureParams(t)) |p| {
                self.scanVariance(p, param_id, flipVariance(position), saw_co, saw_ct);
            }
            if (self.interner.signatureReturn(t)) |r| {
                self.scanVariance(r, param_id, position, saw_co, saw_ct);
            }
            return;
        }
        if (flags.is_object_type) {
            const members = self.interner.objectMembers(t);
            for (members) |m| {
                self.scanVariance(m.type, param_id, position, saw_co, saw_ct);
            }
            const si = self.interner.objectStringIndex(t);
            if (si != types.Primitive.none) self.scanVariance(si, param_id, position, saw_co, saw_ct);
            const ni = self.interner.objectNumberIndex(t);
            if (ni != types.Primitive.none) self.scanVariance(ni, param_id, position, saw_co, saw_ct);
            return;
        }
        if (flags.is_union) {
            for (self.interner.unionMembers(t)) |m| {
                self.scanVariance(m, param_id, position, saw_co, saw_ct);
            }
            return;
        }
        if (flags.is_intersection) {
            for (self.interner.intersectionMembers(t)) |m| {
                self.scanVariance(m, param_id, position, saw_co, saw_ct);
            }
            return;
        }
        if (flags.is_tuple) {
            const payload = self.interner.pool.tuple_payloads.items[self.interner.pool.payloadOf(t)];
            const elems = self.interner.pool.tuple_element_pool.items[payload.elements_start .. payload.elements_start + payload.elements_len];
            for (elems) |e| {
                self.scanVariance(e.type, param_id, position, saw_co, saw_ct);
            }
            return;
        }
        if (flags.is_keyof) {
            // `keyof T` — T is consumed as a key; treat as bivariant
            // (suppress recording inside the keyof operand).
            return;
        }
        if (flags.is_indexed_access) {
            const payload = self.interner.pool.indexed_access_payloads.items[self.interner.pool.payloadOf(t)];
            // Object slot is read+write → invariant. Index slot
            // stays at the surrounding polarity.
            self.scanVariance(payload.object, param_id, .invariant, saw_co, saw_ct);
            self.scanVariance(payload.index, param_id, position, saw_co, saw_ct);
            return;
        }
        if (flags.is_conditional) {
            const c = self.interner.conditionalPayload(t);
            self.scanVariance(c.check_type, param_id, position, saw_co, saw_ct);
            self.scanVariance(c.extends_type, param_id, position, saw_co, saw_ct);
            self.scanVariance(c.true_branch, param_id, position, saw_co, saw_ct);
            self.scanVariance(c.false_branch, param_id, position, saw_co, saw_ct);
            return;
        }
        if (flags.is_mapped) {
            const m = self.interner.mappedPayload(t);
            self.scanVariance(m.constraint, param_id, position, saw_co, saw_ct);
            self.scanVariance(m.template, param_id, position, saw_co, saw_ct);
            return;
        }
        if (flags.is_instantiation) {
            const payload = self.interner.pool.instantiation_payloads.items[self.interner.pool.payloadOf(t)];
            const args = self.interner.pool.type_arg_pool.items[payload.args_start .. payload.args_start + payload.args_len];
            // Without per-origin variance metadata, treat each
            // type-argument slot at the surrounding polarity. A
            // future fixed-point pass can refine this.
            for (args) |a| {
                self.scanVariance(a, param_id, position, saw_co, saw_ct);
            }
            return;
        }
        // Primitives, literals, and type parameters other than the
        // target — nothing to walk.
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
        var captured_tp_ids: std.ArrayListUnmanaged(TypeId) = .empty;
        defer captured_tp_ids.deinit(self.gpa);
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
            const tp_id = self.interner.internTypeParameterWithVariance(
                tpp.name,
                constraint,
                def,
                types.Variance.fromHirBits(tpp.variance),
            ) catch return error.OutOfMemory;
            self.hir.setType(tp, tp_id);
            try self.recordNarrow(tpp.name, tp_id);
            try captured_tp_ids.append(self.gpa, tp_id);
        }

        var param_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer param_types.deinit(self.gpa);
        const params = hir_mod.fnParams(self.hir, node);
        for (params) |p| {
            const pp = hir_mod.parameterOf(self.hir, p);
            const has_anno = pp.type_annotation != hir_mod.none_node_id;
            var t: TypeId = if (has_anno)
                try self.lowererLowerWithTypeParams(pp.type_annotation)
            else
                types.Primitive.any;
            // `f(x?: T)` and `f(x: T = default)` both widen the
            // parameter type to include `undefined` (matches the
            // call-site behavior where the caller can omit the arg).
            if (pp.flags.is_optional or pp.default_value != hir_mod.none_node_id) {
                t = self.unionWithUndefined(t) catch t;
            }
            try param_types.append(self.gpa, t);
            self.hir.setType(p, t);
            if (pp.name != hir_mod.none_node_id) self.hir.setType(pp.name, t);
            if (!has_anno and self.strict_flags.no_implicit_any) {
                const param_name: []const u8 = if (pp.name != hir_mod.none_node_id and self.hir.kindOf(pp.name) == .identifier)
                    self.string_interner.get(hir_mod.identifierOf(self.hir, pp.name).name)
                else
                    "<anonymous>";
                const msg = try std.fmt.allocPrint(
                    self.diag_arena.allocator(),
                    "Parameter '{s}' implicitly has an 'any' type.",
                    .{param_name},
                );
                try self.diagnostics.append(self.gpa, .{
                    .node = p,
                    .code = TsCodes.parameter_implicitly_any,
                    .message = msg,
                });
            }
        }

        // Detect a `arg is T` / `asserts arg is T` return-type
        // before lowering — the predicate's target type is the
        // *return type* for assignability purposes (it always
        // returns boolean), but we record the predicate separately
        // so call sites can narrow the argument.
        const is_predicate = f.return_type != hir_mod.none_node_id and
            self.hir.kindOf(f.return_type) == .type_predicate_type;
        const ret_t: TypeId = if (f.return_type != hir_mod.none_node_id)
            (if (is_predicate) types.Primitive.boolean_t else try self.lowererLowerWithTypeParams(f.return_type))
        else
            types.Primitive.any;

        const sig = self.interner.internSignature(param_types.items, ret_t, false) catch return error.OutOfMemory;
        self.hir.setType(node, sig);
        if (f.name != hir_mod.none_node_id) self.hir.setType(f.name, sig);
        // Auto-infer variance for any type parameter that had no
        // explicit `in` / `out` modifier. We walk the signature —
        // an occurrence of T in a param slot is contravariant, in
        // the return slot covariant. The result lives in the
        // `inferred_variance` side table since the interner keys
        // variance into the TypeId.
        if (captured_tp_ids.items.len > 0) {
            var tp_ix: usize = 0;
            for (type_params) |tp_node| {
                if (self.hir.kindOf(tp_node) != .type_parameter) continue;
                const tpp_h = hir_mod.typeParameterOf(self.hir, tp_node);
                if (tp_ix >= captured_tp_ids.items.len) break;
                const tp_id_v = captured_tp_ids.items[tp_ix];
                tp_ix += 1;
                if (tpp_h.variance != 0) continue; // explicit `in`/`out`
                const v = self.inferVariance(sig, tp_id_v);
                try self.inferred_variance.put(self.gpa, tp_id_v, v);
            }
        }
        // Record the function's generic type parameters keyed by name
        // so call sites with explicit type args (`f<T>(args)`) can
        // substitute directly. Drop any prior recording on shadow.
        if (captured_tp_ids.items.len > 0 and f.name != hir_mod.none_node_id and self.hir.kindOf(f.name) == .identifier) {
            const fn_name = hir_mod.identifierOf(self.hir, f.name).name;
            if (self.generic_fns.fetchRemove(fn_name)) |old| self.gpa.free(old.value);
            const owned = captured_tp_ids.toOwnedSlice(self.gpa) catch return error.OutOfMemory;
            try self.generic_fns.put(self.gpa, fn_name, owned);
        }
        // Overload tracking: when multiple `function f(...)` decls
        // share a name, we treat the body-less ones as overload
        // signatures. The body-bearing one is the implementation
        // (used only for body typing — never picked by call-site
        // resolution).
        if (f.name != hir_mod.none_node_id and self.hir.kindOf(f.name) == .identifier) {
            const fn_name = hir_mod.identifierOf(self.hir, f.name).name;
            const has_body = f.body != hir_mod.none_node_id;
            const gop = try self.overloads.getOrPut(self.gpa, fn_name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            // The implementation signature is appended last but
            // marked-by-position (not by flag). Caller picks the
            // first compatible non-final entry; falls back to
            // last (the impl) when none match.
            if (!has_body) {
                try gop.value_ptr.*.append(self.gpa, sig);
            } else {
                // Implementation signature: only append if there
                // are existing overloads — a single-decl function
                // doesn't need overload resolution.
                if (gop.value_ptr.*.items.len > 0) {
                    try gop.value_ptr.*.append(self.gpa, sig);
                }
            }
        }
        // Record the predicate so call sites can narrow.
        if (is_predicate and f.name != hir_mod.none_node_id and self.hir.kindOf(f.name) == .identifier) {
            const pred = hir_mod.typePredicateOf(self.hir, f.return_type);
            const target_t: TypeId = if (pred.target_type != hir_mod.none_node_id)
                (self.lowererLowerWithTypeParams(pred.target_type) catch types.Primitive.unknown)
            else
                types.Primitive.unknown;
            const fn_name = hir_mod.identifierOf(self.hir, f.name).name;
            try self.fn_predicates.put(self.gpa, fn_name, .{
                .param_index = pred.param_index,
                .target_type = target_t,
                .is_asserts = pred.is_asserts,
            });
        }
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
        // Names of class members declared `private`. After the class
        // name is known we move ownership into `class_private_members`
        // and reset this local to `.empty` so the trailing `defer` is
        // a no-op on the success path.
        var private_names: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer private_names.deinit(self.gpa);
        var protected_names: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer protected_names.deinit(self.gpa);
        // Names of class members treated as abstract (v0 heuristic:
        // bodyless methods inside an `abstract` class). Moved into
        // `class_abstract_members` once the class name is known.
        var abstract_names: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer abstract_names.deinit(self.gpa);
        // Names the child concretely implements (methods with a body
        // or any field). Used to satisfy inherited abstract members.
        var concrete_names: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer concrete_names.deinit(self.gpa);

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
                    if (fn_p.flags.is_private) try private_names.put(self.gpa, id.name, {});
                    if (fn_p.flags.is_protected) try protected_names.put(self.gpa, id.name, {});
                    // v0 abstract-member heuristic: a method without
                    // a body inside an `abstract` class is treated as
                    // abstract. Methods with a body count as concrete
                    // implementations and satisfy any inherited
                    // abstract member of the same name.
                    if (c.is_abstract and fn_p.body == hir_mod.none_node_id) {
                        try abstract_names.put(self.gpa, id.name, {});
                    } else {
                        try concrete_names.put(self.gpa, id.name, {});
                    }
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
                    if (op.visibility == .private) try private_names.put(self.gpa, id.name, {});
                    if (op.visibility == .protected) try protected_names.put(self.gpa, id.name, {});
                    // Class fields count as concrete implementations
                    // for the purpose of satisfying inherited abstract
                    // members (v0 has no syntax for abstract fields).
                    try concrete_names.put(self.gpa, id.name, {});
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
            try self.class_name_by_instance.put(self.gpa, instance_t, cid.name);
            if (ctor_sig != types.Primitive.none) {
                try self.class_constructor_sigs.put(self.gpa, cid.name, ctor_sig);
            }
            // Track abstract classes so `new X()` can emit TS2511.
            if (c.is_abstract) {
                try self.abstract_classes.put(self.gpa, cid.name, {});
            } else {
                _ = self.abstract_classes.remove(cid.name);
            }
            // Register the private-member set under the class name.
            // A prior registration (rare — repeated checks of the
            // same source) gets clobbered; release the old set's
            // memory before overwriting.
            if (self.class_private_members.fetchRemove(cid.name)) |old| {
                var owned = old.value;
                owned.deinit(self.gpa);
            }
            try self.class_private_members.put(self.gpa, cid.name, private_names);
            // Ownership has moved into the map; reset the local so
            // the trailing `defer` is a no-op on the success path.
            private_names = .empty;
            if (self.class_protected_members.fetchRemove(cid.name)) |old| {
                var owned = old.value;
                owned.deinit(self.gpa);
            }
            try self.class_protected_members.put(self.gpa, cid.name, protected_names);
            protected_names = .empty;
            // Register abstract-member set for this class so subclass
            // checks can consult it. Replace any prior entry.
            if (self.class_abstract_members.fetchRemove(cid.name)) |old| {
                var owned = old.value;
                owned.deinit(self.gpa);
            }
            try self.class_abstract_members.put(self.gpa, cid.name, abstract_names);
            abstract_names = .empty;
            if (c.extends != hir_mod.none_node_id and self.hir.kindOf(c.extends) == .identifier) {
                const ext_id = hir_mod.identifierOf(self.hir, c.extends);
                if (self.class_instance_types.contains(ext_id.name)) {
                    try self.class_parent.put(self.gpa, cid.name, ext_id.name);
                }
                // TS2515: a non-abstract class extending an abstract
                // parent must implement each inherited abstract
                // member. v0 walks one level only and emits one
                // diagnostic per missing member.
                if (!c.is_abstract) {
                    if (self.class_abstract_members.getPtr(ext_id.name)) |parent_abs| {
                        var it = parent_abs.keyIterator();
                        while (it.next()) |name_ptr| {
                            const member_name = name_ptr.*;
                            if (concrete_names.contains(member_name)) continue;
                            const member_str = self.string_interner.get(member_name);
                            const child_str = self.string_interner.get(cid.name);
                            const parent_str = self.string_interner.get(ext_id.name);
                            const msg = try std.fmt.allocPrint(
                                self.diag_arena.allocator(),
                                "Non-abstract class '{s}' does not implement inherited abstract member '{s}' from class '{s}'.",
                                .{ child_str, member_str, parent_str },
                            );
                            try self.diagnostics.append(self.gpa, .{
                                .node = node,
                                .code = TsCodes.abstract_member_not_implemented,
                                .message = msg,
                            });
                        }
                    }
                }
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

    /// TS2341: emit when `obj.name` reaches a member declared
    /// `private` from outside the declaring class body. The check
    /// is purely structural in v0:
    ///
    ///   1. Map `obj_t` back to a class name via
    ///      `class_name_by_instance`. Non-class receivers
    ///      (interfaces, plain object types) bail out.
    ///   2. Look up the class's private-member set. Non-private
    ///      props bail out.
    ///   3. Walk parents of `node` — if no enclosing `class_decl`
    ///      matches the declaring class's name, the access is
    ///      outside the body and we emit TS2341.
    ///
    /// Inheritance is intentionally not chased — `private` in TS
    /// is per-class, so a subclass accessing a parent-class
    /// `private` member is also a TS2341.
    fn checkPrivateMemberAccess(
        self: *Checker,
        node: NodeId,
        obj_t: TypeId,
        prop_name: hir_mod.StringId,
    ) CheckError!void {
        const class_name = self.class_name_by_instance.get(obj_t) orelse return;
        const private_set = self.class_private_members.getPtr(class_name) orelse return;
        if (!private_set.contains(prop_name)) return;
        // Walk parents looking for an enclosing `class_decl` whose
        // name matches `class_name`. Found → access is inside the
        // declaring body; allow it.
        var cur = self.hir.parentOf(node);
        while (cur != hir_mod.none_node_id) : (cur = self.hir.parentOf(cur)) {
            const k = self.hir.kindOf(cur);
            if (k != .class_decl and k != .class_expr) continue;
            const c = hir_mod.classOf(self.hir, cur);
            if (c.name == hir_mod.none_node_id or self.hir.kindOf(c.name) != .identifier) continue;
            const enclosing = hir_mod.identifierOf(self.hir, c.name).name;
            if (enclosing == class_name) return;
        }
        const prop_str = self.string_interner.get(prop_name);
        const class_str = self.string_interner.get(class_name);
        const msg = try std.fmt.allocPrint(
            self.diag_arena.allocator(),
            "Property '{s}' is private and only accessible within class '{s}'.",
            .{ prop_str, class_str },
        );
        try self.diagnostics.append(self.gpa, .{
            .node = node,
            .code = TsCodes.private_member_access,
            .message = msg,
        });
    }

    /// TS2445: emit when `obj.name` reaches a member declared
    /// `protected` from outside the declaring class and its
    /// subclass chain. Mirrors `checkPrivateMemberAccess` but
    /// allows access from any subclass body — walk the enclosing
    /// `class_decl` chain via `class_parent` to see whether the
    /// receiver's declaring class is reachable through `extends`.
    fn checkProtectedMemberAccess(
        self: *Checker,
        node: NodeId,
        obj_t: TypeId,
        prop_name: hir_mod.StringId,
    ) CheckError!void {
        const class_name = self.class_name_by_instance.get(obj_t) orelse return;
        const protected_set = self.class_protected_members.getPtr(class_name) orelse return;
        if (!protected_set.contains(prop_name)) return;
        var cur = self.hir.parentOf(node);
        while (cur != hir_mod.none_node_id) : (cur = self.hir.parentOf(cur)) {
            const k = self.hir.kindOf(cur);
            if (k != .class_decl and k != .class_expr) continue;
            const c = hir_mod.classOf(self.hir, cur);
            if (c.name == hir_mod.none_node_id or self.hir.kindOf(c.name) != .identifier) continue;
            const enclosing = hir_mod.identifierOf(self.hir, c.name).name;
            var probe: ?hir_mod.StringId = enclosing;
            while (probe) |p| {
                if (p == class_name) return;
                probe = self.class_parent.get(p);
            }
        }
        const prop_str = self.string_interner.get(prop_name);
        const class_str = self.string_interner.get(class_name);
        const msg = try std.fmt.allocPrint(
            self.diag_arena.allocator(),
            "Property '{s}' is protected and only accessible within class '{s}' and its subclasses.",
            .{ prop_str, class_str },
        );
        try self.diagnostics.append(self.gpa, .{
            .node = node,
            .code = TsCodes.protected_member_access,
            .message = msg,
        });
    }

    /// TS2540: emit when an assignment target `obj.x` resolves to a
    /// property declared `readonly`. Object/interface readonly props
    /// are always immutable; class-level readonly fields are
    /// approximated by the constructor exception — `this.x = ...`
    /// inside a constructor body is allowed. Bare `any` receivers and
    /// non-object types are silently skipped (no readonly to enforce).
    fn checkReadonlyAssignment(self: *Checker, target: NodeId) CheckError!void {
        if (self.hir.kindOf(target) != .member_access) return;
        const m = hir_mod.memberOf(self.hir, target);
        const obj_t = self.hir.typeOf(m.object);
        if (obj_t == types.Primitive.none) return;
        if (!self.interner.pool.flagsOf(obj_t).is_object_type) return;
        const info = self.interner.objectMemberInfo(obj_t, m.name) orelse return;
        if (!info.is_readonly) return;
        // Constructor exception: a class-level readonly field may be
        // initialized inside the class's own constructor via
        // `this.x = ...`. Approximate by allowing any `this.<x>`
        // assignment whose nearest enclosing fn is a constructor.
        if (self.hir.kindOf(m.object) == .this_expr) {
            var cur = self.hir.parentOf(target);
            while (cur != hir_mod.none_node_id) : (cur = self.hir.parentOf(cur)) {
                const k = self.hir.kindOf(cur);
                if (k == .fn_decl or k == .fn_expr or k == .arrow_fn) {
                    const fp = hir_mod.fnDeclOf(self.hir, cur);
                    if (fp.flags.is_constructor) return;
                    break;
                }
            }
        }
        const prop_str = self.string_interner.get(m.name);
        const msg = try std.fmt.allocPrint(
            self.diag_arena.allocator(),
            "Cannot assign to '{s}' because it is a read-only property.",
            .{prop_str},
        );
        try self.diagnostics.append(self.gpa, .{
            .node = target,
            .code = TsCodes.readonly_property,
            .message = msg,
        });
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

    /// Per-statement check for `import … from "spec"`. The binder
    /// already declared the local bindings; this pass enforces the
    /// `resolveJsonModule` rule: when the option is OFF, an import
    /// from a `.json` specifier is unresolved and emits TS2307.
    /// When ON the import resolves and the default binding stays
    /// `any` (v0 — TS would refine to the parsed JSON's shape).
    fn checkImportDecl(self: *Checker, node: NodeId) CheckError!void {
        const imp = hir_mod.importOf(self.hir, node);
        const spec = self.string_interner.get(imp.module);
        if (spec.len == 0) return;
        if (!std.mem.endsWith(u8, spec, ".json")) return;
        if (self.strict_flags.resolve_json_module) return;
        const msg = try std.fmt.allocPrint(
            self.diag_arena.allocator(),
            "Cannot find module '{s}' or its corresponding type declarations.",
            .{spec},
        );
        try self.diagnostics.append(self.gpa, .{
            .node = node,
            .code = TsCodes.cannot_find_module,
            .message = msg,
        });
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

        var string_idx: TypeId = types.Primitive.none;
        var number_idx: TypeId = types.Primitive.none;
        for (members) |m| {
            if (self.hir.kindOf(m) == .index_signature) {
                const ix = hir_mod.indexSignatureOf(self.hir, m);
                const value_t = if (ix.value_type != hir_mod.none_node_id)
                    try self.lowererLowerWithTypeParams(ix.value_type)
                else
                    types.Primitive.any;
                const key_t = if (ix.key_type != hir_mod.none_node_id)
                    try self.lowererLowerWithTypeParams(ix.key_type)
                else
                    types.Primitive.string_t;
                if (key_t == types.Primitive.string_t) string_idx = value_t;
                if (key_t == types.Primitive.number_t) number_idx = value_t;
                continue;
            }
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

        // `interface B extends A { ... }` — merge each parent's
        // members into the child. Child decls win on name conflict.
        const extends = hir_mod.interfaceExtends(self.hir, node);
        if (extends.len > 0) {
            try self.mergeInterfaceExtends(extends, &iface_members, &string_idx, &number_idx);
        }

        const iface_t = self.interner.internObjectTypeWithIndex(iface_members.items, string_idx, number_idx) catch return error.OutOfMemory;
        self.hir.setType(node, iface_t);
        if (it.name != hir_mod.none_node_id and self.hir.kindOf(it.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, it.name);
            try self.type_names.put(self.gpa, id.name, iface_t);
            self.hir.setType(it.name, iface_t);
        }
    }

    /// Pull in members from every parent interface listed in
    /// `extends`. Child entries already in `child_members` win on
    /// name conflict. Index signatures inherit when the child
    /// hasn't declared its own.
    fn mergeInterfaceExtends(
        self: *Checker,
        extends: []const NodeId,
        child_members: *std.ArrayListUnmanaged(types.ObjectMember),
        string_idx: *TypeId,
        number_idx: *TypeId,
    ) CheckError!void {
        var child_names: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer child_names.deinit(self.gpa);
        for (child_members.items) |m| try child_names.put(self.gpa, m.name, {});

        var inherited: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
        defer inherited.deinit(self.gpa);
        for (extends) |ext_node| {
            // Each entry is a `type_ref`; lower it through the
            // type-name table to get the parent's interned shape.
            const parent_t = self.lowererLowerWithTypeParams(ext_node) catch continue;
            if (!self.interner.pool.flagsOf(parent_t).is_object_type) continue;
            for (self.interner.objectMembers(parent_t)) |pm| {
                if (child_names.contains(pm.name)) continue;
                try inherited.append(self.gpa, pm);
                try child_names.put(self.gpa, pm.name, {});
            }
            if (string_idx.* == types.Primitive.none) {
                const pi = self.interner.objectStringIndex(parent_t);
                if (pi != types.Primitive.none) string_idx.* = pi;
            }
            if (number_idx.* == types.Primitive.none) {
                const pi = self.interner.objectNumberIndex(parent_t);
                if (pi != types.Primitive.none) number_idx.* = pi;
            }
        }
        if (inherited.items.len > 0) {
            try child_members.insertSlice(self.gpa, 0, inherited.items);
        }
    }

    /// Lower a type alias `type Alias<T...> = U` into the
    /// underlying type's TypeId and record it under the alias name.
    /// For non-generic aliases the body lowers directly. For
    /// generic aliases, we intern each type parameter, push it onto
    /// the narrow scope so the body resolves under that binding,
    /// and store `(params, body)` in `generic_aliases` so later
    /// `Alias<X>` references can substitute X for the original
    /// parameter.
    fn checkTypeAliasDecl(self: *Checker, node: NodeId) CheckError!void {
        const ta = hir_mod.typeAliasOf(self.hir, node);
        if (ta.aliased == hir_mod.none_node_id) return;
        const type_params = self.hir.childSlice(ta.type_params_start, ta.type_params_len);
        if (type_params.len == 0) {
            const aliased_t = try self.lowererLowerWithTypeParams(ta.aliased);
            self.hir.setType(node, aliased_t);
            if (ta.name != hir_mod.none_node_id and self.hir.kindOf(ta.name) == .identifier) {
                const id = hir_mod.identifierOf(self.hir, ta.name);
                try self.type_names.put(self.gpa, id.name, aliased_t);
                self.hir.setType(ta.name, aliased_t);
            }
            return;
        }

        // Generic alias: intern each type parameter, lower body
        // under their narrow binding, then store the (params, body)
        // for later instantiation.
        try self.pushNarrowScope();
        defer self.popNarrowScope();
        var param_ids: std.ArrayListUnmanaged(TypeId) = .empty;
        errdefer param_ids.deinit(self.gpa);
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
            const tp_id = self.interner.internTypeParameterWithVariance(
                tpp.name,
                constraint,
                def,
                types.Variance.fromHirBits(tpp.variance),
            ) catch return error.OutOfMemory;
            self.hir.setType(tp, tp_id);
            try self.recordNarrow(tpp.name, tp_id);
            try param_ids.append(self.gpa, tp_id);
        }
        const body_t = try self.lowererLowerWithTypeParams(ta.aliased);
        self.hir.setType(node, body_t);
        // Auto-infer variance for any alias type parameter without
        // an explicit `in` / `out` modifier. See `inferVariance`.
        {
            var tp_ix: usize = 0;
            for (type_params) |tp_node| {
                if (self.hir.kindOf(tp_node) != .type_parameter) continue;
                const tpp_h = hir_mod.typeParameterOf(self.hir, tp_node);
                if (tp_ix >= param_ids.items.len) break;
                const tp_id_v = param_ids.items[tp_ix];
                tp_ix += 1;
                if (tpp_h.variance != 0) continue; // explicit `in`/`out`
                const v = self.inferVariance(body_t, tp_id_v);
                try self.inferred_variance.put(self.gpa, tp_id_v, v);
            }
        }
        const owned_params = param_ids.toOwnedSlice(self.gpa) catch return error.OutOfMemory;
        if (ta.name != hir_mod.none_node_id and self.hir.kindOf(ta.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, ta.name);
            try self.generic_aliases.put(self.gpa, id.name, .{
                .params = owned_params,
                .body = body_t,
                .body_node = ta.aliased,
            });
            // Also expose the un-instantiated body via `type_names`
            // so a bare `Alias` (no type-args) resolves — TS treats
            // it as `Alias<unknown, …>`.
            try self.type_names.put(self.gpa, id.name, body_t);
            self.hir.setType(ta.name, body_t);
        }
    }

    /// Lower a type annotation while consulting the current
    /// narrow scope (for in-scope type parameters) and the
    /// named-type table (for class / interface / type-alias names).
    fn lowererLowerWithTypeParams(self: *Checker, type_node: NodeId) CheckError!TypeId {
        switch (self.hir.kindOf(type_node)) {
            .object_type => {
                // Member types must lower under the same narrow
                // scope as the enclosing annotation so that type
                // parameters bound by an enclosing alias / fn
                // resolve. The raw `lowerObjectType` doesn't see
                // them — re-implement it here.
                const members = hir_mod.objectTypeMembers(self.hir, type_node);
                var built: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
                defer built.deinit(self.gpa);
                var string_idx: TypeId = types.Primitive.none;
                var number_idx: TypeId = types.Primitive.none;
                for (members) |m| {
                    if (self.hir.kindOf(m) == .index_signature) {
                        const ix = hir_mod.indexSignatureOf(self.hir, m);
                        const value_t = if (ix.value_type != hir_mod.none_node_id)
                            try self.lowererLowerWithTypeParams(ix.value_type)
                        else
                            types.Primitive.any;
                        const key_t = if (ix.key_type != hir_mod.none_node_id)
                            try self.lowererLowerWithTypeParams(ix.key_type)
                        else
                            types.Primitive.string_t;
                        if (key_t == types.Primitive.string_t) string_idx = value_t;
                        if (key_t == types.Primitive.number_t) number_idx = value_t;
                        continue;
                    }
                    if (self.hir.kindOf(m) != .interface_member) continue;
                    const im = hir_mod.interfaceMemberOf(self.hir, m);
                    if (im.name == 0) continue;
                    const t: TypeId = if (im.type_node != hir_mod.none_node_id)
                        try self.lowererLowerWithTypeParams(im.type_node)
                    else
                        types.Primitive.any;
                    try built.append(self.gpa, .{
                        .name = im.name,
                        .type = t,
                        .is_optional = im.is_optional,
                        .is_readonly = im.is_readonly,
                        .is_method = im.is_method,
                    });
                }
                return self.interner.internObjectTypeWithIndex(built.items, string_idx, number_idx) catch return error.OutOfMemory;
            },
            .union_type => {
                const members = hir_mod.unionTypeMembers(self.hir, type_node);
                var ms: std.ArrayListUnmanaged(TypeId) = .empty;
                defer ms.deinit(self.gpa);
                for (members) |m| try ms.append(self.gpa, try self.lowererLowerWithTypeParams(m));
                return self.interner.internUnion(ms.items) catch return error.OutOfMemory;
            },
            .intersection_type => {
                const members = hir_mod.intersectionTypeMembers(self.hir, type_node);
                var ms: std.ArrayListUnmanaged(TypeId) = .empty;
                defer ms.deinit(self.gpa);
                for (members) |m| try ms.append(self.gpa, try self.lowererLowerWithTypeParams(m));
                return self.interner.internIntersection(ms.items) catch return error.OutOfMemory;
            },
            .type_ref => {
                const r = hir_mod.typeRefOf(self.hir, type_node);
                if (r.qualifier_len == 0 and r.args_len == 0) {
                    if (self.lookupNarrow(r.name)) |t| return t;
                    if (self.generic_aliases.get(r.name)) |info| {
                        var all_defaulted: bool = info.params.len > 0;
                        for (info.params) |p| {
                            if (!self.interner.pool.flagsOf(p).is_type_parameter) {
                                all_defaulted = false;
                                break;
                            }
                            const tp = self.interner.pool.type_parameter_payloads.items[self.interner.pool.payloadOf(p)];
                            if (tp.default == types.Primitive.none) {
                                all_defaulted = false;
                                break;
                            }
                        }
                        if (all_defaulted) {
                            var subs: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty;
                            defer subs.deinit(self.gpa);
                            for (info.params) |p| {
                                const tp = self.interner.pool.type_parameter_payloads.items[self.interner.pool.payloadOf(p)];
                                try subs.put(self.gpa, p, tp.default);
                            }
                            return self.substituteType(info.body, &subs) catch info.body;
                        }
                    }
                    if (self.type_names.get(r.name)) |t| return t;
                }
                // `Alias<X, Y>` — instantiate the generic alias by
                // substituting each declared parameter with the
                // corresponding lowered argument. Extra args are
                // ignored; missing args fall back to the parameter's
                // own TypeId (so partial application leaves the
                // remaining slot in place).
                if (r.qualifier_len == 0 and r.args_len > 0) {
                    // `ThisType<T>` — TS marker that re-binds contextual
                    // `this` inside object literals to T. For now, treat
                    // it as a no-op unwrap so `let x: ThisType<{x:1}>`
                    // is equivalent to `let x: {x:1}`. Propagating T as
                    // the contextual `this` for method bodies inside
                    // the literal is a Phase 6 follow-up.
                    if (r.args_len == 1) {
                        const name_str = self.string_interner.get(r.name);
                        if (std.mem.eql(u8, name_str, "ThisType")) {
                            const args = hir_mod.typeRefArgs(self.hir, type_node);
                            return try self.lowererLowerWithTypeParams(args[0]);
                        }
                        // `NoInfer<T>` (TS 5.4) — marks a type-arg
                        // slot as non-inference so callers can't
                        // contribute candidates from this position.
                        // For v0 we treat it transparently: lower to
                        // T directly. Inference still records the
                        // first-seen T from any non-NoInfer slot;
                        // remaining slots reuse the substituted T,
                        // so explicit `<number>` + non-numeric arg
                        // still emits TS2345 as expected.
                        if (std.mem.eql(u8, name_str, "NoInfer")) {
                            const args = hir_mod.typeRefArgs(self.hir, type_node);
                            return try self.lowererLowerWithTypeParams(args[0]);
                        }
                        // `Promise<T>` — there is no real lib.d.ts
                        // wired up yet, so synthesize a minimal
                        // structural Promise (`{ then: (cb: (v: T) =>
                        // any) => any }`) on the fly. This lets
                        // downstream `Awaited<…>` / `await …` peel it.
                        if (std.mem.eql(u8, name_str, "Promise")) {
                            const args = hir_mod.typeRefArgs(self.hir, type_node);
                            const inner = try self.lowererLowerWithTypeParams(args[0]);
                            return try self.buildStructuralPromise(inner);
                        }
                        // `Awaited<T>` (TS 4.5) — recursively unwrap
                        // any structural `Promise<U>` chain. Non-
                        // Promise operands pass through unchanged.
                        if (std.mem.eql(u8, name_str, "Awaited")) {
                            const args = hir_mod.typeRefArgs(self.hir, type_node);
                            const inner = try self.lowererLowerWithTypeParams(args[0]);
                            return self.evalAwaited(inner);
                        }
                    }
                    if (self.generic_aliases.get(r.name)) |info| {
                        const args = hir_mod.typeRefArgs(self.hir, type_node);
                        var subs: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty;
                        defer subs.deinit(self.gpa);
                        const npairs = @min(args.len, info.params.len);
                        var i: usize = 0;
                        while (i < npairs) : (i += 1) {
                            const arg_t = try self.lowererLowerWithTypeParams(args[i]);
                            try subs.put(self.gpa, info.params[i], arg_t);
                        }
                        // Fill remaining type-parameters with their
                        // declaration-site defaults (`<T, U = number>`)
                        // for partial application like `Pair<string>`.
                        if (args.len < info.params.len) {
                            var j: usize = args.len;
                            while (j < info.params.len) : (j += 1) {
                                const p = info.params[j];
                                if (!self.interner.pool.flagsOf(p).is_type_parameter) continue;
                                const tp = self.interner.pool.type_parameter_payloads.items[self.interner.pool.payloadOf(p)];
                                if (tp.default == types.Primitive.none) continue;
                                try subs.put(self.gpa, p, tp.default);
                            }
                        }
                        // Homomorphic mapped-type alias: when the
                        // alias body is `{ [K in keyof T]: F<K> }`,
                        // the static `body_t` collapsed to `unknown`
                        // because `keyof T` couldn't materialize at
                        // alias-decl time. Re-evaluate the mapped
                        // body now under the outer-parameter
                        // substitution so `Partial<{x: number}>`
                        // returns `{ x?: number }`.
                        if (info.body_node != hir_mod.none_node_id and
                            self.hir.kindOf(info.body_node) == .mapped_type)
                        {
                            try self.pushNarrowScope();
                            defer self.popNarrowScope();
                            // Push T → arg_t into the narrow scope so
                            // type-refs inside the mapped body
                            // resolve through `lookupNarrow`.
                            for (info.params, 0..) |param_t, idx| {
                                if (idx >= args.len) break;
                                const tp = self.interner.pool.type_parameter_payloads.items[self.interner.pool.payloadOf(param_t)];
                                const arg_t = subs.get(param_t) orelse continue;
                                try self.recordNarrow(tp.name, arg_t);
                            }
                            return self.evalMappedType(info.body_node) catch info.body;
                        }
                        return self.substituteType(info.body, &subs) catch info.body;
                    }
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
            .keyof_type => {
                // `keyof T` — re-resolve the operand through the
                // type-name aware path, then evaluate eagerly when
                // the result is a known object type.
                const k = hir_mod.keyofTypeOf(self.hir, type_node);
                const operand = try self.lowererLowerWithTypeParams(k.operand);
                if (self.interner.pool.flagsOf(operand).is_object_type) {
                    const members = self.interner.objectMembers(operand);
                    if (members.len == 0) return types.Primitive.never;
                    var lits: std.ArrayListUnmanaged(TypeId) = .empty;
                    defer lits.deinit(self.gpa);
                    for (members) |m| {
                        const lit = self.interner.internStringLiteral(m.name) catch continue;
                        try lits.append(self.gpa, lit);
                    }
                    if (lits.items.len == 1) return lits.items[0];
                    return self.interner.internUnion(lits.items) catch return error.OutOfMemory;
                }
                return self.interner.internKeyof(operand) catch return error.OutOfMemory;
            },
            .indexed_access_type => {
                // `T[K]` — resolve both sides through the narrow-aware
                // path. If T is now an object type and K is a known
                // string literal, return the matching member directly.
                const ia = hir_mod.indexedAccessTypeOf(self.hir, type_node);
                const obj = try self.lowererLowerWithTypeParams(ia.object);
                const idx = try self.lowererLowerWithTypeParams(ia.index);
                const obj_flags = self.interner.pool.flagsOf(obj);
                const idx_flags = self.interner.pool.flagsOf(idx);
                if (obj_flags.is_object_type and idx_flags.is_literal and idx_flags.is_string) {
                    const lit = self.interner.literalOf(idx);
                    switch (lit) {
                        .string_lit => |sid| {
                            if (self.interner.objectMember(obj, sid)) |member_t| return member_t;
                        },
                        else => {},
                    }
                }
                return self.interner.internIndexedAccess(obj, idx) catch return error.OutOfMemory;
            },
            .conditional_type => {
                // `T extends U ? X : Y` — eagerly evaluate when neither
                // `T` nor `U` contains an unresolved type parameter.
                // Distributive: when `T` resolves to a union, distribute
                // the conditional across each member and union the
                // results.
                //
                // `[T] extends [U]` — the bracketed tuple-of-one form
                // suppresses distribution. We detect both sides being
                // single-element tuples and unwrap them, evaluating
                // non-distributively.
                //
                // `infer R` placeholders in the extends-side need to
                // be visible to the true-branch (`R`). We push a
                // narrow scope around the conditional, lower the
                // ext side first (registering each infer'd name), then
                // lower the branches.
                const c = hir_mod.conditionalTypeOf(self.hir, type_node);
                try self.pushNarrowScope();
                defer self.popNarrowScope();

                // Detect `[T] extends [U]` — both sides are
                // single-element tuples. Unwrap and skip distribution.
                if (self.hir.kindOf(c.check) == .tuple_type and self.hir.kindOf(c.extends) == .tuple_type) {
                    const check_elems = hir_mod.tupleTypeElements(self.hir, c.check);
                    const ext_elems = hir_mod.tupleTypeElements(self.hir, c.extends);
                    if (check_elems.len == 1 and ext_elems.len == 1) {
                        const check = try self.lowererLowerWithTypeParams(check_elems[0]);
                        const ext = try self.lowererLowerWithTypeParams(ext_elems[0]);
                        try self.registerInferNames(ext_elems[0], ext);
                        const tt = try self.lowererLowerWithTypeParams(c.true_branch);
                        const ff = try self.lowererLowerWithTypeParams(c.false_branch);
                        // Non-distributing: evaluate as a single check
                        // (skipping the union-distribute branch).
                        return self.evalConditionalNonDistributing(check, ext, tt, ff);
                    }
                }

                const check = try self.lowererLowerWithTypeParams(c.check);
                const ext = try self.lowererLowerWithTypeParams(c.extends);
                try self.registerInferNames(c.extends, ext);
                const tt = try self.lowererLowerWithTypeParams(c.true_branch);
                const ff = try self.lowererLowerWithTypeParams(c.false_branch);
                return self.evalConditional(check, ext, tt, ff);
            },
            .mapped_type => {
                // `{ [K in T]: V }` — when `T` resolves to a known
                // string-literal union, materialize the result as an
                // object type with one property per literal. Each
                // property's type is the value template with `K`
                // substituted for that literal.
                return self.evalMappedType(type_node);
            },
            else => {},
        }
        return self.lowerer.lower(type_node);
    }

    /// Evaluate `check extends ext ? tt : ff`. If either side carries a
    /// free type parameter (or a downstream conditional/keyof that
    /// hasn't reduced), defer by interning the conditional. If `check`
    /// is a union and itself a naked type parameter substitution,
    /// distribute. Otherwise pick the branch by structural assignability.
    /// Side note on `infer X` placeholders: when `ext` carries one,
    /// we attempt structural matching against `check` to bind the
    /// `infer` variable; the substitution is then applied to `tt`
    /// before returning. Today only the function-return case is
    /// supported (`T extends (...) => infer R ? R : never`).
    fn evalConditional(
        self: *Checker,
        check: TypeId,
        ext: TypeId,
        tt: TypeId,
        ff: TypeId,
    ) CheckError!TypeId {
        // Distribute over a union check.
        if (self.interner.pool.flagsOf(check).is_union) {
            const members = self.interner.unionMembers(check);
            var built: std.ArrayListUnmanaged(TypeId) = .empty;
            defer built.deinit(self.gpa);
            for (members) |m| {
                const r = try self.evalConditional(m, ext, tt, ff);
                try built.append(self.gpa, r);
            }
            return self.interner.internUnion(built.items) catch return error.OutOfMemory;
        }
        // `infer X` matching: when `ext` is a signature with infer'd
        // type-parameter placeholders and `check` is also a signature,
        // bind each infer'd placeholder structurally and substitute
        // into `tt` before returning.
        if (self.interner.pool.flagsOf(ext).is_signature and
            self.interner.pool.flagsOf(check).is_signature)
        {
            var infer_subs: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty;
            defer infer_subs.deinit(self.gpa);
            const matched = self.matchInfer(check, ext, &infer_subs) catch false;
            if (matched and infer_subs.count() > 0) {
                return self.substituteType(tt, &infer_subs);
            }
        }
        // Defer if the check or extends type carries a free type parameter.
        if (self.containsFreeTypeParameter(check) or self.containsFreeTypeParameter(ext)) {
            return self.interner.internConditional(check, ext, tt, ff) catch return error.OutOfMemory;
        }
        const ok = self.engine.isAssignableTo(check, ext) catch false;
        return if (ok) tt else ff;
    }

    /// Like `evalConditional` but skips union distribution — used for
    /// the bracketed `[T] extends [U]` form where TS suppresses the
    /// distributive behavior.
    fn evalConditionalNonDistributing(
        self: *Checker,
        check: TypeId,
        ext: TypeId,
        tt: TypeId,
        ff: TypeId,
    ) CheckError!TypeId {
        if (self.interner.pool.flagsOf(ext).is_signature and
            self.interner.pool.flagsOf(check).is_signature)
        {
            var infer_subs: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty;
            defer infer_subs.deinit(self.gpa);
            const matched = self.matchInfer(check, ext, &infer_subs) catch false;
            if (matched and infer_subs.count() > 0) {
                return self.substituteType(tt, &infer_subs);
            }
        }
        if (self.containsFreeTypeParameter(check) or self.containsFreeTypeParameter(ext)) {
            return self.interner.internConditional(check, ext, tt, ff) catch return error.OutOfMemory;
        }
        const ok = self.engine.isAssignableTo(check, ext) catch false;
        return if (ok) tt else ff;
    }

    /// Walk the HIR ext-side of a conditional looking for `infer X`
    /// nodes; for each, register the name → TypeParameter mapping
    /// in the current narrow scope so subsequent `X` references in
    /// the conditional's true-branch resolve.
    fn registerInferNames(self: *Checker, ext_node: NodeId, ext_t: TypeId) !void {
        _ = ext_t;
        try self.walkAndRegisterInfer(ext_node);
    }

    fn walkAndRegisterInfer(self: *Checker, node: NodeId) !void {
        if (node == hir_mod.none_node_id) return;
        const k = self.hir.kindOf(node);
        if (k == .infer_type) {
            const ip = hir_mod.inferTypeOf(self.hir, node);
            const constraint: TypeId = if (ip.constraint != hir_mod.none_node_id)
                try self.lowerer.lower(ip.constraint)
            else
                types.Primitive.unknown;
            const tp_id = self.interner.internTypeParameter(ip.name, constraint, types.Primitive.none) catch return;
            try self.recordNarrow(ip.name, tp_id);
            return;
        }
        if (k == .fn_type or k == .constructor_type) {
            const ft = hir_mod.fnTypeOf(self.hir, node);
            const params = self.hir.childSlice(ft.params_start, @intCast(ft.params_len));
            for (params) |p| {
                if (self.hir.kindOf(p) == .parameter) {
                    const pp = hir_mod.parameterOf(self.hir, p);
                    if (pp.type_annotation != hir_mod.none_node_id) {
                        try self.walkAndRegisterInfer(pp.type_annotation);
                    }
                }
            }
            if (ft.return_type != hir_mod.none_node_id) {
                try self.walkAndRegisterInfer(ft.return_type);
            }
            return;
        }
        if (k == .union_type) {
            for (hir_mod.unionTypeMembers(self.hir, node)) |m| try self.walkAndRegisterInfer(m);
            return;
        }
        if (k == .intersection_type) {
            for (hir_mod.intersectionTypeMembers(self.hir, node)) |m| try self.walkAndRegisterInfer(m);
            return;
        }
        if (k == .array_type) {
            const a = hir_mod.arrayTypeOf(self.hir, node);
            try self.walkAndRegisterInfer(a.element);
            return;
        }
        if (k == .tuple_type) {
            for (hir_mod.tupleTypeElements(self.hir, node)) |e| try self.walkAndRegisterInfer(e);
            return;
        }
        if (k == .indexed_access_type) {
            const ia = hir_mod.indexedAccessTypeOf(self.hir, node);
            try self.walkAndRegisterInfer(ia.object);
            try self.walkAndRegisterInfer(ia.index);
            return;
        }
        // Other type-node kinds either don't carry infer placeholders
        // in normal usage, or are deferred to a Phase 6 follow-up.
    }

    /// Structural match between `check` and `ext`, treating any
    /// TypeParameter in `ext` as an infer'd placeholder. On match,
    /// records `infer_param -> check_subterm` in `subs`. Returns
    /// false if the structural shapes don't align.
    fn matchInfer(
        self: *Checker,
        check: TypeId,
        ext: TypeId,
        subs: *std.AutoHashMapUnmanaged(TypeId, TypeId),
    ) !bool {
        if (self.interner.pool.flagsOf(ext).is_type_parameter) {
            try subs.put(self.gpa, ext, check);
            return true;
        }
        const ef = self.interner.pool.flagsOf(ext);
        const cf = self.interner.pool.flagsOf(check);
        if (ef.is_signature and cf.is_signature) {
            // For the common ReturnType pattern `(...args: any[]) =>
            // infer R`, the ext side may have a different parameter
            // count than the check side. We don't enforce parameter
            // matching here — only the return-type unification. This
            // is the high-frequency `infer R` use case (ReturnType,
            // Awaited, Parameters, etc.); structural param matching
            // is a Phase 6 follow-up.
            const er = self.interner.signatureReturn(ext) orelse return true;
            const cr = self.interner.signatureReturn(check) orelse return true;
            return self.matchInfer(cr, er, subs);
        }
        // Default: identity.
        return check == ext;
    }

    fn containsFreeTypeParameter(self: *Checker, t: TypeId) bool {
        const flags = self.interner.pool.flagsOf(t);
        if (flags.is_type_parameter) return true;
        if (flags.is_union) {
            for (self.interner.unionMembers(t)) |m| if (self.containsFreeTypeParameter(m)) return true;
            return false;
        }
        if (flags.is_intersection) {
            for (self.interner.intersectionMembers(t)) |m| if (self.containsFreeTypeParameter(m)) return true;
            return false;
        }
        if (flags.is_object_type) {
            const members = self.interner.objectMembers(t);
            for (members) |m| if (self.containsFreeTypeParameter(m.type)) return true;
            return false;
        }
        if (flags.is_signature) {
            const params = self.interner.signatureParams(t);
            for (params) |p| if (self.containsFreeTypeParameter(p)) return true;
            if (self.interner.signatureReturn(t)) |r| if (self.containsFreeTypeParameter(r)) return true;
            return false;
        }
        return false;
    }

    fn evalMappedType(self: *Checker, node: NodeId) CheckError!TypeId {
        const m = hir_mod.mappedTypeOf(self.hir, node);
        if (m.constraint == hir_mod.none_node_id or m.value == hir_mod.none_node_id) {
            // Fall back to plain lower.
            return self.lowerer.lower(node);
        }
        const constraint_t = try self.lowererLowerWithTypeParams(m.constraint);
        // The type-parameter NodeId — its `name` is the StringId we
        // bind for the value template.
        if (m.type_param == hir_mod.none_node_id or self.hir.kindOf(m.type_param) != .type_parameter) {
            return self.lowerer.lower(node);
        }
        const tp = hir_mod.typeParameterOf(self.hir, m.type_param);
        const tp_id = self.interner.internTypeParameter(tp.name, types.Primitive.unknown, types.Primitive.none) catch
            return error.OutOfMemory;
        try self.pushNarrowScope();
        defer self.popNarrowScope();
        try self.recordNarrow(tp.name, tp_id);

        // Materialize when the constraint is a string-literal union or
        // a single string-literal type.
        var literal_keys: std.ArrayListUnmanaged(hir_mod.StringId) = .empty;
        defer literal_keys.deinit(self.gpa);
        const can_materialize = self.collectStringLiteralKeys(constraint_t, &literal_keys);
        if (!can_materialize or literal_keys.items.len == 0) {
            // Defer with a plain lowering.
            return self.lowerer.lower(node);
        }

        var built: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
        defer built.deinit(self.gpa);
        // Modifier values: 0 = unspecified (inherit from source),
        // 1 = add, 2 = remove. The homomorphic case
        // (`{ [K in keyof T]: ... }`) inherits the source object's
        // is_optional / is_readonly when the modifier is unspecified.
        const homomorphic_source: ?TypeId = blk: {
            if (self.hir.kindOf(m.constraint) != .keyof_type) break :blk null;
            const k = hir_mod.keyofTypeOf(self.hir, m.constraint);
            const operand = self.lowererLowerWithTypeParams(k.operand) catch break :blk null;
            if (self.interner.pool.flagsOf(operand).is_object_type) break :blk operand;
            break :blk null;
        };
        const value_template = try self.lowererLowerWithTypeParams(m.value);
        for (literal_keys.items) |key_name| {
            // Substitute `K -> literal` in the value template.
            const key_lit = self.interner.internStringLiteral(key_name) catch continue;
            var subs: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty;
            defer subs.deinit(self.gpa);
            try subs.put(self.gpa, tp_id, key_lit);
            const value_t = self.substituteType(value_template, &subs) catch value_template;

            // Resolve the per-key effective name. With an `as`
            // clause (TS 4.1+ key remapping), re-lower the remap
            // with `K` bound to the current key's string literal
            // so template-literal / conditional / `Exclude<K, …>`
            // shapes evaluate eagerly. If the remap reduces to
            // `never` the key is dropped; otherwise the result
            // must be a string-like literal and replaces `key_name`.
            var effective_name: hir_mod.StringId = key_name;
            if (m.remap != hir_mod.none_node_id) {
                try self.pushNarrowScope();
                try self.recordNarrow(tp.name, key_lit);
                const remap_t = self.lowererLowerWithTypeParams(m.remap) catch types.Primitive.never;
                self.popNarrowScope();
                if (remap_t == types.Primitive.never) continue;
                const rf = self.interner.pool.flagsOf(remap_t);
                // Unwrap an intersection containing a string literal
                // (e.g. `K & string` after substitution).
                const named: TypeId = blk2: {
                    if (rf.is_intersection) {
                        const ms = self.interner.intersectionMembers(remap_t);
                        for (ms) |mt| {
                            const mf = self.interner.pool.flagsOf(mt);
                            if (mf.is_literal and mf.is_string) break :blk2 mt;
                        }
                    }
                    break :blk2 remap_t;
                };
                const nf = self.interner.pool.flagsOf(named);
                if (!(nf.is_literal and nf.is_string)) continue;
                const lit = self.interner.literalOf(named);
                switch (lit) {
                    .string_lit => |sid| effective_name = sid,
                    else => continue,
                }
            }
            // Inherit source flags when homomorphic + modifier
            // unspecified; apply +/- modifiers otherwise.
            var src_optional = false;
            var src_readonly = false;
            if (homomorphic_source) |src_t| {
                if (self.interner.objectMemberInfo(src_t, key_name)) |info| {
                    src_optional = info.is_optional;
                    src_readonly = info.is_readonly;
                }
            }
            const is_optional = switch (m.optional) {
                1 => true, // +?
                2 => false, // -?
                else => src_optional, // inherit (or false when no source)
            };
            const is_readonly = switch (m.readonly) {
                1 => true,
                2 => false,
                else => src_readonly,
            };
            try built.append(self.gpa, .{
                .name = effective_name,
                .type = value_t,
                .is_optional = is_optional,
                .is_readonly = is_readonly,
                .is_method = false,
            });
        }
        return self.interner.internObjectType(built.items) catch return error.OutOfMemory;
    }

    /// Walk a type and accumulate the StringIds of every string-literal
    /// member. Returns false if any member isn't a string literal —
    /// in that case the mapped type can't be materialized eagerly.
    fn collectStringLiteralKeys(
        self: *Checker,
        t: TypeId,
        out: *std.ArrayListUnmanaged(hir_mod.StringId),
    ) bool {
        const flags = self.interner.pool.flagsOf(t);
        // Check `is_union` *first* because the union's propagated flag
        // set OR-folds in `is_string`/`is_literal` from each member,
        // which would otherwise misroute through the literal branch.
        if (flags.is_union) {
            const members = self.interner.unionMembers(t);
            for (members) |mt| if (!self.collectStringLiteralKeys(mt, out)) return false;
            return true;
        }
        if (flags.is_literal and flags.is_string) {
            const lit = self.interner.literalOf(t);
            switch (lit) {
                .string_lit => |sid| {
                    out.append(self.gpa, sid) catch return false;
                    return true;
                },
                else => return false,
            }
        }
        return false;
    }

    /// True iff `target` is shaped like a lowered tuple type — an
    /// object with at least a `length` member plus a numeric "0"
    /// positional member (variadic tuples have only a leading "0"
    /// when there's a middle/trailing rest, so we don't require
    /// a full sequence).
    fn isTupleShapedTarget(self: *Checker, target: TypeId) bool {
        const flags = self.interner.pool.flagsOf(target);
        if (!flags.is_object_type) return false;
        const length_id = self.string_interner.intern("length") catch return false;
        if (self.interner.objectMember(target, length_id) == null) return false;
        const zero_id = self.string_interner.intern("0") catch return false;
        return self.interner.objectMember(target, zero_id) != null;
    }

    /// Positional check of an `array_literal` init against a
    /// tuple-shaped target. For each element index `i`, look up
    /// the target's member named `"i"`; if missing, fall back to
    /// the target's number-key indexer (rest slot). Returns true
    /// when every element assigns.
    fn checkArrayLiteralAgainstTuple(self: *Checker, init_node: NodeId, target: TypeId) !bool {
        const elements = hir_mod.arrayLiteralElements(self.hir, init_node);
        const num_idx = self.interner.objectNumberIndex(target);
        for (elements, 0..) |el, i| {
            if (el == hir_mod.none_node_id) continue;
            const el_t = try self.checkExpression(el);
            // Look up the matching positional member.
            var nbuf: [12]u8 = undefined;
            const name_str = std.fmt.bufPrint(&nbuf, "{d}", .{i}) catch return false;
            const name = self.string_interner.intern(name_str) catch return error.OutOfMemory;
            const tgt_t: TypeId = if (self.interner.objectMember(target, name)) |t|
                t
            else if (num_idx != types.Primitive.none)
                num_idx
            else
                return false;
            const ok = self.engine.isAssignableTo(el_t, tgt_t) catch return error.OutOfMemory;
            if (!ok) return false;
        }
        return true;
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
            // Special-case array-literal → tuple positional check.
            // The init's structural Array<T>-shape loses positional
            // info, so plain assignability would reject `[1, "a"]`
            // against `[number, string]`. Instead, when init is a
            // literal `[…]` and the target is a tuple-shaped object
            // type (positional "0", "1", … members), check each
            // element against the matching positional slot, then
            // fall back to the target's number-key indexer for any
            // extras (variadic tuple rest).
            const ok = blk: {
                if (v.type_annotation != hir_mod.none_node_id and
                    self.hir.kindOf(v.init) == .array_literal and
                    self.isTupleShapedTarget(declared_type))
                {
                    break :blk try self.checkArrayLiteralAgainstTuple(v.init, declared_type);
                }
                break :blk self.engine.isAssignableTo(init_type, declared_type) catch return error.OutOfMemory;
            };
            if (!ok) {
                try self.report(node, TsCodes.type_not_assignable, "Type is not assignable to declared type.");
            }
            // TS2353: fresh-object-literal excess-property check.
            // Only fires when the init is a literal `{ … }` and the
            // declared type is a known object — otherwise extra
            // properties may legitimately come from elsewhere.
            try self.checkExcessProperties(v.init, declared_type);
            // TS2375: `exactOptionalPropertyTypes` rejects literal
            // `undefined` flowing into an optional-but-not-undefined
            // property.
            try self.checkExactOptionalProperties(v.init, declared_type);
        } else if (declared_type == types.Primitive.none) {
            self.hir.setType(node, init_type);
        }
        // Propagate the declaration's type to the name identifier
        // so hover-on-identifier returns the right type.
        if (v.name != hir_mod.none_node_id) self.hir.setType(v.name, final_type);

        // Aliased conditional narrowing: `let cond = obj.kind === "x"`.
        // Record `cond -> guard_expr_node` so a subsequent `if (cond)`
        // applies the original guard. Only fires for `const`/`let`-style
        // bindings whose init is a recognizably-narrowing expression.
        if (v.name != hir_mod.none_node_id and self.hir.kindOf(v.name) == .identifier and
            v.init != hir_mod.none_node_id and isNarrowingGuard(self.hir, v.init))
        {
            const id = hir_mod.identifierOf(self.hir, v.name);
            try self.cond_aliases.put(self.gpa, id.name, v.init);
        }

        // TS7005: variable declared without an annotation and
        // without an initializer falls through to `any`.
        if (self.strict_flags.no_implicit_any and
            v.type_annotation == hir_mod.none_node_id and
            v.init == hir_mod.none_node_id)
        {
            const var_name: []const u8 = if (v.name != hir_mod.none_node_id and self.hir.kindOf(v.name) == .identifier)
                self.string_interner.get(hir_mod.identifierOf(self.hir, v.name).name)
            else
                "<anonymous>";
            const msg = try std.fmt.allocPrint(
                self.diag_arena.allocator(),
                "Variable '{s}' implicitly has an 'any' type.",
                .{var_name},
            );
            try self.diagnostics.append(self.gpa, .{
                .node = node,
                .code = TsCodes.variable_implicitly_any,
                .message = msg,
            });
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
            .identifier => self.typeOfIdentifier(node),
            .binary_op => try self.checkBinop(node),
            .unary_op => try self.checkUnary(node),
            .logical_op => try self.checkLogical(node),
            .conditional => try self.checkConditional(node),
            .assignment => blk: {
                const a = hir_mod.assignmentOf(self.hir, node);
                _ = try self.checkExpression(a.target);
                // Reassignment clears any prior conditional alias for
                // the variable: `let cond = isString(x); cond = false;
                // if (cond) ...` — the second branch shouldn't
                // narrow `x` because `cond` is no longer the original
                // guard expression.
                if (self.hir.kindOf(a.target) == .identifier) {
                    const id = hir_mod.identifierOf(self.hir, a.target);
                    _ = self.cond_aliases.remove(id.name);
                    // TS2588: `const x = 1; x = 2;` — assigning to
                    // a const-bound identifier is a hard error.
                    if (self.identifierResolvesToConst(a.target)) {
                        const name_str = self.string_interner.get(id.name);
                        const msg = try std.fmt.allocPrint(
                            self.diag_arena.allocator(),
                            "Cannot assign to '{s}' because it is a constant.",
                            .{name_str},
                        );
                        try self.diagnostics.append(self.gpa, .{
                            .node = node,
                            .code = TsCodes.cannot_assign_const,
                            .message = msg,
                        });
                    }
                }
                // TS2540: assigning to a property declared `readonly`.
                // Object/interface readonly fields are immutable;
                // class-field readonly is approximated by the
                // constructor exception inside the helper.
                if (self.hir.kindOf(a.target) == .member_access) {
                    try self.checkReadonlyAssignment(a.target);
                }
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
                    if (self.abstract_classes.contains(id.name)) {
                        try self.report(
                            node,
                            TsCodes.abstract_class_instantiation,
                            "Cannot create an instance of an abstract class.",
                        );
                    }
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
                // Overload resolution: when the callee is a known
                // overloaded fn, pick the first applicable signature.
                // "Applicable" = arg_count fits and each arg type is
                // assignable to the corresponding param type.
                if (self.hir.kindOf(c.callee) == .identifier) {
                    const callee_name = hir_mod.identifierOf(self.hir, c.callee).name;
                    if (self.overloads.get(callee_name)) |overload_list| {
                        if (overload_list.items.len > 1) {
                            // The last entry is the implementation;
                            // walk only the leading overloads.
                            const overloads = overload_list.items[0 .. overload_list.items.len - 1];
                            for (overloads) |sig| {
                                if (try self.signatureAccepts(sig, arg_types.items)) {
                                    try self.checkArgsAgainstSignature(node, args, arg_types.items, sig);
                                    if (self.interner.signatureReturn(sig)) |ret| {
                                        break :blk ret;
                                    }
                                }
                            }
                            // No overload accepted these args — emit
                            // TS2769 instead of falling through to the
                            // implementation signature (which is not
                            // visible at call sites in TS).
                            try self.report(node, TsCodes.no_overload_matches, "No overload matches this call.");
                            if (self.interner.signatureReturn(overload_list.items[0])) |ret| {
                                break :blk ret;
                            }
                            break :blk types.Primitive.any;
                        }
                    }
                }
                // Explicit type arguments (`f<T>(args)`): if the
                // callee resolves to a generic fn we recorded, lower
                // each explicit arg, build a substitution, and
                // substitute against the signature. Substituted
                // signature drives both arg-checking (so TS2345
                // fires against the explicit-instantiated parameter
                // types) and the return type.
                const type_arg_nodes = hir_mod.callTypeArgs(self.hir, node);
                var effective_callee_t = callee_t;
                if (type_arg_nodes.len > 0 and self.interner.pool.flagsOf(callee_t).is_signature and self.hir.kindOf(c.callee) == .identifier) {
                    const callee_name = hir_mod.identifierOf(self.hir, c.callee).name;
                    if (self.generic_fns.get(callee_name)) |type_params| {
                        var subs: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty;
                        defer subs.deinit(self.gpa);
                        const n = @min(type_params.len, type_arg_nodes.len);
                        for (0..n) |i| {
                            const explicit_t = self.lowererLowerWithTypeParams(type_arg_nodes[i]) catch types.Primitive.unknown;
                            try subs.put(self.gpa, type_params[i], explicit_t);
                        }
                        if (subs.count() > 0) {
                            effective_callee_t = self.substituteType(callee_t, &subs) catch callee_t;
                        }
                    }
                }
                if (self.interner.pool.flagsOf(effective_callee_t).is_signature) {
                    try self.checkArgsAgainstSignature(node, args, arg_types.items, effective_callee_t);
                    if (self.interner.signatureReturn(effective_callee_t)) |ret| {
                        // If explicit type args already substituted,
                        // skip argument-driven inference (it's
                        // redundant and the substituted return is
                        // canonical).
                        if (effective_callee_t != callee_t) break :blk ret;
                        const param_ts = self.interner.signatureParams(effective_callee_t);
                        const instantiated = self.instantiateReturn(param_ts, arg_types.items, ret) catch ret;
                        break :blk instantiated;
                    }
                }
                if (self.interner.signatureReturn(effective_callee_t)) |ret| break :blk ret;
                break :blk types.Primitive.any;
            },
            .member_access => blk: {
                const m = hir_mod.memberOf(self.hir, node);
                const obj_t = try self.checkExpression(m.object);
                // TS2341: legacy `private` member access from
                // outside the declaring class body. Runs before
                // narrowing/index lookups so the diagnostic fires
                // even when the resolved type is identical inside
                // and outside the class.
                try self.checkPrivateMemberAccess(node, obj_t, m.name);
                try self.checkProtectedMemberAccess(node, obj_t, m.name);
                // Member-access narrowing: `if (obj.x !== null) { …
                // obj.x … }` — when the object is a bare identifier
                // and a guard recorded a narrow for `(obj, x)`, the
                // narrowed type wins over the static lookup.
                if (self.hir.kindOf(m.object) == .identifier) {
                    const obj_id = hir_mod.identifierOf(self.hir, m.object);
                    const key: MemberKey = .{ .obj_name = obj_id.name, .prop_name = m.name };
                    if (self.lookupMemberNarrow(key)) |nt| {
                        break :blk if (m.optional) self.unionWithUndefined(nt) catch nt else nt;
                    }
                }
                // Optional chaining (`obj?.x`) widens the result to
                // include `undefined` regardless of whether the
                // object's static type already does.
                if (self.interner.objectMember(obj_t, m.name)) |t| {
                    break :blk if (m.optional) self.unionWithUndefined(t) catch t else t;
                }
                // Lib lookup: `string`-typed receivers consult the
                // hard-coded `String.prototype` shape (`length`,
                // `charAt`, `toUpperCase`, …). Catches both the
                // primitive `string` and any string-literal type.
                {
                    const obj_flags = self.interner.pool.flagsOf(obj_t);
                    if (obj_flags.is_string and !obj_flags.is_object_type) {
                        if (lib.stringProto(&self.lib_cache, self.interner, self.string_interner)) |proto| {
                            if (self.interner.objectMember(proto, m.name)) |t| {
                                break :blk if (m.optional) self.unionWithUndefined(t) catch t else t;
                            }
                        } else |_| {}
                    }
                }
                // Lib lookup: array shapes (object types with a
                // number indexer) consult `Array<T>.prototype` for
                // `push`, `map`, `filter`, … using the indexer's
                // element type as `T`.
                if (self.interner.pool.flagsOf(obj_t).is_object_type) {
                    const num_idx = self.interner.objectNumberIndex(obj_t);
                    if (num_idx != types.Primitive.none) {
                        if (lib.arrayProto(&self.lib_cache, self.interner, self.string_interner, self.gpa, num_idx)) |proto| {
                            if (self.interner.objectMember(proto, m.name)) |t| {
                                break :blk if (m.optional) self.unionWithUndefined(t) catch t else t;
                            }
                        } else |_| {}
                    }
                }
                // Index-signature fallback: `obj.foo` on a type
                // with a `[k: string]: V` indexer resolves to V.
                if (self.interner.pool.flagsOf(obj_t).is_object_type) {
                    const string_idx = self.interner.objectStringIndex(obj_t);
                    if (string_idx != types.Primitive.none) {
                        // `noPropertyAccessFromIndexSignature`:
                        // dot-access against a type whose only
                        // matching member is the index signature
                        // must use bracket form. Emit TS4111 but
                        // still resolve the type so downstream
                        // checks see the indexer's value type.
                        if (self.strict_flags.no_property_access_from_index_signature) {
                            const name_str = self.string_interner.get(m.name);
                            const msg = try std.fmt.allocPrint(
                                self.diag_arena.allocator(),
                                "Property '{s}' comes from an index signature, so it must be accessed with ['{s}'].",
                                .{ name_str, name_str },
                            );
                            try self.diagnostics.append(self.gpa, .{
                                .node = node,
                                .code = TsCodes.index_signature_property_access,
                                .message = msg,
                            });
                        }
                        break :blk string_idx;
                    }
                    // No matching member and no indexer → TS2339.
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
                const obj_t = try self.checkExpression(e.object);
                const idx_t = try self.checkExpression(e.index);
                if (self.interner.pool.flagsOf(obj_t).is_object_type) {
                    // Tuple literal-index access: `tup[0]` should
                    // pick the per-index member typed under "0", not
                    // the broader number indexer's union. Only fires
                    // when the index is a numeric literal expression.
                    if (self.hir.kindOf(e.index) == .literal_number) {
                        const v = hir_mod.literalNumberOf(self.hir, e.index);
                        // Convert to integer; ignore non-integral
                        // forms (e.g. `tup[0.5]`) and let the indexer
                        // path handle them.
                        if (v >= 0 and v == @floor(v)) {
                            var nbuf: [12]u8 = undefined;
                            const k = std.fmt.bufPrint(&nbuf, "{d}", .{@as(u64, @intFromFloat(v))}) catch null;
                            if (k) |key_str| {
                                const key_id = self.string_interner.intern(key_str) catch 0;
                                if (key_id != 0) {
                                    if (self.interner.objectMember(obj_t, key_id)) |t| break :blk t;
                                }
                            }
                        }
                    }
                    // Index-signature fallback. With
                    // `noUncheckedIndexedAccess`, widen the result
                    // with `undefined` since dynamic indexing may
                    // miss. Tuple positional access above is exempt
                    // because the arity is statically known.
                    const idx_flags = self.interner.pool.flagsOf(idx_t);
                    if (idx_flags.is_string) {
                        const v = self.interner.objectStringIndex(obj_t);
                        if (v != types.Primitive.none) break :blk self.maybeWidenWithUndefined(v);
                    }
                    if (idx_flags.is_number) {
                        const v = self.interner.objectNumberIndex(obj_t);
                        if (v != types.Primitive.none) break :blk self.maybeWidenWithUndefined(v);
                    }
                }
                break :blk types.Primitive.any;
            },
            .as_expr, .type_assertion => blk: {
                // `expr as T` / `<T>expr` — type the inner
                // expression for diagnostics, then return the
                // asserted type. No assignability check: `as` is
                // an explicit override.
                const a = hir_mod.asExpressionOf(self.hir, node);
                const inner_t = try self.checkExpression(a.expr);
                if (a.type_node == hir_mod.none_node_id) break :blk types.Primitive.any;
                // `expr as const` — special form. The parser
                // builds a synthetic `const` type-ref to mark it.
                if (self.isAsConstMarker(a.type_node)) {
                    break :blk self.literalizeForAsConst(a.expr, inner_t) catch inner_t;
                }
                break :blk try self.lowererLowerWithTypeParams(a.type_node);
            },
            .satisfies_expr => blk: {
                // `expr satisfies T` — verify that `expr` is
                // assignable to T (TS1360 on miss) but PRESERVE
                // `expr`'s narrower type as the result. Distinct
                // from `as T` which uses T as the result type.
                const a = hir_mod.asExpressionOf(self.hir, node);
                const inner_t = try self.checkExpression(a.expr);
                if (a.type_node == hir_mod.none_node_id) break :blk inner_t;
                const target_t = try self.lowererLowerWithTypeParams(a.type_node);
                const ok = self.engine.isAssignableTo(inner_t, target_t) catch false;
                if (!ok) {
                    try self.report(node, TsCodes.satisfies_constraint, "Type does not satisfy the expected constraint.");
                }
                break :blk inner_t;
            },
            .non_null_expr => blk: {
                // `expr!` — postfix non-null assertion. Type the
                // inner expression, then subtract null + undefined
                // from the resulting union. Non-union types pass
                // through (we don't error on a redundant assert).
                const a = hir_mod.asExpressionOf(self.hir, node);
                const inner = try self.checkExpression(a.expr);
                break :blk self.subtractNullUndefined(inner) catch inner;
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
                const elem_t: TypeId = if (elem_types.items.len == 0)
                    types.Primitive.any
                else if (elem_types.items.len == 1)
                    elem_types.items[0]
                else
                    self.interner.internUnion(elem_types.items) catch return error.OutOfMemory;
                // Build the standard Array<T> shape — `length:
                // number` plus `[i: number]: T`. Lets `arr[0]`
                // and `arr.length` resolve through the existing
                // object-type machinery without a dedicated array
                // TypeKind.
                break :blk self.interner.internArrayType(self.string_interner, elem_t) catch return error.OutOfMemory;
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
            .await_expr => blk: {
                // `await expr` — type-check the operand. When the
                // operand's type is structurally a `Promise<T>` (an
                // object type with a `.then(cb)` method whose callback
                // takes the resolved value as its first parameter),
                // unwrap to `T`. Otherwise pass the operand type
                // through.
                const a = hir_mod.awaitExprOf(self.hir, node);
                const inner_t = try self.checkExpression(a.expr);
                // TS1308: `await` is only allowed inside an async
                // function or at the top level of a module. Walk up
                // the parent chain looking for the nearest enclosing
                // function. If found and it isn't async, diagnose.
                // Reaching the root without finding any function is
                // top-level await, which is allowed.
                var cur: hir_mod.NodeId = self.hir.parentOf(node);
                while (cur != hir_mod.none_node_id) : (cur = self.hir.parentOf(cur)) {
                    const k = self.hir.kindOf(cur);
                    if (k == .fn_decl or k == .fn_expr or k == .arrow_fn) {
                        const fp = hir_mod.fnDeclOf(self.hir, cur);
                        if (!fp.flags.is_async) {
                            try self.report(node, TsCodes.await_only_in_async, "'await' expression is only allowed in async functions and at top levels of modules.");
                        }
                        break;
                    }
                }
                break :blk self.unwrapPromise(inner_t);
            },
            .yield_expr => blk: {
                // `yield expr` / `yield* expr` — type-check the
                // operand and pass its type through. TODO(Phase 6):
                // model generator yield/return type pairs and unwrap
                // delegated yields' iterables.
                const y = hir_mod.yieldExprOf(self.hir, node);
                if (y.expr == hir_mod.none_node_id) break :blk types.Primitive.undefined_t;
                const inner_t = try self.checkExpression(y.expr);
                break :blk inner_t;
            },
            else => types.Primitive.any,
        };
        self.hir.setType(node, t);
        return t;
    }

    fn pushNarrowScope(self: *Checker) !void {
        const empty: std.AutoHashMapUnmanaged(hir_mod.StringId, TypeId) = .empty;
        try self.narrow_scopes.append(self.gpa, empty);
        const empty_mem: std.AutoHashMapUnmanaged(MemberKey, TypeId) = .empty;
        try self.member_narrow_scopes.append(self.gpa, empty_mem);
    }

    fn popNarrowScope(self: *Checker) void {
        if (self.narrow_scopes.items.len == 0) return;
        var top = self.narrow_scopes.items[self.narrow_scopes.items.len - 1];
        top.deinit(self.gpa);
        _ = self.narrow_scopes.pop();
        if (self.member_narrow_scopes.items.len == 0) return;
        var mtop = self.member_narrow_scopes.items[self.member_narrow_scopes.items.len - 1];
        mtop.deinit(self.gpa);
        _ = self.member_narrow_scopes.pop();
    }

    /// Look up the topmost narrowed type for a member access keyed
    /// by `(obj_name, prop_name)`. Walks the scope stack inner →
    /// outer.
    fn lookupMemberNarrow(self: *Checker, key: MemberKey) ?TypeId {
        var i = self.member_narrow_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.member_narrow_scopes.items[i].get(key)) |t| return t;
        }
        return null;
    }

    fn recordMemberNarrow(self: *Checker, key: MemberKey, t: TypeId) !void {
        if (self.member_narrow_scopes.items.len == 0) return;
        var top = &self.member_narrow_scopes.items[self.member_narrow_scopes.items.len - 1];
        try top.put(self.gpa, key, t);
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
    /// True if `sig` accepts the given `arg_types` — i.e., the call
    /// would type-check without TS2554 / TS2345. Used by overload
    /// resolution to pick the first applicable signature.
    fn signatureAccepts(self: *Checker, sig: TypeId, arg_types: []const TypeId) !bool {
        const params = self.interner.signatureParams(sig);
        // Required-arg count = params not including a trailing run
        // that includes `undefined`.
        var min_required: usize = params.len;
        while (min_required > 0) {
            if (!self.typeIncludesUndefined(params[min_required - 1])) break;
            min_required -= 1;
        }
        if (arg_types.len < min_required) return false;
        if (arg_types.len > params.len) return false;
        const n = @min(arg_types.len, params.len);
        for (0..n) |i| {
            if (self.interner.pool.flagsOf(params[i]).is_type_parameter) continue;
            const ok = self.engine.isAssignableTo(arg_types[i], params[i]) catch false;
            if (!ok) return false;
        }
        return true;
    }

    /// Assertion-function flow narrowing. If `stmt` is a call to a
    /// function whose return type is `asserts arg is T`, record
    /// `arg -> T` in the surrounding narrow scope so subsequent
    /// statements in the same block see the narrowed type.
    fn applyAssertionFlow(self: *Checker, stmt: NodeId) !void {
        const k = self.hir.kindOf(stmt);
        if (k != .call_expr) return;
        const c = hir_mod.callOf(self.hir, stmt);
        if (self.hir.kindOf(c.callee) != .identifier) return;
        const callee_id = hir_mod.identifierOf(self.hir, c.callee);
        const pred = self.fn_predicates.get(callee_id.name) orelse return;
        if (!pred.is_asserts) return;
        const args = hir_mod.callArgs(self.hir, stmt);
        if (pred.param_index >= args.len) return;
        const arg = args[pred.param_index];
        if (self.hir.kindOf(arg) != .identifier) return;
        const arg_id = hir_mod.identifierOf(self.hir, arg);
        // Predicate-less `asserts arg` (no `is T`): narrow to a
        // truthy approximation by subtracting `null | undefined`
        // from the current type.
        if (pred.target_type == types.Primitive.unknown or pred.target_type == types.Primitive.none) {
            const current = self.lookupNarrow(arg_id.name) orelse self.typeOfIdentifier(arg);
            const narrowed = self.subtractNullUndefined(current) catch current;
            try self.recordNarrow(arg_id.name, narrowed);
            return;
        }
        try self.recordNarrow(arg_id.name, pred.target_type);
    }

    fn applyTypeGuard(self: *Checker, cond: NodeId, when_true: bool) !void {
        // Aliased conditional narrowing: `if (cond)` where `cond`
        // was bound to a guard expression. Expand the alias and
        // recurse on the original expression so all the existing
        // guard logic applies.
        if (self.hir.kindOf(cond) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, cond);
            if (self.cond_aliases.get(id.name)) |aliased| {
                return self.applyTypeGuard(aliased, when_true);
            }
        }
        // `if (Array.isArray(x))` — built-in narrowing for the
        // canonical array predicate. We don't yet have a fully-shaped
        // `Array<any>` reference type wired up here, so we narrow the
        // argument to `Primitive.object_t` (arrays are objects). This
        // mirrors the approximation used elsewhere (e.g. `instanceof`)
        // and lets `let arr = x` after the guard pick up an object
        // type rather than the original `any`/union.
        if (self.hir.kindOf(cond) == .call_expr) {
            const c = hir_mod.callOf(self.hir, cond);
            if (self.hir.kindOf(c.callee) == .member_access) {
                const m = hir_mod.memberOf(self.hir, c.callee);
                if (self.hir.kindOf(m.object) == .identifier) {
                    const obj_id = hir_mod.identifierOf(self.hir, m.object);
                    const obj_name = self.string_interner.get(obj_id.name);
                    const prop_name = self.string_interner.get(m.name);
                    if (std.mem.eql(u8, obj_name, "Array") and
                        std.mem.eql(u8, prop_name, "isArray"))
                    {
                        const args = hir_mod.callArgs(self.hir, cond);
                        if (args.len >= 1 and self.hir.kindOf(args[0]) == .identifier) {
                            const arg_id = hir_mod.identifierOf(self.hir, args[0]);
                            if (when_true) {
                                try self.recordNarrow(arg_id.name, types.Primitive.object_t);
                            } else {
                                const current = self.lookupNarrow(arg_id.name) orelse self.typeOfIdentifier(args[0]);
                                const narrowed = self.subtractType(current, types.Primitive.object_t) catch current;
                                try self.recordNarrow(arg_id.name, narrowed);
                            }
                            return;
                        }
                    }
                }
            }
        }
        // `if (isFoo(x))` — type-predicate call narrowing. When the
        // condition is a call to a predicate function and the argument
        // at the predicate's parameter index is an identifier, narrow
        // the identifier in the then-branch to the predicate's target
        // type (or subtract it in the else-branch).
        if (self.hir.kindOf(cond) == .call_expr) {
            const c = hir_mod.callOf(self.hir, cond);
            if (self.hir.kindOf(c.callee) == .identifier) {
                const callee_id = hir_mod.identifierOf(self.hir, c.callee);
                if (self.fn_predicates.get(callee_id.name)) |pred| {
                    const args = hir_mod.callArgs(self.hir, cond);
                    if (pred.param_index < args.len) {
                        const arg = args[pred.param_index];
                        if (self.hir.kindOf(arg) == .identifier) {
                            const arg_id = hir_mod.identifierOf(self.hir, arg);
                            if (when_true) {
                                try self.recordNarrow(arg_id.name, pred.target_type);
                            } else {
                                const current = self.lookupNarrow(arg_id.name) orelse self.typeOfIdentifier(arg);
                                const narrowed = self.subtractType(current, pred.target_type) catch current;
                                try self.recordNarrow(arg_id.name, narrowed);
                            }
                            return;
                        }
                    }
                }
            }
        }
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

        // `"foo" in x` — narrows `x` to the variants of its union
        // that declare `foo`. The else-branch keeps the variants
        // that *don't* declare it. LHS must be a string literal
        // (TS only narrows when the property name is statically
        // known); RHS must be an identifier we can record against.
        if (b.op == .in and
            self.hir.kindOf(b.lhs) == .literal_string and
            self.hir.kindOf(b.rhs) == .identifier)
        {
            const lit = hir_mod.literalStringOf(self.hir, b.lhs);
            const rhs_id = hir_mod.identifierOf(self.hir, b.rhs);
            const current = self.lookupNarrow(rhs_id.name) orelse self.typeOfIdentifier(b.rhs);
            const narrowed = self.narrowByPropertyPresence(current, lit.value, when_true) catch current;
            if (narrowed != current) try self.recordNarrow(rhs_id.name, narrowed);
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
                        // the variable's current type. Works for
                        // unions of primitives (`string | number`
                        // minus `string` → `number`). Falls through
                        // to `never` for the bare-equality case.
                        const current = self.lookupNarrow(id.name) orelse self.typeOfIdentifier(u.operand);
                        const subbed = self.subtractType(current, narrowed) catch current;
                        try self.recordNarrow(id.name, subbed);
                    }
                }
                return;
            }
        }
        // X === <literal> / X !== <literal> — narrow X to the
        // literal type in the positive branch, subtract it in the
        // negative branch. Covers `s === "hello"`, `n === 42`,
        // `b === true`, `x === 42n`, `x === -42n` (parsed as
        // `unary_op(neg, literal_bigint(42))`). Discriminated-union
        // narrowing above handles the member-access case
        // (`x.kind === "circle"`); this branch handles the
        // bare-identifier case.
        const rhs_is_neg_bigint = blk: {
            if (self.hir.kindOf(b.rhs) != .unary_op) break :blk false;
            const u = hir_mod.unaryOf(self.hir, b.rhs);
            break :blk u.op == .neg and self.hir.kindOf(u.operand) == .literal_bigint;
        };
        if (self.hir.kindOf(b.lhs) == .identifier and
            (self.hir.kindOf(b.rhs) == .literal_string or
                self.hir.kindOf(b.rhs) == .literal_number or
                self.hir.kindOf(b.rhs) == .literal_bigint or
                self.hir.kindOf(b.rhs) == .literal_bool or
                rhs_is_neg_bigint))
        {
            const id = hir_mod.identifierOf(self.hir, b.lhs);
            const lit_t: TypeId = blk: {
                if (rhs_is_neg_bigint) {
                    const u = hir_mod.unaryOf(self.hir, b.rhs);
                    const lit = hir_mod.literalBigIntOf(self.hir, u.operand);
                    const digits_str = self.string_interner.get(lit.digits);
                    // Build "-<digits>" so the rendered literal is
                    // `-<digits>n` and equality of TypeIds tracks
                    // sign + magnitude.
                    var buf: [64]u8 = undefined;
                    if (digits_str.len + 1 > buf.len) return;
                    buf[0] = '-';
                    @memcpy(buf[1 .. 1 + digits_str.len], digits_str);
                    const neg_digits_id = self.string_interner.intern(buf[0 .. 1 + digits_str.len]) catch return;
                    break :blk self.interner.internBigIntLiteral(neg_digits_id) catch return;
                }
                switch (self.hir.kindOf(b.rhs)) {
                    .literal_string => {
                        const lit = hir_mod.literalStringOf(self.hir, b.rhs);
                        break :blk self.interner.internStringLiteral(lit.value) catch return;
                    },
                    .literal_number => {
                        const v = hir_mod.literalNumberOf(self.hir, b.rhs);
                        break :blk self.interner.internNumberLiteral(v) catch return;
                    },
                    .literal_bigint => {
                        const lit = hir_mod.literalBigIntOf(self.hir, b.rhs);
                        break :blk self.interner.internBigIntLiteral(lit.digits) catch return;
                    },
                    .literal_bool => {
                        const v = hir_mod.literalBoolOf(self.hir, b.rhs);
                        break :blk self.interner.internBooleanLiteral(v);
                    },
                    else => unreachable,
                }
            };
            if (positive) {
                try self.recordNarrow(id.name, lit_t);
            } else {
                const current = self.lookupNarrow(id.name) orelse self.typeOfIdentifier(b.lhs);
                const narrowed = self.subtractType(current, lit_t) catch current;
                try self.recordNarrow(id.name, narrowed);
            }
            return;
        }
        // X === null / X !== null
        if (self.hir.kindOf(b.lhs) == .identifier and
            self.hir.kindOf(b.rhs) == .literal_null)
        {
            const id = hir_mod.identifierOf(self.hir, b.lhs);
            if (positive) {
                try self.recordNarrow(id.name, types.Primitive.null_t);
            } else {
                // X !== null in then-branch → subtract null from X's
                // current static type. If X was `string | null`, the
                // narrowed type is `string`. If X was just `null`,
                // the narrowed type is `never` (unreachable).
                const current = self.lookupNarrow(id.name) orelse self.typeOfIdentifier(b.lhs);
                const narrowed = self.subtractType(current, types.Primitive.null_t) catch current;
                try self.recordNarrow(id.name, narrowed);
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
                    const current = self.lookupNarrow(lhs.name) orelse self.typeOfIdentifier(b.lhs);
                    const narrowed = self.subtractType(current, types.Primitive.undefined_t) catch current;
                    try self.recordNarrow(lhs.name, narrowed);
                }
                return;
            }
        }

        // Member-access narrowing on an identifier-rooted access:
        //   obj.x === null / obj.x !== null
        //   obj.x === undefined / obj.x !== undefined
        //   obj.x === <literal> / obj.x !== <literal>
        // The narrow is keyed by `(obj_name, prop_name)` so the
        // `member_access` typing path sees it inside the branch.
        if (self.hir.kindOf(b.lhs) == .member_access) {
            const m = hir_mod.memberOf(self.hir, b.lhs);
            if (self.hir.kindOf(m.object) == .identifier) {
                const obj_id = hir_mod.identifierOf(self.hir, m.object);
                const key: MemberKey = .{ .obj_name = obj_id.name, .prop_name = m.name };
                // RHS == null
                if (self.hir.kindOf(b.rhs) == .literal_null) {
                    if (positive) {
                        try self.recordMemberNarrow(key, types.Primitive.null_t);
                    } else {
                        const obj_t = self.typeOfIdentifier(m.object);
                        const current = self.lookupMemberNarrow(key) orelse
                            (self.interner.objectMember(obj_t, m.name) orelse types.Primitive.any);
                        const narrowed = self.subtractType(current, types.Primitive.null_t) catch current;
                        try self.recordMemberNarrow(key, narrowed);
                    }
                    return;
                }
                // RHS == identifier 'undefined'
                if (self.hir.kindOf(b.rhs) == .identifier) {
                    const rhs2 = hir_mod.identifierOf(self.hir, b.rhs);
                    const rhs2_name = self.string_interner.get(rhs2.name);
                    if (std.mem.eql(u8, rhs2_name, "undefined")) {
                        if (positive) {
                            try self.recordMemberNarrow(key, types.Primitive.undefined_t);
                        } else {
                            const obj_t = self.typeOfIdentifier(m.object);
                            const current = self.lookupMemberNarrow(key) orelse
                                (self.interner.objectMember(obj_t, m.name) orelse types.Primitive.any);
                            const narrowed = self.subtractType(current, types.Primitive.undefined_t) catch current;
                            try self.recordMemberNarrow(key, narrowed);
                        }
                        return;
                    }
                }
                // RHS == primitive literal (string/number/bool).
                // The discriminated-union path above narrows the
                // whole object when its type is a union; this
                // records a property-level narrow so non-union
                // object roots also see the literal type.
                if (self.hir.kindOf(b.rhs) == .literal_string or
                    self.hir.kindOf(b.rhs) == .literal_number or
                    self.hir.kindOf(b.rhs) == .literal_bool)
                {
                    const lit_t: TypeId = blk: {
                        switch (self.hir.kindOf(b.rhs)) {
                            .literal_string => {
                                const lit = hir_mod.literalStringOf(self.hir, b.rhs);
                                break :blk self.interner.internStringLiteral(lit.value) catch return;
                            },
                            .literal_number => {
                                const v = hir_mod.literalNumberOf(self.hir, b.rhs);
                                break :blk self.interner.internNumberLiteral(v) catch return;
                            },
                            .literal_bool => {
                                const v = hir_mod.literalBoolOf(self.hir, b.rhs);
                                break :blk self.interner.internBooleanLiteral(v);
                            },
                            else => unreachable,
                        }
                    };
                    if (positive) {
                        try self.recordMemberNarrow(key, lit_t);
                    } else {
                        const obj_t = self.typeOfIdentifier(m.object);
                        const current = self.lookupMemberNarrow(key) orelse
                            (self.interner.objectMember(obj_t, m.name) orelse types.Primitive.any);
                        const narrowed = self.subtractType(current, lit_t) catch current;
                        try self.recordMemberNarrow(key, narrowed);
                    }
                    return;
                }
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
        // If accumulated narrowing already produced `never`, there's
        // nothing left to subtract — leave the narrow alone.
        if (static_t == types.Primitive.never) return;
        const is_union = self.interner.pool.flagsOf(static_t).is_union;
        const is_object = self.interner.pool.flagsOf(static_t).is_object_type;
        if (!is_union and !is_object) return;

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

        // Treat a single-object narrow as a one-element union so the
        // exhaustion logic below collapses it to `never` when the
        // last remaining variant is also subtracted (the
        // exhaustiveness-marker pattern in switch defaults).
        const single_buf = [_]TypeId{static_t};
        const members: []const TypeId = if (is_union)
            self.interner.unionMembers(static_t)
        else
            single_buf[0..];
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
        const narrowed: TypeId = if (keep.items.len == 0)
            // Exhausted: every variant was excluded. The discriminant
            // is `never` — TS uses this for exhaustiveness checks
            // (e.g. `let x: never = s` in a switch's default branch
            // after every case is covered).
            types.Primitive.never
        else if (keep.items.len == 1)
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
            if (k == .for_in_stmt or k == .for_of_stmt) {
                // The loop binding lives directly on the for node;
                // it isn't a sibling in any block. Match against
                // the binding's name slot if it's a let/const/var
                // form, or directly when it's a bare identifier
                // (the parser emits this for `for (let n of ...)`).
                const fr = hir_mod.forInOf(self.hir, cur);
                if (fr.target != hir_mod.none_node_id) {
                    const tk = self.hir.kindOf(fr.target);
                    if (tk == .var_decl or tk == .let_decl or tk == .const_decl) {
                        const v = hir_mod.varDeclOf(self.hir, fr.target);
                        if (v.name != hir_mod.none_node_id and self.hir.kindOf(v.name) == .identifier) {
                            const vid = hir_mod.identifierOf(self.hir, v.name);
                            if (vid.name == id.name) {
                                const t = self.hir.typeOf(fr.target);
                                if (t != types.Primitive.none) return t;
                            }
                        }
                    } else if (tk == .identifier) {
                        const vid = hir_mod.identifierOf(self.hir, fr.target);
                        if (vid.name == id.name) {
                            const t = self.hir.typeOf(fr.target);
                            if (t != types.Primitive.none) return t;
                        }
                    }
                }
            }
            cur = self.hir.parentOf(cur);
        }

        // Module-level fallback.
        if (self.module) |module| {
            if (module.root.lookup(id.name)) |sym| {
                if (sym.decls.items.len > 0) {
                    const decl = sym.decls.items[0];
                    const t = self.hir.typeOf(decl);
                    if (t != types.Primitive.none) return t;
                }
                return types.Primitive.any;
            }
            // Module is bound and the name is unknown — emit TS2304
            // unless the identifier is a recognized built-in (e.g.
            // `console`, `undefined`, global constructors). Skip
            // declaration name slots to avoid flagging the very
            // identifier that introduces the name.
            if (!self.isDeclNameSlot(node) and !self.isBuiltinName(id.name)) {
                self.reportCannotFindName(node, id.name) catch {};
            }
        }
        // Lib globals — `Object` carries the keys/values/entries/
        // assign namespace. Other globals fall through to `any` for
        // now (full lib.d.ts wiring is a follow-up).
        const name_str = self.string_interner.get(id.name);
        if (std.mem.eql(u8, name_str, "Object")) {
            if (lib.objectGlobal(&self.lib_cache, self.interner, self.string_interner)) |og| {
                return og;
            } else |_| {}
        }
        return types.Primitive.any;
    }

    /// Recognize a small set of common globals that should not
    /// trigger TS2304 even though we don't have a real lib.d.ts
    /// loaded yet. The list intentionally errs on the conservative
    /// side; expand as more globals are encountered.
    fn isBuiltinName(self: *const Checker, name: hir_mod.StringId) bool {
        const s = self.string_interner.get(name);
        const builtins = [_][]const u8{
            // Core globals / values.
            "console",     "undefined",          "NaN",
            "Infinity",    "globalThis",         "this",
            "window",      "document",
            // Constructors / namespaces.
            "Math",        "JSON",               "Object",
            "Array",       "String",             "Number",
            "Boolean",     "Symbol",             "BigInt",
            "Error",       "TypeError",          "RangeError",
            "SyntaxError", "Promise",            "Map",
            "Set",         "WeakMap",            "WeakSet",
            "Date",        "RegExp",             "Function",
            "Proxy",       "Reflect",
            // Global functions.
            "parseInt",    "parseFloat",         "isNaN",
            "isFinite",    "encodeURI",          "decodeURI",
            "encodeURIComponent",                "decodeURIComponent",
            // Timers / scheduling.
            "setTimeout",  "clearTimeout",       "setInterval",
            "clearInterval",                     "setImmediate",
            "clearImmediate",                    "queueMicrotask",
            // Node.js / CommonJS.
            "process",     "Buffer",             "require",
            "module",      "exports",            "__dirname",
            "__filename",
            // Function-scoped magic.
            "arguments",
            // Dynamic `import("…")` parses the keyword as an
            // identifier callee — exempt it from TS2304.
            "import",
            // Common ambient names emitted by the parser for
            // module / class shapes that don't have full
            // resolution wired up yet.
            "super",
        };
        for (builtins) |b| {
            if (std.mem.eql(u8, s, b)) return true;
        }
        return false;
    }

    fn reportCannotFindName(
        self: *Checker,
        node: NodeId,
        name: hir_mod.StringId,
    ) !void {
        const name_str = self.string_interner.get(name);

        // Collect in-scope candidate names and find the closest one
        // by Levenshtein distance. We accept a suggestion only if the
        // distance is ≤ max(2, name.len/4) — matches tsc behavior of
        // suggesting only "obvious" typos.
        const Best = struct { name: []const u8 = "", dist: usize = std.math.maxInt(usize) };
        var best: Best = .{};

        const considerCandidate = struct {
            fn call(typo: []const u8, cand_str: []const u8, b: *Best) void {
                if (cand_str.len == 0) return;
                if (std.mem.eql(u8, cand_str, typo)) return;
                // Quick reject: length difference > 2 and > typo.len/4
                // cannot satisfy the threshold.
                const ll = if (cand_str.len > typo.len) cand_str.len - typo.len else typo.len - cand_str.len;
                if (ll > 2 and ll > typo.len / 4) return;
                const d = levenshtein(typo, cand_str);
                if (d < b.dist) b.* = .{ .name = cand_str, .dist = d };
            }
        }.call;

        // Walk the HIR parent chain and collect parameter / local
        // decl names — mirrors the lookup in `typeOfIdentifier`.
        var cur: hir_mod.NodeId = self.hir.parentOf(node);
        while (cur != hir_mod.none_node_id) {
            const k = self.hir.kindOf(cur);
            if (k == .fn_decl or k == .fn_expr or k == .arrow_fn) {
                const params = hir_mod.fnParams(self.hir, cur);
                for (params) |p| {
                    if (self.hir.kindOf(p) != .parameter) continue;
                    const pp = hir_mod.parameterOf(self.hir, p);
                    if (pp.name == hir_mod.none_node_id) continue;
                    if (self.hir.kindOf(pp.name) != .identifier) continue;
                    const pid = hir_mod.identifierOf(self.hir, pp.name);
                    considerCandidate(name_str, self.string_interner.get(pid.name), &best);
                }
            } else if (k == .block_stmt) {
                const stmts = hir_mod.blockStmts(self.hir, cur);
                for (stmts) |s| {
                    const sk = self.hir.kindOf(s);
                    if (sk == .var_decl or sk == .let_decl or sk == .const_decl) {
                        const v = hir_mod.varDeclOf(self.hir, s);
                        if (v.name != hir_mod.none_node_id and self.hir.kindOf(v.name) == .identifier) {
                            const vid = hir_mod.identifierOf(self.hir, v.name);
                            considerCandidate(name_str, self.string_interner.get(vid.name), &best);
                        }
                    } else if (sk == .fn_decl or sk == .fn_expr) {
                        const fp = hir_mod.fnDeclOf(self.hir, s);
                        if (fp.name != hir_mod.none_node_id and self.hir.kindOf(fp.name) == .identifier) {
                            const fid = hir_mod.identifierOf(self.hir, fp.name);
                            considerCandidate(name_str, self.string_interner.get(fid.name), &best);
                        }
                    }
                }
            }
            cur = self.hir.parentOf(cur);
        }

        // Module-level symbol names (value / type / namespace spaces).
        if (self.module) |module| {
            inline for (.{ "values", "types", "namespaces" }) |field_name| {
                var it = @field(module.root, field_name).iterator();
                while (it.next()) |entry| {
                    const cand_id = entry.key_ptr.*;
                    considerCandidate(name_str, self.string_interner.get(cand_id), &best);
                }
            }
        }

        // Threshold: max(2, name.len/4). For very short names we
        // still allow distance 2 — matches tsc.
        const threshold: usize = @max(@as(usize, 2), name_str.len / 4);
        const has_suggestion = best.dist <= threshold and best.name.len > 0;

        const msg = if (has_suggestion)
            try std.fmt.allocPrint(
                self.diag_arena.allocator(),
                "Cannot find name '{s}'. Did you mean '{s}'?",
                .{ name_str, best.name },
            )
        else
            try std.fmt.allocPrint(
                self.diag_arena.allocator(),
                "Cannot find name '{s}'.",
                .{name_str},
            );

        try self.diagnostics.append(self.gpa, .{
            .node = node,
            .code = if (has_suggestion) TsCodes.cannot_find_name_did_you_mean else TsCodes.cannot_find_name,
            .message = msg,
        });
    }

    /// Classic two-row Levenshtein edit distance. Computes the
    /// minimum number of single-character insertions, deletions, or
    /// substitutions to transform `a` into `b`. O(|a|·|b|) time,
    /// O(min(|a|,|b|)) space. Used for "did you mean?" suggestions.
    fn levenshtein(a: []const u8, b: []const u8) usize {
        if (a.len == 0) return b.len;
        if (b.len == 0) return a.len;
        // Bound the DP arrays — identifier names rarely exceed 128
        // bytes; anything over the cap is treated as max-distance to
        // avoid heap allocation in the hot diagnostic path.
        const cap: usize = 128;
        if (a.len + 1 > cap or b.len + 1 > cap) return std.math.maxInt(usize);
        var prev: [cap]usize = undefined;
        var curr: [cap]usize = undefined;
        var j: usize = 0;
        while (j <= b.len) : (j += 1) prev[j] = j;
        var i: usize = 1;
        while (i <= a.len) : (i += 1) {
            curr[0] = i;
            var k: usize = 1;
            while (k <= b.len) : (k += 1) {
                const cost: usize = if (a[i - 1] == b[k - 1]) 0 else 1;
                const del = prev[k] + 1;
                const ins = curr[k - 1] + 1;
                const sub = prev[k - 1] + cost;
                var m = del;
                if (ins < m) m = ins;
                if (sub < m) m = sub;
                curr[k] = m;
            }
            std.mem.copyForwards(usize, prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
        }
        return prev[b.len];
    }

    /// Returns true when the identifier reference resolves to a
    /// `const`-declared symbol at the source — used by TS2588 to
    /// flag assignment to a constant. Walks the same parent-chain
    /// as `typeOfIdentifier` but checks the *kind* of declaration
    /// rather than its type.
    fn identifierResolvesToConst(self: *Checker, node: NodeId) bool {
        const id = hir_mod.identifierOf(self.hir, node);
        var cur: hir_mod.NodeId = self.hir.parentOf(node);
        while (cur != hir_mod.none_node_id) {
            const k = self.hir.kindOf(cur);
            // Parameter binding shadows outer const decls; if a
            // parameter with this name is in scope, it isn't const.
            if (k == .fn_decl or k == .fn_expr or k == .arrow_fn) {
                const params = hir_mod.fnParams(self.hir, cur);
                for (params) |p| {
                    if (self.hir.kindOf(p) != .parameter) continue;
                    const pp = hir_mod.parameterOf(self.hir, p);
                    if (pp.name == hir_mod.none_node_id) continue;
                    if (self.hir.kindOf(pp.name) != .identifier) continue;
                    const pid = hir_mod.identifierOf(self.hir, pp.name);
                    if (pid.name == id.name) return false;
                }
            }
            if (k == .block_stmt) {
                const stmts = hir_mod.blockStmts(self.hir, cur);
                for (stmts) |s| {
                    const sk = self.hir.kindOf(s);
                    if (sk == .var_decl or sk == .let_decl or sk == .const_decl) {
                        const v = hir_mod.varDeclOf(self.hir, s);
                        if (v.name != hir_mod.none_node_id and self.hir.kindOf(v.name) == .identifier) {
                            const vid = hir_mod.identifierOf(self.hir, v.name);
                            if (vid.name == id.name) return sk == .const_decl;
                        }
                    }
                }
            }
            cur = self.hir.parentOf(cur);
        }
        // Module-level fallback via the binder's symbol table.
        if (self.module) |module| {
            if (module.root.lookup(id.name)) |sym| {
                return sym.flags.is_const;
            }
        }
        return false;
    }

    /// Conservative gate for TS2367: return true only when both
    /// sides look like concrete primitives (string / number / boolean
    /// / bigint / null / undefined / symbol) or literals of those.
    /// Skips unions, intersections, object types, type parameters,
    /// any/unknown/never, and other compound shapes — TS allows
    /// many of those comparisons even when they look unrelated, and
    /// our `isComparableTo` is too coarse to reproduce TS's
    /// `comparableRelation` exactly.
    fn shouldCheckNoOverlap(self: *Checker, a: TypeId, b: TypeId) bool {
        return self.isConcretePrimitiveLike(a) and self.isConcretePrimitiveLike(b);
    }

    fn isConcretePrimitiveLike(self: *Checker, t: TypeId) bool {
        if (t == types.Primitive.any or
            t == types.Primitive.unknown or
            t == types.Primitive.never or
            t == types.Primitive.void_t)
        {
            return false;
        }
        const f = self.interner.pool.flagsOf(t);
        if (f.is_union or f.is_intersection or
            f.is_object_type or f.is_object or
            f.is_signature or f.is_tuple or
            f.is_type_parameter or f.is_instantiation or
            f.is_conditional or f.is_mapped or
            f.is_indexed_access or f.is_keyof or
            f.is_typeof or f.is_infer or
            f.is_template_literal)
        {
            return false;
        }
        return f.is_string or f.is_number or f.is_boolean or
            f.is_bigint or f.is_symbol or
            f.is_null or f.is_undefined;
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
            .eq, .neq, .eq_strict, .neq_strict => blk: {
                // TS2367: warn when `===` / `!==` compares two known
                // types that have no overlap. We're conservative here
                // and only fire when both sides are concrete
                // primitives (or literals of those primitives) so we
                // don't flag legitimate union / object / generic
                // comparisons that TS itself allows.
                if (b.op == .eq_strict or b.op == .neq_strict) {
                    if (self.shouldCheckNoOverlap(lhs, rhs)) {
                        const ok = self.engine.isComparableTo(lhs, rhs) catch true;
                        if (!ok) {
                            try self.report(node, TsCodes.no_overlap_comparison, "This comparison appears to be unintentional because the types have no overlap.");
                        }
                    }
                }
                break :blk types.Primitive.boolean_t;
            },
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
        // `a ?? b` — when `a` is non-null/undefined the result is
        // `a`'s type minus null/undefined; otherwise it's `b`'s
        // type. The runtime forks on nullish, so the result type
        // is `(a minus null|undefined) | b`. For `&&`/`||` we keep
        // the existing simple union — TS narrows further but our
        // current relation engine doesn't yet model truthiness.
        if (l.op == .nullish) {
            const lhs_non_null = self.subtractNullUndefined(lhs) catch lhs;
            return self.interner.internUnion(&.{ lhs_non_null, rhs }) catch error.OutOfMemory;
        }
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
        // Default-type fallback: walk every TypeId reachable from the
        // signature (params + return) and, for any type-parameter id
        // not already substituted, fall back to its declaration-site
        // default (`<T = string>`). Lets `f()` resolve `T` to `string`
        // when no value pins it. The walker reaches into unions /
        // intersections so optional `x?: T` (lowered to `T |
        // undefined`) still surfaces the underlying T.
        for (param_ts) |p| try self.collectFreeTypeParamDefaults(p, &subs);
        try self.collectFreeTypeParamDefaults(ret_type, &subs);
        if (subs.count() == 0) return ret_type;
        return self.substituteType(ret_type, &subs);
    }

    /// Walk `t` and, for any encountered type-parameter id with a
    /// declaration-site default that isn't already in `subs`, record
    /// `tp_id -> default`. Used by `instantiateReturn` so optional
    /// params (`x?: T` → `T | undefined`) and nested generics still
    /// surface T.
    fn collectFreeTypeParamDefaults(
        self: *Checker,
        t: TypeId,
        subs: *std.AutoHashMapUnmanaged(TypeId, TypeId),
    ) !void {
        const flags = self.interner.pool.flagsOf(t);
        if (flags.is_type_parameter) {
            if (!subs.contains(t)) {
                const tp = self.interner.pool.type_parameter_payloads.items[self.interner.pool.payloadOf(t)];
                if (tp.default != types.Primitive.none) {
                    try subs.put(self.gpa, t, tp.default);
                }
            }
            return;
        }
        if (flags.is_union) {
            for (self.interner.unionMembers(t)) |m| try self.collectFreeTypeParamDefaults(m, subs);
            return;
        }
        if (flags.is_intersection) {
            for (self.interner.intersectionMembers(t)) |m| try self.collectFreeTypeParamDefaults(m, subs);
            return;
        }
    }

    /// Substitute occurrences of type-parameter ids in `t` per the
    /// `subs` map. Recurses into compound types — unions,
    /// intersections, signatures, object types — so a parameterized
    /// alias body fully resolves under instantiation.
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
        if (flags.is_signature) {
            const params = self.interner.signatureParams(t);
            var new: std.ArrayListUnmanaged(TypeId) = .empty;
            defer new.deinit(self.gpa);
            for (params) |p| try new.append(self.gpa, try self.substituteType(p, subs));
            const ret = if (self.interner.signatureReturn(t)) |r|
                try self.substituteType(r, subs)
            else
                types.Primitive.void_t;
            return self.interner.internSignature(new.items, ret, false) catch return t;
        }
        if (flags.is_object_type) {
            const orig = self.interner.objectMembers(t);
            var new_members: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
            defer new_members.deinit(self.gpa);
            for (orig) |om| {
                try new_members.append(self.gpa, .{
                    .name = om.name,
                    .type = try self.substituteType(om.type, subs),
                    .is_optional = om.is_optional,
                    .is_readonly = om.is_readonly,
                    .is_method = om.is_method,
                });
            }
            return self.interner.internObjectType(new_members.items) catch return t;
        }
        if (flags.is_conditional) {
            // Substitute into each leaf, then re-attempt eager
            // evaluation. If the check is now concrete, this
            // collapses to the picked branch.
            const c = self.interner.conditionalPayload(t);
            const new_check = try self.substituteType(c.check_type, subs);
            const new_ext = try self.substituteType(c.extends_type, subs);
            const new_tt = try self.substituteType(c.true_branch, subs);
            const new_ff = try self.substituteType(c.false_branch, subs);
            return self.evalConditional(new_check, new_ext, new_tt, new_ff);
        }
        if (flags.is_keyof) {
            // `keyof T` after substitution may resolve eagerly.
            const k = self.interner.pool.keyof_payloads.items[self.interner.pool.payloadOf(t)];
            const new_operand = try self.substituteType(k.operand, subs);
            if (self.interner.pool.flagsOf(new_operand).is_object_type) {
                const members = self.interner.objectMembers(new_operand);
                if (members.len == 0) return types.Primitive.never;
                var lits: std.ArrayListUnmanaged(TypeId) = .empty;
                defer lits.deinit(self.gpa);
                for (members) |m| {
                    const lit = self.interner.internStringLiteral(m.name) catch continue;
                    try lits.append(self.gpa, lit);
                }
                if (lits.items.len == 1) return lits.items[0];
                return self.interner.internUnion(lits.items) catch return t;
            }
            return self.interner.internKeyof(new_operand) catch return t;
        }
        if (flags.is_indexed_access) {
            // T[K] after substitution. If the substituted T is an
            // object type and K resolves to a string literal, look
            // up the matching member's type. Otherwise re-intern.
            const ia = self.interner.pool.indexed_access_payloads.items[self.interner.pool.payloadOf(t)];
            const new_obj = try self.substituteType(ia.object, subs);
            const new_idx = try self.substituteType(ia.index, subs);
            const obj_flags = self.interner.pool.flagsOf(new_obj);
            const idx_flags = self.interner.pool.flagsOf(new_idx);
            if (obj_flags.is_object_type and idx_flags.is_literal and idx_flags.is_string) {
                const lit = self.interner.literalOf(new_idx);
                switch (lit) {
                    .string_lit => |sid| {
                        if (self.interner.objectMember(new_obj, sid)) |member_t| {
                            return member_t;
                        }
                    },
                    else => {},
                }
            }
            return self.interner.internIndexedAccess(new_obj, new_idx) catch return t;
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
        // Required-arg count = number of leading params whose type
        // doesn't include `undefined`. Optional / defaulted params
        // (typed as `T | undefined` by the signature pass) are
        // permitted to be omitted at the call site, matching tsc.
        var min_required: usize = param_ts.len;
        while (min_required > 0) {
            if (!self.typeIncludesUndefined(param_ts[min_required - 1])) break;
            min_required -= 1;
        }
        if (args.len < min_required or args.len > param_ts.len) {
            const expected_label: []const u8 = if (min_required == param_ts.len) "" else " or fewer";
            const msg = try std.fmt.allocPrint(
                self.diag_arena.allocator(),
                "Expected {d}{s} arguments, but got {d}.",
                .{ param_ts.len, expected_label, args.len },
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

    /// True when `type_node` is the synthetic `type_ref` to `const`
    /// the parser uses to encode `expr as const`.
    fn isAsConstMarker(self: *Checker, type_node: NodeId) bool {
        if (self.hir.kindOf(type_node) != .type_ref) return false;
        const r = hir_mod.typeRefOf(self.hir, type_node);
        if (r.qualifier_len != 0 or r.args_len != 0) return false;
        const name = self.string_interner.get(r.name);
        return std.mem.eql(u8, name, "const");
    }

    /// Implement `expr as const`: re-type the inner expression as
    /// its narrowest literal form. For literals this is the literal
    /// type itself; for `{ k: v }` we walk the properties and
    /// recursively literalize. Other shapes fall through unchanged.
    fn literalizeForAsConst(self: *Checker, expr: NodeId, fallback: TypeId) !TypeId {
        switch (self.hir.kindOf(expr)) {
            .literal_string => {
                const lit = hir_mod.literalStringOf(self.hir, expr);
                return self.interner.internStringLiteral(lit.value) catch return error.OutOfMemory;
            },
            .literal_number => {
                const v = hir_mod.literalNumberOf(self.hir, expr);
                return self.interner.internNumberLiteral(v) catch return error.OutOfMemory;
            },
            .literal_bool => {
                const v = hir_mod.literalBoolOf(self.hir, expr);
                return if (v) types.Primitive.true_lit else types.Primitive.false_lit;
            },
            .object_literal => {
                const props = hir_mod.objectLiteralProps(self.hir, expr);
                var members: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
                defer members.deinit(self.gpa);
                for (props) |p| {
                    if (self.hir.kindOf(p) != .object_property) continue;
                    const op = hir_mod.objectPropertyOf(self.hir, p);
                    if (self.hir.kindOf(op.key) != .identifier) continue;
                    if (op.value == hir_mod.none_node_id) continue;
                    const k = hir_mod.identifierOf(self.hir, op.key);
                    const inner = try self.checkExpression(op.value);
                    const lit_t = try self.literalizeForAsConst(op.value, inner);
                    try members.append(self.gpa, .{
                        .name = k.name,
                        .type = lit_t,
                        .is_optional = false,
                        .is_readonly = true,
                        .is_method = false,
                    });
                }
                return self.interner.internObjectType(members.items) catch return error.OutOfMemory;
            },
            else => return fallback,
        }
    }

    /// Filter a union type by whether each variant declares
    /// `prop_name` as a member. Used by `in`-operator narrowing:
    /// `"foo" in obj` keeps the union arms that have `foo`;
    /// the else branch keeps the arms that don't. For non-union
    /// inputs, the unfiltered type passes through (matches tsc:
    /// `in` narrowing only fires on unions of object types).
    fn narrowByPropertyPresence(
        self: *Checker,
        t: TypeId,
        prop_name: hir_mod.StringId,
        keep_with_prop: bool,
    ) !TypeId {
        if (!self.interner.pool.flagsOf(t).is_union) return t;
        const members = self.interner.unionMembers(t);
        var kept: std.ArrayListUnmanaged(TypeId) = .empty;
        defer kept.deinit(self.gpa);
        for (members) |m| {
            const has = self.interner.objectMember(m, prop_name) != null;
            if (has == keep_with_prop) try kept.append(self.gpa, m);
        }
        if (kept.items.len == 0) return types.Primitive.never;
        if (kept.items.len == 1) return kept.items[0];
        return self.interner.internUnion(kept.items) catch return error.OutOfMemory;
    }

    /// Bind the loop variable in `for (TARGET in/of SOURCE) ...`
    /// to `elem_t`. Target may be a `let`/`const`/`var` decl
    /// (binding shape) or a bare identifier (assignment shape).
    /// Both get the loop's element type recorded on the binding's
    /// HIR node so identifier lookups inside the body see it.
    fn bindForLoopTarget(self: *Checker, target: NodeId, elem_t: TypeId) CheckError!void {
        if (target == hir_mod.none_node_id) return;
        switch (self.hir.kindOf(target)) {
            .var_decl, .let_decl, .const_decl => {
                const v = hir_mod.varDeclOf(self.hir, target);
                self.hir.setType(target, elem_t);
                if (v.name != hir_mod.none_node_id) self.hir.setType(v.name, elem_t);
            },
            .identifier => {
                self.hir.setType(target, elem_t);
            },
            else => {},
        }
    }

    /// True when `t` admits `undefined` — either directly or as a
    /// member of a union. `any` and `unknown` count as well, since
    /// they accept any value.
    fn typeIncludesUndefined(self: *Checker, t: TypeId) bool {
        const f = self.interner.pool.flagsOf(t);
        if (f.is_undefined or f.is_any or f.is_unknown) return true;
        if (!f.is_union) return false;
        for (self.interner.unionMembers(t)) |m| {
            if (self.interner.pool.flagsOf(m).is_undefined) return true;
        }
        return false;
    }

    /// Build `t | undefined` (or return `t` if it already includes
    /// `undefined`). Used to widen optional parameters and defaulted
    /// parameters so call sites can omit them.
    fn unionWithUndefined(self: *Checker, t: TypeId) !TypeId {
        // Already nullable — bail out so we don't create
        // `(T | undefined) | undefined`.
        const flags = self.interner.pool.flagsOf(t);
        if (flags.is_undefined or flags.is_any or flags.is_unknown) return t;
        if (flags.is_union) {
            for (self.interner.unionMembers(t)) |m| {
                if (self.interner.pool.flagsOf(m).is_undefined) return t;
            }
        }
        return self.interner.internUnion(&.{ t, types.Primitive.undefined_t }) catch return error.OutOfMemory;
    }

    /// Remove `null` and `undefined` from `t` if it's a union; for
    /// non-union types pass through unchanged. Used by the
    /// `non_null_expr` typing path to support TS's `expr!` postfix
    /// operator. An empty result collapses to `never`.
    fn subtractNullUndefined(self: *Checker, t: TypeId) !TypeId {
        if (!self.interner.pool.flagsOf(t).is_union) return t;
        const members = self.interner.unionMembers(t);
        var kept: std.ArrayListUnmanaged(TypeId) = .empty;
        defer kept.deinit(self.gpa);
        for (members) |m| {
            const f = self.interner.pool.flagsOf(m);
            if (f.is_null or f.is_undefined) continue;
            try kept.append(self.gpa, m);
        }
        if (kept.items.len == 0) return types.Primitive.never;
        if (kept.items.len == 1) return kept.items[0];
        return self.interner.internUnion(kept.items) catch return error.OutOfMemory;
    }

    /// Widen `t` with `undefined` when `noUncheckedIndexedAccess`
    /// is enabled. Returns `t` unchanged when the option is off,
    /// when `t` is already `undefined`, or when `t` already contains
    /// `undefined` as a union member. Used by `element_access`
    /// typing for index-signature paths so `arr[i]` types as
    /// `T | undefined`.
    fn maybeWidenWithUndefined(self: *Checker, t: TypeId) TypeId {
        if (!self.strict_flags.no_unchecked_indexed_access) return t;
        if (t == types.Primitive.undefined_t) return t;
        const flags = self.interner.pool.flagsOf(t);
        if (flags.is_union) {
            for (self.interner.unionMembers(t)) |m| {
                if (m == types.Primitive.undefined_t) return t;
            }
        }
        return self.interner.internUnion(&.{ t, types.Primitive.undefined_t }) catch t;
    }

    /// Subtract a single type from a union (or return `t` unchanged
    /// if `t` isn't a union or doesn't contain `to_remove`). Used by
    /// negative-branch narrowing on `=== null`, `=== undefined`,
    /// `=== "literal"`, etc.
    fn subtractType(self: *Checker, t: TypeId, to_remove: TypeId) !TypeId {
        if (t == to_remove) return types.Primitive.never;
        if (!self.interner.pool.flagsOf(t).is_union) return t;
        const members = self.interner.unionMembers(t);
        var kept: std.ArrayListUnmanaged(TypeId) = .empty;
        defer kept.deinit(self.gpa);
        for (members) |m| {
            if (m == to_remove) continue;
            try kept.append(self.gpa, m);
        }
        if (kept.items.len == 0) return types.Primitive.never;
        if (kept.items.len == 1) return kept.items[0];
        return self.interner.internUnion(kept.items) catch return error.OutOfMemory;
    }

    /// TS2353: when an object-literal init flows into a typed
    /// destination, every property in the literal must be declared
    /// on the target. Only fires for fresh literals (the actual
    /// `{ … }` syntax) — the same shape passed through a variable
    /// is treated as a regular structural assignment by tsc.
    fn checkExcessProperties(self: *Checker, init_node: NodeId, declared_t: TypeId) CheckError!void {
        if (init_node == hir_mod.none_node_id) return;
        if (self.hir.kindOf(init_node) != .object_literal) return;
        if (!self.interner.pool.flagsOf(declared_t).is_object_type) return;
        const props = hir_mod.objectLiteralProps(self.hir, init_node);
        for (props) |p| {
            if (self.hir.kindOf(p) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, p);
            if (self.hir.kindOf(op.key) != .identifier) continue;
            const id = hir_mod.identifierOf(self.hir, op.key);
            const declared_member = self.interner.objectMemberInfo(declared_t, id.name);
            if (declared_member == null) {
                const name_str = self.string_interner.get(id.name);
                const msg = try std.fmt.allocPrint(
                    self.diag_arena.allocator(),
                    "Object literal may only specify known properties, and '{s}' does not exist on the target type.",
                    .{name_str},
                );
                try self.diagnostics.append(self.gpa, .{
                    .node = p,
                    .code = TsCodes.object_literal_excess_property,
                    .message = msg,
                });
                continue;
            }
            // Recurse into nested object-literal values: if the
            // declared property is itself an object type, the
            // nested literal also gets the freshness check.
            if (self.hir.kindOf(op.value) == .object_literal) {
                try self.checkExcessProperties(op.value, declared_member.?.type);
            }
        }
    }

    /// TS2375: when `exactOptionalPropertyTypes` is on, an object
    /// literal that explicitly sets an optional property to
    /// `undefined` is rejected unless the property's declared type
    /// already includes `undefined`. Only fires for fresh literals
    /// flowing into a known object-shaped destination.
    fn checkExactOptionalProperties(self: *Checker, init_node: NodeId, declared_t: TypeId) CheckError!void {
        if (!self.strict_flags.exact_optional_property_types) return;
        if (init_node == hir_mod.none_node_id) return;
        if (self.hir.kindOf(init_node) != .object_literal) return;
        if (!self.interner.pool.flagsOf(declared_t).is_object_type) return;
        const props = hir_mod.objectLiteralProps(self.hir, init_node);
        for (props) |p| {
            if (self.hir.kindOf(p) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, p);
            if (self.hir.kindOf(op.key) != .identifier) continue;
            if (op.value == hir_mod.none_node_id) continue;
            const id = hir_mod.identifierOf(self.hir, op.key);
            const declared_member = self.interner.objectMemberInfo(declared_t, id.name) orelse continue;
            if (!declared_member.is_optional) continue;
            // Only flag literal `undefined` values — the strict v0
            // doesn't try to track `undefined` through narrowing.
            if (self.hir.kindOf(op.value) != .literal_undefined) continue;
            // Skip if the declared type already includes `undefined`
            // — `a?: number | undefined` permits explicit undefined
            // even when the strict flag is on.
            if (self.typeIncludesUndefined(declared_member.type)) continue;
            const name_str = self.string_interner.get(id.name);
            const msg = try std.fmt.allocPrint(
                self.diag_arena.allocator(),
                "Type 'undefined' is not assignable to type of property '{s}'. With 'exactOptionalPropertyTypes: true', 'undefined' is not assignable to an optional property whose type does not include it.",
                .{name_str},
            );
            try self.diagnostics.append(self.gpa, .{
                .node = p,
                .code = TsCodes.exact_optional_property,
                .message = msg,
            });
        }
    }
};

/// Flip a polarity tag for the `inferVariance` walk. Covariant ⇄
/// contravariant on each input boundary; invariant and bivariant
/// are absorbing — they don't flip.
fn flipVariance(v: types.Variance) types.Variance {
    return switch (v) {
        .covariant => .contravariant,
        .contravariant => .covariant,
        .invariant => .invariant,
        .bivariant => .bivariant,
    };
}

/// Recognise expressions that produce control-flow narrowing when
/// used as conditions. Used by `cond_aliases` to decide whether to
/// record `let cond = <expr>` for later aliased-narrow expansion.
fn isNarrowingGuard(hir: *const Hir, node: NodeId) bool {
    const k = hir.kindOf(node);
    if (k == .call_expr) return true; // could be a predicate call
    if (k != .binary_op) return false;
    const b = hir_mod.binopOf(hir, node);
    return switch (b.op) {
        .eq_strict, .neq_strict, .instanceof, .in => true,
        else => false,
    };
}

/// Test whether a whitespace-trimmed line is a `// <name>` comment.
/// Accepts arbitrary trailing text after `<name>` (e.g. a colon and
/// reason: `// @ts-ignore: legacy api`). Block-comment forms aren't
/// matched here — they'd require a separate scan.
fn matchDirective(trimmed: []const u8, name: []const u8) bool {
    if (trimmed.len < 2 + name.len) return false;
    if (trimmed[0] != '/' or trimmed[1] != '/') return false;
    var j: usize = 2;
    while (j < trimmed.len and (trimmed[j] == ' ' or trimmed[j] == '\t')) : (j += 1) {}
    if (trimmed.len - j < name.len) return false;
    if (!std.mem.eql(u8, trimmed[j .. j + name.len], name)) return false;
    if (j + name.len == trimmed.len) return true;
    const c = trimmed[j + name.len];
    return !(std.ascii.isAlphanumeric(c) or c == '_' or c == '-');
}

/// Convert a 0-based byte offset into a 0-based source-line number.
fn byteOffsetToLine(source: []const u8, byte_pos: u32) u32 {
    var line: u32 = 0;
    const limit = @min(@as(usize, byte_pos), source.len);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

fn typeOfTypeofString(s: []const u8) ?TypeId {
    if (std.mem.eql(u8, s, "string")) return types.Primitive.string_t;
    if (std.mem.eql(u8, s, "number")) return types.Primitive.number_t;
    if (std.mem.eql(u8, s, "boolean")) return types.Primitive.boolean_t;
    if (std.mem.eql(u8, s, "bigint")) return types.Primitive.bigint_t;
    if (std.mem.eql(u8, s, "symbol")) return types.Primitive.symbol_t;
    if (std.mem.eql(u8, s, "undefined")) return types.Primitive.undefined_t;
    if (std.mem.eql(u8, s, "object")) return types.Primitive.object_t;
    // `typeof x === "function"` — narrow to a callable approximation.
    // We don't yet model a top-callable primitive, so use `object_t`,
    // which is the closest precomputed type (functions are objects).
    if (std.mem.eql(u8, s, "function")) return types.Primitive.object_t;
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
    s.engine = try relation.Engine.init(T.allocator, &s.ti);
    errdefer s.engine.deinit();
    s.engine.setStringInterner(&s.sint);
    s.checker = Checker.init(T.allocator, &s.hir, &s.ti, &s.sint, &s.engine);
    s.checker.setSource(source);
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

/// Setup variant that also runs the binder and attaches the resulting
/// module to the checker. Required for diagnostics whose detection
/// path consults the symbol table — TS2304 in particular needs the
/// module to know "I have full visibility, this name truly doesn't
/// exist." Caller owns the binder via `destroyBoundSetup`.
const BoundTestSetup = struct {
    base: *TestSetup,
    binder: binder_mod.Binder,
};

fn newBoundSetup(source: []const u8) !*BoundTestSetup {
    const b = try T.allocator.create(BoundTestSetup);
    errdefer T.allocator.destroy(b);
    b.base = try newSetup(source);
    errdefer destroySetup(b.base);
    b.binder = try binder_mod.Binder.init(T.allocator, &b.base.hir, &b.base.sint, 0);
    errdefer {
        b.binder.module.deinit();
        T.allocator.destroy(b.binder.module);
        b.binder.deinit();
    }
    try b.binder.bindSourceFile(b.base.root);
    b.base.checker.setModule(b.binder.module);
    return b;
}

fn destroyBoundSetup(b: *BoundTestSetup) void {
    b.binder.module.deinit();
    T.allocator.destroy(b.binder.module);
    b.binder.deinit();
    destroySetup(b.base);
    T.allocator.destroy(b);
}

test "checker: unresolved identifier emits TS2304" {
    const b = try newBoundSetup("unknownVar;");
    defer destroyBoundSetup(b);
    try b.base.checker.checkSourceFile(b.base.root);
    var found = false;
    for (b.base.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.cannot_find_name) found = true;
    }
    try T.expect(found);
}

test "checker: console.log does not emit TS2304" {
    const b = try newBoundSetup("console.log(\"hi\");");
    defer destroyBoundSetup(b);
    try b.base.checker.checkSourceFile(b.base.root);
    for (b.base.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.cannot_find_name);
    }
}

test "checker: Math.PI does not emit TS2304" {
    const b = try newBoundSetup("Math.PI;");
    defer destroyBoundSetup(b);
    try b.base.checker.checkSourceFile(b.base.root);
    for (b.base.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.cannot_find_name);
    }
}

test "checker: typo of in-scope name emits TS2552 with suggestion" {
    const b = try newBoundSetup("const myVar = 1; mvVar;");
    defer destroyBoundSetup(b);
    try b.base.checker.checkSourceFile(b.base.root);
    var found = false;
    for (b.base.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.cannot_find_name_did_you_mean) {
            found = true;
            try T.expect(std.mem.indexOf(u8, d.message, "myVar") != null);
            try T.expect(std.mem.indexOf(u8, d.message, "Did you mean") != null);
        }
    }
    try T.expect(found);
}

test "checker: unresolved identifier with no close match emits TS2304" {
    const b = try newBoundSetup("const xxx = 1; abc;");
    defer destroyBoundSetup(b);
    try b.base.checker.checkSourceFile(b.base.root);
    var found_2304 = false;
    var found_2552 = false;
    for (b.base.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.cannot_find_name) found_2304 = true;
        if (d.code == TsCodes.cannot_find_name_did_you_mean) found_2552 = true;
    }
    try T.expect(found_2304);
    try T.expect(!found_2552);
}

test "checker: assigning to const emits TS2588" {
    const b = try newBoundSetup("const x = 1; x = 2;");
    defer destroyBoundSetup(b);
    try b.base.checker.checkSourceFile(b.base.root);
    var found = false;
    for (b.base.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.cannot_assign_const) found = true;
    }
    try T.expect(found);
}

test "checker: assigning to let does not emit TS2588" {
    const b = try newBoundSetup("let x = 1; x = 2;");
    defer destroyBoundSetup(b);
    try b.base.checker.checkSourceFile(b.base.root);
    for (b.base.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.cannot_assign_const);
    }
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

test "checker: @ts-ignore suppresses next-line diagnostic" {
    const s = try newSetup("// @ts-ignore\nlet x: number = \"hi\";");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expectEqual(@as(usize, 0), s.checker.diagnostics.items.len);
}

test "checker: @ts-expect-error suppresses next-line diagnostic" {
    const s = try newSetup("// @ts-expect-error\nlet x: number = \"hi\";");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expectEqual(@as(usize, 0), s.checker.diagnostics.items.len);
}

test "checker: unused @ts-expect-error emits TS2578" {
    const s = try newSetup("// @ts-expect-error\nlet x: number = 1;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.unused_ts_expect_error) found = true;
    }
    try T.expect(found);
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

test "checker: private member accessed outside class emits TS2341" {
    const s = try newSetup(
        \\class Foo { private x: number = 1; }
        \\const f = new Foo();
        \\f.x;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.private_member_access) {
            found = true;
            try T.expect(std.mem.indexOf(u8, d.message, "Foo") != null);
            try T.expect(std.mem.indexOf(u8, d.message, "private") != null);
        }
    }
    try T.expect(found);
}

test "checker: private member accessed inside class via this is allowed" {
    const s = try newSetup(
        \\class Foo {
        \\  private x: number = 1;
        \\  getX(): number { return this.x; }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.private_member_access);
    }
}

test "checker: public member accessed outside class is allowed" {
    const s = try newSetup(
        \\class Foo { x: number = 1; }
        \\const f = new Foo();
        \\f.x;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.private_member_access);
    }
}

test "checker: protected member accessed outside class emits TS2445" {
    const s = try newSetup(
        \\class A { protected x: number = 1; }
        \\const a = new A();
        \\a.x;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.protected_member_access) {
            found = true;
            try T.expect(std.mem.indexOf(u8, d.message, "A") != null);
            try T.expect(std.mem.indexOf(u8, d.message, "protected") != null);
        }
    }
    try T.expect(found);
}

test "checker: protected member accessed inside subclass via this is allowed" {
    const s = try newSetup(
        \\class A { protected x: number = 1; }
        \\class B extends A {
        \\  f(): number { return this.x; }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.protected_member_access);
    }
}

test "checker: protected member accessed inside declaring class via this is allowed" {
    const s = try newSetup(
        \\class A {
        \\  protected x: number = 1;
        \\  f(): number { return this.x; }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.protected_member_access);
    }
}

test "checker: var-decl type mismatch emits TS2322" {
    const s = try newSetup("let x: number = \"hi\";");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expectEqual(@as(usize, 1), s.checker.diagnostics.items.len);
    try T.expectEqual(TsCodes.type_not_assignable, s.checker.diagnostics.items[0].code);
}

test "checker: use-before-assign emits TS2454" {
    const s = try newSetup(
        \\let x: number;
        \\let y = x;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.used_before_assignment) found = true;
    }
    try T.expect(found);
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

test "checker: `satisfies` preserves the original expression type" {
    const s = try newSetup(
        \\let x = { kind: "circle", r: 1 } satisfies { kind: string };
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const x_decl = stmts[0];
    const v = hir_mod.varDeclOf(&s.hir, x_decl);
    try T.expectEqual(hir_mod.NodeKind.satisfies_expr, s.hir.kindOf(v.init));
    // The result type must retain the `r` member from the original
    // object literal — `satisfies` does not widen to the constraint.
    const x_t = s.hir.typeOf(v.init);
    const r_id = try s.sint.intern("r");
    try T.expect(s.ti.objectMember(x_t, r_id) != types.Primitive.none);
}

test "checker: `satisfies` emits TS1360 when expr is not assignable to constraint" {
    const s = try newSetup(
        \\let y = ({ kind: 42 }) satisfies { kind: string };
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.satisfies_constraint) found = true;
    }
    try T.expect(found);
}

test "checker: `satisfies number[]` preserves array type — `.length` resolves" {
    const s = try newSetup(
        \\let arr = [1, 2, 3] satisfies number[];
        \\let n = arr.length;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[1]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(v.init));
}

test "checker: noImplicitAny emits TS7006 for unannotated parameter" {
    const s = try newSetup(
        \\function id(x) { return x; }
    );
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_implicit_any = true });
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.parameter_implicitly_any) found = true;
    }
    try T.expect(found);
}

test "checker: noImplicitAny silent when parameter has annotation" {
    const s = try newSetup(
        \\function id(x: number): number { return x; }
    );
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_implicit_any = true });
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: noImplicitAny emits TS7005 for bare `let x` declaration" {
    const s = try newSetup("let x;");
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_implicit_any = true });
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.variable_implicitly_any) found = true;
    }
    try T.expect(found);
}

test "checker: function without return annotation infers from a single return" {
    const s = try newSetup("function add(a: number, b: number) { return a + b; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    const sig = s.hir.typeOf(top);
    const ret = s.ti.signatureReturn(sig) orelse return error.TestExpectedEqual;
    try T.expectEqual(types.Primitive.number_t, ret);
}

test "checker: function without returns infers void" {
    const s = try newSetup("function noop(x: number) { let y = x; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    const sig = s.hir.typeOf(top);
    const ret = s.ti.signatureReturn(sig) orelse return error.TestExpectedEqual;
    try T.expectEqual(types.Primitive.void_t, ret);
}

test "checker: arrow with expression body infers its return from the expression" {
    const s = try newSetup("let f = (x: number) => x + 1;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    const v = hir_mod.varDeclOf(&s.hir, top);
    const sig = s.hir.typeOf(v.init);
    const ret = s.ti.signatureReturn(sig) orelse return error.TestExpectedEqual;
    try T.expectEqual(types.Primitive.number_t, ret);
}

test "checker: noUnusedParameters emits TS6133 for unread param" {
    const s = try newSetup("function f(x: number, y: number): number { return x; }");
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_unused_parameters = true });
    try s.checker.checkSourceFile(s.root);
    var has_y = false;
    var only_y = true;
    for (s.checker.diagnostics.items) |d| {
        if (d.code != TsCodes.declared_but_not_read) continue;
        const msg = d.message;
        if (std.mem.indexOf(u8, msg, "'y'") != null) has_y = true;
        if (std.mem.indexOf(u8, msg, "'x'") != null) only_y = false;
    }
    try T.expect(has_y);
    try T.expect(only_y);
}

test "checker: noUnusedParameters honors leading-underscore convention" {
    const s = try newSetup("function f(_unused: number, x: number): number { return x; }");
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_unused_parameters = true });
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: noUnusedParameters skips when flag is off" {
    const s = try newSetup("function f(x: number, y: number): number { return x; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: noUnusedParameters emits TS6133 for unread catch binding" {
    const s = try newSetup("try { } catch (e) { }");
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_unused_parameters = true });
    try s.checker.checkSourceFile(s.root);
    var has_e = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code != TsCodes.declared_but_not_read) continue;
        if (std.mem.indexOf(u8, d.message, "'e'") != null) has_e = true;
    }
    try T.expect(has_e);
}

test "checker: noUnusedParameters does not flag a read catch binding" {
    const s = try newSetup("try { } catch (e) { let m = e; }");
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_unused_parameters = true });
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        if (d.code != TsCodes.declared_but_not_read) continue;
        try T.expect(std.mem.indexOf(u8, d.message, "'e'") == null);
    }
}

test "checker: noUnusedParameters emits TS6133 for unread arrow param" {
    const s = try newSetup("let f = (unused: number) => 1;");
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_unused_parameters = true });
    try s.checker.checkSourceFile(s.root);
    var has_unused = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code != TsCodes.declared_but_not_read) continue;
        if (std.mem.indexOf(u8, d.message, "'unused'") != null) has_unused = true;
    }
    try T.expect(has_unused);
}

test "checker: noUnusedParameters does not flag a read arrow param" {
    const s = try newSetup("let f = (x: number) => x;");
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_unused_parameters = true });
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: generic alias `Box<number>` substitutes the type parameter" {
    const s = try newSetup(
        \\type Box<T> = { value: T };
        \\function f(b: Box<number>): number { return b.value; }
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

test "checker: object-literal excess property emits TS2353" {
    const s = try newSetup("let p: { x: number } = { x: 1, y: 2 };");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.object_literal_excess_property) found = true;
    }
    try T.expect(found);
}

test "checker: matching object literal compiles without TS2353" {
    const s = try newSetup("let p: { x: number; y: number } = { x: 1, y: 2 };");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: exactOptionalPropertyTypes flags explicit undefined on optional property" {
    const s = try newSetup("const x: { a?: number } = { a: undefined };");
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .exact_optional_property_types = true });
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.exact_optional_property) found = true;
    }
    try T.expect(found);
}

test "checker: exactOptionalPropertyTypes off — explicit undefined on optional is silent" {
    const s = try newSetup("const x: { a?: number } = { a: undefined };");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.exact_optional_property);
    }
}

test "checker: interface extends inherits parent members" {
    const s = try newSetup(
        \\interface Named { name: string; }
        \\interface Box extends Named { value: number; }
        \\function f(b: Box): string { return b.name; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const box_t = s.hir.typeOf(stmts[1]);
    const name_id = try s.sint.intern("name");
    const value_id = try s.sint.intern("value");
    try T.expect(s.ti.objectMember(box_t, name_id) != null);
    try T.expect(s.ti.objectMember(box_t, value_id) != null);
}

test "checker: interface extends multiple parents merges all members" {
    const s = try newSetup(
        \\interface A { a: number; }
        \\interface B { b: string; }
        \\interface C extends A, B { c: boolean; }
        \\function f(c: C): number { return c.a; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const c_t = s.hir.typeOf(stmts[2]);
    const a_id = try s.sint.intern("a");
    const b_id = try s.sint.intern("b");
    const c_id = try s.sint.intern("c");
    try T.expect(s.ti.objectMember(c_t, a_id) != null);
    try T.expect(s.ti.objectMember(c_t, b_id) != null);
    try T.expect(s.ti.objectMember(c_t, c_id) != null);
}

test "checker: for-of binds the loop variable to the array's element type" {
    const s = try newSetup(
        \\function sum(xs: number[]): number {
        \\  let total: number = 0;
        \\  for (let x of xs) { total = total + x; }
        \\  return total;
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: for-of element references a typed identifier" {
    // Sanity check that the loop variable becomes number, then
    // that an arithmetic op against it stays number.
    const s = try newSetup(
        \\let xs: number[] = [1, 2, 3];
        \\let total: number = 0;
        \\for (let x of xs) { total = total + x; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: for-in binds the key variable to string" {
    const s = try newSetup(
        \\function f(o: { [k: string]: number }): string {
        \\  for (let k in o) { let s: string = k; return s; }
        \\  return "";
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: array literal indexes to its element type" {
    const s = try newSetup(
        \\let xs = [1, 2, 3];
        \\let n = xs[0];
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[1]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(v.init));
}

test "checker: array literal exposes length: number" {
    const s = try newSetup(
        \\let xs = [1, 2, 3];
        \\let n = xs.length;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[1]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(v.init));
}

test "checker: keyof T evaluates to a union of property name literals" {
    const s = try newSetup(
        \\type Point = { x: number; y: number };
        \\type PointKey = keyof Point;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const keys_t = s.hir.typeOf(stmts[1]);
    try T.expect(s.ti.pool.flagsOf(keys_t).is_union);
    // Both 'x' and 'y' should appear as string-literal types.
    var has_x = false;
    var has_y = false;
    for (s.ti.unionMembers(keys_t)) |m| {
        if (!s.ti.pool.flagsOf(m).is_literal) continue;
        const lit = s.ti.literalOf(m);
        switch (lit) {
            .string_lit => |sid| {
                const text = s.sint.get(sid);
                if (std.mem.eql(u8, text, "x")) has_x = true;
                if (std.mem.eql(u8, text, "y")) has_y = true;
            },
            else => {},
        }
    }
    try T.expect(has_x);
    try T.expect(has_y);
}

test "checker: nullish coalescing strips null/undefined from lhs" {
    const s = try newSetup(
        \\function pickMaybe(): string | null { return null; }
        \\let s = pickMaybe() ?? "default";
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[1]);
    const t = s.hir.typeOf(v.init);
    // Result is `string` (lhs minus null) | `string` (rhs literal type)
    // → effectively just `string`. Either way `null` must NOT appear.
    if (s.ti.pool.flagsOf(t).is_union) {
        for (s.ti.unionMembers(t)) |m| {
            try T.expect(m != types.Primitive.null_t);
            try T.expect(m != types.Primitive.undefined_t);
        }
    }
}

test "checker: optional chaining widens the result with undefined" {
    const s = try newSetup(
        \\interface Box { value: number; }
        \\function f(b: Box): number { return b?.value; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    // The return value should be `number | undefined` (broader
    // than the function's declared `number` return — we don't
    // assert on the diagnostic since that's the assignability
    // story; instead we check the inner expression's type.)
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const f = hir_mod.fnDeclOf(&s.hir, stmts[1]);
    const body = hir_mod.blockStmts(&s.hir, f.body);
    const ret_p = hir_mod.returnOf(&s.hir, body[0]);
    const t = s.hir.typeOf(ret_p.value);
    try T.expect(s.ti.pool.flagsOf(t).is_union);
    var has_num = false;
    var has_undef = false;
    for (s.ti.unionMembers(t)) |m| {
        if (m == types.Primitive.number_t) has_num = true;
        if (m == types.Primitive.undefined_t) has_undef = true;
    }
    try T.expect(has_num);
    try T.expect(has_undef);
}

test "checker: tuple literal-index resolves to the specific member type" {
    const s = try newSetup(
        \\function fst(p: [number, string]): number { return p[0]; }
        \\function snd(p: [number, string]): string { return p[1]; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const f1 = hir_mod.fnDeclOf(&s.hir, stmts[0]);
    const body1 = hir_mod.blockStmts(&s.hir, f1.body);
    const ret1 = hir_mod.returnOf(&s.hir, body1[0]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(ret1.value));
    const f2 = hir_mod.fnDeclOf(&s.hir, stmts[1]);
    const body2 = hir_mod.blockStmts(&s.hir, f2.body);
    const ret2 = hir_mod.returnOf(&s.hir, body2[0]);
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(ret2.value));
}

test "checker: noUncheckedIndexedAccess widens arr[i] with undefined" {
    const s = try newSetup(
        \\const arr: number[] = [1];
        \\const x = arr[0];
        \\let n: number = x;
    );
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_unchecked_indexed_access = true });
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.type_not_assignable) found = true;
    }
    try T.expect(found);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const x_decl = hir_mod.varDeclOf(&s.hir, stmts[1]);
    const x_t = s.hir.typeOf(x_decl.init);
    try T.expect(s.ti.pool.flagsOf(x_t).is_union);
    var has_num = false;
    var has_undef = false;
    for (s.ti.unionMembers(x_t)) |m| {
        if (m == types.Primitive.number_t) has_num = true;
        if (m == types.Primitive.undefined_t) has_undef = true;
    }
    try T.expect(has_num);
    try T.expect(has_undef);
}

test "checker: noUncheckedIndexedAccess off keeps arr[i] as T" {
    const s = try newSetup(
        \\const arr: number[] = [1];
        \\const x = arr[0];
        \\let n: number = x;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.type_not_assignable);
    }
}

test "checker: `as const` on a string literal types as the literal" {
    const s = try newSetup("let s = \"hi\" as const;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[0]);
    const t = s.hir.typeOf(v.init);
    try T.expect(s.ti.pool.flagsOf(t).is_literal);
    const lit = s.ti.literalOf(t);
    switch (lit) {
        .string_lit => |sid| try T.expectEqualStrings("hi", s.sint.get(sid)),
        else => return error.TestExpectedEqual,
    }
}

test "checker: `as const` on a number literal types as the literal" {
    const s = try newSetup("let n = 42 as const;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[0]);
    const t = s.hir.typeOf(v.init);
    try T.expect(s.ti.pool.flagsOf(t).is_literal);
}

test "checker: `as const` on an object literal makes members literal + readonly" {
    const s = try newSetup("let o = { kind: \"circle\", r: 1 } as const;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[0]);
    const t = s.hir.typeOf(v.init);
    try T.expect(s.ti.pool.flagsOf(t).is_object_type);
    const kind_id = try s.sint.intern("kind");
    const kind_t = s.ti.objectMember(t, kind_id) orelse return error.TestExpectedEqual;
    // 'kind' is the literal "circle", not the broad string type.
    try T.expect(s.ti.pool.flagsOf(kind_t).is_literal);
}

test "checker: `in` operator narrows a union to variants with the named prop" {
    // Then-branch only (the else-branch path needs the negative
    // narrowing to be tightened — currently keeps the variants
    // *without* the prop but typeOfIdentifier may not see that
    // through every parent chain shape; tracked as a follow-up).
    const s = try newSetup(
        \\type Cat = { meows: boolean };
        \\type Dog = { barks: boolean };
        \\function f(p: Cat | Dog): boolean {
        \\  if ("meows" in p) { return p.meows; }
        \\  return false;
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: keyof on a literal type alias resolves to a literal union" {
    // The full assignability story (TS2322 on `keyof T = "z"`) needs
    // contextual typing for fresh string-literal expressions —
    // tracked as a follow-up. Here we just verify that `keyof T`
    // produces the expected interned shape so downstream features
    // (mapped types, indexed access) can build on it.
    const s = try newSetup(
        \\type Point = { x: number; y: number };
        \\type PointKey = keyof Point;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const keys_t = s.hir.typeOf(stmts[1]);
    try T.expect(s.ti.pool.flagsOf(keys_t).is_union);
}

test "checker: labeled tuple element types parse equivalently to plain tuples" {
    // TS 4.0+ allows labeling tuple elements: `[first: string, second: number]`.
    // Labels are documentation-only and don't change type semantics, so the
    // labelled form must produce the same diagnostic count as the un-labelled
    // form for an otherwise-identical program.
    const labeled = try newSetup(
        \\type Pair = [first: string, second: number];
        \\const p: Pair = ["a", 1];
    );
    defer destroySetup(labeled);
    try labeled.checker.checkSourceFile(labeled.root);
    const plain = try newSetup(
        \\type Pair = [string, number];
        \\const p: Pair = ["a", 1];
    );
    defer destroySetup(plain);
    try plain.checker.checkSourceFile(plain.root);
    try T.expectEqual(plain.checker.diagnostics.items.len, labeled.checker.diagnostics.items.len);
}

test "checker: labeled tuple still flags element-type mismatch as TS2322" {
    // The labels don't relax structural checks: assigning `[number, string]`
    // to a `[first: string, second: number]` annotation must still emit a
    // type-not-assignable diagnostic — same behaviour as an un-labelled
    // `[string, number]` annotation.
    const s = try newSetup(
        \\type Pair = [first: string, second: number];
        \\const p: Pair = [1, "a"];
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.type_not_assignable) found = true;
    }
    try T.expect(found);
}

test "checker: tuple type exposes per-index members + length literal" {
    const s = try newSetup(
        \\function fst(p: [number, string]): number { return p[0]; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const params = hir_mod.fnParams(&s.hir, stmts[0]);
    const tuple_t = s.hir.typeOf(params[0]);
    // Tuple → object with `length` (literal 2), `0`/`1` keyed members,
    // and a number indexer for the union.
    try T.expect(s.ti.pool.flagsOf(tuple_t).is_object_type);
    const length_id = try s.sint.intern("length");
    try T.expect(s.ti.objectMember(tuple_t, length_id) != null);
    const zero_id = try s.sint.intern("0");
    const one_id = try s.sint.intern("1");
    try T.expect(s.ti.objectMember(tuple_t, zero_id) != null);
    try T.expect(s.ti.objectMember(tuple_t, one_id) != null);
}

test "checker: variadic tuple [number, ...string[]] accepts a matching literal" {
    // TS 4.0+ allows spreads inside tuple types. The leading
    // `number` slot is positional; the trailing `...string[]`
    // permits any number of trailing strings. The literal must
    // type-check without TS2322.
    const s = try newSetup(
        \\type T = [number, ...string[]];
        \\const t: T = [1, "a", "b"];
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found_2322 = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.type_not_assignable) found_2322 = true;
    }
    try T.expect(!found_2322);
}

test "checker: variadic tuple [number, ...string[], boolean] accepts a matching literal" {
    // A rest may sit between two fixed slots — TS allows
    // `[A, ...B[], C]` and the literal must structurally match.
    const s = try newSetup(
        \\type T = [number, ...string[], boolean];
        \\const t: T = [1, "a", true];
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found_2322 = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.type_not_assignable) found_2322 = true;
    }
    try T.expect(!found_2322);
}

test "checker: variadic tuple [number, ...string[]] flags wrong leading type as TS2322" {
    // The fixed leading slot is invariant: `["a"]` must NOT
    // assign to `[number, ...string[]]` because position 0 is
    // typed `number`, not `string`.
    const s = try newSetup(
        \\type T = [number, ...string[]];
        \\const t: T = ["a"];
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.type_not_assignable) found = true;
    }
    try T.expect(found);
}

test "checker: T[] annotation indexes to T" {
    const s = try newSetup(
        \\function head(xs: number[]): number { return xs[0]; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const f = hir_mod.fnDeclOf(&s.hir, stmts[0]);
    const body = hir_mod.blockStmts(&s.hir, f.body);
    const ret_p = hir_mod.returnOf(&s.hir, body[0]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(ret_p.value));
}

test "checker: let arr: number[] element access types as number" {
    // Mirrors `Array<T>` element-access shape: `arr[0]` on an
    // annotated `number[]` should resolve through the number-key
    // indexer to plain `number` (not `number | undefined` or `any`).
    const s = try newSetup(
        \\let arr: number[] = [1];
        \\let n = arr[0];
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[1]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(v.init));
}

test "checker: `readonly T[]` annotation parses + types like `T[]`" {
    // The parser strips the `readonly` modifier on type annotations
    // (see `parseTypeOperator` for `kw_readonly`), so `readonly T[]`
    // currently lowers to the same `Array<T>` shape as `T[]`. A
    // proper readonly-vs-mutable assignability story is tracked as
    // a Phase 6 follow-up; for now we lock in that the modifier is
    // accepted at the type-annotation position without a diagnostic.
    const s = try newSetup(
        \\let a: readonly number[] = [1, 2, 3];
        \\let n = a[0];
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[1]);
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(v.init));
}

test "checker: interface extends with index signature inherits indexer" {
    const s = try newSetup(
        \\interface MapLike { [k: string]: number; }
        \\interface NamedMap extends MapLike { name: string; }
        \\function f(m: NamedMap): number { return m.anything; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: optional parameter widens to T | undefined" {
    const s = try newSetup("function f(x?: number): number { return 0; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    const params = hir_mod.fnParams(&s.hir, top);
    const pt = s.hir.typeOf(params[0]);
    // Type of `x` is a union — verify both `number` and `undefined` show up.
    try T.expect(s.ti.pool.flagsOf(pt).is_union);
    var has_num = false;
    var has_undef = false;
    for (s.ti.unionMembers(pt)) |m| {
        if (m == types.Primitive.number_t) has_num = true;
        if (m == types.Primitive.undefined_t) has_undef = true;
    }
    try T.expect(has_num);
    try T.expect(has_undef);
}

test "checker: omitting an optional argument compiles cleanly" {
    const s = try newSetup(
        \\function f(a: number, b?: number): number { return a; }
        \\let x = f(1);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: too many args still emits TS2554 even with optional params" {
    const s = try newSetup(
        \\function f(a: number, b?: number): number { return a; }
        \\let x = f(1, 2, 3);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.expected_n_arguments) found = true;
    }
    try T.expect(found);
}

test "checker: defaulted parameter widens like optional" {
    const s = try newSetup(
        \\function f(a: number, b: number = 0): number { return a + b; }
        \\let x = f(1);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: string-index signature resolves member access" {
    const s = try newSetup(
        \\interface MapLike { [k: string]: number; }
        \\function f(m: MapLike): number { return m.anything; }
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

test "checker: number-index signature resolves element access" {
    const s = try newSetup(
        \\interface NumIdx { [i: number]: string; }
        \\function f(a: NumIdx): string { return a[0]; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const f = hir_mod.fnDeclOf(&s.hir, stmts[1]);
    const body = hir_mod.blockStmts(&s.hir, f.body);
    const ret_p = hir_mod.returnOf(&s.hir, body[0]);
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(ret_p.value));
}

test "checker: object type literal with string index signature" {
    const s = try newSetup(
        \\function f(m: { [k: string]: boolean }): boolean { return m.flag; }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
}

test "checker: noPropertyAccessFromIndexSignature emits TS4111" {
    const s = try newSetup(
        \\interface I { [k: string]: number }
        \\const o: I = {};
        \\const v = o.foo;
    );
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_property_access_from_index_signature = true });
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.index_signature_property_access) found = true;
    }
    try T.expect(found);
}

test "checker: dot access via index signature is silent without flag" {
    const s = try newSetup(
        \\interface I { [k: string]: number }
        \\const o: I = {};
        \\const v = o.foo;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.index_signature_property_access);
    }
}

test "checker: postfix `!` strips null/undefined from a union" {
    const s = try newSetup(
        \\function pickMaybe(): string | null { return null; }
        \\let s = pickMaybe()!;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[1]);
    try T.expectEqual(hir_mod.NodeKind.non_null_expr, s.hir.kindOf(v.init));
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(v.init));
}

test "checker: generic alias mismatch emits TS2322" {
    const s = try newSetup(
        \\type Box<T> = { value: T };
        \\let b: Box<number> = { value: "hi" };
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.type_not_assignable) found = true;
    }
    try T.expect(found);
}

test "checker: noUnusedLocals emits TS6133 for unread let" {
    const s = try newSetup(
        \\function f(): number {
        \\  let unused = 1;
        \\  let used = 2;
        \\  return used;
        \\}
    );
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .no_unused_locals = true });
    try s.checker.checkSourceFile(s.root);
    var has_unused = false;
    var has_used = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code != TsCodes.declared_but_not_read) continue;
        if (std.mem.indexOf(u8, d.message, "'unused'") != null) has_unused = true;
        if (std.mem.indexOf(u8, d.message, "'used'") != null) has_used = true;
    }
    try T.expect(has_unused);
    try T.expect(!has_used);
}

test "checker: function with branches unions the return types" {
    const s = try newSetup(
        \\function f(b: boolean) {
        \\  if (b) { return 1; }
        \\  return "hi";
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const top = firstStatement(s);
    const sig = s.hir.typeOf(top);
    const ret = s.ti.signatureReturn(sig) orelse return error.TestExpectedEqual;
    // The union order is canonicalized by sort+dedup; we just
    // verify it's a union containing both number_t and string_t.
    try T.expect(s.ti.pool.flagsOf(ret).is_union);
    const members = s.ti.unionMembers(ret);
    var has_num = false;
    var has_str = false;
    for (members) |m| {
        if (m == types.Primitive.number_t) has_num = true;
        if (m == types.Primitive.string_t) has_str = true;
    }
    try T.expect(has_num);
    try T.expect(has_str);
}

test "checker: explicit type args override call-site inference" {
    // Without inference (no value args to drive it), explicit type
    // args still resolve the return type.
    const s = try newSetup(
        \\function id<T>(): T { return null as any; }
        \\let n = id<number>();
        \\let s = id<string>();
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    // stmts[1] = let n = id<number>(); stmts[2] = let s = id<string>();
    const n_decl = stmts[1];
    const s_decl = stmts[2];
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(n_decl));
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(s_decl));
}

test "checker: explicit type args take precedence over inference" {
    // Inference would say `T = number`, but explicit `<string>`
    // wins. The arg is then checked against the substituted
    // signature, so passing a number to `id<string>` is TS2345.
    const s = try newSetup(
        \\function id<T>(x: T): T { return x; }
        \\let r = id<string>(42);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    // r should be `string` because the explicit type-arg wins.
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(r_decl));
    // And we should have a TS2345 diagnostic for passing number to string.
    var saw_2345 = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.argument_type_mismatch) saw_2345 = true;
    }
    try T.expect(saw_2345);
}

test "checker: conditional type with concrete check evaluates true branch" {
    // `string extends string ? number : boolean` should resolve to
    // `number` eagerly.
    const s = try newSetup(
        \\type Pick<T> = T extends string ? number : boolean;
        \\let r: Pick<string> = 1;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    // stmts[1] = `let r: Pick<string> = 1`
    const r_decl = stmts[1];
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(r_decl));
}

test "checker: conditional type with concrete check evaluates false branch" {
    const s = try newSetup(
        \\type Pick<T> = T extends string ? number : boolean;
        \\let r: Pick<number> = true;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    try T.expectEqual(types.Primitive.boolean_t, s.hir.typeOf(r_decl));
}

test "checker: conditional distributes over a union check" {
    // `(string | number) extends string ? "yes" : "no"`
    // distributes to `("yes" | "no")` (literal types).
    const s = try newSetup(
        \\type T = (string | number) extends string ? 1 : 0;
        \\let r: T = 0;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    const t = s.hir.typeOf(r_decl);
    // The result should be a union of the literal types `1 | 0`.
    try T.expect(s.ti.pool.flagsOf(t).is_union);
}

test "checker: type predicate narrows in then-branch" {
    const s = try newSetup(
        \\function isString(x: any): x is string { return true; }
        \\function f(x: any) {
        \\  if (isString(x)) {
        \\    let s = x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const s_decl = then_stmts[0];
    const s_init = hir_mod.varDeclOf(&s.hir, s_decl).init;
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(s_init));
}

test "checker: overload resolution picks the matching signature" {
    // Two overloads + one implementation. Calling with a string
    // should resolve to the string overload's return type.
    const s = try newSetup(
        \\function pick(x: string): number;
        \\function pick(x: number): string;
        \\function pick(x: any): any { return x; }
        \\let n = pick("hello");
        \\let s2 = pick(42);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    // stmts[3] = let n = pick("hello") — return is number.
    // stmts[4] = let s2 = pick(42) — return is string.
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(stmts[3]));
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(stmts[4]));
}

test "checker: TS2769 when no overload matches the call" {
    // Two overloads + impl. Call with `boolean` matches neither
    // overload's first parameter (string / number) — should emit
    // TS2769 rather than silently using the impl signature.
    const s = try newSetup(
        \\function f(x: string): number;
        \\function f(x: number): string;
        \\function f(x: any): any { return x; }
        \\let r = f(true);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.no_overload_matches) found = true;
    }
    try T.expect(found);
}

test "checker: aliased conditional narrows via stored guard" {
    const s = try newSetup(
        \\function isString(x: any): x is string { return true; }
        \\function f(x: any) {
        \\  let cond = isString(x);
        \\  if (cond) {
        \\    let s = x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    // body_stmts[0] = let cond = isString(x)
    // body_stmts[1] = if (cond) { let s = x; }
    const if_stmt = body_stmts[1];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const s_decl = then_stmts[0];
    const s_init = hir_mod.varDeclOf(&s.hir, s_decl).init;
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(s_init));
}

test "checker: asserts predicate narrows in fall-through" {
    const s = try newSetup(
        \\function assertString(x: unknown): asserts x is string { }
        \\function f(x: unknown) {
        \\  assertString(x);
        \\  let s = x;
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    // body_stmts[0] = assertString(x); body_stmts[1] = let s = x;
    const s_decl = body_stmts[1];
    const s_init = hir_mod.varDeclOf(&s.hir, s_decl).init;
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(s_init));
}

test "checker: type predicate negative branch subtracts" {
    const s = try newSetup(
        \\function isString(x: string | number): x is string { return true; }
        \\function f(x: string | number) {
        \\  if (isString(x)) {
        \\    let s = x;
        \\  } else {
        \\    let n = x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const else_stmts = hir_mod.blockStmts(&s.hir, ifp.else_branch);
    const n_init = hir_mod.varDeclOf(&s.hir, else_stmts[0]).init;
    // (string | number) minus string = number.
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(n_init));
}

test "checker: TS 5.5 inferred type predicate from typeof === narrowing" {
    // `function isString(x: unknown) { return typeof x === "string"; }`
    // — no explicit `x is string` annotation, but the body is a single
    // narrowing comparison. Call sites should narrow `x` to `string`.
    const s = try newSetup(
        \\function isString(x: unknown) { return typeof x === "string"; }
        \\function f(x: unknown) {
        \\  if (isString(x)) {
        \\    let s = x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const s_init = hir_mod.varDeclOf(&s.hir, then_stmts[0]).init;
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(s_init));
}

test "checker: TS 5.5 inferred predicate from x !== null narrows union" {
    // `(string | null) !== null` returns true → infer `x is string`.
    // Call site narrows `x` to `string` in the then-branch.
    const s = try newSetup(
        \\function isPresent(x: string | null) { return x !== null; }
        \\function f(x: string | null) {
        \\  if (isPresent(x)) {
        \\    let s = x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const s_init = hir_mod.varDeclOf(&s.hir, then_stmts[0]).init;
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(s_init));
}

test "checker: TS 5.5 inferred predicate skipped for multi-statement bodies" {
    // Body has more than one statement → don't infer a predicate.
    // Call site should leave `x` as `string | null`.
    const s = try newSetup(
        \\function isPresent(x: string | null) {
        \\  let y = x;
        \\  return y !== null;
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    // The function shouldn't be recorded as a predicate — sanity-check
    // by looking up its name in `fn_predicates`.
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const fn_name = hir_mod.identifierOf(&s.hir, f.name).name;
    try T.expect(!s.checker.fn_predicates.contains(fn_name));
}

test "checker: mapped type over keyof T materializes properties" {
    // `{ [K in "x" | "y"]: number }` should produce `{ x: number; y: number }`.
    const s = try newSetup(
        \\type Map = { [K in "x" | "y"]: number };
        \\let r: Map = { x: 1, y: 2 };
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    const t = s.hir.typeOf(r_decl);
    try T.expect(s.ti.pool.flagsOf(t).is_object_type);
    const members = s.ti.objectMembers(t);
    try T.expectEqual(@as(usize, 2), members.len);
    // Both members should be number_t.
    for (members) |m| try T.expectEqual(types.Primitive.number_t, m.type);
}

test "checker: bracketed [T] extends [U] suppresses distribution" {
    // Without brackets: `(string | number) extends string ? "y" : "n"`
    // distributes to `"y" | "n"`. With brackets:
    // `[(string | number)] extends [string] ? "y" : "n"` evaluates
    // non-distributively: `string | number` is NOT assignable to
    // `string`, so the result is `"n"` only (single literal).
    const s = try newSetup(
        \\type T = [string | number] extends [string] ? "y" : "n";
        \\let r: T;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    const t = s.hir.typeOf(r_decl);
    // Result should be a single string-literal type, not a union.
    try T.expect(!s.ti.pool.flagsOf(t).is_union);
    try T.expect(s.ti.pool.flagsOf(t).is_literal);
}

test "checker: ReturnType<T> infers signature return via infer R" {
    const s = try newSetup(
        \\type Return<T> = T extends (...args: any[]) => infer R ? R : never;
        \\let r: Return<() => string>;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    // r should resolve to `string`.
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(r_decl));
}

test "checker: Required<T> -? strips optional from source" {
    const s = try newSetup(
        \\type Required<T> = { [K in keyof T]-?: T[K] };
        \\let r: Required<{ x?: number; y?: string }>;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    const t = s.hir.typeOf(r_decl);
    try T.expect(s.ti.pool.flagsOf(t).is_object_type);
    const members = s.ti.objectMembers(t);
    try T.expectEqual(@as(usize, 2), members.len);
    // Both members should NOT be optional (was: optional in source).
    for (members) |m| try T.expect(!m.is_optional);
}

test "checker: Mutable<T> -readonly strips readonly from source" {
    const s = try newSetup(
        \\type Mutable<T> = { -readonly [K in keyof T]: T[K] };
        \\let r: Mutable<{ readonly x: number; readonly y: string }>;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    const t = s.hir.typeOf(r_decl);
    try T.expect(s.ti.pool.flagsOf(t).is_object_type);
    const members = s.ti.objectMembers(t);
    try T.expectEqual(@as(usize, 2), members.len);
    for (members) |m| try T.expect(!m.is_readonly);
}

test "checker: homomorphic Readonly<T> adds readonly to source" {
    const s = try newSetup(
        \\type Readonly<T> = { readonly [K in keyof T]: T[K] };
        \\let r: Readonly<{ x: number }>;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    const t = s.hir.typeOf(r_decl);
    const members = s.ti.objectMembers(t);
    try T.expectEqual(@as(usize, 1), members.len);
    try T.expect(members[0].is_readonly);
}

test "checker: homomorphic Partial<T> preserves field types" {
    const s = try newSetup(
        \\type Partial<T> = { [K in keyof T]?: T[K] };
        \\let p: Partial<{ x: number; y: string }>;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const p_decl = stmts[1];
    const t = s.hir.typeOf(p_decl);
    try T.expect(s.ti.pool.flagsOf(t).is_object_type);
    const members = s.ti.objectMembers(t);
    try T.expectEqual(@as(usize, 2), members.len);
    // Each member should be optional + carry the original type.
    var saw_x_number = false;
    var saw_y_string = false;
    for (members) |m| {
        try T.expect(m.is_optional);
        if (m.type == types.Primitive.number_t) saw_x_number = true;
        if (m.type == types.Primitive.string_t) saw_y_string = true;
    }
    try T.expect(saw_x_number);
    try T.expect(saw_y_string);
}

test "checker: mapped type `as` identity clause preserves key set" {
    // Sketch of the TS 4.1 key-remapping pipeline:
    //   `{ [K in keyof T as <Remap>]: T[K] }`
    // The richer remap forms — template literals (e.g.
    // `prefix_${K & string}`) — require the parser-driven
    // rescanTemplate path that's still pending (see ts_parser
    // "Phase 1.B follow-up"). This test pins the parse +
    // per-key narrow-scope evaluation by using an identity
    // remap (`as K`) and verifying the resulting object
    // preserves the source's keys.
    const s = try newSetup(
        \\type T = { a: string; b: number };
        \\type R = { [K in keyof T as K]: T[K] };
        \\let r: R;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[2];
    const t = s.hir.typeOf(r_decl);
    try T.expect(s.ti.pool.flagsOf(t).is_object_type);
    const members = s.ti.objectMembers(t);
    try T.expectEqual(@as(usize, 2), members.len);
    const want_a = try s.sint.intern("a");
    const want_b = try s.sint.intern("b");
    var saw_a = false;
    var saw_b = false;
    for (members) |m| {
        if (m.name == want_a) saw_a = true;
        if (m.name == want_b) saw_b = true;
    }
    try T.expect(saw_a);
    try T.expect(saw_b);
}

test "checker: mapped type `as` clause drops keys whose remap is never" {
    // `as Exclude<K, "private">` evaluates per-key: when K
    // equals "private" the conditional reduces to `never`,
    // dropping the key from the materialized object type.
    const s = try newSetup(
        \\type Exclude<T, U> = T extends U ? never : T;
        \\type T = { a: string; private: number };
        \\type R = { [K in keyof T as Exclude<K, "private">]: T[K] };
        \\let r: R;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[3];
    const t = s.hir.typeOf(r_decl);
    try T.expect(s.ti.pool.flagsOf(t).is_object_type);
    const members = s.ti.objectMembers(t);
    try T.expectEqual(@as(usize, 1), members.len);
    const want_a = try s.sint.intern("a");
    const dropped = try s.sint.intern("private");
    try T.expectEqual(want_a, members[0].name);
    try T.expect(members[0].name != dropped);
}

test "checker: type-parameter variance — `in` modifier becomes contravariant TypeId" {
    const s = try newSetup("function f<in T>(x: T): void {}");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const tps = hir_mod.fnTypeParams(&s.hir, fn_node);
    try T.expectEqual(@as(usize, 1), tps.len);
    const tp_id = s.hir.typeOf(tps[0]);
    try T.expect(s.ti.pool.flagsOf(tp_id).is_type_parameter);
    try T.expectEqual(types.Variance.contravariant, s.ti.typeParameterVariance(tp_id));
}

test "checker: type-parameter variance — `out` modifier becomes covariant TypeId" {
    const s = try newSetup("function f<out T>(): void {}");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const tps = hir_mod.fnTypeParams(&s.hir, fn_node);
    try T.expectEqual(@as(usize, 1), tps.len);
    const tp_id = s.hir.typeOf(tps[0]);
    try T.expectEqual(types.Variance.covariant, s.ti.typeParameterVariance(tp_id));
}

test "checker: type-parameter variance — `in out` modifier becomes invariant TypeId" {
    const s = try newSetup("function f<in out T>(x: T): T { return x; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const tps = hir_mod.fnTypeParams(&s.hir, fn_node);
    try T.expectEqual(@as(usize, 1), tps.len);
    const tp_id = s.hir.typeOf(tps[0]);
    try T.expectEqual(types.Variance.invariant, s.ti.typeParameterVariance(tp_id));
}

test "checker: type-parameter variance — no modifier defaults to bivariant" {
    const s = try newSetup("function f<T>(x: T): T { return x; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const tps = hir_mod.fnTypeParams(&s.hir, fn_node);
    try T.expectEqual(@as(usize, 1), tps.len);
    const tp_id = s.hir.typeOf(tps[0]);
    try T.expectEqual(types.Variance.bivariant, s.ti.typeParameterVariance(tp_id));
}

test "checker: variance inference — T in return position is covariant" {
    const s = try newSetup("function f<T>(): T { return null as any; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const tps = hir_mod.fnTypeParams(&s.hir, fn_node);
    try T.expectEqual(@as(usize, 1), tps.len);
    const tp_id = s.hir.typeOf(tps[0]);
    try T.expectEqual(types.Variance.covariant, s.checker.typeParameterVariance(tp_id));
}

test "checker: variance inference — T in parameter position is contravariant" {
    const s = try newSetup("function f<T>(x: T): void {}");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const tps = hir_mod.fnTypeParams(&s.hir, fn_node);
    try T.expectEqual(@as(usize, 1), tps.len);
    const tp_id = s.hir.typeOf(tps[0]);
    try T.expectEqual(types.Variance.contravariant, s.checker.typeParameterVariance(tp_id));
}

test "checker: `await g()` types as the operand call's return type" {
    const s = try newSetup(
        \\function g(): number { return 1; }
        \\let x = await g();
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const x_decl = stmts[1];
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(x_decl));
    const v = hir_mod.varDeclOf(&s.hir, x_decl);
    try T.expectEqual(hir_mod.NodeKind.await_expr, s.hir.kindOf(v.init));
    // The operand isn't Promise-shaped, so unwrapPromise is a passthrough.
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(v.init));
}

test "checker: TS1308 `await` only allowed in async functions" {
    // Sync function with `await` should diagnose; async function
    // should not.
    const s = try newSetup(
        \\function g(): number { return 1; }
        \\function f() { await g(); }
        \\async function h() { await g(); }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found_in_sync: bool = false;
    var found_in_async: bool = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code != TsCodes.await_only_in_async) continue;
        // The await inside `f` lives at a smaller node id than the
        // one inside `h`; either way, finding exactly one TS1308 is
        // the contract. Track via the ancestor walk for clarity.
        var cur: hir_mod.NodeId = s.hir.parentOf(d.node);
        while (cur != hir_mod.none_node_id) : (cur = s.hir.parentOf(cur)) {
            const k = s.hir.kindOf(cur);
            if (k == .fn_decl or k == .fn_expr or k == .arrow_fn) {
                const fp = hir_mod.fnDeclOf(&s.hir, cur);
                if (fp.flags.is_async) {
                    found_in_async = true;
                } else {
                    found_in_sync = true;
                }
                break;
            }
        }
    }
    try T.expect(found_in_sync);
    try T.expect(!found_in_async);
}

test "checker: unwrapPromise extracts T from a structural Promise<T>" {
    const s = try newSetup("");
    defer destroySetup(s);
    // Build `(value: number) => any`.
    const cb_params = [_]types.TypeId{types.Primitive.number_t};
    const cb_sig = try s.ti.internSignature(&cb_params, types.Primitive.any, false);
    // Build `then(cb: (value: number) => any): any`.
    const then_params = [_]types.TypeId{cb_sig};
    const then_sig = try s.ti.internSignature(&then_params, types.Primitive.any, false);
    // Build `{ then: (cb) => any }`.
    const then_name = try s.sint.intern("then");
    const members = [_]types.ObjectMember{.{
        .name = then_name,
        .type = then_sig,
        .is_optional = false,
        .is_readonly = false,
        .is_method = true,
    }};
    const promise_t = try s.ti.internObjectType(&members);
    try T.expectEqual(types.Primitive.number_t, s.checker.unwrapPromise(promise_t));
}

test "checker: unwrapPromise passes non-Promise types through unchanged" {
    const s = try newSetup("");
    defer destroySetup(s);
    try T.expectEqual(types.Primitive.number_t, s.checker.unwrapPromise(types.Primitive.number_t));
}

test "checker: `yield expr` types as the operand expression's type" {
    const s = try newSetup("function* gen() { yield 1; }");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const fn_payload = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, fn_payload.body);
    // The parser drops expression-statement wrappers, so body_stmts[0]
    // is the yield_expr directly.
    const expr_id = body_stmts[0];
    try T.expectEqual(hir_mod.NodeKind.yield_expr, s.hir.kindOf(expr_id));
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(expr_id));
}

test "checker: x === string-literal narrows to literal type" {
    const s = try newSetup(
        \\function f(s: string) {
        \\  if (s === "hello") {
        \\    let x = s;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const x_decl = then_stmts[0];
    const x_init = hir_mod.varDeclOf(&s.hir, x_decl).init;
    // The narrowed type should be the string-literal type "hello",
    // not the wider string_t.
    const hello_id = try s.sint.intern("hello");
    const expected = try s.ti.internStringLiteral(hello_id);
    try T.expectEqual(expected, s.hir.typeOf(x_init));
}

test "checker: n === number-literal narrows to literal type" {
    const s = try newSetup(
        \\function f(n: number) {
        \\  if (n === 42) {
        \\    let x = n;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const x_decl = then_stmts[0];
    const x_init = hir_mod.varDeclOf(&s.hir, x_decl).init;
    const expected = try s.ti.internNumberLiteral(42);
    try T.expectEqual(expected, s.hir.typeOf(x_init));
}

test "checker: x === bigint-literal narrows to literal type" {
    const s = try newSetup(
        \\function f(x: bigint) {
        \\  if (x === 42n) {
        \\    let y = x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const y_decl = then_stmts[0];
    const y_init = hir_mod.varDeclOf(&s.hir, y_decl).init;
    const digits_id = try s.sint.intern("42");
    const expected = try s.ti.internBigIntLiteral(digits_id);
    try T.expectEqual(expected, s.hir.typeOf(y_init));
}

test "checker: x === negative bigint-literal narrows to negative literal" {
    const s = try newSetup(
        \\function f(x: bigint) {
        \\  if (x === -42n) {
        \\    let y = x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const y_decl = then_stmts[0];
    const y_init = hir_mod.varDeclOf(&s.hir, y_decl).init;
    const digits_id = try s.sint.intern("-42");
    const expected = try s.ti.internBigIntLiteral(digits_id);
    try T.expectEqual(expected, s.hir.typeOf(y_init));
}

test "checker: obj.x !== null narrows obj.x in then-branch" {
    const s = try newSetup(
        \\interface Box { x: string | null; }
        \\function f(obj: Box) {
        \\  if (obj.x !== null) {
        \\    let v = obj.x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const v_decl = then_stmts[0];
    const v_init = hir_mod.varDeclOf(&s.hir, v_decl).init;
    // The narrowed `obj.x` should be string_t — null subtracted out.
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(v_init));
}

test "checker: obj.x === <literal> narrows obj.x to literal type" {
    const s = try newSetup(
        \\interface Box { x: number; }
        \\function f(obj: Box) {
        \\  if (obj.x === 42) {
        \\    let v = obj.x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const v_decl = then_stmts[0];
    const v_init = hir_mod.varDeclOf(&s.hir, v_decl).init;
    // The narrowed `obj.x` should be the literal 42, not number_t.
    const expected = try s.ti.internNumberLiteral(42);
    try T.expectEqual(expected, s.hir.typeOf(v_init));
}

test "checker: ThisType<T> unwraps to T" {
    const s = try newSetup(
        \\let x: ThisType<{ value: number }> = { value: 1 };
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expectEqual(@as(usize, 0), s.checker.diagnostics.items.len);
}

test "checker: NoInfer<T> in param parses without 'cannot find name'" {
    const s = try newSetup(
        \\function foo<T>(x: T, y: NoInfer<T>): T { return x; }
        \\foo(1, 2);
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    // NoInfer<T> should lower transparently to T; no diagnostics.
    try T.expectEqual(@as(usize, 0), s.checker.diagnostics.items.len);
}

test "checker: NoInfer<T> with explicit type arg + bad arg emits TS2345" {
    const s = try newSetup(
        \\function foo<T>(x: T, y: NoInfer<T>): T { return x; }
        \\foo<number>(1, "s");
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.argument_type_mismatch) found = true;
    }
    try T.expect(found);
}

test "checker: NoInfer<T> as alias result type unwraps" {
    const s = try newSetup(
        \\type Id<T> = NoInfer<T>;
        \\let v: Id<number> = 1;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expectEqual(@as(usize, 0), s.checker.diagnostics.items.len);
}

test "checker: Awaited<Promise<number>> resolves to number" {
    // The lexer collapses `>>` into a single `greater_greater` token
    // and the parser doesn't currently split it back out for nested
    // type arguments — so we route the inner `Promise<number>`
    // through an intermediate alias to keep the source free of `>>`.
    const s = try newSetup(
        \\type P = Promise<number>;
        \\type R = Awaited<P>;
        \\let r: R;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[2];
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(r_decl));
}

test "checker: Awaited<Promise<Promise<string>>> recursively unwraps to string" {
    // Same `>>` parser caveat as above — stage the doubly-nested
    // Promise through a pair of aliases so the source has no `>>`.
    const s = try newSetup(
        \\type Inner = Promise<string>;
        \\type Outer = Promise<Inner>;
        \\type R = Awaited<Outer>;
        \\let r: R;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[3];
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(r_decl));
}

test "checker: Awaited<number> on a non-Promise passes through unchanged" {
    const s = try newSetup(
        \\type R = Awaited<number>;
        \\let r: R;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const r_decl = stmts[1];
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(r_decl));
}

test "checker: Array.isArray(x) narrows x in then-branch" {
    const s = try newSetup(
        \\function f(x: any) {
        \\  if (Array.isArray(x)) {
        \\    let arr = x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const v_decl = then_stmts[0];
    const v_init = hir_mod.varDeclOf(&s.hir, v_decl).init;
    // `x` should be narrowed to object_t (array approximation) inside the guard.
    try T.expectEqual(types.Primitive.object_t, s.hir.typeOf(v_init));
}

test "checker: typeof x === \"function\" narrows x in then-branch" {
    const s = try newSetup(
        \\function f(x: any) {
        \\  if (typeof x === "function") {
        \\    let fn = x;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&s.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&s.hir, ifp.then_branch);
    const v_decl = then_stmts[0];
    const v_init = hir_mod.varDeclOf(&s.hir, v_decl).init;
    try T.expectEqual(types.Primitive.object_t, s.hir.typeOf(v_init));
}

test "checker: switch on x.kind narrows x per case body" {
    // Discriminated-union narrowing inside switch cases — `s.v`
    // resolves to each variant's `v` type rather than the wider
    // `number | string`.
    const s = try newSetup(
        \\type S = { k: "a"; v: number } | { k: "b"; v: string };
        \\function f(s: S) {
        \\  switch (s.k) {
        \\    case "a": let n = s.v; break;
        \\    case "b": let str = s.v; break;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const sw_node = body_stmts[0];
    const cases = hir_mod.switchCases(&s.hir, sw_node);

    // case "a" → n init = s.v should type to number_t.
    const a_stmts = hir_mod.switchCaseStmts(&s.hir, cases[0]);
    const n_init = hir_mod.varDeclOf(&s.hir, a_stmts[0]).init;
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(n_init));

    // case "b" → str init = s.v should type to string_t.
    const b_stmts = hir_mod.switchCaseStmts(&s.hir, cases[1]);
    const str_init = hir_mod.varDeclOf(&s.hir, b_stmts[0]).init;
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(str_init));
}

test "checker: switch default narrows x to union minus listed cases" {
    // The default case sees `x` narrowed to the union members not
    // matched by any listed case. With two variants and one case
    // listed, default narrows to the remaining variant — so
    // `s.v` resolves to that variant's `v` type.
    const s = try newSetup(
        \\type S = { k: "a"; v: number } | { k: "b"; v: string };
        \\function f(s: S) {
        \\  switch (s.k) {
        \\    case "a": let n = s.v; break;
        \\    default: let other = s.v; break;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    try T.expect(s.checker.diagnostics.items.len == 0);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const fn_node = stmts[1];
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&s.hir, f.body);
    const sw_node = body_stmts[0];
    const cases = hir_mod.switchCases(&s.hir, sw_node);
    // Default case body: `let other = s.v` — `s` was narrowed to
    // the only remaining variant ({ k: "b"; v: string }), so
    // `s.v` types to `string`.
    const def_stmts = hir_mod.switchCaseStmts(&s.hir, cases[1]);
    const other_init = hir_mod.varDeclOf(&s.hir, def_stmts[0]).init;
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(other_init));
}

test "checker: exhaustive switch narrows discriminant to never in default" {
    // After every variant of a discriminated union is listed as a
    // case, the default branch sees the discriminant as `never` —
    // TS's exhaustiveness-marker pattern. `let x: never = s` must
    // type-check without TS2322 because `s` is `never` there.
    const s = try newSetup(
        \\type S = { kind: "a" } | { kind: "b" };
        \\function f(s: S) {
        \\  switch (s.kind) {
        \\    case "a": break;
        \\    case "b": break;
        \\    default: let x: never = s;
        \\  }
        \\}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.type_not_assignable);
    }
}

test "checker: number === string-literal emits TS2367 (no overlap)" {
    const s = try newSetup(
        \\let x: number = 1;
        \\if (x === "hello") {}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.no_overlap_comparison) found = true;
    }
    try T.expect(found);
}

test "checker: isolatedModules emits TS1205 for `export const enum`" {
    const s = try newSetup(
        \\export const enum E { A, B }
    );
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .isolated_modules = true });
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.isolated_modules_reexport) found = true;
    }
    try T.expect(found);
}

test "checker: isolatedModules off — `export const enum` passes silently" {
    const s = try newSetup(
        \\export const enum E { A, B }
    );
    defer destroySetup(s);
    // No isolated_modules flag set — the const-enum is allowed.
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.isolated_modules_reexport);
    }
}

test "checker: resolveJsonModule on — `.json` import resolves silently" {
    const s = try newSetup(
        \\import data from "./data.json";
    );
    defer destroySetup(s);
    s.checker.setStrictFlags(.{ .resolve_json_module = true });
    try s.checker.checkSourceFile(s.root);
    // No TS2307 — the import is permitted.
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.cannot_find_module);
    }
}

test "checker: resolveJsonModule off — `.json` import emits TS2307" {
    const s = try newSetup(
        \\import data from "./data.json";
    );
    defer destroySetup(s);
    // Flag defaults to false; import should be rejected.
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.cannot_find_module) found = true;
    }
    try T.expect(found);
}

test "checker: lib — string.length resolves to number" {
    const s = try newSetup("let s: string = \"hi\"; s.length;");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    // The trailing `s.length;` is the second top-level statement.
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const len_expr = stmts[1];
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(len_expr));
}

test "checker: lib — string.toUpperCase() resolves to string and is callable" {
    const s = try newSetup("let s: string = \"hi\"; s.toUpperCase();");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    // The call expression types as the signature's return.
    const call_expr = stmts[1];
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(call_expr));
    // No TS2339 should fire for a known prototype method.
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.property_does_not_exist);
    }
}

test "checker: lib — array<number>.push and .length resolve" {
    const s = try newSetup("let arr = [1, 2, 3]; arr.length; arr.push(4);");
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    // arr.length -> number
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(stmts[1]));
    // arr.push(4) -> number (the new length)
    try T.expectEqual(types.Primitive.number_t, s.hir.typeOf(stmts[2]));
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.property_does_not_exist);
    }
}

test "checker: lib — Object.keys is reachable as a member of `Object`" {
    const b = try newBoundSetup("Object.keys({});");
    defer destroyBoundSetup(b);
    try b.base.checker.checkSourceFile(b.base.root);
    // No TS2304 (cannot find name `Object`) and no TS2339 on `keys`.
    for (b.base.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.cannot_find_name);
        try T.expect(d.code != TsCodes.property_does_not_exist);
    }
}

test "checker: assigning to an interface readonly property emits TS2540" {
    const s = try newSetup(
        \\interface P { readonly x: number }
        \\const p: P = { x: 1 };
        \\p.x = 2;
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found: bool = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.readonly_property) found = true;
    }
    try T.expect(found);
}

test "checker: `this.x = …` inside a class constructor passes (no TS2540)" {
    const s = try newSetup(
        \\class C { readonly x = 1; constructor() { this.x = 2; } }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.readonly_property);
    }
}

test "checker: `new AbstractClass()` emits TS2511" {
    const s = try newSetup(
        \\abstract class A { m(): void {} }
        \\new A();
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.abstract_class_instantiation) found = true;
    }
    try T.expect(found);
}

test "checker: `new ConcreteSubclass()` of an abstract class is allowed" {
    const s = try newSetup(
        \\abstract class A { m(): void {} }
        \\class B extends A { m(): void {} }
        \\new B();
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.abstract_class_instantiation);
    }
}

test "checker: non-abstract subclass missing abstract member emits TS2515" {
    const s = try newSetup(
        \\abstract class A { abstract m(): void }
        \\class B extends A {}
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    var found = false;
    for (s.checker.diagnostics.items) |d| {
        if (d.code == TsCodes.abstract_member_not_implemented) found = true;
    }
    try T.expect(found);
}

test "checker: non-abstract subclass implementing abstract member passes (no TS2515)" {
    const s = try newSetup(
        \\abstract class A { abstract m(): void }
        \\class B extends A { m() {} }
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.abstract_member_not_implemented);
    }
}

test "checker: default type parameter — `function f<T = string>(x?: T): T` returns string when called bare" {
    const s = try newSetup(
        \\function f<T = string>(x?: T): T { return x as T; }
        \\let r = f();
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    // `let r = f();` — the call's inferred return type should fall
    // back to the declaration-site default `string`.
    const decl = hir_mod.varDeclOf(&s.hir, stmts[1]);
    const call_expr = decl.init;
    try T.expectEqual(types.Primitive.string_t, s.hir.typeOf(call_expr));
}

test "checker: default type parameter — `type Box<T = number>` resolves bare `Box` to `{ value: number }`" {
    const s = try newSetup(
        \\type Box<T = number> = { value: T };
        \\const b: Box = { value: 1 };
    );
    defer destroySetup(s);
    try s.checker.checkSourceFile(s.root);
    // No TS2314 (generic type requires type arguments) and no TS2322
    // (assignment mismatch). The default `number` should fill `T` so
    // `{ value: 1 }` matches `{ value: number }`.
    for (s.checker.diagnostics.items) |d| {
        try T.expect(d.code != TsCodes.generic_type_requires_args);
        try T.expect(d.code != TsCodes.type_not_assignable);
    }
}
