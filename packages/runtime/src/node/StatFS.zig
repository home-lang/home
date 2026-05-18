// Copied from bun/src/runtime/node/StatFS.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// **Partial port (StatFS payload + extern stubs).**
//
// Upstream `StatFS.zig` is the `node:fs.StatFS` / `BigIntStatFS` wrapper
// around `bun.StatFS` (alias of libc's `struct statfs` on POSIX,
// `uv_statfs_t` on Windows). It bundles two concerns:
//
//   1. The pure `StatFSType(big)` payload + `init(*StatFS)` mapping —
//      copies the seven f_* fields into i32-/i64-sized cells (small vs
//      big variant) with the `@truncate(@as(i64, @intCast(...)))` cast
//      chain that handles libc's varying field widths.
//   2. The JSC bridge — two `extern fn`s
//      (`Bun__createJSStatFSObject` / `…BigIntStatFSObject`) +
//      constructor accessors that allocate the JS-side cells.
//
// Only (1) is ported here. The `StatFS` substrate
// (`bun.c.struct_statfs` / `uv_statfs_t`) re-lands with the syscall
// surface — a minimal `StatFS` shape that the `init` helper reads is
// declared locally so callers that only need pure conversion can use
// this file today. The JSC bridge is kept as `extern fn` decls.
//
// Imports rewritten: @import("bun") → @import("home_rt") for the
// `Environment` namespace.

const std = @import("std");

const home_rt = @import("home_rt");
const Environment = home_rt.Environment;

// ---- StatFS payload shape (stubbed) ---------------------------------------
//
// Upstream `bun.StatFS = bun.c.struct_statfs` on macOS/Linux/FreeBSD and
// `windows.libuv.uv_statfs_t` on Windows — the libc layouts differ
// per-OS in field widths. The conversion helpers below only read seven
// names (`f_type`, `f_bsize`, ...), so we declare the union of those as
// the minimal local shape. When the real `bun.StatFS` substrate ports,
// swap this alias for `home_rt.StatFS`.
pub const StatFSPayload = extern struct {
    f_type: i64 = 0,
    f_bsize: i64 = 0,
    f_blocks: i64 = 0,
    f_bfree: i64 = 0,
    f_bavail: i64 = 0,
    f_files: i64 = 0,
    f_ffree: i64 = 0,
};

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
            // Upstream branches on `Environment.os` (`.linux`/`.mac`/
            // `.freebsd` vs `.windows`) to read the libc struct's
            // per-platform field shapes. Home's stubbed `StatFSPayload`
            // is uniform (all i64) and the conversion is per-field
            // identical, so the explicit `comptime switch` collapses to
            // a single block. The narrowing `@truncate(@as(i64,
            // @intCast(x)))` chain is preserved 1:1 with upstream so
            // the swap to the real platform-specific struct is a no-op.
            // `wasi` rejected at compile-time to match upstream's
            // `.wasm => @compileError`.
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
    const payload: StatFSPayload = .{
        .f_type = 0x4_0000_0001, // > i32 max — exercise the @truncate
        .f_bsize = 4096,
        .f_blocks = 1_000_000,
        .f_bfree = 500_000,
        .f_bavail = 400_000,
        .f_files = 100_000,
        .f_ffree = 99_000,
    };
    const small = StatFSSmall.init(&payload);
    // 0x4_0000_0001 truncated to i32 == 1
    try std.testing.expectEqual(@as(i32, 1), small._fstype);
    try std.testing.expectEqual(@as(i32, 4096), small._bsize);
    try std.testing.expectEqual(@as(i32, 1_000_000), small._blocks);
}

test "StatFS: big variant preserves full i64" {
    const payload: StatFSPayload = .{
        .f_type = 0x4_0000_0001,
        .f_bsize = 4096,
        .f_blocks = 1_000_000,
        .f_bfree = 500_000,
        .f_bavail = 400_000,
        .f_files = 100_000,
        .f_ffree = 99_000,
    };
    const big = StatFSBig.init(&payload);
    try std.testing.expectEqual(@as(i64, 0x4_0000_0001), big._fstype);
    try std.testing.expectEqual(@as(i64, 4096), big._bsize);
}

test "StatFS: union dispatches to the right variant" {
    const payload: StatFSPayload = .{ .f_blocks = 123_456 };
    const small = StatFS.init(&payload, false);
    const big = StatFS.init(&payload, true);
    try std.testing.expectEqual(@as(i32, 123_456), small.small._blocks);
    try std.testing.expectEqual(@as(i64, 123_456), big.big._blocks);
}
