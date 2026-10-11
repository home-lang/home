const bun = @import("bun");
const jsc = bun.jsc;
const Self = @This();

resource: jsc.Strong.Optional = .empty,

extern "c" fn Home__FSRequest__event(global: *jsc.JSGlobalObject, value: jsc.JSValue, previous: jsc.JSValue, operation: u8) jsc.JSValue;

pub fn init(global: *jsc.JSGlobalObject, promise: jsc.JSValue) Self {
    if (global.bunVM().scriptExecutionStatus() != .running) return .{};
    const value = Home__FSRequest__event(global, promise, .js_undefined, 0);
    if (value.isUndefined()) return .{};
    return .{ .resource = .create(value, global) };
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
