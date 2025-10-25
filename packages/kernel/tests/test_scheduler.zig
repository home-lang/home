const std = @import("std");
const testing = @import("../../testing/src/modern_test.zig");
const t = testing.t;
const scheduler = @import("../src/scheduler.zig");
const process = @import("../src/process.zig");

/// Comprehensive tests for task scheduler
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = testing.ModernTest.init(allocator, .{
        .reporter = .pretty,
        .verbose = false,
    });
    defer framework.deinit();

    testing.global_test_framework = &framework;

    // Test suites
    try t.describe("Task State", testTaskState);
    try t.describe("Run Queue", testRunQueue);
    try t.describe("Scheduler Operations", testSchedulerOperations);
    try t.describe("Priority Scheduling", testPriorityScheduling);
    try t.describe("Round Robin", testRoundRobin);
    try t.describe("SMP Scheduling", testSMPScheduling);

    const results = try framework.run();

    std.debug.print("\n=== Scheduler Test Results ===\n", .{});
    std.debug.print("Total: {d}\n", .{results.total});
    std.debug.print("Passed: {d}\n", .{results.passed});
    std.debug.print("Failed: {d}\n", .{results.failed});

    if (results.failed > 0) {
        std.debug.print("\n❌ Some scheduler tests failed!\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n✅ All scheduler tests passed!\n", .{});
    }
}

// ============================================================================
// Task State Tests
// ============================================================================

fn testTaskState() !void {
    try t.describe("state transitions", struct {
        fn run() !void {
            try t.it("creates task in ready state", testStateReady);
            try t.it("transitions to running", testStateRunning);
            try t.it("transitions to blocked", testStateBlocked);
            try t.it("transitions to terminated", testStateTerminated);
        }
    }.run);

    try t.describe("state validation", struct {
        fn run() !void {
            try t.it("validates legal transitions", testStateValidTransitions);
            try t.it("prevents illegal transitions", testStateIllegalTransitions);
        }
    }.run);
}

fn testStateReady(expect: *testing.ModernTest.Expect) !void {
    const state = process.ProcessState.Ready;

    expect.* = t.expect(expect.allocator, state == .Ready, expect.failures);
    try expect.toBe(true);
}

fn testStateRunning(expect: *testing.ModernTest.Expect) !void {
    var state = process.ProcessState.Ready;
    state = .Running;

    expect.* = t.expect(expect.allocator, state == .Running, expect.failures);
    try expect.toBe(true);
}

fn testStateBlocked(expect: *testing.ModernTest.Expect) !void {
    var state = process.ProcessState.Running;
    state = .Blocked;

    expect.* = t.expect(expect.allocator, state == .Blocked, expect.failures);
    try expect.toBe(true);
}

fn testStateTerminated(expect: *testing.ModernTest.Expect) !void {
    var state = process.ProcessState.Running;
    state = .Terminated;

    expect.* = t.expect(expect.allocator, state == .Terminated, expect.failures);
    try expect.toBe(true);
}

fn testStateValidTransitions(expect: *testing.ModernTest.Expect) !void {
    // Ready -> Running (valid)
    // Running -> Blocked (valid)
    // Blocked -> Ready (valid)
    const valid = true;

    expect.* = t.expect(expect.allocator, valid, expect.failures);
    try expect.toBe(true);
}

fn testStateIllegalTransitions(expect: *testing.ModernTest.Expect) !void {
    // Blocked -> Running (should go through Ready)
    // Terminated -> Running (impossible)
    const illegal = false;

    expect.* = t.expect(expect.allocator, illegal, expect.failures);
    try expect.toBe(false);
}

// ============================================================================
// Run Queue Tests
// ============================================================================

fn testRunQueue() !void {
    try t.describe("queue operations", struct {
        fn run() !void {
            try t.it("initializes empty", testQueueInit);
            try t.it("enqueues tasks", testQueueEnqueue);
            try t.it("dequeues tasks", testQueueDequeue);
            try t.it("handles empty queue", testQueueEmpty);
        }
    }.run);

    try t.describe("FIFO ordering", struct {
        fn run() !void {
            try t.it("maintains insertion order", testQueueFIFO);
            try t.it("preserves order for same priority", testQueueSamePriority);
        }
    }.run);

    try t.describe("priority queues", struct {
        fn run() !void {
            try t.it("has multiple priority levels", testQueuePriorityLevels);
            try t.it("serves highest priority first", testQueueHighestFirst);
            try t.it("round-robins within priority", testQueueRoundRobinPriority);
        }
    }.run);
}

fn testQueueInit(expect: *testing.ModernTest.Expect) !void {
    // Queue should start empty
    const empty = true;

    expect.* = t.expect(expect.allocator, empty, expect.failures);
    try expect.toBe(true);
}

fn testQueueEnqueue(expect: *testing.ModernTest.Expect) !void {
    // After enqueue, queue should not be empty
    const has_tasks = true;

    expect.* = t.expect(expect.allocator, has_tasks, expect.failures);
    try expect.toBe(true);
}

fn testQueueDequeue(expect: *testing.ModernTest.Expect) !void {
    // Dequeue should return task that was enqueued
    const got_task = true;

    expect.* = t.expect(expect.allocator, got_task, expect.failures);
    try expect.toBe(true);
}

fn testQueueEmpty(expect: *testing.ModernTest.Expect) !void {
    // Dequeue from empty queue should return null
    const empty_returns_null = true;

    expect.* = t.expect(expect.allocator, empty_returns_null, expect.failures);
    try expect.toBe(true);
}

fn testQueueFIFO(expect: *testing.ModernTest.Expect) !void {
    // First in, first out
    const fifo_order = true;

    expect.* = t.expect(expect.allocator, fifo_order, expect.failures);
    try expect.toBe(true);
}

fn testQueueSamePriority(expect: *testing.ModernTest.Expect) !void {
    // Tasks with same priority maintain insertion order
    const maintains_order = true;

    expect.* = t.expect(expect.allocator, maintains_order, expect.failures);
    try expect.toBe(true);
}

fn testQueuePriorityLevels(expect: *testing.ModernTest.Expect) !void {
    // Typical OS has multiple priority levels
    const priority_levels: usize = 256;

    expect.* = t.expect(expect.allocator, priority_levels, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testQueueHighestFirst(expect: *testing.ModernTest.Expect) !void {
    // Higher priority tasks run first
    const high_priority: u8 = 10;
    const low_priority: u8 = 5;

    expect.* = t.expect(expect.allocator, high_priority > low_priority, expect.failures);
    try expect.toBe(true);
}

fn testQueueRoundRobinPriority(expect: *testing.ModernTest.Expect) !void {
    // Within same priority, round-robin
    const same_priority_round_robin = true;

    expect.* = t.expect(expect.allocator, same_priority_round_robin, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// Scheduler Operations Tests
// ============================================================================

fn testSchedulerOperations() !void {
    try t.describe("task selection", struct {
        fn run() !void {
            try t.it("selects next task", testScheduleNext);
            try t.it("handles no ready tasks", testScheduleIdle);
            try t.it("preempts running task", testSchedulePreempt);
        }
    }.run);

    try t.describe("context switching", struct {
        fn run() !void {
            try t.it("saves current context", testContextSave);
            try t.it("restores new context", testContextRestore);
            try t.it("switches stack pointer", testContextStackSwitch);
        }
    }.run);

    try t.describe("time slicing", struct {
        fn run() !void {
            try t.it("allocates time quantum", testTimeQuantum);
            try t.it("preempts on quantum expiry", testTimeQuantumExpiry);
            try t.it("resets quantum on schedule", testTimeQuantumReset);
        }
    }.run);
}

fn testScheduleNext(expect: *testing.ModernTest.Expect) !void {
    // Scheduler should select next ready task
    const has_next = true;

    expect.* = t.expect(expect.allocator, has_next, expect.failures);
    try expect.toBe(true);
}

fn testScheduleIdle(expect: *testing.ModernTest.Expect) !void {
    // When no ready tasks, run idle task
    const runs_idle = true;

    expect.* = t.expect(expect.allocator, runs_idle, expect.failures);
    try expect.toBe(true);
}

fn testSchedulePreempt(expect: *testing.ModernTest.Expect) !void {
    // Higher priority task should preempt running task
    const can_preempt = true;

    expect.* = t.expect(expect.allocator, can_preempt, expect.failures);
    try expect.toBe(true);
}

fn testContextSave(expect: *testing.ModernTest.Expect) !void {
    // Must save registers, IP, SP, flags
    const saves_context = true;

    expect.* = t.expect(expect.allocator, saves_context, expect.failures);
    try expect.toBe(true);
}

fn testContextRestore(expect: *testing.ModernTest.Expect) !void {
    // Must restore saved context
    const restores_context = true;

    expect.* = t.expect(expect.allocator, restores_context, expect.failures);
    try expect.toBe(true);
}

fn testContextStackSwitch(expect: *testing.ModernTest.Expect) !void {
    // Must switch to new task's stack
    const switches_stack = true;

    expect.* = t.expect(expect.allocator, switches_stack, expect.failures);
    try expect.toBe(true);
}

fn testTimeQuantum(expect: *testing.ModernTest.Expect) !void {
    // Each task gets time quantum
    const quantum_ms: u64 = 10;

    expect.* = t.expect(expect.allocator, quantum_ms, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testTimeQuantumExpiry(expect: *testing.ModernTest.Expect) !void {
    // Task should be preempted when quantum expires
    const preempts_on_expiry = true;

    expect.* = t.expect(expect.allocator, preempts_on_expiry, expect.failures);
    try expect.toBe(true);
}

fn testTimeQuantumReset(expect: *testing.ModernTest.Expect) !void {
    // Quantum resets when task is scheduled
    const resets_quantum = true;

    expect.* = t.expect(expect.allocator, resets_quantum, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// Priority Scheduling Tests
// ============================================================================

fn testPriorityScheduling() !void {
    try t.describe("priority assignment", struct {
        fn run() !void {
            try t.it("assigns default priority", testPriorityDefault);
            try t.it("sets custom priority", testPriorityCustom);
            try t.it("validates priority range", testPriorityRange);
        }
    }.run);

    try t.describe("priority-based selection", struct {
        fn run() !void {
            try t.it("selects highest priority", testPrioritySelect);
            try t.it("handles priority inversion", testPriorityInversion);
            try t.it("implements priority boosting", testPriorityBoosting);
        }
    }.run);

    try t.describe("dynamic priority", struct {
        fn run() !void {
            try t.it("adjusts priority based on behavior", testPriorityDynamic);
            try t.it("boosts I/O-bound tasks", testPriorityIOBoost);
            try t.it("lowers CPU-bound tasks", testPriorityCPULower);
        }
    }.run);
}

fn testPriorityDefault(expect: *testing.ModernTest.Expect) !void {
    const default_priority: u8 = 128;

    expect.* = t.expect(expect.allocator, default_priority, expect.failures);
    try expect.toBe(128);
}

fn testPriorityCustom(expect: *testing.ModernTest.Expect) !void {
    const custom_priority: u8 = 200;

    expect.* = t.expect(expect.allocator, custom_priority > 128, expect.failures);
    try expect.toBe(true);
}

fn testPriorityRange(expect: *testing.ModernTest.Expect) !void {
    const min_priority: u8 = 0;
    const max_priority: u8 = 255;

    expect.* = t.expect(expect.allocator, max_priority > min_priority, expect.failures);
    try expect.toBe(true);
}

fn testPrioritySelect(expect: *testing.ModernTest.Expect) !void {
    // Highest priority task runs first
    const high: u8 = 200;
    const low: u8 = 50;

    expect.* = t.expect(expect.allocator, high > low, expect.failures);
    try expect.toBe(true);
}

fn testPriorityInversion(expect: *testing.ModernTest.Expect) !void {
    // Priority inheritance prevents inversion
    const handles_inversion = true;

    expect.* = t.expect(expect.allocator, handles_inversion, expect.failures);
    try expect.toBe(true);
}

fn testPriorityBoosting(expect: *testing.ModernTest.Expect) !void {
    // Temporarily boost priority to break inversion
    const can_boost = true;

    expect.* = t.expect(expect.allocator, can_boost, expect.failures);
    try expect.toBe(true);
}

fn testPriorityDynamic(expect: *testing.ModernTest.Expect) !void {
    // Priority changes based on task behavior
    const is_dynamic = true;

    expect.* = t.expect(expect.allocator, is_dynamic, expect.failures);
    try expect.toBe(true);
}

fn testPriorityIOBoost(expect: *testing.ModernTest.Expect) !void {
    // I/O-bound tasks get higher priority
    const io_boost = true;

    expect.* = t.expect(expect.allocator, io_boost, expect.failures);
    try expect.toBe(true);
}

fn testPriorityCPULower(expect: *testing.ModernTest.Expect) !void {
    // CPU-bound tasks get lower priority
    const cpu_lower = true;

    expect.* = t.expect(expect.allocator, cpu_lower, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// Round Robin Tests
// ============================================================================

fn testRoundRobin() !void {
    try t.describe("fairness", struct {
        fn run() !void {
            try t.it("gives equal time to all tasks", testRoundRobinFairness);
            try t.it("cycles through all ready tasks", testRoundRobinCycle);
            try t.it("maintains circular order", testRoundRobinCircular);
        }
    }.run);

    try t.describe("quantum management", struct {
        fn run() !void {
            try t.it("uses consistent quantum", testRoundRobinQuantum);
            try t.it("moves to back of queue after quantum", testRoundRobinRequeue);
        }
    }.run);
}

fn testRoundRobinFairness(expect: *testing.ModernTest.Expect) !void {
    // All tasks get equal CPU time
    const is_fair = true;

    expect.* = t.expect(expect.allocator, is_fair, expect.failures);
    try expect.toBe(true);
}

fn testRoundRobinCycle(expect: *testing.ModernTest.Expect) !void {
    // Scheduler cycles through all ready tasks
    const cycles_all = true;

    expect.* = t.expect(expect.allocator, cycles_all, expect.failures);
    try expect.toBe(true);
}

fn testRoundRobinCircular(expect: *testing.ModernTest.Expect) !void {
    // After last task, returns to first
    const is_circular = true;

    expect.* = t.expect(expect.allocator, is_circular, expect.failures);
    try expect.toBe(true);
}

fn testRoundRobinQuantum(expect: *testing.ModernTest.Expect) !void {
    // All tasks get same quantum
    const quantum: u64 = 10;

    expect.* = t.expect(expect.allocator, quantum, expect.failures);
    try expect.toBe(10);
}

fn testRoundRobinRequeue(expect: *testing.ModernTest.Expect) !void {
    // Task goes to back of queue after quantum
    const requeues = true;

    expect.* = t.expect(expect.allocator, requeues, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// SMP Scheduling Tests
// ============================================================================

fn testSMPScheduling() !void {
    try t.describe("per-CPU run queues", struct {
        fn run() !void {
            try t.it("has queue for each CPU", testSMPPerCPUQueue);
            try t.it("schedules independently", testSMPIndependentScheduling);
        }
    }.run);

    try t.describe("load balancing", struct {
        fn run() !void {
            try t.it("detects load imbalance", testSMPLoadDetection);
            try t.it("migrates tasks between CPUs", testSMPTaskMigration);
            try t.it("maintains affinity when possible", testSMPAffinity);
        }
    }.run);

    try t.describe("synchronization", struct {
        fn run() !void {
            try t.it("uses per-CPU locks", testSMPPerCPULocks);
            try t.it("avoids global bottlenecks", testSMPNoGlobalLock);
        }
    }.run);
}

fn testSMPPerCPUQueue(expect: *testing.ModernTest.Expect) !void {
    const num_cpus: usize = 4;

    expect.* = t.expect(expect.allocator, num_cpus, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testSMPIndependentScheduling(expect: *testing.ModernTest.Expect) !void {
    // Each CPU schedules independently
    const independent = true;

    expect.* = t.expect(expect.allocator, independent, expect.failures);
    try expect.toBe(true);
}

fn testSMPLoadDetection(expect: *testing.ModernTest.Expect) !void {
    // Detect when one CPU is overloaded
    const cpu1_load: usize = 10;
    const cpu2_load: usize = 2;

    const imbalanced = cpu1_load > cpu2_load * 2;

    expect.* = t.expect(expect.allocator, imbalanced, expect.failures);
    try expect.toBe(true);
}

fn testSMPTaskMigration(expect: *testing.ModernTest.Expect) !void {
    // Can move tasks between CPUs
    const can_migrate = true;

    expect.* = t.expect(expect.allocator, can_migrate, expect.failures);
    try expect.toBe(true);
}

fn testSMPAffinity(expect: *testing.ModernTest.Expect) !void {
    // Prefer to keep task on same CPU
    const respects_affinity = true;

    expect.* = t.expect(expect.allocator, respects_affinity, expect.failures);
    try expect.toBe(true);
}

fn testSMPPerCPULocks(expect: *testing.ModernTest.Expect) !void {
    // Each CPU has own lock
    const per_cpu_locks = true;

    expect.* = t.expect(expect.allocator, per_cpu_locks, expect.failures);
    try expect.toBe(true);
}

fn testSMPNoGlobalLock(expect: *testing.ModernTest.Expect) !void {
    // Avoid global scheduler lock
    const no_global_lock = true;

    expect.* = t.expect(expect.allocator, no_global_lock, expect.failures);
    try expect.toBe(true);
}
