// Instruction Scheduling
// Reorders instructions to minimize pipeline stalls and maximize ILP

const std = @import("std");
const IR = @import("optimizer.zig").IR;

/// Instruction latency information
pub const Latency = struct {
    /// Target architecture
    arch: Architecture,

    pub const Architecture = enum {
        x64,
        arm64,
        riscv64,
    };

    pub fn getLatency(self: Latency, inst: IR.Instruction) u32 {
        return switch (self.arch) {
            .x64 => self.getX64Latency(inst),
            .arm64 => self.getARM64Latency(inst),
            .riscv64 => self.getRISCV64Latency(inst),
        };
    }

    fn getX64Latency(self: Latency, inst: IR.Instruction) u32 {
        _ = self;
        return switch (inst) {
            .add, .sub, .and_, .or_, .xor, .shl, .shr => 1,
            .mul => 3,
            .div => 25,
            .load => 4, // L1 cache hit
            .store => 1,
            .move => 1,
            .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => 1,
            .vec_add, .vec_mul => 3,
            .vec_load, .vec_store => 4,
            else => 1,
        };
    }

    fn getARM64Latency(self: Latency, inst: IR.Instruction) u32 {
        _ = self;
        return switch (inst) {
            .add, .sub, .and_, .or_, .xor, .shl, .shr => 1,
            .mul => 3,
            .div => 15,
            .load => 3,
            .store => 1,
            .move => 1,
            .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => 1,
            .vec_add, .vec_mul => 2,
            .vec_load, .vec_store => 3,
            else => 1,
        };
    }

    fn getRISCV64Latency(self: Latency, inst: IR.Instruction) u32 {
        _ = self;
        return switch (inst) {
            .add, .sub, .and_, .or_, .xor, .shl, .shr => 1,
            .mul => 4,
            .div => 30,
            .load => 3,
            .store => 1,
            .move => 1,
            .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => 1,
            else => 1,
        };
    }
};

/// Data dependency between instructions
pub const Dependency = struct {
    /// Instruction that must execute first
    producer: usize,
    /// Instruction that depends on producer
    consumer: usize,
    /// Type of dependency
    kind: DependencyKind,
    /// Latency between producer and consumer
    latency: u32,

    pub const DependencyKind = enum {
        flow, // True dependency (RAW - Read After Write)
        anti, // Anti dependency (WAR - Write After Read)
        output, // Output dependency (WAW - Write After Write)
    };
};

/// Instruction scheduler using list scheduling
pub const InstructionScheduler = struct {
    allocator: std.mem.Allocator,
    latency: Latency,

    pub fn init(allocator: std.mem.Allocator, arch: Latency.Architecture) InstructionScheduler {
        return .{
            .allocator = allocator,
            .latency = Latency{ .arch = arch },
        };
    }

    /// Build dependency graph for a basic block
    pub fn buildDependencies(
        self: *InstructionScheduler,
        block: *const IR.BasicBlock,
    ) !std.ArrayList(Dependency) {
        var deps = std.ArrayList(Dependency){};

        // Track last writer of each register
        var last_writer = std.AutoHashMap(u8, usize).init(self.allocator);
        defer last_writer.deinit();

        // Track last reader of each register
        var last_reader = std.AutoHashMap(u8, usize).init(self.allocator);
        defer last_reader.deinit();

        for (block.instructions.items, 0..) |inst, idx| {
            // Extract uses and defs from instruction
            var uses = try self.getUses(inst);
            defer uses.deinit(self.allocator);

            var defs = try self.getDefs(inst);
            defer defs.deinit(self.allocator);

            // Flow dependencies (RAW): current instruction uses a register written by earlier instruction
            for (uses.items) |use_reg| {
                if (last_writer.get(use_reg)) |writer_idx| {
                    try deps.append(self.allocator, .{
                        .producer = writer_idx,
                        .consumer = idx,
                        .kind = .flow,
                        .latency = self.latency.getLatency(block.instructions.items[writer_idx]),
                    });
                }
            }

            // Anti dependencies (WAR): current instruction writes a register read by earlier instruction
            for (defs.items) |def_reg| {
                if (last_reader.get(def_reg)) |reader_idx| {
                    try deps.append(self.allocator, .{
                        .producer = reader_idx,
                        .consumer = idx,
                        .kind = .anti,
                        .latency = 0,
                    });
                }
            }

            // Output dependencies (WAW): current instruction writes a register written by earlier instruction
            for (defs.items) |def_reg| {
                if (last_writer.get(def_reg)) |writer_idx| {
                    try deps.append(self.allocator, .{
                        .producer = writer_idx,
                        .consumer = idx,
                        .kind = .output,
                        .latency = 0,
                    });
                }
            }

            // Update last writer/reader tracking
            for (defs.items) |def_reg| {
                try last_writer.put(def_reg, idx);
            }
            for (uses.items) |use_reg| {
                try last_reader.put(use_reg, idx);
            }
        }

        return deps;
    }

    fn getUses(self: *InstructionScheduler, inst: IR.Instruction) !std.ArrayList(u8) {
        var uses = std.ArrayList(u8){};

        switch (inst) {
            .add, .sub, .mul, .div, .and_, .or_, .xor, .shl, .shr => |op| {
                if (op.lhs == .register) try uses.append(self.allocator, op.lhs.register);
                if (op.rhs == .register) try uses.append(self.allocator, op.rhs.register);
            },
            .load => |op| {
                if (op.addr == .register) try uses.append(self.allocator, op.addr.register);
            },
            .store => |op| {
                if (op.addr == .register) try uses.append(self.allocator, op.addr.register);
                if (op.value == .register) try uses.append(self.allocator, op.value.register);
            },
            .move => |op| {
                if (op.src == .register) try uses.append(self.allocator, op.src.register);
            },
            .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => |op| {
                if (op.lhs == .register) try uses.append(self.allocator, op.lhs.register);
                if (op.rhs == .register) try uses.append(self.allocator, op.rhs.register);
            },
            .vec_add, .vec_mul => |op| {
                if (op.lhs == .register) try uses.append(self.allocator, op.lhs.register);
                if (op.rhs == .register) try uses.append(self.allocator, op.rhs.register);
            },
            else => {},
        }

        return uses;
    }

    fn getDefs(self: *InstructionScheduler, inst: IR.Instruction) !std.ArrayList(u8) {
        var defs = std.ArrayList(u8){};

        switch (inst) {
            .add, .sub, .mul, .div, .and_, .or_, .xor, .shl, .shr => |op| {
                if (op.dest == .register) try defs.append(self.allocator, op.dest.register);
            },
            .load => |op| {
                if (op.dest == .register) try defs.append(self.allocator, op.dest.register);
            },
            .move => |op| {
                if (op.dest == .register) try defs.append(self.allocator, op.dest.register);
            },
            .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => |op| {
                if (op.dest == .register) try defs.append(self.allocator, op.dest.register);
            },
            .vec_add, .vec_mul => |op| {
                if (op.dest == .register) try defs.append(self.allocator, op.dest.register);
            },
            .vec_load => |op| {
                if (op.dest == .register) try defs.append(self.allocator, op.dest.register);
            },
            else => {},
        }

        return defs;
    }

    /// Schedule instructions using list scheduling algorithm
    pub fn schedule(
        self: *InstructionScheduler,
        block: *IR.BasicBlock,
    ) !void {
        if (block.instructions.items.len <= 1) return;

        // Build dependency graph
        var deps = try self.buildDependencies(block);
        defer deps.deinit(self.allocator);

        // Calculate ready time for each instruction
        var ready_time = try self.allocator.alloc(u32, block.instructions.items.len);
        defer self.allocator.free(ready_time);
        @memset(ready_time, 0);

        for (deps.items) |dep| {
            const producer_ready = ready_time[dep.producer];
            const consumer_min_ready = producer_ready + dep.latency;
            if (consumer_min_ready > ready_time[dep.consumer]) {
                ready_time[dep.consumer] = consumer_min_ready;
            }
        }

        // Create schedule order based on ready times
        var schedule_order = std.ArrayList(usize){};
        defer schedule_order.deinit(self.allocator);

        var scheduled = try self.allocator.alloc(bool, block.instructions.items.len);
        defer self.allocator.free(scheduled);
        @memset(scheduled, false);

        var current_time: u32 = 0;
        while (schedule_order.items.len < block.instructions.items.len) {
            // Find ready instructions at current time
            var best_inst: ?usize = null;
            var best_priority: i32 = -1;

            for (0..block.instructions.items.len) |i| {
                if (scheduled[i]) continue;
                if (ready_time[i] > current_time) continue;

                // Priority: prefer critical path instructions
                const priority = @as(i32, @intCast(ready_time[i]));
                if (priority > best_priority) {
                    best_priority = priority;
                    best_inst = i;
                }
            }

            if (best_inst) |inst_idx| {
                try schedule_order.append(self.allocator, inst_idx);
                scheduled[inst_idx] = true;
            } else {
                current_time += 1;
            }
        }

        // Reorder instructions according to schedule
        var new_instructions = std.ArrayList(IR.Instruction){};

        for (schedule_order.items) |idx| {
            try new_instructions.append(self.allocator, block.instructions.items[idx]);
        }

        // Replace old instruction list
        block.instructions.deinit(self.allocator);
        block.instructions = new_instructions;
    }

    /// Optimize an entire function
    pub fn optimize(self: *InstructionScheduler, func: *IR.Function) !bool {
        var changed = false;

        for (func.blocks.items) |*block| {
            if (block.instructions.items.len > 1) {
                try self.schedule(block);
                changed = true;
            }
        }

        return changed;
    }
};

// Tests
test "latency calculation" {
    const testing = std.testing;

    const latency = Latency{ .arch = .x64 };

    const add_inst = IR.Instruction{ .add = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .register = 2 },
    } };

    const mul_inst = IR.Instruction{ .mul = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .register = 2 },
    } };

    try testing.expect(latency.getLatency(add_inst) == 1);
    try testing.expect(latency.getLatency(mul_inst) == 3);
}

test "dependency detection" {
    const testing = std.testing;

    var block = IR.BasicBlock.init(testing.allocator, 0);
    defer block.deinit(testing.allocator);

    // r0 = r1 + r2
    try block.instructions.append(testing.allocator, .{ .add = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .register = 2 },
    } });

    // r3 = r0 + r4  (depends on previous)
    try block.instructions.append(testing.allocator, .{ .add = .{
        .dest = .{ .register = 3 },
        .lhs = .{ .register = 0 },
        .rhs = .{ .register = 4 },
    } });

    var scheduler = InstructionScheduler.init(testing.allocator, .x64);
    var deps = try scheduler.buildDependencies(&block);
    defer deps.deinit(testing.allocator);

    // Should detect flow dependency
    try testing.expect(deps.items.len >= 1);
    try testing.expect(deps.items[0].kind == .flow);
}

test "instruction scheduling" {
    const testing = std.testing;

    var block = IR.BasicBlock.init(testing.allocator, 0);
    defer block.deinit(testing.allocator);

    // Create instructions with no dependencies - can be reordered
    try block.instructions.append(testing.allocator, .{ .move = .{
        .dest = .{ .register = 0 },
        .src = .{ .constant = 1 },
    } });

    try block.instructions.append(testing.allocator, .{ .move = .{
        .dest = .{ .register = 1 },
        .src = .{ .constant = 2 },
    } });

    var scheduler = InstructionScheduler.init(testing.allocator, .x64);
    try scheduler.schedule(&block);

    // Verify scheduling completed without errors
    try testing.expect(block.instructions.items.len == 2);
}
