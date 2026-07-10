// Copied from bun/src/s3_signing/error.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").
//
// Stubs vs. upstream: the JSC-facing helpers (`getJSSignError`, `throwSignError`,
// `S3Error.toJS`, `S3Error.toJSWithAsyncStack`) live in
// `runtime/webcore/s3/error_jsc.zig` upstream — that file is not yet ported.
// We keep the pure-data parts (`ErrorCodeAndMessage`, `S3Error`, message/code
// lookup) which are useful to the signer + transport layers. The JSC bindings
// can be re-attached when webcore is wired up.

//! S3 signer error code + message lookup. Pure data, no JSC.
pub const ErrorCodeAndMessage = struct {
    code: []const u8,
    message: []const u8,
};

pub fn getSignErrorMessage(comptime err: anyerror) [:0]const u8 {
    return switch (err) {
        error.MissingCredentials => "Missing S3 credentials. 'accessKeyId', 'secretAccessKey', 'bucket', and 'endpoint' are required",
        error.InvalidMethod => "Method must be GET, PUT, DELETE or HEAD when using s3:// protocol",
        error.InvalidPath => "Invalid S3 bucket, key combination",
        error.InvalidEndpoint => "Invalid S3 endpoint",
        error.InvalidSessionToken => "Invalid session token",
        else => "Failed to retrieve S3 content. Are the credentials correct?",
    };
}

pub fn getSignErrorCodeAndMessage(err: anyerror) ErrorCodeAndMessage {
    // keep error codes consistent for internal errors
    return switch (err) {
        error.MissingCredentials => .{ .code = "ERR_S3_MISSING_CREDENTIALS", .message = getSignErrorMessage(error.MissingCredentials) },
        error.InvalidMethod => .{ .code = "ERR_S3_INVALID_METHOD", .message = getSignErrorMessage(error.InvalidMethod) },
        error.InvalidPath => .{ .code = "ERR_S3_INVALID_PATH", .message = getSignErrorMessage(error.InvalidPath) },
        error.InvalidEndpoint => .{ .code = "ERR_S3_INVALID_ENDPOINT", .message = getSignErrorMessage(error.InvalidEndpoint) },
        error.InvalidSessionToken => .{ .code = "ERR_S3_INVALID_SESSION_TOKEN", .message = getSignErrorMessage(error.InvalidSessionToken) },
        else => .{ .code = "ERR_S3_INVALID_SIGNATURE", .message = getSignErrorMessage(error.SignError) },
    };
}

pub const S3Error = struct {
    code: []const u8,
    message: []const u8,

    // The `*JSGlobalObject`-taking variants live in the JSC bridge layer
    // (`runtime/webcore/s3/error_jsc.zig`), which now exists. Aliasing to them
    // (Bun's exact shape) makes `err.toJS(global, path)` build a real
    // ERR_S3_* error instance instead of returning `.zero` — the stub caused
    // a null JSValue to flow into the stream error path and trip the
    // exception-presence assertion (S3 stream error with no credentials).
    pub const toJS = @import("../runtime/webcore/s3/error_jsc.zig").s3ErrorToJS;
    pub const toJSWithAsyncStack = @import("../runtime/webcore/s3/error_jsc.zig").s3ErrorToJSWithAsyncStack;
};

test "getSignErrorMessage maps known errors" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, getSignErrorMessage(error.MissingCredentials), "Missing S3 credentials") != null);
    try std.testing.expect(std.mem.indexOf(u8, getSignErrorMessage(error.InvalidMethod), "Method must be GET") != null);
    try std.testing.expect(std.mem.indexOf(u8, getSignErrorMessage(error.InvalidPath), "Invalid S3 bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, getSignErrorMessage(error.InvalidEndpoint), "Invalid S3 endpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, getSignErrorMessage(error.InvalidSessionToken), "Invalid session token") != null);
}

test "getSignErrorMessage falls back to generic message for unknown errors" {
    const std = @import("std");
    const msg = getSignErrorMessage(error.SignError);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Failed to retrieve S3 content") != null);
}

test "getSignErrorCodeAndMessage pairs codes with messages" {
    const std = @import("std");
    const ec = getSignErrorCodeAndMessage(error.MissingCredentials);
    try std.testing.expectEqualStrings("ERR_S3_MISSING_CREDENTIALS", ec.code);
    try std.testing.expect(std.mem.indexOf(u8, ec.message, "accessKeyId") != null);

    const path_ec = getSignErrorCodeAndMessage(error.InvalidPath);
    try std.testing.expectEqualStrings("ERR_S3_INVALID_PATH", path_ec.code);

    const fallback = getSignErrorCodeAndMessage(error.SomeOtherError);
    try std.testing.expectEqualStrings("ERR_S3_INVALID_SIGNATURE", fallback.code);
}

test "S3Error struct fields" {
    const std = @import("std");
    const e = S3Error{ .code = "ERR_X", .message = "msg" };
    try std.testing.expectEqualStrings("ERR_X", e.code);
    try std.testing.expectEqualStrings("msg", e.message);
}

comptime {
    // Touch home_rt to mirror upstream's `@import("bun")` wiring even though
    // the pure-data subset compiled here has no runtime dependency on it.
    _ = @import("home");
}
