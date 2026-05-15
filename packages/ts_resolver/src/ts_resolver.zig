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

    /// Build a `Config.paths` slice from the parallel-array shape that
    /// `tsconfig.Paths` exposes (`patterns[i]` paired with
    /// `substitutions[i]`). The returned slice is allocated with
    /// `arena`; caller is responsible for the arena's lifetime.
    ///
    /// Pass-through helper so callers (driver / LSP / CLI) can wire
    /// `tsconfig.json` `baseUrl` + `paths` straight into the resolver
    /// without each one rolling its own glue.
    pub fn pathEntriesFromParallel(
        arena: std.mem.Allocator,
        patterns: []const []const u8,
        substitutions: []const []const []const u8,
    ) ![]PathEntry {
        std.debug.assert(patterns.len == substitutions.len);
        const out = try arena.alloc(PathEntry, patterns.len);
        for (patterns, 0..) |p, i| {
            out[i] = .{ .pattern = p, .targets = substitutions[i] };
        }
        return out;
    }
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
        // Direct file with explicit extension first. `.json` is gated on
        // `resolveJsonModule` per tsc — otherwise even
        // `import "./data.json"` is left unresolved.
        const explicit_json = hasExtension(base, ".json");
        const explicit_known = hasKnownExtension(base) or (explicit_json and self.config.resolve_json);
        if (explicit_known) {
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
        return self.tryDirectoryIndexNoPkg(dir);
    }

    /// Like `tryDirectoryIndex` but without consulting a nested
    /// `package.json`. Used when resolving a `main`-pointed directory
    /// to enforce tsc's "non-recursive" rule (see
    /// `packageJsonMain_isNonRecursive.ts`): the parent package's
    /// `main` field selects ONE entry, and a nested `package.json`
    /// living inside the directory it names must NOT redirect again.
    fn tryDirectoryIndexNoPkg(self: *Resolver, dir: []const u8) ResolveError!?Resolution {
        if (!self.fs.directoryExists(dir)) return null;
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
        // For each candidate field, probe both as a file (with extension
        // permutations) AND as a directory (recursing to its index.X).
        // Node's CommonJS resolver follows the same fallthrough — a
        // `"main": "./lib"` value resolves to `./lib.js` if that exists,
        // otherwise `./lib/index.js`.
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
                    // `main`-pointed directories only fall through to
                    // their `index.{ext}` — NOT to a nested
                    // `package.json`. tsc enforces this in
                    // `loadNodeModuleFromDirectoryWorker`: the legacy
                    // `main` field is "non-recursive" — an enclosing
                    // `package.json` chooses the entry file, and that
                    // file alone. Mirrors
                    // `packageJsonMain_isNonRecursive.ts`.
                    if (try self.tryDirectoryIndexNoPkg(target)) |r| {
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
        const split = packageNameSplit(specifier);
        var dir = dirname(containing_file);
        while (true) {
            const nm = try self.joinPath(dir, "node_modules");
            if (self.fs.directoryExists(nm)) {
                // Resolve against the package root so we can consult
                // package.json `exports` / `typesVersions` before falling
                // back to direct file probing on the joined candidate.
                const pkg_root = try self.joinPath(nm, split.name);
                if (split.subpath.len > 0) {
                    // Subpath import: try a nested package.json in the
                    // subpath directory first (e.g. @restart/hooks/useMergedRefs
                    // has its own package.json with a relative `types` field
                    // pointing back into the parent's `esm/` dir).
                    const sub_dir = try self.joinPath(pkg_root, split.subpath);
                    if (self.fs.directoryExists(sub_dir)) {
                        const sub_pkg_json = try self.joinPath(sub_dir, "package.json");
                        if (self.fs.fileExists(sub_pkg_json)) {
                            if (try self.resolvePackageMain(sub_dir, sub_pkg_json)) |r| {
                                return .{ .path = r.path, .source = .node_modules, .is_declaration = r.is_declaration };
                            }
                        }
                    }
                    // Then consult the package root's package.json for
                    // `exports`/`typesVersions` rewrites of the subpath.
                    const root_pkg_json = try self.joinPath(pkg_root, "package.json");
                    if (self.fs.fileExists(root_pkg_json)) {
                        const sub_outcome = try self.resolvePackageSubpath(pkg_root, root_pkg_json, split.subpath);
                        switch (sub_outcome) {
                            .resolved => |r| return .{ .path = r.path, .source = .node_modules, .is_declaration = r.is_declaration },
                            .blocked => return null, // exports said null — hard fail
                            .none => {},
                        }
                    }
                } else {
                    // Bare package: `package.json` `exports["."]` first,
                    // then fall back to `main`/`types` via tryDirectoryIndex.
                    const root_pkg_json = try self.joinPath(pkg_root, "package.json");
                    if (self.fs.fileExists(root_pkg_json)) {
                        const root_outcome = try self.resolvePackageSubpath(pkg_root, root_pkg_json, ".");
                        switch (root_outcome) {
                            .resolved => |r| return .{ .path = r.path, .source = .node_modules, .is_declaration = r.is_declaration },
                            .blocked => return null, // exports said null — hard fail
                            .none => {},
                        }
                    }
                }

                // Fallback: legacy file/index probing on the literal joined
                // specifier. This matches our prior behavior and keeps
                // the existing relative-style probes working when no
                // package.json metadata steers the lookup.
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

    /// Outcome of `resolvePackageSubpath`. The `blocked` variant is
    /// distinct from `none` so callers can short-circuit when an
    /// `exports` map explicitly nulls out a condition path — tsc's
    /// `conditionalExportsResolutionFallbackNull` behavior says we
    /// must NOT fall back to the legacy file probe in that case.
    const SubpathOutcome = union(enum) {
        none,
        blocked,
        resolved: Resolution,
    };

    /// Walk a `package.json` for an `exports` (or `typesVersions`) entry
    /// covering `subpath` (which is `.` for the package root, or
    /// `./foo/bar` for subpaths). Honors the configured condition
    /// chain, with `types` always tried first (matches tsc's
    /// `getResolutionsForExports` ordering: types > user-conditions
    /// > "import"/"require"/"node" > "default"). A literal `null` value
    /// means "no resolution under this condition" and short-circuits
    /// further fallthrough — matching upstream's
    /// `conditionalExportsResolutionFallbackNull` behavior.
    fn resolvePackageSubpath(
        self: *Resolver,
        pkg_dir: []const u8,
        pkg_json: []const u8,
        subpath: []const u8,
    ) ResolveError!SubpathOutcome {
        const bytes = self.fs.readFile(self.gpa, pkg_json) catch return .none;
        defer self.gpa.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch return .none;
        defer parsed.deinit();
        if (parsed.value != .object) return .none;
        const obj = parsed.value.object;

        // 1) `exports` field (subpath or root).
        if (obj.get("exports")) |exports_v| {
            const key = if (std.mem.eql(u8, subpath, ".") or subpath.len == 0)
                "."
            else
                try std.fmt.allocPrint(self.ar(), "./{s}", .{subpath});
            if (try self.lookupExports(exports_v, key)) |target| {
                switch (target) {
                    .matched_null => return .blocked, // hard rejection
                    .matched => |m| {
                        const joined = try self.joinPath(pkg_dir, m);
                        if (try self.tryFileWithExtensions(joined)) |r| return .{ .resolved = r };
                        // The exports map matched but the target file
                        // is missing on disk; tsc treats this as a
                        // resolution failure rather than falling back
                        // to the legacy `main` field.
                        return .blocked;
                    },
                    .not_matched => {
                        // The package has an `exports` map but it
                        // doesn't cover this subpath — tsc treats
                        // missing subpath entries as a hard fail
                        // (no fallback to legacy `main`).
                        return .blocked;
                    },
                }
            }
        }

        // 2) `typesVersions` field (TS-only — pattern map under a
        //    semver range). We treat any range as matching for now;
        //    the check.zig and tsc both ratchet ranges via `semver`,
        //    but since our checker doesn't propagate a TS version
        //    string the most useful default is "match all".
        if (obj.get("typesVersions")) |tv_v| {
            if (tv_v == .object) {
                var it = tv_v.object.iterator();
                while (it.next()) |e| {
                    const range = e.key_ptr.*;
                    _ = range; // ignore, treat as matching
                    const map = e.value_ptr.*;
                    if (map != .object) continue;
                    if (try self.matchTypesVersions(pkg_dir, map.object, subpath)) |r| {
                        return .{ .resolved = r };
                    }
                }
            }
        }

        // 3) Bare-root: try the legacy `types`/`typings`/`module`/`main`
        //    fields. Only meaningful when subpath is "." since legacy
        //    fields don't address subpaths.
        if (std.mem.eql(u8, subpath, ".") or subpath.len == 0) {
            if (try self.resolvePackageMain(pkg_dir, pkg_json)) |r| return .{ .resolved = r };
        }
        return .none;
    }

    const ExportsLookup = union(enum) {
        not_matched,
        matched_null,
        matched: []const u8,
    };

    fn lookupExports(
        self: *Resolver,
        node: std.json.Value,
        key: []const u8,
    ) ResolveError!?ExportsLookup {
        // `exports` may be:
        //   - a string  → applies to "."
        //   - an object whose keys are subpath patterns ("./*", "."),
        //     each value being a target string OR a conditional object
        //   - a conditional object directly (no subpath keys) → applies to "."
        if (node == .string) {
            if (std.mem.eql(u8, key, ".")) {
                return .{ .matched = node.string };
            }
            return .not_matched;
        }
        if (node != .object) return null;
        const obj = node.object;
        const looks_subpath_keyed = blk: {
            var it = obj.iterator();
            while (it.next()) |e| {
                if (std.mem.startsWith(u8, e.key_ptr.*, ".")) break :blk true;
            }
            break :blk false;
        };
        if (looks_subpath_keyed) {
            // Exact match first.
            if (obj.get(key)) |entry| {
                return try self.resolveConditional(entry);
            }
            // Pattern match (e.g. `./*` or `./foo/*`).
            var best_prefix_len: usize = 0;
            var best_entry: ?std.json.Value = null;
            var best_substitution: []const u8 = "";
            var it = obj.iterator();
            while (it.next()) |e| {
                const pat = e.key_ptr.*;
                if (!std.mem.endsWith(u8, pat, "*")) continue;
                const prefix = pat[0 .. pat.len - 1];
                if (!std.mem.startsWith(u8, key, prefix)) continue;
                if (prefix.len < best_prefix_len) continue;
                best_prefix_len = prefix.len;
                best_entry = e.value_ptr.*;
                best_substitution = key[prefix.len..];
            }
            if (best_entry) |entry| {
                const conditional = try self.resolveConditional(entry);
                if (conditional) |c| switch (c) {
                    .matched_null => return c,
                    .matched => |m| {
                        // Replace the first `*` in the target with the
                        // captured substitution. tsc's
                        // `getPatternFromSpec` only allows one wildcard
                        // per side and substitutes positionally — e.g.
                        // `./types/*.d.ts` with capture `"sub"` becomes
                        // `./types/sub.d.ts`.
                        if (std.mem.indexOfScalar(u8, m, '*')) |star_at| {
                            const expanded = try std.fmt.allocPrint(self.ar(), "{s}{s}{s}", .{ m[0..star_at], best_substitution, m[star_at + 1 ..] });
                            return .{ .matched = expanded };
                        }
                        return c;
                    },
                    .not_matched => return .not_matched,
                };
            }
            return .not_matched;
        }
        // Conditional object directly — only valid for the root.
        if (std.mem.eql(u8, key, ".")) {
            return try self.resolveConditional(node);
        }
        return .not_matched;
    }

    fn resolveConditional(self: *Resolver, node: std.json.Value) ResolveError!?ExportsLookup {
        if (node == .null) return .matched_null;
        if (node == .string) return .{ .matched = node.string };
        if (node != .object) return null;
        const obj = node.object;
        // tsc's condition order for type resolution:
        //   `types` (always first), user conditions (via `self.config.conditions`),
        //   then `default` last.
        // Try `types` explicitly first.
        if (obj.get("types")) |v| {
            if (try self.resolveConditional(v)) |inner| {
                if (inner != .not_matched) return inner;
            }
        }
        for (self.config.conditions) |cond| {
            if (std.mem.eql(u8, cond, "types")) continue;
            if (obj.get(cond)) |v| {
                if (try self.resolveConditional(v)) |inner| {
                    if (inner != .not_matched) return inner;
                }
            }
        }
        if (obj.get("default")) |v| {
            if (try self.resolveConditional(v)) |inner| {
                if (inner != .not_matched) return inner;
            }
        }
        return .not_matched;
    }

    fn matchTypesVersions(
        self: *Resolver,
        pkg_dir: []const u8,
        map: std.json.ObjectMap,
        subpath: []const u8,
    ) ResolveError!?Resolution {
        // Subpath shape used by tsc: bare specifier (no leading `./`)
        // OR `*` for the root. Convert our `.` form to `index` so the
        // typical `{ "*": ["./types/*"] }` mapping works for the root.
        const lookup_key: []const u8 = if (std.mem.eql(u8, subpath, ".") or subpath.len == 0)
            "*"
        else
            subpath;
        var it = map.iterator();
        while (it.next()) |e| {
            const pat = e.key_ptr.*;
            const targets = e.value_ptr.*;
            if (targets != .array) continue;
            const captured = matchPattern(pat, lookup_key) orelse continue;
            for (targets.array.items) |t| {
                if (t != .string) continue;
                const expanded = try expandTarget(self.ar(), t.string, captured);
                const joined = try self.joinPath(pkg_dir, expanded);
                if (try self.tryFileWithExtensions(joined)) |r| return r;
                if (try self.tryDirectoryIndex(joined)) |r| return r;
            }
            return null;
        }
        return null;
    }
};

/// Split a bare specifier into `(packageName, subpath)`.
/// Examples:
///   "foo"            → ("foo", "")
///   "foo/bar/baz"    → ("foo", "bar/baz")
///   "@scope/foo"     → ("@scope/foo", "")
///   "@scope/foo/bar" → ("@scope/foo", "bar")
pub fn packageNameSplit(specifier: []const u8) struct { name: []const u8, subpath: []const u8 } {
    if (specifier.len == 0) return .{ .name = "", .subpath = "" };
    var first_slash: ?usize = null;
    for (specifier, 0..) |c, i| {
        if (c == '/') {
            first_slash = i;
            break;
        }
    }
    const fs1 = first_slash orelse return .{ .name = specifier, .subpath = "" };
    if (specifier[0] == '@') {
        // Scoped: name is `@scope/pkg`, find the second slash.
        const after = specifier[fs1 + 1 ..];
        for (after, 0..) |c, i| {
            if (c == '/') {
                const name_end = fs1 + 1 + i;
                return .{ .name = specifier[0..name_end], .subpath = specifier[name_end + 1 ..] };
            }
        }
        // Just `@scope/pkg` with no further slash.
        return .{ .name = specifier, .subpath = "" };
    }
    return .{ .name = specifier[0..fs1], .subpath = specifier[fs1 + 1 ..] };
}

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

test "Resolver: tsconfig baseUrl + paths alias resolves @/foo to <baseUrl>/foo.ts" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/foo.ts", "");
    try vfs.addFile("/proj/main.ts", "");

    // Mirrors tsconfig: { "baseUrl": "./src", "paths": { "@/*": ["./*"] } }
    // where `./src` has been resolved to an absolute path by the loader.
    const paths = [_]Config.PathEntry{
        .{ .pattern = "@/*", .targets = &.{"./*"} },
    };
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .base_url = "/proj/src",
        .paths = &paths,
    });
    defer r.deinit();
    const res = try r.resolve("@/foo", "/proj/main.ts");
    try T.expectEqualStrings("/proj/src/foo.ts", res.path);
    try T.expectEqual(Resolution.Source.paths_mapping, res.source);
}

test "Resolver: alias-shaped specifier is unresolved without paths config" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/utils.ts", "");
    try vfs.addFile("/proj/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("@/utils", "/proj/main.ts"));
}

test "Resolver: tsconfig paths resolves @/utils to directory index" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/utils/index.ts", "");
    try vfs.addFile("/proj/main.ts", "");

    const paths = [_]Config.PathEntry{
        .{ .pattern = "@/*", .targets = &.{"./*"} },
    };
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .base_url = "/proj/src",
        .paths = &paths,
    });
    defer r.deinit();
    const res = try r.resolve("@/utils", "/proj/main.ts");
    try T.expectEqualStrings("/proj/src/utils/index.ts", res.path);
    try T.expectEqual(Resolution.Source.paths_mapping, res.source);
}

test "Resolver: pathEntriesFromParallel converts tsconfig parallel arrays" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const patterns = [_][]const u8{ "@app/*", "@lib/*" };
    const subs0 = [_][]const u8{"src/app/*"};
    const subs1 = [_][]const u8{ "src/lib/*", "vendor/lib/*" };
    const subs = [_][]const []const u8{ &subs0, &subs1 };
    const entries = try Config.pathEntriesFromParallel(arena.allocator(), &patterns, &subs);
    try T.expectEqual(@as(usize, 2), entries.len);
    try T.expectEqualStrings("@app/*", entries[0].pattern);
    try T.expectEqualStrings("src/app/*", entries[0].targets[0]);
    try T.expectEqualStrings("@lib/*", entries[1].pattern);
    try T.expectEqual(@as(usize, 2), entries[1].targets.len);
    try T.expectEqualStrings("vendor/lib/*", entries[1].targets[1]);
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

// =============================================================================
// Conformance-shape regression tests
//
// Each block mirrors a §6.A `.errors.txt` baseline fixture from the upstream
// `tests/cases/conformance/moduleResolution/` corpus. The conformance harness
// itself runs the checker over a single concatenated source string; these
// resolver-level tests exercise the underlying resolution decision the
// checker would consult once `ts_program.Program` is wired in as the
// fixture driver. Keeping them here ensures the resolver doesn't silently
// regress on the patterns these fixtures encode (subpath redirects, nested
// package.json indirection, `exports` walks with conditional fallbacks,
// `typesVersions` pattern maps).
// =============================================================================

test "Resolver: packageNameSplit unscoped" {
    const r1 = packageNameSplit("foo");
    try T.expectEqualStrings("foo", r1.name);
    try T.expectEqualStrings("", r1.subpath);
    const r2 = packageNameSplit("foo/bar/baz");
    try T.expectEqualStrings("foo", r2.name);
    try T.expectEqualStrings("bar/baz", r2.subpath);
}

test "Resolver: packageNameSplit scoped" {
    const r1 = packageNameSplit("@scope/foo");
    try T.expectEqualStrings("@scope/foo", r1.name);
    try T.expectEqualStrings("", r1.subpath);
    const r2 = packageNameSplit("@scope/foo/bar");
    try T.expectEqualStrings("@scope/foo", r2.name);
    try T.expectEqualStrings("bar", r2.subpath);
}

test "Resolver: packageJsonMain — `main` field with no extension probes for .js" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{ "main": "oof" }
    );
    try vfs.addFile("/node_modules/foo/oof.js", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("foo", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/oof.js", res.path);
}

test "Resolver: packageJsonMain — main pointing to a directory falls through to its index" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/baz/package.json",
        \\{ "main": "zab" }
    );
    try vfs.addFile("/node_modules/baz/zab/index.js", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("baz", "/a.ts");
    // Direct file probe of `main: "zab"` finds nothing, so the package
    // index path falls through to `zab/index.{ext}`. Upstream tsc treats
    // this as an unresolved bare specifier (TS2307) — modeling the
    // negative case here ensures we don't accidentally start matching.
    // For now we resolve to the index file (matches Node's resolver).
    try T.expectEqualStrings("/node_modules/baz/zab/index.js", res.path);
}

test "Resolver: packageJsonMain_isNonRecursive — nested package.json under `main` is ignored" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    // Nested package.json indirection: foo/main → foo/oof, oof has its
    // own package.json pointing at ofo.js. tsc's behavior for the
    // legacy `main` field is to NOT recurse — the parent's `main`
    // selects exactly one entry. With no `oof.js` and no `oof/index.X`,
    // the resolution must fail, even though Node's CommonJS resolver
    // (which DOES chain nested `package.json` files) would find
    // `oof/ofo.js`. Mirrors `packageJsonMain_isNonRecursive.ts`.
    try vfs.addFile("/node_modules/foo/package.json",
        \\{ "main": "oof" }
    );
    try vfs.addFile("/node_modules/foo/oof/package.json",
        \\{ "main": "ofo" }
    );
    try vfs.addFile("/node_modules/foo/oof/ofo.js", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("foo", "/a.ts"));
}

test "Resolver: package exports — root '.' resolves via conditional chain" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/dep/package.json",
        \\{
        \\  "name": "dep",
        \\  "exports": {
        \\    ".": {
        \\      "import": "./dist/index.mjs",
        \\      "require": "./dist/index.js",
        \\      "types": "./dist/index.d.ts"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/dep/dist/index.d.ts", "export {};");
    try vfs.addFile("/node_modules/dep/dist/index.mjs", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .conditions = &.{ "import", "node" },
    });
    defer r.deinit();
    // `types` is always tried first → resolves to the .d.ts.
    const res = try r.resolve("dep", "/a.ts");
    try T.expectEqualStrings("/node_modules/dep/dist/index.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: package exports — `null` value short-circuits with no fallthrough" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/dep/package.json",
        \\{
        \\  "name": "dep",
        \\  "exports": {
        \\    ".": {
        \\      "import": null,
        \\      "types": "./dist/index.d.ts"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/dep/dist/index.d.ts", "export {};");
    try vfs.addFile("/a.ts", "");

    // With ONLY "import" in our conditions (no `types` shortcut), the
    // first matching condition is `import: null` which bails with
    // "no resolution" — even though `types` would otherwise match.
    // Mirrors `conditionalExportsResolutionFallbackNull.ts`.
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .conditions = &.{"import"},
    });
    defer r.deinit();
    // `types` is tried first per tsc; with `types: "./dist/index.d.ts"`
    // present, the resolution succeeds via the types channel. The null
    // gate only kicks in when `types` is absent — verified separately.
    const res = try r.resolve("dep", "/a.ts");
    try T.expectEqualStrings("/node_modules/dep/dist/index.d.ts", res.path);
}

test "Resolver: package exports — null without sibling types is a hard fail" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/dep/package.json",
        \\{
        \\  "name": "dep",
        \\  "main": "./fallback.js",
        \\  "exports": {
        \\    ".": {
        \\      "import": null
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/dep/fallback.js", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .conditions = &.{"import"},
    });
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("dep", "/a.ts"));
}

test "Resolver: package exports — subpath resolves through pattern wildcard" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{
        \\  "name": "foo",
        \\  "exports": {
        \\    "./*": {
        \\      "types": "./types/*.d.ts",
        \\      "import": "./esm/*.mjs"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/foo/types/sub.d.ts", "");
    try vfs.addFile("/node_modules/foo/esm/sub.mjs", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .conditions = &.{ "import", "node" },
    });
    defer r.deinit();
    const res = try r.resolve("foo/sub", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/types/sub.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: nestedPackageJsonRedirect — subpath has its own package.json with relative types" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    // Mirrors the conformance fixture: `@restart/hooks/useMergedRefs`
    // has its own `package.json` whose `types` field reaches into the
    // parent package's `esm/` directory via `..`.
    try vfs.addFile("/node_modules/@restart/hooks/package.json",
        \\{
        \\  "name": "@restart/hooks",
        \\  "main": "cjs/index.js",
        \\  "types": "cjs/index.d.ts"
        \\}
    );
    try vfs.addFile("/node_modules/@restart/hooks/useMergedRefs/package.json",
        \\{
        \\  "name": "@restart/hooks/useMergedRefs",
        \\  "main": "../cjs/useMergedRefs.js",
        \\  "types": "../esm/useMergedRefs.d.ts"
        \\}
    );
    try vfs.addFile("/node_modules/@restart/hooks/esm/useMergedRefs.d.ts", "export {};");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("@restart/hooks/useMergedRefs", "/main.ts");
    try T.expectEqualStrings("/node_modules/@restart/hooks/esm/useMergedRefs.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: typesVersions wildcard rewrites subpath into versioned types dir" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{
        \\  "name": "foo",
        \\  "main": "./index.js",
        \\  "typesVersions": { ">=4.0": { "*": ["ts4.0/*"] } }
        \\}
    );
    try vfs.addFile("/node_modules/foo/ts4.0/sub.d.ts", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("foo/sub", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/ts4.0/sub.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: untypedModuleImport — bare JS package without types still resolves to .js" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    // Mirrors `untypedModuleImport.ts` — a JS-only package without
    // any `.d.ts` should still surface a Resolution (the checker is
    // what decides whether to emit TS7016 under `--noImplicitAny`).
    try vfs.addFile("/node_modules/foo/package.json",
        \\{ "name": "foo", "version": "1.2.3" }
    );
    try vfs.addFile("/node_modules/foo/index.js", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("foo", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/index.js", res.path);
    try T.expect(!res.is_declaration);
}

test "Resolver: untypedModuleImport_noImplicitAny_scoped — scoped JS-only package resolves" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/@foo/bar/package.json",
        \\{ "name": "@foo/bar" }
    );
    try vfs.addFile("/node_modules/@foo/bar/index.js", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("@foo/bar", "/a.ts");
    try T.expectEqualStrings("/node_modules/@foo/bar/index.js", res.path);
    try T.expect(!res.is_declaration);
}

test "Resolver: untypedModuleImport_noImplicitAny_typesForPackageExist — sibling types subpath" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{ "name": "foo" }
    );
    try vfs.addFile("/node_modules/foo/index.d.ts", "");
    // Subpath has only a JS file — the resolver should still resolve
    // it (untyped) so the checker can emit TS7016 itself.
    try vfs.addFile("/node_modules/foo/sub.js", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("foo/sub", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/sub.js", res.path);
    try T.expect(!res.is_declaration);
}

test "Resolver: scoped package types preferred over main" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/@scope/foo/package.json",
        \\{
        \\  "main": "./index.js",
        \\  "types": "./index.d.ts"
        \\}
    );
    try vfs.addFile("/node_modules/@scope/foo/index.js", "");
    try vfs.addFile("/node_modules/@scope/foo/index.d.ts", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("@scope/foo", "/a.ts");
    try T.expectEqualStrings("/node_modules/@scope/foo/index.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: package exports — exact-key match beats wildcard pattern" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{
        \\  "exports": {
        \\    "./special": "./dist/special.d.ts",
        \\    "./*": "./dist/*.d.ts"
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/foo/dist/special.d.ts", "");
    try vfs.addFile("/node_modules/foo/dist/other.d.ts", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const exact = try r.resolve("foo/special", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/dist/special.d.ts", exact.path);
    const pat = try r.resolve("foo/other", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/dist/other.d.ts", pat.path);
}
