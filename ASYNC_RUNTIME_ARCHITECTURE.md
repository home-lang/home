# Async Runtime Architecture

## Overview

This document describes the comprehensive async/await runtime implementation for the Home language. The design is inspired by Tokio (Rust), async-std, and Go's runtime, adapted for Home's ownership and type system.

## Goals

1. **Zero-cost Abstraction**: Async should compile to efficient state machines with no runtime overhead
2. **Work-Stealing Scheduler**: Efficient multi-threaded task execution with load balancing
3. **I/O Integration**: Native OS event loop integration (epoll/kqueue/IOCP)
4. **Composability**: Easy to compose async operations with combinators
5. **Error Propagation**: Seamless integration with Result<T, E> types
6. **Cancellation**: Support for task cancellation and timeouts
7. **Fair Scheduling**: Prevent task starvation

## Architecture Components

###  1. Core Abstractions

#### Future Trait
```zig
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Poll function signature
        pub const PollFn = *const fn (*Self, *Context) PollResult(T);

        poll_fn: PollFn,
        state: *anyopaque,  // State machine state

        pub fn poll(self: *Self, ctx: *Context) PollResult(T) {
            return self.poll_fn(self, ctx);
        }
    };
}

pub fn PollResult(comptime T: type) type {
    return union(enum) {
        Ready: T,
        Pending: void,
    };
}
```

#### Context
```zig
pub const Context = struct {
    waker: Waker,
    executor_data: *anyopaque,

    pub fn wake(self: *Context) void {
        self.waker.wake();
    }
};
```

#### Waker
```zig
pub const Waker = struct {
    vtable: *const WakerVTable,
    data: *anyopaque,

    pub const WakerVTable = struct {
        wake: *const fn (*anyopaque) void,
        wake_by_ref: *const fn (*anyopaque) void,
        clone: *const fn (*anyopaque) *anyopaque,
        drop: *const fn (*anyopaque) void,
    };

    pub fn wake(self: Waker) void {
        self.vtable.wake(self.data);
    }

    pub fn wakeByRef(self: *const Waker) void {
        self.vtable.wake_by_ref(self.data);
    }
};
```

### 2. Task Scheduler

#### Work-Stealing Queue
```
┌─────────────────────────────────────────────────────────┐
│                   Runtime (Global)                       │
│                                                          │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐        │
│  │  Worker 0  │  │  Worker 1  │  │  Worker 2  │  ...   │
│  │            │  │            │  │            │        │
│  │ Local Queue│  │ Local Queue│  │ Local Queue│        │
│  │  [Tasks]   │  │  [Tasks]   │  │  [Tasks]   │        │
│  │            │  │            │  │            │        │
│  │  Thread 0  │  │  Thread 1  │  │  Thread 2  │        │
│  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘        │
│        │                │                │               │
│        └────────────────┼────────────────┘               │
│                         │                                │
│                   Global Queue                           │
│                   [Tasks]                                │
│                                                          │
│                   I/O Reactor                            │
│                   (Poller Thread)                        │
└─────────────────────────────────────────────────────────┘
```

**Key Properties:**
- Each worker thread has a local FIFO queue
- Workers steal from other workers when idle (LIFO from victims)
- Global queue for tasks spawned from non-worker threads
- Lock-free when possible using atomic operations

#### Worker Thread
```zig
pub const Worker = struct {
    id: usize,
    local_queue: Deque(Task),
    runtime: *Runtime,
    thread: std.Thread,
    parker: Parker,  // For sleeping when idle

    /// Main worker loop
    fn run(self: *Worker) void {
        while (!self.runtime.shutdown.load(.Acquire)) {
            if (self.findTask()) |task| {
                self.runTask(task);
            } else {
                // No work, try to steal
                if (self.steal()) |task| {
                    self.runTask(task);
                } else {
                    // No work available, park
                    self.parker.park();
                }
            }
        }
    }

    fn findTask(self: *Worker) ?*Task {
        // Try local queue first
        if (self.local_queue.pop()) |task| return task;

        // Try global queue
        if (self.runtime.global_queue.pop()) |task| return task;

        return null;
    }

    fn steal(self: *Worker) ?*Task {
        // Try to steal from other workers
        for (self.runtime.workers) |*victim| {
            if (victim.id == self.id) continue;

            if (victim.local_queue.steal()) |task| {
                return task;
            }
        }
        return null;
    }
};
```

### 3. I/O Reactor

Platform-specific I/O event loop:

#### Linux (epoll)
```zig
pub const Reactor = struct {
    epoll_fd: i32,
    events: []std.os.linux.epoll_event,
    registry: std.AutoHashMap(i32, *Waker),

    pub fn poll(self: *Reactor, timeout: ?i64) !usize {
        const n = std.os.linux.epoll_wait(
            self.epoll_fd,
            self.events.ptr,
            @intCast(self.events.len),
            timeout orelse -1,
        );

        for (self.events[0..n]) |event| {
            const fd = @as(i32, @intCast(event.data.fd));
            if (self.registry.get(fd)) |waker| {
                waker.wake();
            }
        }

        return @intCast(n);
    }

    pub fn register(self: *Reactor, fd: i32, interest: Interest, waker: *Waker) !void {
        var event = std.os.linux.epoll_event{
            .events = interestToEpollEvents(interest),
            .data = .{ .fd = @intCast(fd) },
        };

        try std.os.linux.epoll_ctl(
            self.epoll_fd,
            std.os.linux.EPOLL.CTL_ADD,
            fd,
            &event,
        );

        try self.registry.put(fd, waker);
    }
};
```

#### macOS/BSD (kqueue)
```zig
pub const Reactor = struct {
    kq: i32,
    events: []std.os.Kevent,
    registry: std.AutoHashMap(i32, *Waker),

    pub fn poll(self: *Reactor, timeout: ?i64) !usize {
        const timespec = if (timeout) |t| std.os.timespec{
            .tv_sec = @divFloor(t, std.time.ns_per_s),
            .tv_nsec = @mod(t, std.time.ns_per_s),
        } else null;

        const n = std.os.kevent(
            self.kq,
            &[_]std.os.Kevent{},  // No changes
            self.events,
            if (timespec) |*ts| ts else null,
        ) catch |err| return err;

        for (self.events[0..n]) |event| {
            const fd = @as(i32, @intCast(event.ident));
            if (self.registry.get(fd)) |waker| {
                waker.wake();
            }
        }

        return n;
    }
};
```

#### Windows (IOCP)
```zig
pub const Reactor = struct {
    iocp_handle: windows.HANDLE,
    entries: []windows.OVERLAPPED_ENTRY,
    registry: std.AutoHashMap(usize, *Waker),

    pub fn poll(self: *Reactor, timeout: ?u32) !usize {
        var num_entries: u32 = 0;

        const result = windows.kernel32.GetQueuedCompletionStatusEx(
            self.iocp_handle,
            self.entries.ptr,
            @intCast(self.entries.len),
            &num_entries,
            timeout orelse windows.INFINITE,
            windows.FALSE,
        );

        if (result == 0) return error.IOCPError;

        for (self.entries[0..num_entries]) |entry| {
            const key = @as(usize, entry.lpCompletionKey);
            if (self.registry.get(key)) |waker| {
                waker.wake();
            }
        }

        return num_entries;
    }
};
```

### 4. Async State Machine Transformation

#### Source Code
```home
async fn fetch_data(url: string) -> Result<Data, Error> {
    let response = await http_get(url)?;
    let data = await response.json()?;
    return Ok(data);
}
```

#### Generated State Machine
```zig
const FetchDataStateMachine = struct {
    state: enum {
        Start,
        AwaitingHttpGet,
        AwaitingJson,
        Done,
    },
    url: []const u8,
    response: ?HttpResponse,
    data: ?Data,
    http_get_future: ?Future(Result(HttpResponse, Error)),
    json_future: ?Future(Result(Data, Error)),

    pub fn poll(self: *@This(), ctx: *Context) PollResult(Result(Data, Error)) {
        while (true) {
            switch (self.state) {
                .Start => {
                    // Start HTTP GET
                    self.http_get_future = http_get(self.url);
                    self.state = .AwaitingHttpGet;
                },
                .AwaitingHttpGet => {
                    const result = self.http_get_future.?.poll(ctx);
                    switch (result) {
                        .Ready => |res| {
                            switch (res) {
                                .Ok => |response| {
                                    self.response = response;
                                    self.json_future = response.json();
                                    self.state = .AwaitingJson;
                                },
                                .Err => |err| {
                                    self.state = .Done;
                                    return .{ .Ready = .{ .Err = err } };
                                },
                            }
                        },
                        .Pending => return .Pending,
                    }
                },
                .AwaitingJson => {
                    const result = self.json_future.?.poll(ctx);
                    switch (result) {
                        .Ready => |res| {
                            self.state = .Done;
                            return .{ .Ready = res };
                        },
                        .Pending => return .Pending,
                    }
                },
                .Done => unreachable,
            }
        }
    }
};
```

### 5. Async Primitives

#### Channel (MPMC)
```zig
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        queue: ConcurrentQueue(T),
        senders: std.ArrayList(*Waker),
        receivers: std.ArrayList(*Waker),
        closed: std.atomic.Atomic(bool),

        pub fn send(self: *Self, value: T) Future(Result(void, SendError)) {
            return SendFuture(T){ .channel = self, .value = value };
        }

        pub fn recv(self: *Self) Future(Result(T, RecvError)) {
            return RecvFuture(T){ .channel = self };
        }
    };
}
```

#### Mutex
```zig
pub fn Mutex(comptime T: type) type {
    return struct {
        const Self = @This();

        inner: T,
        locked: std.atomic.Atomic(bool),
        waiters: std.ArrayList(*Waker),

        pub fn lock(self: *Self) Future(*MutexGuard(T)) {
            return LockFuture(T){ .mutex = self };
        }
    };
}
```

#### Select (multi-future select)
```zig
pub fn select(futures: anytype) Future(SelectResult) {
    return SelectFuture{
        .futures = futures,
        .ready_index = null,
    };
}
```

### 6. Timer Infrastructure

```zig
pub const TimerWheel = struct {
    wheels: [4][]TimerBucket,  // Different granularities
    current_tick: u64,

    /// Hierarchical timing wheels:
    /// - Wheel 0: 256 slots, 1ms per slot (0-256ms)
    /// - Wheel 1: 256 slots, 256ms per slot (256ms-65s)
    /// - Wheel 2: 256 slots, 65s per slot (65s-4.6h)
    /// - Wheel 3: 256 slots, 4.6h per slot (4.6h-49 days)

    pub fn schedule(self: *TimerWheel, delay: u64, waker: *Waker) void {
        const ticks = delay / self.tick_duration;
        const wheel_idx = self.selectWheel(ticks);
        const slot = self.calculateSlot(wheel_idx, ticks);

        self.wheels[wheel_idx][slot].add(waker);
    }

    pub fn advance(self: *TimerWheel) void {
        self.current_tick += 1;

        // Check each wheel
        for (self.wheels, 0..) |wheel, idx| {
            if (self.shouldAdvanceWheel(idx)) {
                const slot = self.current_tick % wheel.len;
                for (wheel[slot].wakers.items) |waker| {
                    waker.wake();
                }
                wheel[slot].clear();
            }
        }
    }
};

pub fn sleep(duration_ns: u64) Future(void) {
    return SleepFuture{ .duration = duration_ns, .registered = false };
}

pub fn timeout(comptime T: type, duration: u64, future: Future(T)) Future(Result(T, TimeoutError)) {
    return TimeoutFuture(T){
        .inner = future,
        .deadline = duration,
        .timer_registered: false,
    };
}
```

### 7. Runtime API

```zig
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    global_queue: ConcurrentQueue(*Task),
    reactor: Reactor,
    timer_wheel: TimerWheel,
    shutdown: std.atomic.Atomic(bool),

    /// Create a new runtime with N worker threads
    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !Runtime {
        var runtime = Runtime{
            .allocator = allocator,
            .workers = try allocator.alloc(Worker, num_workers),
            .global_queue = ConcurrentQueue(*Task).init(allocator),
            .reactor = try Reactor.init(allocator),
            .timer_wheel = TimerWheel.init(allocator),
            .shutdown = std.atomic.Atomic(bool).init(false),
        };

        // Initialize workers
        for (runtime.workers, 0..) |*worker, i| {
            worker.* = try Worker.init(i, &runtime);
        }

        return runtime;
    }

    /// Spawn a new task
    pub fn spawn(self: *Runtime, comptime T: type, future: Future(T)) !JoinHandle(T) {
        const task = try Task.init(self.allocator, T, future);

        // Try to push to current worker's local queue
        if (getCurrentWorker()) |worker| {
            worker.local_queue.push(task);
            return JoinHandle(T){ .task = task };
        }

        // Otherwise, push to global queue
        try self.global_queue.push(task);

        // Wake a worker if any are parked
        self.unpark_one();

        return JoinHandle(T){ .task = task };
    }

    /// Block on a future until completion
    pub fn block_on(self: *Runtime, comptime T: type, future: Future(T)) !T {
        const handle = try self.spawn(T, future);
        return try handle.await();
    }

    /// Run the runtime until all tasks complete
    pub fn run(self: *Runtime) !void {
        // Start worker threads
        for (self.workers) |*worker| {
            try worker.start();
        }

        // Start reactor thread
        const reactor_thread = try std.Thread.spawn(.{}, Reactor.run, .{&self.reactor});

        // Start timer thread
        const timer_thread = try std.Thread.spawn(.{}, TimerWheel.run, .{&self.timer_wheel});

        // Wait for all workers to finish
        for (self.workers) |*worker| {
            worker.thread.join();
        }

        reactor_thread.join();
        timer_thread.join();
    }

    /// Shutdown the runtime
    pub fn shutdown(self: *Runtime) void {
        self.shutdown.store(true, .Release);

        // Unpark all workers
        for (self.workers) |*worker| {
            worker.parker.unpark();
        }
    }
};
```

### 8. Error Propagation

#### Result Integration
```zig
pub fn Future(comptime T: type) type {
    return struct {
        // ... existing Future implementation

        /// Map the success value
        pub fn map(self: *Self, comptime U: type, f: *const fn (T) U) Future(U) {
            return MapFuture(T, U){ .inner = self, .f = f };
        }

        /// Map the error value (for Result futures)
        pub fn mapErr(self: *Self, comptime T2: type, comptime E: type, comptime E2: type, f: *const fn (E) E2) Future(Result(T2, E2)) {
            return MapErrFuture(T2, E, E2){ .inner = self, .f = f };
        }

        /// Chain futures (flatMap/andThen)
        pub fn andThen(self: *Self, comptime U: type, f: *const fn (T) Future(U)) Future(U) {
            return AndThenFuture(T, U){ .inner = self, .f = f };
        }
    };
}
```

#### ? Operator Support
```home
async fn complex_operation() -> Result<Data, Error> {
    let step1 = await fetch_data()?;       // Short-circuit on error
    let step2 = await process_data(step1)?; // Chain operations
    let step3 = await save_data(step2)?;
    return Ok(step3);
}
```

Compiles to:
```zig
// State machine with error handling at each await point
switch (result) {
    .Ready => |res| switch (res) {
        .Ok => |value| { /* continue */ },
        .Err => |err| return .{ .Ready = .{ .Err = err } },
    },
    .Pending => return .Pending,
}
```

## Performance Characteristics

### Time Complexity
- Task spawn: O(1) amortized (push to local queue)
- Task poll: O(1) per poll
- Work stealing: O(N) where N = number of workers (typically small)
- I/O registration: O(log K) where K = number of registered FDs
- Timer scheduling: O(1) with hierarchical timer wheels

### Space Complexity
- Per task: ~200 bytes (state machine + metadata)
- Per worker: ~64KB (local queue)
- Global queue: Unbounded (can be configured)
- Reactor: O(K) where K = registered FDs
- Timer wheel: Fixed size (4 * 256 * pointer size)

### Scalability
- Linear scaling with CPU cores for CPU-bound tasks
- Efficient handling of 100K+ concurrent I/O operations
- Low latency (<1ms) for task scheduling
- Fair scheduling prevents starvation

## Safety Guarantees

1. **Memory Safety**: All async operations respect ownership rules
2. **Data Race Freedom**: Wakers are Send+Sync, proper synchronization
3. **Cancellation Safety**: Tasks can be safely cancelled
4. **Resource Cleanup**: RAII ensures resources released on task drop
5. **No Undefined Behavior**: All state machines type-safe

## Example Usage

### Simple Async Function
```home
async fn hello() -> string {
    await sleep(Duration.seconds(1));
    return "Hello, async!";
}

fn main() {
    let runtime = Runtime.new();
    let result = runtime.block_on(hello());
    print(result);  // "Hello, async!"
}
```

### Concurrent HTTP Requests
```home
async fn fetch_all(urls: []string) -> Result<[]Data, Error> {
    let mut futures = [];

    for url in urls {
        futures.push(http_get(url));
    }

    let results = await join_all(futures);
    return Ok(results);
}
```

### Channel Communication
```home
async fn producer(tx: Sender<i32>) {
    for i in 0..10 {
        await tx.send(i)?;
        await sleep(Duration.millis(100));
    }
}

async fn consumer(rx: Receiver<i32>) {
    while let Ok(value) = await rx.recv() {
        print("Received: {value}");
    }
}

fn main() {
    let runtime = Runtime.new();
    let (tx, rx) = channel();

    runtime.spawn(producer(tx));
    runtime.spawn(consumer(rx));

    runtime.run();
}
```

### Timeout and Select
```home
async fn with_timeout() -> Result<Data, Error> {
    let future = fetch_data("https://api.example.com");

    match await timeout(Duration.seconds(5), future) {
        Ok(data) => Ok(data),
        Err(TimeoutError) => Err(Error.Timeout),
    }
}

async fn first_to_complete() -> Result<Data, Error> {
    let future1 = fetch_from_primary();
    let future2 = fetch_from_backup();

    // Return whichever completes first
    return await select! {
        result = future1 => result,
        result = future2 => result,
    };
}
```

## Implementation Phases

### Phase 1: Core Infrastructure (Week 1)
- [ ] Enhanced Future trait with PollResult
- [ ] Context and Waker implementation
- [ ] Basic task representation
- [ ] Simple executor (single-threaded)

### Phase 2: Work-Stealing Scheduler (Week 1-2)
- [ ] Concurrent queue implementation
- [ ] Worker threads
- [ ] Work-stealing algorithm
- [ ] Parker/Unparker for thread parking

### Phase 3: I/O Reactor (Week 2)
- [ ] Platform detection
- [ ] epoll implementation (Linux)
- [ ] kqueue implementation (macOS/BSD)
- [ ] IOCP implementation (Windows)
- [ ] Unified I/O interface

### Phase 4: State Machine Generation (Week 2-3)
- [ ] Async function analysis in parser
- [ ] State extraction from await points
- [ ] State machine code generation
- [ ] Integration with codegen

### Phase 5: Async Primitives (Week 3)
- [ ] Channel (MPMC, SPSC variants)
- [ ] Mutex and RwLock
- [ ] Semaphore
- [ ] Select macro/primitive
- [ ] Once cell

### Phase 6: Timer System (Week 3)
- [ ] Hierarchical timer wheel
- [ ] Sleep function
- [ ] Timeout combinator
- [ ] Interval/periodic timers

### Phase 7: Testing and Examples (Week 4)
- [ ] Unit tests for all components
- [ ] Integration tests
- [ ] Benchmark suite
- [ ] Example applications
- [ ] Documentation

## References

- Tokio Runtime Design: https://tokio.rs/blog/2019-10-scheduler
- Work-Stealing Paper: "Dynamic Circular Work-Stealing Deque" by Chase and Lev
- Timer Wheels: "Hashed and Hierarchical Timing Wheels" by Varghese and Lauck
- Async/Await Transformation: Rust RFC 2394
- Go Scheduler: https://golang.org/s/go11sched
