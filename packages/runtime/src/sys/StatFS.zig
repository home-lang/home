//! Native statfs ABI and libc bridge.
//!
//! Bun obtains this type from its translated C headers. Home keeps the small
//! platform definitions here so sys.statfs writes into the real libc layout
//! instead of a result-only placeholder.

const builtin = @import("builtin");

pub const StatFS = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => DarwinStatFS,
    .linux => LinuxStatFS,
    .freebsd => FreeBSDStatFS,
    .windows => UVStatFS,
    else => UVStatFS,
};

const DarwinStatFS = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
};

const LinuxStatFS = extern struct {
    f_type: c_ulong,
    f_bsize: c_ulong,
    f_blocks: c_ulong,
    f_bfree: c_ulong,
    f_bavail: c_ulong,
    f_files: c_ulong,
    f_ffree: c_ulong,
    f_fsid: [2]c_int,
    f_namelen: c_ulong,
    f_frsize: c_ulong,
    f_flags: c_ulong,
    f_spare: [4]c_ulong,
};

const FreeBSDStatFS = extern struct {
    f_version: u32,
    f_type: u32,
    f_flags: u64,
    f_bsize: u64,
    f_iosize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: i64,
    f_files: u64,
    f_ffree: i64,
    f_syncwrites: u64,
    f_asyncwrites: u64,
    f_syncreads: u64,
    f_asyncreads: u64,
    f_nvnodelistsize: u32,
    f_spare0: u32,
    f_spare: [9]u64,
    f_namemax: u32,
    f_owner: u32,
    f_fsid: [2]i32,
    f_charspare: [80]u8,
    f_fstypename: [16]u8,
    f_mntfromname: [1024]u8,
    f_mntonname: [1024]u8,
};

const UVStatFS = extern struct {
    f_type: u64,
    f_bsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_spare: [4]u64,
};

const libc = struct {
    extern "c" fn statfs(path: [*:0]const u8, out: *StatFS) c_int;
};

pub fn statfs(path: [:0]const u8, out: *StatFS) c_int {
    return switch (comptime builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .linux, .freebsd => libc.statfs(path.ptr, out),
        else => {
            out.* = @bitCast(@as([@sizeOf(StatFS)]u8, @splat(0)));
            return -1;
        },
    };
}

comptime {
    const Layout = struct { size: usize, alignment: usize, f_type: usize, f_bsize: usize };
    const expected: ?Layout = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .{ .size = 2168, .alignment = 8, .f_type = 60, .f_bsize = 0 },
        .linux => if (@sizeOf(c_ulong) == 8) .{ .size = 120, .alignment = 8, .f_type = 0, .f_bsize = 8 } else null,
        .freebsd => .{ .size = 2344, .alignment = 8, .f_type = 4, .f_bsize = 16 },
        .windows => .{ .size = 88, .alignment = 8, .f_type = 0, .f_bsize = 8 },
        else => null,
    };
    if (expected) |layout| {
        if (@sizeOf(StatFS) != layout.size or
            @alignOf(StatFS) != layout.alignment or
            @offsetOf(StatFS, "f_type") != layout.f_type or
            @offsetOf(StatFS, "f_bsize") != layout.f_bsize)
        {
            @compileError("native statfs ABI mismatch");
        }
    }
}
