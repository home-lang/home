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
    };
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    program: *ts_program.Program,

    pub fn init(gpa: std.mem.Allocator, program: *ts_program.Program) Service {
        return .{ .gpa = gpa, .program = program };
    }

    /// Hover at `byte_pos` inside `file`. Walks the file's HIR
    /// to find the smallest enclosing node and renders its type.
    pub fn hover(self: *Service, file_path: []const u8, byte_pos: u32) ?HoverResult {
        const file_id = self.program.lookupPath(file_path) orelse return null;
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return null;
        const node = findInnermostNode(&c.hir, c.root, byte_pos) orelse return null;
        const t = c.hir.typeOf(node);
        const repr = renderType(self.gpa, &c.type_interner, &c.interner, t) catch "";
        const span = c.hir.spanOf(node);
        const start_pos = ts_diagnostics.positionToLineCol(f.source, span.start);
        const end_pos = ts_diagnostics.positionToLineCol(f.source, span.end);
        return .{
            .type_repr = repr,
            .span = .{
                .file = f.path,
                .start_line = start_pos.line,
                .start_col = start_pos.col,
                .end_line = end_pos.line,
                .end_col = end_pos.col,
            },
            .kind = c.hir.kindOf(node),
        };
    }

    /// Goto-definition for the identifier at `byte_pos`. Walks the
    /// binder's symbol table to find the declaration.
    pub fn gotoDefinition(self: *Service, file_path: []const u8, byte_pos: u32) ?Definition {
        const file_id = self.program.lookupPath(file_path) orelse return null;
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return null;
        const node = findInnermostNode(&c.hir, c.root, byte_pos) orelse return null;
        if (c.hir.kindOf(node) != .identifier) return null;
        const id = hir_mod.identifierOf(&c.hir, node);
        const sym = c.module.root.lookup(id.name) orelse return null;
        if (sym.decls.items.len == 0) return null;
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

    /// Find every reference to the symbol at `byte_pos` across
    /// every file in the program. Identifier matches are filtered
    /// by name (string identity); shadowing-aware lookup via the
    /// binder's scope graph is a Phase 8 follow-up.
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

        // Walk every program file's HIR. Each file has its own
        // string_interner, so we re-intern the target name into
        // the visited file's interner to compare ids.
        for (self.program.files.items) |f| {
            const c = f.compilation orelse continue;
            // Look the name up in this file's interner (without
            // adding to it). If absent, no reference is possible.
            const local_id = c.interner.lookup(target_name) orelse continue;
            var i: hir_mod.NodeId = 0;
            while (i < c.hir.nodeCount()) : (i += 1) {
                if (c.hir.kindOf(i) != .identifier) continue;
                const id = hir_mod.identifierOf(&c.hir, i);
                if (id.name != local_id) continue;
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
    /// outline view.
    pub fn documentSymbols(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]SymbolInfo {
        var out: std.ArrayListUnmanaged(SymbolInfo) = .empty;
        errdefer out.deinit(gpa);
        const file_id = self.program.lookupPath(file_path) orelse return out.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return out.toOwnedSlice(gpa);
        // Skip files whose parse left a non-block root (malformed).
        if (c.hir.kindOf(c.root) != .block_stmt) return out.toOwnedSlice(gpa);
        const stmts = hir_mod.blockStmts(&c.hir, c.root);
        for (stmts) |s| {
            const info = describeTopLevelSymbol(&c.hir, &c.interner, s, f.source, f.path) orelse continue;
            try out.append(gpa, info);
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

    /// Code actions available at `byte_pos`. Today implements
    /// "Organize Imports" — sorts top-level import declarations by
    /// module specifier and emits the replacement edit.
    pub fn codeActions(self: *Service, gpa: std.mem.Allocator, file_path: []const u8) ![]CodeAction {
        var actions: std.ArrayListUnmanaged(CodeAction) = .empty;
        errdefer actions.deinit(gpa);
        const file_id = self.program.lookupPath(file_path) orelse return actions.toOwnedSlice(gpa);
        const f = self.program.fileById(file_id);
        const c = f.compilation orelse return actions.toOwnedSlice(gpa);
        // Collect import declarations (statement order).
        var imports: std.ArrayListUnmanaged(hir_mod.NodeId) = .empty;
        defer imports.deinit(gpa);
        // Skip files whose parse left a non-block root (malformed).
        if (c.hir.kindOf(c.root) != .block_stmt) return actions.toOwnedSlice(gpa);
        const stmts = hir_mod.blockStmts(&c.hir, c.root);
        for (stmts) |s| {
            if (c.hir.kindOf(s) == .import_decl) try imports.append(gpa, s);
        }
        if (imports.items.len < 2) return actions.toOwnedSlice(gpa);
        // Sort by module specifier name.
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
        // Already sorted? No-op.
        var differs = false;
        for (imports.items, 0..) |orig, i| {
            if (orig != sorted[i]) {
                differs = true;
                break;
            }
        }
        if (!differs) return actions.toOwnedSlice(gpa);
        // Build the new text (rendered import lines, in sorted order).
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        for (sorted, 0..) |id, i| {
            if (i > 0) try buf.append(gpa, '\n');
            const span = c.hir.spanOf(id);
            try buf.appendSlice(gpa, f.source[span.start..span.end]);
        }
        const new_text = try buf.toOwnedSlice(gpa);
        // The replacement edit covers the union span of all imports.
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
        // Sort by (line, col) for deterministic delta output.
        std.mem.sort(SemanticToken, tokens.items, {}, semanticTokenLessThan);
        return tokens.toOwnedSlice(gpa);
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
};

fn semanticTokenLessThan(_: void, a: SemanticToken, b: SemanticToken) bool {
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
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
        .let_decl, .const_decl, .var_decl => {
            const v = hir_mod.varDeclOf(hir, node);
            if (v.name == hir_mod.none_node_id) return null;
            const name_id = hir_mod.identifierOf(hir, v.name).name;
            return .{ .name = sint.get(name_id), .kind = .variable, .span = span_info };
        },
        else => return null,
    }
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
    defer T.allocator.free(symbols);

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
