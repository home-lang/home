// Copied verbatim from bun/src/safety/thread_id.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

/// A value that does not alias any other thread ID.
/// See `Thread/Mutex/Recursive.zig` in the Zig standard library.
pub const invalid = std.math.maxInt(std.Thread.Id);

const std = @import("std");
