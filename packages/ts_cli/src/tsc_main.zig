//! `home tsc` binary entry point.
//!
//! Wraps `ts_cli.parseArgs` + `ts_cli.dispatch` (pure-decision layer)
//! with the actual disk I/O: read source files, compile through
//! `ts_program.Program`, and write `.js` (and optionally `.d.ts` /
//! `.js.map`) outputs to disk.
//!
//! This is the binary the CI matrix runs against tsc/tsgo for parity
//! checks. The pure-decision layer in `ts_cli.zig` is exercised by
//! unit tests; this main keeps stdio + filesystem code minimal so
//! the bulk of the logic remains testable.

const std = @import("std");
const ts_cli = @import("ts_cli");
const ts_program = @import("ts_program");
const ts_resolver = @import("ts_resolver");
const ts_driver = @import("ts_driver");
const ts_diagnostics = @import("ts_diagnostics");
const ts_emit = @import("ts_emit");
const tsconfig_mod = @import("tsconfig");
const ts_watch = @import("ts_watch");
const d_hm = @import("d_hm");

const ts_empty_files_list_in_config: u32 = 18002;

const RealFs = struct {
    fn read(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
        var threaded = std.Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();
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

    fn write(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
        var threaded = std.Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();
        // Make parent directories first.
        if (std.fs.path.dirname(path)) |parent| {
            cwd.createDirPath(io, parent) catch {};
        }
        var file = try cwd.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        if (bytes.len > 0) try file.writeStreamingAll(io, bytes);
    }
};

/// Expand `@response-file` arguments in place, mirroring tsc's
/// `parseResponseFile`: a `@file` arg is replaced by the whitespace/
/// quote-tokenized contents of `file` (recursively). A file that can't be
/// read or is empty emits TS5083; an unterminated quoted span emits
/// TS6045. `arena` owns the file contents (the appended args borrow into
/// them, so it must outlive `out`). `depth` guards against cycles.
fn expandResponseFiles(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    raw: []const []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
    depth: usize,
) void {
    for (raw) |a| {
        if (a.len > 1 and a[0] == '@' and depth <= 32) {
            const fname = a[1..];
            const contents = RealFs.read(arena, fname) catch "";
            if (contents.len == 0) {
                const msg = ts_cli.cannotReadFileDiagnostic(gpa, fname) catch continue;
                defer gpa.free(msg);
                std.debug.print("{s}\n", .{msg});
                continue;
            }
            const toks = ts_cli.tokenizeResponseFile(gpa, contents) catch continue;
            defer gpa.free(toks.args);
            if (toks.unterminated) {
                const msg = ts_cli.unterminatedResponseFileStringDiagnostic(gpa, fname) catch null;
                if (msg) |m| {
                    defer gpa.free(m);
                    std.debug.print("{s}\n", .{m});
                }
            }
            expandResponseFiles(gpa, arena, toks.args, out, depth + 1);
        } else {
            out.append(gpa, a) catch {};
        }
    }
}

/// Resolve a project reference (a `references[].path`, or the `tsc -b`
/// project argument) to a canonical `tsconfig.json` path. Per tsc: a path
/// ending in `.json` is the config file itself; otherwise it's a directory
/// holding `tsconfig.json`. `arena`-owned.
fn resolveConfigPath(arena: std.mem.Allocator, base_dir: []const u8, ref: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, ref, ".json")) {
        return std.fs.path.resolve(arena, &.{ base_dir, ref });
    }
    return std.fs.path.resolve(arena, &.{ base_dir, ref, "tsconfig.json" });
}

/// Built project-reference graph: parallel `nodes` (for `topoSortProjects`)
/// and canonical config `paths`.
const LoadedGraph = struct {
    nodes: []ts_cli.ProjectNode,
    paths: [][]const u8,
    diagnostics: []const []const u8 = &.{},
};

/// Load the `tsc --build` project graph starting from `root_config` (a
/// canonical tsconfig path), following `references` recursively. Builds the
/// node/dep structure `topoSortProjects` consumes. Unreadable/unparseable
/// referenced configs are treated as leaf nodes (no deps). `arena`-owned.
fn loadBuildGraph(gpa: std.mem.Allocator, arena: std.mem.Allocator, root_config: []const u8) !LoadedGraph {
    // Everything is arena-owned (freed with the caller's arena) so the
    // temporary lists don't need their own cleanup.
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var dep_lists: std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
    var diagnostics: std.ArrayListUnmanaged([]const u8) = .empty;

    const ensure = struct {
        fn idx(a: std.mem.Allocator, ps: *std.ArrayListUnmanaged([]const u8), ds: *std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)), p: []const u8) !usize {
            for (ps.items, 0..) |existing, i| {
                if (std.mem.eql(u8, existing, p)) return i;
            }
            try ps.append(a, p);
            try ds.append(a, .empty);
            return ps.items.len - 1;
        }
    };

    _ = try ensure.idx(arena, &paths, &dep_lists, root_config);
    var i: usize = 0;
    while (i < paths.items.len) : (i += 1) {
        const cfg_path = paths.items[i];
        const src = RealFs.read(arena, cfg_path) catch continue; // leaf on read error
        const cfg = tsconfig_mod.parseString(gpa, arena, src) catch continue;
        const base = std.fs.path.dirname(cfg_path) orelse ".";
        const parent_has_inputs = projectConfigHasInputFiles(gpa, arena, cfg_path, cfg) catch false;
        const parent_buildinfo = projectBuildInfoFilePath(arena, cfg_path, cfg) catch null;
        for (cfg.references) |ref| {
            const ref_path = resolveConfigPath(arena, base, ref) catch continue;
            const dep_idx = try ensure.idx(arena, &paths, &dep_lists, ref_path);
            try dep_lists.items[i].append(arena, dep_idx);
            const ref_src = RealFs.read(arena, ref_path) catch continue;
            const ref_cfg = tsconfig_mod.parseString(gpa, arena, ref_src) catch continue;
            if (parent_buildinfo) |parent_bi| {
                if (try projectBuildInfoFilePath(arena, ref_path, ref_cfg)) |ref_bi| {
                    if (std.mem.eql(u8, parent_bi, ref_bi)) {
                        try diagnostics.append(arena, try referencedProjectBuildInfoOverwriteDiagnostic(arena, parent_bi, ref));
                    }
                }
            }
            if (parent_has_inputs) {
                if (ref_cfg.compiler_options.composite != true) {
                    try diagnostics.append(arena, try referencedProjectMustBeCompositeDiagnostic(arena, ref));
                }
                if (ref_cfg.compiler_options.no_emit == true) {
                    try diagnostics.append(arena, try referencedProjectMayNotDisableEmitDiagnostic(arena, ref));
                }
            }
        }
    }

    const nodes = try arena.alloc(ts_cli.ProjectNode, paths.items.len);
    for (paths.items, 0..) |p, k| {
        nodes[k] = .{ .name = p, .deps = dep_lists.items[k].items };
    }
    return .{ .nodes = nodes, .paths = paths.items, .diagnostics = diagnostics.items };
}

fn projectConfigHasInputFiles(gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg_path: []const u8, cfg: tsconfig_mod.TsConfig) !bool {
    if (cfg.files) |files| return files.len > 0;

    const project_dir = std.fs.path.dirname(cfg_path) orelse ".";
    var input_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer input_files.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |p| gpa.free(p);
        owned.deinit(gpa);
    }
    var excludes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer excludes.deinit(gpa);
    if (cfg.exclude) |ex| {
        for (ex) |e| try excludes.append(gpa, e);
    }
    if (cfg.compiler_options.out_dir) |d| {
        try excludes.append(gpa, d);
        try excludes.append(gpa, try std.fmt.allocPrint(arena, "{s}/**", .{d}));
    }
    if (cfg.compiler_options.declaration_dir) |d| {
        try excludes.append(gpa, try std.fmt.allocPrint(arena, "{s}/**", .{d}));
    }
    try excludes.append(gpa, "**/node_modules/**");
    try expandProjectGlobs(gpa, project_dir, effectiveIncludePatterns(cfg), excludes.items, &input_files, &owned);
    return input_files.items.len > 0;
}

fn projectBuildInfoFilePath(arena: std.mem.Allocator, cfg_path: []const u8, cfg: tsconfig_mod.TsConfig) !?[]const u8 {
    const co = cfg.compiler_options;
    if (co.composite != true and co.incremental != true and co.ts_buildinfo_file == null) return null;

    const project_dir = std.fs.path.dirname(cfg_path) orelse ".";
    if (co.ts_buildinfo_file) |p| {
        if (std.fs.path.isAbsolute(p)) return try arena.dupe(u8, p);
        return try std.fs.path.resolve(arena, &.{ project_dir, p });
    }

    if (co.out_dir) |out_dir| {
        if (std.fs.path.isAbsolute(out_dir)) {
            return try std.fs.path.resolve(arena, &.{ out_dir, "tsconfig.tsbuildinfo" });
        }
        return try std.fs.path.resolve(arena, &.{ project_dir, out_dir, "tsconfig.tsbuildinfo" });
    }

    const cfg_basename = std.fs.path.basename(cfg_path);
    const stem_len = std.mem.lastIndexOfScalar(u8, cfg_basename, '.') orelse cfg_basename.len;
    const buildinfo_basename = try std.fmt.allocPrint(arena, "{s}.tsbuildinfo", .{cfg_basename[0..stem_len]});
    return try std.fs.path.resolve(arena, &.{ project_dir, buildinfo_basename });
}

fn referencedProjectMustBeCompositeDiagnostic(gpa: std.mem.Allocator, ref_path: []const u8) ![]const u8 {
    const code: u32 = 6306;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: Referenced project '{s}' must have setting \"composite\": true.",
        .{ code, ref_path },
    );
}

fn referencedProjectMayNotDisableEmitDiagnostic(gpa: std.mem.Allocator, ref_path: []const u8) ![]const u8 {
    const code: u32 = 6310;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: Referenced project '{s}' may not disable emit.",
        .{ code, ref_path },
    );
}

fn referencedProjectBuildInfoOverwriteDiagnostic(gpa: std.mem.Allocator, output_path: []const u8, ref_path: []const u8) ![]const u8 {
    const code: u32 = 6377;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: Cannot write file '{s}' because it will overwrite '.tsbuildinfo' file generated by referenced project '{s}'.",
        .{ code, output_path, ref_path },
    );
}

fn printConfigValidationDiagnostics(gpa: std.mem.Allocator, cfg: tsconfig_mod.TsConfig) !bool {
    const diags = try cfg.validate(gpa);
    defer tsconfig_mod.freeValidationDiagnostics(gpa, diags);
    if (diags.len == 0) return false;
    for (diags) |d| {
        std.debug.print("error TS{d}: {s}\n", .{ d.code, d.message });
    }
    return true;
}

/// Emit a tsc status message. tsc prints these
/// CategoryMessage diagnostics as plain text (no `TSxxxx:` prefix); the
/// `code` is carried so the diagnostic-coverage ledger credits it.
fn buildStatusMessage(comptime code: u32, comptime fmt: []const u8, args: anytype) void {
    comptime std.debug.assert(code >= 6000);
    std.debug.print(fmt, args);
}

fn reportWatchErrorStatus(error_count: usize) void {
    if (error_count == 1) {
        buildStatusMessage(6193, "Found 1 error. Watching for file changes.\n", .{});
    } else {
        buildStatusMessage(6194, "Found {d} errors. Watching for file changes.\n", .{error_count});
    }
}

/// A project is up to date when every expected output (`.js`, and `.d.ts`
/// when declarations are emitted) exists and is at least as new as every
/// input file. Mirrors the timestamp half of tsc's getUpToDateStatus.
fn projectIsUpToDate(
    gpa: std.mem.Allocator,
    inputs: []const []const u8,
    out_dir: ?[]const u8,
    declaration_dir: ?[]const u8,
    emit_dts: bool,
    project: []const u8,
    verbose: bool,
) bool {
    var newest_input: i128 = std.math.minInt(i128);
    var newest_input_path: []const u8 = "";
    var oldest_output: i128 = std.math.maxInt(i128);
    var oldest_output_path: []u8 = "";
    defer if (oldest_output_path.len != 0) gpa.free(oldest_output_path);
    for (inputs) |in| {
        const m = fileMtimeNanos(in) orelse return false; // can't stat → rebuild
        if (m > newest_input) {
            newest_input = m;
            newest_input_path = in;
        }
    }
    for (inputs) |in| {
        const js = computeOutPath(gpa, in, out_dir, ".js") catch return false;
        defer gpa.free(js);
        const jm = fileMtimeNanos(js) orelse {
            // TS6352 — output file does not exist → out of date.
            if (verbose) buildStatusMessage(6352, "Project '{s}' is out of date because output file '{s}' does not exist\n", .{ project, js });
            return false;
        };
        if (jm < newest_input) {
            // TS6350 — output older than input → out of date.
            if (verbose) buildStatusMessage(6350, "Project '{s}' is out of date because output '{s}' is older than input '{s}'\n", .{ project, js, newest_input_path });
            return false;
        }
        if (verbose and jm < oldest_output) {
            if (oldest_output_path.len != 0) gpa.free(oldest_output_path);
            oldest_output_path = gpa.dupe(u8, js) catch "";
            oldest_output = jm;
        }
        if (emit_dts) {
            const dts = computeOutPath(gpa, in, declaration_dir, ".d.ts") catch return false;
            defer gpa.free(dts);
            const dm = fileMtimeNanos(dts) orelse {
                if (verbose) buildStatusMessage(6352, "Project '{s}' is out of date because output file '{s}' does not exist\n", .{ project, dts });
                return false;
            };
            if (dm < newest_input) {
                if (verbose) buildStatusMessage(6350, "Project '{s}' is out of date because output '{s}' is older than input '{s}'\n", .{ project, dts, newest_input_path });
                return false;
            }
            if (verbose and dm < oldest_output) {
                if (oldest_output_path.len != 0) gpa.free(oldest_output_path);
                oldest_output_path = gpa.dupe(u8, dts) catch "";
                oldest_output = dm;
            }
        }
    }
    // TS6351 — verbose build reason for a timestamp-clean project.
    if (verbose and oldest_output_path.len != 0) {
        buildStatusMessage(6351, "Project '{s}' is up to date because newest input '{s}' is older than output '{s}'\n", .{ project, newest_input_path, oldest_output_path });
    }
    return true;
}

/// Build a single project (used by `tsc --build` for each project in
/// dependency order): load its tsconfig, gather inputs, compile, and emit
/// `.js` (+ `.d.ts` when declaration/composite is set). Paths are resolved
/// against the project's own directory. Returns true if the project had
/// compile errors. Reuses the same program/driver/emit APIs as the normal
/// single-project flow.
fn buildOneProject(gpa: std.mem.Allocator, arena: std.mem.Allocator, config_path: []const u8, verbose: bool, force: bool) bool {
    const cfg_src = RealFs.read(arena, config_path) catch {
        std.debug.print("error reading {s}\n", .{config_path});
        return true;
    };
    var cfg = tsconfig_mod.parseString(gpa, arena, cfg_src) catch {
        std.debug.print("error parsing {s}\n", .{config_path});
        return true;
    };
    cfg.file_path = config_path;
    if (printConfigValidationDiagnostics(gpa, cfg) catch true) return true;
    const project_dir = std.fs.path.dirname(config_path) orelse ".";

    var input_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer input_files.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |p| gpa.free(p);
        owned.deinit(gpa);
    }
    if (cfg.files) |fs_list| {
        for (fs_list) |f| {
            const p = std.fs.path.join(gpa, &.{ project_dir, f }) catch return true;
            owned.append(gpa, p) catch return true;
            input_files.append(gpa, p) catch return true;
        }
    } else {
        // Exclude the project's own output dir (so emitted .js/.d.ts aren't
        // re-ingested as inputs on rebuild) and node_modules, in addition
        // to any configured excludes — mirrors tsc's default excludes.
        var excludes: std.ArrayListUnmanaged([]const u8) = .empty;
        defer excludes.deinit(gpa);
        if (cfg.exclude) |ex| {
            for (ex) |e| excludes.append(gpa, e) catch return true;
        }
        if (cfg.compiler_options.out_dir) |d| {
            excludes.append(gpa, d) catch return true;
            excludes.append(gpa, std.fmt.allocPrint(arena, "{s}/**", .{d}) catch return true) catch return true;
        }
        if (cfg.compiler_options.declaration_dir) |d| {
            excludes.append(gpa, std.fmt.allocPrint(arena, "{s}/**", .{d}) catch return true) catch return true;
        }
        excludes.append(gpa, "**/node_modules/**") catch return true;
        expandProjectGlobs(gpa, project_dir, effectiveIncludePatterns(cfg), excludes.items, &input_files, &owned) catch return true;
    }
    if (input_files.items.len == 0) {
        if (verbose) std.debug.print("  (no input files)\n", .{});
        return false;
    }

    // Output directories are resolved against the project's own dir.
    const out_dir: ?[]const u8 = if (cfg.compiler_options.out_dir) |d|
        (std.fs.path.join(arena, &.{ project_dir, d }) catch return true)
    else
        null;
    const emit_dts = (cfg.compiler_options.declaration orelse false) or (cfg.compiler_options.composite orelse false);
    const declaration_dir: ?[]const u8 = if (cfg.compiler_options.declaration_dir) |d|
        (std.fs.path.join(arena, &.{ project_dir, d }) catch return true)
    else
        out_dir;

    // Incremental up-to-date check (tsc's getUpToDateStatus, simplified to
    // input/output mtime comparison). Skipped under `--force`.
    if (!force and projectNeedsTimestampUpdate(gpa, arena, config_path, cfg, input_files.items, out_dir, declaration_dir, emit_dts)) {
        if (verbose) {
            buildStatusMessage(6400, "Project '{s}' is up to date but needs to update timestamps of output files that are older than input files\n", .{config_path});
            buildStatusMessage(6359, "Updating output timestamps of project '{s}'...\n", .{config_path});
        }
        touchProjectOutputs(gpa, input_files.items, out_dir, declaration_dir, emit_dts);
        return false;
    }
    if (!force and projectIsUpToDate(gpa, input_files.items, out_dir, declaration_dir, emit_dts, config_path, verbose)) {
        return false;
    }
    // TS6388 — under `--force`, tsc rebuilds regardless of up-to-dateness.
    if (force and verbose) buildStatusMessage(6388, "Project '{s}' is being forcibly rebuilt\n", .{config_path});
    // TS6358 — `Building project '{0}'...`
    if (verbose) buildStatusMessage(6358, "Building project '{s}'...\n", .{config_path});

    var resolver_fs = ResolverRealFs{};
    var resolver = ts_resolver.Resolver.init(gpa, resolver_fs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();
    for (input_files.items) |path| {
        const src = RealFs.read(gpa, path) catch {
            std.debug.print("error reading {s}\n", .{path});
            return true;
        };
        defer gpa.free(src);
        _ = program.add(path, src) catch return true;
    }

    var compile_opts = ts_driver.optionsFromConfig(&cfg);
    var resolver_adapter = CheckerResolverAdapter{ .resolver = &resolver };
    compile_opts.external_resolver = .{ .ptr = &resolver_adapter, .vtable = &CheckerResolverAdapter.vtable };
    _ = program.loadImportClosure(compile_opts) catch {};

    var had_errors = false;
    var stream_ctx: StreamCtx = .{
        .gpa = gpa,
        .program = &program,
        .use_pretty = true,
        .use_color = false,
        .any_errors = &had_errors,
    };
    program.compileAllStreaming(compile_opts, &stream_ctx, streamDiagsCallback) catch return true;
    if (cfg.compiler_options.composite orelse false) {
        const composite_summary = printCompositeProjectFileListDiagnostics(
            gpa,
            &program,
            input_files.items,
            config_path,
            true,
            false,
        );
        if (composite_summary.error_count > 0) had_errors = true;
    }
    if (compile_opts.no_emit) return had_errors;

    var reported_unchanged_timestamps = false;
    for (program.files.items) |f| {
        const c = f.compilation orelse continue;
        const out_path = computeOutPath(gpa, f.path, out_dir, ".js") catch continue;
        defer gpa.free(out_path);
        writeProjectOutput(gpa, out_path, c.js, config_path, verbose, &reported_unchanged_timestamps);
        if (emit_dts) {
            const dts_path = computeOutPath(gpa, f.path, declaration_dir, ".d.ts") catch continue;
            defer gpa.free(dts_path);
            // Prefer zig-dtsx (source-driven, infers exported types); fall
            // back to the symbol-driven emitter if it can't process the file.
            if (ts_emit.d_ts_fast.emit(gpa, f.source)) |dts| {
                defer gpa.free(dts);
                writeProjectOutput(gpa, dts_path, dts, config_path, verbose, &reported_unchanged_timestamps);
            } else |_| {
                var emitter = ts_emit.DtsEmitter.initWithTypes(gpa, &c.hir, &c.interner, &c.type_interner, .{});
                defer emitter.deinit();
                emitter.emitSourceFile(c.root) catch continue;
                const dts_bytes = emitter.toOwnedSlice() catch continue;
                defer gpa.free(dts_bytes);
                writeProjectOutput(gpa, dts_path, dts_bytes, config_path, verbose, &reported_unchanged_timestamps);
            }
        }
    }
    return had_errors;
}

const ProjectDryStatus = enum { build, up_to_date, update_timestamps };

fn projectDryStatus(gpa: std.mem.Allocator, arena: std.mem.Allocator, config_path: []const u8) ProjectDryStatus {
    const cfg_src = RealFs.read(arena, config_path) catch return .build;
    var cfg = tsconfig_mod.parseString(gpa, arena, cfg_src) catch return .build;
    cfg.file_path = config_path;
    if (printConfigValidationDiagnostics(gpa, cfg) catch true) return .build;
    const project_dir = std.fs.path.dirname(config_path) orelse ".";

    var input_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer input_files.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |p| gpa.free(p);
        owned.deinit(gpa);
    }
    if (cfg.files) |fs_list| {
        for (fs_list) |f| {
            const p = std.fs.path.join(gpa, &.{ project_dir, f }) catch return .build;
            owned.append(gpa, p) catch return .build;
            input_files.append(gpa, p) catch return .build;
        }
    } else {
        var excludes: std.ArrayListUnmanaged([]const u8) = .empty;
        defer excludes.deinit(gpa);
        if (cfg.exclude) |ex| {
            for (ex) |e| excludes.append(gpa, e) catch return .build;
        }
        if (cfg.compiler_options.out_dir) |d| {
            excludes.append(gpa, d) catch return .build;
            excludes.append(gpa, std.fmt.allocPrint(arena, "{s}/**", .{d}) catch return .build) catch return .build;
        }
        if (cfg.compiler_options.declaration_dir) |d| {
            excludes.append(gpa, std.fmt.allocPrint(arena, "{s}/**", .{d}) catch return .build) catch return .build;
        }
        excludes.append(gpa, "**/node_modules/**") catch return .build;
        expandProjectGlobs(gpa, project_dir, effectiveIncludePatterns(cfg), excludes.items, &input_files, &owned) catch return .build;
    }
    if (input_files.items.len == 0) return .up_to_date;

    const out_dir: ?[]const u8 = if (cfg.compiler_options.out_dir) |d|
        (std.fs.path.join(arena, &.{ project_dir, d }) catch return .build)
    else
        null;
    const emit_dts = (cfg.compiler_options.declaration orelse false) or (cfg.compiler_options.composite orelse false);
    const declaration_dir: ?[]const u8 = if (cfg.compiler_options.declaration_dir) |d|
        (std.fs.path.join(arena, &.{ project_dir, d }) catch return .build)
    else
        out_dir;

    if (projectNeedsTimestampUpdate(gpa, arena, config_path, cfg, input_files.items, out_dir, declaration_dir, emit_dts)) {
        return .update_timestamps;
    }
    return if (projectIsUpToDate(gpa, input_files.items, out_dir, declaration_dir, emit_dts, config_path, false))
        .up_to_date
    else
        .build;
}

fn buildInfoVersionForPath(info: ts_emit.tsbuildinfo.BuildInfo, path: []const u8) ?[]const u8 {
    for (info.file_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, path)) return info.file_infos[i].version;
    }
    return null;
}

fn sourceSha1Hex(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(source);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    const hex = try gpa.alloc(u8, digest.len * 2);
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return hex;
}

fn projectNeedsTimestampUpdate(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    config_path: []const u8,
    cfg: tsconfig_mod.TsConfig,
    inputs: []const []const u8,
    out_dir: ?[]const u8,
    declaration_dir: ?[]const u8,
    emit_dts: bool,
) bool {
    const buildinfo_path = (projectBuildInfoFilePath(arena, config_path, cfg) catch null) orelse return false;
    const buildinfo_src = RealFs.read(gpa, buildinfo_path) catch return false;
    defer gpa.free(buildinfo_src);
    var info = ts_emit.tsbuildinfo.read(gpa, buildinfo_src) catch return false;
    defer info.deinit(gpa);

    var newest_input: i128 = std.math.minInt(i128);
    for (inputs) |path| {
        const input_mtime = fileMtimeNanos(path) orelse return false;
        if (input_mtime > newest_input) newest_input = input_mtime;
        const source = RealFs.read(gpa, path) catch return false;
        defer gpa.free(source);
        const current_hash = sourceSha1Hex(gpa, source) catch return false;
        defer gpa.free(current_hash);
        const stored_hash = buildInfoVersionForPath(info, path) orelse return false;
        if (!std.mem.eql(u8, current_hash, stored_hash)) return false;
    }

    var found_older_output = false;
    for (inputs) |path| {
        const js = computeOutPath(gpa, path, out_dir, ".js") catch return false;
        defer gpa.free(js);
        const js_mtime = fileMtimeNanos(js) orelse return false;
        if (js_mtime < newest_input) found_older_output = true;
        if (emit_dts) {
            const dts = computeOutPath(gpa, path, declaration_dir, ".d.ts") catch return false;
            defer gpa.free(dts);
            const dts_mtime = fileMtimeNanos(dts) orelse return false;
            if (dts_mtime < newest_input) found_older_output = true;
        }
    }
    return found_older_output;
}

fn touchFileNow(path: []const u8) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{}) catch return;
    defer file.close(io);
    file.setTimestampsNow(io) catch {};
}

fn touchProjectOutputs(
    gpa: std.mem.Allocator,
    inputs: []const []const u8,
    out_dir: ?[]const u8,
    declaration_dir: ?[]const u8,
    emit_dts: bool,
) void {
    for (inputs) |path| {
        const js = computeOutPath(gpa, path, out_dir, ".js") catch continue;
        defer gpa.free(js);
        touchFileNow(js);
        if (emit_dts) {
            const dts = computeOutPath(gpa, path, declaration_dir, ".d.ts") catch continue;
            defer gpa.free(dts);
            touchFileNow(dts);
        }
    }
}

fn writeProjectOutput(
    gpa: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    project: []const u8,
    verbose: bool,
    reported_unchanged_timestamps: *bool,
) void {
    if (RealFs.read(gpa, path)) |existing| {
        defer gpa.free(existing);
        if (std.mem.eql(u8, existing, bytes)) {
            if (verbose and !reported_unchanged_timestamps.*) {
                buildStatusMessage(6371, "Updating unchanged output timestamps of project '{s}'...\n", .{project});
                reported_unchanged_timestamps.* = true;
            }
            touchFileNow(path);
            return;
        }
    } else |_| {}
    writeOrDie(gpa, path, bytes);
}

fn appendCleanOutputIfPresent(
    gpa: std.mem.Allocator,
    inputs: []const []const u8,
    outputs: *std.ArrayListUnmanaged([]u8),
    output_path: []const u8,
) !void {
    if (pathInList(inputs, output_path)) return;
    if (fileMtimeNanos(output_path) == null) return;
    try outputs.append(gpa, try gpa.dupe(u8, output_path));
}

fn appendProjectCleanOutputs(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    config_path: []const u8,
    outputs: *std.ArrayListUnmanaged([]u8),
) !void {
    const cfg_src = RealFs.read(arena, config_path) catch return;
    var cfg = tsconfig_mod.parseString(gpa, arena, cfg_src) catch return;
    cfg.file_path = config_path;
    const project_dir = std.fs.path.dirname(config_path) orelse ".";

    var input_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer input_files.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |p| gpa.free(p);
        owned.deinit(gpa);
    }
    if (cfg.files) |fs_list| {
        for (fs_list) |f| {
            const p = try std.fs.path.join(gpa, &.{ project_dir, f });
            try owned.append(gpa, p);
            try input_files.append(gpa, p);
        }
    } else {
        var excludes: std.ArrayListUnmanaged([]const u8) = .empty;
        defer excludes.deinit(gpa);
        if (cfg.exclude) |ex| {
            for (ex) |e| try excludes.append(gpa, e);
        }
        if (cfg.compiler_options.out_dir) |d| {
            try excludes.append(gpa, d);
            try excludes.append(gpa, try std.fmt.allocPrint(arena, "{s}/**", .{d}));
        }
        if (cfg.compiler_options.declaration_dir) |d| {
            try excludes.append(gpa, try std.fmt.allocPrint(arena, "{s}/**", .{d}));
        }
        try excludes.append(gpa, "**/node_modules/**");
        try expandProjectGlobs(gpa, project_dir, effectiveIncludePatterns(cfg), excludes.items, &input_files, &owned);
    }

    const out_dir: ?[]const u8 = if (cfg.compiler_options.out_dir) |d|
        try std.fs.path.join(arena, &.{ project_dir, d })
    else
        null;
    const emit_dts = (cfg.compiler_options.declaration orelse false) or (cfg.compiler_options.composite orelse false);
    const declaration_dir: ?[]const u8 = if (cfg.compiler_options.declaration_dir) |d|
        try std.fs.path.join(arena, &.{ project_dir, d })
    else
        out_dir;

    for (input_files.items) |path| {
        const js = try computeOutPath(gpa, path, out_dir, ".js");
        defer gpa.free(js);
        try appendCleanOutputIfPresent(gpa, input_files.items, outputs, js);
        if (emit_dts) {
            const dts = try computeOutPath(gpa, path, declaration_dir, ".d.ts");
            defer gpa.free(dts);
            try appendCleanOutputIfPresent(gpa, input_files.items, outputs, dts);
        }
    }
}

fn printDryCleanOutputs(outputs: []const []u8) void {
    // TS6356 — dry clean status with one bullet per would-delete output.
    buildStatusMessage(6356, "A non-dry build would delete the following files:\n", .{});
    for (outputs) |path| {
        std.debug.print(" * {s}\n", .{path});
    }
}

/// How a root (input) file was specified, for `--explainFiles`.
const RootInclusion = struct {
    /// TS1427 / TS1409 / TS1457 / TS1407 — chosen by provenance.
    code: u32,
    /// For TS1407, the include pattern that matched (`{0}`).
    spec: []const u8 = "",
    /// Config file path, for TS1407's `{1}`.
    config_path: []const u8 = "",
};

/// `--explainFiles`: print each program file with the reason it is part of
/// the compilation, mirroring tsc's `ExplainFiles`. Root (input) files use
/// the provenance-derived reason; any transitively-added file uses TS1399.
fn printExplainFiles(
    gpa: std.mem.Allocator,
    program: *const ts_program.Program,
    roots: []const []const u8,
    root: RootInclusion,
) void {
    // The file-inclusion reason codes this renders (referenced here so the
    // status scanner credits them as emitted).
    const code_root_specified: u32 = 1427;
    const code_files_list: u32 = 1409;
    const code_default_include: u32 = 1457;
    const code_include_pattern: u32 = 1407;
    // TS1393 `Imported via {0} from file '{1}'` — the reason a
    // transitively-included (non-root) file is in the program. Mirrors
    // tsgo's `fileIncludeKindImport` branch of `computeReferenceFileDiagnostic`.
    const code_imported_via: u32 = 1393;
    _ = code_imported_via;
    // TS1400 `Referenced via '{0}' from file '{1}'` — a file pulled in by
    // a `/// <reference path="…" />` directive.
    const code_referenced_via: u32 = 1400;
    _ = code_referenced_via;
    for (program.files.items) |f| {
        std.debug.print("{s}\n", .{f.path});
        if (!pathInList(roots, f.path)) {
            // A non-root file is here because something pulled it in —
            // an import (TS1393) or a `/// <reference path>` directive
            // (TS1400). tsgo prints one line per include reason; Home
            // records the first puller.
            if (f.include_reason) |ir| {
                switch (ir.kind) {
                    .import => {
                        const importer_path = program.files.items[ir.importer].path;
                        const msg = std.fmt.allocPrint(
                            gpa,
                            "  Imported via {s} from file '{s}'",
                            .{ ir.specifier_text, importer_path },
                        ) catch return;
                        defer gpa.free(msg);
                        std.debug.print("{s}\n", .{msg});
                        continue;
                    },
                    .reference_file => {
                        const referencing_path = program.files.items[ir.importer].path;
                        const msg = std.fmt.allocPrint(
                            gpa,
                            "  Referenced via '{s}' from file '{s}'",
                            .{ ir.specifier_text, referencing_path },
                        ) catch return;
                        defer gpa.free(msg);
                        std.debug.print("{s}\n", .{msg});
                        continue;
                    },
                    .root => {},
                }
            }
            // No recorded edge (partial program / resolution gap): fall
            // back to the generic root-specified reason rather than
            // fabricating a puller.
            std.debug.print("  {s}\n", .{(ts_diagnostics.codes.lookup(code_root_specified) orelse unreachable).message});
            continue;
        }
        if (root.code == code_include_pattern) {
            // "Matched by include pattern '{0}' in '{1}'."
            const cfg_base = std.fs.path.basename(root.config_path);
            const msg = std.fmt.allocPrint(gpa, "  Matched by include pattern '{s}' in '{s}'", .{ root.spec, cfg_base }) catch return;
            defer gpa.free(msg);
            std.debug.print("{s}\n", .{msg});
        } else {
            const code = switch (root.code) {
                code_files_list => code_files_list,
                code_default_include => code_default_include,
                else => code_root_specified,
            };
            std.debug.print("  {s}\n", .{(ts_diagnostics.codes.lookup(code) orelse unreachable).message});
        }
    }
}

/// True when `needle` string-equals any entry in `haystack`.
fn pathInList(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |p| {
        if (std.mem.eql(u8, p, needle)) return true;
    }
    return false;
}

const CompositeProjectFileListSummary = struct {
    error_count: usize = 0,
    files_with_errors: usize = 0,
    first_error_file: []const u8 = "",
    first_error_line: usize = 0,
    first_error_col: usize = 0,
};

fn sourceFileMayBeEmittedByProject(f: *const ts_program.File) bool {
    return !f.is_declaration;
}

fn compositeProjectFileListMessage(
    gpa: std.mem.Allocator,
    file_path: []const u8,
    config_path: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "File '{s}' is not listed within the file list of project '{s}'. Projects must list all files or use an 'include' pattern.",
        .{ file_path, config_path },
    );
}

fn compositeDiagnosticAnchor(
    program: *const ts_program.Program,
    f: *const ts_program.File,
) struct { file: *const ts_program.File, pos: u32, span_len: u32 } {
    if (f.include_reason) |reason| {
        if (reason.importer < program.files.items.len) {
            const importer = program.fileById(reason.importer);
            const pos = findIncludeSpecifierPosition(importer.source, reason.specifier_text);
            const span_len: u32 = blk: {
                if (reason.specifier_text.len >= 2) {
                    const first = reason.specifier_text[0];
                    const last = reason.specifier_text[reason.specifier_text.len - 1];
                    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
                        break :blk @intCast(@min(reason.specifier_text.len, std.math.maxInt(u32)));
                    }
                }
                break :blk @intCast(@min(reason.specifier_text.len, std.math.maxInt(u32)));
            };
            return .{ .file = importer, .pos = pos, .span_len = span_len };
        }
    }
    return .{ .file = f, .pos = 0, .span_len = 0 };
}

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

fn printCompositeProjectFileListDiagnostics(
    gpa: std.mem.Allocator,
    program: *const ts_program.Program,
    roots: []const []const u8,
    config_path: []const u8,
    use_pretty: bool,
    use_color: bool,
) CompositeProjectFileListSummary {
    var summary: CompositeProjectFileListSummary = .{};
    var seen_files: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_files.deinit(gpa);
    for (program.files.items) |f| {
        if (!sourceFileMayBeEmittedByProject(f)) continue;
        if (pathInList(roots, f.path)) continue;
        const anchor = compositeDiagnosticAnchor(program, f);
        const lc = ts_diagnostics.positionToLineCol(anchor.file.source, anchor.pos);
        const message = compositeProjectFileListMessage(gpa, f.path, config_path) catch continue;
        defer gpa.free(message);
        const diag: ts_diagnostics.Diagnostic = .{
            .file = anchor.file.path,
            .line = lc.line,
            .col = lc.col,
            .code = 6307,
            .code_prefix = .TS,
            .severity = .err,
            .message = message,
            .span_len = anchor.span_len,
        };
        const formatted = if (use_pretty)
            ts_diagnostics.formatPretty(gpa, diag, anchor.file.source, use_color) catch continue
        else
            ts_diagnostics.formatDefault(gpa, diag) catch continue;
        defer gpa.free(formatted);
        std.debug.print("{s}\n", .{formatted});

        summary.error_count += 1;
        if (!seen_files.contains(anchor.file.path)) {
            seen_files.put(gpa, anchor.file.path, {}) catch {};
            summary.files_with_errors += 1;
        }
        if (summary.first_error_file.len == 0) {
            summary.first_error_file = anchor.file.path;
            summary.first_error_line = lc.line;
            summary.first_error_col = lc.col;
        }
    }
    return summary;
}

/// Modification time of `path` in nanoseconds, or null if it can't be
/// stat'd (missing/unreadable). Used by `tsc --build`'s up-to-date check.
fn fileMtimeNanos(path: []const u8) ?i128 {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    return @as(i128, st.mtime.nanoseconds);
}

/// Write `bytes` to `path`, or emit TS5033 and exit on failure. Mirrors
/// tsc's emitter, which reports `Could_not_write_file` for any output
/// write error.
fn writeOrDie(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) void {
    RealFs.write(gpa, path, bytes) catch |err| {
        const msg = ts_cli.couldNotWriteFileDiagnostic(gpa, path, @errorName(err)) catch std.process.exit(1);
        defer gpa.free(msg);
        std.debug.print("{s}\n", .{msg});
        std.process.exit(1);
    };
}

const ResolverRealFs = struct {
    pub fn fs(self: *ResolverRealFs) ts_resolver.FileSystem {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: ts_resolver.FileSystem.VTable = .{
        .fileExists = fileExists,
        .directoryExists = directoryExists,
        .readFile = readFile,
    };

    fn fileExists(_: *anyopaque, path: []const u8) bool {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();
        var file = cwd.openFile(io, path, .{}) catch return false;
        defer file.close(io);
        return true;
    }

    fn directoryExists(_: *anyopaque, path: []const u8) bool {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, path, .{}) catch return false;
        defer dir.close(io);
        return true;
    }

    fn readFile(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const bytes = try RealFs.read(gpa, path);
        return @constCast(bytes);
    }
};

/// True if `path` names an existing regular file. Used by the explicit
/// `--project` existence checks (TS5058 / TS5081).
fn fileExistsOnDisk(gpa: std.mem.Allocator, path: []const u8) bool {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// True if `path` names an existing directory.
fn directoryExistsOnDisk(gpa: std.mem.Allocator, path: []const u8) bool {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

const CheckerResolverAdapter = struct {
    resolver: *ts_resolver.Resolver,

    pub const vtable = ts_driver.ExternalResolver.VTable{
        .resolve = resolveImpl,
        .moduleExport = moduleExportImpl,
    };

    fn resolveImpl(
        self_ptr: *anyopaque,
        specifier: []const u8,
        containing_file: []const u8,
    ) ?ts_driver.ExternalResolver.Resolution {
        const self: *CheckerResolverAdapter = @ptrCast(@alignCast(self_ptr));
        const r = self.resolver.resolve(specifier, containing_file) catch return null;
        return .{
            .path = r.path,
            .is_declaration = r.is_declaration,
            .alternate_result = r.alternate_result,
        };
    }

    /// Cross-module export query, backing the checker's
    /// `crossModulePrivateNameInfo` (TS4023/TS4024/TS4026/TS4030/TS4034
    /// "… from external/private module …" privacy diagnostics). Without
    /// this the production CLI left those codes silent on real `home-tsc`
    /// invocations even though the checker emission sites exist — only
    /// the conformance harness wired it. Resolve the specifier, read +
    /// bind the resolved module, and report whether `name` is a top-level
    /// type-space export (`exported_type`) or reachable only as a nested
    /// member of an exported namespace (`cannot_be_named`). Mirrors the
    /// conformance harness's `CheckerResolverAdapter.moduleExportImpl`.
    fn moduleExportImpl(
        self_ptr: *anyopaque,
        specifier: []const u8,
        containing_file: []const u8,
        name: []const u8,
    ) ?ts_driver.ExternalResolver.ModuleExport {
        const self: *CheckerResolverAdapter = @ptrCast(@alignCast(self_ptr));
        const r = self.resolver.resolve(specifier, containing_file) catch return null;
        // The resolver's arena outlives the checker calls, so the rendered
        // module name borrowed by the checker stays valid.
        const arena = self.resolver.arena.allocator();
        const src = self.resolver.fs.readFile(self.resolver.gpa, r.path) catch return null;
        defer self.resolver.gpa.free(src);
        const is_tsx = std.mem.endsWith(u8, r.path, ".tsx") or std.mem.endsWith(u8, r.path, ".jsx");
        const exported = ts_program.moduleExportsTypeSpaceName(self.resolver.gpa, src, name, is_tsx);
        const cannot_be_named = !exported and
            ts_program.moduleExportNestedTypeSpaceName(self.resolver.gpa, src, name, is_tsx);
        const type_only_pos = ts_program.moduleExportIsTypeOnly(self.resolver.gpa, src, name, is_tsx);
        const module_name = ts_program.renderModuleDisplayName(arena, r.path) catch return null;
        const export_path = if (type_only_pos != null) (arena.dupe(u8, r.path) catch return null) else "";
        return .{
            .module_name = module_name,
            .exported_type = exported,
            .cannot_be_named = cannot_be_named,
            .type_only_export = type_only_pos != null,
            .export_path = export_path,
            .export_pos = type_only_pos orelse 0,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer args_arena.deinit();
    const all_args = try init.minimal.args.toSlice(args_arena.allocator());

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    if (all_args.len > 1) {
        // Expand `@response-file` args (TS5083 / TS6045 on failure) before
        // option parsing, the way tsc does.
        expandResponseFiles(gpa, args_arena.allocator(), all_args[1..], &argv, 0);
    }

    // `tsc -b` / `tsc --build` (build mode) must be the FIRST argument.
    const is_build_mode = argv.items.len > 0 and
        (std.mem.eql(u8, argv.items[0], "-b") or std.mem.eql(u8, argv.items[0], "--build"));

    var opts: ts_cli.Options = undefined;
    var opts_files_owned = false;
    if (is_build_mode) {
        // Parse the build flags (TS5072/5073/5077/5094/6369/6370). Phase A:
        // on clean parse, build each project via the normal per-project
        // compile flow (full topological/incremental orchestration is a
        // follow-up). Non-dry `--clean` is not yet implemented.
        var bp = ts_cli.parseBuildArgs(gpa, argv.items[1..]) catch
            std.process.exit(@intFromEnum(ts_cli.ExitCode.internal_error));
        defer bp.deinit(gpa);
        var had_build_err = false;
        for (bp.diagnostics) |d| {
            std.debug.print("{s}\n", .{d});
            had_build_err = true;
        }
        if (had_build_err) std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
        if (bp.options.clean and !bp.options.dry) {
            std.debug.print("home tsc --build: '--clean' is not yet implemented.\n", .{});
            return;
        }
        // Resolve the project reference graph, check for cycles (TS6202),
        // then build every project in dependency order. "." / a directory
        // resolves to its tsconfig.json.
        const root_ref = if (bp.projects.len > 0) bp.projects[0] else ".";
        const root_cfg = resolveConfigPath(args_arena.allocator(), ".", root_ref) catch root_ref;
        const graph = loadBuildGraph(gpa, args_arena.allocator(), root_cfg) catch {
            std.debug.print("error: cannot load project '{s}'\n", .{root_cfg});
            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
        };
        if (graph.diagnostics.len > 0) {
            for (graph.diagnostics) |d| std.debug.print("{s}\n", .{d});
            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
        }
        var ord = ts_cli.topoSortProjects(gpa, graph.nodes) catch
            ts_cli.BuildOrder{ .order = &.{}, .cycle = null };
        defer ord.deinit(gpa);
        if (ord.cycle) |cyc| {
            const msg = ts_cli.projectReferenceCycleDiagnostic(gpa, cyc) catch
                std.process.exit(@intFromEnum(ts_cli.ExitCode.internal_error));
            defer gpa.free(msg);
            std.debug.print("{s}\n", .{msg});
            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
        }
        if (bp.options.verbose and graph.paths.len > 1) {
            // TS6355 — `Projects in this build: {0}` (the project list).
            buildStatusMessage(6355, "Projects in this build:\n", .{});
            for (graph.paths) |p| std.debug.print("    * {s}\n", .{p});
        }
        if (bp.options.clean and bp.options.dry) {
            var clean_outputs: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (clean_outputs.items) |p| gpa.free(p);
                clean_outputs.deinit(gpa);
            }
            for (ord.order) |pi| {
                try appendProjectCleanOutputs(gpa, args_arena.allocator(), graph.paths[pi], &clean_outputs);
            }
            printDryCleanOutputs(clean_outputs.items);
            return;
        }
        if (bp.options.dry) {
            for (ord.order) |pi| {
                const project_path = graph.paths[pi];
                switch (projectDryStatus(gpa, args_arena.allocator(), project_path)) {
                    .build => {
                        // TS6357 — dry build status for a project that would build.
                        buildStatusMessage(6357, "A non-dry build would build project '{s}'\n", .{project_path});
                    },
                    .update_timestamps => {
                        // TS6374 — dry build status for a timestamp-only pseudo build.
                        buildStatusMessage(6374, "A non-dry build would update timestamps for output of project '{s}'\n", .{project_path});
                    },
                    .up_to_date => {
                        // TS6361 — dry build status for a project that is already current.
                        buildStatusMessage(6361, "Project '{s}' is up to date\n", .{project_path});
                    },
                }
            }
            return;
        }
        // Build each project (dependencies first). The per-project builder
        // handles up-to-date checks unless `--force` is set.
        const BuildProjectStatus = enum { ok, errors, skipped };
        const project_status = try gpa.alloc(BuildProjectStatus, graph.paths.len);
        defer gpa.free(project_status);
        @memset(project_status, .ok);
        var build_had_errors = false;
        for (ord.order) |pi| {
            var blocked_dep: ?usize = null;
            var blocked_dep_status: BuildProjectStatus = .ok;
            for (graph.nodes[pi].deps) |dep| {
                if (project_status[dep] != .ok) {
                    blocked_dep = dep;
                    blocked_dep_status = project_status[dep];
                    break;
                }
            }
            if (blocked_dep) |dep| {
                if (bp.options.verbose) {
                    if (blocked_dep_status == .skipped) {
                        // TS6383 / TS6382 — transitive dependency was not built.
                        buildStatusMessage(6383, "Project '{s}' can't be built because its dependency '{s}' was not built\n", .{ graph.paths[pi], graph.paths[dep] });
                        buildStatusMessage(6382, "Skipping build of project '{s}' because its dependency '{s}' was not built\n", .{ graph.paths[pi], graph.paths[dep] });
                    } else {
                        // TS6363 / TS6362 — direct dependency has errors.
                        buildStatusMessage(6363, "Project '{s}' can't be built because its dependency '{s}' has errors\n", .{ graph.paths[pi], graph.paths[dep] });
                        buildStatusMessage(6362, "Skipping build of project '{s}' because its dependency '{s}' has errors\n", .{ graph.paths[pi], graph.paths[dep] });
                    }
                }
                project_status[pi] = .skipped;
                build_had_errors = true;
                continue;
            }
            if (buildOneProject(gpa, args_arena.allocator(), graph.paths[pi], bp.options.verbose, bp.options.force)) {
                project_status[pi] = .errors;
                build_had_errors = true;
            }
        }
        if (build_had_errors) std.process.exit(@intFromEnum(ts_cli.ExitCode.type_errors));
        return;
    } else {
        var parse_ctx: ts_cli.ParseContext = .{};
        opts = ts_cli.parseArgsCtx(gpa, argv.items, &parse_ctx) catch |err| {
            switch (err) {
                // TS6044: a non-boolean flag (e.g. `--outDir`) was the last
                // argument with no value following it.
                error.MissingValue => {
                    if (parse_ctx.missing_value_option.len > 0) {
                        const msg = ts_cli.compilerOptionExpectsArgumentDiagnostic(gpa, parse_ctx.missing_value_option) catch {
                            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
                        };
                        defer gpa.free(msg);
                        std.debug.print("{s}\n", .{msg});
                    } else {
                        std.debug.print("error parsing args: {s}\n", .{@errorName(err)});
                    }
                },
                error.ConfigOnlyOption => {
                    if (parse_ctx.config_only_option.len > 0) {
                        const msg = ts_cli.optionCanOnlyBeSpecifiedInTsconfigOrNullDiagnostic(gpa, parse_ctx.config_only_option) catch {
                            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
                        };
                        defer gpa.free(msg);
                        std.debug.print("{s}\n", .{msg});
                    } else {
                        std.debug.print("error parsing args: {s}\n", .{@errorName(err)});
                    }
                },
                error.ConfigOnlyBooleanOption => {
                    if (parse_ctx.config_only_option.len > 0) {
                        const msg = ts_cli.optionCanOnlyBeSpecifiedInTsconfigOrFalseOrNullDiagnostic(gpa, parse_ctx.config_only_option) catch {
                            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
                        };
                        defer gpa.free(msg);
                        std.debug.print("{s}\n", .{msg});
                    } else {
                        std.debug.print("error parsing args: {s}\n", .{@errorName(err)});
                    }
                },
                error.InvalidEnumOption => {
                    if (parse_ctx.enum_option.len > 0 and parse_ctx.enum_allowed_values.len > 0) {
                        const msg = ts_cli.argumentForOptionMustBeDiagnostic(gpa, parse_ctx.enum_option, parse_ctx.enum_allowed_values) catch {
                            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
                        };
                        defer gpa.free(msg);
                        std.debug.print("{s}\n", .{msg});
                    } else {
                        std.debug.print("error parsing args: {s}\n", .{@errorName(err)});
                    }
                },
                else => std.debug.print("error parsing args: {s}\n", .{@errorName(err)}),
            }
            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
        };
        opts_files_owned = true;

        // TS5093 / TS6369: a build-only option (or a non-first `--build`)
        // used in plain `tsc` mode.
        for (argv.items) |a| {
            if (ts_cli.buildOnlyOptionInNormalMode(a)) |bn| {
                const code: u32 = 5093;
                const msg = std.fmt.allocPrint(gpa, "error TS{d}: Compiler option '--{s}' may only be used with '--build'.", .{ code, bn }) catch
                    std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
                defer gpa.free(msg);
                std.debug.print("{s}\n", .{msg});
                std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
            }
            if (std.mem.eql(u8, a, "--build") or std.mem.eql(u8, a, "-b")) {
                const code: u32 = 6369;
                std.debug.print("error TS{d}: Option '--build' must be the first command line argument.\n", .{code});
                std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
            }
        }
    }
    defer if (opts_files_owned) gpa.free(opts.files);

    // TS5042: `--project` (or `-p`) cannot be combined with positional
    // source files. Mirrors upstream `internal/execute/tsc.go`.
    if (opts.project != null and opts.files.len > 0) {
        const msg = projectMixedWithSourceFilesDiagnostic(gpa) catch {
            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
        };
        defer gpa.free(msg);
        std.debug.print("{s}\n", .{msg});
        std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
    }

    // Resolve tsconfig BEFORE dispatch so a discovered tsconfig
    // counts as input for the "no files" check inside dispatch.
    // Explicit `--project <path>` wins; otherwise we walk upward
    // from cwd looking for the nearest `tsconfig.json`.
    var cfg_arena = std.heap.ArenaAllocator.init(gpa);
    defer cfg_arena.deinit();
    var cfg_path_buf: ?[]u8 = null;
    defer if (cfg_path_buf) |b| gpa.free(b);
    var loaded_cfg: ?tsconfig_mod.TsConfig = null;
    const explicit_project = opts.project;
    const should_load_config = opts.project != null or opts.files.len == 0 or opts.show_config;

    // For an explicit `--project`, validate existence the way upstream
    // does before resolving the config path: a path that names an
    // existing directory must contain a `tsconfig.json` (else TS5081);
    // a non-directory path is treated as a file and must exist (else
    // TS5058).
    if (explicit_project) |proj| {
        if (directoryExistsOnDisk(gpa, proj)) {
            const candidate = try std.fmt.allocPrint(gpa, "{s}/tsconfig.json", .{proj});
            defer gpa.free(candidate);
            if (!fileExistsOnDisk(gpa, candidate)) {
                const msg = try cannotFindTsConfigAtCurrentDirectoryDiagnostic(gpa, candidate);
                defer gpa.free(msg);
                std.debug.print("{s}\n", .{msg});
                std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
            }
        } else if (!fileExistsOnDisk(gpa, proj)) {
            const msg = try specifiedPathDoesNotExistDiagnostic(gpa, proj);
            defer gpa.free(msg);
            std.debug.print("{s}\n", .{msg});
            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
        }
    }

    if (should_load_config) {
        if (resolveTsConfigPath(gpa, opts.project) catch null) |path| {
            opts.project = path;
            cfg_path_buf = path;
        }
    }

    // Help is rendered from the compiler-options table (table-driven, so
    // the `--help` text stays in lockstep with the diagnostic catalogue).
    if (opts.show_help or opts.show_all_help) {
        const help = ts_cli.renderHelp(gpa, opts.show_all_help) catch {
            std.debug.print("{s}\n", .{ts_cli.helpText});
            return;
        };
        defer gpa.free(help);
        std.debug.print("{s}\n", .{help});
        return;
    }

    // `--init`: write a default tsconfig.json, or TS5054 if one exists.
    if (opts.init_config) {
        if (fileExistsOnDisk(gpa, "tsconfig.json")) {
            const msg = ts_cli.tsconfigAlreadyDefinedDiagnostic(gpa, "tsconfig.json") catch std.process.exit(1);
            defer gpa.free(msg);
            std.debug.print("{s}\n", .{msg});
            std.process.exit(1);
        }
        const tsconfig_text = ts_cli.defaultTsconfigContentsWithDiagnostics(gpa) catch std.process.exit(1);
        defer gpa.free(tsconfig_text);
        RealFs.write(gpa, "tsconfig.json", tsconfig_text) catch |err| {
            std.debug.print("error writing tsconfig.json: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        // TS6071 — tsc's `--init` success message (CategoryMessage).
        buildStatusMessage(6071, "Successfully created a tsconfig.json file.\n", .{});
        return;
    }

    const dec = ts_cli.dispatch(opts);
    if (dec.stdout_text.len > 0) {
        std.debug.print("{s}\n", .{dec.stdout_text});
    }
    if (dec.stderr_text.len > 0) {
        std.debug.print("{s}\n", .{dec.stderr_text});
    }
    if (dec.code != .success) std.process.exit(@intFromEnum(dec.code));

    if (opts.show_version or opts.show_help) return;

    // Load the discovered tsconfig. The JSONC parser aliases
    // strings into the source buffer, so cfg_src must outlive
    // `loaded_cfg`'s borrowed slices — keep it for the rest of
    // main rather than freeing inside this block.
    var cfg_src: []const u8 = &.{};
    defer if (cfg_src.len > 0) gpa.free(cfg_src);
    if (cfg_path_buf) |path| {
        cfg_src = RealFs.read(gpa, path) catch |err| blk: {
            std.debug.print("error reading {s}: {s}\n", .{ path, @errorName(err) });
            break :blk &.{};
        };
        if (cfg_src.len > 0) {
            loaded_cfg = tsconfig_mod.parseString(gpa, cfg_arena.allocator(), cfg_src) catch |err| blk: {
                std.debug.print("error parsing tsconfig {s}: {s}\n", .{ path, @errorName(err) });
                break :blk null;
            };
            if (loaded_cfg) |*c| c.file_path = path;
        }
    }

    if (loaded_cfg) |c| {
        if (try printConfigValidationDiagnostics(gpa, c)) {
            std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
        }
    }

    // Determine the file list. Precedence:
    //   1. positional args (CLI wins)
    //   2. tsconfig `files`: literal list, used as-is
    //   3. tsconfig `include` / `exclude`: glob-expanded against the
    //      tsconfig's directory; default ext filter is `.ts` / `.tsx`
    //      / `.d.ts` / `.mts` / `.cts` plus Home's `.hm` / `.home`.
    var input_files: std.ArrayListUnmanaged([]const u8) = .empty;
    var owned_paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        input_files.deinit(gpa);
        for (owned_paths.items) |p| gpa.free(p);
        owned_paths.deinit(gpa);
    }
    for (opts.files) |f| try input_files.append(gpa, f);
    if (input_files.items.len == 0) {
        if (loaded_cfg) |c| {
            if (c.files) |fs_list| for (fs_list) |f| try input_files.append(gpa, f);
        }
    }
    if (input_files.items.len == 0) {
        if (loaded_cfg) |c| {
            const project_dir = std.fs.path.dirname(c.file_path) orelse ".";
            const include_patterns = effectiveIncludePatterns(c);
            const exclude_patterns = effectiveExcludePatterns(c);
            try expandProjectGlobs(
                gpa,
                project_dir,
                include_patterns,
                exclude_patterns,
                &input_files,
                &owned_paths,
            );
        }
    }

    if (input_files.items.len == 0) {
        if (loaded_cfg) |c| {
            if (opts.files.len == 0) {
                if (c.files == null) {
                    const project_dir = std.fs.path.dirname(c.file_path) orelse ".";
                    var exclude_display_list: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer exclude_display_list.deinit(gpa);
                    var owned_out_dir_exclude: ?[]u8 = null;
                    defer if (owned_out_dir_exclude) |p| gpa.free(p);
                    const exclude_display_patterns = try effectiveExcludeDiagnosticPatterns(
                        gpa,
                        project_dir,
                        c,
                        &exclude_display_list,
                        &owned_out_dir_exclude,
                    );
                    const msg = try noInputsFoundInConfigDiagnostic(
                        gpa,
                        c.file_path,
                        effectiveIncludePatterns(c),
                        exclude_display_patterns,
                    );
                    defer gpa.free(msg);
                    std.debug.print("{s}\n", .{msg});
                    std.process.exit(2);
                }
                if (c.files) |files| {
                    if (files.len == 0 and c.references.len == 0 and !c.has_extends) {
                        std.debug.print("error TS{d}: The 'files' list in config file '{s}' is empty.\n", .{ ts_empty_files_list_in_config, c.file_path });
                        std.process.exit(2);
                    }
                }
            }
        }
        std.debug.print("error: no input files; pass paths or --project=<path>\n", .{});
        std.process.exit(2);
    }

    // §4.A.12 — read-side of `.tsbuildinfo` round-trip. When
    // `compilerOptions.incremental` is on and a prior buildinfo
    // exists, parse it and surface a one-liner so callers can see
    // the round-trip is wired. Actually skipping unchanged files
    // is a follow-up — for now we just demonstrate the read path
    // can be invoked without breaking the pipeline.
    if (loaded_cfg) |cfg_ptr| {
        const want_buildinfo = cfg_ptr.compiler_options.incremental orelse false;
        if (want_buildinfo) {
            const out_dir_for_read: ?[]const u8 = opts.out_dir orelse blk: {
                if (cfg_ptr.compiler_options.out_dir) |d| break :blk d;
                break :blk null;
            };
            const bi_path: ?[]u8 = blk: {
                if (cfg_ptr.compiler_options.ts_buildinfo_file) |p| break :blk gpa.dupe(u8, p) catch null;
                break :blk if (out_dir_for_read) |od|
                    std.fs.path.join(gpa, &.{ od, "tsconfig.tsbuildinfo" }) catch null
                else
                    gpa.dupe(u8, "tsconfig.tsbuildinfo") catch null;
            };
            if (bi_path) |p| {
                defer gpa.free(p);
                if (RealFs.read(gpa, p)) |bi_src| {
                    defer gpa.free(bi_src);
                    if (ts_emit.tsbuildinfo.read(gpa, bi_src)) |info_const| {
                        var info = info_const;
                        defer info.deinit(gpa);
                        std.debug.print("home tsc: loaded incremental info ({d} previously-compiled files)\n", .{info.file_names.len});
                    } else |_| {}
                } else |_| {}
            }
        }
    }

    var resolver_fs = ResolverRealFs{};
    var resolver = ts_resolver.Resolver.init(gpa, resolver_fs.fs(), .{});
    defer resolver.deinit();

    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();

    // §file-add — extension gate. tsc rejects an input file whose
    // extension it cannot process before it ever reads the file:
    // a JavaScript file without `allowJs` is TS6504; any other
    // unsupported extension is TS6054. (`allowNonTsExtensions` — the
    // upstream escape hatch — has no CLI surface in Home yet, so the
    // check always runs.)
    const allow_js: bool = blk: {
        if (loaded_cfg) |c| break :blk (c.compiler_options.allow_js orelse false);
        break :blk false;
    };
    var extension_errors: bool = false;
    for (input_files.items) |path| {
        switch (classifyExtension(path)) {
            .supported => {},
            .javascript => {
                if (!allow_js) {
                    const msg = try javaScriptFileNeedsAllowJsDiagnostic(gpa, path);
                    defer gpa.free(msg);
                    std.debug.print("{s}\n", .{msg});
                    extension_errors = true;
                }
            },
            .unsupported => {
                const msg = try unsupportedExtensionDiagnostic(gpa, path);
                defer gpa.free(msg);
                std.debug.print("{s}\n", .{msg});
                extension_errors = true;
            },
        }
    }
    if (extension_errors) std.process.exit(1);

    for (input_files.items) |path| {
        const src = RealFs.read(gpa, path) catch |err| {
            std.debug.print("error reading {s}: {s}\n", .{ path, @errorName(err) });
            std.process.exit(1);
        };
        defer gpa.free(src);
        _ = program.add(path, src) catch |err| {
            std.debug.print("error adding file: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    var compile_opts: ts_driver.CompileOptions = if (loaded_cfg) |*c|
        ts_driver.optionsFromConfig(c)
    else
        .{};
    compile_opts.strict = opts.strict;
    compile_opts.no_emit = opts.no_emit;
    var resolver_adapter = CheckerResolverAdapter{ .resolver = &resolver };
    compile_opts.external_resolver = .{
        .ptr = &resolver_adapter,
        .vtable = &CheckerResolverAdapter.vtable,
    };

    // Build the transitive import closure (like tsc's file loader) so
    // every reachable file participates in the program. This is what
    // lets `--explainFiles` report imported files with their TS1393
    // "Imported via … from file …" reason. Best-effort: resolution gaps
    // simply leave the program partial, as they did before.
    _ = program.loadImportClosure(compile_opts) catch {};

    // §2.1 — `--listFiles` / `--listFilesOnly`. Print every input
    // path the program will compile. `--listFilesOnly` exits before
    // running the pipeline; `--listFiles` continues afterward.
    if (opts.list_files or opts.list_files_only) {
        for (input_files.items) |path| {
            std.debug.print("{s}\n", .{path});
        }
        if (opts.list_files_only) return;
    }

    // §2.1 — `--showConfig`. Print a minimal JSON view of the
    // resolved tsconfig + the discovered file list. Then exit.
    if (opts.show_config) {
        std.debug.print("{{\n", .{});
        std.debug.print("  \"compileOnSave\": false,\n", .{});
        std.debug.print("  \"compilerOptions\": {{\n", .{});
        if (loaded_cfg) |c| {
            const co = c.compiler_options;
            if (co.target) |t| std.debug.print("    \"target\": \"{s}\",\n", .{@tagName(t)});
            if (co.module) |m| std.debug.print("    \"module\": \"{s}\",\n", .{@tagName(m)});
            if (co.out_dir) |d| std.debug.print("    \"outDir\": \"{s}\",\n", .{d});
            if (co.strict) |s| std.debug.print("    \"strict\": {s},\n", .{if (s) "true" else "false"});
            if (co.declaration) |d| std.debug.print("    \"declaration\": {s},\n", .{if (d) "true" else "false"});
        }
        std.debug.print("  }},\n", .{});
        std.debug.print("  \"files\": [\n", .{});
        for (input_files.items, 0..) |path, i| {
            std.debug.print("    \"{s}\"{s}\n", .{ path, if (i + 1 < input_files.items.len) "," else "" });
        }
        std.debug.print("  ]\n", .{});
        std.debug.print("}}\n", .{});
        return;
    }

    // Stream diagnostics as each file finishes compiling. Brings
    // time-to-first-diagnostic down from whole-program time to
    // per-file check time — Phase 5 §5.8 / §5.A.10.
    var any_errors_streaming: bool = false;
    // Default ANSI colors on when stdout is a TTY; off when piped/redirected.
    const stdout_is_tty: bool = blk: {
        var tty_threaded = std.Io.Threaded.init(gpa, .{});
        defer tty_threaded.deinit();
        const tty_io = tty_threaded.io();
        const stdout = std.Io.File.stdout();
        break :blk stdout.isTty(tty_io) catch false;
    };
    var stream_error_count: usize = 0;
    var stream_files_with_errors: usize = 0;
    var stream_first_error_file: []const u8 = "";
    var stream_first_error_line: usize = 0;
    var stream_first_error_col: usize = 0;
    var stream_ctx: StreamCtx = .{
        .gpa = gpa,
        .program = &program,
        .use_pretty = opts.pretty orelse true,
        .use_color = stdout_is_tty,
        .any_errors = &any_errors_streaming,
        .error_count = &stream_error_count,
        .files_with_errors = &stream_files_with_errors,
        .first_error_file = &stream_first_error_file,
        .first_error_line = &stream_first_error_line,
        .first_error_col = &stream_first_error_col,
    };
    if (opts.watch) {
        buildStatusMessage(6031, "Starting compilation in watch mode...\n", .{});
    }
    program.compileAllStreaming(compile_opts, &stream_ctx, streamDiagsCallback) catch |err| {
        std.debug.print("compile error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (loaded_cfg) |c| {
        if (c.compiler_options.composite orelse false) {
            const composite_summary = printCompositeProjectFileListDiagnostics(
                gpa,
                &program,
                input_files.items,
                c.file_path,
                opts.pretty orelse true,
                stdout_is_tty,
            );
            if (composite_summary.error_count > 0) {
                any_errors_streaming = true;
                stream_error_count += composite_summary.error_count;
                stream_files_with_errors += composite_summary.files_with_errors;
                if (stream_first_error_file.len == 0) {
                    stream_first_error_file = composite_summary.first_error_file;
                    stream_first_error_line = composite_summary.first_error_line;
                    stream_first_error_col = composite_summary.first_error_col;
                }
            }
        }
    }
    // tsc's post-compilation summary (CategoryMessage). Non-watch
    // compiles stay silent when clean; watch compiles always report
    // the TS6193/TS6194 "Watching for file changes" status. For
    // non-watch errors, tsc picks the message by error-and-file count:
    // 1 error → TS6259 in one file else TS6216; many errors across >1
    // files → TS6261; otherwise TS6217.
    if (opts.watch) {
        reportWatchErrorStatus(stream_error_count);
    } else if (stream_error_count == 1) {
        if (stream_files_with_errors == 1 and stream_first_error_file.len != 0) {
            buildStatusMessage(6259, "Found 1 error in {s}\n", .{stream_first_error_file});
        } else {
            buildStatusMessage(6216, "Found 1 error.\n", .{});
        }
    } else if (stream_error_count > 1) {
        if (stream_files_with_errors > 1) {
            buildStatusMessage(6261, "Found {d} errors in {d} files.\n", .{ stream_error_count, stream_files_with_errors });
        } else if (stream_files_with_errors == 1 and stream_first_error_file.len != 0) {
            buildStatusMessage(6260, "Found {d} errors in the same file, starting at: {s}:{d}\n", .{ stream_error_count, stream_first_error_file, stream_first_error_line });
        } else {
            buildStatusMessage(6217, "Found {d} errors.\n", .{stream_error_count});
        }
    }

    // `--explainFiles`: list every file with its inclusion reason. Input
    // files in a run come from one source (CLI args XOR tsconfig `files`
    // XOR include globs), so the root reason is uniform.
    if (opts.explain_files) {
        var root_incl: RootInclusion = .{ .code = 1427 };
        if (opts.files.len == 0) {
            if (loaded_cfg) |c| {
                if (c.files != null) {
                    root_incl.code = 1409; // Part of 'files' list
                } else if (c.include == null) {
                    root_incl.code = 1457; // Matched by default **/* pattern
                } else {
                    root_incl.code = 1407; // Matched by include pattern
                    root_incl.spec = if (c.include.?.len > 0) c.include.?[0] else "**/*";
                    root_incl.config_path = c.file_path;
                }
            }
        }
        printExplainFiles(gpa, &program, input_files.items, root_incl);
    }

    // Resolve outDir from CLI or tsconfig. CLI wins.
    const out_dir: ?[]const u8 = opts.out_dir orelse blk: {
        if (loaded_cfg) |c| if (c.compiler_options.out_dir) |d| break :blk d;
        break :blk null;
    };

    // Resolve `declaration` from CLI or tsconfig. CLI wins.
    const emit_dts: bool = blk: {
        if (opts.declaration) |d| break :blk d;
        if (loaded_cfg) |c| if (c.compiler_options.declaration) |d| break :blk d;
        break :blk false;
    };

    // Resolve `sourceMap` from CLI or tsconfig. CLI wins.
    const emit_source_map: bool = blk: {
        if (opts.source_map) |s| break :blk s;
        if (loaded_cfg) |c| if (c.compiler_options.source_map) |s| break :blk s;
        break :blk false;
    };

    // Resolve `declarationMap` from CLI or tsconfig. CLI wins. Has no
    // effect unless `declaration` emission is also on (matches tsc).
    const emit_decl_map: bool = blk: {
        if (opts.declaration_map) |d| break :blk d;
        if (loaded_cfg) |c| if (c.compiler_options.declaration_map) |d| break :blk d;
        break :blk false;
    };

    // Declaration output dir: tsconfig `declarationDir` if set,
    // otherwise alongside the .js (which itself respects outDir).
    const declaration_dir: ?[]const u8 = blk: {
        if (loaded_cfg) |c| if (c.compiler_options.declaration_dir) |d| break :blk d;
        break :blk out_dir;
    };

    // Diagnostics already printed above by the streaming callback;
    // this loop only handles JS / .d.ts emission. The streaming
    // any-errors flag flows into the final exit-code decision.
    var any_errors = any_errors_streaming;

    // TS5055/5056: before emitting, verify no output file would overwrite
    // an input file or be written twice (tsc's `verifyEmitFilePath`). Such
    // outputs are blocked from emit and reported.
    var blocked_outputs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (blocked_outputs.items) |b| gpa.free(b);
        blocked_outputs.deinit(gpa);
    }
    if (!opts.no_emit) {
        var inputs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer inputs.deinit(gpa);
        var outputs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (outputs.items) |o| gpa.free(o);
            outputs.deinit(gpa);
        }
        for (program.files.items) |f| {
            try inputs.append(gpa, f.path);
            if (f.compilation == null) continue;
            try outputs.append(gpa, try computeOutPath(gpa, f.path, out_dir, ".js"));
            if (emit_dts) try outputs.append(gpa, try computeOutPath(gpa, f.path, declaration_dir, ".d.ts"));
        }
        const cols = try ts_cli.detectOutputCollisions(gpa, inputs.items, outputs.items, loaded_cfg != null);
        defer gpa.free(cols);
        for (cols) |col| {
            const msg = try ts_cli.formatOutputCollision(gpa, col);
            defer gpa.free(msg);
            std.debug.print("{s}\n", .{msg});
            try blocked_outputs.append(gpa, try gpa.dupe(u8, col.output_path));
        }
        if (cols.len > 0) any_errors = true;
    }

    for (program.files.items) |f| {
        const c = f.compilation orelse continue;
        if (opts.no_emit) continue;
        const out_path = try computeOutPath(gpa, f.path, out_dir, ".js");
        defer gpa.free(out_path);
        // Skip files whose output was blocked by the TS5055/5056 check.
        if (pathInList(blocked_outputs.items, out_path)) continue;

        // §4.A.13 — when sourceMap is enabled, re-emit through a
        // Printer hooked up to a SourceMap so the printer records
        // mappings as it streams. The compileSource path produced
        // `c.js` without mappings, so we discard it here in favor
        // of the freshly-emitted bytes that include the trailing
        // `//# sourceMappingURL=…` comment.
        var sm_owned_js: ?[]u8 = null;
        defer if (sm_owned_js) |b| gpa.free(b);
        var sm_owned_map: ?[]u8 = null;
        defer if (sm_owned_map) |b| gpa.free(b);
        var sm_map_path_owned: ?[]u8 = null;
        defer if (sm_map_path_owned) |b| gpa.free(b);

        if (emit_source_map) {
            const map_path = std.fmt.allocPrint(gpa, "{s}.map", .{out_path}) catch unreachable;
            sm_map_path_owned = map_path;
            const map_basename = std.fs.path.basename(map_path);
            const out_basename = std.fs.path.basename(out_path);
            var sm = ts_emit.SourceMap.init(gpa, out_basename);
            defer sm.deinit();
            const src_idx = sm.addSource(f.path, f.source) catch 0;

            var emit_options = compile_opts.emit;
            emit_options.source_map = &sm;
            emit_options.source_map_src_idx = src_idx;
            emit_options.source_map_url = map_basename;

            var printer = ts_emit.Printer.init(gpa, &c.hir, &c.interner, emit_options);
            defer printer.deinit();
            printer.setSource(f.source);
            printer.printSourceFile(c.root) catch |err| {
                std.debug.print("warning: source-map emit failed for {s}: {s}\n", .{ f.path, @errorName(err) });
            };
            sm_owned_js = printer.toOwnedSlice() catch null;
            sm_owned_map = sm.toJson() catch null;
        }

        const js_bytes: []const u8 = sm_owned_js orelse c.js;
        writeOrDie(gpa, out_path, js_bytes);
        if (emit_source_map) {
            const map_bytes: []const u8 = sm_owned_map orelse "{}";
            const map_path = sm_map_path_owned.?;
            writeOrDie(gpa, map_path, map_bytes);
        }

        if (emit_dts) {
            var emitter = ts_emit.DtsEmitter.initWithTypes(gpa, &c.hir, &c.interner, &c.type_interner, .{});
            defer emitter.deinit();
            emitter.emitSourceFile(c.root) catch |err| {
                std.debug.print("error emitting d.ts for {s}: {s}\n", .{ f.path, @errorName(err) });
                continue;
            };
            const dts_bytes = emitter.toOwnedSlice() catch continue;
            defer gpa.free(dts_bytes);
            const dts_path = try computeOutPath(gpa, f.path, declaration_dir, ".d.ts");
            defer gpa.free(dts_path);
            writeOrDie(gpa, dts_path, dts_bytes);

            // §4.A.x — when `declarationMap` is on, write a parallel
            // `.d.ts.map` next to the `.d.ts`. v0 emits Source Map V3
            // framing only (empty `mappings`); the symbol-driven
            // re-printer fills in real positions later. Reuses
            // `d_hm.renderDeclarationMap` since the format is shared
            // between `.d.hm.map` and `.d.ts.map`.
            if (emit_decl_map) {
                const dts_basename = std.fs.path.basename(dts_path);
                const map_bytes = d_hm.renderDeclarationMap(
                    gpa,
                    f.path,
                    .{ .file = dts_basename },
                ) catch |err| blk: {
                    std.debug.print("warning: declaration-map render failed for {s}: {s}\n", .{ f.path, @errorName(err) });
                    break :blk null;
                };
                if (map_bytes) |mb| {
                    defer gpa.free(mb);
                    const map_path = try std.fmt.allocPrint(gpa, "{s}.map", .{dts_path});
                    defer gpa.free(map_path);
                    writeOrDie(gpa, map_path, mb);
                }
            }
        }
    }

    // §4.A.12 — write `.tsbuildinfo` when `compilerOptions.incremental: true`.
    if (loaded_cfg) |cfg_ptr| {
        const want_buildinfo = cfg_ptr.compiler_options.incremental orelse false;
        if (want_buildinfo) {
            // File names + per-file content-version (sha-1 over source).
            var file_names: std.ArrayListUnmanaged([]const u8) = .empty;
            defer file_names.deinit(gpa);
            var file_infos: std.ArrayListUnmanaged(ts_emit.tsbuildinfo.FileInfo) = .empty;
            defer {
                for (file_infos.items) |fi| gpa.free(fi.version);
                file_infos.deinit(gpa);
            }
            for (program.files.items) |f| {
                try file_names.append(gpa, f.path);
                var hasher = std.crypto.hash.Sha1.init(.{});
                hasher.update(f.source);
                var digest: [20]u8 = undefined;
                hasher.final(&digest);
                const hex = try gpa.alloc(u8, digest.len * 2);
                const hex_chars = "0123456789abcdef";
                for (digest, 0..) |b, i| {
                    hex[i * 2] = hex_chars[b >> 4];
                    hex[i * 2 + 1] = hex_chars[b & 0x0F];
                }
                try file_infos.append(gpa, .{ .version = hex });
            }
            const buildinfo = ts_emit.tsbuildinfo.emit(
                gpa,
                file_names.items,
                file_infos.items,
                "{}", // options blob: tsc serialises a few normalized options here; placeholder
                .{},
            ) catch null;
            if (buildinfo) |bi| {
                defer gpa.free(bi);
                const bi_path: []const u8 = blk: {
                    if (cfg_ptr.compiler_options.ts_buildinfo_file) |p| break :blk p;
                    break :blk if (out_dir) |od|
                        try std.fs.path.join(gpa, &.{ od, "tsconfig.tsbuildinfo" })
                    else
                        try gpa.dupe(u8, "tsconfig.tsbuildinfo");
                };
                defer if (cfg_ptr.compiler_options.ts_buildinfo_file == null) gpa.free(bi_path);
                RealFs.write(gpa, bi_path, bi) catch |err| {
                    std.debug.print("warning: could not write {s}: {s}\n", .{ bi_path, @errorName(err) });
                };
            }
        }
    }

    if (opts.watch) {
        // §5.A.5 — polling watch loop driven by `ts_watch.Watcher`
        // over `RealStatFs`. Each tick compares mtime+size for every
        // tracked path and reports a `ChangeSet`; we re-read, update
        // the program, recompile changed files, and re-emit JS.
        // Native FS-event backends (FSEvents/inotify/ReadDirChangesW)
        // are tracked separately.
        var watch_threaded = std.Io.Threaded.init(gpa, .{});
        defer watch_threaded.deinit();
        const watch_io = watch_threaded.io();
        var rfs = ts_watch.RealStatFs.init(gpa);
        defer rfs.deinit();
        var watcher = ts_watch.Watcher.init(gpa, rfs.fs());
        defer watcher.deinit();
        // Pre-populate the tracked set so the first tick records a
        // real baseline rather than reporting every input as added.
        for (input_files.items) |path| {
            try watcher.track(path);
        }
        while (true) {
            // Inter-poll pause: 100ms via `std.Io.Clock.Duration.sleep`.
            // A platform-native FS-event backend (FSEvents/inotify/
            // ReadDirChangesW) is the right long-term replacement and
            // is tracked as Phase 5 §5.A.5.
            std.Io.Clock.Duration.sleep(.{
                .clock = .boot,
                .raw = .fromNanoseconds(100 * std.time.ns_per_ms),
            }, watch_io) catch {};
            var change_set = watcher.tick() catch |err| {
                std.debug.print("watch error: {s}\n", .{@errorName(err)});
                continue;
            };
            defer change_set.deinit(gpa);
            if (change_set.isEmpty()) continue;

            var changed: std.ArrayListUnmanaged([]const u8) = .empty;
            defer changed.deinit(gpa);
            for (change_set.changes.items) |ch| {
                if (ch.kind == .removed) continue;
                const src = RealFs.read(gpa, ch.path) catch |err| {
                    std.debug.print("error reading {s}: {s}\n", .{ ch.path, @errorName(err) });
                    continue;
                };
                defer gpa.free(src);
                // `updateSource` dupes the buffer internally.
                _ = program.updateSource(ch.path, src) catch |err| {
                    std.debug.print("error updating source {s}: {s}\n", .{ ch.path, @errorName(err) });
                    continue;
                };
                // The watcher's tracked-set keys are owned strings
                // independent of `input_files`, so it's safe to
                // borrow the input_files slice here for re-emit.
                const path_borrow = blk: {
                    for (input_files.items) |p| {
                        if (std.mem.eql(u8, p, ch.path)) break :blk p;
                    }
                    break :blk ch.path;
                };
                try changed.append(gpa, path_borrow);
            }
            if (changed.items.len == 0) continue;
            buildStatusMessage(6032, "File change detected. Starting incremental compilation...\n", .{});
            _ = program.recompileChanged(changed.items, compile_opts) catch |err| {
                std.debug.print("recompile error: {s}\n", .{@errorName(err)});
                continue;
            };
            var watch_any_errors = false;
            var watch_error_count: usize = 0;
            var watch_stream_ctx: StreamCtx = .{
                .gpa = gpa,
                .program = &program,
                .use_pretty = opts.pretty orelse true,
                .use_color = stdout_is_tty,
                .any_errors = &watch_any_errors,
                .error_count = &watch_error_count,
            };
            for (changed.items) |path| {
                const file_id = program.lookupPath(path) orelse continue;
                const f = program.fileById(file_id);
                const c = f.compilation orelse continue;
                streamDiagsCallback(&watch_stream_ctx, path, c.diagnostics.items);
            }
            reportWatchErrorStatus(watch_error_count);
            // Re-emit each changed file's JS to disk.
            for (changed.items) |path| {
                const file_id = program.lookupPath(path) orelse continue;
                const f = program.fileById(file_id);
                const c = f.compilation orelse continue;
                if (opts.no_emit) continue;
                const out_path = computeOutPath(gpa, path, out_dir, ".js") catch continue;
                defer gpa.free(out_path);
                writeOrDie(gpa, out_path, c.js);
            }
        }
    }

    if (any_errors) std.process.exit(1);
}

fn mapPhaseToCode(phase: ts_driver.Diagnostic.Phase) u32 {
    return switch (phase) {
        .lex, .parse => 1109,
        .bind => 2304,
        .emit => 5024,
    };
}

/// Context carried through `Program.compileAllStreaming`'s
/// per-file callback. `program` lets the callback resolve
/// the file's source bytes for line/col rendering; `any_errors`
/// is OR'd from each file's non-emit-phase diagnostics so the
/// final exit code reflects what's been streamed.
const StreamCtx = struct {
    gpa: std.mem.Allocator,
    program: *const ts_program.Program,
    use_pretty: bool,
    use_color: bool,
    any_errors: *bool,
    /// Running count of non-emit diagnostics, for the TS6216/TS6217
    /// "Found N errors" summary. Optional so the build-mode caller can
    /// skip it.
    error_count: ?*usize = null,
    /// Count of distinct files that had at least one error, and the
    /// path of the first such file — for the per-file summary variants
    /// TS6259 ("Found 1 error in {0}") / TS6261 ("Found {0} errors in
    /// {1} files.").
    files_with_errors: ?*usize = null,
    first_error_file: ?*[]const u8 = null,
    /// Line/col of the first error, for TS6260's "starting at:" anchor.
    first_error_line: ?*usize = null,
    first_error_col: ?*usize = null,
};

/// Invoked once per compiled file, in compilation order. Renders
/// every diagnostic via the same formatter the post-compile loop
/// used to use, but earlier — diagnostics for file 0 surface before
/// file N has even been parsed.
fn streamDiagsCallback(ctx: *StreamCtx, file_path: []const u8, diags: []const ts_driver.Diagnostic) void {
    const fid = ctx.program.lookupPath(file_path) orelse return;
    const f = ctx.program.fileById(fid);
    var file_had_error = false;
    for (diags) |d| {
        const pos = ts_diagnostics.positionToLineCol(f.source, d.pos);
        const code = if (d.code != 0) d.code else mapPhaseToCode(d.phase);
        const prefix: ts_diagnostics.Diagnostic.CodePrefix = switch (d.code_prefix) {
            .TS => .TS,
            .HM => .HM,
        };
        // Map the driver's nested elaboration chain (tsc `messageChain`)
        // into the renderer's chain so it surfaces as indented
        // continuation lines under the header. Allocated in an arena tied
        // to this diagnostic's render; freed right after.
        var chain_arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer chain_arena.deinit();
        const rendered_chain = mapDriverChain(chain_arena.allocator(), d.chain) catch &.{};
        const rendered_related = mapDriverRelated(chain_arena.allocator(), ctx.program, f, d.related) catch &.{};
        const fdiag: ts_diagnostics.Diagnostic = .{
            .file = f.path,
            .line = pos.line,
            .col = pos.col,
            .code = code,
            .code_prefix = prefix,
            .severity = .err,
            .message = d.message,
            .span_len = 0,
            .chain = rendered_chain,
            .related = rendered_related,
        };
        const formatted = if (ctx.use_pretty)
            ts_diagnostics.formatPretty(ctx.gpa, fdiag, f.source, ctx.use_color) catch continue
        else
            ts_diagnostics.formatDefault(ctx.gpa, fdiag) catch continue;
        defer ctx.gpa.free(formatted);
        std.debug.print("{s}\n", .{formatted});
        if (d.phase != .emit) {
            ctx.any_errors.* = true;
            if (ctx.error_count) |ec| ec.* += 1;
            if (!file_had_error) {
                file_had_error = true;
                if (ctx.files_with_errors) |fc| fc.* += 1;
                if (ctx.first_error_file) |fe| {
                    if (fe.*.len == 0) {
                        fe.* = f.path;
                        if (ctx.first_error_line) |fl| fl.* = pos.line;
                        if (ctx.first_error_col) |fcol| fcol.* = pos.col;
                    }
                }
            }
        }
    }
}

/// Recursively map a driver elaboration chain into the renderer's
/// `ChainEntry` shape (message + children only; the renderer flattens
/// tsc-style without re-printing the per-entry code). Allocated in the
/// caller's arena.
fn mapDriverChain(
    arena: std.mem.Allocator,
    chain: []const ts_driver.DiagnosticChainEntry,
) error{OutOfMemory}![]const ts_diagnostics.ChainEntry {
    if (chain.len == 0) return &.{};
    const out = try arena.alloc(ts_diagnostics.ChainEntry, chain.len);
    for (chain, 0..) |entry, i| {
        out[i] = .{
            .message = entry.message,
            .children = try mapDriverChain(arena, entry.children),
        };
    }
    return out;
}

/// Map a driver diagnostic's related-info anchors into the renderer's
/// shape, resolving each anchor's byte `pos` to line:col against the
/// right file source. A null `file` anchors in the diagnostic's own file
/// (`primary`); a non-null `file` is a cross-file anchor (e.g. TS1377)
/// looked up in the program. If the cross-file source isn't available,
/// the anchor still renders its message (location omitted). Allocated in
/// the caller's arena.
fn mapDriverRelated(
    arena: std.mem.Allocator,
    program: *const ts_program.Program,
    primary: *const ts_program.File,
    related: []const ts_driver.RelatedInfo,
) error{OutOfMemory}![]const ts_diagnostics.Related {
    if (related.len == 0) return &.{};
    const out = try arena.alloc(ts_diagnostics.Related, related.len);
    for (related, 0..) |r, i| {
        const prefix: ts_diagnostics.Diagnostic.CodePrefix = switch (r.code_prefix) {
            .TS => .TS,
            .HM => .HM,
        };
        // Resolve the anchor's file + source.
        var anchor_file: []const u8 = primary.path;
        var anchor_source: ?[]const u8 = primary.source;
        if (r.file) |rf| {
            anchor_file = rf;
            if (program.lookupPath(rf)) |afid| {
                anchor_source = program.fileById(afid).source;
            } else {
                anchor_source = null; // source unavailable — omit location
            }
        }
        if (anchor_source) |src| {
            const lc = ts_diagnostics.positionToLineCol(src, r.pos);
            out[i] = .{ .file = anchor_file, .line = lc.line, .col = lc.col, .code = r.code, .code_prefix = prefix, .message = r.message };
        } else {
            out[i] = .{ .file = "", .code = r.code, .code_prefix = prefix, .message = r.message };
        }
    }
    return out;
}

/// Walk `project_dir` recursively, collect every TypeScript-shaped
/// file whose path (relative to the project) matches at least one
/// `include` glob and no `exclude` glob. Owned paths are stored in
/// `owned` so the caller can free them after compilation; borrowed
/// `[]const u8` slices into those owned bytes are appended to
/// `out`. Mirrors the file shapes tsc accepts by default (no
/// `allowJs` yet).
fn expandProjectGlobs(
    gpa: std.mem.Allocator,
    project_dir: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
    owned: *std.ArrayListUnmanaged([]u8),
) !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, project_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var stack: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stack.items) |s| gpa.free(s);
        stack.deinit(gpa);
    }
    try stack.append(gpa, try gpa.dupe(u8, ""));

    while (stack.items.len > 0) {
        const rel = stack.pop().?;
        defer gpa.free(rel);

        const subdir_path = if (rel.len == 0)
            try gpa.dupe(u8, project_dir)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ project_dir, rel });
        defer gpa.free(subdir_path);

        var sub = cwd.openDir(io, subdir_path, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var iter = sub.iterate();
        while (iter.next(io) catch null) |entry| {
            const child_rel = if (rel.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name });

            switch (entry.kind) {
                .directory => {
                    // Skip dotfiles and node_modules so we don't walk
                    // into massive trees by default.
                    if (std.mem.startsWith(u8, entry.name, ".") or
                        std.mem.eql(u8, entry.name, "node_modules"))
                    {
                        gpa.free(child_rel);
                        continue;
                    }
                    if (anyMatches(exclude, child_rel)) {
                        gpa.free(child_rel);
                        continue;
                    }
                    try stack.append(gpa, child_rel);
                },
                .file => {
                    defer gpa.free(child_rel);
                    if (!isTsLikeExtension(child_rel)) continue;
                    if (anyMatches(exclude, child_rel)) continue;
                    if (!anyMatches(include, child_rel)) continue;
                    const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ project_dir, child_rel });
                    try owned.append(gpa, full);
                    try out.append(gpa, full);
                },
                else => gpa.free(child_rel),
            }
        }
    }
}

fn anyMatches(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |pat| {
        if (tsconfig_mod.matchGlob(pat, path)) return true;
    }
    return false;
}

fn isTsLikeExtension(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".d.ts")) return true;
    if (std.mem.endsWith(u8, path, ".d.hm")) return true;
    if (std.mem.endsWith(u8, path, ".d.home")) return true;
    if (std.mem.endsWith(u8, path, ".ts")) return true;
    if (std.mem.endsWith(u8, path, ".tsx")) return true;
    if (std.mem.endsWith(u8, path, ".mts")) return true;
    if (std.mem.endsWith(u8, path, ".cts")) return true;
    if (std.mem.endsWith(u8, path, ".hm")) return true;
    if (std.mem.endsWith(u8, path, ".home")) return true;
    return false;
}

fn effectiveIncludePatterns(cfg: tsconfig_mod.TsConfig) []const []const u8 {
    return cfg.include orelse &[_][]const u8{"**/*"};
}

fn effectiveExcludePatterns(cfg: tsconfig_mod.TsConfig) []const []const u8 {
    return cfg.exclude orelse &.{};
}

fn effectiveExcludeDiagnosticPatterns(
    gpa: std.mem.Allocator,
    project_dir: []const u8,
    cfg: tsconfig_mod.TsConfig,
    out: *std.ArrayListUnmanaged([]const u8),
    owned_out_dir: *?[]u8,
) ![]const []const u8 {
    if (cfg.exclude) |exclude| return exclude;
    const out_dir = cfg.compiler_options.out_dir orelse return &.{};
    const display = if (std.fs.path.isAbsolute(out_dir))
        out_dir
    else blk: {
        const joined = try std.fs.path.join(gpa, &.{ project_dir, out_dir });
        owned_out_dir.* = joined;
        break :blk joined;
    };
    try out.append(gpa, display);
    return out.items;
}

/// TS5042: `--project` cannot be combined with positional source files.
/// Faithful port of the check in upstream `internal/execute/tsc.go`.
fn projectMixedWithSourceFilesDiagnostic(gpa: std.mem.Allocator) ![]u8 {
    const code: u32 = 5042;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: Option 'project' cannot be mixed with source files on a command line.",
        .{code},
    );
}

/// TS5058: an explicit `--project` path (treated as a file because it
/// isn't an existing directory) does not exist on disk.
fn specifiedPathDoesNotExistDiagnostic(gpa: std.mem.Allocator, file_or_directory: []const u8) ![]u8 {
    const code: u32 = 5058;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: The specified path does not exist: '{s}'.",
        .{ code, file_or_directory },
    );
}

/// TS5081: `--project` named an existing directory but it has no
/// `tsconfig.json`. (Upstream uses the "current directory" message here
/// with the resolved `tsconfig.json` path as the argument.)
fn cannotFindTsConfigAtCurrentDirectoryDiagnostic(gpa: std.mem.Allocator, config_file_name: []const u8) ![]u8 {
    const code: u32 = 5081;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: Cannot find a tsconfig.json file at the current directory: {s}.",
        .{ code, config_file_name },
    );
}

fn noInputsFoundInConfigDiagnostic(
    gpa: std.mem.Allocator,
    config_path: []const u8,
    include_patterns: []const []const u8,
    exclude_patterns: []const []const u8,
) ![]u8 {
    const code: u32 = 18003;
    var include_json: std.ArrayListUnmanaged(u8) = .empty;
    defer include_json.deinit(gpa);
    var exclude_json: std.ArrayListUnmanaged(u8) = .empty;
    defer exclude_json.deinit(gpa);
    try appendJsonStringArray(&include_json, gpa, include_patterns);
    try appendJsonStringArray(&exclude_json, gpa, exclude_patterns);
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: No inputs were found in config file '{s}'. Specified 'include' paths were '{s}' and 'exclude' paths were '{s}'.",
        .{ code, config_path, include_json.items, exclude_json.items },
    );
}

/// The TypeScript-supported source extensions, rendered in the exact
/// order and quoting tsc uses for the TS6054 message (`SupportedTSExt-
/// ensionsFlat`). Home additionally accepts its native `.hm`/`.home`
/// shapes, but those are deliberately omitted from the *diagnostic*
/// string so the message stays byte-identical to tsc.
const ts_supported_extensions_display = "'.ts', '.tsx', '.d.ts', '.cts', '.d.cts', '.mts', '.d.mts'";

/// Classification of an input file's extension for the file-add
/// extension checks (TS6504 / TS6054).
const ExtensionClass = enum {
    /// A TS/Home source extension the compiler accepts — no diagnostic.
    supported,
    /// A JavaScript-family extension (`.js`/`.jsx`/`.mjs`/`.cjs`).
    /// Reported as TS6504 when `allowJs` is off.
    javascript,
    /// Any other recognized-but-unsupported extension. Reported as
    /// TS6054. Extension-less paths are treated as supported (tsc only
    /// runs the check when the path `HasExtension`).
    unsupported,
};

fn classifyExtension(path: []const u8) ExtensionClass {
    // Home + TS source shapes the compiler can actually process.
    if (isTsLikeExtension(path)) return .supported;
    if (std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".jsx") or
        std.mem.endsWith(u8, path, ".mjs") or
        std.mem.endsWith(u8, path, ".cjs"))
    {
        return .javascript;
    }
    // Mirror tsc: only files that actually carry an extension are
    // candidates for the unsupported-extension diagnostic. A path with
    // no `.` in its basename is left alone.
    const base = std.fs.path.basename(path);
    if (std.mem.indexOfScalar(u8, base, '.') == null) return .supported;
    return .unsupported;
}

/// TS6504: an input file is a JavaScript file but `allowJs` is not set.
/// `{0}` is the file path. Caller frees.
fn javaScriptFileNeedsAllowJsDiagnostic(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const code: u32 = 6504;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: File '{s}' is a JavaScript file. Did you mean to enable the 'allowJs' option?",
        .{ code, path },
    );
}

/// TS6054: an input file has an extension the compiler does not support.
/// `{0}` is the file path, `{1}` the supported-extension list. Caller
/// frees.
fn unsupportedExtensionDiagnostic(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const code: u32 = 6054;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: File '{s}' has an unsupported extension. The only supported extensions are {s}.",
        .{ code, path, ts_supported_extensions_display },
    );
}

fn appendJsonStringArray(
    out: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    values: []const []const u8,
) !void {
    try out.append(gpa, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.append(gpa, '"');
        for (value) |ch| {
            switch (ch) {
                '"' => try out.appendSlice(gpa, "\\\""),
                '\\' => try out.appendSlice(gpa, "\\\\"),
                '\n' => try out.appendSlice(gpa, "\\n"),
                '\r' => try out.appendSlice(gpa, "\\r"),
                '\t' => try out.appendSlice(gpa, "\\t"),
                else => {
                    if (ch < 0x20) {
                        const hex = "0123456789abcdef";
                        try out.appendSlice(gpa, "\\u00");
                        try out.append(gpa, hex[ch >> 4]);
                        try out.append(gpa, hex[ch & 0x0f]);
                    } else {
                        try out.append(gpa, ch);
                    }
                },
            }
        }
        try out.append(gpa, '"');
    }
    try out.append(gpa, ']');
}

/// Compute the output path for a source file with the given extension
/// (e.g. `.js`, `.d.ts`). With no out_dir, emit alongside the source
/// (`a.ts` → `a.js`). With an out_dir, mirror just the basename
/// (full path-mirroring vs. rootDir is a Phase 5 follow-up).
fn computeOutPath(gpa: std.mem.Allocator, src_path: []const u8, out_dir: ?[]const u8, ext: []const u8) ![]u8 {
    const ext_dot = std.mem.lastIndexOfScalar(u8, src_path, '.') orelse src_path.len;
    const stem = src_path[0..ext_dot];
    if (out_dir) |dir| {
        const base = std.fs.path.basename(stem);
        return try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, base, ext });
    }
    return try std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, ext });
}

/// Resolve the path to a tsconfig.json. With an explicit `--project`
/// (file or directory), use it directly. Otherwise walk upward from
/// cwd looking for the nearest `tsconfig.json`. Returns a freshly
/// allocated path that the caller frees, or null when nothing is
/// found.
fn resolveTsConfigPath(gpa: std.mem.Allocator, project: ?[]const u8) !?[]u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    if (project) |p| {
        // If the path ends with .json, treat as the file directly;
        // otherwise treat as a directory and append `tsconfig.json`.
        if (std.mem.endsWith(u8, p, ".json")) {
            return try gpa.dupe(u8, p);
        }
        const joined = try std.fmt.allocPrint(gpa, "{s}/tsconfig.json", .{p});
        return joined;
    }

    // Upward walk. Use the absolute path of cwd so we know when we
    // hit the root.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &dir_buf);
    var cur = try gpa.dupe(u8, dir_buf[0..n]);
    defer gpa.free(cur);
    while (cur.len > 0) {
        const candidate = try std.fmt.allocPrint(gpa, "{s}/tsconfig.json", .{cur});
        // Try to stat — if it exists, return.
        const exists = blk: {
            var f = cwd.openFile(io, candidate, .{}) catch break :blk false;
            f.close(io);
            break :blk true;
        };
        if (exists) return candidate;
        gpa.free(candidate);
        const parent = std.fs.path.dirname(cur) orelse break;
        if (std.mem.eql(u8, parent, cur)) break;
        const new_cur = try gpa.dupe(u8, parent);
        gpa.free(cur);
        cur = new_cur;
    }
    return null;
}

test "tsc_main: TS5042 project mixed with source files diagnostic" {
    const msg = try projectMixedWithSourceFilesDiagnostic(std.testing.allocator);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS5042: Option 'project' cannot be mixed with source files on a command line.",
        msg,
    );
}

test "tsc_main: TS5058 specified path does not exist diagnostic" {
    const msg = try specifiedPathDoesNotExistDiagnostic(std.testing.allocator, "./missing.json");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS5058: The specified path does not exist: './missing.json'.",
        msg,
    );
}

test "tsc_main: TS5081 cannot find tsconfig at current directory diagnostic" {
    const msg = try cannotFindTsConfigAtCurrentDirectoryDiagnostic(std.testing.allocator, "/repo/sub/tsconfig.json");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS5081: Cannot find a tsconfig.json file at the current directory: /repo/sub/tsconfig.json.",
        msg,
    );
}

test "tsc_main: TS6306 referenced project must be composite diagnostic" {
    const msg = try referencedProjectMustBeCompositeDiagnostic(std.testing.allocator, "../lib");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS6306: Referenced project '../lib' must have setting \"composite\": true.",
        msg,
    );
}

test "tsc_main: TS6310 referenced project may not disable emit diagnostic" {
    const msg = try referencedProjectMayNotDisableEmitDiagnostic(std.testing.allocator, "../lib");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS6310: Referenced project '../lib' may not disable emit.",
        msg,
    );
}

test "tsc_main: project build info path resolves explicit relative path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg = try tsconfig_mod.parseString(std.testing.allocator, arena,
        \\{ "compilerOptions": { "composite": true, "tsBuildInfoFile": "../shared.tsbuildinfo" } }
    );
    const path = (try projectBuildInfoFilePath(arena, "/repo/app/tsconfig.json", cfg)).?;
    try std.testing.expectEqualStrings("/repo/shared.tsbuildinfo", path);
}

test "tsc_main: project build info path follows Home default convention" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg = try tsconfig_mod.parseString(std.testing.allocator, arena,
        \\{ "compilerOptions": { "incremental": true, "outDir": "dist" } }
    );
    const path = (try projectBuildInfoFilePath(arena, "/repo/app/tsconfig.json", cfg)).?;
    try std.testing.expectEqualStrings("/repo/app/dist/tsconfig.tsbuildinfo", path);
}

test "tsc_main: TS6377 referenced project build info overwrite diagnostic" {
    const msg = try referencedProjectBuildInfoOverwriteDiagnostic(std.testing.allocator, "/repo/shared.tsbuildinfo", "../lib");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS6377: Cannot write file '/repo/shared.tsbuildinfo' because it will overwrite '.tsbuildinfo' file generated by referenced project '../lib'.",
        msg,
    );
}

test "tsc_main: TS18003 no-input config diagnostic uses include and exclude specs" {
    const include = [_][]const u8{ "src/**/*.ts", "tests/**/*.ts" };
    const exclude = [_][]const u8{"dist"};
    const msg = try noInputsFoundInConfigDiagnostic(std.testing.allocator, "/repo/tsconfig.json", &include, &exclude);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS18003: No inputs were found in config file '/repo/tsconfig.json'. Specified 'include' paths were '[\"src/**/*.ts\",\"tests/**/*.ts\"]' and 'exclude' paths were '[\"dist\"]'.",
        msg,
    );
}

test "tsc_main: TS18003 no-input config diagnostic preserves empty include list" {
    const include = [_][]const u8{};
    const exclude = [_][]const u8{};
    const msg = try noInputsFoundInConfigDiagnostic(std.testing.allocator, "tsconfig.json", &include, &exclude);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS18003: No inputs were found in config file 'tsconfig.json'. Specified 'include' paths were '[]' and 'exclude' paths were '[]'.",
        msg,
    );
}

test "tsc_main: TS18003 diagnostic uses implicit outDir exclude display" {
    const cfg = try tsconfig_mod.parse(std.testing.allocator,
        \\{ "compilerOptions": { "outDir": "dist" } }
    );
    defer cfg.deinit();
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var owned: ?[]u8 = null;
    defer if (owned) |p| std.testing.allocator.free(p);

    const patterns = try effectiveExcludeDiagnosticPatterns(std.testing.allocator, "/repo", cfg, &out, &owned);
    try std.testing.expectEqual(@as(usize, 1), patterns.len);
    try std.testing.expectEqualStrings("/repo/dist", patterns[0]);
}

test "tsc_main: TS6504 JavaScript-file diagnostic text" {
    const msg = try javaScriptFileNeedsAllowJsDiagnostic(std.testing.allocator, "src/app.js");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS6504: File 'src/app.js' is a JavaScript file. Did you mean to enable the 'allowJs' option?",
        msg,
    );
}

test "tsc_main: TS6054 unsupported-extension diagnostic text" {
    const msg = try unsupportedExtensionDiagnostic(std.testing.allocator, "data/notes.txt");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "error TS6054: File 'data/notes.txt' has an unsupported extension. The only supported extensions are '.ts', '.tsx', '.d.ts', '.cts', '.d.cts', '.mts', '.d.mts'.",
        msg,
    );
}

test "tsc_main: classifyExtension recognizes TS, Home, JS and unsupported shapes" {
    try std.testing.expectEqual(ExtensionClass.supported, classifyExtension("a.ts"));
    try std.testing.expectEqual(ExtensionClass.supported, classifyExtension("a.tsx"));
    try std.testing.expectEqual(ExtensionClass.supported, classifyExtension("a.d.ts"));
    try std.testing.expectEqual(ExtensionClass.supported, classifyExtension("a.mts"));
    try std.testing.expectEqual(ExtensionClass.supported, classifyExtension("a.cts"));
    try std.testing.expectEqual(ExtensionClass.supported, classifyExtension("a.hm"));
    try std.testing.expectEqual(ExtensionClass.supported, classifyExtension("a.home"));
    // JS family -> TS6504 candidate.
    try std.testing.expectEqual(ExtensionClass.javascript, classifyExtension("a.js"));
    try std.testing.expectEqual(ExtensionClass.javascript, classifyExtension("a.jsx"));
    try std.testing.expectEqual(ExtensionClass.javascript, classifyExtension("a.mjs"));
    try std.testing.expectEqual(ExtensionClass.javascript, classifyExtension("a.cjs"));
    // Anything else with an extension -> TS6054 candidate.
    try std.testing.expectEqual(ExtensionClass.unsupported, classifyExtension("a.txt"));
    try std.testing.expectEqual(ExtensionClass.unsupported, classifyExtension("a.json"));
    // No extension -> left alone (matches tsc's HasExtension gate).
    try std.testing.expectEqual(ExtensionClass.supported, classifyExtension("Makefile"));
    try std.testing.expectEqual(ExtensionClass.supported, classifyExtension("src/noext"));
}

test "tsc_main: TS18003 diagnostic JSON-escapes control characters" {
    const include = [_][]const u8{"src/\x01*.ts"};
    const exclude = [_][]const u8{};
    const msg = try noInputsFoundInConfigDiagnostic(std.testing.allocator, "tsconfig.json", &include, &exclude);
    defer std.testing.allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "src/\\u0001*.ts") != null);
}

test "tsc_main: TS6307 diagnostic message and anchor match composite file list validation" {
    const msg = try compositeProjectFileListMessage(
        std.testing.allocator,
        "/repo/src/dep.ts",
        "/repo/tsconfig.json",
    );
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(
        "File '/repo/src/dep.ts' is not listed within the file list of project '/repo/tsconfig.json'. Projects must list all files or use an 'include' pattern.",
        msg,
    );

    const src = "import { dep } from './dep';\n";
    const pos = findIncludeSpecifierPosition(src, "\"./dep\"");
    const lc = ts_diagnostics.positionToLineCol(src, pos);
    try std.testing.expectEqual(@as(u32, 1), lc.line);
    try std.testing.expectEqual(@as(u32, 21), lc.col);
}
