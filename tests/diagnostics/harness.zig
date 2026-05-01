//! Diagnostic snapshot test harness.
//!
//! Walks `tests/diagnostics/cases/` for `*.home` files, runs `home check`
//! on each, captures stderr+stdout, normalizes it (strips ANSI color
//! codes and DebugAllocator leak dumps, rewrites the absolute path of
//! the test file to a stable repo-relative form), and compares the
//! result to a checked-in `<file>.expected` snapshot.
//!
//! Usage (via build.zig):
//!   zig build test-diagnostics                # verify, fail on diff
//!   zig build test-diagnostics -- --update    # rewrite .expected files
//!
//! Direct invocation:
//!   diagnostic-harness <repo-root> <home-binary> [--update]
//!
//! Why a custom harness instead of plain shell:
//! - We need the same normalization on every platform (Linux/macOS/Windows)
//! - We need to filter DebugAllocator leak dumps that the debug build
//!   emits at exit (unrelated to diagnostic UX, very noisy)
//! - We need a `--update` mode for intentional snapshot refreshes
//!
//! Snapshot honesty: only commit a `.expected` file that matches the
//! compiler's *current* output. If a diagnostic category isn't
//! implemented yet, leaving it out is better than fabricating ideal
//! output that doesn't match reality — that defeats regression detection.

const std = @import("std");
const Io = std.Io;

const usage =
    \\diagnostic-harness <repo-root> <home-binary> [--update]
    \\
    \\Walks <repo-root>/tests/diagnostics/cases/ for *.home files, runs
    \\<home-binary> check on each, normalizes stderr, and compares to
    \\<file>.expected. Exits non-zero on any mismatch.
    \\
    \\  --update   rewrite .expected files instead of comparing
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 3) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }

    const repo_root = args[1];
    const home_bin = args[2];
    var update_mode = false;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--update") or std.mem.eql(u8, arg, "-u")) {
            update_mode = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        } else {
            std.debug.print("unknown arg: {s}\n\n{s}", .{ arg, usage });
            std.process.exit(2);
        }
    }

    const cases_dir_path = try std.fs.path.join(gpa, &.{ repo_root, "tests", "diagnostics", "cases" });
    defer gpa.free(cases_dir_path);

    var cases: std.ArrayList([]const u8) = .empty;
    defer {
        for (cases.items) |p| gpa.free(p);
        cases.deinit(gpa);
    }

    try collectCases(gpa, io, cases_dir_path, &cases);
    std.mem.sort([]const u8, cases.items, {}, lessThan);

    if (cases.items.len == 0) {
        std.debug.print("no .home cases found under {s}\n", .{cases_dir_path});
        std.process.exit(1);
    }

    var failed: usize = 0;
    var updated: usize = 0;
    var passed: usize = 0;

    for (cases.items) |case_path| {
        const result = runCase(gpa, io, repo_root, home_bin, case_path) catch |err| {
            std.debug.print("FAIL  {s}: harness error: {t}\n", .{ rel(case_path, repo_root), err });
            failed += 1;
            continue;
        };
        defer gpa.free(result);

        const expected_path = try std.mem.concat(gpa, u8, &.{ case_path, ".expected" });
        defer gpa.free(expected_path);

        if (update_mode) {
            try writeFile(io, expected_path, result);
            std.debug.print("UPDATE {s}\n", .{rel(case_path, repo_root)});
            updated += 1;
            continue;
        }

        const expected = Io.Dir.cwd().readFileAlloc(io, expected_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("FAIL  {s}: missing snapshot {s}\n", .{ rel(case_path, repo_root), rel(expected_path, repo_root) });
                std.debug.print("      run with --update to create it, then review the diff\n", .{});
                std.debug.print("      actual output was:\n", .{});
                printIndented(result, "      | ");
                failed += 1;
                continue;
            },
            else => return err,
        };
        defer gpa.free(expected);

        if (std.mem.eql(u8, expected, result)) {
            passed += 1;
        } else {
            failed += 1;
            std.debug.print("FAIL  {s}\n", .{rel(case_path, repo_root)});
            printDiff(expected, result);
            std.debug.print("      run `zig build test-diagnostics -- --update` to accept new output\n\n", .{});
        }
    }

    if (update_mode) {
        std.debug.print("\nupdated {d} snapshot(s)\n", .{updated});
        return;
    }

    std.debug.print("\n{d} passed, {d} failed (out of {d})\n", .{ passed, failed, cases.items.len });
    if (failed > 0) std.process.exit(1);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Recursively collect all `*.home` files under `dir_path`.
fn collectCases(
    gpa: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => {
                defer gpa.free(child);
                try collectCases(gpa, io, child, out);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".home")) {
                    try out.append(gpa, child);
                } else {
                    gpa.free(child);
                }
            },
            else => gpa.free(child),
        }
    }
}

/// Per-case wall-clock budget. Generous enough for slow CI runners
/// but tight enough to catch genuine infinite loops in the parser /
/// type checker (we've seen at least one — `fn 123 invalid()` —
/// where the parser never terminates).
const case_timeout_seconds: i64 = 30;

/// Run `home check <case>` and return normalized output. Caller frees.
fn runCase(
    gpa: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    home_bin: []const u8,
    case_path: []const u8,
) ![]u8 {
    // Disable color: we don't strictly rely on this (the harness strips
    // ANSI anyway) but it avoids regressing if checkCommand starts
    // honoring NO_COLOR in the future.
    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("NO_COLOR", "1");
    try env_map.put("CLICOLOR", "0");

    const argv = [_][]const u8{ home_bin, "check", case_path };

    const timeout: Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = .fromSeconds(case_timeout_seconds),
    } };

    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .environ_map = &env_map,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = timeout,
    }) catch |err| return err;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // We capture both streams. checkCommand uses std.debug.print
    // (which writes to stderr) but future renderers may move to stdout.
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(gpa);
    try combined.appendSlice(gpa, result.stderr);
    if (result.stdout.len > 0) {
        if (combined.items.len > 0 and combined.items[combined.items.len - 1] != '\n') {
            try combined.append(gpa, '\n');
        }
        try combined.appendSlice(gpa, result.stdout);
    }

    return normalize(gpa, combined.items, repo_root);
}

/// Normalize compiler output for stable snapshots.
///
/// 1. Strip ANSI escape sequences (CSI: ESC [ ... <letter>)
/// 2. Drop DebugAllocator leak dumps. These are emitted at process
///    exit by debug builds and are unrelated to diagnostic UX. A leak
///    dump starts with `error(DebugAllocator):` and continues for
///    several stack-frame lines (Allocator.zig, type_system.zig,
///    main.zig, etc.) until the next blank line. We just drop every
///    line until we see a non-stack-frame, non-error line.
/// 3. Rewrite the absolute test-file path to repo-relative form so
///    snapshots are portable across machines.
fn normalize(gpa: std.mem.Allocator, raw: []const u8, repo_root: []const u8) ![]u8 {
    // Step 1: strip ANSI.
    const stripped = try stripAnsi(gpa, raw);
    defer gpa.free(stripped);

    // Step 2: drop debug-allocator noise.
    const denoised = try stripDebugAllocator(gpa, stripped);
    defer gpa.free(denoised);

    // Step 3: rewrite absolute paths to <repo>-relative.
    const rewritten = try rewritePaths(gpa, denoised, repo_root);
    defer gpa.free(rewritten);

    // Step 4: trim trailing whitespace on each line + ensure single
    // trailing newline. Keeps diffs noise-free.
    return tidyTrailing(gpa, rewritten);
}

fn stripAnsi(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == 0x1b and i + 1 < input.len and input[i + 1] == '[') {
            // Skip past CSI parameter bytes (0x30-0x3f) and intermediate
            // bytes (0x20-0x2f), then consume the final byte (0x40-0x7e).
            i += 2;
            while (i < input.len) {
                const ch = input[i];
                i += 1;
                if (ch >= 0x40 and ch <= 0x7e) break;
            }
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }

    return out.toOwnedSlice(gpa);
}

fn stripDebugAllocator(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, input.len);

    var lines = std.mem.splitScalar(u8, input, '\n');
    var skipping = false;
    while (lines.next()) |line| {
        if (skipping) {
            // Stack frames look like "  /path/file.zig:NN:NN: 0x... in fn (binary)"
            // or are continuation lines starting with spaces and source code.
            if (line.len == 0) {
                skipping = false;
                try out.append(gpa, '\n');
                continue;
            }
            // Heuristic: while the next line looks like part of a leak
            // dump (path/file.zig:..., or a code-snippet continuation
            // line, or a caret pointer) keep dropping. Bail out on a
            // line that clearly isn't part of the dump.
            if (isLeakDumpLine(line)) continue;
            skipping = false;
            // fall through to normal append below
        }

        if (std.mem.startsWith(u8, line, "error(DebugAllocator):")) {
            skipping = true;
            continue;
        }

        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }

    // splitScalar leaves a trailing empty line when input ended in '\n'.
    // We always re-emit a trailing '\n', so trim one if doubled.
    while (out.items.len >= 2 and
        out.items[out.items.len - 1] == '\n' and
        out.items[out.items.len - 2] == '\n')
    {
        _ = out.pop();
    }

    return out.toOwnedSlice(gpa);
}

fn isLeakDumpLine(line: []const u8) bool {
    // Path-like line containing ".zig:" — stack frame.
    if (std.mem.indexOf(u8, line, ".zig:") != null) return true;

    // Continuation lines: just whitespace + code snippet, often ending
    // with `^` pointer. We treat any line that starts with whitespace
    // (i.e. is indented) as part of the previous frame's context.
    if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) return true;

    return false;
}

fn rewritePaths(gpa: std.mem.Allocator, input: []const u8, repo_root: []const u8) ![]u8 {
    // Replace any occurrence of `<repo_root>/` with `<repo>/` so
    // snapshots don't bake in $HOME.
    const needle = try std.mem.concat(gpa, u8, &.{ repo_root, "/" });
    defer gpa.free(needle);

    return std.mem.replaceOwned(u8, gpa, input, needle, "<repo>/");
}

fn tidyTrailing(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, input.len);

    var lines = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        try out.appendSlice(gpa, trimmed);
    }

    // Collapse trailing blank lines down to a single newline.
    while (out.items.len >= 2 and
        out.items[out.items.len - 1] == '\n' and
        out.items[out.items.len - 2] == '\n')
    {
        _ = out.pop();
    }
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append(gpa, '\n');
    }

    return out.toOwnedSlice(gpa);
}

fn writeFile(io: Io, path: []const u8, contents: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    try Io.Dir.cwd().createDirPath(io, dir);
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var write_buf: [4096]u8 = undefined;
    var w = f.writer(io, &write_buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

fn rel(path: []const u8, repo_root: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, repo_root)) {
        var i: usize = repo_root.len;
        while (i < path.len and path[i] == '/') i += 1;
        return path[i..];
    }
    return path;
}

fn printDiff(expected: []const u8, actual: []const u8) void {
    std.debug.print("      --- expected\n", .{});
    printIndented(expected, "      - ");
    std.debug.print("      +++ actual\n", .{});
    printIndented(actual, "      + ");
}

fn printIndented(body: []const u8, prefix: []const u8) void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        std.debug.print("{s}{s}\n", .{ prefix, line });
    }
}
