const std = @import("std");
const bun = @import("bun");

pub const DoneCallback = @import("DoneCallback.zig");

pub const jsc = struct {
    pub const JSValue = struct {
        done_callback: ?*DoneCallback = null,
        ensure_alive_counter: ?*usize = null,
        bound_name: ?[]const u8 = null,
        bound_arg_count: usize = 0,

        pub fn ensureStillAlive(this: JSValue) void {
            if (this.ensure_alive_counter) |counter| counter.* += 1;
        }
    };

    pub const BunVM = struct {
        allocator: std.mem.Allocator,
    };

    pub const JSGlobalObject = struct {
        vm: BunVM,
        ensure_alive_count: usize = 0,

        pub fn init(allocator: std.mem.Allocator) JSGlobalObject {
            return .{ .vm = .{ .allocator = allocator } };
        }

        pub fn bunVM(this: *JSGlobalObject) *BunVM {
            return &this.vm;
        }
    };

    pub const VirtualMachine = struct {
        allocator: std.mem.Allocator,

        var current = VirtualMachine{ .allocator = std.heap.smp_allocator };

        pub fn get() *VirtualMachine {
            return &current;
        }

        pub fn useAllocator(allocator: std.mem.Allocator) void {
            current.allocator = allocator;
        }
    };

    pub const Codegen = struct {
        pub const JSDoneCallback = struct {
            pub fn toJS(this: *DoneCallback, globalThis: *JSGlobalObject) JSValue {
                return .{
                    .done_callback = this,
                    .ensure_alive_counter = &globalThis.ensure_alive_count,
                };
            }

            pub fn fromJS(value: JSValue) ?*DoneCallback {
                return value.done_callback;
            }
        };
    };

    pub const JSFunction = struct {
        pub fn create(_: *JSGlobalObject, _: []const u8, callback: anytype, _: usize, _: anytype) JSFunction {
            _ = callback;
            return .{};
        }

        pub fn bind(_: JSFunction, _: *JSGlobalObject, value: JSValue, name: *const bun.String, arg_count: usize, _: anytype) bun.JSError!JSValue {
            var bound = value;
            bound.bound_name = name.slice();
            bound.bound_arg_count = arg_count;
            return bound;
        }
    };
};

pub const BunTest = struct {
    pub const RefData = struct {
        deref_count: *usize,

        pub fn deref(this: *RefData) void {
            this.deref_count.* += 1;
        }
    };

    pub fn bunTestDoneCallback() void {}
};

pub const debug = struct {
    pub const group = struct {
        pub fn begin(_: std.builtin.SourceLocation) void {}
        pub fn end() void {}
    };
};
