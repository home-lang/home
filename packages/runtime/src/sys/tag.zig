// Extracted from bun/src/sys/sys.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Just the `Tag` enum (syscall classifier) and its `isWindows` helper. The
// upstream `Tag` lives inside `sys.zig` as a sub-decl of the 4703-line
// syscall substrate; almost every `Error`/`Maybe` site references it, so
// pulling it out here lets downstream files (`sys/Error.zig`, `sys/File.zig`,
// `Result(T, Error)` consumers) port without dragging in the full `sys`
// namespace.
//
// Upstream's `pub var strings = std.EnumMap(Tag, jsc.C.JSStringRef)...` is
// dropped because it depends on the JSC string interner. It re-attaches in
// Phase 12.2 alongside the JSC bridge.

const std = @import("std");

/// A tag describing which syscall produced an `Error`. The variants below
/// `WriteFile` are Windows-only (`isWindows()` keys off that boundary).
pub const Tag = enum(u8) {
    TODO,

    dup,
    access,
    connect,
    chmod,
    chown,
    clonefile,
    clonefileat,
    close,
    copy_file_range,
    copyfile,
    fchmod,
    fchmodat,
    fchown,
    fcntl,
    fdatasync,
    fstat,
    fstatat,
    fsync,
    ftruncate,
    futimens,
    getdents64,
    getdirentries64,
    lchmod,
    lchown,
    link,
    lseek,
    lstat,
    lutime,
    mkdir,
    mkdtemp,
    fnctl,
    memfd_create,
    mmap,
    munmap,
    open,
    pread,
    pwrite,
    read,
    readlink,
    rename,
    stat,
    statfs,
    symlink,
    symlinkat,
    unlink,
    utime,
    utimensat,
    write,
    getcwd,
    getenv,
    chdir,
    fcopyfile,
    recv,
    send,
    sendfile,
    sendmmsg,
    splice,
    rmdir,
    truncate,
    realpath,
    futime,
    pidfd_open,
    poll,
    ppoll,
    watch,
    scandir,

    kevent,
    kqueue,
    epoll_ctl,
    kill,
    waitpid,
    posix_spawn,
    getaddrinfo,
    writev,
    pwritev,
    readv,
    preadv,
    ioctl_ficlone,
    accept,
    bind2,
    connect2,
    listen,
    pipe,
    try_write,
    socketpair,
    setsockopt,
    statx,
    rm,

    uv_spawn,
    uv_pipe,
    uv_tty_set_mode,
    uv_open_osfhandle,
    uv_os_homedir,

    // Below this line are Windows API calls only.

    WriteFile,
    NtQueryDirectoryFile,
    NtSetInformationFile,
    GetFinalPathNameByHandle,
    CloseHandle,
    SetFilePointerEx,
    SetEndOfFile,

    pub fn isWindows(this: Tag) bool {
        return @intFromEnum(this) > @intFromEnum(Tag.WriteFile);
    }
};

test "Tag.TODO is the zero discriminant (so default-initialised Error has TODO)" {
    // Many `Error` sites rely on `syscall: Tag = Tag.TODO` defaulting cheaply;
    // keep `TODO` at index 0 to preserve that.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Tag.TODO));
}

test "Tag.isWindows true only for the Windows API subset" {
    // POSIX/cross-platform calls report false.
    try std.testing.expect(!Tag.open.isWindows());
    try std.testing.expect(!Tag.read.isWindows());
    try std.testing.expect(!Tag.write.isWindows());
    try std.testing.expect(!Tag.uv_spawn.isWindows()); // libuv tag, not raw Win32.

    // `WriteFile` is the boundary marker — also reports false.
    try std.testing.expect(!Tag.WriteFile.isWindows());

    // Strictly above WriteFile are the Win32/NT calls.
    try std.testing.expect(Tag.NtQueryDirectoryFile.isWindows());
    try std.testing.expect(Tag.CloseHandle.isWindows());
    try std.testing.expect(Tag.SetEndOfFile.isWindows());
}

test "Tag is a u8 enum (fits in `Error` packed layout)" {
    const info = @typeInfo(Tag).@"enum";
    try std.testing.expectEqual(u8, info.tag_type);
    // Sanity-check we didn't drop variants — last upstream tag is SetEndOfFile.
    try std.testing.expect(@intFromEnum(Tag.SetEndOfFile) > @intFromEnum(Tag.TODO));
}
