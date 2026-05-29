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
const options_table = @import("options_table.zig");
const codes = ts_diagnostics.codes;

pub const all_options = options_table.all_options;

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
    /// `--declaration` / `-d`. `null` means defer to tsconfig.
    declaration: ?bool = null,
    /// `--sourceMap`. `null` means defer to tsconfig.
    source_map: ?bool = null,
    /// `--declarationMap`. `null` means defer to tsconfig. When true,
    /// emit a `.d.ts.map` (or `.d.hm.map`) alongside each `.d.ts` /
    /// `.d.hm`. Implies `--declaration` at emit time.
    declaration_map: ?bool = null,
};

pub const ParseError = error{
    OutOfMemory,
    UnknownFlag,
    MissingValue,
};

/// Diagnostic context captured when `parseArgs` aborts. Lets the binary
/// layer render the exact tsc message for the failure (e.g. TS6044 with
/// the canonical option name) rather than a generic `error.MissingValue`
/// string. `missing_value_option` names the flag whose argument was
/// omitted (canonical tsc name, no leading dashes); it is only
/// meaningful when `parseArgs` returns `error.MissingValue`.
pub const ParseContext = struct {
    missing_value_option: []const u8 = "",
};

/// Parse argv (excluding the program name) into a typed Options.
pub fn parseArgs(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var ctx: ParseContext = .{};
    return parseArgsCtx(gpa, args, &ctx);
}

/// Like `parseArgs` but records failure context into `ctx`. On
/// `error.MissingValue` the offending option's canonical name is left
/// in `ctx.missing_value_option` so the caller can emit TS6044.
pub fn parseArgsCtx(gpa: std.mem.Allocator, args: []const []const u8, ctx: *ParseContext) ParseError!Options {
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
            if (i >= args.len) {
                ctx.missing_value_option = "project";
                return error.MissingValue;
            }
            opts.project = args[i];
        } else if (parseEqFlag(a, "--project=")) |v| {
            opts.project = v;
        } else if (std.mem.eql(u8, a, "--target")) {
            i += 1;
            if (i >= args.len) {
                ctx.missing_value_option = "target";
                return error.MissingValue;
            }
            opts.target = args[i];
        } else if (parseEqFlag(a, "--target=")) |v| {
            opts.target = v;
        } else if (parseEqFlag(a, "--outDir=")) |v| {
            opts.out_dir = v;
        } else if (std.mem.eql(u8, a, "--outDir")) {
            i += 1;
            if (i >= args.len) {
                ctx.missing_value_option = "outDir";
                return error.MissingValue;
            }
            opts.out_dir = args[i];
        } else if (parseEqFlag(a, "--module=")) |v| {
            opts.module = v;
        } else if (std.mem.eql(u8, a, "--module")) {
            i += 1;
            if (i >= args.len) {
                ctx.missing_value_option = "module";
                return error.MissingValue;
            }
            opts.module = args[i];
        } else if (parseEqFlag(a, "--jsx=")) |v| {
            opts.jsx = v;
        } else if (std.mem.eql(u8, a, "--jsx")) {
            i += 1;
            if (i >= args.len) {
                ctx.missing_value_option = "jsx";
                return error.MissingValue;
            }
            opts.jsx = args[i];
        } else if (std.mem.eql(u8, a, "--declaration") or std.mem.eql(u8, a, "-d")) {
            opts.declaration = true;
        } else if (std.mem.eql(u8, a, "--no-declaration")) {
            opts.declaration = false;
        } else if (std.mem.eql(u8, a, "--sourceMap")) {
            opts.source_map = true;
        } else if (std.mem.eql(u8, a, "--no-sourceMap")) {
            opts.source_map = false;
        } else if (std.mem.eql(u8, a, "--declarationMap")) {
            opts.declaration_map = true;
        } else if (std.mem.eql(u8, a, "--no-declarationMap")) {
            opts.declaration_map = false;
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
    \\  --sourceMap            Emit a `.js.map` source map alongside each `.js`
    \\  --declarationMap       Emit a `.d.ts.map` / `.d.hm.map` alongside each declaration
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

/// Render `home tsc --help` (or `--all`) from the compiler-options table.
///
/// Faithful to tsc: each option's one-line description and its grouping
/// category header are pulled from the diagnostic catalogue (the same
/// `TSxxxx` messages tsc keys its `--help` text to) rather than from
/// hand-written prose. The default view lists only the
/// `ShowInSimplifiedHelpView` options; `--all` lists every option grouped
/// under its category. Caller frees the returned buffer.
pub fn renderHelp(gpa: std.mem.Allocator, all: bool) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "Usage: home tsc [files...] [options]\n\n");

    // Collect distinct category codes in first-appearance order so the
    // grouped listing mirrors the reference compiler's decl order.
    var cats: [64]u32 = undefined;
    var ncat: usize = 0;
    for (all_options) |opt| {
        if (opt.category == 0) continue;
        var present = false;
        for (cats[0..ncat]) |c| {
            if (c == opt.category) {
                present = true;
                break;
            }
        }
        if (!present and ncat < cats.len) {
            cats[ncat] = opt.category;
            ncat += 1;
        }
    }

    for (cats[0..ncat]) |cat| {
        // Skip categories with no visible options in this view.
        var any = false;
        for (all_options) |opt| {
            if (opt.category != cat) continue;
            if (!all and !opt.simplified) continue;
            any = true;
            break;
        }
        if (!any) continue;

        if (codes.lookup(cat)) |ci| {
            try buf.append(gpa, '\n');
            try buf.appendSlice(gpa, ci.message);
            try buf.append(gpa, '\n');
        }
        for (all_options) |opt| {
            if (opt.category != cat) continue;
            if (!all and !opt.simplified) continue;
            try renderOption(gpa, &buf, opt);
        }
    }
    return buf.toOwnedSlice(gpa);
}

fn renderOption(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), opt: options_table.OptionDecl) !void {
    try buf.appendSlice(gpa, "  --");
    try buf.appendSlice(gpa, opt.name);
    if (opt.short.len > 0) {
        try buf.appendSlice(gpa, ", -");
        try buf.appendSlice(gpa, opt.short);
    }
    try buf.append(gpa, '\n');
    if (opt.code != 0) {
        if (codes.lookup(opt.code)) |ci| {
            try buf.appendSlice(gpa, "      ");
            try buf.appendSlice(gpa, ci.message);
            try buf.append(gpa, '\n');
        }
    }
}

/// TS6044: a non-boolean compiler flag was given on the command line
/// with no argument following it (e.g. a trailing `--outDir`). Mirrors
/// the upstream `Compiler_option_0_expects_an_argument` message; `{0}`
/// is the canonical option name (no leading dashes). Caller frees.
pub fn compilerOptionExpectsArgumentDiagnostic(gpa: std.mem.Allocator, option: []const u8) ![]u8 {
    const code: u32 = 6044;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: Compiler option '{s}' expects an argument.",
        .{ code, option },
    );
}

/// TS5054: `--init` was asked to create a `tsconfig.json` but one already
/// exists at `path`. Mirrors tsc's `WriteConfigFile` guard; `{0}` is the
/// normalized absolute path of the existing file. Caller frees.
pub fn tsconfigAlreadyDefinedDiagnostic(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const code: u32 = 5054;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: A 'tsconfig.json' file is already defined at: '{s}'.",
        .{ code, path },
    );
}

/// Default `tsconfig.json` body written by `home tsc --init` when no
/// config exists. A compact, valid superset of tsc's `--init` defaults
/// (the parity-relevant behavior is the TS5054 guard + the created path;
/// the body is a sensible default Home and tsc both accept).
pub const defaultTsconfigContents: []const u8 =
    \\{
    \\  "compilerOptions": {
    \\    "target": "esnext",
    \\    "module": "esnext",
    \\    "moduleResolution": "bundler",
    \\    "strict": true,
    \\    "esModuleInterop": true,
    \\    "skipLibCheck": true,
    \\    "forceConsistentCasingInFileNames": true
    \\  }
    \\}
    \\
;

/// Message printed after `--init` successfully writes a new config.
/// Mirrors tsc's "Created a new tsconfig.json" header + learn-more line.
pub const initCreatedMessage: []const u8 =
    "Created a new tsconfig.json.\nYou can learn more at https://aka.ms/tsconfig";

/// TS5033: an output file could not be written. `{0}` is the path, `{1}`
/// is the underlying OS error text. Mirrors tsc's emitter write-failure
/// diagnostic. Caller frees.
pub fn couldNotWriteFileDiagnostic(gpa: std.mem.Allocator, path: []const u8, err_text: []const u8) ![]u8 {
    const code: u32 = 5033;
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: Could not write file '{s}': {s}.",
        .{ code, path, err_text },
    );
}

/// TS5083: a file named on the command line (a `@response-file`) could
/// not be read. `{0}` is the file name. Caller frees.
pub fn cannotReadFileDiagnostic(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const code: u32 = 5083;
    return try std.fmt.allocPrint(gpa, "error TS{d}: Cannot read file '{s}'.", .{ code, path });
}

/// TS6045: a `@response-file` contained a quoted argument with no closing
/// quote. `{0}` is the file name. Caller frees.
pub fn unterminatedResponseFileStringDiagnostic(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const code: u32 = 6045;
    return try std.fmt.allocPrint(gpa, "error TS{d}: Unterminated quoted string in response file '{s}'.", .{ code, path });
}

/// Tokenized result of a `@response-file`'s contents.
pub const ResponseTokens = struct {
    /// Arguments, each borrowing a slice of the input `contents`.
    args: [][]const u8,
    /// True when a quoted argument was opened but never closed (TS6045).
    unterminated: bool,
};

/// Split a response-file body into command-line arguments, mirroring
/// tsc's `parseResponseFile` tokenizer: whitespace-separated tokens, with
/// double-quoted spans taken verbatim (without the quotes). An unquoted
/// run ends at the next byte `<= ' '`. Sets `unterminated` when a quote is
/// left open (the partial token is dropped, as tsc does). `args` borrows
/// from `contents`; the returned slice is gpa-owned (free with `gpa.free`).
pub fn tokenizeResponseFile(gpa: std.mem.Allocator, contents: []const u8) !ResponseTokens {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer args.deinit(gpa);
    var unterminated = false;
    var pos: usize = 0;
    const n = contents.len;
    while (pos < n) {
        while (pos < n and contents[pos] <= ' ') pos += 1;
        if (pos >= n) break;
        if (contents[pos] == '"') {
            pos += 1;
            const start = pos;
            while (pos < n and contents[pos] != '"') pos += 1;
            if (pos < n) {
                try args.append(gpa, contents[start..pos]);
                pos += 1;
            } else {
                unterminated = true;
                break;
            }
        } else {
            const start = pos;
            while (pos < n and contents[pos] > ' ') pos += 1;
            try args.append(gpa, contents[start..pos]);
        }
    }
    return .{ .args = try args.toOwnedSlice(gpa), .unterminated = unterminated };
}

/// One output-file collision found by `detectOutputCollisions`.
pub const OutputCollision = struct {
    /// TS5055 (overwrites an input file) or TS5056 (two inputs → one output).
    code: u32,
    /// The offending output path (borrowed from the caller's slice).
    output_path: []const u8,
    /// For TS5055 only: whether to append the TS5068 "add a tsconfig.json"
    /// message chain (tsc adds it when the program has no config file).
    add_tsconfig_hint: bool = false,
};

/// Detect output-file collisions the way tsc's program output-path check
/// does (`verifyEmitFilePath` in program.go):
///   - TS5055 when an emitted output path equals one of the input files
///     (with the TS5068 hint appended when `has_config` is false);
///   - TS5056 when two emitted outputs resolve to the same path.
/// `outputs` is in emit order; both slices hold already-normalized paths
/// (the caller decides case sensitivity by normalizing beforehand).
/// Returns an owned slice; the `output_path` fields borrow from `outputs`.
pub fn detectOutputCollisions(
    gpa: std.mem.Allocator,
    inputs: []const []const u8,
    outputs: []const []const u8,
    has_config: bool,
) ![]OutputCollision {
    var result: std.ArrayListUnmanaged(OutputCollision) = .empty;
    errdefer result.deinit(gpa);
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(gpa);

    for (outputs) |out| {
        if (out.len == 0) continue;
        var overwrites_input = false;
        for (inputs) |in| {
            if (std.mem.eql(u8, in, out)) {
                overwrites_input = true;
                break;
            }
        }
        if (overwrites_input) {
            try result.append(gpa, .{
                .code = 5055,
                .output_path = out,
                .add_tsconfig_hint = !has_config,
            });
        }
        var already_seen = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, out)) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) {
            try result.append(gpa, .{ .code = 5056, .output_path = out });
        } else {
            try seen.append(gpa, out);
        }
    }
    return result.toOwnedSlice(gpa);
}

/// Render an `OutputCollision` as its `error TSxxxx: …` line(s). TS5055
/// with `add_tsconfig_hint` appends the TS5068 hint as an indented chain
/// line, matching tsc's message chain. Caller frees.
pub fn formatOutputCollision(gpa: std.mem.Allocator, col: OutputCollision) ![]u8 {
    return switch (col.code) {
        5055 => if (col.add_tsconfig_hint) blk: {
            // The hint is TS5068, attached as a message chain. Render its
            // text from the catalogue so it stays authoritative.
            const hint_code: u32 = 5068;
            break :blk try std.fmt.allocPrint(
                gpa,
                "error TS5055: Cannot write file '{s}' because it would overwrite input file.\n  {s}",
                .{ col.output_path, (codes.lookup(hint_code) orelse unreachable).message },
            );
        }
        else
            try std.fmt.allocPrint(
                gpa,
                "error TS5055: Cannot write file '{s}' because it would overwrite input file.",
                .{col.output_path},
            ),
        5056 => try std.fmt.allocPrint(
            gpa,
            "error TS5056: Cannot write file '{s}' because it would be overwritten by multiple input files.",
            .{col.output_path},
        ),
        else => try std.fmt.allocPrint(gpa, "error TS{d}: output file collision: '{s}'.", .{ col.code, col.output_path }),
    };
}

// =============================================================================
// `tsc --build` command-line parsing
// =============================================================================

/// `OptionsForBuild` — the build-specific flags. Boolean unless noted.
/// Mirrors tsgo `internal/tsoptions/declsbuild.go`.
const BuildOptions = struct {
    verbose: bool = false,
    dry: bool = false,
    force: bool = false,
    clean: bool = false,
    builders: ?u32 = null, // number
    stop_build_on_errors: bool = false,
};

/// `commonOptionsWithBuild` ∪ `OptionsForBuild` — every option valid in
/// `tsc --build` mode (tsgo `BuildOpts`). A `-`/`--` flag not in this set
/// is either a compiler-only option (TS5094) or unknown (TS5072/TS5077).
const build_valid_names = [_][]const u8{
    // commonOptionsWithBuild (canonical names)
    "assumeChangesOnlyAffectDirectDependencies", "checkers",      "declaration",
    "declarationMap",                            "deduplicatePackages", "diagnostics",
    "emitDeclarationOnly",                       "explainFiles",  "extendedDiagnostics",
    "generateCpuProfile",                        "generateTrace", "help",
    "incremental",                               "inlineSourceMap", "listEmittedFiles",
    "listFiles",                                 "locale",        "noCheck",
    "noEmit",                                    "pprofDir",      "preserveWatchOutput",
    "pretty",                                    "quiet",         "singleThreaded",
    "sourceMap",                                 "traceResolution", "watch",
    // OptionsForBuild
    "build", "verbose", "dry", "force", "clean", "builders", "stopBuildOnErrors",
};

/// Build-only flags (in `BuildOpts` but not a compiler option) — using one
/// of these in plain `tsc` (no `--build`) is TS5093. `build` is excluded:
/// it is the mode switch, not a misused option.
const build_only_names = [_][]const u8{
    "verbose", "dry", "force", "clean", "builders", "stopBuildOnErrors",
};

/// Resolve a build-mode short alias to its canonical name (tsgo
/// `BuildNameMap`, `allowShort`). Returns the input unchanged if not a
/// recognized short.
fn canonicalBuildName(name: []const u8) []const u8 {
    const pairs = [_]struct { short: []const u8, long: []const u8 }{
        .{ .short = "b", .long = "build" },   .{ .short = "v", .long = "verbose" },
        .{ .short = "d", .long = "dry" },     .{ .short = "f", .long = "force" },
        .{ .short = "h", .long = "help" },    .{ .short = "w", .long = "watch" },
        .{ .short = "i", .long = "incremental" }, .{ .short = "q", .long = "quiet" },
    };
    for (pairs) |p| if (std.mem.eql(u8, name, p.short)) return p.long;
    return name;
}

fn isBuildValidName(name: []const u8) bool {
    for (build_valid_names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Strip leading `-` characters from a flag (`--verbose` → `verbose`).
fn stripDashes(flag: []const u8) []const u8 {
    var s = flag;
    while (s.len > 0 and s[0] == '-') s = s[1..];
    return s;
}

/// If `flag` (a raw `--name` / `-x` argument) names a build-only option,
/// return its canonical name — used by plain `tsc` to emit TS5093. Matches
/// canonical full names only (short aliases mean compiler options like
/// `-d`=declaration in non-build mode).
pub fn buildOnlyOptionInNormalMode(flag: []const u8) ?[]const u8 {
    const name = stripDashes(flag);
    for (build_only_names) |n| if (std.mem.eql(u8, name, n)) return n;
    return null;
}

/// Closest build-option name to `name` within a length-scaled edit
/// distance, or null. Drives the TS5077 "Did you mean" suggestion.
fn closestBuildOptionName(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    const threshold = @max(name.len, 2) / 2 + 1;
    for (build_valid_names) |cand| {
        const d = tsconfig_mod.levenshteinIcase(name, cand);
        if (d < best_dist and d <= threshold) {
            best_dist = d;
            best = cand;
        }
    }
    return best;
}

pub const BuildParse = struct {
    options: BuildOptions,
    /// Project paths (positional args); defaults to `["."]` when none given.
    projects: [][]const u8,
    /// Fully-formatted `error TSxxxx: …` lines (gpa-owned, each freed).
    diagnostics: [][]u8,

    pub fn deinit(self: *BuildParse, gpa: std.mem.Allocator) void {
        for (self.diagnostics) |d| gpa.free(d);
        gpa.free(self.diagnostics);
        gpa.free(self.projects);
    }
};

/// Parse a `tsc --build` argument list (the args AFTER the leading
/// `-b`/`--build`), mirroring tsgo `ParseBuildCommandLine` +
/// `createUnknownOptionError`:
///   - unknown option that is a compiler option  → TS5094 (or TS6369 for `build`)
///   - unknown option, close to a build option    → TS5077
///   - unknown option, otherwise                   → TS5072
///   - `builders` without a numeric value          → TS5073
///   - clean+force / clean+verbose                 → TS6370
/// Non-flag args are project paths (default `["."]`). Caller frees via
/// `BuildParse.deinit`.
pub fn parseBuildArgs(gpa: std.mem.Allocator, args: []const []const u8) !BuildParse {
    var opts: BuildOptions = .{};
    var projects: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer projects.deinit(gpa);
    var diags: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (diags.items) |d| gpa.free(d);
        diags.deinit(gpa);
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len == 0) continue;
        if (a[0] != '-') {
            try projects.append(gpa, a);
            continue;
        }
        const raw = stripDashes(a);
        const name = canonicalBuildName(raw);
        if (std.mem.eql(u8, name, "verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, name, "dry")) {
            opts.dry = true;
        } else if (std.mem.eql(u8, name, "force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, name, "clean")) {
            opts.clean = true;
        } else if (std.mem.eql(u8, name, "stopBuildOnErrors")) {
            opts.stop_build_on_errors = true;
        } else if (std.mem.eql(u8, name, "builders")) {
            // Number option: needs a numeric value.
            if (i + 1 < args.len and std.fmt.parseInt(u32, args[i + 1], 10) catch null != null) {
                opts.builders = std.fmt.parseInt(u32, args[i + 1], 10) catch unreachable;
                i += 1;
            } else {
                const code: u32 = 5073;
                try diags.append(gpa, try std.fmt.allocPrint(gpa, "error TS{d}: Build option '{s}' requires a value of type number.", .{ code, name }));
            }
        } else if (isBuildValidName(name)) {
            // Other valid build option (a common option) — accepted; value
            // handling for these is the orchestrator's concern.
        } else if (tsconfig_mod.isKnownCompilerOptionName(name)) {
            if (std.mem.eql(u8, name, "build")) {
                const code: u32 = 6369;
                try diags.append(gpa, try std.fmt.allocPrint(gpa, "error TS{d}: Option '--build' must be the first command line argument.", .{code}));
            } else {
                const code: u32 = 5094;
                try diags.append(gpa, try std.fmt.allocPrint(gpa, "error TS{d}: Compiler option '--{s}' may not be used with '--build'.", .{ code, name }));
            }
        } else if (closestBuildOptionName(name)) |suggestion| {
            const code: u32 = 5077;
            try diags.append(gpa, try std.fmt.allocPrint(gpa, "error TS{d}: Unknown build option '{s}'. Did you mean '{s}'?", .{ code, name, suggestion }));
        } else {
            const code: u32 = 5072;
            try diags.append(gpa, try std.fmt.allocPrint(gpa, "error TS{d}: Unknown build option '{s}'.", .{ code, name }));
        }
    }

    // Nonsensical combinations (tsgo ParseBuildCommandLine).
    if (opts.clean and opts.force) {
        const code: u32 = 6370;
        try diags.append(gpa, try std.fmt.allocPrint(gpa, "error TS{d}: Options '{s}' and '{s}' cannot be combined.", .{ code, "clean", "force" }));
    }
    if (opts.clean and opts.verbose) {
        const code: u32 = 6370;
        try diags.append(gpa, try std.fmt.allocPrint(gpa, "error TS{d}: Options '{s}' and '{s}' cannot be combined.", .{ code, "clean", "verbose" }));
    }

    if (projects.items.len == 0) try projects.append(gpa, ".");

    return .{
        .options = opts,
        .projects = try projects.toOwnedSlice(gpa),
        .diagnostics = try diags.toOwnedSlice(gpa),
    };
}

/// A project in the `tsc --build` reference graph.
pub const ProjectNode = struct {
    /// Config path/name (used verbatim in the TS6202 cycle message).
    name: []const u8,
    /// Indices into the node list of the projects this one references.
    deps: []const usize,
};

pub const BuildOrder = struct {
    /// Topological order — each project appears after all its references
    /// (dependencies built first). gpa-owned.
    order: []usize,
    /// When the graph has a cycle, the project names on the circular path
    /// (gpa-owned slice of borrowed names); null otherwise. Drives TS6202.
    cycle: ?[][]const u8,

    pub fn deinit(self: *BuildOrder, gpa: std.mem.Allocator) void {
        gpa.free(self.order);
        if (self.cycle) |c| gpa.free(c);
    }
};

/// Topologically order a project-reference graph (dependencies first),
/// mirroring tsgo's `setupBuildTask` DFS post-order with `analyzing`/
/// `completed` cycle detection. On the first cycle found, `cycle` holds the
/// names on the circular path (for TS6202) and `order` is the partial order.
pub fn topoSortProjects(gpa: std.mem.Allocator, nodes: []const ProjectNode) !BuildOrder {
    const State = enum { unvisited, analyzing, completed };
    const states = try gpa.alloc(State, nodes.len);
    defer gpa.free(states);
    @memset(states, .unvisited);

    var order: std.ArrayListUnmanaged(usize) = .empty;
    errdefer order.deinit(gpa);
    var stack: std.ArrayListUnmanaged(usize) = .empty;
    defer stack.deinit(gpa);
    var cycle: ?[][]const u8 = null;
    errdefer if (cycle) |c| gpa.free(c);

    const Walk = struct {
        fn visit(
            g: std.mem.Allocator,
            ns: []const ProjectNode,
            st: []State,
            ord: *std.ArrayListUnmanaged(usize),
            stk: *std.ArrayListUnmanaged(usize),
            cyc: *?[][]const u8,
            idx: usize,
        ) !void {
            if (st[idx] == .completed) return;
            if (st[idx] == .analyzing) {
                if (cyc.* == null) {
                    // Record the path from the earlier occurrence of `idx`
                    // on the stack through to the current node.
                    var start: usize = 0;
                    for (stk.items, 0..) |s, i| {
                        if (s == idx) {
                            start = i;
                            break;
                        }
                    }
                    var names: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (stk.items[start..]) |s| try names.append(g, ns[s].name);
                    try names.append(g, ns[idx].name); // close the cycle
                    cyc.* = try names.toOwnedSlice(g);
                }
                return;
            }
            st[idx] = .analyzing;
            try stk.append(g, idx);
            for (ns[idx].deps) |dep| {
                try visit(g, ns, st, ord, stk, cyc, dep);
            }
            _ = stk.pop();
            st[idx] = .completed;
            try ord.append(g, idx);
        }
    };

    for (nodes, 0..) |_, i| {
        try Walk.visit(gpa, nodes, states, &order, &stack, &cycle, i);
    }

    return .{ .order = try order.toOwnedSlice(gpa), .cycle = cycle };
}

/// TS6202: a project-reference cycle. `{0}` is the cycle's project names
/// joined by newlines (tsgo `strings.Join(circularityStack, "\n")`).
/// Caller frees.
pub fn projectReferenceCycleDiagnostic(gpa: std.mem.Allocator, cycle_names: []const []const u8) ![]u8 {
    const code: u32 = 6202;
    const joined = try std.mem.join(gpa, "\n", cycle_names);
    defer gpa.free(joined);
    return try std.fmt.allocPrint(
        gpa,
        "error TS{d}: Project references may not form a circular graph. Cycle detected:\n{s}",
        .{ code, joined },
    );
}

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

test "parseArgs: --pretty default + tsc_main resolution semantics" {
    // No flag -> null (auto). tsc_main resolves null/true to pretty,
    // and only `--no-pretty` (opts.pretty == false) falls back to the
    // single-line `formatDefault` shape — this test pins down both
    // halves of that resolution rule so the wiring can't drift.
    const argv = [_][]const u8{};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(?bool, null), opts.pretty);
    try T.expect((opts.pretty orelse true) == true);

    const argv_no = [_][]const u8{"--no-pretty"};
    const opts_no = try parseArgs(T.allocator, &argv_no);
    defer T.allocator.free(opts_no.files);
    try T.expect((opts_no.pretty orelse true) == false);
}

test "parseArgs: --sourceMap / --no-sourceMap" {
    {
        const argv = [_][]const u8{"--sourceMap"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expectEqual(@as(?bool, true), opts.source_map);
    }
    {
        const argv = [_][]const u8{"--no-sourceMap"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expectEqual(@as(?bool, false), opts.source_map);
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

test "parseArgsCtx: trailing --outDir captures missing-value option for TS6044" {
    var ctx: ParseContext = .{};
    const argv = [_][]const u8{"--outDir"};
    try T.expectError(error.MissingValue, parseArgsCtx(T.allocator, &argv, &ctx));
    try T.expectEqualStrings("outDir", ctx.missing_value_option);
}

test "parseArgsCtx: trailing value-flags each report their canonical name" {
    const cases = [_]struct { flag: []const u8, name: []const u8 }{
        .{ .flag = "--project", .name = "project" },
        .{ .flag = "-p", .name = "project" },
        .{ .flag = "--target", .name = "target" },
        .{ .flag = "--module", .name = "module" },
        .{ .flag = "--jsx", .name = "jsx" },
    };
    for (cases) |c| {
        var ctx: ParseContext = .{};
        const argv = [_][]const u8{c.flag};
        try T.expectError(error.MissingValue, parseArgsCtx(T.allocator, &argv, &ctx));
        try T.expectEqualStrings(c.name, ctx.missing_value_option);
    }
}

test "parseArgsCtx: flag with a value does not set missing-value option" {
    var ctx: ParseContext = .{};
    const argv = [_][]const u8{ "--outDir", "dist" };
    const opts = try parseArgsCtx(T.allocator, &argv, &ctx);
    defer T.allocator.free(opts.files);
    try T.expectEqualStrings("dist", opts.out_dir.?);
    try T.expectEqualStrings("", ctx.missing_value_option);
}

test "compilerOptionExpectsArgumentDiagnostic: TS6044 message text" {
    const msg = try compilerOptionExpectsArgumentDiagnostic(T.allocator, "outDir");
    defer T.allocator.free(msg);
    try T.expectEqualStrings(
        "error TS6044: Compiler option 'outDir' expects an argument.",
        msg,
    );
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

test "options_table: every description/category code resolves in the catalogue" {
    // A row's `.code` / `.category` must point at a real catalogue entry —
    // a dangling code would render a blank `--help` line. (`0` means the
    // upstream decl carried no description, e.g. tsgo-only flags absent
    // from the upstream-derived catalogue.)
    for (all_options) |opt| {
        if (opt.code != 0) try T.expect(codes.lookup(opt.code) != null);
        if (opt.category != 0) try T.expect(codes.lookup(opt.category) != null);
    }
}

test "renderHelp: simplified view renders simplified option descriptions" {
    const help = try renderHelp(T.allocator, false);
    defer T.allocator.free(help);
    try T.expect(std.mem.indexOf(u8, help, "Usage:") != null);
    // `--watch` / `--strict` are ShowInSimplifiedHelpView; their catalogue
    // descriptions must appear in the default view.
    try T.expect(std.mem.indexOf(u8, help, "Watch input files.") != null);
    try T.expect(std.mem.indexOf(u8, help, "Enable all strict type-checking options.") != null);
    // `traceResolution` is not ShowInSimplifiedHelpView — it must NOT leak
    // into the default view.
    try T.expect(std.mem.indexOf(u8, help, "--traceResolution") == null);
}

test "renderHelp: --all view includes advanced options and category headers" {
    const help = try renderHelp(T.allocator, true);
    defer T.allocator.free(help);
    // `traceResolution` is advanced-only; it appears under --all.
    try T.expect(std.mem.indexOf(u8, help, "--traceResolution") != null);
    try T.expect(std.mem.indexOf(u8, help, "Log paths used during the 'moduleResolution' process.") != null);
    // Simplified options still render under --all too.
    try T.expect(std.mem.indexOf(u8, help, "--target, -t") != null);
}

test "renderHelp: option names carry their short alias" {
    const help = try renderHelp(T.allocator, false);
    defer T.allocator.free(help);
    try T.expect(std.mem.indexOf(u8, help, "--watch, -w") != null);
}

test "tsconfigAlreadyDefinedDiagnostic: TS5054 message text" {
    const msg = try tsconfigAlreadyDefinedDiagnostic(T.allocator, "/proj/tsconfig.json");
    defer T.allocator.free(msg);
    try T.expectEqualStrings(
        "error TS5054: A 'tsconfig.json' file is already defined at: '/proj/tsconfig.json'.",
        msg,
    );
}

test "defaultTsconfigContents parses as a tsconfig object" {
    // --init must write a config Home itself can load.
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const cfg = try tsconfig_mod.parseString(T.allocator, arena.allocator(), defaultTsconfigContents);
    try T.expect(!cfg.root_not_object);
    try T.expectEqual(@as(?bool, true), cfg.compiler_options.strict);
}

test "couldNotWriteFileDiagnostic: TS5033 message text" {
    const msg = try couldNotWriteFileDiagnostic(T.allocator, "dist/a.js", "AccessDenied");
    defer T.allocator.free(msg);
    try T.expectEqualStrings("error TS5033: Could not write file 'dist/a.js': AccessDenied.", msg);
}

test "detectOutputCollisions: TS5055 when output overwrites an input" {
    const inputs = [_][]const u8{ "src/a.ts", "src/b.js" };
    // Emitting a.ts to a.js (fine) but b.js would overwrite the input b.js.
    const outputs = [_][]const u8{ "src/a.js", "src/b.js" };
    const cols = try detectOutputCollisions(T.allocator, &inputs, &outputs, true);
    defer T.allocator.free(cols);
    try T.expectEqual(@as(usize, 1), cols.len);
    try T.expectEqual(@as(u32, 5055), cols[0].code);
    try T.expectEqualStrings("src/b.js", cols[0].output_path);
    try T.expect(!cols[0].add_tsconfig_hint); // has_config = true
}

test "detectOutputCollisions: TS5055 adds the TS5068 hint without a config" {
    const inputs = [_][]const u8{"a.js"};
    const outputs = [_][]const u8{"a.js"};
    const cols = try detectOutputCollisions(T.allocator, &inputs, &outputs, false);
    defer T.allocator.free(cols);
    try T.expectEqual(@as(usize, 1), cols.len);
    try T.expectEqual(@as(u32, 5055), cols[0].code);
    try T.expect(cols[0].add_tsconfig_hint);
}

test "detectOutputCollisions: TS5056 when two inputs map to the same output" {
    const inputs = [_][]const u8{ "src/a.ts", "src/a.tsx" };
    // Both emit to the same a.js.
    const outputs = [_][]const u8{ "dist/a.js", "dist/a.js" };
    const cols = try detectOutputCollisions(T.allocator, &inputs, &outputs, true);
    defer T.allocator.free(cols);
    try T.expectEqual(@as(usize, 1), cols.len);
    try T.expectEqual(@as(u32, 5056), cols[0].code);
    try T.expectEqualStrings("dist/a.js", cols[0].output_path);
}

test "detectOutputCollisions: clean outputs produce no diagnostics" {
    const inputs = [_][]const u8{ "src/a.ts", "src/b.ts" };
    const outputs = [_][]const u8{ "dist/a.js", "dist/b.js" };
    const cols = try detectOutputCollisions(T.allocator, &inputs, &outputs, true);
    defer T.allocator.free(cols);
    try T.expectEqual(@as(usize, 0), cols.len);
}

test "cannotReadFileDiagnostic / unterminatedResponseFileStringDiagnostic message text" {
    const m1 = try cannotReadFileDiagnostic(T.allocator, "args.txt");
    defer T.allocator.free(m1);
    try T.expectEqualStrings("error TS5083: Cannot read file 'args.txt'.", m1);
    const m2 = try unterminatedResponseFileStringDiagnostic(T.allocator, "args.txt");
    defer T.allocator.free(m2);
    try T.expectEqualStrings("error TS6045: Unterminated quoted string in response file 'args.txt'.", m2);
}

test "tokenizeResponseFile: whitespace and quoted args" {
    const r = try tokenizeResponseFile(T.allocator, "  --strict\n  --outDir \"my dir\"\t--noEmit ");
    defer T.allocator.free(r.args);
    try T.expect(!r.unterminated);
    try T.expectEqual(@as(usize, 4), r.args.len);
    try T.expectEqualStrings("--strict", r.args[0]);
    try T.expectEqualStrings("--outDir", r.args[1]);
    try T.expectEqualStrings("my dir", r.args[2]);
    try T.expectEqualStrings("--noEmit", r.args[3]);
}

test "tokenizeResponseFile: unterminated quote flags TS6045 and drops the partial token" {
    const r = try tokenizeResponseFile(T.allocator, "--outDir \"unclosed");
    defer T.allocator.free(r.args);
    try T.expect(r.unterminated);
    try T.expectEqual(@as(usize, 1), r.args.len);
    try T.expectEqualStrings("--outDir", r.args[0]);
}

test "tokenizeResponseFile: empty / whitespace-only yields no args" {
    const r = try tokenizeResponseFile(T.allocator, "   \n\t  ");
    defer T.allocator.free(r.args);
    try T.expect(!r.unterminated);
    try T.expectEqual(@as(usize, 0), r.args.len);
}

fn buildDiagHas(p: BuildParse, needle: []const u8) bool {
    for (p.diagnostics) |d| {
        if (std.mem.indexOf(u8, d, needle) != null) return true;
    }
    return false;
}

test "parseBuildArgs: valid build flags set options, no diagnostics" {
    var p = try parseBuildArgs(T.allocator, &.{ "--verbose", "--force", "--builders", "4", "./proj" });
    defer p.deinit(T.allocator);
    try T.expect(p.options.verbose);
    try T.expect(p.options.force);
    try T.expectEqual(@as(?u32, 4), p.options.builders);
    try T.expectEqual(@as(usize, 1), p.projects.len);
    try T.expectEqualStrings("./proj", p.projects[0]);
    try T.expectEqual(@as(usize, 0), p.diagnostics.len);
}

test "parseBuildArgs: short aliases resolve (-v/-f/-b)" {
    var p = try parseBuildArgs(T.allocator, &.{ "-v", "-f" });
    defer p.deinit(T.allocator);
    try T.expect(p.options.verbose);
    try T.expect(p.options.force);
    try T.expectEqual(@as(usize, 0), p.diagnostics.len);
}

test "parseBuildArgs: no projects defaults to '.'" {
    var p = try parseBuildArgs(T.allocator, &.{"--dry"});
    defer p.deinit(T.allocator);
    try T.expectEqual(@as(usize, 1), p.projects.len);
    try T.expectEqualStrings(".", p.projects[0]);
}

test "parseBuildArgs: TS5094 for a compiler option in build mode" {
    var p = try parseBuildArgs(T.allocator, &.{"--strict"});
    defer p.deinit(T.allocator);
    try T.expect(buildDiagHas(p, "error TS5094: Compiler option '--strict' may not be used with '--build'."));
}

test "parseBuildArgs: TS5073 when builders has no numeric value" {
    var p = try parseBuildArgs(T.allocator, &.{ "--builders", "--verbose" });
    defer p.deinit(T.allocator);
    try T.expect(buildDiagHas(p, "error TS5073: Build option 'builders' requires a value of type number."));
    try T.expect(p.options.verbose); // --verbose still parsed
}

test "parseBuildArgs: TS5077 did-you-mean for a near-miss build option" {
    var p = try parseBuildArgs(T.allocator, &.{"--verbos"});
    defer p.deinit(T.allocator);
    try T.expect(buildDiagHas(p, "error TS5077: Unknown build option 'verbos'. Did you mean 'verbose'?"));
}

test "parseBuildArgs: TS5072 for a wholly-unknown build option" {
    var p = try parseBuildArgs(T.allocator, &.{"--zzzqqq"});
    defer p.deinit(T.allocator);
    try T.expect(buildDiagHas(p, "error TS5072: Unknown build option 'zzzqqq'."));
}

test "parseBuildArgs: TS6370 for clean+force and clean+verbose" {
    var p = try parseBuildArgs(T.allocator, &.{ "--clean", "--force" });
    defer p.deinit(T.allocator);
    try T.expect(buildDiagHas(p, "error TS6370: Options 'clean' and 'force' cannot be combined."));
    var p2 = try parseBuildArgs(T.allocator, &.{ "--clean", "--verbose" });
    defer p2.deinit(T.allocator);
    try T.expect(buildDiagHas(p2, "error TS6370: Options 'clean' and 'verbose' cannot be combined."));
}

test "topoSortProjects: dependencies are ordered before dependents" {
    // app → lib → core. Build order must be core, lib, app.
    const nodes = [_]ProjectNode{
        .{ .name = "app", .deps = &.{1} },
        .{ .name = "lib", .deps = &.{2} },
        .{ .name = "core", .deps = &.{} },
    };
    var r = try topoSortProjects(T.allocator, &nodes);
    defer r.deinit(T.allocator);
    try T.expect(r.cycle == null);
    try T.expectEqual(@as(usize, 3), r.order.len);
    // core (2) before lib (1) before app (0)
    try T.expectEqual(@as(usize, 2), r.order[0]);
    try T.expectEqual(@as(usize, 1), r.order[1]);
    try T.expectEqual(@as(usize, 0), r.order[2]);
}

test "topoSortProjects: diamond graph orders each dep before dependents" {
    // a → b,c ; b → d ; c → d. d must come first, a last.
    const nodes = [_]ProjectNode{
        .{ .name = "a", .deps = &.{ 1, 2 } },
        .{ .name = "b", .deps = &.{3} },
        .{ .name = "c", .deps = &.{3} },
        .{ .name = "d", .deps = &.{} },
    };
    var r = try topoSortProjects(T.allocator, &nodes);
    defer r.deinit(T.allocator);
    try T.expect(r.cycle == null);
    try T.expectEqual(@as(usize, 3), r.order[0]); // d first
    try T.expectEqual(@as(usize, 0), r.order[r.order.len - 1]); // a last
}

test "topoSortProjects: detects a cycle and reports the path" {
    // a → b → c → a.
    const nodes = [_]ProjectNode{
        .{ .name = "a", .deps = &.{1} },
        .{ .name = "b", .deps = &.{2} },
        .{ .name = "c", .deps = &.{0} },
    };
    var r = try topoSortProjects(T.allocator, &nodes);
    defer r.deinit(T.allocator);
    try T.expect(r.cycle != null);
    const c = r.cycle.?;
    // Path starts and ends at the same node (a … a).
    try T.expectEqualStrings(c[0], c[c.len - 1]);
    try T.expect(c.len >= 4); // a, b, c, a
}

test "projectReferenceCycleDiagnostic: TS6202 message joins names with newlines" {
    const names = [_][]const u8{ "a/tsconfig.json", "b/tsconfig.json", "a/tsconfig.json" };
    const msg = try projectReferenceCycleDiagnostic(T.allocator, &names);
    defer T.allocator.free(msg);
    try T.expect(std.mem.startsWith(u8, msg, "error TS6202: Project references may not form a circular graph. Cycle detected:\n"));
    try T.expect(std.mem.indexOf(u8, msg, "a/tsconfig.json\nb/tsconfig.json\na/tsconfig.json") != null);
}

test "buildOnlyOptionInNormalMode: detects build-only flags for TS5093" {
    try T.expectEqualStrings("verbose", buildOnlyOptionInNormalMode("--verbose").?);
    try T.expectEqualStrings("clean", buildOnlyOptionInNormalMode("--clean").?);
    // A compiler option / non-build flag → null.
    try T.expect(buildOnlyOptionInNormalMode("--strict") == null);
    try T.expect(buildOnlyOptionInNormalMode("--noEmit") == null);
    // Short `-d` is declaration in normal mode, NOT build-only `dry`.
    try T.expect(buildOnlyOptionInNormalMode("-d") == null);
}

test "formatOutputCollision: TS5055 / TS5068 hint / TS5056 message text" {
    const m1 = try formatOutputCollision(T.allocator, .{ .code = 5055, .output_path = "a.js" });
    defer T.allocator.free(m1);
    try T.expectEqualStrings("error TS5055: Cannot write file 'a.js' because it would overwrite input file.", m1);

    const m2 = try formatOutputCollision(T.allocator, .{ .code = 5055, .output_path = "a.js", .add_tsconfig_hint = true });
    defer T.allocator.free(m2);
    try T.expect(std.mem.indexOf(u8, m2, "error TS5055:") != null);
    try T.expect(std.mem.indexOf(u8, m2, "Adding a tsconfig.json file will help organize") != null);
    try T.expect(std.mem.indexOf(u8, m2, "https://aka.ms/tsconfig") != null);

    const m3 = try formatOutputCollision(T.allocator, .{ .code = 5056, .output_path = "a.js" });
    defer T.allocator.free(m3);
    try T.expectEqualStrings("error TS5056: Cannot write file 'a.js' because it would be overwritten by multiple input files.", m3);
}
