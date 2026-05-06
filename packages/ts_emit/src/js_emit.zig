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
    /// 17+ automatic runtime.
    jsx_runtime: JsxRuntime = .classic,
    /// Custom factory name for classic mode (defaults to `React`).
    jsx_factory: []const u8 = "React",
    /// Custom fragment for classic mode (defaults to `React.Fragment`).
    jsx_fragment: []const u8 = "React.Fragment",
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
                    try self.printStatement(stmts[j]);
                    try self.write(self.options.newline);
                    try self.emitClassDecorateCall(stmts[i..j], stmts[j]);
                    i = j;
                    continue;
                }
            }
            if (i > 0) try self.write(self.options.newline);
            try self.printStatement(stmt);
        }
        // Optional source-map URL trailer.
        if (self.options.source_map_url) |url| {
            try self.write(self.options.newline);
            try self.write("//# sourceMappingURL=");
            try self.write(url);
            try self.write(self.options.newline);
        }
    }

    /// Emit `<Name> = __decorate([dec1, dec2, ...], <Name>);` after
    /// a class declaration that had decorators attached.
    fn emitClassDecorateCall(self: *Printer, decorators: []const NodeId, class_node: NodeId) anyerror!void {
        const c = hir_mod.classOf(self.hir, class_node);
        if (c.name == hir_mod.none_node_id) return;
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
        try self.write("for (");
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
                for (params, 0..) |p, i| {
                    if (i > 0) try self.write(", ");
                    try self.printParameter(p);
                }
                try self.write(") { ");
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
            for (params, 0..) |p, i| {
                if (i > 0) try self.write(", ");
                try self.printParameter(p);
            }
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
        if (!f.flags.is_method and !f.flags.is_constructor) {
            if (f.flags.is_async) try self.write("async ");
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
        for (params, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            try self.printParameter(p);
        }
        try self.write(")");
        if (f.body != hir_mod.none_node_id) {
            try self.write(" ");
            try self.printStatementInline(f.body);
        } else {
            try self.writeSemi();
        }
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

    fn printClassDecl(self: *Printer, node: NodeId) !void {
        // §4.A.2 — at ES5, lower class to function-with-prototype.
        if (self.options.es_target == .es5) {
            try self.printClassDeclEs5(node);
            return;
        }
        const c = hir_mod.classOf(self.hir, node);
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
        const members = hir_mod.classMembers(self.hir, node);
        if (members.len == 0) {
            try self.write("}");
            return;
        }
        self.depth += 1;
        var i: usize = 0;
        while (i < members.len) : (i += 1) {
            const m = members[i];
            // Decorators are members whose kind is `.decorator`.
            // They're emitted as preceding siblings of the actual
            // member; we skip them in the in-class output and
            // collect them for the post-class __decorate calls.
            if (self.hir.kindOf(m) == .decorator) continue;
            try self.write(self.options.newline);
            try self.indent();
            switch (self.hir.kindOf(m)) {
                .fn_decl, .fn_expr, .arrow_fn => try self.printFnDecl(m),
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
        try self.write("var ");
        try self.printExpression(c.name);
        try self.write(" = (function (");
        if (c.extends != hir_mod.none_node_id) try self.write("_super");
        try self.write(") { ");
        if (c.extends != hir_mod.none_node_id) {
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
            for (params, 0..) |p, i| {
                if (i > 0) try self.write(", ");
                try self.printParameter(p);
            }
        }
        try self.write(") { ");
        if (c.extends != hir_mod.none_node_id) {
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
            for (params, 0..) |p, i| {
                if (i > 0) try self.write(", ");
                try self.printParameter(p);
            }
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
        // `export { a, b as c }` → `module.exports.a = a; module.exports.c = b;`.
        const named = hir_mod.exportNamed(self.hir, node);
        const re_export_module = self.interner.get(ex.module);
        if (re_export_module.len > 0) {
            // `export { a } from "x"` → `({ a } = require("x")); module.exports.a = a;`
            // Conservative: use a temporary.
            try self.write("(function() { const _re = require(\"");
            try self.write(re_export_module);
            try self.write("\"); ");
            for (named) |spec| {
                if (self.hir.kindOf(spec) != .import_specifier) continue;
                const sp = hir_mod.importSpecifierOf(self.hir, spec);
                try self.write("module.exports.");
                try self.write(self.interner.get(sp.local));
                try self.write(" = _re.");
                try self.write(self.interner.get(sp.imported));
                try self.write("; ");
            }
            try self.write("})()");
            try self.writeSemi();
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
                const v = hir_mod.literalNumberOf(self.hir, node);
                var buf: [32]u8 = undefined;
                const fmt = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "NaN";
                try self.write(fmt);
            },
            .literal_bigint => {
                const b = hir_mod.literalBigIntOf(self.hir, node);
                try self.write(self.interner.get(b.digits));
                try self.write("n");
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
                try self.write("await ");
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
    /// - `.classic`: `<factory>.createElement(tag, props, ...children)`
    /// - `.automatic`: `_jsx(tag, props)` or `_jsxs(tag, props)` (key
    ///   in props if present). Caller must arrange the import of
    ///   `_jsx` / `_jsxs` from `react/jsx-runtime`.
    /// - `.automatic_dev`: same as `.automatic` but use `_jsxDEV`.
    /// - `.preserve`: error — preserve mode is handled by the bundler,
    ///   not the streaming printer (we'd need a JSX literal in the
    ///   output stream).
    fn printJsxElement(self: *Printer, node: NodeId) anyerror!void {
        switch (self.options.jsx_runtime) {
            .classic, .preserve => try self.printJsxElementClassic(node),
            .automatic => try self.printJsxElementAutomatic(node, "_jsx", "_jsxs"),
            .automatic_dev => try self.printJsxElementAutomatic(node, "_jsxDEV", "_jsxDEV"),
        }
    }

    fn printJsxElementClassic(self: *Printer, node: NodeId) anyerror!void {
        const el = hir_mod.jsxElementOf(self.hir, node);
        try self.write(self.options.jsx_factory);
        try self.write(".createElement(");
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

    fn printJsxElementAutomatic(self: *Printer, node: NodeId, single_name: []const u8, multi_name: []const u8) anyerror!void {
        const el = hir_mod.jsxElementOf(self.hir, node);
        const children = hir_mod.jsxChildren(self.hir, node);
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
            .classic, .preserve => {
                try self.write(self.options.jsx_factory);
                try self.write(".createElement(");
                try self.write(self.options.jsx_fragment);
                try self.write(", null");
                const children = hir_mod.jsxFragmentChildren(self.hir, node);
                for (children) |c| {
                    try self.write(", ");
                    try self.printExpression(c);
                }
                try self.write(")");
            },
            .automatic, .automatic_dev => {
                const fn_name: []const u8 = if (self.options.jsx_runtime == .automatic_dev) "_jsxDEV" else "_jsxs";
                try self.write(fn_name);
                try self.write("(_Fragment, { children: [");
                const children = hir_mod.jsxFragmentChildren(self.hir, node);
                for (children, 0..) |c, i| {
                    if (i > 0) try self.write(", ");
                    try self.printExpression(c);
                }
                try self.write("] })");
            },
        }
    }

    fn printJsxExpression(self: *Printer, node: NodeId) anyerror!void {
        const ex = hir_mod.jsxExpressionOf(self.hir, node);
        if (ex.expression == hir_mod.none_node_id) {
            try self.write("null");
        } else {
            try self.printExpression(ex.expression);
        }
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
        try self.write("[");
        for (elements, 0..) |e, i| {
            if (i > 0) try self.write(", ");
            if (e == hir_mod.none_node_id) {
                // hole
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
    try s.printer.printSourceFile(s.root);
    return T.allocator.dupe(u8, s.printer.out.items);
}

test "emit: jsx classic produces React.createElement" {
    const out = try emitJsx("let v = <Foo />;", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "React.createElement(Foo, null)") != null);
}

test "emit: jsx classic with custom factory" {
    const out = try emitJsx("let v = <Foo />;", .{ .jsx_factory = "h" });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "h.createElement(Foo, null)") != null);
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
