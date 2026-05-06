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

    var opts = ts_cli.parseArgs(gpa, argv.items) catch |err| {
        std.debug.print("error parsing args: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer gpa.free(opts.files);

    // Resolve tsconfig BEFORE dispatch so a discovered tsconfig
    // counts as input for the "no files" check inside dispatch.
    // Explicit `--project <path>` wins; otherwise we walk upward
    // from cwd looking for the nearest `tsconfig.json`.
    var cfg_arena = std.heap.ArenaAllocator.init(gpa);
    defer cfg_arena.deinit();
    var cfg_path_buf: ?[]u8 = null;
    defer if (cfg_path_buf) |b| gpa.free(b);
    var loaded_cfg: ?tsconfig_mod.TsConfig = null;
    if (resolveTsConfigPath(gpa, opts.project) catch null) |path| {
        opts.project = path;
        cfg_path_buf = path;
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
    //      / `.d.ts` / `.mts` / `.cts`.
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
            const include_patterns: []const []const u8 = c.include orelse &[_][]const u8{"**/*"};
            const exclude_patterns: []const []const u8 = c.exclude orelse &.{};
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
        std.debug.print("error: no input files; pass paths or --project=<path>\n", .{});
        std.process.exit(2);
    }

    var virtual = ts_resolver.VirtualFs.init(gpa);
    defer virtual.deinit();
    var resolver = ts_resolver.Resolver.init(gpa, virtual.fs(), .{});
    defer resolver.deinit();

    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();

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

    const compile_opts: ts_driver.CompileOptions = if (loaded_cfg) |*c|
        ts_driver.optionsFromConfig(c)
    else
        .{};

    program.compileAll(compile_opts) catch |err| {
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

    // Declaration output dir: tsconfig `declarationDir` if set,
    // otherwise alongside the .js (which itself respects outDir).
    const declaration_dir: ?[]const u8 = blk: {
        if (loaded_cfg) |c| if (c.compiler_options.declaration_dir) |d| break :blk d;
        break :blk out_dir;
    };

    // Print diagnostics + write JS outputs.
    var any_errors = false;
    for (program.files.items) |f| {
        const c = f.compilation orelse continue;
        for (c.diagnostics.items) |d| {
            const pos = ts_diagnostics.positionToLineCol(c.source, d.pos);
            const code = if (d.code != 0) d.code else mapPhaseToCode(d.phase);
            const prefix: ts_diagnostics.Diagnostic.CodePrefix = switch (d.code_prefix) {
                .TS => .TS,
                .HM => .HM,
            };
            const fdiag: ts_diagnostics.Diagnostic = .{
                .file = f.path,
                .line = pos.line,
                .col = pos.col,
                .code = code,
                .code_prefix = prefix,
                .severity = .err,
                .message = d.message,
                .span_len = 0,
            };
            const formatted = ts_diagnostics.formatDefault(gpa, fdiag) catch continue;
            defer gpa.free(formatted);
            std.debug.print("{s}\n", .{formatted});
            if (d.phase != .emit) any_errors = true;
        }
        if (opts.no_emit) continue;
        const out_path = try computeOutPath(gpa, f.path, out_dir, ".js");
        defer gpa.free(out_path);
        RealFs.write(gpa, out_path, c.js) catch |err| {
            std.debug.print("error writing {s}: {s}\n", .{ out_path, @errorName(err) });
            std.process.exit(1);
        };
        if (emit_dts) {
            var emitter = ts_emit.DtsEmitter.init(gpa, &c.hir, &c.interner, .{});
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
    if (std.mem.endsWith(u8, path, ".ts")) return true;
    if (std.mem.endsWith(u8, path, ".tsx")) return true;
    if (std.mem.endsWith(u8, path, ".mts")) return true;
    if (std.mem.endsWith(u8, path, ".cts")) return true;
    return false;
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
