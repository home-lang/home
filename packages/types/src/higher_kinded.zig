const std = @import("std");

/// Higher-Kinded Types (HKT) - Types that take other types as parameters
/// Enables abstraction over type constructors (e.g., Functor, Monad, etc.)
///
/// HKTs allow us to abstract over type constructors like Option<T>, Result<T, E>, List<T>
/// and define common interfaces that work across all of them.
pub const HigherKindedTypes = struct {
    allocator: std.mem.Allocator,
    type_constructors: std.StringHashMap(TypeConstructor),
    type_classes: std.StringHashMap(TypeClass),

    pub const Kind = enum {
        /// * - concrete type (Int, String, etc.)
        concrete,
        /// * -> * - type constructor taking one type (Option, List, etc.)
        unary,
        /// * -> * -> * - type constructor taking two types (Result, Map, etc.)
        binary,
        /// (* -> *) -> * - higher-order (takes type constructor)
        higher_order,
    };

    pub const TypeConstructor = struct {
        name: []const u8,
        kind: Kind,
        arity: usize,
        type_params: []const []const u8,
    };

    pub const TypeClass = struct {
        name: []const u8,
        kind: Kind,
        methods: []const Method,
        super_classes: []const []const u8,

        pub const Method = struct {
            name: []const u8,
            signature: []const u8,
        };
    };

    pub fn init(allocator: std.mem.Allocator) HigherKindedTypes {
        return .{
            .allocator = allocator,
            .type_constructors = std.StringHashMap(TypeConstructor).init(allocator),
            .type_classes = std.StringHashMap(TypeClass).init(allocator),
        };
    }

    pub fn deinit(self: *HigherKindedTypes) void {
        self.type_constructors.deinit();
        self.type_classes.deinit();
    }

    /// Register a type constructor
    pub fn registerTypeConstructor(
        self: *HigherKindedTypes,
        name: []const u8,
        kind: Kind,
        type_params: []const []const u8,
    ) !void {
        try self.type_constructors.put(name, .{
            .name = name,
            .kind = kind,
            .arity = type_params.len,
            .type_params = type_params,
        });
    }

    /// Register a type class
    pub fn registerTypeClass(
        self: *HigherKindedTypes,
        name: []const u8,
        kind: Kind,
        methods: []const TypeClass.Method,
        super_classes: []const []const u8,
    ) !void {
        try self.type_classes.put(name, .{
            .name = name,
            .kind = kind,
            .methods = methods,
            .super_classes = super_classes,
        });
    }
};

/// Functor - Types that can be mapped over
/// F<A> -> (A -> B) -> F<B>
pub fn Functor(comptime F: type) type {
    return struct {
        pub fn map(
            self: F,
            comptime A: type,
            comptime B: type,
            f: *const fn (A) B,
        ) F {
            _ = self;
            _ = f;
            @compileError("Functor.map must be implemented for " ++ @typeName(F));
        }
    };
}

/// Applicative - Functors with application
/// F<A -> B> -> F<A> -> F<B>
pub fn Applicative(comptime F: type) type {
    return struct {
        pub const Base = Functor(F);

        pub fn pure(comptime A: type, value: A) F {
            _ = value;
            @compileError("Applicative.pure must be implemented for " ++ @typeName(F));
        }

        pub fn ap(
            self: F,
            comptime A: type,
            comptime B: type,
            ff: F,
        ) F {
            _ = self;
            _ = ff;
            @compileError("Applicative.ap must be implemented for " ++ @typeName(F));
        }
    };
}

/// Monad - Chainable computations
/// F<A> -> (A -> F<B>) -> F<B>
pub fn Monad(comptime M: type) type {
    return struct {
        pub const Base = Applicative(M);

        pub fn bind(
            self: M,
            comptime A: type,
            comptime B: type,
            f: *const fn (A) M,
        ) M {
            _ = self;
            _ = f;
            @compileError("Monad.bind must be implemented for " ++ @typeName(M));
        }

        pub fn flatMap(
            self: M,
            comptime A: type,
            comptime B: type,
            f: *const fn (A) M,
        ) M {
            return bind(self, A, B, f);
        }
    };
}

/// Foldable - Types that can be folded/reduced
pub fn Foldable(comptime F: type) type {
    return struct {
        pub fn foldLeft(
            self: F,
            comptime A: type,
            comptime B: type,
            initial: B,
            f: *const fn (B, A) B,
        ) B {
            _ = self;
            _ = initial;
            _ = f;
            @compileError("Foldable.foldLeft must be implemented for " ++ @typeName(F));
        }

        pub fn foldRight(
            self: F,
            comptime A: type,
            comptime B: type,
            initial: B,
            f: *const fn (A, B) B,
        ) B {
            _ = self;
            _ = initial;
            _ = f;
            @compileError("Foldable.foldRight must be implemented for " ++ @typeName(F));
        }
    };
}

/// Traversable - Functors that can be traversed
pub fn Traversable(comptime T: type) type {
    return struct {
        pub const Base = Functor(T);
        pub const FoldableBase = Foldable(T);

        pub fn traverse(
            self: T,
            comptime A: type,
            comptime B: type,
            comptime F: type,
            f: *const fn (A) F,
        ) F {
            _ = self;
            _ = f;
            @compileError("Traversable.traverse must be implemented for " ++ @typeName(T));
        }
    };
}

/// Example: Option type with HKT instances
pub fn Option(comptime T: type) type {
    return union(enum) {
        some: T,
        none: void,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .some = value };
        }

        pub fn none_value() Self {
            return .{ .none = {} };
        }

        pub fn isSome(self: Self) bool {
            return switch (self) {
                .some => true,
                .none => false,
            };
        }

        pub fn isNone(self: Self) bool {
            return !self.isSome();
        }

        pub fn unwrap(self: Self) !T {
            return switch (self) {
                .some => |v| v,
                .none => error.NoneValue,
            };
        }

        // Functor instance
        pub fn map(self: Self, comptime U: type, f: *const fn (T) U) Option(U) {
            return switch (self) {
                .some => |v| Option(U).init(f(v)),
                .none => Option(U).none_value(),
            };
        }

        // Applicative instance
        pub fn pure(value: T) Self {
            return init(value);
        }

        pub fn ap(self: Self, comptime U: type, ff: Option(*const fn (T) U)) Option(U) {
            return switch (ff) {
                .some => |func| switch (self) {
                    .some => |v| Option(U).init(func(v)),
                    .none => Option(U).none_value(),
                },
                .none => Option(U).none_value(),
            };
        }

        // Monad instance
        pub fn bind(self: Self, comptime U: type, f: *const fn (T) Option(U)) Option(U) {
            return switch (self) {
                .some => |v| f(v),
                .none => Option(U).none_value(),
            };
        }

        pub fn flatMap(self: Self, comptime U: type, f: *const fn (T) Option(U)) Option(U) {
            return bind(self, U, f);
        }

        // Foldable instance
        pub fn foldLeft(self: Self, comptime U: type, initial: U, f: *const fn (U, T) U) U {
            return switch (self) {
                .some => |v| f(initial, v),
                .none => initial,
            };
        }

        pub fn foldRight(self: Self, comptime U: type, initial: U, f: *const fn (T, U) U) U {
            return switch (self) {
                .some => |v| f(v, initial),
                .none => initial,
            };
        }
    };
}

/// Example: Result type with HKT instances
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        err: E,

        const Self = @This();

        pub fn ok_value(value: T) Self {
            return .{ .ok = value };
        }

        pub fn err_value(err: E) Self {
            return .{ .err = err };
        }

        pub fn isOk(self: Self) bool {
            return switch (self) {
                .ok => true,
                .err => false,
            };
        }

        pub fn isErr(self: Self) bool {
            return !self.isOk();
        }

        pub fn unwrap(self: Self) !T {
            return switch (self) {
                .ok => |v| v,
                .err => error.ResultError,
            };
        }

        // Functor instance
        pub fn map(self: Self, comptime U: type, f: *const fn (T) U) Result(U, E) {
            return switch (self) {
                .ok => |v| Result(U, E).ok_value(f(v)),
                .err => |e| Result(U, E).err_value(e),
            };
        }

        // Monad instance
        pub fn bind(self: Self, comptime U: type, f: *const fn (T) Result(U, E)) Result(U, E) {
            return switch (self) {
                .ok => |v| f(v),
                .err => |e| Result(U, E).err_value(e),
            };
        }

        pub fn flatMap(self: Self, comptime U: type, f: *const fn (T) Result(U, E)) Result(U, E) {
            return bind(self, U, f);
        }

        // Error handling
        pub fn mapErr(self: Self, comptime F: type, f: *const fn (E) F) Result(T, F) {
            return switch (self) {
                .ok => |v| Result(T, F).ok_value(v),
                .err => |e| Result(T, F).err_value(f(e)),
            };
        }
    };
}

/// Example: List type with HKT instances
pub fn List(comptime T: type) type {
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

        // Functor instance
        pub fn map(self: Self, comptime U: type, f: *const fn (T) U) !List(U) {
            var result = try self.allocator.alloc(U, self.items.len);
            for (self.items, 0..) |item, i| {
                result[i] = f(item);
            }
            return List(U){
                .items = result,
                .allocator = self.allocator,
            };
        }

        // Monad instance
        pub fn bind(self: Self, comptime U: type, f: *const fn (T) List(U)) !List(U) {
            var total_len: usize = 0;
            var temp_lists = try self.allocator.alloc(List(U), self.items.len);
            defer self.allocator.free(temp_lists);

            for (self.items, 0..) |item, i| {
                temp_lists[i] = f(item);
                total_len += temp_lists[i].items.len;
            }

            var result = try self.allocator.alloc(U, total_len);
            var offset: usize = 0;
            for (temp_lists) |list| {
                @memcpy(result[offset .. offset + list.items.len], list.items);
                offset += list.items.len;
            }

            return List(U){
                .items = result,
                .allocator = self.allocator,
            };
        }

        // Foldable instance
        pub fn foldLeft(self: Self, comptime U: type, initial: U, f: *const fn (U, T) U) U {
            var acc = initial;
            for (self.items) |item| {
                acc = f(acc, item);
            }
            return acc;
        }

        pub fn foldRight(self: Self, comptime U: type, initial: U, f: *const fn (T, U) U) U {
            var acc = initial;
            var i = self.items.len;
            while (i > 0) {
                i -= 1;
                acc = f(self.items[i], acc);
            }
            return acc;
        }
    };
}

/// Type-level programming utilities
pub const TypeLevel = struct {
    /// Apply a type constructor to a type
    pub fn Apply(comptime F: type, comptime A: type) type {
        return F(A);
    }

    /// Compose two type constructors
    pub fn Compose(comptime F: type, comptime G: type) type {
        return struct {
            pub fn apply(comptime A: type) type {
                return F(G(A));
            }
        };
    }

    /// Identity type constructor
    pub fn Identity(comptime A: type) type {
        return A;
    }

    /// Const type constructor (ignores second parameter)
    pub fn Const(comptime A: type) type {
        return struct {
            pub fn apply(comptime B: type) type {
                _ = B;
                return A;
            }
        };
    }
};
