//! Salsa-style incremental wrapper around `ts_program.Program`.
//!
//! Per TS_PARITY_PLAN §5.A.1. The full Salsa engine lives in
//! `packages/query/`. This package demonstrates the pattern by wiring
//! a per-file content-hash cache into the compile pipeline so repeated
//! `query()` calls only re-run the per-file driver on files whose
//! source bytes actually changed.
//!
//! The cache here is intentionally small — one slot ("compileFile",
//! keyed by path, value = content hash + last-compiled revision). It
//! is *not* the production query DB; instead it shows how the program
//! graph would surface a single derived query through the engine.
//!
//! Usage:
//! ```zig
//! var qp = try QueryProgram.init(gpa, &program);
//! defer qp.deinit();
//! _ = try qp.query(.{}); // first call: compiles every file
//! _ = try qp.query(.{}); // second call: zero work
//! _ = try program.updateSource("/a.ts", "let x = 2;");
//! _ = try qp.query(.{}); // re-compiles only /a.ts
//! ```

const std = @import("std");
const ts_program = @import("ts_program");
const ts_driver = @import("ts_driver");

pub const QueryError = ts_program.ProgramError;

/// Stats returned by `query()`. `compiled` is the number of files the
/// pipeline actually ran on this call; `skipped` is the number whose
/// cached compilation was reused.
pub const QueryStats = struct {
    compiled: u32,
    skipped: u32,
    revision: u32,
};

/// Per-file cache entry. We track the FNV-1a hash of the source bytes
/// at the time of the last successful compile, plus the revision at
/// which that compile happened. A file is "current" iff its source
/// bytes still hash to `source_hash` AND it has a non-null
/// `compilation` on the program.
///
/// `dependencies` is the set of FileIds this file imports — captured
/// at the time of the last successful compile. When a file's content
/// hash changes, we walk back up the reverse-dependency graph and
/// invalidate every dependent's cache entry (transitively). This
/// mirrors how Salsa propagates "did the input change?" up to derived
/// queries.
const Entry = struct {
    source_hash: u64,
    last_compile_revision: u32,
    dependencies: std.ArrayListUnmanaged(ts_program.FileId),

    fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        self.dependencies.deinit(gpa);
    }
};

pub const QueryProgram = struct {
    gpa: std.mem.Allocator,
    program: *ts_program.Program,
    /// Per-file last-known-good cache. Keyed by FileId.
    entries: std.AutoHashMapUnmanaged(ts_program.FileId, Entry),
    /// Bumped on every `query()` call so callers can correlate stats
    /// across runs.
    revision: u32,

    pub fn init(gpa: std.mem.Allocator, program: *ts_program.Program) QueryProgram {
        return .{
            .gpa = gpa,
            .program = program,
            .entries = .empty,
            .revision = 0,
        };
    }

    pub fn deinit(self: *QueryProgram) void {
        var it = self.entries.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.gpa);
        self.entries.deinit(self.gpa);
    }

    /// Run the compile query against the program. Files whose source
    /// bytes hash unchanged AND already have a cached compilation are
    /// skipped — the existing `*ts_driver.Compilation` is left in
    /// place. New / dirty / never-compiled files run through the
    /// per-file driver.
    pub fn query(self: *QueryProgram, options: ts_driver.CompileOptions) QueryError!QueryStats {
        self.revision += 1;
        var compiled: u32 = 0;
        var skipped: u32 = 0;

        for (self.program.files.items) |f| {
            const h = hashSource(f.source);
            if (self.entries.get(f.id)) |entry| {
                if (entry.source_hash == h and f.compilation != null) {
                    skipped += 1;
                    continue;
                }
            }

            // Drop any stale compilation before re-running the
            // pipeline — `updateSource` does this for us, but a caller
            // who mutates `f.source` directly is also covered.
            if (f.compilation) |old| {
                old.deinit();
                self.gpa.destroy(old);
                f.compilation = null;
            }

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
            // Replace any pre-existing entry's dep list before we
            // overwrite it (avoids leaking the prior ArrayListUnmanaged).
            if (self.entries.getPtr(f.id)) |old| old.deinit(self.gpa);
            try self.entries.put(self.gpa, f.id, .{
                .source_hash = h,
                .last_compile_revision = self.revision,
                .dependencies = .empty,
            });
            compiled += 1;
        }

        // Cross-file imports may need re-resolving if any file was
        // re-compiled (its HIR is fresh). `compileAll` is a no-op for
        // already-compiled files, so we can call it cheaply here to
        // pick up any new imports — it internally calls
        // resolveImports on every invocation.
        if (compiled > 0) {
            try self.program.compileAll(options);
            // Snapshot each file's import set into its cache entry.
            // We do this *after* compileAll so resolveImports has
            // populated `f.imports` for fresh compiles.
            try self.snapshotDependencies();
        }

        return .{
            .compiled = compiled,
            .skipped = skipped,
            .revision = self.revision,
        };
    }

    /// Copy each file's resolved import list into its cache entry.
    /// Called after every compile pass so the dependency graph the
    /// invalidator walks is the one the most recent compile produced.
    fn snapshotDependencies(self: *QueryProgram) QueryError!void {
        for (self.program.files.items) |f| {
            const entry = self.entries.getPtr(f.id) orelse continue;
            entry.dependencies.clearRetainingCapacity();
            try entry.dependencies.appendSlice(self.gpa, f.imports.items);
        }
    }

    /// If `path` isn't tracked in the program, returns
    /// `error.NotFound`. If the new content hashes to the same value
    /// as the cached entry, returns `false` and does no work — the
    /// existing compilation stays in place. Otherwise updates the
    /// program's source, invalidates this file plus every transitive
    /// dependent, runs the compile pipeline, and returns `true`.
    pub fn recompileIfChanged(
        self: *QueryProgram,
        path: []const u8,
        new_content: []const u8,
    ) QueryError!bool {
        const id = self.program.lookupPath(path) orelse return error.NotFound;
        const new_hash = hashSource(new_content);
        if (self.entries.get(id)) |entry| {
            // Same content + still has a live compilation => no work.
            const f = self.program.fileById(id);
            if (entry.source_hash == new_hash and f.compilation != null) {
                return false;
            }
        }

        // Content changed (or we've never compiled it). Push the new
        // bytes through the program and invalidate dependents.
        _ = try self.program.updateSource(path, new_content);
        self.invalidateDependents(id);
        // Drop the changed file's own entry so the next query() pass
        // recompiles it.
        if (self.entries.fetchRemove(id)) |kv| {
            var e = kv.value;
            e.deinit(self.gpa);
        }
        _ = try self.query(.{});
        return true;
    }

    /// Walk every cached entry and drop those that (transitively)
    /// depend on `changed`. Uses the dependency snapshot stored in
    /// each entry, not the live `f.imports` — so an entry is
    /// invalidated based on the imports observed at *its* last
    /// compile, which is what Salsa-style invalidation requires.
    ///
    /// Also nulls out each dependent file's `compilation` so the
    /// next `query()` pass re-runs the per-file driver.
    fn invalidateDependents(self: *QueryProgram, changed: ts_program.FileId) void {
        // BFS over reverse-dependency edges. We rebuild the reverse
        // graph from the snapshot each call — the cache is small and
        // this keeps the data structure simple.
        var dirty: std.AutoHashMapUnmanaged(ts_program.FileId, void) = .empty;
        defer dirty.deinit(self.gpa);
        dirty.put(self.gpa, changed, {}) catch return;

        var changed_count_prev: usize = 0;
        while (dirty.count() != changed_count_prev) {
            changed_count_prev = dirty.count();
            var it = self.entries.iterator();
            while (it.next()) |kv| {
                const file_id = kv.key_ptr.*;
                if (dirty.contains(file_id)) continue;
                for (kv.value_ptr.dependencies.items) |dep| {
                    if (dirty.contains(dep)) {
                        dirty.put(self.gpa, file_id, {}) catch return;
                        break;
                    }
                }
            }
        }

        // Drop entries + compilations for every file we marked dirty
        // *except* `changed` itself — the caller handles that one.
        var dit = dirty.iterator();
        while (dit.next()) |d| {
            const file_id = d.key_ptr.*;
            if (file_id == changed) continue;
            if (self.entries.fetchRemove(file_id)) |kv| {
                var e = kv.value;
                e.deinit(self.gpa);
            }
            const f = self.program.fileById(file_id);
            if (f.compilation) |old| {
                old.deinit();
                self.gpa.destroy(old);
                f.compilation = null;
            }
        }
    }

    /// Inspect: the cached dependency set for `id` from its last
    /// compile, or `null` if we've never compiled it.
    pub fn cachedDependencies(self: *const QueryProgram, id: ts_program.FileId) ?[]const ts_program.FileId {
        const e = self.entries.getPtr(id) orelse return null;
        return e.dependencies.items;
    }

    /// Inspect: was this file compiled (or skipped) on the most
    /// recent `query()` call?
    pub fn lastCompileRevision(self: *const QueryProgram, id: ts_program.FileId) ?u32 {
        const e = self.entries.get(id) orelse return null;
        return e.last_compile_revision;
    }
};

/// FNV-1a 64-bit. Plenty of bits to avoid collisions on the file
/// counts we care about; ~2GB/s on modern hardware.
fn hashSource(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// =============================================================================
// Tests
// =============================================================================

const ts_resolver = @import("ts_resolver");
const T = std.testing;

test "QueryProgram: first call compiles every file" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = ts_program.Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x: number = 1;");
    _ = try p.add("/b.ts", "let y: string = \"hi\";");

    var qp = QueryProgram.init(T.allocator, &p);
    defer qp.deinit();

    const stats = try qp.query(.{});
    try T.expectEqual(@as(u32, 2), stats.compiled);
    try T.expectEqual(@as(u32, 0), stats.skipped);
    try T.expectEqual(@as(u32, 1), stats.revision);
    for (p.files.items) |f| try T.expect(f.compilation != null);
}

test "QueryProgram: second call with no edits skips every file" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = ts_program.Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x: number = 1;");
    _ = try p.add("/b.ts", "let y: string = \"hi\";");
    _ = try p.add("/c.ts", "let z: boolean = true;");

    var qp = QueryProgram.init(T.allocator, &p);
    defer qp.deinit();

    _ = try qp.query(.{});
    const second = try qp.query(.{});
    try T.expectEqual(@as(u32, 0), second.compiled);
    try T.expectEqual(@as(u32, 3), second.skipped);
    try T.expectEqual(@as(u32, 2), second.revision);
}

test "QueryProgram: edited file recompiles, untouched files skip" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = ts_program.Program.init(T.allocator, &resolver);
    defer p.deinit();
    const a = try p.add("/a.ts", "let a = 1;");
    _ = try p.add("/b.ts", "let b = 2;");
    _ = try p.add("/c.ts", "let c = 3;");

    var qp = QueryProgram.init(T.allocator, &p);
    defer qp.deinit();

    _ = try qp.query(.{});
    // Touch only /a.ts.
    _ = try p.updateSource("/a.ts", "let a = 999;");

    const stats = try qp.query(.{});
    try T.expectEqual(@as(u32, 1), stats.compiled);
    try T.expectEqual(@as(u32, 2), stats.skipped);
    try T.expect(std.mem.indexOf(u8, p.fileById(a).compilation.?.js, "999") != null);
}

test "QueryProgram: recompileIfChanged returns false when content unchanged" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = ts_program.Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x = 1;");

    var qp = QueryProgram.init(T.allocator, &p);
    defer qp.deinit();

    _ = try qp.query(.{});
    const rev_before = qp.revision;
    // Same bytes => no recompile, no revision bump.
    const changed = try qp.recompileIfChanged("/a.ts", "let x = 1;");
    try T.expect(!changed);
    try T.expectEqual(rev_before, qp.revision);
}

test "QueryProgram: recompileIfChanged returns true when content differs" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = ts_program.Program.init(T.allocator, &resolver);
    defer p.deinit();
    const a = try p.add("/a.ts", "let x = 1;");

    var qp = QueryProgram.init(T.allocator, &p);
    defer qp.deinit();

    _ = try qp.query(.{});
    const rev_before = qp.revision;
    const changed = try qp.recompileIfChanged("/a.ts", "let x = 42;");
    try T.expect(changed);
    try T.expect(qp.revision > rev_before);
    try T.expect(std.mem.indexOf(u8, p.fileById(a).compilation.?.js, "42") != null);
}

test "QueryProgram: A imports B; B changing invalidates A" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/a.ts", "import { y } from './b'; export let z = y;");
    try vfs.addFile("/proj/b.ts", "export let y = 1;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = ts_program.Program.init(T.allocator, &resolver);
    defer p.deinit();
    const a_id = try p.add("/proj/a.ts", "import { y } from './b'; export let z = y;");
    const b_id = try p.add("/proj/b.ts", "export let y = 1;");

    var qp = QueryProgram.init(T.allocator, &p);
    defer qp.deinit();

    _ = try qp.query(.{});
    // After the initial compile, A's cached dependency set should
    // include B.
    const a_deps = qp.cachedDependencies(a_id) orelse return error.MissingEntry;
    var found_b = false;
    for (a_deps) |d| {
        if (d == b_id) found_b = true;
    }
    try T.expect(found_b);

    // Touch B. Even though A's bytes are identical, A should be
    // recompiled because its dependency changed.
    const changed = try qp.recompileIfChanged("/proj/b.ts", "export let y = 999;");
    try T.expect(changed);
    // The latest query() bumped revision and recompiled both A
    // (transitive) and B (direct).
    const a_rev = qp.lastCompileRevision(a_id) orelse return error.MissingEntry;
    const b_rev = qp.lastCompileRevision(b_id) orelse return error.MissingEntry;
    try T.expectEqual(qp.revision, a_rev);
    try T.expectEqual(qp.revision, b_rev);
}

test "QueryProgram: identical updateSource value still skips on next query" {
    // updateSource clears `compilation`, so the next query *will*
    // recompile — but the cache should record the same hash and on
    // the call after that, skip again.
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = ts_program.Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "let x = 1;");

    var qp = QueryProgram.init(T.allocator, &p);
    defer qp.deinit();

    _ = try qp.query(.{}); // compile
    _ = try p.updateSource("/a.ts", "let x = 1;"); // same content!
    const after = try qp.query(.{});
    // Hash matches the cached entry but compilation was nulled by
    // updateSource — so we must re-run. After this call though, the
    // cache is back in sync.
    try T.expectEqual(@as(u32, 1), after.compiled);
    const final = try qp.query(.{});
    try T.expectEqual(@as(u32, 1), final.skipped);
}
