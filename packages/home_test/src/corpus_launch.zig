//! Launch contracts from scripts/runner.node.mjs at Bun 4982b91e.
//! These are upstream deadlines and startup settings, not failure retries.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const File = struct {
    relative_path: []const u8,
    node_test: bool,
    test_runner: bool,
    // The corpus gate uses the CI contract. Diagnostic callers can select the
    // upstream local profile explicitly without changing the acceptance gate.
    is_ci: bool = true,
    asan_step: bool = false,
};

pub const Profile = struct {
    file_timeout_ms: i64,
    test_timeout_ms: ?u32,
    node_test: bool,
    validate_runtime: bool,
    no_orphans: bool,
    test_invocation: bool = true,
};

pub const SetupOperation = enum {
    install,
    build,
    pub fn profile(self: SetupOperation) Profile {
        return .{ .file_timeout_ms = if (self == .install) 180_000 else 60_000, .test_timeout_ms = null, .node_test = false, .validate_runtime = false, .no_orphans = false, .test_invocation = false };
    }
};

pub fn profile(file: File, executable: []const u8) Profile {
    const asan = std.mem.indexOf(u8, std.fs.path.basename(executable), "asan") != null;
    var result = Profile{
        .file_timeout_ms = 30_000,
        .test_timeout_ms = null,
        .node_test = file.node_test,
        .validate_runtime = asan or !file.is_ci,
        .no_orphans = asan and !file.node_test,
    };
    if (file.node_test) {
        result.file_timeout_ms = 20_000;
        if (!file.is_ci or file.asan_step) result.file_timeout_ms = 60_000;
        inline for (.{ "test-dns", "test-cluster-", "-docker-", "test-stdin-pipe-large" }) |part| {
            if (std.mem.indexOf(u8, file.relative_path, part) != null) result.file_timeout_ms = 60_000;
        }
    } else if (file.test_runner) {
        // The caller supplies a path relative to test/, whereas the pinned
        // regular runner matches against test/<relative>.
        var timeout: u32 = if (std.ascii.startsWithIgnoreCase(file.relative_path, "napi")) 300_000 else 180_000;
        inline for (.{ "integration", "3rd_party", "docker", "bun-install-registry", "bun-security-scanner-matrix", "v8", "bundler_compile", "tonic", "test/napi", "test\\napi" }) |part| {
            if (std.ascii.findIgnoreCase(file.relative_path, part) != null) timeout = 300_000;
        }
        result.file_timeout_ms = timeout * @as(u32, if (asan) 2 else 1);
        result.test_timeout_ms = (timeout / 2) * @as(u32, if (asan) 3 else 1);
    }
    return result;
}

pub fn applyEnvironment(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    selected: Profile,
    temp_path: []const u8,
    bin_path: []const u8,
) !void {
    inline for (.{ "TMPDIR", "BUN_TMPDIR", "TEST_TMPDIR", "BUN_INSTALL_CACHE_DIR" }) |key| try env.put(key, temp_path);
    inline for (.{ "BUN_FEATURE_FLAG_INTERNAL_FOR_TESTING", "BUN_DEBUG_QUIET_LOGS", "BUN_GARBAGE_COLLECTOR_LEVEL" }) |key| try env.put(key, "1");
    try env.put("BUN_JSC_randomIntegrityAuditRate", "1.0");
    try env.put("BUN_RUNTIME_TRANSPILER_CACHE_PATH", "0");
    try env.put("BUN_ENABLE_CRASH_REPORTING", "0");
    try env.put("FORCE_COLOR", if (selected.node_test) "0" else "1");
    if (selected.node_test) try env.put("NO_COLOR", "1") else if (selected.test_invocation) try env.put("GITHUB_ACTIONS", "true");
    if (selected.no_orphans) try env.put("BUN_FEATURE_FLAG_NO_ORPHANS", "1");
    const path_key = if (builtin.os.tag == .windows) "Path" else "PATH";
    const path = try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ bin_path, std.fs.path.delimiter, env.get(path_key) orelse "" });
    defer allocator.free(path);
    if (builtin.os.tag == .windows) {
        _ = env.swapRemove("PATH");
        inline for (.{ "TMPDIR", "TEMP", "TEMPDIR", "TMP" }) |key| _ = env.swapRemove(key);
        try env.put("TEMP", temp_path);
        try env.put("SHELLOPTS", "igncr");
    }
    try env.put(path_key, path);
}

pub fn applyValidation(
    allocator: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    selected: Profile,
    file: File,
    project_root: []const u8,
) !void {
    if (!selected.validate_runtime) return;
    if (!try listed(allocator, io, project_root, "no-validate-exceptions.txt", file.relative_path, true)) {
        try env.put("BUN_JSC_validateExceptionChecks", "1");
        try env.put("BUN_JSC_dumpSimulatedThrows", "1");
    }
    if (!try listed(allocator, io, project_root, "no-validate-leaksan.txt", file.relative_path, false)) {
        try env.put("BUN_DESTRUCT_VM_ON_EXIT", "1");
        try env.put("ASAN_OPTIONS", "allow_user_segv_handler=1:disable_coredump=0:detect_leaks=1:abort_on_error=1");
        const value = try std.fmt.allocPrint(allocator, "malloc_context_size=30:print_suppressions=0:suppressions={s}{c}test{c}leaksan.supp", .{ project_root, std.fs.path.sep, std.fs.path.sep });
        defer allocator.free(value);
        try env.put("LSAN_OPTIONS", value);
    }
}

fn listed(allocator: std.mem.Allocator, io: Io, root: []const u8, filename: []const u8, relative: []const u8, trim: bool) !bool {
    const path = try std.fs.path.join(allocator, &.{ root, "test", filename });
    defer allocator.free(path);
    const source = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(source);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = if (trim) std.mem.trim(u8, raw, " \t\r") else raw;
        if (line.len == 0 or line[0] == '#') continue;
        const name = if (std.mem.startsWith(u8, line, "test/")) line[5..] else line;
        if (name.len != relative.len) continue;
        for (name, relative) |a, b| {
            // Upstream normalizes separators only for exception validation.
            if (a != (if (trim and b == '\\') @as(u8, '/') else b)) break;
        } else return true;
    }
    return false;
}

/// Own only a fresh per-file directory, including command aliases. Placing
/// aliases here avoids altering a neighboring installed Bun executable.
pub const Storage = struct {
    path: []u8,
    temp_path: []u8,
    bin_path: []u8,

    pub fn create(allocator: std.mem.Allocator, io: Io, inherited: *const std.process.Environ.Map) !Storage {
        const base = if (builtin.os.tag == .windows) inherited.get("TEMP") orelse inherited.get("TMP") orelse return error.MissingTemporaryDirectory else inherited.get("TMPDIR") orelse "/tmp";
        const absolute_base = try Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
        defer allocator.free(absolute_base);
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = try std.fmt.allocPrint(allocator, "home-corpus-{x}", .{random});
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ absolute_base, name });
        errdefer allocator.free(path);
        try Io.Dir.cwd().createDir(io, path, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
        errdefer Io.Dir.cwd().deleteTree(io, path) catch {};
        const temp_path = try std.fs.path.join(allocator, &.{ path, "tmp" });
        errdefer allocator.free(temp_path);
        try Io.Dir.cwd().createDir(io, temp_path, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
        const bin_path = try std.fs.path.join(allocator, &.{ path, "bin" });
        errdefer allocator.free(bin_path);
        try Io.Dir.cwd().createDir(io, bin_path, .default_dir);
        return .{ .path = path, .temp_path = temp_path, .bin_path = bin_path };
    }

    pub fn linkExecutable(self: Storage, allocator: std.mem.Allocator, io: Io, executable: []const u8, include_node: bool) !void {
        const target = try Io.Dir.cwd().realPathFileAlloc(io, executable, allocator);
        defer allocator.free(target);
        inline for (.{ "bun", "home", "node" }) |name| {
            if (!std.mem.eql(u8, name, "node") or include_node) {
                const path = try std.fs.path.join(allocator, &.{ self.bin_path, name ++ (if (builtin.os.tag == .windows) ".exe" else "") });
                defer allocator.free(path);
                Io.Dir.cwd().symLink(io, target, path, .{}) catch {
                    try Io.Dir.hardLink(.cwd(), target, .cwd(), path, io, .{});
                };
            }
        }
    }

    pub fn cleanup(self: Storage, io: Io) !void {
        try Io.Dir.cwd().deleteTree(io, self.path);
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        allocator.free(self.bin_path);
        allocator.free(self.temp_path);
        allocator.free(self.path);
        self.* = undefined;
    }
};

test "corpus launch distinguishes original CI test, script and Node deadlines" {
    const ordinary = profile(.{ .relative_path = "test/js/bun/foo.test.ts", .node_test = false, .test_runner = true }, "/bin/home");
    try std.testing.expectEqual(@as(i64, 180_000), ordinary.file_timeout_ms);
    try std.testing.expectEqual(@as(?u32, 90_000), ordinary.test_timeout_ms);
    const integration = profile(.{ .relative_path = "TEST\\NAPI\\foo.test.ts", .node_test = false, .test_runner = true }, "/bin/home-asan");
    try std.testing.expectEqual(@as(i64, 600_000), integration.file_timeout_ms);
    try std.testing.expectEqual(@as(?u32, 450_000), integration.test_timeout_ms);
    const script = profile(.{ .relative_path = "integration/script.ts", .node_test = false, .test_runner = false }, "/bin/home-asan");
    try std.testing.expectEqual(@as(i64, 30_000), script.file_timeout_ms);
    try std.testing.expect(script.test_timeout_ms == null);
    const node = profile(.{ .relative_path = "js/node/test/parallel/test-buffer.js", .node_test = true, .test_runner = true }, "/bin/home");
    try std.testing.expectEqual(@as(i64, 20_000), node.file_timeout_ms);
    try std.testing.expect(node.test_timeout_ms == null);
    const slow_node = profile(.{ .relative_path = "js/node/test/parallel/test-dns.js", .node_test = true, .test_runner = false }, "/bin/home");
    try std.testing.expectEqual(@as(i64, 60_000), slow_node.file_timeout_ms);
}

test "corpus launch storage is isolated and cleanup preserves its neighbors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(if (builtin.os.tag == .windows) "TEMP" else "TMPDIR", root);
    var first = try Storage.create(allocator, std.testing.io, &env);
    defer first.deinit(allocator);
    var second = try Storage.create(allocator, std.testing.io, &env);
    defer second.deinit(allocator);
    defer second.cleanup(std.testing.io) catch {};
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
    var empty_cache = try Io.Dir.cwd().openDir(std.testing.io, first.temp_path, .{ .iterate = true });
    defer empty_cache.close(std.testing.io);
    var entries = empty_cache.iterate();
    try std.testing.expect(try entries.next(std.testing.io) == null);
    try first.cleanup(std.testing.io);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(std.testing.io, first.path, .{}));
    try Io.Dir.cwd().access(std.testing.io, second.path, .{});
}

pub fn resolveExecutable(allocator: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, executable: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, executable, "/\\") != null) {
        const resolved = try Io.Dir.cwd().realPathFileAlloc(io, executable, allocator);
        defer allocator.free(resolved);
        // realPathFileAlloc owns a sentinel byte. Return the non-sentinel
        // allocation promised by this API so callers can free its full extent.
        return allocator.dupe(u8, resolved);
    }
    var paths = std.mem.splitScalar(u8, env.get("PATH") orelse "", std.fs.path.delimiter);
    while (paths.next()) |directory| {
        const name = if (builtin.os.tag == .windows and std.fs.path.extension(executable).len == 0) try std.fmt.allocPrint(allocator, "{s}.exe", .{executable}) else try allocator.dupe(u8, executable);
        defer allocator.free(name);
        const candidate = try std.fs.path.join(allocator, &.{ directory, name });
        defer allocator.free(candidate);
        Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        const resolved = try Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator);
        defer allocator.free(resolved);
        return allocator.dupe(u8, resolved);
    }
    return error.FileNotFound;
}

test "corpus launch applies GC integrity cache and distinct Node color settings" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("BUN_GARBAGE_COLLECTOR_LEVEL", "0");
    try env.put("HOME", "/real-user-home");
    try env.put("SHELL", "/bin/zsh");
    try env.put("PATH", "/existing-tools");
    try applyEnvironment(allocator, &env, profile(.{ .relative_path = "ordinary.test.ts", .node_test = false, .test_runner = true }, "/bin/home"), "/fresh-temp", "/fresh-bin");
    try std.testing.expectEqualStrings("1", env.get("BUN_GARBAGE_COLLECTOR_LEVEL").?);
    try std.testing.expectEqualStrings("1.0", env.get("BUN_JSC_randomIntegrityAuditRate").?);
    try std.testing.expectEqualStrings("0", env.get("BUN_RUNTIME_TRANSPILER_CACHE_PATH").?);
    try std.testing.expectEqualStrings("/fresh-temp", env.get("BUN_INSTALL_CACHE_DIR").?);
    try std.testing.expectEqualStrings("/fresh-temp", env.get("TEST_TMPDIR").?);
    try std.testing.expectEqualStrings("/real-user-home", env.get("HOME").?);
    try std.testing.expectEqualStrings("/bin/zsh", env.get("SHELL").?);
    try std.testing.expectEqualStrings("1", env.get("FORCE_COLOR").?);
    try std.testing.expectEqualStrings("true", env.get("GITHUB_ACTIONS").?);
    try applyEnvironment(allocator, &env, profile(.{ .relative_path = "test-node.js", .node_test = true, .test_runner = false }, "/bin/home"), "/node-temp", "/node-bin");
    try std.testing.expectEqualStrings("0", env.get("FORCE_COLOR").?);
    try std.testing.expectEqualStrings("1", env.get("NO_COLOR").?);
}

test "corpus launch validation honors pinned list semantics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "test");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test/no-validate-exceptions.txt", .data = "# comment\n  test/js/example.test.ts  \n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test/no-validate-leaksan.txt", .data = "js/example.test.ts\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const excluded = File{ .relative_path = "js/example.test.ts", .node_test = false, .test_runner = true };
    try applyValidation(allocator, std.testing.io, &env, profile(excluded, "/bin/home-asan"), excluded, root);
    try std.testing.expect(env.get("BUN_JSC_validateExceptionChecks") == null);
    try std.testing.expect(env.get("BUN_DESTRUCT_VM_ON_EXIT") == null);
    const included = File{ .relative_path = "js/included.test.ts", .node_test = false, .test_runner = true };
    try applyValidation(allocator, std.testing.io, &env, profile(included, "/bin/home-asan"), included, root);
    try std.testing.expectEqualStrings("1", env.get("BUN_JSC_validateExceptionChecks").?);
    try std.testing.expectEqualStrings("1", env.get("BUN_DESTRUCT_VM_ON_EXIT").?);
}

test "corpus launch resolved executable preserves allocation ownership" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "executable", .data = "fixture" });
    const absolute = try tmp.dir.realPathFileAlloc(std.testing.io, "executable", allocator);
    defer allocator.free(absolute);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const resolved = try resolveExecutable(allocator, std.testing.io, &env, absolute);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(absolute, resolved);
}

test "corpus launch setup preserves install and build contracts" {
    const allocator = std.testing.allocator;
    inline for (.{ SetupOperation.install, SetupOperation.build }) |operation| {
        const selected = operation.profile();
        try std.testing.expectEqual(@as(i64, if (operation == .install) 180_000 else 60_000), selected.file_timeout_ms);
        try std.testing.expect(selected.test_timeout_ms == null and !selected.test_invocation and !selected.validate_runtime);
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try applyEnvironment(allocator, &env, selected, "/setup/tmp", "/setup/bin");
        try std.testing.expect(env.get("GITHUB_ACTIONS") == null and env.get("NO_COLOR") == null and env.get("TEST_THREAD_ID") == null);
        try std.testing.expectEqualStrings("1", env.get("FORCE_COLOR").?);
        try std.testing.expectEqualStrings("1.0", env.get("BUN_JSC_randomIntegrityAuditRate").?);
        try env.put("GITHUB_ACTIONS", "inherited");
        try applyEnvironment(allocator, &env, selected, "/setup/tmp", "/setup/bin");
        try std.testing.expectEqualStrings("inherited", env.get("GITHUB_ACTIONS").?);
    }
}
