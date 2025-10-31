// Home Programming Language - Register Allocation Hints
// Manual optimization through register allocation hints and constraints

const std = @import("std");

// ============================================================================
// Architecture Support
// ============================================================================

pub const Architecture = enum {
    x86_64,
    aarch64,
    riscv64,

    pub fn getRegisterCount(self: Architecture) u8 {
        return switch (self) {
            .x86_64 => 16, // rax-r15
            .aarch64 => 31, // x0-x30 (x31 is zero/sp)
            .riscv64 => 32, // x0-x31
        };
    }

    pub fn getCallerSavedCount(self: Architecture) u8 {
        return switch (self) {
            .x86_64 => 9, // rax, rcx, rdx, rsi, rdi, r8-r11
            .aarch64 => 18, // x0-x17
            .riscv64 => 15, // t0-t6, a0-a7
        };
    }

    pub fn getCalleeSavedCount(self: Architecture) u8 {
        return switch (self) {
            .x86_64 => 7, // rbx, rbp, r12-r15
            .aarch64 => 11, // x19-x29
            .riscv64 => 12, // s0-s11
        };
    }
};

// ============================================================================
// Register Classes
// ============================================================================

pub const RegisterClass = enum {
    /// General purpose integer registers
    General,
    /// Floating point registers
    Float,
    /// Vector/SIMD registers
    Vector,
    /// Special purpose registers (stack pointer, frame pointer, etc)
    Special,

    pub fn getRegisterCount(self: RegisterClass, arch: Architecture) u8 {
        return switch (self) {
            .General => arch.getRegisterCount(),
            .Float => switch (arch) {
                .x86_64 => 16, // xmm0-xmm15
                .aarch64 => 32, // v0-v31
                .riscv64 => 32, // f0-f31
            },
            .Vector => switch (arch) {
                .x86_64 => 32, // ymm0-ymm31 (AVX-512)
                .aarch64 => 32, // v0-v31
                .riscv64 => 32, // v0-v31
            },
            .Special => 2, // SP, FP typically
        };
    }
};

// ============================================================================
// Register Hints
// ============================================================================

pub const RegisterHint = enum {
    /// No preference, let compiler decide
    None,
    /// Prefer specific register
    Prefer,
    /// Require specific register (may fail if unavailable)
    Require,
    /// Avoid specific register
    Avoid,
    /// Any register in class
    AnyInClass,
    /// Caller-saved register preferred (for temporary values)
    CallerSaved,
    /// Callee-saved register preferred (for long-lived values)
    CalleeSaved,
};

pub const RegisterConstraint = struct {
    hint: RegisterHint,
    register_class: RegisterClass,
    specific_register: ?u8,
    architecture: Architecture,

    pub fn none(arch: Architecture) RegisterConstraint {
        return .{
            .hint = .None,
            .register_class = .General,
            .specific_register = null,
            .architecture = arch,
        };
    }

    pub fn prefer(arch: Architecture, class: RegisterClass, reg: u8) RegisterConstraint {
        return .{
            .hint = .Prefer,
            .register_class = class,
            .specific_register = reg,
            .architecture = arch,
        };
    }

    pub fn require(arch: Architecture, class: RegisterClass, reg: u8) RegisterConstraint {
        return .{
            .hint = .Require,
            .register_class = class,
            .specific_register = reg,
            .architecture = arch,
        };
    }

    pub fn avoid(arch: Architecture, class: RegisterClass, reg: u8) RegisterConstraint {
        return .{
            .hint = .Avoid,
            .register_class = class,
            .specific_register = reg,
            .architecture = arch,
        };
    }

    pub fn anyInClass(arch: Architecture, class: RegisterClass) RegisterConstraint {
        return .{
            .hint = .AnyInClass,
            .register_class = class,
            .specific_register = null,
            .architecture = arch,
        };
    }

    pub fn callerSaved(arch: Architecture, class: RegisterClass) RegisterConstraint {
        return .{
            .hint = .CallerSaved,
            .register_class = class,
            .specific_register = null,
            .architecture = arch,
        };
    }

    pub fn calleeSaved(arch: Architecture, class: RegisterClass) RegisterConstraint {
        return .{
            .hint = .CalleeSaved,
            .register_class = class,
            .specific_register = null,
            .architecture = arch,
        };
    }

    /// Validate constraint is feasible
    pub fn validate(self: RegisterConstraint) bool {
        if (self.specific_register) |reg| {
            const max_reg = self.register_class.getRegisterCount(self.architecture);
            if (reg >= max_reg) return false;
        }
        return true;
    }

    /// Check if constraint is satisfied by a register
    pub fn satisfiedBy(self: RegisterConstraint, reg: u8, class: RegisterClass) bool {
        // Class must match
        if (class != self.register_class) return false;

        return switch (self.hint) {
            .None => true,
            .Prefer => true, // Preference means any register works, but one is preferred
            .Require => if (self.specific_register) |r| reg == r else false,
            .Avoid => if (self.specific_register) |r| reg != r else true,
            .AnyInClass => true,
            .CallerSaved, .CalleeSaved => true, // Would need more context
        };
    }
};

// ============================================================================
// Variable Lifetime Tracking
// ============================================================================

pub const LiveRange = struct {
    start: u32, // Program point (instruction index)
    end: u32, // Program point (instruction index)
    variable: []const u8,

    pub fn overlaps(self: LiveRange, other: LiveRange) bool {
        return !(self.end < other.start or other.end < self.start);
    }

    pub fn contains(self: LiveRange, point: u32) bool {
        return point >= self.start and point <= self.end;
    }

    pub fn length(self: LiveRange) u32 {
        return self.end - self.start;
    }
};

// ============================================================================
// Register Allocator State
// ============================================================================

pub const RegisterAllocator = struct {
    architecture: Architecture,
    allocator: std.mem.Allocator,
    /// Map from variable name to register constraint
    constraints: std.StringHashMap(RegisterConstraint),
    /// Map from variable name to live range
    live_ranges: std.StringHashMap(LiveRange),
    /// Currently allocated registers (bitset)
    allocated: std.DynamicBitSet,
    /// Register to variable mapping
    register_map: std.AutoHashMap(u8, []const u8),
    /// Spill priority queue (variables that should be spilled first)
    spill_weights: std.StringHashMap(f32),

    pub fn init(allocator: std.mem.Allocator, arch: Architecture) !RegisterAllocator {
        const reg_count = arch.getRegisterCount();
        return .{
            .architecture = arch,
            .allocator = allocator,
            .constraints = std.StringHashMap(RegisterConstraint).init(allocator),
            .live_ranges = std.StringHashMap(LiveRange).init(allocator),
            .allocated = try std.DynamicBitSet.initEmpty(allocator, reg_count),
            .register_map = std.AutoHashMap(u8, []const u8).init(allocator),
            .spill_weights = std.StringHashMap(f32).init(allocator),
        };
    }

    pub fn deinit(self: *RegisterAllocator) void {
        self.constraints.deinit();
        self.live_ranges.deinit();
        self.allocated.deinit();
        self.register_map.deinit();
        self.spill_weights.deinit();
    }

    /// Add register constraint for a variable
    pub fn addConstraint(self: *RegisterAllocator, variable: []const u8, constraint: RegisterConstraint) !void {
        if (!constraint.validate()) {
            return error.InvalidConstraint;
        }
        try self.constraints.put(variable, constraint);
    }

    /// Set live range for a variable
    pub fn setLiveRange(self: *RegisterAllocator, variable: []const u8, range: LiveRange) !void {
        try self.live_ranges.put(variable, range);
    }

    /// Allocate a register for a variable
    pub fn allocate(self: *RegisterAllocator, variable: []const u8) !?u8 {
        const constraint = self.constraints.get(variable) orelse RegisterConstraint.none(self.architecture);

        // Try to satisfy the constraint
        const reg_count = self.architecture.getRegisterCount();

        if (constraint.specific_register) |specific| {
            // Specific register requested
            if (constraint.hint == .Require) {
                if (self.allocated.isSet(specific)) {
                    return error.RegisterUnavailable;
                }
                self.allocated.set(specific);
                try self.register_map.put(specific, variable);
                return specific;
            } else if (constraint.hint == .Prefer) {
                if (!self.allocated.isSet(specific)) {
                    self.allocated.set(specific);
                    try self.register_map.put(specific, variable);
                    return specific;
                }
                // Fall through to find alternative
            }
        }

        // Find any available register
        var i: u8 = 0;
        while (i < reg_count) : (i += 1) {
            if (!self.allocated.isSet(i)) {
                if (constraint.satisfiedBy(i, constraint.register_class)) {
                    self.allocated.set(i);
                    try self.register_map.put(i, variable);
                    return i;
                }
            }
        }

        // No register available - would need to spill
        return null;
    }

    /// Free a register
    pub fn free(self: *RegisterAllocator, reg: u8) void {
        if (reg < self.architecture.getRegisterCount()) {
            self.allocated.unset(reg);
            _ = self.register_map.remove(reg);
        }
    }

    /// Get register allocated to variable
    pub fn getRegister(self: *RegisterAllocator, variable: []const u8) ?u8 {
        var it = self.register_map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, variable)) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }

    /// Calculate spill cost for a variable
    pub fn spillCost(self: *RegisterAllocator, variable: []const u8) f32 {
        // Use pre-calculated weight if available
        if (self.spill_weights.get(variable)) |weight| {
            return weight;
        }

        // Default: based on live range length
        if (self.live_ranges.get(variable)) |range| {
            return @floatFromInt(range.length());
        }

        return 1.0;
    }

    /// Set spill weight hint
    pub fn setSpillWeight(self: *RegisterAllocator, variable: []const u8, weight: f32) !void {
        try self.spill_weights.put(variable, weight);
    }

    /// Get allocation statistics
    pub fn getStatistics(self: *RegisterAllocator) AllocationStatistics {
        const total = self.architecture.getRegisterCount();
        const allocated_count = self.allocated.count();

        return .{
            .total_registers = total,
            .allocated_registers = @intCast(allocated_count),
            .free_registers = total - @as(u8, @intCast(allocated_count)),
            .variables_allocated = @intCast(self.register_map.count()),
        };
    }
};

pub const AllocationStatistics = struct {
    total_registers: u8,
    allocated_registers: u8,
    free_registers: u8,
    variables_allocated: u32,

    pub fn utilizationRatio(self: AllocationStatistics) f32 {
        if (self.total_registers == 0) return 0.0;
        return @as(f32, @floatFromInt(self.allocated_registers)) / @as(f32, @floatFromInt(self.total_registers));
    }
};

// ============================================================================
// Graph Coloring Allocator
// ============================================================================

pub const InterferenceGraph = struct {
    allocator: std.mem.Allocator,
    /// Adjacency list representation
    edges: std.StringHashMap(std.StringHashMap(void)),

    pub fn init(allocator: std.mem.Allocator) InterferenceGraph {
        return .{
            .allocator = allocator,
            .edges = std.StringHashMap(std.StringHashMap(void)).init(allocator),
        };
    }

    pub fn deinit(self: *InterferenceGraph) void {
        var it = self.edges.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.edges.deinit();
    }

    /// Add an interference edge between two variables
    pub fn addEdge(self: *InterferenceGraph, var1: []const u8, var2: []const u8) !void {
        // Add var1 -> var2
        if (!self.edges.contains(var1)) {
            try self.edges.put(var1, std.StringHashMap(void).init(self.allocator));
        }
        const neighbors1 = self.edges.getPtr(var1).?;
        try neighbors1.put(var2, {});

        // Add var2 -> var1 (undirected graph)
        if (!self.edges.contains(var2)) {
            try self.edges.put(var2, std.StringHashMap(void).init(self.allocator));
        }
        const neighbors2 = self.edges.getPtr(var2).?;
        try neighbors2.put(var1, {});
    }

    /// Get degree (number of neighbors) for a variable
    pub fn getDegree(self: *InterferenceGraph, variable: []const u8) u32 {
        if (self.edges.get(variable)) |neighbors| {
            return @intCast(neighbors.count());
        }
        return 0;
    }

    /// Check if two variables interfere
    pub fn interfere(self: *InterferenceGraph, var1: []const u8, var2: []const u8) bool {
        if (self.edges.get(var1)) |neighbors| {
            return neighbors.contains(var2);
        }
        return false;
    }
};

// ============================================================================
// Register Hints from Profiling
// ============================================================================

pub const ProfilingData = struct {
    variable: []const u8,
    access_count: u64,
    loop_depth: u8,
    is_induction_variable: bool,

    pub fn calculatePriority(self: ProfilingData) f32 {
        var priority: f32 = @floatFromInt(self.access_count);

        // Weight by loop depth (variables in inner loops are more important)
        priority *= std.math.pow(f32, 2.0, @floatFromInt(self.loop_depth));

        // Induction variables should stay in registers
        if (self.is_induction_variable) {
            priority *= 1.5;
        }

        return priority;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "architecture register counts" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 16), Architecture.x86_64.getRegisterCount());
    try testing.expectEqual(@as(u8, 31), Architecture.aarch64.getRegisterCount());
    try testing.expectEqual(@as(u8, 32), Architecture.riscv64.getRegisterCount());
}

test "register constraints" {
    const testing = std.testing;

    const constraint = RegisterConstraint.prefer(.x86_64, .General, 5);
    try testing.expect(constraint.validate());
    try testing.expectEqual(RegisterHint.Prefer, constraint.hint);
    try testing.expectEqual(@as(u8, 5), constraint.specific_register.?);

    try testing.expect(constraint.satisfiedBy(5, .General));
    try testing.expect(!constraint.satisfiedBy(5, .Float));
    try testing.expect(constraint.satisfiedBy(3, .General)); // Prefer, not require
}

test "live range overlap" {
    const testing = std.testing;

    const range1 = LiveRange{ .start = 10, .end = 20, .variable = "x" };
    const range2 = LiveRange{ .start = 15, .end = 25, .variable = "y" };
    const range3 = LiveRange{ .start = 25, .end = 30, .variable = "z" };

    try testing.expect(range1.overlaps(range2));
    try testing.expect(range2.overlaps(range1));
    try testing.expect(!range1.overlaps(range3));
    try testing.expect(range2.overlaps(range3)); // Touch at boundary
}

test "register allocator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ralloc = try RegisterAllocator.init(allocator, .x86_64);
    defer ralloc.deinit();

    // Add constraint for variable x to prefer register 3
    const constraint = RegisterConstraint.prefer(.x86_64, .General, 3);
    try ralloc.addConstraint("x", constraint);

    // Allocate register
    const reg = try ralloc.allocate("x");
    try testing.expect(reg != null);
    try testing.expectEqual(@as(u8, 3), reg.?); // Should get preferred register

    const stats = ralloc.getStatistics();
    try testing.expectEqual(@as(u8, 1), stats.allocated_registers);
    try testing.expectEqual(@as(u32, 1), stats.variables_allocated);
}

test "register allocation with conflicts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ralloc = try RegisterAllocator.init(allocator, .x86_64);
    defer ralloc.deinit();

    // Both variables want register 5
    try ralloc.addConstraint("x", RegisterConstraint.require(.x86_64, .General, 5));
    try ralloc.addConstraint("y", RegisterConstraint.prefer(.x86_64, .General, 5));

    const reg_x = try ralloc.allocate("x");
    try testing.expectEqual(@as(u8, 5), reg_x.?);

    const reg_y = try ralloc.allocate("y");
    try testing.expect(reg_y != null);
    try testing.expect(reg_y.? != 5); // Should get different register
}

test "spill cost calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ralloc = try RegisterAllocator.init(allocator, .x86_64);
    defer ralloc.deinit();

    const range = LiveRange{ .start = 10, .end = 50, .variable = "x" };
    try ralloc.setLiveRange("x", range);

    const cost = ralloc.spillCost("x");
    try testing.expectEqual(@as(f32, 40.0), cost); // Length of live range
}

test "interference graph" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var graph = InterferenceGraph.init(allocator);
    defer graph.deinit();

    try graph.addEdge("x", "y");
    try graph.addEdge("y", "z");

    try testing.expect(graph.interfere("x", "y"));
    try testing.expect(graph.interfere("y", "x"));
    try testing.expect(graph.interfere("y", "z"));
    try testing.expect(!graph.interfere("x", "z"));

    try testing.expectEqual(@as(u32, 1), graph.getDegree("x"));
    try testing.expectEqual(@as(u32, 2), graph.getDegree("y"));
    try testing.expectEqual(@as(u32, 1), graph.getDegree("z"));
}

test "profiling priority" {
    const testing = std.testing;

    const data1 = ProfilingData{
        .variable = "i",
        .access_count = 1000,
        .loop_depth = 2,
        .is_induction_variable = true,
    };

    const data2 = ProfilingData{
        .variable = "temp",
        .access_count = 10,
        .loop_depth = 0,
        .is_induction_variable = false,
    };

    const priority1 = data1.calculatePriority();
    const priority2 = data2.calculatePriority();

    try testing.expect(priority1 > priority2);
}

test "register class counts" {
    const testing = std.testing;

    const gen_x64 = RegisterClass.General.getRegisterCount(.x86_64);
    try testing.expectEqual(@as(u8, 16), gen_x64);

    const float_x64 = RegisterClass.Float.getRegisterCount(.x86_64);
    try testing.expectEqual(@as(u8, 16), float_x64);

    const vec_aarch64 = RegisterClass.Vector.getRegisterCount(.aarch64);
    try testing.expectEqual(@as(u8, 32), vec_aarch64);
}
