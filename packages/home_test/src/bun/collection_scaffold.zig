const std = @import("std");

pub const Collection = @import("Collection.zig");

pub const jsc = struct {
    pub const JSValue = usize;

    pub const JSGlobalObject = opaque {};

    pub const Strong = struct {
        pub const Deprecated = struct {
            allocator: std.mem.Allocator,
            value: JSValue,
            deinited: bool = false,

            pub fn init(allocator: std.mem.Allocator, value: JSValue) Deprecated {
                return .{ .allocator = allocator, .value = value };
            }

            pub fn deinit(this: *Deprecated) void {
                this.deinited = true;
            }

            pub fn get(this: Deprecated) JSValue {
                return this.value;
            }
        };
    };

    pub const ConsoleObject = struct {
        pub const Formatter = struct {
            globalThis: *JSGlobalObject,
            quote_strings: bool,

            pub fn deinit(_: *Formatter) void {}
        };
    };

    pub const Jest = struct {
        pub const Jest = struct {
            pub const runner = null;
        };
    };
};

pub const ScopeMode = enum {
    normal,
    skip,
    todo,
    failing,
    filtered_out,
};

pub const BaseScope = struct {
    parent: ?*DescribeScope,
    name: ?[]const u8,
    concurrent: bool,
    mode: ScopeMode,
    only: enum { no, contains, yes },
    has_callback: bool,
    test_id_for_debugger: i32,
    line_no: u32,
};

pub const DescribeScope = struct {
    base: BaseScope,
    failed: bool = false,
    destroyed: bool = false,

    pub fn create(gpa: std.mem.Allocator, base: BaseScope) *DescribeScope {
        const scope = gpa.create(DescribeScope) catch @panic("OutOfMemory");
        scope.* = .{ .base = base };
        return scope;
    }

    pub fn destroy(this: *DescribeScope, gpa: std.mem.Allocator) void {
        this.destroyed = true;
        gpa.destroy(this);
    }
};

pub const BunTestRoot = struct {
    hook_scope: ?*DescribeScope,
};

pub const BunTestPtr = struct {
    value: *BunTest,

    pub fn init(value: *BunTest) BunTestPtr {
        return .{ .value = value };
    }

    pub fn get(this: BunTestPtr) *BunTest {
        return this.value;
    }
};

pub const StepResult = union(enum) {
    complete,
    waiting: struct {},
    pending,
};

pub const HandleUncaughtExceptionResult = enum {
    hide_error,
    show_handled_error,
    show_unhandled_error_between_tests,
    show_unhandled_error_in_describe,
};

pub const BunTest = struct {
    gpa: std.mem.Allocator,
    collection: Collection,
    callback_runs: usize = 0,
    last_callback: ?jsc.JSValue = null,
    last_callback_data: ?BunTest.RefDataValue = null,
    added_results: std.array_list.Managed(BunTest.RefDataValue),
    next_callback_result: ?BunTest.RefDataValue = null,

    pub const RefDataValue = union(enum) {
        start,
        collection: struct {
            active_scope: *DescribeScope,
        },
        done: struct {},
    };

    pub fn init(gpa: std.mem.Allocator, root: *BunTestRoot) BunTest {
        return .{
            .gpa = gpa,
            .collection = Collection.init(gpa, root),
            .added_results = .init(gpa),
        };
    }

    pub fn deinit(this: *BunTest) void {
        this.collection.deinit();
        this.added_results.deinit();
    }

    pub fn strong(this: *BunTest) BunTestPtr {
        return .init(this);
    }

    pub fn addResult(this: *BunTest, result: BunTest.RefDataValue) void {
        this.added_results.append(result) catch @panic("OutOfMemory");
    }

    pub fn runTestCallback(
        this_strong: BunTestPtr,
        _: *jsc.JSGlobalObject,
        callback: jsc.JSValue,
        _: bool,
        data: BunTest.RefDataValue,
        _: *const anyopaque,
    ) ?BunTest.RefDataValue {
        const this = this_strong.get();
        this.callback_runs += 1;
        this.last_callback = callback;
        this.last_callback_data = data;
        return this.next_callback_result;
    }
};

pub const RefDataValue = BunTest.RefDataValue;

pub const debug = struct {
    pub const group = struct {
        pub fn begin(_: std.builtin.SourceLocation) void {}
        pub fn end() void {}
        pub fn log(comptime _: []const u8, _: anytype) void {}
    };
};
