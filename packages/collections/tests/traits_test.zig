const std = @import("std");
const testing = std.testing;
const traits = @import("traits");

// ==================== Collectible Trait Tests ====================

test "Collectible: primitive types" {
    const IntCollectible = traits.Collectible(i32);
    IntCollectible.verify();

    try testing.expect(!IntCollectible.needs_deinit);
    try testing.expect(IntCollectible.is_copyable);
}

test "Collectible: struct without deinit" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    const PointCollectible = traits.Collectible(Point);
    PointCollectible.verify();

    try testing.expect(!PointCollectible.needs_deinit);
    try testing.expect(PointCollectible.is_copyable);
}

test "Collectible: struct with deinit" {
    const Resource = struct {
        data: []u8,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    const ResourceCollectible = traits.Collectible(Resource);
    ResourceCollectible.verify();

    try testing.expect(ResourceCollectible.needs_deinit);
    try testing.expect(!ResourceCollectible.is_copyable);
}

test "Collectible: pointer types" {
    const PtrCollectible = traits.Collectible(*i32);
    PtrCollectible.verify();

    try testing.expect(PtrCollectible.needs_deinit);
    try testing.expect(!PtrCollectible.is_copyable);
}

test "isCollectible helper" {
    try testing.expect(traits.isCollectible(i32));
    try testing.expect(traits.isCollectible([]const u8));
    try testing.expect(traits.isCollectible(bool));
}

// ==================== Comparable Trait Tests ====================

test "Comparable: integer types" {
    const IntComparable = traits.Comparable(i32);
    IntComparable.verify();

    try testing.expect(IntComparable.has_natural_order);

    try testing.expect(IntComparable.compare(1, 2) == .lt);
    try testing.expect(IntComparable.compare(2, 1) == .gt);
    try testing.expect(IntComparable.compare(5, 5) == .eq);

    try testing.expect(IntComparable.lessThan(1, 2));
    try testing.expect(IntComparable.greaterThan(2, 1));
    try testing.expect(IntComparable.equal(5, 5));
}

test "Comparable: float types" {
    const FloatComparable = traits.Comparable(f64);
    FloatComparable.verify();

    try testing.expect(FloatComparable.has_natural_order);

    try testing.expect(FloatComparable.compare(1.5, 2.5) == .lt);
    try testing.expect(FloatComparable.compare(3.0, 1.0) == .gt);
    try testing.expect(FloatComparable.compare(2.0, 2.0) == .eq);
}

test "Comparable: bool types" {
    const BoolComparable = traits.Comparable(bool);
    BoolComparable.verify();

    try testing.expect(BoolComparable.has_natural_order);
}

test "Comparable: custom struct with compare" {
    const Person = struct {
        age: i32,
        name: []const u8,

        pub fn compare(self: @This(), other: @This()) std.math.Order {
            return std.math.order(self.age, other.age);
        }
    };

    const PersonComparable = traits.Comparable(Person);
    PersonComparable.verify();

    try testing.expect(PersonComparable.has_compare);

    const alice = Person{ .age = 30, .name = "Alice" };
    const bob = Person{ .age = 25, .name = "Bob" };

    try testing.expect(PersonComparable.compare(bob, alice) == .lt);
    try testing.expect(PersonComparable.compare(alice, bob) == .gt);
    try testing.expect(PersonComparable.lessThan(bob, alice));
}

test "isComparable helper" {
    try testing.expect(traits.isComparable(i32));
    try testing.expect(traits.isComparable(f64));
    try testing.expect(traits.isComparable(bool));
}

// ==================== Aggregatable Trait Tests ====================

test "Aggregatable: integer types" {
    const IntAggregatable = traits.Aggregatable(i32);
    IntAggregatable.verify();

    try testing.expect(IntAggregatable.is_numeric);

    try testing.expectEqual(@as(i32, 7), IntAggregatable.add(3, 4));
    try testing.expectEqual(@as(i32, 1), IntAggregatable.sub(5, 4));
    try testing.expectEqual(@as(i32, 12), IntAggregatable.mul(3, 4));
    try testing.expectEqual(@as(i32, 3), IntAggregatable.div(10, 3));

    try testing.expectEqual(@as(i32, 0), IntAggregatable.zero());

    try testing.expectEqual(@as(f64, 42.0), IntAggregatable.toFloat(42));
    try testing.expectEqual(@as(i32, 42), IntAggregatable.fromFloat(42.5));
}

test "Aggregatable: float types" {
    const FloatAggregatable = traits.Aggregatable(f64);
    FloatAggregatable.verify();

    try testing.expect(FloatAggregatable.is_numeric);

    try testing.expectEqual(@as(f64, 7.5), FloatAggregatable.add(3.0, 4.5));
    try testing.expectEqual(@as(f64, 0.5), FloatAggregatable.sub(5.0, 4.5));
    try testing.expectEqual(@as(f64, 12.0), FloatAggregatable.mul(3.0, 4.0));
    try testing.expectApproxEqAbs(@as(f64, 2.5), FloatAggregatable.div(10.0, 4.0), 0.001);

    try testing.expectEqual(@as(f64, 0.0), FloatAggregatable.zero());

    try testing.expectEqual(@as(f64, 42.5), FloatAggregatable.toFloat(42.5));
    try testing.expectEqual(@as(f64, 42.5), FloatAggregatable.fromFloat(42.5));
}

test "Aggregatable: custom type with methods" {
    const Money = struct {
        cents: i64,

        pub fn add(self: @This(), other: @This()) @This() {
            return .{ .cents = self.cents + other.cents };
        }

        pub fn sub(self: @This(), other: @This()) @This() {
            return .{ .cents = self.cents - other.cents };
        }

        pub fn mul(self: @This(), scalar: @This()) @This() {
            return .{ .cents = self.cents * scalar.cents };
        }

        pub fn div(self: @This(), scalar: @This()) @This() {
            return .{ .cents = @divTrunc(self.cents, scalar.cents) };
        }

        pub fn zero() @This() {
            return .{ .cents = 0 };
        }

        pub fn toFloat(self: @This()) f64 {
            return @as(f64, @floatFromInt(self.cents)) / 100.0;
        }

        pub fn fromFloat(val: f64) @This() {
            return .{ .cents = @intFromFloat(val * 100.0) };
        }
    };

    const MoneyAggregatable = traits.Aggregatable(Money);
    MoneyAggregatable.verify();

    try testing.expect(MoneyAggregatable.has_add);
    try testing.expect(MoneyAggregatable.has_sub);
    try testing.expect(MoneyAggregatable.has_mul);
    try testing.expect(MoneyAggregatable.has_div);

    const m1 = Money{ .cents = 500 }; // $5.00
    const m2 = Money{ .cents = 300 }; // $3.00

    const sum = MoneyAggregatable.add(m1, m2);
    try testing.expectEqual(@as(i64, 800), sum.cents);

    const diff = MoneyAggregatable.sub(m1, m2);
    try testing.expectEqual(@as(i64, 200), diff.cents);

    const zero = MoneyAggregatable.zero();
    try testing.expectEqual(@as(i64, 0), zero.cents);

    try testing.expectEqual(@as(f64, 5.0), MoneyAggregatable.toFloat(m1));

    const from_float = MoneyAggregatable.fromFloat(10.50);
    try testing.expectEqual(@as(i64, 1050), from_float.cents);
}

test "isAggregatable helper" {
    try testing.expect(traits.isAggregatable(i32));
    try testing.expect(traits.isAggregatable(f64));
    try testing.expect(traits.isAggregatable(u64));
}

// ==================== Combined Trait Tests ====================

test "Type satisfies multiple traits" {
    const IntCollectible = traits.Collectible(i32);
    const IntComparable = traits.Comparable(i32);
    const IntAggregatable = traits.Aggregatable(i32);

    IntCollectible.verify();
    IntComparable.verify();
    IntAggregatable.verify();

    try testing.expect(traits.isCollectible(i32));
    try testing.expect(traits.isComparable(i32));
    try testing.expect(traits.isAggregatable(i32));
}

test "Custom type satisfies all traits" {
    const Score = struct {
        points: i32,

        pub fn compare(self: @This(), other: @This()) std.math.Order {
            return std.math.order(self.points, other.points);
        }

        pub fn add(self: @This(), other: @This()) @This() {
            return .{ .points = self.points + other.points };
        }

        pub fn sub(self: @This(), other: @This()) @This() {
            return .{ .points = self.points - other.points };
        }

        pub fn mul(self: @This(), other: @This()) @This() {
            return .{ .points = self.points * other.points };
        }

        pub fn div(self: @This(), other: @This()) @This() {
            return .{ .points = @divTrunc(self.points, other.points) };
        }

        pub fn zero() @This() {
            return .{ .points = 0 };
        }

        pub fn toFloat(self: @This()) f64 {
            return @floatFromInt(self.points);
        }

        pub fn fromFloat(val: f64) @This() {
            return .{ .points = @intFromFloat(val) };
        }
    };

    traits.Collectible(Score).verify();
    traits.Comparable(Score).verify();
    traits.Aggregatable(Score).verify();

    const s1 = Score{ .points = 100 };
    const s2 = Score{ .points = 50 };

    try testing.expect(traits.Comparable(Score).compare(s1, s2) == .gt);

    const sum = traits.Aggregatable(Score).add(s1, s2);
    try testing.expectEqual(@as(i32, 150), sum.points);
}

// ==================== Additional Traits Tests ====================

// ==================== Hashable Trait Tests ====================

test "Hashable: integer types" {
    const IntHashable = traits.Hashable(i32);
    IntHashable.verify();

    try testing.expect(IntHashable.has_natural_hash);

    const hash1 = IntHashable.hash(42);
    const hash2 = IntHashable.hash(42);
    const hash3 = IntHashable.hash(43);

    try testing.expectEqual(hash1, hash2);
    try testing.expect(hash1 != hash3);
}

test "Hashable: boolean types" {
    const BoolHashable = traits.Hashable(bool);
    BoolHashable.verify();

    try testing.expect(BoolHashable.has_natural_hash);

    const hash_true = BoolHashable.hash(true);
    const hash_false = BoolHashable.hash(false);

    try testing.expect(hash_true != hash_false);
    try testing.expectEqual(@as(u64, 1), hash_true);
    try testing.expectEqual(@as(u64, 0), hash_false);
}

test "Hashable: custom struct with hash" {
    const Point = struct {
        x: i32,
        y: i32,

        pub fn hash(self: @This()) u64 {
            const x_hash = @as(u64, @bitCast(@as(i64, self.x)));
            const y_hash = @as(u64, @bitCast(@as(i64, self.y)));
            return x_hash ^ y_hash;
        }
    };

    const PointHashable = traits.Hashable(Point);
    PointHashable.verify();

    try testing.expect(PointHashable.has_hash);

    const p1 = Point{ .x = 10, .y = 20 };
    const p2 = Point{ .x = 10, .y = 20 };
    const p3 = Point{ .x = 15, .y = 25 };

    try testing.expectEqual(PointHashable.hash(p1), PointHashable.hash(p2));
    try testing.expect(PointHashable.hash(p1) != PointHashable.hash(p3));
}

test "isHashable helper" {
    try testing.expect(traits.isHashable(i32));
    try testing.expect(traits.isHashable(f64));
    try testing.expect(traits.isHashable(bool));
}

// ==================== Displayable Trait Tests ====================

test "Displayable: primitive types" {
    const IntDisplayable = traits.Displayable(i32);
    IntDisplayable.verify();

    try testing.expect(IntDisplayable.is_primitive);

    const FloatDisplayable = traits.Displayable(f64);
    FloatDisplayable.verify();

    try testing.expect(FloatDisplayable.is_primitive);

    const BoolDisplayable = traits.Displayable(bool);
    BoolDisplayable.verify();

    try testing.expect(BoolDisplayable.is_primitive);
}

test "isDisplayable helper" {
    try testing.expect(traits.isDisplayable(i32));
    try testing.expect(traits.isDisplayable(f64));
    try testing.expect(traits.isDisplayable(bool));
}

// ==================== Equatable Trait Tests ====================

test "Equatable: integer types" {
    const IntEquatable = traits.Equatable(i32);
    IntEquatable.verify();

    try testing.expect(IntEquatable.has_natural_equality);

    try testing.expect(IntEquatable.eql(42, 42));
    try testing.expect(!IntEquatable.eql(42, 43));

    try testing.expect(!IntEquatable.notEql(42, 42));
    try testing.expect(IntEquatable.notEql(42, 43));
}

test "Equatable: custom struct with eql" {
    const Person = struct {
        age: i32,
        name: []const u8,

        pub fn eql(self: @This(), other: @This()) bool {
            return self.age == other.age and std.mem.eql(u8, self.name, other.name);
        }
    };

    const PersonEquatable = traits.Equatable(Person);
    PersonEquatable.verify();

    try testing.expect(PersonEquatable.has_eql);

    const alice1 = Person{ .age = 30, .name = "Alice" };
    const alice2 = Person{ .age = 30, .name = "Alice" };
    const bob = Person{ .age = 25, .name = "Bob" };

    try testing.expect(PersonEquatable.eql(alice1, alice2));
    try testing.expect(!PersonEquatable.eql(alice1, bob));
    try testing.expect(PersonEquatable.notEql(alice1, bob));
}

test "isEquatable helper" {
    try testing.expect(traits.isEquatable(i32));
    try testing.expect(traits.isEquatable(f64));
    try testing.expect(traits.isEquatable(bool));
}

// ==================== Cloneable Trait Tests ====================

test "Cloneable: primitive types" {
    const IntCloneable = traits.Cloneable(i32);
    IntCloneable.verify();

    try testing.expect(IntCloneable.is_copyable);

    const FloatCloneable = traits.Cloneable(f64);
    FloatCloneable.verify();

    try testing.expect(FloatCloneable.is_copyable);
}

test "Cloneable: simple struct" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    const PointCloneable = traits.Cloneable(Point);
    PointCloneable.verify();

    try testing.expect(PointCloneable.is_copyable);
}

test "Cloneable: struct with clone method" {
    const Buffer = struct {
        data: []u8,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn clone(self: @This(), allocator: std.mem.Allocator) !@This() {
            const new_data = try allocator.dupe(u8, self.data);
            return .{ .data = new_data };
        }
    };

    const BufferCloneable = traits.Cloneable(Buffer);
    BufferCloneable.verify();

    try testing.expect(BufferCloneable.has_clone);
    try testing.expect(!BufferCloneable.is_copyable); // Has deinit, so not copyable
}

test "isCloneable helper" {
    try testing.expect(traits.isCloneable(i32));
    try testing.expect(traits.isCloneable(f64));
    try testing.expect(traits.isCloneable(bool));
}

// ==================== Serializable Trait Tests ====================

test "Serializable: primitive types" {
    const IntSerializable = traits.Serializable(i32);
    IntSerializable.verify();

    try testing.expect(IntSerializable.is_primitive);

    const FloatSerializable = traits.Serializable(f64);
    FloatSerializable.verify();

    try testing.expect(FloatSerializable.is_primitive);

    const BoolSerializable = traits.Serializable(bool);
    BoolSerializable.verify();

    try testing.expect(BoolSerializable.is_primitive);
}

test "isSerializable helper" {
    try testing.expect(traits.isSerializable(i32));
    try testing.expect(traits.isSerializable(f64));
    try testing.expect(traits.isSerializable(bool));
}

// ==================== Iterable Trait Tests ====================

test "Iterable: slice types" {
    const SliceIterable = traits.Iterable([]const i32);
    SliceIterable.verify();

    try testing.expect(SliceIterable.is_array);
}

test "Iterable: array types" {
    const ArrayIterable = traits.Iterable([5]i32);
    ArrayIterable.verify();

    try testing.expect(ArrayIterable.is_array);
}

test "Iterable: struct with iterator" {
    const Range = struct {
        start: i32,
        end: i32,

        pub const Iterator = struct {
            current: i32,
            end: i32,

            pub fn next(self: *@This()) ?i32 {
                if (self.current >= self.end) return null;
                const val = self.current;
                self.current += 1;
                return val;
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .current = self.start, .end = self.end };
        }
    };

    const RangeIterable = traits.Iterable(Range);
    RangeIterable.verify();

    try testing.expect(RangeIterable.has_iterator);
}

test "isIterable helper" {
    try testing.expect(traits.isIterable([]const i32));
    try testing.expect(traits.isIterable([5]i32));
}

// ==================== Multiple New Traits Tests ====================

test "Type satisfies multiple new traits" {
    const IntHashable = traits.Hashable(i32);
    const IntDisplayable = traits.Displayable(i32);
    const IntEquatable = traits.Equatable(i32);
    const IntCloneable = traits.Cloneable(i32);
    const IntSerializable = traits.Serializable(i32);

    IntHashable.verify();
    IntDisplayable.verify();
    IntEquatable.verify();
    IntCloneable.verify();
    IntSerializable.verify();

    try testing.expect(traits.isHashable(i32));
    try testing.expect(traits.isDisplayable(i32));
    try testing.expect(traits.isEquatable(i32));
    try testing.expect(traits.isCloneable(i32));
    try testing.expect(traits.isSerializable(i32));
}

test "Custom type with all traits" {
    const CompleteType = struct {
        value: i32,

        pub fn hash(self: @This()) u64 {
            return @as(u64, @bitCast(@as(i64, self.value)));
        }

        pub fn eql(self: @This(), other: @This()) bool {
            return self.value == other.value;
        }

        pub fn clone(self: @This(), allocator: std.mem.Allocator) !@This() {
            _ = allocator;
            return self;
        }

        pub fn compare(self: @This(), other: @This()) std.math.Order {
            return std.math.order(self.value, other.value);
        }
    };

    traits.Hashable(CompleteType).verify();
    traits.Equatable(CompleteType).verify();
    traits.Cloneable(CompleteType).verify();
    traits.Comparable(CompleteType).verify();

    const ct1 = CompleteType{ .value = 42 };
    const ct2 = CompleteType{ .value = 42 };
    const ct3 = CompleteType{ .value = 10 };

    const hash1 = traits.Hashable(CompleteType).hash(ct1);
    const hash2 = traits.Hashable(CompleteType).hash(ct2);
    try testing.expectEqual(hash1, hash2);

    try testing.expect(traits.Equatable(CompleteType).eql(ct1, ct2));
    try testing.expect(!traits.Equatable(CompleteType).eql(ct1, ct3));

    try testing.expect(traits.Comparable(CompleteType).compare(ct1, ct2) == .eq);
    try testing.expect(traits.Comparable(CompleteType).compare(ct1, ct3) == .gt);
}
