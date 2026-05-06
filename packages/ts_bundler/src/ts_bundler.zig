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
    /// When true, run a naive minifier over the concatenated output:
    /// trim leading/trailing whitespace per line, collapse runs of
    /// spaces, and drop trailing semicolons before `}`. This is a
    /// stand-in for a real minifier (§4.5.A.4) but materially shrinks
    /// the emit for v0 callers.
    minify: bool = false,
    /// When true, run a v0 tree-shaking pass over each compiled module
    /// before concatenation. The pass is approximate — it drops
    /// top-level `function name(...)` declarations whose name does not
    /// appear anywhere else in the module's emit. It's enough to
    /// demonstrate the shape; the real graph-walking shaker lands with
    /// the Bun-bundler integration.
    tree_shake: bool = false,
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

            if (options.tree_shake) {
                const shaken = treeShake(gpa, c.js) catch return error.OutOfMemory;
                defer gpa.free(shaken);
                out.appendSlice(gpa, shaken) catch return error.OutOfMemory;
                if (shaken.len > 0 and shaken[shaken.len - 1] != '\n') {
                    out.append(gpa, '\n') catch return error.OutOfMemory;
                }
            } else {
                out.appendSlice(gpa, c.js) catch return error.OutOfMemory;
                // Ensure each module's emit ends on a newline so the
                // next entry doesn't accidentally splice its first
                // line onto the previous one.
                if (c.js.len > 0 and c.js[c.js.len - 1] != '\n') {
                    out.append(gpa, '\n') catch return error.OutOfMemory;
                }
            }
        }

        if (options.format == .iife) {
            out.appendSlice(gpa, "})();\n") catch return error.OutOfMemory;
        }

        if (options.minify) {
            const raw = out.toOwnedSlice(gpa) catch return error.OutOfMemory;
            defer gpa.free(raw);
            return minify(gpa, raw) catch return error.OutOfMemory;
        }

        return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
    }
};

/// Approximate v0 tree-shaker. Walks the emit line-by-line and drops
/// top-level `function NAME(...) { ... }` blocks whose `NAME` does not
/// appear anywhere else in the same emit (i.e. the symbol is declared
/// but never referenced). Returns a freshly-allocated slice owned by
/// the caller.
fn treeShake(gpa: std.mem.Allocator, js: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < js.len) {
        // Find the start of the current line.
        const line_start = i;
        var line_end = i;
        while (line_end < js.len and js[line_end] != '\n') : (line_end += 1) {}
        const line = js[line_start..line_end];

        // Detect a top-level `function NAME(` at column 0 (no leading
        // whitespace). Anything indented is treated as nested and
        // preserved untouched.
        const fn_kw = "function ";
        if (std.mem.startsWith(u8, line, fn_kw)) {
            const name_start = fn_kw.len;
            var name_end = name_start;
            while (name_end < line.len and isIdentChar(line[name_end])) : (name_end += 1) {}
            if (name_end > name_start and name_end < line.len and line[name_end] == '(') {
                const name = line[name_start..name_end];
                // The block always opens with `{` either on this line
                // or shortly after; we span until the matching `}`.
                if (findBlockEnd(js, line_start)) |block_end| {
                    // Look for any other reference to `name` outside
                    // the declaration block. If none, drop it.
                    const before = js[0..line_start];
                    const after = if (block_end < js.len) js[block_end..] else js[js.len..js.len];
                    if (containsIdent(before, name) or containsIdent(after, name)) {
                        try out.appendSlice(gpa, js[line_start..block_end]);
                    } // else: skip — unreachable top-level fn.
                    i = block_end;
                    continue;
                }
                // Malformed — fall through to default copy path.
            }
        }

        // Default path: copy the line plus its trailing newline (if any).
        const copy_end = if (line_end < js.len) line_end + 1 else js.len;
        try out.appendSlice(gpa, js[line_start..copy_end]);
        i = copy_end;
    }

    return out.toOwnedSlice(gpa);
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$';
}

/// Whole-word identifier search — avoids matching `foo` inside `foobar`.
fn containsIdent(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.mem.eql(u8, haystack[i .. i + needle.len], needle)) continue;
        const left_ok = i == 0 or !isIdentChar(haystack[i - 1]);
        const right_ok = i + needle.len == haystack.len or !isIdentChar(haystack[i + needle.len]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

/// Locate the byte index immediately after the `}` that closes the
/// brace-delimited block starting at or after `start`. Naive (no
/// string/comment awareness) — sufficient for the v0 emit shape.
fn findBlockEnd(js: []const u8, start: usize) ?usize {
    var i: usize = start;
    while (i < js.len and js[i] != '{') : (i += 1) {}
    if (i >= js.len) return null;
    var depth: usize = 0;
    while (i < js.len) : (i += 1) {
        switch (js[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    var end = i + 1;
                    if (end < js.len and js[end] == '\n') end += 1;
                    return end;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Naive minifier: trim leading/trailing whitespace per line, collapse
/// runs of spaces inside lines to a single space, and drop a trailing
/// `;` immediately before `}`. Returns a freshly-allocated slice owned
/// by the caller.
fn minify(gpa: std.mem.Allocator, js: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var line_iter = std.mem.splitScalar(u8, js, '\n');
    var first = true;
    while (line_iter.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (trimmed.len == 0) continue;

        // Collapse runs of spaces inside the line.
        var prev_space = false;
        var line_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer line_buf.deinit(gpa);
        for (trimmed) |c| {
            if (c == ' ' or c == '\t') {
                if (!prev_space) try line_buf.append(gpa, ' ');
                prev_space = true;
            } else {
                try line_buf.append(gpa, c);
                prev_space = false;
            }
        }

        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, line_buf.items);
    }

    // Drop `;` before any `}` (skipping intervening whitespace/newlines).
    var compacted: std.ArrayListUnmanaged(u8) = .empty;
    errdefer compacted.deinit(gpa);
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        if (out.items[i] == ';') {
            var j: usize = i + 1;
            while (j < out.items.len and (out.items[j] == ' ' or out.items[j] == '\n' or out.items[j] == '\t')) : (j += 1) {}
            if (j < out.items.len and out.items[j] == '}') {
                continue; // skip the `;`
            }
        }
        try compacted.append(gpa, out.items[i]);
    }
    out.deinit(gpa);
    return compacted.toOwnedSlice(gpa);
}

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

test "Bundler: tree-shake drops unreachable top-level fn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "main.ts", .{ .truncate = true });
        defer f.close(io);
        // `used` is referenced from the call below; `unused` is not
        // referenced anywhere, so the v0 shaker should drop it.
        try f.writeStreamingAll(io,
            \\function used(a, b) { return a + b; }
            \\function unused(x) { return x + 1; }
            \\let r = used(1, 2);
        );
    }
    const path_z = try tmp.dir.realPathFileAlloc(io, "main.ts", T.allocator);
    defer T.allocator.free(path_z);
    const path: []const u8 = path_z;

    var b = Bundler.init(T.allocator);
    defer b.deinit();
    try b.addEntry(path);

    const js = try b.bundle(T.allocator, .{ .tree_shake = true });
    defer T.allocator.free(js);

    try T.expect(std.mem.indexOf(u8, js, "function used") != null);
    try T.expect(std.mem.indexOf(u8, js, "function unused") == null);
}

test "Bundler: minify strips leading whitespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "main.ts", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\function add(a, b) {
            \\  return a + b;
            \\}
            \\let r = add(1, 2);
        );
    }
    const path_z = try tmp.dir.realPathFileAlloc(io, "main.ts", T.allocator);
    defer T.allocator.free(path_z);
    const path: []const u8 = path_z;

    var b = Bundler.init(T.allocator);
    defer b.deinit();
    try b.addEntry(path);

    const js = try b.bundle(T.allocator, .{ .minify = true });
    defer T.allocator.free(js);

    // No line in the minified emit may begin with whitespace.
    var it = std.mem.splitScalar(u8, js, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try T.expect(line[0] != ' ' and line[0] != '\t');
    }
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
