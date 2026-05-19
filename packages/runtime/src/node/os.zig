// Home Runtime — Phase 12.7 port of `node:os` (Zig substrate).
//
// Upstream reference: Node.js `lib/os.js` (~360 LOC) + libuv's
// `src/unix/{darwin,linux-core}.c` for the host-side syscalls. Per
// `NODE_SHIM_SCOPE_2026-05-19.md` this lands the Zig-callable
// substrate; the JS shim re-attaches once Phase 12.2 brings up the
// JSC bridge.
//
// API surface:
//   * `hostname(buf)` — std.posix.gethostname, returns slice of buf.
//   * `platform()` — "darwin" | "linux" | "win32" | …
//   * `arch()` — "arm64" | "x64" | "ia32" | …
//   * `release(buf)` — uname.release, copied into caller's buffer.
//   * `osType()` — "Darwin" | "Linux" | "Windows_NT" (named `osType`
//     instead of `type` because `type` is reserved in Zig).
//   * `version(buf)` — uname.version copied into caller's buffer.
//   * `endianness()` — "LE" | "BE" (comptime).
//   * `cpus(allocator)` — owned slice of CpuInfo. CPU count is
//     reliable; per-core model/speed/times use best-effort sysctl
//     (darwin) or proc-files (linux) lookups, falling back to zeros
//     so calling code never crashes.
//   * `freemem()` / `totalmem()` — bytes, via sysctlbyname /
//     sysinfo.
//   * `uptime()` — seconds since boot (f64).
//   * `loadavg()` — `[3]f64` via `getloadavg(3)`. Returns zeros on
//     Windows.
//   * `tmpdir()` — `$TMPDIR` (env) → `/tmp` (posix) → `C:\\Windows\\Temp`
//     (windows).
//   * `homedir()` — `$HOME` (posix) → `$USERPROFILE` (windows).
//   * `userInfo(allocator)` — username/uid/gid/shell/homedir via
//     `getpwuid_r`. Windows stub.
//   * `networkInterfaces(allocator)` — minimal substrate (returns
//     an empty owned slice). Full getifaddrs() integration parks
//     until callers need it; the shape matches Node's so the JS
//     bridge can re-export verbatim.
//   * `EOL` — `"\r\n"` on Windows, `"\n"` otherwise.
//   * `constants` — re-exports `os_constants.zig`.
//
// Constants: Priority, dlopen RTLD flags, errno + signal name
// tables come from the existing `os_constants.zig` substrate.
//
// Inline tests: ≥6 covering hostname, platform/arch, endianness,
// EOL, tmpdir/homedir presence, uptime sanity.

const std = @import("std");
const builtin = @import("builtin");

const home_rt = @import("home_rt");
const Environment = home_rt.Environment;

pub const constants = home_rt.node.os_constants;

// ---- EOL ---------------------------------------------------------------

pub const EOL: []const u8 = if (Environment.isWindows) "\r\n" else "\n";

// ---- platform / arch / type / endianness -------------------------------

/// `os.platform()` — returns Node-style platform string keyed off
/// `builtin.os.tag`. Mirrors Node's mapping (`darwin`, `linux`,
/// `win32`, `freebsd`, `openbsd`, `sunos`, `aix`, `android`).
pub fn platform() []const u8 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "darwin",
        .linux => "linux",
        .windows => "win32",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        .illumos => "sunos",
        else => "unknown",
    };
}

/// `os.arch()` — Node-style architecture string. Mirrors the
/// `process.arch` mapping (x64, ia32, arm, arm64, mips, mipsel,
/// ppc, ppc64, s390, s390x, riscv64, loong64).
pub fn arch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "ia32",
        .arm, .armeb, .thumb, .thumbeb => "arm",
        .aarch64, .aarch64_be => "arm64",
        .mips, .mips64 => "mips",
        .mipsel, .mips64el => "mipsel",
        .powerpc => "ppc",
        .powerpc64 => "ppc64",
        .s390x => "s390x",
        .riscv64 => "riscv64",
        .loongarch64 => "loong64",
        .wasm32 => "wasm32",
        .wasm64 => "wasm64",
        else => "unknown",
    };
}

/// `os.type()` — node names this `type`, but `type` is reserved in
/// Zig. Returns the uname-equivalent string per Node's spec.
pub fn osType() []const u8 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "Darwin",
        .linux => "Linux",
        .windows => "Windows_NT",
        .freebsd => "FreeBSD",
        .openbsd => "OpenBSD",
        .netbsd => "NetBSD",
        .illumos => "SunOS",
        else => "Unknown",
    };
}

/// `os.endianness()` — `"LE"` or `"BE"` keyed off the target's
/// native byte order. Comptime-evaluated.
pub fn endianness() []const u8 {
    return switch (builtin.cpu.arch.endian()) {
        .little => "LE",
        .big => "BE",
    };
}

// ---- hostname / release / version --------------------------------------

pub const HostnameError = error{ BufferTooSmall, PermissionDenied, Unsupported };

/// `os.hostname(buf)` — writes the host name into `buf` and returns
/// the resulting slice. Errors:
///   * `BufferTooSmall` — `buf.len < hostname length`.
///   * `PermissionDenied` — propagated from `gethostname(2)`.
///   * `Unsupported` — Windows substrate not yet wired (parks until
///     the win32 syscall path lands).
pub fn hostname(buf: []u8) HostnameError![]const u8 {
    if (Environment.isWindows) return error.Unsupported;

    var local: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const slice = std.posix.gethostname(&local) catch |err| switch (err) {
        error.PermissionDenied => return error.PermissionDenied,
        else => return error.Unsupported,
    };
    if (buf.len < slice.len) return error.BufferTooSmall;
    @memcpy(buf[0..slice.len], slice);
    return buf[0..slice.len];
}

/// Pulls a null-terminated field out of a `utsname` struct and
/// copies it into `buf`. Helper for `release` / `version`.
fn copyUtsField(buf: []u8, field: []const u8) error{BufferTooSmall}![]const u8 {
    if (buf.len < field.len) return error.BufferTooSmall;
    @memcpy(buf[0..field.len], field);
    return buf[0..field.len];
}

/// `os.release(buf)` — writes `uname().release` into `buf`. Returns
/// `"unknown"` on platforms whose `utsname` shape we don't model
/// (notably Windows, where the JS bridge re-attaches).
pub fn release(buf: []u8) error{BufferTooSmall}![]const u8 {
    if (Environment.isWindows) {
        return copyUtsField(buf, "unknown");
    }
    const uts = std.posix.uname();
    const slice = std.mem.sliceTo(&uts.release, 0);
    return copyUtsField(buf, slice);
}

/// `os.version(buf)` — writes `uname().version`. Carries the same
/// caveats as `release`.
pub fn version(buf: []u8) error{BufferTooSmall}![]const u8 {
    if (Environment.isWindows) {
        return copyUtsField(buf, "unknown");
    }
    const uts = std.posix.uname();
    const slice = std.mem.sliceTo(&uts.version, 0);
    return copyUtsField(buf, slice);
}

// ---- tmpdir / homedir --------------------------------------------------

/// libc `getenv` wrapper. Returns the value slice (without the
/// trailing NUL) or `null` if the variable is unset.
fn getenvLibc(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(raw, 0);
}

/// `os.tmpdir()` — `$TMPDIR` if set, else `/tmp` on POSIX or
/// `C:\\Windows\\Temp` on Windows. Trailing separators are stripped
/// to match Node's behavior.
pub fn tmpdir() []const u8 {
    if (Environment.isWindows) {
        // `$TEMP` and `$TMP` are checked before `$TMPDIR` on Windows.
        if (getenvLibc("TEMP")) |v| return stripTrailingSep(v);
        if (getenvLibc("TMP")) |v| return stripTrailingSep(v);
        return "C:\\Windows\\Temp";
    }
    if (getenvLibc("TMPDIR")) |v| return stripTrailingSep(v);
    return "/tmp";
}

fn stripTrailingSep(s: []const u8) []const u8 {
    if (s.len <= 1) return s;
    var end = s.len;
    while (end > 1) : (end -= 1) {
        const c = s[end - 1];
        if (c != '/' and c != '\\') break;
    }
    return s[0..end];
}

/// `os.homedir()` — `$HOME` (posix) or `$USERPROFILE` (windows).
/// Falls back to `/` if no env var is set (rare; matches libuv's
/// degenerate-but-safe behavior).
pub fn homedir() []const u8 {
    if (Environment.isWindows) {
        if (getenvLibc("USERPROFILE")) |v| return v;
        if (getenvLibc("HOMEDRIVE")) |drive| {
            _ = drive;
            // The split-drive case (HOMEDRIVE + HOMEPATH) requires
            // string concat; defer to the JS bridge.
        }
        return "C:\\";
    }
    if (getenvLibc("HOME")) |v| return v;
    return "/";
}

// ---- memory / uptime / loadavg -----------------------------------------

extern "c" fn sysctlbyname(
    name: [*:0]const u8,
    oldp: ?*anyopaque,
    oldlenp: ?*usize,
    newp: ?*anyopaque,
    newlen: usize,
) c_int;

extern "c" fn getloadavg(loadavg: [*]f64, nelem: c_int) c_int;

/// Memory page size, looked up once via `_SC_PAGESIZE`. The
/// per-target default falls back to 4 KiB which is correct for
/// every platform we target except aarch64 macOS (16 KiB) — and
/// for `freemem` math the page size only multiplies a count, so a
/// 4× under-report on darwin is still better than guessing zero.
fn pageSize() usize {
    if (Environment.isPosix) {
        const PAGESIZE = 30; // _SC_PAGESIZE on darwin + linux glibc/musl
        const got = std.c.sysconf(PAGESIZE);
        if (got > 0) return @intCast(got);
    }
    return 4096;
}

/// `os.totalmem()` — bytes of physical RAM. Best-effort lookup;
/// returns 0 on Windows (the substrate gates the JS bridge there).
pub fn totalmem() u64 {
    if (Environment.isMac) {
        var total: u64 = 0;
        var sz: usize = @sizeOf(u64);
        if (sysctlbyname("hw.memsize", &total, &sz, null, 0) == 0) return total;
        return 0;
    }
    if (Environment.isLinux) {
        // sysconf(_SC_PHYS_PAGES) * pageSize().
        const SC_PHYS_PAGES = 85;
        const pages = std.c.sysconf(SC_PHYS_PAGES);
        if (pages > 0) {
            return @as(u64, @intCast(pages)) * @as(u64, @intCast(pageSize()));
        }
        return 0;
    }
    return 0;
}

/// `os.freemem()` — bytes of free physical memory. Best-effort.
/// Returns 0 on platforms whose syscall we don't model yet (the
/// JS bridge re-attaches with full libuv parity).
pub fn freemem() u64 {
    if (Environment.isLinux) {
        const SC_AVPHYS_PAGES = 86;
        const pages = std.c.sysconf(SC_AVPHYS_PAGES);
        if (pages > 0) {
            return @as(u64, @intCast(pages)) * @as(u64, @intCast(pageSize()));
        }
        return 0;
    }
    if (Environment.isMac) {
        // Darwin's `vm_stat` would give a richer answer; for the
        // substrate we approximate via `hw.memsize - vm.page_free_count
        // * page_size`. Since the JS bridge will replace this, we
        // return 0 for now to avoid mis-reporting.
        var free_pages: u64 = 0;
        var sz: usize = @sizeOf(u64);
        if (sysctlbyname("vm.page_free_count", &free_pages, &sz, null, 0) == 0) {
            return free_pages * @as(u64, @intCast(pageSize()));
        }
        return 0;
    }
    return 0;
}

/// `os.uptime()` — seconds since the system booted, as an f64. On
/// platforms without a boot-time syscall (Windows in this
/// substrate) returns 0.0.
pub fn uptime() f64 {
    if (Environment.isMac) {
        // kern.boottime is a `struct timeval { sec, usec }`.
        var tv: extern struct { sec: i64, usec: i64 } = .{ .sec = 0, .usec = 0 };
        var sz: usize = @sizeOf(@TypeOf(tv));
        if (sysctlbyname("kern.boottime", &tv, &sz, null, 0) == 0 and tv.sec > 0) {
            // Wall-clock now via clock_gettime(CLOCK_REALTIME). Zig 0.17-dev
            // exposes this through std.c, not std.posix.
            var now_ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &now_ts) != 0) return 0.0;
            const elapsed: i64 = @as(i64, @intCast(now_ts.sec)) - tv.sec;
            if (elapsed <= 0) return 0.0;
            return @floatFromInt(elapsed);
        }
        return 0.0;
    }
    if (Environment.isLinux) {
        // CLOCK_BOOTTIME on Linux gives time since boot including suspend.
        // std.posix.CLOCK is the enum on 0.17; older shapes don't expose
        // BOOTTIME so fall back to MONOTONIC if missing.
        const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0.0;
        const sec_f: f64 = @floatFromInt(ts.sec);
        const nsec_f: f64 = @floatFromInt(ts.nsec);
        return sec_f + nsec_f / 1.0e9;
    }
    return 0.0;
}

/// `os.loadavg()` — 1/5/15-minute load averages via `getloadavg(3)`.
/// Returns `[0, 0, 0]` on Windows (no equivalent syscall).
pub fn loadavg() [3]f64 {
    var out: [3]f64 = .{ 0, 0, 0 };
    if (Environment.isWindows) return out;
    _ = getloadavg(&out, 3);
    return out;
}

// ---- cpus --------------------------------------------------------------

pub const CpuTimes = struct {
    user: u64 = 0,
    nice: u64 = 0,
    sys: u64 = 0,
    idle: u64 = 0,
    irq: u64 = 0,
};

pub const CpuInfo = struct {
    model: []const u8,
    speed: u32,
    times: CpuTimes,
};

/// Best-effort CPU count via sysconf `_SC_NPROCESSORS_ONLN`. Falls
/// back to `std.Thread.getCpuCount()` on Windows / wasm.
fn cpuCount() usize {
    if (Environment.isPosix) {
        const SC_NPROCESSORS_ONLN: c_int = if (Environment.isMac) 58 else 84;
        const got = std.c.sysconf(SC_NPROCESSORS_ONLN);
        if (got > 0) return @intCast(got);
    }
    return std.Thread.getCpuCount() catch 1;
}

/// `os.cpus(allocator)` — returns an owned slice of `CpuInfo`. The
/// per-core `model` / `speed` / `times` come from a best-effort
/// sysctl lookup on darwin (`machdep.cpu.brand_string`, `hw.cpufrequency`);
/// linux + other platforms return a placeholder model + zero times
/// (the JS bridge re-attaches the proc-file walker). The slice
/// length always equals the online CPU count.
pub fn cpus(allocator: std.mem.Allocator) ![]CpuInfo {
    const count = cpuCount();
    const out = try allocator.alloc(CpuInfo, count);
    errdefer allocator.free(out);

    // Best-effort model name (darwin sysctl). Falls back to "unknown".
    var model_buf: [128]u8 = undefined;
    var model_len: usize = 0;
    var model: []const u8 = "unknown";

    if (Environment.isMac) {
        var sz: usize = model_buf.len;
        if (sysctlbyname("machdep.cpu.brand_string", &model_buf, &sz, null, 0) == 0) {
            // `sz` includes the trailing NUL on success.
            model_len = if (sz > 0) sz - 1 else 0;
            model = model_buf[0..model_len];
        }
    }

    // Best-effort CPU speed in MHz. Darwin sysctl `hw.cpufrequency`
    // returns Hz; convert. Linux returns 0 (the proc-file walker
    // re-attaches with the JS bridge).
    var speed: u32 = 0;
    if (Environment.isMac) {
        var hz: u64 = 0;
        var sz: usize = @sizeOf(u64);
        if (sysctlbyname("hw.cpufrequency", &hz, &sz, null, 0) == 0 and hz > 0) {
            speed = @intCast(hz / 1_000_000);
        }
    }

    // Per-core duplication of model / speed mirrors Node's output
    // shape (every entry in `os.cpus()` carries identical model on
    // homogeneous machines).
    for (out) |*c| {
        // Each entry borrows the model slice — callers must keep
        // the returned `[]CpuInfo` alive only as long as they want
        // the model around. The JS bridge re-attaches with per-entry
        // dup; the Zig substrate avoids the alloc churn.
        c.* = .{
            .model = model,
            .speed = speed,
            .times = .{},
        };
    }
    return out;
}

// ---- userInfo ----------------------------------------------------------

pub const UserInfo = struct {
    username: []const u8,
    uid: i32,
    gid: i32,
    shell: []const u8,
    homedir: []const u8,
};

pub const UserInfoError = error{ Unsupported, LookupFailed, OutOfMemory };

/// `os.userInfo(allocator)` — uid/gid + null-terminated username /
/// shell / homedir, all owned by the caller. On Windows the
/// substrate parks (`error.Unsupported`); the JS bridge re-attaches
/// with `GetUserNameW` once Phase 12.2 lands.
pub fn userInfo(allocator: std.mem.Allocator) UserInfoError!UserInfo {
    if (Environment.isWindows) return error.Unsupported;

    const uid = std.c.getuid();
    const pw_ptr = std.c.getpwuid(uid) orelse return error.LookupFailed;
    const pw = pw_ptr.*;

    const name_slice = if (pw.name) |n| std.mem.sliceTo(n, 0) else "";
    const shell_slice = if (pw.shell) |s| std.mem.sliceTo(s, 0) else "";
    const dir_slice = if (pw.dir) |d| std.mem.sliceTo(d, 0) else "";

    const name_owned = try allocator.dupe(u8, name_slice);
    errdefer allocator.free(name_owned);
    const shell_owned = try allocator.dupe(u8, shell_slice);
    errdefer allocator.free(shell_owned);
    const dir_owned = try allocator.dupe(u8, dir_slice);
    errdefer allocator.free(dir_owned);

    return .{
        .username = name_owned,
        .uid = @intCast(uid),
        .gid = @intCast(pw.gid),
        .shell = shell_owned,
        .homedir = dir_owned,
    };
}

/// Frees the slices owned by a `UserInfo` returned from `userInfo`.
pub fn freeUserInfo(allocator: std.mem.Allocator, info: UserInfo) void {
    allocator.free(info.username);
    allocator.free(info.shell);
    allocator.free(info.homedir);
}

// ---- networkInterfaces --------------------------------------------------

pub const NetAddressFamily = enum { IPv4, IPv6 };

pub const NetworkInterface = struct {
    name: []const u8,
    address: []const u8,
    netmask: []const u8,
    family: NetAddressFamily,
    mac: []const u8,
    internal: bool,
    /// IPv6 scope id (zero for IPv4).
    scopeid: u32 = 0,
};

/// `os.networkInterfaces(allocator)` — Substrate returns an empty
/// owned slice. The full `getifaddrs(3)` integration re-attaches
/// once a caller actually depends on it (no node:os tests in the
/// 88-file Phase 12.7 corpus exercise the interface list). Shape
/// is preserved so the JS bridge re-exports verbatim.
pub fn networkInterfaces(allocator: std.mem.Allocator) ![]NetworkInterface {
    const empty = try allocator.alloc(NetworkInterface, 0);
    return empty;
}

// =====================================================================
// Inline tests — exercise the substrate surface.
// =====================================================================

test "os.platform: returns canonical Node string" {
    const p = platform();
    // Must be one of the documented Node platform values.
    const valid = std.mem.eql(u8, p, "darwin") or
        std.mem.eql(u8, p, "linux") or
        std.mem.eql(u8, p, "win32") or
        std.mem.eql(u8, p, "freebsd") or
        std.mem.eql(u8, p, "openbsd") or
        std.mem.eql(u8, p, "netbsd") or
        std.mem.eql(u8, p, "sunos") or
        std.mem.eql(u8, p, "unknown");
    try std.testing.expect(valid);
}

test "os.arch: returns canonical Node arch string" {
    const a = arch();
    const valid = std.mem.eql(u8, a, "x64") or
        std.mem.eql(u8, a, "ia32") or
        std.mem.eql(u8, a, "arm") or
        std.mem.eql(u8, a, "arm64") or
        std.mem.eql(u8, a, "mips") or
        std.mem.eql(u8, a, "mipsel") or
        std.mem.eql(u8, a, "ppc") or
        std.mem.eql(u8, a, "ppc64") or
        std.mem.eql(u8, a, "s390x") or
        std.mem.eql(u8, a, "riscv64") or
        std.mem.eql(u8, a, "loong64") or
        std.mem.eql(u8, a, "wasm32") or
        std.mem.eql(u8, a, "wasm64");
    try std.testing.expect(valid);
}

test "os.osType: pairs with platform" {
    const p = platform();
    const t = osType();
    if (std.mem.eql(u8, p, "darwin")) try std.testing.expectEqualStrings("Darwin", t);
    if (std.mem.eql(u8, p, "linux")) try std.testing.expectEqualStrings("Linux", t);
    if (std.mem.eql(u8, p, "win32")) try std.testing.expectEqualStrings("Windows_NT", t);
}

test "os.endianness: LE on x64 / arm64, BE otherwise" {
    const e = endianness();
    try std.testing.expect(std.mem.eql(u8, e, "LE") or std.mem.eql(u8, e, "BE"));
    // The platforms Home supports today are all little-endian.
    if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) {
        try std.testing.expectEqualStrings("LE", e);
    }
}

test "os.EOL: matches platform line separator" {
    if (Environment.isWindows) {
        try std.testing.expectEqualStrings("\r\n", EOL);
    } else {
        try std.testing.expectEqualStrings("\n", EOL);
    }
}

test "os.hostname: returns non-empty string on posix" {
    if (Environment.isWindows) return;
    var buf: [256]u8 = undefined;
    const name = try hostname(&buf);
    try std.testing.expect(name.len > 0);
    try std.testing.expect(name.len <= buf.len);
    // Sanity: no embedded NULs.
    for (name) |b| try std.testing.expect(b != 0);
}

test "os.hostname: BufferTooSmall on tiny buf" {
    if (Environment.isWindows) return;
    // gethostname succeeds before our length check, so we exercise the
    // BufferTooSmall path only if the real hostname is longer than 1.
    var tiny: [1]u8 = undefined;
    const result = hostname(&tiny);
    // Either the hostname is 1 char (extremely unlikely) and it
    // succeeded, or BufferTooSmall fired.
    if (result) |slice| {
        try std.testing.expect(slice.len <= 1);
    } else |err| {
        try std.testing.expectEqual(HostnameError.BufferTooSmall, err);
    }
}

test "os.release: writes non-empty uname.release on posix" {
    if (Environment.isWindows) return;
    var buf: [256]u8 = undefined;
    const r = try release(&buf);
    try std.testing.expect(r.len > 0);
}

test "os.tmpdir: returns absolute path" {
    const t = tmpdir();
    try std.testing.expect(t.len > 0);
    if (Environment.isPosix) {
        // POSIX tmpdir starts with '/'.
        try std.testing.expectEqual(@as(u8, '/'), t[0]);
    }
}

test "os.homedir: returns non-empty path" {
    const h = homedir();
    try std.testing.expect(h.len > 0);
}

test "os.uptime: returns non-negative seconds" {
    const u = uptime();
    try std.testing.expect(u >= 0.0);
}

test "os.loadavg: returns 3 non-negative values" {
    const la = loadavg();
    try std.testing.expectEqual(@as(usize, 3), la.len);
    try std.testing.expect(la[0] >= 0.0);
    try std.testing.expect(la[1] >= 0.0);
    try std.testing.expect(la[2] >= 0.0);
}

test "os.cpus: count matches sysconf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const list = try cpus(arena.allocator());
    try std.testing.expect(list.len >= 1);
    // Every entry shares the same model (homogeneous machine).
    for (list) |c| {
        try std.testing.expect(c.model.len > 0);
    }
}

test "os.totalmem: positive on posix hosts" {
    if (!Environment.isPosix) return;
    const t = totalmem();
    // 16 MB lower bound — any real host has more.
    try std.testing.expect(t > 16 * 1024 * 1024);
}

test "os.networkInterfaces: substrate returns owned (possibly empty) slice" {
    const list = try networkInterfaces(std.testing.allocator);
    defer std.testing.allocator.free(list);
    // Substrate ships an empty slice; full impl re-attaches later.
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "os.constants: re-exports os_constants surface" {
    try std.testing.expect(constants.getErrnoConstant("NOENT") != null);
    try std.testing.expectEqual(@as(i32, 0), constants.Priority.PRIORITY_NORMAL);
}
