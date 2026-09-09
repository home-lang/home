//! Original root/test setup through Home, with durable non-test outcomes.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const capture = @import("adapters/jsc_bootstrap.zig");
const journal_module = @import("corpus_journal.zig");
const platform = @import("corpus_platform.zig");
const build_options = @import("build_options");

pub const Input = struct { path: []const u8, sha256: []const u8 };
const Manifest = struct { bun_pin: []const u8, files: []Input };
pub const Options = struct {
    report_directory: ?[]const u8 = null,
    expected_platform: ?platform.Expected = null,
};
pub const Summary = struct {
    journal: journal_module.Journal,
    steps: usize = 0,
    succeeded: usize = 0,
    failed: usize = 0,
    inputs_unchanged: bool = true,
    pub fn deinit(self: *Summary) void {
        self.journal.deinit();
    }
    pub fn successful(self: Summary) bool {
        return self.steps == 2 and self.failed == 0 and self.inputs_unchanged;
    }
};

fn validPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn inputMatches(allocator: Allocator, io: Io, root: []const u8, input: Input) !bool {
    if (!validPath(input.path) or input.sha256.len != 64) return error.InvalidSetupInput;
    const path = try std.fs.path.join(allocator, &.{ root, input.path });
    defer allocator.free(path);
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    const digest = try journal_module.hashFile(io, file);
    return std.mem.eql(u8, &digest, input.sha256);
}

pub fn runRootInstalls(allocator: Allocator, io: Io, project_root: []const u8, options: Options) !Summary {
    if (!build_options.enable_jsc) return error.NativeRuntimeRequired;
    var env = try capture.inheritedEnvironmentMap(allocator);
    defer env.deinit();
    var detected = try platform.detect(allocator, io);
    defer detected.deinit();
    const expected = options.expected_platform orelse platform.Expected.fromEnvironment(&env);
    const checked = platform.check(detected.host, expected);
    if (checked.len != 0) return error.CorpusPlatformMismatch;
    const root = try Io.Dir.cwd().realPathFileAlloc(io, project_root, allocator);
    defer allocator.free(root);
    const raw_report = env.get("HOME_BUN_CORPUS_REPORT_DIR");
    const env_report = if (raw_report) |value| (if (value.len == 0) null else value) else null;
    var summary = Summary{ .journal = try journal_module.Journal.createForPurpose(allocator, io, options.report_directory orelse env_report, root, .setup) };
    errdefer summary.deinit();
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "BUN_SETUP_FILES.json" });
    defer allocator.free(manifest_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const manifest = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer manifest.deinit();
    const pin_path = try std.fs.path.join(allocator, &.{ root, "test", "UPSTREAM_SHA.txt" });
    defer allocator.free(pin_path);
    const pin = try Io.Dir.cwd().readFileAlloc(io, pin_path, allocator, .limited(1024));
    defer allocator.free(pin);
    if (manifest.value.bun_pin.len != 40 or !std.mem.eql(u8, manifest.value.bun_pin, std.mem.trim(u8, pin, " \t\r\n"))) return error.SetupPinMismatch;
    for (manifest.value.bun_pin) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidSetupPin;
    for (manifest.value.files, 0..) |input, index| {
        if (!validPath(input.path) or input.sha256.len != 64) return error.InvalidSetupInput;
        for (input.sha256) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidSetupInput;
        for (manifest.value.files[0..index]) |previous| if (std.mem.eql(u8, previous.path, input.path)) return error.DuplicateSetupInput;
    }
    const Step = struct { path: []const u8, operation: []const u8 = "install", timeout_ms: i64 = 180_000 };
    const steps = [_]Step{ .{ .path = "package.json" }, .{ .path = "test/package.json" } };
    try summary.journal.append(.{ .event = "setup_plan", .contract = "bun-4982b91e-root-test-setup", .bun_pin = manifest.value.bun_pin, .manifest_sha256 = @as([]const u8, &journal_module.hashBytes(bytes)), .host = detected.host, .expected_platform = expected, .inputs = manifest.value.files, .steps = steps });
    for (steps) |step| try summary.journal.select(step.path);
    for (manifest.value.files) |input| if (!try inputMatches(allocator, io, root, input)) {
        try summary.journal.append(.{ .event = "setup_input_changed", .path = input.path, .phase = "before_install" });
        return error.SetupInputChanged;
    };
    for (steps, 0..) |step, id| {
        var package_hash: ?[]const u8 = null;
        for (manifest.value.files) |input| if (std.mem.eql(u8, input.path, step.path)) {
            package_hash = input.sha256;
            break;
        };
        const hash = package_hash orelse return error.MissingSetupPackageInput;
        const cwd = if (id == 0) try allocator.dupe(u8, root) else try std.fs.path.join(allocator, &.{ root, "test" });
        defer allocator.free(cwd);
        std.debug.print("[home-bun-setup] install {s}\n", .{cwd});
        var result = try capture.runHomeCapturedWithOptions(allocator, "", &.{"install"}, .{ .corpus_project_root = cwd, .setup_operation = .install, .record = .{ .journal = &summary.journal, .id = id, .mode = "setup_install", .source_sha256 = hash[0..64].* } });
        defer result.deinit(allocator);
        var unchanged = true;
        for (manifest.value.files) |input| if (!try inputMatches(allocator, io, root, input)) {
            unchanged = false;
            try summary.journal.append(.{ .event = "setup_input_changed", .path = input.path, .phase = "after_install" });
        };
        summary.inputs_unchanged = summary.inputs_unchanged and unchanged;
        // Install output can mention tests or assertions. It never registers
        // corpus test cases and must not be parsed into their pass counters.
        _ = try summary.journal.complete(id, result.term, result.timed_out, result.stdout, result.stderr, .{ .passed = @as(usize, 0), .failed = @as(usize, 0), .skipped = @as(usize, 0), .todo = @as(usize, 0), .observed = false }, result.output_complete, unchanged, null, false);
        summary.steps += 1;
        if (result.term.success() and !result.timed_out and result.output_complete and unchanged) summary.succeeded += 1 else summary.failed += 1;
        // Pinned runTests attempts both root and test installs. A setup failure
        // prevents the later corpus/service phases; it does not skip this loop.
    }
    try summary.journal.finish(.{ .files = summary.steps, .passed = @as(usize, 0), .failed = @as(usize, 0), .skipped = @as(usize, 0), .todo = @as(usize, 0), .unsupported = @as(usize, 0), .failed_files = summary.failed, .process_checks_passed = @as(usize, 0), .setup_steps_succeeded = summary.succeeded, .setup_steps_failed = summary.failed, .inputs_unchanged = summary.inputs_unchanged });
    return summary;
}

test "native corpus setup installs and builds with owned aliases and separate outcomes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "test");
    const root_json = "{\"name\":\"native-setup-root\",\"private\":true,\"scripts\":{\"postinstall\":\"bun hook.js root\",\"build\":\"bun hook.js build\"}}";
    const test_json = "{\"name\":\"native-setup-test\",\"private\":true,\"scripts\":{\"postinstall\":\"bun ../hook.js test\"}}";
    const hook =
        \\const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert');
        \\assert.equal(process.env.BUN_GARBAGE_COLLECTOR_LEVEL,'1');
        \\assert.equal(process.env.BUN_JSC_randomIntegrityAuditRate,'1.0');
        \\assert.equal(process.env.BUN_RUNTIME_TRANSPILER_CACHE_PATH,'0');
        \\assert.equal(fs.realpathSync(Bun.which('bun')),fs.realpathSync(process.execPath));
        \\assert.equal(fs.realpathSync(Bun.which('node')),fs.realpathSync(process.execPath));
        \\assert.equal(fs.existsSync(path.join(process.env.BUN_INSTALL_CACHE_DIR,'bun')),false);
        \\const name=process.argv[2]; fs.writeFileSync(name+'.marker',process.env.BUN_INSTALL_CACHE_DIR);
        \\if(name==='root') { console.log('999 pass');process.exit(7); }
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = root_json });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/package.json", .data = test_json });
    try tmp.dir.writeFile(io, .{ .sub_path = "hook.js", .data = hook });
    const pin = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try tmp.dir.writeFile(io, .{ .sub_path = "test/UPSTREAM_SHA.txt", .data = pin });
    const manifest = try std.json.Stringify.valueAlloc(allocator, .{ .bun_pin = pin, .files = .{
        .{ .path = "package.json", .sha256 = @as([]const u8, &journal_module.hashBytes(root_json)) },
        .{ .path = "test/package.json", .sha256 = @as([]const u8, &journal_module.hashBytes(test_json)) },
        .{ .path = "hook.js", .sha256 = @as([]const u8, &journal_module.hashBytes(hook)) },
    } }, .{});
    defer allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "BUN_SETUP_FILES.json", .data = manifest });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const report = try std.fs.path.join(allocator, &.{ root, "reports" });
    defer allocator.free(report);
    var summary = try runRootInstalls(allocator, io, root, .{ .report_directory = report, .expected_platform = .{} });
    defer summary.deinit();
    if (summary.succeeded != 1 or summary.failed != 1) {
        for (0..2) |id| {
            const output = try summary.journal.artifactPath(id, "stderr");
            defer allocator.free(output);
            const contents = try Io.Dir.cwd().readFileAlloc(io, output, allocator, .limited(1024 * 1024));
            defer allocator.free(contents);
            std.debug.print("setup control {d}: {s}\n", .{ id, contents });
        }
    }
    try std.testing.expectEqual(@as(usize, 2), summary.steps);
    try std.testing.expectEqual(@as(usize, 1), summary.succeeded);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expect(!summary.successful() and summary.inputs_unchanged);
    const first = try tmp.dir.readFileAlloc(io, "root.marker", allocator, .limited(4096));
    defer allocator.free(first);
    const second = try tmp.dir.readFileAlloc(io, "test/test.marker", allocator, .limited(4096));
    defer allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, first, .{}));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, second, .{}));
    var built = try capture.runHomeCapturedWithOptions(allocator, "", &.{ "run", "build" }, .{ .corpus_project_root = root, .setup_operation = .build });
    defer built.deinit(allocator);
    try std.testing.expect(built.term.success() and !built.timed_out and built.output_complete);
    const build_cache = try tmp.dir.readFileAlloc(io, "build.marker", allocator, .limited(4096));
    defer allocator.free(build_cache);
    try std.testing.expect(!std.mem.eql(u8, first, build_cache) and !std.mem.eql(u8, second, build_cache));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, build_cache, .{}));
}
