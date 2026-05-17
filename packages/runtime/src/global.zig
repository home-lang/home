// Home Runtime — process-level globals.
//
// Mirrors the small subset of Bun's `Global` namespace that the copied
// cli leaves need: `exit` for fatal error paths, `crash` for panics
// (no-op in tests).

const std = @import("std");

pub fn exit(code: u8) noreturn {
    std.process.exit(code);
}

pub fn crash() noreturn {
    @panic("home_rt: crash() called");
}

test "exit and crash exist" {
    _ = exit;
    _ = crash;
}
