// Copied from bun/src/jsc/AbortSignal.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// WebCore `AbortSignal` glue. Most of this is just an opaque pointer + extern
// `WebCore__AbortSignal__*` declarations; we keep the full surface so callers
// (fetch, streams, FormData) can still spell every method.
//
// Omitted until the JSC bridge re-attaches in Phase 12.2:
//   - The whole `Timeout` substruct — it depends on `bun.timespec`,
//     `jsc.API.Timer`, `bun.TrivialNew`, `bun.destroy`, and `jsc.VirtualMachine`.
//   - `signal(global, reason)` — calls `bun.analytics.Features.abort_signal += 1`
//     and uses CommonAbortReason. Kept as a passthrough extern wrapper, but no
//     analytics increment (re-add once `home_rt.analytics` is wired).
//   - `reasonIfAborted` — relies on JSValue's `.isUndefined()` and `.zero`
//     comparison, which the JSValue enum exposes — but it also references
//     `bun.debugAssert`; we substitute `std.debug.assert` on debug builds.
//   - `AbortReason.toBodyValueError` — needs `jsc.WebCore.Body.Value.ValueError`,
//     which is not yet ported.
//
// `JSGlobalObject` and `JSValue` are stubbed locally; the real types
// re-attach in Phase 12.2.

const std = @import("std");
const CommonAbortReason = @import("./CommonAbortReason.zig").CommonAbortReason;

const bun = @import("bun");
const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;

// `bun.cast(*T, ptr)` is equivalent to `@ptrCast(@alignCast(ptr))`.
fn castPtr(comptime T: type, p: *anyopaque) T {
    return @ptrCast(@alignCast(p));
}

pub const AbortSignal = opaque {
    pub const Timeout = struct {
        event_loop_timer: jsc.API.Timer.EventLoopTimer,

        // The `Timeout`'s lifetime is owned by the AbortSignal.
        // But this does have a ref count increment.
        signal: *AbortSignal,

        /// "epoch" is reused.
        flags: jsc.API.Timer.TimerObjectInternals.Flags = .{},

        /// See `swapGlobalForTestIsolation`: timers from a prior isolated test
        /// file must not fire abort handlers in the new global.
        generation: u32 = 0,

        const new = bun.TrivialNew(Timeout);

        fn init(vm: *jsc.VirtualMachine, signal_: *AbortSignal, milliseconds: u64) *Timeout {
            const this: *Timeout = .new(.{
                .signal = signal_,
                .generation = vm.test_isolation_generation,
                .event_loop_timer = .{
                    .next = bun.timespec.now(.allow_mocked_time).addMs(@intCast(milliseconds)),
                    .tag = .AbortSignalTimeout,
                    .state = .CANCELLED,
                },
            });

            if (comptime bun.Environment.ci_assert) {
                if (signal_.aborted()) {
                    @panic("unreachable: signal is already aborted");
                }
            }

            // We default to not keeping the event loop alive with this timeout.
            vm.timer.insert(&this.event_loop_timer);

            return this;
        }

        fn cancel(this: *Timeout, vm: *jsc.VirtualMachine) void {
            if (this.event_loop_timer.state == .ACTIVE) {
                vm.timer.remove(&this.event_loop_timer);
            }
        }

        pub fn run(this: *Timeout, vm: *jsc.VirtualMachine) void {
            this.event_loop_timer.state = .FIRED;
            this.cancel(vm);

            // The signal and its handlers belong to a previous isolated test
            // file's global; firing now would run them against the new global.
            // Drop the extra ref that signalAbort() would have released.
            if (this.generation != vm.test_isolation_generation) {
                this.signal.unref();
                return;
            }

            // Dispatching the signal may cause the Timeout to get freed.
            dispatch(vm, this.signal);
        }

        fn dispatch(vm: *jsc.VirtualMachine, signal_ptr: *AbortSignal) void {
            const loop = vm.eventLoop();
            loop.enter();
            defer loop.exit();
            // signalAbort() releases the extra ref from timeout() after all
            // abort work completes, so we must not unref here.
            signal_ptr.signal(vm.global, .Timeout);
        }

        // This may run inside the "signal" call.
        fn deinit(this: *Timeout, vm: *jsc.VirtualMachine) void {
            this.cancel(vm);
            bun.destroy(this);
        }

        /// Caller is expected to have already ref'd the AbortSignal.
        export fn AbortSignal__Timeout__create(vm: *jsc.VirtualMachine, signal_: *AbortSignal, milliseconds: u64) *Timeout {
            return Timeout.init(vm, signal_, milliseconds);
        }

        export fn AbortSignal__Timeout__run(this: *Timeout, vm: *jsc.VirtualMachine) void {
            this.run(vm);
        }

        export fn AbortSignal__Timeout__deinit(this: *Timeout) void {
            // Called from ~AbortSignal() / cancelTimer(). The AbortSignal's
            // ScriptExecutionContext may be a dead global under --isolate, so
            // we resolve the VM via the threadlocal instead of taking it as a
            // parameter (which the caller would have to dereference the dead
            // context to obtain).
            this.deinit(jsc.VirtualMachine.get());
        }
    };

    extern fn WebCore__AbortSignal__aborted(arg0: *AbortSignal) bool;
    extern fn WebCore__AbortSignal__abortReason(arg0: *AbortSignal) JSValue;
    extern fn WebCore__AbortSignal__addListener(arg0: *AbortSignal, arg1: ?*anyopaque, ArgFn2: ?*const fn (?*anyopaque, JSValue) callconv(.c) void) *AbortSignal;
    extern fn WebCore__AbortSignal__cleanNativeBindings(arg0: *AbortSignal, arg1: ?*anyopaque) void;
    extern fn WebCore__AbortSignal__create(arg0: *JSGlobalObject) JSValue;
    extern fn WebCore__AbortSignal__fromJS(JSValue0: JSValue) ?*AbortSignal;
    extern fn WebCore__AbortSignal__ref(arg0: *AbortSignal) *AbortSignal;
    extern fn WebCore__AbortSignal__toJS(arg0: *AbortSignal, arg1: *JSGlobalObject) JSValue;
    extern fn WebCore__AbortSignal__unref(arg0: *AbortSignal) void;

    pub fn listen(
        this: *AbortSignal,
        comptime Context: type,
        ctx: *Context,
        comptime cb: *const fn (*Context, JSValue) void,
    ) *AbortSignal {
        const Wrapper = struct {
            const call = cb;
            pub fn callback(
                ptr: ?*anyopaque,
                reason: JSValue,
            ) callconv(.c) void {
                const val = castPtr(*Context, ptr.?);
                call(val, reason);
            }
        };

        return this.addListener(@as(?*anyopaque, @ptrCast(ctx)), Wrapper.callback);
    }

    pub fn addListener(
        this: *AbortSignal,
        ctx: ?*anyopaque,
        callback: *const fn (?*anyopaque, JSValue) callconv(.c) void,
    ) *AbortSignal {
        return WebCore__AbortSignal__addListener(this, ctx, callback);
    }

    pub fn cleanNativeBindings(this: *AbortSignal, ctx: ?*anyopaque) void {
        return WebCore__AbortSignal__cleanNativeBindings(this, ctx);
    }

    extern fn WebCore__AbortSignal__signal(*AbortSignal, *JSGlobalObject, CommonAbortReason) void;

    /// Fire the AbortSignal with a CommonAbortReason. Upstream also bumps
    /// `bun.analytics.Features.abort_signal`; we omit the counter until
    /// `home_rt.analytics` is wired in Phase 12.2.
    pub fn signal(
        this: *AbortSignal,
        globalObject: *JSGlobalObject,
        reason: CommonAbortReason,
    ) void {
        return WebCore__AbortSignal__signal(this, globalObject, reason);
    }

    extern fn WebCore__AbortSignal__incrementPendingActivity(*AbortSignal) void;
    extern fn WebCore__AbortSignal__decrementPendingActivity(*AbortSignal) void;

    pub fn pendingActivityRef(this: *AbortSignal) void {
        return WebCore__AbortSignal__incrementPendingActivity(this);
    }

    pub fn pendingActivityUnref(this: *AbortSignal) void {
        return WebCore__AbortSignal__decrementPendingActivity(this);
    }

    /// This function is not threadsafe. aborted is a boolean, not an atomic!
    pub fn aborted(this: *AbortSignal) bool {
        return WebCore__AbortSignal__aborted(this);
    }

    /// This function is not threadsafe. JSValue cannot safely be passed between threads.
    pub fn abortReason(this: *AbortSignal) JSValue {
        return WebCore__AbortSignal__abortReason(this);
    }

    extern fn WebCore__AbortSignal__reasonIfAborted(*AbortSignal, *JSGlobalObject, *u8) JSValue;

    pub const AbortReason = union(enum) {
        common: CommonAbortReason,
        js: JSValue,

        /// `toBodyValueError` upstream returns `jsc.WebCore.Body.Value.ValueError`,
        /// which lives in code not yet ported. Re-add once Body lands.
        pub fn toJS(this: AbortReason, global: *JSGlobalObject) JSValue {
            return switch (this) {
                .common => |reason| reason.toJS(global),
                .js => |value| value,
            };
        }
    };

    pub fn reasonIfAborted(this: *AbortSignal, global: *JSGlobalObject) ?AbortReason {
        var reason: u8 = 0;
        const js_reason = WebCore__AbortSignal__reasonIfAborted(this, global, &reason);
        if (reason > 0) {
            if (comptime bun.Environment.allow_assert) {
                bun.debugAssert(js_reason.isUndefined());
            }
            return .{ .common = @enumFromInt(reason) };
        }
        if (js_reason == .zero) {
            return null; // not aborted
        }
        return .{ .js = js_reason };
    }

    pub fn ref(this: *AbortSignal) *AbortSignal {
        return WebCore__AbortSignal__ref(this);
    }

    pub fn unref(this: *AbortSignal) void {
        WebCore__AbortSignal__unref(this);
    }

    pub fn detach(this: *AbortSignal, ctx: ?*anyopaque) void {
        this.cleanNativeBindings(ctx);
        this.unref();
    }

    pub fn fromJS(value: JSValue) ?*AbortSignal {
        return WebCore__AbortSignal__fromJS(value);
    }

    pub fn toJS(this: *AbortSignal, global: *JSGlobalObject) JSValue {
        return WebCore__AbortSignal__toJS(this, global);
    }

    pub fn create(global: *JSGlobalObject) JSValue {
        return WebCore__AbortSignal__create(global);
    }

    extern fn WebCore__AbortSignal__new(*JSGlobalObject) *AbortSignal;
    pub fn new(global: *JSGlobalObject) *AbortSignal {
        jsc.markBinding(@src());
        return WebCore__AbortSignal__new(global);
    }

    // `getTimeout` and the whole `Timeout` substruct are omitted until
    // `home_rt.jsc.VirtualMachine` and `jsc.API.Timer.EventLoopTimer` exist.
    // The C++ side keeps the field; callers that need it must wait for
    // Phase 12.2.
};

test "AbortSignal is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*AbortSignal) == @sizeOf(usize));
}

test "AbortSignal exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(AbortSignal, "aborted"));
    try std.testing.expect(@hasDecl(AbortSignal, "abortReason"));
    try std.testing.expect(@hasDecl(AbortSignal, "addListener"));
    try std.testing.expect(@hasDecl(AbortSignal, "listen"));
    try std.testing.expect(@hasDecl(AbortSignal, "cleanNativeBindings"));
    try std.testing.expect(@hasDecl(AbortSignal, "signal"));
    try std.testing.expect(@hasDecl(AbortSignal, "ref"));
    try std.testing.expect(@hasDecl(AbortSignal, "unref"));
    try std.testing.expect(@hasDecl(AbortSignal, "detach"));
    try std.testing.expect(@hasDecl(AbortSignal, "fromJS"));
    try std.testing.expect(@hasDecl(AbortSignal, "toJS"));
    try std.testing.expect(@hasDecl(AbortSignal, "create"));
    try std.testing.expect(@hasDecl(AbortSignal, "new"));
    try std.testing.expect(@hasDecl(AbortSignal, "reasonIfAborted"));
    try std.testing.expect(@hasDecl(AbortSignal, "pendingActivityRef"));
    try std.testing.expect(@hasDecl(AbortSignal, "pendingActivityUnref"));
}

test "AbortSignal.AbortReason is a tagged union {common, js}" {
    const info = @typeInfo(AbortSignal.AbortReason).@"union";
    try std.testing.expectEqualStrings("common", info.fields[0].name);
    try std.testing.expectEqualStrings("js", info.fields[1].name);
}
