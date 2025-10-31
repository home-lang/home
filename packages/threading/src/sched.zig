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
    bits: [32]usize = [_]usize{0} ** 32,

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
    _ = cpu_set;
    switch (builtin.os.tag) {
        .linux => {
            // Linux-specific affinity setting
            return ThreadError.NotSupported;
        },
        .macos, .freebsd, .windows => {
            return ThreadError.NotSupported;
        },
        else => {
            return ThreadError.NotSupported;
        },
    }
}

pub fn getAffinity() ThreadError!CpuSet {
    switch (builtin.os.tag) {
        .linux => {
            return ThreadError.NotSupported;
        },
        else => {
            return ThreadError.NotSupported;
        },
    }
}

pub fn setPriority(priority: i32) ThreadError!void {
    _ = priority;
    return ThreadError.NotSupported;
}

pub fn getPriority() ThreadError!i32 {
    return ThreadError.NotSupported;
}
