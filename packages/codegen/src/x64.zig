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
            .code = std.ArrayList(u8).empty,
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
        // REX.W + B8+rd + imm64
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xB8 + dst.encodeModRM());

        // Write i64 in little endian
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, imm, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// mov reg, imm32 (zero-extended to 64-bit)
    pub fn movRegImm32(self: *Assembler, dst: Register, imm: i32) !void {
        // For r8–r15 the high bit of the register number is encoded in
        // the REX.B prefix; without it the CPU decodes eax–edi instead.
        if (dst.needsRexPrefix()) {
            try self.code.append(self.allocator, 0x41); // REX.B
        }
        try self.code.append(self.allocator, 0xB8 + dst.encodeModRM());

        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, imm, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// mov reg, reg
    pub fn movRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // REX.W + 89 /r
        try self.emitRex(true, src.needsRexPrefix(), false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x89);
        try self.emitModRM(0b11, @intFromEnum(src), @intFromEnum(dst));
    }

    /// mov reg, [base + offset] - Load from memory.
    ///
    /// x64 quirk: when the base register's low 3 bits are 0b100 (rsp, r12),
    /// the modrm rm value 100 is RESERVED to indicate "next byte is SIB".
    /// We MUST emit a SIB byte for those bases or the CPU will interpret
    /// our displacement bytes as a SIB descriptor and read garbage.
    pub fn movRegMem(self: *Assembler, dst: Register, base: Register, offset: i32) !void {
        try self.emitRex(true, dst.needsRexPrefix(), false, base.needsRexPrefix());
        try self.code.append(self.allocator, 0x8B);
        try self.emitMemModRM(@intFromEnum(dst), base, offset);
    }

    /// mov [base + offset], src - Store register to memory. Same SIB rule
    /// as movRegMem — see that function for details.
    pub fn movMemReg(self: *Assembler, base: Register, offset: i32, src: Register) !void {
        try self.emitRex(true, src.needsRexPrefix(), false, base.needsRexPrefix());
        try self.code.append(self.allocator, 0x89);
        try self.emitMemModRM(@intFromEnum(src), base, offset);
    }

    /// Emit the ModRM + (optional SIB) + displacement bytes for a
    /// `[base + offset]` memory operand. `reg` is the encoding of the
    /// "other" operand (the register half of the operation). Picks the
    /// shortest legal encoding:
    ///   - mod=00 if offset==0 AND base isn't rbp/r13 (those need disp8)
    ///   - mod=01 if offset fits in i8
    ///   - mod=10 otherwise (32-bit displacement)
    /// Always emits a SIB byte when the base's low 3 bits == 100
    /// (rsp / r12).
    fn emitMemModRM(self: *Assembler, reg: u8, base: Register, offset: i32) !void {
        const base_enc: u8 = @intFromEnum(base) & 0b111;
        const needs_sib = base_enc == 0b100;
        // rbp / r13 (low 3 bits == 101) cannot use mod=00 form — that
        // encoding means RIP-relative. Force at least mod=01 with disp8=0.
        const is_rbp_like = base_enc == 0b101;

        const mod: u2 = if (offset == 0 and !is_rbp_like) 0b00
            else if (offset >= -128 and offset <= 127) 0b01
            else 0b10;

        // ModRM
        const modrm_byte = (@as(u8, mod) << 6) | ((reg & 0b111) << 3) | base_enc;
        try self.code.append(self.allocator, modrm_byte);

        // SIB byte (only when base is rsp/r12).
        if (needs_sib) {
            // SIB: scale=00, index=100 (none), base=base_enc
            const sib_byte: u8 = (0b00 << 6) | (0b100 << 3) | base_enc;
            try self.code.append(self.allocator, sib_byte);
        }

        // Displacement.
        switch (mod) {
            0b00 => {}, // no displacement
            0b01 => try self.code.append(self.allocator, @as(u8, @bitCast(@as(i8, @intCast(offset))))),
            0b10 => {
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(i32, &bytes, offset, .little);
                try self.code.appendSlice(self.allocator, &bytes);
            },
            else => unreachable,
        }
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

    /// Scale factor for SIB addressing. The encoded field is log2(scale),
    /// so only 1/2/4/8 are valid.
    pub const SibScale = enum(u2) {
        one = 0,
        two = 1,
        four = 2,
        eight = 3,
    };

    /// lea dst, [base + index*scale + disp]. Emits a SIB byte so the full
    /// x64 addressing form is available — useful for `base + i*8`
    /// array-element addressing without a separate imul+add sequence.
    ///
    /// Constraints: index must not be .rsp (the encoding reserves 0b100
    /// in the index field to mean "no index"). Callers who need rsp as
    /// the index must swap base/index first.
    pub fn leaRegMemSib(
        self: *Assembler,
        dst: Register,
        base: Register,
        index: Register,
        scale: SibScale,
        disp: i32,
    ) !void {
        if (index == .rsp) return error.InvalidSibIndex;

        // REX.W + 8D /r [SIB + disp]
        try self.emitRex(
            true,
            dst.needsRexPrefix(),
            index.needsRexPrefix(),
            base.needsRexPrefix(),
        );
        try self.code.append(self.allocator, 0x8D);

        // r/m = 0b100 signals "SIB follows". Addressing mode picks
        // between no-disp / disp8 / disp32. Note: base == rbp / r13 with
        // mod==0b00 is encoded differently (no-base form), so we promote
        // to disp8(0) in that case.
        const base_is_bp_family = base == .rbp or base == .r13;
        const mod: u2 = if (disp == 0 and !base_is_bp_family)
            0b00
        else if (disp >= -128 and disp <= 127)
            0b01
        else
            0b10;

        try self.emitModRM(mod, @intFromEnum(dst), 0b100);

        // SIB byte: scale[7:6] index[5:3] base[2:0]
        const sib: u8 =
            (@as(u8, @intFromEnum(scale)) << 6) |
            ((@as(u8, @intFromEnum(index)) & 0x7) << 3) |
            (@as(u8, @intFromEnum(base)) & 0x7);
        try self.code.append(self.allocator, sib);

        switch (mod) {
            0b00 => {},
            0b01 => try self.code.append(self.allocator, @bitCast(@as(i8, @intCast(disp)))),
            0b10 => {
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(i32, &bytes, disp, .little);
                try self.code.appendSlice(self.allocator, &bytes);
            },
            else => unreachable,
        }
    }

    /// lea dst, [src + disp]
    pub fn leaRegMem(self: *Assembler, dst: Register, src: Register, disp: i32) !void {
        // REX.W + 8D /r [src + disp]
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x8D); // LEA opcode

        // Determine addressing mode based on displacement.
        // rbp and r13 with mod=00 encode as RIP-relative, so they need mod=01 + disp8(0).
        if (disp == 0 and src != .rsp and src != .r12 and src != .rbp and src != .r13) {
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
        // REX.W + 69 /r imm32  — reg field=dst (REX.R), r/m field=dst (REX.B)
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

    /// xor reg, imm32 (XOR with immediate, sign-extended to 64 bits)
    pub fn xorRegImm32(self: *Assembler, dst: Register, value: i32) !void {
        // REX.W + 81 /6 id
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0x81);
        try self.emitModRM(0b11, 6, @intFromEnum(dst)); // /6 for xor
        const value_bytes = @as([4]u8, @bitCast(value));
        try self.code.appendSlice(self.allocator, &value_bytes);
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

    // --- Unsigned Jcc rel32 forms. Opcodes follow the same Intel table as
    // the signed variants, offset by the CF/ZF test instead of SF/OF.
    //   ja  / jnbe — 0F 87
    //   jae / jnb  — 0F 83
    //   jb  / jnae — 0F 82
    //   jbe / jna  — 0F 86
    //
    // These are the Jcc forms that pair with `ucomisd` for IEEE-754 float
    // comparisons (ucomisd sets CF for "below" and an unordered compare
    // behaves like "below" so NaN-handling falls out naturally).

    pub fn jaRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x87);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    pub fn jaeRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x83);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    pub fn jbRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x82);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    pub fn jbeRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x86);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    pub fn patchJaRel32(self: *Assembler, pos: usize, offset: i32) !void {
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }
    pub fn patchJaeRel32(self: *Assembler, pos: usize, offset: i32) !void {
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }
    pub fn patchJbRel32(self: *Assembler, pos: usize, offset: i32) !void {
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }
    pub fn patchJbeRel32(self: *Assembler, pos: usize, offset: i32) !void {
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    /// call rel32 (relative call)
    pub fn callRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0xE8);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// call r/m64 — indirect call through a register. Used for trait/vtable
    /// dispatch where the function address is loaded at runtime. Encoded as
    /// `FF /2` with optional REX.B for r8-r15.
    pub fn callReg(self: *Assembler, target: Register) !void {
        if (target.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0xFF);
        try self.emitModRM(0b11, 2, @intFromEnum(target));
    }

    /// Get current code position (for calculating jumps)
    pub fn getPosition(self: *Assembler) usize {
        return self.code.items.len;
    }

    /// Patch a rel32 offset at a specific position. Returns an error
    /// if the displacement doesn't fit in 32 bits (code section >2 GB).
    pub fn patchRel32(self: *Assembler, pos: usize, target: usize) !void {
        const current = pos + 4;
        const diff = @as(i64, @intCast(target)) - @as(i64, @intCast(current));
        if (diff < std.math.minInt(i32) or diff > std.math.maxInt(i32)) {
            return error.CodegenFailed;
        }
        const offset: i32 = @intCast(diff);
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

    // --- Unsigned setcc variants. These test CF/ZF rather than SF/OF and
    // are the correct ones for unsigned integer comparisons as well as the
    // outputs of IEEE-754 `ucomisd` (where an unordered compare sets CF=1).
    //
    //   seta  / setnbe  — above         (CF=0 AND ZF=0)   0F 97
    //   setae / setnb   — above or eq   (CF=0)            0F 93
    //   setb  / setnae  — below         (CF=1)            0F 92
    //   setbe / setna   — below or eq   (CF=1 OR ZF=1)    0F 96

    pub fn setaReg(self: *Assembler, dst: Register) !void {
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x97);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    pub fn setaeReg(self: *Assembler, dst: Register) !void {
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x93);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    pub fn setbReg(self: *Assembler, dst: Register) !void {
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x92);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
    }

    pub fn setbeReg(self: *Assembler, dst: Register) !void {
        if (dst.needsRexPrefix()) {
            try self.emitRex(false, false, false, true);
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x96);
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

    /// shl reg, imm8 — REX.W + C1 /4 ib. For imm8 == 1 we emit the
    /// shorter D1 /4 form; imm8 == 0 is a no-op and skipped entirely.
    /// The shift count is masked to 6 bits by the CPU, so we also reject
    /// counts ≥ 64 at assemble time to catch the caller's bug rather than
    /// silently producing a zero-result shift.
    pub fn shlRegImm8(self: *Assembler, dst: Register, imm: u8) !void {
        if (imm == 0) return;
        if (imm >= 64) return error.ShiftCountOutOfRange;
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        if (imm == 1) {
            try self.code.append(self.allocator, 0xD1);
            try self.emitModRM(0b11, 4, @intFromEnum(dst));
        } else {
            try self.code.append(self.allocator, 0xC1);
            try self.emitModRM(0b11, 4, @intFromEnum(dst));
            try self.code.append(self.allocator, imm);
        }
    }

    /// shr reg, imm8 — REX.W + C1 /5 ib (logical right shift).
    pub fn shrRegImm8(self: *Assembler, dst: Register, imm: u8) !void {
        if (imm == 0) return;
        if (imm >= 64) return error.ShiftCountOutOfRange;
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        if (imm == 1) {
            try self.code.append(self.allocator, 0xD1);
            try self.emitModRM(0b11, 5, @intFromEnum(dst));
        } else {
            try self.code.append(self.allocator, 0xC1);
            try self.emitModRM(0b11, 5, @intFromEnum(dst));
            try self.code.append(self.allocator, imm);
        }
    }

    // --- Bit-manipulation instructions (BSF/BSR/POPCNT/LZCNT/TZCNT).
    //
    // These all take a 64-bit destination and a 64-bit source register.
    // Callers that only care about "result in rax, input in rax" can pass
    // the same register twice.

    /// bsf dst, src — 0F BC /r. Bit Scan Forward: sets dst to the index of
    /// the least-significant set bit in src. If src is zero, dst is
    /// undefined and ZF=1.
    pub fn bsfRegReg(self: *Assembler, dst: Register, src: Register) !void {
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xBC);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// bsr dst, src — 0F BD /r. Bit Scan Reverse.
    pub fn bsrRegReg(self: *Assembler, dst: Register, src: Register) !void {
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xBD);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// popcnt dst, src — F3 0F B8 /r. Population count.
    pub fn popcntRegReg(self: *Assembler, dst: Register, src: Register) !void {
        // F3 prefix first, then REX.W, then escape and opcode.
        try self.code.append(self.allocator, 0xF3);
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xB8);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// lzcnt dst, src — F3 0F BD /r. Count leading zeros. Unlike BSR,
    /// this is well-defined for src = 0 (returns operand size in bits).
    pub fn lzcntRegReg(self: *Assembler, dst: Register, src: Register) !void {
        try self.code.append(self.allocator, 0xF3);
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xBD);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// tzcnt dst, src — F3 0F BC /r. Count trailing zeros.
    pub fn tzcntRegReg(self: *Assembler, dst: Register, src: Register) !void {
        try self.code.append(self.allocator, 0xF3);
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xBC);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// sar reg, imm8 — REX.W + C1 /7 ib (arithmetic right shift).
    pub fn sarRegImm8(self: *Assembler, dst: Register, imm: u8) !void {
        if (imm == 0) return;
        if (imm >= 64) return error.ShiftCountOutOfRange;
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        if (imm == 1) {
            try self.code.append(self.allocator, 0xD1);
            try self.emitModRM(0b11, 7, @intFromEnum(dst));
        } else {
            try self.code.append(self.allocator, 0xC1);
            try self.emitModRM(0b11, 7, @intFromEnum(dst));
            try self.code.append(self.allocator, imm);
        }
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

    /// dec reg (decrement register by 1)
    pub fn decReg(self: *Assembler, dst: Register) !void {
        // REX.W + FF /1
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xFF);
        try self.emitModRM(0b11, 1, @intFromEnum(dst));
    }

    // --- movsx sign-extend variants. All produce a 64-bit destination,
    // sign-extending from the low 8/16/32 bits of the source register.
    //   movsx r64, r8  — REX.W + 0F BE /r
    //   movsx r64, r16 — REX.W + 0F BF /r
    //   movsxd r64, r32 — REX.W + 63   /r
    //
    // These are the correct choice when promoting narrow signed integers
    // to i64; the existing movzx variants zero-extend instead and would
    // flip the sign for negative narrow values.

    pub fn movsxReg64Reg8(self: *Assembler, dst: Register, src: Register) !void {
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xBE);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    pub fn movsxReg64Reg16(self: *Assembler, dst: Register, src: Register) !void {
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xBF);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    pub fn movsxdReg64Reg32(self: *Assembler, dst: Register, src: Register) !void {
        // MOVSXD is spelled differently in the Intel manual but behaves as
        // a sign-extending move from a 32-bit source.
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x63);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// xchg reg, reg — swap contents of two 64-bit registers. This is the
    /// only x86-64 xchg form we care about; when one operand is rax the
    /// short 1-byte encoding exists, but the ModRM form encodes any pair.
    /// Note: `xchg` against memory has an implicit LOCK prefix and is
    /// therefore atomic — we keep that variant out of this helper.
    pub fn xchgRegReg(self: *Assembler, a: Register, b: Register) !void {
        try self.emitRex(true, a.needsRexPrefix(), false, b.needsRexPrefix());
        try self.code.append(self.allocator, 0x87);
        try self.emitModRM(0b11, @intFromEnum(a), @intFromEnum(b));
    }

    /// test reg, imm32 — AND without writing back, just set flags.
    /// Encoded as REX.W + F7 /0 imm32. Useful when we only want to know
    /// whether a masked bit pattern is zero without needing a scratch.
    pub fn testRegImm32(self: *Assembler, dst: Register, imm: i32) !void {
        try self.emitRex(true, false, false, dst.needsRexPrefix());
        try self.code.append(self.allocator, 0xF7);
        try self.emitModRM(0b11, 0, @intFromEnum(dst));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, imm, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    // --- cmov variants. Conditional moves are branch-free selects that
    // pair with `cmp`/`test`. Opcodes are the same table as Jcc, just
    // with a different 0F prefix byte:
    //   cmove/cmovz    — 0F 44
    //   cmovne/cmovnz  — 0F 45
    //   cmovl          — 0F 4C
    //   cmovle         — 0F 4E
    //   cmovg          — 0F 4F
    //   cmovge         — 0F 4D
    //   cmova          — 0F 47
    //   cmovae/cmovnc  — 0F 43
    //   cmovb/cmovc    — 0F 42
    //   cmovbe         — 0F 46

    fn emitCmov(self: *Assembler, opcode: u8, dst: Register, src: Register) !void {
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, opcode);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    pub fn cmoveRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x44, dst, src);
    }
    pub fn cmovneRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x45, dst, src);
    }
    pub fn cmovlRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x4C, dst, src);
    }
    pub fn cmovleRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x4E, dst, src);
    }
    pub fn cmovgRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x4F, dst, src);
    }
    pub fn cmovgeRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x4D, dst, src);
    }
    pub fn cmovaRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x47, dst, src);
    }
    pub fn cmovaeRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x43, dst, src);
    }
    pub fn cmovbRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x42, dst, src);
    }
    pub fn cmovbeRegReg(self: *Assembler, dst: Register, src: Register) !void {
        return self.emitCmov(0x46, dst, src);
    }

    /// Patch jg rel32 at position
    pub fn patchJgRel32(self: *Assembler, pos: usize, offset: i32) !void {
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    pub fn patchJgeRel32(self: *Assembler, pos: usize, offset: i32) !void {
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    pub fn patchJleRel32(self: *Assembler, pos: usize, offset: i32) !void {
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    /// movzx reg64, byte [base + offset] - Zero-extend byte from memory to 64-bit register
    pub fn movzxReg64Mem8(self: *Assembler, dst: Register, base: Register, offset: i32) !void {
        // REX.W + 0F B6 /r [base + disp32]
        try self.emitRex(true, dst.needsRexPrefix(), false, base.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0xB6);

        // r12 and rsp require SIB byte even with offset=0
        const needs_sib = (base == .r12 or base == .rsp);

        if (offset == 0 and base != .rbp and base != .r13 and !needs_sib) {
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

        const needs_sib = (base == .r12 or base == .rsp);

        if (offset == 0 and base != .rbp and base != .r13 and !needs_sib) {
            try self.emitModRM(0b00, @intFromEnum(src), @intFromEnum(base));
        } else if (offset == 0 and needs_sib) {
            try self.emitModRM(0b00, @intFromEnum(src), 0b100);
            try self.code.append(self.allocator, 0x24);
        } else {
            if (needs_sib) {
                try self.emitModRM(0b10, @intFromEnum(src), 0b100);
                try self.code.append(self.allocator, 0x24);
            } else {
                try self.emitModRM(0b10, @intFromEnum(src), @intFromEnum(base));
            }
            const offset_bytes = @as([4]u8, @bitCast(offset));
            try self.code.appendSlice(self.allocator, &offset_bytes);
        }
    }

    /// mov byte [base + offset], imm8 - Store immediate byte to memory
    pub fn movByteMemImm(self: *Assembler, base: Register, offset: i32, value: u8) !void {
        // C6 /0 [base + disp32] imm8
        try self.code.append(self.allocator, 0xC6);

        const needs_sib = (base == .r12 or base == .rsp);

        if (offset == 0 and base != .rbp and base != .r13 and !needs_sib) {
            try self.emitModRM(0b00, 0, @intFromEnum(base));
        } else if (offset == 0 and needs_sib) {
            try self.emitModRM(0b00, 0, 0b100);
            try self.code.append(self.allocator, 0x24);
        } else {
            if (needs_sib) {
                try self.emitModRM(0b10, 0, 0b100);
                try self.code.append(self.allocator, 0x24);
            } else {
                try self.emitModRM(0b10, 0, @intFromEnum(base));
            }
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
    /// cmp reg, imm32 (sign-extended to 64-bit by the CPU).
    /// For values that don't fit in i32, use cmpRegReg with a
    /// scratch register loaded via movRegImm64.
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

    /// jo rel8 - Jump if overflow (short)
    pub fn joRel8(self: *Assembler, offset: i8) !usize {
        const pos = self.code.items.len;
        try self.code.append(self.allocator, 0x70);
        try self.code.append(self.allocator, @bitCast(offset));
        return pos;
    }

    /// jno rel8 - Jump if no overflow (short)
    pub fn jnoRel8(self: *Assembler, offset: i8) !usize {
        const pos = self.code.items.len;
        try self.code.append(self.allocator, 0x71);
        try self.code.append(self.allocator, @bitCast(offset));
        return pos;
    }

    /// jno rel32 - Jump if no overflow (near). Encoded as `0F 81 + i32`.
    pub fn jnoRel32(self: *Assembler, offset: i32) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x81);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// Patch a jno rel32 instruction in place.
    pub fn patchJnoRel32(self: *Assembler, pos: usize, offset: i32) !void {
        std.mem.writeInt(i32, self.code.items[pos + 2 ..][0..4], offset, .little);
    }

    /// cmovs reg, reg — Conditional move if sign flag is set (SF=1).
    /// Used for branch-free "pick between two values based on sign".
    /// Encoded as `REX.W + 0F 48 /r`.
    pub fn cmovsRegReg(self: *Assembler, dst: Register, src: Register) !void {
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x48);
        try self.emitModRM(0b11, @intFromEnum(dst), @intFromEnum(src));
    }

    /// jz rel8 - Jump if zero (short) - same as je
    pub fn jzRel8(self: *Assembler, offset: i8) !usize {
        const pos = self.code.items.len;
        try self.code.append(self.allocator, 0x74); // Same opcode as je
        try self.code.append(self.allocator, @bitCast(offset));
        return pos;
    }

    /// jnz rel8 - Jump if not zero (short) - same as jne
    pub fn jnzRel8(self: *Assembler, offset: i8) !usize {
        const pos = self.code.items.len;
        try self.code.append(self.allocator, 0x75); // Same opcode as jne
        try self.code.append(self.allocator, @bitCast(offset));
        return pos;
    }

    /// int3 - Software breakpoint (trap)
    pub fn int3(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xCC);
    }

    /// ud2 - Undefined instruction (always triggers invalid opcode exception)
    pub fn ud2(self: *Assembler) !void {
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x0B);
    }

    /// Patch jz rel8 at position
    pub fn patchJz8(self: *Assembler, pos: usize, offset: i8) void {
        self.code.items[pos + 1] = @bitCast(offset);
    }

    /// Patch jnz rel8 at position
    pub fn patchJnz8(self: *Assembler, pos: usize, offset: i8) void {
        self.code.items[pos + 1] = @bitCast(offset);
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

    /// Patch jo rel8 at position
    pub fn patchJo8(self: *Assembler, pos: usize, offset: i8) void {
        self.code.items[pos + 1] = @bitCast(offset);
    }

    /// Patch jno rel8 at position
    pub fn patchJno8(self: *Assembler, pos: usize, offset: i8) void {
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
        const needs_sib = (base == .r12 or base == .rsp);
        if (needs_sib) {
            try self.emitModRM(0b10, dst.encodeModRM(), 0b100);
            try self.code.append(self.allocator, 0x24);
        } else {
            try self.emitModRM(0b10, dst.encodeModRM(), @intFromEnum(base));
        }
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
        const needs_sib = (base == .r12 or base == .rsp);
        if (needs_sib) {
            try self.emitModRM(0b10, src.encodeModRM(), 0b100);
            try self.code.append(self.allocator, 0x24);
        } else {
            try self.emitModRM(0b10, src.encodeModRM(), @intFromEnum(base));
        }
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

    /// sqrtsd xmm1, xmm2 - Scalar square root double-precision (single 64-bit float).
    /// Encoded as F2 0F 51 /r.
    pub fn sqrtsdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        try self.code.append(self.allocator, 0xF2);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x51);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// sqrtss xmm1, xmm2 - Scalar square root single-precision (single 32-bit float).
    /// Encoded as F3 0F 51 /r.
    pub fn sqrtssXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        try self.code.append(self.allocator, 0xF3);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x51);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// roundsd xmm1, xmm2, imm8 — Scalar round double-precision.
    /// SSE4.1 instruction; macOS and Linux x86-64 ABI both require SSE4.1.
    ///
    /// imm8 controls the rounding mode:
    ///   0 = round to nearest (ties to even)
    ///   1 = round down (floor)
    ///   2 = round up (ceiling)
    ///   3 = round toward zero (truncate)
    ///
    /// Encoded as 66 0F 3A 0B /r ib.
    pub fn roundsdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister, mode: u8) !void {
        try self.code.append(self.allocator, 0x66);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x3A);
        try self.code.append(self.allocator, 0x0B);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
        try self.code.append(self.allocator, mode);
    }

    /// cvtsi2sd xmm, r64 — Convert 64-bit signed integer to double.
    /// Encoded as F2 REX.W 0F 2A /r.
    pub fn cvtsi2sdXmmReg(self: *Assembler, dst: XmmRegister, src: Register) !void {
        try self.code.append(self.allocator, 0xF2);
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x2A);
        try self.emitModRM(0b11, dst.encodeModRM(), @intFromEnum(src));
    }

    /// cvttsd2si r64, xmm — Convert double to 64-bit signed integer (truncate).
    /// Encoded as F2 REX.W 0F 2C /r.
    pub fn cvttsd2siRegXmm(self: *Assembler, dst: Register, src: XmmRegister) !void {
        try self.code.append(self.allocator, 0xF2);
        try self.emitRex(true, dst.needsRexPrefix(), false, src.needsRexPrefix());
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x2C);
        try self.emitModRM(0b11, @intFromEnum(dst), src.encodeModRM());
    }

    /// mulsd xmm1, xmm2 — Scalar multiply double-precision.
    /// Encoded as F2 0F 59 /r.
    pub fn mulsdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        try self.code.append(self.allocator, 0xF2);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x59);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// addsd xmm1, xmm2 — Scalar add double-precision.
    /// Encoded as F2 0F 58 /r.
    pub fn addsdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        try self.code.append(self.allocator, 0xF2);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x58);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// subsd xmm1, xmm2 — Scalar subtract double-precision.
    /// Encoded as F2 0F 5C /r.
    pub fn subsdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        try self.code.append(self.allocator, 0xF2);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5C);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    /// divsd xmm1, xmm2 — Scalar divide double-precision.
    /// Encoded as F2 0F 5E /r.
    pub fn divsdXmmXmm(self: *Assembler, dst: XmmRegister, src: XmmRegister) !void {
        try self.code.append(self.allocator, 0xF2);
        if (dst.needsRexPrefix() or src.needsRexPrefix()) {
            try self.emitRex(false, dst.needsRexPrefix(), false, src.needsRexPrefix());
        }
        try self.code.append(self.allocator, 0x0F);
        try self.code.append(self.allocator, 0x5E);
        try self.emitModRM(0b11, dst.encodeModRM(), src.encodeModRM());
    }

    // ===== x87 FPU instructions =====
    // These are used for transcendental math functions (sin/cos/tan/exp/log/...)
    // where a single instruction replaces an expensive polynomial evaluation.
    // The FPU uses a stack of 8 registers (st0-st7). Values are loaded from
    // memory via `fld qword ptr [mem]` and stored via `fstp qword ptr [mem]`.

    /// fld qword ptr [rsp] — load 64-bit double from top of stack into st(0).
    /// Encoded as DD /0 with [rsp] (rm=100, needs SIB 24).
    pub fn fldQwordRsp(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xDD);
        try self.code.append(self.allocator, 0x04); // mod=00 reg=0 rm=100
        try self.code.append(self.allocator, 0x24); // SIB: scale=0 index=100 base=100 (rsp)
    }

    /// fstp qword ptr [rsp] — store st(0) to 64-bit memory and pop.
    /// Encoded as DD /3 with [rsp].
    pub fn fstpQwordRsp(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xDD);
        try self.code.append(self.allocator, 0x1C); // mod=00 reg=3 rm=100
        try self.code.append(self.allocator, 0x24); // SIB for rsp
    }

    /// fsin — st(0) = sin(st(0)). Encoded as D9 FE.
    pub fn fsin(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xFE);
    }

    /// fcos — st(0) = cos(st(0)). Encoded as D9 FF.
    pub fn fcos(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xFF);
    }

    /// fptan — st(0) = tan(st(0)), pushes 1.0 on top. Encoded as D9 F2.
    /// A subsequent `fstp st(0)` is needed to discard the 1.0.
    pub fn fptan(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xF2);
    }

    /// fpatan — st(1) = atan2(st(1), st(0)), then pops. Encoded as D9 F3.
    pub fn fpatan(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xF3);
    }

    /// f2xm1 — st(0) = 2^st(0) - 1. Valid only for st(0) in [-1, 1].
    /// Encoded as D9 F0.
    pub fn f2xm1(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xF0);
    }

    /// fyl2x — st(1) = st(1) * log2(st(0)), then pops st(0).
    /// Encoded as D9 F1.
    pub fn fyl2x(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xF1);
    }

    /// fscale — st(0) = st(0) * 2^trunc(st(1)). Encoded as D9 FD.
    pub fn fscale(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xFD);
    }

    /// frndint — st(0) = round-to-integer(st(0)) using FPU rounding mode.
    /// Encoded as D9 FC.
    pub fn frndint(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xFC);
    }

    /// fld1 — push 1.0 onto FPU stack. Encoded as D9 E8.
    pub fn fld1(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xE8);
    }

    /// fldl2e — push log2(e) onto FPU stack. Encoded as D9 EA.
    pub fn fldl2e(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xEA);
    }

    /// fldln2 — push ln(2) onto FPU stack. Encoded as D9 ED.
    pub fn fldln2(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xED);
    }

    /// fldlg2 — push log10(2) onto FPU stack. Encoded as D9 EC.
    pub fn fldlg2(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xEC);
    }

    /// fchs — st(0) = -st(0). Encoded as D9 E0.
    pub fn fchs(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xE0);
    }

    /// fabs — st(0) = |st(0)|. Encoded as D9 E1.
    pub fn fabs_(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xE1);
    }

    /// fxch — exchange st(0) with st(1). Encoded as D9 C9.
    pub fn fxch(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xC9);
    }

    /// fstp st(0) — pop top of FPU stack (discard). Encoded as DD D8.
    pub fn fstpSt0(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xDD);
        try self.code.append(self.allocator, 0xD8);
    }

    /// fstp st(1) — store st(0) to st(1) and pop. Encoded as DD D9.
    /// Effectively drops st(1) from the stack.
    pub fn fstpSt1(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xDD);
        try self.code.append(self.allocator, 0xD9);
    }

    /// fprem — partial remainder: st(0) = st(0) mod st(1).
    /// Encoded as D9 F8.
    pub fn fprem(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xF8);
    }

    /// fsqrt — st(0) = sqrt(st(0)). Encoded as D9 FA.
    pub fn fsqrt(self: *Assembler) !void {
        try self.code.append(self.allocator, 0xD9);
        try self.code.append(self.allocator, 0xFA);
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
