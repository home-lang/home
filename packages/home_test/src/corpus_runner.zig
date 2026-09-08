//! Native-only execution of the pinned Bun corpus.
//!
//! Every selected original file and child runs in Home's production runtime.
//! Discovery follows the pinned upstream CI runner; no source rewriting or
//! synthetic JavaScript compatibility prelude participates in execution.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const corpus = @import("corpus.zig");
const jsc_bootstrap = @import("adapters/jsc_bootstrap.zig");
const test_result = @import("result.zig");
const Io = std.Io;

pub const Subset = enum {
    minimal_js,
    bundler_core_itbundled,
    bundler_transpiler_bootstrap,

    pub fn label(self: Subset) []const u8 {
        return switch (self) {
            .minimal_js => "minimal-js",
            .bundler_core_itbundled => "bundler-core-itbundled",
            .bundler_transpiler_bootstrap => "bundler-transpiler-bootstrap",
        };
    }
};

pub const Summary = struct {
    files: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    todo: usize = 0,
    unsupported: usize = 0,
    // Files that legitimately register zero tests (e.g. Bun's empty-file.test.ts
    // regression fixture, which is only a comment). These must not be treated as a
    // `no-tests-observed` failure even though they contribute no passed/failed/todo.
    allowed_empty_files: usize = 0,
    blocked: bool = false,
    reason: []const u8 = "",
    first_failure_file: []const u8 = "",
    first_failure_file_owned: bool = false,
    first_failure_message: []const u8 = "",
    first_failure_message_owned: bool = false,
    stdout: []const u8 = "",
    stdout_owned: bool = false,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        if (self.first_failure_file_owned) {
            allocator.free(self.first_failure_file);
        }
        if (self.first_failure_message_owned) {
            allocator.free(self.first_failure_message);
        }
        if (self.stdout_owned) {
            allocator.free(self.stdout);
        }
        self.first_failure_file = "";
        self.first_failure_file_owned = false;
        self.first_failure_message = "";
        self.first_failure_message_owned = false;
        self.stdout = "";
        self.stdout_owned = false;
    }

    pub fn addFileResult(self: *Summary, file: test_result.FileResult) void {
        self.files += 1;
        self.passed += file.passed;
        self.failed += file.failed;
        self.todo += file.todo;
        self.unsupported += file.unsupported;
    }
};

pub const minimal_js_files = [_][]const u8{
    "js/web/timers/microtask.test.js",
    "js/bun/test/expect-extend.test.js",
};

pub const bundler_core_itbundled_files = [_][]const u8{
    "bundler/bundler_html.test.ts",
    "bundler/bundler_jsx.test.ts",
    "bundler/bundler_loader.test.ts",
    "bundler/esbuild/extra.test.ts",
    "bundler/esbuild/metafile.test.ts",
    "bundler/bundler_allow_unresolved.test.ts",
};

pub const bundler_transpiler_bootstrap_files = [_][]const u8{
    "bundler/bundler_feature_flag.test.ts",
    "bundler/plugin-error-nested-throw.test.ts",
    "bundler/transpiler/decorator-metadata.test.ts",
    "bundler/transpiler/decorators.test.ts",
    "bundler/transpiler/es-decorators.test.ts",
    "bundler/transpiler/es-decorators-esbuild.test.ts",
    "bundler/transpiler/preserve-use-strict-cjs.test.ts",
    "bundler/transpiler/template-literal.test.ts",
    "bundler/transpiler/function-tostring-require.test.ts",
    "bundler/transpiler/export-default.test.js",
    "bundler/transpiler/scope-mismatch-panic.test.ts",
    "bundler/transpiler/bun-pragma.test.ts",
    "bundler/transpiler/property.test.ts",
    "bundler/transpiler/transpiler-stack-overflow.test.ts",
    "bundler/transpiler/transpiler.test.js",
    "bundler/transpiler/jsx-production.test.ts",
    "bundler/transpiler/runtime-transpiler.test.ts",
    "bundler/transpiler/macro-test.test.ts",
    "bundler/cli.test.ts",
    "bundler/resolver/cache-invalidation.test.ts",
    "bundler/resolver/cache-node-compat.test.ts",
    "bundler/resolver/cache-runtime.test.ts",
};

pub fn parseSubsetFlagValue(value: []const u8) ?Subset {
    if (std.mem.eql(u8, value, "minimal-js")) return .minimal_js;
    if (std.mem.eql(u8, value, "bundler-core-itbundled")) return .bundler_core_itbundled;
    if (std.mem.eql(u8, value, "bundler-transpiler-bootstrap")) return .bundler_transpiler_bootstrap;
    return null;
}

pub fn filesForSubset(subset: Subset) []const []const u8 {
    return switch (subset) {
        .minimal_js => minimal_js_files[0..],
        .bundler_core_itbundled => bundler_core_itbundled_files[0..],
        .bundler_transpiler_bootstrap => bundler_transpiler_bootstrap_files[0..],
    };
}

pub fn runSubset(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8, subset: Subset) !Summary {
    if (!build_options.enable_jsc) {
        return .{
            .files = filesForSubset(subset).len,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var summary = Summary{};
    for (filesForSubset(subset)) |relative| {
        try runIsolatedRelativeFile(io, allocator, corpus_path, relative, &summary);
    }

    return summary;
}

pub fn runGate(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8) !Summary {
    const test_files = corpus.collectTrackedTestFiles(io, allocator, corpus_path) catch |err| switch (err) {
        error.FileNotFound => return .{ .blocked = true, .reason = "corpus-not-found" },
        else => return err,
    };
    defer corpus.freeTestFiles(allocator, test_files);

    if (!build_options.enable_jsc) {
        return .{
            .files = test_files.len,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var summary = Summary{};
    const show_progress = bunCorpusProgressEnabled();
    const range = bunCorpusRange(test_files.len);
    for (test_files[range.start..range.end], range.start..) |relative, index| {
        if (show_progress) {
            std.debug.print("[home-bun-corpus] {d}/{d} {s}\n", .{ index + 1, test_files.len, relative });
        }
        try runIsolatedRelativeFile(io, allocator, corpus_path, relative, &summary);
    }

    return summary;
}

pub fn runDirectory(
    io: Io,
    allocator: std.mem.Allocator,
    corpus_path: []const u8,
    relative_directory: []const u8,
) !Summary {
    const test_files = corpus.collectTrackedDirectoryTestFiles(io, allocator, corpus_path, relative_directory) catch |err| switch (err) {
        error.FileNotFound => return .{ .blocked = true, .reason = "corpus-directory-not-found" },
        else => return err,
    };
    defer corpus.freeTestFiles(allocator, test_files);

    if (!build_options.enable_jsc) {
        return .{
            .files = test_files.len,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var summary = Summary{};
    const show_progress = bunCorpusProgressEnabled();
    for (test_files, 0..) |directory_relative, index| {
        const corpus_relative = try std.fs.path.join(allocator, &.{ relative_directory, directory_relative });
        defer allocator.free(corpus_relative);
        if (show_progress) {
            std.debug.print("[home-bun-corpus] {d}/{d} {s}\n", .{ index + 1, test_files.len, corpus_relative });
        }
        try runIsolatedRelativeFile(io, allocator, corpus_path, corpus_relative, &summary);
    }

    return summary;
}

fn bunCorpusProgressEnabled() bool {
    return envFlagEnabled("HOME_BUN_CORPUS_PROGRESS");
}

fn fullBunCorpusGateEnabled() bool {
    return envFlagEnabled("HOME_BUN_CORPUS_FULL");
}

fn envFlagEnabled(name: [:0]const u8) bool {
    if (builtin.is_test) {
        const value = std.testing.environ.getAlloc(std.testing.allocator, name) catch return false;
        defer std.testing.allocator.free(value);
        const text = std.mem.trim(u8, value, " \t\r\n");
        return text.len > 0 and !std.mem.eql(u8, text, "0") and !std.mem.eql(u8, text, "false");
    }
    const value = std.c.getenv(name) orelse return false;
    const text = std.mem.trim(u8, std.mem.span(value), " \t\r\n");
    return text.len > 0 and !std.mem.eql(u8, text, "0") and !std.mem.eql(u8, text, "false");
}

fn envVariablePresent(name: [:0]const u8) bool {
    if (builtin.is_test) {
        return std.testing.environ.contains(std.testing.allocator, name) catch false;
    }
    return std.c.getenv(name) != null;
}

fn envVariableAlloc(allocator: std.mem.Allocator, name: [:0]const u8) !?[]u8 {
    if (builtin.is_test) return std.testing.environ.getAlloc(allocator, name) catch null;
    const value = std.c.getenv(name) orelse return null;
    return try allocator.dupe(u8, std.mem.span(value));
}

fn bunCorpusRange(total: usize) struct { start: usize, end: usize } {
    const start = bunCorpusEnvUsize("HOME_BUN_CORPUS_START") orelse 1;
    const limit = bunCorpusEnvUsize("HOME_BUN_CORPUS_LIMIT");
    const zero_start = if (start == 0) 0 else @min(start - 1, total);
    const end = if (limit) |count| @min(total, zero_start + count) else total;
    return .{ .start = zero_start, .end = end };
}

fn bunCorpusEnvUsize(name: [:0]const u8) ?usize {
    if (builtin.is_test) {
        const value = std.testing.environ.getAlloc(std.testing.allocator, name) catch return null;
        defer std.testing.allocator.free(value);
        const text = std.mem.trim(u8, value, " \t\r\n");
        if (text.len == 0) return null;
        return std.fmt.parseUnsigned(usize, text, 10) catch null;
    }
    const value = std.c.getenv(name) orelse return null;
    const text = std.mem.trim(u8, std.mem.span(value), " \t\r\n");
    if (text.len == 0) return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}

pub fn runFile(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8, relative: []const u8) !Summary {
    if (!build_options.enable_jsc) {
        return .{
            .files = 1,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var summary = Summary{};
    try runIsolatedRelativeFile(io, allocator, corpus_path, relative, &summary);
    return summary;
}

const OwnedFlags = struct {
    values: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *OwnedFlags, allocator: std.mem.Allocator) void {
        for (self.values.items) |flag| allocator.free(flag);
        self.values.deinit(allocator);
        self.* = undefined;
    }
};

fn parseNativeCorpusFlags(allocator: std.mem.Allocator, source: []const u8) !OwnedFlags {
    var result = OwnedFlags{};
    errdefer result.deinit(allocator);

    const scan = source[0..@min(source.len, 1500)];
    var lines = std.mem.splitScalar(u8, scan, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimStart(u8, raw_line, " \t");
        if (!std.mem.startsWith(u8, line, "// Flags:")) continue;
        var flags = std.mem.tokenizeAny(u8, line["// Flags:".len..], " \t\r");
        while (flags.next()) |flag| {
            if (!std.mem.startsWith(u8, flag, "--")) continue;
            const owned_flag = try allocator.dupe(u8, flag);
            errdefer allocator.free(owned_flag);
            try result.values.append(allocator, owned_flag);
        }
        break;
    }
    return result;
}

const NativeCorpusMode = enum { script, test_runner };

fn isNativeHomeCorpusFile(relative: []const u8) bool {
    return corpus.isJavaScriptFile(relative);
}

fn isNativeExpectedFailureCorpusFile(relative: []const u8) bool {
    return std.mem.eql(u8, relative, "js/bun/test/test-fixture-diff-indexed-properties.js");
}

fn isNativePlatformAuditCorpusFile(relative: []const u8) bool {
    return std.mem.eql(u8, relative, "js/bun/symbols.test.ts");
}

fn nativeCorpusMode(relative: []const u8) NativeCorpusMode {
    if (isNativeExpectedFailureCorpusFile(relative)) return .test_runner;
    return if (corpus.isNodeTestFile(relative) or !corpus.isTestStrictFile(relative)) .script else .test_runner;
}

fn nativeCorpusModeForSource(relative: []const u8, source: []const u8) NativeCorpusMode {
    if (corpus.isNodeTestFile(relative)) {
        if (std.mem.indexOf(u8, relative, "needs-test") != null or std.mem.indexOf(u8, source, "node:test") != null) return .test_runner;
        inline for (.{ "test-fs-append-file-flush.js", "test-fs-write-file-flush.js", "test-fs-write-stream-flush.js" }) |name| {
            if (std.mem.eql(u8, relative, "js/node/test/parallel/" ++ name)) return .test_runner;
        }
    }
    return nativeCorpusMode(relative);
}

fn buildNativeCorpusArgs(
    allocator: std.mem.Allocator,
    flags: []const []const u8,
    config_path: []const u8,
    absolute_fixture_path: []const u8,
    mode: NativeCorpusMode,
) ![][]const u8 {
    const args = try allocator.alloc([]const u8, flags.len + 4);
    args[0] = if (mode == .test_runner) "test" else "run";
    args[1] = "--config";
    args[2] = config_path;
    @memcpy(args[3 .. 3 + flags.len], flags);
    args[args.len - 1] = absolute_fixture_path;
    return args;
}

fn hasActiveScriptSource(source: []const u8) bool {
    var i: usize = 0;
    while (i < source.len) {
        if (std.ascii.isWhitespace(source[i])) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "//")) {
            i = if (std.mem.indexOfScalarPos(u8, source, i, '\n')) |end| end + 1 else source.len;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "/*")) {
            const end = std.mem.indexOfPos(u8, source, i + 2, "*/") orelse return false;
            i = end + 2;
            continue;
        }
        return true;
    }
    return false;
}

fn nativeCorpusProcessSucceeded(term: std.process.Child.Term, timed_out: bool) bool {
    return !timed_out and term.success();
}

fn nativeCorpusAllowsNoTests(relative: []const u8) bool {
    return isNativePlatformAuditCorpusFile(relative) and builtin.os.tag != .linux and builtin.os.tag != .windows;
}

fn nativeExpectedFailureCorpusPassed(
    relative: []const u8,
    term: std.process.Child.Term,
    timed_out: bool,
    stdout: []const u8,
    stderr: []const u8,
) bool {
    if (!isNativeExpectedFailureCorpusFile(relative) or timed_out) return false;
    switch (term) {
        .exited => |code| if (code != 1) return false,
        else => return false,
    }

    const counts = nativeCorpusTestCounts(stdout, stderr);
    if (!counts.observed or counts.passed != 0 or counts.failed != 1 or counts.skipped != 0 or counts.todo != 0) return false;
    for ([_][]const u8{ stdout, stderr }) |output| {
        if (std.mem.indexOf(u8, output, "undefined") != null) return false;
    }
    return std.mem.indexOf(u8, stdout, "expect(received).toEqual(expected)") != null or
        std.mem.indexOf(u8, stderr, "expect(received).toEqual(expected)") != null;
}

fn nativeCorpusSkipReason(stdout: []const u8, stderr: []const u8) ?[]const u8 {
    for ([_][]const u8{ stdout, stderr }) |output| {
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "1..0 # Skipped:") or
                std.mem.startsWith(u8, line, "1..0 # SKIP "))
            {
                return line;
            }
        }
    }
    return null;
}

const NativeTestCounts = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    todo: usize = 0,
    observed: bool = false,
};

fn nativeCorpusTestCounts(stdout: []const u8, stderr: []const u8) NativeTestCounts {
    var counts = NativeTestCounts{};
    for ([_][]const u8{ stdout, stderr }) |output| {
        var pending = NativeTestCounts{};
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |raw_line| {
            var plain_buf: [512]u8 = undefined;
            const line = std.mem.trim(u8, stripAnsi(raw_line, &plain_buf), " \t\r");
            if (std.mem.startsWith(u8, line, "Ran ") and
                std.mem.indexOf(u8, line, " across ") != null and
                (std.mem.indexOf(u8, line, " test ") != null or std.mem.indexOf(u8, line, " tests ") != null))
            {
                pending.observed = true;
                counts = pending;
                pending = .{};
                continue;
            }
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const count = std.fmt.parseUnsigned(usize, line[0..space], 10) catch continue;
            const label = std.mem.trim(u8, line[space + 1 ..], " ");
            if (std.mem.eql(u8, label, "pass")) pending.passed = count;
            if (std.mem.eql(u8, label, "fail")) pending.failed = count;
            if (std.mem.eql(u8, label, "skip")) pending.skipped = count;
            if (std.mem.eql(u8, label, "todo")) pending.todo = count;
        }
    }
    return counts;
}

fn stripAnsi(input: []const u8, buffer: []u8) []const u8 {
    var read: usize = 0;
    var written: usize = 0;
    while (read < input.len and written < buffer.len) {
        if (input[read] == 0x1b and read + 1 < input.len and input[read + 1] == '[') {
            read += 2;
            while (read < input.len and !(input[read] >= 0x40 and input[read] <= 0x7e)) : (read += 1) {}
            if (read < input.len) read += 1;
            continue;
        }
        buffer[written] = input[read];
        written += 1;
        read += 1;
    }
    return buffer[0..written];
}

fn nativeCorpusFailureDiagnostic(
    allocator: std.mem.Allocator,
    term: std.process.Child.Term,
    timed_out: bool,
    stdout: []const u8,
    stderr: []const u8,
) ![]u8 {
    const outcome = if (timed_out)
        try allocator.dupe(u8, "timed out after 120 seconds")
    else switch (term) {
        .exited => |code| try std.fmt.allocPrint(allocator, "exited with code {d}", .{code}),
        .signal => |signal| try std.fmt.allocPrint(allocator, "terminated by SIG{s}", .{@tagName(signal)}),
        .stopped => |signal| try std.fmt.allocPrint(allocator, "stopped by SIG{s}", .{@tagName(signal)}),
        .unknown => |code| try std.fmt.allocPrint(allocator, "terminated with unknown status {d}", .{code}),
    };
    defer allocator.free(outcome);

    return std.fmt.allocPrint(
        allocator,
        "native Home corpus process {s}\nstderr:\n{s}\nstdout:\n{s}",
        .{ outcome, stderr, stdout },
    );
}

fn appendSummaryStdout(allocator: std.mem.Allocator, summary: *Summary, stdout: []const u8) !void {
    if (stdout.len == 0) return;
    const combined = try std.mem.concat(allocator, u8, &.{ summary.stdout, stdout });
    if (summary.stdout_owned) allocator.free(summary.stdout);
    summary.stdout = combined;
    summary.stdout_owned = true;
}

fn runIsolatedRelativeFile(
    io: Io,
    allocator: std.mem.Allocator,
    corpus_path: []const u8,
    relative: []const u8,
    summary: *Summary,
) !void {
    return runRelativeFile(io, allocator, corpus_path, relative, summary);
}

fn runRelativeFile(
    io: Io,
    allocator: std.mem.Allocator,
    corpus_path: []const u8,
    relative: []const u8,
    summary: *Summary,
) !void {
    var file_result = test_result.FileResult{ .path = relative };
    const file_path = try std.fs.path.join(allocator, &.{ corpus_path, relative });
    defer allocator.free(file_path);

    const source = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(source);

    if (isNativeHomeCorpusFile(relative)) {
        const absolute_fixture_path = try Io.Dir.cwd().realPathFileAlloc(io, file_path, allocator);
        defer allocator.free(absolute_fixture_path);

        var flags = try parseNativeCorpusFlags(allocator, source);
        defer flags.deinit(allocator);
        const mode = nativeCorpusModeForSource(relative, source);

        const absolute_corpus_path = try Io.Dir.cwd().realPathFileAlloc(io, corpus_path, allocator);
        defer allocator.free(absolute_corpus_path);
        const corpus_project_root = std.fs.path.dirname(absolute_corpus_path) orelse return error.InvalidCorpusRoot;
        const config_path = try std.fs.path.join(allocator, &.{ corpus_project_root, if (corpus.isNodeTestFile(relative)) "bunfig.node-test.toml" else "bunfig.toml" });
        defer allocator.free(config_path);
        const args_tail = try buildNativeCorpusArgs(allocator, flags.values.items, config_path, absolute_fixture_path, mode);
        defer allocator.free(args_tail);

        const test_thread_id = try std.fmt.allocPrint(allocator, "home-corpus-{s}", .{std.fs.path.basename(relative)});
        defer allocator.free(test_thread_id);

        var native_run = try jsc_bootstrap.runHomeCapturedWithOptions(allocator, test_thread_id, args_tail, .{
            .corpus_project_root = corpus_project_root,
        });
        defer native_run.deinit(allocator);
        try appendSummaryStdout(allocator, summary, native_run.stdout);

        if (isNativeExpectedFailureCorpusFile(relative)) {
            if (nativeExpectedFailureCorpusPassed(relative, native_run.term, native_run.timed_out, native_run.stdout, native_run.stderr)) {
                file_result.passed = 1;
            } else {
                file_result.failed = 1;
                const diagnostic = try std.fmt.allocPrint(
                    allocator,
                    "native Home expected-failure fixture did not emit exactly one indexed-property diff without undefined values\nstderr:\n{s}\nstdout:\n{s}",
                    .{ native_run.stderr, native_run.stdout },
                );
                defer allocator.free(diagnostic);
                try recordFailure(allocator, summary, relative, diagnostic);
            }
        } else if (nativeCorpusProcessSucceeded(native_run.term, native_run.timed_out)) {
            if (!hasActiveScriptSource(source)) {
                // Upstream comment-only files execute no feature assertions.
                summary.allowed_empty_files += 1;
            } else if (nativeCorpusSkipReason(native_run.stdout, native_run.stderr)) |reason| {
                file_result.unsupported = 1;
                const diagnostic = try std.fmt.allocPrint(allocator, "native Home corpus fixture skipped: {s}", .{reason});
                defer allocator.free(diagnostic);
                try recordFailure(allocator, summary, relative, diagnostic);
            } else if (mode == .test_runner) {
                const counts = nativeCorpusTestCounts(native_run.stdout, native_run.stderr);
                if (!counts.observed) {
                    file_result.unsupported = 1;
                    try recordFailure(allocator, summary, relative, "native Home test runner did not report any executed tests");
                } else if (counts.passed + counts.failed + counts.skipped + counts.todo == 0) {
                    if (corpus.isNodeTestFile(relative)) {
                        // The upstream Node launcher judges these files by
                        // process exit even when its textual node:test match
                        // selects the test runner for top-level assertions.
                        // Comment-only bodies are excluded above. This is one
                        // script-file check, as in native script mode below.
                        file_result.passed = 1;
                    } else if (nativeCorpusAllowsNoTests(relative)) {
                        summary.allowed_empty_files += 1;
                    } else {
                        file_result.unsupported = 1;
                        try recordFailure(allocator, summary, relative, "native Home test runner did not report any executed tests");
                    }
                } else {
                    file_result.passed = counts.passed;
                    file_result.failed = counts.failed;
                    // The reduced corpus runner represents both upstream
                    // `test.skip` and `test.todo` registrations in the TODO
                    // counter. Preserve that accounting when a production-VM
                    // file is executed in a child instead of treating an
                    // upstream platform/debug skip as missing Home support.
                    file_result.todo = counts.todo + counts.skipped;
                    if (counts.failed > 0) {
                        try recordFailure(allocator, summary, relative, "native Home test runner reported failed tests");
                    }
                }
            } else {
                file_result.passed = 1;
            }
        } else {
            file_result.failed = 1;
            const diagnostic = try nativeCorpusFailureDiagnostic(
                allocator,
                native_run.term,
                native_run.timed_out,
                native_run.stdout,
                native_run.stderr,
            );
            defer allocator.free(diagnostic);
            try recordFailure(allocator, summary, relative, diagnostic);
        }
        summary.addFileResult(file_result);
        return;
    }

    file_result.unsupported = 1;
    summary.addFileResult(file_result);
    try recordFailure(allocator, summary, relative, "native corpus execution requires a JavaScript or TypeScript file");
}

fn recordFailure(
    allocator: std.mem.Allocator,
    summary: *Summary,
    relative: []const u8,
    message: ?[]const u8,
) !void {
    if (summary.first_failure_file.len != 0) return;

    summary.first_failure_file = try allocator.dupe(u8, relative);
    summary.first_failure_file_owned = true;
    if (message) |text| {
        summary.first_failure_message = try allocator.dupe(u8, text);
        summary.first_failure_message_owned = true;
    } else {
        summary.first_failure_message_owned = false;
        summary.first_failure_message = "native Home execution did not provide a diagnostic";
    }
}

test "native corpus summary does not double count unsupported tests" {
    var summary = Summary{};
    summary.addFileResult(.{ .path = "fixture.js", .passed = 3, .failed = 1, .unsupported = 2, .todo = 4 });
    try std.testing.expectEqual(@as(usize, 1), summary.files);
    try std.testing.expectEqual(@as(usize, 3), summary.passed);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 2), summary.unsupported);
    try std.testing.expectEqual(@as(usize, 4), summary.todo);
}

test "native test runner counts require observed tests and retain skips" {
    const counts = nativeCorpusTestCounts("", " 7 pass\n 0 fail\n 2 skip\n 1 todo\nRan 10 tests across 1 file. [1ms]\n");
    try std.testing.expect(counts.observed);
    try std.testing.expectEqual(@as(usize, 7), counts.passed);
    try std.testing.expectEqual(@as(usize, 2), counts.skipped);
    try std.testing.expectEqual(@as(usize, 1), counts.todo);
    try std.testing.expect(!nativeCorpusTestCounts("7 pass\n", "").observed);
    try std.testing.expect(!nativeCorpusTestCounts("", "").observed);
    try std.testing.expect(nativeCorpusTestCounts("", "1 pass\n0 fail\nRan 1 test across 1 file. [1ms]").observed);
}

test "native test runner counts use the final ANSI summary instead of nested runs" {
    const output =
        " 3 pass\n 0 fail\nRan 3 tests across 3 files. [1ms]\n" ++
        "\x1b[2m 61 pass\x1b[0m\n\x1b[2m 0 fail\x1b[0m\n\x1b[2m 1 skip\x1b[0m\n" ++
        "Ran 63 tests across 1 file. \x1b[2m[2ms]\x1b[0m\n";
    const counts = nativeCorpusTestCounts("", output);
    try std.testing.expect(counts.observed);
    try std.testing.expectEqual(@as(usize, 61), counts.passed);
    try std.testing.expectEqual(@as(usize, 0), counts.failed);
    try std.testing.expectEqual(@as(usize, 1), counts.skipped);
    try std.testing.expectEqual(@as(usize, 0), counts.todo);
}

test "native corpus skip markers are not accepted as passing coverage" {
    try std.testing.expectEqualStrings("1..0 # Skipped: platform", nativeCorpusSkipReason("1..0 # Skipped: platform\n", "").?);
    try std.testing.expectEqualStrings("1..0 # SKIP unavailable", nativeCorpusSkipReason("", "1..0 # SKIP unavailable\r\n").?);
    try std.testing.expect(nativeCorpusSkipReason("", "") == null);
    try std.testing.expect(nativeCorpusSkipReason("completed\n", "") == null);
    try std.testing.expect(nativeCorpusSkipReason("diagnostic contains 1..0 # Skipped: text\n", "") == null);
}

test "native stream iterator process classification requires a clean exit" {
    try std.testing.expect(nativeCorpusProcessSucceeded(.{ .exited = 0 }, false));
    try std.testing.expect(!nativeCorpusProcessSucceeded(.{ .exited = 1 }, false));
    try std.testing.expect(!nativeCorpusProcessSucceeded(.{ .unknown = 0 }, false));
    try std.testing.expect(!nativeCorpusProcessSucceeded(.{ .exited = 0 }, true));
}

test "native Bun test fixture expected failure accepts only the indexed-property diff contract" {
    const relative = "js/bun/test/test-fixture-diff-indexed-properties.js";
    const output =
        "error: expect(received).toEqual(expected)\n" ++
        " 0 pass\n 1 fail\nRan 1 test across 1 file. [1ms]\n";
    try std.testing.expect(nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, false, "", output));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed(relative, .{ .exited = 0 }, false, "", output));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, true, "", output));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, false, "", output ++ "undefined\n"));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, false, "", " 0 pass\n 1 fail\nRan 1 test across 1 file. [1ms]\n"));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed("js/bun/test/other-fixture.js", .{ .exited = 1 }, false, "", output));
}

test "native Bun test fixtures and interop consumers execute unchanged through the corpus gate" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const cases = [_]struct { path: []const u8, passed: usize, todo: usize = 0, allowed_empty: usize = 0 }{
        .{ .path = "js/bun/test/test-interop.js", .passed = 1 },
        .{ .path = "js/bun/test/test-fixture-diff-indexed-properties.js", .passed = 1 },
        .{ .path = "js/bun/test/expect-extend.test.js", .passed = 28 },
        .{ .path = "js/bun/test/mock-fn.test.js", .passed = 72 },
        .{ .path = "js/bun/test/expect.test.js", .passed = 398, .todo = 10 },
        .{ .path = "js/bun/test/fake-timers/sinonjs/fake-timers.test.ts", .passed = 0, .todo = 438 },
        .{ .path = "js/bun/test/test-test.test.ts", .passed = 24, .todo = 16 },
        .{ .path = "js/bun/test/printing/diffexample.test.ts", .passed = 2 },
        .{ .path = "js/bun/plugin/plugins.test.ts", .passed = 31, .todo = 1 },
        .{
            .path = "js/bun/symbols.test.ts",
            .passed = if (builtin.os.tag == .linux) 2 else if (builtin.os.tag == .windows) 1 else 0,
            .allowed_empty = if (builtin.os.tag == .linux or builtin.os.tag == .windows) 0 else 1,
        },
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    for (cases) |case| {
        var summary = try runFile(
            threaded.io(),
            std.testing.allocator,
            "packages/runtime/test/test",
            case.path,
        );
        defer summary.deinit(std.testing.allocator);
        if (summary.failed != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != case.todo) {
            std.debug.print(
                "native Bun test fixture mismatch for {s}: passed={} todo={} failed={} unsupported={} message={s}\n",
                .{ case.path, summary.passed, summary.todo, summary.failed, summary.unsupported, summary.first_failure_message },
            );
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(case.todo, summary.todo);
        try std.testing.expectEqual(@as(usize, 0), summary.failed);
        try std.testing.expectEqual(@as(usize, 0), summary.unsupported);
        try std.testing.expectEqual(case.allowed_empty, summary.allowed_empty_files);
    }
}

test "native HTML web corpus executes all five original files and real children" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const cases = [_]struct { path: []const u8, passed: usize, todo: usize = 0 }{
        .{ .path = "js/web/html/FormData-file-error-leak.test.ts", .passed = 1 },
        .{ .path = "js/web/html/FormData-multipart-serialization.test.ts", .passed = if (builtin.os.tag == .linux) 4 else 3, .todo = if (builtin.os.tag == .linux) 0 else 1 },
        .{ .path = "js/web/html/FormData.test.ts", .passed = 129 },
        .{ .path = "js/web/html/URLSearchParams.test.ts", .passed = 11 },
        .{ .path = "js/web/html/html-rewriter-doctype.test.ts", .passed = 1 },
    };
    for (cases) |case| {
        try std.testing.expect(isNativeHomeCorpusFile(case.path));
        try std.testing.expectEqual(NativeCorpusMode.test_runner, nativeCorpusMode(case.path));
        var summary = try runFile(threaded.io(), allocator, "packages/runtime/test/test", case.path);
        defer summary.deinit(allocator);
        if (summary.failed != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != case.todo) {
            std.debug.print("native HTML web corpus mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(case.todo, summary.todo);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.unsupported + summary.allowed_empty_files);
    }
}

test "native body corpus executes the full seven-file matrix with upstream skips" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const cases = [_]struct { path: []const u8, passed: usize, todo: usize = 0 }{
        .{ .path = "js/web/fetch/body-async-iterator.test.ts", .passed = 2 },
        .{ .path = "js/web/fetch/body-clone.test.ts", .passed = 25 },
        .{ .path = "js/web/fetch/body-mixin-errors.test.ts", .passed = 2 },
        .{ .path = "js/web/fetch/body-stream-excess.test.ts", .passed = 4 },
        .{ .path = "js/web/fetch/body-stream.test.ts", .passed = 9086 },
        .{ .path = "js/web/fetch/body.test.ts", .passed = 346, .todo = 4 },
        .{ .path = "js/web/fetch/request-cyclic-reference.test.ts", .passed = 2 },
    };
    for (cases) |case| {
        try std.testing.expect(isNativeHomeCorpusFile(case.path));
        try std.testing.expectEqual(NativeCorpusMode.test_runner, nativeCorpusMode(case.path));
        var summary = try runFile(threaded.io(), allocator, "packages/runtime/test/test", case.path);
        defer summary.deinit(allocator);
        if (summary.failed != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != case.todo) {
            std.debug.print("native body corpus mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(case.todo, summary.todo);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.unsupported + summary.allowed_empty_files);
    }
}

test "native body corpus retains original ownership workloads" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { path: []const u8, retained: []const []const u8 }{
        .{ .path = "body-clone.test.ts", .retained = &.{ "await using proc = Bun.spawn", "i < 8", "i < 64", "clone.headers.set", "application/x-original-type-0000000000000001", "expect(exitCode).toBe(0)" } },
        .{ .path = "body.test.ts", .retained = &.{ "SZ = 2_000_000, WARM = 50, BLOCK = 40", "await using proc = Bun.spawn", "await run(BLOCK); Bun.gc(true)", "expect(block2).toBeLessThan(50)", "const it = skip ? test.skip : test" } },
        .{ .path = "request-cyclic-reference.test.ts", .retained = &.{ "i < 10000", "Bun.gc(true)", "toBeLessThanOrEqual(100)", "body: req1.body", "controller.stream2 = req2" } },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(allocator, &.{ "packages/runtime/test/test/js/web/fetch", case.path });
        defer allocator.free(path);
        const source = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);
        for (case.retained) |needle| try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);
    }
}

test "native Blob corpus executes all six original files with allocation and snapshot checks" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const cases = [_]struct { path: []const u8, passed: usize }{
        .{ .path = "js/web/fetch/blob-array-fast-path.test.ts", .passed = 11 },
        .{ .path = "js/web/fetch/blob-cow.test.ts", .passed = 1 },
        .{ .path = "js/web/fetch/blob-file-name-ownership.test.ts", .passed = 1 },
        .{ .path = "js/web/fetch/blob-oom.test.ts", .passed = 16 },
        .{ .path = "js/web/fetch/blob-write.test.ts", .passed = 10 },
        .{ .path = "js/web/fetch/blob.test.ts", .passed = 26 },
    };
    for (cases) |case| {
        try std.testing.expect(isNativeHomeCorpusFile(case.path));
        try std.testing.expectEqual(NativeCorpusMode.test_runner, nativeCorpusMode(case.path));
        var summary = try runFile(threaded.io(), allocator, "packages/runtime/test/test", case.path);
        defer summary.deinit(allocator);
        if (summary.failed != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != 0) {
            std.debug.print("native Blob corpus mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.todo + summary.unsupported + summary.allowed_empty_files);
    }
}

test "native Headers/Response original six-file matrix retains snapshots and collection workloads" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const cases = [_]struct { path: []const u8, passed: usize }{
        .{ .path = "js/web/fetch/headers.test.ts", .passed = 94 },
        .{ .path = "js/web/fetch/headers-case.test.ts", .passed = 3 },
        .{ .path = "js/web/fetch/headers.undici.test.ts", .passed = 51 },
        .{ .path = "js/web/fetch/fetch_headers.test.js", .passed = 6 },
        .{ .path = "js/web/fetch/response.test.ts", .passed = 14 },
        .{ .path = "js/web/fetch/response-cyclic-reference.test.ts", .passed = 2 },
    };
    for (cases) |case| {
        try std.testing.expect(isNativeHomeCorpusFile(case.path));
        try std.testing.expectEqual(NativeCorpusMode.test_runner, nativeCorpusMode(case.path));
        var summary = try runFile(threaded.io(), std.testing.allocator, "packages/runtime/test/test", case.path);
        defer summary.deinit(std.testing.allocator);
        if (summary.failed != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != 0) {
            std.debug.print("native Headers/Response mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.todo + summary.unsupported + summary.allowed_empty_files);
    }
}

test "native Request matrices preserve unchanged workloads and subclass dispatch" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const cases = [_]struct {
        path: []const u8,
        passed: usize,
        retained: []const []const u8,
    }{
        .{
            .path = "js/web/request/request-clone-leak.test.ts",
            .passed = 12,
            .retained = &.{ "1000 * ASAN_MULTIPLIER", "2000 * ASAN_MULTIPLIER", "j < 500;", "500 * ASAN_MULTIPLIER", "process.memoryUsage.rss()", "isASAN ? 64 : 30" },
        },
        .{
            .path = "js/web/request/request-method-getter.test.ts",
            .passed = 6,
            .retained = &.{ "1024 * 512", "1024 * 128", "heapStats()", "request.clone().method", "request.method", "toBeLessThan(512)" },
        },
        .{
            .path = "js/web/request/request-subclass.test.ts",
            .passed = 2,
            .retained = &.{ "undici-types", "constructor(input: string", "class MyRequest extends Request", "get method()", "Bun.serve({", "i < 1e4", "Invalid header name" },
        },
        .{
            .path = "js/web/request/request.test.ts",
            .passed = 4,
            .retained = &.{ "signal: undefined", "signal: null", "clone() does not lock original body", "Promise.all([request.text(), cloned.text()])" },
        },
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    for (cases) |case| {
        const source_path = try std.fs.path.join(std.testing.allocator, &.{ "packages/runtime/test/test", case.path });
        defer std.testing.allocator.free(source_path);
        const source = try Io.Dir.cwd().readFileAlloc(threaded.io(), source_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(source);
        for (case.retained) |needle| try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);

        var summary = try runFile(threaded.io(), std.testing.allocator, "packages/runtime/test/test", case.path);
        defer summary.deinit(std.testing.allocator);
        if (summary.failed != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != 0) {
            std.debug.print("native Request mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(@as(usize, 0), summary.failed);
        try std.testing.expectEqual(@as(usize, 0), summary.todo);
        try std.testing.expectEqual(@as(usize, 0), summary.unsupported);
        try std.testing.expectEqual(@as(usize, 0), summary.allowed_empty_files);
    }
}

test "native corpus execution covers previously split Request and microtask paths" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    inline for (.{
        .{ .path = "js/web/request/request.test.ts", .passed = 4 },
        .{ .path = "js/web/timers/microtask.test.js", .passed = 2 },
    }) |case| {
        var summary = try runFile(threaded.io(), std.testing.allocator, "packages/runtime/test/test", case.path);
        defer summary.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, case.passed), summary.passed);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.todo + summary.unsupported);
    }
}

test "native Blob corpus retains original prototype and ownership workloads" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { path: []const u8, retained: []const []const u8 }{
        .{ .path = "blob-array-fast-path.test.ts", .retained = &.{ "Object.defineProperty(Array.prototype, 1", "expect(calls).toBe(1)", "delete (Array.prototype as any)[1]", "i < 10000", "arr.push(\"pad\")" } },
        .{ .path = "blob-file-name-ownership.test.ts", .retained = &.{ "i < 2000", "Buffer.alloc(512", "structuredClone(f)", "Bun.gc(true)", "await using proc = Bun.spawn", "await bytesClone.text()", "await fileClone.text()", "expect(exitCode).toBe(0)" } },
        .{ .path = "blob-oom.test.ts", .retained = &.{ "setSyntheticAllocationLimitForTesting(128 * 1024 * 1024)", "64 * 1024 * 1024", "setSyntheticAllocationLimitForTesting(4 * 1024 * 1024)", "Bun.gc(true)", "longer than 2^32-1 characters", ".not.toThrow()" } },
        .{ .path = "blob.test.ts", .retained = &.{ "oddJson", "alignedText", "slice(1).text()", "Bun.spawn" } },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(allocator, &.{ "packages/runtime/test/test/js/web/fetch", case.path });
        defer allocator.free(path);
        const source = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);
        for (case.retained) |needle| try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);
    }
}

test "native HTML web corpus retains original children and memory workloads" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { path: []const u8, retained: []const []const u8 }{
        .{ .path = "FormData-file-error-leak.test.ts", .retained = &.{ "256 * 1024", "const iterations = 100", "WARMUP: \"10\"", "Bun.spawn", "toBeLessThan(isASAN ? 400 : 10)", "expect(exitCode).toBe(0)" } },
        .{ .path = "FormData-file-error-leak-fixture.ts", .retained = &.{ "process.memoryUsage.rss()", "i < iterations", "i < warmup", "Bun.gc(true)", "ENOENT" } },
        .{ .path = "FormData-multipart-serialization.test.ts", .retained = &.{ "test.skipIf(!isLinux)", "Bun.spawn" } },
        .{ .path = "FormData.test.ts", .retained = &.{ "i < 100000", "JSON.stringify(fd.toJSON())", "JSON.stringify(parsed.toJSON())", "Bun.spawn" } },
        .{ .path = "html-rewriter-doctype.test.ts", .retained = &.{ "doctype.remove()", "doctype.removed", "rewriter.transform(html)" } },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(allocator, &.{ "packages/runtime/test/test/js/web/html", case.path });
        defer allocator.free(path);
        const source = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);
        for (case.retained) |needle| try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);
    }
}

test "native Headers/Response sources retain WebIDL and cyclic stream assertions" {
    const allocator = std.testing.allocator;
    const headers = try Io.Dir.cwd().readFileAlloc(std.testing.io, "packages/runtime/test/test/js/web/fetch/headers.undici.test.ts", allocator, .limited(1024 * 1024));
    defer allocator.free(headers);
    try std.testing.expect(std.mem.indexOf(u8, headers, "fails if primitive is passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "Symbol.iterator is only accessed once") != null);
    const cyclic = try Io.Dir.cwd().readFileAlloc(std.testing.io, "packages/runtime/test/test/js/web/fetch/response-cyclic-reference.test.ts", allocator, .limited(1024 * 1024));
    defer allocator.free(cyclic);
    for ([_][]const u8{ "i < 10000", "Bun.gc(true)", "toBeLessThanOrEqual(100)" }) |needle| {
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, cyclic, needle));
    }
    try std.testing.expect(std.mem.indexOf(u8, cyclic, "new Response(response.body)") != null);
    try std.testing.expect(std.mem.indexOf(u8, cyclic, "stream.response2 = response2") != null);
}

test "native body corpus preserves every upstream stream transport and conversion dimension" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "js/web/fetch/body-stream.test.ts";
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ "packages/runtime/test/test", path });
    defer std.testing.allocator.free(source_path);
    const source = try Io.Dir.cwd().readFileAlloc(io, source_path, std.testing.allocator, std.Io.Limit.limited(1024 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "{ name: \"http/3\", http3: true }") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Request.prototype.arrayBuffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Request.prototype.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const useRequestObjectValues = [true, false]") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "for (let forceReadableStreamConversionFastPath of [true, false])") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "for (let withDelay of [false, true])") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "1024 * 1024 * 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "new DataView(bytes.buffer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "for (let isDirectStream of [true, false])") != null);
}

test "native corpus execution covers the entire pinned inventory" {
    const files = try corpus.collectTrackedTestFiles(std.testing.io, std.testing.allocator, corpus.default_root);
    defer corpus.freeTestFiles(std.testing.allocator, files);
    try std.testing.expectEqual(@as(usize, 4754), files.len);
    for (files) |path| try std.testing.expect(isNativeHomeCorpusFile(path));
    try std.testing.expect(!isNativeHomeCorpusFile("fixture.test.ts.snap"));
    try std.testing.expectEqual(NativeCorpusMode.script, nativeCorpusModeForSource("js/node/cluster/test-worker-no-exit-http.ts", "throw new Error();"));
    try std.testing.expectEqual(NativeCorpusMode.script, nativeCorpusModeForSource("js/node/test/parallel/test-buffer-isencoding.js", "require('assert').ok(true);"));
    try std.testing.expectEqual(NativeCorpusMode.test_runner, nativeCorpusModeForSource("js/node/test/parallel/test-module-isBuiltin.js", "assert(isBuiltin('node:test'));"));
    try std.testing.expect(!hasActiveScriptSource("/* disabled */\n// test('none', () => {});\n"));
    try std.testing.expect(hasActiveScriptSource("/* active */ require('assert').ok(true);"));
}

test "native corpus execution preserves flags and explicit project configuration" {
    const allocator = std.testing.allocator;
    var flags = try parseNativeCorpusFlags(allocator, "// Flags: --experimental-stream-iter --no-warnings\nrun();");
    defer flags.deinit(allocator);
    const args = try buildNativeCorpusArgs(allocator, flags.values.items, "/corpus/bunfig.node-test.toml", "/corpus/test/node.js", .script);
    defer allocator.free(args);
    try std.testing.expectEqual(@as(usize, 6), args.len);
    try std.testing.expectEqualStrings("run", args[0]);
    try std.testing.expectEqualStrings("--config", args[1]);
    try std.testing.expectEqualStrings("/corpus/bunfig.node-test.toml", args[2]);
    try std.testing.expectEqualStrings("--experimental-stream-iter", args[3]);
    try std.testing.expectEqualStrings("--no-warnings", args[4]);
    try std.testing.expectEqualStrings("/corpus/test/node.js", args[5]);
}

test "native corpus execution propagates real child and Node assertion failures" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "test/js/node/test/parallel");
    try tmp.dir.writeFile(io, .{ .sub_path = "bunfig.toml", .data = "[test]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bunfig.node-test.toml", .data = "[test]\n[install]\nauto = 'disable'\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/child-failure.test.js", .data =
        \\import { test, expect } from "bun:test";
        \\test("native child exit is observed", () => {
        \\  const child = Bun.spawnSync([process.execPath, "-e", "process.exit(23)"]);
        \\  console.log("real-child-exit=" + child.exitCode);
        \\  expect(child.exitCode).toBe(0);
        \\});
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/js/node/test/parallel/test-node-assertion.js", .data =
        \\const assert = require("node:assert");
        \\assert.strictEqual(1, 2, "real-node-assertion");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/js/node/test/parallel/test-top-level.js", .data =
        \\const assert = require("node:assert");
        \\assert(require("node:module").isBuiltin("node:test"));
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/js/node/test/parallel/test-commented.js", .data = "// upstream intentionally disabled\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "test", allocator);
    defer allocator.free(root);
    var failed_child = try runFile(io, allocator, root, "child-failure.test.js");
    defer failed_child.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), failed_child.failed);
    try std.testing.expectEqual(@as(usize, 0), failed_child.passed);
    try std.testing.expect(std.mem.indexOf(u8, failed_child.stdout, "real-child-exit=23") != null);
    var failed_node = try runFile(io, allocator, root, "js/node/test/parallel/test-node-assertion.js");
    defer failed_node.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), failed_node.failed);
    try std.testing.expect(std.mem.indexOf(u8, failed_node.first_failure_message, "real-node-assertion") != null);
    var top_level = try runFile(io, allocator, root, "js/node/test/parallel/test-top-level.js");
    defer top_level.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), top_level.passed);
    try std.testing.expectEqual(@as(usize, 0), top_level.failed + top_level.unsupported + top_level.allowed_empty_files);
    var commented = try runFile(io, allocator, root, "js/node/test/parallel/test-commented.js");
    defer commented.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), commented.passed + commented.failed + commented.unsupported);
    try std.testing.expectEqual(@as(usize, 1), commented.allowed_empty_files);
}
