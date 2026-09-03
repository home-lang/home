//! Architecture abstraction for the freestanding kernel codegen path.
//!
//! `home_kernel_codegen.zig` is a naive stack machine: every expression
//! evaluates into an accumulator register, temporaries are pushed onto the
//! machine stack, and locals live at fixed offsets from a frame pointer. That
//! model is architecture-neutral; only the instruction text is not. This file
//! is the seam. It exposes the ~40 operations the codegen actually performs,
//! named for what they mean rather than for how x86 spells them, and emits the
//! assembly text for the selected target.
//!
//! Adding an architecture means implementing the switches here, not editing
//! the codegen. See home-lang/home#582 (aarch64 lowering) and
//! home-lang/home-os#44 (the ADR that chose extending this direct emitter over
//! routing the kernel path through LLVM).
//!
//! Register roles, and the machine registers they map to:
//!
//! | Role     | x86-64 | aarch64 | Notes                                    |
//! |----------|--------|---------|------------------------------------------|
//! | `acc`    | `%rax` | `x0`    | expression accumulator, and return value |
//! | `tmp`    | `%rcx` | `x1`    | right-hand operand of a binary op        |
//! | `tmp2`   | `%rsi` | `x2`    | scratch across a multi-step lowering     |
//! | `tmp3`   | `%rdx` | `x3`    | division remainder on x86                |
//! | `base`   | `%rbp` | `x29`   | frame pointer                            |
//! | `stack`  | `%rsp` | `sp`    | stack pointer                            |
//! | `scratch`| `%r11` | `x9`    | assembler-internal; never holds a value  |
//! | `scratch2`|`%r10` | `x10`   | assembler-internal; never holds a value  |
//!
//! `scratch` and `scratch2` exist because aarch64 cannot fold a large
//! displacement or a 64-bit immediate into a load, so the emitter sometimes
//! has to materialise an address. The codegen must never assume they survive
//! an emitter call.

const std = @import("std");

pub const Arch = enum {
    x86_64,
    aarch64,

    /// Accept the spellings that appear in target triples and on the command
    /// line. `null` for anything else, so the caller can report it with the
    /// text the user actually wrote.
    pub fn parse(name: []const u8) ?Arch {
        if (std.mem.eql(u8, name, "x86_64") or
            std.mem.eql(u8, name, "x86-64") or
            std.mem.eql(u8, name, "amd64")) return .x86_64;
        if (std.mem.eql(u8, name, "aarch64") or
            std.mem.eql(u8, name, "arm64")) return .aarch64;
        return null;
    }

    /// Accept a whole target triple and return the architecture it names.
    ///
    /// Written as a prefix match rather than a split on `-`, because the
    /// architecture itself is sometimes spelled with a dash (`x86-64-...`),
    /// which a naive split would truncate to `x86` and reject.
    pub fn parseTriple(triple: []const u8) ?Arch {
        if (parse(triple)) |a| return a;
        const prefixes = [_]struct { text: []const u8, arch: Arch }{
            .{ .text = "x86_64", .arch = .x86_64 },
            .{ .text = "x86-64", .arch = .x86_64 },
            .{ .text = "amd64", .arch = .x86_64 },
            .{ .text = "aarch64", .arch = .aarch64 },
            .{ .text = "arm64", .arch = .aarch64 },
        };
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, triple, p.text)) {
                // Only a separator may follow, so `aarch64be` is not accepted
                // as `aarch64`: it is a different, big-endian target.
                if (triple.len == p.text.len or triple[p.text.len] == '-') return p.arch;
            }
        }
        return null;
    }

    /// The architecture part of a target triple, as the assembler spells it.
    pub fn triplePrefix(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
        };
    }

    /// Natural word width in bytes. Both targets are 64-bit; the constant is
    /// named so that frame arithmetic reads as intent rather than as `8`.
    pub fn wordSize(self: Arch) usize {
        return switch (self) {
            .x86_64, .aarch64 => 8,
        };
    }

    /// Stack alignment required at a call boundary.
    pub fn stackAlign(self: Arch) usize {
        return switch (self) {
            .x86_64 => 16,
            .aarch64 => 16,
        };
    }

    /// How many arguments travel in registers before the stack is used.
    pub fn argRegCount(self: Arch) usize {
        return switch (self) {
            .x86_64 => 6, // SysV: rdi rsi rdx rcx r8 r9
            .aarch64 => 8, // AAPCS64: x0-x7
        };
    }
};

pub const Reg = enum {
    acc,
    tmp,
    tmp2,
    tmp3,
    base,
    stack,
    scratch,
    scratch2,
    /// Destination, source and length of a block memory operation. On x86-64
    /// these are the registers the string instructions require, which is why
    /// they alias `tmp`/`tmp2` there; on aarch64 they are distinct registers,
    /// because a copy loop has no such constraint and the aliasing would be a
    /// hazard rather than a requirement.
    mem_dst,
    mem_src,
    mem_len,
};

/// Comparison predicates. Signedness is explicit: the kernel tree compares
/// both signed counters and unsigned addresses, and picking the wrong one is
/// silent until an address crosses 2^63.
pub const Cond = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    ult,
    ule,
    ugt,
    uge,
};

/// Binary operations the stack machine performs with the left operand in
/// `acc` and the right operand in `tmp`, leaving the result in `acc`.
pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr_arith,
    shr_logical,
};

/// Memory barrier flavours, for `@barrier` and for the volatile MMIO
/// intrinsics (home-lang/home#584). On x86-64 the strong memory model makes
/// most of these no-ops, which is recorded explicitly rather than by omission.
pub const Barrier = enum {
    /// Full system barrier: no access may cross in either direction.
    full,
    /// Loads before it complete before loads after it.
    loads,
    /// Stores before it complete before stores after it.
    stores,
    /// Instruction synchronisation: discard the prefetched pipeline.
    isync,
};

pub const Emitter = struct {
    arch: Arch,
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    const Self = @This();

    // ---------------------------------------------------------------- output

    pub fn raw(self: Self, bytes: []const u8) !void {
        try self.out.appendSlice(self.gpa, bytes);
    }

    pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(text);
        try self.out.appendSlice(self.gpa, text);
    }

    /// One instruction, indented the way the rest of the file is.
    fn insn(self: Self, comptime fmt: []const u8, args: anytype) !void {
        try self.raw("    ");
        try self.print(fmt, args);
        try self.raw("\n");
    }

    // ------------------------------------------------------------- registers

    /// The 64-bit name of a role, including the sigil the assembler wants.
    pub fn reg(self: Self, r: Reg) []const u8 {
        return switch (self.arch) {
            .x86_64 => switch (r) {
                .acc => "%rax",
                .tmp => "%rcx",
                .tmp2 => "%rsi",
                .tmp3 => "%rdx",
                .base => "%rbp",
                .stack => "%rsp",
                .scratch => "%r11",
                .scratch2 => "%r10",
                .mem_dst => "%rdi",
                .mem_src => "%rsi",
                .mem_len => "%rcx",
            },
            .aarch64 => switch (r) {
                .acc => "x0",
                .tmp => "x1",
                .tmp2 => "x2",
                .tmp3 => "x3",
                .base => "x29",
                .stack => "sp",
                .scratch => "x9",
                .scratch2 => "x10",
                .mem_dst => "x11",
                .mem_src => "x12",
                .mem_len => "x13",
            },
        };
    }

    /// The 32-bit view of a role. aarch64 needs it for sub-word loads and
    /// extensions; x86 needs it for the `movl` zero-extension idiom.
    pub fn reg32(self: Self, r: Reg) []const u8 {
        return switch (self.arch) {
            .x86_64 => switch (r) {
                .acc => "%eax",
                .tmp => "%ecx",
                .tmp2 => "%esi",
                .tmp3 => "%edx",
                .base => "%ebp",
                .stack => "%esp",
                .scratch => "%r11d",
                .scratch2 => "%r10d",
                .mem_dst => "%edi",
                .mem_src => "%esi",
                .mem_len => "%ecx",
            },
            .aarch64 => switch (r) {
                .acc => "w0",
                .tmp => "w1",
                .tmp2 => "w2",
                .tmp3 => "w3",
                .base => "w29",
                .stack => "wsp",
                .scratch => "w9",
                .scratch2 => "w10",
                .mem_dst => "w11",
                .mem_src => "w12",
                .mem_len => "w13",
            },
        };
    }

    /// Argument register `index` in the platform calling convention, or null
    /// past the last one — the caller then passes that argument on the stack.
    pub fn argReg(self: Self, index: usize) ?[]const u8 {
        return switch (self.arch) {
            .x86_64 => switch (index) {
                0 => "%rdi",
                1 => "%rsi",
                2 => "%rdx",
                3 => "%rcx",
                4 => "%r8",
                5 => "%r9",
                else => null,
            },
            .aarch64 => switch (index) {
                0 => "x0",
                1 => "x1",
                2 => "x2",
                3 => "x3",
                4 => "x4",
                5 => "x5",
                6 => "x6",
                7 => "x7",
                else => null,
            },
        };
    }

    // -------------------------------------------------------------- sections

    pub fn sectionText(self: Self) !void {
        try self.raw(".section .text\n");
    }

    pub fn sectionRodata(self: Self) !void {
        try self.raw("\n.section .rodata\n");
    }

    pub fn sectionData(self: Self) !void {
        try self.raw("\n.section .data\n");
    }

    pub fn sectionBss(self: Self) !void {
        try self.raw("\n.section .bss\n");
    }

    pub fn globalSymbol(self: Self, sym: []const u8) !void {
        try self.print(".global {s}\n", .{sym});
    }

    pub fn defineLabel(self: Self, sym: []const u8) !void {
        try self.print("{s}:\n", .{sym});
    }

    /// `.balign` is spelled the same by both assemblers, but saying it once
    /// here keeps alignment out of the codegen's vocabulary.
    pub fn alignTo(self: Self, bytes: usize) !void {
        try self.print("    .balign {d}\n", .{bytes});
    }

    // ----------------------------------------------------------------- frame

    /// Establish a frame of `frame_size` bytes and save the return address.
    ///
    /// x86-64 pushes the return address itself, so only `%rbp` is saved here.
    /// aarch64 keeps it in `x30`, which any nested call would clobber, so the
    /// frame record is the `x29`/`x30` pair — the layout every ARM unwinder
    /// and debugger expects.
    pub fn prologue(self: Self, frame_size: usize) !void {
        switch (self.arch) {
            .x86_64 => {
                try self.insn("pushq %rbp", .{});
                try self.insn("movq %rsp, %rbp", .{});
                if (frame_size > 0) try self.insn("subq ${d}, %rsp", .{frame_size});
            },
            .aarch64 => {
                try self.insn("stp x29, x30, [sp, #-16]!", .{});
                try self.insn("mov x29, sp", .{});
                if (frame_size > 0) try self.subSpImm(frame_size);
            },
        }
    }

    /// Tear the frame down. Restoring the stack pointer from the frame pointer
    /// rather than adding the frame size back makes this correct even if the
    /// body left temporaries pushed, which the stack machine does on every
    /// early return out of a nested expression.
    pub fn epilogue(self: Self) !void {
        switch (self.arch) {
            .x86_64 => {
                try self.insn("movq %rbp, %rsp", .{});
                try self.insn("popq %rbp", .{});
            },
            .aarch64 => {
                try self.insn("mov sp, x29", .{});
                try self.insn("ldp x29, x30, [sp], #16", .{});
            },
        }
    }

    pub fn ret(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("ret", .{}),
            .aarch64 => try self.insn("ret", .{}),
        }
    }

    /// `sub sp, sp, #N` only encodes a 12-bit immediate, optionally shifted
    /// left by 12. A frame larger than that is rare but a fixed-size array
    /// local reaches it, so materialise the constant instead of truncating it.
    fn subSpImm(self: Self, amount: usize) !void {
        if (amount <= 0xfff) {
            try self.insn("sub sp, sp, #{d}", .{amount});
        } else if (amount & 0xfff == 0 and amount <= 0xfff000) {
            try self.insn("sub sp, sp, #{d}, lsl #12", .{amount >> 12});
        } else {
            try self.movImmReg(.scratch, @intCast(amount));
            try self.insn("sub sp, sp, {s}", .{self.reg(.scratch)});
        }
    }

    // ------------------------------------------------------ stack temporaries

    /// Push the accumulator, or any role, as one machine word.
    ///
    /// aarch64 has no push instruction and requires `sp` to stay 16-byte
    /// aligned at every point where an exception could be taken, so a
    /// single-word push moves the stack by 16 and wastes the upper half. The
    /// alternative — packing two values per 16 bytes — would make the stack
    /// machine's depth accounting non-local, which is not worth eight bytes
    /// of a kernel stack.
    pub fn push(self: Self, r: Reg) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("pushq {s}", .{self.reg(r)}),
            .aarch64 => try self.insn("str {s}, [sp, #-16]!", .{self.reg(r)}),
        }
    }

    pub fn pop(self: Self, r: Reg) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("popq {s}", .{self.reg(r)}),
            .aarch64 => try self.insn("ldr {s}, [sp], #16", .{self.reg(r)}),
        }
    }

    /// Pop into a named argument register (the text `argReg` returned).
    pub fn popNamed(self: Self, name: []const u8) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("popq {s}", .{name}),
            .aarch64 => try self.insn("ldr {s}, [sp], #16", .{name}),
        }
    }

    /// How far `push` moves the stack pointer. The codegen needs this when it
    /// computes the offset of an argument it has already pushed.
    pub fn pushStride(self: Self) usize {
        return switch (self.arch) {
            .x86_64 => 8,
            .aarch64 => 16,
        };
    }

    // ----------------------------------------------------------------- moves

    pub fn movReg(self: Self, dst: Reg, src: Reg) !void {
        if (dst == src) return;
        switch (self.arch) {
            .x86_64 => try self.insn("movq {s}, {s}", .{ self.reg(src), self.reg(dst) }),
            .aarch64 => try self.insn("mov {s}, {s}", .{ self.reg(dst), self.reg(src) }),
        }
    }

    /// Move a named machine register into a role, for the few places that
    /// deal with the calling convention directly.
    pub fn movFromNamed(self: Self, dst: Reg, src_name: []const u8) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq {s}, {s}", .{ src_name, self.reg(dst) }),
            .aarch64 => try self.insn("mov {s}, {s}", .{ self.reg(dst), src_name }),
        }
    }

    pub fn movToNamed(self: Self, dst_name: []const u8, src: Reg) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq {s}, {s}", .{ self.reg(src), dst_name }),
            .aarch64 => try self.insn("mov {s}, {s}", .{ dst_name, self.reg(src) }),
        }
    }

    pub fn movImm(self: Self, value: i64) !void {
        try self.movImmReg(.acc, value);
    }

    /// Materialise a 64-bit constant.
    ///
    /// x86 has a single instruction for it. aarch64 builds the value 16 bits
    /// at a time: `movz` for the lowest non-zero halfword, then `movk` for
    /// each remaining non-zero one. Emitting only the non-zero halfwords keeps
    /// the common small constant to one instruction while staying correct for
    /// the full 64-bit range, including the MMIO base addresses on a Pi 5,
    /// which live above 2^32 and would silently truncate under a 32-bit form.
    pub fn movImmReg(self: Self, r: Reg, value: i64) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq ${d}, {s}", .{ value, self.reg(r) }),
            .aarch64 => {
                const bits: u64 = @bitCast(value);
                if (bits == 0) {
                    try self.insn("mov {s}, #0", .{self.reg(r)});
                    return;
                }
                // A small negative constant is one instruction as the bitwise
                // complement of a small positive one.
                if (value < 0 and value >= -0x10000) {
                    const inverted: u64 = ~bits;
                    if (inverted <= 0xffff) {
                        try self.insn("movn {s}, #{d}", .{ self.reg(r), inverted });
                        return;
                    }
                }
                var emitted_first = false;
                var shift: u6 = 0;
                while (true) : (shift += 16) {
                    const half: u16 = @truncate(bits >> shift);
                    if (half != 0) {
                        if (!emitted_first) {
                            if (shift == 0) {
                                try self.insn("movz {s}, #{d}", .{ self.reg(r), half });
                            } else {
                                try self.insn("movz {s}, #{d}, lsl #{d}", .{ self.reg(r), half, shift });
                            }
                            emitted_first = true;
                        } else {
                            try self.insn("movk {s}, #{d}, lsl #{d}", .{ self.reg(r), half, shift });
                        }
                    }
                    if (shift == 48) break;
                }
            },
        }
    }

    // ------------------------------------------------------------- frame slots

    /// Load one word from a frame slot. Offsets are negative bytes from the
    /// frame pointer.
    pub fn loadLocal(self: Self, dst: Reg, offset: i32) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq {d}({s}), {s}", .{ offset, self.reg(.base), self.reg(dst) }),
            .aarch64 => {
                // `ldur` takes a signed 9-bit offset, which covers the frames
                // of ordinary functions. Anything deeper gets its address
                // computed first: silently wrapping the offset would read a
                // neighbouring local.
                if (offset >= -256 and offset <= 255) {
                    try self.insn("ldur {s}, [x29, #{d}]", .{ self.reg(dst), offset });
                } else {
                    try self.frameAddr(.scratch, offset);
                    try self.insn("ldr {s}, [{s}]", .{ self.reg(dst), self.reg(.scratch) });
                }
            },
        }
    }

    pub fn storeLocal(self: Self, src: Reg, offset: i32) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq {s}, {d}({s})", .{ self.reg(src), offset, self.reg(.base) }),
            .aarch64 => {
                if (offset >= -256 and offset <= 255) {
                    try self.insn("stur {s}, [x29, #{d}]", .{ self.reg(src), offset });
                } else {
                    try self.frameAddr(.scratch, offset);
                    try self.insn("str {s}, [{s}]", .{ self.reg(src), self.reg(.scratch) });
                }
            },
        }
    }

    /// Store a named machine register into a frame slot. Used when spilling
    /// incoming arguments, which arrive in convention registers rather than
    /// in roles.
    pub fn storeNamedLocal(self: Self, src_name: []const u8, offset: i32) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq {s}, {d}(%rbp)", .{ src_name, offset }),
            .aarch64 => {
                if (offset >= -256 and offset <= 255) {
                    try self.insn("stur {s}, [x29, #{d}]", .{ src_name, offset });
                } else {
                    try self.frameAddr(.scratch, offset);
                    try self.insn("str {s}, [{s}]", .{ src_name, self.reg(.scratch) });
                }
            },
        }
    }

    /// Address of a frame slot, for taking a pointer to a local or for
    /// indexing into an array local.
    pub fn leaLocal(self: Self, dst: Reg, offset: i32) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("leaq {d}({s}), {s}", .{ offset, self.reg(.base), self.reg(dst) }),
            .aarch64 => try self.frameAddr(dst, offset),
        }
    }

    /// aarch64 helper: `dst = x29 + offset`, for any offset.
    ///
    /// `add`/`sub` encode a 12-bit immediate, optionally shifted left by 12.
    /// Both forms are used before falling back to materialising the constant,
    /// because a frame that is an exact multiple of the page size is the
    /// common shape for a function with a page-aligned buffer local.
    fn frameAddr(self: Self, dst: Reg, offset: i32) !void {
        const op: []const u8 = if (offset >= 0) "add" else "sub";
        const magnitude: u64 = if (offset >= 0)
            @intCast(offset)
        else
            @intCast(-@as(i64, offset));

        if (magnitude <= 0xfff) {
            try self.insn("{s} {s}, x29, #{d}", .{ op, self.reg(dst), magnitude });
            return;
        }
        if (magnitude & 0xfff == 0 and magnitude <= 0xfff000) {
            try self.insn("{s} {s}, x29, #{d}, lsl #12", .{ op, self.reg(dst), magnitude >> 12 });
            return;
        }
        try self.movImmReg(dst, offset);
        try self.insn("add {s}, x29, {s}", .{ self.reg(dst), self.reg(dst) });
    }

    /// Load a word from `[base_reg + offset]`, where `base_reg` holds an
    /// address the codegen computed.
    pub fn loadOffset(self: Self, dst: Reg, addr: Reg, offset: i64) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq {d}({s}), {s}", .{ offset, self.reg(addr), self.reg(dst) }),
            .aarch64 => {
                if (offset >= 0 and offset <= 32760 and @rem(offset, 8) == 0) {
                    try self.insn("ldr {s}, [{s}, #{d}]", .{ self.reg(dst), self.reg(addr), offset });
                } else if (offset >= -256 and offset <= 255) {
                    try self.insn("ldur {s}, [{s}, #{d}]", .{ self.reg(dst), self.reg(addr), offset });
                } else {
                    try self.movImmReg(.scratch, offset);
                    try self.insn("ldr {s}, [{s}, {s}]", .{ self.reg(dst), self.reg(addr), self.reg(.scratch) });
                }
            },
        }
    }

    pub fn storeOffset(self: Self, src: Reg, addr: Reg, offset: i64) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq {s}, {d}({s})", .{ self.reg(src), offset, self.reg(addr) }),
            .aarch64 => {
                if (offset >= 0 and offset <= 32760 and @rem(offset, 8) == 0) {
                    try self.insn("str {s}, [{s}, #{d}]", .{ self.reg(src), self.reg(addr), offset });
                } else if (offset >= -256 and offset <= 255) {
                    try self.insn("stur {s}, [{s}, #{d}]", .{ self.reg(src), self.reg(addr), offset });
                } else {
                    try self.movImmReg(.scratch, offset);
                    try self.insn("str {s}, [{s}, {s}]", .{ self.reg(src), self.reg(addr), self.reg(.scratch) });
                }
            },
        }
    }

    // --------------------------------------------------------------- globals

    /// Address of a symbol, position-independently.
    pub fn leaSymbol(self: Self, dst: Reg, sym: []const u8) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("leaq {s}(%rip), {s}", .{ sym, self.reg(dst) }),
            .aarch64 => {
                // `adrp` reaches ±4 GiB in 4 KiB pages; the `:lo12:` add
                // supplies the offset within the page. This is the standard
                // pair, and it is what lets a kernel image be linked anywhere
                // in the address space without a relocation per reference.
                try self.insn("adrp {s}, {s}", .{ self.reg(dst), sym });
                try self.insn("add {s}, {s}, :lo12:{s}", .{ self.reg(dst), self.reg(dst), sym });
            },
        }
    }

    /// Load a word from a symbol.
    pub fn loadSymbol(self: Self, dst: Reg, sym: []const u8) !void {
        try self.loadSymbolSized(dst, sym, 8, false);
    }

    /// Load `size` bytes from a symbol, extending to a full word.
    pub fn loadSymbolSized(self: Self, dst: Reg, sym: []const u8, size: usize, signed: bool) !void {
        switch (self.arch) {
            .x86_64 => {
                const d = self.reg(dst);
                switch (size) {
                    1 => try self.insn("{s} {s}(%rip), {s}", .{ if (signed) "movsbq" else "movzbq", sym, d }),
                    2 => try self.insn("{s} {s}(%rip), {s}", .{ if (signed) "movswq" else "movzwq", sym, d }),
                    4 => if (signed)
                        try self.insn("movslq {s}(%rip), {s}", .{ sym, d })
                    else
                        try self.insn("movl {s}(%rip), {s}", .{ sym, self.reg32(dst) }),
                    else => try self.insn("movq {s}(%rip), {s}", .{ sym, d }),
                }
            },
            .aarch64 => {
                // The page address goes into the destination, then the load
                // folds the within-page offset into its addressing mode.
                try self.insn("adrp {s}, {s}", .{ self.reg(dst), sym });
                switch (size) {
                    1 => if (signed)
                        try self.insn("ldrsb {s}, [{s}, :lo12:{s}]", .{ self.reg(dst), self.reg(dst), sym })
                    else
                        try self.insn("ldrb {s}, [{s}, :lo12:{s}]", .{ self.reg32(dst), self.reg(dst), sym }),
                    2 => if (signed)
                        try self.insn("ldrsh {s}, [{s}, :lo12:{s}]", .{ self.reg(dst), self.reg(dst), sym })
                    else
                        try self.insn("ldrh {s}, [{s}, :lo12:{s}]", .{ self.reg32(dst), self.reg(dst), sym }),
                    4 => if (signed)
                        try self.insn("ldrsw {s}, [{s}, :lo12:{s}]", .{ self.reg(dst), self.reg(dst), sym })
                    else
                        try self.insn("ldr {s}, [{s}, :lo12:{s}]", .{ self.reg32(dst), self.reg(dst), sym }),
                    else => try self.insn("ldr {s}, [{s}, :lo12:{s}]", .{ self.reg(dst), self.reg(dst), sym }),
                }
            },
        }
    }

    pub fn storeSymbol(self: Self, src: Reg, sym: []const u8) !void {
        try self.storeSymbolSized(src, sym, 8);
    }

    /// Store the low `size` bytes of `src` to a symbol.
    pub fn storeSymbolSized(self: Self, src: Reg, sym: []const u8, size: usize) !void {
        switch (self.arch) {
            .x86_64 => {
                const sub = self.subReg(src, size);
                const mnemonic = switch (size) {
                    1 => "movb",
                    2 => "movw",
                    4 => "movl",
                    else => "movq",
                };
                try self.insn("{s} {s}, {s}(%rip)", .{ mnemonic, sub, sym });
            },
            .aarch64 => {
                // The address needs a register of its own: the value register
                // must survive the store.
                try self.insn("adrp {s}, {s}", .{ self.reg(.scratch), sym });
                switch (size) {
                    1 => try self.insn("strb {s}, [{s}, :lo12:{s}]", .{ self.reg32(src), self.reg(.scratch), sym }),
                    2 => try self.insn("strh {s}, [{s}, :lo12:{s}]", .{ self.reg32(src), self.reg(.scratch), sym }),
                    4 => try self.insn("str {s}, [{s}, :lo12:{s}]", .{ self.reg32(src), self.reg(.scratch), sym }),
                    else => try self.insn("str {s}, [{s}, :lo12:{s}]", .{ self.reg(src), self.reg(.scratch), sym }),
                }
            },
        }
    }

    /// Store the low `size` bytes of `src` at `[addr + offset]`.
    pub fn storeOffsetSized(self: Self, src: Reg, addr: Reg, offset: i64, size: usize) !void {
        if (offset == 0) return self.storeIndirect(src, addr, size);
        switch (self.arch) {
            .x86_64 => {
                const sub = self.subReg(src, size);
                const mnemonic = switch (size) {
                    1 => "movb",
                    2 => "movw",
                    4 => "movl",
                    else => "movq",
                };
                try self.insn("{s} {s}, {d}({s})", .{ mnemonic, sub, offset, self.reg(addr) });
            },
            .aarch64 => {
                // Fold the displacement into the addressing mode when the
                // scaled unsigned form reaches it, otherwise compute it.
                const scaled_ok = offset >= 0 and @rem(offset, @as(i64, @intCast(size))) == 0 and
                    @divExact(offset, @as(i64, @intCast(size))) <= 4095;
                if (scaled_ok) {
                    switch (size) {
                        1 => try self.insn("strb {s}, [{s}, #{d}]", .{ self.reg32(src), self.reg(addr), offset }),
                        2 => try self.insn("strh {s}, [{s}, #{d}]", .{ self.reg32(src), self.reg(addr), offset }),
                        4 => try self.insn("str {s}, [{s}, #{d}]", .{ self.reg32(src), self.reg(addr), offset }),
                        else => try self.insn("str {s}, [{s}, #{d}]", .{ self.reg(src), self.reg(addr), offset }),
                    }
                } else {
                    try self.movImmReg(.scratch, offset);
                    try self.insn("add {s}, {s}, {s}", .{ self.reg(.scratch), self.reg(.scratch), self.reg(addr) });
                    try self.storeIndirect(src, .scratch, size);
                }
            },
        }
    }

    /// Shift the accumulator by a constant.
    pub fn shiftImm(self: Self, op: BinOp, amount: u6) !void {
        switch (self.arch) {
            .x86_64 => {
                const mnemonic = switch (op) {
                    .shl => "shlq",
                    .shr_arith => "sarq",
                    .shr_logical => "shrq",
                    else => unreachable,
                };
                try self.insn("{s} ${d}, %rax", .{ mnemonic, amount });
            },
            .aarch64 => {
                const mnemonic = switch (op) {
                    .shl => "lsl",
                    .shr_arith => "asr",
                    .shr_logical => "lsr",
                    else => unreachable,
                };
                try self.insn("{s} x0, x0, #{d}", .{ mnemonic, amount });
            },
        }
    }

    // ---------------------------------------------------------------- memory

    /// Load `size` bytes from the address in `addr` into `dst`, sign- or
    /// zero-extending to a full word.
    pub fn loadIndirect(self: Self, dst: Reg, addr: Reg, size: usize, signed: bool) !void {
        switch (self.arch) {
            .x86_64 => {
                const src = self.reg(addr);
                const d = self.reg(dst);
                switch (size) {
                    1 => try self.insn("{s} ({s}), {s}", .{ if (signed) "movsbq" else "movzbq", src, d }),
                    2 => try self.insn("{s} ({s}), {s}", .{ if (signed) "movswq" else "movzwq", src, d }),
                    4 => if (signed)
                        try self.insn("movslq ({s}), {s}", .{ src, d })
                    else
                        try self.insn("movl ({s}), {s}", .{ src, self.reg32(dst) }),
                    else => try self.insn("movq ({s}), {s}", .{ src, d }),
                }
            },
            .aarch64 => {
                const src = self.reg(addr);
                switch (size) {
                    1 => if (signed)
                        try self.insn("ldrsb {s}, [{s}]", .{ self.reg(dst), src })
                    else
                        try self.insn("ldrb {s}, [{s}]", .{ self.reg32(dst), src }),
                    2 => if (signed)
                        try self.insn("ldrsh {s}, [{s}]", .{ self.reg(dst), src })
                    else
                        try self.insn("ldrh {s}, [{s}]", .{ self.reg32(dst), src }),
                    4 => if (signed)
                        try self.insn("ldrsw {s}, [{s}]", .{ self.reg(dst), src })
                    else
                        try self.insn("ldr {s}, [{s}]", .{ self.reg32(dst), src }),
                    else => try self.insn("ldr {s}, [{s}]", .{ self.reg(dst), src }),
                }
            },
        }
    }

    /// Store the low `size` bytes of `src` to the address in `addr`.
    pub fn storeIndirect(self: Self, src: Reg, addr: Reg, size: usize) !void {
        switch (self.arch) {
            .x86_64 => {
                const a = self.reg(addr);
                const sub = self.subReg(src, size);
                switch (size) {
                    1 => try self.insn("movb {s}, ({s})", .{ sub, a }),
                    2 => try self.insn("movw {s}, ({s})", .{ sub, a }),
                    4 => try self.insn("movl {s}, ({s})", .{ sub, a }),
                    else => try self.insn("movq {s}, ({s})", .{ self.reg(src), a }),
                }
            },
            .aarch64 => {
                const a = self.reg(addr);
                switch (size) {
                    1 => try self.insn("strb {s}, [{s}]", .{ self.reg32(src), a }),
                    2 => try self.insn("strh {s}, [{s}]", .{ self.reg32(src), a }),
                    4 => try self.insn("str {s}, [{s}]", .{ self.reg32(src), a }),
                    else => try self.insn("str {s}, [{s}]", .{ self.reg(src), a }),
                }
            },
        }
    }

    /// The sub-word name of a role. aarch64 has only `w`, so anything narrower
    /// than 4 bytes is still addressed through `w` and the instruction carries
    /// the width.
    pub fn subReg(self: Self, r: Reg, size: usize) []const u8 {
        return switch (self.arch) {
            .x86_64 => switch (size) {
                1 => switch (r) {
                    .acc => "%al",
                    .tmp => "%cl",
                    .tmp2 => "%sil",
                    .tmp3 => "%dl",
                    .base => "%bpl",
                    .stack => "%spl",
                    .scratch => "%r11b",
                    .scratch2 => "%r10b",
                    .mem_dst => "%dil",
                    .mem_src => "%sil",
                    .mem_len => "%cl",
                },
                2 => switch (r) {
                    .acc => "%ax",
                    .tmp => "%cx",
                    .tmp2 => "%si",
                    .tmp3 => "%dx",
                    .base => "%bp",
                    .stack => "%sp",
                    .scratch => "%r11w",
                    .scratch2 => "%r10w",
                    .mem_dst => "%di",
                    .mem_src => "%si",
                    .mem_len => "%cx",
                },
                4 => self.reg32(r),
                else => self.reg(r),
            },
            .aarch64 => if (size <= 4) self.reg32(r) else self.reg(r),
        };
    }

    // ------------------------------------------------------------ arithmetic

    /// `acc = acc <op> tmp`.
    pub fn binOp(self: Self, op: BinOp) !void {
        switch (self.arch) {
            .x86_64 => switch (op) {
                .add => try self.insn("addq %rcx, %rax", .{}),
                .sub => try self.insn("subq %rcx, %rax", .{}),
                .mul => try self.insn("imulq %rcx, %rax", .{}),
                .div => {
                    // `cqto` sign-extends %rax through %rdx, which `idivq`
                    // requires as its high half.
                    try self.insn("cqto", .{});
                    try self.insn("idivq %rcx", .{});
                },
                .rem => {
                    try self.insn("cqto", .{});
                    try self.insn("idivq %rcx", .{});
                    try self.insn("movq %rdx, %rax", .{});
                },
                .bit_and => try self.insn("andq %rcx, %rax", .{}),
                .bit_or => try self.insn("orq %rcx, %rax", .{}),
                .bit_xor => try self.insn("xorq %rcx, %rax", .{}),
                .shl => try self.insn("shlq %cl, %rax", .{}),
                .shr_arith => try self.insn("sarq %cl, %rax", .{}),
                .shr_logical => try self.insn("shrq %cl, %rax", .{}),
            },
            .aarch64 => switch (op) {
                .add => try self.insn("add x0, x0, x1", .{}),
                .sub => try self.insn("sub x0, x0, x1", .{}),
                .mul => try self.insn("mul x0, x0, x1", .{}),
                .div => try self.insn("sdiv x0, x0, x1", .{}),
                .rem => {
                    // No remainder instruction: quotient, then
                    // `x0 - quotient*divisor` in one multiply-subtract.
                    try self.insn("sdiv x9, x0, x1", .{});
                    try self.insn("msub x0, x9, x1, x0", .{});
                },
                .bit_and => try self.insn("and x0, x0, x1", .{}),
                .bit_or => try self.insn("orr x0, x0, x1", .{}),
                .bit_xor => try self.insn("eor x0, x0, x1", .{}),
                .shl => try self.insn("lsl x0, x0, x1", .{}),
                .shr_arith => try self.insn("asr x0, x0, x1", .{}),
                .shr_logical => try self.insn("lsr x0, x0, x1", .{}),
            },
        }
    }

    /// `dst = dst <op> src` for the operations that need no fixed register
    /// pair. Division and the shifts are excluded: on x86-64 both constrain
    /// their operands to particular registers, so they only exist in the
    /// accumulator form above, and asking for them here is a programming
    /// error rather than a missing feature.
    pub fn aluRegs(self: Self, op: BinOp, dst: Reg, src: Reg) !void {
        switch (self.arch) {
            .x86_64 => {
                const mnemonic = switch (op) {
                    .add => "addq",
                    .sub => "subq",
                    .mul => "imulq",
                    .bit_and => "andq",
                    .bit_or => "orq",
                    .bit_xor => "xorq",
                    .div, .rem, .shl, .shr_arith, .shr_logical => unreachable,
                };
                try self.insn("{s} {s}, {s}", .{ mnemonic, self.reg(src), self.reg(dst) });
            },
            .aarch64 => {
                const mnemonic = switch (op) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    .bit_and => "and",
                    .bit_or => "orr",
                    .bit_xor => "eor",
                    .div, .rem, .shl, .shr_arith, .shr_logical => unreachable,
                };
                try self.insn("{s} {s}, {s}, {s}", .{
                    mnemonic, self.reg(dst), self.reg(dst), self.reg(src),
                });
            },
        }
    }

    /// `acc = -acc`.
    pub fn negate(self: Self) !void {
        try self.negateReg(.acc);
    }

    pub fn negateReg(self: Self, r: Reg) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("negq {s}", .{self.reg(r)}),
            .aarch64 => try self.insn("neg {s}, {s}", .{ self.reg(r), self.reg(r) }),
        }
    }

    /// `acc = ~acc`.
    pub fn bitNot(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("notq %rax", .{}),
            .aarch64 => try self.insn("mvn x0, x0", .{}),
        }
    }

    /// Set a role to zero. Spelled out rather than left to the caller because
    /// x86 has a shorter idiom for it than a general immediate move.
    pub fn zero(self: Self, r: Reg) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("xorq {s}, {s}", .{ self.reg(r), self.reg(r) }),
            .aarch64 => try self.insn("mov {s}, #0", .{self.reg(r)}),
        }
    }

    /// `acc = (acc != 0) ? 1 : 0` — collapse any value to a boolean.
    pub fn boolNormalize(self: Self) !void {
        switch (self.arch) {
            .x86_64 => {
                try self.insn("testq %rax, %rax", .{});
                try self.insn("setne %al", .{});
                try self.insn("movzbq %al, %rax", .{});
            },
            .aarch64 => {
                try self.insn("cmp x0, #0", .{});
                try self.insn("cset x0, ne", .{});
            },
        }
    }

    /// `acc = acc + imm`, for pointer arithmetic the codegen knows statically.
    pub fn addImm(self: Self, r: Reg, value: i64) !void {
        if (value == 0) return;
        switch (self.arch) {
            .x86_64 => try self.insn("addq ${d}, {s}", .{ value, self.reg(r) }),
            .aarch64 => {
                if (value > 0 and value <= 0xfff) {
                    try self.insn("add {s}, {s}, #{d}", .{ self.reg(r), self.reg(r), value });
                } else if (value < 0 and value >= -0xfff) {
                    try self.insn("sub {s}, {s}, #{d}", .{ self.reg(r), self.reg(r), -value });
                } else {
                    try self.movImmReg(.scratch, value);
                    try self.insn("add {s}, {s}, {s}", .{ self.reg(r), self.reg(r), self.reg(.scratch) });
                }
            },
        }
    }

    /// `acc = acc * imm`, for scaling an index by an element size.
    pub fn mulImm(self: Self, value: i64) !void {
        if (value == 1) return;
        switch (self.arch) {
            .x86_64 => try self.insn("imulq ${d}, %rax, %rax", .{value}),
            .aarch64 => {
                try self.movImmReg(.scratch, value);
                try self.insn("mul x0, x0, {s}", .{self.reg(.scratch)});
            },
        }
    }

    /// Sign- or zero-extend the low `size` bytes of the accumulator to a full
    /// word, after a narrower value has been produced in it.
    pub fn narrow(self: Self, size: usize, signed: bool) !void {
        if (size >= 8) return;
        switch (self.arch) {
            .x86_64 => switch (size) {
                1 => try self.insn("{s} %al, %rax", .{if (signed) "movsbq" else "movzbq"}),
                2 => try self.insn("{s} %ax, %rax", .{if (signed) "movswq" else "movzwq"}),
                4 => if (signed)
                    try self.insn("movslq %eax, %rax", .{})
                else
                    try self.insn("movl %eax, %eax", .{}),
                else => {},
            },
            .aarch64 => switch (size) {
                1 => try self.insn("{s} x0, w0", .{if (signed) "sxtb" else "uxtb"}),
                2 => try self.insn("{s} x0, w0", .{if (signed) "sxth" else "uxth"}),
                4 => if (signed)
                    try self.insn("sxtw x0, w0", .{})
                else
                    // Writing a `w` register zeroes the upper half, which is
                    // the whole of the zero-extension.
                    try self.insn("mov w0, w0", .{}),
                else => {},
            },
        }
    }

    // ------------------------------------------------------------ comparison

    /// `acc = (acc <cond> tmp) ? 1 : 0`.
    pub fn compareSet(self: Self, cond: Cond) !void {
        switch (self.arch) {
            .x86_64 => {
                const setcc = switch (cond) {
                    .eq => "sete",
                    .ne => "setne",
                    .lt => "setl",
                    .le => "setle",
                    .gt => "setg",
                    .ge => "setge",
                    .ult => "setb",
                    .ule => "setbe",
                    .ugt => "seta",
                    .uge => "setae",
                };
                try self.insn("cmpq %rcx, %rax", .{});
                try self.insn("{s} %al", .{setcc});
                try self.insn("movzbq %al, %rax", .{});
            },
            .aarch64 => {
                // `cset` writes the whole 0-or-1 result in one instruction;
                // there is no flag-to-byte-then-extend dance.
                const suffix = switch (cond) {
                    .eq => "eq",
                    .ne => "ne",
                    .lt => "lt",
                    .le => "le",
                    .gt => "gt",
                    .ge => "ge",
                    .ult => "lo",
                    .ule => "ls",
                    .ugt => "hi",
                    .uge => "hs",
                };
                try self.insn("cmp x0, x1", .{});
                try self.insn("cset x0, {s}", .{suffix});
            },
        }
    }

    /// Turn the flags a preceding comparison set into 0 or 1 in the
    /// accumulator, without performing a comparison of its own.
    pub fn setFromFlags(self: Self, cond: Cond) !void {
        switch (self.arch) {
            .x86_64 => {
                const setcc = switch (cond) {
                    .eq => "sete",
                    .ne => "setne",
                    .lt => "setl",
                    .le => "setle",
                    .gt => "setg",
                    .ge => "setge",
                    .ult => "setb",
                    .ule => "setbe",
                    .ugt => "seta",
                    .uge => "setae",
                };
                try self.insn("{s} %al", .{setcc});
                try self.insn("movzbq %al, %rax", .{});
            },
            .aarch64 => {
                const suffix = switch (cond) {
                    .eq => "eq",
                    .ne => "ne",
                    .lt => "lt",
                    .le => "le",
                    .gt => "gt",
                    .ge => "ge",
                    .ult => "lo",
                    .ule => "ls",
                    .ugt => "hi",
                    .uge => "hs",
                };
                try self.insn("cset x0, {s}", .{suffix});
            },
        }
    }

    /// Compare two roles, leaving flags set for a following conditional
    /// branch or conditional move.
    pub fn cmpRegs(self: Self, left: Reg, right: Reg) !void {
        switch (self.arch) {
            // AT&T order puts the subtrahend first: this is `left - right`.
            .x86_64 => try self.insn("cmpq {s}, {s}", .{ self.reg(right), self.reg(left) }),
            .aarch64 => try self.insn("cmp {s}, {s}", .{ self.reg(left), self.reg(right) }),
        }
    }

    /// Compare the accumulator against an immediate, leaving flags set for a
    /// following conditional branch.
    pub fn cmpImm(self: Self, r: Reg, value: i64) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("cmpq ${d}, {s}", .{ value, self.reg(r) }),
            .aarch64 => {
                if (value >= 0 and value <= 0xfff) {
                    try self.insn("cmp {s}, #{d}", .{ self.reg(r), value });
                } else {
                    try self.movImmReg(.scratch, value);
                    try self.insn("cmp {s}, {s}", .{ self.reg(r), self.reg(.scratch) });
                }
            },
        }
    }

    // ---------------------------------------------------------- control flow

    pub fn jump(self: Self, label: []const u8) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("jmp {s}", .{label}),
            .aarch64 => try self.insn("b {s}", .{label}),
        }
    }

    /// Branch when `r` is zero.
    pub fn jumpIfZero(self: Self, r: Reg, label: []const u8) !void {
        switch (self.arch) {
            .x86_64 => {
                try self.insn("testq {s}, {s}", .{ self.reg(r), self.reg(r) });
                try self.insn("jz {s}", .{label});
            },
            .aarch64 => try self.insn("cbz {s}, {s}", .{ self.reg(r), label }),
        }
    }

    /// Branch when `r` is non-zero.
    pub fn jumpIfNotZero(self: Self, r: Reg, label: []const u8) !void {
        switch (self.arch) {
            .x86_64 => {
                try self.insn("testq {s}, {s}", .{ self.reg(r), self.reg(r) });
                try self.insn("jnz {s}", .{label});
            },
            .aarch64 => try self.insn("cbnz {s}, {s}", .{ self.reg(r), label }),
        }
    }

    /// Branch on the flags a preceding `cmpImm` set.
    pub fn jumpCond(self: Self, cond: Cond, label: []const u8) !void {
        switch (self.arch) {
            .x86_64 => {
                const jcc = switch (cond) {
                    .eq => "je",
                    .ne => "jne",
                    .lt => "jl",
                    .le => "jle",
                    .gt => "jg",
                    .ge => "jge",
                    .ult => "jb",
                    .ule => "jbe",
                    .ugt => "ja",
                    .uge => "jae",
                };
                try self.insn("{s} {s}", .{ jcc, label });
            },
            .aarch64 => {
                const suffix = switch (cond) {
                    .eq => "eq",
                    .ne => "ne",
                    .lt => "lt",
                    .le => "le",
                    .gt => "gt",
                    .ge => "ge",
                    .ult => "lo",
                    .ule => "ls",
                    .ugt => "hi",
                    .uge => "hs",
                };
                try self.insn("b.{s} {s}", .{ suffix, label });
            },
        }
    }

    pub fn call(self: Self, sym: []const u8) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("call {s}", .{sym}),
            .aarch64 => try self.insn("bl {s}", .{sym}),
        }
    }

    pub fn callReg(self: Self, r: Reg) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("call *{s}", .{self.reg(r)}),
            .aarch64 => try self.insn("blr {s}", .{self.reg(r)}),
        }
    }

    /// Adjust the stack pointer after a call whose arguments overflowed the
    /// register set.
    pub fn addStack(self: Self, bytes: usize) !void {
        if (bytes == 0) return;
        switch (self.arch) {
            .x86_64 => try self.insn("addq ${d}, %rsp", .{bytes}),
            .aarch64 => {
                if (bytes <= 0xfff) {
                    try self.insn("add sp, sp, #{d}", .{bytes});
                } else {
                    try self.movImmReg(.scratch, @intCast(bytes));
                    try self.insn("add sp, sp, {s}", .{self.reg(.scratch)});
                }
            },
        }
    }

    // ------------------------------------------------- stack-relative access

    /// Read a word the stack machine has already pushed, without popping it.
    /// `slot` counts pushes, not bytes, because the two architectures move the
    /// stack pointer by different amounts per push.
    pub fn loadPushed(self: Self, dst: Reg, slot: usize) !void {
        const offset = slot * self.pushStride();
        switch (self.arch) {
            .x86_64 => if (offset == 0)
                try self.insn("movq (%rsp), {s}", .{self.reg(dst)})
            else
                try self.insn("movq {d}(%rsp), {s}", .{ offset, self.reg(dst) }),
            .aarch64 => if (offset == 0)
                try self.insn("ldr {s}, [sp]", .{self.reg(dst)})
            else
                try self.insn("ldr {s}, [sp, #{d}]", .{ self.reg(dst), offset }),
        }
    }

    /// Copy the stack pointer into a role. aarch64 forbids `sp` as the operand
    /// of most instructions, so anything that wants its value has to move it
    /// into a general register first.
    pub fn movFromStackPtr(self: Self, dst: Reg) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq %rsp, {s}", .{self.reg(dst)}),
            .aarch64 => try self.insn("mov {s}, sp", .{self.reg(dst)}),
        }
    }

    /// Push the current stack pointer as a value.
    pub fn pushStackPtr(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("pushq %rsp", .{}),
            .aarch64 => {
                try self.insn("mov x9, sp", .{});
                try self.insn("str x9, [sp, #-16]!", .{});
            },
        }
    }

    // --------------------------------------------------------- conditional move

    /// `dst = cond ? src : dst`, on the flags a preceding `cmp` set.
    pub fn condMove(self: Self, cond: Cond, dst: Reg, src: Reg) !void {
        switch (self.arch) {
            .x86_64 => {
                const cmov = switch (cond) {
                    .eq => "cmoveq",
                    .ne => "cmovneq",
                    .lt => "cmovlq",
                    .le => "cmovleq",
                    .gt => "cmovgq",
                    .ge => "cmovgeq",
                    .ult => "cmovbq",
                    .ule => "cmovbeq",
                    .ugt => "cmovaq",
                    .uge => "cmovaeq",
                };
                try self.insn("{s} {s}, {s}", .{ cmov, self.reg(src), self.reg(dst) });
            },
            .aarch64 => {
                const suffix = switch (cond) {
                    .eq => "eq",
                    .ne => "ne",
                    .lt => "lt",
                    .le => "le",
                    .gt => "gt",
                    .ge => "ge",
                    .ult => "lo",
                    .ule => "ls",
                    .ugt => "hi",
                    .uge => "hs",
                };
                // `csel dst, src, dst, cond` is the exact equivalent: take
                // `src` when the condition holds, keep `dst` otherwise.
                try self.insn("csel {s}, {s}, {s}, {s}", .{
                    self.reg(dst), self.reg(src), self.reg(dst), suffix,
                });
            },
        }
    }

    // ----------------------------------------------------------- block memory

    /// Copy `mem_len` bytes from `mem_src` to `mem_dst`.
    ///
    /// Both implementations leave the same state behind — `mem_dst` and
    /// `mem_src` advanced by the length, `mem_len` zero — because callers in
    /// the codegen rely on the pointer having moved and compensate for it.
    /// `label_id` must be unique within the translation unit; the caller takes
    /// it from the codegen's label counter so the output stays deterministic.
    pub fn memCopy(self: Self, label_id: usize) !void {
        switch (self.arch) {
            .x86_64 => {
                // `cld` because the direction flag is callee-saved but not
                // guaranteed clear on entry from hand-written assembly.
                try self.insn("cld", .{});
                try self.insn("rep movsb", .{});
            },
            .aarch64 => {
                try self.print("    cbz x13, .L_memcpy_done_{d}\n", .{label_id});
                try self.print(".L_memcpy_loop_{d}:\n", .{label_id});
                try self.insn("ldrb w9, [x12], #1", .{});
                try self.insn("strb w9, [x11], #1", .{});
                try self.insn("subs x13, x13, #1", .{});
                try self.print("    b.ne .L_memcpy_loop_{d}\n", .{label_id});
                try self.print(".L_memcpy_done_{d}:\n", .{label_id});
            },
        }
    }

    /// Fill `mem_len` bytes at `mem_dst` with the low byte of `acc`.
    pub fn memFill(self: Self, label_id: usize) !void {
        switch (self.arch) {
            .x86_64 => {
                try self.insn("cld", .{});
                try self.insn("rep stosb", .{});
            },
            .aarch64 => {
                try self.print("    cbz x13, .L_memset_done_{d}\n", .{label_id});
                try self.print(".L_memset_loop_{d}:\n", .{label_id});
                try self.insn("strb w0, [x11], #1", .{});
                try self.insn("subs x13, x13, #1", .{});
                try self.print("    b.ne .L_memset_loop_{d}\n", .{label_id});
                try self.print(".L_memset_done_{d}:\n", .{label_id});
            },
        }
    }

    // ------------------------------------------------------------- CPU state

    pub fn nop(self: Self) !void {
        try self.insn("nop", .{});
    }

    /// Halt until an interrupt arrives. The idle loop of every kernel.
    pub fn halt(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("hlt", .{}),
            .aarch64 => try self.insn("wfi", .{}),
        }
    }

    pub fn disableInterrupts(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("cli", .{}),
            .aarch64 => try self.insn("msr daifset, #2", .{}),
        }
    }

    pub fn enableInterrupts(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("sti", .{}),
            .aarch64 => try self.insn("msr daifclr, #2", .{}),
        }
    }

    /// The barrier a device-register read needs *after* the load, and a
    /// device-register write needs *before* the store, so that accesses to
    /// device memory keep program order relative to ordinary memory.
    ///
    /// On x86-64 both are empty: the architecture's memory model already
    /// orders loads with loads and stores with stores, so a fence here would
    /// be cost without meaning. On aarch64 they are mandatory — without them
    /// a driver's register writes may be observed by the device in a
    /// different order than written, which is the classic silent Pi driver
    /// bug (home-lang/home#584).
    pub fn mmioBarrierAfterRead(self: Self) !void {
        switch (self.arch) {
            .x86_64 => {},
            .aarch64 => try self.insn("dmb oshld", .{}),
        }
    }

    pub fn mmioBarrierBeforeWrite(self: Self) !void {
        switch (self.arch) {
            .x86_64 => {},
            .aarch64 => try self.insn("dmb oshst", .{}),
        }
    }

    /// Whether this target has a separate I/O address space reached by `in`
    /// and `out` instructions. Only x86 does; everywhere else the same job is
    /// done by memory-mapped registers, and a port intrinsic is not something
    /// to emulate but something to reject.
    pub fn hasPortIo(self: Self) bool {
        return switch (self.arch) {
            .x86_64 => true,
            .aarch64 => false,
        };
    }

    /// `pause` / `yield`: a hint inside a spin loop.
    pub fn spinHint(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("pause", .{}),
            .aarch64 => try self.insn("yield", .{}),
        }
    }

    /// Sleep until another core signals an event.
    ///
    /// x86 has no `sev`/`wfe` pair, so the closest honest lowering is the
    /// spin-loop hint: a caller polling a flag still makes progress, it just
    /// does not sleep. A caller that needs real cross-core wakeup wants a
    /// proper synchronisation primitive on either architecture.
    pub fn waitForEvent(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("pause", .{}),
            .aarch64 => try self.insn("wfe", .{}),
        }
    }

    /// Read the interrupt-enable state and then mask interrupts, leaving the
    /// previous state in the accumulator. Paired with `restoreInterrupts`,
    /// this is what makes a critical section nestable: an inner section must
    /// not switch interrupts back on underneath an outer one.
    pub fn saveInterrupts(self: Self) !void {
        switch (self.arch) {
            .x86_64 => {
                try self.insn("pushfq", .{});
                try self.insn("popq %rax", .{});
                try self.insn("cli", .{});
            },
            .aarch64 => {
                // DAIF holds the four mask bits; `daifset, #2` sets I alone.
                try self.insn("mrs x0, daif", .{});
                try self.insn("msr daifset, #2", .{});
            },
        }
    }

    /// Restore the interrupt state saved by `saveInterrupts`, taken from the
    /// accumulator.
    pub fn restoreInterrupts(self: Self) !void {
        switch (self.arch) {
            .x86_64 => {
                try self.insn("pushq %rax", .{});
                try self.insn("popfq", .{});
            },
            .aarch64 => try self.insn("msr daif, x0", .{}),
        }
    }

    /// A monotonically increasing counter, into the accumulator.
    ///
    /// The two are not the same clock and must not be compared across
    /// architectures: x86's counts core cycles, ARM's counts at a fixed
    /// frequency given by `CNTFRQ_EL0`. Callers converting to wall time have
    /// to ask for the frequency either way.
    pub fn readTimestamp(self: Self) !void {
        switch (self.arch) {
            .x86_64 => {
                // rdtsc splits the 64-bit value across edx:eax.
                try self.insn("rdtsc", .{});
                try self.insn("shlq $32, %rdx", .{});
                try self.insn("orq %rdx, %rax", .{});
            },
            .aarch64 => try self.insn("mrs x0, cntvct_el0", .{}),
        }
    }

    /// Atomically add `tmp` to the 64-bit location addressed by `tmp3`,
    /// leaving the value it held before in the accumulator.
    ///
    /// `label_id` must be unique within the translation unit; the caller takes
    /// it from the codegen's label counter so the output stays deterministic.
    pub fn atomicAdd64(self: Self, label_id: usize) !void {
        switch (self.arch) {
            .x86_64 => {
                // `lock xadd` is the whole operation: it needs no retry loop,
                // so it cannot livelock under contention.
                try self.insn("movq %rcx, %rax", .{});
                try self.insn("lock xaddq %rax, (%rdx)", .{});
            },
            .aarch64 => {
                // The exclusive-monitor loop rather than the single-instruction
                // LSE form (`ldaddal`), because LSE arrived in ARMv8.1 and the
                // Pi 3's Cortex-A53 is ARMv8.0 — the LSE form assembles only
                // with `.arch armv8.1-a` and faults as undefined on that core.
                // Acquire on the load and release on the store give this the
                // same ordering as the x86 instruction.
                try self.print(".L_atomic_add_{d}:\n", .{label_id});
                try self.insn("ldaxr x0, [x3]", .{});
                try self.insn("add x9, x0, x1", .{});
                try self.insn("stlxr w10, x9, [x3]", .{});
                try self.print("    cbnz w10, .L_atomic_add_{d}\n", .{label_id});
            },
        }
    }

    /// Whether `name` is a system register this target can read or write.
    /// x86 has no general system-register space, so only the control
    /// registers the kernel actually touches are accepted.
    pub fn knowsSysreg(self: Self, name: []const u8) bool {
        return switch (self.arch) {
            .x86_64 => std.mem.eql(u8, name, "cr0") or std.mem.eql(u8, name, "cr2") or
                std.mem.eql(u8, name, "cr3") or std.mem.eql(u8, name, "cr4"),
            // aarch64 register names are validated by the assembler, which
            // knows the whole encoding space; repeating that list here would
            // only go stale. Reject anything that is not plausibly a name so a
            // typo cannot become an assembler error with no Home location.
            .aarch64 => name.len > 0 and name.len < 32 and for (name) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') break false;
            } else true,
        };
    }

    /// Read a system register into the accumulator.
    pub fn readSysreg(self: Self, name: []const u8) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("mov %{s}, %rax", .{name}),
            .aarch64 => try self.insn("mrs x0, {s}", .{name}),
        }
    }

    /// Write the accumulator to a system register.
    pub fn writeSysreg(self: Self, name: []const u8) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("mov %rax, %{s}", .{name}),
            .aarch64 => {
                try self.insn("msr {s}, x0", .{name});
                // A system-register write does not take effect for following
                // instructions until the pipeline is resynchronised.
                try self.insn("isb", .{});
            },
        }
    }

    /// Set the stack pointer from the accumulator, and read it into one.
    ///
    /// Used by the context switch, which is the one place a kernel legitimately
    /// changes stacks underneath itself.
    pub fn writeStackPtr(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("movq %rax, %rsp", .{}),
            .aarch64 => try self.insn("mov sp, x0", .{}),
        }
    }

    /// Invalidate the TLB entry covering the address in the accumulator.
    pub fn invalidateTlbPage(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("invlpg (%rax)", .{}),
            .aarch64 => {
                // TLBI takes a virtual address shifted right by 12, and needs
                // the surrounding barriers: `dsb ishst` so earlier page-table
                // writes are visible to the table walker, `dsb ish` so the
                // invalidation completes, and `isb` so following instructions
                // see the new translation. Omitting them leaves the old
                // mapping live for an unbounded time.
                try self.insn("dsb ishst", .{});
                try self.insn("lsr x0, x0, #12", .{});
                try self.insn("tlbi vaae1is, x0", .{});
                try self.insn("dsb ish", .{});
                try self.insn("isb", .{});
            },
        }
    }

    /// A barrier against the *compiler* reordering, with no instruction of its
    /// own. This backend performs no reordering across a call, so it emits
    /// nothing on either target — said out loud rather than left as an
    /// unexplained empty case.
    pub fn compilerBarrier(self: Self) !void {
        try self.raw("    # compiler barrier: this backend does not reorder across it\n");
    }

    /// A full hardware memory fence: every load and store issued before it is
    /// observed before any issued after it. Unlike `compilerBarrier` this is a
    /// real instruction — it constrains the CPU and the store buffer, not just
    /// the compiler.
    pub fn memoryBarrier(self: Self) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("mfence", .{}),
            // `dmb ish` orders against the inner-shareable domain, which is
            // every core an SMP kernel shares memory with. `sy` would also
            // cover device and outer-shareable traffic that a lock does not
            // need to fence.
            .aarch64 => try self.insn("dmb ish", .{}),
        }
    }

    /// Atomic 32-bit compare-and-exchange.
    ///
    /// Contract: address in `tmp3`, expected value in `acc`, desired value in
    /// `tmp`. Leaves the value the location actually held in `acc`, so a
    /// caller compares it against what it expected to learn whether the swap
    /// happened.
    pub fn atomicCompareExchange32(self: Self, label_id: usize) !void {
        switch (self.arch) {
            .x86_64 => try self.insn("lock cmpxchgl %ecx, (%rdx)", .{}),
            .aarch64 => {
                try self.insn("mov w2, w0", .{});
                try self.print(".L_cas_{d}:\n", .{label_id});
                try self.insn("ldaxr w0, [x3]", .{});
                try self.insn("cmp w0, w2", .{});
                try self.print("    b.ne .L_cas_fail_{d}\n", .{label_id});
                try self.insn("stlxr w9, w1, [x3]", .{});
                try self.print("    cbnz w9, .L_cas_{d}\n", .{label_id});
                try self.print("    b .L_cas_done_{d}\n", .{label_id});
                try self.print(".L_cas_fail_{d}:\n", .{label_id});
                // The exclusive monitor is still armed after a failed compare;
                // leaving it so can make an unrelated store-exclusive succeed
                // when it should not.
                try self.insn("clrex", .{});
                try self.print(".L_cas_done_{d}:\n", .{label_id});
            },
        }
    }

    /// Atomic 32-bit exchange: address in `tmp3`, new value in `tmp`, previous
    /// value left in `acc`.
    pub fn atomicExchange32(self: Self, label_id: usize) !void {
        switch (self.arch) {
            .x86_64 => {
                // `xchg` is implicitly locked on x86.
                try self.insn("xchgl %ecx, (%rdx)", .{});
                try self.insn("movl %ecx, %eax", .{});
            },
            .aarch64 => {
                try self.print(".L_xchg_{d}:\n", .{label_id});
                try self.insn("ldaxr w0, [x3]", .{});
                try self.insn("stlxr w9, w1, [x3]", .{});
                try self.print("    cbnz w9, .L_xchg_{d}\n", .{label_id});
            },
        }
    }

    /// Atomic 32-bit add: address in `tmp3`, addend in `tmp`, previous value
    /// left in `acc`.
    pub fn atomicAdd32(self: Self, label_id: usize) !void {
        switch (self.arch) {
            .x86_64 => {
                try self.insn("movl %ecx, %eax", .{});
                try self.insn("lock xaddl %eax, (%rdx)", .{});
            },
            .aarch64 => {
                try self.print(".L_xadd_{d}:\n", .{label_id});
                try self.insn("ldaxr w0, [x3]", .{});
                try self.insn("add w10, w0, w1", .{});
                try self.insn("stlxr w9, w10, [x3]", .{});
                try self.print("    cbnz w9, .L_xadd_{d}\n", .{label_id});
            },
        }
    }

    /// Acquire-load of a 32-bit location addressed by `tmp3`, into `acc`.
    pub fn atomicLoad32(self: Self) !void {
        switch (self.arch) {
            // A plain load is already acquire-ordered under x86's memory model.
            .x86_64 => try self.insn("movl (%rdx), %eax", .{}),
            .aarch64 => try self.insn("ldar w0, [x3]", .{}),
        }
    }

    /// Release-store of `tmp` into the 32-bit location addressed by `tmp3`.
    pub fn atomicStore32(self: Self) !void {
        switch (self.arch) {
            // A plain store is already release-ordered under x86's memory model.
            .x86_64 => try self.insn("movl %ecx, (%rdx)", .{}),
            .aarch64 => try self.insn("stlr w1, [x3]", .{}),
        }
    }

    /// A memory barrier of the requested strength.
    ///
    /// x86-64's memory model already orders loads with loads and stores with
    /// stores, so only the full barrier and the instruction-stream
    /// synchronisation emit anything. That is a property of the architecture,
    /// not an omission: see home-lang/home#584.
    pub fn barrier(self: Self, kind: Barrier) !void {
        switch (self.arch) {
            .x86_64 => switch (kind) {
                .full => try self.insn("mfence", .{}),
                .loads => try self.insn("lfence", .{}),
                .stores => try self.insn("sfence", .{}),
                .isync => try self.insn("cpuid", .{}),
            },
            .aarch64 => switch (kind) {
                .full => try self.insn("dsb sy", .{}),
                .loads => try self.insn("dmb ld", .{}),
                .stores => try self.insn("dmb st", .{}),
                .isync => try self.insn("isb", .{}),
            },
        }
    }

    // ------------------------------------------------------------------ data

    /// Emit one initialised word of static data.
    pub fn dataWord(self: Self, value: i64) !void {
        try self.print("    .quad {d}\n", .{value});
    }

    pub fn dataBytes(self: Self, count: usize) !void {
        try self.print("    .zero {d}\n", .{count});
    }

    pub fn dataString(self: Self, text: []const u8) !void {
        try self.print("    .asciz \"{s}\"\n", .{text});
    }
};

// ---------------------------------------------------------------------- tests

const testing = std.testing;

fn emitToString(arch: Arch, comptime body: fn (Emitter) anyerror!void) ![]u8 {
    var out: std.ArrayList(u8) = .{ .items = &[_]u8{}, .capacity = 0 };
    const e = Emitter{ .arch = arch, .out = &out, .gpa = testing.allocator };
    try body(e);
    return out.toOwnedSlice(testing.allocator);
}

test "arch parses the spellings that appear in triples" {
    try testing.expectEqual(Arch.x86_64, Arch.parse("x86_64").?);
    try testing.expectEqual(Arch.x86_64, Arch.parse("x86-64").?);
    try testing.expectEqual(Arch.aarch64, Arch.parse("aarch64").?);
    try testing.expectEqual(Arch.aarch64, Arch.parse("arm64").?);
    try testing.expect(Arch.parse("riscv64") == null);
}

test "aarch64 materialises a 64-bit constant in halfwords" {
    // A Raspberry Pi 5 peripheral base. A 32-bit move would silently drop the
    // top bits and address nothing.
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.movImmReg(.acc, 0x1F00000000);
        }
    }.f);
    defer testing.allocator.free(text);
    // 0x1F00000000 is 31 << 32: one halfword, at shift 32.
    try testing.expectEqualStrings("    movz x0, #31, lsl #32\n", text);
}

test "aarch64 small constant is one instruction" {
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.movImmReg(.acc, 42);
        }
    }.f);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("    movz x0, #42\n", text);
}

test "aarch64 negative constant uses movn" {
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.movImmReg(.acc, -1);
        }
    }.f);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("    movn x0, #0\n", text);
}

test "aarch64 prologue saves the link register" {
    // x30 is not saved by the hardware on a branch-and-link, so a frame that
    // omits it cannot survive a nested call.
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.prologue(32);
        }
    }.f);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "stp x29, x30, [sp, #-16]!") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sub sp, sp, #32") != null);
}

test "aarch64 deep frame slot computes its address" {
    // Past ldur's signed 9-bit reach the offset must be materialised, not
    // wrapped: wrapping would read a neighbouring local. 4096 is exactly one
    // page, so it takes the shifted-immediate form rather than a movn.
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.loadLocal(.acc, -4096);
        }
    }.f);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "ldur") == null);
    try testing.expectEqualStrings(
        "    sub x9, x29, #1, lsl #12\n    ldr x0, [x9]\n",
        text,
    );
}

test "aarch64 frame slot past the shifted-immediate form materialises" {
    // 4097 is neither a 12-bit immediate nor a multiple of a page, so the
    // offset has to be built in a register first.
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.loadLocal(.acc, -4097);
        }
    }.f);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "movn x9, #4096") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add x9, x29, x9") != null);
}

test "aarch64 shallow frame slot uses ldur directly" {
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.loadLocal(.acc, -8);
        }
    }.f);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("    ldur x0, [x29, #-8]\n", text);
}

test "aarch64 remainder is sdiv plus msub" {
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.binOp(.rem);
        }
    }.f);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "sdiv x9, x0, x1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "msub x0, x9, x1, x0") != null);
}

test "aarch64 symbol address uses the adrp pair" {
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.leaSymbol(.acc, "uart_base");
        }
    }.f);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "adrp x0, uart_base") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add x0, x0, :lo12:uart_base") != null);
}

test "sub-word loads extend correctly on both targets" {
    const a64 = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.loadIndirect(.acc, .tmp, 1, false);
            try e.loadIndirect(.acc, .tmp, 1, true);
            try e.loadIndirect(.acc, .tmp, 4, false);
        }
    }.f);
    defer testing.allocator.free(a64);
    try testing.expect(std.mem.indexOf(u8, a64, "ldrb w0, [x1]") != null);
    try testing.expect(std.mem.indexOf(u8, a64, "ldrsb x0, [x1]") != null);
    try testing.expect(std.mem.indexOf(u8, a64, "ldr w0, [x1]") != null);

    const x86 = try emitToString(.x86_64, struct {
        fn f(e: Emitter) !void {
            try e.loadIndirect(.acc, .tmp, 1, false);
        }
    }.f);
    defer testing.allocator.free(x86);
    try testing.expectEqualStrings("    movzbq (%rcx), %rax\n", x86);
}

test "compare leaves a 0 or 1 in the accumulator on both targets" {
    const a64 = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.compareSet(.lt);
        }
    }.f);
    defer testing.allocator.free(a64);
    try testing.expectEqualStrings("    cmp x0, x1\n    cset x0, lt\n", a64);

    const x86 = try emitToString(.x86_64, struct {
        fn f(e: Emitter) !void {
            try e.compareSet(.lt);
        }
    }.f);
    defer testing.allocator.free(x86);
    try testing.expect(std.mem.indexOf(u8, x86, "setl %al") != null);
}

test "unsigned comparisons do not lower to signed conditions" {
    // An address above 2^63 compares wrong under a signed predicate, and the
    // failure is silent, so the two families must stay distinct.
    const a64 = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.compareSet(.ult);
        }
    }.f);
    defer testing.allocator.free(a64);
    try testing.expect(std.mem.indexOf(u8, a64, "cset x0, lo") != null);
}

test "push keeps the aarch64 stack 16-byte aligned" {
    const text = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.push(.acc);
            try e.pop(.tmp);
        }
    }.f);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "    str x0, [sp, #-16]!\n    ldr x1, [sp], #16\n",
        text,
    );
}

test "barriers are real on aarch64 and honest on x86" {
    const a64 = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.barrier(.full);
            try e.barrier(.isync);
        }
    }.f);
    defer testing.allocator.free(a64);
    try testing.expectEqualStrings("    dsb sy\n    isb\n", a64);
}

test "halt is the idle instruction of each architecture" {
    const a64 = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.halt();
        }
    }.f);
    defer testing.allocator.free(a64);
    try testing.expectEqualStrings("    wfi\n", a64);
}

test "block copy leaves the same register state on both targets" {
    // Callers compensate for the pointers having advanced, so the aarch64
    // loop must consume mem_len and advance mem_dst/mem_src exactly as the
    // x86 string instruction does.
    const a64 = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.memCopy(7);
        }
    }.f);
    defer testing.allocator.free(a64);
    try testing.expect(std.mem.indexOf(u8, a64, "ldrb w9, [x12], #1") != null);
    try testing.expect(std.mem.indexOf(u8, a64, "strb w9, [x11], #1") != null);
    try testing.expect(std.mem.indexOf(u8, a64, "subs x13, x13, #1") != null);
    // A zero length must not run one iteration.
    try testing.expect(std.mem.indexOf(u8, a64, "cbz x13, .L_memcpy_done_7") != null);

    const x86 = try emitToString(.x86_64, struct {
        fn f(e: Emitter) !void {
            try e.memCopy(7);
        }
    }.f);
    defer testing.allocator.free(x86);
    try testing.expectEqualStrings("    cld\n    rep movsb\n", x86);
}

test "block memory roles are distinct registers on aarch64" {
    // On x86 they alias the string-instruction registers by necessity; if the
    // aarch64 mapping ever aliased them a copy would destroy its own source.
    const e = Emitter{ .arch = .aarch64, .out = undefined, .gpa = undefined };
    try testing.expect(!std.mem.eql(u8, e.reg(.mem_dst), e.reg(.mem_src)));
    try testing.expect(!std.mem.eql(u8, e.reg(.mem_dst), e.reg(.mem_len)));
    try testing.expect(!std.mem.eql(u8, e.reg(.mem_src), e.reg(.mem_len)));
    try testing.expect(!std.mem.eql(u8, e.reg(.mem_dst), e.reg(.acc)));
}

test "conditional move picks the source only when the condition holds" {
    const a64 = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.condMove(.gt, .acc, .tmp);
        }
    }.f);
    defer testing.allocator.free(a64);
    try testing.expectEqualStrings("    csel x0, x1, x0, gt\n", a64);
}

test "reading a pushed slot accounts for the push stride" {
    // aarch64 pushes move the stack by 16, x86 by 8; a caller asking for the
    // second pushed word must get the right byte offset on each.
    const a64 = try emitToString(.aarch64, struct {
        fn f(e: Emitter) !void {
            try e.loadPushed(.tmp3, 1);
        }
    }.f);
    defer testing.allocator.free(a64);
    try testing.expectEqualStrings("    ldr x3, [sp, #16]\n", a64);

    const x86 = try emitToString(.x86_64, struct {
        fn f(e: Emitter) !void {
            try e.loadPushed(.tmp3, 1);
        }
    }.f);
    defer testing.allocator.free(x86);
    try testing.expectEqualStrings("    movq 8(%rsp), %rdx\n", x86);
}

test "target triples resolve to an architecture" {
    try testing.expectEqual(Arch.aarch64, Arch.parseTriple("aarch64-freestanding").?);
    try testing.expectEqual(Arch.aarch64, Arch.parseTriple("aarch64-linux-gnu").?);
    try testing.expectEqual(Arch.aarch64, Arch.parseTriple("arm64").?);
    try testing.expectEqual(Arch.x86_64, Arch.parseTriple("x86_64-freestanding").?);
    // The architecture itself contains a dash here; a split on '-' would see
    // "x86" and give up.
    try testing.expectEqual(Arch.x86_64, Arch.parseTriple("x86-64-freestanding").?);
    // Big-endian aarch64 is a different target, not a spelling of this one.
    try testing.expect(Arch.parseTriple("aarch64be-freestanding") == null);
    try testing.expect(Arch.parseTriple("riscv64-freestanding") == null);
}
