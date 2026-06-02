// Copied from bun/src/runtime/api/csrf_jsc.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the matching surface):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `JSValue`, `JSError`,
//     `jsc.ZigString.Slice`, `jsc.Node.Encoding`, `jsc.API.Bun.Crypto.EVP.*`,
//     plus the `bun.analytics.Features` counters — none of those are on
//     home_rt yet. The two host fns (`csrf__generate`, `csrf__verify`) are
//     ported as call-frame-driven skeletons: argument-shape branches are
//     preserved so the JS-side validation logic is recoverable, but every
//     access to the JSC surface goes through the local opaque/stub layer.
//   - `boring.EVP_MAX_MD_SIZE` — folded to the constant 64 (BoringSSL's
//     compile-time max for all currently supported digests). Swap to the
//     real symbol when `home_rt.boringssl_sys.EVP_MAX_MD_SIZE` lands.
//   - The pure `generate()`/`verify()` halves continue to live in
//     `src/csrf/` and are imported via a soft-linked module stub so the
//     file builds standalone. The real csrf module is unchanged on disk.
//
// Tests cover the analytics-counter shape (saturating increment) and the
// stub-defaults table so the constants survive re-attachment.

//! `Bun.CSRF.generate` / `Bun.CSRF.verify` host fns. The pure
//! `generate()`/`verify()` halves stay in `src/csrf/`.

/// JS binding function for generating CSRF tokens.
/// First argument is secret (required), second is options (optional).
///
/// Body parked: every JSC accessor below goes through a stub. The shape of
/// the argument-validation branches is preserved so re-attachment in Phase
/// 12.2 is a mechanical drop of the real `jsc.*` symbols.
pub fn csrf__generate(globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) JSError!jsc.JSValue {
    bun.analytics.Features.bumpSaturating(&bun.analytics.Features.csrf_generate);

    // We should have at least one argument (secret).
    const args = callframe.arguments();
    var secret: ?jsc.ZigString.Slice = null;
    if (args.len >= 1) {
        const jsSecret = args[0];
        if (jsSecret.isEmptyOrUndefinedOrNull()) {
            return globalObject.throwInvalidArguments("Secret is required", .{});
        }
        if (!jsSecret.isString() or (try jsSecret.getLength(globalObject)) == 0) {
            return globalObject.throwInvalidArguments("Secret must be a non-empty string", .{});
        }
        secret = try jsSecret.toSlice(globalObject, bun.default_allocator);
    }
    defer if (secret) |s| s.deinit();

    // Defaults pulled from `csrf.DEFAULT_EXPIRATION_MS` /
    // `csrf.DEFAULT_ALGORITHM` so the re-attachment swap stays a string
    // substitution.
    var expires_in: u64 = csrf.DEFAULT_EXPIRATION_MS;
    var encoding: csrf.TokenFormat = .base64url;
    var algorithm: jsc.API.Bun.Crypto.EVP.Algorithm = csrf.DEFAULT_ALGORITHM;

    if (args.len > 1 and args[1].isObject()) {
        const options_value = args[1];
        if (try options_value.getOptionalInt(globalObject, "expiresIn", u64)) |v| expires_in = v;

        if (try options_value.get(globalObject, "encoding")) |encoding_js| {
            const encoding_enum = try jsc.Node.Encoding.fromJSWithDefaultOnEmpty(encoding_js, globalObject, .base64url) orelse {
                return globalObject.throwInvalidArguments("Invalid format: must be 'base64', 'base64url', or 'hex'", .{});
            };
            encoding = switch (encoding_enum) {
                .base64 => .base64,
                .base64url => .base64url,
                .hex => .hex,
                else => return globalObject.throwInvalidArguments("Invalid format: must be 'base64', 'base64url', or 'hex'", .{}),
            };
        }

        if (try options_value.get(globalObject, "algorithm")) |algorithm_js| {
            if (!algorithm_js.isString()) {
                return globalObject.throwInvalidArgumentTypeValue("algorithm", "string", algorithm_js);
            }
            algorithm = try jsc.API.Bun.Crypto.EVP.Algorithm.map.fromJSCaseInsensitive(globalObject, algorithm_js) orelse {
                return globalObject.throwInvalidArguments("Algorithm not supported", .{});
            };
            switch (algorithm) {
                .blake2b256, .blake2b512, .sha256, .sha384, .sha512, .@"sha512-256" => {},
                else => return globalObject.throwInvalidArguments("Algorithm not supported", .{}),
            }
        }
    }

    var token_buffer: [512]u8 = @splat(0);
    const token_bytes = csrf.generate(.{
        .secret = if (secret) |s| s.slice() else globalObject.bunVM().rareData().defaultCSRFSecret(),
        .expires_in_ms = expires_in,
        .encoding = encoding,
        .algorithm = algorithm,
    }, &token_buffer) catch |err| switch (err) {
        // Upstream had a second branch `else => return globalObject.throwError(err, ...)`.
        // The stub `csrf.Error` set currently has only `TokenCreationFailed`,
        // so the `else` would be unreachable. Reinstate the branch when the
        // real csrf module grows additional variants:
        //   else => return globalObject.throwError(err, "Failed to generate CSRF token"),
        csrf.Error.TokenCreationFailed => return globalObject.throw("Failed to create CSRF token", .{}),
    };

    return encoding.toNodeEncoding().encodeWithMaxSize(globalObject, EVP_MAX_MD_SIZE + 32, token_bytes);
}

/// JS binding function for verifying CSRF tokens.
/// First argument is token (required), second is options (optional).
pub fn csrf__verify(globalObject: *jsc.JSGlobalObject, call_frame: *jsc.CallFrame) JSError!jsc.JSValue {
    bun.analytics.Features.bumpSaturating(&bun.analytics.Features.csrf_verify);

    const args = call_frame.arguments();
    if (args.len < 1) {
        return globalObject.throwInvalidArguments("Missing required token parameter", .{});
    }
    const jsToken: jsc.JSValue = args[0];
    if (jsToken.isUndefinedOrNull()) {
        return globalObject.throwInvalidArguments("Token is required", .{});
    }
    if (!jsToken.isString() or (try jsToken.getLength(globalObject)) == 0) {
        return globalObject.throwInvalidArguments("Token must be a non-empty string", .{});
    }
    const token = try jsToken.toSlice(globalObject, bun.default_allocator);
    defer token.deinit();

    var secret: ?jsc.ZigString.Slice = null;
    defer if (secret) |s| s.deinit();
    var max_age: u64 = csrf.DEFAULT_EXPIRATION_MS;
    var encoding: csrf.TokenFormat = .base64url;
    var algorithm: jsc.API.Bun.Crypto.EVP.Algorithm = csrf.DEFAULT_ALGORITHM;

    if (args.len > 1 and args[1].isObject()) {
        const options_value = args[1];

        if (try options_value.getOptional(globalObject, "secret", jsc.ZigString.Slice)) |secretSlice| {
            if (secretSlice.len == 0) {
                return globalObject.throwInvalidArguments("Secret must be a non-empty string", .{});
            }
            secret = secretSlice;
        }

        if (try options_value.getOptionalInt(globalObject, "maxAge", u64)) |v| max_age = v;

        if (try options_value.get(globalObject, "encoding")) |encoding_js| {
            const encoding_enum = try jsc.Node.Encoding.fromJSWithDefaultOnEmpty(encoding_js, globalObject, .base64url) orelse {
                return globalObject.throwInvalidArguments("Invalid format: must be 'base64', 'base64url', or 'hex'", .{});
            };
            encoding = switch (encoding_enum) {
                .base64 => .base64,
                .base64url => .base64url,
                .hex => .hex,
                else => return globalObject.throwInvalidArguments("Invalid format: must be 'base64', 'base64url', or 'hex'", .{}),
            };
        }
        if (try options_value.get(globalObject, "algorithm")) |algorithm_js| {
            if (!algorithm_js.isString()) {
                return globalObject.throwInvalidArgumentTypeValue("algorithm", "string", algorithm_js);
            }
            algorithm = try jsc.API.Bun.Crypto.EVP.Algorithm.map.fromJSCaseInsensitive(globalObject, algorithm_js) orelse {
                return globalObject.throwInvalidArguments("Algorithm not supported", .{});
            };
            switch (algorithm) {
                .blake2b256, .blake2b512, .sha256, .sha384, .sha512, .@"sha512-256" => {},
                else => return globalObject.throwInvalidArguments("Algorithm not supported", .{}),
            }
        }
    }

    const is_valid = csrf.verify(.{
        .token = token.slice(),
        .secret = if (secret) |s| s.slice() else globalObject.bunVM().rareData().defaultCSRFSecret(),
        .max_age_ms = max_age,
        .encoding = encoding,
        .algorithm = algorithm,
    });

    return jsc.JSValue.jsBoolean(is_valid);
}

const std = @import("std");
const home_rt = @import("home");

// BoringSSL's `EVP_MAX_MD_SIZE` is 64 across all currently supported digests
// (SHA-512 + a `+32` salt). Swap for the real symbol when boringssl_sys
// exports it.
const EVP_MAX_MD_SIZE: usize = 64;

// ============================================================================
// Local stubs for the bun.* / bun.jsc.* surfaces
// ============================================================================

const bun = struct {
    pub const default_allocator = home_rt.default_allocator;

    pub const analytics = struct {
        pub const Features = struct {
            pub var csrf_generate: usize = 0;
            pub var csrf_verify: usize = 0;

            /// Saturating-increment helper — mirrors the upstream
            /// `if (counter < maxInt) counter += 1` guard.
            pub fn bumpSaturating(counter: *usize) void {
                if (counter.* < std.math.maxInt(usize)) counter.* += 1;
            }
        };
    };
};

pub const JSError = error{JSError};

const jsc = struct {
    pub const JSGlobalObject = opaque {
        // All accessors return the zero-value placeholder so the file builds
        // standalone. None of these are reachable from the in-file tests.
        pub fn throwInvalidArguments(_: *JSGlobalObject, _: []const u8, _: anytype) JSError!JSValue {
            return error.JSError;
        }
        pub fn throwInvalidArgumentTypeValue(_: *JSGlobalObject, _: []const u8, _: []const u8, _: JSValue) JSError!JSValue {
            return error.JSError;
        }
        pub fn throw(_: *JSGlobalObject, _: []const u8, _: anytype) JSError!JSValue {
            return error.JSError;
        }
        pub fn throwError(_: *JSGlobalObject, _: anyerror, _: []const u8) JSError!JSValue {
            return error.JSError;
        }
        pub fn bunVM(_: *JSGlobalObject) *VirtualMachine {
            return &dummy_vm;
        }
    };

    pub const CallFrame = opaque {
        pub fn arguments(_: *CallFrame) []const JSValue {
            return &.{};
        }
    };

    pub const JSValue = enum(i64) {
        zero = 0,
        js_undefined = 0xa,
        _,

        pub fn isEmptyOrUndefinedOrNull(_: JSValue) bool {
            return true;
        }
        pub fn isUndefinedOrNull(_: JSValue) bool {
            return true;
        }
        pub fn isString(_: JSValue) bool {
            return false;
        }
        pub fn isObject(_: JSValue) bool {
            return false;
        }
        pub fn getLength(_: JSValue, _: *JSGlobalObject) JSError!u32 {
            return 0;
        }
        pub fn toSlice(_: JSValue, _: *JSGlobalObject, _: std.mem.Allocator) JSError!ZigString.Slice {
            return .{};
        }
        pub fn getOptionalInt(_: JSValue, _: *JSGlobalObject, _: []const u8, comptime _: type) JSError!?u64 {
            return null;
        }
        pub fn get(_: JSValue, _: *JSGlobalObject, _: []const u8) JSError!?JSValue {
            return null;
        }
        pub fn getOptional(_: JSValue, _: *JSGlobalObject, _: []const u8, comptime _: type) JSError!?ZigString.Slice {
            return null;
        }
        pub fn jsBoolean(_: bool) JSValue {
            return .zero;
        }
    };

    pub const ZigString = struct {
        pub const Slice = struct {
            len: usize = 0,
            pub fn slice(_: Slice) []const u8 {
                return "";
            }
            pub fn deinit(_: Slice) void {}
        };
    };

    pub const Node = struct {
        pub const Encoding = enum(u8) {
            base64,
            base64url,
            hex,
            other,

            pub fn fromJSWithDefaultOnEmpty(_: JSValue, _: *JSGlobalObject, default: Encoding) JSError!?Encoding {
                return default;
            }
        };
    };

    pub const API = struct {
        pub const Bun = struct {
            pub const Crypto = struct {
                pub const EVP = struct {
                    pub const Algorithm = enum {
                        blake2b256,
                        blake2b512,
                        sha256,
                        sha384,
                        sha512,
                        @"sha512-256",
                        unknown,

                        pub const map = struct {
                            pub fn fromJSCaseInsensitive(_: *JSGlobalObject, _: JSValue) JSError!?Algorithm {
                                return null;
                            }
                        };
                    };
                };
            };
        };
    };

    const VirtualMachine = struct {
        rare: RareData = .{},

        pub fn rareData(self: *VirtualMachine) *RareData {
            return &self.rare;
        }
    };
    const RareData = struct {
        pub fn defaultCSRFSecret(_: *RareData) []const u8 {
            return "";
        }
    };
    var dummy_vm: VirtualMachine = .{};
};

// `src/csrf/csrf.zig` substitute. The real module is wired up by the
// re-attachment TU; here we only need a build-clean shape and the same
// default constants/enums.
const csrf = struct {
    pub const DEFAULT_EXPIRATION_MS: u64 = 60 * 60 * 1000;
    pub const DEFAULT_ALGORITHM: jsc.API.Bun.Crypto.EVP.Algorithm = .sha256;

    pub const TokenFormat = enum {
        base64,
        base64url,
        hex,

        pub fn toNodeEncoding(self: TokenFormat) NodeEncoding {
            return switch (self) {
                .base64 => .{ .tag = .base64 },
                .base64url => .{ .tag = .base64url },
                .hex => .{ .tag = .hex },
            };
        }
    };

    pub const NodeEncoding = struct {
        tag: enum { base64, base64url, hex },

        pub fn encodeWithMaxSize(_: NodeEncoding, _: *jsc.JSGlobalObject, _: usize, _: []const u8) jsc.JSValue {
            return .zero;
        }
    };

    pub const Error = error{TokenCreationFailed};

    pub const GenerateInput = struct {
        secret: []const u8,
        expires_in_ms: u64,
        encoding: TokenFormat,
        algorithm: jsc.API.Bun.Crypto.EVP.Algorithm,
    };

    pub const VerifyInput = struct {
        token: []const u8,
        secret: []const u8,
        max_age_ms: u64,
        encoding: TokenFormat,
        algorithm: jsc.API.Bun.Crypto.EVP.Algorithm,
    };

    pub fn generate(_: GenerateInput, buf: *[512]u8) Error![]const u8 {
        return buf[0..0];
    }

    pub fn verify(_: VerifyInput) bool {
        return false;
    }
};

comptime {
    _ = &home_rt.upstream_sha;
    // Force the host-fn entry points into the link graph even though the
    // in-file tests don't call them, so a tooling pass can see the JS-bridge
    // skeleton.
    _ = &csrf__generate;
    _ = &csrf__verify;
}

// ============================================================================
// Tests
// ============================================================================

test "csrf.DEFAULT_EXPIRATION_MS is one hour in milliseconds" {
    try std.testing.expectEqual(@as(u64, 60 * 60 * 1000), csrf.DEFAULT_EXPIRATION_MS);
}

test "csrf.TokenFormat round-trips through toNodeEncoding" {
    try std.testing.expectEqual(csrf.NodeEncoding{ .tag = .base64 }, csrf.TokenFormat.base64.toNodeEncoding());
    try std.testing.expectEqual(csrf.NodeEncoding{ .tag = .base64url }, csrf.TokenFormat.base64url.toNodeEncoding());
    try std.testing.expectEqual(csrf.NodeEncoding{ .tag = .hex }, csrf.TokenFormat.hex.toNodeEncoding());
}

test "Features.bumpSaturating stops at maxInt(usize)" {
    var n: usize = std.math.maxInt(usize) - 1;
    bun.analytics.Features.bumpSaturating(&n);
    try std.testing.expectEqual(std.math.maxInt(usize), n);
    // Saturating: a second bump leaves the counter pinned.
    bun.analytics.Features.bumpSaturating(&n);
    try std.testing.expectEqual(std.math.maxInt(usize), n);
}

test "EVP_MAX_MD_SIZE matches BoringSSL's compile-time cap" {
    try std.testing.expectEqual(@as(usize, 64), EVP_MAX_MD_SIZE);
}

test "csrf.DEFAULT_ALGORITHM is sha256" {
    try std.testing.expectEqual(jsc.API.Bun.Crypto.EVP.Algorithm.sha256, csrf.DEFAULT_ALGORITHM);
}
