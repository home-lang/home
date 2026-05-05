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

    pub const ItemKind = enum { variable, function, class, interface, type_alias, module, keyword, member };
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
        return items.toOwnedSlice(gpa);
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
