// Phase 12.2 M3 — JSC C++ engine bring-up scaffold.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M3 (Real C++ Wrapper Layer), this
// file is the front door for the milestone: it documents the contract the
// next agent must satisfy when wiring JavaScriptCore into Home. M1 named
// the opaque types; M2 declared the C-API extern fn surface; M3 actually
// links the engine and stands up the VM.
//
// Build flag: `-Denable_jsc=true` (default false) gates the linkage in
// `build.zig`. With the flag set, `home_rt_tests` links libc++ +
// `JavaScriptCore.framework` on macOS (system-installed). Without it, the
// extern fns from `jsc/extern_fns.zig` stay unresolved — which is fine
// because no caller exercises them in CI today.
//
// `Engine` is the owner of one JSC realm. Its lifecycle is:
//
//     var engine = try Engine.init(allocator);
//     defer engine.deinit();
//     const ctx = engine.currentContext();
//     const global = engine.currentGlobalObject();
//     // …dispatch C-API calls against `ctx` / `global`…
//
// All methods panic in M3 — the bodies are placeholders the next milestone
// fills in. The struct shape is committed so downstream callers can be
// written against it without waiting on the C++ work.
//
// Bun upstream reference: `~/Code/bun/src/bun.js/javascript.zig` (the
// `VirtualMachine` type) — Home's `Engine` collapses that surface onto
// the minimum needed to validate the binding round-trip.

const std = @import("std");
const opaques = @import("opaques.zig");

const JSContextRef = opaques.JSContextRef;
const JSGlobalObject = opaques.JSGlobalObject;
const VM = opaques.VM;

/// Single-realm owner of a JavaScriptCore VM. Created via `Engine.init`,
/// destroyed via `Engine.deinit`. Methods route to the extern-fn surface
/// declared in `jsc/extern_fns.zig` once `-Denable_jsc=true` is set and a
/// host JSC is available.
pub const Engine = struct {
    /// Backing allocator. M3 uses this for any host-side bookkeeping
    /// (e.g. exception buffers, weak-ref tables); the JSC heap itself is
    /// owned by `*VM`.
    allocator: std.mem.Allocator,

    /// Owning pointer to the JSC `*VM` instance. Populated by `init`,
    /// released by `deinit`. Opaque until M3 lands the C++ bridge.
    vm: ?*VM = null,

    /// Owning pointer to the realm's `*JSContextRef`. One context per
    /// engine for now; multi-context support follows in Phase 12.3.
    context: ?*JSContextRef = null,

    /// Construct a fresh engine + VM + context. Currently panics; M3
    /// fills in the body by calling `JSGlobalContextCreate(null)` and
    /// stashing the returned `*JSContextRef` in `self.context`.
    pub fn init(allocator: std.mem.Allocator) !Engine {
        _ = allocator;
        @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
    }

    /// Tear down the engine and release the underlying VM. Currently
    /// panics; M3 fills in the body by calling `JSGlobalContextRelease`.
    pub fn deinit(self: *Engine) void {
        _ = self;
        @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
    }

    /// Return the current `*JSContextRef`. M3 fills in the body to
    /// return `self.context.?` after asserting init succeeded.
    pub fn currentContext(self: *const Engine) *JSContextRef {
        _ = self;
        @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
    }

    /// Return the global object for the realm. M3 fills in the body by
    /// calling `JSContextGetGlobalObject(self.context)` and casting the
    /// `*JSObject` result down to `*JSGlobalObject`.
    pub fn currentGlobalObject(self: *const Engine) *JSGlobalObject {
        _ = self;
        @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
    }
};

test "Engine type exists and is a struct" {
    // Compile-time-only smoke test. We never call `Engine.init` here —
    // doing so would `@panic` until M3 lands. The point is to assert the
    // shape: `Engine` is a `struct` carrying a nullable VM + context plus
    // the four lifecycle methods. Downstream test ports against this
    // shape land in M4.
    try std.testing.expect(@typeInfo(Engine) == .@"struct");
    try std.testing.expect(@hasDecl(Engine, "init"));
    try std.testing.expect(@hasDecl(Engine, "deinit"));
    try std.testing.expect(@hasDecl(Engine, "currentContext"));
    try std.testing.expect(@hasDecl(Engine, "currentGlobalObject"));
}
