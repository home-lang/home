// Copied from bun/src/runtime/node/os/constants.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Pure substrate of `node:os.constants`:
//   * the four `comptime`-time enum lookup helpers (`getErrnoConstant`,
//     `getWindowsErrnoConstant`, `getSignalsConstant`, `getDlopenConstant`)
//   * the canonical name lists upstream's JSC `create()` iterates over
//   * the `Copyfile` / `Priority` integer constants (already pure data)
//
// What's omitted (re-attaches in Phase 12.2 with the JSC bridge):
//   * `defineConstant` / `__defineConstant` (writes to a `jsc.JSValue`)
//   * `create()` / `createErrno()` / `createSignals()` / `createPriority()`
//     / `createDlopen()` — they materialise the `node:os.constants` JS
//     object via `jsc.JSGlobalObject.put(...)` and `jsc.ZigString.static`.
//   * the `Bun__createJSStatsObject` / `…BigIntStats…` extern bridges
//     (those live in node/Stat.zig).
//
// Imports rewritten: @import("bun") → @import("home") for the
// `Environment` namespace.

const std = @import("std");
const builtin = @import("builtin");

const home_rt = @import("home");
const Environment = home_rt.Environment;

/// Tag for the four "shape" buckets upstream's `__defineConstant` switches on.
/// Carried verbatim so the JSC bridge re-attaches without renaming.
pub const ConstantType = enum { ERRNO, ERRNO_WIN, SIG, DLOPEN, OTHER };

/// Returns the underlying integer for `std.posix.E.<name>` if it exists on
/// the current target, else null. Tags missing on the host platform are
/// silently dropped — same behavior as upstream.
pub fn getErrnoConstant(comptime name: []const u8) ?comptime_int {
    return if (@hasField(std.posix.E, name))
        @intFromEnum(@field(std.posix.E, name))
    else
        null;
}

/// Windows-only winsock error tags. Mirrors `std.os.windows.ws2_32.WinsockError`.
pub fn getWindowsErrnoConstant(comptime name: []const u8) ?comptime_int {
    if (!Environment.isWindows) return null;
    return if (@hasField(std.os.windows.ws2_32.WinsockError, name))
        @intFromEnum(@field(std.os.windows.ws2_32.WinsockError, name))
    else
        null;
}

/// POSIX signal table lookup. In Zig 0.17 `std.posix.SIG` is an enum whose
/// fields are the platform signal names (`HUP`, `INT`, `STKFLT` is
/// Linux-only, etc.). Returns null if the host lacks the signal.
///
/// Divergence from upstream: bun's vendored Zig 0.13 spelled `SIG` as a
/// namespace of `pub const HUP = 1` decls, so it used `@hasDecl`. The 0.17
/// stdlib switched `SIG` to an enum, so we use `@hasField` here.
pub fn getSignalsConstant(comptime name: []const u8) ?comptime_int {
    return if (@hasField(std.posix.SIG, name))
        @intFromEnum(@field(std.posix.SIG, name))
    else
        null;
}

/// `dlopen()` flag table. Lives under `std.posix.system.RTLD` and is target-
/// specific (DEEPBIND is glibc-only, etc.).
pub fn getDlopenConstant(comptime name: []const u8) ?comptime_int {
    return if (@hasDecl(std.posix.system.RTLD, name))
        @field(std.posix.system.RTLD, name)
    else
        null;
}

/// Canonical list of POSIX errno tags `node:os.constants.errno` exposes.
/// Names are the suffixes — upstream's JSC bridge prepends "E" before
/// putting them on the JS object.
pub const errno_names = [_][]const u8{
    "2BIG",         "ACCES",       "ADDRINUSE",   "ADDRNOTAVAIL",
    "AFNOSUPPORT",  "AGAIN",       "ALREADY",     "BADF",
    "BADMSG",       "BUSY",        "CANCELED",    "CHILD",
    "CONNABORTED",  "CONNREFUSED", "CONNRESET",   "DEADLK",
    "DESTADDRREQ",  "DOM",         "DQUOT",       "EXIST",
    "FAULT",        "FBIG",        "HOSTUNREACH", "IDRM",
    "ILSEQ",        "INPROGRESS",  "INTR",        "INVAL",
    "IO",           "ISCONN",      "ISDIR",       "LOOP",
    "MFILE",        "MLINK",       "MSGSIZE",     "MULTIHOP",
    "NAMETOOLONG",  "NETDOWN",     "NETRESET",    "NETUNREACH",
    "NFILE",        "NOBUFS",      "NODATA",      "NODEV",
    "NOENT",        "NOEXEC",      "NOLCK",       "NOLINK",
    "NOMEM",        "NOMSG",       "NOPROTOOPT",  "NOSPC",
    "NOSR",         "NOSTR",       "NOSYS",       "NOTCONN",
    "NOTDIR",       "NOTEMPTY",    "NOTSOCK",     "NOTSUP",
    "NOTTY",        "NXIO",        "OPNOTSUPP",   "OVERFLOW",
    "PERM",         "PIPE",        "PROTO",       "PROTONOSUPPORT",
    "PROTOTYPE",    "RANGE",       "ROFS",        "SPIPE",
    "SRCH",         "STALE",       "TIME",        "TIMEDOUT",
    "TXTBSY",       "WOULDBLOCK",  "XDEV",
};

/// `errno_windows_names` — winsock error tags `node:os.constants.errno`
/// exposes when `Environment.isWindows`. Names are already the JS-facing
/// keys upstream puts on the constants object (no prefix transform).
pub const errno_windows_names = [_][]const u8{
    "WSAEINTR",               "WSAEBADF",         "WSAEACCES",
    "WSAEFAULT",              "WSAEINVAL",        "WSAEMFILE",
    "WSAEWOULDBLOCK",         "WSAEINPROGRESS",   "WSAEALREADY",
    "WSAENOTSOCK",            "WSAEDESTADDRREQ",  "WSAEMSGSIZE",
    "WSAEPROTOTYPE",          "WSAENOPROTOOPT",   "WSAEPROTONOSUPPORT",
    "WSAESOCKTNOSUPPORT",     "WSAEOPNOTSUPP",    "WSAEPFNOSUPPORT",
    "WSAEAFNOSUPPORT",        "WSAEADDRINUSE",    "WSAEADDRNOTAVAIL",
    "WSAENETDOWN",            "WSAENETUNREACH",   "WSAENETRESET",
    "WSAECONNABORTED",        "WSAECONNRESET",    "WSAENOBUFS",
    "WSAEISCONN",             "WSAENOTCONN",      "WSAESHUTDOWN",
    "WSAETOOMANYREFS",        "WSAETIMEDOUT",     "WSAECONNREFUSED",
    "WSAELOOP",               "WSAENAMETOOLONG",  "WSAEHOSTDOWN",
    "WSAEHOSTUNREACH",        "WSAENOTEMPTY",     "WSAEPROCLIM",
    "WSAEUSERS",              "WSAEDQUOT",        "WSAESTALE",
    "WSAEREMOTE",             "WSASYSNOTREADY",   "WSAVERNOTSUPPORTED",
    "WSANOTINITIALISED",      "WSAEDISCON",       "WSAENOMORE",
    "WSAECANCELLED",          "WSAEINVALIDPROCTABLE", "WSAEINVALIDPROVIDER",
    "WSAEPROVIDERFAILEDINIT", "WSASYSCALLFAILURE", "WSASERVICE_NOT_FOUND",
    "WSATYPE_NOT_FOUND",      "WSA_E_NO_MORE",    "WSA_E_CANCELLED",
    "WSAEREFUSED",
};

/// Canonical list of POSIX signal name suffixes `node:os.constants.signals`
/// exposes. Upstream's JSC bridge prepends "SIG" before putting them.
pub const signal_names = [_][]const u8{
    "HUP",    "INT",   "QUIT", "ILL",   "TRAP", "ABRT",  "IOT",  "BUS",
    "FPE",    "KILL",  "USR1", "SEGV",  "USR2", "PIPE",  "ALRM", "TERM",
    "CHLD",   "STKFLT","CONT", "STOP",  "TSTP", "BREAK", "TTIN", "TTOU",
    "URG",    "XCPU",  "XFSZ", "VTALRM","PROF", "WINCH", "IO",   "POLL",
    "LOST",   "PWR",   "INFO", "SYS",   "UNUSED",
};

/// `node:os.constants.dlopen` keys. Upstream's JSC bridge prepends "RTLD_".
pub const dlopen_names = [_][]const u8{ "LAZY", "NOW", "GLOBAL", "LOCAL", "DEEPBIND" };

/// `node:os.constants.priority.*` — pure integer constants.
pub const Priority = struct {
    pub const PRIORITY_LOW: i32 = 19;
    pub const PRIORITY_BELOW_NORMAL: i32 = 10;
    pub const PRIORITY_NORMAL: i32 = 0;
    pub const PRIORITY_ABOVE_NORMAL: i32 = -7;
    pub const PRIORITY_HIGH: i32 = -14;
    pub const PRIORITY_HIGHEST: i32 = -20;
};

/// `node:os.constants.UV_UDP_REUSEADDR`. Defined inline by upstream as `4`.
pub const UV_UDP_REUSEADDR: i32 = 4;

test "os_constants: getErrnoConstant resolves canonical tags" {
    // EINVAL is universal; ENOENT too. We only assert "non-null" — the
    // numeric values differ per OS so we don't hardcode them.
    try std.testing.expect(getErrnoConstant("INVAL") != null);
    try std.testing.expect(getErrnoConstant("NOENT") != null);
    try std.testing.expectEqual(@as(?comptime_int, null), getErrnoConstant("DEFINITELY_NOT_A_REAL_ERRNO_TAG"));
}

test "os_constants: getSignalsConstant resolves canonical tags" {
    try std.testing.expect(getSignalsConstant("HUP") != null);
    try std.testing.expect(getSignalsConstant("INT") != null);
    try std.testing.expectEqual(@as(?comptime_int, null), getSignalsConstant("NOT_A_SIGNAL"));
}

test "os_constants: Priority and UV_UDP_REUSEADDR carry node-spec values" {
    try std.testing.expectEqual(@as(i32, 19), Priority.PRIORITY_LOW);
    try std.testing.expectEqual(@as(i32, 0), Priority.PRIORITY_NORMAL);
    try std.testing.expectEqual(@as(i32, -20), Priority.PRIORITY_HIGHEST);
    try std.testing.expectEqual(@as(i32, 4), UV_UDP_REUSEADDR);
}

test "os_constants: name tables carry the documented entries" {
    try std.testing.expectEqual(@as(usize, 79), errno_names.len);
    try std.testing.expectEqual(@as(usize, 37), signal_names.len);
    try std.testing.expectEqual(@as(usize, 5), dlopen_names.len);
    try std.testing.expectEqual(@as(usize, 58), errno_windows_names.len);
    // Spot-check a few well-known entries.
    try std.testing.expectEqualStrings("NOENT", errno_names[44]);
    try std.testing.expectEqualStrings("HUP", signal_names[0]);
    try std.testing.expectEqualStrings("LAZY", dlopen_names[0]);
}
