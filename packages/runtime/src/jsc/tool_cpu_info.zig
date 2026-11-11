//! Per-call native processor information for the repository-tool os adapter.
const std = @import("std");
const builtin = @import("builtin");
const io = std.Io.Threaded.global_single_threaded.io();
const files = @import("tool_cpu_files.zig");

pub const Times = struct { user: u64, nice: u64, sys: u64, idle: u64, irq: u64 };
pub const Cpu = struct { model: []const u8, speed: u32, times: Times };
const LinuxCpu = struct { id: usize, cpu: Cpu, model_priority: usize = std.math.maxInt(usize) };

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    records: []Cpu,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn milliseconds(ticks: u64, hz: u64) !u64 {
    if (hz == 0) return error.InvalidClockRate;
    return std.math.cast(u64, @as(u128, ticks) * 1000 / hz) orelse error.CpuTimeOverflow;
}

fn clockRate() !u64 {
    // <unistd.h>: _SC_CLK_TCK differs between Darwin and Linux.
    const rate = std.c.sysconf(if (builtin.os.tag == .macos) 3 else 2);
    if (rate <= 0) return error.InvalidClockRate;
    return @intCast(rate);
}

fn parseStat(allocator: std.mem.Allocator, text: []const u8, hz: u64) ![]LinuxCpu {
    var result: std.ArrayList(LinuxCpu) = .empty;
    errdefer result.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse continue;
        if (std.mem.eql(u8, name, "cpu") or !std.mem.startsWith(u8, name, "cpu")) continue;
        const id = std.fmt.parseInt(usize, name[3..], 10) catch return error.InvalidCpuStat;
        for (result.items) |prior| if (prior.id == id) return error.InvalidCpuStat;
        var ticks: [6]u64 = undefined;
        for (&ticks) |*tick| tick.* = std.fmt.parseInt(u64, fields.next() orelse return error.InvalidCpuStat, 10) catch return error.InvalidCpuStat;
        // Node's times use the individual user/nice/system/idle/hard-IRQ
        // counters, not the aggregate row, iowait or softirq counters.
        try result.append(allocator, .{ .id = id, .cpu = .{
            .model = "unknown",
            .speed = 0,
            .times = .{ .user = try milliseconds(ticks[0], hz), .nice = try milliseconds(ticks[1], hz), .sys = try milliseconds(ticks[2], hz), .idle = try milliseconds(ticks[3], hz), .irq = try milliseconds(ticks[5], hz) },
        } });
    }
    if (result.items.len == 0) return error.NoCpuInformation;
    std.mem.sort(LinuxCpu, result.items, {}, struct {
        fn less(_: void, a: LinuxCpu, b: LinuxCpu) bool {
            return a.id < b.id;
        }
    }.less);
    return result.toOwnedSlice(allocator);
}

fn applyModels(records: []LinuxCpu, text: []const u8) void {
    var current: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            current = null;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "processor")) {
            current = std.fmt.parseInt(usize, value, 10) catch null;
            continue;
        }
        if (value.len == 0) continue;
        for ([_][]const u8{ "model name", "cpu model", "CPU part", "Processor", "cpu", "cpu family" }, 0..) |model_key, priority| {
            if (!std.mem.eql(u8, key, model_key)) continue;
            if (current) |id| {
                for (records) |*record| if (record.id == id and priority < record.model_priority) {
                    record.model_priority = priority;
                    record.cpu.model = value;
                    break;
                };
            }
            break;
        }
    }
}

fn linuxSnapshot(allocator: std.mem.Allocator, proc: std.Io.Dir, sys: ?std.Io.Dir, hz: u64) ![]Cpu {
    const stat = try files.read(allocator, proc, "stat", .limited(16 * 1024 * 1024));
    const records = try parseStat(allocator, stat, hz);
    if (files.read(allocator, proc, "cpuinfo", .limited(16 * 1024 * 1024))) |text| {
        applyModels(records, text);
    } else |_| {}
    const output = try allocator.alloc(Cpu, records.len);
    for (records, output) |record, *cpu| {
        cpu.* = record.cpu;
        if (sys) |directory| {
            const path = try std.fmt.allocPrint(allocator, "cpu{d}/cpufreq/scaling_cur_freq", .{record.id});
            const text = files.read(allocator, directory, path, .limited(1024)) catch continue;
            const khz = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch continue;
            cpu.speed = std.math.cast(u32, khz / 1000) orelse return error.CpuSpeedOverflow;
        }
    }
    // Missing model/frequency metadata stays explicitly unknown/zero, like
    // Node. Every record and all CPU time values still come from /proc/stat.
    return output;
}

extern "c" fn host_processor_info(host: u32, flavor: c_int, processors: *u32, info: *?[*]c_int, count: *u32) c_int;

fn darwinSnapshot(allocator: std.mem.Allocator) ![]Cpu {
    var model_buffer: [512]u8 = @splat(0);
    var model: ?[]const u8 = null;
    for ([_][:0]const u8{ "machdep.cpu.brand_string", "hw.model" }) |name| {
        var size: usize = model_buffer.len;
        if (std.c.sysctlbyname(name.ptr, &model_buffer, &size, null, 0) == 0 and size > 0 and size <= model_buffer.len) {
            model = try allocator.dupe(u8, std.mem.sliceTo(model_buffer[0..size], 0));
            break;
        }
    }
    const name = model orelse return error.NoCpuModel;
    var frequency: u64 = 0;
    var size: usize = @sizeOf(u64);
    if (std.c.sysctlbyname("hw.cpufrequency", &frequency, &size, null, 0) != 0 or size != @sizeOf(u64)) frequency = 0;
    // Apple Silicon does not expose hw.cpufrequency. Report unavailable (0),
    // never libuv's invented 2400 MHz or a value derived from CPU count.
    const speed = std.math.cast(u32, frequency / 1_000_000) orelse return error.CpuSpeedOverflow;
    const host = std.c.mach_host_self();
    defer _ = std.c.mach_port_deallocate(std.c.mach_task_self(), host);
    var processors: u32 = 0;
    var words: u32 = 0;
    var information: ?[*]c_int = null;
    // mach/processor_info.h: PROCESSOR_CPU_LOAD_INFO = 2; four CPU states.
    if (host_processor_info(host, 2, &processors, &information, &words) != 0) return error.NoCpuInformation;
    const info = information orelse return error.NoCpuInformation;
    // host_processor_info counts integer words; vm_deallocate takes bytes.
    defer _ = std.c.vm_deallocate(std.c.mach_task_self(), @intFromPtr(info), @as(usize, words) * @sizeOf(c_int));
    if (processors == 0 or @as(u64, processors) * 4 != words) return error.InvalidCpuInformation;
    const hz = try clockRate();
    const output = try allocator.alloc(Cpu, processors);
    for (output, 0..) |*cpu, index| {
        const ticks = @as([*]const u32, @ptrCast(info))[index * 4 ..][0..4];
        cpu.* = .{ .model = name, .speed = speed, .times = .{
            .user = try milliseconds(ticks[0], hz),
            .nice = try milliseconds(ticks[3], hz),
            .sys = try milliseconds(ticks[1], hz),
            .idle = try milliseconds(ticks[2], hz),
            .irq = 0,
        } };
    }
    return output;
}

pub fn snapshot(backing: std.mem.Allocator) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const records = switch (builtin.os.tag) {
        .macos => try darwinSnapshot(allocator),
        .linux => linux: {
            var proc = try std.Io.Dir.cwd().openDir(io, "/proc", .{});
            defer proc.close(io);
            var sys: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, "/sys/devices/system/cpu", .{}) catch null;
            defer if (sys) |*directory| directory.close(io);
            break :linux try linuxSnapshot(allocator, proc, sys, try clockRate());
        },
        else => return error.Unsupported,
    };
    return .{ .arena = arena, .records = records };
}

test "CPU information parses real counter fields and sparse processor IDs" {
    const a = std.testing.allocator;
    const records = try parseStat(a, "cpu 900 900 900 900 900 900\ncpu3 125 2 3 4 999 6 777\ncpu0 1 2 3 4 5 6\nintr 999\n", 250);
    defer a.free(records);
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqual(@as(usize, 0), records[0].id);
    try std.testing.expectEqual(@as(usize, 3), records[1].id);
    try std.testing.expectEqual(Times{ .user = 500, .nice = 8, .sys = 12, .idle = 16, .irq = 24 }, records[1].cpu.times);
    applyModels(records, "processor : 3\nmodel name : Test CPU three\n\nprocessor : 1\nmodel name : offline\n\nprocessor : 0\nmodel name : Test CPU zero\n");
    try std.testing.expectEqualStrings("Test CPU zero", records[0].cpu.model);
    try std.testing.expectEqualStrings("Test CPU three", records[1].cpu.model);
}

test "CPU information refuses missing duplicate malformed or overflowing counters" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "cpu 1 2 3 4 5 6\n", "cpu0 1 2\n", "cpu0 1 2 3 4 5 bad\n", "cpu0 1 2 3 4 5 6\ncpu0 1 2 3 4 5 6\n" }) |text| try std.testing.expectError(if (std.mem.startsWith(u8, text, "cpu ")) error.NoCpuInformation else error.InvalidCpuStat, parseStat(a, text, 100));
    try std.testing.expectError(error.InvalidClockRate, parseStat(a, "cpu0 1 2 3 4 5 6\n", 0));
    try std.testing.expectError(error.CpuTimeOverflow, milliseconds(std.math.maxInt(u64), 1));
    try std.testing.expectEqual(@as(u64, 1000), try milliseconds(1024, 1024));
}

test "CPU information reads native files by numeric ID and refreshes metadata" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cpu3/cpufreq");
    try temporary.dir.writeFile(io, .{ .sub_path = "stat", .data = "cpu3 10 20 30 40 50 60\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "cpuinfo", .data = "processor : 3\nmodel name : actual fixture model\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "cpu3/cpufreq/scaling_cur_freq", .data = "3123456\n" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first = try linuxSnapshot(arena.allocator(), temporary.dir, temporary.dir, 100);
    try std.testing.expectEqualStrings("actual fixture model", first[0].model);
    try std.testing.expectEqual(@as(u32, 3123), first[0].speed);
    try std.testing.expectEqual(@as(u64, 600), first[0].times.irq);
    try temporary.dir.writeFile(io, .{ .sub_path = "cpu3/cpufreq/scaling_cur_freq", .data = "1899999\n" });
    const second = try linuxSnapshot(arena.allocator(), temporary.dir, temporary.dir, 100);
    try std.testing.expectEqual(@as(u32, 1899), second[0].speed);
    try std.testing.expectEqual(@as(u32, 3123), first[0].speed);
}

test "CPU information queries current native processor snapshots with owned storage" {
    var first = try snapshot(std.testing.allocator);
    defer first.deinit();
    var second = try snapshot(std.testing.allocator);
    defer second.deinit();
    try std.testing.expect(first.records.len > 0);
    try std.testing.expectEqual(first.records.len, second.records.len);
    for (first.records, second.records) |one, two| {
        try std.testing.expect(one.model.len > 0);
        try std.testing.expect(one.times.user + one.times.sys + one.times.idle > 0);
        try std.testing.expect(two.times.user + two.times.sys + two.times.idle > 0);
    }
    first.records[0].times.user = 0;
    try std.testing.expect(second.records[0].times.user > 0);
}
