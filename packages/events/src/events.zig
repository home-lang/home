const std = @import("std");
const StaticMutex = @import("threading").StaticMutex;

/// Event handler function type
pub fn Handler(comptime T: type) type {
    return *const fn (event: T) void;
}

/// Wildcard handler for any event
pub const WildcardHandler = *const fn (event_type: []const u8, data: []const u8) void;

/// Event priority levels
pub const Priority = enum(u8) {
    low = 0,
    normal = 128,
    high = 255,
};

/// Event listener with priority
pub fn Listener(comptime T: type) type {
    return struct {
        handler: Handler(T),
        priority: Priority,
        once: bool,
    };
}

/// Generic event emitter
pub fn EventEmitter(comptime Events: type) type {
    return struct {
        allocator: std.mem.Allocator,
        listeners: ListenerMap,
        wildcard_listeners: std.ArrayList(WildcardHandler),
        mutex: StaticMutex,
        next_listener_id: u64,

        const Self = @This();
        const ListenerMap = std.StringHashMap(std.ArrayList(AnyListener));

        const AnyListener = struct {
            id: u64,
            handler_ptr: *const anyopaque,
            priority: Priority,
            once: bool,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .listeners = ListenerMap.init(allocator),
                .wildcard_listeners = .empty,
                .mutex = .{},
                .next_listener_id = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.listeners.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.listeners.deinit();
            self.wildcard_listeners.deinit(self.allocator);
            self.mutex.deinit();
        }

        /// Register an event handler
        pub fn on(self: *Self, comptime event: []const u8, handler: Handler(Events.getEventType(event))) !void {
            try self.addListener(event, @ptrCast(handler), .normal, false);
        }

        /// Register a one-time event handler
        pub fn once(self: *Self, comptime event: []const u8, handler: Handler(Events.getEventType(event))) !void {
            try self.addListener(event, @ptrCast(handler), .normal, true);
        }

        /// Register a high-priority event handler
        pub fn onHighPriority(self: *Self, comptime event: []const u8, handler: Handler(Events.getEventType(event))) !void {
            try self.addListener(event, @ptrCast(handler), .high, false);
        }

        /// Register a low-priority event handler
        pub fn onLowPriority(self: *Self, comptime event: []const u8, handler: Handler(Events.getEventType(event))) !void {
            try self.addListener(event, @ptrCast(handler), .low, false);
        }

        /// Listen to all events
        pub fn onAny(self: *Self, handler: WildcardHandler) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.wildcard_listeners.append(self.allocator, handler);
        }

        fn addListener(self: *Self, event: []const u8, handler: *const anyopaque, priority: Priority, once_flag: bool) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const result = try self.listeners.getOrPut(event);
            if (!result.found_existing) {
                result.value_ptr.* = .empty;
            }

            const listener = AnyListener{
                .id = self.next_listener_id,
                .handler_ptr = handler,
                .priority = priority,
                .once = once_flag,
            };
            self.next_listener_id += 1;

            // Insert sorted by priority (high to low)
            var insert_idx: usize = result.value_ptr.items.len;
            for (result.value_ptr.items, 0..) |existing, i| {
                if (@intFromEnum(priority) > @intFromEnum(existing.priority)) {
                    insert_idx = i;
                    break;
                }
            }
            try result.value_ptr.insert(self.allocator, insert_idx, listener);
        }

        /// Remove an event handler
        pub fn off(self: *Self, event: []const u8, handler: ?*const anyopaque) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.listeners.getPtr(event)) |listener_list| {
                if (handler) |h| {
                    // Remove specific handler
                    var i: usize = 0;
                    while (i < listener_list.items.len) {
                        if (listener_list.items[i].handler_ptr == h) {
                            _ = listener_list.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                } else {
                    // Remove all handlers for this event
                    listener_list.clearRetainingCapacity();
                }
            }
        }

        /// Emit an event
        pub fn emit(self: *Self, comptime event: []const u8, data: Events.getEventType(event)) void {
            self.mutex.lock();

            // Own both snapshots before unlocking; listener registration and
            // removal are allowed to reallocate their backing arrays while
            // callbacks are running.
            var listeners_allocated = false;
            const listeners = if (self.listeners.get(event)) |list| blk: {
                if (self.allocator.dupe(AnyListener, list.items)) |snapshot| {
                    listeners_allocated = true;
                    break :blk snapshot;
                } else |_| break :blk @as([]AnyListener, &[_]AnyListener{});
            } else @as([]AnyListener, &[_]AnyListener{});
            var wildcards_allocated = false;
            const wildcard_snapshot = if (self.allocator.dupe(WildcardHandler, self.wildcard_listeners.items)) |snapshot| blk: {
                wildcards_allocated = true;
                break :blk snapshot;
            } else |_| @as([]WildcardHandler, &[_]WildcardHandler{});

            var to_remove: std.ArrayList(u64) = .empty;
            defer {
                to_remove.deinit(self.allocator);
                if (listeners_allocated) self.allocator.free(listeners);
                if (wildcards_allocated) self.allocator.free(wildcard_snapshot);
            }

            self.mutex.unlock();

            // Call handlers
            for (listeners) |listener| {
                const handler: Handler(Events.getEventType(event)) = @ptrCast(@alignCast(listener.handler_ptr));
                handler(data);
                if (listener.once) {
                    to_remove.append(self.allocator, listener.id) catch {};
                }
            }

            // Call wildcard handlers
            // Note: In a real implementation, we'd serialize data to JSON
            for (wildcard_snapshot) |wildcard| {
                wildcard(event, ""); // Simplified - real impl would serialize data
            }

            // Remove once listeners (in reverse order to maintain indices)
            if (to_remove.items.len > 0) {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.listeners.getPtr(event)) |listener_list| {
                    for (to_remove.items) |id| {
                        for (listener_list.items, 0..) |listener, i| {
                            if (listener.id == id) {
                                _ = listener_list.orderedRemove(i);
                                break;
                            }
                        }
                    }
                }
            }
        }

        /// Get listener count for an event
        pub fn listenerCount(self: *Self, event: []const u8) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.listeners.get(event)) |list| {
                return list.items.len;
            }
            return 0;
        }

        /// Get all registered event names
        pub fn eventNames(self: *Self) []const []const u8 {
            self.mutex.lock();
            defer self.mutex.unlock();

            var names: std.ArrayList([]const u8) = .empty;
            var it = self.listeners.keyIterator();
            while (it.next()) |key| {
                names.append(self.allocator, key.*) catch continue;
            }
            return names.toOwnedSlice(self.allocator) catch &[_][]const u8{};
        }

        /// Remove all listeners
        pub fn removeAllListeners(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var it = self.listeners.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.clearRetainingCapacity();
            }
            self.wildcard_listeners.clearRetainingCapacity();
        }
    };
}

/// Simple string-based event emitter (like mitt)
pub const SimpleEmitter = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMap(std.ArrayList(SimpleHandler)),
    wildcard_handlers: std.ArrayList(WildcardHandler),
    mutex: StaticMutex,

    const SimpleHandler = *const fn (data: []const u8) void;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .handlers = std.StringHashMap(std.ArrayList(SimpleHandler)).init(allocator),
            .wildcard_handlers = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.handlers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.handlers.deinit();
        self.wildcard_handlers.deinit(self.allocator);
        self.mutex.deinit();
    }

    /// Register a handler for an event
    pub fn on(self: *Self, event: []const u8, handler: SimpleHandler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = try self.handlers.getOrPut(event);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        try result.value_ptr.append(self.allocator, handler);
    }

    /// Register a wildcard handler
    pub fn onAny(self: *Self, handler: WildcardHandler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.wildcard_handlers.append(self.allocator, handler);
    }

    /// Remove a handler
    pub fn off(self: *Self, event: []const u8, handler: ?SimpleHandler) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.handlers.getPtr(event)) |handler_list| {
            if (handler) |h| {
                var i: usize = 0;
                while (i < handler_list.items.len) {
                    if (handler_list.items[i] == h) {
                        _ = handler_list.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            } else {
                handler_list.clearRetainingCapacity();
            }
        }
    }

    /// Emit an event
    pub fn emit(self: *Self, event: []const u8, data: []const u8) void {
        // Copy handler lists under the lock, then dispatch without holding
        // the mutex. Track whether each copy was actually allocated so we
        // don't attempt to free a static-empty fallback slice.
        self.mutex.lock();
        var handlers_allocated = false;
        const handlers_copy = if (self.handlers.get(event)) |list| blk: {
            if (self.allocator.dupe(SimpleHandler, list.items)) |dup| {
                handlers_allocated = true;
                break :blk dup;
            } else |_| break :blk @as([]SimpleHandler, &[_]SimpleHandler{});
        } else @as([]SimpleHandler, &[_]SimpleHandler{});
        var wildcard_allocated = false;
        const wildcard_copy = if (self.allocator.dupe(WildcardHandler, self.wildcard_handlers.items)) |dup| blk: {
            wildcard_allocated = true;
            break :blk dup;
        } else |_| @as([]WildcardHandler, &[_]WildcardHandler{});
        self.mutex.unlock();

        defer {
            if (handlers_allocated) self.allocator.free(handlers_copy);
            if (wildcard_allocated) self.allocator.free(wildcard_copy);
        }

        for (handlers_copy) |handler| {
            handler(data);
        }

        for (wildcard_copy) |wildcard| {
            wildcard(event, data);
        }
    }

    /// Dispatch (alias for emit)
    pub fn dispatch(self: *Self, event: []const u8, data: []const u8) void {
        self.emit(event, data);
    }

    /// Listen (alias for on)
    pub fn listen(self: *Self, event: []const u8, handler: SimpleHandler) !void {
        return self.on(event, handler);
    }

    /// Get listener count
    pub fn listenerCount(self: *Self, event: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.handlers.get(event)) |list| {
            return list.items.len;
        }
        return 0;
    }

    /// Clear all handlers
    pub fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.handlers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.clearRetainingCapacity();
        }
        self.wildcard_handlers.clearRetainingCapacity();
    }
};

/// Global event bus (singleton pattern)
pub const EventBus = struct {
    var instance: ?*SimpleEmitter = null;
    var mutex: StaticMutex = .{};

    pub fn getInstance(allocator: std.mem.Allocator) !*SimpleEmitter {
        mutex.lock();
        defer mutex.unlock();

        if (instance == null) {
            const emitter = try allocator.create(SimpleEmitter);
            emitter.* = SimpleEmitter.init(allocator);
            instance = emitter;
        }
        return instance.?;
    }

    pub fn destroy(allocator: std.mem.Allocator) void {
        mutex.lock();
        defer mutex.unlock();

        if (instance) |inst| {
            inst.deinit();
            allocator.destroy(inst);
            instance = null;
        }
    }
};

/// Convenience functions matching Stacks API

/// Emit/dispatch an event
pub fn dispatch(emitter: *SimpleEmitter, event: []const u8, data: []const u8) void {
    emitter.emit(event, data);
}

/// Alias for dispatch
pub fn useEvent(emitter: *SimpleEmitter, event: []const u8, data: []const u8) void {
    dispatch(emitter, event, data);
}

/// Listen to an event
pub fn listen(emitter: *SimpleEmitter, event: []const u8, handler: SimpleEmitter.SimpleHandler) !void {
    return emitter.on(event, handler);
}

/// Alias for listen
pub fn useListen(emitter: *SimpleEmitter, event: []const u8, handler: SimpleEmitter.SimpleHandler) !void {
    return listen(emitter, event, handler);
}

/// Remove a listener
pub fn off(emitter: *SimpleEmitter, event: []const u8, handler: ?SimpleEmitter.SimpleHandler) void {
    emitter.off(event, handler);
}

// Tests
test "simple emitter basic usage" {
    const allocator = std.testing.allocator;
    var emitter = SimpleEmitter.init(allocator);
    defer emitter.deinit();

    const TestHandler = struct {
        var calls: std.atomic.Value(u32) = .init(0);
        var payload_ok: std.atomic.Value(bool) = .init(false);

        fn h(data: []const u8) void {
            payload_ok.store(std.mem.eql(u8, data, "hello"), .release);
            _ = calls.fetchAdd(1, .release);
        }
    };
    TestHandler.calls.store(0, .release);
    TestHandler.payload_ok.store(false, .release);

    try emitter.on("test", TestHandler.h);
    emitter.emit("test", "hello");

    try std.testing.expectEqual(@as(u32, 1), TestHandler.calls.load(.acquire));
    try std.testing.expect(TestHandler.payload_ok.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), emitter.listenerCount("test"));

    emitter.off("test", TestHandler.h);
    try std.testing.expectEqual(@as(usize, 0), emitter.listenerCount("test"));
}

test "generic emitter owns snapshots and removes once listeners by id" {
    const TestEvents = struct {
        pub fn getEventType(comptime event: []const u8) type {
            if (std.mem.eql(u8, event, "value")) return i32;
            @compileError("unknown test event");
        }
    };
    const TestHandler = struct {
        var total: std.atomic.Value(i32) = .init(0);

        fn handle(value: i32) void {
            _ = total.fetchAdd(value, .acq_rel);
        }
    };

    TestHandler.total.store(0, .release);
    var emitter = EventEmitter(TestEvents).init(std.testing.allocator);
    defer emitter.deinit();

    try emitter.once("value", TestHandler.handle);
    emitter.emit("value", 7);
    emitter.emit("value", 11);

    try std.testing.expectEqual(@as(i32, 7), TestHandler.total.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), emitter.listenerCount("value"));
}

test "simple emitter wildcard" {
    const allocator = std.testing.allocator;
    var emitter = SimpleEmitter.init(allocator);
    defer emitter.deinit();

    const Wildcard = struct {
        var called: std.atomic.Value(bool) = .init(false);

        fn h(event: []const u8, data: []const u8) void {
            called.store(
                std.mem.eql(u8, event, "any-event") and std.mem.eql(u8, data, "data"),
                .release,
            );
        }
    };
    Wildcard.called.store(false, .release);

    try emitter.onAny(Wildcard.h);
    emitter.emit("any-event", "data");
    try std.testing.expect(Wildcard.called.load(.acquire));
}

test "simple emitter clear" {
    const allocator = std.testing.allocator;
    var emitter = SimpleEmitter.init(allocator);
    defer emitter.deinit();

    const handler = struct {
        fn h(data: []const u8) void {
            _ = data;
        }
    }.h;

    try emitter.on("event1", handler);
    try emitter.on("event2", handler);

    try std.testing.expectEqual(@as(usize, 1), emitter.listenerCount("event1"));
    try std.testing.expectEqual(@as(usize, 1), emitter.listenerCount("event2"));

    emitter.clear();

    try std.testing.expectEqual(@as(usize, 0), emitter.listenerCount("event1"));
    try std.testing.expectEqual(@as(usize, 0), emitter.listenerCount("event2"));
}

test "dispatch and listen convenience functions" {
    const allocator = std.testing.allocator;
    var emitter = SimpleEmitter.init(allocator);
    defer emitter.deinit();

    const handler = struct {
        fn h(data: []const u8) void {
            _ = data;
        }
    }.h;

    try listen(&emitter, "user:registered", handler);
    dispatch(&emitter, "user:registered", "{\"name\": \"John\"}");

    off(&emitter, "user:registered", null);
    try std.testing.expectEqual(@as(usize, 0), emitter.listenerCount("user:registered"));
}
