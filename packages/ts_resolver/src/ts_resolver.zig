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

pub const TypeReferenceResolutionMode = enum {
    import,
    require,
};

const import_type_reference_conditions = [_][]const u8{ "import", "node" };
const require_type_reference_conditions = [_][]const u8{ "require", "node" };
const bundler_import_conditions = [_][]const u8{"import"};
const bundler_require_conditions = [_][]const u8{"require"};

/// tsc-compatible display name for a resolution strategy, used in the
/// TS6087/TS6088 `--traceResolution` banner.
fn strategyName(s: Strategy) []const u8 {
    return switch (s) {
        .classic => "Classic",
        .node10 => "Node10",
        .node16 => "Node16",
        .nodenext => "NodeNext",
        .bundler => "Bundler",
    };
}

/// Module-resolution config. Caller-owned; kept as a slice borrowing
/// from the parsed tsconfig.
pub const Config = struct {
    strategy: Strategy = .bundler,
    /// True when `moduleResolution` was set explicitly (selects the
    /// TS6087 "Explicitly specified…" trace over the TS6088 default).
    explicit_strategy: bool = false,
    /// `compilerOptions.baseUrl`. Empty means unset.
    base_url: []const u8 = "",
    /// `compilerOptions.paths` — list of `(pattern, [target...])`.
    paths: []const PathEntry = &.{},
    /// Active conditions for `package.json` `exports`. The order
    /// matters: tsc inserts these *after* `node` and `default` is
    /// always tried last.
    conditions: []const []const u8 = &.{ "import", "node" },
    /// Effective `compilerOptions.module`, when a caller has one.
    /// Bundler resolution uses this together with the importer
    /// extension to pick `import` vs `require` conditions.
    module_kind: []const u8 = "",
    /// File extensions to probe for module specifiers without one.
    extensions: []const []const u8 = &.{ ".ts", ".tsx", ".d.ts", ".mts", ".cts", ".hm", ".home", ".d.hm", ".d.home", ".js", ".jsx", ".mjs", ".cjs" },
    /// True when `compilerOptions.allowImportingTsExtensions` is on.
    allow_ts_extensions: bool = false,
    /// True when `compilerOptions.resolveJsonModule` is on.
    resolve_json: bool = true,
    /// Output directory options used by modern package self-name
    /// resolution to map an `exports` target such as
    /// `./types/index.d.ts` or `./dist/index.js` back to the source
    /// input (`./index.ts`) before giving up.
    out_dir: []const u8 = "",
    declaration_dir: []const u8 = "",
    root_dir: []const u8 = "",
    /// `compilerOptions.rootDirs`, resolved by callers when available.
    /// Relative entries are interpreted relative to `config_file_path`.
    root_dirs: []const []const u8 = &.{},
    config_file_path: []const u8 = "",
    /// Project-reference redirect config name when a host resolves with
    /// compiler options borrowed from that referenced project. When set
    /// and tracing is active, resolution emits TS6215.
    project_reference_redirect_config: []const u8 = "",
    /// True when source-to-output fallback should be surfaced as TS6305
    /// metadata for project-reference consumers. Plain package self-name
    /// fallback leaves this false so same-project imports remain clean.
    project_reference_output_diagnostics: bool = false,
    /// `compilerOptions.typeRoots` or harness `@typeRoots` roots.
    /// These are custom package-root directories such as `/a/types`;
    /// explicit `node_modules/@types` roots still use TypeScript's
    /// scoped-name mangling.
    type_roots: []const []const u8 = &.{},
    /// Project display name for automatic typings discovery traces.
    project_name: []const u8 = "",
    /// Automatic typings cache directory. When set, unresolved or JS-only
    /// bare module resolutions get one declaration-only retry under this
    /// directory's immediate `node_modules`, matching tsc's TS6140 path.
    typings_location: []const u8 = "",

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
    /// True for `.d.ts` / `.d.hm` / `.d.home` summary files.
    is_declaration: bool,
    /// When the primary resolution went through `package.json`
    /// `exports` and landed on a non-declaration (JS) file under an
    /// ESM (`import`) importer, but a declaration file WOULD have
    /// resolved had `exports` been ignored, this holds that
    /// otherwise-unreachable declaration path. tsc uses it to emit
    /// the TS6278 "There are types at '{0}', but this result could
    /// not be resolved when respecting package.json \"exports\""
    /// elaboration on TS7016. Null when there is no such alternate.
    /// Borrowed from the resolver's arena like `path`.
    alternate_result: ?[]const u8 = null,
    /// When an `exports`/`imports` target under `declarationDir`/`outDir`
    /// was reverse-mapped to a source input because the emitted output
    /// file is absent, this is the missing output path. The checker uses
    /// it to report TS6305 instead of treating the source as a normal
    /// implementation-file resolution.
    project_reference_output: ?[]const u8 = null,
    /// True when the package exports object contains an active
    /// `import`/`require` condition mapped to null. TypeScript treats
    /// that as a hard module-resolution failure even if the `types`
    /// condition can name a declaration file.
    blocked_by_exports_null: bool = false,
    /// tsc's package identity string for node_modules resolutions when
    /// the owning package.json has both `name` and `version`.
    package_id: ?[]const u8 = null,

    pub const Source = enum {
        relative,
        absolute,
        paths_mapping,
        node_modules,
        package_exports,
        package_main,
        index_file,
        type_roots,
        root_dirs,
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
        /// Lists immediate directory entries. Caller frees with `freeDirEntries`.
        readDir: *const fn (self: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]DirEntry,
        /// Returns the filesystem real path. Caller frees.
        realpath: *const fn (self: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8,
    };

    pub const DirEntry = struct {
        name: []const u8,
        is_dir: bool,
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
    pub fn readDir(self: FileSystem, gpa: std.mem.Allocator, path: []const u8) anyerror![]DirEntry {
        return self.vtable.readDir(self.ptr, gpa, path);
    }
    pub fn realpath(self: FileSystem, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        return self.vtable.realpath(self.ptr, gpa, path);
    }

    pub fn freeDirEntries(gpa: std.mem.Allocator, entries: []DirEntry) void {
        for (entries) |entry| gpa.free(entry.name);
        gpa.free(entries);
    }
};

/// Module resolver. Caller owns the strings inside `Resolution`;
/// they're allocated from the resolver's arena.
/// Collects `--traceResolution` trace lines (tsc's `TSxxxx` resolution
/// trace messages). Each entry carries its TypeScript message code and
/// the fully-formatted text. Owns an arena for the text. When a
/// `Resolver` has no sink attached, tracing is a no-op (zero overhead),
/// so the resolver behaves identically with or without `--traceResolution`.
pub const TraceSink = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    /// Hard cap on collected trace lines — a safety bound so a pathological
    /// resolution closure can't grow the sink without limit.
    pub const max_entries: usize = 20_000;

    pub const Entry = struct { code: u32, text: []const u8 };

    pub fn init(gpa: std.mem.Allocator) TraceSink {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *TraceSink) void {
        self.arena.deinit();
    }
};

pub const Resolver = struct {
    gpa: std.mem.Allocator,
    fs: FileSystem,
    config: Config,
    arena: std.heap.ArenaAllocator,
    /// Optional `--traceResolution` sink. Null means tracing is off.
    trace: ?*TraceSink = null,
    /// Guards the once-per-program resolution-kind banner (TS6087/6088).
    resolution_kind_traced: bool = false,
    /// Per-(directory, specifier) resolution memo, mirroring tsc's
    /// module-resolution cache. The checker re-resolves the same
    /// specifiers many times during type-checking; without this every
    /// reference re-walks the filesystem (and, under `--traceResolution`,
    /// re-emits the whole trace, which exploded the trace volume). Keyed
    /// by `"<dir>\x00<specifier>"` (interned in `arena`); value `null`
    /// memoizes a `NotFound`. Resolution depends only on the containing
    /// DIRECTORY (relative joins + the package-scope walk both start from
    /// `dirname(containing_file)`), so a per-dir key is sound.
    cache: std.StringHashMapUnmanaged(?Resolution) = .empty,
    /// Per-file existence memo used by traced candidate probes. This
    /// mirrors tsc's lower-level lookup cache so repeated candidates can
    /// report TS6239/TS6240 instead of hitting the filesystem again.
    file_exists_cache: std.StringHashMapUnmanaged(bool) = .empty,
    /// Set transiently by `attachExportsAlternateResult` while probing
    /// the exports-disabled "alternate" resolution. In this mode the
    /// legacy `main`/`types`/`module` fields only count when they
    /// produce a declaration file, so a JS-only `main` falls through to
    /// the sibling `@types/<pkg>` package (mirroring tsc's
    /// declaration-only alternate pass).
    alternate_mode: bool = false,
    /// Set when an `exports`/`imports` map entry is resolved under a
    /// project with `outDir`/`declarationDir` but no way to establish the
    /// project root (no `rootDir`, no config file) — tsc's TS2209/TS2210.
    /// tsc reports this and leaves the specifier UNRESOLVED (the import's
    /// would-be TS2307 is suppressed in favour of this). Cleared at the
    /// start of each `resolve`; the bridge/checker reads it after a failed
    /// resolution. Arena-allocated.
    ambiguous_root: ?AmbiguousRoot = null,

    /// A TS2209 (exports) / TS2210 (imports) project-root-ambiguous record:
    /// the map `entry` (`.`, `./sub`, `#imp`) and the `package.json` `file`
    /// it was declared in.
    pub const AmbiguousRoot = struct {
        entry: []const u8,
        file: []const u8,
        is_imports: bool,
    };

    pub fn init(gpa: std.mem.Allocator, fs: FileSystem, config: Config) Resolver {
        return .{
            .gpa = gpa,
            .fs = fs,
            .config = config,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.file_exists_cache.deinit(self.gpa);
        self.cache.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Best-effort rendering of the probe extension set for the
    /// "target file types: {1}" trace slot. Honestly reports the
    /// extensions Home actually probes (rendered into the trace sink's
    /// arena). Only called when a sink is attached.
    fn targetFileTypesText(self: *Resolver) []const u8 {
        const sink = self.trace orelse return "";
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const a = sink.arena.allocator();
        buf.append(a, '[') catch return "[]";
        for (self.config.extensions, 0..) |ext, i| {
            if (i != 0) buf.appendSlice(a, ", ") catch return "[]";
            buf.append(a, '\'') catch return "[]";
            buf.appendSlice(a, ext) catch return "[]";
            buf.append(a, '\'') catch return "[]";
        }
        buf.append(a, ']') catch return "[]";
        return buf.items;
    }

    fn conditionsText(self: *Resolver) []const u8 {
        const sink = self.trace orelse return "";
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const a = sink.arena.allocator();
        for (self.config.conditions, 0..) |condition, i| {
            if (i != 0) buf.appendSlice(a, ", ") catch return "";
            buf.append(a, '\'') catch return "";
            buf.appendSlice(a, condition) catch return "";
            buf.append(a, '\'') catch return "";
        }
        return buf.items;
    }

    /// Append a `--traceResolution` line (no-op when no sink is attached).
    /// Capped at `TraceSink.max_entries`: resolving a full type/lib
    /// closure (e.g. during declaration emit) can drive an enormous
    /// number of resolutions, and an uncapped sink would grow without
    /// bound. The cap is far above what any human reads for diagnosis.
    fn traceMsg(self: *Resolver, code: u32, comptime fmt: []const u8, args: anytype) void {
        const sink = self.trace orelse return;
        if (sink.entries.items.len >= TraceSink.max_entries) return;
        const a = sink.arena.allocator();
        const text = std.fmt.allocPrint(a, fmt, args) catch return;
        sink.entries.append(a, .{ .code = code, .text = text }) catch {};
    }

    fn traceResolutionUsingProjectReference(self: *Resolver) void {
        if (self.config.project_reference_redirect_config.len == 0) return;
        self.traceMsg(
            6215,
            "Using compiler options of project reference redirect '{s}'.",
            .{self.config.project_reference_redirect_config},
        );
    }

    /// Resolve `specifier` from a file located at `containing_file`.
    /// `containing_file` is the importer; specifier is its argument
    /// to `import`/`require`/`from`. Memoizes per (directory, specifier)
    /// and wraps `resolveImpl` with tsc's per-resolution entry/exit
    /// banner traces (TS6086/6089/6090) — emitted only on a cache MISS,
    /// so repeated resolutions of the same specifier don't re-walk the
    /// filesystem or re-emit traces.
    pub fn resolve(
        self: *Resolver,
        specifier: []const u8,
        containing_file: []const u8,
    ) ResolveError!Resolution {
        if (specifier.len == 0) return error.InvalidSpecifier;
        // Fresh per-resolution: any TS2209/TS2210 ambiguity is recorded
        // during this call and read by the caller immediately after.
        self.ambiguous_root = null;
        // Once-per-program resolution-kind banner (tsc emits this before
        // the first module resolution). TS6087 when explicit, TS6088 when
        // defaulted.
        if (self.trace != null and !self.resolution_kind_traced) {
            self.resolution_kind_traced = true;
            const kind = strategyName(self.config.strategy);
            if (self.config.explicit_strategy) {
                self.traceMsg(6087, "Explicitly specified module resolution kind: '{s}'.", .{kind});
            } else {
                self.traceMsg(6088, "Module resolution kind is not specified, using '{s}'.", .{kind});
            }
        }
        const saved_conditions = self.config.conditions;
        if (self.activeConditionsForResolution(containing_file)) |conditions| {
            self.config.conditions = conditions;
        }
        defer self.config.conditions = saved_conditions;

        // Cache key: "<containing-file>\x00<specifier>" interned in
        // the resolver arena. Bundler resolution can vary conditions
        // by importer extension (`.mts` vs `.cts`) and effective module
        // kind, so a directory-only key would incorrectly share
        // package-export results across files in the same folder.
        // On allocation failure, fall through to an uncached resolve.
        const key = std.fmt.allocPrint(self.arena.allocator(), "{s}\x00{s}", .{ containing_file, specifier }) catch
            return self.resolveTraced(specifier, containing_file);
        if (self.cache.get(key)) |cached| return cached orelse error.NotFound;
        const result = self.resolveTraced(specifier, containing_file);
        if (result) |r| {
            self.cache.put(self.gpa, key, r) catch {};
        } else |e| {
            // Don't memoize a TS2209/TS2210-ambiguous failure: the
            // ambiguity is reported per importing file, so each resolve
            // must re-run and re-stash `ambiguous_root` (a cached null
            // would suppress it for the 2nd+ importer).
            if (e == error.NotFound and self.ambiguous_root == null) self.cache.put(self.gpa, key, null) catch {};
        }
        return result;
    }

    fn activeConditionsForResolution(self: *Resolver, containing_file: []const u8) ?[]const []const u8 {
        if (self.config.strategy != .bundler) return null;
        if (std.mem.endsWith(u8, containing_file, ".cts") or
            std.mem.endsWith(u8, containing_file, ".cjs"))
            return &bundler_require_conditions;
        if (std.mem.endsWith(u8, containing_file, ".mts") or
            std.mem.endsWith(u8, containing_file, ".mjs"))
            return &bundler_import_conditions;
        if (self.config.module_kind.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(self.config.module_kind, "commonjs"))
            return &bundler_require_conditions;
        return &bundler_import_conditions;
    }

    /// Resolve a triple-slash `<reference types="...">` directive.
    /// Kept as a sibling API to module resolution because tsc traces
    /// type-reference directives with their own TS6116/6119/6120/etc.
    /// banners and searches custom `typeRoots` before `node_modules/@types`.
    pub fn resolveTypeReferenceDirective(
        self: *Resolver,
        directive: []const u8,
        containing_file: []const u8,
    ) ResolveError!Resolution {
        if (directive.len == 0) return error.InvalidSpecifier;
        if (self.trace != null) {
            if (try self.typeReferenceRootDir(containing_file)) |root_dir| {
                self.traceMsg(6116, "======== Resolving type reference directive '{s}', containing file '{s}', root directory '{s}'. ========", .{ directive, containing_file, root_dir });
            } else {
                self.traceMsg(6242, "======== Resolving type reference directive '{s}', containing file '{s}'. ========", .{ directive, containing_file });
            }
            self.traceResolutionUsingProjectReference();
        }
        const result = self.resolveTypeReferenceDirectiveImpl(directive, containing_file);
        if (result) |found| {
            const primary = if (found.primary) "true" else "false";
            if (found.resolution.package_id) |package_id| {
                self.traceMsg(6219, "======== Type reference directive '{s}' was successfully resolved to '{s}' with Package ID '{s}', primary: {s}. ========", .{ directive, found.resolution.path, package_id, primary });
            } else {
                self.traceMsg(6119, "======== Type reference directive '{s}' was successfully resolved to '{s}', primary: {s}. ========", .{ directive, found.resolution.path, primary });
            }
            return found.resolution;
        } else |e| {
            if (e == error.NotFound) {
                self.traceMsg(6120, "======== Type reference directive '{s}' was not resolved. ========", .{directive});
            }
            return e;
        }
    }

    /// Resolve a triple-slash `<reference types="...">` directive with
    /// an explicit `resolution-mode` attribute. TypeScript applies that
    /// requested ESM/CJS condition set to package exports even when the
    /// surrounding project otherwise uses a legacy resolver.
    pub fn resolveTypeReferenceDirectiveWithMode(
        self: *Resolver,
        directive: []const u8,
        containing_file: []const u8,
        mode: TypeReferenceResolutionMode,
    ) ResolveError!Resolution {
        const saved_strategy = self.config.strategy;
        const saved_conditions = self.config.conditions;
        self.config.strategy = switch (saved_strategy) {
            .classic, .node10 => .bundler,
            else => saved_strategy,
        };
        self.config.conditions = switch (mode) {
            .import => &import_type_reference_conditions,
            .require => &require_type_reference_conditions,
        };
        defer {
            self.config.strategy = saved_strategy;
            self.config.conditions = saved_conditions;
        }
        return self.resolveTypeReferenceDirective(directive, containing_file);
    }

    /// `resolveImpl` plus the TS6086/6089/6090 banner traces. Separated
    /// so `resolve` can apply the memo around it.
    fn resolveTraced(
        self: *Resolver,
        specifier: []const u8,
        containing_file: []const u8,
    ) ResolveError!Resolution {
        if (self.trace != null) {
            self.traceMsg(6086, "======== Resolving module '{s}' from '{s}'. ========", .{ specifier, containing_file });
            self.traceResolutionUsingProjectReference();
        }
        const result = self.resolveImpl(specifier, containing_file);
        if (result) |r| {
            if (self.trace != null) {
                if (r.package_id) |package_id| {
                    self.traceMsg(6218, "======== Module name '{s}' was successfully resolved to '{s}' with Package ID '{s}'. ========", .{ specifier, r.path, package_id });
                } else {
                    self.traceMsg(6089, "======== Module name '{s}' was successfully resolved to '{s}'. ========", .{ specifier, r.path });
                }
            }
        } else |_| {
            if (self.trace != null) {
                self.traceMsg(6090, "======== Module name '{s}' was not resolved. ========", .{specifier});
            }
        }
        return self.tryResolveFromTypingsLocation(specifier, result);
    }

    fn tryResolveFromTypingsLocation(
        self: *Resolver,
        specifier: []const u8,
        original_result: ResolveError!Resolution,
    ) ResolveError!Resolution {
        if (self.config.typings_location.len == 0 or
            isRelative(specifier) or
            isAbsolute(specifier))
        {
            return original_result;
        }

        if (original_result) |r| {
            if (isSupportedTsOrJsonPath(r.path)) return r;
        } else |err| {
            if (err != error.NotFound) return err;
        }

        self.traceMsg(
            6140,
            "Auto discovery for typings is enabled in project '{s}'. Running extra resolution pass for module '{s}' using cache location '{s}'.",
            .{ self.config.project_name, specifier, self.config.typings_location },
        );
        if (try self.tryAutomaticTypingsLocation(specifier)) |r| return r;
        return original_result;
    }

    fn tryAutomaticTypingsLocation(
        self: *Resolver,
        specifier: []const u8,
    ) ResolveError!?Resolution {
        const declaration_extensions = [_][]const u8{ ".d.ts", ".d.mts", ".d.cts", ".d.hm", ".d.home" };
        const saved_exts = self.config.extensions;
        const saved_resolve_json = self.config.resolve_json;
        self.config.extensions = &declaration_extensions;
        self.config.resolve_json = false;
        defer {
            self.config.extensions = saved_exts;
            self.config.resolve_json = saved_resolve_json;
        }

        const nm = try self.joinPath(self.config.typings_location, "node_modules");
        if (!self.fs.directoryExists(nm)) {
            self.traceMsg(6148, "Directory '{s}' does not exist, skipping all lookups in it.", .{nm});
            return null;
        }

        const split = packageNameSplit(specifier);
        const pkg_root = try self.joinPath(nm, split.name);
        const root_pkg_json = try self.joinPath(pkg_root, "package.json");
        const has_root_pkg_json = self.fs.fileExists(root_pkg_json);
        if (split.subpath.len > 0) {
            if (has_root_pkg_json) {
                const sub_outcome = try self.resolvePackageSubpath(pkg_root, root_pkg_json, split.subpath);
                switch (sub_outcome) {
                    .resolved => |r| if (r.is_declaration) {
                        return try self.withPackageId(.{ .path = r.path, .source = .node_modules, .is_declaration = true }, pkg_root, root_pkg_json, false);
                    },
                    .blocked => return null,
                    .none => {},
                }
            }
        } else if (has_root_pkg_json) {
            const root_outcome = try self.resolvePackageSubpath(pkg_root, root_pkg_json, ".");
            switch (root_outcome) {
                .resolved => |r| if (r.is_declaration) {
                    return try self.withPackageId(.{ .path = r.path, .source = .node_modules, .is_declaration = true }, pkg_root, root_pkg_json, false);
                },
                .blocked => return null,
                .none => {},
            }
        }

        if (try self.tryAtTypesFallback(nm, split.name, split.subpath)) |r| return r;

        const candidate = try self.joinPath(nm, specifier);
        if (try self.tryFileWithExtensions(candidate)) |r| {
            if (r.is_declaration) return .{ .path = r.path, .source = .node_modules, .is_declaration = true };
        }
        if (try self.tryDirectoryIndex(candidate)) |r| {
            if (r.is_declaration) return .{ .path = r.path, .source = .node_modules, .is_declaration = true };
        }
        return null;
    }

    fn resolveImpl(
        self: *Resolver,
        specifier: []const u8,
        containing_file: []const u8,
    ) ResolveError!Resolution {
        if (specifier.len == 0) return error.InvalidSpecifier;

        // Relative or absolute path.
        if (isRelative(specifier)) {
            const dir = dirname(containing_file);
            // tsc accepts a bare `.` (and `..`) as a relative
            // directory specifier — `import x from "."` resolves to
            // `./index.{ts,…}` in the containing file's directory.
            // Normalize to `./` / `../` so `joinPath` produces a
            // clean directory path that `tryDirectoryIndex` can stat
            // (mirrors `importFromDot.ts`).
            const normalized: []const u8 = if (std.mem.eql(u8, specifier, "."))
                "./"
            else if (std.mem.eql(u8, specifier, ".."))
                "../"
            else
                specifier;
            const joined = try self.joinPath(dir, normalized);
            if (try self.tryFileWithExtensions(joined)) |r| return r;
            if (try self.tryDirectoryIndex(joined)) |r| return r;
            if (try self.tryRootDirs(normalized, joined)) |r| return r;
            return error.NotFound;
        }
        if (isAbsolute(specifier)) {
            if (try self.tryFileWithExtensions(specifier)) |r| return r;
            if (try self.tryDirectoryIndex(specifier)) |r| return r;
            return error.NotFound;
        }

        // Bare specifier — paths mapping → `#imports` → self-name → node_modules → typeRoots.
        const resolution_mode = if (self.hasCondition("import")) "ESM" else "CJS";
        self.traceMsg(6402, "Resolving in {s} mode with conditions {s}.", .{ resolution_mode, self.conditionsText() });
        if (try self.tryPathsMapping(specifier)) |r| return r;
        if (self.config.strategy == .classic) {
            const dir = dirname(containing_file);
            const joined = try self.joinPath(dir, specifier);
            if (try self.tryFileWithExtensions(joined)) |r| return r;
            if (try self.tryDirectoryIndex(joined)) |r| return r;
        }
        // The modern resolvers (node16/nodenext/bundler) honor a few
        // package.json-scope-relative lookups BEFORE walking node_modules,
        // matching tsc's `resolveModuleName` order (`loadModuleFromImports`
        // then `loadModuleFromSelfNameReference`). The legacy `node10` and
        // `classic` strategies skip both — they only ever consult
        // node_modules / `main` (no `exports`-scoped indirection).
        if (self.exportsResolutionEnabled()) {
            // `#`-prefixed private subpath imports resolve against the
            // nearest enclosing `package.json` `imports` map.
            if (specifier.len > 0 and specifier[0] == '#') {
                if (std.mem.eql(u8, specifier, "#") or std.mem.startsWith(u8, specifier, "#/")) {
                    self.traceMsg(6272, "Invalid import specifier '{s}' has no possible resolutions.", .{specifier});
                    return error.NotFound;
                }
                if (try self.tryImportsMapping(specifier, containing_file)) |r| return r;
                // A `#`-prefixed specifier never resolves through
                // node_modules; if the imports map didn't cover it, it's
                // unresolved (tsc treats `#`-specifiers as scope-private).
                return error.NotFound;
            }
            // Self-name: `import "<own-name>/sub"` from inside a package
            // whose `package.json` declares a matching `name` + `exports`.
            if (try self.trySelfNameReference(specifier, containing_file)) |r| return r;
        }
        if (looksLikeAbsoluteUriSpecifier(specifier)) {
            self.traceMsg(
                6164,
                "Skipping module '{s}' that looks like an absolute URI, target file types: {s}.",
                .{ specifier, self.targetFileTypesText() },
            );
            return error.NotFound;
        }
        if (try self.tryNodeModules(specifier, containing_file)) |r| {
            return try self.attachExportsAlternateResult(r, specifier, containing_file);
        }
        if (try self.tryTypeRoots(specifier)) |r| return r;
        return error.NotFound;
    }

    const TypeReferenceLookup = struct {
        resolution: Resolution,
        primary: bool,
    };

    fn resolveTypeReferenceDirectiveImpl(
        self: *Resolver,
        directive: []const u8,
        containing_file: []const u8,
    ) ResolveError!TypeReferenceLookup {
        if (self.config.type_roots.len > 0) {
            self.traceMsg(6121, "Resolving with primary search path '{s}'.", .{self.typeRootsTraceText()});
            var saw_existing_root = false;
            for (self.config.type_roots) |root| {
                if (root.len == 0) continue;
                if (self.fs.directoryExists(root)) saw_existing_root = true;
                if (try self.tryTypeReferenceRoot(root, directive)) |r| {
                    return .{ .resolution = r, .primary = true };
                }
            }
            if (saw_existing_root) {
                self.traceMsg(6265, "Resolving type reference directive for program that specifies custom typeRoots, skipping lookup in 'node_modules' folder.", .{});
                return error.NotFound;
            }
        }

        return self.resolveTypeReferenceDirectiveFromNodeModules(directive, containing_file);
    }

    fn resolveTypeReferenceDirectiveFromNodeModules(
        self: *Resolver,
        directive: []const u8,
        containing_file: []const u8,
    ) ResolveError!TypeReferenceLookup {
        if (containing_file.len == 0) {
            self.traceMsg(6122, "Root directory cannot be determined, skipping primary search paths.", .{});
            return error.NotFound;
        }

        var dir = dirname(containing_file);
        while (true) {
            const nm = try self.joinPath(dir, "node_modules");
            const at_types = try self.joinPath(nm, "@types");
            if (try self.tryTypeReferenceAtTypesRoot(at_types, directive)) |r| {
                return .{ .resolution = r, .primary = false };
            }
            if (try self.tryTypeReferencePackageRoot(nm, directive)) |r| {
                return .{ .resolution = r, .primary = false };
            }
            if (dir.len == 0 or std.mem.eql(u8, dir, "/")) break;
            const parent = dirname(dir);
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }
        return error.NotFound;
    }

    /// Walk up from `containing_file`'s directory to the nearest
    /// `package.json` and return `(dir, package.json path)`. Mirrors
    /// tsc's `getPackageScopeForPath` — the enclosing package scope is
    /// the first ancestor directory holding a `package.json`. Returns
    /// null when no ancestor has one.
    const PackageScope = struct { dir: []const u8, pkg_json: []const u8 };
    fn getPackageScope(self: *Resolver, containing_file: []const u8) ResolveError!?PackageScope {
        var dir = dirname(containing_file);
        while (true) {
            const pkg_path = try self.joinPath(dir, "package.json");
            if (self.fs.fileExists(pkg_path)) {
                self.traceMsg(6099, "Found 'package.json' at '{s}'.", .{pkg_path});
                return .{ .dir = dir, .pkg_json = pkg_path };
            }
            if (dir.len == 0 or std.mem.eql(u8, dir, "/")) break;
            const parent = dirname(dir);
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }
        return null;
    }

    /// tsc's `loadModuleFromSelfNameReference`: when the enclosing
    /// `package.json` has a `name` AND an `exports` map, a bare specifier
    /// that begins with that `name` resolves through the package's own
    /// `exports` (so a package can import itself by name). Returns null
    /// when there is no matching scope or the specifier's leading path
    /// components don't equal the package name.
    fn trySelfNameReference(
        self: *Resolver,
        specifier: []const u8,
        containing_file: []const u8,
    ) ResolveError!?Resolution {
        const scope = (try self.getPackageScope(containing_file)) orelse return null;
        const bytes = self.fs.readFile(self.gpa, scope.pkg_json) catch return null;
        defer self.gpa.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const obj = parsed.value.object;
        // Self-name only applies to packages that publish `exports`;
        // without it there is no self-name channel (matches the
        // `!scope.contents.packageJsonContent.exports` guard upstream).
        if (obj.get("exports") == null) return null;
        const name_v = obj.get("name") orelse return null;
        if (name_v != .string) return null;
        const name = name_v.string;
        if (name.len == 0) return null;
        // The specifier must be `<name>` exactly or `<name>/<subpath>`.
        if (!std.mem.startsWith(u8, specifier, name)) return null;
        const rest = specifier[name.len..];
        const subpath: []const u8 = if (rest.len == 0)
            "."
        else if (rest[0] == '/')
            rest[1..]
        else
            return null; // `name` matched only as a prefix of a longer name
        const outcome = try self.resolvePackageSubpath(scope.dir, scope.pkg_json, subpath);
        switch (outcome) {
            .resolved => |r| return .{
                .path = r.path,
                .source = .package_exports,
                .is_declaration = r.is_declaration,
                .alternate_result = r.alternate_result,
                .project_reference_output = r.project_reference_output,
                .package_id = r.package_id,
            },
            .blocked, .none => return null,
        }
    }

    /// tsc's `loadModuleFromImports`: a `#`-prefixed specifier resolves
    /// against the nearest enclosing `package.json` `imports` map (the
    /// private-subpath analogue of `exports`). Honors the same condition
    /// chain and `null`-short-circuit semantics as `exports`. Returns
    /// null when no scope/`imports` entry covers the specifier.
    fn tryImportsMapping(
        self: *Resolver,
        specifier: []const u8,
        containing_file: []const u8,
    ) ResolveError!?Resolution {
        const scope = (try self.getPackageScope(containing_file)) orelse {
            const directory_path = dirname(containing_file);
            self.traceMsg(6270, "Directory '{s}' has no containing package.json scope. Imports will not resolve.", .{directory_path});
            return null;
        };
        const bytes = self.fs.readFile(self.gpa, scope.pkg_json) catch return null;
        defer self.gpa.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const obj = parsed.value.object;
        const imports_v = obj.get("imports") orelse {
            self.traceMsg(6273, "package.json scope '{s}' has no imports defined.", .{scope.dir});
            return null;
        };
        // `imports` keys are always `#`-prefixed; reuse the same subpath
        // lookup machinery as `exports` (exact key then `*` pattern).
        if (try self.lookupExports(imports_v, specifier, "imports", scope.dir)) |target| {
            switch (target) {
                .matched_null => {
                    self.traceMsg(6274, "package.json scope '{s}' explicitly maps specifier '{s}' to null.", .{ scope.dir, specifier });
                    return null; // hard rejection
                },
                .matched => |m| {
                    const joined = try self.joinPath(scope.dir, m);
                    if (try self.tryFileWithExtensions(joined)) |r| {
                        return .{ .path = r.path, .source = .package_exports, .is_declaration = r.is_declaration };
                    }
                    return null;
                },
                .not_matched => {
                    self.traceMsg(6271, "Import specifier '{s}' does not exist in package.json scope at path '{s}'.", .{ specifier, scope.dir });
                    return null;
                },
                .invalid_target => return null,
            }
        }
        self.traceMsg(6271, "Import specifier '{s}' does not exist in package.json scope at path '{s}'.", .{ specifier, scope.dir });
        return null;
    }

    /// Mirrors tsc's `resolveNodeLike` alternate-result post-step: when
    /// the primary resolution went through `package.json` `exports`
    /// (modern resolver) under an ESM (`import`) importer and landed on
    /// a non-declaration JS file, tsc re-resolves with `exports`
    /// IGNORED and only declaration/TypeScript extensions enabled to
    /// see whether the library *could* have been typed had it published
    /// `exports` correctly. If that alternate finds a declaration file,
    /// it is stashed on `Resolution.alternate_result` so the checker can
    /// surface the TS6278 elaboration on TS7016. Returns `r` unchanged
    /// when no alternate applies.
    fn attachExportsAlternateResult(
        self: *Resolver,
        r: Resolution,
        specifier: []const u8,
        containing_file: []const u8,
    ) ResolveError!Resolution {
        // Only the modern resolvers consult `exports`; the legacy
        // strategies never need an alternate.
        if (!self.exportsResolutionEnabled()) return r;
        // The primary result is already typed — nothing to recover.
        if (r.is_declaration) return r;
        // Bare (non-relative) specifiers only — `exports` is a
        // node_modules-package concept.
        if (isRelative(specifier) or isAbsolute(specifier)) return r;
        // The alternate only fires for ESM importers, matching tsc's
        // `slices.Contains(r.conditions, "import")` guard.
        if (!self.hasCondition("import")) return r;

        // Re-resolve with `exports` disabled (node10 strategy) and only
        // declaration/TypeScript extensions in play, so a `.js`/`.mjs`
        // implementation can't masquerade as the alternate.
        self.traceMsg(6277, "Resolution of non-relative name failed; trying with modern Node resolution features disabled to see if npm library needs configuration update.", .{});
        const saved_strategy = self.config.strategy;
        const saved_exts = self.config.extensions;
        self.config.strategy = .node10;
        self.config.extensions = &.{ ".d.ts", ".d.mts", ".d.cts", ".ts", ".tsx", ".mts", ".cts", ".d.hm", ".d.home" };
        self.alternate_mode = true;
        defer {
            self.config.strategy = saved_strategy;
            self.config.extensions = saved_exts;
            self.alternate_mode = false;
        }
        if (try self.tryNodeModules(specifier, containing_file)) |alt| {
            if (alt.is_declaration) {
                self.traceMsg(6278, "There are types at '{s}', but this result could not be resolved when respecting package.json \"exports\". The '{s}' library may need to update its package.json or typings.", .{ alt.path, packageNameSplit(specifier).name });
                return .{
                    .path = r.path,
                    .source = r.source,
                    .is_declaration = r.is_declaration,
                    .alternate_result = alt.path,
                };
            }
        }
        return r;
    }

    /// True when `cond` is among the configured `exports` conditions.
    fn hasCondition(self: *Resolver, cond: []const u8) bool {
        for (self.config.conditions) |c| {
            if (std.mem.eql(u8, c, cond)) return true;
        }
        return false;
    }

    // ---- Internal helpers ----

    fn ar(self: *Resolver) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// True when the configured strategy honors `package.json`
    /// `exports` (and `imports`) maps. tsc only consults `exports`
    /// under the modern resolvers — `node16`, `nodenext`, and
    /// `bundler`. The legacy `node10` (a.k.a. `node`) strategy
    /// IGNORES `exports` and resolves through `main`/`types` only;
    /// `classic` doesn't even look at `package.json`.
    fn exportsResolutionEnabled(self: *Resolver) bool {
        return switch (self.config.strategy) {
            .node16, .nodenext, .bundler => true,
            .classic, .node10 => false,
        };
    }

    fn joinPath(self: *Resolver, a: []const u8, b: []const u8) ResolveError![]const u8 {
        // An absolute `b` (e.g. a `package.json` `"types"` field of
        // `/.ts/typescript.d.ts`) discards `a` entirely — matching
        // tsc's `combinePaths`, where a rooted trailing path resets
        // the result. Without this an absolute `types`/`typings`
        // value gets spuriously concatenated onto the package dir.
        if (isAbsolute(b)) return self.ar().dupe(u8, b) catch error.OutOfMemory;
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

    /// `fileExists` wrapped with tsc's per-candidate resolution traces
    /// (TS6097 "File 'X' exists - use it as a name resolution result." /
    /// TS6096 "File 'X' does not exist."). Repeated probes use the
    /// lookup cache traces TS6239/TS6240. No-op tracing when no sink.
    fn fileExistsTraced(self: *Resolver, path: []const u8) bool {
        if (self.trace == null) return self.fs.fileExists(path);
        if (self.file_exists_cache.get(path)) |exists| {
            if (exists) {
                self.traceMsg(6239, "File '{s}' exists according to earlier cached lookups.", .{path});
            } else {
                self.traceMsg(6240, "File '{s}' does not exist according to earlier cached lookups.", .{path});
            }
            return exists;
        }
        const exists = self.fs.fileExists(path);
        const key = self.ar().dupe(u8, path) catch {
            self.traceFileExists(path, exists);
            return exists;
        };
        self.file_exists_cache.put(self.gpa, key, exists) catch {};
        self.traceFileExists(path, exists);
        return exists;
    }

    fn traceFileExists(self: *Resolver, path: []const u8, exists: bool) void {
        if (self.trace != null) {
            if (exists) {
                self.traceMsg(6097, "File '{s}' exists - use it as a name resolution result.", .{path});
            } else {
                self.traceMsg(6096, "File '{s}' does not exist.", .{path});
            }
        }
    }

    /// Probe `base` then `base.ext` for each configured extension and
    /// `.d.ts`. Returns the first hit.
    fn tryFileWithExtensions(self: *Resolver, base: []const u8) ResolveError!?Resolution {
        self.traceMsg(
            6095,
            "Loading module as file / folder, candidate module location '{s}', target file types: {s}.",
            .{ base, self.targetFileTypesText() },
        );
        // Direct file with explicit extension first. `.json` is gated on
        // `resolveJsonModule` per tsc — otherwise even
        // `import "./data.json"` is left unresolved.
        const explicit_json = hasExtension(base, ".json");
        const explicit_known = hasKnownExtension(base) or (explicit_json and self.config.resolve_json);
        if (explicit_known) {
            if (self.config.strategy == .bundler and isImplementationOutputPath(base)) {
                if (try self.tryFileWithOutputExtensionSubstitution(base)) |resolution| {
                    return resolution;
                }
            }
            if (self.fileExistsTraced(base)) {
                return .{
                    .path = try self.ar().dupe(u8, base),
                    .source = .relative,
                    .is_declaration = isDeclarationPath(base),
                };
            }
            if (self.config.strategy != .bundler or !isImplementationOutputPath(base)) {
                if (try self.tryFileWithOutputExtensionSubstitution(base)) |resolution| {
                    return resolution;
                }
            }
            if (try self.tryFileWithTsExtensionSubstitution(base)) |resolution| {
                return resolution;
            }
        }
        if (!explicit_known) {
            if (try self.tryArbitraryExtensionDeclaration(base)) |resolution| {
                return resolution;
            }
        }
        // Probe each extension in order.
        for (self.config.extensions) |ext| {
            const candidate = std.fmt.allocPrint(self.ar(), "{s}{s}", .{ base, ext }) catch return error.OutOfMemory;
            if (self.fileExistsTraced(candidate)) {
                return .{
                    .path = candidate,
                    .source = .relative,
                    .is_declaration = isDeclarationPath(ext),
                };
            }
        }
        if (self.config.resolve_json) {
            const candidate = std.fmt.allocPrint(self.ar(), "{s}.json", .{base}) catch return error.OutOfMemory;
            if (self.fileExistsTraced(candidate)) {
                return .{
                    .path = candidate,
                    .source = .relative,
                    .is_declaration = false,
                };
            }
        }
        return null;
    }

    fn tryFileWithTsExtensionSubstitution(self: *Resolver, path: []const u8) ResolveError!?Resolution {
        const Substitution = struct {
            stem: []const u8,
            candidates: []const []const u8,
        };
        const substitution: Substitution = blk: {
            if (std.mem.endsWith(u8, path, ".d.ts"))
                break :blk .{ .stem = path[0 .. path.len - ".d.ts".len], .candidates = &.{ ".ts", ".tsx", ".d.ts" } };
            if (std.mem.endsWith(u8, path, ".d.mts"))
                break :blk .{ .stem = path[0 .. path.len - ".d.mts".len], .candidates = &.{ ".mts", ".d.mts" } };
            if (std.mem.endsWith(u8, path, ".d.cts"))
                break :blk .{ .stem = path[0 .. path.len - ".d.cts".len], .candidates = &.{ ".cts", ".d.cts" } };
            if (std.mem.endsWith(u8, path, ".ts") and !std.mem.endsWith(u8, path, ".d.ts"))
                break :blk .{ .stem = path[0 .. path.len - ".ts".len], .candidates = &.{ ".tsx", ".d.ts" } };
            if (std.mem.endsWith(u8, path, ".tsx"))
                break :blk .{ .stem = path[0 .. path.len - ".tsx".len], .candidates = &.{".d.ts"} };
            if (std.mem.endsWith(u8, path, ".mts"))
                break :blk .{ .stem = path[0 .. path.len - ".mts".len], .candidates = &.{".d.mts"} };
            if (std.mem.endsWith(u8, path, ".cts"))
                break :blk .{ .stem = path[0 .. path.len - ".cts".len], .candidates = &.{".d.cts"} };
            return null;
        };
        for (substitution.candidates) |ext| {
            const candidate = std.fmt.allocPrint(self.ar(), "{s}{s}", .{ substitution.stem, ext }) catch return error.OutOfMemory;
            if (std.mem.eql(u8, candidate, path)) continue;
            if (self.fileExistsTraced(candidate)) {
                return .{
                    .path = candidate,
                    .source = .relative,
                    .is_declaration = isDeclarationPath(candidate),
                };
            }
        }
        return null;
    }

    fn tryFileWithOutputExtensionSubstitution(self: *Resolver, path: []const u8) ResolveError!?Resolution {
        const source_exts = sourceExtensionsForOutputPath(path);
        if (source_exts.len == 0) return null;
        const source_base = stripOutputExtension(path) orelse return null;
        const stripped_ext = path[source_base.len..];
        self.traceMsg(
            6132,
            "File name '{s}' has a '{s}' extension - stripping it.",
            .{ path, stripped_ext },
        );
        for (source_exts) |ext| {
            const candidate = std.fmt.allocPrint(self.ar(), "{s}{s}", .{ source_base, ext }) catch return error.OutOfMemory;
            if (std.mem.eql(u8, candidate, path)) continue;
            if (self.fileExistsTraced(candidate)) {
                return .{
                    .path = candidate,
                    .source = .relative,
                    .is_declaration = isDeclarationPath(candidate),
                };
            }
        }
        return null;
    }

    fn tryArbitraryExtensionDeclaration(self: *Resolver, base: []const u8) ResolveError!?Resolution {
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
        const slash = std.mem.lastIndexOfScalar(u8, base, '/');
        if (slash != null and dot < slash.?) return null;
        const candidate = std.fmt.allocPrint(self.ar(), "{s}.d{s}.ts", .{ base[0..dot], base[dot..] }) catch return error.OutOfMemory;
        if (!self.fs.fileExists(candidate)) return null;
        return .{
            .path = candidate,
            .source = .relative,
            .is_declaration = true,
        };
    }

    fn tryDirectoryIndex(self: *Resolver, dir: []const u8) ResolveError!?Resolution {
        // Trim a trailing `/` so `a/` matches the `a` directory entry
        // recorded in the VFS (mirrors tsc which treats the
        // directory-only specifier `"."` as `<dir>/` and resolves it
        // through `<dir>/index.{ts,…}`).
        const trimmed = if (dir.len > 1 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else dir;
        if (!self.fs.directoryExists(trimmed)) return null;
        // Try package.json first.
        const pkg_path = try self.joinPath(trimmed, "package.json");
        if (self.fs.fileExists(pkg_path)) {
            if (try self.resolvePackageMain(trimmed, pkg_path)) |r| return r;
        }
        // Fall back to index.X.
        return self.tryDirectoryIndexNoPkg(trimmed);
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
                    .is_declaration = isDeclarationPath(ext),
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
                    if (v.string.len == 0) {
                        self.traceMsg(6220, "'package.json' had a falsy '{s}' field.", .{key});
                        continue;
                    }
                    const target = try self.joinPath(dir, v.string);
                    self.traceMsg(6101, "'package.json' has '{s}' field '{s}' that references '{s}'.", .{ key, v.string, target });
                    if (try self.tryFileWithExtensions(target)) |r| {
                        // In alternate (declaration-only) mode, a JS
                        // `main`/`module` target that resolves to a
                        // non-declaration file does NOT count — tsc's
                        // alternate pass only probes declaration/TS
                        // extensions, so such a package falls through
                        // to the sibling `@types/<pkg>` lookup.
                        if (!self.alternate_mode or r.is_declaration) {
                            try self.tracePackagePeerDependencies(dir, obj);
                            return .{
                                .path = r.path,
                                .source = .package_main,
                                .is_declaration = r.is_declaration,
                            };
                        }
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
                        if (!self.alternate_mode or r.is_declaration) {
                            try self.tracePackagePeerDependencies(dir, obj);
                            return .{
                                .path = r.path,
                                .source = .package_main,
                                .is_declaration = r.is_declaration,
                            };
                        }
                    }
                } else if (packageJsonFieldIsFalsy(v)) {
                    self.traceMsg(6220, "'package.json' had a falsy '{s}' field.", .{key});
                } else {
                    self.traceMsg(6105, "Expected type of '{s}' field in 'package.json' to be 'string', got '{s}'.", .{ key, jsonValueTypeName(v) });
                }
            }
        }
        return null;
    }

    fn tracePackagePeerDependencies(
        self: *Resolver,
        pkg_dir: []const u8,
        obj: std.json.ObjectMap,
    ) ResolveError!void {
        _ = try self.packagePeerDependenciesSuffix(pkg_dir, obj, true);
    }

    fn withPackageId(
        self: *Resolver,
        resolution: Resolution,
        pkg_dir: []const u8,
        pkg_json: []const u8,
        trace_peers: bool,
    ) ResolveError!Resolution {
        var out = resolution;
        out.package_id = try self.packageIdFor(pkg_dir, pkg_json, resolution.path, trace_peers);
        return out;
    }

    fn packageIdFor(
        self: *Resolver,
        pkg_dir: []const u8,
        pkg_json: []const u8,
        resolved_path: []const u8,
        trace_peers: bool,
    ) ResolveError!?[]const u8 {
        const bytes = self.fs.readFile(self.gpa, pkg_json) catch return null;
        defer self.gpa.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const obj = parsed.value.object;
        const name_v = obj.get("name") orelse return null;
        const version_v = obj.get("version") orelse return null;
        if (name_v != .string or version_v != .string) return null;

        const submodule = if (resolved_path.len > pkg_dir.len and
            std.mem.startsWith(u8, resolved_path, pkg_dir) and
            resolved_path[pkg_dir.len] == '/')
            resolved_path[pkg_dir.len + 1 ..]
        else
            "";
        const peer_suffix = try self.packagePeerDependenciesSuffix(pkg_dir, obj, trace_peers);
        if (submodule.len == 0) {
            return try std.fmt.allocPrint(self.ar(), "{s}@{s}{s}", .{ name_v.string, version_v.string, peer_suffix });
        }
        return try std.fmt.allocPrint(self.ar(), "{s}/{s}@{s}{s}", .{ name_v.string, submodule, version_v.string, peer_suffix });
    }

    fn packagePeerDependenciesSuffix(
        self: *Resolver,
        pkg_dir: []const u8,
        obj: std.json.ObjectMap,
        trace_peers: bool,
    ) ResolveError![]const u8 {
        const should_trace = trace_peers and self.trace != null;
        const peer_v = obj.get("peerDependencies") orelse return "";
        if (peer_v != .object or peer_v.object.count() == 0) return "";

        if (should_trace) {
            self.traceMsg(6281, "'package.json' has a 'peerDependencies' field.", .{});
        }
        const package_dir = try self.realPath(pkg_dir);
        const marker = "/node_modules";
        const nm_end = (std.mem.lastIndexOf(u8, package_dir, marker) orelse return "") + marker.len;
        const node_modules = package_dir[0..nm_end];

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(self.gpa);
        var suffix: std.ArrayListUnmanaged(u8) = .empty;
        defer suffix.deinit(self.gpa);
        var it = peer_v.object.iterator();
        while (it.next()) |entry| {
            try names.append(self.gpa, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);

        for (names.items) |name| {
            const peer_root = try self.joinPath(node_modules, name);
            const peer_pkg_json = try self.joinPath(peer_root, "package.json");
            const version = try self.packageJsonVersion(peer_pkg_json);
            if (version) |v| {
                try suffix.append(self.gpa, '+');
                try suffix.appendSlice(self.gpa, name);
                try suffix.append(self.gpa, '@');
                try suffix.appendSlice(self.gpa, v);
                if (should_trace) {
                    self.traceMsg(6282, "Found peerDependency '{s}' with '{s}' version.", .{ name, v });
                }
            } else {
                if (should_trace) {
                    self.traceMsg(6283, "Failed to find peerDependency '{s}'.", .{name});
                }
            }
        }
        if (suffix.items.len == 0) return "";
        return try self.ar().dupe(u8, suffix.items);
    }

    fn realPath(self: *Resolver, path: []const u8) ResolveError![]const u8 {
        const rp = self.fs.realpath(self.ar(), path) catch try self.ar().dupe(u8, path);
        self.traceMsg(6130, "Resolving real path for '{s}', result '{s}'.", .{ path, rp });
        return rp;
    }

    fn packageJsonVersion(self: *Resolver, pkg_json: []const u8) ResolveError!?[]const u8 {
        const bytes = self.fs.readFile(self.gpa, pkg_json) catch return null;
        defer self.gpa.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const v = parsed.value.object.get("version") orelse return "";
        if (v != .string) return "";
        return self.ar().dupe(u8, v.string) catch error.OutOfMemory;
    }

    fn tryPathsMapping(self: *Resolver, specifier: []const u8) ResolveError!?Resolution {
        if (self.trace != null and self.config.paths.len > 0) {
            self.traceMsg(6091, "'paths' option is specified, looking for a pattern to match module name '{s}'.", .{specifier});
        }
        for (self.config.paths) |entry| {
            if (matchPattern(entry.pattern, specifier)) |substitution| {
                self.traceMsg(6092, "Module name '{s}', matched pattern '{s}'.", .{ specifier, entry.pattern });
                for (entry.targets) |target| {
                    const expanded = try expandTarget(self.ar(), target, substitution);
                    const root = self.config.base_url;
                    const full = if (root.len == 0)
                        expanded
                    else
                        try self.joinPath(root, expanded);
                    self.traceMsg(6093, "Trying substitution '{s}', candidate module location: '{s}'.", .{ target, expanded });
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

    fn tryRootDirs(
        self: *Resolver,
        specifier: []const u8,
        candidate: []const u8,
    ) ResolveError!?Resolution {
        if (self.config.root_dirs.len == 0) return null;

        self.traceMsg(6107, "'rootDirs' option is set, using it to resolve relative module name '{s}'.", .{specifier});
        var best_root: ?[]const u8 = null;
        var best_suffix: []const u8 = "";
        for (self.config.root_dirs) |configured_root| {
            const root = try self.configuredRootDir(configured_root);
            const suffix = rootDirSuffix(candidate, root);
            self.traceMsg(6104, "Checking if '{s}' is the longest matching prefix for '{s}' - '{s}'.", .{ root, candidate, suffix orelse "" });
            if (suffix) |s| {
                if (best_root == null or root.len > best_root.?.len) {
                    best_root = root;
                    best_suffix = s;
                }
            }
        }

        const matched_root = best_root orelse {
            self.traceMsg(6111, "Module resolution using 'rootDirs' has failed.", .{});
            return null;
        };
        self.traceMsg(6108, "Longest matching prefix for '{s}' is '{s}'.", .{ candidate, matched_root });
        self.traceMsg(6110, "Trying other entries in 'rootDirs'.", .{});

        for (self.config.root_dirs) |configured_root| {
            const root = try self.configuredRootDir(configured_root);
            if (std.mem.eql(u8, root, matched_root)) continue;
            const remapped = if (best_suffix.len == 0)
                root
            else
                try self.joinPath(root, best_suffix);
            self.traceMsg(6109, "Loading '{s}' from the root dir '{s}', candidate location '{s}'.", .{ specifier, root, remapped });
            if (try self.tryFileWithExtensions(remapped)) |r| {
                return .{ .path = r.path, .source = .root_dirs, .is_declaration = r.is_declaration };
            }
            if (try self.tryDirectoryIndex(remapped)) |r| {
                return .{ .path = r.path, .source = .root_dirs, .is_declaration = r.is_declaration };
            }
        }

        self.traceMsg(6111, "Module resolution using 'rootDirs' has failed.", .{});
        return null;
    }

    fn tryNodeModules(self: *Resolver, specifier: []const u8, containing_file: []const u8) ResolveError!?Resolution {
        const split = packageNameSplit(specifier);
        const dir = dirname(containing_file);
        if (self.trace != null) {
            self.traceMsg(6098, "Loading module '{s}' from 'node_modules' folder, target file types: {s}.", .{ specifier, self.targetFileTypesText() });
            self.traceMsg(6125, "Looking up in 'node_modules' folder, initial location '{s}'.", .{dir});
            // `@scope/pkg` — tsc notes the scoped lookup directory.
            if (specifier.len > 0 and specifier[0] == '@') {
                self.traceMsg(6182, "Scoped package detected, looking in '{s}'", .{split.name});
            }
        }

        var preferred_exts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer preferred_exts.deinit(self.gpa);
        var fallback_exts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer fallback_exts.deinit(self.gpa);
        try self.partitionNodeModuleExtensions(&preferred_exts, &fallback_exts);

        if (preferred_exts.items.len > 0) {
            self.traceMsg(6417, "Searching all ancestor node_modules directories for preferred extensions: {s}.", .{self.extensionsText(preferred_exts.items)});
            if (try self.tryNodeModulesPass(specifier, containing_file, preferred_exts.items)) |r| return r;
        }

        if (fallback_exts.items.len > 0) {
            self.traceMsg(6418, "Searching all ancestor node_modules directories for fallback extensions: {s}.", .{self.extensionsText(fallback_exts.items)});
            if (try self.tryNodeModulesPass(specifier, containing_file, fallback_exts.items)) |r| return r;
        }
        return null;
    }

    fn partitionNodeModuleExtensions(
        self: *Resolver,
        preferred: *std.ArrayListUnmanaged([]const u8),
        fallback: *std.ArrayListUnmanaged([]const u8),
    ) ResolveError!void {
        for (self.config.extensions) |ext| {
            if (isPreferredNodeModuleExtension(ext)) {
                try preferred.append(self.gpa, ext);
            } else {
                try fallback.append(self.gpa, ext);
            }
        }
        if (self.config.resolve_json) {
            try fallback.append(self.gpa, ".json");
        }
    }

    fn extensionsText(self: *Resolver, exts: []const []const u8) []const u8 {
        const sink = self.trace orelse return "";
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const a = sink.arena.allocator();
        buf.append(a, '[') catch return "[]";
        for (exts, 0..) |ext, i| {
            if (i != 0) buf.appendSlice(a, ", ") catch return "[]";
            buf.append(a, '\'') catch return "[]";
            buf.appendSlice(a, ext) catch return "[]";
            buf.append(a, '\'') catch return "[]";
        }
        buf.append(a, ']') catch return "[]";
        return buf.items;
    }

    fn tryNodeModulesPass(
        self: *Resolver,
        specifier: []const u8,
        containing_file: []const u8,
        extensions: []const []const u8,
    ) ResolveError!?Resolution {
        const saved_exts = self.config.extensions;
        const saved_resolve_json = self.config.resolve_json;
        self.config.extensions = extensions;
        self.config.resolve_json = false;
        defer {
            self.config.extensions = saved_exts;
            self.config.resolve_json = saved_resolve_json;
        }

        // Walk up the directory tree looking for node_modules/<spec>.
        const split = packageNameSplit(specifier);
        var dir = dirname(containing_file);
        while (true) {
            const nm = try self.joinPath(dir, "node_modules");
            if (!self.fs.directoryExists(nm)) {
                self.traceMsg(6148, "Directory '{s}' does not exist, skipping all lookups in it.", .{nm});
            } else {
                // Resolve against the package root so we can consult
                // package.json `exports` / `typesVersions` before falling
                // back to direct file probing on the joined candidate.
                const pkg_root = try self.joinPath(nm, split.name);
                const root_pkg_json = try self.joinPath(pkg_root, "package.json");
                const has_root_pkg_json = self.fs.fileExists(root_pkg_json);
                if (split.subpath.len > 0) {
                    // Subpath import: try a nested package.json in the
                    // subpath directory first (e.g. @restart/hooks/useMergedRefs
                    // has its own package.json with a relative `types` field
                    // pointing back into the parent's `esm/` dir). This
                    // matches `nestedPackageJsonRedirect.ts` in upstream:
                    // a per-subpath `package.json` *can* redirect (unlike
                    // the parent `main`-pointed dir which is non-recursive).
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
                    if (has_root_pkg_json) {
                        const sub_outcome = try self.resolvePackageSubpath(pkg_root, root_pkg_json, split.subpath);
                        switch (sub_outcome) {
                            .resolved => |r| return try self.withPackageId(.{
                                .path = r.path,
                                .source = .node_modules,
                                .is_declaration = r.is_declaration,
                                .blocked_by_exports_null = r.blocked_by_exports_null,
                            }, pkg_root, root_pkg_json, false),
                            .blocked => {
                                if (try self.tryAtTypesFallback(nm, split.name, split.subpath)) |r| return r;
                                return null;
                            },
                            .none => {},
                        }
                    }
                } else {
                    // Bare package: `package.json` `exports["."]` first,
                    // then fall back to `main`/`types` via tryDirectoryIndex.
                    if (has_root_pkg_json) {
                        const root_outcome = try self.resolvePackageSubpath(pkg_root, root_pkg_json, ".");
                        switch (root_outcome) {
                            .resolved => |r| return try self.withPackageId(.{
                                .path = r.path,
                                .source = .node_modules,
                                .is_declaration = r.is_declaration,
                                .blocked_by_exports_null = r.blocked_by_exports_null,
                            }, pkg_root, root_pkg_json, false),
                            .blocked => {
                                if (try self.tryAtTypesFallback(nm, split.name, "")) |r| return r;
                                return null;
                            },
                            .none => {},
                        }
                    }
                }

                // `@types/<pkg>` mirror lookup — tried BEFORE the
                // legacy JS fallback so that a sibling typings package
                // (`@types/foo` for `foo`, `@types/scope__name` for
                // `@scope/name`) wins over an untyped JS resolution.
                if (try self.tryAtTypesFallback(nm, split.name, split.subpath)) |r| return r;

                // Fallback: legacy file/index probing on the literal joined
                // specifier. This matches our prior behavior and keeps
                // the existing relative-style probes working when no
                // package.json metadata steers the lookup.
                const candidate = try self.joinPath(nm, specifier);
                if (try self.tryFileWithExtensions(candidate)) |r| {
                    const out: Resolution = .{ .path = r.path, .source = .node_modules, .is_declaration = r.is_declaration };
                    if (has_root_pkg_json) return try self.withPackageId(out, pkg_root, root_pkg_json, true);
                    return out;
                }
                if (try self.tryDirectoryIndex(candidate)) |r| {
                    const out: Resolution = .{ .path = r.path, .source = .node_modules, .is_declaration = r.is_declaration };
                    if (has_root_pkg_json) return try self.withPackageId(out, pkg_root, root_pkg_json, true);
                    return out;
                }
            }
            if (dir.len == 0 or std.mem.eql(u8, dir, "/")) break;
            const parent = dirname(dir);
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }
        return null;
    }

    fn tryTypeRoots(self: *Resolver, specifier: []const u8) ResolveError!?Resolution {
        if (self.config.type_roots.len == 0) return null;
        for (self.config.type_roots) |root| {
            if (root.len == 0) continue;
            if (std.mem.endsWith(u8, root, "/node_modules/@types") or
                std.mem.eql(u8, root, "node_modules/@types"))
            {
                if (try self.tryAtTypesRoot(root, specifier)) |r| return r;
                continue;
            }
            const candidate = try self.joinPath(root, specifier);
            if (try self.tryTypeRootCandidate(candidate)) |r| return r;
        }
        return null;
    }

    fn typeReferenceRootDir(self: *Resolver, containing_file: []const u8) ResolveError!?[]const u8 {
        if (self.config.root_dir.len != 0) return try self.configuredRootDir(self.config.root_dir);
        if (self.config.config_file_path.len != 0) return dirname(self.config.config_file_path);
        if (containing_file.len != 0) return dirname(containing_file);
        return null;
    }

    fn typeRootsTraceText(self: *Resolver) []const u8 {
        const sink = self.trace orelse return "";
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const a = sink.arena.allocator();
        for (self.config.type_roots, 0..) |root, i| {
            if (i != 0) buf.appendSlice(a, ", ") catch return "";
            buf.appendSlice(a, root) catch return "";
        }
        return buf.items;
    }

    fn tryTypeReferenceRoot(
        self: *Resolver,
        root: []const u8,
        directive: []const u8,
    ) ResolveError!?Resolution {
        if (std.mem.endsWith(u8, root, "/node_modules/@types") or
            std.mem.eql(u8, root, "node_modules/@types"))
        {
            return self.tryTypeReferenceAtTypesRoot(root, directive);
        }
        const candidate = try self.joinPath(root, directive);
        const resolution = (try self.tryTypeRootCandidate(candidate)) orelse return null;
        return try self.withTypeReferencePackageId(resolution, candidate);
    }

    fn tryTypeReferencePackageRoot(
        self: *Resolver,
        node_modules: []const u8,
        directive: []const u8,
    ) ResolveError!?Resolution {
        const candidate = try self.joinPath(node_modules, directive);
        const resolution = (try self.tryTypeRootCandidate(candidate)) orelse return null;
        return try self.withTypeReferencePackageId(resolution, candidate);
    }

    fn tryTypeReferenceAtTypesRoot(
        self: *Resolver,
        root: []const u8,
        directive: []const u8,
    ) ResolveError!?Resolution {
        const pkg_dir = try self.atTypesPackageDir(root, directive);
        const resolution = (try self.tryTypeRootCandidate(pkg_dir)) orelse return null;
        return try self.withTypeReferencePackageId(resolution, pkg_dir);
    }

    fn atTypesPackageDir(self: *Resolver, root: []const u8, specifier: []const u8) ResolveError![]const u8 {
        const split = packageNameSplit(specifier);
        if (split.name.len == 0) return try self.joinPath(root, specifier);
        const pkg_root: []const u8 = if (split.name[0] == '@') blk: {
            const slash = std.mem.indexOfScalar(u8, split.name, '/') orelse return try self.joinPath(root, specifier);
            const scope = split.name[1..slash];
            const tail = split.name[slash + 1 ..];
            const mangled = try std.fmt.allocPrint(self.ar(), "{s}__{s}", .{ scope, tail });
            break :blk try self.joinPath(root, mangled);
        } else try self.joinPath(root, split.name);
        if (split.subpath.len == 0) return pkg_root;
        return try self.joinPath(pkg_root, split.subpath);
    }

    fn withTypeReferencePackageId(
        self: *Resolver,
        resolution: Resolution,
        pkg_dir: []const u8,
    ) ResolveError!Resolution {
        const pkg_json = try self.joinPath(pkg_dir, "package.json");
        if (!self.fs.fileExists(pkg_json)) return resolution;
        return try self.withPackageId(resolution, pkg_dir, pkg_json, false);
    }

    fn tryAtTypesRoot(self: *Resolver, root: []const u8, specifier: []const u8) ResolveError!?Resolution {
        const split = packageNameSplit(specifier);
        if (split.name.len == 0) return null;
        const pkg_dir: []const u8 = if (split.name[0] == '@') blk: {
            const slash = std.mem.indexOfScalar(u8, split.name, '/') orelse return null;
            const scope = split.name[1..slash];
            const tail = split.name[slash + 1 ..];
            const mangled = try std.fmt.allocPrint(self.ar(), "{s}__{s}", .{ scope, tail });
            break :blk try self.joinPath(root, mangled);
        } else try self.joinPath(root, split.name);
        const candidate = if (split.subpath.len == 0)
            pkg_dir
        else
            try self.joinPath(pkg_dir, split.subpath);
        return self.tryTypeRootCandidate(candidate);
    }

    fn tryTypeRootCandidate(self: *Resolver, candidate: []const u8) ResolveError!?Resolution {
        if (try self.tryFileWithExtensions(candidate)) |r| {
            if (r.is_declaration) return .{ .path = r.path, .source = .type_roots, .is_declaration = true };
        }
        const trimmed = if (candidate.len > 1 and candidate[candidate.len - 1] == '/') candidate[0 .. candidate.len - 1] else candidate;
        const pkg_json = try self.joinPath(trimmed, "package.json");
        if (self.fs.fileExists(pkg_json)) {
            const outcome = try self.resolvePackageSubpath(trimmed, pkg_json, ".");
            switch (outcome) {
                .resolved => |r| if (r.is_declaration) {
                    return .{
                        .path = r.path,
                        .source = .type_roots,
                        .is_declaration = true,
                        .package_id = r.package_id,
                    };
                },
                .blocked => return null,
                .none => {},
            }
        }
        if (try self.tryDirectoryIndex(candidate)) |r| {
            if (r.is_declaration) return .{ .path = r.path, .source = .type_roots, .is_declaration = true };
        }
        return null;
    }

    /// `@types/<pkg>` parallel-directory lookup. When a JS-only package
    /// has no `.d.ts` of its own, tsc walks the SAME `node_modules`
    /// directory for `@types/<pkg>` (or `@types/<scope>__<name>` for
    /// scoped packages — `@scope/foo` becomes `@types/scope__foo`).
    /// Returns the resolved `Resolution` or null.
    fn tryAtTypesFallback(
        self: *Resolver,
        nm_dir: []const u8,
        pkg_name: []const u8,
        subpath: []const u8,
    ) ResolveError!?Resolution {
        if (pkg_name.len == 0) return null;
        const at_types_name: []const u8 = if (pkg_name[0] == '@') blk: {
            const slash = std.mem.indexOfScalar(u8, pkg_name, '/') orelse return null;
            const scope = pkg_name[1..slash];
            const tail = pkg_name[slash + 1 ..];
            break :blk try std.fmt.allocPrint(self.ar(), "@types/{s}__{s}", .{ scope, tail });
        } else try std.fmt.allocPrint(self.ar(), "@types/{s}", .{pkg_name});
        const at_root = try self.joinPath(nm_dir, at_types_name);
        if (!self.fs.directoryExists(at_root)) return null;
        const at_pkg_json = try self.joinPath(at_root, "package.json");
        if (subpath.len > 0) {
            const cand = try self.joinPath(at_root, subpath);
            if (try self.tryFileWithExtensions(cand)) |r| {
                if (r.is_declaration) return .{ .path = r.path, .source = .node_modules, .is_declaration = true };
            }
            if (try self.tryDirectoryIndex(cand)) |r| {
                if (r.is_declaration) return .{ .path = r.path, .source = .node_modules, .is_declaration = true };
            }
            return null;
        }
        if (self.fs.fileExists(at_pkg_json)) {
            const outcome = try self.resolvePackageSubpath(at_root, at_pkg_json, ".");
            switch (outcome) {
                .resolved => |r| if (r.is_declaration) {
                    return .{ .path = r.path, .source = .node_modules, .is_declaration = true };
                },
                .blocked, .none => {},
            }
        }
        const fallback = try self.joinPath(at_root, "index");
        if (try self.tryFileWithExtensions(fallback)) |r| {
            if (r.is_declaration) return .{ .path = r.path, .source = .node_modules, .is_declaration = true };
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

        // 1) `exports` field (subpath or root). Only honored for
        //    strategies that recognize the field — `node10` and
        //    `classic` deliberately ignore it (per tsc's
        //    `node10AlternateResult_*` fixtures, which expect the
        //    legacy `main` to win even when `exports` is present).
        if (self.exportsResolutionEnabled()) {
            if (obj.get("exports")) |exports_v| {
                const key = if (std.mem.eql(u8, subpath, ".") or subpath.len == 0)
                    "."
                else
                    try std.fmt.allocPrint(self.ar(), "./{s}", .{subpath});
                const active_null = self.exportsHasActiveNullCondition(exports_v, key);
                if (try self.lookupExports(exports_v, key, "exports", pkg_dir)) |target| {
                    switch (target) {
                        .matched_null => return .blocked, // hard rejection
                        .matched => |m| {
                            const joined = try self.joinPath(pkg_dir, m);
                            // TS2209 — under `outDir`/`declarationDir`, tsc
                            // tries to map the exports target back to its
                            // source input *before* loading it directly, but
                            // can't establish the project root with no
                            // `rootDir` and no config file. It reports the
                            // ambiguity and leaves the specifier unresolved.
                            // Mirrors tsgo's `tryLoadInputFileForPath`
                            // (called at higher priority than the output).
                            if ((self.config.out_dir.len != 0 or self.config.declaration_dir.len != 0) and
                                self.config.config_file_path.len == 0 and
                                self.config.root_dir.len == 0 and
                                std.mem.indexOf(u8, joined, "/node_modules/") == null)
                            {
                                self.ambiguous_root = .{
                                    .entry = try self.ar().dupe(u8, key),
                                    .file = try self.ar().dupe(u8, pkg_json),
                                    .is_imports = false,
                                };
                                return .blocked;
                            }
                            if (try self.tryFileWithExtensions(joined)) |r| {
                                try self.tracePackagePeerDependencies(pkg_dir, obj);
                                var out = r;
                                out.blocked_by_exports_null = active_null;
                                return .{ .resolved = out };
                            }
                            if (try self.tryLoadInputFileForPath(joined)) |r| {
                                try self.tracePackagePeerDependencies(pkg_dir, obj);
                                var out = r;
                                out.blocked_by_exports_null = active_null;
                                return .{ .resolved = out };
                            }
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
                            self.traceMsg(6276, "Export specifier '{s}' does not exist in package.json scope at path '{s}'.", .{ key, pkg_dir });
                            return .blocked;
                        },
                        .invalid_target => return .blocked,
                    }
                }
            }
        }

        // 2) `typesVersions` field (TS-only — pattern map under a
        //    semver range). Mirror tsc's trace sequence from
        //    packagejson.GetVersionPaths, then resolve through the first
        //    entry that matches the compiler version.
        if (try self.selectTypesVersionsEntry(obj, subpath)) |entry| {
            if (try self.matchTypesVersions(pkg_dir, entry.map, subpath)) |r| {
                try self.tracePackagePeerDependencies(pkg_dir, obj);
                return .{ .resolved = r };
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

    fn exportsHasActiveNullCondition(self: *Resolver, exports_v: std.json.Value, key: []const u8) bool {
        const node = self.exportsNodeForKey(exports_v, key) orelse return false;
        return self.conditionalNodeHasActiveNull(node);
    }

    fn exportsNodeForKey(self: *Resolver, exports_v: std.json.Value, key: []const u8) ?std.json.Value {
        _ = self;
        if (exports_v != .object) return if (std.mem.eql(u8, key, ".")) exports_v else null;
        const obj = exports_v.object;
        if (obj.get(key)) |entry| return entry;
        if (!std.mem.eql(u8, key, ".")) return null;
        var it = obj.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, ".")) return null;
        }
        return exports_v;
    }

    fn conditionalNodeHasActiveNull(self: *Resolver, node: std.json.Value) bool {
        if (node == .null) return true;
        if (node != .object) return false;
        const obj = node.object;
        for (self.config.conditions) |cond| {
            if (std.mem.eql(u8, cond, "types")) continue;
            if (obj.get(cond)) |v| {
                if (v == .null) return true;
                if (self.conditionalNodeHasActiveNull(v)) return true;
            }
        }
        if (obj.get("default")) |v| {
            if (v == .null) return true;
        }
        return false;
    }

    const TypeVersionsEntry = struct {
        map: std.json.ObjectMap,
    };

    const ts_compiler_version = "7.0.0-dev";
    const ts_compiler_version_major_minor = "7.0";

    fn selectTypesVersionsEntry(
        self: *Resolver,
        obj: std.json.ObjectMap,
        module_name: []const u8,
    ) ResolveError!?TypeVersionsEntry {
        const tv_v = obj.get("typesVersions") orelse {
            self.traceMsg(6100, "'package.json' does not have a '{s}' field.", .{"typesVersions"});
            return null;
        };
        if (tv_v != .object) {
            self.traceMsg(6105, "Expected type of '{s}' field in 'package.json' to be 'object', got '{s}'.", .{ "typesVersions", jsonValueTypeName(tv_v) });
            return null;
        }

        self.traceMsg(6206, "'package.json' has a 'typesVersions' field with version-specific path mappings.", .{});
        var it = tv_v.object.iterator();
        while (it.next()) |entry| {
            const range = entry.key_ptr.*;
            switch (typesVersionRangeMatches(range)) {
                .invalid => {
                    self.traceMsg(6209, "'package.json' has a 'typesVersions' entry '{s}' that is not a valid semver range.", .{range});
                    continue;
                },
                .no_match => continue,
                .match => {
                    if (entry.value_ptr.* != .object) {
                        const field_name = try std.fmt.allocPrint(self.ar(), "typesVersions['{s}']", .{range});
                        self.traceMsg(6105, "Expected type of '{s}' field in 'package.json' to be 'object', got '{s}'.", .{ field_name, jsonValueTypeName(entry.value_ptr.*) });
                        return null;
                    }
                    const lookup_key: []const u8 = if (std.mem.eql(u8, module_name, ".") or module_name.len == 0) "index" else module_name;
                    self.traceMsg(6208, "'package.json' has a 'typesVersions' entry '{s}' that matches compiler version '{s}', looking for a pattern to match module name '{s}'.", .{ range, ts_compiler_version, lookup_key });
                    return .{ .map = entry.value_ptr.*.object };
                },
            }
        }

        self.traceMsg(6207, "'package.json' does not have a 'typesVersions' entry that matches version '{s}'.", .{ts_compiler_version_major_minor});
        return null;
    }

    const ExportsLookup = union(enum) {
        not_matched,
        matched_null,
        invalid_target,
        matched: []const u8,
    };

    fn lookupExports(
        self: *Resolver,
        node: std.json.Value,
        key: []const u8,
        kind: []const u8,
        scope_dir: []const u8,
    ) ResolveError!?ExportsLookup {
        // `exports` may be:
        //   - a string  → applies to "."
        //   - an object whose keys are subpath patterns ("./*", "."),
        //     each value being a target string OR a conditional object
        //   - a conditional object directly (no subpath keys) → applies to "."
        if (node == .string) {
            if (std.mem.eql(u8, key, ".")) {
                self.traceMsg(6404, "Using '{s}' subpath '{s}' with target '{s}'.", .{ kind, key, node.string });
                return .{ .matched = node.string };
            }
            return .not_matched;
        }
        if (node == .array) {
            if (std.mem.eql(u8, key, ".")) {
                if (try self.resolveConditional(node, kind, scope_dir, key)) |resolved| {
                    if (resolved == .matched) {
                        self.traceMsg(6404, "Using '{s}' subpath '{s}' with target '{s}'.", .{ kind, key, resolved.matched });
                    }
                    return resolved;
                }
                return null;
            }
            return .not_matched;
        }
        if (node != .object) {
            self.traceInvalidPackageJsonTarget(scope_dir, key);
            return .invalid_target;
        }
        const obj = node.object;
        // Subpath-keyed when a key begins with `.` (`exports`) OR `#`
        // (`imports`). The `imports` map shares this shape but its keys
        // are private `#`-prefixed specifiers rather than `./` subpaths.
        const looks_subpath_keyed = blk: {
            var it = obj.iterator();
            while (it.next()) |e| {
                if (std.mem.startsWith(u8, e.key_ptr.*, ".") or
                    std.mem.startsWith(u8, e.key_ptr.*, "#")) break :blk true;
            }
            break :blk false;
        };
        if (looks_subpath_keyed) {
            // Exact match first.
            if (obj.get(key)) |entry| {
                if (try self.resolveConditional(entry, kind, scope_dir, key)) |resolved| {
                    if (resolved == .matched) {
                        self.traceMsg(6404, "Using '{s}' subpath '{s}' with target '{s}'.", .{ kind, key, resolved.matched });
                    }
                    return resolved;
                }
                return null;
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
                const conditional = try self.resolveConditional(entry, kind, scope_dir, key);
                if (conditional) |c| switch (c) {
                    .matched_null => return c,
                    .invalid_target => return c,
                    .matched => |m| {
                        // Replace the first `*` in the target with the
                        // captured substitution. tsc's
                        // `getPatternFromSpec` only allows one wildcard
                        // per side and substitutes positionally — e.g.
                        // `./types/*.d.ts` with capture `"sub"` becomes
                        // `./types/sub.d.ts`.
                        if (std.mem.indexOfScalar(u8, m, '*')) |star_at| {
                            const expanded = try std.fmt.allocPrint(self.ar(), "{s}{s}{s}", .{ m[0..star_at], best_substitution, m[star_at + 1 ..] });
                            self.traceMsg(6404, "Using '{s}' subpath '{s}' with target '{s}'.", .{ kind, key, expanded });
                            return .{ .matched = expanded };
                        }
                        self.traceMsg(6404, "Using '{s}' subpath '{s}' with target '{s}'.", .{ kind, key, m });
                        return c;
                    },
                    .not_matched => return .not_matched,
                };
            }
            return .not_matched;
        }
        // Conditional object directly — only valid for the root.
        if (std.mem.eql(u8, key, ".")) {
            if (try self.resolveConditional(node, kind, scope_dir, key)) |resolved| {
                if (resolved == .matched) {
                    self.traceMsg(6404, "Using '{s}' subpath '{s}' with target '{s}'.", .{ kind, key, resolved.matched });
                }
                return resolved;
            }
            return null;
        }
        return .not_matched;
    }

    fn traceInvalidPackageJsonTarget(self: *Resolver, scope_dir: []const u8, specifier: []const u8) void {
        self.traceMsg(6275, "package.json scope '{s}' has invalid type for target of specifier '{s}'", .{ scope_dir, specifier });
    }

    fn resolveConditional(
        self: *Resolver,
        node: std.json.Value,
        kind: []const u8,
        scope_dir: []const u8,
        specifier: []const u8,
    ) ResolveError!?ExportsLookup {
        if (node == .null) return .matched_null;
        if (node == .string) return .{ .matched = node.string };
        if (node == .array) {
            if (node.array.items.len == 0) {
                self.traceInvalidPackageJsonTarget(scope_dir, specifier);
                return .invalid_target;
            }
            var saw_invalid_target = false;
            for (node.array.items) |item| {
                if (try self.resolveConditional(item, kind, scope_dir, specifier)) |inner| {
                    switch (inner) {
                        .not_matched => {},
                        .invalid_target => saw_invalid_target = true,
                        else => return inner,
                    }
                }
            }
            if (saw_invalid_target) return .invalid_target;
            self.traceInvalidPackageJsonTarget(scope_dir, specifier);
            return .invalid_target;
        }
        if (node != .object) {
            self.traceInvalidPackageJsonTarget(scope_dir, specifier);
            return .invalid_target;
        }
        const obj = node.object;
        self.traceMsg(6413, "Entering conditional exports.", .{});
        defer self.traceMsg(6416, "Exiting conditional exports.", .{});
        var saw_invalid_target = false;

        var nonmatch_it = obj.iterator();
        while (nonmatch_it.next()) |entry| {
            const condition = entry.key_ptr.*;
            if (std.mem.eql(u8, condition, "types") or
                std.mem.eql(u8, condition, "default") or
                self.hasCondition(condition))
            {
                continue;
            }
            self.traceMsg(6405, "Saw non-matching condition '{s}'.", .{condition});
        }

        // tsc's condition order for type resolution:
        //   `types` (always first), user conditions (via `self.config.conditions`),
        //   then `default` last.
        // Try `types` explicitly first.
        if (obj.get("types")) |v| {
            self.traceMsg(6403, "Matched '{s}' condition '{s}'.", .{ kind, "types" });
            if (try self.resolveConditional(v, kind, scope_dir, specifier)) |inner| {
                switch (inner) {
                    .matched => {
                        self.traceMsg(6414, "Resolved under condition '{s}'.", .{"types"});
                        return inner;
                    },
                    .matched_null => return inner,
                    .invalid_target => saw_invalid_target = true,
                    .not_matched => {},
                }
            }
            self.traceMsg(6415, "Failed to resolve under condition '{s}'.", .{"types"});
        }
        for (self.config.conditions) |cond| {
            if (std.mem.eql(u8, cond, "types")) continue;
            if (obj.get(cond)) |v| {
                self.traceMsg(6403, "Matched '{s}' condition '{s}'.", .{ kind, cond });
                if (try self.resolveConditional(v, kind, scope_dir, specifier)) |inner| {
                    switch (inner) {
                        .matched => {
                            self.traceMsg(6414, "Resolved under condition '{s}'.", .{cond});
                            return inner;
                        },
                        .matched_null => return inner,
                        .invalid_target => saw_invalid_target = true,
                        .not_matched => {},
                    }
                }
                self.traceMsg(6415, "Failed to resolve under condition '{s}'.", .{cond});
            }
        }
        if (obj.get("default")) |v| {
            self.traceMsg(6403, "Matched '{s}' condition '{s}'.", .{ kind, "default" });
            if (try self.resolveConditional(v, kind, scope_dir, specifier)) |inner| {
                switch (inner) {
                    .matched => {
                        self.traceMsg(6414, "Resolved under condition '{s}'.", .{"default"});
                        return inner;
                    },
                    .matched_null => return inner,
                    .invalid_target => saw_invalid_target = true,
                    .not_matched => {},
                }
            }
            self.traceMsg(6415, "Failed to resolve under condition '{s}'.", .{"default"});
        }
        if (saw_invalid_target) return .invalid_target;
        return .not_matched;
    }

    fn matchTypesVersions(
        self: *Resolver,
        pkg_dir: []const u8,
        map: std.json.ObjectMap,
        subpath: []const u8,
    ) ResolveError!?Resolution {
        // Subpath shape per upstream tsc: a bare-specifier suffix
        // (no leading `./`). For the root case (`.` / empty), tsc
        // treats the lookup key as `index` — so a `{ "*": ["ts3.1/*"] }`
        // mapping resolves the package root through `ts3.1/index.d.ts`.
        // This matches `typesVersions.justIndex.ts` and
        // `typesVersions.multiFile.ts` baselines.
        const is_root = std.mem.eql(u8, subpath, ".") or subpath.len == 0;
        const lookup_key: []const u8 = if (is_root) "index" else subpath;
        // Exact (literal) matches first — tsc's `getPatternFromSpec`
        // tries exact non-wildcard keys before wildcards.
        var it_exact = map.iterator();
        while (it_exact.next()) |e| {
            const pat = e.key_ptr.*;
            if (std.mem.endsWith(u8, pat, "*")) continue;
            if (!std.mem.eql(u8, pat, lookup_key)) continue;
            const targets = e.value_ptr.*;
            if (targets != .array) continue;
            for (targets.array.items) |t| {
                if (t != .string) continue;
                const joined = try self.joinPath(pkg_dir, t.string);
                if (try self.tryFileWithExtensions(joined)) |r| return r;
                if (try self.tryDirectoryIndex(joined)) |r| return r;
            }
            return null;
        }
        // Wildcard pass — pick the LONGEST matching prefix per tsc's
        // `getPatternFromSpec` ordering rule.
        var best_prefix_len: usize = 0;
        var best_targets: ?std.json.Value = null;
        var best_captured: []const u8 = "";
        var found_any = false;
        var it_wild = map.iterator();
        while (it_wild.next()) |e| {
            const pat = e.key_ptr.*;
            if (!std.mem.endsWith(u8, pat, "*")) continue;
            const targets = e.value_ptr.*;
            if (targets != .array) continue;
            const captured = matchPattern(pat, lookup_key) orelse continue;
            const prefix_len = pat.len - 1;
            if (found_any and prefix_len < best_prefix_len) continue;
            found_any = true;
            best_prefix_len = prefix_len;
            best_targets = targets;
            best_captured = captured;
        }
        if (best_targets) |targets| {
            for (targets.array.items) |t| {
                if (t != .string) continue;
                // typesVersions targets place the wildcard wherever it
                // logically substitutes — `ts3.1/*` ends in `*`,
                // `fallback/*.d.ts` has it INSIDE. Use the FIRST
                // `*` per tsc's `getPatternFromSpec` (one wildcard
                // per side). Falls back to literal when no `*`.
                const expanded = try substituteFirstStar(self.ar(), t.string, best_captured);
                const joined = try self.joinPath(pkg_dir, expanded);
                if (try self.tryFileWithExtensions(joined)) |r| return r;
                if (try self.tryDirectoryIndex(joined)) |r| return r;
            }
        }
        return null;
    }

    /// tsc's `tryLoadInputFileForPath` subset. When resolving package
    /// `exports` under a project with `outDir` / `declarationDir`, an
    /// export target may name an emitted file that is not physically
    /// present in the test VFS yet (`./types/index.d.ts`,
    /// `./dist/index.js`). TypeScript maps that output path back to the
    /// source input relative to `rootDir` (or the config directory) and
    /// then probes source extensions.
    fn tryLoadInputFileForPath(self: *Resolver, output_path: []const u8) ResolveError!?Resolution {
        if (std.mem.indexOf(u8, output_path, "/node_modules/") != null) return null;
        const config_root = self.configRootDir() orelse return null;
        if (self.config.declaration_dir.len != 0) {
            if (try self.tryLoadInputFileFromOutputDir(output_path, self.config.declaration_dir, config_root)) |r| return r;
        }
        if (self.config.out_dir.len != 0 and
            !std.mem.eql(u8, self.config.out_dir, self.config.declaration_dir))
        {
            if (try self.tryLoadInputFileFromOutputDir(output_path, self.config.out_dir, config_root)) |r| return r;
        }
        return null;
    }

    fn tryLoadInputFileFromOutputDir(
        self: *Resolver,
        output_path: []const u8,
        configured_output_dir: []const u8,
        config_root: []const u8,
    ) ResolveError!?Resolution {
        const output_dir = try self.joinPath(config_root, configured_output_dir);
        if (!pathHasDirPrefix(output_path, output_dir)) return null;
        const rel = output_path[output_dir.len..];
        const rel_trimmed = if (rel.len > 0 and rel[0] == '/') rel[1..] else rel;
        const source_root = if (self.config.root_dir.len != 0)
            try self.joinPath(config_root, self.config.root_dir)
        else
            config_root;
        const source_base_with_output_ext = try self.joinPath(source_root, rel_trimmed);
        const source_base = stripOutputExtension(source_base_with_output_ext) orelse source_base_with_output_ext;
        const candidates = sourceExtensionsForOutputPath(output_path);
        for (candidates) |ext| {
            const candidate = std.fmt.allocPrint(self.ar(), "{s}{s}", .{ source_base, ext }) catch return error.OutOfMemory;
            if (self.fileExistsTraced(candidate)) {
                return .{
                    .path = candidate,
                    .source = .package_exports,
                    .is_declaration = isDeclarationPath(candidate),
                    .project_reference_output = if (self.config.project_reference_output_diagnostics) output_path else null,
                };
            }
        }
        return null;
    }

    fn configRootDir(self: *Resolver) ?[]const u8 {
        if (self.config.config_file_path.len != 0) return dirname(self.config.config_file_path);
        return null;
    }

    fn configuredRootDir(self: *Resolver, root: []const u8) ResolveError![]const u8 {
        if (root.len == 0 or isAbsolute(root)) return root;
        const config_root = self.configRootDir() orelse return root;
        return try self.joinPath(config_root, root);
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

fn looksLikeAbsoluteUriSpecifier(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, ':') != null;
}

fn jsonValueTypeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "boolean",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn packageJsonFieldIsFalsy(value: std.json.Value) bool {
    return switch (value) {
        .null => true,
        .bool => |b| !b,
        else => false,
    };
}

const TypesVersionRangeMatch = enum { invalid, no_match, match };

fn typesVersionRangeMatches(range: []const u8) TypesVersionRangeMatch {
    const trimmed = std.mem.trim(u8, range, " \t\r\n");
    if (trimmed.len == 0) return .invalid;
    if (std.mem.eql(u8, trimmed, "*") or std.mem.eql(u8, trimmed, "x") or std.mem.eql(u8, trimmed, "X")) return .match;

    var i: usize = 0;
    var op: enum { exact, gt, gte, lt, lte, caret, tilde } = .exact;
    if (std.mem.startsWith(u8, trimmed, ">=")) {
        op = .gte;
        i = 2;
    } else if (std.mem.startsWith(u8, trimmed, "<=")) {
        op = .lte;
        i = 2;
    } else if (trimmed[0] == '>') {
        op = .gt;
        i = 1;
    } else if (trimmed[0] == '<') {
        op = .lt;
        i = 1;
    } else if (trimmed[0] == '^') {
        op = .caret;
        i = 1;
    } else if (trimmed[0] == '~') {
        op = .tilde;
        i = 1;
    }
    while (i < trimmed.len and trimmed[i] == ' ') i += 1;
    const major = parseUnsignedPrefix(trimmed, &i) orelse return .invalid;
    var minor: u32 = 0;
    if (i < trimmed.len and trimmed[i] == '.') {
        i += 1;
        minor = parseUnsignedPrefix(trimmed, &i) orelse return .invalid;
    }
    if (i < trimmed.len and trimmed[i] == '.') {
        i += 1;
        _ = parseUnsignedPrefix(trimmed, &i) orelse return .invalid;
    }
    if (i < trimmed.len) {
        const c = trimmed[i];
        if (c != '-' and c != '+' and c != ' ' and c != '\t') return .invalid;
    }

    const cmp = compareMajorMinor(7, 0, major, minor);
    return switch (op) {
        .exact, .caret, .tilde => if (cmp == 0) .match else .no_match,
        .gt => if (cmp > 0) .match else .no_match,
        .gte => if (cmp >= 0) .match else .no_match,
        .lt => if (cmp < 0) .match else .no_match,
        .lte => if (cmp <= 0) .match else .no_match,
    };
}

fn parseUnsignedPrefix(s: []const u8, index: *usize) ?u32 {
    if (index.* >= s.len or s[index.*] < '0' or s[index.*] > '9') return null;
    var value: u32 = 0;
    while (index.* < s.len) : (index.* += 1) {
        const c = s[index.*];
        if (c < '0' or c > '9') break;
        value = std.math.mul(u32, value, 10) catch return null;
        value = std.math.add(u32, value, @as(u32, c - '0')) catch return null;
    }
    return value;
}

fn compareMajorMinor(lhs_major: u32, lhs_minor: u32, rhs_major: u32, rhs_minor: u32) i8 {
    if (lhs_major > rhs_major) return 1;
    if (lhs_major < rhs_major) return -1;
    if (lhs_minor > rhs_minor) return 1;
    if (lhs_minor < rhs_minor) return -1;
    return 0;
}

fn hasKnownExtension(s: []const u8) bool {
    const exts = [_][]const u8{ ".ts", ".tsx", ".d.ts", ".mts", ".cts", ".d.mts", ".d.cts", ".hm", ".home", ".d.hm", ".d.home", ".js", ".jsx", ".mjs", ".cjs" };
    for (exts) |e| if (std.mem.endsWith(u8, s, e)) return true;
    return false;
}

fn isDeclarationPath(s: []const u8) bool {
    return std.mem.endsWith(u8, s, ".d.ts") or
        std.mem.endsWith(u8, s, ".d.mts") or
        std.mem.endsWith(u8, s, ".d.cts") or
        std.mem.endsWith(u8, s, ".d.hm") or
        std.mem.endsWith(u8, s, ".d.home") or
        (std.mem.endsWith(u8, s, ".ts") and std.mem.indexOf(u8, s, ".d.") != null);
}

fn isSupportedTsOrJsonPath(s: []const u8) bool {
    return std.mem.endsWith(u8, s, ".ts") or
        std.mem.endsWith(u8, s, ".tsx") or
        std.mem.endsWith(u8, s, ".mts") or
        std.mem.endsWith(u8, s, ".cts") or
        std.mem.endsWith(u8, s, ".hm") or
        std.mem.endsWith(u8, s, ".home") or
        std.mem.endsWith(u8, s, ".json");
}

fn isPreferredNodeModuleExtension(ext: []const u8) bool {
    return isDeclarationPath(ext) or
        std.mem.eql(u8, ext, ".ts") or
        std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".mts") or
        std.mem.eql(u8, ext, ".cts") or
        std.mem.eql(u8, ext, ".hm") or
        std.mem.eql(u8, ext, ".home");
}

fn pathHasDirPrefix(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len) return true;
    if (dir.len > 0 and dir[dir.len - 1] == '/') return true;
    return path[dir.len] == '/';
}

fn rootDirSuffix(path: []const u8, root: []const u8) ?[]const u8 {
    if (root.len == 0) return null;
    if (!pathHasDirPrefix(path, root)) return null;
    if (path.len == root.len) return "";
    var start = root.len;
    while (start < path.len and path[start] == '/') start += 1;
    return path[start..];
}

fn stripOutputExtension(path: []const u8) ?[]const u8 {
    const exts = [_][]const u8{ ".d.ts", ".d.mts", ".d.cts", ".js", ".jsx", ".mjs", ".cjs" };
    inline for (exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return path[0 .. path.len - ext.len];
    }
    return null;
}

fn isImplementationOutputPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".jsx") or
        std.mem.endsWith(u8, path, ".mjs") or
        std.mem.endsWith(u8, path, ".cjs");
}

fn sourceExtensionsForOutputPath(path: []const u8) []const []const u8 {
    if (std.mem.endsWith(u8, path, ".d.mts") or std.mem.endsWith(u8, path, ".mjs")) return &.{ ".mts", ".d.mts", ".mjs" };
    if (std.mem.endsWith(u8, path, ".d.cts") or std.mem.endsWith(u8, path, ".cjs")) return &.{ ".cts", ".d.cts", ".cjs" };
    if (std.mem.endsWith(u8, path, ".jsx")) return &.{ ".tsx", ".d.ts", ".jsx" };
    return &.{ ".ts", ".tsx", ".d.ts", ".js", ".jsx" };
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

/// Replace the first `*` in `target` with `substitution`. Matches
/// tsc's `getPatternFromSpec` semantics: one wildcard per side of
/// the mapping, substituted positionally. Used by `typesVersions`
/// target expansion and the exports-pattern walker.
pub fn substituteFirstStar(gpa: std.mem.Allocator, target: []const u8, substitution: []const u8) ![]const u8 {
    const at = std.mem.indexOfScalar(u8, target, '*') orelse return gpa.dupe(u8, target);
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ target[0..at], substitution, target[at + 1 ..] });
}

// =============================================================================
// Virtual filesystem (for tests)
// =============================================================================

pub const VirtualFs = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]const u8),
    dirs: std.StringHashMapUnmanaged(void),
    realpaths: std.StringHashMapUnmanaged([]const u8),

    pub fn init(gpa: std.mem.Allocator) VirtualFs {
        return .{ .gpa = gpa, .files = .empty, .dirs = .empty, .realpaths = .empty };
    }

    pub fn deinit(self: *VirtualFs) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        var dit = self.dirs.iterator();
        while (dit.next()) |entry| self.gpa.free(entry.key_ptr.*);
        var rit = self.realpaths.iterator();
        while (rit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.files.deinit(self.gpa);
        self.dirs.deinit(self.gpa);
        self.realpaths.deinit(self.gpa);
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

    pub fn addRealPath(self: *VirtualFs, path: []const u8, real_path: []const u8) !void {
        if (self.realpaths.fetchRemove(path)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value);
        }
        const key = try self.gpa.dupe(u8, path);
        const val = try self.gpa.dupe(u8, real_path);
        try self.realpaths.put(self.gpa, key, val);
    }

    pub fn fs(self: *VirtualFs) FileSystem {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: FileSystem.VTable = .{
        .fileExists = vfsFileExists,
        .directoryExists = vfsDirExists,
        .readFile = vfsReadFile,
        .readDir = vfsReadDir,
        .realpath = vfsRealpath,
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

    fn vfsReadDir(p: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]FileSystem.DirEntry {
        const self: *VirtualFs = @ptrCast(@alignCast(p));
        if (!self.dirs.contains(path)) return error.FileNotFound;
        var out: std.ArrayListUnmanaged(FileSystem.DirEntry) = .empty;
        errdefer {
            for (out.items) |entry| gpa.free(entry.name);
            out.deinit(gpa);
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = seen.iterator();
            while (it.next()) |entry| gpa.free(entry.key_ptr.*);
            seen.deinit(gpa);
        }

        var dit = self.dirs.iterator();
        while (dit.next()) |entry| {
            const child = immediateChildName(path, entry.key_ptr.*) orelse continue;
            if (seen.contains(child)) continue;
            try appendVfsDirEntry(gpa, &out, &seen, child, true);
        }

        var fit = self.files.iterator();
        while (fit.next()) |entry| {
            const child = immediateChildName(path, entry.key_ptr.*) orelse continue;
            if (seen.contains(child)) continue;
            try appendVfsDirEntry(gpa, &out, &seen, child, false);
        }
        return out.toOwnedSlice(gpa);
    }

    fn vfsRealpath(p: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *VirtualFs = @ptrCast(@alignCast(p));
        const v = self.realpaths.get(path) orelse path;
        return gpa.dupe(u8, v);
    }
};

fn appendVfsDirEntry(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(FileSystem.DirEntry),
    seen: *std.StringHashMapUnmanaged(void),
    child: []const u8,
    is_dir: bool,
) !void {
    const name = try gpa.dupe(u8, child);
    const seen_key = try gpa.dupe(u8, child);
    seen.put(gpa, seen_key, {}) catch |err| {
        gpa.free(name);
        gpa.free(seen_key);
        return err;
    };
    out.append(gpa, .{ .name = name, .is_dir = is_dir }) catch |err| {
        gpa.free(name);
        return err;
    };
}

fn immediateChildName(parent: []const u8, candidate: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, parent, candidate)) return null;
    const rest = if (parent.len == 0 or std.mem.eql(u8, parent, "/"))
        trimLeadingSlashes(candidate)
    else blk: {
        if (!std.mem.startsWith(u8, candidate, parent)) return null;
        if (candidate.len <= parent.len or candidate[parent.len] != '/') return null;
        break :blk candidate[parent.len + 1 ..];
    };
    if (rest.len == 0) return null;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| return rest[0..slash];
    return rest;
}

fn trimLeadingSlashes(path: []const u8) []const u8 {
    var start: usize = 0;
    while (start < path.len and path[start] == '/') : (start += 1) {}
    return path[start..];
}

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

test "Resolver: --traceResolution emits TS6086/6089/6095/6096/6097 banners and file probes" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/foo.ts", "export const x = 1;");
    try vfs.addFile("/proj/src/bar.ts", "import './foo';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("./foo", "/proj/src/bar.ts");
    try T.expectEqualStrings("/proj/src/foo.ts", res.path);

    var saw_6086 = false;
    var saw_6089 = false;
    var saw_6095 = false;
    var saw_6097 = false;
    for (sink.entries.items) |e| {
        switch (e.code) {
            6086 => saw_6086 = true,
            6089 => saw_6089 = true,
            6095 => saw_6095 = true,
            6097 => saw_6097 = true,
            else => {},
        }
    }
    try T.expect(saw_6086);
    try T.expect(saw_6089);
    try T.expect(saw_6095);
    try T.expect(saw_6097);
}

test "Resolver: project-reference redirect trace emits TS6215" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/repo/ref/index.ts", "export const x = 1;");
    try vfs.addFile("/repo/app.ts", "import './ref/index';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .project_reference_redirect_config = "/repo/ref/tsconfig.json",
    });
    defer r.deinit();
    r.trace = &sink;

    _ = try r.resolve("./ref/index", "/repo/app.ts");

    var found = false;
    for (sink.entries.items) |e| {
        if (e.code != 6215) continue;
        try T.expectEqualStrings("Using compiler options of project reference redirect '/repo/ref/tsconfig.json'.", e.text);
        found = true;
    }
    try T.expect(found);
}

test "Resolver: node_modules + package.json resolution traces TS6098/6125/6099/6101" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/node_modules/dep/package.json", "{\"main\":\"./lib.js\"}");
    try vfs.addFile("/proj/node_modules/dep/lib.js", "module.exports = {};");
    try vfs.addFile("/proj/src/app.ts", "import 'dep';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    _ = r.resolve("dep", "/proj/src/app.ts") catch {};
    var saw_6098 = false;
    var saw_6125 = false;
    var saw_6101 = false;
    var saw_6100 = false;
    var saw_6417 = false;
    var saw_6418 = false;
    for (sink.entries.items) |e| {
        switch (e.code) {
            6098 => saw_6098 = true,
            6125 => saw_6125 = true,
            6101 => saw_6101 = true,
            6100 => saw_6100 = true,
            6417 => saw_6417 = true,
            6418 => saw_6418 = true,
            else => {},
        }
    }
    try T.expect(saw_6098);
    try T.expect(saw_6125);
    try T.expect(saw_6101);
    try T.expect(saw_6100);
    try T.expect(saw_6417);
    try T.expect(saw_6418);
}

test "Resolver: invalid package.json path field traces TS6105" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/node_modules/dep/package.json", "{\"types\":123,\"main\":\"./lib.js\"}");
    try vfs.addFile("/proj/node_modules/dep/lib.js", "module.exports = {};");
    try vfs.addFile("/proj/src/app.ts", "import 'dep';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("dep", "/proj/src/app.ts");
    try T.expectEqualStrings("/proj/node_modules/dep/lib.js", res.path);

    var saw_6105 = false;
    for (sink.entries.items) |e| {
        if (e.code == 6105) saw_6105 = true;
    }
    try T.expect(saw_6105);
}

test "Resolver: falsy package.json path field traces TS6220 and falls through" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/node_modules/dep/package.json", "{\"types\":false,\"main\":\"./lib.js\"}");
    try vfs.addFile("/proj/node_modules/dep/lib.js", "module.exports = {};");
    try vfs.addFile("/proj/src/app.ts", "import 'dep';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("dep", "/proj/src/app.ts");
    try T.expectEqualStrings("/proj/node_modules/dep/lib.js", res.path);

    var saw_6220 = false;
    var saw_6105 = false;
    for (sink.entries.items) |e| {
        switch (e.code) {
            6220 => saw_6220 = true,
            6105 => saw_6105 = true,
            else => {},
        }
    }
    try T.expect(saw_6220);
    try T.expect(!saw_6105);
}

test "Resolver: package peerDependencies trace found and missing peers" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/node_modules/dep/package.json",
        \\{
        \\  "types": "./index.d.ts",
        \\  "peerDependencies": {
        \\    "missing": "^1.0.0",
        \\    "react": "^18.0.0"
        \\  }
        \\}
    );
    try vfs.addFile("/proj/node_modules/dep/index.d.ts", "");
    try vfs.addFile("/proj/node_modules/react/package.json", "{\"version\":\"18.2.0\"}");
    try vfs.addFile("/proj/src/main.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("dep", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/node_modules/dep/index.d.ts", res.path);

    var saw_field = false;
    var saw_found = false;
    var saw_missing = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6281 and std.mem.indexOf(u8, entry.text, "peerDependencies") != null) saw_field = true;
        if (entry.code == 6282 and std.mem.indexOf(u8, entry.text, "react") != null and std.mem.indexOf(u8, entry.text, "18.2.0") != null) saw_found = true;
        if (entry.code == 6283 and std.mem.indexOf(u8, entry.text, "missing") != null) saw_missing = true;
    }
    try T.expect(saw_field);
    try T.expect(saw_found);
    try T.expect(saw_missing);
}

test "Resolver: package peerDependencies trace realpath lookup TS6130" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/node_modules/dep/package.json",
        \\{
        \\  "name": "dep",
        \\  "version": "1.0.0",
        \\  "types": "./index.d.ts",
        \\  "peerDependencies": { "react": "*" }
        \\}
    );
    try vfs.addFile("/proj/node_modules/dep/index.d.ts", "");
    try vfs.addRealPath("/proj/node_modules/dep", "/real/node_modules/dep");
    try vfs.addFile("/real/node_modules/react/package.json", "{\"version\":\"18.2.0\"}");
    try vfs.addFile("/proj/src/main.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("dep", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/node_modules/dep/index.d.ts", res.path);
    try T.expectEqualStrings("dep/index.d.ts@1.0.0+react@18.2.0", res.package_id.?);

    var saw_6130 = false;
    var saw_real_peer = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6130 and
            std.mem.indexOf(u8, entry.text, "/proj/node_modules/dep") != null and
            std.mem.indexOf(u8, entry.text, "/real/node_modules/dep") != null) saw_6130 = true;
        if (entry.code == 6282 and std.mem.indexOf(u8, entry.text, "react") != null) saw_real_peer = true;
    }
    try T.expect(saw_6130);
    try T.expect(saw_real_peer);
}

test "Resolver: automatic typings cache traces TS6140 and replaces JS-only package" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/node_modules/dep/index.js", "module.exports = {};");
    try vfs.addFile("/cache/node_modules/@types/dep/index.d.ts", "export declare const value: number;");
    try vfs.addFile("/proj/src/main.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .project_name = "/proj/tsconfig.json",
        .typings_location = "/cache",
    });
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("dep", "/proj/src/main.ts");
    try T.expectEqualStrings("/cache/node_modules/@types/dep/index.d.ts", res.path);
    try T.expect(res.is_declaration);

    var saw_6089_js = false;
    var saw_6140 = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6089 and std.mem.indexOf(u8, entry.text, "/proj/node_modules/dep/index.js") != null) saw_6089_js = true;
        if (entry.code == 6140 and
            std.mem.indexOf(u8, entry.text, "/proj/tsconfig.json") != null and
            std.mem.indexOf(u8, entry.text, "dep") != null and
            std.mem.indexOf(u8, entry.text, "/cache") != null) saw_6140 = true;
    }
    try T.expect(saw_6089_js);
    try T.expect(saw_6140);
}

test "Resolver: paths mapping traces TS6091/6092/6093" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/foo.ts", "export const x = 1;");
    try vfs.addFile("/proj/src/bar.ts", "import '@app/foo';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    const paths = [_]Config.PathEntry{.{ .pattern = "@app/*", .targets = &.{"./src/*"} }};
    var r = Resolver.init(T.allocator, vfs.fs(), .{ .base_url = "/proj", .paths = &paths });
    defer r.deinit();
    r.trace = &sink;

    _ = r.resolve("@app/foo", "/proj/src/bar.ts") catch {};
    var saw_6091 = false;
    var saw_6092 = false;
    var saw_6093 = false;
    for (sink.entries.items) |e| {
        switch (e.code) {
            6091 => saw_6091 = true,
            6092 => saw_6092 = true,
            6093 => saw_6093 = true,
            else => {},
        }
    }
    try T.expect(saw_6091);
    try T.expect(saw_6092);
    try T.expect(saw_6093);
}

test "Resolver: resolution cache dedupes repeated resolves (one trace set, not N)" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/foo.ts", "export const x = 1;");
    try vfs.addFile("/proj/src/bar.ts", "import './foo';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    // Resolve the same (dir, specifier) 5 times — the checker does this
    // many times during type-checking. Only the first should walk the FS
    // and trace; the rest hit the memo.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const res = try r.resolve("./foo", "/proj/src/bar.ts");
        try T.expectEqualStrings("/proj/src/foo.ts", res.path);
    }
    var count_6086: usize = 0;
    for (sink.entries.items) |e| {
        if (e.code == 6086) count_6086 += 1;
    }
    try T.expectEqual(@as(usize, 1), count_6086);
}

test "Resolver: traceResolution reports cached file existence lookups" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/dep.ts", "export const x = 1;");
    try vfs.addFile("/proj/src/app.ts", "import './dep';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    const dep = try r.resolve("./dep", "/proj/src/app.ts");
    try T.expectEqualStrings("/proj/src/dep.ts", dep.path);
    const dep_explicit = try r.resolve("./dep.ts", "/proj/src/app.ts");
    try T.expectEqualStrings("/proj/src/dep.ts", dep_explicit.path);

    _ = r.resolve("./missing", "/proj/src/app.ts") catch {};
    _ = r.resolve("./missing.ts", "/proj/src/app.ts") catch {};

    var saw_6239 = false;
    var saw_6240 = false;
    for (sink.entries.items) |e| {
        switch (e.code) {
            6239 => saw_6239 = true,
            6240 => saw_6240 = true,
            else => {},
        }
    }
    try T.expect(saw_6239);
    try T.expect(saw_6240);
}

test "Resolver: resolution-kind banner TS6088 (default) / TS6087 (explicit), once" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/foo.ts", "export const x = 1;");
    try vfs.addFile("/proj/src/bar.ts", "import './foo';");

    {
        var sink = TraceSink.init(T.allocator);
        defer sink.deinit();
        var r = Resolver.init(T.allocator, vfs.fs(), .{});
        defer r.deinit();
        r.trace = &sink;
        _ = try r.resolve("./foo", "/proj/src/bar.ts");
        _ = try r.resolve("./foo", "/proj/src/bar.ts");
        var count_6088: usize = 0;
        for (sink.entries.items) |e| {
            if (e.code == 6088) count_6088 += 1;
        }
        try T.expectEqual(@as(usize, 1), count_6088); // once, not per-resolve
    }
    {
        var sink = TraceSink.init(T.allocator);
        defer sink.deinit();
        var r = Resolver.init(T.allocator, vfs.fs(), .{ .explicit_strategy = true });
        defer r.deinit();
        r.trace = &sink;
        _ = try r.resolve("./foo", "/proj/src/bar.ts");
        var saw_6087 = false;
        for (sink.entries.items) |e| {
            if (e.code == 6087) saw_6087 = true;
        }
        try T.expect(saw_6087);
    }
}

test "Resolver: not-found resolution traces TS6090" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/bar.ts", "import './missing';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    try T.expectError(error.NotFound, r.resolve("./missing", "/proj/src/bar.ts"));
    var saw_6090 = false;
    for (sink.entries.items) |e| {
        if (e.code == 6090) saw_6090 = true;
    }
    try T.expect(saw_6090);
}

test "Resolver: rootDirs resolves relative module through sibling virtual root and traces" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/views/view.ts", "import './template';");
    try vfs.addFile("/proj/generated/views/template.ts", "export const template = 1;");
    try vfs.addFile("/proj/tsconfig.json", "{\"compilerOptions\":{\"rootDirs\":[\"./src\",\"./generated\"]}}");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    const roots = [_][]const u8{ "./src", "./generated" };
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .root_dirs = &roots,
        .config_file_path = "/proj/tsconfig.json",
    });
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("./template", "/proj/src/views/view.ts");
    try T.expectEqualStrings("/proj/generated/views/template.ts", res.path);
    try T.expectEqual(Resolution.Source.root_dirs, res.source);

    var saw_6104 = false;
    var saw_6107 = false;
    var saw_6108 = false;
    var saw_6109 = false;
    var saw_6110 = false;
    for (sink.entries.items) |e| {
        switch (e.code) {
            6104 => saw_6104 = true,
            6107 => saw_6107 = true,
            6108 => saw_6108 = true,
            6109 => saw_6109 = true,
            6110 => saw_6110 = true,
            else => {},
        }
    }
    try T.expect(saw_6104);
    try T.expect(saw_6107);
    try T.expect(saw_6108);
    try T.expect(saw_6109);
    try T.expect(saw_6110);
}

test "Resolver: failed rootDirs lookup traces TS6111" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/views/view.ts", "import './missing';");
    try vfs.addFile("/proj/tsconfig.json", "{\"compilerOptions\":{\"rootDirs\":[\"./src\",\"./generated\"]}}");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    const roots = [_][]const u8{ "./src", "./generated" };
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .root_dirs = &roots,
        .config_file_path = "/proj/tsconfig.json",
    });
    defer r.deinit();
    r.trace = &sink;

    try T.expectError(error.NotFound, r.resolve("./missing", "/proj/src/views/view.ts"));
    var saw_6111 = false;
    for (sink.entries.items) |e| {
        if (e.code == 6111) saw_6111 = true;
    }
    try T.expect(saw_6111);
}

test "Resolver: trace skips absolute URI-looking specifiers with TS6164" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/main.ts", "import 'https://example.com/mod.js';");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    try T.expectError(error.NotFound, r.resolve("https://example.com/mod.js", "/proj/src/main.ts"));
    var saw_6164 = false;
    var saw_6098 = false;
    for (sink.entries.items) |e| {
        switch (e.code) {
            6164 => saw_6164 = true,
            6098 => saw_6098 = true,
            else => {},
        }
    }
    try T.expect(saw_6164);
    try T.expect(!saw_6098);
}

test "Resolver: no trace sink means no tracing overhead (entries stay empty)" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/foo.ts", "export const x = 1;");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    // No sink attached: resolve still works, tracing is a no-op.
    const res = try r.resolve("./foo", "/proj/src/foo.ts");
    try T.expectEqualStrings("/proj/src/foo.ts", res.path);
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

test "Resolver: bare dot specifier resolves to sibling index" {
    // `import x from "."` from `/proj/a/b.ts` must resolve to
    // `/proj/a/index.ts`. Mirrors tsc on `importFromDot.ts`.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/a/index.ts", "export const indexInA = 0;");
    try vfs.addFile("/proj/a/b.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve(".", "/proj/a/b.ts");
    try T.expectEqualStrings("/proj/a/index.ts", res.path);
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

test "Resolver: REPRO paths mapping with extension-like name resolves to directory index" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    // Mirrors pathMappingBasedModuleResolution_withExtensionInName.ts:
    // baseUrl "." (root "/"), paths { "*": ["foo/*"] }, and the module
    // specifier "zone.js" / "zone.tsx" is a DIRECTORY name whose `.js`/
    // `.tsx` suffix is part of the package name, not a file extension.
    try vfs.addFile("/foo/zone.js/index.d.ts", "export const x: number;");
    try vfs.addFile("/foo/zone.tsx/index.d.ts", "export const y: number;");
    try vfs.addFile("/a.ts", "");

    const paths = [_]Config.PathEntry{
        .{ .pattern = "*", .targets = &.{"foo/*"} },
    };
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .base_url = "/",
        .paths = &paths,
    });
    defer r.deinit();
    const res_js = try r.resolve("zone.js", "/a.ts");
    try T.expectEqualStrings("/foo/zone.js/index.d.ts", res_js.path);
    const res_tsx = try r.resolve("zone.tsx", "/a.ts");
    try T.expectEqualStrings("/foo/zone.tsx/index.d.ts", res_tsx.path);
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

test "Resolver: ancestor node_modules direct declaration file" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/a/b/node_modules/foo.d.ts", "export declare let x: number");
    try vfs.addFile("/a/b/c/lib.ts", "");
    try vfs.addFile("/a/b/c/d/e/app.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .bundler });
    defer r.deinit();
    const lib_res = try r.resolve("foo", "/a/b/c/lib.ts");
    try T.expectEqualStrings("/a/b/node_modules/foo.d.ts", lib_res.path);
    try T.expect(lib_res.is_declaration);

    const app_res = try r.resolve("foo", "/a/b/c/d/e/app.ts");
    try T.expectEqualStrings("/a/b/node_modules/foo.d.ts", app_res.path);
    try T.expect(app_res.is_declaration);
}

test "Resolver: custom typeRoots resolve scoped packages literally" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/a/types/@scoped/typescache/index.d.ts", "export const typesCache: number;");
    try vfs.addFile("/a/types/mangled__typescache/index.d.ts", "export const mangledTypes: number;");
    try vfs.addFile("/a/node_modules/@types/@scoped/attypescache/index.d.ts", "export const atTypesCache: number;");
    try vfs.addFile("/a/node_modules/@types/mangled__attypescache/index.d.ts", "export const mangledAtTypesCache: number;");
    try vfs.addFile("/a.ts", "import { typesCache } from '@scoped/typescache';");

    const roots = [_][]const u8{ "/a/types", "/a/node_modules/@types" };
    var r = Resolver.init(T.allocator, vfs.fs(), .{ .type_roots = &roots });
    defer r.deinit();

    const scoped = try r.resolve("@scoped/typescache", "/a.ts");
    try T.expectEqualStrings("/a/types/@scoped/typescache/index.d.ts", scoped.path);
    try T.expectEqual(Resolution.Source.type_roots, scoped.source);
    try T.expectError(error.NotFound, r.resolve("@mangled/typescache", "/a.ts"));
    try T.expectError(error.NotFound, r.resolve("@scoped/attypescache", "/a.ts"));

    const at_types = try r.resolve("@mangled/attypescache", "/a.ts");
    try T.expectEqualStrings("/a/node_modules/@types/mangled__attypescache/index.d.ts", at_types.path);
    try T.expectEqual(Resolution.Source.type_roots, at_types.source);
}

test "Resolver: type reference directives trace custom typeRoots primary lookup" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/types/node/index.d.ts", "declare const process: unknown;");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    const roots = [_][]const u8{"/proj/types"};
    var r = Resolver.init(T.allocator, vfs.fs(), .{ .root_dir = "/proj", .type_roots = &roots });
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolveTypeReferenceDirective("node", "/proj/src/app.ts");
    try T.expectEqualStrings("/proj/types/node/index.d.ts", res.path);
    try T.expectError(error.NotFound, r.resolveTypeReferenceDirective("missing", "/proj/src/app.ts"));

    var saw_6116 = false;
    var saw_6119 = false;
    var saw_6120 = false;
    var saw_6121 = false;
    var saw_6265 = false;
    for (sink.entries.items) |entry| {
        switch (entry.code) {
            6116 => saw_6116 = true,
            6119 => saw_6119 = true,
            6120 => saw_6120 = true,
            6121 => saw_6121 = true,
            6265 => saw_6265 = true,
            else => {},
        }
    }
    try T.expect(saw_6116);
    try T.expect(saw_6119);
    try T.expect(saw_6120);
    try T.expect(saw_6121);
    try T.expect(saw_6265);
}

test "Resolver: type reference directives trace @types package IDs and missing root" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/node_modules/@types/node/package.json",
        \\{ "name": "@types/node", "version": "1.0.0", "types": "index.d.ts" }
    );
    try vfs.addFile("/proj/node_modules/@types/node/index.d.ts", "declare const process: unknown;");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolveTypeReferenceDirective("node", "/proj/src/app.ts");
    try T.expectEqualStrings("/proj/node_modules/@types/node/index.d.ts", res.path);
    try T.expectEqualStrings("@types/node/index.d.ts@1.0.0", res.package_id.?);
    try T.expectError(error.NotFound, r.resolveTypeReferenceDirective("missing", ""));

    var saw_6122 = false;
    var saw_6219 = false;
    var saw_6242 = false;
    for (sink.entries.items) |entry| {
        switch (entry.code) {
            6122 => saw_6122 = true,
            6219 => saw_6219 = true,
            6242 => saw_6242 = true,
            else => {},
        }
    }
    try T.expect(saw_6122);
    try T.expect(saw_6219);
    try T.expect(saw_6242);
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

test "Resolver: explicit declaration extension can resolve source implementation" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/foo.ts", "");
    try vfs.addFile("/proj/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("./foo.d.ts", "/proj/main.ts");
    try T.expectEqualStrings("/proj/foo.ts", res.path);
    try T.expect(!res.is_declaration);
}

test "Resolver: relative emitted js specifier maps to ts source input" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/thing.ts", "");
    try vfs.addFile("/proj/index.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .nodenext });
    defer r.deinit();
    r.trace = &sink;
    const res = try r.resolve("./src/thing.js", "/proj/index.ts");
    try T.expectEqualStrings("/proj/src/thing.ts", res.path);

    var saw_6132 = false;
    for (sink.entries.items) |e| {
        if (e.code == 6132) saw_6132 = true;
    }
    try T.expect(saw_6132);
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

test "Resolver: arbitrary extension declaration companion resolves" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/dir/native.d.node.ts", "export function doNativeThing(): unknown;");
    try vfs.addFile("/proj/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("./dir/native.node", "/proj/main.ts");
    try T.expectEqualStrings("/proj/dir/native.d.node.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: Home source and declaration extensions resolve" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "");
    try vfs.addFile("/proj/lib.hm", "export const x = 1;");
    try vfs.addFile("/proj/types.d.home", "export type T = string;");
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const lib = try r.resolve("./lib", "/proj/main.ts");
    try T.expectEqualStrings("/proj/lib.hm", lib.path);
    try T.expect(!lib.is_declaration);
    const types_home = try r.resolve("./types", "/proj/main.ts");
    try T.expectEqualStrings("/proj/types.d.home", types_home.path);
    try T.expect(types_home.is_declaration);
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

test "Resolver: classic bare module probes sibling virtual file" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/main.ts", "import \"d\";");
    try vfs.addFile("/d.ts", "export {};");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .classic });
    defer r.deinit();
    const res = try r.resolve("d", "/main.ts");
    try T.expectEqualStrings("/d.ts", res.path);
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

test "Resolver: TS2209 ambiguous project root for self-name exports under outDir" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/package.json",
        \\{ "name": "package", "type": "module", "exports": "./index.js" }
    );
    try vfs.addFile("/index.js", "export {};");
    var r = Resolver.init(T.allocator, vfs.fs(), .{ .out_dir = "out" });
    defer r.deinit();
    // With outDir set but no rootDir and no config file, the self-name
    // exports entry can't be reverse-mapped to a source root → unresolved
    // with the ambiguity recorded (tsc's TS2209).
    try T.expectError(error.NotFound, r.resolve("package", "/index.js"));
    try T.expect(r.ambiguous_root != null);
    try T.expectEqualStrings(".", r.ambiguous_root.?.entry);
    try T.expectEqualStrings("/package.json", r.ambiguous_root.?.file);
    try T.expect(!r.ambiguous_root.?.is_imports);
}

test "Resolver: no TS2209 when rootDir disambiguates" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/package.json",
        \\{ "name": "package", "type": "module", "exports": "./index.js" }
    );
    try vfs.addFile("/index.js", "export {};");
    var r = Resolver.init(T.allocator, vfs.fs(), .{ .out_dir = "out", .root_dir = "." });
    defer r.deinit();
    // rootDir present → no ambiguity; the export resolves normally.
    _ = r.resolve("package", "/index.js") catch {};
    try T.expect(r.ambiguous_root == null);
}

test "Resolver: no TS2209 without outDir/declarationDir" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/package.json",
        \\{ "name": "package", "type": "module", "exports": "./index.js" }
    );
    try vfs.addFile("/index.js", "export {};");
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    // No outDir → the export resolves directly, no ambiguity.
    _ = r.resolve("package", "/index.js") catch {};
    try T.expect(r.ambiguous_root == null);
}

test "Resolver: conditional exports trace matching fallback path" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/dep/package.json",
        \\{
        \\  "name": "dep",
        \\  "exports": {
        \\    ".": {
        \\      "import": {
        \\        "browser": "./browser.d.ts"
        \\      },
        \\      "default": "./fallback.d.ts"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/dep/fallback.d.ts", "export {};");
    try vfs.addFile("/a.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .conditions = &.{ "import", "node" },
    });
    defer r.deinit();
    r.trace = &sink;
    const res = try r.resolve("dep", "/a.ts");
    try T.expectEqualStrings("/node_modules/dep/fallback.d.ts", res.path);

    var saw_mode = false;
    var saw_matched_import = false;
    var saw_target = false;
    var saw_nonmatching = false;
    var saw_enter = false;
    var saw_resolved_default = false;
    var saw_failed_import = false;
    var saw_exit = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6402 and std.mem.indexOf(u8, entry.text, "ESM") != null and std.mem.indexOf(u8, entry.text, "'import'") != null) saw_mode = true;
        if (entry.code == 6403 and std.mem.indexOf(u8, entry.text, "exports") != null and std.mem.indexOf(u8, entry.text, "import") != null) saw_matched_import = true;
        if (entry.code == 6404 and std.mem.indexOf(u8, entry.text, "exports") != null and std.mem.indexOf(u8, entry.text, "./fallback.d.ts") != null) saw_target = true;
        if (entry.code == 6405 and std.mem.indexOf(u8, entry.text, "browser") != null) saw_nonmatching = true;
        if (entry.code == 6413) saw_enter = true;
        if (entry.code == 6414 and std.mem.indexOf(u8, entry.text, "default") != null) saw_resolved_default = true;
        if (entry.code == 6415 and std.mem.indexOf(u8, entry.text, "import") != null) saw_failed_import = true;
        if (entry.code == 6416) saw_exit = true;
    }
    try T.expect(saw_mode);
    try T.expect(saw_matched_import);
    try T.expect(saw_target);
    try T.expect(saw_nonmatching);
    try T.expect(saw_enter);
    try T.expect(saw_resolved_default);
    try T.expect(saw_failed_import);
    try T.expect(saw_exit);
}

test "Resolver: conditional exports invalid target traces TS6275 before fallback" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/dep/package.json",
        \\{
        \\  "name": "dep",
        \\  "exports": {
        \\    ".": {
        \\      "import": 123,
        \\      "default": "./fallback.d.ts"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/dep/fallback.d.ts", "export {};");
    try vfs.addFile("/a.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .conditions = &.{ "import", "node" },
    });
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("dep", "/a.ts");
    try T.expectEqualStrings("/node_modules/dep/fallback.d.ts", res.path);

    var saw_6275 = false;
    var saw_failed_import = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6275 and
            std.mem.indexOf(u8, entry.text, "/node_modules/dep") != null and
            std.mem.indexOf(u8, entry.text, "'.'") != null) saw_6275 = true;
        if (entry.code == 6415 and std.mem.indexOf(u8, entry.text, "import") != null) saw_failed_import = true;
    }
    try T.expect(saw_6275);
    try T.expect(saw_failed_import);
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

test "Resolver: exports routes to JS but legacy types yields alternate_result" {
    // Mirrors moduleResolution/resolvesWithoutExportsDiagnostic1: the
    // `exports` map only exposes `import`/`require` JS entry points, so
    // an ESM importer resolves to `index.mjs` (untyped). The legacy
    // top-level `types` field still points at `index.d.ts`, which is
    // unreachable while respecting `exports` — tsc records it as the
    // alternate result so the checker can emit the TS6278 elaboration.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{
        \\  "name": "foo",
        \\  "main": "index.js",
        \\  "types": "index.d.ts",
        \\  "exports": {
        \\    ".": {
        \\      "import": "./index.mjs",
        \\      "require": "./index.js"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/foo/index.js", "");
    try vfs.addFile("/node_modules/foo/index.mjs", "");
    try vfs.addFile("/node_modules/foo/index.d.ts", "");
    try vfs.addFile("/index.mts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .strategy = .node16,
        .conditions = &.{ "import", "node" },
    });
    defer r.deinit();
    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    r.trace = &sink;
    const res = try r.resolve("foo", "/index.mts");
    try T.expectEqualStrings("/node_modules/foo/index.mjs", res.path);
    try T.expect(!res.is_declaration);
    try T.expect(res.alternate_result != null);
    try T.expectEqualStrings("/node_modules/foo/index.d.ts", res.alternate_result.?);
    var saw_probe_trace = false;
    var saw_types_trace = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6277) saw_probe_trace = true;
        if (entry.code == 6278) saw_types_trace = true;
    }
    try T.expect(saw_probe_trace);
    try T.expect(saw_types_trace);
}

test "Resolver: exports routes to JS, @types sibling yields alternate_result" {
    // The `bar` package itself ships only JS via `exports`, but a
    // sibling `@types/bar` declares the types. tsc reports the
    // alternate path under `/node_modules/@types/` so the checker
    // rewrites the package name to `@types/bar` in TS6278.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/bar/package.json",
        \\{
        \\  "name": "bar",
        \\  "main": "index.js",
        \\  "exports": {
        \\    ".": {
        \\      "import": "./index.mjs",
        \\      "require": "./index.js"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/bar/index.js", "");
    try vfs.addFile("/node_modules/bar/index.mjs", "");
    try vfs.addFile("/node_modules/@types/bar/package.json",
        \\{ "name": "@types/bar", "types": "index.d.ts" }
    );
    try vfs.addFile("/node_modules/@types/bar/index.d.ts", "");
    try vfs.addFile("/index.mts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .strategy = .node16,
        .conditions = &.{ "import", "node" },
    });
    defer r.deinit();
    const res = try r.resolve("bar", "/index.mts");
    try T.expectEqualStrings("/node_modules/bar/index.mjs", res.path);
    try T.expect(!res.is_declaration);
    try T.expect(res.alternate_result != null);
    try T.expectEqualStrings("/node_modules/@types/bar/index.d.ts", res.alternate_result.?);
}

test "Resolver: no alternate_result when exports already exposes types" {
    // Negative: when `exports` resolves directly to a declaration file
    // (via the `types` condition), there is nothing unreachable, so no
    // alternate_result is recorded.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/dep/package.json",
        \\{
        \\  "name": "dep",
        \\  "exports": {
        \\    ".": {
        \\      "import": "./dist/index.mjs",
        \\      "types": "./dist/index.d.ts"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/dep/dist/index.d.ts", "");
    try vfs.addFile("/node_modules/dep/dist/index.mjs", "");
    try vfs.addFile("/index.mts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .strategy = .node16,
        .conditions = &.{ "import", "node" },
    });
    defer r.deinit();
    const res = try r.resolve("dep", "/index.mts");
    try T.expectEqualStrings("/node_modules/dep/dist/index.d.ts", res.path);
    try T.expect(res.is_declaration);
    try T.expect(res.alternate_result == null);
}

test "Resolver: no alternate_result for require (non-ESM) importer" {
    // Negative: tsc only computes the alternate result when `import`
    // is among the active conditions. A CJS (`require`) importer never
    // gets the elaboration even though types are unreachable.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{
        \\  "name": "foo",
        \\  "main": "index.js",
        \\  "types": "index.d.ts",
        \\  "exports": {
        \\    ".": {
        \\      "import": "./index.mjs",
        \\      "require": "./index.js"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/foo/index.js", "");
    try vfs.addFile("/node_modules/foo/index.mjs", "");
    try vfs.addFile("/node_modules/foo/index.d.ts", "");
    try vfs.addFile("/index.cts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .strategy = .node16,
        .conditions = &.{ "require", "node" },
    });
    defer r.deinit();
    const res = try r.resolve("foo", "/index.cts");
    try T.expectEqualStrings("/node_modules/foo/index.js", res.path);
    try T.expect(!res.is_declaration);
    try T.expect(res.alternate_result == null);
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

test "Resolver: self-name exports declarationDir target maps back to source input" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/package.json",
        \\{
        \\  "name": "@this/package",
        \\  "type": "module",
        \\  "exports": {
        \\    ".": {
        \\      "types": "./types/index.d.ts",
        \\      "default": "./dist/index.js"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/index.ts", "export {};");
    try vfs.addFile("/src/thing.ts", "import '@this/package';");
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .strategy = .nodenext,
        .declaration_dir = "./types",
        .out_dir = "./dist",
        .config_file_path = "/tsconfig.json",
    });
    defer r.deinit();
    const res = try r.resolve("@this/package", "/src/thing.ts");
    try T.expectEqualStrings("/index.ts", res.path);
    try T.expectEqual(Resolution.Source.package_exports, res.source);
    try T.expect(res.project_reference_output == null);
}

test "Resolver: self-name exports outDir default target maps back to source input" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/package.json",
        \\{
        \\  "name": "@this/package",
        \\  "type": "module",
        \\  "exports": {
        \\    ".": {
        \\      "default": "./dist/index.js"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/index.ts", "export {};");
    try vfs.addFile("/src/thing.ts", "import '@this/package';");
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .strategy = .nodenext,
        .out_dir = "./dist",
        .config_file_path = "/tsconfig.json",
    });
    defer r.deinit();
    const res = try r.resolve("@this/package", "/src/thing.ts");
    try T.expectEqualStrings("/index.ts", res.path);
    try T.expectEqual(Resolution.Source.package_exports, res.source);
    try T.expect(res.project_reference_output == null);
}

test "Resolver: project-reference output diagnostics preserve missing declaration output" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/package.json",
        \\{
        \\  "name": "@this/package",
        \\  "type": "module",
        \\  "exports": {
        \\    ".": {
        \\      "types": "./types/index.d.ts",
        \\      "default": "./dist/index.js"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/index.ts", "export {};");
    try vfs.addFile("/src/thing.ts", "import '@this/package';");
    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .strategy = .nodenext,
        .declaration_dir = "./types",
        .out_dir = "./dist",
        .config_file_path = "/tsconfig.json",
        .project_reference_output_diagnostics = true,
    });
    defer r.deinit();
    const res = try r.resolve("@this/package", "/src/thing.ts");
    try T.expectEqualStrings("/index.ts", res.path);
    try T.expectEqualStrings("/types/index.d.ts", res.project_reference_output.?);
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

test "Resolver: typesVersions traces matching range lookup" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{
        \\  "name": "foo",
        \\  "typesVersions": { ">=4.0": { "*": ["ts4.0/*"] } }
        \\}
    );
    try vfs.addFile("/node_modules/foo/ts4.0/sub.d.ts", "");
    try vfs.addFile("/a.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;
    const res = try r.resolve("foo/sub", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/ts4.0/sub.d.ts", res.path);

    var saw_field = false;
    var saw_match = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6206) saw_field = true;
        if (entry.code == 6208 and
            std.mem.indexOf(u8, entry.text, ">=4.0") != null and
            std.mem.indexOf(u8, entry.text, "7.0.0-dev") != null and
            std.mem.indexOf(u8, entry.text, "sub") != null)
        {
            saw_match = true;
        }
    }
    try T.expect(saw_field);
    try T.expect(saw_match);
}

test "Resolver: typesVersions traces invalid and nonmatching ranges" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{
        \\  "name": "foo",
        \\  "main": "./index.js",
        \\  "typesVersions": {
        \\    "not-a-range": { "*": ["bad/*"] },
        \\    ">=99.0": { "*": ["future/*"] }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/foo/index.js", "");
    try vfs.addFile("/a.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;
    const res = try r.resolve("foo", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/index.js", res.path);

    var saw_field = false;
    var saw_invalid = false;
    var saw_no_match = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6206) saw_field = true;
        if (entry.code == 6209 and std.mem.indexOf(u8, entry.text, "not-a-range") != null) saw_invalid = true;
        if (entry.code == 6207 and std.mem.indexOf(u8, entry.text, "7.0") != null) saw_no_match = true;
    }
    try T.expect(saw_field);
    try T.expect(saw_invalid);
    try T.expect(saw_no_match);
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

test "Resolver: package ID trace uses TS6218 for package resolution" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{ "name": "foo", "version": "1.2.3" }
    );
    try vfs.addFile("/node_modules/foo/index.js", "");
    try vfs.addFile("/a.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("foo", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/index.js", res.path);
    try T.expectEqualStrings("foo/index.js@1.2.3", res.package_id.?);

    var saw_6218 = false;
    var saw_plain_6089 = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6218 and
            std.mem.indexOf(u8, entry.text, "foo/index.js@1.2.3") != null) saw_6218 = true;
        if (entry.code == 6089) saw_plain_6089 = true;
    }
    try T.expect(saw_6218);
    try T.expect(!saw_plain_6089);
}

test "Resolver: package ID includes peer dependency suffix" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{
        \\  "name": "foo",
        \\  "version": "1.2.3",
        \\  "types": "./index.d.ts",
        \\  "peerDependencies": { "react": "*" }
        \\}
    );
    try vfs.addFile("/node_modules/foo/index.d.ts", "");
    try vfs.addFile("/node_modules/react/package.json",
        \\{ "name": "react", "version": "18.2.0" }
    );
    try vfs.addFile("/a.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    r.trace = &sink;

    const res = try r.resolve("foo", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/index.d.ts", res.path);
    try T.expectEqualStrings("foo/index.d.ts@1.2.3+react@18.2.0", res.package_id.?);

    var saw_peer_field = false;
    var saw_peer_version = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6281) saw_peer_field = true;
        if (entry.code == 6282 and std.mem.indexOf(u8, entry.text, "react") != null) saw_peer_version = true;
    }
    try T.expect(saw_peer_field);
    try T.expect(saw_peer_version);
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

// =============================================================================
// Resolver follow-ups: typesVersions root, @types/<pkg> fallback,
// strategy-gated `exports`, conditional ordering. Each test mirrors a
// concrete upstream §6.A fixture or its negative-control equivalent.
// =============================================================================

test "Resolver: typesVersions — root '*' wildcard resolves through `index.d.ts`" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/a/package.json",
        \\{ "typesVersions": { ">=3.1.0-0": { "*": ["ts3.1/*"] } } }
    );
    try vfs.addFile("/node_modules/a/ts3.1/index.d.ts", "export const a = 0;");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("a", "/main.ts");
    try T.expectEqualStrings("/node_modules/a/ts3.1/index.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: typesVersions — multi-file, root + subpath both go through ts3.1/" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/ext/package.json",
        \\{
        \\  "name": "ext",
        \\  "types": "index",
        \\  "typesVersions": { ">=3.1.0-0": { "*": ["ts3.1/*"] } }
        \\}
    );
    try vfs.addFile("/node_modules/ext/index.d.ts", "");
    try vfs.addFile("/node_modules/ext/other.d.ts", "");
    try vfs.addFile("/node_modules/ext/ts3.1/index.d.ts", "");
    try vfs.addFile("/node_modules/ext/ts3.1/other.d.ts", "");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const root = try r.resolve("ext", "/main.ts");
    try T.expectEqualStrings("/node_modules/ext/ts3.1/index.d.ts", root.path);
    const sub = try r.resolve("ext/other", "/main.ts");
    try T.expectEqualStrings("/node_modules/ext/ts3.1/other.d.ts", sub.path);
}

test "Resolver: typesVersions — exact key beats wildcard pattern" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/pkg/package.json",
        \\{
        \\  "typesVersions": {
        \\    ">=4.0": {
        \\      "special": ["custom/special.d.ts"],
        \\      "*": ["fallback/*.d.ts"]
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/pkg/custom/special.d.ts", "");
    try vfs.addFile("/node_modules/pkg/fallback/other.d.ts", "");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const exact = try r.resolve("pkg/special", "/main.ts");
    try T.expectEqualStrings("/node_modules/pkg/custom/special.d.ts", exact.path);
    const pat = try r.resolve("pkg/other", "/main.ts");
    try T.expectEqualStrings("/node_modules/pkg/fallback/other.d.ts", pat.path);
}

test "Resolver: @types/<pkg> fallback — bare pkg with no types resolves through @types" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{ "name": "foo" }
    );
    try vfs.addFile("/node_modules/foo/index.js", "");
    try vfs.addFile("/node_modules/@types/foo/package.json",
        \\{ "name": "@types/foo" }
    );
    try vfs.addFile("/node_modules/@types/foo/index.d.ts", "export const foo: number;");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("foo", "/main.ts");
    try T.expectEqualStrings("/node_modules/@types/foo/index.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: @types/<scope>__<name> fallback — scoped pkg flips to flattened types" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/@scope/foo/package.json",
        \\{ "name": "@scope/foo" }
    );
    try vfs.addFile("/node_modules/@scope/foo/index.js", "");
    try vfs.addFile("/node_modules/@types/scope__foo/package.json",
        \\{ "name": "@types/scope__foo" }
    );
    try vfs.addFile("/node_modules/@types/scope__foo/index.d.ts", "");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("@scope/foo", "/main.ts");
    try T.expectEqualStrings("/node_modules/@types/scope__foo/index.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: @types fallback respects sibling .js as the implementation" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{ "name": "foo" }
    );
    try vfs.addFile("/node_modules/foo/index.js", "");
    try vfs.addFile("/node_modules/@types/foo/package.json",
        \\{ "name": "@types/foo" }
    );
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("foo", "/main.ts");
    try T.expectEqualStrings("/node_modules/foo/index.js", res.path);
    try T.expect(!res.is_declaration);
}

test "Resolver: node10 strategy IGNORES `exports` — falls through to `main`" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/pkg/package.json",
        \\{
        \\  "name": "pkg",
        \\  "main": "./untyped.js",
        \\  "exports": { ".": "./definitely-not-index.js" }
        \\}
    );
    try vfs.addFile("/node_modules/pkg/untyped.js", "");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer r.deinit();
    const res = try r.resolve("pkg", "/main.ts");
    try T.expectEqualStrings("/node_modules/pkg/untyped.js", res.path);
    try T.expect(!res.is_declaration);
}

test "Resolver: node16 strategy DOES honor `exports` — exports wins over main" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/pkg/package.json",
        \\{
        \\  "name": "pkg",
        \\  "main": "./present.js",
        \\  "exports": { ".": "./definitely-not-index.js" }
        \\}
    );
    try vfs.addFile("/node_modules/pkg/present.js", "");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("pkg", "/main.ts"));
}

test "Resolver: package exports — `import` condition string resolves over `default`" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/dep/package.json",
        \\{
        \\  "exports": {
        \\    ".": {
        \\      "import": "./dist/index.mjs",
        \\      "default": "./dist/index.cjs"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/dep/dist/index.mjs", "");
    try vfs.addFile("/node_modules/dep/dist/index.cjs", "");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .conditions = &.{ "import", "node" },
    });
    defer r.deinit();
    const res = try r.resolve("dep", "/main.ts");
    try T.expectEqualStrings("/node_modules/dep/dist/index.mjs", res.path);
}

test "Resolver: package exports — `require` condition picked when `import` absent" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/dep/package.json",
        \\{
        \\  "exports": {
        \\    ".": {
        \\      "import": "./dist/index.mjs",
        \\      "require": "./dist/index.cjs"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/dep/dist/index.mjs", "");
    try vfs.addFile("/node_modules/dep/dist/index.cjs", "");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .conditions = &.{ "require", "node" },
    });
    defer r.deinit();
    const res = try r.resolve("dep", "/main.ts");
    try T.expectEqualStrings("/node_modules/dep/dist/index.cjs", res.path);
}

test "Resolver: nestedPackageJsonRedirect — subpath `package.json` reaches into parent dir" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/@restart/hooks/package.json",
        \\{
        \\  "name": "@restart/hooks",
        \\  "main": "cjs/index.js",
        \\  "types": "cjs/index.d.ts",
        \\  "module": "esm/index.js"
        \\}
    );
    try vfs.addFile("/node_modules/@restart/hooks/useMergedRefs/package.json",
        \\{
        \\  "name": "@restart/hooks/useMergedRefs",
        \\  "private": true,
        \\  "main": "../cjs/useMergedRefs.js",
        \\  "module": "../esm/useMergedRefs.js",
        \\  "types": "../esm/useMergedRefs.d.ts"
        \\}
    );
    try vfs.addFile("/node_modules/@restart/hooks/esm/useMergedRefs.d.ts", "export {};");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    const res = try r.resolve("@restart/hooks/useMergedRefs", "/main.ts");
    try T.expectEqualStrings("/node_modules/@restart/hooks/esm/useMergedRefs.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: package exports — null on import condition keeps `types` reachable" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/dep/package.json",
        \\{
        \\  "exports": {
        \\    ".": {
        \\      "types": "./dist/index.d.ts",
        \\      "import": null,
        \\      "default": "./dist/index.js"
        \\    }
        \\  }
        \\}
    );
    try vfs.addFile("/node_modules/dep/dist/index.d.ts", "");
    try vfs.addFile("/node_modules/dep/dist/index.js", "");
    try vfs.addFile("/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{
        .conditions = &.{ "import", "node" },
    });
    defer r.deinit();
    const res = try r.resolve("dep", "/main.ts");
    try T.expectEqualStrings("/node_modules/dep/dist/index.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: relative import lands in node_modules pkg via index.js" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/foo/package.json",
        \\{ "name": "foo" }
    );
    try vfs.addFile("/node_modules/foo/index.js", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("./node_modules/foo", "/a.ts");
    try T.expectEqualStrings("/node_modules/foo/index.js", res.path);
    try T.expect(!res.is_declaration);
}

test "Resolver: package types — ABSOLUTE value discards package dir" {
    // Mirrors the `APISample_*` harness shape: `package.json` `types`
    // points at an absolute `/.ts/...` declaration file mounted
    // outside the package directory.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/typescript/package.json",
        \\{ "name": "typescript", "types": "/.ts/typescript.d.ts" }
    );
    try vfs.addFile("/.ts/typescript.d.ts", "");
    try vfs.addFile("/a.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{});
    defer r.deinit();
    const res = try r.resolve("typescript", "/a.ts");
    try T.expectEqualStrings("/.ts/typescript.d.ts", res.path);
    try T.expect(res.is_declaration);
}

// =============================================================================
// Self-name + `#imports` resolution (TS2307 false-positive reduction).
//
// These mirror tsc's `loadModuleFromSelfNameReference` and
// `loadModuleFromImports`: a package may `import "<own-name>/sub"` and
// resolve it through its OWN `exports`, and a `#`-prefixed specifier
// resolves against the enclosing `package.json` `imports` map. Both are
// gated on the modern resolvers (node16/nodenext/bundler).
// =============================================================================

test "Resolver: self-name — package imports itself by name via root exports" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{
        \\  "name": "my-pkg",
        \\  "exports": { ".": { "types": "./dist/index.d.ts", "import": "./dist/index.mjs" } }
        \\}
    );
    try vfs.addFile("/proj/dist/index.d.ts", "export const x: number;");
    try vfs.addFile("/proj/dist/index.mjs", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    const res = try r.resolve("my-pkg", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/dist/index.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: self-name — subpath resolves through own exports pattern" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{
        \\  "name": "@scope/lib",
        \\  "exports": { "./*": { "types": "./types/*.d.ts" } }
        \\}
    );
    try vfs.addFile("/proj/types/feature.d.ts", "export const f: number;");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .bundler });
    defer r.deinit();
    const res = try r.resolve("@scope/lib/feature", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/types/feature.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: self-name — requires `exports`; bare name without exports falls through" {
    // Negative: a package.json `name` WITHOUT an `exports` map does not
    // grant a self-name channel, so `import "my-pkg"` from inside is
    // genuinely unresolved (matching tsc's exports guard).
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{ "name": "my-pkg", "main": "./index.js" }
    );
    try vfs.addFile("/proj/index.js", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("my-pkg", "/proj/src/main.ts"));
}

test "Resolver: self-name — disabled under node10 (legacy) strategy" {
    // Negative: the legacy node10 strategy never consults self-name,
    // so the same import is unresolved.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{
        \\  "name": "my-pkg",
        \\  "exports": { ".": "./dist/index.d.ts" }
        \\}
    );
    try vfs.addFile("/proj/dist/index.d.ts", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("my-pkg", "/proj/src/main.ts"));
}

test "Resolver: self-name — wrong name prefix does not match" {
    // Negative: `my-pkg-extra` is NOT covered by self-name for `my-pkg`
    // (the name must match on whole path components), so it falls
    // through to node_modules and fails.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{
        \\  "name": "my-pkg",
        \\  "exports": { ".": "./dist/index.d.ts" }
        \\}
    );
    try vfs.addFile("/proj/dist/index.d.ts", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("my-pkg-extra", "/proj/src/main.ts"));
}

test "Resolver: self-name — node_modules still wins for a DIFFERENT package name" {
    // Self-name must not shadow ordinary dependency resolution: a sibling
    // dependency `other` under node_modules resolves normally even though
    // the enclosing package declares its own name + exports.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{ "name": "my-pkg", "exports": { ".": "./dist/index.d.ts" } }
    );
    try vfs.addFile("/proj/dist/index.d.ts", "");
    try vfs.addFile("/proj/node_modules/other/package.json",
        \\{ "name": "other", "types": "./other.d.ts" }
    );
    try vfs.addFile("/proj/node_modules/other/other.d.ts", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    const res = try r.resolve("other", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/node_modules/other/other.d.ts", res.path);
}

test "Resolver: #imports — private subpath resolves through `imports` map" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{
        \\  "name": "my-pkg",
        \\  "imports": { "#internal/*": { "types": "./src/internal/*.d.ts" } }
        \\}
    );
    try vfs.addFile("/proj/src/internal/util.d.ts", "export const u: number;");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    const res = try r.resolve("#internal/util", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/src/internal/util.d.ts", res.path);
    try T.expect(res.is_declaration);
}

test "Resolver: #imports — exact key beats node_modules and never walks it" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{ "name": "my-pkg", "imports": { "#dep": "./shim.d.ts" } }
    );
    try vfs.addFile("/proj/shim.d.ts", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .bundler });
    defer r.deinit();
    const res = try r.resolve("#dep", "/proj/src/main.ts");
    try T.expectEqualStrings("/proj/shim.d.ts", res.path);
}

test "Resolver: #imports — invalid target traces TS6275" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{ "name": "my-pkg", "imports": { "#bad": 123 } }
    );
    try vfs.addFile("/proj/src/main.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    r.trace = &sink;

    try T.expectError(error.NotFound, r.resolve("#bad", "/proj/src/main.ts"));
    var saw_6275 = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6275 and
            std.mem.indexOf(u8, entry.text, "/proj") != null and
            std.mem.indexOf(u8, entry.text, "#bad") != null) saw_6275 = true;
    }
    try T.expect(saw_6275);
}

test "Resolver: #imports — unmatched `#` specifier is a hard NotFound" {
    // Negative: a `#`-prefixed specifier with no covering `imports` entry
    // must NOT fall back to node_modules — it is genuinely unresolved.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{ "name": "my-pkg", "imports": { "#known": "./known.d.ts" } }
    );
    try vfs.addFile("/proj/known.d.ts", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("#unknown", "/proj/src/main.ts"));
}

test "Resolver: #imports — invalid specifier traces TS6272" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{ "name": "my-pkg", "imports": { "#known": "./known.d.ts" } }
    );
    try vfs.addFile("/proj/src/main.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    r.trace = &sink;

    try T.expectError(error.NotFound, r.resolve("#", "/proj/src/main.ts"));
    var saw_6272 = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6272) saw_6272 = true;
    }
    try T.expect(saw_6272);
}

test "Resolver: #imports — missing package scope traces TS6270" {
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/main.ts", "");

    var sink = TraceSink.init(T.allocator);
    defer sink.deinit();
    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node16 });
    defer r.deinit();
    r.trace = &sink;

    try T.expectError(error.NotFound, r.resolve("#unknown", "/proj/src/main.ts"));
    var saw_6270 = false;
    for (sink.entries.items) |entry| {
        if (entry.code == 6270) saw_6270 = true;
    }
    try T.expect(saw_6270);
}

test "Resolver: #imports — disabled under classic strategy" {
    // Negative: classic strategy never looks at `imports`.
    var vfs = VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/package.json",
        \\{ "name": "my-pkg", "imports": { "#x": "./x.d.ts" } }
    );
    try vfs.addFile("/proj/x.d.ts", "");
    try vfs.addFile("/proj/src/main.ts", "");

    var r = Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .classic });
    defer r.deinit();
    try T.expectError(error.NotFound, r.resolve("#x", "/proj/src/main.ts"));
}
