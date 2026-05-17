// Deterministic game primitives for lockstep simulations, replays, and RTS rules.

const std = @import("std");

pub const Tick = u64;
pub const PlayerIndex = u16;

pub const EntityId = struct {
    index: u32,
    generation: u16,

    pub const invalid: EntityId = .{ .index = 0, .generation = 0 };

    pub fn init(index: u32, generation: u16) EntityId {
        return .{ .index = index, .generation = generation };
    }

    pub fn isValid(self: EntityId) bool {
        return self.index != 0;
    }

    pub fn eql(self: EntityId, other: EntityId) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};

pub const DeterministicHash = struct {
    value: u64,

    const offset_basis: u64 = 14_695_981_039_346_656_037;
    const prime: u64 = 1_099_511_628_211;

    pub fn init(seed: u64) DeterministicHash {
        var self = DeterministicHash{ .value = offset_basis };
        self.mixU64(seed);
        return self;
    }

    pub fn mixByte(self: *DeterministicHash, byte: u8) void {
        self.value ^= byte;
        self.value *%= prime;
    }

    pub fn mixBytes(self: *DeterministicHash, bytes: []const u8) void {
        for (bytes) |byte| {
            self.mixByte(byte);
        }
    }

    pub fn mixBool(self: *DeterministicHash, value: bool) void {
        self.mixByte(if (value) 1 else 0);
    }

    pub fn mixU32(self: *DeterministicHash, value: u32) void {
        var remaining = value;
        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            self.mixByte(@truncate(remaining));
            remaining >>= 8;
        }
    }

    pub fn mixU64(self: *DeterministicHash, value: u64) void {
        var remaining = value;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            self.mixByte(@truncate(remaining));
            remaining >>= 8;
        }
    }

    pub fn mixI32(self: *DeterministicHash, value: i32) void {
        self.mixU32(@bitCast(value));
    }

    pub fn finish(self: DeterministicHash) u64 {
        return self.value;
    }
};

pub const FixedStepClock = struct {
    tick_rate: u32,
    tick_ns: u64,
    accumulator_ns: u64 = 0,
    tick: Tick = 0,

    pub fn init(tick_rate: u32) FixedStepClock {
        const clamped_rate = @max(tick_rate, 1);
        return .{
            .tick_rate = clamped_rate,
            .tick_ns = @divFloor(1_000_000_000, clamped_rate),
        };
    }

    pub fn addElapsed(self: *FixedStepClock, elapsed_ns: u64) u32 {
        self.accumulator_ns +|= elapsed_ns;

        var steps: u32 = 0;
        while (self.accumulator_ns >= self.tick_ns) {
            self.accumulator_ns -= self.tick_ns;
            self.tick += 1;
            steps += 1;
        }
        return steps;
    }

    pub fn alpha(self: FixedStepClock) f32 {
        if (self.tick_ns == 0) return 0;
        return @as(f32, @floatFromInt(self.accumulator_ns)) / @as(f32, @floatFromInt(self.tick_ns));
    }
};

pub const HexPoint = struct {
    q: i32,
    r: i32,

    pub const directions = [_]HexPoint{
        .{ .q = 1, .r = 0 },
        .{ .q = 1, .r = -1 },
        .{ .q = 0, .r = -1 },
        .{ .q = -1, .r = 0 },
        .{ .q = -1, .r = 1 },
        .{ .q = 0, .r = 1 },
    };

    pub fn init(q: i32, r: i32) HexPoint {
        return .{ .q = q, .r = r };
    }

    pub fn add(self: HexPoint, other: HexPoint) HexPoint {
        return .{ .q = self.q + other.q, .r = self.r + other.r };
    }

    pub fn neighbor(self: HexPoint, direction: u3) HexPoint {
        return self.add(directions[direction]);
    }

    pub fn distance(self: HexPoint, other: HexPoint) u32 {
        const dq = @abs(self.q - other.q);
        const dr = @abs(self.r - other.r);
        const ds = @abs((self.q + self.r) - (other.q + other.r));
        return @intCast(@divFloor(dq + dr + ds, 2));
    }
};

test "DeterministicHash is stable and order-sensitive" {
    var a = DeterministicHash.init(7);
    a.mixU32(42);
    a.mixBytes("settlers");

    var b = DeterministicHash.init(7);
    b.mixU32(42);
    b.mixBytes("settlers");

    var c = DeterministicHash.init(7);
    c.mixBytes("settlers");
    c.mixU32(42);

    try std.testing.expectEqual(a.finish(), b.finish());
    try std.testing.expect(a.finish() != c.finish());
}

test "FixedStepClock emits whole deterministic ticks" {
    var clock = FixedStepClock.init(20);

    try std.testing.expectEqual(@as(u32, 0), clock.addElapsed(49_000_000));
    try std.testing.expectEqual(@as(Tick, 0), clock.tick);
    try std.testing.expect(clock.alpha() > 0.9);

    try std.testing.expectEqual(@as(u32, 2), clock.addElapsed(51_000_000));
    try std.testing.expectEqual(@as(Tick, 2), clock.tick);
    try std.testing.expectEqual(@as(u64, 0), clock.accumulator_ns);
}

test "HexPoint distance and neighbors match axial hex rules" {
    const origin = HexPoint.init(0, 0);
    const east = origin.neighbor(0);
    const southwest = origin.neighbor(4);

    try std.testing.expectEqual(HexPoint.init(1, 0), east);
    try std.testing.expectEqual(@as(u32, 1), origin.distance(east));
    try std.testing.expectEqual(@as(u32, 1), origin.distance(southwest));
    try std.testing.expectEqual(@as(u32, 2), east.distance(southwest));
}
