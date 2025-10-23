const std = @import("std");

/// Dependent Types - Types that depend on values
///
/// Dependent types allow types to be parameterized by values, not just other types.
/// This enables very precise type specifications and allows proving properties at compile time.
///
/// Examples:
///   - Vector<n: usize> - vector of exactly n elements
///   - Range<min: i32, max: i32> - integer between min and max
///   - List<T, length: usize> - list of exactly 'length' elements of type T
///   - Matrix<rows: usize, cols: usize, T> - matrix with specific dimensions
///
/// Key concepts:
///   - Pi types (Π): dependent function types (x: A) -> B(x)
///   - Sigma types (Σ): dependent pair types (x: A, B(x))
///   - Equality types: proofs that two values are equal
///   - Refinement types: subtypes with predicates
pub const DependentTypes = struct {
    allocator: std.mem.Allocator,
    type_defs: std.StringHashMap(TypeDef),
    value_deps: std.StringHashMap(ValueDependency),
    refinements: std.ArrayList(Refinement),

    pub const TypeDef = struct {
        name: []const u8,
        kind: TypeKind,
        dependencies: []const []const u8,
        constraint: ?Constraint,
    };

    pub const TypeKind = enum {
        /// Π type: (x: A) -> B(x)
        pi,
        /// Σ type: (x: A, B(x))
        sigma,
        /// Equality type: a = b
        equality,
        /// Refinement type: { x: T | P(x) }
        refinement,
        /// Indexed type: T[i]
        indexed,
    };

    pub const ValueDependency = struct {
        value_name: []const u8,
        value_type: []const u8,
        dependent_types: []const []const u8,
    };

    pub const Constraint = union(enum) {
        predicate: *const fn (?*anyopaque) bool,
        equality: struct {
            left: []const u8,
            right: []const u8,
        },
        bounds: struct {
            lower: ?i64,
            upper: ?i64,
        },
    };

    pub const Refinement = struct {
        base_type: []const u8,
        predicate: *const fn (?*anyopaque) bool,
        description: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) DependentTypes {
        return .{
            .allocator = allocator,
            .type_defs = std.StringHashMap(TypeDef).init(allocator),
            .value_deps = std.StringHashMap(ValueDependency).init(allocator),
            .refinements = std.ArrayList(Refinement).init(allocator),
        };
    }

    pub fn deinit(self: *DependentTypes) void {
        self.type_defs.deinit();
        self.value_deps.deinit();
        self.refinements.deinit();
    }

    /// Register a dependent type
    pub fn registerType(
        self: *DependentTypes,
        name: []const u8,
        kind: TypeKind,
        dependencies: []const []const u8,
        constraint: ?Constraint,
    ) !void {
        try self.type_defs.put(name, .{
            .name = name,
            .kind = kind,
            .dependencies = dependencies,
            .constraint = constraint,
        });
    }

    /// Register a value dependency
    pub fn registerValueDependency(
        self: *DependentTypes,
        value_name: []const u8,
        value_type: []const u8,
        dependent_types: []const []const u8,
    ) !void {
        try self.value_deps.put(value_name, .{
            .value_name = value_name,
            .value_type = value_type,
            .dependent_types = dependent_types,
        });
    }

    /// Register a refinement type
    pub fn registerRefinement(
        self: *DependentTypes,
        base_type: []const u8,
        predicate: *const fn (?*anyopaque) bool,
        description: []const u8,
    ) !void {
        try self.refinements.append(.{
            .base_type = base_type,
            .predicate = predicate,
            .description = description,
        });
    }

    /// Check if a value satisfies a refinement
    pub fn checkRefinement(
        self: *DependentTypes,
        refinement_idx: usize,
        value: ?*anyopaque,
    ) bool {
        if (refinement_idx >= self.refinements.items.len) return false;
        const refinement = self.refinements.items[refinement_idx];
        return refinement.predicate(value);
    }
};

/// Pi Type - Dependent function type (x: A) -> B(x)
/// The return type B depends on the input value x
pub fn Pi(comptime A: type, comptime B: fn (A) type) type {
    return struct {
        function: *const fn (A) (B(A)),

        const Self = @This();

        pub fn init(f: *const fn (A) (B(A))) Self {
            return .{ .function = f };
        }

        pub fn apply(self: Self, a: A) B(a) {
            return self.function(a);
        }
    };
}

/// Sigma Type - Dependent pair (x: A, B(x))
/// The second element's type depends on the first element's value
pub fn Sigma(comptime A: type, comptime B: fn (A) type) type {
    return struct {
        first: A,
        second: B(first),

        const Self = @This();

        pub fn init(a: A, b: B(a)) Self {
            return .{ .first = a, .second = b };
        }

        pub fn fst(self: Self) A {
            return self.first;
        }

        pub fn snd(self: Self) B(self.first) {
            return self.second;
        }
    };
}

/// Equality Type - Proof that two values are equal
pub fn Eq(comptime T: type, comptime a: T, comptime b: T) type {
    return struct {
        const Self = @This();

        pub fn refl() !Self {
            if (a != b) return error.NotEqual;
            return Self{};
        }

        pub fn symm(proof: Self) Self {
            _ = proof;
            return Self{};
        }

        pub fn trans(comptime c: T, proof1: Self, proof2: Eq(T, b, c)) Eq(T, a, c) {
            _ = proof1;
            _ = proof2;
            return Eq(T, a, c){};
        }
    };
}

/// Refinement Type - Subtype with predicate
/// { x: T | P(x) } - values of type T that satisfy predicate P
pub fn Refinement(comptime T: type, comptime P: fn (T) bool) type {
    return struct {
        value: T,

        const Self = @This();

        pub fn init(v: T) !Self {
            if (!P(v)) return error.PredicateFailed;
            return .{ .value = v };
        }

        pub fn get(self: Self) T {
            return self.value;
        }

        pub fn set(self: *Self, v: T) !void {
            if (!P(v)) return error.PredicateFailed;
            self.value = v;
        }
    };
}

/// Length-indexed vector (dependent type example)
/// Vec<T, n> - vector of exactly n elements
pub fn Vec(comptime T: type, comptime n: usize) type {
    return struct {
        data: [n]T,

        const Self = @This();

        pub fn init() Self {
            return .{ .data = undefined };
        }

        pub fn fromArray(arr: [n]T) Self {
            return .{ .data = arr };
        }

        pub fn len(self: *const Self) usize {
            _ = self;
            return n;
        }

        pub fn get(self: *const Self, idx: usize) !T {
            if (idx >= n) return error.IndexOutOfBounds;
            return self.data[idx];
        }

        pub fn set(self: *Self, idx: usize, value: T) !void {
            if (idx >= n) return error.IndexOutOfBounds;
            self.data[idx] = value;
        }

        /// Append - returns a new vector with n+1 elements
        pub fn append(self: Self, value: T) Vec(T, n + 1) {
            var result = Vec(T, n + 1).init();
            for (0..n) |i| {
                result.data[i] = self.data[i];
            }
            result.data[n] = value;
            return result;
        }

        /// Take - returns a new vector with m elements (m <= n)
        pub fn take(self: Self, comptime m: usize) Vec(T, m) {
            if (m > n) @compileError("Cannot take more elements than vector contains");
            var result = Vec(T, m).init();
            for (0..m) |i| {
                result.data[i] = self.data[i];
            }
            return result;
        }

        /// Concatenate two vectors
        pub fn concat(self: Self, comptime m: usize, other: Vec(T, m)) Vec(T, n + m) {
            var result = Vec(T, n + m).init();
            for (0..n) |i| {
                result.data[i] = self.data[i];
            }
            for (0..m) |i| {
                result.data[n + i] = other.data[i];
            }
            return result;
        }

        /// Map over the vector (preserves length)
        pub fn map(self: Self, comptime U: type, f: *const fn (T) U) Vec(U, n) {
            var result = Vec(U, n).init();
            for (0..n) |i| {
                result.data[i] = f(self.data[i]);
            }
            return result;
        }

        /// Zip two vectors of the same length
        pub fn zip(self: Self, comptime U: type, other: Vec(U, n)) Vec(struct { T, U }, n) {
            var result = Vec(struct { T, U }, n).init();
            for (0..n) |i| {
                result.data[i] = .{ self.data[i], other.data[i] };
            }
            return result;
        }
    };
}

/// Bounded integer - refinement type example
/// Bounded<min, max> - integers between min and max (inclusive)
pub fn Bounded(comptime min: i64, comptime max: i64) type {
    if (min > max) @compileError("min must be <= max");

    return struct {
        value: i64,

        const Self = @This();

        pub fn init(v: i64) !Self {
            if (v < min or v > max) return error.OutOfBounds;
            return .{ .value = v };
        }

        pub fn get(self: Self) i64 {
            return self.value;
        }

        pub fn set(self: *Self, v: i64) !void {
            if (v < min or v > max) return error.OutOfBounds;
            self.value = v;
        }

        pub fn add(self: Self, other: Self) !Self {
            const result = self.value + other.value;
            return Self.init(result);
        }

        pub fn sub(self: Self, other: Self) !Self {
            const result = self.value - other.value;
            return Self.init(result);
        }

        pub fn min_value() i64 {
            return min;
        }

        pub fn max_value() i64 {
            return max;
        }
    };
}

/// Non-empty list - dependent type ensuring non-emptiness
pub fn NonEmptyList(comptime T: type) type {
    return struct {
        head: T,
        tail: []T,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, first: T) Self {
            return .{
                .head = first,
                .tail = &.{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.tail);
        }

        pub fn length(self: *const Self) usize {
            return 1 + self.tail.len;
        }

        pub fn first(self: *const Self) T {
            return self.head;
        }

        pub fn append(self: *Self, value: T) !void {
            var new_tail = try self.allocator.alloc(T, self.tail.len + 1);
            @memcpy(new_tail[0..self.tail.len], self.tail);
            new_tail[self.tail.len] = value;
            self.allocator.free(self.tail);
            self.tail = new_tail;
        }

        pub fn map(self: Self, comptime U: type, f: *const fn (T) U) !NonEmptyList(U) {
            var result = NonEmptyList(U).init(self.allocator, f(self.head));
            for (self.tail) |item| {
                try result.append(f(item));
            }
            return result;
        }
    };
}

/// Sorted list - dependent type maintaining sorted invariant
pub fn SortedList(comptime T: type, comptime lessThan: fn (T, T) bool) type {
    return struct {
        items: []T,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .items = &.{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        pub fn length(self: *const Self) usize {
            return self.items.len;
        }

        /// Insert maintains sorted order
        pub fn insert(self: *Self, value: T) !void {
            // Find insertion point
            var insert_idx: usize = 0;
            for (self.items, 0..) |item, i| {
                if (lessThan(value, item)) {
                    insert_idx = i;
                    break;
                }
                insert_idx = i + 1;
            }

            // Allocate new array
            var new_items = try self.allocator.alloc(T, self.items.len + 1);

            // Copy elements before insertion point
            @memcpy(new_items[0..insert_idx], self.items[0..insert_idx]);

            // Insert new value
            new_items[insert_idx] = value;

            // Copy elements after insertion point
            if (insert_idx < self.items.len) {
                @memcpy(new_items[insert_idx + 1 ..], self.items[insert_idx..]);
            }

            // Free old array and update
            self.allocator.free(self.items);
            self.items = new_items;
        }

        pub fn get(self: *const Self, idx: usize) !T {
            if (idx >= self.items.len) return error.IndexOutOfBounds;
            return self.items[idx];
        }

        /// Binary search (guaranteed to work because list is sorted)
        pub fn binarySearch(self: *const Self, value: T) ?usize {
            var left: usize = 0;
            var right: usize = self.items.len;

            while (left < right) {
                const mid = left + (right - left) / 2;
                const mid_val = self.items[mid];

                if (lessThan(mid_val, value)) {
                    left = mid + 1;
                } else if (lessThan(value, mid_val)) {
                    right = mid;
                } else {
                    return mid;
                }
            }

            return null;
        }
    };
}

/// Matrix with dimension tracking
pub fn Matrix(comptime T: type, comptime rows: usize, comptime cols: usize) type {
    return struct {
        data: [rows][cols]T,

        const Self = @This();

        pub fn init() Self {
            return .{ .data = undefined };
        }

        pub fn rows_count(self: *const Self) usize {
            _ = self;
            return rows;
        }

        pub fn cols_count(self: *const Self) usize {
            _ = self;
            return cols;
        }

        pub fn get(self: *const Self, row: usize, col: usize) !T {
            if (row >= rows or col >= cols) return error.IndexOutOfBounds;
            return self.data[row][col];
        }

        pub fn set(self: *Self, row: usize, col: usize, value: T) !void {
            if (row >= rows or col >= cols) return error.IndexOutOfBounds;
            self.data[row][col] = value;
        }

        /// Matrix multiplication (type-safe dimensions)
        pub fn multiply(self: Self, comptime n: usize, other: Matrix(T, cols, n)) Matrix(T, rows, n) {
            var result = Matrix(T, rows, n).init();

            for (0..rows) |i| {
                for (0..n) |j| {
                    var sum: T = 0;
                    for (0..cols) |k| {
                        sum += self.data[i][k] * other.data[k][j];
                    }
                    result.data[i][j] = sum;
                }
            }

            return result;
        }

        /// Transpose
        pub fn transpose(self: Self) Matrix(T, cols, rows) {
            var result = Matrix(T, cols, rows).init();
            for (0..rows) |i| {
                for (0..cols) |j| {
                    result.data[j][i] = self.data[i][j];
                }
            }
            return result;
        }
    };
}

/// Proof type - compile-time proof that a property holds
pub const Proof = struct {
    /// Proof that n > 0
    pub fn Positive(comptime n: i64) type {
        if (n <= 0) @compileError("Value must be positive");
        return struct {
            pub const value = n;
        };
    }

    /// Proof that n is even
    pub fn Even(comptime n: i64) type {
        if (@mod(n, 2) != 0) @compileError("Value must be even");
        return struct {
            pub const value = n;
        };
    }

    /// Proof that n is a power of 2
    pub fn PowerOfTwo(comptime n: u64) type {
        if (n == 0 or (n & (n - 1)) != 0) @compileError("Value must be a power of 2");
        return struct {
            pub const value = n;
        };
    }

    /// Proof that m <= n
    pub fn LessThanOrEqual(comptime m: i64, comptime n: i64) type {
        if (m > n) @compileError("First value must be <= second value");
        return struct {
            pub const left = m;
            pub const right = n;
        };
    }
};

/// Example usage patterns
pub const Examples = struct {
    /// Safe array indexing with dependent types
    pub fn safeIndex(comptime T: type, comptime n: usize) type {
        return struct {
            array: Vec(T, n),
            index: Bounded(0, n - 1),

            const Self = @This();

            pub fn init(arr: Vec(T, n), idx: Bounded(0, n - 1)) Self {
                return .{ .array = arr, .index = idx };
            }

            /// Get is guaranteed to never fail because index is bounded
            pub fn get(self: Self) T {
                return self.array.data[@intCast(self.index.get())];
            }
        };
    }

    /// Division by non-zero (dependent type preventing division by zero)
    pub const NonZero = Refinement(i64, struct {
        fn predicate(x: i64) bool {
            return x != 0;
        }
    }.predicate);

    pub fn safeDivide(numerator: i64, denominator: NonZero) i64 {
        return @divFloor(numerator, denominator.get());
    }
};
