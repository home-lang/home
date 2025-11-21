// Home Game Development Framework - AI System
// Behavior trees, state machines, utility AI, and steering behaviors

const std = @import("std");

// ============================================================================
// Behavior Tree
// ============================================================================

pub const NodeStatus = enum {
    success,
    failure,
    running,
};

pub const BehaviorNode = struct {
    pub const VTable = struct {
        tick: *const fn (*BehaviorNode, *anyopaque) NodeStatus,
        reset: *const fn (*BehaviorNode) void,
    };

    vtable: *const VTable,
    name: []const u8,

    pub fn tick(self: *BehaviorNode, context: *anyopaque) NodeStatus {
        return self.vtable.tick(self, context);
    }

    pub fn reset(self: *BehaviorNode) void {
        self.vtable.reset(self);
    }
};

/// Sequence node - runs children in order until one fails
pub fn Sequence(comptime max_children: usize) type {
    return struct {
        const Self = @This();

        base: BehaviorNode,
        children: [max_children]?*BehaviorNode,
        child_count: usize,
        current_child: usize,

        const vtable = BehaviorNode.VTable{
            .tick = tick,
            .reset = resetNode,
        };

        pub fn init(name: []const u8) Self {
            return Self{
                .base = .{ .vtable = &vtable, .name = name },
                .children = [_]?*BehaviorNode{null} ** max_children,
                .child_count = 0,
                .current_child = 0,
            };
        }

        pub fn addChild(self: *Self, child: *BehaviorNode) !void {
            if (self.child_count >= max_children) return error.TooManyChildren;
            self.children[self.child_count] = child;
            self.child_count += 1;
        }

        fn tick(node: *BehaviorNode, context: *anyopaque) NodeStatus {
            const self: *Self = @fieldParentPtr("base", node);

            while (self.current_child < self.child_count) {
                if (self.children[self.current_child]) |child| {
                    const status = child.tick(context);
                    switch (status) {
                        .running => return .running,
                        .failure => {
                            self.current_child = 0;
                            return .failure;
                        },
                        .success => self.current_child += 1,
                    }
                } else {
                    self.current_child += 1;
                }
            }

            self.current_child = 0;
            return .success;
        }

        fn resetNode(node: *BehaviorNode) void {
            const self: *Self = @fieldParentPtr("base", node);
            self.current_child = 0;
            for (self.children[0..self.child_count]) |maybe_child| {
                if (maybe_child) |child| {
                    child.reset();
                }
            }
        }
    };
}

/// Selector node - runs children until one succeeds
pub fn Selector(comptime max_children: usize) type {
    return struct {
        const Self = @This();

        base: BehaviorNode,
        children: [max_children]?*BehaviorNode,
        child_count: usize,
        current_child: usize,

        const vtable = BehaviorNode.VTable{
            .tick = tick,
            .reset = resetNode,
        };

        pub fn init(name: []const u8) Self {
            return Self{
                .base = .{ .vtable = &vtable, .name = name },
                .children = [_]?*BehaviorNode{null} ** max_children,
                .child_count = 0,
                .current_child = 0,
            };
        }

        pub fn addChild(self: *Self, child: *BehaviorNode) !void {
            if (self.child_count >= max_children) return error.TooManyChildren;
            self.children[self.child_count] = child;
            self.child_count += 1;
        }

        fn tick(node: *BehaviorNode, context: *anyopaque) NodeStatus {
            const self: *Self = @fieldParentPtr("base", node);

            while (self.current_child < self.child_count) {
                if (self.children[self.current_child]) |child| {
                    const status = child.tick(context);
                    switch (status) {
                        .running => return .running,
                        .success => {
                            self.current_child = 0;
                            return .success;
                        },
                        .failure => self.current_child += 1,
                    }
                } else {
                    self.current_child += 1;
                }
            }

            self.current_child = 0;
            return .failure;
        }

        fn resetNode(node: *BehaviorNode) void {
            const self: *Self = @fieldParentPtr("base", node);
            self.current_child = 0;
            for (self.children[0..self.child_count]) |maybe_child| {
                if (maybe_child) |child| {
                    child.reset();
                }
            }
        }
    };
}

// ============================================================================
// Finite State Machine
// ============================================================================

pub fn StateMachine(comptime StateEnum: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const StateHandler = struct {
            enter: ?*const fn (*Context) void = null,
            update: ?*const fn (*Context, f64) void = null,
            exit: ?*const fn (*Context) void = null,
        };

        current_state: StateEnum,
        previous_state: ?StateEnum,
        handlers: std.EnumArray(StateEnum, StateHandler),
        context: *Context,
        state_time: f64,

        pub fn init(initial_state: StateEnum, context: *Context) Self {
            return Self{
                .current_state = initial_state,
                .previous_state = null,
                .handlers = std.EnumArray(StateEnum, StateHandler).initFill(.{}),
                .context = context,
                .state_time = 0,
            };
        }

        pub fn setHandler(self: *Self, state: StateEnum, handler: StateHandler) void {
            self.handlers.set(state, handler);
        }

        pub fn transition(self: *Self, new_state: StateEnum) void {
            if (self.current_state == new_state) return;

            // Exit current state
            const current_handler = self.handlers.get(self.current_state);
            if (current_handler.exit) |exit_fn| {
                exit_fn(self.context);
            }

            // Change state
            self.previous_state = self.current_state;
            self.current_state = new_state;
            self.state_time = 0;

            // Enter new state
            const new_handler = self.handlers.get(new_state);
            if (new_handler.enter) |enter_fn| {
                enter_fn(self.context);
            }
        }

        pub fn update(self: *Self, dt: f64) void {
            self.state_time += dt;

            const handler = self.handlers.get(self.current_state);
            if (handler.update) |update_fn| {
                update_fn(self.context, dt);
            }
        }

        pub fn getState(self: *const Self) StateEnum {
            return self.current_state;
        }

        pub fn getStateTime(self: *const Self) f64 {
            return self.state_time;
        }
    };
}

// ============================================================================
// Utility AI
// ============================================================================

pub fn UtilityAI(comptime ActionEnum: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Consideration = struct {
            evaluate: *const fn (*const Context) f32,
            weight: f32 = 1.0,
        };

        pub const Action = struct {
            considerations: std.ArrayList(Consideration),
            execute: *const fn (*Context) void,
            name: []const u8,

            pub fn getScore(self: *const Action, context: *const Context) f32 {
                if (self.considerations.items.len == 0) return 0;

                var total: f32 = 1.0;
                for (self.considerations.items) |consideration| {
                    const score = consideration.evaluate(context);
                    total *= score * consideration.weight;
                }

                // Compensation factor for multiple considerations
                const mod_factor = 1.0 - (1.0 / @as(f32, @floatFromInt(self.considerations.items.len)));
                const make_up = (1.0 - total) * mod_factor;
                return total + (make_up * total);
            }
        };

        actions: std.EnumArray(ActionEnum, ?Action),
        context: *Context,
        current_action: ?ActionEnum,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, context: *Context) Self {
            return Self{
                .actions = std.EnumArray(ActionEnum, ?Action).initFill(null),
                .context = context,
                .current_action = null,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var iter = self.actions.iterator();
            while (iter.next()) |entry| {
                if (entry.value.*) |*action| {
                    action.considerations.deinit();
                }
            }
        }

        pub fn registerAction(
            self: *Self,
            action_enum: ActionEnum,
            name: []const u8,
            execute: *const fn (*Context) void,
        ) !*Action {
            const action = Action{
                .considerations = std.ArrayList(Consideration).init(self.allocator),
                .execute = execute,
                .name = name,
            };
            self.actions.set(action_enum, action);
            return &self.actions.getPtr(action_enum).*.?;
        }

        pub fn addConsideration(self: *Self, action_enum: ActionEnum, consideration: Consideration) !void {
            if (self.actions.getPtr(action_enum).*) |*action| {
                try action.considerations.append(consideration);
            }
        }

        pub fn selectAction(self: *Self) ?ActionEnum {
            var best_action: ?ActionEnum = null;
            var best_score: f32 = 0;

            var iter = self.actions.iterator();
            while (iter.next()) |entry| {
                if (entry.value.*) |*action| {
                    const score = action.getScore(self.context);
                    if (score > best_score) {
                        best_score = score;
                        best_action = entry.key;
                    }
                }
            }

            self.current_action = best_action;
            return best_action;
        }

        pub fn executeSelected(self: *Self) void {
            if (self.current_action) |action_enum| {
                if (self.actions.get(action_enum)) |action| {
                    action.execute(self.context);
                }
            }
        }
    };
}

// ============================================================================
// Steering Behaviors
// ============================================================================

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: Vec2, s: f32) Vec2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn length(self: Vec2) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn normalize(self: Vec2) Vec2 {
        const len = self.length();
        if (len == 0) return self;
        return .{ .x = self.x / len, .y = self.y / len };
    }

    pub fn truncate(self: Vec2, max_len: f32) Vec2 {
        const len = self.length();
        if (len > max_len) {
            return self.normalize().scale(max_len);
        }
        return self;
    }

    pub fn distance(self: Vec2, other: Vec2) f32 {
        return self.sub(other).length();
    }
};

pub const SteeringAgent = struct {
    position: Vec2 = .{},
    velocity: Vec2 = .{},
    max_speed: f32 = 100,
    max_force: f32 = 50,
    mass: f32 = 1,
    wander_angle: f32 = 0,

    pub fn applyForce(self: *SteeringAgent, force: Vec2, dt: f32) void {
        const acceleration = force.scale(1.0 / self.mass);
        self.velocity = self.velocity.add(acceleration.scale(dt)).truncate(self.max_speed);
        self.position = self.position.add(self.velocity.scale(dt));
    }

    pub fn seek(self: *const SteeringAgent, target: Vec2) Vec2 {
        const desired = target.sub(self.position).normalize().scale(self.max_speed);
        return desired.sub(self.velocity).truncate(self.max_force);
    }

    pub fn flee(self: *const SteeringAgent, target: Vec2) Vec2 {
        const desired = self.position.sub(target).normalize().scale(self.max_speed);
        return desired.sub(self.velocity).truncate(self.max_force);
    }

    pub fn arrive(self: *const SteeringAgent, target: Vec2, slowing_radius: f32) Vec2 {
        const offset = target.sub(self.position);
        const dist = offset.length();

        if (dist < 0.001) return .{};

        const ramped_speed = self.max_speed * (dist / slowing_radius);
        const clipped_speed = @min(ramped_speed, self.max_speed);
        const desired = offset.scale(clipped_speed / dist);

        return desired.sub(self.velocity).truncate(self.max_force);
    }

    pub fn pursue(self: *const SteeringAgent, target: *const SteeringAgent) Vec2 {
        const dist = self.position.distance(target.position);
        const prediction_time = dist / self.max_speed;
        const future_pos = target.position.add(target.velocity.scale(prediction_time));
        return self.seek(future_pos);
    }

    pub fn evade(self: *const SteeringAgent, target: *const SteeringAgent) Vec2 {
        const dist = self.position.distance(target.position);
        const prediction_time = dist / self.max_speed;
        const future_pos = target.position.add(target.velocity.scale(prediction_time));
        return self.flee(future_pos);
    }

    pub fn wander(self: *SteeringAgent, circle_distance: f32, circle_radius: f32, angle_change: f32) Vec2 {
        // Get circle center
        var circle_center = self.velocity.normalize().scale(circle_distance);

        // Calculate displacement
        const displacement = Vec2{
            .x = @cos(self.wander_angle) * circle_radius,
            .y = @sin(self.wander_angle) * circle_radius,
        };

        // Change wander angle slightly
        self.wander_angle += (std.crypto.random.float(f32) - 0.5) * angle_change;

        // Calculate wander force
        circle_center = circle_center.add(displacement);
        return circle_center.truncate(self.max_force);
    }

    pub fn separate(self: *const SteeringAgent, neighbors: []const *SteeringAgent, desired_separation: f32) Vec2 {
        var steer = Vec2{};
        var count: f32 = 0;

        for (neighbors) |other| {
            const dist = self.position.distance(other.position);
            if (dist > 0 and dist < desired_separation) {
                const diff = self.position.sub(other.position).normalize().scale(1.0 / dist);
                steer = steer.add(diff);
                count += 1;
            }
        }

        if (count > 0) {
            steer = steer.scale(1.0 / count);
        }

        if (steer.length() > 0) {
            steer = steer.normalize().scale(self.max_speed).sub(self.velocity);
            steer = steer.truncate(self.max_force);
        }

        return steer;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "StateMachine transitions" {
    const States = enum { idle, walking, running };
    const Ctx = struct { speed: f32 = 0 };

    var ctx = Ctx{};
    var fsm = StateMachine(States, Ctx).init(.idle, &ctx);

    try std.testing.expectEqual(States.idle, fsm.getState());

    fsm.transition(.walking);
    try std.testing.expectEqual(States.walking, fsm.getState());
    try std.testing.expectEqual(States.idle, fsm.previous_state.?);
}

test "SteeringAgent seek" {
    var agent = SteeringAgent{ .position = .{ .x = 0, .y = 0 } };
    const target = Vec2{ .x = 100, .y = 0 };

    const force = agent.seek(target);
    try std.testing.expect(force.x > 0);
}

test "Vec2 operations" {
    const v1 = Vec2{ .x = 3, .y = 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 5), v1.length(), 0.001);

    const normalized = v1.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 1), normalized.length(), 0.001);
}
