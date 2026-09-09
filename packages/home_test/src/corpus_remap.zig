//! Pinned crash-remap service launch, lifetime, and durable non-test outcomes.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const capture = @import("adapters/jsc_bootstrap.zig");
const launch = @import("corpus_launch.zig");
const journal_module = @import("corpus_journal.zig");
const service_module = @import("corpus_service.zig");
const platform = @import("corpus_platform.zig");
const build_options = @import("build_options");

pub fn applicable(host: platform.Host, is_ci: bool) bool {
    return is_ci and !std.mem.eql(u8, host.os, "windows");
}
fn fileHash(io: Io, path: []const u8) ![64]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return journal_module.hashFile(io, file);
}
fn unchanged(io: Io, path: []const u8, expected: [64]u8) !bool {
    const actual = fileHash(io, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return std.mem.eql(u8, &actual, &expected);
}

pub const Remap = struct {
    allocator: Allocator,
    io: Io,
    journal: journal_module.Journal,
    service: *service_module.Service,
    storage: launch.Storage,
    source_path: []u8,
    source_sha256: [64]u8,
    package_path: []u8,
    package_sha256: [64]u8,
    finished: bool = false,
    successful: bool = false,

    /// Explicit service launch. The full coordinator uses applicable() and
    /// the original installation process gate before calling this operation.
    pub fn start(allocator: Allocator, io: Io, project_root: []const u8, commit: []const u8, report_directory: ?[]const u8) !Remap {
        if (!build_options.enable_jsc) return error.NativeRuntimeRequired;
        if (commit.len != 40) return error.InvalidCorpusCommit;
        for (commit) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidCorpusCommit;
        const root = try Io.Dir.cwd().realPathFileAlloc(io, project_root, allocator);
        defer allocator.free(root);
        var env = try capture.inheritedEnvironmentMap(allocator);
        defer env.deinit();
        const inherited_report = env.get("HOME_BUN_CORPUS_REPORT_DIR");
        const report = report_directory orelse if (inherited_report) |path| (if (path.len != 0) path else null) else null;
        var journal = try journal_module.Journal.createForPurpose(allocator, io, report, root, .service);
        errdefer journal.deinit();
        std.debug.print("[home-bun-remap] results: {s}\n", .{journal.directory});
        const source_path = try std.fs.path.join(allocator, &.{ root, "node_modules", "bun-tracestrings", "bin", "ci-remap-server.ts" });
        errdefer allocator.free(source_path);
        const source_hash = try fileHash(io, source_path);
        const package_path = try std.fs.path.join(allocator, &.{ root, "node_modules", "bun-tracestrings", "package.json" });
        errdefer allocator.free(package_path);
        const package_hash = try fileHash(io, package_path);
        const override = env.get("HOME_BUN_TEST_EXECUTABLE");
        const candidate = if (override != null and override.?.len != 0) try allocator.dupe(u8, override.?) else try capture.preferredHomeExecutablePathAlloc(allocator);
        defer allocator.free(candidate);
        const executable = try launch.resolveExecutable(allocator, io, &env, candidate);
        defer allocator.free(executable);
        var storage = try launch.Storage.create(allocator, io, &env);
        errdefer storage.deinit(allocator);
        errdefer storage.cleanup(io) catch {};
        try storage.linkExecutable(allocator, io, executable, true);
        const path_key = if (@import("builtin").os.tag == .windows) "Path" else "PATH";
        const path = try std.fmt.allocPrint(allocator, "{s}{c}{s}{c}{s}", .{ storage.bin_path, std.fs.path.delimiter, std.fs.path.dirname(executable).?, std.fs.path.delimiter, env.get(path_key) orelse "" });
        defer allocator.free(path);
        try env.put(path_key, path);
        // These are the original remap launch overrides, not the test profile.
        try env.put("HOME_NATIVE_VM", "1");
        try env.put("BUN_DEBUG_QUIET_LOGS", "1");
        try env.put("NO_COLOR", "1");
        const argv: []const []const u8 = &.{ executable, "run", "--silent", "ci-remap-server", executable, root, commit };
        try journal.append(.{ .event = "service_plan", .contract = "bun-4982b91e-ci-remap", .service = "ci-remap-server", .startup_timeout_ms = 5000, .ready_protocol = "port_line", .commit = commit, .source_path = source_path, .source_sha256 = @as([]const u8, &source_hash), .package_sha256 = @as([]const u8, &package_hash), .setup_performed = false });
        try journal.select("ci-remap-server");
        try journal.start(.{ .journal = &journal, .id = 0, .mode = "ci_remap_server", .source_sha256 = source_hash }, argv, 5000, root, &env);
        const service = try service_module.Service.start(allocator, io, .{ .argv = argv, .cwd = root, .environment = &env, .protocol = .port_line, .startup_timeout_ms = 5000 });
        errdefer service.deinit();
        try journal.append(.{ .event = "service_readiness", .id = 0, .ready = service.ready(), .port = service.port() });
        return .{ .allocator = allocator, .io = io, .journal = journal, .service = service, .storage = storage, .source_path = source_path, .source_sha256 = source_hash, .package_path = package_path, .package_sha256 = package_hash };
    }
    pub fn port(self: *const Remap) ?u16 {
        return self.service.port();
    }
    pub fn finish(self: *Remap) !bool {
        if (self.finished) return self.successful;
        self.finished = true;
        const result = self.service.finish();
        const source_unchanged = try unchanged(self.io, self.source_path, self.source_sha256) and try unchanged(self.io, self.package_path, self.package_sha256);
        try self.journal.completeService(0, result.*, source_unchanged);
        try self.storage.cleanup(self.io);
        const successful = result.successful() and source_unchanged;
        try self.journal.finish(.{ .files = @as(usize, 1), .passed = 0, .failed = 0, .skipped = 0, .todo = 0, .unsupported = 0, .failed_files = @as(usize, if (successful) 0 else 1), .process_checks_passed = 0, .services_succeeded = @as(usize, if (successful) 1 else 0), .services_failed = @as(usize, if (successful) 0 else 1), .temporary_storage_removed = true });
        self.successful = successful;
        return successful;
    }
    pub fn deinit(self: *Remap) void {
        _ = self.finish() catch false;
        self.service.deinit();
        self.storage.cleanup(self.io) catch {};
        self.storage.deinit(self.allocator);
        self.journal.deinit();
        self.allocator.free(self.source_path);
        self.allocator.free(self.package_path);
    }
};

test "native corpus remap keeps a ready native service owned until explicit completion" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "node_modules/bun-tracestrings/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"name\":\"private-remap\",\"scripts\":{\"ci-remap-server\":\"bun node_modules/bun-tracestrings/bin/ci-remap-server.ts\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/bun-tracestrings/package.json", .data = "{\"name\":\"bun-tracestrings\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/bun-tracestrings/bin/ci-remap-server.ts", .data =
        \\const fs=require('node:fs'),assert=require('node:assert');
        \\assert.equal(fs.realpathSync(Bun.which('node')),fs.realpathSync(process.execPath));
        \\assert.equal(process.env.NO_COLOR,'1');
        \\assert.equal(process.env.BUN_DEBUG_QUIET_LOGS,'1');
        \\const server=Bun.serve({port:0,fetch(){return new Response('ready')}});
        \\console.log(server.port);
    });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const report = try std.fs.path.join(allocator, &.{ root, "reports" });
    defer allocator.free(report);
    var remap = try Remap.start(allocator, io, root, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", report);
    defer remap.deinit();
    try std.testing.expect(remap.port() != null);
    const request = try std.fmt.allocPrint(allocator, "const r=await fetch('http://127.0.0.1:{d}');if(await r.text()!=='ready')throw new Error('service protocol');", .{remap.port().?});
    defer allocator.free(request);
    var response = try capture.runHomeCaptured(allocator, "remap-client", &.{ "-e", request });
    defer response.deinit(allocator);
    try std.testing.expect(response.term.success() and !response.timed_out and response.output_complete);
    try std.testing.expect(try remap.finish());
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, remap.storage.path, .{}));
}
