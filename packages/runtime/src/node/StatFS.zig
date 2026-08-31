// Copied from bun/src/runtime/node/StatFS.zig. MIT — see ../cli/LICENSE.bun.md.
// Home retains Bun's JSC extern names while the native ABI lives in sys/StatFS.zig.

const std = @import("std");

const home_rt = @import("home");
const Environment = home_rt.Environment;

pub const StatFSPayload = @import("../sys/StatFS.zig").StatFS;

// ---- JSC bridge externs (stubbed) -----------------------------------------

/// Opaque placeholder for `jsc.JSGlobalObject` — re-aliased to the real
/// type once the JSC surface re-lands.
pub const JSGlobalObject = opaque {};
/// Opaque placeholder for `jsc.JSValue` — i64-shaped to match upstream's
/// enum repr.
pub const JSValue = enum(i64) { _ };

extern fn Bun__JSBigIntStatFSObjectConstructor(*JSGlobalObject) JSValue;
extern fn Bun__JSStatFSObjectConstructor(*JSGlobalObject) JSValue;

extern fn Bun__createJSStatFSObject(
    globalObject: *JSGlobalObject,
    fstype: i64,
    bsize: i64,
    blocks: i64,
    bfree: i64,
    bavail: i64,
    files: i64,
    ffree: i64,
) JSValue;

extern fn Bun__createJSBigIntStatFSObject(
    globalObject: *JSGlobalObject,
    fstype: i64,
    bsize: i64,
    blocks: i64,
    bfree: i64,
    bavail: i64,
    files: i64,
    ffree: i64,
) JSValue;

// ---- StatFSType(big) ------------------------------------------------------

/// StatFS and BigIntStatFS classes from node:fs.
pub fn StatFSType(comptime big: bool) type {
    const Int = if (big) i64 else i32;

    return struct {

        // Common fields between Linux and macOS (and Windows via libuv).
        _fstype: Int,
        _bsize: Int,
        _blocks: Int,
        _bfree: Int,
        _bavail: Int,
        _files: Int,
        _ffree: Int,

        const This = @This();

        pub fn toJS(this: *const This, globalObject: *JSGlobalObject) JSValue {
            return statfsToJS(this, globalObject);
        }

        fn statfsToJS(this: *const This, globalObject: *JSGlobalObject) JSValue {
            if (big) {
                return Bun__createJSBigIntStatFSObject(
                    globalObject,
                    this._fstype,
                    this._bsize,
                    this._blocks,
                    this._bfree,
                    this._bavail,
                    this._files,
                    this._ffree,
                );
            }

            return Bun__createJSStatFSObject(
                globalObject,
                this._fstype,
                this._bsize,
                this._blocks,
                this._bfree,
                this._bavail,
                this._files,
                this._ffree,
            );
        }

        pub fn init(statfs_: *const StatFSPayload) This {
            // The native layouts vary, but these seven fields are common.
            if (comptime Environment.isWasi) {
                @compileError("Unsupported OS");
            }
            const fstype_ = statfs_.f_type;
            const bsize_ = statfs_.f_bsize;
            const blocks_ = statfs_.f_blocks;
            const bfree_ = statfs_.f_bfree;
            const bavail_ = statfs_.f_bavail;
            const files_ = statfs_.f_files;
            const ffree_ = statfs_.f_ffree;
            return .{
                ._fstype = @truncate(@as(i64, @intCast(fstype_))),
                ._bsize = @truncate(@as(i64, @intCast(bsize_))),
                ._blocks = @truncate(@as(i64, @intCast(blocks_))),
                ._bfree = @truncate(@as(i64, @intCast(bfree_))),
                ._bavail = @truncate(@as(i64, @intCast(bavail_))),
                ._files = @truncate(@as(i64, @intCast(files_))),
                ._ffree = @truncate(@as(i64, @intCast(ffree_))),
            };
        }
    };
}

pub const StatFSSmall = StatFSType(false);
pub const StatFSBig = StatFSType(true);

/// Union between `StatFS` and `BigIntStatFS` where the type can be decided at runtime.
pub const StatFS = union(enum) {
    big: StatFSBig,
    small: StatFSSmall,

    pub inline fn init(stat_: *const StatFSPayload, big: bool) StatFS {
        if (big) {
            return .{ .big = StatFSBig.init(stat_) };
        } else {
            return .{ .small = StatFSSmall.init(stat_) };
        }
    }

    pub fn toJSNewlyCreated(this: *const StatFS, globalObject: *JSGlobalObject) JSValue {
        return switch (this.*) {
            .big => |*big| big.toJS(globalObject),
            .small => |*small| small.toJS(globalObject),
        };
    }
};

// ---- Tests ----------------------------------------------------------------

test "StatFS: small variant truncates to i32 cells" {
    var payload = std.mem.zeroes(StatFSPayload);
    payload.f_type = 0x8000_0001; // > i32 max — exercise the @truncate
    payload.f_bsize = 4096;
    payload.f_blocks = 1_000_000;
    payload.f_bfree = 500_000;
    payload.f_bavail = 400_000;
    payload.f_files = 100_000;
    payload.f_ffree = 99_000;
    const small = StatFSSmall.init(&payload);
    try std.testing.expectEqual(@as(i32, -2_147_483_647), small._fstype);
    try std.testing.expectEqual(@as(i32, 4096), small._bsize);
    try std.testing.expectEqual(@as(i32, 1_000_000), small._blocks);
}

test "StatFS: big variant preserves full i64" {
    var payload = std.mem.zeroes(StatFSPayload);
    payload.f_type = 0x8000_0001;
    payload.f_bsize = 4096;
    payload.f_blocks = 1_000_000;
    payload.f_bfree = 500_000;
    payload.f_bavail = 400_000;
    payload.f_files = 100_000;
    payload.f_ffree = 99_000;
    const big = StatFSBig.init(&payload);
    try std.testing.expectEqual(@as(i64, 0x8000_0001), big._fstype);
    try std.testing.expectEqual(@as(i64, 4096), big._bsize);
}

test "StatFS: union dispatches to the right variant" {
    var payload = std.mem.zeroes(StatFSPayload);
    payload.f_blocks = 123_456;
    const small = StatFS.init(&payload, false);
    const big = StatFS.init(&payload, true);
    try std.testing.expectEqual(@as(i32, 123_456), small.small._blocks);
    try std.testing.expectEqual(@as(i64, 123_456), big.big._blocks);
}
