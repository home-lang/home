// Timing Attack Mitigations
// Constant-time operations and timing channel protection

const std = @import("std");

pub const constant_time = @import("constant_time.zig");
pub const detection = @import("detection.zig");
pub const random_delay = @import("random_delay.zig");

/// Timing leak severity
pub const LeakSeverity = enum {
    none, // No detectable timing leak
    low, // Minor timing variation (< 1μs)
    medium, // Moderate timing variation (1-10μs)
    high, // Significant timing variation (> 10μs)
    critical, // Obvious timing leak exposing secrets
};

/// Timing measurement result
pub const TimingMeasurement = struct {
    min_cycles: u64,
    max_cycles: u64,
    avg_cycles: u64,
    stddev: f64,
    measurements: usize,

    pub fn getVariation(self: TimingMeasurement) u64 {
        return self.max_cycles - self.min_cycles;
    }

    pub fn getSeverity(self: TimingMeasurement) LeakSeverity {
        const variation = self.getVariation();

        // Approximate cycle-to-time conversion (assuming 3GHz CPU)
        // 1μs = ~3000 cycles
        const us_threshold = 3000;

        if (variation < us_threshold) {
            return .low;
        } else if (variation < us_threshold * 10) {
            return .medium;
        } else if (variation < us_threshold * 100) {
            return .high;
        } else {
            return .critical;
        }
    }

    pub fn isConstantTime(self: TimingMeasurement, threshold_cycles: u64) bool {
        return self.getVariation() <= threshold_cycles;
    }
};

/// High-resolution cycle counter
pub inline fn getCycles() u64 {
    const builtin = @import("builtin");

    // Platform-specific cycle counter
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("rdtsc"
            : [ret] "={rax}" (-> u64),
            :
            : .{ .memory = true }
        ),
        .aarch64, .aarch64_be => blk: {
            // ARM: Read system timer counter
            var counter: u64 = undefined;
            asm volatile ("mrs %[counter], cntvct_el0"
                : [counter] "=r" (counter),
            );
            break :blk counter;
        },
        else => std.time.nanoTimestamp(), // Fallback
    };
}

/// Measure execution time in CPU cycles
pub fn measureCycles(comptime func: anytype, args: anytype) u64 {
    const start = getCycles();
    @call(.auto, func, args);
    const end = getCycles();
    return end - start;
}

/// Benchmark function with multiple iterations
pub fn benchmark(
    allocator: std.mem.Allocator,
    comptime func: anytype,
    args: anytype,
    iterations: usize,
) !TimingMeasurement {
    var measurements = try allocator.alloc(u64, iterations);
    defer allocator.free(measurements);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        measurements[i] = measureCycles(func, args);
    }

    // Calculate statistics
    var min_val: u64 = std.math.maxInt(u64);
    var max_val: u64 = 0;
    var sum: u64 = 0;

    for (measurements) |m| {
        if (m < min_val) min_val = m;
        if (m > max_val) max_val = m;
        sum += m;
    }

    const avg = sum / iterations;

    // Calculate standard deviation
    var variance_sum: f64 = 0.0;
    for (measurements) |m| {
        const diff = @as(f64, @floatFromInt(m)) - @as(f64, @floatFromInt(avg));
        variance_sum += diff * diff;
    }
    const variance = variance_sum / @as(f64, @floatFromInt(iterations));
    const stddev = @sqrt(variance);

    return TimingMeasurement{
        .min_cycles = min_val,
        .max_cycles = max_val,
        .avg_cycles = avg,
        .stddev = stddev,
        .measurements = iterations,
    };
}

/// Memory barrier to prevent compiler reordering
pub inline fn memoryBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

/// Full memory fence (serializing instruction)
pub inline fn memoryFence() void {
    // MFENCE on x86_64 - ensures all loads/stores complete
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// Compiler barrier (prevents optimization reordering)
pub inline fn compilerBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

/// Cache flush for address
pub inline fn cacheFlush(addr: *const anyopaque) void {
    // CLFLUSH on x86_64 - flush cache line
    asm volatile ("clflush (%[addr])"
        :
        : [addr] "r" (addr),
        : .{ .memory = true }
    );
}

/// Serialize execution (wait for all prior instructions)
pub inline fn serialize() void {
    // CPUID acts as a serializing instruction on x86_64
    var eax: u32 = 0;
    var ebx: u32 = undefined;
    var ecx: u32 = 0;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [eax_in] "{eax}" (eax),
          [ecx_in] "{ecx}" (ecx),
    );
}

test "cycle counter" {
    const testing = std.testing;

    const cycles1 = getCycles();
    // Do some work
    var sum: u64 = 0;
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        sum += i;
    }
    const cycles2 = getCycles();

    // Should have taken some cycles
    try testing.expect(cycles2 > cycles1);

    // Prevent optimization
    compilerBarrier();
    try testing.expect(sum > 0);
}

test "measure cycles" {
    const testing = std.testing;

    const TestFn = struct {
        fn compute() void {
            var sum: u64 = 0;
            var i: u64 = 0;
            while (i < 100) : (i += 1) {
                sum += i;
            }
            compilerBarrier();
        }
    };

    const cycles = measureCycles(TestFn.compute, .{});
    try testing.expect(cycles > 0);
}

test "benchmark statistics" {
    const testing = std.testing;

    const TestFn = struct {
        fn compute() void {
            var sum: u64 = 0;
            var i: u64 = 0;
            while (i < 50) : (i += 1) {
                sum += i;
            }
            compilerBarrier();
        }
    };

    const result = try benchmark(testing.allocator, TestFn.compute, .{}, 100);

    try testing.expect(result.min_cycles > 0);
    try testing.expect(result.max_cycles >= result.min_cycles);
    try testing.expect(result.avg_cycles >= result.min_cycles);
    try testing.expect(result.avg_cycles <= result.max_cycles);
    try testing.expectEqual(@as(usize, 100), result.measurements);
}

test "timing severity" {
    const testing = std.testing;

    // Low variation
    var low = TimingMeasurement{
        .min_cycles = 1000,
        .max_cycles = 1500,
        .avg_cycles = 1250,
        .stddev = 100.0,
        .measurements = 100,
    };
    try testing.expectEqual(LeakSeverity.low, low.getSeverity());

    // Critical variation
    var critical = TimingMeasurement{
        .min_cycles = 1000,
        .max_cycles = 500000,
        .avg_cycles = 250000,
        .stddev = 10000.0,
        .measurements = 100,
    };
    try testing.expectEqual(LeakSeverity.critical, critical.getSeverity());
}

test "constant time check" {
    const testing = std.testing;

    const result = TimingMeasurement{
        .min_cycles = 1000,
        .max_cycles = 1100,
        .avg_cycles = 1050,
        .stddev = 50.0,
        .measurements = 100,
    };

    try testing.expect(result.isConstantTime(200));
    try testing.expect(!result.isConstantTime(50));
}
