//! Durable native corpus evidence. A missing finished/completed event remains
//! incomplete; successful process exits never manufacture passing test cases.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Invocation = struct {
    journal: *Journal,
    id: usize,
    mode: []const u8,
    source_sha256: [64]u8,
};

pub const Journal = struct {
    allocator: Allocator,
    io: Io,
    directory: []u8,
    events: Io.File,
    selected: usize = 0,
    started: usize = 0,
    completed: usize = 0,
    executable: ?[]u8 = null,
    executable_stat: ?Io.File.Stat = null,
    executable_sha256: ?[64]u8 = null,

    pub fn create(allocator: Allocator, io: Io, requested: ?[]const u8, corpus_root: []const u8) !Journal {
        const relative = if (requested) |path| try allocator.dupe(u8, path) else blk: {
            try Io.Dir.cwd().createDirPath(io, "zig-out/bun-corpus-results");
            var random: [16]u8 = undefined;
            io.random(&random);
            break :blk try std.fmt.allocPrint(allocator, "zig-out/bun-corpus-results/{x}", .{random});
        };
        defer allocator.free(relative);
        const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cwd);
        const directory = try std.fs.path.resolve(allocator, &.{ cwd, relative });
        errdefer allocator.free(directory);
        // Never reuse or truncate another run's evidence directory.
        try Io.Dir.cwd().createDir(io, directory, .default_dir);
        const path = try std.fs.path.join(allocator, &.{ directory, "events.jsonl" });
        defer allocator.free(path);
        const events = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        errdefer events.close(io);
        var journal = Journal{ .allocator = allocator, .io = io, .directory = directory, .events = events };
        try journal.append(.{ .event = "run", .schema = 2, .corpus_root = corpus_root });
        return journal;
    }

    pub fn deinit(self: *Journal) void {
        self.events.close(self.io);
        if (self.executable) |path| self.allocator.free(path);
        self.allocator.free(self.directory);
        self.* = undefined;
    }

    pub fn append(self: *Journal, value: anytype) !void {
        const text = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(text);
        try self.events.writeStreamingAll(self.io, text);
        try self.events.writeStreamingAll(self.io, "\n");
        try self.events.sync(self.io);
    }

    pub fn select(self: *Journal, path: []const u8) !void {
        try self.append(.{ .event = "selected", .id = self.selected, .path = path });
        self.selected += 1;
    }

    fn verifyExecutable(self: *Journal, path: []const u8) !void {
        const file = try Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (self.executable_stat) |old| {
            if (!std.mem.eql(u8, path, self.executable.?) or old.inode != stat.inode or old.size != stat.size or !std.meta.eql(old.mtime, stat.mtime)) return error.CorpusExecutableChanged;
        } else {
            self.executable = try self.allocator.dupe(u8, path);
            self.executable_sha256 = try hashFile(self.io, file);
            self.executable_stat = stat;
            const after = try file.stat(self.io);
            if (stat.size != after.size or !std.meta.eql(stat.mtime, after.mtime)) return error.CorpusExecutableChanged;
        }
    }

    pub fn start(self: *Journal, invocation: Invocation, argv: []const []const u8, timeout_ms: i64, cwd: ?[]const u8, env: ?*const std.process.Environ.Map) !void {
        if (invocation.id != self.started or self.started != self.completed or self.started >= self.selected) return error.InvalidCorpusEventOrder;
        try self.verifyExecutable(argv[0]);
        const Environment = struct {
            HOME_NATIVE_VM: ?[]const u8,
            HOME_CORPUS_FULL_VM: ?[]const u8,
            BUN_FEATURE_FLAG_INTERNAL_FOR_TESTING: ?[]const u8,
            BUN_GARBAGE_COLLECTOR_LEVEL: ?[]const u8,
            BUN_JSC_randomIntegrityAuditRate: ?[]const u8,
            BUN_RUNTIME_TRANSPILER_CACHE_PATH: ?[]const u8,
            BUN_INSTALL_CACHE_DIR: ?[]const u8,
            TMPDIR: ?[]const u8,
            TEMP: ?[]const u8,
            BUN_TMPDIR: ?[]const u8,
            TEST_TMPDIR: ?[]const u8,
            PATH: ?[]const u8,
            FORCE_COLOR: ?[]const u8,
            NO_COLOR: ?[]const u8,
            CI: ?[]const u8,
            GITHUB_ACTIONS: ?[]const u8,
        };
        var environment: Environment = undefined;
        inline for (comptime std.meta.fieldNames(Environment)) |name| @field(environment, name) = if (env) |values| values.get(name) else null;
        try self.append(.{
            .event = "started",
            .phase = "launch_attempt",
            .id = invocation.id,
            .mode = invocation.mode,
            .source_sha256 = @as([]const u8, &invocation.source_sha256),
            .executable_sha256 = @as([]const u8, &self.executable_sha256.?),
            .argv = argv,
            .cwd = cwd,
            .environment = environment,
            .timeout_ms = timeout_ms,
        });
        self.started += 1;
    }

    pub fn artifactPath(self: *Journal, id: usize, suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}{c}{d:0>6}.{s}", .{ self.directory, std.fs.path.sep, id, suffix });
    }

    fn writeArtifact(self: *Journal, id: usize, suffix: []const u8, bytes: []const u8) !void {
        const path = try self.artifactPath(id, suffix);
        defer self.allocator.free(path);
        const file = try Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
        try file.sync(self.io);
    }

    pub fn complete(self: *Journal, id: usize, term: std.process.Child.Term, timed_out: bool, stdout: []const u8, stderr: []const u8, counts: anytype, output_complete: bool, source_unchanged: bool, junit_path: ?[]const u8, expected_failure_verified: bool) !bool {
        if (id != self.completed or self.started != self.completed + 1) return error.InvalidCorpusEventOrder;
        try self.writeArtifact(id, "stdout", stdout);
        try self.writeArtifact(id, "stderr", stderr);
        try self.verifyExecutable(self.executable.?);
        var junit_sha256: ?[64]u8 = null;
        if (junit_path) |path| {
            const file = Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (file) |report| {
                defer report.close(self.io);
                try report.sync(self.io);
                junit_sha256 = try hashFile(self.io, report);
            }
        }
        var stdout_name: [40]u8 = undefined;
        var stderr_name: [40]u8 = undefined;
        try self.append(.{
            .event = "completed",
            .id = id,
            .term = term,
            .timed_out = timed_out,
            .source_unchanged = source_unchanged,
            .output_complete = output_complete,
            .expected_failure_verified = expected_failure_verified,
            .counts = counts,
            .stdout_file = try std.fmt.bufPrint(&stdout_name, "{d:0>6}.stdout", .{id}),
            .stderr_file = try std.fmt.bufPrint(&stderr_name, "{d:0>6}.stderr", .{id}),
            .junit_file = if (junit_path) |path| std.fs.path.basename(path) else null,
            .stdout_sha256 = @as([]const u8, &hashBytes(stdout)),
            .stderr_sha256 = @as([]const u8, &hashBytes(stderr)),
            .junit = if (junit_path == null) "not_requested" else if (junit_sha256 == null) "missing" else "retained",
            .junit_sha256 = if (junit_sha256) |*hash| @as([]const u8, hash) else null,
        });
        self.completed += 1;
        return junit_path == null or junit_sha256 != null;
    }

    pub fn finish(self: *Journal, summary: anytype) !void {
        try self.append(.{ .event = "finished", .selected = self.selected, .started = self.started, .completed = self.completed, .all_selected_completed = self.completed == self.selected, .summary = summary });
    }
};

pub fn hashBytes(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashFile(io: Io, file: Io.File) ![64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositionalAll(io, &buffer, offset);
        if (count == 0) break;
        hash.update(buffer[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

test "corpus journal preserves selection and refuses to overwrite a prior run" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "results" });
    defer allocator.free(path);
    var journal = try Journal.create(allocator, io, path, root);
    defer journal.deinit();
    try journal.select("first.test.ts");
    try journal.select("not-started.test.ts");
    try std.testing.expectError(error.PathAlreadyExists, Journal.create(allocator, io, path, root));
    const events_path = try std.fs.path.join(allocator, &.{ path, "events.jsonl" });
    defer allocator.free(events_path);
    const data = try Io.Dir.cwd().readFileAlloc(io, events_path, allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "not-started.test.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "finished") == null);
}

test "corpus journal retains raw failures and detects executable changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "executable", .data = "fixture executable" });
    const executable = try tmp.dir.realPathFileAlloc(io, "executable", allocator);
    defer allocator.free(executable);
    const path = try std.fs.path.join(allocator, &.{ root, "results" });
    defer allocator.free(path);
    var journal = try Journal.create(allocator, io, path, root);
    defer journal.deinit();
    try journal.select("failing.test.js");
    try journal.select("pending.test.js");
    const invocation = Invocation{ .journal = &journal, .id = 0, .mode = "test_runner", .source_sha256 = hashBytes("source") };
    try journal.start(invocation, &.{ executable, "test", "failing.test.js" }, 180_000, null, null);
    const counts = .{ .passed = 1, .failed = 1, .skipped = 2, .todo = 3, .observed = true };
    try std.testing.expect(try journal.complete(0, .{ .exited = 1 }, false, "raw\x00stdout", "assertion failure", counts, true, true, null, false));
    const stdout_path = try journal.artifactPath(0, "stdout");
    defer allocator.free(stdout_path);
    const stdout = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("raw\x00stdout", stdout);
    try std.testing.expectError(error.InvalidCorpusEventOrder, journal.start(invocation, &.{executable}, 180_000, null, null));
    try tmp.dir.writeFile(io, .{ .sub_path = "executable", .data = "a different executable" });
    var next = invocation;
    next.id = 1;
    try std.testing.expectError(error.CorpusExecutableChanged, journal.start(next, &.{executable}, 180_000, null, null));
    try journal.finish(.{ .failed = 1 });
    try std.testing.expectEqual(@as(usize, 2), journal.selected);
    try std.testing.expectEqual(@as(usize, 1), journal.started);
    try std.testing.expectEqual(@as(usize, 1), journal.completed);
}

test "corpus journal exposes a missing requested JUnit report" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "executable", .data = "fixture" });
    const executable = try tmp.dir.realPathFileAlloc(io, "executable", allocator);
    defer allocator.free(executable);
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "results" });
    defer allocator.free(path);
    var journal = try Journal.create(allocator, io, path, root);
    defer journal.deinit();
    try journal.select("test.js");
    try journal.start(.{ .journal = &journal, .id = 0, .mode = "test_runner", .source_sha256 = hashBytes("source") }, &.{executable}, 180_000, null, null);
    const junit = try journal.artifactPath(0, "junit.xml");
    defer allocator.free(junit);
    try std.testing.expect(!try journal.complete(0, .{ .exited = 0 }, false, "", "", .{ .passed = 1 }, true, true, junit, false));
}
