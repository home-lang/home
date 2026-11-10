//! Fresh native CPU availability for the repository-tool os adapter.
const std = @import("std");
const builtin = @import("builtin");
const io = std.Io.Threaded.global_single_threaded.io();

fn readSmall(allocator: std.mem.Allocator, directory: std.Io.Dir, path: []const u8) ?[]u8 {
    return directory.readFileAlloc(io, path, allocator, .limited(65537)) catch null;
}

fn parseNumber(text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

fn quotaCount(quota: i64, period: i64) ?usize {
    if (quota <= 0 or period <= 0) return null;
    // Match libuv's whole-CPU estimate, including sub-CPU quotas.
    return std.math.cast(usize, @max(@divTrunc(quota, period), 1));
}

fn v2Quota(text: []const u8) ?usize {
    var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const quota = parseNumber(fields.next() orelse return null) orelse return null;
    const period = parseNumber(fields.next() orelse return null) orelse return null;
    if (fields.next() != null) return null;
    return quotaCount(quota, period);
}

fn quotaFile(allocator: std.mem.Allocator, root: std.Io.Dir, path: []const u8, v2: bool) ?usize {
    if (v2) {
        const filename = std.fs.path.join(allocator, &.{ path, "cpu.max" }) catch return null;
        defer allocator.free(filename);
        const contents = readSmall(allocator, root, filename) orelse return null;
        defer allocator.free(contents);
        return v2Quota(contents);
    }
    const quota_path = std.fs.path.join(allocator, &.{ path, "cpu.cfs_quota_us" }) catch return null;
    defer allocator.free(quota_path);
    const period_path = std.fs.path.join(allocator, &.{ path, "cpu.cfs_period_us" }) catch return null;
    defer allocator.free(period_path);
    const quota_text = readSmall(allocator, root, quota_path) orelse return null;
    defer allocator.free(quota_text);
    const period_text = readSmall(allocator, root, period_path) orelse return null;
    defer allocator.free(period_text);
    return quotaCount(parseNumber(quota_text) orelse return null, parseNumber(period_text) orelse return null);
}

fn membershipPath(path: []const u8) []const u8 {
    const relative = std.mem.trim(u8, path, "/");
    var components = std.mem.splitScalar(u8, relative, '/');
    // Namespace-relative /proc paths can refer above the mounted cgroup root.
    // Never escape that root; its visible quota still constrains this process.
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return "";
    return relative;
}

fn hierarchyQuota(allocator: std.mem.Allocator, root: std.Io.Dir, path: []const u8, v2: bool) ?usize {
    var current = membershipPath(path);
    var limit: ?usize = null;
    while (true) {
        if (quotaFile(allocator, root, current, v2)) |count| limit = if (limit) |prior| @min(prior, count) else count;
        if (current.len == 0) break;
        current = std.fs.path.dirname(current) orelse "";
    }
    return limit;
}

fn cgroupQuota(allocator: std.mem.Allocator, root: std.Io.Dir, membership: []const u8) ?usize {
    var lines = std.mem.tokenizeScalar(u8, membership, '\n');
    while (lines.next()) |line| {
        const first = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const remainder = line[first + 1 ..];
        const last = std.mem.indexOfScalar(u8, remainder, ':') orelse continue;
        const controllers = remainder[0..last];
        const path = remainder[last + 1 ..];
        if (!std.mem.startsWith(u8, path, "/")) continue;
        if (std.mem.eql(u8, line[0..first], "0") and controllers.len == 0) {
            if (hierarchyQuota(allocator, root, path, true)) |count| return count;
            continue;
        }
        var names = std.mem.splitScalar(u8, controllers, ',');
        while (names.next()) |name| {
            if (!std.mem.eql(u8, name, "cpu")) continue;
            // Both standard v1 controller mount names are in use.
            for ([_][]const u8{ "cpu", "cpu,cpuacct" }) |mount| {
                var controller = root.openDir(io, mount, .{}) catch continue;
                defer controller.close(io);
                if (hierarchyQuota(allocator, controller, path, false)) |count| return count;
            }
        }
    }
    return null;
}

pub fn availableParallelism() !usize {
    // https://nodejs.org/api/os.html#osavailableparallelism
    // All state is per-call: affinity, CPU online state and quotas can change.
    var count: usize = if (builtin.os.tag == .macos) darwin: {
        for ([_][:0]const u8{ "hw.activecpu", "hw.logicalcpu", "hw.ncpu" }) |name| {
            var result: c_int = 0;
            var length: usize = @sizeOf(c_int);
            if (std.c.sysctlbyname(name.ptr, &result, &length, null, 0) == 0 and length == @sizeOf(c_int) and result > 0) break :darwin @intCast(result);
        }
        break :darwin try std.Thread.getCpuCount();
    } else try std.Thread.getCpuCount();
    if (count == 0) return error.NoAvailableCpu;
    if (builtin.os.tag == .linux) {
        const allocator = std.heap.smp_allocator;
        if (readSmall(allocator, .cwd(), "/proc/self/cgroup")) |membership| {
            defer allocator.free(membership);
            if (std.Io.Dir.cwd().openDir(io, "/sys/fs/cgroup", .{})) |directory| {
                var root = directory;
                defer root.close(io);
                if (cgroupQuota(allocator, root, membership)) |limit| count = @min(count, limit);
            } else |_| {}
        }
    }
    return count;
}

test "CPU quota parsing preserves unlimited, malformed and fractional cases" {
    try std.testing.expectEqual(@as(?usize, null), v2Quota("max 100000\n"));
    try std.testing.expectEqual(@as(?usize, null), v2Quota("-1 100000"));
    try std.testing.expectEqual(@as(?usize, null), v2Quota("50000 0"));
    try std.testing.expectEqual(@as(?usize, null), v2Quota("bad 100000"));
    try std.testing.expectEqual(@as(?usize, null), v2Quota("100000 100000 extra"));
    try std.testing.expectEqual(@as(?usize, 1), v2Quota("50000 100000"));
    try std.testing.expectEqual(@as(?usize, 2), v2Quota("250000 100000\n"));
}

test "cgroup v2 reads actual hierarchical quota files without caching" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "parent/child");
    try temporary.dir.writeFile(io, .{ .sub_path = "cpu.max", .data = "max 100000\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/cpu.max", .data = "200000 100000\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/child/cpu.max", .data = "500000 100000\n" });
    try std.testing.expectEqual(@as(?usize, 2), cgroupQuota(std.testing.allocator, temporary.dir, "0::/parent/child\n"));
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/child/cpu.max", .data = "50000 100000\n" });
    try std.testing.expectEqual(@as(?usize, 1), cgroupQuota(std.testing.allocator, temporary.dir, "0::/parent/child\n"));
    try temporary.dir.writeFile(io, .{ .sub_path = "cpu.max", .data = "300000 100000\n" });
    try std.testing.expectEqual(@as(?usize, 3), cgroupQuota(std.testing.allocator, temporary.dir, "0::/../../outside\n"));
}

test "cgroup v1 reads controller membership and real quota period pairs" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cpu,cpuacct/group");
    try temporary.dir.writeFile(io, .{ .sub_path = "cpu,cpuacct/group/cpu.cfs_quota_us", .data = "150000\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "cpu,cpuacct/group/cpu.cfs_period_us", .data = "100000\n" });
    try std.testing.expectEqual(@as(?usize, 1), cgroupQuota(std.testing.allocator, temporary.dir, "7:memory:/elsewhere\n8:cpuacct,cpu:/group\n"));
    try std.testing.expectEqual(@as(?usize, 1), cgroupQuota(std.testing.allocator, temporary.dir, "0::/unified-without-cpu\n8:cpuacct,cpu:/group\n"));
    try temporary.dir.writeFile(io, .{ .sub_path = "cpu,cpuacct/group/cpu.cfs_quota_us", .data = "-1\n" });
    try std.testing.expectEqual(@as(?usize, null), cgroupQuota(std.testing.allocator, temporary.dir, "8:cpuacct,cpu:/group\n"));
}

test "available parallelism queries this native operating system" {
    try std.testing.expect(try availableParallelism() > 0);
}

comptime {
    if (builtin.is_test and builtin.os.tag == .linux) _ = @import("tool_cpu_affinity_linux_test.zig");
}
