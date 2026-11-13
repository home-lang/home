//! The running kernel's release, rather than compile-time OS metadata.
const std = @import("std");
const builtin = @import("builtin");

pub fn read(allocator: std.mem.Allocator) ![:0]u8 {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        var information: std.c.utsname = undefined;
        if (std.c.uname(&information) != 0) return error.NativeUnameFailed;
        const release = std.mem.sliceTo(&information.release, 0);
        if (release.len == 0) return error.EmptyKernelRelease;
        return allocator.dupeSentinel(u8, release, 0);
    }
    return error.UnsupportedPlatform;
}
