//! Native host probes and expected-agent checks from Bun 4982b91e utils/runner.
//! Unknown probe results remain unknown; declared expectations fail closed.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Host = struct {
    os: []const u8,
    arch: []const u8,
    distro: ?[]const u8 = null,
    distro_version: ?[]const u8 = null,
    abi: ?[]const u8 = null,
    abi_version: ?[]const u8 = null,
};

pub const Expected = struct {
    os: ?[]const u8 = null,
    arch: ?[]const u8 = null,
    abi: ?[]const u8 = null,
    distro: ?[]const u8 = null,
    release: ?[]const u8 = null,

    pub fn fromEnvironment(env: *const std.process.Environ.Map) Expected {
        return .{ .os = env.get("EXPECTED_PLATFORM_OS"), .arch = env.get("EXPECTED_PLATFORM_ARCH"), .abi = env.get("EXPECTED_PLATFORM_ABI"), .distro = env.get("EXPECTED_PLATFORM_DISTRO"), .release = env.get("EXPECTED_PLATFORM_RELEASE") };
    }
};

pub const Mismatch = struct { field: []const u8, expected: []const u8, actual: ?[]const u8 };
pub const Check = struct {
    values: [5]Mismatch = undefined,
    len: usize = 0,
    pub fn items(self: *const Check) []const Mismatch {
        return self.values[0..self.len];
    }
};

pub fn check(host: Host, expected: Expected) Check {
    var result = Check{};
    // Like pinned CI, absent/empty expected OS disables the whole check.
    if ((expected.os orelse @as([]const u8, "")).len == 0) return result;
    inline for (.{ "os", "arch", "abi", "distro", "release" }) |field| {
        const wanted: []const u8 = @field(expected, field) orelse "";
        if (wanted.len > 0) {
            const actual: ?[]const u8 = if (comptime std.mem.eql(u8, field, "release")) host.distro_version else @field(host, field);
            const matches = if (actual) |value| (if (comptime std.mem.eql(u8, field, "release")) releaseMatches(value, wanted) else std.mem.eql(u8, value, wanted)) else false;
            if (!matches) {
                result.values[result.len] = .{ .field = field, .expected = wanted, .actual = actual };
                result.len += 1;
            }
        }
    }
    return result;
}

fn releaseMatches(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected) or (std.mem.startsWith(u8, actual, expected) and actual.len > expected.len and actual[expected.len] == '.');
}

pub fn isCI(env: *const std.process.Environ.Map) bool {
    inline for (.{ "CI", "BUILDKITE", "GITHUB_ACTIONS" }) |key| {
        if (std.mem.eql(u8, env.get(key) orelse "", "true")) return true;
    }
    return false;
}

pub const Detected = struct {
    arena: std.heap.ArenaAllocator,
    host: Host,
    pub fn deinit(self: *Detected) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn detect(allocator: Allocator, io: Io) !Detected {
    const os = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        else => return error.UnsupportedCorpusOS,
    };
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedCorpusArchitecture,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const probe = NativeProbe{ .allocator = arena.allocator(), .io = io };
    const host = try detectWith(probe, arena.allocator(), os, arch);
    return .{ .arena = arena, .host = host };
}

const NativeProbe = struct {
    allocator: Allocator,
    io: Io,
    fn exists(self: NativeProbe, path: []const u8) !bool {
        Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }
    fn read(self: NativeProbe, path: []const u8) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
    }
    fn command(self: NativeProbe, argv: []const []const u8) !?[]const u8 {
        const result = std.process.run(self.allocator, self.io, .{ .argv = argv, .expand_arg0 = .expand }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        // Pinned utils treats nonzero exit and signal termination as errors.
        return if (result.term.success()) result.stdout else null;
    }
};

/// Probe injection preserves the exact platform precedence for differential
/// tests. Returned strings are borrowed from probes or allocated by allocator.
pub fn detectWith(probe: anytype, allocator: Allocator, os: []const u8, arch: []const u8) !Host {
    var host = Host{ .os = os, .arch = arch };
    if (std.mem.eql(u8, os, "darwin")) {
        host.distro = "macOS";
        if (try probe.command(&.{ "sw_vers", "-productVersion" })) |value| host.distro_version = trim(value);
    } else if (std.mem.eql(u8, os, "windows")) {
        if (try probe.command(&.{ "cmd", "/c", "ver" })) |value| host.distro = trim(value);
        if (try probe.command(&.{ "cmd", "/c", "ver" })) |value| host.distro_version = trim(value);
    } else if (std.mem.eql(u8, os, "linux")) {
        if (try probe.exists("/etc/alpine-release")) {
            host.abi = "musl";
            host.distro = "alpine";
            const release = trim(try probe.read("/etc/alpine-release"));
            host.distro_version = if (std.mem.indexOfScalar(u8, release, '_')) |index| try std.fmt.allocPrint(allocator, "{s}-edge", .{release[0..index]}) else release;
        } else {
            const lib_arch = if (std.mem.eql(u8, arch, "x64")) "x86_64" else "aarch64";
            const musl = try std.fmt.allocPrint(allocator, "/lib/ld-musl-{s}.so.1", .{lib_arch});
            const gnu = try std.fmt.allocPrint(allocator, "/lib/ld-linux-{s}.so.2", .{lib_arch});
            if (try probe.exists(musl)) host.abi = "musl" else if (try probe.exists(gnu)) host.abi = "gnu" else if (try probe.command(&.{ "ldd", "--version" })) |value| {
                if (std.ascii.findIgnoreCase(value, "musl") != null) host.abi = "musl" else if (std.ascii.findIgnoreCase(value, "gnu") != null or std.ascii.findIgnoreCase(value, "glibc") != null) host.abi = "gnu";
            }
            if (try probe.exists("/etc/os-release")) {
                const release = try probe.read("/etc/os-release");
                host.distro = try releaseField(allocator, release, "ID");
                host.distro_version = try releaseField(allocator, release, "VERSION_ID");
            }
            if (host.distro == null) if (try probe.command(&.{ "lsb_release", "-is" })) |value| {
                const lower = try allocator.dupe(u8, trim(value));
                for (lower) |*c| c.* = std.ascii.toLower(c.*);
                host.distro = lower;
            };
            if (host.distro_version == null) if (try probe.command(&.{ "lsb_release", "-rs" })) |value| {
                host.distro_version = trim(value);
            };
        }
        if (try probe.command(&.{ "ldd", "--version" })) |value| host.abi_version = firstVersion(value);
    } else return error.UnsupportedCorpusOS;
    return host;
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c");
}

fn releaseField(allocator: Allocator, source: []const u8, name: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (line.len > name.len and std.mem.startsWith(u8, line, name) and line[name.len] == '=') {
            const value = std.mem.trimEnd(u8, line[name.len + 1 ..], "\r");
            if (std.mem.indexOfScalar(u8, value, '"') != null) return (try std.json.parseFromSlice([]const u8, allocator, value, .{ .allocate = .alloc_always })).value;
            return value;
        }
    }
    return null;
}

fn firstVersion(source: []const u8) ?[]const u8 {
    for (source, 0..) |c, start| {
        if (!std.ascii.isDigit(c)) continue;
        var end = start;
        while (end < source.len and std.ascii.isDigit(source[end])) : (end += 1) {}
        if (end >= source.len or source[end] != '.' or end + 1 >= source.len or !std.ascii.isDigit(source[end + 1])) continue;
        end += 1;
        while (end < source.len and std.ascii.isDigit(source[end])) : (end += 1) {}
        if (end + 1 < source.len and source[end] == '.' and std.ascii.isDigit(source[end + 1])) {
            end += 1;
            while (end < source.len and std.ascii.isDigit(source[end])) : (end += 1) {}
        }
        return source[start..end];
    }
    return null;
}

test "corpus platform expectations fail closed and match release components" {
    const host = Host{ .os = "darwin", .arch = "aarch64", .distro = "macOS", .distro_version = "26.4.1" };
    try std.testing.expectEqual(@as(usize, 0), check(host, .{ .arch = "x64" }).len);
    try std.testing.expectEqual(@as(usize, 0), check(host, .{ .os = "darwin", .release = "26.4" }).len);
    const failed = check(host, .{ .os = "linux", .arch = "x64", .abi = "gnu", .distro = "ubuntu", .release = "26.40" });
    try std.testing.expectEqual(@as(usize, 5), failed.len);
    try std.testing.expect(failed.items()[2].actual == null);
}

test "corpus platform CI environment requires original exact true spelling" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("CI", "1");
    try std.testing.expect(!isCI(&env));
    try env.put("GITHUB_ACTIONS", "true");
    try std.testing.expect(isCI(&env));
    try env.put("EXPECTED_PLATFORM_OS", "linux");
    try std.testing.expectEqualStrings("linux", Expected.fromEnvironment(&env).os.?);
}

/// Recorded OS observations for platform differential controls. No fixture or
/// test file is executed by these controls.
pub const Observations = struct {
    files: []const struct { path: []const u8, contents: []const u8 = "" } = &.{},
    commands: []const struct { argv: []const []const u8, stdout: ?[]const u8 } = &.{},
    pub fn exists(self: Observations, path: []const u8) !bool {
        for (self.files) |file| if (std.mem.eql(u8, path, file.path)) return true;
        return false;
    }
    pub fn read(self: Observations, path: []const u8) ![]const u8 {
        for (self.files) |file| if (std.mem.eql(u8, path, file.path)) return file.contents;
        return error.FileNotFound;
    }
    pub fn command(self: Observations, argv: []const []const u8) !?[]const u8 {
        for (self.commands) |cmd| {
            if (cmd.argv.len != argv.len) continue;
            for (cmd.argv, argv) |a, b| {
                if (!std.mem.eql(u8, a, b)) break;
            } else return cmd.stdout;
        }
        return null;
    }
};

test "corpus platform probes preserve Alpine loader and release precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const host = try detectWith(Observations{
        .files = &.{ .{ .path = "/etc/alpine-release", .contents = "3.23.0_alpha20260101\n" }, .{ .path = "/etc/os-release", .contents = "ID=ignored\nVERSION_ID=99\n" }, .{ .path = "/lib/ld-linux-aarch64.so.2" } },
        .commands = &.{.{ .argv = &.{ "ldd", "--version" }, .stdout = "musl libc\nVersion 1.2.5\n" }},
    }, arena.allocator(), "linux", "aarch64");
    try std.testing.expectEqualStrings("musl", host.abi.?);
    try std.testing.expectEqualStrings("alpine", host.distro.?);
    try std.testing.expectEqualStrings("3.23.0-edge", host.distro_version.?);
    try std.testing.expectEqualStrings("1.2.5", host.abi_version.?);
}

test "corpus platform unknown probes stay unknown and quoted fields are decoded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const host = try detectWith(Observations{ .files = &.{.{ .path = "/etc/os-release", .contents = "NOT_ID=wrong\nID=\"ubuntu\"\r\nVERSION_ID=\"25.04\"\n" }}, .commands = &.{.{ .argv = &.{ "ldd", "--version" }, .stdout = "ldd (GNU libc) 2.42\n" }} }, a, "linux", "x64");
    try std.testing.expectEqualStrings("gnu", host.abi.?);
    try std.testing.expectEqualStrings("2.42", host.abi_version.?);
    try std.testing.expectEqualStrings("ubuntu", host.distro.?);
    try std.testing.expectEqualStrings("25.04", host.distro_version.?);
    const unknown = try detectWith(Observations{}, a, "linux", "aarch64");
    try std.testing.expect(unknown.abi == null and unknown.distro == null and unknown.distro_version == null);
    try std.testing.expectEqual(@as(usize, 2), check(unknown, .{ .os = "linux", .abi = "musl", .release = "3" }).len);
}
