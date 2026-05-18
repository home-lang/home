// Copied from bun/src/runtime/api/crash_handler_jsc.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home_rt")
//   - `bun.Environment.isMac`         → `home_rt.Environment.isMac`
//   - `bun.BoundedArray`              → `home_rt.BoundedArray`
//
// Pending rewrites (home_rt symbols don't exist yet — comments at the call
// site flag the upstream form for the eventual re-attachment):
//   - `bun.Environment.is_canary`, `bun.Environment.git_sha`,
//     `bun.Global.package_json_version`
//   - `bun.crash_handler.*`, `bun.outOfMemory`, `bun.Global.raiseIgnoringPanicHandler`
//   - `bun.analytics.packedFeatures`, `bun.analytics.packed_features_list`
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the matching surface):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `jsc.JSValue`,
//     `jsc.JSFunction.create`, `jsc.ZigString.static`, `bun.JSError`,
//     `bun.String.{static,init,cloneLatin1,transferToJS,toJS}` — opaques + an
//     `enum(i64)` for `JSValue`. The full `js_bindings.generate()` body
//     is parked in a comment; the per-fn host bodies are stubbed but the
//     `crash_handler.{suppressCoreDumpsIfNecessary,panicImpl,writeU64AsTwoVLQs,handleRootError}`
//     and `bun.analytics.packed_features_list` calls stay in comments for
//     mechanical re-attachment.
//
// The macOS `_dyld_get_image_header`/`_dyld_get_image_vmaddr_slide` path is
// preserved verbatim under the `Environment.isMac` gate — it has no JSC
// dependency and is useful for crash-report symbolication wiring.

//! JS testing/debugging bindings for the crash handler. Keeps
//! `src/crash_handler/` free of JSC types.

pub const js_bindings = struct {
    // JSC stubs — re-attach when the matching home_rt.jsc surface lands.
    const JSGlobalObject = opaque {};
    const CallFrame = opaque {};
    pub const JSValue = enum(i64) {
        zero = 0,
        js_undefined = 0xa,
        _,
        pub fn jsNumber(_: anytype) JSValue {
            return .zero;
        }
        pub fn jsNumberFromInt64(_: i64) JSValue {
            return .zero;
        }
        pub fn jsBoolean(_: bool) JSValue {
            return .zero;
        }
    };
    pub const JSError = error{JSError};

    // Upstream `generate()` body, parked. Walks an inline tuple of
    // `(name, fn)` pairs, calling `jsc.JSFunction.create` + `obj.put` for
    // each. Re-attach once home_rt has `JSFunction.create`, `JSValue.createEmptyObject`,
    // `ZigString.static`, and `JSValue.put`.
    //
    //     pub fn generate(global: *jsc.JSGlobalObject) jsc.JSValue {
    //         const obj = jsc.JSValue.createEmptyObject(global, 8);
    //         inline for (.{
    //             .{ "getMachOImageZeroOffset", jsGetMachOImageZeroOffset },
    //             .{ "getFeaturesAsVLQ", jsGetFeaturesAsVLQ },
    //             .{ "getFeatureData", jsGetFeatureData },
    //             .{ "segfault", jsSegfault },
    //             .{ "panic", jsPanic },
    //             .{ "rootError", jsRootError },
    //             .{ "outOfMemory", jsOutOfMemory },
    //             .{ "raiseIgnoringPanicHandler", jsRaiseIgnoringPanicHandler },
    //         }) |tuple| {
    //             const name = jsc.ZigString.static(tuple[0]);
    //             obj.put(global, name, jsc.JSFunction.create(global, tuple[0], tuple[1], 1, .{}));
    //         }
    //         return obj;
    //     }
    pub fn generate(global: *JSGlobalObject) JSValue {
        _ = global;
        return .zero;
    }

    /// macOS-only: dyld base address minus the image vmaddr slide. Useful
    /// for crash symbolication. No JSC dep, kept live.
    pub fn jsGetMachOImageZeroOffset(_: *JSGlobalObject, _: *CallFrame) JSError!JSValue {
        if (!home_rt.Environment.isMac) return .js_undefined;

        const header = std.c._dyld_get_image_header(0) orelse return .js_undefined;
        const base_address = @intFromPtr(header);
        const vmaddr_slide = std.c._dyld_get_image_vmaddr_slide(0);

        return JSValue.jsNumber(base_address - vmaddr_slide);
    }

    // Upstream body parked — depends on `crash_handler.suppressCoreDumpsIfNecessary`
    // and a hot deliberate-crash payload. Re-attach once the crash_handler
    // re-lands.
    pub fn jsSegfault(_: *JSGlobalObject, _: *CallFrame) JSError!JSValue {
        return .js_undefined;
    }

    // Upstream body parked — calls `bun.crash_handler.panicImpl("invoked
    // crashByPanic() handler", null, null)`. Stays as a noreturn stub so the
    // signature matches.
    pub fn jsPanic(_: *JSGlobalObject, _: *CallFrame) JSError!JSValue {
        return .js_undefined;
    }

    // Upstream body parked — calls `bun.crash_handler.handleRootError(error.Test, null)`.
    pub fn jsRootError(_: *JSGlobalObject, _: *CallFrame) JSError!JSValue {
        return .js_undefined;
    }

    // Upstream body parked — calls `bun.outOfMemory()` after suppressing
    // core dumps. Both helpers depend on the full crash_handler port.
    pub fn jsOutOfMemory(_: *JSGlobalObject, _: *CallFrame) JSError!JSValue {
        return .js_undefined;
    }

    // Upstream body parked — calls `bun.Global.raiseIgnoringPanicHandler(.SIGSEGV)`.
    pub fn jsRaiseIgnoringPanicHandler(_: *JSGlobalObject, _: *CallFrame) JSError!JSValue {
        return .js_undefined;
    }

    // Upstream body parked — packs `bun.analytics.packedFeatures()` into a
    // pair of base-32 VLQs via `crash_handler.writeU64AsTwoVLQs` and ships
    // it as a transferToJS'd Latin-1 string.
    pub fn jsGetFeaturesAsVLQ(global: *JSGlobalObject, _: *CallFrame) JSError!JSValue {
        _ = global;
        // The buffer/writer scaffolding is still type-checked so the
        // re-attachment is a one-line swap of the call target.
        var buf: home_rt.BoundedArray(u8, 16) = .{};
        // Touch buf so the symbol stays live.
        buf.len = 0;
        return .zero;
    }

    // Upstream body parked. Composes:
    //   { features: [...], version, is_canary, revision, generated_at }
    // — pulls from `bun.analytics.packed_features_list`, `Global.package_json_version`,
    // `Environment.{is_canary,git_sha}`, and `std.time.milliTimestamp`.
    pub fn jsGetFeatureData(global: *JSGlobalObject, _: *CallFrame) JSError!JSValue {
        _ = global;
        // Touch `Environment.isMac` so the home_rt env surface stays
        // statically referenced; the rest of the env fields (`is_canary`,
        // `git_sha`, `Global.package_json_version`) re-attach with the
        // body in Phase 12.2.
        _ = home_rt.Environment.isMac;
        // Zig 0.17 removed `std.time.milliTimestamp`; the upstream body uses
        // it to populate `.generated_at`. Re-pick the replacement when the
        // matching home_rt clock helper lands.
        return .zero;
    }
};

const std = @import("std");
const home_rt = @import("home_rt");

test "crash_handler_jsc: generate returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *js_bindings.JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(js_bindings.JSValue.zero, js_bindings.generate(g));
}

test "crash_handler_jsc: jsGetMachOImageZeroOffset is js_undefined off-mac" {
    if (home_rt.Environment.isMac) return error.SkipZigTest;
    var dummy: u8 = 0;
    var cf_dummy: u8 = 0;
    const g: *js_bindings.JSGlobalObject = @ptrCast(&dummy);
    const cf: *js_bindings.CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(
        js_bindings.JSValue.js_undefined,
        try js_bindings.jsGetMachOImageZeroOffset(g, cf),
    );
}

test "crash_handler_jsc: JSValue tag is ABI-compatible with i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(js_bindings.JSValue));
}

test "crash_handler_jsc: feature-data scaffolding references its env deps" {
    var dummy: u8 = 0;
    const g: *js_bindings.JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *js_bindings.CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(js_bindings.JSValue.zero, try js_bindings.jsGetFeatureData(g, cf));
}

comptime {
    _ = &home_rt.upstream_sha;
}
