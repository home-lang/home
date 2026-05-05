//! Multi-file TS program graph.
//!
//! Per TS_PARITY_PLAN. Wraps the per-file driver
//! (`packages/ts_driver/`) with a module graph and cross-file
//! resolution via `packages/ts_resolver/`. The resulting `Program`
//! is the unit the LSP, the `home tsc` CLI, and the bundler operate on.
//!
//! Phase 4.5 ships:
//!   - `Program.add(path, source)` — add files explicitly
//!   - `Program.resolve()` — walk imports and resolve them via the
//!     module resolver, building the dependency DAG
//!   - `Program.compileAll()` — compile every file in the graph
//!     (depth-first to preserve declaration ordering)
//!   - Cycle detection — TS allows cycles and we record them but
//!     compile each file once
//!
//! Phase 5 adds incremental rebuilds via the query DB.

const std = @import("std");
const ts_driver = @import("ts_driver");
const ts_resolver = @import("ts_resolver");

pub const FileId = u32;

/// One file in the program. Owned by the program.
pub const File = struct {
    id: FileId,
    /// Resolved absolute (or program-canonical) path.
    path: []const u8,
    /// Source text. NOT owned — caller manages lifetime via the
    /// FileSystem implementation.
    source: []const u8,
    /// Compiled artefact. `null` until `compileAll` runs.
    compilation: ?*ts_driver.Compilation,
    /// Outgoing import edges — file ids this file imports from.
    imports: std.ArrayListUnmanaged(FileId),
    /// True for `.d.ts` / `.d.hm` declaration-only files.
    is_declaration: bool,
    /// True for `.tsx` / `.jsx` files.
    is_tsx: bool,
};

pub const ProgramError = error{
    OutOfMemory,
    NotFound,
    Ambiguous,
    InvalidSpecifier,
    LexError,
    ParseError,
    BindError,
    EmitError,
};

pub const Program = struct {
    gpa: std.mem.Allocator,
    files: std.ArrayListUnmanaged(*File),
    by_path: std.StringHashMapUnmanaged(FileId),
    resolver: *ts_resolver.Resolver,
    /// Stored sources keyed by path (we own the dupes).
    sources: std.StringHashMapUnmanaged([]const u8),

    pub fn init(gpa: std.mem.Allocator, resolver: *ts_resolver.Resolver) Program {
        return .{
            .gpa = gpa,
            .files = .empty,
            .by_path = .empty,
            .resolver = resolver,
            .sources = .empty,
        };
    }

    pub fn deinit(self: *Program) void {
        for (self.files.items) |f| {
            if (f.compilation) |c| {
                c.deinit();
                self.gpa.destroy(c);
            }
            f.imports.deinit(self.gpa);
            self.gpa.free(f.path);
            self.gpa.destroy(f);
        }
        self.files.deinit(self.gpa);

        var it = self.by_path.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.by_path.deinit(self.gpa);

        var sit = self.sources.iterator();
        while (sit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.sources.deinit(self.gpa);
    }

    /// Add a file to the program. Returns its FileId. If a file at
    /// `path` already exists, returns the existing id and ignores the
    /// new source.
    pub fn add(self: *Program, path: []const u8, source: []const u8) ProgramError!FileId {
        if (self.by_path.get(path)) |id| return id;

        const owned_path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned_path);
        const owned_source = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(owned_source);

        const id: FileId = @intCast(self.files.items.len);
        const file = try self.gpa.create(File);
        errdefer self.gpa.destroy(file);
        file.* = .{
            .id = id,
            .path = owned_path,
            .source = owned_source,
            .compilation = null,
            .imports = .empty,
            .is_declaration = std.mem.endsWith(u8, path, ".d.ts") or std.mem.endsWith(u8, path, ".d.hm"),
            .is_tsx = std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".jsx"),
        };

        try self.files.append(self.gpa, file);

        const key = try self.gpa.dupe(u8, path);
        try self.by_path.put(self.gpa, key, id);

        const skey = try self.gpa.dupe(u8, path);
        try self.sources.put(self.gpa, skey, owned_source);

        return id;
    }

    pub fn fileById(self: *const Program, id: FileId) *File {
        return self.files.items[id];
    }

    pub fn lookupPath(self: *const Program, path: []const u8) ?FileId {
        return self.by_path.get(path);
    }

    /// Compile every file. Two passes:
    ///   1. Lex/parse/bind/emit each file in isolation.
    ///   2. Walk imports and resolve specifiers — populating the
    ///      `imports` adjacency list.
    pub fn compileAll(self: *Program, options: ts_driver.CompileOptions) ProgramError!void {
        for (self.files.items) |f| {
            if (f.compilation != null) continue;
            var per_file = options;
            per_file.is_tsx = options.is_tsx or f.is_tsx;
            const c = ts_driver.compileSource(self.gpa, f.source, per_file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LexError => return error.LexError,
                error.ParseError => return error.ParseError,
                error.BindError => return error.BindError,
                error.EmitError => return error.EmitError,
            };
            f.compilation = c;
        }

        try self.resolveImports();
    }

    /// Walk every compiled file's import declarations and resolve
    /// each to a FileId, populating the adjacency list.
    fn resolveImports(self: *Program) ProgramError!void {
        const hir_mod = @import("hir");
        for (self.files.items) |f| {
            const c = f.compilation orelse continue;
            const root = c.root;
            const stmts = hir_mod.blockStmts(&c.hir, root);
            for (stmts) |s| {
                if (c.hir.kindOf(s) != .import_decl) continue;
                const imp = hir_mod.importOf(&c.hir, s);
                const module_name = c.interner.get(imp.module);
                if (module_name.len == 0) continue;
                // Resolve relative to the importing file.
                const res = self.resolver.resolve(module_name, f.path) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NotFound, error.Ambiguous, error.InvalidSpecifier => continue,
                };
                // If the resolved file is already in the program,
                // record the edge. Otherwise the program is partial —
                // the LSP will pick it up when the file is added.
                if (self.by_path.get(res.path)) |target_id| {
                    try f.imports.append(self.gpa, target_id);
                }
            }
        }
    }

    /// Return true if `from` reaches `to` through the import graph
    /// (transitive). Used by cycle detection + impact analysis.
    pub fn reaches(self: *const Program, from: FileId, to: FileId) bool {
        var visited = std.AutoHashMapUnmanaged(FileId, void).empty;
        defer visited.deinit(self.gpa);
        var stack = std.ArrayListUnmanaged(FileId).empty;
        defer stack.deinit(self.gpa);
        stack.append(self.gpa, from) catch return false;
        while (stack.pop()) |cur| {
            if (cur == to) return true;
            if (visited.get(cur) != null) continue;
            visited.put(self.gpa, cur, {}) catch return false;
            for (self.files.items[cur].imports.items) |edge| {
                stack.append(self.gpa, edge) catch return false;
            }
        }
        return false;
    }

    /// Returns a slice of files in dependency-resolution order — leaves
    /// (no imports) first, roots (depended upon by everything) last.
    /// On a cycle, the order is best-effort. Caller frees with `gpa.free`.
    pub fn topologicalOrder(self: *const Program) ProgramError![]FileId {
        var order = std.ArrayListUnmanaged(FileId).empty;
        errdefer order.deinit(self.gpa);
        var visited = std.AutoHashMapUnmanaged(FileId, void).empty;
        defer visited.deinit(self.gpa);
        var on_stack = std.AutoHashMapUnmanaged(FileId, void).empty;
        defer on_stack.deinit(self.gpa);
        for (self.files.items) |f| {
            try self.topoVisit(f.id, &visited, &on_stack, &order);
        }
        return try order.toOwnedSlice(self.gpa);
    }

    fn topoVisit(
        self: *const Program,
        id: FileId,
        visited: *std.AutoHashMapUnmanaged(FileId, void),
        on_stack: *std.AutoHashMapUnmanaged(FileId, void),
        order: *std.ArrayListUnmanaged(FileId),
    ) ProgramError!void {
        if (visited.contains(id)) return;
        if (on_stack.contains(id)) return; // cycle — bail
        try on_stack.put(self.gpa, id, {});
        for (self.files.items[id].imports.items) |edge| {
            try self.topoVisit(edge, visited, on_stack, order);
        }
        _ = on_stack.remove(id);
        try visited.put(self.gpa, id, {});
        try order.append(self.gpa, id);
    }
};

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "Program: add returns stable FileId, dedups on path" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const a = try p.add("/a.ts", "let x = 1;");
    const a2 = try p.add("/a.ts", "let y = 2;");
    const b = try p.add("/b.ts", "let z = 3;");
    try T.expectEqual(@as(FileId, 0), a);
    try T.expectEqual(a, a2); // dedup
    try T.expectEqual(@as(FileId, 1), b);
}

test "Program: compileAll produces JS for every file" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x: number = 1;");
    _ = try p.add("/b.ts", "let y: string = \"hi\";");
    try p.compileAll(.{});
    for (p.files.items) |f| {
        try T.expect(f.compilation != null);
        try T.expect(f.compilation.?.js.len > 0);
    }
}

test "Program: resolves imports between files" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/a.ts", "import { y } from './b';");
    try vfs.addFile("/proj/b.ts", "export let y = 42;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const a_id = try p.add("/proj/a.ts", "import { y } from './b';");
    const b_id = try p.add("/proj/b.ts", "export let y = 42;");
    try p.compileAll(.{});
    const a = p.fileById(a_id);
    try T.expectEqual(@as(usize, 1), a.imports.items.len);
    try T.expectEqual(b_id, a.imports.items[0]);
}

test "Program: tsx flag inherits from .tsx file extension" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/Comp.tsx", "let v = <Foo bar=\"baz\" />;");
    try p.compileAll(.{});
    const file = p.fileById(0);
    try T.expect(file.is_tsx);
    try T.expect(std.mem.indexOf(u8, file.compilation.?.js, "React.createElement") != null);
}

test "Program: declaration files marked is_declaration" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/types.d.ts", "declare const X: number;");
    try T.expect(p.fileById(0).is_declaration);
}

test "Program: reaches detects transitive imports" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/a.ts", "");
    try vfs.addFile("/b.ts", "");
    try vfs.addFile("/c.ts", "");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const a = try p.add("/a.ts", "import './b';");
    const b = try p.add("/b.ts", "import './c';");
    const c = try p.add("/c.ts", "");
    try p.compileAll(.{});
    try T.expect(p.reaches(a, b));
    try T.expect(p.reaches(a, c)); // transitive
    try T.expect(!p.reaches(c, a));
}

test "Program: topologicalOrder produces leaves-first" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/a.ts", "");
    try vfs.addFile("/b.ts", "");
    try vfs.addFile("/c.ts", "");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const a = try p.add("/a.ts", "import './b';");
    const b = try p.add("/b.ts", "import './c';");
    const c = try p.add("/c.ts", "");
    try p.compileAll(.{});
    const order = try p.topologicalOrder();
    defer T.allocator.free(order);
    try T.expectEqual(@as(usize, 3), order.len);
    // c is a leaf — should come first.
    try T.expectEqual(c, order[0]);
    // a depends on b which depends on c — a should come last.
    try T.expectEqual(a, order[2]);
    try T.expectEqual(b, order[1]);
}

test "Program: cycle does not infinite loop" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/a.ts", "");
    try vfs.addFile("/b.ts", "");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "import './b';");
    _ = try p.add("/b.ts", "import './a';");
    try p.compileAll(.{});
    const order = try p.topologicalOrder();
    defer T.allocator.free(order);
    try T.expectEqual(@as(usize, 2), order.len);
}
