// Particle system for C&C Generals Zero Hour
// Part of Home stdlib - Graphics backend
// 3D particle effects (explosions, smoke, fire, weather)

const std = @import("std");
const Allocator = std.mem.Allocator;

// Particle emitter types
pub const EmitterType = enum {
    Point,      // Emits from a point
    Sphere,     // Emits from sphere surface
    Box,        // Emits from box volume
    Cone,       // Emits in cone shape
    Line,       // Emits along line
};

// Particle types
pub const ParticleType = enum {
    Billboard,   // Always faces camera
    Oriented,    // Has fixed orientation
    Streak,      // Motion blur trail
    Mesh,        // 3D mesh particle
};

// Blend modes for particles
pub const ParticleBlend = enum {
    Alpha,
    Additive,
    Modulate,
};

// Single particle
pub const Particle = struct {
    position: [3]f32,
    velocity: [3]f32,
    color: [4]f32,
    size: f32,
    rotation: f32,
    lifetime: f32,
    age: f32,
    is_alive: bool,

    pub fn init() Particle {
        return .{
            .position = [3]f32{ 0.0, 0.0, 0.0 },
            .velocity = [3]f32{ 0.0, 0.0, 0.0 },
            .color = [4]f32{ 1.0, 1.0, 1.0, 1.0 },
            .size = 1.0,
            .rotation = 0.0,
            .lifetime = 1.0,
            .age = 0.0,
            .is_alive = true,
        };
    }

    pub fn update(self: *Particle, delta_time: f32, gravity: [3]f32) void {
        if (!self.is_alive) return;

        self.age += delta_time;

        if (self.age >= self.lifetime) {
            self.is_alive = false;
            return;
        }

        // Update position
        self.position[0] += self.velocity[0] * delta_time;
        self.position[1] += self.velocity[1] * delta_time;
        self.position[2] += self.velocity[2] * delta_time;

        // Apply gravity
        self.velocity[0] += gravity[0] * delta_time;
        self.velocity[1] += gravity[1] * delta_time;
        self.velocity[2] += gravity[2] * delta_time;

        // Fade out based on lifetime
        const life_ratio = self.age / self.lifetime;
        self.color[3] = 1.0 - life_ratio;
    }
};

// Particle emitter configuration
pub const EmitterConfig = struct {
    emitter_type: EmitterType,
    particle_type: ParticleType,
    blend_mode: ParticleBlend,

    // Emission
    emission_rate: f32,      // Particles per second
    max_particles: u32,
    burst_count: u32,        // Particles per burst

    // Particle properties
    lifetime_min: f32,
    lifetime_max: f32,
    size_min: f32,
    size_max: f32,
    speed_min: f32,
    speed_max: f32,

    // Colors
    color_start: [4]f32,
    color_end: [4]f32,

    // Physics
    gravity: [3]f32,
    drag: f32,

    // Emitter shape
    radius: f32,             // For sphere/cone
    cone_angle: f32,         // For cone
    box_size: [3]f32,        // For box

    pub fn init() EmitterConfig {
        return .{
            .emitter_type = .Point,
            .particle_type = .Billboard,
            .blend_mode = .Alpha,
            .emission_rate = 10.0,
            .max_particles = 100,
            .burst_count = 0,
            .lifetime_min = 1.0,
            .lifetime_max = 2.0,
            .size_min = 1.0,
            .size_max = 2.0,
            .speed_min = 10.0,
            .speed_max = 20.0,
            .color_start = [4]f32{ 1.0, 1.0, 1.0, 1.0 },
            .color_end = [4]f32{ 1.0, 1.0, 1.0, 0.0 },
            .gravity = [3]f32{ 0.0, -9.8, 0.0 },
            .drag = 0.0,
            .radius = 1.0,
            .cone_angle = 45.0,
            .box_size = [3]f32{ 1.0, 1.0, 1.0 },
        };
    }
};

// Particle emitter
pub const ParticleEmitter = struct {
    allocator: Allocator,
    config: EmitterConfig,
    particles: []Particle,
    particle_count: u32,
    position: [3]f32,
    is_active: bool,
    emission_accumulator: f32,
    prng: std.rand.DefaultPrng,

    pub fn init(allocator: Allocator, config: EmitterConfig) !ParticleEmitter {
        const particles = try allocator.alloc(Particle, config.max_particles);
        for (particles) |*p| {
            p.* = Particle.init();
            p.is_alive = false;
        }

        var prng = std.rand.DefaultPrng.init(0);

        return .{
            .allocator = allocator,
            .config = config,
            .particles = particles,
            .particle_count = 0,
            .position = [3]f32{ 0.0, 0.0, 0.0 },
            .is_active = true,
            .emission_accumulator = 0.0,
            .prng = prng,
        };
    }

    pub fn deinit(self: *ParticleEmitter) void {
        self.allocator.free(self.particles);
    }

    pub fn update(self: *ParticleEmitter, delta_time: f32) void {
        if (!self.is_active) return;

        // Update existing particles
        for (self.particles) |*particle| {
            if (particle.is_alive) {
                particle.update(delta_time, self.config.gravity);
            }
        }

        // Emit new particles
        self.emission_accumulator += delta_time * self.config.emission_rate;

        while (self.emission_accumulator >= 1.0) {
            self.emitParticle();
            self.emission_accumulator -= 1.0;
        }
    }

    fn emitParticle(self: *ParticleEmitter) void {
        // Find dead particle to reuse
        for (self.particles) |*particle| {
            if (!particle.is_alive) {
                self.spawnParticle(particle);
                return;
            }
        }
    }

    fn spawnParticle(self: *ParticleEmitter, particle: *Particle) void {
        const rand = self.prng.random();

        // Position based on emitter type
        particle.position = switch (self.config.emitter_type) {
            .Point => self.position,
            .Sphere => self.randomSpherePoint(rand),
            .Box => self.randomBoxPoint(rand),
            .Cone => self.randomConePoint(rand),
            .Line => self.randomLinePoint(rand),
        };

        // Random velocity
        const speed = self.config.speed_min + rand.float(f32) * (self.config.speed_max - self.config.speed_min);
        const direction = self.randomDirection(rand);

        particle.velocity = [3]f32{
            direction[0] * speed,
            direction[1] * speed,
            direction[2] * speed,
        };

        // Random properties
        particle.lifetime = self.config.lifetime_min + rand.float(f32) * (self.config.lifetime_max - self.config.lifetime_min);
        particle.size = self.config.size_min + rand.float(f32) * (self.config.size_max - self.config.size_min);
        particle.color = self.config.color_start;
        particle.rotation = rand.float(f32) * std.math.pi * 2.0;
        particle.age = 0.0;
        particle.is_alive = true;
    }

    fn randomSpherePoint(self: *ParticleEmitter, rand: std.rand.Random) [3]f32 {
        const theta = rand.float(f32) * std.math.pi * 2.0;
        const phi = std.math.acos(2.0 * rand.float(f32) - 1.0);

        return [3]f32{
            self.position[0] + self.config.radius * @sin(phi) * @cos(theta),
            self.position[1] + self.config.radius * @sin(phi) * @sin(theta),
            self.position[2] + self.config.radius * @cos(phi),
        };
    }

    fn randomBoxPoint(self: *ParticleEmitter, rand: std.rand.Random) [3]f32 {
        return [3]f32{
            self.position[0] + (rand.float(f32) - 0.5) * self.config.box_size[0],
            self.position[1] + (rand.float(f32) - 0.5) * self.config.box_size[1],
            self.position[2] + (rand.float(f32) - 0.5) * self.config.box_size[2],
        };
    }

    fn randomConePoint(self: *ParticleEmitter, rand: std.rand.Random) [3]f32 {
        _ = rand;
        return self.position;
    }

    fn randomLinePoint(self: *ParticleEmitter, rand: std.rand.Random) [3]f32 {
        const t = rand.float(f32);
        return [3]f32{
            self.position[0],
            self.position[1] + t * 10.0,
            self.position[2],
        };
    }

    fn randomDirection(self: *ParticleEmitter, rand: std.rand.Random) [3]f32 {
        _ = self;
        const theta = rand.float(f32) * std.math.pi * 2.0;
        const phi = std.math.acos(2.0 * rand.float(f32) - 1.0);

        return [3]f32{
            @sin(phi) * @cos(theta),
            @sin(phi) * @sin(theta),
            @cos(phi),
        };
    }

    pub fn burst(self: *ParticleEmitter, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            self.emitParticle();
        }
    }

    pub fn setPosition(self: *ParticleEmitter, pos: [3]f32) void {
        self.position = pos;
    }

    pub fn getAliveCount(self: ParticleEmitter) u32 {
        var count: u32 = 0;
        for (self.particles) |particle| {
            if (particle.is_alive) count += 1;
        }
        return count;
    }
};

// Preset configurations

pub fn createExplosionEmitter(allocator: Allocator) !ParticleEmitter {
    var config = EmitterConfig.init();
    config.emitter_type = .Sphere;
    config.particle_type = .Billboard;
    config.blend_mode = .Additive;
    config.max_particles = 200;
    config.burst_count = 100;
    config.lifetime_min = 0.5;
    config.lifetime_max = 1.5;
    config.size_min = 2.0;
    config.size_max = 5.0;
    config.speed_min = 20.0;
    config.speed_max = 50.0;
    config.color_start = [4]f32{ 1.0, 0.8, 0.3, 1.0 };
    config.color_end = [4]f32{ 0.3, 0.1, 0.0, 0.0 };
    config.radius = 5.0;
    config.emission_rate = 0.0; // Burst only

    return try ParticleEmitter.init(allocator, config);
}

pub fn createSmokeEmitter(allocator: Allocator) !ParticleEmitter {
    var config = EmitterConfig.init();
    config.emitter_type = .Point;
    config.particle_type = .Billboard;
    config.blend_mode = .Alpha;
    config.max_particles = 100;
    config.emission_rate = 20.0;
    config.lifetime_min = 2.0;
    config.lifetime_max = 4.0;
    config.size_min = 3.0;
    config.size_max = 6.0;
    config.speed_min = 5.0;
    config.speed_max = 10.0;
    config.color_start = [4]f32{ 0.3, 0.3, 0.3, 0.8 };
    config.color_end = [4]f32{ 0.5, 0.5, 0.5, 0.0 };
    config.gravity = [3]f32{ 0.0, 5.0, 0.0 }; // Rises

    return try ParticleEmitter.init(allocator, config);
}

pub fn createFireEmitter(allocator: Allocator) !ParticleEmitter {
    var config = EmitterConfig.init();
    config.emitter_type = .Box;
    config.particle_type = .Billboard;
    config.blend_mode = .Additive;
    config.max_particles = 150;
    config.emission_rate = 50.0;
    config.lifetime_min = 0.3;
    config.lifetime_max = 0.8;
    config.size_min = 1.0;
    config.size_max = 3.0;
    config.speed_min = 10.0;
    config.speed_max = 20.0;
    config.color_start = [4]f32{ 1.0, 0.5, 0.0, 1.0 };
    config.color_end = [4]f32{ 1.0, 0.0, 0.0, 0.0 };
    config.box_size = [3]f32{ 2.0, 0.5, 2.0 };
    config.gravity = [3]f32{ 0.0, 15.0, 0.0 }; // Rises fast

    return try ParticleEmitter.init(allocator, config);
}

// Tests
test "Particle: update" {
    var particle = Particle.init();
    particle.velocity = [3]f32{ 10.0, 10.0, 0.0 };
    particle.lifetime = 1.0;

    particle.update(0.1, [3]f32{ 0.0, -9.8, 0.0 });

    try std.testing.expect(particle.position[0] > 0.0);
    try std.testing.expect(particle.is_alive);
}

test "Particle: lifetime expiration" {
    var particle = Particle.init();
    particle.lifetime = 1.0;

    particle.update(1.5, [3]f32{ 0.0, 0.0, 0.0 });

    try std.testing.expect(!particle.is_alive);
}

test "ParticleEmitter: init" {
    const allocator = std.testing.allocator;
    var config = EmitterConfig.init();
    config.max_particles = 10;

    var emitter = try ParticleEmitter.init(allocator, config);
    defer emitter.deinit();

    try std.testing.expectEqual(@as(u32, 10), @as(u32, @intCast(emitter.particles.len)));
}

test "ParticleEmitter: emission" {
    const allocator = std.testing.allocator;
    var config = EmitterConfig.init();
    config.max_particles = 100;
    config.emission_rate = 10.0;

    var emitter = try ParticleEmitter.init(allocator, config);
    defer emitter.deinit();

    emitter.update(1.0);

    try std.testing.expect(emitter.getAliveCount() > 0);
}

test "ParticleEmitter: burst" {
    const allocator = std.testing.allocator;
    var config = EmitterConfig.init();
    config.max_particles = 100;

    var emitter = try ParticleEmitter.init(allocator, config);
    defer emitter.deinit();

    emitter.burst(50);

    try std.testing.expectEqual(@as(u32, 50), emitter.getAliveCount());
}

test "Preset: explosion emitter" {
    const allocator = std.testing.allocator;
    var emitter = try createExplosionEmitter(allocator);
    defer emitter.deinit();

    try std.testing.expectEqual(EmitterType.Sphere, emitter.config.emitter_type);
}

test "Preset: smoke emitter" {
    const allocator = std.testing.allocator;
    var emitter = try createSmokeEmitter(allocator);
    defer emitter.deinit();

    try std.testing.expectEqual(EmitterType.Point, emitter.config.emitter_type);
}

test "Preset: fire emitter" {
    const allocator = std.testing.allocator;
    var emitter = try createFireEmitter(allocator);
    defer emitter.deinit();

    try std.testing.expectEqual(EmitterType.Box, emitter.config.emitter_type);
}
