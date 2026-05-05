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

pub const Options = struct {
    /// 2-space indent matches tsc's default.
    indent: []const u8 = "  ",
    /// `\n` matches tsc on POSIX; Windows callers pass `\r\n`.
    newline: []const u8 = "\n",
    /// If true, drop semicolons unless required for ASI. We default
    /// to *with* semicolons, matching tsc.
    omit_semis: bool = false,
};

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
        };
    }

    pub fn deinit(self: *Printer) void {
        self.out.deinit(self.gpa);
    }

    pub fn toOwnedSlice(self: *Printer) ![]u8 {
        return self.out.toOwnedSlice(self.gpa);
    }

    fn write(self: *Printer, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
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
        for (stmts, 0..) |stmt, i| {
            if (i > 0) try self.write(self.options.newline);
            try self.printStatement(stmt);
        }
    }

    fn printStatement(self: *Printer, node: NodeId) anyerror!void {
        try self.indent();
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
        for (members) |m| {
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

    fn printExport(self: *Printer, node: NodeId) !void {
        const ex = hir_mod.exportOf(self.hir, node);
        if (ex.is_type_only) return;
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
            .member_access => try self.printMember(node),
            .element_access => try self.printElement(node),
            .array_literal => try self.printArrayLiteral(node),
            .object_literal => try self.printObjectLiteral(node),
            .fn_decl, .fn_expr, .arrow_fn => try self.printFnDecl(node),
            .class_decl, .class_expr => try self.printClassDecl(node),
            else => return error.UnsupportedNode,
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
        try self.printExpression(p.object);
        try self.write(if (p.optional) "?." else ".");
        try self.write(self.interner.get(p.name));
    }

    fn printElement(self: *Printer, node: NodeId) !void {
        const p = hir_mod.elementOf(self.hir, node);
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
