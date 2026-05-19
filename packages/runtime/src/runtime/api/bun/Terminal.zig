// Copied from bun/src/runtime/api/bun/Terminal.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Aggressive skeleton port. The upstream file is a 1200-line PTY +
// JSC class implementation. This port preserves the leaf types that
// downstream code (JSTerminal Codegen, the Subprocess spawn path) reads
// from this module without dragging in the whole I/O reader/writer surface.
//
// What survives the port:
//   - `Flags` packed struct(u8) — the per-Terminal state bitset stored on
//     every instance. Tag-bit positions are observable through the C++
//     Codegen so they must round-trip through `@as(u8, @bitCast(...))`.
//   - `OpenPtyTermios` extern struct — the libutil `openpty(3)` parameter
//     shape. C-ABI-fixed; required for the eventual `openpty` extern.
//   - `Winsize` extern struct — the `TIOCGWINSZ`/`TIOCSWINSZ` payload. Also
//     used as the fifth arg to `openpty`.
//   - `OpenPtyFn` — function-pointer alias for dynamic `openpty` lookup
//     on Linux (libutil is not always linked).
//   - `CreatePtyError` — the failure mode set for `createPty(cols, rows)`.
//   - `clampToCoord` — pure-helper for Windows COORD i16 conversion.
//   - `Options.max_term_name_len` — public constant referenced by
//     `JSTerminal.cpp` (terminfo name length limit).
//
// JSC + I/O substrate (RefCount, IOWriter/IOReader, JSRef, EventLoopHandle,
// jsc.Codegen.JSTerminal, all the constructor/resize/write/dataCallback
// methods, Windows ConPTY plumbing, dynamic libutil loader) is PARKED.
// Re-attach in Phase 12.3 once `home_rt.jsc` grows the matching surface.

const std = @import("std");
const builtin = @import("builtin");

// ---- Public leaf types ------------------------------------------------

/// State bitset stored on every Terminal instance. Layout is mirrored
/// by the C++ Codegen (`packed struct(u8)` → `u8` field on the heap object).
pub const Flags = packed struct(u8) {
    closed: bool = false,
    finalized: bool = false,
    raw_mode: bool = false,
    reader_started: bool = false,
    connected: bool = false,
    reader_done: bool = false,
    writer_done: bool = false,
    /// Set when an inline-created terminal has been attached to a subprocess
    /// via spawn; prevents reusing the same inline terminal for a second
    /// spawn (which on Windows would be silently killed by
    /// ClosePseudoConsole when the first subprocess exits, and on POSIX
    /// has no slave_fd left).
    inline_spawned: bool = false,
};

/// `struct termios` shape passed to `openpty(3)`. Kept extern so the
/// dynamic libutil entry point sees the canonical layout even when Zig
/// `std.posix.termios` differs across glibc/musl/macOS.
pub const OpenPtyTermios = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_cc: [20]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

/// `struct winsize` — TIOCGWINSZ/TIOCSWINSZ payload + final arg to
/// `openpty(3)`.
pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

/// `openpty(3)` signature for dynamic libutil lookup. The fn-pointer
/// alias is held by `LibUtil.getOpenPty()` (parked in this skeleton).
pub const OpenPtyFn = *const fn (
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*const OpenPtyTermios,
    winp: ?*const Winsize,
) callconv(.c) c_int;

pub const CreatePtyError = error{ OpenPtyFailed, DupFailed, NotSupported };

/// Maximum length for terminal name (e.g., "xterm-256color"). Longest
/// known terminfo names are ~23 chars; 128 allows for custom terminals.
pub const max_term_name_len = 128;

/// COORD.X/Y are i16 on Windows; clamp the u16 cols/rows passed in from
/// JS to the COORD range. Pure helper — no platform check needed.
pub inline fn clampToCoord(v: u16) i16 {
    return @intCast(@min(v, std.math.maxInt(i16)));
}

// ---- Parked surfaces -------------------------------------------------
//
// `Terminal` (RefCount + JSC class, master_fd/slave_fd/read_fd/write_fd,
// IOWriter/IOReader, JSRef + EventLoopHandle, this_value, hpcon on Windows,
// all constructor/write/resize/dataCallback/exitCallback/drainCallback
// methods), `Options.parseFromJS`, `CreateResult`, the `createPty` /
// `createPtyPosix` / `createPtyWindows` implementations, the `LibUtil`
// dlopen helper, and the `getTermios`/`setTermiosFlag`/`getTermiosFlag`
// pair are all PARKED. They depend on:
//   - bun.io.StreamingWriter / bun.io.BufferedReader  (home_rt.io WIP)
//   - bun.ptr.RefCount                                (home_rt.ptr WIP)
//   - jsc.Codegen.JSTerminal                          (Codegen WIP)
//   - jsc.JSRef / jsc.EventLoopHandle / jsc.ZigString  (home_rt.jsc WIP)
//   - bun.FD / bun.sys.dup / bun.sys.dlopen           (home_rt.sys WIP)
//   - bun.windows.HPCON + ConPTY APIs                 (home_rt.windows WIP)
// Re-attach in Phase 12.3.

test "Terminal: Flags packs into u8 with little-endian bit order" {
    var f: Flags = .{};
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(f)));

    f.closed = true;
    try std.testing.expectEqual(@as(u8, 0x01), @as(u8, @bitCast(f)));

    f = .{};
    f.finalized = true;
    try std.testing.expectEqual(@as(u8, 0x02), @as(u8, @bitCast(f)));

    f = .{};
    f.inline_spawned = true;
    try std.testing.expectEqual(@as(u8, 0x80), @as(u8, @bitCast(f)));
}

test "Terminal: Flags all-set round-trips through bitcast" {
    const f: Flags = .{
        .closed = true,
        .finalized = true,
        .raw_mode = true,
        .reader_started = true,
        .connected = true,
        .reader_done = true,
        .writer_done = true,
        .inline_spawned = true,
    };
    try std.testing.expectEqual(@as(u8, 0xFF), @as(u8, @bitCast(f)));
    const back: Flags = @bitCast(@as(u8, 0xFF));
    try std.testing.expect(back.closed);
    try std.testing.expect(back.inline_spawned);
}

test "Terminal: Winsize layout matches struct winsize ABI" {
    try std.testing.expect(@typeInfo(Winsize).@"struct".layout == .@"extern");
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Winsize));
    const w: Winsize = .{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    try std.testing.expectEqual(@as(u16, 24), w.ws_row);
    try std.testing.expectEqual(@as(u16, 80), w.ws_col);
}

test "Terminal: OpenPtyTermios layout is C-ABI compatible" {
    try std.testing.expect(@typeInfo(OpenPtyTermios).@"struct".layout == .@"extern");
    // 4*u32 + 20 bytes + 2*u32 = 16 + 20 + 8 = 44; compilers may pad to
    // the alignment of u32 (4), so 44 is the natural total.
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(OpenPtyTermios));
}

test "Terminal: clampToCoord clamps above i16 max but passes small values" {
    try std.testing.expectEqual(@as(i16, 24), clampToCoord(24));
    try std.testing.expectEqual(@as(i16, 80), clampToCoord(80));
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16)), clampToCoord(std.math.maxInt(i16)));
    // u16 65535 > i16 max 32767 → clamps to i16 max.
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16)), clampToCoord(std.math.maxInt(u16)));
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16)), clampToCoord(40000));
}

test "Terminal: max_term_name_len matches the terminfo cap" {
    try std.testing.expectEqual(@as(comptime_int, 128), max_term_name_len);
}

test "Terminal: CreatePtyError set spelled the way upstream expects" {
    const E = CreatePtyError;
    // Force the error-set members to exist; a stray rename would refuse to compile.
    const want: [3]E = .{ error.OpenPtyFailed, error.DupFailed, error.NotSupported };
    for (want) |e| {
        try std.testing.expect(@errorName(e).len > 0);
    }
}
