// Copied from bun/src/errno/darwin_errno.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// macOS errno table plus the `UV_E` mapping libuv uses to translate POSIX
// errno values into its own negative-int error space. Upstream's `UV_E`
// references `bun.windows.libuv.UV_E*` for the codes that don't have a
// matching POSIX errno on Darwin (CHARSET, NONET, REMOTEIO, UNATCH); Home
// hasn't ported libuv_sys yet, so those constants are inlined from libuv's
// `errno.h` (negative-of-`UV__E*`, values stable since libuv 1.0).

pub const Mode = std.posix.mode_t;
pub const E = std.posix.E;
pub const S = std.posix.S;

/// libuv UV_E* constants for the four codes that have no Darwin POSIX
/// counterpart. Negative-int form matches libuv's `include/uv/errno.h`
/// (where `UV_E* = -<positive>`); `UV_E` below negates them again to get
/// the positive errno-shaped integer Bun stores.
/// Once `libuv_sys/libuv.zig` is ported, these will be replaced by
/// `@import("home_rt").libuv_sys.libuv.UV_E*`.
const uv_constants = struct {
    pub const UV_ECHARSET: c_int = -4080;
    pub const UV_ENONET: c_int = -4056;
    pub const UV_EREMOTEIO: c_int = -4030;
    pub const UV_EUNATCH: c_int = -4023;
};

pub const SystemErrno = enum(u16) {
    SUCCESS = 0,
    EPERM = 1,
    ENOENT = 2,
    ESRCH = 3,
    EINTR = 4,
    EIO = 5,
    ENXIO = 6,
    E2BIG = 7,
    ENOEXEC = 8,
    EBADF = 9,
    ECHILD = 10,
    EDEADLK = 11,
    ENOMEM = 12,
    EACCES = 13,
    EFAULT = 14,
    ENOTBLK = 15,
    EBUSY = 16,
    EEXIST = 17,
    EXDEV = 18,
    ENODEV = 19,
    ENOTDIR = 20,
    EISDIR = 21,
    EINVAL = 22,
    ENFILE = 23,
    EMFILE = 24,
    ENOTTY = 25,
    ETXTBSY = 26,
    EFBIG = 27,
    ENOSPC = 28,
    ESPIPE = 29,
    EROFS = 30,
    EMLINK = 31,
    EPIPE = 32,
    EDOM = 33,
    ERANGE = 34,
    EAGAIN = 35,
    EINPROGRESS = 36,
    EALREADY = 37,
    ENOTSOCK = 38,
    EDESTADDRREQ = 39,
    EMSGSIZE = 40,
    EPROTOTYPE = 41,
    ENOPROTOOPT = 42,
    EPROTONOSUPPORT = 43,
    ESOCKTNOSUPPORT = 44,
    ENOTSUP = 45,
    EPFNOSUPPORT = 46,
    EAFNOSUPPORT = 47,
    EADDRINUSE = 48,
    EADDRNOTAVAIL = 49,
    ENETDOWN = 50,
    ENETUNREACH = 51,
    ENETRESET = 52,
    ECONNABORTED = 53,
    ECONNRESET = 54,
    ENOBUFS = 55,
    EISCONN = 56,
    ENOTCONN = 57,
    ESHUTDOWN = 58,
    ETOOMANYREFS = 59,
    ETIMEDOUT = 60,
    ECONNREFUSED = 61,
    ELOOP = 62,
    ENAMETOOLONG = 63,
    EHOSTDOWN = 64,
    EHOSTUNREACH = 65,
    ENOTEMPTY = 66,
    EPROCLIM = 67,
    EUSERS = 68,
    EDQUOT = 69,
    ESTALE = 70,
    EREMOTE = 71,
    EBADRPC = 72,
    ERPCMISMATCH = 73,
    EPROGUNAVAIL = 74,
    EPROGMISMATCH = 75,
    EPROCUNAVAIL = 76,
    ENOLCK = 77,
    ENOSYS = 78,
    EFTYPE = 79,
    EAUTH = 80,
    ENEEDAUTH = 81,
    EPWROFF = 82,
    EDEVERR = 83,
    EOVERFLOW = 84,
    EBADEXEC = 85,
    EBADARCH = 86,
    ESHLIBVERS = 87,
    EBADMACHO = 88,
    ECANCELED = 89,
    EIDRM = 90,
    ENOMSG = 91,
    EILSEQ = 92,
    ENOATTR = 93,
    EBADMSG = 94,
    EMULTIHOP = 95,
    ENODATA = 96,
    ENOLINK = 97,
    ENOSR = 98,
    ENOSTR = 99,
    EPROTO = 100,
    ETIME = 101,
    EOPNOTSUPP = 102,
    ENOPOLICY = 103,
    ENOTRECOVERABLE = 104,
    EOWNERDEAD = 105,
    EQFULL = 106,

    pub const max = 107;

    pub fn init(code: anytype) ?SystemErrno {
        if (code < 0) {
            if (code <= -max) {
                return null;
            }
            return @enumFromInt(-code);
        }
        if (code >= max) return null;
        return @enumFromInt(code);
    }
};
pub const UV_E = struct {
    pub const @"2BIG": i32 = @intFromEnum(SystemErrno.E2BIG);
    pub const ACCES: i32 = @intFromEnum(SystemErrno.EACCES);
    pub const ADDRINUSE: i32 = @intFromEnum(SystemErrno.EADDRINUSE);
    pub const ADDRNOTAVAIL: i32 = @intFromEnum(SystemErrno.EADDRNOTAVAIL);
    pub const AFNOSUPPORT: i32 = @intFromEnum(SystemErrno.EAFNOSUPPORT);
    pub const AGAIN: i32 = @intFromEnum(SystemErrno.EAGAIN);
    pub const ALREADY: i32 = @intFromEnum(SystemErrno.EALREADY);
    pub const BADF: i32 = @intFromEnum(SystemErrno.EBADF);
    pub const BUSY: i32 = @intFromEnum(SystemErrno.EBUSY);
    pub const CANCELED: i32 = @intFromEnum(SystemErrno.ECANCELED);
    pub const CHARSET: i32 = -uv_constants.UV_ECHARSET;
    pub const CONNABORTED: i32 = @intFromEnum(SystemErrno.ECONNABORTED);
    pub const CONNREFUSED: i32 = @intFromEnum(SystemErrno.ECONNREFUSED);
    pub const CONNRESET: i32 = @intFromEnum(SystemErrno.ECONNRESET);
    pub const DESTADDRREQ: i32 = @intFromEnum(SystemErrno.EDESTADDRREQ);
    pub const EXIST: i32 = @intFromEnum(SystemErrno.EEXIST);
    pub const FAULT: i32 = @intFromEnum(SystemErrno.EFAULT);
    pub const HOSTUNREACH: i32 = @intFromEnum(SystemErrno.EHOSTUNREACH);
    pub const INTR: i32 = @intFromEnum(SystemErrno.EINTR);
    pub const INVAL: i32 = @intFromEnum(SystemErrno.EINVAL);
    pub const IO: i32 = @intFromEnum(SystemErrno.EIO);
    pub const ISCONN: i32 = @intFromEnum(SystemErrno.EISCONN);
    pub const ISDIR: i32 = @intFromEnum(SystemErrno.EISDIR);
    pub const LOOP: i32 = @intFromEnum(SystemErrno.ELOOP);
    pub const MFILE: i32 = @intFromEnum(SystemErrno.EMFILE);
    pub const MSGSIZE: i32 = @intFromEnum(SystemErrno.EMSGSIZE);
    pub const NAMETOOLONG: i32 = @intFromEnum(SystemErrno.ENAMETOOLONG);
    pub const NETDOWN: i32 = @intFromEnum(SystemErrno.ENETDOWN);
    pub const NETUNREACH: i32 = @intFromEnum(SystemErrno.ENETUNREACH);
    pub const NFILE: i32 = @intFromEnum(SystemErrno.ENFILE);
    pub const NOBUFS: i32 = @intFromEnum(SystemErrno.ENOBUFS);
    pub const NODEV: i32 = @intFromEnum(SystemErrno.ENODEV);
    pub const NOENT: i32 = @intFromEnum(SystemErrno.ENOENT);
    pub const NOMEM: i32 = @intFromEnum(SystemErrno.ENOMEM);
    pub const NONET: i32 = -uv_constants.UV_ENONET;
    pub const NOSPC: i32 = @intFromEnum(SystemErrno.ENOSPC);
    pub const NOSYS: i32 = @intFromEnum(SystemErrno.ENOSYS);
    pub const NOTCONN: i32 = @intFromEnum(SystemErrno.ENOTCONN);
    pub const NOTDIR: i32 = @intFromEnum(SystemErrno.ENOTDIR);
    pub const NOTEMPTY: i32 = @intFromEnum(SystemErrno.ENOTEMPTY);
    pub const NOTSOCK: i32 = @intFromEnum(SystemErrno.ENOTSOCK);
    pub const NOTSUP: i32 = @intFromEnum(SystemErrno.ENOTSUP);
    pub const PERM: i32 = @intFromEnum(SystemErrno.EPERM);
    pub const PIPE: i32 = @intFromEnum(SystemErrno.EPIPE);
    pub const PROTO: i32 = @intFromEnum(SystemErrno.EPROTO);
    pub const PROTONOSUPPORT: i32 = @intFromEnum(SystemErrno.EPROTONOSUPPORT);
    pub const PROTOTYPE: i32 = @intFromEnum(SystemErrno.EPROTOTYPE);
    pub const ROFS: i32 = @intFromEnum(SystemErrno.EROFS);
    pub const SHUTDOWN: i32 = @intFromEnum(SystemErrno.ESHUTDOWN);
    pub const SPIPE: i32 = @intFromEnum(SystemErrno.ESPIPE);
    pub const SRCH: i32 = @intFromEnum(SystemErrno.ESRCH);
    pub const TIMEDOUT: i32 = @intFromEnum(SystemErrno.ETIMEDOUT);
    pub const TXTBSY: i32 = @intFromEnum(SystemErrno.ETXTBSY);
    pub const XDEV: i32 = @intFromEnum(SystemErrno.EXDEV);
    pub const FBIG: i32 = @intFromEnum(SystemErrno.EFBIG);
    pub const NOPROTOOPT: i32 = @intFromEnum(SystemErrno.ENOPROTOOPT);
    pub const RANGE: i32 = @intFromEnum(SystemErrno.ERANGE);
    pub const NXIO: i32 = @intFromEnum(SystemErrno.ENXIO);
    pub const MLINK: i32 = @intFromEnum(SystemErrno.EMLINK);
    pub const HOSTDOWN: i32 = @intFromEnum(SystemErrno.EHOSTDOWN);
    pub const REMOTEIO: i32 = -uv_constants.UV_EREMOTEIO;
    pub const NOTTY: i32 = @intFromEnum(SystemErrno.ENOTTY);
    pub const FTYPE: i32 = @intFromEnum(SystemErrno.EFTYPE);
    pub const ILSEQ: i32 = @intFromEnum(SystemErrno.EILSEQ);
    pub const OVERFLOW: i32 = @intFromEnum(SystemErrno.EOVERFLOW);
    pub const SOCKTNOSUPPORT: i32 = @intFromEnum(SystemErrno.ESOCKTNOSUPPORT);
    pub const NODATA: i32 = @intFromEnum(SystemErrno.ENODATA);
    pub const UNATCH: i32 = -uv_constants.UV_EUNATCH;
    pub const NOEXEC: i32 = @intFromEnum(SystemErrno.ENOEXEC);
};
pub fn getErrno(rc: anytype) E {
    if (rc == -1) {
        return @enumFromInt(std.c._errno().*);
    } else {
        return .SUCCESS;
    }
}

const std = @import("std");

test "darwin SystemErrno canonical values match POSIX (ENOENT=2, EBADF=9)" {
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(SystemErrno.ENOENT));
    try std.testing.expectEqual(@as(c_int, 9), @intFromEnum(SystemErrno.EBADF));
    try std.testing.expectEqual(@as(c_int, 17), @intFromEnum(SystemErrno.EEXIST));
}

test "darwin SystemErrno macOS-specific codes have macOS values" {
    // EAGAIN is 35 on Darwin (vs 11 on Linux) — verifies we picked up the
    // right table.
    try std.testing.expectEqual(@as(c_int, 35), @intFromEnum(SystemErrno.EAGAIN));
    // EBADMACHO is Darwin-only.
    try std.testing.expectEqual(@as(c_int, 88), @intFromEnum(SystemErrno.EBADMACHO));
    try std.testing.expectEqual(@as(c_int, 106), @intFromEnum(SystemErrno.EQFULL));
    try std.testing.expectEqual(107, SystemErrno.max);
}

test "darwin SystemErrno.init clamps out-of-range and accepts negatives" {
    try std.testing.expectEqual(@as(?SystemErrno, .ENOENT), SystemErrno.init(@as(c_int, 2)));
    try std.testing.expectEqual(@as(?SystemErrno, .ENOENT), SystemErrno.init(@as(c_int, -2)));
    try std.testing.expectEqual(@as(?SystemErrno, null), SystemErrno.init(@as(c_int, 500)));
    try std.testing.expectEqual(@as(?SystemErrno, null), SystemErrno.init(@as(c_int, -500)));
}

test "darwin UV_E stubbed libuv constants match documented libuv 1.x values" {
    // These are the four UV_E* entries that didn't have a Darwin POSIX
    // counterpart in upstream. The integer values come from libuv's
    // include/uv/errno.h (UV_E* = -UV__E*).
    try std.testing.expectEqual(@as(i32, 4080), UV_E.CHARSET);
    try std.testing.expectEqual(@as(i32, 4056), UV_E.NONET);
    try std.testing.expectEqual(@as(i32, 4030), UV_E.REMOTEIO);
    try std.testing.expectEqual(@as(i32, 4023), UV_E.UNATCH);
}
