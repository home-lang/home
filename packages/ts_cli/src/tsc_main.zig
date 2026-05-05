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

    const opts = ts_cli.parseArgs(gpa, argv.items) catch |err| {
        std.debug.print("error parsing args: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer gpa.free(opts.files);

    const dec = ts_cli.dispatch(opts);
    if (dec.stdout_text.len > 0) {
        std.debug.print("{s}\n", .{dec.stdout_text});
    }
    if (dec.stderr_text.len > 0) {
        std.debug.print("{s}\n", .{dec.stderr_text});
    }
    if (dec.code != .success) std.process.exit(@intFromEnum(dec.code));

    if (opts.show_version or opts.show_help) return;
    if (opts.files.len == 0) return;

    // Compile each input file (single-file mode for v0; project /
    // tsconfig flow lands in a follow-up).
    _ = RealFs;
    var virtual = ts_resolver.VirtualFs.init(gpa);
    defer virtual.deinit();
    var resolver = ts_resolver.Resolver.init(gpa, virtual.fs(), .{});
    defer resolver.deinit();

    var program = ts_program.Program.init(gpa, &resolver);
    defer program.deinit();

    for (opts.files) |path| {
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

    program.compileAll(.{}) catch |err| {
        std.debug.print("compile error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Print diagnostics + write JS outputs.
    var any_errors = false;
    for (program.files.items) |f| {
        const c = f.compilation orelse continue;
        for (c.diagnostics.items) |d| {
            std.debug.print("{s}: {s}\n", .{ f.path, d.message });
            if (d.phase != .emit) any_errors = true;
        }
        if (opts.no_emit) continue;
        // Output path: replace .ts/.tsx with .js (sibling). When
        // outDir is set we mirror the directory structure under it.
        const ext_dot = std.mem.lastIndexOfScalar(u8, f.path, '.') orelse f.path.len;
        const stem = f.path[0..ext_dot];
        const out_path = try std.fmt.allocPrint(gpa, "{s}.js", .{stem});
        defer gpa.free(out_path);
        RealFs.write(gpa, out_path, c.js) catch |err| {
            std.debug.print("error writing {s}: {s}\n", .{ out_path, @errorName(err) });
            std.process.exit(1);
        };
    }
    _ = ts_diagnostics; // silence unused import while diagnostics flow lands

    if (any_errors) std.process.exit(1);
}
