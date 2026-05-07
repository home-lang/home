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
    pub fn supportsNumericSeparators(self: EsTarget) bool {
        return @intFromEnum(self) >= @intFromEnum(EsTarget.es2021);
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
    /// TS 5.0+. v1 only handles class-level decorators in Stage 3
    /// mode; per-member Stage 3 emit still uses the legacy form.
    experimental_decorators: bool = true,
    /// `emitDecoratorMetadata` — when true (and `experimentalDecorators`
    /// is also true), emit `__metadata("design:type", T)`,
    /// `__metadata("design:paramtypes", [...])`, and
    /// `__metadata("design:returntype", T)` calls inside the
    /// `__decorate([...])` array for decorated members.
    emit_decorator_metadata: bool = false,
    /// `importHelpers` — when true, prepend an
    /// `import { __awaiter, __decorate, __extends, __param,
    /// __importDefault, __importStar } from "tslib";` line at the top
    /// of the file so the runtime helpers come from the `tslib`
    /// package rather than being expected as ambient globals. v0
    /// emits the full helper set unconditionally and lets the bundler
    /// tree-shake unused names.
    import_helpers: bool = false,
    /// `removeComments` — when true, strip JSDoc `/** … */` comments
    /// from the output. When false (default), JSDoc comments that
    /// appear immediately before a top-level declaration in the
    /// source are copied through to the emitted JS so documentation
    /// generators (TypeDoc, JSDoc) keep working on the JS output.
    /// Source bytes must be attached via `Printer.setSource` for
    /// pass-through to take effect.
    remove_comments: bool = false,
};

const source_map_mod = @import("source_map.zig");

pub const Printer = struct {
    gpa: std.mem.Allocator,
    hir: *const Hir,
    interner: *const string_interner.Interner,
    out: std.ArrayListUnmanaged(u8),
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
        };
    }

    /// Attach source bytes for span->line/col lookups. Optional —
    /// only needed when `options.source_map` is set.
    pub fn setSource(self: *Printer, source: []const u8) void {
        self.source = source;
    }

    pub fn deinit(self: *Printer) void {
        self.out.deinit(self.gpa);
    }

    pub fn toOwnedSlice(self: *Printer) ![]u8 {
        return self.out.toOwnedSlice(self.gpa);
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
            try self.write("import { __awaiter, __decorate, __extends, __metadata, __param, __importDefault, __importStar } from \"tslib\";");
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
                    try self.printStatement(stmts[j]);
                    try self.write(self.options.newline);
                    try self.emitClassDecorateCall(stmts[i..j], stmts[j]);
                    i = j;
                    continue;
                }
            }
            if (i > 0) try self.write(self.options.newline);
            try self.emitLeadingJsDoc(stmt);
            try self.printStatement(stmt);
        }
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
    ///     to keep the v1 transform local. Per-member decorators
    ///     still go through the legacy `__decorate` walk.
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
            try self.write("__esDecorate(null, null, [");
            for (decorators, 0..) |d, i| {
                if (i > 0) try self.write(", ");
                const dp = hir_mod.decoratorOf(self.hir, d);
                try self.printExpression(dp.expression);
            }
            try self.write("], { kind: \"class\", name: \"");
            try self.printExpression(c.name);
            try self.write("\" }, null, []);");
        }
    }

    fn printStatement(self: *Printer, node: NodeId) anyerror!void {
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
            .enum_decl => try self.printEnum(node),
            .namespace_decl => try self.printNamespace(node),
            .import_decl => try self.printImport(node),
            .export_decl => try self.printExport(node),
            // Expression statement.
            else => {
                try self.printExpression(node);
                try self.writeSemi();
            },
        }
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
        const kw: []const u8 = switch (kind) {
            .var_decl => "var",
            .let_decl => "let",
            .const_decl => "const",
            else => unreachable,
        };
        try self.write(kw);
        try self.write(" ");
        const v = hir_mod.varDeclOf(self.hir, node);
        if (v.name != hir_mod.none_node_id) try self.printExpression(v.name);
        // Type annotation erases at runtime.
        if (v.init != hir_mod.none_node_id) {
            try self.write(" = ");
            try self.printExpression(v.init);
        }
        try self.writeSemi();
    }

    fn printBlock(self: *Printer, node: NodeId) !void {
        try self.write("{");
        const stmts = hir_mod.blockStmts(self.hir, node);
        if (stmts.len == 0) {
            try self.write("}");
            return;
        }
        self.depth += 1;
        for (stmts) |stmt| {
            try self.write(self.options.newline);
            try self.printStatement(stmt);
        }
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
            .return_stmt => try self.printReturn(node),
            .break_stmt => try self.printBreakOrContinue(node, "break"),
            .continue_stmt => try self.printBreakOrContinue(node, "continue"),
            .throw_stmt => try self.printThrow(node),
            else => {
                try self.printExpression(node);
                try self.writeSemi();
            },
        }
    }

    fn printWhile(self: *Printer, node: NodeId) !void {
        const p = hir_mod.whileOf(self.hir, node);
        try self.write("while (");
        try self.printExpression(p.cond);
        try self.write(") ");
        try self.printStatementInline(p.body);
    }

    fn printDoWhile(self: *Printer, node: NodeId) !void {
        const p = hir_mod.doWhileOf(self.hir, node);
        try self.write("do ");
        try self.printStatementInline(p.body);
        try self.write(" while (");
        try self.printExpression(p.cond);
        try self.write(")");
        try self.writeSemi();
    }

    fn printFor(self: *Printer, node: NodeId) !void {
        const p = hir_mod.forStmtOf(self.hir, node);
        try self.write("for (");
        if (p.init != hir_mod.none_node_id) try self.printExpression(p.init);
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
        const p = hir_mod.forInOf(self.hir, node);
        // §4.A.3 — `for-of` lowers to indexed `for` at ES5.
        // Conservative: assume the source is array-shaped. Iterator-
        // protocol fallback would need an `__values` helper +
        // try/finally; that's a Phase 4 follow-up.
        if (self.hir.kindOf(node) == .for_of_stmt and self.options.es_target == .es5) {
            try self.write("for (var _i = 0, _arr = ");
            try self.printExpression(p.source);
            try self.write("; _i < _arr.length; _i++) { ");
            try self.printForOfBindingDecl(p.target);
            try self.write(" = _arr[_i]; ");
            try self.printForOfBody(p.body);
            try self.write(" }");
            return;
        }
        const kw = if (self.hir.kindOf(node) == .for_in_stmt) "in" else "of";
        if (self.hir.kindOf(node) == .for_of_stmt and p.is_await) {
            try self.write("for await (");
        } else {
            try self.write("for (");
        }
        try self.printExpression(p.target);
        try self.write(" ");
        try self.write(kw);
        try self.write(" ");
        try self.printExpression(p.source);
        try self.write(") ");
        try self.printStatementInline(p.body);
    }

    /// Emit the binding decl line for a downleveled `for-of`. The
    /// target is a `let_decl`/`const_decl`/`var_decl`/identifier;
    /// strip the initializer (we'll assign per-iteration) and emit
    /// just the keyword + name.
    fn printForOfBindingDecl(self: *Printer, target: NodeId) anyerror!void {
        const k = self.hir.kindOf(target);
        if (k == .let_decl or k == .const_decl or k == .var_decl) {
            const v = hir_mod.varDeclOf(self.hir, target);
            const kw_str: []const u8 = switch (k) {
                .let_decl => "var ", // var binds for ES5 compatibility
                .const_decl => "var ",
                .var_decl => "var ",
                else => "var ",
            };
            try self.write(kw_str);
            if (v.name != hir_mod.none_node_id) try self.printExpression(v.name);
        } else {
            try self.printExpression(target);
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

    fn printReturn(self: *Printer, node: NodeId) !void {
        try self.write("return");
        const r = hir_mod.returnOf(self.hir, node);
        if (r.value != hir_mod.none_node_id) {
            try self.write(" ");
            try self.printExpression(r.value);
        }
        try self.writeSemi();
    }

    fn printBreakOrContinue(self: *Printer, node: NodeId, kw: []const u8) !void {
        try self.write(kw);
        const lab = hir_mod.labelOf(self.hir, node);
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
                try self.write(" (");
                try self.printExpression(p.catch_param);
                try self.write(")");
            }
            try self.write(" ");
            try self.printStatementInline(p.catch_block);
        }
        if (p.finally_block != hir_mod.none_node_id) {
            try self.write(" finally ");
            try self.printStatementInline(p.finally_block);
        }
    }

    fn printSwitch(self: *Printer, node: NodeId) !void {
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
        if (f.flags.is_arrow) {
            // §4.A.1 — at ES5, arrows downlevel to plain `function`
            // expressions. The lexical-`this` capture is approximated
            // by `(this)`-binding via `.bind(this)` at the call site —
            // tsc inserts a `_this = this;` enclosing-scope variable
            // and rewrites references in the body. We use the
            // simpler `function () { ... }.bind(this)` shape; it has
            // the same observable behavior modulo `prototype`.
            if (self.options.es_target == .es5) {
                if (f.flags.is_async) try self.write("async ");
                try self.write("function (");
                const params = hir_mod.fnParams(self.hir, node);
                try self.printRuntimeParams(params);
                try self.write(") { ");
                // §4.A — inject `if (x === void 0) { x = ...; }` shims
                // for any default-parameter, before the user body.
                if (self.hasDefaultParam(params)) {
                    try self.writeDefaultParamShims(params);
                    try self.write(" ");
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
                try self.write(" }.bind(this)");
                return;
            }
            if (f.flags.is_async) try self.write("async ");
            try self.write("(");
            const params = hir_mod.fnParams(self.hir, node);
            try self.printRuntimeParams(params);
            try self.write(") => ");
            if (f.body != hir_mod.none_node_id) {
                if (self.hir.kindOf(f.body) == .block_stmt) {
                    try self.printBlock(f.body);
                } else {
                    try self.printExpression(f.body);
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
        const downlevel_async = f.flags.is_async and !self.options.es_target.supportsNativeAsync();
        if (!f.flags.is_method and !f.flags.is_constructor) {
            if (f.flags.is_async and !downlevel_async) try self.write("async ");
            try self.write("function");
            if (f.flags.is_generator) try self.write("*");
            if (f.name != hir_mod.none_node_id) {
                try self.write(" ");
                try self.printExpression(f.name);
            }
        } else if (f.flags.is_constructor) {
            try self.write("constructor");
        } else if (f.flags.is_method) {
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
            if (downlevel_async) {
                try self.printAsyncDownlevelBody(f.body);
            } else if (self.options.es_target == .es5 and self.hasDefaultParam(params)) {
                // §4.A — at ES5, lower default-parameter syntax to a
                // body-prefix `if (x === void 0) { x = ...; }` shim.
                try self.printFnBodyWithDefaults(params, f.body);
            } else {
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
    fn printAsyncDownlevelBody(self: *Printer, body: NodeId) anyerror!void {
        try self.write("{");
        self.depth += 1;
        try self.writeNewlineIndent();
        try self.write("return __awaiter(this, void 0, void 0, function* () ");
        const prev = self.in_async_downlevel;
        self.in_async_downlevel = true;
        defer self.in_async_downlevel = prev;
        if (self.hir.kindOf(body) == .block_stmt) {
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

    fn printParameter(self: *Printer, node: NodeId) !void {
        const p = hir_mod.parameterOf(self.hir, node);
        if (p.flags.is_rest) try self.write("...");
        if (p.name != hir_mod.none_node_id) try self.printExpression(p.name);
        if (p.default_value != hir_mod.none_node_id) {
            try self.write(" = ");
            try self.printExpression(p.default_value);
        }
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
        for (params) |p| {
            if (self.isThisParam(p)) continue;
            if (!first) try self.write(", ");
            try self.printParameter(p);
            first = false;
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
        // matching tsc's downlevel shape.
        const downlevel_fields = !self.options.es_target.supportsNativeClassFields() and
            self.classHasPublicFieldInit(node);
        try self.write("class");
        if (c.name != hir_mod.none_node_id) {
            try self.write(" ");
            try self.printExpression(c.name);
        }
        if (c.extends != hir_mod.none_node_id) {
            try self.write(" extends ");
            try self.printExpression(c.extends);
        }
        try self.write(" {");
        if (members.len == 0) {
            try self.write("}");
            return;
        }
        // Track lexical class so `printMember` can rewrite `this.#x`
        // accesses inside the body.
        const prev_class = self.current_class_name;
        if (downlevel_private) self.current_class_name = hir_mod.identifierOf(self.hir, c.name).name;
        defer self.current_class_name = prev_class;
        self.depth += 1;
        // Locate an explicit constructor (if any) for downlevel
        // field hoisting. If none exists and we have fields to hoist,
        // synthesize one as the first emitted member.
        var ctor_idx: ?usize = null;
        if (downlevel_fields) {
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
            // Private fields are stored in the per-class WeakMap;
            // skip the in-class field declaration entirely.
            // TODO: when there's an initializer, inject
            //   `_Class_x.set(this, <init>);` into a constructor body
            //   (synthesizing one if absent). Today the initializer is
            //   silently dropped — callers must initialize via a
            //   method/setter for now.
            if (downlevel_private and self.hir.kindOf(m) == .object_property) {
                const op = hir_mod.objectPropertyOf(self.hir, m);
                if (self.privateFieldName(op.key) != null) continue;
            }
            // Public field with an initializer at sub-ES2022 — has
            // already been hoisted into the (real or synthesized) ctor.
            if (downlevel_fields and self.hir.kindOf(m) == .object_property) {
                const op = hir_mod.objectPropertyOf(self.hir, m);
                if (op.value != hir_mod.none_node_id and
                    self.privateFieldName(op.key) == null)
                {
                    continue;
                }
            }
            try self.write(self.options.newline);
            try self.indent();
            switch (self.hir.kindOf(m)) {
                .fn_decl, .fn_expr, .arrow_fn => {
                    if (downlevel_fields and ctor_idx != null and ctor_idx.? == i) {
                        try self.printCtorWithHoistedFields(node, m);
                    } else {
                        try self.printFnDecl(m);
                    }
                },
                .object_property => {
                    const op = hir_mod.objectPropertyOf(self.hir, m);
                    try self.printExpression(op.key);
                    if (op.value != hir_mod.none_node_id) {
                        try self.write(" = ");
                        try self.printExpression(op.value);
                    }
                    try self.writeSemi();
                },
                else => {},
            }
        }
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("}");
        // §4.A.8 — emit `__decorate` calls for each decorated member.
        try self.emitMethodDecorateCalls(node);
    }

    /// True if the class has at least one non-private `object_property`
    /// member with an initializer. Used to decide whether downlevel
    /// field-hoisting is needed.
    fn classHasPublicFieldInit(self: *Printer, class_node: NodeId) bool {
        const members = hir_mod.classMembers(self.hir, class_node);
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (op.value == hir_mod.none_node_id) continue;
            if (self.privateFieldName(op.key) != null) continue;
            return true;
        }
        return false;
    }

    /// Emit `this.<key> = <init>; ` for every public field with an
    /// initializer on this class. Caller is responsible for being
    /// inside a constructor body and writing surrounding indentation.
    fn writeHoistedFieldInits(self: *Printer, class_node: NodeId) !void {
        const members = hir_mod.classMembers(self.hir, class_node);
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (op.value == hir_mod.none_node_id) continue;
            if (self.privateFieldName(op.key) != null) continue;
            try self.write("this.");
            try self.printExpression(op.key);
            try self.write(" = ");
            try self.printExpression(op.value);
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
    /// a method or property, emit a post-class `__decorate(...)` call.
    /// Class-level decorators are handled by the existing
    /// `emitClassDecorateCall` from the source-file walker.
    fn emitMethodDecorateCalls(self: *Printer, class_node: NodeId) anyerror!void {
        const c = hir_mod.classOf(self.hir, class_node);
        if (c.name == hir_mod.none_node_id) return;
        const members = hir_mod.classMembers(self.hir, class_node);
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
            try self.write(self.options.newline);
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
            try self.write(".prototype, \"");
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
                    try self.write(".prototype, \"");
                    if (self.hir.kindOf(name_node) == .identifier) {
                        const fid = hir_mod.identifierOf(self.hir, name_node);
                        try self.write(self.interner.get(fid.name));
                    }
                    try self.write("\", null);");
                }
            }
            i = j;
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
            if (std.mem.eql(u8, name, "string")) { try self.write("String"); return; }
            if (std.mem.eql(u8, name, "number")) { try self.write("Number"); return; }
            if (std.mem.eql(u8, name, "boolean")) { try self.write("Boolean"); return; }
            if (std.mem.eql(u8, name, "bigint")) { try self.write("BigInt"); return; }
            if (std.mem.eql(u8, name, "symbol")) { try self.write("Symbol"); return; }
            if (std.mem.eql(u8, name, "void") or
                std.mem.eql(u8, name, "undefined") or
                std.mem.eql(u8, name, "null") or
                std.mem.eql(u8, name, "never"))
            {
                try self.write("void 0");
                return;
            }
            if (std.mem.eql(u8, name, "Function")) { try self.write("Function"); return; }
            if (std.mem.eql(u8, name, "Array")) { try self.write("Array"); return; }
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
        if (k == .array_type or k == .tuple_type) { try self.write("Array"); return; }
        if (k == .fn_type or k == .constructor_type) { try self.write("Function"); return; }
        try self.write("Object");
    }

    /// Lower a class to ES5 function-with-prototype. Pattern:
    ///   var Cls = (function(_super) {
    ///     __extends(Cls, _super);  // when extends is set
    ///     function Cls(args) { _super.call(this, ...); /* ctor body */ }
    ///     Cls.prototype.method = function () { /* ... */ };
    ///     return Cls;
    ///   })(SuperClass);
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
        // Synthesize `_super.call(this)` only when there is no
        // explicit constructor — an explicit ctor body already
        // contains a `super(...)` call which will be lowered to
        // `_super.call(this, ...)` by `printCall`.
        if (has_extends and ctor == null) {
            try self.write("_super.call(this); ");
        }
        // Class fields with initializers go inside the ctor body.
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
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
            try self.printExpression(c.name);
            try self.write(".prototype.");
            try self.printExpression(fd.name);
            try self.write(" = function (");
            const params = hir_mod.fnParams(self.hir, m);
            try self.printRuntimeParams(params);
            try self.write(") ");
            if (fd.body != hir_mod.none_node_id) {
                try self.printStatementInline(fd.body);
            } else {
                try self.write("{}");
            }
            try self.write("; ");
        }
        try self.write("return ");
        try self.printExpression(c.name);
        try self.write("; })(");
        if (c.extends != hir_mod.none_node_id) try self.printExpression(c.extends);
        try self.write(");");
    }

    fn printEnum(self: *Printer, node: NodeId) !void {
        // tsc lowers enum to an IIFE. We emit a placeholder; full
        // semantic emit (string vs. number, const-enum inlining) is a
        // Phase 4 follow-up.
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
            try self.write(self.options.newline);
            try self.indent();
            const op = hir_mod.objectPropertyOf(self.hir, m);
            try self.printExpression(e.name);
            try self.write("[");
            try self.printExpression(e.name);
            try self.write("[");
            try self.printExpression(op.key);
            try self.write("]] = ");
            if (op.value != hir_mod.none_node_id) {
                try self.printExpression(op.value);
            } else {
                var buf: [32]u8 = undefined;
                const w = std.fmt.bufPrint(&buf, "{d}", .{auto}) catch "0";
                try self.write(w);
            }
            try self.writeSemi();
            auto += 1;
        }
        self.depth -= 1;
        try self.writeNewlineIndent();
        try self.write("})(");
        try self.printExpression(e.name);
        try self.write(" || (");
        try self.printExpression(e.name);
        try self.write(" = {}));");
    }

    fn printNamespace(self: *Printer, node: NodeId) !void {
        const n = hir_mod.namespaceOf(self.hir, node);
        try self.write("var ");
        try self.printExpression(n.name);
        try self.write(";");
        try self.writeNewlineIndent();
        try self.write("(function (");
        try self.printExpression(n.name);
        try self.write(") {");
        const body = hir_mod.namespaceBody(self.hir, node);
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
    }

    fn printImport(self: *Printer, node: NodeId) !void {
        const imp = hir_mod.importOf(self.hir, node);
        // Type-only imports erase entirely.
        if (imp.is_type_only) return;
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

    fn printExpression(self: *Printer, node: NodeId) anyerror!void {
        const kind = self.hir.kindOf(node);
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
            .binary_op => try self.printBinop(node),
            .unary_op => try self.printUnary(node),
            .logical_op => try self.printLogical(node),
            .conditional => try self.printConditional(node),
            .assignment => try self.printAssignment(node),
            .call_expr => try self.printCall(node),
            .new_expr => try self.printNew(node),
            .as_expr, .satisfies_expr, .type_assertion, .non_null_expr => {
                // Type assertions and `expr!` non-null assertions
                // erase at runtime — print the inner expression only.
                const a = hir_mod.asExpressionOf(self.hir, node);
                try self.printExpression(a.expr);
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
                    try self.write("await ");
                }
                try self.printExpression(a.expr);
            },
            .yield_expr => {
                const y = hir_mod.yieldExprOf(self.hir, node);
                try self.write("yield");
                if (y.type_node != hir_mod.none_node_id) try self.write("*");
                if (y.expr != hir_mod.none_node_id) {
                    try self.write(" ");
                    try self.printExpression(y.expr);
                }
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
        const v = hir_mod.literalNumberOf(self.hir, node);
        var buf: [32]u8 = undefined;
        const fmt = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "NaN";
        try self.write(fmt);
    }

    fn printBinop(self: *Printer, node: NodeId) !void {
        const p = hir_mod.binopOf(self.hir, node);
        try self.write("(");
        try self.printExpression(p.lhs);
        try self.write(" ");
        try self.write(binOpString(p.op));
        try self.write(" ");
        try self.printExpression(p.rhs);
        try self.write(")");
    }

    fn printUnary(self: *Printer, node: NodeId) !void {
        const p = hir_mod.unaryOf(self.hir, node);
        const op_str = unaryOpString(p.op);
        // `typeof`/`void`/`delete` need a space before the operand.
        const needs_space = (p.op == .typeof or p.op == .void_ or p.op == .delete);
        try self.write(op_str);
        if (needs_space) try self.write(" ");
        try self.printExpression(p.operand);
    }

    fn printLogical(self: *Printer, node: NodeId) !void {
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
        try self.write("(");
        try self.printExpression(p.lhs);
        try self.write(" ");
        try self.write(switch (p.op) {
            .@"and" => "&&",
            .@"or" => "||",
            .nullish => "??",
        });
        try self.write(" ");
        try self.printExpression(p.rhs);
        try self.write(")");
    }

    fn printConditional(self: *Printer, node: NodeId) !void {
        const p = hir_mod.conditionalOf(self.hir, node);
        try self.write("(");
        try self.printExpression(p.cond);
        try self.write(" ? ");
        try self.printExpression(p.then_branch);
        try self.write(" : ");
        try self.printExpression(p.else_branch);
        try self.write(")");
    }

    fn printAssignment(self: *Printer, node: NodeId) !void {
        const p = hir_mod.assignmentOf(self.hir, node);
        try self.printExpression(p.target);
        try self.write(if (p.op != null) compoundOpString(p.op.?) else " = ");
        try self.printExpression(p.value);
    }

    fn printCall(self: *Printer, node: NodeId) !void {
        const p = hir_mod.callOf(self.hir, node);
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
        try self.printExpression(p.callee);
        try self.write("(");
        const args = hir_mod.callArgs(self.hir, node);
        for (args, 0..) |a, i| {
            if (i > 0) try self.write(", ");
            try self.printExpression(a);
        }
        try self.write(")");
    }

    fn printNew(self: *Printer, node: NodeId) !void {
        const p = hir_mod.callOf(self.hir, node);
        try self.write("new ");
        try self.printExpression(p.callee);
        try self.write("(");
        const args = hir_mod.callArgs(self.hir, node);
        for (args, 0..) |a, i| {
            if (i > 0) try self.write(", ");
            try self.printExpression(a);
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
        try self.printExpression(p.object);
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
        try self.printExpression(p.object);
        try self.write(if (p.optional) "?.[" else "[");
        try self.printExpression(p.index);
        try self.write("]");
    }

    fn printArrayLiteral(self: *Printer, node: NodeId) !void {
        const elements = hir_mod.arrayLiteralElements(self.hir, node);
        // §4.A — array spread `[...a]` is an ES2015 feature. Below
        // that we lower a pure single-spread `[...a]` to `a.slice()`,
        // matching tsc's downlevel shape. Mixed/multi-spread cases
        // (e.g. `[...a, b]`, `[...a, ...b]`) and call-site spread
        // (`f(...args)` → `f.apply(null, args)`) are not yet lowered
        // and fall through to native-syntax emission for now.
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
        try self.write("[");
        for (elements, 0..) |e, i| {
            if (i > 0) try self.write(", ");
            if (e == hir_mod.none_node_id) {
                // hole
            } else if (self.hir.kindOf(e) == .spread) {
                const sp = hir_mod.spreadOf(self.hir, e);
                try self.write("...");
                try self.printExpression(sp.expression);
            } else {
                try self.printExpression(e);
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
        try self.write("{ ");
        for (props, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            if (self.hir.kindOf(p) != .object_property) {
                try self.printExpression(p);
                continue;
            }
            const op = hir_mod.objectPropertyOf(self.hir, p);
            if (op.is_shorthand) {
                try self.printExpression(op.key);
            } else if (op.is_method) {
                try self.printFnDecl(op.value);
            } else {
                if (op.is_computed) {
                    try self.write("[");
                    try self.printExpression(op.key);
                    try self.write("]");
                } else {
                    try self.printExpression(op.key);
                }
                try self.write(": ");
                try self.printExpression(op.value);
            }
        }
        try self.write(" }");
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
    // Always-parenthesized binop emit (Phase 4.1 baseline) yields the
    // grouped form. Phase 4 follow-up: precedence-aware paren elision.
    try T.expectEqualStrings("(1 + (2 * 3));", out);
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
    try T.expect(std.mem.indexOf(u8, out, "return (a + b);") != null);
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

test "emit: for-await-of emits 'for await'" {
    const out = try emitWithOpts("for await (const v of items) { use(v); }", .{ .es_target = .es2015 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "for await (") != null);
    try T.expect(std.mem.indexOf(u8, out, " of items") != null);
}

test "emit: for-in is unaffected by es_target" {
    const out = try emitWithOpts("for (let k in obj) { let v = k; }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, " in ") != null);
}

test "emit: class downlevels to function-with-prototype at es5" {
    const out = try emitWithOpts("class Foo { greet() { return 1; } }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "var Foo") != null);
    try T.expect(std.mem.indexOf(u8, out, "function Foo(") != null);
    try T.expect(std.mem.indexOf(u8, out, "Foo.prototype.greet") != null);
    try T.expect(std.mem.indexOf(u8, out, "class ") == null);
}

test "emit: class with extends emits __extends + super.call at es5" {
    const out = try emitWithOpts("class B extends A { }", .{ .es_target = .es5 });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__extends(B, _super)") != null);
    try T.expect(std.mem.indexOf(u8, out, "_super.call(this)") != null);
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
    try T.expect(std.mem.indexOf(u8, out, "_super.call(this)") != null);
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
    try T.expect(std.mem.indexOf(u8, out, "import { __awaiter, __decorate, __extends, __metadata, __param, __importDefault, __importStar } from \"tslib\";") != null);
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
    try T.expectEqualStrings("(a && b);", out);
}

test "emit: ternary" {
    const out = try emit("a ? 1 : 2;");
    defer T.allocator.free(out);
    try T.expectEqualStrings("(a ? 1 : 2);", out);
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
    try T.expect(std.mem.indexOf(u8, out, "(x) => (x + 1)") != null);
}

test "emit: arrow block body" {
    const out = try emit("let f = (x) => { return x; };");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "(x) => {") != null);
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

test "emit: stage 3 class decorator emits __esDecorate helper" {
    const out = try emitWithOpts("@logged class Foo {}", .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "class Foo") != null);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, null, [logged], { kind: \"class\", name: \"Foo\" }, null, []);") != null);
    // Stage 3 must NOT emit the legacy `__decorate` form.
    try T.expect(std.mem.indexOf(u8, out, "= __decorate(") == null);
}

test "emit: stage 3 multiple class decorators preserve order" {
    const out = try emitWithOpts("@a @b @c class Bar {}", .{ .experimental_decorators = false });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "__esDecorate(null, null, [a, b, c], { kind: \"class\", name: \"Bar\" }, null, []);") != null);
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
