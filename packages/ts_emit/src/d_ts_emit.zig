//! `.d.ts` declaration emitter — Phase 4 of TS_PARITY_PLAN.
//!
//! Symbol-driven track: walks the bound module and emits a
//! declaration-only TypeScript file matching tsc's behavior.
//! All implementation details (function bodies, statement-level
//! code, internal types) are stripped; only the public type
//! surface remains.
//!
//! Phase 4 ships the emit foundations. The fast track (Phase 4
//! follow-up) will integrate `zig-dtsx` (vendored as a submodule)
//! for the `isolatedDeclarations` cases where re-printing from
//! the symbol table is unnecessary.
//!
//! Coverage today:
//!   - `function name(p: T): U;` — body stripped, signature kept
//!   - `class Name { … }` — body stripped to declared properties +
//!     method signatures (no implementations)
//!   - `interface Name { … }` — pass-through (already declarations)
//!   - `type Alias = T;` — pass-through
//!   - `enum Name { … }` — pass-through (declarations are
//!     identical in .d.ts and .ts)
//!   - `namespace Name { … }` — recursively walk body, emit
//!     declarations
//!   - `let/const/var x: T;` — annotation kept, initializer dropped
//!   - imports/exports passed through (modulo runtime side effects)

const std = @import("std");
const hir_mod = @import("hir");
const string_interner = @import("string_interner");
const ts_checker = @import("ts_checker");

pub const NodeId = hir_mod.NodeId;
pub const Hir = hir_mod.Hir;

pub const Options = struct {
    indent: []const u8 = "  ",
    newline: []const u8 = "\n",
    max_inferred_type_serialization_len: usize = 1_000_000,
};

pub const Diagnostic = struct {
    node: NodeId,
    code: u32,
    message: []const u8,
};

pub const EmitError = error{
    OutOfMemory,
    UnsupportedNode,
};

pub const Emitter = struct {
    gpa: std.mem.Allocator,
    hir: *const Hir,
    interner: *const string_interner.Interner,
    /// Optional type interner — when set, the emitter renders
    /// inferred types (e.g. a function's checker-derived return
    /// type when no annotation was supplied) into the .d.ts output.
    /// Without it the emitter falls back to skipping unannotated
    /// types, matching the old behavior.
    type_interner: ?*const ts_checker.Interner = null,
    out: std.ArrayListUnmanaged(u8),
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    options: Options,
    depth: u32,

    pub fn init(
        gpa: std.mem.Allocator,
        hir: *const Hir,
        interner: *const string_interner.Interner,
        options: Options,
    ) Emitter {
        return .{
            .gpa = gpa,
            .hir = hir,
            .interner = interner,
            .type_interner = null,
            .out = .empty,
            .diagnostics = .empty,
            .options = options,
            .depth = 0,
        };
    }

    /// Constructor variant that also wires the type interner so
    /// inferred return types can be rendered.
    pub fn initWithTypes(
        gpa: std.mem.Allocator,
        hir: *const Hir,
        interner: *const string_interner.Interner,
        type_interner: *const ts_checker.Interner,
        options: Options,
    ) Emitter {
        return .{
            .gpa = gpa,
            .hir = hir,
            .interner = interner,
            .type_interner = type_interner,
            .out = .empty,
            .diagnostics = .empty,
            .options = options,
            .depth = 0,
        };
    }

    pub fn deinit(self: *Emitter) void {
        for (self.diagnostics.items) |d| self.gpa.free(d.message);
        self.diagnostics.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }

    pub fn toOwnedSlice(self: *Emitter) ![]u8 {
        return self.out.toOwnedSlice(self.gpa);
    }

    fn write(self: *Emitter, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }

    fn indent(self: *Emitter) !void {
        var i: u32 = 0;
        while (i < self.depth) : (i += 1) try self.write(self.options.indent);
    }

    pub fn emitSourceFile(self: *Emitter, root: NodeId) !void {
        const stmts = hir_mod.blockStmts(self.hir, root);
        var first = true;
        for (stmts) |s| {
            if (!self.shouldEmit(s)) continue;
            if (!first) try self.write(self.options.newline);
            first = false;
            try self.emitDeclaration(s);
        }
        if (!first) try self.write(self.options.newline);
    }

    fn shouldEmit(self: *const Emitter, node: NodeId) bool {
        return switch (self.hir.kindOf(node)) {
            .fn_decl,
            .class_decl,
            .interface_decl,
            .type_alias_decl,
            .enum_decl,
            .namespace_decl,
            .var_decl,
            .let_decl,
            .const_decl,
            .import_decl,
            .export_decl,
            => true,
            else => false,
        };
    }

    fn emitDeclaration(self: *Emitter, node: NodeId) anyerror!void {
        try self.indent();
        switch (self.hir.kindOf(node)) {
            .fn_decl => try self.emitFn(node, true),
            .class_decl => try self.emitClass(node),
            .interface_decl => try self.emitInterface(node),
            .type_alias_decl => try self.emitTypeAlias(node),
            .enum_decl => try self.emitEnum(node),
            .namespace_decl => try self.emitNamespace(node),
            .var_decl, .let_decl, .const_decl => try self.emitVarDecl(node),
            .import_decl => try self.emitImport(node),
            .export_decl => try self.emitExport(node),
            else => {},
        }
    }

    fn emitFn(self: *Emitter, node: NodeId, top_level: bool) !void {
        const f = hir_mod.fnDeclOf(self.hir, node);
        if (top_level) try self.write("declare function ");
        if (f.name != hir_mod.none_node_id) try self.emitIdentifier(f.name);
        try self.write("(");
        const params = hir_mod.fnParams(self.hir, node);
        for (params, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            try self.emitParameter(p);
        }
        try self.write(")");
        if (f.return_type != hir_mod.none_node_id) {
            try self.write(": ");
            try self.emitTypeNode(f.return_type);
        } else if (try self.renderInferredReturn(node, f.name)) |rendered| {
            defer self.gpa.free(rendered);
            try self.write(": ");
            try self.write(rendered);
        }
        try self.write(";");
    }

    /// If a type interner is available and the function's HIR node
    /// has a checker-assigned signature TypeId, render its return
    /// type. Returns null when the type interner is absent or the
    /// node lacks a usable signature.
    fn renderInferredReturn(self: *Emitter, node: NodeId, name_node: NodeId) !?[]u8 {
        const ti = self.type_interner orelse return null;
        const t = self.hir.typeOf(node);
        if (t == 0) return null;
        if (!ti.pool.flagsOf(t).is_signature) return null;
        const ret = ti.signatureReturn(t) orelse return null;
        const rendered = ts_checker.renderType(self.gpa, ti, self.interner, ret) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CyclicStructure => {
                try self.reportCyclicStructure(node, name_node);
                return null;
            },
        };
        errdefer self.gpa.free(rendered);
        if (rendered.len > self.options.max_inferred_type_serialization_len) {
            try self.reportInferredTypeTooLong(node);
            self.gpa.free(rendered);
            return null;
        }
        return rendered;
    }

    fn reportCyclicStructure(self: *Emitter, node: NodeId, name_node: NodeId) !void {
        const name = if (name_node != hir_mod.none_node_id and self.hir.kindOf(name_node) == .identifier)
            self.interner.get(hir_mod.identifierOf(self.hir, name_node).name)
        else
            "(Missing)";
        const message = try std.fmt.allocPrint(
            self.gpa,
            "The inferred type of '{s}' references a type with a cyclic structure which cannot be trivially serialized. A type annotation is necessary.",
            .{name},
        );
        errdefer self.gpa.free(message);
        try self.diagnostics.append(self.gpa, .{
            .node = node,
            .code = 5088,
            .message = message,
        });
    }

    fn reportInferredTypeTooLong(self: *Emitter, node: NodeId) !void {
        const message = try self.gpa.dupe(u8, "The inferred type of this node exceeds the maximum length the compiler will serialize. An explicit type annotation is needed.");
        errdefer self.gpa.free(message);
        try self.diagnostics.append(self.gpa, .{
            .node = node,
            .code = 7056,
            .message = message,
        });
    }

    fn emitParameter(self: *Emitter, node: NodeId) !void {
        const p = hir_mod.parameterOf(self.hir, node);
        if (p.flags.is_computed_binding_key) return;
        if (p.flags.is_rest) try self.write("...");
        if (p.name != hir_mod.none_node_id) try self.emitIdentifier(p.name);
        if (p.flags.is_optional) try self.write("?");
        if (p.type_annotation != hir_mod.none_node_id) {
            try self.write(": ");
            try self.emitTypeNode(p.type_annotation);
        }
    }

    fn emitClass(self: *Emitter, node: NodeId) !void {
        const c = hir_mod.classOf(self.hir, node);
        try self.write("declare class ");
        if (c.name != hir_mod.none_node_id) try self.emitIdentifier(c.name);
        if (c.extends != hir_mod.none_node_id) {
            try self.write(" extends ");
            try self.emitExpressionAsRef(c.extends);
        }
        try self.write(" {");
        const members = hir_mod.classMembers(self.hir, node);
        if (members.len == 0) {
            try self.write("}");
            return;
        }
        self.depth += 1;
        for (members) |m| {
            try self.write(self.options.newline);
            try self.indent();
            switch (self.hir.kindOf(m)) {
                .fn_decl, .fn_expr, .arrow_fn => try self.emitFn(m, false),
                .object_property => {
                    const op = hir_mod.objectPropertyOf(self.hir, m);
                    try self.emitIdentifier(op.key);
                    if (op.type_annotation != hir_mod.none_node_id) {
                        try self.write(": ");
                        try self.emitTypeNode(op.type_annotation);
                    }
                    try self.write(";");
                },
                else => {},
            }
        }
        self.depth -= 1;
        try self.write(self.options.newline);
        try self.indent();
        try self.write("}");
    }

    fn emitInterface(self: *Emitter, node: NodeId) !void {
        const i = hir_mod.interfaceOf(self.hir, node);
        try self.write("interface ");
        try self.emitIdentifier(i.name);
        try self.write(" {");
        const members = hir_mod.interfaceMembers(self.hir, node);
        if (members.len == 0) {
            try self.write("}");
            return;
        }
        self.depth += 1;
        for (members) |m| {
            try self.write(self.options.newline);
            try self.indent();
            try self.emitInterfaceMember(m);
        }
        self.depth -= 1;
        try self.write(self.options.newline);
        try self.indent();
        try self.write("}");
    }

    fn emitInterfaceMember(self: *Emitter, node: NodeId) !void {
        if (self.hir.kindOf(node) != .interface_member) return;
        const m = hir_mod.interfaceMemberOf(self.hir, node);
        if (m.is_readonly) try self.write("readonly ");
        try self.write(self.interner.get(m.name));
        if (m.is_optional) try self.write("?");
        if (m.type_node != hir_mod.none_node_id) {
            try self.write(": ");
            try self.emitTypeNode(m.type_node);
        }
        try self.write(";");
    }

    fn emitTypeAlias(self: *Emitter, node: NodeId) !void {
        const t = hir_mod.typeAliasOf(self.hir, node);
        try self.write("type ");
        try self.emitIdentifier(t.name);
        try self.write(" = ");
        if (t.aliased != hir_mod.none_node_id) {
            try self.emitTypeNode(t.aliased);
        } else {
            try self.write("unknown");
        }
        try self.write(";");
    }

    fn emitEnum(self: *Emitter, node: NodeId) !void {
        const e = hir_mod.enumOf(self.hir, node);
        try self.write("declare enum ");
        try self.emitIdentifier(e.name);
        try self.write(" {");
        const members = hir_mod.enumMembers(self.hir, node);
        if (members.len == 0) {
            try self.write("}");
            return;
        }
        self.depth += 1;
        for (members) |m| {
            try self.write(self.options.newline);
            try self.indent();
            if (self.hir.kindOf(m) == .object_property) {
                const op = hir_mod.objectPropertyOf(self.hir, m);
                try self.emitIdentifier(op.key);
                try self.write(",");
            }
        }
        self.depth -= 1;
        try self.write(self.options.newline);
        try self.indent();
        try self.write("}");
    }

    fn emitNamespace(self: *Emitter, node: NodeId) !void {
        const n = hir_mod.namespaceOf(self.hir, node);
        try self.write("declare namespace ");
        try self.emitIdentifier(n.name);
        try self.write(" {");
        const body = hir_mod.namespaceBody(self.hir, node);
        if (body.len == 0) {
            try self.write("}");
            return;
        }
        self.depth += 1;
        for (body) |s| {
            if (!self.shouldEmit(s)) continue;
            try self.write(self.options.newline);
            try self.emitDeclaration(s);
        }
        self.depth -= 1;
        try self.write(self.options.newline);
        try self.indent();
        try self.write("}");
    }

    fn emitVarDecl(self: *Emitter, node: NodeId) !void {
        const v = hir_mod.varDeclOf(self.hir, node);
        const kw: []const u8 = switch (self.hir.kindOf(node)) {
            .var_decl => "declare var ",
            .let_decl => "declare let ",
            .const_decl => "declare const ",
            else => unreachable,
        };
        try self.write(kw);
        if (v.name != hir_mod.none_node_id) try self.emitIdentifier(v.name);
        if (v.type_annotation != hir_mod.none_node_id) {
            try self.write(": ");
            try self.emitTypeNode(v.type_annotation);
        }
        try self.write(";");
    }

    fn emitImport(self: *Emitter, node: NodeId) !void {
        const imp = hir_mod.importOf(self.hir, node);
        try self.write("import ");
        if (imp.is_type_only) try self.write("type ");
        var any = false;
        if (imp.default_binding != hir_mod.none_node_id) {
            try self.emitIdentifier(imp.default_binding);
            any = true;
        }
        if (imp.namespace_binding != hir_mod.none_node_id) {
            if (any) try self.write(", ");
            try self.write("* as ");
            try self.emitIdentifier(imp.namespace_binding);
            any = true;
        }
        const named = hir_mod.importNamed(self.hir, node);
        if (named.len > 0) {
            if (any) try self.write(", ");
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
            any = true;
        }
        if (any) try self.write(" from ");
        try self.write("\"");
        try self.write(self.interner.get(imp.module));
        try self.write("\";");
    }

    fn emitExport(self: *Emitter, node: NodeId) !void {
        const ex = hir_mod.exportOf(self.hir, node);
        try self.write("export ");
        if (ex.is_default) try self.write("default ");
        if (ex.decl != hir_mod.none_node_id) {
            try self.emitDeclarationInline(ex.decl);
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
        const m = self.interner.get(ex.module);
        if (m.len > 0) {
            try self.write(" from \"");
            try self.write(m);
            try self.write("\"");
        }
        try self.write(";");
    }

    /// Emit the inner declaration of an `export <decl>` form
    /// without the leading indent (the caller already wrote
    /// "export ").
    fn emitDeclarationInline(self: *Emitter, node: NodeId) !void {
        switch (self.hir.kindOf(node)) {
            .fn_decl => try self.emitFn(node, true),
            .class_decl => try self.emitClass(node),
            .interface_decl => try self.emitInterface(node),
            .type_alias_decl => try self.emitTypeAlias(node),
            .enum_decl => try self.emitEnum(node),
            .var_decl, .let_decl, .const_decl => try self.emitVarDecl(node),
            else => {},
        }
    }

    fn emitIdentifier(self: *Emitter, node: NodeId) !void {
        if (self.hir.kindOf(node) != .identifier) return;
        const id = hir_mod.identifierOf(self.hir, node);
        try self.write(self.interner.get(id.name));
    }

    /// Emit an HIR type node back as TypeScript syntax.
    fn emitTypeNode(self: *Emitter, node: NodeId) anyerror!void {
        switch (self.hir.kindOf(node)) {
            .type_ref => {
                const r = hir_mod.typeRefOf(self.hir, node);
                const qualifier = hir_mod.typeRefQualifier(self.hir, node);
                for (qualifier) |q| {
                    try self.emitIdentifier(q);
                    try self.write(".");
                }
                try self.write(self.interner.get(r.name));
                const args = hir_mod.typeRefArgs(self.hir, node);
                if (args.len > 0) {
                    try self.write("<");
                    for (args, 0..) |a, i| {
                        if (i > 0) try self.write(", ");
                        try self.emitTypeNode(a);
                    }
                    try self.write(">");
                }
            },
            .union_type => {
                const members = hir_mod.unionTypeMembers(self.hir, node);
                for (members, 0..) |m, i| {
                    if (i > 0) try self.write(" | ");
                    try self.emitTypeNode(m);
                }
            },
            .intersection_type => {
                const members = hir_mod.intersectionTypeMembers(self.hir, node);
                for (members, 0..) |m, i| {
                    if (i > 0) try self.write(" & ");
                    try self.emitTypeNode(m);
                }
            },
            .array_type => {
                const a = hir_mod.arrayTypeOf(self.hir, node);
                try self.emitTypeNode(a.element);
                try self.write("[]");
            },
            .tuple_type => {
                const elems = hir_mod.tupleTypeElements(self.hir, node);
                try self.write("[");
                for (elems, 0..) |e, i| {
                    if (i > 0) try self.write(", ");
                    try self.emitTypeNode(e);
                }
                try self.write("]");
            },
            .keyof_type => {
                const k = hir_mod.keyofTypeOf(self.hir, node);
                try self.write("keyof ");
                try self.emitTypeNode(k.operand);
            },
            .typeof_type => {
                const t = hir_mod.typeofTypeOf(self.hir, node);
                try self.write("typeof ");
                try self.emitIdentifier(t.operand);
            },
            .indexed_access_type => {
                const ia = hir_mod.indexedAccessTypeOf(self.hir, node);
                try self.emitTypeNode(ia.object);
                try self.write("[");
                try self.emitTypeNode(ia.index);
                try self.write("]");
            },
            .conditional_type => {
                const c = hir_mod.conditionalTypeOf(self.hir, node);
                try self.emitTypeNode(c.check);
                try self.write(" extends ");
                try self.emitTypeNode(c.extends);
                try self.write(" ? ");
                try self.emitTypeNode(c.true_branch);
                try self.write(" : ");
                try self.emitTypeNode(c.false_branch);
            },
            .type_literal => {
                const lt = hir_mod.literalTypeOf(self.hir, node);
                if (lt.negative) try self.write("-");
                switch (self.hir.kindOf(lt.literal)) {
                    .literal_string => {
                        const s = hir_mod.literalStringOf(self.hir, lt.literal);
                        try self.write("\"");
                        try self.write(self.interner.get(s.value));
                        try self.write("\"");
                    },
                    .literal_number => {
                        var nbuf: [32]u8 = undefined;
                        const v = hir_mod.literalNumberOf(self.hir, lt.literal);
                        try self.write(try std.fmt.bufPrint(&nbuf, "{d}", .{v}));
                    },
                    .literal_bool => {
                        const v = hir_mod.literalBoolOf(self.hir, lt.literal);
                        try self.write(if (v) "true" else "false");
                    },
                    else => try self.write("unknown"),
                }
            },
            .object_type => {
                const members = hir_mod.objectTypeMembers(self.hir, node);
                try self.write("{ ");
                for (members, 0..) |m, i| {
                    if (i > 0) try self.write(" ");
                    try self.emitInterfaceMember(m);
                }
                try self.write(" }");
            },
            .fn_type, .constructor_type => {
                const ft = hir_mod.fnTypeOf(self.hir, node);
                if (ft.is_constructor) try self.write("new ");
                try self.write("(");
                const params_start = ft.params_start;
                const params_len = ft.params_len;
                var i: u32 = 0;
                while (i < params_len) : (i += 1) {
                    if (i > 0) try self.write(", ");
                    const p = self.hir.child_pool.items[params_start + i];
                    try self.emitParameter(p);
                }
                try self.write(") => ");
                if (ft.return_type != hir_mod.none_node_id) {
                    try self.emitTypeNode(ft.return_type);
                } else {
                    try self.write("void");
                }
            },
            else => try self.write("unknown"),
        }
    }

    /// `extends` clause expression — emit as a type reference.
    fn emitExpressionAsRef(self: *Emitter, node: NodeId) anyerror!void {
        switch (self.hir.kindOf(node)) {
            .identifier => try self.emitIdentifier(node),
            .member_access => {
                const m = hir_mod.memberOf(self.hir, node);
                try self.emitExpressionAsRef(m.object);
                try self.write(".");
                try self.write(self.interner.get(m.name));
            },
            else => try self.write("unknown"),
        }
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
    return s;
}

fn destroySetup(s: *TestSetup) void {
    s.parser.deinit();
    s.tokens.deinit(T.allocator);
    s.scanner.deinit(T.allocator);
    s.hir.deinit();
    s.sint.deinit();
    T.allocator.destroy(s);
}

fn emitTest(source: []const u8) ![]u8 {
    const s = try newSetup(source);
    defer destroySetup(s);
    var em = Emitter.init(T.allocator, &s.hir, &s.sint, .{});
    defer em.deinit();
    try em.emitSourceFile(s.root);
    return T.allocator.dupe(u8, em.out.items);
}

/// Same as `emitTest` but runs the checker first so the d.ts
/// emitter sees inferred return types via the type interner.
fn emitTestTyped(source: []const u8) ![]u8 {
    const s = try newSetup(source);
    defer destroySetup(s);
    var ti = try ts_checker.Interner.init(T.allocator);
    defer ti.deinit();
    var engine = try ts_checker.Engine.init(T.allocator, &ti);
    defer engine.deinit();
    var checker = ts_checker.Checker.init(T.allocator, &s.hir, &ti, &s.sint, &engine);
    defer checker.deinit();
    try checker.checkSourceFile(s.root);
    var em = Emitter.initWithTypes(T.allocator, &s.hir, &s.sint, &ti, .{});
    defer em.deinit();
    try em.emitSourceFile(s.root);
    return T.allocator.dupe(u8, em.out.items);
}

test "d.ts: function strips body" {
    const out = try emitTest("function add(a: number, b: number): number { return a + b; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare function add(a: number, b: number): number;") != null);
    try T.expect(std.mem.indexOf(u8, out, "return") == null);
}

test "d.ts: var with type kept; without dropped value" {
    const out = try emitTest("let x: number = 1;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare let x: number;") != null);
    try T.expect(std.mem.indexOf(u8, out, "= 1") == null);
}

test "d.ts: const decl" {
    const out = try emitTest("const PI: number = 3.14;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare const PI: number;") != null);
}

test "d.ts: type alias kept" {
    const out = try emitTest("type Pair = [number, number];");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "type Pair = [number, number];") != null);
}

test "d.ts: union type alias" {
    const out = try emitTest("type ID = string | number;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "type ID = string | number;") != null);
}

test "d.ts: class declaration with method" {
    const out = try emitTest("class Foo { bar(x: number): string { return \"\"; } }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare class Foo") != null);
    try T.expect(std.mem.indexOf(u8, out, "bar(x: number): string;") != null);
    try T.expect(std.mem.indexOf(u8, out, "return") == null);
}

test "d.ts: class field with annotation emits its type" {
    const out = try emitTest("class Box { value: number = 0; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare class Box") != null);
    try T.expect(std.mem.indexOf(u8, out, "value: number;") != null);
    // Initializer must not leak into the .d.ts.
    try T.expect(std.mem.indexOf(u8, out, "= 0") == null);
}

test "d.ts: enum declaration" {
    const out = try emitTest("enum Color { Red, Green, Blue }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare enum Color") != null);
    try T.expect(std.mem.indexOf(u8, out, "Red,") != null);
}

test "d.ts: imports passed through" {
    const out = try emitTest("import { useState } from \"react\";");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "import { useState } from \"react\";") != null);
}

test "d.ts: export decl" {
    const out = try emitTest("export function id(x: number): number { return x; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "export declare function id(x: number): number;") != null);
}

test "d.ts: inferred return type renders when annotation is missing" {
    const out = try emitTestTyped("function add(a: number, b: number) { return a + b; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare function add(a: number, b: number): number;") != null);
}

test "d.ts: inferred cyclic return reports TS5088 instead of eliding" {
    const s = try newSetup("function foo() { return 1; }");
    defer destroySetup(s);
    var ti = try ts_checker.Interner.init(T.allocator);
    defer ti.deinit();
    var engine = try ts_checker.Engine.init(T.allocator, &ti);
    defer engine.deinit();
    var checker = ts_checker.Checker.init(T.allocator, &s.hir, &ti, &s.sint, &engine);
    defer checker.deinit();
    try checker.checkSourceFile(s.root);

    const fn_node = hir_mod.blockStmts(&s.hir, s.root)[0];
    const next_name = try s.sint.intern("next");
    const obj = try ti.internObjectType(&.{
        .{ .name = next_name, .type = ts_checker.types.Primitive.none, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const payload = ti.pool.object_type_payloads.items[ti.pool.payloadOf(obj)];
    ti.pool.object_member_pool.items[payload.members_start].type = obj;
    const sig = s.hir.typeOf(fn_node);
    const params = ti.signatureParams(sig);
    const cyclic_sig = try ti.internSignature(params, obj, false);
    s.hir.setType(fn_node, cyclic_sig);
    const f = hir_mod.fnDeclOf(&s.hir, fn_node);
    s.hir.setType(f.name, cyclic_sig);

    var em = Emitter.initWithTypes(T.allocator, &s.hir, &s.sint, &ti, .{});
    defer em.deinit();
    try em.emitSourceFile(s.root);
    try T.expectEqual(@as(usize, 1), em.diagnostics.items.len);
    try T.expectEqual(@as(u32, 5088), em.diagnostics.items[0].code);
    try T.expect(std.mem.indexOf(u8, em.diagnostics.items[0].message, "The inferred type of 'foo'") != null);
}

test "d.ts: inferred return exceeding serialization limit reports TS7056" {
    const s = try newSetup("function add(a: number, b: number) { return a + b; }");
    defer destroySetup(s);
    var ti = try ts_checker.Interner.init(T.allocator);
    defer ti.deinit();
    var engine = try ts_checker.Engine.init(T.allocator, &ti);
    defer engine.deinit();
    var checker = ts_checker.Checker.init(T.allocator, &s.hir, &ti, &s.sint, &engine);
    defer checker.deinit();
    try checker.checkSourceFile(s.root);

    var em = Emitter.initWithTypes(T.allocator, &s.hir, &s.sint, &ti, .{
        .max_inferred_type_serialization_len = 3,
    });
    defer em.deinit();
    try em.emitSourceFile(s.root);
    try T.expectEqual(@as(usize, 1), em.diagnostics.items.len);
    try T.expectEqual(@as(u32, 7056), em.diagnostics.items[0].code);
    try T.expect(std.mem.indexOf(u8, em.diagnostics.items[0].message, "exceeds the maximum length") != null);
    try T.expect(std.mem.indexOf(u8, em.out.items, "declare function add(a: number, b: number);") != null);
}

test "d.ts: inferred void return for body without returns" {
    const out = try emitTestTyped("function noop(x: number) { let y = x; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare function noop(x: number): void;") != null);
}

test "d.ts: inferred union return across branches" {
    const out = try emitTestTyped(
        \\function pick(b: boolean) {
        \\  if (b) { return 1; }
        \\  return "hi";
        \\}
    );
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare function pick(b: boolean):") != null);
    // Both branches must surface in the union; order is interner-canonical.
    try T.expect(std.mem.indexOf(u8, out, "number") != null);
    try T.expect(std.mem.indexOf(u8, out, "string") != null);
    try T.expect(std.mem.indexOf(u8, out, " | ") != null);
}

test "d.ts: interface body emits members" {
    const out = try emitTest("interface Point { x: number; y: number; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "interface Point {") != null);
    try T.expect(std.mem.indexOf(u8, out, "x: number;") != null);
    try T.expect(std.mem.indexOf(u8, out, "y: number;") != null);
}

test "d.ts: interface readonly + optional flags" {
    const out = try emitTest("interface I { readonly id: number; name?: string; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "readonly id: number;") != null);
    try T.expect(std.mem.indexOf(u8, out, "name?: string;") != null);
}

test "d.ts: object type literal in annotation" {
    const out = try emitTest("let p: { x: number; y: number } = null;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "{ x: number;") != null);
    try T.expect(std.mem.indexOf(u8, out, "y: number; }") != null);
}

test "d.ts: namespace declaration" {
    const out = try emitTest("namespace Math { let pi: number = 3.14; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare namespace Math") != null);
    try T.expect(std.mem.indexOf(u8, out, "declare let pi: number;") != null);
}
