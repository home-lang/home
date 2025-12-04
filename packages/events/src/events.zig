const std = @import("std");

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
        mutex: std.Thread.Mutex,

        const Self = @This();
        const ListenerMap = std.StringHashMap(std.ArrayList(AnyListener));

        const AnyListener = struct {
            handler_ptr: *const anyopaque,
            priority: Priority,
            once: bool,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .listeners = ListenerMap.init(allocator),
                .wildcard_listeners = std.ArrayList(WildcardHandler).init(allocator),
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.listeners.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.listeners.deinit();
            self.wildcard_listeners.deinit();
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
            try self.wildcard_listeners.append(handler);
        }

        fn addListener(self: *Self, event: []const u8, handler: *const anyopaque, priority: Priority, once_flag: bool) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const result = try self.listeners.getOrPut(event);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(AnyListener).init(self.allocator);
            }

            const listener = AnyListener{
                .handler_ptr = handler,
                .priority = priority,
                .once = once_flag,
            };

            // Insert sorted by priority (high to low)
            var insert_idx: usize = result.value_ptr.items.len;
            for (result.value_ptr.items, 0..) |existing, i| {
                if (@intFromEnum(priority) > @intFromEnum(existing.priority)) {
                    insert_idx = i;
                    break;
                }
            }
            try result.value_ptr.insert(insert_idx, listener);
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

            // Get listeners for this event
            const listeners = if (self.listeners.get(event)) |list| list.items else &[_]AnyListener{};

            // Copy once listeners to remove after
            var to_remove = std.ArrayList(usize).init(self.allocator);
            defer to_remove.deinit();

            self.mutex.unlock();

            // Call handlers
            for (listeners, 0..) |listener, i| {
                const handler: Handler(Events.getEventType(event)) = @ptrCast(listener.handler_ptr);
                handler(data);
                if (listener.once) {
                    to_remove.append(i) catch {};
                }
            }

            // Call wildcard handlers
            // Note: In a real implementation, we'd serialize data to JSON
            for (self.wildcard_listeners.items) |wildcard| {
                wildcard(event, ""); // Simplified - real impl would serialize data
            }

            // Remove once listeners (in reverse order to maintain indices)
            if (to_remove.items.len > 0) {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.listeners.getPtr(event)) |listener_list| {
                    var offset: usize = 0;
                    for (to_remove.items) |idx| {
                        _ = listener_list.orderedRemove(idx - offset);
                        offset += 1;
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

            var names = std.ArrayList([]const u8).init(self.allocator);
            var it = self.listeners.keyIterator();
            while (it.next()) |key| {
                names.append(key.*) catch continue;
            }
            return names.toOwnedSlice() catch &[_][]const u8{};
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
    mutex: std.Thread.Mutex,

    const SimpleHandler = *const fn (data: []const u8) void;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .handlers = std.StringHashMap(std.ArrayList(SimpleHandler)).init(allocator),
            .wildcard_handlers = std.ArrayList(WildcardHandler).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.handlers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.handlers.deinit();
        self.wildcard_handlers.deinit();
    }

    /// Register a handler for an event
    pub fn on(self: *Self, event: []const u8, handler: SimpleHandler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = try self.handlers.getOrPut(event);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(SimpleHandler).init(self.allocator);
        }
        try result.value_ptr.append(handler);
    }

    /// Register a wildcard handler
    pub fn onAny(self: *Self, handler: WildcardHandler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.wildcard_handlers.append(handler);
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
        self.mutex.lock();
        const handlers_copy = if (self.handlers.get(event)) |list|
            self.allocator.dupe(SimpleHandler, list.items) catch &[_]SimpleHandler{}
        else
            &[_]SimpleHandler{};
        const wildcard_copy = self.allocator.dupe(WildcardHandler, self.wildcard_handlers.items) catch &[_]WildcardHandler{};
        self.mutex.unlock();

        defer {
            if (handlers_copy.len > 0) self.allocator.free(handlers_copy);
            if (wildcard_copy.len > 0) self.allocator.free(wildcard_copy);
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
    var mutex: std.Thread.Mutex = .{};

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

    var called = false;
    const handler = struct {
        fn h(data: []const u8) void {
            _ = data;
            // In real test, would verify data
        }
    }.h;

    try emitter.on("test", handler);
    emitter.emit("test", "hello");
    _ = called;

    try std.testing.expectEqual(@as(usize, 1), emitter.listenerCount("test"));

    emitter.off("test", handler);
    try std.testing.expectEqual(@as(usize, 0), emitter.listenerCount("test"));
}

test "simple emitter wildcard" {
    const allocator = std.testing.allocator;
    var emitter = SimpleEmitter.init(allocator);
    defer emitter.deinit();

    var event_received: []const u8 = "";
    _ = event_received;

    const wildcard = struct {
        fn h(event: []const u8, data: []const u8) void {
            _ = event;
            _ = data;
        }
    }.h;

    try emitter.onAny(wildcard);
    emitter.emit("any-event", "data");
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
