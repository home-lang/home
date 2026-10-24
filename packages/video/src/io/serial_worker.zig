//! Bounded, stable-address serial callback executor. Native Zig 0.15.2 host.
//! Payload owners remain in the caller until callback cleanup returns. A fence
//! means cleanup completion, not callback success or GPU/source retirement.
const std = @import("std");
const Admission = @import("../core/owned_admission.zig").Registry(64);
pub const Task = struct {
    function: *const fn (*anyopaque) void,
    context: *anyopaque,
};
pub const Snapshot = struct { issued: u64, completed: u64, outstanding: usize, queued: usize, active: bool, closed: bool, rejected: u64 };
const Entry = struct { task: Task, ticket: Admission.Ticket };
const State = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    changed: std.Thread.Condition = .{},
    entries: [64]Entry = undefined,
    head: usize = 0,
    count: usize = 0,
    active: bool = false,
    closed: bool = false,
    admission: Admission,
    thread: ?std.Thread = null,
    fn run(s: *State) void {
        running = s;
        defer running = null;
        s.mutex.lock();
        defer s.mutex.unlock();
        while (true) {
            // Predicate and sleep share one lock; submit cannot lose its wake.
            while (s.count == 0 and !s.closed) s.changed.wait(&s.mutex);
            if (s.count == 0) return;
            const entry = s.entries[s.head];
            s.head = (s.head + 1) % s.entries.len;
            s.count -= 1;
            s.active = true;
            s.mutex.unlock();
            entry.task.function(entry.task.context);
            s.mutex.lock();
            s.active = false;
            s.admission.release(entry.ticket) catch unreachable;
            s.changed.broadcast();
        }
    }
};
threadlocal var running: ?*State = null;
/// Move-only value handle: moving the handle never moves worker state. Serialize
/// deinit against other public calls; callback contexts must survive their fence.
pub const Worker = struct {
    state: ?*State,
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Worker {
        const admission = try Admission.init(capacity, capacity);
        const s = try allocator.create(State);
        errdefer allocator.destroy(s);
        s.* = .{ .allocator = allocator, .admission = admission };
        s.thread = try std.Thread.spawn(.{}, State.run, .{s});
        return .{ .state = s };
    }
    /// Nonblocking admission; capacity includes the executing callback. Failure
    /// leaves task ownership in the caller. Tickets never wrap or repeat.
    pub fn submit(w: *Worker, task: Task) !u64 {
        const s = w.state orelse return error.Closed;
        s.mutex.lock();
        defer s.mutex.unlock();
        if (s.closed) return error.Closed;
        const ticket = try s.admission.reserve(1);
        s.entries[(s.head + s.count) % s.entries.len] = .{ .task = task, .ticket = ticket };
        s.count += 1;
        s.changed.signal();
        return ticket.id;
    }
    pub fn snapshot(w: *Worker) !Snapshot {
        const s = w.state orelse return error.Closed;
        s.mutex.lock();
        defer s.mutex.unlock();
        return .{ .issued = s.admission.issued, .completed = s.admission.released, .outstanding = s.admission.count, .queued = s.count, .active = s.active, .closed = s.closed, .rejected = s.admission.rejected };
    }
    pub fn finished(w: *Worker, target: u64) !bool {
        const s = w.state orelse return error.Closed;
        s.mutex.lock();
        defer s.mutex.unlock();
        return !try s.admission.pendingThrough(target);
    }
    /// Waits through exactly target, including executing work. Later admissions
    /// do not extend the fence. Native wait; hosted event loops should poll.
    pub fn wait(w: *Worker, target: u64) !void {
        const s = w.state orelse return error.Closed;
        if (running == s) return error.WorkerCannotWait;
        s.mutex.lock();
        defer s.mutex.unlock();
        while (try s.admission.pendingThrough(target)) s.changed.wait(&s.mutex);
    }
    /// Stop admission and drain already accepted work, including active cleanup.
    pub fn closeAdmission(w: *Worker) void {
        const s = w.state orelse return;
        s.mutex.lock();
        defer s.mutex.unlock();
        s.closed = true;
        s.changed.broadcast();
    }
    pub fn deinit(w: *Worker) !void {
        const s = w.state orelse return;
        if (running == s) return error.WorkerCannotJoin;
        w.closeAdmission();
        s.thread.?.join();
        s.allocator.destroy(s);
        w.state = null;
    }
};

const Latch = struct {
    mutex: std.Thread.Mutex = .{},
    changed: std.Thread.Condition = .{},
    entered: bool = false,
    released: bool = false,
    cleaned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn run(p: *anyopaque) void {
        const l: *Latch = @ptrCast(@alignCast(p));
        l.mutex.lock();
        l.entered = true;
        l.changed.broadcast();
        while (!l.released) l.changed.wait(&l.mutex);
        l.mutex.unlock();
        l.cleaned.store(true, .release);
    }
    fn enteredWait(l: *Latch) void {
        l.mutex.lock();
        defer l.mutex.unlock();
        while (!l.entered) l.changed.wait(&l.mutex);
    }
    fn release(l: *Latch) void {
        l.mutex.lock();
        defer l.mutex.unlock();
        l.released = true;
        l.changed.broadcast();
    }
};
test "serial worker charges active ownership and fences cleanup without waiting for later work" {
    var worker = try Worker.init(std.testing.allocator, 2);
    defer worker.deinit() catch unreachable;
    var first: Latch = .{};
    var second: Latch = .{};
    defer {
        first.release();
        second.release();
    }
    const a = try worker.submit(.{ .function = Latch.run, .context = &first });
    first.enteredWait();
    const b = try worker.submit(.{ .function = Latch.run, .context = &second });
    try std.testing.expectError(error.BufferFull, worker.submit(.{ .function = Latch.run, .context = &second }));
    const pending = try worker.snapshot();
    try std.testing.expectEqual(@as(usize, 2), pending.outstanding);
    try std.testing.expectEqual(@as(usize, 1), pending.queued);
    try std.testing.expect(pending.active and !try worker.finished(a));
    try std.testing.expectError(error.InvalidTarget, worker.finished(b + 1));
    first.release();
    try worker.wait(a);
    second.enteredWait();
    try std.testing.expect(first.cleaned.load(.acquire));
    try std.testing.expect(try worker.finished(a));
    try std.testing.expect(!try worker.finished(b));
    worker.closeAdmission();
    try std.testing.expectError(error.Closed, worker.submit(.{ .function = Latch.run, .context = &first }));
    second.release();
    try worker.deinit();
    try std.testing.expect(second.cleaned.load(.acquire));
    try std.testing.expectError(error.Closed, worker.snapshot());
}
test "serial worker remains stable across value return and idle wake cycles" {
    const Context = struct {
        count: usize = 0,
        fn increment(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.count += 1;
        }
        fn create() !Worker {
            return Worker.init(std.testing.allocator, 1);
        }
    };
    var worker = try Context.create();
    defer worker.deinit() catch unreachable;
    var context: Context = .{};
    for (1..1001) |expected| {
        const ticket = try worker.submit(.{ .function = Context.increment, .context = &context });
        try worker.wait(ticket);
        try std.testing.expectEqual(expected, context.count);
    }
    const final = try worker.snapshot();
    try std.testing.expectEqual(@as(u64, 1000), final.completed);
    try std.testing.expectEqual(@as(usize, 0), final.outstanding);
}
test "serial callbacks cannot join their worker or wait on their own prefix" {
    const Context = struct {
        worker: *Worker,
        valid: bool = false,
        fn run(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            const target = (self.worker.snapshot() catch unreachable).issued;
            if (self.worker.wait(target)) |_| return else |err| if (err != error.WorkerCannotWait) return;
            if (self.worker.deinit()) |_| return else |err| if (err != error.WorkerCannotJoin) return;
            self.valid = true;
        }
    };
    var worker = try Worker.init(std.testing.allocator, 1);
    defer worker.deinit() catch unreachable;
    var context = Context{ .worker = &worker };
    try worker.wait(try worker.submit(.{ .function = Context.run, .context = &context }));
    try std.testing.expect(context.valid);
}
test "serial worker allocation failures leave no thread or state owner" {
    const Probe = struct {
        fn run(a: std.mem.Allocator) !void {
            var worker = try Worker.init(a, 1);
            try worker.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
    try std.testing.expectError(error.InvalidConfiguration, Worker.init(std.testing.allocator, 0));
    try std.testing.expectError(error.InvalidConfiguration, Worker.init(std.testing.allocator, 65));
}

test "closing admission drains queued owners and concurrent producer bursts lose no work" {
    const Producer = struct {
        worker: *Worker,
        counter: *std.atomic.Value(usize),
        fn count(p: *anyopaque) void {
            const counter: *std.atomic.Value(usize) = @ptrCast(@alignCast(p));
            _ = counter.fetchAdd(1, .monotonic);
        }
        fn run(p: *@This()) void {
            for (0..500) |_| {
                while (true) {
                    _ = p.worker.submit(.{ .function = count, .context = p.counter }) catch |err| {
                        if (err != error.BufferFull) unreachable;
                        std.Thread.yield() catch {};
                        continue;
                    };
                    break;
                }
            }
        }
    };
    var worker = try Worker.init(std.testing.allocator, 16);
    defer worker.deinit() catch unreachable;
    var counter = std.atomic.Value(usize).init(0);
    var producers: [4]Producer = undefined;
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&producers, &threads) |*producer, *thread| {
        producer.* = .{ .worker = &worker, .counter = &counter };
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    try worker.wait((try worker.snapshot()).issued);
    try std.testing.expectEqual(@as(usize, 2000), counter.load(.acquire));
    var gate: Latch = .{};
    defer gate.release();
    _ = try worker.submit(.{ .function = Latch.run, .context = &gate });
    gate.enteredWait();
    _ = try worker.submit(.{ .function = Producer.count, .context = &counter });
    worker.closeAdmission();
    gate.release();
    try worker.deinit();
    try std.testing.expectEqual(@as(usize, 2001), counter.load(.acquire));
}
