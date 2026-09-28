const std = @import("std");
const builtin = @import("builtin");
const threading = @import("threading");

const waiter_count = 8;
const blocked_ns = 250 * std.time.ns_per_ms;
const max_cpu_fraction = 20;

fn currentThreadCpuTimeNs() !u64 {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.UnsupportedPlatform;
    }

    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(.THREAD_CPUTIME_ID, &time) != 0) return error.CpuClockFailed;
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}

pub fn main() !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.UnsupportedPlatform;
    }

    var semaphore = try threading.Semaphore.init(0);
    defer semaphore.deinit();

    const Context = struct {
        semaphore: *threading.Semaphore,
        ready: std.atomic.Value(u32) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        cpu_ns: *[waiter_count]u64,

        fn waiter(context: *@This(), index: usize) void {
            const start = currentThreadCpuTimeNs() catch {
                context.failed.store(true, .release);
                _ = context.ready.fetchAdd(1, .release);
                return;
            };
            _ = context.ready.fetchAdd(1, .release);
            context.semaphore.wait() catch {
                context.failed.store(true, .release);
                return;
            };
            const end = currentThreadCpuTimeNs() catch {
                context.failed.store(true, .release);
                return;
            };
            context.cpu_ns[index] = end - start;
        }
    };

    var cpu_ns: [waiter_count]u64 = @splat(0);
    var context = Context{ .semaphore = &semaphore, .cpu_ns = &cpu_ns };
    var threads: [waiter_count]threading.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try threading.Thread.spawn(std.heap.page_allocator, Context.waiter, .{ &context, index });
    }

    while (context.ready.load(.acquire) != waiter_count) threading.Thread.yield();
    threading.Thread.sleep(blocked_ns);
    for (0..waiter_count) |_| try semaphore.post();
    for (threads) |thread| try thread.join();
    if (context.failed.load(.acquire)) return error.MeasurementFailed;

    var total_cpu_ns: u64 = 0;
    var max_cpu_ns: u64 = 0;
    for (cpu_ns) |cpu_time| {
        total_cpu_ns += cpu_time;
        max_cpu_ns = @max(max_cpu_ns, cpu_time);
    }

    const budget_ns = blocked_ns / max_cpu_fraction;
    std.debug.print(
        "blocked-waiter-cpu: waiters={d} block_ms={d} total_cpu_us={d} max_cpu_us={d} budget_us={d}\n",
        .{ waiter_count, blocked_ns / std.time.ns_per_ms, total_cpu_ns / std.time.ns_per_us, max_cpu_ns / std.time.ns_per_us, budget_ns / std.time.ns_per_us },
    );
    if (max_cpu_ns >= budget_ns) return error.BlockedWaiterConsumedCpu;
}
