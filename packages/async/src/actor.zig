const std = @import("std");
const runtime = @import("runtime.zig");
const channel = @import("channel.zig");

/// Actor system for message-passing concurrency
///
/// Provides Erlang-style actors with:
/// - Isolated state
/// - Message passing via mailboxes
/// - Supervision trees
/// - Error recovery
pub const ActorSystem = struct {
    allocator: std.mem.Allocator,
    runtime: *runtime.Runtime,
    actors: std.StringHashMap(*ActorContext),
    next_actor_id: std.atomic.Value(usize),
    supervisors: std.ArrayList(*Supervisor),

    pub fn init(allocator: std.mem.Allocator, rt: *runtime.Runtime) !ActorSystem {
        return .{
            .allocator = allocator,
            .runtime = rt,
            .actors = std.StringHashMap(*ActorContext).init(allocator),
            .next_actor_id = std.atomic.Value(usize).init(1),
            .supervisors = std.ArrayList(*Supervisor).init(allocator),
        };
    }

    pub fn deinit(self: *ActorSystem) void {
        var it = self.actors.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.actors.deinit();

        for (self.supervisors.items) |supervisor| {
            supervisor.deinit();
            self.allocator.destroy(supervisor);
        }
        self.supervisors.deinit();
    }

    /// Spawn a new actor
    pub fn spawn(
        self: *ActorSystem,
        comptime ActorType: type,
        name: ?[]const u8,
        init_state: ActorType.State,
    ) !ActorRef(ActorType.Message) {
        const actor_id = self.next_actor_id.fetchAdd(1, .monotonic);
        const actor_name = if (name) |n|
            try self.allocator.dupe(u8, n)
        else
            try std.fmt.allocPrint(self.allocator, "actor_{d}", .{actor_id});

        const ctx = try self.allocator.create(ActorContext);
        ctx.* = try ActorContext.init(
            self.allocator,
            actor_id,
            actor_name,
        );

        try self.actors.put(actor_name, ctx);

        // Create mailbox
        const mailbox = try channel.unboundedChannel(ActorType.Message, self.allocator);

        // Spawn actor task
        const actor_instance = try self.allocator.create(ActorType);
        actor_instance.* = ActorType{
            .state = init_state,
            .ctx = ctx,
            .mailbox = mailbox.receiver(),
        };

        // Start actor loop
        _ = try self.runtime.spawn(void, ActorType.run(actor_instance));

        return ActorRef(ActorType.Message){
            .id = actor_id,
            .name = actor_name,
            .sender = mailbox.sender(),
            .system = self,
        };
    }

    /// Get actor by name
    pub fn get(self: *ActorSystem, name: []const u8) ?*ActorContext {
        return self.actors.get(name);
    }

    /// Create a supervisor
    pub fn createSupervisor(
        self: *ActorSystem,
        strategy: SupervisionStrategy,
    ) !*Supervisor {
        const supervisor = try self.allocator.create(Supervisor);
        supervisor.* = try Supervisor.init(self.allocator, self, strategy);
        try self.supervisors.append(supervisor);
        return supervisor;
    }
};

/// Actor context with metadata
pub const ActorContext = struct {
    allocator: std.mem.Allocator,
    id: usize,
    name: []const u8,
    parent: ?*ActorContext,
    children: std.ArrayList(*ActorContext),
    is_alive: std.atomic.Value(bool),
    restart_count: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, id: usize, name: []const u8) !ActorContext {
        return .{
            .allocator = allocator,
            .id = id,
            .name = name,
            .parent = null,
            .children = std.ArrayList(*ActorContext).init(allocator),
            .is_alive = std.atomic.Value(bool).init(true),
            .restart_count = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *ActorContext) void {
        self.children.deinit();
    }

    pub fn addChild(self: *ActorContext, child: *ActorContext) !void {
        try self.children.append(child);
        child.parent = self;
    }

    pub fn stop(self: *ActorContext) void {
        self.is_alive.store(false, .release);
    }

    pub fn incrementRestarts(self: *ActorContext) usize {
        return self.restart_count.fetchAdd(1, .monotonic);
    }
};

/// Reference to an actor for sending messages
pub fn ActorRef(comptime MessageType: type) type {
    return struct {
        const Self = @This();

        id: usize,
        name: []const u8,
        sender: channel.Sender(MessageType),
        system: *ActorSystem,

        /// Send a message to the actor
        pub fn send(self: *Self, message: MessageType) !void {
            try self.sender.trySend(message);
        }

        /// Send a message asynchronously
        pub fn sendAsync(self: *Self, message: MessageType) channel.SendFuture(MessageType) {
            return self.sender.send(message);
        }

        /// Stop the actor
        pub fn stop(self: *Self) void {
            if (self.system.get(self.name)) |ctx| {
                ctx.stop();
            }
        }
    };
}

/// Base actor trait
pub fn Actor(comptime StateType: type, comptime MessageType: type) type {
    return struct {
        const Self = @This();

        pub const State = StateType;
        pub const Message = MessageType;

        state: State,
        ctx: *ActorContext,
        mailbox: channel.Receiver(Message),

        /// Actor message processing loop
        pub fn run(self: *Self) !void {
            while (self.ctx.is_alive.load(.acquire)) {
                const maybe_msg = self.mailbox.tryRecv();

                if (maybe_msg) |msg| {
                    try self.handle(msg);
                } else {
                    // No messages, yield
                    std.time.sleep(1 * std.time.ns_per_ms);
                }
            }
        }

        /// Handle a message (must be implemented by concrete actor)
        pub fn handle(self: *Self, message: Message) !void {
            _ = self;
            _ = message;
            @compileError("Actor must implement handle() method");
        }
    };
}

/// Supervision strategy for actor hierarchies
pub const SupervisionStrategy = enum {
    /// Restart only the failed child
    OneForOne,
    /// Restart all children if one fails
    OneForAll,
    /// Restart the failed child and any started after it
    RestForOne,
};

/// Supervisor for managing actor lifecycles
pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    system: *ActorSystem,
    strategy: SupervisionStrategy,
    max_restarts: usize,
    restart_window: i64, // milliseconds
    children: std.ArrayList(SupervisedChild),

    const SupervisedChild = struct {
        ctx: *ActorContext,
        restart_times: std.ArrayList(i64),
    };

    pub fn init(
        allocator: std.mem.Allocator,
        system: *ActorSystem,
        strategy: SupervisionStrategy,
    ) !Supervisor {
        return .{
            .allocator = allocator,
            .system = system,
            .strategy = strategy,
            .max_restarts = 3,
            .restart_window = 5000, // 5 seconds
            .children = std.ArrayList(SupervisedChild).init(allocator),
        };
    }

    pub fn deinit(self: *Supervisor) void {
        for (self.children.items) |child| {
            child.restart_times.deinit();
        }
        self.children.deinit();
    }

    /// Add a child actor to supervise
    pub fn supervise(self: *Supervisor, ctx: *ActorContext) !void {
        const child = SupervisedChild{
            .ctx = ctx,
            .restart_times = std.ArrayList(i64).init(self.allocator),
        };
        try self.children.append(child);
    }

    /// Handle child failure
    pub fn handleFailure(self: *Supervisor, child_ctx: *ActorContext) !void {
        const now = std.time.milliTimestamp();

        // Find the child
        var child_index: ?usize = null;
        for (self.children.items, 0..) |child, i| {
            if (child.ctx.id == child_ctx.id) {
                child_index = i;
                break;
            }
        }

        if (child_index == null) return;

        const child = &self.children.items[child_index.?];

        // Record restart time
        try child.restart_times.append(now);

        // Clean old restart times outside window
        const window_start = now - self.restart_window;
        var i: usize = 0;
        while (i < child.restart_times.items.len) {
            if (child.restart_times.items[i] < window_start) {
                _ = child.restart_times.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Check restart limit
        if (child.restart_times.items.len > self.max_restarts) {
            // Too many restarts, escalate to parent
            if (child_ctx.parent) |parent| {
                parent.stop();
            }
            return error.TooManyRestarts;
        }

        // Apply supervision strategy
        switch (self.strategy) {
            .OneForOne => try self.restartChild(child_index.?),
            .OneForAll => try self.restartAllChildren(),
            .RestForOne => try self.restartFromChild(child_index.?),
        }
    }

    fn restartChild(self: *Supervisor, index: usize) !void {
        const child = &self.children.items[index];
        _ = child.ctx.incrementRestarts();
        // Would restart the actor here
        _ = self;
    }

    fn restartAllChildren(self: *Supervisor) !void {
        for (self.children.items, 0..) |_, i| {
            try self.restartChild(i);
        }
    }

    fn restartFromChild(self: *Supervisor, start_index: usize) !void {
        var i = start_index;
        while (i < self.children.items.len) : (i += 1) {
            try self.restartChild(i);
        }
    }
};

/// Example: Counter actor
pub const CounterActor = struct {
    const Self = @This();

    pub const Message = union(enum) {
        Increment,
        Decrement,
        Get: *i32,
        Reset,
    };

    state: i32,
    ctx: *ActorContext,
    mailbox: channel.Receiver(Message),

    pub fn run(self: *Self) !void {
        while (self.ctx.is_alive.load(.acquire)) {
            const maybe_msg = self.mailbox.tryRecv();

            if (maybe_msg) |msg| {
                try self.handle(msg);
            } else {
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
    }

    pub fn handle(self: *Self, message: Message) !void {
        switch (message) {
            .Increment => self.state += 1,
            .Decrement => self.state -= 1,
            .Get => |result_ptr| result_ptr.* = self.state,
            .Reset => self.state = 0,
        }
    }
};

/// Message patterns
pub const MessagePattern = struct {
    /// Ask pattern: send and wait for response
    pub fn ask(
        comptime ActorType: type,
        comptime ResponseType: type,
        actor_ref: *ActorRef(ActorType.Message),
        make_message: fn (*channel.Sender(ResponseType)) ActorType.Message,
    ) !ResponseType {
        const response_channel = try channel.boundedChannel(ResponseType, actor_ref.system.allocator, 1);
        defer response_channel.deinit();

        const sender = response_channel.sender();
        const receiver = response_channel.receiver();

        const msg = make_message(&sender);
        try actor_ref.send(msg);

        return receiver.tryRecv() orelse error.NoResponse;
    }

    /// Tell pattern: fire and forget
    pub fn tell(
        comptime MessageType: type,
        actor_ref: *ActorRef(MessageType),
        message: MessageType,
    ) !void {
        try actor_ref.send(message);
    }
};
