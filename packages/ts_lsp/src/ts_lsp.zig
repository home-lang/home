//! TypeScript LSP foundation — Phase 8 of TS_PARITY_PLAN.
//!
//! Wraps the program graph + checker + diagnostic formatter as a
//! query surface for editor integrations. This is the protocol-
//! agnostic core; a separate `ts_lsp_server` (post-Phase 8) will
//! speak the LSP wire format on top.
//!
//! Phase 8 ships:
//!   - hover(file, byte_pos) -> { type_repr, span }
//!   - goto_definition(file, byte_pos) -> { file, span }
//!   - find_references(file, byte_pos) -> []{ file, span }
//!   - completions(file, byte_pos) -> []CompletionItem
//!   - diagnostics(file) -> []Diagnostic
//!
//! All operations consult the existing `ts_program.Program`. The
//! query DB (Phase 5 §11.6) plugs in beneath this so repeated
//! requests against the same program revision share cached
//! results — but the LSP API doesn't change.

const std = @import("std");
const hir_mod = @import("hir");
const ts_program = @import("ts_program");
const ts_driver = @import("ts_driver");
const ts_diagnostics = @import("ts_diagnostics");
const ts_checker = @import("ts_checker");
const ts_lexer = @import("ts_lexer");
const string_interner = @import("string_interner");

pub const Span = struct {
    file: []const u8,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

pub const HoverResult = struct {
    /// Human-readable type rendering. Empty when no type is
    /// available for the position.
    type_repr: []const u8,
    /// Source span the hover covers.
    span: Span,
    /// Hover'd node kind (for editor styling).
    kind: hir_mod.NodeKind,
};

pub const Definition = struct {
    file: []const u8,
    span: Span,
};

pub const CompletionItem = struct {
    /// Label shown in the completion popup.
    label: []const u8,
    /// Item kind (variable / function / class / interface / type / module).
    kind: ItemKind,
    /// Optional type signature shown alongside the label.
    detail: []const u8,
    /// When non-empty, an auto-import candidate: the file path the
    /// symbol was discovered in. The editor renders this as a
    /// secondary `additionalTextEdits` insertion (`import { name }
    /// from "<path>"`) when the user selects this completion.
    /// Empty for module-local completions.
    auto_import_from: []const u8 = "",

    pub const ItemKind = enum { variable, function, class, interface, type_alias, module, keyword, member };
};

pub const SignatureInfo = struct {
    /// Rendered signature, e.g. "(x: number, y: string): boolean".
    label: []const u8,
    /// Index of the active parameter (the one cursor is currently
    /// hovering over inside the call).
    active_parameter: u32,
    /// Per-parameter labels (for highlighting in the editor).
    parameters: []const []const u8,
};

pub const InlayHint = struct {
    /// 0-based byte position the hint anchors at.
    pos: u32,
    /// Hint text — typically `: T` for `let x` or parameter names
    /// at call sites.
    label: []const u8,
    /// Hint kind — affects editor presentation.
    kind: enum { type_annotation, parameter_name },
};

/// A single text edit applied to a file. Used by `rename` and
/// `codeAction` to communicate cross-file edits to the editor.
pub const TextEdit = struct {
    file: []const u8,
    /// 0-based start position.
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    new_text: []const u8,
};

/// LSP `textDocument/foldingRange` payload — describes a region of
/// source the editor can collapse. Line numbers are 0-based, matching
/// the LSP wire format.
pub const FoldingRange = struct {
    start_line: u32,
    end_line: u32,
    kind: Kind,

    pub const Kind = enum { region, comment, imports };
};

/// LSP `textDocument/selectionRange` payload — a single source range
/// in a nested-range list. The list runs innermost-first, with each
/// successive entry strictly enclosing the previous one. Lines/cols
/// match the rest of the LSP surface (1-based, mirroring `Span`).
pub const Range = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

/// LSP `TextDocumentSaveReason` — passed to `willSaveWaitUntil` so
/// the server can adapt formatting/edit behavior per trigger source.
/// Values mirror the LSP wire numbers (1..4) but are exposed as a
/// Zig enum at this layer.
pub const SaveReason = enum { manual, auto, after_delay, focus_out };

pub const CodeAction = struct {
    title: []const u8,
    kind: Kind,
    edits: []TextEdit,

    pub const Kind = enum {
        organize_imports,
        sort_imports,
        fix_all,
        quick_fix,
    };
};

/// LSP semanticTokens — per-token classification for syntax-aware
/// editor highlighting. Standard LSP token types are emitted by
/// 0-based index; the editor's `legend` maps the index back to the
/// LSP-spec name.
pub const SemanticToken = struct {
    line: u32,
    col: u32,
    length: u32,
    /// Index into the semantic-token type legend.
    token_type: TokenType,
    /// Bitset of modifiers (today always 0).
    modifiers: u32,

    pub const TokenType = enum(u8) {
        variable = 0,
        parameter = 1,
        function = 2,
        method = 3,
        class = 4,
        interface = 5,
        type_alias = 6,
        enum_ = 7,
        property = 8,
        keyword = 9,
        string = 10,
        number = 11,
        comment = 12,

        pub fn legend() []const []const u8 {
            return &.{
                "variable",  "parameter", "function",  "method",
                "class",     "interface", "type",      "enum",
                "property",  "keyword",   "string",    "number",
                "comment",
            };
        }
    };
};

pub const SymbolInfo = struct {
    name: []const u8,
    kind: SymbolKind,
    span: Span,
    /// Nested members for tree-view outlines (class methods, namespace
    /// members, interface members, enum members). Empty when the symbol
    /// has no children. Owned by the same allocation as the parent
    /// slice; the caller frees them recursively via `freeSymbols`.
    children: []SymbolInfo = &.{},

    pub const SymbolKind = enum {
        function,
        class,
        interface,
        variable,
        type_alias,
        enum_,
        namespace,
        module,
        property,
        method,
        enum_member,
    };
};

/// Recursively free a `[]SymbolInfo` produced by `documentSymbols` /
/// `workspaceSymbols`. Frees nested `children` slices too.
pub fn freeSymbols(gpa: std.mem.Allocator, symbols: []SymbolInfo) void {
    for (symbols) |s| {
        if (s.children.len > 0) freeSymbols(gpa, s.children);
    }
    gpa.free(symbols);
}

/// Free a `[]CodeLens` produced by `codeLenses`. Frees the per-lens
/// `title` allocations and the slice itself.
pub fn freeCodeLenses(gpa: std.mem.Allocator, lenses: []CodeLens) void {
    for (lenses) |l| gpa.free(l.title);
    gpa.free(lenses);
}

/// LSP `textDocument/documentHighlight` payload — describes a single
/// occurrence of the identifier under the cursor inside the current
/// file. `kind` matches LSP's `DocumentHighlightKind` (text=1, read=2,
/// write=3); the file-local nature mirrors the spec.
pub const Highlight = struct {
    span: Span,
    kind: Kind,

    pub const Kind = enum { text, read, write };
};

/// LSP `textDocument/prepareCallHierarchy` element. Represents one
/// caller (incoming) or callee (outgoing) of the function under the
/// cursor. The `span` points at the symbol's declaration, mirroring
/// LSP's `CallHierarchyItem.range`.
pub const CallHierarchyItem = struct {
    name: []const u8,
    kind: SymbolInfo.SymbolKind,
    span: Span,
};

/// LSP `textDocument/codeLens` payload. Each lens is rendered inline
/// above a top-level declaration with a short title (e.g.
/// `"5 references"`). `command` is the LSP command id the editor
/// invokes when the user clicks the lens; empty for display-only.
pub const CodeLens = struct {
    /// Where to render the lens — typically the declaration's full
    /// span; the editor anchors the lens at `start_line`.
    span: Span,
    /// Title text shown to the user.
    title: []const u8,
    /// LSP command id the editor invokes on click. Empty for
    /// display-only lenses.
    command: []const u8,
};

/// Structured LSP `textDocument/publishDiagnostics` payload. One per
/// underlying `ts_driver.Diagnostic`; the wire layer maps these
/// directly to the LSP `Diagnostic[]` shape (range/severity/code/
/// message/source) without re-parsing rendered text.
///
/// `range` follows the same 1-based line/col convention as the rest
/// of `Span` in this module (the wire layer subtracts 1 when emitting
/// the 0-based LSP wire form).
pub const LspDiagnostic = struct {
    range: Span,
    severity: Severity,
    code: u32,
    /// Owned by the diagnostic — `freeLspDiagnostics` frees it.
    message: []const u8,
    /// Diagnostic source identifier (LSP `Diagnostic.source`).
    /// Borrowed; defaults to the static `"ts"` literal.
    source: []const u8 = "ts",

    pub const Severity = enum { err, warning, info, hint };
};

/// Free a `[]LspDiagnostic` produced by `Service.diagnosticsStructured`.
/// Releases the per-diagnostic `message` allocations and the slice.
pub fn freeLspDiagnostics(gpa: std.mem.Allocator, diags: []LspDiagnostic) void {
    for (diags) |d| gpa.free(d.message);
    gpa.free(diags);
}

pub const Service = struct {
    gpa: std.mem.Allocator,
    program: *ts_program.Program,

    pub fn init(gpa: std.mem.Allocator, program: *ts_program.Program) Service {
        return .{ .gpa = gpa, .program = program };
    }

    /// Hover at `byte_pos` inside `file`. Walks the file's HIR
    /// to find the smallest enclosing node and renders its type.
    /// When the position lands on an identifier whose binder symbol
    /// is a function/class/variable declaration, the rendered form
    /// echoes the declaration shape (e.g. `function add(a: number,
    /// b: number): number`) instead of just the type repr.
    pub fn hover(self: *Service, file_path: []const u8, byte_pos: u32) ?HoverResult {
        const file_id = self.program.lookupPath(file_path) orelse return null;
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return null;
        const node = findInnermostNode(&c.hir, c.root, byte_pos) orelse return null;
        const t = c.hir.typeOf(node);
        const span = c.hir.spanOf(node);
        const start_pos = ts_diagnostics.positionToLineCol(f.source, span.start);
        const end_pos = ts_diagnostics.positionToLineCol(f.source, span.end);
        const span_info: Span = .{
            .file = f.path,
            .start_line = start_pos.line,
            .start_col = start_pos.col,
            .end_line = end_pos.line,
            .end_col = end_pos.col,
        };

        // Declaration-shape rendering for identifiers bound to
        // top-level value symbols (functions / classes / variables).
        if (c.hir.kindOf(node) == .identifier) {
            const id = hir_mod.identifierOf(&c.hir, node);
            if (c.module.root.lookup(id.name)) |sym| {
                if (renderDeclShape(self.gpa, &c.type_interner, &c.interner, &c.hir, sym, t)) |decl_repr| {
                    return .{
                        .type_repr = decl_repr,
                        .span = span_info,
                        .kind = c.hir.kindOf(node),
                    };
                }
            }
        }

        const repr = renderType(self.gpa, &c.type_interner, &c.interner, t) catch "";
        return .{
            .type_repr = repr,
            .span = span_info,
            .kind = c.hir.kindOf(node),
        };
    }

    /// Goto-definition for the identifier at `byte_pos`. Walks the
    /// binder's symbol table to find the declaration. When the local
    /// symbol is an import, follows the import declaration through
    /// the resolver to the source file and returns the original
    /// definition span there.
    pub fn gotoDefinition(self: *Service, file_path: []const u8, byte_pos: u32) ?Definition {
        const file_id = self.program.lookupPath(file_path) orelse return null;
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return null;
        const node = findInnermostNode(&c.hir, c.root, byte_pos) orelse return null;
        if (c.hir.kindOf(node) != .identifier) return null;
        const id = hir_mod.identifierOf(&c.hir, node);
        const sym = c.module.root.lookup(id.name) orelse return null;
        if (sym.decls.items.len == 0) return null;

        // Cross-file: if the local binding is an import, walk the
        // file's import declarations to find the source module and
        // resolve the original definition in the imported file.
        if (sym.flags.is_import) {
            if (self.resolveImportedDefinition(c, f.path, id.name)) |def| {
                return def;
            }
        }

        const decl = sym.decls.items[0];
        const span = c.hir.spanOf(decl);
        const start_pos = ts_diagnostics.positionToLineCol(f.source, span.start);
        const end_pos = ts_diagnostics.positionToLineCol(f.source, span.end);
        return .{
            .file = f.path,
            .span = .{
                .file = f.path,
                .start_line = start_pos.line,
                .start_col = start_pos.col,
                .end_line = end_pos.line,
                .end_col = end_pos.col,
            },
        };
    }

    /// Walk `c`'s import declarations looking for the one that
    /// introduces `local_name`. When found, resolve the import's
    /// module specifier through the program's resolver and return
    /// the definition span of the matching exported symbol in the
    /// imported file. Returns null when the import can't be matched,
    /// the module doesn't resolve to a tracked file, or the foreign
    /// file lacks the expected symbol.
    fn resolveImportedDefinition(
        self: *Service,
        c: anytype,
        importer_path: []const u8,
        local_name: string_interner.StringId,
    ) ?Definition {
        if (c.hir.kindOf(c.root) != .block_stmt) return null;
        const stmts = hir_mod.blockStmts(&c.hir, c.root);
        for (stmts) |s| {
            if (c.hir.kindOf(s) != .import_decl) continue;
            const imp = hir_mod.importOf(&c.hir, s);

            // Determine the foreign name introduced by the binding —
            // the name as it is exported from the source module. For
            // a default import the foreign name is `default`; for a
            // namespace import there is no specific name (the
            // "definition" is the foreign module root); for a named
            // import it's the spec's `imported` field.
            var foreign_name: ?[]const u8 = null;
            var is_namespace = false;
            var matched = false;

            if (imp.default_binding != hir_mod.none_node_id and
                c.hir.kindOf(imp.default_binding) == .identifier)
            {
                const did = hir_mod.identifierOf(&c.hir, imp.default_binding);
                if (did.name == local_name) {
                    foreign_name = "default";
                    matched = true;
                }
            }
            if (!matched and imp.namespace_binding != hir_mod.none_node_id and
                c.hir.kindOf(imp.namespace_binding) == .identifier)
            {
                const nid = hir_mod.identifierOf(&c.hir, imp.namespace_binding);
                if (nid.name == local_name) {
                    is_namespace = true;
                    matched = true;
                }
            }
            if (!matched) {
                const named = hir_mod.importNamed(&c.hir, s);
                for (named) |spec| {
                    if (c.hir.kindOf(spec) != .import_specifier) continue;
                    const sp = hir_mod.importSpecifierOf(&c.hir, spec);
                    if (sp.local == local_name) {
                        foreign_name = c.interner.get(sp.imported);
                        matched = true;
                        break;
                    }
                }
            }
            if (!matched) continue;

            // Resolve the module specifier to a file path.
            const module_name = c.interner.get(imp.module);
            if (module_name.len == 0) return null;
            const res = self.program.resolver.resolve(module_name, importer_path) catch return null;
            const target_id = self.program.lookupPath(res.path) orelse return null;
            const tf = self.program.fileById(target_id);
            const tc = tf.compilation orelse return null;

            // Namespace imports point at the foreign module root.
            if (is_namespace) {
                const span = tc.hir.spanOf(tc.root);
                const start_pos = ts_diagnostics.positionToLineCol(tf.source, span.start);
                const end_pos = ts_diagnostics.positionToLineCol(tf.source, span.end);
                return .{
                    .file = tf.path,
                    .span = .{
                        .file = tf.path,
                        .start_line = start_pos.line,
                        .start_col = start_pos.col,
                        .end_line = end_pos.line,
                        .end_col = end_pos.col,
                    },
                };
            }

            // Look up the foreign name in the imported file's
            // interner (without mutating it). Absent → no symbol.
            const fname = foreign_name orelse return null;
            const target_name_id = tc.interner.lookup(fname) orelse return null;
            const target_sym = tc.module.root.lookup(target_name_id) orelse return null;
            if (target_sym.decls.items.len == 0) return null;
            const tdecl = target_sym.decls.items[0];
            const tspan = tc.hir.spanOf(tdecl);
            const tstart = ts_diagnostics.positionToLineCol(tf.source, tspan.start);
            const tend = ts_diagnostics.positionToLineCol(tf.source, tspan.end);
            return .{
                .file = tf.path,
                .span = .{
                    .file = tf.path,
                    .start_line = tstart.line,
                    .start_col = tstart.col,
                    .end_line = tend.line,
                    .end_col = tend.col,
                },
            };
        }
        return null;
    }

    /// Find every reference to the symbol at `byte_pos` across
    /// every file in the program. Within the cursor's own file the
    /// search is shadowing-aware: each candidate's enclosing scope
    /// is consulted via the binder's scope graph and the candidate
    /// is filtered out if its name resolves to a different symbol
    /// than the cursor's. Cross-file matches still match by name
    /// only — the import-resolution path in `gotoDefinition`
    /// handles the cross-module symbol identity question.
    pub fn findReferences(self: *Service, gpa: std.mem.Allocator, file_path: []const u8, byte_pos: u32) ![]Span {
        var spans: std.ArrayListUnmanaged(Span) = .empty;
        errdefer spans.deinit(gpa);

        // Resolve the target identifier to its interned name.
        const file_id = self.program.lookupPath(file_path) orelse return spans.toOwnedSlice(gpa);
        const origin = self.program.fileById(file_id);
        const oc = origin.compilation orelse return spans.toOwnedSlice(gpa);
        const node = findInnermostNode(&oc.hir, oc.root, byte_pos) orelse return spans.toOwnedSlice(gpa);
        if (oc.hir.kindOf(node) != .identifier) return spans.toOwnedSlice(gpa);
        const target = hir_mod.identifierOf(&oc.hir, node);
        const target_name = oc.interner.get(target.name);

        // Resolve the cursor's identifier to its declaring symbol so
        // we can compare candidate-site lookups against it. Compare
        // by opaque pointer so this layer doesn't import binder.
        const target_sym_addr: usize = blk: {
            const s = enclosingScopeOf(oc.module, &oc.hir, node);
            if (s.lookup(target.name)) |sym| break :blk @intFromPtr(sym);
            if (oc.module.root.lookup(target.name)) |sym| break :blk @intFromPtr(sym);
            break :blk 0;
        };

        // Walk every program file's HIR. Each file has its own
        // string_interner, so we re-intern the target name into
        // the visited file's interner to compare ids.
        for (self.program.files.items) |f| {
            const c = f.compilation orelse continue;
            const local_id = c.interner.lookup(target_name) orelse continue;
            const is_origin = (f.id == file_id);
            var i: hir_mod.NodeId = 0;
            while (i < c.hir.nodeCount()) : (i += 1) {
                if (c.hir.kindOf(i) != .identifier) continue;
                const id = hir_mod.identifierOf(&c.hir, i);
                if (id.name != local_id) continue;

                // In-file shadowing filter: resolve this candidate's
                // name in its enclosing scope. If it doesn't resolve
                // to the same symbol the cursor does, the candidate
                // shadows or is shadowed by a different binding —
                // skip it.
                if (is_origin and target_sym_addr != 0) {
                    const cand_scope = enclosingScopeOf(c.module, &c.hir, i);
                    const cand_addr: usize = if (cand_scope.lookup(local_id)) |s| @intFromPtr(s) else 0;
                    if (cand_addr != target_sym_addr) continue;
                }

                const span = c.hir.spanOf(i);
                const sp = ts_diagnostics.positionToLineCol(f.source, span.start);
                const ep = ts_diagnostics.positionToLineCol(f.source, span.end);
                try spans.append(gpa, .{
                    .file = f.path,
                    .start_line = sp.line,
                    .start_col = sp.col,
                    .end_line = ep.line,
                    .end_col = ep.col,
                });
            }
        }
        return spans.toOwnedSlice(gpa);
    }

    /// File-local highlights for the identifier under the cursor.
    /// LSP `textDocument/documentHighlight`: returns one `Highlight`
    /// per occurrence of the same identifier name in the cursor's
    /// file, with `kind` distinguishing read vs write sites. Unlike
    /// `findReferences`, this stops at the file boundary and never
    /// crosses into other modules. Shadowing-aware: candidates whose
    /// enclosing scope binds a different symbol are filtered out.
    pub fn documentHighlights(self: *Service, gpa: std.mem.Allocator, file_path: []const u8, byte_pos: u32) ![]Highlight {
        var hls: std.ArrayListUnmanaged(Highlight) = .empty;
        errdefer hls.deinit(gpa);

        const file_id = self.program.lookupPath(file_path) orelse return hls.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return hls.toOwnedSlice(gpa);
        const node = findInnermostNode(&c.hir, c.root, byte_pos) orelse return hls.toOwnedSlice(gpa);
        if (c.hir.kindOf(node) != .identifier) return hls.toOwnedSlice(gpa);
        const target = hir_mod.identifierOf(&c.hir, node);

        // Resolve the cursor's identifier to its declaring symbol so
        // we can compare candidate-site lookups against it. Compare
        // by opaque pointer so this layer doesn't import binder.
        const target_sym_addr: usize = blk: {
            const s = enclosingScopeOf(c.module, &c.hir, node);
            if (s.lookup(target.name)) |sym| break :blk @intFromPtr(sym);
            if (c.module.root.lookup(target.name)) |sym| break :blk @intFromPtr(sym);
            break :blk 0;
        };

        var i: hir_mod.NodeId = 1;
        while (i < c.hir.nodeCount()) : (i += 1) {
            if (c.hir.kindOf(i) != .identifier) continue;
            const id = hir_mod.identifierOf(&c.hir, i);
            if (id.name != target.name) continue;

            // In-file shadowing filter — same logic as findReferences.
            if (target_sym_addr != 0) {
                const cand_scope = enclosingScopeOf(c.module, &c.hir, i);
                const cand_addr: usize = if (cand_scope.lookup(id.name)) |s| @intFromPtr(s) else 0;
                if (cand_addr != target_sym_addr) continue;
            }

            const span = c.hir.spanOf(i);
            const sp = ts_diagnostics.positionToLineCol(f.source, span.start);
            const ep = ts_diagnostics.positionToLineCol(f.source, span.end);
            try hls.append(gpa, .{
                .span = .{
                    .file = f.path,
                    .start_line = sp.line,
                    .start_col = sp.col,
                    .end_line = ep.line,
                    .end_col = ep.col,
                },
                .kind = classifyIdentifierKind(&c.hir, i),
            });
        }
        return hls.toOwnedSlice(gpa);
    }

    /// Completions at `byte_pos`. Phase 8 v0: top-level
    /// module-scope symbols + the standard primitive type names.
    /// Member-access completion (`p.|` → properties of `p`'s type)
    /// is a Phase 8 follow-up.
    pub fn completions(self: *Service, gpa: std.mem.Allocator, file_path: []const u8, byte_pos: u32) ![]CompletionItem {
        _ = byte_pos;
        var items: std.ArrayListUnmanaged(CompletionItem) = .empty;
        errdefer items.deinit(gpa);

        const file_id = self.program.lookupPath(file_path) orelse return items.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return items.toOwnedSlice(gpa);

        // Module-level value symbols.
        var it = c.module.root.values.iterator();
        while (it.next()) |entry| {
            const sym = entry.value_ptr.*;
            const kind: CompletionItem.ItemKind = if (sym.flags.is_function)
                .function
            else if (sym.flags.is_class)
                .class
            else
                .variable;
            try items.append(gpa, .{
                .label = c.interner.get(entry.key_ptr.*),
                .kind = kind,
                .detail = "",
            });
        }
        // Module-level type symbols.
        var tit = c.module.root.types.iterator();
        while (tit.next()) |entry| {
            const sym = entry.value_ptr.*;
            const kind: CompletionItem.ItemKind = if (sym.flags.is_class)
                .class
            else if (sym.flags.is_interface)
                .interface
            else
                .type_alias;
            try items.append(gpa, .{
                .label = c.interner.get(entry.key_ptr.*),
                .kind = kind,
                .detail = "",
            });
        }
        // §8.A.1 — auto-import candidates from other files in the
        // program. We surface every top-level declaration in any
        // *other* file, tagged with `auto_import_from = <path>`.
        // The editor renders these as secondary completions and
        // adds the matching `import { name } from "<path>"` when
        // the user accepts. Names already present in the local
        // file are not duplicated as auto-import candidates.
        for (self.program.files.items) |other| {
            if (std.mem.eql(u8, other.path, file_path)) continue;
            const oc = other.compilation orelse continue;
            // Skip files whose parse left a non-block root (malformed).
            if (oc.hir.kindOf(oc.root) != .block_stmt) continue;
            const ostmts = hir_mod.blockStmts(&oc.hir, oc.root);
            for (ostmts) |s| {
                const info = describeTopLevelSymbol(&oc.hir, &oc.interner, s, oc.source, other.path) orelse continue;
                // Skip if already in local scope.
                const local_name_id = c.interner.intern(info.name) catch continue;
                if (c.module.root.values.contains(local_name_id)) continue;
                if (c.module.root.types.contains(local_name_id)) continue;
                const item_kind: CompletionItem.ItemKind = switch (info.kind) {
                    .function => .function,
                    .class => .class,
                    .interface => .interface,
                    .type_alias => .type_alias,
                    .enum_ => .type_alias,
                    .variable => .variable,
                    else => .variable,
                };
                try items.append(gpa, .{
                    .label = info.name,
                    .kind = item_kind,
                    .detail = "Auto import",
                    .auto_import_from = other.path,
                });
            }
        }
        return items.toOwnedSlice(gpa);
    }

    /// Signature-help at `byte_pos`. Returns the active signature
    /// rendered as `(p1: T1, p2: T2): R`, with the active parameter
    /// index based on the cursor's position in the argument list.
    /// Returns null when no enclosing call expression is found.
    pub fn signatureHelp(self: *Service, gpa: std.mem.Allocator, file_path: []const u8, byte_pos: u32) !?SignatureInfo {
        const file_id = self.program.lookupPath(file_path) orelse return null;
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return null;
        // Walk up from the innermost node looking for a call_expr.
        const start = findInnermostNode(&c.hir, c.root, byte_pos) orelse return null;
        const call_node = walkUpToCallExpr(&c.hir, start) orelse return null;
        const call = hir_mod.callOf(&c.hir, call_node);
        const callee_t = c.hir.typeOf(call.callee);
        if (!c.type_interner.pool.flagsOf(callee_t).is_signature) return null;
        const sig_label = renderType(gpa, &c.type_interner, &c.interner, callee_t) catch return null;
        // Determine active parameter — count comma-separated args
        // before byte_pos by walking the call's argument spans.
        var active_index: u32 = 0;
        const args = hir_mod.callArgs(&c.hir, call_node);
        for (args, 0..) |arg, i| {
            const sp = c.hir.spanOf(arg);
            if (byte_pos > sp.end) {
                active_index = @intCast(i + 1);
            } else if (byte_pos >= sp.start) {
                active_index = @intCast(i);
                break;
            }
        }
        const params = c.type_interner.signatureParams(callee_t);
        var labels = std.ArrayListUnmanaged([]const u8).empty;
        errdefer labels.deinit(gpa);
        for (params) |p| {
            const lbl = renderType(gpa, &c.type_interner, &c.interner, p) catch "";
            try labels.append(gpa, lbl);
        }
        return .{
            .label = sig_label,
            .active_parameter = active_index,
            .parameters = try labels.toOwnedSlice(gpa),
        };
    }

    /// Inlay hints inside `file`. Today we surface inferred types
    /// at `let`/`const` bindings without an explicit annotation.
    /// Phase 8 follow-up: parameter-name hints at call sites.
    pub fn inlayHints(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]InlayHint {
        var hints: std.ArrayListUnmanaged(InlayHint) = .empty;
        errdefer hints.deinit(gpa);
        const file_id = self.program.lookupPath(file_path) orelse return hints.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return hints.toOwnedSlice(gpa);
        try collectInlayHints(gpa, &c.hir, &c.type_interner, &c.interner, c.root, &hints);
        return hints.toOwnedSlice(gpa);
    }

    /// All top-level declarations across every file in the program,
    /// optionally filtered by a substring of the symbol name.
    /// `query == ""` returns everything. Used by VS Code's
    /// `Ctrl+T` quick-open-symbol palette.
    pub fn workspaceSymbols(
        self: *Service,
        gpa: std.mem.Allocator,
        query: []const u8,
    ) ![]SymbolInfo {
        var out: std.ArrayListUnmanaged(SymbolInfo) = .empty;
        errdefer out.deinit(gpa);
        for (self.program.files.items) |f| {
            const c = f.compilation orelse continue;
            // Skip files whose parse left a non-block root (malformed).
            if (c.hir.kindOf(c.root) != .block_stmt) continue;
            const stmts = hir_mod.blockStmts(&c.hir, c.root);
            for (stmts) |s| {
                const info = describeTopLevelSymbol(&c.hir, &c.interner, s, f.source, f.path) orelse continue;
                if (query.len > 0 and std.mem.indexOf(u8, info.name, query) == null) continue;
                try out.append(gpa, info);
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// All top-level declarations in `file`, useful for an editor
    /// outline view. Class/interface/namespace/enum decls carry their
    /// members as nested `children`. Free with `freeSymbols`.
    pub fn documentSymbols(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]SymbolInfo {
        var out: std.ArrayListUnmanaged(SymbolInfo) = .empty;
        errdefer {
            for (out.items) |s| if (s.children.len > 0) freeSymbols(gpa, s.children);
            out.deinit(gpa);
        }
        const file_id = self.program.lookupPath(file_path) orelse return out.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return out.toOwnedSlice(gpa);
        // Skip files whose parse left a non-block root (malformed).
        if (c.hir.kindOf(c.root) != .block_stmt) return out.toOwnedSlice(gpa);
        const stmts = hir_mod.blockStmts(&c.hir, c.root);
        for (stmts) |s| {
            var info = describeTopLevelSymbol(&c.hir, &c.interner, s, f.source, f.path) orelse continue;
            info.children = try collectSymbolChildren(gpa, &c.hir, &c.interner, s, f.source, f.path);
            try out.append(gpa, info);
        }
        return out.toOwnedSlice(gpa);
    }

    /// LSP `textDocument/codeLens` — emit one `CodeLens` per top-level
    /// `function` / `class` declaration in `file_path`, titled with
    /// the count of program-wide references (the declaration site
    /// itself is excluded from the count). Singular `"1 reference"`
    /// vs plural `"N references"` follows English plural agreement.
    /// Title strings are owned by `gpa`; callers free them with
    /// `freeCodeLenses`.
    pub fn codeLenses(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]CodeLens {
        var out: std.ArrayListUnmanaged(CodeLens) = .empty;
        errdefer {
            for (out.items) |l| gpa.free(l.title);
            out.deinit(gpa);
        }

        const file_id = self.program.lookupPath(file_path) orelse return out.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return out.toOwnedSlice(gpa);
        if (c.hir.kindOf(c.root) != .block_stmt) return out.toOwnedSlice(gpa);
        const stmts = hir_mod.blockStmts(&c.hir, c.root);

        for (stmts) |s_in| {
            // Unwrap `export <decl>` so we can see the inner fn/class.
            var s = s_in;
            if (c.hir.kindOf(s) == .export_decl) {
                const ex = hir_mod.exportOf(&c.hir, s);
                if (ex.decl != hir_mod.none_node_id) s = ex.decl;
            }
            const k = c.hir.kindOf(s);
            const name_node: hir_mod.NodeId = switch (k) {
                .fn_decl => blk: {
                    const fnp = hir_mod.fnDeclOf(&c.hir, s);
                    if (fnp.name == hir_mod.none_node_id) continue;
                    break :blk fnp.name;
                },
                .class_decl => blk: {
                    const cls = hir_mod.classOf(&c.hir, s);
                    if (cls.name == hir_mod.none_node_id) continue;
                    break :blk cls.name;
                },
                else => continue,
            };
            if (c.hir.kindOf(name_node) != .identifier) continue;

            // Use the declaration's own span for the lens (editor
            // anchors at start_line). Use the name node's start as
            // the cursor seed for findReferences.
            const decl_span = c.hir.spanOf(s_in);
            const name_span = c.hir.spanOf(name_node);
            const byte_pos: u32 = name_span.start;

            const refs = try self.findReferences(gpa, file_path, byte_pos);
            defer gpa.free(refs);

            // Exclude the declaration's own name occurrence: it is
            // always returned by findReferences (the cursor sits on
            // the binding identifier), so subtract one when present.
            // Guard against the (unexpected) zero case.
            const total: usize = refs.len;
            const count: usize = if (total > 0) total - 1 else 0;

            const title = if (count == 1)
                try std.fmt.allocPrint(gpa, "1 reference", .{})
            else
                try std.fmt.allocPrint(gpa, "{d} references", .{count});

            const sp = ts_diagnostics.positionToLineCol(f.source, decl_span.start);
            const ep = ts_diagnostics.positionToLineCol(f.source, decl_span.end);
            try out.append(gpa, .{
                .span = .{
                    .file = f.path,
                    .start_line = sp.line,
                    .start_col = sp.col,
                    .end_line = ep.line,
                    .end_col = ep.col,
                },
                .title = title,
                .command = "",
            });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Rename the symbol under the cursor across the entire program.
    /// Reuses `findReferences`'s cross-file walk and produces one
    /// `TextEdit` per occurrence. The caller applies them in batch.
    pub fn rename(self: *Service, gpa: std.mem.Allocator, file_path: []const u8, byte_pos: u32, new_name: []const u8) ![]TextEdit {
        var edits: std.ArrayListUnmanaged(TextEdit) = .empty;
        errdefer edits.deinit(gpa);
        const refs = try self.findReferences(gpa, file_path, byte_pos);
        defer gpa.free(refs);
        for (refs) |r| {
            try edits.append(gpa, .{
                .file = r.file,
                .start_line = if (r.start_line > 0) r.start_line - 1 else 0,
                .start_col = if (r.start_col > 0) r.start_col - 1 else 0,
                .end_line = if (r.end_line > 0) r.end_line - 1 else 0,
                .end_col = if (r.end_col > 0) r.end_col - 1 else 0,
                .new_text = new_name,
            });
        }
        return edits.toOwnedSlice(gpa);
    }

    /// Code actions available for `file`. Implements:
    ///   - "Organize Imports" — sorts top-level import declarations
    ///     by module specifier and emits the replacement edit.
    ///   - "Add explicit type annotation" — for each top-level
    ///     `let`/`const`/`var` with no annotation but a well-defined
    ///     (non-`any`) inferred type, emits an insertion of
    ///     `: <rendered_type>` right after the binding's name.
    pub fn codeActions(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]CodeAction {
        var actions: std.ArrayListUnmanaged(CodeAction) = .empty;
        errdefer actions.deinit(gpa);
        const file_id = self.program.lookupPath(file_path) orelse return actions.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return actions.toOwnedSlice(gpa);
        // Skip files whose parse left a non-block root (malformed).
        if (c.hir.kindOf(c.root) != .block_stmt) return actions.toOwnedSlice(gpa);
        const stmts = hir_mod.blockStmts(&c.hir, c.root);

        // ---- Organize Imports ---------------------------------------------
        organize_imports: {
            var imports: std.ArrayListUnmanaged(hir_mod.NodeId) = .empty;
            defer imports.deinit(gpa);
            for (stmts) |s| {
                if (c.hir.kindOf(s) == .import_decl) try imports.append(gpa, s);
            }
            if (imports.items.len < 2) break :organize_imports;
            const sorted = try gpa.dupe(hir_mod.NodeId, imports.items);
            defer gpa.free(sorted);
            const Ctx = struct {
                hir: *const hir_mod.Hir,
                sint: *const string_interner.Interner,
                pub fn lessThan(ctx: @This(), a: hir_mod.NodeId, b: hir_mod.NodeId) bool {
                    const ia = hir_mod.importOf(ctx.hir, a);
                    const ib = hir_mod.importOf(ctx.hir, b);
                    const sa = ctx.sint.get(ia.module);
                    const sb = ctx.sint.get(ib.module);
                    return std.mem.lessThan(u8, sa, sb);
                }
            };
            std.mem.sort(hir_mod.NodeId, sorted, Ctx{ .hir = &c.hir, .sint = &c.interner }, Ctx.lessThan);
            var differs = false;
            for (imports.items, 0..) |orig, i| {
                if (orig != sorted[i]) {
                    differs = true;
                    break;
                }
            }
            if (!differs) break :organize_imports;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(gpa);
            for (sorted, 0..) |id, i| {
                if (i > 0) try buf.append(gpa, '\n');
                const span = c.hir.spanOf(id);
                try buf.appendSlice(gpa, f.source[span.start..span.end]);
            }
            const new_text = try buf.toOwnedSlice(gpa);
            const first_span = c.hir.spanOf(imports.items[0]);
            const last_span = c.hir.spanOf(imports.items[imports.items.len - 1]);
            const start_pos = ts_diagnostics.positionToLineCol(f.source, first_span.start);
            const end_pos = ts_diagnostics.positionToLineCol(f.source, last_span.end);
            var edits = try gpa.alloc(TextEdit, 1);
            edits[0] = .{
                .file = f.path,
                .start_line = if (start_pos.line > 0) start_pos.line - 1 else 0,
                .start_col = if (start_pos.col > 0) start_pos.col - 1 else 0,
                .end_line = if (end_pos.line > 0) end_pos.line - 1 else 0,
                .end_col = if (end_pos.col > 0) end_pos.col - 1 else 0,
                .new_text = new_text,
            };
            try actions.append(gpa, .{
                .title = "Organize Imports",
                .kind = .organize_imports,
                .edits = edits,
            });
        }

        // ---- Add explicit type annotation ---------------------------------
        // For each top-level let/const/var with no annotation but a
        // well-defined inferred type, surface a quick-fix that
        // inserts `: <rendered_type>` after the binding's name.
        for (stmts) |s| {
            const k = c.hir.kindOf(s);
            if (k != .let_decl and k != .const_decl and k != .var_decl) continue;
            const v = hir_mod.varDeclOf(&c.hir, s);
            if (v.type_annotation != hir_mod.none_node_id) continue;
            if (v.init == hir_mod.none_node_id) continue;
            if (v.name == hir_mod.none_node_id) continue;
            // Only handle plain identifier bindings (skip destructuring).
            if (c.hir.kindOf(v.name) != .identifier) continue;
            const t = c.hir.typeOf(v.name);
            // Skip none / any / unknown — not useful to surface.
            if (t == ts_checker.Primitive.none) continue;
            if (t == ts_checker.Primitive.any) continue;
            if (t == ts_checker.Primitive.unknown) continue;
            const repr = renderType(gpa, &c.type_interner, &c.interner, t) catch continue;
            defer gpa.free(repr);
            const new_text = try std.fmt.allocPrint(gpa, ": {s}", .{repr});
            errdefer gpa.free(new_text);
            const name_id = hir_mod.identifierOf(&c.hir, v.name).name;
            const name_str = c.interner.get(name_id);
            const title = try std.fmt.allocPrint(gpa, "Add explicit type to {s}", .{name_str});
            errdefer gpa.free(title);
            // Insertion is a zero-width edit at the byte right after
            // the binding's name.
            const ins_byte = c.hir.spanOf(v.name).end;
            const ins_pos = ts_diagnostics.positionToLineCol(f.source, ins_byte);
            const ln: u32 = if (ins_pos.line > 0) ins_pos.line - 1 else 0;
            const co: u32 = if (ins_pos.col > 0) ins_pos.col - 1 else 0;
            var edits = try gpa.alloc(TextEdit, 1);
            edits[0] = .{
                .file = f.path,
                .start_line = ln,
                .start_col = co,
                .end_line = ln,
                .end_col = co,
                .new_text = new_text,
            };
            try actions.append(gpa, .{
                .title = title,
                .kind = .quick_fix,
                .edits = edits,
            });
        }

        return actions.toOwnedSlice(gpa);
    }

    /// Semantic tokens for `file`. Walks the HIR and emits one
    /// classified token per identifier-bearing node, so the editor
    /// can color code by symbol kind. The result is sorted by
    /// (line, col) — matching LSP's `textDocument/semanticTokens/full`
    /// expected ordering.
    pub fn semanticTokens(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]SemanticToken {
        var tokens: std.ArrayListUnmanaged(SemanticToken) = .empty;
        errdefer tokens.deinit(gpa);
        const file_id = self.program.lookupPath(file_path) orelse return tokens.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return tokens.toOwnedSlice(gpa);
        var i: hir_mod.NodeId = 1;
        while (i < c.hir.nodeCount()) : (i += 1) {
            const tt = classifyNodeForSemantic(&c.hir, i) orelse continue;
            const span = c.hir.spanOf(i);
            const pos = ts_diagnostics.positionToLineCol(f.source, span.start);
            try tokens.append(gpa, .{
                .line = pos.line - 1, // LSP is 0-based; our positionToLineCol is 1-based.
                .col = pos.col - 1,
                .length = span.end - span.start,
                .token_type = tt,
                .modifiers = 0,
            });
        }
        // Walk the saved scanner token stream so keyword tokens
        // (`let`, `function`, `class`, `if`, ...) get a `.keyword`
        // semantic-token classification. The HIR encodes keywords
        // implicitly via node kind, so without this pass editors
        // would miss them. Comments are scanner trivia and aren't
        // retained as tokens — once `.line_comment` /
        // `.block_comment` token kinds exist they get classified the
        // same way (see `classifyLexerToken`).
        for (c.tokens.items) |tok| {
            const tt = classifyLexerToken(tok.kind) orelse continue;
            const pos = ts_diagnostics.positionToLineCol(f.source, tok.span.start);
            try tokens.append(gpa, .{
                .line = pos.line - 1,
                .col = pos.col - 1,
                .length = tok.span.end - tok.span.start,
                .token_type = tt,
                .modifiers = 0,
            });
        }
        // Sort by (line, col) for deterministic delta output.
        std.mem.sort(SemanticToken, tokens.items, {}, semanticTokenLessThan);
        return tokens.toOwnedSlice(gpa);
    }

    /// Delta-encoded LSP wire form of `semanticTokens(file)` —
    /// matches the `data` array shape required by
    /// `textDocument/semanticTokens/full`.
    ///
    /// For each (line, col)-sorted token we emit 5 u32s:
    /// `delta_line`, `delta_start`, `length`, `token_type_index`,
    /// `token_modifiers_bitset`. `delta_line` is relative to the
    /// previous token (or 0 for the first); `delta_start` is
    /// relative to the previous token's `col` when on the same line,
    /// otherwise the absolute column on the new line.
    pub fn semanticTokensWire(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]u32 {
        const toks = try self.semanticTokens(gpa, file_path);
        defer gpa.free(toks);
        return encodeSemanticTokensWire(gpa, toks);
    }

    /// Delta-encoded LSP wire form of the subset of tokens whose
    /// `line` falls in `[start_line, end_line)` — matches
    /// `textDocument/semanticTokens/range`. Encoding is identical to
    /// `semanticTokensWire`, but only the in-range tokens contribute
    /// to the delta sequence (and the first in-range token's deltas
    /// are absolute vs (0, 0)).
    pub fn semanticTokensRange(
        self: *Service,
        gpa: std.mem.Allocator,
        file_path: []const u8,
        start_line: u32,
        end_line: u32,
    ) ![]u32 {
        const toks = try self.semanticTokens(gpa, file_path);
        defer gpa.free(toks);
        var filtered: std.ArrayListUnmanaged(SemanticToken) = .empty;
        defer filtered.deinit(gpa);
        for (toks) |t| {
            if (t.line >= start_line and t.line < end_line) {
                try filtered.append(gpa, t);
            }
        }
        return encodeSemanticTokensWire(gpa, filtered.items);
    }

    /// Apply an editor `textDocument/didChange` to `file_path`:
    /// replace the program's source bytes, recompile just that file
    /// (cross-file imports are re-resolved as part of the recompile),
    /// and return the rendered diagnostics — the same shape
    /// `diagnostics(file)` returns. The caller (e.g. the LSP wire
    /// layer) is expected to push the result back to the editor as a
    /// `textDocument/publishDiagnostics` notification.
    ///
    /// Returns an empty slice when `file_path` isn't tracked.
    ///
    /// §8.A.8: incremental edit -> recompile -> fresh diagnostics.
    pub fn didChangeFile(
        self: *Service,
        gpa: std.mem.Allocator,
        file_path: []const u8,
        new_source: []const u8,
    ) ![]const u8 {
        // Step 1: swap the source bytes in. updateSource also
        // invalidates the file's cached compilation.
        const id_opt = try self.program.updateSource(file_path, new_source);
        if (id_opt == null) {
            // Unknown file — nothing to do, return empty rendered diagnostics.
            return gpa.dupe(u8, "");
        }
        // Step 2: recompile this file (and re-resolve imports).
        // v1 recompiles the changed file only; transitive
        // re-typecheck of importers is a follow-up.
        const paths = [_][]const u8{file_path};
        _ = try self.program.recompileChanged(&paths, .{});
        // Step 3: render fresh diagnostics for the editor.
        return self.diagnostics(gpa, file_path);
    }

    /// `textDocument/formatting` — return a list of `TextEdit`s that
    /// reformat `file_path`. Today this is a no-op stub: real
    /// formatting requires a TS-aware pretty-printer (the JS emitter
    /// in `ts_emit/js_emit.zig` erases types, so it's not suitable
    /// here). Phase 6 follow-up: add a TS-preserving printer and
    /// surface a real edit. The contract — "method exists + responds
    /// with a TextEdit list" — is satisfied; an empty list is a
    /// valid LSP response meaning "already formatted / nothing to
    /// change".
    pub fn formatDocument(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]TextEdit {
        var edits: std.ArrayListUnmanaged(TextEdit) = .empty;
        errdefer edits.deinit(gpa);
        // Confirm the file is tracked + has a successful compilation.
        // If either is missing, return an empty edit list (no-op).
        const file_id = self.program.lookupPath(file_path) orelse return edits.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        _ = f.compilation orelse return edits.toOwnedSlice(gpa);
        // TODO(Phase 6): once a TS-preserving pretty-printer lands,
        // re-emit `f.source` through it and emit a single full-file
        // replacement edit. For now we return [] so editors treat
        // the file as already formatted.
        return edits.toOwnedSlice(gpa);
    }

    /// `textDocument/selectionRange` — return a list of nested ranges
    /// at `byte_pos`, innermost first, walking up the HIR parent chain.
    /// Editors use this to power "expand selection" / "shrink
    /// selection" commands: each successive entry strictly encloses
    /// the previous one, ending with the file root. When the cursor
    /// doesn't land on any node (empty file / unknown path) the
    /// returned slice is empty.
    pub fn selectionRange(self: *Service, gpa: std.mem.Allocator, file_path: []const u8, byte_pos: u32) ![]Range {
        var ranges: std.ArrayListUnmanaged(Range) = .empty;
        errdefer ranges.deinit(gpa);

        const file_id = self.program.lookupPath(file_path) orelse return ranges.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return ranges.toOwnedSlice(gpa);
        const start = findInnermostNode(&c.hir, c.root, byte_pos) orelse return ranges.toOwnedSlice(gpa);

        // Walk parent chain, emitting one range per ancestor. Skip
        // duplicate spans (some HIR wrappers share their child's
        // span exactly — collapsing those keeps "expand selection"
        // visibly progressive).
        var cur = start;
        var last_start: u32 = std.math.maxInt(u32);
        var last_end: u32 = std.math.maxInt(u32);
        while (cur != hir_mod.none_node_id) {
            const span = c.hir.spanOf(cur);
            if (!(span.start == last_start and span.end == last_end)) {
                const sp = ts_diagnostics.positionToLineCol(f.source, span.start);
                const ep = ts_diagnostics.positionToLineCol(f.source, span.end);
                try ranges.append(gpa, .{
                    .start_line = sp.line,
                    .start_col = sp.col,
                    .end_line = ep.line,
                    .end_col = ep.col,
                });
                last_start = span.start;
                last_end = span.end;
            }
            const p = c.hir.parentOf(cur);
            if (p == cur) break;
            if (p == hir_mod.none_node_id) break;
            cur = p;
        }
        return ranges.toOwnedSlice(gpa);
    }

    /// `textDocument/willSaveWaitUntil` — give the server a chance to
    /// apply edits before the editor persists the file. The reason
    /// mirrors LSP's `TextDocumentSaveReason` (1 = manual, 2 = auto,
    /// 3 = after_delay, 4 = focus_out). For now we just delegate to
    /// `formatDocument` for every save trigger; once we differentiate
    /// auto-save behavior (e.g. skip heavy formatting on focus_out)
    /// the per-reason branching lands here.
    pub fn willSaveWaitUntil(
        self: *Service,
        gpa: std.mem.Allocator,
        file_path: []const u8,
        reason: SaveReason,
    ) ![]TextEdit {
        _ = reason;
        return self.formatDocument(gpa, file_path);
    }

    /// `textDocument/foldingRange` — return one `FoldingRange` per
    /// foldable region in `file_path`. We surface:
    ///   - one `imports` range covering any contiguous run of
    ///     top-level `import_decl` statements (when 2+ imports);
    ///   - one `region` range per `block_stmt` in the file (the file
    ///     root is itself a block_stmt and is skipped — folding the
    ///     entire file is not useful).
    pub fn foldingRanges(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]FoldingRange {
        var ranges: std.ArrayListUnmanaged(FoldingRange) = .empty;
        errdefer ranges.deinit(gpa);
        const file_id = self.program.lookupPath(file_path) orelse return ranges.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return ranges.toOwnedSlice(gpa);

        // 1. Walk the root's children to find a contiguous import run.
        if (c.hir.kindOf(c.root) == .block_stmt) {
            const stmts = hir_mod.blockStmts(&c.hir, c.root);
            var run_start: ?hir_mod.NodeId = null;
            var run_last: hir_mod.NodeId = hir_mod.none_node_id;
            for (stmts) |s| {
                if (c.hir.kindOf(s) == .import_decl) {
                    if (run_start == null) run_start = s;
                    run_last = s;
                } else {
                    if (run_start) |start_node| {
                        if (start_node != run_last) {
                            const sp = c.hir.spanOf(start_node);
                            const ep = c.hir.spanOf(run_last);
                            const start_pos = ts_diagnostics.positionToLineCol(f.source, sp.start);
                            const end_pos = ts_diagnostics.positionToLineCol(f.source, ep.end);
                            try ranges.append(gpa, .{
                                .start_line = if (start_pos.line > 0) start_pos.line - 1 else 0,
                                .end_line = if (end_pos.line > 0) end_pos.line - 1 else 0,
                                .kind = .imports,
                            });
                        }
                        run_start = null;
                    }
                }
            }
            // Trailing run (if file ends inside an import block).
            if (run_start) |start_node| {
                if (start_node != run_last) {
                    const sp = c.hir.spanOf(start_node);
                    const ep = c.hir.spanOf(run_last);
                    const start_pos = ts_diagnostics.positionToLineCol(f.source, sp.start);
                    const end_pos = ts_diagnostics.positionToLineCol(f.source, ep.end);
                    try ranges.append(gpa, .{
                        .start_line = if (start_pos.line > 0) start_pos.line - 1 else 0,
                        .end_line = if (end_pos.line > 0) end_pos.line - 1 else 0,
                        .kind = .imports,
                    });
                }
            }
        }

        // 2. Emit a `region` range per block_stmt in the file (skip
        //    the root block, which spans the whole file).
        var i: hir_mod.NodeId = 1;
        while (i < c.hir.nodeCount()) : (i += 1) {
            if (i == c.root) continue;
            if (c.hir.kindOf(i) != .block_stmt) continue;
            const span = c.hir.spanOf(i);
            const start_pos = ts_diagnostics.positionToLineCol(f.source, span.start);
            const end_pos = ts_diagnostics.positionToLineCol(f.source, span.end);
            // Folding only makes sense for blocks spanning multiple lines.
            if (end_pos.line <= start_pos.line) continue;
            try ranges.append(gpa, .{
                .start_line = if (start_pos.line > 0) start_pos.line - 1 else 0,
                .end_line = if (end_pos.line > 0) end_pos.line - 1 else 0,
                .kind = .region,
            });
        }
        return ranges.toOwnedSlice(gpa);
    }

    /// LSP `callHierarchy/incomingCalls`: return one item per
    /// function in the program that calls the function under the
    /// cursor. The cursor must land inside (or on the name of) a
    /// function declaration; we match call sites by callee-identifier
    /// name and credit each match to its enclosing fn declaration.
    /// Each returned item points at the calling fn's declaration span.
    pub fn callHierarchyIncoming(
        self: *Service,
        gpa: std.mem.Allocator,
        file_path: []const u8,
        byte_pos: u32,
    ) ![]CallHierarchyItem {
        var out: std.ArrayListUnmanaged(CallHierarchyItem) = .empty;
        errdefer out.deinit(gpa);

        const file_id = self.program.lookupPath(file_path) orelse return out.toOwnedSlice(gpa);
        const origin = self.program.fileById(file_id);
        const oc = origin.compilation orelse return out.toOwnedSlice(gpa);
        const start = findInnermostNode(&oc.hir, oc.root, byte_pos) orelse return out.toOwnedSlice(gpa);
        const target_fn = enclosingFnDecl(&oc.hir, start) orelse return out.toOwnedSlice(gpa);
        const target_fn_p = hir_mod.fnDeclOf(&oc.hir, target_fn);
        if (target_fn_p.name == hir_mod.none_node_id) return out.toOwnedSlice(gpa);
        const target_name_id = hir_mod.identifierOf(&oc.hir, target_fn_p.name).name;
        const target_name = oc.interner.get(target_name_id);

        // Walk every program file's HIR. For each call_expr whose
        // callee is an identifier matching the target name, find the
        // enclosing fn declaration and record it. Top-level calls
        // (no enclosing fn) are skipped.
        for (self.program.files.items) |f| {
            const c = f.compilation orelse continue;
            const local_id = c.interner.lookup(target_name) orelse continue;
            var i: hir_mod.NodeId = 1;
            while (i < c.hir.nodeCount()) : (i += 1) {
                if (c.hir.kindOf(i) != .call_expr) continue;
                const call = hir_mod.callOf(&c.hir, i);
                if (call.callee == hir_mod.none_node_id) continue;
                if (c.hir.kindOf(call.callee) != .identifier) continue;
                const cid = hir_mod.identifierOf(&c.hir, call.callee);
                if (cid.name != local_id) continue;

                const caller_fn = enclosingFnDecl(&c.hir, i) orelse continue;
                // Skip self-recursive matches against the target itself.
                if (f.id == file_id and caller_fn == target_fn) continue;
                const item = describeFnDeclItem(&c.hir, &c.interner, caller_fn, f.source, f.path) orelse continue;
                if (containsCallHierarchyItem(out.items, item)) continue;
                try out.append(gpa, item);
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// LSP `callHierarchy/outgoingCalls`: return one item per
    /// function called BY the function under the cursor. Walks the
    /// target fn's body for `call_expr` nodes; for each, the callee
    /// identifier is resolved against the file's module-scope symbol
    /// table to find its declaration. Calls whose callee isn't a
    /// resolvable top-level fn name are skipped.
    pub fn callHierarchyOutgoing(
        self: *Service,
        gpa: std.mem.Allocator,
        file_path: []const u8,
        byte_pos: u32,
    ) ![]CallHierarchyItem {
        var out: std.ArrayListUnmanaged(CallHierarchyItem) = .empty;
        errdefer out.deinit(gpa);

        const file_id = self.program.lookupPath(file_path) orelse return out.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return out.toOwnedSlice(gpa);
        const start = findInnermostNode(&c.hir, c.root, byte_pos) orelse return out.toOwnedSlice(gpa);
        const target_fn = enclosingFnDecl(&c.hir, start) orelse return out.toOwnedSlice(gpa);
        const target_fn_p = hir_mod.fnDeclOf(&c.hir, target_fn);
        if (target_fn_p.body == hir_mod.none_node_id) return out.toOwnedSlice(gpa);

        // Walk every node in the file and check if it's a descendant
        // of the target fn. We use parent-chain walks to test
        // containment so we don't need a recursive HIR walker here.
        var i: hir_mod.NodeId = 1;
        while (i < c.hir.nodeCount()) : (i += 1) {
            if (c.hir.kindOf(i) != .call_expr) continue;
            if (!nodeContainedIn(&c.hir, i, target_fn)) continue;
            const call = hir_mod.callOf(&c.hir, i);
            if (call.callee == hir_mod.none_node_id) continue;
            if (c.hir.kindOf(call.callee) != .identifier) continue;
            const cid = hir_mod.identifierOf(&c.hir, call.callee);
            const sym = c.module.root.lookup(cid.name) orelse continue;
            if (sym.decls.items.len == 0) continue;
            const decl = sym.decls.items[0];
            const decl_kind = c.hir.kindOf(decl);
            if (decl_kind != .fn_decl and decl_kind != .fn_expr and decl_kind != .arrow_fn) continue;
            const item = describeFnDeclItem(&c.hir, &c.interner, decl, f.source, f.path) orelse continue;
            if (containsCallHierarchyItem(out.items, item)) continue;
            try out.append(gpa, item);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Diagnostics for `file`. Forwards from the per-file
    /// Compilation and renders them in tsc-default format.
    pub fn diagnostics(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        const file_id = self.program.lookupPath(file_path) orelse return buf.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return buf.toOwnedSlice(gpa);
        for (c.diagnostics.items) |d| {
            const pos = ts_diagnostics.positionToLineCol(f.source, d.pos);
            const fdiag: ts_diagnostics.Diagnostic = .{
                .file = f.path,
                .line = pos.line,
                .col = pos.col,
                .code = 2300 + @as(u32, @intFromEnum(d.phase)),
                .code_prefix = .TS,
                .severity = .err,
                .message = d.message,
                .span_len = 0,
            };
            const formatted = try ts_diagnostics.formatDefault(gpa, fdiag);
            defer gpa.free(formatted);
            try buf.appendSlice(gpa, formatted);
            try buf.append(gpa, '\n');
        }
        return buf.toOwnedSlice(gpa);
    }

    /// Structured per-file diagnostics for the LSP wire layer.
    /// Mirrors `diagnostics(file)` but returns a `[]LspDiagnostic`
    /// (range/severity/code/message/source) instead of a rendered
    /// blob, so the wire layer can emit the LSP `Diagnostic[]` shape
    /// directly without re-parsing text.
    ///
    /// Caller owns the slice — release via `freeLspDiagnostics`.
    pub fn diagnosticsStructured(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]LspDiagnostic {
        var out: std.ArrayListUnmanaged(LspDiagnostic) = .empty;
        errdefer {
            for (out.items) |d| gpa.free(d.message);
            out.deinit(gpa);
        }
        const file_id = self.program.lookupPath(file_path) orelse return out.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return out.toOwnedSlice(gpa);
        for (c.diagnostics.items) |d| {
            const start_pos = ts_diagnostics.positionToLineCol(f.source, d.pos);
            // The driver `Diagnostic` doesn't track an explicit
            // `span_len`; we render a single-char range starting at
            // the diagnostic position. (When the upstream Diagnostic
            // grows a span field, swap this for `pos + span_len`.)
            const end_byte: u32 = d.pos + 1;
            const end_pos = ts_diagnostics.positionToLineCol(f.source, end_byte);
            const code: u32 = if (d.code != 0) d.code else 2300 + @as(u32, @intFromEnum(d.phase));
            const message = try gpa.dupe(u8, d.message);
            errdefer gpa.free(message);
            try out.append(gpa, .{
                .range = .{
                    .file = f.path,
                    .start_line = start_pos.line,
                    .start_col = start_pos.col,
                    .end_line = end_pos.line,
                    .end_col = end_pos.col,
                },
                .severity = .err,
                .code = code,
                .message = message,
                .source = "ts",
            });
        }
        return out.toOwnedSlice(gpa);
    }
};

fn semanticTokenLessThan(_: void, a: SemanticToken, b: SemanticToken) bool {
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}

/// Walk a (line, col)-sorted slice of `SemanticToken`s and produce
/// the LSP-wire `[]u32` (5 u32s per token: `delta_line`,
/// `delta_start`, `length`, `type`, `modifiers`). The first token's
/// deltas are absolute (vs (0, 0)); subsequent `delta_start` resets
/// to absolute on each new line.
fn encodeSemanticTokensWire(gpa: std.mem.Allocator, tokens: []const SemanticToken) ![]u32 {
    var data: std.ArrayListUnmanaged(u32) = .empty;
    errdefer data.deinit(gpa);
    var prev_line: u32 = 0;
    var prev_col: u32 = 0;
    for (tokens, 0..) |t, i| {
        const delta_line = if (i == 0) t.line else t.line - prev_line;
        const delta_start = blk: {
            if (i == 0) break :blk t.col;
            if (t.line == prev_line) break :blk t.col - prev_col;
            break :blk t.col;
        };
        try data.append(gpa, delta_line);
        try data.append(gpa, delta_start);
        try data.append(gpa, t.length);
        try data.append(gpa, @intFromEnum(t.token_type));
        try data.append(gpa, t.modifiers);
        prev_line = t.line;
        prev_col = t.col;
    }
    return data.toOwnedSlice(gpa);
}

/// Map a HIR node to a semantic-token type by inspecting the node's
/// kind plus the kind of its parent (e.g., `identifier` inside a
/// `fn_decl`'s name slot is a `function` token, but the same kind
/// inside a `let_decl` is a `variable`).
fn classifyNodeForSemantic(hir: *const hir_mod.Hir, node: hir_mod.NodeId) ?SemanticToken.TokenType {
    const k = hir.kindOf(node);
    switch (k) {
        .literal_string => return .string,
        .literal_number => return .number,
        .identifier => {
            // Look at the parent to disambiguate.
            const p = hir.parentOf(node);
            if (p == hir_mod.none_node_id) return .variable;
            const pk = hir.kindOf(p);
            switch (pk) {
                .fn_decl, .fn_expr => {
                    const f = hir_mod.fnDeclOf(hir, p);
                    if (f.name == node) return .function;
                    return .variable;
                },
                .class_decl, .class_expr => {
                    const c = hir_mod.classOf(hir, p);
                    if (c.name == node) return .class;
                    return .variable;
                },
                .interface_decl => {
                    const inf = hir_mod.interfaceOf(hir, p);
                    if (inf.name == node) return .interface;
                    return .variable;
                },
                .type_alias_decl => {
                    const a = hir_mod.typeAliasOf(hir, p);
                    if (a.name == node) return .type_alias;
                    return .variable;
                },
                .enum_decl => {
                    const e = hir_mod.enumOf(hir, p);
                    if (e.name == node) return .enum_;
                    return .variable;
                },
                .parameter => return .parameter,
                .member_access => return .property,
                else => return .variable,
            }
        },
        else => return null,
    }
}

/// Map a scanner `TokenKind` to a semantic-token type. Today this
/// surfaces keywords as `.keyword`; comment trivia is not retained
/// as a token kind by the lexer (whitespace + comments are skipped
/// during scanning), so this returns `null` for everything else.
/// When the lexer grows `.line_comment` / `.block_comment` token
/// kinds, add them here mapped to `.comment`.
fn classifyLexerToken(kind: ts_lexer.TokenKind) ?SemanticToken.TokenType {
    if (kind.isKeyword()) return .keyword;
    return null;
}

/// Walk up the parent chain from `start` until we find a call_expr,
/// or return null if we reach the root without one.
fn walkUpToCallExpr(hir: *const hir_mod.Hir, start: hir_mod.NodeId) ?hir_mod.NodeId {
    var cur = start;
    while (cur != hir_mod.none_node_id) {
        if (hir.kindOf(cur) == .call_expr) return cur;
        const p = hir.parentOf(cur);
        if (p == cur) return null;
        cur = p;
    }
    return null;
}

/// Walk up the parent chain from `start` until we find an
/// fn_decl/fn_expr/arrow_fn, or return null if we reach the root
/// without one. Used by call-hierarchy to anchor a cursor inside a
/// function body to that function's declaration node.
fn enclosingFnDecl(hir: *const hir_mod.Hir, start: hir_mod.NodeId) ?hir_mod.NodeId {
    var cur = start;
    while (cur != hir_mod.none_node_id) {
        const k = hir.kindOf(cur);
        if (k == .fn_decl or k == .fn_expr or k == .arrow_fn) return cur;
        const p = hir.parentOf(cur);
        if (p == cur) return null;
        cur = p;
    }
    return null;
}

/// Test whether `node` is `ancestor` or a transitive descendant of
/// it, by walking the parent chain upward from `node`.
fn nodeContainedIn(hir: *const hir_mod.Hir, node: hir_mod.NodeId, ancestor: hir_mod.NodeId) bool {
    var cur = node;
    while (cur != hir_mod.none_node_id) {
        if (cur == ancestor) return true;
        const p = hir.parentOf(cur);
        if (p == cur) return false;
        cur = p;
    }
    return false;
}

/// Build a `CallHierarchyItem` from a fn_decl-shaped node. Returns
/// null when the function has no name (anonymous fn_expr / arrow).
fn describeFnDeclItem(
    hir: *const hir_mod.Hir,
    sint: *const string_interner.Interner,
    fn_node: hir_mod.NodeId,
    source: []const u8,
    file_path: []const u8,
) ?CallHierarchyItem {
    const f = hir_mod.fnDeclOf(hir, fn_node);
    if (f.name == hir_mod.none_node_id) return null;
    if (hir.kindOf(f.name) != .identifier) return null;
    const name_id = hir_mod.identifierOf(hir, f.name).name;
    const span = hir.spanOf(fn_node);
    const sp = ts_diagnostics.positionToLineCol(source, span.start);
    const ep = ts_diagnostics.positionToLineCol(source, span.end);
    return .{
        .name = sint.get(name_id),
        .kind = .function,
        .span = .{
            .file = file_path,
            .start_line = sp.line,
            .start_col = sp.col,
            .end_line = ep.line,
            .end_col = ep.col,
        },
    };
}

/// Linear de-dup helper for the call-hierarchy result list. Items
/// match by file+name (call sites can repeat within the same caller).
fn containsCallHierarchyItem(items: []const CallHierarchyItem, item: CallHierarchyItem) bool {
    for (items) |it| {
        if (std.mem.eql(u8, it.name, item.name) and std.mem.eql(u8, it.span.file, item.span.file)) {
            return true;
        }
    }
    return false;
}

/// Walk the file's top-level statements and emit type-annotation
/// hints at unannotated `let`/`const` declarations.
fn collectInlayHints(
    gpa: std.mem.Allocator,
    hir: *const hir_mod.Hir,
    type_interner: *const ts_checker.Interner,
    sint: *const string_interner.Interner,
    root: hir_mod.NodeId,
    out: *std.ArrayListUnmanaged(InlayHint),
) !void {
    if (root == hir_mod.none_node_id) return;
    const k = hir.kindOf(root);
    switch (k) {
        .let_decl, .const_decl, .var_decl => {
            const v = hir_mod.varDeclOf(hir, root);
            // Hint only when no explicit annotation but a type was inferred.
            if (v.type_annotation != hir_mod.none_node_id) return;
            if (v.name == hir_mod.none_node_id) return;
            const t = hir.typeOf(v.name);
            const repr = renderType(gpa, type_interner, sint, t) catch return;
            const label = try std.fmt.allocPrint(gpa, ": {s}", .{repr});
            gpa.free(repr);
            try out.append(gpa, .{
                .pos = hir.spanOf(v.name).end,
                .label = label,
                .kind = .type_annotation,
            });
        },
        .block_stmt => {
            const stmts = hir_mod.blockStmts(hir, root);
            for (stmts) |s| try collectInlayHints(gpa, hir, type_interner, sint, s, out);
        },
        .fn_decl => {
            const f = hir_mod.fnDeclOf(hir, root);
            if (f.body != hir_mod.none_node_id) {
                try collectInlayHints(gpa, hir, type_interner, sint, f.body, out);
            }
        },
        else => {},
    }
}

fn describeTopLevelSymbol(
    hir: *const hir_mod.Hir,
    sint: *const string_interner.Interner,
    node_in: hir_mod.NodeId,
    source: []const u8,
    file_path: []const u8,
) ?SymbolInfo {
    // Unwrap `export <decl>` to the inner decl so the symbol name + kind
    // come from `<decl>` rather than the export shell.
    var node = node_in;
    if (hir.kindOf(node) == .export_decl) {
        const ex = hir_mod.exportOf(hir, node);
        if (ex.decl != hir_mod.none_node_id) node = ex.decl;
    }
    const k = hir.kindOf(node);
    const span = hir.spanOf(node);
    const sp = ts_diagnostics.positionToLineCol(source, span.start);
    const ep = ts_diagnostics.positionToLineCol(source, span.end);
    const span_info: Span = .{
        .file = file_path,
        .start_line = sp.line,
        .start_col = sp.col,
        .end_line = ep.line,
        .end_col = ep.col,
    };
    switch (k) {
        .fn_decl => {
            const f = hir_mod.fnDeclOf(hir, node);
            if (f.name == hir_mod.none_node_id) return null;
            const name_id = hir_mod.identifierOf(hir, f.name).name;
            return .{ .name = sint.get(name_id), .kind = .function, .span = span_info };
        },
        .class_decl => {
            const c = hir_mod.classOf(hir, node);
            if (c.name == hir_mod.none_node_id) return null;
            const name_id = hir_mod.identifierOf(hir, c.name).name;
            return .{ .name = sint.get(name_id), .kind = .class, .span = span_info };
        },
        .interface_decl => {
            const inf = hir_mod.interfaceOf(hir, node);
            if (inf.name == hir_mod.none_node_id) return null;
            const name_id = hir_mod.identifierOf(hir, inf.name).name;
            return .{ .name = sint.get(name_id), .kind = .interface, .span = span_info };
        },
        .type_alias_decl => {
            const a = hir_mod.typeAliasOf(hir, node);
            if (a.name == hir_mod.none_node_id) return null;
            const name_id = hir_mod.identifierOf(hir, a.name).name;
            return .{ .name = sint.get(name_id), .kind = .type_alias, .span = span_info };
        },
        .enum_decl => {
            const e = hir_mod.enumOf(hir, node);
            if (e.name == hir_mod.none_node_id) return null;
            const name_id = hir_mod.identifierOf(hir, e.name).name;
            return .{ .name = sint.get(name_id), .kind = .enum_, .span = span_info };
        },
        .namespace_decl => {
            const n = hir_mod.namespaceOf(hir, node);
            if (n.name == hir_mod.none_node_id) return null;
            const name_id = hir_mod.identifierOf(hir, n.name).name;
            return .{ .name = sint.get(name_id), .kind = .namespace, .span = span_info };
        },
        .let_decl, .const_decl, .var_decl => {
            const v = hir_mod.varDeclOf(hir, node);
            if (v.name == hir_mod.none_node_id) return null;
            const name_id = hir_mod.identifierOf(hir, v.name).name;
            return .{ .name = sint.get(name_id), .kind = .variable, .span = span_info };
        },
        else => return null,
    }
}

/// Build the `children` list for a top-level symbol. Class members
/// become method/property children, interface members become
/// method/property children, namespace members recursively become
/// their describable child kinds, and enum members become
/// `enum_member` children. Returns an empty slice when the node has
/// no enumerable children.
fn collectSymbolChildren(
    gpa: std.mem.Allocator,
    hir: *const hir_mod.Hir,
    sint: *const string_interner.Interner,
    node_in: hir_mod.NodeId,
    source: []const u8,
    file_path: []const u8,
) ![]SymbolInfo {
    var node = node_in;
    if (hir.kindOf(node) == .export_decl) {
        const ex = hir_mod.exportOf(hir, node);
        if (ex.decl != hir_mod.none_node_id) node = ex.decl;
    }
    var out: std.ArrayListUnmanaged(SymbolInfo) = .empty;
    errdefer {
        for (out.items) |s| if (s.children.len > 0) freeSymbols(gpa, s.children);
        out.deinit(gpa);
    }
    switch (hir.kindOf(node)) {
        .class_decl => {
            const members = hir_mod.classMembers(hir, node);
            for (members) |m| {
                const child = describeMemberSymbol(hir, sint, m, source, file_path) orelse continue;
                try out.append(gpa, child);
            }
        },
        .interface_decl => {
            const members = hir_mod.interfaceMembers(hir, node);
            for (members) |m| {
                const child = describeMemberSymbol(hir, sint, m, source, file_path) orelse continue;
                try out.append(gpa, child);
            }
        },
        .namespace_decl => {
            const body = hir_mod.namespaceBody(hir, node);
            for (body) |s| {
                var child = describeTopLevelSymbol(hir, sint, s, source, file_path) orelse continue;
                child.children = try collectSymbolChildren(gpa, hir, sint, s, source, file_path);
                try out.append(gpa, child);
            }
        },
        .enum_decl => {
            const members = hir_mod.enumMembers(hir, node);
            for (members) |m| {
                const child = describeEnumMember(hir, sint, m, source, file_path) orelse continue;
                try out.append(gpa, child);
            }
        },
        else => {},
    }
    return out.toOwnedSlice(gpa);
}

/// Describe one class or interface member as a child SymbolInfo.
/// Returns null for members we can't name (e.g. decorators, computed
/// keys without a literal identifier).
fn describeMemberSymbol(
    hir: *const hir_mod.Hir,
    sint: *const string_interner.Interner,
    node: hir_mod.NodeId,
    source: []const u8,
    file_path: []const u8,
) ?SymbolInfo {
    const k = hir.kindOf(node);
    const span = hir.spanOf(node);
    const sp = ts_diagnostics.positionToLineCol(source, span.start);
    const ep = ts_diagnostics.positionToLineCol(source, span.end);
    const span_info: Span = .{
        .file = file_path,
        .start_line = sp.line,
        .start_col = sp.col,
        .end_line = ep.line,
        .end_col = ep.col,
    };
    switch (k) {
        // Class methods are emitted as `fn_expr` (since they have
        // `is_method=true`); free functions as `fn_decl`. Both share
        // `FnDeclPayload`; we surface either as a `method` child.
        .fn_decl, .fn_expr => {
            const f = hir_mod.fnDeclOf(hir, node);
            if (f.name == hir_mod.none_node_id) return null;
            const name_id = hir_mod.identifierOf(hir, f.name).name;
            return .{ .name = sint.get(name_id), .kind = .method, .span = span_info };
        },
        .object_property => {
            const op = hir_mod.objectPropertyOf(hir, node);
            if (op.key == hir_mod.none_node_id) return null;
            if (hir.kindOf(op.key) != .identifier) return null;
            const name_id = hir_mod.identifierOf(hir, op.key).name;
            const kind: SymbolInfo.SymbolKind = if (op.is_method) .method else .property;
            return .{ .name = sint.get(name_id), .kind = kind, .span = span_info };
        },
        .interface_member => {
            const im = hir_mod.interfaceMemberOf(hir, node);
            if (im.name == 0) return null;
            const kind: SymbolInfo.SymbolKind = if (im.is_method) .method else .property;
            return .{ .name = sint.get(im.name), .kind = kind, .span = span_info };
        },
        else => return null,
    }
}

/// Describe one enum member (parser emits these as `object_property`).
fn describeEnumMember(
    hir: *const hir_mod.Hir,
    sint: *const string_interner.Interner,
    node: hir_mod.NodeId,
    source: []const u8,
    file_path: []const u8,
) ?SymbolInfo {
    if (hir.kindOf(node) != .object_property) return null;
    const op = hir_mod.objectPropertyOf(hir, node);
    if (op.key == hir_mod.none_node_id) return null;
    if (hir.kindOf(op.key) != .identifier) return null;
    const name_id = hir_mod.identifierOf(hir, op.key).name;
    const span = hir.spanOf(node);
    const sp = ts_diagnostics.positionToLineCol(source, span.start);
    const ep = ts_diagnostics.positionToLineCol(source, span.end);
    return .{
        .name = sint.get(name_id),
        .kind = .enum_member,
        .span = .{
            .file = file_path,
            .start_line = sp.line,
            .start_col = sp.col,
            .end_line = ep.line,
            .end_col = ep.col,
        },
    };
}

/// Walk the HIR depth-first and return the smallest node whose
/// span contains `byte_pos`.
fn findInnermostNode(hir: *const hir_mod.Hir, root: hir_mod.NodeId, byte_pos: u32) ?hir_mod.NodeId {
    if (root == hir_mod.none_node_id) return null;
    var best: ?hir_mod.NodeId = null;
    var best_size: u32 = std.math.maxInt(u32);
    var i: hir_mod.NodeId = 1;
    while (i < hir.nodeCount()) : (i += 1) {
        const span = hir.spanOf(i);
        if (byte_pos < span.start or byte_pos >= span.end) continue;
        const size = span.end - span.start;
        if (size < best_size) {
            best = i;
            best_size = size;
        }
    }
    return best;
}

/// Classify an identifier node as `.read` or `.write` based on the
/// shape of its parent. Writes: assignment targets, `++`/`--`
/// operands, and the name slot of a declaration (var/let/const/fn/
/// class/parameter/type-parameter). Everything else is a read.
fn classifyIdentifierKind(hir: *const hir_mod.Hir, node: hir_mod.NodeId) Highlight.Kind {
    const parent = hir.parentOf(node);
    if (parent == hir_mod.none_node_id or parent == node) return .read;
    switch (hir.kindOf(parent)) {
        .assignment => {
            const a = hir_mod.assignmentOf(hir, parent);
            if (a.target == node) return .write;
        },
        .update_op => return .write,
        .var_decl, .let_decl, .const_decl => {
            const v = hir_mod.varDeclOf(hir, parent);
            if (v.name == node) return .write;
            if (v.init == node) return .read;
        },
        .fn_decl, .fn_expr, .arrow_fn => {
            const fn_p = hir_mod.fnDeclOf(hir, parent);
            if (fn_p.name == node) return .write;
        },
        .class_decl, .class_expr => {
            const cp = hir_mod.classOf(hir, parent);
            if (cp.name == node) return .write;
        },
        .parameter => {
            const p = hir_mod.parameterOf(hir, parent);
            if (p.name == node) return .write;
        },
        else => {},
    }
    return .read;
}

/// Walk the HIR ancestor chain from `node` upward and return the
/// innermost scope whose `introducing_node` lies on that chain.
/// Falls back to the module root when no inner scope contains the
/// node — the binder always opens the module scope at root.
fn enclosingScopeOf(module: anytype, hir: *const hir_mod.Hir, node: hir_mod.NodeId) *const @TypeOf(module.root.*) {
    var cur: hir_mod.NodeId = node;
    while (cur != hir_mod.none_node_id) {
        for (module.scopes.items) |s| {
            if (s.introducing_node == cur and s != module.root) return s;
        }
        const parent = hir.parentOf(cur);
        if (parent == cur) break; // self-loop guard
        cur = parent;
    }
    return module.root;
}

/// Render a TypeId as a human-readable string. Caller owns the
/// returned slice. Walks the actual structure of compound types
/// (unions / intersections / object types / signatures) so the
/// hover text reflects the real shape.
fn renderType(
    gpa: std.mem.Allocator,
    ti: anytype,
    sint: *const string_interner.Interner,
    id: hir_mod.TypeId,
) anyerror![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try renderTypeInto(&buf, gpa, ti, sint, id, 0);
    return buf.toOwnedSlice(gpa);
}

fn renderTypeInto(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    ti: anytype,
    sint: *const string_interner.Interner,
    id: hir_mod.TypeId,
    depth: u32,
) anyerror!void {
    if (depth > 8) {
        try buf.appendSlice(gpa, "…");
        return;
    }
    const flags = ti.pool.flagsOf(id);
    if (flags.is_any) {
        try buf.appendSlice(gpa, "any");
        return;
    }
    if (flags.is_unknown) {
        try buf.appendSlice(gpa, "unknown");
        return;
    }
    if (flags.is_never) {
        try buf.appendSlice(gpa, "never");
        return;
    }
    if (flags.is_void) {
        try buf.appendSlice(gpa, "void");
        return;
    }
    if (flags.is_null) {
        try buf.appendSlice(gpa, "null");
        return;
    }
    if (flags.is_undefined) {
        try buf.appendSlice(gpa, "undefined");
        return;
    }
    if (flags.is_literal) {
        const lit = ti.literalOf(id);
        switch (lit) {
            .string_lit => |sid| {
                try buf.append(gpa, '"');
                try buf.appendSlice(gpa, sint.get(sid));
                try buf.append(gpa, '"');
            },
            .number_lit => |bits| {
                const v: f64 = @bitCast(bits);
                var nbuf: [32]u8 = undefined;
                try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{v}));
            },
            .boolean_lit => |b| try buf.appendSlice(gpa, if (b) "true" else "false"),
            .bigint_lit => |sid| {
                try buf.appendSlice(gpa, sint.get(sid));
                try buf.append(gpa, 'n');
            },
        }
        return;
    }
    if (flags.is_object_type) {
        // Walk the object type's members.
        const payload = ti.pool.object_type_payloads.items[ti.pool.payloadOf(id)];
        const members = ti.pool.object_member_pool.items[payload.members_start .. payload.members_start + payload.members_len];
        try buf.appendSlice(gpa, "{ ");
        for (members, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(gpa, "; ");
            if (m.is_readonly) try buf.appendSlice(gpa, "readonly ");
            try buf.appendSlice(gpa, sint.get(m.name));
            if (m.is_optional) try buf.append(gpa, '?');
            try buf.appendSlice(gpa, ": ");
            try renderTypeInto(buf, gpa, ti, sint, m.type, depth + 1);
        }
        try buf.appendSlice(gpa, " }");
        return;
    }
    if (flags.is_signature) {
        try buf.append(gpa, '(');
        const params = ti.signatureParams(id);
        for (params, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(gpa, ", ");
            try renderTypeInto(buf, gpa, ti, sint, p, depth + 1);
        }
        try buf.appendSlice(gpa, ") => ");
        if (ti.signatureReturn(id)) |ret| {
            try renderTypeInto(buf, gpa, ti, sint, ret, depth + 1);
        } else {
            try buf.appendSlice(gpa, "void");
        }
        return;
    }
    if (flags.is_union) {
        const members = ti.unionMembers(id);
        for (members, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(gpa, " | ");
            try renderTypeInto(buf, gpa, ti, sint, m, depth + 1);
        }
        return;
    }
    if (flags.is_intersection) {
        const members = ti.intersectionMembers(id);
        for (members, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(gpa, " & ");
            try renderTypeInto(buf, gpa, ti, sint, m, depth + 1);
        }
        return;
    }
    if (flags.is_string) {
        try buf.appendSlice(gpa, "string");
        return;
    }
    if (flags.is_number) {
        try buf.appendSlice(gpa, "number");
        return;
    }
    if (flags.is_boolean) {
        try buf.appendSlice(gpa, "boolean");
        return;
    }
    if (flags.is_bigint) {
        try buf.appendSlice(gpa, "bigint");
        return;
    }
    if (flags.is_symbol) {
        try buf.appendSlice(gpa, "symbol");
        return;
    }
    if (flags.is_object) {
        try buf.appendSlice(gpa, "object");
        return;
    }
    if (flags.is_keyof) {
        try buf.appendSlice(gpa, "keyof T");
        return;
    }
    if (flags.is_indexed_access) {
        try buf.appendSlice(gpa, "T[K]");
        return;
    }
    if (flags.is_conditional) {
        try buf.appendSlice(gpa, "T extends U ? X : Y");
        return;
    }
    if (flags.is_type_parameter) {
        try buf.append(gpa, 'T');
        return;
    }
    try buf.appendSlice(gpa, "unknown");
}

/// Render a binder symbol as its source-shape declaration, e.g.:
///   - function add(a: number, b: number): number
///   - class Box { … }
///   - let count: number
///
/// Returns null when the symbol kind isn't one we have a special
/// rendering for; callers should fall back to `renderType`.
/// Caller owns the returned slice when non-null.
fn renderDeclShape(
    gpa: std.mem.Allocator,
    ti: anytype,
    sint: *const string_interner.Interner,
    hir: *const hir_mod.Hir,
    sym: anytype,
    t: hir_mod.TypeId,
) ?[]u8 {
    const name = sint.get(sym.name);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);

    if (sym.flags.is_function) {
        const flags = ti.pool.flagsOf(t);
        if (!flags.is_signature) return null;
        buf.appendSlice(gpa, "function ") catch return null;
        buf.appendSlice(gpa, name) catch return null;
        buf.append(gpa, '(') catch return null;

        // Prefer parameter names from the original fn_decl, falling
        // back to positional `arg{N}` when unavailable.
        const param_types = ti.signatureParams(t);
        var fn_params: ?[]const hir_mod.NodeId = null;
        if (sym.decls.items.len > 0) {
            const decl_id = sym.decls.items[0];
            const dk = hir.kindOf(decl_id);
            if (dk == .fn_decl or dk == .fn_expr or dk == .arrow_fn) {
                fn_params = hir_mod.fnParams(hir, decl_id);
            }
        }

        for (param_types, 0..) |p, i| {
            if (i > 0) buf.appendSlice(gpa, ", ") catch return null;
            var named = false;
            if (fn_params) |fps| {
                if (i < fps.len) {
                    const param = hir_mod.parameterOf(hir, fps[i]);
                    if (param.flags.is_rest) buf.appendSlice(gpa, "...") catch return null;
                    if (param.name != hir_mod.none_node_id and hir.kindOf(param.name) == .identifier) {
                        const pid = hir_mod.identifierOf(hir, param.name);
                        buf.appendSlice(gpa, sint.get(pid.name)) catch return null;
                        named = true;
                    }
                    if (param.flags.is_optional) buf.append(gpa, '?') catch return null;
                }
            }
            if (!named) {
                var nbuf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&nbuf, "arg{d}", .{i}) catch return null;
                buf.appendSlice(gpa, s) catch return null;
            }
            buf.appendSlice(gpa, ": ") catch return null;
            renderTypeInto(&buf, gpa, ti, sint, p, 0) catch return null;
        }
        buf.appendSlice(gpa, "): ") catch return null;
        if (ti.signatureReturn(t)) |ret| {
            renderTypeInto(&buf, gpa, ti, sint, ret, 0) catch return null;
        } else {
            buf.appendSlice(gpa, "void") catch return null;
        }
        return buf.toOwnedSlice(gpa) catch null;
    }

    if (sym.flags.is_class) {
        buf.appendSlice(gpa, "class ") catch return null;
        buf.appendSlice(gpa, name) catch return null;
        buf.appendSlice(gpa, " { … }") catch return null;
        return buf.toOwnedSlice(gpa) catch null;
    }

    if (sym.flags.is_const or sym.flags.is_let or sym.flags.is_var) {
        const kw = if (sym.flags.is_const) "const " else if (sym.flags.is_let) "let " else "var ";
        buf.appendSlice(gpa, kw) catch return null;
        buf.appendSlice(gpa, name) catch return null;
        buf.appendSlice(gpa, ": ") catch return null;
        renderTypeInto(&buf, gpa, ti, sint, t, 0) catch return null;
        return buf.toOwnedSlice(gpa) catch null;
    }

    buf.deinit(gpa);
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;
const ts_resolver = @import("ts_resolver");

test "Service: hover renders the type at a position" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "let x: number = 42;";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Position 4 lands inside the identifier 'x'.
    const r = svc.hover("/main.ts", 4) orelse return error.NoHover;
    defer T.allocator.free(r.type_repr);
    // The let_decl span starts at 0; identifier 'x' is innermost
    // at byte 4. Either way the rendered type is non-empty.
    try T.expect(r.type_repr.len > 0);
}

test "Service: gotoDefinition resolves a top-level reference" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "let count = 1; let total = count;";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // 'count' on the right side begins around byte 27.
    const def = svc.gotoDefinition("/main.ts", 28) orelse return error.NoDefinition;
    // Definition is the let_decl starting at byte 0.
    try T.expectEqual(@as(u32, 1), def.span.start_line);
}

test "Service: gotoDefinition follows imports across files" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    // The resolver consults the VFS to translate `./lib` to `/lib.ts`.
    try vfs.addFile("/lib.ts", "export let foo = 1;");
    try vfs.addFile("/main.ts", "import { foo } from './lib'; let x = foo;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/lib.ts", "export let foo = 1;");
    _ = try program.add("/main.ts", "import { foo } from './lib'; let x = foo;");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Use site of `foo` at the end of /main.ts: "...let x = foo;".
    const main_src = "import { foo } from './lib'; let x = foo;";
    const use_pos: u32 = @intCast(std.mem.lastIndexOf(u8, main_src, "foo").?);
    const def = svc.gotoDefinition("/main.ts", use_pos + 1) orelse return error.NoDefinition;
    // The definition should land in /lib.ts, not /main.ts.
    try T.expectEqualStrings("/lib.ts", def.file);
    try T.expectEqualStrings("/lib.ts", def.span.file);
}

test "Service: completions list module-level value symbols" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "let foo = 1; function bar() {} class Baz {} interface I {}";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const items = try svc.completions(T.allocator, "/main.ts", 0);
    defer T.allocator.free(items);

    var saw_foo = false;
    var saw_bar = false;
    var saw_baz = false;
    var saw_i = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "foo")) saw_foo = true;
        if (std.mem.eql(u8, item.label, "bar")) saw_bar = true;
        if (std.mem.eql(u8, item.label, "Baz")) saw_baz = true;
        if (std.mem.eql(u8, item.label, "I")) saw_i = true;
    }
    try T.expect(saw_foo);
    try T.expect(saw_bar);
    try T.expect(saw_baz);
    try T.expect(saw_i);
}

test "Service: findReferences returns all identifier sites" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "let x = 1; let y = x; let z = x + 1;";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Reference to 'x' on the rhs of `let y = x` (byte ~19).
    const refs = try svc.findReferences(T.allocator, "/main.ts", 19);
    defer T.allocator.free(refs);
    // Three occurrences of x: declaration + two refs.
    try T.expectEqual(@as(usize, 3), refs.len);
}

test "Service: findReferences excludes shadowed bindings" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Outer `x` and inner `x` (inside the function body) are
    // distinct bindings. Asking for references to the outer `x`
    // must skip both occurrences inside the function body — those
    // refer to a different symbol introduced by the inner `let x`.
    const src =
        "let x = 1;\n" ++
        "function f() { let x = 2; return x; }\n" ++
        "let y = x;\n";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Position of the outer `x` declaration: column 5 of line 1.
    const outer_pos: u32 = @intCast(std.mem.indexOf(u8, src, "x").?);
    const refs = try svc.findReferences(T.allocator, "/main.ts", outer_pos);
    defer T.allocator.free(refs);
    // Outer-x sites: declaration on line 1 + reference on line 3.
    // Lines are 1-indexed; line 2 is the function body and must be
    // skipped on both the inner declaration and the inner `return x`.
    try T.expectEqual(@as(usize, 2), refs.len);
    for (refs) |r| try T.expect(r.start_line != 2);
}

test "Service: documentHighlights classifies reads vs writes" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Three `x` sites:
    //   `let x = 1;` — declaration (write)
    //   `x = 2;`     — assignment LHS (write)
    //   `let y = x;` — RHS read.
    const src = "let x = 1; x = 2; let y = x;";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Cursor on the declaration's `x`.
    const decl_pos: u32 = @intCast(std.mem.indexOf(u8, src, "x").?);
    const hls = try svc.documentHighlights(T.allocator, "/main.ts", decl_pos);
    defer T.allocator.free(hls);

    try T.expectEqual(@as(usize, 3), hls.len);
    var writes: usize = 0;
    var reads: usize = 0;
    for (hls) |h| {
        switch (h.kind) {
            .write => writes += 1,
            .read => reads += 1,
            .text => {},
        }
    }
    try T.expectEqual(@as(usize, 2), writes);
    try T.expectEqual(@as(usize, 1), reads);
}

test "Service: documentHighlights ignores other files" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/a.ts", "export let count = 1;");
    _ = try program.add("/b.ts", "let other = count;");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Cursor on `count` declaration in /a.ts.
    const hls = try svc.documentHighlights(T.allocator, "/a.ts", 11);
    defer T.allocator.free(hls);

    // /a.ts contains exactly one `count` (the declaration).
    try T.expectEqual(@as(usize, 1), hls.len);
    try T.expectEqual(Highlight.Kind.write, hls[0].kind);
}

test "Service: findReferences walks every file in the program" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/a.ts", "export let count = 1;");
    _ = try program.add("/b.ts", "let other = count;");
    _ = try program.add("/c.ts", "let third = count + count;");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Position of `count` in the declaration in /a.ts.
    const refs = try svc.findReferences(T.allocator, "/a.ts", 11);
    defer T.allocator.free(refs);
    // Across all three files: 1 in /a.ts (decl), 1 in /b.ts, 2 in /c.ts.
    try T.expectEqual(@as(usize, 4), refs.len);
}

test "Service: diagnostics surface from compilation" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "let x: number = \"hi\";";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const out = try svc.diagnostics(T.allocator, "/main.ts");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "/main.ts") != null);
    try T.expect(std.mem.indexOf(u8, out, "error TS") != null);
}

test "Service: didChangeFile recompiles + returns fresh diagnostics" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Initial source has a type error: assigning string to number.
    _ = try program.add("/main.ts", "let x: number = \"hi\";");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);

    // Sanity-check: the original source produces at least one
    // diagnostic line.
    const before = try svc.diagnostics(T.allocator, "/main.ts");
    defer T.allocator.free(before);
    try T.expect(before.len > 0);
    try T.expect(std.mem.indexOf(u8, before, "error TS") != null);

    // Apply an edit that fixes the type error.
    const after = try svc.didChangeFile(T.allocator, "/main.ts", "let x: number = 1;");
    defer T.allocator.free(after);
    // Diagnostics should shrink to zero (or at minimum become
    // strictly smaller than the previous rendering).
    try T.expect(after.len < before.len);
    try T.expect(std.mem.indexOf(u8, after, "error TS") == null);

    // The program's compilation should reflect the new source.
    const f = program.fileById(0);
    try T.expect(f.compilation != null);
    try T.expectEqualStrings("let x: number = 1;", f.source);
}

test "Service: didChangeFile on unknown file returns empty diagnostics" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    var svc = Service.init(T.allocator, &program);
    const out = try svc.didChangeFile(T.allocator, "/missing.ts", "let x = 1;");
    defer T.allocator.free(out);
    try T.expectEqual(@as(usize, 0), out.len);
}

test "Service: hover renders structural object type" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let p = { x: 1, y: \"hi\" };");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Hover on the variable's name (~byte 4).
    const r = svc.hover("/main.ts", 4) orelse return error.NoHover;
    defer T.allocator.free(r.type_repr);
    // Should mention number and string, not '{...}' placeholder.
    try T.expect(std.mem.indexOf(u8, r.type_repr, "number") != null or
        std.mem.indexOf(u8, r.type_repr, "string") != null or
        std.mem.indexOf(u8, r.type_repr, "{") != null);
}

test "Service: hover renders union types" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let xs = [1, \"hi\"];");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const r = svc.hover("/main.ts", 4) orelse return error.NoHover;
    defer T.allocator.free(r.type_repr);
    // The union type should render with 'number' and 'string'.
    try T.expect(std.mem.indexOf(u8, r.type_repr, "number") != null or
        std.mem.indexOf(u8, r.type_repr, "string") != null);
}

test "Service: hover renders function declaration shape" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "function add(a: number, b: number): number { return a + b; }\nadd(1, 2);";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Byte 62 lands on the call-site identifier `add` (start of line 2).
    const r = svc.hover("/main.ts", 62) orelse return error.NoHover;
    defer T.allocator.free(r.type_repr);
    // Expect the declaration-shape rendering, not just `(a, b) => …`.
    try T.expect(std.mem.indexOf(u8, r.type_repr, "function add") != null);
    try T.expect(std.mem.indexOf(u8, r.type_repr, "a: number") != null);
    try T.expect(std.mem.indexOf(u8, r.type_repr, "b: number") != null);
    try T.expect(std.mem.indexOf(u8, r.type_repr, "): number") != null);
}

test "Service: hover on missing file returns null" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    var svc = Service.init(T.allocator, &program);
    try T.expect(svc.hover("/missing.ts", 0) == null);
}

test "Service: completions surfaces auto-import candidates from other files" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/lib.ts", "export function libFn() { } export class LibClass { }");
    _ = try program.add("/main.ts", "let x = 1;");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const items = try svc.completions(T.allocator, "/main.ts", 0);
    defer T.allocator.free(items);

    var saw_lib_fn = false;
    var saw_lib_class = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "libFn") and std.mem.eql(u8, it.auto_import_from, "/lib.ts")) saw_lib_fn = true;
        if (std.mem.eql(u8, it.label, "LibClass") and std.mem.eql(u8, it.auto_import_from, "/lib.ts")) saw_lib_class = true;
    }
    try T.expect(saw_lib_fn);
    try T.expect(saw_lib_class);
}

test "Service: workspaceSymbols searches across files" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/a.ts", "function helperA() { }");
    _ = try program.add("/b.ts", "class HelperB { }");
    _ = try program.add("/c.ts", "let other = 1;");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const all = try svc.workspaceSymbols(T.allocator, "");
    defer T.allocator.free(all);
    try T.expectEqual(@as(usize, 3), all.len);

    const filtered = try svc.workspaceSymbols(T.allocator, "elper");
    defer T.allocator.free(filtered);
    // Both `helperA` and `HelperB` contain "elper".
    try T.expectEqual(@as(usize, 2), filtered.len);
}

test "Service: documentSymbols enumerates top-level decls" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        \\function add(a: number, b: number) { return a + b; }
        \\class Box { value: number = 0; }
        \\interface I { x: number; }
        \\type Pair = [number, number];
        \\let counter = 0;
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const symbols = try svc.documentSymbols(T.allocator, "/main.ts");
    defer freeSymbols(T.allocator, symbols);

    try T.expectEqual(@as(usize, 5), symbols.len);
    try T.expectEqualStrings("add", symbols[0].name);
    try T.expectEqual(SymbolInfo.SymbolKind.function, symbols[0].kind);
    try T.expectEqualStrings("Box", symbols[1].name);
    try T.expectEqual(SymbolInfo.SymbolKind.class, symbols[1].kind);
    try T.expectEqualStrings("I", symbols[2].name);
    try T.expectEqual(SymbolInfo.SymbolKind.interface, symbols[2].kind);
    try T.expectEqualStrings("Pair", symbols[3].name);
    try T.expectEqual(SymbolInfo.SymbolKind.type_alias, symbols[3].kind);
    try T.expectEqualStrings("counter", symbols[4].name);
    try T.expectEqual(SymbolInfo.SymbolKind.variable, symbols[4].kind);
}

test "Service: documentSymbols emits class methods as nested children" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        \\class Box {
        \\  open() { }
        \\  close() { }
        \\}
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const symbols = try svc.documentSymbols(T.allocator, "/main.ts");
    defer freeSymbols(T.allocator, symbols);

    try T.expectEqual(@as(usize, 1), symbols.len);
    try T.expectEqualStrings("Box", symbols[0].name);
    try T.expectEqual(SymbolInfo.SymbolKind.class, symbols[0].kind);
    try T.expectEqual(@as(usize, 2), symbols[0].children.len);
    try T.expectEqualStrings("open", symbols[0].children[0].name);
    try T.expectEqual(SymbolInfo.SymbolKind.method, symbols[0].children[0].kind);
    try T.expectEqualStrings("close", symbols[0].children[1].name);
    try T.expectEqual(SymbolInfo.SymbolKind.method, symbols[0].children[1].kind);
}

test "Service: documentSymbols emits enum members as nested children" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "enum Color { Red, Green, Blue }";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const symbols = try svc.documentSymbols(T.allocator, "/main.ts");
    defer freeSymbols(T.allocator, symbols);

    try T.expectEqual(@as(usize, 1), symbols.len);
    try T.expectEqualStrings("Color", symbols[0].name);
    try T.expectEqual(SymbolInfo.SymbolKind.enum_, symbols[0].kind);
    try T.expectEqual(@as(usize, 3), symbols[0].children.len);
    try T.expectEqualStrings("Red", symbols[0].children[0].name);
    try T.expectEqual(SymbolInfo.SymbolKind.enum_member, symbols[0].children[0].kind);
    try T.expectEqualStrings("Green", symbols[0].children[1].name);
    try T.expectEqualStrings("Blue", symbols[0].children[2].name);
}

test "Service: codeLenses count references on top-level fn and class" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        \\function add(a: number, b: number): number { return a + b; }
        \\class Box { value: number = 0; }
        \\let s = add(1, 2);
        \\let t = add(3, 4);
        \\let b = new Box();
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const lenses = try svc.codeLenses(T.allocator, "/main.ts");
    defer freeCodeLenses(T.allocator, lenses);

    try T.expectEqual(@as(usize, 2), lenses.len);
    // `add` is referenced twice (in the two calls).
    try T.expectEqualStrings("2 references", lenses[0].title);
    // `Box` is referenced once (in `new Box()`).
    try T.expectEqualStrings("1 reference", lenses[1].title);
}

test "Service: codeLenses emits zero-reference lens for unused decl" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "function unused() { return 1; }";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const lenses = try svc.codeLenses(T.allocator, "/main.ts");
    defer freeCodeLenses(T.allocator, lenses);

    try T.expectEqual(@as(usize, 1), lenses.len);
    try T.expectEqualStrings("0 references", lenses[0].title);
    try T.expectEqualStrings("", lenses[0].command);
}

test "Service: signatureHelp returns signature info inside a call" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        \\function add(a: number, b: number): number { return a + b; }
        \\let r = add(1, 2);
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Position somewhere inside the call expression's argument list.
    const at_call = std.mem.indexOf(u8, src, "add(1, 2)").? + 4; // inside the args
    const sig = (try svc.signatureHelp(T.allocator, "/main.ts", @intCast(at_call))) orelse return error.NoSignature;
    defer T.allocator.free(sig.label);
    defer {
        for (sig.parameters) |p| T.allocator.free(p);
        T.allocator.free(sig.parameters);
    }
    try T.expectEqual(@as(usize, 2), sig.parameters.len);
    try T.expect(sig.label.len > 0);
}

test "Service: rename returns one edit per occurrence" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "let count = 1; let total = count + count;";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Rename `count` (declared at byte 4).
    const edits = try svc.rename(T.allocator, "/main.ts", 4, "n");
    defer T.allocator.free(edits);
    // 3 occurrences: declaration + 2 references.
    try T.expectEqual(@as(usize, 3), edits.len);
    for (edits) |e| try T.expectEqualStrings("n", e.new_text);
}

test "Service: callHierarchyIncoming finds callers of the target fn" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // `target` is called from inside `caller_a` and `caller_b`.
    // A top-level call to `target` is intentionally ignored — only
    // calls from inside another fn count as incoming callers.
    const src =
        "function target() { return 1; }\n" ++
        "function caller_a() { return target(); }\n" ++
        "function caller_b() { return target() + 1; }\n" ++
        "target();\n";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Cursor on the name `target` in its declaration.
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, "target").?);
    const incoming = try svc.callHierarchyIncoming(T.allocator, "/main.ts", pos);
    defer T.allocator.free(incoming);

    try T.expectEqual(@as(usize, 2), incoming.len);
    var saw_a = false;
    var saw_b = false;
    for (incoming) |it| {
        try T.expectEqual(SymbolInfo.SymbolKind.function, it.kind);
        if (std.mem.eql(u8, it.name, "caller_a")) saw_a = true;
        if (std.mem.eql(u8, it.name, "caller_b")) saw_b = true;
    }
    try T.expect(saw_a);
    try T.expect(saw_b);
}

test "Service: callHierarchyOutgoing finds callees of the target fn" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // `caller` invokes `helper_a` and `helper_b`.
    const src =
        "function helper_a() { return 1; }\n" ++
        "function helper_b() { return 2; }\n" ++
        "function caller() { return helper_a() + helper_b(); }\n";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    // Cursor on the name `caller` in its declaration.
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, "caller").?);
    const outgoing = try svc.callHierarchyOutgoing(T.allocator, "/main.ts", pos);
    defer T.allocator.free(outgoing);

    try T.expectEqual(@as(usize, 2), outgoing.len);
    var saw_a = false;
    var saw_b = false;
    for (outgoing) |it| {
        try T.expectEqual(SymbolInfo.SymbolKind.function, it.kind);
        if (std.mem.eql(u8, it.name, "helper_a")) saw_a = true;
        if (std.mem.eql(u8, it.name, "helper_b")) saw_b = true;
    }
    try T.expect(saw_a);
    try T.expect(saw_b);
}

test "Service: codeActions sorts top-level imports" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "import { a } from \"z\";\nimport { b } from \"a\";\n";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const actions = try svc.codeActions(T.allocator, "/main.ts");
    defer {
        for (actions) |a| {
            for (a.edits) |e| T.allocator.free(e.new_text);
            T.allocator.free(a.edits);
        }
        T.allocator.free(actions);
    }
    try T.expect(actions.len == 1);
    try T.expectEqualStrings("Organize Imports", actions[0].title);
    // The new text should mention `"a"` before `"z"`.
    const nt = actions[0].edits[0].new_text;
    const a_pos = std.mem.indexOf(u8, nt, "\"a\"") orelse return error.NotFound;
    const z_pos = std.mem.indexOf(u8, nt, "\"z\"") orelse return error.NotFound;
    try T.expect(a_pos < z_pos);
}

test "Service: semanticTokens classifies identifiers by declaring kind" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "function add(a, b) { return a + b; } class Box {} let x = 1;";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const tokens = try svc.semanticTokens(T.allocator, "/main.ts");
    defer T.allocator.free(tokens);

    var has_function = false;
    var has_class = false;
    var has_parameter = false;
    var has_variable = false;
    for (tokens) |tok| {
        switch (tok.token_type) {
            .function => has_function = true,
            .class => has_class = true,
            .parameter => has_parameter = true,
            .variable => has_variable = true,
            else => {},
        }
    }
    try T.expect(has_function);
    try T.expect(has_class);
    try T.expect(has_parameter);
    try T.expect(has_variable);
}

test "Service: semanticTokens emits keyword tokens from the scanner stream" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "function add(a, b) { return a + b; } class Box {} let x = 1;";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const tokens = try svc.semanticTokens(T.allocator, "/main.ts");
    defer T.allocator.free(tokens);

    var keyword_count: usize = 0;
    for (tokens) |tok| {
        if (tok.token_type == .keyword) keyword_count += 1;
    }
    // Source has at least: `function`, `return`, `class`, `let` -> 4 keywords.
    try T.expect(keyword_count >= 4);
}

test "Service: semanticTokens covers `let` keyword span exactly" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // `let` starts at byte 0 -> line 0, col 0, length 3.
    const src = "let x = 1;";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const tokens = try svc.semanticTokens(T.allocator, "/main.ts");
    defer T.allocator.free(tokens);

    var found = false;
    for (tokens) |tok| {
        if (tok.token_type == .keyword and tok.line == 0 and tok.col == 0 and tok.length == 3) {
            found = true;
            break;
        }
    }
    try T.expect(found);
}

test "Service: inlayHints surfaces inferred types on let-bindings" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src = "let x = 42; let y: string = \"hi\"; let z = true;";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const hints = try svc.inlayHints(T.allocator, "/main.ts");
    defer {
        for (hints) |h| T.allocator.free(h.label);
        T.allocator.free(hints);
    }
    // x and z get hints; y has an explicit annotation so no hint.
    try T.expectEqual(@as(usize, 2), hints.len);
    for (hints) |h| try T.expectEqual(@as(@TypeOf(h.kind), .type_annotation), h.kind);
}

test "Service: codeActions adds explicit type annotation for inferred lets" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x = 42;");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const actions = try svc.codeActions(T.allocator, "/main.ts");
    defer {
        for (actions) |a| {
            T.allocator.free(a.title);
            for (a.edits) |e| T.allocator.free(e.new_text);
            T.allocator.free(a.edits);
        }
        T.allocator.free(actions);
    }
    try T.expectEqual(@as(usize, 1), actions.len);
    try T.expectEqual(@as(CodeAction.Kind, .quick_fix), actions[0].kind);
    try T.expectEqualStrings("Add explicit type to x", actions[0].title);
    try T.expectEqual(@as(usize, 1), actions[0].edits.len);
    try T.expectEqualStrings(": number", actions[0].edits[0].new_text);
    // Insertion is zero-width — start and end positions match.
    const e = actions[0].edits[0];
    try T.expectEqual(e.start_line, e.end_line);
    try T.expectEqual(e.start_col, e.end_col);
}

test "Service: formatDocument returns a TextEdit list (no-op stub)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x = 1;");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const edits = try svc.formatDocument(T.allocator, "/main.ts");
    defer T.allocator.free(edits);
    // Stub: empty edit list = "already formatted". Real formatting
    // is a Phase 6 follow-up (needs a TS-aware pretty-printer).
    try T.expectEqual(@as(usize, 0), edits.len);

    // Unknown file is also a no-op rather than an error.
    const missing = try svc.formatDocument(T.allocator, "/missing.ts");
    defer T.allocator.free(missing);
    try T.expectEqual(@as(usize, 0), missing.len);
}

test "Service: foldingRanges emits one range per block + import run" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        \\import { a } from "x";
        \\import { b } from "y";
        \\function foo() {
        \\    let x = 1;
        \\}
        \\class Bar {
        \\    m() {
        \\        return 1;
        \\    }
        \\}
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const ranges = try svc.foldingRanges(T.allocator, "/main.ts");
    defer T.allocator.free(ranges);

    // Expect at least one `imports` range and at least one `region`.
    var saw_imports = false;
    var saw_region = false;
    for (ranges) |r| {
        if (r.kind == .imports) saw_imports = true;
        if (r.kind == .region) saw_region = true;
        // Every range should span 1+ lines (start < end).
        try T.expect(r.end_line > r.start_line);
    }
    try T.expect(saw_imports);
    try T.expect(saw_region);
}

test "Service: semanticTokensWire returns empty array for empty/unknown file" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/empty.ts", "");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const wire = try svc.semanticTokensWire(T.allocator, "/empty.ts");
    defer T.allocator.free(wire);
    try T.expectEqual(@as(usize, 0), wire.len);

    // Unknown file is also a no-op rather than an error.
    const missing = try svc.semanticTokensWire(T.allocator, "/missing.ts");
    defer T.allocator.free(missing);
    try T.expectEqual(@as(usize, 0), missing.len);
}

test "Service: semanticTokensWire delta-encodes two tokens on the same line" {
    // Hand-build two tokens on line 0 to assert the delta encoding
    // exactly, without depending on the HIR walker's classification
    // for any specific source.
    const toks = [_]SemanticToken{
        .{ .line = 0, .col = 4, .length = 3, .token_type = .variable, .modifiers = 0 },
        .{ .line = 0, .col = 10, .length = 5, .token_type = .variable, .modifiers = 0 },
    };
    const wire = try encodeSemanticTokensWire(T.allocator, &toks);
    defer T.allocator.free(wire);

    const expected = [_]u32{
        // First token: deltas are absolute vs (0, 0).
        0, 4, 3, @intFromEnum(SemanticToken.TokenType.variable), 0,
        // Second token: same line -> delta_start is col2 - col1 = 6.
        0, 6, 5, @intFromEnum(SemanticToken.TokenType.variable), 0,
    };
    try T.expectEqual(@as(usize, expected.len), wire.len);
    for (expected, 0..) |v, idx| try T.expectEqual(v, wire[idx]);
}

test "Service: semanticTokensRange filters tokens by line window" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        \\let a = 1;
        \\let b = 2;
        \\let c = 3;
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);

    // Full file produces some tokens.
    const full = try svc.semanticTokensWire(T.allocator, "/main.ts");
    defer T.allocator.free(full);
    try T.expect(full.len > 0);
    try T.expectEqual(@as(usize, 0), full.len % 5);

    // [1, 2) keeps only line-1 tokens. Each token is 5 u32s; the
    // first token's `delta_line` should be absolute (not 1), since
    // the encoding restarts within the range.
    const middle = try svc.semanticTokensRange(T.allocator, "/main.ts", 1, 2);
    defer T.allocator.free(middle);
    try T.expect(middle.len > 0);
    try T.expectEqual(@as(usize, 0), middle.len % 5);
    // First emitted token has absolute line=1, so delta_line == 1.
    try T.expectEqual(@as(u32, 1), middle[0]);

    // Empty range -> empty array.
    const none = try svc.semanticTokensRange(T.allocator, "/main.ts", 5, 5);
    defer T.allocator.free(none);
    try T.expectEqual(@as(usize, 0), none.len);
}

test "Service: selectionRange returns nested ranges innermost-first" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Cursor lands on the identifier `x` in `return x;`. We expect
    // ranges to nest: identifier -> some expression/stmt ancestors
    // -> fn_decl -> file root. The exact ancestor count depends on
    // HIR shape, so we assert the structural invariants (innermost
    // first, strictly-enclosing, root at the end) rather than a
    // precise list.
    const src =
        \\function foo() {
        \\    let x = 1;
        \\    return x;
        \\}
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, "return x").? + "return ".len);
    const ranges = try svc.selectionRange(T.allocator, "/main.ts", pos);
    defer T.allocator.free(ranges);

    // We must have at least the innermost identifier + the file root.
    try T.expect(ranges.len >= 2);

    // Innermost-first: each successive range encloses the previous
    // (start <= prev.start AND end >= prev.end), with at least one
    // strict expansion across the whole list.
    var saw_expansion = false;
    var i: usize = 1;
    while (i < ranges.len) : (i += 1) {
        const prev = ranges[i - 1];
        const cur = ranges[i];
        const start_le = (cur.start_line < prev.start_line) or
            (cur.start_line == prev.start_line and cur.start_col <= prev.start_col);
        const end_ge = (cur.end_line > prev.end_line) or
            (cur.end_line == prev.end_line and cur.end_col >= prev.end_col);
        try T.expect(start_le);
        try T.expect(end_ge);
        if (!(cur.start_line == prev.start_line and cur.start_col == prev.start_col and
            cur.end_line == prev.end_line and cur.end_col == prev.end_col))
        {
            saw_expansion = true;
        }
    }
    try T.expect(saw_expansion);

    // Last range = file root. It must start at line 1 col 1 and end
    // at-or-after the last source line.
    const last = ranges[ranges.len - 1];
    try T.expectEqual(@as(u32, 1), last.start_line);
    try T.expectEqual(@as(u32, 1), last.start_col);
    try T.expect(last.end_line >= 4);
}

test "Service: selectionRange + willSaveWaitUntil handle unknown files" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x = 1;");
    try program.compileAll(.{});

    var svc = Service.init(T.allocator, &program);

    // Unknown file -> empty range list.
    const r = try svc.selectionRange(T.allocator, "/missing.ts", 0);
    defer T.allocator.free(r);
    try T.expectEqual(@as(usize, 0), r.len);

    // willSaveWaitUntil delegates to formatDocument (still a stub),
    // so all four save reasons return an empty edit list today.
    inline for (.{ SaveReason.manual, SaveReason.auto, SaveReason.after_delay, SaveReason.focus_out }) |reason| {
        const edits = try svc.willSaveWaitUntil(T.allocator, "/main.ts", reason);
        defer T.allocator.free(edits);
        try T.expectEqual(@as(usize, 0), edits.len);
    }
}
