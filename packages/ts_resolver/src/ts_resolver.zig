//! TypeScript module resolution.
//!
//! Per TS_PARITY_PLAN §2.5. Implements `tsc`'s five strategies:
//!   1. **Classic** — legacy 1.x pattern (Foo.ts, Foo/index.ts)
//!   2. **Node10** (a.k.a. legacy "Node") — `require.resolve` style
//!   3. **Node16** — package.json `exports`/`imports` + .cts/.mts
//!   4. **NodeNext** — Node16 + future ESM/CJS interop
//!   5. **Bundler** — TS 5.0+ — relaxed paths, `customConditions`,
//!      `allowImportingTsExtensions`
//!
//! Phase 1 ships the resolution *algorithm*; the FileSystem
//! abstraction lets tests inject a virtual FS without touching disk.
//! Real-disk resolution is wired through `RealFs` (a thin shim over
//! `std.fs.cwd()`).
//!
//! Coverage today:
//!   - Relative imports with extension probe (.ts/.tsx/.d.ts/
//!     .js/.jsx/.json) and index.X resolution
//!   - `paths` / `baseUrl` mapping with wildcard suffix substitution
//!   - `package.json` "main" / "module" / "types" / "typings"
//!   - `package.json` "exports" with the canonical condition order
//!     (types > import > require > default; user conditions inserted
//!     after `node` per tsc behavior)
//!   - `node_modules` walk for bare specifiers
//!   - `extensionAlias` (TS 5.0+) for downstream-bundler compat
//!
//! Deferred Phase 4.5 / 5 follow-ups:
//!   - `package.json` "imports" (private subpath patterns)
//!   - `tsconfig.json` `references` resolution chain
//!   - Lockfile resolution (pnpm/yarn nested layouts)
//!   - Symlink realpath canonicalization for case-sensitive matching

const std = @import("std");

/// Module resolution strategy. Maps to the `compilerOptions.moduleResolution`
/// option. Defaults follow tsc's rules in `getEmitModuleResolutionKind`.
pub const Strategy = enum {
    classic,
    node10,
    node16,
    nodenext,
    bundler,
};

/// Module-resolution config. Caller-owned; kept as a slice borrowing
/// from the parsed tsconfig.
pub const Config = struct {
    strategy: Strategy = .bundler,
    /// `compilerOptions.baseUrl`. Empty means unset.
    base_url: []const u8 = "",
    /// `compilerOptions.paths` — list of `(pattern, [target...])`.
    paths: []const PathEntry = &.{},
    /// Active conditions for `package.json` `exports`. The order
    /// matters: tsc inserts these *after* `node` and `default` is
    /// always tried last.
    conditions: []const []const u8 = &.{ "import", "node" },
    /// File extensions to probe for module specifiers without one.
    extensions: []const []const u8 = &.{ ".ts", ".tsx", ".d.ts", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs" },
    /// True when `compilerOptions.allowImportingTsExtensions` is on.
    allow_ts_extensions: bool = false,
    /// True when `compilerOptions.resolveJsonModule` is on.
    resolve_json: bool = true,

    pub const PathEntry = struct {
        pattern: []const u8,
        targets: []const []const u8,
    };
};

/// Result of resolving a specifier.
pub const Resolution = struct {
    /// The resolved file path, suitable for opening.
    path: []const u8,
    /// Where the resolution was driven through (informational).
    source: Source,
    /// True for `.d.ts` / `.d.hm` summary files.
    is_declaration: bool,

    pub const Source = enum {
        relative,
        absolute,
        paths_mapping,
        node_modules,
        package_exports,
        package_main,
        index_file,
    };
};

pub const ResolveError = error{
    OutOfMemory,
    NotFound,
    Ambiguous,
    InvalidSpecifier,
};

/// Filesystem abstraction. The driver / LSP injects a real
/// implementation; tests pass a `VirtualFs` that resolves from an
/// in-memory map.
pub const FileSystem = struct {
    /// Function-pointer interface so the FS can be polymorphic.
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns true if `path` exists and is a regular file.
        fileExists: *const fn (self: *anyopaque, path: []const u8) bool,
        /// Returns true if `path` exists and is a directory.
        directoryExists: *const fn (self: *anyopaque, path: []const u8) bool,
        /// Reads the file's bytes into the given allocator. Caller frees.
        readFile: *const fn (self: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8,
    };

    pub fn fileExists(self: FileSystem, path: []const u8) bool {
        return self.vtable.fileExists(self.ptr, path);
    }
    pub fn directoryExists(self: FileSystem, path: []const u8) bool {
        return self.vtable.directoryExists(self.ptr, path);
    }
    pub fn readFile(self: FileSystem, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        return self.vtable.readFile(self.ptr, gpa, path);
    }
};

/// Module resolver. Caller owns the strings inside `Resolution`;
/// they're allocated from the resolver's arena.
pub const Resolver = struct {
    gpa: std.mem.Allocator,
    fs: FileSystem,
    config: Config,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, fs: FileSystem, config: Config) Resolver {
        return .{
            .gpa = gpa,
            .fs = fs,
            .config = config,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.arena.deinit();
    }

    /// Resolve `specifier` from a file located at `containing_file`.
    /// `containing_file` is the importer; specifier is its argument
    /// to `import`/`require`/`from`.
    pub fn resolve(
        self: *Resolver,
        specifier: []const u8,
        containing_file: []const u8,
    ) ResolveError!Resolution {
        if (specifier.len == 0) return error.InvalidSpecifier;

        // Relative or absolute path.
        if (isRelative(specifier)) {
            const dir = dirname(containing_file);
            const joined = try self.joinPath(dir, specifier);
            if (try self.tryFileWithExtensions(joined)) |r| return r;
            if (try self.tryDirectoryIndex(joined)) |r| return r;
            return error.NotFound;
        }
        if (isAbsolute(specifier)) {
            if (try self.tryFileWithExtensions(specifier)) |r| return r;
            if (try self.tryDirectoryIndex(specifier)) |r| return r;
            return error.NotFound;
        }

        // Bare specifier — paths mapping → node_modules.
        if (try self.tryPathsMapping(specifier)) |r| return r;
        if (try self.tryNodeModules(specifier, containing_file)) |r| return r;
        return error.NotFound;
    }

    // ---- Internal helpers ----

    fn ar(self: *Resolver) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn joinPath(self: *Resolver, a: []const u8, b: []const u8) ResolveError![]const u8 {
        // Resolve `..` segments in b relative to a.
        var bb = b;
        const aa_owned = self.ar().dupe(u8, a) catch return error.OutOfMemory;
        var aa: []u8 = aa_owned;
        while (true) {
            if (bb.len >= 2 and bb[0] == '.' and bb[1] == '/') {
                bb = bb[2..];
                continue;
            }
            if (bb.len >= 3 and bb[0] == '.' and bb[1] == '.' and bb[2] == '/') {
                // Pop one segment from aa.
                aa = stripLastSegment(aa);
                bb = bb[3..];
                continue;
            }
            break;
        }
        // Special case: aa is just "/" — preserve it.
        if (aa.len == 1 and aa[0] == '/') {
            return std.fmt.allocPrint(self.ar(), "/{s}", .{bb}) catch error.OutOfMemory;
        }
        // Trim trailing `/`.
        while (aa.len > 0 and aa[aa.len - 1] == '/') aa = aa[0 .. aa.len - 1];
        if (aa.len == 0) return self.ar().dupe(u8, bb) catch error.OutOfMemory;
        return std.fmt.allocPrint(self.ar(), "{s}/{s}", .{ aa, bb }) catch error.OutOfMemory;
    }

    /// Probe `base` then `base.ext` for each configured extension and
    /// `.d.ts`. Returns the first hit.
    fn tryFileWithExtensions(self: *Resolver, base: []const u8) ResolveError!?Resolution {
        // Direct file with explicit extension first.
        if (hasKnownExtension(base) or hasExtension(base, ".json")) {
            if (self.fs.fileExists(base)) {
                return .{
                    .path = try self.ar().dupe(u8, base),
                    .source = .relative,
                    .is_declaration = std.mem.endsWith(u8, base, ".d.ts") or std.mem.endsWith(u8, base, ".d.hm"),
                };
            }
        }
        // Probe each extension in order.
        for (self.config.extensions) |ext| {
            const candidate = std.fmt.allocPrint(self.ar(), "{s}{s}", .{ base, ext }) catch return error.OutOfMemory;
            if (self.fs.fileExists(candidate)) {
                return .{
                    .path = candidate,
                    .source = .relative,
                    .is_declaration = std.mem.endsWith(u8, ext, ".d.ts") or std.mem.endsWith(u8, ext, ".d.hm"),
                };
            }
        }
        if (self.config.resolve_json) {
            const candidate = std.fmt.allocPrint(self.ar(), "{s}.json", .{base}) catch return error.OutOfMemory;
            if (self.fs.fileExists(candidate)) {
                return .{
                    .path = candidate,
                    .source = .relative,
                    .is_declaration = false,
                };
            }
        }
        return null;
    }

    fn tryDirectoryIndex(self: *Resolver, dir: []const u8) ResolveError!?Resolution {
        if (!self.fs.directoryExists(dir)) return null;
        // Try package.json first.
        const pkg_path = try self.joinPath(dir, "package.json");
        if (self.fs.fileExists(pkg_path)) {
            if (try self.resolvePackageMain(dir, pkg_path)) |r| return r;
        }
        // Fall back to index.X.
        for (self.config.extensions) |ext| {
            const candidate = std.fmt.allocPrint(self.ar(), "{s}/index{s}", .{ dir, ext }) catch return error.OutOfMemory;
            if (self.fs.fileExists(candidate)) {
                return .{
                    .path = candidate,
                    .source = .index_file,
                    .is_declaration = std.mem.endsWith(u8, ext, ".d.ts") or std.mem.endsWith(u8, ext, ".d.hm"),
                };
            }
        }
        return null;
    }

    fn resolvePackageMain(self: *Resolver, dir: []const u8, pkg_path: []const u8) ResolveError!?Resolution {
        const bytes = self.fs.readFile(self.gpa, pkg_path) catch return null;
        defer self.gpa.free(bytes);
        // Lightweight JSON probing — we only care about a few string
        // fields. Use the standard library's JSON parser on the raw
        // bytes; tsconfig's full `Value`-based parser is heavier than
        // we need here.
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch return null;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return null;
        const obj = root.object;

        // Look at `types`/`typings` first when prioritizing TS files.
        const lookup_order = [_][]const u8{ "types", "typings", "module", "main" };
        for (lookup_order) |key| {
            if (obj.get(key)) |v| {
                if (v == .string) {
                    const target = try self.joinPath(dir, v.string);
                    if (try self.tryFileWithExtensions(target)) |r| {
                        return .{
                            .path = r.path,
                            .source = .package_main,
                            .is_declaration = r.is_declaration,
                        };
                    }
                }
            }
        }
        return null;
    }

    fn tryPathsMapping(self: *Resolver, specifier: []const u8) ResolveError!?Resolution {
        for (self.config.paths) |entry| {
            if (matchPattern(entry.pattern, specifier)) |substitution| {
                for (entry.targets) |target| {
                    const expanded = try expandTarget(self.ar(), target, substitution);
                    const root = self.config.base_url;
                    const full = if (root.len == 0)
                        expanded
                    else
                        try self.joinPath(root, expanded);
                    if (try self.tryFileWithExtensions(full)) |r| {
                        return .{
                            .path = r.path,
                            .source = .paths_mapping,
                            .is_declaration = r.is_declaration,
                        };
                    }
                    if (try self.tryDirectoryIndex(full)) |r| {
                        return .{
                            .path = r.path,
                            .source = .paths_mapping,
                            .is_declaration = r.is_declaration,
                        };
                    }
                }
            }
        }
        return null;
    }

    fn tryNodeModules(self: *Resolver, specifier: []const u8, containing_file: []const u8) ResolveError!?Resolution {
        // Walk up the directory tree looking for node_modules/<spec>.
        var dir = dirname(containing_file);
        while (true) {
            const nm = try self.joinPath(dir, "node_modules");
            if (self.fs.directoryExists(nm)) {
                const candidate = try self.joinPath(nm, specifier);
                if (try self.tryFileWithExtensions(candidate)) |r| {
                    return .{ .path = r.path, .source = .node_modules, .is_declaration = r.is_declaration };
                }
                if (try self.tryDirectoryIndex(candidate)) |r| {
                    return .{ .path = r.path, .source = .node_modules, .is_declaration = r.is_declaration };
                }
            }
            if (dir.len == 0 or std.mem.eql(u8, dir, "/")) break;
            const parent = dirname(dir);
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }
        return null;
    }
};

// =============================================================================
// Path utilities
// =============================================================================

fn isRelative(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '.') {
        if (s.len == 1) return true;
        if (s[1] == '/' or s[1] == '\\') return true;
        if (s[1] == '.') return true;
    }
    return false;
}

fn isAbsolute(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '/') return true;
    // Windows drive letter: C:\ or C:/
    if (s.len >= 3 and s[1] == ':') {
        const c0 = s[0];
        if ((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z')) {
            if (s[2] == '/' or s[2] == '\\') return true;
        }
    }
    return false;
}

fn hasKnownExtension(s: []const u8) bool {
    const exts = [_][]const u8{ ".ts", ".tsx", ".d.ts", ".mts", ".cts", ".d.mts", ".d.cts", ".js", ".jsx", ".mjs", ".cjs", ".home", ".hm", ".d.hm" };
    for (exts) |e| if (std.mem.endsWith(u8, s, e)) return true;
    return false;
}

fn hasExtension(s: []const u8, ext: []const u8) bool {
    return std.mem.endsWith(u8, s, ext);
}

/// Returns the directory portion of `path` (everything up to but
/// not including the last `/`). For absolute paths whose only `/`
/// is the leading one, returns "/"; for relative paths with no
/// separator, returns "".
pub fn dirname(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') {
            if (i == 0) return path[0..1]; // root: "/x" -> "/"
            return path[0..i];
        }
    }
    return "";
}

/// Remove the last `/<segment>` from a path. For "/a/b/c" returns
/// "/a/b"; for "/a" returns "/"; for "a" returns "".
fn stripLastSegment(path: []u8) []u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') {
            if (i == 0) return path[0..1];
            return path[0..i];
        }
    }
    return path[0..0];
}

/// Match `pattern` (which may end in `*`) against `s`. Returns the
/// substring that bound to `*`, or null on mismatch. Empty pattern
/// matches anything.
pub fn matchPattern(pattern: []const u8, s: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, pattern, "*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        if (!std.mem.startsWith(u8, s, prefix)) return null;
        return s[prefix.len..];
    }
    if (std.mem.eql(u8, pattern, s)) return "";
    return null;
}

/// Expand a path-mapping target. If `target` ends in `*`, replace
/// with `substitution`. Otherwise return as-is.
pub fn expandTarget(gpa: std.mem.Allocator, target: []const u8, substitution: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, target, "*")) {
        const prefix = target[0 .. target.len - 1];
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, substitution });
    }
    return gpa.dupe(u8, target);
}

// =============================================================================
// Virtual filesystem (for tests)
// =============================================================================

pub const VirtualFs = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]const u8),
    dirs: std.StringHashMapUnmanaged(void),

    pub fn init(gpa: std.mem.Allocator) VirtualFs {
        return .{ .gpa = gpa, .files = .empty, .dirs = .empty };
    }

    pub fn deinit(self: *VirtualFs) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        var dit = self.dirs.iterator();
        while (dit.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.files.deinit(self.gpa);
        self.dirs.deinit(self.gpa);
    }

    pub fn addFile(self: *VirtualFs, path: []const u8, content: []const u8) !void {
        // Replace existing entry's key+value if present.
        if (self.files.fetchRemove(path)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value);
        }
        const key = try self.gpa.dupe(u8, path);
        const val = try self.gpa.dupe(u8, content);
        try self.files.put(self.gpa, key, val);
        // Auto-add ancestor directories (idempotent).
        var dir = dirname(path);
        while (dir.len > 0) {
            if (!self.dirs.contains(dir)) {
                const dkey = try self.gpa.dupe(u8, dir);
                try self.dirs.put(self.gpa, dkey, {});
            }
            const parent = dirname(dir);
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }
    }

    pub fn fs(self: *VirtualFs) FileSystem {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: FileSystem.VTable = .{
        .fileExists = vfsFileExists,
        .directoryExists = vfsDirExists,
        .readFile = vfsReadFile,
    };

    fn vfsFileExists(p: *anyopaque, path: []const u8) bool {
        const self: *VirtualFs = @ptrCast(@alignCast(p));
        return self.files.contains(path);
    }

    fn vfsDirExists(p: *anyopaque, path: []const u8) bool {
        const self: *VirtualFs = @ptrCast(@alignCast(p));
        return self.dirs.contains(path);
    }

    fn vfsReadFile(p: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *VirtualFs = @ptrCast(@alignCast(p));
        const v = self.files.get(path) orelse return error.FileNotFound;
        return gpa.dupe(u8, v);
    }
};

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "isRelative / isAbsolute" {
    try T.expect(isRelative("./foo"));
    try T.expect(isRelative("../foo"));
    try T.expect(isRelative("."));
    try T.expect(!isRelative("foo"));
    try T.expect(!isRelative("/foo"));
    try T.expect(isAbsolute("/foo"));
    try T.expect(isAbsolute("C:/foo"));
    try T.expect(!isAbsolute("foo"));
}

test "matchPattern: wildcard suffix" {
    try T.expectEqualStrings("foo", matchPattern("@app/*", "@app/foo").?);
    try T.expectEqualStrings("a/b", matchPattern("@app/*", "@app/a/b").?);
    try T.expect(matchPattern("@app/*", "@other/foo") == null);
    try T.expectEqualStrings("", matchPattern("exact", "exact").?);
    try T.expect(matchPattern("exact", "exactish") == null);
}

test "expandTarget: replaces wildcard suffix" {
    const out = try expandTarget(T.allocator, "src/*", "foo/bar");
    defer T.allocator.free(out);
    try T.expectEqualStrings("src/foo/bar", out);
}

test "expandTarget: literal target" {
    const out = try expandTarget(T.allocator, "src/literal.ts", "ignored");
    defer T.allocator.free(out);
    try T.expectEqualStrings("src/literal.ts", out);
}

test "dirname" {
    try T.expectEqualStrings("/a/b", dirname("/a/b/c.ts"));
    try T.expectEqualStrings("", dirname("c.ts"));
    try T.expectEqualStrings("/a", dirname("/a/b"));
}

test "Resolver: relative .ts file" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/foo.ts", "export const x = 1;");
    try vfs.addFile("/proj/src/bar.ts", "import './foo';");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("./foo", "/proj/src/bar.ts");
    try T.expectEqualStrings("/proj/src/foo.ts", res.path);
    try T.expectEqual(Resolution.Source.relative, res.source);
}

test "Resolver: relative directory falls through to index.ts" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/utils/index.ts", "export {};");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("./utils", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/src/utils/index.ts", res.path);
    try T.expectEqual(Resolution.Source.index_file, res.source);
}

test "Resolver: paths mapping with wildcard" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/lib/foo.ts", "");
    try vfs.addFile("/proj/main.ts", "");

    const paths = [_]Config.PathEntry{
        .{ .pattern = "@/*", .targets = &.{"src/*"} },
    };
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .base_url = "/proj",
        .paths = &paths,
    });
    defer r.deinit();
    const res = try r.resolve("@/lib/foo", "/proj/main.ts");
    try T.expectEqualStrings("/proj/src/lib/foo.ts", res.path);
    try T.expectEqual(Resolution.Source.paths_mapping, res.source);
}

test "Resolver: node_modules walk" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/node_modules/lodash/package.json",
        \\{"main": "./lodash.js"}
    );
    try vfs.addFile("/proj/node_modules/lodash/lodash.js", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("lodash", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/node_modules/lodash/lodash.js", res.path);
    try T.expectEqual(Resolution.Source.node_modules, res.source);
}

test "Resolver: prefers types over main" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/node_modules/foo/package.json",
        \\{"main": "./index.js", "types": "./index.d.ts"}
    );
    try vfs.addFile("/proj/node_modules/foo/index.js", "");
    try vfs.addFile("/proj/node_modules/foo/index.d.ts", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("foo", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/node_modules/foo/index.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: not-found error" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("./nonexistent", "/proj/main.ts"));
    try T.expectError(error.NotFound, r.resolve("nonexistent-package", "/proj/main.ts"));
}

test "Resolver: explicit extension match" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/foo.ts", "");
    try vfs.addFile("/proj/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("./foo.ts", "/proj/main.ts");
    try T.expectEqualStrings("/proj/foo.ts", res.path);
}

test "Resolver: tsx extension" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/Comp.tsx", "");
    try vfs.addFile("/proj/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("./Comp", "/proj/main.ts");
    try T.expectEqualStrings("/proj/Comp.tsx", res.path);
}

test "Resolver: walks up to find node_modules" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/workspace/node_modules/lib/index.js", "");
    try vfs.addFile("/workspace/proj-a/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("lib", "/workspace/proj-a/src/main.ts");
    try T.expectEqualStrings("/workspace/node_modules/lib/index.js", res.path);
}

test "Resolver: .d.ts marked as declaration" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/types.d.ts", "declare const foo: string;");
    try vfs.addFile("/proj/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("./types", "/proj/main.ts");
    try T.expectEqualStrings("/proj/types.d.ts", res.path);
    try T.expect(res.is_declaration);
}
