// Home Programming Language - Callback and Function Pointer Support
// Utilities for working with C callbacks and function pointers

const std = @import("std");

// ============================================================================
// Function Pointer Utilities
// ============================================================================

/// Create a C-compatible function pointer type
pub fn CFn(comptime ReturnType: type, comptime ParamTypes: []const type) type {
    const params_tuple = makeTuple(ParamTypes);
    const Params = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = params_tuple,
        .decls = &.{},
        .is_tuple = true,
    } });

    return *const fn (Params) callconv(.c) ReturnType;
}

fn makeTuple(comptime types: []const type) []const std.builtin.Type.StructField {
    comptime {
        var fields: [types.len]std.builtin.Type.StructField = undefined;
        for (types, 0..) |T, i| {
            fields[i] = .{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = T,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
        }
        const final = fields;
        return &final;
    }
}

// ============================================================================
// Callback Context
// ============================================================================

/// Generic callback context for passing user data to C callbacks
pub const CallbackContext = struct {
    userdata: ?*anyopaque = null,

    pub fn init(userdata: ?*anyopaque) CallbackContext {
        return .{ .userdata = userdata };
    }

    /// Get typed userdata
    pub fn get(self: CallbackContext, comptime T: type) ?*T {
        if (self.userdata) |data| {
            return @as(*T, @ptrCast(@alignCast(data)));
        }
        return null;
    }

    /// Set typed userdata
    pub fn set(self: *CallbackContext, data: anytype) void {
        self.userdata = @as(*anyopaque, @ptrCast(data));
    }
};

// ============================================================================
// Callback Wrapper
// ============================================================================

/// Wraps a Home function to make it callable from C
pub fn Callback(comptime FnType: type) type {
    return struct {
        const Self = @This();

        callback_fn: FnType,
        context: CallbackContext,

        pub fn init(callback_fn: FnType, userdata: ?*anyopaque) Self {
            return .{
                .callback_fn = callback_fn,
                .context = CallbackContext.init(userdata),
            };
        }

        /// Get the C-compatible function pointer
        pub fn getCFn(self: *Self) FnType {
            return self.callback_fn;
        }
    };
}

// ============================================================================
// Common C Callback Signatures
// ============================================================================

/// C void callback: void (*)(void*)
pub const VoidCallback = *const fn (?*anyopaque) callconv(.c) void;

/// C int callback: int (*)(void*)
pub const IntCallback = *const fn (?*anyopaque) callconv(.c) c_int;

/// C comparison callback: int (*)(const void*, const void*)
pub const CompareFn = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;

/// C filter callback: int (*)(void*)
pub const FilterFn = *const fn (?*anyopaque) callconv(.c) c_int;

/// C foreach callback: void (*)(void*, void*)
pub const ForEachFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

// ============================================================================
// Callback Registry
// ============================================================================

/// Thread-safe callback registry for managing C callbacks
pub const CallbackRegistry = struct {
    const Entry = struct {
        callback: *anyopaque,
        context: ?*anyopaque,
    };

    entries: std.AutoHashMap(usize, Entry),
    next_id: usize,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CallbackRegistry {
        return .{
            .entries = std.AutoHashMap(usize, Entry).init(allocator),
            .next_id = 1,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CallbackRegistry) void {
        self.entries.deinit();
    }

    /// Register a callback and return its ID
    pub fn register(self: *CallbackRegistry, callback: anytype, context: ?*anyopaque) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        try self.entries.put(id, .{
            .callback = @as(*anyopaque, @ptrCast(@constCast(&callback))),
            .context = context,
        });

        return id;
    }

    /// Unregister a callback by ID
    pub fn unregister(self: *CallbackRegistry, id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.entries.remove(id);
    }

    /// Get callback by ID
    pub fn get(self: *CallbackRegistry, id: usize, comptime T: type) ?T {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(id)) |entry| {
            return @as(T, @ptrCast(@alignCast(entry.callback)));
        }
        return null;
    }

    /// Get context for callback ID
    pub fn getContext(self: *CallbackRegistry, id: usize) ?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(id)) |entry| {
            return entry.context;
        }
        return null;
    }
};

// ============================================================================
// Closure Support (Advanced)
// ============================================================================

/// Closure captures environment and can be called from C
pub fn Closure(comptime ReturnType: type, comptime ParamType: type) type {
    return struct {
        const Self = @This();
        const ClosureFn = *const fn (env: ?*anyopaque, param: ParamType) ReturnType;

        env: ?*anyopaque,
        func: ClosureFn,

        pub fn init(env: ?*anyopaque, func: ClosureFn) Self {
            return .{ .env = env, .func = func };
        }

        pub fn call(self: *const Self, param: ParamType) ReturnType {
            return self.func(self.env, param);
        }

        /// Get a C-compatible trampoline function
        pub fn trampoline(self: *const Self) *const fn (ParamType) callconv(.c) ReturnType {
            // Note: This is a simplified example. Real implementation would need
            // more sophisticated trampolines for proper closure support from C.
            _ = self;
            @compileError("Trampoline generation not yet implemented");
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "CallbackContext" {
    const testing = std.testing;

    var value: i32 = 42;
    var ctx = CallbackContext.init(&value);

    const ptr = ctx.get(i32);
    try testing.expect(ptr != null);
    try testing.expectEqual(@as(i32, 42), ptr.?.*);
}

test "Callback wrapper" {
    const TestFn = *const fn (i32) callconv(.c) i32;
    const test_fn: TestFn = struct {
        fn f(x: i32) callconv(.c) i32 {
            return x * 2;
        }
    }.f;

    var cb = Callback(TestFn).init(test_fn, null);
    const fn_ptr = cb.getCFn();

    const result = fn_ptr(21);
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 42), result);
}

test "CallbackRegistry" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = CallbackRegistry.init(allocator);
    defer registry.deinit();

    const TestFn = *const fn () callconv(.c) void;
    const test_fn: TestFn = struct {
        fn f() callconv(.c) void {}
    }.f;

    var ctx: i32 = 123;

    const id = try registry.register(test_fn, &ctx);
    try testing.expect(id > 0);

    const retrieved = registry.get(id, TestFn);
    try testing.expect(retrieved != null);

    const ctx_ptr = registry.getContext(id);
    try testing.expect(ctx_ptr != null);

    registry.unregister(id);

    const after_unregister = registry.get(id, TestFn);
    try testing.expect(after_unregister == null);
}

test "Closure" {
    const MyClosure = Closure(i32, i32);

    const env_value: i32 = 10;
    const add_fn = struct {
        fn f(env: ?*anyopaque, param: i32) i32 {
            const val = @as(*const i32, @ptrCast(@alignCast(env.?)));
            return val.* + param;
        }
    }.f;

    const closure = MyClosure.init(@constCast(&env_value), add_fn);
    const result = closure.call(5);

    const testing = std.testing;
    try testing.expectEqual(@as(i32, 15), result);
}

test "Common callback signatures" {
    // Just ensure they compile
    const void_cb: VoidCallback = struct {
        fn f(_: ?*anyopaque) callconv(.c) void {}
    }.f;
    _ = void_cb;

    const int_cb: IntCallback = struct {
        fn f(_: ?*anyopaque) callconv(.c) c_int {
            return 0;
        }
    }.f;
    _ = int_cb;

    const cmp: CompareFn = struct {
        fn f(_: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) c_int {
            return 0;
        }
    }.f;
    _ = cmp;
}
