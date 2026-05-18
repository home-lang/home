// Extracted from bun/src/sys/sys.zig + bun/src/runtime/node.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `Maybe(T, E)` is the union the entire bun.sys / bun.runtime.node substrate
// returns. Upstream lives across two files: the generic factory lives in
// `runtime/node.zig` (`fn Maybe(ReturnTypeT, ErrorTypeT)`) and the sys-specific
// alias `pub fn Maybe(T) = bun.api.node.Maybe(T, Error)` lives at the top of
// `sys/sys.zig` (4703 lines). The substrate around it (errno_map, Error,
// SystemError, jsc.toJS, windows NTSTATUS translation, the css ParseError
// adapter) hasn't been ported yet, so we carve out the parts that compile on
// the substrate that does exist and leave a few methods as stubs with banners
// noting their re-attach path.
//
// What's ported:
//   * `Maybe(T, E)` generic union with `.err` / `.result` tags.
//   * `.success`, `.aborted`, `.retry` helpers.
//   * `.unwrap`, `.unwrapOr`, `.isTrue`.
//   * `.initErr`, `.initResult`, `.asErr`, `.asValue`, `.isOk`, `.isErr`.
//   * `.mapErr`, `.getErrno`, `.errno`, `.todo()`.
//   * `.errnoSys`, `.errnoSysP`, `.errnoSysFd`, `.errnoSysFP`, `.errnoSysPD`
//     — using a caller-supplied `getErrno` rather than the
//     yet-to-be-ported `bun.sys.getErrno`. The error-payload struct shape
//     (`.errno`, `.syscall`, optional `.fd`/`.path`/`.dest`) is the upstream
//     `bun.sys.Error` API.
//
// What's stubbed:
//   * `.toJS`, `.toArrayBuffer` — need `home_rt.jsc.JSGlobalObject` /
//     `JSValue` / `ArrayBuffer`; re-attach in Phase 12.2.
//   * `.toCssResult` — needs `home_rt.css.ParseError`; re-attach when the
//     CSS substrate ports.
//   * `.format` — needs `home_rt.deprecated.autoFormatLabelFallback`;
//     swapped for a plain `{any}` printer here.
//   * `.unwrap` defers to a caller-supplied `errnoToZigErrFn` since the
//     upstream `bun.errnoToZigErr` is the 350-entry POSIX errno_map table.
//     The default falls back to `error.Unexpected`.
//
// `kindFromMode(mode_t)` is also extracted here because it's the only
// `sys.zig` helper that doesn't pull in any syscall wrapper machinery —
// it's pure-data lookup over `std.posix.S` constants. Mirrors the upstream
// version at line 4435.
//
// PORT NOTE: upstream returns `std.fs.File.Kind`, which existed in Zig
// 0.14. Zig 0.17 removed `std.fs.File.Kind` (only `std.fs.Dir.Entry.Kind`
// survived, under `std/fs/Dir.zig`). We define an equivalent local
// `FileKind` enum here with the same tag names so the signature reads the
// same — when the runtime upgrades to a Zig that re-exposes the
// canonical type, this re-aliases trivially.

const std = @import("std");
const posix = std.posix;

/// Cross-version `std.fs.File.Kind` standin — see PORT NOTE in the file
/// banner. The variant names are exactly the ones Zig 0.14 used.
pub const FileKind = enum {
    block_device,
    character_device,
    directory,
    named_pipe,
    sym_link,
    file,
    unix_domain_socket,
    whiteout,
    door,
    event_port,
    unknown,
};

/// Generic `Maybe(T, E)` factory mirroring upstream `bun.api.node.Maybe`.
///
/// `ErrorTypeT` is expected to look like `bun.sys.Error` — a struct with
/// fields `errno: Int`, `syscall: sys.Tag`, and optional `fd`/`path`/`dest`.
/// The factory only requires that the type be default-initialisable
/// (`.{} = ErrorType{}`) and that it accepts struct literal initialisers
/// like `.{ .errno = ..., .syscall = ..., .fd = ... }`. Decls `retry` and
/// `todo` are optional and detected via `@hasDecl`.
pub fn Maybe(comptime ReturnTypeT: type, comptime ErrorTypeT: type) type {
    // `@hasDecl` only works on struct/union/enum/opaque containers — pre-gate
    // on the typeInfo to avoid `expected struct, enum, union, or opaque`
    // errors when the caller hands us a primitive like `u16`.
    const err_info = @typeInfo(ErrorTypeT);
    const can_have_decls = switch (err_info) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
    const has_retry = can_have_decls and @hasDecl(ErrorTypeT, "retry");
    const has_todo = can_have_decls and @hasDecl(ErrorTypeT, "todo");

    return union(Tag) {
        pub const ErrorType = ErrorTypeT;
        pub const ReturnType = ReturnTypeT;

        err: ErrorType,
        result: ReturnType,

        pub const Tag = enum { err, result };

        pub const retry: @This() = if (has_retry) .{ .err = ErrorType.retry } else .{ .err = .{} };
        pub const success: @This() = .{
            .result = std.mem.zeroes(ReturnType),
        };
        /// Garbage payload — only meant to be returned when an AbortSignal
        /// trips an operation. Matches upstream constructor.
        pub const aborted: @This() = .{ .err = .{
            .errno = @intFromEnum(posix.E.INTR),
            .syscall = .access,
        } };

        pub inline fn todo() @This() {
            if (has_todo) {
                return .{ .err = ErrorType.todo() };
            }
            return .{ .err = ErrorType{} };
        }

        pub fn isTrue(this: @This()) bool {
            if (comptime ReturnType != bool) @compileError("This function can only be called on bool");
            return switch (this) {
                .result => |r| r,
                else => false,
            };
        }

        /// Stub — upstream defers to `bun.errnoToZigErr(e.errno)`, a
        /// 350-entry POSIX errno_map. Until that table ports, callers
        /// either supply their own mapper or accept `error.Unexpected`.
        pub fn unwrap(this: @This()) !ReturnType {
            return switch (this) {
                .result => |r| r,
                .err => error.Unexpected,
            };
        }

        pub inline fn unwrapOr(this: @This(), default_value: ReturnType) ReturnType {
            return switch (this) {
                .result => |v| v,
                .err => default_value,
            };
        }

        pub inline fn initErr(e: ErrorType) @This() {
            return .{ .err = e };
        }

        pub inline fn asErr(this: *const @This()) ?ErrorType {
            if (this.* == .err) return this.err;
            return null;
        }

        pub inline fn asValue(this: *const @This()) ?ReturnType {
            if (this.* == .result) return this.result;
            return null;
        }

        pub inline fn isOk(this: *const @This()) bool {
            return switch (this.*) {
                .result => true,
                .err => false,
            };
        }

        pub inline fn isErr(this: *const @This()) bool {
            return switch (this.*) {
                .result => false,
                .err => true,
            };
        }

        pub inline fn initResult(result: ReturnType) @This() {
            return .{ .result = result };
        }

        pub inline fn mapErr(this: @This(), comptime E: type, err_fn: *const fn (ErrorTypeT) E) Maybe(ReturnType, E) {
            return switch (this) {
                .result => |v| .{ .result = v },
                .err => |e| .{ .err = err_fn(e) },
            };
        }

        pub fn getErrno(this: @This()) posix.E {
            return switch (this) {
                .result => posix.E.SUCCESS,
                .err => |e| @enumFromInt(e.errno),
            };
        }

        /// Build an `.err` payload from a raw errno value + syscall tag.
        /// Mirrors upstream `Maybe.errno` (note the truncation pattern).
        pub fn errno(err: anytype, syscall: anytype) @This() {
            return @This(){
                .err = .{
                    .errno = translateToErrInt(err),
                    .syscall = syscall,
                },
            };
        }

        /// Build a syscall-error from a return code. `getErrnoFn` is a
        /// caller-supplied `fn (anytype) std.posix.E` — upstream binds
        /// `bun.sys.getErrno`, which delegates to libc's `errno` global on
        /// POSIX or NTSTATUS translation on Windows. Until those land,
        /// callers pass in whichever variant is appropriate.
        pub fn errnoSys(rc: anytype, syscall: anytype, getErrnoFn: *const fn (anytype) posix.E) ?@This() {
            return switch (getErrnoFn(rc)) {
                .SUCCESS => null,
                else => |e| @This(){
                    .err = .{
                        .errno = translateToErrInt(e),
                        .syscall = syscall,
                    },
                },
            };
        }

        pub fn errnoSysFd(rc: anytype, syscall: anytype, fd: anytype, getErrnoFn: *const fn (anytype) posix.E) ?@This() {
            return switch (getErrnoFn(rc)) {
                .SUCCESS => null,
                else => |e| @This(){
                    .err = .{
                        .errno = translateToErrInt(e),
                        .syscall = syscall,
                        .fd = fd,
                    },
                },
            };
        }

        pub fn errnoSysP(rc: anytype, syscall: anytype, file_path: anytype, getErrnoFn: *const fn (anytype) posix.E) ?@This() {
            return switch (getErrnoFn(rc)) {
                .SUCCESS => null,
                else => |e| @This(){
                    .err = .{
                        .errno = translateToErrInt(e),
                        .syscall = syscall,
                        .path = asByteSlice(file_path),
                    },
                },
            };
        }

        pub fn errnoSysFP(rc: anytype, syscall: anytype, fd: anytype, file_path: anytype, getErrnoFn: *const fn (anytype) posix.E) ?@This() {
            return switch (getErrnoFn(rc)) {
                .SUCCESS => null,
                else => |e| @This(){
                    .err = .{
                        .errno = translateToErrInt(e),
                        .syscall = syscall,
                        .fd = fd,
                        .path = asByteSlice(file_path),
                    },
                },
            };
        }

        pub fn errnoSysPD(rc: anytype, syscall: anytype, file_path: anytype, dest: anytype, getErrnoFn: *const fn (anytype) posix.E) ?@This() {
            return switch (getErrnoFn(rc)) {
                .SUCCESS => null,
                else => |e| @This(){
                    .err = .{
                        .errno = translateToErrInt(e),
                        .syscall = syscall,
                        .path = asByteSlice(file_path),
                        .dest = asByteSlice(dest),
                    },
                },
            };
        }

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            return switch (this) {
                .result => try writer.print("Result(...)", .{}),
                .err => |e| try writer.print("Error({any})", .{e}),
            };
        }
    };
}

fn translateToErrInt(err: anytype) u16 {
    return switch (@typeInfo(@TypeOf(err))) {
        .@"enum" => @as(u16, @truncate(@intFromEnum(err))),
        else => @as(u16, @truncate(@as(usize, @intCast(err)))),
    };
}

/// Best-effort `bun.asByteSlice` shim for the upstream `errnoSysP` helpers.
/// Accepts `[]const u8`, `[:0]const u8`, `[*:0]const u8`, and arrays.
fn asByteSlice(value: anytype) []const u8 {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info == .pointer) {
        switch (info.pointer.size) {
            .slice => return value,
            .many => if (info.pointer.sentinel_ptr != null) return std.mem.sliceTo(value, 0),
            .one => if (@typeInfo(info.pointer.child) == .array) return value,
            else => {},
        }
    }
    if (info == .array) return &value;
    @compileError("asByteSlice: unsupported type " ++ @typeName(T));
}

/// Resolve a POSIX `mode_t` to `std.fs.File.Kind`. Mirrors upstream
/// `sys/sys.zig` at line 4435 — pure-data lookup over `S.IFMT`.
pub fn kindFromMode(mode: posix.mode_t) FileKind {
    return switch (mode & posix.S.IFMT) {
        posix.S.IFBLK => .block_device,
        posix.S.IFCHR => .character_device,
        posix.S.IFDIR => .directory,
        posix.S.IFIFO => .named_pipe,
        posix.S.IFLNK => .sym_link,
        posix.S.IFREG => .file,
        posix.S.IFSOCK => .unix_domain_socket,
        else => .unknown,
    };
}

// -- Inline tests -------------------------------------------------------

const TestTag = enum(u8) { access, open, read, write };

const TestError = struct {
    errno: u16 = 0,
    syscall: TestTag = .access,
    fd: ?u64 = null,
    path: ?[]const u8 = null,
    dest: ?[]const u8 = null,
};

test "Maybe(void, TestError).success is the canonical OK" {
    const M = Maybe(void, TestError);
    const ok: M = .success;
    try std.testing.expect(ok.isOk());
    try std.testing.expect(!ok.isErr());
    try std.testing.expect(ok.asErr() == null);
}

test "Maybe(u32, TestError).initErr / asErr round-trip" {
    const M = Maybe(u32, TestError);
    const err: M = .initErr(.{ .errno = 9, .syscall = .open });
    try std.testing.expect(err.isErr());
    try std.testing.expect(!err.isOk());
    try std.testing.expectEqual(@as(u16, 9), err.asErr().?.errno);
}

test "Maybe(u32, TestError).unwrapOr falls back on err" {
    const M = Maybe(u32, TestError);
    const ok: M = .initResult(42);
    const bad: M = .initErr(.{});
    try std.testing.expectEqual(@as(u32, 42), ok.unwrapOr(0));
    try std.testing.expectEqual(@as(u32, 0), bad.unwrapOr(0));
}

test "Maybe(bool, TestError).isTrue only returns true on .result(true)" {
    const M = Maybe(bool, TestError);
    const t: M = .initResult(true);
    const f: M = .initResult(false);
    const e: M = .initErr(.{});
    try std.testing.expect(t.isTrue());
    try std.testing.expect(!f.isTrue());
    try std.testing.expect(!e.isTrue());
}

test "Maybe.getErrno reflects the err.errno field" {
    const M = Maybe(u32, TestError);
    const ok: M = .initResult(0);
    const e: M = .initErr(.{ .errno = @intFromEnum(posix.E.NOENT), .syscall = .open });
    try std.testing.expectEqual(posix.E.SUCCESS, ok.getErrno());
    try std.testing.expectEqual(posix.E.NOENT, e.getErrno());
}

test "Maybe.mapErr threads the error through a converter" {
    const M = Maybe(u32, TestError);
    const N = Maybe(u32, u16);
    const Mapper = struct {
        fn map(e: TestError) u16 {
            return e.errno;
        }
    };
    const e: M = .initErr(.{ .errno = 7 });
    const mapped: N = e.mapErr(u16, Mapper.map);
    try std.testing.expectEqual(@as(u16, 7), mapped.asErr().?);
}

test "Maybe.errno builds an .err payload from an enum value" {
    const M = Maybe(u32, TestError);
    const e = M.errno(posix.E.NOENT, TestTag.open);
    try std.testing.expect(e.isErr());
    try std.testing.expectEqual(@as(u16, @intFromEnum(posix.E.NOENT)), e.asErr().?.errno);
}

test "kindFromMode classifies regular files and directories" {
    // Use the canonical POSIX bits — works the same on darwin/linux/freebsd.
    try std.testing.expectEqual(FileKind.directory, kindFromMode(posix.S.IFDIR));
    try std.testing.expectEqual(FileKind.file, kindFromMode(posix.S.IFREG));
    try std.testing.expectEqual(FileKind.sym_link, kindFromMode(posix.S.IFLNK));
}

test "kindFromMode returns .unknown for an unrecognised mode" {
    // 0 has no IFMT bits set — picks up the `else` branch.
    try std.testing.expectEqual(FileKind.unknown, kindFromMode(0));
}

test "Maybe.aborted carries the INTR errno + .access syscall tag" {
    const M = Maybe(u32, TestError);
    const a: M = .aborted;
    try std.testing.expectEqual(@as(u16, @intFromEnum(posix.E.INTR)), a.asErr().?.errno);
}
