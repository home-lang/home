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
const corpus_journal = @import("corpus_journal.zig");
const corpus_selection = @import("corpus_selection.zig");
const corpus_vendor = @import("corpus_vendor.zig");
const corpus_platform = @import("corpus_platform.zig");
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

pub const FileExecution = struct {
    relative_path: []const u8,
    mode: NativeCorpusMode,
    term: std.process.Child.Term,
    timed_out: bool,
    output_complete: bool,
    timeout_ms: i64,
    stdout: []const u8,
    stderr: []const u8,
};

pub const RunOptions = struct {
    /// Called after each child completes, before its capture is released.
    /// Slices are borrowed for the duration of the call. Without a callback,
    /// the summary owns each file's capture until Summary.deinit is called.
    on_file: ?*const fn (FileExecution) anyerror!void = null,
    persist_results: bool = false,
    report_directory: ?[]const u8 = null,
    /// Explicit CI selection. Diagnostic file/subset/directory routes retain
    /// their explicitly requested files. The caller supplies pinned source
    /// bytes, and may only remove exclusions in its Home expectation source.
    selection: ?SelectionPolicy = null,
};

pub const SelectionPolicy = struct {
    context: corpus_selection.Context,
    upstream_expectations: []const u8,
    home_expectations: ?[]const u8 = null,
    options: corpus_selection.Options = .{},
    /// Replace platform fields with native probes before selecting or launching.
    detect_platform: bool = false,
    expected_platform: corpus_platform.Expected = .{},
    asan_step: bool = false,
};

test "native corpus selection records exclusions and rejects Home-only skips" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "test");
    try tmp.dir.writeFile(io, .{ .sub_path = "test/BUN_TRACKED_FILES.txt", .data = "excluded.test.js\npass.test.js\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bunfig.toml", .data = "[test]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/pass.test.js", .data = "import {test,expect} from 'bun:test'; test('registered',()=>expect(42).toBe(42));" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/excluded.test.js", .data = "throw new Error('excluded fixture must not execute');" });
    const root = try tmp.dir.realPathFileAlloc(io, "test", allocator);
    defer allocator.free(root);
    var summary = try runGateWithOptions(io, allocator, root, .{
        .persist_results = true,
        .selection = .{ .context = .{ .executable = "home", .os = "darwin", .arch = "aarch64" }, .upstream_expectations = "test/excluded.test.js [ FAIL ] # upstream fixture rule" },
    });
    defer summary.deinit(allocator);
    try std.testing.expect(!summary.blocked);
    defer Io.Dir.cwd().deleteTree(io, summary.journal.?.directory) catch {};
    try std.testing.expectEqual(@as(usize, 1), summary.files);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    const events_path = try std.fs.path.join(allocator, &.{ summary.journal.?.directory, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try Io.Dir.cwd().readFileAlloc(io, events_path, allocator, .limited(1024 * 1024));
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"event\":\"selection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "upstream fixture rule") != null);
    try std.testing.expectError(error.HomeOnlyCorpusExclusion, runGateWithOptions(io, allocator, root, .{
        .selection = .{ .context = .{ .executable = "home", .os = "darwin", .arch = "aarch64" }, .upstream_expectations = "", .home_expectations = "test/pass.test.js [ SKIP ]" },
    }));
}

pub const Summary = struct {
    files: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    todo: usize = 0,
    skipped: usize = 0,
    unsupported: usize = 0,
    // Process outcomes are separate from registered test-case counts. A script
    // can succeed without registering tests; that never invents passing cases.
    process_checks_passed: usize = 0,
    failed_files: usize = 0,
    skipped_files: usize = 0,
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
    journal: ?corpus_journal.Journal = null,
    executions: std.ArrayList(FileExecution) = .empty,
    on_file: ?*const fn (FileExecution) anyerror!void = null,
    vendor_context: ?VendorExecutionContext = null,
    launch_is_ci: bool = true,
    launch_asan_step: bool = false,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        if (self.journal) |*journal| journal.deinit();
        if (self.first_failure_file_owned) {
            allocator.free(self.first_failure_file);
        }
        if (self.first_failure_message_owned) {
            allocator.free(self.first_failure_message);
        }
        for (self.executions.items) |execution| {
            allocator.free(execution.relative_path);
            allocator.free(execution.stdout);
            allocator.free(execution.stderr);
        }
        self.executions.deinit(allocator);
        self.executions = .empty;
        self.first_failure_file = "";
        self.first_failure_file_owned = false;
        self.first_failure_message = "";
        self.first_failure_message_owned = false;
    }

    pub fn addFileResult(self: *Summary, file: test_result.FileResult) void {
        self.files += 1;
        self.passed += file.passed;
        self.failed += file.failed;
        self.todo += file.todo;
        self.skipped += file.skipped;
        self.unsupported += file.unsupported;
    }
};

fn beginSummary(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8, options: RunOptions) !Summary {
    var summary = Summary{ .on_file = options.on_file, .launch_is_ci = if (options.selection) |policy| policy.context.is_ci else true, .launch_asan_step = if (options.selection) |policy| policy.asan_step else false };
    if (options.persist_results or options.report_directory != null) {
        const env_path = try envVariableAlloc(allocator, "HOME_BUN_CORPUS_REPORT_DIR");
        defer if (env_path) |value| allocator.free(value);
        const requested = options.report_directory orelse if (env_path) |value| (if (value.len == 0) null else value) else null;
        summary.journal = try corpus_journal.Journal.create(allocator, io, requested, corpus_path);
        std.debug.print("[home-bun-corpus] results: {s}\n", .{summary.journal.?.directory});
    }
    return summary;
}

fn finishSummary(summary: *Summary) !void {
    if (summary.journal) |*journal| try journal.finish(.{
        .files = summary.files,
        .passed = summary.passed,
        .failed = summary.failed,
        .skipped = summary.skipped,
        .todo = summary.todo,
        .unsupported = summary.unsupported,
        .failed_files = summary.failed_files,
        .process_checks_passed = summary.process_checks_passed,
        .skipped_files = summary.skipped_files,
        .comment_only_files = summary.allowed_empty_files,
    });
}

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
    return runSubsetWithOptions(io, allocator, corpus_path, subset, .{});
}

pub fn runSubsetWithOptions(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8, subset: Subset, options: RunOptions) !Summary {
    if (!build_options.enable_jsc) {
        return .{
            .files = filesForSubset(subset).len,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var summary = try beginSummary(io, allocator, corpus_path, options);
    errdefer summary.deinit(allocator);
    if (summary.journal) |*journal| for (filesForSubset(subset)) |relative| {
        try journal.select(relative);
    };
    for (filesForSubset(subset)) |relative| {
        try runIsolatedRelativeFile(io, allocator, corpus_path, relative, &summary);
    }

    try finishSummary(&summary);
    return summary;
}

pub fn runGate(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8) !Summary {
    return runGateWithOptions(io, allocator, corpus_path, .{});
}

pub fn runGateWithOptions(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8, requested: RunOptions) !Summary {
    var options = requested;
    var detected: ?corpus_platform.Detected = null;
    defer if (detected) |*owned| owned.deinit();
    if (options.selection) |*policy| {
        if (policy.detect_platform) {
            detected = try corpus_platform.detect(allocator, io);
            const host = detected.?.host;
            const checked = corpus_platform.check(host, policy.expected_platform);
            if (checked.len != 0) return error.CorpusPlatformMismatch;
            inline for (.{ "os", "arch", "distro", "distro_version", "abi", "abi_version" }) |field| @field(policy.context, field) = @field(host, field);
        }
    }
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

    var summary = try beginSummary(io, allocator, corpus_path, options);
    errdefer summary.deinit(allocator);
    const show_progress = bunCorpusProgressEnabled();
    var planned: std.ArrayList([]const u8) = .empty;
    defer planned.deinit(allocator);
    if (options.selection) |policy| {
        const upstream = try corpus_selection.parseExpectations(allocator, policy.upstream_expectations);
        defer allocator.free(upstream);
        const home = try corpus_selection.parseExpectations(allocator, policy.home_expectations orelse policy.upstream_expectations);
        defer allocator.free(home);
        const modifiers = try policy.context.modifiers(allocator);
        defer corpus_selection.freeModifiers(allocator, modifiers);
        try corpus_selection.validateHomeExpectations(test_files, upstream, home, modifiers);
        const selection = try corpus_selection.select(allocator, test_files, policy.context, home, policy.options);
        defer selection.deinit(allocator);
        for (selection.selected) |index| try planned.append(allocator, test_files[index]);
        const range = bunCorpusRange(planned.items.len);
        if (summary.journal) |*journal| {
            var extra: std.ArrayList(usize) = .empty;
            defer extra.deinit(allocator);
            for (selection.selected) |index| {
                if (corpus_selection.matchingRule(test_files[index], upstream, modifiers) != null) try extra.append(allocator, index);
            }
            try journal.append(.{
                .event = "selection",
                .contract = "bun-4982b91e-primary",
                .inventory = test_files,
                .context = policy.context,
                .native_platform_detected = policy.detect_platform,
                .expected_platform = policy.expected_platform,
                .asan_step = policy.asan_step,
                .modifiers = modifiers,
                .options = policy.options,
                .upstream_expectations = upstream,
                .upstream_expectations_sha256 = @as([]const u8, &corpus_journal.hashBytes(policy.upstream_expectations)),
                .home_expectations = home,
                .home_expectations_sha256 = @as([]const u8, &corpus_journal.hashBytes(policy.home_expectations orelse policy.upstream_expectations)),
                .selected_indices = selection.selected,
                .excluded = selection.excluded,
                .additional_home_coverage = extra.items,
                .range_start = range.start,
                .range_end = range.end,
            });
        }
    } else try planned.appendSlice(allocator, test_files);
    const range = bunCorpusRange(planned.items.len);
    if (summary.journal) |*journal| for (planned.items[range.start..range.end]) |relative| {
        try journal.select(relative);
    };
    for (planned.items[range.start..range.end], range.start..) |relative, index| {
        if (show_progress) {
            std.debug.print("[home-bun-corpus] {d}/{d} {s}\n", .{ index + 1, planned.items.len, relative });
        }
        try runIsolatedRelativeFile(io, allocator, corpus_path, relative, &summary);
    }

    try finishSummary(&summary);
    return summary;
}

pub fn runDirectory(
    io: Io,
    allocator: std.mem.Allocator,
    corpus_path: []const u8,
    relative_directory: []const u8,
) !Summary {
    return runDirectoryWithOptions(io, allocator, corpus_path, relative_directory, .{});
}

pub fn runDirectoryWithOptions(
    io: Io,
    allocator: std.mem.Allocator,
    corpus_path: []const u8,
    relative_directory: []const u8,
    options: RunOptions,
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

    var summary = try beginSummary(io, allocator, corpus_path, options);
    errdefer summary.deinit(allocator);
    const show_progress = bunCorpusProgressEnabled();
    if (summary.journal) |*journal| for (test_files) |directory_relative| {
        const relative = try std.fs.path.join(allocator, &.{ relative_directory, directory_relative });
        defer allocator.free(relative);
        try journal.select(relative);
    };
    for (test_files, 0..) |directory_relative, index| {
        const corpus_relative = try std.fs.path.join(allocator, &.{ relative_directory, directory_relative });
        defer allocator.free(corpus_relative);
        if (show_progress) {
            std.debug.print("[home-bun-corpus] {d}/{d} {s}\n", .{ index + 1, test_files.len, corpus_relative });
        }
        try runIsolatedRelativeFile(io, allocator, corpus_path, corpus_relative, &summary);
    }

    try finishSummary(&summary);
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
    const end = if (limit) |count| zero_start + @min(total - zero_start, count) else total;
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
    return runFileWithOptions(io, allocator, corpus_path, relative, .{});
}

pub fn runFileWithOptions(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8, relative: []const u8, options: RunOptions) !Summary {
    if (!build_options.enable_jsc) {
        return .{
            .files = 1,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var summary = try beginSummary(io, allocator, corpus_path, options);
    errdefer summary.deinit(allocator);
    if (summary.journal) |*journal| try journal.select(relative);
    try runIsolatedRelativeFile(io, allocator, corpus_path, relative, &summary);
    try finishSummary(&summary);
    return summary;
}

pub const FileTarget = struct { corpus_path: []const u8, relative_path: []const u8 };

const VendorExecutionContext = struct {
    corpus_project_root: []const u8,
    preload: ?[]const u8 = null,
};

test "native corpus prepared vendors use project configs, forced test mode and complete outcomes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "vendor/configured/test");
    try tmp.dir.createDirPath(io, "vendor/bare/specs");
    // The old primary-project derivation would explicitly select this config.
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/bunfig.toml", .data = "[test]\npreload='./wrong-parent.js'\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/wrong-parent.js", .data = "throw new Error('incorrect vendor project root');" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/configured/package.json", .data = "{\"name\":\"configured\",\"private\":true}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/configured/bunfig.toml", .data = "[test]\npreload='./setup.js'\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/configured/setup.js", .data = "globalThis.vendorConfigLoaded=true;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/configured/test/a-fail.js", .data = "import {test,expect} from 'bun:test'; test('retained vendor failure',()=>expect(1).toBe(2));" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/configured/test/b-pass.js", .data =
        \\// Flags: --not-a-real-node-flag
        \\import {test,expect} from 'bun:test';
        \\test('normal project config and cwd',()=>{
        \\ expect(globalThis.vendorConfigLoaded).toBe(true);
        \\ expect(require('node:path').basename(process.cwd())).toBe('configured');
        \\ expect(process.env.TEST_SERIAL_ID).toBeUndefined();
        \\ expect(process.env.CI).toBe('1');
        \\});
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/bare/package.json", .data = "{\"name\":\"bare\",\"private\":true}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/bare/specs/normal.test.js", .data = "import {test,expect} from 'bun:test'; test('no config needed',()=>expect(require('node:path').basename(process.cwd())).toBe('bare'));" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const report = try std.fs.path.join(allocator, &.{ root, "configured-results" });
    defer allocator.free(report);
    var configured = try runPreparedVendorWithOptions(io, allocator, root, .{
        .package = "configured",
        .repository = "private-control",
        .tag = "fixture",
        .testExtensions = &.{"js"},
        .skipTests = .{ .bool = true },
    }, .{ .run = .{ .report_directory = report } });
    defer configured.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), configured.files);
    try std.testing.expectEqual(@as(usize, 1), configured.passed);
    try std.testing.expectEqual(@as(usize, 1), configured.failed);
    try std.testing.expectEqual(@as(usize, 1), configured.failed_files);
    try std.testing.expectEqual(@as(usize, 0), configured.unsupported + configured.process_checks_passed);
    try std.testing.expectEqual(NativeCorpusMode.test_runner, configured.executions.items[0].mode);
    const events_path = try std.fs.path.join(allocator, &.{ report, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try Io.Dir.cwd().readFileAlloc(io, events_path, allocator, .limited(1024 * 1024));
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "bun-4982b91e-vendor") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "--config=") == null);
    var bare = try runPreparedVendorWithOptions(io, allocator, root, .{ .package = "bare", .repository = "private-control", .tag = "fixture", .testPath = "specs" }, .{});
    defer bare.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), bare.passed);
    try std.testing.expectEqual(@as(usize, 0), bare.failed_files + bare.failed + bare.unsupported);
}

pub const VendorRunOptions = struct {
    run: RunOptions = .{},
    filters: []const []const u8 = &.{},
    checkout_revision: ?[]const u8 = null,
};

/// Execute a prepared vendor project. Installation/build belong to the outer
/// CI coordinator; this entrypoint records that they were NOT performed here.
pub fn runPreparedVendorWithOptions(io: Io, allocator: std.mem.Allocator, project_root: []const u8, vendor: corpus_vendor.Vendor, options: VendorRunOptions) !Summary {
    if (!build_options.enable_jsc) return .{ .blocked = true, .reason = "jsc-disabled" };
    if (options.run.selection != null) return error.PrimarySelectionNotApplicableToVendor;
    const root = try Io.Dir.cwd().realPathFileAlloc(io, project_root, allocator);
    defer allocator.free(root);
    const vendor_path = try std.fs.path.join(allocator, &.{ root, "vendor", vendor.package });
    defer allocator.free(vendor_path);
    const package_path = try std.fs.path.join(allocator, &.{ vendor_path, "package.json" });
    defer allocator.free(package_path);
    try Io.Dir.cwd().access(io, package_path, .{});
    const test_path = try std.fs.path.join(allocator, &.{ vendor_path, vendor.testDirectory() });
    defer allocator.free(test_path);
    const entries = try corpus_vendor.collectEntries(allocator, io, test_path);
    defer corpus.freeTestFiles(allocator, entries);
    var filter = try corpus_vendor.Filter.init(allocator, vendor);
    defer filter.deinit(allocator);
    var inventory: std.ArrayList([]const u8) = .empty;
    defer {
        for (inventory.items) |path| allocator.free(path);
        inventory.deinit(allocator);
    }
    var selected: std.ArrayList(usize) = .empty;
    defer selected.deinit(allocator);
    const Exclusion = struct { index: usize, reason: []const u8, skip_pattern: ?[]const u8 = null };
    var excluded: std.ArrayList(Exclusion) = .empty;
    defer excluded.deinit(allocator);
    for (entries, 0..) |entry, index| {
        const relative = try std.fs.path.join(allocator, &.{ vendor.testDirectory(), entry });
        inventory.append(allocator, relative) catch |err| {
            allocator.free(relative);
            return err;
        };
        const absolute = try std.fs.path.join(allocator, &.{ vendor_path, relative });
        defer allocator.free(absolute);
        const decision = filter.decide(entry, absolute, options.filters);
        if (decision == .selected) try selected.append(allocator, index) else try excluded.append(allocator, .{
            .index = index,
            .reason = @tagName(decision),
            .skip_pattern = if (decision == .skip_rule) decision.skip_rule else null,
        });
    }
    const preload = if (!std.mem.eql(u8, vendor.runner(), "bun")) blk: {
        const filename = try std.fmt.allocPrint(allocator, "{s}.ts", .{vendor.runner()});
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ root, "test", "runners", filename });
        errdefer allocator.free(path);
        try Io.Dir.cwd().access(io, path, .{});
        break :blk path;
    } else null;
    defer if (preload) |path| allocator.free(path);
    var summary = try beginSummary(io, allocator, vendor_path, options.run);
    errdefer summary.deinit(allocator);
    summary.vendor_context = .{ .corpus_project_root = root, .preload = preload };
    // Context borrows this call's paths and is only used during execution.
    const range = bunCorpusRange(selected.items.len);
    if (summary.journal) |*journal| {
        try journal.append(.{
            .event = "selection",
            .contract = "bun-4982b91e-vendor",
            .vendor = vendor,
            .checkout_revision = options.checkout_revision,
            .setup_performed = false,
            .execution = "prepared-vendor",
            .filters = options.filters,
            .inventory = inventory.items,
            .selected_indices = selected.items,
            .excluded = excluded.items,
            .additional_home_coverage = @as([]const usize, &.{}),
            .range_start = range.start,
            .range_end = range.end,
        });
        for (selected.items[range.start..range.end]) |index| try journal.select(inventory.items[index]);
    }
    for (selected.items[range.start..range.end], range.start..) |index, ordinal| {
        if (bunCorpusProgressEnabled()) std.debug.print("[home-bun-corpus] vendor {s} {d}/{d} {s}\n", .{ vendor.package, ordinal + 1, selected.items.len, inventory.items[index] });
        try runIsolatedRelativeFile(io, allocator, vendor_path, inventory.items[index], &summary);
    }
    try finishSummary(&summary);
    summary.vendor_context = null;
    return summary;
}

pub fn runFilesWithOptions(io: Io, allocator: std.mem.Allocator, files: []const FileTarget, options: RunOptions) !Summary {
    if (!build_options.enable_jsc) return .{ .files = files.len, .blocked = true, .reason = "jsc-disabled" };
    var summary = try beginSummary(io, allocator, "", options);
    errdefer summary.deinit(allocator);
    if (summary.journal) |*journal| {
        const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cwd);
        for (files) |file| {
            const path = try std.fs.path.resolve(allocator, &.{ cwd, file.corpus_path, file.relative_path });
            defer allocator.free(path);
            try journal.select(path);
        }
    }
    for (files) |file| try runIsolatedRelativeFile(io, allocator, file.corpus_path, file.relative_path, &summary);
    try finishSummary(&summary);
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

pub const NativeCorpusMode = enum { script, test_runner };

fn isNativeHomeCorpusFile(relative: []const u8) bool {
    return corpus.isJavaScriptFile(relative);
}

fn isNativeExpectedFailureCorpusFile(relative: []const u8) bool {
    return std.mem.eql(u8, relative, "js/bun/test/test-fixture-diff-indexed-properties.js");
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
    config_path: ?[]const u8,
    absolute_fixture_path: []const u8,
    mode: NativeCorpusMode,
) ![][]const u8 {
    const offset: usize = if (config_path != null) 2 else 1;
    const args = try allocator.alloc([]const u8, flags.len + offset + 1);
    errdefer allocator.free(args);
    args[0] = if (mode == .test_runner) "test" else "run";
    // Bun declares config as an optional-value flag. Like pinned CI, attach
    // its value so script dispatch cannot mistake the TOML for the entrypoint.
    if (config_path) |path| args[1] = try std.fmt.allocPrint(allocator, "--config={s}", .{path});
    @memcpy(args[offset .. offset + flags.len], flags);
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
        if (nativeDiagnosticContains(output, "undefined")) return false;
    }
    return nativeDiagnosticContains(stdout, "expect(received).toEqual(expected)") or
        nativeDiagnosticContains(stderr, "expect(received).toEqual(expected)");
}

// ANSI styling is presentation; evaluate the complete diagnostic text without
// changing the original CI color settings or truncating retained output.
fn nativeDiagnosticContains(output: []const u8, needle: []const u8) bool {
    const Characters = struct {
        bytes: []const u8,
        index: usize = 0,

        fn next(self: *@This()) ?u8 {
            while (self.index < self.bytes.len) {
                if (self.bytes[self.index] == 0x1b and self.index + 1 < self.bytes.len and self.bytes[self.index + 1] == '[') {
                    self.index += 2;
                    while (self.index < self.bytes.len and !(self.bytes[self.index] >= 0x40 and self.bytes[self.index] <= 0x7e)) self.index += 1;
                    if (self.index < self.bytes.len) self.index += 1;
                    continue;
                }
                const char = self.bytes[self.index];
                self.index += 1;
                return char;
            }
            return null;
        }
    };
    if (needle.len == 0) return true;
    var cursor = Characters{ .bytes = output };
    while (cursor.next()) |char| {
        if (char != needle[0]) continue;
        var candidate = cursor;
        var matches = true;
        for (needle[1..]) |expected| {
            if (candidate.next() != expected) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
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
    timeout_ms: i64,
    term: std.process.Child.Term,
    timed_out: bool,
    stdout: []const u8,
    stderr: []const u8,
) ![]u8 {
    const outcome = if (timed_out)
        try std.fmt.allocPrint(allocator, "timed out after {d} milliseconds", .{timeout_ms})
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

    const source = Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        if (summary.journal) |*journal| try journal.append(.{ .event = "preparation_failed", .id = summary.files, .path = file_path, .error_name = @errorName(err) });
        return err;
    };
    defer allocator.free(source);

    if (isNativeHomeCorpusFile(relative) or summary.vendor_context != null) {
        const absolute_fixture_path = try Io.Dir.cwd().realPathFileAlloc(io, file_path, allocator);
        defer allocator.free(absolute_fixture_path);

        var flags = if (summary.vendor_context != null) OwnedFlags{} else try parseNativeCorpusFlags(allocator, source);
        defer flags.deinit(allocator);
        const mode = if (summary.vendor_context != null) NativeCorpusMode.test_runner else nativeCorpusModeForSource(relative, source);
        const node_test = summary.vendor_context == null and corpus.isNodeTestFile(relative);

        const absolute_corpus_path = try Io.Dir.cwd().realPathFileAlloc(io, corpus_path, allocator);
        defer allocator.free(absolute_corpus_path);
        const corpus_project_root = if (summary.vendor_context != null) absolute_corpus_path else std.fs.path.dirname(absolute_corpus_path) orelse return error.InvalidCorpusRoot;
        const config_path = if (summary.vendor_context != null) null else try std.fs.path.join(allocator, &.{ corpus_project_root, if (node_test) "bunfig.node-test.toml" else "bunfig.toml" });
        defer if (config_path) |path| allocator.free(path);
        if (summary.vendor_context) |vendor| if (vendor.preload) |path| {
            try flags.values.ensureUnusedCapacity(allocator, 2);
            flags.values.appendAssumeCapacity(try allocator.dupe(u8, "--preload"));
            flags.values.appendAssumeCapacity(try allocator.dupe(u8, path));
        };
        const args_tail = try buildNativeCorpusArgs(allocator, flags.values.items, config_path, absolute_fixture_path, mode);
        defer allocator.free(args_tail);
        defer if (config_path != null) allocator.free(args_tail[1]);

        const test_thread_id = try std.fmt.allocPrint(allocator, "home-corpus-{s}", .{std.fs.path.basename(relative)});
        defer allocator.free(test_thread_id);

        const source_hash = corpus_journal.hashBytes(source);
        const id = summary.files;
        const junit_path = if (summary.journal) |*journal| (if (mode == .test_runner and !node_test) try journal.artifactPath(id, "junit.xml") else null) else null;
        defer if (junit_path) |path| allocator.free(path);
        const validation_relative = if (summary.vendor_context) |vendor| try std.fs.path.relative(allocator, vendor.corpus_project_root, null, vendor.corpus_project_root, absolute_fixture_path) else null;
        defer if (validation_relative) |path| allocator.free(path);
        var native_run = try jsc_bootstrap.runHomeCapturedWithOptions(allocator, test_thread_id, args_tail, .{
            .corpus_project_root = corpus_project_root,
            .junit_path = junit_path,
            .record = if (summary.journal) |*journal| .{ .journal = journal, .id = id, .mode = @tagName(mode), .source_sha256 = source_hash } else null,
            .corpus_file = .{ .relative_path = relative, .node_test = node_test, .test_runner = mode == .test_runner, .is_ci = summary.launch_is_ci, .asan_step = summary.launch_asan_step },
            .corpus_validation_root = if (summary.vendor_context) |vendor| vendor.corpus_project_root else null,
            .corpus_validation_relative_path = validation_relative,
            .vendor_test = summary.vendor_context != null,
        });
        defer native_run.deinit(allocator);
        const execution = FileExecution{
            .relative_path = relative,
            .mode = mode,
            .term = native_run.term,
            .timed_out = native_run.timed_out,
            .output_complete = native_run.output_complete,
            .timeout_ms = native_run.timeout_ms,
            .stdout = native_run.stdout,
            .stderr = native_run.stderr,
        };
        const counts = nativeCorpusTestCounts(native_run.stdout, native_run.stderr);
        const after_source = Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024)) catch null;
        defer if (after_source) |bytes| allocator.free(bytes);
        const source_unchanged = if (after_source) |bytes| std.mem.eql(u8, source, bytes) else false;
        const expected_failure_verified = summary.vendor_context == null and nativeExpectedFailureCorpusPassed(relative, native_run.term, native_run.timed_out, native_run.stdout, native_run.stderr);
        const report_retained = if (summary.journal) |*journal| try journal.complete(id, native_run.term, native_run.timed_out, native_run.stdout, native_run.stderr, counts, native_run.output_complete, source_unchanged, junit_path, expected_failure_verified) else true;
        const missing_case_report = !report_retained and counts.passed + counts.failed + counts.skipped + counts.todo != 0;
        if (summary.on_file) |on_file| try on_file(execution);

        if (summary.vendor_context == null and isNativeExpectedFailureCorpusFile(relative)) {
            if (expected_failure_verified and source_unchanged and !missing_case_report) {
                summary.process_checks_passed += 1;
            } else {
                file_result.passed = counts.passed;
                file_result.failed = counts.failed;
                file_result.skipped = counts.skipped;
                file_result.todo = counts.todo;
                summary.failed_files += 1;
                const diagnostic = try std.fmt.allocPrint(
                    allocator,
                    "native Home expected-failure fixture did not emit exactly one indexed-property diff without undefined values\nstderr:\n{s}\nstdout:\n{s}",
                    .{ native_run.stderr, native_run.stdout },
                );
                defer allocator.free(diagnostic);
                try recordFailure(allocator, summary, relative, diagnostic);
            }
        } else {
            if (counts.observed) {
                file_result.passed = counts.passed;
                file_result.failed = counts.failed;
                file_result.todo = counts.todo;
                file_result.skipped = counts.skipped;
            }
            if (!nativeCorpusProcessSucceeded(native_run.term, native_run.timed_out) or counts.failed != 0 or !source_unchanged or missing_case_report) {
                summary.failed_files += 1;
                const diagnostic = if (!source_unchanged) try allocator.dupe(u8, "original corpus source changed during execution") else if (missing_case_report) try allocator.dupe(u8, "native JUnit report missing for registered test cases") else try nativeCorpusFailureDiagnostic(
                    allocator,
                    native_run.timeout_ms,
                    native_run.term,
                    native_run.timed_out,
                    native_run.stdout,
                    native_run.stderr,
                );
                defer allocator.free(diagnostic);
                try recordFailure(allocator, summary, relative, diagnostic);
            } else if (!hasActiveScriptSource(source)) {
                summary.allowed_empty_files += 1;
            } else if (nativeCorpusSkipReason(native_run.stdout, native_run.stderr) != null) {
                // Original Node TAP skips describe platform applicability, not
                // missing Home behavior or passing feature assertions.
                summary.skipped_files += 1;
            } else if (counts.passed + counts.failed + counts.skipped + counts.todo == 0) {
                // Pinned CI judges original script bodies by process exit,
                // including strict-name files with their own assertion loops.
                // Keep this observation separate from registered test cases.
                summary.process_checks_passed += 1;
            }
        }
        summary.addFileResult(file_result);
        if (summary.on_file == null) {
            var owned = execution;
            owned.relative_path = try allocator.dupe(u8, relative);
            errdefer allocator.free(owned.relative_path);
            try summary.executions.append(allocator, owned);
            // Transfer the complete capture without copying growing aggregate
            // buffers or dropping stderr from successful files.
            native_run.stdout = &.{};
            native_run.stderr = &.{};
        }
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

test "native corpus expected failure accepts only the indexed-property diff contract" {
    const relative = "js/bun/test/test-fixture-diff-indexed-properties.js";
    const output =
        "error: expect(received).toEqual(expected)\n" ++
        " 0 pass\n 1 fail\nRan 1 test across 1 file. [1ms]\n";
    try std.testing.expect(nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, false, "", output));
    const colored = "error: \x1b[2mexpect(\x1b[0m\x1b[31mreceived\x1b[0m).toEqual(\x1b[32mexpected\x1b[0m)\n 0 pass\n 1 fail\nRan 1 test across 1 file. [1ms]\n";
    try std.testing.expect(nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, false, "", colored));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, false, "", colored ++ "un\x1b[31mdefined\x1b[0m"));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed(relative, .{ .exited = 0 }, false, "", output));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, true, "", output));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, false, "", output ++ "undefined\n"));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed(relative, .{ .exited = 1 }, false, "", " 0 pass\n 1 fail\nRan 1 test across 1 file. [1ms]\n"));
    try std.testing.expect(!nativeExpectedFailureCorpusPassed("js/bun/test/other-fixture.js", .{ .exited = 1 }, false, "", output));
}

test "native Bun test fixtures and interop consumers execute unchanged through the corpus gate" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const cases = [_]struct { path: []const u8, passed: usize, todo: usize = 0, skipped: usize = 0, allowed_empty: usize = 0, process_checks: usize = 0 }{
        // An interop shim, not a test file: it exports the bun:test surface for
        // other suites and registers no cases of its own. A file with a live
        // body and no registered tests is counted as a process check, never as
        // a pass, so `.passed = 1` was unreachable. Assert the process check so
        // the file is still verified to execute cleanly.
        .{ .path = "js/bun/test/test-interop.js", .passed = 0, .process_checks = 1 },
        .{ .path = "js/bun/test/test-fixture-diff-indexed-properties.js", .passed = 1 },
        .{ .path = "js/bun/test/expect-extend.test.js", .passed = 28 },
        .{ .path = "js/bun/test/mock-fn.test.js", .passed = 72 },
        .{ .path = "js/bun/test/expect.test.js", .passed = 398, .todo = 10 },
        .{ .path = "js/bun/test/fake-timers/sinonjs/fake-timers.test.ts", .passed = 0, .todo = 438 },
        .{ .path = "js/bun/test/test-test.test.ts", .passed = 24, .skipped = 16 },
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
        if (summary.failed != 0 or summary.failed_files != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != case.todo or summary.skipped != case.skipped) {
            std.debug.print(
                "native Bun test fixture mismatch for {s}: passed={} todo={} failed={} unsupported={} message={s}\n",
                .{ case.path, summary.passed, summary.todo, summary.failed, summary.unsupported, summary.first_failure_message },
            );
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(case.todo, summary.todo);
        try std.testing.expectEqual(case.skipped, summary.skipped);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.failed_files);
        try std.testing.expectEqual(@as(usize, 0), summary.unsupported);
        try std.testing.expectEqual(case.allowed_empty, summary.allowed_empty_files);
        if (case.process_checks != 0) {
            try std.testing.expectEqual(case.process_checks, summary.process_checks_passed);
        }
    }
}

test "native HTML web corpus executes all five original files and real children" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const cases = [_]struct { path: []const u8, passed: usize, skipped: usize = 0 }{
        .{ .path = "js/web/html/FormData-file-error-leak.test.ts", .passed = 1 },
        .{ .path = "js/web/html/FormData-multipart-serialization.test.ts", .passed = if (builtin.os.tag == .linux) 4 else 3, .skipped = if (builtin.os.tag == .linux) 0 else 1 },
        .{ .path = "js/web/html/FormData.test.ts", .passed = 129 },
        .{ .path = "js/web/html/URLSearchParams.test.ts", .passed = 11 },
        .{ .path = "js/web/html/html-rewriter-doctype.test.ts", .passed = 1 },
    };
    for (cases) |case| {
        try std.testing.expect(isNativeHomeCorpusFile(case.path));
        try std.testing.expectEqual(NativeCorpusMode.test_runner, nativeCorpusMode(case.path));
        var summary = try runFile(threaded.io(), allocator, "packages/runtime/test/test", case.path);
        defer summary.deinit(allocator);
        if (summary.failed != 0 or summary.failed_files != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.skipped != case.skipped or summary.todo != 0) {
            std.debug.print("native HTML web corpus mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(case.skipped, summary.skipped);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.failed_files + summary.unsupported + summary.allowed_empty_files);
    }
}

test "native body corpus executes the full seven-file matrix with upstream skips" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const cases = [_]struct { path: []const u8, passed: usize, skipped: usize = 0 }{
        .{ .path = "js/web/fetch/body-async-iterator.test.ts", .passed = 2 },
        .{ .path = "js/web/fetch/body-clone.test.ts", .passed = 25 },
        .{ .path = "js/web/fetch/body-mixin-errors.test.ts", .passed = 2 },
        .{ .path = "js/web/fetch/body-stream-excess.test.ts", .passed = 4 },
        .{ .path = "js/web/fetch/body-stream.test.ts", .passed = 9086 },
        .{ .path = "js/web/fetch/body.test.ts", .passed = 346, .skipped = 4 },
        .{ .path = "js/web/fetch/request-cyclic-reference.test.ts", .passed = 2 },
    };
    for (cases) |case| {
        try std.testing.expect(isNativeHomeCorpusFile(case.path));
        try std.testing.expectEqual(NativeCorpusMode.test_runner, nativeCorpusMode(case.path));
        var summary = try runFile(threaded.io(), allocator, "packages/runtime/test/test", case.path);
        defer summary.deinit(allocator);
        if (summary.failed != 0 or summary.failed_files != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.skipped != case.skipped or summary.todo != 0) {
            std.debug.print("native body corpus mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(case.skipped, summary.skipped);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.failed_files + summary.unsupported + summary.allowed_empty_files);
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
        if (summary.failed != 0 or summary.failed_files != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != 0) {
            std.debug.print("native Blob corpus mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.failed_files + summary.todo + summary.unsupported + summary.allowed_empty_files);
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
        if (summary.failed != 0 or summary.failed_files != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != 0) {
            std.debug.print("native Headers/Response mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.failed_files + summary.todo + summary.unsupported + summary.allowed_empty_files);
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
        if (summary.failed != 0 or summary.failed_files != 0 or summary.unsupported != 0 or summary.passed != case.passed or summary.todo != 0) {
            std.debug.print("native Request mismatch for {s}: passed={} failed={} todo={} unsupported={} message={s}\n", .{ case.path, summary.passed, summary.failed, summary.todo, summary.unsupported, summary.first_failure_message });
        }
        try std.testing.expectEqual(@as(usize, 1), summary.files);
        try std.testing.expectEqual(case.passed, summary.passed);
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.failed_files);
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
        try std.testing.expectEqual(@as(usize, 0), summary.failed + summary.failed_files + summary.todo + summary.unsupported);
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
    defer allocator.free(args[1]);
    try std.testing.expectEqual(@as(usize, 5), args.len);
    try std.testing.expectEqualStrings("run", args[0]);
    try std.testing.expectEqualStrings("--config=/corpus/bunfig.node-test.toml", args[1]);
    try std.testing.expectEqualStrings("--experimental-stream-iter", args[2]);
    try std.testing.expectEqualStrings("--no-warnings", args[3]);
    try std.testing.expectEqualStrings("/corpus/test/node.js", args[4]);
}

test "native corpus launch applies CI environment and removes per-file storage" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "test");
    try tmp.dir.writeFile(io, .{ .sub_path = "bunfig.toml", .data = "[test]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/launch.test.js", .data =
        \\import { test, expect } from "bun:test";
        \\import { realpathSync, readdirSync } from "node:fs";
        \\console.log("launch-temp=" + process.env.TEST_TMPDIR);
        \\test("CI startup and real command aliases", () => {
        \\  for (const key of ["BUN_GARBAGE_COLLECTOR_LEVEL", "BUN_FEATURE_FLAG_INTERNAL_FOR_TESTING"]) expect(process.env[key]).toBe("1");
        \\  expect(process.env.BUN_JSC_randomIntegrityAuditRate).toBe("1.0");
        \\  expect(process.env.BUN_RUNTIME_TRANSPILER_CACHE_PATH).toBe("0");
        \\  expect(readdirSync(process.env.BUN_INSTALL_CACHE_DIR)).toEqual([]);
        \\  expect(process.env.BUN_INSTALL_CACHE_DIR).toBe(process.env.TEST_TMPDIR);
        \\  expect(process.env.BUN_TMPDIR).toBe(process.env.TEST_TMPDIR);
        \\  expect(process.env.GITHUB_ACTIONS).toBe("true");
        \\  for (const command of ["bun", "home"]) {
        \\    const child = Bun.spawnSync([command, "-e", "console.log(require('node:fs').realpathSync(process.execPath)); process.exit(17)"]);
        \\    expect(child.exitCode).toBe(17);
        \\    expect(child.stdout.toString().trim()).toBe(realpathSync(process.execPath));
        \\  }
        \\});
    });
    const root = try tmp.dir.realPathFileAlloc(io, "test", allocator);
    defer allocator.free(root);
    var previous: ?[]u8 = null;
    defer if (previous) |path| allocator.free(path);
    for (0..2) |_| {
        var summary = try runFile(io, allocator, root, "launch.test.js");
        defer summary.deinit(allocator);
        if (summary.failed_files != 0) std.debug.print("{s}\n", .{summary.first_failure_message});
        try std.testing.expectEqual(@as(usize, 0), summary.failed_files);
        try std.testing.expectEqual(@as(usize, 1), summary.passed);
        const execution = summary.executions.items[0];
        try std.testing.expectEqual(@as(i64, 180_000), execution.timeout_ms);
        const start = (std.mem.indexOf(u8, execution.stdout, "launch-temp=") orelse return error.MissingLaunchDiagnostic) + "launch-temp=".len;
        const end = std.mem.indexOfScalarPos(u8, execution.stdout, start, '\n') orelse execution.stdout.len;
        const path = std.mem.trim(u8, execution.stdout[start..end], "\r");
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
        if (previous) |old| try std.testing.expect(!std.mem.eql(u8, old, path)) else previous = try allocator.dupe(u8, path);
    }
    try Io.Dir.cwd().access(io, root, .{});
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
        \\test("successful registered case", () => expect(1).toBe(1));
        \\test("second registered failure", () => expect(1).toBe(2));
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
    try tmp.dir.writeFile(io, .{ .sub_path = "test/manual.test.js", .data =
        \\const assert = require("node:assert");
        \\for (let i = 0; i < 3; i++) assert.strictEqual(i + 1, 1 + i);
        \\console.log("manual assertions executed");
        \\console.error("manual diagnostic retained");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/manual-failure.test.js", .data =
        \\require("node:assert").strictEqual(1, 2, "manual assertion fails");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/guarded.test.js", .data = "if (false) throw new Error('inactive');\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/js/node/test/parallel/test-skipped.js", .data = "console.log('1..0 # Skipped: original platform requirement');\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "test", allocator);
    defer allocator.free(root);
    var failed_child = try runFile(io, allocator, root, "child-failure.test.js");
    defer failed_child.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), failed_child.failed);
    try std.testing.expectEqual(@as(usize, 1), failed_child.failed_files);
    try std.testing.expectEqual(@as(usize, 1), failed_child.passed);
    try std.testing.expectEqual(@as(usize, 1), failed_child.executions.items.len);
    try std.testing.expect(std.mem.indexOf(u8, failed_child.executions.items[0].stdout, "real-child-exit=23") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_child.executions.items[0].stderr, "second registered failure") != null);
    var failed_node = try runFile(io, allocator, root, "js/node/test/parallel/test-node-assertion.js");
    defer failed_node.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), failed_node.failed_files);
    try std.testing.expectEqual(@as(usize, 0), failed_node.passed + failed_node.failed + failed_node.process_checks_passed);
    try std.testing.expect(std.mem.indexOf(u8, failed_node.first_failure_message, "real-node-assertion") != null);
    var top_level = try runFile(io, allocator, root, "js/node/test/parallel/test-top-level.js");
    defer top_level.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), top_level.process_checks_passed);
    try std.testing.expectEqual(@as(usize, 0), top_level.passed + top_level.failed_files);
    try std.testing.expectEqual(@as(usize, 0), top_level.failed + top_level.unsupported + top_level.allowed_empty_files);
    var manual = try runFile(io, allocator, root, "manual.test.js");
    defer manual.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), manual.process_checks_passed);
    try std.testing.expectEqual(@as(usize, 0), manual.passed + manual.failed + manual.failed_files + manual.unsupported);
    try std.testing.expect(std.mem.indexOf(u8, manual.executions.items[0].stdout, "manual assertions executed") != null);
    try std.testing.expect(std.mem.indexOf(u8, manual.executions.items[0].stderr, "manual diagnostic retained") != null);
    var manual_failure = try runFile(io, allocator, root, "manual-failure.test.js");
    defer manual_failure.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), manual_failure.failed_files);
    try std.testing.expectEqual(@as(usize, 0), manual_failure.passed + manual_failure.process_checks_passed);
    try std.testing.expect(std.mem.indexOf(u8, manual_failure.first_failure_message, "manual assertion fails") != null);
    var guarded = try runFile(io, allocator, root, "guarded.test.js");
    defer guarded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), guarded.process_checks_passed);
    try std.testing.expectEqual(@as(usize, 0), guarded.passed + guarded.failed + guarded.failed_files);
    var skipped = try runFile(io, allocator, root, "js/node/test/parallel/test-skipped.js");
    defer skipped.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), skipped.skipped_files);
    try std.testing.expectEqual(@as(usize, 0), skipped.passed + skipped.process_checks_passed + skipped.failed_files + skipped.unsupported);
    var commented = try runFile(io, allocator, root, "js/node/test/parallel/test-commented.js");
    defer commented.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), commented.passed + commented.failed + commented.unsupported + commented.process_checks_passed + commented.failed_files);
    try std.testing.expectEqual(@as(usize, 1), commented.allowed_empty_files);

    // A failing first file must not hide subsequent successful diagnostics.
    // Streaming callers receive complete captures without accumulating them.
    try tmp.dir.writeFile(io, .{
        .sub_path = "test/BUN_TRACKED_FILES.txt",
        .data = "child-failure.test.js\nmanual.test.js\n",
    });
    const Observer = struct {
        var calls: usize = 0;

        fn onFile(execution: FileExecution) !void {
            try std.testing.expect(!execution.timed_out);
            if (calls == 0) {
                try std.testing.expectEqualStrings("child-failure.test.js", execution.relative_path);
                try std.testing.expect(!nativeCorpusProcessSucceeded(execution.term, false));
                try std.testing.expect(std.mem.indexOf(u8, execution.stderr, "second registered failure") != null);
            } else {
                try std.testing.expectEqualStrings("manual.test.js", execution.relative_path);
                try std.testing.expect(nativeCorpusProcessSucceeded(execution.term, false));
                try std.testing.expect(std.mem.indexOf(u8, execution.stdout, "manual assertions executed") != null);
                try std.testing.expect(std.mem.indexOf(u8, execution.stderr, "manual diagnostic retained") != null);
            }
            calls += 1;
        }

        fn rejectOutput(_: FileExecution) !void {
            return error.CaptureSinkFailed;
        }
    };
    Observer.calls = 0;
    var streamed = try runGateWithOptions(io, allocator, root, .{ .on_file = Observer.onFile });
    defer streamed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), Observer.calls);
    try std.testing.expectEqual(@as(usize, 0), streamed.executions.items.len);
    try std.testing.expectEqual(@as(usize, 1), streamed.passed);
    try std.testing.expectEqual(@as(usize, 2), streamed.failed);
    try std.testing.expectEqual(@as(usize, 1), streamed.failed_files);
    try std.testing.expectEqual(@as(usize, 1), streamed.process_checks_passed);
    try std.testing.expectError(error.CaptureSinkFailed, runFileWithOptions(io, allocator, root, "manual.test.js", .{ .on_file = Observer.rejectOutput }));
}

test "native corpus journal retains mixed outcomes and the entire selection" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "test");
    try tmp.dir.writeFile(io, .{ .sub_path = "bunfig.toml", .data = "[test]\n" });
    const mixed_source =
        \\import { test, expect } from "bun:test";
        \\test("passing case", () => expect(1).toBe(1));
        \\test("failing case", () => expect(1).toBe(2));
        \\test.skip("skipped case", () => { throw new Error("must not execute"); });
        \\test.todo("todo case");
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "test/mixed.test.js", .data = mixed_source });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/manual.test.js", .data = "require('node:assert').strictEqual(4, 2 + 2); console.log('manual body executed');" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/empty.test.js", .data = "// intentionally empty fixture\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "test", allocator);
    defer allocator.free(root);
    const reports = try std.fs.path.join(allocator, &.{ root, "results" });
    defer allocator.free(reports);
    const files = [_]FileTarget{
        .{ .corpus_path = root, .relative_path = "mixed.test.js" },
        .{ .corpus_path = root, .relative_path = "manual.test.js" },
        .{ .corpus_path = root, .relative_path = "empty.test.js" },
    };
    var summary = try runFilesWithOptions(io, allocator, &files, .{ .report_directory = reports });
    defer summary.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), summary.files);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.skipped);
    try std.testing.expectEqual(@as(usize, 1), summary.todo);
    try std.testing.expectEqual(@as(usize, 1), summary.failed_files);
    try std.testing.expectEqual(@as(usize, 1), summary.process_checks_passed);
    try std.testing.expectEqual(@as(usize, 1), summary.allowed_empty_files);
    const events_path = try std.fs.path.join(allocator, &.{ reports, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try Io.Dir.cwd().readFileAlloc(io, events_path, allocator, .limited(65536));
    defer allocator.free(events);
    var lines = std.mem.tokenizeScalar(u8, events, '\n');
    var selected: usize = 0;
    var completed: usize = 0;
    var finished = false;
    while (lines.next()) |line| {
        const value = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer value.deinit();
        const event = value.value.object.get("event").?.string;
        if (std.mem.eql(u8, event, "selected")) selected += 1;
        if (std.mem.eql(u8, event, "started")) try std.testing.expectEqual(@as(usize, 3), selected);
        if (std.mem.eql(u8, event, "completed")) completed += 1;
        if (std.mem.eql(u8, event, "finished")) finished = value.value.object.get("all_selected_completed").?.bool;
    }
    try std.testing.expectEqual(@as(usize, 3), completed);
    try std.testing.expect(finished);
    const junit_path = try summary.journal.?.artifactPath(0, "junit.xml");
    defer allocator.free(junit_path);
    const junit = try Io.Dir.cwd().readFileAlloc(io, junit_path, allocator, .limited(65536));
    defer allocator.free(junit);
    for ([_][]const u8{ "passing case", "failing case", "skipped case", "todo case", "<failure", "<skipped", "TODO" }) |expected| try std.testing.expect(std.mem.indexOf(u8, junit, expected) != null);
    const after = try tmp.dir.readFileAlloc(io, "test/mixed.test.js", allocator, .limited(65536));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(mixed_source, after);
}

test "native corpus host checks precede discovery and local context reaches children" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.CorpusPlatformMismatch, runGateWithOptions(io, allocator, "/nonexistent-platform-control", .{
        .selection = .{ .context = .{ .executable = "home", .os = "unused", .arch = "unused" }, .upstream_expectations = "", .detect_platform = true, .expected_platform = .{ .os = "impossible-platform" } },
    }));
    var detected = try corpus_platform.detect(allocator, io);
    defer detected.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "test/js/node/test/parallel");
    try tmp.dir.writeFile(io, .{ .sub_path = "bunfig.toml", .data = "[test]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bunfig.node-test.toml", .data = "[test]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/BUN_TRACKED_FILES.txt", .data = "a.test.js\njs/node/test/parallel/test-platform-launch.js\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/a.test.js", .data = "import {test,expect} from 'bun:test'; test('local validation enabled',()=>expect(process.env.BUN_JSC_validateExceptionChecks).toBe('1'));" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/js/node/test/parallel/test-platform-launch.js", .data = "require('node:assert').strictEqual(process.env.BUN_JSC_validateExceptionChecks,'1');" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const tests = try std.fs.path.join(allocator, &.{ root, "test" });
    defer allocator.free(tests);
    const reports = try std.fs.path.join(allocator, &.{ root, "reports" });
    defer allocator.free(reports);
    var summary = try runGateWithOptions(io, allocator, tests, .{ .report_directory = reports, .selection = .{
        .context = .{ .executable = "home", .os = "placeholder", .arch = "placeholder", .is_ci = false },
        .upstream_expectations = "",
        .detect_platform = true,
        .expected_platform = .{ .os = detected.host.os, .arch = detected.host.arch },
    } });
    defer summary.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), summary.files);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 1), summary.process_checks_passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed_files + summary.failed + summary.unsupported);
    var saw_node = false;
    for (summary.executions.items) |execution| if (std.mem.indexOf(u8, execution.relative_path, "test-platform-launch") != null) {
        saw_node = true;
        try std.testing.expectEqual(@as(i64, 60_000), execution.timeout_ms);
    };
    try std.testing.expect(saw_node);
    const events_path = try std.fs.path.join(allocator, &.{ reports, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try Io.Dir.cwd().readFileAlloc(io, events_path, allocator, .limited(1024 * 1024));
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"native_platform_detected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "placeholder") == null);
}
