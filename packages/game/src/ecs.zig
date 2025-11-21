// Home Game Development Framework - Entity Component System
// Archetype-based ECS for high-performance game logic

const std = @import("std");

// ============================================================================
// Entity
// ============================================================================

pub const Entity = struct {
    id: u32,
    generation: u16,

    pub const null_entity = Entity{ .id = 0, .generation = 0 };

    pub fn isValid(self: Entity) bool {
        return self.id != 0;
    }

    pub fn eql(self: Entity, other: Entity) bool {
        return self.id == other.id and self.generation == other.generation;
    }
};

// ============================================================================
// Component Storage
// ============================================================================

pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();

        data: std.ArrayList(T),
        sparse: std.AutoHashMap(u32, usize), // entity id -> dense index
        entities: std.ArrayList(u32), // dense index -> entity id
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .data = .{},
                .sparse = std.AutoHashMap(u32, usize).init(allocator),
                .entities = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit(self.allocator);
            self.sparse.deinit();
            self.entities.deinit(self.allocator);
        }

        pub fn add(self: *Self, entity_id: u32, component: T) !void {
            if (self.sparse.contains(entity_id)) {
                return error.ComponentAlreadyExists;
            }

            const index = self.data.items.len;
            try self.data.append(self.allocator, component);
            try self.sparse.put(entity_id, index);
            try self.entities.append(self.allocator, entity_id);
        }

        pub fn remove(self: *Self, entity_id: u32) !void {
            if (self.sparse.get(entity_id)) |index| {
                // Swap with last element
                const last_index = self.data.items.len - 1;
                if (index != last_index) {
                    const last_entity = self.entities.items[last_index];
                    self.data.items[index] = self.data.items[last_index];
                    self.entities.items[index] = last_entity;
                    self.sparse.put(last_entity, index) catch unreachable;
                }

                _ = self.data.pop();
                _ = self.entities.pop();
                _ = self.sparse.remove(entity_id);
            } else {
                return error.ComponentNotFound;
            }
        }

        pub fn get(self: *Self, entity_id: u32) ?*T {
            if (self.sparse.get(entity_id)) |index| {
                return &self.data.items[index];
            }
            return null;
        }

        pub fn getConst(self: *const Self, entity_id: u32) ?*const T {
            if (self.sparse.get(entity_id)) |index| {
                return &self.data.items[index];
            }
            return null;
        }

        pub fn has(self: *const Self, entity_id: u32) bool {
            return self.sparse.contains(entity_id);
        }

        pub fn count(self: *const Self) usize {
            return self.data.items.len;
        }

        pub fn items(self: *Self) []T {
            return self.data.items;
        }

        pub fn entityIds(self: *Self) []u32 {
            return self.entities.items;
        }
    };
}

// ============================================================================
// Entity Manager
// ============================================================================

pub const EntityManager = struct {
    next_id: u32,
    generations: std.AutoHashMap(u32, u16),
    free_ids: std.ArrayList(u32),
    alive: std.AutoHashMap(u32, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EntityManager {
        return EntityManager{
            .next_id = 1,
            .generations = std.AutoHashMap(u32, u16).init(allocator),
            .free_ids = .{},
            .alive = std.AutoHashMap(u32, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EntityManager) void {
        self.generations.deinit();
        self.free_ids.deinit(self.allocator);
        self.alive.deinit();
    }

    pub fn create(self: *EntityManager) !Entity {
        const id = if (self.free_ids.items.len > 0)
            self.free_ids.pop().?
        else blk: {
            const new_id = self.next_id;
            self.next_id += 1;
            break :blk new_id;
        };

        const generation: u16 = self.generations.get(id) orelse 0;

        try self.alive.put(id, {});
        return Entity{ .id = id, .generation = generation };
    }

    pub fn destroy(self: *EntityManager, entity: Entity) !void {
        if (!self.isAlive(entity)) {
            return error.EntityNotAlive;
        }

        _ = self.alive.remove(entity.id);

        // Increment generation
        const new_gen = entity.generation +% 1;
        try self.generations.put(entity.id, new_gen);
        try self.free_ids.append(self.allocator, entity.id);
    }

    pub fn isAlive(self: *const EntityManager, entity: Entity) bool {
        if (!self.alive.contains(entity.id)) {
            return false;
        }
        const current_gen = self.generations.get(entity.id) orelse 0;
        return current_gen == entity.generation;
    }

    pub fn count(self: *const EntityManager) usize {
        return self.alive.count();
    }
};

// ============================================================================
// World
// ============================================================================

pub fn World(comptime component_types: anytype) type {
    return struct {
        const Self = @This();
        const ComponentTuple = component_types;

        entities: EntityManager,
        allocator: std.mem.Allocator,

        // Generate storage fields for each component type
        storages: StorageStruct(),

        fn StorageStruct() type {
            var fields: []const std.builtin.Type.StructField = &[_]std.builtin.Type.StructField{};
            inline for (std.meta.fields(ComponentTuple)) |field| {
                const T = @field(ComponentTuple, field.name);
                fields = fields ++ &[_]std.builtin.Type.StructField{.{
                    .name = field.name,
                    .type = ComponentStorage(T),
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(ComponentStorage(T)),
                }};
            }
            return @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = false,
                },
            });
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            var storages: StorageStruct() = undefined;
            inline for (std.meta.fields(StorageStruct())) |field| {
                @field(storages, field.name) = field.type.init(allocator);
            }

            return Self{
                .entities = EntityManager.init(allocator),
                .allocator = allocator,
                .storages = storages,
            };
        }

        pub fn deinit(self: *Self) void {
            inline for (std.meta.fields(StorageStruct())) |field| {
                @field(self.storages, field.name).deinit();
            }
            self.entities.deinit();
        }

        pub fn createEntity(self: *Self) !Entity {
            return try self.entities.create();
        }

        pub fn destroyEntity(self: *Self, entity: Entity) !void {
            // Remove all components
            inline for (std.meta.fields(StorageStruct())) |field| {
                @field(self.storages, field.name).remove(entity.id) catch {};
            }
            try self.entities.destroy(entity);
        }

        pub fn addComponent(self: *Self, entity: Entity, comptime name: []const u8, component: anytype) !void {
            if (!self.entities.isAlive(entity)) {
                return error.EntityNotAlive;
            }
            try @field(self.storages, name).add(entity.id, component);
        }

        pub fn removeComponent(self: *Self, entity: Entity, comptime name: []const u8) !void {
            if (!self.entities.isAlive(entity)) {
                return error.EntityNotAlive;
            }
            try @field(self.storages, name).remove(entity.id);
        }

        pub fn getComponent(self: *Self, entity: Entity, comptime name: []const u8) ?*@TypeOf(@field(self.storages, name)).data.items[0] {
            if (!self.entities.isAlive(entity)) {
                return null;
            }
            return @field(self.storages, name).get(entity.id);
        }

        pub fn hasComponent(self: *const Self, entity: Entity, comptime name: []const u8) bool {
            if (!self.entities.isAlive(entity)) {
                return false;
            }
            return @field(self.storages, name).has(entity.id);
        }

        pub fn entityCount(self: *const Self) usize {
            return self.entities.count();
        }
    };
}

// ============================================================================
// Simple World (without comptime component registration)
// ============================================================================

pub const SimpleWorld = struct {
    entities: EntityManager,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SimpleWorld {
        return SimpleWorld{
            .entities = EntityManager.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SimpleWorld) void {
        self.entities.deinit();
    }

    pub fn createEntity(self: *SimpleWorld) !Entity {
        return try self.entities.create();
    }

    pub fn destroyEntity(self: *SimpleWorld, entity: Entity) !void {
        try self.entities.destroy(entity);
    }

    pub fn isAlive(self: *const SimpleWorld, entity: Entity) bool {
        return self.entities.isAlive(entity);
    }

    pub fn entityCount(self: *const SimpleWorld) usize {
        return self.entities.count();
    }
};

// ============================================================================
// System Interface
// ============================================================================

pub fn System(comptime Context: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        update_fn: *const fn (*Context, f64) void,
        priority: i32,
        enabled: bool,

        pub fn init(name: []const u8, update_fn: *const fn (*Context, f64) void) Self {
            return Self{
                .name = name,
                .update_fn = update_fn,
                .priority = 0,
                .enabled = true,
            };
        }

        pub fn update(self: *const Self, context: *Context, dt: f64) void {
            if (self.enabled) {
                self.update_fn(context, dt);
            }
        }
    };
}

pub fn SystemScheduler(comptime Context: type) type {
    return struct {
        const Self = @This();
        const SystemType = System(Context);

        systems: std.ArrayList(SystemType),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .systems = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.systems.deinit(self.allocator);
        }

        pub fn addSystem(self: *Self, system: SystemType) !void {
            try self.systems.append(self.allocator, system);
            // Sort by priority
            std.mem.sort(SystemType, self.systems.items, {}, struct {
                fn lessThan(_: void, a: SystemType, b: SystemType) bool {
                    return a.priority < b.priority;
                }
            }.lessThan);
        }

        pub fn update(self: *Self, context: *Context, dt: f64) void {
            for (self.systems.items) |*system| {
                system.update(context, dt);
            }
        }

        pub fn enableSystem(self: *Self, name: []const u8) void {
            for (self.systems.items) |*system| {
                if (std.mem.eql(u8, system.name, name)) {
                    system.enabled = true;
                    return;
                }
            }
        }

        pub fn disableSystem(self: *Self, name: []const u8) void {
            for (self.systems.items) |*system| {
                if (std.mem.eql(u8, system.name, name)) {
                    system.enabled = false;
                    return;
                }
            }
        }
    };
}

// ============================================================================
// Query Helper
// ============================================================================

pub fn QueryIterator(comptime Storage1: type, comptime Storage2: type) type {
    return struct {
        const Self = @This();

        storage1: *Storage1,
        storage2: *Storage2,
        index: usize,

        pub fn init(storage1: *Storage1, storage2: *Storage2) Self {
            return Self{
                .storage1 = storage1,
                .storage2 = storage2,
                .index = 0,
            };
        }

        pub fn next(self: *Self) ?struct { entity_id: u32, c1: *@TypeOf(self.storage1.data.items[0]), c2: *@TypeOf(self.storage2.data.items[0]) } {
            while (self.index < self.storage1.entities.items.len) {
                const entity_id = self.storage1.entities.items[self.index];
                self.index += 1;

                if (self.storage2.get(entity_id)) |c2| {
                    return .{
                        .entity_id = entity_id,
                        .c1 = &self.storage1.data.items[self.index - 1],
                        .c2 = c2,
                    };
                }
            }
            return null;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Entity validity" {
    const e1 = Entity{ .id = 1, .generation = 0 };
    const e2 = Entity.null_entity;

    try std.testing.expect(e1.isValid());
    try std.testing.expect(!e2.isValid());
}

test "ComponentStorage" {
    const Position = struct { x: f32, y: f32 };

    var storage = ComponentStorage(Position).init(std.testing.allocator);
    defer storage.deinit();

    try storage.add(1, .{ .x = 10, .y = 20 });
    try std.testing.expectEqual(@as(usize, 1), storage.count());

    const pos = storage.get(1);
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(@as(f32, 10), pos.?.x);

    try storage.remove(1);
    try std.testing.expectEqual(@as(usize, 0), storage.count());
}

test "EntityManager" {
    var em = EntityManager.init(std.testing.allocator);
    defer em.deinit();

    const e1 = try em.create();
    const e2 = try em.create();

    try std.testing.expect(em.isAlive(e1));
    try std.testing.expect(em.isAlive(e2));
    try std.testing.expectEqual(@as(usize, 2), em.count());

    try em.destroy(e1);
    try std.testing.expect(!em.isAlive(e1));
    try std.testing.expectEqual(@as(usize, 1), em.count());
}

test "SimpleWorld" {
    var world = SimpleWorld.init(std.testing.allocator);
    defer world.deinit();

    const e1 = try world.createEntity();
    try std.testing.expect(world.isAlive(e1));

    try world.destroyEntity(e1);
    try std.testing.expect(!world.isAlive(e1));
}

test "SystemScheduler" {
    const Context = struct {
        value: i32 = 0,
    };

    var ctx = Context{};
    var scheduler = SystemScheduler(Context).init(std.testing.allocator);
    defer scheduler.deinit();

    try scheduler.addSystem(System(Context).init("test", struct {
        fn update(c: *Context, _: f64) void {
            c.value += 1;
        }
    }.update));

    scheduler.update(&ctx, 0.016);
    try std.testing.expectEqual(@as(i32, 1), ctx.value);
}
