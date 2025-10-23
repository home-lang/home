const std = @import("std");

/// ARM64 (AArch64) assembler for native code generation
pub const Assembler = struct {
    code: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Assembler {
        return .{
            .code = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Assembler) void {
        self.code.deinit();
    }

    pub fn getCode(self: *const Assembler) []const u8 {
        return self.code.items;
    }

    pub fn getPosition(self: *const Assembler) usize {
        return self.code.items.len;
    }

    // ARM64 Registers
    pub const Register = enum(u5) {
        x0 = 0,
        x1 = 1,
        x2 = 2,
        x3 = 3,
        x4 = 4,
        x5 = 5,
        x6 = 6,
        x7 = 7,
        x8 = 8,
        x9 = 9,
        x10 = 10,
        x11 = 11,
        x12 = 12,
        x13 = 13,
        x14 = 14,
        x15 = 15,
        x16 = 16,
        x17 = 17,
        x18 = 18,
        x19 = 19,
        x20 = 20,
        x21 = 21,
        x22 = 22,
        x23 = 23,
        x24 = 24,
        x25 = 25,
        x26 = 26,
        x27 = 27,
        x28 = 28,
        x29 = 29, // Frame pointer
        x30 = 30, // Link register
        sp = 31,  // Stack pointer
    };

    /// MOV (immediate) - Move immediate to register
    /// mov xd, #imm
    pub fn movRegImm64(self: *Assembler, dest: Register, imm: i64) !void {
        const imm_u64: u64 = @bitCast(imm);
        const rd = @intFromEnum(dest);

        // MOVZ - Move with zero (lower 16 bits)
        const movz = 0xD2800000 | (@as(u32, @intCast(imm_u64 & 0xFFFF)) << 5) | rd;
        try self.emitU32(movz);

        // MOVK - Move with keep (bits 16-31)
        if ((imm_u64 >> 16) != 0) {
            const movk1 = 0xF2A00000 | (@as(u32, @intCast((imm_u64 >> 16) & 0xFFFF)) << 5) | rd;
            try self.emitU32(movk1);
        }

        // MOVK (bits 32-47)
        if ((imm_u64 >> 32) != 0) {
            const movk2 = 0xF2C00000 | (@as(u32, @intCast((imm_u64 >> 32) & 0xFFFF)) << 5) | rd;
            try self.emitU32(movk2);
        }

        // MOVK (bits 48-63)
        if ((imm_u64 >> 48) != 0) {
            const movk3 = 0xF2E00000 | (@as(u32, @intCast((imm_u64 >> 48) & 0xFFFF)) << 5) | rd;
            try self.emitU32(movk3);
        }
    }

    /// MOV (register) - Move register to register
    /// mov xd, xn
    pub fn movRegReg(self: *Assembler, dest: Register, src: Register) !void {
        // ORR xd, xzr, xn (equivalent to MOV)
        const rd = @intFromEnum(dest);
        const rn = @intFromEnum(src);
        const instr = 0xAA0003E0 | (@as(u32, rn) << 16) | rd;
        try self.emitU32(instr);
    }

    /// ADD (register) - Add registers
    /// add xd, xn, xm
    pub fn addRegReg(self: *Assembler, dest: Register, src1: Register, src2: Register) !void {
        const rd = @intFromEnum(dest);
        const rn = @intFromEnum(src1);
        const rm = @intFromEnum(src2);
        const instr = 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
        try self.emitU32(instr);
    }

    /// SUB (register) - Subtract registers
    /// sub xd, xn, xm
    pub fn subRegReg(self: *Assembler, dest: Register, src1: Register, src2: Register) !void {
        const rd = @intFromEnum(dest);
        const rn = @intFromEnum(src1);
        const rm = @intFromEnum(src2);
        const instr = 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
        try self.emitU32(instr);
    }

    /// MUL - Multiply registers
    /// mul xd, xn, xm
    pub fn mulRegReg(self: *Assembler, dest: Register, src1: Register, src2: Register) !void {
        const rd = @intFromEnum(dest);
        const rn = @intFromEnum(src1);
        const rm = @intFromEnum(src2);
        const instr = 0x9B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
        try self.emitU32(instr);
    }

    /// SDIV - Signed divide
    /// sdiv xd, xn, xm
    pub fn divRegReg(self: *Assembler, dest: Register, src1: Register, src2: Register) !void {
        const rd = @intFromEnum(dest);
        const rn = @intFromEnum(src1);
        const rm = @intFromEnum(src2);
        const instr = 0x9AC00C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
        try self.emitU32(instr);
    }

    /// CMP (compare) - Compare registers
    /// cmp xn, xm
    pub fn cmpRegReg(self: *Assembler, src1: Register, src2: Register) !void {
        const rn = @intFromEnum(src1);
        const rm = @intFromEnum(src2);
        // SUBS xzr, xn, xm (equivalent to CMP)
        const instr = 0xEB00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
        try self.emitU32(instr);
    }

    /// B.cond - Conditional branch
    /// b.eq label
    pub fn beq(self: *Assembler, offset: i32) !void {
        const imm19 = @as(u32, @bitCast(offset >> 2)) & 0x7FFFF;
        const instr = 0x54000000 | (imm19 << 5) | 0x0; // EQ condition
        try self.emitU32(instr);
    }

    /// B - Unconditional branch
    /// b label
    pub fn b(self: *Assembler, offset: i32) !void {
        const imm26 = @as(u32, @bitCast(offset >> 2)) & 0x3FFFFFF;
        const instr = 0x14000000 | imm26;
        try self.emitU32(instr);
    }

    /// BL - Branch with link (call)
    /// bl label
    pub fn bl(self: *Assembler, offset: i32) !void {
        const imm26 = @as(u32, @bitCast(offset >> 2)) & 0x3FFFFFF;
        const instr = 0x94000000 | imm26;
        try self.emitU32(instr);
    }

    /// RET - Return from subroutine
    /// ret
    pub fn ret(self: *Assembler) !void {
        // RET x30 (link register)
        const instr = 0xD65F03C0;
        try self.emitU32(instr);
    }

    /// LDR (immediate) - Load register from memory
    /// ldr xd, [xn, #imm]
    pub fn ldrRegMem(self: *Assembler, dest: Register, base: Register, offset: i32) !void {
        const rd = @intFromEnum(dest);
        const rn = @intFromEnum(base);
        const imm12 = @as(u32, @bitCast(offset >> 3)) & 0xFFF; // Scaled by 8
        const instr = 0xF9400000 | (imm12 << 10) | (@as(u32, rn) << 5) | rd;
        try self.emitU32(instr);
    }

    /// STR (immediate) - Store register to memory
    /// str xd, [xn, #imm]
    pub fn strRegMem(self: *Assembler, src: Register, base: Register, offset: i32) !void {
        const rt = @intFromEnum(src);
        const rn = @intFromEnum(base);
        const imm12 = @as(u32, @bitCast(offset >> 3)) & 0xFFF; // Scaled by 8
        const instr = 0xF9000000 | (imm12 << 10) | (@as(u32, rn) << 5) | rt;
        try self.emitU32(instr);
    }

    /// STP - Store pair of registers
    /// stp x1, x2, [sp, #-16]!
    pub fn stpPreIndex(self: *Assembler, rt1: Register, rt2: Register, base: Register, offset: i32) !void {
        const r1 = @intFromEnum(rt1);
        const r2 = @intFromEnum(rt2);
        const rn = @intFromEnum(base);
        const imm7 = @as(u32, @bitCast(offset >> 3)) & 0x7F;
        const instr = 0xA9800000 | (imm7 << 15) | (@as(u32, r2) << 10) | (@as(u32, rn) << 5) | r1;
        try self.emitU32(instr);
    }

    /// LDP - Load pair of registers
    /// ldp x1, x2, [sp], #16
    pub fn ldpPostIndex(self: *Assembler, rt1: Register, rt2: Register, base: Register, offset: i32) !void {
        const r1 = @intFromEnum(rt1);
        const r2 = @intFromEnum(rt2);
        const rn = @intFromEnum(base);
        const imm7 = @as(u32, @bitCast(offset >> 3)) & 0x7F;
        const instr = 0xA8C00000 | (imm7 << 15) | (@as(u32, r2) << 10) | (@as(u32, rn) << 5) | r1;
        try self.emitU32(instr);
    }

    /// NOP - No operation
    pub fn nop(self: *Assembler) !void {
        const instr = 0xD503201F;
        try self.emitU32(instr);
    }

    fn emitU32(self: *Assembler, value: u32) !void {
        const bytes = std.mem.toBytes(value);
        try self.code.appendSlice(&bytes);
    }

    pub fn patchBeq(self: *Assembler, position: usize, target: usize) !void {
        const offset = @as(i32, @intCast(target)) - @as(i32, @intCast(position));
        const imm19 = @as(u32, @bitCast(offset >> 2)) & 0x7FFFF;
        const instr = 0x54000000 | (imm19 << 5) | 0x0;

        const bytes = std.mem.toBytes(instr);
        @memcpy(self.code.items[position .. position + 4], &bytes);
    }

    pub fn patchB(self: *Assembler, position: usize, target: usize) !void {
        const offset = @as(i32, @intCast(target)) - @as(i32, @intCast(position));
        const imm26 = @as(u32, @bitCast(offset >> 2)) & 0x3FFFFFF;
        const instr = 0x14000000 | imm26;

        const bytes = std.mem.toBytes(instr);
        @memcpy(self.code.items[position .. position + 4], &bytes);
    }
};
