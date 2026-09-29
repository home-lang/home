// Home Programming Language - Scheduling Policies
// CPU affinity and scheduling control

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const ThreadError = @import("errors.zig").ThreadError;

const WindowsGroupAffinity = extern struct {
    mask: usize,
    group: u16,
    reserved: [3]u16,
};

extern "kernel32" fn GetThreadGroupAffinity(
    thread: std.os.windows.HANDLE,
    group_affinity: *WindowsGroupAffinity,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn SetThreadGroupAffinity(
    thread: std.os.windows.HANDLE,
    group_affinity: *const WindowsGroupAffinity,
    previous_group_affinity: ?*WindowsGroupAffinity,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetThreadPriority(
    thread: std.os.windows.HANDLE,
    priority: c_int,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetThreadPriority(
    thread: std.os.windows.HANDLE,
) callconv(.winapi) c_int;

const MachThreadAffinityPolicy = extern struct {
    affinity_tag: std.c.integer_t,
};

const mach_thread_affinity_policy: c_uint = 4;
const mach_thread_affinity_policy_count: std.c.mach_msg_type_number_t =
    @sizeOf(MachThreadAffinityPolicy) / @sizeOf(std.c.integer_t);
// mach/kern_return.h
const mach_not_supported: std.c.kern_return_t = 46;

const windows_priority_error_return: i32 = std.math.maxInt(i32);
const windows_priority_idle: i32 = -15;
const windows_priority_lowest: i32 = -2;
const windows_priority_below_normal: i32 = -1;
const windows_priority_normal: i32 = 0;
const windows_priority_above_normal: i32 = 1;
const windows_priority_highest: i32 = 2;
const windows_priority_time_critical: i32 = 15;

extern "c" fn mach_thread_self() std.c.mach_port_t;
extern "c" fn thread_policy_set(
    thread: std.c.thread_t,
    flavor: c_uint,
    policy_info: [*]std.c.integer_t,
    count: std.c.mach_msg_type_number_t,
) std.c.kern_return_t;
extern "c" fn thread_policy_get(
    thread: std.c.thread_t,
    flavor: c_uint,
    policy_info: [*]std.c.integer_t,
    count: *std.c.mach_msg_type_number_t,
    get_default: *std.c.boolean_t,
) std.c.kern_return_t;

pub const SchedPolicy = enum(c_int) {
    Other = 0,
    FIFO = 1,
    RR = 2,
    Batch = 3,
    Idle = 5,

    pub fn fromInt(val: c_int) SchedPolicy {
        return @enumFromInt(val);
    }

    pub fn toInt(self: SchedPolicy) c_int {
        return @intFromEnum(self);
    }
};

pub const SchedParam = struct {
    priority: i32,

    pub fn init(priority: i32) SchedParam {
        return .{ .priority = priority };
    }
};

pub const CpuSet = struct {
    bits: [32]usize = @splat(0),

    pub const capacity = 32 * @bitSizeOf(usize);

    pub fn init() CpuSet {
        return .{};
    }

    pub fn set(self: *CpuSet, cpu: usize) void {
        const idx = cpu / @bitSizeOf(usize);
        const bit = cpu % @bitSizeOf(usize);
        if (idx < self.bits.len) {
            self.bits[idx] |= (@as(usize, 1) << @intCast(bit));
        }
    }

    pub fn clear(self: *CpuSet, cpu: usize) void {
        const idx = cpu / @bitSizeOf(usize);
        const bit = cpu % @bitSizeOf(usize);
        if (idx < self.bits.len) {
            self.bits[idx] &= ~(@as(usize, 1) << @intCast(bit));
        }
    }

    pub fn isSet(self: *const CpuSet, cpu: usize) bool {
        const idx = cpu / @bitSizeOf(usize);
        const bit = cpu % @bitSizeOf(usize);
        if (idx < self.bits.len) {
            return (self.bits[idx] & (@as(usize, 1) << @intCast(bit))) != 0;
        }
        return false;
    }

    pub fn clearAll(self: *CpuSet) void {
        for (&self.bits) |*b| {
            b.* = 0;
        }
    }
};

fn cpuSetToWindowsGroupAffinity(cpu_set: *const CpuSet) ThreadError!WindowsGroupAffinity {
    var selected_group: ?usize = null;
    var selected_mask: usize = 0;

    for (cpu_set.bits, 0..) |mask, group| {
        if (mask == 0) continue;
        if (selected_group != null) return ThreadError.InvalidCpuSet;
        selected_group = group;
        selected_mask = mask;
    }

    const group = selected_group orelse return ThreadError.InvalidCpuSet;
    return .{
        .mask = selected_mask,
        .group = @intCast(group),
        .reserved = @splat(0),
    };
}

fn windowsGroupAffinityToCpuSet(group_affinity: WindowsGroupAffinity) ThreadError!CpuSet {
    if (group_affinity.mask == 0 or group_affinity.group >= CpuSet.capacity / @bitSizeOf(usize)) {
        return ThreadError.InvalidCpuSet;
    }

    var cpu_set = CpuSet.init();
    cpu_set.bits[group_affinity.group] = group_affinity.mask;
    return cpu_set;
}

pub fn setAffinity(cpu_set: *const CpuSet) ThreadError!void {
    if (comptime builtin.os.tag == .linux) {
        var native: std.os.linux.cpu_set_t = @splat(0);
        for (cpu_set.bits, 0..) |word, index| {
            if (index < native.len) {
                native[index] = word;
            } else if (word != 0) {
                return ThreadError.InvalidCpuSet;
            }
        }
        std.os.linux.sched_setaffinity(0, &native) catch return ThreadError.AffinitySetFailed;
        return;
    }
    if (comptime builtin.os.tag == .windows) {
        const group_affinity = try cpuSetToWindowsGroupAffinity(cpu_set);
        if (!SetThreadGroupAffinity(std.os.windows.GetCurrentThread(), &group_affinity, null).toBool()) {
            return ThreadError.AffinitySetFailed;
        }
        return;
    }
    return ThreadError.OperationNotSupported;
}

pub fn getAffinity() ThreadError!CpuSet {
    if (comptime builtin.os.tag == .linux) {
        const native = posix.sched_getaffinity(0) catch |err| switch (err) {
            error.PermissionDenied => return ThreadError.PermissionDenied,
            else => return ThreadError.SchedParamFailed,
        };
        var result = CpuSet.init();
        for (native, 0..) |word, index| {
            if (index < result.bits.len) result.bits[index] = word;
        }
        return result;
    }
    if (comptime builtin.os.tag == .windows) {
        var group_affinity = WindowsGroupAffinity{
            .mask = 0,
            .group = 0,
            .reserved = @splat(0),
        };
        if (!GetThreadGroupAffinity(std.os.windows.GetCurrentThread(), &group_affinity).toBool()) {
            return ThreadError.SchedParamFailed;
        }
        return windowsGroupAffinityToCpuSet(group_affinity);
    }
    return ThreadError.OperationNotSupported;
}

/// Set the current macOS thread's advisory affinity tag. Threads with the
/// same non-zero tag are hints to the scheduler to share an L2 cache where
/// possible. A zero tag removes the hint. This does not pin a thread to a CPU.
pub fn setAffinityTag(tag: i32) ThreadError!void {
    if (comptime builtin.os.tag != .macos) return ThreadError.OperationNotSupported;

    const thread = mach_thread_self();
    defer _ = std.c.mach_port_deallocate(std.c.mach_task_self(), thread);

    var policy = MachThreadAffinityPolicy{ .affinity_tag = tag };
    const result = thread_policy_set(
        thread,
        mach_thread_affinity_policy,
        @ptrCast(&policy),
        mach_thread_affinity_policy_count,
    );
    if (result == mach_not_supported) return ThreadError.OperationNotSupported;
    if (result != 0) return ThreadError.AffinitySetFailed;
}

/// Read the current macOS thread's advisory affinity tag. Zero means the
/// scheduler has no affinity relationship hint for the thread.
pub fn getAffinityTag() ThreadError!i32 {
    if (comptime builtin.os.tag != .macos) return ThreadError.OperationNotSupported;

    const thread = mach_thread_self();
    defer _ = std.c.mach_port_deallocate(std.c.mach_task_self(), thread);

    var policy = MachThreadAffinityPolicy{ .affinity_tag = 0 };
    var count = mach_thread_affinity_policy_count;
    var get_default: std.c.boolean_t = 0;
    const result = thread_policy_get(
        thread,
        mach_thread_affinity_policy,
        @ptrCast(&policy),
        &count,
        &get_default,
    );
    if (result == mach_not_supported) return ThreadError.OperationNotSupported;
    if (result != 0 or count != mach_thread_affinity_policy_count) return ThreadError.SchedParamFailed;
    return policy.affinity_tag;
}

fn canonicalPriority(priority: i32) ThreadError!i32 {
    if (priority < 0 or priority > 100) return ThreadError.InvalidPriority;
    if (priority == 0) return 0;
    if (priority < 25) return 1;
    if (priority < 50) return 25;
    if (priority < 75) return 50;
    if (priority < 99) return 75;
    return priority;
}

fn priorityToWindows(priority: i32) ThreadError!i32 {
    return switch (try canonicalPriority(priority)) {
        0 => windows_priority_idle,
        1 => windows_priority_lowest,
        25 => windows_priority_below_normal,
        50 => windows_priority_normal,
        75 => windows_priority_above_normal,
        99 => windows_priority_highest,
        100 => windows_priority_time_critical,
        else => unreachable,
    };
}

fn priorityFromWindows(priority: i32) ThreadError!i32 {
    return switch (priority) {
        windows_priority_idle => 0,
        windows_priority_lowest => 1,
        windows_priority_below_normal => 25,
        windows_priority_normal => 50,
        windows_priority_above_normal => 75,
        windows_priority_highest => 99,
        windows_priority_time_critical => 100,
        else => ThreadError.SchedParamFailed,
    };
}

fn priorityToLinuxNice(priority: i32) ThreadError!i32 {
    return switch (try canonicalPriority(priority)) {
        0 => 19,
        1 => 15,
        25 => 10,
        50 => 0,
        75 => -5,
        99 => -10,
        100 => -20,
        else => unreachable,
    };
}

fn priorityFromLinuxNice(nice: i32) ThreadError!i32 {
    return switch (nice) {
        19 => 0,
        15 => 1,
        10 => 25,
        0 => 50,
        -5 => 75,
        -10 => 99,
        -20 => 100,
        else => ThreadError.SchedParamFailed,
    };
}

fn priorityToDarwinQos(priority: i32) ThreadError!c_uint {
    return switch (try canonicalPriority(priority)) {
        0, 1 => 0x09,
        25 => 0x11,
        50 => 0x15,
        75 => 0x19,
        99, 100 => 0x21,
        else => unreachable,
    };
}

fn priorityFromDarwinQos(qos: c_uint) ThreadError!i32 {
    return switch (qos) {
        0x00, 0x15 => 50,
        0x09 => 1,
        0x11 => 25,
        0x19 => 75,
        0x21 => 99,
        else => ThreadError.SchedParamFailed,
    };
}

pub fn setPriority(priority: i32) ThreadError!void {
    if (comptime builtin.os.tag == .windows) {
        const native = try priorityToWindows(priority);
        if (!SetThreadPriority(std.os.windows.GetCurrentThread(), native).toBool()) {
            return ThreadError.SchedParamFailed;
        }
        return;
    }
    if (comptime builtin.os.tag == .linux) {
        const nice = try priorityToLinuxNice(priority);
        const result = std.os.linux.syscall3(
            .setpriority,
            0,
            0,
            @bitCast(@as(isize, nice)),
        );
        return switch (std.os.linux.errno(result)) {
            .SUCCESS => {},
            .ACCES, .PERM => ThreadError.PermissionDenied,
            .INVAL => ThreadError.InvalidPriority,
            else => ThreadError.SchedParamFailed,
        };
    }
    if (comptime builtin.os.tag == .macos) {
        const qos: std.c.qos_class_t = @fromBackingInt(@intCast(try priorityToDarwinQos(priority)));
        const result = std.c.pthread_set_qos_class_self_np(qos, 0);
        if (result == 0) return;
        if (result == @backingInt(std.c.E.PERM)) return ThreadError.PermissionDenied;
        if (result == @backingInt(std.c.E.INVAL)) return ThreadError.InvalidPriority;
        return ThreadError.SchedParamFailed;
    }
    return ThreadError.OperationNotSupported;
}

pub fn getPriority() ThreadError!i32 {
    if (comptime builtin.os.tag == .windows) {
        const native = GetThreadPriority(std.os.windows.GetCurrentThread());
        if (native == windows_priority_error_return) return ThreadError.SchedParamFailed;
        return priorityFromWindows(native);
    }
    if (comptime builtin.os.tag == .linux) {
        const result = std.os.linux.syscall2(.getpriority, 0, 0);
        if (std.os.linux.errno(result) != .SUCCESS) return ThreadError.SchedParamFailed;
        const nice = 20 - @as(i32, @intCast(result));
        return priorityFromLinuxNice(nice);
    }
    if (comptime builtin.os.tag == .macos) {
        var qos: std.c.qos_class_t = .UNSPECIFIED;
        var relative_priority: c_int = 0;
        const result = std.c.pthread_get_qos_class_np(std.c.pthread_self(), &qos, &relative_priority);
        if (result != 0 or relative_priority != 0) return ThreadError.SchedParamFailed;
        return priorityFromDarwinQos(@backingInt(qos));
    }
    return ThreadError.OperationNotSupported;
}

test "abstract priorities map to native scheduler values" {
    try std.testing.expectEqual(@as(i32, windows_priority_idle), try priorityToWindows(0));
    try std.testing.expectEqual(@as(i32, windows_priority_below_normal), try priorityToWindows(25));
    try std.testing.expectEqual(@as(i32, windows_priority_normal), try priorityToWindows(50));
    try std.testing.expectEqual(@as(i32, windows_priority_time_critical), try priorityToWindows(100));
    try std.testing.expectEqual(@as(i32, 10), try priorityToLinuxNice(25));
    try std.testing.expectEqual(@as(i32, -20), try priorityToLinuxNice(100));
    try std.testing.expectEqual(@as(c_uint, 0x11), try priorityToDarwinQos(25));
    try std.testing.expectEqual(@as(c_uint, 0x21), try priorityToDarwinQos(100));
    try std.testing.expectError(ThreadError.InvalidPriority, priorityToWindows(-1));
    try std.testing.expectError(ThreadError.InvalidPriority, priorityToLinuxNice(101));
}

test "cpu set tracks bits across word boundaries" {
    var set = CpuSet.init();
    const word_bits = @bitSizeOf(usize);
    set.set(0);
    set.set(word_bits);
    set.set(CpuSet.capacity - 1);

    try std.testing.expect(set.isSet(0));
    try std.testing.expect(set.isSet(word_bits));
    try std.testing.expect(set.isSet(CpuSet.capacity - 1));
    set.clear(word_bits);
    try std.testing.expect(!set.isSet(word_bits));
}

test "Windows processor-group affinity converts without truncation" {
    const word_bits = @bitSizeOf(usize);
    var set = CpuSet.init();
    set.set(word_bits * 3 + 2);
    set.set(word_bits * 3 + 5);

    const group_affinity = try cpuSetToWindowsGroupAffinity(&set);
    try std.testing.expectEqual(@as(u16, 3), group_affinity.group);
    try std.testing.expectEqual((@as(usize, 1) << 2) | (@as(usize, 1) << 5), group_affinity.mask);

    const round_trip = try windowsGroupAffinityToCpuSet(group_affinity);
    try std.testing.expect(round_trip.isSet(word_bits * 3 + 2));
    try std.testing.expect(round_trip.isSet(word_bits * 3 + 5));
}

test "Windows processor-group affinity rejects unrepresentable sets" {
    var empty = CpuSet.init();
    try std.testing.expectError(ThreadError.InvalidCpuSet, cpuSetToWindowsGroupAffinity(&empty));

    empty.set(0);
    empty.set(@bitSizeOf(usize));
    try std.testing.expectError(ThreadError.InvalidCpuSet, cpuSetToWindowsGroupAffinity(&empty));

    const outside = WindowsGroupAffinity{
        .mask = 1,
        .group = @intCast(CpuSet.capacity / @bitSizeOf(usize)),
        .reserved = @splat(0),
    };
    try std.testing.expectError(ThreadError.InvalidCpuSet, windowsGroupAffinityToCpuSet(outside));
}

test "linux current-thread affinity round trips" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const original = try getAffinity();
    defer setAffinity(&original) catch {};

    var selected: ?usize = null;
    for (0..CpuSet.capacity) |cpu| {
        if (original.isSet(cpu)) {
            selected = cpu;
            break;
        }
    }
    const cpu = selected orelse return error.SkipZigTest;

    var single = CpuSet.init();
    single.set(cpu);
    try setAffinity(&single);
    const observed = try getAffinity();
    try std.testing.expect(observed.isSet(cpu));
    for (0..CpuSet.capacity) |other| {
        if (other != cpu) try std.testing.expect(!observed.isSet(other));
    }
}

test "Windows current-thread affinity round trips" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const original = try getAffinity();
    defer setAffinity(&original) catch {};

    var selected: ?usize = null;
    for (0..CpuSet.capacity) |cpu| {
        if (original.isSet(cpu)) {
            selected = cpu;
            break;
        }
    }
    const cpu = selected orelse return error.SkipZigTest;

    var single = CpuSet.init();
    single.set(cpu);
    try setAffinity(&single);
    const observed = try getAffinity();
    try std.testing.expect(observed.isSet(cpu));
    for (0..CpuSet.capacity) |other| {
        if (other != cpu) try std.testing.expect(!observed.isSet(other));
    }
}

test "macOS current-thread affinity tag round trips or reports kernel unsupported" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const original = getAffinityTag() catch |err| switch (err) {
        ThreadError.OperationNotSupported => {
            try std.testing.expectError(ThreadError.OperationNotSupported, setAffinityTag(1));
            return;
        },
        else => return err,
    };
    defer setAffinityTag(original) catch {};

    const requested: i32 = 0x484f4d45;
    try setAffinityTag(requested);
    try std.testing.expectEqual(requested, try getAffinityTag());
}
