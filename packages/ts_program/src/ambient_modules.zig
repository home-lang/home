//! Ambient module declarations (`declare module "spec" { ... }`) of global
//! declaration files, and the exports an importing file sees through them.
//!
//! tsc resolves a non-relative import to a declared ambient module before it
//! consults module resolution, so `import { spawn } from "node:child_process"`
//! binds to @types/node's declarations. Each program file checks in its own
//! pool, so the program finds the declaring file and declaration node of
//! every export here; ts_program then maps their checked types into the
//! importing file's pool.
const std = @import("std");
const hir = @import("hir");
const driver = @import("ts_driver");

pub const ModuleDecl = struct { source: usize, node: hir.NodeId };

/// One export of an ambient module: `decl` is a declaration node in
/// `source`. `name` is the export name, or `"export="` for the module's
/// export assignment.
pub const Export = struct { name: []const u8, source: usize, decl: hir.NodeId };

pub const Index = struct {
    /// Module name (unquoted) to its declarations, in program order.
    modules: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(ModuleDecl)) = .empty,

    pub fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        for (self.modules.values()) |*decls| decls.deinit(gpa);
        self.modules.deinit(gpa);
    }

    /// Record the top-level ambient module declarations of a global script.
    pub fn add(self: *Index, gpa: std.mem.Allocator, source: usize, c: *const driver.Compilation) !void {
        if (c.root == hir.none_node_id or c.hir.kindOf(c.root) != .block_stmt) return;
        for (hir.blockStmts(&c.hir, c.root)) |statement| {
            const name = moduleName(c, statement) orelse continue;
            const entry = try self.modules.getOrPut(gpa, name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(gpa, .{ .source = source, .node = statement });
        }
    }

    pub fn lookup(self: *const Index, spec: []const u8) []const ModuleDecl {
        return if (self.modules.get(spec)) |decls| decls.items else &.{};
    }
};

/// The unquoted name of a string-named module declaration, or null.
fn moduleName(c: *const driver.Compilation, node: hir.NodeId) ?[]const u8 {
    const kind = c.hir.kindOf(node);
    if (kind != .namespace_decl and kind != .module_decl) return null;
    const ns = hir.namespaceOf(&c.hir, node);
    if (ns.name == hir.none_node_id) return null;
    const raw = switch (c.hir.kindOf(ns.name)) {
        .literal_string => c.interner.get(hir.literalStringOf(&c.hir, ns.name).value),
        .identifier => if (ns.is_string_named) c.interner.get(hir.identifierOf(&c.hir, ns.name).name) else return null,
        else => return null,
    };
    if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'') and raw[raw.len - 1] == raw[0]) return raw[1 .. raw.len - 1];
    return raw;
}

fn identifierText(c: *const driver.Compilation, node: hir.NodeId) ?[]const u8 {
    if (node == hir.none_node_id or c.hir.kindOf(node) != .identifier) return null;
    return c.interner.get(hir.identifierOf(&c.hir, node).name);
}

/// The declared name of a declaration statement (unwrapped from `export`).
pub fn declarationName(c: *const driver.Compilation, node: hir.NodeId) ?[]const u8 {
    return switch (c.hir.kindOf(node)) {
        .fn_decl => identifierText(c, hir.fnDeclOf(&c.hir, node).name),
        .var_decl, .let_decl, .const_decl => identifierText(c, hir.varDeclOf(&c.hir, node).name),
        .class_decl => identifierText(c, hir.classOf(&c.hir, node).name),
        .interface_decl => identifierText(c, hir.interfaceOf(&c.hir, node).name),
        .type_alias_decl => identifierText(c, hir.typeAliasOf(&c.hir, node).name),
        .enum_decl => identifierText(c, hir.enumOf(&c.hir, node).name),
        .namespace_decl, .module_decl => identifierText(c, hir.namespaceOf(&c.hir, node).name),
        else => null,
    };
}

fn unwrapExport(c: *const driver.Compilation, node: hir.NodeId) hir.NodeId {
    if (c.hir.kindOf(node) != .export_decl) return node;
    const p = hir.exportOf(&c.hir, node);
    if (p.is_export_equals or c.interner.get(p.module).len != 0 or p.decl == hir.none_node_id) return node;
    return p.decl;
}

const Collector = struct {
    gpa: std.mem.Allocator,
    index: *const Index,
    sources: []const ?*const driver.Compilation,
    out: *std.ArrayListUnmanaged(Export),
    visiting: std.StringHashMapUnmanaged(void) = .empty,

    fn module(self: *Collector, spec: []const u8) error{OutOfMemory}!void {
        if (self.visiting.contains(spec)) return;
        try self.visiting.put(self.gpa, spec, {});
        defer _ = self.visiting.remove(spec);
        for (self.index.lookup(spec)) |decl| {
            const c = self.sources[decl.source] orelse continue;
            try self.body(decl.source, c, decl.node);
        }
    }

    fn append(self: *Collector, name: []const u8, source: usize, decl: hir.NodeId) !void {
        try self.out.append(self.gpa, .{ .name = name, .source = source, .decl = decl });
    }

    /// Copy every export of `spec` (except `default`), renamed when asked.
    fn reexport(self: *Collector, spec: []const u8, only: ?[]const u8, as: ?[]const u8) !void {
        var nested: std.ArrayListUnmanaged(Export) = .empty;
        defer nested.deinit(self.gpa);
        var inner: Collector = .{ .gpa = self.gpa, .index = self.index, .sources = self.sources, .out = &nested, .visiting = self.visiting };
        try inner.module(spec);
        self.visiting = inner.visiting;
        for (nested.items) |exported| {
            if (only) |name| {
                if (!std.mem.eql(u8, exported.name, name)) continue;
                try self.append(as orelse name, exported.source, exported.decl);
            } else {
                if (std.mem.eql(u8, exported.name, "default")) continue;
                try self.append(exported.name, exported.source, exported.decl);
            }
        }
    }

    fn body(self: *Collector, source: usize, c: *const driver.Compilation, node: hir.NodeId) !void {
        const statements = hir.namespaceBody(&c.hir, node);
        var explicit = false;
        for (statements) |statement| {
            if (c.hir.kindOf(statement) == .export_decl) explicit = true;
        }
        for (statements) |statement| {
            if (c.hir.kindOf(statement) != .export_decl) {
                if (explicit) continue;
                if (declarationName(c, statement)) |name| try self.append(name, source, statement);
                continue;
            }
            const p = hir.exportOf(&c.hir, statement);
            if (p.is_export_equals) {
                const target = identifierText(c, p.decl) orelse continue;
                try self.exportAssignment(source, c, node, target);
                continue;
            }
            if (c.interner.get(p.module).len != 0) {
                const from = c.interner.get(p.module);
                if (p.is_namespace) {
                    if (c.interner.get(p.namespace_alias).len == 0) try self.reexport(from, null, null);
                    continue;
                }
                for (hir.exportNamed(&c.hir, statement)) |specifier| {
                    if (c.hir.kindOf(specifier) != .import_specifier) continue;
                    const sp = hir.importSpecifierOf(&c.hir, specifier);
                    try self.reexport(from, c.interner.get(sp.imported), c.interner.get(sp.local));
                }
                continue;
            }
            if (p.decl != hir.none_node_id) {
                const name = if (p.is_default) "default" else (declarationName(c, p.decl) orelse continue);
                try self.append(name, source, p.decl);
                continue;
            }
            for (hir.exportNamed(&c.hir, statement)) |specifier| {
                if (c.hir.kindOf(specifier) != .import_specifier) continue;
                const sp = hir.importSpecifierOf(&c.hir, specifier);
                const local = c.interner.get(sp.imported);
                const exported = c.interner.get(sp.local);
                try self.appendLocals(exported, source, c, node, local);
            }
        }
    }

    /// `export = X`: a local declaration, a `global` declaration of this
    /// module, or `import X = require("other")` (the other module's exports).
    fn exportAssignment(self: *Collector, source: usize, c: *const driver.Compilation, node: hir.NodeId, target: []const u8) !void {
        for (hir.namespaceBody(&c.hir, node)) |statement| {
            if (c.hir.kindOf(statement) != .import_decl) continue;
            const imp = hir.importOf(&c.hir, statement);
            if (!imp.is_require_equals) continue;
            const local = identifierText(c, imp.default_binding) orelse continue;
            if (!std.mem.eql(u8, local, target)) continue;
            const from = c.interner.get(imp.module);
            var nested: std.ArrayListUnmanaged(Export) = .empty;
            defer nested.deinit(self.gpa);
            var inner: Collector = .{ .gpa = self.gpa, .index = self.index, .sources = self.sources, .out = &nested, .visiting = self.visiting };
            try inner.module(from);
            self.visiting = inner.visiting;
            for (nested.items) |exported| try self.append(exported.name, exported.source, exported.decl);
            return;
        }
        try self.appendLocals("export=", source, c, node, target);
    }

    /// Export `local` as `name`: every overload of a function, else the
    /// best single declaration (see `findLocal`).
    fn appendLocals(self: *Collector, name: []const u8, source: usize, c: *const driver.Compilation, node: hir.NodeId, local: []const u8) !void {
        const first = findLocal(c, node, local) orelse return;
        if (c.hir.kindOf(first) != .fn_decl) return self.append(name, source, first);
        for (hir.namespaceBody(&c.hir, node)) |raw| {
            const statement = unwrapExport(c, raw);
            if (c.hir.kindOf(statement) != .fn_decl) continue;
            if (!std.mem.eql(u8, declarationName(c, statement) orelse "", local)) continue;
            try self.append(name, source, statement);
        }
    }
};

/// A declaration named `name` directly in `module_node`'s body or in one of
/// its `declare global { }` blocks. Value declarations win over types.
fn findLocal(c: *const driver.Compilation, module_node: hir.NodeId, name: []const u8) ?hir.NodeId {
    var type_match: ?hir.NodeId = null;
    for (hir.namespaceBody(&c.hir, module_node)) |raw| {
        const statement = unwrapExport(c, raw);
        const kind = c.hir.kindOf(statement);
        if ((kind == .namespace_decl or kind == .module_decl) and
            std.mem.eql(u8, identifierText(c, hir.namespaceOf(&c.hir, statement).name) orelse "", "global"))
        {
            for (hir.namespaceBody(&c.hir, statement)) |inner_raw| {
                const inner = unwrapExport(c, inner_raw);
                const declared = declarationName(c, inner) orelse continue;
                if (!std.mem.eql(u8, declared, name)) continue;
                switch (c.hir.kindOf(inner)) {
                    .interface_decl, .type_alias_decl => type_match = type_match orelse inner,
                    else => return inner,
                }
            }
            continue;
        }
        const declared = declarationName(c, statement) orelse continue;
        if (!std.mem.eql(u8, declared, name)) continue;
        switch (kind) {
            .interface_decl, .type_alias_decl => type_match = type_match orelse statement,
            else => return statement,
        }
    }
    return type_match;
}

/// Every export of ambient module `spec`, following `export *`, named
/// re-exports and `export = require(...)` aliases across declarations.
pub fn collectExports(
    gpa: std.mem.Allocator,
    index: *const Index,
    sources: []const ?*const driver.Compilation,
    spec: []const u8,
    out: *std.ArrayListUnmanaged(Export),
) error{OutOfMemory}!void {
    var collector: Collector = .{ .gpa = gpa, .index = index, .sources = sources, .out = out };
    defer collector.visiting.deinit(gpa);
    try collector.module(spec);
}
