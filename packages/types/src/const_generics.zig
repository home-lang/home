const std = @import("std");

/// Const Generics - Compile-time value parameters for types
/// Allows types to be parameterized by constant values, not just other types
///
/// Example:
///   Array<T, N> where N is a compile-time constant
///   Vector<T, 3> - a 3-element vector of type T
pub const ConstGenerics = struct {
    allocator: std.mem.Allocator,
    const_params: std.StringHashMap(ConstParam),
    instantiations: std.ArrayList(Instantiation),

    pub const ConstParamKind = enum {
        integer,
        boolean,
        string,
        type_ref,
    };

    pub const ConstParam = struct {
        name: []const u8,
        kind: ConstParamKind,
        value: Value,
        constraint: ?Constraint,

        pub const Value = union(enum) {
            integer: i64,
            boolean: bool,
            string: []const u8,
            type_ref: []const u8,
            unresolved: void,
        };

        pub const Constraint = union(enum) {
            range: struct {
                min: i64,
                max: i64,
            },
            values: []const Value,
            type_constraint: []const u8,
        };
    };

    pub const Instantiation = struct {
        type_name: []const u8,
        const_args: []const ConstParam.Value,
        mangled_name: []const u8,
        generated: bool,
    };

    pub fn init(allocator: std.mem.Allocator) ConstGenerics {
        return .{
            .allocator = allocator,
            .const_params = std.StringHashMap(ConstParam).init(allocator),
            .instantiations = std.ArrayList(Instantiation).init(allocator),
        };
    }

    pub fn deinit(self: *ConstGenerics) void {
        self.const_params.deinit();
        self.instantiations.deinit();
    }

    /// Register a const generic parameter
    pub fn registerConstParam(
        self: *ConstGenerics,
        name: []const u8,
        kind: ConstParamKind,
        constraint: ?ConstParam.Constraint,
    ) !void {
        try self.const_params.put(name, .{
            .name = name,
            .kind = kind,
            .value = .{ .unresolved = {} },
            .constraint = constraint,
        });
    }

    /// Instantiate a type with const generic parameters
    pub fn instantiate(
        self: *ConstGenerics,
        type_name: []const u8,
        const_args: []const ConstParam.Value,
    ) ![]const u8 {
        // Check if already instantiated
        for (self.instantiations.items) |inst| {
            if (std.mem.eql(u8, inst.type_name, type_name) and
                self.argsEqual(inst.const_args, const_args))
            {
                return inst.mangled_name;
            }
        }

        // Generate mangled name
        const mangled = try self.mangleName(type_name, const_args);

        // Store instantiation
        try self.instantiations.append(.{
            .type_name = type_name,
            .const_args = try self.allocator.dupe(ConstParam.Value, const_args),
            .mangled_name = mangled,
            .generated = false,
        });

        return mangled;
    }

    /// Validate const parameter against constraints
    pub fn validateConstParam(
        self: *ConstGenerics,
        param: *const ConstParam,
        value: ConstParam.Value,
    ) !bool {
        _ = self;

        if (param.constraint) |constraint| {
            switch (constraint) {
                .range => |range| {
                    switch (value) {
                        .integer => |v| {
                            return v >= range.min and v <= range.max;
                        },
                        else => return false,
                    }
                },
                .values => |values| {
                    for (values) |allowed| {
                        if (self.valuesEqual(allowed, value)) {
                            return true;
                        }
                    }
                    return false;
                },
                .type_constraint => {
                    // Type checking would happen here
                    return true;
                },
            }
        }

        return true;
    }

    /// Generate mangled name for const generic instantiation
    fn mangleName(
        self: *ConstGenerics,
        type_name: []const u8,
        const_args: []const ConstParam.Value,
    ) ![]const u8 {
        var name = std.ArrayList(u8).init(self.allocator);
        defer name.deinit();

        try name.appendSlice(type_name);
        try name.append('_');

        for (const_args, 0..) |arg, i| {
            if (i > 0) try name.append('_');

            switch (arg) {
                .integer => |v| {
                    const str = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                    defer self.allocator.free(str);
                    try name.appendSlice(str);
                },
                .boolean => |v| {
                    try name.appendSlice(if (v) "true" else "false");
                },
                .string => |s| {
                    try name.appendSlice(s);
                },
                .type_ref => |t| {
                    try name.appendSlice(t);
                },
                .unresolved => {
                    try name.appendSlice("unresolved");
                },
            }
        }

        return name.toOwnedSlice();
    }

    fn argsEqual(self: *ConstGenerics, a: []const ConstParam.Value, b: []const ConstParam.Value) bool {
        if (a.len != b.len) return false;

        for (a, b) |arg_a, arg_b| {
            if (!self.valuesEqual(arg_a, arg_b)) return false;
        }

        return true;
    }

    fn valuesEqual(self: *ConstGenerics, a: ConstParam.Value, b: ConstParam.Value) bool {
        _ = self;

        if (@intFromEnum(a) != @intFromEnum(b)) return false;

        return switch (a) {
            .integer => |v_a| v_a == b.integer,
            .boolean => |v_a| v_a == b.boolean,
            .string => |v_a| std.mem.eql(u8, v_a, b.string),
            .type_ref => |v_a| std.mem.eql(u8, v_a, b.type_ref),
            .unresolved => true,
        };
    }
};

/// Example usage patterns
pub const Examples = struct {
    /// Fixed-size array with const generic size
    /// Array<T, N> where N is compile-time constant
    pub const ArrayExample = struct {
        element_type: []const u8,
        size: usize,

        pub fn create(comptime T: type, comptime N: usize) type {
            return struct {
                data: [N]T,

                pub fn init() @This() {
                    return .{ .data = undefined };
                }

                pub fn len(self: *const @This()) usize {
                    return self.data.len;
                }

                pub fn get(self: *const @This(), index: usize) ?T {
                    if (index >= N) return null;
                    return self.data[index];
                }

                pub fn set(self: *@This(), index: usize, value: T) !void {
                    if (index >= N) return error.IndexOutOfBounds;
                    self.data[index] = value;
                }
            };
        }
    };

    /// Vector with compile-time dimensions
    /// Vector<T, D> where D is dimensions (2D, 3D, 4D, etc.)
    pub const VectorExample = struct {
        pub fn create(comptime T: type, comptime D: usize) type {
            return struct {
                components: [D]T,

                pub fn init(values: [D]T) @This() {
                    return .{ .components = values };
                }

                pub fn dot(self: *const @This(), other: *const @This()) T {
                    var result: T = 0;
                    for (0..D) |i| {
                        result += self.components[i] * other.components[i];
                    }
                    return result;
                }

                pub fn magnitude(self: *const @This()) f64 {
                    var sum: f64 = 0;
                    for (0..D) |i| {
                        const val: f64 = @floatFromInt(self.components[i]);
                        sum += val * val;
                    }
                    return @sqrt(sum);
                }
            };
        }
    };

    /// Matrix with compile-time dimensions
    /// Matrix<T, R, C> where R=rows, C=columns
    pub const MatrixExample = struct {
        pub fn create(comptime T: type, comptime R: usize, comptime C: usize) type {
            return struct {
                data: [R][C]T,

                pub fn init() @This() {
                    return .{ .data = undefined };
                }

                pub fn get(self: *const @This(), row: usize, col: usize) ?T {
                    if (row >= R or col >= C) return null;
                    return self.data[row][col];
                }

                pub fn set(self: *@This(), row: usize, col: usize, value: T) !void {
                    if (row >= R or col >= C) return error.IndexOutOfBounds;
                    self.data[row][col] = value;
                }

                pub fn rows(self: *const @This()) usize {
                    _ = self;
                    return R;
                }

                pub fn cols(self: *const @This()) usize {
                    _ = self;
                    return C;
                }
            };
        }
    };

    /// Bounded integer with const generic bounds
    /// Bounded<MIN, MAX> ensures value is always in range
    pub const BoundedExample = struct {
        pub fn create(comptime T: type, comptime MIN: T, comptime MAX: T) type {
            return struct {
                value: T,

                pub fn init(v: T) !@This() {
                    if (v < MIN or v > MAX) {
                        return error.OutOfBounds;
                    }
                    return .{ .value = v };
                }

                pub fn get(self: *const @This()) T {
                    return self.value;
                }

                pub fn set(self: *@This(), v: T) !void {
                    if (v < MIN or v > MAX) {
                        return error.OutOfBounds;
                    }
                    self.value = v;
                }

                pub fn min() T {
                    return MIN;
                }

                pub fn max() T {
                    return MAX;
                }
            };
        }
    };
};

/// Const generic constraints and validation
pub const Constraints = struct {
    /// Range constraint for integer const generics
    pub fn RangeConstraint(comptime MIN: i64, comptime MAX: i64) type {
        return struct {
            pub fn validate(value: i64) bool {
                return value >= MIN and value <= MAX;
            }

            pub fn min() i64 {
                return MIN;
            }

            pub fn max() i64 {
                return MAX;
            }
        };
    }

    /// Power of 2 constraint
    pub fn PowerOfTwoConstraint() type {
        return struct {
            pub fn validate(value: i64) bool {
                if (value <= 0) return false;
                return (value & (value - 1)) == 0;
            }
        };
    }

    /// Type equality constraint
    pub fn TypeEqualityConstraint(comptime T: type) type {
        return struct {
            pub fn validate(comptime U: type) bool {
                return T == U;
            }
        };
    }
};
