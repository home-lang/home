const bun = @import("bun");
const jsc = bun.jsc;
const Self = @This();

resource: jsc.Strong.Optional = .empty,
callback_mode: bool = false,

extern "c" fn Home__FSRequest__event(global: *jsc.JSGlobalObject, value: jsc.JSValue, previous: jsc.JSValue, operation: u8) jsc.JSValue;

pub fn init(global: *jsc.JSGlobalObject, promise: jsc.JSValue) Self {
    if (global.bunVM().scriptExecutionStatus() != .running) return .{};
    const value = Home__FSRequest__event(global, promise, .js_undefined, 0);
    if (value.isUndefined()) return .{};
    return .{ .resource = .create(value, global) };
}

pub fn initCallback(global: *jsc.JSGlobalObject, callback: jsc.JSValue) Self {
    if (global.bunVM().scriptExecutionStatus() != .running) return .{ .callback_mode = true };
    const value = Home__FSRequest__event(global, callback, .js_undefined, 4);
    return .{ .resource = if (value.isUndefined()) .empty else .create(value, global), .callback_mode = true };
}

pub fn queueEarlyError(global: *jsc.JSGlobalObject, callback: jsc.JSValue, error_value: jsc.JSValue) jsc.JSValue {
    _ = Home__FSRequest__event(global, callback, error_value, 7);
    return .js_undefined;
}

pub fn deliver(this: *Self, global: *jsc.JSGlobalObject, promise: *jsc.JSPromise.Strong, value: jsc.JSValue, failed: bool) bun.JSTerminated!void {
    if (this.callback_mode) {
        if (global.bunVM().scriptExecutionStatus() == .running) {
            if (this.resource.get()) |resource| _ = Home__FSRequest__event(global, resource, value, if (failed) 6 else 5);
        }
    } else if (failed) {
        try promise.get().reject(global, value);
    } else {
        try promise.get().resolve(global, value);
    }
}

pub fn enter(this: *Self, global: *jsc.JSGlobalObject) jsc.Strong.Optional {
    const resource = this.resource.get() orelse return .empty;
    if (global.bunVM().scriptExecutionStatus() != .running) return .empty;
    const value = Home__FSRequest__event(global, resource, .js_undefined, 1);
    if (value.isUndefined()) return .empty;
    return .create(value, global);
}

pub fn leave(this: *Self, global: *jsc.JSGlobalObject, previous: *jsc.Strong.Optional) void {
    defer previous.deinit();
    const context = previous.get() orelse return;
    if (global.bunVM().scriptExecutionStatus() == .running) {
        _ = Home__FSRequest__event(global, this.resource.get().?, context, 2);
    }
}

pub fn deinit(this: *Self, global: *jsc.JSGlobalObject) void {
    defer this.resource.deinit();
    const resource = this.resource.get() orelse return;
    if (global.bunVM().scriptExecutionStatus() == .running) {
        _ = Home__FSRequest__event(global, resource, .js_undefined, 3);
    }
}
