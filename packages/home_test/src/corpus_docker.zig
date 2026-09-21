//! Linux CI Docker coordinator with the pinned readiness and lifetime contract.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const capture = @import("adapters/jsc_bootstrap.zig");
const journal_module = @import("corpus_journal.zig");
const launch = @import("corpus_launch.zig");
const platform = @import("corpus_platform.zig");
const service_module = @import("corpus_service.zig");
const build_options = @import("build_options");

pub fn applicable(host: platform.Host, is_ci: bool) bool {
    return is_ci and std.mem.eql(u8, host.os, "linux");
}

fn fileHash(io: Io, path: []const u8) ![64]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return journal_module.hashFile(io, file);
}

pub const Coordinator = struct {
    allocator: Allocator,
    io: Io,
    journal: journal_module.Journal,
    service: ?*service_module.Service = null,
    storage: ?launch.Storage = null,
    socket_path: ?[]u8 = null,
    source_path: ?[]u8 = null,
    source_sha256: ?[64]u8 = null,
    docker_available: bool = false,
    finished: bool = false,
    service_successful: bool = false,

    /// Probe Docker exactly once, then start the pinned coordinator when the
    /// host supports it. An unavailable or unready coordinator preserves the
    /// upstream direct-compose fallback and never publishes a socket.
    pub fn start(
        allocator: Allocator,
        io: Io,
        project_root: []const u8,
        selected_tests: []const []const u8,
        report_directory: ?[]const u8,
    ) !Coordinator {
        if (!build_options.enable_jsc) return error.NativeRuntimeRequired;
        if (builtin.os.tag != .linux) return error.DockerCoordinatorNotApplicable;
        const root = try Io.Dir.cwd().realPathFileAlloc(io, project_root, allocator);
        defer allocator.free(root);
        var env = try capture.inheritedEnvironmentMap(allocator);
        defer env.deinit();
        const inherited_report = env.get("HOME_BUN_CORPUS_REPORT_DIR");
        const report = report_directory orelse if (inherited_report) |path| (if (path.len != 0) path else null) else null;
        var journal = try journal_module.Journal.createForPurpose(allocator, io, report, root, .service);
        errdefer journal.deinit();
        std.debug.print("[home-bun-docker] results: {s}\n", .{journal.directory});
        const docker = launch.resolveExecutable(allocator, io, &env, "docker") catch |err| {
            try journal.append(.{ .event = "docker_probe", .contract = "bun-4982b91e-docker-coordinator", .argv = &.{ "docker", "compose", "version" }, .available = false, .error_name = @errorName(err), .case_credit = 0 });
            return .{ .allocator = allocator, .io = io, .journal = journal };
        };
        defer allocator.free(docker);
        var probe = capture.runToolCaptured(allocator, io, &.{ docker, "compose", "version" }, root, 180_000) catch |err| {
            try journal.append(.{ .event = "docker_probe", .contract = "bun-4982b91e-docker-coordinator", .argv = &.{ docker, "compose", "version" }, .available = false, .error_name = @errorName(err), .case_credit = 0 });
            return .{ .allocator = allocator, .io = io, .journal = journal };
        };
        defer probe.deinit(allocator);
        const available = probe.term.success() and !probe.timed_out and probe.output_complete;
        try journal.append(.{
            .event = "docker_probe",
            .contract = "bun-4982b91e-docker-coordinator",
            .argv = &.{ docker, "compose", "version" },
            .term = probe.term,
            .timed_out = probe.timed_out,
            .output_complete = probe.output_complete,
            .stdout = probe.stdout,
            .stderr = probe.stderr,
            .available = available,
            .case_credit = 0,
        });
        var result = Coordinator{ .allocator = allocator, .io = io, .journal = journal, .docker_available = available };
        if (!available) return result;

        const source_path = try std.fs.path.join(allocator, &.{ root, "test", "docker", "coordinator.ts" });
        errdefer allocator.free(source_path);
        const source_hash = try fileHash(io, source_path);
        const override = env.get("HOME_BUN_TEST_EXECUTABLE");
        const candidate = if (override != null and override.?.len != 0) try allocator.dupe(u8, override.?) else try capture.preferredHomeExecutablePathAlloc(allocator);
        defer allocator.free(candidate);
        const executable = try launch.resolveExecutable(allocator, io, &env, candidate);
        defer allocator.free(executable);
        var storage = try launch.Storage.create(allocator, io, &env);
        errdefer storage.deinit(allocator);
        errdefer storage.cleanup(io) catch {};
        const socket_path = try std.fs.path.join(allocator, &.{ storage.path, "coordinator.sock" });
        errdefer allocator.free(socket_path);
        try env.put("BUN_DOCKER_COORDINATOR_SOCKET", socket_path);
        try env.put("HOME_NATIVE_VM", "1");
        const argv = try allocator.alloc([]const u8, selected_tests.len + 2);
        defer allocator.free(argv);
        argv[0] = executable;
        argv[1] = source_path;
        @memcpy(argv[2..], selected_tests);
        try result.journal.append(.{
            .event = "service_plan",
            .contract = "bun-4982b91e-docker-coordinator",
            .service = "docker-coordinator",
            .startup_timeout_ms = 15_000,
            .ready_protocol = "COORDINATOR_READY",
            .socket_path = socket_path,
            .source_path = source_path,
            .source_sha256 = @as([]const u8, &source_hash),
            .selected_tests = selected_tests,
            .setup_performed = false,
        });
        try result.journal.select("docker-coordinator");
        try result.journal.start(.{ .journal = &result.journal, .id = 0, .mode = "docker_coordinator", .source_sha256 = source_hash }, argv, 15_000, root, &env);
        const service = try service_module.Service.start(allocator, io, .{
            .argv = argv,
            .cwd = root,
            .environment = &env,
            .protocol = .{ .marker = "COORDINATOR_READY" },
            .startup_timeout_ms = 15_000,
            .keep_stdin_open = true,
        });
        errdefer service.deinit();
        try result.journal.append(.{ .event = "service_readiness", .id = 0, .ready = service.ready(), .socket_path = if (service.ready()) socket_path else null, .fallback = if (service.ready()) "coordinator" else "direct-compose" });
        result.service = service;
        result.storage = storage;
        result.socket_path = socket_path;
        result.source_path = source_path;
        result.source_sha256 = source_hash;
        // The pinned runner kills an unready coordinator before tests begin so
        // direct-compose fallback does not overlap a failed background owner.
        if (!service.ready()) try result.finish();
        return result;
    }

    pub fn services(self: *const Coordinator) launch.Services {
        return .{ .docker_socket = if (self.service) |service| (if (service.ready()) self.socket_path else null) else null };
    }

    pub fn finish(self: *Coordinator) !void {
        if (self.finished) return;
        self.finished = true;
        if (self.service) |service| {
            const outcome = service.finish();
            const unchanged = if (self.source_path) |path| blk: {
                const actual = fileHash(self.io, path) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
                break :blk std.mem.eql(u8, &actual, &self.source_sha256.?);
            } else false;
            try self.journal.completeService(0, outcome.*, unchanged);
            self.service_successful = outcome.successful() and unchanged;
        }
        if (self.storage) |storage| try storage.cleanup(self.io);
        try self.journal.finish(.{
            .files = @as(usize, if (self.service == null) 0 else 1),
            .passed = 0,
            .failed = 0,
            .skipped = 0,
            .todo = 0,
            .unsupported = 0,
            .failed_files = @as(usize, if (self.service != null and !self.service_successful) 1 else 0),
            .process_checks_passed = 0,
            .docker_available = self.docker_available,
            .coordinator_ready = self.services().docker_socket != null,
            .fallback = if (self.services().docker_socket == null) "direct-compose" else "coordinator",
            .temporary_storage_removed = self.storage != null,
        });
    }

    pub fn deinit(self: *Coordinator) void {
        self.finish() catch {};
        if (self.service) |service| service.deinit();
        if (self.storage) |*storage| storage.deinit(self.allocator);
        if (self.socket_path) |path| self.allocator.free(path);
        if (self.source_path) |path| self.allocator.free(path);
        self.journal.deinit();
        self.* = undefined;
    }
};

test "native corpus Docker coordinator applicability matches pinned CI" {
    const linux = platform.Host{ .os = "linux", .arch = "x86_64" };
    const darwin = platform.Host{ .os = "darwin", .arch = "aarch64" };
    try std.testing.expect(applicable(linux, true));
    try std.testing.expect(!applicable(linux, false));
    try std.testing.expect(!applicable(darwin, true));
}
