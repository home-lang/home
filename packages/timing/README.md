# Timing Attack Mitigations

Comprehensive timing side-channel defenses including constant-time operations, timing leak detection, and countermeasures for Home OS.

## Overview

The `timing` package provides protection against timing attacks:

- **Constant-Time Operations**: Operations that take the same time regardless of secret data
- **Timing Leak Detection**: Statistical analysis to identify timing vulnerabilities
- **Random Delays**: Inject noise to mask timing variations
- **Cycle Counting**: High-resolution timing measurements
- **Statistical Testing**: Welch's t-test, Cohen's d for leak detection

## Why Timing Attacks Matter

Timing attacks exploit variations in execution time to extract secret information:

- **Password/Hash Comparison**: Early-exit comparisons leak password length and content
- **Cryptographic Operations**: RSA, AES timing leaks can reveal keys
- **Cache Timing**: CPU cache behavior leaks access patterns
- **Branch Prediction**: Conditional branches leak secret-dependent control flow
- **Memory Access**: DRAM row buffer timing leaks addresses

## Quick Start

### Constant-Time Password Comparison

```zig
const std = @import("std");
const timing = @import("timing");

pub fn verifyPassword(input: []const u8, stored_hash: []const u8) bool {
    // WRONG: Early exit leaks information
    // if (input.len != stored_hash.len) return false;
    // for (input, stored_hash) |a, b| {
    //     if (a != b) return false;  // Leaks position of mismatch!
    // }

    // CORRECT: Constant-time comparison
    return timing.constant_time.secureCompare(input, stored_hash);
}
```

### Detecting Timing Leaks

```zig
const std = @import("std");
const timing = @import("timing");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var detector = timing.detection.LeakDetector.init(allocator, 1000);
    defer detector.deinit();

    // Test function for timing leaks
    const TestFn = struct {
        fn compare(a: []const u8, b: []const u8) bool {
            // Vulnerable: early exit
            if (a.len != b.len) return false;
            for (a, b) |x, y| {
                if (x != y) return false;
            }
            return true;
        }
    };

    const password1 = "secret123";
    const password2 = "secret124"; // Only last char differs

    const result = try detector.testFunction(
        TestFn.compare,
        .{ password1, password1 }, // Group A: matching
        .{ password1, password2 }, // Group B: non-matching
        1000, // Iterations
    );

    if (!result.is_constant_time) {
        std.debug.print("⚠️  TIMING LEAK DETECTED!\n", .{});
        std.debug.print("   Severity: {}\n", .{result.leak_severity});
        std.debug.print("   Confidence: {d:.1}%\n", .{result.confidence * 100});
        std.debug.print("   Details: {s}\n", .{result.getDetails()});
    } else {
        std.debug.print("✓ Constant-time verified\n", .{});
    }
}
```

### Benchmarking with Statistics

```zig
const std = @import("std");
const timing = @import("timing");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const TestFn = struct {
        fn cryptoOp() void {
            // Simulate crypto operation
            var sum: u64 = 0;
            var i: u64 = 0;
            while (i < 1000) : (i += 1) {
                sum +%= i * 12345;
            }
            timing.compilerBarrier();
        }
    };

    const result = try timing.benchmark(allocator, TestFn.cryptoOp, .{}, 10000);

    std.debug.print("Min cycles: {}\n", .{result.min_cycles});
    std.debug.print("Max cycles: {}\n", .{result.max_cycles});
    std.debug.print("Avg cycles: {}\n", .{result.avg_cycles});
    std.debug.print("Stddev: {d:.2}\n", .{result.stddev});
    std.debug.print("Variation: {} cycles\n", .{result.getVariation()});
    std.debug.print("Severity: {}\n", .{result.getSeverity()});
}
```

## Features

### Constant-Time Operations

Operations guaranteed to take the same time regardless of input values:

```zig
const ct = timing.constant_time;

// Constant-time byte comparison
const is_equal = ct.compareBytes(secret1, secret2); // Returns 1 or 0

// Constant-time conditional select
const selected = ct.select(u32, condition, value_a, value_b);

// Constant-time conditional copy
ct.conditionalCopy(dst, src, condition);

// Constant-time comparisons
const is_less = ct.lessThan(u32, a, b);
const minimum = ct.min(u32, a, b);
const maximum = ct.max(u32, a, b);

// Constant-time zero check
const is_zero = ct.isZero(u32, value);

// Constant-time absolute value
const abs_value = ct.abs(i32, signed_value);

// Secure memory zeroing (prevents compiler optimization)
ct.secureZero(sensitive_buffer);
```

**How It Works:**

Constant-time operations avoid:
- **Conditional branches on secrets**: No `if (secret)` branches
- **Early exits**: Always process full length
- **Secret-dependent memory access**: No `array[secret]`
- **Secret-dependent loop counts**: Fixed iterations

Example: Constant-time select using bitwise operations:
```zig
// condition must be 0 or 1
pub fn select(T: type, condition: u1, a: T, b: T) T {
    const mask = condition * maxInt(T);  // All 1s or all 0s
    return (a & mask) | (b & ~mask);
}
// If condition=1: returns (a & ~0) | (b & 0) = a
// If condition=0: returns (a & 0) | (b & ~0) = b
// No branches!
```

### Timing Leak Detection

Statistical analysis to find timing vulnerabilities:

```zig
var detector = timing.detection.LeakDetector.init(allocator, 1000);
defer detector.deinit();

// Test two scenarios
const result = try detector.testFunction(
    functionToTest,
    args_scenario_a,
    args_scenario_b,
    iterations,
);

// Analyze results
if (!result.is_constant_time) {
    // Timing leak detected!
    switch (result.leak_severity) {
        .low => // < 1μs variation
        .medium => // 1-10μs variation
        .high => // 10-100μs variation
        .critical => // > 100μs variation - obvious leak
    }
}
```

**Statistical Tests:**

1. **Welch's t-test**: Compares means of two groups
   - Large |t| value → groups have different timings
   - Used when variances are unequal

2. **Cohen's d**: Effect size measurement
   - d < 0.2: Small effect
   - d = 0.5: Medium effect
   - d > 0.8: Large effect (timing leak likely)

3. **P-value**: Statistical significance
   - p < 0.05: Statistically significant difference
   - p < 0.01: Highly significant

### Random Delay Injection

Add noise to mask timing variations:

```zig
// Simple random delay
var delay_gen = timing.random_delay.RandomDelay.init(
    seed,
    min_cycles: 1000,
    max_cycles: 5000,
);
delay_gen.delay(); // Random delay between 1000-5000 cycles

// Adaptive delay with distributions
var adaptive = timing.random_delay.AdaptiveDelay.init(
    seed,
    .gaussian,  // or .uniform, .exponential
    mean: 10000,
    stddev: 2000,
);
adaptive.delay();

// Delay budget (limit total delay overhead)
var budget = timing.random_delay.DelayBudget.init(100000); // 100k cycles max
if (budget.canDelay(5000)) {
    _ = budget.useDelay(5000);
    timing.random_delay.RandomDelay.delayFixed(5000);
}
```

**When to Use:**

- **Authentication systems**: Hide password comparison timing
- **Rate limiting**: Add jitter to prevent timing analysis
- **Network protocols**: Mask processing time differences
- **Cryptographic operations**: Add noise to key-dependent timing

**Warning:** Random delays alone are not sufficient for security. Always use constant-time algorithms first, delays are defense-in-depth.

### High-Resolution Timing

Precise cycle counting for measurements:

```zig
// Read CPU cycle counter
const start = timing.getCycles();
// ... operation ...
const end = timing.getCycles();
const elapsed = end - start;

// Measure function
const cycles = timing.measureCycles(myFunction, .{arg1, arg2});

// Memory barriers
timing.memoryBarrier();    // Compiler barrier only
timing.memoryFence();      // Hardware memory fence (MFENCE)
timing.compilerBarrier();  // Prevent optimization reordering
timing.serialize();        // Serialize execution (CPUID)

// Cache operations
timing.cacheFlush(&variable); // Flush cache line (CLFLUSH)
```

## Complete Examples

### Secure Password Verification

```zig
const std = @import("std");
const timing = @import("timing");

pub const PasswordVerifier = struct {
    allocator: std.mem.Allocator,
    delay_gen: timing.random_delay.RandomDelay,
    min_delay_cycles: u64,

    pub fn init(allocator: std.mem.Allocator) PasswordVerifier {
        return .{
            .allocator = allocator,
            .delay_gen = timing.random_delay.RandomDelay.init(
                @intCast(std.time.timestamp()),
                10000,  // Min 10k cycles
                50000,  // Max 50k cycles
            ),
            .min_delay_cycles = 10000,
        };
    }

    pub fn verify(self: *PasswordVerifier, input: []const u8, hash: []const u8) bool {
        // Always add random delay first
        self.delay_gen.delay();

        // Constant-time comparison
        const is_valid = timing.constant_time.secureCompare(input, hash);

        // Add minimum delay to mask fast path
        timing.random_delay.RandomDelay.delayFixed(self.min_delay_cycles);

        return is_valid;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var verifier = PasswordVerifier.init(allocator);

    const password_hash = "hashed_password_12345";
    const user_input = "wrong_password";

    const is_valid = verifier.verify(user_input, password_hash);

    std.debug.print("Password valid: {}\n", .{is_valid});
}
```

### Timing-Safe Cryptographic Comparison

```zig
const std = @import("std");
const timing = @import("timing");

pub fn verifyMAC(message: []const u8, received_mac: []const u8, key: []const u8) !bool {
    // Compute expected MAC
    var expected_mac: [32]u8 = undefined;
    computeHMAC(message, key, &expected_mac); // Your HMAC function

    // Constant-time comparison
    const is_valid = timing.constant_time.compareBytes(&expected_mac, received_mac) == 1;

    // Securely zero MAC to prevent memory dumps
    timing.constant_time.secureZero(&expected_mac);

    return is_valid;
}
```

### Auditing Code for Timing Leaks

```zig
const std = @import("std");
const timing = @import("timing");

pub fn auditFunction(
    allocator: std.mem.Allocator,
    comptime func: anytype,
) !void {
    std.debug.print("Auditing {} for timing leaks...\n", .{@typeName(@TypeOf(func))});

    var detector = timing.detection.LeakDetector.init(allocator, 1000);
    defer detector.deinit();

    // Test different input scenarios
    const scenarios = [_]struct {
        name: []const u8,
        args_a: anytype,
        args_b: anytype,
    }{
        .{ .name = "short vs long", .args_a = .{"a"}, .args_b = .{"aaaaaaaaaa"} },
        .{ .name = "first char diff", .args_a = .{"password"}, .args_b = .{"Password"} },
        .{ .name = "last char diff", .args_a = .{"password"}, .args_b = .{"passwore"} },
    };

    for (scenarios) |scenario| {
        const result = try detector.testFunction(
            func,
            scenario.args_a,
            scenario.args_b,
            5000,
        );

        std.debug.print("  Scenario: {s}\n", .{scenario.name});
        std.debug.print("    Constant-time: {}\n", .{result.is_constant_time});
        std.debug.print("    Severity: {}\n", .{result.leak_severity});
        std.debug.print("    Confidence: {d:.1}%\n", .{result.confidence * 100});
        std.debug.print("    {s}\n", .{result.getDetails()});
    }
}
```

## Best Practices

### Security

1. **Always use constant-time for secrets**: Password comparison, MAC verification, key checks
2. **Test with leak detector**: Verify constant-time claims with statistical tests
3. **Defense in depth**: Combine constant-time + random delays + rate limiting
4. **Secure zeroing**: Always zero sensitive data after use
5. **Avoid branches on secrets**: No `if (secret_bit)` branches
6. **Fixed-time algorithms**: Crypto operations should take same time for all inputs
7. **Cache-timing awareness**: Avoid secret-dependent memory access patterns

### Common Pitfalls

```zig
// ❌ VULNERABLE: Early exit
fn compare_bad(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;  // Leaks length
    for (a, b) |x, y| {
        if (x != y) return false;  // Leaks position
    }
    return true;
}

// ✅ SECURE: Constant-time
fn compare_good(a: []const u8, b: []const u8) bool {
    return timing.constant_time.secureCompare(a, b);
}

// ❌ VULNERABLE: Secret-dependent branch
fn process_bad(secret: u8) void {
    if (secret & 0x80 != 0) {  // Branch on secret bit
        // Slow path
    } else {
        // Fast path
    }
}

// ✅ SECURE: Branchless
fn process_good(secret: u8) void {
    const bit = (secret >> 7) & 1;
    // Use bit in constant-time operations
}
```

### Performance

1. **Benchmark first**: Measure overhead of constant-time operations
2. **Selective application**: Only use for security-critical code
3. **Compiler optimization**: Use `-O ReleaseFast` but verify timing
4. **Profile with perf**: Check for unexpected branches or cache misses
5. **Balance security/speed**: Constant-time adds overhead, use where needed

### Testing

1. **Statistical testing**: Use leak detector with many iterations (>1000)
2. **Different inputs**: Test with varying data patterns
3. **Multiple scenarios**: Short/long inputs, matching/non-matching
4. **P-value threshold**: p < 0.05 indicates significant timing difference
5. **Effect size**: Cohen's d > 0.5 suggests exploitable leak

## Timing Attack Examples

### Cache Timing Attack

```zig
// Vulnerable: Array access depends on secret
fn vulnerable(secret: u8) u8 {
    const table = [256]u8{...};
    return table[secret];  // Cache timing leaks secret!
}

// Attacker measures cache hits/misses to determine secret
```

### Branch Prediction Attack

```zig
// Vulnerable: Branch depends on secret
fn vulnerable(secret: bool) void {
    if (secret) {
        expensiveOperation();  // Trains branch predictor
    }
}

// Attacker measures misprediction penalties
```

### Memory Access Timing

```zig
// Vulnerable: Access pattern depends on secret
fn vulnerable(secret: usize) u8 {
    var data = [1000]u8{...};
    return data[secret * 100];  // DRAM row buffer timing leak
}
```

## Mitigations Summary

| Attack Type | Mitigation | Implementation |
|-------------|------------|----------------|
| Early-exit comparison | Constant-time compare | `constant_time.secureCompare()` |
| Conditional branches | Bitwise select | `constant_time.select()` |
| Cache timing | Fixed memory access | Avoid `array[secret]` |
| Branch prediction | Branchless code | Use masks instead of `if` |
| Statistical analysis | Random delays | `random_delay.delay()` |

## Hardware Considerations

### CPU Features

- **RDTSC**: Cycle counter (privileged on some systems)
- **MFENCE**: Memory fence for serialization
- **CLFLUSH**: Cache flush (may be restricted)
- **Speculation**: Modern CPUs may speculatively execute, adding noise

### Platform Differences

- **x86_64**: RDTSC available, high-resolution timing
- **ARM**: Generic timer, may have lower resolution
- **Virtualization**: TSC may be virtualized, less accurate

## License

Part of the Home programming language project.
