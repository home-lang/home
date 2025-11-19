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

    /// mov reg, [base + offset] - Load from memory
    pub fn movRegMem(self: *Assembler, dst: Register, base: Register, offset: i32) !void {
        // REX.W + 8B /r [base + disp32]
        try self.emitRex(true, dst.needsRexPrefix(), false, base.needsRexPrefix());
        try self.code.append(self.allocator, 0x8B);
        // ModRM byte: mod=10 (32-bit displacement), reg=dst, rm=base
        try self.emitModRM(0b10, @intFromEnum(dst), @intFromEnum(base));
        // Emit 32-bit displacement
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// mov [base + offset], src - Store register to memory
    pub fn movMemReg(self: *Assembler, base: Register, offset: i32, src: Register) !void {
        // REX.W + 89 /r [base + disp32]
        try self.emitRex(true, src.needsRexPrefix(), false, base.needsRexPrefix());
        try self.code.append(self.allocator, 0x89);
        // ModRM byte: mod=10 (32-bit displacement), reg=src, rm=base
        try self.emitModRM(0b10, @intFromEnum(src), @intFromEnum(base));
        // Emit 32-bit displacement
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// lea reg, [rip + disp32] - Load Effective Address with RIP-relative addressing
    /// This is used for loading addresses of data in the data section
    /// Returns the position where the displacement was written so it can be patched later
    pub fn leaRipRel(self: *Assembler, dst: Register, disp32: i32) !usize {
        // REX.W + 8D /r [rip + disp32]
        // ModRM for RIP-relative: mod=00, reg=dst, rm=101 (RIP-relative)
        try self.emitRex(true, dst.needsRexPrefix(), false, false);
        try self.code.append(self.allocator, 0x8D); // LEA opcode

        // ModRM byte: mod=00 (no displacement, but RIP-relative uses disp32)
        // reg=dst, rm=101 (0b101 = RIP-relative addressing)
        const modrm = (0b00 << 6) | ((@intFromEnum(dst) & 0x7) << 3) | 0b101;
        try self.code.append(self.allocator, modrm);

        // Remember position where we write the displacement
        const disp_pos = self.code.items.len;

        // Emit 32-bit displacement (offset from RIP)
        try self.code.writer(self.allocator).writeInt(i32, disp32, .little);

        return disp_pos;
    }

    /// Patch a previously written RIP-relative displacement
    pub fn patchLeaRipRel(self: *Assembler, disp_pos: usize, new_disp: i32) !void {
        std.mem.writeInt(i32, self.code.items[disp_pos..][0..4], new_disp, .little);
    }

    /// lea dst, [src + disp]
    pub fn leaRegMem(self: *Assembler, dst: Register, src: Register, disp: i32) !void {
        // REX.W + 8D /r [src + disp]
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x8D); // LEA opcode

        // Determine addressing mode based on displacement
        if (disp == 0 and src != .rsp and src != .r12) {
            // mod=00 (no displacement)
            try self.emitModRM(0b00, @intFromEnum(dst), @intFromEnum(src));
        } else if (disp >= -128 and disp <= 127) {
            // mod=01 (disp8)
            try self.emitModRM(0b01, @intFromEnum(dst), @intFromEnum(src));
            if (src == .rsp or src == .r12) {
                try self.code.append(self.allocator, 0x24); // SIB for rsp/r12
            }
            try self.code.append(self.allocator, @bitCast(@as(i8, @intCast(disp))));
        } else {
            // mod=10 (disp32)
            try self.emitModRM(0b10, @intFromEnum(dst), @intFromEnum(src));
            if (src == .rsp or src == .r12) {
                try self.code.append(self.allocator, 0x24); // SIB for rsp/r12
            }
            try self.code.writer(self.allocator).writeInt(i32, disp, .little);
        }
    }

    /// add reg, reg
    pub fn addRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 01 /r
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x01);
        try self.emitModRM(0b11, @intFromEnum(src), @intFromEnum(dst));
    }

    pub fn addRegImm32(self: *Assembler, dst: Register, imm: i32) !void {
        // REX.W + 81 /0 imm32
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x81);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
        try self.code.writer(self.allocator).writeInt(i32, imm, .little);
    }

    /// sub reg, reg
    pub fn subRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 29 /r
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x29);
        try self.emitModRM(0b11, @intFromEnum(src), @intFromEnum(dst));
    }

    /// sub reg, imm32
    pub fn subRegImm32(self: *Assembler, dst: Register, imm: i32) !void {
        // REX.W + 81 /5 imm32
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x81);
        try self.emitModRM(0b11, 5, @intFromEnum(dst));
        try self.code.writer(self.allocator).writeInt(i32, imm, .little);
    }

    /// imul reg, reg (signed multiply)
    pub fn imulRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 0F AF /r
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xAF);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// imul dst, imm32 - multiply register by immediate
    pub fn imulRegImm32(self: *Assembler, dst: Register, imm: i32) !void {
        // REX.W + 69 /r imm32
        try self.emitRex(true, dst.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x69);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(dst));
        try self.code.writer(self.allocator).writeInt(i32, imm, .little);
    }

    /// idiv reg (signed divide: rdx:rax / reg -> rax=quotient, rdx=remainder)
    /// Note: caller must set up rdx:rax (typically via cqo to sign-extend rax into rdx)
    pub fn idivReg(self: *Assembler, divisor: Register) !void {
        // REX.W + F7 /7
        try self.emitRex(true, false, false, divisor.needsRexPrefix());
        try self.code.append(self.allocator, 0xF7);
        try self.emitModRM(0b11, 7, @intFromEnum(divisor));
    }

    /// cqo - sign extend rax into rdx:rax (for division)
    pub fn cqo(self: *Assembler) !void {
        // REX.W + 99
        try self.emitRex(true, false, false, false);
        try self.code.append(self.allocator, 0x99);
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

    /// and reg, reg (bitwise AND)
    pub fn andRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 21 /r
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x21);
        try self.emitModRM(0b11, @intFromEnum(src), @intFromEnum(dst));
    }

    /// or reg, reg (bitwise OR)
    pub fn orRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 09 /r
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x09);
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

    /// test reg, reg (AND operation but only sets flags, doesn't store result)
    pub fn testRegReg(self: *Assembler, left: Register, right: Register) !void {
        // REX.W + 85 /r
        try self.emitRex(true, right.needsRexPrefix(), false, left.needsRexPrefix());
        try self.code.append(self.allocator, 0x85);
        try self.emitModRM(0b11, @intFromEnum(right), @intFromEnum(left));
    }

    /// jz rel32 (jump if zero) - same as je
    pub fn jzRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x84);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// jnz rel32 (jump if not zero) - same as jne
    pub fn jnzRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x85);
        try self.code.writer(self.allocator).writeInt(i32, offset, .little);
    }

    /// Patch a jz (je) rel32 instruction at a specific position
    pub fn patchJzRel32(self: *Assembler, pos: usize, offset: i32) !void {
        // jz/je is 6 bytes: 0F 84 [rel32]
        // The rel32 starts at pos + 2
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    /// Patch a jnz (jne) rel32 instruction at a specific position
    pub fn patchJnzRel32(self: *Assembler, pos: usize, offset: i32) !void {
        // jnz/jne is 6 bytes: 0F 85 [rel32]
        // The rel32 starts at pos + 2
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    /// Patch a jmp rel32 instruction at a specific position
    pub fn patchJmpRel32(self: *Assembler, pos: usize, offset: i32) !void {
        // jmp is 5 bytes: E9 [rel32]
        // The rel32 starts at pos + 1
        std.mem.writeInt(i32, self.code.items[pos + 1 ..][0..4], offset, .little);
    }

    /// Patch a je rel32 instruction at a specific position
    pub fn patchJeRel32(self: *Assembler, pos: usize, offset: i32) !void {
        // je is 6 bytes: 0F 84 [rel32]
        // The rel32 starts at pos + 2
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    /// Patch a jne rel32 instruction at a specific position
    pub fn patchJneRel32(self: *Assembler, pos: usize, offset: i32) !void {
        // jne is 6 bytes: 0F 85 [rel32]
        // The rel32 starts at pos + 2
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    /// Patch a jl rel32 instruction at a specific position
    pub fn patchJlRel32(self: *Assembler, pos: usize, offset: i32) !void {
        // jl is 6 bytes: 0F 8C [rel32]
        // The rel32 starts at pos + 2
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    /// sete reg (set byte on equal)
    pub fn seteReg(self: *Assembler, dst: Register) !void {
        // REX (if needed) + 0F 94 /r
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x94);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    /// setne reg (set byte on not equal)
    pub fn setneReg(self: *Assembler, dst: Register) !void {
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x95);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    /// setl reg (set byte on less than, signed)
    pub fn setlReg(self: *Assembler, dst: Register) !void {
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x9C);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    /// setle reg (set byte on less than or equal, signed)
    pub fn setleReg(self: *Assembler, dst: Register) !void {
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x9E);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    /// setg reg (set byte on greater than, signed)
    pub fn setgReg(self: *Assembler, dst: Register) !void {
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x9F);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    /// setge reg (set byte on greater than or equal, signed)
    pub fn setgeReg(self: *Assembler, dst: Register) !void {
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x9D);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    /// setz reg (set byte on zero flag, alias for sete)
    pub fn setzReg(self: *Assembler, dst: Register) !void {
        // SETZ is the same as SETE (both check ZF=1)
        // REX (if needed) + 0F 94 /r
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x94);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    /// neg reg (two's complement negation)
    pub fn negReg(self: *Assembler, dst: Register) !void {
        // REX.W + F7 /3
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xF7);
        try self.emitModRM(0b11, 3, @intFromEnum(dst));
    }

    /// not reg (bitwise NOT, one's complement)
    pub fn notReg(self: *Assembler, dst: Register) !void {
        // REX.W + F7 /2
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xF7);
        try self.emitModRM(0b11, 2, @intFromEnum(dst));
    }

    /// shl reg, cl (shift left by value in CL register)
    pub fn shlRegCl(self: *Assembler, dst: Register) !void {
        // REX.W + D3 /4
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xD3);
        try self.emitModRM(0b11, 4, @intFromEnum(dst));
    }

    /// shr reg, cl (logical shift right by value in CL register)
    pub fn shrRegCl(self: *Assembler, dst: Register) !void {
        // REX.W + D3 /5
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xD3);
        try self.emitModRM(0b11, 5, @intFromEnum(dst));
    }

    /// sar reg, cl (arithmetic shift right by value in CL register)
    pub fn sarRegCl(self: *Assembler, dst: Register) !void {
        // REX.W + D3 /7
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xD3);
        try self.emitModRM(0b11, 7, @intFromEnum(dst));
    }

    /// movzx reg64, reg8 (zero-extend 8-bit to 64-bit)
    pub fn movzxReg64Reg8(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 0F B6 /r
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xB6);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// inc reg (increment register by 1)
    pub fn incReg(self: *Assembler, dst: Register) !void {
        // REX.W + FF /0
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xFF);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    /// Patch jg rel32 at position
    pub fn patchJgRel32(self: *Assembler, pos: usize, offset: i32) !void {
        // jg is 6 bytes: 0F 8F offset32
        // Patch the offset32 at pos + 2
        const offset_bytes = @as([4]u8, @bitCast(@as(i32, offset)));
        self.code.items[pos + 2] = offset_bytes[0];
        self.code.items[pos + 3] = offset_bytes[1];
        self.code.items[pos + 4] = offset_bytes[2];
        self.code.items[pos + 5] = offset_bytes[3];
    }

    /// Patch jge rel32 at position
    pub fn patchJgeRel32(self: *Assembler, pos: usize, offset: i32) !void {
        // jge is 6 bytes: 0F 8D offset32
        // Patch the offset32 at pos + 2
        const offset_bytes = @as([4]u8, @bitCast(@as(i32, offset)));
        self.code.items[pos + 2] = offset_bytes[0];
        self.code.items[pos + 3] = offset_bytes[1];
        self.code.items[pos + 4] = offset_bytes[2];
        self.code.items[pos + 5] = offset_bytes[3];
    }

    /// movzx reg64, byte [base + offset] - Zero-extend byte from memory to 64-bit register
    pub fn movzxReg64Mem8(self: *Assembler, dst: Register, base: Register, offset: i32) !void {
        // REX.W + 0F B6 /r [base + disp32]
        try self.emitRex(true, dst.needsRexPrefix(), false, base.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xB6);

        // r12 and rsp require SIB byte even with offset=0
        const needs_sib = (base == .r12 or base == .rsp);

        if (offset == 0 and base != .rbp and !needs_sib) {
            // [base] with no displacement (ModRM = 00)
            try self.emitModRM(0b00, @intFromEnum(dst), @intFromEnum(base));
        } else if (offset == 0 and needs_sib) {
            // [base] with SIB byte but no displacement
            try self.emitModRM(0b00, @intFromEnum(dst), 0b100); // 0b100 indicates SIB follows
            try self.code.append(self.allocator, 0x24); // SIB: scale=0, index=rsp(4), base=r12/rsp
        } else {
            // [base + disp32] (ModRM = 10)
            try self.emitModRM(0b10, @intFromEnum(dst), @intFromEnum(base));
            const offset_bytes = @as([4]u8, @bitCast(offset));
            try self.code.appendSlice(self.allocator, &offset_bytes);
        }
    }

    /// mov byte [base + offset], reg8 - Store low 8 bits of register to memory
    pub fn movByteMemReg(self: *Assembler, base: Register, offset: i32, src: Register) !void {
        // 88 /r [base + disp32]
        // No REX prefix needed for byte access to low 8 bits
        try self.code.append(self.allocator, 0x88);

        if (offset == 0 and base != .rbp) {
            // [base] with no displacement
            try self.emitModRM(0b00, @intFromEnum(src), @intFromEnum(base));
        } else {
            // [base + disp32]
            try self.emitModRM(0b10, @intFromEnum(src), @intFromEnum(base));
            const offset_bytes = @as([4]u8, @bitCast(offset));
            try self.code.appendSlice(self.allocator, &offset_bytes);
        }
    }

    /// mov byte [base + offset], imm8 - Store immediate byte to memory
    pub fn movByteMemImm(self: *Assembler, base: Register, offset: i32, value: u8) !void {
        // C6 /0 [base + disp32] imm8
        try self.code.append(self.allocator, 0xC6);

        if (offset == 0 and base != .rbp) {
            // [base] with no displacement
            try self.emitModRM(0b00, 0, @intFromEnum(base));
        } else {
            // [base + disp32]
            try self.emitModRM(0b10, 0, @intFromEnum(base));
            const offset_bytes = @as([4]u8, @bitCast(offset));
            try self.code.appendSlice(self.allocator, &offset_bytes);
        }

        try self.code.append(self.allocator, value);
    }

    /// add reg, imm32 - Add immediate to register
    pub fn addRegImm(self: *Assembler, dst: Register, value: i32) !void {
        // REX.W + 81 /0 imm32
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x81);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
        const value_bytes = @as([4]u8, @bitCast(value));
        try self.code.appendSlice(self.allocator, &value_bytes);
    }

    /// sub reg, imm32 - Subtract immediate from register
    pub fn subRegImm(self: *Assembler, dst: Register, value: i32) !void {
        // REX.W + 81 /5 imm32
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x81);
        try self.emitModRM(0b11, 5, @intFromEnum(dst));
        const value_bytes = @as([4]u8, @bitCast(value));
        try self.code.appendSlice(self.allocator, &value_bytes);
    }

    /// cmp reg, imm32 - Compare register with immediate
    pub fn cmpRegImm(self: *Assembler, dst: Register, value: i32) !void {
        // REX.W + 81 /7 imm32
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x81);
        try self.emitModRM(0b11, 7, @intFromEnum(dst));
        const value_bytes = @as([4]u8, @bitCast(value));
        try self.code.appendSlice(self.allocator, &value_bytes);
    }

    /// jmp rel8 - Unconditional jump (short)
    pub fn jmpRel8(self: *Assembler, offset: i8) !usize {
        const pos = self.code.items.len;
        try self.code.append(self.allocator, 0xEB);
        try self.code.append(self.allocator, @bitCast(offset));
        return pos;
    }

    /// je rel8 - Jump if equal (short)
    pub fn jeRel8(self: *Assembler, offset: i8) !usize {
        const pos = self.code.items.len;
        try self.code.append(self.allocator, 0x74);
        try self.code.append(self.allocator, @bitCast(offset));
        return pos;
    }

    /// jne rel8 - Jump if not equal (short)
    pub fn jneRel8(self: *Assembler, offset: i8) !usize {
        const pos = self.code.items.len;
        try self.code.append(self.allocator, 0x75);
        try self.code.append(self.allocator, @bitCast(offset));
        return pos;
    }

    /// Patch je rel8 at position
    pub fn patchJe8(self: *Assembler, pos: usize, offset: i8) void {
        self.code.items[pos + 1] = @bitCast(offset);
    }

    /// Patch jne rel8 at position
    pub fn patchJne8(self: *Assembler, pos: usize, offset: i8) void {
        self.code.items[pos + 1] = @bitCast(offset);
    }

    /// Patch jmp rel8 at position
    pub fn patchJmp8(self: *Assembler, pos: usize, offset: i8) void {
        self.code.items[pos + 1] = @bitCast(offset);
    }
};
