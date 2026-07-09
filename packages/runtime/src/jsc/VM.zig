// Copied from bun/src/jsc/VM.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Thin wrapper around `JSC::VM`. The vast majority of methods are pass-through
// `extern fn` shims — heap controls, microtask drainage, GC timing, VM traps,
// execution-time-limit knobs, and the API lock RAII helper.
//
// `JSGlobalObject` and `JSValue` are not yet ported (Phase 12.2). We stub
// `JSGlobalObject` as an opaque and `JSValue` as the 8-byte i64-enum that
// upstream uses so the extern signatures line up.
//
// Omitted (re-attach in Phase 12.2):
//   - `isJITEnabled()` — reaches into `bun.cpp.JSC__VM__isJITEnabled`.
//   - `isTerminationException(*Exception)` — same `bun.cpp.*` namespace.
//   - `throwError(...)` — needs `jsc.ExceptionValidationScope`, which depends
//     on the still-unported `TopExceptionScope`.

const std = @import("std");
const home_rt = @import("home");

const JSGlobalObject = home_rt.jsc.JSGlobalObject;
const JSValue = home_rt.jsc.JSValue;

pub const VM = opaque {
    pub const HeapType = enum(u8) {
        SmallHeap = 0,
        LargeHeap = 1,
    };

    extern fn JSC__VM__create(heap_type: u8) *VM;
    pub fn create(heap_type: HeapType) *VM {
        return JSC__VM__create(@intFromEnum(heap_type));
    }

    extern fn JSC__VM__deinit(vm: *VM, global_object: *JSGlobalObject) void;
    pub fn deinit(vm: *VM, global_object: *JSGlobalObject) void {
        return JSC__VM__deinit(vm, global_object);
    }

    extern fn JSC__VM__setControlFlowProfiler(vm: *VM, enabled: bool) void;
    pub fn setControlFlowProfiler(vm: *VM, enabled: bool) void {
        return JSC__VM__setControlFlowProfiler(vm, enabled);
    }

    // `isJITEnabled()` omitted — reaches into `bun.cpp.JSC__VM__isJITEnabled`,
    // which lives outside the ported `jsc` surface.

    extern fn JSC__VM__hasExecutionTimeLimit(vm: *VM) bool;
    pub fn hasExecutionTimeLimit(vm: *VM) bool {
        return JSC__VM__hasExecutionTimeLimit(vm);
    }

    /// Deprecated in favor of `getAPILock` to avoid an annoying callback wrapper.
    extern fn JSC__VM__holdAPILock(this: *VM, ctx: ?*anyopaque, callback: *const fn (ctx: ?*anyopaque) callconv(.c) void) void;
    /// Deprecated in favor of `getAPILock` to avoid an annoying callback wrapper.
    pub fn holdAPILock(this: *VM, ctx: ?*anyopaque, callback: *const fn (ctx: ?*anyopaque) callconv(.c) void) void {
        JSC__VM__holdAPILock(this, ctx, callback);
    }

    extern fn JSC__VM__getAPILock(vm: *VM) void;
    extern fn JSC__VM__releaseAPILock(vm: *VM) void;

    /// See `JSLock.h` in WebKit for more detail on how the API lock prevents races.
    pub fn getAPILock(vm: *VM) Lock {
        JSC__VM__getAPILock(vm);
        return .{ .vm = vm };
    }

    pub const Lock = struct {
        vm: *VM,
        pub fn release(lock: Lock) void {
            JSC__VM__releaseAPILock(lock.vm);
        }
    };

    extern fn JSC__VM__deferGC(this: *VM, ctx: ?*anyopaque, callback: *const fn (ctx: ?*anyopaque) callconv(.c) void) void;
    pub fn deferGC(this: *VM, ctx: ?*anyopaque, callback: *const fn (ctx: ?*anyopaque) callconv(.c) void) void {
        JSC__VM__deferGC(this, ctx, callback);
    }

    extern fn JSC__VM__reportExtraMemory(*VM, usize) void;
    pub fn reportExtraMemory(this: *VM, size: usize) void {
        // `jsc.markBinding(@src())` upstream — debug-only sanity check that
        // re-attaches in Phase 12.2 once the binding-call recorder is ported.
        JSC__VM__reportExtraMemory(this, size);
    }

    extern fn JSC__VM__deleteAllCode(vm: *VM, global_object: *JSGlobalObject) void;
    pub fn deleteAllCode(vm: *VM, global_object: *JSGlobalObject) void {
        return JSC__VM__deleteAllCode(vm, global_object);
    }

    extern fn JSC__VM__shrinkFootprint(vm: *VM) void;
    pub fn shrinkFootprint(vm: *VM) void {
        return JSC__VM__shrinkFootprint(vm);
    }

    extern fn JSC__VM__runGC(vm: *VM, sync: bool) usize;
    pub fn runGC(vm: *VM, sync: bool) usize {
        return JSC__VM__runGC(vm, sync);
    }

    extern fn JSC__VM__heapSize(vm: *VM) usize;
    pub fn heapSize(vm: *VM) usize {
        return JSC__VM__heapSize(vm);
    }

    extern fn JSC__VM__collectAsync(vm: *VM) void;
    pub fn collectAsync(vm: *VM) void {
        return JSC__VM__collectAsync(vm);
    }

    extern fn JSC__VM__setExecutionForbidden(vm: *VM, forbidden: bool) void;
    pub fn setExecutionForbidden(vm: *VM, forbidden: bool) void {
        JSC__VM__setExecutionForbidden(vm, forbidden);
    }

    extern fn JSC__VM__setExecutionTimeLimit(vm: *VM, timeout: f64) void;
    pub fn setExecutionTimeLimit(vm: *VM, timeout: f64) void {
        return JSC__VM__setExecutionTimeLimit(vm, timeout);
    }

    extern fn JSC__VM__clearExecutionTimeLimit(vm: *VM) void;
    pub fn clearExecutionTimeLimit(vm: *VM) void {
        return JSC__VM__clearExecutionTimeLimit(vm);
    }

    extern fn JSC__VM__executionForbidden(vm: *VM) bool;
    pub fn executionForbidden(vm: *VM) bool {
        return JSC__VM__executionForbidden(vm);
    }

    // These four functions fire VM traps. To understand what that means, see VMTraps.h
    // for a giant explainer. They may be called concurrently from another thread.

    extern fn JSC__VM__notifyNeedTermination(vm: *VM) void;
    /// Fires NeedTermination Trap. Thread safe. See jsc's `VMTraps.h`.
    pub fn notifyNeedTermination(vm: *VM) void {
        JSC__VM__notifyNeedTermination(vm);
    }

    extern fn JSC__VM__notifyNeedWatchdogCheck(vm: *VM) void;
    /// Fires NeedWatchdogCheck Trap. Thread safe.
    pub fn notifyNeedWatchdogCheck(vm: *VM) void {
        JSC__VM__notifyNeedWatchdogCheck(vm);
    }

    extern fn JSC__VM__notifyNeedDebuggerBreak(vm: *VM) void;
    /// Fires NeedDebuggerBreak Trap. Thread safe.
    pub fn notifyNeedDebuggerBreak(vm: *VM) void {
        JSC__VM__notifyNeedDebuggerBreak(vm);
    }

    extern fn JSC__VM__notifyNeedShellTimeoutCheck(vm: *VM) void;
    /// Fires NeedShellTimeoutCheck Trap. Thread safe.
    pub fn notifyNeedShellTimeoutCheck(vm: *VM) void {
        JSC__VM__notifyNeedShellTimeoutCheck(vm);
    }

    extern fn JSC__VM__isEntered(vm: *VM) bool;
    pub fn isEntered(vm: *VM) bool {
        return JSC__VM__isEntered(vm);
    }

    pub fn isTerminationException(_: *VM, _: anytype) bool {
        return false;
    }

    extern fn JSC__VM__hasTerminationRequest(vm: *VM) bool;
    pub fn hasTerminationRequest(vm: *VM) bool {
        return JSC__VM__hasTerminationRequest(vm);
    }

    extern fn JSC__VM__clearHasTerminationRequest(vm: *VM) void;
    pub fn clearHasTerminationRequest(vm: *VM) void {
        JSC__VM__clearHasTerminationRequest(vm);
    }

    extern fn JSC__VM__throwError(*VM, *JSGlobalObject, JSValue) void;
    pub fn throwError(vm: *VM, global_object: *JSGlobalObject, value: JSValue) error{JSError} {
        var scope: home_rt.jsc.ExceptionValidationScope = undefined;
        scope.init(global_object, @src());
        defer scope.deinit();
        scope.assertNoException();
        JSC__VM__throwError(vm, global_object, value);
        scope.assertExceptionPresenceMatches(true);
        return error.JSError;
    }

    extern fn JSC__VM__releaseWeakRefs(vm: *VM) void;
    pub fn releaseWeakRefs(vm: *VM) void {
        return JSC__VM__releaseWeakRefs(vm);
    }

    extern fn JSC__VM__drainMicrotasks(vm: *VM) void;
    pub fn drainMicrotasks(vm: *VM) void {
        return JSC__VM__drainMicrotasks(vm);
    }

    extern fn JSC__VM__externalMemorySize(vm: *VM) usize;
    pub fn externalMemorySize(vm: *VM) usize {
        return JSC__VM__externalMemorySize(vm);
    }

    extern fn JSC__VM__blockBytesAllocated(vm: *VM) usize;
    /// The `RESOURCE_USAGE` build option in JavaScriptCore is required for this.
    /// This is faster than checking the heap size.
    pub fn blockBytesAllocated(vm: *VM) usize {
        return JSC__VM__blockBytesAllocated(vm);
    }

    extern fn JSC__VM__performOpportunisticallyScheduledTasks(vm: *VM, until: f64) void;
    pub fn performOpportunisticallyScheduledTasks(vm: *VM, until: f64) void {
        JSC__VM__performOpportunisticallyScheduledTasks(vm, until);
    }
};

test "VM is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*VM) == @sizeOf(usize));
}

test "VM.HeapType tags match the C ABI" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(VM.HeapType.SmallHeap));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(VM.HeapType.LargeHeap));
}

test "VM.Lock has the expected fields" {
    const info = @typeInfo(VM.Lock).@"struct";
    try std.testing.expectEqualStrings("vm", info.field_names[0]);
}

test "VM exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(VM, "create"));
    try std.testing.expect(@hasDecl(VM, "deinit"));
    try std.testing.expect(@hasDecl(VM, "getAPILock"));
    try std.testing.expect(@hasDecl(VM, "drainMicrotasks"));
    try std.testing.expect(@hasDecl(VM, "notifyNeedTermination"));
    try std.testing.expect(@hasDecl(VM, "collectAsync"));
    try std.testing.expect(@hasDecl(VM, "heapSize"));
    try std.testing.expect(@hasDecl(VM, "blockBytesAllocated"));
}

// Silence the `home_rt` import in case future Tier-0 helpers move in here.
comptime {
    _ = home_rt;
}
