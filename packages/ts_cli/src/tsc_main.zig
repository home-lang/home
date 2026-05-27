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
        for (all_args[1..]) |a| try argv.append(gpa, a);
    }

    var parse_ctx: ts_cli.ParseContext = .{};
    var opts = ts_cli.parseArgsCtx(gpa, argv.items, &parse_ctx) catch |err| {
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
            else => std.debug.print("error parsing args: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(@intFromEnum(ts_cli.ExitCode.config_error));
    };
    defer gpa.free(opts.files);

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
    var stream_ctx: StreamCtx = .{
        .gpa = gpa,
        .program = &program,
        .use_pretty = opts.pretty orelse true,
        .use_color = stdout_is_tty,
        .any_errors = &any_errors_streaming,
    };
    program.compileAllStreaming(compile_opts, &stream_ctx, streamDiagsCallback) catch |err| {
        std.debug.print("compile error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

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
    const any_errors = any_errors_streaming;
    for (program.files.items) |f| {
        const c = f.compilation orelse continue;
        if (opts.no_emit) continue;
        const out_path = try computeOutPath(gpa, f.path, out_dir, ".js");
        defer gpa.free(out_path);

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
        RealFs.write(gpa, out_path, js_bytes) catch |err| {
            std.debug.print("error writing {s}: {s}\n", .{ out_path, @errorName(err) });
            std.process.exit(1);
        };
        if (emit_source_map) {
            const map_bytes: []const u8 = sm_owned_map orelse "{}";
            const map_path = sm_map_path_owned.?;
            RealFs.write(gpa, map_path, map_bytes) catch |err| {
                std.debug.print("error writing {s}: {s}\n", .{ map_path, @errorName(err) });
                std.process.exit(1);
            };
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
            RealFs.write(gpa, dts_path, dts_bytes) catch |err| {
                std.debug.print("error writing {s}: {s}\n", .{ dts_path, @errorName(err) });
                std.process.exit(1);
            };

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
                    RealFs.write(gpa, map_path, mb) catch |err| {
                        std.debug.print("error writing {s}: {s}\n", .{ map_path, @errorName(err) });
                        std.process.exit(1);
                    };
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
        std.debug.print("home tsc - watching for changes (Ctrl-C to stop)\n", .{});
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
            std.debug.print("\n[{s}] {d} file(s) changed; recompiling…\n", .{ "watch", changed.items.len });
            const recompiled = program.recompileChanged(changed.items, compile_opts) catch |err| blk: {
                std.debug.print("recompile error: {s}\n", .{@errorName(err)});
                break :blk @as(u32, 0);
            };
            std.debug.print("[watch] {d} file(s) recompiled.\n", .{recompiled});
            // Re-emit each changed file's JS to disk.
            for (changed.items) |path| {
                const file_id = program.lookupPath(path) orelse continue;
                const f = program.fileById(file_id);
                const c = f.compilation orelse continue;
                if (opts.no_emit) continue;
                const out_path = computeOutPath(gpa, path, out_dir, ".js") catch continue;
                defer gpa.free(out_path);
                RealFs.write(gpa, out_path, c.js) catch |err| {
                    std.debug.print("error writing {s}: {s}\n", .{ out_path, @errorName(err) });
                };
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
};

/// Invoked once per compiled file, in compilation order. Renders
/// every diagnostic via the same formatter the post-compile loop
/// used to use, but earlier — diagnostics for file 0 surface before
/// file N has even been parsed.
fn streamDiagsCallback(ctx: *StreamCtx, file_path: []const u8, diags: []const ts_driver.Diagnostic) void {
    const fid = ctx.program.lookupPath(file_path) orelse return;
    const f = ctx.program.fileById(fid);
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
        };
        const formatted = if (ctx.use_pretty)
            ts_diagnostics.formatPretty(ctx.gpa, fdiag, f.source, ctx.use_color) catch continue
        else
            ts_diagnostics.formatDefault(ctx.gpa, fdiag) catch continue;
        defer ctx.gpa.free(formatted);
        std.debug.print("{s}\n", .{formatted});
        if (d.phase != .emit) ctx.any_errors.* = true;
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
