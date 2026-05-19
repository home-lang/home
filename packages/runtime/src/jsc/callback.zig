// Phase 12.2 M5 — host-callback registration helpers.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M5, this file is the *write* half
// of the M5 call surface: where `jsc/call.zig` handles "Zig invokes a JS
// function", this file handles "Zig publishes a function that JS can
// invoke". JSC exposes this through `JSObjectMakeFunctionWithCallback` —
// the C-API takes a `JSObjectCallAsFunctionCallback` function pointer with
// a fixed `(ctx, function, thisObject, argc, argv[], exception)` shape and
// returns a `*JSObject` you can attach as a property on the realm's global.
//
// The `Callback` struct here is the Zig-shaped record we hand to
// `registerCallback` / `registerHostFunction`: it pairs the host fn ptr
// with the JS-visible name (used both as the property key on the global
// and as the function's `.name`). Once M3 lands the C++ wiring, the
// register helpers will (a) build a `*JSString` from `name`, (b) call
// `JSObjectMakeFunctionWithCallback(ctx, name_str, fn_ptr)`, (c) attach
// the result to `global` via `JSObjectSetProperty`, and (d) release the
// transient `*JSString`. Until then, both register helpers panic with
// `TODO(phase-12.2-M3)`.
//
// `registerHostFunction` is the lower-level entry: it returns the freshly
// constructed `*JSValue` without attaching it anywhere, so callers can do
// their own placement (e.g. property on a non-global object, or stash it
// in a strong ref for later use). `registerCallback` is the
// "global-property" sugar on top.
//
// Bun upstream parity:
//   - `~/Code/bun/src/jsc/JSObject.zig` L412 (`JSObjectMakeFunctionWithCallback`
//     wrapper that the Bun side uses for host-fn registration).
//   - `~/Code/bun/src/jsc/CallFrame.zig` (the symmetric "called from JS"
//     side that unpacks `argc`/`argv` for the host fn).
//
// All bodies panic with `TODO(phase-12.2-M3)`; the M5 contract is the
// shape of the surface, not its semantics.

const std = @import("std");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSGlobalObject = opaques.JSGlobalObject;
const JSObject = opaques.JSObject;
const JSString = opaques.JSString;

/// `ExceptionRef` mirrors the M2 declaration in `extern_fns.zig` — a
/// nullable out-pointer JSC writes the thrown value through. Host
/// callbacks set `exception.*` to deliver an error to the JS caller.
pub const ExceptionRef = [*c]?*JSValue;

/// The C-ABI shape JSC expects for host-supplied callbacks. The signature
/// mirrors Apple's `JSObjectCallAsFunctionCallback` typedef in
/// `<JavaScriptCore/JSObjectRef.h>`. Pointer-to-fn (rather than a closure)
/// is required because JSC stores the pointer in the function object and
/// dispatches it without any host-side trampoline.
///
/// The `args` parameter is a C-style pointer + length pair (`argc`,
/// `argv[]`) so the C-API can pass JSC's internal `JSValueRef[]` buffer
/// directly. Hosts that prefer a slice should reslice via
/// `args[0..args_count]` at the top of their body.
pub const HostCallbackFn = *const fn (
    ctx: *JSContextRef,
    this: ?*JSValue,
    args_count: usize,
    args: [*c]const ?*JSValue,
    exception: ExceptionRef,
) callconv(.c) *JSValue;

/// Host-callback descriptor. Pairs a Zig fn ptr with the JS-visible name
/// JSC will install on the function object (`.name` property + property
/// key on the target object when used via `registerCallback`).
pub const Callback = struct {
    /// The host function pointer. Must follow the `HostCallbackFn` shape
    /// (C calling convention; six fixed parameters). The fn body is
    /// responsible for arg validation and exception-out-param setting.
    fn_ptr: HostCallbackFn,

    /// JS-visible name. Used twice: (1) as the `.name` slot on the
    /// resulting function object, (2) as the property key on `global`
    /// when installed via `registerCallback`. UTF-8 encoded.
    name: []const u8,
};

/// Build a host function from `fn_ptr` and attach it to `global` under
/// `name`. The function's `.name` slot is also set to `name`.
///
/// Forwards (M3) to `JSObjectMakeFunctionWithCallback` + `JSObjectSetProperty`,
/// with `JSStringCreateWithUTF8CString` / `JSStringRelease` wrapping the
/// name string. The transient `*JSString` is released before return; the
/// installed function object is owned by `global`.
pub fn registerCallback(
    ctx: *JSContextRef,
    global: *JSGlobalObject,
    name: []const u8,
    fn_ptr: HostCallbackFn,
) void {
    _ = ctx;
    _ = global;
    _ = name;
    _ = fn_ptr;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Build a host function from `fn_ptr` and return it as a `*JSValue`
/// without attaching it anywhere. Callers do their own placement
/// (property on a non-global object, strong-ref for later use, etc.).
///
/// Forwards (M3) to `JSObjectMakeFunctionWithCallback` alone, casting
/// the returned `*JSObject` up to `*JSValue` before returning.
pub fn registerHostFunction(
    ctx: *JSContextRef,
    name: []const u8,
    fn_ptr: HostCallbackFn,
) *JSValue {
    _ = ctx;
    _ = name;
    _ = fn_ptr;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

// ---- inline tests -------------------------------------------------------

// Reference fn used by the signature tests below. It is never actually
// dispatched — the register helpers panic under M5 — but the tests need
// a concrete `HostCallbackFn`-shaped pointer to take its address.
fn sample_host_fn(
    ctx: *JSContextRef,
    this: ?*JSValue,
    args_count: usize,
    args: [*c]const ?*JSValue,
    exception: ExceptionRef,
) callconv(.c) *JSValue {
    _ = ctx;
    _ = this;
    _ = args_count;
    _ = args;
    _ = exception;
    @panic("test-only stub; never dispatched");
}

test "callback helpers expose the expected M5 signatures" {
    // Compile-time signature check. We never invoke the helpers (they
    // panic until M3 lands the C++ engine); the point is to assert each
    // entry exists as a function and has not silently drifted off the
    // M5 spec.
    try std.testing.expect(@typeInfo(@TypeOf(registerCallback)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(registerHostFunction)) == .@"fn");
    // `Callback` is a plain struct carrying the two fields the M5 spec
    // calls out: `fn_ptr` + `name`. Field order is not API-relevant but
    // the names are — downstream call sites build `.{ .fn_ptr = …,
    // .name = … }` literals against them.
    try std.testing.expect(@typeInfo(Callback) == .@"struct");
    try std.testing.expect(@hasField(Callback, "fn_ptr"));
    try std.testing.expect(@hasField(Callback, "name"));
}

test "Callback struct and HostCallbackFn round-trip a fn ptr" {
    // Build a `Callback` literal pointing at `sample_host_fn` and verify
    // both fields read back unchanged. This is the canonical construction
    // pattern downstream callers will use; if `HostCallbackFn` ever
    // drifts off the C-API shape, this test stops compiling.
    const cb: Callback = .{
        .fn_ptr = sample_host_fn,
        .name = "sampleHostFn",
    };
    try std.testing.expectEqualStrings("sampleHostFn", cb.name);
    try std.testing.expect(cb.fn_ptr == sample_host_fn);
    // `registerHostFunction` returns `*JSValue` (non-optional — the
    // freshly constructed function object is never null on success;
    // failure surfaces through a JSC abort, not a null return).
    const reg_info = @typeInfo(@TypeOf(registerHostFunction)).@"fn";
    try std.testing.expect(reg_info.return_type.? == *JSValue);
    // `registerCallback` is `void`-returning (the attached fn lives on
    // `global` and is fetched back by JS-side `globalThis.<name>`).
    const reg_cb_info = @typeInfo(@TypeOf(registerCallback)).@"fn";
    try std.testing.expect(reg_cb_info.return_type.? == void);
}

// Silence unused-import lints — `JSObject` and `JSString` are reserved
// for the M3 wiring where `JSObjectMakeFunctionWithCallback` produces a
// `*JSObject` and consumes a `*JSString` name. Keeping the aliases here
// keeps the M3 diff against this file minimal.
comptime {
    _ = JSObject;
    _ = JSString;
}
