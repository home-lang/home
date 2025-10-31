// Timing Attack Detection
// Statistical analysis to detect timing leaks

const std = @import("std");
const timing = @import("timing.zig");

/// Statistical test result
pub const TestResult = struct {
    is_constant_time: bool,
    confidence: f64, // 0.0 to 1.0
    p_value: f64, // Statistical significance
    leak_severity: timing.LeakSeverity,
    details: [512]u8,
    details_len: usize,

    pub fn init(
        is_constant_time: bool,
        confidence: f64,
        p_value: f64,
        severity: timing.LeakSeverity,
        details: []const u8,
    ) TestResult {
        var result: TestResult = undefined;
        result.is_constant_time = is_constant_time;
        result.confidence = confidence;
        result.p_value = p_value;
        result.leak_severity = severity;

        @memset(&result.details, 0);
        @memcpy(result.details[0..details.len], details);
        result.details_len = details.len;

        return result;
    }

    pub fn getDetails(self: *const TestResult) []const u8 {
        return self.details[0..self.details_len];
    }
};

/// Timing oracle for testing
pub const TimingOracle = struct {
    samples_a: std.ArrayList(u64),
    samples_b: std.ArrayList(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TimingOracle {
        return .{
            .samples_a = std.ArrayList(u64){},
            .samples_b = std.ArrayList(u64){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TimingOracle) void {
        self.samples_a.deinit(self.allocator);
        self.samples_b.deinit(self.allocator);
    }

    pub fn addSampleA(self: *TimingOracle, cycles: u64) !void {
        try self.samples_a.append(self.allocator, cycles);
    }

    pub fn addSampleB(self: *TimingOracle, cycles: u64) !void {
        try self.samples_b.append(self.allocator, cycles);
    }

    pub fn getMeanA(self: *const TimingOracle) f64 {
        if (self.samples_a.items.len == 0) return 0.0;

        var sum: u64 = 0;
        for (self.samples_a.items) |sample| {
            sum += sample;
        }

        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.samples_a.items.len));
    }

    pub fn getMeanB(self: *const TimingOracle) f64 {
        if (self.samples_b.items.len == 0) return 0.0;

        var sum: u64 = 0;
        for (self.samples_b.items) |sample| {
            sum += sample;
        }

        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.samples_b.items.len));
    }

    pub fn getVarianceA(self: *const TimingOracle) f64 {
        if (self.samples_a.items.len < 2) return 0.0;

        const mean = self.getMeanA();
        var sum_sq_diff: f64 = 0.0;

        for (self.samples_a.items) |sample| {
            const diff = @as(f64, @floatFromInt(sample)) - mean;
            sum_sq_diff += diff * diff;
        }

        return sum_sq_diff / @as(f64, @floatFromInt(self.samples_a.items.len - 1));
    }

    pub fn getVarianceB(self: *const TimingOracle) f64 {
        if (self.samples_b.items.len < 2) return 0.0;

        const mean = self.getMeanB();
        var sum_sq_diff: f64 = 0.0;

        for (self.samples_b.items) |sample| {
            const diff = @as(f64, @floatFromInt(sample)) - mean;
            sum_sq_diff += diff * diff;
        }

        return sum_sq_diff / @as(f64, @floatFromInt(self.samples_b.items.len - 1));
    }

    /// Welch's t-test for comparing two groups with unequal variances
    pub fn welchTTest(self: *const TimingOracle) f64 {
        const mean_a = self.getMeanA();
        const mean_b = self.getMeanB();
        const var_a = self.getVarianceA();
        const var_b = self.getVarianceB();
        const n_a = @as(f64, @floatFromInt(self.samples_a.items.len));
        const n_b = @as(f64, @floatFromInt(self.samples_b.items.len));

        if (n_a < 2 or n_b < 2) return 0.0;

        // Calculate t-statistic
        const numerator = mean_a - mean_b;
        const denominator = @sqrt((var_a / n_a) + (var_b / n_b));

        if (denominator == 0.0) return 0.0;

        return numerator / denominator;
    }

    /// Cohen's d effect size
    pub fn cohensD(self: *const TimingOracle) f64 {
        const mean_a = self.getMeanA();
        const mean_b = self.getMeanB();
        const var_a = self.getVarianceA();
        const var_b = self.getVarianceB();
        const n_a = @as(f64, @floatFromInt(self.samples_a.items.len));
        const n_b = @as(f64, @floatFromInt(self.samples_b.items.len));

        // Pooled standard deviation
        const pooled_var = ((n_a - 1.0) * var_a + (n_b - 1.0) * var_b) / (n_a + n_b - 2.0);
        const pooled_sd = @sqrt(pooled_var);

        if (pooled_sd == 0.0) return 0.0;

        return (mean_a - mean_b) / pooled_sd;
    }
};

/// Timing leak detector
pub const LeakDetector = struct {
    oracle: TimingOracle,
    threshold_cycles: u64,

    pub fn init(allocator: std.mem.Allocator, threshold_cycles: u64) LeakDetector {
        return .{
            .oracle = TimingOracle.init(allocator),
            .threshold_cycles = threshold_cycles,
        };
    }

    pub fn deinit(self: *LeakDetector) void {
        self.oracle.deinit();
    }

    /// Test if function exhibits timing leaks
    pub fn testFunction(
        self: *LeakDetector,
        comptime func: anytype,
        args_a: anytype,
        args_b: anytype,
        iterations: usize,
    ) !TestResult {
        // Measure group A
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const cycles = timing.measureCycles(func, args_a);
            try self.oracle.addSampleA(cycles);
        }

        // Measure group B
        i = 0;
        while (i < iterations) : (i += 1) {
            const cycles = timing.measureCycles(func, args_b);
            try self.oracle.addSampleB(cycles);
        }

        // Analyze results
        return self.analyze();
    }

    fn analyze(self: *LeakDetector) TestResult {
        const mean_a = self.oracle.getMeanA();
        const mean_b = self.oracle.getMeanB();
        const mean_diff = @abs(mean_a - mean_b);

        const t_stat = self.oracle.welchTTest();
        const effect_size = self.oracle.cohensD();

        // Determine if constant-time
        const is_ct = mean_diff <= @as(f64, @floatFromInt(self.threshold_cycles));

        // Calculate confidence (inverse of effect size, clamped)
        const confidence = @max(0.0, @min(1.0, 1.0 - (@abs(effect_size) / 10.0)));

        // Approximate p-value from t-statistic (simplified)
        // In production, would use proper t-distribution
        const p_value = if (@abs(t_stat) > 2.0) 0.05 else 0.5;

        // Determine severity
        const severity = blk: {
            const diff_u64: u64 = @intFromFloat(@abs(mean_diff));
            if (diff_u64 < 3000) { // < 1μs
                break :blk timing.LeakSeverity.low;
            } else if (diff_u64 < 30000) { // < 10μs
                break :blk timing.LeakSeverity.medium;
            } else if (diff_u64 < 300000) { // < 100μs
                break :blk timing.LeakSeverity.high;
            } else {
                break :blk timing.LeakSeverity.critical;
            }
        };

        var details_buf: [256]u8 = undefined;
        const details = std.fmt.bufPrint(
            &details_buf,
            "Mean diff: {d:.2} cycles, t={d:.2}, d={d:.2}",
            .{ mean_diff, t_stat, effect_size },
        ) catch "Analysis complete";

        return TestResult.init(is_ct, confidence, p_value, severity, details);
    }
};

test "timing oracle" {
    const testing = std.testing;

    var oracle = TimingOracle.init(testing.allocator);
    defer oracle.deinit();

    // Add samples
    try oracle.addSampleA(1000);
    try oracle.addSampleA(1100);
    try oracle.addSampleA(1200);

    try oracle.addSampleB(5000);
    try oracle.addSampleB(5100);
    try oracle.addSampleB(5200);

    // Check means
    const mean_a = oracle.getMeanA();
    const mean_b = oracle.getMeanB();

    try testing.expectApproxEqAbs(@as(f64, 1100.0), mean_a, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 5100.0), mean_b, 1.0);

    // Check t-test
    const t_stat = oracle.welchTTest();
    try testing.expect(@abs(t_stat) > 1.0); // Should show significant difference
}

test "leak detector - constant time" {
    const testing = std.testing;

    var detector = LeakDetector.init(testing.allocator, 1000);
    defer detector.deinit();

    const TestFn = struct {
        fn constantTime(_: u32) void {
            var sum: u64 = 0;
            var i: u64 = 0;
            while (i < 100) : (i += 1) {
                sum += i;
            }
            timing.compilerBarrier();
        }
    };

    const result = try detector.testFunction(TestFn.constantTime, .{@as(u32, 0)}, .{@as(u32, 1)}, 50);

    // Should be relatively constant-time
    try testing.expectEqual(timing.LeakSeverity.low, result.leak_severity);
}

test "leak detector - timing leak" {
    const testing = std.testing;

    var detector = LeakDetector.init(testing.allocator, 1000);
    defer detector.deinit();

    const TestFn = struct {
        fn variableTime(input: u32) void {
            var sum: u64 = 0;
            var i: u64 = 0;
            // Loop count depends on input - timing leak!
            while (i < input) : (i += 1) {
                sum += i;
            }
            timing.compilerBarrier();
        }
    };

    const result = try detector.testFunction(TestFn.variableTime, .{@as(u32, 10)}, .{@as(u32, 1000)}, 50);

    // Should detect timing leak
    try testing.expect(!result.is_constant_time);
    try testing.expect(result.leak_severity != .none);
}
