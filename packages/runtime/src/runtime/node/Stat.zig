/// Stats and BigIntStats classes from node:fs
pub fn StatType(comptime big: bool) type {
    return struct {
        pub const new = bun.TrivialNew(@This());
        pub const deinit = bun.TrivialDeinit(@This());

        value: Syscall.PosixStat,

        const StatTimespec = bun.timespec;
        const Float = if (big) i64 else f64;

        pub inline fn init(stat_: *const Syscall.PosixStat) @This() {
            return .{ .value = stat_.* };
        }

        inline fn toNanoseconds(ts: StatTimespec) u64 {
            const exact: i128 = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            return @bitCast(@as(i64, @truncate(exact)));
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

        fn getBirthtime(stat_: *const Syscall.PosixStat) StatTimespec {
            return stat_.birthtim;
        }

        pub fn toJS(this: *const @This(), globalObject: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
            return statToJS(&this.value, globalObject);
        }

        pub fn getConstructor(globalObject: *jsc.JSGlobalObject) jsc.JSValue {
            return if (big) Bun__JSBigIntStatsObjectConstructor(globalObject) else Bun__JSStatsObjectConstructor(globalObject);
        }

        fn statToJS(stat_: *const Syscall.PosixStat, globalObject: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
            const aTime = stat_.atime();
            const mTime = stat_.mtime();
            const cTime = stat_.ctime();
            const bTime = getBirthtime(stat_);
            const atime_ms: Float = toTimeMS(aTime);
            const mtime_ms: Float = toTimeMS(mTime);
            const ctime_ms: Float = toTimeMS(cTime);
            const birthtime_ms: Float = toTimeMS(bTime);

            if (big) {
                const object = try bun.jsc.fromJSHostCall(globalObject, @src(), Bun__createJSBigIntStatsObject, .{
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
                });
                return setTimespecs(globalObject, object, .{ aTime, mTime, cTime, bTime });
            }

            const object = Bun__createJSStatsObject(
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
            return setTimespecs(globalObject, object, .{ aTime, mTime, cTime, bTime });
        }

        fn setTimespecs(globalObject: *jsc.JSGlobalObject, object: jsc.JSValue, times: [4]StatTimespec) bun.JSError!jsc.JSValue {
            var seconds: [4]i64 = undefined;
            var fractions: [4]i64 = undefined;
            for (times, 0..) |ts, i| {
                seconds[i] = if (Environment.isWindows) @as(u32, @bitCast(@as(i32, @truncate(ts.sec)))) else @intCast(ts.sec);
                fractions[i] = if (Environment.isWindows) @as(u32, @bitCast(@as(i32, @truncate(ts.nsec)))) else @intCast(ts.nsec);
            }
            return bun.jsc.fromJSHostCall(globalObject, @src(), Home__setStatsTimespecs, .{ globalObject, object, big, &seconds, &fractions });
        }
    };
}
extern fn Home__setStatsTimespecs(*jsc.JSGlobalObject, jsc.JSValue, bool, *const [4]i64, *const [4]i64) jsc.JSValue;
extern fn Bun__JSBigIntStatsObjectConstructor(*jsc.JSGlobalObject) jsc.JSValue;
extern fn Bun__JSStatsObjectConstructor(*jsc.JSGlobalObject) jsc.JSValue;

extern fn Bun__createJSStatsObject(
    globalObject: *jsc.JSGlobalObject,
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
) jsc.JSValue;

extern fn Bun__createJSBigIntStatsObject(
    globalObject: *jsc.JSGlobalObject,
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
) jsc.JSValue;

pub const StatsSmall = StatType(false);
pub const StatsBig = StatType(true);

/// Test-only: build a Stats/BigIntStats from a raw u64 ino via the real
/// statToJS path, so regression tests can exercise high-inode values without
/// a filesystem that hands them out.
pub fn createStatsForIno(globalObject: *jsc.JSGlobalObject, callFrame: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    const ino_arg, const big_arg = callFrame.argumentsAsArray(2);
    var stat_ = std.mem.zeroes(Syscall.PosixStat);
    stat_.ino = ino_arg.toUInt64NoTruncate();
    return try Stats.init(&stat_, big_arg.toBoolean()).toJSNewlyCreated(globalObject);
}

/// Union between `Stats` and `BigIntStats` where the type can be decided at runtime
pub const Stats = union(enum) {
    big: StatsBig,
    small: StatsSmall,

    pub inline fn init(stat_: *const Syscall.PosixStat, big: bool) Stats {
        if (big) {
            return .{ .big = StatsBig.init(stat_) };
        } else {
            return .{ .small = StatsSmall.init(stat_) };
        }
    }

    pub fn toJSNewlyCreated(this: *const Stats, globalObject: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
        return switch (this.*) {
            .big => this.big.toJS(globalObject),
            .small => this.small.toJS(globalObject),
        };
    }

    pub inline fn toJS(this: *Stats, globalObject: *jsc.JSGlobalObject) jsc.JSValue {
        _ = this;
        _ = globalObject;

        @compileError("Only use Stats.toJSNewlyCreated() or Stats.toJS() directly on a StatsBig or StatsSmall");
    }
};

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Syscall = bun.sys;
const jsc = bun.jsc;
