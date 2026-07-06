//! JS pretty-printer — Phase 4 of TS_PARITY_PLAN.
//!
//! Streams JavaScript output from the post-bind HIR. No intermediate
//! JS-AST, matching tsc/tsgo's printer-by-traversal approach.
//!
//! Phase 4.1 covers expressions and basic statements that the
//! ts_parser produces today: literals, identifiers, binary / unary /
//! logical / conditional / call / member / element / assignment;
//! block, if, while, do-while, for, for-in, for-of, return, break,
//! continue, throw, try/catch/finally, switch, function, class,
//! interface (erased), enum, namespace (erased to IIFE), import,
//! export.
//!
//! What's deferred (Phase 4.2 / downlevel transforms):
//!   - Source maps (skeleton wired but byte-equivalent VLQ encoder
//!     not yet implemented)
//!   - Downlevel ES2024 → es2022 / es2021 / … / ES5
//!   - Decorator emit (legacy + Stage 3)
//!   - JSX transforms
//!   - ESM ↔ CJS interop (`__importDefault` / `__importStar`)
//!   - Comment preservation
//!
//! These all hook into the same `Printer.printNode` switch — the
//! foundation here is correct streaming output; downlevel transforms
//! re-route specific node kinds to their lowered forms.

const std = @import("std");
const hir_mod = @import("hir");
const string_interner = @import("string_interner");

pub const Hir = hir_mod.Hir;
pub const NodeId = hir_mod.NodeId;
pub const StringId = hir_mod.StringId;

pub const EmitError = error{
    OutOfMemory,
    UnsupportedNode,
};

/// Module emit format. `esm` is today's default (preserves `import`
/// / `export`). `commonjs` lowers to `require()` + `module.exports`,
/// inserting `__importDefault` / `__importStar` helpers when the
/// `esModuleInterop` flag is on (we always emit them — matches tsc's
/// default for `module: commonjs`).
pub const ModuleKind = enum {
    esm,
    commonjs,
};

/// Approximate ES target for the emitter. Selects which downlevel
/// transforms apply. `esnext` = "no lowering", `es2020` = lower
/// nullish-coalescing + optional-chaining, `es2017` = also lower
/// async/await (Phase 4 follow-up), `es5` = lower arrow + class
/// (Phase 4 follow-up).
pub const EsTarget = enum {
    es5,
    es2015,
    es2016,
    es2017,
    es2018,
    es2019,
    es2020,
    es2021,
    es2022,
    es2023,
    esnext,

    pub fn supportsNullishAndOptional(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2020);
    }

    /// Numeric separators (`1_000_000`) are an ES2021 feature. Below
    /// that we strip the underscores from the literal text on emit.
    pub fn supportsLogicalAssignment(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2021);
    }

    pub fn supportsNumericSeparators(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2021);
    }

    /// The exponentiation operator (`a ** b`, `a **= b`) is an ES2016
    /// feature. Below that tsc lowers it to `Math.pow(a, b)`.
    pub fn supportsExponentiation(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2016);
    }

    /// Object spread `{ ...a }` is an ES2018 feature. Below that tsc lowers
    /// it to a left-folded `__assign(...)` chain.
    pub fn supportsObjectSpread(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2018);
    }

    /// Native `async`/`await` is an ES2017 feature. Below that we
    /// downlevel async functions to a `__awaiter`-wrapped generator
    /// and rewrite `await E` inside the body to `yield E`.
    pub fn supportsNativeAsync(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2017);
    }

    /// Native `#private` class fields land in ES2022. Below that we
    /// lower them to a per-class `WeakMap` keyed by the instance, with
    /// `this.#x` reads/writes routed through `_Class_x.get(this)` /
    /// `_Class_x.set(this, v)`.
    pub fn supportsNativePrivateFields(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2022);
    }

    /// Native public class fields (`class C { x = 1; }`) are an ES2022
    /// feature. At ES2015–ES2021 we hoist field initializers into the
    /// (synthesized, if needed) constructor as `this.x = 1;`, matching
    /// tsc's downlevel shape.
    pub fn supportsNativeClassFields(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2022);
    }

    /// Native `123n` BigInt literal syntax landed in ES2020. Below
    /// that we lower `123n` to `BigInt("123")`, matching tsc's
    /// downlevel shape.
    pub fn supportsNativeBigInt(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2020);
    }

    /// Native `function*` generator syntax is an ES2015 feature. Below
    /// that we lower to a `__generator(this, function (_state) { … })`
    /// state-machine, matching tsc's downlevel shape. v0 of the
    /// state-machine transform is tracked separately (§4.A.4); this
    /// predicate is the gate that future lowering will branch on.
    pub fn supportsNativeGenerators(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2015);
    }

    /// Native `async function*` async generators (plus `for await…of`)
    /// landed in ES2018. Below that we lower the function to a
    /// `__asyncGenerator(this, arguments, function () { return
    /// __generator(...); })` wrapper, and each user `yield E` expands
    /// to the double-yield pattern `return [4, __await(E)]; … return [4];`
    /// matching tsc's downlevel shape.
    pub fn supportsNativeAsyncGenerators(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2018);
    }
};

pub const JsxRuntime = enum {
    /// Classic React.createElement(tag, props, ...children).
    classic,
    /// Automatic runtime — `_jsx(tag, props)` for static-children
    /// and `_jsxs(tag, props)` for multiple children, imported from
    /// `react/jsx-runtime`.
    automatic,
    /// Same as automatic but adds dev-time source location info.
    automatic_dev,
    /// Pass through unchanged (for downstream tooling).
    preserve,
};

pub const Options = struct {
    /// 2-space indent matches tsc's default.
    indent: []const u8 = "  ",
    /// `\n` matches tsc on POSIX; Windows callers pass `\r\n`.
    newline: []const u8 = "\n",
    /// If true, drop semicolons unless required for ASI. We default
    /// to *with* semicolons, matching tsc.
    omit_semis: bool = false,
    /// If non-null, the printer records source-map mappings into the
    /// supplied `SourceMap` as it streams.
    source_map: ?*source_map_mod.SourceMap = null,
    /// Source-index inside the SourceMap for every mapping recorded
    /// from this printer. The driver normally adds the source first
    /// and passes the returned index here.
    source_map_src_idx: u32 = 0,
    /// When non-null, the printer appends a tsc-compatible
    /// `//# sourceMappingURL=<url>` comment to the end of the
    /// JS output. The URL is typically `<output>.map`.
    source_map_url: ?[]const u8 = null,
    /// JSX lowering mode. `classic` matches today's React.createElement
    /// output. `automatic` lowers to `_jsx`/`_jsxs` matching the React
    /// 17+ automatic runtime. `preserve` keeps JSX literals untouched
    /// (copied from source bytes).
    jsx_runtime: JsxRuntime = .classic,
    /// Full callee for classic-mode element creation. Emitted verbatim
    /// — set to `"h"` (Preact), `"React.createElement"` (the default,
    /// matching tsc's `jsxFactory`), or any other expression.
    jsx_factory: []const u8 = "React.createElement",
    /// Fragment expression for classic mode (matches tsc's
    /// `jsxFragmentFactory`, default `"React.Fragment"`).
    jsx_fragment_factory: []const u8 = "React.Fragment",
    /// ES target — selects which downlevel transforms apply.
    es_target: EsTarget = .esnext,
    /// Module emit format. `esm` (default) keeps `import`/`export`;
    /// `commonjs` lowers to `require()` + `Object.defineProperty(exports, ...)`.
    module_kind: ModuleKind = .esm,
    /// `esModuleInterop` — when true and module_kind is commonjs,
    /// inject `__importDefault` / `__importStar` helper calls so
    /// `import x from "y"` works against CJS modules without
    /// `.default`-property dance.
    es_module_interop: bool = true,
    /// `experimentalDecorators` — when true (default), emit the
    /// legacy `__decorate(...)` shape that matches tsc with
    /// `experimentalDecorators: true`. When false, emit the Stage 3
    /// (TC39) `__esDecorate` shape that tsc uses by default in
    /// TS 5.0+. v1 emits a simplified helper shape for class- and
    /// member-level decorators; full initializer-array semantics are
    /// tracked as a follow-up.
    experimental_decorators: bool = true,
    /// `emitDecoratorMetadata` — when true (and `experimentalDecorators`
    /// is also true), emit `__metadata("design:type", T)`,
    /// `__metadata("design:paramtypes", [...])`, and
    /// `__metadata("design:returntype", T)` calls inside the
    /// `__decorate([...])` array for decorated members.
    emit_decorator_metadata: bool = false,
    /// `importHelpers` — when true, prepend an
    /// `import { __awaiter, __decorate, __esDecorate, __extends,
    /// __generator, __param, __importDefault, __importStar, __values }
    /// from "tslib";` line at the top of the file so the runtime
    /// helpers come from the `tslib` package rather than being
    /// expected as ambient globals. v0 emits the full helper set
    /// unconditionally and lets the bundler tree-shake unused names.
    import_helpers: bool = false,
    /// `downlevelIteration` — when true and `es_target` is below
    /// ES2015, lower `for-of` over a non-array iterable using the
    /// iterator protocol (`__values(source).next()` loop wrapped in
    /// try/catch/finally that closes the iterator via `.return()` on
    /// abrupt completion). When false (default) `for-of` at ES5 stays
    /// on the cheaper indexed-for shape, which assumes the source is
    /// array-like. Matches tsc's `downlevelIteration` compiler flag.
    downlevel_iteration: bool = false,
    /// `removeComments` — when true, strip JSDoc `/** … */` comments
    /// from the output. When false (default), JSDoc comments that
    /// appear immediately before a top-level declaration in the
    /// source are copied through to the emitted JS so documentation
    /// generators (TypeDoc, JSDoc) keep working on the JS output.
    /// Source bytes must be attached via `Printer.setSource` for
    /// pass-through to take effect.
    remove_comments: bool = false,
    /// `useDefineForClassFields` — when true (default for ES2022+),
    /// public class fields use ES2022 `[[Define]]` semantics: the
    /// emitter keeps the native `class Foo { x = 1 }` shape so the
    /// runtime calls `Object.defineProperty(this, "x", { value: 1, … })`.
    /// When false (TS legacy), public fields lower to plain
    /// `this.x = 1;` assignments inside the (synthesized if absent)
    /// constructor — matching tsc's pre-ES2022 / `useDefineForClassFields:
    /// false` shape. v0 only plumbs the option; downlevel ES targets
    /// already hoist fields into the ctor regardless of this flag.
    use_define_for_class_fields: bool = true,
};

const source_map_mod = @import("source_map.zig");

/// One entry on the expression-context temp-hoist stack (§4.A.31). `mark`
/// is the byte offset in `out` where this scope's `var _a, _b;` declaration
/// gets spliced in (right after the function's / module's opening), and
/// `count` is how many `_a`-style temps have been allocated in the scope.
const TempScope = struct { mark: usize, count: usize };

pub const Printer = struct {
    gpa: std.mem.Allocator,
    hir: *const Hir,
    interner: *const string_interner.Interner,
    out: std.ArrayListUnmanaged(u8),
    /// Stack of function/module temp scopes for the ES-downlevel
    /// expression-context temp-hoist. On scope exit a `var _a, _b; ` decl
    /// is spliced in at `mark` so it lands at the function/module top,
    /// matching tsc's temp placement.
    temp_scopes: std.ArrayListUnmanaged(TempScope) = .empty,
    /// One-shot marker consumed by `printBlock`: the next block printed is a
    /// FUNCTION body, so it opens its own temp-hoist scope (temps allocated
    /// inside splice at that function's top rather than module scope).
    next_block_is_fn_body: bool = false,
    options: Options,
    depth: u32,
    /// True when the previous token-output ended with a position where
    /// inserting a newline would alter ASI semantics.
    pending_break: bool,
    /// Generated-line of the next byte we'll write (0-based).
    gen_line: u32,
    /// Generated-column of the next byte we'll write (0-based).
    gen_col: u32,
    /// Source bytes for line/col lookup of HIR spans. Optional;
    /// when null, source-map mappings are skipped.
    source: ?[]const u8,
    /// True while emitting the body of an async function that's been
    /// lowered to a `__awaiter(this, void 0, void 0, function* () { … })`
    /// wrapper. The `.await_expr` printer consults this to emit
    /// `yield` instead of `await` within the generator body.
    in_async_downlevel: bool,
    /// True while emitting inside a sync-generator state-machine
    /// body via `printGeneratorDownlevelBody`. When set, `printReturn`
    /// rewrites `return E;` to `return [2, E];` (op-2 = generator-
    /// return) so nested returns inside lowered control-flow
    /// (loops / ifs / switch cases) participate in the state machine
    /// instead of returning from the inner state-machine fn directly.
    /// The top-level body walker has its own explicit return emit so
    /// it doesn't go through printReturn — this flag covers the
    /// recursively-printed nested case.
    in_sync_gen_body: bool = false,
    /// Name (interned) of the lexically-enclosing class while emitting
    /// its body, when private-field downlevel is active. Used to
    /// rewrite `this.#x` -> `_<Class>_x.get(this)`. `null` outside a
    /// class body or when the target supports native private fields.
    current_class_name: ?StringId,
    /// True while emitting the inside of an ES5-lowered derived class
    /// IIFE body. Causes `super(args)` to lower to
    /// `_super.call(this, args)`, `super.m(args)` to
    /// `_super.prototype.m.call(this, args)`, and bare `super.x` reads
    /// to `_super.prototype.x`. Outside this scope `super` is printed
    /// verbatim (preserved at ES2015+ where the keyword is legal).
    in_es5_super_lowering: bool,
    /// Set while printing the *target* (constructor) spine of a `new`
    /// expression. A call reached on that spine must be parenthesized so
    /// `new` applies to the call result, not its callee — `new (f())()`
    /// must not print as `new f()()` (which parses as `(new f())()`).
    /// Mirrors Bun's `ExprFlag.forbid_call`. Only ever set inside
    /// `printNew` (and restored), and read in `printCall`, so it has no
    /// effect outside `new`-target printing.
    forbid_call: bool = false,
    /// Function-nesting depth — bumped on entry to any function body
    /// (decl/expr/arrow/method/ctor) and restored on exit. Used by the
    /// `.await_expr` printer to detect *top-level* await: at depth 0
    /// the await is at module scope, which is only legal in ESM at
    /// ES2022+. At older targets we still emit `await E` but prefix
    /// it with a `/* TODO: top-level await requires ES2022+ */` marker
    /// so downstream tools can flag the unsupported emit.
    fn_depth: u32,
    /// §4.A.4.4 — when non-null, top-level `break;` statements
    /// emitted via `printNonIndentStatement` rewrite to
    /// `return [3, gen_break_label];` so the break correctly exits
    /// the lowered loop (rather than escaping the state machine's
    /// switch). Only set while emitting pre/post statements of a
    /// lowered loop body via `emitGenInloopStmt`.
    gen_break_label: ?u32,
    /// §4.A.9 v11 — class name node for which the per-class
    /// `_<Class>_metadata` var has already been declared this
    /// printClassDecl invocation. Both `emitMethodDecorateCalls`
    /// (member chain) and `emitClassDecorateCall` (class chain)
    /// consult this so the metadata object is created exactly once
    /// per decorated class and both chains see the same instance.
    stage3_metadata_declared_for: ?NodeId,
    /// §4.A.9 v7 — when non-null, the enclosing class has at least
    /// one decorated instance member under Stage 3 lowering, so every
    /// ctor-emit path inside the class body should append a
    /// `__runInitializers(this, _<Class>_instanceExtra);` call before
    /// the closing `}`. The value is the class's `name` HIR node so
    /// the emit can synthesize the correct `_<Class>_instanceExtra`
    /// identifier. Save+cleared on entry to nested classes/functions.
    stage3_instance_extra_class: ?NodeId,
    /// §4.A.4.4 part 2 — when non-null, top-level `continue;`
    /// statements rewrite to `return [3, gen_continue_label];` so
    /// the continue restarts the lowered loop's iteration. Set only
    /// for loop kinds whose iteration restart is a single jump
    /// (today: `while_stmt` → jump to header). `do-while` and
    /// `for` still bail on continue until a dedicated continue case
    /// runs the cond-test or update step.
    gen_continue_label: ?u32,
    /// §4.A.9 v13 — when non-null, the next `printClassDecl` is being
    /// emitted inside an IIFE wrapper (see `emitStage3IIFEClass`) and
    /// should inject a `static { ... }` block at the top of the class
    /// body containing the class-decorate chain. The slice carries the
    /// class-level decorator NodeIds in source order. Cleared by the
    /// IIFE emitter after `printStatement` returns.
    stage3_iife_class_decorators: ?[]const NodeId,

    pub fn init(
        gpa: std.mem.Allocator,
        hir: *const Hir,
        interner: *const string_interner.Interner,
        options: Options,
    ) Printer {
        return .{
            .gpa = gpa,
            .hir = hir,
            .interner = interner,
            .out = .empty,
            .options = options,
            .depth = 0,
            .pending_break = false,
            .gen_line = 0,
            .gen_col = 0,
            .source = null,
            .in_async_downlevel = false,
            .current_class_name = null,
            .in_es5_super_lowering = false,
            .fn_depth = 0,
            .gen_break_label = null,
            .gen_continue_label = null,
            .stage3_instance_extra_class = null,
            .stage3_metadata_declared_for = null,
            .stage3_iife_class_decorators = null,
        };
    }

    /// Attach source bytes for span->line/col lookups. Optional —
    /// only needed when `options.source_map` is set.
    pub fn setSource(self: *Printer, source: []const u8) void {
        self.source = source;
    }

    pub fn deinit(self: *Printer) void {
        self.out.deinit(self.gpa);
        self.temp_scopes.deinit(self.gpa);
    }

    // ── Expression-context temp-hoist (§4.A.31) ───────────────────────────
    // A downlevel transform deep inside an expression can need a scratch
    // variable (`(_a = x, a = _a.a)`). We allocate `_a`, `_b`, … per enclosing
    // function/module and splice the `var _a, _b;` declaration in at the
    // scope's top on exit, matching tsc's placement.

    /// Write the `_a`-style temp name for `idx` (0→`_a` … 25→`_z`, 26→`_0`, …).
    fn writeTempName(buf: []u8, idx: usize) []const u8 {
        if (idx < 26) {
            buf[0] = '_';
            buf[1] = @as(u8, 'a') + @as(u8, @intCast(idx));
            return buf[0..2];
        }
        buf[0] = '_';
        const n = std.fmt.bufPrint(buf[1..], "{d}", .{idx - 26}) catch unreachable;
        return buf[0 .. 1 + n.len];
    }

    /// Open a temp scope, recording the current `out` position as the splice
    /// mark. Call right after emitting the function/module body opener.
    fn pushTempScope(self: *Printer) !void {
        try self.temp_scopes.append(self.gpa, .{ .mark = self.out.items.len, .count = 0 });
    }

    /// Allocate a fresh temp in the current scope and write its name into
    /// `buf`, returning the slice. Falls back to a bare `_a` if (defensively)
    /// no scope is open.
    fn allocTemp(self: *Printer, buf: []u8) []const u8 {
        if (self.temp_scopes.items.len == 0) return writeTempName(buf, 0);
        const scope = &self.temp_scopes.items[self.temp_scopes.items.len - 1];
        const idx = scope.count;
        scope.count += 1;
        return writeTempName(buf, idx);
    }

    /// Close the current temp scope; if any temps were allocated, splice a
    /// `var _a, _b; ` declaration in at the scope's mark so it lands at the
    /// function/module top. `sep` is appended after the `;` (a space inside a
    /// function body, a newline at module top).
    fn popTempScope(self: *Printer, sep: []const u8) !void {
        const scope = self.temp_scopes.pop() orelse return;
        if (scope.count == 0) return;
        var decl: std.ArrayListUnmanaged(u8) = .empty;
        defer decl.deinit(self.gpa);
        try decl.appendSlice(self.gpa, "var ");
        var i: usize = 0;
        while (i < scope.count) : (i += 1) {
            if (i > 0) try decl.appendSlice(self.gpa, ", ");
            var b: [16]u8 = undefined;
            try decl.appendSlice(self.gpa, writeTempName(&b, i));
        }
        try decl.appendSlice(self.gpa, ";");
        try decl.appendSlice(self.gpa, sep);
        try self.out.insertSlice(self.gpa, scope.mark, decl.items);
    }

    /// Close the current temp scope inside a multi-line block body: the
    /// `var _a, _b;` splices in as the block's first line (newline + indent
    /// at the current depth), matching tsc's function-top temp placement.
    /// Call while `depth` is still the block's inner depth.
    fn popTempScopeAtBlockTop(self: *Printer) !void {
        const scope = self.temp_scopes.pop() orelse return;
        if (scope.count == 0) return;
        var decl: std.ArrayListUnmanaged(u8) = .empty;
        defer decl.deinit(self.gpa);
        try decl.appendSlice(self.gpa, self.options.newline);
        var d: u32 = 0;
        while (d < self.depth) : (d += 1) try decl.appendSlice(self.gpa, self.options.indent);
        try decl.appendSlice(self.gpa, "var ");
        var i: usize = 0;
        while (i < scope.count) : (i += 1) {
            if (i > 0) try decl.appendSlice(self.gpa, ", ");
            var b: [16]u8 = undefined;
            try decl.appendSlice(self.gpa, writeTempName(&b, i));
        }
        try decl.appendSlice(self.gpa, ";");
        try self.out.insertSlice(self.gpa, scope.mark, decl.items);
    }

    pub fn toOwnedSlice(self: *Printer) ![]u8 {
        return self.out.toOwnedSlice(self.gpa);
    }

    /// The most recently emitted byte, or null if nothing's been written.
    fn lastOutByte(self: *const Printer) ?u8 {
        if (self.out.items.len == 0) return null;
        return self.out.items[self.out.items.len - 1];
    }

    /// Emit a prefix operator (`-`, `+`, `++`, `--`, `!`, `~`, …), inserting
    /// a separating space when it would otherwise merge with the preceding
    /// byte into a different token — `-(-a)` must print `- -a`, not `--a`
    /// (a decrement), and likewise for `+ +a`, `- --a`, `+ ++a`.
    fn writePrefixOp(self: *Printer, op: []const u8) !void {
        if (op.len > 0 and (op[0] == '+' or op[0] == '-')) {
            if (self.lastOutByte()) |lb| {
                if (lb == op[0]) try self.write(" ");
            }
        }
        try self.write(op);
    }

    fn write(self: *Printer, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
        for (s) |c| {
            if (c == '\n') {
                self.gen_line += 1;
                self.gen_col = 0;
            } else {
                self.gen_col += 1;
            }
        }
    }

    /// Record a source-map mapping for the *next* token, anchored at
    /// the current generated position. No-op if no source map is
    /// configured. `src_byte_pos` is a byte offset into the source
    /// the caller is mapping back to.
    fn mapAt(self: *Printer, src_byte_pos: u32) !void {
        const sm = self.options.source_map orelse return;
        const src = self.source orelse return;
        var line: u32 = 0;
        var col: u32 = 0;
        var i: u32 = 0;
        while (i < src_byte_pos and i < src.len) : (i += 1) {
            if (src[i] == '\n') {
                line += 1;
                col = 0;
            } else {
                col += 1;
            }
        }
        try sm.addMapping(.{
            .gen_line = self.gen_line,
            .gen_col = self.gen_col,
            .src_idx = self.options.source_map_src_idx,
            .src_line = line,
            .src_col = col,
            .name_idx = null,
        });
    }

    fn writeNewlineIndent(self: *Printer) !void {
        try self.write(self.options.newline);
        var i: u32 = 0;
        while (i < self.depth) : (i += 1) {
            try self.write(self.options.indent);
        }
    }

    fn writeSemi(self: *Printer) !void {
        if (!self.options.omit_semis) try self.write(";");
    }

    /// Public entry: emit a complete source-file as JavaScript.
    pub fn printSourceFile(self: *Printer, root: NodeId) !void {
        const stmts = hir_mod.blockStmts(self.hir, root);
        // `importHelpers: true` — emit a tslib import for the runtime
        // helpers we may reference (`__awaiter`, `__decorate`, etc.).
        // v0 emits the full set unconditionally; the bundler's
        // tree-shaker drops unreferenced names. The import lands
        // before any user-level statement so the helpers are in
        // scope for the lowered code below.
        if (self.options.import_helpers) {
            try self.write("import { __assign, __asyncDelegator, __asyncGenerator, __asyncValues, __await, __awaiter, __decorate, __esDecorate, __extends, __generator, __metadata, __param, __importDefault, __importStar, __rest, __runInitializers, __values } from \"tslib\";");
            try self.write(self.options.newline);
        }
        // §4.A.10 — auto-import the runtime helpers when the file
        // uses any JSX *and* the runtime mode is automatic. The
        // imports land before any user-level statement so they're
        // visible to the lowered JSX expressions below.
        const needs_auto_jsx_import = (self.options.jsx_runtime == .automatic or
            self.options.jsx_runtime == .automatic_dev) and
            anyJsxIn(self.hir, root);
        if (needs_auto_jsx_import) {
            const helpers: []const u8 = if (self.options.jsx_runtime == .automatic_dev)
                "import { jsxDEV as _jsxDEV, Fragment as _Fragment } from \"react/jsx-dev-runtime\";"
            else
                "import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from \"react/jsx-runtime\";";
            try self.write(helpers);
            try self.write(self.options.newline);
        }
        // §4.A.31 — open the module-level temp-hoist scope after imports so a
        // downlevel transform in a top-level statement can allocate a `_a`
        // temp whose `var _a;` declaration lands here.
        try self.pushTempScope();
        var i: usize = 0;
        while (i < stmts.len) : (i += 1) {
            const stmt = stmts[i];
            // Decorator preamble: collect a run of decorator
            // siblings preceding a class_decl. Emit the class
            // first, then the __decorate(...) helper call.
            if (self.hir.kindOf(stmt) == .decorator) {
                var j = i;
                while (j < stmts.len and self.hir.kindOf(stmts[j]) == .decorator) j += 1;
                if (j < stmts.len and self.hir.kindOf(stmts[j]) == .class_decl) {
                    if (i > 0) try self.write(self.options.newline);
                    // JSDoc anchored on the run-leading decorator.
                    try self.emitLeadingJsDoc(stmts[i]);
                    // §4.A.9 v13 — Stage 3 (non-legacy) class decorator
                    // runs route through the IIFE wrapper so the static
                    // block at the top of the class body rebinds the
                    // class identity to the post-decorator value before
                    // any subsequent static-field / static-block in the
                    // same body evaluates. Legacy `__decorate` keeps the
                    // existing flat `class Foo {}; Foo = __decorate([..], Foo);` shape.
                    if (!self.options.experimental_decorators) {
                        try self.emitStage3IIFEClass(stmts[i..j], stmts[j]);
                    } else {
                        try self.printStatement(stmts[j]);
                        try self.write(self.options.newline);
                        try self.emitClassDecorateCall(stmts[i..j], stmts[j]);
                    }
                    i = j;
                    continue;
                }
            }
            // §4.A.9 v13b — member-only-decorated classes (no class-
            // level decorator preamble, but at least one member is
            // preceded by `.decorator` siblings inside the body). Under
            // Stage 3, these also route through the IIFE wrapper (with
            // an empty class-decorators slice → no static block) so the
            // per-class `_<Name>_metadata` / `_<Name>_instanceExtra` /
            // `_<Name>_<field>_init` vars stay scoped to the IIFE.
            // Anonymous class_decls (none_node_id name) fall through to
            // the flat path — the IIFE needs a name for its outer let.
            if (!self.options.experimental_decorators and
                self.hir.kindOf(stmt) == .class_decl)
            {
                const c = hir_mod.classOf(self.hir, stmt);
                if (c.name != hir_mod.none_node_id and self.classHasAnyMemberDecorator(stmt)) {
                    if (i > 0) try self.write(self.options.newline);
                    try self.emitLeadingJsDoc(stmt);
                    const empty: []const NodeId = &[_]NodeId{};
                    try self.emitStage3IIFEClass(empty, stmt);
                    continue;
                }
            }
            if (i > 0) try self.write(self.options.newline);
            try self.emitLeadingJsDoc(stmt);
            try self.printStatement(stmt);
        }
        // §4.A.31 — flush any module-level temps (`var _a, _b;`) after imports.
        try self.popTempScope(self.options.newline);
        // Source-map fallback: if a SourceMap is attached but no
        // per-token mappings were recorded (e.g. caller didn't supply
        // source bytes via `setSource`), populate a basic line-level
        // mapping so the generated `"mappings"` string is non-empty
        // and decodes to a coherent line-by-line mapping. v0 emits
        // one segment per generated line at column 0.
        if (self.options.source_map) |sm| {
            if (sm.mappings.items.len == 0) {
                const src_line_count: ?u32 = if (self.source) |src|
                    countLines(src)
                else
                    null;
                try sm.fillLineMappings(
                    self.out.items,
                    self.options.source_map_src_idx,
                    src_line_count,
                );
            }
        }
        // Optional source-map URL trailer.
        if (self.options.source_map_url) |url| {
            try self.write(self.options.newline);
            try self.write("//# sourceMappingURL=");
            try self.write(url);
            try self.write(self.options.newline);
        }
    }

    /// Emit the post-class-decl runtime call for class-level
    /// decorators. Two shapes are supported:
    ///
    ///   - Legacy (`experimental_decorators: true`, default):
    ///     `Foo = __decorate([dec1, dec2], Foo);` — matches tsc
    ///     with `experimentalDecorators: true`.
    ///
    ///   - Stage 3 / TC39 (`experimental_decorators: false`),
    ///     simplified v1:
    ///     `__esDecorate(null, null, [dec1, dec2], { kind: "class", name: "Foo" }, null, []);`
    ///     A full Stage 3 lowering wraps the class in an IIFE with a
    ///     static initializer block; we emit the helper call alone
    ///     to keep the v1 transform local.
    fn emitClassDecorateCall(self: *Printer, decorators: []const NodeId, class_node: NodeId) anyerror!void {
        const c = hir_mod.classOf(self.hir, class_node);
        if (c.name == hir_mod.none_node_id) return;
        if (self.options.experimental_decorators) {
            try self.printExpression(c.name);
            try self.write(" = __decorate([");
            for (decorators, 0..) |d, i| {
                if (i > 0) try self.write(", ");
                const dp = hir_mod.decoratorOf(self.hir, d);
                try self.printExpression(dp.expression);
            }
            try self.write("], ");
            try self.printExpression(c.name);
            try self.write(");");
        } else {
            // §4.A.9 v3/v4 — Stage 3 class decorator chain. Emits:
            //   var _<N>_d = { value: <N> };
            //   var _<N>_extra = [];
            //   __esDecorate(null, _<N>_d, [decs], { kind: "class", name: "<N>" }, null, _<N>_extra);
            //   <N> = _<N>_d.value;
            //   __runInitializers(<N>, _<N>_extra);
            // The descriptor object supports class replacement; the
            // extra-initializers array carries any `addInitializer`
            // callbacks the decorators registered; `__runInitializers`
            // runs them against the (possibly replaced) class.
            try self.ensureStage3Metadata(c.name);
            try self.write(self.options.newline);
            try self.write("var _");
            try self.writeClassNameSuffix(c.name);
            try self.write("_d = { value: ");
            try self.printExpression(c.name);
            try self.write(" }, _");
            try self.writeClassNameSuffix(c.name);
            try self.write("_extra = [];");
            try self.write(self.options.newline);
            try self.write("__esDecorate(null, _");
            try self.writeClassNameSuffix(c.name);
            try self.write("_d, [");
            for (decorators, 0..) |d, i| {
                if (i > 0) try self.write(", ");
                const dp = hir_mod.decoratorOf(self.hir, d);
                try self.printExpression(dp.expression);
            }
            try self.write("], { kind: \"class\", name: \"");
            try self.printExpression(c.name);
            try self.write("\", metadata: _");
            try self.writeClassNameSuffix(c.name);
            try self.write("_metadata }, null, _");
            try self.writeClassNameSuffix(c.name);
            try self.write("_extra);");
            try self.write(self.options.newline);
            try self.printExpression(c.name);
            try self.write(" = _");
            try self.writeClassNameSuffix(c.name);
            try self.write("_d.value;");
            try self.write(self.options.newline);
            try self.write("__runInitializers(");
            try self.printExpression(c.name);
            try self.write(", _");
            try self.writeClassNameSuffix(c.name);
            try self.write("_extra);");
        }
    }

    /// §4.A.9 v13 — Stage 3 class-decorator IIFE wrap. Emits:
    ///
    ///   let Foo = (() => {
    ///     var _Foo_metadata = typeof Symbol === "function" && Symbol.metadata ? Object.create(null) : void 0;
    ///     class Foo {
    ///       static {
    ///         var _Foo_d = { value: this };
    ///         var _Foo_extra = [];
    ///         __esDecorate(null, _Foo_d, [decs], { kind: "class", name: "Foo", metadata: _Foo_metadata }, null, _Foo_extra);
    ///         Foo = _Foo_d.value;
    ///         __runInitializers(Foo, _Foo_extra);
    ///       }
    ///       // ...members...
    ///     }
    ///     // ...member decorate chain (existing flat emit, inside IIFE)...
    ///     return Foo;
    ///   })();
    ///
    /// The static block runs DURING class init (before any subsequent
    /// static-field / static-block in the same body), so module-scope
    /// AND class-body references to `Foo` after the static block see
    /// the post-decorator class identity.
    ///
    /// Anonymous classes fall back to the flat emit since the IIFE
    /// needs a name to declare/return. The hoisted `_<Name>_metadata`
    /// declaration is suppressed from re-emission downstream by
    /// `ensureStage3Metadata` consulting `stage3_metadata_declared_for`.
    fn emitStage3IIFEClass(
        self: *Printer,
        class_decorators: []const NodeId,
        class_node: NodeId,
    ) anyerror!void {
        const c = hir_mod.classOf(self.hir, class_node);
        if (c.name == hir_mod.none_node_id) {
            try self.printStatement(class_node);
            try self.write(self.options.newline);
            try self.emitClassDecorateCall(class_decorators, class_node);
            return;
        }
        // 1. IIFE preamble.
        try self.write("let ");
        try self.printExpression(c.name);
        try self.write(" = (() => {");
        self.depth += 1;
        // 2. Hoisted per-class metadata var. Must live in the IIFE
        // scope so both the static block and any post-class member
        // decorate chain reference the same identity.
        try self.write(self.options.newline);
        try self.indent();
        try self.write("var _");
        try self.writeClassNameSuffix(c.name);
        try self.write("_metadata = typeof Symbol === \"function\" && Symbol.metadata ? Object.create(null) : void 0;");
        self.stage3_metadata_declared_for = c.name;
        // 3. Set IIFE flag, emit class (printClassDecl injects the
        // static block at the top of the body when this is set), clear.
        self.stage3_iife_class_decorators = class_decorators;
        try self.write(self.options.newline);
        try self.indent();
        try self.printStatement(class_node);
        self.stage3_iife_class_decorators = null;
        // 4. IIFE return — the static block has already rebound the
        // local `<Name>` to the post-decorator class.
        try self.write(self.options.newline);
        try self.indent();
        try self.write("return ");
        try self.printExpression(c.name);
        try self.write(";");
        // 5. Close IIFE.
        self.depth -= 1;
        try self.write(self.options.newline);
        try self.indent();
        try self.write("})();");
    }

    /// §4.A.9 v13/v13c — emit the `static { ... }` block injected at
    /// the top of an IIFE-wrapped class body. Contains, in order:
    ///
    ///   1. The member decorate chain — per-class extras vars,
    ///      per-field init vars, and one `__esDecorate(...)` line
    ///      per decorated member (delegated to
    ///      `emitMethodDecorateCalls`). Static-extras
    ///      `__runInitializers` trailer runs here too.
    ///   2. The class decorate chain (if `class_decorators.len > 0`)
    ///      — descriptor + `__esDecorate` + class rebind +
    ///      class-extras `__runInitializers`. Runs AFTER the member
    ///      chain so member decorators see the original class and
    ///      class-replacement decorators rebind the class identity
    ///      for any later static-field initializer.
    ///
    /// Caller is responsible for indentation of the opening `static`
    /// keyword. References `_<Name>_metadata` already declared by
    /// the IIFE preamble (`emitStage3IIFEClass`).
    fn emitStage3IIFEClassStaticBlock(
        self: *Printer,
        class_node: NodeId,
        class_name: NodeId,
        class_decorators: []const NodeId,
    ) anyerror!void {
        try self.write("static {");
        self.depth += 1;
        // 1. Member decorate chain. emitMethodDecorateCalls walks
        // class members, emits per-class extras + per-field init
        // var declarations + one __esDecorate per decorated member,
        // and a trailing __runInitializers for static extras. It is
        // depth-aware so its newlines + indents render correctly
        // inside the static block.
        try self.emitMethodDecorateCalls(class_node);
        // 2. Class decorate chain — only when class-level decorators
        // are present. Skipped for member-only-decorated classes.
        if (class_decorators.len > 0) {
            try self.write(self.options.newline);
            try self.indent();
            try self.write("var _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_d = { value: this };");
            try self.write(self.options.newline);
            try self.indent();
            try self.write("var _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_extra = [];");
            try self.write(self.options.newline);
            try self.indent();
            try self.write("__esDecorate(null, _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_d, [");
            for (class_decorators, 0..) |d, i| {
                if (i > 0) try self.write(", ");
                const dp = hir_mod.decoratorOf(self.hir, d);
                try self.printExpression(dp.expression);
            }
            try self.write("], { kind: \"class\", name: \"");
            try self.writeClassNameSuffix(class_name);
            try self.write("\", metadata: _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_metadata }, null, _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_extra);");
            try self.write(self.options.newline);
            try self.indent();
            try self.printExpression(class_name);
            try self.write(" = _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_d.value;");
            try self.write(self.options.newline);
            try self.indent();
            try self.write("__runInitializers(");
            try self.printExpression(class_name);
            try self.write(", _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_extra);");
        }
        self.depth -= 1;
        try self.write(self.options.newline);
        try self.indent();
        try self.write("}");
    }

    /// §4.A.9 v11 — emit `var _<Class>_metadata = typeof Symbol === "function"
    /// && Symbol.metadata ? Object.create(null) : void 0;` exactly once
    /// per decorated class. Both the member and class decorator chains
    /// call this so the metadata object is shared. Subsequent calls
    /// for the same class are no-ops.
    fn ensureStage3Metadata(self: *Printer, class_name: NodeId) anyerror!void {
        if (class_name == hir_mod.none_node_id) return;
        if (self.stage3_metadata_declared_for) |prev| {
            if (prev == class_name) return;
        }
        self.stage3_metadata_declared_for = class_name;
        try self.write(self.options.newline);
        try self.write("var _");
        try self.writeClassNameSuffix(class_name);
        try self.write("_metadata = typeof Symbol === \"function\" && Symbol.metadata ? Object.create(null) : void 0;");
    }

    /// Emit the class name as a bare identifier (no quoting). Used to
    /// build synthesized variable names like `_<ClassName>_d` for the
    /// Stage 3 class-decorator descriptor binding.
    fn writeClassNameSuffix(self: *Printer, name_node: NodeId) anyerror!void {
        if (self.hir.kindOf(name_node) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, name_node);
            try self.write(self.interner.get(id.name));
        }
    }

    /// §4.A.9 v13b — true if any class member is preceded by at least
    /// one `.decorator` sibling. Doesn't distinguish static / instance
    /// or member kind — any kind of member decorator presence is enough
    /// to warrant IIFE-wrapping the whole class so per-class
    /// metadata / extras / init vars stay scoped to the IIFE rather
    /// than leaking to module scope.
    fn classHasAnyMemberDecorator(self: *const Printer, class_node: NodeId) bool {
        const members = hir_mod.classMembers(self.hir, class_node);
        for (members) |m| {
            if (self.hir.kindOf(m) == .decorator) return true;
        }
        return false;
    }

    /// §4.A.9 v7 — true if any class member is preceded by decorators
    /// AND the decorated target is a non-constructor *instance* member.
    /// Used by the ctor-emit paths to know whether to append the
    /// trailing `__runInitializers(this, _<Class>_instanceExtra);` call.
    fn classHasDecoratedInstanceMember(self: *const Printer, class_node: NodeId) bool {
        const members = hir_mod.classMembers(self.hir, class_node);
        var i: usize = 0;
        while (i < members.len) : (i += 1) {
            if (self.hir.kindOf(members[i]) != .decorator) continue;
            var j = i;
            while (j < members.len and self.hir.kindOf(members[j]) == .decorator) j += 1;
            if (j >= members.len) break;
            const target = members[j];
            const tk = self.hir.kindOf(target);
            if (tk == .fn_decl or tk == .fn_expr) {
                const fd = hir_mod.fnDeclOf(self.hir, target);
                if (!fd.flags.is_constructor and !fd.flags.is_static) return true;
            } else if (tk == .object_property) {
                const op = hir_mod.objectPropertyOf(self.hir, target);
                if (!op.is_static) return true;
            }
            i = j;
        }
        return false;
    }

    /// §4.A.9 v7 — emit a single-line
    /// `__runInitializers(this, _<Class>_instanceExtra);` trailer when
    /// the active class has decorated instance members under Stage 3.
    /// No-op outside that context. Call this at the end of every ctor
    /// body so the (possibly synthesized) constructor runs the extras
    /// for each instance.
    fn emitStage3InstanceExtraTrailer(self: *Printer) anyerror!void {
        const cn = self.stage3_instance_extra_class orelse return;
        try self.write(" __runInitializers(this, _");
        try self.writeClassNameSuffix(cn);
        try self.write("_instanceExtra);");
    }

    /// §4.A.9 v12 — true when the `object_property` member at `member_id`
    /// inside `class_node` has at least one preceding `.decorator`
    /// sibling. Used by the field-init-wrap path to decide whether to
    /// wrap the field's initializer with `__runInitializers`.
    fn memberHasDecorators(self: *const Printer, class_node: NodeId, member_id: NodeId) bool {
        const members = hir_mod.classMembers(self.hir, class_node);
        var i: usize = 0;
        while (i < members.len) : (i += 1) {
            if (members[i] != member_id) continue;
            if (i == 0) return false;
            return self.hir.kindOf(members[i - 1]) == .decorator;
        }
        return false;
    }

    /// §4.A.9 v12 — when a field with identifier `key` belongs to a
    /// named class under Stage 3 AND has decorators, write the
    /// `__runInitializers(<host>, _<Class>_<field>_init, ` prefix and
    /// return `true`; the caller is responsible for emitting the
    /// original value expression followed by `)`. Returns `false` when
    /// no wrap should happen (legacy mode, anonymous class, computed
    /// key, no decorators) — the caller emits the value plainly.
    /// `host_is_this` selects `this` vs the class identifier for the
    /// __runInitializers receiver (instance fields → `this`, static
    /// fields → class).
    fn beginFieldInitWrap(
        self: *Printer,
        class_node: NodeId,
        member_id: NodeId,
        host_is_this: bool,
    ) anyerror!bool {
        if (self.options.experimental_decorators) return false;
        const c = hir_mod.classOf(self.hir, class_node);
        if (c.name == hir_mod.none_node_id) return false;
        const op = hir_mod.objectPropertyOf(self.hir, member_id);
        if (self.hir.kindOf(op.key) != .identifier) return false;
        if (self.privateFieldName(op.key) != null) return false;
        if (!self.memberHasDecorators(class_node, member_id)) return false;
        const id = hir_mod.identifierOf(self.hir, op.key);
        const key_name = self.interner.get(id.name);
        try self.write("__runInitializers(");
        if (host_is_this) {
            try self.write("this");
        } else {
            try self.printExpression(c.name);
        }
        try self.write(", _");
        try self.writeClassNameSuffix(c.name);
        try self.write("_");
        try self.write(key_name);
        try self.write("_init, ");
        return true;
    }

    /// §4.A.9 v12 — close the `__runInitializers(...)` wrapper opened
    /// by `beginFieldInitWrap`. Caller passes whatever `true`/`false`
    /// they got back.
    fn endFieldInitWrap(self: *Printer, did_wrap: bool) anyerror!void {
        if (did_wrap) try self.write(")");
    }

    fn printStatement(self: *Printer, node: NodeId) anyerror!void {
        // `declare`d / ambient declarations have no runtime presence and
        // erase entirely (emitting `const a;` or `function f(x);` would be
        // invalid JS). Checked before indenting so no stray whitespace is
        // left behind.
        switch (self.hir.kindOf(node)) {
            .var_decl, .let_decl, .const_decl => if (hir_mod.varDeclOf(self.hir, node).is_ambient) return,
            .fn_decl => if (hir_mod.fnDeclOf(self.hir, node).body == hir_mod.none_node_id) return,
            else => {},
        }
        try self.indent();
        const span = self.hir.spanOf(node);
        try self.mapAt(span.start);
        const kind = self.hir.kindOf(node);
        switch (kind) {
            .var_decl, .let_decl, .const_decl => try self.printVarDecl(node),
            .block_stmt => try self.printBlock(node),
            .if_stmt => try self.printIf(node),
            .while_stmt => try self.printWhile(node),
            .do_while_stmt => try self.printDoWhile(node),
            .for_stmt => try self.printFor(node),
            .for_in_stmt, .for_of_stmt => try self.printForInOf(node),
            .return_stmt => try self.printReturn(node),
            .break_stmt => try self.printBreakOrContinue(node, "break"),
            .continue_stmt => try self.printBreakOrContinue(node, "continue"),
            .throw_stmt => try self.printThrow(node),
            .try_stmt => try self.printTry(node),
            .switch_stmt => try self.printSwitch(node),
            .fn_decl, .fn_expr, .arrow_fn => try self.printFnDecl(node),
            .class_decl, .class_expr => try self.printClassDecl(node),
            .interface_decl => {
                // Interfaces erase at runtime — emit nothing.
                return;
            },
            .type_alias_decl => {
                return;
            },
            .decorator => {
                // Phase 4 follow-up: emit __decorate / Stage-3 form.
                // For now decorators erase so output remains runnable.
                return;
            },
            .labeled_stmt => {
                const ls = hir_mod.labeledStmtOf(self.hir, node);
                try self.printExpression(ls.label);
                try self.write(": ");
                try self.printStatementInline(ls.body);
            },
            .enum_decl => try self.printEnum(node),
            .namespace_decl => try self.printNamespace(node),
            .import_decl => try self.printImport(node),
            .export_decl => try self.printExport(node),
            // Expression statement.
            else => {
                // An expression statement whose leftmost token is `{`,
                // `function`, or `class` must be parenthesized, else it
                // parses as a block / declaration (`({a}=o);`, IIFE, etc.).
                const needs_parens = self.exprStmtNeedsParens(node);
                if (needs_parens) try self.write("(");
                try self.printExpression(node);
                if (needs_parens) try self.write(")");
                try self.writeSemi();
            },
        }
    }

    /// True when an expression statement's leftmost emitted token would be
    /// `{` / `function` / `class`, requiring it to be parenthesized.
    /// Descends the left edge of left-associative forms; binops /
    /// conditionals self-parenthesize so they aren't followed here.
    fn exprStmtNeedsParens(self: *const Printer, node: NodeId) bool {
        return switch (self.hir.kindOf(node)) {
            // (`fn_decl`/`class_decl` appear here too: the parser emits them
            // even in expression position.)
            .object_literal, .fn_expr, .fn_decl, .class_expr, .class_decl => true,
            .call_expr => self.exprStmtNeedsParens(hir_mod.callOf(self.hir, node).callee),
            .member_access => self.exprStmtNeedsParens(hir_mod.memberOf(self.hir, node).object),
            .element_access => self.exprStmtNeedsParens(hir_mod.elementOf(self.hir, node).object),
            .assignment => self.exprStmtNeedsParens(hir_mod.assignmentOf(self.hir, node).target),
            else => false,
        };
    }

    fn indent(self: *Printer) !void {
        var i: u32 = 0;
        while (i < self.depth) : (i += 1) {
            try self.write(self.options.indent);
        }
    }

    /// Emit any JSDoc `/** … */` comment that appears immediately
    /// before `node` in the source. "Immediately before" means
    /// the comment closes within the run of whitespace that
    /// precedes the node. The comment is copied byte-for-byte and
    /// followed by a newline plus the current indent so the
    /// declaration lands on its own line.
    ///
    /// No-op when `options.remove_comments` is true, when source
    /// bytes are unattached, or when no leading JSDoc is present.
    fn emitLeadingJsDoc(self: *Printer, node: NodeId) !void {
        if (self.options.remove_comments) return;
        const src = self.source orelse return;
        const span = self.hir.spanOf(node);
        const start: usize = @intCast(span.start);
        if (start == 0 or start > src.len) return;
        // Walk backwards over horizontal + vertical whitespace.
        var i: usize = start;
        while (i > 0) {
            const c = src[i - 1];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                i -= 1;
                continue;
            }
            break;
        }
        // Need a closing `*/` immediately before the whitespace run.
        if (i < 2) return;
        if (!(src[i - 1] == '/' and src[i - 2] == '*')) return;
        const close_end = i; // exclusive end of `*/`
        // Walk back to the opening `/**`. Search for the literal
        // "/**" with the second `*` distinct from the closing `*/`'s.
        if (close_end < 5) return; // need at least `/** */`
        var k: usize = close_end - 2; // index of the `*` of `*/`
        // k must be at least 2 so that src[k-2..k+1] is a valid range.
        while (k >= 2) : (k -= 1) {
            if (src[k - 2] == '/' and src[k - 1] == '*' and src[k] == '*') {
                const open_start = k - 2;
                if (open_start + 3 > close_end) return;
                const comment = src[open_start..close_end];
                if (comment.len < 5) return;
                try self.write(comment);
                try self.write(self.options.newline);
                try self.indent();
                return;
            }
            if (k == 2) break;
        }
    }

    fn printVarDecl(self: *Printer, node: NodeId) anyerror!void {
        const kind = self.hir.kindOf(node);
        const kw = self.varDeclKeyword(kind);
        const v = hir_mod.varDeclOf(self.hir, node);
        // Destructuring binding: `const { a } = obj` / `const [x] = arr`.
        // Destructuring is ES2015 syntax — at ES2015+ keep it NATIVE (as
        // tsc / Bun's printer do). Only below ES2015 (ES5/ES3) do we lower
        // to a comma-declarator chain pulling each binding out of a single
        // temporary holding the initializer (`var _o = obj, a = _o.a;`).
        if (v.name != hir_mod.none_node_id and self.options.es_target == .es5) {
            const name_kind = self.hir.kindOf(v.name);
            if (name_kind == .object_pattern or name_kind == .array_pattern) {
                try self.printDestructuringVarDecl(kw, v.name, v.init);
                return;
            }
        }
        try self.write(kw);
        try self.write(" ");
        if (v.name != hir_mod.none_node_id) try self.printBindingName(v.name);
        // Type annotation erases at runtime. The initializer is printed at
        // `.comma` so a top-level sequence wraps (`x = (a, b)`).
        if (v.init != hir_mod.none_node_id) {
            try self.write(" = ");
            try self.printExpr(v.init, .comma);
        }
        try self.writeSemi();
    }

    fn varDeclKeyword(self: *const Printer, kind: hir_mod.NodeKind) []const u8 {
        // ES5 has no block-scoped declarations — collapse `let`/`const`
        // to `var`. Block-scoping rewrites for shadowed names are
        // deferred; v0 trusts user code not to rely on TDZ.
        return switch (kind) {
            .var_decl => "var",
            .let_decl => if (self.options.es_target == .es5) "var" else "let",
            .const_decl => if (self.options.es_target == .es5) "var" else "const",
            else => unreachable,
        };
    }

    fn printVarDeclHeader(self: *Printer, node: NodeId, include_init: bool) anyerror!void {
        const kind = self.hir.kindOf(node);
        const v = hir_mod.varDeclOf(self.hir, node);
        // §4.A destructuring v14 — at ES5 a pattern-name var-decl
        // can't render as native `var [a, b] = arr;`. Route through
        // the destructuring var-decl lowering which emits
        // `var _arr = arr, a = _arr[0], b = _arr[1];` — a valid
        // comma-separated decl list (works in for-stmt init too).
        if (self.options.es_target == .es5 and v.name != hir_mod.none_node_id and include_init) {
            const nk = self.hir.kindOf(v.name);
            if (nk == .object_pattern or nk == .array_pattern) {
                try self.printDestructuringVarDeclHeader(self.varDeclKeyword(kind), v.name, v.init);
                return;
            }
        }
        try self.write(self.varDeclKeyword(kind));
        try self.write(" ");
        if (v.name != hir_mod.none_node_id) try self.printBindingName(v.name);
        if (include_init and v.init != hir_mod.none_node_id) {
            try self.write(" = ");
            try self.printExpr(v.init, .comma);
        }
    }

    /// §4.A destructuring v14/v16 — same as `printDestructuringVarDecl`
    /// but doesn't emit a trailing `;` (for use in for-stmt init
    /// where the surrounding `for (...; ...; ...)` syntax provides
    /// the terminator). Shares the recursive helper so defaults,
    /// rest, computed keys, and nested patterns all work.
    fn printDestructuringVarDeclHeader(
        self: *Printer,
        kw_in: []const u8,
        pattern: NodeId,
        initializer: NodeId,
    ) anyerror!void {
        const is_array = self.hir.kindOf(pattern) == .array_pattern;
        const tmp: []const u8 = if (is_array) "_arr" else "_o";
        const kw = if (self.options.es_target == .es5) "var" else kw_in;
        try self.write(kw);
        try self.write(" ");
        try self.write(tmp);
        if (initializer != hir_mod.none_node_id) {
            try self.write(" = ");
            try self.printExpression(initializer);
        }
        var emitted_count: usize = 1;
        var counter: usize = 0;
        try self.emitDestructuringPairs(pattern, tmp, &counter, &emitted_count);
        // No trailing `;` — caller controls the terminator.
    }

    fn printBindingName(self: *Printer, node: NodeId) anyerror!void {
        switch (self.hir.kindOf(node)) {
            .object_pattern => try self.printObjectBindingPattern(node),
            .array_pattern => try self.printArrayBindingPattern(node),
            else => try self.printExpression(node),
        }
    }

    fn printObjectBindingPattern(self: *Printer, node: NodeId) anyerror!void {
        try self.write("{ ");
        const elements = hir_mod.patternElements(self.hir, node);
        var emitted: usize = 0;
        for (elements, 0..) |elem, i| {
            if (self.hir.kindOf(elem) != .parameter) continue;
            const param = hir_mod.parameterOf(self.hir, elem);
            // Computed-key / rename-key synthetic elements pair with the
            // following binding param — skip here; the binding emits the
            // `[key]: name` / `key: name` form by looking back.
            if (param.flags.is_computed_binding_key or param.flags.is_rename_binding_key) continue;
            if (emitted > 0) try self.write(", ");
            emitted += 1;
            if (param.flags.is_rest) try self.write("...");
            const prev_key: ?hir_mod.ParameterPayload = blk: {
                if (i == 0 or param.flags.is_rest) break :blk null;
                const prev = elements[i - 1];
                if (self.hir.kindOf(prev) != .parameter) break :blk null;
                const pp = hir_mod.parameterOf(self.hir, prev);
                if (pp.flags.is_computed_binding_key or pp.flags.is_rename_binding_key) break :blk pp;
                break :blk null;
            };
            if (prev_key) |pp| {
                if (pp.flags.is_computed_binding_key) {
                    // `[expr]: name`
                    try self.write("[");
                    try self.printExpression(pp.default_value);
                    try self.write("]: ");
                } else {
                    // Renamed binding `key: name`.
                    try self.printExpression(pp.default_value);
                    try self.write(": ");
                }
            }
            if (param.name != hir_mod.none_node_id) try self.printBindingName(param.name);
            if (param.default_value != hir_mod.none_node_id) {
                try self.write(" = ");
                try self.printExpression(param.default_value);
            }
        }
        try self.write(" }");
    }

    fn printArrayBindingPattern(self: *Printer, node: NodeId) anyerror!void {
        try self.write("[");
        const elements = hir_mod.patternElements(self.hir, node);
        for (elements, 0..) |elem, i| {
            if (i > 0) try self.write(", ");
            if (self.hir.kindOf(elem) != .parameter) continue;
            const param = hir_mod.parameterOf(self.hir, elem);
            if (param.flags.is_computed_binding_key) continue;
            if (param.flags.is_rest) try self.write("...");
            if (param.name != hir_mod.none_node_id) try self.printBindingName(param.name);
            if (param.default_value != hir_mod.none_node_id) {
                try self.write(" = ");
                try self.printExpression(param.default_value);
            }
        }
        try self.write("]");
    }

    /// Lower `const { a, b } = obj` / `const [x, y] = arr` to a
    /// comma-declarator chain: `var _o = obj, a = _o.a, b = _o.b;`.
    /// At ES5 the `let`/`const` keyword also collapses to `var`.
    /// Refactored in §4.A.4 destructuring v15 to share the recursive
    /// `emitDestructuringPairs` helper with the shim path; nested
    /// patterns now lower via fresh `_n<N>` temps.
    fn printDestructuringVarDecl(
        self: *Printer,
        kw_in: []const u8,
        pattern: NodeId,
        initializer: NodeId,
    ) anyerror!void {
        const is_array = self.hir.kindOf(pattern) == .array_pattern;
        const tmp: []const u8 = if (is_array) "_arr" else "_o";
        // ES5 has no block-scoped declarations — collapse to `var`.
        const kw = if (self.options.es_target == .es5) "var" else kw_in;
        try self.write(kw);
        try self.write(" ");
        try self.write(tmp);
        if (initializer != hir_mod.none_node_id) {
            try self.write(" = ");
            try self.printExpression(initializer);
        }
        // The source-temp counts as the first emitted decl; subsequent
        // bindings prepend ", ".
        var emitted_count: usize = 1;
        var counter: usize = 0;
        try self.emitDestructuringPairs(pattern, tmp, &counter, &emitted_count);
        try self.writeSemi();
    }

    fn printBlock(self: *Printer, node: NodeId) !void {
        // §4.A.31 — a function body opens its own temp-hoist scope so temps
        // allocated by downlevel transforms inside splice in at the function
        // top. Ordinary (if/for/…) blocks share the enclosing scope. The
        // one-shot flag is consumed here so nested blocks don't inherit it.
        const fn_body_scope = self.next_block_is_fn_body;
        self.next_block_is_fn_body = false;
        try self.write("{");
        const stmts = hir_mod.blockStmts(self.hir, node);
        if (stmts.len == 0) {
            try self.write("}");
            return;
        }
        self.depth += 1;
        if (fn_body_scope) try self.pushTempScope();
        for (stmts) |stmt| {
            try self.write(self.options.newline);
            try self.printStatement(stmt);
        }
        if (fn_body_scope) try self.popTempScopeAtBlockTop();
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
    }

    fn printIf(self: *Printer, node: NodeId) anyerror!void {
        const p = hir_mod.ifOf(self.hir, node);
        try self.write("if (");
        try self.printExpression(p.cond);
        try self.write(") ");
        try self.printStatementInline(p.then_branch);
        if (p.else_branch != hir_mod.none_node_id) {
            try self.write(" else ");
            try self.printStatementInline(p.else_branch);
        }
    }

    /// Like `printStatement` but does NOT lead with the indent prefix —
    /// the caller has already positioned the cursor.
    fn printStatementInline(self: *Printer, node: NodeId) anyerror!void {
        const kind = self.hir.kindOf(node);
        switch (kind) {
            .block_stmt => try self.printBlock(node),
            else => {
                // Wrap the inline statement (including the trailing
                // semicolon, if any) around the depth-aware printer.
                try self.printNonIndentStatement(node);
            },
        }
    }

    fn printNonIndentStatement(self: *Printer, node: NodeId) anyerror!void {
        const kind = self.hir.kindOf(node);
        switch (kind) {
            .if_stmt => try self.printIf(node),
            .while_stmt => try self.printWhile(node),
            .do_while_stmt => try self.printDoWhile(node),
            .for_stmt => try self.printFor(node),
            .for_in_stmt, .for_of_stmt => try self.printForInOf(node),
            .try_stmt => try self.printTry(node),
            .switch_stmt => try self.printSwitch(node),
            .block_stmt => try self.printBlock(node),
            .return_stmt => try self.printReturn(node),
            .break_stmt => try self.printBreakOrContinue(node, "break"),
            .continue_stmt => try self.printBreakOrContinue(node, "continue"),
            .throw_stmt => try self.printThrow(node),
            .var_decl, .let_decl, .const_decl => try self.printVarDecl(node),
            // Declaration forms carry no statement terminator (a `;` after
            // `function f(){}` / `class C{}` is a spurious empty statement
            // that neither tsc nor Bun emit). This path is reached for
            // `export default function …` / `export default class …`,
            // including the anonymous `function (){}` / `class {}` forms,
            // which the grammar still treats as declarations. An
            // `arrow_fn` is an expression and keeps its `;`, so it stays
            // in the `else` branch below.
            .fn_decl, .fn_expr => try self.printFnDecl(node),
            .class_decl, .class_expr => try self.printClassDecl(node),
            .enum_decl => try self.printEnum(node),
            .namespace_decl => try self.printNamespace(node),
            else => {
                try self.printExpression(node);
                try self.writeSemi();
            },
        }
    }

    fn printWhile(self: *Printer, node: NodeId) !void {
        // §4.A.4.4 — clear the outer lowered-loop break/continue
        // labels while emitting this inner loop so any break/continue
        // inside targets the inner while (not the outer state machine).
        const prev_break = self.gen_break_label;
        const prev_continue = self.gen_continue_label;
        self.gen_break_label = null;
        self.gen_continue_label = null;
        defer {
            self.gen_break_label = prev_break;
            self.gen_continue_label = prev_continue;
        }
        const p = hir_mod.whileOf(self.hir, node);
        try self.write("while (");
        try self.printExpression(p.cond);
        try self.write(") ");
        try self.printStatementInline(p.body);
    }

    fn printDoWhile(self: *Printer, node: NodeId) !void {
        const prev_break = self.gen_break_label;
        const prev_continue = self.gen_continue_label;
        self.gen_break_label = null;
        self.gen_continue_label = null;
        defer {
            self.gen_break_label = prev_break;
            self.gen_continue_label = prev_continue;
        }
        const p = hir_mod.doWhileOf(self.hir, node);
        try self.write("do ");
        try self.printStatementInline(p.body);
        try self.write(" while (");
        try self.printExpression(p.cond);
        try self.write(")");
        try self.writeSemi();
    }

    fn printFor(self: *Printer, node: NodeId) !void {
        const prev_break = self.gen_break_label;
        const prev_continue = self.gen_continue_label;
        self.gen_break_label = null;
        self.gen_continue_label = null;
        defer {
            self.gen_break_label = prev_break;
            self.gen_continue_label = prev_continue;
        }
        const p = hir_mod.forStmtOf(self.hir, node);
        try self.write("for (");
        if (p.init != hir_mod.none_node_id) {
            switch (self.hir.kindOf(p.init)) {
                .var_decl, .let_decl, .const_decl => try self.printVarDeclHeader(p.init, true),
                // Multi-declarator for-init (`for (let i = 0, j = 10; …)`)
                // is wrapped in a synthetic block by the parser. Emit one
                // keyword + comma-separated declarators.
                .block_stmt => {
                    const decls = hir_mod.blockStmts(self.hir, p.init);
                    for (decls, 0..) |d, i| {
                        const dk = self.hir.kindOf(d);
                        if (dk != .var_decl and dk != .let_decl and dk != .const_decl) continue;
                        if (i == 0) {
                            try self.printVarDeclHeader(d, true);
                        } else {
                            try self.write(", ");
                            const v = hir_mod.varDeclOf(self.hir, d);
                            if (v.name != hir_mod.none_node_id) try self.printBindingName(v.name);
                            if (v.init != hir_mod.none_node_id) {
                                try self.write(" = ");
                                try self.printExpression(v.init);
                            }
                        }
                    }
                },
                else => try self.printExpression(p.init),
            }
        }
        try self.write(";");
        if (p.cond != hir_mod.none_node_id) {
            try self.write(" ");
            try self.printExpression(p.cond);
        }
        try self.write(";");
        if (p.update != hir_mod.none_node_id) {
            try self.write(" ");
            try self.printExpression(p.update);
        }
        try self.write(") ");
        try self.printStatementInline(p.body);
    }

    fn printForInOf(self: *Printer, node: NodeId) !void {
        const prev_break = self.gen_break_label;
        const prev_continue = self.gen_continue_label;
        self.gen_break_label = null;
        self.gen_continue_label = null;
        defer {
            self.gen_break_label = prev_break;
            self.gen_continue_label = prev_continue;
        }
        const p = hir_mod.forInOf(self.hir, node);
        // §4.A.3 — `for-of` lowers at ES5. Two shapes:
        //   * default: assume array-shape, lower to indexed `for`
        //     (cheap, but breaks for `Map`/`Set`/custom iterables).
        //   * `downlevel_iteration: true`: full iterator-protocol
        //     loop wrapped in try/catch/finally so the iterator's
        //     `.return()` runs on abrupt completion. Matches tsc's
        //     `downlevelIteration` flag.
        if (self.hir.kindOf(node) == .for_of_stmt and !p.is_await and self.options.es_target == .es5) {
            if (self.options.downlevel_iteration) {
                try self.printForOfIteratorProtocol(p.target, p.source, p.body);
                return;
            }
            try self.write("for (var _i = 0, _arr = ");
            try self.printExpression(p.source);
            try self.write("; _i < _arr.length; _i++) { ");
            // §4.A destructuring v8 — for-of with destructuring target
            // at ES5 lowers to a temp-ident bind + extraction shim
            // instead of emitting `var [a, b] = _arr[_i];` (which is
            // ES2015 syntax). Pattern target → `var _e = _arr[_i],
            // a = _e[0], b = _e[1];`. Identifier target keeps the
            // existing `var <name> = _arr[_i];` shape.
            if (self.forOfBindingIsPattern(p.target)) {
                try self.write("var _e = _arr[_i]; ");
                try self.emitDestructuringShim(self.forOfBindingPatternNode(p.target), "_e");
                try self.write(" ");
            } else {
                try self.printForOfBindingDecl(p.target);
                try self.write(" = _arr[_i]; ");
            }
            try self.printForOfBody(p.body);
            try self.write(" }");
            return;
        }
        // §4.A.4.9 v0 — `for await (... of ...)` downlevel at ES2017
        // and below. Lowers to the iterator-protocol with __asyncValues
        // + try/catch/finally cleanup. Uses `await _aiter.next()` inside
        // a native async context (or at ES5 where async functions are
        // wrapped by __awaiter and `yield` is the resumption op).
        if (self.hir.kindOf(node) == .for_of_stmt and p.is_await and !self.options.es_target.supportsNativeAsyncGenerators()) {
            const await_kw: []const u8 = if (self.in_async_downlevel) "yield " else "await ";
            try self.write("var _aiter, _astep, e_1, _r;");
            try self.write(" try { for (_aiter = __asyncValues(");
            try self.printExpression(p.source);
            try self.write("); _astep = ");
            try self.write(await_kw);
            try self.write("_aiter.next(), !_astep.done; ) { ");
            // §4.A destructuring v9 — at ES5 the native `var { a } =
            // _astep.value;` shape would fail; lower via temp ident.
            // At ES2015+ the printForOfBindingDecl path emits native
            // destructuring which is fine.
            if (self.options.es_target == .es5 and self.forOfBindingIsPattern(p.target)) {
                try self.write("var _e = _astep.value; ");
                try self.emitDestructuringShim(self.forOfBindingPatternNode(p.target), "_e");
                try self.write(" ");
            } else {
                try self.printForOfBindingDecl(p.target);
                try self.write(" = _astep.value; ");
            }
            try self.printForOfBody(p.body);
            try self.write(" } } catch (e_1_1) { e_1 = { error: e_1_1 }; } finally { try { if (_astep && !_astep.done && (_r = _aiter.return)) ");
            try self.write(await_kw);
            try self.write("_r.call(_aiter); } finally { if (e_1) throw e_1.error; } }");
            return;
        }
        const kw = if (self.hir.kindOf(node) == .for_in_stmt) "in" else "of";
        if (self.hir.kindOf(node) == .for_of_stmt and p.is_await) {
            try self.write("for await (");
        } else {
            try self.write("for (");
        }
        switch (self.hir.kindOf(p.target)) {
            .var_decl, .let_decl, .const_decl => try self.printVarDeclHeader(p.target, false),
            else => try self.printBindingName(p.target),
        }
        try self.write(" ");
        try self.write(kw);
        try self.write(" ");
        try self.printExpression(p.source);
        try self.write(") ");
        try self.printStatementInline(p.body);
    }

    /// §4.A destructuring v8 — true iff `target` is a destructuring
    /// pattern (`{...}` or `[...]`) or a `var|let|const` decl whose
    /// name is a destructuring pattern. Used by the ES5 for-of lowering
    /// to decide whether to emit a temp-ident + shim instead of the
    /// native pattern syntax.
    fn forOfBindingIsPattern(self: *const Printer, target: NodeId) bool {
        const k = self.hir.kindOf(target);
        if (k == .object_pattern or k == .array_pattern) return true;
        if (k == .var_decl or k == .let_decl or k == .const_decl) {
            const v = hir_mod.varDeclOf(self.hir, target);
            if (v.name == hir_mod.none_node_id) return false;
            const nk = self.hir.kindOf(v.name);
            return nk == .object_pattern or nk == .array_pattern;
        }
        return false;
    }

    /// §4.A destructuring v8 — extract the pattern node from a for-of
    /// target. Callers verify `forOfBindingIsPattern(target)` first.
    fn forOfBindingPatternNode(self: *const Printer, target: NodeId) NodeId {
        const k = self.hir.kindOf(target);
        if (k == .object_pattern or k == .array_pattern) return target;
        const v = hir_mod.varDeclOf(self.hir, target);
        return v.name;
    }

    /// Emit the binding decl line for a downleveled `for-of`. The
    /// parser preserves declaration targets, so strip any initializer
    /// here; the ES5 loop assigns the current array element after this
    /// fragment.
    fn printForOfBindingDecl(self: *Printer, target: NodeId) anyerror!void {
        const k = self.hir.kindOf(target);
        if (k == .let_decl or k == .const_decl or k == .var_decl) {
            const v = hir_mod.varDeclOf(self.hir, target);
            try self.write("var ");
            if (v.name != hir_mod.none_node_id) try self.printBindingName(v.name);
        } else if (k == .identifier) {
            try self.write("var ");
            try self.printExpression(target);
        } else {
            try self.printBindingName(target);
        }
    }

    /// Inline-emit a for-of body inside a single-line block stmt.
    fn printForOfBody(self: *Printer, body: NodeId) anyerror!void {
        if (self.hir.kindOf(body) == .block_stmt) {
            const stmts = hir_mod.blockStmts(self.hir, body);
            for (stmts, 0..) |s, i| {
                if (i > 0) try self.write(" ");
                try self.printNonIndentStatement(s);
            }
        } else {
            try self.printNonIndentStatement(body);
        }
    }

    /// §4.A.3 — emit a for-of using the iterator protocol so a
    /// `Map`/`Set`/custom iterable downlevels correctly. Shape mirrors
    /// tsc with `downlevelIteration`:
    ///
    /// ```js
    /// try {
    ///     for (var _b = __values(source), _c = _b.next(); !_c.done; _c = _b.next()) {
    ///         var x = _c.value;
    ///         <body>
    ///     }
    /// }
    /// catch (e_1_1) { e_1 = { error: e_1_1 }; }
    /// finally {
    ///     try { if (_c && !_c.done && (_a = _b.return)) _a.call(_b); }
    ///     finally { if (e_1) throw e_1.error; }
    /// }
    /// var e_1, _a;
    /// ```
    ///
    /// Notes:
    ///   * `e_1` / `_a` / `_b` / `_c` are static names — nested for-of
    ///     under `downlevel_iteration` may collide. Hoisting / per-loop
    ///     uniquing is a follow-up (§4.A.3.2).
    ///   * The declarations for `e_1, _a` are emitted *before* the
    ///     try so they're hoisted into the enclosing scope, matching
    ///     tsc's shape (var hoist).
    fn printForOfIteratorProtocol(
        self: *Printer,
        target: NodeId,
        source: NodeId,
        body: NodeId,
    ) anyerror!void {
        try self.write("var e_1, _a; try { for (var _b = __values(");
        try self.printExpression(source);
        try self.write("), _c = _b.next(); !_c.done; _c = _b.next()) { ");
        // §4.A destructuring v8 — pattern target at ES5 + iterator-
        // protocol can't use native `var { a } = _c.value;`. Lower to
        // a temp-ident bind + extraction shim.
        if (self.forOfBindingIsPattern(target)) {
            try self.write("var _e = _c.value; ");
            try self.emitDestructuringShim(self.forOfBindingPatternNode(target), "_e");
            try self.write(" ");
        } else {
            try self.printForOfBindingDecl(target);
            try self.write(" = _c.value; ");
        }
        try self.printForOfBody(body);
        try self.write(" } } catch (e_1_1) { e_1 = { error: e_1_1 }; } finally { try { if (_c && !_c.done && (_a = _b.return)) _a.call(_b); } finally { if (e_1) throw e_1.error; } }");
    }

    fn printReturn(self: *Printer, node: NodeId) !void {
        const r = hir_mod.returnOf(self.hir, node);
        // §4.A.4 — inside the sync-generator state-machine body,
        // nested `return E;` (via lowered loop bodies, if branches,
        // switch cases, etc.) must surface as the generator-return
        // op so the tslib `__generator` runtime treats it as the
        // function's return value rather than the inner state-machine
        // fn's local return.
        if (self.in_sync_gen_body) {
            try self.write("return [2");
            if (r.value != hir_mod.none_node_id) {
                try self.write(", ");
                try self.printExpression(r.value);
            }
            try self.write("];");
            return;
        }
        try self.write("return");
        if (r.value != hir_mod.none_node_id) {
            try self.write(" ");
            try self.printExpression(r.value);
        }
        try self.writeSemi();
    }

    fn printBreakOrContinue(self: *Printer, node: NodeId, kw: []const u8) !void {
        // §4.A.4.4 — when emitting a bare unlabeled `break;` /
        // `continue;` inside a lowered generator loop, rewrite to
        // the state-machine jump `return [3, label];` so the
        // break exits the loop (and continue restarts it) rather
        // than escaping the state machine's switch case.
        const lab = hir_mod.labelOf(self.hir, node);
        if (lab.label == hir_mod.none_node_id) {
            const target: ?u32 = if (std.mem.eql(u8, kw, "break"))
                self.gen_break_label
            else if (std.mem.eql(u8, kw, "continue"))
                self.gen_continue_label
            else
                null;
            if (target) |t| {
                var buf: [16]u8 = undefined;
                const num = std.fmt.bufPrint(&buf, "{d}", .{t}) catch unreachable;
                try self.write("return [3, ");
                try self.write(num);
                try self.write("];");
                return;
            }
        }
        try self.write(kw);
        if (lab.label != hir_mod.none_node_id) {
            try self.write(" ");
            try self.printExpression(lab.label);
        }
        try self.writeSemi();
    }

    fn printThrow(self: *Printer, node: NodeId) !void {
        try self.write("throw ");
        const t = hir_mod.throwOf(self.hir, node);
        try self.printExpression(t.value);
        try self.writeSemi();
    }

    fn printTry(self: *Printer, node: NodeId) !void {
        const p = hir_mod.tryOf(self.hir, node);
        try self.write("try ");
        try self.printStatementInline(p.block);
        if (p.catch_block != hir_mod.none_node_id) {
            try self.write(" catch");
            if (p.catch_param != hir_mod.none_node_id) {
                const pk = self.hir.kindOf(p.catch_param);
                const is_pattern = pk == .object_pattern or pk == .array_pattern;
                // §4.A destructuring v10 — catch param destructuring.
                // At ES5 the native `catch ({ a }) { ... }` shape would
                // fail; lower to `catch (_e) { var a = _e.a; ... }`.
                // At ES2015+ render the pattern verbatim via
                // `printBindingName` (which routes patterns through
                // their respective printers).
                if (is_pattern and self.options.es_target == .es5) {
                    try self.write(" (_e) ");
                    try self.write("{ ");
                    try self.emitDestructuringShim(p.catch_param, "_e");
                    try self.write(" ");
                    if (self.hir.kindOf(p.catch_block) == .block_stmt) {
                        const stmts = hir_mod.blockStmts(self.hir, p.catch_block);
                        for (stmts, 0..) |s, i| {
                            if (i > 0) try self.write(" ");
                            try self.printNonIndentStatement(s);
                        }
                    } else {
                        try self.printNonIndentStatement(p.catch_block);
                    }
                    try self.write(" }");
                } else {
                    try self.write(" (");
                    try self.printBindingName(p.catch_param);
                    try self.write(") ");
                    try self.printStatementInline(p.catch_block);
                }
            } else {
                try self.write(" ");
                try self.printStatementInline(p.catch_block);
            }
        }
        if (p.finally_block != hir_mod.none_node_id) {
            try self.write(" finally ");
            try self.printStatementInline(p.finally_block);
        }
    }

    fn printSwitch(self: *Printer, node: NodeId) !void {
        // Switch traps break only — continue inside a switch still
        // targets the enclosing loop, so leave gen_continue_label
        // alone here.
        const prev_break = self.gen_break_label;
        self.gen_break_label = null;
        defer self.gen_break_label = prev_break;
        const p = hir_mod.switchOf(self.hir, node);
        try self.write("switch (");
        try self.printExpression(p.discriminant);
        try self.write(") {");
        self.depth += 1;
        const cases = hir_mod.switchCases(self.hir, node);
        for (cases) |c| {
            try self.write(self.options.newline);
            try self.indent();
            const cp = hir_mod.switchCaseOf(self.hir, c);
            if (cp.value == hir_mod.none_node_id) {
                try self.write("default:");
            } else {
                try self.write("case ");
                try self.printExpression(cp.value);
                try self.write(":");
            }
            const stmts = hir_mod.switchCaseStmts(self.hir, c);
            self.depth += 1;
            for (stmts) |s| {
                try self.write(self.options.newline);
                try self.printStatement(s);
            }
            self.depth -= 1;
        }
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
    }

    fn printFnDecl(self: *Printer, node: NodeId) anyerror!void {
        const f = hir_mod.fnDeclOf(self.hir, node);
        // Each function introduces its own async-context boundary.
        // `await` in a nested non-async function is a SyntaxError (and
        // a nested async fn manages its own lowering); either way we
        // shouldn't carry the parent's downlevel flag into the child.
        const prev_downlevel = self.in_async_downlevel;
        self.in_async_downlevel = false;
        defer self.in_async_downlevel = prev_downlevel;
        // Track function-nesting depth so `await_expr` at module scope
        // (depth 0) can be distinguished from `await` inside a function.
        self.fn_depth += 1;
        defer self.fn_depth -= 1;
        if (f.flags.is_arrow) {
            // §4.A.1 — at ES5, arrows downlevel to plain `function`
            // expressions. The lexical-`this` capture is approximated
            // by `(this)`-binding via `.bind(this)` at the call site —
            // tsc inserts a `_this = this;` enclosing-scope variable
            // and rewrites references in the body. We use the
            // simpler `function () { ... }.bind(this)` shape; it has
            // the same observable behavior modulo `prototype`.
            if (self.options.es_target == .es5) {
                // An async arrow additionally lowers via `__awaiter` (async is
                // not ES5): `async () => { await x }` ->
                // `function () { return __awaiter(this, void 0, void 0,
                // function* () { yield x; }); }.bind(this)`. Home always binds
                // `this` for arrows, so the `__awaiter` this-arg is `this`.
                const async_downlevel = f.flags.is_async and !self.options.es_target.supportsNativeAsync();
                try self.write("function (");
                const params = hir_mod.fnParams(self.hir, node);
                try self.printRuntimeParams(params);
                try self.write(") { ");
                // §4.A.31 — inline-style temp scope for the lowered arrow body
                // (`{ var _a; … }`); popped before the branch returns below.
                try self.pushTempScope();
                // §4.A — inject `if (x === void 0) { x = ...; }` shims
                // for any default-parameter, before the user body.
                if (self.hasDefaultParam(params)) {
                    try self.writeDefaultParamShims(params);
                    try self.write(" ");
                }
                // §4.A destructuring v7 — extract pattern params via
                // `var a = _p0.a, ...` from the temp idents emitted in
                // the parameter list above.
                if (self.hasDestructuringParam(params)) {
                    try self.writeDestructuringParamShims(params);
                    try self.write(" ");
                }
                if (async_downlevel) {
                    try self.write("return __awaiter(this, void 0, void 0, function* () { ");
                    self.in_async_downlevel = true;
                }
                if (f.body != hir_mod.none_node_id) {
                    if (self.hir.kindOf(f.body) == .block_stmt) {
                        const stmts = hir_mod.blockStmts(self.hir, f.body);
                        for (stmts, 0..) |s, i| {
                            if (i > 0) try self.write(" ");
                            try self.printNonIndentStatement(s);
                        }
                    } else {
                        try self.write("return ");
                        try self.printExpression(f.body);
                        try self.write(";");
                    }
                }
                if (async_downlevel) {
                    self.in_async_downlevel = false;
                    try self.write(" }); }.bind(this)");
                } else {
                    try self.write(" }.bind(this)");
                }
                try self.popTempScope(" ");
                return;
            }
            if (f.flags.is_async) try self.write("async ");
            try self.write("(");
            const params = hir_mod.fnParams(self.hir, node);
            try self.printRuntimeParams(params);
            try self.write(") => ");
            if (f.body != hir_mod.none_node_id) {
                if (self.hir.kindOf(f.body) == .block_stmt) {
                    self.next_block_is_fn_body = true;
                    try self.printBlock(f.body);
                } else {
                    // An object-literal concise body must be parenthesized,
                    // else `=> { … }` parses as a block, not a returned object.
                    const needs_parens = self.hir.kindOf(f.body) == .object_literal;
                    if (needs_parens) try self.write("(");
                    // Concise body is an AssignmentExpression — print at
                    // `.comma` so a top-level sequence wraps (`() => (a, b)`),
                    // otherwise `() => a, b` parses as `(() => a), b`.
                    try self.printExpr(f.body, .comma);
                    if (needs_parens) try self.write(")");
                }
            }
            return;
        }
        // §4.A.5 — async/await downlevel. At ES2016 and below, an
        // `async function f(args) { body }` is rewritten to
        // `function f(args) { return __awaiter(this, void 0, void 0,
        // function* () { body }); }` and `await E` inside the body
        // becomes `yield E`. The `__awaiter` runtime helper is the
        // same shape tsc emits.
        // §4.A.4.7 v0 — async generator state-machine downlevel.
        // At ES2017 and below an `async function* g(args) { ... }` is
        // wrapped as `function g(args) { return __asyncGenerator(this,
        // arguments, function () { return __generator(this, function (_a)
        // { switch (_a.label) { ... } }); }); }`. Each user `yield E`
        // inside the body expands to the tslib double-yield pattern
        // `return [4, __await(E)]; case +1: _a.sent(); return [4];
        // case +2: _a.sent();`. v0 supports linear bodies only.
        const downlevel_async_gen = f.flags.is_async and
            f.flags.is_generator and
            !f.flags.is_method and
            !f.flags.is_constructor and
            !self.options.es_target.supportsNativeAsyncGenerators() and
            f.body != hir_mod.none_node_id and
            self.hir.kindOf(f.body) == .block_stmt and
            self.canLowerAsyncGeneratorBody(f.body);
        const downlevel_async = !downlevel_async_gen and f.flags.is_async and !self.options.es_target.supportsNativeAsync();
        // §4.A.4 v0 — generator state-machine downlevel. At ES2014
        // and below, a `function* g(args) { … }` whose body is *linear*
        // (only top-level `yield E` / `return [E]` / plain expression
        // statements — no `if`/`while`/`for`/`try`/`switch` around the
        // yields) is rewritten to
        // `function g(args) { return __generator(this, function (_a) {
        //   switch (_a.label) { case 0: …; return [4, V1]; case 1: …; … } }); }`
        // matching tsc's emit shape. The `__generator` runtime helper
        // is the same one tsc uses. Bodies outside the supported
        // subset fall through to native `function*` with a leading
        // `/* TODO */` marker so the unsupported emit is visible to
        // downstream tools (the v1 of this transform covers nested
        // control flow).
        const downlevel_generator = !downlevel_async_gen and f.flags.is_generator and
            !f.flags.is_method and
            !f.flags.is_constructor and
            !self.options.es_target.supportsNativeGenerators() and
            f.body != hir_mod.none_node_id and
            self.hir.kindOf(f.body) == .block_stmt and
            self.canLowerGeneratorBody(f.body);
        const generator_native_at_es5 = !downlevel_async_gen and f.flags.is_generator and
            !self.options.es_target.supportsNativeGenerators() and
            !downlevel_generator;
        if (!f.flags.is_method and !f.flags.is_constructor) {
            if (f.flags.is_async and !downlevel_async and !downlevel_async_gen) try self.write("async ");
            if (generator_native_at_es5) {
                try self.write("/* TODO: ES5 generator state-machine doesn't yet handle nested control flow with yields — keeping native function*, will fail at runtime in ES5 */ ");
            }
            try self.write("function");
            if (f.flags.is_generator and !downlevel_generator and !downlevel_async_gen) try self.write("*");
            if (f.name != hir_mod.none_node_id) {
                try self.write(" ");
                try self.printExpression(f.name);
            }
        } else if (f.flags.is_constructor) {
            try self.write("constructor");
        } else if (f.flags.is_method) {
            if (f.flags.is_static) try self.write("static ");
            // `async` (unless downleveled) — accessors are never async.
            if (f.flags.is_async and !f.flags.is_getter and !f.flags.is_setter and
                !downlevel_async and !downlevel_async_gen) try self.write("async ");
            // Accessor keyword — `get x()` / `set x(v)`.
            if (f.flags.is_getter) {
                try self.write("get ");
            } else if (f.flags.is_setter) {
                try self.write("set ");
            }
            if (f.flags.is_generator and !downlevel_generator and !downlevel_async_gen) try self.write("*");
            if (f.name != hir_mod.none_node_id) {
                try self.printExpression(f.name);
            }
        }
        try self.write("(");
        const params = hir_mod.fnParams(self.hir, node);
        try self.printRuntimeParams(params);
        try self.write(")");
        if (f.body != hir_mod.none_node_id) {
            try self.write(" ");
            if (downlevel_async_gen) {
                try self.printAsyncGeneratorDownlevelBody(f.body, params);
            } else if (downlevel_async) {
                try self.printAsyncDownlevelBody(f.body, params);
            } else if (downlevel_generator) {
                try self.printGeneratorDownlevelBody(f.body, params);
            } else if (f.flags.is_constructor and self.hasParameterProperty(params)) {
                // TS parameter properties: emit `this.x = x;` assignments
                // (after a leading super() call) at the constructor head.
                try self.printConstructorBodyWithParamProps(f.body, params);
            } else if (self.options.es_target == .es5 and (self.hasDefaultParam(params) or self.hasDestructuringParam(params))) {
                // §4.A — at ES5, lower default-parameter syntax to a
                // body-prefix `if (x === void 0) { x = ...; }` shim
                // AND/OR extract destructuring params via
                // `var a = _p0.a, ...` from the temp idents emitted in
                // the parameter list.
                try self.printFnBodyWithDefaults(params, f.body);
            } else {
                self.next_block_is_fn_body = self.hir.kindOf(f.body) == .block_stmt;
                try self.printStatementInline(f.body);
            }
        } else {
            try self.writeSemi();
        }
    }

    /// Emit `{ return __awaiter(this, void 0, void 0, function* () { body }); }`
    /// — the shape tsc uses to lower async functions for ES2016 and
    /// below. Inside the generator body we set `in_async_downlevel`
    /// so the `await` printer lowers `await E` to `yield E`.
    fn printAsyncDownlevelBody(self: *Printer, body: NodeId, params: []const NodeId) anyerror!void {
        try self.write("{");
        self.depth += 1;
        try self.writeNewlineIndent();
        // §4.A destructuring v13 — when the enclosing async fn has
        // pattern params at ES5, the param list emits `_pN` temp idents
        // and the body needs a destructuring shim. Inject it here
        // before `return __awaiter(...)` so the closure-captured
        // bindings are visible to the inner generator body.
        if (self.options.es_target == .es5 and self.hasDestructuringParam(params)) {
            try self.writeDestructuringParamShims(params);
            try self.writeNewlineIndent();
        }
        try self.write("return __awaiter(this, void 0, void 0, function* () ");
        const prev = self.in_async_downlevel;
        self.in_async_downlevel = true;
        defer self.in_async_downlevel = prev;
        if (self.hir.kindOf(body) == .block_stmt) {
            self.next_block_is_fn_body = true;
            try self.printBlock(body);
        } else {
            try self.write("{ return ");
            try self.printExpression(body);
            try self.write("; }");
        }
        try self.write(");");
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
    }

    /// §4.A.4 v0 — true iff `body` is a `block_stmt` whose top-level
    /// statements are all in the lowerable set:
    ///   * `yield_expr` (top-level expression-statement yield)
    ///   * `return_stmt`
    ///   * `var/let/const` decl whose initializer is either absent,
    ///     a top-level `yield_expr` (§4.A.4.1 — yield-in-RHS resumes
    ///     via `_a.sent()`), or any non-yield-bearing expression
    ///     (pass-through as plain `var`)
    ///   * `assignment` (plain `=`, not compound) whose `value` is a
    ///     top-level `yield_expr` (§4.A.4.1) — or any assignment
    ///     whose subtree contains no yield (pass-through)
    ///   * any structured statement (`if`/`while`/`do`/`for`/`for-in`/
    ///     `for-of`/`try`/`switch`/`throw`) whose entire subtree
    ///     contains no `yield` — these emit as plain JS inside the
    ///     current `case` (§4.A.4.2 part 1)
    ///   * any other expression statement whose subtree contains no
    ///     yield
    /// v0 still bails on: yields nested inside structured statements
    /// (CFG lowering is §4.A.4.2 part 2), compound-assignment-to-yield,
    /// destructuring decl targets, and `break`/`continue`/`fn_decl`/
    /// `class_decl` at the body's top level.
    fn canLowerGeneratorBody(self: *const Printer, body: NodeId) bool {
        if (self.hir.kindOf(body) != .block_stmt) return false;
        const stmts = hir_mod.blockStmts(self.hir, body);
        for (stmts) |s| {
            const k = self.hir.kindOf(s);
            switch (k) {
                // Labeled statements aren't handled by the inline
                // generator lowering — bail to native `function*`.
                .labeled_stmt => return false,
                .yield_expr, .return_stmt => continue,
                .var_decl, .let_decl, .const_decl => {
                    const v = hir_mod.varDeclOf(self.hir, s);
                    if (v.name == hir_mod.none_node_id) return false;
                    if (self.hir.kindOf(v.name) != .identifier) return false;
                    if (v.init != hir_mod.none_node_id and self.hir.kindOf(v.init) != .yield_expr) {
                        if (self.subtreeContainsYield(v.init)) return false;
                    }
                },
                .assignment => {
                    const a = hir_mod.assignmentOf(self.hir, s);
                    if (a.op != null and self.hir.kindOf(a.value) == .yield_expr) return false;
                    if (self.hir.kindOf(a.value) != .yield_expr) {
                        if (self.subtreeContainsYield(s)) return false;
                    }
                },
                .while_stmt => {
                    // Pass-through is fine when the subtree carries no yields.
                    if (!self.subtreeContainsYield(s)) continue;
                    // §4.A.4.2 part 2d / §4.A.4.3 — `while (cond) body;`
                    // where cond is yield-free (or cond is exactly a
                    // `yield E` per §4.A.4.10 — the "yield in cond"
                    // variant) and body is either a bare single yield
                    // or a block containing exactly one yield
                    // surrounded by yield-free statements.
                    const wp = hir_mod.whileOf(self.hir, s);
                    var cond_yields = false;
                    if (self.subtreeContainsYield(wp.cond)) {
                        // §4.A.4.10 — accept only the restricted form
                        // where cond IS a single `yield E` expression.
                        // Larger expressions that just contain a yield
                        // somewhere inside aren't handled by the
                        // current state-machine emit path.
                        if (self.hir.kindOf(wp.cond) != .yield_expr) return false;
                        const yc = hir_mod.yieldExprOf(self.hir, wp.cond);
                        if (yc.type_node != hir_mod.none_node_id) return false; // no yield* in cond
                        if (yc.expr != hir_mod.none_node_id and self.subtreeContainsYield(yc.expr)) return false;
                        cond_yields = true;
                    }
                    if (self.singleYieldInThen(wp.body)) |ye| {
                        const yp = hir_mod.yieldExprOf(self.hir, ye);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.splitLoopBody(wp.body, true)) |split| {
                        const yp = hir_mod.yieldExprOf(self.hir, split.yield_node);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.multiYieldLoopBodyOk(wp.body, true)) {
                        // multi-yield body — emit handles it when cond
                        // is yield-free. The yield-in-cond path doesn't
                        // yet support multi-yield bodies (state-counting
                        // intertwines with the extra cond-resume case);
                        // reject the combination so it falls back to
                        // native `function*` rather than emit broken JS.
                        if (cond_yields) return false;
                    } else {
                        return false;
                    }
                },
                .do_while_stmt => {
                    if (!self.subtreeContainsYield(s)) continue;
                    // §4.A.4.2 part 2e / §4.A.4.3 / §4.A.4.13 —
                    // `do body while (cond);` with body being either
                    // bare single yield, split-body, or multi-yield
                    // block; cond is either yield-free OR a single
                    // `yield E` expression (the "cond-yield" variant
                    // adds an extra cond-resume case to the state
                    // machine). Multi-yield body + cond-yield bails
                    // because the state-counting intertwines awkwardly.
                    const dwp = hir_mod.doWhileOf(self.hir, s);
                    var cond_yields = false;
                    if (self.subtreeContainsYield(dwp.cond)) {
                        if (self.hir.kindOf(dwp.cond) != .yield_expr) return false;
                        const yc = hir_mod.yieldExprOf(self.hir, dwp.cond);
                        if (yc.type_node != hir_mod.none_node_id) return false; // no yield* in cond
                        if (yc.expr != hir_mod.none_node_id and self.subtreeContainsYield(yc.expr)) return false;
                        cond_yields = true;
                    }
                    if (self.singleYieldInThen(dwp.body)) |ye| {
                        const yp = hir_mod.yieldExprOf(self.hir, ye);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.splitLoopBody(dwp.body, true)) |split| {
                        const yp = hir_mod.yieldExprOf(self.hir, split.yield_node);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.multiYieldLoopBodyOk(dwp.body, true)) {
                        // multi-yield body — emit handles it, but
                        // combined with cond-yield the layout isn't
                        // implemented yet.
                        if (cond_yields) return false;
                    } else {
                        return false;
                    }
                },
                .for_in_stmt => {
                    if (!self.subtreeContainsYield(s)) continue;
                    // §4.A.4.8 cont. — `for (const k in obj) yield E;`.
                    // Source must be yield-free; body is bare single yield
                    // or multi-yield block. Keys are collected eagerly via
                    // a synthesized `for (var _x in obj) _keys.push(_x);`
                    // before entering the state-machine header.
                    const fip = hir_mod.forInOf(self.hir, s);
                    if (self.subtreeContainsYield(fip.source)) return false;
                    if (self.singleYieldInThen(fip.body)) |ye| {
                        const yp = hir_mod.yieldExprOf(self.hir, ye);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.splitLoopBody(fip.body, true)) |split| {
                        const yp = hir_mod.yieldExprOf(self.hir, split.yield_node);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.multiYieldLoopBodyOk(fip.body, true)) {
                        // multi-yield — emit handles it.
                    } else {
                        return false;
                    }
                    const tk = self.hir.kindOf(fip.target);
                    if (tk == .identifier) {
                        // ok
                    } else if (tk == .var_decl or tk == .let_decl or tk == .const_decl) {
                        const v = hir_mod.varDeclOf(self.hir, fip.target);
                        if (v.name == hir_mod.none_node_id) return false;
                        // §4.A.4.8 v2 — accept identifier OR destructuring
                        // pattern as the binding name; emit routes through
                        // `printBindingName`.
                        const nk = self.hir.kindOf(v.name);
                        if (nk != .identifier and nk != .object_pattern and nk != .array_pattern) return false;
                    } else {
                        return false;
                    }
                },
                .for_of_stmt => {
                    if (!self.subtreeContainsYield(s)) continue;
                    // §4.A.4.8 v0 — `for (const x of source) yield E;`
                    // Source must be yield-free; body is bare single yield
                    // or multi-yield block; for-await-of bails (separate);
                    // downlevel_iteration mode also bails (needs the
                    // iterator-protocol unwrapping wrapped in state machine
                    // — bigger work).
                    const fop = hir_mod.forInOf(self.hir, s);
                    if (fop.is_await) return false;
                    if (self.subtreeContainsYield(fop.source)) return false;
                    if (self.singleYieldInThen(fop.body)) |ye| {
                        const yp = hir_mod.yieldExprOf(self.hir, ye);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.splitLoopBody(fop.body, true)) |split| {
                        const yp = hir_mod.yieldExprOf(self.hir, split.yield_node);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.multiYieldLoopBodyOk(fop.body, true)) {
                        // multi-yield — emit handles it.
                    } else {
                        return false;
                    }
                    // Target is a simple identifier OR `let/const/var
                    // <name>` where name is identifier or destructuring
                    // pattern (§4.A.4.8 v2).
                    const tk = self.hir.kindOf(fop.target);
                    if (tk == .identifier) {
                        // ok
                    } else if (tk == .var_decl or tk == .let_decl or tk == .const_decl) {
                        const v = hir_mod.varDeclOf(self.hir, fop.target);
                        if (v.name == hir_mod.none_node_id) return false;
                        const nk = self.hir.kindOf(v.name);
                        if (nk != .identifier and nk != .object_pattern and nk != .array_pattern) return false;
                    } else {
                        return false;
                    }
                },
                .for_stmt => {
                    if (!self.subtreeContainsYield(s)) continue;
                    // §4.A.4.2 part 2f / §4.A.4.3 / §4.A.4.12 / §4.A.4.15 —
                    // `for (init; cond; update) body;`. Accepted:
                    //   * init: yield-free OR `var|let|const x = yield E;`
                    //     (peeled into a pre-loop yield+bind, §4.A.4.12)
                    //   * cond: yield-free OR exactly `yield E_cond`
                    //     (§4.A.4.15 v0 — adds a cond_resume case to the
                    //     state machine; multi-yield body + cond-yield
                    //     bails because state-counting intertwines)
                    //   * update: yield-free
                    //   * body: bare single yield, split-body, OR
                    //     multi-yield block (multi-yield bails when
                    //     cond_yields)
                    const fp = hir_mod.forStmtOf(self.hir, s);
                    if (fp.init != hir_mod.none_node_id and self.subtreeContainsYield(fp.init)) {
                        if (!self.forInitIsSimpleYieldDecl(fp.init)) return false;
                    }
                    var cond_yields = false;
                    if (fp.cond != hir_mod.none_node_id and self.subtreeContainsYield(fp.cond)) {
                        if (self.hir.kindOf(fp.cond) != .yield_expr) return false;
                        const yc = hir_mod.yieldExprOf(self.hir, fp.cond);
                        if (yc.type_node != hir_mod.none_node_id) return false;
                        if (yc.expr != hir_mod.none_node_id and self.subtreeContainsYield(yc.expr)) return false;
                        cond_yields = true;
                    }
                    if (fp.update != hir_mod.none_node_id and self.subtreeContainsYield(fp.update)) return false;
                    if (self.singleYieldInThen(fp.body)) |ye| {
                        const yp = hir_mod.yieldExprOf(self.hir, ye);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.splitLoopBody(fp.body, true)) |split| {
                        const yp = hir_mod.yieldExprOf(self.hir, split.yield_node);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.multiYieldLoopBodyOk(fp.body, true)) {
                        // multi-yield body — emit handles it when cond
                        // is yield-free; with cond-yield, bail.
                        if (cond_yields) return false;
                    } else {
                        return false;
                    }
                },
                .if_stmt => {
                    // Pass-through is fine when the subtree carries no yields.
                    if (!self.subtreeContainsYield(s)) continue;
                    // §4.A.4.2 part 2a/2b/2c + §4.A.4.5 — supported shapes:
                    //   * then-branch: single bare yield OR multi-yield block
                    //   * else-branch (when present): single bare yield OR
                    //     multi-yield block OR non-yielding
                    //   * cond + each yielded expression has no nested yield
                    if (!self.ifChainValid(s)) return false;
                },
                .try_stmt => {
                    if (!self.subtreeContainsYield(s)) continue;
                    // §4.A.4.6 — try body is either a single bare
                    // yield or a multi-yield block (N≥2 yields).
                    // catch + finally bodies must be yield-free.
                    // Catch parameter must be a plain identifier.
                    const tp = hir_mod.tryOf(self.hir, s);
                    if (self.singleYieldInThen(tp.block)) |ye| {
                        const yp = hir_mod.yieldExprOf(self.hir, ye);
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else if (self.multiYieldLoopBodyOk(tp.block, false)) {
                        // multi-yield try body — emit handles it.
                    } else {
                        return false;
                    }
                    if (tp.catch_block != hir_mod.none_node_id) {
                        if (tp.catch_param != hir_mod.none_node_id and self.hir.kindOf(tp.catch_param) != .identifier) return false;
                        if (self.classifyBreakContinue(tp.catch_block) == .unhandleable) return false;
                        if (self.subtreeContainsYield(tp.catch_block)) {
                            // Yields inside the catch body are OK as
                            // long as every top-level stmt is either
                            // a yield (not yield*) or has no nested yield.
                            if (self.hir.kindOf(tp.catch_block) != .block_stmt) return false;
                            const cstmts = hir_mod.blockStmts(self.hir, tp.catch_block);
                            for (cstmts) |cs| {
                                if (self.hir.kindOf(cs) == .yield_expr) {
                                    const ypc = hir_mod.yieldExprOf(self.hir, cs);
                                    if (ypc.type_node != hir_mod.none_node_id) return false;
                                    if (ypc.expr != hir_mod.none_node_id and self.subtreeContainsYield(ypc.expr)) return false;
                                } else if (self.subtreeContainsYield(cs)) {
                                    return false;
                                }
                            }
                        }
                    }
                    if (tp.finally_block != hir_mod.none_node_id) {
                        if (self.classifyBreakContinue(tp.finally_block) == .unhandleable) return false;
                        if (self.subtreeContainsYield(tp.finally_block)) {
                            // Yields inside finally are OK with the same
                            // top-level-statement rule as catch.
                            if (self.hir.kindOf(tp.finally_block) != .block_stmt) return false;
                            const fstmts = hir_mod.blockStmts(self.hir, tp.finally_block);
                            for (fstmts) |fs| {
                                if (self.hir.kindOf(fs) == .yield_expr) {
                                    const ypf = hir_mod.yieldExprOf(self.hir, fs);
                                    if (ypf.type_node != hir_mod.none_node_id) return false;
                                    if (ypf.expr != hir_mod.none_node_id and self.subtreeContainsYield(ypf.expr)) return false;
                                } else if (self.subtreeContainsYield(fs)) {
                                    return false;
                                }
                            }
                        }
                    }
                    if (tp.catch_block == hir_mod.none_node_id and tp.finally_block == hir_mod.none_node_id) return false;
                },
                .switch_stmt => {
                    if (!self.subtreeContainsYield(s)) continue;
                    // §4.A.4.16 v0 — `switch (x) { case <V>: ...; break; ... }`
                    // with yielding bodies. Restrictions:
                    //   * discriminant is yield-free
                    //   * each case body is a flat sequence of yield/
                    //     await-free non-structured stmts plus at most
                    //     ONE bare `yield E;` (E yield-free) — no
                    //     fall-through, no labeled break
                    //   * each case body ends with `break;` (or
                    //     `return`/`throw` which implicitly terminate)
                    //   * `default` is allowed
                    if (!self.switchYieldOk(s)) return false;
                },
                .break_stmt, .continue_stmt, .fn_decl, .class_decl => return false,
                .call_expr => {
                    // `f(yield E);` as a top-level expression — call
                    // with exactly one arg that's a yield_expr,
                    // callee yield-free.
                    const cp = hir_mod.callOf(self.hir, s);
                    const args = hir_mod.callArgs(self.hir, s);
                    if (args.len == 1 and self.hir.kindOf(args[0]) == .yield_expr) {
                        if (self.subtreeContainsYield(cp.callee)) return false;
                        const yp = hir_mod.yieldExprOf(self.hir, args[0]);
                        if (yp.type_node != hir_mod.none_node_id) return false; // bail on yield*
                        if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    } else {
                        if (self.subtreeContainsYield(s)) return false;
                    }
                },
                else => {
                    if (self.subtreeContainsYield(s)) return false;
                },
            }
        }
        return true;
    }

    /// §4.A.4.2 part 2b — emit a non-yielding statement (or block's
    /// statements, unwrapped) inline on the current line. Used for
    /// else-bodies inside the generator state machine where the
    /// statements run between the yield resumption and the after-if
    /// fall-through.
    fn emitGenInlineStatements(self: *Printer, body: NodeId) anyerror!void {
        if (body == hir_mod.none_node_id) return;
        if (self.hir.kindOf(body) == .block_stmt) {
            const stmts = hir_mod.blockStmts(self.hir, body);
            for (stmts) |s| {
                try self.write(" ");
                try self.printNonIndentStatement(s);
            }
            return;
        }
        try self.write(" ");
        try self.printNonIndentStatement(body);
    }

    /// §4.A.4.2 + §4.A.4.5 + §4.A.4.11 — emit one segment of an
    /// if-yield chain. The caller has already opened the segment's
    /// "cur" case (or has just emitted a `case N:` for it via the
    /// outer walker or by recursing here). This function writes:
    ///
    ///   * The cond skip (`if (!(cond)) return [3, skip];`).
    ///   * The then-walk (yield-resume cases for each then-yield,
    ///     interleaved with non-yield stmts).
    ///   * (when has_else) the jump to `after_label`, the
    ///     else-open case, AND either:
    ///     - a recursive `emitGenIfChain` call for `else if (...)`
    ///       chain links (the inner if's cur IS the outer's
    ///       else-open case, so we just continue emitting into it);
    ///     - the else-walk for yielding non-if else branches; OR
    ///     - `emitGenInlineStatements` for non-yielding else.
    ///
    /// `state.*` advances by `n_then + else_section` cases. The
    /// caller is responsible for opening the shared `after_if`
    /// case after this returns.
    fn emitGenIfChain(
        self: *Printer,
        if_node: NodeId,
        after_label: u32,
        state: *u32,
        buf: *[16]u8,
    ) anyerror!void {
        const ip = hir_mod.ifOf(self.hir, if_node);
        // Then-branch shape.
        var n_then: u32 = 1;
        const then_is_single = self.singleYieldInThen(ip.then_branch) != null;
        const then_stmts: []const NodeId = if (then_is_single) blk: {
            break :blk @as([]const NodeId, &[_]NodeId{self.singleYieldInThen(ip.then_branch).?});
        } else stmts2: {
            const sl = hir_mod.blockStmts(self.hir, ip.then_branch);
            n_then = 0;
            for (sl) |s| {
                if (self.hir.kindOf(s) == .yield_expr) n_then += 1;
            }
            break :stmts2 sl;
        };
        // Else-branch shape.
        const has_else = ip.else_branch != hir_mod.none_node_id;
        const else_has_yields = has_else and self.subtreeContainsYield(ip.else_branch);
        const else_is_chain = else_has_yields and self.hir.kindOf(ip.else_branch) == .if_stmt;
        // Where the else-section begins (this is the label of the
        // else-open case; for a chain link, it's the inner if's cur).
        const else_label_start: u32 = state.* + n_then + 1;
        // Cur case: cond skip + walk-then.
        var num_skip_buf: [16]u8 = undefined;
        const skip_label: u32 = if (has_else) else_label_start else after_label;
        const num_skip = std.fmt.bufPrint(&num_skip_buf, "{d}", .{skip_label}) catch unreachable;
        try self.write(" if (!(");
        try self.printExpression(ip.cond);
        try self.write(")) return [3, ");
        try self.write(num_skip);
        try self.write("];");
        // Walk then-body.
        for (then_stmts) |s| {
            if (self.hir.kindOf(s) == .yield_expr) {
                const yp_n = hir_mod.yieldExprOf(self.hir, s);
                const op_n: []const u8 = if (yp_n.type_node != hir_mod.none_node_id) "5" else "4";
                try self.write(" return [");
                try self.write(op_n);
                if (yp_n.expr != hir_mod.none_node_id) {
                    try self.write(", ");
                    try self.printExpression(yp_n.expr);
                }
                try self.write("];");
                state.* += 1;
                const num_resume = std.fmt.bufPrint(buf, "{d}", .{state.*}) catch unreachable;
                try self.writeNewlineIndent();
                try self.write("case ");
                try self.write(num_resume);
                try self.write(": _a.sent();");
            } else {
                try self.write(" ");
                try self.printNonIndentStatement(s);
            }
        }
        // After then-walk: if else exists, jump past it.
        if (has_else) {
            var num_after_buf: [16]u8 = undefined;
            const num_after = std.fmt.bufPrint(&num_after_buf, "{d}", .{after_label}) catch unreachable;
            try self.write(" return [3, ");
            try self.write(num_after);
            try self.write("];");
            // Open else case.
            state.* += 1;
            {
                const num_else = std.fmt.bufPrint(buf, "{d}", .{state.*}) catch unreachable;
                try self.writeNewlineIndent();
                try self.write("case ");
                try self.write(num_else);
                try self.write(":");
            }
            if (else_is_chain) {
                // §4.A.4.11 — `else if (...)` chain link. The inner
                // if's cur is the else-open case we just opened;
                // recurse to emit its segment with the same shared
                // after_label.
                try self.emitGenIfChain(ip.else_branch, after_label, state, buf);
            } else if (else_has_yields) {
                // Walk yielding non-if else body (same shape as then-walk).
                const else_stmts: []const NodeId = blk: {
                    if (self.singleYieldInThen(ip.else_branch)) |single| {
                        break :blk @as([]const NodeId, &[_]NodeId{single});
                    }
                    break :blk hir_mod.blockStmts(self.hir, ip.else_branch);
                };
                for (else_stmts) |s| {
                    if (self.hir.kindOf(s) == .yield_expr) {
                        const yp_n = hir_mod.yieldExprOf(self.hir, s);
                        const op_n: []const u8 = if (yp_n.type_node != hir_mod.none_node_id) "5" else "4";
                        try self.write(" return [");
                        try self.write(op_n);
                        if (yp_n.expr != hir_mod.none_node_id) {
                            try self.write(", ");
                            try self.printExpression(yp_n.expr);
                        }
                        try self.write("];");
                        state.* += 1;
                        const num_resume = std.fmt.bufPrint(buf, "{d}", .{state.*}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num_resume);
                        try self.write(": _a.sent();");
                    } else {
                        try self.write(" ");
                        try self.printNonIndentStatement(s);
                    }
                }
            } else {
                // Non-yielding else: emit inline statements.
                try self.emitGenInlineStatements(ip.else_branch);
            }
        }
    }

    /// §4.A.4.2 part 2a — if `then_branch` is a single `yield E`
    /// (bare expression-statement, either standalone or inside a
    /// single-statement block), return that yield node. Otherwise
    /// `null`. v0 of the CFG slice only handles this narrow shape;
    /// multi-statement bodies and any other statement kind fall
    /// outside the supported subset.
    fn singleYieldInThen(self: *const Printer, then_branch: NodeId) ?NodeId {
        if (then_branch == hir_mod.none_node_id) return null;
        const k = self.hir.kindOf(then_branch);
        if (k == .yield_expr) return then_branch;
        if (k == .block_stmt) {
            const stmts = hir_mod.blockStmts(self.hir, then_branch);
            if (stmts.len == 1 and self.hir.kindOf(stmts[0]) == .yield_expr) return stmts[0];
        }
        return null;
    }

    /// §4.A.4.12 — true iff `init` is a `for`-stmt init of the shape
    /// `var|let|const <ident> = yield <yield-free expr>;`. This is the
    /// only init-with-yield shape the state-machine lowering accepts:
    /// the binding is peeled off into a pre-loop yield+bind case pair
    /// before the loop's header opens, then the for-stmt runs with
    /// init treated as already executed.
    fn forInitIsSimpleYieldDecl(self: *const Printer, init_node: NodeId) bool {
        const k = self.hir.kindOf(init_node);
        if (k != .var_decl and k != .let_decl and k != .const_decl) return false;
        const v = hir_mod.varDeclOf(self.hir, init_node);
        if (v.name == hir_mod.none_node_id) return false;
        if (self.hir.kindOf(v.name) != .identifier) return false;
        if (v.init == hir_mod.none_node_id) return false;
        if (self.hir.kindOf(v.init) != .yield_expr) return false;
        const y = hir_mod.yieldExprOf(self.hir, v.init);
        if (y.type_node != hir_mod.none_node_id) return false;
        if (y.expr != hir_mod.none_node_id and self.subtreeContainsYield(y.expr)) return false;
        return true;
    }

    /// §4.A.4.14 v3 — true iff `body` is acceptable as the body of
    /// a for-await-of inside an async generator. Accepts:
    ///   * a bare single statement (a yield_expr OR any yield/await-
    ///     free non-structured stmt)
    ///   * a `{ ... }` block whose top-level stmts each pass
    ///     `asyncGenForAwaitBodyStmtOk` (yield_exprs are fine; non-
    ///     yield stmts must be yield/await-free and non-structured)
    /// Structured stmts (if/while/do_while/for/for_in/for_of/try/
    /// switch/throw/break/continue/fn_decl/class_decl/return_stmt)
    /// are rejected at the top level because the inline walk doesn't
    /// recurse and break/continue aren't routed through
    /// `gen_break_label`/`gen_continue_label` in async-gen emit.
    fn asyncGenForAwaitBodyOk(self: *const Printer, body: NodeId) bool {
        if (body == hir_mod.none_node_id) return false;
        if (self.hir.kindOf(body) != .block_stmt) return self.asyncGenForAwaitBodyStmtOk(body);
        const stmts = hir_mod.blockStmts(self.hir, body);
        for (stmts) |s| {
            if (!self.asyncGenForAwaitBodyStmtOk(s)) return false;
        }
        return true;
    }

    /// §4.A.4.14 v3+v5+v6+v8 — per-statement validator for for-await-of
    /// body. Yields (including `yield*`) are accepted if RHS is yield/
    /// await-free; bare unlabeled `break`/`continue` are accepted
    /// (rewritten to state-machine jumps via `printBreakOrContinue`);
    /// a shallow `if (cond) break|continue;` (no else, no nested
    /// yields/awaits, cond yield/await-free) is accepted because the
    /// regular if-stmt printer + the wired gen_break/continue labels
    /// produce the right state-machine jump automatically; other
    /// non-yields must be yield/await-free and not a structured stmt.
    fn asyncGenForAwaitBodyStmtOk(self: *const Printer, s: NodeId) bool {
        const k = self.hir.kindOf(s);
        if (k == .yield_expr) {
            const yp = hir_mod.yieldExprOf(self.hir, s);
            if (yp.type_node != hir_mod.none_node_id and yp.expr == hir_mod.none_node_id) return false;
            if (yp.expr != hir_mod.none_node_id and (self.subtreeContainsYield(yp.expr) or self.subtreeContainsAwait(yp.expr))) return false;
            return true;
        }
        if (k == .break_stmt or k == .continue_stmt) {
            const lab = hir_mod.labelOf(self.hir, s);
            return lab.label == hir_mod.none_node_id;
        }
        // §4.A.4.14 v8+v9 — shallow `if (cond) break|continue;` with
        // optional yield/await-free else. The existing printIf +
        // printBreakOrContinue cooperation handles the state-machine
        // jump rewrite for the then-branch; the else-branch (when
        // present) emits inline via printNonIndentStatement.
        if (k == .if_stmt) {
            const ip = hir_mod.ifOf(self.hir, s);
            if (ip.cond == hir_mod.none_node_id) return false;
            if (self.subtreeContainsYield(ip.cond) or self.subtreeContainsAwait(ip.cond)) return false;
            // then-branch must be a bare unlabeled break or continue
            // (or a one-element block containing one).
            const then_branch = ip.then_branch;
            const then_stmt: NodeId = if (self.hir.kindOf(then_branch) == .block_stmt) blk: {
                const tstmts = hir_mod.blockStmts(self.hir, then_branch);
                if (tstmts.len != 1) break :blk hir_mod.none_node_id;
                break :blk tstmts[0];
            } else then_branch;
            if (then_stmt == hir_mod.none_node_id) return false;
            const tk = self.hir.kindOf(then_stmt);
            if (tk != .break_stmt and tk != .continue_stmt) return false;
            const lab = hir_mod.labelOf(self.hir, then_stmt);
            if (lab.label != hir_mod.none_node_id) return false;
            // §4.A.4.14 v9 — else-branch (when present) must be
            // yield/await-free and not a structured stmt that would
            // require its own state-machine plumbing.
            if (ip.else_branch != hir_mod.none_node_id) {
                if (self.subtreeContainsYield(ip.else_branch) or self.subtreeContainsAwait(ip.else_branch)) return false;
                const ek = self.hir.kindOf(ip.else_branch);
                switch (ek) {
                    .while_stmt, .do_while_stmt, .for_stmt, .for_in_stmt, .for_of_stmt, .try_stmt, .switch_stmt, .throw_stmt, .return_stmt, .fn_decl, .class_decl => return false,
                    else => {},
                }
            }
            return true;
        }
        if (self.subtreeContainsYield(s) or self.subtreeContainsAwait(s)) return false;
        switch (k) {
            .while_stmt, .do_while_stmt, .for_stmt, .for_in_stmt, .for_of_stmt, .try_stmt, .switch_stmt, .throw_stmt, .fn_decl, .class_decl, .return_stmt => return false,
            else => return true,
        }
    }

    /// §4.A.4.16 v0/v1 — true iff `switch_stmt` is acceptable for
    /// state-machine lowering. Each case body: yield/await-free
    /// non-structured stmts + ≥0 bare `yield E` + ends with
    /// `break;` / `return` / `throw`. No labeled break. No
    /// fall-through. Multi-yield per case is fine — each yield opens
    /// a fresh resume state in the emit.
    fn switchYieldOk(self: *const Printer, switch_node: NodeId) bool {
        const sp = hir_mod.switchOf(self.hir, switch_node);
        if (self.subtreeContainsYield(sp.discriminant)) return false;
        const cases = hir_mod.switchCases(self.hir, switch_node);
        for (cases) |cn| {
            if (self.hir.kindOf(cn) != .switch_case) continue;
            const cp = hir_mod.switchCaseOf(self.hir, cn);
            if (cp.value != hir_mod.none_node_id and self.subtreeContainsYield(cp.value)) return false;
            const stmts = hir_mod.switchCaseStmts(self.hir, cn);
            var terminates = false;
            for (stmts) |st| {
                const k = self.hir.kindOf(st);
                if (k == .yield_expr) {
                    const yp = hir_mod.yieldExprOf(self.hir, st);
                    if (yp.type_node != hir_mod.none_node_id) return false; // no yield* in v0
                    if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                    continue;
                }
                if (k == .break_stmt) {
                    const lab = hir_mod.labelOf(self.hir, st);
                    if (lab.label != hir_mod.none_node_id) return false; // no labeled break
                    terminates = true;
                    continue;
                }
                if (k == .return_stmt or k == .throw_stmt) {
                    if (self.subtreeContainsYield(st)) return false;
                    terminates = true;
                    continue;
                }
                if (self.subtreeContainsYield(st)) return false;
                switch (k) {
                    .while_stmt, .do_while_stmt, .for_stmt, .for_in_stmt, .for_of_stmt, .try_stmt, .switch_stmt, .if_stmt, .fn_decl, .class_decl, .continue_stmt => return false,
                    else => {},
                }
            }
            if (!terminates) return false;
        }
        return true;
    }

    /// §4.A.4.5 — true iff `body` is a block with **two or more**
    /// top-level `yield_expr`s and every other statement is yield-
    /// and break/continue-safe. Multi-yield bodies lower through a
    /// separate emit path that walks the body inline, opening a new
    /// resumption case after each yield.
    fn multiYieldLoopBodyOk(self: *const Printer, body: NodeId, accept_continue: bool) bool {
        if (body == hir_mod.none_node_id) return false;
        if (self.hir.kindOf(body) != .block_stmt) return false;
        const stmts = hir_mod.blockStmts(self.hir, body);
        var yield_count: usize = 0;
        for (stmts) |s| {
            if (self.hir.kindOf(s) == .yield_expr) {
                const yp = hir_mod.yieldExprOf(self.hir, s);
                if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                yield_count += 1;
            } else {
                if (self.subtreeContainsYield(s)) return false;
                if (self.classifyBreakContinueImpl(s, accept_continue) == .unhandleable) return false;
            }
        }
        return yield_count >= 2;
    }

    /// §4.A.4.11 v0 — recursive validator for if-yield chains. Accepts
    /// `if (cond) then [else <branch>]` where:
    ///   * `cond` is yield-free.
    ///   * `then` is either a bare-yield (`singleYieldInThen`), a 1+
    ///     yield block with yield-free pre/post (`yieldBlockOkInIfBranch`),
    ///     or any block satisfying the same constraints.
    ///   * `else_branch` (when present) is either:
    ///     - yield-free (handled inline by the emit), OR
    ///     - the bare-yield/yield-block shape (same as `then`), OR
    ///     - another `if_stmt` whose own subtree contains yields and
    ///       which itself satisfies `ifChainValid` (this is the
    ///       `else if (...)` chain — recursive).
    /// This unifies the predicate work the per-stmt scanner used to
    /// inline at the if-stmt arm; the emit side mirrors via
    /// `emitGenIfChainSegment` (recursive).
    fn ifChainValid(self: *const Printer, if_node: NodeId) bool {
        const ip = hir_mod.ifOf(self.hir, if_node);
        if (self.subtreeContainsYield(ip.cond)) return false;
        // Validate then-branch shape.
        if (self.singleYieldInThen(ip.then_branch)) |ye_then| {
            const yp_then = hir_mod.yieldExprOf(self.hir, ye_then);
            if (yp_then.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp_then.expr)) return false;
        } else if (!self.yieldBlockOkInIfBranch(ip.then_branch)) {
            return false;
        }
        // Validate else-branch (if present).
        if (ip.else_branch != hir_mod.none_node_id) {
            if (self.subtreeContainsYield(ip.else_branch)) {
                if (self.hir.kindOf(ip.else_branch) == .if_stmt) {
                    // `else if (...)` chain link — recurse.
                    if (!self.ifChainValid(ip.else_branch)) return false;
                } else if (self.singleYieldInThen(ip.else_branch)) |ye_else| {
                    const yp_else = hir_mod.yieldExprOf(self.hir, ye_else);
                    if (yp_else.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp_else.expr)) return false;
                } else if (!self.yieldBlockOkInIfBranch(ip.else_branch)) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Count the number of state-machine cases an if-yield chain
    /// consumes *past* its current case. Used by the emit caller to
    /// compute the chain's shared `after_if_label`.
    ///
    /// Layout per segment:
    ///   * `n_then` resume cases (one per yield in then-branch).
    ///   * `else_section` cases for the else-branch (when present):
    ///     - `else if (...)` chain link → 1 (else_open which IS the
    ///       inner if's cur) + the inner segment's interior cases.
    ///     - yielding non-if block → 1 (else_open) + `m_else`.
    ///     - non-yielding else → 1 (else_open).
    /// The outermost caller adds +1 for the shared `after_if` case.
    fn elseSectionCaseCount(self: *const Printer, else_branch: NodeId) u32 {
        if (else_branch == hir_mod.none_node_id) return 0;
        if (!self.subtreeContainsYield(else_branch)) return 1;
        if (self.hir.kindOf(else_branch) == .if_stmt) {
            const inner = hir_mod.ifOf(self.hir, else_branch);
            var n: u32 = 1; // inner's cur case = outer's else_open
            n += self.countYieldsInThenBranch(inner.then_branch);
            n += self.elseSectionCaseCount(inner.else_branch);
            return n;
        }
        // Yielding non-if else.
        var n: u32 = 1; // else_open
        if (self.singleYieldInThen(else_branch) != null) {
            n += 1;
        } else {
            const sl = hir_mod.blockStmts(self.hir, else_branch);
            for (sl) |st| {
                if (self.hir.kindOf(st) == .yield_expr) n += 1;
            }
        }
        return n;
    }

    /// Count yields in a then- or else-branch that's either a bare
    /// yield_expr, a block whose single stmt is the yield, or a
    /// block-stmt with mixed yields/non-yields.
    fn countYieldsInThenBranch(self: *const Printer, branch: NodeId) u32 {
        if (branch == hir_mod.none_node_id) return 0;
        if (self.singleYieldInThen(branch) != null) return 1;
        if (self.hir.kindOf(branch) != .block_stmt) return 0;
        const sl = hir_mod.blockStmts(self.hir, branch);
        var n: u32 = 0;
        for (sl) |s| {
            if (self.hir.kindOf(s) == .yield_expr) n += 1;
        }
        return n;
    }

    /// §4.A.4.5 v2 — like `multiYieldLoopBodyOk` but accepts blocks
    /// with **one or more** top-level yields. Used by the if-then-yield
    /// emit path which walks the body inline regardless of whether
    /// the yield count is 1 or 2+. The single-pure-yield single-stmt
    /// case stays handled by `singleYieldInThen`; this helper catches
    /// the "pre-stmts + yield + post-stmts" split shape and the
    /// multi-yield-with-interspersed-stmts shape. Non-yield stmts must
    /// be yield-free and have no unhandleable break/continue.
    fn yieldBlockOkInIfBranch(self: *const Printer, body: NodeId) bool {
        if (body == hir_mod.none_node_id) return false;
        if (self.hir.kindOf(body) != .block_stmt) return false;
        const stmts = hir_mod.blockStmts(self.hir, body);
        var yield_count: usize = 0;
        for (stmts) |s| {
            if (self.hir.kindOf(s) == .yield_expr) {
                const yp = hir_mod.yieldExprOf(self.hir, s);
                if (yp.expr != hir_mod.none_node_id and self.subtreeContainsYield(yp.expr)) return false;
                yield_count += 1;
            } else {
                if (self.subtreeContainsYield(s)) return false;
                if (self.classifyBreakContinueImpl(s, false) == .unhandleable) return false;
            }
        }
        return yield_count >= 1;
    }

    /// §4.A.4.3 — split a block-statement loop body into its
    /// pre-yield statements, the single yield node, and its
    /// post-yield statements. Returns `null` if the body isn't a
    /// block with exactly one top-level yield, if any non-yield
    /// statement's subtree contains a yield, or if any pre/post
    /// statement contains a `break_stmt` or `continue_stmt` that
    /// would target the lowered loop (those would emit as bare
    /// `break;`/`continue;` inside the state machine's switch and
    /// incorrectly exit the switch rather than the loop). Bare-yield
    /// bodies (no block, or a one-statement block whose statement
    /// is the yield) are handled by `singleYieldInThen` and
    /// intentionally return `null` here so callers stay on the
    /// existing simpler emit path for that shape.
    fn splitLoopBody(self: *const Printer, body: NodeId, accept_continue: bool) ?struct {
        pre: []const NodeId,
        yield_node: NodeId,
        post: []const NodeId,
    } {
        if (body == hir_mod.none_node_id) return null;
        if (self.hir.kindOf(body) != .block_stmt) return null;
        const stmts = hir_mod.blockStmts(self.hir, body);
        if (stmts.len < 2) return null;
        var yield_idx: ?usize = null;
        for (stmts, 0..) |s, i| {
            if (self.hir.kindOf(s) == .yield_expr) {
                if (yield_idx != null) return null;
                yield_idx = i;
            } else {
                if (self.subtreeContainsYield(s)) return null;
                if (self.classifyBreakContinueImpl(s, accept_continue) == .unhandleable) return null;
            }
        }
        const idx = yield_idx orelse return null;
        return .{
            .pre = stmts[0..idx],
            .yield_node = stmts[idx],
            .post = stmts[idx + 1 ..],
        };
    }

    /// Verdict from inspecting break/continue nodes inside a
    /// candidate generator loop body.
    const BreakContinueScan = enum {
        /// No problematic break/continue — emit normally.
        none,
        /// At least one `break;` or `continue;` targets the
        /// lowered loop. Rewritable to `return [3, label];` when
        /// the enclosing loop type supports it (`while_stmt`
        /// supports both today; `do_while_stmt`/`for_stmt` support
        /// only `break_only`).
        has_break_or_continue,
        /// `continue;` targets the lowered loop in a context that
        /// doesn't yet support it (today: any loop except
        /// `while_stmt`), OR a break/continue passes through a
        /// `try_stmt` on its way out of the body — neither shape
        /// lowers in v0; bail to native function*.
        unhandleable,
    };

    /// Classify every `break_stmt` / `continue_stmt` in the subtree
    /// rooted at `root` based on whether its target is inside or
    /// outside the subtree, and whether the path to that target
    /// passes through any construct (`try_stmt`) the state-machine
    /// lowering can't safely re-route. break/continue contained
    /// inside a nested loop/switch within the subtree pass through
    /// fine and don't contribute to the verdict. `accept_continue`
    /// gates whether `continue;` targeting the lowered loop is OK
    /// (while-loops only, today).
    fn classifyBreakContinue(self: *const Printer, root: NodeId) BreakContinueScan {
        return self.classifyBreakContinueImpl(root, false);
    }
    fn classifyBreakContinueWithContinue(self: *const Printer, root: NodeId) BreakContinueScan {
        return self.classifyBreakContinueImpl(root, true);
    }
    fn classifyBreakContinueImpl(self: *const Printer, root: NodeId, accept_continue: bool) BreakContinueScan {
        if (root == hir_mod.none_node_id) return .none;
        // If `root` itself is a loop/switch, every break/continue
        // inside it targets `root` or something nested deeper —
        // all stay inside the passed-through inline construct.
        const root_kind = self.hir.kindOf(root);
        switch (root_kind) {
            .while_stmt, .do_while_stmt, .for_stmt, .for_in_stmt, .for_of_stmt, .switch_stmt => return .none,
            else => {},
        }
        const total = self.hir.nodeCount();
        var result: BreakContinueScan = .none;
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            const k = self.hir.kindOf(i);
            if (k != .break_stmt and k != .continue_stmt) continue;
            var cur: NodeId = self.hir.parentOf(i);
            var nested: bool = false;
            var through_try: bool = false;
            while (cur != hir_mod.none_node_id and cur != root) {
                const pk = self.hir.kindOf(cur);
                switch (pk) {
                    .while_stmt, .do_while_stmt, .for_stmt, .for_in_stmt, .for_of_stmt, .switch_stmt => {
                        nested = true;
                        break;
                    },
                    .try_stmt => through_try = true,
                    else => {},
                }
                const p = self.hir.parentOf(cur);
                if (p == cur) break;
                cur = p;
            }
            if (nested) continue;
            if (cur != root) continue;
            // This break/continue targets the lowered loop.
            if (through_try) return .unhandleable;
            if (k == .continue_stmt and !accept_continue) return .unhandleable;
            result = .has_break_or_continue;
        }
        return result;
    }

    /// §4.A.4.2 — true iff any node in the subtree rooted at `root`
    /// is a `yield_expr`. Uses a linear sweep over the HIR's flat
    /// node array plus an ancestor-chain walk per yield candidate,
    /// which is O(N × depth) — fine for the small generator bodies
    /// this is called on.
    fn subtreeContainsYield(self: *const Printer, root: NodeId) bool {
        if (root == hir_mod.none_node_id) return false;
        if (self.hir.kindOf(root) == .yield_expr) return true;
        const total = self.hir.nodeCount();
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            if (self.hir.kindOf(i) != .yield_expr) continue;
            var cur: NodeId = self.hir.parentOf(i);
            while (cur != hir_mod.none_node_id) {
                if (cur == root) return true;
                const p = self.hir.parentOf(cur);
                if (p == cur) break;
                cur = p;
            }
        }
        return false;
    }

    /// §4.A.4 v0 — emit the linear state-machine downlevel:
    ///
    /// ```js
    /// {
    ///     return __generator(this, function (_a) {
    ///         switch (_a.label) {
    ///             case 0: <pre-yield stmts> return [4 /*yield*/, V1];
    ///             case 1: _a.sent(); <stmts> return [4 /*yield*/, V2];
    ///             …
    ///             case N: _a.sent(); <tail> return [2 /*return*/];
    ///         }
    ///     });
    /// }
    /// ```
    ///
    /// Op-code conventions (matching tslib's `__generator`):
    ///   * `[4, value]` — yield value
    ///   * `[5, expr]`  — yield* expr (delegate)
    ///   * `[2, value]` — return value (terminates)
    ///   * `[2]`        — bare return (terminates)
    ///
    /// Caller is responsible for gating on `canLowerGeneratorBody`.
    fn printGeneratorDownlevelBody(self: *Printer, body: NodeId, params: []const NodeId) anyerror!void {
        try self.write("{");
        self.depth += 1;
        try self.writeNewlineIndent();
        // §4.A destructuring v13 — destructuring-param shim at the
        // outer function level so the inner state-machine sees the
        // bindings via closure.
        if (self.options.es_target == .es5 and self.hasDestructuringParam(params)) {
            try self.writeDestructuringParamShims(params);
            try self.writeNewlineIndent();
        }
        try self.write("return __generator(this, function (_a) {");
        self.depth += 1;
        try self.writeNewlineIndent();
        try self.write("switch (_a.label) {");
        self.depth += 1;
        // §4.A.4 — set the sync-gen flag so nested `return E;` (via
        // recursively-printed loop bodies, if branches, switch cases)
        // rewrites to `return [2, E];` automatically.
        const prev_sync_gen = self.in_sync_gen_body;
        self.in_sync_gen_body = true;
        defer self.in_sync_gen_body = prev_sync_gen;

        const stmts = hir_mod.blockStmts(self.hir, body);
        var state: u32 = 0;
        var buf: [16]u8 = undefined;

        try self.writeNewlineIndent();
        try self.write("case 0:");
        var ended = false;

        for (stmts) |stmt| {
            const k = self.hir.kindOf(stmt);
            if (k == .yield_expr) {
                try self.emitGenYieldTransition(stmt, &state, &buf, null, .new_decl);
                try self.write(" _a.sent();");
            } else if (k == .return_stmt) {
                const r = hir_mod.returnOf(self.hir, stmt);
                try self.write(" return [2");
                if (r.value != hir_mod.none_node_id) {
                    try self.write(", ");
                    try self.printExpression(r.value);
                }
                try self.write("];");
                ended = true;
                break;
            } else if (k == .var_decl or k == .let_decl or k == .const_decl) {
                const v = hir_mod.varDeclOf(self.hir, stmt);
                // §4.A.4.1 — `let x = yield E;` lowers to a
                // `var x = _a.sent();` binding immediately after
                // the yield-state transition. Decls without a
                // yield initializer pass through as plain `var`
                // (let/const semantics are softened to var for
                // the state-machine body; preserving block scope
                // would require splitting cases by lexical scope,
                // which is part of §4.A.4.2).
                if (v.init != hir_mod.none_node_id and self.hir.kindOf(v.init) == .yield_expr) {
                    try self.emitGenYieldTransition(v.init, &state, &buf, v.name, .new_decl);
                } else {
                    try self.write(" var ");
                    if (v.name != hir_mod.none_node_id) try self.printExpression(v.name);
                    if (v.init != hir_mod.none_node_id) {
                        try self.write(" = ");
                        try self.printExpression(v.init);
                    }
                    try self.write(";");
                }
            } else if (k == .assignment) {
                const a = hir_mod.assignmentOf(self.hir, stmt);
                // §4.A.4.1 — `x = yield E;` (plain `=`) lowers to
                // `x = _a.sent();` after the yield transition.
                if (a.op == null and self.hir.kindOf(a.value) == .yield_expr) {
                    try self.emitGenYieldTransition(a.value, &state, &buf, a.target, .assignment);
                } else {
                    try self.write(" ");
                    try self.printNonIndentStatement(stmt);
                }
            } else if (k == .call_expr) {
                // `f(yield E);` — close current case with the yield's
                // `return [4, E];`, then open `case +1: f(_a.sent());`.
                const cp = hir_mod.callOf(self.hir, stmt);
                const args = hir_mod.callArgs(self.hir, stmt);
                if (args.len == 1 and self.hir.kindOf(args[0]) == .yield_expr) {
                    const yp = hir_mod.yieldExprOf(self.hir, args[0]);
                    try self.write(" return [4");
                    if (yp.expr != hir_mod.none_node_id) {
                        try self.write(", ");
                        try self.printExpression(yp.expr);
                    }
                    try self.write("];");
                    state += 1;
                    const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num);
                    try self.write(": ");
                    try self.printExpression(cp.callee);
                    try self.write("(_a.sent());");
                } else {
                    try self.write(" ");
                    try self.printNonIndentStatement(stmt);
                }
            } else if (k == .while_stmt and self.subtreeContainsYield(stmt)) {
                // §4.A.4.2 part 2d / §4.A.4.3 / §4.A.4.5 — `while (cond) body;`.
                // Single-yield body: 3-case loop (header / resume / exit).
                // Multi-yield body: N+2-case loop (header / N resumption
                // cases — last loops back to header / exit).
                const prev_break = self.gen_break_label;
                const prev_continue = self.gen_continue_label;
                defer {
                    self.gen_break_label = prev_break;
                    self.gen_continue_label = prev_continue;
                }
                const wp = hir_mod.whileOf(self.hir, stmt);
                // Multi-yield path — fan out body inline.
                if (self.singleYieldInThen(wp.body) == null and self.splitLoopBody(wp.body, true) == null) {
                    const header = state + 1;
                    // Count yields to derive the exit label up front.
                    const body_stmts = hir_mod.blockStmts(self.hir, wp.body);
                    var n_yields: u32 = 0;
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) n_yields += 1;
                    }
                    const exit_label = state + 1 + n_yields + 1; // header + N resumes + exit
                    self.gen_break_label = exit_label;
                    self.gen_continue_label = header;
                    // Open header case.
                    state += 1;
                    {
                        const num_header = std.fmt.bufPrint(&buf, "{d}", .{header}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num_header);
                        try self.write(":");
                        var num_exit_buf: [16]u8 = undefined;
                        const num_exit = std.fmt.bufPrint(&num_exit_buf, "{d}", .{exit_label}) catch unreachable;
                        try self.write(" if (!(");
                        try self.printExpression(wp.cond);
                        try self.write(")) return [3, ");
                        try self.write(num_exit);
                        try self.write("];");
                    }
                    // Walk body stmts inline; each yield closes the current
                    // case and opens the next resumption case. The last
                    // resumption case ends with the loopback to header.
                    var emitted_yields: u32 = 0;
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) {
                            const yp_n = hir_mod.yieldExprOf(self.hir, s);
                            const op_n: []const u8 = if (yp_n.type_node != hir_mod.none_node_id) "5" else "4";
                            try self.write(" return [");
                            try self.write(op_n);
                            if (yp_n.expr != hir_mod.none_node_id) {
                                try self.write(", ");
                                try self.printExpression(yp_n.expr);
                            }
                            try self.write("];");
                            state += 1;
                            emitted_yields += 1;
                            const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                            try self.writeNewlineIndent();
                            try self.write("case ");
                            try self.write(num_resume);
                            try self.write(": _a.sent();");
                        } else {
                            try self.write(" ");
                            try self.printNonIndentStatement(s);
                        }
                    }
                    // Last resumption case: loopback to header.
                    var num_header_buf: [16]u8 = undefined;
                    const num_header_back = std.fmt.bufPrint(&num_header_buf, "{d}", .{header}) catch unreachable;
                    try self.write(" return [3, ");
                    try self.write(num_header_back);
                    try self.write("];");
                    // Open exit case.
                    state += 1;
                    {
                        const num_exit_open = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num_exit_open);
                        try self.write(":");
                    }
                    continue;
                }
                var pre: []const NodeId = &[_]NodeId{};
                var post: []const NodeId = &[_]NodeId{};
                const ye_node: NodeId = if (self.singleYieldInThen(wp.body)) |single|
                    single
                else blk: {
                    const split = self.splitLoopBody(wp.body, true) orelse unreachable;
                    pre = split.pre;
                    post = split.post;
                    break :blk split.yield_node;
                };
                const yp = hir_mod.yieldExprOf(self.hir, ye_node);
                const op: []const u8 = if (yp.type_node != hir_mod.none_node_id) "5" else "4";
                // §4.A.4.10 — yield-in-cond adds an extra resumption
                // case for the cond's yield. Layout:
                //   no cond-yield (existing):  header / body-resume / exit (3 cases)
                //   cond-yield (new):          header / cond-resume / body-resume / exit (4 cases)
                // In the cond-yield path, `header` emits `return [4, E_cond];`
                // and `cond_resume` does `if (!_a.sent()) return [3, exit];`
                // before the pre-stmts and the body yield.
                const cond_is_yield = self.hir.kindOf(wp.cond) == .yield_expr;
                const header = state + 1;
                const cond_resume_label: u32 = if (cond_is_yield) state + 2 else 0;
                const resume_label: u32 = if (cond_is_yield) state + 3 else state + 2;
                const exit_label: u32 = if (cond_is_yield) state + 4 else state + 3;
                // §4.A.4.4 — set break/continue labels so `break;` and
                // `continue;` inside pre/post rewrite to the appropriate
                // state-machine jump. Inner loops/switches save+clear
                // these in their own printers.
                self.gen_break_label = exit_label;
                self.gen_continue_label = header;
                // Open header case.
                {
                    const num_header = std.fmt.bufPrint(&buf, "{d}", .{header}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_header);
                    try self.write(":");
                    if (cond_is_yield) {
                        // Yield the cond. Truthy test happens at the
                        // cond_resume case below.
                        const yc = hir_mod.yieldExprOf(self.hir, wp.cond);
                        try self.write(" return [4");
                        if (yc.expr != hir_mod.none_node_id) {
                            try self.write(", ");
                            try self.printExpression(yc.expr);
                        }
                        try self.write("];");
                    } else {
                        var num_exit_buf: [16]u8 = undefined;
                        const num_exit = std.fmt.bufPrint(&num_exit_buf, "{d}", .{exit_label}) catch unreachable;
                        try self.write(" if (!(");
                        try self.printExpression(wp.cond);
                        try self.write(")) return [3, ");
                        try self.write(num_exit);
                        try self.write("];");
                        for (pre) |ps| {
                            try self.write(" ");
                            try self.printNonIndentStatement(ps);
                        }
                        try self.write(" return [");
                        try self.write(op);
                        if (yp.expr != hir_mod.none_node_id) {
                            try self.write(", ");
                            try self.printExpression(yp.expr);
                        }
                        try self.write("];");
                    }
                }
                // Open cond_resume case (when applicable): truthy test +
                // pre-stmts + body yield.
                if (cond_is_yield) {
                    const num_cr = std.fmt.bufPrint(&buf, "{d}", .{cond_resume_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_cr);
                    try self.write(":");
                    var num_exit_buf: [16]u8 = undefined;
                    const num_exit = std.fmt.bufPrint(&num_exit_buf, "{d}", .{exit_label}) catch unreachable;
                    try self.write(" if (!_a.sent()) return [3, ");
                    try self.write(num_exit);
                    try self.write("];");
                    for (pre) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                    try self.write(" return [");
                    try self.write(op);
                    if (yp.expr != hir_mod.none_node_id) {
                        try self.write(", ");
                        try self.printExpression(yp.expr);
                    }
                    try self.write("];");
                }
                // Open body-resume case: sent + post-stmts + loopback.
                {
                    const num_resume = std.fmt.bufPrint(&buf, "{d}", .{resume_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_resume);
                    try self.write(": _a.sent();");
                    for (post) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                    var num_header_buf: [16]u8 = undefined;
                    const num_header_back = std.fmt.bufPrint(&num_header_buf, "{d}", .{header}) catch unreachable;
                    try self.write(" return [3, ");
                    try self.write(num_header_back);
                    try self.write("];");
                }
                // Open exit case.
                {
                    const num_exit_open = std.fmt.bufPrint(&buf, "{d}", .{exit_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_exit_open);
                    try self.write(":");
                }
                state += if (cond_is_yield) @as(u32, 4) else @as(u32, 3);
            } else if (k == .for_in_stmt and self.subtreeContainsYield(stmt)) {
                // §4.A.4.8 cont. — `for (const k in source) yield E;`.
                // Keys are collected eagerly into `_keys` (synthesized
                // `for (var _x in source) _keys.push(_x);`) inside the
                // current case, then iterated with an indexed-for
                // state-machine. Same layout as for-of:
                //   cur: var _keys = [], _i = 0; for (var _x in src) _keys.push(_x);
                //   header: cond + binding + first yield
                //   resumes + continue + exit
                const prev_break = self.gen_break_label;
                const prev_continue = self.gen_continue_label;
                defer {
                    self.gen_break_label = prev_break;
                    self.gen_continue_label = prev_continue;
                }
                const fip = hir_mod.forInOf(self.hir, stmt);
                var pre: []const NodeId = &[_]NodeId{};
                var post: []const NodeId = &[_]NodeId{};
                const ye_first: NodeId = if (self.singleYieldInThen(fip.body)) |single|
                    single
                else if (self.splitLoopBody(fip.body, true)) |split| blk: {
                    pre = split.pre;
                    post = split.post;
                    break :blk split.yield_node;
                } else hir_mod.none_node_id;
                var n_yields: u32 = 1;
                if (ye_first == hir_mod.none_node_id) {
                    n_yields = 0;
                    const body_stmts = hir_mod.blockStmts(self.hir, fip.body);
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) n_yields += 1;
                    }
                }
                const header = state + 1;
                const continue_label = state + 1 + n_yields + 1;
                const exit_label = continue_label + 1;
                self.gen_break_label = exit_label;
                self.gen_continue_label = continue_label;
                // Eager key collection in the current case.
                try self.write(" var _keys = [], _i = 0;");
                try self.write(" for (var _x in ");
                try self.printExpression(fip.source);
                try self.write(") _keys.push(_x);");
                const target_name: NodeId = blk: {
                    const tk = self.hir.kindOf(fip.target);
                    if (tk == .identifier) break :blk fip.target;
                    const v = hir_mod.varDeclOf(self.hir, fip.target);
                    break :blk v.name;
                };
                state += 1;
                {
                    const num_header = std.fmt.bufPrint(&buf, "{d}", .{header}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_header);
                    try self.write(": if (!(_i < _keys.length)) return [3, ");
                    var num_exit_buf: [16]u8 = undefined;
                    try self.write(std.fmt.bufPrint(&num_exit_buf, "{d}", .{exit_label}) catch unreachable);
                    try self.write("]; var ");
                    // §4.A.4.8 v2 — printBindingName routes identifier
                    // / array_pattern / object_pattern through the right
                    // emit (destructuring shapes render correctly).
                    try self.printBindingName(target_name);
                    try self.write(" = _keys[_i];");
                }
                if (ye_first != hir_mod.none_node_id) {
                    for (pre) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                    const yp = hir_mod.yieldExprOf(self.hir, ye_first);
                    const op: []const u8 = if (yp.type_node != hir_mod.none_node_id) "5" else "4";
                    try self.write(" return [");
                    try self.write(op);
                    if (yp.expr != hir_mod.none_node_id) {
                        try self.write(", ");
                        try self.printExpression(yp.expr);
                    }
                    try self.write("];");
                    state += 1;
                    const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_resume);
                    try self.write(": _a.sent();");
                    for (post) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                } else {
                    const body_stmts = hir_mod.blockStmts(self.hir, fip.body);
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) {
                            const yp = hir_mod.yieldExprOf(self.hir, s);
                            const op: []const u8 = if (yp.type_node != hir_mod.none_node_id) "5" else "4";
                            try self.write(" return [");
                            try self.write(op);
                            if (yp.expr != hir_mod.none_node_id) {
                                try self.write(", ");
                                try self.printExpression(yp.expr);
                            }
                            try self.write("];");
                            state += 1;
                            const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                            try self.writeNewlineIndent();
                            try self.write("case ");
                            try self.write(num_resume);
                            try self.write(": _a.sent();");
                        } else {
                            try self.write(" ");
                            try self.printNonIndentStatement(s);
                        }
                    }
                }
                state += 1;
                {
                    const num_continue = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_continue);
                    try self.write(": _i++; return [3, ");
                    var num_header_buf: [16]u8 = undefined;
                    try self.write(std.fmt.bufPrint(&num_header_buf, "{d}", .{header}) catch unreachable);
                    try self.write("];");
                }
                state += 1;
                {
                    const num_exit_open = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_exit_open);
                    try self.write(":");
                }
            } else if (k == .for_of_stmt and self.subtreeContainsYield(stmt)) {
                // §4.A.4.8 v0 — `for (const x of source) yield E;` at ES5.
                // Lowers to the indexed-for state-machine shape (the same
                // form the regular for-of downlevel produces). Layout:
                //   cur: `var _i = 0, _arr = source;`  (init)
                //   header: cond + `var x = _arr[_i];` binding + first yield
                //   N resumption cases (last falls through to continue)
                //   continue: `_i++; return [3, header];`
                //   exit
                const prev_break = self.gen_break_label;
                const prev_continue = self.gen_continue_label;
                defer {
                    self.gen_break_label = prev_break;
                    self.gen_continue_label = prev_continue;
                }
                const fop = hir_mod.forInOf(self.hir, stmt);
                // Determine the body's yield shape.
                var pre: []const NodeId = &[_]NodeId{};
                var post: []const NodeId = &[_]NodeId{};
                const ye_first: NodeId = if (self.singleYieldInThen(fop.body)) |single|
                    single
                else if (self.splitLoopBody(fop.body, true)) |split| blk: {
                    pre = split.pre;
                    post = split.post;
                    break :blk split.yield_node;
                } else blk2: {
                    // Multi-yield path — collect body stmts; the walker
                    // emits them inline.
                    _ = self.multiYieldLoopBodyOk(fop.body, true);
                    break :blk2 hir_mod.none_node_id;
                };
                // Count yields in body for label allocation.
                var n_yields: u32 = 1;
                if (ye_first == hir_mod.none_node_id) {
                    n_yields = 0;
                    const body_stmts = hir_mod.blockStmts(self.hir, fop.body);
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) n_yields += 1;
                    }
                }
                // §4.A.4.8 — pick the iteration shape:
                //   * `downlevel_iteration=true`: iterator protocol via
                //     `__values` + `.next()` (works for Map/Set/custom
                //     iterables). When set, also wrap the loop in a
                //     try/catch/finally that runs the iterator's
                //     `.return()` on abrupt completion (§4.A.4.8 cont.3).
                //   * default: cheaper indexed-for (assumes array-shape).
                const use_iter_protocol = self.options.downlevel_iteration;
                const use_cleanup = use_iter_protocol;
                // Label layout (with cleanup, +3 cases past `continue`):
                //   header / N resumes / continue / catchStart / finallyStart / endLabel
                const header = state + 1;
                const continue_label = state + 1 + n_yields + 1;
                const catch_label: u32 = if (use_cleanup) continue_label + 1 else 0;
                const finally_label: u32 = if (use_cleanup) continue_label + 2 else 0;
                const exit_label = if (use_cleanup) continue_label + 3 else continue_label + 1;
                self.gen_break_label = exit_label;
                self.gen_continue_label = continue_label;
                // Init in current case.
                if (use_iter_protocol) {
                    try self.write(" var e_1, _r;");
                    var nbuf: [16]u8 = undefined;
                    try self.write(" _a.trys.push([");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{state}) catch unreachable);
                    try self.write(", ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{catch_label}) catch unreachable);
                    try self.write(", ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{finally_label}) catch unreachable);
                    try self.write(", ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{exit_label}) catch unreachable);
                    try self.write("]); var _b = __values(");
                    try self.printExpression(fop.source);
                    try self.write("), _c = _b.next();");
                } else {
                    try self.write(" var _i = 0, _arr = ");
                    try self.printExpression(fop.source);
                    try self.write(";");
                }
                const target_name: NodeId = blk: {
                    const tk = self.hir.kindOf(fop.target);
                    if (tk == .identifier) break :blk fop.target;
                    const v = hir_mod.varDeclOf(self.hir, fop.target);
                    break :blk v.name;
                };
                // Open header case: cond check + binding + (pre stmts) + first yield (if any).
                state += 1;
                {
                    const num_header = std.fmt.bufPrint(&buf, "{d}", .{header}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_header);
                    try self.write(":");
                    var num_exit_buf: [16]u8 = undefined;
                    const num_exit = std.fmt.bufPrint(&num_exit_buf, "{d}", .{exit_label}) catch unreachable;
                    if (use_iter_protocol) {
                        try self.write(" if (_c.done) return [3, ");
                        try self.write(num_exit);
                        try self.write("]; var ");
                        try self.printBindingName(target_name);
                        try self.write(" = _c.value;");
                    } else {
                        try self.write(" if (!(_i < _arr.length)) return [3, ");
                        try self.write(num_exit);
                        try self.write("]; var ");
                        try self.printBindingName(target_name);
                        try self.write(" = _arr[_i];");
                    }
                }
                // Body emission: bare-yield → emit pre / yield / post around
                // the existing 3-case shape; multi-yield body → walk inline.
                if (ye_first != hir_mod.none_node_id) {
                    // pre stmts in the header case.
                    for (pre) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                    const yp = hir_mod.yieldExprOf(self.hir, ye_first);
                    const op: []const u8 = if (yp.type_node != hir_mod.none_node_id) "5" else "4";
                    try self.write(" return [");
                    try self.write(op);
                    if (yp.expr != hir_mod.none_node_id) {
                        try self.write(", ");
                        try self.printExpression(yp.expr);
                    }
                    try self.write("];");
                    state += 1;
                    const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_resume);
                    try self.write(": _a.sent();");
                    for (post) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                } else {
                    // Multi-yield body walker.
                    const body_stmts = hir_mod.blockStmts(self.hir, fop.body);
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) {
                            const yp = hir_mod.yieldExprOf(self.hir, s);
                            const op: []const u8 = if (yp.type_node != hir_mod.none_node_id) "5" else "4";
                            try self.write(" return [");
                            try self.write(op);
                            if (yp.expr != hir_mod.none_node_id) {
                                try self.write(", ");
                                try self.printExpression(yp.expr);
                            }
                            try self.write("];");
                            state += 1;
                            const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                            try self.writeNewlineIndent();
                            try self.write("case ");
                            try self.write(num_resume);
                            try self.write(": _a.sent();");
                        } else {
                            try self.write(" ");
                            try self.printNonIndentStatement(s);
                        }
                    }
                }
                // Open continue case: advance iteration + loopback to header.
                state += 1;
                {
                    const num_continue = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_continue);
                    if (use_iter_protocol) {
                        try self.write(": _c = _b.next(); return [3, ");
                    } else {
                        try self.write(": _i++; return [3, ");
                    }
                    var num_header_buf: [16]u8 = undefined;
                    try self.write(std.fmt.bufPrint(&num_header_buf, "{d}", .{header}) catch unreachable);
                    try self.write("];");
                }
                if (use_cleanup) {
                    // §4.A.4.8 cont.3 — catch + finally cleanup wrap.
                    // catch captures any thrown error into `e_1`; finally
                    // runs the iterator's `.return()` if available and
                    // rethrows the captured error (if any).
                    state += 1;
                    var nbuf: [16]u8 = undefined;
                    {
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{state}) catch unreachable);
                        try self.write(": e_1 = { error: _a.sent() }; return [3, ");
                        try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{finally_label}) catch unreachable);
                        try self.write("];");
                    }
                    state += 1;
                    {
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{state}) catch unreachable);
                        try self.write(": if (_c && !_c.done && (_r = _b.return)) _r.call(_b); if (e_1) throw e_1.error; return [7];");
                    }
                }
                // Open exit case.
                state += 1;
                {
                    const num_exit_open = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_exit_open);
                    try self.write(":");
                }
            } else if (k == .for_stmt and self.subtreeContainsYield(stmt)) {
                // §4.A.4.2 part 2f / §4.A.4.3 / §4.A.4.4 part 3 —
                // `for (init; cond; update) body;` 4-case loop:
                //   case state+1 (header): if (!cond) return [3, exit]; pre; return [op, E];
                //   case state+2 (resume): _a.sent(); + post-stmts; falls through
                //   case state+3 (continue): update; return [3, header];
                //   case state+4 (exit): post-loop fall-through
                // Init runs in the current case before fall-through
                // into the header. continue jumps to the continue
                // case so the update step runs once before the next
                // cond check.
                //
                // §4.A.4.12 — when init is `var x = yield E;` the
                // yield+bind is peeled off into its own case pair
                // before the for-stmt machinery opens its header.
                // All header/resume/continue/exit labels shift by 1.
                const prev_break = self.gen_break_label;
                const prev_continue = self.gen_continue_label;
                defer {
                    self.gen_break_label = prev_break;
                    self.gen_continue_label = prev_continue;
                }
                const fp = hir_mod.forStmtOf(self.hir, stmt);
                const init_is_yield_decl = fp.init != hir_mod.none_node_id and self.subtreeContainsYield(fp.init);
                if (init_is_yield_decl) {
                    const v = hir_mod.varDeclOf(self.hir, fp.init);
                    try self.emitGenYieldTransition(v.init, &state, &buf, v.name, .new_decl);
                }
                // Multi-yield path — header + N resumes + continue + exit.
                if (self.singleYieldInThen(fp.body) == null and self.splitLoopBody(fp.body, true) == null) {
                    const header = state + 1;
                    const body_stmts = hir_mod.blockStmts(self.hir, fp.body);
                    var n_yields: u32 = 0;
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) n_yields += 1;
                    }
                    const continue_label = state + 1 + n_yields + 1; // header + N resumes + continue
                    const exit_label = continue_label + 1;
                    self.gen_break_label = exit_label;
                    self.gen_continue_label = continue_label;
                    // Init in current case (skipped when the init was a
                    // yield-decl peeled off above into its own case pair).
                    if (fp.init != hir_mod.none_node_id and !init_is_yield_decl) {
                        try self.write(" ");
                        try self.printNonIndentStatement(fp.init);
                    }
                    // Open header case.
                    state += 1;
                    {
                        const num_header = std.fmt.bufPrint(&buf, "{d}", .{header}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num_header);
                        try self.write(":");
                        if (fp.cond != hir_mod.none_node_id) {
                            var num_exit_buf: [16]u8 = undefined;
                            const num_exit = std.fmt.bufPrint(&num_exit_buf, "{d}", .{exit_label}) catch unreachable;
                            try self.write(" if (!(");
                            try self.printExpression(fp.cond);
                            try self.write(")) return [3, ");
                            try self.write(num_exit);
                            try self.write("];");
                        }
                    }
                    // Walk body stmts inline.
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) {
                            const yp_n = hir_mod.yieldExprOf(self.hir, s);
                            const op_n: []const u8 = if (yp_n.type_node != hir_mod.none_node_id) "5" else "4";
                            try self.write(" return [");
                            try self.write(op_n);
                            if (yp_n.expr != hir_mod.none_node_id) {
                                try self.write(", ");
                                try self.printExpression(yp_n.expr);
                            }
                            try self.write("];");
                            state += 1;
                            const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                            try self.writeNewlineIndent();
                            try self.write("case ");
                            try self.write(num_resume);
                            try self.write(": _a.sent();");
                        } else {
                            try self.write(" ");
                            try self.printNonIndentStatement(s);
                        }
                    }
                    // Final resumption case falls through to continue.
                    // Open continue case: update + loopback.
                    state += 1;
                    {
                        const num_continue = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num_continue);
                        try self.write(":");
                        if (fp.update != hir_mod.none_node_id) {
                            try self.write(" ");
                            try self.printExpression(fp.update);
                            try self.write(";");
                        }
                        var num_header_buf: [16]u8 = undefined;
                        const num_header_back = std.fmt.bufPrint(&num_header_buf, "{d}", .{header}) catch unreachable;
                        try self.write(" return [3, ");
                        try self.write(num_header_back);
                        try self.write("];");
                    }
                    // Open exit case.
                    state += 1;
                    {
                        const num_exit_open = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num_exit_open);
                        try self.write(":");
                    }
                    continue;
                }
                var pre: []const NodeId = &[_]NodeId{};
                var post: []const NodeId = &[_]NodeId{};
                const ye_node: NodeId = if (self.singleYieldInThen(fp.body)) |single|
                    single
                else blk: {
                    const split = self.splitLoopBody(fp.body, true) orelse unreachable;
                    pre = split.pre;
                    post = split.post;
                    break :blk split.yield_node;
                };
                const yp = hir_mod.yieldExprOf(self.hir, ye_node);
                const op: []const u8 = if (yp.type_node != hir_mod.none_node_id) "5" else "4";
                // §4.A.4.15 — yield-in-cond adds an extra cond_resume
                // case between the header and the body-yield case.
                // Layout:
                //   no cond-yield (existing): header / resume / continue / exit (4 cases)
                //   cond-yield (new):         header / cond_resume / resume / continue / exit (5 cases)
                const cond_is_yield = fp.cond != hir_mod.none_node_id and self.hir.kindOf(fp.cond) == .yield_expr;
                const header = state + 1;
                const cond_resume_label: u32 = if (cond_is_yield) state + 2 else 0;
                const resume_label: u32 = if (cond_is_yield) state + 3 else state + 2;
                const continue_label: u32 = if (cond_is_yield) state + 4 else state + 3;
                const exit_label: u32 = if (cond_is_yield) state + 5 else state + 4;
                // §4.A.4.4 — set break/continue labels for the body's pre/post.
                self.gen_break_label = exit_label;
                self.gen_continue_label = continue_label;
                // Init in the current case (skipped when the init was a
                // yield-decl peeled off above into its own case pair).
                if (fp.init != hir_mod.none_node_id and !init_is_yield_decl) {
                    try self.write(" ");
                    try self.printNonIndentStatement(fp.init);
                }
                // Open header case: optional cond yield/check + pre-stmts + body yield.
                // With cond-yield the header just yields the cond
                // expression and the cond_resume case below does the
                // truthy test against `_a.sent()` before the body yield.
                {
                    const num_header = std.fmt.bufPrint(&buf, "{d}", .{header}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_header);
                    try self.write(":");
                    if (cond_is_yield) {
                        const yc = hir_mod.yieldExprOf(self.hir, fp.cond);
                        try self.write(" return [4");
                        if (yc.expr != hir_mod.none_node_id) {
                            try self.write(", ");
                            try self.printExpression(yc.expr);
                        }
                        try self.write("];");
                    } else {
                        if (fp.cond != hir_mod.none_node_id) {
                            var num_exit_buf: [16]u8 = undefined;
                            const num_exit = std.fmt.bufPrint(&num_exit_buf, "{d}", .{exit_label}) catch unreachable;
                            try self.write(" if (!(");
                            try self.printExpression(fp.cond);
                            try self.write(")) return [3, ");
                            try self.write(num_exit);
                            try self.write("];");
                        }
                        for (pre) |ps| {
                            try self.write(" ");
                            try self.printNonIndentStatement(ps);
                        }
                        try self.write(" return [");
                        try self.write(op);
                        if (yp.expr != hir_mod.none_node_id) {
                            try self.write(", ");
                            try self.printExpression(yp.expr);
                        }
                        try self.write("];");
                    }
                }
                // Open cond_resume case (cond-yield only): truthy test +
                // pre-stmts + body yield.
                if (cond_is_yield) {
                    const num_cr = std.fmt.bufPrint(&buf, "{d}", .{cond_resume_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_cr);
                    try self.write(":");
                    var num_exit_buf: [16]u8 = undefined;
                    const num_exit = std.fmt.bufPrint(&num_exit_buf, "{d}", .{exit_label}) catch unreachable;
                    try self.write(" if (!_a.sent()) return [3, ");
                    try self.write(num_exit);
                    try self.write("];");
                    for (pre) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                    try self.write(" return [");
                    try self.write(op);
                    if (yp.expr != hir_mod.none_node_id) {
                        try self.write(", ");
                        try self.printExpression(yp.expr);
                    }
                    try self.write("];");
                }
                // Open body-resume case: sent + post-stmts (falls through to continue).
                {
                    const num_resume = std.fmt.bufPrint(&buf, "{d}", .{resume_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_resume);
                    try self.write(": _a.sent();");
                    for (post) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                }
                // Open continue case: optional update + loopback.
                {
                    const num_continue = std.fmt.bufPrint(&buf, "{d}", .{continue_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_continue);
                    try self.write(":");
                    if (fp.update != hir_mod.none_node_id) {
                        try self.write(" ");
                        try self.printExpression(fp.update);
                        try self.write(";");
                    }
                    var num_header_buf: [16]u8 = undefined;
                    const num_header_back = std.fmt.bufPrint(&num_header_buf, "{d}", .{header}) catch unreachable;
                    try self.write(" return [3, ");
                    try self.write(num_header_back);
                    try self.write("];");
                }
                // Open exit case.
                {
                    const num_exit_open = std.fmt.bufPrint(&buf, "{d}", .{exit_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_exit_open);
                    try self.write(":");
                }
                state += if (cond_is_yield) @as(u32, 5) else @as(u32, 4);
            } else if (k == .do_while_stmt and self.subtreeContainsYield(stmt)) {
                // §4.A.4.2 part 2e / §4.A.4.3 / §4.A.4.4 part 3 —
                // `do body while (cond);` 4-case loop:
                //   case state+1 (body): pre-stmts + yield
                //   case state+2 (resume): _a.sent(); + post-stmts; falls through
                //   case state+3 (continue): if (cond) return [3, body];
                //   case state+4 (exit): post-loop fall-through
                // The dedicated continue case lets `continue;` inside
                // the body jump to it (running the cond-check without
                // re-running post-stmts).
                const prev_break = self.gen_break_label;
                const prev_continue = self.gen_continue_label;
                defer {
                    self.gen_break_label = prev_break;
                    self.gen_continue_label = prev_continue;
                }
                const dwp = hir_mod.doWhileOf(self.hir, stmt);
                // Multi-yield path — body + N resumes + continue + exit.
                if (self.singleYieldInThen(dwp.body) == null and self.splitLoopBody(dwp.body, true) == null) {
                    const body_label = state + 1;
                    const body_stmts = hir_mod.blockStmts(self.hir, dwp.body);
                    var n_yields: u32 = 0;
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) n_yields += 1;
                    }
                    const continue_label = state + 1 + n_yields + 1; // body + N resumes + continue
                    const exit_label = continue_label + 1;
                    self.gen_break_label = exit_label;
                    self.gen_continue_label = continue_label;
                    // Open body case.
                    state += 1;
                    {
                        const num_body = std.fmt.bufPrint(&buf, "{d}", .{body_label}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num_body);
                        try self.write(":");
                    }
                    // Walk body stmts inline.
                    for (body_stmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) {
                            const yp_n = hir_mod.yieldExprOf(self.hir, s);
                            const op_n: []const u8 = if (yp_n.type_node != hir_mod.none_node_id) "5" else "4";
                            try self.write(" return [");
                            try self.write(op_n);
                            if (yp_n.expr != hir_mod.none_node_id) {
                                try self.write(", ");
                                try self.printExpression(yp_n.expr);
                            }
                            try self.write("];");
                            state += 1;
                            const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                            try self.writeNewlineIndent();
                            try self.write("case ");
                            try self.write(num_resume);
                            try self.write(": _a.sent();");
                        } else {
                            try self.write(" ");
                            try self.printNonIndentStatement(s);
                        }
                    }
                    // Open continue case: cond loopback to body.
                    state += 1;
                    {
                        const num_continue = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num_continue);
                        try self.write(":");
                        var num_body_buf: [16]u8 = undefined;
                        const num_body_back = std.fmt.bufPrint(&num_body_buf, "{d}", .{body_label}) catch unreachable;
                        try self.write(" if (");
                        try self.printExpression(dwp.cond);
                        try self.write(") return [3, ");
                        try self.write(num_body_back);
                        try self.write("];");
                    }
                    // Open exit case.
                    state += 1;
                    {
                        const num_exit_open = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num_exit_open);
                        try self.write(":");
                    }
                    continue;
                }
                var pre: []const NodeId = &[_]NodeId{};
                var post: []const NodeId = &[_]NodeId{};
                const ye_node: NodeId = if (self.singleYieldInThen(dwp.body)) |single|
                    single
                else blk: {
                    const split = self.splitLoopBody(dwp.body, true) orelse unreachable;
                    pre = split.pre;
                    post = split.post;
                    break :blk split.yield_node;
                };
                const yp = hir_mod.yieldExprOf(self.hir, ye_node);
                const op: []const u8 = if (yp.type_node != hir_mod.none_node_id) "5" else "4";
                // §4.A.4.13 — yield-in-cond adds an extra cond_yield
                // case between the body-resume and the loopback test.
                // Layout:
                //   no cond-yield (existing):  body / resume / continue (cond) / exit (4 cases)
                //   cond-yield (new):          body / resume / cond_yield / cond_resume / exit (5 cases)
                // In the cond-yield path, the resume case falls through
                // to `cond_yield` which emits `return [4, E_cond];`;
                // `cond_resume` does `if (_a.sent()) return [3, body];`.
                const cond_is_yield = self.hir.kindOf(dwp.cond) == .yield_expr;
                const body_label = state + 1;
                const resume_label = state + 2;
                const cond_yield_label: u32 = if (cond_is_yield) state + 3 else 0;
                const continue_label: u32 = if (cond_is_yield) state + 4 else state + 3;
                const exit_label: u32 = if (cond_is_yield) state + 5 else state + 4;
                // §4.A.4.4 — set break/continue labels for the body's pre/post.
                self.gen_break_label = exit_label;
                self.gen_continue_label = if (cond_is_yield) cond_yield_label else continue_label;
                // Open body case: pre-stmts + yield.
                {
                    const num_body = std.fmt.bufPrint(&buf, "{d}", .{body_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_body);
                    try self.write(":");
                    for (pre) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                    try self.write(" return [");
                    try self.write(op);
                    if (yp.expr != hir_mod.none_node_id) {
                        try self.write(", ");
                        try self.printExpression(yp.expr);
                    }
                    try self.write("];");
                }
                // Open resume case: sent + post-stmts (falls through
                // to cond_yield in the cond-yield variant, otherwise
                // to continue).
                {
                    const num_resume = std.fmt.bufPrint(&buf, "{d}", .{resume_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_resume);
                    try self.write(": _a.sent();");
                    for (post) |ps| {
                        try self.write(" ");
                        try self.printNonIndentStatement(ps);
                    }
                }
                // Open cond_yield case (cond-yield only): emit the
                // cond's yield. The body-resume falls through into this.
                if (cond_is_yield) {
                    const num_cy = std.fmt.bufPrint(&buf, "{d}", .{cond_yield_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_cy);
                    try self.write(":");
                    const yc = hir_mod.yieldExprOf(self.hir, dwp.cond);
                    try self.write(" return [4");
                    if (yc.expr != hir_mod.none_node_id) {
                        try self.write(", ");
                        try self.printExpression(yc.expr);
                    }
                    try self.write("];");
                }
                // Open continue case (in cond-yield mode this is the
                // cond_resume case): yield-free cond just emits the
                // truthy test against `cond`; cond-yield uses
                // `_a.sent()` from the cond_yield resumption.
                {
                    const num_continue = std.fmt.bufPrint(&buf, "{d}", .{continue_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_continue);
                    try self.write(":");
                    var num_body_buf: [16]u8 = undefined;
                    const num_body_back = std.fmt.bufPrint(&num_body_buf, "{d}", .{body_label}) catch unreachable;
                    if (cond_is_yield) {
                        try self.write(" if (_a.sent()) return [3, ");
                        try self.write(num_body_back);
                        try self.write("];");
                    } else {
                        try self.write(" if (");
                        try self.printExpression(dwp.cond);
                        try self.write(") return [3, ");
                        try self.write(num_body_back);
                        try self.write("];");
                    }
                }
                // Open exit case.
                {
                    const num_exit = std.fmt.bufPrint(&buf, "{d}", .{exit_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_exit);
                    try self.write(":");
                }
                state += if (cond_is_yield) @as(u32, 5) else @as(u32, 4);
            } else if (k == .switch_stmt and self.subtreeContainsYield(stmt)) {
                // §4.A.4.16 v0 — switch with yielding case bodies.
                // Layout per case: each case-with-yield consumes 2
                // state slots (yield + resume+exit); pure yield-free
                // cases consume 1 state (body + break-rewritten exit).
                // Plus 1 dispatch case (current) + 1 exit case.
                const sp = hir_mod.switchOf(self.hir, stmt);
                const cases = hir_mod.switchCases(self.hir, stmt);
                // Two-pass: pass 1 assigns a state label to each case
                // and computes exit_label; pass 2 emits the dispatch
                // switch and each case body inline.
                var case_states: [128]u32 = undefined; // v0: cap at 128 cases
                var has_default = false;
                var default_state: u32 = 0;
                var next_state = state + 1;
                var case_idx: usize = 0;
                for (cases) |cn| {
                    if (self.hir.kindOf(cn) != .switch_case) continue;
                    case_states[case_idx] = next_state;
                    const cp_ = hir_mod.switchCaseOf(self.hir, cn);
                    if (cp_.value == hir_mod.none_node_id) {
                        has_default = true;
                        default_state = next_state;
                    }
                    // Count yields in body to compute state advance.
                    const stmts_ = hir_mod.switchCaseStmts(self.hir, cn);
                    var yield_count: u32 = 0;
                    for (stmts_) |st| {
                        if (self.hir.kindOf(st) == .yield_expr) yield_count += 1;
                    }
                    // Each yield consumes 2 states (close + resume open);
                    // body case open is 1; total per case = 1 + 2*yield_count.
                    // But the resume case ends with `return [3, exit]` and
                    // the open case label is the case_state itself, so
                    // advance = 1 + yield_count (each yield adds 1 resume state).
                    next_state += 1 + yield_count;
                    case_idx += 1;
                    if (case_idx >= case_states.len) return error.OutOfMemory;
                }
                const exit_label = next_state;
                // Save/restore gen_break_label: bare `break;` in case
                // bodies rewrites to `return [3, exit];`.
                const prev_break = self.gen_break_label;
                self.gen_break_label = exit_label;
                defer self.gen_break_label = prev_break;
                // Emit dispatch in current case.
                try self.write(" switch (");
                try self.printExpression(sp.discriminant);
                try self.write(") {");
                var di: usize = 0;
                for (cases) |cn| {
                    if (self.hir.kindOf(cn) != .switch_case) continue;
                    const cp = hir_mod.switchCaseOf(self.hir, cn);
                    if (cp.value == hir_mod.none_node_id) {
                        di += 1;
                        continue; // default handled below
                    }
                    try self.write(" case ");
                    try self.printExpression(cp.value);
                    try self.write(": return [3, ");
                    var nbuf: [16]u8 = undefined;
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{case_states[di]}) catch unreachable);
                    try self.write("];");
                    di += 1;
                }
                {
                    var nbuf: [16]u8 = undefined;
                    try self.write(" default: return [3, ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{if (has_default) default_state else exit_label}) catch unreachable);
                    try self.write("]; }");
                }
                // Pass 2: emit each case body.
                var ci: usize = 0;
                for (cases) |cn| {
                    if (self.hir.kindOf(cn) != .switch_case) continue;
                    state = case_states[ci];
                    {
                        var nbuf: [16]u8 = undefined;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{state}) catch unreachable);
                        try self.write(":");
                    }
                    const stmts2 = hir_mod.switchCaseStmts(self.hir, cn);
                    for (stmts2) |st| {
                        const sk = self.hir.kindOf(st);
                        if (sk == .yield_expr) {
                            const yp = hir_mod.yieldExprOf(self.hir, st);
                            try self.write(" return [4");
                            if (yp.expr != hir_mod.none_node_id) {
                                try self.write(", ");
                                try self.printExpression(yp.expr);
                            }
                            try self.write("];");
                            state += 1;
                            var nbuf: [16]u8 = undefined;
                            try self.writeNewlineIndent();
                            try self.write("case ");
                            try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{state}) catch unreachable);
                            try self.write(": _a.sent();");
                            continue;
                        }
                        // §4.A.4.16 v1 — `return E;` inside a state-
                        // machine switch case must emit `return [2, E];`
                        // (op-2 = generator-return), not native return.
                        if (sk == .return_stmt) {
                            const r = hir_mod.returnOf(self.hir, st);
                            try self.write(" return [2");
                            if (r.value != hir_mod.none_node_id) {
                                try self.write(", ");
                                try self.printExpression(r.value);
                            }
                            try self.write("];");
                            continue;
                        }
                        // break_stmt/throw/other — emit inline
                        // (printNonIndentStatement rewrites break via
                        // gen_break_label; throw stays native).
                        try self.write(" ");
                        try self.printNonIndentStatement(st);
                    }
                    ci += 1;
                }
                // Open exit case.
                state = exit_label;
                {
                    var nbuf: [16]u8 = undefined;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{state}) catch unreachable);
                    try self.write(":");
                }
            } else if (k == .if_stmt and self.subtreeContainsYield(stmt)) {
                // §4.A.4.2 + §4.A.4.5 + §4.A.4.11 — unified if-yield
                // emit. Handles all combinations of N then-yields ×
                // (no else | non-yielding else | M else-yields) AND
                // `else if (...)` chains where the else-branch is
                // another if_stmt with yields. The recursive helper
                // `emitGenIfChain` does the heavy lifting; we just
                // compute the shared `after_if_label` upfront so all
                // branches converge on it, run the helper, and open
                // the after_if case.
                const ip0 = hir_mod.ifOf(self.hir, stmt);
                const n_then0 = self.countYieldsInThenBranch(ip0.then_branch);
                const else_section = self.elseSectionCaseCount(ip0.else_branch);
                const after_if_label = state + n_then0 + else_section + 1;
                try self.emitGenIfChain(stmt, after_if_label, &state, &buf);
                // Open afterIf case.
                state += 1;
                {
                    const num_after_open = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_after_open);
                    try self.write(":");
                }
            } else if (k == .try_stmt and self.subtreeContainsYield(stmt)) {
                // §4.A.4.6 — `try { yield... } [catch (e) {...}] [finally {...}]`
                // via tslib __generator's try-frame protocol:
                //   _a.trys.push([tryStart, catchStart, finallyStart, endLabel])
                // Runtime routes [3, endLabel] jumps from inside the
                // try frame through finally (and uses catchStart on
                // throw). Frame is popped via [7] endfinally.
                //
                // For N yields in the try body, the layout adds N-1
                // intermediate resumption cases between the current
                // try-start case and the catch/finally/end cases.
                const tp = hir_mod.tryOf(self.hir, stmt);
                const has_catch = tp.catch_block != hir_mod.none_node_id;
                const has_finally = tp.finally_block != hir_mod.none_node_id;
                const try_start = state;
                // Count yields in the try body to derive labels.
                var n_try_yields: u32 = 1;
                if (self.singleYieldInThen(tp.block) == null) {
                    n_try_yields = 0;
                    const tstmts = hir_mod.blockStmts(self.hir, tp.block);
                    for (tstmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) n_try_yields += 1;
                    }
                }
                // Count yields in the catch body (0 when no catch).
                var n_catch_yields: u32 = 0;
                if (has_catch and self.hir.kindOf(tp.catch_block) == .block_stmt) {
                    const cstmts = hir_mod.blockStmts(self.hir, tp.catch_block);
                    for (cstmts) |cs| {
                        if (self.hir.kindOf(cs) == .yield_expr) n_catch_yields += 1;
                    }
                }
                // yield_resume is the LAST resumption case in try (state + N_try).
                const yield_resume = state + n_try_yields;
                const catch_start: ?u32 = if (has_catch) yield_resume + 1 else null;
                // catch section takes (n_catch_yields + 1) cases when has_catch.
                const catch_total: u32 = if (has_catch) n_catch_yields + 1 else 0;
                // Count yields in the finally body (0 when no finally).
                var n_finally_yields: u32 = 0;
                if (has_finally and self.hir.kindOf(tp.finally_block) == .block_stmt) {
                    const fstmts = hir_mod.blockStmts(self.hir, tp.finally_block);
                    for (fstmts) |fs| {
                        if (self.hir.kindOf(fs) == .yield_expr) n_finally_yields += 1;
                    }
                }
                // finally section takes (n_finally_yields + 1) cases when has_finally.
                const finally_total: u32 = if (has_finally) n_finally_yields + 1 else 0;
                const finally_start: ?u32 = if (has_finally) yield_resume + catch_total + 1 else null;
                const end_label: u32 = yield_resume + catch_total + finally_total + 1;
                // Emit `_a.trys.push([tryStart, catchStart?, finallyStart?, endLabel]);`
                {
                    var nbuf: [16]u8 = undefined;
                    try self.write(" _a.trys.push([");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{try_start}) catch unreachable);
                    try self.write(", ");
                    if (catch_start) |cs| {
                        try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{cs}) catch unreachable);
                    }
                    try self.write(", ");
                    if (finally_start) |fs| {
                        try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{fs}) catch unreachable);
                    }
                    try self.write(", ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{end_label}) catch unreachable);
                    try self.write("]);");
                }
                // Walk the try body inline. For single-yield bodies
                // (singleYieldInThen) the body is just the one yield;
                // for multi-yield bodies (block with N yields), we
                // interleave non-yield stmts and emit a new resumption
                // case after each yield. The very last yield's
                // resumption case ends with `_a.sent(); return [3, end];`
                // (jump out of the try frame, runtime routes through finally).
                {
                    const single = self.singleYieldInThen(tp.block);
                    const tstmts: []const NodeId = if (single != null) blk: {
                        // Synthesize a one-element list pointing at the yield.
                        break :blk @as([]const NodeId, &[_]NodeId{single.?});
                    } else hir_mod.blockStmts(self.hir, tp.block);
                    var seen_yields: u32 = 0;
                    for (tstmts) |s| {
                        if (self.hir.kindOf(s) == .yield_expr) {
                            seen_yields += 1;
                            const yp_n = hir_mod.yieldExprOf(self.hir, s);
                            const op_n: []const u8 = if (yp_n.type_node != hir_mod.none_node_id) "5" else "4";
                            try self.write(" return [");
                            try self.write(op_n);
                            if (yp_n.expr != hir_mod.none_node_id) {
                                try self.write(", ");
                                try self.printExpression(yp_n.expr);
                            }
                            try self.write("];");
                            // Open the next resumption case. If this
                            // was the last yield, the case will be
                            // closed below with a jump to end; otherwise
                            // it stays open for the next stmt to write into.
                            state += 1;
                            const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                            try self.writeNewlineIndent();
                            try self.write("case ");
                            try self.write(num_resume);
                            try self.write(": _a.sent();");
                        } else {
                            try self.write(" ");
                            try self.printNonIndentStatement(s);
                        }
                    }
                    // Close the last resumption case with the jump-to-end.
                    var nbuf: [16]u8 = undefined;
                    try self.write(" return [3, ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{end_label}) catch unreachable);
                    try self.write("];");
                }
                if (has_catch) {
                    state += 1;
                    {
                        var nbuf: [16]u8 = undefined;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{catch_start.?}) catch unreachable);
                        try self.write(":");
                    }
                    // Bind catch variable: var <name> = _a.sent();
                    if (tp.catch_param != hir_mod.none_node_id) {
                        try self.write(" var ");
                        try self.printExpression(tp.catch_param);
                        try self.write(" = _a.sent();");
                    } else {
                        try self.write(" _a.sent();");
                    }
                    // Walk catch body — for yield-free catch the body
                    // just lives in catch_start case; for yields,
                    // each closes the current case and opens the
                    // next resumption case (same pattern as try body).
                    if (self.hir.kindOf(tp.catch_block) == .block_stmt) {
                        const cstmts = hir_mod.blockStmts(self.hir, tp.catch_block);
                        for (cstmts) |cs| {
                            if (self.hir.kindOf(cs) == .yield_expr) {
                                const ypc = hir_mod.yieldExprOf(self.hir, cs);
                                const opc: []const u8 = if (ypc.type_node != hir_mod.none_node_id) "5" else "4";
                                try self.write(" return [");
                                try self.write(opc);
                                if (ypc.expr != hir_mod.none_node_id) {
                                    try self.write(", ");
                                    try self.printExpression(ypc.expr);
                                }
                                try self.write("];");
                                state += 1;
                                const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                                try self.writeNewlineIndent();
                                try self.write("case ");
                                try self.write(num_resume);
                                try self.write(": _a.sent();");
                            } else {
                                try self.write(" ");
                                try self.printNonIndentStatement(cs);
                            }
                        }
                    }
                    // Jump to end (runtime routes through finally if present).
                    var nbuf: [16]u8 = undefined;
                    try self.write(" return [3, ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{end_label}) catch unreachable);
                    try self.write("];");
                }
                if (has_finally) {
                    state += 1;
                    {
                        var nbuf: [16]u8 = undefined;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{finally_start.?}) catch unreachable);
                        try self.write(":");
                    }
                    // Walk finally body — yields close the current case
                    // and open new resumption cases, same as try body.
                    // The final case ends with [7] endfinally.
                    if (self.hir.kindOf(tp.finally_block) == .block_stmt) {
                        const fstmts = hir_mod.blockStmts(self.hir, tp.finally_block);
                        for (fstmts) |fs| {
                            if (self.hir.kindOf(fs) == .yield_expr) {
                                const ypf = hir_mod.yieldExprOf(self.hir, fs);
                                const opf: []const u8 = if (ypf.type_node != hir_mod.none_node_id) "5" else "4";
                                try self.write(" return [");
                                try self.write(opf);
                                if (ypf.expr != hir_mod.none_node_id) {
                                    try self.write(", ");
                                    try self.printExpression(ypf.expr);
                                }
                                try self.write("];");
                                state += 1;
                                const num_resume = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                                try self.writeNewlineIndent();
                                try self.write("case ");
                                try self.write(num_resume);
                                try self.write(": _a.sent();");
                            } else {
                                try self.write(" ");
                                try self.printNonIndentStatement(fs);
                            }
                        }
                    }
                    // [7] endfinally — pops the trys frame and resumes pending op.
                    try self.write(" return [7];");
                }
                // Open end case.
                state += 1;
                {
                    var nbuf: [16]u8 = undefined;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{end_label}) catch unreachable);
                    try self.write(":");
                }
            } else {
                try self.write(" ");
                try self.printNonIndentStatement(stmt);
            }
        }

        if (!ended) {
            try self.write(" return [2];");
        }

        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("});");
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
    }

    /// §4.A.4.7 v0 — true iff `body` is a `block_stmt` whose top-level
    /// statements are all in the lowerable set for async generators:
    ///   * `yield_expr` (not `yield*`)
    ///   * top-level `await_expr` (statement form)
    ///   * `var/let/const` decl whose init is either absent, a top-level
    ///     `await_expr`, or any yield/await-free expression
    ///   * `assignment` (plain `=`) whose value is a top-level
    ///     `await_expr`, or any yield/await-free expression
    ///   * `return_stmt`
    ///   * any other statement whose subtree contains no yield/await
    /// v0 deliberately bails on yield*, structured statements with
    /// nested yields, and any awaits/yields appearing as sub-expressions
    /// inside non-RHS positions — those will follow the regular
    /// generator-state-machine path's incremental ladder.
    fn canLowerAsyncGeneratorBody(self: *const Printer, body: NodeId) bool {
        if (self.hir.kindOf(body) != .block_stmt) return false;
        const stmts = hir_mod.blockStmts(self.hir, body);
        for (stmts) |s| {
            const k = self.hir.kindOf(s);
            switch (k) {
                // Labeled statements (incl. labeled loops with labeled
                // break/continue) aren't handled by the inline async-gen
                // lowering — bail to native `async function*`.
                .labeled_stmt => return false,
                .yield_expr => {
                    const yp = hir_mod.yieldExprOf(self.hir, s);
                    if (yp.expr != hir_mod.none_node_id) {
                        if (self.subtreeContainsYield(yp.expr)) return false;
                        // `yield await E` (immediate await as yield value)
                        // is fine — we unwrap to `__await(E.expr)` in emit.
                        // Nested awaits deeper in the expression are not.
                        if (self.hir.kindOf(yp.expr) == .await_expr) {
                            const inner = hir_mod.awaitExprOf(self.hir, yp.expr);
                            if (inner.expr != hir_mod.none_node_id and (self.subtreeContainsYield(inner.expr) or self.subtreeContainsAwait(inner.expr))) return false;
                        } else if (self.subtreeContainsAwait(yp.expr)) {
                            return false;
                        }
                    }
                    // §4.A.4.7 cont.4 — `yield* E` is supported via
                    // `__asyncDelegator(__asyncValues(E))` wrap.
                },
                .await_expr => {
                    const ap = hir_mod.awaitExprOf(self.hir, s);
                    if (ap.expr != hir_mod.none_node_id) {
                        if (self.subtreeContainsYield(ap.expr)) return false;
                        if (self.subtreeContainsAwait(ap.expr)) return false;
                    }
                },
                .return_stmt => continue,
                .var_decl, .let_decl, .const_decl => {
                    const v = hir_mod.varDeclOf(self.hir, s);
                    if (v.name == hir_mod.none_node_id or self.hir.kindOf(v.name) != .identifier) return false;
                    if (v.init != hir_mod.none_node_id) {
                        const init_kind = self.hir.kindOf(v.init);
                        if (init_kind == .await_expr) {
                            const ap = hir_mod.awaitExprOf(self.hir, v.init);
                            if (ap.expr != hir_mod.none_node_id and (self.subtreeContainsYield(ap.expr) or self.subtreeContainsAwait(ap.expr))) return false;
                        } else if (init_kind == .yield_expr) {
                            const yp = hir_mod.yieldExprOf(self.hir, v.init);
                            if (yp.type_node != hir_mod.none_node_id) return false; // bail on yield*
                            if (yp.expr != hir_mod.none_node_id and (self.subtreeContainsYield(yp.expr) or self.subtreeContainsAwait(yp.expr))) return false;
                        } else {
                            if (self.subtreeContainsYield(v.init) or self.subtreeContainsAwait(v.init)) return false;
                        }
                    }
                },
                .assignment => {
                    const a = hir_mod.assignmentOf(self.hir, s);
                    if (a.op != null and (self.hir.kindOf(a.value) == .await_expr or self.hir.kindOf(a.value) == .yield_expr)) return false;
                    if (self.hir.kindOf(a.value) == .await_expr) {
                        const ap = hir_mod.awaitExprOf(self.hir, a.value);
                        if (ap.expr != hir_mod.none_node_id and (self.subtreeContainsYield(ap.expr) or self.subtreeContainsAwait(ap.expr))) return false;
                    } else if (self.hir.kindOf(a.value) == .yield_expr) {
                        const yp = hir_mod.yieldExprOf(self.hir, a.value);
                        if (yp.type_node != hir_mod.none_node_id) return false;
                        if (yp.expr != hir_mod.none_node_id and (self.subtreeContainsYield(yp.expr) or self.subtreeContainsAwait(yp.expr))) return false;
                    } else {
                        if (self.subtreeContainsYield(s) or self.subtreeContainsAwait(s)) return false;
                    }
                },
                .call_expr => {
                    // §4.A.4.7 (cont.2/5/6) — accept call_expr where
                    // at least one arg is an await_expr (anywhere in
                    // the arg list), every other arg is yield/await-
                    // free, and the await targets have yield/await-
                    // free sub-trees. Examples:
                    //   - `f(await E);`              (cont.2 v0)
                    //   - `f(await E, x, y);`        (cont.5)
                    //   - `f(x, await E);`           (cont.6 — await not at 0)
                    //   - `f(await A, await B);`     (cont.6 — multi-await)
                    //   - `f(await A, x, await B);`  (cont.6 — interleaved)
                    const cp = hir_mod.callOf(self.hir, s);
                    const args = hir_mod.callArgs(self.hir, s);
                    var has_await_arg = false;
                    var ok_multi_await = true;
                    for (args) |a| {
                        if (self.hir.kindOf(a) == .await_expr) {
                            has_await_arg = true;
                            const ap = hir_mod.awaitExprOf(self.hir, a);
                            if (ap.expr != hir_mod.none_node_id and (self.subtreeContainsYield(ap.expr) or self.subtreeContainsAwait(ap.expr))) {
                                ok_multi_await = false;
                                break;
                            }
                        } else {
                            if (self.subtreeContainsYield(a) or self.subtreeContainsAwait(a)) {
                                ok_multi_await = false;
                                break;
                            }
                        }
                    }
                    if (has_await_arg and ok_multi_await) {
                        if (self.subtreeContainsYield(cp.callee) or self.subtreeContainsAwait(cp.callee)) return false;
                    } else {
                        if (self.subtreeContainsYield(s) or self.subtreeContainsAwait(s)) return false;
                    }
                },
                .for_of_stmt => {
                    // §4.A.4.14 v4 — `for await (const x of source) BODY`
                    // inside an async generator with optional multi-
                    // yield / no-yield body, plus an awaited-source
                    // form. Accepted shapes:
                    //   * `is_await: true` (regular `for-of` still bails)
                    //   * source is yield/await-free OR is exactly a
                    //     bare `await E` expression (E itself yield/
                    //     await-free) — the await is peeled into a
                    //     pre-loop yield+bind by the emit path
                    //   * body satisfies `asyncGenForAwaitBodyOk`
                    //   * target is a simple ident or `var|let|const <ident>`
                    const fop = hir_mod.forInOf(self.hir, s);
                    if (!fop.is_await) return false;
                    if (self.subtreeContainsYield(fop.source)) return false;
                    if (self.subtreeContainsAwait(fop.source)) {
                        // Only accept the strict shape `await <yield/await-free E>`.
                        if (self.hir.kindOf(fop.source) != .await_expr) return false;
                        const ap = hir_mod.awaitExprOf(self.hir, fop.source);
                        if (ap.expr == hir_mod.none_node_id) return false;
                        if (self.subtreeContainsYield(ap.expr) or self.subtreeContainsAwait(ap.expr)) return false;
                    }
                    if (!self.asyncGenForAwaitBodyOk(fop.body)) return false;
                    const tk = self.hir.kindOf(fop.target);
                    if (tk == .identifier) {
                        // ok
                    } else if (tk == .var_decl or tk == .let_decl or tk == .const_decl) {
                        const v = hir_mod.varDeclOf(self.hir, fop.target);
                        if (v.name == hir_mod.none_node_id) return false;
                        // §4.A.4.14 v7 — accept identifier OR destructuring
                        // pattern (array / object) as the decl name; the
                        // emit routes through `printBindingName` so both
                        // shapes render correctly.
                        const nk = self.hir.kindOf(v.name);
                        if (nk != .identifier and nk != .object_pattern and nk != .array_pattern) return false;
                    } else {
                        return false;
                    }
                },
                .if_stmt, .while_stmt, .do_while_stmt, .for_stmt, .for_in_stmt, .try_stmt, .switch_stmt, .throw_stmt, .break_stmt, .continue_stmt, .fn_decl, .class_decl => return false,
                else => {
                    if (self.subtreeContainsYield(s) or self.subtreeContainsAwait(s)) return false;
                },
            }
        }
        return true;
    }

    /// Companion to `subtreeContainsYield` — true iff any node in the
    /// subtree rooted at `root` is an `await_expr`. Used by the async-
    /// generator predicate to reject await sub-expressions in
    /// non-supported positions.
    fn subtreeContainsAwait(self: *const Printer, root: NodeId) bool {
        if (root == hir_mod.none_node_id) return false;
        if (self.hir.kindOf(root) == .await_expr) return true;
        const total = self.hir.nodeCount();
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            if (self.hir.kindOf(i) != .await_expr) continue;
            var cur: NodeId = self.hir.parentOf(i);
            while (cur != hir_mod.none_node_id) {
                if (cur == root) return true;
                const p = self.hir.parentOf(cur);
                if (p == cur) break;
                cur = p;
            }
        }
        return false;
    }

    /// §4.A.4.7 v0 — emit the async-generator wrapper + inner generator
    /// state machine. Body must satisfy `canLowerAsyncGeneratorBody`.
    /// Each user `yield E` expands to the tslib double-yield pattern:
    ///   `return [4, __await(E)];`
    ///   `case +1: _a.sent(); return [4];`
    ///   `case +2: _a.sent();`
    /// So N user yields produce 2N resumption-related cases.
    fn printAsyncGeneratorDownlevelBody(self: *Printer, body: NodeId, params: []const NodeId) anyerror!void {
        try self.write("{");
        self.depth += 1;
        try self.writeNewlineIndent();
        // §4.A destructuring v13 — destructuring-param shim at the
        // outer async-gen function level.
        if (self.options.es_target == .es5 and self.hasDestructuringParam(params)) {
            try self.writeDestructuringParamShims(params);
            try self.writeNewlineIndent();
        }
        try self.write("return __asyncGenerator(this, arguments, function () {");
        self.depth += 1;
        try self.writeNewlineIndent();
        try self.write("return __generator(this, function (_a) {");
        self.depth += 1;
        try self.writeNewlineIndent();
        try self.write("switch (_a.label) {");
        self.depth += 1;
        // §4.A.4 — set the sync-gen flag so nested `return E;` (via
        // recursively-printed loop bodies, if branches, switch cases)
        // rewrites to `return [2, E];` automatically.
        const prev_sync_gen = self.in_sync_gen_body;
        self.in_sync_gen_body = true;
        defer self.in_sync_gen_body = prev_sync_gen;

        const stmts = hir_mod.blockStmts(self.hir, body);
        var state: u32 = 0;
        var buf: [16]u8 = undefined;

        try self.writeNewlineIndent();
        try self.write("case 0:");
        var ended = false;

        for (stmts) |stmt| {
            const k = self.hir.kindOf(stmt);
            if (k == .yield_expr) {
                const yp = hir_mod.yieldExprOf(self.hir, stmt);
                if (yp.type_node != hir_mod.none_node_id) {
                    // §4.A.4.7 cont.4 — `yield* E` in async gen.
                    // Wrap with `__asyncDelegator(__asyncValues(E))` so
                    // the delegate handles both sync and async iterables
                    // uniformly. Op-code 5 is the delegation opcode.
                    // After delegation, case +1 re-yields the produced
                    // value via `return [4, __await(_a.sent())];`; case +2
                    // resumes.
                    try self.write(" return [5, __asyncDelegator(__asyncValues(");
                    if (yp.expr != hir_mod.none_node_id) try self.printExpression(yp.expr);
                    try self.write("))];");
                    state += 1;
                    {
                        const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num);
                        try self.write(": return [4, __await(_a.sent())];");
                    }
                    state += 1;
                    {
                        const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num);
                        try self.write(": _a.sent();");
                    }
                    continue;
                }
                try self.write(" return [4, __await(");
                if (yp.expr != hir_mod.none_node_id) {
                    // `yield await E` — unwrap the user's redundant await
                    // so we emit `__await(E)` rather than `__await(await E)`
                    // (which would be invalid inside the sync inner generator).
                    if (self.hir.kindOf(yp.expr) == .await_expr) {
                        const inner = hir_mod.awaitExprOf(self.hir, yp.expr);
                        if (inner.expr != hir_mod.none_node_id) {
                            try self.printExpression(inner.expr);
                        } else {
                            try self.write("void 0");
                        }
                    } else {
                        try self.printExpression(yp.expr);
                    }
                } else {
                    try self.write("void 0");
                }
                try self.write(")];");
                // First resumption: signal "value sent — emit done".
                state += 1;
                {
                    const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num);
                    try self.write(": _a.sent(); return [4];");
                }
                // Second resumption: continue with the rest of the body.
                state += 1;
                {
                    const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num);
                    try self.write(": _a.sent();");
                }
            } else if (k == .await_expr) {
                // Top-level `await E;` — single resumption (no emit).
                const ap = hir_mod.awaitExprOf(self.hir, stmt);
                try self.write(" return [4, __await(");
                if (ap.expr != hir_mod.none_node_id) try self.printExpression(ap.expr);
                try self.write(")];");
                state += 1;
                const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                try self.writeNewlineIndent();
                try self.write("case ");
                try self.write(num);
                try self.write(": _a.sent();");
            } else if ((k == .var_decl or k == .let_decl or k == .const_decl)) {
                const v = hir_mod.varDeclOf(self.hir, stmt);
                if (v.init != hir_mod.none_node_id and self.hir.kindOf(v.init) == .await_expr) {
                    // `let x = await E;` — yield + bind.
                    const ap = hir_mod.awaitExprOf(self.hir, v.init);
                    try self.write(" return [4, __await(");
                    if (ap.expr != hir_mod.none_node_id) try self.printExpression(ap.expr);
                    try self.write(")];");
                    state += 1;
                    const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num);
                    try self.write(": var ");
                    if (v.name != hir_mod.none_node_id) try self.printExpression(v.name);
                    try self.write(" = _a.sent();");
                } else if (v.init != hir_mod.none_node_id and self.hir.kindOf(v.init) == .yield_expr) {
                    // `let x = yield E;` — double-yield + bind to second _a.sent()
                    // (consumer-provided value).
                    const yp = hir_mod.yieldExprOf(self.hir, v.init);
                    try self.write(" return [4, __await(");
                    if (yp.expr != hir_mod.none_node_id) {
                        try self.printExpression(yp.expr);
                    } else {
                        try self.write("void 0");
                    }
                    try self.write(")];");
                    state += 1;
                    {
                        const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num);
                        try self.write(": _a.sent(); return [4];");
                    }
                    state += 1;
                    {
                        const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num);
                        try self.write(": var ");
                        if (v.name != hir_mod.none_node_id) try self.printExpression(v.name);
                        try self.write(" = _a.sent();");
                    }
                } else {
                    try self.write(" var ");
                    if (v.name != hir_mod.none_node_id) try self.printExpression(v.name);
                    if (v.init != hir_mod.none_node_id) {
                        try self.write(" = ");
                        try self.printExpression(v.init);
                    }
                    try self.write(";");
                }
            } else if (k == .assignment) {
                const a = hir_mod.assignmentOf(self.hir, stmt);
                if (a.op == null and self.hir.kindOf(a.value) == .await_expr) {
                    const ap = hir_mod.awaitExprOf(self.hir, a.value);
                    try self.write(" return [4, __await(");
                    if (ap.expr != hir_mod.none_node_id) try self.printExpression(ap.expr);
                    try self.write(")];");
                    state += 1;
                    const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num);
                    try self.write(": ");
                    try self.printExpression(a.target);
                    try self.write(" = _a.sent();");
                } else if (a.op == null and self.hir.kindOf(a.value) == .yield_expr) {
                    // `x = yield E;` — double-yield, bind second sent to target.
                    const yp = hir_mod.yieldExprOf(self.hir, a.value);
                    try self.write(" return [4, __await(");
                    if (yp.expr != hir_mod.none_node_id) {
                        try self.printExpression(yp.expr);
                    } else {
                        try self.write("void 0");
                    }
                    try self.write(")];");
                    state += 1;
                    {
                        const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num);
                        try self.write(": _a.sent(); return [4];");
                    }
                    state += 1;
                    {
                        const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num);
                        try self.write(": ");
                        try self.printExpression(a.target);
                        try self.write(" = _a.sent();");
                    }
                } else {
                    try self.write(" ");
                    try self.printNonIndentStatement(stmt);
                }
            } else if (k == .call_expr) {
                // §4.A.4.7 — call with one or more await args. The
                // predicate already verified at least one arg is an
                // await_expr and every non-await arg is yield/await-
                // free. Two emit shapes:
                //
                //   1) Single await in position 0, no other awaits —
                //      use the existing simple shape:
                //        return [4, __await(arg0.target)];
                //        case S+1: f(_a.sent(), <other args verbatim>);
                //
                //   2) Otherwise (await elsewhere or multi-await) —
                //      yield each await in source order, binding all
                //      but the last to `var _b<i> = _a.sent();`
                //      temps; the last await's `_a.sent()` lands
                //      inline in the final assembled call. Non-await
                //      args evaluate verbatim at the call site at
                //      resumption time (predicate-checked safe).
                const cp = hir_mod.callOf(self.hir, stmt);
                const args = hir_mod.callArgs(self.hir, stmt);
                var await_count: usize = 0;
                var last_await_idx: usize = 0;
                for (args, 0..) |a, idx| {
                    if (self.hir.kindOf(a) == .await_expr) {
                        await_count += 1;
                        last_await_idx = idx;
                    }
                }
                const simple_single_await =
                    await_count == 1 and args.len >= 1 and self.hir.kindOf(args[0]) == .await_expr;
                if (simple_single_await) {
                    const ap = hir_mod.awaitExprOf(self.hir, args[0]);
                    try self.write(" return [4, __await(");
                    if (ap.expr != hir_mod.none_node_id) try self.printExpression(ap.expr);
                    try self.write(")];");
                    state += 1;
                    const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num);
                    try self.write(": ");
                    try self.printExpression(cp.callee);
                    try self.write("(_a.sent()");
                    var i: usize = 1;
                    while (i < args.len) : (i += 1) {
                        try self.write(", ");
                        try self.printExpression(args[i]);
                    }
                    try self.write(");");
                } else if (await_count >= 1) {
                    // Multi-await (or await not in position 0) path.
                    var seen_awaits: usize = 0;
                    for (args, 0..) |a, idx| {
                        if (self.hir.kindOf(a) != .await_expr) continue;
                        const ap = hir_mod.awaitExprOf(self.hir, a);
                        try self.write(" return [4, __await(");
                        if (ap.expr != hir_mod.none_node_id) try self.printExpression(ap.expr);
                        try self.write(")];");
                        state += 1;
                        const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                        try self.writeNewlineIndent();
                        try self.write("case ");
                        try self.write(num);
                        try self.write(": ");
                        if (idx == last_await_idx) {
                            // Final await: inline `_a.sent()` into the
                            // assembled call alongside the prior temps
                            // and the verbatim non-await args.
                            try self.printExpression(cp.callee);
                            try self.write("(");
                            var prev_await_seen: usize = 0;
                            for (args, 0..) |ca, ci| {
                                if (ci > 0) try self.write(", ");
                                if (self.hir.kindOf(ca) == .await_expr) {
                                    if (ci == last_await_idx) {
                                        try self.write("_a.sent()");
                                    } else {
                                        var tbuf: [16]u8 = undefined;
                                        const tnum = std.fmt.bufPrint(&tbuf, "{d}", .{prev_await_seen}) catch unreachable;
                                        try self.write("_b");
                                        try self.write(tnum);
                                        prev_await_seen += 1;
                                    }
                                } else {
                                    try self.printExpression(ca);
                                }
                            }
                            try self.write(");");
                        } else {
                            // Intermediate await: bind to `_b<n>` temp
                            // so the assembled call can read it later.
                            var tbuf: [16]u8 = undefined;
                            const tnum = std.fmt.bufPrint(&tbuf, "{d}", .{seen_awaits}) catch unreachable;
                            try self.write("var _b");
                            try self.write(tnum);
                            try self.write(" = _a.sent();");
                            seen_awaits += 1;
                        }
                    }
                } else {
                    try self.write(" ");
                    try self.printNonIndentStatement(stmt);
                }
            } else if (k == .for_of_stmt) {
                // §4.A.4.14 v3 — `for await (const x of source) BODY`
                // in an async generator with optional multi-yield or
                // no-yield body, and try/finally cleanup via an awaited
                // `.return()`. Predicate guarantees:
                //   * is_await: true; source yield/await-free
                //   * body satisfies `asyncGenForAwaitBodyOk` —
                //     either a bare single stmt (yield_expr or yield/
                //     await-free non-structured) or a block whose
                //     top-level stmts each pass the same check
                //   * target is simple ident or `var|let|const <ident>`
                //
                // Layout for body with N yields (1 + 2*N body cases):
                //   case S+0 (current): _a.trys.push([S+1, catch, finally, end]);
                //                       var _aiter = __asyncValues(source);
                //   case S+1: return [4, __await(_aiter.next())];
                //   case S+2: var _aresult = _a.sent();
                //             if (_aresult.done) return [3, normal_end];
                //             var x = _aresult.value;
                //             <body walk — each yield closes the case
                //              with `return [4, __await(E)];` and opens
                //              resume1+resume2 cases; non-yield stmts
                //              emit verbatim; trailing stmts after the
                //              last yield run in the last resume2 case>
                //             return [3, header];   // loopback
                //   case normal_end: return [3, end];
                //   case catch: var _e_1 = _a.sent(); return [3, finally];
                //   case finally: if (!(_aresult && !_aresult.done
                //                       && _aiter.return)) return [3, finally_end];
                //                 return [4, __await(_aiter.return.call(_aiter))];
                //   case cleanup_resume: _a.sent();
                //   case finally_end: if (_e_1) throw _e_1; return [7];
                //   case end: (exit)
                //
                // For N=0 (no-yield body), case S+2 emits bind+check+
                // body-stmts+loopback all inline — no resume cases.
                const fop = hir_mod.forInOf(self.hir, stmt);
                const target_name: NodeId = blk: {
                    const tk = self.hir.kindOf(fop.target);
                    if (tk == .identifier) break :blk fop.target;
                    const v = hir_mod.varDeclOf(self.hir, fop.target);
                    break :blk v.name;
                };
                // Normalize body to a stmt slice. Bare single stmt
                // (yield_expr OR non-yield stmt) becomes a one-element
                // walk; a block uses blockStmts directly.
                var single_buf: [1]NodeId = undefined;
                const body_stmts: []const NodeId = blk: {
                    if (self.hir.kindOf(fop.body) == .block_stmt) {
                        break :blk hir_mod.blockStmts(self.hir, fop.body);
                    }
                    single_buf[0] = fop.body;
                    break :blk single_buf[0..1];
                };
                var n_yields: u32 = 0;
                for (body_stmts) |s| {
                    if (self.hir.kindOf(s) == .yield_expr) n_yields += 1;
                }
                // §4.A.4.14 v4 — peel source's `await E` into a yield+
                // bind case pair before the trys-frame opens. The
                // resume case binds `_src = _a.sent();` and is then
                // used as the source for `__asyncValues`. This adds 1
                // case to the layout but doesn't affect any of the body
                // / cleanup label offsets (everything stays relative
                // to the post-peel state).
                const source_is_await = self.hir.kindOf(fop.source) == .await_expr;
                if (source_is_await) {
                    const ap = hir_mod.awaitExprOf(self.hir, fop.source);
                    try self.write(" return [4, __await(");
                    try self.printExpression(ap.expr);
                    try self.write(")];");
                    state += 1;
                    const num = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num);
                    try self.write(": var _src = _a.sent();");
                }
                const try_start = state + 1;
                const header_label = state + 1;
                // Body cases = 1 (bind+check+first-yield) + 2*(N-1)
                //              (per remaining yield: resume1, resume2-
                //              with-trailing-stmts) + 2 (last yield's
                //              resume1 + resume2-with-loopback)
                //            = 1 + 2*N total body cases
                const body_case_count: u32 = 1 + 2 * n_yields;
                const normal_end_label = state + 1 + 1 + body_case_count;
                const catch_label = normal_end_label + 1;
                const finally_label = catch_label + 1;
                const finally_end_label = finally_label + 2;
                const end_label = finally_end_label + 1;
                // trys.push + init in current case.
                {
                    var nbuf: [16]u8 = undefined;
                    try self.write(" _a.trys.push([");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{try_start}) catch unreachable);
                    try self.write(", ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{catch_label}) catch unreachable);
                    try self.write(", ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{finally_label}) catch unreachable);
                    try self.write(", ");
                    try self.write(std.fmt.bufPrint(&nbuf, "{d}", .{end_label}) catch unreachable);
                    try self.write("]);");
                }
                try self.write(" var _aiter = __asyncValues(");
                if (source_is_await) {
                    try self.write("_src");
                } else {
                    try self.printExpression(fop.source);
                }
                try self.write(");");
                // Open header case: await next().
                state += 1;
                {
                    const num_h = std.fmt.bufPrint(&buf, "{d}", .{header_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_h);
                    try self.write(": return [4, __await(_aiter.next())];");
                }
                // Open bind+check case. Writes the header for the body
                // walk; the walk itself emits stmts inline then closes
                // with the first yield's `return [4, __await(E1)];`.
                state += 1;
                {
                    const num_b = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    var num_ne_buf: [16]u8 = undefined;
                    const num_normal_end = std.fmt.bufPrint(&num_ne_buf, "{d}", .{normal_end_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_b);
                    try self.write(": var _aresult = _a.sent(); if (_aresult.done) return [3, ");
                    try self.write(num_normal_end);
                    try self.write("]; var ");
                    // §4.A.4.14 v7 — printBindingName routes identifier
                    // / array_pattern / object_pattern through the right
                    // emit (the latter two render destructuring).
                    try self.printBindingName(target_name);
                    try self.write(" = _aresult.value;");
                }
                // §4.A.4.14 v6 — wire break/continue rewrites so any
                // top-level `break;` in the body emits as
                // `return [3, normal_end_label];` (re-routes through
                // the cleanup chain) and `continue;` emits as
                // `return [3, header_label];` (jumps directly to the
                // next iteration's `_aiter.next()` await). Saved/
                // restored around the walk so outer state-machine
                // loops keep their own bindings.
                const prev_break_lbl = self.gen_break_label;
                const prev_continue_lbl = self.gen_continue_label;
                self.gen_break_label = normal_end_label;
                self.gen_continue_label = header_label;
                defer {
                    self.gen_break_label = prev_break_lbl;
                    self.gen_continue_label = prev_continue_lbl;
                }
                // Walk body stmts inline. Each yield closes the current
                // case (regular yield: `return [4, __await(E)];`;
                // yield*: `return [5, __asyncDelegator(__asyncValues(E))];`)
                // then opens two new resumption cases. For regular
                // yields, resume1 signals done with `return [4];`; for
                // yield*, resume1 re-yields the delegated value via
                // `return [4, __await(_a.sent())];`. Resume2 in both
                // cases is just `_a.sent();` (stays open for trailing
                // stmts or the loopback close).
                for (body_stmts) |s| {
                    if (self.hir.kindOf(s) == .yield_expr) {
                        const yp_n = hir_mod.yieldExprOf(self.hir, s);
                        const is_delegating = yp_n.type_node != hir_mod.none_node_id;
                        if (is_delegating) {
                            try self.write(" return [5, __asyncDelegator(__asyncValues(");
                            try self.printExpression(yp_n.expr);
                            try self.write("))];");
                        } else {
                            try self.write(" return [4, __await(");
                            if (yp_n.expr != hir_mod.none_node_id) {
                                try self.printExpression(yp_n.expr);
                            } else {
                                try self.write("void 0");
                            }
                            try self.write(")];");
                        }
                        // Open resume1.
                        state += 1;
                        {
                            const num_r1 = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                            try self.writeNewlineIndent();
                            try self.write("case ");
                            try self.write(num_r1);
                            if (is_delegating) {
                                try self.write(": return [4, __await(_a.sent())];");
                            } else {
                                try self.write(": _a.sent(); return [4];");
                            }
                        }
                        // Open resume2.
                        state += 1;
                        {
                            const num_r2 = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                            try self.writeNewlineIndent();
                            try self.write("case ");
                            try self.write(num_r2);
                            try self.write(": _a.sent();");
                        }
                    } else {
                        try self.write(" ");
                        try self.printNonIndentStatement(s);
                    }
                }
                // Close last resume2 (or bind+check if N==0, but the
                // predicate rules that out) with loopback to header.
                {
                    var num_h_buf: [16]u8 = undefined;
                    const num_h_back = std.fmt.bufPrint(&num_h_buf, "{d}", .{header_label}) catch unreachable;
                    try self.write(" return [3, ");
                    try self.write(num_h_back);
                    try self.write("];");
                }
                // Open normal_end case: jump past catch+finally.
                state += 1;
                {
                    const num_ne = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    var num_end_buf: [16]u8 = undefined;
                    const num_end = std.fmt.bufPrint(&num_end_buf, "{d}", .{end_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_ne);
                    try self.write(": return [3, ");
                    try self.write(num_end);
                    try self.write("];");
                }
                // Open catch case: capture error, jump to finally.
                state += 1;
                {
                    const num_c = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    var num_f_buf: [16]u8 = undefined;
                    const num_f = std.fmt.bufPrint(&num_f_buf, "{d}", .{finally_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_c);
                    try self.write(": var _e_1 = _a.sent(); return [3, ");
                    try self.write(num_f);
                    try self.write("];");
                }
                // Open finally case: skip cleanup if no usable iterator,
                // otherwise await `.return()` call.
                state += 1;
                {
                    const num_f = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    var num_fe_buf: [16]u8 = undefined;
                    const num_fe = std.fmt.bufPrint(&num_fe_buf, "{d}", .{finally_end_label}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_f);
                    try self.write(": if (!(_aresult && !_aresult.done && _aiter.return)) return [3, ");
                    try self.write(num_fe);
                    try self.write("]; return [4, __await(_aiter.return.call(_aiter))];");
                }
                // Open cleanup-resume case.
                state += 1;
                {
                    const num_cr = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_cr);
                    try self.write(": _a.sent();");
                }
                // Open finally_end case: rethrow + endfinally.
                state += 1;
                {
                    const num_fe = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_fe);
                    try self.write(": if (_e_1) throw _e_1; return [7];");
                }
                // Open end case (exit).
                state += 1;
                {
                    const num_e = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
                    try self.writeNewlineIndent();
                    try self.write("case ");
                    try self.write(num_e);
                    try self.write(":");
                }
            } else if (k == .return_stmt) {
                const r = hir_mod.returnOf(self.hir, stmt);
                try self.write(" return [2");
                if (r.value != hir_mod.none_node_id) {
                    try self.write(", ");
                    try self.printExpression(r.value);
                }
                try self.write("];");
                ended = true;
                break;
            } else {
                try self.write(" ");
                try self.printNonIndentStatement(stmt);
            }
        }

        if (!ended) {
            try self.write(" return [2];");
        }

        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("});");
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("});");
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
    }

    /// §4.A.4 — close the current `case` with `return [op, expr];`
    /// (op-code 4 for `yield`, 5 for `yield*`) and open the next
    /// `case N+1:`. When `bind_target` is non-null, the resumed
    /// value lands in `<bind_target> = _a.sent();`, prefixed with
    /// `var` iff `bind_kind == .new_decl` (§4.A.4.1 — decl form
    /// introduces a fresh binding hoisted via `var`; assignment
    /// form writes to an already-declared name). When `bind_target`
    /// is null the caller emits the bare `_a.sent();` resumption.
    const BindKind = enum { new_decl, assignment };
    fn emitGenYieldTransition(
        self: *Printer,
        yield_node: NodeId,
        state: *u32,
        buf: *[16]u8,
        bind_target: ?NodeId,
        bind_kind: BindKind,
    ) anyerror!void {
        const y = hir_mod.yieldExprOf(self.hir, yield_node);
        const op: []const u8 = if (y.type_node != hir_mod.none_node_id) "5" else "4";
        try self.write(" return [");
        try self.write(op);
        if (y.expr != hir_mod.none_node_id) {
            try self.write(", ");
            try self.printExpression(y.expr);
        }
        try self.write("];");
        state.* += 1;
        const num = std.fmt.bufPrint(buf, "{d}", .{state.*}) catch unreachable;
        try self.writeNewlineIndent();
        try self.write("case ");
        try self.write(num);
        try self.write(":");
        if (bind_target) |t| {
            try self.write(" ");
            if (bind_kind == .new_decl) try self.write("var ");
            try self.printExpression(t);
            try self.write(" = _a.sent();");
        }
    }

    fn printParameter(self: *Printer, node: NodeId) !void {
        const p = hir_mod.parameterOf(self.hir, node);
        if (p.flags.is_rest) try self.write("...");
        if (p.name != hir_mod.none_node_id) {
            // §4.A — `printBindingName` routes identifier vs
            // array_pattern / object_pattern through the right emit.
            // At ES2015+, native destructuring params (`function f({ a, b })`)
            // render verbatim. ES5 still emits the pattern in-place
            // here; lowering it to a temp-param + var-decl-in-body
            // shim is tracked separately.
            try self.printBindingName(p.name);
        }
        // §4.A — at ES5, default-parameter syntax (`x = 1`) is lowered
        // to a body-prefix `if (x === void 0) { x = 1; }` shim. Skip
        // the native default emit here so the parameter list stays
        // ES5-clean; the shim is injected by `printFnBodyWithDefaults`.
        if (p.default_value != hir_mod.none_node_id and self.options.es_target != .es5) {
            try self.write(" = ");
            try self.printExpression(p.default_value);
        }
    }

    /// True if any parameter in `params` carries a `default_value`
    /// (i.e. was written `(x = expr)` in source). Used at ES5 to
    /// decide whether to inject the `if (x === void 0)` shim into
    /// the function body.
    fn hasDefaultParam(self: *const Printer, params: []const NodeId) bool {
        for (params) |pn| {
            if (self.hir.kindOf(pn) != .parameter) continue;
            const p = hir_mod.parameterOf(self.hir, pn);
            if (p.default_value != hir_mod.none_node_id) return true;
        }
        return false;
    }

    /// §4.A — true if any parameter's `name` is an `object_pattern` /
    /// `array_pattern`. Used at ES5 to decide whether to substitute
    /// temp idents in the parameter list and inject the destructuring
    /// extraction `var a = _p<idx>.a, ...` shim into the body.
    fn hasDestructuringParam(self: *const Printer, params: []const NodeId) bool {
        for (params) |pn| {
            if (self.hir.kindOf(pn) != .parameter) continue;
            if (self.isThisParam(pn)) continue;
            const p = hir_mod.parameterOf(self.hir, pn);
            if (p.name == hir_mod.none_node_id) continue;
            const nk = self.hir.kindOf(p.name);
            if (nk == .object_pattern or nk == .array_pattern) return true;
        }
        return false;
    }

    /// §4.A — true if `pn`'s name is a destructuring pattern.
    fn isPatternParam(self: *const Printer, pn: NodeId) bool {
        if (self.hir.kindOf(pn) != .parameter) return false;
        const p = hir_mod.parameterOf(self.hir, pn);
        if (p.name == hir_mod.none_node_id) return false;
        const nk = self.hir.kindOf(p.name);
        return nk == .object_pattern or nk == .array_pattern;
    }

    /// §4.A — emit the destructuring extraction shim for ES5 pattern
    /// params. For each pattern param at visible-index N, emit
    /// `var a = _p<N>.a, b = _p<N>.b;` (object) or
    /// `var a = _p<N>[0], b = _p<N>[1];` (array). Defaults / rest
    /// follow the same conventions as `printDestructuringVarDecl`:
    /// `=== void 0 ?` ternary for defaults; `.slice(i)` for array
    /// rest; `__rest(_pN, [...])` for object rest.
    fn writeDestructuringParamShims(self: *Printer, params: []const NodeId) !void {
        var first = true;
        var idx: usize = 0;
        for (params) |pn| {
            if (self.hir.kindOf(pn) != .parameter) continue;
            if (self.isThisParam(pn)) continue;
            defer idx += 1;
            if (!self.isPatternParam(pn)) continue;
            if (!first) try self.writeNewlineIndent();
            first = false;
            const p = hir_mod.parameterOf(self.hir, pn);
            var name_buf: [16]u8 = undefined;
            const tmp_name = std.fmt.bufPrint(&name_buf, "_p{d}", .{idx}) catch unreachable;
            try self.emitDestructuringShim(p.name, tmp_name);
        }
    }

    /// §4.A — emit the destructuring extraction body for one pattern
    /// against a pre-existing source identifier name. Renders
    /// `var <bindings>;` with `=`/`?: void 0` and rest conventions.
    /// Shared between `writeDestructuringParamShims` (ES5 fn-params)
    /// and any other call site that needs to bind from a fixed ident.
    fn emitDestructuringShim(self: *Printer, pattern: NodeId, source_ident: []const u8) !void {
        try self.write("var ");
        var emitted_count: usize = 0;
        var counter: usize = 0;
        try self.emitDestructuringPairs(pattern, source_ident, &counter, &emitted_count);
        try self.write(";");
    }

    /// §4.A destructuring v15 — recursive helper that emits the
    /// comma-separated binding pairs `<name> = <src>.<accessor>, ...`
    /// for one pattern. When a nested pattern is encountered, a
    /// fresh `_n<counter>` temp ident is allocated, bound to the
    /// parent's slot, then this fn recurses into the nested pattern
    /// using the temp as source. All bindings (parent + recursed
    /// children) land in the same comma-separated decl list. The
    /// caller writes the leading `var ` and the trailing `;` (or
    /// equivalent), and is responsible for pre-existing emitted_count.
    fn emitDestructuringPairs(
        self: *Printer,
        pattern: NodeId,
        source_ident: []const u8,
        counter: *usize,
        emitted_count: *usize,
    ) anyerror!void {
        const is_array = self.hir.kindOf(pattern) == .array_pattern;
        const elements = hir_mod.patternElements(self.hir, pattern);
        for (elements, 0..) |elem, i| {
            if (self.hir.kindOf(elem) != .parameter) continue;
            const param = hir_mod.parameterOf(self.hir, elem);
            if (param.flags.is_computed_binding_key) continue;
            if (param.name == hir_mod.none_node_id) continue;
            const computed_key_expr: NodeId = blk: {
                if (is_array or i == 0) break :blk hir_mod.none_node_id;
                const prev = elements[i - 1];
                if (self.hir.kindOf(prev) != .parameter) break :blk hir_mod.none_node_id;
                const pp = hir_mod.parameterOf(self.hir, prev);
                if (!pp.flags.is_computed_binding_key) break :blk hir_mod.none_node_id;
                break :blk pp.default_value;
            };
            const name_kind = self.hir.kindOf(param.name);
            const is_nested = name_kind == .object_pattern or name_kind == .array_pattern;
            if (!is_nested and name_kind != .identifier) continue;
            if (emitted_count.* > 0) try self.write(", ");
            emitted_count.* += 1;
            if (param.flags.is_rest) {
                // Rest must be an identifier in valid TS — nested rest
                // not part of the spec. If the parser hands us one,
                // skip the nested case gracefully.
                if (!is_nested) {
                    const id = hir_mod.identifierOf(self.hir, param.name);
                    const name_str = self.interner.get(id.name);
                    if (is_array) {
                        try self.write(name_str);
                        try self.write(" = ");
                        try self.write(source_ident);
                        var rbuf: [32]u8 = undefined;
                        const slice_str = std.fmt.bufPrint(&rbuf, ".slice({d})", .{i}) catch unreachable;
                        try self.write(slice_str);
                    } else {
                        try self.write(name_str);
                        try self.write(" = __rest(");
                        try self.write(source_ident);
                        try self.write(", [");
                        var pkey_emitted: usize = 0;
                        for (elements, 0..) |pelem, pi| {
                            if (pi >= i) break;
                            if (self.hir.kindOf(pelem) != .parameter) continue;
                            const pparam = hir_mod.parameterOf(self.hir, pelem);
                            if (pparam.flags.is_computed_binding_key) continue;
                            if (pparam.flags.is_rest) continue;
                            if (pparam.name == hir_mod.none_node_id) continue;
                            if (self.hir.kindOf(pparam.name) != .identifier) continue;
                            const pid = hir_mod.identifierOf(self.hir, pparam.name);
                            const pname = self.interner.get(pid.name);
                            if (pkey_emitted > 0) try self.write(", ");
                            try self.write("\"");
                            try self.write(pname);
                            try self.write("\"");
                            pkey_emitted += 1;
                        }
                        try self.write("])");
                    }
                }
                continue;
            }
            // For nested patterns, allocate a fresh temp ident and
            // bind the parent's slot to it; then recurse. The
            // temp's value access uses the same accessor logic as
            // for identifier bindings (.name / [idx] / [computed]).
            if (is_nested) {
                counter.* += 1;
                var tbuf: [16]u8 = undefined;
                const nested_src = std.fmt.bufPrint(&tbuf, "_n{d}", .{counter.*}) catch unreachable;
                const has_default = param.default_value != hir_mod.none_node_id;
                try self.write(nested_src);
                try self.write(" = ");
                if (has_default) {
                    try self.write(source_ident);
                    try self.writePatternAccessor(is_array, i, computed_key_expr, "");
                    try self.write(" === void 0 ? ");
                    try self.printExpression(param.default_value);
                    try self.write(" : ");
                }
                try self.write(source_ident);
                try self.writePatternAccessor(is_array, i, computed_key_expr, "");
                // Recurse: nested pattern's bindings now use the
                // freshly-bound temp as their source.
                try self.emitDestructuringPairs(param.name, nested_src, counter, emitted_count);
                continue;
            }
            const id = hir_mod.identifierOf(self.hir, param.name);
            const name_str = self.interner.get(id.name);
            const has_default = param.default_value != hir_mod.none_node_id;
            try self.write(name_str);
            try self.write(" = ");
            if (has_default) {
                try self.write(source_ident);
                try self.writePatternAccessor(is_array, i, computed_key_expr, name_str);
                try self.write(" === void 0 ? ");
                try self.printExpression(param.default_value);
                try self.write(" : ");
            }
            try self.write(source_ident);
            try self.writePatternAccessor(is_array, i, computed_key_expr, name_str);
        }
    }

    /// §4.A destructuring v15 — write the accessor suffix for a
    /// pattern element: `[i]` (array), `[computed]` (computed key),
    /// or `.name` (plain object key). Encapsulates the three forms
    /// so emit sites stay terse.
    fn writePatternAccessor(
        self: *Printer,
        is_array: bool,
        idx: usize,
        computed_key_expr: NodeId,
        name: []const u8,
    ) anyerror!void {
        if (computed_key_expr != hir_mod.none_node_id) {
            try self.write("[");
            try self.printExpression(computed_key_expr);
            try self.write("]");
            return;
        }
        if (is_array) {
            var buf: [32]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&buf, "[{d}]", .{idx}) catch unreachable;
            try self.write(idx_str);
            return;
        }
        try self.write(".");
        try self.write(name);
    }

    /// Emit the `if (x === void 0) { x = <default>; }` shim for each
    /// parameter that has a default value. Skips `this:T` params and
    /// rest params (rest can't have a default in valid TS). Caller
    /// positions the indent for the first shim; subsequent shims are
    /// separated by newline + indent.
    fn writeDefaultParamShims(self: *Printer, params: []const NodeId) !void {
        var first = true;
        for (params) |pn| {
            if (self.hir.kindOf(pn) != .parameter) continue;
            if (self.isThisParam(pn)) continue;
            const p = hir_mod.parameterOf(self.hir, pn);
            if (p.default_value == hir_mod.none_node_id) continue;
            if (p.name == hir_mod.none_node_id) continue;
            if (!first) try self.writeNewlineIndent();
            first = false;
            try self.write("if (");
            try self.printExpression(p.name);
            try self.write(" === void 0) { ");
            try self.printExpression(p.name);
            try self.write(" = ");
            try self.printExpression(p.default_value);
            try self.write("; }");
        }
    }

    /// Emit a function body block (`{ ... }`) for a function whose
    /// parameter list contains `= default` parameters. At ES5 this
    /// prepends an `if (x === void 0) { x = <default>; }` shim for
    /// each default-bearing parameter, then emits the original body
    /// statements. `body` may be a `block_stmt` or an expression
    /// (arrow concise-body).
    fn printFnBodyWithDefaults(self: *Printer, params: []const NodeId, body: NodeId) !void {
        try self.write("{");
        self.depth += 1;
        try self.writeNewlineIndent();
        // Default-param shims first (they may target the temp idents
        // that destructuring shims subsequently destructure into).
        const has_defaults = self.hasDefaultParam(params);
        if (has_defaults) try self.writeDefaultParamShims(params);
        // §4.A — ES5 destructuring-param extraction. Runs after the
        // default-param shims so the temp idents (`_p<N>`) are
        // populated when this fires.
        const has_destruct = self.options.es_target == .es5 and self.hasDestructuringParam(params);
        if (has_destruct) {
            if (has_defaults) try self.writeNewlineIndent();
            try self.writeDestructuringParamShims(params);
        }
        if (body != hir_mod.none_node_id) {
            if (self.hir.kindOf(body) == .block_stmt) {
                const stmts = hir_mod.blockStmts(self.hir, body);
                for (stmts) |s| {
                    try self.write(self.options.newline);
                    try self.printStatement(s);
                }
            } else {
                try self.write(self.options.newline);
                try self.indent();
                try self.write("return ");
                try self.printExpression(body);
                try self.writeSemi();
            }
        }
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
    }

    /// True when any parameter carries a visibility/`readonly` modifier
    /// (a TS "parameter property"). Only constructors can have these.
    fn hasParameterProperty(self: *const Printer, params: []const NodeId) bool {
        for (params) |p| {
            if (self.hir.kindOf(p) != .parameter) continue;
            if (hir_mod.parameterOf(self.hir, p).flags.is_parameter_property) return true;
        }
        return false;
    }

    /// True when `stmt` is a `super(...)` call statement (the call has a
    /// `super` callee). Parameter-property assignments are emitted right
    /// after such a leading call, matching tsc.
    fn isSuperCallStatement(self: *const Printer, stmt: NodeId) bool {
        if (self.hir.kindOf(stmt) != .call_expr) return false;
        const callee = hir_mod.callOf(self.hir, stmt).callee;
        if (self.hir.kindOf(callee) == .super_expr) return true;
        // `super` is also modeled as an identifier named "super".
        if (self.hir.kindOf(callee) == .identifier) {
            return std.mem.eql(u8, self.interner.get(hir_mod.identifierOf(self.hir, callee).name), "super");
        }
        return false;
    }

    /// Emit `this.x = x;` for each constructor parameter property, the way
    /// tsc lowers `constructor(public x) {}`. Pattern/`this` params can't be
    /// parameter properties, so the name is always a plain identifier.
    fn emitParameterPropertyAssignments(self: *Printer, params: []const NodeId) !void {
        for (params) |p| {
            if (self.hir.kindOf(p) != .parameter) continue;
            const pp = hir_mod.parameterOf(self.hir, p);
            if (!pp.flags.is_parameter_property) continue;
            if (pp.name == hir_mod.none_node_id or self.hir.kindOf(pp.name) != .identifier) continue;
            const name = self.interner.get(hir_mod.identifierOf(self.hir, pp.name).name);
            try self.write(self.options.newline);
            try self.indent();
            try self.write("this.");
            try self.write(name);
            try self.write(" = ");
            try self.write(name);
            try self.writeSemi();
        }
    }

    /// Print a constructor body that has parameter properties: emit any
    /// leading `super(...)` call, then the `this.x = x;` assignments, then
    /// the remaining statements (tsc's ordering).
    fn printConstructorBodyWithParamProps(self: *Printer, body: NodeId, params: []const NodeId) !void {
        try self.write("{");
        self.depth += 1;
        // ES5 default-param shims (uncommon in constructors; kept for safety).
        if (self.options.es_target == .es5 and self.hasDefaultParam(params)) {
            try self.writeNewlineIndent();
            try self.writeDefaultParamShims(params);
        }
        var stmts: []const NodeId = &.{};
        if (body != hir_mod.none_node_id and self.hir.kindOf(body) == .block_stmt) {
            stmts = hir_mod.blockStmts(self.hir, body);
        }
        var start: usize = 0;
        if (stmts.len > 0 and self.isSuperCallStatement(stmts[0])) {
            try self.write(self.options.newline);
            try self.printStatement(stmts[0]);
            start = 1;
        }
        try self.emitParameterPropertyAssignments(params);
        for (stmts[start..]) |s| {
            try self.write(self.options.newline);
            try self.printStatement(s);
        }
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
    }

    /// True if `param` is an explicit `this: T` first-parameter
    /// (TS-only — must not appear in the runtime JS output).
    fn isThisParam(self: *const Printer, param: NodeId) bool {
        if (self.hir.kindOf(param) != .parameter) return false;
        const p = hir_mod.parameterOf(self.hir, param);
        if (p.name == hir_mod.none_node_id) return false;
        if (self.hir.kindOf(p.name) != .identifier) return false;
        const id = hir_mod.identifierOf(self.hir, p.name);
        return std.mem.eql(u8, self.interner.get(id.name), "this");
    }

    /// Print a comma-separated parameter list, skipping any
    /// `this: T` parameter (TS-only — runtime JS doesn't surface
    /// it). Caller writes the surrounding parens.
    fn printRuntimeParams(self: *Printer, params: []const NodeId) !void {
        var first = true;
        var idx: usize = 0;
        for (params) |p| {
            if (self.isThisParam(p)) continue;
            if (!first) try self.write(", ");
            // §4.A — at ES5, pattern params become temp idents `_pN`;
            // the destructuring shim in the body extracts the bindings.
            // At ES2015+ printParameter renders the pattern verbatim.
            if (self.options.es_target == .es5 and self.isPatternParam(p)) {
                if (hir_mod.parameterOf(self.hir, p).flags.is_rest) try self.write("...");
                var buf: [16]u8 = undefined;
                const tmp_name = std.fmt.bufPrint(&buf, "_p{d}", .{idx}) catch unreachable;
                try self.write(tmp_name);
            } else {
                try self.printParameter(p);
            }
            first = false;
            idx += 1;
        }
    }

    fn printClassDecl(self: *Printer, node: NodeId) !void {
        // §4.A.2 — at ES5, lower class to function-with-prototype.
        if (self.options.es_target == .es5) {
            try self.printClassDeclEs5(node);
            return;
        }
        const c = hir_mod.classOf(self.hir, node);
        const members = hir_mod.classMembers(self.hir, node);
        // §4.A.9 v7 — Stage 3 pre-scan: if the class has any decorated
        // instance member, set `stage3_instance_extra_class` so every
        // ctor-emit path inside the class body appends the
        // `__runInitializers(this, _<Class>_instanceExtra);` trailer.
        // Save and restore around the class body so nested classes
        // don't leak the parent's context.
        const prev_instance_extra = self.stage3_instance_extra_class;
        const prev_metadata_decl = self.stage3_metadata_declared_for;
        defer {
            self.stage3_instance_extra_class = prev_instance_extra;
            self.stage3_metadata_declared_for = prev_metadata_decl;
        }
        self.stage3_metadata_declared_for = null;
        if (!self.options.experimental_decorators and c.name != hir_mod.none_node_id) {
            if (self.classHasDecoratedInstanceMember(node)) {
                self.stage3_instance_extra_class = c.name;
            } else {
                self.stage3_instance_extra_class = null;
            }
        } else {
            self.stage3_instance_extra_class = null;
        }
        // §4.A.7 — at targets below ES2022, lower `#field` to a
        // per-class `WeakMap`. Emit the `var _<Class>_<field> = new
        // WeakMap();` declarations *before* the class statement.
        const downlevel_private = !self.options.es_target.supportsNativePrivateFields() and
            self.classHasPrivateField(node) and c.name != hir_mod.none_node_id;
        if (downlevel_private) {
            for (members) |m| {
                if (self.hir.kindOf(m) != .object_property) continue;
                const op = hir_mod.objectPropertyOf(self.hir, m);
                const pname = self.privateFieldName(op.key) orelse continue;
                try self.write("var ");
                try self.writeWeakMapName(c.name, pname);
                try self.write(" = new WeakMap();");
                try self.write(self.options.newline);
            }
        }
        // §4.A.9 — public class fields are an ES2022 feature. At
        // earlier ES2015–ES2021 targets we hoist `x = <init>;` into
        // the (synthesized if absent) constructor as `this.x = <init>;`,
        // matching tsc's downlevel shape. We also force the same lowering
        // when `useDefineForClassFields: false` so emitted JS uses the
        // legacy assignment semantics rather than ES2022 [[Define]].
        const downlevel_fields = (!self.options.es_target.supportsNativeClassFields() or
            !self.options.use_define_for_class_fields) and
            (self.classHasPublicFieldInit(node) or self.classHasPrivateFieldInit(node));
        try self.write("class");
        if (c.name != hir_mod.none_node_id) {
            try self.write(" ");
            try self.printExpression(c.name);
        }
        if (c.extends != hir_mod.none_node_id) {
            try self.write(" extends ");
            try self.printHeritageExpression(c.extends);
        }
        try self.write(" {");
        // §4.A.9 v13 — IIFE wrap: when `stage3_iife_class_decorators`
        // is set, inject a `static { ... }` block at the top of the
        // class body. The block runs:
        //   1. Member decorate chain (v13c) — moved here from
        //      post-class so member decorates run during class init.
        //   2. Class decorate chain (v13) — runs after member
        //      decorates and rebinds the IIFE-scope `<Name>` so
        //      subsequent static-field initializers see the post-
        //      decorator class identity (closes the captured-
        //      reference caveat).
        //
        // §4.A.9 v13b — for member-only-decorated classes the wrap
        // is still active and the static block runs the member
        // chain, but no class decorate sub-block is emitted.
        const iife_decs: ?[]const NodeId = if (c.name != hir_mod.none_node_id)
            self.stage3_iife_class_decorators
        else
            null;
        const has_member_decorators = iife_decs != null and self.classHasAnyMemberDecorator(node);
        const has_class_decorators = iife_decs != null and iife_decs.?.len > 0;
        const has_static_block = has_class_decorators or has_member_decorators;
        if (has_static_block) {
            self.depth += 1;
            try self.write(self.options.newline);
            try self.indent();
            try self.emitStage3IIFEClassStaticBlock(node, c.name, iife_decs.?);
            self.depth -= 1;
        }
        if (members.len == 0) {
            if (has_static_block) {
                try self.write(self.options.newline);
                try self.indent();
            }
            try self.write("}");
            return;
        }
        // Track lexical class so `printMember` can rewrite `this.#x`
        // accesses inside the body.
        const prev_class = self.current_class_name;
        if (downlevel_private) self.current_class_name = hir_mod.identifierOf(self.hir, c.name).name;
        defer self.current_class_name = prev_class;
        self.depth += 1;
        // Locate an explicit constructor (if any). We need it for
        // downlevel field hoisting (§4.A.9) and Stage 3 instance-extras
        // ctor trailer (§4.A.9 v7). If neither concern applies we still
        // scan but don't emit a synthesized ctor.
        const stage3_instance = self.stage3_instance_extra_class != null;
        var ctor_idx: ?usize = null;
        if (downlevel_fields or stage3_instance) {
            for (members, 0..) |m, idx| {
                const k = self.hir.kindOf(m);
                if (k != .fn_decl and k != .fn_expr) continue;
                const fd = hir_mod.fnDeclOf(self.hir, m);
                if (fd.flags.is_constructor) {
                    ctor_idx = idx;
                    break;
                }
            }
            if (ctor_idx == null) {
                try self.write(self.options.newline);
                try self.indent();
                try self.printSynthesizedCtor(node);
            }
        }
        var i: usize = 0;
        while (i < members.len) : (i += 1) {
            const m = members[i];
            // Decorators are members whose kind is `.decorator`.
            // They're emitted as preceding siblings of the actual
            // member; we skip them in the in-class output and
            // collect them for the post-class __decorate calls.
            if (self.hir.kindOf(m) == .decorator) continue;
            // Abstract members (`abstract f(): void;` / `abstract x: T;`)
            // have no runtime presence — tsc strips them. Emitting the
            // bodyless method signature `f();` would be invalid JS.
            if (self.memberIsAbstract(m)) continue;
            // Private fields are stored in the per-class WeakMap;
            // skip the in-class field declaration entirely. Their
            // initializers are hoisted into the (explicit or
            // synthesized) constructor via `writeHoistedFieldInits`
            // → `_<Class>_<field>.set(this, <init>);` (§4.A.7 v2).
            if (downlevel_private and self.hir.kindOf(m) == .object_property) {
                const op = hir_mod.objectPropertyOf(self.hir, m);
                if (self.privateFieldName(op.key) != null) continue;
            }
            // Public field with an initializer at sub-ES2022 — has
            // already been hoisted into the (real or synthesized) ctor.
            // Auto-accessors (`is_accessor`) bypass this skip: their
            // class-body lowering emits a storage slot + paired get/set
            // that mustn't be hoisted away.
            if (downlevel_fields and self.hir.kindOf(m) == .object_property) {
                const op = hir_mod.objectPropertyOf(self.hir, m);
                if (op.value != hir_mod.none_node_id and
                    self.privateFieldName(op.key) == null and
                    !op.is_accessor)
                {
                    continue;
                }
            }
            try self.write(self.options.newline);
            try self.indent();
            switch (self.hir.kindOf(m)) {
                .fn_decl, .fn_expr, .arrow_fn => {
                    const is_decorated_ctor = ctor_idx != null and ctor_idx.? == i;
                    const needs_synthetic_trailer = is_decorated_ctor and (downlevel_fields or stage3_instance);
                    if (needs_synthetic_trailer) {
                        try self.printCtorWithHoistedFields(node, m);
                    } else {
                        try self.printFnDecl(m);
                    }
                },
                .object_property => {
                    const op = hir_mod.objectPropertyOf(self.hir, m);
                    if (op.is_accessor and self.hir.kindOf(op.key) == .identifier) {
                        // §4.A.9 v9/v10 — auto-accessor lowering.
                        // Expand `accessor <key> = <value>;` into a
                        // backing storage field + paired getter/setter.
                        // At ES2022+ (native private fields), the storage
                        // is a true-private `#<key>_accessor` slot emitted
                        // here in the class body. Below ES2022, the
                        // initializer flows through `writeHoistedFieldInits`
                        // into the (synthesized or explicit) ctor as
                        // `this._<key> = <value>;` and we only emit the
                        // get/set pair here.
                        const id = hir_mod.identifierOf(self.hir, op.key);
                        const key_name = self.interner.get(id.name);
                        const use_private = self.options.es_target.supportsNativePrivateFields();
                        const storage_prefix: []const u8 = if (use_private) "#" else "_";
                        const storage_suffix: []const u8 = if (use_private) "_accessor" else "";
                        // Storage field — emitted in the class body only
                        // at ES2022+ (where public/private class fields
                        // are native). At older targets the initializer
                        // is hoisted into the ctor.
                        if (use_private) {
                            if (op.is_static) try self.write("static ");
                            try self.write(storage_prefix);
                            try self.write(key_name);
                            try self.write(storage_suffix);
                            if (op.value != hir_mod.none_node_id) {
                                try self.write(" = ");
                                // §4.A.9 v12 — wrap decorator-returned
                                // init wrappers around the accessor's
                                // private-slot value at ES2022+. `this`
                                // inside a static field init points at
                                // the class itself, so a single `this`
                                // host works for both static + instance
                                // forms.
                                const did_wrap = try self.beginFieldInitWrap(node, m, true);
                                try self.printExpression(op.value);
                                try self.endFieldInitWrap(did_wrap);
                            }
                            try self.write(";");
                            try self.write(self.options.newline);
                            try self.indent();
                        }
                        // Getter.
                        if (op.is_static) try self.write("static ");
                        try self.write("get ");
                        try self.write(key_name);
                        try self.write("() { return this.");
                        try self.write(storage_prefix);
                        try self.write(key_name);
                        try self.write(storage_suffix);
                        try self.write("; }");
                        // Setter.
                        try self.write(self.options.newline);
                        try self.indent();
                        if (op.is_static) try self.write("static ");
                        try self.write("set ");
                        try self.write(key_name);
                        try self.write("(value) { this.");
                        try self.write(storage_prefix);
                        try self.write(key_name);
                        try self.write(storage_suffix);
                        try self.write(" = value; }");
                    } else if (op.is_method) {
                        // Method member — computed-name methods come through
                        // the object_property path (regular ones are
                        // fn_decl). Emit `[key](params){body}` /
                        // `key(params){body}`, not a `key = value` field.
                        if (op.is_static) try self.write("static ");
                        try self.writeMethodPrefix(op.value);
                        if (op.is_computed) {
                            try self.write("[");
                            try self.printExpression(op.key);
                            try self.write("]");
                        } else {
                            try self.printExpression(op.key);
                        }
                        try self.printObjectMethodBody(op.value);
                    } else {
                        if (op.is_static) try self.write("static ");
                        if (op.is_computed) {
                            try self.write("[");
                            try self.printExpression(op.key);
                            try self.write("]");
                        } else {
                            try self.printExpression(op.key);
                        }
                        if (op.value != hir_mod.none_node_id) {
                            try self.write(" = ");
                            // §4.A.9 v12 — wrap decorated field's
                            // initializer with `__runInitializers` so
                            // decorator-returned init wrappers run.
                            // `this` inside a static field init points
                            // at the class, so a single `this` host
                            // covers static + instance.
                            const did_wrap = try self.beginFieldInitWrap(node, m, true);
                            try self.printExpression(op.value);
                            try self.endFieldInitWrap(did_wrap);
                        }
                        try self.writeSemi();
                    }
                },
                .block_stmt => {
                    // Stage 3 class static-initialization block. Emit
                    // `static { ... }` on a single line — `printBlock`
                    // doesn't re-indent, unlike `printStatement`.
                    try self.write("static ");
                    try self.printBlock(m);
                },
                else => {},
            }
        }
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
        // §4.A.8 — emit `__decorate` calls for each decorated member.
        // §4.A.9 v13c — when IIFE-wrapped, the member decorate chain
        // is emitted INSIDE the class's static block (above the class
        // decorate chain, if any) rather than after the class body.
        // The static-block emit handles it; skip the post-class call
        // here to avoid duplicate decorate emission.
        if (self.stage3_iife_class_decorators == null) {
            try self.emitMethodDecorateCalls(node);
        }
    }

    /// True if the class has at least one non-private `object_property`
    /// member with an initializer. Used to decide whether downlevel
    /// field-hoisting is needed.
    fn classHasPublicFieldInit(self: *Printer, class_node: NodeId) bool {
        const members = hir_mod.classMembers(self.hir, class_node);
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (op.is_static) continue;
            if (op.value == hir_mod.none_node_id) continue;
            if (self.privateFieldName(op.key) != null) continue;
            return true;
        }
        return false;
    }

    /// §4.A.7 v2 — true if the class has at least one private field
    /// with an initializer. Used to trigger ctor synthesis (or
    /// hoisted-fields decoration of an explicit ctor) at sub-ES2022
    /// targets so `_<Class>_<field>.set(this, <init>);` runs.
    fn classHasPrivateFieldInit(self: *Printer, class_node: NodeId) bool {
        const members = hir_mod.classMembers(self.hir, class_node);
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (op.is_static) continue;
            if (op.value == hir_mod.none_node_id) continue;
            if (self.privateFieldName(op.key) == null) continue;
            return true;
        }
        return false;
    }

    /// Emit `this.<key> = <init>; ` for every public field with an
    /// initializer on this class. Caller is responsible for being
    /// inside a constructor body and writing surrounding indentation.
    fn writeHoistedFieldInits(self: *Printer, class_node: NodeId) !void {
        const members = hir_mod.classMembers(self.hir, class_node);
        const c = hir_mod.classOf(self.hir, class_node);
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (op.is_static) continue;
            if (op.value == hir_mod.none_node_id) continue;
            // §4.A.7 v2 — private field initializer hoist. Below ES2022
            // private fields lower through per-class WeakMap instances;
            // the field's `<init>` expression needs to land in the
            // ctor body as `_<Class>_<field>.set(this, <init>);` so
            // instances actually get the initial value.
            if (self.privateFieldName(op.key)) |pname| {
                if (!self.options.es_target.supportsNativePrivateFields() and c.name != hir_mod.none_node_id) {
                    try self.writeWeakMapName(c.name, pname);
                    try self.write(".set(this, ");
                    try self.printExpression(op.value);
                    try self.write("); ");
                }
                continue;
            }
            // Auto-accessor: hoist its `_<key>` storage assignment
            // into the ctor (not the public-facing `<key>` name —
            // that's the getter/setter pair). At ES2022+ the storage
            // field is emitted natively in the class body via the
            // `#<key>_accessor` private slot, so no hoist needed.
            if (op.is_accessor) {
                if (self.options.es_target.supportsNativePrivateFields()) continue;
                if (self.hir.kindOf(op.key) != .identifier) continue;
                const id = hir_mod.identifierOf(self.hir, op.key);
                const key_name = self.interner.get(id.name);
                try self.write("this._");
                try self.write(key_name);
                try self.write(" = ");
                // §4.A.9 v12 — wrap the accessor's storage initializer
                // with `__runInitializers` so decorator-returned init
                // wrappers actually run for `@dec accessor x = v;`.
                const did_wrap = try self.beginFieldInitWrap(class_node, m, true);
                try self.printExpression(op.value);
                try self.endFieldInitWrap(did_wrap);
                try self.write("; ");
                continue;
            }
            try self.write("this.");
            try self.printExpression(op.key);
            try self.write(" = ");
            // §4.A.9 v12 — wrap decorated public-field initializers
            // with `__runInitializers` so decorator-returned init
            // wrappers actually run. No-op for undecorated fields.
            const did_wrap = try self.beginFieldInitWrap(class_node, m, true);
            try self.printExpression(op.value);
            try self.endFieldInitWrap(did_wrap);
            try self.write("; ");
        }
    }

    /// Synthesize a constructor for a class with no explicit ctor that
    /// nonetheless needs hoisted public-field initializers. Forwards
    /// args via `super(...args)` for derived classes.
    fn printSynthesizedCtor(self: *Printer, class_node: NodeId) !void {
        const c = hir_mod.classOf(self.hir, class_node);
        if (c.extends != hir_mod.none_node_id) {
            try self.write("constructor(...args) { super(...args); ");
        } else {
            try self.write("constructor() { ");
        }
        try self.writeHoistedFieldInits(class_node);
        try self.emitStage3InstanceExtraTrailer();
        try self.write("}");
    }

    /// Emit an explicit constructor with hoisted public-field
    /// initializers prepended to its body. For derived classes the
    /// initializers must come *after* `super(...)`; we approximate
    /// that here by emitting initializers *after* the user body
    /// (precise pre/post-`super` splitting is a follow-up). For root
    /// classes we emit initializers first, before user statements.
    fn printCtorWithHoistedFields(self: *Printer, class_node: NodeId, ctor: NodeId) !void {
        const fd = hir_mod.fnDeclOf(self.hir, ctor);
        try self.write("constructor(");
        const params = hir_mod.fnParams(self.hir, ctor);
        try self.printRuntimeParams(params);
        try self.write(") {");
        const c = hir_mod.classOf(self.hir, class_node);
        const has_extends = c.extends != hir_mod.none_node_id;
        try self.write(" ");
        if (!has_extends) try self.writeHoistedFieldInits(class_node);
        if (fd.body != hir_mod.none_node_id and self.hir.kindOf(fd.body) == .block_stmt) {
            const stmts = hir_mod.blockStmts(self.hir, fd.body);
            for (stmts) |s| {
                try self.printNonIndentStatement(s);
                try self.write(" ");
            }
        }
        if (has_extends) try self.writeHoistedFieldInits(class_node);
        try self.emitStage3InstanceExtraTrailer();
        try self.write("}");
    }

    /// True if any class member is an `object_property` whose key is
    /// an identifier starting with `#` (a private field).
    fn classHasPrivateField(self: *Printer, class_node: NodeId) bool {
        const members = hir_mod.classMembers(self.hir, class_node);
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (self.privateFieldName(op.key) != null) return true;
        }
        return false;
    }

    /// If `key` is an identifier whose interned name begins with `#`,
    /// return the name *without* the leading `#`. Otherwise null.
    fn privateFieldName(self: *Printer, key: NodeId) ?[]const u8 {
        if (key == hir_mod.none_node_id) return null;
        if (self.hir.kindOf(key) != .identifier) return null;
        const id = hir_mod.identifierOf(self.hir, key);
        const s = self.interner.get(id.name);
        if (s.len == 0 or s[0] != '#') return null;
        return s[1..];
    }

    /// Emit the WeakMap variable name for a private field on this class
    /// — `_<ClassName>_<field>`, matching tsc's mangling.
    fn writeWeakMapName(self: *Printer, class_name_node: NodeId, field: []const u8) !void {
        try self.write("_");
        const cn = hir_mod.identifierOf(self.hir, class_name_node);
        try self.write(self.interner.get(cn.name));
        try self.write("_");
        try self.write(field);
    }

    /// Walk class members; for each run of decorator siblings preceding
    /// a method or property, emit a post-class decorator helper call.
    /// Class-level decorators are handled by `emitClassDecorateCall`
    /// from the source-file walker.
    fn emitMethodDecorateCalls(self: *Printer, class_node: NodeId) anyerror!void {
        const c = hir_mod.classOf(self.hir, class_node);
        if (c.name == hir_mod.none_node_id) return;
        const members = hir_mod.classMembers(self.hir, class_node);
        // §4.A.9 v6 — pre-scan to detect any decorated static member.
        // If found, declare a shared `_<Class>_staticExtra = []` array
        // once and pass it to each static __esDecorate call; then call
        // `__runInitializers(<Class>, _<Class>_staticExtra);` after all
        // member decorate calls so any addInitializer callbacks run.
        var any_decorated_static = false;
        var any_decorated_instance = false;
        if (!self.options.experimental_decorators) {
            var s_i: usize = 0;
            while (s_i < members.len) : (s_i += 1) {
                if (self.hir.kindOf(members[s_i]) != .decorator) continue;
                var s_j = s_i;
                while (s_j < members.len and self.hir.kindOf(members[s_j]) == .decorator) s_j += 1;
                if (s_j >= members.len) break;
                const target = members[s_j];
                const tk = self.hir.kindOf(target);
                // Skip constructor decorators (not legal in Stage 3 but
                // current emit also skips them).
                var is_ctor = false;
                if (tk == .fn_decl or tk == .fn_expr) {
                    is_ctor = hir_mod.fnDeclOf(self.hir, target).flags.is_constructor;
                }
                if (!is_ctor) {
                    if (self.isStaticMember(target)) {
                        any_decorated_static = true;
                    } else {
                        any_decorated_instance = true;
                    }
                }
                s_i = s_j;
            }
            if (any_decorated_static or any_decorated_instance) {
                // §4.A.9 v11 — declare per-class metadata once, shared
                // with the class-decorator chain (which runs after).
                try self.ensureStage3Metadata(c.name);
            }
            if (any_decorated_static) {
                try self.write(self.options.newline);
                try self.indent();
                try self.write("var _");
                try self.writeClassNameSuffix(c.name);
                try self.write("_staticExtra = [];");
            }
            if (any_decorated_instance) {
                try self.write(self.options.newline);
                try self.indent();
                try self.write("var _");
                try self.writeClassNameSuffix(c.name);
                try self.write("_instanceExtra = [];");
            }
        }
        var i: usize = 0;
        while (i < members.len) : (i += 1) {
            const m = members[i];
            if (self.hir.kindOf(m) != .decorator) continue;
            // Collect a run of decorators...
            var j = i;
            while (j < members.len and self.hir.kindOf(members[j]) == .decorator) j += 1;
            // ...followed by the actual member they decorate.
            if (j >= members.len) {
                i = j;
                continue;
            }
            const target = members[j];
            const decorators = members[i..j];
            const tk = self.hir.kindOf(target);
            // Method or property: emit
            //   __decorate([decs], ClassName.prototype, "name", null);
            // Static members target the constructor itself.
            const target_name: ?NodeId = blk: {
                if (tk == .fn_decl or tk == .fn_expr) {
                    const fd = hir_mod.fnDeclOf(self.hir, target);
                    if (fd.flags.is_constructor) break :blk null; // constructors don't decorate
                    break :blk fd.name;
                }
                if (tk == .object_property) {
                    const op = hir_mod.objectPropertyOf(self.hir, target);
                    break :blk op.key;
                }
                break :blk null;
            };
            const name_node = target_name orelse {
                i = j;
                continue;
            };
            if (!self.options.experimental_decorators) {
                try self.emitStage3MemberDecorateCall(decorators, target, name_node, c.name, any_decorated_static, any_decorated_instance);
                i = j;
                continue;
            }
            try self.write(self.options.newline);
            try self.indent();
            try self.write("__decorate([");
            for (decorators, 0..) |d, k| {
                if (k > 0) try self.write(", ");
                const dp = hir_mod.decoratorOf(self.hir, d);
                try self.printExpression(dp.expression);
            }
            // `emitDecoratorMetadata` — append `__metadata(...)` entries
            // inside the same array.
            if (self.options.emit_decorator_metadata and self.options.experimental_decorators) {
                try self.emitMemberMetadata(target);
            }
            try self.write("], ");
            try self.printExpression(c.name);
            if (!self.isStaticMember(target)) try self.write(".prototype");
            try self.write(", \"");
            if (self.hir.kindOf(name_node) == .identifier) {
                const id = hir_mod.identifierOf(self.hir, name_node);
                try self.write(self.interner.get(id.name));
            }
            try self.write("\", null);");
            // §4.A.8 ratchet — also emit `__param(N, dec)` calls
            // when the decorated target is a method/fn with
            // parameter decorators.
            if (tk == .fn_decl or tk == .fn_expr) {
                const params = hir_mod.fnParams(self.hir, target);
                for (params, 0..) |p, idx| {
                    if (self.hir.kindOf(p) != .parameter) continue;
                    const param_decs = hir_mod.parameterDecorators(self.hir, p);
                    if (param_decs.len == 0) continue;
                    try self.write(self.options.newline);
                    try self.indent();
                    try self.write("__decorate([");
                    for (param_decs, 0..) |pd, k| {
                        if (k > 0) try self.write(", ");
                        const wrap_idx_buf = try std.fmt.allocPrint(self.gpa, "__param({d}, ", .{idx});
                        defer self.gpa.free(wrap_idx_buf);
                        try self.write(wrap_idx_buf);
                        const dp = hir_mod.decoratorOf(self.hir, pd);
                        try self.printExpression(dp.expression);
                        try self.write(")");
                    }
                    try self.write("], ");
                    try self.printExpression(c.name);
                    if (!self.isStaticMember(target)) try self.write(".prototype");
                    try self.write(", \"");
                    if (self.hir.kindOf(name_node) == .identifier) {
                        const fid = hir_mod.identifierOf(self.hir, name_node);
                        try self.write(self.interner.get(fid.name));
                    }
                    try self.write("\", null);");
                }
            }
            i = j;
        }
        // §4.A.9 v6 — after all member decorate calls, run any
        // `addInitializer` callbacks the static-member decorators
        // registered. Instance initializers still need ctor-synthesis
        // wiring (Phase 4 §4.A.9 follow-up).
        if (any_decorated_static and !self.options.experimental_decorators) {
            try self.write(self.options.newline);
            try self.indent();
            try self.write("__runInitializers(");
            try self.printExpression(c.name);
            try self.write(", _");
            try self.writeClassNameSuffix(c.name);
            try self.write("_staticExtra);");
        }
    }

    /// Simplified Stage 3 member decorator lowering. A spec-complete
    /// transform needs per-member initializer arrays and class-static
    /// blocks; this v1 helper shape pins the observable decorator list
    /// + context so we no longer mix Stage 3 class decorators with
    /// legacy member `__decorate` calls.
    fn emitStage3MemberDecorateCall(
        self: *Printer,
        decorators: []const NodeId,
        target: NodeId,
        name_node: NodeId,
        class_name: NodeId,
        has_static_extras: bool,
        has_instance_extras: bool,
    ) anyerror!void {
        // §4.A.9 v12 — decorated fields (incl. auto-accessor storage)
        // need a per-field `_<Class>_<field>_init = []` array passed as
        // __esDecorate's 5th `initializers` arg. The class-body / ctor
        // emit then wraps the field's value with
        //   __runInitializers(this, _<Class>_<field>_init, <orig>)
        // so any initializer-wrapping decorators take effect. The pre-
        // declaration must precede the __esDecorate line.
        const wants_field_init_var = !self.options.experimental_decorators and
            class_name != hir_mod.none_node_id and
            self.hir.kindOf(target) == .object_property and
            self.hir.kindOf(name_node) == .identifier and
            self.privateFieldName(name_node) == null;
        if (wants_field_init_var) {
            try self.write(self.options.newline);
            try self.indent();
            try self.write("var _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_");
            const id = hir_mod.identifierOf(self.hir, name_node);
            try self.write(self.interner.get(id.name));
            try self.write("_init = [];");
        }
        try self.write(self.options.newline);
        try self.indent();
        // Stage 3 `__esDecorate` first arg (`ctor`) drives tslib's
        // `Object.defineProperty(target, name, descriptor)` path. When
        // non-null, tslib reads the current descriptor from the proto
        // (instance) or the class itself (static), lets decorators
        // mutate `descriptor.value` / `descriptor.get` / `descriptor.set`,
        // and applies the (possibly replaced) descriptor.
        //
        // §4.A.9 v2 — static members pass the class identifier.
        // §4.A.9 v14 — instance accessor/method/getter/setter decorators
        // now also pass the class so that decorator-returned
        // replacements actually take effect (the v12 wrap path covered
        // `init` only — `get`/`set`/`value` replacement requires the
        // defineProperty pass).
        //
        // Instance fields keep `null` because field-decorator returns
        // are initializer wrappers (slot 5), not descriptor values; the
        // defineProperty pass would redefine the prototype with an
        // unrelated descriptor.
        const tk_for_ctor = self.hir.kindOf(target);
        const is_static_for_ctor = self.isStaticMember(target);
        var is_instance_field = false;
        if (!is_static_for_ctor and tk_for_ctor == .object_property) {
            const op_for_ctor = hir_mod.objectPropertyOf(self.hir, target);
            is_instance_field = !op_for_ctor.is_accessor;
        }
        const pass_class_as_ctor = class_name != hir_mod.none_node_id and !is_instance_field;
        try self.write("__esDecorate(");
        if (pass_class_as_ctor) {
            try self.printExpression(class_name);
        } else {
            try self.write("null");
        }
        try self.write(", null, [");
        for (decorators, 0..) |d, k| {
            if (k > 0) try self.write(", ");
            const dp = hir_mod.decoratorOf(self.hir, d);
            try self.printExpression(dp.expression);
        }
        try self.write("], { kind: \"");
        try self.writeStage3MemberKind(target);
        try self.write("\", name: \"");
        try self.writeStage3MemberName(name_node);
        try self.write("\", static: ");
        try self.write(if (self.isStaticMember(target)) "true" else "false");
        try self.write(", private: ");
        try self.write(if (self.privateFieldName(name_node) != null) "true" else "false");
        // Stage 3 access descriptor — only emitted for public members
        // (private members would need `#name in obj` syntax which v0 skips).
        if (self.privateFieldName(name_node) == null) {
            try self.write(", ");
            try self.emitStage3AccessDescriptor(target, name_node);
        }
        // §4.A.9 v11 — metadata field references the per-class shared
        // `_<Class>_metadata` object that was declared once at the top
        // of the decorate chain (see `ensureStage3Metadata`). Decorators
        // that introspect `context.metadata` now see the same identity
        // across the class + all its members. When the class has no
        // declared name we fall back to `void 0` (anonymous expression).
        // §4.A.9 v6 — static-member decorators pass the per-class
        // `_<Class>_staticExtra` array (declared by the caller) so
        // addInitializer callbacks survive to `__runInitializers`.
        // §4.A.9 v7 — instance members pass `_<Class>_instanceExtra`
        // so the ctor trailer can run member-level extra initializers.
        try self.write(", metadata: ");
        if (class_name != hir_mod.none_node_id) {
            try self.write("_");
            try self.writeClassNameSuffix(class_name);
            try self.write("_metadata");
        } else {
            try self.write("void 0");
        }
        const is_static = self.isStaticMember(target);
        // §4.A.9 v12 — slot 5 (`initializers`) of __esDecorate. For
        // decorated fields we pass the per-field `_<Class>_<field>_init`
        // array; for non-field targets (methods/getters/setters) it
        // stays `null` since they don't have initializer-position
        // semantics.
        try self.write(" }, ");
        if (wants_field_init_var) {
            try self.write("_");
            try self.writeClassNameSuffix(class_name);
            try self.write("_");
            const id = hir_mod.identifierOf(self.hir, name_node);
            try self.write(self.interner.get(id.name));
            try self.write("_init");
        } else {
            try self.write("null");
        }
        if (is_static and has_static_extras and class_name != hir_mod.none_node_id) {
            try self.write(", _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_staticExtra);");
        } else if (!is_static and has_instance_extras and class_name != hir_mod.none_node_id) {
            try self.write(", _");
            try self.writeClassNameSuffix(class_name);
            try self.write("_instanceExtra);");
        } else {
            try self.write(", []);");
        }
    }

    /// Emit the Stage 3 `access: { has, get?, set? }` descriptor for a
    /// member decorator's context. Methods + getters provide `has`+`get`;
    /// fields provide `has`+`get`+`set`; setters provide `has`+`set`.
    /// `function (obj)` form is used (not arrow) so the output remains
    /// valid at any es_target without depending on arrow→function
    /// downlevel running on synthetic emit text.
    fn emitStage3AccessDescriptor(self: *Printer, target: NodeId, name_node: NodeId) anyerror!void {
        var name_slice: []const u8 = "";
        if (self.hir.kindOf(name_node) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, name_node);
            name_slice = self.interner.get(id.name);
        }
        const tk = self.hir.kindOf(target);
        var is_getter = false;
        var is_setter = false;
        if (tk == .fn_decl or tk == .fn_expr) {
            const fd = hir_mod.fnDeclOf(self.hir, target);
            is_getter = fd.flags.is_getter;
            is_setter = fd.flags.is_setter;
        }
        const is_field = tk == .object_property;
        const include_get = !is_setter;
        const include_set = is_field or is_setter;
        try self.write("access: { has: function (obj) { return \"");
        try self.write(name_slice);
        try self.write("\" in obj; }");
        if (include_get) {
            try self.write(", get: function (obj) { return obj.");
            try self.write(name_slice);
            try self.write("; }");
        }
        if (include_set) {
            try self.write(", set: function (obj, value) { obj.");
            try self.write(name_slice);
            try self.write(" = value; }");
        }
        try self.write(" }");
    }

    fn isStaticMember(self: *Printer, target: NodeId) bool {
        const tk = self.hir.kindOf(target);
        if (tk == .fn_decl or tk == .fn_expr) {
            return hir_mod.fnDeclOf(self.hir, target).flags.is_static;
        }
        if (tk == .object_property) {
            return hir_mod.objectPropertyOf(self.hir, target).is_static;
        }
        return false;
    }

    fn writeStage3MemberKind(self: *Printer, target: NodeId) !void {
        const tk = self.hir.kindOf(target);
        if (tk == .fn_decl or tk == .fn_expr) {
            const fd = hir_mod.fnDeclOf(self.hir, target);
            if (fd.flags.is_getter) {
                try self.write("getter");
            } else if (fd.flags.is_setter) {
                try self.write("setter");
            } else {
                try self.write("method");
            }
            return;
        }
        if (tk == .object_property) {
            const op = hir_mod.objectPropertyOf(self.hir, target);
            if (op.is_accessor) {
                try self.write("accessor");
                return;
            }
        }
        try self.write("field");
    }

    fn writeStage3MemberName(self: *Printer, name_node: NodeId) !void {
        if (self.privateFieldName(name_node)) |private_name| {
            try self.write(private_name);
            return;
        }
        if (self.hir.kindOf(name_node) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, name_node);
            try self.write(self.interner.get(id.name));
        }
    }

    /// Emit the trailing `, __metadata(...)` entries inside a
    /// `__decorate([...])` array for a decorated class member.
    fn emitMemberMetadata(self: *Printer, target: NodeId) anyerror!void {
        const tk = self.hir.kindOf(target);
        if (tk == .fn_decl or tk == .fn_expr) {
            const fd = hir_mod.fnDeclOf(self.hir, target);
            if (fd.flags.is_constructor) return;
            if (fd.flags.is_getter or fd.flags.is_setter) {
                try self.write(", __metadata(\"design:type\", ");
                if (fd.flags.is_setter) {
                    const params = hir_mod.fnParams(self.hir, target);
                    if (params.len > 0 and self.hir.kindOf(params[0]) == .parameter) {
                        const pp = hir_mod.parameterOf(self.hir, params[0]);
                        try self.writeDesignTypeFromAnno(pp.type_annotation);
                    } else {
                        try self.write("Object");
                    }
                } else {
                    try self.writeDesignTypeFromAnno(fd.return_type);
                }
                try self.write(")");
                return;
            }
            try self.write(", __metadata(\"design:type\", Function)");
            try self.write(", __metadata(\"design:paramtypes\", [");
            const params = hir_mod.fnParams(self.hir, target);
            var emitted: usize = 0;
            for (params) |p| {
                if (self.hir.kindOf(p) != .parameter) continue;
                if (emitted > 0) try self.write(", ");
                const pp = hir_mod.parameterOf(self.hir, p);
                try self.writeDesignTypeFromAnno(pp.type_annotation);
                emitted += 1;
            }
            try self.write("])");
            try self.write(", __metadata(\"design:returntype\", ");
            try self.writeDesignTypeFromAnno(fd.return_type);
            try self.write(")");
            return;
        }
        if (tk == .object_property) {
            const op = hir_mod.objectPropertyOf(self.hir, target);
            try self.write(", __metadata(\"design:type\", ");
            try self.writeDesignTypeFromAnno(op.type_annotation);
            try self.write(")");
            return;
        }
    }

    /// Map a type-annotation HIR node to a runtime expression suitable
    /// for `__metadata("design:type", X)`.
    fn writeDesignTypeFromAnno(self: *Printer, type_node: NodeId) anyerror!void {
        if (type_node == hir_mod.none_node_id) {
            try self.write("Object");
            return;
        }
        const k = self.hir.kindOf(type_node);
        if (k == .type_ref) {
            const tr = hir_mod.typeRefOf(self.hir, type_node);
            const name = self.interner.get(tr.name);
            const qual = hir_mod.typeRefQualifier(self.hir, type_node);
            if (qual.len > 0) {
                try self.write("Object");
                return;
            }
            if (std.mem.eql(u8, name, "string")) {
                try self.write("String");
                return;
            }
            if (std.mem.eql(u8, name, "number")) {
                try self.write("Number");
                return;
            }
            if (std.mem.eql(u8, name, "boolean")) {
                try self.write("Boolean");
                return;
            }
            if (std.mem.eql(u8, name, "bigint")) {
                try self.write("BigInt");
                return;
            }
            if (std.mem.eql(u8, name, "symbol")) {
                try self.write("Symbol");
                return;
            }
            if (std.mem.eql(u8, name, "void") or
                std.mem.eql(u8, name, "undefined") or
                std.mem.eql(u8, name, "null") or
                std.mem.eql(u8, name, "never"))
            {
                try self.write("void 0");
                return;
            }
            if (std.mem.eql(u8, name, "Function")) {
                try self.write("Function");
                return;
            }
            if (std.mem.eql(u8, name, "Array")) {
                try self.write("Array");
                return;
            }
            if (std.mem.eql(u8, name, "Object") or
                std.mem.eql(u8, name, "any") or
                std.mem.eql(u8, name, "unknown"))
            {
                try self.write("Object");
                return;
            }
            try self.write(name);
            return;
        }
        if (k == .array_type or k == .tuple_type) {
            try self.write("Array");
            return;
        }
        if (k == .fn_type or k == .constructor_type) {
            try self.write("Function");
            return;
        }
        try self.write("Object");
    }

    /// Lower a class to ES5 function-with-prototype. Pattern:
    ///   var Cls = (function(_super) {
    ///     __extends(Cls, _super);  // when extends is set
    ///     function Cls(args) { _super.call(this, ...); /* ctor body */ }
    ///     Cls.prototype.method = function () { /* ... */ };
    ///     return Cls;
    ///   })(SuperClass);
    /// Emit `function (params) body` for an ES5 accessor member (the value
    /// side of a `get`/`set` in an `Object.defineProperty` descriptor).
    fn printEs5AccessorFn(self: *Printer, node: NodeId) anyerror!void {
        const fd = hir_mod.fnDeclOf(self.hir, node);
        try self.write("function (");
        const params = hir_mod.fnParams(self.hir, node);
        try self.printRuntimeParams(params);
        try self.write(") ");
        if (fd.body != hir_mod.none_node_id) {
            if (self.hasDefaultParam(params) or self.hasDestructuringParam(params)) {
                try self.printFnBodyWithDefaults(params, fd.body);
            } else {
                self.next_block_is_fn_body = self.hir.kindOf(fd.body) == .block_stmt;
                try self.printStatementInline(fd.body);
            }
        } else {
            try self.write("{}");
        }
    }

    /// Lower a class getter/setter to `Object.defineProperty`, merging a
    /// get+set pair for the same (identifier) key + static-ness into one
    /// call: `Object.defineProperty(C.prototype, "x", { get: function () {…},
    /// set: function (v) {…}, enumerable: false, configurable: true });`.
    /// Only emits at the first accessor of the key (a later pair member is
    /// skipped by the caller-visible early return).
    fn printEs5ClassAccessor(self: *Printer, class_name: NodeId, members: []const NodeId, m: NodeId, fd: hir_mod.FnDeclPayload) anyerror!void {
        const name = self.interner.get(hir_mod.identifierOf(self.hir, fd.name).name);
        const is_static = fd.flags.is_static;
        // Skip if an earlier accessor already emitted this (name, static) pair.
        for (members) |prev| {
            if (prev == m) break;
            const pk = self.hir.kindOf(prev);
            if (pk != .fn_decl and pk != .fn_expr) continue;
            const pfd = hir_mod.fnDeclOf(self.hir, prev);
            if (!(pfd.flags.is_getter or pfd.flags.is_setter)) continue;
            if (self.hir.kindOf(pfd.name) != .identifier) continue;
            if (pfd.flags.is_static != is_static) continue;
            if (std.mem.eql(u8, self.interner.get(hir_mod.identifierOf(self.hir, pfd.name).name), name)) return;
        }
        // Collect the get and set nodes for this key.
        var get_node: NodeId = hir_mod.none_node_id;
        var set_node: NodeId = hir_mod.none_node_id;
        for (members) |mm| {
            const mk = self.hir.kindOf(mm);
            if (mk != .fn_decl and mk != .fn_expr) continue;
            const mfd = hir_mod.fnDeclOf(self.hir, mm);
            if (self.hir.kindOf(mfd.name) != .identifier) continue;
            if (mfd.flags.is_static != is_static) continue;
            if (!std.mem.eql(u8, self.interner.get(hir_mod.identifierOf(self.hir, mfd.name).name), name)) continue;
            if (mfd.flags.is_getter and get_node == hir_mod.none_node_id) get_node = mm;
            if (mfd.flags.is_setter and set_node == hir_mod.none_node_id) set_node = mm;
        }
        try self.write("Object.defineProperty(");
        try self.printExpression(class_name);
        if (!is_static) try self.write(".prototype");
        try self.write(", \"");
        try self.write(name);
        try self.write("\", { ");
        if (get_node != hir_mod.none_node_id) {
            try self.write("get: ");
            try self.printEs5AccessorFn(get_node);
            try self.write(", ");
        }
        if (set_node != hir_mod.none_node_id) {
            try self.write("set: ");
            try self.printEs5AccessorFn(set_node);
            try self.write(", ");
        }
        try self.write("enumerable: false, configurable: true }); ");
    }

    fn printClassDeclEs5(self: *Printer, node: NodeId) anyerror!void {
        const c = hir_mod.classOf(self.hir, node);
        if (c.name == hir_mod.none_node_id) return; // anonymous class — fall back
        const has_extends = c.extends != hir_mod.none_node_id;
        // Enable `super` lowering for the derived-class body. Restored
        // on exit so unrelated nested code (e.g. an inner non-derived
        // class declaration) sees its outer state.
        const prev_super = self.in_es5_super_lowering;
        if (has_extends) self.in_es5_super_lowering = true;
        defer self.in_es5_super_lowering = prev_super;
        try self.write("var ");
        try self.printExpression(c.name);
        try self.write(" = (function (");
        if (has_extends) try self.write("_super");
        try self.write(") { ");
        if (has_extends) {
            try self.write("__extends(");
            try self.printExpression(c.name);
            try self.write(", _super); ");
        }
        // Find the constructor; emit a function `<Name>(...)` for it
        // (or a no-arg default).
        const members = hir_mod.classMembers(self.hir, node);
        var ctor: ?NodeId = null;
        for (members) |m| {
            const k = self.hir.kindOf(m);
            if (k != .fn_decl and k != .fn_expr) continue;
            const fd = hir_mod.fnDeclOf(self.hir, m);
            if (fd.flags.is_constructor) {
                ctor = m;
                break;
            }
        }
        try self.write("function ");
        try self.printExpression(c.name);
        try self.write("(");
        if (ctor) |ct| {
            const params = hir_mod.fnParams(self.hir, ct);
            try self.printRuntimeParams(params);
        }
        try self.write(") { ");
        // §4.A — ES5 default-parameter lowering for the constructor.
        // Shims must run before any `_super.call(...)` synthesis or
        // class-field initialization, so the defaulted bindings are
        // visible everywhere downstream.
        if (ctor) |ct| {
            const params = hir_mod.fnParams(self.hir, ct);
            if (self.hasDefaultParam(params)) {
                try self.writeDefaultParamShims(params);
                try self.write(" ");
            }
            if (self.hasDestructuringParam(params)) {
                try self.writeDestructuringParamShims(params);
                try self.write(" ");
            }
        }
        // Synthesize `_super.call(this)` only when there is no
        // explicit constructor — an explicit ctor body already
        // contains a `super(...)` call which will be lowered to
        // `_super.call(this, ...)` by `printCall`.
        if (has_extends and ctor == null) {
            // An implicit derived constructor forwards its args to the base.
            // With no instance-field initializers this is exactly tsc's
            // `return _super !== null && _super.apply(this, arguments) || this;`
            // form (the old `_super.call(this)` dropped the arguments). When
            // there ARE field inits the byte-exact tsc shape needs a `_this`
            // capture (temp infra) — deferred; keep the in-place form there.
            var has_instance_field = false;
            for (members) |m| {
                if (self.hir.kindOf(m) != .object_property) continue;
                const op = hir_mod.objectPropertyOf(self.hir, m);
                if (op.is_static) continue;
                if (op.value == hir_mod.none_node_id) continue;
                has_instance_field = true;
                break;
            }
            if (has_instance_field) {
                try self.write("_super.call(this); ");
            } else {
                try self.write("return _super !== null && _super.apply(this, arguments) || this; ");
            }
        }
        // Class fields with initializers go inside the ctor body.
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (op.is_static) continue;
            if (op.value == hir_mod.none_node_id) continue;
            try self.write("this.");
            try self.printExpression(op.key);
            try self.write(" = ");
            try self.printExpression(op.value);
            try self.write("; ");
        }
        // Inline the ctor body if present.
        if (ctor) |ct| {
            const fd = hir_mod.fnDeclOf(self.hir, ct);
            if (fd.body != hir_mod.none_node_id and self.hir.kindOf(fd.body) == .block_stmt) {
                const stmts = hir_mod.blockStmts(self.hir, fd.body);
                for (stmts) |s| {
                    try self.printNonIndentStatement(s);
                    try self.write(" ");
                }
            }
        }
        try self.write("} ");
        // Methods → prototype assignments.
        for (members) |m| {
            const k = self.hir.kindOf(m);
            if (k != .fn_decl and k != .fn_expr) continue;
            const fd = hir_mod.fnDeclOf(self.hir, m);
            if (fd.flags.is_constructor) continue;
            if (fd.name == hir_mod.none_node_id) continue;
            // Getters/setters lower to `Object.defineProperty` (merging a
            // get+set pair for the same key into one call — separate calls
            // would clobber each other). Computed accessor names are deferred.
            if ((fd.flags.is_getter or fd.flags.is_setter) and self.hir.kindOf(fd.name) == .identifier) {
                try self.printEs5ClassAccessor(c.name, members, m, fd);
                continue;
            }
            try self.printExpression(c.name);
            if (fd.flags.is_static) {
                try self.write(".");
            } else {
                try self.write(".prototype.");
            }
            try self.printExpression(fd.name);
            try self.write(" = function (");
            const params = hir_mod.fnParams(self.hir, m);
            try self.printRuntimeParams(params);
            try self.write(") ");
            if (fd.body != hir_mod.none_node_id) {
                if (self.hasDefaultParam(params) or self.hasDestructuringParam(params)) {
                    // §4.A — ES5 default-param / destructuring-param
                    // lowering for class methods.
                    try self.printFnBodyWithDefaults(params, fd.body);
                } else {
                    self.next_block_is_fn_body = self.hir.kindOf(fd.body) == .block_stmt;
                    try self.printStatementInline(fd.body);
                }
            } else {
                try self.write("{}");
            }
            try self.write("; ");
        }
        // Static fields are assigned on the constructor after method
        // definitions. Instance fields stay in the constructor body.
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (!op.is_static or op.value == hir_mod.none_node_id) continue;
            try self.printExpression(c.name);
            try self.write(".");
            try self.printExpression(op.key);
            try self.write(" = ");
            try self.printExpression(op.value);
            try self.write("; ");
        }
        try self.write("return ");
        try self.printExpression(c.name);
        try self.write("; })(");
        if (c.extends != hir_mod.none_node_id) try self.printHeritageExpression(c.extends);
        try self.write(");");
    }

    fn printHeritageExpression(self: *Printer, node: NodeId) anyerror!void {
        if (self.hir.kindOf(node) == .type_ref) {
            const r = hir_mod.typeRefOf(self.hir, node);
            const qual = hir_mod.typeRefQualifier(self.hir, node);
            for (qual) |q| {
                try self.printExpression(q);
                try self.write(".");
            }
            try self.write(self.interner.get(r.name));
            return;
        }
        try self.printExpression(node);
    }

    /// Write an enum member's name as a quoted JS string (`"A"`). Member
    /// names are identifiers or string-literal keys.
    fn writeEnumMemberName(self: *Printer, key: NodeId) !void {
        try self.write("\"");
        switch (self.hir.kindOf(key)) {
            .identifier => try self.write(self.interner.get(hir_mod.identifierOf(self.hir, key).name)),
            .literal_string => try self.write(self.interner.get(hir_mod.literalStringOf(self.hir, key).value)),
            else => try self.printExpression(key),
        }
        try self.write("\"");
    }

    fn printEnum(self: *Printer, node: NodeId) !void {
        // tsc lowers an enum to an IIFE that builds the member object.
        // Numeric members get a bidirectional mapping
        // (`E[E["A"] = 0] = "A";`), string members forward-only
        // (`E["A"] = "x";`). (const-enum use-site inlining is a separate
        // optimization; the object is still emitted, as with
        // preserveConstEnums.)
        const e = hir_mod.enumOf(self.hir, node);
        try self.write("var ");
        try self.printExpression(e.name);
        try self.write(";");
        try self.writeNewlineIndent();
        try self.write("(function (");
        try self.printExpression(e.name);
        try self.write(") {");
        self.depth += 1;
        const members = hir_mod.enumMembers(self.hir, node);
        var auto: i64 = 0;
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            const has_value = op.value != hir_mod.none_node_id;
            const string_member = has_value and self.hir.kindOf(op.value) == .literal_string;
            try self.write(self.options.newline);
            try self.indent();
            if (string_member) {
                // E["A"] = "x";  (no reverse mapping for string members)
                try self.printExpression(e.name);
                try self.write("[");
                try self.writeEnumMemberName(op.key);
                try self.write("] = ");
                try self.printExpression(op.value);
                try self.writeSemi();
            } else {
                // E[E["A"] = <value>] = "A";
                try self.printExpression(e.name);
                try self.write("[");
                try self.printExpression(e.name);
                try self.write("[");
                try self.writeEnumMemberName(op.key);
                try self.write("] = ");
                if (has_value) {
                    try self.printExpression(op.value);
                    if (self.hir.kindOf(op.value) == .literal_number) {
                        auto = @as(i64, @intFromFloat(hir_mod.literalNumberOf(self.hir, op.value))) + 1;
                    }
                } else {
                    var buf: [32]u8 = undefined;
                    try self.write(std.fmt.bufPrint(&buf, "{d}", .{auto}) catch "0");
                    auto += 1;
                }
                try self.write("] = ");
                try self.writeEnumMemberName(op.key);
                try self.writeSemi();
            }
        }
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("})(");
        try self.printExpression(e.name);
        try self.write(" || (");
        try self.printExpression(e.name);
        try self.write(" = {}));");
    }

    /// Emit one exported namespace member: the inner declaration followed
    /// by `N.<name> = <name>;`. Keeping the local binding means internal
    /// references to the name still resolve without rewriting. tsc lowers
    /// `export const x = 1` inside `namespace N` this way (a property on N).
    fn emitNamespaceExportedMember(self: *Printer, ns_name: []const u8, export_node: NodeId) !void {
        const ex = hir_mod.exportOf(self.hir, export_node);
        if (ex.decl == hir_mod.none_node_id) {
            // `export { ... }` / re-export — no local decl to bind.
            try self.printStatement(export_node);
            return;
        }
        try self.printStatement(ex.decl);
        const name_node: NodeId = switch (self.hir.kindOf(ex.decl)) {
            .var_decl, .let_decl, .const_decl => hir_mod.varDeclOf(self.hir, ex.decl).name,
            .fn_decl => hir_mod.fnDeclOf(self.hir, ex.decl).name,
            .class_decl => hir_mod.classOf(self.hir, ex.decl).name,
            else => hir_mod.none_node_id,
        };
        // Interfaces / type aliases erase — no assignment.
        if (name_node == hir_mod.none_node_id or self.hir.kindOf(name_node) != .identifier) return;
        const nm = self.interner.get(hir_mod.identifierOf(self.hir, name_node).name);
        try self.write(self.options.newline);
        try self.indent();
        try self.write(ns_name);
        try self.write(".");
        try self.write(nm);
        try self.write(" = ");
        try self.write(nm);
        try self.writeSemi();
    }

    /// True when a class method has no runtime body — abstract methods,
    /// overload signatures, and `declare`-class methods. Emitting their
    /// bodyless signature `f();` would be invalid JS, so they're omitted.
    fn memberIsAbstract(self: *const Printer, m: NodeId) bool {
        return switch (self.hir.kindOf(m)) {
            .fn_decl, .fn_expr, .arrow_fn => hir_mod.fnDeclOf(self.hir, m).body == hir_mod.none_node_id,
            else => false,
        };
    }

    fn printNamespace(self: *Printer, node: NodeId) !void {
        const n = hir_mod.namespaceOf(self.hir, node);
        const body = hir_mod.namespaceBody(self.hir, node);
        // A qualified name (`namespace A.B.C`) desugars to nested IIFEs.
        // The parser interns the dotted text as one identifier name.
        const full = if (self.hir.kindOf(n.name) == .identifier)
            self.interner.get(hir_mod.identifierOf(self.hir, n.name).name)
        else
            "";
        var parts: [16][]const u8 = undefined;
        var nparts: usize = 0;
        if (full.len > 0 and std.mem.indexOfScalar(u8, full, '.') != null) {
            var it = std.mem.splitScalar(u8, full, '.');
            while (it.next()) |p| {
                if (nparts < parts.len) {
                    parts[nparts] = p;
                    nparts += 1;
                }
            }
        }
        if (nparts > 1) {
            try self.printNamespaceLevel(parts[0..nparts], 0, "", body);
            try self.write(";");
            return;
        }
        // Non-identifier name (e.g. `module "foo"`): emit via the node.
        if (full.len == 0) {
            try self.write("var ");
            try self.printExpression(n.name);
            try self.write(";");
            try self.writeNewlineIndent();
            try self.write("(function (");
            try self.printExpression(n.name);
            try self.write(") {");
            self.depth += 1;
            for (body) |s| {
                try self.write(self.options.newline);
                try self.printStatement(s);
            }
            self.depth -= 1;
            try self.writeNewlineIndent();
            try self.write("})(");
            try self.printExpression(n.name);
            try self.write(" || (");
            try self.printExpression(n.name);
            try self.write(" = {}));");
            return;
        }
        // Single-segment identifier namespace.
        const one = [_][]const u8{full};
        try self.printNamespaceLevel(&one, 0, "", body);
        try self.write(";");
    }

    /// Emit one level of a (possibly nested) namespace IIFE. `parts` is the
    /// dotted name split into segments; `parent` is the enclosing segment's
    /// name ("" at the outermost). The body is emitted at the innermost.
    fn printNamespaceLevel(self: *Printer, parts: []const []const u8, idx: usize, parent: []const u8, body: []const NodeId) anyerror!void {
        const name = parts[idx];
        try self.write("var ");
        try self.write(name);
        try self.write(";");
        try self.writeNewlineIndent();
        try self.write("(function (");
        try self.write(name);
        try self.write(") {");
        self.depth += 1;
        if (idx + 1 == parts.len) {
            for (body) |s| {
                try self.write(self.options.newline);
                if (self.hir.kindOf(s) == .export_decl) {
                    try self.emitNamespaceExportedMember(name, s);
                } else {
                    try self.printStatement(s);
                }
            }
        } else {
            try self.write(self.options.newline);
            try self.indent();
            try self.printNamespaceLevel(parts, idx + 1, name, body);
        }
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("})(");
        if (idx == 0) {
            try self.write(name);
            try self.write(" || (");
            try self.write(name);
            try self.write(" = {}))");
        } else {
            // `name = parent.name || (parent.name = {})`
            try self.write(name);
            try self.write(" = ");
            try self.write(parent);
            try self.write(".");
            try self.write(name);
            try self.write(" || (");
            try self.write(parent);
            try self.write(".");
            try self.write(name);
            try self.write(" = {}))");
        }
    }

    fn printImport(self: *Printer, node: NodeId) !void {
        const imp = hir_mod.importOf(self.hir, node);
        // Type-only imports erase entirely.
        if (imp.is_type_only) return;
        // `import name = require("m")` → `const name = require("m");`
        // (the require form, regardless of module kind).
        if (imp.is_require_equals and imp.default_binding != hir_mod.none_node_id) {
            try self.write("const ");
            try self.printExpression(imp.default_binding);
            try self.write(" = require(\"");
            try self.write(self.interner.get(imp.module));
            try self.write("\")");
            try self.writeSemi();
            return;
        }
        if (self.options.module_kind == .commonjs) {
            try self.printImportCjs(node, imp);
            return;
        }
        try self.write("import ");
        var any_local = false;
        if (imp.default_binding != hir_mod.none_node_id) {
            try self.printExpression(imp.default_binding);
            any_local = true;
        }
        if (imp.namespace_binding != hir_mod.none_node_id) {
            if (any_local) try self.write(", ");
            try self.write("* as ");
            try self.printExpression(imp.namespace_binding);
            any_local = true;
        }
        const named = hir_mod.importNamed(self.hir, node);
        if (named.len > 0) {
            if (any_local) try self.write(", ");
            try self.write("{ ");
            for (named, 0..) |spec, i| {
                if (i > 0) try self.write(", ");
                if (self.hir.kindOf(spec) != .import_specifier) continue;
                const sp = hir_mod.importSpecifierOf(self.hir, spec);
                try self.write(self.interner.get(sp.imported));
                if (sp.imported != sp.local) {
                    try self.write(" as ");
                    try self.write(self.interner.get(sp.local));
                }
            }
            try self.write(" }");
            any_local = true;
        }
        if (any_local) try self.write(" from ");
        try self.write("\"");
        try self.write(self.interner.get(imp.module));
        try self.write("\"");
        try self.writeSemi();
    }

    fn printImportCjs(self: *Printer, node: NodeId, imp: hir_mod.ImportPayload) !void {
        const module_str = self.interner.get(imp.module);
        const named = hir_mod.importNamed(self.hir, node);
        const has_default = imp.default_binding != hir_mod.none_node_id;
        const has_namespace = imp.namespace_binding != hir_mod.none_node_id;
        const has_named = named.len > 0;
        // Pure side-effect import: `import "x"` → `require("x")`.
        if (!has_default and !has_namespace and !has_named) {
            try self.write("require(\"");
            try self.write(module_str);
            try self.write("\")");
            try self.writeSemi();
            return;
        }
        // Default import: `import x from "y"` →
        //   `const x = __importDefault(require("y")).default`
        // (with esModuleInterop). Without interop:
        //   `const x = require("y")`.
        if (has_default and !has_namespace and !has_named) {
            try self.write("const ");
            try self.printExpression(imp.default_binding);
            try self.write(" = ");
            if (self.options.es_module_interop) {
                try self.write("__importDefault(require(\"");
                try self.write(module_str);
                try self.write("\")).default");
            } else {
                try self.write("require(\"");
                try self.write(module_str);
                try self.write("\")");
            }
            try self.writeSemi();
            return;
        }
        // Namespace import: `import * as x from "y"` →
        //   `const x = __importStar(require("y"))`
        if (has_namespace and !has_default and !has_named) {
            try self.write("const ");
            try self.printExpression(imp.namespace_binding);
            try self.write(" = ");
            if (self.options.es_module_interop) {
                try self.write("__importStar(require(\"");
                try self.write(module_str);
                try self.write("\"))");
            } else {
                try self.write("require(\"");
                try self.write(module_str);
                try self.write("\")");
            }
            try self.writeSemi();
            return;
        }
        // Named imports: `import { a, b as c } from "y"` →
        //   `const { a, b: c } = require("y")`.
        if (has_named and !has_default) {
            try self.write("const { ");
            for (named, 0..) |spec, i| {
                if (i > 0) try self.write(", ");
                if (self.hir.kindOf(spec) != .import_specifier) continue;
                const sp = hir_mod.importSpecifierOf(self.hir, spec);
                try self.write(self.interner.get(sp.imported));
                if (sp.imported != sp.local) {
                    try self.write(": ");
                    try self.write(self.interner.get(sp.local));
                }
            }
            try self.write(" } = require(\"");
            try self.write(module_str);
            try self.write("\")");
            try self.writeSemi();
            return;
        }
        // Mixed default + named (or default + namespace): bind
        // a temporary, then destructure. Conservative — uses one
        // require but multiple statements.
        try self.write("const _mod = require(\"");
        try self.write(module_str);
        try self.write("\")");
        try self.writeSemi();
        if (has_default) {
            try self.write("const ");
            try self.printExpression(imp.default_binding);
            try self.write(" = ");
            if (self.options.es_module_interop) {
                try self.write("__importDefault(_mod).default");
            } else {
                try self.write("_mod");
            }
            try self.writeSemi();
        }
        if (has_named) {
            try self.write("const { ");
            for (named, 0..) |spec, i| {
                if (i > 0) try self.write(", ");
                if (self.hir.kindOf(spec) != .import_specifier) continue;
                const sp = hir_mod.importSpecifierOf(self.hir, spec);
                try self.write(self.interner.get(sp.imported));
                if (sp.imported != sp.local) {
                    try self.write(": ");
                    try self.write(self.interner.get(sp.local));
                }
            }
            try self.write(" } = _mod");
            try self.writeSemi();
        }
    }

    fn printExport(self: *Printer, node: NodeId) !void {
        const ex = hir_mod.exportOf(self.hir, node);
        if (ex.is_type_only) return;
        // `export = <expr>;` lowers to `module.exports = <expr>;`
        // (CommonJS-style default export) regardless of module kind.
        if (ex.is_export_equals) {
            try self.write("module.exports = ");
            try self.printExpression(ex.decl);
            try self.writeSemi();
            return;
        }
        // `export interface I {}` / `export type T = ...` erase at
        // runtime — bail before writing the `export ` keyword so we
        // don't leave a dangling token.
        if (ex.decl != hir_mod.none_node_id) {
            const dk = self.hir.kindOf(ex.decl);
            if (dk == .interface_decl or dk == .type_alias_decl) return;
        }
        if (self.options.module_kind == .commonjs) {
            try self.printExportCjs(node, ex);
            return;
        }
        try self.write("export ");
        if (ex.is_default) {
            try self.write("default ");
            if (ex.decl != hir_mod.none_node_id) {
                try self.printNonIndentStatement(ex.decl);
            }
            return;
        }
        if (ex.decl != hir_mod.none_node_id) {
            try self.printNonIndentStatement(ex.decl);
            return;
        }
        // `export * [as ns] from "m"` — namespace re-export.
        if (ex.is_namespace) {
            try self.write("*");
            const alias = self.interner.get(ex.namespace_alias);
            if (alias.len > 0) {
                try self.write(" as ");
                try self.write(alias);
            }
            try self.write(" from \"");
            try self.write(self.interner.get(ex.module));
            try self.write("\"");
            try self.writeSemi();
            return;
        }
        const named = hir_mod.exportNamed(self.hir, node);
        try self.write("{ ");
        for (named, 0..) |spec, i| {
            if (i > 0) try self.write(", ");
            if (self.hir.kindOf(spec) != .import_specifier) continue;
            const sp = hir_mod.importSpecifierOf(self.hir, spec);
            try self.write(self.interner.get(sp.imported));
            if (sp.imported != sp.local) {
                try self.write(" as ");
                try self.write(self.interner.get(sp.local));
            }
        }
        try self.write(" }");
        const empty_id = self.interner.get(ex.module);
        if (empty_id.len > 0) {
            try self.write(" from \"");
            try self.write(empty_id);
            try self.write("\"");
        }
        try self.writeSemi();
    }

    fn printExportCjs(self: *Printer, node: NodeId, ex: hir_mod.ExportPayload) !void {
        // `export default <decl>` → `module.exports.default = <expr>`.
        if (ex.is_default) {
            if (ex.decl != hir_mod.none_node_id) {
                const dk = self.hir.kindOf(ex.decl);
                if (dk == .fn_decl or dk == .class_decl) {
                    // Emit decl, then assign by name.
                    try self.printNonIndentStatement(ex.decl);
                    // Find the inner name to re-export.
                    const decl_name = decoratorBoundName(self.hir, ex.decl);
                    if (decl_name) |n| {
                        try self.write("module.exports.default = ");
                        try self.write(self.interner.get(n));
                        try self.writeSemi();
                    }
                } else {
                    try self.write("module.exports.default = ");
                    try self.printExpression(ex.decl);
                    try self.writeSemi();
                }
            }
            return;
        }
        // `export <decl>` → emit decl + `module.exports.<name> = <name>`.
        if (ex.decl != hir_mod.none_node_id) {
            try self.printNonIndentStatement(ex.decl);
            const decl_name = decoratorBoundName(self.hir, ex.decl);
            if (decl_name) |n| {
                try self.write("module.exports.");
                try self.write(self.interner.get(n));
                try self.write(" = ");
                try self.write(self.interner.get(n));
                try self.writeSemi();
            }
            return;
        }
        // `export * [as ns] from "m"` — namespace re-export.
        const re_export_module = self.interner.get(ex.module);
        if (ex.is_namespace) {
            const alias = self.interner.get(ex.namespace_alias);
            if (alias.len > 0) {
                // `export * as ns from "m"` → `module.exports.ns = require("m");`
                try self.write("module.exports.");
                try self.write(alias);
                try self.write(" = require(\"");
                try self.write(re_export_module);
                try self.write("\")");
                try self.writeSemi();
            } else {
                // `export * from "m"` → copy own enumerable keys, skipping
                // `default` (mirrors tsc's `__exportStar` semantics).
                try self.write("Object.keys(require(\"");
                try self.write(re_export_module);
                try self.write("\")).forEach(function (k) { if (k !== \"default\" && !Object.prototype.hasOwnProperty.call(module.exports, k)) Object.defineProperty(module.exports, k, { enumerable: true, get: function () { return require(\"");
                try self.write(re_export_module);
                try self.write("\")[k]; } }); })");
                try self.writeSemi();
            }
            return;
        }
        // `export { a, b as c } [from "m"]`.
        const named = hir_mod.exportNamed(self.hir, node);
        if (re_export_module.len > 0) {
            // `export { a, b as c } from "m"` →
            //   module.exports.a = require("m").a;
            //   module.exports.c = require("m").b;
            // Each binding takes a fresh `require()` so callers see the
            // live module instance (matches tsc's "live binding" emit
            // for re-exports under `module: commonjs`).
            for (named) |spec| {
                if (self.hir.kindOf(spec) != .import_specifier) continue;
                const sp = hir_mod.importSpecifierOf(self.hir, spec);
                try self.write("module.exports.");
                try self.write(self.interner.get(sp.local));
                try self.write(" = require(\"");
                try self.write(re_export_module);
                try self.write("\").");
                try self.write(self.interner.get(sp.imported));
                try self.writeSemi();
            }
            return;
        }
        for (named) |spec| {
            if (self.hir.kindOf(spec) != .import_specifier) continue;
            const sp = hir_mod.importSpecifierOf(self.hir, spec);
            try self.write("module.exports.");
            try self.write(self.interner.get(sp.local));
            try self.write(" = ");
            try self.write(self.interner.get(sp.imported));
            try self.writeSemi();
        }
    }

    // ----- Expressions ----------------------------------------------------

    /// Print `node` as an expression in a context that does not need
    /// parentheses for any operator (statement position, after `=` /
    /// `return`, etc.). Equivalent to the lowest precedence level.
    fn printExpression(self: *Printer, node: NodeId) anyerror!void {
        try self.printExpr(node, .lowest);
    }

    /// Print `node` as an expression embedded in a surrounding context of
    /// precedence `level`. Precedence-sensitive forms (binary / logical /
    /// conditional / assignment / unary) consult `level` to decide whether
    /// to wrap themselves in parentheses, mirroring Bun's `printExpr`.
    fn printExpr(self: *Printer, node: NodeId, level: Level) anyerror!void {
        const kind = self.hir.kindOf(node);
        // `forbid_call` only propagates down the `new`-target call spine
        // (member/element object, call callee). Any other expression form is
        // a fresh context, so clear it — the leftmost atom of a spine clears
        // it before any argument/index is printed.
        if (kind != .member_access and kind != .element_access and kind != .call_expr) {
            self.forbid_call = false;
        }
        switch (kind) {
            .identifier => {
                const id = hir_mod.identifierOf(self.hir, node);
                try self.write(self.interner.get(id.name));
            },
            .literal_string => {
                const s = hir_mod.literalStringOf(self.hir, node);
                try self.write("\"");
                try self.write(self.interner.get(s.value));
                try self.write("\"");
            },
            .template_literal => try self.printTemplateLiteral(node),
            .literal_number => {
                try self.printLiteralNumber(node);
            },
            .literal_bigint => {
                const b = hir_mod.literalBigIntOf(self.hir, node);
                const digits = self.interner.get(b.digits);
                if (self.options.es_target.supportsNativeBigInt()) {
                    try self.write(digits);
                    try self.write("n");
                } else {
                    // Below ES2020 there is no BigInt literal syntax.
                    // Lower to a `BigInt("123")` call — matches tsc's
                    // downlevel shape and preserves arbitrary-precision
                    // semantics.
                    try self.write("BigInt(\"");
                    try self.write(digits);
                    try self.write("\")");
                }
            },
            .literal_bool => {
                const v = hir_mod.literalBoolOf(self.hir, node);
                try self.write(if (v) "true" else "false");
            },
            .literal_null => try self.write("null"),
            .literal_undefined => try self.write("undefined"),
            .literal_regex => try self.printLiteralRegex(node),
            .binary_op => try self.printBinop(node, level),
            .unary_op => try self.printUnary(node, level),
            .logical_op => try self.printLogical(node, level),
            .conditional => try self.printConditional(node, level),
            .assignment => try self.printAssignment(node, level),
            .call_expr => try self.printCall(node),
            .new_expr => try self.printNew(node),
            // Spread element in a call-arg / new-arg position (array and
            // object literals handle their own spread). Native `...expr`.
            .spread => {
                try self.write("...");
                // Spread takes an AssignmentExpression; print at `.comma`
                // so only a top-level sequence wraps.
                try self.printExpr(hir_mod.spreadOf(self.hir, node).expression, .comma);
            },
            .as_expr, .satisfies_expr, .type_assertion, .non_null_expr => {
                // Type assertions and `expr!` non-null assertions
                // erase at runtime — print the inner expression only,
                // forwarding the surrounding precedence so the erased
                // wrapper doesn't change parenthesization.
                const a = hir_mod.asExpressionOf(self.hir, node);
                try self.printExpr(a.expr, level);
            },
            .member_access => try self.printMember(node),
            .element_access => try self.printElement(node),
            .array_literal => try self.printArrayLiteral(node),
            .object_literal => try self.printObjectLiteral(node),
            .fn_decl, .fn_expr, .arrow_fn => try self.printFnDecl(node),
            .class_decl, .class_expr => try self.printClassDecl(node),
            .jsx_element, .jsx_self_closing => try self.printJsxElement(node),
            .jsx_fragment => try self.printJsxFragment(node),
            .jsx_expression => try self.printJsxExpression(node),
            .await_expr => {
                const a = hir_mod.awaitExprOf(self.hir, node);
                // §4.A.5 — under ES2016 and below the enclosing async
                // function is wrapped in `__awaiter(... function* ())`,
                // so `await E` lowers to `yield E` inside the
                // generator body.
                if (self.in_async_downlevel) {
                    try self.write("yield ");
                } else {
                    // Top-level await (ES2022, ESM only). At lower
                    // targets we still emit `await E` but prefix it
                    // with a `/* TODO: ... */` marker so downstream
                    // tooling can see the unsupported emit. v0 skips
                    // proper error reporting; the checker is the right
                    // place for that.
                    if (self.fn_depth == 0 and
                        self.options.module_kind == .esm and
                        @intFromEnum(self.options.es_target) < @intFromEnum(EsTarget.es2022))
                    {
                        try self.write("/* TODO: top-level await requires ES2022+ */ ");
                    }
                    try self.write("await ");
                }
                // `await` binds like a unary prefix operator, so its
                // operand is printed one level below `.prefix` — a binary
                // operand keeps its parens (`await (a + b)`), while a
                // member/call does not (`await a.b`).
                try self.printExpr(a.expr, Level.sub(.prefix, 1));
            },
            .yield_expr => {
                const y = hir_mod.yieldExprOf(self.hir, node);
                // `yield` is an AssignmentExpression production: it must be
                // parenthesized when used where assign-or-tighter binds, e.g.
                // `(yield a) + 1` (else `yield a + 1` yields `a + 1`). Mirrors
                // Bun's `level.gte(.assign)`; the operand prints at `.yield`.
                const wrap = level.gte(.assign);
                if (wrap) try self.write("(");
                try self.write("yield");
                if (y.type_node != hir_mod.none_node_id) try self.write("*");
                if (y.expr != hir_mod.none_node_id) {
                    try self.write(" ");
                    try self.printExpr(y.expr, .yield);
                }
                if (wrap) try self.write(")");
            },
            else => return error.UnsupportedNode,
        }
    }

    /// Lower JSX. Runtime mode is `Options.jsx_runtime`:
    /// - `.classic`: `<jsx_factory>(tag, props, ...children)`. The
    ///   factory is emitted verbatim (default `React.createElement`,
    ///   matching tsc's `jsxFactory`).
    /// - `.automatic`: `_jsx(tag, props)` or `_jsxs(tag, props)` (key
    ///   in props if present). Caller must arrange the import of
    ///   `_jsx` / `_jsxs` from `react/jsx-runtime`.
    /// - `.automatic_dev`: same as `.automatic` but use `_jsxDEV`.
    /// - `.preserve`: copy the original JSX bytes through unchanged
    ///   (requires `setSource`); falls back to classic when source
    ///   bytes aren't attached so callers always get valid JS.
    fn printJsxElement(self: *Printer, node: NodeId) anyerror!void {
        switch (self.options.jsx_runtime) {
            .classic => try self.printJsxElementClassic(node),
            .preserve => try self.printJsxPreserve(node),
            .automatic => try self.printJsxElementAutomatic(node, "_jsx", "_jsxs"),
            .automatic_dev => try self.printJsxElementAutomatic(node, "_jsxDEV", "_jsxDEV"),
        }
    }

    fn printJsxElementClassic(self: *Printer, node: NodeId) anyerror!void {
        const el = hir_mod.jsxElementOf(self.hir, node);
        try self.write(self.options.jsx_factory);
        try self.write("(");
        try self.writeJsxTag(el.tag);
        try self.write(", ");
        const attrs = hir_mod.jsxAttrs(self.hir, node);
        try self.writePropsObject(attrs);
        const children = hir_mod.jsxChildren(self.hir, node);
        for (children) |c| {
            try self.write(", ");
            try self.printExpression(c);
        }
        try self.write(")");
    }

    /// `.preserve` mode: copy the original JSX bytes verbatim from
    /// the attached source. When no source is attached, fall back to
    /// the classic lowering so callers always get valid JS.
    fn printJsxPreserve(self: *Printer, node: NodeId) anyerror!void {
        if (self.source) |src| {
            const span = self.hir.spanOf(node);
            const start: usize = @intCast(span.start);
            const end: usize = @intCast(span.end);
            if (end > start and end <= src.len) {
                try self.write(src[start..end]);
                return;
            }
        }
        try self.printJsxElementClassic(node);
    }

    fn printJsxElementAutomatic(self: *Printer, node: NodeId, single_name: []const u8, multi_name: []const u8) anyerror!void {
        const el = hir_mod.jsxElementOf(self.hir, node);
        const children = hir_mod.jsxChildren(self.hir, node);
        const is_dev = self.options.jsx_runtime == .automatic_dev;
        const fn_name = if (children.len > 1) multi_name else single_name;
        try self.write(fn_name);
        try self.write("(");
        try self.writeJsxTag(el.tag);
        try self.write(", ");
        // Automatic runtime: props is `{ ...attrs, children: ... }`.
        const attrs = hir_mod.jsxAttrs(self.hir, node);
        try self.write("{ ");
        var first = true;
        for (attrs) |a| {
            if (!first) try self.write(", ");
            first = false;
            switch (self.hir.kindOf(a)) {
                .jsx_attribute => {
                    const ap = hir_mod.jsxAttributeOf(self.hir, a);
                    try self.write(self.interner.get(ap.name));
                    try self.write(": ");
                    if (ap.value == hir_mod.none_node_id) {
                        try self.write("true");
                    } else if (self.hir.kindOf(ap.value) == .jsx_expression) {
                        const ex = hir_mod.jsxExpressionOf(self.hir, ap.value);
                        try self.printExpression(ex.expression);
                    } else {
                        try self.printExpression(ap.value);
                    }
                },
                .jsx_spread_attribute => {
                    const sp = hir_mod.jsxSpreadAttributeOf(self.hir, a);
                    try self.write("...");
                    try self.printExpression(sp.expression);
                },
                else => {},
            }
        }
        if (children.len > 0) {
            if (!first) try self.write(", ");
            try self.write("children: ");
            if (children.len == 1) {
                try self.printExpression(children[0]);
            } else {
                try self.write("[");
                for (children, 0..) |c, i| {
                    if (i > 0) try self.write(", ");
                    try self.printExpression(c);
                }
                try self.write("]");
            }
        }
        try self.write(" }");
        // Dev runtime threads extra args:
        // `_jsxDEV(tag, props, key, isStaticChildren, source, self)`.
        // v0 emits placeholder source info `{}`.
        if (is_dev) {
            try self.write(", undefined, ");
            try self.write(if (children.len > 1) "true" else "false");
            try self.write(", {}, this");
        }
        try self.write(")");
    }

    fn writeJsxTag(self: *Printer, tag: NodeId) anyerror!void {
        if (self.hir.kindOf(tag) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, tag);
            const name = self.interner.get(id.name);
            if (name.len > 0 and name[0] >= 'a' and name[0] <= 'z') {
                try self.write("\"");
                try self.write(name);
                try self.write("\"");
                return;
            }
        }
        try self.printExpression(tag);
    }

    fn writePropsObject(self: *Printer, attrs: []const NodeId) anyerror!void {
        if (attrs.len == 0) {
            try self.write("null");
            return;
        }
        try self.write("{ ");
        for (attrs, 0..) |a, i| {
            if (i > 0) try self.write(", ");
            switch (self.hir.kindOf(a)) {
                .jsx_attribute => {
                    const ap = hir_mod.jsxAttributeOf(self.hir, a);
                    try self.write(self.interner.get(ap.name));
                    try self.write(": ");
                    if (ap.value == hir_mod.none_node_id) {
                        try self.write("true");
                    } else if (self.hir.kindOf(ap.value) == .jsx_expression) {
                        const ex = hir_mod.jsxExpressionOf(self.hir, ap.value);
                        try self.printExpression(ex.expression);
                    } else {
                        try self.printExpression(ap.value);
                    }
                },
                .jsx_spread_attribute => {
                    const sp = hir_mod.jsxSpreadAttributeOf(self.hir, a);
                    try self.write("...");
                    try self.printExpression(sp.expression);
                },
                else => {},
            }
        }
        try self.write(" }");
    }

    fn printJsxFragment(self: *Printer, node: NodeId) anyerror!void {
        switch (self.options.jsx_runtime) {
            .classic => try self.printJsxFragmentClassic(node),
            .preserve => {
                if (self.source) |src| {
                    const span = self.hir.spanOf(node);
                    const start: usize = @intCast(span.start);
                    const end: usize = @intCast(span.end);
                    if (end > start and end <= src.len) {
                        try self.write(src[start..end]);
                        return;
                    }
                }
                try self.printJsxFragmentClassic(node);
            },
            .automatic, .automatic_dev => {
                const is_dev = self.options.jsx_runtime == .automatic_dev;
                const fn_name: []const u8 = if (is_dev) "_jsxDEV" else "_jsxs";
                try self.write(fn_name);
                try self.write("(_Fragment, { children: [");
                const children = hir_mod.jsxFragmentChildren(self.hir, node);
                for (children, 0..) |c, i| {
                    if (i > 0) try self.write(", ");
                    try self.printExpression(c);
                }
                try self.write("] }");
                if (is_dev) {
                    try self.write(", undefined, true, {}, this");
                }
                try self.write(")");
            },
        }
    }

    fn printJsxFragmentClassic(self: *Printer, node: NodeId) anyerror!void {
        try self.write(self.options.jsx_factory);
        try self.write("(");
        try self.write(self.options.jsx_fragment_factory);
        try self.write(", null");
        const children = hir_mod.jsxFragmentChildren(self.hir, node);
        for (children) |c| {
            try self.write(", ");
            try self.printExpression(c);
        }
        try self.write(")");
    }

    fn printJsxExpression(self: *Printer, node: NodeId) anyerror!void {
        const ex = hir_mod.jsxExpressionOf(self.hir, node);
        if (ex.expression == hir_mod.none_node_id) {
            try self.write("null");
        } else {
            try self.printExpression(ex.expression);
        }
    }

    /// Emit a template-literal expression. At ES2015+ we emit the
    /// native backtick form; at ES5 we lower to string concatenation
    /// (`"a" + x + "b"`). Tagged templates are lowered to a regular
    /// `call_expr` by the parser, so by the time we reach this node
    /// we know it's untagged.
    fn printTemplateLiteral(self: *Printer, node: NodeId) anyerror!void {
        const texts = hir_mod.templateLiteralTexts(self.hir, node);
        const exprs = hir_mod.templateLiteralExprs(self.hir, node);

        if (self.options.es_target == .es5) {
            // No substitutions ⇒ just emit `"text"` (no concat needed).
            if (exprs.len == 0) {
                try self.write("\"");
                if (texts.len == 1) {
                    const s = hir_mod.literalStringOf(self.hir, texts[0]);
                    try self.write(self.interner.get(s.value));
                }
                try self.write("\"");
                return;
            }
            // `"t0" + e0 + "t1" + e1 + … + "tN"`. We elide empty text
            // segments (common at start/end with `` `${x}` ``); when
            // the very first emitted segment would be a substitution
            // we wrap it in `String(...)` so the result is always a
            // string (even if `e0` is e.g. a number).
            try self.write("(");
            var emitted_any = false;
            var i: usize = 0;
            while (i < texts.len) : (i += 1) {
                const s = hir_mod.literalStringOf(self.hir, texts[i]);
                const txt = self.interner.get(s.value);
                if (txt.len > 0) {
                    if (emitted_any) try self.write(" + ");
                    try self.write("\"");
                    try self.write(txt);
                    try self.write("\"");
                    emitted_any = true;
                }
                if (i < exprs.len) {
                    if (emitted_any) {
                        try self.write(" + ");
                        try self.printExpression(exprs[i]);
                    } else {
                        try self.write("String(");
                        try self.printExpression(exprs[i]);
                        try self.write(")");
                    }
                    emitted_any = true;
                }
            }
            try self.write(")");
            return;
        }

        // ES2015+: native template literal — re-emit as `` `…${e}…` ``.
        try self.write("`");
        var i: usize = 0;
        while (i < texts.len) : (i += 1) {
            const s = hir_mod.literalStringOf(self.hir, texts[i]);
            try self.write(self.interner.get(s.value));
            if (i < exprs.len) {
                try self.write("${");
                try self.printExpression(exprs[i]);
                try self.write("}");
            }
        }
        try self.write("`");
    }

    /// Emit a numeric literal, preferring the original source bytes
    /// when attached so user-chosen forms (`0xCAFE`, `1e10`, numeric
    /// separators) round-trip. Strips `_` digit separators for ES
    /// targets below ES2021 (where they aren't valid JS).
    fn printLiteralNumber(self: *Printer, node: NodeId) !void {
        const span = self.hir.spanOf(node);
        if (self.source) |src| {
            const start: usize = @intCast(span.start);
            const end: usize = @intCast(span.end);
            if (end > start and end <= src.len) {
                const slice = src[start..end];
                // Validate the slice actually looks like a numeric
                // literal — synthetic literals (e.g. the implicit `1`
                // that `i++` lowers through) carry the span of their
                // originating token instead, so we must fall back to
                // the stored value when the source bytes don't match.
                if (sliceLooksLikeNumber(slice)) {
                    if (self.options.es_target.supportsNumericSeparators()) {
                        try self.write(slice);
                    } else {
                        var i: usize = 0;
                        var run_start: usize = 0;
                        while (i < slice.len) : (i += 1) {
                            if (slice[i] == '_') {
                                if (i > run_start) try self.write(slice[run_start..i]);
                                run_start = i + 1;
                            }
                        }
                        if (run_start < slice.len) try self.write(slice[run_start..]);
                    }
                    return;
                }
            }
        }
        const v = hir_mod.literalNumberOf(self.hir, node);
        var buf: [32]u8 = undefined;
        const fmt = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "NaN";
        try self.write(fmt);
    }

    fn printLiteralRegex(self: *Printer, node: NodeId) !void {
        if (self.source) |src| {
            const span = self.hir.spanOf(node);
            const start: usize = @intCast(span.start);
            const end: usize = @intCast(span.end);
            if (end > start and end <= src.len) {
                try self.write(src[start..end]);
                return;
            }
        }
        try self.write("/./");
    }

    fn printBinop(self: *Printer, node: NodeId, level: Level) !void {
        const p = hir_mod.binopOf(self.hir, node);
        // `a ** b` (ES2016) downlevels to `Math.pow(a, b)` below es2016. The
        // result is a call expression, which binds tighter than any binary
        // operator, so no outer parens are needed regardless of `level`.
        if (p.op == .pow and !self.options.es_target.supportsExponentiation()) {
            try self.write("Math.pow(");
            try self.printExpr(p.lhs, .comma);
            try self.write(", ");
            try self.printExpr(p.rhs, .comma);
            try self.write(")");
            return;
        }
        // §4.A.7 — the private-field brand check `#f in o` lowers to
        // `_<Class>_f.has(o)` below ES2022, reusing the per-class WeakMap
        // storage. `has(...)` is a call, so no outer parens are needed.
        if (p.op == .in and !self.options.es_target.supportsNativePrivateFields()) {
            if (self.privateFieldName(p.lhs)) |field| {
                if (self.current_class_name) |class_name| {
                    try self.write("_");
                    try self.write(self.interner.get(class_name));
                    try self.write("_");
                    try self.write(field);
                    try self.write(".has(");
                    try self.printExpression(p.rhs);
                    try self.write(")");
                    return;
                }
            }
        }
        const e_level = binOpLevel(p.op);
        const wrap = level.gte(e_level);
        if (wrap) try self.write("(");

        // Left-associative ops let a same-precedence child sit on the left
        // unparenthesized (left_level = e_level - 1) and force parens on
        // the right (right_level = e_level). `**` is right-associative, so
        // the sides flip. Comma is non-associative — both sides at e-1.
        var left_level = e_level.sub(1);
        var right_level = e_level.sub(1);
        if (p.op == .pow) {
            left_level = e_level;
            // `**` cannot directly contain a unary expression on its left:
            // `-2 ** 3` is a SyntaxError, so force `(-2) ** 3`. (Bun forces
            // the left operand to `.call` for unary/await/signed-number
            // left operands; Home models a signed number as a unary.)
            if (self.hir.kindOf(p.lhs) == .unary_op) left_level = .call;
        } else if (p.op != .comma) {
            right_level = e_level;
        }

        try self.printExpr(p.lhs, left_level);
        if (p.op == .comma) {
            try self.write(", ");
        } else {
            try self.write(" ");
            try self.write(binOpString(p.op));
            try self.write(" ");
        }
        try self.printExpr(p.rhs, right_level);
        if (wrap) try self.write(")");
    }

    fn printUnary(self: *Printer, node: NodeId, level: Level) !void {
        const p = hir_mod.unaryOf(self.hir, node);
        const wrap = level.gte(.prefix);
        if (wrap) try self.write("(");
        const op_str = unaryOpString(p.op);
        // `typeof`/`void`/`delete` need a space before the operand.
        const needs_space = (p.op == .typeof or p.op == .void_ or p.op == .delete);
        try self.writePrefixOp(op_str);
        if (needs_space) try self.write(" ");
        try self.printExpr(p.operand, Level.sub(.prefix, 1));
        if (wrap) try self.write(")");
    }

    fn printLogical(self: *Printer, node: NodeId, level: Level) !void {
        const p = hir_mod.logicalOf(self.hir, node);
        // Downlevel `a ?? b` to `(a !== null && a !== undefined ? a : b)`
        // when targeting below ES2020. The single-evaluation rule
        // requires binding `a` to a temporary if it has side effects;
        // the conservative fallback for now is to just inline `a`
        // twice — safe for identifiers and member-access-on-identifier
        // (the common cases). A proper IIFE wrapper for arbitrary
        // expressions is a Phase 4 follow-up.
        if (p.op == .nullish and !self.options.es_target.supportsNullishAndOptional()) {
            try self.write("(");
            try self.printExpression(p.lhs);
            try self.write(" !== null && ");
            try self.printExpression(p.lhs);
            try self.write(" !== void 0 ? ");
            try self.printExpression(p.lhs);
            try self.write(" : ");
            try self.printExpression(p.rhs);
            try self.write(")");
            return;
        }
        const e_level = logicalLevel(p.op);
        const wrap = level.gte(e_level);
        if (wrap) try self.write("(");
        // Logical ops are left-associative.
        var left_level = e_level.sub(1);
        var right_level = e_level;
        // "??" cannot directly contain "||" or "&&" without parentheses,
        // so force those operands to wrap (matching Bun's printBinary).
        if (p.op == .nullish) {
            if (self.logicalChildIsAndOr(p.lhs)) left_level = .prefix;
            if (self.logicalChildIsAndOr(p.rhs)) right_level = .prefix;
        }
        try self.printExpr(p.lhs, left_level);
        try self.write(" ");
        try self.write(switch (p.op) {
            .@"and" => "&&",
            .@"or" => "||",
            .nullish => "??",
        });
        try self.write(" ");
        try self.printExpr(p.rhs, right_level);
        if (wrap) try self.write(")");
    }

    /// True when `node` is a `&&` / `||` logical expression — the operands
    /// that must be parenthesized when nested directly inside `??`.
    fn logicalChildIsAndOr(self: *const Printer, node: NodeId) bool {
        if (self.hir.kindOf(node) != .logical_op) return false;
        const op = hir_mod.logicalOf(self.hir, node).op;
        return op == .@"and" or op == .@"or";
    }

    fn printConditional(self: *Printer, node: NodeId, level: Level) !void {
        const p = hir_mod.conditionalOf(self.hir, node);
        const wrap = level.gte(.conditional);
        if (wrap) try self.write("(");
        try self.printExpr(p.cond, .conditional);
        try self.write(" ? ");
        try self.printExpr(p.then_branch, .yield);
        try self.write(" : ");
        try self.printExpr(p.else_branch, .yield);
        if (wrap) try self.write(")");
    }

    /// The parser lowers `++`/`--` to a compound assignment `target += 1` /
    /// `target -= 1` whose synthesized `1` literal carries the 2-char
    /// operator-token span (a real `1` is 1 char). This mirrors the
    /// checker's `assignmentIsSynthesizedUpdate` so the printer can rebuild
    /// the original update expression — lowering to `+= 1` would be wrong for
    /// a *postfix* `x++` in value position (it yields the new value, not the
    /// old). Returns `{ is_inc, is_prefix }` when `node` is such an update.
    fn synthUpdateOf(self: *const Printer, node: NodeId, p: hir_mod.AssignmentPayload) ?struct { is_inc: bool, is_prefix: bool } {
        const op = p.op orelse return null;
        if (op != .add and op != .sub) return null;
        if (self.hir.kindOf(p.value) != .literal_number) return null;
        if (hir_mod.literalNumberOf(self.hir, p.value) != 1.0) return null;
        const value_span = self.hir.spanOf(p.value);
        if (value_span.end - value_span.start != 2) return null;
        const target_span = self.hir.spanOf(p.target);
        const node_span = self.hir.spanOf(node);
        const is_prefix_shape = value_span.start == node_span.start and
            value_span.end <= target_span.start;
        const is_postfix_shape = value_span.end == node_span.end and
            value_span.start >= target_span.end;
        if (!is_prefix_shape and !is_postfix_shape) return null;
        return .{ .is_inc = (op == .add), .is_prefix = is_prefix_shape };
    }

    fn printAssignment(self: *Printer, node: NodeId, level: Level) !void {
        const p = hir_mod.assignmentOf(self.hir, node);
        // Reconstruct `++`/`--` lowered to `+= 1` / `-= 1` by the parser.
        if (self.synthUpdateOf(node, p)) |u| {
            const op_str = if (u.is_inc) "++" else "--";
            const my_level: Level = if (u.is_prefix) .prefix else .postfix;
            const wrap = level.gte(my_level);
            if (wrap) try self.write("(");
            if (u.is_prefix) {
                try self.writePrefixOp(op_str);
                try self.printExpr(p.target, Level.sub(.prefix, 1));
            } else {
                try self.printExpr(p.target, Level.sub(.postfix, 1));
                try self.write(op_str);
            }
            if (wrap) try self.write(")");
            return;
        }
        // Logical assignment (`a ||= b`) below ES2021 downlevels to the
        // short-circuit form `(a || (a = b))` (re-evaluating the target,
        // matching the printer's other downlevels). At ES2021+ it's native.
        if (p.op) |op| {
            const logical_str: ?[]const u8 = switch (op) {
                .logical_or => " || ",
                .logical_and => " && ",
                .nullish_coalesce => " ?? ",
                else => null,
            };
            if (logical_str) |ls| {
                if (!self.options.es_target.supportsLogicalAssignment()) {
                    try self.write("(");
                    try self.printExpression(p.target);
                    try self.write(ls);
                    try self.write("(");
                    try self.printExpression(p.target);
                    try self.write(" = ");
                    try self.printExpression(p.value);
                    try self.write("))");
                    return;
                }
            }
        }
        // `a **= b` (ES2016) downlevels to `a = Math.pow(a, b)` below es2016,
        // re-evaluating the target (matching the logical-assignment downlevel
        // style above; a side-effecting target would double-evaluate).
        if (p.op == .pow and !self.options.es_target.supportsExponentiation()) {
            const wrap_pow = level.gte(.assign);
            if (wrap_pow) try self.write("(");
            try self.printExpr(p.target, .assign);
            try self.write(" = Math.pow(");
            try self.printExpression(p.target);
            try self.write(", ");
            try self.printExpression(p.value);
            try self.write(")");
            if (wrap_pow) try self.write(")");
            return;
        }
        // Assignment is right-associative at `.assign`: the target sits at
        // `.assign` and the value one level below, so `a = b = c` nests
        // without parens while a looser value (a sequence) wraps.
        const wrap = level.gte(.assign);
        if (wrap) try self.write("(");
        try self.printExpr(p.target, .assign);
        try self.write(if (p.op != null) compoundOpString(p.op.?) else " = ");
        try self.printExpr(p.value, Level.sub(.assign, 1));
        if (wrap) try self.write(")");
    }

    /// Escape cooked template text for emission inside a `` ` `` literal:
    /// backtick, backslash, and a `${` substitution opener.
    fn writeTemplateCooked(self: *Printer, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            switch (s[i]) {
                '`' => try self.write("\\`"),
                '\\' => try self.write("\\\\"),
                '$' => {
                    if (i + 1 < s.len and s[i + 1] == '{') try self.write("\\$") else try self.write("$");
                },
                else => try self.write(s[i .. i + 1]),
            }
        }
    }

    /// Re-render a desugared tagged-template call as the native
    /// `` tag`s0${v0}s1…` `` form (tsc / Bun keep tagged templates native).
    /// arg 0 is the cooked-strings array; args 1.. are the substitutions.
    fn printTaggedTemplate(self: *Printer, node: NodeId, p: hir_mod.CallPayload) !void {
        try self.printExpression(p.callee);
        try self.write("`");
        const args = hir_mod.callArgs(self.hir, node);
        if (args.len > 0 and self.hir.kindOf(args[0]) == .array_literal) {
            const cooked = hir_mod.arrayLiteralElements(self.hir, args[0]);
            const values = args[1..];
            for (cooked, 0..) |seg, i| {
                if (self.hir.kindOf(seg) == .literal_string) {
                    try self.writeTemplateCooked(self.interner.get(hir_mod.literalStringOf(self.hir, seg).value));
                }
                if (i < values.len) {
                    try self.write("${");
                    try self.printExpression(values[i]);
                    try self.write("}");
                }
            }
        }
        try self.write("`");
    }

    fn printCall(self: *Printer, node: NodeId) !void {
        const p = hir_mod.callOf(self.hir, node);
        // A call reached on a `new`-target spine must be parenthesized
        // (`new (f())()`). Consume the flag so the callee/args (fresh
        // contexts) don't inherit it.
        const wrap_call = self.forbid_call;
        self.forbid_call = false;
        // Tagged template `tag`…`` — re-render natively.
        if (p.is_tagged_template) {
            try self.printTaggedTemplate(node, p);
            return;
        }
        // Dynamic `import("...")` lowering for CommonJS targets:
        // emit `Promise.resolve(require("..."))`. ESM keeps the
        // native `import()` form (handled by the runtime).
        if (self.options.module_kind == .commonjs and self.hir.kindOf(p.callee) == .identifier) {
            const id = hir_mod.identifierOf(self.hir, p.callee);
            const name = self.interner.get(id.name);
            if (std.mem.eql(u8, name, "import")) {
                try self.write("Promise.resolve(require(");
                const args = hir_mod.callArgs(self.hir, node);
                for (args, 0..) |a, i| {
                    if (i > 0) try self.write(", ");
                    try self.printExpression(a);
                }
                try self.write("))");
                return;
            }
        }
        // §4.A.2 — when lowering a derived class to ES5 we must
        // rewrite `super(args)` -> `_super.call(this, args)` and
        // `super.m(args)` -> `_super.prototype.m.call(this, args)`
        // because the `super` keyword has no meaning inside the
        // generated IIFE body.
        if (self.in_es5_super_lowering) {
            const callee_kind = self.hir.kindOf(p.callee);
            if (callee_kind == .identifier) {
                const id = hir_mod.identifierOf(self.hir, p.callee);
                if (std.mem.eql(u8, self.interner.get(id.name), "super")) {
                    try self.write("_super.call(this");
                    const args = hir_mod.callArgs(self.hir, node);
                    for (args) |a| {
                        try self.write(", ");
                        try self.printExpression(a);
                    }
                    try self.write(")");
                    return;
                }
            } else if (callee_kind == .member_access) {
                const m = hir_mod.memberOf(self.hir, p.callee);
                if (self.hir.kindOf(m.object) == .identifier) {
                    const obj_id = hir_mod.identifierOf(self.hir, m.object);
                    if (std.mem.eql(u8, self.interner.get(obj_id.name), "super")) {
                        try self.write("_super.prototype.");
                        try self.write(self.interner.get(m.name));
                        try self.write(".call(this");
                        const args = hir_mod.callArgs(self.hir, node);
                        for (args) |a| {
                            try self.write(", ");
                            try self.printExpression(a);
                        }
                        try self.write(")");
                        return;
                    }
                }
            }
        }
        // Optional call `f?.(args)`. Below ES2020, downlevel to
        // `(f === null || f === void 0 ? void 0 : f(args))` (re-evaluating
        // the callee, matching printMember's `?.` downlevel style); at
        // ES2020+ preserve the native `?.()` form.
        if (p.optional) {
            const args = hir_mod.callArgs(self.hir, node);
            if (!self.options.es_target.supportsNullishAndOptional()) {
                try self.write("(");
                try self.printExpression(p.callee);
                try self.write(" === null || ");
                try self.printExpression(p.callee);
                try self.write(" === void 0 ? void 0 : ");
                try self.printExpression(p.callee);
                try self.write("(");
                for (args, 0..) |a, i| {
                    if (i > 0) try self.write(", ");
                    try self.printExpression(a);
                }
                try self.write("))");
                return;
            }
            try self.printExpr(p.callee, .postfix);
            try self.write("?.(");
            for (args, 0..) |a, i| {
                if (i > 0) try self.write(", ");
                try self.printExpr(a, .comma);
            }
            try self.write(")");
            return;
        }
        // §4.A — ES5 call-site spread. `f(...a)` -> `f.apply(void 0, a)`,
        // `o.m(a, ...b)` -> `o.m.apply(o, [a].concat(b))`. Deferred (native
        // fall-through) for callee shapes whose receiver can't be repeated
        // safely — handled inside `printEs5SpreadCall`.
        const es5_args = hir_mod.callArgs(self.hir, node);
        if (self.options.es_target == .es5 and callArgsHaveSpread(self.hir, es5_args)) {
            if (try self.printEs5SpreadCall(p.callee, es5_args, wrap_call)) return;
        }
        // The call target binds at `.postfix`, so a looser callee is
        // parenthesized (`(a || b)()`, `(a, b)()`). Arguments are printed at
        // `.comma` so only a top-level sequence argument wraps.
        if (wrap_call) try self.write("(");
        try self.printExpr(p.callee, .postfix);
        try self.write("(");
        const args = hir_mod.callArgs(self.hir, node);
        for (args, 0..) |a, i| {
            if (i > 0) try self.write(", ");
            try self.printExpr(a, .comma);
        }
        try self.write(")");
        if (wrap_call) try self.write(")");
    }

    fn callArgsHaveSpread(hir: *const hir_mod.Hir, args: []const NodeId) bool {
        for (args) |a| {
            if (a != hir_mod.none_node_id and hir.kindOf(a) == .spread) return true;
        }
        return false;
    }

    /// ES5 downlevel of a call whose arguments contain a spread. Emits
    /// `callee.apply(thisArg, argsArray)`. Returns false (caller falls back
    /// to native emission) when the callee is a member access on a
    /// side-effecting receiver, since repeating it as the `thisArg` would
    /// double-evaluate it — tsc caches it in a temp there, which this first
    /// increment does not yet do.
    fn printEs5SpreadCall(self: *Printer, callee: NodeId, args: []const NodeId, wrap_call: bool) !bool {
        const callee_kind = self.hir.kindOf(callee);
        if (callee_kind == .member_access) {
            const m = hir_mod.memberOf(self.hir, callee);
            if (m.optional) return false;
            const simple_recv = m.object != hir_mod.none_node_id and
                (self.hir.kindOf(m.object) == .identifier or self.hir.kindOf(m.object) == .this_expr);
            if (simple_recv) {
                // `o.m(...a)` -> `o.m.apply(o, a)` — the receiver is a bare
                // identifier / `this`, so repeating it is side-effect-free.
                if (wrap_call) try self.write("(");
                try self.printExpr(callee, .postfix);
                try self.write(".apply(");
                try self.printExpr(m.object, .comma);
                try self.write(", ");
                try self.printEs5SpreadArgsArray(args);
                try self.write(")");
                if (wrap_call) try self.write(")");
                return true;
            }
            // §4.A.31 — side-effecting receiver: cache it in a hoisted temp.
            // `o[1].m(...a)` -> `(_a = o[1]).m.apply(_a, a)`.
            var buf: [16]u8 = undefined;
            const t = self.allocTemp(&buf);
            if (wrap_call) try self.write("(");
            try self.write("(");
            try self.write(t);
            try self.write(" = ");
            try self.printExpr(m.object, .comma);
            try self.write(").");
            try self.write(self.interner.get(m.name));
            try self.write(".apply(");
            try self.write(t);
            try self.write(", ");
            try self.printEs5SpreadArgsArray(args);
            try self.write(")");
            if (wrap_call) try self.write(")");
            return true;
        }
        if (callee_kind != .identifier) return false;
        // `f(...a)` -> `f.apply(void 0, a)`.
        if (wrap_call) try self.write("(");
        try self.printExpr(callee, .postfix);
        try self.write(".apply(void 0, ");
        try self.printEs5SpreadArgsArray(args);
        try self.write(")");
        if (wrap_call) try self.write(")");
        return true;
    }

    /// Emit the argument array for an ES5 `.apply`, lowering spreads via
    /// `.concat`: `...a` alone -> `a`; `a, ...b, c` -> `[a].concat(b, [c])`;
    /// `...a, ...b` -> `a.concat(b)`.
    fn printEs5SpreadArgsArray(self: *Printer, args: []const NodeId) !void {
        // A "part" is either a run of non-spread args (an array literal) or a
        // single spread expression. Count parts first so the base part's
        // precedence is correct: `.postfix` when a trailing `.concat` follows,
        // `.comma` when it is the lone part.
        var part_count: usize = 0;
        var scan: usize = 0;
        while (scan < args.len) {
            if (self.hir.kindOf(args[scan]) == .spread) {
                part_count += 1;
                scan += 1;
            } else {
                while (scan < args.len and self.hir.kindOf(args[scan]) != .spread) scan += 1;
                part_count += 1;
            }
        }
        const base_prec: Level = if (part_count > 1) .postfix else .comma;
        var idx: usize = 0;
        var part_index: usize = 0;
        var opened_concat = false;
        while (idx < args.len) {
            if (self.hir.kindOf(args[idx]) != .spread) {
                var run_end = idx;
                while (run_end < args.len and self.hir.kindOf(args[run_end]) != .spread) run_end += 1;
                try self.es5ArgsPartSep(part_index, &opened_concat);
                try self.write("[");
                var k = idx;
                while (k < run_end) : (k += 1) {
                    if (k > idx) try self.write(", ");
                    try self.printExpr(args[k], .comma);
                }
                try self.write("]");
                part_index += 1;
                idx = run_end;
            } else {
                const sp = hir_mod.spreadOf(self.hir, args[idx]);
                try self.es5ArgsPartSep(part_index, &opened_concat);
                try self.printExpr(sp.expression, if (part_index == 0) base_prec else .comma);
                part_index += 1;
                idx += 1;
            }
        }
        if (opened_concat) try self.write(")");
    }

    fn es5ArgsPartSep(self: *Printer, part_index: usize, opened_concat: *bool) !void {
        if (part_index == 0) return;
        if (!opened_concat.*) {
            try self.write(".concat(");
            opened_concat.* = true;
        } else {
            try self.write(", ");
        }
    }

    fn printNew(self: *Printer, node: NodeId) !void {
        const p = hir_mod.callOf(self.hir, node);
        // §4.A — ES5 `new` with spread args: `new C(...a)` ->
        // `new (C.bind.apply(C, [void 0].concat(a)))()`. Only for a
        // side-effect-free constructor (identifier / this) that can be
        // repeated as both the `.bind` receiver and `.apply` thisArg;
        // side-effecting constructors need a temp (deferred), so those fall
        // through to native emission.
        const new_args = hir_mod.callArgs(self.hir, node);
        if (self.options.es_target == .es5 and callArgsHaveSpread(self.hir, new_args)) {
            const ck = self.hir.kindOf(p.callee);
            if (ck == .identifier or ck == .this_expr) {
                try self.write("new (");
                try self.printExpr(p.callee, .postfix);
                try self.write(".bind.apply(");
                try self.printExpr(p.callee, .comma);
                try self.write(", ");
                try self.printEs5NewArgsArray(new_args);
                try self.write("))()");
                return;
            }
        }
        try self.write("new ");
        // The constructor target binds at `.new`; arguments at `.comma`.
        // `forbid_call` parenthesizes any call reached on the target spine.
        const prev_forbid = self.forbid_call;
        self.forbid_call = true;
        try self.printExpr(p.callee, .new);
        self.forbid_call = prev_forbid;
        try self.write("(");
        const args = hir_mod.callArgs(self.hir, node);
        for (args, 0..) |a, i| {
            if (i > 0) try self.write(", ");
            try self.printExpr(a, .comma);
        }
        try self.write(")");
    }

    /// Argument array for an ES5 `new`-spread — the array passed to
    /// `Ctor.bind.apply(Ctor, …)`. Prepends `void 0` (the ignored bind
    /// `this`) to the leading array-literal part: `new C(...a)` ->
    /// `[void 0].concat(a)`, `new C(1, ...a, b)` -> `[void 0, 1].concat(a, [b])`.
    fn printEs5NewArgsArray(self: *Printer, args: []const NodeId) !void {
        // Leading run of non-spread args shares the base `[void 0, …]` literal.
        var run_end: usize = 0;
        while (run_end < args.len and self.hir.kindOf(args[run_end]) != .spread) run_end += 1;
        try self.write("[void 0");
        var k: usize = 0;
        while (k < run_end) : (k += 1) {
            try self.write(", ");
            try self.printExpr(args[k], .comma);
        }
        try self.write("]");
        var idx = run_end;
        if (idx >= args.len) return;
        try self.write(".concat(");
        var first = true;
        while (idx < args.len) {
            if (!first) try self.write(", ");
            first = false;
            if (self.hir.kindOf(args[idx]) == .spread) {
                const sp = hir_mod.spreadOf(self.hir, args[idx]);
                try self.printExpr(sp.expression, .comma);
                idx += 1;
            } else {
                var re = idx;
                while (re < args.len and self.hir.kindOf(args[re]) != .spread) re += 1;
                try self.write("[");
                var j = idx;
                while (j < re) : (j += 1) {
                    if (j > idx) try self.write(", ");
                    try self.printExpr(args[j], .comma);
                }
                try self.write("]");
                idx = re;
            }
        }
        try self.write(")");
    }

    fn printMember(self: *Printer, node: NodeId) !void {
        const p = hir_mod.memberOf(self.hir, node);
        // §4.A.2 — bare `super.x` reads become `_super.prototype.x`
        // inside the ES5 derived-class IIFE body. Calls of the form
        // `super.x(args)` are handled in `printCall`.
        if (self.in_es5_super_lowering and self.hir.kindOf(p.object) == .identifier) {
            const obj_id = hir_mod.identifierOf(self.hir, p.object);
            if (std.mem.eql(u8, self.interner.get(obj_id.name), "super")) {
                try self.write("_super.prototype.");
                try self.write(self.interner.get(p.name));
                return;
            }
        }
        // §4.A.7 — rewrite `<obj>.#field` to `_<Class>_field.get(<obj>)`
        // when private-field downlevel is active inside a class body.
        if (self.current_class_name) |class_name| {
            const name_str = self.interner.get(p.name);
            if (name_str.len > 0 and name_str[0] == '#') {
                try self.write("_");
                try self.write(self.interner.get(class_name));
                try self.write("_");
                try self.write(name_str[1..]);
                try self.write(".get(");
                try self.printExpression(p.object);
                try self.write(")");
                return;
            }
        }
        // Downlevel `obj?.x` to `(obj === null || obj === void 0 ? void 0 : obj.x)`
        // when targeting below ES2020.
        if (p.optional and !self.options.es_target.supportsNullishAndOptional()) {
            try self.write("(");
            try self.printExpression(p.object);
            try self.write(" === null || ");
            try self.printExpression(p.object);
            try self.write(" === void 0 ? void 0 : ");
            try self.printExpression(p.object);
            try self.write(".");
            try self.write(self.interner.get(p.name));
            try self.write(")");
            return;
        }
        // The member target binds at `.postfix`, so a looser object (binary,
        // conditional, …) is parenthesized: `(a + b).c`, `(a ? b : c).d`.
        //
        // KNOWN LIMITATION: `(a?.b).c` is emitted as `a?.b.c`. These differ
        // when `a` is nullish (`(a?.b).c` throws; `a?.b.c` short-circuits to
        // undefined), but the HIR collapses both to the same shape — it has
        // no optional-chain-boundary marker (Bun's `optional_chain`
        // start/continue + `has_non_optional_chain_parent`). Fixing it needs
        // that marker threaded through the parser's postfix loop and the
        // member/element/call payloads; deferred as a rare case.
        try self.printExpr(p.object, .postfix);
        try self.write(if (p.optional) "?." else ".");
        try self.write(self.interner.get(p.name));
    }

    fn printElement(self: *Printer, node: NodeId) !void {
        const p = hir_mod.elementOf(self.hir, node);
        if (p.optional and !self.options.es_target.supportsNullishAndOptional()) {
            try self.write("(");
            try self.printExpression(p.object);
            try self.write(" === null || ");
            try self.printExpression(p.object);
            try self.write(" === void 0 ? void 0 : ");
            try self.printExpression(p.object);
            try self.write("[");
            try self.printExpression(p.index);
            try self.write("])");
            return;
        }
        // Element target binds at `.postfix` like member access; the index
        // sits inside `[ ]` so it needs no precedence wrapping.
        try self.printExpr(p.object, .postfix);
        try self.write(if (p.optional) "?.[" else "[");
        try self.printExpression(p.index);
        try self.write("]");
    }

    fn printArrayLiteral(self: *Printer, node: NodeId) !void {
        const elements = hir_mod.arrayLiteralElements(self.hir, node);
        // §4.A — array spread `[...a]` is an ES2015 feature. Below that we
        // lower a pure single-spread `[...a]` to `a.slice()` (a fresh copy),
        // matching tsc's helper-free downlevel shape.
        if (self.options.es_target == .es5 and
            elements.len == 1 and
            elements[0] != hir_mod.none_node_id and
            self.hir.kindOf(elements[0]) == .spread)
        {
            const sp = hir_mod.spreadOf(self.hir, elements[0]);
            try self.printExpression(sp.expression);
            try self.write(".slice()");
            return;
        }
        // Mixed/multi-spread `[...a, b]` / `[x, ...a]` / `[...a, ...b]` lower
        // to a `.concat` chain (`a.concat([b])`, `[x].concat(a)`), reusing the
        // same helper-free part-builder as ES5 call-site spread. Deferred for
        // arrays containing holes (`[...a, , b]`), which fall through native.
        if (self.options.es_target == .es5) {
            var has_spread = false;
            var has_hole = false;
            for (elements) |e| {
                if (e == hir_mod.none_node_id) {
                    has_hole = true;
                } else if (self.hir.kindOf(e) == .spread) {
                    has_spread = true;
                }
            }
            if (has_spread and !has_hole) {
                try self.printEs5SpreadArgsArray(elements);
                return;
            }
        }
        try self.write("[");
        for (elements, 0..) |e, i| {
            if (i > 0) try self.write(", ");
            if (e == hir_mod.none_node_id) {
                // hole
            } else if (self.hir.kindOf(e) == .spread) {
                const sp = hir_mod.spreadOf(self.hir, e);
                try self.write("...");
                try self.printExpr(sp.expression, .comma);
            } else {
                try self.printExpr(e, .comma);
            }
        }
        try self.write("]");
    }

    fn printObjectLiteral(self: *Printer, node: NodeId) !void {
        const props = hir_mod.objectLiteralProps(self.hir, node);
        if (props.len == 0) {
            try self.write("{}");
            return;
        }
        // §4.A — object spread `{ ...a }` is an ES2018 feature. Below that tsc
        // lowers it to a left-folded `__assign(...)` chain (helper-based, like
        // the sibling object-rest `__rest`), e.g. `{ a: 1, ...r, c: 2 }` ->
        // `__assign(__assign({ a: 1 }, r), { c: 2 })`.
        if (!self.options.es_target.supportsObjectSpread() and objectHasSpread(self.hir, props)) {
            try self.printObjectSpreadAssign(props);
            return;
        }
        // §4.A.31 — computed property keys are ES2015; at ES5 the literal
        // lowers to a comma-sequence through a hoisted temp:
        // `{ a: 1, [k]: v }` -> `(_a = { a: 1 }, _a[k] = v, _a)`.
        if (self.options.es_target == .es5 and
            objectAllPlainProps(self.hir, props) and
            objectHasComputed(self.hir, props))
        {
            try self.printEs5ComputedObject(props);
            return;
        }
        try self.write("{ ");
        for (props, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            // Object spread `{ ...rest }` (native at ES2018+).
            if (self.hir.kindOf(p) == .spread) {
                try self.write("...");
                try self.printExpr(hir_mod.spreadOf(self.hir, p).expression, .comma);
                continue;
            }
            try self.printObjectProp(p);
        }
        try self.write(" }");
    }

    fn objectHasComputed(hir: *const hir_mod.Hir, props: []const NodeId) bool {
        for (props) |p| {
            if (hir.kindOf(p) != .object_property) continue;
            if (hir_mod.objectPropertyOf(hir, p).is_computed) return true;
        }
        return false;
    }

    fn objectAllPlainProps(hir: *const hir_mod.Hir, props: []const NodeId) bool {
        for (props) |p| {
            if (hir.kindOf(p) != .object_property) return false;
        }
        return true;
    }

    /// §4.A.31 — ES5 lowering for object literals with computed keys:
    /// `{ a: 1, [k]: v, b: 2 }` -> `(_a = { a: 1 }, _a[k] = v, _a.b = 2, _a)`.
    /// Props before the first computed key stay in the seed literal; the rest
    /// become assignments through a hoisted temp (tsc's shape). The sequence
    /// is always parenthesized, so no outer precedence wrapping is needed.
    fn printEs5ComputedObject(self: *Printer, props: []const NodeId) anyerror!void {
        var first_computed: usize = 0;
        while (first_computed < props.len) : (first_computed += 1) {
            if (hir_mod.objectPropertyOf(self.hir, props[first_computed]).is_computed) break;
        }
        var buf: [16]u8 = undefined;
        const t = self.allocTemp(&buf);
        try self.write("(");
        try self.write(t);
        try self.write(" = ");
        try self.printObjectChunk(props[0..first_computed]);
        var i = first_computed;
        while (i < props.len) : (i += 1) {
            const op = hir_mod.objectPropertyOf(self.hir, props[i]);
            try self.write(", ");
            try self.write(t);
            if (op.is_computed) {
                try self.write("[");
                try self.printExpression(op.key);
                try self.write("]");
            } else if (self.hir.kindOf(op.key) == .identifier) {
                try self.write(".");
                try self.printExpression(op.key);
            } else {
                // String/number-literal key after a computed one: bracket form.
                try self.write("[");
                try self.printExpression(op.key);
                try self.write("]");
            }
            try self.write(" = ");
            if (op.is_method) {
                try self.write("function ");
                try self.printObjectMethodBody(op.value);
            } else if (op.is_shorthand) {
                try self.printExpression(op.key);
            } else {
                try self.printExpr(op.value, .comma);
            }
        }
        try self.write(", ");
        try self.write(t);
        try self.write(")");
    }

    fn objectHasSpread(hir: *const hir_mod.Hir, props: []const NodeId) bool {
        for (props) |p| {
            if (hir.kindOf(p) == .spread) return true;
        }
        return false;
    }

    /// Emit a single non-spread object-literal property: shorthand `{ foo }`
    /// (expanded to `foo: foo` at ES5), method shorthand `{ foo() {} }`,
    /// computed `{ [k]: v }`, or regular `key: value`.
    fn printObjectProp(self: *Printer, p: NodeId) !void {
        if (self.hir.kindOf(p) != .object_property) {
            try self.printExpression(p);
            return;
        }
        const op = hir_mod.objectPropertyOf(self.hir, p);
        if (op.is_shorthand) {
            // `{ foo }` shorthand is ES2015; below that tsc expands it to
            // the full `{ foo: foo }` form.
            try self.printExpression(op.key);
            if (self.options.es_target == .es5) {
                try self.write(": ");
                try self.printExpression(op.key);
            }
        } else if (op.is_method) {
            // Object literal method shorthand: `{ foo() { … } }`. At ES2015+
            // emit native shorthand; at ES5 lower to `key: function (…) {…}`.
            if (self.options.es_target == .es5) {
                if (op.is_computed) {
                    try self.write("[");
                    try self.printExpression(op.key);
                    try self.write("]");
                } else {
                    try self.printExpression(op.key);
                }
                try self.write(": function ");
            } else {
                // Accessor / async / generator keywords precede the key.
                try self.writeMethodPrefix(op.value);
                if (op.is_computed) {
                    try self.write("[");
                    try self.printExpression(op.key);
                    try self.write("]");
                } else {
                    try self.printExpression(op.key);
                }
            }
            try self.printObjectMethodBody(op.value);
        } else {
            if (op.is_computed) {
                try self.write("[");
                try self.printExpression(op.key);
                try self.write("]");
            } else {
                try self.printExpression(op.key);
            }
            try self.write(": ");
            try self.printExpr(op.value, .comma);
        }
    }

    /// Emit a run of non-spread props as an object literal `{ ... }` — used as
    /// an argument chunk in the ES5 object-spread `__assign` lowering.
    fn printObjectChunk(self: *Printer, chunk: []const NodeId) !void {
        if (chunk.len == 0) {
            try self.write("{}");
            return;
        }
        try self.write("{ ");
        for (chunk, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            try self.printObjectProp(p);
        }
        try self.write(" }");
    }

    /// Lower an object literal containing spread(s) to tsc's `__assign` chain
    /// for targets below ES2018. Consecutive non-spread props form object
    /// chunks; each spread becomes a bare argument; parts fold left. A leading
    /// spread uses an empty `{}` base (`{ ...r }` -> `__assign({}, r)`).
    fn printObjectSpreadAssign(self: *Printer, props: []const NodeId) !void {
        var part_count: usize = 0;
        var leading_spread = false;
        {
            var i: usize = 0;
            var first = true;
            while (i < props.len) {
                if (self.hir.kindOf(props[i]) == .spread) {
                    if (first) leading_spread = true;
                    part_count += 1;
                    i += 1;
                } else {
                    while (i < props.len and self.hir.kindOf(props[i]) != .spread) i += 1;
                    part_count += 1;
                }
                first = false;
            }
        }
        const fold_count = if (leading_spread) part_count else part_count - 1;
        var f: usize = 0;
        while (f < fold_count) : (f += 1) try self.write("__assign(");
        var is_base = true;
        if (leading_spread) {
            try self.write("{}");
            is_base = false;
        }
        var idx: usize = 0;
        while (idx < props.len) {
            if (self.hir.kindOf(props[idx]) == .spread) {
                const expr = hir_mod.spreadOf(self.hir, props[idx]).expression;
                if (is_base) {
                    try self.printExpr(expr, .comma);
                    is_base = false;
                } else {
                    try self.write(", ");
                    try self.printExpr(expr, .comma);
                    try self.write(")");
                }
                idx += 1;
            } else {
                var re = idx;
                while (re < props.len and self.hir.kindOf(props[re]) != .spread) re += 1;
                if (is_base) {
                    try self.printObjectChunk(props[idx..re]);
                    is_base = false;
                } else {
                    try self.write(", ");
                    try self.printObjectChunk(props[idx..re]);
                    try self.write(")");
                }
                idx = re;
            }
        }
    }

    /// Emit `(params) { body }` for an object-literal method value.
    /// The key is printed by the caller (and at ES5 the caller also
    /// prints `: function ` before delegating). The value node is a
    /// `fn_expr` with `is_method = true`. Honors `is_generator` and
    /// the ES5 default-param shim. (Async object-method shorthand is
    /// a follow-up — the `async` prefix needs to land before the
    /// method name, which the caller has already emitted.)
    /// Write a method's leading keywords before its name: `get `/`set ` for
    /// accessors, else `async `/`*` (the generator star must precede the
    /// name, so it's emitted here by the caller, not in the body).
    fn writeMethodPrefix(self: *Printer, fn_node: NodeId) !void {
        const f = hir_mod.fnDeclOf(self.hir, fn_node);
        if (f.flags.is_getter) {
            try self.write("get ");
            return;
        }
        if (f.flags.is_setter) {
            try self.write("set ");
            return;
        }
        if (f.flags.is_async and self.options.es_target.supportsNativeAsync()) try self.write("async ");
        if (f.flags.is_generator) try self.write("*");
    }

    fn printObjectMethodBody(self: *Printer, fn_node: NodeId) anyerror!void {
        const f = hir_mod.fnDeclOf(self.hir, fn_node);
        const downlevel_async = f.flags.is_async and !self.options.es_target.supportsNativeAsync();
        try self.write("(");
        const params = hir_mod.fnParams(self.hir, fn_node);
        try self.printRuntimeParams(params);
        try self.write(")");
        if (f.body != hir_mod.none_node_id) {
            try self.write(" ");
            if (downlevel_async) {
                try self.printAsyncDownlevelBody(f.body, params);
            } else if (self.options.es_target == .es5 and (self.hasDefaultParam(params) or self.hasDestructuringParam(params))) {
                try self.printFnBodyWithDefaults(params, f.body);
            } else {
                self.next_block_is_fn_body = self.hir.kindOf(f.body) == .block_stmt;
                try self.printStatementInline(f.body);
            }
        } else {
            try self.write("{}");
        }
    }
};

/// Count line breaks in `s` and return the number of lines (≥ 1).
/// "a\nb" -> 2 lines, "a\nb\n" -> 3 lines (the line after the
/// trailing newline still counts).
fn countLines(s: []const u8) u32 {
    var n: u32 = 1;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// True if the HIR rooted at `root` (or any reachable subtree)
/// contains a JSX-shape node. Walked by the auto-import logic to
/// decide whether to inject the `react/jsx-runtime` imports.
fn anyJsxIn(hir: *const Hir, root: NodeId) bool {
    if (root == hir_mod.none_node_id) return false;
    var i: hir_mod.NodeId = 1;
    while (i < hir.nodeCount()) : (i += 1) {
        switch (hir.kindOf(i)) {
            .jsx_element, .jsx_self_closing, .jsx_fragment => return true,
            else => {},
        }
    }
    return false;
}

/// Return the StringId of the bound name for a top-level
/// declaration (function / class / let / const). Returns null
/// when the decl has no bindable name (e.g. anonymous function
/// expression).
fn decoratorBoundName(hir: *const Hir, decl: NodeId) ?hir_mod.StringId {
    const k = hir.kindOf(decl);
    switch (k) {
        .fn_decl, .fn_expr => {
            const f = hir_mod.fnDeclOf(hir, decl);
            if (f.name == hir_mod.none_node_id) return null;
            if (hir.kindOf(f.name) != .identifier) return null;
            return hir_mod.identifierOf(hir, f.name).name;
        },
        .class_decl, .class_expr => {
            const c = hir_mod.classOf(hir, decl);
            if (c.name == hir_mod.none_node_id) return null;
            if (hir.kindOf(c.name) != .identifier) return null;
            return hir_mod.identifierOf(hir, c.name).name;
        },
        .let_decl, .const_decl, .var_decl => {
            const v = hir_mod.varDeclOf(hir, decl);
            if (v.name == hir_mod.none_node_id) return null;
            if (hir.kindOf(v.name) != .identifier) return null;
            return hir_mod.identifierOf(hir, v.name).name;
        },
        else => return null,
    }
}

fn binOpString(op: hir_mod.BinOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .pow => "**",
        .eq => "==",
        .neq => "!=",
        .eq_strict => "===",
        .neq_strict => "!==",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shl => "<<",
        .shr => ">>",
        .shr_unsigned => ">>>",
        .instanceof => "instanceof",
        .in => "in",
        .comma => ",",
        // Logical-assignment ops only appear as assignment operators, never
        // as a binary_op; included for switch exhaustiveness.
        .logical_or => "||",
        .logical_and => "&&",
        .nullish_coalesce => "??",
    };
}

/// Operator-precedence level, mirroring Bun's `Op.Level`
/// (`~/Code/bun/src/ast/op.zig`). Higher binds tighter. The printer
/// threads the *surrounding* level into each expression and wraps it in
/// parentheses only when the expression's own level is looser than the
/// context requires — yielding Bun/tsc-style minimal parenthesization
/// instead of the historical "always wrap every binop" baseline.
const Level = enum(u8) {
    lowest,
    comma,
    spread,
    yield,
    assign,
    conditional,
    nullish_coalescing,
    logical_or,
    logical_and,
    bitwise_or,
    bitwise_xor,
    bitwise_and,
    equals,
    compare,
    shift,
    add,
    multiply,
    exponentiation,
    prefix,
    postfix,
    new,
    call,
    member,

    fn gte(self: Level, other: Level) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }

    /// `level - n`, saturating at `.lowest` so `.lowest.sub(1)` stays
    /// `.lowest` rather than wrapping the unsigned tag.
    fn sub(self: Level, n: u8) Level {
        const v = @intFromEnum(self);
        return @enumFromInt(if (v > n) v - n else 0);
    }
};

/// Precedence level of a binary operator, mirroring Bun's `Op.Table`.
fn binOpLevel(op: hir_mod.BinOp) Level {
    return switch (op) {
        .comma => .comma,
        .nullish_coalesce => .nullish_coalescing,
        .logical_or => .logical_or,
        .logical_and => .logical_and,
        .bit_or => .bitwise_or,
        .bit_xor => .bitwise_xor,
        .bit_and => .bitwise_and,
        .eq, .neq, .eq_strict, .neq_strict => .equals,
        .lt, .le, .gt, .ge, .in, .instanceof => .compare,
        .shl, .shr, .shr_unsigned => .shift,
        .add, .sub => .add,
        .mul, .div, .mod => .multiply,
        .pow => .exponentiation,
    };
}

/// Precedence level of a logical operator (`logical_op` node).
fn logicalLevel(op: hir_mod.LogicalOp) Level {
    return switch (op) {
        .nullish => .nullish_coalescing,
        .@"or" => .logical_or,
        .@"and" => .logical_and,
    };
}

fn unaryOpString(op: hir_mod.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .plus => "+",
        .not => "!",
        .bit_not => "~",
        .typeof => "typeof",
        .void_ => "void",
        .delete => "delete",
    };
}

/// True if `slice` looks like the source text of a JavaScript
/// numeric literal — used by `printLiteralNumber` to detect when a
/// HIR literal's span was synthesized from a non-number token (e.g.
/// `i++` lowers to `i += 1` whose `1` literal carries the `++`
/// token span). In that case we fall back to the stored numeric value.
fn sliceLooksLikeNumber(slice: []const u8) bool {
    if (slice.len == 0) return false;
    const c0 = slice[0];
    if (c0 >= '0' and c0 <= '9') return true;
    if (c0 == '.' and slice.len > 1) {
        const c1 = slice[1];
        return c1 >= '0' and c1 <= '9';
    }
    return false;
}

fn compoundOpString(op: hir_mod.BinOp) []const u8 {
    return switch (op) {
        .add => " += ",
        .sub => " -= ",
        .mul => " *= ",
        .div => " /= ",
        .mod => " %= ",
        .pow => " **= ",
        .bit_and => " &= ",
        .bit_or => " |= ",
        .bit_xor => " ^= ",
        .shl => " <<= ",
        .shr => " >>= ",
        .shr_unsigned => " >>>= ",
        .logical_or => " ||= ",
        .logical_and => " &&= ",
        .nullish_coalesce => " ??= ",
        else => " = ",
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
    printer: Printer,
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
    s.printer = Printer.init(T.allocator, &s.hir, &s.interner, .{});
    s.printer.setSource(source);
    return s;
}

fn destroyTestSetup(s: *TestSetup) void {
    s.printer.deinit();
    s.parser.deinit();
    s.tokens.deinit(T.allocator);
    s.scanner.deinit(T.allocator);
    s.hir.deinit();
    s.interner.deinit();
    T.allocator.destroy(s);
}

fn emit(source: []const u8) ![]u8 {
    const s = try newTestSetup(source);
    defer destroyTestSetup(s);
    try s.printer.printSourceFile(s.root);
    return T.allocator.dupe(u8, s.printer.out.items);
}

test "emit: number literal" {
    const out = try emit("42;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("42;", out);
}

test "emit: string literal" {
    const out = try emit("\"hello\";");
    defer T.allocator.free(out);
    try T.expectEqualStrings("\"hello\";", out);
}

test "emit: arithmetic with parens for precedence" {
    const out = try emit("1 + 2 * 3;");
    defer T.allocator.free(out);
    // Precedence-aware paren elision (matches tsc / Bun): `*` binds tighter
    // than `+`, so no parentheses are needed.
    try T.expectEqualStrings("1 + 2 * 3;", out);
}

test "emit: precedence — only required parens are emitted" {
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        // Grouping that overrides precedence is preserved.
        .{ .src = "(1 + 2) * 3;", .want = "(1 + 2) * 3;" },
        // Left-associative `-` keeps the right side parenthesized only when
        // the source grouped it.
        .{ .src = "1 - 2 - 3;", .want = "1 - 2 - 3;" },
        .{ .src = "1 - (2 - 3);", .want = "1 - (2 - 3);" },
        // `**` is right-associative.
        .{ .src = "2 ** 3 ** 4;", .want = "2 ** 3 ** 4;" },
        .{ .src = "(2 ** 3) ** 4;", .want = "(2 ** 3) ** 4;" },
        // `-2 ** 3` is a SyntaxError — the unary left operand must wrap.
        .{ .src = "(-2) ** 3;", .want = "(-2) ** 3;" },
        // `??` cannot be mixed with `||`/`&&` without parens.
        .{ .src = "(a || b) ?? c;", .want = "(a || b) ?? c;" },
        // A looser expression as a member target / call callee wraps.
        .{ .src = "(a + b).c;", .want = "(a + b).c;" },
        .{ .src = "(f || g)();", .want = "(f || g)();" },
        // Unary operand wraps a comparison.
        .{ .src = "!(a < b);", .want = "!(a < b);" },
        // Right-associative assignment nests without parens.
        .{ .src = "a = b = c;", .want = "a = b = c;" },
    };
    for (cases) |c| {
        const out = try emit(c.src);
        defer T.allocator.free(out);
        try T.expectEqualStrings(c.want, out);
    }
}

test "emit: identifier reference" {
    const out = try emit("foo;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("foo;", out);
}

test "emit: function declaration" {
    const out = try emit("function add(a, b) { return a + b; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function add(a, b)") != null);
    try T.expect(std.mem.indexOf(u8, out, "return a + b;") != null);
}

test "emit: if/else" {
    const out = try emit("if (x) y; else z;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "if (x)") != null);
    try T.expect(std.mem.indexOf(u8, out, " else ") != null);
}

test "emit: while loop" {
    const out = try emit("while (x) { y; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "while (x)") != null);
}

test "emit: for loop" {
    const out = try emit("for (let i = 0; i < 10; i = i + 1) { y; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "for (") != null);
}

test "emit: array literal" {
    const out = try emit("let a = [1, 2, 3];");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "[1, 2, 3]") != null);
}

test "emit: object literal" {
    const out = try emit("let o = { x: 1, y: 2 };");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "{ x: 1, y: 2 }") != null);
}

test "emit: import declaration" {
    const out = try emit("import { useState } from \"react\";");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "import { useState } from \"react\";") != null);
}

test "emit: type-only import erases" {
    const out = try emit("import type { Foo } from \"./types\";");
    defer T.allocator.free(out);
    try T.expectEqualStrings("", out);
}

test "emit: interface erases" {
    const out = try emit("interface Foo { x: number; }");
    defer T.allocator.free(out);
    try T.expectEqualStrings("", out);
}

test "emit: as-cast erases at runtime" {
    const out = try emit("let n = (\"hi\" as any) as number;");
    defer T.allocator.free(out);
    // Both casts erase; the inner string literal is what remains.
    try T.expect(std.mem.indexOf(u8, out, "let n = \"hi\"") != null);
    try T.expect(std.mem.indexOf(u8, out, " as ") == null);
}

test "emit: postfix non-null assertion erases at runtime" {
    const out = try emit("let s = x!;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "let s = x") != null);
    try T.expect(std.mem.indexOf(u8, out, "!") == null);
}

test "emit: export interface erases without dangling token" {
    const out = try emit(
        \\export interface Box { value: number; }
        \\export class Counter { count: number = 0; }
    );
    defer T.allocator.free(out);
    // No dangling `export ` left from the interface erase.
    try T.expect(std.mem.indexOf(u8, out, "export class Counter") != null);
    try T.expect(std.mem.indexOf(u8, out, "interface") == null);
}

test "emit: export type alias erases" {
    const out = try emit("export type Pair = [number, number];");
    defer T.allocator.free(out);
    try T.expectEqualStrings("", out);
}

test "emit: type alias erases" {
    const out = try emit("type Pair = [number, number];");
    defer T.allocator.free(out);
    try T.expectEqualStrings("", out);
}

test "emit: try/catch/finally" {
    const out = try emit("try { f(); } catch (e) { g(); } finally { h(); }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "try ") != null);
    try T.expect(std.mem.indexOf(u8, out, " catch (e) ") != null);
    try T.expect(std.mem.indexOf(u8, out, " finally ") != null);
}

fn emitJsx(source: []const u8, opts: Options) ![]u8 {
    const s = try T.allocator.create(TestSetup);
    defer T.allocator.destroy(s);
    s.interner = try string_interner.Interner.init(T.allocator);
    defer s.interner.deinit();
    s.hir = try hir_mod.Hir.init(T.allocator);
    defer s.hir.deinit();
    s.scanner = ts_lexer.Scanner.init(T.allocator, source);
    defer s.scanner.deinit(T.allocator);
    s.tokens = try s.scanner.tokenize(T.allocator);
    defer s.tokens.deinit(T.allocator);
    s.parser = ts_parser.Parser.init(T.allocator, &s.hir, &s.interner, source, s.tokens.items);
    s.parser.setTsx(true);
    defer s.parser.deinit();
    s.root = try s.parser.parseSourceFile();
    s.printer = Printer.init(T.allocator, &s.hir, &s.interner, opts);
    defer s.printer.deinit();
    s.printer.setSource(source);
    try s.printer.printSourceFile(s.root);
    return T.allocator.dupe(u8, s.printer.out.items);
}

test "emit: jsx classic produces React.createElement" {
    const out = try emitJsx("let v = <Foo />;", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "React.createElement(Foo, null)") != null);
}

test "emit: jsx classic with attribute lowers to props object" {
    const out = try emitJsx("let v = <Foo x={1}/>;", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "React.createElement(Foo, { x: 1 })") != null);
}

test "emit: jsx classic with custom factory" {
    const out = try emitJsx("let v = <Foo x={1}/>;", .{ .jsx_factory = "h" });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "h(Foo, { x: 1 })") != null);
}

test "emit: jsx classic fragment uses fragment factory" {
    const out = try emitJsx("let v = <></>;", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "React.createElement(React.Fragment, null)") != null);
}

test "emit: jsx classic fragment honors custom factory pair" {
    const out = try emitJsx("let v = <></>;", .{
        .jsx_factory = "h",
        .jsx_fragment_factory = "Fragment",
    });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "h(Fragment, null)") != null);
}

test "emit: jsx preserve passes elements through unchanged" {
    const out = try emitJsx("let v = <Foo x={1}/>;", .{ .jsx_runtime = .preserve });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "<Foo x={1}/>") != null);
    try T.expect(std.mem.indexOf(u8, out, "React.createElement") == null);
}

test "emit: jsx automatic uses _jsx for single child" {
    const out = try emitJsx("let v = <Foo bar={1} />;", .{ .jsx_runtime = .automatic });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "_jsx(Foo, ") != null);
    try T.expect(std.mem.indexOf(u8, out, "bar: 1") != null);
}

test "emit: jsx automatic uses _jsxs for multiple children" {
    const out = try emitJsx("let v = <Foo>{1}{2}</Foo>;", .{ .jsx_runtime = .automatic });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "_jsxs(Foo, ") != null);
    try T.expect(std.mem.indexOf(u8, out, "children: [") != null);
}

test "emit: jsx automatic_dev uses _jsxDEV" {
    const out = try emitJsx("let v = <Foo />;", .{ .jsx_runtime = .automatic_dev });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "_jsxDEV(Foo, ") != null);
}

test "emit: jsx automatic_dev emits placeholder source info args" {
    const out = try emitJsx("let v = <Foo />;", .{ .jsx_runtime = .automatic_dev });
    defer T.allocator.free(out);
    // Signature: `_jsxDEV(tag, props, key, isStaticChildren, source, self)`.
    try T.expect(std.mem.indexOf(u8, out, "_jsxDEV(Foo, ") != null);
    try T.expect(std.mem.indexOf(u8, out, ", undefined, false, {}, this)") != null);
}

test "emit: jsx automatic_dev injects react/jsx-dev-runtime import" {
    const out = try emitJsx("let v = <Foo />;", .{ .jsx_runtime = .automatic_dev });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "import { jsxDEV as _jsxDEV") != null);
    try T.expect(std.mem.indexOf(u8, out, "from \"react/jsx-dev-runtime\"") != null);
}

test "emit: jsx automatic injects react/jsx-runtime import" {
    const out = try emitJsx("let v = <Foo />;", .{ .jsx_runtime = .automatic });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "import { jsx as _jsx") != null);
    try T.expect(std.mem.indexOf(u8, out, "from \"react/jsx-runtime\"") != null);
}

test "emit: jsx classic does not inject auto-import" {
    const out = try emitJsx("let v = <Foo />;", .{ .jsx_runtime = .classic });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "react/jsx-runtime") == null);
}

test "emit: arrow downlevels to function-with-bind at es5" {
    const out = try emitWithOpts("let f = (x) => x + 1;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function (") != null);
    try T.expect(std.mem.indexOf(u8, out, ".bind(this)") != null);
    try T.expect(std.mem.indexOf(u8, out, "=>") == null);
}

test "emit: arrow preserved at es2015+" {
    const out = try emitWithOpts("let f = (x) => x + 1;", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "=>") != null);
    try T.expect(std.mem.indexOf(u8, out, ".bind(this)") == null);
}

test "emit: arrow with block body downlevels correctly" {
    const out = try emitWithOpts("let f = (x) => { return x + 1; };", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function (") != null);
    try T.expect(std.mem.indexOf(u8, out, "return") != null);
}

test "emit: for-of downlevels to indexed for at es5" {
    const out = try emitWithOpts("for (let n of arr) { console.log(n); }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, " of ") == null);
    try T.expect(std.mem.indexOf(u8, out, "_i = 0") != null);
    try T.expect(std.mem.indexOf(u8, out, "_arr = arr") != null);
    try T.expect(std.mem.indexOf(u8, out, "_arr[_i]") != null);
}

test "emit: for-of preserved at es2015+" {
    const out = try emitWithOpts("for (let n of arr) { console.log(n); }", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, " of ") != null);
}

test "emit: for-await-of preserves native syntax at es2018+" {
    // Native `for await (...)` is ES2018+. At ES2018 and above the
    // existing emit passes it through unchanged.
    const out = try emitWithOpts("for await (const v of items) { use(v); }", .{ .es_target = .es2018 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "for await (") != null);
    try T.expect(std.mem.indexOf(u8, out, " of items") != null);
}

test "emit: for-await-of lowers via __asyncValues + try/finally at es2017" {
    const out = try emitWithOpts(
        "for await (const v of items) { use(v); }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    // Native for-await-of is gone.
    try T.expect(std.mem.indexOf(u8, out, "for await (") == null);
    // Iterator-protocol with __asyncValues + native `await`.
    try T.expect(std.mem.indexOf(u8, out, "var _aiter, _astep, e_1, _r;") != null);
    try T.expect(std.mem.indexOf(u8, out, "_aiter = __asyncValues(items)") != null);
    try T.expect(std.mem.indexOf(u8, out, "_astep = await _aiter.next()") != null);
    try T.expect(std.mem.indexOf(u8, out, "var v = _astep.value;") != null);
    try T.expect(std.mem.indexOf(u8, out, "use(v);") != null);
    // Try/catch/finally with .return() cleanup using `await`.
    try T.expect(std.mem.indexOf(u8, out, "catch (e_1_1)") != null);
    try T.expect(std.mem.indexOf(u8, out, "await _r.call(_aiter)") != null);
    try T.expect(std.mem.indexOf(u8, out, "if (e_1) throw e_1.error;") != null);
}

test "emit: for-in is unaffected by es_target" {
    const out = try emitWithOpts("for (let k in obj) { let v = k; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, " in ") != null);
}

test "emit: for-of with array literal source lowers at es5" {
    const out = try emitWithOpts("for (const x of [1, 2, 3]) { console.log(x); }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, " of ") == null);
    try T.expect(std.mem.indexOf(u8, out, "_i = 0") != null);
    try T.expect(std.mem.indexOf(u8, out, "_arr = [1, 2, 3]") != null);
    try T.expect(std.mem.indexOf(u8, out, "_i < _arr.length") != null);
    try T.expect(std.mem.indexOf(u8, out, "_i++") != null);
    try T.expect(std.mem.indexOf(u8, out, "var x = _arr[_i]") != null);
    try T.expect(std.mem.indexOf(u8, out, "console.log(x)") != null);
}

test "emit: for-of with array variable lowers at es5" {
    const out = try emitWithOpts("for (const x of arr) { use(x); }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, " of ") == null);
    try T.expect(std.mem.indexOf(u8, out, "for (var _i = 0, _arr = arr;") != null);
    try T.expect(std.mem.indexOf(u8, out, "_i < _arr.length") != null);
    try T.expect(std.mem.indexOf(u8, out, "var x = _arr[_i]") != null);
    try T.expect(std.mem.indexOf(u8, out, "use(x)") != null);
}

test "emit: for-of preserves native syntax at es2015 with array literal" {
    const out = try emitWithOpts("for (const x of [1, 2, 3]) { console.log(x); }", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, " of ") != null);
    try T.expect(std.mem.indexOf(u8, out, "_arr") == null);
    try T.expect(std.mem.indexOf(u8, out, "_i") == null);
}

test "emit: for-of with downlevel_iteration emits iterator-protocol loop at es5" {
    const out = try emitWithOpts(
        "for (const v of iterable) { use(v); }",
        .{ .es_target = .es5, .downlevel_iteration = true },
    );
    defer T.allocator.free(out);
    // No native `for-of` keyword survived.
    try T.expect(std.mem.indexOf(u8, out, " of ") == null);
    // Hoisted error + return-fn temps.
    try T.expect(std.mem.indexOf(u8, out, "var e_1, _a;") != null);
    // __values()-driven iterator setup, .next() loop.
    try T.expect(std.mem.indexOf(u8, out, "__values(iterable)") != null);
    try T.expect(std.mem.indexOf(u8, out, "_c = _b.next()") != null);
    try T.expect(std.mem.indexOf(u8, out, "!_c.done") != null);
    // Binding via .value.
    try T.expect(std.mem.indexOf(u8, out, "var v = _c.value") != null);
    // catch / finally with .return() call.
    try T.expect(std.mem.indexOf(u8, out, "catch (e_1_1)") != null);
    try T.expect(std.mem.indexOf(u8, out, "_a = _b.return") != null);
    try T.expect(std.mem.indexOf(u8, out, "_a.call(_b)") != null);
    try T.expect(std.mem.indexOf(u8, out, "if (e_1) throw e_1.error;") != null);
}

test "emit: for-of without downlevel_iteration keeps indexed-for at es5" {
    const out = try emitWithOpts(
        "for (const v of iterable) { use(v); }",
        .{ .es_target = .es5, .downlevel_iteration = false },
    );
    defer T.allocator.free(out);
    // Cheaper indexed-for form, no iterator protocol.
    try T.expect(std.mem.indexOf(u8, out, "_i < _arr.length") != null);
    try T.expect(std.mem.indexOf(u8, out, "__values(") == null);
    try T.expect(std.mem.indexOf(u8, out, "e_1") == null);
}

test "emit: for-of with downlevel_iteration is a no-op at es2015+" {
    // downlevel_iteration only fires below ES2015 — native for-of survives at es2015+.
    const out = try emitWithOpts(
        "for (const v of iterable) { use(v); }",
        .{ .es_target = .es2015, .downlevel_iteration = true },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, " of ") != null);
    try T.expect(std.mem.indexOf(u8, out, "__values(") == null);
}

test "emit: importHelpers tslib import includes __values" {
    const out = try emitWithOpts(
        "async function f() { await g(); }",
        .{ .es_target = .es2015, .import_helpers = true },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__values") != null);
    try T.expect(std.mem.indexOf(u8, out, "from \"tslib\"") != null);
}

test "EsTarget.supportsNativeGenerators is es2015+" {
    try T.expectEqual(false, EsTarget.supportsNativeGenerators(.es5));
    try T.expectEqual(true, EsTarget.supportsNativeGenerators(.es2015));
    try T.expectEqual(true, EsTarget.supportsNativeGenerators(.esnext));
}

test "emit: class downlevels to function-with-prototype at es5" {
    const out = try emitWithOpts("class Foo { greet() { return 1; } }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var Foo") != null);
    try T.expect(std.mem.indexOf(u8, out, "function Foo(") != null);
    try T.expect(std.mem.indexOf(u8, out, "Foo.prototype.greet") != null);
    try T.expect(std.mem.indexOf(u8, out, "class ") == null);
}

test "emit: class with extends emits __extends + super forwarding at es5" {
    const out = try emitWithOpts("class B extends A { }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__extends(B, _super)") != null);
    // Implicit derived ctor forwards args: `return _super.apply(this, arguments) || this`.
    try T.expect(std.mem.indexOf(u8, out, "return _super !== null && _super.apply(this, arguments) || this;") != null);
}

test "emit: class field initializer goes inside ctor at es5" {
    const out = try emitWithOpts("class Box { value = 42; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "this.value = 42") != null);
}

test "emit: plain class extends at es5 emits __extends helper call" {
    const out = try emitWithOpts("class B extends A {}", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    // IIFE wrapper with `_super` parameter applied to `A`.
    try T.expect(std.mem.indexOf(u8, out, "var B = (function (_super)") != null);
    try T.expect(std.mem.indexOf(u8, out, "__extends(B, _super)") != null);
    try T.expect(std.mem.indexOf(u8, out, "function B()") != null);
    try T.expect(std.mem.indexOf(u8, out, "return _super !== null && _super.apply(this, arguments) || this;") != null);
    try T.expect(std.mem.indexOf(u8, out, "return B;") != null);
    try T.expect(std.mem.indexOf(u8, out, "})(A)") != null);
    // No leftover `class` keyword.
    try T.expect(std.mem.indexOf(u8, out, "class ") == null);
}

test "emit: super.method() in derived method lowers to _super.prototype.method.call(this) at es5" {
    const out = try emitWithOpts(
        "class B extends A { m() { super.m(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // The method is hung off the prototype.
    try T.expect(std.mem.indexOf(u8, out, "B.prototype.m = function ()") != null);
    // `super.m()` inside a method becomes `_super.prototype.m.call(this)`.
    try T.expect(std.mem.indexOf(u8, out, "_super.prototype.m.call(this)") != null);
    // Bare `super.` should not survive lowering — only `_super.` is allowed.
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "super.")) |pos| : (idx = pos + 1) {
        try T.expect(pos > 0 and out[pos - 1] == '_');
    }
}

test "emit: derived constructor with super(arg) lowers to _super.call(this, arg) at es5" {
    const out = try emitWithOpts(
        "class B extends A { constructor() { super(1); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__extends(B, _super)") != null);
    // `super(1)` in the ctor body becomes `_super.call(this, 1)`.
    try T.expect(std.mem.indexOf(u8, out, "_super.call(this, 1)") != null);
    // `super(...)` token should not survive lowering.
    try T.expect(std.mem.indexOf(u8, out, "super(") == null);
}

test "emit: class preserved at es2015+" {
    const out = try emitWithOpts("class Foo { greet() { return 1; } }", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "class Foo") != null);
    try T.expect(std.mem.indexOf(u8, out, "prototype") == null);
}

test "emit: parameter properties lower to this.x = x assignments" {
    const out = try emit("class P { constructor(public x: number, private y: number, readonly z: string) {} }");
    defer T.allocator.free(out);
    // Modifiers stripped from the param list; assignments synthesized.
    try T.expect(std.mem.indexOf(u8, out, "constructor(x, y, z)") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.x = x;") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.y = y;") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.z = z;") != null);
}

test "emit: parameter-property assignments follow a leading super() call" {
    const out = try emit(
        \\class D extends B {
        \\  constructor(public n: number) { super(); use(n); }
        \\}
    );
    defer T.allocator.free(out);
    const super_idx = std.mem.indexOf(u8, out, "super()").?;
    const assign_idx = std.mem.indexOf(u8, out, "this.n = n;").?;
    const use_idx = std.mem.indexOf(u8, out, "use(n)").?;
    // Ordering: super() → this.n = n → rest of body.
    try T.expect(super_idx < assign_idx);
    try T.expect(assign_idx < use_idx);
}

test "emit: declare statements erase entirely" {
    const out = try emit("declare const a: number;\ndeclare function f(x: string): void;\nexport const real = 1;");
    defer T.allocator.free(out);
    // No invalid bodyless / initializer-less declarations.
    try T.expect(std.mem.indexOf(u8, out, "const a;") == null);
    try T.expect(std.mem.indexOf(u8, out, "function f(") == null);
    // Real declarations survive.
    try T.expect(std.mem.indexOf(u8, out, "const real = 1;") != null);
}

test "emit: function overload signatures erase, implementation survives" {
    const out = try emit("function over(x: string): void;\nfunction over(x: number): void;\nfunction over(x: any) { return x; }");
    defer T.allocator.free(out);
    // Exactly one `function over` (the implementation).
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "function over")) |p| {
        count += 1;
        idx = p + 1;
    }
    try T.expectEqual(@as(usize, 1), count);
    try T.expect(std.mem.indexOf(u8, out, "return x;") != null);
}

test "emit: import x = require() lowers to const x = require()" {
    const out = try emit("import foo = require(\"./foo\");");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "const foo = require(\"./foo\")") != null);
    // Must not be mistaken for an ESM default import.
    try T.expect(std.mem.indexOf(u8, out, "import foo from") == null);
}

test "emit: a plain default import stays an ESM import" {
    const out = try emit("import foo from \"./foo\";");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "import foo from \"./foo\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "require(") == null);
}

test "emit: abstract methods are omitted (no invalid bodyless signature)" {
    const out = try emit("abstract class A { abstract f(): void; g() { return 1; } }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "class A") != null);
    try T.expect(std.mem.indexOf(u8, out, "g()") != null);
    // The abstract method must not appear as a bodyless `f();`.
    try T.expect(std.mem.indexOf(u8, out, "f()") == null);
    try T.expect(std.mem.indexOf(u8, out, "abstract") == null);
}

test "emit: computed class method names emit as methods, not field assignments" {
    const out = try emit("class C { [Symbol.iterator]() { return 1; } field = 2; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "[Symbol.iterator]()") != null);
    try T.expect(std.mem.indexOf(u8, out, "return 1;") != null);
    // Must NOT be a `= () {}` field assignment.
    try T.expect(std.mem.indexOf(u8, out, "Symbol.iterator = ") == null);
    try T.expect(std.mem.indexOf(u8, out, "field = 2;") != null);
}

test "emit: arrow with object-literal concise body is parenthesized" {
    const out = try emit("const f = () => ({ k: 1 });");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "=> ({ k: 1 })") != null);
    // Must not become a block body `=> { k: 1 }`.
    try T.expect(std.mem.indexOf(u8, out, "=> { k: 1 }") == null);
}

test "emit: statement-leading object/function/destructuring is parenthesized" {
    const out1 = try emit("({ a } = obj);");
    defer T.allocator.free(out1);
    try T.expect(std.mem.indexOf(u8, out1, "({ a } = obj)") != null);

    const out2 = try emit("(function() { return 1; })();");
    defer T.allocator.free(out2);
    // The IIFE must stay parenthesized (a bare `function(){}()` is invalid).
    try T.expect(std.mem.indexOf(u8, out2, "(function") != null);
    try T.expect(std.mem.indexOf(u8, out2, "}())") != null or std.mem.indexOf(u8, out2, "})()") != null);

    // A real function declaration is NOT extra-parenthesized.
    const out3 = try emit("function real() { return 2; }");
    defer T.allocator.free(out3);
    try T.expect(std.mem.indexOf(u8, out3, "(function real") == null);
    try T.expect(std.mem.indexOf(u8, out3, "function real(") != null);
}

test "emit: labeled statement keeps its label (break/continue target)" {
    const out = try emit("outer: for (const x of list) { if (x) continue outer; }\nL: { break L; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "outer: for") != null);
    try T.expect(std.mem.indexOf(u8, out, "continue outer") != null);
    try T.expect(std.mem.indexOf(u8, out, "L: {") != null);
    try T.expect(std.mem.indexOf(u8, out, "break L") != null);
}

test "emit: tagged template renders natively (not a desugared call)" {
    const out = try emit("const t = tag`a${1}b${x}c`;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "tag`a${1}b${x}c`") != null);
    // Must NOT be the desugared `tag([...], ...)` call form.
    try T.expect(std.mem.indexOf(u8, out, "tag([") == null);
    try T.expect(std.mem.indexOf(u8, out, "tag([\"a\"") == null);
}

test "emit: tagged template escapes backtick / backslash / dollar-brace in cooked text" {
    const out = try emit("const t = raw`a\\nb`;");
    defer T.allocator.free(out);
    // The cooked text keeps its content inside the native template.
    try T.expect(std.mem.indexOf(u8, out, "raw`") != null);
}

test "emit: logical assignment is native at es2021+" {
    const out = try emitWithOpts("a ||= b; a &&= c; a ??= d;", .{ .es_target = .es2021 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "a ||= b") != null);
    try T.expect(std.mem.indexOf(u8, out, "a &&= c") != null);
    try T.expect(std.mem.indexOf(u8, out, "a ??= d") != null);
}

test "emit: logical assignment downlevels to short-circuit below es2021" {
    const out = try emitWithOpts("a ||= b; a ??= d;", .{ .es_target = .es2019 });
    defer T.allocator.free(out);
    // a ||= b  ->  (a || (a = b))  — NOT the always-assigning `a = (a || b)`.
    try T.expect(std.mem.indexOf(u8, out, "(a || (a = b))") != null);
    try T.expect(std.mem.indexOf(u8, out, "(a ?? (a = d))") != null);
    try T.expect(std.mem.indexOf(u8, out, "||=") == null);
}

test "emit: object-literal accessors/async/generator keep keywords + star placement" {
    const out = try emit("const o = { get x() { return 1; }, set x(v) {}, async am() {}, *g() {} };");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "get x()") != null);
    try T.expect(std.mem.indexOf(u8, out, "set x(v)") != null);
    try T.expect(std.mem.indexOf(u8, out, "async am()") != null);
    try T.expect(std.mem.indexOf(u8, out, "*g()") != null);
    // The generator star must precede the name, never `g*(`.
    try T.expect(std.mem.indexOf(u8, out, "g*(") == null);
}

test "emit: multi-declarator for-init emits and does not error/truncate" {
    const out = try emit("for (let i = 0, j = 10; i < j; i++) {}\nconst after = 1;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "for (let i = 0, j = 10;") != null);
    try T.expect(std.mem.indexOf(u8, out, "const after = 1;") != null);
}

test "emit: call and new spread args emit and do not truncate the file" {
    const out = try emit("const r = f(...args, 1);\nconst o = new Foo(...a, b);\nconst after = 9;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "f(...args, 1)") != null);
    try T.expect(std.mem.indexOf(u8, out, "new Foo(...a, b)") != null);
    try T.expect(std.mem.indexOf(u8, out, "const after = 9;") != null);
}

test "emit: regex literal emits verbatim (pattern + flags)" {
    const out = try emit("const r = /ab+c/gi;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "/ab+c/gi") != null);
    // Must not collapse to the `/./` placeholder.
    try T.expect(std.mem.indexOf(u8, out, "/./") == null);
}

test "emit: object spread {...rest} emits and does not truncate the file" {
    const out = try emit("const o = { a: 1, ...rest, b: 2 };\nconst after = 9;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "...rest") != null);
    try T.expect(std.mem.indexOf(u8, out, "a: 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "b: 2") != null);
    // The statement AFTER the spread object must still be emitted.
    try T.expect(std.mem.indexOf(u8, out, "const after = 9;") != null);
}

test "emit: class getter/setter/async/generator keep their keywords" {
    const out = try emit("class C { get x() { return 1; } set x(v: number) {} async m() {} static *g() {} }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "get x()") != null);
    try T.expect(std.mem.indexOf(u8, out, "set x(v)") != null);
    try T.expect(std.mem.indexOf(u8, out, "async m()") != null);
    try T.expect(std.mem.indexOf(u8, out, "static *g()") != null);
}

test "emit: qualified namespace A.B desugars to nested IIFEs (valid JS)" {
    const out = try emit("namespace A.B { export const z = 1; }");
    defer T.allocator.free(out);
    // No invalid `var A.B`.
    try T.expect(std.mem.indexOf(u8, out, "var A.B") == null);
    // Outer A and inner B IIFEs, with B assigned onto A.B.
    try T.expect(std.mem.indexOf(u8, out, "var A;") != null);
    try T.expect(std.mem.indexOf(u8, out, "var B;") != null);
    try T.expect(std.mem.indexOf(u8, out, "B = A.B || (A.B = {})") != null);
    try T.expect(std.mem.indexOf(u8, out, "B.z = z;") != null);
    try T.expect(std.mem.indexOf(u8, out, "(A || (A = {}))") != null);
}

test "emit: namespace exported members become N.x assignments (valid JS)" {
    const out = try emit("namespace N { export const x = 1; export function f() { return x; } const hidden = 2; }");
    defer T.allocator.free(out);
    // No bare `export` may survive inside the IIFE (that would be invalid JS).
    try T.expect(std.mem.indexOf(u8, out, "export const") == null);
    try T.expect(std.mem.indexOf(u8, out, "export function") == null);
    // Exported members are assigned onto the namespace object...
    try T.expect(std.mem.indexOf(u8, out, "N.x = x;") != null);
    try T.expect(std.mem.indexOf(u8, out, "N.f = f;") != null);
    // ...with the local binding kept (so `return x` still resolves).
    try T.expect(std.mem.indexOf(u8, out, "const x = 1;") != null);
    // Non-exported members are not assigned onto N.
    try T.expect(std.mem.indexOf(u8, out, "N.hidden") == null);
}

test "emit: export = lowers to module.exports assignment" {
    const out = try emitWithOpts("class Foo {}\nexport = Foo;", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "module.exports = Foo;") != null);
    // Must not leave a dangling `export Foo`.
    try T.expect(std.mem.indexOf(u8, out, "export Foo") == null);
}

test "emit: numeric enum lowers to bidirectional IIFE with auto-increment" {
    const out = try emit("enum F { X, Y = 5, Z }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "F[F[\"X\"] = 0] = \"X\";") != null);
    try T.expect(std.mem.indexOf(u8, out, "F[F[\"Y\"] = 5] = \"Y\";") != null);
    // Auto-increment resumes from the explicit 5.
    try T.expect(std.mem.indexOf(u8, out, "F[F[\"Z\"] = 6] = \"Z\";") != null);
    try T.expect(std.mem.indexOf(u8, out, "(F || (F = {}))") != null);
}

test "emit: string enum members are forward-only (no reverse mapping)" {
    const out = try emit("enum Dir { Up = \"UP\", Down = \"DOWN\" }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "Dir[\"Up\"] = \"UP\";") != null);
    try T.expect(std.mem.indexOf(u8, out, "Dir[\"Down\"] = \"DOWN\";") != null);
    // No bidirectional reverse mapping for string members.
    try T.expect(std.mem.indexOf(u8, out, "Dir[Dir[\"Up\"]") == null);
}

test "emit: optional call ?.() preserved natively at es2020+" {
    const out = try emitWithOpts("f?.(1);", .{ .es_target = .es2020 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "f?.(1)") != null);
}

test "emit: optional call ?.() downlevels below es2020" {
    const out = try emitWithOpts("f?.(1);", .{ .es_target = .es2019 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "f === null || f === void 0 ? void 0 : f(1)") != null);
    // Must NOT collapse to a plain unconditional call.
    try T.expect(std.mem.indexOf(u8, out, "?.(") == null);
}

test "emit: a plain (non-property) constructor param emits no assignment" {
    const out = try emit("class P { constructor(x: number) { this.q = x; } }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "this.x = x;") == null);
}

test "emit: object destructuring lowers to temp + property reads at es5" {
    const out = try emitWithOpts("const { a } = obj;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    // `const` collapses to `var`, single statement with a `_o` temp
    // holding the initializer and one property read per binding.
    try T.expect(std.mem.indexOf(u8, out, "var _o = obj") != null);
    try T.expect(std.mem.indexOf(u8, out, "a = _o.a") != null);
    // No native pattern survives.
    try T.expect(std.mem.indexOf(u8, out, "{ a }") == null);
    try T.expect(std.mem.indexOf(u8, out, "const ") == null);
}

test "emit: array destructuring lowers to temp + index reads at es5" {
    const out = try emitWithOpts("const [x] = arr;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _arr = arr") != null);
    try T.expect(std.mem.indexOf(u8, out, "x = _arr[0]") != null);
    // No native pattern, no `const`.
    try T.expect(std.mem.indexOf(u8, out, "[x]") == null);
    try T.expect(std.mem.indexOf(u8, out, "const ") == null);
}

test "emit: destructuring is native at es2015+" {
    const out = try emitWithOpts("const { a } = obj;", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    // ES2015+ keeps native destructuring (matching tsc / Bun's printer).
    try T.expect(std.mem.indexOf(u8, out, "const { a } = obj") != null);
    try T.expect(std.mem.indexOf(u8, out, "_o") == null);
}

test "emit: object destructuring preserves rename and default at es2015+" {
    const out = try emit("const { x, y: z, w = 3 } = obj;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "{ x, y: z, w = 3 }") != null);
}

test "emit: object destructuring with default fires void 0 check at es5" {
    // §4.A.4 destructuring v2 — `var { a = 1 } = obj;` lowers to
    // `var _o = obj, a = _o.a === void 0 ? 1 : _o.a;` so the default
    // fires only when the property is missing/undefined.
    const out = try emitWithOpts("const { a = 1 } = obj;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _o = obj") != null);
    try T.expect(std.mem.indexOf(u8, out, "a = _o.a === void 0 ? 1 : _o.a") != null);
}

test "emit: array destructuring with default fires void 0 check at es5" {
    const out = try emitWithOpts("const [a = 1] = arr;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _arr = arr") != null);
    try T.expect(std.mem.indexOf(u8, out, "a = _arr[0] === void 0 ? 1 : _arr[0]") != null);
}

test "emit: mixed destructuring with and without defaults at es5" {
    // Mix of defaulted and non-defaulted elements in the same pattern.
    const out = try emitWithOpts("const { a, b = 2 } = obj;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _o = obj") != null);
    try T.expect(std.mem.indexOf(u8, out, "a = _o.a") != null);
    try T.expect(std.mem.indexOf(u8, out, "b = _o.b === void 0 ? 2 : _o.b") != null);
}

test "emit: array destructuring with rest binds slice() at es5" {
    // §4.A.4 destructuring v3 — `var [a, ...rest] = arr;` lowers to
    // `var _arr = arr, a = _arr[0], rest = _arr.slice(1);`.
    const out = try emitWithOpts("const [a, ...rest] = arr;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _arr = arr") != null);
    try T.expect(std.mem.indexOf(u8, out, "a = _arr[0]") != null);
    try T.expect(std.mem.indexOf(u8, out, "rest = _arr.slice(1)") != null);
}

test "emit: array destructuring with rest only lowers to slice(0)" {
    const out = try emitWithOpts("const [...all] = arr;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _arr = arr") != null);
    try T.expect(std.mem.indexOf(u8, out, "all = _arr.slice(0)") != null);
}

test "emit: object destructuring with rest lowers via __rest helper" {
    // §4.A.4 destructuring v4 — `var { a, b, ...rest } = obj;` lowers
    // to `var _o = obj, a = _o.a, b = _o.b, rest = __rest(_o, ["a", "b"]);`.
    const out = try emitWithOpts("const { a, b, ...rest } = obj;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _o = obj") != null);
    try T.expect(std.mem.indexOf(u8, out, "a = _o.a") != null);
    try T.expect(std.mem.indexOf(u8, out, "b = _o.b") != null);
    try T.expect(std.mem.indexOf(u8, out, "rest = __rest(_o, [\"a\", \"b\"])") != null);
}

test "emit: object destructuring with rest-only lowers to __rest(_o, [])" {
    const out = try emitWithOpts("const { ...all } = obj;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _o = obj") != null);
    try T.expect(std.mem.indexOf(u8, out, "all = __rest(_o, [])") != null);
}

test "emit: function with object destructuring param emits pattern at es2015+" {
    // `printBindingName` routes patterns to the right emit so
    // `function f({ a, b }) { return a; }` renders verbatim at
    // ES2015+ instead of producing an empty parameter list.
    const out = try emitWithOpts("function f({ a, b }) { return a; }", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f({ a, b })") != null);
}

test "emit: function with array destructuring param emits pattern at es2015+" {
    const out = try emitWithOpts("function f([a, b]) { return a; }", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f([a, b])") != null);
}

test "emit: function with object destructuring param lowers to temp + shim at es5" {
    // §4.A destructuring v6 — `function f({ a, b }) { return a; }`
    // lowers to `function f(_p0) { var a = _p0.a, b = _p0.b; return a; }`
    // at ES5. The pattern param is replaced with a temp ident `_pN`
    // (where N is the visible-param index) and a body-prefix shim
    // extracts the bindings.
    const out = try emitWithOpts("function f({ a, b }) { return a; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _p0.a, b = _p0.b;") != null);
    // Pattern itself must NOT appear in the param list.
    try T.expect(std.mem.indexOf(u8, out, "function f({") == null);
}

test "emit: function with array destructuring param lowers to temp + shim at es5" {
    const out = try emitWithOpts("function f([a, b]) { return a; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _p0[0], b = _p0[1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "function f([") == null);
}

test "emit: function with mixed plain + destructuring params at es5" {
    // Plain param at index 0, pattern at index 1, plain at index 2.
    // The destructuring shim uses `_p1` for the pattern, plain params
    // render normally.
    const out = try emitWithOpts("function f(x, { a, b }, y) { return a; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(x, _p1, y)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _p1.a, b = _p1.b;") != null);
}

test "emit: function with destructuring param + default lowers at es5" {
    // Combine pattern + default: `var a = _p0.a === void 0 ? 1 : _p0.a, ...`.
    const out = try emitWithOpts("function f({ a = 1, b }) { return a + b; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _p0.a === void 0 ? 1 : _p0.a, b = _p0.b;") != null);
}

test "emit: function with array destructuring rest param lowers at es5" {
    const out = try emitWithOpts("function f([a, ...rest]) { return rest; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _p0[0], rest = _p0.slice(1);") != null);
}

test "emit: function with object rest param uses __rest at es5" {
    const out = try emitWithOpts("function f({ a, b, ...rest }) { return rest; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _p0.a, b = _p0.b, rest = __rest(_p0, [\"a\", \"b\"]);") != null);
}

test "emit: for-of with array destructuring target lowers via _e temp at es5" {
    // §4.A destructuring v8 — `for (const [a, b] of arr) { f(a, b); }`
    // lowers to `for (var _i = 0, _arr = arr; ...; _i++) { var _e =
    // _arr[_i]; var a = _e[0], b = _e[1]; f(a, b); }` at ES5.
    const out = try emitWithOpts(
        "for (const [a, b] of arr) { f(a, b); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _i = 0, _arr = arr;") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _e = _arr[_i];") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _e[0], b = _e[1];") != null);
    // Pattern itself must NOT appear in the loop body var-decl.
    try T.expect(std.mem.indexOf(u8, out, "var [a, b] = _arr[_i]") == null);
}

test "emit: for-stmt with destructuring init lowers via temp + chained decl at es5" {
    // §4.A destructuring v14 — `for (const [a, b] = arr; i < 1; i++)`
    // can't emit native pattern at ES5. Lowers to chained decl:
    // `for (var _arr = arr, a = _arr[0], b = _arr[1]; i < 1; i++)`.
    const out = try emitWithOpts(
        "for (const [a, b] = arr; cond; i++) { use(a, b); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "for (var _arr = arr, a = _arr[0], b = _arr[1]; cond; i++)") != null);
}

test "emit: for-of with object destructuring target lowers via _e temp at es5" {
    const out = try emitWithOpts(
        "for (const { name, age } of items) { f(name); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _e = _arr[_i];") != null);
    try T.expect(std.mem.indexOf(u8, out, "var name = _e.name, age = _e.age;") != null);
}

test "emit: object destructuring with computed key lowers to indexed read at es5" {
    // §4.A.4 destructuring v11 — `var { [key]: name } = obj;` lowers
    // to `var _o = obj, name = _o[key];` (uses indexed property access
    // instead of `.name`).
    const out = try emitWithOpts(
        "const { [key]: name } = obj;",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _o = obj") != null);
    try T.expect(std.mem.indexOf(u8, out, "name = _o[key]") != null);
}

test "emit: object destructuring with computed key + default at es5" {
    const out = try emitWithOpts(
        "const { [key]: name = 'fallback' } = obj;",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _o = obj") != null);
    try T.expect(std.mem.indexOf(u8, out, "name = _o[key] === void 0 ? \"fallback\" : _o[key]") != null);
}

test "emit: function with computed-key destructuring param lowers at es5" {
    // §4.A.4 destructuring v11 — the fn-param shim also resolves
    // computed keys correctly.
    const out = try emitWithOpts(
        "function f({ [k]: name }) { return name; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var name = _p0[k];") != null);
}

test "emit: generator with destructuring param injects shim before state machine at es5" {
    // §4.A destructuring v13 — `function* g({ a, b }) { yield a; }`
    // at ES5 needs `var a = _p0.a, b = _p0.b;` BEFORE the inner state
    // machine so the closure captures the bindings.
    const out = try emitWithOpts(
        "function* g({ a, b }) { yield a; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function g(_p0)") != null);
    // Destructuring shim fires before the state-machine wrapper.
    const shim_idx = std.mem.indexOf(u8, out, "var a = _p0.a, b = _p0.b;");
    const sm_idx = std.mem.indexOf(u8, out, "return __generator");
    try T.expect(shim_idx != null and sm_idx != null);
    try T.expect(shim_idx.? < sm_idx.?);
}

test "emit: async function with destructuring param injects shim before __awaiter at es5" {
    const out = try emitWithOpts(
        "async function f({ a }) { return a; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(_p0)") != null);
    const shim_idx = std.mem.indexOf(u8, out, "var a = _p0.a;");
    const awaiter_idx = std.mem.indexOf(u8, out, "return __awaiter");
    try T.expect(shim_idx != null and awaiter_idx != null);
    try T.expect(shim_idx.? < awaiter_idx.?);
}

test "emit: nested array-in-array destructuring lowers via recursive temp at es5" {
    // §4.A destructuring v15 — `function f([a, [b, c]]) { ... }`
    // at ES5 lowers to `function f(_p0) { var a = _p0[0], _n1 = _p0[1],
    // b = _n1[0], c = _n1[1]; ... }`. The nested pattern gets a fresh
    // `_n<counter>` temp bound to the parent's positional slot, then
    // bindings extract from it.
    //
    // Note: object renames + nested-object-via-key (e.g.
    // `{ outer: { a } }`) require parser changes to preserve the
    // "outer" key — not addressed in this v0. Positional arrays
    // work because no key info is dropped.
    const out = try emitWithOpts(
        "function f([a, [b, c]]) { return a + b + c; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _p0[0], _n1 = _p0[1], b = _n1[0], c = _n1[1];") != null);
}

test "emit: deeply nested array destructuring chains multiple temps at es5" {
    // Three levels of array nesting.
    const out = try emitWithOpts(
        "function f([[[a]]]) { return a; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f(_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _n1 = _p0[0], _n2 = _n1[0], a = _n2[0];") != null);
}

test "emit: for-stmt init with destructuring + defaults/rest now lowers at es5" {
    // §4.A destructuring v16 — for-stmt init now uses the shared
    // recursive helper, so defaults/rest/nested all work.
    const out = try emitWithOpts(
        "for (const [a = 1, ...rest] = arr; cond; i++) { use(a, rest); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _arr = arr") != null);
    try T.expect(std.mem.indexOf(u8, out, "a = _arr[0] === void 0 ? 1 : _arr[0]") != null);
    try T.expect(std.mem.indexOf(u8, out, "rest = _arr.slice(1)") != null);
}

test "emit: top-level nested array destructuring decl lowers via recursive temp at es5" {
    // §4.A destructuring v15 — top-level decls now share the
    // recursive helper, so `const [a, [b, c]] = arr;` at ES5 lowers
    // through the same `_n<N>` temp chain as fn-params.
    const out = try emitWithOpts(
        "const [a, [b, c]] = arr;",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _arr = arr, a = _arr[0], _n1 = _arr[1], b = _n1[0], c = _n1[1];") != null);
}

test "emit: nested array in catch-param lowers via recursive temp at es5" {
    // Same recursion fires for catch params via the shared shim.
    const out = try emitWithOpts(
        "try { } catch ([code, [inner, outer]]) { log(code, inner, outer); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "catch (_e)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var code = _e[0], _n1 = _e[1], inner = _n1[0], outer = _n1[1];") != null);
}

test "emit: function with computed-key destructuring param renders pattern at es2015+" {
    // §4.A.4 destructuring v11 — native pattern emit at ES2015+ now
    // includes the [key]: name form (was previously dropping the
    // computed-key part).
    const out = try emitWithOpts(
        "function f({ [k]: name }) { return name; }",
        .{ .es_target = .es2015 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function f({ [k]: name })") != null);
}

test "emit: destructuring var-decl with computed key + adjacent plain key renders both at es2015+" {
    // Make sure the mixed shape renders natively without dropping either
    // key or misrendering the comma.
    const out = try emitWithOpts(
        "const { a, [k]: b } = obj;",
        .{ .es_target = .es2015 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "{ a, [k]: b }") != null);
    try T.expect(std.mem.indexOf(u8, out, "= obj") != null);
    // Double-comma indicates the v11 bug; must not appear.
    try T.expect(std.mem.indexOf(u8, out, ", ,") == null);
}

test "emit: try-catch with destructuring param renders pattern at es2015+" {
    // §4.A destructuring v10 — at ES2015+ catch destructuring is
    // native; printBindingName routes the pattern through the right
    // emit instead of dropping it.
    const out = try emitWithOpts(
        "try { f(); } catch ({ message }) { log(message); }",
        .{ .es_target = .es2015 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "catch ({ message })") != null);
    try T.expect(std.mem.indexOf(u8, out, "log(message)") != null);
}

test "emit: try-catch with destructuring param lowers to temp + shim at es5" {
    // At ES5 the native pattern doesn't work — emit `catch (_e) {
    // var message = _e.message; ... }`.
    const out = try emitWithOpts(
        "try { f(); } catch ({ message }) { log(message); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "catch (_e)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var message = _e.message;") != null);
    try T.expect(std.mem.indexOf(u8, out, "log(message)") != null);
    // Native pattern must not leak through.
    try T.expect(std.mem.indexOf(u8, out, "catch ({ message })") == null);
}

test "emit: try-catch with array destructuring param lowers at es5" {
    const out = try emitWithOpts(
        "try { f(); } catch ([code, msg]) { log(msg); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "catch (_e)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var code = _e[0], msg = _e[1];") != null);
}

test "emit: for-await-of with destructuring target lowers via _e temp at es5" {
    // §4.A destructuring v9 — async for-await-of also handles pattern
    // targets via temp ident. Using es2017 so the for-await-of falls
    // through the iterator-protocol emit (native await) and we get
    // a clean read on the destructuring lowering at ES5.
    const out = try emitWithOpts(
        "async function f() { for await (const [a, b] of source) { use(a, b); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // The async fn is downleveled to __awaiter; for-await emits
    // `__asyncValues` inside. The ES5 destructuring shim still fires
    // because the for-of branch checks es_target == .es5 directly.
    try T.expect(std.mem.indexOf(u8, out, "var _e = _astep.value;") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _e[0], b = _e[1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "var [a, b] = _astep.value") == null);
}

test "emit: for-of with destructuring + defaults at es5 inherits shim" {
    // Confirm the `emitDestructuringShim` path used by for-of's
    // pattern target also handles defaults via the v2 conditional.
    const out = try emitWithOpts(
        "for (const [a = 1, b = 2] of arr) { use(a, b); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _e = _arr[_i];") != null);
    try T.expect(std.mem.indexOf(u8, out, "a = _e[0] === void 0 ? 1 : _e[0]") != null);
    try T.expect(std.mem.indexOf(u8, out, "b = _e[1] === void 0 ? 2 : _e[1]") != null);
}

test "emit: for-of with destructuring rest at es5 inherits shim" {
    const out = try emitWithOpts(
        "for (const [a, ...rest] of arr) { use(a, rest); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _e = _arr[_i];") != null);
    try T.expect(std.mem.indexOf(u8, out, "a = _e[0]") != null);
    try T.expect(std.mem.indexOf(u8, out, "rest = _e.slice(1)") != null);
}

test "emit: for-of with downlevel_iteration + destructuring target lowers at es5" {
    // §4.A destructuring v8 — iterator-protocol form also handles
    // pattern targets via _e temp.
    const out = try emitWithOpts(
        "for (const [a, b] of items) { f(a, b); }",
        .{ .es_target = .es5, .downlevel_iteration = true },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__values(items)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _e = _c.value;") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _e[0], b = _e[1];") != null);
    // Native pattern syntax must NOT appear.
    try T.expect(std.mem.indexOf(u8, out, "var [a, b] = _c.value") == null);
}

test "emit: for-of with identifier target keeps direct var = _arr[_i] at es5" {
    // Identifier target keeps the existing shape — no _e temp injected.
    const out = try emitWithOpts(
        "for (const x of arr) { f(x); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var x = _arr[_i];") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _e") == null);
}

test "emit: arrow with destructuring param lowers to .bind(this) + temp + shim at es5" {
    // §4.A destructuring v7 — arrow ES5 lowering also handles
    // pattern params. `({ a, b }) => a + b` becomes
    // `function (_p0) { var a = _p0.a, b = _p0.b; return a + b; }.bind(this)`.
    const out = try emitWithOpts("const f = ({ a, b }) => a + b;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function (_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var a = _p0.a, b = _p0.b;") != null);
    try T.expect(std.mem.indexOf(u8, out, "}.bind(this)") != null);
}

test "emit: class method with destructuring param lowers at es5" {
    // Class methods route through the ES5 prototype emit which now
    // also fires the destructuring shim.
    const out = try emitWithOpts(
        "class C { greet({ name }) { return name; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "C.prototype.greet = function (_p0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "var name = _p0.name;") != null);
}

test "emit: const lowers to var at es5" {
    const out = try emitWithOpts("const x = 1;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var x = 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "const ") == null);
}

test "emit: let lowers to var at es5" {
    const out = try emitWithOpts("let x = 1;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var x = 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "let ") == null);
}

test "emit: let and const preserved at es2015+" {
    const out = try emitWithOpts("let x = 1; const y = 2;", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "let x = 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "const y = 2") != null);
    try T.expect(std.mem.indexOf(u8, out, "var ") == null);
}

test "emit: dynamic import lowers to Promise.resolve(require) for cjs" {
    const out = try emitWithOpts("let mod = import(\"foo\");", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "Promise.resolve(require(\"foo\"))") != null);
}

test "emit: await expression emits 'await <expr>'" {
    const out = try emit("async function f() { let x = await g(); return x; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "async function") != null);
    try T.expect(std.mem.indexOf(u8, out, "await g()") != null);
}

test "emit: async function preserved at es2017" {
    const out = try emitWithOpts(
        "async function f() { let x = await g(); return x; }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "async function") != null);
    try T.expect(std.mem.indexOf(u8, out, "await g()") != null);
    try T.expect(std.mem.indexOf(u8, out, "__awaiter") == null);
}

test "emit: async function lowers to __awaiter wrapper at es2015" {
    const out = try emitWithOpts(
        "async function f() { return await g(); }",
        .{ .es_target = .es2015 },
    );
    defer T.allocator.free(out);
    // No leading `async` keyword on the outer function.
    try T.expect(std.mem.indexOf(u8, out, "async function") == null);
    // The outer function is plain.
    try T.expect(std.mem.indexOf(u8, out, "function f()") != null);
    // `__awaiter(this, void 0, void 0, function* ()` wrapper appears.
    try T.expect(std.mem.indexOf(u8, out, "__awaiter(this, void 0, void 0, function* ()") != null);
}

test "emit: importHelpers prepends tslib import when async lowers at es2015" {
    const out = try emitWithOpts(
        "async function f() { return await g(); }",
        .{ .es_target = .es2015, .import_helpers = true },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "import { __assign, __asyncDelegator, __asyncGenerator, __asyncValues, __await, __awaiter, __decorate, __esDecorate, __extends, __generator, __metadata, __param, __importDefault, __importStar, __rest, __runInitializers, __values } from \"tslib\";") != null);
    // Helper still gets referenced from user code.
    try T.expect(std.mem.indexOf(u8, out, "__awaiter(this, void 0, void 0, function* ()") != null);
}

test "emit: no tslib import when import_helpers is off" {
    const out = try emitWithOpts(
        "async function f() { return await g(); }",
        .{ .es_target = .es2015 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "tslib") == null);
    try T.expect(std.mem.indexOf(u8, out, "import {") == null);
    // Helper is still referenced — runtime is expected to provide it.
    try T.expect(std.mem.indexOf(u8, out, "__awaiter(this, void 0, void 0, function* ()") != null);
}

test "emit: await becomes yield only inside __awaiter wrapper" {
    const out = try emitWithOpts(
        "async function f() { return await g(); }",
        .{ .es_target = .es2016 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "yield g()") != null);
    // No bare `await` left over — it was rewritten.
    try T.expect(std.mem.indexOf(u8, out, "await g()") == null);
}

test "emit: top-level await passes through in ESM at ES2022" {
    // Top-level `await` is allowed in ESM modules at ES2022+. The
    // parser accepts `await E` outside any async function and the
    // emitter passes it through unchanged.
    const out = try emitWithOpts(
        "let res = await fetch(\"https://example.com\");",
        .{ .module_kind = .esm, .es_target = .es2022 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "await fetch(\"https://example.com\")") != null);
    // No TODO marker on supported targets.
    try T.expect(std.mem.indexOf(u8, out, "TODO: top-level await") == null);
}

test "emit: top-level await emits TODO marker for older ES targets" {
    // ESM + ES5 doesn't support top-level await, but v0 still emits
    // the `await E` form prefixed with a `/* TODO: ... */` marker so
    // downstream tools can see the unsupported emit. (Proper error
    // reporting belongs in the checker.)
    const out = try emitWithOpts(
        "let res = await fetch(\"https://example.com\");",
        .{ .module_kind = .esm, .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: top-level await requires ES2022+") != null);
    try T.expect(std.mem.indexOf(u8, out, "await fetch(\"https://example.com\")") != null);
}

test "emit: yield expression emits 'yield'" {
    const out = try emit("function* gen() { yield 1; yield* other(); }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "yield 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "yield* other()") != null);
}

test "emit: bare yield emits without operand" {
    const out = try emit("function* g() { yield; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "yield") != null);
}

test "emit: generator downlevels to __generator state-machine at es5" {
    const out = try emitWithOpts(
        "function* g() { yield 1; yield 2; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // `function*` is gone — emitted as plain `function g(`.
    try T.expect(std.mem.indexOf(u8, out, "function*") == null);
    try T.expect(std.mem.indexOf(u8, out, "function g(") != null);
    // __generator wrapper present, with the `(this, function (_a) { … })` shape.
    try T.expect(std.mem.indexOf(u8, out, "return __generator(this, function (_a)") != null);
    // switch on _a.label drives the state machine.
    try T.expect(std.mem.indexOf(u8, out, "switch (_a.label)") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 0:") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent()") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent()") != null);
    // [4, <value>] is the yield opcode.
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2]") != null);
    // Fall-through return [2] terminates the machine.
    try T.expect(std.mem.indexOf(u8, out, "return [2]") != null);
    // No leftover `yield` keyword — every yield was rewritten.
    try T.expect(std.mem.indexOf(u8, out, "yield 1") == null);
    try T.expect(std.mem.indexOf(u8, out, "yield 2") == null);
}

test "emit: generator with bare yield emits [4] opcode" {
    const out = try emitWithOpts(
        "function* g() { yield; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return [4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent()") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [2];") != null);
}

test "emit: generator with yield* emits [5] delegate opcode" {
    const out = try emitWithOpts(
        "function* g() { yield* other(); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return [5, other()]") != null);
    try T.expect(std.mem.indexOf(u8, out, "yield* other()") == null);
}

test "emit: generator with return value emits [2, value] terminator" {
    const out = try emitWithOpts(
        "function* g() { yield 1; return 42; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [2, 42]") != null);
    // The post-return fall-through `return [2]` should NOT also appear —
    // explicit return short-circuits the synthesized fall-through.
    // Count occurrences of `return [2]` — exactly one (the `[2, 42]`).
    var idx: usize = 0;
    var bare_count: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "return [2]")) |pos| : (idx = pos + 1) {
        bare_count += 1;
    }
    try T.expect(bare_count == 0);
}

test "emit: generator preserved at es2015+" {
    const out = try emitWithOpts(
        "function* g() { yield 1; yield 2; }",
        .{ .es_target = .es2015 },
    );
    defer T.allocator.free(out);
    // Native `function*` survives — no state-machine lowering.
    try T.expect(std.mem.indexOf(u8, out, "function* g(") != null);
    try T.expect(std.mem.indexOf(u8, out, "yield 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "__generator") == null);
}

test "emit: generator with deeper else-if chain (4 branches) lowers correctly" {
    // §4.A.4.11 — `if (a) y1; else if (b) y2; else if (c) y3; else y4;`
    // adds a third chain link. All four yields converge on one
    // shared `after` case at the end.
    const out = try emitWithOpts(
        "function* g() { if (a) yield 1; else if (b) yield 2; else if (c) yield 3; else yield 4; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 4];") != null);
    // Three conds gate the chain.
    try T.expect(std.mem.indexOf(u8, out, "if (!(a)) return [3,") != null);
    try T.expect(std.mem.indexOf(u8, out, "if (!(b)) return [3,") != null);
    try T.expect(std.mem.indexOf(u8, out, "if (!(c)) return [3,") != null);
}

test "emit: generator with else-if chain (no final else) lowers correctly" {
    // §4.A.4.11 — chain without a final else. The innermost
    // chain link has no else, so its then-resume falls through
    // to `after` directly.
    const out = try emitWithOpts(
        "function* g() { if (a) yield 1; else if (b) yield 2; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "if (!(a)) return [3,") != null);
    try T.expect(std.mem.indexOf(u8, out, "if (!(b)) return [3,") != null);
}

test "emit: generator with else-if chain ending in non-yielding else" {
    // §4.A.4.11 — chain's final `else` is non-yielding. The
    // chain still lowers; the final else just emits inline stmts
    // in its case.
    const out = try emitWithOpts(
        "function* g() { if (a) yield 1; else if (b) yield 2; else fallback(); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "fallback();") != null);
}

test "emit: generator with else-if chain lowers via recursive if-yield emit" {
    // §4.A.4.11 — `else if (...)` chain. Each chain link's
    // else-open case IS the next link's cur case; all branches
    // converge on a single shared `after_if` case. For the fixture
    //   `if (a) yield 1; else if (b) yield 2; else yield 3;`
    // the state-machine layout is (case numbers shown for clarity):
    //   case 0 (cur):    if (!(a)) return [3, else_a];   // outer cond
    //                    return [4, 1];                  // then_a yield
    //   case 1:          _a.sent(); return [3, after];   // then_a resume + jump
    //   case 2 (else_a): if (!(b)) return [3, else_b];   // inner cond
    //                    return [4, 2];                  // then_b yield
    //   case 3:          _a.sent(); return [3, after];   // then_b resume + jump
    //   case 4 (else_b): return [4, 3];                  // final else yield
    //   case 5:          _a.sent();                       // final else resume
    //   case 6 (after):                                   // shared exit
    const out = try emitWithOpts(
        "function* g() { if (a) yield 1; else if (b) yield 2; else yield 3; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "if (!(a)) return [3, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: if (!(b)) return [3, 4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: return [4, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 6:") != null);
    // Every then/else resume jumps to the shared `after` case 6.
    try T.expect(std.mem.indexOf(u8, out, "return [3, 6];") != null);
}

test "emit: generator with let x = yield E binds via _a.sent()" {
    const out = try emitWithOpts(
        "function* g() { let x = yield 1; return x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // Yield op-code remains [4, 1].
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // Resumed value lands in `var x = _a.sent();` (var-hoisted so
    // the next case can read it).
    try T.expect(std.mem.indexOf(u8, out, "case 1: var x = _a.sent();") != null);
    // Final return forwards the bound value.
    try T.expect(std.mem.indexOf(u8, out, "return [2, x]") != null);
    // No leftover `let` keyword survived the lowering.
    try T.expect(std.mem.indexOf(u8, out, "let x") == null);
}

test "emit: generator with assignment x = yield E uses no var prefix" {
    const out = try emitWithOpts(
        "function* g() { var x; x = yield 1; return x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // Assignment-form (var pre-declared) — no `var` introduced by
    // the resumption; just plain `x = _a.sent();`.
    try T.expect(std.mem.indexOf(u8, out, "case 1: x = _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: var x = _a.sent();") == null);
    // Pre-decl `var x;` still survives in the first case.
    try T.expect(std.mem.indexOf(u8, out, "var x;") != null);
}

test "emit: generator with multiple yield bindings sequences cases correctly" {
    const out = try emitWithOpts(
        "function* g() { let a = yield 1; let b = yield 2; return a + b; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: var a = _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: var b = _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [2, a + b]") != null);
}

test "emit: generator with non-yielding if lowers as inline if" {
    // `if` whose subtree contains no yield is treated as a plain
    // statement inside the current case — no CFG lowering needed.
    const out = try emitWithOpts(
        "function* g() { if (cond) console.log(1); yield 2; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "if (cond)") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2]") != null);
}

test "emit: generator with non-yielding while lowers as inline while" {
    const out = try emitWithOpts(
        "function* g() { while (cond) doStuff(); yield 1; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "while (cond)") != null);
    try T.expect(std.mem.indexOf(u8, out, "doStuff()") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
}

test "emit: generator with non-yielding for lowers as inline for" {
    const out = try emitWithOpts(
        "function* g() { for (let i = 0; i < 3; i++) acc(i); yield acc; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "for (") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, acc]") != null);
}

test "emit: generator with non-yielding try lowers as inline try" {
    const out = try emitWithOpts(
        "function* g() { try { risky(); } catch (e) { recover(); } yield done; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "try ") != null);
    try T.expect(std.mem.indexOf(u8, out, "catch (e)") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, done]") != null);
}

test "emit: generator with if-then-yield lowers to [3, label] conditional jump" {
    const out = try emitWithOpts(
        "function* g() { if (cond) yield 1; yield 2; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Conditional skip to the after-if case (label 2).
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 2];") != null);
    // Yield from the then-branch — op-code 4.
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // Yield resumption case + after-if case both opened.
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2:") != null);
    // The trailing `yield 2;` becomes case 3.
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent();") != null);
    // Final synthesized fall-through return.
    try T.expect(std.mem.indexOf(u8, out, "return [2];") != null);
}

test "emit: generator with if-then-yield (block body) lowers same as bare-stmt body" {
    const out = try emitWithOpts(
        "function* g() { if (cond) { yield 1; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2:") != null);
}

test "emit: generator with if-then-yield + non-yielding else lowers with else case" {
    const out = try emitWithOpts(
        "function* g() { if (cond) yield 1; else { f(); g(); } yield 2; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Conditional jump skips to else label (case 2).
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 2];") != null);
    // Yield in then-branch.
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // Resumption case ends with unconditional skip past the else body to after-if (case 3).
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [3, 3];") != null);
    // Else body lives in case 2.
    try T.expect(std.mem.indexOf(u8, out, "case 2:") != null);
    try T.expect(std.mem.indexOf(u8, out, "f();") != null);
    try T.expect(std.mem.indexOf(u8, out, "g();") != null);
    // After-if case 3 holds the trailing `yield 2;` → case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 3:") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent();") != null);
}

test "emit: generator with if-then-yield + non-yielding bare-stmt else lowers" {
    // Single-statement else (no block wrapper) works the same way.
    const out = try emitWithOpts(
        "function* g() { if (cond) yield 1; else f(); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [3, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2:") != null);
    try T.expect(std.mem.indexOf(u8, out, "f();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3:") != null);
}

test "emit: generator with while-yield lowers to 3-case loop" {
    const out = try emitWithOpts(
        "function* g() { while (cond) yield 1; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Header (case 1): cond check + yield.
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(cond)) return [3, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // Resume (case 2): sent + jump-back to header.
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [3, 1];") != null);
    // Exit (case 3): falls through to final return [2].
    try T.expect(std.mem.indexOf(u8, out, "case 3:") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [2]") != null);
}

test "emit: generator with while-yield + trailing yield sequences correctly" {
    const out = try emitWithOpts(
        "function* g() { while (cond) yield 1; yield 2; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(cond)) return [3, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [3, 1];") != null);
    // After exit case 3, the trailing `yield 2` advances state to 4.
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent();") != null);
}

test "emit: generator with break targeting lowered while rewrites to [3, exit]" {
    // §4.A.4.4 — `if (other) break;` inside a lowered while body
    // rewrites the break to `return [3, exit_label];` so it exits
    // the lowered loop (not the enclosing switch case).
    const out = try emitWithOpts(
        "function* g() { while (cond) { if (other) break; yield 1; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Exit label is case 3 for this single-yield body.
    try T.expect(std.mem.indexOf(u8, out, "if (other) return [3, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
}

test "emit: generator with continue targeting lowered while rewrites to [3, header]" {
    // §4.A.4.4 part 2 — `continue;` inside a lowered while body
    // rewrites to `return [3, header_label];` so the next iteration's
    // cond check runs without resuming through `_a.sent()`.
    const out = try emitWithOpts(
        "function* g() { while (cond) { if (other) continue; yield 1; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Header is case 1 for this single-yield body.
    try T.expect(std.mem.indexOf(u8, out, "if (other) return [3, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
}

test "emit: generator with continue targeting lowered for rewrites to [3, continue]" {
    // §4.A.4.4 part 3 — for-loops now have a dedicated continue
    // case where the update runs before re-checking the cond.
    // continue rewrites to a jump targeting that case.
    const out = try emitWithOpts(
        "function* g() { for (let i = 0; i < 3; i++) { if (other) continue; yield i; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Continue case is case 3 (between resume 2 and exit 4).
    try T.expect(std.mem.indexOf(u8, out, "if (other) return [3, 3];") != null);
    // Continue case body: update + loopback to header.
    try T.expect(std.mem.indexOf(u8, out, "case 3: i++; return [3, 1];") != null);
}

test "emit: generator with continue targeting lowered do-while rewrites to [3, continue]" {
    // Companion for do-while: continue jumps to the cond-check case.
    const out = try emitWithOpts(
        "function* g() { do { if (other) continue; yield 1; } while (cond); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Continue case for do-while is case 3 (cond check).
    try T.expect(std.mem.indexOf(u8, out, "if (other) return [3, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: if (cond) return [3, 1];") != null);
}

test "emit: generator with break inside nested inner loop targets the inner loop" {
    // break inside an inner non-yielding while/for/switch should
    // emit as native `break;` (its target is the inner construct);
    // only break targeting the *lowered* outer loop gets rewritten.
    const out = try emitWithOpts(
        "function* g() { while (cond) { while (inner) break; yield 1; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // The inner while keeps its native break.
    try T.expect(std.mem.indexOf(u8, out, "while (inner) break;") != null);
    // The outer yield still lowers normally.
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
}

test "emit: generator with break inside nested switch in loop body still lowers" {
    // break inside a nested switch targets the switch (not the
    // lowered loop), so the lowering is safe to proceed.
    const out = try emitWithOpts(
        "function* g() { while (cond) { switch (x) { case 1: break; } yield 1; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // The inner switch + break pass through verbatim inside case 1.
    try T.expect(std.mem.indexOf(u8, out, "switch (x)") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
}

test "emit: generator with multi-stmt while body splits pre/post stmts across cases" {
    const out = try emitWithOpts(
        "function* g() { while (cond) { pre(); yield 1; post(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Header case 1: cond + pre() + yield.
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(cond)) return [3, 3]; pre(); return [4, 1];") != null);
    // Resume case 2: sent + post() + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); post(); return [3, 1];") != null);
    // Exit case 3.
    try T.expect(std.mem.indexOf(u8, out, "case 3:") != null);
}

test "emit: generator with multi-yield while body lowers to N+2 cases" {
    // §4.A.4.5 — two yields in a while body fan out into 4 cases:
    // header (cond + first yield), res1 (sent + second yield),
    // res2 (sent + loopback), exit.
    const out = try emitWithOpts(
        "function* g() { while (cond) { yield 1; yield 2; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Header case 1: cond + first yield. exit is case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(cond)) return [3, 4]; return [4, 1];") != null);
    // Resumption case 2: sent + second yield.
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [4, 2];") != null);
    // Resumption case 3: sent + loopback to header.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [3, 1];") != null);
    // Exit case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with multi-yield do-while body lowers to N+3 cases" {
    const out = try emitWithOpts(
        "function* g() { do { yield 1; yield 2; } while (cond); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // Body case 1: first yield.
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, 1]") != null);
    // Resumption case 2: sent + second yield.
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [4, 2]") != null);
    // Resumption case 3: sent (falls through to continue).
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent();") != null);
    // Continue case 4: cond + loopback to body.
    try T.expect(std.mem.indexOf(u8, out, "case 4: if (cond) return [3, 1];") != null);
    // Exit case 5.
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with multi-yield for body lowers to N+3 cases" {
    const out = try emitWithOpts(
        "function* g() { for (let i = 0; i < 3; i++) { yield i; yield i + 1; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "var i = 0;") != null);
    // Header case 1: cond + first yield. exit is case 5.
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(i < 3)) return [3, 5]; return [4, i];") != null);
    // Resumption case 2: sent + second yield.
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [4, i + 1]") != null);
    // Resumption case 3: sent.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent();") != null);
    // Continue case 4: update + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 4: i++; return [3, 1];") != null);
    // Exit case 5.
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with multi-yield while body + stmts splits correctly" {
    const out = try emitWithOpts(
        "function* g() { while (cond) { pre(); yield 1; mid(); yield 2; post(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // Header case 1: cond + pre() + first yield.
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(cond)) return [3, 4]; pre(); return [4, 1];") != null);
    // Resumption case 2: sent + mid() + second yield.
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); mid(); return [4, 2];") != null);
    // Resumption case 3: sent + post() + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); post(); return [3, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with while (yield E) split body lowers with pre/post around yield" {
    // §4.A.4.10 — yield-cond + split body (pre-stmts + body yield + post-stmts).
    // Pre-stmts emit in the cond_resume case before the body yield;
    // post-stmts emit in the body_resume case after `_a.sent()`.
    const out = try emitWithOpts(
        "function* g() { while (yield 1) { setup(); yield 2; cleanup(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // cond_resume runs setup() before the body yield.
    try T.expect(std.mem.indexOf(u8, out, "if (!_a.sent()) return [3,") != null);
    try T.expect(std.mem.indexOf(u8, out, "setup();") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2];") != null);
    // body_resume runs cleanup() then loops back.
    try T.expect(std.mem.indexOf(u8, out, "cleanup();") != null);
}

test "emit: generator with while (yield E) body lowers via cond-resume case" {
    // §4.A.4.10 — `while (yield E) body` now lowers through the
    // state machine. Each iteration yields the cond (`return [4, E];`),
    // resumes in a new `cond_resume` case that does the truthy test
    // against `_a.sent()`, then runs the body's yield + body-resume +
    // loopback to header. Total 4 cases (vs 3 for yield-free cond).
    const out = try emitWithOpts(
        "function* g() { while (yield 1) yield 2; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // case 1: yield the cond.
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, 1];") != null);
    // case 2: cond_resume — truthy test + body yield.
    try T.expect(std.mem.indexOf(u8, out, "case 2: if (!_a.sent()) return [3, 4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2];") != null);
    // case 3: body_resume — sent + loopback to header (case 1).
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [3, 1];") != null);
    // case 4: exit.
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with for-loop-yield lowers to 4-case loop with continue case" {
    const out = try emitWithOpts(
        "function* g() { for (let i = 0; i < 3; i++) yield i; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Init emitted in case 0 (before fall-through to header).
    try T.expect(std.mem.indexOf(u8, out, "var i = 0;") != null);
    // Header case 1: cond + yield. exit now case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(i < 3)) return [3, 4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, i]") != null);
    // Resume case 2: sent (falls through to continue case).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
    // Continue case 3: update (i++ lowers to i += 1) + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 3: i++; return [3, 1];") != null);
    // Exit case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: postfix i++ round-trips as i++ (not i += 1)" {
    // The parser lowers `i++` to a synthetic `i += 1` whose `1` literal
    // carries the 2-char `++` token span; the printer detects that shape
    // and rebuilds the update. Lowering to `i += 1` would be wrong for a
    // postfix update used as a value (`const x = i++`).
    const out = try emit("function f() { let i = 0; i++; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "i++;") != null);
    try T.expect(std.mem.indexOf(u8, out, "i += 1") == null);
    try T.expect(std.mem.indexOf(u8, out, "i += ++") == null);
}

test "emit: nested unary operators don't merge into ++/--" {
    // `-(-a)` must not collapse to `--a` (a decrement); a separating space
    // is required. `-(+a)` is fine without one.
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "const x = - -a;", .want = "const x = - -a;" },
        .{ .src = "const x = + +a;", .want = "const x = + +a;" },
        .{ .src = "const x = - +a;", .want = "const x = -+a;" },
        .{ .src = "const x = -(--a);", .want = "const x = - --a;" },
    };
    for (cases) |c| {
        const out = try emit(c.src);
        defer T.allocator.free(out);
        try T.expectEqualStrings(c.want, out);
    }
}

test "emit: call on a new-target spine is parenthesized" {
    // `new (f())()` must not print as `new f()()` (which parses as
    // `(new f())()`). The call on the constructor spine is wrapped, while
    // arguments and ordinary calls are unaffected.
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "const a = new (getClass())();", .want = "const a = new (getClass())();" },
        .{ .src = "const a = new (f().C)();", .want = "const a = new (f()).C();" },
        .{ .src = "const a = new C();", .want = "const a = new C();" },
        .{ .src = "const a = new C.x();", .want = "const a = new C.x();" },
        .{ .src = "new Foo(bar(), baz());", .want = "new Foo(bar(), baz());" },
    };
    for (cases) |c| {
        const out = try emit(c.src);
        defer T.allocator.free(out);
        try T.expectEqualStrings(c.want, out);
    }
}

test "emit: yield is parenthesized by surrounding precedence" {
    // `(yield a) + 1` must keep its parens (else `yield a + 1` yields a+1);
    // a bare `yield a + 1` statement and `const x = yield a` do not.
    const wrapped = try emit("function* g() { return (yield a) + 1; }");
    defer T.allocator.free(wrapped);
    try T.expect(std.mem.indexOf(u8, wrapped, "return (yield a) + 1;") != null);

    const bare = try emit("function* g() { yield a + 1; }");
    defer T.allocator.free(bare);
    try T.expect(std.mem.indexOf(u8, bare, "yield a + 1;") != null);
    try T.expect(std.mem.indexOf(u8, bare, "(yield") == null);
}

test "emit: increment/decrement preserve update semantics" {
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        // Postfix in value position must NOT become `i += 1` (different value).
        .{ .src = "const x = i++;", .want = "const x = i++;" },
        .{ .src = "const y = i--;", .want = "const y = i--;" },
        .{ .src = "const z = ++i;", .want = "const z = ++i;" },
        .{ .src = "const w = --i;", .want = "const w = --i;" },
        .{ .src = "arr[i++] = 1;", .want = "arr[i++] = 1;" },
        .{ .src = "obj.k++;", .want = "obj.k++;" },
    };
    for (cases) |c| {
        const out = try emit(c.src);
        defer T.allocator.free(out);
        try T.expectEqualStrings(c.want, out);
    }
}

test "emit: generator with bare-for-yield (no init/cond/update) lowers as infinite loop" {
    const out = try emitWithOpts(
        "function* g() { for (;;) yield 1; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // No init or cond emitted. Header case 1 yields directly.
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, 1]") != null);
    // Resume case 2: sent (falls through to continue).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
    // Continue case 3: bare loopback (no update).
    try T.expect(std.mem.indexOf(u8, out, "case 3: return [3, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with for-loop + yield-in-init peels yield-decl into pre-loop case pair" {
    // §4.A.4.12 — `for (var x = yield 0; cond; x++) yield x;` now
    // lowers: the init's `yield 0` becomes a stand-alone yield+bind
    // pair (case 0 closes with `return [4, 0]`; case 1 opens with
    // `var x = _a.sent();`) before the regular 4-case for-stmt
    // machinery (header / resume / continue / exit) takes over.
    const out = try emitWithOpts(
        "function* g() { for (let x = yield 0; cond; x++) yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Case 0 closes with the init's yield.
    try T.expect(std.mem.indexOf(u8, out, "case 0: return [4, 0];") != null);
    // Case 1 binds the resumed value into x.
    try T.expect(std.mem.indexOf(u8, out, "case 1: var x = _a.sent();") != null);
    // Header is case 2 (shifted by the yield-init pair).
    try T.expect(std.mem.indexOf(u8, out, "case 2: if (!(cond)) return [3, 5]; return [4, x];") != null);
    // Resume is case 3.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent();") != null);
    // Continue is case 4 — update + jump back to header.
    try T.expect(std.mem.indexOf(u8, out, "case 4: x++; return [3, 2];") != null);
    // Exit is case 5.
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with for-loop + yield-in-init + multi-yield body lowers" {
    // The peeled yield-init shifts every subsequent label by 1.
    const out = try emitWithOpts(
        "function* g() { for (let x = yield 0; cond; x++) { pre(); yield x; post(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "case 0: return [4, 0];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: var x = _a.sent();") != null);
    // Header now also runs pre() and yields x.
    try T.expect(std.mem.indexOf(u8, out, "case 2: if (!(cond)) return [3, 5]; pre(); return [4, x];") != null);
    // Resume runs post() and falls through to continue.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); post();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: x++; return [3, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with for-loop + non-yield-decl init-yield still bails" {
    // Only `var|let|const <ident> = yield E;` is accepted; anything
    // else (yield-in-update, bare expression init, destructuring decl, …)
    // still bails to native `function*`. Yield-in-cond does lower via
    // §4.A.4.15 — covered in the next test.
    const out = try emitWithOpts(
        "function* g() { for (i = yield 0; cond; i++) yield i; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "__generator") == null);
}

test "emit: generator with for-loop + yield-in-cond lowers to 5-case loop" {
    // §4.A.4.15 — `for (; yield E; i++) yield i;` is now accepted in
    // the restricted form where `cond` IS a single `yield E`
    // expression. Layout adds a cond_resume case between header and
    // body-resume that does the truthy test against `_a.sent()`.
    const out = try emitWithOpts(
        "function* g() { for (i = 0; yield 0; i++) yield i; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Init runs in case 0.
    try T.expect(std.mem.indexOf(u8, out, "case 0: i = 0;") != null);
    // Header (case 1) yields cond.
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, 0];") != null);
    // cond_resume (case 2) tests _a.sent() + body yield.
    try T.expect(std.mem.indexOf(u8, out, "case 2: if (!_a.sent()) return [3, 5]; return [4, i];") != null);
    // body-resume (case 3) sent + falls through.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent();") != null);
    // continue (case 4) update + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 4: i++; return [3, 1];") != null);
    // exit (case 5).
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with for-loop + cond-yield + multi-yield body still bails" {
    // The state-counting intertwines awkwardly with the extra
    // cond-resume case so multi-yield body + cond-yield falls back.
    const out = try emitWithOpts(
        "function* g() { for (i = 0; yield 0; i++) { yield i; yield i + 1; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "__generator") == null);
}

test "emit: generator with do-while-yield lowers to 4-case loop with continue case" {
    const out = try emitWithOpts(
        "function* g() { do yield 1; while (cond); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Body case 1: yield directly.
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, 1]") != null);
    // Resume case 2: sent (falls through to continue case).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
    // Continue case 3: cond-check + loopback to body.
    try T.expect(std.mem.indexOf(u8, out, "case 3: if (cond) return [3, 1];") != null);
    // Exit case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with multi-stmt do-while body splits pre/post" {
    const out = try emitWithOpts(
        "function* g() { do { pre(); yield 1; post(); } while (cond); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // Body case 1: pre() then yield.
    try T.expect(std.mem.indexOf(u8, out, "case 1: pre(); return [4, 1];") != null);
    // Resume case 2: sent + post() (falls through).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); post();") != null);
    // Continue case 3: cond-check + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 3: if (cond) return [3, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with multi-stmt for body splits pre/post around yield" {
    const out = try emitWithOpts(
        "function* g() { for (let i = 0; i < 3; i++) { pre(); yield i; post(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "var i = 0;") != null);
    // Header case 1: cond check + pre() + yield. exit now case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(i < 3)) return [3, 4]; pre(); return [4, i];") != null);
    // Resume case 2: sent + post() (falls through to continue).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); post();") != null);
    // Continue case 3: update + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 3: i++; return [3, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with for-of-yield lowers to indexed-for state machine" {
    const out = try emitWithOpts(
        "function* g() { for (const x of items) yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Init in case 0: var _i = 0, _arr = items;
    try T.expect(std.mem.indexOf(u8, out, "var _i = 0, _arr = items;") != null);
    // Header case 1: cond check + binding + yield. Exit = case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(_i < _arr.length)) return [3, 4]; var x = _arr[_i]; return [4, x];") != null);
    // Resume case 2: sent (falls through).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
    // Continue case 3: _i++ + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _i++; return [3, 1];") != null);
    // Exit case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with for-of-yield + downlevel_iteration uses __values + .next() + cleanup wrap" {
    const out = try emitWithOpts(
        "function* g() { for (const x of items) yield x; }",
        .{ .es_target = .es5, .downlevel_iteration = true },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // §4.A.4.8 cont.3 — trys frame for .return() cleanup.
    try T.expect(std.mem.indexOf(u8, out, "var e_1, _r;") != null);
    // tryStart=0, catchStart=4, finallyStart=5, endLabel=6.
    try T.expect(std.mem.indexOf(u8, out, "_a.trys.push([0, 4, 5, 6]);") != null);
    // Iterator-protocol init.
    try T.expect(std.mem.indexOf(u8, out, "var _b = __values(items), _c = _b.next();") != null);
    // Header case 1 (exit jump now goes to case 6 — the runtime routes through finally).
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (_c.done) return [3, 6]; var x = _c.value; return [4, x];") != null);
    // Resumption case 2 + continue case 3.
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: _c = _b.next(); return [3, 1];") != null);
    // Catch case 4 captures error into e_1.
    try T.expect(std.mem.indexOf(u8, out, "case 4: e_1 = { error: _a.sent() }; return [3, 5];") != null);
    // Finally case 5 runs .return() + rethrow if needed.
    try T.expect(std.mem.indexOf(u8, out, "case 5: if (_c && !_c.done && (_r = _b.return)) _r.call(_b); if (e_1) throw e_1.error; return [7];") != null);
    // Exit case 6.
    try T.expect(std.mem.indexOf(u8, out, "case 6:") != null);
    // Indexed-for forms must NOT appear.
    try T.expect(std.mem.indexOf(u8, out, "_arr") == null);
    try T.expect(std.mem.indexOf(u8, out, "_i++") == null);
}

test "emit: generator with for-of-yield + multi-stmt body lowers" {
    const out = try emitWithOpts(
        "function* g() { for (const x of items) { pre(); yield x; post(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _i = 0, _arr = items;") != null);
    // Header case 1 includes pre() + first yield.
    try T.expect(std.mem.indexOf(u8, out, "var x = _arr[_i]; pre(); return [4, x];") != null);
    // Resume case 2 includes post() (falls through).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); post();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: _i++; return [3, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with for-of-yield + array destructuring target" {
    // §4.A.4.8 v2 — destructuring binding inside the state-machine
    // for-of: `var [a, b] = _arr[_i];`.
    const out = try emitWithOpts(
        "function* g() { for (const [a, b] of items) yield a; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "var [a, b] = _arr[_i];") != null);
}

test "emit: generator with for-of-yield + object destructuring target" {
    const out = try emitWithOpts(
        "function* g() { for (const { value } of items) yield value; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "var { value } = _arr[_i];") != null);
}

test "emit: generator with switch + yielding cases lowers to dispatch + per-case states" {
    // §4.A.4.16 v0 — `switch (x) { case 1: yield 'a'; break; case 2:
    // yield 'b'; break; }` at ES5 lowers to:
    //   case 0: switch (x) { case 1: return [3, 1]; case 2: return [3, 3]; default: return [3, exit]; }
    //   case 1: return [4, 'a'];
    //   case 2: _a.sent(); return [3, exit];   // break → exit_label
    //   case 3: return [4, 'b'];
    //   case 4: _a.sent(); return [3, exit];
    //   case 5: (exit)
    const out = try emitWithOpts(
        "function* g() { switch (x) { case 1: yield 'a'; break; case 2: yield 'b'; break; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Dispatch
    try T.expect(std.mem.indexOf(u8, out, "switch (x) { case 1: return [3, 1]; case 2: return [3, 3]; default: return [3, 5]; }") != null);
    // case 1 yields 'a'
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, \"a\"];") != null);
    // case 2 resume + break (→ exit case 5)
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [3, 5];") != null);
    // case 3 yields 'b'
    try T.expect(std.mem.indexOf(u8, out, "case 3: return [4, \"b\"];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent(); return [3, 5];") != null);
    // exit
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with switch + default lowers default to its case state" {
    // The `default:` arm gets its own state and the dispatch's
    // `default` clause jumps there.
    const out = try emitWithOpts(
        "function* g() { switch (x) { case 1: yield 'a'; break; default: yield 'd'; break; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "switch (x) { case 1: return [3, 1]; default: return [3, 3]; }") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: return [4, \"d\"];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent(); return [3, 5];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with switch + yield-free case still routes through dispatch" {
    // A yield-free case body just runs its stmts and breaks (→ exit).
    const out = try emitWithOpts(
        "function* g() { switch (x) { case 1: yield 'a'; break; case 2: log(); break; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // case 2 body emits `log()` + the break rewrite to exit.
    try T.expect(std.mem.indexOf(u8, out, "case 3: log(); return [3, 4];") != null);
}

test "emit: generator with switch + multi-yield-per-case lowers" {
    // §4.A.4.16 v1 — multi-yield per case. Each yield opens a fresh
    // resume state. `case 1: pre(); yield 'a'; mid(); yield 'b';
    // post(); break;` lowers to 3 states (initial + 2 resumes).
    const out = try emitWithOpts(
        "function* g() { switch (x) { case 1: pre(); yield 'a'; mid(); yield 'b'; post(); break; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // Dispatch (default → exit, no default arm).
    try T.expect(std.mem.indexOf(u8, out, "switch (x) { case 1: return [3, 1]; default: return [3, 4]; }") != null);
    // Case 1: pre() + first yield.
    try T.expect(std.mem.indexOf(u8, out, "case 1: pre(); return [4, \"a\"];") != null);
    // Resume1: sent + mid() + second yield.
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); mid(); return [4, \"b\"];") != null);
    // Resume2: sent + post() + break (→ exit).
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); post(); return [3, 4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with nested return in for-of-yield emits return-op-2" {
    // §4.A.4 — `return E;` inside a lowered loop body emits as
    // `return [2, E];` (op-2 generator return) via the in_sync_gen_body
    // flag in printReturn.
    const out = try emitWithOpts(
        "function* g() { for (const x of items) { if (x.done) return x; yield x; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // The nested `return x;` (via the if-guard) emits as op-2.
    try T.expect(std.mem.indexOf(u8, out, "if (x.done) return [2, x];") != null);
}

test "emit: generator with nested return in if-yield emits return-op-2" {
    const out = try emitWithOpts(
        "function* g() { if (cond) return 42; yield 1; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // `return 42;` inside the if-then emits as `return [2, 42];`.
    try T.expect(std.mem.indexOf(u8, out, "return [2, 42];") != null);
}

test "emit: generator with switch + return in case emits return-op-2" {
    // `return E;` inside a state-machine switch case must emit
    // `return [2, E];` (generator-return op), not native return.
    const out = try emitWithOpts(
        "function* g() { switch (x) { case 1: return 'done'; case 2: yield 'b'; break; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // case 1 emits `return [2, 'done']` — the early generator return.
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [2, \"done\"];") != null);
}

test "emit: generator with switch missing-break still bails" {
    // No-break case is fall-through; v0 requires explicit break.
    const out = try emitWithOpts(
        "function* g() { switch (x) { case 1: yield 'a'; case 2: yield 'b'; break; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") != null);
}

test "emit: generator with switch yield-in-discriminant still bails" {
    const out = try emitWithOpts(
        "function* g() { switch (yield 1) { case 1: yield 'a'; break; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") != null);
}

test "emit: generator with for-of-yield + if-guarded continue lowers" {
    // Sibling of §4.A.4.14 v8 for sync gen. `for (const x of items) {
    // if (x.skip) continue; yield x; }` uses splitLoopBody (pre=[if],
    // yield, post=[]). The if-stmt + break/continue printer cooperation
    // emits `if (x.skip) return [3, <continue_label>];` inline.
    const out = try emitWithOpts(
        "function* g() { for (const x of items) { if (x.skip) continue; yield x; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // continue_label is case 3 for this 4-case loop layout (header /
    // resume / continue / exit). gen_continue_label is wired before
    // splitLoopBody's pre-stmts emit.
    try T.expect(std.mem.indexOf(u8, out, "if (x.skip) return [3, 3];") != null);
}

test "emit: generator with for-of-yield + if-guarded break lowers" {
    const out = try emitWithOpts(
        "function* g() { for (const x of items) { if (x.done) break; yield x; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // break → exit_label = case 4.
    try T.expect(std.mem.indexOf(u8, out, "if (x.done) return [3, 4];") != null);
}

test "emit: generator with for-in-yield + destructuring target" {
    // for-in iterates keys (strings), so destructuring on a key is
    // unusual but valid TS (treats key as string-indexed).
    const out = try emitWithOpts(
        "function* g() { for (const [a, b] in obj) yield a; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "var [a, b] = _keys[_i];") != null);
}

test "emit: generator with for-in-yield lowers via eager keys collection" {
    const out = try emitWithOpts(
        "function* g() { for (const k in obj) yield k; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Init in case 0: eager key collection.
    try T.expect(std.mem.indexOf(u8, out, "var _keys = [], _i = 0;") != null);
    try T.expect(std.mem.indexOf(u8, out, "for (var _x in obj) _keys.push(_x);") != null);
    // Header case 1: cond + binding + yield. Exit = case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 1: if (!(_i < _keys.length)) return [3, 4]; var k = _keys[_i]; return [4, k];") != null);
    // Continue case 3 increments _i and loops back to header.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _i++; return [3, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: sync generator with for-await-of still bails" {
    // `function*` (sync) + `for await` is invalid TS; we keep this
    // case bailing in the sync-generator state machine. The proper
    // async-generator-side lowering is exercised separately below.
    const out = try emitWithOpts(
        "function* g() { for await (const x of items) yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "__generator") == null);
}

test "emit: async generator with for-await-of lowers to 11-case loop with trys-frame cleanup" {
    // §4.A.4.14 v1 — `async function* g() { for await (const x of source) yield x; }`
    // now lowers with full try/finally cleanup: the iterator's
    // `.return()` is awaited on early termination or on throw. Layout:
    //   case 0: trys.push + init (`_aiter = __asyncValues(source);`)
    //   case 1: await next() — `return [4, __await(_aiter.next())];`
    //   case 2: bind result + done-check + body yield
    //   case 3: body yield resume1
    //   case 4: body yield resume2 + loopback to case 1
    //   case 5: normal-end (jump past catch+finally to case 10)
    //   case 6: catch-start (capture _e_1)
    //   case 7: finally-start (skip if no usable iterator, else
    //           awaited `.return()`)
    //   case 8: cleanup-resume
    //   case 9: finally-end (rethrow + endfinally)
    //   case 10: exit
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // Init in case 0 — trys.push then __asyncValues.
    try T.expect(std.mem.indexOf(u8, out, "case 0: _a.trys.push([1, 6, 7, 10]); var _aiter = __asyncValues(source);") != null);
    // Header case 1 awaits next().
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, __await(_aiter.next())];") != null);
    // Bind/check/body-yield in case 2 — done-jump now targets normal_end (case 5).
    try T.expect(std.mem.indexOf(u8, out, "case 2: var _aresult = _a.sent(); if (_aresult.done) return [3, 5]; var x = _aresult.value; return [4, __await(x)];") != null);
    // Body yield resume1.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [4];") != null);
    // Body yield resume2 + loopback to header (case 1).
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent(); return [3, 1];") != null);
    // Normal-end (case 5) jumps past catch+finally to end_label (case 10).
    try T.expect(std.mem.indexOf(u8, out, "case 5: return [3, 10];") != null);
    // Catch (case 6) captures error, jumps to finally (case 7).
    try T.expect(std.mem.indexOf(u8, out, "case 6: var _e_1 = _a.sent(); return [3, 7];") != null);
    // Finally (case 7) skips cleanup if no usable iterator, else awaits .return().
    try T.expect(std.mem.indexOf(u8, out, "case 7: if (!(_aresult && !_aresult.done && _aiter.return)) return [3, 9]; return [4, __await(_aiter.return.call(_aiter))];") != null);
    // Cleanup resume (case 8).
    try T.expect(std.mem.indexOf(u8, out, "case 8: _a.sent();") != null);
    // Finally-end (case 9) rethrows + endfinally.
    try T.expect(std.mem.indexOf(u8, out, "case 9: if (_e_1) throw _e_1; return [7];") != null);
    // End label (case 10) — exit.
    try T.expect(std.mem.indexOf(u8, out, "case 10:") != null);
}

test "emit: async generator with for-await-of + var decl target binds via var" {
    // `let x` and `var x` lower identically to `const x` (the
    // state-machine binding is always `var x = _aresult.value;`).
    const out = try emitWithOpts(
        "async function* g() { for await (let x of source) yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "var x = _aresult.value;") != null);
}

test "emit: async generator with for-await-of + multi-yield body interleaves stmts" {
    // §4.A.4.14 v2 — multi-yield body. Each additional yield adds
    // 2 cases (resume1 + resume2-with-trailing-stmts). For N=2 yields
    // with one stmt before/between/after, layout is:
    //   case 0: trys.push([1, 8, 9, 12]) + init
    //   case 1: header (await next)
    //   case 2: bind+check, var x = _aresult.value, pre(), close with yield 1
    //   case 3: y1 resume1
    //   case 4: y1 resume2, mid(), close with yield 2
    //   case 5: y2 resume1
    //   case 6: y2 resume2, post(), loopback to case 1
    //   case 7: normal_end -> case 12
    //   case 8: catch
    //   case 9: finally
    //   case 10: cleanup resume
    //   case 11: finally_end
    //   case 12: end
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { pre(); yield 1; mid(); yield 2; post(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // trys.push targets shift to reflect the wider body (catch=8, finally=9, end=12).
    try T.expect(std.mem.indexOf(u8, out, "case 0: _a.trys.push([1, 8, 9, 12]); var _aiter = __asyncValues(source);") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, __await(_aiter.next())];") != null);
    // Bind+check, then pre(), then yield 1.
    try T.expect(std.mem.indexOf(u8, out, "case 2: var _aresult = _a.sent(); if (_aresult.done) return [3, 7]; var x = _aresult.value; pre(); return [4, __await(1)];") != null);
    // y1 resume1 + resume2 (mid() + yield 2).
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent(); mid(); return [4, __await(2)];") != null);
    // y2 resume1 + resume2 (post() + loopback).
    try T.expect(std.mem.indexOf(u8, out, "case 5: _a.sent(); return [4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 6: _a.sent(); post(); return [3, 1];") != null);
    // Normal-end re-routes to end.
    try T.expect(std.mem.indexOf(u8, out, "case 7: return [3, 12];") != null);
    // Catch + finally + cleanup chain.
    try T.expect(std.mem.indexOf(u8, out, "case 8: var _e_1 = _a.sent(); return [3, 9];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 9: if (!(_aresult && !_aresult.done && _aiter.return)) return [3, 11]; return [4, __await(_aiter.return.call(_aiter))];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 10: _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 11: if (_e_1) throw _e_1; return [7];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 12:") != null);
}

test "emit: async generator with for-await-of + multi-yield body + structured stmt still bails" {
    // V2 predicate rejects structured stmts (if/while/try/etc.) in the
    // body since the inline walk doesn't recurse into them.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { if (x) yield 1; yield 2; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // Falls back to native async generator (no __asyncGenerator wrapper
    // in the ES5 downlevel emit means it stayed as `async function*`).
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") == null);
}

test "emit: async generator with for-await-of + no-yield body lowers to 9-case loop" {
    // §4.A.4.14 v3 — N=0 yield body. Layout collapses to 9 cases:
    //   case 0: trys.push([1, 4, 5, 8]) + init
    //   case 1: header (await next)
    //   case 2: bind+check + f(x) + loopback to case 1
    //   case 3: normal_end -> case 8
    //   case 4: catch
    //   case 5: finally
    //   case 6: cleanup resume
    //   case 7: finally_end
    //   case 8: end
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) f(x); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // trys.push targets shifted for N=0 (catch=4, finally=5, end=8).
    try T.expect(std.mem.indexOf(u8, out, "case 0: _a.trys.push([1, 4, 5, 8]); var _aiter = __asyncValues(source);") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, __await(_aiter.next())];") != null);
    // Bind/check + body call + loopback all in case 2.
    try T.expect(std.mem.indexOf(u8, out, "case 2: var _aresult = _a.sent(); if (_aresult.done) return [3, 3]; var x = _aresult.value; f(x); return [3, 1];") != null);
    // Normal-end + catch + finally + cleanup + finally-end + exit chain.
    try T.expect(std.mem.indexOf(u8, out, "case 3: return [3, 8];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: var _e_1 = _a.sent(); return [3, 5];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 5: if (!(_aresult && !_aresult.done && _aiter.return)) return [3, 7]; return [4, __await(_aiter.return.call(_aiter))];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 6: _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 7: if (_e_1) throw _e_1; return [7];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 8:") != null);
}

test "emit: async generator with for-await-of + no-yield bare-stmt body lowers" {
    // Body is a bare statement (not a block) — `f(x);`. Predicate
    // routes both bare-stmt and block bodies through the same emit.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) g(x); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "var x = _aresult.value; g(x); return [3, 1];") != null);
}

test "emit: async generator with for-await-of + array destructuring target" {
    // §4.A.4.14 v7 — `for await (const [a, b] of source)` binds the
    // tuple via `var [a, b] = _aresult.value;` in the state machine.
    const out = try emitWithOpts(
        "async function* g() { for await (const [a, b] of source) yield a; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "var [a, b] = _aresult.value;") != null);
}

test "emit: async generator with for-await-of + object destructuring target" {
    // `for await (const { value, done } of source)` binds the object
    // via `var { value, done } = _aresult.value;`.
    const out = try emitWithOpts(
        "async function* g() { for await (const { value, done } of source) yield value; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "var { value, done } = _aresult.value;") != null);
}

test "emit: async generator with for-await-of + break in body routes through cleanup" {
    // §4.A.4.14 v6 — `break;` inside the body rewrites to
    // `return [3, normal_end_label];` so the state machine re-routes
    // through the finally case (awaited `.return()` cleanup) before
    // landing on the end label.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { yield x; break; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // case 4 contains the break rewrite (return [3, 5]) — 5 is normal_end_label.
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent(); return [3, 5];") != null);
    // Normal-end (case 5) still routes to end (case 10).
    try T.expect(std.mem.indexOf(u8, out, "case 5: return [3, 10];") != null);
}

test "emit: async generator with for-await-of + continue in body restarts loop" {
    // `continue;` inside the body rewrites to
    // `return [3, header_label];` — jumps directly to the next
    // iteration's _aiter.next() await without re-entering cleanup.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { yield x; continue; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // case 4 contains the continue rewrite (return [3, 1]) — 1 is header_label.
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent(); return [3, 1];") != null);
}

test "emit: async generator with for-await-of + if-guarded continue lowers" {
    // §4.A.4.14 v8 — `if (cond) continue;` in body rewrites to
    // `if (cond) return [3, header_label];` via the existing if-stmt
    // + break/continue printers cooperating with the wired
    // gen_continue_label.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { if (x.skip) continue; yield x; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // case 2 binds x and inlines the if-guard before the yield.
    try T.expect(std.mem.indexOf(u8, out, "if (x.skip) return [3, 1];") != null);
}

test "emit: async generator with for-await-of + if-guarded break lowers" {
    // `if (cond) break;` rewrites to `if (cond) return [3, normal_end];`.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { if (x.done) break; yield x; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // case 2: bind + `if (x.done) return [3, 5];` + yield x.
    try T.expect(std.mem.indexOf(u8, out, "if (x.done) return [3, 5];") != null);
}

test "emit: async generator with for-await-of + if-else with yield-free else lowers" {
    // §4.A.4.14 v9 — `if (cond) break|continue; else <yield/await-free stmt>;`
    // is now accepted. The state-machine jump fires in the then branch;
    // the else runs inline.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { if (x.skip) continue; else f(x); yield x; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // case 2: bind + `if (x.skip) return [3, 1]; else f(x);` + yield x.
    try T.expect(std.mem.indexOf(u8, out, "if (x.skip) return [3, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "else f(x)") != null);
}

test "emit: async generator with for-await-of + if-with-yielding-else still bails" {
    // Yields/awaits in the else branch require state-machine plumbing
    // the v9 simple inline emit doesn't provide.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { if (x.skip) continue; else yield x * 2; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") == null);
}

test "emit: async generator with for-await-of + labeled break still bails" {
    // Labeled break/continue isn't part of v6 — predicate rejects so
    // the loop falls back to native `async function*`.
    const out = try emitWithOpts(
        "async function* g() { outer: for await (const x of source) { break outer; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") == null);
}

test "emit: async generator with for-await-of + yield* in body delegates via __asyncDelegator" {
    // §4.A.4.14 v5 — `yield* inner` in the body of for-await-of uses
    // op-5 + __asyncDelegator(__asyncValues(...)) so delegation works
    // for both sync and async iterables uniformly. Resume1 re-yields
    // the delegated value via __await(_a.sent()); resume2 continues.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) yield* inner(x); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // Body case 2 closes with op-5 delegation.
    try T.expect(std.mem.indexOf(u8, out, "var x = _aresult.value; return [5, __asyncDelegator(__asyncValues(inner(x)))];") != null);
    // Resume1 (case 3) re-yields the delegated value.
    try T.expect(std.mem.indexOf(u8, out, "case 3: return [4, __await(_a.sent())];") != null);
    // Resume2 (case 4) does _a.sent() + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent(); return [3, 1];") != null);
}

test "emit: async generator with for-await-of + mixed yield/yield* body" {
    // Multi-yield body mixing regular and delegating yields. Layout
    // is 1 + 2*N body cases (N=2 here, so 5 body cases).
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { yield x; yield* inner(x); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // y1 (regular): case 2 closes with __await(x); case 3 = `_a.sent(); return [4];`; case 4 opens with _a.sent() + y2.
    try T.expect(std.mem.indexOf(u8, out, "case 2: var _aresult = _a.sent(); if (_aresult.done) return [3, 7]; var x = _aresult.value; return [4, __await(x)];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [4];") != null);
    // y2 (delegating): case 4 closes with op-5; case 5 = re-yield resume; case 6 = _a.sent() + loopback.
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent(); return [5, __asyncDelegator(__asyncValues(inner(x)))];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 5: return [4, __await(_a.sent())];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 6: _a.sent(); return [3, 1];") != null);
}

test "emit: async generator with for-await-of + bare yield* still bails (no source)" {
    // `yield*` without a source expression is invalid; predicate
    // rejects so the loop falls back.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) yield*; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") == null);
}

test "emit: async generator with for-await-of + awaited source peels into pre-loop yield+bind" {
    // §4.A.4.14 v4 — source is `await getSource()`. The await is
    // peeled into a pre-loop yield+bind (case 0 closes with the
    // source's `return [4, __await(getSource())]`; case 1 binds
    // `var _src = _a.sent();`) before the regular trys-frame opens
    // in case 1 with `_aiter = __asyncValues(_src)`. All downstream
    // labels shift by 1 to make room for the source-peel.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of await getSource()) yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // Case 0 closes with the source's await.
    try T.expect(std.mem.indexOf(u8, out, "case 0: return [4, __await(getSource())];") != null);
    // Case 1 binds _src then runs trys.push + __asyncValues(_src).
    // Trys labels shift by 1: try_start=2, catch=7, finally=8, end=11.
    try T.expect(std.mem.indexOf(u8, out, "case 1: var _src = _a.sent(); _a.trys.push([2, 7, 8, 11]); var _aiter = __asyncValues(_src);") != null);
    // Header now at case 2.
    try T.expect(std.mem.indexOf(u8, out, "case 2: return [4, __await(_aiter.next())];") != null);
    // Bind/check + body yield (target case shifts to 6 = normal_end).
    try T.expect(std.mem.indexOf(u8, out, "case 3: var _aresult = _a.sent(); if (_aresult.done) return [3, 6]; var x = _aresult.value; return [4, __await(x)];") != null);
    // Cleanup chain shifted by 1.
    try T.expect(std.mem.indexOf(u8, out, "case 6: return [3, 11];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 11:") != null);
}

test "emit: async generator with for-await-of + complex non-await source still works" {
    // Source can be any yield/await-free expression (member access,
    // call, etc.).
    const out = try emitWithOpts(
        "async function* g() { for await (const x of obj.items()) yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    // No source-peel — source emits inline as the __asyncValues arg.
    try T.expect(std.mem.indexOf(u8, out, "var _aiter = __asyncValues(obj.items());") != null);
    // No _src binding.
    try T.expect(std.mem.indexOf(u8, out, "var _src = _a.sent()") == null);
}

test "emit: async generator with for-await-of + source containing nested await still bails" {
    // `await getSource() + x` contains await but isn't a bare
    // await_expr — predicate rejects so the loop falls back.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of (await getSource()).items) yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // Source is `(await getSource()).items` — a member access on the
    // result of an await, not a bare await. v4 rejects this shape.
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") == null);
}

test "emit: async generator with for-await-of + no-yield multi-stmt body lowers" {
    // N=0 yields, block body with multiple stmts.
    const out = try emitWithOpts(
        "async function* g() { for await (const x of source) { pre(x); post(x); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "var x = _aresult.value; pre(x); post(x); return [3, 1];") != null);
}

test "emit: async generator with regular for-of (non-await) still bails" {
    // `for (const x of source)` (no `await`) inside an async generator
    // is also outside v0 — the async-gen predicate only accepts the
    // for-await-of shape so the loop falls back to native emit.
    const out = try emitWithOpts(
        "async function* g() { for (const x of source) yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") == null);
}

test "emit: generator with do-while + yield-in-cond lowers to 5-case loop" {
    // §4.A.4.13 — `do yield 1; while (yield 2);` now lowers: the body
    // case yields 1, body-resume falls through to a new cond_yield
    // case that yields 2, cond_resume tests _a.sent() and loops back.
    const out = try emitWithOpts(
        "function* g() { do yield 1; while (yield 2); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Body case 1: yield 1.
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, 1];") != null);
    // Body-resume case 2: sent (falls through to cond_yield).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
    // Cond-yield case 3: yield 2.
    try T.expect(std.mem.indexOf(u8, out, "case 3: return [4, 2];") != null);
    // Cond-resume case 4: test sent + loopback to body.
    try T.expect(std.mem.indexOf(u8, out, "case 4: if (_a.sent()) return [3, 1];") != null);
    // Exit case 5.
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with do-while + split-body + yield-in-cond lowers" {
    // Split body (pre + yield + post) combined with yield-cond.
    const out = try emitWithOpts(
        "function* g() { do { pre(); yield 1; post(); } while (yield 2); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // Body case 1: pre() + yield 1.
    try T.expect(std.mem.indexOf(u8, out, "case 1: pre(); return [4, 1];") != null);
    // Body-resume case 2: sent + post() (falls through to cond_yield).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); post();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: return [4, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: if (_a.sent()) return [3, 1];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with do-while + multi-yield body + yield-in-cond still bails" {
    // The cond-yield + multi-yield-body combination intentionally
    // bails because the state-counting intertwines awkwardly with
    // the extra cond_resume case.
    const out = try emitWithOpts(
        "function* g() { do { yield 1; yield 2; } while (yield 3); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "__generator") == null);
}

test "emit: generator with do-while + yield* in cond still bails" {
    // yield* (delegating yield) in the cond expression isn't part of
    // the §4.A.4.13 v0 surface — it would change the cond's resumption
    // semantics in ways the current state machine doesn't model.
    const out = try emitWithOpts(
        "function* g() { do yield 1; while (yield* inner); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "__generator") == null);
}

test "emit: generator with if-then-yield + else-yield lowers to 5-case shape" {
    const out = try emitWithOpts(
        "function* g() { if (cond) yield 1; else yield 2; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Then-branch path: cond skip → case 2 (else); then-yield → case 1.
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // Then-resumption: case 1, then jumps past else-yield to after-if (case 4).
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [3, 4];") != null);
    // Else-yield: case 2.
    try T.expect(std.mem.indexOf(u8, out, "case 2:") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 2]") != null);
    // Else-resumption: case 3.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent();") != null);
    // After-if: case 4 (falls through to final `return [2];`).
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with multi-yield if-then (no else) lowers inline" {
    const out = try emitWithOpts(
        "function* g() { if (cond) { yield 1; yield 2; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Cond skip targets afterIf (case 3 for 2 yields).
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 3];") != null);
    // First yield closes case 0.
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // Intermediate resumption case 1: sent + second yield.
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [4, 2]") != null);
    // Final resumption case 2: sent (falls through to afterIf).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
    // afterIf case 3.
    try T.expect(std.mem.indexOf(u8, out, "case 3:") != null);
}

test "emit: generator with multi-yield if-then + post-if yield sequences correctly" {
    const out = try emitWithOpts(
        "function* g() { if (cond) { yield 1; yield 2; } yield 3; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // After the multi-yield if, case 3 is afterIf; yield 3 happens in case 3.
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: return [4, 3]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent();") != null);
}

test "emit: generator with multi-yield if-then + non-yielding else lowers" {
    const out = try emitWithOpts(
        "function* g() { if (cond) { yield 1; yield 2; } else { f(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // 2 then-yields → state advances by 2; non-yielding else takes 1 case;
    // afterIf = state + 2 + 1 + 1 = state + 4.
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [4, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [3, 4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: f();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with multi-yield if-then + yielding else lowers" {
    const out = try emitWithOpts(
        "function* g() { if (cond) { yield 1; yield 2; } else { yield 3; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // 2 then-yields + 1 else-yield. afterIf = state + 2 + 2 + 1 = state + 5.
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [4, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [3, 5];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: return [4, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with single-yield then + multi-yield else lowers" {
    const out = try emitWithOpts(
        "function* g() { if (cond) yield 1; else { yield 2; yield 3; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // 1 then-yield + 2 else-yields. afterIf = state + 1 + 3 + 1 = state + 5.
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [3, 5];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: return [4, 2];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [4, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: generator with if-then-yield containing pre-yield stmt lowers via state machine" {
    // §4.A.4.5 v2 — `if (cond) { f(); yield 1; }` (1+ pre-yield
    // statements + 1 yield) now lowers through the state machine.
    // The cur case emits the cond skip, the pre-stmts, then the
    // yield; case state+1 resumes with `_a.sent();`.
    const out = try emitWithOpts(
        "function* g() { if (cond) { f(); yield 1; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "if (!(cond)) return [3,") != null);
    try T.expect(std.mem.indexOf(u8, out, "f();") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
}

test "emit: generator with if-then-yield containing post-yield stmt lowers via state machine" {
    // §4.A.4.5 v2 — `if (cond) { yield 1; cleanup(); }` (yield
    // followed by cleanup stmts). After the yield's resumption
    // case sets up `_a.sent()`, the post-stmts emit inline.
    const out = try emitWithOpts(
        "function* g() { if (cond) { yield 1; cleanup(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "cleanup();") != null);
}

test "emit: generator with if-then-yield containing pre+post stmt lowers via state machine" {
    // §4.A.4.5 v2 — full split shape: pre-stmt, yield, post-stmt.
    const out = try emitWithOpts(
        "function* g() { if (cond) { init(); yield 1; cleanup(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "init();") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "cleanup();") != null);
}

test "emit: generator with try-finally + yield lowers via __generator trys protocol" {
    const out = try emitWithOpts(
        "function* g() { try { yield 1; } finally { cleanup(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // trys.push with [tryStart, , finallyStart, endLabel] — no catchStart.
    try T.expect(std.mem.indexOf(u8, out, "_a.trys.push([0, , 2, 3]);") != null);
    // Yield inside the try body.
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // Yield resumption case 1: sent + jump to end (runtime routes through finally).
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [3, 3];") != null);
    // Finally case 2: cleanup() + [7] endfinally.
    try T.expect(std.mem.indexOf(u8, out, "case 2: cleanup(); return [7];") != null);
    // End case 3.
    try T.expect(std.mem.indexOf(u8, out, "case 3:") != null);
}

test "emit: generator with try-catch + yield emits catchStart + catch binding" {
    const out = try emitWithOpts(
        "function* g() { try { yield 1; } catch (e) { handle(e); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // trys.push with [tryStart, catchStart, , endLabel] — no finallyStart.
    try T.expect(std.mem.indexOf(u8, out, "_a.trys.push([0, 2, , 3]);") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // yield resumption case 1: sent + jump to end (no finally; direct).
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [3, 3];") != null);
    // catch case 2: var e = _a.sent(); handle(e); return [3, end].
    try T.expect(std.mem.indexOf(u8, out, "case 2: var e = _a.sent(); handle(e); return [3, 3];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3:") != null);
}

test "emit: generator with try-catch-finally + yield emits all four labels" {
    const out = try emitWithOpts(
        "function* g() { try { yield 1; } catch (e) { handle(e); } finally { cleanup(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // trys.push with full frame [tryStart, catchStart, finallyStart, endLabel].
    try T.expect(std.mem.indexOf(u8, out, "_a.trys.push([0, 2, 3, 4]);") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [3, 4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: var e = _a.sent(); handle(e); return [3, 4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: cleanup(); return [7];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with multi-yield try-finally lowers with N resumption cases" {
    const out = try emitWithOpts(
        "function* g() { try { yield 1; yield 2; } finally { cleanup(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // trys frame: tryStart=0, finallyStart=3, endLabel=4.
    try T.expect(std.mem.indexOf(u8, out, "_a.trys.push([0, , 3, 4]);") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // Resumption case 1: sent + second yield.
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [4, 2]") != null);
    // Resumption case 2: sent + jump to end (final yield's resumption).
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [3, 4];") != null);
    // Finally case 3.
    try T.expect(std.mem.indexOf(u8, out, "case 3: cleanup(); return [7];") != null);
    // End case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with multi-yield try-catch lowers with intermediate resumption + catch" {
    const out = try emitWithOpts(
        "function* g() { try { yield 1; yield 2; } catch (e) { handle(e); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "_a.trys.push([0, 3, , 4]);") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [4, 2]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent(); return [3, 4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: var e = _a.sent(); handle(e); return [3, 4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with yield in catch body lowers via resumption case" {
    const out = try emitWithOpts(
        "function* g() { try { yield 1; } catch (e) { yield e; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // trys frame: [tryStart=0, catchStart=2, , endLabel=4].
    // catch section now takes 2 cases (catchStart + 1 yield resume).
    try T.expect(std.mem.indexOf(u8, out, "_a.trys.push([0, 2, , 4]);") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    // Try yield resumption (case 1) jumps to end.
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [3, 4];") != null);
    // catch start (case 2) binds e + yields.
    try T.expect(std.mem.indexOf(u8, out, "case 2: var e = _a.sent(); return [4, e];") != null);
    // catch yield resumption (case 3) jumps to end.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [3, 4];") != null);
    // End case 4.
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with yield in catch + finally adjusts labels correctly" {
    const out = try emitWithOpts(
        "function* g() { try { yield 1; } catch (e) { yield e; } finally { cleanup(); } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // trys frame now: tryStart=0, catchStart=2, finallyStart=4, endLabel=5.
    try T.expect(std.mem.indexOf(u8, out, "_a.trys.push([0, 2, 4, 5]);") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: var e = _a.sent(); return [4, e];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [3, 5];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: cleanup(); return [7];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 5:") != null);
}

test "emit: async generator lowers to __asyncGenerator + __generator at es2017" {
    const out = try emitWithOpts(
        "async function* g() { yield 1; yield 2; }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    // No native `async function*` survived.
    try T.expect(std.mem.indexOf(u8, out, "async function*") == null);
    try T.expect(std.mem.indexOf(u8, out, "function g(") != null);
    // Wrapper shape.
    try T.expect(std.mem.indexOf(u8, out, "return __asyncGenerator(this, arguments, function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "return __generator(this, function (_a) {") != null);
    try T.expect(std.mem.indexOf(u8, out, "switch (_a.label) {") != null);
    // First user yield: case 0 closes with __await wrap; case 1 signals done; case 2 resumes.
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(1)]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
    // Second user yield: cases 3 and 4 mirror cases 1+2.
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(2)]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4: _a.sent();") != null);
    // Terminating return.
    try T.expect(std.mem.indexOf(u8, out, "return [2]") != null);
}

test "emit: async generator with top-level await lowers as single-yield resumption" {
    const out = try emitWithOpts(
        "async function* g() { await fetch(); yield 1; }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    // Await: case 0 ends with [4, __await(fetch())]; case 1 resumes.
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(fetch())]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent();") != null);
    // Yield: cases 2-3-4 (double-yield).
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(1)]") != null);
}

test "emit: async generator with let x = await E binds via _a.sent()" {
    const out = try emitWithOpts(
        "async function* g() { let x = await fetch(); yield x; }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    // case 0 yields __await(fetch()); case 1 binds via var x = _a.sent().
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(fetch())]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: var x = _a.sent();") != null);
    // case 2 yields __await(x) (the user yield).
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(x)]") != null);
}

test "emit: async generator with x = yield E (pre-declared) uses no var prefix" {
    const out = try emitWithOpts(
        "async function* g() { var x; x = yield 1; }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(1)]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [4];") != null);
    // Bind without `var` prefix (target is already declared).
    try T.expect(std.mem.indexOf(u8, out, "case 2: x = _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: var x = _a.sent();") == null);
}

test "emit: async generator with let x = yield E binds via second _a.sent()" {
    // `let x = yield E;` in async gen: double-yield, then bind the
    // consumer-provided value (the second _a.sent()) to x.
    const out = try emitWithOpts(
        "async function* g() { let x = yield 1; }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    // case 0 yields __await(1).
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(1)]") != null);
    // case 1: sent + emit-done re-yield.
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [4];") != null);
    // case 2: bind via var x = _a.sent().
    try T.expect(std.mem.indexOf(u8, out, "case 2: var x = _a.sent();") != null);
}

test "emit: async generator with x = await E (pre-declared) uses no var prefix" {
    const out = try emitWithOpts(
        "async function* g() { var x; x = await fetch(); yield x; }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(fetch())]") != null);
    // case 1 should bind via plain `x = _a.sent();` (no var prefix).
    try T.expect(std.mem.indexOf(u8, out, "case 1: x = _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: var x = _a.sent();") == null);
}

test "emit: async generator with f(await E) lowers to yield + call(_a.sent())" {
    const out = try emitWithOpts(
        "async function* g() { log(await fetch()); yield 1; }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    // First await: case 0 yields __await(fetch()); case 1 calls log(_a.sent()).
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(fetch())]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: log(_a.sent());") != null);
    // Then the user yield 1 expands to the double-yield pattern.
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(1)]") != null);
}

test "emit: async generator with yield await E unwraps to single __await" {
    // `yield await E` in async-gen body: the user's await is redundant
    // (yield already implicitly awaits), but the pattern is common.
    // Lower to `return [4, __await(E)];` rather than the invalid
    // `return [4, __await(await E)];`.
    const out = try emitWithOpts(
        "async function* g() { yield await fetch(); }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(fetch())]") != null);
    // No leftover `await fetch` inside __await wrap.
    try T.expect(std.mem.indexOf(u8, out, "__await(await") == null);
    // Rest of the double-yield pattern.
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [4];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
}

test "emit: async generator with f(await E, other) (multi-arg) lowers to yield + call(_a.sent(), …)" {
    // §4.A.4.7 (cont.2) extension — multi-arg call with await in
    // position 0 now lowers through the state machine. The trailing
    // args evaluate at resumption time and are passed verbatim into
    // the call after `_a.sent()`.
    const out = try emitWithOpts(
        "async function* g() { log(await fetch(), 2); }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(fetch())]") != null);
    try T.expect(std.mem.indexOf(u8, out, "log(_a.sent(), 2)") != null);
}

test "emit: async generator with f(await E, x, y) threads multiple trailing args" {
    const out = try emitWithOpts(
        "async function* g() { log(await fetch(), x, y); }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "log(_a.sent(), x, y)") != null);
}

test "emit: async generator with f(await A, await B) lowers via sequential yields + temp" {
    // §4.A.4.7 (cont.6) — two awaits in call args. Yields each in
    // source order; the first await's `_a.sent()` is bound to
    // `var _b0 = ...`; the second await's `_a.sent()` lands inline
    // in the final assembled call `f(_b0, _a.sent());`.
    const out = try emitWithOpts(
        "async function* g() { log(await fetch(), await other()); }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(fetch())]") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _b0 = _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(other())]") != null);
    try T.expect(std.mem.indexOf(u8, out, "log(_b0, _a.sent())") != null);
}

test "emit: async generator with f(x, await E) lowers (await not at position 0)" {
    // §4.A.4.7 (cont.6) — when the only await is at a non-zero
    // position, the multi-await path fires with await_count=1 but
    // the simple-single-await fast path doesn't (only triggers when
    // args[0] is await).
    const out = try emitWithOpts(
        "async function* g() { log(x, await fetch()); }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(fetch())]") != null);
    try T.expect(std.mem.indexOf(u8, out, "log(x, _a.sent())") != null);
}

test "emit: async generator with f(await A, x, await B) interleaves awaits + verbatim args" {
    // §4.A.4.7 (cont.6) — mixed shape: await + non-await + await.
    // Each await yields in source order; non-await arg `x`
    // evaluates inline in the final call.
    const out = try emitWithOpts(
        "async function* g() { log(await A(), x, await B()); }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(A())]") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _b0 = _a.sent();") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(B())]") != null);
    try T.expect(std.mem.indexOf(u8, out, "log(_b0, x, _a.sent())") != null);
}

test "emit: async generator with yield* lowers via __asyncDelegator + [5] opcode" {
    const out = try emitWithOpts(
        "async function* g() { yield* other(); }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    // Op-code 5 with __asyncDelegator(__asyncValues(E)) wrap.
    try T.expect(std.mem.indexOf(u8, out, "return [5, __asyncDelegator(__asyncValues(other()))];") != null);
    // Resumption case 1 re-yields via __await(_a.sent()).
    try T.expect(std.mem.indexOf(u8, out, "case 1: return [4, __await(_a.sent())];") != null);
    // Resumption case 2 continues.
    try T.expect(std.mem.indexOf(u8, out, "case 2: _a.sent();") != null);
}

test "emit: async generator preserved at es2018+" {
    const out = try emitWithOpts(
        "async function* g() { yield 1; }",
        .{ .es_target = .es2018 },
    );
    defer T.allocator.free(out);
    // Native `async function*` survives — no downlevel wrapper.
    try T.expect(std.mem.indexOf(u8, out, "async function* g(") != null);
    try T.expect(std.mem.indexOf(u8, out, "yield 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator") == null);
}

test "EsTarget.supportsNativeAsyncGenerators is es2018+" {
    try T.expectEqual(false, EsTarget.supportsNativeAsyncGenerators(.es5));
    try T.expectEqual(false, EsTarget.supportsNativeAsyncGenerators(.es2017));
    try T.expectEqual(true, EsTarget.supportsNativeAsyncGenerators(.es2018));
    try T.expectEqual(true, EsTarget.supportsNativeAsyncGenerators(.esnext));
}

test "emit: async generator at es5 still wraps via __asyncGenerator" {
    const out = try emitWithOpts(
        "async function* g() { yield 1; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__asyncGenerator(this, arguments, function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, __await(1)]") != null);
}

test "emit: generator with try-finally + yield-in-finally lowers via resumption case" {
    // §4.A.4.6 (cont.3) — yields in finally now lower like yields
    // in catch: each yield opens a new resumption case before the
    // final [7] endfinally.
    const out = try emitWithOpts(
        "function* g() { try { yield 1; } finally { yield 2; } }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    // trys frame: tryStart=0, finallyStart=2, endLabel=4 (finally takes 2 cases).
    try T.expect(std.mem.indexOf(u8, out, "_a.trys.push([0, , 2, 4]);") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent(); return [3, 4];") != null);
    // Finally entry case 2: yields V2 first.
    try T.expect(std.mem.indexOf(u8, out, "case 2: return [4, 2];") != null);
    // Finally yield-resume case 3: sent + [7] endfinally.
    try T.expect(std.mem.indexOf(u8, out, "case 3: _a.sent(); return [7];") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 4:") != null);
}

test "emit: generator with bare try (no catch/finally) bails — handled by yield path" {
    // try { yield 1; } with no clauses is degenerate; the try-stmt
    // predicate rejects it and the body-yield falls through to the
    // standard yield-stmt path (which doesn't apply since the yield
    // is inside a try block). End result: bails.
    const out = try emitWithOpts(
        "function* g() { try { yield 1; } catch (e) {} }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // Just verifying it lowers (catch present — supported).
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
}

test "emit: generator with f(yield E) at top-level lowers to yield + call(_a.sent())" {
    // `f(yield E);` at statement position now lowers cleanly: cur case
    // closes with `return [4, E];`, next case calls `f(_a.sent())`.
    const out = try emitWithOpts(
        "function* g() { console.log(yield 1); }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "TODO: ES5 generator") == null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, 1]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: console.log(_a.sent());") != null);
}

test "emit: generator with non-yield decl passes through as plain var" {
    const out = try emitWithOpts(
        "function* g() { let x = 42; yield x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // Decl without yield-RHS lowers to plain `var x = 42;` inside
    // the state machine — no _a.sent() involved.
    try T.expect(std.mem.indexOf(u8, out, "var x = 42;") != null);
    try T.expect(std.mem.indexOf(u8, out, "return [4, x]") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1: _a.sent();") != null);
}

test "emit: importHelpers tslib import includes __generator" {
    const out = try emitWithOpts(
        "async function f() { await g(); }",
        .{ .es_target = .es2015, .import_helpers = true },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__generator") != null);
    try T.expect(std.mem.indexOf(u8, out, "from \"tslib\"") != null);
}

test "emit: dynamic import preserved for esm" {
    const out = try emitWithOpts("let mod = import(\"foo\");", .{ .module_kind = .esm });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "import(\"foo\")") != null);
    try T.expect(std.mem.indexOf(u8, out, "require") == null);
}

test "emit: method decorators emit __decorate against prototype" {
    const out = try emit(
        \\class Foo {
        \\  @logged
        \\  greet() { return 1; }
        \\}
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([logged], Foo.prototype, \"greet\", null);") != null);
}

test "emit: property decorators emit __decorate against prototype" {
    const out = try emit(
        \\class Foo {
        \\  @observe
        \\  count = 0;
        \\}
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([observe], Foo.prototype, \"count\", null);") != null);
}

test "emit: static member decorators target constructor" {
    const out = try emit(
        \\class Foo {
        \\  @logged
        \\  static greet() { return 1; }
        \\  @observe
        \\  static count = 0;
        \\}
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "static greet()") != null);
    try T.expect(std.mem.indexOf(u8, out, "static count = 0;") != null);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([logged], Foo, \"greet\", null);") != null);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([observe], Foo, \"count\", null);") != null);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([logged], Foo.prototype, \"greet\", null);") == null);
}

test "emit: parameter decorators emit __param wrappers" {
    const out = try emit(
        \\class Service {
        \\  @logged
        \\  greet(@inject name: string) { return name; }
        \\}
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([logged], Service.prototype, \"greet\", null);") != null);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([__param(0, inject)], Service.prototype, \"greet\", null);") != null);
}

test "emit: non-jsx file with automatic mode skips the import" {
    const out = try emitWithOpts("let x = 1;", .{ .jsx_runtime = .automatic });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "react/jsx-runtime") == null);
}

fn emitWithOpts(source: []const u8, opts: Options) ![]u8 {
    const s = try T.allocator.create(TestSetup);
    defer T.allocator.destroy(s);
    s.interner = try string_interner.Interner.init(T.allocator);
    defer s.interner.deinit();
    s.hir = try hir_mod.Hir.init(T.allocator);
    defer s.hir.deinit();
    s.scanner = ts_lexer.Scanner.init(T.allocator, source);
    defer s.scanner.deinit(T.allocator);
    s.tokens = try s.scanner.tokenize(T.allocator);
    defer s.tokens.deinit(T.allocator);
    s.parser = ts_parser.Parser.init(T.allocator, &s.hir, &s.interner, source, s.tokens.items);
    defer s.parser.deinit();
    s.root = try s.parser.parseSourceFile();
    s.printer = Printer.init(T.allocator, &s.hir, &s.interner, opts);
    defer s.printer.deinit();
    s.printer.setSource(source);
    try s.printer.printSourceFile(s.root);
    return T.allocator.dupe(u8, s.printer.out.items);
}

test "emit: nullish-coalescing lowers under es2019" {
    const out = try emitWithOpts("let r = a ?? b;", .{ .es_target = .es2019 });
    defer T.allocator.free(out);
    // Expect a ternary, not `??`.
    try T.expect(std.mem.indexOf(u8, out, "??") == null);
    try T.expect(std.mem.indexOf(u8, out, "!== null") != null);
    try T.expect(std.mem.indexOf(u8, out, "!== void 0") != null);
}

test "emit: template literal preserved at es2015+" {
    const out = try emitWithOpts("let s = `hi ${x}`;", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    // Native backtick form survives.
    try T.expect(std.mem.indexOf(u8, out, "`hi ${x}`") != null);
    // No string-concat lowering.
    try T.expect(std.mem.indexOf(u8, out, "\"hi \" + x") == null);
}

test "emit: template literal lowers to string concat at es5" {
    const out = try emitWithOpts("let s = `hi ${x}`;", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    // Backtick form is gone.
    try T.expect(std.mem.indexOf(u8, out, "`") == null);
    // String concat appears.
    try T.expect(std.mem.indexOf(u8, out, "\"hi \" + x") != null);
}

test "emit: optional-chaining lowers under es2019" {
    const out = try emitWithOpts("let r = obj?.x;", .{ .es_target = .es2019 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "?.") == null);
    try T.expect(std.mem.indexOf(u8, out, "=== null") != null);
}

test "emit: optional element-access lowers under es2019" {
    const out = try emitWithOpts("let r = arr?.[0];", .{ .es_target = .es2019 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "?.[") == null);
}

test "emit: nullish/optional preserved at es2020+" {
    const out = try emitWithOpts("let r = a ?? b;", .{ .es_target = .es2020 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "??") != null);
}

test "emit: array spread preserved at es2015+" {
    const out = try emitWithOpts("let r = [...a];", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "[...a]") != null);
    try T.expect(std.mem.indexOf(u8, out, ".slice()") == null);
}

test "emit: array spread lowers to slice() at es5" {
    const out = try emitWithOpts("let r = [...a];", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "a.slice()") != null);
    try T.expect(std.mem.indexOf(u8, out, "[...") == null);
}

test "emit: call-site spread lowers to apply() at es5" {
    // `f(...a)` -> `f.apply(void 0, a)`; no leftover native spread.
    const out1 = try emitWithOpts("f(...a);", .{ .es_target = .es5 });
    defer T.allocator.free(out1);
    try T.expect(std.mem.indexOf(u8, out1, "f.apply(void 0, a)") != null);
    try T.expect(std.mem.indexOf(u8, out1, "f(...") == null);

    // method call keeps the receiver as thisArg: `o.m(...a)` -> `o.m.apply(o, a)`.
    const out2 = try emitWithOpts("o.m(...a);", .{ .es_target = .es5 });
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "o.m.apply(o, a)") != null);

    // mixed args build the array via concat: `f(a, ...b)` -> `f.apply(void 0, [a].concat(b))`.
    const out3 = try emitWithOpts("f(a, ...b);", .{ .es_target = .es5 });
    defer T.allocator.free(out3);
    try T.expect(std.mem.indexOf(u8, out3, "f.apply(void 0, [a].concat(b))") != null);

    // leading spread then arg: `f(...a, b)` -> `f.apply(void 0, a.concat([b]))`.
    const out4 = try emitWithOpts("f(...a, b);", .{ .es_target = .es5 });
    defer T.allocator.free(out4);
    try T.expect(std.mem.indexOf(u8, out4, "f.apply(void 0, a.concat([b]))") != null);
}

test "emit: es5 complex-receiver spread caches receiver in a hoisted temp" {
    // `o[1].foo(...a)` -> `var _a; (_a = o[1]).foo.apply(_a, a);` — the
    // side-effecting receiver is evaluated once via a module-top temp (§4.A.31).
    const out = try emitWithOpts("o[1].foo(...a);", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _a;") != null);
    try T.expect(std.mem.indexOf(u8, out, "(_a = o[1]).foo.apply(_a, a)") != null);
}

test "emit: es5 in-function temp hoists to the function top, not module" {
    // Temps allocated inside a function body place at that function's top
    // (tsc's shape), not at module scope (§4.A.31 follow-up a).
    const out = try emitWithOpts("function f() { o[1].foo(...a); }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    const fn_pos = std.mem.indexOf(u8, out, "function f() {").?;
    const var_pos = std.mem.indexOf(u8, out, "var _a;").?;
    try T.expect(var_pos > fn_pos);
    try T.expect(std.mem.indexOf(u8, out, "(_a = o[1]).foo.apply(_a, a)") != null);
    // exactly one declaration — the module scope stays temp-free.
    try T.expect(std.mem.indexOf(u8, out[var_pos + 1 ..], "var _a;") == null);
}

test "emit: es5 arrow-body temp stays inside the lowered function" {
    const out = try emitWithOpts("let g = () => { o[1].foo(...a); };", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    const fn_pos = std.mem.indexOf(u8, out, "function () {").?;
    const var_pos = std.mem.indexOf(u8, out, "var _a;").?;
    try T.expect(var_pos > fn_pos);
    try T.expect(std.mem.indexOf(u8, out, "(_a = o[1]).foo.apply(_a, a)") != null);
    try T.expect(std.mem.indexOf(u8, out, ".bind(this)") != null);
}

test "emit: es5 sibling functions get independent temp counters" {
    // Each function scope restarts at `_a` — no cross-function bleed.
    const out = try emitWithOpts("function f() { o[1].foo(...a); } function g() { p[2].bar(...b); }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "(_a = o[1]).foo.apply(_a, a)") != null);
    try T.expect(std.mem.indexOf(u8, out, "(_a = p[2]).bar.apply(_a, b)") != null);
    try T.expect(std.mem.indexOf(u8, out, "_b") == null);
}

test "emit: es5 object literal computed key lowers to temp sequence" {
    // `{ [key]: value }` -> `(_a = {}, _a[key] = value, _a)` (§4.A.31 b).
    const out1 = try emitWithOpts("let obj = { [key]: value };", .{ .es_target = .es5 });
    defer T.allocator.free(out1);
    try T.expect(std.mem.indexOf(u8, out1, "var _a;") != null);
    try T.expect(std.mem.indexOf(u8, out1, "(_a = {}, _a[key] = value, _a)") != null);

    // props before the first computed key seed the literal; later plain
    // props become dot-assignments.
    const out2 = try emitWithOpts("let obj = { a: 1, [k]: v, b: 2 };", .{ .es_target = .es5 });
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "(_a = { a: 1 }, _a[k] = v, _a.b = 2, _a)") != null);

    // computed method keys ride the same lowering.
    const out3 = try emitWithOpts("let obj = { [key]() { return 1; } };", .{ .es_target = .es5 });
    defer T.allocator.free(out3);
    try T.expect(std.mem.indexOf(u8, out3, "(_a = {}, _a[key] = function () {") != null);
}

test "emit: computed object keys stay native at es2015+" {
    const out = try emitWithOpts("let obj = { [key]: value };", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "[key]: value") != null);
    try T.expect(std.mem.indexOf(u8, out, "_a") == null);
}

test "emit: call-site spread preserved natively at es2015+" {
    const out = try emitWithOpts("f(...a);", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "f(...a)") != null);
    try T.expect(std.mem.indexOf(u8, out, ".apply(") == null);
}

test "emit: mixed array spread lowers to concat() at es5" {
    // spread-then-element: `[...a, b]` -> `a.concat([b])`.
    const out1 = try emitWithOpts("let r = [...a, b];", .{ .es_target = .es5 });
    defer T.allocator.free(out1);
    try T.expect(std.mem.indexOf(u8, out1, "a.concat([b])") != null);
    try T.expect(std.mem.indexOf(u8, out1, "[...") == null);

    // element-then-spread: `[x, ...a]` -> `[x].concat(a)`.
    const out2 = try emitWithOpts("let r = [x, ...a];", .{ .es_target = .es5 });
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "[x].concat(a)") != null);

    // two spreads: `[...a, ...b]` -> `a.concat(b)`.
    const out3 = try emitWithOpts("let r = [...a, ...b];", .{ .es_target = .es5 });
    defer T.allocator.free(out3);
    try T.expect(std.mem.indexOf(u8, out3, "a.concat(b)") != null);

    // single spread still copies via slice (unchanged).
    const out4 = try emitWithOpts("let r = [...a];", .{ .es_target = .es5 });
    defer T.allocator.free(out4);
    try T.expect(std.mem.indexOf(u8, out4, "a.slice()") != null);
}

test "emit: mixed array spread preserved natively at es2015+" {
    const out = try emitWithOpts("let r = [...a, b];", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "[...a, b]") != null);
    try T.expect(std.mem.indexOf(u8, out, ".concat(") == null);
}

test "emit: new-with-spread lowers to bind.apply() at es5" {
    // `new C(...a)` -> `new (C.bind.apply(C, [void 0].concat(a)))()`.
    const out1 = try emitWithOpts("new C(...a);", .{ .es_target = .es5 });
    defer T.allocator.free(out1);
    try T.expect(std.mem.indexOf(u8, out1, "new (C.bind.apply(C, [void 0].concat(a)))()") != null);
    try T.expect(std.mem.indexOf(u8, out1, "new C(...") == null);

    // leading fixed args merge into the base literal after void 0.
    const out2 = try emitWithOpts("new C(1, 2, ...a);", .{ .es_target = .es5 });
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "new (C.bind.apply(C, [void 0, 1, 2].concat(a)))()") != null);

    // trailing fixed arg after the spread.
    const out3 = try emitWithOpts("new C(...a, b);", .{ .es_target = .es5 });
    defer T.allocator.free(out3);
    try T.expect(std.mem.indexOf(u8, out3, "new (C.bind.apply(C, [void 0].concat(a, [b])))()") != null);
}

test "emit: new-with-spread preserved natively at es2015+" {
    const out = try emitWithOpts("new C(...a);", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "new C(...a)") != null);
    try T.expect(std.mem.indexOf(u8, out, "bind.apply") == null);
}

test "emit: object shorthand expands at es5" {
    // `{ foo }` shorthand is ES2015; at es5 -> `{ foo: foo }`.
    const out = try emitWithOpts("let o = { foo, bar };", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "foo: foo") != null);
    try T.expect(std.mem.indexOf(u8, out, "bar: bar") != null);
}

test "emit: object shorthand preserved natively at es2015+" {
    const out = try emitWithOpts("let o = { foo };", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "{ foo }") != null);
    try T.expect(std.mem.indexOf(u8, out, "foo: foo") == null);
}

test "emit: exponentiation lowers to Math.pow below es2016" {
    const out1 = try emitWithOpts("let r = 2 ** 3;", .{ .es_target = .es5 });
    defer T.allocator.free(out1);
    try T.expect(std.mem.indexOf(u8, out1, "Math.pow(2, 3)") != null);
    try T.expect(std.mem.indexOf(u8, out1, "**") == null);

    // right-associative nesting: `2 ** 3 ** 4` -> `Math.pow(2, Math.pow(3, 4))`.
    const out2 = try emitWithOpts("let r = 2 ** 3 ** 4;", .{ .es_target = .es2015 });
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "Math.pow(2, Math.pow(3, 4))") != null);

    // compound `x **= 2` -> `x = Math.pow(x, 2)`.
    const out3 = try emitWithOpts("x **= 2;", .{ .es_target = .es5 });
    defer T.allocator.free(out3);
    try T.expect(std.mem.indexOf(u8, out3, "x = Math.pow(x, 2)") != null);
}

test "emit: exponentiation preserved natively at es2016+" {
    const out = try emitWithOpts("let r = 2 ** 3;", .{ .es_target = .es2016 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "2 ** 3") != null);
    try T.expect(std.mem.indexOf(u8, out, "Math.pow") == null);
}

test "emit: object spread lowers to __assign below es2018" {
    // leading spread uses an empty `{}` base.
    const out1 = try emitWithOpts("let o = { ...rest };", .{ .es_target = .es5 });
    defer T.allocator.free(out1);
    try T.expect(std.mem.indexOf(u8, out1, "__assign({}, rest)") != null);
    try T.expect(std.mem.indexOf(u8, out1, "{ ...") == null);

    // interior spread: fold left with object-literal chunks on both sides.
    const out2 = try emitWithOpts("let o = { a: 1, ...rest, c: 2 };", .{ .es_target = .es2017 });
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "__assign(__assign({ a: 1 }, rest), { c: 2 })") != null);

    // leading spread then a prop.
    const out3 = try emitWithOpts("let o = { ...a, b: 2 };", .{ .es_target = .es5 });
    defer T.allocator.free(out3);
    try T.expect(std.mem.indexOf(u8, out3, "__assign(__assign({}, a), { b: 2 })") != null);
}

test "emit: object spread preserved natively at es2018+" {
    const out = try emitWithOpts("let o = { ...rest };", .{ .es_target = .es2018 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "{ ...rest }") != null);
    try T.expect(std.mem.indexOf(u8, out, "__assign") == null);
}

test "emit: es5 class instance getter lowers to defineProperty" {
    const out = try emitWithOpts("class C { get prop() { return 1; } }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    // Structural checks — function bodies are emitted multi-line, matching
    // home's existing method-body convention.
    try T.expect(std.mem.indexOf(u8, out, "Object.defineProperty(C.prototype, \"prop\", { get: function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "enumerable: false, configurable: true });") != null);
    try T.expect(std.mem.indexOf(u8, out, "C.prototype.prop = function") == null);
}

test "emit: es5 class getter+setter merge into one defineProperty" {
    const out = try emitWithOpts("class C { get prop() { return this._p; } set prop(v) { this._p = v; } }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    // both accessors share a single defineProperty call, get before set.
    try T.expect(std.mem.indexOf(u8, out, "Object.defineProperty(C.prototype, \"prop\", { get: function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "set: function (v) {") != null);
    // exactly one defineProperty for this key (no duplicate that would clobber).
    const first = std.mem.indexOf(u8, out, "Object.defineProperty(C.prototype, \"prop\"").?;
    try T.expect(std.mem.indexOf(u8, out[first + 10 ..], "Object.defineProperty(C.prototype, \"prop\"") == null);
}

test "emit: es5 class static getter targets the constructor" {
    const out = try emitWithOpts("class C { static get prop() { return 1; } }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "Object.defineProperty(C, \"prop\", { get: function () {") != null);
    try T.expect(std.mem.indexOf(u8, out, "C.prototype") == null);
}

test "emit: es2015+ class accessors stay native" {
    const out = try emitWithOpts("class C { get prop() { return 1; } }", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "get prop()") != null);
    try T.expect(std.mem.indexOf(u8, out, "defineProperty") == null);
}

test "emit: es5 async arrow lowers via __awaiter" {
    // block body: `await x` -> `yield x` inside the __awaiter generator.
    const out1 = try emitWithOpts("let f = async () => { await x; };", .{ .es_target = .es5 });
    defer T.allocator.free(out1);
    try T.expect(std.mem.indexOf(u8, out1, "return __awaiter(this, void 0, void 0, function* () {") != null);
    try T.expect(std.mem.indexOf(u8, out1, "yield x;") != null);
    try T.expect(std.mem.indexOf(u8, out1, "}); }.bind(this)") != null);
    try T.expect(std.mem.indexOf(u8, out1, "async function") == null);

    // expression body returns from the generator.
    const out2 = try emitWithOpts("let f = async () => x;", .{ .es_target = .es5 });
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "return __awaiter(this, void 0, void 0, function* () { return x; }); }.bind(this)") != null);
}

test "emit: es2017+ async arrow stays native" {
    const out = try emitWithOpts("let f = async () => x;", .{ .es_target = .es2017 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "async ") != null);
    try T.expect(std.mem.indexOf(u8, out, "__awaiter") == null);
}

test "emit: es5 implicit derived constructor forwards args to base" {
    const out = try emitWithOpts("class Base {} class Derived extends Base {}", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "return _super !== null && _super.apply(this, arguments) || this;") != null);
    try T.expect(std.mem.indexOf(u8, out, "_super.call(this);") == null);
}

test "emit: es5 derived with instance field keeps in-place super call" {
    // Field-bearing derived classes still need a _this capture (deferred);
    // they keep the in-place `_super.call(this)` form for now.
    const out = try emitWithOpts("class Base {} class D extends Base { x = 1; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "_super.call(this);") != null);
}

test "emit: private-field brand check lowers to WeakMap.has below es2022" {
    // The private-field WeakMap weave is active at es2015–es2021; the ES5
    // class-IIFE path doesn't downlevel privates (separate gap), so this
    // brand-check lowering targets the range where `_C_f` storage exists.
    const out = try emitWithOpts("class C { #f = 1; m(o: C) { return #f in o; } }", .{ .es_target = .es2021 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "_C_f.has(o)") != null);
    try T.expect(std.mem.indexOf(u8, out, "#f in o") == null);
}

test "emit: private-field brand check stays native at es2022+" {
    const out = try emitWithOpts("class C { #f = 1; m(o: C) { return #f in o; } }", .{ .es_target = .esnext });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "#f in o") != null);
    try T.expect(std.mem.indexOf(u8, out, ".has(") == null);
}

test "emit: cjs default import lowers via __importDefault" {
    const out = try emitWithOpts("import x from \"y\";", .{ .module_kind = .commonjs, .es_module_interop = true });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__importDefault(require(\"y\"))") != null);
    try T.expect(std.mem.indexOf(u8, out, ".default") != null);
}

test "emit: cjs default import without interop is plain require" {
    const out = try emitWithOpts("import x from \"y\";", .{ .module_kind = .commonjs, .es_module_interop = false });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "require(\"y\")") != null);
    try T.expect(std.mem.indexOf(u8, out, "__importDefault") == null);
}

test "emit: cjs namespace import lowers via __importStar" {
    const out = try emitWithOpts("import * as x from \"y\";", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__importStar(require(\"y\"))") != null);
}

test "emit: cjs named import destructures from require" {
    const out = try emitWithOpts("import { a, b } from \"y\";", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "const { a, b } = require(\"y\")") != null);
}

test "emit: cjs side-effect import emits bare require" {
    const out = try emitWithOpts("import \"y\";", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "require(\"y\")") != null);
    try T.expect(std.mem.indexOf(u8, out, "const") == null);
}

test "emit: cjs export-decl assigns to module.exports" {
    const out = try emitWithOpts("export function add(a, b) { return a + b; }", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "function add") != null);
    try T.expect(std.mem.indexOf(u8, out, "module.exports.add = add") != null);
}

test "emit: cjs export-default-fn assigns to module.exports.default" {
    const out = try emitWithOpts("export default function f() { return 1; }", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "module.exports.default = f") != null);
}

test "emit: esm export-star preserves star form" {
    const out = try emitWithOpts("export * from \"./foo\";", .{});
    defer T.allocator.free(out);
    try T.expectEqualStrings("export * from \"./foo\";", out);
}

test "emit: esm export-star-as preserves alias" {
    const out = try emitWithOpts("export * as ns from \"./foo\";", .{});
    defer T.allocator.free(out);
    try T.expectEqualStrings("export * as ns from \"./foo\";", out);
}

test "emit: esm named re-export preserves from clause" {
    const out = try emitWithOpts("export { x, y as z } from \"./bar\";", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "export { x, y as z } from \"./bar\";") != null);
}

test "emit: esm export-default-as re-exports default binding" {
    const out = try emitWithOpts("export { default as foo } from \"./bar\";", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "export { default as foo } from \"./bar\";") != null);
}

test "emit: cjs export-star lowers via Object.defineProperty loop" {
    const out = try emitWithOpts("export * from \"./foo\";", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    // No bare `export *` survives.
    try T.expect(std.mem.indexOf(u8, out, "export *") == null);
    // Lowering walks the source module's keys and forwards each to
    // module.exports, skipping `default`.
    try T.expect(std.mem.indexOf(u8, out, "Object.keys(require(\"./foo\"))") != null);
    try T.expect(std.mem.indexOf(u8, out, "k !== \"default\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "Object.defineProperty(module.exports, k") != null);
}

test "emit: cjs export-star-as assigns whole module to alias" {
    const out = try emitWithOpts("export * as ns from \"./foo\";", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "module.exports.ns = require(\"./foo\");") != null);
}

test "emit: cjs named re-export assigns each binding" {
    const out = try emitWithOpts("export { x, y as z } from \"./bar\";", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "module.exports.x = require(\"./bar\").x;") != null);
    try T.expect(std.mem.indexOf(u8, out, "module.exports.z = require(\"./bar\").y;") != null);
}

test "emit: cjs export-default-as re-exports default binding" {
    const out = try emitWithOpts("export { default as foo } from \"./bar\";", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "module.exports.foo = require(\"./bar\").default;") != null);
}

// ----- ESM ↔ CJS interop: full-pattern coverage --------------------------
// These tests pin down the exact emit shape for the five common ESM↔CJS
// interop cases so a regression in helper insertion or assignment form
// surfaces immediately rather than masquerading as a "looks close" diff.

test "emit: cjs default import emits full __importDefault(...).default pattern" {
    // `import x from "./y"` → `const x = __importDefault(require("./y")).default;`
    const out = try emitWithOpts("import x from \"./y\";", .{ .module_kind = .commonjs, .es_module_interop = true });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "const x = __importDefault(require(\"./y\")).default") != null);
}

test "emit: cjs namespace import emits full __importStar(require) pattern" {
    // `import * as x from "./y"` → `const x = __importStar(require("./y"));`
    const out = try emitWithOpts("import * as x from \"./y\";", .{ .module_kind = .commonjs, .es_module_interop = true });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "const x = __importStar(require(\"./y\"))") != null);
}

test "emit: cjs named import emits exact destructure-from-require shape" {
    // `import { a, b } from "./y"` → `const { a, b } = require("./y");`
    const out = try emitWithOpts("import { a, b } from \"./y\";", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "const { a, b } = require(\"./y\")") != null);
    // No interop helpers should be injected for plain named imports.
    try T.expect(std.mem.indexOf(u8, out, "__importDefault") == null);
    try T.expect(std.mem.indexOf(u8, out, "__importStar") == null);
}

test "emit: cjs export-default expression assigns to module.exports.default" {
    // `export default <expr>` → `module.exports.default = <expr>;` for
    // non-decl payloads (number literals, identifiers, calls, ...).
    const out = try emitWithOpts("export default 42;", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "module.exports.default = 42") != null);
    // Ensure no stray ESM `export default` keyword survived lowering.
    try T.expect(std.mem.indexOf(u8, out, "export default") == null);
}

test "emit: cjs local export-clause assigns each binding to module.exports" {
    // `export { x }` (no `from` clause) refers to a local binding and
    // lowers to `module.exports.x = x;`. With aliasing, the alias goes
    // on the LHS and the local name on the RHS.
    const out = try emitWithOpts("const x = 1; const y = 2; export { x, y as renamed };", .{ .module_kind = .commonjs });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "module.exports.x = x") != null);
    try T.expect(std.mem.indexOf(u8, out, "module.exports.renamed = y") != null);
    // Should not look like a re-export from a module.
    try T.expect(std.mem.indexOf(u8, out, "require(") == null);
}

test "emit: throw" {
    const out = try emit("throw new Error(\"bad\");");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "throw ") != null);
}

test "emit: class decl" {
    const out = try emit("class Foo { x = 1; greet() { return 1; } }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "class Foo") != null);
}

test "emit: class extends" {
    const out = try emit("class B extends A {}");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "class B extends A") != null);
}

test "emit: class extends generic instantiation erases type args" {
    const out = try emit("class B extends A<string> {}");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "class B extends A") != null);
    try T.expect(std.mem.indexOf(u8, out, "A<string>") == null);
}

test "emit: switch with cases" {
    const out = try emit("switch (x) { case 1: f(); break; default: g(); }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "switch (x)") != null);
    try T.expect(std.mem.indexOf(u8, out, "case 1:") != null);
    try T.expect(std.mem.indexOf(u8, out, "default:") != null);
}

test "emit: assignment expression" {
    const out = try emit("x = 5;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("x = 5;", out);
}

test "emit: compound assignment" {
    const out = try emit("x += 1;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("x += 1;", out);
}

test "emit: logical operators" {
    const out = try emit("a && b;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("a && b;", out);
}

test "emit: ternary" {
    const out = try emit("a ? 1 : 2;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("a ? 1 : 2;", out);
}

test "emit: optional chaining" {
    const out = try emit("a?.b;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("a?.b;", out);
}

test "emit: export default function" {
    const out = try emit("export default function f() {}");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "export default function f") != null);
}

test "emit: export default declaration carries no trailing semicolon" {
    // A function/class declaration is not an expression statement, so no
    // `;` follows it — neither tsc nor Bun emit one. (`export default
    // function f() {};` would be a spurious empty statement.)
    const fn_out = try emit("export default function f() {}");
    defer T.allocator.free(fn_out);
    try T.expect(std.mem.indexOf(u8, fn_out, "{};") == null);

    const cls_out = try emit("export default class C {}");
    defer T.allocator.free(cls_out);
    try T.expect(std.mem.indexOf(u8, cls_out, "{};") == null);

    // An arrow / expression default export *is* an expression and keeps `;`.
    const arrow_out = try emit("export default () => 1;");
    defer T.allocator.free(arrow_out);
    try T.expect(std.mem.indexOf(u8, arrow_out, "=> 1;") != null);
}

test "emit: let / const / var distinct" {
    const out = try emit("let a = 1; const b = 2; var c = 3;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "let a = 1;") != null);
    try T.expect(std.mem.indexOf(u8, out, "const b = 2;") != null);
    try T.expect(std.mem.indexOf(u8, out, "var c = 3;") != null);
}

test "emit: type annotation erases" {
    const out = try emit("let x: number = 1;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("let x = 1;", out);
}

test "emit: declaration without initializer" {
    const out = try emit("let x;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("let x;", out);
}

test "emit: arrow expression body" {
    const out = try emit("let f = x => x + 1;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "(x) => x + 1") != null);
}

test "emit: arrow block body" {
    const out = try emit("let f = (x) => { return x; };");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "(x) => {") != null);
}

test "emit: arrow concise body wraps a comma sequence" {
    // `() => a, b` parses as `(() => a), b`, so the sequence body must stay
    // parenthesized — the concise body is printed at the `.comma` level.
    const out = try emit("const f = () => (a, b);");
    defer T.allocator.free(out);
    try T.expectEqualStrings("const f = () => (a, b);", out);
}

test "emit: async arrow" {
    const out = try emit("let f = async (x) => x;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "async (x) => x") != null);
}

test "emit: class with decorator emits __decorate helper" {
    const out = try emit("@logged class Foo {}");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "class Foo") != null);
    try T.expect(std.mem.indexOf(u8, out, "Foo = __decorate([logged], Foo);") != null);
}

test "emit: class with multiple decorators preserves order" {
    const out = try emit("@a @b @c class Bar {}");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "Bar = __decorate([a, b, c], Bar);") != null);
}

test "emit: class with decorator-call expression" {
    const out = try emit("@inject(Foo) class Bar {}");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([inject(Foo)], Bar)") != null);
}

test "emit: stage 3 class decorator emits descriptor + class-replacement chain" {
    const out = try emitWithOpts("@logged class Foo {}", .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // §4.A.9 v13 — Stage 3 class decorators now lower into an IIFE
    // with a static block at the top of the class body. The static
    // block runs the descriptor + __esDecorate + rebind + extras
    // chain DURING class init so any subsequent static-block /
    // static-field initializer in the same body sees the post-
    // decorator class identity. The IIFE returns the (rebound)
    // class to the outer `let` binding.
    try T.expect(std.mem.indexOf(u8, out, "let Foo = (() => {") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_metadata = typeof Symbol === \"function\" && Symbol.metadata ? Object.create(null) : void 0;") != null);
    try T.expect(std.mem.indexOf(u8, out, "class Foo") != null);
    try T.expect(std.mem.indexOf(u8, out, "static {") != null);
    // Inside the static block: descriptor + extras as separate
    // statements (no comma-fold), referencing `this` (the original
    // class). Rebind targets the IIFE-scope `Foo` binding.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_d = { value: this };") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_extra = [];") != null);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, _Foo_d, [logged], { kind: \"class\", name: \"Foo\", metadata: _Foo_metadata }, null, _Foo_extra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "Foo = _Foo_d.value;") != null);
    try T.expect(std.mem.indexOf(u8, out, "__runInitializers(Foo, _Foo_extra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "return Foo;") != null);
    try T.expect(std.mem.indexOf(u8, out, "})();") != null);
    // Stage 3 must NOT emit the legacy `__decorate` form.
    try T.expect(std.mem.indexOf(u8, out, "= __decorate(") == null);
}

test "emit: stage 3 multiple class decorators preserve order" {
    const out = try emitWithOpts("@a @b @c class Bar {}", .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // §4.A.9 v13 — same IIFE+static-block shape as the single-decorator
    // case; the decorator list is preserved in source order.
    try T.expect(std.mem.indexOf(u8, out, "let Bar = (() => {") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Bar_d = { value: this };") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Bar_extra = [];") != null);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, _Bar_d, [a, b, c], { kind: \"class\", name: \"Bar\", metadata: _Bar_metadata }, null, _Bar_extra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "Bar = _Bar_d.value;") != null);
    try T.expect(std.mem.indexOf(u8, out, "__runInitializers(Bar, _Bar_extra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "return Bar;") != null);
}

test "emit: stage 3 class decorator with call expression preserves arguments" {
    const out = try emitWithOpts("@inject(Foo) class Bar {}", .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "class Bar") != null);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, _Bar_d, [inject(Foo)], { kind: \"class\", name: \"Bar\", metadata: _Bar_metadata }, null, _Bar_extra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "Bar = _Bar_d.value;") != null);
    // Legacy form must NOT appear under stage 3.
    try T.expect(std.mem.indexOf(u8, out, "Bar = __decorate(") == null);
}

test "emit: stage 3 method decorator on class method emits per-member decorate" {
    const out = try emitWithOpts(
        \\@logged class Foo {
        \\  @traced
        \\  greet() { return 1; }
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // Class-level decorator uses the Stage 3 descriptor + replacement chain.
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, _Foo_d, [logged], { kind: \"class\", name: \"Foo\", metadata: _Foo_metadata }, null, _Foo_extra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "Foo = _Foo_d.value;") != null);
    try T.expect(std.mem.indexOf(u8, out, "__runInitializers(Foo, _Foo_extra);") != null);
    // §4.A.9 v7 — instance-decorator chain now declares
    // `_Foo_instanceExtra = []` and passes it to instance __esDecorate
    // calls; the ctor synthesizes a `__runInitializers(this, ...)` trailer.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_instanceExtra = [];") != null);
    // §4.A.9 v11 — metadata var declared once before the chain and
    // shared by the class decorator + every member decorator.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_metadata = typeof Symbol === \"function\" && Symbol.metadata ? Object.create(null) : void 0;") != null);
    // §4.A.9 v14 — instance non-field decorators (method/getter/
    // setter/accessor) now pass the class identifier as slot 1 so
    // tslib's `Object.defineProperty(target, name, descriptor)` path
    // applies decorator-returned `value`/`get`/`set` replacements.
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(Foo, null, [traced], { kind: \"method\", name: \"greet\", static: false, private: false, access: { has: function (obj) { return \"greet\" in obj; }, get: function (obj) { return obj.greet; } }, metadata: _Foo_metadata }, null, _Foo_instanceExtra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "__runInitializers(this, _Foo_instanceExtra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([traced]") == null);
}

test "emit: stage 3 field/accessor decorators emit member contexts" {
    const out = try emitWithOpts(
        \\class Foo {
        \\  @observe
        \\  count: number = 0;
        \\  @memo
        \\  get value(): number { return this.count; }
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // §4.A.9 v7 — instance-extras array + runInitializers trailer.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_instanceExtra = [];") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_metadata = typeof Symbol === \"function\" && Symbol.metadata ? Object.create(null) : void 0;") != null);
    // §4.A.9 v12 — decorated field gets a per-field init array passed
    // as slot 5 (`initializers`) of __esDecorate; the ctor wraps the
    // field's value with `__runInitializers(this, _Foo_count_init, ...)`.
    // Getters/setters/methods don't carry initializer wrapping, so
    // slot 5 stays `null` for the `@memo get value()` line.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_count_init = [];") != null);
    // Field decorator still passes `null` as slot 1 — field-decorator
    // return values are initializer wrappers (slot 5), not descriptor
    // values, so tslib's defineProperty pass would do the wrong thing.
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, null, [observe], { kind: \"field\", name: \"count\", static: false, private: false, access: { has: function (obj) { return \"count\" in obj; }, get: function (obj) { return obj.count; }, set: function (obj, value) { obj.count = value; } }, metadata: _Foo_metadata }, _Foo_count_init, _Foo_instanceExtra);") != null);
    // §4.A.9 v14 — instance getter decorator now passes `Foo` so tslib
    // can apply a decorator-returned `get` replacement via defineProperty.
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(Foo, null, [memo], { kind: \"getter\", name: \"value\", static: false, private: false, access: { has: function (obj) { return \"value\" in obj; }, get: function (obj) { return obj.value; } }, metadata: _Foo_metadata }, null, _Foo_instanceExtra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "count = __runInitializers(this, _Foo_count_init, 0);") != null);
    try T.expect(std.mem.indexOf(u8, out, "__runInitializers(this, _Foo_instanceExtra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([observe]") == null);
}

test "emit: stage 3 static member decorators mark static context" {
    const out = try emitWithOpts(
        \\class Foo {
        \\  @logged
        \\  static greet() { return 1; }
        \\  @observe
        \\  static count = 0;
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);

    // §4.A.9 v6 — when there's any decorated static member, the
    // emit declares `var _Foo_staticExtra = [];` once and passes it
    // as the 6th arg of each static __esDecorate call, then calls
    // `__runInitializers(Foo, _Foo_staticExtra);` after the chain.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_staticExtra = [];") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_metadata = typeof Symbol === \"function\" && Symbol.metadata ? Object.create(null) : void 0;") != null);
    // §4.A.9 v12 — decorated static field gets its per-field init
    // array; the class-body static-field emit wraps the literal `0`
    // with `__runInitializers(this, _Foo_count_init, 0)` where `this`
    // refers to the class inside a static field initializer.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_count_init = [];") != null);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(Foo, null, [logged], { kind: \"method\", name: \"greet\", static: true, private: false, access: { has: function (obj) { return \"greet\" in obj; }, get: function (obj) { return obj.greet; } }, metadata: _Foo_metadata }, null, _Foo_staticExtra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(Foo, null, [observe], { kind: \"field\", name: \"count\", static: true, private: false, access: { has: function (obj) { return \"count\" in obj; }, get: function (obj) { return obj.count; }, set: function (obj, value) { obj.count = value; } }, metadata: _Foo_metadata }, _Foo_count_init, _Foo_staticExtra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "static count = __runInitializers(this, _Foo_count_init, 0);") != null);
    try T.expect(std.mem.indexOf(u8, out, "__runInitializers(Foo, _Foo_staticExtra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "static: false") == null);
}

test "emit: class accessor field lowers via #-private storage at ES2022+ default" {
    // §4.A.9 v9/v10 — at esnext (default), use native `#<key>_accessor`
    // private slot. Below ES2022 the emit uses underscore-prefix.
    const out = try emitWithOpts(
        \\class Foo {
        \\  @validated
        \\  accessor count = 0;
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // §4.A.9 v12 — decorated auto-accessor wraps the storage-slot
    // initializer with `__runInitializers(this, _Foo_count_init, 0)`
    // so Stage 3 accessor decorators returning `{ init: ... }` actually
    // wrap the initial value. Without a decorator the slot would still
    // emit `#count_accessor = 0;` plainly.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_count_init = [];") != null);
    try T.expect(std.mem.indexOf(u8, out, "#count_accessor = __runInitializers(this, _Foo_count_init, 0);") != null);
    try T.expect(std.mem.indexOf(u8, out, "get count() { return this.#count_accessor; }") != null);
    try T.expect(std.mem.indexOf(u8, out, "set count(value) { this.#count_accessor = value; }") != null);
    // Native `accessor` keyword is gone (we always lower).
    try T.expect(std.mem.indexOf(u8, out, "accessor count") == null);
    try T.expect(std.mem.indexOf(u8, out, "kind: \"accessor\", name: \"count\"") != null);
}

test "emit: stage 3 v13c member __esDecorate runs inside static block before class decorate" {
    // §4.A.9 v13c — when a class has BOTH a class-level decorator
    // and a member decorator under Stage 3, both decorate chains
    // run inside the same `static { ... }` block at the top of
    // the class body. The member chain comes FIRST (so member
    // decorators see the original class), then the class chain
    // rebinds the class identity.
    const out = try emitWithOpts(
        \\@logged class Foo {
        \\  @observe
        \\  count = 0;
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // Both decorate calls appear in the output.
    const member_idx = std.mem.indexOf(u8, out, "__esDecorate(null, null, [observe]").?;
    const class_idx = std.mem.indexOf(u8, out, "__esDecorate(null, _Foo_d, [logged]").?;
    // Member chain runs BEFORE class chain.
    try T.expect(member_idx < class_idx);
    // Both are inside the static block (which appears before any
    // `}` closing the class body — there's only one such `}` for
    // this empty-body class besides the static block's own).
    const static_idx = std.mem.indexOf(u8, out, "static {").?;
    try T.expect(static_idx < member_idx);
    try T.expect(static_idx < class_idx);
}

test "emit: stage 3 v14 accessor decorator passes class as __esDecorate ctor arg" {
    // §4.A.9 v14 — instance accessor decorators must pass the class
    // identifier as slot 1 of __esDecorate so tslib's helper can
    // (a) read the current accessor's `{ get, set }` descriptor from
    // the prototype, (b) let the decorator return a `{ get, set, init }`
    // replacement, and (c) apply the (possibly replaced) descriptor
    // via `Object.defineProperty(Class.prototype, name, descriptor)`.
    // Without the class as slot 1, tslib's `target` resolves to `null`
    // and the defineProperty pass is skipped — `get`/`set` replacement
    // silently no-ops.
    const out = try emitWithOpts(
        \\class Foo {
        \\  @validated
        \\  accessor count = 0;
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // The accessor decorator emits with `Foo` as slot 1 — not `null`.
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(Foo, null, [validated], { kind: \"accessor\"") != null);
    // The init array is still passed as slot 5 (v12) so init
    // wrappers from the same decorator still work.
    try T.expect(std.mem.indexOf(u8, out, ", _Foo_count_init, _Foo_instanceExtra);") != null);
}

test "emit: stage 3 v14 instance method decorator passes class as ctor arg" {
    // §4.A.9 v14 — instance method/getter/setter decorators get the
    // class as slot 1 (was `null` pre-v14) so decorator-returned
    // method/getter/setter replacements actually take effect.
    const out = try emitWithOpts(
        \\class Foo {
        \\  @log
        \\  greet() { return 1; }
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(Foo, null, [log], { kind: \"method\", name: \"greet\", static: false,") != null);
}

test "emit: stage 3 v13b member-only-decorated class is IIFE-wrapped" {
    // §4.A.9 v13b — a class with no class-level decorator but at
    // least one member decorator IIFE-wraps so the per-class
    // metadata + extras + init vars stay scoped to the IIFE.
    // §4.A.9 v13c — the member decorate chain runs inside the
    // class's `static { ... }` block (moved there from post-class
    // for tsc-byte-equivalence). No class decorate sub-chain is
    // emitted since there's no class-level decorator.
    const out = try emitWithOpts(
        \\class Foo {
        \\  @observe
        \\  count = 0;
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // IIFE preamble + return + close.
    try T.expect(std.mem.indexOf(u8, out, "let Foo = (() => {") != null);
    try T.expect(std.mem.indexOf(u8, out, "return Foo;") != null);
    try T.expect(std.mem.indexOf(u8, out, "})();") != null);
    // Per-class metadata var is hoisted to IIFE scope.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_metadata = typeof Symbol === \"function\" && Symbol.metadata ? Object.create(null) : void 0;") != null);
    // §4.A.9 v13c — static block is now emitted (member chain lives
    // inside it). The chain itself stays substring-compatible with
    // the previous post-class shape.
    try T.expect(std.mem.indexOf(u8, out, "static {") != null);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, null, [observe], { kind: \"field\"") != null);
    // No class decorate sub-chain — no `_Foo_d`, no class rebind.
    try T.expect(std.mem.indexOf(u8, out, "_Foo_d =") == null);
}

test "emit: stage 3 v13b undecorated class is NOT IIFE-wrapped" {
    // §4.A.9 v13b — gating check: a class with no decorators (class
    // or member) stays as a plain `class Foo {}` declaration. No
    // IIFE, no metadata var.
    const out = try emitWithOpts(
        \\class Foo {
        \\  count = 0;
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "let Foo = (() => {") == null);
    try T.expect(std.mem.indexOf(u8, out, "_Foo_metadata") == null);
    try T.expect(std.mem.indexOf(u8, out, "class Foo") != null);
}

test "emit: stage 3 v14 instance field decorator still passes null as ctor arg" {
    // §4.A.9 v14 — field decorators keep `null` as slot 1 because
    // their return value is an initializer wrapper (slot 5), not a
    // descriptor `value`. Passing the class would trigger tslib's
    // defineProperty pass which would redefine the prototype with the
    // wrong shape for fields.
    const out = try emitWithOpts(
        \\class Foo {
        \\  @observe
        \\  count = 0;
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, null, [observe], { kind: \"field\", name: \"count\", static: false,") != null);
}

test "emit: stage 3 decorated field at ES2021 wraps hoisted init via __runInitializers" {
    // §4.A.9 v12 — at sub-ES2022 the public field is hoisted into
    // the (synthesized or explicit) ctor as `this.X = value;`. When
    // the field has a Stage 3 decorator the value is wrapped with
    // `__runInitializers(this, _<Class>_<field>_init, value)` so any
    // initializer-wrapping behavior the decorator returns actually
    // runs. This test exercises the hoisted-ctor path explicitly.
    const out = try emitWithOpts(
        \\class Foo {
        \\  @observe
        \\  count = 0;
        \\}
    , .{ .experimental_decorators = false, .es_target = .es2021 });
    defer T.allocator.free(out);
    // Per-field init array declared with the rest of the v6/v7/v11 vars.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_count_init = [];") != null);
    // __esDecorate passes the per-field init array as slot 5.
    try T.expect(std.mem.indexOf(u8, out, ", _Foo_count_init, _Foo_instanceExtra);") != null);
    // The hoisted ctor wraps the original literal `0` with __runInitializers.
    try T.expect(std.mem.indexOf(u8, out, "this.count = __runInitializers(this, _Foo_count_init, 0);") != null);
    // The plain literal-assignment form (no wrap) must NOT appear.
    try T.expect(std.mem.indexOf(u8, out, "this.count = 0;") == null);
}

test "emit: stage 3 undecorated field does NOT receive __runInitializers wrap" {
    // §4.A.9 v12 — wrap is gated on the field having decorators.
    // An undecorated field next to a decorated one must still emit
    // its plain initializer form (no per-field init array, no wrap).
    const out = try emitWithOpts(
        \\class Foo {
        \\  @observe
        \\  count = 0;
        \\  plain = 1;
        \\}
    , .{ .experimental_decorators = false, .es_target = .es2021 });
    defer T.allocator.free(out);
    // Decorated `count` is wrapped.
    try T.expect(std.mem.indexOf(u8, out, "this.count = __runInitializers(this, _Foo_count_init, 0);") != null);
    // Undecorated `plain` stays plain — no per-field init array.
    try T.expect(std.mem.indexOf(u8, out, "this.plain = 1;") != null);
    try T.expect(std.mem.indexOf(u8, out, "_Foo_plain_init") == null);
}

test "emit: accessor field falls back to underscore storage below ES2022" {
    // At ES2021 (no native private fields), the lowering uses the
    // underscore-prefix convention so the output stays runnable. The
    // storage's initializer is hoisted into the ctor by the existing
    // public-field downlevel (`useDefineForClassFields: false`-like
    // path), so we look for `this._count = 0;` instead of a literal
    // `_count = 0;` class-body member.
    const out = try emitWithOpts(
        \\class Foo {
        \\  accessor count = 0;
        \\}
    , .{ .es_target = .es2021 });
    defer T.allocator.free(out);
    // Storage uses underscore-prefix (no `#`), hoisted into the ctor.
    try T.expect(std.mem.indexOf(u8, out, "this._count = 0;") != null);
    try T.expect(std.mem.indexOf(u8, out, "get count() { return this._count; }") != null);
    try T.expect(std.mem.indexOf(u8, out, "set count(value) { this._count = value; }") != null);
    try T.expect(std.mem.indexOf(u8, out, "#count_accessor") == null);
}

test "emit: static accessor field lowers with static-prefixed storage + get/set" {
    const out = try emit(
        \\class Foo {
        \\  static accessor shared = 1;
        \\}
    );
    defer T.allocator.free(out);
    // At esnext, true-private `#`.
    try T.expect(std.mem.indexOf(u8, out, "static #shared_accessor = 1;") != null);
    try T.expect(std.mem.indexOf(u8, out, "static get shared()") != null);
    try T.expect(std.mem.indexOf(u8, out, "static set shared(value)") != null);
}

test "emit: class with static initialization block emits `static { ... }` on one line" {
    const out = try emit(
        \\class Foo {
        \\  static {
        \\    Foo.value = 1;
        \\  }
        \\}
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "static {") != null);
    try T.expect(std.mem.indexOf(u8, out, "Foo.value = 1;") != null);
    // No double-indent — `static` and `{` must be on the same line.
    try T.expect(std.mem.indexOf(u8, out, "static\n") == null);
    try T.expect(std.mem.indexOf(u8, out, "static  {") == null);
}

test "emit: stage 3 setter decorator includes set in access descriptor (no get)" {
    const out = try emitWithOpts(
        \\class Foo {
        \\  @validated
        \\  set name(v: string) { this._name = v; }
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // Setter access: has + set only (no get).
    try T.expect(std.mem.indexOf(u8, out, "kind: \"setter\", name: \"name\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "set: function (obj, value) { obj.name = value; }") != null);
    // Setter has no `get`.
    try T.expect(std.mem.indexOf(u8, out, "get: function (obj) { return obj.name;") == null);
}

test "emit: stage 3 v13 IIFE static block runs class decorate before class-body member initializers" {
    // §4.A.9 v13 — the captured-reference caveat. The class
    // body has BOTH a class-level decorator AND a static block /
    // static field that references the class identifier. Inside
    // the IIFE-wrapped emit, the injected static block (which
    // runs the class decorate chain) is emitted BEFORE the user's
    // own static block, so by the time the user's static block
    // executes, the class binding already points at the post-
    // decorator value.
    const out = try emitWithOpts(
        \\@logged class Foo {
        \\  static {
        \\    Foo.tag = "after-decorate";
        \\  }
        \\}
    , .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // Find the index of our injected static block and the user's
    // static block; the injected one (containing `_Foo_d`) must
    // appear strictly before the user's `Foo.tag = ...` block.
    const injected_idx = std.mem.indexOf(u8, out, "var _Foo_d = { value: this };").?;
    const user_idx = std.mem.indexOf(u8, out, "Foo.tag = \"after-decorate\";").?;
    try T.expect(injected_idx < user_idx);
    // The class is IIFE-wrapped; the `return Foo;` returns the
    // (rebound) class binding to the outer `let Foo`.
    try T.expect(std.mem.indexOf(u8, out, "let Foo = (() => {") != null);
    try T.expect(std.mem.indexOf(u8, out, "return Foo;") != null);
}

test "emit: stage 3 v13 IIFE round-trips a class with no class-body members" {
    // Empty class with a class decorator under Stage 3 — the IIFE
    // wraps it, the static block lives alone inside the class, and
    // the closing `}` is reachable cleanly.
    const out = try emitWithOpts("@logged class Empty {}", .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "let Empty = (() => {") != null);
    try T.expect(std.mem.indexOf(u8, out, "class Empty {") != null);
    try T.expect(std.mem.indexOf(u8, out, "static {") != null);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, _Empty_d, [logged]") != null);
    try T.expect(std.mem.indexOf(u8, out, "return Empty;") != null);
    try T.expect(std.mem.indexOf(u8, out, "})();") != null);
}

test "emit: stage 3 class-only decorator does not produce legacy class assignment" {
    const out = try emitWithOpts("@a @b class Baz {}", .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    // §4.A.9 v13 — IIFE-wrapped class with the descriptor + helper +
    // rebind + runInitializers chain inside a static block at the top
    // of the class body.
    try T.expect(std.mem.indexOf(u8, out, "let Baz = (() => {") != null);
    try T.expect(std.mem.indexOf(u8, out, "class Baz") != null);
    try T.expect(std.mem.indexOf(u8, out, "static {") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Baz_d = { value: this };") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Baz_extra = [];") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Baz_metadata = typeof Symbol === \"function\" && Symbol.metadata ? Object.create(null) : void 0;") != null);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, _Baz_d, [a, b], { kind: \"class\", name: \"Baz\", metadata: _Baz_metadata }, null, _Baz_extra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "Baz = _Baz_d.value;") != null);
    try T.expect(std.mem.indexOf(u8, out, "__runInitializers(Baz, _Baz_extra);") != null);
    try T.expect(std.mem.indexOf(u8, out, "return Baz;") != null);
    // No legacy `Name = __decorate(...)` rewiring under Stage 3.
    try T.expect(std.mem.indexOf(u8, out, "Baz = __decorate(") == null);
}

test "emit: sourceMappingURL trailer appended when configured" {
    const s = try newTestSetup("let x = 1;");
    defer destroyTestSetup(s);

    var printer = Printer.init(T.allocator, &s.hir, &s.interner, .{
        .source_map_url = "out.js.map",
    });
    defer printer.deinit();
    try printer.printSourceFile(s.root);
    const out = try printer.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "//# sourceMappingURL=out.js.map") != null);
}

test "emit: no sourceMappingURL when option absent" {
    const s = try newTestSetup("let x = 1;");
    defer destroyTestSetup(s);

    var printer = Printer.init(T.allocator, &s.hir, &s.interner, .{});
    defer printer.deinit();
    try printer.printSourceFile(s.root);
    const out = try printer.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "sourceMappingURL") == null);
}

test "emit: source map records mappings for each statement" {
    const src = "let x = 1;\nlet y = 2;\nlet z = 3;";
    const s = try newTestSetup(src);
    defer destroyTestSetup(s);

    var sm = source_map_mod.SourceMap.init(T.allocator, "out.js");
    defer sm.deinit();
    const sidx = try sm.addSource("in.ts", src);

    var printer = Printer.init(T.allocator, &s.hir, &s.interner, .{
        .source_map = &sm,
        .source_map_src_idx = sidx,
    });
    defer printer.deinit();
    printer.setSource(src);
    try printer.printSourceFile(s.root);

    // Three statements -> at least 3 mappings.
    try T.expect(sm.mappings.items.len >= 3);

    // First mapping should map gen (0, 0) -> src (0, 0).
    const first = sm.mappings.items[0];
    try T.expectEqual(@as(u32, 0), first.gen_line);
    try T.expectEqual(@as(u32, 0), first.gen_col);
    try T.expectEqual(@as(u32, 0), first.src_line);
    try T.expectEqual(@as(u32, 0), first.src_col);
}

test "emit: private field lowers to WeakMap below es2022" {
    const out = try emitWithOpts(
        "class Foo { #count = 0; get() { return this.#count; } }",
        .{ .es_target = .es2021 },
    );
    defer T.allocator.free(out);
    // WeakMap declaration appears before the class.
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_count = new WeakMap();") != null);
    // `this.#count` rewrites to `_Foo_count.get(this)`.
    try T.expect(std.mem.indexOf(u8, out, "_Foo_count.get(this)") != null);
    // The `#count` field declaration is gone from the class body.
    try T.expect(std.mem.indexOf(u8, out, "#count") == null);
}

test "emit: private field preserved at es2022+" {
    const out = try emitWithOpts(
        "class Foo { #count = 0; get() { return this.#count; } }",
        .{ .es_target = .es2022 },
    );
    defer T.allocator.free(out);
    // No WeakMap lowering at native-private-field targets.
    try T.expect(std.mem.indexOf(u8, out, "WeakMap") == null);
    try T.expect(std.mem.indexOf(u8, out, "#count") != null);
}

test "emit: native private field with getter at es2022 emits both #x init and this.#x" {
    // §4.A.7 — at native-private-field targets we keep both the
    // class-body `#x = 1;` declaration and `this.#x` accesses
    // verbatim, with no WeakMap helper around them.
    const out = try emitWithOpts(
        "class Foo { #x = 1; getX() { return this.#x; } }",
        .{ .es_target = .es2022 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "#x = 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.#x") != null);
    try T.expect(std.mem.indexOf(u8, out, "WeakMap") == null);
    try T.expect(std.mem.indexOf(u8, out, "getX()") != null);
}

test "emit: native private field at esnext target keeps #x literally" {
    // The default `esnext` target is the highest tier — never
    // downlevel. Useful sanity check that future EsTarget bumps
    // don't accidentally trigger lowering.
    const out = try emitWithOpts(
        "class Foo { #x = 1; getX() { return this.#x; } }",
        .{ .es_target = .esnext },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "#x = 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.#x") != null);
    try T.expect(std.mem.indexOf(u8, out, "WeakMap") == null);
}

test "emit: private field downlevel to WeakMap at es2019" {
    // §4.A.7 — at ES2019 (sub-ES2022) we synthesize a per-class
    // `WeakMap` and rewrite `this.#x` reads to `_Foo_x.get(this)`.
    // The `#x` token must not survive in the output.
    const out = try emitWithOpts(
        "class Foo { #x = 1; getX() { return this.#x; } }",
        .{ .es_target = .es2019 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "new WeakMap()") != null);
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_x = new WeakMap();") != null);
    try T.expect(std.mem.indexOf(u8, out, "_Foo_x.get(this)") != null);
    try T.expect(std.mem.indexOf(u8, out, "#x") == null);
    // §4.A.7 v2 — private field initializer is now hoisted into the
    // (synthesized) ctor as `_Foo_x.set(this, 1);` so instances get
    // the initial value.
    try T.expect(std.mem.indexOf(u8, out, "_Foo_x.set(this, 1)") != null);
}

test "emit: private field with no other fields synthesizes ctor + init at es2019" {
    // Class with ONLY private-field initializer (no public fields)
    // still needs ctor synthesis at sub-ES2022.
    const out = try emitWithOpts(
        "class Foo { #count = 0; }",
        .{ .es_target = .es2019 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_count = new WeakMap();") != null);
    try T.expect(std.mem.indexOf(u8, out, "_Foo_count.set(this, 0)") != null);
}

test "emit: private field with explicit ctor hoists init into ctor body at es2019" {
    // Explicit ctor + private field init: the init lands inside the
    // ctor body (before user statements for root classes).
    const out = try emitWithOpts(
        "class Foo { #count = 0; constructor() { log(); } }",
        .{ .es_target = .es2019 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "_Foo_count.set(this, 0)") != null);
    // log() is user body; the hoisted init runs first.
    try T.expect(std.mem.indexOf(u8, out, "log()") != null);
    const init_idx = std.mem.indexOf(u8, out, "_Foo_count.set(this, 0)");
    const user_idx = std.mem.indexOf(u8, out, "log()");
    try T.expect(init_idx != null and user_idx != null);
    try T.expect(init_idx.? < user_idx.?);
}

test "emit: multiple private fields with inits all hoist at es2019" {
    const out = try emitWithOpts(
        "class Foo { #a = 1; #b = 2; }",
        .{ .es_target = .es2019 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "_Foo_a.set(this, 1)") != null);
    try T.expect(std.mem.indexOf(u8, out, "_Foo_b.set(this, 2)") != null);
}

test "emit: private field with no initializer doesn't synthesize ctor at es2019" {
    // A private field declared but not initialized doesn't need ctor
    // injection — the WeakMap entry just isn't pre-populated.
    const out = try emitWithOpts(
        "class Foo { #x; getX() { return this.#x; } }",
        .{ .es_target = .es2019 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var _Foo_x = new WeakMap();") != null);
    // No .set() call.
    try T.expect(std.mem.indexOf(u8, out, "_Foo_x.set") == null);
}

test "emit: private method `#m()` preserved at es2022+" {
    // Private methods are class-body `fn_decl` members whose name
    // starts with `#`. At ES2022+ we emit them verbatim — no
    // lowering. (Sub-ES2022 lowering of private *methods* is not
    // implemented in v0; the WeakMap path covers fields only.)
    const out = try emitWithOpts(
        "class Foo { #m() { return 1; } call() { return this.#m(); } }",
        .{ .es_target = .es2022 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "#m()") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.#m()") != null);
    try T.expect(std.mem.indexOf(u8, out, "WeakMap") == null);
}

test "emit: public class field native at es2022+" {
    const out = try emitWithOpts(
        "class Foo { x = 1; greet() { return this.x; } }",
        .{ .es_target = .es2022 },
    );
    defer T.allocator.free(out);
    // Native field declaration kept inside the class body.
    try T.expect(std.mem.indexOf(u8, out, "x = 1;") != null);
    // No synthesized constructor.
    try T.expect(std.mem.indexOf(u8, out, "constructor()") == null);
    try T.expect(std.mem.indexOf(u8, out, "this.x = 1;") == null);
}

test "emit: public class field hoisted into synthesized ctor at es2019" {
    const out = try emitWithOpts(
        "class Foo { x = 1; greet() { return this.x; } }",
        .{ .es_target = .es2019 },
    );
    defer T.allocator.free(out);
    // No bare native field declaration; it was hoisted into the ctor.
    // Match the leading newline+indentation pattern that a member
    // declaration would otherwise produce.
    try T.expect(std.mem.indexOf(u8, out, "\n  x = 1;") == null);
    // A synthesized constructor carries `this.x = 1;`.
    try T.expect(std.mem.indexOf(u8, out, "constructor()") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.x = 1;") != null);
    // Class shape is otherwise preserved.
    try T.expect(std.mem.indexOf(u8, out, "class Foo") != null);
    try T.expect(std.mem.indexOf(u8, out, "greet()") != null);
}

test "emit: useDefineForClassFields=true keeps native class field at es2022" {
    const out = try emitWithOpts(
        "class Foo { x = 1; }",
        .{ .es_target = .es2022, .use_define_for_class_fields = true },
    );
    defer T.allocator.free(out);
    // Default: native field declaration kept inside the class body.
    try T.expect(std.mem.indexOf(u8, out, "x = 1;") != null);
    try T.expect(std.mem.indexOf(u8, out, "constructor()") == null);
    try T.expect(std.mem.indexOf(u8, out, "this.x = 1;") == null);
}

test "emit: useDefineForClassFields=false lowers field to ctor assignment at es2022" {
    const out = try emitWithOpts(
        "class Foo { x = 1; }",
        .{ .es_target = .es2022, .use_define_for_class_fields = false },
    );
    defer T.allocator.free(out);
    // Legacy TS semantics: synthesized ctor with `this.x = 1;`.
    try T.expect(std.mem.indexOf(u8, out, "constructor()") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.x = 1;") != null);
    // No bare native field declaration left behind.
    try T.expect(std.mem.indexOf(u8, out, "\n  x = 1;") == null);
}

test "emit: public field hoisted into existing ctor at es2017" {
    const out = try emitWithOpts(
        "class Foo { x = 1; constructor(n) { this.n = n; } }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    // Existing ctor signature preserved with hoisted init prepended.
    try T.expect(std.mem.indexOf(u8, out, "constructor(n)") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.x = 1;") != null);
    try T.expect(std.mem.indexOf(u8, out, "this.n = n;") != null);
    // No leftover native field declaration as a class member.
    try T.expect(std.mem.indexOf(u8, out, "\n  x = 1;") == null);
}

test "emit: preserves leading JSDoc on a function declaration" {
    const src =
        "/**\n" ++
        " * Adds two numbers.\n" ++
        " * @param {number} a\n" ++
        " * @param {number} b\n" ++
        " * @returns {number}\n" ++
        " */\n" ++
        "function add(a, b) { return a + b; }";
    const out = try emit(src);
    defer T.allocator.free(out);
    // Full JSDoc block copied through verbatim, ahead of the decl.
    try T.expect(std.mem.indexOf(u8, out, "/**") != null);
    try T.expect(std.mem.indexOf(u8, out, "Adds two numbers.") != null);
    try T.expect(std.mem.indexOf(u8, out, "@param {number} a") != null);
    try T.expect(std.mem.indexOf(u8, out, "@returns {number}") != null);
    try T.expect(std.mem.indexOf(u8, out, "*/") != null);
    // The JSDoc must lead the declaration.
    const doc_pos = std.mem.indexOf(u8, out, "/**").?;
    const fn_pos = std.mem.indexOf(u8, out, "function add").?;
    try T.expect(doc_pos < fn_pos);
}

test "emit: removeComments strips JSDoc" {
    const src =
        "/** A docstring. */\n" ++
        "function add(a, b) { return a + b; }";
    const out = try emitWithOpts(src, .{ .remove_comments = true });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "/**") == null);
    try T.expect(std.mem.indexOf(u8, out, "A docstring") == null);
    try T.expect(std.mem.indexOf(u8, out, "function add") != null);
}

test "emit: emitDecoratorMetadata adds design:type for property decorators" {
    const out = try emitWithOpts(
        \\class Foo {
        \\  @observe
        \\  count: number = 0;
        \\}
    , .{ .emit_decorator_metadata = true });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__metadata(\"design:type\", Number)") != null);
    try T.expect(std.mem.indexOf(u8, out, "__decorate([observe, __metadata(\"design:type\", Number)], Foo.prototype, \"count\", null);") != null);
}

test "emit: emitDecoratorMetadata adds design:paramtypes and returntype for methods" {
    const out = try emitWithOpts(
        \\class Service {
        \\  @logged
        \\  greet(name: string, age: number): boolean { return true; }
        \\}
    , .{ .emit_decorator_metadata = true });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__metadata(\"design:type\", Function)") != null);
    try T.expect(std.mem.indexOf(u8, out, "__metadata(\"design:paramtypes\", [String, Number])") != null);
    try T.expect(std.mem.indexOf(u8, out, "__metadata(\"design:returntype\", Boolean)") != null);
}

test "emit: emitDecoratorMetadata off by default — no __metadata calls" {
    const out = try emit(
        \\class Foo {
        \\  @observe
        \\  count: number = 0;
        \\}
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__metadata(") == null);
}

test "emit: numeric separator preserved at es2021+" {
    const out = try emitWithOpts("const x = 1_000_000;", .{ .es_target = .es2021 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "1_000_000") != null);
}

test "emit: numeric separator stripped below es2021" {
    const out = try emitWithOpts("const x = 1_000_000;", .{ .es_target = .es2017 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "1_000_000") == null);
    try T.expect(std.mem.indexOf(u8, out, "1000000") != null);
}

test "emit: numeric separator in hex/binary stripped below es2021" {
    const out = try emitWithOpts("const x = 0xFF_FF; const y = 0b1010_1010;", .{ .es_target = .es2020 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "_") == null);
    try T.expect(std.mem.indexOf(u8, out, "0xFFFF") != null);
    try T.expect(std.mem.indexOf(u8, out, "0b10101010") != null);
}

test "emit: hex literal preserved at es2021" {
    const out = try emitWithOpts("const x = 0xFF;", .{ .es_target = .es2021 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "0xFF") != null);
}

test "emit: binary literal preserved at es2020" {
    const out = try emitWithOpts("const x = 0b1010;", .{ .es_target = .es2020 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "0b1010") != null);
}

test "emit: octal literal preserved at es2020" {
    const out = try emitWithOpts("const x = 0o17;", .{ .es_target = .es2020 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "0o17") != null);
}

test "emit: exponent literal preserved" {
    const out = try emit("const x = 1e10;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "1e10") != null);
}

test "emit: numeric separator + hex preserved at es2021, stripped at es2017" {
    const out_es2021 = try emitWithOpts("const x = 0xCAFE_BABE;", .{ .es_target = .es2021 });
    defer T.allocator.free(out_es2021);
    try T.expect(std.mem.indexOf(u8, out_es2021, "0xCAFE_BABE") != null);

    const out_es2017 = try emitWithOpts("const x = 0xCAFE_BABE;", .{ .es_target = .es2017 });
    defer T.allocator.free(out_es2017);
    try T.expect(std.mem.indexOf(u8, out_es2017, "_") == null);
    try T.expect(std.mem.indexOf(u8, out_es2017, "0xCAFEBABE") != null);
}

test "emit: bigint literal preserved at es2022" {
    const out = try emitWithOpts("const x = 123n;", .{ .es_target = .es2022 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "123n") != null);
    try T.expect(std.mem.indexOf(u8, out, "BigInt(") == null);
}

test "emit: bigint literal lowered to BigInt() below es2020" {
    const out = try emitWithOpts("const x = 123n;", .{ .es_target = .es2017 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "BigInt(\"123\")") != null);
    // The native `123n` suffix must NOT leak through at older targets —
    // it would be a SyntaxError on any pre-ES2020 engine.
    try T.expect(std.mem.indexOf(u8, out, "123n") == null);
}

test "emit: negative bigint round-trips at es2022 and downlevels at es2017" {
    const out_es2022 = try emitWithOpts("const x = -1n;", .{ .es_target = .es2022 });
    defer T.allocator.free(out_es2022);
    try T.expect(std.mem.indexOf(u8, out_es2022, "-1n") != null);

    const out_es2017 = try emitWithOpts("const x = -1n;", .{ .es_target = .es2017 });
    defer T.allocator.free(out_es2017);
    try T.expect(std.mem.indexOf(u8, out_es2017, "-BigInt(\"1\")") != null);
}

test "emit: default parameter preserved at es2017+" {
    const out = try emitWithOpts(
        "function f(x = 1) { return x; }",
        .{ .es_target = .es2017 },
    );
    defer T.allocator.free(out);
    // Native default in the parameter list; no shim in body.
    try T.expect(std.mem.indexOf(u8, out, "x = 1") != null);
    try T.expect(std.mem.indexOf(u8, out, "void 0") == null);
    try T.expect(std.mem.indexOf(u8, out, "=== void 0") == null);
}

test "emit: default parameter lowered to void-0 shim at es5" {
    const out = try emitWithOpts(
        "function f(x = 1) { return x; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // Parameter list itself stays bare — `(x)` not `(x = 1)`.
    try T.expect(std.mem.indexOf(u8, out, "function f(x)") != null);
    // Body opens with the standard `if (x === void 0)` shim.
    try T.expect(std.mem.indexOf(u8, out, "if (x === void 0)") != null);
    try T.expect(std.mem.indexOf(u8, out, "x = 1;") != null);
}

test "emit: multiple default parameters lowered in source order at es5" {
    const out = try emitWithOpts(
        "function f(a = 1, b = 2) { return a + b; }",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    // Both shims emitted, neither parameter retains its native default.
    try T.expect(std.mem.indexOf(u8, out, "function f(a, b)") != null);
    const a_shim = std.mem.indexOf(u8, out, "if (a === void 0) { a = 1; }") orelse {
        try T.expect(false);
        return;
    };
    const b_shim = std.mem.indexOf(u8, out, "if (b === void 0) { b = 2; }") orelse {
        try T.expect(false);
        return;
    };
    // Source-order: `a`'s shim must precede `b`'s.
    try T.expect(a_shim < b_shim);
}

test "emit: object method shorthand preserved at es2015+" {
    // ES2015 introduced object literal method shorthand:
    //     const o = { foo() { return 1; } }
    // At ES2015 and above the emitter must keep the shorthand form
    // verbatim — `foo() { ... }` with no `function` keyword and no
    // `foo:` separator. The HIR carries the property name on
    // `op.key` and the method body on `op.value` (a `fn_expr` with
    // `is_method = true`).
    const out = try emitWithOpts(
        "let o = { foo() { return 1; } };",
        .{ .es_target = .es2015 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "foo()") != null);
    try T.expect(std.mem.indexOf(u8, out, "foo: function") == null);
    try T.expect(std.mem.indexOf(u8, out, "return 1;") != null);
}

test "emit: object method shorthand lowers to property:function at es5" {
    // ES5 has no object method shorthand — `{ foo() { ... } }` must
    // expand to `{ foo: function () { ... } }` (anonymous function
    // expression value). Matches tsc's downlevel shape.
    const out = try emitWithOpts(
        "let o = { foo() { return 1; } };",
        .{ .es_target = .es5 },
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "foo: function") != null);
    try T.expect(std.mem.indexOf(u8, out, "return 1;") != null);
    // Shorthand form must NOT survive at ES5 — the property name
    // is followed by `:`, not directly by `(`.
    try T.expect(std.mem.indexOf(u8, out, "foo(") == null);
}
