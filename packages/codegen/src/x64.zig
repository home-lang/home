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

/// XMM SIMD registers (SSE/AVX)
pub const XmmRegister = enum(u8) {
    xmm0 = 0,
    xmm1 = 1,
    xmm2 = 2,
    xmm3 = 3,
    xmm4 = 4,
    xmm5 = 5,
    xmm6 = 6,
    xmm7 = 7,
    xmm8 = 8,
    xmm9 = 9,
    xmm10 = 10,
    xmm11 = 11,
    xmm12 = 12,
    xmm13 = 13,
    xmm14 = 14,
    xmm15 = 15,

    pub fn needsRexPrefix(self: XmmRegister) bool {
        return @intFromEnum(self) >= 8;
    }

    pub fn encodeModRM(self: XmmRegister) u8 {
        return @intFromEnum(self) & 0x7;
    }

    pub fn toYmm(self: XmmRegister) YmmRegister {
        return @enumFromInt(@intFromEnum(self));
    }
};

/// YMM SIMD registers (AVX/AVX2 - 256-bit)
pub const YmmRegister = enum(u8) {
    ymm0 = 0,
    ymm1 = 1,
    ymm2 = 2,
    ymm3 = 3,
    ymm4 = 4,
    ymm5 = 5,
    ymm6 = 6,
    ymm7 = 7,
    ymm8 = 8,
    ymm9 = 9,
    ymm10 = 10,
    ymm11 = 11,
    ymm12 = 12,
    ymm13 = 13,
    ymm14 = 14,
    ymm15 = 15,

    pub fn needsRexPrefix(self: YmmRegister) bool {
        return @intFromEnum(self) >= 8;
    }

    pub fn encodeModRM(self: YmmRegister) u8 {
        return @intFromEnum(self) & 0x7;
    }

    pub fn toXmm(self: YmmRegister) XmmRegister {
        return @enumFromInt(@intFromEnum(self));
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

        // Write i64 in little endian
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, imm, .little);
        try self.code.appendSlice(self.allocator, &bytes);
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
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// mov [base + offset], src - Store register to memory
    pub fn movMemReg(self: *Assembler, base: Register, offset: i32, src: Register) !void {
        // REX.W + 89 /r [base + disp32]
        try self.emitRex(true, src.needsRexPrefix(), false, base.needsRexPrefix());
        try self.code.append(self.allocator, 0x89);
        // ModRM byte: mod=10 (32-bit displacement), reg=src, rm=base
        try self.emitModRM(0b10, @intFromEnum(src), @intFromEnum(base));
        // Emit 32-bit displacement
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
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
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, disp32, .little);
        try self.code.appendSlice(self.allocator, &bytes);

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
            var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, disp, .little);
        try self.code.appendSlice(self.allocator, &bytes);
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
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, imm, .little);
        try self.code.appendSlice(self.allocator, &bytes);
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
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, imm, .little);
        try self.code.appendSlice(self.allocator, &bytes);
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
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, imm, .little);
        try self.code.appendSlice(self.allocator, &bytes);
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
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// je rel32 (jump if equal)
    pub fn jeRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x84);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// jne rel32 (jump if not equal)
    pub fn jneRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x85);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// jl rel32 (jump if less)
    pub fn jlRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x8C);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// jle rel32 (jump if less or equal)
    pub fn jleRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x8E);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// jg rel32 (jump if greater)
    pub fn jgRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x8F);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// jge rel32 (jump if greater or equal)
    pub fn jgeRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x8D);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// jns rel32 (jump if not sign / jump if positive)
    pub fn jnsRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x89); // JNS opcode
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// call rel32 (relative call)
    pub fn callRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0xE8);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
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
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// jnz rel32 (jump if not zero) - same as jne
    pub fn jnzRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x85);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
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

    /// Patch a jns rel32 instruction at a specific position
    pub fn patchJnsRel32(self: *Assembler, pos: usize, offset: i32) !void {
        // jns is 6 bytes: 0F 89 [rel32]
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

    // ============ SIMD Instructions (SSE2/SSE4) ============

    /// movdqa xmm, [base + offset] - Move aligned 128-bit integer from memory to XMM register
    pub fn movdqaXmmMem(self: *Assembler, dst: XmmRegister, base: Register, offset: i32) !void {
        // 66 0F 6F /r [base + disp32]
        try self.code.append(self.allocator, 0x66); // Operand-size prefix
        if (dst.needsRexPrefix() or base.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, base.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x6F);
        try self.emitModRM(0b10, dst.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// movdqa [base + offset], xmm - Move aligned 128-bit integer from XMM register to memory
    pub fn movdqaMemXmm(self: *Assembler, base: Register, offset: i32, src: XmmRegister) !void {
        // 66 0F 7F /r [base + disp32]
        try self.code.append(self.allocator, 0x66); // Operand-size prefix
        if (src.needsRexPrefix() or base.needsRexPrefix()) {
            try self.emitRex(false, src.needsRexPrefix(), false, base.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x7F);
        try self.emitModRM(0b10, src.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// paddd xmm1, xmm2 - Packed add doubleword (add 4x32-bit integers)
    pub fn padddXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F FE /r
        try self.code.append(self.allocator, 0x66); // Operand-size prefix
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xFE);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// psubd xmm1, xmm2 - Packed subtract doubleword (subtract 4x32-bit integers)
    pub fn psubdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F FA /r
        try self.code.append(self.allocator, 0x66); // Operand-size prefix
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xFA);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// pmulld xmm1, xmm2 - Packed multiply low doubleword (multiply 4x32-bit integers, keep low 32 bits)
    /// Requires SSE4.1
    pub fn pmulldXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 38 40 /r
        try self.code.append(self.allocator, 0x66); // Operand-size prefix
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x38);
        try self.code.append(self.allocator, 0x40);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// movq xmm, reg64 - Move quadword from general-purpose register to XMM register
    pub fn movqXmmReg(self: *Assembler, dst: XmmRegister, src: Register) !void {
        // 66 REX.W 0F 6E /r
        try self.code.append(self.allocator, 0x66); // Operand-size prefix
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x6E);
        try self.emitModRM(0b11, dst.encodeModRM(), @intFromEnum(src));
    }

    /// movq reg64, xmm - Move quadword from XMM register to general-purpose register
    pub fn movqRegXmm(self: *Assembler, dst: Register, src: XmmRegister) !void {
        // 66 REX.W 0F 7E /r
        try self.code.append(self.allocator, 0x66); // Operand-size prefix
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x7E);
        try self.emitModRM(0b11, src.encodeModRM(), @intFromEnum(dst));
    }

    /// pxor xmm1, xmm2 - Packed XOR (common way to zero an XMM register)
    pub fn pxorXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F EF /r
        try self.code.append(self.allocator, 0x66); // Operand-size prefix
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xEF);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// pshufd xmm1, xmm2, imm8 - Shuffle packed doublewords
    pub fn pshufdXmmXmmImm(self: *Assembler, dst: XmmRegister, src: XmmRegister, imm: u8) !void {
        // 66 0F 70 /r ib
        try self.code.append(self.allocator, 0x66); // Operand-size prefix
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x70);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
        try self.code.append(self.allocator, imm);
    }

    // ============ Floating-Point SIMD Instructions (SSE/SSE2) ============

    /// addps xmm1, xmm2 - Packed add single-precision (4x32-bit floats)
    pub fn addpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 58 /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x58);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// addpd xmm1, xmm2 - Packed add double-precision (2x64-bit floats)
    pub fn addpdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 58 /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x58);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// subps xmm1, xmm2 - Packed subtract single-precision (4x32-bit floats)
    pub fn subpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 5C /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5C);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// subpd xmm1, xmm2 - Packed subtract double-precision (2x64-bit floats)
    pub fn subpdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 5C /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5C);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// mulps xmm1, xmm2 - Packed multiply single-precision (4x32-bit floats)
    pub fn mulpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 59 /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x59);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// mulpd xmm1, xmm2 - Packed multiply double-precision (2x64-bit floats)
    pub fn mulpdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 59 /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x59);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// divps xmm1, xmm2 - Packed divide single-precision (4x32-bit floats)
    pub fn divpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 5E /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5E);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// divpd xmm1, xmm2 - Packed divide double-precision (2x64-bit floats)
    pub fn divpdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 5E /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5E);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// sqrtps xmm1, xmm2 - Packed square root single-precision (4x32-bit floats)
    pub fn sqrtpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 51 /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x51);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// sqrtpd xmm1, xmm2 - Packed square root double-precision (2x64-bit floats)
    pub fn sqrtpdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 51 /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x51);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// movaps xmm, [base + offset] - Move aligned packed single-precision
    pub fn movapsXmmMem(self: *Assembler, dst: XmmRegister, base: Register, offset: i32) !void {
        // 0F 28 /r [base + disp32]
        if (dst.needsRexPrefix() or base.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, base.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x28);
        try self.emitModRM(0b10, dst.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// movaps [base + offset], xmm - Store aligned packed single-precision
    pub fn movapsMemXmm(self: *Assembler, base: Register, offset: i32, src: XmmRegister) !void {
        // 0F 29 /r [base + disp32]
        if (src.needsRexPrefix() or base.needsRexPrefix()) {
            try self.emitRex(false, src.needsRexPrefix(), false, base.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x29);
        try self.emitModRM(0b10, src.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    // ============ VEX-encoded Helper ============

    /// Emit VEX prefix for 3-operand AVX instructions
    /// VEX format: C4/C5 RXB.m_mmmm W.vvvv.L.pp
    fn emitVex3(self: *Assembler, r: bool, x: bool, b: bool, m: u5, w: bool, vvvv: u4, l: bool, pp: u2) !void {
        // Use 3-byte VEX (C4) for full control
        try self.code.append(self.allocator, 0xC4);

        // Byte 1: RXB.m_mmmm (inverted R, X, B bits)
        const byte1 = (@as(u8, if (!r) 0x80 else 0) |
                       @as(u8, if (!x) 0x40 else 0) |
                       @as(u8, if (!b) 0x20 else 0) |
                       @as(u8, m));
        try self.code.append(self.allocator, byte1);

        // Byte 2: W.vvvv.L.pp (inverted vvvv)
        const byte2 = (@as(u8, if (w) 0x80 else 0) |
                       @as(u8, (~vvvv & 0xF) << 3) |
                       @as(u8, if (l) 0x04 else 0) |
                       @as(u8, pp));
        try self.code.append(self.allocator, byte2);
    }

    // ============ AVX Instructions (256-bit) ============

    /// vaddps ymm1, ymm2, ymm3 - AVX packed add single-precision (8x32-bit floats)
    pub fn vaddpsYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.0F.WIG 58 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001, // 0F opcode map
            false,   // W ignored
            @intFromEnum(src1),
            true,    // L=1 for 256-bit
            0b00,    // pp=0 (none)
        );
        try self.code.append(self.allocator, 0x58);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vaddpd ymm1, ymm2, ymm3 - AVX packed add double-precision (4x64-bit floats)
    pub fn vaddpdYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F.WIG 58 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001, // 0F opcode map
            false,   // W ignored
            @intFromEnum(src1),
            true,    // L=1 for 256-bit
            0b01,    // pp=1 (66 prefix)
        );
        try self.code.append(self.allocator, 0x58);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vmulps ymm1, ymm2, ymm3 - AVX packed multiply single-precision (8x32-bit floats)
    pub fn vmulpsYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.0F.WIG 59 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001,
            false,
            @intFromEnum(src1),
            true,
            0b00,
        );
        try self.code.append(self.allocator, 0x59);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vmulpd ymm1, ymm2, ymm3 - AVX packed multiply double-precision (4x64-bit floats)
    pub fn vmulpdYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F.WIG 59 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001,
            false,
            @intFromEnum(src1),
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0x59);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vsubps ymm1, ymm2, ymm3 - AVX packed subtract single-precision (8x32-bit floats)
    pub fn vsubpsYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.0F.WIG 5C /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001,
            false,
            @intFromEnum(src1),
            true,
            0b00,
        );
        try self.code.append(self.allocator, 0x5C);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vsubpd ymm1, ymm2, ymm3 - AVX packed subtract double-precision (4x64-bit floats)
    pub fn vsubpdYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F.WIG 5C /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001,
            false,
            @intFromEnum(src1),
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0x5C);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vdivps ymm1, ymm2, ymm3 - AVX packed divide single-precision (8x32-bit floats)
    pub fn vdivpsYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.0F.WIG 5E /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001,
            false,
            @intFromEnum(src1),
            true,
            0b00,
        );
        try self.code.append(self.allocator, 0x5E);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vdivpd ymm1, ymm2, ymm3 - AVX packed divide double-precision (4x64-bit floats)
    pub fn vdivpdYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F.WIG 5E /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001,
            false,
            @intFromEnum(src1),
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0x5E);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vpaddd ymm1, ymm2, ymm3 - AVX2 packed add doubleword (8x32-bit integers)
    pub fn vpadddYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F.WIG FE /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001,
            false,
            @intFromEnum(src1),
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0xFE);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vpsubd ymm1, ymm2, ymm3 - AVX2 packed subtract doubleword (8x32-bit integers)
    pub fn vpsubdYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F.WIG FA /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001,
            false,
            @intFromEnum(src1),
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0xFA);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vpmulld ymm1, ymm2, ymm3 - AVX2 packed multiply low doubleword (8x32-bit integers)
    pub fn vpmulldYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F38.WIG 40 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00010, // 0F38 opcode map
            false,
            @intFromEnum(src1),
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0x40);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vmovdqa ymm, [base + offset] - Move aligned 256-bit integer from memory
    pub fn vmovdqaYmmMem(self: *Assembler, dst: YmmRegister, base: Register, offset: i32) !void {
        // VEX.256.66.0F.WIG 6F /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            base.needsRexPrefix(),
            0b00001,
            false,
            0, // vvvv unused
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0x6F);
        try self.emitModRM(0b10, dst.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// vmovdqa [base + offset], ymm - Store aligned 256-bit integer to memory
    pub fn vmovdqaMemYmm(self: *Assembler, base: Register, offset: i32, src: YmmRegister) !void {
        // VEX.256.66.0F.WIG 7F /r
        try self.emitVex3(
            src.needsRexPrefix(),
            false,
            base.needsRexPrefix(),
            0b00001,
            false,
            0, // vvvv unused
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0x7F);
        try self.emitModRM(0b10, src.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// vpxor ymm1, ymm2, ymm3 - AVX2 packed XOR (common way to zero a YMM register)
    pub fn vpxorYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F.WIG EF /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00001,
            false,
            @intFromEnum(src1),
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0xEF);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    // ============ FMA Instructions (FMA3) ============

    /// vfmadd213ps xmm1, xmm2, xmm3 - FMA: xmm1 = (xmm1 * xmm2) + xmm3 (4x32-bit)
    pub fn vfmadd213psXmmXmmXmm(self: *Assembler, dst: XmmRegister, src1: XmmRegister, src2: XmmRegister) !void {
        // VEX.128.66.0F38.W0 A8 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00010, // 0F38 map
            false,   // W=0
            @intFromEnum(src1),
            false,   // L=0 for 128-bit
            0b01,    // pp=01 (66 prefix)
        );
        try self.code.append(self.allocator, 0xA8);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vfmadd213pd xmm1, xmm2, xmm3 - FMA: xmm1 = (xmm1 * xmm2) + xmm3 (2x64-bit)
    pub fn vfmadd213pdXmmXmmXmm(self: *Assembler, dst: XmmRegister, src1: XmmRegister, src2: XmmRegister) !void {
        // VEX.128.66.0F38.W1 A8 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00010, // 0F38 map
            true,    // W=1 for double precision
            @intFromEnum(src1),
            false,   // L=0 for 128-bit
            0b01,    // pp=01 (66 prefix)
        );
        try self.code.append(self.allocator, 0xA8);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vfmadd213ps ymm1, ymm2, ymm3 - FMA: ymm1 = (ymm1 * ymm2) + ymm3 (8x32-bit)
    pub fn vfmadd213psYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F38.W0 A8 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00010,
            false,
            @intFromEnum(src1),
            true,    // L=1 for 256-bit
            0b01,
        );
        try self.code.append(self.allocator, 0xA8);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    /// vfmadd213pd ymm1, ymm2, ymm3 - FMA: ymm1 = (ymm1 * ymm2) + ymm3 (4x64-bit)
    pub fn vfmadd213pdYmmYmmYmm(self: *Assembler, dst: YmmRegister, src1: YmmRegister, src2: YmmRegister) !void {
        // VEX.256.66.0F38.W1 A8 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            src2.needsRexPrefix(),
            0b00010,
            true,
            @intFromEnum(src1),
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0xA8);
        try self.emitModRM(0b11, dst.encodeModRM(), src2.encodeModRM());
    }

    // ============ Horizontal Operations ============

    /// haddps xmm1, xmm2 - Horizontal add packed single-precision
    pub fn haddpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // F2 0F 7C /r
        try self.code.append(self.allocator, 0xF2);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x7C);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// haddpd xmm1, xmm2 - Horizontal add packed double-precision
    pub fn haddpdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 7C /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x7C);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    // ============ Comparison Operations ============

    /// cmpps xmm1, xmm2, imm8 - Compare packed single-precision
    pub fn cmppsXmmXmmImm(self: *Assembler, dst: XmmRegister, src: XmmRegister, imm: u8) !void {
        // 0F C2 /r ib
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xC2);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
        try self.code.append(self.allocator, imm);
    }

    /// cmppd xmm1, xmm2, imm8 - Compare packed double-precision
    pub fn cmppdXmmXmmImm(self: *Assembler, dst: XmmRegister, src: XmmRegister, imm: u8) !void {
        // 66 0F C2 /r ib
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xC2);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
        try self.code.append(self.allocator, imm);
    }

    // ============ Blend Operations ============

    /// blendvps xmm1, xmm2, xmm0 - Blend packed single-precision using XMM0 mask
    pub fn blendvpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 38 14 /r (mask in XMM0)
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x38);
        try self.code.append(self.allocator, 0x14);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// blendvpd xmm1, xmm2, xmm0 - Blend packed double-precision using XMM0 mask
    pub fn blendvpdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 38 15 /r (mask in XMM0)
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x38);
        try self.code.append(self.allocator, 0x15);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    // ============ Min/Max Operations ============

    /// minps xmm1, xmm2 - Minimum of packed single-precision
    pub fn minpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 5D /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5D);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// maxps xmm1, xmm2 - Maximum of packed single-precision
    pub fn maxpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 5F /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5F);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    // ============ Broadcast Operations ============

    /// vbroadcastss xmm, m32 - Broadcast single float to all elements
    pub fn vbroadcastssXmmMem(self: *Assembler, dst: XmmRegister, base: Register, offset: i32) !void {
        // VEX.128.66.0F38.W0 18 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            base.needsRexPrefix(),
            0b00010, // 0F38 map
            false,
            0, // vvvv unused
            false, // L=0 for 128-bit
            0b01,
        );
        try self.code.append(self.allocator, 0x18);
        try self.emitModRM(0b10, dst.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// vbroadcastss ymm, m32 - Broadcast single float to all 8 elements
    pub fn vbroadcastssYmmMem(self: *Assembler, dst: YmmRegister, base: Register, offset: i32) !void {
        // VEX.256.66.0F38.W0 18 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            base.needsRexPrefix(),
            0b00010,
            false,
            0,
            true, // L=1 for 256-bit
            0b01,
        );
        try self.code.append(self.allocator, 0x18);
        try self.emitModRM(0b10, dst.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// vbroadcastsd ymm, m64 - Broadcast single double to all 4 elements
    pub fn vbroadcastsdYmmMem(self: *Assembler, dst: YmmRegister, base: Register, offset: i32) !void {
        // VEX.256.66.0F38.W0 19 /r
        try self.emitVex3(
            dst.needsRexPrefix(),
            false,
            base.needsRexPrefix(),
            0b00010,
            false,
            0,
            true,
            0b01,
        );
        try self.code.append(self.allocator, 0x19);
        try self.emitModRM(0b10, dst.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    // ============ Conversion Instructions ============

    /// cvtdq2ps xmm, xmm - Convert packed i32 to f32
    pub fn cvtdq2psXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 5B /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5B);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// cvtps2dq xmm, xmm - Convert packed f32 to i32 (truncate)
    pub fn cvtps2dqXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 5B /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5B);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// cvtpd2ps xmm, xmm - Convert packed f64 to f32
    pub fn cvtpd2psXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 5A /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5A);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// cvtps2pd xmm, xmm - Convert packed f32 to f64
    pub fn cvtps2pdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 5A /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5A);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    // ============ Unaligned Load/Store ============

    /// movups xmm, [base + offset] - Move unaligned packed single-precision
    pub fn movupsXmmMem(self: *Assembler, dst: XmmRegister, base: Register, offset: i32) !void {
        // 0F 10 /r
        if (dst.needsRexPrefix() or base.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, base.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x10);
        try self.emitModRM(0b10, dst.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// movups [base + offset], xmm - Store unaligned packed single-precision
    pub fn movupsMemXmm(self: *Assembler, base: Register, offset: i32, src: XmmRegister) !void {
        // 0F 11 /r
        if (src.needsRexPrefix() or base.needsRexPrefix()) {
            try self.emitRex(false, src.needsRexPrefix(), false, base.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x11);
        try self.emitModRM(0b10, src.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// movdqu xmm, [base + offset] - Move unaligned 128-bit integer
    pub fn movdquXmmMem(self: *Assembler, dst: XmmRegister, base: Register, offset: i32) !void {
        // F3 0F 6F /r
        try self.code.append(self.allocator, 0xF3);
        if (dst.needsRexPrefix() or base.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, base.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x6F);
        try self.emitModRM(0b10, dst.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// movdqu [base + offset], xmm - Store unaligned 128-bit integer
    pub fn movdquMemXmm(self: *Assembler, base: Register, offset: i32, src: XmmRegister) !void {
        // F3 0F 7F /r
        try self.code.append(self.allocator, 0xF3);
        if (src.needsRexPrefix() or base.needsRexPrefix()) {
            try self.emitRex(false, src.needsRexPrefix(), false, base.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x7F);
        try self.emitModRM(0b10, src.encodeModRM(), @intFromEnum(base));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    // ============ Bit Manipulation ============

    /// pslld xmm, imm8 - Shift left logical doubleword by immediate
    pub fn pslldXmmImm(self: *Assembler, dst: XmmRegister, imm: u8) !void {
        // 66 0F 72 /6 ib
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, dst.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x72);
        try self.emitModRM(0b11, 6, dst.encodeModRM());
        try self.code.append(self.allocator, imm);
    }

    /// psrld xmm, imm8 - Shift right logical doubleword by immediate
    pub fn psrldXmmImm(self: *Assembler, dst: XmmRegister, imm: u8) !void {
        // 66 0F 72 /2 ib
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, dst.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x72);
        try self.emitModRM(0b11, 2, dst.encodeModRM());
        try self.code.append(self.allocator, imm);
    }

    /// psrad xmm, imm8 - Shift right arithmetic doubleword by immediate
    pub fn psradXmmImm(self: *Assembler, dst: XmmRegister, imm: u8) !void {
        // 66 0F 72 /4 ib
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, dst.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x72);
        try self.emitModRM(0b11, 4, dst.encodeModRM());
        try self.code.append(self.allocator, imm);
    }

    /// pand xmm1, xmm2 - Bitwise AND
    pub fn pandXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F DB /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xDB);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// por xmm1, xmm2 - Bitwise OR
    pub fn porXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F EB /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xEB);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// pandn xmm1, xmm2 - Bitwise AND NOT (xmm1 = ~xmm1 & xmm2)
    pub fn pandnXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F DF /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xDF);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    // ============ Absolute Value & Sign Manipulation ============

    /// andps xmm1, xmm2 - Bitwise AND for floats (used for abs)
    pub fn andpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 54 /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x54);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// andnps xmm1, xmm2 - Bitwise AND NOT for floats
    pub fn andnpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 55 /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x55);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// orps xmm1, xmm2 - Bitwise OR for floats (used for sign manipulation)
    pub fn orpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 56 /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x56);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// xorps xmm1, xmm2 - Bitwise XOR for floats (used for negation)
    pub fn xorpsXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 0F 57 /r
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x57);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// pabsd xmm, xmm - Absolute value of packed i32 (SSSE3)
    pub fn pabsdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        // 66 0F 38 1E /r
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x38);
        try self.code.append(self.allocator, 0x1E);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }
};
