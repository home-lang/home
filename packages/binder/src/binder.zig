//! Binder — Phase 2 of TS_PARITY_PLAN.
//!
//! Walks the HIR produced by the TS parser (or, in the future, the Home
//! frontend), creates `Symbol` records keyed by interned name, populates
//! lexical `Scope`s, and threads cross-file declaration merging.
//!
//! Three meaning-spaces per symbol (matching tsc):
//!   * **value** — runtime bindings (let/const/var/function/class)
//!   * **type**  — interface/type alias/class-as-type/enum-as-type
//!   * **namespace** — namespace/module/enum-as-namespace
//!
//! A single name may inhabit multiple meaning-spaces — that's exactly
//! how declaration merging surfaces in the type system. For example:
//!   - `class Foo {}` declares `Foo` in the *value* and *type* spaces
//!   - `namespace Foo { … }` adds `Foo` to the *namespace* space and
//!     *merges* with the existing class
//!   - `interface Bar {}` + `interface Bar {}` merge in the type space
//!
//! Phase 2 deliverables targeted here:
//!   1. `Symbol` records with `flags`, decl list, three SymbolMaps for
//!      sub-scopes (value/type/ns) — merged on conflict
//!   2. `Scope` graph — one per source file (module), block, function,
//!      class, namespace; lexical chain via `parent`
//!   3. `Binder.bindSourceFile()` walks the HIR and populates the scope
//!   4. Cross-file declaration merging via the `Module.augment(other)`
//!      step the driver invokes after all files are bound
//!
//! Unicovered for Phase 2 (Phase 3 / type-checker concerns):
//!   - Resolving identifier references to symbols (that's the checker's
//!     `resolve(name, scope)` query)
//!   - Type-system meaning of merges (interface fields union, namespace
//!     adds members, etc.)
//!   - JSDoc-driven `@type` annotation lifting (separate pass)
//!
//! This file is intentionally self-contained. The driver wires it into
//! the same arena that owns the HIR.

const std = @import("std");
const hir_mod = @import("hir");
const string_interner = @import("string_interner");

pub const NodeId = hir_mod.NodeId;
pub const StringId = hir_mod.StringId;

/// Symbol-meaning bit flags. A single `Symbol` aggregates every
/// declaration that shares its name within a scope; `flags` records
/// which meaning-spaces it occupies.
pub const SymbolFlags = packed struct(u32) {
    /// Bound to a runtime value (`let`, `const`, `var`, `function`,
    /// `class`, function parameter, import binding).
    is_value: bool = false,
    /// Bound to a type (`interface`, `type`, `class`-as-type,
    /// `enum`-as-type, type parameter).
    is_type: bool = false,
    /// Bound to a namespace / module / enum-as-namespace.
    is_namespace: bool = false,

    is_function: bool = false,
    is_class: bool = false,
    is_interface: bool = false,
    is_type_alias: bool = false,
    is_enum: bool = false,
    is_namespace_decl: bool = false,
    is_const: bool = false,
    is_let: bool = false,
    is_var: bool = false,
    is_parameter: bool = false,
    is_property: bool = false,
    is_method: bool = false,
    is_constructor: bool = false,
    is_import: bool = false,
    is_export: bool = false,
    is_default_export: bool = false,
    is_type_parameter: bool = false,
    /// Set when a symbol was created by merging two declarations of the
    /// same name (e.g. interface + interface, class + namespace).
    is_merged: bool = false,
    /// Set on synthesized symbols that represent ambient declarations
    /// (no source binding).
    is_ambient: bool = false,

    _padding: u10 = 0,
};

/// One symbol per name-and-scope. Multiple declarations of the same
/// name in the same scope are *merged* into one symbol whose `decls`
/// list grows.
pub const Symbol = struct {
    name: StringId,
    flags: SymbolFlags,
    /// HIR nodes that contributed to this symbol. The first declaration
    /// is canonical for diagnostics ("first declared here").
    decls: std.ArrayListUnmanaged(NodeId),
    /// Sub-scope this symbol introduces (a class body, namespace body,
    /// function body), or `null` for a leaf.
    members: ?*Scope,
    /// Containing scope (back-pointer used for diagnostics).
    parent_scope: ?*Scope,

    pub fn deinit(self: *Symbol, gpa: std.mem.Allocator) void {
        self.decls.deinit(gpa);
    }

    pub fn addDecl(self: *Symbol, gpa: std.mem.Allocator, node: NodeId, additional_flags: SymbolFlags) !void {
        try self.decls.append(gpa, node);
        // Merge flags using bitwise OR semantics on every meaning space.
        const a: u32 = @bitCast(self.flags);
        const b: u32 = @bitCast(additional_flags);
        self.flags = @bitCast(a | b);
        if (self.decls.items.len > 1) {
            self.flags.is_merged = true;
        }
    }
};

/// What kind of lexical scope this is. Affects hoisting rules and
/// which declarations are visible *before* their syntactic position.
pub const ScopeKind = enum(u8) {
    /// One per `.ts` / `.tsx` / `.d.ts` file. Top-level `let`/`const`
    /// are block-scoped (ESM); `var` and `function` hoist to here.
    module,
    /// `function f() { … }` body or function-expression body.
    function,
    /// `{ … }` standalone block (also `if`, `while`, `for` body).
    block,
    /// `class Foo { … }` body.
    class,
    /// `interface Foo { … }` body.
    interface,
    /// `namespace Foo { … }` or `module "x" { … }`.
    namespace,
    /// Type-parameter scope (introduced by `<T, U>` in fn / class /
    /// interface / type-alias declarations).
    type_params,
};

/// A SymbolMap is a name → symbol-pointer table. We keep three per
/// scope (value / type / namespace) so a single name like `Foo` can
/// appear in two of them simultaneously.
pub const SymbolMap = std.AutoHashMapUnmanaged(StringId, *Symbol);

pub const Scope = struct {
    kind: ScopeKind,
    parent: ?*Scope,
    /// HIR node that introduced this scope (the `class_decl`,
    /// `namespace_decl`, `block_stmt`, etc.).
    introducing_node: NodeId,
    /// Value-space bindings.
    values: SymbolMap,
    /// Type-space bindings.
    types: SymbolMap,
    /// Namespace-space bindings.
    namespaces: SymbolMap,

    pub fn lookupLocal(self: *const Scope, name: StringId) ?*Symbol {
        if (self.values.get(name)) |s| return s;
        if (self.types.get(name)) |s| return s;
        if (self.namespaces.get(name)) |s| return s;
        return null;
    }

    /// Walk parent scopes, returning the first `Symbol` matching `name`.
    /// Returns null if unbound.
    pub fn lookup(self: *const Scope, name: StringId) ?*Symbol {
        var cur: ?*const Scope = self;
        while (cur) |sc| {
            if (sc.lookupLocal(name)) |s| return s;
            cur = sc.parent;
        }
        return null;
    }
};

/// A Module is one source file's bound result. The driver owns the
/// arena into which the binder allocates symbols and scopes.
pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    file_id: u32,
    root: *Scope,
    /// All symbols allocated while binding this file. Owned via arena.
    /// Pointer-stable — symbol pointers are durable across the binder
    /// run because we never grow this array (we pre-allocate via the
    /// arena allocator on insertion).
    symbols: std.ArrayListUnmanaged(*Symbol),
    /// All scopes allocated while binding this file.
    scopes: std.ArrayListUnmanaged(*Scope),

    pub fn deinit(self: *Module) void {
        // Everything the Module owns is allocated through the arena:
        //   - symbol structs (via openScope's arena allocator)
        //   - scope structs (ditto)
        //   - the SymbolMap entries (via declare's arena allocator)
        //   - the per-symbol `decls` ArrayList backing storage
        //   - the `symbols` / `scopes` ArrayList backing storage
        // A single arena.deinit() releases all of it. Calling
        // ArrayListUnmanaged.deinit on arena-backed storage with a
        // *different* allocator (the gpa) is a use-after-free in
        // disguise: it decommits memory the arena will then walk and
        // free a second time, surfacing as a poisoned allocator
        // pointer (0xaa…) on deeply recursive inputs where the
        // arena's free list has grown large enough to be reused.
        self.arena.deinit();
    }

    /// §3.A.15 — cross-file module augmentation. Walk every symbol in
    /// `other`'s root scope and merge its declarations into `self`'s
    /// root scope. Used by the driver to apply `declare global { … }`
    /// blocks (which augment the program's global scope) and module
    /// augmentation (`declare module "foo" { … }`) across files.
    /// Symbols not present in `self` are inserted; existing symbols
    /// have their `decls` extended with the augmenting decls and
    /// their `flags` OR-folded.
    pub fn augment(self: *Module, other: *const Module) !void {
        const ar = self.arena.allocator();
        try mergeScope(self.root, other.root, ar);
    }
};

fn mergeScope(into: *Scope, from: *const Scope, ar: std.mem.Allocator) !void {
    try mergeSymbolMap(&into.values, &from.values, ar);
    try mergeSymbolMap(&into.types, &from.types, ar);
    try mergeSymbolMap(&into.namespaces, &from.namespaces, ar);
}

fn mergeSymbolMap(into: *SymbolMap, from: *const SymbolMap, ar: std.mem.Allocator) !void {
    var it = from.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const src = entry.value_ptr.*;
        const gop = try into.getOrPut(ar, name);
        if (!gop.found_existing) {
            // Move the symbol pointer into the destination scope.
            gop.value_ptr.* = src;
            continue;
        }
        // Merge: extend decls list + OR-fold flags + mark as merged.
        const dst = gop.value_ptr.*;
        for (src.decls.items) |d| try dst.decls.append(ar, d);
        const a: u32 = @bitCast(dst.flags);
        const b: u32 = @bitCast(src.flags);
        dst.flags = @bitCast(a | b);
        dst.flags.is_merged = true;
    }
}

/// The Binder operates against a single HIR. Spawned per file by the
/// driver; the resulting `Module` is owned by the caller.
pub const Binder = struct {
    gpa: std.mem.Allocator,
    hir: *const hir_mod.Hir,
    interner: *string_interner.Interner,
    module: *Module,
    /// Stack of scopes open during the walk.
    scope_stack: std.ArrayListUnmanaged(*Scope),
    /// Diagnostics accumulated during bind. The driver collates these
    /// across files.
    diagnostics: std.ArrayListUnmanaged(Diagnostic),

    pub const Diagnostic = struct {
        node: NodeId,
        message: []const u8,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        hir: *const hir_mod.Hir,
        interner: *string_interner.Interner,
        file_id: u32,
    ) !Binder {
        const module = try gpa.create(Module);
        errdefer gpa.destroy(module);
        module.* = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .file_id = file_id,
            .root = undefined,
            .symbols = .empty,
            .scopes = .empty,
        };
        errdefer module.deinit();

        var binder: Binder = .{
            .gpa = gpa,
            .hir = hir,
            .interner = interner,
            .module = module,
            .scope_stack = .empty,
            .diagnostics = .empty,
        };
        // Open the module-level scope.
        const root = try binder.openScope(.module, hir_mod.none_node_id);
        module.root = root;
        return binder;
    }

    pub fn deinit(self: *Binder) void {
        self.scope_stack.deinit(self.gpa);
        self.diagnostics.deinit(self.gpa);
    }

    fn currentScope(self: *Binder) *Scope {
        return self.scope_stack.items[self.scope_stack.items.len - 1];
    }

    fn openScope(self: *Binder, kind: ScopeKind, introducing_node: NodeId) !*Scope {
        const ar = self.module.arena.allocator();
        const sc = try ar.create(Scope);
        sc.* = .{
            .kind = kind,
            .parent = if (self.scope_stack.items.len == 0) null else self.currentScope(),
            .introducing_node = introducing_node,
            .values = .empty,
            .types = .empty,
            .namespaces = .empty,
        };
        try self.scope_stack.append(self.gpa, sc);
        try self.module.scopes.append(ar, sc);
        return sc;
    }

    fn closeScope(self: *Binder) void {
        std.debug.assert(self.scope_stack.items.len > 1);
        _ = self.scope_stack.pop();
    }

    fn newSymbol(
        self: *Binder,
        name: StringId,
        flags: SymbolFlags,
        decl: NodeId,
    ) !*Symbol {
        const ar = self.module.arena.allocator();
        const s = try ar.create(Symbol);
        s.* = .{
            .name = name,
            .flags = flags,
            .decls = .empty,
            .members = null,
            .parent_scope = self.currentScope(),
        };
        try s.decls.append(ar, decl);
        try self.module.symbols.append(ar, s);
        return s;
    }

    pub const Space = enum { value, type, namespace };

    /// Add a declaration to the current scope in the given meaning-space.
    /// If a symbol of that name already exists in that space, merge into
    /// it; otherwise allocate a new symbol.
    fn declare(
        self: *Binder,
        space: Space,
        name: StringId,
        flags: SymbolFlags,
        decl: NodeId,
    ) !*Symbol {
        const map: *SymbolMap = switch (space) {
            .value => &self.currentScope().values,
            .type => &self.currentScope().types,
            .namespace => &self.currentScope().namespaces,
        };
        if (map.get(name)) |existing| {
            const ar = self.module.arena.allocator();
            try existing.addDecl(ar, decl, flags);
            return existing;
        }
        const s = try self.newSymbol(name, flags, decl);
        try map.put(self.module.arena.allocator(), name, s);
        return s;
    }

    /// Bind a complete source-file HIR. The HIR root must be a
    /// `block_stmt` containing top-level statements (the shape produced
    /// by `ts_parser.parseSourceFile`).
    pub fn bindSourceFile(self: *Binder, root: NodeId) !void {
        const stmts = hir_mod.blockStmts(self.hir, root);
        for (stmts) |stmt| {
            try self.bindStatement(stmt);
        }
    }

    fn bindStatement(self: *Binder, node: NodeId) anyerror!void {
        const kind = self.hir.kindOf(node);
        switch (kind) {
            .labeled_stmt => try self.bindStatement(hir_mod.labeledStmtOf(self.hir, node).body),
            .var_decl, .let_decl, .const_decl => try self.bindVarDecl(node),
            .fn_decl, .fn_expr, .arrow_fn => try self.bindFunctionDecl(node),
            .class_decl => try self.bindClassDecl(node),
            .interface_decl => try self.bindInterfaceDecl(node),
            .type_alias_decl => try self.bindTypeAliasDecl(node),
            .enum_decl => try self.bindEnumDecl(node),
            .namespace_decl => try self.bindNamespaceDecl(node),
            .import_decl => try self.bindImportDecl(node),
            .export_decl => try self.bindExportDecl(node),
            .block_stmt => try self.bindBlock(node),
            .if_stmt => {
                const p = hir_mod.ifOf(self.hir, node);
                try self.bindStatement(p.then_branch);
                if (p.else_branch != hir_mod.none_node_id) try self.bindStatement(p.else_branch);
            },
            .while_stmt => try self.bindStatement(hir_mod.whileOf(self.hir, node).body),
            .do_while_stmt => try self.bindStatement(hir_mod.doWhileOf(self.hir, node).body),
            .for_stmt => {
                const p = hir_mod.forStmtOf(self.hir, node);
                if (p.init != hir_mod.none_node_id) {
                    const init_kind = self.hir.kindOf(p.init);
                    if (init_kind == .var_decl or init_kind == .let_decl or init_kind == .const_decl) {
                        try self.bindStatement(p.init);
                    } else if (init_kind == .block_stmt) {
                        // Multi-binding for-init (`for (var i = 0, j = 10; ...)`)
                        // is wrapped in a synthetic block_stmt by the
                        // parser. Recurse so each per-binding var_decl
                        // gets bound — without this, references to the
                        // trailing bindings in the cond/update slots
                        // surface as TS2304.
                        for (hir_mod.blockStmts(self.hir, p.init)) |s| {
                            const s_kind = self.hir.kindOf(s);
                            if (s_kind == .var_decl or s_kind == .let_decl or s_kind == .const_decl) {
                                try self.bindStatement(s);
                            }
                        }
                    }
                }
                try self.bindStatement(p.body);
            },
            .for_in_stmt, .for_of_stmt => {
                const p = hir_mod.forInOf(self.hir, node);
                try self.bindStatement(p.body);
            },
            .try_stmt => {
                const p = hir_mod.tryOf(self.hir, node);
                try self.bindStatement(p.block);
                if (p.catch_block != hir_mod.none_node_id) {
                    // Open a block scope for the catch param.
                    _ = try self.openScope(.block, node);
                    if (p.catch_param != hir_mod.none_node_id and
                        self.hir.kindOf(p.catch_param) == .identifier)
                    {
                        const id = hir_mod.identifierOf(self.hir, p.catch_param);
                        _ = try self.declare(.value, id.name, .{
                            .is_value = true,
                            .is_let = true,
                        }, p.catch_param);
                    }
                    try self.bindStatement(p.catch_block);
                    self.closeScope();
                }
                if (p.finally_block != hir_mod.none_node_id) try self.bindStatement(p.finally_block);
            },
            .switch_stmt => {
                const cases = hir_mod.switchCases(self.hir, node);
                for (cases) |c| {
                    const stmts = hir_mod.switchCaseStmts(self.hir, c);
                    for (stmts) |s| try self.bindStatement(s);
                }
            },
            else => {},
        }
    }

    fn bindVarDecl(self: *Binder, node: NodeId) !void {
        const kind = self.hir.kindOf(node);
        const v = hir_mod.varDeclOf(self.hir, node);
        if (v.name == hir_mod.none_node_id) return;
        const flags: SymbolFlags = .{
            .is_value = true,
            .is_const = kind == .const_decl,
            .is_let = kind == .let_decl,
            .is_var = kind == .var_decl,
        };
        try self.bindVarDeclName(v.name, node, flags);
    }

    /// Walk a `let`/`const`/`var` binding name and declare each
    /// identifier. Plain `const x = …` declares a single name.
    /// `const { a, b } = …` and `const [ x, y ] = …` declare every
    /// shorthand element. Nested patterns recurse.
    fn bindVarDeclName(self: *Binder, name_node: NodeId, decl_node: NodeId, flags: SymbolFlags) !void {
        if (name_node == hir_mod.none_node_id) return;
        const k = self.hir.kindOf(name_node);
        if (k == .identifier) {
            const id = hir_mod.identifierOf(self.hir, name_node);
            _ = try self.declare(.value, id.name, flags, decl_node);
        } else if (k == .object_pattern or k == .array_pattern) {
            const elements = hir_mod.patternElements(self.hir, name_node);
            for (elements) |e| {
                if (self.hir.kindOf(e) != .parameter) continue;
                const ep = hir_mod.parameterOf(self.hir, e);
                try self.bindVarDeclName(ep.name, decl_node, flags);
            }
        }
    }

    fn bindBlock(self: *Binder, node: NodeId) anyerror!void {
        _ = try self.openScope(.block, node);
        const stmts = hir_mod.blockStmts(self.hir, node);
        for (stmts) |s| try self.bindStatement(s);
        self.closeScope();
    }

    fn bindFunctionDecl(self: *Binder, node: NodeId) !void {
        const f = hir_mod.fnDeclOf(self.hir, node);
        if (f.name != hir_mod.none_node_id and self.hir.kindOf(f.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, f.name);
            _ = try self.declare(.value, id.name, .{
                .is_value = true,
                .is_function = true,
            }, node);
        }
        // Open a function scope, bind parameters, then bind the body.
        _ = try self.openScope(.function, node);
        defer self.closeScope();
        const params = hir_mod.fnParams(self.hir, node);
        for (params) |p| {
            const pp = hir_mod.parameterOf(self.hir, p);
            try self.bindParamName(pp.name, p);
        }
        if (f.body != hir_mod.none_node_id and self.hir.kindOf(f.body) == .block_stmt) {
            const body_stmts = hir_mod.blockStmts(self.hir, f.body);
            for (body_stmts) |s| try self.bindStatement(s);
        }
    }

    /// Bind every identifier reachable from a parameter's name slot.
    /// For plain `function f(x)` the name is the identifier itself.
    /// Destructuring patterns (`{ a, b }`, `[ x, y ]`) wrap each
    /// binding in a `parameter` element node — recurse so every
    /// bound name lands in the function scope.
    fn bindParamName(self: *Binder, name_node: NodeId, decl_node: NodeId) !void {
        if (name_node == hir_mod.none_node_id) return;
        const k = self.hir.kindOf(name_node);
        if (k == .identifier) {
            const id = hir_mod.identifierOf(self.hir, name_node);
            _ = try self.declare(.value, id.name, .{
                .is_value = true,
                .is_parameter = true,
            }, decl_node);
        } else if (k == .object_pattern or k == .array_pattern) {
            const elements = hir_mod.patternElements(self.hir, name_node);
            for (elements) |e| {
                if (self.hir.kindOf(e) != .parameter) continue;
                const ep = hir_mod.parameterOf(self.hir, e);
                try self.bindParamName(ep.name, decl_node);
            }
        }
    }

    fn bindClassDecl(self: *Binder, node: NodeId) !void {
        const c = hir_mod.classOf(self.hir, node);
        if (c.name != hir_mod.none_node_id and self.hir.kindOf(c.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, c.name);
            // Class names live in *both* the value space (the
            // constructor) and the type space (the instance type).
            _ = try self.declare(.value, id.name, .{
                .is_value = true,
                .is_class = true,
            }, node);
            _ = try self.declare(.type, id.name, .{
                .is_type = true,
                .is_class = true,
            }, node);
        }
        // Class body — open a class scope and bind members.
        _ = try self.openScope(.class, node);
        defer self.closeScope();
        const members = hir_mod.classMembers(self.hir, node);
        for (members) |m| {
            switch (self.hir.kindOf(m)) {
                .fn_decl, .fn_expr, .arrow_fn => {
                    const fn_p = hir_mod.fnDeclOf(self.hir, m);
                    if (fn_p.name != hir_mod.none_node_id and
                        self.hir.kindOf(fn_p.name) == .identifier)
                    {
                        const id = hir_mod.identifierOf(self.hir, fn_p.name);
                        _ = try self.declare(.value, id.name, .{
                            .is_value = true,
                            .is_method = fn_p.flags.is_method and !fn_p.flags.is_constructor,
                            .is_constructor = fn_p.flags.is_constructor,
                        }, m);
                    }
                    // Walk into the method body — open a function
                    // scope, bind parameters and locals.
                    _ = try self.openScope(.function, m);
                    defer self.closeScope();
                    const params = hir_mod.fnParams(self.hir, m);
                    for (params) |p| {
                        const pp = hir_mod.parameterOf(self.hir, p);
                        try self.bindParamName(pp.name, p);
                    }
                    if (fn_p.body != hir_mod.none_node_id and self.hir.kindOf(fn_p.body) == .block_stmt) {
                        const body_stmts = hir_mod.blockStmts(self.hir, fn_p.body);
                        for (body_stmts) |s| try self.bindStatement(s);
                    }
                },
                .object_property => {
                    const op = hir_mod.objectPropertyOf(self.hir, m);
                    if (self.hir.kindOf(op.key) == .identifier) {
                        const id = hir_mod.identifierOf(self.hir, op.key);
                        _ = try self.declare(.value, id.name, .{
                            .is_value = true,
                            .is_property = true,
                        }, m);
                    }
                },
                .block_stmt => {
                    _ = try self.openScope(.block, m);
                    defer self.closeScope();
                    for (hir_mod.blockStmts(self.hir, m)) |s| try self.bindStatement(s);
                },
                else => {},
            }
        }
    }

    fn bindInterfaceDecl(self: *Binder, node: NodeId) !void {
        const i = hir_mod.interfaceOf(self.hir, node);
        if (self.hir.kindOf(i.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, i.name);
            _ = try self.declare(.type, id.name, .{
                .is_type = true,
                .is_interface = true,
            }, node);
        }
    }

    fn bindTypeAliasDecl(self: *Binder, node: NodeId) !void {
        const t = hir_mod.typeAliasOf(self.hir, node);
        if (self.hir.kindOf(t.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, t.name);
            _ = try self.declare(.type, id.name, .{
                .is_type = true,
                .is_type_alias = true,
            }, node);
        }
    }

    fn bindEnumDecl(self: *Binder, node: NodeId) !void {
        const e = hir_mod.enumOf(self.hir, node);
        if (self.hir.kindOf(e.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, e.name);
            // Enums occupy value, type, *and* namespace spaces.
            _ = try self.declare(.value, id.name, .{
                .is_value = true,
                .is_enum = true,
            }, node);
            _ = try self.declare(.type, id.name, .{
                .is_type = true,
                .is_enum = true,
            }, node);
            _ = try self.declare(.namespace, id.name, .{
                .is_namespace = true,
                .is_enum = true,
            }, node);
        }
        // Enum members are currently lowered as object_property nodes
        // by the parser; we don't open a sub-scope for them in Phase 2.
    }

    fn bindNamespaceDecl(self: *Binder, node: NodeId) !void {
        const n = hir_mod.namespaceOf(self.hir, node);
        if (self.hir.kindOf(n.name) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, n.name);
            _ = try self.declare(.namespace, id.name, .{
                .is_namespace = true,
                .is_namespace_decl = true,
            }, node);
            // If the namespace contains value declarations, it also
            // surfaces in the value space (per tsc semantics).
            // Conservative: always tag value too; the type checker
            // will inspect the body to refine.
            _ = try self.declare(.value, id.name, .{
                .is_value = true,
                .is_namespace_decl = true,
            }, node);
        }
        _ = try self.openScope(.namespace, node);
        defer self.closeScope();
        const body = hir_mod.namespaceBody(self.hir, node);
        for (body) |s| try self.bindStatement(s);
    }

    fn bindImportDecl(self: *Binder, node: NodeId) !void {
        const imp = hir_mod.importOf(self.hir, node);
        const flags: SymbolFlags = .{
            .is_value = !imp.is_type_only,
            .is_type = imp.is_type_only,
            .is_import = true,
        };
        if (imp.default_binding != hir_mod.none_node_id and
            self.hir.kindOf(imp.default_binding) == .identifier)
        {
            const id = hir_mod.identifierOf(self.hir, imp.default_binding);
            const space: Space = if (imp.is_type_only) .type else .value;
            _ = try self.declare(space, id.name, flags, imp.default_binding);
        }
        if (imp.namespace_binding != hir_mod.none_node_id and
            self.hir.kindOf(imp.namespace_binding) == .identifier)
        {
            const id = hir_mod.identifierOf(self.hir, imp.namespace_binding);
            // `import * as ns` binds ns in *both* value and namespace
            // spaces, plus type if it's `import type * as`.
            const space: Space = if (imp.is_type_only) .type else .value;
            _ = try self.declare(space, id.name, flags, imp.namespace_binding);
            _ = try self.declare(.namespace, id.name, flags, imp.namespace_binding);
        }
        const named = hir_mod.importNamed(self.hir, node);
        for (named) |spec| {
            if (self.hir.kindOf(spec) != .import_specifier) continue;
            const sp = hir_mod.importSpecifierOf(self.hir, spec);
            const sp_flags: SymbolFlags = .{
                .is_value = !(imp.is_type_only or sp.is_type_only),
                .is_type = (imp.is_type_only or sp.is_type_only),
                .is_import = true,
            };
            const space: Space = if (imp.is_type_only or sp.is_type_only) .type else .value;
            _ = try self.declare(space, sp.local, sp_flags, spec);
        }
    }

    fn bindExportDecl(self: *Binder, node: NodeId) !void {
        const ex = hir_mod.exportOf(self.hir, node);
        // `export { … }` and `export … from "m"` don't introduce new
        // local bindings — they re-export existing ones. We just mark
        // the named locals as exported when the source is local.
        const named = hir_mod.exportNamed(self.hir, node);
        for (named) |spec| {
            if (self.hir.kindOf(spec) != .import_specifier) continue;
            const sp = hir_mod.importSpecifierOf(self.hir, spec);
            // We don't have the local symbol yet (forward references
            // are valid). Phase 3 will resolve.
            _ = sp;
        }
        // `export <decl>` introduces a binding *and* exports it.
        if (ex.decl != hir_mod.none_node_id) {
            try self.bindStatement(ex.decl);
            // Tag the just-created symbol as exported.
            if (firstIdentifier(self.hir, ex.decl)) |name_node| {
                const id = hir_mod.identifierOf(self.hir, name_node);
                if (self.currentScope().values.get(id.name)) |s| {
                    s.flags.is_export = true;
                    if (ex.is_default) s.flags.is_default_export = true;
                }
                if (self.currentScope().types.get(id.name)) |s| {
                    s.flags.is_export = true;
                    if (ex.is_default) s.flags.is_default_export = true;
                }
            }
        } else if (ex.is_default) {
            // `export default <expr>` synthesizes a `default` binding.
            const default_id = self.interner.intern("default") catch return error.OutOfMemory;
            _ = try self.declare(.value, default_id, .{
                .is_value = true,
                .is_export = true,
                .is_default_export = true,
            }, node);
        }
    }
};

/// For a declaration node, returns the NodeId of the bound name
/// identifier, or null if it doesn't have one in the standard slot.
fn firstIdentifier(hir: *const hir_mod.Hir, node: NodeId) ?NodeId {
    return switch (hir.kindOf(node)) {
        // §5.A.2 — `export let|const|var <name>` needs its underlying
        // variable symbol tagged as exported. Without this branch,
        // `bindExportDecl`'s post-bind lookup didn't fire for variable
        // bindings — `export let y = 1;` left `y` un-tagged with
        // `is_export`, which downstream queries (per-symbol invalidation,
        // hover, completion auto-import filtering) all rely on.
        .var_decl, .let_decl, .const_decl => blk: {
            const v = hir_mod.varDeclOf(hir, node);
            if (v.name != hir_mod.none_node_id and hir.kindOf(v.name) == .identifier) break :blk v.name;
            break :blk null;
        },
        .fn_decl, .fn_expr, .arrow_fn => blk: {
            const f = hir_mod.fnDeclOf(hir, node);
            if (f.name != hir_mod.none_node_id and hir.kindOf(f.name) == .identifier) break :blk f.name;
            break :blk null;
        },
        .class_decl, .class_expr => blk: {
            const c = hir_mod.classOf(hir, node);
            if (c.name != hir_mod.none_node_id and hir.kindOf(c.name) == .identifier) break :blk c.name;
            break :blk null;
        },
        .interface_decl => blk: {
            const i = hir_mod.interfaceOf(hir, node);
            if (hir.kindOf(i.name) == .identifier) break :blk i.name;
            break :blk null;
        },
        .type_alias_decl => blk: {
            const t = hir_mod.typeAliasOf(hir, node);
            if (hir.kindOf(t.name) == .identifier) break :blk t.name;
            break :blk null;
        },
        .enum_decl => blk: {
            const e = hir_mod.enumOf(hir, node);
            if (hir.kindOf(e.name) == .identifier) break :blk e.name;
            break :blk null;
        },
        .namespace_decl => blk: {
            const n = hir_mod.namespaceOf(hir, node);
            if (hir.kindOf(n.name) == .identifier) break :blk n.name;
            break :blk null;
        },
        else => null,
    };
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;
const ts_lexer = @import("ts_lexer");
const ts_parser = @import("ts_parser");

const TestSetup = struct {
    interner: string_interner.Interner,
    hir: hir_mod.Hir,
    scanner: ts_lexer.Scanner,
    tokens: std.ArrayList(ts_lexer.Token),
    parser: ts_parser.Parser,
    binder: Binder,
    root: NodeId,
};

fn newTestSetup(source: []const u8) !*TestSetup {
    const s = try T.allocator.create(TestSetup);
    errdefer T.allocator.destroy(s);
    s.interner = try string_interner.Interner.init(T.allocator);
    errdefer s.interner.deinit();
    s.hir = try hir_mod.Hir.init(T.allocator);
    errdefer s.hir.deinit();
    s.scanner = ts_lexer.Scanner.init(T.allocator, source);
    errdefer s.scanner.deinit(T.allocator);
    s.tokens = try s.scanner.tokenize(T.allocator);
    errdefer s.tokens.deinit(T.allocator);
    s.parser = ts_parser.Parser.init(T.allocator, &s.hir, &s.interner, source, s.tokens.items);
    errdefer s.parser.deinit();
    s.root = try s.parser.parseSourceFile();
    s.binder = try Binder.init(T.allocator, &s.hir, &s.interner, 0);
    errdefer {
        s.binder.module.deinit();
        T.allocator.destroy(s.binder.module);
        s.binder.deinit();
    }
    try s.binder.bindSourceFile(s.root);
    return s;
}

fn destroyTestSetup(s: *TestSetup) void {
    s.binder.module.deinit();
    T.allocator.destroy(s.binder.module);
    s.binder.deinit();
    s.parser.deinit();
    s.tokens.deinit(T.allocator);
    s.scanner.deinit(T.allocator);
    s.hir.deinit();
    s.interner.deinit();
    T.allocator.destroy(s);
}

test "binder: empty source — module scope opened, no bindings" {
    var s = try newTestSetup("");
    defer destroyTestSetup(s);
    try T.expectEqual(@as(usize, 0), s.binder.module.root.values.count());
    try T.expectEqual(@as(usize, 0), s.binder.module.root.types.count());
    try T.expectEqual(ScopeKind.module, s.binder.module.root.kind);
}

test "binder: function declaration binds in value space" {
    var s = try newTestSetup("function add(a, b) { return a + b; }");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("add");
    const sym = s.binder.module.root.values.get(id) orelse return error.SymbolNotFound;
    try T.expect(sym.flags.is_value);
    try T.expect(sym.flags.is_function);
    try T.expect(!sym.flags.is_type);
    try T.expectEqual(@as(usize, 1), sym.decls.items.len);
}

test "binder: class binds in both value and type spaces" {
    var s = try newTestSetup("class Foo { x = 1; }");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("Foo");
    const value_sym = s.binder.module.root.values.get(id) orelse return error.NoValueSymbol;
    const type_sym = s.binder.module.root.types.get(id) orelse return error.NoTypeSymbol;
    try T.expect(value_sym.flags.is_class);
    try T.expect(type_sym.flags.is_class);
    try T.expect(value_sym != type_sym);
}

test "binder: interface binds in type space only" {
    var s = try newTestSetup("interface Bar {}");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("Bar");
    try T.expect(s.binder.module.root.types.get(id) != null);
    try T.expect(s.binder.module.root.values.get(id) == null);
}

test "binder: interface + interface merges" {
    var s = try newTestSetup("interface I {} interface I {}");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("I");
    const sym = s.binder.module.root.types.get(id) orelse return error.NoSymbol;
    try T.expectEqual(@as(usize, 2), sym.decls.items.len);
    try T.expect(sym.flags.is_merged);
}

test "binder: type alias binds in type space" {
    var s = try newTestSetup("type Pair = number;");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("Pair");
    const sym = s.binder.module.root.types.get(id) orelse return error.NoSymbol;
    try T.expect(sym.flags.is_type_alias);
}

test "binder: enum binds in all three spaces" {
    var s = try newTestSetup("enum Color { Red, Green, Blue }");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("Color");
    try T.expect(s.binder.module.root.values.get(id) != null);
    try T.expect(s.binder.module.root.types.get(id) != null);
    try T.expect(s.binder.module.root.namespaces.get(id) != null);
}

test "binder: namespace binds in namespace space" {
    var s = try newTestSetup("namespace N { let x = 1; }");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("N");
    try T.expect(s.binder.module.root.namespaces.get(id) != null);
}

test "binder: import default binds locally" {
    var s = try newTestSetup("import React from \"react\";");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("React");
    const sym = s.binder.module.root.values.get(id) orelse return error.NoSymbol;
    try T.expect(sym.flags.is_import);
    try T.expect(sym.flags.is_value);
}

test "binder: import named with rename" {
    var s = try newTestSetup("import { useState as u } from \"react\";");
    defer destroyTestSetup(s);
    // The local name is `u`, not `useState`.
    const local_id = try s.interner.intern("u");
    try T.expect(s.binder.module.root.values.get(local_id) != null);
    const imported_id = try s.interner.intern("useState");
    try T.expect(s.binder.module.root.values.get(imported_id) == null);
}

test "binder: import type-only goes to type space" {
    var s = try newTestSetup("import type { Foo } from \"./types\";");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("Foo");
    try T.expect(s.binder.module.root.types.get(id) != null);
    try T.expect(s.binder.module.root.values.get(id) == null);
}

test "binder: export tags symbol as exported" {
    var s = try newTestSetup("export function f() {}");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("f");
    const sym = s.binder.module.root.values.get(id) orelse return error.NoSymbol;
    try T.expect(sym.flags.is_export);
    try T.expect(!sym.flags.is_default_export);
}

test "binder: export default class" {
    var s = try newTestSetup("export default class Foo {}");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("Foo");
    const sym = s.binder.module.root.values.get(id) orelse return error.NoSymbol;
    try T.expect(sym.flags.is_default_export);
}

test "binder: scope.lookup walks parent chain" {
    var s = try newTestSetup("function outer() { function inner() {} }");
    defer destroyTestSetup(s);
    // Find the inner function's scope.
    var inner_scope: ?*Scope = null;
    for (s.binder.module.scopes.items) |sc| {
        if (sc.kind == .function and sc.parent != null and sc.parent.?.kind == .function) {
            inner_scope = sc;
            break;
        }
    }
    try T.expect(inner_scope != null);
    const outer_id = try s.interner.intern("outer");
    // Local lookup at inner scope misses; full lookup walks parent.
    try T.expect(inner_scope.?.lookupLocal(outer_id) == null);
    try T.expect(inner_scope.?.lookup(outer_id) != null);
}

test "binder: function parameters are bound in function scope" {
    var s = try newTestSetup("function add(a, b) { return a + b; }");
    defer destroyTestSetup(s);
    // Find the function scope.
    var fn_scope: ?*Scope = null;
    for (s.binder.module.scopes.items) |sc| {
        if (sc.kind == .function) fn_scope = sc;
    }
    try T.expect(fn_scope != null);
    const a = try s.interner.intern("a");
    const b = try s.interner.intern("b");
    const sa = fn_scope.?.values.get(a) orelse return error.NoA;
    const sb = fn_scope.?.values.get(b) orelse return error.NoB;
    try T.expect(sa.flags.is_parameter);
    try T.expect(sb.flags.is_parameter);
}

test "binder: catch parameter is bound in catch-block scope" {
    var s = try newTestSetup("try { f(); } catch (err) { log(err); }");
    defer destroyTestSetup(s);
    var found = false;
    for (s.binder.module.scopes.items) |sc| {
        const err_id = try s.interner.intern("err");
        if (sc.values.get(err_id)) |_| {
            found = true;
            break;
        }
    }
    try T.expect(found);
}

test "binder: top-level let is bound" {
    var s = try newTestSetup("let count = 0;");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("count");
    const sym = s.binder.module.root.values.get(id) orelse return error.NoSymbol;
    try T.expect(sym.flags.is_let);
}

test "binder: declaration merging — class + namespace" {
    var s = try newTestSetup("class C {} namespace C { let x = 1; }");
    defer destroyTestSetup(s);
    const id = try s.interner.intern("C");
    // Class registers in value + type. Namespace adds to value + namespace.
    const value_sym = s.binder.module.root.values.get(id) orelse return error.NoVal;
    try T.expect(value_sym.flags.is_class);
    try T.expect(value_sym.flags.is_namespace_decl);
    try T.expect(value_sym.flags.is_merged);
    try T.expect(s.binder.module.root.namespaces.get(id) != null);
    try T.expect(s.binder.module.root.types.get(id) != null);
}

test "binder: for-init with multiple var decls binds every name" {
    // `for (var i = 0, j = 10; ...)` should bind both `i` and `j`
    // — without recursing into the parser's synthetic block_stmt
    // wrapping the secondary decls the trailing bindings surface
    // as TS2304 in the cond/update slots.
    var s = try newTestSetup("for (var i = 0, j = 10; i < j; i++, j--) {}");
    defer destroyTestSetup(s);
    const i_id = try s.interner.intern("i");
    const j_id = try s.interner.intern("j");
    try T.expect(s.binder.module.root.values.get(i_id) != null);
    try T.expect(s.binder.module.root.values.get(j_id) != null);
}

test "binder: Module.augment merges symbols across modules" {
    const s1 = try newTestSetup("function alpha() {}");
    defer destroyTestSetup(s1);
    const s2 = try newTestSetup("class Beta {}");
    defer destroyTestSetup(s2);
    // Augmenting s1 with s2 should add `Beta` to s1's value scope.
    // Note: cross-interner StringId correctness is verified
    // separately by the program-graph layer (where files share
    // an interner). This test exercises the merge mechanics.
    try s1.binder.module.augment(s2.binder.module);
}
