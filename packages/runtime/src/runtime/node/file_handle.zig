//! Native ownership for fs.promises FileHandles. Pending close jobs root the
//! branded owner; VM shutdown retires descriptors after admitted jobs quiesce.
const bun = @import("bun");
const jsc = bun.jsc;
const Maybe = bun.sys.Maybe;
extern fn Home__FileHandle__wrap(*jsc.JSGlobalObject, *State) jsc.JSValue;
extern fn Home__FileHandle__state(*jsc.JSGlobalObject, jsc.JSValue) ?*State;
var registry_lock: bun.Mutex = .{};
var registry: ?*State = null;
pub const State = struct {
    lock: bun.Mutex = .{},
    fd: bun.FD,
    closed: bool = false,
    global: *jsc.JSGlobalObject,
    next: ?*State = null,
    pub fn create(global: *jsc.JSGlobalObject, fd: bun.FD) jsc.JSValue {
        const state = bun.new(State, .{ .fd = fd, .global = global });
        registry_lock.lock();
        state.next = registry;
        registry = state;
        registry_lock.unlock();
        return Home__FileHandle__wrap(global, state);
    }
    pub fn close(this: *State) Maybe(void) {
        this.lock.lock();
        defer this.lock.unlock();
        if (this.closed) return .{ .result = {} };
        this.closed = true;
        if (bun.Environment.isPosix) {
            const errno = bun.sys.getErrno(@import("std").c.close(this.fd.native()));
            if (errno != .SUCCESS) return .{ .err = .{ .errno = @backingInt(errno), .syscall = .close, .fd = this.fd } };
        } else if (this.fd.closeAllowingStandardIo(@returnAddress())) |err| return .{ .err = err };
        return .{ .result = {} };
    }
    pub fn destroy(this: *State) void {
        registry_lock.lock();
        var cursor = &registry;
        while (cursor.*) |state| {
            if (state == this) {
                cursor.* = state.next;
                break;
            }
            cursor = &state.next;
        }
        registry_lock.unlock();
        _ = this.close();
        bun.destroy(this);
    }
};
pub const OpenResult = struct {
    fd: bun.FD,
    pub fn toJS(this: OpenResult, global: *jsc.JSGlobalObject) jsc.JSValue {
        const number = this.fd.toJS(global);
        if (global.hasException()) return .zero;
        const fd = bun.FD.fromJSValidated(number, global) catch return .zero;
        return State.create(global, fd.?);
    }
    pub fn deinitForShutdown(this: *OpenResult) void {
        this.fd.close();
    }
};

pub const CloseArgument = struct {
    pub const file_handle_close = true;
    state: *State,
    root: jsc.Strong.Optional,
    pub fn fromJS(global: *jsc.JSGlobalObject, arguments: *jsc.CallFrame.ArgumentsSlice) bun.JSError!CloseArgument {
        const value = arguments.nextEat() orelse return global.throwInvalidArguments("FileHandle owner is required", .{});
        const state = Home__FileHandle__state(global, value) orelse return error.JSError;
        return .{ .state = state, .root = .create(value, global) };
    }
    pub fn toThreadSafe(_: *CloseArgument) void {}
    pub fn deinit(this: CloseArgument) void {
        var root = this.root;
        root.deinit();
    }
};
pub export fn Home__FileHandle__memoryCost() usize {
    return @sizeOf(State);
}
pub export fn Home__FileHandle__release(state: *State) void {
    state.destroy();
}
pub export fn Home__FileHandle__isOpen(state: *State) bool {
    state.lock.lock();
    defer state.lock.unlock();
    return !state.closed;
}
pub export fn Home__FileHandle__detach(state: *State) void {
    state.lock.lock();
    defer state.lock.unlock();
    state.closed = true;
}
pub export fn Home__FileHandle__fd(state: *State) jsc.JSValue {
    state.lock.lock();
    defer state.lock.unlock();
    return if (state.closed) jsc.JSValue.jsNumberFromInt32(-1) else state.fd.toJSWithoutMakingLibUVOwned();
}
pub fn shutdown(global: *jsc.JSGlobalObject) void {
    registry_lock.lock();
    defer registry_lock.unlock();
    var cursor = registry;
    while (cursor) |state| : (cursor = state.next) {
        if (state.global == global) _ = state.close();
    }
}
