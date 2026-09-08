// Copied from Bun's SystemError; MIT — see ../cli/LICENSE.bun.md.
// Native C ABI and error conversion use Home's live JSC bridge. Diagnostic
// formatting mirrors the pinned runtime and shares Home's output color policy.

const std = @import("std");
const bun = @import("home");

// Native JSC bridge types.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
const JSValue = @import("home").jsc.JSValue;
const JSPromise = @import("./JSPromise.zig").JSPromise;

// JSC bridge: the real `bun.String` (WTF-backed BunString) is now present;
// reference it directly so SystemError fields share its type identity.
const String = @import("home").String;

// `bun.sys.E` errno enum — now live via the sys layer. Must be the real
// per-platform enum (not a `{ SUCCESS = 0, _ }` stub): getErrno()'s result is
// passed to `@tagName` in log/format paths, which panics in debug builds on an
// unnamed value (e.g. EPIPE=32) if the enum has no matching tag.
pub const SysE = @import("home").sys.E;

pub const SystemError = extern struct {
    errno: c_int = 0,
    /// label for errno
    code: String = .empty,
    message: String, // it is illegal to have an empty message
    path: String = .empty,
    syscall: String = .empty,
    hostname: String = .empty,
    /// MinInt = no file descriptor
    fd: c_int = std.math.minInt(c_int),
    dest: String = .empty,

    pub fn Maybe(comptime Result: type) type {
        return union(enum) {
            err: SystemError,
            result: Result,
        };
    }

    extern fn SystemError__toErrorInstance(this: *const SystemError, global: *JSGlobalObject) JSValue;
    extern fn SystemError__toErrorInstanceWithInfoObject(this: *const SystemError, global: *JSGlobalObject) JSValue;

    pub fn getErrno(this: *const SystemError) SysE {
        // The inverse in bun.sys.Error.toSystemError()
        return @fromBackingInt(@intCast(this.errno * -1));
    }

    pub fn deref(this: *const SystemError) void {
        this.path.deref();
        this.code.deref();
        this.message.deref();
        this.syscall.deref();
        this.hostname.deref();
        this.dest.deref();
    }

    pub fn ref(this: *SystemError) void {
        this.path.ref();
        this.code.ref();
        this.message.ref();
        this.syscall.ref();
        this.hostname.ref();
        this.dest.ref();
    }

    pub fn toErrorInstance(this: *const SystemError, global: *JSGlobalObject) JSValue {
        defer this.deref();
        return SystemError__toErrorInstance(this, global);
    }

    /// Like `toErrorInstance` but populates the error's stack trace with async
    /// frames from the given promise's await chain. Use when creating an error
    /// from native code at the top of the event loop (threadpool callback) to
    /// reject a promise — otherwise the error has an empty stack (e.g.
    /// `await Bun.file("/nope").text()` had `err.stack === undefined`).
    pub fn toErrorInstanceWithAsyncStack(this: *const SystemError, global: *JSGlobalObject, promise: *JSPromise) JSValue {
        defer this.deref();
        const err = SystemError__toErrorInstance(this, global);
        err.attachAsyncStackFromPromise(global, promise);
        return err;
    }

    /// This constructs the ERR_SYSTEM_ERROR error object, which has an `info`
    /// property containing the details of the system error:
    ///
    /// SystemError [ERR_SYSTEM_ERROR]: A system error occurred: {syscall} returned {errno} ({message})
    /// {
    ///     name: "ERR_SYSTEM_ERROR",
    ///     info: {
    ///         errno: -{errno},
    ///         code: {code},        // string
    ///         message: {message},  // string
    ///         syscall: {syscall},  // string
    ///     },
    ///     errno: -{errno},
    ///     syscall: {syscall},
    /// }
    ///
    /// Before using this function, consider if the Node.js API it is
    /// implementing follows this convention. It is exclusively used
    /// to match the error code that `node:os` throws.
    pub fn toErrorInstanceWithInfoObject(this: *const SystemError, global: *JSGlobalObject) JSValue {
        defer this.deref();
        return SystemError__toErrorInstanceWithInfoObject(this, global);
    }

    pub fn format(self: SystemError, writer: *std.Io.Writer) !void {
        if (!self.path.isEmpty()) {
            // TODO: remove this hardcoding
            switch (bun.Output.enable_ansi_colors_stderr) {
                inline else => |enable_colors| try writer.print(
                    comptime bun.Output.prettyFmt(
                        "<r><red>{f}<r><d>:<r> <b>{f}<r>: {f} <d>({f}())<r>",
                        enable_colors,
                    ),
                    .{
                        self.code,
                        self.path,
                        self.message,
                        self.syscall,
                    },
                ),
            }
        } else
        // TODO: remove this hardcoding
        switch (bun.Output.enable_ansi_colors_stderr) {
            inline else => |enable_colors| try writer.print(
                comptime bun.Output.prettyFmt(
                    "<r><red>{f}<r><d>:<r> {f} <d>({f}())<r>",
                    enable_colors,
                ),
                .{
                    self.code,
                    self.message,
                    self.syscall,
                },
            ),
        }
    }
};

test "SystemError carries the expected fields in order" {
    const info = @typeInfo(SystemError).@"struct";
    try std.testing.expect(info.layout == .@"extern");
    try std.testing.expectEqualStrings("errno", info.field_names[0]);
    try std.testing.expectEqualStrings("code", info.field_names[1]);
    try std.testing.expectEqualStrings("message", info.field_names[2]);
    try std.testing.expectEqualStrings("path", info.field_names[3]);
    try std.testing.expectEqualStrings("syscall", info.field_names[4]);
    try std.testing.expectEqualStrings("hostname", info.field_names[5]);
    try std.testing.expectEqualStrings("fd", info.field_names[6]);
    try std.testing.expectEqualStrings("dest", info.field_names[7]);
}

test "SystemError default state has the expected sentinel values" {
    const err: SystemError = .{ .message = .empty };
    try std.testing.expectEqual(@as(c_int, 0), err.errno);
    try std.testing.expectEqual(std.math.minInt(c_int), err.fd);
    try std.testing.expect(err.code.isEmpty());
    try std.testing.expect(err.message.isEmpty());
    try std.testing.expect(err.path.isEmpty());
}

test "SystemError.Maybe(T) is a tagged union with err/result arms" {
    const M = SystemError.Maybe(u32);
    const info = @typeInfo(M).@"union";
    try std.testing.expectEqualStrings("err", info.field_names[0]);
    try std.testing.expectEqualStrings("result", info.field_names[1]);
}

test "SystemError.getErrno inverts the sign of errno" {
    const err: SystemError = .{ .message = .empty, .errno = -5 };
    try std.testing.expectEqual(@as(i32, 5), @backingInt(err.getErrno()));
}
