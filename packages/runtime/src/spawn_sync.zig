// Internal synchronous process spawning is the same contract used by Bun's
// native CLI and package-manager call sites. Keep this module as the stable
// import path while delegating to the complete runtime implementation.

const process = @import("runtime/api/bun/process.zig");

pub const Stdio = process.sync.Options.Stdio;
pub const Options = process.sync.Options;
pub const Status = process.Status;
pub const Result = process.sync.Result;
pub const spawn = process.sync.spawn;
