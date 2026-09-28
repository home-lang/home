// Home Programming Language - Scheduling Policies
// CPU affinity and scheduling control

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const ThreadError = @import("errors.zig").ThreadError;

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
    return ThreadError.OperationNotSupported;
}

pub fn setPriority(priority: i32) ThreadError!void {
    _ = priority;
    return ThreadError.OperationNotSupported;
}

pub fn getPriority() ThreadError!i32 {
    return ThreadError.OperationNotSupported;
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
