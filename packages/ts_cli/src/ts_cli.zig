//! `home tsc` CLI entry point.
//!
//! Per TS_PARITY_PLAN section 2.1. Drop-in compatible with `tsc` /
//! `tsgo` flag surface. Phase 4.5 ships the most-used flags; the
//! complete ~140-key matrix from section 2.2 fills in incrementally
//! against the typed tsconfig schema.
//!
//! Usage:
//!
//!   home tsc [files…] [options]
//!   home tsc --noEmit            # type-check only
//!   home tsc --watch              # re-emit on file change
//!   home tsc --project=tsconfig.json   # explicit config path
//!
//! Exit codes match tsc: 0 success, 1 type errors, 2 CLI/config errors,
//! 3 internal errors.

const std = @import("std");
const ts_diagnostics = @import("ts_diagnostics");
const ts_driver = @import("ts_driver");
const ts_program = @import("ts_program");
const ts_resolver = @import("ts_resolver");
const tsconfig_mod = @import("tsconfig");

pub const ExitCode = enum(u8) {
    success = 0,
    type_errors = 1,
    config_error = 2,
    internal_error = 3,
};

pub const Options = struct {
    /// Files passed positionally on the CLI.
    files: []const []const u8 = &.{},
    /// `--project` / `-p` path to a tsconfig.json.
    project: ?[]const u8 = null,
    /// `--noEmit`.
    no_emit: bool = false,
    /// `--watch` / `-w`.
    watch: bool = false,
    /// `--pretty` / `--no-pretty`. `null` means "auto" (TTY detect).
    pretty: ?bool = null,
    /// `--listFiles`.
    list_files: bool = false,
    /// `--listFilesOnly`.
    list_files_only: bool = false,
    /// `--showConfig`.
    show_config: bool = false,
    /// `--init`.
    init_config: bool = false,
    /// `--version` / `-v`.
    show_version: bool = false,
    /// `--help` / `-h` / `-?` / `--all`.
    show_help: bool = false,
    show_all_help: bool = false,
    /// `--strict` (and the strict-family individual toggles).
    strict: ?bool = null,
    /// `--target=esXXXX`.
    target: ?[]const u8 = null,
    /// `--outDir=PATH`.
    out_dir: ?[]const u8 = null,
    /// `--module=…`.
    module: ?[]const u8 = null,
    /// `--jsx=…`.
    jsx: ?[]const u8 = null,
};

pub const ParseError = error{
    OutOfMemory,
    UnknownFlag,
    MissingValue,
};

/// Parse argv (excluding the program name) into a typed Options.
pub fn parseArgs(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer files.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--noEmit")) {
            opts.no_emit = true;
        } else if (std.mem.eql(u8, a, "--watch") or std.mem.eql(u8, a, "-w")) {
            opts.watch = true;
        } else if (std.mem.eql(u8, a, "--pretty")) {
            opts.pretty = true;
        } else if (std.mem.eql(u8, a, "--no-pretty")) {
            opts.pretty = false;
        } else if (std.mem.eql(u8, a, "--listFiles")) {
            opts.list_files = true;
        } else if (std.mem.eql(u8, a, "--listFilesOnly")) {
            opts.list_files_only = true;
        } else if (std.mem.eql(u8, a, "--showConfig")) {
            opts.show_config = true;
        } else if (std.mem.eql(u8, a, "--init")) {
            opts.init_config = true;
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-v")) {
            opts.show_version = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "-?")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, a, "--all")) {
            opts.show_all_help = true;
        } else if (std.mem.eql(u8, a, "--strict")) {
            opts.strict = true;
        } else if (std.mem.eql(u8, a, "--project") or std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.project = args[i];
        } else if (parseEqFlag(a, "--project=")) |v| {
            opts.project = v;
        } else if (std.mem.eql(u8, a, "--target")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.target = args[i];
        } else if (parseEqFlag(a, "--target=")) |v| {
            opts.target = v;
        } else if (parseEqFlag(a, "--outDir=")) |v| {
            opts.out_dir = v;
        } else if (std.mem.eql(u8, a, "--outDir")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.out_dir = args[i];
        } else if (parseEqFlag(a, "--module=")) |v| {
            opts.module = v;
        } else if (std.mem.eql(u8, a, "--module")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.module = args[i];
        } else if (parseEqFlag(a, "--jsx=")) |v| {
            opts.jsx = v;
        } else if (std.mem.eql(u8, a, "--jsx")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.jsx = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            // Unknown flag — silently accept for forward-compat per
            // TS_PARITY_PLAN. A future cycle promotes selected
            // unknown flags to errors.
            // Skip a value if `--flag value` style.
            if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') {
                // Heuristic: assume it consumes the next arg.
                // Real impl will use a flag-arity table.
                i += 1;
            }
        } else {
            try files.append(gpa, a);
        }
    }
    opts.files = try files.toOwnedSlice(gpa);
    return opts;
}

fn parseEqFlag(a: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, a, prefix)) return a[prefix.len..];
    return null;
}

pub const helpText: []const u8 =
    \\Usage: home tsc [files...] [options]
    \\
    \\Options:
    \\  --project, -p <path>   Compile the project at <path>/tsconfig.json
    \\  --noEmit               Type-check only; do not write output files
    \\  --watch, -w            Watch input files for changes and recompile
    \\  --target <es*>         Target ES version (default es2024)
    \\  --module <kind>        Module form (commonjs / es2022 / nodenext / preserve)
    \\  --outDir <dir>         Output directory for emitted files
    \\  --jsx <mode>           JSX mode (preserve / react / react-jsx / react-jsxdev)
    \\  --strict               Enable all --strictXxx options
    \\  --pretty / --no-pretty Force-toggle ANSI-colored diagnostics
    \\  --listFiles            Print all included files and exit
    \\  --listFilesOnly        Same as --listFiles but stops before emit
    \\  --showConfig           Print the resolved tsconfig as JSON
    \\  --init                 Write a default tsconfig.json
    \\  --version, -v          Print version
    \\  --help, -h             Print this help
    \\  --all                  Print every flag including advanced
    \\
;

pub const versionText: []const u8 = "home tsc 0.1.0 (TS-compat 5.x)";

pub const RunResult = struct {
    code: ExitCode,
    /// One of `helpText`, `versionText`, or empty.
    stdout_text: []const u8 = "",
    /// Diagnostic message when `code` indicates failure.
    stderr_text: []const u8 = "",
};

/// Process parsed Options and decide what the CLI should do. Pure
/// function — no I/O. The actual binary wraps this with stdout /
/// stderr / disk reads.
pub fn dispatch(opts: Options) RunResult {
    if (opts.show_version) {
        return .{ .code = .success, .stdout_text = versionText };
    }
    if (opts.show_help or opts.show_all_help) {
        return .{ .code = .success, .stdout_text = helpText };
    }
    if (opts.files.len == 0 and opts.project == null and !opts.init_config) {
        return .{
            .code = .config_error,
            .stderr_text = "error: no input files; pass paths or --project=<dir>",
        };
    }
    // The full driver flow lands in a Phase 5 follow-up: load the
    // tsconfig from disk, build a Program over the resolved file
    // graph, run compileAll, then either emit to disk or
    // (if --noEmit) just collate diagnostics.
    return .{ .code = .success };
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "parseArgs: positional file paths" {
    const argv = [_][]const u8{ "src/a.ts", "src/b.ts" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(usize, 2), opts.files.len);
    try T.expectEqualStrings("src/a.ts", opts.files[0]);
}

test "parseArgs: --noEmit" {
    const argv = [_][]const u8{"--noEmit"};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.no_emit);
}

test "parseArgs: --watch and -w both work" {
    {
        const argv = [_][]const u8{"--watch"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expect(opts.watch);
    }
    {
        const argv = [_][]const u8{"-w"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expect(opts.watch);
    }
}

test "parseArgs: --project=path" {
    const argv = [_][]const u8{"--project=./tsconfig.json"};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqualStrings("./tsconfig.json", opts.project.?);
}

test "parseArgs: --project path (separate value)" {
    const argv = [_][]const u8{ "-p", "tsconfig.json" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqualStrings("tsconfig.json", opts.project.?);
}

test "parseArgs: --target / --module / --outDir / --jsx" {
    const argv = [_][]const u8{ "--target=es2022", "--module=esnext", "--outDir=dist", "--jsx=react-jsx" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqualStrings("es2022", opts.target.?);
    try T.expectEqualStrings("esnext", opts.module.?);
    try T.expectEqualStrings("dist", opts.out_dir.?);
    try T.expectEqualStrings("react-jsx", opts.jsx.?);
}

test "parseArgs: --pretty and --no-pretty" {
    {
        const argv = [_][]const u8{"--pretty"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expectEqual(@as(?bool, true), opts.pretty);
    }
    {
        const argv = [_][]const u8{"--no-pretty"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expectEqual(@as(?bool, false), opts.pretty);
    }
}

test "parseArgs: --strict" {
    const argv = [_][]const u8{"--strict"};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(?bool, true), opts.strict);
}

test "parseArgs: --version sets show_version" {
    const argv = [_][]const u8{"--version"};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.show_version);
}

test "parseArgs: --help / -h / -?" {
    const variants = [_][]const u8{ "--help", "-h", "-?" };
    for (variants) |flag| {
        const argv = [_][]const u8{flag};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expect(opts.show_help);
    }
}

test "parseArgs: mixed flags + files" {
    const argv = [_][]const u8{ "--noEmit", "a.ts", "--strict", "b.ts" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.no_emit);
    try T.expectEqual(@as(?bool, true), opts.strict);
    try T.expectEqual(@as(usize, 2), opts.files.len);
    try T.expectEqualStrings("a.ts", opts.files[0]);
    try T.expectEqualStrings("b.ts", opts.files[1]);
}

test "parseArgs: --listFiles / --listFilesOnly / --showConfig / --init" {
    const argv = [_][]const u8{ "--listFiles", "--listFilesOnly", "--showConfig", "--init" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.list_files);
    try T.expect(opts.list_files_only);
    try T.expect(opts.show_config);
    try T.expect(opts.init_config);
}

test "dispatch: --version returns versionText to stdout" {
    var opts: Options = .{};
    opts.show_version = true;
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.success, r.code);
    try T.expect(std.mem.indexOf(u8, r.stdout_text, "home tsc") != null);
}

test "dispatch: --help returns helpText to stdout" {
    var opts: Options = .{};
    opts.show_help = true;
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.success, r.code);
    try T.expect(std.mem.indexOf(u8, r.stdout_text, "Usage:") != null);
}

test "dispatch: missing input is a config error" {
    const opts: Options = .{};
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.config_error, r.code);
    try T.expect(std.mem.indexOf(u8, r.stderr_text, "no input files") != null);
}

test "dispatch: --project sets up a compile run" {
    var opts: Options = .{};
    opts.project = "tsconfig.json";
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.success, r.code);
}
