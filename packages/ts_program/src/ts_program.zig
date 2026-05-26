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
const ts_cache = @import("ts_cache");
const hir_mod_ns = @import("hir");

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
    /// True for `.d.ts` / `.d.hm` / `.d.home` declaration-only files.
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
            .is_declaration = isDeclarationPath(path),
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

    fn isDeclarationPath(path: []const u8) bool {
        return std.mem.endsWith(u8, path, ".d.ts") or
            std.mem.endsWith(u8, path, ".d.mts") or
            std.mem.endsWith(u8, path, ".d.cts") or
            std.mem.endsWith(u8, path, ".d.hm") or
            std.mem.endsWith(u8, path, ".d.home") or
            (std.mem.endsWith(u8, path, ".ts") and std.mem.indexOf(u8, path, ".d.") != null);
    }

    fn isJsLikePath(path: []const u8) bool {
        return std.mem.endsWith(u8, path, ".js") or
            std.mem.endsWith(u8, path, ".jsx") or
            std.mem.endsWith(u8, path, ".mjs") or
            std.mem.endsWith(u8, path, ".cjs");
    }

    /// Replace the source bytes for an existing file (matched by
    /// path). Returns the file's id, or null if `path` isn't
    /// tracked. Drops the file's cached compilation if any.
    pub fn updateSource(self: *Program, path: []const u8, new_source: []const u8) !?FileId {
        const id = self.by_path.get(path) orelse return null;
        const f = self.files.items[id];
        if (f.compilation) |old| {
            old.deinit();
            self.gpa.destroy(old);
            f.compilation = null;
        }
        // Replace the source slice. We also update the
        // `sources` map's value so the dupe stays consistent.
        const new_dupe = try self.gpa.dupe(u8, new_source);
        if (self.sources.fetchRemove(path)) |old_entry| {
            self.gpa.free(old_entry.key);
            self.gpa.free(old_entry.value);
        }
        const skey = try self.gpa.dupe(u8, path);
        try self.sources.put(self.gpa, skey, new_dupe);
        f.source = new_dupe;
        f.imports.clearRetainingCapacity();
        return id;
    }

    pub fn lookupPath(self: *const Program, path: []const u8) ?FileId {
        return self.by_path.get(path);
    }

    /// Compile every file. Two passes:
    ///   1. Lex/parse/bind/emit each file in isolation.
    ///   2. Walk imports and resolve specifiers — populating the
    ///      `imports` adjacency list.
    pub fn compileAll(self: *Program, options: ts_driver.CompileOptions) ProgramError!void {
        const ambient_global_namespace_roots = try self.collectAmbientGlobalNamespaceRoots();
        defer freeStringSlice(self.gpa, ambient_global_namespace_roots);
        const script_object_expandos = try self.collectScriptObjectExpandos();
        defer self.gpa.free(script_object_expandos);
        for (self.files.items) |f| {
            if (f.compilation != null) continue;
            var per_file = options;
            per_file.is_tsx = options.is_tsx or f.is_tsx;
            per_file.ambient_global_namespace_roots = ambient_global_namespace_roots;
            per_file.script_object_expandos = script_object_expandos;
            // Per-file declaration-file flag. Multi-file fixtures
            // (e.g. `react.d.ts` + `app.tsx` in one conformance case)
            // share a global `options.is_declaration_file` that the
            // harness derives from a single representative path — so
            // a regular `.tsx` file compiled in the same case as a
            // `.d.ts` neighbour was inheriting `is_declaration_file=true`
            // and getting class-field initializers falsely flagged with
            // TS1039. Trust the per-file extension flag: it's accurate
            // for every file in the program (single-file callers see
            // the same value they'd have passed in the global option).
            per_file.is_declaration_file = f.is_declaration;
            // Anchor checker module-resolution requests at the
            // current file when the caller hasn't overridden the
            // importer path. This is what lets
            // `Checker.setExternalResolver` produce correct
            // node_modules-relative resolutions for fixtures whose
            // virtual sections were stripped before per-file
            // compilation.
            if (per_file.importer_path.len == 0) per_file.importer_path = f.path;
            const c = ts_driver.compileSource(self.gpa, f.source, per_file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LexError => return error.LexError,
                error.ParseError => return error.ParseError,
                error.BindError => return error.BindError,
                error.EmitError => return error.EmitError,
            };
            f.compilation = c;
        }

        try self.appendMissingImportedHelperDiagnostics(options);

        try self.resolveImports();
    }

    /// Streaming variant of `compileAll`. Each file's diagnostics are
    /// surfaced via `callback` as soon as that file finishes
    /// compiling — driving "time-to-first-diagnostic" closer to the
    /// per-file check time rather than the whole-program time.
    /// Phase 5 §5.8 "streaming diagnostics" foundation.
    pub fn compileAllStreaming(
        self: *Program,
        options: ts_driver.CompileOptions,
        ctx: anytype,
        comptime callback: fn (ctx_t: @TypeOf(ctx), file_path: []const u8, diags: []const ts_driver.Diagnostic) void,
    ) ProgramError!void {
        const ambient_global_namespace_roots = try self.collectAmbientGlobalNamespaceRoots();
        defer freeStringSlice(self.gpa, ambient_global_namespace_roots);
        const script_object_expandos = try self.collectScriptObjectExpandos();
        defer self.gpa.free(script_object_expandos);
        for (self.files.items) |f| {
            if (f.compilation != null) {
                // Already compiled — replay its diagnostics anyway so
                // a streaming consumer that joined late doesn't miss
                // them.
                callback(ctx, f.path, f.compilation.?.diagnostics.items);
                continue;
            }
            var per_file = options;
            per_file.is_tsx = options.is_tsx or f.is_tsx;
            per_file.is_declaration_file = f.is_declaration;
            per_file.ambient_global_namespace_roots = ambient_global_namespace_roots;
            per_file.script_object_expandos = script_object_expandos;
            if (per_file.importer_path.len == 0) per_file.importer_path = f.path;
            const c = ts_driver.compileSource(self.gpa, f.source, per_file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LexError => return error.LexError,
                error.ParseError => return error.ParseError,
                error.BindError => return error.BindError,
                error.EmitError => return error.EmitError,
            };
            f.compilation = c;
            callback(ctx, f.path, c.diagnostics.items);
        }

        try self.resolveImports();
    }

    fn collectAmbientGlobalNamespaceRoots(self: *const Program) ProgramError![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer freeStringSlice(self.gpa, out.items);
        for (self.files.items) |f| {
            try appendTopLevelNamespaceRootsFromSource(self.gpa, f.source, &out);
            try appendAmbientGlobalNamespaceRootsFromSource(self.gpa, f.source, &out);
        }
        return try out.toOwnedSlice(self.gpa);
    }

    fn collectScriptObjectExpandos(self: *const Program) ProgramError![]const ts_driver.ScriptObjectExpando {
        var out: std.ArrayListUnmanaged(ts_driver.ScriptObjectExpando) = .empty;
        errdefer out.deinit(self.gpa);
        var namespace_roots: std.ArrayListUnmanaged([]const u8) = .empty;
        defer namespace_roots.deinit(self.gpa);
        for (self.files.items) |f| {
            try collectTopLevelNamespaceRootSlices(self.gpa, f.source, &namespace_roots);
        }
        for (self.files.items) |f| {
            if (!isJsLikePath(f.path)) continue;
            var roots: std.ArrayListUnmanaged([]const u8) = .empty;
            defer roots.deinit(self.gpa);
            try roots.appendSlice(self.gpa, namespace_roots.items);
            try collectUntypedObjectLiteralRoots(self.gpa, f.source, &roots);
            for (roots.items) |root| {
                try collectScriptObjectExpandosForRoot(self.gpa, f.source, root, &out);
            }
        }
        return try out.toOwnedSlice(self.gpa);
    }

    fn appendTopLevelNamespaceRootsFromSource(
        gpa: std.mem.Allocator,
        source: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
    ) ProgramError!void {
        var roots: std.ArrayListUnmanaged([]const u8) = .empty;
        defer roots.deinit(gpa);
        try collectTopLevelNamespaceRootSlices(gpa, source, &roots);
        for (roots.items) |name| {
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, name)) break;
            } else {
                const owned = try gpa.dupe(u8, name);
                errdefer gpa.free(owned);
                try out.append(gpa, owned);
            }
        }
    }

    fn collectTopLevelNamespaceRootSlices(
        gpa: std.mem.Allocator,
        source: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
    ) ProgramError!void {
        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            var after_keyword: usize = 0;
            if (identifierKeywordAt(source, i, "declare")) {
                var p = i + "declare".len;
                while (p < source.len and std.ascii.isWhitespace(source[p])) p += 1;
                if (identifierKeywordAt(source, p, "namespace")) {
                    after_keyword = p + "namespace".len;
                } else if (identifierKeywordAt(source, p, "module")) {
                    after_keyword = p + "module".len;
                } else {
                    continue;
                }
            } else if (identifierKeywordAt(source, i, "namespace")) {
                after_keyword = i + "namespace".len;
            } else if (identifierKeywordAt(source, i, "module")) {
                after_keyword = i + "module".len;
            } else {
                continue;
            }
            var p = after_keyword;
            while (p < source.len and std.ascii.isWhitespace(source[p])) p += 1;
            if (p >= source.len or !asciiIdentifierStart(source[p])) continue;
            const start = p;
            p += 1;
            while (p < source.len and asciiIdentifierContinue(source[p])) p += 1;
            const name = source[start..p];
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, name)) break;
            } else {
                try out.append(gpa, name);
            }
        }
    }

    fn collectUntypedObjectLiteralRoots(
        gpa: std.mem.Allocator,
        source: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
    ) ProgramError!void {
        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            const kw_len: usize = if (identifierKeywordAt(source, i, "var"))
                3
            else if (identifierKeywordAt(source, i, "let"))
                3
            else if (identifierKeywordAt(source, i, "const"))
                5
            else
                continue;
            var p = i + kw_len;
            while (p < source.len and std.ascii.isWhitespace(source[p])) p += 1;
            if (p >= source.len or !asciiIdentifierStart(source[p])) continue;
            const name_start = p;
            p += 1;
            while (p < source.len and asciiIdentifierContinue(source[p])) p += 1;
            const name = source[name_start..p];
            while (p < source.len and std.ascii.isWhitespace(source[p])) p += 1;
            if (p >= source.len or source[p] != '=') continue;
            p += 1;
            while (p < source.len and std.ascii.isWhitespace(source[p])) p += 1;
            if (p >= source.len or source[p] != '{') continue;
            p += 1;
            while (p < source.len and std.ascii.isWhitespace(source[p])) p += 1;
            if (p >= source.len or source[p] != '}') continue;
            var exists = false;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, name)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) try out.append(gpa, name);
        }
    }

    fn collectScriptObjectExpandosForRoot(
        gpa: std.mem.Allocator,
        source: []const u8,
        root: []const u8,
        out: *std.ArrayListUnmanaged(ts_driver.ScriptObjectExpando),
    ) ProgramError!void {
        var i: usize = 0;
        while (i + root.len + 1 < source.len) : (i += 1) {
            if (!std.mem.startsWith(u8, source[i..], root)) continue;
            if (i > 0 and asciiIdentifierContinue(source[i - 1])) continue;
            var p = i + root.len;
            if (p >= source.len or source[p] != '.') continue;
            p += 1;
            if (p >= source.len or !asciiIdentifierStart(source[p])) continue;
            const member_start = p;
            p += 1;
            while (p < source.len and asciiIdentifierContinue(source[p])) p += 1;
            const member = source[member_start..p];
            while (p < source.len and std.ascii.isWhitespace(source[p])) p += 1;
            if (p >= source.len or source[p] != '=') continue;
            p += 1;
            while (p < source.len and std.ascii.isWhitespace(source[p])) p += 1;
            if (!(std.mem.startsWith(u8, source[p..], "function") or
                std.mem.startsWith(u8, source[p..], "class")))
            {
                continue;
            }
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing.root, root) and std.mem.eql(u8, existing.member, member)) break;
            } else {
                try out.append(gpa, .{ .root = root, .member = member });
            }
        }
    }

    fn appendAmbientGlobalNamespaceRootsFromSource(
        gpa: std.mem.Allocator,
        source: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
    ) ProgramError!void {
        const needle = "declare global";
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_from, needle)) |decl_pos| {
            search_from = decl_pos + needle.len;
            const open_rel = std.mem.indexOfScalarPos(u8, source, search_from, '{') orelse continue;
            var i = open_rel + 1;
            var depth: usize = 1;
            while (i < source.len and depth > 0) {
                const ch = source[i];
                if (ch == '{') {
                    depth += 1;
                    i += 1;
                    continue;
                }
                if (ch == '}') {
                    depth -= 1;
                    i += 1;
                    continue;
                }
                if (depth == 1) {
                    if (identifierKeywordAt(source, i, "namespace")) {
                        try appendAmbientGlobalNamespaceRoot(gpa, source, i + "namespace".len, out);
                    } else if (identifierKeywordAt(source, i, "module")) {
                        try appendAmbientGlobalNamespaceRoot(gpa, source, i + "module".len, out);
                    }
                }
                i += 1;
            }
        }
    }

    fn appendAmbientGlobalNamespaceRoot(
        gpa: std.mem.Allocator,
        source: []const u8,
        after_keyword: usize,
        out: *std.ArrayListUnmanaged([]const u8),
    ) ProgramError!void {
        var i = after_keyword;
        while (i < source.len and std.ascii.isWhitespace(source[i])) i += 1;
        if (i >= source.len or !asciiIdentifierStart(source[i])) return;
        const start = i;
        i += 1;
        while (i < source.len and asciiIdentifierContinue(source[i])) i += 1;
        const name = source[start..i];
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try out.append(gpa, owned);
    }

    fn identifierKeywordAt(source: []const u8, pos: usize, keyword: []const u8) bool {
        if (pos + keyword.len > source.len) return false;
        if (!std.mem.eql(u8, source[pos .. pos + keyword.len], keyword)) return false;
        if (pos > 0 and asciiIdentifierContinue(source[pos - 1])) return false;
        const end = pos + keyword.len;
        return end >= source.len or !asciiIdentifierContinue(source[end]);
    }

    fn asciiIdentifierStart(c: u8) bool {
        return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_' or c == '$';
    }

    fn asciiIdentifierContinue(c: u8) bool {
        return asciiIdentifierStart(c) or (c >= '0' and c <= '9');
    }

    fn freeStringSlice(gpa: std.mem.Allocator, items: []const []const u8) void {
        for (items) |item| gpa.free(item);
        gpa.free(items);
    }

    /// One `declare global { … }` block discovered at a file's top
    /// level. The eventual cross-file symbol-table merge — driven by
    /// `binder.Module.augment` — needs to know which files contribute
    /// to the program's global scope. For v1 we just surface the
    /// (file, namespace_node) pairs so downstream consumers can decide
    /// how to consume them. The actual `augment` call requires shared
    /// string-interning across files which the program graph does
    /// not yet provide.
    pub const GlobalAugmentation = struct {
        file_id: FileId,
        namespace_node_id: hir_mod_ns.NodeId,
    };

    /// Walk every compiled file's top-level statements and return a
    /// slice of `GlobalAugmentation` records — one per top-level
    /// `namespace_decl` whose name is `"global"`. Caller frees with
    /// `gpa.free`.
    pub fn collectGlobalAugmentations(self: *const Program) ProgramError![]GlobalAugmentation {
        var out: std.ArrayListUnmanaged(GlobalAugmentation) = .empty;
        errdefer out.deinit(self.gpa);
        for (self.files.items) |f| {
            const c = f.compilation orelse continue;
            const root = c.root;
            if (c.hir.kindOf(root) != .block_stmt) continue;
            const stmts = hir_mod_ns.blockStmts(&c.hir, root);
            for (stmts) |s| {
                if (c.hir.kindOf(s) != .namespace_decl) continue;
                const ns = hir_mod_ns.namespaceOf(&c.hir, s);
                if (c.hir.kindOf(ns.name) != .identifier) continue;
                const ident = hir_mod_ns.identifierOf(&c.hir, ns.name);
                const name_bytes = c.interner.get(ident.name);
                if (!std.mem.eql(u8, name_bytes, "global")) continue;
                try out.append(self.gpa, .{
                    .file_id = f.id,
                    .namespace_node_id = s,
                });
            }
        }
        return try out.toOwnedSlice(self.gpa);
    }

    /// Per-file cached emit summary. Populated by `emitAllToCache`.
    pub const EmitSummary = struct {
        file_id: FileId,
        path: []const u8,
        js: []const u8, // owned by gpa
        diagnostic_count: u32,
        has_errors: bool,
        from_cache: bool,

        pub fn deinit(self: *EmitSummary, gpa: std.mem.Allocator) void {
            gpa.free(self.js);
        }
    };

    /// Emit every file to JS, consulting `cache` for hits. The cache
    /// key is `sha256(source + config_blob)` per file. On a hit the
    /// cached JS is returned directly without running the lex/parse/
    /// bind/check/emit pipeline — the multi-file analogue of
    /// `ts_driver.emitWithCache`.
    ///
    /// This is the path `home tsc --emit` will take for unchanged
    /// files: cold-start over a fully-cached project drops to a
    /// pile of disk reads instead of N pipeline runs.
    ///
    /// Returns a slice of `EmitSummary` records (caller frees each
    /// `js` slice plus the outer slice via `gpa.free`).
    pub fn emitAllToCache(
        self: *Program,
        cache: *ts_cache.Cache,
        config_blob: []const u8,
        options: ts_driver.CompileOptions,
    ) ProgramError![]EmitSummary {
        const out = self.gpa.alloc(EmitSummary, self.files.items.len) catch return error.OutOfMemory;
        errdefer {
            for (out) |*s| self.gpa.free(s.js);
            self.gpa.free(out);
        }
        for (self.files.items, 0..) |f, idx| {
            var per_file = options;
            per_file.is_tsx = options.is_tsx or f.is_tsx;
            per_file.is_declaration_file = f.is_declaration;
            const r = ts_driver.emitWithCache(self.gpa, f.source, cache, config_blob, per_file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LexError => return error.LexError,
                error.ParseError => return error.ParseError,
                error.BindError => return error.BindError,
                error.EmitError => return error.EmitError,
                else => return error.EmitError,
            };
            out[idx] = .{
                .file_id = f.id,
                .path = f.path,
                .js = r.js,
                .diagnostic_count = r.diagnostic_count,
                .has_errors = r.has_errors,
                .from_cache = r.from_cache,
            };
        }
        return out;
    }

    /// Compile every file in parallel using a worker pool. Each
    /// worker compiles one file at a time; the outer thread waits
    /// for all to finish before resolving cross-file imports.
    ///
    /// Phase 5 deliverable. Per the §5.6 model: parse + bind are
    /// embarrassingly parallel (each file is independent). Number
    /// of workers defaults to `min(NPROC, 8)` matching tsgo.
    pub fn compileAllParallel(self: *Program, options: ts_driver.CompileOptions, workers: ?usize) ProgramError!void {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const n = workers orelse @min(cpu_count, 8);

        // Files-to-compile slice (indices we still need to do).
        var pending: std.ArrayListUnmanaged(usize) = .empty;
        defer pending.deinit(self.gpa);
        for (self.files.items, 0..) |f, idx| {
            if (f.compilation == null) try pending.append(self.gpa, idx);
        }
        if (pending.items.len == 0) {
            try self.resolveImports();
            return;
        }

        // Atomic cursor that workers pop from.
        var cursor = std.atomic.Value(usize).init(0);
        var failures = std.atomic.Value(u32).init(0);

        const Worker = struct {
            fn run(prog: *Program, opts: ts_driver.CompileOptions, pending_slice: []const usize, cur: *std.atomic.Value(usize), fail: *std.atomic.Value(u32)) void {
                while (true) {
                    const i = cur.fetchAdd(1, .seq_cst);
                    if (i >= pending_slice.len) return;
                    const idx = pending_slice[i];
                    const f = prog.files.items[idx];
                    var per_file = opts;
                    per_file.is_tsx = opts.is_tsx or f.is_tsx;
                    per_file.is_declaration_file = f.is_declaration;
                    if (per_file.importer_path.len == 0) per_file.importer_path = f.path;
                    const c = ts_driver.compileSource(prog.gpa, f.source, per_file) catch {
                        _ = fail.fetchAdd(1, .seq_cst);
                        continue;
                    };
                    f.compilation = c;
                }
            }
        };

        var threads = self.gpa.alloc(std.Thread, n) catch return error.OutOfMemory;
        defer self.gpa.free(threads);
        var spawned: usize = 0;
        for (threads, 0..) |*t, i| {
            _ = i;
            t.* = std.Thread.spawn(.{}, Worker.run, .{ self, options, pending.items, &cursor, &failures }) catch {
                // If we can't spawn more workers, do the rest serially.
                Worker.run(self, options, pending.items, &cursor, &failures);
                break;
            };
            spawned += 1;
        }
        for (threads[0..spawned]) |t| t.join();

        if (failures.load(.seq_cst) > 0) {
            // Phase 5 follow-up: aggregate per-file errors. For now
            // report the most generic.
            return error.ParseError;
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
            // Defensive guard: a parse error can leave c.root pointing
            // at a non-block sentinel (e.g. recursive type files that
            // bail mid-parse). blockStmts asserts kind == .block_stmt,
            // so skip resolution for malformed roots.
            if (c.hir.kindOf(root) != .block_stmt) continue;
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

    /// Re-compile only the subset of files whose paths appear in
    /// `changed_paths`. Files not listed reuse their existing
    /// `compilation` (or remain unset if they were never compiled).
    /// Returns the count of files re-compiled.
    ///
    /// Pairs with `ts_watch.Watcher.tick()` for the watch-mode
    /// loop:
    ///   var cs = try watcher.tick();
    ///   defer cs.deinit(gpa);
    ///   const paths = try changeSetPaths(gpa, &cs);
    ///   defer gpa.free(paths);
    ///   _ = try program.recompileChanged(paths, options);
    pub fn recompileChanged(
        self: *Program,
        changed_paths: []const []const u8,
        options: ts_driver.CompileOptions,
    ) ProgramError!u32 {
        var count: u32 = 0;
        for (changed_paths) |p| {
            const id = self.by_path.get(p) orelse continue;
            const f = self.files.items[id];
            // Free the previous compilation so the new one owns
            // a fresh HIR + symbol table.
            if (f.compilation) |old| {
                old.deinit();
                self.gpa.destroy(old);
                f.compilation = null;
            }
            // Clear any cached import edges — they'll be repopulated
            // by resolveImports below.
            f.imports.clearRetainingCapacity();

            var per_file = options;
            per_file.is_tsx = options.is_tsx or f.is_tsx;
            per_file.is_declaration_file = f.is_declaration;
            const c = ts_driver.compileSource(self.gpa, f.source, per_file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ParseError,
            };
            f.compilation = c;
            try self.appendMissingImportedHelperDiagnosticsForFile(f, options);
            count += 1;
        }
        // Cross-file imports may now resolve to different ids.
        try self.resolveImports();
        return count;
    }

    fn appendMissingImportedHelperDiagnostics(self: *Program, options: ts_driver.CompileOptions) ProgramError!void {
        if (!options.emit.import_helpers) return;
        for (self.files.items) |f| {
            try self.appendMissingImportedHelperDiagnosticsForFile(f, options);
        }
    }

    fn appendMissingImportedHelperDiagnosticsForFile(self: *Program, f: *File, options: ts_driver.CompileOptions) ProgramError!void {
        if (!options.emit.import_helpers) return;
        if (f.is_declaration) return;
        if (legacyDecoratorsEnabled(f.source, options)) return;
        const c = f.compilation orelse return;
        const tslib = self.findTslibDeclaration() orelse return;

        var search_from: usize = 0;
        while (findStage3DecoratedClassExpression(f.source, search_from)) |decorated| {
            const helpers = [_][]const u8{ "__esDecorate", "__runInitializers", "__setFunctionName" };
            for (helpers) |helper| {
                if (std.mem.eql(u8, helper, "__setFunctionName") and decorated.has_class_name) continue;
                if (std.mem.indexOf(u8, tslib.source, helper) != null) continue;
                const msg = try std.fmt.allocPrint(
                    self.gpa,
                    "This syntax requires an imported helper named '{s}' which does not exist in 'tslib'. Consider upgrading your version of 'tslib'.",
                    .{helper},
                );
                try c.diagnostics.append(self.gpa, .{
                    .phase = .bind,
                    .pos = @intCast(decorated.at_pos),
                    .line = 0,
                    .span_len = @intCast(decorated.span_len),
                    .code = 2343,
                    .message = msg,
                });
                c.has_errors = true;
            }
            search_from = decorated.at_pos + 1;
        }
        sortDiagnosticsBySourceOrder(c.diagnostics.items);
    }

    fn findTslibDeclaration(self: *Program) ?*File {
        for (self.files.items) |f| {
            const base = std.fs.path.basename(f.path);
            if (std.mem.eql(u8, base, "tslib.d.ts")) return f;
        }
        return null;
    }

    const DecoratedClass = struct {
        at_pos: usize,
        span_len: usize,
        has_class_name: bool,
    };

    fn findStage3DecoratedClassExpression(source: []const u8, start: usize) ?DecoratedClass {
        var i = start;
        while (std.mem.indexOfScalarPos(u8, source, i, '@')) |at| {
            if (positionInLineComment(source, at) or positionInBlockComment(source, at)) {
                i = at + 1;
                continue;
            }
            const class_pos = findKeywordNearby(source, at + 1, "class") orelse {
                i = at + 1;
                continue;
            };
            const after_class = skipTrivia(source, class_pos + "class".len);
            const has_name = after_class < source.len and isIdentifierStart(source[after_class]);
            return .{
                .at_pos = at,
                .span_len = class_pos + "class".len - at,
                .has_class_name = has_name,
            };
        }
        return null;
    }

    fn findKeywordNearby(source: []const u8, start: usize, keyword: []const u8) ?usize {
        const max = @min(source.len, start + 256);
        var i = start;
        var paren_depth: u32 = 0;
        while (i < max) : (i += 1) {
            switch (source[i]) {
                '(' => paren_depth += 1,
                ')' => {
                    if (paren_depth > 0) paren_depth -= 1;
                },
                ';' => if (paren_depth == 0) return null,
                else => {},
            }
            if (i + keyword.len <= source.len and
                std.mem.eql(u8, source[i .. i + keyword.len], keyword) and
                (i == 0 or !isIdentifierContinue(source[i - 1])) and
                (i + keyword.len == source.len or !isIdentifierContinue(source[i + keyword.len])))
            {
                return i;
            }
        }
        return null;
    }

    fn skipTrivia(source: []const u8, start: usize) usize {
        var i = start;
        while (i < source.len) : (i += 1) {
            switch (source[i]) {
                ' ', '\t', '\r', '\n' => continue,
                else => return i,
            }
        }
        return i;
    }

    fn positionInLineComment(source: []const u8, pos: usize) bool {
        var line_start = pos;
        while (line_start > 0 and source[line_start - 1] != '\n') : (line_start -= 1) {}
        if (std.mem.indexOf(u8, source[line_start..pos], "//")) |_| return true;
        return false;
    }

    fn positionInBlockComment(source: []const u8, pos: usize) bool {
        const open = std.mem.lastIndexOf(u8, source[0..pos], "/*") orelse return false;
        const close = std.mem.lastIndexOf(u8, source[0..pos], "*/") orelse return true;
        return open > close;
    }

    fn sourceDirectiveBool(source: []const u8, name: []const u8) ?bool {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "//")) continue;
            const marker = std.mem.indexOf(u8, line, "@") orelse continue;
            const body = line[marker + 1 ..];
            const colon = std.mem.indexOfScalar(u8, body, ':') orelse continue;
            const key = std.mem.trim(u8, body[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(key, name)) continue;
            const value = std.mem.trim(u8, body[colon + 1 ..], " \t\r");
            if (std.ascii.startsWithIgnoreCase(value, "true")) return true;
            if (std.ascii.startsWithIgnoreCase(value, "false")) return false;
        }
        return null;
    }

    fn legacyDecoratorsEnabled(source: []const u8, options: ts_driver.CompileOptions) bool {
        if (sourceDirectiveBool(source, "experimentalDecorators")) |on| return on;
        if (options.pub_tsconfig) |cfg| {
            if (cfg.compiler_options.experimental_decorators) |on| return on;
        }
        return false;
    }

    fn isIdentifierStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
    }

    fn isIdentifierContinue(c: u8) bool {
        return isIdentifierStart(c) or std.ascii.isDigit(c);
    }

    fn sortDiagnosticsBySourceOrder(diags: []ts_driver.Diagnostic) void {
        const lessThan = struct {
            fn lt(_: void, a: ts_driver.Diagnostic, b: ts_driver.Diagnostic) bool {
                if (a.pos != b.pos) return a.pos < b.pos;
                if (a.span_len != 0 and b.span_len != 0 and a.span_len != b.span_len) {
                    return a.span_len < b.span_len;
                }
                return a.code < b.code;
            }
        }.lt;
        std.mem.sort(ts_driver.Diagnostic, diags, {}, lessThan);
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
// Cross-file export-table merge (declaration-emit privacy support)
// =============================================================================
//
// The per-file checker (`packages/ts_checker`) classifies a referenced
// bare type name as `imported_external` when it is bound by an `import`
// in the current file, but cannot tell whether the name is genuinely
// exported from its source module (the fact upstream establishes via
// `getExternalModuleContainer` / `isSymbolAccessibleWorker` against a
// merged symbol table). These helpers supply that cross-file fact: given
// the SOURCE of the resolved module, parse+bind it and report whether
// `name` is an exported type-space symbol, plus the module's rendered
// display name (the `{2}` diagnostic slot).
//
// We deliberately scope this to a faithful subset: a top-level
// `export`ed declaration in type space (`interface` / `type` / `class` /
// `enum`). This mirrors the `from private module` case of
// `selectDiagnosticBasedOnModuleName`. The harder alias-chain and
// `cannot be named` cases are left for a future symbol-graph merge.

/// True when `module_source` declares `name` as an exported type-space
/// symbol at module scope. Parses + binds the source through the same
/// driver pipeline the program graph uses, then queries the bound
/// module's top-level symbol table — robust against nesting, strings,
/// and comments (unlike a raw text scan). `name` is the bare identifier.
pub fn moduleExportsTypeSpaceName(
    gpa: std.mem.Allocator,
    module_source: []const u8,
    name: []const u8,
    is_tsx: bool,
) bool {
    var compilation = ts_driver.compileSource(gpa, module_source, .{
        .is_tsx = is_tsx,
        .continue_on_error = true,
        .no_emit = true,
    }) catch return false;
    defer {
        compilation.deinit();
        gpa.destroy(compilation);
    }
    // Query the TYPE-space symbol table specifically: a class declares
    // into both value and type space as separate symbols, and the
    // generic `lookupTopLevel` returns the value symbol first (which has
    // is_type=false). We want the type-space binding, so consult
    // `module.root.types` directly.
    const id = compilation.interner.lookup(name) orelse return false;
    const sym = compilation.module.root.types.get(id) orelse return false;
    return sym.flags.is_type and sym.flags.is_export;
}

/// Render the `{2}` module-name slot for the declaration-emit privacy
/// diagnostics. Upstream `symbolToString` of a file's external-module
/// symbol renders the QUOTED module stem: the basename of the resolved
/// path with its extension(s) stripped, wrapped in double quotes
/// (`"type"` for a file `type.ts` resolved from `./type`, matching the
/// `declarationEmitExpandoPropertyPrivateName` baseline's `'"a"'`).
/// Caller owns the returned slice.
pub fn renderModuleDisplayName(gpa: std.mem.Allocator, resolved_path: []const u8) ![]u8 {
    const stem = moduleStem(resolved_path);
    return std.fmt.allocPrint(gpa, "\"{s}\"", .{stem});
}

/// Basename of `path` with all trailing extensions stripped (so
/// `a.d.ts` -> `a`, `dir/type.ts` -> `type`). Pure slice, no alloc.
pub fn moduleStem(path: []const u8) []const u8 {
    var base = path;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |slash| base = base[slash + 1 ..];
    // Strip the first dot and everything after (handles `.ts`, `.d.ts`,
    // `.tsx`, `.mts`, etc.). Upstream renders the bare module stem.
    if (std.mem.indexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
    return base;
}

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

test "Program: compileAllStreaming invokes callback per file" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x: number = 1;");
    _ = try p.add("/b.ts", "let y: string = \"hi\";");
    _ = try p.add("/c.ts", "let z: boolean = true;");
    var visited: [3][]const u8 = .{ "", "", "" };
    var idx: usize = 0;
    const Ctx = struct { v: *[3][]const u8, i: *usize };
    const cb = struct {
        pub fn call(c: Ctx, file_path: []const u8, _: []const ts_driver.Diagnostic) void {
            c.v.*[c.i.*] = file_path;
            c.i.* += 1;
        }
    }.call;
    try p.compileAllStreaming(.{}, Ctx{ .v = &visited, .i = &idx }, cb);
    try T.expectEqual(@as(usize, 3), idx);
    try T.expectEqualStrings("/a.ts", visited[0]);
    try T.expectEqualStrings("/b.ts", visited[1]);
    try T.expectEqualStrings("/c.ts", visited[2]);
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
    _ = try p.add("/types.d.home", "declare const Y: number;");
    try T.expect(p.fileById(1).is_declaration);
    _ = try p.add("/native.d.node.ts", "export function doNativeThing(): unknown;");
    try T.expect(p.fileById(2).is_declaration);
}

test "Program: compileAll routes per-file is_declaration_file (no TS1039 from .tsx neighbour of .d.ts)" {
    // Multi-file program with a `.d.ts` neighbour next to a regular
    // `.tsx` file: the `.tsx` file's class-field initializer must
    // NOT inherit ambient-context semantics from the `.d.ts`
    // sibling, even when the caller passes a global
    // `options.is_declaration_file=true`. Anchors §6.A.4's
    // `tsxDynamicTagName8/9` parity fix.
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/react.d.ts", "declare module 'react' { class Component<T, U> {} }");
    _ = try p.add("/app.tsx", "export class Text { _tag: string = 'div'; }");
    try p.compileAll(.{ .is_tsx = true, .is_declaration_file = true });
    const app = p.fileById(1).compilation orelse return error.TestFailed;
    for (app.diagnostics.items) |d| {
        try T.expect(d.code != 1039);
    }
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

test "Program: compileAllParallel produces same output as serial" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    // 8 files, each with a small TS program — exercises the worker
    // pool with multiple jobs in flight at once.
    const sources = [_][]const u8{
        "let a: number = 1;",
        "let b: string = \"hi\";",
        "function id(x: number): number { return x; }",
        "class Foo { x = 1; }",
        "interface Bar { y: number; }",
        "type Pair<A, B> = [A, B];",
        "enum Color { Red, Green, Blue }",
        "let arr: number[] = [1, 2, 3];",
    };
    for (sources, 0..) |s, i| {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/f{d}.ts", .{i});
        _ = try p.add(path, s);
    }
    try p.compileAllParallel(.{}, 4);
    var emitted: usize = 0;
    for (p.files.items) |f| {
        try T.expect(f.compilation != null);
        if (f.compilation.?.js.len > 0) emitted += 1;
    }
    // Interface + type alias erase to empty JS; the rest emit
    // non-empty output. We expect at least 6 of 8.
    try T.expect(emitted >= 6);
}

test "Program: updateSource replaces a file's source bytes" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x = 1;");
    try p.compileAll(.{});
    try T.expect(p.fileById(0).compilation != null);

    const id = (try p.updateSource("/a.ts", "let y = 2;")) orelse return error.NoFile;
    // Compilation cleared; source replaced.
    try T.expect(p.fileById(id).compilation == null);
    try T.expectEqualStrings("let y = 2;", p.fileById(id).source);
}

test "Program: recompileChanged only recompiles listed paths" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let a = 1;");
    _ = try p.add("/b.ts", "let b = 2;");
    _ = try p.add("/c.ts", "let c = 3;");
    try p.compileAll(.{});

    // Touch only /b.ts.
    _ = try p.updateSource("/b.ts", "let b = 999;");
    const paths = [_][]const u8{"/b.ts"};
    const recompiled = try p.recompileChanged(&paths, .{});
    try T.expectEqual(@as(u32, 1), recompiled);
    // /a.ts and /c.ts still have their original compilation.
    try T.expect(p.fileById(0).compilation != null);
    try T.expect(p.fileById(2).compilation != null);
    // /b.ts has a fresh compilation reflecting the new source.
    const b = p.fileById(1);
    try T.expect(b.compilation != null);
    try T.expect(std.mem.indexOf(u8, b.compilation.?.js, "999") != null);
}

test "Program: emitAllToCache emits JS for every file" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x: number = 1;");
    _ = try p.add("/b.ts", "let y: string = \"hi\";");

    var cache = try ts_cache.Cache.init(T.allocator, null);
    defer cache.deinit();

    const summaries = try p.emitAllToCache(&cache, "", .{});
    defer {
        for (summaries) |*s| s.deinit(T.allocator);
        T.allocator.free(summaries);
    }
    try T.expectEqual(@as(usize, 2), summaries.len);
    for (summaries) |s| {
        try T.expect(s.js.len > 0);
        try T.expect(!s.from_cache); // first run is always a miss
    }
    // Cache now has 2 entries.
    try T.expectEqual(@as(u32, 2), cache.count());
}

test "Program: emitAllToCache second pass is cache-hit" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x: number = 1;");
    _ = try p.add("/b.ts", "let y: string = \"hi\";");

    var cache = try ts_cache.Cache.init(T.allocator, null);
    defer cache.deinit();

    const first = try p.emitAllToCache(&cache, "", .{});
    defer {
        for (first) |*s| s.deinit(T.allocator);
        T.allocator.free(first);
    }
    const second = try p.emitAllToCache(&cache, "", .{});
    defer {
        for (second) |*s| s.deinit(T.allocator);
        T.allocator.free(second);
    }
    for (second) |s| try T.expect(s.from_cache);
    // Same JS bytes.
    for (first, second) |a, b| try T.expectEqualStrings(a.js, b.js);
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

test "Program: importHelpers reports missing Stage 3 decorator helpers from tslib" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/main.ts",
        \\export {};
        \\declare var dec: any;
        \\var C;
        \\C = @dec class {};
    );
    _ = try p.add("/tslib.d.ts", "export {}\n");
    try p.compileAll(.{ .emit = .{ .import_helpers = true } });

    const c = p.fileById(0).compilation.?;
    var seen_es_decorate = false;
    var seen_run_initializers = false;
    var seen_set_function_name = false;
    for (c.diagnostics.items) |d| {
        if (d.code != 2343) continue;
        if (std.mem.indexOf(u8, d.message, "'__esDecorate'") != null) seen_es_decorate = true;
        if (std.mem.indexOf(u8, d.message, "'__runInitializers'") != null) seen_run_initializers = true;
        if (std.mem.indexOf(u8, d.message, "'__setFunctionName'") != null) seen_set_function_name = true;
    }
    try T.expect(seen_es_decorate);
    try T.expect(seen_run_initializers);
    try T.expect(seen_set_function_name);
}

test "Program: collectGlobalAugmentations finds none for plain files" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x: number = 1;");
    _ = try p.add("/b.ts", "let y: string = \"hi\";");
    try p.compileAll(.{});
    const augments = try p.collectGlobalAugmentations();
    defer T.allocator.free(augments);
    try T.expectEqual(@as(usize, 0), augments.len);
}

test "Program: collectGlobalAugmentations finds declare global block" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    // A `declare global { … }` block lowers to a top-level
    // `namespace_decl` named "global". v1 surfaces these so a future
    // pass can call `binder.Module.augment` to merge them into the
    // program's global scope.
    const id = try p.add("/g.ts", "declare global { interface Window {} }");
    try p.compileAll(.{});
    const augments = try p.collectGlobalAugmentations();
    defer T.allocator.free(augments);
    try T.expectEqual(@as(usize, 1), augments.len);
    try T.expectEqual(id, augments[0].file_id);
}

test "Program: declare global namespace roots are visible across files" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    _ = try p.add("/a.ts", "export interface Foo {}");
    _ = try p.add("/b.ts",
        \\import * as a from "./a";
        \\declare global {
        \\  namespace teams {
        \\    export namespace calling {
        \\      export import Foo = a.Foo;
        \\    }
        \\  }
        \\}
    );
    const c_id = try p.add("/c.ts", "type Foo = teams.calling.Foo; export const bar = (p?: Foo) => {}");
    try p.compileAll(.{ .no_emit = true });
    const c = p.fileById(c_id).compilation.?;
    for (c.diagnostics.items) |d| {
        try T.expect(d.code != 2503);
    }
}

test "moduleStem strips dir and extensions" {
    try T.expectEqualStrings("a", moduleStem("a.ts"));
    try T.expectEqualStrings("type", moduleStem("./type.ts"));
    try T.expectEqualStrings("foo", moduleStem("/dir/sub/foo.d.ts"));
    try T.expectEqualStrings("bar", moduleStem("bar.tsx"));
    try T.expectEqualStrings("index", moduleStem("/a/b/index.mts"));
    try T.expectEqualStrings("noext", moduleStem("noext"));
}

test "renderModuleDisplayName quotes the module stem" {
    const m = try renderModuleDisplayName(T.allocator, "./a.ts");
    defer T.allocator.free(m);
    try T.expectEqualStrings("\"a\"", m);
    const m2 = try renderModuleDisplayName(T.allocator, "/node_modules/pkg/type.d.ts");
    defer T.allocator.free(m2);
    try T.expectEqualStrings("\"type\"", m2);
}

test "moduleExportsTypeSpaceName: exported interface is a type-space export" {
    try T.expect(moduleExportsTypeSpaceName(T.allocator, "export interface I {}", "I", false));
    try T.expect(moduleExportsTypeSpaceName(T.allocator, "export type A = number;", "A", false));
    try T.expect(moduleExportsTypeSpaceName(T.allocator, "export class C {}", "C", false));
    try T.expect(moduleExportsTypeSpaceName(T.allocator, "export enum E { A }", "E", false));
}

test "moduleExportsTypeSpaceName: non-exported or value-only names are not type-space exports" {
    // Declared but NOT exported.
    try T.expect(!moduleExportsTypeSpaceName(T.allocator, "interface I {}", "I", false));
    // Exported value (const) is not a type-space symbol.
    try T.expect(!moduleExportsTypeSpaceName(T.allocator, "export const v = 1;", "v", false));
    // Exported function is value-space, not type-space.
    try T.expect(!moduleExportsTypeSpaceName(T.allocator, "export function f() {}", "f", false));
    // Absent name.
    try T.expect(!moduleExportsTypeSpaceName(T.allocator, "export interface I {}", "Missing", false));
}

test "moduleExportsTypeSpaceName: nested declarations do not leak as top-level exports" {
    // `Inner` is declared inside a namespace body, not at module scope —
    // it must NOT be reported as a top-level export of this module.
    const src =
        \\export namespace N {
        \\    export interface Inner {}
        \\}
    ;
    try T.expect(!moduleExportsTypeSpaceName(T.allocator, src, "Inner", false));
    // The namespace itself is a namespace-space export, not type-space.
    try T.expect(!moduleExportsTypeSpaceName(T.allocator, src, "N", false));
}
