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
const builtin = @import("builtin");
const ts_driver = @import("ts_driver");
const ts_resolver = @import("ts_resolver");
const ts_cache = @import("ts_cache");
const tsconfig_mod = @import("tsconfig");
const hir_mod_ns = @import("hir");
const binder = @import("binder");
const StringInterner = ts_driver.StringInterner;
const source_owners = ts_driver.source_owners;

pub const FileId = u32;
pub const export_origins = @import("export_origins.zig");
const class_declarations = @import("class_declarations.zig");
const declaration_graph = @import("declaration_graph.zig");
const checked_schema = @import("checked_schema.zig");

const program_source_markers = &[_][]const u8{
    "namespace", "module", "global", "declare", "interface", "class", "export", "exports", "=",
};
const ProgramSourceMarkerIndex = ts_driver.SourceMarkerIndex;
const ProgramSourceMarkers = union(enum) {
    borrowed: *const ProgramSourceMarkerIndex,
    owned: ProgramSourceMarkerIndex,

    fn contains(self: *const ProgramSourceMarkers, comptime marker: []const u8) bool {
        return switch (self.*) {
            .borrowed => |index| index.contains(marker),
            .owned => |*index| index.contains(marker),
        };
    }
};

const OwnerMutex = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *OwnerMutex) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *OwnerMutex) void {
        self.state.store(false, .release);
    }
};

/// Why a file is part of the program — mirrors tsgo's
/// `FileIncludeReason` (the subset Home can determine today). Drives the
/// `--explainFiles` line for each file. Root-file provenance is supplied
/// by the CLI layer (which knows how the path was specified); the
/// program records the transitive reason here while building the edge
/// graph, so `--explainFiles` can render TS1393/TS1400/TS1402/TS1405
/// plus compilerOptions type/lib entries, and diagnostics can attach
/// the corresponding related-information anchors.
pub const IncludeKind = enum {
    root,
    import,
    reference_file,
    type_reference,
    lib_reference,
    imported_helper,
    jsx_runtime_import,
    compiler_type_reference,
    implicit_type_reference,
    compiler_lib_reference,
    default_lib_reference,
};

pub const IncludeReason = struct {
    kind: IncludeKind = .root,
    /// For non-root reasons: the file id that pulled this one in (the
    /// importer, or the file containing the triple-slash directive).
    importer: FileId = 0,
    /// The reference text as written: for `.import` the module specifier
    /// quoted to match tsgo's `referenceLocation.text()`; for
    /// triple-slash references the bare target text. Owned by the program.
    specifier_text: []const u8 = "",
    /// tsc package identity for node_modules imports/type-reference
    /// directives when the resolver found one. Owned by the program when
    /// non-empty.
    package_id: []const u8 = "",
    /// Emitted declaration output path that redirected to this source file
    /// through project-reference resolution. Owned by the program when non-empty.
    project_reference_output: []const u8 = "",
    /// Byte offset of the import/reference specifier in the importer.
    /// Used for related-information anchors.
    specifier_pos: u32 = 0,

    pub fn relatedDiagnosticCode(self: IncludeReason) ?u32 {
        const code_file_included_via_import_here: u32 = 1399;
        const code_file_included_via_reference_here: u32 = 1401;
        const code_file_included_via_type_reference_here: u32 = 1404;
        const code_file_included_via_lib_reference_here: u32 = 1406;
        const code_file_is_entry_point_of_type_library_specified_here: u32 = 1419;
        const code_file_is_library_specified_here: u32 = 1423;
        const code_file_is_default_library_for_target_specified_here: u32 = 1426;
        return switch (self.kind) {
            .import => code_file_included_via_import_here,
            .reference_file => code_file_included_via_reference_here,
            .type_reference => code_file_included_via_type_reference_here,
            .lib_reference => code_file_included_via_lib_reference_here,
            .compiler_type_reference => code_file_is_entry_point_of_type_library_specified_here,
            .compiler_lib_reference => code_file_is_library_specified_here,
            .default_lib_reference => code_file_is_default_library_for_target_specified_here,
            .root, .imported_helper, .jsx_runtime_import, .implicit_type_reference => null,
        };
    }

    pub fn relatedDiagnosticMessage(self: IncludeReason) ?[]const u8 {
        return switch (self.kind) {
            .import => "File is included via import here.",
            .reference_file => "File is included via reference here.",
            .type_reference => "File is included via type library reference here.",
            .lib_reference => "File is included via library reference here.",
            .compiler_type_reference => "File is entry point of type library specified here.",
            .compiler_lib_reference => "File is library specified here.",
            .default_lib_reference => "File is default library for target specified here.",
            .root, .imported_helper, .jsx_runtime_import, .implicit_type_reference => null,
        };
    }

    pub fn specifierSpanLen(self: IncludeReason) u32 {
        return @intCast(@min(self.specifier_text.len, std.math.maxInt(u32)));
    }
};

fn findIncludeSpecifierPosition(source: []const u8, specifier_text: []const u8) u32 {
    if (specifier_text.len == 0) return 0;
    if (std.mem.indexOf(u8, source, specifier_text)) |pos| {
        return @intCast(@min(pos, std.math.maxInt(u32)));
    }
    var needle = specifier_text;
    if (specifier_text.len >= 2) {
        const first = specifier_text[0];
        const last = specifier_text[specifier_text.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            needle = specifier_text[1 .. specifier_text.len - 1];
        }
    }
    if (std.mem.indexOf(u8, source, needle)) |pos| {
        const quoted_pos = if (pos > 0 and (source[pos - 1] == '"' or source[pos - 1] == '\'')) pos - 1 else pos;
        return @intCast(@min(quoted_pos, std.math.maxInt(u32)));
    }
    return 0;
}

/// One file in the program. Owned by the program.
pub const File = struct {
    id: FileId,
    /// Resolved absolute (or program-canonical) path.
    path: []const u8,
    /// Source text. NOT owned — caller manages lifetime via the
    /// FileSystem implementation.
    source: []const u8,
    /// Exact byte facts for the current collection pass only. Cleared on
    /// every compilation exit; redirects never receive a source snapshot.
    source_markers: ?ProgramSourceMarkers = null,
    /// Compiled artefact. `null` until `compileAll` runs.
    compilation: ?*ts_driver.Compilation,
    /// Stable checked-source identity in `Program.owners`. Tombstoned before
    /// the compilation storage is destroyed or replaced.
    owner: source_owners.OwnerId = .none,
    /// Outgoing import edges — file ids this file imports from.
    imports: std.ArrayListUnmanaged(FileId),
    /// True for `.d.ts` / `.d.hm` / `.d.home` declaration-only files.
    is_declaration: bool,
    /// True for `.tsx` / `.jsx` files.
    is_tsx: bool,
    /// Resolver-derived implied Node format for ambiguous extensions.
    package_type_module: bool,
    /// First-seen reason this file is in the program. `null` until set
    /// by `resolveImports` (for imported files); root files are
    /// classified by the CLI layer at `--explainFiles` time.
    include_reason: ?IncludeReason = null,
    /// Package-ID deduplication redirect target. When two physical
    /// node_modules files have the same package identity, tsgo keeps the
    /// first source file as canonical and records later paths as redirect
    /// files for explainFiles (TS1429).
    redirect_target: ?FileId = null,

    fn sourceContains(self: *const File, comptime marker: []const u8) bool {
        if (self.source_markers) |*markers| return markers.contains(marker);
        return std.mem.indexOf(u8, self.source, marker) != null;
    }
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

/// Borrowed declarations: NodeIds and TypeIds must only be interpreted in
/// `file.compilation`. Shared names do not merge local symbol/type ownership.
/// An index is valid only while its prepared files remain alive and unchanged.
const BoundGlobal = struct {
    file: *const File,
    symbol: *const binder.Symbol,
};

const BoundGlobals = struct {
    const Key = struct { name: hir_mod_ns.StringId, space: binder.Binder.Space };
    entries: std.AutoArrayHashMapUnmanaged(Key, std.ArrayListUnmanaged(BoundGlobal)) = .empty,

    fn deinit(self: *BoundGlobals, gpa: std.mem.Allocator) void {
        for (self.entries.values()) |*owners| owners.deinit(gpa);
        self.entries.deinit(gpa);
    }

    fn lookup(self: *const BoundGlobals, name: hir_mod_ns.StringId, space: binder.Binder.Space) []const BoundGlobal {
        return if (self.entries.get(.{ .name = name, .space = space })) |owners| owners.items else &.{};
    }

    /// Compatibility projections for the checker's existing presence-only
    /// inputs. Keep the typed declaration owners in the index: these slices
    /// are not a substitute for resolving their actual types.
    fn names(self: *const BoundGlobals, gpa: std.mem.Allocator, strings: *const StringInterner, comptime kind: enum { vars, types }) ![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |name| gpa.free(name);
            out.deinit(gpa);
        }
        var seen: std.AutoHashMapUnmanaged(hir_mod_ns.StringId, void) = .empty;
        defer seen.deinit(gpa);
        for (self.entries.keys(), self.entries.values()) |key, owners| {
            if (kind == .vars) {
                if (key.space != .value) continue;
                var is_var = false;
                for (owners.items) |owner| is_var = is_var or owner.symbol.flags.is_var;
                if (!is_var) continue;
            } else if (key.space == .value) continue;
            const entry = try seen.getOrPut(gpa, key.name);
            if (entry.found_existing) continue;
            const name = try gpa.dupe(u8, strings.get(key.name));
            errdefer gpa.free(name);
            try out.append(gpa, name);
        }
        return try out.toOwnedSlice(gpa);
    }
};

pub const Program = struct {
    gpa: std.mem.Allocator,
    /// All source owners use this name keyspace, but retain independent HIR,
    /// symbols and type pools. Initialize before launching any workers.
    strings: ?StringInterner = null,
    /// Checked source revisions and their declaration provenance. Owner IDs
    /// are never reused during the Program lifetime.
    owners: source_owners.Registry,
    /// Parallel checking publishes completed owners concurrently. The
    /// registry's append-only identity tables require exclusive mutation.
    owners_mutex: OwnerMutex = .{},
    files: std.ArrayListUnmanaged(*File),
    by_path: std.StringHashMapUnmanaged(FileId),
    by_package_id: std.StringHashMapUnmanaged(FileId),
    deduplicate_packages: bool,
    resolver: *ts_resolver.Resolver,
    /// Stored sources keyed by path (we own the dupes).
    sources: std.StringHashMapUnmanaged([]const u8),

    pub fn init(gpa: std.mem.Allocator, resolver: *ts_resolver.Resolver) Program {
        return .{
            .gpa = gpa,
            .owners = source_owners.Registry.init(gpa),
            .files = .empty,
            .by_path = .empty,
            .by_package_id = .empty,
            .deduplicate_packages = true,
            .resolver = resolver,
            .sources = .empty,
        };
    }

    pub fn deinit(self: *Program) void {
        for (self.files.items) |f| {
            self.dropCompilation(f);
            f.imports.deinit(self.gpa);
            if (f.include_reason) |ir| {
                if (ir.specifier_text.len != 0) self.gpa.free(ir.specifier_text);
                if (ir.package_id.len != 0) self.gpa.free(ir.package_id);
                if (ir.project_reference_output.len != 0) self.gpa.free(ir.project_reference_output);
            }
            self.gpa.free(f.path);
            self.gpa.destroy(f);
        }
        self.files.deinit(self.gpa);
        self.owners.deinit();
        if (self.strings) |*strings| strings.deinit();

        var it = self.by_path.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.by_path.deinit(self.gpa);

        var pit = self.by_package_id.iterator();
        while (pit.next()) |e| self.gpa.free(e.key_ptr.*);
        self.by_package_id.deinit(self.gpa);

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
            .owner = .none,
            .imports = .empty,
            .is_declaration = isDeclarationPath(path),
            .is_tsx = std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".jsx"),
            .package_type_module = self.resolver.containingPackageIsTypeModule(path),
            .include_reason = null,
            .redirect_target = null,
        };

        try self.files.append(self.gpa, file);

        const key = try self.gpa.dupe(u8, path);
        try self.by_path.put(self.gpa, key, id);

        const skey = try self.gpa.dupe(u8, path);
        try self.sources.put(self.gpa, skey, owned_source);

        return id;
    }

    fn addRedirectFile(self: *Program, path: []const u8, target_id: FileId) ProgramError!FileId {
        if (self.by_path.get(path)) |id| return id;

        const target = self.files.items[target_id];
        const owned_path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned_path);

        const id: FileId = @intCast(self.files.items.len);
        const file = try self.gpa.create(File);
        errdefer self.gpa.destroy(file);
        file.* = .{
            .id = id,
            .path = owned_path,
            .source = target.source,
            .compilation = null,
            .owner = .none,
            .imports = .empty,
            .is_declaration = target.is_declaration,
            .is_tsx = target.is_tsx,
            .package_type_module = target.package_type_module,
            .include_reason = null,
            .redirect_target = target_id,
        };

        try self.files.append(self.gpa, file);

        const key = try self.gpa.dupe(u8, path);
        try self.by_path.put(self.gpa, key, id);

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
        self.dropCompilation(f);
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
        f.source_markers = null;
        f.imports.clearRetainingCapacity();
        return id;
    }

    pub fn lookupPath(self: *const Program, path: []const u8) ?FileId {
        return self.by_path.get(path);
    }

    fn prepareSourceMarkers(self: *Program) void {
        for (self.files.items) |file| {
            file.source_markers = if (file.redirect_target != null)
                null
            else if (file.compilation) |compilation|
                .{ .borrowed = &compilation.source_markers }
            else
                .{ .owned = ProgramSourceMarkerIndex.scan(file.source) };
        }
    }

    fn clearSourceMarkers(self: *Program) void {
        for (self.files.items) |file| file.source_markers = null;
    }

    fn needsCompilation(f: *const File, options: ts_driver.CompileOptions) bool {
        if (f.redirect_target != null) return false;
        const c = f.compilation orelse return true;
        return !options.bind_only and (c.check_state == .bound or c.check_state == .unavailable);
    }

    fn dropCompilation(self: *Program, f: *File) void {
        f.source_markers = null;
        if (f.owner != .none) {
            self.owners_mutex.lock();
            defer self.owners_mutex.unlock();
            self.owners.unregister(f.owner) catch unreachable;
            f.owner = .none;
        }
        if (f.compilation) |compilation| {
            compilation.deinit();
            self.gpa.destroy(compilation);
            f.compilation = null;
        }
    }

    fn prepareNameStore(self: *Program) ProgramError!void {
        if (self.strings == null) {
            self.strings = StringInterner.init(self.gpa) catch return error.OutOfMemory;
        }
    }

    fn prepareFiles(self: *Program, options: ts_driver.CompileOptions) ProgramError!void {
        var bind_options = options;
        bind_options.bind_only = true;
        for (self.files.items) |f| {
            if (needsCompilation(f, bind_options)) try self.compileFile(f, bind_options);
        }
    }

    fn collectBoundGlobals(self: *const Program) ProgramError!BoundGlobals {
        var index: BoundGlobals = .{};
        errdefer index.deinit(self.gpa);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            const c = f.compilation orelse continue;
            if (boundSourceIsExternalModule(c)) continue;
            // Binder insertion order is deterministic within each file, even
            // when files were prepared in parallel. All merged declarations
            // remain reachable through their original symbol and source.
            for (c.module.symbols.items) |symbol| {
                if (symbol.parent_scope != c.module.root) continue;
                for ([_]binder.Binder.Space{ .value, .type, .namespace }) |space| {
                    const map = switch (space) {
                        .value => &c.module.root.values,
                        .type => &c.module.root.types,
                        .namespace => &c.module.root.namespaces,
                    };
                    if (map.get(symbol.name) != symbol) continue;
                    const entry = try index.entries.getOrPut(self.gpa, .{ .name = symbol.name, .space = space });
                    if (!entry.found_existing) entry.value_ptr.* = .empty;
                    try entry.value_ptr.append(self.gpa, .{ .file = f, .symbol = symbol });
                }
            }
        }
        return index;
    }

    fn boundSourceIsExternalModule(c: *const ts_driver.Compilation) bool {
        if (c.root == hir_mod_ns.none_node_id) return false;
        for (hir_mod_ns.blockStmts(&c.hir, c.root)) |stmt| {
            switch (c.hir.kindOf(stmt)) {
                .export_decl => return true,
                .import_decl => {
                    const imp = hir_mod_ns.importOf(&c.hir, stmt);
                    // An internal `import Alias = Namespace.Member` does
                    // not turn a script into an external module.
                    if (imp.import_equals == hir_mod_ns.none_node_id or imp.is_export) return true;
                },
                else => {},
            }
        }
        for (c.hir.kinds.items) |kind| if (kind == .import_meta) return true;
        return false;
    }

    /// All execution modes share the same per-file identity and lifecycle.
    /// A failed check cannot leave a partially checked source available for
    /// retry; successful preparation preserves the actual binder/HIR owner.
    fn compileFile(self: *Program, f: *File, options: ts_driver.CompileOptions) ts_driver.CompileError!void {
        var per_file = options;
        per_file.shared_strings = &self.strings.?;
        per_file.is_tsx = options.is_tsx or f.is_tsx;
        per_file.package_type_module = f.package_type_module;
        per_file.is_declaration_file = f.is_declaration;
        per_file.file_id = f.id;
        per_file.suppress_import_helper_diagnostics = true;
        if (per_file.importer_path.len == 0) per_file.importer_path = f.path;
        if (f.compilation == null) f.compilation = try ts_driver.prepareSource(self.gpa, f.source, per_file);
        const c = f.compilation.?;
        errdefer self.dropCompilation(f);
        if (!options.bind_only) {
            try ts_driver.checkPreparedSource(c, per_file);
            std.debug.assert(f.owner == .none);
            // Scanner recovery can produce a diagnostic-bearing result
            // without a typed HIR. Such a file has no checked owner.
            const source = c.sourceOwner(f.path) catch return;
            self.owners_mutex.lock();
            defer self.owners_mutex.unlock();
            f.owner = self.owners.register(source) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.EmitError,
            };
        }
    }

    /// Compile every file after resolving the complete bound dependency graph.
    pub fn compileAll(self: *Program, options: ts_driver.CompileOptions) ProgramError!void {
        try self.prepareNameStore();
        self.deduplicate_packages = options.deduplicate_packages;
        if (options.bind_only) {
            try self.prepareFiles(options);
            try self.resolveImports();
            return;
        }
        try self.prepareFiles(options);
        // Checked CommonJS owner types must exist before a requiring consumer
        // is checked. The bound graph is complete at this point, so establish
        // dependency order without reparsing or a second checker pass.
        try self.resolveImports();
        const compilation_order = try self.dependencyOrder();
        defer self.gpa.free(compilation_order);
        var globals = try self.collectBoundGlobals();
        defer globals.deinit(self.gpa);
        self.prepareSourceMarkers();
        defer self.clearSourceMarkers();
        self.deduplicate_packages = options.deduplicate_packages;
        const ambient_global_namespace_roots = try self.collectAmbientGlobalNamespaceRoots();
        defer freeStringSlice(self.gpa, ambient_global_namespace_roots);
        const script_object_expandos = try self.collectScriptObjectExpandos();
        defer self.gpa.free(script_object_expandos);
        const program_global_var_names = try globals.names(self.gpa, &self.strings.?, .vars);
        defer freeStringSlice(self.gpa, program_global_var_names);
        const program_global_type_names = try globals.names(self.gpa, &self.strings.?, .types);
        defer freeStringSlice(self.gpa, program_global_type_names);
        const module_interface_augmentations = try self.collectRelativeModuleInterfaceAugmentations();
        defer self.gpa.free(module_interface_augmentations);
        const program_exported_classes = try self.collectProgramExportedClasses();
        defer freeProgramExportedClasses(self.gpa, program_exported_classes);
        var declarations = try self.collectProgramDeclarationsForChecking();
        defer declarations.deinit();
        const program_ambient_module_interface_exports = try self.collectAmbientModuleInterfaceExports();
        defer freeProgramAmbientModuleInterfaceExports(self.gpa, program_ambient_module_interface_exports);
        const program_commonjs_exports = try self.collectProgramCommonJsExports();
        defer freeProgramCommonJsExports(self.gpa, program_commonjs_exports);
        const program_umd_globals = try self.collectProgramUmdGlobals();
        defer freeProgramUmdGlobals(self.gpa, program_umd_globals);
        const merged_program_umd_globals = try mergeProgramUmdGlobals(self.gpa, program_umd_globals, options.program_umd_globals);
        defer self.gpa.free(merged_program_umd_globals);
        const known_reference_paths = try self.gpa.alloc([]const u8, self.files.items.len + options.known_reference_paths.len);
        defer self.gpa.free(known_reference_paths);
        for (self.files.items, 0..) |f, i| known_reference_paths[i] = f.path;
        for (options.known_reference_paths, 0..) |path, i| known_reference_paths[self.files.items.len + i] = path;
        for (compilation_order) |file_index| {
            const f = self.files.items[file_index];
            if (f.redirect_target != null) continue;
            if (!needsCompilation(f, options)) continue;
            var per_file = options;
            per_file.is_tsx = options.is_tsx or f.is_tsx;
            per_file.package_type_module = f.package_type_module;
            per_file.ambient_global_namespace_roots = ambient_global_namespace_roots;
            per_file.script_object_expandos = script_object_expandos;
            per_file.program_global_var_names = program_global_var_names;
            per_file.program_global_type_names = program_global_type_names;
            per_file.module_interface_augmentations = module_interface_augmentations;
            per_file.program_exported_classes = program_exported_classes;
            per_file.program_exported_values = declarations.values;
            per_file.program_exported_types = declarations.types;
            per_file.program_ambient_module_interface_exports = program_ambient_module_interface_exports;
            per_file.program_commonjs_exports = program_commonjs_exports;
            per_file.program_umd_globals = merged_program_umd_globals;
            per_file.known_reference_paths = known_reference_paths;
            per_file.suppress_import_helper_diagnostics = true;
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
            try self.compileFile(f, per_file);
            try self.populateProgramCommonJsExportSchemas(f, @constCast(program_commonjs_exports));
        }

        try self.appendMissingCompilerTypeReferenceDiagnostics(options);
        try self.appendMissingImportedHelperDiagnostics(options);
        try self.appendRootDirDiagnostics(options);
        try self.appendProgramGlobalDeclareVarDiagnostics();
        try self.appendProgramGlobalInterfaceMemberDiagnostics();
        try self.appendMergedAmbientModuleExportDiagnostics();
    }

    fn dependencyOrder(self: *const Program) ProgramError![]const usize {
        const states = try self.gpa.alloc(u2, self.files.items.len);
        defer self.gpa.free(states);
        @memset(states, 0);
        var order: std.ArrayListUnmanaged(usize) = .empty;
        errdefer order.deinit(self.gpa);
        for (self.files.items, 0..) |_, index| try self.appendDependencyOrder(index, states, &order);
        return order.toOwnedSlice(self.gpa);
    }

    fn appendDependencyOrder(
        self: *const Program,
        index: usize,
        states: []u2,
        order: *std.ArrayListUnmanaged(usize),
    ) ProgramError!void {
        if (states[index] == 2) return;
        if (states[index] == 1) return;
        states[index] = 1;
        for (self.files.items[index].imports.items) |dependency| {
            if (dependency < self.files.items.len) try self.appendDependencyOrder(dependency, states, order);
        }
        states[index] = 2;
        try order.append(self.gpa, index);
    }

    /// Explicitly invalidate and recompile all sources, e.g. after options
    /// change. Closure discovery itself no longer needs this reparsing pass.
    pub fn recompileAll(self: *Program, options: ts_driver.CompileOptions) ProgramError!void {
        for (self.files.items) |file| {
            self.dropCompilation(file);
            file.imports.clearRetainingCapacity();
        }
        try self.compileAll(options);
    }

    fn appendMissingCompilerTypeReferenceDiagnostics(
        self: *Program,
        options: ts_driver.CompileOptions,
    ) ProgramError!void {
        if (options.compiler_type_reference_names.len == 0) return;
        var host: ?*ts_driver.Compilation = null;
        var containing_file: []const u8 = "";
        for (self.files.items) |file| {
            if (file.compilation) |compilation| {
                host = compilation;
                containing_file = file.path;
                break;
            }
        }
        const compilation = host orelse return;
        for (options.compiler_type_reference_names) |name| {
            if (name.len == 0) continue;
            _ = self.resolver.resolveTypeReferenceDirective(name, containing_file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const message = try std.fmt.allocPrint(
                        self.gpa,
                        "Cannot find type definition file for '{s}'.",
                        .{name},
                    );
                    var duplicate = false;
                    for (compilation.diagnostics.items) |diagnostic| {
                        if (diagnostic.code == 2688 and std.mem.eql(u8, diagnostic.message, message)) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) {
                        self.gpa.free(message);
                        continue;
                    }
                    compilation.diagnostics.append(self.gpa, .{
                        .phase = .bind,
                        .pos = 0,
                        .line = 1,
                        .code = 2688,
                        .is_global = true,
                        .message = message,
                    }) catch |append_err| {
                        self.gpa.free(message);
                        return append_err;
                    };
                    compilation.has_errors = true;
                },
            };
        }
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
        try self.prepareNameStore();
        try self.prepareFiles(options);
        try self.resolveImports();
        const compilation_order = try self.dependencyOrder();
        defer self.gpa.free(compilation_order);
        var globals = try self.collectBoundGlobals();
        defer globals.deinit(self.gpa);
        self.prepareSourceMarkers();
        defer self.clearSourceMarkers();
        const ambient_global_namespace_roots = try self.collectAmbientGlobalNamespaceRoots();
        defer freeStringSlice(self.gpa, ambient_global_namespace_roots);
        const script_object_expandos = try self.collectScriptObjectExpandos();
        defer self.gpa.free(script_object_expandos);
        const program_global_var_names = try globals.names(self.gpa, &self.strings.?, .vars);
        defer freeStringSlice(self.gpa, program_global_var_names);
        const program_global_type_names = try globals.names(self.gpa, &self.strings.?, .types);
        defer freeStringSlice(self.gpa, program_global_type_names);
        const module_interface_augmentations = try self.collectRelativeModuleInterfaceAugmentations();
        defer self.gpa.free(module_interface_augmentations);
        const program_exported_classes = try self.collectProgramExportedClasses();
        defer freeProgramExportedClasses(self.gpa, program_exported_classes);
        var declarations = try self.collectProgramDeclarationsForChecking();
        defer declarations.deinit();
        const program_ambient_module_interface_exports = try self.collectAmbientModuleInterfaceExports();
        defer freeProgramAmbientModuleInterfaceExports(self.gpa, program_ambient_module_interface_exports);
        const program_commonjs_exports = try self.collectProgramCommonJsExports();
        defer freeProgramCommonJsExports(self.gpa, program_commonjs_exports);
        const program_umd_globals = try self.collectProgramUmdGlobals();
        defer freeProgramUmdGlobals(self.gpa, program_umd_globals);
        const merged_program_umd_globals = try mergeProgramUmdGlobals(self.gpa, program_umd_globals, options.program_umd_globals);
        defer self.gpa.free(merged_program_umd_globals);
        const known_reference_paths = try self.gpa.alloc([]const u8, self.files.items.len + options.known_reference_paths.len);
        defer self.gpa.free(known_reference_paths);
        for (self.files.items, 0..) |f, i| known_reference_paths[i] = f.path;
        for (options.known_reference_paths, 0..) |path, i| known_reference_paths[self.files.items.len + i] = path;
        for (compilation_order) |file_index| {
            const f = self.files.items[file_index];
            if (f.redirect_target != null) continue;
            if (!needsCompilation(f, options)) {
                // Already compiled — replay its diagnostics anyway so
                // a streaming consumer that joined late doesn't miss
                // them.
                callback(ctx, f.path, f.compilation.?.diagnostics.items);
                continue;
            }
            var per_file = options;
            per_file.is_tsx = options.is_tsx or f.is_tsx;
            per_file.package_type_module = f.package_type_module;
            per_file.is_declaration_file = f.is_declaration;
            per_file.ambient_global_namespace_roots = ambient_global_namespace_roots;
            per_file.script_object_expandos = script_object_expandos;
            per_file.program_global_var_names = program_global_var_names;
            per_file.program_global_type_names = program_global_type_names;
            per_file.module_interface_augmentations = module_interface_augmentations;
            per_file.program_exported_classes = program_exported_classes;
            per_file.program_exported_values = declarations.values;
            per_file.program_exported_types = declarations.types;
            per_file.program_ambient_module_interface_exports = program_ambient_module_interface_exports;
            per_file.program_commonjs_exports = program_commonjs_exports;
            per_file.program_umd_globals = merged_program_umd_globals;
            per_file.known_reference_paths = known_reference_paths;
            per_file.suppress_import_helper_diagnostics = true;
            if (per_file.importer_path.len == 0) per_file.importer_path = f.path;
            try self.compileFile(f, per_file);
            try self.populateProgramCommonJsExportSchemas(f, @constCast(program_commonjs_exports));
            callback(ctx, f.path, f.compilation.?.diagnostics.items);
        }

        try self.appendProgramGlobalInterfaceMemberDiagnostics();
        try self.appendRootDirDiagnostics(options);
    }

    fn collectAmbientGlobalNamespaceRoots(self: *const Program) ProgramError![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer freeStringSlice(self.gpa, out.items);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            if (!f.sourceContains("namespace") and
                !f.sourceContains("module") and
                !f.sourceContains("global")) continue;
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
            if (f.redirect_target != null) continue;
            if (!f.sourceContains("namespace") and
                !f.sourceContains("module")) continue;
            try collectTopLevelNamespaceRootSlices(self.gpa, f.source, &namespace_roots);
        }
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            if (!isJsLikePath(f.path)) continue;
            try collectQualifiedJsDocTypedefs(self.gpa, f.source, &out);
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

    fn collectRelativeModuleInterfaceAugmentations(self: *const Program) ProgramError![]const ts_driver.ModuleInterfaceAugmentation {
        var out: std.ArrayListUnmanaged(ts_driver.ModuleInterfaceAugmentation) = .empty;
        errdefer out.deinit(self.gpa);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            if (!f.sourceContains("declare") or
                !f.sourceContains("module") or
                !f.sourceContains("interface")) continue;
            try self.collectRelativeModuleInterfaceAugmentationsFromSource(f.path, f.source, &out);
        }
        return try out.toOwnedSlice(self.gpa);
    }

    fn collectProgramExportedClasses(self: *const Program) ProgramError![]const ts_driver.ProgramExportedClass {
        var has_class = false;
        for (self.files.items) |file| {
            if (file.redirect_target == null and file.sourceContains("class")) {
                has_class = true;
                break;
            }
        }
        if (!has_class) return &.{};
        var sources: std.ArrayListUnmanaged(class_declarations.Source) = .empty;
        defer sources.deinit(self.gpa);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            // Every execution mode prepares bound owners before collecting
            // cross-file declarations. Do not reparse or omit missing owners.
            const compilation = f.compilation orelse unreachable;
            try sources.append(self.gpa, .{ .path = f.path, .compilation = compilation });
        }
        const classes = class_declarations.collect(self.gpa, self.resolver, sources.items) catch return error.OutOfMemory;
        var out: std.ArrayListUnmanaged(ts_driver.ProgramExportedClass) = .{ .items = @constCast(classes), .capacity = classes.len };
        errdefer freeProgramExportedClasses(self.gpa, out.items);
        var namespace_augmentations: std.ArrayListUnmanaged(ProgramNamespaceStaticAugmentation) = .empty;
        defer {
            for (namespace_augmentations.items) |aug| {
                self.gpa.free(aug.target_path);
                if (aug.members.len > 0) self.gpa.free(aug.members);
            }
            namespace_augmentations.deinit(self.gpa);
        }
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            if (!f.sourceContains("declare") or
                !f.sourceContains("module") or
                !f.sourceContains("namespace")) continue;
            try collectRelativeModuleNamespaceStaticAugmentationsFromSource(self.gpa, f.path, f.source, &namespace_augmentations);
        }
        for (out.items) |*class| {
            var extra_count: usize = 0;
            for (namespace_augmentations.items) |aug| {
                if (!std.mem.eql(u8, aug.class_name, class.class_name)) continue;
                if (!programModulePathMatches(aug.target_path, if (class.declaration_path.len > 0) class.declaration_path else class.target_path)) continue;
                extra_count += aug.members.len;
            }
            if (extra_count == 0) continue;
            var merged: std.ArrayListUnmanaged(ts_driver.ProgramExportedClassMember) = .empty;
            defer merged.deinit(self.gpa);
            try merged.appendSlice(self.gpa, class.static_members);
            for (namespace_augmentations.items) |aug| {
                if (!std.mem.eql(u8, aug.class_name, class.class_name)) continue;
                if (!programModulePathMatches(aug.target_path, if (class.declaration_path.len > 0) class.declaration_path else class.target_path)) continue;
                try merged.appendSlice(self.gpa, aug.members);
            }
            const owned = try merged.toOwnedSlice(self.gpa);
            if (class.static_members.len > 0) self.gpa.free(class.static_members);
            class.static_members = owned;
        }
        return try out.toOwnedSlice(self.gpa);
    }

    fn collectProgramDeclarations(self: *Program) ProgramError!declaration_graph.Graph {
        var sources: std.ArrayListUnmanaged(declaration_graph.Source) = .empty;
        defer sources.deinit(self.gpa);
        for (self.files.items) |file| {
            if (file.redirect_target != null) continue;
            try sources.append(self.gpa, .{ .path = file.path, .compilation = file.compilation orelse unreachable });
        }
        return declaration_graph.collect(self.gpa, self.resolver, sources.items) catch return error.OutOfMemory;
    }

    /// Program declaration schemas transfer types across resolved file
    /// boundaries. A dependency-free program has no consumer for them: local
    /// declarations are checked from their owner's HIR, while global scripts
    /// and CommonJS use their dedicated program facts. Keep the full collector
    /// available for callers that explicitly request an export snapshot.
    fn collectProgramDeclarationsForChecking(self: *Program) ProgramError!declaration_graph.Graph {
        for (self.files.items) |file| {
            if (file.redirect_target == null and file.imports.items.len != 0)
                return self.collectProgramDeclarations();
        }
        return declaration_graph.Graph.init(self.gpa);
    }

    fn collectAmbientModuleInterfaceExports(self: *const Program) ProgramError![]const ts_driver.ProgramAmbientModuleInterfaceExport {
        var out: std.ArrayListUnmanaged(ts_driver.ProgramAmbientModuleInterfaceExport) = .empty;
        errdefer {
            for (out.items) |item| {
                self.gpa.free(item.specifier);
                self.gpa.free(item.name);
                self.gpa.free(item.module_path);
                self.gpa.free(item.namespace_path);
                freeProgramAmbientInterfaceMembers(self.gpa, item.members);
            }
            out.deinit(self.gpa);
        }
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            if (!f.sourceContains("declare") or
                !f.sourceContains("interface") or
                (!f.sourceContains("module") and
                    !f.sourceContains("global"))) continue;
            try collectAmbientModuleInterfaceExportsFromSource(self.gpa, f.source, &out);
        }
        try self.collectExportedNamespaceInterfaces(&out);
        try self.propagateExportedNamespaceInterfacesThroughStars(&out);
        return try out.toOwnedSlice(self.gpa);
    }

    fn collectExportedNamespaceInterfaces(
        self: *const Program,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramAmbientModuleInterfaceExport),
    ) ProgramError!void {
        for (self.files.items) |file| {
            if (file.redirect_target != null) continue;
            if (!file.sourceContains("export") or
                !file.sourceContains("interface") or
                (!file.sourceContains("namespace") and
                    !file.sourceContains("module"))) continue;
            try collectExportedNamespaceInterfacesFromSource(self.gpa, file.path, file.source, out);
        }
    }

    fn propagateExportedNamespaceInterfacesThroughStars(
        self: *const Program,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramAmbientModuleInterfaceExport),
    ) ProgramError!void {
        if (out.items.len == 0) return;
        var changed = true;
        while (changed) {
            changed = false;
            for (self.files.items) |file| {
                if (file.redirect_target != null) continue;
                var stars = try relativeExportStarSpecifiers(self.gpa, file.source);
                defer stars.deinit(self.gpa);
                for (stars.items) |specifier| {
                    const target_path = try resolveProgramRelativeModulePath(self.gpa, file.path, specifier);
                    defer self.gpa.free(target_path);
                    const candidate_count = out.items.len;
                    var index: usize = 0;
                    while (index < candidate_count) : (index += 1) {
                        const exported = out.items[index];
                        if (exported.module_path.len == 0 or
                            !programModulePathMatches(exported.module_path, target_path) or
                            programNamespaceInterfaceExists(out.items, file.path, exported.namespace_path, exported.name))
                        {
                            continue;
                        }
                        try appendProgramNamespaceInterface(
                            self.gpa,
                            file.path,
                            exported.namespace_path,
                            exported.name,
                            exported.members,
                            out,
                        );
                        changed = true;
                    }
                }
            }
        }
    }

    fn collectExportedNamespaceInterfacesFromSource(
        gpa: std.mem.Allocator,
        module_path: []const u8,
        source: []const u8,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramAmbientModuleInterfaceExport),
    ) ProgramError!void {
        var index: usize = 0;
        var depth: usize = 0;
        while (index < source.len) {
            if (skipProgramCommentOrString(source, index, source.len)) |next| {
                index = next;
                continue;
            }
            switch (source[index]) {
                '{' => depth += 1,
                '}' => if (depth > 0) {
                    depth -= 1;
                },
                else => {},
            }
            if (depth != 0 or !identifierKeywordAt(source, index, "export")) {
                index += 1;
                continue;
            }
            var cursor = skipProgramTrivia(source, index + "export".len, source.len);
            if (identifierKeywordAt(source, cursor, "declare")) {
                cursor = skipProgramTrivia(source, cursor + "declare".len, source.len);
            }
            const keyword_len: usize = if (identifierKeywordAt(source, cursor, "namespace"))
                "namespace".len
            else if (identifierKeywordAt(source, cursor, "module"))
                "module".len
            else {
                index += "export".len;
                continue;
            };
            const name_start = skipProgramTrivia(source, cursor + keyword_len, source.len);
            const name_end = parseIdentifierEnd(source, name_start, source.len) orelse {
                index += "export".len;
                continue;
            };
            const body_open = std.mem.indexOfScalarPos(u8, source, name_end, '{') orelse break;
            const body_close = findMatchingBrace(source, body_open) orelse break;
            const namespace_path = source[name_start..name_end];
            try collectExportedNamespaceBody(
                gpa,
                module_path,
                source,
                body_open + 1,
                body_close,
                namespace_path,
                out,
            );
            index = body_close + 1;
        }
    }

    fn collectExportedNamespaceBody(
        gpa: std.mem.Allocator,
        module_path: []const u8,
        source: []const u8,
        body_start: usize,
        body_end: usize,
        namespace_path: []const u8,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramAmbientModuleInterfaceExport),
    ) ProgramError!void {
        var index = body_start;
        var depth: usize = 0;
        while (index < body_end) {
            if (skipProgramCommentOrString(source, index, body_end)) |next| {
                index = next;
                continue;
            }
            switch (source[index]) {
                '{' => depth += 1,
                '}' => if (depth > 0) {
                    depth -= 1;
                },
                else => {},
            }
            if (depth != 0 or !identifierKeywordAt(source, index, "export")) {
                index += 1;
                continue;
            }
            var cursor = skipProgramTrivia(source, index + "export".len, body_end);
            if (identifierKeywordAt(source, cursor, "declare")) {
                cursor = skipProgramTrivia(source, cursor + "declare".len, body_end);
            }
            if (identifierKeywordAt(source, cursor, "interface")) {
                const name_start = skipProgramTrivia(source, cursor + "interface".len, body_end);
                const name_end = parseIdentifierEnd(source, name_start, body_end) orelse {
                    index += "export".len;
                    continue;
                };
                const iface_open = std.mem.indexOfScalarPos(u8, source, name_end, '{') orelse break;
                const iface_close = findMatchingBrace(source, iface_open) orelse break;
                if (iface_close > body_end) break;
                const members = try collectAmbientInterfaceMembers(gpa, source, iface_open + 1, iface_close);
                appendProgramNamespaceInterface(
                    gpa,
                    module_path,
                    namespace_path,
                    source[name_start..name_end],
                    members,
                    out,
                ) catch |err| {
                    freeProgramAmbientInterfaceMembers(gpa, members);
                    return err;
                };
                freeProgramAmbientInterfaceMembers(gpa, members);
                index = iface_close + 1;
                continue;
            }
            const keyword_len: usize = if (identifierKeywordAt(source, cursor, "namespace"))
                "namespace".len
            else if (identifierKeywordAt(source, cursor, "module"))
                "module".len
            else {
                index += "export".len;
                continue;
            };
            const name_start = skipProgramTrivia(source, cursor + keyword_len, body_end);
            const name_end = parseIdentifierEnd(source, name_start, body_end) orelse {
                index += "export".len;
                continue;
            };
            const nested_open = std.mem.indexOfScalarPos(u8, source, name_end, '{') orelse break;
            const nested_close = findMatchingBrace(source, nested_open) orelse break;
            if (nested_close > body_end) break;
            const nested_path = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ namespace_path, source[name_start..name_end] });
            defer gpa.free(nested_path);
            try collectExportedNamespaceBody(
                gpa,
                module_path,
                source,
                nested_open + 1,
                nested_close,
                nested_path,
                out,
            );
            index = nested_close + 1;
        }
    }

    fn appendProgramNamespaceInterface(
        gpa: std.mem.Allocator,
        module_path: []const u8,
        namespace_path: []const u8,
        name: []const u8,
        source_members: []const ts_driver.ProgramAmbientInterfaceMember,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramAmbientModuleInterfaceExport),
    ) ProgramError!void {
        const specifier_copy = try gpa.dupe(u8, "");
        errdefer gpa.free(specifier_copy);
        const module_path_copy = try gpa.dupe(u8, module_path);
        errdefer gpa.free(module_path_copy);
        const namespace_path_copy = try gpa.dupe(u8, namespace_path);
        errdefer gpa.free(namespace_path_copy);
        const name_copy = try gpa.dupe(u8, name);
        errdefer gpa.free(name_copy);
        const members = try cloneProgramAmbientInterfaceMembers(gpa, source_members);
        errdefer freeProgramAmbientInterfaceMembers(gpa, members);
        try out.append(gpa, .{
            .specifier = specifier_copy,
            .name = name_copy,
            .members = members,
            .module_path = module_path_copy,
            .namespace_path = namespace_path_copy,
        });
    }

    fn cloneProgramAmbientInterfaceMembers(
        gpa: std.mem.Allocator,
        source_members: []const ts_driver.ProgramAmbientInterfaceMember,
    ) ProgramError![]const ts_driver.ProgramAmbientInterfaceMember {
        var members: std.ArrayListUnmanaged(ts_driver.ProgramAmbientInterfaceMember) = .empty;
        errdefer freeProgramAmbientInterfaceMembers(gpa, members.items);
        for (source_members) |member| {
            const cloned = try cloneProgramAmbientInterfaceMember(gpa, member);
            members.append(gpa, cloned) catch {
                gpa.free(cloned.name);
                gpa.free(cloned.type_name);
                return error.OutOfMemory;
            };
        }
        return try members.toOwnedSlice(gpa);
    }

    fn cloneProgramAmbientInterfaceMember(
        gpa: std.mem.Allocator,
        member: ts_driver.ProgramAmbientInterfaceMember,
    ) ProgramError!ts_driver.ProgramAmbientInterfaceMember {
        const name = try gpa.dupe(u8, member.name);
        errdefer gpa.free(name);
        const type_name = try gpa.dupe(u8, member.type_name);
        return .{
            .name = name,
            .type_name = type_name,
            .is_optional = member.is_optional,
            .is_readonly = member.is_readonly,
            .is_method = member.is_method,
        };
    }

    fn programNamespaceInterfaceExists(
        items: []const ts_driver.ProgramAmbientModuleInterfaceExport,
        module_path: []const u8,
        namespace_path: []const u8,
        name: []const u8,
    ) bool {
        for (items) |item| {
            if (programModulePathMatches(item.module_path, module_path) and
                std.mem.eql(u8, item.namespace_path, namespace_path) and
                std.mem.eql(u8, item.name, name))
            {
                return true;
            }
        }
        return false;
    }

    fn relativeExportStarSpecifiers(
        gpa: std.mem.Allocator,
        source: []const u8,
    ) ProgramError!std.ArrayListUnmanaged([]const u8) {
        var result: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer result.deinit(gpa);
        var index: usize = 0;
        var depth: usize = 0;
        while (index < source.len) {
            if (skipProgramCommentOrString(source, index, source.len)) |next| {
                index = next;
                continue;
            }
            switch (source[index]) {
                '{' => depth += 1,
                '}' => if (depth > 0) {
                    depth -= 1;
                },
                else => {},
            }
            if (depth != 0 or !identifierKeywordAt(source, index, "export")) {
                index += 1;
                continue;
            }
            var cursor = skipProgramTrivia(source, index + "export".len, source.len);
            if (cursor >= source.len or source[cursor] != '*') {
                index += "export".len;
                continue;
            }
            cursor = skipProgramTrivia(source, cursor + 1, source.len);
            if (!identifierKeywordAt(source, cursor, "from")) {
                index += "export".len;
                continue;
            }
            cursor = skipProgramTrivia(source, cursor + "from".len, source.len);
            if (cursor >= source.len or (source[cursor] != '"' and source[cursor] != '\'')) {
                index += "export".len;
                continue;
            }
            const quote = source[cursor];
            const spec_start = cursor + 1;
            const spec_end = std.mem.indexOfScalarPos(u8, source, spec_start, quote) orelse break;
            const specifier = source[spec_start..spec_end];
            if (std.mem.startsWith(u8, specifier, ".")) try result.append(gpa, specifier);
            index = spec_end + 1;
        }
        return result;
    }

    fn skipProgramTrivia(source: []const u8, start: usize, limit: usize) usize {
        var index = start;
        while (index < limit) {
            if (std.ascii.isWhitespace(source[index])) {
                index += 1;
                continue;
            }
            if (index + 1 < limit and source[index] == '/' and source[index + 1] == '/') {
                index += 2;
                while (index < limit and source[index] != '\n' and source[index] != '\r') : (index += 1) {}
                continue;
            }
            if (index + 1 < limit and source[index] == '/' and source[index + 1] == '*') {
                index += 2;
                while (index + 1 < limit and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {}
                index = @min(index + 2, limit);
                continue;
            }
            break;
        }
        return index;
    }

    fn skipProgramCommentOrString(source: []const u8, start: usize, limit: usize) ?usize {
        if (start >= limit) return null;
        if (start + 1 < limit and source[start] == '/' and source[start + 1] == '/') {
            var index = start + 2;
            while (index < limit and source[index] != '\n' and source[index] != '\r') : (index += 1) {}
            return index;
        }
        if (start + 1 < limit and source[start] == '/' and source[start + 1] == '*') {
            var index = start + 2;
            while (index + 1 < limit and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {}
            return @min(index + 2, limit);
        }
        const quote = source[start];
        if (quote != '"' and quote != '\'' and quote != '`') return null;
        var index = start + 1;
        while (index < limit) : (index += 1) {
            if (source[index] == '\\') {
                index = @min(index + 1, limit);
                continue;
            }
            if (source[index] == quote) return index + 1;
        }
        return limit;
    }

    fn collectProgramCommonJsExports(self: *Program) ProgramError![]const ts_driver.ProgramCommonJsExport {
        try self.prepareNameStore();
        try self.prepareFiles(.{
            .bind_only = true,
            .allow_js = true,
            .continue_on_error = true,
            .no_emit = true,
            .suppress_js_check_diagnostics = true,
        });
        var out: std.ArrayListUnmanaged(ts_driver.ProgramCommonJsExport) = .empty;
        errdefer freeProgramCommonJsExports(self.gpa, out.items);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            if (f.is_declaration) {
                // A declaration-file CommonJS export requires `export =`.
                // Avoid reparsing ordinary library declarations when either
                // required token is absent; false positives still take the
                // full syntax-aware path below.
                if (!f.sourceContains("export") or
                    !f.sourceContains("=")) continue;
                const info = moduleExportAssignmentInfo(self.gpa, f.source, f.is_tsx) orelse continue;
                const private_name = info.private_type_name orelse "";
                if (private_name.len == 0 and !info.target_is_any) continue;
                errdefer if (private_name.len > 0) self.gpa.free(private_name);
                const module_path = try self.gpa.dupe(u8, f.path);
                errdefer self.gpa.free(module_path);
                const module_name = if (private_name.len > 0)
                    try renderExternalModulePathDisplayName(self.gpa, f.path)
                else
                    "";
                errdefer if (module_name.len > 0) self.gpa.free(module_name);
                const export_name = try self.gpa.dupe(u8, "");
                errdefer self.gpa.free(export_name);
                try out.append(self.gpa, .{
                    .module_path = module_path,
                    .name = export_name,
                    .private_type_name = private_name,
                    .private_module_name = module_name,
                    .whole_export_is_any = info.target_is_any,
                });
                continue;
            }
            if (!f.sourceContains("exports")) continue;
            // Export-name discovery only reads syntax. All files are already
            // prepared; do not lex, bind and check this source a second time.
            const compilation = f.compilation orelse continue;
            if (compilation.hir.kindOf(compilation.root) != .block_stmt) continue;
            if (moduleRootHasEsmExportSyntax(&compilation.hir, compilation.root)) continue;
            for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |stmt| {
                if (compilation.hir.kindOf(stmt) != .assignment) continue;
                const assignment = hir_mod_ns.assignmentOf(&compilation.hir, stmt);
                if (assignment.op != null or assignment.value == hir_mod_ns.none_node_id) continue;
                const name_text = commonJsExportAssignmentMetadataName(
                    &compilation.hir,
                    &compilation.interner,
                    assignment,
                ) orelse continue;
                var duplicate = false;
                for (out.items) |existing| {
                    if (std.mem.eql(u8, existing.module_path, f.path) and
                        std.mem.eql(u8, existing.name, name_text))
                    {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                const path_copy = try self.gpa.dupe(u8, f.path);
                errdefer self.gpa.free(path_copy);
                const name_copy = try self.gpa.dupe(u8, name_text);
                errdefer self.gpa.free(name_copy);
                try out.append(self.gpa, .{
                    .module_path = path_copy,
                    .name = name_copy,
                });
            }
        }
        for (self.files.items) |file| try self.populateProgramCommonJsExportSchemas(file, out.items);
        return try out.toOwnedSlice(self.gpa);
    }

    fn populateProgramCommonJsExportSchemas(
        self: *Program,
        file: *File,
        exports: []ts_driver.ProgramCommonJsExport,
    ) ProgramError!void {
        var target: ?*ts_driver.ProgramCommonJsExport = null;
        for (exports) |*exported| {
            if (exported.whole_export_schema == null and exported.name.len == 0 and
                std.mem.eql(u8, exported.module_path, file.path))
            {
                target = exported;
                break;
            }
        }
        const exported = target orelse return;
        const compilation = file.compilation orelse return;
        if (!compilation.checked_types_ready or compilation.hir.kindOf(compilation.root) != .block_stmt) return;
        const whole_types = checked_schema.wholeExportTypes(self.gpa, compilation) catch return error.OutOfMemory;
        defer self.gpa.free(whole_types);
        if (whole_types.len == 0) return;
        var position: ?u32 = null;
        for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |statement| {
            if (compilation.hir.kindOf(statement) != .assignment) continue;
            const assignment = hir_mod_ns.assignmentOf(&compilation.hir, statement);
            if (assignment.op != null or assignment.value == hir_mod_ns.none_node_id) continue;
            const name = commonJsExportAssignmentMetadataName(
                &compilation.hir,
                &compilation.interner,
                assignment,
            ) orelse continue;
            if (name.len == 0) {
                position = compilation.hir.spanOf(statement).start;
                break;
            }
        }
        const export_position = position orelse return;
        exported.whole_export_schema = checked_schema.collect(
            self.gpa,
            file.path,
            compilation,
            whole_types,
            export_position,
        ) catch return error.OutOfMemory;
    }

    fn collectProgramUmdGlobals(self: *const Program) ProgramError![]const ts_driver.ProgramUmdGlobal {
        var out: std.ArrayListUnmanaged(ts_driver.ProgramUmdGlobal) = .empty;
        errdefer {
            for (out.items) |item| self.gpa.free(item.name);
            out.deinit(self.gpa);
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.gpa);
        for (self.files.items) |f| {
            if (f.redirect_target != null or !f.is_declaration) continue;
            try collectProgramUmdGlobalsFromSource(self.gpa, f.source, &out, &seen);
        }
        return try out.toOwnedSlice(self.gpa);
    }

    fn collectProgramUmdGlobalsFromSource(
        gpa: std.mem.Allocator,
        source: []const u8,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramUmdGlobal),
        seen: *std.StringHashMapUnmanaged(void),
    ) ProgramError!void {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_start, "export")) |export_pos| {
            search_start = export_pos + "export".len;
            if (!identifierKeywordAt(source, export_pos, "export")) continue;
            var as_pos = export_pos + "export".len;
            while (as_pos < source.len and std.ascii.isWhitespace(source[as_pos])) : (as_pos += 1) {}
            if (!identifierKeywordAt(source, as_pos, "as")) continue;
            var namespace_pos = as_pos + "as".len;
            while (namespace_pos < source.len and std.ascii.isWhitespace(source[namespace_pos])) : (namespace_pos += 1) {}
            if (!identifierKeywordAt(source, namespace_pos, "namespace")) continue;
            var name_start = namespace_pos + "namespace".len;
            while (name_start < source.len and std.ascii.isWhitespace(source[name_start])) : (name_start += 1) {}
            const name_end = parseIdentifierEnd(source, name_start, source.len) orelse continue;
            const name = source[name_start..name_end];
            if (seen.contains(name)) continue;
            const owned = try gpa.dupe(u8, name);
            errdefer gpa.free(owned);
            try seen.put(gpa, owned, {});
            try out.append(gpa, .{ .name = owned });
        }
    }

    fn collectAmbientModuleInterfaceExportsFromSource(
        gpa: std.mem.Allocator,
        source: []const u8,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramAmbientModuleInterfaceExport),
    ) ProgramError!void {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_start, "declare")) |declare_pos| {
            search_start = declare_pos + "declare".len;
            if (!identifierKeywordAt(source, declare_pos, "declare")) continue;
            var module_pos = declare_pos + "declare".len;
            while (module_pos < source.len and std.ascii.isWhitespace(source[module_pos])) : (module_pos += 1) {}
            if (!identifierKeywordAt(source, module_pos, "module")) continue;
            module_pos += "module".len;
            while (module_pos < source.len and std.ascii.isWhitespace(source[module_pos])) : (module_pos += 1) {}
            if (module_pos >= source.len or (source[module_pos] != '"' and source[module_pos] != '\'')) continue;
            const quote = source[module_pos];
            const spec_start = module_pos + 1;
            const spec_end = std.mem.indexOfScalarPos(u8, source, spec_start, quote) orelse continue;
            const spec = source[spec_start..spec_end];
            if (spec.len == 0 or spec[0] == '.' or spec[0] == '/') continue;
            const body_open = std.mem.indexOfScalarPos(u8, source, spec_end + 1, '{') orelse continue;
            const body_close = findMatchingBrace(source, body_open) orelse continue;
            try collectAmbientModuleInterfacesFromBody(gpa, source, spec, body_open + 1, body_close, out);
            search_start = body_close + 1;
        }

        search_start = 0;
        while (std.mem.indexOfPos(u8, source, search_start, "declare")) |declare_pos| {
            search_start = declare_pos + "declare".len;
            if (!identifierKeywordAt(source, declare_pos, "declare")) continue;
            var global_pos = declare_pos + "declare".len;
            while (global_pos < source.len and std.ascii.isWhitespace(source[global_pos])) : (global_pos += 1) {}
            if (!identifierKeywordAt(source, global_pos, "global")) continue;
            const body_open = std.mem.indexOfScalarPos(u8, source, global_pos + "global".len, '{') orelse continue;
            const body_close = findMatchingBrace(source, body_open) orelse continue;
            try collectAmbientModuleInterfacesFromBody(gpa, source, "__global__", body_open + 1, body_close, out);
            search_start = body_close + 1;
        }
    }

    fn collectAmbientModuleInterfacesFromBody(
        gpa: std.mem.Allocator,
        source: []const u8,
        spec: []const u8,
        body_start: usize,
        body_end: usize,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramAmbientModuleInterfaceExport),
    ) ProgramError!void {
        var search_start = body_start;
        while (search_start < body_end) {
            const iface_pos = std.mem.indexOfPos(u8, source, search_start, "interface") orelse break;
            if (iface_pos >= body_end) break;
            search_start = iface_pos + "interface".len;
            if (!identifierKeywordAt(source, iface_pos, "interface")) continue;
            var name_start = iface_pos + "interface".len;
            while (name_start < body_end and std.ascii.isWhitespace(source[name_start])) : (name_start += 1) {}
            const name_end = parseIdentifierEnd(source, name_start, body_end) orelse continue;
            const iface_open = std.mem.indexOfScalarPos(u8, source, name_end, '{') orelse continue;
            if (iface_open >= body_end) continue;
            const iface_close = findMatchingBrace(source, iface_open) orelse continue;
            if (iface_close > body_end) continue;
            const members = try collectAmbientInterfaceMembers(gpa, source, iface_open + 1, iface_close);
            errdefer freeProgramAmbientInterfaceMembers(gpa, members);
            const spec_copy = try gpa.dupe(u8, spec);
            errdefer gpa.free(spec_copy);
            const name_copy = try gpa.dupe(u8, source[name_start..name_end]);
            errdefer gpa.free(name_copy);
            try out.append(gpa, .{
                .specifier = spec_copy,
                .name = name_copy,
                .members = members,
                .module_path = try gpa.dupe(u8, ""),
                .namespace_path = try gpa.dupe(u8, ""),
            });
            search_start = iface_close + 1;
        }
    }

    fn collectAmbientInterfaceMembers(
        gpa: std.mem.Allocator,
        source: []const u8,
        body_start: usize,
        body_end: usize,
    ) ProgramError![]const ts_driver.ProgramAmbientInterfaceMember {
        var out: std.ArrayListUnmanaged(ts_driver.ProgramAmbientInterfaceMember) = .empty;
        errdefer {
            for (out.items) |item| {
                gpa.free(item.name);
                gpa.free(item.type_name);
            }
            out.deinit(gpa);
        }
        var i = body_start;
        while (i < body_end) {
            while (i < body_end and (std.ascii.isWhitespace(source[i]) or source[i] == ';' or source[i] == ',')) : (i += 1) {}
            if (i >= body_end) break;
            var is_readonly = false;
            if (identifierKeywordAt(source, i, "readonly")) {
                is_readonly = true;
                i += "readonly".len;
                while (i < body_end and std.ascii.isWhitespace(source[i])) : (i += 1) {}
            }
            if (i >= body_end or !isIdentifierStart(source[i])) {
                i += 1;
                continue;
            }
            const member_start = i;
            const member_end = parseIdentifierEnd(source, member_start, body_end) orelse {
                i += 1;
                continue;
            };
            i = member_end;
            while (i < body_end and std.ascii.isWhitespace(source[i])) : (i += 1) {}
            const is_optional = if (i < body_end and source[i] == '?') blk: {
                i += 1;
                while (i < body_end and std.ascii.isWhitespace(source[i])) : (i += 1) {}
                break :blk true;
            } else false;
            var is_method = false;
            if (i < body_end and source[i] == '(') {
                var depth: usize = 1;
                i += 1;
                while (i < body_end and depth > 0) : (i += 1) {
                    if (source[i] == '(') depth += 1;
                    if (source[i] == ')') depth -= 1;
                }
                while (i < body_end and std.ascii.isWhitespace(source[i])) : (i += 1) {}
                is_method = true;
            }
            if (i >= body_end or source[i] != ':') {
                while (i < body_end and source[i] != ';' and source[i] != '\n' and source[i] != '\r') : (i += 1) {}
                continue;
            }
            i += 1;
            while (i < body_end and std.ascii.isWhitespace(source[i])) : (i += 1) {}
            const type_start = i;
            const type_end = parseIdentifierEnd(source, type_start, body_end) orelse type_start;
            const type_name = if (type_end > type_start) source[type_start..type_end] else "any";
            const name_copy = try gpa.dupe(u8, source[member_start..member_end]);
            errdefer gpa.free(name_copy);
            const type_copy = try gpa.dupe(u8, type_name);
            errdefer gpa.free(type_copy);
            try out.append(gpa, .{
                .name = name_copy,
                .type_name = type_copy,
                .is_optional = is_optional,
                .is_readonly = is_readonly,
                .is_method = is_method,
            });
            i = type_end;
        }
        return try out.toOwnedSlice(gpa);
    }

    const ProgramNamespaceStaticAugmentation = struct {
        target_path: []const u8,
        class_name: []const u8,
        members: []const ts_driver.ProgramExportedClassMember = &.{},
    };

    fn collectRelativeModuleNamespaceStaticAugmentationsFromSource(
        gpa: std.mem.Allocator,
        path: []const u8,
        source: []const u8,
        out: *std.ArrayListUnmanaged(ProgramNamespaceStaticAugmentation),
    ) ProgramError!void {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_start, "declare")) |declare_pos| {
            search_start = declare_pos + "declare".len;
            if (!identifierKeywordAt(source, declare_pos, "declare")) continue;
            var module_pos = declare_pos + "declare".len;
            while (module_pos < source.len and std.ascii.isWhitespace(source[module_pos])) : (module_pos += 1) {}
            if (!identifierKeywordAt(source, module_pos, "module")) continue;
            module_pos += "module".len;
            while (module_pos < source.len and std.ascii.isWhitespace(source[module_pos])) : (module_pos += 1) {}
            if (module_pos >= source.len or (source[module_pos] != '"' and source[module_pos] != '\'')) continue;
            const quote = source[module_pos];
            const spec_start = module_pos + 1;
            const spec_end = std.mem.indexOfScalarPos(u8, source, spec_start, quote) orelse continue;
            const spec = source[spec_start..spec_end];
            if (!std.mem.startsWith(u8, spec, ".")) continue;
            const body_open = std.mem.indexOfScalarPos(u8, source, spec_end + 1, '{') orelse continue;
            const body_close = findMatchingBrace(source, body_open) orelse continue;
            const target_path = try resolveProgramRelativeModulePath(gpa, path, spec);
            errdefer gpa.free(target_path);
            try collectRelativeModuleNamespaceStaticAugmentationsFromBody(gpa, target_path, source, body_open + 1, body_close, out);
            search_start = body_close + 1;
        }
    }

    fn collectRelativeModuleNamespaceStaticAugmentationsFromBody(
        gpa: std.mem.Allocator,
        target_path: []const u8,
        source: []const u8,
        body_start: usize,
        body_end: usize,
        out: *std.ArrayListUnmanaged(ProgramNamespaceStaticAugmentation),
    ) ProgramError!void {
        var search_start = body_start;
        var target_path_owned = false;
        while (search_start < body_end) {
            const ns_pos = std.mem.indexOfPos(u8, source, search_start, "namespace") orelse break;
            if (ns_pos >= body_end) break;
            search_start = ns_pos + "namespace".len;
            if (!identifierKeywordAt(source, ns_pos, "namespace")) continue;
            var name_start = ns_pos + "namespace".len;
            while (name_start < body_end and std.ascii.isWhitespace(source[name_start])) : (name_start += 1) {}
            const name_end = parseIdentifierEnd(source, name_start, body_end) orelse continue;
            const ns_open = std.mem.indexOfScalarPos(u8, source, name_end, '{') orelse continue;
            if (ns_open >= body_end) continue;
            const ns_close = findMatchingBrace(source, ns_open) orelse continue;
            if (ns_close > body_end) continue;
            const members = try collectNamespaceStaticMembersOwned(gpa, source, ns_open + 1, ns_close);
            if (members.len > 0) {
                const stored_path = if (!target_path_owned) blk: {
                    target_path_owned = true;
                    break :blk target_path;
                } else try gpa.dupe(u8, target_path);
                try out.append(gpa, .{
                    .target_path = stored_path,
                    .class_name = source[name_start..name_end],
                    .members = members,
                });
            }
            search_start = ns_close + 1;
        }
        if (!target_path_owned) gpa.free(target_path);
    }

    fn collectNamespaceStaticMembersOwned(
        gpa: std.mem.Allocator,
        source: []const u8,
        body_start: usize,
        body_end: usize,
    ) ProgramError![]const ts_driver.ProgramExportedClassMember {
        var out: std.ArrayListUnmanaged(ts_driver.ProgramExportedClassMember) = .empty;
        errdefer out.deinit(gpa);
        try collectNamespaceStaticMembers(gpa, source, body_start, body_end, &out);
        return try out.toOwnedSlice(gpa);
    }

    fn collectNamespaceStaticMembers(
        gpa: std.mem.Allocator,
        source: []const u8,
        body_start: usize,
        body_end: usize,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramExportedClassMember),
    ) ProgramError!void {
        var i = body_start;
        while (i < body_end and i < source.len) : (i += 1) {
            if (!asciiIdentifierStart(source[i])) continue;
            var cursor = i;
            if (identifierKeywordAt(source, cursor, "export")) {
                cursor += "export".len;
                while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            }
            const keyword_len: usize = if (identifierKeywordAt(source, cursor, "let"))
                3
            else if (identifierKeywordAt(source, cursor, "const"))
                5
            else if (identifierKeywordAt(source, cursor, "var"))
                3
            else
                continue;
            cursor += keyword_len;
            while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            const name_start = cursor;
            const name_end = parseIdentifierEnd(source, name_start, body_end) orelse continue;
            cursor = name_end;
            while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            var type_name: []const u8 = "any";
            if (cursor < body_end and source[cursor] == ':') {
                cursor += 1;
                while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
                const type_start = cursor;
                if (parseIdentifierEnd(source, type_start, body_end)) |type_end| {
                    type_name = source[type_start..type_end];
                    cursor = type_end;
                }
            } else if (cursor < body_end and source[cursor] == '=') {
                cursor += 1;
                while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
                type_name = inferSimpleInitializerTypeName(source, cursor, body_end);
            }
            try out.append(gpa, .{ .name = source[name_start..name_end], .type_name = type_name, .is_method = false });
            i = skipClassMemberRemainder(source, cursor, body_end);
        }
    }

    fn resolveProgramRelativeModulePath(gpa: std.mem.Allocator, from_path: []const u8, spec: []const u8) ProgramError![]u8 {
        const dir = std.fs.path.dirname(from_path) orelse "";
        return std.fs.path.resolve(gpa, &[_][]const u8{ dir, spec }) catch return error.OutOfMemory;
    }

    fn programModulePathMatches(candidate: []const u8, target_path: []const u8) bool {
        if (std.mem.eql(u8, candidate, target_path)) return true;
        const candidate_base = stripProgramModuleExtension(candidate);
        const target_base = stripProgramModuleExtension(target_path);
        return std.mem.eql(u8, candidate_base, target_base);
    }

    fn stripProgramModuleExtension(path: []const u8) []const u8 {
        const exts = [_][]const u8{ ".d.mts", ".d.cts", ".d.ts", ".tsx", ".mts", ".cts", ".ts", ".jsx", ".mjs", ".cjs", ".js" };
        for (exts) |ext| {
            if (std.mem.endsWith(u8, path, ext)) return path[0 .. path.len - ext.len];
        }
        return path;
    }

    fn skipClassMemberRemainder(source: []const u8, start: usize, limit: usize) usize {
        var i = start;
        var depth: usize = 0;
        var quote: u8 = 0;
        while (i < limit and i < source.len) : (i += 1) {
            const c = source[i];
            if (quote != 0) {
                if (c == '\\') {
                    i += 1;
                } else if (c == quote) {
                    quote = 0;
                }
                continue;
            }
            if (c == '"' or c == '\'' or c == '`') {
                quote = c;
                continue;
            }
            if (c == '(' or c == '[' or c == '{') {
                depth += 1;
                continue;
            }
            if (c == ')' or c == ']' or c == '}') {
                if (depth == 0) return i;
                depth -= 1;
                continue;
            }
            if (depth == 0 and (c == ';' or c == '\n' or c == '\r')) return i;
        }
        return i;
    }

    fn inferSimpleInitializerTypeName(source: []const u8, start: usize, limit: usize) []const u8 {
        if (start >= limit or start >= source.len) return "any";
        const c = source[start];
        if (c == '"' or c == '\'' or c == '`') return "string";
        if (std.ascii.isDigit(c)) return "number";
        if (std.mem.startsWith(u8, source[start..@min(limit, source.len)], "true") or
            std.mem.startsWith(u8, source[start..@min(limit, source.len)], "false")) return "boolean";
        if (std.mem.startsWith(u8, source[start..@min(limit, source.len)], "undefined")) return "undefined";
        if (std.mem.startsWith(u8, source[start..@min(limit, source.len)], "null")) return "null";
        return "any";
    }

    fn collectRelativeModuleInterfaceAugmentationsFromSource(
        self: *const Program,
        path: []const u8,
        source: []const u8,
        out: *std.ArrayListUnmanaged(ts_driver.ModuleInterfaceAugmentation),
    ) ProgramError!void {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_start, "declare")) |declare_pos| {
            search_start = declare_pos + "declare".len;
            if (!identifierKeywordAt(source, declare_pos, "declare")) continue;
            var module_pos = declare_pos + "declare".len;
            while (module_pos < source.len and std.ascii.isWhitespace(source[module_pos])) : (module_pos += 1) {}
            if (!identifierKeywordAt(source, module_pos, "module")) continue;
            module_pos += "module".len;
            while (module_pos < source.len and std.ascii.isWhitespace(source[module_pos])) : (module_pos += 1) {}
            if (module_pos >= source.len or (source[module_pos] != '"' and source[module_pos] != '\'')) continue;
            const quote = source[module_pos];
            const spec_start = module_pos + 1;
            const spec_end = std.mem.indexOfScalarPos(u8, source, spec_start, quote) orelse continue;
            const spec = source[spec_start..spec_end];
            if (!std.mem.startsWith(u8, spec, ".")) continue;
            const body_open = std.mem.indexOfScalarPos(u8, source, spec_end + 1, '{') orelse continue;
            const body_close = findMatchingBrace(source, body_open) orelse continue;
            try self.collectInterfaceMethodAugmentations(path, source, spec, body_open + 1, body_close, out);
            search_start = body_close + 1;
        }
    }

    fn collectInterfaceMethodAugmentations(
        self: *const Program,
        path: []const u8,
        source: []const u8,
        spec: []const u8,
        body_start: usize,
        body_end: usize,
        out: *std.ArrayListUnmanaged(ts_driver.ModuleInterfaceAugmentation),
    ) ProgramError!void {
        var search_start = body_start;
        while (search_start < body_end) {
            const iface_pos = std.mem.indexOfPos(u8, source, search_start, "interface") orelse break;
            if (iface_pos >= body_end) break;
            search_start = iface_pos + "interface".len;
            if (!identifierKeywordAt(source, iface_pos, "interface")) continue;
            var name_start = iface_pos + "interface".len;
            while (name_start < body_end and std.ascii.isWhitespace(source[name_start])) : (name_start += 1) {}
            const name_end = parseIdentifierEnd(source, name_start, body_end) orelse continue;
            const iface_name = source[name_start..name_end];
            const iface_open = std.mem.indexOfScalarPos(u8, source, name_end, '{') orelse continue;
            if (iface_open >= body_end) continue;
            const iface_close = findMatchingBrace(source, iface_open) orelse continue;
            if (iface_close > body_end) continue;
            const target_decl = try self.findRelativeModuleInterfaceDeclaration(path, spec, iface_name);
            try collectInterfaceMethodAugmentationsFromBody(
                self.gpa,
                path,
                source,
                spec,
                iface_name,
                name_end,
                @intCast(name_start),
                target_decl,
                iface_open + 1,
                iface_close,
                out,
            );
            search_start = iface_close + 1;
        }
    }

    fn collectInterfaceMethodAugmentationsFromBody(
        gpa: std.mem.Allocator,
        path: []const u8,
        source: []const u8,
        spec: []const u8,
        iface_name: []const u8,
        iface_name_end: usize,
        iface_name_pos: u32,
        target_decl: ?ProgramInterfaceDeclaration,
        body_start: usize,
        body_end: usize,
        out: *std.ArrayListUnmanaged(ts_driver.ModuleInterfaceAugmentation),
    ) ProgramError!void {
        var i = body_start;
        while (i < body_end) : (i += 1) {
            if (!asciiIdentifierStart(source[i])) continue;
            const member_start = i;
            const member_end = parseIdentifierEnd(source, member_start, body_end) orelse continue;
            var cursor = member_end;
            var method_type_parameter_name: []const u8 = "";
            while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            if (cursor < body_end and source[cursor] == '<') {
                const type_params_close = findMatchingDelimited(source, cursor, body_end, '<', '>') orelse {
                    i = member_end;
                    continue;
                };
                var type_param_start = cursor + 1;
                while (type_param_start < type_params_close and std.ascii.isWhitespace(source[type_param_start])) : (type_param_start += 1) {}
                if (parseIdentifierEnd(source, type_param_start, type_params_close)) |type_param_end| {
                    method_type_parameter_name = source[type_param_start..type_param_end];
                }
                cursor = type_params_close + 1;
                while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            }
            if (cursor >= body_end or source[cursor] != '(') {
                i = member_end;
                continue;
            }
            const params_close = findMatchingParen(source, cursor, body_end) orelse {
                i = member_end;
                continue;
            };
            const callback_parameter_type_param_index = firstCallbackInterfaceTypeParameterIndex(
                source,
                iface_name_end,
                body_start - 1,
                cursor + 1,
                params_close,
            );
            cursor = params_close + 1;
            while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            if (cursor >= body_end or source[cursor] != ':') {
                i = params_close;
                continue;
            }
            cursor += 1;
            while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            const return_start = cursor;
            const return_end = parseIdentifierEnd(source, return_start, body_end) orelse {
                i = cursor;
                continue;
            };
            try out.append(gpa, .{
                .target_path = spec,
                .source_path = path,
                .source_pos = iface_name_pos,
                .target_decl_path = if (target_decl) |decl| decl.path else null,
                .target_decl_pos = if (target_decl) |decl| decl.pos else null,
                .interface_name = iface_name,
                .member_name = source[member_start..member_end],
                .return_type_name = source[return_start..return_end],
                .callback_parameter_type_param_index = callback_parameter_type_param_index,
                .method_type_parameter_name = method_type_parameter_name,
                .is_method = true,
            });
            i = return_end;
        }
    }

    fn firstCallbackInterfaceTypeParameterIndex(
        source: []const u8,
        iface_name_end: usize,
        iface_open: usize,
        params_start: usize,
        params_end: usize,
    ) ?u16 {
        var cursor = params_start;
        while (cursor < params_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        const outer_name_end = parseIdentifierEnd(source, cursor, params_end) orelse return null;
        cursor = outer_name_end;
        while (cursor < params_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor < params_end and source[cursor] == '?') {
            cursor += 1;
            while (cursor < params_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        }
        if (cursor >= params_end or source[cursor] != ':') return null;
        cursor += 1;
        while (cursor < params_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor >= params_end or source[cursor] != '(') return null;
        const callback_close = findMatchingParen(source, cursor, params_end) orelse return null;
        cursor += 1;
        while (cursor < callback_close and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        const callback_name_end = parseIdentifierEnd(source, cursor, callback_close) orelse return null;
        cursor = callback_name_end;
        while (cursor < callback_close and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor >= callback_close or source[cursor] != ':') return null;
        cursor += 1;
        while (cursor < callback_close and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        const type_name_end = parseIdentifierEnd(source, cursor, callback_close) orelse return null;
        return interfaceTypeParameterIndex(source, iface_name_end, iface_open, source[cursor..type_name_end]);
    }

    fn interfaceTypeParameterIndex(
        source: []const u8,
        iface_name_end: usize,
        iface_open: usize,
        type_name: []const u8,
    ) ?u16 {
        var cursor = iface_name_end;
        while (cursor < iface_open and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor >= iface_open or source[cursor] != '<') return null;
        const close = findMatchingDelimited(source, cursor, iface_open, '<', '>') orelse return null;
        cursor += 1;
        var index: u16 = 0;
        while (cursor < close) {
            while (cursor < close and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            const name_end = parseIdentifierEnd(source, cursor, close) orelse return null;
            if (std.mem.eql(u8, source[cursor..name_end], type_name)) return index;
            var depth: usize = 0;
            cursor = name_end;
            while (cursor < close) : (cursor += 1) {
                switch (source[cursor]) {
                    '<', '(', '[', '{' => depth += 1,
                    '>', ')', ']', '}' => if (depth > 0) {
                        depth -= 1;
                    },
                    ',' => if (depth == 0) {
                        cursor += 1;
                        break;
                    },
                    else => {},
                }
            }
            index = std.math.add(u16, index, 1) catch return null;
        }
        return null;
    }

    const ProgramInterfaceDeclaration = struct {
        path: []const u8,
        pos: u32,
    };

    fn findRelativeModuleInterfaceDeclaration(
        self: *const Program,
        from_path: []const u8,
        spec: []const u8,
        interface_name: []const u8,
    ) ProgramError!?ProgramInterfaceDeclaration {
        const target_path = try resolveProgramRelativeModulePath(self.gpa, from_path, spec);
        defer self.gpa.free(target_path);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            if (!programModulePathMatches(f.path, target_path)) continue;
            const pos = findTopLevelInterfaceDeclarationPos(f.source, interface_name) orelse return null;
            return .{ .path = f.path, .pos = pos };
        }
        return null;
    }

    fn findTopLevelInterfaceDeclarationPos(source: []const u8, interface_name: []const u8) ?u32 {
        var depth: usize = 0;
        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            if (c == '{') {
                depth += 1;
                continue;
            }
            if (c == '}') {
                if (depth > 0) depth -= 1;
                continue;
            }
            if (depth != 0) continue;
            if (!identifierKeywordAt(source, i, "interface")) continue;
            var name_start = i + "interface".len;
            while (name_start < source.len and std.ascii.isWhitespace(source[name_start])) : (name_start += 1) {}
            const name_end = parseIdentifierEnd(source, name_start, source.len) orelse continue;
            if (std.mem.eql(u8, source[name_start..name_end], interface_name)) return @intCast(name_start);
            i = name_end;
        }
        return null;
    }

    fn parseIdentifierEnd(source: []const u8, start: usize, limit: usize) ?usize {
        if (start >= limit or start >= source.len or !asciiIdentifierStart(source[start])) return null;
        var end = start + 1;
        while (end < limit and end < source.len and asciiIdentifierContinue(source[end])) : (end += 1) {}
        return end;
    }

    fn findMatchingBrace(source: []const u8, open_pos: usize) ?usize {
        return findMatchingDelimited(source, open_pos, source.len, '{', '}');
    }

    fn findMatchingParen(source: []const u8, open_pos: usize, limit: usize) ?usize {
        return findMatchingDelimited(source, open_pos, limit, '(', ')');
    }

    fn findMatchingDelimited(source: []const u8, open_pos: usize, limit: usize, open_ch: u8, close_ch: u8) ?usize {
        if (open_pos >= limit or open_pos >= source.len or source[open_pos] != open_ch) return null;
        var depth: usize = 0;
        var quote: u8 = 0;
        var i = open_pos;
        while (i < limit and i < source.len) : (i += 1) {
            const c = source[i];
            if (quote != 0) {
                if (c == '\\') {
                    i += 1;
                } else if (c == quote) {
                    quote = 0;
                }
                continue;
            }
            if (c == '"' or c == '\'' or c == '`') {
                quote = c;
                continue;
            }
            if (c == open_ch) {
                depth += 1;
            } else if (c == close_ch) {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        return null;
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
            try upsertScriptObjectExpando(gpa, out, root, member, true, false);
        }
    }

    fn collectQualifiedJsDocTypedefs(
        gpa: std.mem.Allocator,
        source: []const u8,
        out: *std.ArrayListUnmanaged(ts_driver.ScriptObjectExpando),
    ) ProgramError!void {
        const needle = "@typedef";
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_from, needle)) |tag_pos| {
            var p = tag_pos + needle.len;
            search_from = p;
            while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
            if (p < source.len and source[p] == '{') {
                var depth: usize = 1;
                p += 1;
                while (p < source.len and depth > 0) : (p += 1) {
                    if (source[p] == '{') depth += 1;
                    if (source[p] == '}') depth -= 1;
                }
                if (depth != 0) continue;
                while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
            }
            if (p >= source.len or !asciiIdentifierStart(source[p])) continue;
            const root_start = p;
            p += 1;
            while (p < source.len and asciiIdentifierContinue(source[p])) p += 1;
            const root = source[root_start..p];
            if (p >= source.len or source[p] != '.') continue;
            p += 1;
            if (p >= source.len or !asciiIdentifierStart(source[p])) continue;
            const member_start = p;
            p += 1;
            while (p < source.len and asciiIdentifierContinue(source[p])) p += 1;
            const member = source[member_start..p];
            try upsertScriptObjectExpando(gpa, out, root, member, false, true);
            search_from = p;
        }
    }

    fn upsertScriptObjectExpando(
        gpa: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(ts_driver.ScriptObjectExpando),
        root: []const u8,
        member: []const u8,
        has_value: bool,
        has_jsdoc_typedef: bool,
    ) ProgramError!void {
        for (out.items) |*existing| {
            if (!std.mem.eql(u8, existing.root, root)) continue;
            if (!std.mem.eql(u8, existing.member, member)) continue;
            existing.has_value = existing.has_value or has_value;
            existing.has_jsdoc_typedef = existing.has_jsdoc_typedef or has_jsdoc_typedef;
            return;
        }
        try out.append(gpa, .{
            .root = root,
            .member = member,
            .has_value = has_value,
            .has_jsdoc_typedef = has_jsdoc_typedef,
        });
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

    fn freeProgramExportedClasses(gpa: std.mem.Allocator, items: []const ts_driver.ProgramExportedClass) void {
        class_declarations.free(gpa, items);
    }

    fn freeProgramAmbientModuleInterfaceExports(gpa: std.mem.Allocator, items: []const ts_driver.ProgramAmbientModuleInterfaceExport) void {
        for (items) |item| {
            gpa.free(item.specifier);
            gpa.free(item.name);
            gpa.free(item.module_path);
            gpa.free(item.namespace_path);
            freeProgramAmbientInterfaceMembers(gpa, item.members);
        }
        gpa.free(items);
    }

    fn programCommonJsExportsNeedDependencyChecking(
        self: *const Program,
        items: []const ts_driver.ProgramCommonJsExport,
    ) bool {
        for (items) |item| {
            if (item.name.len != 0 or item.whole_export_is_any) continue;
            for (self.files.items) |consumer| {
                for (consumer.imports.items) |dependency| {
                    if (dependency < self.files.items.len and
                        std.mem.eql(u8, self.files.items[dependency].path, item.module_path)) return true;
                }
            }
        }
        return false;
    }

    fn freeProgramCommonJsExports(gpa: std.mem.Allocator, items: []const ts_driver.ProgramCommonJsExport) void {
        for (items) |item| {
            if (item.whole_export_schema) |owner_schema| @constCast(owner_schema).deinit(gpa);
            gpa.free(item.module_path);
            gpa.free(item.name);
            if (item.private_type_name.len > 0) gpa.free(item.private_type_name);
            if (item.private_module_name.len > 0) gpa.free(item.private_module_name);
        }
        gpa.free(items);
    }

    fn freeProgramAmbientInterfaceMembers(gpa: std.mem.Allocator, items: []const ts_driver.ProgramAmbientInterfaceMember) void {
        for (items) |item| {
            gpa.free(item.name);
            gpa.free(item.type_name);
        }
        if (items.len > 0) gpa.free(items);
    }

    fn freeProgramUmdGlobals(gpa: std.mem.Allocator, items: []const ts_driver.ProgramUmdGlobal) void {
        for (items) |item| gpa.free(item.name);
        gpa.free(items);
    }

    fn mergeProgramUmdGlobals(
        gpa: std.mem.Allocator,
        collected: []const ts_driver.ProgramUmdGlobal,
        provided: []const ts_driver.ProgramUmdGlobal,
    ) ProgramError![]const ts_driver.ProgramUmdGlobal {
        if (provided.len == 0) return try gpa.dupe(ts_driver.ProgramUmdGlobal, collected);
        var out: std.ArrayListUnmanaged(ts_driver.ProgramUmdGlobal) = .empty;
        errdefer out.deinit(gpa);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        for (collected) |item| {
            if (seen.contains(item.name)) continue;
            try seen.put(gpa, item.name, {});
            try out.append(gpa, item);
        }
        for (provided) |item| {
            if (seen.contains(item.name)) continue;
            try seen.put(gpa, item.name, {});
            try out.append(gpa, item);
        }
        return try out.toOwnedSlice(gpa);
    }

    /// One `declare global { … }` block discovered at a file's top
    /// level. Names share a program keyspace, but HIR nodes remain local.
    /// Preserve the (file, namespace_node) pair for owner-aware resolution;
    /// copying NodeIds into another file's binder is not a valid merge.
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
        try self.prepareNameStore();
        const out = self.gpa.alloc(EmitSummary, self.files.items.len) catch return error.OutOfMemory;
        errdefer {
            for (out) |*s| self.gpa.free(s.js);
            self.gpa.free(out);
        }
        for (self.files.items, 0..) |f, idx| {
            var per_file = options;
            per_file.shared_strings = &self.strings.?;
            per_file.is_tsx = options.is_tsx or f.is_tsx;
            per_file.package_type_module = f.package_type_module;
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
        try self.prepareNameStore();
        self.deduplicate_packages = options.deduplicate_packages;
        if (options.bind_only) {
            try self.compileFilesParallel(options, workers);
            try self.resolveImports();
            return;
        }
        var bind_options = options;
        bind_options.bind_only = true;
        try self.compileFilesParallel(bind_options, workers);
        try self.resolveImports();
        var globals = try self.collectBoundGlobals();
        defer globals.deinit(self.gpa);
        self.prepareSourceMarkers();
        defer self.clearSourceMarkers();
        self.deduplicate_packages = options.deduplicate_packages;
        const ambient_global_namespace_roots = try self.collectAmbientGlobalNamespaceRoots();
        defer freeStringSlice(self.gpa, ambient_global_namespace_roots);
        const script_object_expandos = try self.collectScriptObjectExpandos();
        defer self.gpa.free(script_object_expandos);
        const program_global_var_names = try globals.names(self.gpa, &self.strings.?, .vars);
        defer freeStringSlice(self.gpa, program_global_var_names);
        const program_global_type_names = try globals.names(self.gpa, &self.strings.?, .types);
        defer freeStringSlice(self.gpa, program_global_type_names);
        const module_interface_augmentations = try self.collectRelativeModuleInterfaceAugmentations();
        defer self.gpa.free(module_interface_augmentations);
        const program_exported_classes = try self.collectProgramExportedClasses();
        defer freeProgramExportedClasses(self.gpa, program_exported_classes);
        var declarations = try self.collectProgramDeclarationsForChecking();
        defer declarations.deinit();
        const program_ambient_module_interface_exports = try self.collectAmbientModuleInterfaceExports();
        defer freeProgramAmbientModuleInterfaceExports(self.gpa, program_ambient_module_interface_exports);
        const program_commonjs_exports = try self.collectProgramCommonJsExports();
        defer freeProgramCommonJsExports(self.gpa, program_commonjs_exports);
        const program_umd_globals = try self.collectProgramUmdGlobals();
        defer freeProgramUmdGlobals(self.gpa, program_umd_globals);
        const merged_program_umd_globals = try mergeProgramUmdGlobals(self.gpa, program_umd_globals, options.program_umd_globals);
        defer self.gpa.free(merged_program_umd_globals);
        const known_reference_paths = try self.gpa.alloc([]const u8, self.files.items.len + options.known_reference_paths.len);
        defer self.gpa.free(known_reference_paths);
        for (self.files.items, 0..) |f, i| known_reference_paths[i] = f.path;
        for (options.known_reference_paths, 0..) |path, i| known_reference_paths[self.files.items.len + i] = path;
        var shared_options = options;
        shared_options.ambient_global_namespace_roots = ambient_global_namespace_roots;
        shared_options.script_object_expandos = script_object_expandos;
        shared_options.program_global_var_names = program_global_var_names;
        shared_options.program_global_type_names = program_global_type_names;
        shared_options.module_interface_augmentations = module_interface_augmentations;
        shared_options.program_exported_classes = program_exported_classes;
        shared_options.program_exported_values = declarations.values;
        shared_options.program_exported_types = declarations.types;
        shared_options.program_ambient_module_interface_exports = program_ambient_module_interface_exports;
        shared_options.program_commonjs_exports = program_commonjs_exports;
        shared_options.program_umd_globals = merged_program_umd_globals;
        shared_options.known_reference_paths = known_reference_paths;
        if (self.programCommonJsExportsNeedDependencyChecking(program_commonjs_exports)) {
            try self.compileFilesInDependencyBatches(
                shared_options,
                workers,
                @constCast(program_commonjs_exports),
            );
        } else {
            try self.compileFilesParallel(shared_options, workers);
        }

        try self.appendMissingCompilerTypeReferenceDiagnostics(options);
        try self.appendMissingImportedHelperDiagnostics(options);
        try self.appendRootDirDiagnostics(options);
        try self.appendProgramGlobalDeclareVarDiagnostics();
        try self.appendProgramGlobalInterfaceMemberDiagnostics();
        try self.appendMergedAmbientModuleExportDiagnostics();
    }

    fn compileFilesInDependencyBatches(
        self: *Program,
        options: ts_driver.CompileOptions,
        workers: ?usize,
        program_commonjs_exports: []ts_driver.ProgramCommonJsExport,
    ) ProgramError!void {
        const completed = try self.gpa.alloc(bool, self.files.items.len);
        defer self.gpa.free(completed);
        var remaining: usize = 0;
        for (self.files.items, completed) |file, *done| {
            done.* = file.redirect_target != null or !needsCompilation(file, options);
            if (!done.*) remaining += 1;
        }

        var ready: std.ArrayListUnmanaged(usize) = .empty;
        defer ready.deinit(self.gpa);
        while (remaining > 0) {
            ready.clearRetainingCapacity();
            for (self.files.items, 0..) |file, index| {
                if (completed[index]) continue;
                for (file.imports.items) |dependency| {
                    if (dependency < completed.len and !completed[dependency]) break;
                } else {
                    try ready.append(self.gpa, index);
                }
            }
            // Cyclic components have no dependency-free member. Preserve the
            // existing best-effort behavior by breaking one cycle edge, then
            // resume ordinary ready-set scheduling for the remaining files.
            if (ready.items.len == 0) {
                for (completed, 0..) |done, index| {
                    if (!done) {
                        try ready.append(self.gpa, index);
                        break;
                    }
                }
            }

            try self.compileFileIndicesParallel(options, workers, ready.items);
            for (ready.items) |index| {
                completed[index] = true;
                remaining -= 1;
                try self.populateProgramCommonJsExportSchemas(
                    self.files.items[index],
                    program_commonjs_exports,
                );
            }
        }
    }

    fn compileFilesParallel(self: *Program, options: ts_driver.CompileOptions, workers: ?usize) ProgramError!void {
        try self.prepareNameStore();
        var pending: std.ArrayListUnmanaged(usize) = .empty;
        defer pending.deinit(self.gpa);
        for (self.files.items, 0..) |f, idx| {
            if (needsCompilation(f, options)) try pending.append(self.gpa, idx);
        }
        try self.compileFileIndicesParallel(options, workers, pending.items);
    }

    fn compileFileIndicesParallel(
        self: *Program,
        options: ts_driver.CompileOptions,
        workers: ?usize,
        pending: []const usize,
    ) ProgramError!void {
        if (pending.len == 0) return;
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const n = @max(1, workers orelse @min(cpu_count, 8));

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
                    prog.compileFile(f, opts) catch {
                        _ = fail.fetchAdd(1, .seq_cst);
                        continue;
                    };
                }
            }
        };

        const worker_count = @min(n, pending.len);
        var threads = self.gpa.alloc(std.Thread, worker_count) catch return error.OutOfMemory;
        defer self.gpa.free(threads);
        var spawned: usize = 0;
        for (threads, 0..) |*t, i| {
            _ = i;
            t.* = std.Thread.spawn(.{}, Worker.run, .{ self, options, pending, &cursor, &failures }) catch {
                // If we can't spawn more workers, do the rest serially.
                Worker.run(self, options, pending, &cursor, &failures);
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
    }

    fn appendRootDirDiagnostics(self: *Program, options: ts_driver.CompileOptions) ProgramError!void {
        const cfg = options.pub_tsconfig orelse return;
        const root_raw = cfg.compiler_options.root_dir orelse return;
        if (root_raw.len == 0 or cfg.file_path.len == 0) return;
        const config_dir = std.fs.path.dirname(cfg.file_path) orelse return;
        const root_dir = try self.resolveConfigRelativePath(config_dir, root_raw);
        defer self.gpa.free(root_dir);

        for (self.files.items) |f| {
            if (f.redirect_target != null or f.is_declaration) continue;
            const c = f.compilation orelse continue;
            const file_path = try normalizeProgramPath(self.gpa, f.path);
            defer self.gpa.free(file_path);
            if (pathHasDirPrefix(file_path, root_dir)) continue;
            const msg = try std.fmt.allocPrint(
                self.gpa,
                "File '{s}' is not under 'rootDir' '{s}'. 'rootDir' is expected to contain all source files.",
                .{ file_path, root_dir },
            );
            try c.diagnostics.append(self.gpa, .{
                .phase = .parse,
                .pos = 0,
                .line = 0,
                .span_len = 0,
                .code = 6059,
                .is_global = true,
                .message = msg,
            });
            c.has_errors = true;
        }
    }

    fn resolveConfigRelativePath(self: *Program, config_dir: []const u8, raw: []const u8) ProgramError![]u8 {
        if (std.fs.path.isAbsolute(raw)) return normalizeProgramPath(self.gpa, raw);
        const joined = try std.fs.path.join(self.gpa, &.{ config_dir, raw });
        defer self.gpa.free(joined);
        return normalizeProgramPath(self.gpa, joined);
    }

    fn normalizeProgramPath(gpa: std.mem.Allocator, raw: []const u8) ProgramError![]u8 {
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer parts.deinit(gpa);
        const absolute = std.mem.startsWith(u8, raw, "/");
        var it = std.mem.splitScalar(u8, raw, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..") and parts.items.len != 0) {
                _ = parts.pop();
                continue;
            }
            try parts.append(gpa, part);
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        if (absolute) try out.append(gpa, '/');
        for (parts.items, 0..) |part, i| {
            if (i != 0) try out.append(gpa, '/');
            try out.appendSlice(gpa, part);
        }
        if (out.items.len == 0) try out.appendSlice(gpa, if (absolute) "/" else ".");
        return try out.toOwnedSlice(gpa);
    }

    fn pathHasDirPrefix(path: []const u8, dir: []const u8) bool {
        var trimmed_dir = dir;
        while (trimmed_dir.len > 1 and trimmed_dir[trimmed_dir.len - 1] == '/') {
            trimmed_dir = trimmed_dir[0 .. trimmed_dir.len - 1];
        }
        if (std.mem.eql(u8, path, trimmed_dir)) return true;
        if (!std.mem.startsWith(u8, path, trimmed_dir)) return false;
        return path.len > trimmed_dir.len and path[trimmed_dir.len] == '/';
    }

    /// Walk every compiled file's import declarations and resolve
    /// each to a FileId, populating the adjacency list.
    fn resolveImports(self: *Program) ProgramError!void {
        var targets: std.AutoHashMapUnmanaged(FileId, void) = .empty;
        defer targets.deinit(self.gpa);
        var specifiers: std.ArrayListUnmanaged(StaticModuleReference) = .empty;
        defer specifiers.deinit(self.gpa);
        for (self.files.items) |f| {
            // Resolution is a snapshot, not an append-only history. Closure
            // discovery and incremental checking can visit a file repeatedly.
            f.imports.clearRetainingCapacity();
            targets.clearRetainingCapacity();
            const c = f.compilation orelse continue;
            const root = c.root;
            // Defensive guard: a parse error can leave c.root pointing
            // at a non-block sentinel (e.g. recursive type files that
            // bail mid-parse). blockStmts asserts kind == .block_stmt,
            // so skip resolution for malformed roots.
            if (c.hir.kindOf(root) != .block_stmt) continue;
            specifiers.clearRetainingCapacity();
            try appendStaticModuleReferences(self.gpa, c, &specifiers);
            for (specifiers.items) |reference| {
                const module_name = reference.specifier;
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
                    const seen = try targets.getOrPut(self.gpa, target_id);
                    if (seen.found_existing) continue;
                    try f.imports.append(self.gpa, target_id);
                    // Record *why* the target is in the program, for
                    // `--explainFiles` (TS1393). First importer wins,
                    // matching tsgo's first-add reason ordering. The
                    // specifier is quoted to mirror tsgo's source-slice
                    // reference text; Home's interner drops the original
                    // quotes, so we normalize to double quotes.
                    const target = self.files.items[target_id];
                    if (target.include_reason == null) {
                        const package_id = if (res.package_id) |id| try self.gpa.dupe(u8, id) else "";
                        errdefer if (package_id.len != 0) self.gpa.free(package_id);
                        const project_reference_output = if (res.project_reference_output) |output| try self.gpa.dupe(u8, output) else "";
                        errdefer if (project_reference_output.len != 0) self.gpa.free(project_reference_output);
                        const quoted = try std.fmt.allocPrint(self.gpa, "\"{s}\"", .{module_name});
                        errdefer self.gpa.free(quoted);
                        target.include_reason = .{
                            .kind = .import,
                            .importer = f.id,
                            .specifier_text = quoted,
                            .package_id = package_id,
                            .project_reference_output = project_reference_output,
                            .specifier_pos = reference.position orelse findIncludeSpecifierPosition(f.source, quoted),
                        };
                    }
                }
            }
        }
    }

    fn staticModuleSpecifier(c: *const ts_driver.Compilation, node: hir_mod_ns.NodeId) ?[]const u8 {
        const name = switch (c.hir.kindOf(node)) {
            .import_decl => hir_mod_ns.importOf(&c.hir, node).module,
            .export_decl => hir_mod_ns.exportOf(&c.hir, node).module,
            else => return null,
        };
        const text = c.interner.get(name);
        return if (text.len == 0) null else text;
    }

    const StaticModuleReference = struct {
        specifier: []const u8,
        order: u32,
        /// Opening quote position when represented by a real expression node.
        position: ?u32 = null,
    };

    /// Collect the same static one-literal-argument `require` shape used by
    /// the pinned TypeScript compilers. HIR traversal includes nested calls
    /// without treating comments, strings, computed calls, or dynamic
    /// specifiers as dependencies.
    fn appendStaticModuleReferences(
        gpa: std.mem.Allocator,
        c: *const ts_driver.Compilation,
        out: *std.ArrayListUnmanaged(StaticModuleReference),
    ) !void {
        if (c.hir.kindOf(c.root) != .block_stmt) return;
        for (hir_mod_ns.blockStmts(&c.hir, c.root)) |statement| {
            if (staticModuleSpecifier(c, statement)) |specifier| {
                try out.append(gpa, .{ .specifier = specifier, .order = c.hir.spanOf(statement).start });
            }
        }
        const require_name = c.interner.lookup("require") orelse return;
        var node: hir_mod_ns.NodeId = 1;
        while (node < c.hir.nodeCount()) : (node += 1) {
            if (c.hir.kindOf(node) != .call_expr) continue;
            const call = hir_mod_ns.callOf(&c.hir, node);
            if (call.callee == hir_mod_ns.none_node_id or
                c.hir.kindOf(call.callee) != .identifier or
                hir_mod_ns.identifierOf(&c.hir, call.callee).name != require_name) continue;
            const arguments = hir_mod_ns.callArgs(&c.hir, node);
            if (arguments.len != 1) continue;
            const specifier = staticStringLiteralLike(c, arguments[0]) orelse continue;
            if (specifier.len == 0) continue;
            try out.append(gpa, .{
                .specifier = specifier,
                .order = c.hir.spanOf(arguments[0]).start,
                .position = c.hir.spanOf(arguments[0]).start,
            });
        }
        std.mem.sort(StaticModuleReference, out.items, {}, struct {
            fn lessThan(_: void, left: StaticModuleReference, right: StaticModuleReference) bool {
                return left.order < right.order;
            }
        }.lessThan);
    }

    fn staticStringLiteralLike(c: *const ts_driver.Compilation, node: hir_mod_ns.NodeId) ?[]const u8 {
        if (c.hir.kindOf(node) == .literal_string)
            return c.interner.get(hir_mod_ns.literalStringOf(&c.hir, node).value);
        if (c.hir.kindOf(node) != .template_literal or hir_mod_ns.templateLiteralExprs(&c.hir, node).len != 0) return null;
        const texts = hir_mod_ns.templateLiteralTexts(&c.hir, node);
        if (texts.len != 1 or c.hir.kindOf(texts[0]) != .literal_string) return null;
        return c.interner.get(hir_mod_ns.literalStringOf(&c.hir, texts[0]).value);
    }

    /// Expand the program to the transitive closure of imports, reading
    /// each newly-discovered file through the resolver's file system.
    /// Mirrors tsc's file loader, which follows every module reference
    /// from the root files until no new file is found. Returns the count
    /// of files added beyond the initial roots.
    ///
    /// Each round prepares the current set (so HIR import lists exist),
    /// then resolves+reads any imported file not already present; it
    /// repeats until a round adds nothing. `resolveImports` (run inside
    /// `compileAll`) records each added file's `include_reason`, so
    /// `--explainFiles` can later render TS1393. Check/emit runs only once
    /// discovery is complete, reusing every bound source in place.
    pub fn loadImportClosure(self: *Program, options: ts_driver.CompileOptions) ProgramError!usize {
        return self.loadImportClosureImpl(options, false, null);
    }

    /// Parallel closure loader for production compilers. Small programs use
    /// the serial path to avoid worker startup overhead; larger programs use
    /// the same bounded worker pool as `compileAllParallel` in every round.
    pub fn loadImportClosureParallel(self: *Program, options: ts_driver.CompileOptions, workers: ?usize) ProgramError!usize {
        return self.loadImportClosureImpl(options, true, workers);
    }

    fn loadImportClosureImpl(
        self: *Program,
        options: ts_driver.CompileOptions,
        parallel: bool,
        workers: ?usize,
    ) ProgramError!usize {
        self.deduplicate_packages = options.deduplicate_packages;
        const had_checked_sources = for (self.files.items) |f| {
            if (f.compilation) |c| {
                if (c.check_state == .checked) break true;
            }
        } else false;
        var added: usize = 0;
        added += try self.loadCompilerOptionIncludes(options);
        added += try self.loadCompilerInjectedImports(options);
        var discovery_options = options;
        discovery_options.bind_only = true;
        while (true) {
            if (parallel and builtin.mode != .Debug and self.files.items.len >= 16)
                try self.compileAllParallel(discovery_options, workers)
            else
                try self.compileAll(discovery_options);
            var new_in_round: usize = 0;
            // Snapshot the count: files appended this round are scanned
            // in the next iteration, keeping the fixpoint simple.
            const n = self.files.items.len;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const f = self.files.items[i];
                const c = f.compilation orelse continue;
                if (c.hir.kindOf(c.root) != .block_stmt) continue;
                var specifiers: std.ArrayListUnmanaged(StaticModuleReference) = .empty;
                defer specifiers.deinit(self.gpa);
                try appendStaticModuleReferences(self.gpa, c, &specifiers);
                for (specifiers.items) |reference| {
                    const module_name = reference.specifier;
                    if (module_name.len == 0) continue;
                    const res = self.resolver.resolve(module_name, f.path) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    if (!options.allow_js and isJsLikePath(res.path)) continue;
                    if (self.by_path.get(res.path) != null) continue;
                    _ = self.addResolvedIncludeFileFromResolution(res) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    new_in_round += 1;
                }
                // Triple-slash directives pull files into the program
                // with distinct explainFiles reasons: path (TS1400),
                // types (TS1402/TS1403), and lib (TS1405). `path`
                // directives are literal file paths; `types` use the
                // resolver's type-reference API; `lib` uses Home's
                // currently available local lib.<name>.d.ts convention.
                for (c.references.items) |ref| {
                    switch (ref.kind) {
                        .path => {
                            const candidate = self.joinReferencePath(f.path, ref.name) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                            };
                            defer self.gpa.free(candidate);
                            if (self.by_path.get(candidate) != null) continue;
                            const rsrc = self.resolver.fs.readFile(self.gpa, candidate) catch continue;
                            defer self.gpa.free(rsrc);
                            const new_id = self.add(candidate, rsrc) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => continue,
                            };
                            try self.recordReferenceIncludeReason(new_id, .reference_file, f.id, ref.name, "", ref.pos);
                            new_in_round += 1;
                        },
                        .types => {
                            const resolution = if (ref.resolution_mode) |mode|
                                self.resolver.resolveTypeReferenceDirectiveWithMode(ref.name, f.path, switch (mode) {
                                    .import => .import,
                                    .require => .require,
                                })
                            else
                                self.resolver.resolveTypeReferenceDirective(ref.name, f.path);
                            const res = resolution catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => continue,
                            };
                            if (self.by_path.get(res.path) != null) continue;
                            const new_id = self.addResolvedIncludeFileFromResolution(res) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => continue,
                            } orelse continue;
                            try self.recordReferenceIncludeReason(new_id, .type_reference, f.id, ref.name, res.package_id orelse "", ref.pos);
                            new_in_round += 1;
                        },
                        .lib => {
                            const candidate = self.resolveLibReferencePath(f.path, ref.name) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                            } orelse continue;
                            defer self.gpa.free(candidate);
                            if (self.by_path.get(candidate) != null) continue;
                            const rsrc = self.resolver.fs.readFile(self.gpa, candidate) catch continue;
                            defer self.gpa.free(rsrc);
                            const new_id = self.add(candidate, rsrc) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => continue,
                            };
                            try self.recordReferenceIncludeReason(new_id, .lib_reference, f.id, ref.name, "", ref.pos);
                            new_in_round += 1;
                        },
                    }
                }
            }
            added += new_in_round;
            if (new_in_round == 0) break;
        }
        if (had_checked_sources and added != 0) {
            // A caller may have checked an incomplete graph explicitly.
            // Those results cannot be reused after graph expansion; unlike
            // bound sources, their HIR/types already contain semantic state.
            try self.recompileAll(options);
            return added;
        }
        if (!options.bind_only) {
            if (parallel and builtin.mode != .Debug and self.files.items.len >= 16)
                try self.compileAllParallel(options, workers)
            else
                try self.compileAll(options);
        }
        return added;
    }

    fn loadCompilerInjectedImports(self: *Program, options: ts_driver.CompileOptions) ProgramError!usize {
        var added: usize = 0;
        const n = self.files.items.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const f = self.files.items[i];
            if (f.is_declaration) continue;
            if (options.emit.import_helpers) {
                const specifier = try quotedSpecifier(self.gpa, "tslib");
                defer self.gpa.free(specifier);
                added += try self.loadCompilerInjectedImport(f, "tslib", specifier, .imported_helper);
            }
            if (compilerOptionsUsesAutomaticJsxRuntime(options) and sourceHasJsxSyntax(f.source)) {
                const runtime = try compilerOptionsJsxRuntimeModule(self.gpa, options);
                defer self.gpa.free(runtime);
                const specifier = try quotedSpecifier(self.gpa, runtime);
                defer self.gpa.free(specifier);
                added += try self.loadCompilerInjectedImport(f, runtime, specifier, .jsx_runtime_import);
            }
        }
        return added;
    }

    fn loadCompilerInjectedImport(
        self: *Program,
        importer: *File,
        module_name: []const u8,
        specifier_text: []const u8,
        kind: IncludeKind,
    ) ProgramError!usize {
        const res = self.resolver.resolve(module_name, importer.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return 0,
        };
        const target_id = try self.addResolvedIncludeFileFromResolution(res);
        if (target_id == null) return 0;
        try self.recordReferenceIncludeReasonWithProjectOutput(target_id.?, kind, importer.id, specifier_text, res.package_id orelse "", res.project_reference_output orelse "", 0);
        return 1;
    }

    fn compilerOptionsUsesAutomaticJsxRuntime(options: ts_driver.CompileOptions) bool {
        return options.emit.jsx_runtime == .automatic or options.emit.jsx_runtime == .automatic_dev;
    }

    fn compilerOptionsJsxRuntimeModule(gpa: std.mem.Allocator, options: ts_driver.CompileOptions) ProgramError![]u8 {
        const import_source = if (options.pub_tsconfig) |cfg|
            cfg.compiler_options.jsx_import_source orelse "react"
        else
            "react";
        const suffix: []const u8 = if (options.emit.jsx_runtime == .automatic_dev) "jsx-dev-runtime" else "jsx-runtime";
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ import_source, suffix }) catch return error.OutOfMemory;
    }

    fn sourceHasJsxSyntax(source: []const u8) bool {
        return std.mem.indexOf(u8, source, "<>") != null or
            std.mem.indexOf(u8, source, "</") != null or
            std.mem.indexOf(u8, source, "/>") != null;
    }

    fn quotedSpecifier(gpa: std.mem.Allocator, specifier: []const u8) ProgramError![]u8 {
        return std.fmt.allocPrint(gpa, "\"{s}\"", .{specifier}) catch return error.OutOfMemory;
    }

    fn loadCompilerOptionIncludes(self: *Program, options: ts_driver.CompileOptions) ProgramError!usize {
        const cfg = options.pub_tsconfig orelse return 0;
        var added: usize = 0;
        const containing_file = compilerOptionContainingFile(cfg, self.files.items);
        if (cfg.compiler_options.types) |types| {
            for (types) |type_name| {
                if (type_name.len == 0) continue;
                const res = self.resolver.resolveTypeReferenceDirective(type_name, containing_file) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                const target_id = try self.addResolvedIncludeFileFromResolution(res);
                if (target_id == null) continue;
                try self.recordReferenceIncludeReason(target_id.?, .compiler_type_reference, 0, type_name, res.package_id orelse "", 0);
                added += 1;
            }
        } else {
            added += try self.loadImplicitTypeLibraries(cfg, containing_file);
        }
        if (cfg.compiler_options.lib) |libs| {
            for (libs) |lib_name| {
                if (lib_name.len == 0) continue;
                const candidate = self.resolveLibReferencePath(containing_file, lib_name) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                } orelse continue;
                defer self.gpa.free(candidate);
                const target_id = try self.addResolvedIncludeFile(candidate);
                if (target_id == null) continue;
                try self.recordReferenceIncludeReason(target_id.?, .compiler_lib_reference, 0, lib_name, "", 0);
                added += 1;
            }
        } else if (cfg.compiler_options.no_lib != true) {
            const default_lib = defaultLibNameForTarget(cfg.compiler_options.target);
            const candidate = self.resolveLibReferencePath(containing_file, default_lib.lib_name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            } orelse return added;
            defer self.gpa.free(candidate);
            const target_id = try self.addResolvedIncludeFile(candidate);
            if (target_id) |id| {
                try self.recordReferenceIncludeReason(id, .default_lib_reference, 0, default_lib.target_name, "", 0);
                added += 1;
            }
        }
        return added;
    }

    fn loadImplicitTypeLibraries(
        self: *Program,
        cfg: *const tsconfig_mod.TsConfig,
        containing_file: []const u8,
    ) ProgramError!usize {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (names.items) |name| self.gpa.free(name);
            names.deinit(self.gpa);
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = seen.iterator();
            while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
            seen.deinit(self.gpa);
        }

        try self.collectImplicitTypeLibraryNames(cfg, containing_file, &names, &seen);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        var added: usize = 0;
        for (names.items) |type_name| {
            const res = self.resolver.resolveTypeReferenceDirective(type_name, containing_file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            const target_id = try self.addResolvedIncludeFileFromResolution(res);
            if (target_id == null) continue;
            try self.recordReferenceIncludeReason(target_id.?, .implicit_type_reference, 0, type_name, res.package_id orelse "", 0);
            added += 1;
        }
        return added;
    }

    fn collectImplicitTypeLibraryNames(
        self: *Program,
        cfg: *const tsconfig_mod.TsConfig,
        containing_file: []const u8,
        names: *std.ArrayListUnmanaged([]const u8),
        seen: *std.StringHashMapUnmanaged(void),
    ) ProgramError!void {
        if (cfg.compiler_options.type_roots) |roots| {
            for (roots) |root| {
                if (root.len == 0) continue;
                try self.collectTypeLibraryNamesFromRoot(root, names, seen);
            }
            return;
        }

        var dir = std.fs.path.dirname(containing_file) orelse "";
        while (true) {
            const nm = if (dir.len == 0)
                try self.gpa.dupe(u8, "node_modules")
            else
                try std.fs.path.join(self.gpa, &.{ dir, "node_modules" });
            defer self.gpa.free(nm);
            const at_types = try std.fs.path.join(self.gpa, &.{ nm, "@types" });
            defer self.gpa.free(at_types);
            try self.collectTypeLibraryNamesFromRoot(at_types, names, seen);

            if (dir.len == 0 or std.mem.eql(u8, dir, "/")) break;
            const parent = std.fs.path.dirname(dir) orelse "";
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }
    }

    fn collectTypeLibraryNamesFromRoot(
        self: *Program,
        root: []const u8,
        names: *std.ArrayListUnmanaged([]const u8),
        seen: *std.StringHashMapUnmanaged(void),
    ) ProgramError!void {
        const entries = self.resolver.fs.readDir(self.gpa, root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer ts_resolver.FileSystem.freeDirEntries(self.gpa, entries);
        for (entries) |entry| {
            if (!entry.is_dir or entry.name.len == 0 or entry.name[0] == '.') continue;
            if (entry.name[0] == '@') {
                const scope_root = try std.fs.path.join(self.gpa, &.{ root, entry.name });
                defer self.gpa.free(scope_root);
                try self.collectScopedTypeLibraryNames(scope_root, entry.name, names, seen);
                continue;
            }
            try appendUniqueTypeLibraryName(self.gpa, names, seen, entry.name);
        }
    }

    fn collectScopedTypeLibraryNames(
        self: *Program,
        scope_root: []const u8,
        scope_name: []const u8,
        names: *std.ArrayListUnmanaged([]const u8),
        seen: *std.StringHashMapUnmanaged(void),
    ) ProgramError!void {
        const entries = self.resolver.fs.readDir(self.gpa, scope_root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer ts_resolver.FileSystem.freeDirEntries(self.gpa, entries);
        for (entries) |entry| {
            if (!entry.is_dir or entry.name.len == 0 or entry.name[0] == '.') continue;
            const type_name = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ scope_name, entry.name });
            defer self.gpa.free(type_name);
            try appendUniqueTypeLibraryName(self.gpa, names, seen, type_name);
        }
    }

    fn appendUniqueTypeLibraryName(
        gpa: std.mem.Allocator,
        names: *std.ArrayListUnmanaged([]const u8),
        seen: *std.StringHashMapUnmanaged(void),
        name: []const u8,
    ) ProgramError!void {
        if (seen.contains(name)) return;
        const owned = try gpa.dupe(u8, name);
        const seen_key = try gpa.dupe(u8, name);
        seen.put(gpa, seen_key, {}) catch |err| {
            gpa.free(owned);
            gpa.free(seen_key);
            return err;
        };
        names.append(gpa, owned) catch |err| {
            gpa.free(owned);
            return err;
        };
    }

    fn compilerOptionContainingFile(cfg: *const tsconfig_mod.TsConfig, files: []const *File) []const u8 {
        if (cfg.file_path.len != 0) return cfg.file_path;
        if (files.len != 0) return files[0].path;
        return "";
    }

    fn addResolvedIncludeFile(self: *Program, path: []const u8) ProgramError!?FileId {
        if (self.by_path.get(path) != null) return null;
        const src = self.resolver.fs.readFile(self.gpa, path) catch return null;
        defer self.gpa.free(src);
        return self.add(path, src) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn addResolvedIncludeFileFromResolution(self: *Program, res: ts_resolver.Resolution) ProgramError!?FileId {
        if (self.by_path.get(res.path) != null) return null;
        if (self.deduplicate_packages) {
            if (res.package_id) |package_id| {
                if (package_id.len != 0) {
                    if (self.by_package_id.get(package_id)) |canonical_id| {
                        const canonical = self.files.items[canonical_id];
                        if (!std.mem.eql(u8, canonical.path, res.path)) {
                            return try self.addRedirectFile(res.path, canonical_id);
                        }
                        return null;
                    }
                }
            }
        }

        const added_id = try self.addResolvedIncludeFile(res.path);
        if (self.deduplicate_packages) {
            if (added_id) |id| {
                if (res.package_id) |package_id| {
                    if (package_id.len != 0) {
                        const key = try self.gpa.dupe(u8, package_id);
                        errdefer self.gpa.free(key);
                        try self.by_package_id.put(self.gpa, key, id);
                    }
                }
            }
        }
        return added_id;
    }

    const DefaultLibName = struct {
        lib_name: []const u8,
        target_name: []const u8,
    };

    fn defaultLibNameForTarget(target: ?tsconfig_mod.Target) DefaultLibName {
        const resolved = target orelse return .{ .lib_name = "es2024", .target_name = "" };
        return switch (resolved) {
            .es3, .es5 => .{ .lib_name = "es5", .target_name = "es5" },
            .es2015 => .{ .lib_name = "es2015", .target_name = "es2015" },
            .es2016 => .{ .lib_name = "es2016", .target_name = "es2016" },
            .es2017 => .{ .lib_name = "es2017", .target_name = "es2017" },
            .es2018 => .{ .lib_name = "es2018", .target_name = "es2018" },
            .es2019 => .{ .lib_name = "es2019", .target_name = "es2019" },
            .es2020 => .{ .lib_name = "es2020", .target_name = "es2020" },
            .es2021 => .{ .lib_name = "es2021", .target_name = "es2021" },
            .es2022 => .{ .lib_name = "es2022", .target_name = "es2022" },
            .es2023 => .{ .lib_name = "es2023", .target_name = "es2023" },
            .es2024 => .{ .lib_name = "es2024", .target_name = "es2024" },
            .es2025 => .{ .lib_name = "es2025", .target_name = "es2025" },
            .esnext => .{ .lib_name = "esnext", .target_name = "esnext" },
        };
    }

    /// Resolve a triple-slash reference path (a literal file path) to a
    /// program-canonical path relative to the file that contains the
    /// directive. Normalizes `.`/`..` via `resolvePosix`; absolute paths
    /// pass through. Caller owns the returned slice.
    fn joinReferencePath(self: *Program, containing_file: []const u8, ref: []const u8) error{OutOfMemory}![]u8 {
        if (std.fs.path.dirname(containing_file)) |dir| {
            return std.fs.path.resolvePosix(self.gpa, &.{ dir, ref });
        }
        return std.fs.path.resolvePosix(self.gpa, &.{ref});
    }

    fn recordReferenceIncludeReason(
        self: *Program,
        target_id: FileId,
        kind: IncludeKind,
        importer: FileId,
        text: []const u8,
        package_id: []const u8,
        pos: u32,
    ) ProgramError!void {
        try self.recordReferenceIncludeReasonWithProjectOutput(target_id, kind, importer, text, package_id, "", pos);
    }

    fn recordReferenceIncludeReasonWithProjectOutput(
        self: *Program,
        target_id: FileId,
        kind: IncludeKind,
        importer: FileId,
        text: []const u8,
        package_id: []const u8,
        project_reference_output: []const u8,
        pos: u32,
    ) ProgramError!void {
        const target = self.files.items[target_id];
        if (target.include_reason != null) return;
        target.include_reason = .{
            .kind = kind,
            .importer = importer,
            .specifier_text = try self.gpa.dupe(u8, text),
            .package_id = if (package_id.len == 0) "" else try self.gpa.dupe(u8, package_id),
            .project_reference_output = if (project_reference_output.len == 0) "" else try self.gpa.dupe(u8, project_reference_output),
            .specifier_pos = pos,
        };
    }

    fn resolveLibReferencePath(self: *Program, containing_file: []const u8, name: []const u8) error{OutOfMemory}!?[]u8 {
        if (name.len == 0) return null;
        const file_name = try std.fmt.allocPrint(self.gpa, "lib.{s}.d.ts", .{name});
        defer self.gpa.free(file_name);
        var dir = std.fs.path.dirname(containing_file) orelse "";
        while (true) {
            const candidate = if (dir.len == 0)
                try self.gpa.dupe(u8, file_name)
            else
                try std.fs.path.join(self.gpa, &.{ dir, file_name });
            if (self.resolver.fs.fileExists(candidate)) return candidate;
            self.gpa.free(candidate);
            if (dir.len == 0 or std.mem.eql(u8, dir, "/")) break;
            const parent = std.fs.path.dirname(dir) orelse "";
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }
        return null;
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
        try self.prepareNameStore();
        var count: u32 = 0;
        for (changed_paths) |p| {
            const id = self.by_path.get(p) orelse continue;
            const f = self.files.items[id];
            // Free the previous compilation so the new one owns
            // a fresh HIR + symbol table.
            self.dropCompilation(f);
            // Clear any cached import edges — they'll be repopulated
            // by resolveImports below.
            f.imports.clearRetainingCapacity();

            try self.compileFile(f, options);
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
            if (f.redirect_target != null) continue;
            try self.appendMissingImportedHelperDiagnosticsForFile(f, options);
        }
    }

    const ProgramDeclareVar = struct {
        name: []const u8,
        type_text: []const u8,
    };

    const ProgramGlobalInterfaceMember = struct {
        file_index: usize,
        interface_name: []const u8,
        member_name: []const u8,
        pos: u32,
        is_method: bool,
    };

    const ProgramAmbientExportBinding = struct {
        file_index: usize,
        module_name: []const u8,
        name: []const u8,
        pos: usize,
        is_block_scoped: bool,
    };

    fn appendMergedAmbientModuleExportDiagnostics(self: *Program) ProgramError!void {
        var bindings: std.ArrayListUnmanaged(ProgramAmbientExportBinding) = .empty;
        defer bindings.deinit(self.gpa);
        for (self.files.items, 0..) |f, file_index| {
            if (f.redirect_target != null or !f.is_declaration) continue;
            try collectAmbientExportBindingsFromSource(f.source, file_index, &bindings, self.gpa);
        }
        for (bindings.items, 0..) |binding, i| {
            for (bindings.items[0..i]) |previous| {
                if (binding.file_index == previous.file_index or
                    !std.mem.eql(u8, binding.module_name, previous.module_name) or
                    !std.mem.eql(u8, binding.name, previous.name) or
                    (!binding.is_block_scoped and !previous.is_block_scoped)) continue;
                try self.appendAmbientExportRedeclareDiagnostic(previous);
                try self.appendAmbientExportRedeclareDiagnostic(binding);
            }
        }
    }

    fn appendAmbientExportRedeclareDiagnostic(self: *Program, binding: ProgramAmbientExportBinding) ProgramError!void {
        const file = self.files.items[binding.file_index];
        const compilation = file.compilation orelse return;
        if (diagnosticExistsAt(compilation, 2451, @intCast(binding.pos))) return;
        const message = try std.fmt.allocPrint(
            self.gpa,
            "Cannot redeclare block-scoped variable '{s}'.",
            .{binding.name},
        );
        try compilation.diagnostics.append(self.gpa, .{
            .phase = .bind,
            .pos = @intCast(binding.pos),
            .line = 0,
            .span_len = @intCast(binding.name.len),
            .code = 2451,
            .message = message,
        });
        compilation.has_errors = true;
    }

    fn collectAmbientExportBindingsFromSource(
        source: []const u8,
        file_index: usize,
        out: *std.ArrayListUnmanaged(ProgramAmbientExportBinding),
        gpa: std.mem.Allocator,
    ) ProgramError!void {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_start, "declare")) |declare_pos| {
            search_start = declare_pos + "declare".len;
            if (!identifierKeywordAt(source, declare_pos, "declare")) continue;
            var module_pos = declare_pos + "declare".len;
            while (module_pos < source.len and std.ascii.isWhitespace(source[module_pos])) : (module_pos += 1) {}
            if (!identifierKeywordAt(source, module_pos, "module")) continue;
            module_pos += "module".len;
            while (module_pos < source.len and std.ascii.isWhitespace(source[module_pos])) : (module_pos += 1) {}
            if (module_pos >= source.len or (source[module_pos] != '"' and source[module_pos] != '\'')) continue;
            const quote = source[module_pos];
            const name_start = module_pos + 1;
            const name_end = std.mem.indexOfScalarPos(u8, source, name_start, quote) orelse continue;
            const body_open = std.mem.indexOfScalarPos(u8, source, name_end + 1, '{') orelse continue;
            const body_close = findMatchingBrace(source, body_open) orelse continue;
            const module_name = source[name_start..name_end];
            var export_search = body_open + 1;
            while (std.mem.indexOfPos(u8, source, export_search, "export")) |export_pos| {
                if (export_pos >= body_close) break;
                export_search = export_pos + "export".len;
                if (!identifierKeywordAt(source, export_pos, "export")) continue;
                var cursor = export_pos + "export".len;
                while (cursor < body_close and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
                if (cursor < body_close and source[cursor] == '{') {
                    const close = std.mem.indexOfScalarPos(u8, source, cursor + 1, '}') orelse continue;
                    if (close > body_close) continue;
                    cursor += 1;
                    while (cursor < close) {
                        while (cursor < close and (std.ascii.isWhitespace(source[cursor]) or source[cursor] == ',')) : (cursor += 1) {}
                        const local_end = parseIdentifierEnd(source, cursor, close) orelse break;
                        var exported_start = cursor;
                        var exported_end = local_end;
                        var after = local_end;
                        while (after < close and std.ascii.isWhitespace(source[after])) : (after += 1) {}
                        if (identifierKeywordAt(source, after, "as")) {
                            after += "as".len;
                            while (after < close and std.ascii.isWhitespace(source[after])) : (after += 1) {}
                            if (parseIdentifierEnd(source, after, close)) |alias_end| {
                                exported_start = after;
                                exported_end = alias_end;
                            }
                        }
                        try out.append(gpa, .{
                            .file_index = file_index,
                            .module_name = module_name,
                            .name = source[exported_start..exported_end],
                            .pos = exported_start,
                            .is_block_scoped = true,
                        });
                        cursor = exported_end;
                    }
                    export_search = close + 1;
                    continue;
                }
                const keywords = [_][]const u8{ "const", "let", "var" };
                for (keywords) |keyword| {
                    if (!identifierKeywordAt(source, cursor, keyword)) continue;
                    var binding_start = cursor + keyword.len;
                    while (binding_start < body_close and std.ascii.isWhitespace(source[binding_start])) : (binding_start += 1) {}
                    const binding_end = parseIdentifierEnd(source, binding_start, body_close) orelse break;
                    try out.append(gpa, .{
                        .file_index = file_index,
                        .module_name = module_name,
                        .name = source[binding_start..binding_end],
                        .pos = binding_start,
                        .is_block_scoped = !std.mem.eql(u8, keyword, "var"),
                    });
                    break;
                }
            }
            search_start = body_close + 1;
        }
    }

    fn appendProgramGlobalDeclareVarDiagnostics(self: *Program) ProgramError!void {
        var seen: std.StringHashMapUnmanaged(ProgramDeclareVar) = .empty;
        defer {
            var it = seen.iterator();
            while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
            seen.deinit(self.gpa);
        }

        for (self.files.items) |f| {
            if (f.redirect_target != null or !f.is_declaration) continue;
            const c = f.compilation orelse continue;
            if (boundSourceIsExternalModule(c)) continue;
            var offset: usize = 0;
            var lines = std.mem.splitScalar(u8, f.source, '\n');
            while (lines.next()) |raw_line| {
                defer offset += raw_line.len + 1;
                const line_without_cr = std.mem.trim(u8, raw_line, "\r");
                var leading: usize = 0;
                while (leading < line_without_cr.len and
                    (line_without_cr[leading] == ' ' or line_without_cr[leading] == '\t')) : (leading += 1)
                {}
                const line = line_without_cr[leading..];
                const decl = parseDeclareVarLine(line) orelse continue;
                const gop = try seen.getOrPut(self.gpa, decl.name);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.gpa.dupe(u8, decl.name);
                    gop.value_ptr.* = .{
                        .name = gop.key_ptr.*,
                        .type_text = decl.type_text,
                    };
                    continue;
                }
                const prior = gop.value_ptr.*;
                if (std.mem.eql(u8, prior.type_text, decl.type_text)) continue;
                if (diagnosticExistsAt(c, 2403, @intCast(offset + leading + decl.name_start))) continue;
                const msg = try std.fmt.allocPrint(
                    self.gpa,
                    "Subsequent variable declarations must have the same type.  Variable '{s}' must be of type '{s}', but here has type '{s}'.",
                    .{ decl.name, prior.type_text, decl.type_text },
                );
                try c.diagnostics.append(self.gpa, .{
                    .phase = .bind,
                    .pos = @intCast(offset + leading + decl.name_start),
                    .line = 0,
                    .span_len = @intCast(decl.name.len),
                    .code = 2403,
                    .message = msg,
                });
                c.has_errors = true;
            }
        }
    }

    fn appendProgramGlobalInterfaceMemberDiagnostics(self: *Program) ProgramError!void {
        var members: std.ArrayListUnmanaged(ProgramGlobalInterfaceMember) = .empty;
        defer members.deinit(self.gpa);

        for (self.files.items, 0..) |file, file_index| {
            if (file.redirect_target != null) continue;
            const compilation = file.compilation orelse continue;
            if (boundSourceIsExternalModule(compilation)) continue;
            if (compilation.hir.kindOf(compilation.root) != .block_stmt) continue;
            for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |statement| {
                if (compilation.hir.kindOf(statement) != .interface_decl) continue;
                const interface_decl = hir_mod_ns.interfaceOf(&compilation.hir, statement);
                if (interface_decl.name == hir_mod_ns.none_node_id or
                    compilation.hir.kindOf(interface_decl.name) != .identifier) continue;
                const interface_name = compilation.interner.get(
                    hir_mod_ns.identifierOf(&compilation.hir, interface_decl.name).name,
                );
                for (hir_mod_ns.interfaceMembers(&compilation.hir, statement)) |member_node| {
                    if (compilation.hir.kindOf(member_node) != .interface_member) continue;
                    const member = hir_mod_ns.interfaceMemberOf(&compilation.hir, member_node);
                    if (member.name == 0) continue;
                    const member_name = compilation.interner.get(member.name);
                    if (std.mem.startsWith(u8, member_name, "__")) continue;
                    try members.append(self.gpa, .{
                        .file_index = file_index,
                        .interface_name = interface_name,
                        .member_name = member_name,
                        .pos = compilation.hir.spanOf(member_node).start,
                        .is_method = member.is_method,
                    });
                }
            }
        }

        for (members.items, 0..) |member, i| {
            for (members.items[0..i]) |previous| {
                if (member.file_index == previous.file_index or
                    member.is_method == previous.is_method or
                    !std.mem.eql(u8, member.interface_name, previous.interface_name) or
                    !std.mem.eql(u8, member.member_name, previous.member_name)) continue;
                try self.appendProgramGlobalInterfaceMemberDiagnostic(previous, member);
                try self.appendProgramGlobalInterfaceMemberDiagnostic(member, previous);
            }
        }
    }

    fn appendProgramGlobalInterfaceMemberDiagnostic(
        self: *Program,
        member: ProgramGlobalInterfaceMember,
        other: ProgramGlobalInterfaceMember,
    ) ProgramError!void {
        const file = self.files.items[member.file_index];
        const other_file = self.files.items[other.file_index];
        const compilation = file.compilation orelse return;
        if (diagnosticExistsAt(compilation, 2300, member.pos)) return;

        const related = try self.gpa.alloc(ts_driver.RelatedInfo, 1);
        const related_message = std.fmt.allocPrint(
            self.gpa,
            "'{s}' was also declared here.",
            .{member.member_name},
        ) catch |err| {
            self.gpa.free(related);
            return err;
        };
        const related_file = self.gpa.dupe(u8, other_file.path) catch |err| {
            self.gpa.free(related_message);
            self.gpa.free(related);
            return err;
        };
        related[0] = .{
            .code = 6203,
            .message = related_message,
            .pos = other.pos,
            .span_len = @intCast(other.member_name.len),
            .file = related_file,
        };
        const message = std.fmt.allocPrint(
            self.gpa,
            "Duplicate identifier '{s}'.",
            .{member.member_name},
        ) catch |err| {
            self.gpa.free(related_file);
            self.gpa.free(related_message);
            self.gpa.free(related);
            return err;
        };
        compilation.diagnostics.append(self.gpa, .{
            .phase = .bind,
            .pos = member.pos,
            .line = 0,
            .span_len = @intCast(member.member_name.len),
            .code = 2300,
            .message = message,
            .related = related,
        }) catch |err| {
            self.gpa.free(message);
            self.gpa.free(related_file);
            self.gpa.free(related_message);
            self.gpa.free(related);
            return err;
        };
        compilation.has_errors = true;
    }

    const ParsedDeclareVar = struct {
        name: []const u8,
        name_start: usize,
        type_text: []const u8,
    };

    fn parseDeclareVarLine(line: []const u8) ?ParsedDeclareVar {
        const prefix = "declare var";
        if (!std.mem.startsWith(u8, line, prefix)) return null;
        var i: usize = prefix.len;
        if (i >= line.len or (line[i] != ' ' and line[i] != '\t')) return null;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len or !isIdentifierStart(line[i])) return null;
        const name_start = i;
        i += 1;
        while (i < line.len and isIdentifierContinue(line[i])) : (i += 1) {}
        const name = line[name_start..i];
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len or line[i] != ':') return .{
            .name = name,
            .name_start = name_start,
            .type_text = "any",
        };
        i += 1;
        const type_start_raw = i;
        const semi = std.mem.indexOfScalarPos(u8, line, i, ';') orelse line.len;
        const type_text = std.mem.trim(u8, line[type_start_raw..semi], " \t\r");
        if (type_text.len == 0) return null;
        return .{
            .name = name,
            .name_start = name_start,
            .type_text = type_text,
        };
    }

    fn diagnosticExistsAt(c: *const ts_driver.Compilation, code: u32, pos: u32) bool {
        for (c.diagnostics.items) |d| {
            if (d.code == code and d.pos == pos) return true;
        }
        return false;
    }

    fn appendMissingImportedHelperDiagnosticsForFile(self: *Program, f: *File, options: ts_driver.CompileOptions) ProgramError!void {
        if (!options.emit.import_helpers) return;
        if (f.is_declaration) return;
        if (legacyDecoratorsEnabled(f.source, options)) return;
        const c = f.compilation orelse return;
        const commonjs_module = importedHelpersUseCommonJs(options);
        const tslib = self.findTslibDeclaration() orelse {
            if (sourceExternalEmitHelperPosition(
                c,
                f.source,
                commonjs_module,
                options.emit.es_target == .es5,
                options.emit.es_target != .esnext or
                    options.resource_management_helpers_required or
                    sourceTargetNeedsResourceLowering(f.source),
            )) |pos| {
                try c.diagnostics.append(self.gpa, .{
                    .phase = .bind,
                    .pos = @intCast(pos),
                    .line = 0,
                    .span_len = 0,
                    .code = 2354,
                    .message = try self.gpa.dupe(u8, "This syntax requires an imported helper but module 'tslib' cannot be found."),
                });
                c.has_errors = true;
            }
            return;
        };

        try appendImportedPrivateHelperArityDiagnostics(self.gpa, c, f.source, tslib.source);
        if (options.emit.es_target == .es5) {
            try appendImportedArraySpreadHelperArityDiagnostic(self.gpa, c, tslib.source);
        }
        try ts_driver.appendMissingStage3DecoratorHelperDiagnostics(
            self.gpa,
            c,
            f.source,
            tslib.source,
            options.emit.es_target != .esnext,
        );
        if (commonjs_module) {
            try appendMissingCommonJsInteropHelperDiagnostics(self.gpa, c, tslib.source);
        }
        sortDiagnosticsBySourceOrder(c.diagnostics.items);
    }

    fn importedHelpersUseCommonJs(options: ts_driver.CompileOptions) bool {
        if (options.emit.module_kind == .commonjs) return true;
        if (std.ascii.eqlIgnoreCase(options.module_kind, "commonjs") or
            std.ascii.eqlIgnoreCase(options.module_kind, "amd") or
            std.ascii.eqlIgnoreCase(options.module_kind, "umd") or
            std.ascii.eqlIgnoreCase(options.module_kind, "system"))
        {
            return true;
        }
        if (options.pub_tsconfig) |config| {
            if (config.compiler_options.module) |module| {
                return switch (module) {
                    .commonjs, .amd, .umd, .system => true,
                    else => false,
                };
            }
        }
        return false;
    }

    fn appendImportedPrivateHelperArityDiagnostics(
        gpa: std.mem.Allocator,
        c: *ts_driver.Compilation,
        source: []const u8,
        tslib_source: []const u8,
    ) ProgramError!void {
        const hash_pos = firstPrivateIdentifierHash(source) orelse return;
        const uses = privateHelperUses(source);
        const checks = [_]struct { name: []const u8, required: usize, use: ?HelperUse }{
            .{ .name = "__classPrivateFieldGet", .required = 4, .use = uses.get },
            .{ .name = "__classPrivateFieldSet", .required = 5, .use = uses.set },
        };
        for (checks) |check| {
            const actual = helperParameterCount(tslib_source, check.name) orelse {
                if (check.use) |use| try appendMissingNamedHelperDiagnostic(gpa, c, check.name, use);
                continue;
            };
            if (actual >= check.required) continue;
            const msg = try std.fmt.allocPrint(
                gpa,
                "This syntax requires an imported helper named '{s}' with {d} parameters, which is not compatible with the one in 'tslib'. Consider upgrading your version of 'tslib'.",
                .{ check.name, check.required },
            );
            try c.diagnostics.append(gpa, .{
                .phase = .bind,
                .pos = @intCast(if (check.use) |use| use.pos else hash_pos),
                .line = 0,
                .span_len = @intCast(check.name.len),
                .code = 2807,
                .message = msg,
            });
            c.has_errors = true;
        }
    }

    fn appendImportedArraySpreadHelperArityDiagnostic(
        gpa: std.mem.Allocator,
        c: *ts_driver.Compilation,
        tslib_source: []const u8,
    ) ProgramError!void {
        const use = firstArraySpreadUse(&c.hir) orelse return;
        const actual = helperParameterCount(tslib_source, "__spreadArray") orelse {
            try appendMissingNamedHelperDiagnostic(gpa, c, "__spreadArray", use);
            return;
        };
        if (actual >= 3) return;
        const msg = try gpa.dupe(
            u8,
            "This syntax requires an imported helper named '__spreadArray' with 3 parameters, which is not compatible with the one in 'tslib'. Consider upgrading your version of 'tslib'.",
        );
        try c.diagnostics.append(gpa, .{
            .phase = .bind,
            .pos = @intCast(use.pos),
            .line = 0,
            .span_len = @intCast(use.span_len),
            .code = 2807,
            .message = msg,
        });
        c.has_errors = true;
    }

    fn appendMissingCommonJsInteropHelperDiagnostics(
        gpa: std.mem.Allocator,
        c: *ts_driver.Compilation,
        tslib_source: []const u8,
    ) ProgramError!void {
        var node: hir_mod_ns.NodeId = 1;
        while (node < c.hir.nodeCount()) : (node += 1) {
            if (c.hir.kindOf(node) != .import_decl) continue;
            const import = hir_mod_ns.importOf(&c.hir, node);
            if (import.is_type_only or import.is_require_equals or import.import_equals != hir_mod_ns.none_node_id) continue;
            const helper: []const u8 = if (import.namespace_binding != hir_mod_ns.none_node_id)
                "__importStar"
            else if (import.default_binding != hir_mod_ns.none_node_id)
                "__importDefault"
            else
                continue;
            if (std.mem.indexOf(u8, tslib_source, helper) != null) continue;
            const span = c.hir.spanOf(node);
            try appendMissingNamedHelperDiagnostic(gpa, c, helper, .{
                .pos = span.start,
                .span_len = span.end - span.start,
            });
        }
    }

    fn appendMissingNamedHelperDiagnostic(
        gpa: std.mem.Allocator,
        c: *ts_driver.Compilation,
        helper: []const u8,
        use: HelperUse,
    ) ProgramError!void {
        for (c.diagnostics.items) |diagnostic| {
            if (diagnostic.code == 2343 and
                diagnostic.pos == @as(u32, @intCast(use.pos)) and
                std.mem.indexOf(u8, diagnostic.message, helper) != null)
            {
                return;
            }
        }
        const msg = try std.fmt.allocPrint(
            gpa,
            "This syntax requires an imported helper named '{s}' which does not exist in 'tslib'. Consider upgrading your version of 'tslib'.",
            .{helper},
        );
        try c.diagnostics.append(gpa, .{
            .phase = .bind,
            .pos = @intCast(use.pos),
            .line = 0,
            .span_len = @intCast(use.span_len),
            .code = 2343,
            .message = msg,
        });
        c.has_errors = true;
    }

    const HelperUse = struct {
        pos: usize,
        span_len: usize,
    };

    const PrivateHelperUses = struct {
        get: ?HelperUse = null,
        set: ?HelperUse = null,
    };

    fn privateHelperUses(source: []const u8) PrivateHelperUses {
        var uses: PrivateHelperUses = .{};
        var search_from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, source, search_from, '#')) |hash| {
            search_from = hash + 1;
            if (positionInLineComment(source, hash) or positionInBlockComment(source, hash)) continue;
            if (hash == 0 or source[hash - 1] != '.') continue;
            if (hash + 1 >= source.len or !isIdentifierStart(source[hash + 1])) continue;
            var after_name = hash + 2;
            while (after_name < source.len and isIdentifierContinue(source[after_name])) after_name += 1;
            const op = skipTrivia(source, after_name);
            const simple_write = op < source.len and source[op] == '=' and
                (op + 1 >= source.len or (source[op + 1] != '=' and source[op + 1] != '>'));
            const compound_write = op + 1 < source.len and source[op + 1] == '=' and
                std.mem.indexOfScalar(u8, "+-*/%&|^", source[op]) != null;
            const update = op + 1 < source.len and
                ((source[op] == '+' and source[op + 1] == '+') or
                    (source[op] == '-' and source[op + 1] == '-'));
            const destructuring_write = privateAccessIsInDestructuringAssignment(source, hash - 1);
            var access_start = hash - 1;
            while (access_start > 0 and isIdentifierContinue(source[access_start - 1])) access_start -= 1;
            const use: HelperUse = .{ .pos = access_start, .span_len = after_name - access_start };
            const writes = simple_write or compound_write or update or destructuring_write;
            if (writes and uses.set == null) uses.set = use;
            if ((!simple_write or compound_write or update) and !destructuring_write and uses.get == null) uses.get = use;
            if (uses.get != null and uses.set != null) break;
        }
        return uses;
    }

    fn privateAccessIsInDestructuringAssignment(source: []const u8, access_start: usize) bool {
        var depth: usize = 0;
        var open_brace: ?usize = null;
        var cursor = access_start;
        while (cursor > 0) {
            cursor -= 1;
            switch (source[cursor]) {
                '}' => depth += 1,
                '{' => {
                    if (depth == 0) {
                        open_brace = cursor;
                        break;
                    }
                    depth -= 1;
                },
                ';' => if (depth == 0) break,
                else => {},
            }
        }
        const open = open_brace orelse return false;
        depth = 0;
        cursor = open;
        while (cursor < source.len) : (cursor += 1) {
            switch (source[cursor]) {
                '{' => depth += 1,
                '}' => {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth != 0) continue;
                    var after = skipTrivia(source, cursor + 1);
                    while (after < source.len and source[after] == ')') after = skipTrivia(source, after + 1);
                    return after < source.len and source[after] == '=' and
                        (after + 1 >= source.len or (source[after + 1] != '=' and source[after + 1] != '>'));
                },
                else => {},
            }
        }
        return false;
    }

    fn sourceExternalEmitHelperPosition(
        c: *const ts_driver.Compilation,
        source: []const u8,
        commonjs_module: bool,
        lower_array_spread: bool,
        lower_resource_declarations: bool,
    ) ?usize {
        var best: ?usize = null;
        if (firstPrivateIdentifierHash(source)) |hash| best = minOptionalPos(best, hash);
        if (lower_array_spread) {
            if (firstArraySpreadUse(&c.hir)) |use| best = minOptionalPos(best, use.pos);
        }
        if (lower_resource_declarations) {
            if (firstResourceDeclarationPosition(&c.hir)) |using_pos| best = minOptionalPos(best, using_pos);
        }
        if (commonjs_module) {
            if (firstExportStarAsNamespace(source)) |export_pos| best = minOptionalPos(best, export_pos);
            if (firstCommonJsInteropImportPosition(c)) |import_pos| best = minOptionalPos(best, import_pos);
        }
        return best;
    }

    fn firstArraySpreadUse(hir: *const hir_mod_ns.Hir) ?HelperUse {
        var best: ?HelperUse = null;
        var node: hir_mod_ns.NodeId = 1;
        while (node < hir.nodeCount()) : (node += 1) {
            if (hir.kindOf(node) != .array_literal) continue;
            for (hir_mod_ns.arrayLiteralElements(hir, node)) |element| {
                if (element == hir_mod_ns.none_node_id or hir.kindOf(element) != .spread) continue;
                const span = hir.spanOf(element);
                const use: HelperUse = .{ .pos = span.start, .span_len = span.end - span.start };
                if (best == null or use.pos < best.?.pos) best = use;
            }
        }
        return best;
    }

    fn firstCommonJsInteropImportPosition(c: *const ts_driver.Compilation) ?usize {
        var best: ?usize = null;
        var node: hir_mod_ns.NodeId = 1;
        while (node < c.hir.nodeCount()) : (node += 1) {
            if (c.hir.kindOf(node) != .import_decl) continue;
            const import = hir_mod_ns.importOf(&c.hir, node);
            if (import.is_type_only or import.is_require_equals or import.import_equals != hir_mod_ns.none_node_id) continue;
            if (import.default_binding == hir_mod_ns.none_node_id and import.namespace_binding == hir_mod_ns.none_node_id) continue;
            best = minOptionalPos(best, c.hir.spanOf(node).start);
        }
        return best;
    }

    fn sourceTargetNeedsResourceLowering(source: []const u8) bool {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r/*");
            if (!std.mem.startsWith(u8, line, "@target")) continue;
            const target = std.mem.trim(u8, line["@target".len..], " \t:");
            var parts = std.mem.splitScalar(u8, target, ',');
            while (parts.next()) |raw_part| {
                const part = std.mem.trim(u8, raw_part, " \t\r");
                if (std.ascii.eqlIgnoreCase(part, "esnext")) return false;
            }
            return true;
        }
        return false;
    }

    fn firstResourceDeclarationPosition(hir: *const hir_mod_ns.Hir) ?usize {
        var best: ?usize = null;
        var node: hir_mod_ns.NodeId = 1;
        while (node < hir.nodeCount()) : (node += 1) {
            switch (hir.kindOf(node)) {
                .var_decl, .let_decl, .const_decl => {},
                else => continue,
            }
            const decl = hir_mod_ns.varDeclOf(hir, node);
            if (!decl.is_using and !decl.is_await_using) continue;
            const pos: usize = hir.spanOf(node).start;
            best = minOptionalPos(best, pos);
        }
        return best;
    }

    fn minOptionalPos(current: ?usize, candidate: usize) usize {
        return if (current) |pos| @min(pos, candidate) else candidate;
    }

    fn firstExportStarAsNamespace(source: []const u8) ?usize {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, source, i, "export")) |export_pos| {
            i = export_pos + "export".len;
            if (positionInLineComment(source, export_pos) or positionInBlockComment(source, export_pos)) continue;
            if (export_pos > 0 and isIdentifierContinue(source[export_pos - 1])) continue;
            if (i < source.len and isIdentifierContinue(source[i])) continue;

            var p = skipTrivia(source, i);
            if (p >= source.len or source[p] != '*') continue;
            p = skipTrivia(source, p + 1);
            if (p + "as".len > source.len or !std.mem.eql(u8, source[p .. p + "as".len], "as")) continue;
            if (p > 0 and isIdentifierContinue(source[p - 1])) continue;
            if (p + "as".len < source.len and isIdentifierContinue(source[p + "as".len])) continue;
            return export_pos;
        }
        return null;
    }

    fn firstPrivateIdentifierHash(source: []const u8) ?usize {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, source, i, '#')) |hash| {
            if (positionInLineComment(source, hash) or positionInBlockComment(source, hash)) {
                i = hash + 1;
                continue;
            }
            if (hash + 1 < source.len and isIdentifierStart(source[hash + 1])) return hash;
            i = hash + 1;
        }
        return null;
    }

    fn helperParameterCount(tslib_source: []const u8, name: []const u8) ?usize {
        const name_pos = std.mem.indexOf(u8, tslib_source, name) orelse return null;
        const open_rel = std.mem.indexOfScalar(u8, tslib_source[name_pos + name.len ..], '(') orelse return null;
        const params_start = name_pos + name.len + open_rel + 1;
        const close_rel = std.mem.indexOfScalar(u8, tslib_source[params_start..], ')') orelse return null;
        const params = std.mem.trim(u8, tslib_source[params_start .. params_start + close_rel], " \t\r\n");
        if (params.len == 0) return 0;
        var count: usize = 1;
        for (params) |c_param| {
            if (c_param == ',') count += 1;
        }
        return count;
    }

    fn findTslibDeclaration(self: *Program) ?*File {
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            const base = std.fs.path.basename(f.path);
            if (std.mem.eql(u8, base, "tslib.d.ts")) return f;
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
                if ((a.code == 2300 and b.code == 1005) or
                    (a.code == 1005 and b.code == 2300))
                {
                    return a.code == 2300;
                }
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
// `selectDiagnosticBasedOnModuleName`.
//
// `moduleExportNestedTypeSpaceName` supplies the second fact upstream's
// `isSymbolAccessibleWorker` needs to reach `Accessibility ==
// CannotBeNamed`: a name that is reachable in the resolved module as a
// type-space member NESTED inside an exported namespace (e.g.
// `Widgets.SpecializedWidget.Widget2`) but is NOT itself a direct
// top-level export. Such a symbol has no direct import alias the
// importing file can write into the `.d.ts`, so its accessible-symbol
// chain from the importing scope is empty while it still originates in a
// different external module — exactly the `CannotBeNamed` branch of
// `isSymbolAccessibleWorker` (`symbolExternalModule != enclosing`). The
// emit then selects the `... but cannot be named` message via
// `selectDiagnosticBasedOnModuleName(... moduleNotNameable ...)`.

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
    return moduleExportsTypeSpaceNameFromCompilation(compilation, name);
}

fn moduleExportsTypeSpaceNameFromCompilation(
    compilation: *const ts_driver.Compilation,
    name: []const u8,
) bool {
    // Query the TYPE-space symbol table specifically: a class declares
    // into both value and type space as separate symbols, and the
    // generic `lookupTopLevel` returns the value symbol first (which has
    // is_type=false). We want the type-space binding, so consult
    // `module.root.types` directly.
    const id = compilation.interner.lookup(name) orelse return false;
    const sym = compilation.module.root.types.get(id) orelse return false;
    return sym.flags.is_type and sym.flags.is_export;
}

/// True when `module_source` declares `name` as an exported value-space
/// symbol at module scope. Used alongside `moduleExportsTypeSpaceName`
/// to distinguish classes/enums (type+value) from interfaces/type
/// aliases (type-only declarations) for verbatim-module import checks.
pub fn moduleExportsValueSpaceName(
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
    return moduleExportsValueSpaceNameFromCompilation(compilation, name);
}

fn moduleExportsValueSpaceNameFromCompilation(
    compilation: *const ts_driver.Compilation,
    name: []const u8,
) bool {
    const id = compilation.interner.lookup(name) orelse return false;
    if (!moduleRootHasEsmExportSyntax(&compilation.hir, compilation.root)) {
        if (moduleRootCommonJsDefinePropertyReadonlyStatus(
            &compilation.hir,
            &compilation.interner,
            compilation.root,
            id,
        ) != null) return true;
        if (moduleRootHasCommonJsExportedRuntimeValue(&compilation.hir, &compilation.interner, compilation.root, id)) return true;
    }
    const sym = compilation.module.root.values.get(id) orelse return false;
    if (sym.flags.is_type) return false;
    return moduleRootHasExportedRuntimeValue(&compilation.hir, compilation.root, id);
}

const CommonJsDefinePropertyExport = struct {
    name: hir_mod_ns.StringId,
    is_readonly: bool,
};

fn moduleRootCommonJsDefinePropertyReadonlyStatus(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    root: hir_mod_ns.NodeId,
    wanted_name: hir_mod_ns.StringId,
) ?bool {
    if (hir.kindOf(root) != .block_stmt) return null;
    var found = false;
    var is_readonly = true;
    for (hir_mod_ns.blockStmts(hir, root)) |stmt| {
        const defined = moduleCommonJsDefinePropertyExport(hir, interner, root, stmt) orelse continue;
        if (defined.name != wanted_name) continue;
        found = true;
        is_readonly = is_readonly and defined.is_readonly;
    }
    return if (found) is_readonly else null;
}

fn moduleCommonJsDefinePropertyExport(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    root: hir_mod_ns.NodeId,
    stmt: hir_mod_ns.NodeId,
) ?CommonJsDefinePropertyExport {
    if (hir.kindOf(stmt) != .call_expr) return null;
    const call = hir_mod_ns.callOf(hir, stmt);
    const callee_name = commonJsPropertyAccessName(hir, call.callee) orelse return null;
    if (!std.mem.eql(u8, interner.get(callee_name), "defineProperty")) return null;
    const callee_object = commonJsPropertyAccessObject(hir, call.callee) orelse return null;
    if (hir.kindOf(callee_object) != .identifier or
        !std.mem.eql(u8, interner.get(hir_mod_ns.identifierOf(hir, callee_object).name), "Object")) return null;
    const args = hir_mod_ns.callArgs(hir, stmt);
    if (args.len < 3 or hir.kindOf(args[1]) != .literal_string) return null;
    const target_is_exports = if (hir.kindOf(args[0]) == .identifier)
        std.mem.eql(u8, interner.get(hir_mod_ns.identifierOf(hir, args[0]).name), "exports")
    else
        commonJsModuleExportsAccess(hir, interner, args[0]);
    if (!target_is_exports) return null;
    const descriptor = moduleDefinePropertyDescriptorObject(hir, root, args[2]) orelse return null;

    var has_value = false;
    var has_getter = false;
    var has_setter = false;
    var writable = false;
    for (hir_mod_ns.objectLiteralProps(hir, descriptor)) |prop_node| {
        if (hir.kindOf(prop_node) != .object_property) continue;
        const property = hir_mod_ns.objectPropertyOf(hir, prop_node);
        const property_name = moduleObjectPropertyName(hir, property.key) orelse continue;
        const text = interner.get(property_name);
        if (std.mem.eql(u8, text, "value")) {
            has_value = true;
        } else if (std.mem.eql(u8, text, "get")) {
            has_getter = true;
        } else if (std.mem.eql(u8, text, "set")) {
            has_setter = true;
        } else if (std.mem.eql(u8, text, "writable") and
            property.value != hir_mod_ns.none_node_id and
            hir.kindOf(property.value) == .literal_bool)
        {
            writable = hir_mod_ns.literalBoolOf(hir, property.value);
        }
    }
    const has_accessor = has_getter or has_setter;
    return .{
        .name = hir_mod_ns.literalStringOf(hir, args[1]).value,
        .is_readonly = if (has_accessor) !has_setter else !has_value or !writable,
    };
}

fn moduleDefinePropertyDescriptorObject(
    hir: *const hir_mod_ns.Hir,
    root: hir_mod_ns.NodeId,
    node: hir_mod_ns.NodeId,
) ?hir_mod_ns.NodeId {
    if (node == hir_mod_ns.none_node_id) return null;
    if (hir.kindOf(node) == .object_literal) return node;
    if (hir.kindOf(node) != .identifier or hir.kindOf(root) != .block_stmt) return null;
    const name = hir_mod_ns.identifierOf(hir, node).name;
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        const decl = if (hir.kindOf(raw) == .export_decl) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (decl == hir_mod_ns.none_node_id) continue;
        const kind = hir.kindOf(decl);
        if (kind != .var_decl and kind != .let_decl and kind != .const_decl) continue;
        const variable = hir_mod_ns.varDeclOf(hir, decl);
        if (variable.name == hir_mod_ns.none_node_id or hir.kindOf(variable.name) != .identifier or
            hir_mod_ns.identifierOf(hir, variable.name).name != name) continue;
        if (variable.init != hir_mod_ns.none_node_id and hir.kindOf(variable.init) == .object_literal) return variable.init;
    }
    return null;
}

test "Program: generic local declarations retain schemas without becoming exports" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/classes.ts", "class Hidden<T> { value!: T; } export class Visible<T> { value!: T; } function nested() { class Inner<T> { value!: T; } }");
    try program.prepareNameStore();
    try program.prepareFiles(.{ .bind_only = true });
    const classes = try program.collectProgramExportedClasses();
    defer Program.freeProgramExportedClasses(T.allocator, classes);
    try T.expectEqual(@as(usize, 3), classes.len);
    for (classes) |class| {
        try T.expect(class.schema != null);
        try T.expectEqualStrings("/classes.ts", class.declaration_path);
        try T.expectEqual(!std.mem.eql(u8, class.class_name, "Visible"), class.local_only);
    }
}

test "Program: checking skips declaration schemas without file dependencies" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    const source = "export interface Box<T> { value: T } export declare function make<T>(value: T): Box<T>; const valid: string = make('ok').value; const invalid: boolean = make(1).value;";
    try vfs.addFile("/owner.ts", source);
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/owner.ts", source);
    try program.prepareNameStore();
    try program.prepareFiles(.{ .bind_only = true });
    try program.resolveImports();

    var checking_graph = try program.collectProgramDeclarationsForChecking();
    defer checking_graph.deinit();
    try T.expectEqual(@as(usize, 0), checking_graph.values.len);
    try T.expectEqual(@as(usize, 0), checking_graph.types.len);

    var complete_graph = try program.collectProgramDeclarations();
    defer complete_graph.deinit();
    try T.expectEqual(@as(usize, 1), complete_graph.values.len);
    try T.expectEqual(@as(usize, 1), complete_graph.types.len);

    try program.compileAll(.{ .no_emit = true, .strict = true });
    const compilation = program.fileById(0).compilation.?;
    try expectCompilationHasDiagnosticCode(compilation, 2322);
    try expectCompilationLacksDiagnosticCode(compilation, 2304);
}

test "Program: exported type and factory aliases share a source-owned declaration graph" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    const owner = "export interface Box<T> { readonly value: T; } export function make<T>(value: T): Box<T> { return { value }; } export const seed: Box<number> = make(1);";
    const barrel = "export { Box as AliasBox, make as build, seed as sample } from './owner';";
    try vfs.addFile("/owner.ts", owner);
    try vfs.addFile("/barrel.ts", barrel);
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/barrel.ts", barrel);
    _ = try program.add("/owner.ts", owner);
    try program.prepareNameStore();
    try program.prepareFiles(.{ .bind_only = true });
    var graph = try program.collectProgramDeclarations();
    defer graph.deinit();
    try T.expectEqual(@as(usize, 2), graph.types.len);
    try T.expectEqual(@as(usize, 4), graph.values.len);
    try T.expect(graph.types[0].declaration == graph.types[1].declaration);
    const box = graph.types[0].declaration;
    try T.expectEqualStrings("/owner.ts", box.path);
    var factory: ?*const ts_driver.ProgramClassSchema.Declaration = null;
    for (graph.values) |value| {
        const declaration = value.declaration.?;
        try T.expectEqualStrings("/owner.ts", declaration.path);
        if (!declaration.is_function) continue;
        if (factory) |previous| try T.expect(previous == declaration);
        factory = declaration;
        const signature = declaration.body.?.function;
        try T.expect(signature.result.reference.declaration == box);
        try T.expect(signature.parameters[0].type.parameter == &declaration.parameters[0]);
        try T.expect(signature.result.reference.arguments[0].parameter == &declaration.parameters[0]);
    }
    try T.expect(factory != null);
}

test "Program: namespace imports preserve inferred const literal keys" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();

    const owner = "export const KEY = '~tag';";
    const consumer =
        \\import * as ns from './owner.js';
        \\declare const fn: () => void;
        \\const tagged = fn as { [ns.KEY]?: boolean };
        \\const value: boolean | undefined = tagged[ns.KEY];
        \\const exact: '~tag' = ns.KEY;
        \\void value; void exact;
    ;
    const invalid =
        \\import * as ns from './owner.js';
        \\const wrong: 'other' = ns.KEY;
        \\void wrong;
    ;
    try vfs.addFile("/owner.ts", owner);
    try vfs.addFile("/consumer.ts", consumer);
    try vfs.addFile("/invalid.ts", invalid);
    _ = try program.add("/owner.ts", owner);
    const consumer_id = try program.add("/consumer.ts", consumer);
    const invalid_id = try program.add("/invalid.ts", invalid);
    try program.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = program.fileById(consumer_id).compilation.?;
    const invalid_compilation = program.fileById(invalid_id).compilation.?;
    var graph = try program.collectProgramDeclarations();
    defer graph.deinit();
    try T.expectEqual(@as(usize, 1), graph.values.len);
    try T.expectEqualStrings("KEY", graph.values[0].export_name);
    try T.expectEqualStrings("~tag", graph.values[0].declaration.?.body.?.string);
    try expectCompilationLacksDiagnosticCode(compilation, 2304);
    try expectCompilationLacksDiagnosticCode(compilation, 7053);
    try expectCompilationHasDiagnosticCode(invalid_compilation, 2322);
}

test "Program: literal exports survive unrelated parse diagnostics" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    const owner = "export const BROKEN = ; export const KEY = '~tag';";
    try vfs.addFile("/owner.ts", owner);
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/owner.ts", owner);
    try program.prepareNameStore();
    try program.prepareFiles(.{ .bind_only = true });
    var graph = try program.collectProgramDeclarations();
    defer graph.deinit();
    try T.expectEqual(@as(usize, 1), graph.values.len);
    try T.expectEqualStrings("KEY", graph.values[0].export_name);
    try T.expectEqualStrings("~tag", graph.values[0].declaration.?.body.?.string);
}

test "Program: unsupported graphs are retained only for explicit projections" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/owner.ts", "export interface Box { first: string } export interface Box { second: number } export declare function make(value: string): Box; export declare function make(value: number): Box;");
    try program.prepareNameStore();
    try program.prepareFiles(.{ .bind_only = true });
    var graph = try program.collectProgramDeclarations();
    defer graph.deinit();
    try T.expectEqual(@as(usize, 0), graph.values.len);
    try T.expectEqual(@as(usize, 1), graph.types.len);
    try T.expectEqualStrings("Box", graph.types[0].export_name);
    try T.expect(graph.types[0].projection_only);
}

test "Program: bound class facts separate static members and ignore source trivia" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    const source =
        \\// export class Phantom { private ghost: number; }
        \\export declare class Box<T> {
        \\  /* private phantom: string; */
        \\  private static key: string;
        \\  static count: number;
        \\  value: T;
        \\  'private': number;
        \\  static(): number;
        \\}
        \\export namespace Box { const hidden = 1; export const version: number = 1; }
        \\const text = 'export class Hidden { value: number; }';
    ;
    _ = try program.add("/classes.ts", source);
    try program.prepareNameStore();
    try program.prepareFiles(.{ .bind_only = true });
    const classes = try program.collectProgramExportedClasses();
    defer Program.freeProgramExportedClasses(T.allocator, classes);
    try T.expectEqual(@as(usize, 1), classes.len);
    const class = classes[0];
    try T.expectEqualStrings("Box", class.class_name);
    try T.expectEqualStrings("/classes.ts", class.declaration_path);
    try T.expect(class.declaration_pos != null);
    try T.expectEqual(@as(usize, 1), class.type_parameter_names.len);
    try T.expectEqualStrings("T", class.type_parameter_names[0]);
    try T.expectEqual(@as(usize, 3), class.members.len);
    try T.expectEqualStrings("value", class.members[0].name);
    try T.expectEqualStrings("T", class.members[0].type_name);
    try T.expectEqualStrings("private", class.members[1].name);
    try T.expectEqual(ts_driver.ProgramMemberVisibility.public, class.members[1].visibility);
    try T.expectEqualStrings("static", class.members[2].name);
    try T.expect(class.members[2].is_method);
    try T.expectEqual(@as(usize, 3), class.static_members.len);
    try T.expectEqualStrings("key", class.static_members[0].name);
    try T.expectEqual(ts_driver.ProgramMemberVisibility.private, class.static_members[0].visibility);
    try T.expectEqualStrings("count", class.static_members[1].name);
    try T.expectEqualStrings("version", class.static_members[2].name);
}

test "Program: class export aliases retain their bound declaration through cycles" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    const Fixture = struct { path: []const u8, source: []const u8 };
    for ([_]Fixture{
        .{ .path = "/owner.ts", .source = "class Secret { private key: string; } export { Secret, Secret as Alias };" },
        .{ .path = "/barrel.ts", .source = "export * from './owner'; export * from './cycle';" },
        .{ .path = "/cycle.ts", .source = "export * from './barrel';" },
        .{ .path = "/default.ts", .source = "export { Alias as default } from './owner';" },
    }) |fixture| {
        try vfs.addFile(fixture.path, fixture.source);
        _ = try program.add(fixture.path, fixture.source);
    }
    try program.prepareNameStore();
    try program.prepareFiles(.{ .bind_only = true });
    const classes = try program.collectProgramExportedClasses();
    defer Program.freeProgramExportedClasses(T.allocator, classes);
    try T.expectEqual(@as(usize, 7), classes.len);
    for (classes) |class| {
        try T.expectEqualStrings("/owner.ts", class.declaration_path);
        try T.expectEqual(classes[0].declaration_pos, class.declaration_pos);
        try T.expectEqualStrings("Secret", class.class_name);
        try T.expectEqual(@as(usize, 1), class.members.len);
        if (std.mem.eql(u8, class.target_path, "/default.ts")) {
            try T.expect(class.is_default);
            try T.expectEqualStrings("default", class.exportedName());
        } else {
            try T.expect(!class.is_default);
            try T.expect(std.mem.eql(u8, class.exportedName(), "Secret") or std.mem.eql(u8, class.exportedName(), "Alias"));
        }
    }
}

test "Program: ambient module export assignment target is collected" {
    const source =
        \\declare module "SubModule" {
        \\  class Other {}
        \\  class SubModule {}
        \\  export = SubModule;
        \\}
    ;
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/ambient.d.ts", source);
    try program.prepareNameStore();
    try program.prepareFiles(.{ .bind_only = true });
    const classes = try program.collectProgramExportedClasses();
    defer Program.freeProgramExportedClasses(T.allocator, classes);
    var assignments: usize = 0;
    try T.expectEqual(@as(usize, 1), classes.len);
    for (classes) |class| {
        if (!class.is_export_assignment_target) continue;
        assignments += 1;
        try T.expectEqualStrings("SubModule", class.class_name);
        try T.expectEqualStrings("SubModule", class.ambient_module_name);
        try T.expect(class.declaration_pos != null);
    }
    try T.expectEqual(@as(usize, 1), assignments);
    const facts = ambientModuleExportFacts(T.allocator, source, "SubModule", "", false) orelse return error.MissingTarget;
    try T.expect(facts.exported_type);
    try T.expect(facts.exported_value);
}

test "Program: ambient export assignment class supplies require alias type" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/ambient.d.ts",
        \\declare module "SubModule" {
        \\  class SubModule { value: number; }
        \\  export = SubModule;
        \\}
    );
    const main_id = try program.add("/main.ts",
        \\import SubModule = require("SubModule");
        \\class MainModule { member: SubModule; }
    );
    try program.compileAll(.{ .no_emit = true });
    try expectCompilationLacksDiagnosticCode(program.fileById(main_id).compilation.?, 2749);
}

fn moduleObjectPropertyName(
    hir: *const hir_mod_ns.Hir,
    key: hir_mod_ns.NodeId,
) ?hir_mod_ns.StringId {
    return switch (hir.kindOf(key)) {
        .identifier => hir_mod_ns.identifierOf(hir, key).name,
        .literal_string => hir_mod_ns.literalStringOf(hir, key).value,
        else => null,
    };
}

fn moduleRootHasCommonJsExportedRuntimeValue(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    root: hir_mod_ns.NodeId,
    name: hir_mod_ns.StringId,
) bool {
    if (hir.kindOf(root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(hir, root)) |stmt| {
        if (hir.kindOf(stmt) != .assignment) continue;
        const assignment = hir_mod_ns.assignmentOf(hir, stmt);
        if (assignment.op != null or assignment.value == hir_mod_ns.none_node_id) continue;
        if (commonJsExportAssignmentName(hir, interner, assignment.target) != name) continue;
        if (hir.kindOf(assignment.value) == .unary_op and
            hir_mod_ns.unaryOf(hir, assignment.value).op == .void_)
        {
            continue;
        }
        return true;
    }
    return false;
}

fn moduleRootHasEsmExportSyntax(hir: *const hir_mod_ns.Hir, root: hir_mod_ns.NodeId) bool {
    if (hir.kindOf(root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(hir, root)) |stmt| {
        if (hir.kindOf(stmt) != .export_decl) continue;
        if (!hir_mod_ns.exportOf(hir, stmt).is_export_equals) return true;
    }
    return false;
}

fn commonJsExportAssignmentName(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    target: hir_mod_ns.NodeId,
) ?hir_mod_ns.StringId {
    const property_name = commonJsPropertyAccessName(hir, target) orelse return null;
    const object = commonJsPropertyAccessObject(hir, target) orelse return null;
    if (hir.kindOf(object) == .identifier and
        std.mem.eql(u8, interner.get(hir_mod_ns.identifierOf(hir, object).name), "exports"))
    {
        return property_name;
    }
    const exports_name = commonJsPropertyAccessName(hir, object) orelse return null;
    if (!std.mem.eql(u8, interner.get(exports_name), "exports")) return null;
    const module_object = commonJsPropertyAccessObject(hir, object) orelse return null;
    if (hir.kindOf(module_object) != .identifier or
        !std.mem.eql(u8, interner.get(hir_mod_ns.identifierOf(hir, module_object).name), "module"))
    {
        return null;
    }
    return property_name;
}

fn commonJsExportAssignmentMetadataName(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    initial: hir_mod_ns.AssignmentPayload,
) ?[]const u8 {
    var assignment = initial;
    while (true) {
        if (commonJsExportAssignmentName(hir, interner, assignment.target)) |name| {
            return interner.get(name);
        }
        if (commonJsWholeExportAssignmentTarget(hir, interner, assignment.target)) return "";
        if (assignment.value == hir_mod_ns.none_node_id or hir.kindOf(assignment.value) != .assignment) return null;
        assignment = hir_mod_ns.assignmentOf(hir, assignment.value);
        if (assignment.op != null) return null;
    }
}

fn commonJsWholeExportAssignmentTarget(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    target: hir_mod_ns.NodeId,
) bool {
    const property_name = commonJsPropertyAccessName(hir, target) orelse return false;
    if (!std.mem.eql(u8, interner.get(property_name), "exports")) return false;
    const object = commonJsPropertyAccessObject(hir, target) orelse return false;
    return hir.kindOf(object) == .identifier and
        std.mem.eql(u8, interner.get(hir_mod_ns.identifierOf(hir, object).name), "module");
}

fn commonJsPropertyAccessName(hir: *const hir_mod_ns.Hir, node: hir_mod_ns.NodeId) ?hir_mod_ns.StringId {
    return switch (hir.kindOf(node)) {
        .member_access => hir_mod_ns.memberOf(hir, node).name,
        .element_access => blk: {
            const index = hir_mod_ns.elementOf(hir, node).index;
            if (hir.kindOf(index) != .literal_string) break :blk null;
            break :blk hir_mod_ns.literalStringOf(hir, index).value;
        },
        else => null,
    };
}

fn commonJsPropertyAccessObject(hir: *const hir_mod_ns.Hir, node: hir_mod_ns.NodeId) ?hir_mod_ns.NodeId {
    return switch (hir.kindOf(node)) {
        .member_access => hir_mod_ns.memberOf(hir, node).object,
        .element_access => hir_mod_ns.elementOf(hir, node).object,
        else => null,
    };
}

/// True when `module_source` exports `name` as an ambient const enum. This is
/// still a value-space export, but TypeScript rejects value imports/re-exports
/// of it under isolatedModules-like flags because the member values require
/// cross-file inlining.
pub fn moduleExportsAmbientConstEnumName(
    gpa: std.mem.Allocator,
    module_source: []const u8,
    module_path: []const u8,
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
    return moduleExportsAmbientConstEnumNameFromCompilation(compilation, module_path, name);
}

fn moduleExportsAmbientConstEnumNameFromCompilation(
    compilation: *const ts_driver.Compilation,
    module_path: []const u8,
    name: []const u8,
) bool {
    const id = compilation.interner.lookup(name) orelse return false;
    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return false;
    const is_declaration_file = declarationFilenameLike(module_path);
    for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |raw| {
        if (compilation.hir.kindOf(raw) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(&compilation.hir, raw);
        if (ex.decl != hir_mod_ns.none_node_id and
            ambientConstEnumDeclNamed(&compilation.hir, ex.decl, id, is_declaration_file))
        {
            return true;
        }
        for (hir_mod_ns.exportNamed(&compilation.hir, raw)) |spec_node| {
            if (compilation.hir.kindOf(spec_node) != .import_specifier) continue;
            const sp = hir_mod_ns.importSpecifierOf(&compilation.hir, spec_node);
            if (sp.local != id and sp.imported != id) continue;
            if (moduleRootLocalAmbientConstEnum(&compilation.hir, compilation.root, sp.imported, is_declaration_file)) return true;
        }
    }
    return false;
}

/// True when `module_source` declares `name` as an exported namespace whose
/// body contributes no runtime values. TypeScript treats these as type-only
/// declarations for verbatim-module named-import checks.
pub fn moduleExportsTypeOnlyNamespaceName(
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
    return moduleExportsTypeOnlyNamespaceNameFromCompilation(compilation, name);
}

fn moduleExportsTypeOnlyNamespaceNameFromCompilation(
    compilation: *const ts_driver.Compilation,
    name: []const u8,
) bool {
    const id = compilation.interner.lookup(name) orelse return false;
    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |stmt| {
        if (compilation.hir.kindOf(stmt) != .export_decl) continue;
        const decl = hir_mod_ns.exportOf(&compilation.hir, stmt).decl;
        if (decl == hir_mod_ns.none_node_id or
            (compilation.hir.kindOf(decl) != .namespace_decl and compilation.hir.kindOf(decl) != .module_decl)) continue;
        if (declarationName(&compilation.hir, decl) != id) continue;
        return !declCreatesRuntimeValue(&compilation.hir, decl);
    }
    return false;
}

pub const ModuleExportFacts = struct {
    exported_type: bool = false,
    exported_value: bool = false,
    exported_value_readonly: bool = false,
    ambient_const_enum: bool = false,
    type_only_pos: ?u32 = null,
    type_only_path: []const u8 = "",
    type_only_import: bool = false,
    export_assignment_type_only: bool = false,
    default_export_member_readonly: bool = false,
    generic_function: bool = false,
    call_only_function: bool = false,
    module_is_external: bool = false,
    cannot_be_named: bool = false,
};

pub const ModuleLocalImportFacts = struct {
    /// The queried name is bound in the prepared owner's module scope.
    declares_local: bool = false,
    /// Borrowed from the prepared owner's interner. Empty when the local is
    /// not re-exported under a different public name.
    exported_as: []const u8 = "",
};

/// Query the local provenance behind a missing named export without reopening
/// source or checking the owner. The binder's module scope covers value, type,
/// namespace, import, and destructured bindings; local export clauses provide
/// the exact public alias used by TS2460.
pub fn moduleLocalImportFactsFromCompilation(
    compilation: *const ts_driver.Compilation,
    name: []const u8,
) ModuleLocalImportFacts {
    const name_id = compilation.interner.lookup(name) orelse return .{};
    if (compilation.module.root.lookupLocal(name_id) == null) return .{};
    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return .{ .declares_local = true };
    for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |stmt| {
        if (compilation.hir.kindOf(stmt) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(&compilation.hir, stmt);
        if (compilation.interner.get(ex.module).len != 0) continue;
        for (hir_mod_ns.exportNamed(&compilation.hir, stmt)) |spec_node| {
            if (compilation.hir.kindOf(spec_node) != .import_specifier) continue;
            const export_spec = hir_mod_ns.importSpecifierOf(&compilation.hir, spec_node);
            if (export_spec.imported != name_id or export_spec.local == name_id) continue;
            return .{
                .declares_local = true,
                .exported_as = compilation.interner.get(export_spec.local),
            };
        }
    }
    return .{ .declares_local = true };
}

/// Source-only compatibility entry point. Prepare bindings, but never check
/// the module merely to answer an export-shape query. The caller owns the name.
pub fn moduleCommonJsExportAssignmentClassName(
    gpa: std.mem.Allocator,
    source: []const u8,
    is_tsx: bool,
) ?[]u8 {
    var compilation = ts_driver.compileSource(gpa, source, .{
        .is_tsx = is_tsx,
        .continue_on_error = true,
        .no_emit = true,
        .bind_only = true,
    }) catch return null;
    defer {
        compilation.deinit();
        gpa.destroy(compilation);
    }
    const name = moduleCommonJsExportAssignmentClassNameFromCompilation(compilation) orelse return null;
    return gpa.dupe(u8, name) catch null;
}

/// Borrow the bound class name of a single CommonJS instance export. This is
/// display metadata, not the module's type: multiple assignments need the real
/// union type, and must not be misrepresented by the first constructor's name.
/// Only prepared HIR and lexical bindings are inspected; no allocation,
/// reparsing, checking, or source-text recovery is performed.
pub fn moduleCommonJsExportAssignmentClassNameFromCompilation(
    compilation: *const ts_driver.Compilation,
) ?[]const u8 {
    _ = compilation.interner.lookup("module") orelse return null;
    _ = compilation.interner.lookup("exports") orelse return null;
    const hir = &compilation.hir;
    var result: ?[]const u8 = null;
    var node: hir_mod_ns.NodeId = 1;
    while (node < hir.nodeCount()) : (node += 1) {
        if (hir.kindOf(node) != .assignment) continue;
        const assignment = hir_mod_ns.assignmentOf(hir, node);
        if (!commonJsModuleExportsAccess(hir, &compilation.interner, assignment.target)) continue;
        const object = commonJsPropertyAccessObject(hir, assignment.target) orelse continue;
        // A local `module` value is not the CommonJS wrapper binding.
        if (moduleQueryBoundValue(compilation, object) != null) continue;
        if (result != null or assignment.op != null or hir.kindOf(assignment.value) != .new_expr) return null;
        var callee = hir_mod_ns.callOf(hir, assignment.value).callee;
        // Const aliases form a finite graph of source-owned symbols. A walk
        // longer than that graph is a cycle, not a depth-based approximation.
        var remaining = compilation.module.symbols.items.len;
        while (remaining > 0) : (remaining -= 1) {
            const symbol = moduleQueryBoundValue(compilation, callee) orelse return null;
            if (symbol.flags.is_class) {
                result = compilation.interner.get(symbol.name);
                break;
            }
            if (!symbol.flags.is_const or symbol.decls.items.len != 1) return null;
            const declaration = symbol.decls.items[0];
            if (hir.kindOf(declaration) != .const_decl) return null;
            callee = hir_mod_ns.varDeclOf(hir, declaration).init;
        }
        if (result == null) return null;
    }
    return result;
}

fn moduleQueryBoundValue(compilation: *const ts_driver.Compilation, node: hir_mod_ns.NodeId) ?*const binder.Symbol {
    const hir = &compilation.hir;
    if (hir.kindOf(node) != .identifier) return null;
    const name = hir_mod_ns.identifierOf(hir, node).name;
    var ancestor = node;
    while (ancestor != hir_mod_ns.none_node_id) : (ancestor = hir.parentOf(ancestor)) {
        for (compilation.module.scopes.items) |scope| {
            if (scope.introducing_node != ancestor) continue;
            var current: ?*const binder.Scope = scope;
            while (current) |lexical| : (current = lexical.parent) {
                if (lexical.values.get(name)) |symbol| return symbol;
            }
            return null;
        }
    }
    return compilation.module.root.values.get(name);
}

const ModuleExportAssignmentInfo = struct {
    private_type_name: ?[]u8 = null,
    target_is_any: bool = false,
};

fn moduleExportAssignmentInfo(
    gpa: std.mem.Allocator,
    source: []const u8,
    is_tsx: bool,
) ?ModuleExportAssignmentInfo {
    var compilation = ts_driver.compileSource(gpa, source, .{
        .is_tsx = is_tsx,
        .continue_on_error = true,
        .no_emit = true,
        .is_declaration_file = true,
    }) catch return null;
    defer {
        compilation.deinit();
        gpa.destroy(compilation);
    }
    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return null;
    const stmts = hir_mod_ns.blockStmts(&compilation.hir, compilation.root);

    var export_target: hir_mod_ns.StringId = 0;
    for (stmts) |stmt| {
        if (compilation.hir.kindOf(stmt) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(&compilation.hir, stmt);
        if (!ex.is_export_equals or ex.decl == hir_mod_ns.none_node_id or
            compilation.hir.kindOf(ex.decl) != .identifier) continue;
        export_target = hir_mod_ns.identifierOf(&compilation.hir, ex.decl).name;
        break;
    }
    if (export_target == 0) return null;

    var annotation: hir_mod_ns.NodeId = hir_mod_ns.none_node_id;
    for (stmts) |raw| {
        const stmt = if (compilation.hir.kindOf(raw) == .export_decl)
            hir_mod_ns.exportOf(&compilation.hir, raw).decl
        else
            raw;
        if (stmt == hir_mod_ns.none_node_id or declarationName(&compilation.hir, stmt) != export_target) continue;
        switch (compilation.hir.kindOf(stmt)) {
            .var_decl, .let_decl, .const_decl => annotation = hir_mod_ns.varDeclOf(&compilation.hir, stmt).type_annotation,
            else => {},
        }
        break;
    }
    var info: ModuleExportAssignmentInfo = .{};
    if (annotation == hir_mod_ns.none_node_id) return info;

    const annotation_span = compilation.hir.spanOf(annotation);
    if (annotation_span.end <= source.len and annotation_span.start <= annotation_span.end) {
        const annotation_text = std.mem.trim(
            u8,
            source[annotation_span.start..annotation_span.end],
            " \t\r\n",
        );
        info.target_is_any = std.mem.eql(u8, annotation_text, "any");
    }

    var node: hir_mod_ns.NodeId = 1;
    while (node < compilation.hir.nodeCount()) : (node += 1) {
        if (compilation.hir.kindOf(node) != .type_ref or
            !hirNodeDescendsFrom(&compilation.hir, node, annotation)) continue;
        const ref = hir_mod_ns.typeRefOf(&compilation.hir, node);
        if (ref.qualifier_len != 0 or ref.name == 0) continue;
        if (!moduleRootTypeNameIsPrivate(&compilation.hir, stmts, ref.name)) continue;
        info.private_type_name = gpa.dupe(u8, compilation.interner.get(ref.name)) catch return null;
        break;
    }
    return info;
}

/// Return the first private top-level type referenced by a module's
/// `export =` value annotation. The returned name is owned by `gpa`.
pub fn moduleExportAssignmentPrivateTypeName(
    gpa: std.mem.Allocator,
    source: []const u8,
    is_tsx: bool,
) ?[]u8 {
    const info = moduleExportAssignmentInfo(gpa, source, is_tsx) orelse return null;
    return info.private_type_name;
}

fn hirNodeDescendsFrom(
    hir: *const hir_mod_ns.Hir,
    node: hir_mod_ns.NodeId,
    ancestor: hir_mod_ns.NodeId,
) bool {
    var current = node;
    var remaining = hir.nodeCount();
    while (current != hir_mod_ns.none_node_id and remaining > 0) : (remaining -= 1) {
        if (current == ancestor) return true;
        current = hir.parentOf(current);
    }
    return false;
}

fn moduleRootTypeNameIsPrivate(
    hir: *const hir_mod_ns.Hir,
    stmts: []const hir_mod_ns.NodeId,
    name: hir_mod_ns.StringId,
) bool {
    var found_private = false;
    for (stmts) |raw| {
        const exported = hir.kindOf(raw) == .export_decl;
        const stmt = if (exported) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (stmt == hir_mod_ns.none_node_id or !declCreatesTypeSpaceName(hir, stmt)) continue;
        if (declarationName(hir, stmt) != name) continue;
        if (exported) return false;
        found_private = true;
    }
    return found_private;
}

/// Resolve direct and export-star-projected facts for `name` from an already
/// resolved module. Explicit relative subpaths are followed recursively;
/// directory/index back-references are not, because a `typesVersions` package
/// entry such as `export * from "../"` resolves back through the package map
/// and does not expose the original entry point.
pub fn moduleExportFactsFromResolvedModule(
    gpa: std.mem.Allocator,
    resolver: *ts_resolver.Resolver,
    module_path: []const u8,
    name: []const u8,
) ModuleExportFacts {
    return moduleExportFactsFromResolvedModuleDepth(gpa, resolver, module_path, name, 0) catch .{};
}

/// Build the reusable module compilation consumed by export-fact queries.
/// The caller owns the returned compilation and must deinitialize and destroy
/// it with the same allocator.
pub fn compileModuleForExportFacts(
    gpa: std.mem.Allocator,
    module_path: []const u8,
    source: []const u8,
) !*ts_driver.Compilation {
    const is_tsx = std.mem.endsWith(u8, module_path, ".tsx") or
        std.mem.endsWith(u8, module_path, ".jsx") or
        (std.mem.endsWith(u8, module_path, ".js") and Program.sourceHasJsxSyntax(source));
    return ts_driver.compileSource(gpa, source, .{
        .is_tsx = is_tsx,
        .continue_on_error = true,
        .no_emit = true,
        .bind_only = true,
    });
}

/// Return the non-default names projected by a resolved module, including
/// names reached through `export *` declarations. The caller owns the outer
/// slice and every name in it.
pub fn moduleExportNamesFromResolvedModule(
    gpa: std.mem.Allocator,
    resolver: *ts_resolver.Resolver,
    module_path: []const u8,
) ![]const []const u8 {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    errdefer {
        var it = names.keyIterator();
        while (it.next()) |name| gpa.free(name.*);
        names.deinit(gpa);
    }
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = visited.keyIterator();
        while (it.next()) |path| gpa.free(path.*);
        visited.deinit(gpa);
    }
    var pending: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pending.deinit(gpa);
    try pending.append(gpa, module_path);
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        try collectModuleExportNames(gpa, resolver, pending.items[cursor], &names, &visited, &pending);
    }

    const result = try gpa.alloc([]const u8, names.count());
    var index: usize = 0;
    var it = names.keyIterator();
    while (it.next()) |name| {
        result[index] = name.*;
        index += 1;
    }
    names.deinit(gpa);
    return result;
}

fn collectModuleExportNames(
    gpa: std.mem.Allocator,
    resolver: *ts_resolver.Resolver,
    module_path: []const u8,
    names: *std.StringHashMapUnmanaged(void),
    visited: *std.StringHashMapUnmanaged(void),
    pending: *std.ArrayListUnmanaged([]const u8),
) !void {
    if (visited.contains(module_path)) return;
    const stored_path = try gpa.dupe(u8, module_path);
    visited.put(gpa, stored_path, {}) catch |err| {
        gpa.free(stored_path);
        return err;
    };

    const source = try resolver.fs.readFile(gpa, module_path);
    defer gpa.free(source);
    var compilation = try compileModuleForExportFacts(gpa, module_path, source);
    defer {
        compilation.deinit();
        gpa.destroy(compilation);
    }

    var type_it = compilation.module.root.types.iterator();
    while (type_it.next()) |entry| {
        if (!entry.value_ptr.*.flags.is_export) continue;
        try putOwnedExportName(gpa, names, compilation.interner.get(entry.key_ptr.*));
    }
    var value_it = compilation.module.root.values.iterator();
    while (value_it.next()) |entry| {
        if (!entry.value_ptr.*.flags.is_export) continue;
        try putOwnedExportName(gpa, names, compilation.interner.get(entry.key_ptr.*));
    }
    var namespace_it = compilation.module.root.namespaces.iterator();
    while (namespace_it.next()) |entry| {
        if (!entry.value_ptr.*.flags.is_export) continue;
        try putOwnedExportName(gpa, names, compilation.interner.get(entry.key_ptr.*));
    }

    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return;
    for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |stmt| {
        if (compilation.hir.kindOf(stmt) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(&compilation.hir, stmt);
        for (hir_mod_ns.exportNamed(&compilation.hir, stmt)) |spec_node| {
            if (compilation.hir.kindOf(spec_node) != .import_specifier) continue;
            const spec = hir_mod_ns.importSpecifierOf(&compilation.hir, spec_node);
            try putOwnedExportName(gpa, names, compilation.interner.get(spec.local));
        }
        if (compilation.interner.get(ex.namespace_alias).len != 0) {
            try putOwnedExportName(gpa, names, compilation.interner.get(ex.namespace_alias));
        }
        if (!ex.is_namespace or compilation.interner.get(ex.namespace_alias).len != 0) continue;
        const specifier = compilation.interner.get(ex.module);
        if (specifier.len == 0) continue;
        const target = resolver.resolve(specifier, module_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (std.mem.eql(u8, target.path, module_path)) continue;
        try pending.append(gpa, target.path);
    }
}

fn putOwnedExportName(
    gpa: std.mem.Allocator,
    names: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) !void {
    if (name.len == 0 or std.mem.eql(u8, name, "default") or names.contains(name)) return;
    const stored_name = try gpa.dupe(u8, name);
    names.put(gpa, stored_name, {}) catch |err| {
        gpa.free(stored_name);
        return err;
    };
}

fn moduleExportFactsFromResolvedModuleDepth(
    gpa: std.mem.Allocator,
    resolver: *ts_resolver.Resolver,
    module_path: []const u8,
    name: []const u8,
    depth: u8,
) !ModuleExportFacts {
    if (depth >= 8) return .{};
    const src = try resolver.fs.readFile(gpa, module_path);
    defer gpa.free(src);
    var compilation = try compileModuleForExportFacts(gpa, module_path, src);
    defer {
        compilation.deinit();
        gpa.destroy(compilation);
    }
    return moduleExportFactsFromCompilationDepth(gpa, resolver, module_path, compilation, name, depth);
}

/// Query export facts from a module compilation that the caller already owns.
/// Re-export targets still resolve recursively through the normal resolver.
pub fn moduleExportFactsFromCompilation(
    gpa: std.mem.Allocator,
    resolver: *ts_resolver.Resolver,
    module_path: []const u8,
    compilation: *ts_driver.Compilation,
    name: []const u8,
) ModuleExportFacts {
    return moduleExportFactsFromCompilationDepth(gpa, resolver, module_path, compilation, name, 0) catch .{};
}

fn moduleExportFactsFromCompilationDepth(
    gpa: std.mem.Allocator,
    resolver: *ts_resolver.Resolver,
    module_path: []const u8,
    compilation: *ts_driver.Compilation,
    name: []const u8,
    depth: u8,
) !ModuleExportFacts {
    var facts: ModuleExportFacts = .{
        .exported_type = moduleExportsTypeSpaceNameFromCompilation(compilation, name) or
            moduleExportsTypeOnlyNamespaceNameFromCompilation(compilation, name),
        .exported_value = moduleExportsValueSpaceNameFromCompilation(compilation, name),
        .ambient_const_enum = moduleExportsAmbientConstEnumNameFromCompilation(compilation, module_path, name),
        .type_only_pos = moduleExportIsTypeOnlyFromCompilation(compilation, name),
    };
    facts.cannot_be_named = !facts.exported_type and
        moduleExportNestedTypeSpaceNameFromCompilation(compilation, name);
    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return facts;
    facts.module_is_external = moduleRootIsExternalOrCommonJsModule(
        &compilation.hir,
        &compilation.interner,
        compilation.root,
    );
    facts.call_only_function = moduleRootExportsCallOnlyFunction(
        &compilation.hir,
        &compilation.interner,
        compilation.root,
        name,
    );
    if (std.mem.eql(u8, name, "default") and
        moduleRootHasDefaultValueExport(&compilation.hir, compilation.root))
    {
        facts.exported_value = true;
    }
    if (name.len != 0 and moduleRootExportAssignmentHasValueMember(
        &compilation.hir,
        &compilation.interner,
        compilation.root,
        name,
    )) {
        facts.exported_value = true;
    }
    if (compilation.interner.lookup(name)) |name_id| {
        facts.exported_value_readonly = moduleRootCommonJsDefinePropertyReadonlyStatus(
            &compilation.hir,
            &compilation.interner,
            compilation.root,
            name_id,
        ) orelse false;
    }
    if (name.len == 0) {
        for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |stmt| {
            if (compilation.hir.kindOf(stmt) != .export_decl) continue;
            const ex = hir_mod_ns.exportOf(&compilation.hir, stmt);
            if (!ex.is_export_equals or ex.decl == hir_mod_ns.none_node_id) continue;
            if (compilation.hir.kindOf(ex.decl) != .identifier) {
                facts.exported_value = true;
                return facts;
            }
            const target = hir_mod_ns.identifierOf(&compilation.hir, ex.decl).name;
            const type_symbol = compilation.module.root.types.get(target);
            const value_symbol = compilation.module.root.values.get(target);
            facts.exported_type = type_symbol != null;
            facts.exported_value = value_symbol != null and !value_symbol.?.flags.is_type;
            facts.export_assignment_type_only = facts.exported_type and !facts.exported_value;
            return facts;
        }
        return facts;
    }
    facts.default_export_member_readonly = moduleDefaultExportMemberIsReadonly(
        &compilation.hir,
        &compilation.interner,
        compilation.root,
        name,
    );
    const queried_name = compilation.interner.lookup(name);
    for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |stmt| {
        if (compilation.hir.kindOf(stmt) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(&compilation.hir, stmt);
        const specifier = compilation.interner.get(ex.module);
        if (queried_name) |name_id| {
            if (ex.decl != hir_mod_ns.none_node_id and compilation.hir.kindOf(ex.decl) == .fn_decl and
                declarationName(&compilation.hir, ex.decl) == name_id and
                hir_mod_ns.fnTypeParams(&compilation.hir, ex.decl).len > 0)
            {
                facts.generic_function = true;
            }
            if (ex.is_namespace and
                compilation.interner.get(ex.namespace_alias).len != 0 and
                ex.namespace_alias == name_id)
            {
                facts.exported_type = true;
                if (ex.is_type_only) {
                    if (facts.type_only_pos == null) facts.type_only_pos = compilation.hir.spanOf(stmt).start;
                } else {
                    facts.exported_value = true;
                }
            }
        }
        if (ex.decl == hir_mod_ns.none_node_id and ex.named_len > 0) {
            const name_id = compilation.interner.lookup(name) orelse continue;
            for (hir_mod_ns.exportNamed(&compilation.hir, stmt)) |spec_node| {
                if (compilation.hir.kindOf(spec_node) != .import_specifier) continue;
                const export_spec = hir_mod_ns.importSpecifierOf(&compilation.hir, spec_node);
                if (export_spec.local != name_id) continue;
                if (specifier.len == 0) {
                    if (compilation.module.root.lookupLocal(export_spec.imported)) |local| {
                        if (local.flags.is_import) {
                            var query = export_origins.Query.init(gpa, resolver);
                            defer query.deinit();
                            try query.borrow(module_path, compilation);
                            const origins = try query.resolve(module_path, name);
                            if (origins.complete and !origins.ambiguous) {
                                facts.exported_type = facts.exported_type or origins.type != null or origins.namespace != null;
                                facts.exported_value = facts.exported_value or origins.value != null or origins.type_only_value != null;
                                if (origins.value orelse origins.type_only_value) |origin| {
                                    facts.generic_function = facts.generic_function or origin.generic_function;
                                    facts.call_only_function = facts.call_only_function or origin.call_only_function;
                                }
                                if (origins.value == null) {
                                    if (origins.restriction) |restriction| {
                                        facts.type_only_pos = restriction.position;
                                        facts.type_only_path = restriction.path;
                                        facts.type_only_import = restriction.kind == .import_type;
                                    }
                                }
                            }
                        }
                    }
                    if (moduleRootDeclaresValueBinding(
                        &compilation.hir,
                        compilation.root,
                        export_spec.imported,
                    )) facts.exported_value = true;
                    if (moduleRootDeclaresGenericFunction(
                        &compilation.hir,
                        compilation.root,
                        export_spec.imported,
                    )) facts.generic_function = true;
                    continue;
                }
                const target = resolver.resolve(specifier, module_path) catch continue;
                if (std.mem.eql(u8, target.path, module_path)) continue;
                const imported_name = compilation.interner.get(export_spec.imported);
                const nested = try moduleExportFactsFromResolvedModuleDepth(gpa, resolver, target.path, imported_name, depth + 1);
                if (ex.is_type_only or export_spec.is_type_only) {
                    if (nested.exported_type) {
                        facts.exported_type = true;
                        if (facts.type_only_pos == null) facts.type_only_pos = compilation.hir.spanOf(spec_node).start;
                    }
                } else {
                    facts.exported_type = facts.exported_type or nested.exported_type;
                    facts.exported_value = facts.exported_value or nested.exported_value;
                    facts.ambient_const_enum = facts.ambient_const_enum or nested.ambient_const_enum;
                    facts.exported_value_readonly = facts.exported_value_readonly or nested.exported_value_readonly;
                    facts.generic_function = facts.generic_function or nested.generic_function;
                    facts.call_only_function = facts.call_only_function or nested.call_only_function;
                    if (facts.type_only_pos == null and nested.type_only_pos != null) {
                        facts.type_only_pos = nested.type_only_pos;
                        facts.type_only_path = if (nested.type_only_path.len != 0) nested.type_only_path else target.path;
                        facts.type_only_import = nested.type_only_import;
                    }
                }
            }
        }
        if (!ex.is_namespace or compilation.interner.get(ex.namespace_alias).len != 0) continue;
        if (!std.mem.startsWith(u8, specifier, ".") or exportStarTargetPrefersIndex(specifier)) continue;
        const target = resolver.resolve(specifier, module_path) catch continue;
        if (std.mem.eql(u8, target.path, module_path)) continue;
        const nested = try moduleExportFactsFromResolvedModuleDepth(gpa, resolver, target.path, name, depth + 1);
        if (ex.is_type_only) {
            if (nested.exported_type) {
                facts.exported_type = true;
                if (facts.type_only_pos == null) facts.type_only_pos = compilation.hir.spanOf(stmt).start;
            }
            continue;
        }
        facts.exported_type = facts.exported_type or nested.exported_type;
        facts.exported_value = facts.exported_value or nested.exported_value;
        facts.ambient_const_enum = facts.ambient_const_enum or nested.ambient_const_enum;
        facts.exported_value_readonly = facts.exported_value_readonly or nested.exported_value_readonly;
        facts.generic_function = facts.generic_function or nested.generic_function;
        facts.call_only_function = facts.call_only_function or nested.call_only_function;
        if (facts.type_only_pos == null and nested.type_only_pos != null) {
            facts.type_only_pos = nested.type_only_pos;
            facts.type_only_path = if (nested.type_only_path.len != 0) nested.type_only_path else target.path;
            facts.type_only_import = nested.type_only_import;
        }
    }
    return facts;
}

fn moduleRootExportsCallOnlyFunction(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    root: hir_mod_ns.NodeId,
    name: []const u8,
) bool {
    if (name.len == 0) {
        for (hir_mod_ns.blockStmts(hir, root)) |raw| {
            if (hir.kindOf(raw) != .export_decl) continue;
            const export_decl = hir_mod_ns.exportOf(hir, raw);
            if (!export_decl.is_export_equals or export_decl.decl == hir_mod_ns.none_node_id) continue;
            if (moduleRootValueIsFunction(hir, root, export_decl.decl)) return true;
        }
        return false;
    }
    const name_id = interner.lookup(name) orelse return false;
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        if (hir.kindOf(raw) == .assignment) {
            const assignment = hir_mod_ns.assignmentOf(hir, raw);
            const export_name = commonJsExportAssignmentName(hir, interner, assignment.target) orelse continue;
            if (export_name != name_id or assignment.value == hir_mod_ns.none_node_id) continue;
            if (moduleRootValueIsFunction(hir, root, assignment.value)) return true;
            continue;
        }
        if (hir.kindOf(raw) != .export_decl) continue;
        const export_decl = hir_mod_ns.exportOf(hir, raw);
        if (export_decl.decl != hir_mod_ns.none_node_id and
            declarationName(hir, export_decl.decl) == name_id and
            hir.kindOf(export_decl.decl) == .fn_decl)
        {
            return true;
        }
        if (interner.get(export_decl.module).len != 0) continue;
        for (hir_mod_ns.exportNamed(hir, raw)) |specifier| {
            if (hir.kindOf(specifier) != .import_specifier) continue;
            const exported = hir_mod_ns.importSpecifierOf(hir, specifier);
            if (exported.local != name_id) continue;
            if (moduleRootNamedValueIsFunction(hir, root, exported.imported)) return true;
        }
    }
    return false;
}

fn moduleRootHasDefaultValueExport(hir: *const hir_mod_ns.Hir, root: hir_mod_ns.NodeId) bool {
    if (hir.kindOf(root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        if (hir.kindOf(raw) != .export_decl) continue;
        const export_decl = hir_mod_ns.exportOf(hir, raw);
        if (!export_decl.is_default or export_decl.decl == hir_mod_ns.none_node_id) continue;
        return switch (hir.kindOf(export_decl.decl)) {
            .interface_decl, .type_alias_decl => false,
            else => true,
        };
    }
    return false;
}

fn moduleRootExportAssignmentHasValueMember(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    root: hir_mod_ns.NodeId,
    name: []const u8,
) bool {
    if (hir.kindOf(root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        if (hir.kindOf(raw) != .export_decl) continue;
        const export_decl = hir_mod_ns.exportOf(hir, raw);
        if (!export_decl.is_export_equals or export_decl.decl == hir_mod_ns.none_node_id) continue;
        if (moduleRootValueHasMember(hir, interner, root, export_decl.decl, name)) return true;
    }
    return false;
}

fn moduleRootValueHasMember(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    root: hir_mod_ns.NodeId,
    value: hir_mod_ns.NodeId,
    name: []const u8,
) bool {
    if (hir.kindOf(value) == .object_literal) {
        for (hir_mod_ns.objectLiteralProps(hir, value)) |prop| {
            if (hir.kindOf(prop) != .object_property) continue;
            const key = hir_mod_ns.objectPropertyOf(hir, prop).key;
            const key_name = moduleObjectPropertyName(hir, key) orelse continue;
            if (std.mem.eql(u8, interner.get(key_name), name)) return true;
        }
        return false;
    }
    if (hir.kindOf(value) != .identifier) return false;
    const value_name = hir_mod_ns.identifierOf(hir, value).name;
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        const decl = if (hir.kindOf(raw) == .export_decl) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (decl == hir_mod_ns.none_node_id) continue;
        const kind = hir.kindOf(decl);
        if ((kind == .namespace_decl or kind == .module_decl) and declarationName(hir, decl) == value_name) {
            for (hir_mod_ns.namespaceBody(hir, decl)) |member_raw| {
                if (hir.kindOf(member_raw) != .export_decl) continue;
                const exported = hir_mod_ns.exportOf(hir, member_raw);
                const member = exported.decl;
                if (member != hir_mod_ns.none_node_id and
                    std.mem.eql(u8, interner.get(declarationName(hir, member)), name) and
                    declCreatesRuntimeValue(hir, member))
                {
                    return true;
                }
                for (hir_mod_ns.exportNamed(hir, member_raw)) |specifier| {
                    if (hir.kindOf(specifier) != .import_specifier) continue;
                    const named = hir_mod_ns.importSpecifierOf(hir, specifier);
                    if (!std.mem.eql(u8, interner.get(named.local), name)) continue;
                    for (hir_mod_ns.namespaceBody(hir, decl)) |candidate_raw| {
                        const candidate = if (hir.kindOf(candidate_raw) == .export_decl)
                            hir_mod_ns.exportOf(hir, candidate_raw).decl
                        else
                            candidate_raw;
                        if (candidate != hir_mod_ns.none_node_id and
                            declarationName(hir, candidate) == named.imported and
                            declCreatesRuntimeValue(hir, candidate))
                        {
                            return true;
                        }
                    }
                }
            }
            continue;
        }
        if (kind != .var_decl and kind != .let_decl and kind != .const_decl) continue;
        const variable = hir_mod_ns.varDeclOf(hir, decl);
        if (variable.name == hir_mod_ns.none_node_id or hir.kindOf(variable.name) != .identifier or
            hir_mod_ns.identifierOf(hir, variable.name).name != value_name) continue;
        return moduleRootValueHasMember(hir, interner, root, variable.init, name);
    }
    return false;
}

fn moduleRootValueIsFunction(
    hir: *const hir_mod_ns.Hir,
    root: hir_mod_ns.NodeId,
    value: hir_mod_ns.NodeId,
) bool {
    const kind = hir.kindOf(value);
    if (kind == .fn_decl or kind == .fn_expr or kind == .arrow_fn) return true;
    if (kind != .identifier) return false;
    return moduleRootNamedValueIsFunction(hir, root, hir_mod_ns.identifierOf(hir, value).name);
}

fn moduleRootNamedValueIsFunction(
    hir: *const hir_mod_ns.Hir,
    root: hir_mod_ns.NodeId,
    name: hir_mod_ns.StringId,
) bool {
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        const decl = if (hir.kindOf(raw) == .export_decl) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (decl == hir_mod_ns.none_node_id or declarationName(hir, decl) != name) continue;
        if (hir.kindOf(decl) == .fn_decl) return true;
        const kind = hir.kindOf(decl);
        if (kind != .var_decl and kind != .let_decl and kind != .const_decl) continue;
        const init = hir_mod_ns.varDeclOf(hir, decl).init;
        if (init == hir_mod_ns.none_node_id) continue;
        const init_kind = hir.kindOf(init);
        if (init_kind == .fn_decl or init_kind == .fn_expr or init_kind == .arrow_fn) return true;
    }
    return false;
}

fn moduleRootDeclaresGenericFunction(
    hir: *const hir_mod_ns.Hir,
    root: hir_mod_ns.NodeId,
    name: hir_mod_ns.StringId,
) bool {
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        const decl = if (hir.kindOf(raw) == .export_decl) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (decl == hir_mod_ns.none_node_id or hir.kindOf(decl) != .fn_decl) continue;
        if (declarationName(hir, decl) != name) continue;
        return hir_mod_ns.fnTypeParams(hir, decl).len > 0;
    }
    return false;
}

fn moduleRootDeclaresValueBinding(
    hir: *const hir_mod_ns.Hir,
    root: hir_mod_ns.NodeId,
    name: hir_mod_ns.StringId,
) bool {
    if (hir.kindOf(root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        const stmt = if (hir.kindOf(raw) == .export_decl) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (stmt == hir_mod_ns.none_node_id) continue;
        switch (hir.kindOf(stmt)) {
            .var_decl, .let_decl, .const_decl => {
                if (bindingDeclaresName(hir, hir_mod_ns.varDeclOf(hir, stmt).name, name)) return true;
            },
            .fn_decl, .class_decl, .enum_decl => {
                if (declarationName(hir, stmt) == name) return true;
            },
            else => {},
        }
    }
    return false;
}

fn bindingDeclaresName(
    hir: *const hir_mod_ns.Hir,
    binding: hir_mod_ns.NodeId,
    name: hir_mod_ns.StringId,
) bool {
    if (binding == hir_mod_ns.none_node_id) return false;
    return switch (hir.kindOf(binding)) {
        .identifier => hir_mod_ns.identifierOf(hir, binding).name == name,
        .object_pattern, .array_pattern => blk: {
            for (hir_mod_ns.patternElements(hir, binding)) |element| {
                if (hir.kindOf(element) != .parameter) continue;
                const parameter = hir_mod_ns.parameterOf(hir, element);
                if (bindingDeclaresName(hir, parameter.name, name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn moduleRootIsExternalOrCommonJsModule(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    root: hir_mod_ns.NodeId,
) bool {
    if (hir.kindOf(root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(hir, root)) |stmt| {
        if (moduleCommonJsDefinePropertyExport(hir, interner, root, stmt) != null) return true;
        switch (hir.kindOf(stmt)) {
            .import_decl, .export_decl => return true,
            .assignment => {
                const assignment = hir_mod_ns.assignmentOf(hir, stmt);
                if (assignment.op != null) continue;
                if (commonJsExportAssignmentName(hir, interner, assignment.target) != null or
                    commonJsModuleExportsAccess(hir, interner, assignment.target)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn commonJsModuleExportsAccess(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    node: hir_mod_ns.NodeId,
) bool {
    const name = commonJsPropertyAccessName(hir, node) orelse return false;
    if (!std.mem.eql(u8, interner.get(name), "exports")) return false;
    const object = commonJsPropertyAccessObject(hir, node) orelse return false;
    return hir.kindOf(object) == .identifier and
        std.mem.eql(u8, interner.get(hir_mod_ns.identifierOf(hir, object).name), "module");
}

fn moduleDefaultExportMemberIsReadonly(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    root: hir_mod_ns.NodeId,
    member_name: []const u8,
) bool {
    for (hir_mod_ns.blockStmts(hir, root)) |stmt| {
        if (hir.kindOf(stmt) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(hir, stmt);
        if (!ex.is_default or ex.decl == hir_mod_ns.none_node_id) continue;
        const expression = ex.decl;
        const kind = hir.kindOf(expression);
        if (kind != .as_expr and kind != .type_assertion) continue;
        const assertion = hir_mod_ns.asExpressionOf(hir, expression);
        if (assertion.type_node == hir_mod_ns.none_node_id or hir.kindOf(assertion.type_node) != .type_ref) continue;
        const ref = hir_mod_ns.typeRefOf(hir, assertion.type_node);
        if (!std.mem.eql(u8, interner.get(ref.name), "Readonly")) continue;
        const args = hir_mod_ns.typeRefArgs(hir, assertion.type_node);
        if (args.len != 1) continue;
        if (moduleReadonlyProjectionContainsMember(hir, interner, root, assertion.expr, args[0], member_name)) return true;
    }
    return false;
}

fn moduleReadonlyProjectionContainsMember(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    root: hir_mod_ns.NodeId,
    expression: hir_mod_ns.NodeId,
    type_arg: hir_mod_ns.NodeId,
    member_name: []const u8,
) bool {
    if (moduleObjectLiteralContainsMember(hir, interner, expression, member_name)) return true;
    var source_name: ?hir_mod_ns.StringId = if (hir.kindOf(expression) == .identifier)
        hir_mod_ns.identifierOf(hir, expression).name
    else
        null;
    if (hir.kindOf(type_arg) == .typeof_type) {
        const operand = hir_mod_ns.typeofTypeOf(hir, type_arg).operand;
        if (hir.kindOf(operand) == .identifier) source_name = hir_mod_ns.identifierOf(hir, operand).name;
    }
    const wanted = source_name orelse return false;
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        const decl = if (hir.kindOf(raw) == .export_decl) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (decl == hir_mod_ns.none_node_id) continue;
        const kind = hir.kindOf(decl);
        if (kind != .var_decl and kind != .let_decl and kind != .const_decl) continue;
        const variable = hir_mod_ns.varDeclOf(hir, decl);
        if (variable.name == hir_mod_ns.none_node_id or hir.kindOf(variable.name) != .identifier) continue;
        if (hir_mod_ns.identifierOf(hir, variable.name).name != wanted) continue;
        return moduleObjectLiteralContainsMember(hir, interner, variable.init, member_name);
    }
    return false;
}

fn moduleObjectLiteralContainsMember(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    node: hir_mod_ns.NodeId,
    member_name: []const u8,
) bool {
    if (node == hir_mod_ns.none_node_id or hir.kindOf(node) != .object_literal) return false;
    for (hir_mod_ns.objectLiteralProps(hir, node)) |prop| {
        if (hir.kindOf(prop) != .object_property) continue;
        const key = hir_mod_ns.objectPropertyOf(hir, prop).key;
        const key_name = switch (hir.kindOf(key)) {
            .identifier => hir_mod_ns.identifierOf(hir, key).name,
            .literal_string => hir_mod_ns.literalStringOf(hir, key).value,
            else => continue,
        };
        if (std.mem.eql(u8, interner.get(key_name), member_name)) return true;
    }
    return false;
}

fn exportStarTargetPrefersIndex(specifier: []const u8) bool {
    return std.mem.eql(u8, specifier, ".") or
        std.mem.eql(u8, specifier, "./") or
        std.mem.eql(u8, specifier, "..") or
        std.mem.eql(u8, specifier, "../") or
        std.mem.endsWith(u8, specifier, "/.") or
        std.mem.endsWith(u8, specifier, "/..");
}

pub fn ambientModuleExportFacts(
    gpa: std.mem.Allocator,
    module_source: []const u8,
    specifier: []const u8,
    name: []const u8,
    is_tsx: bool,
) ?ModuleExportFacts {
    var compilation = ts_driver.compileSource(gpa, module_source, .{
        .is_tsx = is_tsx,
        .continue_on_error = true,
        .no_emit = true,
    }) catch return null;
    defer {
        compilation.deinit();
        gpa.destroy(compilation);
    }
    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return null;
    const name_id = compilation.interner.lookup(name);
    var facts: ModuleExportFacts = .{};
    var found_module = false;
    for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |stmt| {
        const local = if (compilation.hir.kindOf(stmt) == .export_decl)
            hir_mod_ns.exportOf(&compilation.hir, stmt).decl
        else
            stmt;
        if (local == hir_mod_ns.none_node_id) continue;
        const stmt_kind = compilation.hir.kindOf(local);
        if (stmt_kind != .module_decl and stmt_kind != .namespace_decl) continue;
        const ns = hir_mod_ns.namespaceOf(&compilation.hir, local);
        if (ns.name == hir_mod_ns.none_node_id) continue;
        const module_name = switch (compilation.hir.kindOf(ns.name)) {
            .identifier => compilation.interner.get(hir_mod_ns.identifierOf(&compilation.hir, ns.name).name),
            .literal_string => compilation.interner.get(hir_mod_ns.literalStringOf(&compilation.hir, ns.name).value),
            else => continue,
        };
        if (!moduleNameMatchesSpecifier(module_name, specifier)) continue;
        found_module = true;
        const body = hir_mod_ns.namespaceBody(&compilation.hir, local);
        if (name.len == 0) {
            collectAmbientExportAssignmentFacts(gpa, &compilation.hir, body, &facts);
        } else if (name_id) |id| {
            collectAmbientModuleExportFacts(&compilation.hir, id, body, true, &facts);
            if (ambientExportAssignmentHasValueMember(gpa, &compilation.hir, &compilation.interner, body, id)) {
                facts.exported_value = true;
            }
        }
    }
    return if (found_module) facts else null;
}

fn collectAmbientExportAssignmentFacts(
    gpa: std.mem.Allocator,
    hir: *const hir_mod_ns.Hir,
    stmts: []const hir_mod_ns.NodeId,
    facts: *ModuleExportFacts,
) void {
    var target_path: std.ArrayListUnmanaged(hir_mod_ns.StringId) = .empty;
    defer target_path.deinit(gpa);
    if (!appendAmbientExportAssignmentTargetPath(gpa, hir, stmts, &target_path) or target_path.items.len == 0) return;
    if (target_path.items.len > 1) {
        facts.exported_type = true;
        facts.exported_value = true;
        return;
    }
    const target = target_path.items[0];
    for (stmts) |raw| {
        const declaration = if (hir.kindOf(raw) == .export_decl)
            hir_mod_ns.exportOf(hir, raw).decl
        else
            raw;
        if (declaration == hir_mod_ns.none_node_id or declarationName(hir, declaration) != target) continue;
        facts.exported_type = declCreatesTypeSpaceName(hir, declaration);
        facts.exported_value = declCreatesRuntimeValue(hir, declaration);
        facts.export_assignment_type_only = facts.exported_type and !facts.exported_value;
        return;
    }
}

fn ambientExportAssignmentHasValueMember(
    gpa: std.mem.Allocator,
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    stmts: []const hir_mod_ns.NodeId,
    member_name: hir_mod_ns.StringId,
) bool {
    var target_path: std.ArrayListUnmanaged(hir_mod_ns.StringId) = .empty;
    defer target_path.deinit(gpa);
    if (!appendAmbientExportAssignmentTargetPath(gpa, hir, stmts, &target_path)) return false;
    if (ambientNamespacePathExportsMember(hir, interner, stmts, target_path.items, member_name)) return true;

    const target_name = target_path.items[target_path.items.len - 1];
    const target_type = ambientNestedValueTypeName(hir, stmts, target_name) orelse return false;
    return ambientNestedInterfaceHasMember(hir, stmts, target_type, member_name);
}

fn appendAmbientExportAssignmentTargetPath(
    gpa: std.mem.Allocator,
    hir: *const hir_mod_ns.Hir,
    stmts: []const hir_mod_ns.NodeId,
    out: *std.ArrayListUnmanaged(hir_mod_ns.StringId),
) bool {
    for (stmts) |raw| {
        if (hir.kindOf(raw) != .export_decl) continue;
        const export_decl = hir_mod_ns.exportOf(hir, raw);
        if (!export_decl.is_export_equals or export_decl.decl == hir_mod_ns.none_node_id) continue;
        if (!appendAmbientEntityNamePath(gpa, hir, export_decl.decl, out)) return false;
        if (out.items.len != 1) return true;
        const alias_name = out.items[0];
        for (stmts) |statement| {
            if (hir.kindOf(statement) != .import_decl) continue;
            const import_decl = hir_mod_ns.importOf(hir, statement);
            if (import_decl.default_binding == hir_mod_ns.none_node_id or
                hir.kindOf(import_decl.default_binding) != .identifier or
                hir_mod_ns.identifierOf(hir, import_decl.default_binding).name != alias_name or
                import_decl.import_equals == hir_mod_ns.none_node_id or
                hir.kindOf(import_decl.import_equals) != .type_ref)
            {
                continue;
            }
            out.clearRetainingCapacity();
            const reference = hir_mod_ns.typeRefOf(hir, import_decl.import_equals);
            for (hir_mod_ns.typeRefQualifier(hir, import_decl.import_equals)) |qualifier| {
                if (hir.kindOf(qualifier) != .identifier) return false;
                out.append(gpa, hir_mod_ns.identifierOf(hir, qualifier).name) catch return false;
            }
            out.append(gpa, reference.name) catch return false;
            return true;
        }
        return true;
    }
    return false;
}

fn appendAmbientEntityNamePath(
    gpa: std.mem.Allocator,
    hir: *const hir_mod_ns.Hir,
    node: hir_mod_ns.NodeId,
    out: *std.ArrayListUnmanaged(hir_mod_ns.StringId),
) bool {
    switch (hir.kindOf(node)) {
        .identifier => {
            out.append(gpa, hir_mod_ns.identifierOf(hir, node).name) catch return false;
            return true;
        },
        .member_access => {
            const member = hir_mod_ns.memberOf(hir, node);
            if (member.optional or !appendAmbientEntityNamePath(gpa, hir, member.object, out)) return false;
            out.append(gpa, member.name) catch return false;
            return true;
        },
        else => return false,
    }
}

fn ambientNamespacePathExportsMember(
    hir: *const hir_mod_ns.Hir,
    interner: anytype,
    stmts: []const hir_mod_ns.NodeId,
    target_path: []const hir_mod_ns.StringId,
    member_name: hir_mod_ns.StringId,
) bool {
    for (stmts) |raw| {
        const declaration = if (hir.kindOf(raw) == .export_decl)
            hir_mod_ns.exportOf(hir, raw).decl
        else
            raw;
        if (declaration == hir_mod_ns.none_node_id or hir.kindOf(declaration) != .namespace_decl) continue;
        const namespace = hir_mod_ns.namespaceOf(hir, declaration);
        if (namespace.name == hir_mod_ns.none_node_id or hir.kindOf(namespace.name) != .identifier) continue;
        const namespace_text = interner.get(hir_mod_ns.identifierOf(hir, namespace.name).name);

        const consumed = ambientNamespaceNameConsumesPath(interner, namespace_text, target_path) orelse 0;
        if (consumed == target_path.len) {
            for (hir_mod_ns.namespaceBody(hir, declaration)) |member_raw| {
                const member = if (hir.kindOf(member_raw) == .export_decl)
                    hir_mod_ns.exportOf(hir, member_raw).decl
                else
                    member_raw;
                if (member == hir_mod_ns.none_node_id or declarationName(hir, member) != member_name) continue;
                if (declCreatesRuntimeValue(hir, member) or
                    hir.kindOf(member) == .namespace_decl or
                    hir.kindOf(member) == .module_decl) return true;
            }
        } else if (consumed > 0 and consumed < target_path.len and
            ambientNamespacePathExportsMember(
                hir,
                interner,
                hir_mod_ns.namespaceBody(hir, declaration),
                target_path[consumed..],
                member_name,
            ))
        {
            return true;
        }

        if (ambientNamespaceNameHasProjectedMember(interner, namespace_text, target_path, member_name)) return true;
    }
    return false;
}

fn ambientNamespaceNameConsumesPath(
    interner: anytype,
    namespace_text: []const u8,
    path: []const hir_mod_ns.StringId,
) ?usize {
    if (path.len == 0) return null;
    var offset: usize = 0;
    var consumed: usize = 0;
    while (consumed < path.len) : (consumed += 1) {
        const segment = interner.get(path[consumed]);
        if (!std.mem.startsWith(u8, namespace_text[offset..], segment)) return null;
        offset += segment.len;
        if (offset == namespace_text.len) return consumed + 1;
        if (namespace_text[offset] != '.') return null;
        offset += 1;
    }
    return null;
}

fn ambientNamespaceNameHasProjectedMember(
    interner: anytype,
    namespace_text: []const u8,
    target_path: []const hir_mod_ns.StringId,
    member_name: hir_mod_ns.StringId,
) bool {
    var offset: usize = 0;
    for (target_path) |segment_id| {
        const segment = interner.get(segment_id);
        if (!std.mem.startsWith(u8, namespace_text[offset..], segment)) return false;
        offset += segment.len;
        if (offset >= namespace_text.len or namespace_text[offset] != '.') return false;
        offset += 1;
    }
    const member_text = interner.get(member_name);
    if (!std.mem.startsWith(u8, namespace_text[offset..], member_text)) return false;
    offset += member_text.len;
    return offset == namespace_text.len or namespace_text[offset] == '.';
}

fn ambientNestedValueTypeName(
    hir: *const hir_mod_ns.Hir,
    stmts: []const hir_mod_ns.NodeId,
    value_name: hir_mod_ns.StringId,
) ?hir_mod_ns.StringId {
    for (stmts) |raw| {
        const declaration = if (hir.kindOf(raw) == .export_decl)
            hir_mod_ns.exportOf(hir, raw).decl
        else
            raw;
        if (declaration == hir_mod_ns.none_node_id) continue;
        switch (hir.kindOf(declaration)) {
            .var_decl, .let_decl, .const_decl => {
                const variable = hir_mod_ns.varDeclOf(hir, declaration);
                if (variable.name == hir_mod_ns.none_node_id or hir.kindOf(variable.name) != .identifier or
                    hir_mod_ns.identifierOf(hir, variable.name).name != value_name or
                    variable.type_annotation == hir_mod_ns.none_node_id or
                    hir.kindOf(variable.type_annotation) != .type_ref) continue;
                const type_ref = hir_mod_ns.typeRefOf(hir, variable.type_annotation);
                if (type_ref.qualifier_len == 0) return type_ref.name;
            },
            .namespace_decl, .module_decl => {
                if (ambientNestedValueTypeName(hir, hir_mod_ns.namespaceBody(hir, declaration), value_name)) |name| return name;
            },
            else => {},
        }
    }
    return null;
}

fn ambientNestedInterfaceHasMember(
    hir: *const hir_mod_ns.Hir,
    stmts: []const hir_mod_ns.NodeId,
    interface_name: hir_mod_ns.StringId,
    member_name: hir_mod_ns.StringId,
) bool {
    for (stmts) |raw| {
        const declaration = if (hir.kindOf(raw) == .export_decl)
            hir_mod_ns.exportOf(hir, raw).decl
        else
            raw;
        if (declaration == hir_mod_ns.none_node_id) continue;
        switch (hir.kindOf(declaration)) {
            .interface_decl => {
                if (declarationName(hir, declaration) != interface_name) continue;
                for (hir_mod_ns.interfaceMembers(hir, declaration)) |member| {
                    if (hir.kindOf(member) != .interface_member) continue;
                    if (hir_mod_ns.interfaceMemberOf(hir, member).name == member_name) return true;
                }
            },
            .namespace_decl, .module_decl => {
                if (ambientNestedInterfaceHasMember(
                    hir,
                    hir_mod_ns.namespaceBody(hir, declaration),
                    interface_name,
                    member_name,
                )) return true;
            },
            else => {},
        }
    }
    return false;
}

fn moduleNameMatchesSpecifier(pattern: []const u8, spec: []const u8) bool {
    if (std.mem.eql(u8, pattern, spec)) return true;
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return false;
    if (std.mem.indexOfScalarPos(u8, pattern, star + 1, '*') != null) return false;
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    return spec.len >= prefix.len + suffix.len and
        std.mem.startsWith(u8, spec, prefix) and
        std.mem.endsWith(u8, spec, suffix);
}

fn collectAmbientModuleExportFacts(
    hir: *const hir_mod_ns.Hir,
    name: hir_mod_ns.StringId,
    stmts: []const hir_mod_ns.NodeId,
    is_ambient: bool,
    facts: *ModuleExportFacts,
) void {
    for (stmts) |stmt| {
        if (hir.kindOf(stmt) == .export_decl) {
            const ex = hir_mod_ns.exportOf(hir, stmt);
            if (ex.decl == hir_mod_ns.none_node_id) {
                for (hir_mod_ns.exportNamed(hir, stmt)) |spec_node| {
                    if (hir.kindOf(spec_node) != .import_specifier) continue;
                    const sp = hir_mod_ns.importSpecifierOf(hir, spec_node);
                    if (sp.local != name and sp.imported != name) continue;
                    if (ex.is_type_only or sp.is_type_only) {
                        facts.type_only_pos = 0;
                        facts.exported_type = true;
                    } else {
                        facts.exported_value = true;
                    }
                }
            }
            if (ex.decl == hir_mod_ns.none_node_id) continue;
            collectAmbientModuleExportDeclFacts(hir, name, ex.decl, ex.is_type_only, is_ambient, facts);
            continue;
        }
        collectAmbientModuleExportDeclFacts(hir, name, stmt, false, is_ambient, facts);
    }
}

fn collectAmbientModuleExportDeclFacts(
    hir: *const hir_mod_ns.Hir,
    name: hir_mod_ns.StringId,
    decl: hir_mod_ns.NodeId,
    is_type_only: bool,
    is_ambient: bool,
    facts: *ModuleExportFacts,
) void {
    if (declarationName(hir, decl) != name) return;
    if (declCreatesTypeSpaceName(hir, decl)) facts.exported_type = true;
    if (ambientConstEnumDeclNamed(hir, decl, name, is_ambient)) facts.ambient_const_enum = true;
    if (is_type_only) {
        facts.type_only_pos = 0;
    } else if (declCreatesRuntimeValue(hir, decl)) {
        facts.exported_value = true;
    }
}

fn moduleRootHasExportedRuntimeValue(hir: *const hir_mod_ns.Hir, root: hir_mod_ns.NodeId, name: hir_mod_ns.StringId) bool {
    if (hir.kindOf(root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(hir, root)) |stmt| {
        if (hir.kindOf(stmt) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(hir, stmt);
        const decl = ex.decl;
        if (decl != hir_mod_ns.none_node_id) {
            if (declarationName(hir, decl) == name and declCreatesRuntimeValue(hir, decl)) return true;
        }
        for (hir_mod_ns.exportNamed(hir, stmt)) |spec_node| {
            if (hir.kindOf(spec_node) != .import_specifier) continue;
            const sp = hir_mod_ns.importSpecifierOf(hir, spec_node);
            // `local` is the public export name; `imported` is the owner-local
            // binding that supplies its value. A renamed clause must not make
            // both names importable (`export { hidden as public }`).
            if (sp.local == name) {
                return moduleRootLocalNameCreatesRuntimeValue(hir, root, sp.imported);
            }
        }
    }
    return false;
}

fn declarationFilenameLike(filename: []const u8) bool {
    if (std.mem.endsWith(u8, filename, ".d.ts")) return true;
    if (std.mem.endsWith(u8, filename, ".d.mts")) return true;
    if (std.mem.endsWith(u8, filename, ".d.cts")) return true;
    return std.mem.endsWith(u8, filename, ".ts") and std.mem.indexOf(u8, filename, ".d.") != null;
}

fn ambientConstEnumDeclNamed(
    hir: *const hir_mod_ns.Hir,
    decl: hir_mod_ns.NodeId,
    name: hir_mod_ns.StringId,
    is_ambient: bool,
) bool {
    if (!is_ambient or hir.kindOf(decl) != .enum_decl) return false;
    const e = hir_mod_ns.enumOf(hir, decl);
    return e.is_const and declarationName(hir, decl) == name;
}

fn moduleRootLocalAmbientConstEnum(
    hir: *const hir_mod_ns.Hir,
    root: hir_mod_ns.NodeId,
    name: hir_mod_ns.StringId,
    is_ambient: bool,
) bool {
    if (hir.kindOf(root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        const stmt = if (hir.kindOf(raw) == .export_decl) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (stmt == hir_mod_ns.none_node_id) continue;
        if (ambientConstEnumDeclNamed(hir, stmt, name, is_ambient)) return true;
    }
    return false;
}

fn moduleRootLocalNameCreatesRuntimeValue(hir: *const hir_mod_ns.Hir, root: hir_mod_ns.NodeId, name: hir_mod_ns.StringId) bool {
    if (hir.kindOf(root) != .block_stmt) return false;
    for (hir_mod_ns.blockStmts(hir, root)) |raw| {
        if (hir.kindOf(raw) == .import_decl) continue;
        const stmt = if (hir.kindOf(raw) == .export_decl) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (stmt == hir_mod_ns.none_node_id) continue;
        if (declarationName(hir, stmt) == name and declCreatesRuntimeValue(hir, stmt)) return true;
    }
    return false;
}

fn declCreatesTypeSpaceName(hir: *const hir_mod_ns.Hir, node: hir_mod_ns.NodeId) bool {
    return switch (hir.kindOf(node)) {
        .interface_decl, .type_alias_decl, .class_decl, .class_expr, .enum_decl, .namespace_decl, .module_decl => true,
        else => false,
    };
}

fn declarationName(hir: *const hir_mod_ns.Hir, node: hir_mod_ns.NodeId) hir_mod_ns.StringId {
    return switch (hir.kindOf(node)) {
        .var_decl, .let_decl, .const_decl => blk: {
            const v = hir_mod_ns.varDeclOf(hir, node);
            break :blk if (v.name != hir_mod_ns.none_node_id and hir.kindOf(v.name) == .identifier)
                hir_mod_ns.identifierOf(hir, v.name).name
            else
                0;
        },
        .fn_decl, .fn_expr => blk: {
            const f = hir_mod_ns.fnDeclOf(hir, node);
            break :blk if (f.name != hir_mod_ns.none_node_id and hir.kindOf(f.name) == .identifier)
                hir_mod_ns.identifierOf(hir, f.name).name
            else
                0;
        },
        .class_decl, .class_expr => blk: {
            const c = hir_mod_ns.classOf(hir, node);
            break :blk if (c.name != hir_mod_ns.none_node_id and hir.kindOf(c.name) == .identifier)
                hir_mod_ns.identifierOf(hir, c.name).name
            else
                0;
        },
        .interface_decl => blk: {
            const interface = hir_mod_ns.interfaceOf(hir, node);
            break :blk if (interface.name != hir_mod_ns.none_node_id and hir.kindOf(interface.name) == .identifier)
                hir_mod_ns.identifierOf(hir, interface.name).name
            else
                0;
        },
        .type_alias_decl => blk: {
            const alias = hir_mod_ns.typeAliasOf(hir, node);
            break :blk if (alias.name != hir_mod_ns.none_node_id and hir.kindOf(alias.name) == .identifier)
                hir_mod_ns.identifierOf(hir, alias.name).name
            else
                0;
        },
        .enum_decl => blk: {
            const e = hir_mod_ns.enumOf(hir, node);
            break :blk if (e.name != hir_mod_ns.none_node_id and hir.kindOf(e.name) == .identifier)
                hir_mod_ns.identifierOf(hir, e.name).name
            else
                0;
        },
        .namespace_decl, .module_decl => blk: {
            const ns = hir_mod_ns.namespaceOf(hir, node);
            break :blk if (ns.name != hir_mod_ns.none_node_id and hir.kindOf(ns.name) == .identifier)
                hir_mod_ns.identifierOf(hir, ns.name).name
            else
                0;
        },
        else => 0,
    };
}

fn declCreatesRuntimeValue(hir: *const hir_mod_ns.Hir, node: hir_mod_ns.NodeId) bool {
    return switch (hir.kindOf(node)) {
        .var_decl, .let_decl, .const_decl, .fn_decl, .fn_expr, .class_decl, .class_expr, .enum_decl => true,
        .namespace_decl, .module_decl => namespaceBodyHasRuntimeValue(hir, node),
        else => false,
    };
}

fn namespaceBodyHasRuntimeValue(hir: *const hir_mod_ns.Hir, node: hir_mod_ns.NodeId) bool {
    if (hir.kindOf(node) != .namespace_decl and hir.kindOf(node) != .module_decl) return false;
    for (hir_mod_ns.namespaceBody(hir, node)) |raw| {
        const stmt = if (hir.kindOf(raw) == .export_decl) hir_mod_ns.exportOf(hir, raw).decl else raw;
        if (stmt == hir_mod_ns.none_node_id) continue;
        if (declCreatesRuntimeValue(hir, stmt)) return true;
    }
    return false;
}

/// True when `name` is exported from `module_source` via a TYPE-ONLY
/// export — `export type { name }` (or `export { type name }`), or a
/// blanket `export type * from "…"` (which re-exports every name
/// type-only, so any imported `name` came through it). Drives TS1379 /
/// TS1362. A syntactic scan of the module's top-level export statements,
/// mirroring how upstream's `getTypeOnlyExportStarDeclaration` /
/// type-only export specifiers mark a name's exported-ness as type-only.
pub fn moduleExportIsTypeOnly(
    gpa: std.mem.Allocator,
    module_source: []const u8,
    name: []const u8,
    is_tsx: bool,
) ?u32 {
    var compilation = ts_driver.compileSource(gpa, module_source, .{
        .is_tsx = is_tsx,
        .continue_on_error = true,
        .no_emit = true,
    }) catch return null;
    defer {
        compilation.deinit();
        gpa.destroy(compilation);
    }
    return moduleExportIsTypeOnlyFromCompilation(compilation, name);
}

fn moduleExportIsTypeOnlyFromCompilation(
    compilation: *const ts_driver.Compilation,
    name: []const u8,
) ?u32 {
    const root = compilation.root;
    if (compilation.hir.kindOf(root) != .block_stmt) return null;
    const name_id = compilation.interner.lookup(name);
    for (hir_mod_ns.blockStmts(&compilation.hir, root)) |stmt| {
        if (compilation.hir.kindOf(stmt) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(&compilation.hir, stmt);
        // `export type * from "…"` re-exports every name type-only.
        if (ex.is_namespace and ex.is_type_only) return compilation.hir.spanOf(stmt).start;
        // `export type { name }` / `export type { x as name }`.
        if (name_id) |nid| {
            for (hir_mod_ns.exportNamed(&compilation.hir, stmt)) |spec_node| {
                if (compilation.hir.kindOf(spec_node) != .export_specifier and
                    compilation.hir.kindOf(spec_node) != .import_specifier) continue;
                const sp = hir_mod_ns.importSpecifierOf(&compilation.hir, spec_node);
                if ((ex.is_type_only or sp.is_type_only) and
                    (sp.local == nid or sp.imported == nid)) return compilation.hir.spanOf(spec_node).start;
            }
        }
    }
    return null;
}

/// True when `name` is NOT a direct top-level type-space export of
/// `module_source` (so `moduleExportsTypeSpaceName` returned false) but
/// IS reachable as a type-space member nested inside one of the module's
/// exported namespaces — e.g. `Widget2` inside `export namespace
/// SpecializedWidget { export class Widget2 {} }`. Such a name has no
/// importable top-level alias, so it "cannot be named" in a `.d.ts` that
/// only sees the importing file's aliases. Mirrors the fall-through in
/// upstream `isSymbolAccessibleWorker`: no accessible chain, but the
/// symbol's external-module container differs from the enclosing one.
///
/// Faithful subset: we recurse only through `export`ed namespaces and
/// look for a type-space binding of `name` (interface / type alias /
/// class / enum / nested namespace). A name found only in value space,
/// or only inside a non-exported namespace, is not reported (it is not
/// reachable from the importing module at all, so upstream would emit
/// `NotAccessible` / nothing rather than `CannotBeNamed`).
pub fn moduleExportNestedTypeSpaceName(
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
    return moduleExportNestedTypeSpaceNameFromCompilation(compilation, name);
}

fn moduleExportNestedTypeSpaceNameFromCompilation(
    compilation: *ts_driver.Compilation,
    name: []const u8,
) bool {
    const id = compilation.interner.lookup(name) orelse return false;
    // A direct top-level type-space export is the `from private module`
    // case, NOT `cannot be named`; exclude it here.
    if (compilation.module.root.types.get(id)) |sym| {
        if (sym.flags.is_type and sym.flags.is_export) return false;
    }
    // Scan every namespace scope in the module. The binder does not link
    // `Symbol.members` to its body scope, but it records all scopes in
    // `module.scopes` with a `parent` back-pointer and an
    // `introducing_node`. A namespace scope is reachable cross-module
    // when its introducing `namespace N` is exported AND every enclosing
    // namespace up to the module root is likewise exported. If such a
    // scope binds `id` in type space, the name is reachable only via
    // qualification — it cannot be named by a top-level import alias.
    for (compilation.module.scopes.items) |scope| {
        if (scope.kind != .namespace) continue;
        const member = scope.types.get(id) orelse continue;
        if (!member.flags.is_type) continue;
        if (namespaceScopeIsExportReachable(compilation, scope)) return true;
    }
    return false;
}

pub const InferredExportUnsafeReference = struct {
    symbol_name: []const u8,
    module_specifier: []const u8,
};

/// Declaration-emit portability query for an exported function's
/// declared return type. Given the resolved module source and a value
/// export name (`foo` in `import { foo } from "foo"`), find the first
/// imported type reference in `foo`'s return annotation whose package
/// specifier would include a nested `node_modules` segment. This mirrors
/// the subset of tsc's declaration writer that reports TS2883 for
/// inferred exported variables such as `export const x = foo()`.
pub fn moduleInferredExportUnsafeReference(
    gpa: std.mem.Allocator,
    out: std.mem.Allocator,
    resolver: *ts_resolver.Resolver,
    module_source: []const u8,
    module_path: []const u8,
    exported_name: []const u8,
    is_tsx: bool,
) ?InferredExportUnsafeReference {
    var compilation = ts_driver.compileSource(gpa, module_source, .{
        .is_tsx = is_tsx,
        .continue_on_error = true,
        .no_emit = true,
    }) catch return null;
    defer {
        compilation.deinit();
        gpa.destroy(compilation);
    }
    const root = compilation.root;
    if (compilation.hir.kindOf(root) != .block_stmt) return null;
    const exported_id = compilation.interner.lookup(exported_name) orelse return null;
    for (hir_mod_ns.blockStmts(&compilation.hir, root)) |stmt| {
        if (compilation.hir.kindOf(stmt) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(&compilation.hir, stmt);
        const decl = ex.decl;
        if (decl == hir_mod_ns.none_node_id or compilation.hir.kindOf(decl) != .fn_decl) continue;
        const f = hir_mod_ns.fnDeclOf(&compilation.hir, decl);
        if (f.name == hir_mod_ns.none_node_id or compilation.hir.kindOf(f.name) != .identifier) continue;
        if (hir_mod_ns.identifierOf(&compilation.hir, f.name).name != exported_id) continue;
        if (f.return_type == hir_mod_ns.none_node_id) return null;
        var ctx = InferredExportScanContext{
            .out = out,
            .resolver = resolver,
            .compilation = compilation,
            .module_path = module_path,
        };
        return ctx.findUnsafeReference(f.return_type) catch null;
    }
    return null;
}

const InferredExportScanContext = struct {
    out: std.mem.Allocator,
    resolver: *ts_resolver.Resolver,
    compilation: *ts_driver.Compilation,
    module_path: []const u8,

    fn findUnsafeReference(self: *InferredExportScanContext, type_node: hir_mod_ns.NodeId) !?InferredExportUnsafeReference {
        if (type_node == hir_mod_ns.none_node_id) return null;
        switch (self.compilation.hir.kindOf(type_node)) {
            .type_ref => {
                const tr = hir_mod_ns.typeRefOf(&self.compilation.hir, type_node);
                if (tr.qualifier_len == 0) {
                    if (try self.unsafeReferenceForImportedType(tr.name)) |unsafe| return unsafe;
                }
                for (hir_mod_ns.typeRefArgs(&self.compilation.hir, type_node)) |arg| {
                    if (try self.findUnsafeReference(arg)) |unsafe| return unsafe;
                }
            },
            .tuple_type => for (hir_mod_ns.tupleTypeElements(&self.compilation.hir, type_node)) |elem| {
                if (try self.findUnsafeReference(elem)) |unsafe| return unsafe;
            },
            .array_type => {
                const at = hir_mod_ns.arrayTypeOf(&self.compilation.hir, type_node);
                if (try self.findUnsafeReference(at.element)) |unsafe| return unsafe;
            },
            .rest_type => {
                const rt = hir_mod_ns.restTypeOf(&self.compilation.hir, type_node);
                if (try self.findUnsafeReference(rt.operand)) |unsafe| return unsafe;
            },
            .union_type => for (hir_mod_ns.unionTypeMembers(&self.compilation.hir, type_node)) |member| {
                if (try self.findUnsafeReference(member)) |unsafe| return unsafe;
            },
            .intersection_type => for (hir_mod_ns.intersectionTypeMembers(&self.compilation.hir, type_node)) |member| {
                if (try self.findUnsafeReference(member)) |unsafe| return unsafe;
            },
            .fn_type, .constructor_type => {
                const ft = hir_mod_ns.fnTypeOf(&self.compilation.hir, type_node);
                if (try self.findUnsafeReference(ft.return_type)) |unsafe| return unsafe;
            },
            else => {},
        }
        return null;
    }

    fn unsafeReferenceForImportedType(
        self: *InferredExportScanContext,
        local_name: hir_mod_ns.StringId,
    ) !?InferredExportUnsafeReference {
        const binding = self.importBindingForLocal(local_name) orelse return null;
        const specifier = self.compilation.interner.get(binding.specifier);
        const resolved = self.resolver.resolve(specifier, self.module_path) catch return null;
        const rendered = try packageSpecifierForResolvedPath(self.out, resolved.path) orelse return null;
        if (std.mem.indexOf(u8, rendered, "/node_modules/") == null) {
            self.out.free(rendered);
            return null;
        }
        const symbol_name = try self.out.dupe(u8, self.compilation.interner.get(binding.imported_name));
        return .{
            .symbol_name = symbol_name,
            .module_specifier = rendered,
        };
    }

    const ImportBinding = struct {
        specifier: hir_mod_ns.StringId,
        imported_name: hir_mod_ns.StringId,
    };

    fn importBindingForLocal(
        self: *InferredExportScanContext,
        local_name: hir_mod_ns.StringId,
    ) ?ImportBinding {
        const root = self.compilation.root;
        if (self.compilation.hir.kindOf(root) != .block_stmt) return null;
        for (hir_mod_ns.blockStmts(&self.compilation.hir, root)) |stmt| {
            if (self.compilation.hir.kindOf(stmt) != .import_decl) continue;
            const imp = hir_mod_ns.importOf(&self.compilation.hir, stmt);
            for (hir_mod_ns.importNamed(&self.compilation.hir, stmt)) |spec_node| {
                const spec = hir_mod_ns.importSpecifierOf(&self.compilation.hir, spec_node);
                if (spec.local != local_name) continue;
                return .{
                    .specifier = imp.module,
                    .imported_name = spec.imported,
                };
            }
        }
        return null;
    }
};

fn packageSpecifierForResolvedPath(out: std.mem.Allocator, resolved_path: []const u8) !?[]u8 {
    const marker = "/node_modules/";
    const idx = std.mem.indexOf(u8, resolved_path, marker) orelse return null;
    var spec = resolved_path[idx + marker.len ..];
    spec = stripKnownTsJsExtension(spec);
    if (std.mem.endsWith(u8, spec, "/index")) spec = spec[0 .. spec.len - "/index".len];
    return try out.dupe(u8, spec);
}

fn stripKnownTsJsExtension(path: []const u8) []const u8 {
    const exts = [_][]const u8{
        ".d.ts",
        ".d.mts",
        ".d.cts",
        ".tsx",
        ".ts",
        ".jsx",
        ".js",
        ".mts",
        ".cts",
        ".mjs",
        ".cjs",
    };
    inline for (exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return path[0 .. path.len - ext.len];
    }
    return path;
}

/// True when `scope` (a namespace body) and every enclosing namespace up
/// to the module root are `export`ed, so the namespace chain is reachable
/// from an importing module. The binder tags `export namespace N` on the
/// value-space symbol of `N` in the *parent* scope, so we resolve the
/// scope's introducing-decl name in its parent's value table and check
/// `is_export`.
fn namespaceScopeIsExportReachable(compilation: *ts_driver.Compilation, scope: *const binder.Scope) bool {
    var cur: ?*const binder.Scope = scope;
    while (cur) |sc| {
        if (sc.kind == .module) return true; // reached the module root
        if (sc.kind != .namespace) return false;
        const parent = sc.parent orelse return false;
        // Resolve the namespace name from its introducing decl.
        const node = sc.introducing_node;
        if (compilation.hir.kindOf(node) != .namespace_decl) return false;
        const ns = hir_mod_ns.namespaceOf(&compilation.hir, node);
        if (compilation.hir.kindOf(ns.name) != .identifier) return false;
        const name_id = hir_mod_ns.identifierOf(&compilation.hir, ns.name).name;
        const sym = parent.values.get(name_id) orelse parent.namespaces.get(name_id) orelse return false;
        if (!sym.flags.is_export) return false;
        cur = parent;
    }
    return false;
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

/// Render the full extensionless module path used by TS4023 for an
/// inaccessible type reached through a CommonJS export value.
pub fn renderExternalModulePathDisplayName(gpa: std.mem.Allocator, resolved_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "\"{s}\"", .{Program.stripProgramModuleExtension(resolved_path)});
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

test "Program: export origin resolver" {
    _ = export_origins;
}

test "Program: re-export facts retain the original import-type restriction" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/leaf.ts", "export function fn<T>(value: T): T { return value; }");
    try vfs.addFile("/alias.ts", "import type { fn } from './leaf'; export { fn };");
    try vfs.addFile("/named.ts", "export { fn } from './alias';");
    try vfs.addFile("/star.ts", "export * from './named';");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    for ([_][]const u8{ "/alias.ts", "/named.ts", "/star.ts" }) |path| {
        const facts = moduleExportFactsFromResolvedModule(T.allocator, &resolver, path, "fn");
        try T.expect(facts.exported_value and !facts.exported_type);
        try T.expect(facts.generic_function and facts.call_only_function);
        try T.expect(facts.type_only_import and facts.type_only_pos != null);
        try T.expectEqualStrings("/alias.ts", facts.type_only_path);
    }
}

fn compilationHasDiagnosticCode(c: *const ts_driver.Compilation, code: u32) bool {
    for (c.diagnostics.items) |d| {
        if (d.code == code) return true;
    }
    return false;
}

fn expectCompilationLacksDiagnosticCode(c: *const ts_driver.Compilation, code: u32) !void {
    for (c.diagnostics.items) |d| {
        try T.expect(d.code != code);
    }
}

fn expectCompilationHasDiagnosticCode(c: *const ts_driver.Compilation, code: u32) !void {
    try T.expect(compilationHasDiagnosticCode(c, code));
}

const NamespaceImportTestResolver = struct {
    resolver: *ts_resolver.Resolver,
    names_available: bool = true,

    const export_names = [_][]const u8{ "initialize", "$constructor", "consume", "TypeOnly", "Opaque", "KEY" };

    const vtable = ts_driver.ExternalResolver.VTable{
        .resolve = resolve,
        .moduleExport = moduleExport,
        .moduleExportNames = moduleExportNames,
    };

    fn resolve(
        self_ptr: *anyopaque,
        specifier: []const u8,
        containing_file: []const u8,
    ) ?ts_driver.ExternalResolver.Resolution {
        const self: *NamespaceImportTestResolver = @ptrCast(@alignCast(self_ptr));
        const result = self.resolver.resolve(specifier, containing_file) catch return null;
        return .{ .path = result.path, .is_declaration = result.is_declaration };
    }

    fn moduleExport(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        name: []const u8,
    ) ?ts_driver.ExternalResolver.ModuleExport {
        if (std.mem.eql(u8, name, "TypeOnly")) return .{
            .module_name = "\"barrel\"",
            .exported_type = true,
            .exported_value = false,
            .runtime_value = null,
            .module_is_external = true,
        };
        if (std.mem.eql(u8, name, "KEY")) return .{
            .module_name = "\"barrel\"",
            .exported_type = false,
            .exported_value = true,
            .runtime_value = true,
            .module_is_external = true,
        };
        if (!std.mem.eql(u8, name, "initialize") and
            !std.mem.eql(u8, name, "$constructor") and
            !std.mem.eql(u8, name, "consume")) return null;
        return .{
            .module_name = "\"barrel\"",
            .exported_type = false,
            .exported_value = true,
            .runtime_value = true,
            .generic_function = true,
            .call_only_function = true,
            .module_is_external = true,
        };
    }

    fn moduleExportNames(
        self_ptr: *anyopaque,
        _: []const u8,
        _: []const u8,
    ) ?[]const []const u8 {
        const self: *NamespaceImportTestResolver = @ptrCast(@alignCast(self_ptr));
        if (!self.names_available) return null;
        return &export_names;
    }
};

test "module export assignment private type query follows object signatures" {
    const source =
        \\interface Private {}
        \\declare const obj: { fn(x: Private): void };
        \\export = obj;
    ;
    const name = moduleExportAssignmentPrivateTypeName(T.allocator, source, false) orelse return error.TestUnexpectedResult;
    defer T.allocator.free(name);
    try T.expectEqualStrings("Private", name);
}

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
        try T.expect(f.owner != .none);
        const source = try p.owners.source(f.owner);
        try T.expectEqualStrings(f.path, source.path);
        try T.expect(source.hir == &f.compilation.?.hir);
    }
}

test "Program: untyped recovery results do not publish checked source owners" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const id = try p.add("/recovery.ts", "");
    try p.compileAll(.{ .bind_only = true });
    const file = p.fileById(id);
    try T.expectEqual(source_owners.OwnerId.none, file.owner);
    // Model the driver's scanner-recovery contract: a safely owned partial
    // compilation may carry diagnostics but cannot provide typed storage.
    file.compilation.?.check_state = .unavailable;
    file.compilation.?.root = hir_mod_ns.none_node_id;
    try p.compileAll(.{ .no_emit = true });
    try T.expectEqual(.checked, file.compilation.?.check_state);
    try T.expectEqual(source_owners.OwnerId.none, file.owner);
    try T.expectEqual(@as(usize, 0), p.owners.owners.items.len);
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

test "Program: rootDir reports source files outside configured root" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{"rootDir":"src"}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const inside_id = try p.add("/proj/src/a.ts", "export const a = 1;");
    const outside_id = try p.add("/proj/other/b.ts", "export const b = 2;");
    try p.compileAll(.{ .pub_tsconfig = &cfg, .no_emit = true });

    for (p.fileById(inside_id).compilation.?.diagnostics.items) |d| {
        try T.expect(d.code != 6059);
    }
    var saw_6059 = false;
    for (p.fileById(outside_id).compilation.?.diagnostics.items) |d| {
        if (d.code == 6059 and
            std.mem.indexOf(u8, d.message, "File '/proj/other/b.ts' is not under 'rootDir' '/proj/src'") != null)
        {
            saw_6059 = true;
        }
    }
    try T.expect(saw_6059);
}

test "Program: imported file records TS1393 include reason (specifier + importer)" {
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

    // The imported file (b) carries an `.import` reason pointing back at
    // the importer (a) with the specifier as written, quoted — exactly
    // what `--explainFiles` renders as `Imported via "./b" from file 'a'`.
    const b = p.fileById(b_id);
    try T.expect(b.include_reason != null);
    try T.expectEqual(IncludeKind.import, b.include_reason.?.kind);
    try T.expectEqual(a_id, b.include_reason.?.importer);
    try T.expectEqualStrings("\"./b\"", b.include_reason.?.specifier_text);
    try T.expectEqual(@as(?u32, 1399), b.include_reason.?.relatedDiagnosticCode());
    try T.expectEqualStrings("File is included via import here.", b.include_reason.?.relatedDiagnosticMessage().?);
    try T.expectEqual(@as(u32, 18), b.include_reason.?.specifier_pos);
    try T.expectEqual(@as(u32, 5), b.include_reason.?.specifierSpanLen());
    const a_source = p.fileById(a_id).source;
    const import_pos = b.include_reason.?.specifier_pos;
    try T.expectEqualStrings("'./b'", a_source[import_pos .. import_pos + b.include_reason.?.specifierSpanLen()]);

    // The root importer itself has no recorded import reason — its
    // provenance is supplied by the CLI layer.
    try T.expect(p.fileById(a_id).include_reason == null);
}

test "Program: loadImportClosure keeps JavaScript external unless allowJs is enabled" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "import value from 'dep';\n");
    try vfs.addFile("/proj/node_modules/dep/package.json", "{\"main\":\"index.js\"}");
    try vfs.addFile("/proj/node_modules/dep/index.js", "module.exports = 1;\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer resolver.deinit();

    var typed_program = Program.init(T.allocator, &resolver);
    defer typed_program.deinit();
    _ = try typed_program.add("/proj/main.ts", "import value from 'dep';\n");
    try T.expectEqual(@as(usize, 0), try typed_program.loadImportClosure(.{}));
    try T.expect(typed_program.lookupPath("/proj/node_modules/dep/index.js") == null);

    var js_program = Program.init(T.allocator, &resolver);
    defer js_program.deinit();
    _ = try js_program.add("/proj/main.ts", "import value from 'dep';\n");
    try T.expectEqual(@as(usize, 1), try js_program.loadImportClosure(.{ .allow_js = true }));
    try T.expect(js_program.lookupPath("/proj/node_modules/dep/index.js") != null);
}

test "Program: triple-slash type reference preserves resolution-mode" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/app.ts", "/// <reference types=\"foo\" resolution-mode=\"require\" />\nSCRIPT;\n");
    try vfs.addFile(
        "/node_modules/@types/foo/package.json",
        "{\"exports\":{\".\":{\"import\":\"./index.d.mts\",\"require\":\"./index.d.cts\"}}}",
    );
    try vfs.addFile("/node_modules/@types/foo/index.d.mts", "export {}; declare global { const MODULE: any; }\n");
    try vfs.addFile("/node_modules/@types/foo/index.d.cts", "export {}; declare global { const SCRIPT: any; }\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{
        .strategy = .bundler,
        .module_kind = "esnext",
    });
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/app.ts", "/// <reference types=\"foo\" resolution-mode=\"require\" />\nSCRIPT;\n");

    try T.expectEqual(@as(usize, 1), try program.loadImportClosure(.{}));
    try T.expect(program.lookupPath("/node_modules/@types/foo/index.d.cts") != null);
    try T.expect(program.lookupPath("/node_modules/@types/foo/index.d.mts") == null);
}

test "Program: node_modules import records package-id include reason (TS1394)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/a.ts", "import { y } from 'dep';\n");
    try vfs.addFile("/proj/node_modules/dep/package.json",
        \\{"name":"dep","version":"1.2.3","types":"index.d.ts"}
    );
    try vfs.addFile("/proj/node_modules/dep/index.d.ts", "export declare const y: number;\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const a_id = try p.add("/proj/a.ts", "import { y } from 'dep';\n");
    const dep_id = try p.add("/proj/node_modules/dep/index.d.ts", "export declare const y: number;\n");
    try p.compileAll(.{});

    const dep = p.fileById(dep_id);
    try T.expect(dep.include_reason != null);
    try T.expectEqual(IncludeKind.import, dep.include_reason.?.kind);
    try T.expectEqual(a_id, dep.include_reason.?.importer);
    try T.expectEqualStrings("\"dep\"", dep.include_reason.?.specifier_text);
    try T.expectEqualStrings("dep/index.d.ts@1.2.3", dep.include_reason.?.package_id);
    try T.expectEqual(@as(?u32, 1399), dep.include_reason.?.relatedDiagnosticCode());
}

test "Program: duplicate package-id import records redirect file (TS1429 reason)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/app/a.ts", "import 'pkg';\n");
    try vfs.addFile("/app/nested/consumer.ts", "import 'pkg';\n");
    try vfs.addFile("/app/node_modules/pkg/package.json",
        \\{
        \\  "name": "pkg",
        \\  "version": "1.0.0",
        \\  "types": "index.d.ts"
        \\}
    );
    try vfs.addFile("/app/node_modules/pkg/index.d.ts", "export const value: number;\n");
    try vfs.addFile("/app/nested/node_modules/pkg/package.json",
        \\{
        \\  "name": "pkg",
        \\  "version": "1.0.0",
        \\  "types": "index.d.ts"
        \\}
    );
    try vfs.addFile("/app/nested/node_modules/pkg/index.d.ts", "export const value: number;\n");

    var r = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer r.deinit();
    var p = Program.init(T.allocator, &r);
    defer p.deinit();
    _ = try p.add("/app/a.ts", "import 'pkg';\n");
    const nested_id = try p.add("/app/nested/consumer.ts", "import 'pkg';\n");

    const added = try p.loadImportClosure(.{});
    try T.expectEqual(@as(usize, 2), added);

    const canonical_id = p.lookupPath("/app/node_modules/pkg/index.d.ts") orelse return error.TestUnexpectedResult;
    const redirect_id = p.lookupPath("/app/nested/node_modules/pkg/index.d.ts") orelse return error.TestUnexpectedResult;
    const canonical = p.fileById(canonical_id);
    const redirect = p.fileById(redirect_id);
    try T.expect(canonical.redirect_target == null);
    try T.expectEqual(canonical_id, redirect.redirect_target.?);
    try T.expect(redirect.compilation == null);
    try T.expect(redirect.include_reason != null);
    try T.expectEqual(IncludeKind.import, redirect.include_reason.?.kind);
    try T.expectEqual(nested_id, redirect.include_reason.?.importer);
    try T.expectEqualStrings("\"pkg\"", redirect.include_reason.?.specifier_text);
    try T.expectEqualStrings("pkg/index.d.ts@1.0.0", redirect.include_reason.?.package_id);
}

test "Program: disabled package deduplication retains physical package copies" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/app/a.ts", "import 'pkg';\n");
    try vfs.addFile("/app/nested/consumer.ts", "import 'pkg';\n");
    try vfs.addFile(
        "/app/node_modules/pkg/package.json",
        "{\"name\":\"pkg\",\"version\":\"1.0.0\",\"types\":\"index.d.ts\"}",
    );
    try vfs.addFile("/app/node_modules/pkg/index.d.ts", "export const value: number;\n");
    try vfs.addFile(
        "/app/nested/node_modules/pkg/package.json",
        "{\"name\":\"pkg\",\"version\":\"1.0.0\",\"types\":\"index.d.ts\"}",
    );
    try vfs.addFile("/app/nested/node_modules/pkg/index.d.ts", "export const value: number;\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/app/a.ts", "import 'pkg';\n");
    _ = try program.add("/app/nested/consumer.ts", "import 'pkg';\n");

    const added = try program.loadImportClosure(.{ .deduplicate_packages = false });
    try T.expectEqual(@as(usize, 2), added);
    const first_id = program.lookupPath("/app/node_modules/pkg/index.d.ts") orelse return error.TestUnexpectedResult;
    const nested_id = program.lookupPath("/app/nested/node_modules/pkg/index.d.ts") orelse return error.TestUnexpectedResult;
    try T.expect(program.fileById(first_id).redirect_target == null);
    try T.expect(program.fileById(nested_id).redirect_target == null);
    try T.expect(program.fileById(first_id).compilation != null);
    try T.expect(program.fileById(nested_id).compilation != null);
}

test "Program: project-reference output import records redirected output (TS1428 reason)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
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
    try vfs.addFile("/index.ts", "export const value = 1;\n");
    try vfs.addFile("/src/thing.ts", "import '@this/package';\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{
        .strategy = .nodenext,
        .declaration_dir = "./types",
        .out_dir = "./dist",
        .config_file_path = "/tsconfig.json",
        .project_reference_output_diagnostics = true,
    });
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const importer_id = try p.add("/src/thing.ts", "import '@this/package';\n");

    const added = try p.loadImportClosure(.{});
    try T.expectEqual(@as(usize, 1), added);

    const source_id = p.lookupPath("/index.ts") orelse return error.TestUnexpectedResult;
    const source = p.fileById(source_id);
    try T.expect(source.include_reason != null);
    try T.expectEqual(IncludeKind.import, source.include_reason.?.kind);
    try T.expectEqual(importer_id, source.include_reason.?.importer);
    try T.expectEqualStrings("\"@this/package\"", source.include_reason.?.specifier_text);
    try T.expectEqualStrings("", source.include_reason.?.package_id);
    try T.expectEqualStrings("/types/index.d.ts", source.include_reason.?.project_reference_output);
}

test "Program: loadImportClosure follows importHelpers tslib import (TS1395/TS1396 reason)" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{"importHelpers":true}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "export async function f() { return 1; }\n");
    try vfs.addFile("/proj/node_modules/tslib/package.json",
        \\{"name":"tslib","version":"2.6.2","types":"tslib.d.ts"}
    );
    try vfs.addFile("/proj/node_modules/tslib/tslib.d.ts", "export declare function __awaiter(): void;\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const main_id = try p.add("/proj/main.ts", "export async function f() { return 1; }\n");

    const added = try p.loadImportClosure(ts_driver.optionsFromConfig(&cfg));
    try T.expectEqual(@as(usize, 1), added);

    const tslib_id = p.lookupPath("/proj/node_modules/tslib/tslib.d.ts") orelse return error.TestUnexpectedResult;
    const tslib = p.fileById(tslib_id);
    try T.expect(tslib.include_reason != null);
    try T.expectEqual(IncludeKind.imported_helper, tslib.include_reason.?.kind);
    try T.expectEqual(main_id, tslib.include_reason.?.importer);
    try T.expectEqualStrings("\"tslib\"", tslib.include_reason.?.specifier_text);
    try T.expectEqualStrings("tslib/tslib.d.ts@2.6.2", tslib.include_reason.?.package_id);
    try T.expectEqual(@as(?u32, null), tslib.include_reason.?.relatedDiagnosticCode());
}

test "Program: loadImportClosure follows automatic JSX runtime import (TS1397/TS1398 reason)" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{"jsx":"react-jsx"}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.tsx", "export const el = <div />;\n");
    try vfs.addFile("/proj/node_modules/react/package.json",
        \\{"name":"react","version":"18.2.0"}
    );
    try vfs.addFile("/proj/node_modules/react/jsx-runtime.d.ts", "export declare function jsx(): unknown;\nexport declare function jsxs(): unknown;\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const main_id = try p.add("/proj/main.tsx", "export const el = <div />;\n");

    const added = try p.loadImportClosure(ts_driver.optionsFromConfig(&cfg));
    try T.expectEqual(@as(usize, 1), added);

    const runtime_id = p.lookupPath("/proj/node_modules/react/jsx-runtime.d.ts") orelse return error.TestUnexpectedResult;
    const runtime = p.fileById(runtime_id);
    try T.expect(runtime.include_reason != null);
    try T.expectEqual(IncludeKind.jsx_runtime_import, runtime.include_reason.?.kind);
    try T.expectEqual(main_id, runtime.include_reason.?.importer);
    try T.expectEqualStrings("\"react/jsx-runtime\"", runtime.include_reason.?.specifier_text);
    try T.expectEqualStrings("react/jsx-runtime.d.ts@18.2.0", runtime.include_reason.?.package_id);
    try T.expectEqual(@as(?u32, null), runtime.include_reason.?.relatedDiagnosticCode());
}

test "Program: loadImportClosure follows compilerOptions.types (TS1417/TS1418 reason)" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{"types":["node"]}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "export {};\n");
    try vfs.addFile("/proj/node_modules/@types/node/package.json",
        \\{"name":"@types/node","version":"2.0.0","types":"index.d.ts"}
    );
    try vfs.addFile("/proj/node_modules/@types/node/index.d.ts", "declare const process: unknown;\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/proj/main.ts", "export {};\n");

    const added = try p.loadImportClosure(ts_driver.optionsFromConfig(&cfg));
    try T.expectEqual(@as(usize, 1), added);

    const type_id = p.lookupPath("/proj/node_modules/@types/node/index.d.ts") orelse return error.TestUnexpectedResult;
    const type_file = p.fileById(type_id);
    try T.expect(type_file.include_reason != null);
    try T.expectEqual(IncludeKind.compiler_type_reference, type_file.include_reason.?.kind);
    try T.expectEqualStrings("node", type_file.include_reason.?.specifier_text);
    try T.expectEqualStrings("@types/node/index.d.ts@2.0.0", type_file.include_reason.?.package_id);
    try T.expectEqual(@as(?u32, 1419), type_file.include_reason.?.relatedDiagnosticCode());
    try T.expectEqualStrings("File is entry point of type library specified here.", type_file.include_reason.?.relatedDiagnosticMessage().?);
}

test "Program: loadImportClosure follows implicit @types package (TS1420/TS1421 reason)" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "export {};\n");
    try vfs.addFile("/proj/node_modules/@types/node/package.json",
        \\{"name":"@types/node","version":"2.0.0","types":"index.d.ts"}
    );
    try vfs.addFile("/proj/node_modules/@types/node/index.d.ts", "declare const process: unknown;\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/proj/main.ts", "export {};\n");

    const added = try p.loadImportClosure(ts_driver.optionsFromConfig(&cfg));
    try T.expectEqual(@as(usize, 1), added);

    const type_id = p.lookupPath("/proj/node_modules/@types/node/index.d.ts") orelse return error.TestUnexpectedResult;
    const type_file = p.fileById(type_id);
    try T.expect(type_file.include_reason != null);
    try T.expectEqual(IncludeKind.implicit_type_reference, type_file.include_reason.?.kind);
    try T.expectEqualStrings("node", type_file.include_reason.?.specifier_text);
    try T.expectEqualStrings("@types/node/index.d.ts@2.0.0", type_file.include_reason.?.package_id);
    try T.expectEqual(@as(?u32, null), type_file.include_reason.?.relatedDiagnosticCode());
    try T.expect(type_file.include_reason.?.relatedDiagnosticMessage() == null);
}

test "Program: loadImportClosure skips implicit @types when compilerOptions.types is empty" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{"types":[]}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "export {};\n");
    try vfs.addFile("/proj/node_modules/@types/node/package.json",
        \\{"name":"@types/node","version":"2.0.0","types":"index.d.ts"}
    );
    try vfs.addFile("/proj/node_modules/@types/node/index.d.ts", "declare const process: unknown;\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/proj/main.ts", "export {};\n");

    const added = try p.loadImportClosure(ts_driver.optionsFromConfig(&cfg));
    try T.expectEqual(@as(usize, 0), added);
    try T.expect(p.lookupPath("/proj/node_modules/@types/node/index.d.ts") == null);
}

test "Program: loadImportClosure follows compilerOptions.lib (TS1422 reason)" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{"lib":["es2020"]}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "export {};\n");
    try vfs.addFile("/proj/lib.es2020.d.ts", "interface Promise<T> {}\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/proj/main.ts", "export {};\n");

    const added = try p.loadImportClosure(ts_driver.optionsFromConfig(&cfg));
    try T.expectEqual(@as(usize, 1), added);

    const lib_id = p.lookupPath("/proj/lib.es2020.d.ts") orelse return error.TestUnexpectedResult;
    const lib = p.fileById(lib_id);
    try T.expect(lib.include_reason != null);
    try T.expectEqual(IncludeKind.compiler_lib_reference, lib.include_reason.?.kind);
    try T.expectEqualStrings("es2020", lib.include_reason.?.specifier_text);
    try T.expectEqual(@as(?u32, 1423), lib.include_reason.?.relatedDiagnosticCode());
    try T.expectEqualStrings("File is library specified here.", lib.include_reason.?.relatedDiagnosticMessage().?);
}

test "Program: loadImportClosure follows default library for target (TS1425 reason)" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{"target":"es2021"}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "export {};\n");
    try vfs.addFile("/proj/lib.es2021.d.ts", "interface Promise<T> {}\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/proj/main.ts", "export {};\n");

    const added = try p.loadImportClosure(ts_driver.optionsFromConfig(&cfg));
    try T.expectEqual(@as(usize, 1), added);

    const lib_id = p.lookupPath("/proj/lib.es2021.d.ts") orelse return error.TestUnexpectedResult;
    const lib = p.fileById(lib_id);
    try T.expect(lib.include_reason != null);
    try T.expectEqual(IncludeKind.default_lib_reference, lib.include_reason.?.kind);
    try T.expectEqualStrings("es2021", lib.include_reason.?.specifier_text);
    try T.expectEqual(@as(?u32, 1426), lib.include_reason.?.relatedDiagnosticCode());
    try T.expectEqualStrings("File is default library for target specified here.", lib.include_reason.?.relatedDiagnosticMessage().?);
}

test "Program: loadImportClosure follows default library without explicit target (TS1424 reason)" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "export {};\n");
    try vfs.addFile("/proj/lib.es2024.d.ts", "interface Promise<T> {}\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/proj/main.ts", "export {};\n");

    const added = try p.loadImportClosure(ts_driver.optionsFromConfig(&cfg));
    try T.expectEqual(@as(usize, 1), added);

    const lib_id = p.lookupPath("/proj/lib.es2024.d.ts") orelse return error.TestUnexpectedResult;
    const lib = p.fileById(lib_id);
    try T.expect(lib.include_reason != null);
    try T.expectEqual(IncludeKind.default_lib_reference, lib.include_reason.?.kind);
    try T.expectEqualStrings("", lib.include_reason.?.specifier_text);
}

test "Program: loadImportClosure respects compilerOptions.noLib" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{"target":"es2021","noLib":true}}
    );
    cfg.file_path = "/proj/tsconfig.json";

    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "export {};\n");
    try vfs.addFile("/proj/lib.es2021.d.ts", "interface Promise<T> {}\n");

    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/proj/main.ts", "export {};\n");

    const added = try p.loadImportClosure(ts_driver.optionsFromConfig(&cfg));
    try T.expectEqual(@as(usize, 0), added);
    try T.expect(p.lookupPath("/proj/lib.es2021.d.ts") == null);
}

test "Program: final closure check sees late declarations without replacing prepared sources" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    const source = "/// <reference path=\"./bridge.d.ts\" />\nglobalThis.lateValue; missingValue; const bad: string = 1;";
    try vfs.addFile("/proj/main.ts", source);
    try vfs.addFile("/proj/bridge.d.ts", "/// <reference path=\"./definitions.d.ts\" />\n");
    try vfs.addFile("/proj/definitions.d.ts", "declare var lateValue: number;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const id = try p.add("/proj/main.ts", source);
    try p.compileAll(.{ .bind_only = true, .no_emit = true });
    const prepared = p.fileById(id).compilation.?;
    const module = prepared.module;
    const tokens = prepared.tokens.items.ptr;
    try T.expectEqual(.bound, prepared.check_state);
    try T.expectEqual(@as(usize, 0), prepared.diagnostics.items.len);

    try T.expectEqual(@as(usize, 2), try p.loadImportClosure(.{ .no_emit = true }));
    try T.expect(p.fileById(id).compilation.? == prepared);
    try T.expect(prepared.module == module and prepared.tokens.items.ptr == tokens);
    try T.expectEqual(.checked, prepared.check_state);
    if (prepared.diagnostics.items.len != 2) for (prepared.diagnostics.items) |d| std.debug.print("closure diagnostic TS{d}: {s}\n", .{ d.code, d.message });
    try T.expectEqual(@as(usize, 2), prepared.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2304), prepared.diagnostics.items[0].code);
    try T.expect(std.mem.indexOf(u8, prepared.diagnostics.items[0].message, "missingValue") != null);
    try T.expectEqual(@as(u32, 2322), prepared.diagnostics.items[1].code);
    for (p.files.items) |f| try T.expect(f.compilation.?.checked_types_ready);
}

test "Program: export name enumeration traverses long cyclic star graphs" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    for (0..48) |index| {
        const path = try std.fmt.allocPrint(T.allocator, "/p/m{d}.ts", .{index});
        defer T.allocator.free(path);
        const source = try std.fmt.allocPrint(T.allocator, "export * from './m{d}';", .{index + 1});
        defer T.allocator.free(source);
        try vfs.addFile(path, source);
    }
    try vfs.addFile("/p/m48.ts", "export class Deep {} export * from './m0'; export default Deep;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    const names = try moduleExportNamesFromResolvedModule(T.allocator, &resolver, "/p/m0.ts");
    defer {
        for (names) |name| T.allocator.free(name);
        T.allocator.free(names);
    }
    try T.expectEqual(@as(usize, 1), names.len);
    try T.expectEqualStrings("Deep", names[0]);
}

test "Program: serial parallel and streaming checks reuse the prepared graph" {
    const Mode = enum { serial, parallel, parallel_zero, streaming };
    inline for (.{ Mode.serial, Mode.parallel, Mode.parallel_zero, Mode.streaming }) |mode| {
        var vfs = ts_resolver.VirtualFs.init(T.allocator);
        defer vfs.deinit();
        const source = "/// <reference path=\"./definitions.d.ts\" />\nglobalThis.lateValue; const bad: string = 1;";
        try vfs.addFile("/proj/main.ts", source);
        try vfs.addFile("/proj/definitions.d.ts", "declare var lateValue: number;");
        var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
        defer resolver.deinit();
        var p = Program.init(T.allocator, &resolver);
        defer p.deinit();
        const id = try p.add("/proj/main.ts", source);
        try p.compileAllParallel(.{ .bind_only = true, .no_emit = true }, 2);
        const prepared = p.fileById(id).compilation.?;
        _ = try p.loadImportClosureParallel(.{ .bind_only = true, .no_emit = true }, 2);
        for (p.files.items) |f| {
            try T.expectEqual(.bound, f.compilation.?.check_state);
            try T.expectEqual(@as(usize, 0), f.compilation.?.diagnostics.items.len);
        }
        const Sink = struct {
            calls: usize = 0,
            errors: usize = 0,
            fn callback(ctx: *@This(), _: []const u8, diags: []const ts_driver.Diagnostic) void {
                ctx.calls += 1;
                ctx.errors += diags.len;
            }
        };
        var sink: Sink = .{};
        const options: ts_driver.CompileOptions = .{ .no_emit = true };
        switch (mode) {
            .serial => try p.compileAll(options),
            .parallel => try p.compileAllParallel(options, 2),
            .parallel_zero => try p.compileAllParallel(options, 0),
            .streaming => try p.compileAllStreaming(options, &sink, Sink.callback),
        }
        try T.expect(p.fileById(id).compilation.? == prepared);
        try T.expectEqual(.checked, prepared.check_state);
        if (prepared.diagnostics.items.len != 1) for (prepared.diagnostics.items) |d| std.debug.print("{s} diagnostic TS{d}: {s}\n", .{ @tagName(mode), d.code, d.message });
        try T.expectEqual(@as(usize, 1), prepared.diagnostics.items.len);
        try T.expectEqual(@as(u32, 2322), prepared.diagnostics.items[0].code);
        if (mode == .streaming) {
            try T.expectEqual(@as(usize, 2), sink.calls);
            try T.expectEqual(@as(usize, 1), sink.errors);
        }
        sink = .{};
        try p.compileAllStreaming(options, &sink, Sink.callback);
        try T.expectEqual(@as(usize, 2), sink.calls);
        try T.expectEqual(@as(usize, 1), sink.errors);
        try T.expect(p.fileById(id).compilation.? == prepared);
    }
}

test "Program: fresh execution modes share names without merging module symbols" {
    const Mode = enum { serial, parallel, streaming };
    inline for (.{ Mode.serial, Mode.parallel, Mode.streaming }) |mode| {
        var vfs = ts_resolver.VirtualFs.init(T.allocator);
        defer vfs.deinit();
        var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
        defer resolver.deinit();
        var p = Program.init(T.allocator, &resolver);
        defer p.deinit();
        const left = try p.add("/left.ts", "export const shared: string = 1;");
        const right = try p.add("/right.ts", "export const shared: number = 1;");
        const Sink = struct {
            fn callback(_: void, _: []const u8, _: []const ts_driver.Diagnostic) void {}
        };
        const options: ts_driver.CompileOptions = .{ .no_emit = true };
        switch (mode) {
            .serial => try p.compileAll(options),
            .parallel => try p.compileAllParallel(options, 2),
            .streaming => try p.compileAllStreaming(options, {}, Sink.callback),
        }
        const a = p.fileById(left).compilation.?;
        const b = p.fileById(right).compilation.?;
        try T.expect(a.interner.sharesStorageWith(&b.interner));
        try T.expect(a.interner.sharesStorageWith(&p.strings.?));
        const shared = a.interner.lookup("shared").?;
        try T.expectEqual(shared, b.interner.lookup("shared").?);
        try T.expect(a.module.root.values.get(shared).? != b.module.root.values.get(shared).?);
        try T.expectEqual(@as(usize, 1), a.diagnostics.items.len);
        try T.expectEqual(@as(u32, 2322), a.diagnostics.items[0].code);
        try T.expectEqual(@as(usize, 0), b.diagnostics.items.len);
        try p.recompileAll(options);
        try T.expectEqual(shared, p.fileById(left).compilation.?.interner.lookup("shared").?);
        try T.expectEqual(@as(usize, 1), p.fileById(left).compilation.?.diagnostics.items.len);
        try T.expectEqual(@as(usize, 0), p.fileById(right).compilation.?.diagnostics.items.len);
    }
}

test "Program: bound global index preserves declaration owners and meaning spaces" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const first = try p.add("/first.ts",
        \\interface Shared { a: string } interface Shared { b: number }
        \\var Shared = 1; var first = 1, second = 2;
        \\{ var hoisted = 1; let hidden = 1; }
        \\function f() { var local = 1; }
        \\namespace N { export var inner = 1; }
    );
    const second = try p.add("/second.ts", "interface Shared { c: boolean } let lexical = 1;");
    _ = try p.add("/module.ts", "const unused = 1; export {}; interface Private {} var privateValue = 1;");
    _ = try p.add("/comments.ts", "/*\nexport {}\n*/ interface Visible {} var visible = 1;");
    _ = try p.add("/alias.ts", "namespace Internal { export class Member {} } import Alias = Internal.Member; interface AliasVisible {}");
    try p.compileAllParallel(.{ .bind_only = true }, 2);
    var index = try p.collectBoundGlobals();
    defer index.deinit(T.allocator);
    const shared = p.strings.?.lookup("Shared").?;
    const types = index.lookup(shared, .type);
    try T.expectEqual(@as(usize, 2), types.len);
    try T.expect(types[0].file == p.fileById(first));
    try T.expect(types[1].file == p.fileById(second));
    try T.expectEqual(@as(usize, 2), types[0].symbol.decls.items.len);
    for (types) |owner| {
        const c = owner.file.compilation.?;
        try T.expect(c.module.root.types.get(shared) == owner.symbol);
        for (owner.symbol.decls.items) |decl| try T.expectEqual(.interface_decl, c.hir.kindOf(decl));
    }
    const values = index.lookup(shared, .value);
    try T.expectEqual(@as(usize, 1), values.len);
    try T.expect(values[0].symbol != types[0].symbol);
    try T.expectEqual(@as(usize, 0), index.lookup(shared, .namespace).len);
    inline for (.{ "Private", "privateValue", "hidden", "local", "inner" }) |name| {
        const id = p.strings.?.lookup(name).?;
        inline for (.{ binder.Binder.Space.value, binder.Binder.Space.type, binder.Binder.Space.namespace }) |space|
            try T.expectEqual(@as(usize, 0), index.lookup(id, space).len);
    }
    inline for (.{ "Visible", "AliasVisible" }) |name|
        try T.expectEqual(@as(usize, 1), index.lookup(p.strings.?.lookup(name).?, .type).len);
    const vars = try index.names(T.allocator, &p.strings.?, .vars);
    defer Program.freeStringSlice(T.allocator, vars);
    const expected = [_][]const u8{ "Shared", "first", "second", "hoisted", "visible" };
    try T.expectEqual(expected.len, vars.len);
    for (expected, vars) |a, b| try T.expectEqualStrings(a, b);
    try T.expectEqual(@as(usize, 1), index.lookup(p.strings.?.lookup("lexical").?, .value).len);
    const AllocationFailures = struct {
        fn run(allocator: std.mem.Allocator, program: *Program) !void {
            const original = program.gpa;
            program.gpa = allocator;
            defer program.gpa = original;
            var candidate = try program.collectBoundGlobals();
            defer candidate.deinit(allocator);
            const names = try candidate.names(allocator, &program.strings.?, .types);
            defer Program.freeStringSlice(allocator, names);
        }
    };
    try T.checkAllAllocationFailures(T.allocator, AllocationFailures.run, .{&p});
}

test "Program: all checking modes consume bound global names without leaking modules" {
    const Mode = enum { serial, parallel, streaming };
    inline for (.{ Mode.serial, Mode.parallel, Mode.streaming }) |mode| {
        var vfs = ts_resolver.VirtualFs.init(T.allocator);
        defer vfs.deinit();
        var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
        defer resolver.deinit();
        var p = Program.init(T.allocator, &resolver);
        defer p.deinit();
        const app = try p.add("/app.ts", "globalThis.second; globalThis.hoisted; globalThis.destructured; globalThis.hidden;");
        _ = try p.add("/definitions.ts", "/*\nexport {}\n*/ var first = 1, second = 2; { var hoisted = 1; } var { destructured } = { destructured: 1 };");
        _ = try p.add("/module.ts", "var hidden = 1; export {};");
        const Sink = struct {
            fn callback(_: void, _: []const u8, _: []const ts_driver.Diagnostic) void {}
        };
        const options: ts_driver.CompileOptions = .{ .strict = true, .no_emit = true };
        switch (mode) {
            .serial => try p.compileAll(options),
            .parallel => try p.compileAllParallel(options, 2),
            .streaming => try p.compileAllStreaming(options, {}, Sink.callback),
        }
        const c = p.fileById(app).compilation.?;
        try T.expectEqual(@as(usize, 1), c.diagnostics.items.len);
        try T.expectEqual(@as(u32, 7017), c.diagnostics.items[0].code);
    }
}

test "Program: retained names outlive every file and the program" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var retained = blk: {
        var p = Program.init(T.allocator, &resolver);
        defer p.deinit();
        _ = try p.add("/a.ts", "interface PersistentName {}");
        try p.compileAll(.{ .bind_only = true });
        break :blk p.strings.?.share();
    };
    defer retained.deinit();
    try T.expectEqualStrings("PersistentName", retained.get(retained.lookup("PersistentName").?));
    var independent = Program.init(T.allocator, &resolver);
    defer independent.deinit();
    try independent.compileAll(.{ .bind_only = true });
    try T.expect(!retained.sharesStorageWith(&independent.strings.?));
    try T.expect(independent.strings.?.lookup("PersistentName") == null);
}

test "Program: expanding an already checked graph invalidates early diagnostics" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    const source = "/// <reference path=\"./definitions.d.ts\" />\nglobalThis.lateValue; const bad: string = 1;";
    try vfs.addFile("/proj/main.ts", source);
    try vfs.addFile("/proj/definitions.d.ts", "declare var lateValue: number;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const id = try p.add("/proj/main.ts", source);
    const options: ts_driver.CompileOptions = .{ .no_emit = true };
    try p.compileAll(options);
    // Incomplete graph: both the missing reference and property may report.
    try T.expect(p.fileById(id).compilation.?.diagnostics.items.len > 1);
    _ = try p.loadImportClosure(options);
    const checked = p.fileById(id).compilation.?;
    try T.expectEqual(@as(usize, 1), checked.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2322), checked.diagnostics.items[0].code);
    // Repeated discovery with no expansion does not replace a checked owner.
    try T.expectEqual(@as(usize, 0), try p.loadImportClosure(options));
    try T.expect(p.fileById(id).compilation.? == checked);
    try T.expectEqual(@as(usize, 1), checked.diagnostics.items.len);
}

test "Program: failed check discards a partial source before retry" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const id = try p.add("/proj/main.ts", "export const bad: string = 1;");
    try p.compileAll(.{ .bind_only = true });
    var failing = T.FailingAllocator.init(T.allocator, .{ .fail_index = 0 });
    p.fileById(id).compilation.?.gpa = failing.allocator();
    try T.expectError(error.OutOfMemory, p.compileAll(.{ .no_emit = true }));
    try T.expect(p.fileById(id).compilation == null);
    try p.compileAll(.{ .no_emit = true });
    const checked = p.fileById(id).compilation.?;
    try T.expectEqual(.checked, checked.check_state);
    try T.expectEqual(@as(usize, 1), checked.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2322), checked.diagnostics.items[0].code);
}

test "Program: loadImportClosure follows /// <reference path> (TS1400 reason)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "/// <reference path=\"./dep.ts\" />\nlet x = 1;\n");
    try vfs.addFile("/proj/dep.ts", "declare const dep: number;\n");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const main_id = try p.add("/proj/main.ts", "/// <reference path=\"./dep.ts\" />\nlet x = 1;\n");

    // Only main.ts is a root; the closure must discover dep.ts via the
    // reference directive and add it.
    const added = try p.loadImportClosure(.{});
    try T.expectEqual(@as(usize, 1), added);

    const dep_id = p.lookupPath("/proj/dep.ts") orelse return error.TestUnexpectedResult;
    const dep = p.fileById(dep_id);
    try T.expect(dep.include_reason != null);
    try T.expectEqual(IncludeKind.reference_file, dep.include_reason.?.kind);
    try T.expectEqual(main_id, dep.include_reason.?.importer);
    try T.expectEqualStrings("./dep.ts", dep.include_reason.?.specifier_text);
    try T.expectEqual(@as(?u32, 1401), dep.include_reason.?.relatedDiagnosticCode());
    try T.expectEqualStrings("File is included via reference here.", dep.include_reason.?.relatedDiagnosticMessage().?);
    try T.expectEqual(@as(u32, 21), dep.include_reason.?.specifier_pos);
    try T.expectEqual(@as(u32, 8), dep.include_reason.?.specifierSpanLen());
    const main_source = p.fileById(main_id).source;
    const ref_pos = dep.include_reason.?.specifier_pos;
    try T.expectEqualStrings("./dep.ts", main_source[ref_pos .. ref_pos + dep.include_reason.?.specifierSpanLen()]);
}

test "Program: compileAll satisfies split-file triple-slash reference path" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/c.d.ts", "declare module \"C\" { export class Cls {} }\n");
    try vfs.addFile("/d.ts", "/// <reference path=\"c.d.ts\" />\nimport { Cls } from \"C\";\n");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .classic });
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/c.d.ts", "declare module \"C\" { export class Cls {} }\n");
    const d_id = try p.add("/d.ts", "/// <reference path=\"c.d.ts\" />\nimport { Cls } from \"C\";\n");

    try p.compileAll(.{ .no_emit = true });

    const d = p.fileById(d_id);
    const c = d.compilation orelse return error.TestUnexpectedResult;
    for (c.diagnostics.items) |diag| {
        try T.expect(diag.code != 6053);
    }
}

test "Program: loadImportClosure follows /// <reference types> (TS1402/TS1403 reason)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/main.ts", "/// <reference types=\"node\" />\n");
    try vfs.addFile("/proj/node_modules/@types/node/package.json",
        \\{ "name": "@types/node", "version": "1.0.0", "types": "index.d.ts" }
    );
    try vfs.addFile("/proj/node_modules/@types/node/index.d.ts", "declare const process: unknown;\n");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const main_id = try p.add("/proj/main.ts", "/// <reference types=\"node\" />\n");

    const added = try p.loadImportClosure(.{});
    try T.expectEqual(@as(usize, 1), added);

    const type_id = p.lookupPath("/proj/node_modules/@types/node/index.d.ts") orelse return error.TestUnexpectedResult;
    const type_file = p.fileById(type_id);
    try T.expect(type_file.include_reason != null);
    try T.expectEqual(IncludeKind.type_reference, type_file.include_reason.?.kind);
    try T.expectEqual(main_id, type_file.include_reason.?.importer);
    try T.expectEqualStrings("node", type_file.include_reason.?.specifier_text);
    try T.expectEqualStrings("@types/node/index.d.ts@1.0.0", type_file.include_reason.?.package_id);
    try T.expectEqual(@as(?u32, 1404), type_file.include_reason.?.relatedDiagnosticCode());
    try T.expectEqualStrings("File is included via type library reference here.", type_file.include_reason.?.relatedDiagnosticMessage().?);
    try T.expectEqual(@as(u32, 22), type_file.include_reason.?.specifier_pos);
    try T.expectEqual(@as(u32, 4), type_file.include_reason.?.specifierSpanLen());
}

test "Program: loadImportClosure follows /// <reference lib> (TS1405 reason)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/proj/src/main.ts", "/// <reference lib=\"es2015\" />\n");
    try vfs.addFile("/proj/lib.es2015.d.ts", "interface Promise<T> {}\n");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const main_id = try p.add("/proj/src/main.ts", "/// <reference lib=\"es2015\" />\n");

    const added = try p.loadImportClosure(.{});
    try T.expectEqual(@as(usize, 1), added);

    const lib_id = p.lookupPath("/proj/lib.es2015.d.ts") orelse return error.TestUnexpectedResult;
    const lib = p.fileById(lib_id);
    try T.expect(lib.include_reason != null);
    try T.expectEqual(IncludeKind.lib_reference, lib.include_reason.?.kind);
    try T.expectEqual(main_id, lib.include_reason.?.importer);
    try T.expectEqualStrings("es2015", lib.include_reason.?.specifier_text);
    try T.expectEqual(@as(?u32, 1406), lib.include_reason.?.relatedDiagnosticCode());
    try T.expectEqualStrings("File is included via library reference here.", lib.include_reason.?.relatedDiagnosticMessage().?);
    try T.expectEqual(@as(u32, 20), lib.include_reason.?.specifier_pos);
    try T.expectEqual(@as(u32, 6), lib.include_reason.?.specifierSpanLen());
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

test "Program: declaration emit reports nonlocal module interface augmentation (TS6232 with TS6233 related)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "export interface A { value: string; }");
    _ = try p.add("/augment.ts",
        \\import "./a";
        \\declare module "./a" {
        \\  interface A { extra(): string; }
        \\}
    );
    try p.compileAll(.{ .strict_flags = .{ .declaration = true } });
    const augmentation = p.fileById(1).compilation orelse return error.TestFailed;
    var saw_6232 = false;
    var saw_6233_related = false;
    for (augmentation.diagnostics.items) |d| {
        if (d.code != 6232) continue;
        saw_6232 = true;
        try T.expectEqualStrings("Declaration augments declaration in another file. This cannot be serialized.", d.message);
        for (d.related) |rel| {
            if (rel.code == 6233 and rel.file != null and std.mem.eql(u8, rel.file.?, "/a.ts")) {
                try T.expectEqualStrings(
                    "This is the declaration being augmented. Consider moving the augmenting declaration into the same file.",
                    rel.message,
                );
                saw_6233_related = true;
            }
        }
    }
    try T.expect(saw_6232);
    try T.expect(saw_6233_related);
}

test "Program: isolated declaration emit reports imports required by augmentations (TS9026)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/child1.ts",
        \\import { ParentThing } from "./parent";
        \\declare module "./parent" {
        \\  interface ParentThing { add(): string; }
        \\}
        \\export function child1(prototype: ParentThing): void {
        \\  prototype.add = () => "ok";
        \\}
    );
    _ = try p.add("/parent.ts",
        \\import { child1 } from "./child1";
        \\export interface ParentThing {}
        \\child1({});
    );
    try p.compileAll(.{ .strict_flags = .{ .declaration = true, .isolated_declarations = true } });

    const parent = p.fileById(1).compilation orelse return error.TestFailed;
    var saw_9026 = false;
    for (parent.diagnostics.items) |d| {
        if (d.code != 9026) continue;
        saw_9026 = true;
        try T.expectEqualStrings(
            "Declaration emit for this file requires preserving this import for augmentations. This is not supported with --isolatedDeclarations.",
            d.message,
        );
        const pos = d.pos;
        try T.expectEqualStrings("import", parent.source[pos .. pos + "import".len]);
    }
    try T.expect(saw_9026);
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

test "Program: source markers match exact byte searches" {
    const Reference = struct {
        fn compare(source: []const u8) !void {
            const index = ProgramSourceMarkerIndex.scan(source);
            inline for (program_source_markers) |marker| {
                try T.expectEqual(std.mem.indexOf(u8, source, marker), index.indexOf(marker));
            }
        }
    };
    for ([_][]const u8{
        "",                                                   "namespace module global declare interface class export exports =",
        "// namespace\n'export' /* module */ exports=global", "namespaceTail xdeclare xinterface className exportsexport",
        "\x00\xffinterface\r\nmodule\x00exports=",
    }) |source| try Reference.compare(source);
    var seed: u32 = 0x1234abcd;
    var buffer: [256]u8 = undefined;
    for (0..512) |round| {
        const len = round % buffer.len;
        for (buffer[0..len]) |*byte| {
            seed = seed *% 1664525 +% 1013904223;
            byte.* = @truncate(seed >> 24);
        }
        const marker = program_source_markers[round % program_source_markers.len];
        if (len >= marker.len) {
            const offset = seed % (len - marker.len + 1);
            @memcpy(buffer[offset..][0..marker.len], marker);
        }
        try Reference.compare(buffer[0..len]);
    }
}

test "Program: source markers preserve collection metadata" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const Fixture = struct { path: []const u8, source: []const u8 };
    for ([_]Fixture{
        .{ .path = "/class.ts", .source = "export class Box { value: string; }" },
        .{ .path = "/augment.ts", .source = "import './class'; declare module './class' { interface Box { extra(): string; } namespace Box { const version: number; } }" },
        .{ .path = "/ambient.d.ts", .source = "declare module 'ambient' { interface Named { value: string; } } declare global { namespace Shared { interface Member { value: string; } } }" },
        .{ .path = "/script.js", .source = "var Tools = {}; Tools.make = function() { return 1; }; exports.answer = 42;" },
        .{ .path = "/globals.ts", .source = "namespace Shared { export let value = 1; }" },
        .{ .path = "/export.d.ts", .source = "declare class Service { private secret: string; } export = Service;" },
        .{ .path = "/plain.ts", .source = "const text = 'namespace module global declare interface class export exports =';" },
    }) |fixture| {
        try vfs.addFile(fixture.path, fixture.source);
        _ = try p.add(fixture.path, fixture.source);
    }
    try p.prepareNameStore();
    try p.prepareFiles(.{ .bind_only = true, .continue_on_error = true, .no_emit = true });
    const before_roots = try p.collectAmbientGlobalNamespaceRoots();
    defer Program.freeStringSlice(T.allocator, before_roots);
    const before_expandos = try p.collectScriptObjectExpandos();
    defer T.allocator.free(before_expandos);
    const before_augmentations = try p.collectRelativeModuleInterfaceAugmentations();
    defer T.allocator.free(before_augmentations);
    const before_classes = try p.collectProgramExportedClasses();
    defer Program.freeProgramExportedClasses(T.allocator, before_classes);
    const before_interfaces = try p.collectAmbientModuleInterfaceExports();
    defer Program.freeProgramAmbientModuleInterfaceExports(T.allocator, before_interfaces);
    const before_commonjs = try p.collectProgramCommonJsExports();
    defer Program.freeProgramCommonJsExports(T.allocator, before_commonjs);
    try T.expect(before_roots.len > 0);
    try T.expect(before_expandos.len > 0);
    try T.expect(before_augmentations.len > 0);
    try T.expect(before_classes.len > 0);
    try T.expect(before_interfaces.len > 0);
    try T.expect(before_commonjs.len > 0);

    p.prepareSourceMarkers();
    defer p.clearSourceMarkers();
    for (p.files.items) |file| {
        const markers = file.source_markers orelse {
            try T.expect(false);
            continue;
        };
        switch (markers) {
            .borrowed => |index| try T.expect(index == &file.compilation.?.source_markers),
            .owned => try T.expect(false),
        }
    }
    const after_roots = try p.collectAmbientGlobalNamespaceRoots();
    defer Program.freeStringSlice(T.allocator, after_roots);
    const after_expandos = try p.collectScriptObjectExpandos();
    defer T.allocator.free(after_expandos);
    const after_augmentations = try p.collectRelativeModuleInterfaceAugmentations();
    defer T.allocator.free(after_augmentations);
    const after_classes = try p.collectProgramExportedClasses();
    defer Program.freeProgramExportedClasses(T.allocator, after_classes);
    const after_interfaces = try p.collectAmbientModuleInterfaceExports();
    defer Program.freeProgramAmbientModuleInterfaceExports(T.allocator, after_interfaces);
    const after_commonjs = try p.collectProgramCommonJsExports();
    defer Program.freeProgramCommonJsExports(T.allocator, after_commonjs);
    try T.expectEqualDeep(before_roots, after_roots);
    try T.expectEqualDeep(before_expandos, after_expandos);
    try T.expectEqualDeep(before_augmentations, after_augmentations);
    try T.expectEqualDeep(before_classes, after_classes);
    try T.expectEqualDeep(before_interfaces, after_interfaces);
    try T.expectEqualDeep(before_commonjs, after_commonjs);
}

test "Program: source markers reset on updates and exclude redirects" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const canonical = try p.add("/canonical.ts", "namespace Real {}");
    const redirected = try p.addRedirectFile("/redirect.ts", canonical);
    // A redirect's source is not consulted, even when its bytes differ.
    p.fileById(redirected).source = "namespace Ghost {}";
    p.prepareSourceMarkers();
    try T.expect(p.fileById(canonical).source_markers != null);
    try T.expect(p.fileById(redirected).source_markers == null);
    const roots = try p.collectAmbientGlobalNamespaceRoots();
    defer Program.freeStringSlice(T.allocator, roots);
    try T.expectEqual(@as(usize, 1), roots.len);
    try T.expectEqualStrings("Real", roots[0]);
    _ = try p.updateSource("/canonical.ts", "export class Next {}");
    const file = p.fileById(canonical);
    try T.expect(file.source_markers == null);
    try T.expect(file.sourceContains("class") and !file.sourceContains("namespace"));
    p.prepareSourceMarkers();
    try T.expect(file.sourceContains("class") and !file.sourceContains("namespace"));
    p.clearSourceMarkers();
    // Public source replacement between passes must not reuse old facts.
    file.source = "declare module 'changed' {}";
    try T.expect(file.sourceContains("module") and !file.sourceContains("class"));
    p.prepareSourceMarkers();
    try T.expect(file.sourceContains("module") and !file.sourceContains("class"));
    p.clearSourceMarkers();
}

test "Program: source markers clear on every compilation entry and error exit" {
    const Callback = struct {
        fn receive(count: *usize, path: []const u8, diags: []const ts_driver.Diagnostic) void {
            _ = path;
            _ = diags;
            count.* += 1;
        }
    };
    for (0..3) |mode| {
        var vfs = ts_resolver.VirtualFs.init(T.allocator);
        defer vfs.deinit();
        var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
        defer resolver.deinit();
        var p = Program.init(T.allocator, &resolver);
        defer p.deinit();
        _ = try p.add("/a.ts", "namespace Root {}");
        var count: usize = 0;
        var failing = T.FailingAllocator.init(T.allocator, .{ .fail_index = 0 });
        p.gpa = failing.allocator();
        {
            defer p.gpa = T.allocator;
            const result = switch (mode) {
                0 => p.compileAll(.{ .no_emit = true }),
                1 => p.compileAllStreaming(.{ .no_emit = true }, &count, Callback.receive),
                else => p.compileAllParallel(.{ .no_emit = true }, 2),
            };
            try T.expectError(error.OutOfMemory, result);
        }
        try T.expect(failing.has_induced_failure);
        try T.expect(p.fileById(0).source_markers == null);
        switch (mode) {
            0 => try p.compileAll(.{ .no_emit = true }),
            1 => try p.compileAllStreaming(.{ .no_emit = true }, &count, Callback.receive),
            else => try p.compileAllParallel(.{ .no_emit = true }, 2),
        }
        try T.expect(p.fileById(0).source_markers == null);
        if (mode == 1) try T.expectEqual(@as(usize, 1), count);
    }
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
    const old_owner = p.fileById(0).owner;
    try T.expect(old_owner != .none);

    const id = (try p.updateSource("/a.ts", "let y = 2;")) orelse return error.NoFile;
    // Compilation cleared; source replaced.
    try T.expect(p.fileById(id).compilation == null);
    try T.expectEqual(source_owners.OwnerId.none, p.fileById(id).owner);
    try T.expectError(error.InvalidOwner, p.owners.source(old_owner));
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
    const a_owner = p.fileById(0).compilation.?;
    const a_source_owner = p.fileById(0).owner;
    const b_source_owner = p.fileById(1).owner;
    const c_source_owner = p.fileById(2).owner;
    const original_name = p.fileById(1).compilation.?.interner.lookup("b").?;
    _ = try p.updateSource("/b.ts", "let b = 999;");
    try T.expectError(error.InvalidOwner, p.owners.source(b_source_owner));
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
    try T.expect(p.fileById(0).compilation.? == a_owner);
    try T.expectEqual(a_source_owner, p.fileById(0).owner);
    try T.expectEqual(c_source_owner, p.fileById(2).owner);
    try T.expect(b_source_owner != b.owner);
    try T.expectEqualStrings("/b.ts", (try p.owners.source(b.owner)).path);
    try T.expect(b.compilation.?.interner.sharesStorageWith(&a_owner.interner));
    try T.expectEqual(original_name, b.compilation.?.interner.lookup("b").?);
    try T.expectEqual(b.id, b.compilation.?.module.file_id);
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

test "Program: static module closure includes re-export leaves and checks their declarations" {
    const forms = [_][]const u8{
        "import './middle';",
        "export { answer } from './middle';",
        "export * from './middle';",
        "export * as group from './middle';",
        "export type { Shape } from './middle';",
        "export type * from './middle';",
    };
    for (forms) |entry_source| {
        var vfs = ts_resolver.VirtualFs.init(T.allocator);
        defer vfs.deinit();
        try vfs.addFile("/entry.ts", entry_source);
        try vfs.addFile("/middle.ts", "export * from './leaf';");
        try vfs.addFile("/leaf.ts", "export interface Shape { value: number; } export const answer: number = 1; const bad: string = answer;");
        var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
        defer resolver.deinit();
        var p = Program.init(T.allocator, &resolver);
        defer p.deinit();
        const entry = try p.add("/entry.ts", entry_source);
        try T.expectEqual(@as(usize, 2), try p.loadImportClosure(.{ .strict = true, .no_emit = true }));
        const middle = p.lookupPath("/middle.ts").?;
        const leaf = p.lookupPath("/leaf.ts").?;
        try T.expectEqualSlices(FileId, &.{middle}, p.files.items[entry].imports.items);
        try T.expectEqualSlices(FileId, &.{leaf}, p.files.items[middle].imports.items);
        try T.expect(p.reaches(entry, leaf));
        try expectCompilationHasDiagnosticCode(p.files.items[leaf].compilation.?, 2322);
        const reason = p.files.items[leaf].include_reason.?;
        try T.expectEqual(IncludeKind.import, reason.kind);
        try T.expectEqual(middle, reason.importer);
        try T.expectEqualStrings("\"./leaf\"", reason.specifier_text);
        try T.expectEqualStrings("./leaf", p.files.items[middle].source[reason.specifier_pos + 1 ..][0..6]);
    }
}

test "Program: static require closure follows nested and transitive JavaScript dependencies" {
    const entry_source = "function load() { return require('./middle'); }";
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/entry.js", entry_source);
    try vfs.addFile("/middle.js", "module.exports = require(`./leaf`);");
    try vfs.addFile("/leaf.js", "/** @type {string} */ const bad = 1; module.exports = bad;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const entry = try p.add("/entry.js", entry_source);
    try T.expectEqual(@as(usize, 2), try p.loadImportClosure(.{ .strict = true, .allow_js = true, .no_emit = true }));
    const middle = p.lookupPath("/middle.js").?;
    const leaf = p.lookupPath("/leaf.js").?;
    try T.expectEqualSlices(FileId, &.{middle}, p.files.items[entry].imports.items);
    try T.expectEqualSlices(FileId, &.{leaf}, p.files.items[middle].imports.items);
    try T.expect(p.reaches(entry, leaf));
    try expectCompilationHasDiagnosticCode(p.files.items[leaf].compilation.?, 2322);
    try T.expectEqualStrings("\"./middle\"", p.files.items[middle].include_reason.?.specifier_text);
    try T.expectEqual(@as(u32, 33), p.files.items[middle].include_reason.?.specifier_pos);
    try T.expectEqualStrings("\"./leaf\"", p.files.items[leaf].include_reason.?.specifier_text);
    try T.expectEqual(@as(u32, 25), p.files.items[leaf].include_reason.?.specifier_pos);
}

test "Program: non-static require lookalikes do not enter the dependency graph" {
    const entry_source =
        \\const text = "require('./leaf')";
        \\// require('./leaf');
        \\const name = './leaf';
        \\require(name);
        \\loader.require('./leaf');
        \\require('./leaf', 1);
        \\require(`./${name}`);
    ;
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/entry.js", entry_source);
    try vfs.addFile("/leaf.js", "/** @type {string} */ const bad = 1;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const entry = try p.add("/entry.js", entry_source);
    try T.expectEqual(@as(usize, 0), try p.loadImportClosure(.{ .strict = true, .allow_js = true, .no_emit = true }));
    try T.expectEqual(@as(usize, 1), p.files.items.len);
    try T.expectEqual(@as(usize, 0), p.files.items[entry].imports.items.len);
}

test "Program: static require cycles keep unique current edges after updates" {
    const entry_source = "require('./left'); require('./right'); require('./left');";
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/entry.js", entry_source);
    try vfs.addFile("/left.js", "require('./right'); require('./leaf');");
    try vfs.addFile("/right.js", "require('./left'); require('./leaf');");
    try vfs.addFile("/leaf.js", "module.exports = 1;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const entry = try p.add("/entry.js", entry_source);
    try T.expectEqual(@as(usize, 3), try p.loadImportClosure(.{ .bind_only = true, .allow_js = true }));
    const left = p.lookupPath("/left.js").?;
    const right = p.lookupPath("/right.js").?;
    const leaf = p.lookupPath("/leaf.js").?;
    for (0..3) |_| {
        try p.compileAll(.{ .bind_only = true, .allow_js = true });
        try T.expectEqualSlices(FileId, &.{ left, right }, p.files.items[entry].imports.items);
        try T.expectEqualSlices(FileId, &.{ right, leaf }, p.files.items[left].imports.items);
        try T.expectEqualSlices(FileId, &.{ left, leaf }, p.files.items[right].imports.items);
        try T.expect(p.reaches(left, right) and p.reaches(right, left));
    }
    _ = try p.updateSource("/left.js", "module.exports = 1;");
    try p.compileAll(.{ .bind_only = true, .allow_js = true });
    try T.expectEqual(@as(usize, 0), p.files.items[left].imports.items.len);
    try T.expect(!p.reaches(left, leaf));
    try T.expect(p.reaches(entry, leaf));
}

test "Program: checked CommonJS whole exports type requiring consumers in dependency order" {
    const Mode = enum { serial, parallel, streaming };
    const owner_source =
        \\class Service { value = 'text'; }
        \\module.exports = new Service();
    ;
    const app_source =
        \\const instance = require('./owner');
        \\/** @type {boolean} */ const bad = instance.value;
        \\instance.missing;
    ;
    inline for (.{ Mode.serial, Mode.parallel, Mode.streaming }) |mode| {
        for ([_]bool{ false, true }) |owner_first| {
            var vfs = ts_resolver.VirtualFs.init(T.allocator);
            defer vfs.deinit();
            try vfs.addFile("/owner.js", owner_source);
            try vfs.addFile("/app.js", app_source);
            var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
            defer resolver.deinit();
            var program = Program.init(T.allocator, &resolver);
            defer program.deinit();
            const app = if (owner_first) blk: {
                _ = try program.add("/owner.js", owner_source);
                break :blk try program.add("/app.js", app_source);
            } else blk: {
                const id = try program.add("/app.js", app_source);
                _ = try program.add("/owner.js", owner_source);
                break :blk id;
            };
            const options: ts_driver.CompileOptions = .{
                .allow_js = true,
                .check_js = true,
                .strict = true,
                .no_emit = true,
            };
            const Sink = struct {
                fn callback(_: void, _: []const u8, _: []const ts_driver.Diagnostic) void {}
            };
            switch (mode) {
                .serial => try program.compileAll(options),
                .parallel => try program.compileAllParallel(options, 2),
                .streaming => try program.compileAllStreaming(options, {}, Sink.callback),
            }
            const compilation = program.fileById(app).compilation.?;
            try expectCompilationHasDiagnosticCode(compilation, 2322);
            try expectCompilationHasDiagnosticCode(compilation, 2339);
        }
    }
}

test "Program: re-export cycles and diamonds retain unique current dependency edges" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    const entry_source = "export * from './left'; export * from './right'; import './left';";
    try vfs.addFile("/entry.ts", entry_source);
    try vfs.addFile("/left.ts", "export * from './right'; export * from './leaf';");
    try vfs.addFile("/right.ts", "export * from './left'; export * from './leaf';");
    try vfs.addFile("/leaf.ts", "export const answer = 1;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const entry = try p.add("/entry.ts", entry_source);
    try T.expectEqual(@as(usize, 3), try p.loadImportClosure(.{ .bind_only = true }));
    const left = p.lookupPath("/left.ts").?;
    const right = p.lookupPath("/right.ts").?;
    const leaf = p.lookupPath("/leaf.ts").?;
    for (0..3) |_| {
        try p.compileAll(.{ .bind_only = true });
        try T.expectEqualSlices(FileId, &.{ left, right }, p.files.items[entry].imports.items);
        try T.expectEqualSlices(FileId, &.{ right, leaf }, p.files.items[left].imports.items);
        try T.expectEqualSlices(FileId, &.{ left, leaf }, p.files.items[right].imports.items);
        try T.expect(p.reaches(left, right) and p.reaches(right, left));
        const order = try p.topologicalOrder();
        defer T.allocator.free(order);
        try T.expectEqual(@as(usize, 4), order.len);
    }
    _ = try p.updateSource("/left.ts", "export const local = 1;");
    try p.compileAll(.{ .bind_only = true });
    try T.expectEqual(@as(usize, 0), p.files.items[left].imports.items.len);
    try T.expect(!p.reaches(left, leaf));
    try T.expect(p.reaches(entry, leaf));
}

test "Program: importHelpers diagnoses missing Stage 3 decorator helpers" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/main.ts",
        \\export {};
        \\declare var dec: any;
        \\@dec class C { @dec static #method() {} }
    );
    _ = try p.add("/tslib.d.ts", "export {}\n");
    try p.compileAll(.{ .emit = .{ .import_helpers = true, .es_target = .es2022 } });

    const c = p.fileById(0).compilation.?;
    var helper_count: usize = 0;
    for (c.diagnostics.items) |d| {
        if (d.code == 2343) helper_count += 1;
        try T.expect(d.code != 2354);
    }
    try T.expectEqual(@as(usize, 3), helper_count);
}

test "Program: importHelpers detects lowered resource declarations" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const source =
        \\export {};
        \\await using value = null;
    ;
    _ = try p.add("/main.ts", source);
    try p.compileAll(.{ .emit = .{ .import_helpers = true, .es_target = .es2022 } });

    const c = p.fileById(0).compilation.?;
    const using_pos = std.mem.indexOf(u8, source, "await").?;
    var saw_2354 = false;
    for (c.diagnostics.items) |d| {
        if (d.code == 2354 and d.pos == using_pos) saw_2354 = true;
    }
    try T.expect(saw_2354);
}

test "Program: importHelpers reports missing tslib for commonjs namespace re-export helper" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/a.ts", "export {}\n");
    _ = try p.add("/b.ts", "export * as ns from \"./a\";\n");
    try p.compileAll(.{ .emit = .{ .import_helpers = true, .module_kind = .commonjs } });

    const c = p.fileById(1).compilation.?;
    var saw_2354 = false;
    for (c.diagnostics.items) |d| {
        if (d.code == 2354 and d.pos == 0 and
            std.mem.indexOf(u8, d.message, "module 'tslib' cannot be found") != null)
        {
            saw_2354 = true;
        }
    }
    try T.expect(saw_2354);
}

test "Program: importHelpers reports incompatible private field helper arity" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/main.ts",
        \\export {};
        \\class C {
        \\    #x = 1;
        \\    get() { return this.#x; }
        \\}
    );
    _ = try p.add("/tslib.d.ts",
        \\export declare function __classPrivateFieldGet(receiver: any, state: any, kind: any): any;
        \\export declare function __classPrivateFieldSet(receiver: any, state: any, value: any, kind: any): any;
    );
    try p.compileAll(.{ .emit = .{ .import_helpers = true } });

    const c = p.fileById(0).compilation.?;
    var saw_get = false;
    var saw_set = false;
    for (c.diagnostics.items) |d| {
        if (d.code != 2807) continue;
        if (std.mem.indexOf(u8, d.message, "'__classPrivateFieldGet' with 4 parameters") != null) saw_get = true;
        if (std.mem.indexOf(u8, d.message, "'__classPrivateFieldSet' with 5 parameters") != null) saw_set = true;
    }
    try T.expect(saw_get);
    try T.expect(saw_set);
}

test "Program: importHelpers reports incompatible array spread helper arity at ES5" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const source =
        \\export {};
        \\const values = [1, , 2];
        \\const result = [0, ...values, 3];
    ;
    const main_id = try p.add("/main.ts", source);
    _ = try p.add(
        "/tslib.d.ts",
        "export declare function __spreadArray(to: any[], from: any[]): any[];\n",
    );
    try p.compileAll(.{ .no_emit = true, .emit = .{ .import_helpers = true, .es_target = .es5 } });

    const c = p.fileById(main_id).compilation.?;
    const spread_pos: u32 = @intCast(std.mem.indexOf(u8, source, "...values").?);
    var saw_2807 = false;
    for (c.diagnostics.items) |d| {
        if (d.code != 2807 or std.mem.indexOf(u8, d.message, "'__spreadArray' with 3 parameters") == null) continue;
        try T.expectEqual(spread_pos, d.pos);
        try T.expectEqual(@as(u32, "...values".len), d.span_len);
        saw_2807 = true;
    }
    try T.expect(saw_2807);
}

test "Program: parity helper cycle batch reports a missing private setter for destructuring writes" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const source =
        \\export {};
        \\class Example {
        \\    #state = { value: 0 };
        \\    update(source: { value: { value: number } }) {
        \\        ({ value: this.#state } = source);
        \\    }
        \\}
    ;
    const main_id = try p.add("/main.ts", source);
    _ = try p.add("/tslib.d.ts", "export declare function __classPrivateFieldGet(a: any, b: any, c: any, d: any): any;\n");
    try p.compileAll(.{ .emit = .{ .import_helpers = true, .es_target = .es2015 } });

    const c = p.fileById(main_id).compilation.?;
    const expected_pos: u32 = @intCast(std.mem.indexOf(u8, source, "this.#state") orelse return error.TestUnexpectedResult);
    var found = false;
    for (c.diagnostics.items) |d| {
        if (d.code != 2343 or std.mem.indexOf(u8, d.message, "'__classPrivateFieldSet'") == null) continue;
        try T.expectEqual(expected_pos, d.pos);
        try T.expectEqual(@as(u32, "this.#state".len), d.span_len);
        found = true;
    }
    try T.expect(found);
}

test "Program: parity helper cycle batch reports missing CommonJS default and namespace interop helpers" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const default_source = "import greet from \"./dependency\";";
    const namespace_source = "import greet, * as dependency from \"./dependency\";";
    const default_id = try p.add("/main.ts", default_source);
    const namespace_id = try p.add("/combined.ts", namespace_source);
    _ = try p.add("/dependency.ts", "export default function greet(name: string) { return name; }");
    _ = try p.add("/tslib.d.ts", "export const notAHelper: any;\n");
    try p.compileAll(.{
        .module_kind = "commonjs",
        .emit = .{ .import_helpers = true, .es_target = .es2015 },
    });
    try p.compileAll(.{
        .module_kind = "commonjs",
        .emit = .{ .import_helpers = true, .es_target = .es2015 },
    });

    const cases = [_]struct { id: FileId, helper: []const u8, span_len: u32 }{
        .{ .id = default_id, .helper = "__importDefault", .span_len = default_source.len },
        .{ .id = namespace_id, .helper = "__importStar", .span_len = namespace_source.len },
    };
    for (cases) |case| {
        const c = p.fileById(case.id).compilation.?;
        var found = false;
        var count: usize = 0;
        for (c.diagnostics.items) |d| {
            if (d.code != 2343 or std.mem.indexOf(u8, d.message, case.helper) == null) continue;
            try T.expectEqual(@as(u32, 0), d.pos);
            try T.expectEqual(case.span_len, d.span_len);
            found = true;
            count += 1;
        }
        try T.expect(found);
        try T.expectEqual(@as(usize, 1), count);
    }
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

test "Program: namespace imports preserve generic callbacks without a default export" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const owner =
        \\export function initialize<T>(value: T, callback: (value: T) => void): T {
        \\  callback(value);
        \\  return value;
        \\}
    ;
    const barrel = "export * from './owner';";
    const consumer =
        \\import * as api from "./barrel";
        \\api.initialize(1, value => {
        \\  const exact: number = value;
        \\  void exact;
        \\});
    ;
    const named_consumer =
        \\import { initialize } from "./barrel";
        \\initialize(1, value => {
        \\  const exact: number = value;
        \\  void exact;
        \\});
    ;
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/barrel.ts", barrel);
    try vfs.addFile("/proj/consumer.ts", consumer);
    try vfs.addFile("/proj/named-consumer.ts", named_consumer);
    _ = try p.add("/proj/owner.ts", owner);
    _ = try p.add("/proj/barrel.ts", barrel);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);
    const named_consumer_id = try p.add("/proj/named-consumer.ts", named_consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    const named_compilation = p.fileById(named_consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(named_compilation, 7006);
    try expectCompilationLacksDiagnosticCode(named_compilation, 2322);
    try expectCompilationLacksDiagnosticCode(compilation, 2339);
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try expectCompilationLacksDiagnosticCode(compilation, 2322);
}

test "Program: supported qualified interface members retain array callback context" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const shapes = "export type Value = string | number;";
    const owner =
        \\import type * as Shapes from "./shapes.js";
        \\export interface Box { items: Shapes.Value[]; }
    ;
    const consumer =
        \\import type { Box } from "./owner.js";
        \\declare const box: Box;
        \\box.items.map((value, index) => {
        \\  const wrong: never = value;
        \\  return `${index}:${wrong}`;
        \\});
    ;
    try vfs.addFile("/proj/shapes.ts", shapes);
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/shapes.ts", shapes);
    _ = try p.add("/proj/owner.ts", owner);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try expectCompilationHasDiagnosticCode(compilation, 2322);
}

test "Program: qualified interface assertions project declared array members" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const shapes =
        \\export interface Base { opaque: Set<string>; }
        \\export interface Item { value: unknown; }
        \\export interface Def<Options extends readonly Item[] = readonly Item[]> extends Base {
        \\  options: Options;
        \\}
    ;
    const consumer =
        \\import type * as Shapes from "./shapes.js";
        \\declare const source: unknown;
        \\const def = source as Shapes.Def;
        \\def.options.map((value, index) => {
        \\  const exact: Shapes.Item = value;
        \\  const wrong: boolean = value;
        \\  return index;
        \\});
    ;
    try vfs.addFile("/proj/shapes.ts", shapes);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/shapes.ts", shapes);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try expectCompilationHasDiagnosticCode(compilation, 2322);
}

test "Program: qualified indexed assertions project destructured array members" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const util =
        \\export type MimeTypes = "text/plain" | (string & {});
        \\export type InexactPartial<T> = { [K in keyof T]?: T[K] | undefined };
        \\export type PartialBag<T extends object> = InexactPartial<T> & {
        \\  [key: string]: unknown;
        \\};
    ;
    const shapes =
        \\import type * as util from "./util.js";
        \\export interface Base<Out = unknown, In = unknown> { opaque: Set<string>; output: Out; input: In; }
        \\export interface Internals extends Base<File, File> {
        \\  bag: util.PartialBag<{ values: util.MimeTypes[] }>;
        \\}
        \\export interface File { readonly type: string; }
        \\export interface FileSchema { internals: Internals; }
    ;
    const consumer =
        \\import type * as Shapes from "./shapes.js";
        \\type Processor<T> = (schema: T) => void;
        \\export const processor: Processor<Shapes.FileSchema> = (schema) => {
        \\  const { values: mime } = schema.internals.bag as Shapes.Internals["bag"];
        \\  if (mime) {
        \\    mime.map((value) => {
        \\      const exact: string = value;
        \\      const wrong: boolean = value;
        \\      return value;
        \\    });
        \\  }
        \\};
    ;
    try vfs.addFile("/proj/util.ts", util);
    try vfs.addFile("/proj/shapes.ts", shapes);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/util.ts", util);
    _ = try p.add("/proj/shapes.ts", shapes);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try expectCompilationHasDiagnosticCode(compilation, 2322);
}

test "Program: function schemas preserve readonly Record inputs and array results" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const util =
        \\export type Value = string | number;
        \\export type ValueMap = Readonly<Record<string, Value>>;
        \\export function values(entries: ValueMap): Value[] { void entries; return []; }
    ;
    const consumer =
        \\import { values } from "./util.js";
        \\values({}).every((value, index) => {
        \\  const exact: string | number = value;
        \\  const wrong: boolean = value;
        \\  return index >= 0;
        \\});
        \\values(1);
    ;
    try vfs.addFile("/proj/util.ts", util);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/util.ts", util);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try T.expectEqual(@as(usize, 2), compilation.diagnostics.items.len);
    try expectCompilationHasDiagnosticCode(compilation, 2322);
    try expectCompilationHasDiagnosticCode(compilation, 2345);
}

test "Program: local Record aliases do not use the built-in function schema" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const owner =
        \\type Record<K, V> = boolean;
        \\export function accepts(value: Record<string, number>): void { void value; }
    ;
    const consumer =
        \\import { accepts } from "./owner.js";
        \\accepts({});
        \\accepts(true);
    ;
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/owner.ts", owner);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try T.expectEqual(@as(usize, 1), compilation.diagnostics.items.len);
    try expectCompilationHasDiagnosticCode(compilation, 2345);
}

test "Program: qualified imported leaves retain contextual callback signatures" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const shapes =
        \\export interface Base { value: unknown; }
        \\export interface Context { nested: readonly [string]; }
        \\export interface Params { path: string[]; }
    ;
    const owner =
        \\import type * as Shapes from "./shapes.js";
        \\export type Processor<T extends Shapes.Base = Shapes.Base> =
        \\  (schema: T, context: Shapes.Context, params: Shapes.Params) => void;
    ;
    const consumer =
        \\import type { Processor } from "./owner.js";
        \\interface Schema { value: string; }
        \\export const processor: Processor<Schema> = (schema, context, params) => {
        \\  const value: string = schema.value;
        \\  const wrong: number = schema.value;
        \\  const path: string[] = params.path;
        \\  const wrongPath: number[] = params.path;
        \\  void value; void wrong; void path; void wrongPath; void context;
        \\};
    ;
    try vfs.addFile("/proj/shapes.ts", shapes);
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/shapes.ts", shapes);
    _ = try p.add("/proj/owner.ts", owner);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try T.expectEqual(@as(usize, 2), compilation.diagnostics.items.len);
    for (compilation.diagnostics.items) |diagnostic| try T.expectEqual(@as(u32, 2322), diagnostic.code);
}

test "Program: returned imported callable interfaces retain callback read contracts" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const owner =
        \\export interface IssueBase { readonly code?: string; readonly path: PropertyKey[]; readonly message: string; }
        \\export interface InvalidType extends IssueBase { readonly code: "invalid_type"; readonly expected: string; }
        \\export interface InvalidValue extends IssueBase { readonly code: "invalid_value"; readonly values: string[]; }
        \\export type Issue = InvalidType | InvalidValue;
        \\type MakePartial<T, K extends keyof T> = Omit<T, K> & Partial<Pick<T, K>>;
        \\type Flatten<T> = { [K in keyof T]: T[K] } & {};
        \\type InternalIssue<T extends IssueBase = Issue> = T extends any ? RawIssue<T> : never;
        \\type RawIssue<T extends IssueBase> = T extends any
        \\  ? Flatten<MakePartial<T, "message" | "path"> & { readonly input: unknown } & Record<string, unknown>>
        \\  : never;
        \\export interface ErrorMap<T extends IssueBase = Issue> {
        \\  (issue: InternalIssue<T>): { message: string } | string | undefined | null;
        \\}
    ;
    const consumer =
        \\import type * as errors from "./owner.js";
        \\import type { ErrorMap } from "./owner.js";
        \\export const qualified: () => errors.ErrorMap = () => (issue) => issue.code;
        \\export const direct: () => ErrorMap = () => (issue) => issue.code;
        \\export const missingProperty: () => ErrorMap = () => (issue) => issue.missing;
        \\export const wrongReturn: () => ErrorMap = () => (issue) => 42;
        \\function localShadow(): void {
        \\  interface ErrorMap { (value: number): number; }
        \\  const local: () => ErrorMap = () => (value) => value + 1;
        \\  void local;
        \\}
    ;
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/owner.ts", owner);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try T.expectEqual(@as(usize, 2), compilation.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2339), compilation.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2322), compilation.diagnostics.items[1].code);
}

test "Program: named imports preserve generic interface method context" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const owner =
        \\export interface Memoizer {
        \\  alloc<T extends object>(value: T, fallback: T): T;
        \\}
    ;
    const consumer =
        \\import type { Memoizer } from "./owner.js";
        \\const memo: Memoizer = {
        \\  alloc(value, fallback) { return value ?? fallback; },
        \\};
        \\const result = memo.alloc({ name: "ok" }, { name: "fallback" });
        \\const exact: string = result.name;
        \\const wrong: number = result.name;
        \\void exact; void wrong;
    ;
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/owner.ts", owner);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try T.expectEqual(@as(usize, 1), compilation.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2322), compilation.diagnostics.items[0].code);
}

test "Program: namespace imports preserve defaulted indexed generic callbacks" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver, .names_available = false };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const util =
        \\export abstract class Class { constructor(...args: any[]) { void args; } }
        \\export type ProtoOf<T> = {
        \\  [K in keyof T]?: (T[K] extends (...args: infer A) => infer R ? (...args: A) => R : T[K]) | undefined;
        \\} & ThisType<T>;
    ;
    const owner =
        \\import type { Class, ProtoOf } from "./util.js";
        \\type Trait = { _zod: { def: unknown; [key: string]: unknown } };
        \\interface ConstructorParams { Parent?: typeof Class }
        \\export interface ImportedBase<D> { _zod: { def: D }; inherited: string; }
        \\export interface $constructor<T extends Trait, D = T["_zod"]["def"]> {
        \\  new (def: D): T;
        \\  init(inst: T, def: D): asserts inst is T;
        \\}
        \\export function $constructor<T extends Trait, D = T["_zod"]["def"]>(
        \\  name: string,
        \\  initializer: (inst: T, def: D) => void,
        \\  proto?: ProtoOf<T>,
        \\  params?: ConstructorParams
        \\): $constructor<T, D> {
        \\  void name;
        \\  void initializer;
        \\  void proto;
        \\  void params;
        \\  return null as never;
        \\}
    ;
    const barrel = "export * from \"./owner.js\"; export * from \"./broken.js\";";
    const broken = "export const unrelated = ;";
    const consumer =
        \\import * as core from "./barrel.js";
        \\interface Schema extends core.ImportedBase<{ kind: "schema" }> {
        \\  clone(): this;
        \\  format(value: string): string;
        \\  partial(): number;
        \\  partial(mask: { key: string }): number;
        \\}
        \\core.$constructor<Schema>("Schema", (inst, def) => {
        \\  const exactInst: Schema = inst;
        \\  const exactDef: { kind: "schema" } = def;
        \\  void exactInst;
        \\  void exactDef;
        \\}, {
        \\  format(value) {
        \\    const exact: string = value;
        \\    const kind: "schema" = this._zod.def.kind;
        \\    return exact + kind + this.inherited;
        \\  },
        \\  partial(...args) {
        \\    const key: string = args[0].key;
        \\    return key.length + this._zod.def.kind.length;
        \\  },
        \\});
    ;
    const optional_proto_consumer =
        \\import * as core from "./barrel.js";
        \\interface Schema { _zod: { def: { kind: "schema" } } }
        \\core.$constructor<Schema>("Schema", () => {}, undefined);
    ;
    const invalid_optional_proto_consumer =
        \\import * as core from "./barrel.js";
        \\interface Schema { _zod: { def: { kind: "schema" } } }
        \\core.$constructor<Schema>("Schema", () => {}, null);
    ;
    const named_consumer =
        \\import { $constructor } from "./barrel";
        \\interface Schema { _zod: { def: { kind: "schema" } } }
        \\$constructor<Schema>("Schema", (inst, def) => {
        \\  const exactInst: Schema = inst;
        \\  const exactDef: { kind: "schema" } = def;
        \\  void exactInst;
        \\  void exactDef;
        \\});
    ;
    const contextual_consumer =
        \\import * as core from "./owner";
        \\interface Schema { _zod: { def: { kind: "schema" } } }
        \\export const SchemaConstructor: core.$constructor<Schema> = core.$constructor("Schema", (inst, def) => {
        \\  const exactInst: Schema = inst;
        \\  const exactDef: { kind: "schema" } = def;
        \\  void exactInst;
        \\  void exactDef;
        \\});
    ;
    const invalid_contextual_consumer =
        \\import * as core from "./owner";
        \\interface Schema { _zod: { def: { kind: "schema" } } }
        \\export const SchemaConstructor: core.$constructor<Schema> = core.$constructor("Schema", (inst, def) => {
        \\  const wrong: number = inst;
        \\  def.missing;
        \\  void wrong;
        \\});
    ;
    const invalid_proto_consumer =
        \\import * as core from "./owner";
        \\interface Schema { _zod: { def: { kind: "schema" } }; clone(): this; format(value: string): string; }
        \\core.$constructor<Schema>("Schema", () => {}, {
        \\  format(value) {
        \\    const wrong: number = value;
        \\    return value;
        \\  },
        \\});
    ;
    const direct_proto_consumer =
        \\import { $constructor } from "./barrel.js";
        \\interface Schema { _zod: { def: { kind: "schema" } }; clone(): this; format(value: string): string; }
        \\$constructor<Schema>("Schema", () => {}, {
        \\  format(value) { return value.length; },
        \\});
        \\function localShadow(): void {
        \\  function $constructor<T>(_name: string, callback: (value: number) => number): void { void callback; }
        \\  $constructor<Schema>("local", (value) => value + 1);
        \\}
        \\void localShadow;
    ;
    const plain_proto_consumer =
        \\import { $constructor } from "./barrel.js";
        \\interface Schema { _zod: { def: { kind: "schema" } }; format(value: string): string; }
        \\$constructor<Schema>("Schema", () => {}, {
        \\  format(value) { return value; },
        \\});
    ;
    const invalid_consumer =
        \\import * as core from "./owner";
        \\interface Schema { _zod: { def: { kind: "schema" } } }
        \\core.$constructor<Schema>("Schema", (inst, def) => {
        \\  const wrong: number = inst;
        \\  inst.missing;
        \\  void def;
        \\  void wrong;
        \\});
    ;
    try vfs.addFile("/proj/util.ts", util);
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/barrel.ts", barrel);
    try vfs.addFile("/proj/broken.ts", broken);
    try vfs.addFile("/proj/consumer.ts", consumer);
    try vfs.addFile("/proj/optional-proto-consumer.ts", optional_proto_consumer);
    try vfs.addFile("/proj/invalid-optional-proto-consumer.ts", invalid_optional_proto_consumer);
    try vfs.addFile("/proj/named-consumer.ts", named_consumer);
    try vfs.addFile("/proj/contextual-consumer.ts", contextual_consumer);
    try vfs.addFile("/proj/invalid-contextual-consumer.ts", invalid_contextual_consumer);
    try vfs.addFile("/proj/invalid-proto-consumer.ts", invalid_proto_consumer);
    try vfs.addFile("/proj/direct-proto-consumer.ts", direct_proto_consumer);
    try vfs.addFile("/proj/plain-proto-consumer.ts", plain_proto_consumer);
    try vfs.addFile("/proj/invalid-consumer.ts", invalid_consumer);
    _ = try p.add("/proj/util.ts", util);
    _ = try p.add("/proj/owner.ts", owner);
    _ = try p.add("/proj/barrel.ts", barrel);
    _ = try p.add("/proj/broken.ts", broken);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);
    const optional_proto_consumer_id = try p.add("/proj/optional-proto-consumer.ts", optional_proto_consumer);
    const invalid_optional_proto_consumer_id = try p.add("/proj/invalid-optional-proto-consumer.ts", invalid_optional_proto_consumer);
    const named_consumer_id = try p.add("/proj/named-consumer.ts", named_consumer);
    const contextual_consumer_id = try p.add("/proj/contextual-consumer.ts", contextual_consumer);
    const invalid_contextual_consumer_id = try p.add("/proj/invalid-contextual-consumer.ts", invalid_contextual_consumer);
    const invalid_proto_consumer_id = try p.add("/proj/invalid-proto-consumer.ts", invalid_proto_consumer);
    const direct_proto_consumer_id = try p.add("/proj/direct-proto-consumer.ts", direct_proto_consumer);
    const plain_proto_consumer_id = try p.add("/proj/plain-proto-consumer.ts", plain_proto_consumer);
    const invalid_consumer_id = try p.add("/proj/invalid-consumer.ts", invalid_consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    const optional_proto_compilation = p.fileById(optional_proto_consumer_id).compilation.?;
    const invalid_optional_proto_compilation = p.fileById(invalid_optional_proto_consumer_id).compilation.?;
    const named_compilation = p.fileById(named_consumer_id).compilation.?;
    const contextual_compilation = p.fileById(contextual_consumer_id).compilation.?;
    const invalid_contextual_compilation = p.fileById(invalid_contextual_consumer_id).compilation.?;
    const invalid_proto_compilation = p.fileById(invalid_proto_consumer_id).compilation.?;
    const direct_proto_compilation = p.fileById(direct_proto_consumer_id).compilation.?;
    const plain_proto_compilation = p.fileById(plain_proto_consumer_id).compilation.?;
    const invalid_compilation = p.fileById(invalid_consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(named_compilation, 7006);
    try expectCompilationLacksDiagnosticCode(named_compilation, 2322);
    try expectCompilationLacksDiagnosticCode(named_compilation, 2347);
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try expectCompilationLacksDiagnosticCode(compilation, 7019);
    try expectCompilationLacksDiagnosticCode(compilation, 2322);
    try expectCompilationLacksDiagnosticCode(compilation, 2339);
    try expectCompilationLacksDiagnosticCode(compilation, 2493);
    try expectCompilationLacksDiagnosticCode(compilation, 2347);
    try expectCompilationLacksDiagnosticCode(optional_proto_compilation, 2345);
    try expectCompilationHasDiagnosticCode(invalid_optional_proto_compilation, 2345);
    try expectCompilationLacksDiagnosticCode(contextual_compilation, 7006);
    try expectCompilationLacksDiagnosticCode(contextual_compilation, 2322);
    try expectCompilationLacksDiagnosticCode(contextual_compilation, 2347);
    try expectCompilationHasDiagnosticCode(invalid_contextual_compilation, 2322);
    try expectCompilationHasDiagnosticCode(invalid_contextual_compilation, 2339);
    try expectCompilationLacksDiagnosticCode(invalid_proto_compilation, 7006);
    try expectCompilationHasDiagnosticCode(invalid_proto_compilation, 2322);
    try expectCompilationLacksDiagnosticCode(direct_proto_compilation, 7006);
    try expectCompilationLacksDiagnosticCode(direct_proto_compilation, 2345);
    try expectCompilationHasDiagnosticCode(direct_proto_compilation, 2322);
    try expectCompilationLacksDiagnosticCode(plain_proto_compilation, 7006);
    try expectCompilationLacksDiagnosticCode(plain_proto_compilation, 2322);
    try expectCompilationLacksDiagnosticCode(plain_proto_compilation, 2345);
    try expectCompilationLacksDiagnosticCode(invalid_compilation, 7006);
    try expectCompilationHasDiagnosticCode(invalid_compilation, 2322);
    try expectCompilationHasDiagnosticCode(invalid_compilation, 2339);
}

test "Program: mapped prototype conditionals preserve optional generic and rest parameters" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const util =
        \\export type ProtoOf<T> = {
        \\  [K in keyof T]?: (T[K] extends (...args: infer A) => infer R ? (...args: A) => R : T[K]) | undefined;
        \\} & ThisType<T>;
    ;
    const owner =
        \\import type { ProtoOf } from "./util.js";
        \\type Trait = { _zod: { def: unknown; [key: string]: unknown } };
        \\export function $constructor<T extends Trait>(name: string, proto?: ProtoOf<T>): void {
        \\  void name;
        \\  void proto;
        \\}
    ;
    const barrel = "export * from \"./owner.js\";";
    const consumer =
        \\import * as core from "./barrel.js";
        \\interface Schema {
        \\  _zod: { def: { kind: "schema" } };
        \\  clone(def?: { kind: "schema" }, params?: { parent: boolean }): this;
        \\  register<R extends { add(value: Schema, meta: string): void }>(registry: R, ...meta: [string]): this;
        \\  check(...checks: (((value: string) => boolean) | { run(value: string): boolean })[]): this;
        \\  refine<C extends (value: string) => unknown>(check: C, params?: string): this;
        \\}
        \\core.$constructor<Schema>("Schema", {
        \\  clone(def, params) {
        \\    const exactDef: { kind: "schema" } | undefined = def;
        \\    const exactParent: boolean | undefined = params?.parent;
        \\    void exactDef; void exactParent;
        \\    return this;
        \\  },
        \\  register(registry, meta) {
        \\    registry.add(this, meta);
        \\    return this;
        \\  },
        \\  check(...checks) {
        \\    checks.map((check) => typeof check === "function" ? check("x") : check.run("x"));
        \\    return this;
        \\  },
        \\  refine(check, params) {
        \\    check(params ?? "x");
        \\    return this;
        \\  },
        \\});
        \\core.$constructor<Schema>("Invalid", {
        \\  clone(def) {
        \\    const wrong: number = def?.kind;
        \\    def?.missing;
        \\    void wrong;
        \\    return this;
        \\  },
        \\});
        \\function lexicalShadow(): void {
        \\  function $constructor<T>(_name: string, proto?: { refine(value: number): number }): void { void proto; }
        \\  $constructor<Schema>("local", { refine(value) { return value + 1; } });
        \\}
        \\void lexicalShadow;
    ;
    try vfs.addFile("/proj/util.ts", util);
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/barrel.ts", barrel);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/util.ts", util);
    _ = try p.add("/proj/owner.ts", owner);
    _ = try p.add("/proj/barrel.ts", barrel);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try expectCompilationLacksDiagnosticCode(compilation, 7019);
    try expectCompilationLacksDiagnosticCode(compilation, 2349);
    try T.expectEqual(@as(usize, 2), compilation.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2322), compilation.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2339), compilation.diagnostics.items[1].code);
}

test "Program: namespace imports preserve callbacks through inherited interfaces" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const owner =
        \\export interface Base<T> { value: T }
        \\export interface Derived<T> extends Base<T> { enabled: boolean }
        \\export function consume<T>(value: Derived<T>, callback: (item: T) => void): void {
        \\  callback(value.value);
        \\}
    ;
    const consumer =
        \\import * as api from "./owner";
        \\api.consume<number>({ value: 1, enabled: true }, item => {
        \\  const exact: number = item;
        \\  void exact;
        \\});
    ;
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/consumer.ts", consumer);
    _ = try p.add("/proj/owner.ts", owner);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 2339);
    try expectCompilationLacksDiagnosticCode(compilation, 7006);
    try expectCompilationLacksDiagnosticCode(compilation, 2322);
}

test "Program: named imports preserve generic interfaces with built-in Error heritage" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var checker_resolver = NamespaceImportTestResolver{ .resolver = &resolver };
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const owner =
        \\export interface BaseError<T = unknown> extends Error {
        \\  type: T;
        \\  issues: string[];
        \\}
    ;
    const consumer =
        \\import type { BaseError } from "./owner.js";
        \\interface DerivedError<T = unknown> extends BaseError<T> { format(): string; }
        \\declare const error: DerivedError<number>;
        \\const issue: string = error.issues[0];
        \\const message: string = error.name + error.message;
        \\const value: string = error.type.toFixed() + error.format();
        \\void issue; void message; void value;
    ;
    const invalid =
        \\import type { BaseError } from "./owner.js";
        \\interface DerivedError<T = unknown> extends BaseError<T> { format(): string; }
        \\declare const error: DerivedError<number>;
        \\const wrong: string = error.type;
        \\error.missing;
        \\void wrong;
    ;
    try vfs.addFile("/proj/owner.ts", owner);
    try vfs.addFile("/proj/consumer.ts", consumer);
    try vfs.addFile("/proj/invalid.ts", invalid);
    _ = try p.add("/proj/owner.ts", owner);
    const consumer_id = try p.add("/proj/consumer.ts", consumer);
    const invalid_id = try p.add("/proj/invalid.ts", invalid);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
        .external_resolver = .{ .ptr = &checker_resolver, .vtable = &NamespaceImportTestResolver.vtable },
    });
    const compilation = p.fileById(consumer_id).compilation.?;
    const invalid_compilation = p.fileById(invalid_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 2304);
    try expectCompilationLacksDiagnosticCode(compilation, 2339);
    try expectCompilationHasDiagnosticCode(invalid_compilation, 2322);
    try expectCompilationHasDiagnosticCode(invalid_compilation, 2339);
}

test "Program: relative module augmentation summary adds methods to imported class" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    _ = try p.add("/proj/a.ts",
        \\export class A {}
    );
    _ = try p.add("/proj/b.ts",
        \\export class B { value = 1; }
    );
    _ = try p.add("/proj/c.ts",
        \\export class Cls { ok = true; }
    );
    const d_id = try p.add("/proj/d.ts",
        \\import { A } from "./a";
        \\import { B } from "./b";
        \\A.prototype.getB = function() { return undefined; };
        \\declare module "./a" {
        \\  interface A {
        \\    getB(): B;
        \\  }
        \\}
    );
    const e_id = try p.add("/proj/e.ts",
        \\import { A } from "./a";
        \\import { Cls } from "./c";
        \\A.prototype.getCls = function() { return undefined; };
        \\declare module "./a" {
        \\  interface A {
        \\    getCls(): Cls;
        \\  }
        \\}
    );
    const main_id = try p.add("/proj/main.ts",
        \\import { A } from "./a";
        \\import "./d";
        \\import "./e";
        \\const a = new A();
        \\a.getB().value;
        \\a.getCls().ok;
    );

    const options: ts_driver.CompileOptions = .{ .no_emit = true };
    _ = try p.loadImportClosure(options);
    try p.recompileAll(options);
    const d_c = p.fileById(d_id).compilation.?;
    const e_c = p.fileById(e_id).compilation.?;
    const main_c = p.fileById(main_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(d_c, 2339);
    try expectCompilationLacksDiagnosticCode(e_c, 2339);
    try expectCompilationLacksDiagnosticCode(main_c, 2339);
}

test "Program: relative module augmentation merges namespace static members" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const map_id = try p.add("/proj/map.ts",
        \\import { Observable } from "./observable";
        \\(<any>Observable.prototype).map = function() { };
        \\declare module "./observable" {
        \\  interface Observable<T> {
        \\    map<U>(proj: (e: T) => U): Observable<U>;
        \\  }
        \\  namespace Observable {
        \\    let someAnotherValue: string;
        \\  }
        \\}
    );
    _ = try p.add("/proj/observable.ts",
        \\export declare class Observable<T> {
        \\  filter(pred: (e: T) => boolean): Observable<T>;
        \\}
        \\export namespace Observable {
        \\  export let someValue: number;
        \\}
    );
    const main_id = try p.add("/proj/main.ts",
        \\import { Observable } from "./observable";
        \\import "./map";
        \\declare const x: Observable<number>;
        \\let y = x.map(x => x + 1);
        \\let z1 = Observable.someValue.toFixed();
        \\let z2 = Observable.someAnotherValue.toLowerCase();
    );

    const augmentations = try p.collectRelativeModuleInterfaceAugmentations();
    defer p.gpa.free(augmentations);
    try T.expectEqual(@as(usize, 1), augmentations.len);
    try T.expectEqual(@as(?u16, 0), augmentations[0].callback_parameter_type_param_index);
    try T.expectEqualStrings("U", augmentations[0].method_type_parameter_name);

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{ .no_implicit_any = true, .strict_null_checks = true },
    });
    const map_c = p.fileById(map_id).compilation.?;
    const main_c = p.fileById(main_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(map_c, 2449);
    try expectCompilationLacksDiagnosticCode(main_c, 2339);
    try expectCompilationLacksDiagnosticCode(main_c, 7006);
    try expectCompilationLacksDiagnosticCode(main_c, 2345);
}

test "Program: namespace interface augmentation merges through star reexport" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    _ = try p.add("/proj/file.ts",
        \\export namespace Root {
        \\  export interface Foo { x: number; }
        \\}
    );
    _ = try p.add("/proj/reexport.ts",
        \\export * from "./file";
    );
    const augment_id = try p.add("/proj/augment.ts",
        \\import * as ns from "./reexport";
        \\declare module "./reexport" {
        \\  export namespace Root {
        \\    export interface Foo { self: Foo; }
        \\  }
        \\}
        \\declare const f: ns.Root.Foo;
        \\f.x;
        \\f.self;
        \\f.self.x;
        \\f.self.self;
    );

    try p.compileAll(.{ .no_emit = true });
    try expectCompilationLacksDiagnosticCode(p.fileById(augment_id).compilation.?, 2339);
}

test "Program: reverse mapped inference changes union arms for the same source" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const main_id = try p.add("/proj/main.ts",
        \\type Action<T extends string = string> = { type: T };
        \\interface UnknownAction extends Action { [extraProps: string]: unknown }
        \\type Reducer<S = any, A extends Action = UnknownAction> = (state: S | undefined, action: A) => S;
        \\type ReducersMapObject<S = any, A extends Action = UnknownAction> = { [K in keyof S]: Reducer<S[K], A> };
        \\interface ConfigureStoreOptions<S = any, A extends Action = UnknownAction> {
        \\  reducer: Reducer<S, A> | ReducersMapObject<S, A>;
        \\}
        \\declare function configureStore<S = any, A extends Action = UnknownAction>(options: ConfigureStoreOptions<S, A>): void;
        \\{
        \\  const reducer: Reducer<number> = () => 0;
        \\  const store1 = configureStore({ reducer });
        \\}
        \\const counterReducer1: Reducer<number> = () => 0;
        \\const store2 = configureStore({ reducer: { counter1: counterReducer1 } });
        \\export {};
    );

    try p.compileAll(.{
        .no_emit = true,
        .strict_flags = .{
            .no_implicit_any = true,
            .no_implicit_this = true,
            .strict_function_types = true,
            .strict_bind_call_apply = true,
            .strict_null_checks = true,
            .strict_property_initialization = true,
        },
    });
    try expectCompilationLacksDiagnosticCode(p.fileById(main_id).compilation.?, 2322);
}

test "Program: inferred tuple keys instantiate mapped generic returns across program globals" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(),
        \\{"compilerOptions":{"strict":true,"noEmit":true,"noLib":true,"skipLibCheck":true,"pretty":false}}
    );
    cfg.file_path = "/proj/tsconfig.json";
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    const main_id = try p.add("/proj/main.ts",
        \\interface Entity<N extends number> {
        \\  readonly id: N;
        \\  readonly label: `entity-${N}`;
        \\  readonly active: boolean;
        \\}
        \\type PickFields<T, K extends keyof T> = { readonly [P in K]: T[P] };
        \\declare function project<T, K extends readonly (keyof T)[]>(value: T, keys: K): PickFields<T, K[number]>;
        \\declare function field<T, K extends keyof T>(value: T, key: K): T[K];
        \\const entity: Entity<1> = { id: 1, label: "entity-1", active: true };
        \\const selected = project(entity, ["id", "label"] as const);
        \\const label: "entity-1" = field(selected, "label");
    );
    _ = try p.add("/proj/lib.d.ts",
        \\interface Object {}
        \\interface Function {}
        \\interface CallableFunction extends Function {}
        \\interface NewableFunction extends Function {}
        \\interface IArguments { readonly length: number; [index: number]: unknown; }
        \\interface String {}
        \\interface Number {}
        \\interface Boolean {}
        \\interface RegExp {}
        \\interface Array<T> { readonly length: number; [index: number]: T; }
        \\interface ReadonlyArray<T> { readonly length: number; readonly [index: number]: T; }
    );

    const callback = struct {
        fn call(_: void, _: []const u8, _: []const ts_driver.Diagnostic) void {}
    }.call;
    var options = ts_driver.optionsFromConfig(&cfg);
    options.no_emit = true;
    _ = try p.loadImportClosureParallel(options, null);
    try p.compileAllStreaming(options, {}, callback);
    const compilation = p.fileById(main_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(compilation, 2322);
    try expectCompilationLacksDiagnosticCode(compilation, 2345);
}

test "Program: relative module augmentation preserves missing member diagnostic" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    _ = try p.add("/proj/a.ts",
        \\export class B {}
        \\export class A {}
    );
    _ = try p.add("/proj/augment.ts",
        \\import { A, B } from "./a";
        \\export {};
        \\declare module "./a" {
        \\  interface A {
        \\    getB(): B;
        \\  }
        \\}
        \\A.prototype.getB = function() { return new B(); };
    );
    const bad_id = try p.add("/proj/bad.ts",
        \\import { A } from "./a";
        \\import "./augment";
        \\const a = new A();
        \\a.missing();
    );

    try p.compileAll(.{ .no_emit = true });
    const bad_c = p.fileById(bad_id).compilation.?;
    try expectCompilationHasDiagnosticCode(bad_c, 2339);
}

test "Program: relative module augmentation checks imported class return type" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();

    _ = try p.add("/proj/a.ts",
        \\export class A {}
    );
    _ = try p.add("/proj/b.ts",
        \\export class B { value = 1; }
    );
    const augment_id = try p.add("/proj/augment.ts",
        \\import { A } from "./a";
        \\import { B } from "./b";
        \\export {};
        \\declare module "./a" {
        \\  interface A {
        \\    getB(): B;
        \\  }
        \\}
        \\A.prototype.getB = function() { return "wrong"; };
    );

    try p.compileAll(.{ .no_emit = true });
    const augment_c = p.fileById(augment_id).compilation.?;
    try expectCompilationHasDiagnosticCode(augment_c, 2322);
    try expectCompilationLacksDiagnosticCode(augment_c, 2339);
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

test "prepared module local import facts retain declarations aliases and scope" {
    const compilation = try compileModuleForExportFacts(
        T.allocator,
        "/owner.ts",
        \\const hidden = 1;
        \\interface Shape { value: number }
        \\import { source as imported } from "./source";
        \\const { picked } = { picked: 1 };
        \\function wrapper() { const nested = 1; }
        \\export { hidden as public };
        \\export const visible = 1;
        ,
    );
    defer {
        compilation.deinit();
        T.allocator.destroy(compilation);
    }

    const hidden = moduleLocalImportFactsFromCompilation(compilation, "hidden");
    try T.expect(hidden.declares_local);
    try T.expectEqualStrings("public", hidden.exported_as);
    try T.expect(moduleLocalImportFactsFromCompilation(compilation, "Shape").declares_local);
    try T.expect(moduleLocalImportFactsFromCompilation(compilation, "imported").declares_local);
    try T.expect(moduleLocalImportFactsFromCompilation(compilation, "picked").declares_local);
    try T.expect(moduleLocalImportFactsFromCompilation(compilation, "visible").declares_local);
    try T.expect(!moduleLocalImportFactsFromCompilation(compilation, "nested").declares_local);
    try T.expect(!moduleLocalImportFactsFromCompilation(compilation, "missing").declares_local);
}

test "prepared barrel local import facts do not inherit hidden leaf declarations" {
    const compilation = try compileModuleForExportFacts(T.allocator, "/barrel.ts", "export * from './leaf';");
    defer {
        compilation.deinit();
        T.allocator.destroy(compilation);
    }
    try T.expect(!moduleLocalImportFactsFromCompilation(compilation, "hidden").declares_local);
}

test "prepared module local import facts never reopen source or check the owner" {
    const compilation = try compileModuleForExportFacts(
        T.allocator,
        "/owner.ts",
        "const hidden = 1; export { hidden as public };",
    );
    defer {
        compilation.deinit();
        T.allocator.destroy(compilation);
    }
    const node_count = compilation.hir.nodeCount();
    const type_count = compilation.type_interner.pool.typeCount();
    const diagnostics = compilation.diagnostics.items.len;
    compilation.source = "";
    for (0..128) |_| {
        const facts = moduleLocalImportFactsFromCompilation(compilation, "hidden");
        try T.expect(facts.declares_local);
        try T.expectEqualStrings("public", facts.exported_as);
    }
    try T.expectEqual(node_count, compilation.hir.nodeCount());
    try T.expectEqual(type_count, compilation.type_interner.pool.typeCount());
    try T.expectEqual(diagnostics, compilation.diagnostics.items.len);
    try T.expect(!compilation.checked_types_ready);
}

test "ambientModuleExportFacts distinguishes a missing wildcard export" {
    const source =
        \\declare module "*.foo" {
        \\  let everywhere: string;
        \\}
    ;
    const exported = ambientModuleExportFacts(T.allocator, source, "a.foo", "everywhere", false).?;
    try T.expect(exported.exported_value);

    const missing = ambientModuleExportFacts(T.allocator, source, "b.foo", "onlyInA", false).?;
    try T.expect(!missing.exported_type);
    try T.expect(!missing.exported_value);

    const type_source =
        \\declare module "*.foo" {
        \\  export interface OhNo { star: string }
        \\}
    ;
    const exported_type = ambientModuleExportFacts(T.allocator, type_source, "b.foo", "OhNo", false).?;
    try T.expect(exported_type.exported_type);
}

test "ambientModuleExportFacts keeps exported interfaces out of value space" {
    const source =
        \\declare module "fs" {
        \\  export interface WriteFileOptions {}
        \\  export function writeFile(path: string): void;
        \\}
    ;
    const interface_facts = ambientModuleExportFacts(T.allocator, source, "fs", "WriteFileOptions", false).?;
    try T.expect(interface_facts.exported_type);
    try T.expect(!interface_facts.exported_value);

    const function_facts = ambientModuleExportFacts(T.allocator, source, "fs", "writeFile", false).?;
    try T.expect(!function_facts.exported_type);
    try T.expect(function_facts.exported_value);
}

test "ambient export assignment projects declared global value members" {
    const source =
        \\declare module "node:console" {
        \\  global {
        \\    interface Console { Console: console.ConsoleConstructor; }
        \\    namespace console { interface ConsoleConstructor { new (): Console; } }
        \\    var console: Console;
        \\  }
        \\  export = globalThis.console;
        \\}
    ;
    const facts = ambientModuleExportFacts(T.allocator, source, "node:console", "Console", false).?;
    try T.expect(facts.exported_value);
}

test "ambient export assignment projects qualified namespace values" {
    const source =
        \\declare module "nested" {
        \\  namespace a1.a2 { class d {} }
        \\  namespace a1.a2.n3 { class c {} }
        \\  export = a1.a2;
        \\}
        \\declare module "renamed" {
        \\  namespace a.b { class c {} }
        \\  import d = a.b;
        \\  export = d;
        \\}
    ;
    try T.expect(ambientModuleExportFacts(T.allocator, source, "nested", "d", false).?.exported_value);
    try T.expect(ambientModuleExportFacts(T.allocator, source, "nested", "n3", false).?.exported_value);
    try T.expect(ambientModuleExportFacts(T.allocator, source, "renamed", "c", false).?.exported_value);
    try T.expect(!ambientModuleExportFacts(T.allocator, source, "nested", "missing", false).?.exported_value);
}

test "module export facts follow explicit typesVersions back-references" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/ext/index.d.ts", "export function fa(): void;");
    try vfs.addFile("/node_modules/ext/other.d.ts", "export function fb(): void;");
    try vfs.addFile("/node_modules/ext/ts3.1/index.d.ts", "export * from \"../\";");
    try vfs.addFile("/node_modules/ext/ts3.1/other.d.ts", "export * from \"../other\";");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();

    const subpath = moduleExportFactsFromResolvedModule(
        T.allocator,
        &resolver,
        "/node_modules/ext/ts3.1/other.d.ts",
        "fb",
    );
    try T.expect(subpath.exported_value);

    const entry = moduleExportFactsFromResolvedModule(
        T.allocator,
        &resolver,
        "/node_modules/ext/ts3.1/index.d.ts",
        "fa",
    );
    try T.expect(!entry.exported_type);
    try T.expect(!entry.exported_value);
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

test "moduleExportsValueSpaceName: CommonJS void exports stay absent" {
    const source =
        \\exports.j = 1;
        \\exports.k = void 0;
        \\module.exports.m = "ok";
        \\module.exports["n"] = true;
    ;
    try T.expect(moduleExportsValueSpaceName(T.allocator, source, "j", false));
    try T.expect(!moduleExportsValueSpaceName(T.allocator, source, "k", false));
    try T.expect(moduleExportsValueSpaceName(T.allocator, source, "m", false));
    try T.expect(moduleExportsValueSpaceName(T.allocator, source, "n", false));
}

test "module export facts expose only the public side of renamed value exports" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/owner.ts", "const hidden = 1; export { hidden as public };");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();

    const hidden = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/owner.ts", "hidden");
    const public = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/owner.ts", "public");
    try T.expect(!hidden.exported_value);
    try T.expect(public.exported_value);
}

test "module export facts expose non-void CommonJS properties" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile(
        "/assignmentToVoidZero2.js",
        "exports.j = 1;\nexports.k = void 0;\n",
    );
    try vfs.addFile(
        "/importer.js",
        "// @checkJs: true\nimport { j, k } from './assignmentToVoidZero2';\n",
    );
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .out_dir = "auss" });
    defer resolver.deinit();
    const resolution = try resolver.resolve("./assignmentToVoidZero2", "/importer.js");
    try T.expectEqualStrings("/assignmentToVoidZero2.js", resolution.path);

    const exported = moduleExportFactsFromResolvedModule(
        T.allocator,
        &resolver,
        resolution.path,
        "j",
    );
    const absent = moduleExportFactsFromResolvedModule(
        T.allocator,
        &resolver,
        resolution.path,
        "k",
    );
    try T.expect(exported.exported_value);
    try T.expect(!absent.exported_value);
}

test "module export facts preserve CommonJS defineProperty readonly descriptors" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/mod.js",
        \\Object.defineProperty(exports, "writable", { value: 1, writable: true });
        \\Object.defineProperty(exports, "fixed", { value: 1, writable: false });
        \\Object.defineProperty(module.exports, "getter", { get() { return 1; } });
        \\Object.defineProperty(module.exports, "setter", { set(value) {} });
        \\Object.defineProperty(module.exports, "invalid", { writable: true });
    );
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();

    const writable = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/mod.js", "writable");
    const fixed = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/mod.js", "fixed");
    const getter = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/mod.js", "getter");
    const setter = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/mod.js", "setter");
    const invalid = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/mod.js", "invalid");
    try T.expect(writable.exported_value and !writable.exported_value_readonly);
    try T.expect(fixed.exported_value and fixed.exported_value_readonly);
    try T.expect(getter.exported_value and getter.exported_value_readonly);
    try T.expect(setter.exported_value and !setter.exported_value_readonly);
    try T.expect(invalid.exported_value and invalid.exported_value_readonly);
}

test "CommonJS class display query uses prepared syntax and bound aliases" {
    const sources = [_][]const u8{
        "class Service {} module.exports = new Service();",
        "class Service {} module['exports'] = (new Service());",
        "class Service {} const Alias = Service; const Selected = Alias; module.exports = new Selected();",
        "class Service {} /* module.exports = new Fake(); */ module.exports = new Service();",
        "class Service {} const note = 'module.exports = new Fake()'; module.exports = new Service();",
        "class Service {} function later() { module.exports = new Service(); }",
    };
    for (sources) |source| {
        const compilation = try compileModuleForExportFacts(T.allocator, "/owner.js", source);
        defer {
            compilation.deinit();
            T.allocator.destroy(compilation);
        }
        try T.expectEqualStrings("Service", moduleCommonJsExportAssignmentClassNameFromCompilation(compilation).?);
        try T.expect(!compilation.checked_types_ready);
        const name = moduleCommonJsExportAssignmentClassName(T.allocator, source, false).?;
        defer T.allocator.free(name);
        try T.expectEqualStrings("Service", name);
    }
}

test "CommonJS class display query does not invent names or flatten reassignment" {
    const sources = [_][]const u8{
        "// module.exports = new Fake();",
        "const note = 'module.exports = new Fake()';",
        "module.exports = new Missing();",
        "function Factory() {} module.exports = new Factory();",
        "class Service {} const module = { exports: {} }; module.exports = new Service();",
        "class Service {} function local(module) { module.exports = new Service(); }",
        "class Service {} function local() { const module = { exports: {} }; module.exports = new Service(); }",
        "class Service {} module.exports = new Service(); module.exports = {};",
        "class Service {} module.exports = {}; module.exports = new Service();",
        "class Service {} class Other {} module.exports = new Service(); module.exports = new Other();",
        "class Service {} module.exports = new Service(); module.exports = new Service();",
        "const A = B; const B = A; module.exports = new A();",
        "class Service {} function local(Service) { module.exports = new Service(); }",
        "class Service {} module.exports += new Service();",
    };
    for (sources) |source| {
        const compilation = try compileModuleForExportFacts(T.allocator, "/owner.js", source);
        defer {
            compilation.deinit();
            T.allocator.destroy(compilation);
        }
        try T.expectEqual(@as(?[]const u8, null), moduleCommonJsExportAssignmentClassNameFromCompilation(compilation));
    }
}

test "CommonJS prepared class query never reopens source or checks its owner" {
    const compilation = try compileModuleForExportFacts(T.allocator, "/owner.js", "class Service {} module.exports = new Service();");
    defer {
        compilation.deinit();
        T.allocator.destroy(compilation);
    }
    const node_count = compilation.hir.nodeCount();
    const type_count = compilation.type_interner.pool.typeCount();
    const diagnostics = compilation.diagnostics.items.len;
    // Once parsed, the query must depend only on immutable owner syntax and
    // bindings, even if its source view is unavailable to a reparser.
    compilation.source = "";
    for (0..128) |_| {
        try T.expectEqualStrings("Service", moduleCommonJsExportAssignmentClassNameFromCompilation(compilation).?);
    }
    try T.expectEqual(node_count, compilation.hir.nodeCount());
    try T.expectEqual(type_count, compilation.type_interner.pool.typeCount());
    try T.expectEqual(diagnostics, compilation.diagnostics.items.len);
    try T.expect(!compilation.checked_types_ready);
}

test "module export facts distinguish scripts from external modules" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/script.js", "/** @typedef {string} A */\n");
    try vfs.addFile("/esm.js", "export const value = 1;\n");
    try vfs.addFile("/commonjs.js", "module.exports = {};\n");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();

    const script = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/script.js", "");
    const esm = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/esm.js", "");
    const commonjs = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/commonjs.js", "");
    try T.expect(!script.module_is_external);
    try T.expect(esm.module_is_external);
    try T.expect(commonjs.module_is_external);
}

test "module export facts preserve default and export assignment shapes" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/esm.js", "export const x = 0; module.exports.y = 0;\n");
    try vfs.addFile("/default.ts", "export default 0;\n");
    try vfs.addFile("/object.ts", "export = { default: function() {} };\n");
    try vfs.addFile("/callable.ts", "export = function() {};\n");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();

    try T.expect(moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/esm.js", "x").exported_value);
    try T.expect(!moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/esm.js", "y").exported_value);
    try T.expect(moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/default.ts", "default").exported_value);
    try T.expect(moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/object.ts", "default").exported_value);
    try T.expect(moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/callable.ts", "").call_only_function);
}

test "module export facts follow named reexports and destructured bindings" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/node_modules/pkg/package.json", "{\"name\":\"pkg\",\"version\":\"1.0.0\",\"types\":\"index.d.ts\"}");
    try vfs.addFile("/node_modules/pkg/index.d.ts", "export class Foo { private x; }");
    try vfs.addFile("/reexport.d.ts", "export { Foo } from 'pkg';");
    try vfs.addFile("/local.ts", "const source = { bar() {} }; const { bar } = source; export { bar };");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();

    const named = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/reexport.d.ts", "Foo");
    const destructured = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/local.ts", "bar");
    try T.expect(named.exported_type);
    try T.expect(named.exported_value);
    try T.expect(destructured.exported_value);
}

test "module export facts retain namespace alias meaning" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/a.ts", "export class A {}");
    try vfs.addFile("/type.ts", "export type * as ns from './a';");
    try vfs.addFile("/value.ts", "export * as ns from './a';");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();

    const type_only = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/type.ts", "ns");
    try T.expect(type_only.exported_type);
    try T.expect(!type_only.exported_value);
    try T.expect(type_only.type_only_pos != null);

    const value = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/value.ts", "ns");
    try T.expect(value.exported_type);
    try T.expect(value.exported_value);
    try T.expect(value.type_only_pos == null);
}

test "module export facts project export-assignment namespace members" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile(
        "/foo.ts",
        "namespace M { export const Y = 1; } export = M;",
    );
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();

    const exported = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/foo.ts", "Y");
    const missing = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/foo.ts", "X");
    try T.expect(exported.exported_value);
    try T.expect(!missing.exported_value);
}

test "module export facts preserve generic function exports through reexports" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile(
        "/node_modules/lib/index.d.ts",
        "export declare function createService<T>(): T; export declare function plain(): void;",
    );
    try vfs.addFile("/reexport.d.ts", "export { createService } from 'lib';");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();

    const generic = moduleExportFactsFromResolvedModule(
        T.allocator,
        &resolver,
        "/node_modules/lib/index.d.ts",
        "createService",
    );
    const plain = moduleExportFactsFromResolvedModule(
        T.allocator,
        &resolver,
        "/node_modules/lib/index.d.ts",
        "plain",
    );
    const reexport = moduleExportFactsFromResolvedModule(
        T.allocator,
        &resolver,
        "/reexport.d.ts",
        "createService",
    );
    try T.expect(generic.generic_function);
    try T.expect(!plain.generic_function);
    try T.expect(reexport.generic_function);
}

test "module export facts parse JSX-bearing JavaScript modules" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/component.js", "export const C = () => <div />;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    const facts = moduleExportFactsFromResolvedModule(T.allocator, &resolver, "/component.js", "C");
    try T.expect(facts.exported_value);
}

test "Program: qualified JSDoc typedef metadata stays separate from value expandos" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/types.js",
        \\const myTypes = {};
        \\/** @typedef {string} myTypes.typeA */
        \\/**
        \\ * @typedef myTypes.typeB
        \\ * @property {myTypes.typeA} prop
        \\ */
        \\myTypes.Value = class {};
    );

    const expandos = try p.collectScriptObjectExpandos();
    defer T.allocator.free(expandos);
    try T.expectEqual(@as(usize, 3), expandos.len);
    for (expandos) |expando| {
        if (std.mem.eql(u8, expando.member, "Value")) {
            try T.expect(expando.has_value);
            try T.expect(!expando.has_jsdoc_typedef);
        } else {
            try T.expect(!expando.has_value);
            try T.expect(expando.has_jsdoc_typedef);
        }
    }
}

test "Program: collects CommonJS exports assigned void" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile(
        "/assignmentToVoidZero2.js",
        "exports.j = 1;\nexports.k = void 0;\n",
    );
    try vfs.addFile(
        "/importer.js",
        "import { j, k } from './assignmentToVoidZero2';\n",
    );
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .out_dir = "auss" });
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add(
        "/assignmentToVoidZero2.js",
        "exports.j = 1;\nexports.k = void 0;\n",
    );
    _ = try p.add(
        "/importer.js",
        "// @checkJs: true\nimport { j, k } from './assignmentToVoidZero2';\n",
    );

    const exports = try p.collectProgramCommonJsExports();
    defer Program.freeProgramCommonJsExports(T.allocator, exports);
    var saw_j = false;
    var saw_k = false;
    for (exports) |item| {
        if (!std.mem.eql(u8, item.module_path, "/assignmentToVoidZero2.js")) continue;
        if (std.mem.eql(u8, item.name, "j")) saw_j = true;
        if (std.mem.eql(u8, item.name, "k")) saw_k = true;
    }
    try T.expect(saw_j);
    try T.expect(saw_k);
}

test "Program: records whole CommonJS export assignments" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/mod.js", "function C() {}\nexports = module.exports = C;\nexports.f = 1;\n");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/mod.js", "function C() {}\nexports = module.exports = C;\nexports.f = 1;\n");

    const exports = try p.collectProgramCommonJsExports();
    defer Program.freeProgramCommonJsExports(T.allocator, exports);
    var saw_whole = false;
    var saw_f = false;
    for (exports) |item| {
        if (!std.mem.eql(u8, item.module_path, "/mod.js")) continue;
        if (item.name.len == 0) saw_whole = true;
        if (std.mem.eql(u8, item.name, "f")) saw_f = true;
    }
    try T.expect(saw_whole);
    try T.expect(saw_f);
}

test "Program: excludes CommonJS expandos from ESM export tables" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/mod.js", "export const x = 0; module.exports.y = 0;\n");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/mod.js", "export const x = 0; module.exports.y = 0;\n");

    const exports = try p.collectProgramCommonJsExports();
    defer Program.freeProgramCommonJsExports(T.allocator, exports);
    try T.expectEqual(@as(usize, 0), exports.len);
}

test "Program: collects private export-assignment declaration types" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile(
        "/node_modules/@types/pkg/index.d.ts",
        "interface Private {}\ndeclare const obj: { fn(x: Private): void };\nexport = obj;\n",
    );
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add(
        "/node_modules/@types/pkg/index.d.ts",
        "interface Private {}\ndeclare const obj: { fn(x: Private): void };\nexport = obj;\n",
    );

    const exports = try p.collectProgramCommonJsExports();
    defer Program.freeProgramCommonJsExports(T.allocator, exports);
    try T.expectEqual(@as(usize, 1), exports.len);
    try T.expectEqualStrings("Private", exports[0].private_type_name);
    try T.expectEqualStrings("\"/node_modules/@types/pkg/index\"", exports[0].private_module_name);
}

test "Program: records any-typed declaration export assignments" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile(
        "/node_modules/@types/process/process.d.ts",
        "declare const thing: any;\nexport = thing;\n",
    );
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add(
        "/node_modules/@types/process/process.d.ts",
        "declare const thing: any;\nexport = thing;\n",
    );

    const exports = try p.collectProgramCommonJsExports();
    defer Program.freeProgramCommonJsExports(T.allocator, exports);
    try T.expectEqual(@as(usize, 1), exports.len);
    try T.expect(exports[0].whole_export_is_any);
    try T.expectEqualStrings("", exports[0].private_type_name);
}

test "Program: global interface property and method declarations collide across files" {
    const file1_source =
        \\interface TopLevel {
        \\    duplicate1: () => string;
        \\    duplicate2: () => string;
        \\    duplicate3: () => string;
        \\}
    ;
    const file2_source =
        \\interface TopLevel {
        \\    duplicate1(): number;
        \\    duplicate2(): number;
        \\    duplicate3(): number;
        \\}
    ;
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/file1.ts", file1_source);
    try vfs.addFile("/file2.ts", file2_source);
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    const file1_id = try p.add("/file1.ts", file1_source);
    const file2_id = try p.add("/file2.ts", file2_source);

    try p.compileAll(.{ .no_emit = true });
    for ([_]FileId{ file1_id, file2_id }) |file_id| {
        const compilation = p.fileById(file_id).compilation.?;
        var duplicate_count: usize = 0;
        for (compilation.diagnostics.items) |diagnostic| {
            if (diagnostic.code != 2300) continue;
            duplicate_count += 1;
            try T.expectEqual(@as(usize, 1), diagnostic.related.len);
            try T.expectEqual(@as(u32, 6203), diagnostic.related[0].code);
            try T.expect(diagnostic.related[0].file != null);
        }
        try T.expectEqual(@as(usize, 3), duplicate_count);
    }
}

test "Program: checked JS classifies ambient interface imports and re-exports as types" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var p = Program.init(T.allocator, &resolver);
    defer p.deinit();
    _ = try p.add("/node_modules/@types/node/index.d.ts",
        \\declare module "fs" {
        \\  export interface WriteFileOptions {}
        \\  export function writeFile(path: string): void;
        \\}
    );
    const js_id = try p.add("/index.js",
        \\// @checkJs: true
        \\import { writeFile, WriteFileOptions, WriteFileOptions as OtherName } from "fs";
        \\export { WriteFileOptions };
    );

    try p.compileAll(.{ .allow_js = true, .no_emit = true });
    const compilation = p.fileById(js_id).compilation.?;
    var import_type_count: usize = 0;
    var export_type_count: usize = 0;
    for (compilation.diagnostics.items) |diagnostic| {
        if (diagnostic.code == 18042) import_type_count += 1;
        if (diagnostic.code == 18043) export_type_count += 1;
    }
    try T.expectEqual(@as(usize, 2), import_type_count);
    try T.expectEqual(@as(usize, 1), export_type_count);
}

test "moduleExportsValueSpaceName: exported value-space names exclude interfaces and aliases" {
    try T.expect(moduleExportsValueSpaceName(T.allocator, "export class C {}", "C", false));
    try T.expect(moduleExportsValueSpaceName(T.allocator, "export enum E { A }", "E", false));
    try T.expect(moduleExportsValueSpaceName(T.allocator, "export const v = 1;", "v", false));
    try T.expect(moduleExportsValueSpaceName(T.allocator, "export function f() {}", "f", false));
    try T.expect(moduleExportsValueSpaceName(T.allocator, "const A = {}; export { A };", "A", false));
    try T.expect(moduleExportsValueSpaceName(T.allocator, "export namespace N { export const v = 1; }", "N", false));
    try T.expect(!moduleExportsValueSpaceName(T.allocator, "export interface I {}", "I", false));
    try T.expect(!moduleExportsValueSpaceName(T.allocator, "export type A = number;", "A", false));
    try T.expect(!moduleExportsValueSpaceName(T.allocator, "namespace A {} export { A };", "A", false));
    try T.expect(!moduleExportsValueSpaceName(T.allocator, "export namespace N { export type T = any; }", "N", false));
}

test "moduleExportsTypeOnlyNamespaceName: exported type-only namespaces are declarations" {
    try T.expect(moduleExportsTypeOnlyNamespaceName(T.allocator, "export namespace Event { export type T = any; }", "Event", false));
    try T.expect(!moduleExportsTypeOnlyNamespaceName(T.allocator, "export namespace N { export const v = 1; }", "N", false));
    try T.expect(!moduleExportsTypeOnlyNamespaceName(T.allocator, "namespace N { export type T = any; }", "N", false));
    try T.expect(!moduleExportsTypeOnlyNamespaceName(T.allocator, "export interface I {}", "I", false));
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

test "moduleExportNestedTypeSpaceName: type-space member of an exported namespace cannot be named" {
    // `Inner` is reachable only as `N.Inner` — no top-level import alias
    // can name it, so it is the `cannot be named` (CannotBeNamed) case.
    const src =
        \\export namespace N {
        \\    export interface Inner {}
        \\}
    ;
    try T.expect(moduleExportNestedTypeSpaceName(T.allocator, src, "Inner", false));
    // Deeper nesting is also reachable only via qualification.
    const deep =
        \\export namespace Outer {
        \\    export namespace Mid {
        \\        export class Deep {}
        \\    }
        \\}
    ;
    try T.expect(moduleExportNestedTypeSpaceName(T.allocator, deep, "Deep", false));
}

test "moduleExportNestedTypeSpaceName: top-level exports and value-only members are NOT cannot-be-named" {
    // A direct top-level type-space export is the `from private module`
    // case, not `cannot be named` — must return false here.
    try T.expect(!moduleExportNestedTypeSpaceName(T.allocator, "export interface I {}", "I", false));
    try T.expect(!moduleExportNestedTypeSpaceName(T.allocator, "export class C {}", "C", false));
    // A value-only nested member (function) is not a type-space symbol.
    const value_only =
        \\export namespace N {
        \\    export function f() {}
        \\}
    ;
    try T.expect(!moduleExportNestedTypeSpaceName(T.allocator, value_only, "f", false));
    // A member of a NON-exported namespace is not reachable cross-module.
    const private_ns =
        \\namespace N {
        \\    export interface Inner {}
        \\}
    ;
    try T.expect(!moduleExportNestedTypeSpaceName(T.allocator, private_ns, "Inner", false));
    // Absent name.
    try T.expect(!moduleExportNestedTypeSpaceName(T.allocator, "export namespace N { export interface I {} }", "Missing", false));
}

test "moduleInferredExportUnsafeReference: nested node_modules return type is non-portable" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/r/node_modules/foo/node_modules/nested/index.d.ts", "export interface NestedProps {}");
    try vfs.addFile("/r/node_modules/foo/other/index.d.ts", "export interface OtherIndexProps {}");
    try vfs.addFile("/r/node_modules/foo/other.d.ts", "export interface OtherProps {}");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer resolver.deinit();
    const src =
        \\import { OtherProps } from "./other";
        \\import { OtherIndexProps } from "./other/index";
        \\import { NestedProps } from "nested";
        \\export interface SomeProps {}
        \\export function foo(): [SomeProps, OtherProps, OtherIndexProps, NestedProps];
    ;
    const unsafe = moduleInferredExportUnsafeReference(
        T.allocator,
        T.allocator,
        &resolver,
        src,
        "/r/node_modules/foo/index.d.ts",
        "foo",
        false,
    ) orelse return error.TestExpectedEqual;
    defer T.allocator.free(unsafe.symbol_name);
    defer T.allocator.free(unsafe.module_specifier);
    try T.expectEqualStrings("NestedProps", unsafe.symbol_name);
    try T.expectEqualStrings("foo/node_modules/nested", unsafe.module_specifier);
}

test "moduleInferredExportUnsafeReference: portable return type stays clean" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer resolver.deinit();
    const src =
        \\export interface RootProps {}
        \\export function bar(): RootProps;
    ;
    try T.expect(moduleInferredExportUnsafeReference(
        T.allocator,
        T.allocator,
        &resolver,
        src,
        "/node_modules/root/index.d.ts",
        "bar",
        false,
    ) == null);
}

test "Program: missing compiler type reference reports global TS2688" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    const file_id = try program.add("/index.ts", "export {};");
    try program.compileAll(.{
        .no_emit = true,
        .compiler_type_reference_names = &.{"definitely-missing"},
    });
    const compilation = program.fileById(file_id).compilation orelse return error.TestExpectedEqual;
    var found = false;
    for (compilation.diagnostics.items) |diagnostic| {
        if (diagnostic.code != 2688) continue;
        found = true;
        try T.expect(diagnostic.is_global);
        try T.expectEqualStrings(
            "Cannot find type definition file for 'definitely-missing'.",
            diagnostic.message,
        );
    }
    try T.expect(found);
}

test "Program: declaration UMD globals reach script and module consumers" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add(
        "/foo.d.ts",
        "export var x: number;\nexport function fn(): void;\nexport interface Thing { n: typeof x }\nexport as namespace Foo;\n",
    );
    const script_id = try program.add(
        "/script.ts",
        "Foo.fn();\nlet x: Foo.Thing;\nlet y: number = x.n;\n",
    );
    const module_id = try program.add(
        "/module.ts",
        "export {};\nlet z = Foo;\n",
    );

    try program.compileAll(.{ .no_emit = true });

    const script = program.fileById(script_id).compilation orelse return error.TestExpectedEqual;
    var script_used_before_assignment: usize = 0;
    for (script.diagnostics.items) |diagnostic| {
        try T.expect(diagnostic.code != 2304);
        try T.expect(diagnostic.code != 2503);
        if (diagnostic.code == 2454) script_used_before_assignment += 1;
    }
    try T.expectEqual(@as(usize, 0), script_used_before_assignment);

    const module = program.fileById(module_id).compilation orelse return error.TestExpectedEqual;
    var module_umd_diagnostics: usize = 0;
    for (module.diagnostics.items) |diagnostic| {
        try T.expect(diagnostic.code != 2304);
        if (diagnostic.code == 2686) module_umd_diagnostics += 1;
    }
    try T.expectEqual(@as(usize, 1), module_umd_diagnostics);
}

test "Program: sibling script interfaces contribute global type names" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();

    const app_id = try program.add("/app.ts", "interface A { x: $ }\n");
    _ = try program.add("/types/lib/index.d.ts", "interface $ { x }\n");
    try program.compileAll(.{
        .no_emit = true,
        .known_type_reference_names = &.{"lib"},
        .compiler_type_reference_names = &.{"lib"},
    });

    const app = program.fileById(app_id).compilation orelse return error.TestExpectedEqual;
    for (app.diagnostics.items) |diagnostic| {
        try T.expect(diagnostic.code != 2304);
        try T.expect(diagnostic.code != 2693);
    }
}

test "Program: global name discovery preserves declared interface types" {
    const cases = [_]struct { source: []const u8, codes: []const u16 }{
        .{
            .source =
            \\const Methods = 1;
            \\interface Methods { identity(value: string): string; }
            \\declare var methods: Methods;
            \\const good: string = methods.identity('ok');
            \\const bad: number = methods.identity('ok');
            \\methods.identity(1);
            \\methods.missing();
            ,
            .codes = &.{ 2322, 2345, 2339 },
        },
        .{
            .source =
            \\interface Methods { identity(value: string): string; }
            \\declare var methods: Methods;
            \\const good: string = methods.identity('ok');
            \\const bad: number = methods.identity('ok');
            \\methods.identity(1);
            \\methods.missing();
            ,
            .codes = &.{ 2322, 2345, 2339 },
        },
        .{
            .source =
            \\declare var methods: Methods;
            \\const good: string = methods.identity('ok');
            \\const bad: number = methods.identity('ok');
            \\methods.identity(1);
            \\methods.missing();
            \\interface Methods { identity(value: string): string; }
            ,
            .codes = &.{ 2322, 2345, 2339 },
        },
        .{
            .source =
            \\interface DeferredConstructor { identity<T>(value: T): T; }
            \\declare var Deferred: DeferredConstructor;
            \\const good: string = Deferred.identity('ok');
            \\const bad: number = Deferred.identity('ok');
            ,
            .codes = &.{2322},
        },
        .{
            .source =
            \\interface Methods { identity(value: string): string; }
            \\interface Methods { count(value: number): number; }
            \\declare var methods: Methods;
            \\const good: string = methods.identity('ok');
            \\const count: number = methods.count(1);
            \\const bad: number = methods.identity('ok');
            \\methods.count('bad');
            \\methods.missing();
            ,
            .codes = &.{ 2322, 2345, 2339 },
        },
        .{
            .source =
            \\interface Methods { identity(value: string): string; }
            \\type Alias = Methods;
            \\declare var methods: Alias;
            \\const good: string = methods.identity('ok');
            \\const bad: number = methods.identity('ok');
            \\methods.identity(1);
            ,
            .codes = &.{ 2322, 2345 },
        },
        .{
            .source =
            \\interface Methods { identity(value: string): string; }
            \\declare var methods: Methods;
            \\const good: string = methods.identity('ok');
            ,
            .codes = &.{},
        },
    };
    for (cases) |case| {
        for ([_][]const u8{ "", "export {};\n" }) |prefix| {
            const source = try std.mem.concat(T.allocator, u8, &.{ prefix, case.source });
            defer T.allocator.free(source);
            var vfs = ts_resolver.VirtualFs.init(T.allocator);
            defer vfs.deinit();
            var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
            defer resolver.deinit();
            var program = Program.init(T.allocator, &resolver);
            defer program.deinit();
            const app_id = try program.add("/app.ts", source);
            // A sibling script with the same type name must not replace
            // a module-local declaration with an untyped global name.
            if (prefix.len != 0) _ = try program.add("/globals.d.ts", "interface Methods { identity(value: number): number; }\n");
            try program.compileAll(.{ .no_emit = true, .strict = true });
            const app = program.fileById(app_id).compilation.?;
            try T.expectEqual(case.codes.len, app.diagnostics.items.len);
            for (case.codes, app.diagnostics.items) |code, diagnostic| {
                try T.expectEqual(code, diagnostic.code);
            }
        }
    }
}

test "Program: a local value does not hide the global type namespace" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{ .strategy = .node10 });
    defer resolver.deinit();
    var program = Program.init(T.allocator, &resolver);
    defer program.deinit();
    const app_id = try program.add("/app.ts",
        \\const Methods = 1;
        \\declare var methods: Methods;
        \\const good: string = methods.identity('ok');
    );
    _ = try program.add("/globals.d.ts", "interface Methods { identity(value: string): string; }\n");
    try program.compileAll(.{ .no_emit = true, .strict = true });
    const app = program.fileById(app_id).compilation.?;
    try T.expectEqual(@as(usize, 0), app.diagnostics.items.len);
}
