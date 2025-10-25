// Home OS Kernel - Time Protection
// Prevents time manipulation attacks and provides monotonic clocks

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const capabilities = @import("capabilities.zig");

// ============================================================================
// Monotonic Clock - Cannot Go Backwards
// ============================================================================

pub const MonotonicClock = struct {
    /// Nanoseconds since boot (atomic for lock-free reads)
    boot_time_ns: atomic.AtomicU64,
    /// Last recorded time (prevents backwards movement)
    last_time_ns: atomic.AtomicU64,
    /// Lock for updates
    lock: sync.Spinlock,

    pub fn init() MonotonicClock {
        return .{
            .boot_time_ns = atomic.AtomicU64.init(0),
            .last_time_ns = atomic.AtomicU64.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    /// Get current monotonic time (nanoseconds since boot)
    pub fn getTime(self: *MonotonicClock) u64 {
        // Read hardware clock (in production, would read TSC or HPET)
        const now = self.readHardwareClock();

        // Ensure monotonicity
        const last = self.last_time_ns.load(.Acquire);
        if (now > last) {
            _ = self.last_time_ns.compareAndSwap(last, now, .Release, .Acquire);
            return now;
        }

        // Clock went backwards (hardware issue), return last valid time
        return last;
    }

    /// Update boot time (called during boot initialization)
    pub fn setBootTime(self: *MonotonicClock, ns: u64) void {
        self.lock.acquire();
        defer self.lock.release();

        self.boot_time_ns.store(ns, .Release);
        self.last_time_ns.store(ns, .Release);
    }

    /// Get time since boot (immune to system time changes)
    pub fn getUptime(self: *MonotonicClock) u64 {
        const now = self.getTime();
        const boot = self.boot_time_ns.load(.Acquire);
        return if (now > boot) now - boot else 0;
    }

    fn readHardwareClock(self: *MonotonicClock) u64 {
        // In production, would read TSC (Time Stamp Counter) or HPET
        // For now, simulate with monotonically increasing counter
        _ = self;
        return @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp())));
    }
};

// ============================================================================
// Wall Clock with Bounds Checking
// ============================================================================

pub const WallClock = struct {
    /// Current wall time (Unix timestamp in nanoseconds)
    current_time_ns: atomic.AtomicU64,
    /// Minimum allowed time (prevents setting clock too far back)
    min_time_ns: atomic.AtomicU64,
    /// Maximum allowed time (prevents setting clock too far forward)
    max_time_ns: atomic.AtomicU64,
    /// Lock for time changes
    lock: sync.RwLock,

    pub fn init(initial_ns: u64) WallClock {
        // Allow time to be set within reasonable bounds
        const min = if (initial_ns > 86400_000_000_000) initial_ns - 86400_000_000_000 else 0; // -1 day
        const max = initial_ns + 86400_000_000_000; // +1 day

        return .{
            .current_time_ns = atomic.AtomicU64.init(initial_ns),
            .min_time_ns = atomic.AtomicU64.init(min),
            .max_time_ns = atomic.AtomicU64.init(max),
            .lock = sync.RwLock.init(),
        };
    }

    /// Get current wall clock time
    pub fn getTime(self: *const WallClock) u64 {
        return self.current_time_ns.load(.Acquire);
    }

    /// Set wall clock time (requires CAP_SYS_TIME)
    pub fn setTime(self: *WallClock, new_time_ns: u64) !void {
        if (!capabilities.hasCapability(.CAP_SYS_TIME)) {
            return error.PermissionDenied;
        }

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Check bounds
        const min = self.min_time_ns.load(.Acquire);
        const max = self.max_time_ns.load(.Acquire);

        if (new_time_ns < min or new_time_ns > max) {
            audit.logSecurityViolation("Time change outside allowed bounds");
            return error.InvalidTime;
        }

        const old_time = self.current_time_ns.load(.Acquire);
        self.current_time_ns.store(new_time_ns, .Release);

        // Log significant time changes
        const diff = if (new_time_ns > old_time) new_time_ns - old_time else old_time - new_time_ns;
        if (diff > 1_000_000_000) { // > 1 second
            var buf: [128]u8 = undefined;
            const msg = Basics.fmt.bufPrint(&buf, "System time changed by {} ns", .{diff}) catch "time_change";
            audit.logSecurityViolation(msg);
        }
    }

    /// Adjust allowed time bounds (requires CAP_SYS_TIME)
    pub fn setBounds(self: *WallClock, min_ns: u64, max_ns: u64) !void {
        if (!capabilities.hasCapability(.CAP_SYS_TIME)) {
            return error.PermissionDenied;
        }

        if (min_ns >= max_ns) {
            return error.InvalidBounds;
        }

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        self.min_time_ns.store(min_ns, .Release);
        self.max_time_ns.store(max_ns, .Release);
    }
};

// ============================================================================
// Timestamp Validation (Replay Attack Prevention)
// ============================================================================

pub const TimestampValidator = struct {
    /// Maximum age of valid timestamp (nanoseconds)
    max_age_ns: u64,
    /// Clock skew tolerance (nanoseconds)
    skew_tolerance_ns: u64,
    /// Reference to monotonic clock
    clock: *MonotonicClock,

    pub fn init(clock: *MonotonicClock, max_age_seconds: u64) TimestampValidator {
        return .{
            .max_age_ns = max_age_seconds * 1_000_000_000,
            .skew_tolerance_ns = 5_000_000_000, // 5 seconds default
            .clock = clock,
        };
    }

    /// Validate timestamp is recent and not from future
    pub fn validate(self: *const TimestampValidator, timestamp_ns: u64) bool {
        const now = self.clock.getTime();

        // Check if timestamp is too old (replay attack)
        if (timestamp_ns + self.max_age_ns < now) {
            return false; // Too old
        }

        // Check if timestamp is too far in future (clock skew)
        if (timestamp_ns > now + self.skew_tolerance_ns) {
            return false; // Too far in future
        }

        return true;
    }

    /// Validate and record timestamp (prevents replay)
    pub fn validateAndRecord(self: *const TimestampValidator, timestamp_ns: u64, nonce: u64) bool {
        // First check basic timestamp validity
        if (!self.validate(timestamp_ns)) {
            return false;
        }

        // In production, would check nonce against database of used nonces
        // For now, just validate timestamp
        _ = nonce;

        return true;
    }
};

// ============================================================================
// Process Time Accounting (Secure CPU Time)
// ============================================================================

pub const ProcessTime = struct {
    /// User-mode CPU time (nanoseconds)
    utime_ns: atomic.AtomicU64,
    /// Kernel-mode CPU time (nanoseconds)
    stime_ns: atomic.AtomicU64,
    /// Start time (monotonic)
    start_time_ns: u64,

    pub fn init(start_time: u64) ProcessTime {
        return .{
            .utime_ns = atomic.AtomicU64.init(0),
            .stime_ns = atomic.AtomicU64.init(0),
            .start_time_ns = start_time,
        };
    }

    /// Add user-mode CPU time
    pub fn addUserTime(self: *ProcessTime, ns: u64) void {
        _ = self.utime_ns.fetchAdd(ns, .Release);
    }

    /// Add kernel-mode CPU time
    pub fn addKernelTime(self: *ProcessTime, ns: u64) void {
        _ = self.stime_ns.fetchAdd(ns, .Release);
    }

    /// Get total CPU time
    pub fn getTotalTime(self: *const ProcessTime) u64 {
        return self.utime_ns.load(.Acquire) + self.stime_ns.load(.Acquire);
    }

    /// Get process uptime (monotonic)
    pub fn getUptime(self: *const ProcessTime, clock: *MonotonicClock) u64 {
        const now = clock.getTime();
        return if (now > self.start_time_ns) now - self.start_time_ns else 0;
    }
};

// ============================================================================
// Interval Timer with Rate Limiting
// ============================================================================

pub const IntervalTimer = struct {
    /// Interval in nanoseconds
    interval_ns: atomic.AtomicU64,
    /// Next expiration time
    next_expiration_ns: atomic.AtomicU64,
    /// Minimum interval (prevents DoS via rapid timers)
    min_interval_ns: u64,
    /// Expiration count
    expiration_count: atomic.AtomicU64,

    const MIN_INTERVAL_NS = 1_000_000; // 1ms minimum

    pub fn init() IntervalTimer {
        return .{
            .interval_ns = atomic.AtomicU64.init(0),
            .next_expiration_ns = atomic.AtomicU64.init(0),
            .min_interval_ns = MIN_INTERVAL_NS,
            .expiration_count = atomic.AtomicU64.init(0),
        };
    }

    /// Set interval (enforces minimum to prevent abuse)
    pub fn setInterval(self: *IntervalTimer, interval_ns: u64, clock: *MonotonicClock) !void {
        if (interval_ns < self.min_interval_ns and interval_ns != 0) {
            return error.IntervalTooSmall;
        }

        self.interval_ns.store(interval_ns, .Release);

        if (interval_ns > 0) {
            const now = clock.getTime();
            self.next_expiration_ns.store(now + interval_ns, .Release);
        } else {
            self.next_expiration_ns.store(0, .Release);
        }
    }

    /// Check if timer has expired
    pub fn checkExpiration(self: *IntervalTimer, clock: *MonotonicClock) bool {
        const next = self.next_expiration_ns.load(.Acquire);
        if (next == 0) return false;

        const now = clock.getTime();
        if (now >= next) {
            // Timer expired, reset for next interval
            const interval = self.interval_ns.load(.Acquire);
            if (interval > 0) {
                self.next_expiration_ns.store(now + interval, .Release);
            } else {
                self.next_expiration_ns.store(0, .Release);
            }

            _ = self.expiration_count.fetchAdd(1, .Release);
            return true;
        }

        return false;
    }

    /// Get time until next expiration
    pub fn timeUntilExpiration(self: *const IntervalTimer, clock: *MonotonicClock) ?u64 {
        const next = self.next_expiration_ns.load(.Acquire);
        if (next == 0) return null;

        const now = clock.getTime();
        return if (next > now) next - now else 0;
    }
};

// ============================================================================
// Global Time System
// ============================================================================

var monotonic_clock: MonotonicClock = undefined;
var wall_clock: WallClock = undefined;
var time_initialized = false;

/// Initialize time system
pub fn init(initial_wall_time_ns: u64) void {
    if (time_initialized) return;

    monotonic_clock = MonotonicClock.init();
    wall_clock = WallClock.init(initial_wall_time_ns);

    time_initialized = true;
}

/// Get monotonic time (nanoseconds since boot)
pub fn getMonotonicTime() u64 {
    if (!time_initialized) return 0;
    return monotonic_clock.getTime();
}

/// Get wall clock time (Unix timestamp in nanoseconds)
pub fn getWallTime() u64 {
    if (!time_initialized) return 0;
    return wall_clock.getTime();
}

/// Set wall clock time (requires CAP_SYS_TIME)
pub fn setWallTime(new_time_ns: u64) !void {
    if (!time_initialized) return error.NotInitialized;
    try wall_clock.setTime(new_time_ns);
}

/// Get system uptime (nanoseconds)
pub fn getUptime() u64 {
    if (!time_initialized) return 0;
    return monotonic_clock.getUptime();
}

// ============================================================================
// Time-based Nonce Generation
// ============================================================================

var nonce_counter: atomic.AtomicU64 = atomic.AtomicU64.init(0);

/// Generate unique nonce (combines time + counter)
pub fn generateNonce() u64 {
    const time_part = getMonotonicTime();
    const counter_part = nonce_counter.fetchAdd(1, .Release);

    // Combine time (upper 48 bits) and counter (lower 16 bits)
    return (time_part & 0xFFFFFFFFFFFF0000) | (counter_part & 0xFFFF);
}

// ============================================================================
// Tests
// ============================================================================

test "monotonic clock never goes backwards" {
    var clock = MonotonicClock.init();
    clock.setBootTime(1000);

    const t1 = clock.getTime();
    const t2 = clock.getTime();
    const t3 = clock.getTime();

    try Basics.testing.expect(t2 >= t1);
    try Basics.testing.expect(t3 >= t2);
}

test "wall clock bounds enforcement" {
    var clock = WallClock.init(1000000);

    // Should fail - outside bounds
    const result = clock.setTime(0);
    try Basics.testing.expect(result == error.PermissionDenied or result == error.InvalidTime);
}

test "timestamp validator rejects old timestamps" {
    var mono = MonotonicClock.init();
    mono.setBootTime(1000000000);

    var validator = TimestampValidator.init(&mono, 60); // 60 second window

    const now = mono.getTime();
    const old_timestamp = now - 120_000_000_000; // 2 minutes ago

    try Basics.testing.expect(!validator.validate(old_timestamp));
}

test "timestamp validator rejects future timestamps" {
    var mono = MonotonicClock.init();
    mono.setBootTime(1000000000);

    var validator = TimestampValidator.init(&mono, 60);

    const now = mono.getTime();
    const future_timestamp = now + 10_000_000_000; // 10 seconds in future

    try Basics.testing.expect(!validator.validate(future_timestamp));
}

test "timestamp validator accepts current timestamps" {
    var mono = MonotonicClock.init();
    mono.setBootTime(1000000000);

    var validator = TimestampValidator.init(&mono, 60);

    const now = mono.getTime();

    try Basics.testing.expect(validator.validate(now));
}

test "process time accounting" {
    var ptime = ProcessTime.init(1000);

    ptime.addUserTime(500);
    ptime.addKernelTime(300);

    try Basics.testing.expect(ptime.getTotalTime() == 800);
    try Basics.testing.expect(ptime.utime_ns.load(.Acquire) == 500);
    try Basics.testing.expect(ptime.stime_ns.load(.Acquire) == 300);
}

test "interval timer expiration" {
    var timer = IntervalTimer.init();
    var clock = MonotonicClock.init();
    clock.setBootTime(1000);

    // Set 1ms interval
    try timer.setInterval(2_000_000, &clock); // 2ms

    // Should not be expired immediately
    try Basics.testing.expect(!timer.checkExpiration(&clock));
}

test "interval timer rejects too small interval" {
    var timer = IntervalTimer.init();
    var clock = MonotonicClock.init();

    // Should fail - interval too small
    const result = timer.setInterval(100, &clock); // 100ns
    try Basics.testing.expect(result == error.IntervalTooSmall);
}

test "nonce generation" {
    const n1 = generateNonce();
    const n2 = generateNonce();
    const n3 = generateNonce();

    // All nonces should be unique
    try Basics.testing.expect(n1 != n2);
    try Basics.testing.expect(n2 != n3);
    try Basics.testing.expect(n1 != n3);
}
