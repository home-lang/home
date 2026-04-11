//! Minimal Zig build runner that bypasses zig 0.16-dev's std.Io.Threaded /
//! DebugAllocator path, both of which fail to link on macOS 26 due to a stub
//! gap in the bundled libSystem.tbd.
//!
//! Why this exists:
//!   The default build runner at $ZIG_LIB_DIR/compiler/build_runner.zig pulls
//!   in `std.heap.DebugAllocator` (libc malloc), `std.Io.Threaded` (dispatch
//!   semaphores), `std.posix.sigaction`, `std.process.exit`, etc. Zig 0.16-dev
//!   ships with libSystem stubs that target an older macOS SDK, so on macOS
//!   26 the linker cannot resolve any of those symbols and the build runner
//!   itself fails to compile.
//!
//!   This runner does the only thing we actually need: invoke the project's
//!   manual_build.sh which uses `zig build-exe` directly (the build-exe
//!   path correctly auto-links libSystem when given `-target native-macos -lc`).
//!
//! How to use:
//!   zig build --build-runner scripts/build_runner.zig
//!
//! This is a workaround until upstream Zig ships fresh libSystem stubs.
//! When that happens, drop this file and use the default runner.

const std = @import("std");

// Required by `zig build` — these get @import-resolved by the compiler when
// building the runner. The default runner needs `@build` to call into
// `pub fn build(b: *std.Build) void`. We bypass the build graph entirely so
// we don't reference these, but the imports must still resolve.
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

// libc system(3): runs `command` in /bin/sh and returns its exit status.
// Declared as an extern instead of going through std.c.system, which is
// behind a usingnamespace gated on link_libc and may not compile cleanly
// when the runner's other std imports aren't pulled in.
extern "c" fn system(command: [*:0]const u8) c_int;

pub fn main() !void {
    // The build runner runs in the directory containing build.zig (zig build's
    // contract), so a relative path to manual_build.sh is unambiguous.
    const command: [*:0]const u8 = "exec /bin/bash scripts/manual_build.sh";
    const rc = system(command);
    if (rc != 0) {
        // C system() returns the wait status; the high byte is the exit code.
        const exit_code: u8 = @intCast(@as(c_int, @divTrunc(rc, 256)) & 0xff);
        std.process.exit(if (exit_code != 0) exit_code else 1);
    }
}
