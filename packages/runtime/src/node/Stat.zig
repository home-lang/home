// Copied from bun/src/runtime/node/Stat.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// **Partial port (pure conversion math + extern stubs).**
//
// Upstream `Stat.zig` implements the `node:fs.Stats` / `BigIntStats`
// wrapper classes. It bundles two concerns:
//
//   1. Pure arithmetic helpers (`toNanoseconds`, `toTimeMS`) that
//      collapse a `(sec, nsec)` pair into either a `f64` millisecond
//      double (the small Stats variant) or an `i64` nanosecond integer
//      (the BigInt variant), with Windows' Y2038-truncating semantics.
//   2. The JSC bridge (`toJS` / `statToJS`) — calls four C++ helpers
//      (`Bun__createJSStatsObject`, `Bun__createJSBigIntStatsObject`,
//      `Bun__JSStatsObjectConstructor`, `Bun__JSBigIntStatsObjectConstructor`)
//      that allocate the JS-side `Stats` cell and the `getConstructor`
//      accessor that the codegen layer needs.
//
// Only (1) is ported here: `StatType(big)` is faithfully reproduced with
// its `toNanoseconds` / `toTimeMS` / `init` / `getBirthtime` helpers
// (verbatim semantics on POSIX, Windows Y2038 truncation match), and the
// `Stats` union dispatch shell. The JSC path stays as `extern fn`
// declarations + a typed `toJS` stub that returns an opaque `JSValue`-
// shaped placeholder via `@compileError` when called — so callers that
// only need pure conversion can `@import` this file today, and the
// re-attach with the codegen layer is a one-line swap of the externs to
// real bodies.
//
// **PosixStat shape (stubbed).** Upstream pulls `bun.sys.PosixStat` from
// `sys/lib.rs`, which is a libc `struct stat` mirror with platform-
// specific layout. Home's `sys/maybe.zig` exposes `FileKind` /
// `kindFromMode` but not the full `stat` struct yet, so this file
// declares a minimal `PosixStat` shape (just the fields the conversion
// helpers read). The real shape replaces it byte-for-byte when the
// `bun.sys.PosixStat` substrate ports; the field layout matches
// upstream so the swap is non-breaking.
//
// **`bun.timespec` shape (stubbed inline).** Upstream uses the
// `bun.timespec` (sec/nsec extern struct with `ns()` / `nsSigned()`
// helpers). Home doesn't expose a `bun.timespec` namespace yet, so the
// helpers are inlined verbatim — when Home lands `bun.timespec`, swap
// the inline block for `home_rt.timespec`.
//
// Imports rewritten: @import("bun") → @import("home_rt") for the
// `Environment` namespace.

const std = @import("std");

const home_rt = @import("home_rt");
const Environment = home_rt.Environment;

// ---- Minimal PosixStat / timespec shape -----------------------------------
//
// Mirrors what upstream's `Syscall.PosixStat` and `bun.timespec` provide
// to the conversion helpers. Field names + meanings are 1:1 with
// upstream so the swap to the real substrate is purely a declaration
// change.

/// `bun.timespec` shape — sec/nsec pair with the two helpers
/// `toNanoseconds()` reads.
pub const StatTimespec = extern struct {
    sec: i64,
    nsec: i64,

    /// `bun.timespec.ns` — clamps negative `sec` to 0, saturates on
    /// overflow rather than UB. 584 years of u64-ns headroom.
    pub fn ns(this: *const StatTimespec) u64 {
        if (this.sec <= 0) {
            return @max(this.nsec, 0);
        }
        const s_ns = std.math.mul(
            u64,
            @intCast(@max(this.sec, 0)),
            std.time.ns_per_s,
        ) catch return std.math.maxInt(u64);
        return std.math.add(u64, s_ns, @intCast(@max(this.nsec, 0))) catch
            return std.math.maxInt(i64);
    }

    /// `bun.timespec.nsSigned` — wrapping i64 multiplication; matches
    /// upstream's behaviour for the negative-`sec` path.
    pub fn nsSigned(this: *const StatTimespec) i64 {
        const ns_per_sec = this.sec *% std.time.ns_per_s;
        const ns_from_nsec = @divFloor(this.nsec, 1_000_000);
        return ns_per_sec +% ns_from_nsec;
    }
};

/// Minimum subset of `bun.sys.PosixStat` the conversion helpers read.
/// Real shape (per-OS field layout) re-lands when the syscall substrate
/// is ported.
pub const PosixStat = struct {
    dev: u64 = 0,
    ino: u64 = 0,
    mode: u64 = 0,
    nlink: u64 = 0,
    uid: u64 = 0,
    gid: u64 = 0,
    rdev: u64 = 0,
    size: u64 = 0,
    blksize: u64 = 0,
    blocks: u64 = 0,
    /// Access time.
    atim: StatTimespec = .{ .sec = 0, .nsec = 0 },
    /// Modify time.
    mtim: StatTimespec = .{ .sec = 0, .nsec = 0 },
    /// Status-change time.
    ctim: StatTimespec = .{ .sec = 0, .nsec = 0 },
    /// Birth (creation) time — populated by `getBirthtime`.
    birthtim: StatTimespec = .{ .sec = 0, .nsec = 0 },

    pub fn atime(this: *const PosixStat) StatTimespec {
        return this.atim;
    }

    pub fn mtime(this: *const PosixStat) StatTimespec {
        return this.mtim;
    }

    pub fn ctime(this: *const PosixStat) StatTimespec {
        return this.ctim;
    }
};

// ---- JSC bridge externs (stubbed) -----------------------------------------
//
// Verbatim from upstream — these are the C++ entry points the JS-side
// Stats / BigIntStats constructors call into. Declarations only; not
// linked yet (no JSC backend in Home). `toJS` is the public surface
// that exercises them.

/// Opaque placeholder for `jsc.JSGlobalObject` — re-aliased to the real
/// type once the JSC surface re-lands.
pub const JSGlobalObject = opaque {};
/// Opaque placeholder for `jsc.JSValue` — kept i64-shaped to match
/// upstream's enum representation.
pub const JSValue = enum(i64) { _ };

extern fn Bun__JSBigIntStatsObjectConstructor(*JSGlobalObject) JSValue;
extern fn Bun__JSStatsObjectConstructor(*JSGlobalObject) JSValue;

extern fn Bun__createJSStatsObject(
    globalObject: *JSGlobalObject,
    dev: u64,
    ino: u64,
    mode: u64,
    nlink: u64,
    uid: u64,
    gid: u64,
    rdev: u64,
    size: u64,
    blksize: u64,
    blocks: u64,
    atimeMs: f64,
    mtimeMs: f64,
    ctimeMs: f64,
    birthtimeMs: f64,
) JSValue;

extern fn Bun__createJSBigIntStatsObject(
    globalObject: *JSGlobalObject,
    dev: u64,
    ino: u64,
    mode: u64,
    nlink: u64,
    uid: u64,
    gid: u64,
    rdev: u64,
    size: u64,
    blksize: u64,
    blocks: u64,
    atimeMs: i64,
    mtimeMs: i64,
    ctimeMs: i64,
    birthtimeMs: i64,
    atimeNs: u64,
    mtimeNs: u64,
    ctimeNs: u64,
    birthtimeNs: u64,
) JSValue;

// ---- StatType(big) --------------------------------------------------------

/// Generates the `Stats` (small) or `BigIntStats` (big) class shape.
pub fn StatType(comptime big: bool) type {
    return struct {
        value: PosixStat,

        const Float = if (big) i64 else f64;

        pub inline fn init(stat_: *const PosixStat) @This() {
            return .{ .value = stat_.* };
        }

        inline fn toNanoseconds(ts: StatTimespec) u64 {
            if (ts.sec < 0) {
                return @intCast(@max((StatTimespec{
                    .sec = @intCast(ts.sec),
                    .nsec = @intCast(ts.nsec),
                }).nsSigned(), 0));
            }

            return (StatTimespec{
                .sec = @intCast(ts.sec),
                .nsec = @intCast(ts.nsec),
            }).ns();
        }

        fn toTimeMS(ts: StatTimespec) Float {
            // On windows, Node.js purposefully misinterprets time values
            // > On win32, time is stored in uint64_t and starts from 1601-01-01.
            // > libuv calculates tv_sec and tv_nsec from it and converts to signed long,
            // > which causes Y2038 overflow. On the other platforms it is safe to treat
            // > negative values as pre-epoch time.
            const tv_sec = if (Environment.isWindows) @as(u32, @bitCast(@as(i32, @truncate(ts.sec)))) else ts.sec;
            const tv_nsec = if (Environment.isWindows) @as(u32, @bitCast(@as(i32, @truncate(ts.nsec)))) else ts.nsec;
            if (big) {
                const sec: i64 = tv_sec;
                const nsec: i64 = tv_nsec;
                return @as(i64, sec * std.time.ms_per_s) +|
                    @as(i64, @divTrunc(nsec, std.time.ns_per_ms));
            } else {
                // Use floating-point arithmetic to preserve sub-millisecond precision.
                // Node.js returns fractional milliseconds (e.g. 1773248895434.0544).
                const sec_ms: f64 = @as(f64, @floatFromInt(tv_sec)) * 1000.0;
                const nsec_ms: f64 = @as(f64, @floatFromInt(tv_nsec)) / 1_000_000.0;
                return sec_ms + nsec_ms;
            }
        }

        fn getBirthtime(stat_: *const PosixStat) StatTimespec {
            return stat_.birthtim;
        }

        /// Materialise this Stats record on the JS heap. Requires the
        /// JSC backend to be linked — until then the call sites are
        /// `@compileError`-blocked rather than silently broken.
        pub fn toJS(this: *const @This(), globalObject: *JSGlobalObject) JSValue {
            return statToJS(&this.value, globalObject);
        }

        pub fn getConstructor(globalObject: *JSGlobalObject) JSValue {
            return if (big) Bun__JSBigIntStatsObjectConstructor(globalObject) else Bun__JSStatsObjectConstructor(globalObject);
        }

        fn statToJS(stat_: *const PosixStat, globalObject: *JSGlobalObject) JSValue {
            const aTime = stat_.atime();
            const mTime = stat_.mtime();
            const cTime = stat_.ctime();
            const bTime = getBirthtime(stat_);
            const atime_ms: Float = toTimeMS(aTime);
            const mtime_ms: Float = toTimeMS(mTime);
            const ctime_ms: Float = toTimeMS(cTime);
            const birthtime_ms: Float = toTimeMS(bTime);

            if (big) {
                return Bun__createJSBigIntStatsObject(
                    globalObject,
                    stat_.dev,
                    stat_.ino,
                    stat_.mode,
                    stat_.nlink,
                    stat_.uid,
                    stat_.gid,
                    stat_.rdev,
                    stat_.size,
                    stat_.blksize,
                    stat_.blocks,
                    atime_ms,
                    mtime_ms,
                    ctime_ms,
                    birthtime_ms,
                    toNanoseconds(aTime),
                    toNanoseconds(mTime),
                    toNanoseconds(cTime),
                    toNanoseconds(bTime),
                );
            }

            return Bun__createJSStatsObject(
                globalObject,
                stat_.dev,
                stat_.ino,
                stat_.mode,
                stat_.nlink,
                stat_.uid,
                stat_.gid,
                stat_.rdev,
                stat_.size,
                stat_.blksize,
                stat_.blocks,
                atime_ms,
                mtime_ms,
                ctime_ms,
                birthtime_ms,
            );
        }

        // Test-only: expose the pure-arithmetic helpers so tests can
        // drive them without going through statToJS.
        pub const testToTimeMS = toTimeMS;
        pub const testToNanoseconds = toNanoseconds;
    };
}

pub const StatsSmall = StatType(false);
pub const StatsBig = StatType(true);

/// Union between `Stats` and `BigIntStats` where the type can be decided at runtime.
pub const Stats = union(enum) {
    big: StatsBig,
    small: StatsSmall,

    pub inline fn init(stat_: *const PosixStat, big: bool) Stats {
        if (big) {
            return .{ .big = StatsBig.init(stat_) };
        } else {
            return .{ .small = StatsSmall.init(stat_) };
        }
    }

    pub fn toJSNewlyCreated(this: *const Stats, globalObject: *JSGlobalObject) JSValue {
        return switch (this.*) {
            .big => this.big.toJS(globalObject),
            .small => this.small.toJS(globalObject),
        };
    }
};

// ---- Tests ----------------------------------------------------------------

test "Stat: toTimeMS small-variant preserves sub-millisecond precision on POSIX" {
    if (Environment.isWindows) return error.SkipZigTest;
    // 1773248895 sec + 543400 ns => 1_773_248_895_000.5434 ms
    const ts: StatTimespec = .{ .sec = 1_773_248_895, .nsec = 543_400 };
    const ms = StatsSmall.testToTimeMS(ts);
    // Allow 1e-6 tolerance — IEEE 754 round-off.
    const expected: f64 = 1_773_248_895_000.0 + (543_400.0 / 1_000_000.0);
    try std.testing.expect(@abs(ms - expected) < 1e-6);
}

test "Stat: toTimeMS big-variant returns integer ms (truncating sub-ms)" {
    if (Environment.isWindows) return error.SkipZigTest;
    // 999 ns < 1 ms => @divTrunc drops it.
    const ts: StatTimespec = .{ .sec = 10, .nsec = 999 };
    const ms = StatsBig.testToTimeMS(ts);
    try std.testing.expectEqual(@as(i64, 10_000), ms);
}

test "Stat: toNanoseconds handles non-negative timespec via timespec.ns" {
    // 5 sec + 250_000_000 ns => 5_250_000_000 ns
    const ts: StatTimespec = .{ .sec = 5, .nsec = 250_000_000 };
    const got = StatsSmall.testToNanoseconds(ts);
    try std.testing.expectEqual(@as(u64, 5_250_000_000), got);
}

test "Stat: Stats union dispatches to the correct StatType variant" {
    var raw: PosixStat = .{};
    raw.ino = 0xDEAD_BEEF_CAFE;
    const small = Stats.init(&raw, false);
    const big = Stats.init(&raw, true);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE), small.small.value.ino);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE), big.big.value.ino);
}

test "Stat: StatTimespec.ns clamps negative sec to nsec, saturates at maxInt(u64)" {
    // Negative sec: the helper returns the (clamped) nsec.
    const ts_neg: StatTimespec = .{ .sec = -1, .nsec = 42 };
    try std.testing.expectEqual(@as(u64, 42), ts_neg.ns());

    // Saturation: sec close to maxInt(i64) overflows u64-ns math.
    const ts_sat: StatTimespec = .{ .sec = std.math.maxInt(i64) / 2, .nsec = 0 };
    try std.testing.expectEqual(std.math.maxInt(u64), ts_sat.ns());
}
