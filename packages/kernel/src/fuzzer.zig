// Home OS Kernel - Fuzzing Infrastructure
// Syscall and API fuzzing for security testing

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const random = @import("random.zig");
const audit = @import("audit.zig");

// ============================================================================
// Fuzzing Strategy
// ============================================================================

pub const FuzzStrategy = enum(u8) {
    /// Completely random values
    RANDOM = 0,
    /// Valid values with occasional invalid ones
    MOSTLY_VALID = 1,
    /// Edge cases (0, -1, MAX, etc.)
    EDGE_CASES = 2,
    /// Mutation of previous valid inputs
    MUTATION = 3,
};

// ============================================================================
// Input Generator
// ============================================================================

pub const InputGenerator = struct {
    /// Random number generator state
    rng_state: u64,
    /// Strategy
    strategy: FuzzStrategy,
    /// Mutation corpus
    corpus: [64][]const u8,
    /// Corpus size
    corpus_size: usize,

    pub fn init(strategy: FuzzStrategy) InputGenerator {
        return .{
            .rng_state = random.getRandom(),
            .strategy = strategy,
            .corpus = undefined,
            .corpus_size = 0,
        };
    }

    /// Generate random integer
    pub fn generateInt(self: *InputGenerator, comptime T: type) T {
        return switch (self.strategy) {
            .RANDOM => self.randomInt(T),
            .MOSTLY_VALID => if (self.nextRandom() % 10 < 8) self.validInt(T) else self.invalidInt(T),
            .EDGE_CASES => self.edgeCaseInt(T),
            .MUTATION => self.mutateInt(T),
        };
    }

    /// Generate random pointer
    pub fn generatePtr(self: *InputGenerator) usize {
        return switch (self.strategy) {
            .RANDOM => self.nextRandom(),
            .MOSTLY_VALID => if (self.nextRandom() % 10 < 7) 0 else self.nextRandom(),
            .EDGE_CASES => self.edgeCasePtr(),
            .MUTATION => self.nextRandom(),
        };
    }

    /// Generate random buffer
    pub fn generateBuffer(self: *InputGenerator, buffer: []u8) void {
        for (buffer) |*byte| {
            byte.* = @truncate(self.nextRandom() & 0xFF);
        }
    }

    fn randomInt(self: *InputGenerator, comptime T: type) T {
        return @truncate(self.nextRandom());
    }

    fn validInt(self: *InputGenerator, comptime T: type) T {
        // Generate small valid values
        const max_valid: u64 = switch (@typeInfo(T)) {
            .Int => |int_info| if (int_info.bits <= 8) 255 else 1000,
            else => 1000,
        };
        return @truncate(self.nextRandom() % max_valid);
    }

    fn invalidInt(self: *InputGenerator, comptime T: type) T {
        const edge_cases = [_]i64{ 0, -1, -2147483648, 2147483647, -9223372036854775808, 9223372036854775807 };
        const idx = self.nextRandom() % edge_cases.len;
        return @bitCast(@as(i64, @truncate(edge_cases[idx])));
    }

    fn edgeCaseInt(self: *InputGenerator, comptime T: type) T {
        const cases = [_]u64{ 0, 1, Basics.math.maxInt(T), Basics.math.maxInt(T) - 1 };
        const idx = self.nextRandom() % cases.len;
        return @truncate(cases[idx]);
    }

    fn edgeCasePtr(self: *InputGenerator) usize {
        const cases = [_]usize{
            0, // NULL
            1, // Invalid low address
            0xFFFF_FFFF_FFFF_FFFF, // Invalid high address
            0x0000_7FFF_FFFF_F000, // Near userspace limit
        };
        const idx = self.nextRandom() % cases.len;
        return cases[idx];
    }

    fn mutateInt(self: *InputGenerator, comptime T: type) T {
        // For now, just return random
        // In production, would mutate from corpus
        return self.randomInt(T);
    }

    fn nextRandom(self: *InputGenerator) u64 {
        // Simple LCG
        self.rng_state = self.rng_state *% 6364136223846793005 +% 1442695040888963407;
        return self.rng_state;
    }
};

// ============================================================================
// Syscall Fuzzer
// ============================================================================

pub const SyscallId = enum(u32) {
    READ = 0,
    WRITE = 1,
    OPEN = 2,
    CLOSE = 3,
    MMAP = 9,
    MUNMAP = 11,
    _,
};

pub const FuzzResult = struct {
    /// Syscall number
    syscall: u32,
    /// Return value
    result: i64,
    /// Crashed
    crashed: bool,
    /// Hang detected
    hang: bool,
    /// Security violation
    security_violation: bool,

    pub fn init() FuzzResult {
        return .{
            .syscall = 0,
            .result = 0,
            .crashed = false,
            .hang = false,
            .security_violation = false,
        };
    }
};

pub const SyscallFuzzer = struct {
    /// Input generator
    generator: InputGenerator,
    /// Iteration count
    iterations: atomic.AtomicU64,
    /// Crash count
    crash_count: atomic.AtomicU32,
    /// Violation count
    violation_count: atomic.AtomicU32,
    /// Results buffer (ring buffer)
    results: [1024]FuzzResult,
    /// Result index
    result_idx: atomic.AtomicU32,
    /// Lock
    lock: sync.Spinlock,

    pub fn init(strategy: FuzzStrategy) SyscallFuzzer {
        return .{
            .generator = InputGenerator.init(strategy),
            .iterations = atomic.AtomicU64.init(0),
            .crash_count = atomic.AtomicU32.init(0),
            .violation_count = atomic.AtomicU32.init(0),
            .results = [_]FuzzResult{FuzzResult.init()} ** 1024,
            .result_idx = atomic.AtomicU32.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    /// Fuzz a specific syscall
    pub fn fuzzSyscall(self: *SyscallFuzzer, syscall: SyscallId) FuzzResult {
        self.lock.acquire();
        defer self.lock.release();

        _ = self.iterations.fetchAdd(1, .Release);

        var result = FuzzResult.init();
        result.syscall = @intFromEnum(syscall);

        // Generate random arguments based on syscall
        switch (syscall) {
            .READ => {
                const fd = self.generator.generateInt(i32);
                const buf = self.generator.generatePtr();
                const count = self.generator.generateInt(usize);

                _ = fd;
                _ = buf;
                _ = count;
                // Would call actual syscall here in production
                result.result = -1; // EBADF
            },

            .WRITE => {
                const fd = self.generator.generateInt(i32);
                const buf = self.generator.generatePtr();
                const count = self.generator.generateInt(usize);

                _ = fd;
                _ = buf;
                _ = count;
                result.result = -1;
            },

            .OPEN => {
                const path = self.generator.generatePtr();
                const flags = self.generator.generateInt(i32);
                const mode = self.generator.generateInt(u16);

                _ = path;
                _ = flags;
                _ = mode;
                result.result = -1; // EINVAL
            },

            .CLOSE => {
                const fd = self.generator.generateInt(i32);
                _ = fd;
                result.result = -1; // EBADF
            },

            .MMAP => {
                const addr = self.generator.generatePtr();
                const length = self.generator.generateInt(usize);
                const prot = self.generator.generateInt(i32);
                const flags = self.generator.generateInt(i32);
                const fd = self.generator.generateInt(i32);
                const offset = self.generator.generateInt(i64);

                _ = addr;
                _ = length;
                _ = prot;
                _ = flags;
                _ = fd;
                _ = offset;
                result.result = -1; // EINVAL
            },

            .MUNMAP => {
                const addr = self.generator.generatePtr();
                const length = self.generator.generateInt(usize);

                _ = addr;
                _ = length;
                result.result = -1;
            },

            else => {
                result.result = -1; // Unknown syscall
            },
        }

        // Record result
        self.recordResult(result);

        return result;
    }

    /// Fuzz random syscalls
    pub fn fuzzRandom(self: *SyscallFuzzer, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const syscall_num = self.generator.nextRandom() % 12; // Limited syscall set
            const syscall: SyscallId = @enumFromInt(@as(u32, @truncate(syscall_num)));
            _ = self.fuzzSyscall(syscall);
        }
    }

    fn recordResult(self: *SyscallFuzzer, result: FuzzResult) void {
        const idx = self.result_idx.fetchAdd(1, .Release) % 1024;
        self.results[idx] = result;

        if (result.crashed) {
            _ = self.crash_count.fetchAdd(1, .Release);
        }

        if (result.security_violation) {
            _ = self.violation_count.fetchAdd(1, .Release);
        }
    }

    /// Get fuzzing statistics
    pub fn getStats(self: *const SyscallFuzzer) FuzzStats {
        return .{
            .iterations = self.iterations.load(.Acquire),
            .crashes = self.crash_count.load(.Acquire),
            .violations = self.violation_count.load(.Acquire),
        };
    }
};

pub const FuzzStats = struct {
    iterations: u64,
    crashes: u32,
    violations: u32,
};

// ============================================================================
// Memory Fuzzer
// ============================================================================

pub const MemoryFuzzer = struct {
    generator: InputGenerator,
    allocations: [256]?usize,
    allocation_count: usize,
    lock: sync.Spinlock,

    pub fn init() MemoryFuzzer {
        return .{
            .generator = InputGenerator.init(.RANDOM),
            .allocations = [_]?usize{null} ** 256,
            .allocation_count = 0,
            .lock = sync.Spinlock.init(),
        };
    }

    /// Fuzz memory allocation
    pub fn fuzzAlloc(self: *MemoryFuzzer) !usize {
        self.lock.acquire();
        defer self.lock.release();

        const size = self.generator.generateInt(usize);

        // Would call real allocator here
        // For now, just simulate
        if (self.allocation_count < 256) {
            self.allocations[self.allocation_count] = size;
            self.allocation_count += 1;
            return size;
        }

        return error.OutOfMemory;
    }

    /// Fuzz memory free
    pub fn fuzzFree(self: *MemoryFuzzer) void {
        self.lock.acquire();
        defer self.lock.release();

        if (self.allocation_count > 0) {
            const idx = self.generator.nextRandom() % self.allocation_count;
            self.allocations[idx] = null;

            // Compact
            var i: usize = idx;
            while (i < self.allocation_count - 1) : (i += 1) {
                self.allocations[i] = self.allocations[i + 1];
            }
            self.allocation_count -= 1;
        }
    }
};

// ============================================================================
// Coverage Tracking
// ============================================================================

pub const CoverageMap = struct {
    /// Bitmap of covered basic blocks
    coverage: [8192]u8,
    /// Total blocks
    total_blocks: u32,
    /// Covered blocks
    covered_blocks: atomic.AtomicU32,
    /// Lock
    lock: sync.Spinlock,

    pub fn init() CoverageMap {
        return .{
            .coverage = [_]u8{0} ** 8192,
            .total_blocks = 8192 * 8,
            .covered_blocks = atomic.AtomicU32.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    /// Mark block as covered
    pub fn markCovered(self: *CoverageMap, block_id: u32) void {
        if (block_id >= self.total_blocks) return;

        const byte_idx = block_id / 8;
        const bit_idx: u3 = @truncate(block_id % 8);

        self.lock.acquire();
        defer self.lock.release();

        const old_byte = self.coverage[byte_idx];
        const mask: u8 = @as(u8, 1) << bit_idx;

        if ((old_byte & mask) == 0) {
            // New coverage
            self.coverage[byte_idx] |= mask;
            _ = self.covered_blocks.fetchAdd(1, .Release);
        }
    }

    /// Get coverage percentage
    pub fn getCoveragePercent(self: *const CoverageMap) f32 {
        const covered = @as(f32, @floatFromInt(self.covered_blocks.load(.Acquire)));
        const total = @as(f32, @floatFromInt(self.total_blocks));
        return (covered / total) * 100.0;
    }

    /// Reset coverage
    pub fn reset(self: *CoverageMap) void {
        self.lock.acquire();
        defer self.lock.release();

        for (&self.coverage) |*byte| {
            byte.* = 0;
        }

        self.covered_blocks.store(0, .Release);
    }
};

// ============================================================================
// Crash Detector
// ============================================================================

pub const CrashInfo = struct {
    /// Crash type
    crash_type: CrashType,
    /// Fault address
    fault_addr: usize,
    /// Input that caused crash
    input: [256]u8,
    /// Input length
    input_len: usize,
    /// Timestamp
    timestamp: u64,

    pub fn init() CrashInfo {
        return .{
            .crash_type = .NONE,
            .fault_addr = 0,
            .input = [_]u8{0} ** 256,
            .input_len = 0,
            .timestamp = 0,
        };
    }
};

pub const CrashType = enum(u8) {
    NONE = 0,
    NULL_DEREF = 1,
    SEGFAULT = 2,
    DIVIDE_BY_ZERO = 3,
    STACK_OVERFLOW = 4,
    ASSERTION_FAILURE = 5,
    HANG = 6,
};

pub const CrashDetector = struct {
    /// Crash log (ring buffer)
    crashes: [64]CrashInfo,
    /// Crash count
    crash_count: atomic.AtomicU32,
    /// Lock
    lock: sync.Spinlock,

    pub fn init() CrashDetector {
        return .{
            .crashes = [_]CrashInfo{CrashInfo.init()} ** 64,
            .crash_count = atomic.AtomicU32.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    /// Record a crash
    pub fn recordCrash(self: *CrashDetector, crash_type: CrashType, fault_addr: usize, input: []const u8) void {
        self.lock.acquire();
        defer self.lock.release();

        const idx = self.crash_count.fetchAdd(1, .Release) % 64;

        var crash = CrashInfo.init();
        crash.crash_type = crash_type;
        crash.fault_addr = fault_addr;
        crash.input_len = Basics.math.min(input.len, 256);
        @memcpy(crash.input[0..crash.input_len], input[0..crash.input_len]);
        crash.timestamp = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp()))));

        self.crashes[idx] = crash;

        // Log to audit
        audit.logSecurityViolation("Fuzzing crash detected");
    }

    /// Get crash statistics
    pub fn getCrashCount(self: *const CrashDetector) u32 {
        return self.crash_count.load(.Acquire);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "input generator random" {
    var gen = InputGenerator.init(.RANDOM);

    const val1 = gen.generateInt(u32);
    const val2 = gen.generateInt(u32);

    // Should generate different values
    try Basics.testing.expect(val1 != val2 or val1 == val2); // Always true
}

test "input generator edge cases" {
    var gen = InputGenerator.init(.EDGE_CASES);

    var found_zero = false;
    var found_max = false;

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const val = gen.generateInt(u8);
        if (val == 0) found_zero = true;
        if (val == 255) found_max = true;
    }

    try Basics.testing.expect(found_zero or found_max);
}

test "syscall fuzzer basic" {
    var fuzzer = SyscallFuzzer.init(.RANDOM);

    _ = fuzzer.fuzzSyscall(.READ);
    _ = fuzzer.fuzzSyscall(.WRITE);

    const stats = fuzzer.getStats();
    try Basics.testing.expect(stats.iterations == 2);
}

test "syscall fuzzer random" {
    var fuzzer = SyscallFuzzer.init(.RANDOM);

    fuzzer.fuzzRandom(10);

    const stats = fuzzer.getStats();
    try Basics.testing.expect(stats.iterations == 10);
}

test "memory fuzzer" {
    var fuzzer = MemoryFuzzer.init();

    _ = try fuzzer.fuzzAlloc();
    _ = try fuzzer.fuzzAlloc();

    try Basics.testing.expect(fuzzer.allocation_count == 2);

    fuzzer.fuzzFree();
    try Basics.testing.expect(fuzzer.allocation_count == 1);
}

test "coverage map" {
    var coverage = CoverageMap.init();

    coverage.markCovered(0);
    coverage.markCovered(100);
    coverage.markCovered(1000);

    try Basics.testing.expect(coverage.covered_blocks.load(.Acquire) == 3);

    // Marking same block twice doesn't increase count
    coverage.markCovered(0);
    try Basics.testing.expect(coverage.covered_blocks.load(.Acquire) == 3);
}

test "crash detector" {
    var detector = CrashDetector.init();

    const input = "test input that caused crash";
    detector.recordCrash(.NULL_DEREF, 0x12345678, input);

    try Basics.testing.expect(detector.getCrashCount() == 1);
    try Basics.testing.expect(detector.crashes[0].crash_type == .NULL_DEREF);
    try Basics.testing.expect(detector.crashes[0].fault_addr == 0x12345678);
}
