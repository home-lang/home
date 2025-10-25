// Home OS Kernel - KASAN (Kernel Address Sanitizer)
// Detects memory errors: use-after-free, buffer overflows, etc.

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");

// ============================================================================
// Shadow Memory Configuration
// ============================================================================

// KASAN uses shadow memory to track allocation status
// Each 8 bytes of memory is mapped to 1 byte of shadow memory
// Shadow byte meanings:
//   0 = all 8 bytes accessible
//   1-7 = first N bytes accessible, rest inaccessible
//   0xFF = all 8 bytes inaccessible (freed/redzone)
//   0xFE = stack freed
//   0xFD = use-after-free
//   0xFC = stack overflow

const SHADOW_SCALE = 3; // 2^3 = 8 bytes per shadow byte
const SHADOW_GRANULARITY = 8;

pub const ShadowValue = enum(u8) {
    ACCESSIBLE = 0,
    ACCESSIBLE_1 = 1,
    ACCESSIBLE_2 = 2,
    ACCESSIBLE_3 = 3,
    ACCESSIBLE_4 = 4,
    ACCESSIBLE_5 = 5,
    ACCESSIBLE_6 = 6,
    ACCESSIBLE_7 = 7,
    REDZONE = 0xFF,
    STACK_FREE = 0xFE,
    USE_AFTER_FREE = 0xFD,
    STACK_OVERFLOW = 0xFC,
    HEAP_OVERFLOW = 0xFB,
    _,
};

// ============================================================================
// Shadow Memory Map
// ============================================================================

pub const ShadowMemory = struct {
    /// Shadow memory array (simplified - production would use real shadow mapping)
    shadow: [SHADOW_SIZE]u8,
    /// Lock for shadow updates
    lock: sync.Spinlock,
    /// Enabled flag
    enabled: atomic.AtomicBool,
    /// Detection count
    detection_count: atomic.AtomicU64,

    const SHADOW_SIZE = 1024 * 1024; // 1MB shadow = 8MB tracked memory

    pub fn init() ShadowMemory {
        return .{
            .shadow = [_]u8{0} ** SHADOW_SIZE,
            .lock = sync.Spinlock.init(),
            .enabled = atomic.AtomicBool.init(true),
            .detection_count = atomic.AtomicU64.init(0),
        };
    }

    /// Get shadow memory address for a given address
    fn getShadowAddr(self: *ShadowMemory, addr: usize) ?*u8 {
        // Simplified shadow mapping: addr / 8
        const shadow_offset = addr >> SHADOW_SCALE;

        if (shadow_offset >= SHADOW_SIZE) {
            return null;
        }

        return &self.shadow[shadow_offset];
    }

    /// Check if memory access is valid
    pub fn checkAccess(self: *ShadowMemory, addr: usize, size: usize) !void {
        if (!self.enabled.load(.Acquire)) {
            return;
        }

        var offset: usize = 0;
        while (offset < size) : (offset += SHADOW_GRANULARITY) {
            const check_addr = addr + offset;
            const shadow_ptr = self.getShadowAddr(check_addr) orelse return error.ShadowMemoryOutOfRange;

            const shadow_val = shadow_ptr.*;
            const shadow_enum: ShadowValue = @enumFromInt(shadow_val);

            switch (shadow_enum) {
                .ACCESSIBLE => continue,
                .ACCESSIBLE_1, .ACCESSIBLE_2, .ACCESSIBLE_3, .ACCESSIBLE_4, .ACCESSIBLE_5, .ACCESSIBLE_6, .ACCESSIBLE_7 => {
                    // Partial access - check if offset is within accessible range
                    const offset_in_block = check_addr & 0x7;
                    if (offset_in_block >= shadow_val) {
                        return self.reportViolation(.HEAP_OVERFLOW, check_addr);
                    }
                },
                .REDZONE => return self.reportViolation(.HEAP_OVERFLOW, check_addr),
                .STACK_FREE => return self.reportViolation(.STACK_FREE, check_addr),
                .USE_AFTER_FREE => return self.reportViolation(.USE_AFTER_FREE, check_addr),
                .STACK_OVERFLOW => return self.reportViolation(.STACK_OVERFLOW, check_addr),
                .HEAP_OVERFLOW => return self.reportViolation(.HEAP_OVERFLOW, check_addr),
                else => continue,
            }
        }
    }

    /// Poison memory region (mark as inaccessible)
    pub fn poison(self: *ShadowMemory, addr: usize, size: usize, poison_value: ShadowValue) void {
        self.lock.acquire();
        defer self.lock.release();

        var offset: usize = 0;
        while (offset < size) : (offset += SHADOW_GRANULARITY) {
            if (self.getShadowAddr(addr + offset)) |shadow_ptr| {
                shadow_ptr.* = @intFromEnum(poison_value);
            }
        }
    }

    /// Unpoison memory region (mark as accessible)
    pub fn unpoison(self: *ShadowMemory, addr: usize, size: usize) void {
        self.lock.acquire();
        defer self.lock.release();

        var offset: usize = 0;
        while (offset < size) : (offset += SHADOW_GRANULARITY) {
            if (self.getShadowAddr(addr + offset)) |shadow_ptr| {
                shadow_ptr.* = @intFromEnum(ShadowValue.ACCESSIBLE);
            }
        }
    }

    /// Quarantine memory (mark as use-after-free)
    pub fn quarantine(self: *ShadowMemory, addr: usize, size: usize) void {
        self.poison(addr, size, .USE_AFTER_FREE);
    }

    fn reportViolation(self: *ShadowMemory, violation: ShadowValue, addr: usize) !void {
        _ = self.detection_count.fetchAdd(1, .Release);

        var buf: [256]u8 = undefined;
        const msg = Basics.fmt.bufPrint(&buf, "KASAN: {s} at 0x{x}", .{ @tagName(violation), addr }) catch "kasan_violation";

        audit.logSecurityViolation(msg);

        return switch (violation) {
            .USE_AFTER_FREE => error.UseAfterFree,
            .STACK_FREE => error.StackUseAfterFree,
            .STACK_OVERFLOW => error.StackOverflow,
            .HEAP_OVERFLOW => error.HeapOverflow,
            .REDZONE => error.RedzoneViolation,
            else => error.MemoryViolation,
        };
    }

    /// Get detection statistics
    pub fn getDetectionCount(self: *const ShadowMemory) u64 {
        return self.detection_count.load(.Acquire);
    }

    /// Enable/disable KASAN
    pub fn setEnabled(self: *ShadowMemory, enabled: bool) void {
        self.enabled.store(enabled, .Release);
    }
};

// ============================================================================
// Allocation Tracking
// ============================================================================

pub const AllocationInfo = struct {
    /// Allocation address
    addr: usize,
    /// Allocation size
    size: usize,
    /// Allocation timestamp
    timestamp: u64,
    /// Call stack (simplified - would store actual stack trace)
    stack: [4]usize,
    /// Freed flag
    freed: bool,

    pub fn init(addr: usize, size: usize) AllocationInfo {
        return .{
            .addr = addr,
            .size = size,
            .timestamp = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp())))),
            .stack = [_]usize{0} ** 4,
            .freed = false,
        };
    }
};

pub const AllocationTracker = struct {
    /// Tracked allocations
    allocations: [1024]?AllocationInfo,
    /// Allocation count
    allocation_count: atomic.AtomicU32,
    /// Free count
    free_count: atomic.AtomicU32,
    /// Lock
    lock: sync.Spinlock,

    pub fn init() AllocationTracker {
        return .{
            .allocations = [_]?AllocationInfo{null} ** 1024,
            .allocation_count = atomic.AtomicU32.init(0),
            .free_count = atomic.AtomicU32.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    /// Track allocation
    pub fn trackAlloc(self: *AllocationTracker, addr: usize, size: usize) void {
        self.lock.acquire();
        defer self.lock.release();

        const count = self.allocation_count.fetchAdd(1, .Release);
        const idx = count % 1024;

        self.allocations[idx] = AllocationInfo.init(addr, size);
    }

    /// Track free
    pub fn trackFree(self: *AllocationTracker, addr: usize) !void {
        self.lock.acquire();
        defer self.lock.release();

        // Find allocation
        for (&self.allocations) |*maybe_alloc| {
            if (maybe_alloc.*) |*alloc| {
                if (alloc.addr == addr) {
                    if (alloc.freed) {
                        return error.DoubleFree;
                    }

                    alloc.freed = true;
                    _ = self.free_count.fetchAdd(1, .Release);
                    return;
                }
            }
        }

        return error.InvalidFree;
    }

    /// Check for leaks
    pub fn checkLeaks(self: *AllocationTracker) u32 {
        self.lock.acquire();
        defer self.lock.release();

        var leak_count: u32 = 0;

        for (self.allocations) |maybe_alloc| {
            if (maybe_alloc) |alloc| {
                if (!alloc.freed) {
                    leak_count += 1;
                }
            }
        }

        return leak_count;
    }

    /// Get statistics
    pub fn getStats(self: *const AllocationTracker) AllocStats {
        return .{
            .total_allocs = self.allocation_count.load(.Acquire),
            .total_frees = self.free_count.load(.Acquire),
        };
    }
};

pub const AllocStats = struct {
    total_allocs: u32,
    total_frees: u32,
};

// ============================================================================
// Instrumented Memory Operations
// ============================================================================

/// Check memory read
pub fn checkRead(shadow: *ShadowMemory, addr: usize, size: usize) !void {
    try shadow.checkAccess(addr, size);
}

/// Check memory write
pub fn checkWrite(shadow: *ShadowMemory, addr: usize, size: usize) !void {
    try shadow.checkAccess(addr, size);
}

/// Track memory allocation
pub fn onAlloc(shadow: *ShadowMemory, tracker: *AllocationTracker, addr: usize, size: usize) void {
    // Unpoison allocated memory
    shadow.unpoison(addr, size);

    // Track allocation
    tracker.trackAlloc(addr, size);
}

/// Track memory free
pub fn onFree(shadow: *ShadowMemory, tracker: *AllocationTracker, addr: usize, size: usize) !void {
    // Track free (detect double-free)
    try tracker.trackFree(addr);

    // Quarantine freed memory
    shadow.quarantine(addr, size);
}

// ============================================================================
// Stack Protection
// ============================================================================

pub const StackFrame = struct {
    /// Frame start address
    start_addr: usize,
    /// Frame size
    size: usize,
    /// Active flag
    active: bool,

    pub fn init(start_addr: usize, size: usize) StackFrame {
        return .{
            .start_addr = start_addr,
            .size = size,
            .active = true,
        };
    }
};

pub const StackProtector = struct {
    /// Active stack frames
    frames: [64]?StackFrame,
    /// Frame count
    frame_count: usize,
    /// Shadow memory
    shadow: *ShadowMemory,
    /// Lock
    lock: sync.Spinlock,

    pub fn init(shadow: *ShadowMemory) StackProtector {
        return .{
            .frames = [_]?StackFrame{null} ** 64,
            .frame_count = 0,
            .shadow = shadow,
            .lock = sync.Spinlock.init(),
        };
    }

    /// Enter stack frame
    pub fn enterFrame(self: *StackProtector, frame_addr: usize, frame_size: usize) void {
        self.lock.acquire();
        defer self.lock.release();

        if (self.frame_count < 64) {
            self.frames[self.frame_count] = StackFrame.init(frame_addr, frame_size);
            self.frame_count += 1;

            // Unpoison frame
            self.shadow.unpoison(frame_addr, frame_size);
        }
    }

    /// Exit stack frame
    pub fn exitFrame(self: *StackProtector, frame_addr: usize) void {
        self.lock.acquire();
        defer self.lock.release();

        // Find and deactivate frame
        var i: usize = 0;
        while (i < self.frame_count) : (i += 1) {
            if (self.frames[i]) |*frame| {
                if (frame.start_addr == frame_addr) {
                    frame.active = false;

                    // Poison freed stack
                    self.shadow.poison(frame_addr, frame.size, .STACK_FREE);

                    return;
                }
            }
        }
    }
};

// ============================================================================
// Global KASAN State
// ============================================================================

var global_shadow: ShadowMemory = undefined;
var global_tracker: AllocationTracker = undefined;
var kasan_initialized = false;

pub fn init() void {
    if (kasan_initialized) return;

    global_shadow = ShadowMemory.init();
    global_tracker = AllocationTracker.init();

    kasan_initialized = true;

    audit.logSecurityViolation("KASAN initialized");
}

pub fn getShadow() *ShadowMemory {
    if (!kasan_initialized) init();
    return &global_shadow;
}

pub fn getTracker() *AllocationTracker {
    if (!kasan_initialized) init();
    return &global_tracker;
}

// ============================================================================
// Tests
// ============================================================================

test "shadow memory basic" {
    var shadow = ShadowMemory.init();

    // Valid access should succeed
    try shadow.checkAccess(0x1000, 8);
}

test "shadow memory poison" {
    var shadow = ShadowMemory.init();

    shadow.poison(0x1000, 8, .REDZONE);

    // Access to poisoned memory should fail
    const result = shadow.checkAccess(0x1000, 8);
    try Basics.testing.expect(result == error.HeapOverflow or result == error.RedzoneViolation);
}

test "shadow memory unpoison" {
    var shadow = ShadowMemory.init();

    shadow.poison(0x1000, 8, .REDZONE);
    shadow.unpoison(0x1000, 8);

    // Access should succeed after unpoisoning
    try shadow.checkAccess(0x1000, 8);
}

test "use after free detection" {
    var shadow = ShadowMemory.init();

    shadow.quarantine(0x2000, 16);

    const result = shadow.checkAccess(0x2000, 8);
    try Basics.testing.expect(result == error.UseAfterFree);
}

test "allocation tracker" {
    var tracker = AllocationTracker.init();

    tracker.trackAlloc(0x1000, 64);
    tracker.trackAlloc(0x2000, 128);

    const stats = tracker.getStats();
    try Basics.testing.expect(stats.total_allocs == 2);

    try tracker.trackFree(0x1000);
    try Basics.testing.expect(tracker.getStats().total_frees == 1);
}

test "double free detection" {
    var tracker = AllocationTracker.init();

    tracker.trackAlloc(0x1000, 64);
    try tracker.trackFree(0x1000);

    // Second free should fail
    const result = tracker.trackFree(0x1000);
    try Basics.testing.expect(result == error.DoubleFree);
}

test "invalid free detection" {
    var tracker = AllocationTracker.init();

    // Free without alloc should fail
    const result = tracker.trackFree(0x9999);
    try Basics.testing.expect(result == error.InvalidFree);
}

test "memory leak detection" {
    var tracker = AllocationTracker.init();

    tracker.trackAlloc(0x1000, 64);
    tracker.trackAlloc(0x2000, 128);
    try tracker.trackFree(0x1000);

    const leaks = tracker.checkLeaks();
    try Basics.testing.expect(leaks >= 1); // At least one leak (0x2000)
}

test "onAlloc and onFree" {
    var shadow = ShadowMemory.init();
    var tracker = AllocationTracker.init();

    onAlloc(&shadow, &tracker, 0x3000, 64);

    // Should be accessible
    try shadow.checkAccess(0x3000, 64);

    try onFree(&shadow, &tracker, 0x3000, 64);

    // Should be quarantined
    const result = shadow.checkAccess(0x3000, 64);
    try Basics.testing.expect(result == error.UseAfterFree);
}

test "stack protector" {
    var shadow = ShadowMemory.init();
    var protector = StackProtector.init(&shadow);

    protector.enterFrame(0x7000, 128);

    // Frame should be accessible
    try shadow.checkAccess(0x7000, 128);

    protector.exitFrame(0x7000);

    // Frame should be poisoned after exit
    const result = shadow.checkAccess(0x7000, 128);
    try Basics.testing.expect(result == error.StackUseAfterFree);
}

test "detection count" {
    var shadow = ShadowMemory.init();

    shadow.poison(0x4000, 8, .REDZONE);

    _ = shadow.checkAccess(0x4000, 8) catch {};

    try Basics.testing.expect(shadow.getDetectionCount() == 1);

    _ = shadow.checkAccess(0x4000, 8) catch {};

    try Basics.testing.expect(shadow.getDetectionCount() == 2);
}
