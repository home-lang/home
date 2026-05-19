// Copied verbatim from bun/src/safety/safety.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Aggregator module that re-exports the safety substrate so callers can
// `@import("home_rt").safety.{alloc, CheckedAllocator, CriticalSection,
// ThreadLock}` exactly the way upstream does.

pub const alloc = @import("./alloc.zig");
pub const CheckedAllocator = alloc.CheckedAllocator;
pub const CriticalSection = @import("./CriticalSection.zig");
pub const ThreadLock = @import("./ThreadLock.zig");

test "safety aggregator re-exports symbols" {
    const std = @import("std");
    _ = alloc;
    _ = CheckedAllocator;
    _ = CriticalSection;
    _ = ThreadLock;
    try std.testing.expect(@hasDecl(@This(), "alloc"));
    try std.testing.expect(@hasDecl(@This(), "CheckedAllocator"));
    try std.testing.expect(@hasDecl(@This(), "CriticalSection"));
    try std.testing.expect(@hasDecl(@This(), "ThreadLock"));
}
