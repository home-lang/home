// Instruction Selection with Pattern Matching
// Tree-pattern matching for optimal instruction selection

const std = @import("std");
const IR = @import("optimizer.zig").IR;

/// Target architecture for instruction selection
pub const Target = enum {
    x64,
    arm64,
    riscv64,
};

/// Cost model for instruction selection
pub const Cost = u32;

/// Pattern for matching IR instructions
pub const Pattern = struct {
    /// Pattern type
    kind: PatternKind,
    /// Cost of using this pattern
    cost: Cost,
    /// Target instruction mnemonic
    mnemonic: []const u8,

    pub const PatternKind = union(enum) {
        // Arithmetic patterns
        add_reg_reg,
        add_reg_imm,
        sub_reg_reg,
        sub_reg_imm,
        mul_reg_reg,
        mul_reg_power_of_two, // Can use shift instead
        div_reg_reg,

        // Memory patterns
        load_direct,
        load_indexed,
        load_offset,
        store_direct,
        store_indexed,
        store_offset,

        // Complex patterns
        lea, // Load effective address (x64)
        madd, // Multiply-add (ARM64: r = a + b * c)
        msub, // Multiply-subtract (ARM64: r = a - b * c)
        shift_add, // Shifted add (ARM64: r = a + (b << imm))

        // Move patterns
        move_reg,
        move_imm,
        zero, // Special case for moving 0
    };
};

/// Instruction selector using pattern matching
pub const InstructionSelector = struct {
    allocator: std.mem.Allocator,
    target: Target,
    patterns: std.ArrayList(Pattern),

    pub fn init(allocator: std.mem.Allocator, target: Target) !InstructionSelector {
        var selector = InstructionSelector{
            .allocator = allocator,
            .target = target,
            .patterns = std.ArrayList(Pattern){},
        };

        try selector.initializePatterns();
        return selector;
    }

    pub fn deinit(self: *InstructionSelector) void {
        self.patterns.deinit(self.allocator);
    }

    fn initializePatterns(self: *InstructionSelector) !void {
        switch (self.target) {
            .x64 => {
                // x64 patterns
                try self.patterns.append(self.allocator, .{ .kind = .add_reg_reg, .cost = 1, .mnemonic = "add" });
                try self.patterns.append(self.allocator, .{ .kind = .add_reg_imm, .cost = 1, .mnemonic = "add" });
                try self.patterns.append(self.allocator, .{ .kind = .sub_reg_reg, .cost = 1, .mnemonic = "sub" });
                try self.patterns.append(self.allocator, .{ .kind = .sub_reg_imm, .cost = 1, .mnemonic = "sub" });
                try self.patterns.append(self.allocator, .{ .kind = .mul_reg_reg, .cost = 3, .mnemonic = "imul" });
                try self.patterns.append(self.allocator, .{ .kind = .mul_reg_power_of_two, .cost = 1, .mnemonic = "shl" });
                try self.patterns.append(self.allocator, .{ .kind = .lea, .cost = 1, .mnemonic = "lea" });
                try self.patterns.append(self.allocator, .{ .kind = .move_reg, .cost = 1, .mnemonic = "mov" });
                try self.patterns.append(self.allocator, .{ .kind = .move_imm, .cost = 1, .mnemonic = "mov" });
                try self.patterns.append(self.allocator, .{ .kind = .zero, .cost = 1, .mnemonic = "xor" });
            },
            .arm64 => {
                // ARM64 patterns
                try self.patterns.append(self.allocator, .{ .kind = .add_reg_reg, .cost = 1, .mnemonic = "add" });
                try self.patterns.append(self.allocator, .{ .kind = .add_reg_imm, .cost = 1, .mnemonic = "add" });
                try self.patterns.append(self.allocator, .{ .kind = .sub_reg_reg, .cost = 1, .mnemonic = "sub" });
                try self.patterns.append(self.allocator, .{ .kind = .sub_reg_imm, .cost = 1, .mnemonic = "sub" });
                try self.patterns.append(self.allocator, .{ .kind = .mul_reg_reg, .cost = 3, .mnemonic = "mul" });
                try self.patterns.append(self.allocator, .{ .kind = .madd, .cost = 3, .mnemonic = "madd" });
                try self.patterns.append(self.allocator, .{ .kind = .msub, .cost = 3, .mnemonic = "msub" });
                try self.patterns.append(self.allocator, .{ .kind = .shift_add, .cost = 1, .mnemonic = "add" });
                try self.patterns.append(self.allocator, .{ .kind = .move_reg, .cost = 1, .mnemonic = "mov" });
                try self.patterns.append(self.allocator, .{ .kind = .move_imm, .cost = 1, .mnemonic = "mov" });
                try self.patterns.append(self.allocator, .{ .kind = .zero, .cost = 1, .mnemonic = "mov" });
            },
            .riscv64 => {
                // RISC-V patterns
                try self.patterns.append(self.allocator, .{ .kind = .add_reg_reg, .cost = 1, .mnemonic = "add" });
                try self.patterns.append(self.allocator, .{ .kind = .add_reg_imm, .cost = 1, .mnemonic = "addi" });
                try self.patterns.append(self.allocator, .{ .kind = .sub_reg_reg, .cost = 1, .mnemonic = "sub" });
                try self.patterns.append(self.allocator, .{ .kind = .mul_reg_reg, .cost = 3, .mnemonic = "mul" });
                try self.patterns.append(self.allocator, .{ .kind = .move_reg, .cost = 1, .mnemonic = "mv" });
                try self.patterns.append(self.allocator, .{ .kind = .move_imm, .cost = 1, .mnemonic = "li" });
                try self.patterns.append(self.allocator, .{ .kind = .zero, .cost = 1, .mnemonic = "li" });
            },
        }
    }

    /// Select best instruction pattern for an IR instruction
    pub fn selectInstruction(self: *InstructionSelector, inst: IR.Instruction) !?Pattern {
        switch (inst) {
            .add => |op| {
                // Check for LEA pattern (x64 only): add with potential scale
                if (self.target == .x64) {
                    return Pattern{ .kind = .lea, .cost = 1, .mnemonic = "lea" };
                }

                // Check for immediate add
                if (op.rhs == .constant) {
                    return Pattern{ .kind = .add_reg_imm, .cost = 1, .mnemonic = self.getMnemonic(.add_reg_imm) };
                }

                // Check for shift + add (ARM64)
                if (self.target == .arm64) {
                    // TODO: detect if one operand is a shift
                    return Pattern{ .kind = .shift_add, .cost = 1, .mnemonic = "add" };
                }

                // Default: register + register
                return Pattern{ .kind = .add_reg_reg, .cost = 1, .mnemonic = self.getMnemonic(.add_reg_reg) };
            },

            .sub => |op| {
                if (op.rhs == .constant) {
                    return Pattern{ .kind = .sub_reg_imm, .cost = 1, .mnemonic = self.getMnemonic(.sub_reg_imm) };
                }
                return Pattern{ .kind = .sub_reg_reg, .cost = 1, .mnemonic = self.getMnemonic(.sub_reg_reg) };
            },

            .mul => |op| {
                // Check for power-of-two multiplication (can use shift)
                if (op.rhs == .constant) {
                    const val = op.rhs.constant;
                    if (val > 0 and (val & (val - 1)) == 0) {
                        // Power of two - use shift
                        return Pattern{ .kind = .mul_reg_power_of_two, .cost = 1, .mnemonic = self.getMnemonic(.mul_reg_power_of_two) };
                    }
                }
                return Pattern{ .kind = .mul_reg_reg, .cost = 3, .mnemonic = self.getMnemonic(.mul_reg_reg) };
            },

            .move => |op| {
                // Check for zero move
                if (op.src == .constant and op.src.constant == 0) {
                    return Pattern{ .kind = .zero, .cost = 1, .mnemonic = self.getMnemonic(.zero) };
                }

                // Check for immediate move
                if (op.src == .constant) {
                    return Pattern{ .kind = .move_imm, .cost = 1, .mnemonic = self.getMnemonic(.move_imm) };
                }

                return Pattern{ .kind = .move_reg, .cost = 1, .mnemonic = self.getMnemonic(.move_reg) };
            },

            else => return null,
        }
    }

    fn getMnemonic(self: *InstructionSelector, kind: Pattern.PatternKind) []const u8 {
        for (self.patterns.items) |pattern| {
            if (std.meta.eql(pattern.kind, kind)) {
                return pattern.mnemonic;
            }
        }
        return "unknown";
    }

    /// Select instructions for an entire basic block
    pub fn selectBlock(self: *InstructionSelector, block: *const IR.BasicBlock) !std.ArrayList(Pattern) {
        var selected = std.ArrayList(Pattern){};

        for (block.instructions.items) |inst| {
            if (try self.selectInstruction(inst)) |pattern| {
                try selected.append(self.allocator, pattern);
            }
        }

        return selected;
    }

    /// Calculate total cost for a basic block
    pub fn calculateCost(self: *InstructionSelector, block: *const IR.BasicBlock) !Cost {
        var total_cost: Cost = 0;

        for (block.instructions.items) |inst| {
            if (try self.selectInstruction(inst)) |pattern| {
                total_cost += pattern.cost;
            }
        }

        return total_cost;
    }
};

/// Tree pattern matcher for complex instructions
pub const TreeMatcher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TreeMatcher {
        return .{ .allocator = allocator };
    }

    /// Match multiply-add pattern: r = a + (b * c)
    pub fn matchMultiplyAdd(
        self: *TreeMatcher,
        block: *const IR.BasicBlock,
        inst_idx: usize,
    ) ?struct { mul_inst: usize, add_inst: usize } {
        _ = self;
        if (inst_idx >= block.instructions.items.len) return null;

        const inst = block.instructions.items[inst_idx];
        if (inst != .add) return null;

        const add_op = inst.add;

        // Check if either operand is the result of a multiply
        for (block.instructions.items, 0..) |prev_inst, idx| {
            if (idx >= inst_idx) break;
            if (prev_inst != .mul) continue;

            const mul_op = prev_inst.mul;

            // Check if add uses the multiply result
            if (add_op.lhs == .register and add_op.lhs.register == mul_op.dest.register) {
                return .{ .mul_inst = idx, .add_inst = inst_idx };
            }
            if (add_op.rhs == .register and add_op.rhs.register == mul_op.dest.register) {
                return .{ .mul_inst = idx, .add_inst = inst_idx };
            }
        }

        return null;
    }

    /// Match load-effective-address pattern: r = base + (index * scale) + offset
    pub fn matchLEA(
        self: *TreeMatcher,
        inst: IR.Instruction,
    ) ?struct { base: IR.Value, index: IR.Value, scale: i64, offset: i64 } {
        _ = self;
        if (inst != .add) return null;

        // Simplified LEA pattern detection
        const add_op = inst.add;

        // Check for base + offset pattern
        if (add_op.lhs == .register and add_op.rhs == .constant) {
            return .{
                .base = add_op.lhs,
                .index = .{ .register = 0 },
                .scale = 1,
                .offset = add_op.rhs.constant,
            };
        }

        return null;
    }
};

// Tests
test "instruction selection x64" {
    const testing = std.testing;

    var selector = try InstructionSelector.init(testing.allocator, .x64);
    defer selector.deinit();

    // Test add with immediate
    const add_inst = IR.Instruction{ .add = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .constant = 42 },
    } };

    const pattern = try selector.selectInstruction(add_inst);
    try testing.expect(pattern != null);
    try testing.expect(pattern.?.cost == 1);
}

test "instruction selection ARM64" {
    const testing = std.testing;

    var selector = try InstructionSelector.init(testing.allocator, .arm64);
    defer selector.deinit();

    // Test multiply
    const mul_inst = IR.Instruction{ .mul = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .register = 2 },
    } };

    const pattern = try selector.selectInstruction(mul_inst);
    try testing.expect(pattern != null);
    try testing.expectEqualStrings("mul", pattern.?.mnemonic);
}

test "instruction selection power of two" {
    const testing = std.testing;

    var selector = try InstructionSelector.init(testing.allocator, .x64);
    defer selector.deinit();

    // Test multiply by power of 2 (should use shift)
    const mul_inst = IR.Instruction{ .mul = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .constant = 8 },
    } };

    const pattern = try selector.selectInstruction(mul_inst);
    try testing.expect(pattern != null);
    try testing.expectEqualStrings("shl", pattern.?.mnemonic);
    try testing.expect(pattern.?.cost == 1); // Cheaper than multiply
}

test "tree matcher multiply-add" {
    const testing = std.testing;

    var block = IR.BasicBlock.init(testing.allocator, 0);
    defer block.deinit(testing.allocator);

    // r0 = r1 * r2
    try block.instructions.append(testing.allocator, .{ .mul = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .register = 2 },
    } });

    // r3 = r4 + r0  (multiply-add pattern)
    try block.instructions.append(testing.allocator, .{ .add = .{
        .dest = .{ .register = 3 },
        .lhs = .{ .register = 4 },
        .rhs = .{ .register = 0 },
    } });

    var matcher = TreeMatcher.init(testing.allocator);
    const match = matcher.matchMultiplyAdd(&block, 1);

    try testing.expect(match != null);
    try testing.expect(match.?.mul_inst == 0);
    try testing.expect(match.?.add_inst == 1);
}
