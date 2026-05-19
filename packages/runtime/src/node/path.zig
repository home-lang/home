// Partial port of bun/src/runtime/node/path.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `node:path` POSIX + Windows path manipulation. The upstream file is ~3 KLOC
// and intertwines pure path-byte logic with JSC plumbing (`getZigString`,
// `bun.String.createUTF8ForJS`, `globalObject.bunVM().rareData().path_buf`,
// `Syscall.Error`, etc.). The pure helpers are the load-bearing reusable
// units — every JS wrapper just adapts them, and the install resolver, the
// CSS resolver, and the TypeScript resolver all want to call these directly.
//
// This Home port pulls out **only the pure-Zig surface**:
//   * Char constants + `sep_posix` / `sep_windows`.
//   * `PathParsed(T)` — the struct returned by `parse`. No `toJSObject`.
//   * Predicates: `isSepPosixT`, `isSepWindowsT`, `isWindowsDeviceRootT`,
//     `isAbsolutePosixT`, `isAbsoluteWindowsT`.
//   * Slice-returning manipulators: `basenamePosixT`, `basenameWindowsT`,
//     `dirnamePosixT`, `dirnameWindowsT`, `extnamePosixT`, `extnameWindowsT`,
//     `normalizePosixT`, `normalizeWindowsT`, `normalizeT`, `parsePosixT`,
//     `parseWindowsT`, `_formatT`.
//   * `formatExtT` and the internal `normalizeStringT` core driver.
//
// What's deliberately omitted (re-attaches with the JSC substrate):
//   * Every `*JS_T` / `*JS` wrapper (`bun.String.createUTF8ForJS`,
//     `validateString`/`validateObject`, `JSGlobalObject`/`JSValue` types).
//   * Top-level entrypoints `basename`/`dirname`/`extname`/`format`/`join`/
//     `resolve`/`relative`/`isAbsolute`/`normalize`/`parse`/`toNamespacedPath`
//     (they all funnel through `validateString`+JSC and call helpers above).
//   * `getCwdU8`/`getCwdU16`/`getCwdT`/`posixCwdT` — these need
//     `bun.fs.FileSystem.instance.top_level_dir` which we don't yet expose,
//     plus `Syscall.Error` errno mapping (`MaybeBuf` aliasing).
//   * `joinPosixT`/`joinWindowsT` — they use `bun.copy` over potentially-
//     overlapping segments; tractable but the JS wrapper above is the only
//     consumer and that needs JSC. Park together.
//   * `resolvePosixT`/`resolveWindowsT`/`toNamespacedPathWindowsT` — they
//     call `getCwdT` and `posixCwdT`, and resolveWindowsT additionally
//     reaches into `std.process.getenvW` + `WPathBuffer`. Park with cwd.
//   * `relativePosixT`/`relativeWindowsT` — call `resolveX` internally.
//   * `eqlIgnoreCaseT` / `isAbsoluteWindowsZigString`/`isAbsolutePosixZigString`
//     — `eqlIgnoreCaseT` is a 4-line wrapper around
//     `bun.strings.eqlCaseInsensitiveASCII`, ported only for u8. The
//     ZigString helpers need JSC.
//
// `bun.memmove`/`bun.copy` are replaced with `memmove`, a small libc-backed
// helper inside this file. `bun.path.Platform` (used as a comptime tag inside
// `normalizeStringT`) is inlined as a tiny local `Platform` enum so the
// helper keeps its same comptime branch shape.

const std = @import("std");
const builtin = @import("builtin");

const home_rt = @import("home_rt");
const strings = home_rt.strings;
const Environment = home_rt.Environment;

// ---- Constants -------------------------------------------------------------

const CHAR_BACKWARD_SLASH = '\\';
const CHAR_COLON = ':';
const CHAR_DOT = '.';
const CHAR_FORWARD_SLASH = '/';

const CHAR_STR_BACKWARD_SLASH = "\\";
const CHAR_STR_FORWARD_SLASH = "/";
const CHAR_STR_DOT = ".";

pub const sep_posix = CHAR_FORWARD_SLASH;
pub const sep_windows = CHAR_BACKWARD_SLASH;
pub const sep_str_posix = CHAR_STR_FORWARD_SLASH;
pub const sep_str_windows = CHAR_STR_BACKWARD_SLASH;

/// Inlined replacement for `bun.path.Platform`. The upstream enum carries a
/// lot more machinery (its own `isAbsolute`, `resolve`, etc.); we only need
/// the comptime tag for `normalizeStringT` to pick `isSepT`.
const Platform = enum { posix, windows };

/// Returns the maximum on-stack buffer size in `T` elements for a path.
pub fn MAX_PATH_SIZE(comptime T: type) usize {
    _ = T;
    return home_rt.MAX_PATH_BYTES;
}

/// Smaller "typical-case" buffer size — same as upstream's
/// `stack_fallback_size_small` minus the Windows special-case (we don't have
/// `PATH_MIN_WIDE` yet, so just match MAX_PATH_BYTES).
pub fn PATH_SIZE(comptime T: type) usize {
    _ = T;
    return home_rt.MAX_PATH_BYTES;
}

// ---- Internal helpers ------------------------------------------------------

fn validatePathT(comptime T: type, comptime methodName: []const u8) void {
    comptime switch (T) {
        u8, u16 => return,
        else => @compileError("Unsupported type for " ++ methodName ++ ": " ++ @typeName(T)),
    };
}

/// Compile-time literal materialization. Mirrors `bun.strings.literal`.
fn L(comptime T: type, comptime str: []const u8) *const [literalLength(T, str):0]T {
    const Holder = struct {
        pub const value = switch (T) {
            u8 => (str[0..str.len].* ++ .{0})[0..str.len :0],
            u16 => std.unicode.utf8ToUtf16LeStringLiteral(str),
            else => @compileError("unsupported type " ++ @typeName(T) ++ " in path.L"),
        };
    };
    return Holder.value;
}

fn literalLength(comptime T: type, comptime str: []const u8) usize {
    return comptime switch (T) {
        u8 => str.len,
        u16 => std.unicode.calcUtf16LeLen(str) catch unreachable,
        else => 0,
    };
}

/// Inlined `bun.memmove`. Handles overlapping ranges by deferring to libc
/// `memmove` at runtime; for comptime paths falls back to a copy loop.
inline fn memmove(comptime T: type, dest: []T, src: []const T) void {
    if (dest.len == 0) return;
    // Source bytes that exceed `dest` would be unreachable per upstream's
    // debug-assert; trim defensively here.
    const n = @min(dest.len, src.len);
    if (@inComptime()) {
        var i: usize = 0;
        while (i < n) : (i += 1) dest[i] = src[i];
        return;
    }
    // At runtime, std.mem doesn't expose `memmove` directly; fall back to
    // overlap-safe forward/backward copy.
    const dst_addr = @intFromPtr(dest.ptr);
    const src_addr = @intFromPtr(src.ptr);
    if (dst_addr <= src_addr) {
        std.mem.copyForwards(T, dest[0..n], src[0..n]);
    } else {
        std.mem.copyBackwards(T, dest[0..n], src[0..n]);
    }
}

/// Based on Node v21.6.1 private helper formatExt:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L130
inline fn formatExtT(comptime T: type, ext: []const T, buf: []T) []const T {
    const len = ext.len;
    if (len == 0) {
        return &.{};
    }
    if (ext[0] == CHAR_DOT) {
        return ext;
    }
    const bufSize = len + 1;
    buf[0] = CHAR_DOT;
    memmove(T, buf[1..bufSize], ext);
    return buf[0..bufSize];
}

// ---- PathParsed ------------------------------------------------------------

/// Based on Node v21.6.1 path.parse:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L919
/// The structs returned by parse methods. JSC-aware `toJSObject` is
/// intentionally omitted in this port.
pub fn PathParsed(comptime T: type) type {
    return struct {
        root: []const T = "",
        dir: []const T = "",
        base: []const T = "",
        ext: []const T = "",
        name: []const T = "",
    };
}

// ---- Predicates ------------------------------------------------------------

pub fn isSepPosixT(comptime T: type, byte: T) bool {
    return byte == CHAR_FORWARD_SLASH;
}

pub fn isSepWindowsT(comptime T: type, byte: T) bool {
    return byte == CHAR_FORWARD_SLASH or byte == CHAR_BACKWARD_SLASH;
}

pub fn isWindowsDeviceRootT(comptime T: type, byte: T) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}

/// Based on Node v21.6.1 path.posix.isAbsolute:
pub fn isAbsolutePosixT(comptime T: type, path: []const T) bool {
    return path.len > 0 and path[0] == CHAR_FORWARD_SLASH;
}

/// Based on Node v21.6.1 path.win32.isAbsolute:
pub fn isAbsoluteWindowsT(comptime T: type, path: []const T) bool {
    const len = path.len;
    if (len == 0) return false;
    const byte0 = path[0];
    return isSepWindowsT(T, byte0) or
        // Possible device root
        (len > 2 and
            isWindowsDeviceRootT(T, byte0) and
            path[1] == CHAR_COLON and
            isSepWindowsT(T, path[2]));
}

// ---- basename --------------------------------------------------------------

/// Based on Node v21.6.1 path.posix.basename:
pub fn basenamePosixT(comptime T: type, path: []const T, suffix: ?[]const T) []const T {
    comptime validatePathT(T, "basenamePosixT");

    const len = path.len;
    if (len == 0) return &.{};

    var start: usize = 0;
    var end: ?usize = null;
    var matchedSlash: bool = true;

    const _suffix = if (suffix) |_s| _s else &.{};
    const _suffixLen = _suffix.len;
    if (suffix != null and _suffixLen > 0 and _suffixLen <= len) {
        if (std.mem.eql(T, _suffix, path)) return &.{};
        var extIdx: ?usize = _suffixLen - 1;
        var firstNonSlashEnd: ?usize = null;
        var i_i64 = @as(i64, @intCast(len - 1));
        while (i_i64 >= start) : (i_i64 -= 1) {
            const i = @as(usize, @intCast(i_i64));
            const byte = path[i];
            if (byte == CHAR_FORWARD_SLASH) {
                if (!matchedSlash) {
                    start = i + 1;
                    break;
                }
            } else {
                if (firstNonSlashEnd == null) {
                    matchedSlash = false;
                    firstNonSlashEnd = i + 1;
                }
                if (extIdx) |_extIx| {
                    if (byte == _suffix[_extIx]) {
                        if (_extIx == 0) {
                            end = i;
                            extIdx = null;
                        } else {
                            extIdx = _extIx - 1;
                        }
                    } else {
                        extIdx = null;
                        end = firstNonSlashEnd;
                    }
                }
            }
        }

        if (end) |_end| {
            if (start == _end) {
                return path[start..firstNonSlashEnd.?];
            } else {
                return path[start.._end];
            }
        }
        return path[start..len];
    }

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 > -1) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (byte == CHAR_FORWARD_SLASH) {
            if (!matchedSlash) {
                start = i + 1;
                break;
            }
        } else if (end == null) {
            matchedSlash = false;
            end = i + 1;
        }
    }

    return if (end) |_end| path[start.._end] else &.{};
}

/// Based on Node v21.6.1 path.win32.basename:
pub fn basenameWindowsT(comptime T: type, path: []const T, suffix: ?[]const T) []const T {
    comptime validatePathT(T, "basenameWindowsT");

    const len = path.len;
    if (len == 0) return &.{};

    const isSepT = isSepWindowsT;

    var start: usize = 0;
    var end: ?usize = null;
    var matchedSlash: bool = true;

    if (len >= 2 and isWindowsDeviceRootT(T, path[0]) and path[1] == CHAR_COLON) {
        start = 2;
    }

    const _suffix = if (suffix) |_s| _s else &.{};
    const _suffixLen = _suffix.len;
    if (suffix != null and _suffixLen > 0 and _suffixLen <= len) {
        if (std.mem.eql(T, _suffix, path)) return &.{};
        var extIdx: ?usize = _suffixLen - 1;
        var firstNonSlashEnd: ?usize = null;
        var i_i64 = @as(i64, @intCast(len - 1));
        while (i_i64 >= start) : (i_i64 -= 1) {
            const i = @as(usize, @intCast(i_i64));
            const byte = path[i];
            if (isSepT(T, byte)) {
                if (!matchedSlash) {
                    start = i + 1;
                    break;
                }
            } else {
                if (firstNonSlashEnd == null) {
                    matchedSlash = false;
                    firstNonSlashEnd = i + 1;
                }
                if (extIdx) |_extIx| {
                    if (byte == _suffix[_extIx]) {
                        if (_extIx == 0) {
                            end = i;
                            extIdx = null;
                        } else {
                            extIdx = _extIx - 1;
                        }
                    } else {
                        extIdx = null;
                        end = firstNonSlashEnd;
                    }
                }
            }
        }

        if (end) |_end| {
            if (start == _end) {
                return path[start..firstNonSlashEnd.?];
            } else {
                return path[start.._end];
            }
        }
        return path[start..len];
    }

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 >= start) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (isSepT(T, byte)) {
            if (!matchedSlash) {
                start = i + 1;
                break;
            }
        } else if (end == null) {
            matchedSlash = false;
            end = i + 1;
        }
    }

    return if (end) |_end| path[start.._end] else &.{};
}

// ---- dirname ---------------------------------------------------------------

pub fn dirnamePosixT(comptime T: type, path: []const T) []const T {
    comptime validatePathT(T, "dirnamePosixT");

    const len = path.len;
    if (len == 0) return comptime L(T, CHAR_STR_DOT);

    const hasRoot = path[0] == CHAR_FORWARD_SLASH;
    var end: ?usize = null;
    var matchedSlash: bool = true;
    var i: usize = len - 1;
    while (i >= 1) : (i -= 1) {
        if (path[i] == CHAR_FORWARD_SLASH) {
            if (!matchedSlash) {
                end = i;
                break;
            }
        } else {
            matchedSlash = false;
        }
    }

    if (end) |_end| {
        return if (hasRoot and _end == 1)
            comptime L(T, "//")
        else
            path[0.._end];
    }
    return if (hasRoot)
        comptime L(T, CHAR_STR_FORWARD_SLASH)
    else
        comptime L(T, CHAR_STR_DOT);
}

pub fn dirnameWindowsT(comptime T: type, path: []const T) []const T {
    comptime validatePathT(T, "dirnameWindowsT");

    const len = path.len;
    if (len == 0) return comptime L(T, CHAR_STR_DOT);

    const isSepT = isSepWindowsT;

    var rootEnd: ?usize = null;
    var offset: usize = 0;
    const byte0 = path[0];

    if (len == 1) {
        return if (isSepT(T, byte0)) path else comptime L(T, CHAR_STR_DOT);
    }

    if (isSepT(T, byte0)) {
        rootEnd = 1;
        offset = 1;

        if (isSepT(T, path[1])) {
            var j: usize = 2;
            var last: usize = j;

            while (j < len and !isSepT(T, path[j])) j += 1;

            if (j < len and j != last) {
                last = j;
                while (j < len and isSepT(T, path[j])) j += 1;

                if (j < len and j != last) {
                    last = j;
                    while (j < len and !isSepT(T, path[j])) j += 1;

                    if (j == len) return path;

                    if (j != last) {
                        offset = j + 1;
                        rootEnd = offset;
                    }
                }
            }
        }
    } else if (isWindowsDeviceRootT(T, byte0) and path[1] == CHAR_COLON) {
        offset = if (len > 2 and isSepT(T, path[2])) 3 else 2;
        rootEnd = offset;
    }

    var end: ?usize = null;
    var matchedSlash: bool = true;

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 >= offset) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        if (isSepT(T, path[i])) {
            if (!matchedSlash) {
                end = i;
                break;
            }
        } else {
            matchedSlash = false;
        }
    }

    if (end) |_end| return path[0.._end];

    return if (rootEnd) |_rootEnd| path[0.._rootEnd] else comptime L(T, CHAR_STR_DOT);
}

// ---- extname ---------------------------------------------------------------

pub fn extnamePosixT(comptime T: type, path: []const T) []const T {
    comptime validatePathT(T, "extnamePosixT");

    const len = path.len;
    if (len == 0) return &.{};

    var startDot: ?usize = null;
    var startPart: usize = 0;
    var end: ?usize = null;
    var matchedSlash: bool = true;
    var preDotState: ?usize = 0;

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 > -1) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (byte == CHAR_FORWARD_SLASH) {
            if (!matchedSlash) {
                startPart = i + 1;
                break;
            }
            continue;
        }

        if (end == null) {
            matchedSlash = false;
            end = i + 1;
        }

        if (byte == CHAR_DOT) {
            if (startDot == null) {
                startDot = i;
            } else if (preDotState != null and preDotState.? != 1) {
                preDotState = 1;
            }
        } else if (startDot != null) {
            preDotState = null;
        }
    }

    const _end = if (end) |_e| _e else 0;
    const _preDotState = if (preDotState) |_p| _p else 0;
    const _startDot = if (startDot) |_s| _s else 0;
    if (startDot == null or
        end == null or
        (preDotState != null and _preDotState == 0) or
        (_preDotState == 1 and
            _startDot == _end - 1 and
            _startDot == startPart + 1))
    {
        return &.{};
    }

    return path[_startDot.._end];
}

pub fn extnameWindowsT(comptime T: type, path: []const T) []const T {
    comptime validatePathT(T, "extnameWindowsT");

    const len = path.len;
    if (len == 0) return &.{};

    var start: usize = 0;
    var startDot: ?usize = null;
    var startPart: usize = 0;
    var end: ?usize = null;
    var matchedSlash: bool = true;
    var preDotState: ?usize = 0;

    if (len >= 2 and
        path[1] == CHAR_COLON and
        isWindowsDeviceRootT(T, path[0]))
    {
        start = 2;
        startPart = start;
    }

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 >= start) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (isSepWindowsT(T, byte)) {
            if (!matchedSlash) {
                startPart = i + 1;
                break;
            }
            continue;
        }
        if (end == null) {
            matchedSlash = false;
            end = i + 1;
        }
        if (byte == CHAR_DOT) {
            if (startDot == null) {
                startDot = i;
            } else if (preDotState) |_preDotState| {
                if (_preDotState != 1) preDotState = 1;
            }
        } else if (startDot != null) {
            preDotState = null;
        }
    }

    const _end = if (end) |_e| _e else 0;
    const _preDotState = if (preDotState) |_p| _p else 0;
    const _startDot = if (startDot) |_s| _s else 0;
    if (startDot == null or
        end == null or
        (preDotState != null and _preDotState == 0) or
        (_preDotState == 1 and
            _startDot == _end - 1 and
            _startDot == startPart + 1))
    {
        return &.{};
    }

    return path[_startDot.._end];
}

// ---- format (pure helper) --------------------------------------------------

/// Internal formatter used by both `format.posix` and `format.win32`. Writes
/// into `buf` and returns the slice that's the formatted path. Exposed
/// publicly so callers that already have a `PathParsed(T)` can format
/// without going through JSC.
pub fn _formatT(comptime T: type, pathObject: PathParsed(T), separator: T, buf: []T) []const T {
    comptime validatePathT(T, "_formatT");

    const root = pathObject.root;
    const dir = pathObject.dir;
    const base = pathObject.base;
    const ext = pathObject.ext;
    const _name = pathObject.name;

    const dirIsRoot = dir.len == 0 or std.mem.eql(T, dir, root);
    const dirOrRoot = if (dirIsRoot) root else dir;
    const dirLen = dirOrRoot.len;

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    var baseLen = base.len;
    var baseOrNameExt = base;
    if (baseLen > 0) {
        memmove(T, buf[0..baseLen], base);
    } else {
        const formattedExt = formatExtT(T, ext, buf);
        const nameLen = _name.len;
        const extLen = formattedExt.len;
        bufOffset = nameLen;
        bufSize = bufOffset + extLen;
        if (extLen > 0) {
            memmove(T, buf[bufOffset..bufSize], formattedExt);
        }
        if (nameLen > 0) {
            memmove(T, buf[0..nameLen], _name);
        }
        if (bufSize > 0) {
            baseOrNameExt = buf[0..bufSize];
        }
    }

    if (dirLen == 0) return baseOrNameExt;

    baseLen = baseOrNameExt.len;
    if (baseLen > 0) {
        bufOffset = if (dirIsRoot) dirLen else dirLen + 1;
        bufSize = bufOffset + baseLen;
        memmove(T, buf[bufOffset..bufSize], baseOrNameExt);
    }
    memmove(T, buf[0..dirLen], dirOrRoot);
    bufSize = dirLen + baseLen;
    if (!dirIsRoot) {
        bufSize += 1;
        buf[dirLen] = separator;
    }
    return buf[0..bufSize];
}

// ---- normalize -------------------------------------------------------------

/// Internal driver for `normalizePosixT` and `normalizeWindowsT`. The
/// `platform` comptime parameter picks which sep predicate to use.
fn normalizeStringT(
    comptime T: type,
    path: []const T,
    allowAboveRoot: bool,
    separator: T,
    comptime platform: Platform,
    buf: []T,
) [:0]T {
    const len = path.len;
    const isSepT = if (platform == .posix) isSepPosixT else isSepWindowsT;

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    var lastSegmentLength: usize = 0;
    var lastSlash: ?usize = null;
    var dots: ?usize = 0;
    var byte: T = 0;

    var i: usize = 0;
    while (i <= len) : (i += 1) {
        if (i < len) {
            byte = path[i];
        } else if (isSepT(T, byte)) {
            break;
        } else {
            byte = CHAR_FORWARD_SLASH;
        }

        if (isSepT(T, byte)) {
            if ((lastSlash == null and i == 0) or
                (lastSlash != null and i > 0 and lastSlash.? == i - 1) or
                (dots != null and dots.? == 1))
            {
                // NOOP
            } else if (dots != null and dots.? == 2) {
                if (bufSize < 2 or
                    lastSegmentLength != 2 or
                    buf[bufSize - 1] != CHAR_DOT or
                    buf[bufSize - 2] != CHAR_DOT)
                {
                    if (bufSize > 2) {
                        const lastSlashIndex = std.mem.lastIndexOfScalar(T, buf[0..bufSize], separator);
                        if (lastSlashIndex == null) {
                            bufSize = 0;
                            lastSegmentLength = 0;
                        } else {
                            bufSize = lastSlashIndex.?;
                            const lastIndexOfSep = std.mem.lastIndexOfScalar(T, buf[0..bufSize], separator);
                            if (lastIndexOfSep == null) {
                                lastSegmentLength = bufSize;
                            } else {
                                lastSegmentLength = bufSize - 1 - lastIndexOfSep.?;
                            }
                        }
                        lastSlash = i;
                        dots = 0;
                        continue;
                    } else if (bufSize != 0) {
                        bufSize = 0;
                        lastSegmentLength = 0;
                        lastSlash = i;
                        dots = 0;
                        continue;
                    }
                }
                if (allowAboveRoot) {
                    if (bufSize > 0) {
                        bufOffset = bufSize;
                        bufSize += 1;
                        buf[bufOffset] = separator;
                        bufOffset = bufSize;
                        bufSize += 2;
                        buf[bufOffset] = CHAR_DOT;
                        buf[bufOffset + 1] = CHAR_DOT;
                    } else {
                        bufSize = 2;
                        buf[0] = CHAR_DOT;
                        buf[1] = CHAR_DOT;
                    }

                    lastSegmentLength = 2;
                }
            } else {
                if (bufSize > 0) {
                    bufOffset = bufSize;
                    bufSize += 1;
                    buf[bufOffset] = separator;
                }
                const sliceStart = if (lastSlash != null) lastSlash.? + 1 else 0;
                const slice = path[sliceStart..i];

                bufOffset = bufSize;
                bufSize += slice.len;
                memmove(T, buf[bufOffset..bufSize], slice);

                const subtract = if (lastSlash != null) lastSlash.? + 1 else 2;
                lastSegmentLength = if (i >= subtract) i - subtract else 0;
            }
            lastSlash = i;
            dots = 0;
            continue;
        } else if (byte == CHAR_DOT and dots != null) {
            dots = if (dots != null) dots.? + 1 else 0;
            continue;
        } else {
            dots = null;
        }
    }

    buf[bufSize] = 0;
    return buf[0..bufSize :0];
}

pub fn normalizePosixT(comptime T: type, path: []const T, buf: []T) []const T {
    comptime validatePathT(T, "normalizePosixT");

    const len = path.len;
    if (len == 0) return comptime L(T, CHAR_STR_DOT);

    const _isAbsolute = path[0] == CHAR_FORWARD_SLASH;
    const trailingSeparator = path[len - 1] == CHAR_FORWARD_SLASH;

    var normalizedPath = normalizeStringT(T, path, !_isAbsolute, CHAR_FORWARD_SLASH, .posix, buf);

    var bufSize: usize = normalizedPath.len;
    if (bufSize == 0) {
        if (_isAbsolute) return comptime L(T, CHAR_STR_FORWARD_SLASH);
        return if (trailingSeparator) comptime L(T, "./") else comptime L(T, CHAR_STR_DOT);
    }

    var bufOffset: usize = 0;

    if (trailingSeparator) {
        bufOffset = bufSize;
        bufSize += 1;
        buf[bufOffset] = CHAR_FORWARD_SLASH;
        buf[bufSize] = 0;
        normalizedPath = buf[0..bufSize :0];
    }

    if (_isAbsolute) {
        bufOffset = 1;
        bufSize += 1;
        memmove(T, buf[bufOffset..bufSize], normalizedPath);
        buf[0] = CHAR_FORWARD_SLASH;
        buf[bufSize] = 0;
        normalizedPath = buf[0..bufSize :0];
    }
    return normalizedPath;
}

pub fn normalizeWindowsT(comptime T: type, path: []const T, buf: []T) []const T {
    comptime validatePathT(T, "normalizeWindowsT");

    const len = path.len;
    if (len == 0) return comptime L(T, CHAR_STR_DOT);

    const isSepT = isSepWindowsT;

    const byte0: T = path[0];

    if (len == 1) {
        return if (isSepT(T, byte0)) comptime L(T, CHAR_STR_BACKWARD_SLASH) else path;
    }

    var rootEnd: usize = 0;
    var device: ?[]const T = null;
    var _isAbsolute: bool = false;

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    if (isSepT(T, byte0)) {
        _isAbsolute = true;

        if (isSepT(T, path[1])) {
            var j: usize = 2;
            var last: usize = j;
            while (j < len and !isSepT(T, path[j])) j += 1;
            if (j < len and j != last) {
                const firstPart: []const T = path[last..j];
                last = j;
                while (j < len and isSepT(T, path[j])) j += 1;
                if (j < len and j != last) {
                    last = j;
                    while (j < len and !isSepT(T, path[j])) j += 1;
                    if (j == len) {
                        bufSize = 2;
                        buf[0] = CHAR_BACKWARD_SLASH;
                        buf[1] = CHAR_BACKWARD_SLASH;
                        bufOffset = bufSize;
                        bufSize += firstPart.len;
                        memmove(T, buf[bufOffset..bufSize], firstPart);
                        bufOffset = bufSize;
                        bufSize += 1;
                        buf[bufOffset] = CHAR_BACKWARD_SLASH;
                        bufOffset = bufSize;
                        bufSize += len - last;
                        memmove(T, buf[bufOffset..bufSize], path[last..len]);
                        bufOffset = bufSize;
                        bufSize += 1;
                        buf[bufOffset] = CHAR_BACKWARD_SLASH;
                        return buf[0..bufSize];
                    }
                    if (j != last) {
                        bufSize = 2;
                        buf[0] = CHAR_BACKWARD_SLASH;
                        buf[1] = CHAR_BACKWARD_SLASH;
                        bufOffset = bufSize;
                        bufSize += firstPart.len;
                        memmove(T, buf[bufOffset..bufSize], firstPart);
                        bufOffset = bufSize;
                        bufSize += 1;
                        buf[bufOffset] = CHAR_BACKWARD_SLASH;
                        bufOffset = bufSize;
                        bufSize += j - last;
                        memmove(T, buf[bufOffset..bufSize], path[last..j]);

                        device = buf[0..bufSize];
                        rootEnd = j;
                    }
                }
            }
        } else {
            rootEnd = 1;
        }
    } else if (isWindowsDeviceRootT(T, byte0) and
        path[1] == CHAR_COLON)
    {
        buf[0] = byte0;
        buf[1] = CHAR_COLON;
        device = buf[0..2];
        rootEnd = 2;
        if (len > 2 and isSepT(T, path[2])) {
            _isAbsolute = true;
            rootEnd = 3;
        }
    }

    bufOffset = (if (device) |_d| _d.len else 0) + @intFromBool(_isAbsolute);
    var tailLen = if (rootEnd < len) normalizeStringT(T, path[rootEnd..len], !_isAbsolute, CHAR_BACKWARD_SLASH, .windows, buf[bufOffset..]).len else 0;
    if (tailLen == 0 and !_isAbsolute) {
        buf[bufOffset] = CHAR_DOT;
        tailLen = 1;
    }

    if (tailLen > 0 and isSepT(T, path[len - 1])) {
        buf[bufOffset + tailLen] = CHAR_BACKWARD_SLASH;
        tailLen += 1;
    }

    bufSize = bufOffset + tailLen;
    if (_isAbsolute) {
        bufOffset -= 1;
        buf[bufOffset] = CHAR_BACKWARD_SLASH;
    }
    return buf[0..bufSize];
}

pub fn normalizeT(comptime T: type, path: []const T, buf: []T) []const T {
    return switch (builtin.os.tag) {
        .windows => normalizeWindowsT(T, path, buf),
        else => normalizePosixT(T, path, buf),
    };
}

// ---- parse -----------------------------------------------------------------

pub fn parsePosixT(comptime T: type, path: []const T) PathParsed(T) {
    comptime validatePathT(T, "parsePosixT");

    const len = path.len;
    if (len == 0) return .{};

    var root: []const T = &.{};
    var dir: []const T = &.{};
    var base: []const T = &.{};
    var ext: []const T = &.{};
    var _name: []const T = &.{};
    const _isAbsolute = path[0] == CHAR_FORWARD_SLASH;
    var start: usize = 0;
    if (_isAbsolute) {
        root = comptime L(T, CHAR_STR_FORWARD_SLASH);
        start = 1;
    }

    var startDot: ?usize = null;
    var startPart: usize = 0;
    var end: ?usize = null;
    var matchedSlash = true;
    var i_i64 = @as(i64, @intCast(len - 1));
    var preDotState: ?usize = 0;

    while (i_i64 >= start) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (byte == CHAR_FORWARD_SLASH) {
            if (!matchedSlash) {
                startPart = i + 1;
                break;
            }
            continue;
        }
        if (end == null) {
            matchedSlash = false;
            end = i + 1;
        }
        if (byte == CHAR_DOT) {
            if (startDot == null) {
                startDot = i;
            } else if (preDotState) |_preDotState| {
                if (_preDotState != 1) preDotState = 1;
            }
        } else if (startDot != null) {
            preDotState = null;
        }
    }

    if (end) |_end| {
        const _preDotState = if (preDotState) |_p| _p else 0;
        const _startDot = if (startDot) |_s| _s else 0;
        start = if (startPart == 0 and _isAbsolute) 1 else startPart;
        if (startDot == null or
            (preDotState != null and _preDotState == 0) or
            (_preDotState == 1 and
                _startDot == _end - 1 and
                _startDot == startPart + 1))
        {
            _name = path[start.._end];
            base = _name;
        } else {
            _name = path[start.._startDot];
            base = path[start.._end];
            ext = path[_startDot.._end];
        }
    }

    if (startPart > 0) {
        dir = path[0..(startPart - 1)];
    } else if (_isAbsolute) {
        dir = comptime L(T, CHAR_STR_FORWARD_SLASH);
    }

    return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
}

pub fn parseWindowsT(comptime T: type, path: []const T) PathParsed(T) {
    comptime validatePathT(T, "parseWindowsT");

    var root: []const T = &.{};
    var dir: []const T = &.{};
    var base: []const T = &.{};
    var ext: []const T = &.{};
    var _name: []const T = &.{};

    const len = path.len;
    if (len == 0) {
        return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
    }

    const isSepT = isSepWindowsT;

    var rootEnd: usize = 0;
    var byte = path[0];

    if (len == 1) {
        if (isSepT(T, byte)) {
            root = path;
            dir = path;
        } else {
            base = path;
            _name = path;
        }
        return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
    }

    if (isSepT(T, byte)) {
        rootEnd = 1;
        if (isSepT(T, path[1])) {
            var j: usize = 2;
            var last: usize = j;
            while (j < len and !isSepT(T, path[j])) j += 1;
            if (j < len and j != last) {
                last = j;
                while (j < len and isSepT(T, path[j])) j += 1;
                if (j < len and j != last) {
                    last = j;
                    while (j < len and !isSepT(T, path[j])) j += 1;
                    if (j == len) {
                        rootEnd = j;
                    } else if (j != last) {
                        rootEnd = j + 1;
                    }
                }
            }
        }
    } else if (isWindowsDeviceRootT(T, byte) and
        path[1] == CHAR_COLON)
    {
        if (len <= 2) {
            root = path;
            dir = path;
            return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
        }
        rootEnd = 2;
        if (isSepT(T, path[2])) {
            if (len == 3) {
                root = path;
                dir = path;
                return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
            }
            rootEnd = 3;
        }
    }
    if (rootEnd > 0) root = path[0..rootEnd];

    var startDot: ?usize = null;
    var startPart = rootEnd;
    var end: ?usize = null;
    var matchedSlash = true;
    var i_i64 = @as(i64, @intCast(len - 1));
    var preDotState: ?usize = 0;

    while (i_i64 >= rootEnd) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        byte = path[i];
        if (isSepT(T, byte)) {
            if (!matchedSlash) {
                startPart = i + 1;
                break;
            }
            continue;
        }
        if (end == null) {
            matchedSlash = false;
            end = i + 1;
        }
        if (byte == CHAR_DOT) {
            if (startDot == null) {
                startDot = i;
            } else if (preDotState) |_preDotState| {
                if (_preDotState != 1) preDotState = 1;
            }
        } else if (startDot != null) {
            preDotState = null;
        }
    }

    if (end) |_end| {
        const _preDotState = if (preDotState) |_p| _p else 0;
        const _startDot = if (startDot) |_s| _s else 0;
        if (startDot == null or
            (preDotState != null and _preDotState == 0) or
            (_preDotState == 1 and
                _startDot == _end - 1 and
                _startDot == startPart + 1))
        {
            _name = path[startPart.._end];
            base = _name;
        } else {
            _name = path[startPart.._startDot];
            base = path[startPart.._end];
            ext = path[_startDot.._end];
        }
    }

    if (startPart > 0 and startPart != rootEnd) {
        dir = path[0..(startPart - 1)];
    } else {
        dir = root;
    }

    return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
}

// ---- join ------------------------------------------------------------------

/// Based on Node v21.6.1 path.posix.join. `buf2` holds the pre-normalize
/// joined string; `buf` receives the normalize result. Both must be sized at
/// least `PATH_SIZE(T)`.
pub fn joinPosixT(comptime T: type, paths: []const []const T, buf: []T, buf2: []T) []const T {
    comptime validatePathT(T, "joinPosixT");

    if (paths.len == 0) return comptime L(T, CHAR_STR_DOT);

    var bufSize: usize = 0;
    var bufOffset: usize = 0;
    var joined: []const T = &.{};

    for (paths) |path| {
        const len = path.len;
        if (len > 0) {
            if (bufSize != 0) {
                bufOffset = bufSize;
                bufSize += 1;
                buf2[bufOffset] = CHAR_FORWARD_SLASH;
            }
            bufOffset = bufSize;
            bufSize += len;
            memmove(T, buf2[bufOffset..bufSize], path);
            joined = buf2[0..bufSize];
        }
    }
    if (bufSize == 0) return comptime L(T, CHAR_STR_DOT);
    return normalizePosixT(T, joined, buf);
}

/// Based on Node v21.6.1 path.win32.join.
pub fn joinWindowsT(comptime T: type, paths: []const []const T, buf: []T, buf2: []T) []const T {
    comptime validatePathT(T, "joinWindowsT");

    if (paths.len == 0) return comptime L(T, CHAR_STR_DOT);

    const isSepT = isSepWindowsT;

    var bufSize: usize = 0;
    var bufOffset: usize = 0;
    var joined: []const T = &.{};
    var firstPart: []const T = &.{};

    for (paths) |path| {
        const len = path.len;
        if (len > 0) {
            bufOffset = bufSize;
            if (bufSize == 0) {
                bufSize = len;
                memmove(T, buf2[0..bufSize], path);
                joined = buf2[0..bufSize];
                firstPart = joined;
            } else {
                bufOffset = bufSize;
                bufSize += 1;
                buf2[bufOffset] = CHAR_BACKWARD_SLASH;
                bufOffset = bufSize;
                bufSize += len;
                memmove(T, buf2[bufOffset..bufSize], path);
                joined = buf2[0..bufSize];
            }
        }
    }
    if (bufSize == 0) return comptime L(T, CHAR_STR_DOT);

    // Collapse leading slashes — preserve UNC prefix when the first segment
    // already encoded one. Mirrors Node's join() prefix handling.
    var needsReplace: bool = true;
    var slashCount: usize = 0;
    if (firstPart.len > 0 and isSepT(T, firstPart[0])) {
        slashCount += 1;
        const firstLen = firstPart.len;
        if (firstLen > 1 and isSepT(T, firstPart[1])) {
            slashCount += 1;
            if (firstLen > 2) {
                if (isSepT(T, firstPart[2])) {
                    slashCount += 1;
                } else {
                    needsReplace = false;
                }
            }
        }
    }
    if (needsReplace) {
        while (slashCount < bufSize and isSepT(T, joined[slashCount])) slashCount += 1;
        if (slashCount >= 2) {
            bufOffset = 1;
            const newSize = bufOffset + (bufSize - slashCount);
            // Overlapping copy — fall through memmove (handles backward).
            memmove(T, buf2[bufOffset..newSize], joined[slashCount..bufSize]);
            buf2[0] = CHAR_BACKWARD_SLASH;
            bufSize = newSize;
            joined = buf2[0..bufSize];
        }
    }
    return normalizeWindowsT(T, joined, buf);
}

// ---- resolve / relative ----------------------------------------------------

/// Based on Node v21.6.1 path.posix.resolve. Takes `cwd` explicitly rather
/// than calling out to a global FileSystem instance, since the JSC-bound
/// `bun.fs.FileSystem.instance.top_level_dir` is gated on Phase 12.2.
/// `cwd` is consulted only if no absolute path is encountered.
pub fn resolvePosixT(
    comptime T: type,
    paths: []const []const T,
    cwd: []const T,
    buf: []T,
    buf2: []T,
) []const T {
    comptime validatePathT(T, "resolvePosixT");

    var resolvedPath: []const T = &.{};
    var resolvedPathLen: usize = 0;
    var resolvedAbsolute: bool = false;

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    var i_i64: i64 = if (paths.len == 0) -1 else @as(i64, @intCast(paths.len - 1));
    while (i_i64 > -2 and !resolvedAbsolute) : (i_i64 -= 1) {
        var path: []const T = &.{};
        if (i_i64 >= 0) {
            path = paths[@as(usize, @intCast(i_i64))];
        } else {
            path = cwd;
        }
        const len = path.len;
        if (len == 0) continue;

        if (resolvedPathLen > 0) {
            bufOffset = len + 1;
            bufSize = bufOffset + resolvedPathLen;
            memmove(T, buf2[bufOffset..bufSize], resolvedPath);
        }
        bufSize = len;
        memmove(T, buf2[0..bufSize], path);
        bufSize += 1;
        buf2[len] = CHAR_FORWARD_SLASH;
        bufSize += resolvedPathLen;

        resolvedPath = buf2[0..bufSize];
        resolvedPathLen = bufSize;
        resolvedAbsolute = path[0] == CHAR_FORWARD_SLASH;
    }

    if (resolvedPathLen == 0) {
        return comptime L(T, CHAR_STR_DOT);
    }

    const normalized = normalizeStringT(T, resolvedPath, !resolvedAbsolute, CHAR_FORWARD_SLASH, .posix, buf);
    resolvedPathLen = normalized.len;

    if (resolvedAbsolute) {
        bufSize = resolvedPathLen + 1;
        // overlap-safe: dest is shifted forward by 1 inside `buf`.
        memmove(T, buf[1..bufSize], normalized);
        buf[0] = CHAR_FORWARD_SLASH;
        return buf[0..bufSize];
    }
    return if (resolvedPathLen > 0) normalized else comptime L(T, CHAR_STR_DOT);
}

/// Based on Node v21.6.1 path.posix.relative.
pub fn relativePosixT(
    comptime T: type,
    from: []const T,
    to: []const T,
    cwd: []const T,
    buf: []T,
    buf2: []T,
    buf3: []T,
) []const T {
    comptime validatePathT(T, "relativePosixT");

    if (std.mem.eql(T, from, to)) return &.{};

    const fromOrig = resolvePosixT(T, &.{from}, cwd, buf2, buf3);
    const fromOrigLen = fromOrig.len;
    const toOrig = resolvePosixT(T, &.{to}, cwd, buf, buf3);

    if (std.mem.eql(T, fromOrig, toOrig)) return &.{};

    const fromStart: usize = 1;
    const fromEnd: usize = fromOrigLen;
    const fromLen: usize = fromEnd - fromStart;
    const toOrigLen = toOrig.len;
    var toStart: usize = 1;
    const toLen = toOrigLen - toStart;

    const smallestLength = @min(fromLen, toLen);
    var lastCommonSep: ?usize = null;
    var matchesAllOfSmallest = false;
    {
        var i: usize = 0;
        while (i < smallestLength) : (i += 1) {
            const fromByte = fromOrig[fromStart + i];
            if (fromByte != toOrig[toStart + i]) break;
            if (fromByte == CHAR_FORWARD_SLASH) lastCommonSep = i;
        }
        matchesAllOfSmallest = i == smallestLength;
    }
    if (matchesAllOfSmallest) {
        if (toLen > smallestLength) {
            if (toOrig[toStart + smallestLength] == CHAR_FORWARD_SLASH) {
                const start = toStart + smallestLength + 1;
                const slice = toOrig[start..toOrigLen];
                memmove(T, buf3[0..slice.len], slice);
                return buf3[0..slice.len];
            }
            if (smallestLength == 0) {
                const slice = toOrig[toStart..toOrigLen];
                memmove(T, buf3[0..slice.len], slice);
                return buf3[0..slice.len];
            }
        } else if (fromLen > smallestLength) {
            if (fromOrig[fromStart + smallestLength] == CHAR_FORWARD_SLASH) {
                lastCommonSep = smallestLength;
            } else if (smallestLength == 0) {
                lastCommonSep = 0;
            }
        }
    }

    var bufOffset: usize = 0;
    var bufSize: usize = 0;
    var out: []const T = &.{};
    {
        var i: usize = fromStart + (if (lastCommonSep != null) lastCommonSep.? + 1 else 0);
        while (i <= fromEnd) : (i += 1) {
            if (i == fromEnd or fromOrig[i] == CHAR_FORWARD_SLASH) {
                if (out.len > 0) {
                    bufOffset = bufSize;
                    bufSize += 3;
                    buf3[bufOffset] = CHAR_FORWARD_SLASH;
                    buf3[bufOffset + 1] = CHAR_DOT;
                    buf3[bufOffset + 2] = CHAR_DOT;
                } else {
                    bufSize = 2;
                    buf3[0] = CHAR_DOT;
                    buf3[1] = CHAR_DOT;
                }
                out = buf3[0..bufSize];
            }
        }
    }

    toStart = if (lastCommonSep != null) toStart + lastCommonSep.? else 0;
    const sliceSize = toOrigLen - toStart;
    const outLen = out.len;
    bufSize = outLen;
    if (sliceSize > 0) {
        bufOffset = bufSize;
        bufSize += sliceSize;
        memmove(T, buf[bufOffset..bufSize], toOrig[toStart..toOrigLen]);
    }
    if (outLen > 0) {
        memmove(T, buf[0..outLen], out);
    }
    return buf[0..bufSize];
}

// ---- Node-shape API (sub-namespaces) --------------------------------------

/// Node's `path.posix` surface, callable from native Zig today. The JS-visible
/// wrappers re-land in Phase 12.2 when JSC string conversion is online.
///
/// Methods that need scratch space accept caller-provided buffers. The
/// `*Alloc` variants take a `std.mem.Allocator` and return owned slices.
pub const posix = struct {
    pub const sep: []const u8 = "/";
    pub const delimiter: []const u8 = ":";

    pub inline fn isAbsolute(path: []const u8) bool {
        return isAbsolutePosixT(u8, path);
    }

    pub inline fn dirname(path: []const u8) []const u8 {
        return dirnamePosixT(u8, path);
    }

    pub inline fn basename(path: []const u8, suffix: ?[]const u8) []const u8 {
        return basenamePosixT(u8, path, suffix);
    }

    pub inline fn extname(path: []const u8) []const u8 {
        return extnamePosixT(u8, path);
    }

    pub inline fn parse(path: []const u8) PathParsed(u8) {
        return parsePosixT(u8, path);
    }

    pub inline fn normalizeBuf(path: []const u8, buf: []u8) []const u8 {
        return normalizePosixT(u8, path, buf);
    }

    pub inline fn formatBuf(p: PathParsed(u8), buf: []u8) []const u8 {
        return _formatT(u8, p, '/', buf);
    }

    pub inline fn joinBuf(paths: []const []const u8, buf: []u8, buf2: []u8) []const u8 {
        return joinPosixT(u8, paths, buf, buf2);
    }

    pub inline fn resolveBuf(paths: []const []const u8, cwd: []const u8, buf: []u8, buf2: []u8) []const u8 {
        return resolvePosixT(u8, paths, cwd, buf, buf2);
    }

    pub inline fn relativeBuf(
        from: []const u8,
        to: []const u8,
        cwd: []const u8,
        buf: []u8,
        buf2: []u8,
        buf3: []u8,
    ) []const u8 {
        return relativePosixT(u8, from, to, cwd, buf, buf2, buf3);
    }

    /// Allocator-flavored convenience wrapper around `joinBuf`. Returned
    /// slice is owned by the caller.
    pub fn joinAlloc(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
        const buf = try allocator.alloc(u8, home_rt.paths.MAX_PATH_BYTES);
        defer allocator.free(buf);
        const buf2 = try allocator.alloc(u8, home_rt.paths.MAX_PATH_BYTES);
        defer allocator.free(buf2);
        const out = joinPosixT(u8, paths, buf, buf2);
        return allocator.dupe(u8, out);
    }

    /// Allocator-flavored convenience wrapper around `resolveBuf` that
    /// auto-supplies `process.cwd()`.
    pub fn resolveAlloc(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
        var cwd_buf: [home_rt.paths.MAX_PATH_BYTES]u8 = undefined;
        const cwd = std.process.getCwd(&cwd_buf) catch comptime L(u8, "/");
        const buf = try allocator.alloc(u8, home_rt.paths.MAX_PATH_BYTES);
        defer allocator.free(buf);
        const buf2 = try allocator.alloc(u8, home_rt.paths.MAX_PATH_BYTES);
        defer allocator.free(buf2);
        const out = resolvePosixT(u8, paths, cwd, buf, buf2);
        return allocator.dupe(u8, out);
    }
};

/// Node's `path.win32` surface. Same buffer-discipline as `posix`.
pub const win32 = struct {
    pub const sep: []const u8 = "\\";
    pub const delimiter: []const u8 = ";";

    pub inline fn isAbsolute(path: []const u8) bool {
        return isAbsoluteWindowsT(u8, path);
    }

    pub inline fn dirname(path: []const u8) []const u8 {
        return dirnameWindowsT(u8, path);
    }

    pub inline fn basename(path: []const u8, suffix: ?[]const u8) []const u8 {
        return basenameWindowsT(u8, path, suffix);
    }

    pub inline fn extname(path: []const u8) []const u8 {
        return extnameWindowsT(u8, path);
    }

    pub inline fn parse(path: []const u8) PathParsed(u8) {
        return parseWindowsT(u8, path);
    }

    pub inline fn normalizeBuf(path: []const u8, buf: []u8) []const u8 {
        return normalizeWindowsT(u8, path, buf);
    }

    pub inline fn formatBuf(p: PathParsed(u8), buf: []u8) []const u8 {
        return _formatT(u8, p, '\\', buf);
    }

    pub inline fn joinBuf(paths: []const []const u8, buf: []u8, buf2: []u8) []const u8 {
        return joinWindowsT(u8, paths, buf, buf2);
    }
};

// ---- Top-level dispatch (matches host platform) ----------------------------

/// Native separator for the host OS.
pub const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";

/// Native PATH-list delimiter for the host OS.
pub const delimiter: []const u8 = if (builtin.os.tag == .windows) ";" else ":";

pub inline fn isAbsolute(path: []const u8) bool {
    return if (builtin.os.tag == .windows) win32.isAbsolute(path) else posix.isAbsolute(path);
}

pub inline fn dirname(path: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) win32.dirname(path) else posix.dirname(path);
}

pub inline fn basename(path: []const u8, suffix: ?[]const u8) []const u8 {
    return if (builtin.os.tag == .windows) win32.basename(path, suffix) else posix.basename(path, suffix);
}

pub inline fn extname(path: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) win32.extname(path) else posix.extname(path);
}

pub inline fn parse(path: []const u8) PathParsed(u8) {
    return if (builtin.os.tag == .windows) win32.parse(path) else posix.parse(path);
}

pub inline fn normalizeBuf(path: []const u8, buf: []u8) []const u8 {
    return if (builtin.os.tag == .windows) win32.normalizeBuf(path, buf) else posix.normalizeBuf(path, buf);
}

pub inline fn formatBuf(p: PathParsed(u8), buf: []u8) []const u8 {
    return if (builtin.os.tag == .windows) win32.formatBuf(p, buf) else posix.formatBuf(p, buf);
}

pub inline fn joinBuf(paths: []const []const u8, buf: []u8, buf2: []u8) []const u8 {
    return if (builtin.os.tag == .windows) win32.joinBuf(paths, buf, buf2) else posix.joinBuf(paths, buf, buf2);
}

// ---- tests -----------------------------------------------------------------

test "path: separators and constants" {
    try std.testing.expectEqual(@as(u8, '/'), sep_posix);
    try std.testing.expectEqual(@as(u8, '\\'), sep_windows);
}

test "path: isAbsolutePosixT" {
    try std.testing.expect(isAbsolutePosixT(u8, "/foo/bar"));
    try std.testing.expect(!isAbsolutePosixT(u8, "foo/bar"));
    try std.testing.expect(!isAbsolutePosixT(u8, ""));
}

test "path: isAbsoluteWindowsT" {
    try std.testing.expect(isAbsoluteWindowsT(u8, "C:\\foo"));
    try std.testing.expect(isAbsoluteWindowsT(u8, "C:/foo"));
    try std.testing.expect(isAbsoluteWindowsT(u8, "\\foo"));
    try std.testing.expect(isAbsoluteWindowsT(u8, "/foo"));
    try std.testing.expect(!isAbsoluteWindowsT(u8, "foo"));
    try std.testing.expect(!isAbsoluteWindowsT(u8, "C:"));
}

test "path: basenamePosixT matches Node semantics" {
    try std.testing.expectEqualSlices(u8, "quux.html", basenamePosixT(u8, "/foo/bar/baz/quux.html", null));
    try std.testing.expectEqualSlices(u8, "quux", basenamePosixT(u8, "/foo/bar/baz/quux.html", ".html"));
    try std.testing.expectEqualSlices(u8, "", basenamePosixT(u8, "/", null));
    try std.testing.expectEqualSlices(u8, "foo", basenamePosixT(u8, "foo", null));
    try std.testing.expectEqualSlices(u8, "foo", basenamePosixT(u8, "/foo/", null));
}

test "path: dirnamePosixT matches Node semantics" {
    try std.testing.expectEqualSlices(u8, "/foo/bar", dirnamePosixT(u8, "/foo/bar/baz"));
    try std.testing.expectEqualSlices(u8, "/", dirnamePosixT(u8, "/foo"));
    try std.testing.expectEqualSlices(u8, ".", dirnamePosixT(u8, ""));
    try std.testing.expectEqualSlices(u8, ".", dirnamePosixT(u8, "foo"));
}

test "path: extnamePosixT matches Node semantics" {
    try std.testing.expectEqualSlices(u8, ".html", extnamePosixT(u8, "index.html"));
    // Node's extname returns the slice from the *last* dot; "coffee.md" → ".md".
    try std.testing.expectEqualSlices(u8, ".md", extnamePosixT(u8, "index.coffee.md"));
    try std.testing.expectEqualSlices(u8, ".", extnamePosixT(u8, "index."));
    try std.testing.expectEqualSlices(u8, "", extnamePosixT(u8, ".hidden"));
    try std.testing.expectEqualSlices(u8, "", extnamePosixT(u8, ""));
}

test "path: normalizePosixT collapses dots and slashes" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "foo/bar", normalizePosixT(u8, "foo//bar", &buf));
    try std.testing.expectEqualSlices(u8, "foo/bar", normalizePosixT(u8, "./foo/bar", &buf));
    try std.testing.expectEqualSlices(u8, "foo/baz", normalizePosixT(u8, "foo/bar/../baz", &buf));
    try std.testing.expectEqualSlices(u8, "/foo/baz", normalizePosixT(u8, "/foo/bar/../baz", &buf));
    try std.testing.expectEqualSlices(u8, ".", normalizePosixT(u8, "", &buf));
    try std.testing.expectEqualSlices(u8, "/", normalizePosixT(u8, "/", &buf));
}

test "path: parsePosixT yields root/dir/base/ext/name" {
    const r = parsePosixT(u8, "/home/user/file.txt");
    try std.testing.expectEqualSlices(u8, "/", r.root);
    try std.testing.expectEqualSlices(u8, "/home/user", r.dir);
    try std.testing.expectEqualSlices(u8, "file.txt", r.base);
    try std.testing.expectEqualSlices(u8, ".txt", r.ext);
    try std.testing.expectEqualSlices(u8, "file", r.name);

    const r2 = parsePosixT(u8, "");
    try std.testing.expectEqualSlices(u8, "", r2.root);
    try std.testing.expectEqualSlices(u8, "", r2.dir);
    try std.testing.expectEqualSlices(u8, "", r2.base);
}

test "path: parseWindowsT handles drive letters and UNC roots" {
    const r = parseWindowsT(u8, "C:\\foo\\bar.txt");
    try std.testing.expectEqualSlices(u8, "C:\\", r.root);
    try std.testing.expectEqualSlices(u8, "C:\\foo", r.dir);
    try std.testing.expectEqualSlices(u8, "bar.txt", r.base);
    try std.testing.expectEqualSlices(u8, ".txt", r.ext);
    try std.testing.expectEqualSlices(u8, "bar", r.name);

    // Bare drive: root and dir both the path, base/ext/name empty.
    const r2 = parseWindowsT(u8, "C:");
    try std.testing.expectEqualSlices(u8, "C:", r2.root);
    try std.testing.expectEqualSlices(u8, "C:", r2.dir);
    try std.testing.expectEqualSlices(u8, "", r2.base);
}

test "path: _formatT round-trips parsePosixT" {
    var buf: [256]u8 = undefined;
    const parsed = parsePosixT(u8, "/foo/bar/file.txt");
    const out = _formatT(u8, parsed, '/', &buf);
    try std.testing.expectEqualSlices(u8, "/foo/bar/file.txt", out);
}

test "path: isSep helpers" {
    try std.testing.expect(isSepPosixT(u8, '/'));
    try std.testing.expect(!isSepPosixT(u8, '\\'));
    try std.testing.expect(isSepWindowsT(u8, '/'));
    try std.testing.expect(isSepWindowsT(u8, '\\'));
    try std.testing.expect(!isSepWindowsT(u8, 'a'));
}

test "path: isWindowsDeviceRootT accepts ASCII letters only" {
    try std.testing.expect(isWindowsDeviceRootT(u8, 'C'));
    try std.testing.expect(isWindowsDeviceRootT(u8, 'z'));
    try std.testing.expect(!isWindowsDeviceRootT(u8, '0'));
    try std.testing.expect(!isWindowsDeviceRootT(u8, '/'));
}

// ---- Phase 12.7 Node-shape API tests ---------------------------------------

test "path.posix.join: basic concatenation" {
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "/a/b", posix.joinBuf(&.{ "/a", "b" }, &buf, &buf2));
    try std.testing.expectEqualSlices(u8, "/a/b/c", posix.joinBuf(&.{ "/a", "b", "c" }, &buf, &buf2));
    try std.testing.expectEqualSlices(u8, "foo/bar/baz", posix.joinBuf(&.{ "foo", "bar", "baz" }, &buf, &buf2));
    try std.testing.expectEqualSlices(u8, ".", posix.joinBuf(&.{}, &buf, &buf2));
    try std.testing.expectEqualSlices(u8, "foo/baz", posix.joinBuf(&.{ "foo", "bar", "..", "baz" }, &buf, &buf2));
}

test "path.posix.resolve: against explicit cwd" {
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "/work/foo", posix.resolveBuf(&.{"foo"}, "/work", &buf, &buf2));
    try std.testing.expectEqualSlices(u8, "/abs", posix.resolveBuf(&.{"/abs"}, "/work", &buf, &buf2));
    try std.testing.expectEqualSlices(u8, "/work/a/b", posix.resolveBuf(&.{ "a", "b" }, "/work", &buf, &buf2));
    try std.testing.expectEqualSlices(u8, "/a/c", posix.resolveBuf(&.{ "/a/b", "../c" }, "/cwd", &buf, &buf2));
}

test "path.posix.normalize: dot collapse" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "/a/c", posix.normalizeBuf("/a/./b/../c", &buf));
}

test "path.posix.isAbsolute / dirname / basename / extname round-trip" {
    try std.testing.expect(posix.isAbsolute("/x"));
    try std.testing.expect(!posix.isAbsolute("x"));

    try std.testing.expectEqualSlices(u8, "/a/b", posix.dirname("/a/b/c.txt"));
    try std.testing.expectEqualSlices(u8, "c.txt", posix.basename("/a/b/c.txt", null));
    try std.testing.expectEqualSlices(u8, "c", posix.basename("/a/b/c.txt", ".txt"));
    try std.testing.expectEqualSlices(u8, ".txt", posix.extname("/a/b/c.txt"));
}

test "path.posix.parse / format: round-trip" {
    var buf: [256]u8 = undefined;
    const parsed = posix.parse("/home/user/file.txt");
    try std.testing.expectEqualSlices(u8, "/", parsed.root);
    try std.testing.expectEqualSlices(u8, "/home/user", parsed.dir);
    try std.testing.expectEqualSlices(u8, "file.txt", parsed.base);
    try std.testing.expectEqualSlices(u8, ".txt", parsed.ext);
    try std.testing.expectEqualSlices(u8, "file", parsed.name);

    const formatted = posix.formatBuf(parsed, &buf);
    try std.testing.expectEqualSlices(u8, "/home/user/file.txt", formatted);
}

test "path.posix.relative: produces .. segments" {
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    var buf3: [256]u8 = undefined;
    // From /data/orandea/test/aaa we walk up out of `aaa` and `test` to the
    // common ancestor /data/orandea, then descend into impl/bbb.
    try std.testing.expectEqualSlices(u8, "../../impl/bbb", posix.relativeBuf("/data/orandea/test/aaa", "/data/orandea/impl/bbb", "/", &buf, &buf2, &buf3));
    try std.testing.expectEqualSlices(u8, "", posix.relativeBuf("/same/x", "/same/x", "/", &buf, &buf2, &buf3));
}

test "path.posix constants" {
    try std.testing.expectEqualSlices(u8, "/", posix.sep);
    try std.testing.expectEqualSlices(u8, ":", posix.delimiter);
}

test "path.win32 constants and isAbsolute" {
    try std.testing.expectEqualSlices(u8, "\\", win32.sep);
    try std.testing.expectEqualSlices(u8, ";", win32.delimiter);
    try std.testing.expect(win32.isAbsolute("C:\\foo"));
    try std.testing.expect(!win32.isAbsolute("foo"));
}

test "path.win32.join: backslash joiner" {
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "C:\\foo\\bar", win32.joinBuf(&.{ "C:\\foo", "bar" }, &buf, &buf2));
}

test "path: top-level dispatch matches host platform" {
    // On POSIX hosts the top-level sep is '/', and on Windows it's '\\'.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualSlices(u8, "\\", sep);
        try std.testing.expectEqualSlices(u8, ";", delimiter);
    } else {
        try std.testing.expectEqualSlices(u8, "/", sep);
        try std.testing.expectEqualSlices(u8, ":", delimiter);
        try std.testing.expect(isAbsolute("/x"));
        try std.testing.expect(!isAbsolute("x"));
        try std.testing.expectEqualSlices(u8, ".txt", extname("file.txt"));
    }
}

test "path.posix.joinAlloc: allocator wrapper" {
    const allocator = std.testing.allocator;
    const out = try posix.joinAlloc(allocator, &.{ "/a", "b", "c" });
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, "/a/b/c", out);
}

// Reference unused symbols to keep them live for downstream consumers and
// the dead-code linter.
comptime {
    _ = sep_str_posix;
    _ = sep_str_windows;
    _ = MAX_PATH_SIZE;
    _ = PATH_SIZE;
    _ = basenameWindowsT;
    _ = dirnameWindowsT;
    _ = extnameWindowsT;
    _ = normalizeT;
    _ = normalizeWindowsT;
    _ = Environment;
    _ = posix;
    _ = win32;
    _ = sep;
    _ = delimiter;
}
