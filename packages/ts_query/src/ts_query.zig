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
const Entry = struct {
    source_hash: u64,
    last_compile_revision: u32,
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
            try self.entries.put(self.gpa, f.id, .{
                .source_hash = h,
                .last_compile_revision = self.revision,
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
        }

        return .{
            .compiled = compiled,
            .skipped = skipped,
            .revision = self.revision,
        };
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
