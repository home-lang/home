// Copied from bun/src/runtime/node/node_fs_constant.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Pure-data substrate of `node:fs.constants`:
//   * File-access flags (`F_OK`, `R_OK`, `W_OK`, `X_OK`)
//   * `Copyfile` enum + `COPYFILE_*` integer constants
//   * Open flags (`O_RDONLY`, `O_WRONLY`, … `O_NONBLOCK`)
//   * File-type Stat mode flags (`S_IFMT`, `S_IFREG`, …, `S_IFSOCK`)
//   * File-mode Stat mode flags (`S_IRWXU`, …, `S_IXOTH`)
//   * Windows-only `UV_FS_O_FILEMAP`
//
// What's omitted (re-attaches in Phase 12.2 with the JSC bridge): nothing —
// upstream this file is pure data. The only divergence is that `bun.O`
// (a Bun-defined per-OS struct of plain integer flags) is replaced by an
// inline `O` namespace here, since `std.posix.O` in Zig 0.17 is a packed
// struct (not raw integer decls) and `node:fs.constants` ships raw integer
// values to JS.
//
// Imports rewritten: @import("bun") → @import("home_rt") for `Environment`.

const std = @import("std");
const builtin = @import("builtin");

const home_rt = @import("home_rt");
const Environment = home_rt.Environment;

/// Plain-integer mirror of `bun.O` (Bun's `src/sys/sys.zig` per-OS struct of
/// `pub const FOO = …` decls). Zig 0.17 reshaped `std.posix.O` into a packed
/// `bitset` struct, so we replicate Bun's raw-integer flavour here so the
/// downstream `O_*` consts below stay `comptime_int`-compatible with the JS
/// bridge.
const os_tag = builtin.os.tag;
const is_x86 = switch (builtin.cpu.arch) {
    .x86, .x86_64 => true,
    else => false,
};

pub const O = switch (os_tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        pub const RDONLY: comptime_int = 0x0000;
        pub const WRONLY: comptime_int = 0x0001;
        pub const RDWR: comptime_int = 0x0002;
        pub const NONBLOCK: comptime_int = 0x0004;
        pub const APPEND: comptime_int = 0x0008;
        pub const CREAT: comptime_int = 0x0200;
        pub const TRUNC: comptime_int = 0x0400;
        pub const EXCL: comptime_int = 0x0800;
        pub const NOFOLLOW: comptime_int = 0x0100;
        pub const SYMLINK: comptime_int = 0x200000;
        pub const NOCTTY: comptime_int = 131072;
        pub const DIRECTORY: comptime_int = 0x00100000;
        pub const DSYNC: comptime_int = 4194304;
        pub const SYNC: comptime_int = 128;
        // Darwin's `O_DIRECT` doesn't exist; libuv treats this as 0.
        pub const DIRECT: comptime_int = 0;
        pub const NOATIME: comptime_int = 0;
    },
    .linux => struct {
        pub const RDONLY: comptime_int = 0x0000;
        pub const WRONLY: comptime_int = 0x0001;
        pub const RDWR: comptime_int = 0x0002;
        pub const CREAT: comptime_int = 0o100;
        pub const EXCL: comptime_int = 0o200;
        pub const NOCTTY: comptime_int = 0o400;
        pub const TRUNC: comptime_int = 0o1000;
        pub const APPEND: comptime_int = 0o2000;
        pub const NONBLOCK: comptime_int = 0o4000;
        pub const DSYNC: comptime_int = 0o10000;
        pub const SYNC: comptime_int = 0o4010000;
        pub const DIRECTORY: comptime_int = if (is_x86) 0o200000 else 0o40000;
        pub const NOFOLLOW: comptime_int = if (is_x86) 0o400000 else 0o100000;
        pub const DIRECT: comptime_int = if (is_x86) 0o40000 else 0o200000;
        pub const NOATIME: comptime_int = 0o1000000;
        // Linux has no `O_SYMLINK`; mirrored as 0 for parity with Bun's table.
        pub const SYMLINK: comptime_int = 0;
    },
    .freebsd => struct {
        pub const RDONLY: comptime_int = 0x0000;
        pub const WRONLY: comptime_int = 0x0001;
        pub const RDWR: comptime_int = 0x0002;
        pub const NONBLOCK: comptime_int = 0x0004;
        pub const APPEND: comptime_int = 0x0008;
        pub const SYNC: comptime_int = 0x0080;
        pub const NOFOLLOW: comptime_int = 0x0100;
        pub const CREAT: comptime_int = 0x0200;
        pub const TRUNC: comptime_int = 0x0400;
        pub const EXCL: comptime_int = 0x0800;
        pub const NOCTTY: comptime_int = 0x8000;
        pub const DIRECT: comptime_int = 0x00010000;
        pub const DIRECTORY: comptime_int = 0x00020000;
        pub const DSYNC: comptime_int = 0x01000000;
        // FreeBSD lacks `O_SYMLINK`/`O_NOATIME`; Bun's table mirrors them as 0.
        pub const SYMLINK: comptime_int = 0;
        pub const NOATIME: comptime_int = 0;
    },
    .windows => struct {
        // Upstream's libuv-side table on Windows — kept verbatim.
        pub const RDONLY: comptime_int = 0o0;
        pub const WRONLY: comptime_int = 0o1;
        pub const RDWR: comptime_int = 0o2;
        pub const CREAT: comptime_int = 0o100;
        pub const EXCL: comptime_int = 0o200;
        pub const NOCTTY: comptime_int = 0;
        pub const TRUNC: comptime_int = 0o1000;
        pub const APPEND: comptime_int = 0o2000;
        pub const NONBLOCK: comptime_int = 0o4000;
        pub const DSYNC: comptime_int = 0o10000;
        pub const SYNC: comptime_int = 0o4010000;
        pub const DIRECTORY: comptime_int = 0o200000;
        pub const NOFOLLOW: comptime_int = 0o400000;
        pub const DIRECT: comptime_int = 0o40000;
        pub const NOATIME: comptime_int = 0o1000000;
        pub const SYMLINK: comptime_int = 0;
    },
    else => @compileError("unsupported OS"),
};

// =====================================================================
// File Access Constants
// =====================================================================

/// Constant for fs.access(). File is visible to the calling process.
pub const F_OK = std.posix.F_OK;
/// Constant for fs.access(). File can be read by the calling process.
pub const R_OK = std.posix.R_OK;
/// Constant for fs.access(). File can be written by the calling process.
pub const W_OK = std.posix.W_OK;
/// Constant for fs.access(). File can be executed by the calling process.
pub const X_OK = std.posix.X_OK;

// =====================================================================
// File Copy Constants
// =====================================================================

pub const Copyfile = enum(i32) {
    _,
    pub const exclusive: comptime_int = 1;
    pub const clone: comptime_int = 2;
    pub const force: comptime_int = 4;

    pub inline fn isForceClone(this: Copyfile) bool {
        return (@intFromEnum(this) & COPYFILE_FICLONE_FORCE) != 0;
    }

    pub inline fn shouldntOverwrite(this: Copyfile) bool {
        return (@intFromEnum(this) & COPYFILE_EXCL) != 0;
    }

    pub inline fn canUseClone(this: Copyfile) bool {
        _ = this;
        return Environment.isMac;
    }
};

/// Constant for fs.copyFile. Flag indicating the destination file should not be overwritten if it already exists.
pub const COPYFILE_EXCL: i32 = Copyfile.exclusive;
/// Constant for fs.copyFile. copy operation will attempt to create a copy-on-write reflink.
/// If the underlying platform does not support copy-on-write, then a fallback copy mechanism is used.
pub const COPYFILE_FICLONE: i32 = Copyfile.clone;
/// Constant for fs.copyFile. Copy operation will attempt to create a copy-on-write reflink.
/// If the underlying platform does not support copy-on-write, then the operation will fail with an error.
pub const COPYFILE_FICLONE_FORCE: i32 = Copyfile.force;

// =====================================================================
// File Open Constants
// =====================================================================

/// Constant for fs.open(). Flag indicating to open a file for read-only access.
pub const O_RDONLY = O.RDONLY;
/// Constant for fs.open(). Flag indicating to open a file for write-only access.
pub const O_WRONLY = O.WRONLY;
/// Constant for fs.open(). Flag indicating to open a file for read-write access.
pub const O_RDWR = O.RDWR;
/// Constant for fs.open(). Flag indicating to create the file if it does not already exist.
pub const O_CREAT = O.CREAT;
/// Constant for fs.open(). Flag indicating that opening a file should fail if the O_CREAT flag is set and the file already exists.
pub const O_EXCL = O.EXCL;
/// Constant for fs.open(). Flag indicating that if path identifies a terminal device,
/// opening the path shall not cause that terminal to become the controlling terminal for the process
/// (if the process does not already have one).
pub const O_NOCTTY = O.NOCTTY;
/// Constant for fs.open(). Flag indicating that if the file exists and is a regular file, and the file is opened successfully for write access, its length shall be truncated to zero.
pub const O_TRUNC = O.TRUNC;
/// Constant for fs.open(). Flag indicating that data will be appended to the end of the file.
pub const O_APPEND = O.APPEND;
/// Constant for fs.open(). Flag indicating that the open should fail if the path is not a directory.
pub const O_DIRECTORY = O.DIRECTORY;
/// Constant for fs.open(). Linux-only flag indicating that reading should not
/// update atime. Mirrored as 0 on platforms that lack it (parity with upstream).
pub const O_NOATIME = O.NOATIME;
/// Constant for fs.open(). Flag indicating that the open should fail if the path is a symbolic link.
pub const O_NOFOLLOW = O.NOFOLLOW;
/// Constant for fs.open(). Flag indicating that the file is opened for synchronous I/O.
pub const O_SYNC = O.SYNC;
/// Constant for fs.open(). Flag indicating that the file is opened for synchronous I/O with write operations waiting for data integrity.
pub const O_DSYNC = O.DSYNC;
/// Constant for fs.open(). Flag indicating to open the symbolic link itself rather than the resource it is pointing to.
pub const O_SYMLINK = O.SYMLINK;
/// Constant for fs.open(). When set, an attempt will be made to minimize caching effects of file I/O.
pub const O_DIRECT = O.DIRECT;
/// Constant for fs.open(). Flag indicating to open the file in nonblocking mode when possible.
pub const O_NONBLOCK = O.NONBLOCK;

// =====================================================================
// File Type Constants (Stat.mode bit mask)
// =====================================================================

/// Constant for fs.Stats mode property for determining a file's type. Bit mask used to extract the file type code.
pub const S_IFMT = std.posix.S.IFMT;
/// Constant for fs.Stats mode property for determining a file's type. File type constant for a regular file.
pub const S_IFREG = std.posix.S.IFREG;
/// Constant for fs.Stats mode property for determining a file's type. File type constant for a directory.
pub const S_IFDIR = std.posix.S.IFDIR;
/// Constant for fs.Stats mode property for determining a file's type. File type constant for a character-oriented device file.
pub const S_IFCHR = std.posix.S.IFCHR;
/// Constant for fs.Stats mode property for determining a file's type. File type constant for a block-oriented device file.
pub const S_IFBLK = std.posix.S.IFBLK;
/// Constant for fs.Stats mode property for determining a file's type. File type constant for a FIFO/pipe.
pub const S_IFIFO = std.posix.S.IFIFO;
/// Constant for fs.Stats mode property for determining a file's type. File type constant for a symbolic link.
pub const S_IFLNK = std.posix.S.IFLNK;
/// Constant for fs.Stats mode property for determining a file's type. File type constant for a socket.
pub const S_IFSOCK = std.posix.S.IFSOCK;

// =====================================================================
// File Mode Constants (Stat.mode permission bits)
// =====================================================================

/// File mode indicating readable, writable and executable by owner.
pub const S_IRWXU = std.posix.S.IRWXU;
/// File mode indicating readable by owner.
pub const S_IRUSR = std.posix.S.IRUSR;
/// File mode indicating writable by owner.
pub const S_IWUSR = std.posix.S.IWUSR;
/// File mode indicating executable by owner.
pub const S_IXUSR = std.posix.S.IXUSR;
/// File mode indicating readable, writable and executable by group.
pub const S_IRWXG = std.posix.S.IRWXG;
/// File mode indicating readable by group.
pub const S_IRGRP = std.posix.S.IRGRP;
/// File mode indicating writable by group.
pub const S_IWGRP = std.posix.S.IWGRP;
/// File mode indicating executable by group.
pub const S_IXGRP = std.posix.S.IXGRP;
/// File mode indicating readable, writable and executable by others.
pub const S_IRWXO = std.posix.S.IRWXO;
/// File mode indicating readable by others.
pub const S_IROTH = std.posix.S.IROTH;
/// File mode indicating writable by others.
pub const S_IWOTH = std.posix.S.IWOTH;
/// File mode indicating executable by others.
pub const S_IXOTH = std.posix.S.IXOTH;

/// When set, a memory file mapping is used to access the file. This flag
/// is available on Windows operating systems only. On other operating systems,
/// this flag is ignored.
pub const UV_FS_O_FILEMAP: comptime_int = 536870912;

test "node_fs_constant: access flag values match POSIX std" {
    try std.testing.expectEqual(@as(c_int, std.posix.F_OK), F_OK);
    try std.testing.expectEqual(@as(c_int, std.posix.R_OK), R_OK);
    try std.testing.expectEqual(@as(c_int, std.posix.W_OK), W_OK);
    try std.testing.expectEqual(@as(c_int, std.posix.X_OK), X_OK);
}

test "node_fs_constant: Copyfile classifier helpers respect bit flags" {
    const force: Copyfile = @enumFromInt(Copyfile.force);
    const excl: Copyfile = @enumFromInt(Copyfile.exclusive);
    const clone: Copyfile = @enumFromInt(Copyfile.clone);
    try std.testing.expect(force.isForceClone());
    try std.testing.expect(!excl.isForceClone());
    try std.testing.expect(excl.shouldntOverwrite());
    try std.testing.expect(!clone.shouldntOverwrite());
    try std.testing.expectEqual(Environment.isMac, force.canUseClone());
}

test "node_fs_constant: COPYFILE_* mirror Copyfile enum" {
    try std.testing.expectEqual(@as(i32, 1), COPYFILE_EXCL);
    try std.testing.expectEqual(@as(i32, 2), COPYFILE_FICLONE);
    try std.testing.expectEqual(@as(i32, 4), COPYFILE_FICLONE_FORCE);
}

test "node_fs_constant: O_RDONLY is zero on every platform" {
    try std.testing.expectEqual(@as(comptime_int, 0), O_RDONLY);
}

test "node_fs_constant: open flags are platform-distinct" {
    // RDONLY/WRONLY/RDWR are 0/1/2 by POSIX convention. The other flags
    // differ per platform — we only assert "non-zero where it should be".
    try std.testing.expectEqual(@as(comptime_int, 1), O_WRONLY);
    try std.testing.expectEqual(@as(comptime_int, 2), O_RDWR);
    if (Environment.isPosix) {
        try std.testing.expect(O_CREAT != 0);
        try std.testing.expect(O_TRUNC != 0);
        try std.testing.expect(O_APPEND != 0);
    }
}

test "node_fs_constant: file-type flag masks are non-overlapping" {
    // Each of S_IFREG/S_IFDIR/S_IFCHR/… picks a single bit-pattern when
    // masked with S_IFMT.
    try std.testing.expectEqual(S_IFREG, S_IFREG & S_IFMT);
    try std.testing.expectEqual(S_IFDIR, S_IFDIR & S_IFMT);
    try std.testing.expectEqual(S_IFSOCK, S_IFSOCK & S_IFMT);
    try std.testing.expect(S_IFREG != S_IFDIR);
    try std.testing.expect(S_IFDIR != S_IFCHR);
}

test "node_fs_constant: UV_FS_O_FILEMAP carries the node-spec value" {
    try std.testing.expectEqual(@as(comptime_int, 536870912), UV_FS_O_FILEMAP);
}
