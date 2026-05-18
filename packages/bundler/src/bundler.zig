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
    /// When true, `bundleWithMap` will produce a stub source map
    /// alongside the JS output. The v0 stub records `version: 3` and
    /// the list of source paths but emits an empty `mappings` string —
    /// real position-mapping aggregation lands with the Bun-bundler
    /// integration (§4.5.A.5).
    source_map: bool = false,
    /// When true, skip emitting an entry whose path has already been
    /// bundled in this `bundle` call. Prevents duplicated module emit
    /// when callers register the same shared module under multiple
    /// entry points. Transitive-import deduplication is follow-up; v0
    /// only dedupes at the entry-list level.
    deduplicate: bool = true,
    /// When true, `bundleWithManifest` will produce a JSON manifest
    /// alongside the JS output. The manifest follows the conventional
    /// bundler shape:
    ///   `{ "version": 1, "outputs": { "out.js": { "entries": [...], "size": N } } }`
    /// Frameworks consume this for SSR/hydration/asset versioning.
    manifest: bool = false,
};

/// JS + optional source map pair returned by `bundleWithMap`. The
/// `map` slice is non-null when `BundleOptions.source_map` is true.
/// Caller owns both slices and must free them with `gpa`.
pub const BundleResult = struct {
    js: []u8,
    map: ?[]u8,
};

/// JS bundle + JSON manifest pair returned by `bundleWithManifest`.
/// Caller owns both slices and must free them with `gpa`.
pub const ManifestResult = struct {
    bundle: []u8,
    manifest: []u8,
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

        // Track which entry paths have already been emitted in this
        // bundle call so a shared module registered under multiple
        // entries isn't duplicated. Keys reference `entry.path` slices
        // owned by the bundler — no extra allocation needed.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);

        if (options.format == .iife) {
            out.appendSlice(gpa, "(function () {\n") catch return error.OutOfMemory;
        }

        for (self.entries.items) |entry| {
            if (options.deduplicate) {
                const gop = seen.getOrPut(gpa, entry.path) catch return error.OutOfMemory;
                if (gop.found_existing) continue;
            }
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

    /// Run `bundle` and, when `options.source_map` is true, additionally
    /// emit a stub v3 source map JSON document listing the registered
    /// entry paths. The v0 stub deliberately produces an empty
    /// `mappings` string — proper position aggregation lands with the
    /// Bun-bundler integration. Caller owns both slices in the returned
    /// `BundleResult` and must free them with `gpa`.
    pub fn bundleWithMap(self: *Bundler, gpa: std.mem.Allocator, options: BundleOptions) BundleError!BundleResult {
        const js = try self.bundle(gpa, options);
        errdefer gpa.free(js);

        if (!options.source_map) {
            return .{ .js = js, .map = null };
        }

        var map: std.ArrayListUnmanaged(u8) = .empty;
        errdefer map.deinit(gpa);

        map.appendSlice(gpa, "{\"version\": 3, \"sources\": [") catch return error.OutOfMemory;
        for (self.entries.items, 0..) |entry, idx| {
            if (idx > 0) map.appendSlice(gpa, ", ") catch return error.OutOfMemory;
            map.append(gpa, '"') catch return error.OutOfMemory;
            for (entry.path) |c| {
                // JSON-escape the two characters that could appear in a
                // filesystem path and break the JSON shape: backslash
                // (Windows separators) and double quote.
                if (c == '\\' or c == '"') map.append(gpa, '\\') catch return error.OutOfMemory;
                map.append(gpa, c) catch return error.OutOfMemory;
            }
            map.append(gpa, '"') catch return error.OutOfMemory;
        }
        map.appendSlice(gpa, "], \"mappings\": \"\"}") catch return error.OutOfMemory;

        const map_slice = map.toOwnedSlice(gpa) catch return error.OutOfMemory;
        return .{ .js = js, .map = map_slice };
    }

    /// Run `bundle` and produce a JSON manifest describing the emit.
    /// Manifest shape:
    ///   `{ "version": 1, "outputs": { "out.js": { "entries": [...], "size": N } } }`
    /// The output filename is fixed as `out.js` for the v0 single-chunk
    /// emit; chunk-splitting follow-up will populate richer entries.
    /// Caller owns both slices in the returned `ManifestResult` and must
    /// free them with `gpa`.
    pub fn bundleWithManifest(self: *Bundler, gpa: std.mem.Allocator, options: BundleOptions) BundleError!ManifestResult {
        const js = try self.bundle(gpa, options);
        errdefer gpa.free(js);

        var manifest: std.ArrayListUnmanaged(u8) = .empty;
        errdefer manifest.deinit(gpa);

        manifest.appendSlice(gpa, "{\"version\": 1, \"outputs\": {\"out.js\": {\"entries\": [") catch return error.OutOfMemory;
        for (self.entries.items, 0..) |entry, idx| {
            if (idx > 0) manifest.appendSlice(gpa, ", ") catch return error.OutOfMemory;
            manifest.append(gpa, '"') catch return error.OutOfMemory;
            for (entry.path) |c| {
                // JSON-escape the two characters that could appear in a
                // filesystem path and break the JSON shape.
                if (c == '\\' or c == '"') manifest.append(gpa, '\\') catch return error.OutOfMemory;
                manifest.append(gpa, c) catch return error.OutOfMemory;
            }
            manifest.append(gpa, '"') catch return error.OutOfMemory;
        }
        manifest.appendSlice(gpa, "], \"size\": ") catch return error.OutOfMemory;
        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{js.len}) catch return error.OutOfMemory;
        manifest.appendSlice(gpa, size_str) catch return error.OutOfMemory;
        manifest.appendSlice(gpa, "}}}") catch return error.OutOfMemory;

        const manifest_slice = manifest.toOwnedSlice(gpa) catch return error.OutOfMemory;
        return .{ .bundle = js, .manifest = manifest_slice };
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

        // Detect a top-level `import ...` line. We extract the bound
        // names and drop the entire import if none of them are
        // referenced anywhere else in the bundle. Naive: doesn't
        // attempt to remove individual unused bindings within an
        // otherwise-used import.
        const import_kw = "import ";
        if (std.mem.startsWith(u8, line, import_kw)) {
            const before = js[0..line_start];
            const line_advance_end = if (line_end < js.len) line_end + 1 else js.len;
            const after = if (line_advance_end < js.len) js[line_advance_end..] else js[js.len..js.len];
            if (importHasUsedBinding(line, before, after)) {
                try out.appendSlice(gpa, js[line_start..line_advance_end]);
            } // else: skip — fully-unused import.
            i = line_advance_end;
            continue;
        }

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

/// Inspect a single `import ...` line and return true if at least one
/// of its bound names is referenced in `before` or `after`. Handles
/// the three v0 import shapes:
///   - `import x from "..."`
///   - `import { a, b as c } from "..."`
///   - `import * as ns from "..."`
/// Anything we don't recognize is conservatively treated as "used"
/// (i.e. preserved) so we never drop a side-effect import.
fn importHasUsedBinding(line: []const u8, before: []const u8, after: []const u8) bool {
    // Strip the leading `import ` keyword.
    const import_kw = "import ";
    if (!std.mem.startsWith(u8, line, import_kw)) return true;
    var rest = line[import_kw.len..];
    // Trim leading whitespace.
    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
    if (rest.len == 0) return true;

    // Side-effect-only import: `import "mod";` — no bindings, must keep.
    if (rest[0] == '"' or rest[0] == '\'') return true;

    // Locate the ` from ` keyword that separates bindings from the
    // module specifier. If absent we conservatively keep the line.
    const from_idx = std.mem.indexOf(u8, rest, " from ") orelse return true;
    const bindings_part = rest[0..from_idx];

    // Namespace import: `* as ns`.
    if (std.mem.startsWith(u8, bindings_part, "*")) {
        const as_idx = std.mem.indexOf(u8, bindings_part, " as ") orelse return true;
        var ns = bindings_part[as_idx + 4 ..];
        ns = std.mem.trim(u8, ns, " \t");
        if (ns.len == 0) return true;
        return containsIdent(before, ns) or containsIdent(after, ns);
    }

    // Split bindings into a default name (before any `{`) and a named
    // list (between `{` and `}`).
    var default_name: []const u8 = &[_]u8{};
    var named_list: []const u8 = &[_]u8{};
    if (std.mem.indexOfScalar(u8, bindings_part, '{')) |lb| {
        default_name = std.mem.trim(u8, bindings_part[0..lb], " \t,");
        const rb = std.mem.indexOfScalar(u8, bindings_part, '}') orelse bindings_part.len;
        named_list = bindings_part[lb + 1 .. rb];
    } else {
        default_name = std.mem.trim(u8, bindings_part, " \t,");
    }

    if (default_name.len > 0) {
        if (containsIdent(before, default_name) or containsIdent(after, default_name)) return true;
    }

    // Scan named bindings, splitting on commas. Each entry is either
    // `foo` or `foo as bar` — we want the locally-bound name (after
    // `as`, if present).
    var it = std.mem.splitScalar(u8, named_list, ',');
    while (it.next()) |raw| {
        const piece = std.mem.trim(u8, raw, " \t");
        if (piece.len == 0) continue;
        const local = if (std.mem.indexOf(u8, piece, " as ")) |ai|
            std.mem.trim(u8, piece[ai + 4 ..], " \t")
        else
            piece;
        if (local.len == 0) continue;
        if (containsIdent(before, local) or containsIdent(after, local)) return true;
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

/// v0 minifier. Walks the emit byte-by-byte with awareness of string,
/// template, and regex literals so their contents are preserved
/// verbatim. Strips:
///   - `// ...` line comments through the next newline.
///   - `/* ... */` block comments.
///   - Runs of spaces/tabs collapsed to a single space.
///   - Runs of newlines compacted to at most one (and dropped entirely
///     when adjacent to punctuation that doesn't need a separator).
///   - A trailing `;` immediately before `}` (skipping whitespace).
/// Identifier mangling is intentionally out of scope for v0.
/// Returns a freshly-allocated slice owned by the caller.
fn minify(gpa: std.mem.Allocator, js: []const u8) ![]u8 {
    // First pass: strip comments and copy literal contents verbatim,
    // collapsing horizontal whitespace runs and turning newlines into a
    // single `\n` separator we can post-process.
    var pass1: std.ArrayListUnmanaged(u8) = .empty;
    errdefer pass1.deinit(gpa);

    var i: usize = 0;
    var prev_space = false;
    while (i < js.len) {
        const c = js[i];

        // Line comment: `// ...` until newline.
        if (c == '/' and i + 1 < js.len and js[i + 1] == '/') {
            i += 2;
            while (i < js.len and js[i] != '\n') : (i += 1) {}
            // Leave the newline for the outer loop to handle.
            continue;
        }

        // Block comment: `/* ... */`.
        if (c == '/' and i + 1 < js.len and js[i + 1] == '*') {
            i += 2;
            while (i + 1 < js.len and !(js[i] == '*' and js[i + 1] == '/')) : (i += 1) {}
            if (i + 1 < js.len) i += 2 else i = js.len;
            // A block comment acts as a separator — emit a single
            // space so adjacent tokens don't fuse (e.g. `a/*x*/b`).
            if (!prev_space and pass1.items.len > 0) {
                try pass1.append(gpa, ' ');
                prev_space = true;
            }
            continue;
        }

        // String literal `"..."` or `'...'` — copy verbatim, honoring
        // backslash escapes so an escaped closing quote doesn't end
        // the literal early.
        if (c == '"' or c == '\'') {
            const quote = c;
            try pass1.append(gpa, c);
            i += 1;
            while (i < js.len) {
                const ch = js[i];
                try pass1.append(gpa, ch);
                if (ch == '\\' and i + 1 < js.len) {
                    try pass1.append(gpa, js[i + 1]);
                    i += 2;
                    continue;
                }
                i += 1;
                if (ch == quote) break;
            }
            prev_space = false;
            continue;
        }

        // Template literal `` `...` `` — copy verbatim. We don't
        // recurse into `${ ... }` interpolations: minifying expression
        // segments is out of scope for v0 and risks corrupting strings.
        if (c == '`') {
            try pass1.append(gpa, c);
            i += 1;
            while (i < js.len) {
                const ch = js[i];
                try pass1.append(gpa, ch);
                if (ch == '\\' and i + 1 < js.len) {
                    try pass1.append(gpa, js[i + 1]);
                    i += 2;
                    continue;
                }
                i += 1;
                if (ch == '`') break;
            }
            prev_space = false;
            continue;
        }

        // Regex literal — only when `/` appears in a position where a
        // regex is grammatically allowed (after an operator, keyword,
        // or punctuator that can't be the LHS of a division). We use
        // a lightweight heuristic that's good enough for the v0 emit.
        if (c == '/' and isRegexContext(pass1.items)) {
            try pass1.append(gpa, c);
            i += 1;
            var in_class = false;
            while (i < js.len) {
                const ch = js[i];
                try pass1.append(gpa, ch);
                if (ch == '\\' and i + 1 < js.len) {
                    try pass1.append(gpa, js[i + 1]);
                    i += 2;
                    continue;
                }
                i += 1;
                if (ch == '[') in_class = true
                else if (ch == ']') in_class = false
                else if (ch == '/' and !in_class) break
                else if (ch == '\n') break;
            }
            // Copy regex flags (a-z) that follow.
            while (i < js.len and js[i] >= 'a' and js[i] <= 'z') : (i += 1) {
                try pass1.append(gpa, js[i]);
            }
            prev_space = false;
            continue;
        }

        // Whitespace handling: collapse spaces/tabs; preserve a single
        // newline as a marker for the second pass.
        if (c == ' ' or c == '\t' or c == '\r') {
            if (!prev_space and pass1.items.len > 0) {
                try pass1.append(gpa, ' ');
                prev_space = true;
            }
            i += 1;
            continue;
        }
        if (c == '\n') {
            // Drop a pending trailing space then emit a single newline.
            if (pass1.items.len > 0 and pass1.items[pass1.items.len - 1] == ' ') {
                _ = pass1.pop();
            }
            if (pass1.items.len > 0 and pass1.items[pass1.items.len - 1] != '\n') {
                try pass1.append(gpa, '\n');
            }
            prev_space = false;
            i += 1;
            continue;
        }

        try pass1.append(gpa, c);
        prev_space = false;
        i += 1;
    }

    // Second pass: drop `;` before any `}` (skipping intervening
    // whitespace/newlines), and remove unnecessary newlines/spaces
    // next to punctuation. Literal-aware so we don't touch contents of
    // strings, templates, or regex literals.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var k: usize = 0;
    while (k < pass1.items.len) {
        const ch = pass1.items[k];

        // Copy string/template literals verbatim. They were already
        // copied verbatim into `pass1`, so we just relay them through.
        if (ch == '"' or ch == '\'' or ch == '`') {
            const quote = ch;
            try out.append(gpa, ch);
            k += 1;
            while (k < pass1.items.len) {
                const c2 = pass1.items[k];
                try out.append(gpa, c2);
                if (c2 == '\\' and k + 1 < pass1.items.len) {
                    try out.append(gpa, pass1.items[k + 1]);
                    k += 2;
                    continue;
                }
                k += 1;
                if (c2 == quote) break;
            }
            continue;
        }

        // Regex literals were also passed through verbatim. Detect and
        // relay them so spaces inside `/[a b]/` survive.
        if (ch == '/' and isRegexContext(out.items)) {
            try out.append(gpa, ch);
            k += 1;
            var in_class = false;
            while (k < pass1.items.len) {
                const c2 = pass1.items[k];
                try out.append(gpa, c2);
                if (c2 == '\\' and k + 1 < pass1.items.len) {
                    try out.append(gpa, pass1.items[k + 1]);
                    k += 2;
                    continue;
                }
                k += 1;
                if (c2 == '[') in_class = true
                else if (c2 == ']') in_class = false
                else if (c2 == '/' and !in_class) break;
            }
            while (k < pass1.items.len and pass1.items[k] >= 'a' and pass1.items[k] <= 'z') : (k += 1) {
                try out.append(gpa, pass1.items[k]);
            }
            continue;
        }

        // Skip `;` that is followed (after whitespace/newlines) by `}`.
        if (ch == ';') {
            var j: usize = k + 1;
            while (j < pass1.items.len and (pass1.items[j] == ' ' or pass1.items[j] == '\n' or pass1.items[j] == '\t')) : (j += 1) {}
            if (j < pass1.items.len and pass1.items[j] == '}') {
                k += 1;
                continue;
            }
        }

        // Drop redundant newlines. Collapse runs to a single `\n`, drop
        // entirely when adjacent to punctuation that doesn't require a
        // statement separator.
        if (ch == '\n') {
            const left = if (out.items.len == 0) 0 else out.items[out.items.len - 1];
            const right = if (k + 1 < pass1.items.len) pass1.items[k + 1] else 0;
            k += 1;
            if (out.items.len == 0) continue; // leading
            if (right == 0) continue; // trailing
            if (left == '\n') continue; // duplicate
            if (isPunct(left) or isPunct(right)) continue;
            try out.append(gpa, '\n');
            continue;
        }

        // Drop a space adjacent to punctuation.
        if (ch == ' ') {
            const left = if (out.items.len == 0) 0 else out.items[out.items.len - 1];
            const right = if (k + 1 < pass1.items.len) pass1.items[k + 1] else 0;
            k += 1;
            if (left == 0 or right == 0) continue;
            if (isPunct(left) or isPunct(right)) continue;
            try out.append(gpa, ' ');
            continue;
        }

        try out.append(gpa, ch);
        k += 1;
    }

    pass1.deinit(gpa);
    return out.toOwnedSlice(gpa);
}

/// Returns true when a `/` appearing at the current point should be
/// interpreted as the opening of a regex literal rather than a division
/// operator. The heuristic walks back over trailing whitespace and
/// looks at the prior non-whitespace character: anything that can't end
/// an expression (operators, opening punctuation, statement starts) is
/// a regex context. Conservatively returns false when uncertain so we
/// never accidentally swallow `/` in arithmetic.
fn isRegexContext(buf: []const u8) bool {
    if (buf.len == 0) return true;
    var k: usize = buf.len;
    while (k > 0) {
        const c = buf[k - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            k -= 1;
            continue;
        }
        break;
    }
    if (k == 0) return true;
    const prev = buf[k - 1];
    // Punctuation/operators that imply an expression start.
    switch (prev) {
        '(', ',', '=', ':', ';', '!', '&', '|', '?', '{', '}', '[', '+', '-', '*', '/', '%', '<', '>', '^', '~' => return true,
        else => {},
    }
    // Keyword check: scan backwards over identifier chars and compare.
    const w_end = k;
    var w_start = w_end;
    while (w_start > 0 and isIdentChar(buf[w_start - 1])) : (w_start -= 1) {}
    const word = buf[w_start..w_end];
    const kws = [_][]const u8{ "return", "typeof", "in", "of", "instanceof", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await" };
    for (kws) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Punctuation around which whitespace is unnecessary. Conservative —
/// we keep spaces around alphanumerics so `let x` doesn't become `letx`.
fn isPunct(c: u8) bool {
    return switch (c) {
        '{', '}', '(', ')', '[', ']', ',', ';', ':', '?',
        '=', '+', '-', '*', '/', '%', '<', '>', '!',
        '&', '|', '^', '~', '.',
        => true,
        else => false,
    };
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

test "Bundler: tree-shake drops fully-unused import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "main.ts", .{ .truncate = true });
        defer f.close(io);
        // `useState` is imported but never referenced — the v0 shaker
        // should drop the entire import line.
        try f.writeStreamingAll(io,
            \\import { useState } from "react";
            \\let x = 1;
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

    try T.expect(std.mem.indexOf(u8, js, "useState") == null);
    try T.expect(std.mem.indexOf(u8, js, "from \"react\"") == null);
    try T.expect(std.mem.indexOf(u8, js, "let x") != null);
}

test "Bundler: tree-shake preserves import with used binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "main.ts", .{ .truncate = true });
        defer f.close(io);
        // `useState` is referenced below — the import must survive.
        try f.writeStreamingAll(io,
            \\import { useState } from "react";
            \\let s = useState(0);
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

    try T.expect(std.mem.indexOf(u8, js, "useState") != null);
    try T.expect(std.mem.indexOf(u8, js, "import {") != null);
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

test "Bundler: minify strips line and block comments" {
    const src =
        \\let a = 1; // trailing line comment
        \\// full-line comment
        \\let b = /* inline block */ 2;
        \\/* multi
        \\   line block */
        \\let c = 3;
    ;
    const out = try minify(T.allocator, src);
    defer T.allocator.free(out);

    try T.expect(std.mem.indexOf(u8, out, "//") == null);
    try T.expect(std.mem.indexOf(u8, out, "/*") == null);
    try T.expect(std.mem.indexOf(u8, out, "*/") == null);
    try T.expect(std.mem.indexOf(u8, out, "let a=1") != null);
    try T.expect(std.mem.indexOf(u8, out, "let b= 2") != null or std.mem.indexOf(u8, out, "let b=2") != null);
    try T.expect(std.mem.indexOf(u8, out, "let c=3") != null);
}

test "Bundler: minify preserves comment-like text inside strings" {
    const src =
        \\let s = "keep // me";
        \\let t = 'and /* me */ too';
        \\let u = `template // ${x} */ ok`;
    ;
    const out = try minify(T.allocator, src);
    defer T.allocator.free(out);

    // The comment-shaped substrings must survive inside the literals.
    try T.expect(std.mem.indexOf(u8, out, "\"keep // me\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "'and /* me */ too'") != null);
    try T.expect(std.mem.indexOf(u8, out, "`template // ${x} */ ok`") != null);
}

test "Bundler: minify compacts multi-newline statements" {
    const src =
        \\let x = 1;
        \\
        \\
        \\
        \\let y = 2;
        \\
        \\let z = 3;
    ;
    const out = try minify(T.allocator, src);
    defer T.allocator.free(out);

    // No run of two consecutive newlines should remain.
    try T.expect(std.mem.indexOf(u8, out, "\n\n") == null);
    try T.expect(std.mem.indexOf(u8, out, "let x=1") != null);
    try T.expect(std.mem.indexOf(u8, out, "let y=2") != null);
    try T.expect(std.mem.indexOf(u8, out, "let z=3") != null);
}

test "Bundler: minify preserves regex literal contents" {
    // `/[a-z]\/+/g` contains an escaped `/` and a class — the minifier
    // must not treat the inner `/` as the literal terminator and must
    // not touch any of the regex body.
    const src =
        \\let r = /[a-z]\/+/g;
        \\let s = "x".replace(/\s+/g, " ");
    ;
    const out = try minify(T.allocator, src);
    defer T.allocator.free(out);

    try T.expect(std.mem.indexOf(u8, out, "/[a-z]\\/+/g") != null);
    try T.expect(std.mem.indexOf(u8, out, "/\\s+/g") != null);
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

test "Bundler: bundleWithMap returns stub source map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "main.ts", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "let z = 7;");
    }
    const path_z = try tmp.dir.realPathFileAlloc(io, "main.ts", T.allocator);
    defer T.allocator.free(path_z);
    const path: []const u8 = path_z;

    var b = Bundler.init(T.allocator);
    defer b.deinit();
    try b.addEntry(path);

    const result = try b.bundleWithMap(T.allocator, .{ .source_map = true });
    defer T.allocator.free(result.js);
    defer if (result.map) |m| T.allocator.free(m);

    try T.expect(result.map != null);
    const map = result.map.?;
    try T.expect(std.mem.indexOf(u8, map, "\"version\": 3") != null);
    try T.expect(std.mem.indexOf(u8, map, "\"sources\":") != null);
    try T.expect(std.mem.indexOf(u8, map, "\"mappings\":") != null);
}

test "Bundler: deduplicate skips a repeated entry path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "main.ts", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "let dedupSentinel = 99;");
    }
    const path_z = try tmp.dir.realPathFileAlloc(io, "main.ts", T.allocator);
    defer T.allocator.free(path_z);
    const path: []const u8 = path_z;

    var b = Bundler.init(T.allocator);
    defer b.deinit();
    // Register the same path twice — without dedup the emit would
    // appear twice; with dedup (default) it must appear exactly once.
    try b.addEntry(path);
    try b.addEntry(path);

    const js = try b.bundle(T.allocator, .{});
    defer T.allocator.free(js);

    // Count occurrences of the unique sentinel — must be exactly 1.
    var count: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, js, search, "dedupSentinel")) |idx| {
        count += 1;
        search = idx + "dedupSentinel".len;
    }
    try T.expectEqual(@as(usize, 1), count);

    // Sanity-check: with dedup disabled, the sentinel appears twice.
    const js_dup = try b.bundle(T.allocator, .{ .deduplicate = false });
    defer T.allocator.free(js_dup);
    var dup_count: usize = 0;
    var dup_search: usize = 0;
    while (std.mem.indexOfPos(u8, js_dup, dup_search, "dedupSentinel")) |idx| {
        dup_count += 1;
        dup_search = idx + "dedupSentinel".len;
    }
    try T.expectEqual(@as(usize, 2), dup_count);
}

test "Bundler: bundleWithManifest emits expected JSON shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "main.ts", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "let m = 5;");
    }
    const path_z = try tmp.dir.realPathFileAlloc(io, "main.ts", T.allocator);
    defer T.allocator.free(path_z);
    const path: []const u8 = path_z;

    var b = Bundler.init(T.allocator);
    defer b.deinit();
    try b.addEntry(path);

    const result = try b.bundleWithManifest(T.allocator, .{ .manifest = true });
    defer T.allocator.free(result.bundle);
    defer T.allocator.free(result.manifest);

    // Manifest must contain the expected top-level keys.
    try T.expect(std.mem.indexOf(u8, result.manifest, "\"version\": 1") != null);
    try T.expect(std.mem.indexOf(u8, result.manifest, "\"outputs\":") != null);
    try T.expect(std.mem.indexOf(u8, result.manifest, "\"out.js\":") != null);
    try T.expect(std.mem.indexOf(u8, result.manifest, "\"entries\":") != null);
    try T.expect(std.mem.indexOf(u8, result.manifest, "\"size\":") != null);
    // The registered entry path appears inside the manifest.
    try T.expect(std.mem.indexOf(u8, result.manifest, path) != null);
    // The bundle is non-empty.
    try T.expect(result.bundle.len > 0);
}
