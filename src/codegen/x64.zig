const std = @import("std");

/// x86-64 registers
pub const Register = enum(u8) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    pub fn needsRexPrefix(self: Register) bool {
        return @intFromEnum(self) >= 8;
    }

    pub fn encodeModRM(self: Register) u8 {
        return @intFromEnum(self) & 0x7;
    }
};

/// x86-64 assembler for generating machine code
pub const Assembler = struct {
    code: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Assembler {
        return .{
            .code = std.ArrayList(u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Assembler) void {
        self.code.deinit(self.allocator);
    }

    pub fn getCode(self: *Assembler) ![]const u8 {
        return try self.code.toOwnedSlice(self.allocator);
    }

    // REX prefix: 0100WRXB
    // W = 1 for 64-bit operand size
    // R = extension of ModRM reg field
    // X = extension of SIB index field
    // B = extension of ModRM r/m field
    fn emitRex(self: *Assembler, w: bool, r: bool, x: bool, b: bool) !void {
        var rex: u8 = 0x40;
        if (w) rex |= 0x08;
        if (r) rex |= 0x04;
        if (x) rex |= 0x02;
        if (b) rex |= 0x01;
        try self.code.append(self.allocator, rex);
    }

    // ModR/M byte: MMrrr_mmm
    // MM = addressing mode
    // rrr = register operand
    // mmm = r/m operand
    fn emitModRM(self: *Assembler, mode: u8, reg: u8, rm: u8) !void {
        try self.code.append(self.allocator, (mode << 6) | ((reg & 0x7) << 3) | (rm & 0x7));
    }

    /// mov reg, imm64
    pub fn movRegImm64(self: *Assembler, dst: Register, imm: i64) !void {
        // REX.W + B0 + rd + imm64
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xB8 + dst.encodeModRM());
        try self.code.writer(self.allocator).writeInt(i64, imm, .little);
    }

    /// mov reg, reg
    pub fn movRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 89 /r
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x89);
        try self.emitModRM(0b11, @intFromEnum(src), @intFromEnum(dst));
    }

    /// add reg, reg
    pub fn addRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 01 /r
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x01);
        try self.emitModRM(0b11, @intFromEnum(src), @intFromEnum(dst));
    }

    /// sub reg, reg
    pub fn subRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 29 /r
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x29);
        try self.emitModRM(0b11, @intFromEnum(src), @intFromEnum(dst));
    }

    /// imul reg, reg (signed multiply)
    pub fn imulRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 0F AF /r
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xAF);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// push reg
    pub fn pushReg(self: *Assembler, reg: Register) !void {
        if (reg.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x50 + reg.encodeModRM());
    }

    /// pop reg
    pub fn popReg(self: *Assembler, reg: Register) !void {
        if (reg.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x58 + reg.encodeModRM());
    }

    /// ret (near return)
    pub fn ret(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xC3);
    }

    /// syscall
    pub fn syscall(self: *Assembler) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x05);
    }

    /// nop
    pub fn nop(self: *Assembler) !void {
        try self.code.append(self.allocator, 0x90);
    }

    /// xor reg, reg (common way to zero a register)
    pub fn xorRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 31 /r
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x31);
        try self.emitModRM(0b11, @intFromEnum(src), @intFromEnum(dst));
    }

    /// cmp reg, reg
    pub fn cmpRegReg(self: *Assembler, left: Register, right: Register) !void {
        // REX.W + 39 /r
        try self.emitRex(true, right.needsRexPrefix(), false, left.needsRexPrefix());
        try self.code.append(self.allocator, 0x39);
        try self.emitModRM(0b11, @intFromEnum(right), @intFromEnum(left));
    }

    /// jmp rel32 (relative jump)
    pub fn jmpRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0xE9);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// je rel32 (jump if equal)
    pub fn jeRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x84);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// jne rel32 (jump if not equal)
    pub fn jneRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x85);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// jl rel32 (jump if less)
    pub fn jlRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x8C);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// jle rel32 (jump if less or equal)
    pub fn jleRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x8E);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// jg rel32 (jump if greater)
    pub fn jgRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x8F);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// jge rel32 (jump if greater or equal)
    pub fn jgeRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x8D);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// call rel32 (relative call)
    pub fn callRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0xE8);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// Get current code position (for calculating jumps)
    pub fn getPosition(self: *Assembler) usize {
        return self.code.items.len;
    }

    /// Patch a rel32 offset at a specific position
    pub fn patchRel32(self: *Assembler, pos: usize, target: usize) !void {
        const current = pos + 4; // Position after the rel32
        const offset = @as(i32, @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(current))));
        std.mem.writeInt(i32, self.code.items[pos..][0..4], offset, .little);
    }
};
