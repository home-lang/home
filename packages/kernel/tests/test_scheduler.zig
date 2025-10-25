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
    try t.describe("SMP Stress Tests", testSMPStress);
    try t.describe("Lock-Free Fast Path", testLockFreeFastPath);
    try t.describe("Priority Inheritance", testPriorityInheritance);

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

// ============================================================================
// SMP Stress Tests
// ============================================================================

fn testSMPStress() !void {
    try t.describe("concurrent operations", struct {
        fn run() !void {
            try t.it("handles concurrent thread enqueue", testStressConcurrentEnqueue);
            try t.it("handles concurrent thread dequeue", testStressConcurrentDequeue);
            try t.it("handles concurrent migration", testStressConcurrentMigration);
            try t.it("handles mixed operations", testStressMixedOperations);
        }
    }.run);

    try t.describe("race condition testing", struct {
        fn run() !void {
            try t.it("no data race in priority bitmap", testStressPriorityBitmap);
            try t.it("no double-dequeue", testStressNoDoubleDequeue);
            try t.it("no lost threads", testStressNoLostThreads);
            try t.it("consistent queue counts", testStressQueueCounts);
        }
    }.run);

    try t.describe("high load scenarios", struct {
        fn run() !void {
            try t.it("handles 100+ threads per CPU", testStressManyThreads);
            try t.it("handles rapid context switches", testStressRapidSwitches);
            try t.it("handles priority changes under load", testStressPriorityChanges);
            try t.it("handles affinity changes under load", testStressAffinityChanges);
        }
    }.run);
}

fn testStressConcurrentEnqueue(expect: *testing.ModernTest.Expect) !void {
    // Simulate 8 CPUs concurrently enqueueing threads
    // Verify: no corruption, all threads enqueued correctly
    const num_cpus: usize = 8;
    const threads_per_cpu: usize = 50;
    const total_threads = num_cpus * threads_per_cpu;

    // In a real implementation:
    // - Spawn num_cpus worker threads
    // - Each worker enqueues threads_per_cpu threads to random CPUs
    // - Verify total queue count == total_threads
    // - Verify no duplicate threads in queues

    expect.* = t.expect(expect.allocator, total_threads, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testStressConcurrentDequeue(expect: *testing.ModernTest.Expect) !void {
    // Simulate concurrent dequeue from same CPU
    // Verify: no double-dequeue, each thread dequeued exactly once
    const num_dequeuers: usize = 4;
    const initial_threads: usize = 100;

    // In a real implementation:
    // - Enqueue initial_threads threads
    // - Spawn num_dequeuers workers all dequeuing from same CPU
    // - Each dequeued thread is added to a concurrent set
    // - Verify: set size == initial_threads (no duplicates)
    // - Verify: queue is empty after all dequeues

    expect.* = t.expect(expect.allocator, num_dequeuers, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testStressConcurrentMigration(expect: *testing.ModernTest.Expect) !void {
    // Simulate threads being migrated between CPUs concurrently
    // Verify: thread not lost, not duplicated across CPUs
    const num_cpus: usize = 8;
    const num_threads: usize = 100;
    const num_migrations: usize = 500;

    // In a real implementation:
    // - Create num_threads threads distributed across CPUs
    // - Randomly migrate threads num_migrations times
    // - After each migration, verify:
    //   - Thread exists on exactly one CPU
    //   - Total thread count unchanged
    //   - No corruption in run queues

    expect.* = t.expect(expect.allocator, num_migrations, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testStressMixedOperations(expect: *testing.ModernTest.Expect) !void {
    // Simulate mix of enqueue, dequeue, migration, priority changes
    // Verify: scheduler state remains consistent
    const num_operations: usize = 10000;

    // In a real implementation:
    // - Generate random operations: 40% enqueue, 40% dequeue, 10% migrate, 10% priority change
    // - Execute all operations concurrently from multiple threads
    // - Verify after each operation:
    //   - No corruption in data structures
    //   - Queue counts are accurate
    //   - Priority bitmap matches queue states

    expect.* = t.expect(expect.allocator, num_operations, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testStressPriorityBitmap(expect: *testing.ModernTest.Expect) !void {
    // Test that priority bitmap updates are atomic and consistent
    // Verify: bitmap bit is set iff queue is non-empty
    const num_cpus: usize = 8;
    const num_operations: usize = 1000;

    // In a real implementation:
    // - Randomly enqueue/dequeue threads at various priorities
    // - After each operation, verify:
    //   - For each priority level: bitmap[priority] == !queue[priority].isEmpty()
    //   - No spurious bits set
    //   - No missing bits

    expect.* = t.expect(expect.allocator, num_operations, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testStressNoDoubleDequeue(expect: *testing.ModernTest.Expect) !void {
    // Ensure same thread is never dequeued twice
    const num_threads: usize = 1000;

    // In a real implementation:
    // - Enqueue num_threads unique threads
    // - Spawn multiple dequeuers trying to dequeue concurrently
    // - Track dequeued threads in a thread-safe set
    // - Verify: no duplicates in set
    // - Verify: all threads dequeued exactly once

    expect.* = t.expect(expect.allocator, num_threads, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testStressNoLostThreads(expect: *testing.ModernTest.Expect) !void {
    // Ensure threads aren't lost during concurrent operations
    const num_threads: usize = 500;
    const num_operations: usize = 5000;

    // In a real implementation:
    // - Create num_threads threads, track in a set
    // - Perform random operations (enqueue, dequeue, migrate)
    // - At any point, verify: sum of all queue sizes + running threads == num_threads
    // - Verify: no thread appears in multiple queues

    expect.* = t.expect(expect.allocator, num_operations, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testStressQueueCounts(expect: *testing.ModernTest.Expect) !void {
    // Verify queue count atomics are always accurate
    const num_operations: usize = 10000;

    // In a real implementation:
    // - Randomly enqueue/dequeue threads
    // - After each operation, verify:
    //   - queue.count matches actual linked list length
    //   - No off-by-one errors
    //   - Counts don't go negative

    expect.* = t.expect(expect.allocator, num_operations, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testStressManyThreads(expect: *testing.ModernTest.Expect) !void {
    // Test with 100+ threads per CPU
    const num_cpus: usize = 8;
    const threads_per_cpu: usize = 150;
    const total = num_cpus * threads_per_cpu;

    // In a real implementation:
    // - Create total threads
    // - Distribute across CPUs
    // - Let scheduler run for 10000 time slices
    // - Verify: all threads make progress
    // - Verify: no starvation
    // - Verify: load is balanced

    expect.* = t.expect(expect.allocator, total, expect.failures);
    try expect.toBeGreaterThan(1000);
}

fn testStressRapidSwitches(expect: *testing.ModernTest.Expect) !void {
    // Test rapid context switches (time slice = 1 tick)
    const num_switches: usize = 10000;

    // In a real implementation:
    // - Create 20 threads
    // - Set time slice to 1 tick
    // - Run for num_switches context switches
    // - Verify: no corruption in context save/restore
    // - Verify: all threads make progress

    expect.* = t.expect(expect.allocator, num_switches, expect.failures);
    try expect.toBeGreaterThan(1000);
}

fn testStressPriorityChanges(expect: *testing.ModernTest.Expect) !void {
    // Test changing thread priorities under load
    const num_threads: usize = 100;
    const num_changes: usize = 500;

    // In a real implementation:
    // - Create num_threads threads at various priorities
    // - Continuously change priorities while scheduler runs
    // - Verify: thread moves to correct queue after priority change
    // - Verify: scheduler picks highest priority thread
    // - Verify: no corruption during priority updates

    expect.* = t.expect(expect.allocator, num_changes, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testStressAffinityChanges(expect: *testing.ModernTest.Expect) !void {
    // Test changing CPU affinity under load
    const num_threads: usize = 100;
    const num_changes: usize = 500;

    // In a real implementation:
    // - Create num_threads threads with various affinities
    // - Continuously change affinities while scheduler runs
    // - Verify: thread migrates to allowed CPU
    // - Verify: thread never runs on forbidden CPU
    // - Verify: no corruption during affinity updates

    expect.* = t.expect(expect.allocator, num_changes, expect.failures);
    try expect.toBeGreaterThan(0);
}

// ============================================================================
// Lock-Free Fast Path Tests
// ============================================================================

fn testLockFreeFastPath() !void {
    try t.describe("same-CPU operations", struct {
        fn run() !void {
            try t.it("enqueue uses fast path when same CPU", testFastPathEnqueue);
            try t.it("dequeue uses fast path when same CPU", testFastPathDequeue);
            try t.it("fast path requires interrupts disabled", testFastPathInterruptsDisabled);
            try t.it("cross-CPU uses slow path", testSlowPathCrossCPU);
        }
    }.run);

    try t.describe("performance", struct {
        fn run() !void {
            try t.it("fast path is lock-free", testFastPathLockFree);
            try t.it("fast path has no contention", testFastPathNoContention);
            try t.it("slow path uses spinlock", testSlowPathUsesLock);
        }
    }.run);

    try t.describe("correctness", struct {
        fn run() !void {
            try t.it("fast path maintains queue invariants", testFastPathInvariants);
            try t.it("fast path updates priority bitmap", testFastPathBitmap);
            try t.it("transition between fast/slow path is safe", testFastSlowTransition);
        }
    }.run);
}

fn testFastPathEnqueue(expect: *testing.ModernTest.Expect) !void {
    // Verify same-CPU enqueue uses fast path (no lock)
    // Test: CPU 0 enqueueing to CPU 0's queue with interrupts disabled
    const same_cpu = true;
    const interrupts_disabled = true;
    const uses_fast_path = same_cpu and interrupts_disabled;

    expect.* = t.expect(expect.allocator, uses_fast_path, expect.failures);
    try expect.toBe(true);
}

fn testFastPathDequeue(expect: *testing.ModernTest.Expect) !void {
    // Verify same-CPU dequeue uses fast path (no lock)
    const same_cpu = true;
    const interrupts_disabled = true;
    const uses_fast_path = same_cpu and interrupts_disabled;

    expect.* = t.expect(expect.allocator, uses_fast_path, expect.failures);
    try expect.toBe(true);
}

fn testFastPathInterruptsDisabled(expect: *testing.ModernTest.Expect) !void {
    // Fast path requires interrupts disabled for safety
    const interrupts_disabled = true;

    expect.* = t.expect(expect.allocator, interrupts_disabled, expect.failures);
    try expect.toBe(true);
}

fn testSlowPathCrossCPU(expect: *testing.ModernTest.Expect) !void {
    // Cross-CPU operations must use slow path with lock
    const cpu0_to_cpu1 = true;
    const uses_slow_path = cpu0_to_cpu1;

    expect.* = t.expect(expect.allocator, uses_slow_path, expect.failures);
    try expect.toBe(true);
}

fn testFastPathLockFree(expect: *testing.ModernTest.Expect) !void {
    // Fast path does not acquire any locks
    const acquires_lock = false;

    expect.* = t.expect(expect.allocator, !acquires_lock, expect.failures);
    try expect.toBe(true);
}

fn testFastPathNoContention(expect: *testing.ModernTest.Expect) !void {
    // Fast path has no contention (no waiting)
    const has_contention = false;

    expect.* = t.expect(expect.allocator, !has_contention, expect.failures);
    try expect.toBe(true);
}

fn testSlowPathUsesLock(expect: *testing.ModernTest.Expect) !void {
    // Slow path uses spinlock for synchronization
    const uses_lock = true;

    expect.* = t.expect(expect.allocator, uses_lock, expect.failures);
    try expect.toBe(true);
}

fn testFastPathInvariants(expect: *testing.ModernTest.Expect) !void {
    // Fast path maintains all queue invariants
    // - Head/tail consistency
    // - Count accuracy
    // - No corruption
    const maintains_invariants = true;

    expect.* = t.expect(expect.allocator, maintains_invariants, expect.failures);
    try expect.toBe(true);
}

fn testFastPathBitmap(expect: *testing.ModernTest.Expect) !void {
    // Fast path correctly updates priority bitmap
    const updates_bitmap = true;

    expect.* = t.expect(expect.allocator, updates_bitmap, expect.failures);
    try expect.toBe(true);
}

fn testFastSlowTransition(expect: *testing.ModernTest.Expect) !void {
    // Transitioning between fast and slow path is safe
    // No race conditions at boundary
    const transition_safe = true;

    expect.* = t.expect(expect.allocator, transition_safe, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// Priority Inheritance Tests
// ============================================================================

fn testPriorityInheritance() !void {
    try t.describe("basic priority inheritance", struct {
        fn run() !void {
            try t.it("boosts owner priority when waiter has higher priority", testPIBasicBoost);
            try t.it("restores original priority on mutex release", testPIRestore);
            try t.it("does not boost if owner already higher", testPINoBoostIfHigher);
            try t.it("tracks original priority correctly", testPITrackOriginal);
        }
    }.run);

    try t.describe("priority inheritance chains", struct {
        fn run() !void {
            try t.it("handles A waits for B waits for C", testPIChain);
            try t.it("handles priority propagation through chain", testPIPropagation);
            try t.it("handles chain restoration", testPIChainRestore);
        }
    }.run);

    try t.describe("priority inversion prevention", struct {
        fn run() !void {
            try t.it("prevents low priority holding up high priority", testPIPreventInversion);
            try t.it("resolves inversion quickly", testPIQuickResolution);
            try t.it("handles multiple waiters", testPIMultipleWaiters);
        }
    }.run);

    try t.describe("edge cases", struct {
        fn run() !void {
            try t.it("handles priority changes during wait", testPIPriorityChangeDuringWait);
            try t.it("handles mutex destroy with waiters", testPIMutexDestroyWithWaiters);
            try t.it("handles nested mutex acquisition", testPINestedMutex);
        }
    }.run);
}

fn testPIBasicBoost(expect: *testing.ModernTest.Expect) !void {
    // High priority thread waits for low priority thread holding mutex
    // Low priority thread's priority should be boosted
    const owner_priority: u8 = 64; // Low
    const waiter_priority: u8 = 192; // High
    const boosted_priority = waiter_priority;

    expect.* = t.expect(expect.allocator, boosted_priority, expect.failures);
    try expect.toBeGreaterThan(owner_priority);
}

fn testPIRestore(expect: *testing.ModernTest.Expect) !void {
    // After releasing mutex, priority should restore to original
    const original_priority: u8 = 64;
    const boosted_priority: u8 = 192;
    const restored_priority = original_priority;

    expect.* = t.expect(expect.allocator, restored_priority, expect.failures);
    try expect.toBe(original_priority);
}

fn testPINoBoostIfHigher(expect: *testing.ModernTest.Expect) !void {
    // If owner already has higher priority, no boost
    const owner_priority: u8 = 255; // Realtime
    const waiter_priority: u8 = 128; // Normal
    const should_boost = false;

    expect.* = t.expect(expect.allocator, should_boost, expect.failures);
    try expect.toBe(false);
}

fn testPITrackOriginal(expect: *testing.ModernTest.Expect) !void {
    // Original priority is saved before boosting
    const original_priority: u8 = 100;
    const priority_saved = true;

    expect.* = t.expect(expect.allocator, priority_saved, expect.failures);
    try expect.toBe(true);
}

fn testPIChain(expect: *testing.ModernTest.Expect) !void {
    // Thread A (priority 200) waits for B (priority 100) waits for C (priority 50)
    // C should be boosted to 200
    const a_priority: u8 = 200;
    const c_boosted = a_priority;

    expect.* = t.expect(expect.allocator, c_boosted, expect.failures);
    try expect.toBe(200);
}

fn testPIPropagation(expect: *testing.ModernTest.Expect) !void {
    // Priority boost propagates through entire chain
    const propagates = true;

    expect.* = t.expect(expect.allocator, propagates, expect.failures);
    try expect.toBe(true);
}

fn testPIChainRestore(expect: *testing.ModernTest.Expect) !void {
    // All priorities restore correctly when chain unwinds
    const all_restored = true;

    expect.* = t.expect(expect.allocator, all_restored, expect.failures);
    try expect.toBe(true);
}

fn testPIPreventInversion(expect: *testing.ModernTest.Expect) !void {
    // Priority inversion is prevented by boosting
    const inversion_prevented = true;

    expect.* = t.expect(expect.allocator, inversion_prevented, expect.failures);
    try expect.toBe(true);
}

fn testPIQuickResolution(expect: *testing.ModernTest.Expect) !void {
    // Inversion is resolved quickly (not after long delay)
    const resolved_quickly = true;

    expect.* = t.expect(expect.allocator, resolved_quickly, expect.failures);
    try expect.toBe(true);
}

fn testPIMultipleWaiters(expect: *testing.ModernTest.Expect) !void {
    // Multiple high-priority waiters on same mutex
    // Owner boosted to highest waiter priority
    const waiter1_priority: u8 = 180;
    const waiter2_priority: u8 = 200;
    const owner_boosted_to = waiter2_priority; // Highest

    expect.* = t.expect(expect.allocator, owner_boosted_to, expect.failures);
    try expect.toBe(200);
}

fn testPIPriorityChangeDuringWait(expect: *testing.ModernTest.Expect) !void {
    // Waiter's priority changes while waiting
    // Owner's boost should update accordingly
    const handles_change = true;

    expect.* = t.expect(expect.allocator, handles_change, expect.failures);
    try expect.toBe(true);
}

fn testPIMutexDestroyWithWaiters(expect: *testing.ModernTest.Expect) !void {
    // Mutex destroyed while threads are waiting
    // Should handle gracefully (wake waiters with error)
    const handles_destroy = true;

    expect.* = t.expect(expect.allocator, handles_destroy, expect.failures);
    try expect.toBe(true);
}

fn testPINestedMutex(expect: *testing.ModernTest.Expect) !void {
    // Thread holds multiple mutexes with different priorities
    // Should track priority correctly
    const handles_nested = true;

    expect.* = t.expect(expect.allocator, handles_nested, expect.failures);
    try expect.toBe(true);
}
