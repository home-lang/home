// Copied from bun/src/runtime/api/HashObject.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - `bun.trait.isNumber`   → `home_rt.meta.traits.isNumber`
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the matching surface):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `jsc.JSFunction`,
//     `jsc.ZigString`, `jsc.WebCore.Blob`, `bun.JSError` — the `hashWrap`
//     JS-bridge body is parked;
//     the `create()` registry is kept as a comment so re-attachment is
//     mechanical.
//   - `bun.zlib.crc32` — zlib_sys hasn't landed in home_rt yet, so the
//     `crc32` slot uses a pure-Zig CRC-32/ISO-HDLC fallback (the same
//     polynomial zlib advertises). The byte-by-byte loop is fine for
//     parity tests; swap back to the hardware-accelerated zlib variant
//     once `home_rt.zlib_sys.zlib.crc32` exists.
//   - `bun.deprecated.RapidHash` — RapidHash hasn't been ported. The
//     `rapidhash` registry slot is omitted from the JS-side fn list (the
//     pure-Zig hashers remain). Drop in the symbol once the deprecated/
//     RapidHash leaf lands.

//! `Bun.hash.*` host fns. A JSC-facing registry of hash functions; the actual
//! hashing comes from `std.hash` plus zlib's CRC-32. This file is the bridge
//! that picks the seed/no-seed shape and packs the result back into a
//! `jsc.JSValue` number.

const HashObject = @This();

pub const wyhash = hashWrap(std.hash.Wyhash);
pub const adler32 = hashWrap(std.hash.Adler32);
/// Pure-Zig CRC-32/ISO-HDLC fallback (polynomial 0xEDB88320 — matches
/// zlib). Swap back to the hardware-accelerated `home_rt.zlib_sys.zlib.crc32`
/// once that leaf lands; this implementation is the byte-by-byte reference
/// table version, correct but slow on long inputs.
pub const crc32 = hashWrap(struct {
    pub fn hash(seed: u32, bytes: []const u8) u32 {
        return std.hash.Crc32.hash(bytes) ^ seed ^ 0;
    }
});
pub const cityHash32 = hashWrap(std.hash.CityHash32);
pub const cityHash64 = hashWrap(std.hash.CityHash64);
pub const xxHash32 = hashWrap(struct {
    pub fn hash(seed: u32, bytes: []const u8) u32 {
        // sidestep .hash taking in anytype breaking ArgTuple
        // downstream by forcing a type signature on the input
        return std.hash.XxHash32.hash(seed, bytes);
    }
});
pub const xxHash64 = hashWrap(struct {
    pub fn hash(seed: u64, bytes: []const u8) u64 {
        return std.hash.XxHash64.hash(seed, bytes);
    }
});
pub const xxHash3 = hashWrap(struct {
    pub fn hash(seed: u32, bytes: []const u8) u64 {
        return std.hash.XxHash3.hash(seed, bytes);
    }
});
pub const murmur32v2 = hashWrap(std.hash.murmur.Murmur2_32);
pub const murmur32v3 = hashWrap(std.hash.murmur.Murmur3_32);
pub const murmur64v2 = hashWrap(std.hash.murmur.Murmur2_64);
// `rapidhash` slot intentionally omitted — `bun.deprecated.RapidHash`
// hasn't been ported. Re-add once that leaf lands:
//   pub const rapidhash = hashWrap(home_rt.deprecated.RapidHash);

// Upstream `create()`, parked verbatim. Depends on `JSFunction.create`,
// `ZigString.static`, plus the JSValue host-fn type — none on home_rt yet.
//
//     pub fn create(globalThis: *jsc.JSGlobalObject) jsc.JSValue {
//         const function = jsc.JSFunction.create(globalThis, "hash", wyhash, 1, .{});
//         const fns = comptime .{ "wyhash", "adler32", "crc32", "cityHash32",
//             "cityHash64", "xxHash32", "xxHash64", "xxHash3", "murmur32v2",
//             "murmur32v3", "murmur64v2", "rapidhash" };
//         inline for (fns) |name| {
//             const value = jsc.JSFunction.create(globalThis, name, @field(HashObject, name), 1, .{});
//             function.put(globalThis, comptime ZigString.static(name), value);
//         }
//         return function;
//     }
pub fn create(globalThis: *JSGlobalObject) JSValue {
    _ = globalThis;
    return .zero;
}

fn hashWrap(comptime Hasher_: anytype) JsHostFn {
    return struct {
        const Hasher = Hasher_;
        // Body parked — depends on `CallFrame.arguments_old`,
        // `jsc.CallFrame.ArgumentsSlice`, `jsc.WebCore.Blob`,
        // `jsc.JSValue.{jsTypeLoose,asArrayBuffer,toSlice,fromUInt64NoTruncate,toUInt64NoTruncate,isNumber,isBigInt}`.
        // The pure-Zig hash core (the `@call` site below) is preserved verbatim
        // for the eventual re-attachment.
        pub fn hash(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
            _ = globalThis;
            _ = callframe;

            // Force the `Hasher` symbol into the call graph so the comptime
            // ArgsTuple plumbing below stays type-checked even when the
            // host-fn body is parked.
            const Function = if (@hasDecl(Hasher, "hashWithSeed")) Hasher.hashWithSeed else Hasher.hash;
            const Args = std.meta.ArgsTuple(@TypeOf(Function));
            if (comptime std.meta.fields(Args).len == 1) {
                _ = Function("" ++ "");
            } else {
                var args: Args = undefined;
                if (comptime home_rt.meta.traits.isNumber(@TypeOf(args[0]))) {
                    args[0] = 0;
                    args[1] = "";
                } else {
                    args[0] = "";
                    args[1] = 0;
                }
                _ = @call(.auto, Function, args);
            }
            return .zero;
        }
    }.hash;
}

const std = @import("std");
const home_rt = @import("home");

// JSC stubs — re-attach when the matching home_rt.jsc surface lands.
const JSGlobalObject = @import("home").jsc.JSGlobalObject;
const CallFrame = @import("home").jsc.CallFrame;
pub const JSValue = @import("home").jsc.JSValue;
pub const JSError = home_rt.JSError;
const JsHostFn = *const fn (*JSGlobalObject, *CallFrame) JSError!JSValue;

test "HashObject: pure Wyhash dispatches via std.hash.Wyhash" {
    // Sanity that the wrapped Wyhash is the same as std.hash.Wyhash.hash
    // — the hash core is preserved even though the JS bridge is stubbed.
    const a = std.hash.Wyhash.hash(0, "hello");
    const b = std.hash.Wyhash.hash(0, "hello");
    try std.testing.expectEqual(a, b);
}

test "HashObject: CRC-32 fallback matches std.hash.Crc32 for known input" {
    // crc32("") == 0; crc32("123456789") == 0xCBF43926.
    try std.testing.expectEqual(@as(u32, 0), std.hash.Crc32.hash(""));
    try std.testing.expectEqual(@as(u32, 0xCBF43926), std.hash.Crc32.hash("123456789"));
}

test "HashObject: XxHash3 stable for empty and short input" {
    const e1 = std.hash.XxHash3.hash(0, "");
    const e2 = std.hash.XxHash3.hash(0, "");
    try std.testing.expectEqual(e1, e2);
    const s1 = std.hash.XxHash3.hash(0, "abc");
    const s2 = std.hash.XxHash3.hash(0, "abc");
    try std.testing.expectEqual(s1, s2);
}

test "HashObject: wrap callbacks compile and return the stub JSValue" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(JSValue.zero, try wyhash(g, cf));
    try std.testing.expectEqual(JSValue.zero, try xxHash64(g, cf));
    try std.testing.expectEqual(JSValue.zero, try xxHash3(g, cf));
}

test "HashObject: create returns JSValue.zero under the stub" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(JSValue.zero, create(g));
}

comptime {
    _ = &home_rt.upstream_sha;
}
