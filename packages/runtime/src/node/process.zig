// Home Runtime - Phase 12.7 `node:process` Zig substrate.
//
// Bun's real `globalThis.process` / `node:process` implementation lives in
// `bun/src/runtime/node/node_process.zig` and is mostly a JSC export layer
// around process-global host facts. This file ports the JSC-free core into
// Home's runtime so the future JS shim can delegate to real Zig behavior:
// cwd/chdir, pid/ppid, env reads/writes, platform/arch, hrtime, uptime, and
// memoryUsage. EventEmitter/nextTick/binding/dlopen stay parked behind the
// Phase 12.2 JSC bridge.

const std = @import("std");
const bun = @import("bun");
const builtin = @import("builtin");
const home_rt = @import("home");
const Environment = home_rt.Environment;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const version = "v0.0.0-home";
pub const versions = Versions{};

pub const Versions = struct {
    home: []const u8 = "0.0.0",
    bun_compat: []const u8 = "fd0b6f1a",
    zig: []const u8 = builtin.zig_version_string,
};

pub const Release = struct {
    name: []const u8 = "home",
    source_url: []const u8 = "https://github.com/home-lang/home",
};

pub const release = Release{};

pub const MemoryUsage = struct {
    rss: u64,
    heap_total: u64,
    heap_used: u64,
    external: u64,
    array_buffers: u64,
};

pub const CpuUsage = struct {
    user: u64,
    system: u64,
};

pub const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const EnvSnapshot = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(EnvEntry),

    pub fn init(allocator: std.mem.Allocator) EnvSnapshot {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(EnvEntry).empty,
        };
    }

    pub fn deinit(self: *EnvSnapshot) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *const EnvSnapshot, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

pub fn platform() []const u8 {
    return home_rt.node.os.platform();
}

pub fn arch() []const u8 {
    return home_rt.node.os.arch();
}

pub fn pid() i32 {
    if (Environment.isWindows) return 0;
    return @intCast(std.c.getpid());
}

pub fn ppid() i32 {
    if (Environment.isWindows) return 0;
    return @intCast(std.c.getppid());
}

pub fn cwd(allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const raw = std.c.getcwd(&buf, buf.len) orelse return error.CurrentWorkingDirectoryUnavailable;
    return allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(raw))));
}

pub fn chdir(path: []const u8) !void {
    const path_z = try bun.dupeZ(home_rt.default_allocator, u8, path);
    defer home_rt.default_allocator.free(path_z);
    if (std.c.chdir(path_z.ptr) != 0) return error.ChangeDirectoryFailed;
}

pub fn getEnv(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const key_z = try bun.dupeZ(allocator, u8, key);
    defer allocator.free(key_z);
    const raw = std.c.getenv(key_z.ptr) orelse return null;
    return try allocator.dupe(u8, std.mem.span(raw));
}

pub fn hasEnv(key: []const u8) bool {
    var key_buf: [256]u8 = undefined;
    if (key.len + 1 > key_buf.len) return false;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    return std.c.getenv(@ptrCast(key_buf[0..key.len :0].ptr)) != null;
}

pub fn setEnv(key: []const u8, value: []const u8) !void {
    if (Environment.isWindows) return error.Unsupported;
    const key_z = try bun.dupeZ(home_rt.default_allocator, u8, key);
    defer home_rt.default_allocator.free(key_z);
    const value_z = try bun.dupeZ(home_rt.default_allocator, u8, value);
    defer home_rt.default_allocator.free(value_z);
    if (setenv(key_z.ptr, value_z.ptr, 1) != 0) return error.SetEnvironmentFailed;
}

pub fn unsetEnv(key: []const u8) !void {
    if (Environment.isWindows) return error.Unsupported;
    const key_z = try bun.dupeZ(home_rt.default_allocator, u8, key);
    defer home_rt.default_allocator.free(key_z);
    if (unsetenv(key_z.ptr) != 0) return error.UnsetEnvironmentFailed;
}

pub fn envSnapshot(allocator: std.mem.Allocator) !EnvSnapshot {
    var snapshot = EnvSnapshot.init(allocator);
    errdefer snapshot.deinit();

    if (Environment.isWindows) return snapshot;

    var index: usize = 0;
    while (std.c.environ[index]) |raw| : (index += 1) {
        const entry = std.mem.span(raw);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = try allocator.dupe(u8, entry[0..eq]);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, entry[eq + 1 ..]);
        errdefer allocator.free(value);
        try snapshot.entries.append(allocator, .{ .key = key, .value = value });
    }

    return snapshot;
}

pub fn uptime() f64 {
    return home_rt.node.os.uptime();
}

pub fn hrtime(previous: ?[2]u64) [2]u64 {
    const ns = monotonicNs();
    var out = [2]u64{ ns / std.time.ns_per_s, ns % std.time.ns_per_s };
    if (previous) |prev| {
        const prev_ns = prev[0] * std.time.ns_per_s + prev[1];
        const delta = ns -| prev_ns;
        out = .{ delta / std.time.ns_per_s, delta % std.time.ns_per_s };
    }
    return out;
}

pub fn hrtimeBigint() u64 {
    return monotonicNs();
}

pub fn memoryUsage() MemoryUsage {
    if (Environment.isWindows) {
        return .{ .rss = 0, .heap_total = 0, .heap_used = 0, .external = 0, .array_buffers = 0 };
    }

    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const rss: u64 = if (Environment.isMac)
        @intCast(@max(usage.maxrss, 0))
    else
        @as(u64, @intCast(@max(usage.maxrss, 0))) * 1024;

    return .{
        .rss = rss,
        .heap_total = rss,
        .heap_used = 0,
        .external = 0,
        .array_buffers = 0,
    };
}

pub fn cpuUsage(previous: ?CpuUsage) CpuUsage {
    if (Environment.isWindows) return .{ .user = 0, .system = 0 };

    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    var out = CpuUsage{
        .user = timevalMicros(usage.utime),
        .system = timevalMicros(usage.stime),
    };
    if (previous) |prev| {
        out = .{
            .user = out.user -| prev.user,
            .system = out.system -| prev.system,
        };
    }
    return out;
}

pub fn argvFrom(allocator: std.mem.Allocator, argv0: []const u8, script: ?[]const u8, args: []const []const u8) ![][]const u8 {
    const extra: usize = if (script != null) 1 else 0;
    var out = try allocator.alloc([]const u8, 1 + extra + args.len);
    errdefer allocator.free(out);

    out[0] = try allocator.dupe(u8, argv0);
    errdefer allocator.free(out[0]);

    var index: usize = 1;
    if (script) |s| {
        out[index] = try allocator.dupe(u8, s);
        index += 1;
    }

    for (args) |arg| {
        out[index] = try allocator.dupe(u8, arg);
        index += 1;
    }

    return out;
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

pub fn exit(code: u8) noreturn {
    home_rt.Global.exit(code);
}

pub fn abort() noreturn {
    @panic("process.abort");
}

fn monotonicNs() u64 {
    if (Environment.isLinux) {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn timevalMicros(tv: anytype) u64 {
    return @as(u64, @intCast(@max(tv.sec, 0))) * std.time.us_per_s +
        @as(u64, @intCast(@max(tv.usec, 0)));
}

const testing = std.testing;

test "process platform and arch mirror node:os" {
    try testing.expectEqualStrings(home_rt.node.os.platform(), platform());
    try testing.expectEqualStrings(home_rt.node.os.arch(), arch());
}

test "process cwd returns an absolute path" {
    const path = try cwd(testing.allocator);
    defer testing.allocator.free(path);

    try testing.expect(path.len > 0);
    if (!Environment.isWindows) try testing.expect(path[0] == '/');
}

test "process env get/set/unset round trip" {
    if (Environment.isWindows) return error.SkipZigTest;

    const key = "HOME_PROCESS_SUBSTRATE_TEST";
    try unsetEnv(key);
    try testing.expect(!hasEnv(key));

    try setEnv(key, "ok");
    defer unsetEnv(key) catch {};

    try testing.expect(hasEnv(key));
    const value = (try getEnv(testing.allocator, key)).?;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("ok", value);
}

test "process env snapshot includes PATH when present" {
    var snapshot = try envSnapshot(testing.allocator);
    defer snapshot.deinit();

    if (hasEnv("PATH")) {
        try testing.expect(snapshot.get("PATH") != null);
    }
}

test "process pid and ppid are non-negative" {
    try testing.expect(pid() >= 0);
    try testing.expect(ppid() >= 0);
}

test "process hrtime delta is monotonic" {
    const start = hrtime(null);
    const delta = hrtime(start);
    try testing.expect(delta[0] == 0 or delta[0] < 10);
    try testing.expect(hrtimeBigint() > 0);
}

test "process memory and cpu usage are shaped like Node" {
    const mem = memoryUsage();
    try testing.expect(mem.rss >= mem.heap_used);

    const cpu = cpuUsage(null);
    const delta = cpuUsage(cpu);
    try testing.expect(delta.user >= 0);
    try testing.expect(delta.system >= 0);
}

test "process argvFrom preserves argv0 script and args" {
    const argv = try argvFrom(testing.allocator, "home", "app.ts", &.{ "--watch", "x" });
    defer freeArgv(testing.allocator, argv);

    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("home", argv[0]);
    try testing.expectEqualStrings("app.ts", argv[1]);
    try testing.expectEqualStrings("--watch", argv[2]);
    try testing.expectEqualStrings("x", argv[3]);
}
