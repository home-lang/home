// Copied from bun/src/event_loop/AutoFlusher.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt"). The JSC
// `VirtualMachine` type is a local opaque stub — re-attaches to the real
// JSC bridge in Phase 12.2. The body of the helpers is kept verbatim;
// callers reach `vm.eventLoop().deferred_tasks.{post,unregister}Task`
// through duck-typed comptime dispatch, so the stub need not declare
// `eventLoop()` itself.

registered: bool = false,

pub fn registerDeferredMicrotaskWithType(comptime Type: type, this: *Type, vm: *VirtualMachine) void {
    if (this.auto_flusher.registered) return;
    registerDeferredMicrotaskWithTypeUnchecked(Type, this, vm);
}

pub fn unregisterDeferredMicrotaskWithType(comptime Type: type, this: *Type, vm: *VirtualMachine) void {
    if (!this.auto_flusher.registered) return;
    unregisterDeferredMicrotaskWithTypeUnchecked(Type, this, vm);
}

pub fn unregisterDeferredMicrotaskWithTypeUnchecked(comptime Type: type, this: *Type, vm: *VirtualMachine) void {
    home_rt.assert(this.auto_flusher.registered);
    home_rt.assert(vm.eventLoop().deferred_tasks.unregisterTask(this));
    this.auto_flusher.registered = false;
}

pub fn registerDeferredMicrotaskWithTypeUnchecked(comptime Type: type, this: *Type, vm: *VirtualMachine) void {
    home_rt.assert(!this.auto_flusher.registered);
    this.auto_flusher.registered = true;
    home_rt.assert(!vm.eventLoop().deferred_tasks.postTask(this, @ptrCast(&Type.onAutoFlush)));
}

// ---- Local stubs ------------------------------------------------------
// JSC bridge VirtualMachine stubbed — re-attaches in Phase 12.2.
pub const VirtualMachine = home_rt.jsc.VirtualMachine;

const home_rt = @import("home_rt");
const std = @import("std");

// ---- Inline tests -----------------------------------------------------
// We can only sanity-check the storage layout here; the real round-trip
// through `vm.eventLoop().deferred_tasks` lands once the JSC bridge does.

const AutoFlusher = @This();
const testing = std.testing;

test "AutoFlusher: default-initialises with registered = false" {
    const af: AutoFlusher = .{};
    try testing.expectEqual(false, af.registered);
}

test "AutoFlusher: registered flag is mutable" {
    var af: AutoFlusher = .{};
    af.registered = true;
    try testing.expectEqual(true, af.registered);
}
