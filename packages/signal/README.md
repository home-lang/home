# Signal Handling Package

Cross-platform signal handling with support for signal handlers, masking, and signal sets.

## Features

- **Signal Handling**: Register custom handlers for POSIX signals
- **Signal Masking**: Block and unblock signals
- **Signal Sets**: Manage groups of signals
- **Cross-platform**: Unix/Linux/macOS support (Windows has limited support)
- **Type-safe**: Strong typing for signal operations

## Usage

### Basic Signal Handling

```zig
const std = @import("std");
const signal = @import("signal");

// Define a signal handler
fn handleInterrupt(sig: signal.Signal) void {
    std.debug.print("Caught signal: {s}\n", .{sig.name()});
    // Cleanup and exit gracefully
}

pub fn main() !void {
    // Register handler for SIGINT (Ctrl+C)
    try signal.setHandler(.SIGINT, handleInterrupt);

    std.debug.print("Press Ctrl+C to trigger signal handler\n", .{});

    // Keep program running
    while (true) {
        std.time.sleep(std.time.ns_per_s);
    }
}
```

### Sending Signals

```zig
const signal = @import("signal");

// Send signal to another process
try signal.kill(1234, .SIGTERM);

// Send signal to self
try signal.raise(.SIGUSR1);
```

### Signal Masking

```zig
const signal = @import("signal");

// Block a signal (it will be queued but not delivered)
try signal.block(.SIGINT);

// Do critical work that shouldn't be interrupted
// ...

// Unblock the signal
try signal.unblock(.SIGINT);
```

### Ignoring Signals

```zig
const signal = @import("signal");

// Ignore SIGPIPE (broken pipe)
try signal.ignore(.SIGPIPE);

// This is useful for network servers that don't want to crash
// when a client disconnects unexpectedly
```

### Signal Sets

```zig
const std = @import("std");
const signal = @import("signal");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a signal set
    var set = signal.SignalSet.init(allocator);
    defer set.deinit();

    // Add signals to the set
    try set.add(.SIGINT);
    try set.add(.SIGTERM);
    try set.add(.SIGUSR1);

    // Block all signals in the set
    try set.blockAll();

    // Critical section
    std.debug.print("In critical section, signals are blocked\n", .{});
    std.time.sleep(std.time.ns_per_s * 2);

    // Unblock all signals
    try set.unblockAll();
    std.debug.print("Signals unblocked\n", .{});
}
```

### Alarm Timer

```zig
const signal = @import("signal");

fn handleAlarm(sig: signal.Signal) void {
    std.debug.print("Alarm triggered!\n", .{});
}

pub fn main() !void {
    // Set handler for SIGALRM
    try signal.setHandler(.SIGALRM, handleAlarm);

    // Set alarm for 5 seconds
    _ = signal.alarm(5);

    std.debug.print("Alarm set for 5 seconds\n", .{});

    // Wait for alarm
    std.time.sleep(std.time.ns_per_s * 10);

    // Cancel alarm if needed
    signal.cancelAlarm();
}
```

### Graceful Shutdown

```zig
const std = @import("std");
const signal = @import("signal");

var should_exit = false;

fn handleShutdown(sig: signal.Signal) void {
    std.debug.print("Received {s}, shutting down gracefully...\n", .{sig.name()});
    should_exit = true;
}

pub fn main() !void {
    // Handle multiple termination signals
    try signal.setHandler(.SIGINT, handleShutdown);
    try signal.setHandler(.SIGTERM, handleShutdown);

    std.debug.print("Server running... (Ctrl+C to stop)\n", .{});

    while (!should_exit) {
        // Do server work
        std.time.sleep(std.time.ns_per_ms * 100);
    }

    std.debug.print("Cleanup complete, exiting\n", .{});
}
```

## Available Signals

- `SIGHUP` (1) - Hangup
- `SIGINT` (2) - Interrupt (Ctrl+C)
- `SIGQUIT` (3) - Quit
- `SIGILL` (4) - Illegal instruction
- `SIGTRAP` (5) - Trace trap
- `SIGABRT` (6) - Abort
- `SIGBUS` (7) - Bus error
- `SIGFPE` (8) - Floating point exception
- `SIGKILL` (9) - Kill (cannot be caught)
- `SIGUSR1` (10) - User-defined signal 1
- `SIGSEGV` (11) - Segmentation fault
- `SIGUSR2` (12) - User-defined signal 2
- `SIGPIPE` (13) - Broken pipe
- `SIGALRM` (14) - Alarm clock
- `SIGTERM` (15) - Termination
- `SIGCHLD` (17) - Child status changed
- `SIGCONT` (18) - Continue
- `SIGSTOP` (19) - Stop (cannot be caught)
- `SIGTSTP` (20) - Stop typed at terminal
- `SIGTTIN` (21) - Background read from tty
- `SIGTTOU` (22) - Background write to tty
- `SIGURG` (23) - Urgent condition on socket
- `SIGXCPU` (24) - CPU time limit exceeded
- `SIGXFSZ` (25) - File size limit exceeded
- `SIGVTALRM` (26) - Virtual alarm clock
- `SIGPROF` (27) - Profiling alarm clock
- `SIGWINCH` (28) - Window size change
- `SIGIO` (29) - I/O now possible
- `SIGPWR` (30) - Power failure

## Platform Support

- **Unix/Linux/macOS**: Full support for all features
- **Windows**: Limited support (most signal operations return `error.OperationNotSupported`)

## Important Notes

1. **SIGKILL and SIGSTOP**: These signals cannot be caught, blocked, or ignored
2. **Signal Safety**: Signal handlers should be kept simple and avoid complex operations
3. **Thread Safety**: Signal handlers run in an unknown context, avoid accessing shared state
4. **Async-signal-safe**: Only call async-signal-safe functions from handlers
5. **Handler Storage**: Signal handlers are stored globally, not per-thread

## Error Handling

All signal operations return errors for:
- `error.OperationNotSupported` - Operation not supported on this platform
- `error.InvalidSignal` - Invalid signal number
- `error.BlockFailed` - Failed to block signal
- `error.UnblockFailed` - Failed to unblock signal
- `error.RaiseFailed` - Failed to raise signal

## Best Practices

1. **Keep handlers simple**: Minimal logic, just set flags or counters
2. **Use volatile atomics**: For shared state accessed in handlers
3. **Reset handlers**: Always reset or restore original handlers when done
4. **Test graceful shutdown**: Ensure cleanup works correctly
5. **Document signal usage**: Make it clear which signals your program handles
