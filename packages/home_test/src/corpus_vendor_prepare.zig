//! Explicit pinned vendor checkout/install/build through owned native captures.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vendor_module = @import("corpus_vendor.zig");
const capture = @import("adapters/jsc_bootstrap.zig");
const launch = @import("corpus_launch.zig");
const journal_module = @import("corpus_journal.zig");
const build_options = @import("build_options");

pub const Summary = struct {
    allocator: Allocator,
    journal: journal_module.Journal,
    revision: ?[]u8 = null,
    completed: usize = 0,
    failed: usize = 0,
    pub fn successful(self: Summary) bool {
        return self.failed == 0 and self.completed == self.journal.selected and self.revision != null;
    }
    pub fn deinit(self: *Summary) void {
        if (self.revision) |revision| self.allocator.free(revision);
        self.journal.deinit();
    }
};
const Step = enum { clone, fetch, checkout, head, tag, install, build };
fn safeRelative(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var pieces = std.mem.splitScalar(u8, path, '/');
    while (pieces.next()) |piece| if (piece.len == 0 or std.mem.eql(u8, piece, ".") or std.mem.eql(u8, piece, "..")) return false;
    return true;
}
fn hashFile(io: Io, path: []const u8) ![64]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return journal_module.hashFile(io, file);
}
fn finish(summary: *Summary) !void {
    try summary.journal.finish(.{ .files = summary.completed, .passed = 0, .failed = 0, .skipped = 0, .todo = 0, .unsupported = 0, .failed_files = summary.failed, .process_checks_passed = 0, .preparation_steps_succeeded = summary.completed - summary.failed, .preparation_steps_failed = summary.failed, .vendor_revision = summary.revision, .vendor_prepared = summary.successful() });
}

/// This explicit operation prepares one vendor. Full CI performs vendor
/// checkout/discovery before primary installs and conditions later preparation
/// on its selected files; this API does not claim that orchestration is done.
pub fn prepare(allocator: Allocator, io: Io, project_root: []const u8, vendor: vendor_module.Vendor, report_directory: ?[]const u8) !Summary {
    if (!build_options.enable_jsc) return error.NativeRuntimeRequired;
    if (!safeRelative(vendor.package) or vendor.repository.len == 0 or vendor.repository[0] == '-' or vendor.tag.len == 0 or vendor.tag[0] == '-') return error.InvalidVendorSpecification;
    if (!std.mem.eql(u8, vendor.manager(), "bun")) return error.UnsupportedVendorPackageManager;
    const root = try Io.Dir.cwd().realPathFileAlloc(io, project_root, allocator);
    defer allocator.free(root);
    const cwd = try std.fs.path.join(allocator, &.{ root, "vendor", vendor.package });
    defer allocator.free(cwd);
    const present = if (Io.Dir.cwd().access(io, cwd, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    var env = try capture.inheritedEnvironmentMap(allocator);
    defer env.deinit();
    const inherited_report = env.get("HOME_BUN_CORPUS_REPORT_DIR");
    const report = report_directory orelse if (inherited_report) |path| (if (path.len != 0) path else null) else null;
    var summary = Summary{ .allocator = allocator, .journal = try journal_module.Journal.createForPurpose(allocator, io, report, root, .vendor_setup) };
    errdefer summary.deinit();
    std.debug.print("[home-bun-vendor-setup] results: {s}\n", .{summary.journal.directory});
    const spec = try std.json.Stringify.valueAlloc(allocator, vendor, .{});
    defer allocator.free(spec);
    const spec_hash = journal_module.hashBytes(spec);
    const all_steps = [_]Step{ .clone, .fetch, .checkout, .head, .tag, .install, .build };
    const steps = all_steps[@as(usize, if (present) 1 else 0)..];
    var plan: std.ArrayList(struct { path: []const u8, timeout_ms: i64 }) = .empty;
    defer plan.deinit(allocator);
    for (steps) |step| try plan.append(allocator, .{ .path = @tagName(step), .timeout_ms = if (step == .build) 60_000 else 180_000 });
    try summary.journal.append(.{ .event = "vendor_setup_plan", .contract = "bun-4982b91e-explicit-vendor-preparation", .vendor = vendor, .vendor_sha256 = @as([]const u8, &spec_hash), .clone_required = !present, .vendor_cwd = cwd, .steps = plan.items, .case_credit = 0 });
    for (steps) |step| try summary.journal.select(@tagName(step));
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(cwd).?);
    const git = try launch.resolveExecutable(allocator, io, &env, "git");
    defer allocator.free(git);
    const tag_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{vendor.tag});
    defer allocator.free(tag_ref);
    const package_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(package_path);
    const test_path = try std.fs.path.join(allocator, &.{ cwd, vendor.testDirectory() });
    defer allocator.free(test_path);
    for (steps, 0..) |step, id| {
        var result: capture.HomeCapturedResult = undefined;
        var source_hash = spec_hash;
        if (step == .install or step == .build) {
            // Checkout metadata and both required paths must exist before any
            // native preparation command. Build retains ordinary project cwd.
            if (summary.revision == null) return error.VendorRevisionUnavailable;
            try Io.Dir.cwd().access(io, test_path, .{});
            const package_hash = try hashFile(io, package_path);
            source_hash = package_hash;
            result = try capture.runHomeCapturedWithOptions(allocator, "", if (step == .install) &.{"install"} else &.{ "run", "build" }, .{ .corpus_project_root = cwd, .setup_operation = if (step == .install) .install else .build, .record = .{ .journal = &summary.journal, .id = id, .mode = if (step == .install) "vendor_install" else "vendor_build", .source_sha256 = package_hash } });
        } else {
            const argv: []const []const u8 = switch (step) {
                .clone => &.{ git, "clone", "--depth", "1", "--single-branch", vendor.repository, cwd },
                .fetch => &.{ git, "fetch", "--depth", "1", "origin", "tag", vendor.tag },
                .checkout => &.{ git, "checkout", vendor.tag },
                .head => &.{ git, "rev-parse", "--verify", "--end-of-options", "HEAD" },
                .tag => &.{ git, "rev-parse", "--verify", "--end-of-options", tag_ref },
                else => unreachable,
            };
            const working = if (step == .clone) root else cwd;
            try summary.journal.start(.{ .journal = &summary.journal, .id = id, .mode = @tagName(step), .source_sha256 = spec_hash }, argv, 180_000, working, &env);
            result = try capture.runToolCaptured(allocator, io, argv, working, 180_000);
        }
        defer result.deinit(allocator);
        const source_unchanged = if (step == .install or step == .build) blk: {
            const after = hashFile(io, package_path) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk std.mem.eql(u8, &source_hash, &after);
        } else true;
        const ok = result.term.success() and !result.timed_out and result.output_complete and source_unchanged;
        _ = try summary.journal.complete(id, result.term, result.timed_out, result.stdout, result.stderr, .{ .passed = 0, .failed = 0, .skipped = 0, .todo = 0, .observed = false }, result.output_complete, source_unchanged, null, false);
        summary.completed += 1;
        if (!ok) {
            summary.failed += 1;
            try finish(&summary);
            return summary;
        }
        if (step == .head or step == .tag) {
            const revision = std.mem.trim(u8, result.stdout, " \t\r\n");
            if (revision.len != 40) return error.InvalidVendorRevision;
            for (revision) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidVendorRevision;
            if (step == .head) summary.revision = try allocator.dupe(u8, revision) else {
                if (!std.mem.eql(u8, revision, summary.revision.?)) return error.VendorCheckoutDoesNotMatchTag;
                try summary.journal.append(.{ .event = "vendor_checkout", .revision = revision, .tag = vendor.tag, .package_sha256 = @as([]const u8, &try hashFile(io, package_path)) });
            }
        }
    }
    try finish(&summary);
    return summary;
}

test "native corpus vendor preparation clones the pinned tag and retains a build failure" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source/test");
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.writeFile(io, .{ .sub_path = "source/package.json", .data = "{\"name\":\"private-vendor\",\"scripts\":{\"postinstall\":\"bun hook.js install\",\"build\":\"bun hook.js build\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "source/hook.js", .data = "const fs=require('fs'),assert=require('assert');assert.equal(fs.realpathSync(Bun.which('node')),fs.realpathSync(process.execPath));const name=process.argv[2];fs.writeFileSync(name+'.marker',process.env.BUN_INSTALL_CACHE_DIR);if(name==='build')process.exit(7);" });
    try tmp.dir.writeFile(io, .{ .sub_path = "source/test/fixture.test.js", .data = "throw new Error('preparation must not execute test files');" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source);
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(project);
    const report = try std.fs.path.join(allocator, &.{ root, "reports" });
    defer allocator.free(report);
    const repository = try std.fmt.allocPrint(allocator, "file://{s}", .{source});
    defer allocator.free(repository);
    const commands: []const []const []const u8 = &.{
        &.{ "git", "init" },                                                                                                                              &.{ "git", "add", "." },
        &.{ "git", "-c", "user.name=Home Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "test: vendor preparation fixture" }, &.{ "git", "tag", "v1" },
    };
    for (commands) |argv| {
        var result = try capture.runToolCaptured(allocator, io, argv, source, 180000);
        defer result.deinit(allocator);
        try std.testing.expect(result.term.success() and !result.timed_out and result.output_complete);
    }
    var summary = try prepare(allocator, io, project, .{ .package = "private-vendor", .repository = repository, .tag = "v1" }, report);
    defer summary.deinit();
    try std.testing.expectEqual(@as(usize, 7), summary.completed);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expect(!summary.successful() and summary.revision != null);
    inline for (.{ "install", "build" }) |operation| {
        const marker = try std.fs.path.join(allocator, &.{ project, "vendor/private-vendor", operation ++ ".marker" });
        defer allocator.free(marker);
        const cache = try Io.Dir.cwd().readFileAlloc(io, marker, allocator, .limited(4096));
        defer allocator.free(cache);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, cache, .{}));
    }
}
