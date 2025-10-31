// Multi-Pass Optimization Framework
// Implements various optimization passes for improving code generation

const std = @import("std");
const ast = @import("ast");

/// Optimization level
pub const OptLevel = enum {
    none, // -O0: No optimizations
    basic, // -O1: Basic optimizations
    standard, // -O2: Standard optimizations
    aggressive, // -O3: Aggressive optimizations
};

/// Intermediate Representation (IR) for optimization
pub const IR = struct {
    pub const Value = union(enum) {
        constant: i64,
        register: u8,
        stack_slot: u8,
        global: []const u8,

        pub fn hash(self: Value) u64 {
            var hasher = std.hash.Wyhash.init(0);
            switch (self) {
                .constant => |c| std.hash.autoHash(&hasher, c),
                .register => |r| std.hash.autoHash(&hasher, r),
                .stack_slot => |s| std.hash.autoHash(&hasher, s),
                .global => |g| hasher.update(g),
            }
            return hasher.final();
        }

        pub fn eql(self: Value, other: Value) bool {
            if (@as(@typeInfo(Value).@"union".tag_type.?, self) != @as(@typeInfo(Value).@"union".tag_type.?, other)) {
                return false;
            }
            return switch (self) {
                .constant => |c| c == other.constant,
                .register => |r| r == other.register,
                .stack_slot => |s| s == other.stack_slot,
                .global => |g| std.mem.eql(u8, g, other.global),
            };
        }
    };

    // Common operation types
    pub const BinOp = struct { dest: Value, lhs: Value, rhs: Value };
    pub const MemOp = struct { dest: Value, addr: Value, offset: i32 };
    pub const StoreOp = struct { addr: Value, offset: i32, value: Value };
    pub const MoveOp = struct { dest: Value, src: Value };
    pub const VecOp = struct { dest: Value, lhs: Value, rhs: Value, width: u8 };

    pub const Instruction = union(enum) {
        // Arithmetic
        add: BinOp,
        sub: BinOp,
        mul: BinOp,
        div: BinOp,

        // Bitwise
        and_: BinOp,
        or_: BinOp,
        xor: BinOp,
        shl: BinOp,
        shr: BinOp,

        // Memory
        load: MemOp,
        store: StoreOp,
        move: MoveOp,

        // Control flow
        jump: struct { target: usize },
        branch: struct { condition: Value, true_target: usize, false_target: usize },
        call: struct { func: []const u8, args: []const Value, dest: ?Value },
        ret: struct { value: ?Value },

        // Comparisons
        cmp_eq: BinOp,
        cmp_ne: BinOp,
        cmp_lt: BinOp,
        cmp_le: BinOp,
        cmp_gt: BinOp,
        cmp_ge: BinOp,

        // SIMD operations
        vec_add: VecOp,
        vec_mul: VecOp,
        vec_load: struct { dest: Value, addr: Value, width: u8 },
        vec_store: struct { addr: Value, value: Value, width: u8 },

        // Special
        nop: void,
    };

    pub const BasicBlock = struct {
        id: usize,
        instructions: std.ArrayList(Instruction),
        predecessors: std.ArrayList(usize),
        successors: std.ArrayList(usize),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, id: usize) BasicBlock {
            return .{
                .id = id,
                .instructions = std.ArrayList(Instruction){},
                .predecessors = std.ArrayList(usize){},
                .successors = std.ArrayList(usize){},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *BasicBlock, allocator: std.mem.Allocator) void {
            self.instructions.deinit(allocator);
            self.predecessors.deinit(allocator);
            self.successors.deinit(allocator);
        }
    };

    pub const Function = struct {
        name: []const u8,
        blocks: std.ArrayList(BasicBlock),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, name: []const u8) Function {
            return .{
                .name = name,
                .blocks = std.ArrayList(BasicBlock){},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
            for (self.blocks.items) |*block| {
                block.deinit(allocator);
            }
            self.blocks.deinit(allocator);
        }
    };
};

/// Optimization Pass interface
pub const Pass = struct {
    name: []const u8,
    run: *const fn (func: *IR.Function) anyerror!bool,
};

/// Dead Code Elimination
pub fn deadCodeElimination(func: *IR.Function) !bool {
    var changed = false;

    const ValueContext = struct {
        pub fn hash(self: @This(), v: IR.Value) u64 {
            _ = self;
            return v.hash();
        }
        pub fn eql(self: @This(), a: IR.Value, b: IR.Value) bool {
            _ = self;
            return a.eql(b);
        }
    };

    // Mark used values
    var used = std.HashMap(IR.Value, void, ValueContext, std.hash_map.default_max_load_percentage).init(func.allocator);
    defer used.deinit();

    // First pass: mark all values that are used
    for (func.blocks.items) |*block| {
        for (block.instructions.items) |inst| {
            switch (inst) {
                .add, .sub, .mul, .div, .and_, .or_, .xor, .shl, .shr => |op| {
                    try used.put(op.lhs, {});
                    try used.put(op.rhs, {});
                },
                .load => |op| try used.put(op.addr, {}),
                .store => |op| {
                    try used.put(op.addr, {});
                    try used.put(op.value, {});
                },
                .move => |op| try used.put(op.src, {}),
                .branch => |op| try used.put(op.condition, {}),
                .ret => |op| {
                    if (op.value) |val| try used.put(val, {});
                },
                .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => |op| {
                    try used.put(op.lhs, {});
                    try used.put(op.rhs, {});
                },
                .vec_add, .vec_mul => |op| {
                    try used.put(op.lhs, {});
                    try used.put(op.rhs, {});
                },
                .vec_load => |op| try used.put(op.addr, {}),
                .vec_store => |op| {
                    try used.put(op.addr, {});
                    try used.put(op.value, {});
                },
                else => {},
            }
        }
    }

    // Second pass: remove instructions that define unused values
    for (func.blocks.items) |*block| {
        var i: usize = 0;
        while (i < block.instructions.items.len) {
            const inst = block.instructions.items[i];
            var remove = false;

            switch (inst) {
                .add, .sub, .mul, .div, .and_, .or_, .xor, .shl, .shr => |op| {
                    if (!used.contains(op.dest)) remove = true;
                },
                .load => |op| {
                    if (!used.contains(op.dest)) remove = true;
                },
                .move => |op| {
                    if (!used.contains(op.dest)) remove = true;
                },
                .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => |op| {
                    if (!used.contains(op.dest)) remove = true;
                },
                .vec_add, .vec_mul => |op| {
                    if (!used.contains(op.dest)) remove = true;
                },
                .vec_load => |op| {
                    if (!used.contains(op.dest)) remove = true;
                },
                else => {},
            }

            if (remove) {
                _ = block.instructions.orderedRemove(i);
                changed = true;
            } else {
                i += 1;
            }
        }
    }

    return changed;
}

/// Constant Folding
pub fn constantFolding(func: *IR.Function) !bool {
    var changed = false;

    for (func.blocks.items) |*block| {
        for (block.instructions.items, 0..) |*inst, i| {
            switch (inst.*) {
                .add => |op| {
                    if (op.lhs == .constant and op.rhs == .constant) {
                        inst.* = .{ .move = .{
                            .dest = op.dest,
                            .src = .{ .constant = op.lhs.constant + op.rhs.constant },
                        } };
                        changed = true;
                    }
                },
                .sub => |op| {
                    if (op.lhs == .constant and op.rhs == .constant) {
                        inst.* = .{ .move = .{
                            .dest = op.dest,
                            .src = .{ .constant = op.lhs.constant - op.rhs.constant },
                        } };
                        changed = true;
                    }
                },
                .mul => |op| {
                    if (op.lhs == .constant and op.rhs == .constant) {
                        inst.* = .{ .move = .{
                            .dest = op.dest,
                            .src = .{ .constant = op.lhs.constant * op.rhs.constant },
                        } };
                        changed = true;
                    }
                },
                .div => |op| {
                    if (op.lhs == .constant and op.rhs == .constant and op.rhs.constant != 0) {
                        inst.* = .{ .move = .{
                            .dest = op.dest,
                            .src = .{ .constant = @divTrunc(op.lhs.constant, op.rhs.constant) },
                        } };
                        changed = true;
                    }
                },
                else => {},
            }
            _ = i;
        }
    }

    return changed;
}

/// Common Subexpression Elimination
pub fn commonSubexpressionElimination(func: *IR.Function) !bool {
    var changed = false;

    // Map of expression hashes to their computed register/value
    var expressions = std.AutoHashMap(u64, u8).init(func.allocator);
    defer expressions.deinit();

    for (func.blocks.items) |*block| {
        expressions.clearRetainingCapacity();

        for (block.instructions.items) |*inst| {
            switch (inst.*) {
                .add, .sub, .mul, .div => |op| {
                    // Only optimize if destination is a register
                    if (op.dest != .register) continue;

                    // Create a hash of the operation
                    var hasher = std.hash.Wyhash.init(0);
                    std.hash.autoHash(&hasher, @intFromEnum(inst.*));
                    std.hash.autoHash(&hasher, op.lhs.hash());
                    std.hash.autoHash(&hasher, op.rhs.hash());
                    const hash = hasher.final();

                    if (expressions.get(hash)) |prev_reg| {
                        // Replace with move from previous result
                        inst.* = .{ .move = .{
                            .dest = op.dest,
                            .src = .{ .register = prev_reg },
                        } };
                        changed = true;
                    } else {
                        try expressions.put(hash, op.dest.register);
                    }
                },
                else => {},
            }
        }
    }

    return changed;
}

/// Copy Propagation
pub fn copyPropagation(func: *IR.Function) !bool {
    var changed = false;

    const ValueContext = struct {
        pub fn hash(self: @This(), v: IR.Value) u64 {
            _ = self;
            return v.hash();
        }
        pub fn eql(self: @This(), a: IR.Value, b: IR.Value) bool {
            _ = self;
            return a.eql(b);
        }
    };

    // Map of destinations to their source values
    var copies = std.HashMap(IR.Value, IR.Value, ValueContext, std.hash_map.default_max_load_percentage).init(func.allocator);
    defer copies.deinit();

    for (func.blocks.items) |*block| {
        copies.clearRetainingCapacity();

        for (block.instructions.items) |*inst| {
            // First, propagate known copies into this instruction
            switch (inst.*) {
                .add => |*op| {
                    if (copies.get(op.lhs)) |src| {
                        op.lhs = src;
                        changed = true;
                    }
                    if (copies.get(op.rhs)) |src| {
                        op.rhs = src;
                        changed = true;
                    }
                },
                .move => |op| {
                    if (copies.get(op.src)) |src| {
                        inst.* = .{ .move = .{ .dest = op.dest, .src = src } };
                        changed = true;
                    }
                    // Record this copy
                    try copies.put(op.dest, op.src);
                },
                else => {},
            }
        }
    }

    return changed;
}

/// Strength Reduction (replace expensive ops with cheaper ones)
pub fn strengthReduction(func: *IR.Function) !bool {
    var changed = false;

    for (func.blocks.items) |*block| {
        for (block.instructions.items) |*inst| {
            switch (inst.*) {
                .mul => |op| {
                    // Replace multiplication by power of 2 with shift
                    if (op.rhs == .constant) {
                        const val = op.rhs.constant;
                        if (val > 0 and (val & (val - 1)) == 0) {
                            // It's a power of 2
                            const shift = @ctz(val);
                            inst.* = .{ .shl = .{
                                .dest = op.dest,
                                .lhs = op.lhs,
                                .rhs = .{ .constant = shift },
                            } };
                            changed = true;
                        }
                    }
                },
                .div => |op| {
                    // Replace division by power of 2 with shift
                    if (op.rhs == .constant) {
                        const val = op.rhs.constant;
                        if (val > 0 and (val & (val - 1)) == 0) {
                            const shift = @ctz(val);
                            inst.* = .{ .shr = .{
                                .dest = op.dest,
                                .lhs = op.lhs,
                                .rhs = .{ .constant = shift },
                            } };
                            changed = true;
                        }
                    }
                },
                else => {},
            }
        }
    }

    return changed;
}

/// Loop-Invariant Code Motion
pub fn loopInvariantCodeMotion(func: *IR.Function) !bool {
    // This is a simplified version - full LICM requires loop detection
    _ = func;
    return false;
}

/// Optimizer with configurable passes
pub const Optimizer = struct {
    allocator: std.mem.Allocator,
    opt_level: OptLevel,
    passes: std.ArrayList(Pass),

    pub fn init(allocator: std.mem.Allocator, opt_level: OptLevel) !Optimizer {
        var optimizer = Optimizer{
            .allocator = allocator,
            .opt_level = opt_level,
            .passes = std.ArrayList(Pass){},
        };

        // Configure passes based on optimization level
        switch (opt_level) {
            .none => {},
            .basic => {
                try optimizer.passes.append(allocator, .{ .name = "constant-folding", .run = constantFolding });
                try optimizer.passes.append(allocator, .{ .name = "dce", .run = deadCodeElimination });
            },
            .standard => {
                try optimizer.passes.append(allocator, .{ .name = "constant-folding", .run = constantFolding });
                try optimizer.passes.append(allocator, .{ .name = "strength-reduction", .run = strengthReduction });
                try optimizer.passes.append(allocator, .{ .name = "cse", .run = commonSubexpressionElimination });
                try optimizer.passes.append(allocator, .{ .name = "copy-propagation", .run = copyPropagation });
                try optimizer.passes.append(allocator, .{ .name = "dce", .run = deadCodeElimination });
            },
            .aggressive => {
                try optimizer.passes.append(allocator, .{ .name = "constant-folding", .run = constantFolding });
                try optimizer.passes.append(allocator, .{ .name = "strength-reduction", .run = strengthReduction });
                try optimizer.passes.append(allocator, .{ .name = "cse", .run = commonSubexpressionElimination });
                try optimizer.passes.append(allocator, .{ .name = "copy-propagation", .run = copyPropagation });
                try optimizer.passes.append(allocator, .{ .name = "dce", .run = deadCodeElimination });
                try optimizer.passes.append(allocator, .{ .name = "licm", .run = loopInvariantCodeMotion });
                // Run passes multiple times for aggressive optimization
                try optimizer.passes.append(allocator, .{ .name = "constant-folding", .run = constantFolding });
                try optimizer.passes.append(allocator, .{ .name = "dce", .run = deadCodeElimination });
            },
        }

        return optimizer;
    }

    pub fn deinit(self: *Optimizer, allocator: std.mem.Allocator) void {
        self.passes.deinit(allocator);
    }

    /// Run all configured optimization passes on a function
    pub fn optimize(self: *Optimizer, func: *IR.Function) !void {
        for (self.passes.items) |pass| {
            _ = try pass.run(func);
        }
    }

    /// Run optimization passes until fixpoint (no more changes)
    pub fn optimizeToFixpoint(self: *Optimizer, func: *IR.Function, max_iterations: usize) !void {
        var iteration: usize = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            var changed = false;
            for (self.passes.items) |pass| {
                if (try pass.run(func)) {
                    changed = true;
                }
            }
            if (!changed) break;
        }
    }
};

// Tests
test "constant folding" {
    const testing = std.testing;

    var func = IR.Function.init(testing.allocator, "test");
    defer func.deinit(testing.allocator);

    var block = IR.BasicBlock.init(testing.allocator, 0);

    // Add: r0 = 2 + 3
    try block.instructions.append(testing.allocator, .{ .add = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .constant = 2 },
        .rhs = .{ .constant = 3 },
    } });

    try func.blocks.append(testing.allocator, block);

    const changed = try constantFolding(&func);
    try testing.expect(changed);

    // Should be transformed to: r0 = 5
    try testing.expect(func.blocks.items[0].instructions.items[0] == .move);
}

test "strength reduction" {
    const testing = std.testing;

    var func = IR.Function.init(testing.allocator, "test");
    defer func.deinit(testing.allocator);

    var block = IR.BasicBlock.init(testing.allocator, 0);

    // Mul: r0 = r1 * 8
    try block.instructions.append(testing.allocator, .{ .mul = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .constant = 8 },
    } });

    try func.blocks.append(testing.allocator, block);

    const changed = try strengthReduction(&func);
    try testing.expect(changed);

    // Should be transformed to: r0 = r1 << 3
    try testing.expect(func.blocks.items[0].instructions.items[0] == .shl);
}

test "optimizer" {
    const testing = std.testing;

    var optimizer = try Optimizer.init(testing.allocator, .standard);
    defer optimizer.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), optimizer.passes.items.len);
}
