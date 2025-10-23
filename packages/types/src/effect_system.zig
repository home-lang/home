const std = @import("std");

/// Effect System - Track and manage computational effects at the type level
/// Effects include: IO, State, Exceptions, Async, etc.
///
/// Allows reasoning about side effects in a pure functional way
/// and enables algebraic effects and handlers
pub const EffectSystem = struct {
    allocator: std.mem.Allocator,
    effects: std.StringHashMap(EffectDef),
    handlers: std.StringHashMap(EffectHandler),
    effect_stack: std.ArrayList([]const u8),

    pub const EffectKind = enum {
        io,
        state,
        exception,
        async_effect,
        nondeterminism,
        logging,
        random,
        custom,
    };

    pub const EffectDef = struct {
        name: []const u8,
        kind: EffectKind,
        operations: []const Operation,

        pub const Operation = struct {
            name: []const u8,
            params: []const []const u8,
            return_type: []const u8,
        };
    };

    pub const EffectHandler = struct {
        effect_name: []const u8,
        implementation: *const fn ([]const u8, []const ?*anyopaque) anyerror!?*anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator) EffectSystem {
        return .{
            .allocator = allocator,
            .effects = std.StringHashMap(EffectDef).init(allocator),
            .handlers = std.StringHashMap(EffectHandler).init(allocator),
            .effect_stack = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *EffectSystem) void {
        self.effects.deinit();
        self.handlers.deinit();
        self.effect_stack.deinit();
    }

    /// Register an effect definition
    pub fn registerEffect(
        self: *EffectSystem,
        name: []const u8,
        kind: EffectKind,
        operations: []const EffectDef.Operation,
    ) !void {
        try self.effects.put(name, .{
            .name = name,
            .kind = kind,
            .operations = operations,
        });
    }

    /// Register an effect handler
    pub fn registerHandler(
        self: *EffectSystem,
        effect_name: []const u8,
        implementation: *const fn ([]const u8, []const ?*anyopaque) anyerror!?*anyopaque,
    ) !void {
        try self.handlers.put(effect_name, .{
            .effect_name = effect_name,
            .implementation = implementation,
        });
    }

    /// Perform an effect operation
    pub fn perform(
        self: *EffectSystem,
        effect_name: []const u8,
        operation: []const u8,
        args: []const ?*anyopaque,
    ) !?*anyopaque {
        const handler = self.handlers.get(effect_name) orelse return error.NoHandler;
        return try handler.implementation(operation, args);
    }
};

/// Effect - Base type for all effects
pub fn Effect(comptime E: type, comptime A: type) type {
    return struct {
        effect_type: E,
        computation: *const fn (E) A,

        const Self = @This();

        pub fn init(effect: E, comp: *const fn (E) A) Self {
            return .{
                .effect_type = effect,
                .computation = comp,
            };
        }

        pub fn run(self: Self) A {
            return self.computation(self.effect_type);
        }

        pub fn map(self: Self, comptime B: type, f: *const fn (A) B) Effect(E, B) {
            const comp = struct {
                fn call(e: E) B {
                    const a = self.computation(e);
                    return f(a);
                }
            }.call;

            return Effect(E, B).init(self.effect_type, comp);
        }
    };
}

/// IO Effect - Side-effecting I/O operations
pub const IO = struct {
    pub fn of(comptime A: type) type {
        return struct {
            computation: *const fn () A,

            const Self = @This();

            pub fn init(comp: *const fn () A) Self {
                return .{ .computation = comp };
            }

            pub fn run(self: Self) A {
                return self.computation();
            }

            pub fn map(self: Self, comptime B: type, f: *const fn (A) B) IO.of(B) {
                const comp = struct {
                    fn call() B {
                        const a = self.computation();
                        return f(a);
                    }
                }.call;

                return IO.of(B).init(comp);
            }

            pub fn flatMap(self: Self, comptime B: type, f: *const fn (A) IO.of(B)) IO.of(B) {
                const comp = struct {
                    fn call() B {
                        const a = self.computation();
                        const io_b = f(a);
                        return io_b.run();
                    }
                }.call;

                return IO.of(B).init(comp);
            }
        };
    }

    pub fn pure(comptime A: type, value: A) IO.of(A) {
        const comp = struct {
            fn call() A {
                return value;
            }
        }.call;

        return IO.of(A).init(comp);
    }
};

/// State Effect - Stateful computations
pub fn State(comptime S: type, comptime A: type) type {
    return struct {
        run_state: *const fn (S) struct { value: A, state: S },

        const Self = @This();

        pub fn init(f: *const fn (S) struct { value: A, state: S }) Self {
            return .{ .run_state = f };
        }

        pub fn run(self: Self, initial_state: S) struct { value: A, state: S } {
            return self.run_state(initial_state);
        }

        pub fn map(self: Self, comptime B: type, f: *const fn (A) B) State(S, B) {
            const run_fn = struct {
                fn call(s: S) struct { value: B, state: S } {
                    const result = self.run_state(s);
                    return .{
                        .value = f(result.value),
                        .state = result.state,
                    };
                }
            }.call;

            return State(S, B).init(run_fn);
        }

        pub fn flatMap(self: Self, comptime B: type, f: *const fn (A) State(S, B)) State(S, B) {
            const run_fn = struct {
                fn call(s: S) struct { value: B, state: S } {
                    const result1 = self.run_state(s);
                    const state_b = f(result1.value);
                    return state_b.run(result1.state);
                }
            }.call;

            return State(S, B).init(run_fn);
        }
    };
}

/// Reader Effect - Environment/configuration access
pub fn Reader(comptime R: type, comptime A: type) type {
    return struct {
        run_reader: *const fn (R) A,

        const Self = @This();

        pub fn init(f: *const fn (R) A) Self {
            return .{ .run_reader = f };
        }

        pub fn run(self: Self, env: R) A {
            return self.run_reader(env);
        }

        pub fn map(self: Self, comptime B: type, f: *const fn (A) B) Reader(R, B) {
            const run_fn = struct {
                fn call(r: R) B {
                    return f(self.run_reader(r));
                }
            }.call;

            return Reader(R, B).init(run_fn);
        }

        pub fn flatMap(self: Self, comptime B: type, f: *const fn (A) Reader(R, B)) Reader(R, B) {
            const run_fn = struct {
                fn call(r: R) B {
                    const a = self.run_reader(r);
                    const reader_b = f(a);
                    return reader_b.run(r);
                }
            }.call;

            return Reader(R, B).init(run_fn);
        }

        pub fn ask() Reader(R, R) {
            const run_fn = struct {
                fn call(r: R) R {
                    return r;
                }
            }.call;

            return Reader(R, R).init(run_fn);
        }
    };
}

/// Writer Effect - Logging/output accumulation
pub fn Writer(comptime W: type, comptime A: type) type {
    return struct {
        value: A,
        log: W,

        const Self = @This();

        pub fn init(v: A, l: W) Self {
            return .{ .value = v, .log = l };
        }

        pub fn run(self: Self) struct { value: A, log: W } {
            return .{ .value = self.value, .log = self.log };
        }

        pub fn map(self: Self, comptime B: type, f: *const fn (A) B) Writer(W, B) {
            return Writer(W, B).init(f(self.value), self.log);
        }

        pub fn tell(msg: W) Writer(W, void) {
            return Writer(W, void).init({}, msg);
        }
    };
}

/// Async Effect - Asynchronous computations
pub fn Async(comptime A: type) type {
    return struct {
        computation: *const fn () callconv(.Async) A,

        const Self = @This();

        pub fn init(comp: *const fn () callconv(.Async) A) Self {
            return .{ .computation = comp };
        }

        pub fn run(self: Self) A {
            return self.computation();
        }

        pub fn map(self: Self, comptime B: type, f: *const fn (A) B) Async(B) {
            const comp = struct {
                fn call() callconv(.Async) B {
                    const a = self.computation();
                    return f(a);
                }
            }.call;

            return Async(B).init(comp);
        }
    };
}

/// Exception Effect - Error handling
pub fn Exceptional(comptime E: type, comptime A: type) type {
    return union(enum) {
        success: A,
        failure: E,

        const Self = @This();

        pub fn ok(value: A) Self {
            return .{ .success = value };
        }

        pub fn err(error_value: E) Self {
            return .{ .failure = error_value };
        }

        pub fn isOk(self: Self) bool {
            return switch (self) {
                .success => true,
                .failure => false,
            };
        }

        pub fn map(self: Self, comptime B: type, f: *const fn (A) B) Exceptional(E, B) {
            return switch (self) {
                .success => |v| Exceptional(E, B).ok(f(v)),
                .failure => |e| Exceptional(E, B).err(e),
            };
        }

        pub fn flatMap(
            self: Self,
            comptime B: type,
            f: *const fn (A) Exceptional(E, B),
        ) Exceptional(E, B) {
            return switch (self) {
                .success => |v| f(v),
                .failure => |e| Exceptional(E, B).err(e),
            };
        }

        pub fn catch_error(self: Self, handler: *const fn (E) A) A {
            return switch (self) {
                .success => |v| v,
                .failure => |e| handler(e),
            };
        }
    };
}

/// Free Monad - Generic effect composition
pub fn Free(comptime F: type, comptime A: type) type {
    return union(enum) {
        pure: A,
        free: F,

        const Self = @This();

        pub fn pure_value(value: A) Self {
            return .{ .pure = value };
        }

        pub fn free_value(f: F) Self {
            return .{ .free = f };
        }

        pub fn map(self: Self, comptime B: type, f: *const fn (A) B) Free(F, B) {
            return switch (self) {
                .pure => |v| Free(F, B).pure_value(f(v)),
                .free => |effect| Free(F, B).free_value(effect),
            };
        }

        pub fn flatMap(self: Self, comptime B: type, f: *const fn (A) Free(F, B)) Free(F, B) {
            return switch (self) {
                .pure => |v| f(v),
                .free => |effect| Free(F, B).free_value(effect),
            };
        }
    };
}

/// Effect Row - Multiple effects combined
pub const EffectRow = struct {
    effects: []const []const u8,

    pub fn init(effects: []const []const u8) EffectRow {
        return .{ .effects = effects };
    }

    pub fn contains(self: EffectRow, effect: []const u8) bool {
        for (self.effects) |e| {
            if (std.mem.eql(u8, e, effect)) return true;
        }
        return false;
    }

    pub fn union_with(self: EffectRow, other: EffectRow, allocator: std.mem.Allocator) !EffectRow {
        var combined = std.ArrayList([]const u8).init(allocator);
        defer combined.deinit();

        for (self.effects) |e| {
            try combined.append(e);
        }

        for (other.effects) |e| {
            if (!self.contains(e)) {
                try combined.append(e);
            }
        }

        return EffectRow.init(try combined.toOwnedSlice());
    }
};

/// Eff - Extensible effect type
pub fn Eff(comptime R: type, comptime A: type) type {
    return struct {
        effects: EffectRow,
        computation: *const fn (R) A,

        const Self = @This();

        pub fn init(effects: EffectRow, comp: *const fn (R) A) Self {
            return .{
                .effects = effects,
                .computation = comp,
            };
        }

        pub fn run(self: Self, env: R) A {
            return self.computation(env);
        }

        pub fn map(self: Self, comptime B: type, f: *const fn (A) B) Eff(R, B) {
            const comp = struct {
                fn call(r: R) B {
                    return f(self.computation(r));
                }
            }.call;

            return Eff(R, B).init(self.effects, comp);
        }
    };
}
