//! TS bundler v0 — Phase 4.5 scaffold.
//!
//! Minimal "concat-mode" bundler that demonstrates the end-to-end
//! shape: register entry files, compile each via `ts_driver`, then
//! concatenate the emitted JavaScript into a single output.
//!
//! This is intentionally minimal. The full Bun-bundler integration
//! (§4.5.A.* in the parity plan) is a multi-week effort that adds
//! tree-shaking, dead-code elimination, chunk-splitting, source-map
//! merging, and minification. For now this v0 just proves the
//! pipeline so other tools (CLI, watcher) can wire against a stable
//! `Bundler` API while the real implementation lands underneath.

const std = @import("std");
const ts_program = @import("ts_program");
const ts_driver = @import("ts_driver");

/// Output format selector.
pub const Format = enum {
    /// Wrap the concatenated output in `(function () { ... })();`
    /// so module-scoped declarations don't leak to the global scope.
    iife,
    /// Plain concatenation. ESM is the default in modern bundlers and
    /// preserves top-level `import`/`export` semantics. Today the v0
    /// scaffold just concatenates — proper ESM hoisting is follow-up.
    esm,
};

pub const BundleOptions = struct {
    format: Format = .esm,
    /// When true, run a (future) minifier over the concatenated output.
    /// v0 ignores this flag — it's part of the surface so callers can
    /// already opt in; the real minifier ships with §4.5.A.4.
    minify: bool = false,
};

pub const BundleError = error{
    OutOfMemory,
    NoEntryPoints,
    FileReadFailed,
    CompileFailed,
};

/// Per-entry record. We hold onto the path so callers can register
/// entries before they have an allocator with a long-lived arena —
/// the path slice is duped into our gpa on `addEntry`.
const Entry = struct {
    path: []u8,
};

pub const Bundler = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry),

    pub fn init(gpa: std.mem.Allocator) Bundler {
        return .{ .gpa = gpa, .entries = .empty };
    }

    pub fn deinit(self: *Bundler) void {
        for (self.entries.items) |e| self.gpa.free(e.path);
        self.entries.deinit(self.gpa);
    }

    /// Register an entry point. The path is duped into the bundler's
    /// allocator so the caller's slice can go out of scope.
    pub fn addEntry(self: *Bundler, path: []const u8) !void {
        const dup = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(dup);
        try self.entries.append(self.gpa, .{ .path = dup });
    }

    /// Run the per-entry compile pipeline and concatenate the emitted
    /// JavaScript. Caller owns the returned slice and must free it
    /// with `gpa`.
    pub fn bundle(self: *Bundler, gpa: std.mem.Allocator, options: BundleOptions) BundleError![]u8 {
        if (self.entries.items.len == 0) return error.NoEntryPoints;

        // Threaded I/O context — Phase 4.5 uses synchronous reads;
        // the Bun-bundler integration will move to async + worker
        // pools so multiple entries compile in parallel.
        var threaded = std.Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);

        if (options.format == .iife) {
            out.appendSlice(gpa, "(function () {\n") catch return error.OutOfMemory;
        }

        for (self.entries.items) |entry| {
            const source = readAll(gpa, io, cwd, entry.path) catch return error.FileReadFailed;
            defer gpa.free(source);

            var c = ts_driver.compileSource(gpa, source, .{}) catch {
                return error.CompileFailed;
            };
            defer {
                c.deinit();
                gpa.destroy(c);
            }

            out.appendSlice(gpa, c.js) catch return error.OutOfMemory;
            // Ensure each module's emit ends on a newline so the next
            // entry doesn't accidentally splice its first line onto
            // the previous one.
            if (c.js.len > 0 and c.js[c.js.len - 1] != '\n') {
                out.append(gpa, '\n') catch return error.OutOfMemory;
            }
        }

        if (options.format == .iife) {
            out.appendSlice(gpa, "})();\n") catch return error.OutOfMemory;
        }

        // `minify` is a forward-compat hook. v0 just returns the
        // concatenated bytes unchanged.
        _ = options.minify;

        return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
    }
};

/// Slurp a file from `cwd` into a freshly-allocated buffer (caller
/// frees with `gpa`).
fn readAll(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) ![]u8 {
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);
    var read_total: usize = 0;
    while (read_total < size) {
        const n = try file.readPositionalAll(io, buf[read_total..], read_total);
        if (n == 0) break;
        read_total += n;
    }
    return buf;
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "Bundler: single-entry concat produces expected JS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "main.ts", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "let x: number = 42;");
    }
    const path_z = try tmp.dir.realPathFileAlloc(io, "main.ts", T.allocator);
    defer T.allocator.free(path_z);
    const path: []const u8 = path_z;

    var b = Bundler.init(T.allocator);
    defer b.deinit();
    try b.addEntry(path);

    const js = try b.bundle(T.allocator, .{ .format = .esm, .minify = false });
    defer T.allocator.free(js);

    // The driver erases the type annotation; the variable + value
    // survive into the emit.
    try T.expect(std.mem.indexOf(u8, js, "let x") != null);
    try T.expect(std.mem.indexOf(u8, js, "42") != null);
    // ESM mode: no IIFE wrapper.
    try T.expect(std.mem.indexOf(u8, js, "(function () {") == null);
}

test "Bundler: IIFE wrap shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "main.ts", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "let y = 1;");
    }
    const path_z = try tmp.dir.realPathFileAlloc(io, "main.ts", T.allocator);
    defer T.allocator.free(path_z);
    const path: []const u8 = path_z;

    var b = Bundler.init(T.allocator);
    defer b.deinit();
    try b.addEntry(path);

    const js = try b.bundle(T.allocator, .{ .format = .iife, .minify = false });
    defer T.allocator.free(js);

    // Must open with the IIFE prologue and end with the immediate-
    // invocation epilogue.
    try T.expect(std.mem.startsWith(u8, js, "(function () {\n"));
    try T.expect(std.mem.endsWith(u8, js, "})();\n"));
    // The compiled body sits between the wrappers.
    try T.expect(std.mem.indexOf(u8, js, "let y") != null);
}
