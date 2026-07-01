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
const tsconfig_mod = @import("tsconfig");
const hir_mod_ns = @import("hir");
const binder = @import("binder");

pub const FileId = u32;

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
    /// Compiled artefact. `null` until `compileAll` runs.
    compilation: ?*ts_driver.Compilation,
    /// Outgoing import edges — file ids this file imports from.
    imports: std.ArrayListUnmanaged(FileId),
    /// True for `.d.ts` / `.d.hm` / `.d.home` declaration-only files.
    is_declaration: bool,
    /// True for `.tsx` / `.jsx` files.
    is_tsx: bool,
    /// First-seen reason this file is in the program. `null` until set
    /// by `resolveImports` (for imported files); root files are
    /// classified by the CLI layer at `--explainFiles` time.
    include_reason: ?IncludeReason = null,
    /// Package-ID deduplication redirect target. When two physical
    /// node_modules files have the same package identity, tsgo keeps the
    /// first source file as canonical and records later paths as redirect
    /// files for explainFiles (TS1429).
    redirect_target: ?FileId = null,
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
    by_package_id: std.StringHashMapUnmanaged(FileId),
    resolver: *ts_resolver.Resolver,
    /// Stored sources keyed by path (we own the dupes).
    sources: std.StringHashMapUnmanaged([]const u8),

    pub fn init(gpa: std.mem.Allocator, resolver: *ts_resolver.Resolver) Program {
        return .{
            .gpa = gpa,
            .files = .empty,
            .by_path = .empty,
            .by_package_id = .empty,
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
            if (f.include_reason) |ir| {
                if (ir.specifier_text.len != 0) self.gpa.free(ir.specifier_text);
                if (ir.package_id.len != 0) self.gpa.free(ir.package_id);
                if (ir.project_reference_output.len != 0) self.gpa.free(ir.project_reference_output);
            }
            self.gpa.free(f.path);
            self.gpa.destroy(f);
        }
        self.files.deinit(self.gpa);

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
            .imports = .empty,
            .is_declaration = isDeclarationPath(path),
            .is_tsx = std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".jsx"),
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
            .imports = .empty,
            .is_declaration = target.is_declaration,
            .is_tsx = target.is_tsx,
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
        const module_interface_augmentations = try self.collectRelativeModuleInterfaceAugmentations();
        defer self.gpa.free(module_interface_augmentations);
        const program_exported_classes = try self.collectProgramExportedClasses();
        defer freeProgramExportedClasses(self.gpa, program_exported_classes);
        const program_ambient_module_interface_exports = try self.collectAmbientModuleInterfaceExports();
        defer freeProgramAmbientModuleInterfaceExports(self.gpa, program_ambient_module_interface_exports);
        const known_reference_paths = try self.gpa.alloc([]const u8, self.files.items.len);
        defer self.gpa.free(known_reference_paths);
        for (self.files.items, 0..) |f, i| known_reference_paths[i] = f.path;
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            if (f.compilation != null) continue;
            var per_file = options;
            per_file.is_tsx = options.is_tsx or f.is_tsx;
            per_file.ambient_global_namespace_roots = ambient_global_namespace_roots;
            per_file.script_object_expandos = script_object_expandos;
            per_file.module_interface_augmentations = module_interface_augmentations;
            per_file.program_exported_classes = program_exported_classes;
            per_file.program_ambient_module_interface_exports = program_ambient_module_interface_exports;
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
        try self.appendRootDirDiagnostics(options);
        try self.appendProgramGlobalDeclareVarDiagnostics();

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
        const module_interface_augmentations = try self.collectRelativeModuleInterfaceAugmentations();
        defer self.gpa.free(module_interface_augmentations);
        const program_exported_classes = try self.collectProgramExportedClasses();
        defer freeProgramExportedClasses(self.gpa, program_exported_classes);
        const program_ambient_module_interface_exports = try self.collectAmbientModuleInterfaceExports();
        defer freeProgramAmbientModuleInterfaceExports(self.gpa, program_ambient_module_interface_exports);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
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
            per_file.module_interface_augmentations = module_interface_augmentations;
            per_file.program_exported_classes = program_exported_classes;
            per_file.program_ambient_module_interface_exports = program_ambient_module_interface_exports;
            per_file.suppress_import_helper_diagnostics = true;
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

        try self.appendRootDirDiagnostics(options);

        try self.resolveImports();
    }

    fn collectAmbientGlobalNamespaceRoots(self: *const Program) ProgramError![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer freeStringSlice(self.gpa, out.items);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
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
            try collectTopLevelNamespaceRootSlices(self.gpa, f.source, &namespace_roots);
        }
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
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

    fn collectRelativeModuleInterfaceAugmentations(self: *const Program) ProgramError![]const ts_driver.ModuleInterfaceAugmentation {
        var out: std.ArrayListUnmanaged(ts_driver.ModuleInterfaceAugmentation) = .empty;
        errdefer out.deinit(self.gpa);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            try self.collectRelativeModuleInterfaceAugmentationsFromSource(f.path, f.source, &out);
        }
        return try out.toOwnedSlice(self.gpa);
    }

    fn collectProgramExportedClasses(self: *const Program) ProgramError![]const ts_driver.ProgramExportedClass {
        var out: std.ArrayListUnmanaged(ts_driver.ProgramExportedClass) = .empty;
        errdefer out.deinit(self.gpa);
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            try collectProgramExportedClassesFromSource(self.gpa, f.path, f.source, &out);
        }
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
            try collectRelativeModuleNamespaceStaticAugmentationsFromSource(self.gpa, f.path, f.source, &namespace_augmentations);
        }
        for (out.items) |*class| {
            var extra_count: usize = 0;
            for (namespace_augmentations.items) |aug| {
                if (!std.mem.eql(u8, aug.class_name, class.class_name)) continue;
                if (!programModulePathMatches(aug.target_path, class.target_path)) continue;
                extra_count += aug.members.len;
            }
            if (extra_count == 0) continue;
            var merged: std.ArrayListUnmanaged(ts_driver.ProgramExportedClassMember) = .empty;
            try merged.appendSlice(self.gpa, class.static_members);
            for (namespace_augmentations.items) |aug| {
                if (!std.mem.eql(u8, aug.class_name, class.class_name)) continue;
                if (!programModulePathMatches(aug.target_path, class.target_path)) continue;
                try merged.appendSlice(self.gpa, aug.members);
            }
            if (class.static_members.len > 0) self.gpa.free(class.static_members);
            class.static_members = try merged.toOwnedSlice(self.gpa);
        }
        return try out.toOwnedSlice(self.gpa);
    }

    fn collectAmbientModuleInterfaceExports(self: *const Program) ProgramError![]const ts_driver.ProgramAmbientModuleInterfaceExport {
        var out: std.ArrayListUnmanaged(ts_driver.ProgramAmbientModuleInterfaceExport) = .empty;
        errdefer {
            for (out.items) |item| {
                self.gpa.free(item.specifier);
                self.gpa.free(item.name);
                freeProgramAmbientInterfaceMembers(self.gpa, item.members);
            }
            out.deinit(self.gpa);
        }
        for (self.files.items) |f| {
            if (f.redirect_target != null) continue;
            try collectAmbientModuleInterfaceExportsFromSource(self.gpa, f.source, &out);
        }
        return try out.toOwnedSlice(self.gpa);
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

    fn collectProgramExportedClassesFromSource(
        gpa: std.mem.Allocator,
        path: []const u8,
        source: []const u8,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramExportedClass),
    ) ProgramError!void {
        try collectAmbientModuleClassesFromSource(gpa, path, source, out);
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_start, "export")) |export_pos| {
            search_start = export_pos + "export".len;
            if (!identifierKeywordAt(source, export_pos, "export")) continue;
            var cursor = export_pos + "export".len;
            while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            if (identifierKeywordAt(source, cursor, "default")) {
                cursor += "default".len;
                while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            }
            if (identifierKeywordAt(source, cursor, "abstract")) {
                cursor += "abstract".len;
                while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            }
            if (!identifierKeywordAt(source, cursor, "class")) continue;
            cursor += "class".len;
            while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            const name_end = parseIdentifierEnd(source, cursor, source.len) orelse continue;
            var members: []const ts_driver.ProgramExportedClassMember = &.{};
            if (std.mem.indexOfScalarPos(u8, source, name_end, '{')) |class_open| {
                if (findMatchingBrace(source, class_open)) |class_close| {
                    members = try collectExportedClassMembers(gpa, source, class_open + 1, class_close);
                }
            }
            const static_members = try collectExportedNamespaceStaticMembers(gpa, source, source[cursor..name_end]);
            try out.append(gpa, .{
                .target_path = path,
                .class_name = source[cursor..name_end],
                .members = members,
                .static_members = static_members,
            });
            search_start = name_end;
        }
    }

    fn collectAmbientModuleClassesFromSource(
        gpa: std.mem.Allocator,
        path: []const u8,
        source: []const u8,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramExportedClass),
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
            if (std.mem.startsWith(u8, spec, ".")) continue;
            const body_open = std.mem.indexOfScalarPos(u8, source, spec_end + 1, '{') orelse continue;
            const body_close = findMatchingBrace(source, body_open) orelse continue;
            try collectAmbientModuleClassesFromBody(gpa, path, spec, source, body_open + 1, body_close, out);
            search_start = body_close + 1;
        }
    }

    fn collectAmbientModuleClassesFromBody(
        gpa: std.mem.Allocator,
        path: []const u8,
        spec: []const u8,
        source: []const u8,
        body_start: usize,
        body_end: usize,
        out: *std.ArrayListUnmanaged(ts_driver.ProgramExportedClass),
    ) ProgramError!void {
        var search_start = body_start;
        while (search_start < body_end) {
            const class_pos = std.mem.indexOfPos(u8, source, search_start, "class") orelse break;
            if (class_pos >= body_end) break;
            search_start = class_pos + "class".len;
            if (!identifierKeywordAt(source, class_pos, "class")) continue;
            var name_start = class_pos + "class".len;
            while (name_start < body_end and std.ascii.isWhitespace(source[name_start])) : (name_start += 1) {}
            const name_end = parseIdentifierEnd(source, name_start, body_end) orelse continue;
            var members: []const ts_driver.ProgramExportedClassMember = &.{};
            if (std.mem.indexOfScalarPos(u8, source, name_end, '{')) |class_open| {
                if (class_open < body_end) {
                    if (findMatchingBrace(source, class_open)) |class_close| {
                        if (class_close <= body_end) {
                            members = try collectExportedClassMembers(gpa, source, class_open + 1, class_close);
                        }
                    }
                }
            }
            try out.append(gpa, .{
                .target_path = path,
                .ambient_module_name = spec,
                .class_name = source[name_start..name_end],
                .members = members,
            });
            search_start = name_end;
        }
    }

    fn collectExportedNamespaceStaticMembers(
        gpa: std.mem.Allocator,
        source: []const u8,
        class_name: []const u8,
    ) ProgramError![]const ts_driver.ProgramExportedClassMember {
        var out: std.ArrayListUnmanaged(ts_driver.ProgramExportedClassMember) = .empty;
        errdefer out.deinit(gpa);
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_start, "export")) |export_pos| {
            search_start = export_pos + "export".len;
            if (!identifierKeywordAt(source, export_pos, "export")) continue;
            var cursor = export_pos + "export".len;
            while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            if (!identifierKeywordAt(source, cursor, "namespace")) continue;
            cursor += "namespace".len;
            while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            const name_end = parseIdentifierEnd(source, cursor, source.len) orelse continue;
            if (!std.mem.eql(u8, source[cursor..name_end], class_name)) continue;
            const ns_open = std.mem.indexOfScalarPos(u8, source, name_end, '{') orelse continue;
            const ns_close = findMatchingBrace(source, ns_open) orelse continue;
            try collectNamespaceStaticMembers(gpa, source, ns_open + 1, ns_close, &out);
            search_start = ns_close + 1;
        }
        return try out.toOwnedSlice(gpa);
    }

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

    fn collectExportedClassMembers(
        gpa: std.mem.Allocator,
        source: []const u8,
        body_start: usize,
        body_end: usize,
    ) ProgramError![]const ts_driver.ProgramExportedClassMember {
        var members: std.ArrayListUnmanaged(ts_driver.ProgramExportedClassMember) = .empty;
        errdefer members.deinit(gpa);
        var i = body_start;
        var depth: usize = 0;
        while (i < body_end and i < source.len) : (i += 1) {
            const c = source[i];
            if (c == '{' or c == '(' or c == '[') {
                depth += 1;
                continue;
            }
            if (c == '}' or c == ')' or c == ']') {
                if (depth > 0) depth -= 1;
                continue;
            }
            if (depth != 0 or !asciiIdentifierStart(c)) continue;
            const member_start = i;
            const member_end = parseIdentifierEnd(source, member_start, body_end) orelse continue;
            const name = source[member_start..member_end];
            if (std.mem.eql(u8, name, "constructor") or
                std.mem.eql(u8, name, "get") or
                std.mem.eql(u8, name, "set") or
                std.mem.eql(u8, name, "static") or
                std.mem.eql(u8, name, "public") or
                std.mem.eql(u8, name, "private") or
                std.mem.eql(u8, name, "protected") or
                std.mem.eql(u8, name, "readonly") or
                std.mem.eql(u8, name, "declare") or
                std.mem.eql(u8, name, "abstract"))
            {
                i = member_end;
                continue;
            }
            var cursor = member_end;
            while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            if (cursor < body_end and source[cursor] == '(') {
                try members.append(gpa, .{ .name = name, .type_name = "any", .is_method = true });
                if (findMatchingParen(source, cursor, body_end)) |close| {
                    i = skipClassMemberRemainder(source, close + 1, body_end);
                }
                continue;
            }
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
            try members.append(gpa, .{ .name = name, .type_name = type_name, .is_method = false });
            i = skipClassMemberRemainder(source, cursor, body_end);
        }
        return members.toOwnedSlice(gpa);
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
            while (cursor < body_end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
            if (cursor >= body_end or source[cursor] != '(') {
                i = member_end;
                continue;
            }
            const params_close = findMatchingParen(source, cursor, body_end) orelse {
                i = member_end;
                continue;
            };
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
                .is_method = true,
            });
            i = return_end;
        }
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

    fn freeProgramExportedClasses(gpa: std.mem.Allocator, items: []const ts_driver.ProgramExportedClass) void {
        for (items) |item| {
            if (item.members.len > 0) gpa.free(item.members);
        }
        gpa.free(items);
    }

    fn freeProgramAmbientModuleInterfaceExports(gpa: std.mem.Allocator, items: []const ts_driver.ProgramAmbientModuleInterfaceExport) void {
        for (items) |item| {
            gpa.free(item.specifier);
            gpa.free(item.name);
            freeProgramAmbientInterfaceMembers(gpa, item.members);
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
        const module_interface_augmentations = try self.collectRelativeModuleInterfaceAugmentations();
        defer self.gpa.free(module_interface_augmentations);
        const program_exported_classes = try self.collectProgramExportedClasses();
        defer freeProgramExportedClasses(self.gpa, program_exported_classes);
        const program_ambient_module_interface_exports = try self.collectAmbientModuleInterfaceExports();
        defer freeProgramAmbientModuleInterfaceExports(self.gpa, program_ambient_module_interface_exports);
        var shared_options = options;
        shared_options.module_interface_augmentations = module_interface_augmentations;
        shared_options.program_exported_classes = program_exported_classes;
        shared_options.program_ambient_module_interface_exports = program_ambient_module_interface_exports;
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const n = workers orelse @min(cpu_count, 8);

        // Files-to-compile slice (indices we still need to do).
        var pending: std.ArrayListUnmanaged(usize) = .empty;
        defer pending.deinit(self.gpa);
        for (self.files.items, 0..) |f, idx| {
            if (f.compilation == null) try pending.append(self.gpa, idx);
        }
        if (pending.items.len == 0) {
            try self.appendRootDirDiagnostics(options);
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
                    per_file.suppress_import_helper_diagnostics = true;
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
            t.* = std.Thread.spawn(.{}, Worker.run, .{ self, shared_options, pending.items, &cursor, &failures }) catch {
                // If we can't spawn more workers, do the rest serially.
                Worker.run(self, shared_options, pending.items, &cursor, &failures);
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

        try self.appendRootDirDiagnostics(options);

        try self.resolveImports();
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
                            .specifier_pos = findIncludeSpecifierPosition(f.source, quoted),
                        };
                    }
                }
            }
        }
    }

    /// Expand the program to the transitive closure of imports, reading
    /// each newly-discovered file through the resolver's file system.
    /// Mirrors tsc's file loader, which follows every module reference
    /// from the root files until no new file is found. Returns the count
    /// of files added beyond the initial roots.
    ///
    /// Each round compiles the current set (so HIR import lists exist),
    /// then resolves+reads any imported file not already present; it
    /// repeats until a round adds nothing. `resolveImports` (run inside
    /// `compileAll`) records each added file's `include_reason`, so
    /// `--explainFiles` can later render TS1393.
    pub fn loadImportClosure(self: *Program, options: ts_driver.CompileOptions) ProgramError!usize {
        const hir_mod = @import("hir");
        var added: usize = 0;
        added += try self.loadCompilerOptionIncludes(options);
        added += try self.loadCompilerInjectedImports(options);
        while (true) {
            try self.compileAll(options);
            var new_in_round: usize = 0;
            // Snapshot the count: files appended this round are scanned
            // in the next iteration, keeping the fixpoint simple.
            const n = self.files.items.len;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const f = self.files.items[i];
                const c = f.compilation orelse continue;
                if (c.hir.kindOf(c.root) != .block_stmt) continue;
                const stmts = hir_mod.blockStmts(&c.hir, c.root);
                for (stmts) |s| {
                    if (c.hir.kindOf(s) != .import_decl) continue;
                    const imp = hir_mod.importOf(&c.hir, s);
                    const module_name = c.interner.get(imp.module);
                    if (module_name.len == 0) continue;
                    const res = self.resolver.resolve(module_name, f.path) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
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
                            const res = self.resolver.resolveTypeReferenceDirective(ref.name, f.path) catch |err| switch (err) {
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

        const added_id = try self.addResolvedIncludeFile(res.path);
        if (added_id) |id| {
            if (res.package_id) |package_id| {
                if (package_id.len != 0) {
                    const key = try self.gpa.dupe(u8, package_id);
                    errdefer self.gpa.free(key);
                    try self.by_package_id.put(self.gpa, key, id);
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
            if (f.redirect_target != null) continue;
            try self.appendMissingImportedHelperDiagnosticsForFile(f, options);
        }
    }

    const ProgramDeclareVar = struct {
        name: []const u8,
        type_text: []const u8,
    };

    fn appendProgramGlobalDeclareVarDiagnostics(self: *Program) ProgramError!void {
        var seen: std.StringHashMapUnmanaged(ProgramDeclareVar) = .empty;
        defer {
            var it = seen.iterator();
            while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
            seen.deinit(self.gpa);
        }

        for (self.files.items) |f| {
            if (f.redirect_target != null or !f.is_declaration) continue;
            if (sourceLooksExternalModule(f.source)) continue;
            const c = f.compilation orelse continue;
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

    fn sourceLooksExternalModule(source: []const u8) bool {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "import ")) return true;
            if (std.mem.startsWith(u8, line, "export ")) return true;
            if (std.mem.eql(u8, line, "export {}") or std.mem.eql(u8, line, "export {};")) return true;
        }
        return false;
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
        const tslib = self.findTslibDeclaration() orelse {
            if (sourceExternalEmitHelperPosition(f.source, options.emit.module_kind == .commonjs)) |pos| {
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

    fn appendImportedPrivateHelperArityDiagnostics(
        gpa: std.mem.Allocator,
        c: *ts_driver.Compilation,
        source: []const u8,
        tslib_source: []const u8,
    ) ProgramError!void {
        const hash_pos = firstPrivateIdentifierHash(source) orelse return;
        const checks = [_]struct { name: []const u8, required: usize }{
            .{ .name = "__classPrivateFieldGet", .required = 4 },
            .{ .name = "__classPrivateFieldSet", .required = 5 },
        };
        for (checks) |check| {
            const actual = helperParameterCount(tslib_source, check.name) orelse continue;
            if (actual >= check.required) continue;
            const msg = try std.fmt.allocPrint(
                gpa,
                "This syntax requires an imported helper named '{s}' with {d} parameters, which is not compatible with the one in 'tslib'. Consider upgrading your version of 'tslib'.",
                .{ check.name, check.required },
            );
            try c.diagnostics.append(gpa, .{
                .phase = .bind,
                .pos = @intCast(hash_pos),
                .line = 0,
                .span_len = @intCast(check.name.len),
                .code = 2807,
                .message = msg,
            });
            c.has_errors = true;
        }
    }

    fn sourceExternalEmitHelperPosition(source: []const u8, commonjs_module: bool) ?usize {
        var best: ?usize = null;
        if (findStage3DecoratedClassExpression(source, 0)) |decorated| best = decorated.at_pos;
        if (firstPrivateIdentifierHash(source)) |hash| best = minOptionalPos(best, hash);
        if (commonjs_module) {
            if (firstExportStarAsNamespace(source)) |export_pos| best = minOptionalPos(best, export_pos);
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
    const id = compilation.interner.lookup(name) orelse return false;
    const sym = compilation.module.root.values.get(id) orelse return false;
    if (sym.flags.is_type) return false;
    return moduleRootHasExportedRuntimeValue(&compilation.hir, compilation.root, id);
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
    type_only_pos: ?u32 = null,
};

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
    const name_id = compilation.interner.lookup(name) orelse return null;
    if (compilation.hir.kindOf(compilation.root) != .block_stmt) return null;
    var facts: ModuleExportFacts = .{};
    var found_module = false;
    for (hir_mod_ns.blockStmts(&compilation.hir, compilation.root)) |stmt| {
        const stmt_kind = compilation.hir.kindOf(stmt);
        if (stmt_kind != .module_decl and stmt_kind != .namespace_decl) continue;
        const ns = hir_mod_ns.namespaceOf(&compilation.hir, stmt);
        if (ns.name == hir_mod_ns.none_node_id or compilation.hir.kindOf(ns.name) != .literal_string) continue;
        const lit = hir_mod_ns.literalStringOf(&compilation.hir, ns.name);
        if (!moduleNameMatchesSpecifier(compilation.interner.get(lit.value), specifier)) continue;
        found_module = true;
        collectAmbientModuleExportFacts(&compilation.hir, name_id, hir_mod_ns.namespaceBody(&compilation.hir, stmt), &facts);
    }
    return if (found_module) facts else null;
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
    facts: *ModuleExportFacts,
) void {
    for (stmts) |stmt| {
        if (hir.kindOf(stmt) == .export_decl) {
            const ex = hir_mod_ns.exportOf(hir, stmt);
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
            if (ex.decl == hir_mod_ns.none_node_id) continue;
            collectAmbientModuleExportDeclFacts(hir, name, ex.decl, ex.is_type_only, facts);
            continue;
        }
        collectAmbientModuleExportDeclFacts(hir, name, stmt, false, facts);
    }
}

fn collectAmbientModuleExportDeclFacts(
    hir: *const hir_mod_ns.Hir,
    name: hir_mod_ns.StringId,
    decl: hir_mod_ns.NodeId,
    is_type_only: bool,
    facts: *ModuleExportFacts,
) void {
    if (declarationName(hir, decl) != name) return;
    if (declCreatesTypeSpaceName(hir, decl)) facts.exported_type = true;
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
            if (sp.local == name or sp.imported == name) {
                return moduleRootLocalNameCreatesRuntimeValue(hir, root, sp.imported);
            }
        }
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
    const root = compilation.root;
    if (compilation.hir.kindOf(root) != .block_stmt) return null;
    const name_id = compilation.interner.lookup(name);
    for (hir_mod_ns.blockStmts(&compilation.hir, root)) |stmt| {
        if (compilation.hir.kindOf(stmt) != .export_decl) continue;
        const ex = hir_mod_ns.exportOf(&compilation.hir, stmt);
        if (!ex.is_type_only) continue;
        // `export type * from "…"` re-exports every name type-only.
        if (ex.is_namespace) return compilation.hir.spanOf(stmt).start;
        // `export type { name }` / `export type { x as name }`.
        if (name_id) |nid| {
            for (hir_mod_ns.exportNamed(&compilation.hir, stmt)) |spec_node| {
                if (compilation.hir.kindOf(spec_node) != .export_specifier and
                    compilation.hir.kindOf(spec_node) != .import_specifier) continue;
                const sp = hir_mod_ns.importSpecifierOf(&compilation.hir, spec_node);
                if (sp.local == nid or sp.imported == nid) return compilation.hir.spanOf(spec_node).start;
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

test "Program: importHelpers reports missing tslib module for helper syntax" {
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
    try p.compileAll(.{ .emit = .{ .import_helpers = true } });

    const c = p.fileById(0).compilation.?;
    var saw_2354 = false;
    for (c.diagnostics.items) |d| {
        if (d.code == 2354 and std.mem.indexOf(u8, d.message, "module 'tslib' cannot be found") != null) {
            saw_2354 = true;
        }
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
    _ = try p.add("/proj/d.ts",
        \\import { A } from "./a";
        \\import { B } from "./b";
        \\export {};
        \\declare module "./a" {
        \\  interface A {
        \\    getB(): B;
        \\  }
        \\}
        \\A.prototype.getB = function() { return new B(); };
    );
    _ = try p.add("/proj/e.ts",
        \\import { A } from "./a";
        \\import { Cls } from "./c";
        \\export {};
        \\declare module "./a" {
        \\  interface A {
        \\    getCls(): Cls;
        \\  }
        \\}
        \\A.prototype.getCls = function() { return new Cls(); };
    );
    const main_id = try p.add("/proj/main.ts",
        \\import { A } from "./a";
        \\import "./d";
        \\import "./e";
        \\const a = new A();
        \\a.getB().value;
        \\a.getCls().ok;
    );

    try p.compileAll(.{ .no_emit = true });
    const main_c = p.fileById(main_id).compilation.?;
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

    try p.compileAll(.{ .no_emit = true });
    const map_c = p.fileById(map_id).compilation.?;
    const main_c = p.fileById(main_id).compilation.?;
    try expectCompilationLacksDiagnosticCode(map_c, 2449);
    try expectCompilationLacksDiagnosticCode(main_c, 2339);
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
