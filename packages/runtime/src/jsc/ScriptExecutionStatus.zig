// Copied verbatim from bun/src/jsc/ScriptExecutionStatus.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const ScriptExecutionStatus = enum(i32) {
    running = 0,
    suspended = 1,
    stopped = 2,
};
