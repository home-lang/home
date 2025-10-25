// Home Programming Language - Enhanced Inline Assembly Parser
// Better constraint specifications and clobber lists for OS development

const Basics = @import("basics");

// ============================================================================
// Assembly Constraint Types
// ============================================================================

pub const ConstraintType = enum {
    /// Input constraint - read-only
    Input,
    /// Output constraint - write-only
    Output,
    /// Input/output constraint - read-write
    InputOutput,
    /// Early clobber - written before inputs are read
    EarlyClobber,
};

pub const RegisterConstraint = enum {
    /// Any register
    Register, // "r"
    /// Specific register
    Specific, // "{rax}", "{rbx}", etc.
    /// Register class
    Class, // "=&r"

    /// Memory operand
    Memory, // "m"
    /// Immediate value
    Immediate, // "i"
    /// Constant
    Constant, // "n"

    /// x86-64 specific
    Accumulator, // "a" (rax)
    Base, // "b" (rbx)
    Counter, // "c" (rcx)
    Data, // "d" (rdx)
    StackPointer, // "S" (rsi)
    DestinationPointer, // "D" (rdi)
    BasePointer, // "p" (rbp)

    /// Matching constraint
    Matching, // "0", "1", etc. - use same location as operand N
};

pub const Constraint = struct {
    type: ConstraintType,
    register: RegisterConstraint,
    specific_name: ?[]const u8,

    pub fn init(ctype: ConstraintType, register: RegisterConstraint) Constraint {
        return .{
            .type = ctype,
            .register = register,
            .specific_name = null,
        };
    }

    pub fn specific(ctype: ConstraintType, name: []const u8) Constraint {
        return .{
            .type = ctype,
            .register = .Specific,
            .specific_name = name,
        };
    }

    /// Format constraint for inline assembly
    pub fn format(self: Constraint) []const u8 {
        return switch (self.register) {
            .Register => "r",
            .Memory => "m",
            .Immediate => "i",
            .Constant => "n",
            .Accumulator => "a",
            .Base => "b",
            .Counter => "c",
            .Data => "d",
            .StackPointer => "S",
            .DestinationPointer => "D",
            .BasePointer => "p",
            .Specific => self.specific_name orelse "{rax}",
            .Class => "=&r",
            .Matching => "0",
        };
    }
};

// ============================================================================
// Clobber List
// ============================================================================

pub const ClobberList = struct {
    registers: Basics.ArrayList([]const u8),
    memory: bool,
    cc: bool, // Condition codes

    pub fn init(allocator: Basics.Allocator) ClobberList {
        return .{
            .registers = Basics.ArrayList([]const u8).init(allocator),
            .memory = false,
            .cc = false,
        };
    }

    pub fn deinit(self: *ClobberList) void {
        self.registers.deinit();
    }

    pub fn addRegister(self: *ClobberList, reg: []const u8) !void {
        try self.registers.append(reg);
    }

    pub fn addMemory(self: *ClobberList) void {
        self.memory = true;
    }

    pub fn addCC(self: *ClobberList) void {
        self.cc = true;
    }

    pub fn format(self: ClobberList, allocator: Basics.Allocator) ![]const u8 {
        var result = Basics.ArrayList(u8).init(allocator);
        const writer = result.writer();

        try writer.writeAll(":");

        for (self.registers.items, 0..) |reg, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{reg});
        }

        if (self.memory) {
            if (self.registers.items.len > 0) try writer.writeAll(", ");
            try writer.writeAll("\"memory\"");
        }

        if (self.cc) {
            if (self.registers.items.len > 0 or self.memory) try writer.writeAll(", ");
            try writer.writeAll("\"cc\"");
        }

        return result.toOwnedSlice();
    }
};

// ============================================================================
// Assembly Operand
// ============================================================================

pub const Operand = struct {
    name: []const u8,
    constraint: Constraint,
    value_type: []const u8,

    pub fn init(name: []const u8, constraint: Constraint, value_type: []const u8) Operand {
        return .{
            .name = name,
            .constraint = constraint,
            .value_type = value_type,
        };
    }

    pub fn formatInput(self: Operand) []const u8 {
        // Format: [name] "constraint" (value)
        return Basics.fmt.allocPrint(
            Basics.heap.page_allocator,
            "[{s}] \"{s}\" ({s})",
            .{ self.name, self.constraint.format(), self.name },
        ) catch unreachable;
    }

    pub fn formatOutput(self: Operand) []const u8 {
        // Format: [name] "=constraint" (-> type)
        return Basics.fmt.allocPrint(
            Basics.heap.page_allocator,
            "[{s}] \"={s}\" (-> {s})",
            .{ self.name, self.constraint.format(), self.value_type },
        ) catch unreachable;
    }
};

// ============================================================================
// Inline Assembly Builder
// ============================================================================

pub const InlineAsmBuilder = struct {
    allocator: Basics.Allocator,
    instruction: Basics.ArrayList(u8),
    inputs: Basics.ArrayList(Operand),
    outputs: Basics.ArrayList(Operand),
    clobbers: ClobberList,
    is_volatile: bool,

    pub fn init(allocator: Basics.Allocator) InlineAsmBuilder {
        return .{
            .allocator = allocator,
            .instruction = Basics.ArrayList(u8).init(allocator),
            .inputs = Basics.ArrayList(Operand).init(allocator),
            .outputs = Basics.ArrayList(Operand).init(allocator),
            .clobbers = ClobberList.init(allocator),
            .is_volatile = false,
        };
    }

    pub fn deinit(self: *InlineAsmBuilder) void {
        self.instruction.deinit();
        self.inputs.deinit();
        self.outputs.deinit();
        self.clobbers.deinit();
    }

    pub fn setInstruction(self: *InlineAsmBuilder, instr: []const u8) !void {
        try self.instruction.appendSlice(instr);
    }

    pub fn addInput(self: *InlineAsmBuilder, name: []const u8, constraint: Constraint, value_type: []const u8) !void {
        try self.inputs.append(Operand.init(name, constraint, value_type));
    }

    pub fn addOutput(self: *InlineAsmBuilder, name: []const u8, constraint: Constraint, value_type: []const u8) !void {
        try self.outputs.append(Operand.init(name, constraint, value_type));
    }

    pub fn setVolatile(self: *InlineAsmBuilder, vol: bool) void {
        self.is_volatile = vol;
    }

    pub fn clobber(self: *InlineAsmBuilder, item: []const u8) !void {
        if (Basics.mem.eql(u8, item, "memory")) {
            self.clobbers.addMemory();
        } else if (Basics.mem.eql(u8, item, "cc")) {
            self.clobbers.addCC();
        } else {
            try self.clobbers.addRegister(item);
        }
    }

    pub fn build(self: *InlineAsmBuilder) ![]const u8 {
        var result = Basics.ArrayList(u8).init(self.allocator);
        const writer = result.writer();

        // Start assembly block
        if (self.is_volatile) {
            try writer.writeAll("asm volatile (\"");
        } else {
            try writer.writeAll("asm (\"");
        }

        // Instruction
        try writer.writeAll(self.instruction.items);
        try writer.writeAll("\"\n");

        // Outputs
        if (self.outputs.items.len > 0) {
            try writer.writeAll("    : ");
            for (self.outputs.items, 0..) |output, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(output.formatOutput());
            }
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("    :\n");
        }

        // Inputs
        if (self.inputs.items.len > 0) {
            try writer.writeAll("    : ");
            for (self.inputs.items, 0..) |input, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(input.formatInput());
            }
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("    :\n");
        }

        // Clobbers
        const clobber_str = try self.clobbers.format(self.allocator);
        defer self.allocator.free(clobber_str);
        try writer.writeAll("    ");
        try writer.writeAll(clobber_str);

        try writer.writeAll("\n);");

        return result.toOwnedSlice();
    }
};

// ============================================================================
// Common Assembly Templates
// ============================================================================

pub const Templates = struct {
    /// CPUID instruction
    pub fn cpuid(allocator: Basics.Allocator, leaf: []const u8) ![]const u8 {
        var builder = InlineAsmBuilder.init(allocator);
        defer builder.deinit();

        try builder.setInstruction("cpuid");
        try builder.addInput("leaf", Constraint.specific(.Input, "{eax}"), "u32");
        try builder.addOutput("eax", Constraint.specific(.Output, "{eax}"), "u32");
        try builder.addOutput("ebx", Constraint.specific(.Output, "{ebx}"), "u32");
        try builder.addOutput("ecx", Constraint.specific(.Output, "{ecx}"), "u32");
        try builder.addOutput("edx", Constraint.specific(.Output, "{edx}"), "u32");
        try builder.clobber("memory");

        return try builder.build();
    }

    /// MSR read
    pub fn rdmsr(allocator: Basics.Allocator) ![]const u8 {
        var builder = InlineAsmBuilder.init(allocator);
        defer builder.deinit();

        try builder.setInstruction("rdmsr");
        try builder.addInput("msr", Constraint.specific(.Input, "{ecx}"), "u32");
        try builder.addOutput("low", Constraint.specific(.Output, "{eax}"), "u32");
        try builder.addOutput("high", Constraint.specific(.Output, "{edx}"), "u32");
        try builder.setVolatile(true);

        return try builder.build();
    }

    /// MSR write
    pub fn wrmsr(allocator: Basics.Allocator) ![]const u8 {
        var builder = InlineAsmBuilder.init(allocator);
        defer builder.deinit();

        try builder.setInstruction("wrmsr");
        try builder.addInput("msr", Constraint.specific(.Input, "{ecx}"), "u32");
        try builder.addInput("low", Constraint.specific(.Input, "{eax}"), "u32");
        try builder.addInput("high", Constraint.specific(.Input, "{edx}"), "u32");
        try builder.setVolatile(true);

        return try builder.build();
    }

    /// Compare and swap
    pub fn cmpxchg(allocator: Basics.Allocator) ![]const u8 {
        var builder = InlineAsmBuilder.init(allocator);
        defer builder.deinit();

        try builder.setInstruction("lock cmpxchg %[new], %[ptr]");
        try builder.addInput("ptr", Constraint.init(.Input, .Memory), "*u64");
        try builder.addInput("old", Constraint.specific(.Input, "{rax}"), "u64");
        try builder.addInput("new", Constraint.init(.Input, .Register), "u64");
        try builder.addOutput("result", Constraint.specific(.Output, "{rax}"), "u64");
        try builder.clobber("memory");
        try builder.clobber("cc");
        try builder.setVolatile(true);

        return try builder.build();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "constraint formatting" {
    const c1 = Constraint.init(.Input, .Register);
    try Basics.testing.expectEqualSlices(u8, "r", c1.format());

    const c2 = Constraint.specific(.Output, "{rax}");
    try Basics.testing.expectEqualSlices(u8, "{rax}", c2.format());
}

test "clobber list" {
    const allocator = Basics.testing.allocator;
    var clobbers = ClobberList.init(allocator);
    defer clobbers.deinit();

    try clobbers.addRegister("rax");
    try clobbers.addRegister("rbx");
    clobbers.addMemory();
    clobbers.addCC();

    const formatted = try clobbers.format(allocator);
    defer allocator.free(formatted);

    try Basics.testing.expect(formatted.len > 0);
}

test "inline asm builder" {
    const allocator = Basics.testing.allocator;
    var builder = InlineAsmBuilder.init(allocator);
    defer builder.deinit();

    try builder.setInstruction("nop");
    builder.setVolatile(true);

    const result = try builder.build();
    defer allocator.free(result);

    try Basics.testing.expect(result.len > 0);
}
