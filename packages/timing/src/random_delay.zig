// Random Delay Injection
// Add random delays to mask timing variations

const std = @import("std");
const timing = @import("timing.zig");

/// Random delay generator
pub const RandomDelay = struct {
    rng: std.rand.DefaultPrng,
    min_cycles: u64,
    max_cycles: u64,

    pub fn init(seed: u64, min_cycles: u64, max_cycles: u64) RandomDelay {
        return .{
            .rng = std.rand.DefaultPrng.init(seed),
            .min_cycles = min_cycles,
            .max_cycles = max_cycles,
        };
    }

    /// Inject a random delay
    pub fn delay(self: *RandomDelay) void {
        const range = self.max_cycles - self.min_cycles;
        const random_cycles = self.rng.random().uintLessThan(u64, range);
        const target_cycles = self.min_cycles + random_cycles;

        busyWait(target_cycles);
    }

    /// Delay with specific duration
    pub fn delayFixed(cycles: u64) void {
        busyWait(cycles);
    }
};

/// Busy-wait for specified number of cycles
fn busyWait(cycles: u64) void {
    const start = timing.getCycles();
    while (timing.getCycles() - start < cycles) {
        // Spin
        asm volatile ("pause");
    }
}

/// Delay distribution strategy
pub const DelayStrategy = enum {
    uniform, // Uniform distribution
    exponential, // Exponential distribution
    gaussian, // Gaussian/normal distribution
};

/// Advanced random delay with different distributions
pub const AdaptiveDelay = struct {
    rng: std.rand.DefaultPrng,
    strategy: DelayStrategy,
    mean_cycles: u64,
    stddev_cycles: u64,

    pub fn init(seed: u64, strategy: DelayStrategy, mean: u64, stddev: u64) AdaptiveDelay {
        return .{
            .rng = std.rand.DefaultPrng.init(seed),
            .strategy = strategy,
            .mean_cycles = mean,
            .stddev_cycles = stddev,
        };
    }

    pub fn delay(self: *AdaptiveDelay) void {
        const cycles = switch (self.strategy) {
            .uniform => self.uniformDelay(),
            .exponential => self.exponentialDelay(),
            .gaussian => self.gaussianDelay(),
        };

        busyWait(cycles);
    }

    fn uniformDelay(self: *AdaptiveDelay) u64 {
        const min = if (self.mean_cycles > self.stddev_cycles)
            self.mean_cycles - self.stddev_cycles
        else
            0;
        const max = self.mean_cycles + self.stddev_cycles;
        const range = max - min;

        return min + self.rng.random().uintLessThan(u64, range);
    }

    fn exponentialDelay(self: *AdaptiveDelay) u64 {
        // Simple exponential distribution approximation
        const u = self.rng.random().float(f64);
        const lambda = 1.0 / @as(f64, @floatFromInt(self.mean_cycles));
        const delay_val = -@log(1.0 - u) / lambda;

        return @intFromFloat(@max(0.0, delay_val));
    }

    fn gaussianDelay(self: *AdaptiveDelay) u64 {
        // Box-Muller transform for Gaussian distribution
        const uniform1 = self.rng.random().float(f64);
        const uniform2 = self.rng.random().float(f64);

        const z0 = @sqrt(-2.0 * @log(uniform1)) * @cos(2.0 * std.math.pi * uniform2);
        const delay_val = @as(f64, @floatFromInt(self.mean_cycles)) +
            z0 * @as(f64, @floatFromInt(self.stddev_cycles));

        return @intFromFloat(@max(0.0, delay_val));
    }
};

/// Delay budget manager
pub const DelayBudget = struct {
    total_budget: u64,
    used: std.atomic.Value(u64),

    pub fn init(budget_cycles: u64) DelayBudget {
        return .{
            .total_budget = budget_cycles,
            .used = std.atomic.Value(u64).init(0),
        };
    }

    pub fn canDelay(self: *DelayBudget, cycles: u64) bool {
        const current = self.used.load(.acquire);
        return current + cycles <= self.total_budget;
    }

    pub fn useDelay(self: *DelayBudget, cycles: u64) bool {
        const current = self.used.fetchAdd(cycles, .monotonic);
        return current + cycles <= self.total_budget;
    }

    pub fn reset(self: *DelayBudget) void {
        self.used.store(0, .release);
    }

    pub fn getRemaining(self: *const DelayBudget) u64 {
        const current = self.used.load(.acquire);
        if (current >= self.total_budget) return 0;
        return self.total_budget - current;
    }
};

test "random delay" {
    var delay_gen = RandomDelay.init(12345, 1000, 5000);

    // Test delay execution (just ensure it doesn't crash)
    delay_gen.delay();

    // Test fixed delay
    RandomDelay.delayFixed(100);
}

test "adaptive delay strategies" {
    var uniform = AdaptiveDelay.init(12345, .uniform, 10000, 2000);
    uniform.delay();

    var exponential = AdaptiveDelay.init(12345, .exponential, 10000, 2000);
    exponential.delay();

    var gaussian = AdaptiveDelay.init(12345, .gaussian, 10000, 2000);
    gaussian.delay();

    // Just ensure they don't crash
}

test "delay budget" {
    const testing = std.testing;

    var budget = DelayBudget.init(10000);

    try testing.expect(budget.canDelay(5000));
    try testing.expect(budget.useDelay(5000));

    try testing.expect(budget.canDelay(5000));
    try testing.expect(budget.useDelay(5000));

    // Budget exhausted
    try testing.expect(!budget.canDelay(1000));
    try testing.expectEqual(@as(u64, 0), budget.getRemaining());

    // Reset
    budget.reset();
    try testing.expect(budget.canDelay(5000));
    try testing.expectEqual(@as(u64, 10000), budget.getRemaining());
}
