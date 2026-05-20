// Copied from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: src/runtime/test_runner/DoneCallback.zig
// See LICENSE.bun.md for full license text.
/// value = not called yet. null = done already called, no-op.
ref: ?*bun_test.BunTest.RefData,
called: bool = false,

pub const js = jsc.Codegen.JSDoneCallback;
pub const toJS = js.toJS;
pub const fromJS = js.fromJS;

pub fn finalize(
    this: *DoneCallback,
) callconv(.c) void {
    groupLog.begin(@src());
    defer groupLog.end();

    if (this.ref) |ref| ref.deref();
    VirtualMachine.get().allocator.destroy(this);
}

pub fn createUnbound(globalThis: *JSGlobalObject) JSValue {
    groupLog.begin(@src());
    defer groupLog.end();

    var done_callback = bun.handleOom(globalThis.bunVM().allocator.create(DoneCallback));
    done_callback.* = .{ .ref = null };

    const value = done_callback.toJS(globalThis);
    value.ensureStillAlive();
    return value;
}

pub fn bind(value: JSValue, globalThis: *JSGlobalObject) bun.JSError!JSValue {
    const callFn = jsc.JSFunction.create(globalThis, "done", BunTest.bunTestDoneCallback, 1, .{});
    return try callFn.bind(globalThis, value, &bun.String.static("done"), 1, &.{});
}

const bun = @import("bun");
const done_callback_scaffold = @import("done_callback_scaffold.zig");

const jsc = done_callback_scaffold.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const VirtualMachine = jsc.VirtualMachine;

const bun_test = done_callback_scaffold;
const BunTest = done_callback_scaffold.BunTest;
const DoneCallback = done_callback_scaffold.DoneCallback;
const groupLog = done_callback_scaffold.debug.group;
