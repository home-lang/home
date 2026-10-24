//! Native serial executor entry point; Zig 0.15.2, no C translation required.
const host = @import("io/serial_worker.zig");
pub const Worker = host.Worker;
pub const Task = host.Task;
pub const Snapshot = host.Snapshot;
test {
    _ = host;
}
