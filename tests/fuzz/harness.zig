//! Lexer + parser fuzzing harness for the Home compiler.
//!
//! Goal: catch inputs that crash, hang, leak, or otherwise blow up the
//! compiler before users do. Tracks issue #10.
//!
//! Strategy:
//! - Load a small seed corpus from `tests/fuzz/corpus/{lex,parse}/` and
//!   apply byte-level mutations to generate fuzz inputs. Inputs are
//!   written to a temp file and fed to a freshly-installed `home`
//!   binary as a subprocess.
//! - Subprocess isolation is mandatory because the parser is known to
//!   infinite-loop on certain malformed inputs (issue #16). Running
//!   in-process would wedge the harness itself the moment we hit one
//!   of those inputs. By spawning `home parse <file>` (lexer fuzzing)
//!   or `home ast <file>` (parser fuzzing) per iteration we can enforce
//!   a hard wall-clock timeout via `std.process.run`'s timeout option,
//!   then kill the child and keep going.
//! - We classify each iteration:
//!     * exit 0          -> ok (compiler accepted the input)
//!     * exit 1          -> ok (compiler reported errors and exited
//!                          cleanly; this is the *intended* path for
//!                          most fuzz inputs)
//!     * Io.Timeout      -> recoverable finding ("hang"). Saved to
//!                          findings/<target>/timeout-NNNN.home and
//!                          counted; does NOT fail CI. These feed back
//!                          into issue #16's reproduction set.
//!     * .signal/.unknown
//!       or other exit   -> CRASH. Saved as findings/<target>/crash-NNNN.home
//!                          and DOES fail CI on exit (non-zero status).
//!
//! Why not std.testing.fuzz? Two reasons. First, the in-process model
//! can't survive parser hangs. Second, Zig 0.17's coverage-guided fuzz
//! runner is still in flux and not wired up in this build; a plain
//! mutation-based driver is portable and good enough for the basic
//! "catches obvious panics/hangs" budget the issue calls for.
//!
//! Usage (via build.zig):
//!   zig build fuzz                 # run both targets, default 60s budget
//!   zig build fuzz-lexer           # only lexer
//!   zig build fuzz-parser          # only parser
//!   zig build fuzz -- --seconds 30 # custom budget per target
//!   zig build fuzz -- --seed 42    # deterministic
//!
//! Direct invocation:
//!   fuzz-harness <repo-root> <home-binary> <target> [flags]
//!     <target>     lex | parse | all
//!     --seconds N  per-target wall-clock budget (default 30)
//!     --timeout N  per-input timeout in seconds (default 2)
//!     --seed N     PRNG seed (default = wall clock)
//!     --max-iters N  hard upper bound on iterations per target
//!     --findings P  directory for crash/timeout reproducers
//!                   (default: <repo-root>/.home-cache/fuzz-findings)
//!     --quiet       only print summary

const std = @import("std");
const Io = std.Io;

const usage =
    \\fuzz-harness <repo-root> <home-binary> <target> [flags]
    \\
    \\Mutation-based fuzzer for the Home lexer and parser. Runs the
    \\compiler in a subprocess per iteration so parser hangs (see
    \\issue #16) can be timed out without wedging the harness.
    \\
    \\  <target>          lex | parse | all
    \\
    \\  --seconds N       per-target wall-clock budget (default 30)
    \\  --timeout N       per-input timeout in seconds (default 2)
    \\  --seed N          PRNG seed (default = wall clock)
    \\  --max-iters N     hard upper bound on iterations per target
    \\  --findings DIR    where to save crash/timeout reproducers
    \\                    (default: <repo-root>/.home-cache/fuzz-findings)
    \\  --quiet           print summary only
    \\
    \\Exit status:
    \\  0  no crashes (timeouts are reported but do not fail)
    \\  1  at least one crash detected; reproducer is saved
    \\  2  bad invocation
    \\
;

const Target = enum {
    lex,
    parse,
    all,

    fn fromStr(s: []const u8) ?Target {
        if (std.mem.eql(u8, s, "lex")) return .lex;
        if (std.mem.eql(u8, s, "parse")) return .parse;
        if (std.mem.eql(u8, s, "all")) return .all;
        return null;
    }

    fn subcommand(self: Target) []const u8 {
        return switch (self) {
            // `home parse` runs the lexer and prints tokens. Doesn't
            // invoke the parser, so it's a lexer-only fuzz target.
            .lex => "parse",
            // `home ast` runs lexer + parser and prints the AST. This
            // is what the parser-hang inputs from #16 trigger.
            .parse => "ast",
            .all => unreachable,
        };
    }

    fn label(self: Target) []const u8 {
        return switch (self) {
            .lex => "lex",
            .parse => "parse",
            .all => "all",
        };
    }
};

const Args = struct {
    repo_root: []const u8,
    home_bin: []const u8,
    target: Target,
    seconds: u64 = 30,
    timeout_secs: u64 = 2,
    seed: ?u64 = null,
    max_iters: ?u64 = null,
    findings_dir: ?[]const u8 = null,
    quiet: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 4) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }

    var args: Args = .{
        .repo_root = argv[1],
        .home_bin = argv[2],
        .target = Target.fromStr(argv[3]) orelse {
            std.debug.print("unknown target: {s}\n\n{s}", .{ argv[3], usage });
            std.process.exit(2);
        },
    };

    var i: usize = 4;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            args.quiet = true;
        } else if (std.mem.eql(u8, a, "--seconds")) {
            i += 1;
            if (i >= argv.len) fail("--seconds needs a value");
            args.seconds = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--timeout")) {
            i += 1;
            if (i >= argv.len) fail("--timeout needs a value");
            args.timeout_secs = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            if (i >= argv.len) fail("--seed needs a value");
            args.seed = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--max-iters")) {
            i += 1;
            if (i >= argv.len) fail("--max-iters needs a value");
            args.max_iters = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--findings")) {
            i += 1;
            if (i >= argv.len) fail("--findings needs a value");
            args.findings_dir = argv[i];
        } else {
            std.debug.print("unknown arg: {s}\n\n{s}", .{ a, usage });
            std.process.exit(2);
        }
    }

    const default_findings = try std.fs.path.join(arena, &.{ args.repo_root, ".home-cache", "fuzz-findings" });
    const findings_root = args.findings_dir orelse default_findings;

    var total_crashes: u64 = 0;
    if (args.target == .all) {
        total_crashes += try runTarget(gpa, io, arena, args, .lex, findings_root);
        total_crashes += try runTarget(gpa, io, arena, args, .parse, findings_root);
    } else {
        total_crashes += try runTarget(gpa, io, arena, args, args.target, findings_root);
    }

    if (total_crashes > 0) std.process.exit(1);
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("{s}\n\n{s}", .{ msg, usage });
    std.process.exit(2);
}

fn nowToMs(ts: Io.Timestamp) i64 {
    return ts.toMilliseconds();
}

/// Per-target driver. Returns the number of crashes found (used to set
/// the harness exit code). Timeouts are logged but not counted as
/// crashes — see the module-level comment.
fn runTarget(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    args: Args,
    target: Target,
    findings_root: []const u8,
) !u64 {
    if (!args.quiet) {
        std.debug.print(
            \\
            \\=== fuzz target: {s} ===
            \\  budget:    {d}s
            \\  per-input: {d}s timeout
            \\  home bin:  {s}
            \\
        , .{ target.label(), args.seconds, args.timeout_secs, args.home_bin });
    }

    // Load corpus.
    const corpus_dir = try std.fs.path.join(arena, &.{
        args.repo_root, "tests", "fuzz", "corpus", target.label(),
    });
    var corpus: std.ArrayList([]const u8) = .empty;
    defer {
        for (corpus.items) |item| gpa.free(item);
        corpus.deinit(gpa);
    }
    try loadCorpus(gpa, io, corpus_dir, &corpus);

    if (corpus.items.len == 0) {
        // Always seed at least one entry so the mutation loop has
        // something to chew on. Empty input is a valid fuzz seed —
        // it has caught EOF-handling bugs in the past.
        try corpus.append(gpa, try gpa.dupe(u8, ""));
    }

    if (!args.quiet) {
        std.debug.print("  corpus:    {d} seed(s) from {s}\n", .{ corpus.items.len, corpus_dir });
    }

    // Set up findings dir.
    const target_findings = try std.fs.path.join(arena, &.{ findings_root, target.label() });
    try Io.Dir.cwd().createDirPath(io, target_findings);

    // Per-run scratch file for the subprocess input.
    const input_path = try std.fmt.allocPrint(arena, "{s}/_current.home", .{target_findings});

    // PRNG. We seed off the monotonic clock if not given an explicit
    // seed; this is plenty for non-cryptographic mutation.
    const seed: u64 = args.seed orelse blk: {
        const ns = Io.Clock.awake.now(io).nanoseconds;
        break :blk @bitCast(@as(i64, @truncate(ns)));
    };
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    // Stats.
    var stats: Stats = .{};
    const start_ts = Io.Clock.awake.now(io);
    stats.start_ms = nowToMs(start_ts);
    const max_iters = args.max_iters orelse std.math.maxInt(u64);

    while (stats.iterations < max_iters) {
        const elapsed_ms = nowToMs(Io.Clock.awake.now(io)) - stats.start_ms;
        if (elapsed_ms >= @as(i64, @intCast(args.seconds)) * 1000) break;

        const input = try mutate(gpa, rng, corpus.items);
        defer gpa.free(input);

        // Write to scratch file. The compiler reads from disk only.
        try writeAll(io, input_path, input);

        const outcome = runOne(gpa, io, args.home_bin, target, input_path, args.timeout_secs) catch |err| {
            // Spawning itself failed — treat as harness error, not a
            // compiler crash, and bail.
            std.debug.print("  harness error spawning child: {t}\n", .{err});
            return err;
        };

        stats.iterations += 1;
        switch (outcome) {
            .ok => stats.ok += 1,
            .compiler_error => stats.compiler_errors += 1,
            .timeout => {
                stats.timeouts += 1;
                try saveFinding(io, target_findings, "timeout", stats.timeouts, input);
                if (!args.quiet and stats.timeouts <= 10) {
                    std.debug.print("  TIMEOUT #{d:0>4} ({d} bytes) saved (#16 repro)\n", .{
                        stats.timeouts, input.len,
                    });
                }
            },
            .crash => |info| {
                stats.crashes += 1;
                try saveFinding(io, target_findings, "crash", stats.crashes, input);
                std.debug.print("  CRASH   #{d:0>4} ({d} bytes): {s}\n", .{
                    stats.crashes, input.len, info,
                });
            },
        }
    }

    stats.end_ms = nowToMs(Io.Clock.awake.now(io));

    // Always print summary, even with --quiet — that's the whole point.
    const elapsed_ms = stats.end_ms - stats.start_ms;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    const exec_per_s = if (elapsed_ms > 0)
        @as(f64, @floatFromInt(stats.iterations)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms))
    else
        0.0;

    std.debug.print(
        \\--- {s} summary ---
        \\  iterations:      {d} ({d:.1}/s over {d:.1}s)
        \\  ok (exit 0):     {d}
        \\  errors (exit 1): {d}
        \\  timeouts:        {d}  (saved under {s})
        \\  crashes:         {d}  (saved under {s})
        \\
    , .{
        target.label(),
        stats.iterations,
        exec_per_s,
        elapsed_s,
        stats.ok,
        stats.compiler_errors,
        stats.timeouts,
        target_findings,
        stats.crashes,
        target_findings,
    });

    return stats.crashes;
}

const Stats = struct {
    iterations: u64 = 0,
    ok: u64 = 0,
    compiler_errors: u64 = 0,
    timeouts: u64 = 0,
    crashes: u64 = 0,
    start_ms: i64 = 0,
    end_ms: i64 = 0,
};

const Outcome = union(enum) {
    /// Compiler accepted the input (exit 0).
    ok,
    /// Compiler rejected the input cleanly (exit 1). This is the
    /// happy path for most fuzz inputs; we're not trying to make the
    /// compiler accept random bytes, just to make sure it doesn't
    /// crash on them.
    compiler_error,
    /// Process ran past per-input timeout. Almost always a parser
    /// hang; see issue #16.
    timeout,
    /// Process died from a signal, or exited with an unexpected code.
    /// This is what we want CI to fail on. Carries a short
    /// description for the log.
    crash: []const u8,
};

fn runOne(
    gpa: std.mem.Allocator,
    io: Io,
    home_bin: []const u8,
    target: Target,
    input_path: []const u8,
    timeout_secs: u64,
) !Outcome {
    const subcmd = target.subcommand();
    const argv = [_][]const u8{ home_bin, subcmd, input_path };

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    // Shut up colour codes — keeps any future log capture clean.
    try env_map.put("NO_COLOR", "1");
    try env_map.put("CLICOLOR", "0");

    const timeout: Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = .fromSeconds(@intCast(timeout_secs)),
    } };

    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .environ_map = &env_map,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = timeout,
    }) catch |err| switch (err) {
        // Wall-clock budget for this input expired. The harness in
        // std.process.run takes care of killing the child.
        error.Timeout => return .timeout,
        // StreamTooLong is benign — the compiler dumped >1MiB of
        // output. Treat as ok-but-noisy; no need to flag.
        error.StreamTooLong => return .compiler_error,
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    return classifyTerm(result.term);
}

fn classifyTerm(term: std.process.Child.Term) Outcome {
    return switch (term) {
        .exited => |code| switch (code) {
            0 => .ok,
            // home returns 1 for "you gave me bad code" — including
            // parse errors, type errors, and unknown commands. None
            // of those are bugs; they're the compiler doing its job.
            1 => .compiler_error,
            // Any other exit code (2 = misuse, 134 = abort, etc.)
            // is suspicious. Flag it.
            else => .{ .crash = "unexpected non-zero exit code" },
        },
        // SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGFPE, etc. — all bad.
        .signal => .{ .crash = "killed by signal" },
        .stopped => .{ .crash = "process stopped" },
        .unknown => .{ .crash = "unknown termination" },
    };
}

/// Generate one fuzz input from the corpus. Either pick a seed and
/// mutate it, or (1-in-N) generate purely random bytes. The mix gives
/// us both grammar-aware exploration (mutate a real Home program) and
/// adversarial coverage (totally bogus bytes — UTF-8 boundaries, NULs,
/// etc.).
fn mutate(
    gpa: std.mem.Allocator,
    rng: std.Random,
    corpus: []const []const u8,
) ![]u8 {
    // 1 in 16 inputs is purely random. Empirically this is enough to
    // cover the "lexer chokes on a random byte" surface without
    // dwarfing the corpus-guided iterations.
    if (rng.intRangeLessThan(u32, 0, 16) == 0) {
        const len = rng.intRangeAtMost(usize, 0, 256);
        const buf = try gpa.alloc(u8, len);
        rng.bytes(buf);
        return buf;
    }

    const seed_idx = rng.intRangeLessThan(usize, 0, corpus.len);
    const seed = corpus[seed_idx];

    // Apply 1-3 mutations. Each is a small, AFL-style edit.
    const num_mutations = rng.intRangeAtMost(u8, 1, 3);
    var current = try gpa.dupe(u8, seed);
    errdefer gpa.free(current);

    var n: u8 = 0;
    while (n < num_mutations) : (n += 1) {
        current = try applyMutation(gpa, rng, current);
    }
    return current;
}

fn applyMutation(gpa: std.mem.Allocator, rng: std.Random, input: []u8) ![]u8 {
    const op = rng.intRangeAtMost(u8, 0, 7);
    switch (op) {
        0 => { // Bit flip.
            if (input.len == 0) return input;
            const pos = rng.intRangeLessThan(usize, 0, input.len);
            const bit = rng.int(u3);
            input[pos] ^= @as(u8, 1) << bit;
            return input;
        },
        1 => { // Replace byte with random.
            if (input.len == 0) return input;
            const pos = rng.intRangeLessThan(usize, 0, input.len);
            input[pos] = rng.int(u8);
            return input;
        },
        2 => { // Insert random byte.
            if (input.len >= 4096) return input; // size cap
            const pos = if (input.len == 0) 0 else rng.intRangeAtMost(usize, 0, input.len);
            const new_buf = try gpa.alloc(u8, input.len + 1);
            @memcpy(new_buf[0..pos], input[0..pos]);
            new_buf[pos] = rng.int(u8);
            @memcpy(new_buf[pos + 1 ..], input[pos..]);
            gpa.free(input);
            return new_buf;
        },
        3 => { // Delete byte.
            if (input.len <= 1) return input;
            const pos = rng.intRangeLessThan(usize, 0, input.len);
            const new_buf = try gpa.alloc(u8, input.len - 1);
            @memcpy(new_buf[0..pos], input[0..pos]);
            @memcpy(new_buf[pos..], input[pos + 1 ..]);
            gpa.free(input);
            return new_buf;
        },
        4 => { // Insert "interesting" punctuation. Targets the lexer's
            //    multi-char token logic ("::" "->" "=>" "..").
            if (input.len >= 4096) return input;
            const choices = [_][]const u8{
                "{", "}", "(", ")", "[", "]", "\"", "'",
                "::", "->", "=>", "..", "...",
                "//", "/*", "*/", "${", "\\",
            };
            const choice = choices[rng.intRangeLessThan(usize, 0, choices.len)];
            const pos = if (input.len == 0) 0 else rng.intRangeAtMost(usize, 0, input.len);
            const new_buf = try gpa.alloc(u8, input.len + choice.len);
            @memcpy(new_buf[0..pos], input[0..pos]);
            @memcpy(new_buf[pos .. pos + choice.len], choice);
            @memcpy(new_buf[pos + choice.len ..], input[pos..]);
            gpa.free(input);
            return new_buf;
        },
        5 => { // Insert a Home keyword. Targets parser state machines.
            if (input.len >= 4096) return input;
            const kws = [_][]const u8{
                "fn ", "let ", "const ", "if ", "else ", "return ",
                "struct ", "enum ", "match ", "for ", "while ",
                "loop ", "import ", "async ", "await ", "comptime ",
            };
            const kw = kws[rng.intRangeLessThan(usize, 0, kws.len)];
            const pos = if (input.len == 0) 0 else rng.intRangeAtMost(usize, 0, input.len);
            const new_buf = try gpa.alloc(u8, input.len + kw.len);
            @memcpy(new_buf[0..pos], input[0..pos]);
            @memcpy(new_buf[pos .. pos + kw.len], kw);
            @memcpy(new_buf[pos + kw.len ..], input[pos..]);
            gpa.free(input);
            return new_buf;
        },
        6 => { // Truncate. Cheap way to test partial-input handling.
            if (input.len <= 1) return input;
            const new_len = rng.intRangeLessThan(usize, 1, input.len);
            const new_buf = try gpa.alloc(u8, new_len);
            @memcpy(new_buf, input[0..new_len]);
            gpa.free(input);
            return new_buf;
        },
        7 => { // Splice an interesting integer. Hits int-literal parsing.
            if (input.len >= 4096) return input;
            const ints = [_][]const u8{
                "0", "1", "-1", "0x0", "0xFFFFFFFF", "0xFFFFFFFFFFFFFFFF",
                "0b0", "0b1111", "0o0", "0o777",
                "9223372036854775807", "9223372036854775808",
                "1e308", "1.7976931348623157e308",
            };
            const lit = ints[rng.intRangeLessThan(usize, 0, ints.len)];
            const pos = if (input.len == 0) 0 else rng.intRangeAtMost(usize, 0, input.len);
            const new_buf = try gpa.alloc(u8, input.len + lit.len);
            @memcpy(new_buf[0..pos], input[0..pos]);
            @memcpy(new_buf[pos .. pos + lit.len], lit);
            @memcpy(new_buf[pos + lit.len ..], input[pos..]);
            gpa.free(input);
            return new_buf;
        },
        else => return input,
    }
}

/// Recursively load every file under `dir_path` as a corpus entry.
/// We don't filter by extension — anything in the corpus dir is fair
/// game so users can seed with raw bytes if they like.
fn loadCorpus(
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
        if (entry.kind != .file) continue;
        const child_path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(child_path);
        const contents = Io.Dir.cwd().readFileAlloc(io, child_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try out.append(gpa, contents);
    }
}

fn writeAll(io: Io, path: []const u8, bytes: []const u8) !void {
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var write_buf: [4096]u8 = undefined;
    var w = f.writer(io, &write_buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

/// Save a fuzz finding under `<dir>/<kind>-NNNN.home`. Best-effort:
/// if writing fails (out of space, etc.) we log and move on rather
/// than aborting the whole fuzz run.
fn saveFinding(
    io: Io,
    dir: []const u8,
    kind: []const u8,
    seq: u64,
    bytes: []const u8,
) !void {
    var name_buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}/{s}-{d:0>4}.home", .{ dir, kind, seq }) catch return;
    writeAll(io, name, bytes) catch |err| {
        std.debug.print("  warning: failed to save finding {s}: {t}\n", .{ name, err });
    };
}
