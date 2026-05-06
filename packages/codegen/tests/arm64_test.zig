const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const codegen = @import("codegen");

// ─── Smoke tests (mirror the x64 codegen_test.zig surface) ──────────────────

test "arm64: assembler creation" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try testing.expectEqual(@as(usize, 0), assembler.getPosition());
}

test "arm64: emit push instruction" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.pushReg(.x0);
    try testing.expectEqual(@as(usize, 4), assembler.getPosition());
}

test "arm64: emit pop instruction" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.popReg(.x0);
    try testing.expectEqual(@as(usize, 4), assembler.getPosition());
}

test "arm64: emit mov register to register" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.movRegReg(.x0, .x1);
    try testing.expectEqual(@as(usize, 4), assembler.getPosition());
}

test "arm64: emit mov immediate to register" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.movRegImm64(.x0, 42);
    try testing.expectEqual(@as(usize, 4), assembler.getPosition());
}

test "arm64: emit svc (syscall)" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.svc(0);
    try testing.expectEqual(@as(usize, 4), assembler.getPosition());
}

test "arm64: emit eor (xor) register to register" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.eorRegReg(.x0, .x0, .x0);
    try testing.expectEqual(@as(usize, 4), assembler.getPosition());
}

test "arm64: emit add register to register" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.addRegReg(.x0, .x1, .x2);
    try testing.expectEqual(@as(usize, 4), assembler.getPosition());
}

test "arm64: emit sub register from register" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.subRegReg(.x0, .x1, .x2);
    try testing.expectEqual(@as(usize, 4), assembler.getPosition());
}

test "arm64: emit return instruction" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.ret();
    try testing.expectEqual(@as(usize, 4), assembler.getPosition());
}

test "arm64: function prologue pattern" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.functionPrologue();
    // stp x29,x30,[sp,#-16]!  +  add x29,sp,#0  → 8 bytes
    try testing.expectEqual(@as(usize, 8), assembler.getPosition());
}

test "arm64: function epilogue pattern" {
    const allocator = testing.allocator;

    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.functionEpilogue();
    // ldp x29,x30,[sp],#16  +  ret  → 8 bytes
    try testing.expectEqual(@as(usize, 8), assembler.getPosition());
}

// ─── Byte-level encoding tests ──────────────────────────────────────────────
// Each expected byte sequence was hand-derived from the ARM ARM (ARMv8-A
// reference manual) and double-checked against the canonical assembler
// output for the named instruction. AArch64 is little-endian, so a 32-bit
// instruction word 0xAABBCCDD is stored as { 0xDD, 0xCC, 0xBB, 0xAA }.

fn assertEncoding(
    expected: []const u8,
    emit: fn (*codegen.arm64.Assembler) anyerror!void,
) !void {
    const allocator = testing.allocator;
    var asm_ = codegen.arm64.Assembler.init(allocator);
    defer asm_.deinit();
    try emit(&asm_);
    try testing.expectEqualSlices(u8, expected, asm_.code.items);
}

test "arm64 encoding: movz x0, #42" {
    // MOVZ X0, #42 → 0xD2800540
    try assertEncoding(&.{ 0x40, 0x05, 0x80, 0xD2 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.movRegImm64(.x0, 42);
        }
    }.f);
}

test "arm64 encoding: mov x0, x1" {
    // ORR X0, XZR, X1 → 0xAA0103E0
    try assertEncoding(&.{ 0xE0, 0x03, 0x01, 0xAA }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.movRegReg(.x0, .x1);
        }
    }.f);
}

test "arm64 encoding: add x0, x1, x2" {
    // 0x8B020020
    try assertEncoding(&.{ 0x20, 0x00, 0x02, 0x8B }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.addRegReg(.x0, .x1, .x2);
        }
    }.f);
}

test "arm64 encoding: sub x0, x1, x2" {
    // 0xCB020020
    try assertEncoding(&.{ 0x20, 0x00, 0x02, 0xCB }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.subRegReg(.x0, .x1, .x2);
        }
    }.f);
}

test "arm64 encoding: mul x0, x1, x2" {
    // MADD X0, X1, X2, XZR → 0x9B027C20
    try assertEncoding(&.{ 0x20, 0x7C, 0x02, 0x9B }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.mulRegReg(.x0, .x1, .x2);
        }
    }.f);
}

test "arm64 encoding: sdiv x0, x1, x2" {
    // 0x9AC20C20
    try assertEncoding(&.{ 0x20, 0x0C, 0xC2, 0x9A }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.divRegReg(.x0, .x1, .x2);
        }
    }.f);
}

test "arm64 encoding: cmp x1, x2" {
    // SUBS XZR, X1, X2 → 0xEB02003F
    try assertEncoding(&.{ 0x3F, 0x00, 0x02, 0xEB }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.cmpRegReg(.x1, .x2);
        }
    }.f);
}

test "arm64 encoding: ret" {
    // 0xD65F03C0
    try assertEncoding(&.{ 0xC0, 0x03, 0x5F, 0xD6 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.ret();
        }
    }.f);
}

test "arm64 encoding: nop" {
    // 0xD503201F
    try assertEncoding(&.{ 0x1F, 0x20, 0x03, 0xD5 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.nop();
        }
    }.f);
}

test "arm64 encoding: ldr x0, [x1, #16]" {
    // 0xF9400820
    try assertEncoding(&.{ 0x20, 0x08, 0x40, 0xF9 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.ldrRegMem(.x0, .x1, 16);
        }
    }.f);
}

test "arm64 encoding: str x0, [x1, #16]" {
    // 0xF9000820
    try assertEncoding(&.{ 0x20, 0x08, 0x00, 0xF9 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.strRegMem(.x0, .x1, 16);
        }
    }.f);
}

test "arm64 encoding: stp x29, x30, [sp, #-16]!" {
    // Canonical AArch64 prologue STP → 0xA9BF7BFD
    try assertEncoding(&.{ 0xFD, 0x7B, 0xBF, 0xA9 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.stpPreIndex(.x29, .x30, .sp, -16);
        }
    }.f);
}

test "arm64 encoding: ldp x29, x30, [sp], #16" {
    // Canonical AArch64 epilogue LDP → 0xA8C17BFD
    try assertEncoding(&.{ 0xFD, 0x7B, 0xC1, 0xA8 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.ldpPostIndex(.x29, .x30, .sp, 16);
        }
    }.f);
}

test "arm64 encoding: b.eq +0" {
    // 0x54000000
    try assertEncoding(&.{ 0x00, 0x00, 0x00, 0x54 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.beq(0);
        }
    }.f);
}

test "arm64 encoding: b +0" {
    // 0x14000000
    try assertEncoding(&.{ 0x00, 0x00, 0x00, 0x14 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.b(0);
        }
    }.f);
}

test "arm64 encoding: bl +0" {
    // 0x94000000
    try assertEncoding(&.{ 0x00, 0x00, 0x00, 0x94 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.bl(0);
        }
    }.f);
}

test "arm64 encoding: svc #0" {
    // 0xD4000001
    try assertEncoding(&.{ 0x01, 0x00, 0x00, 0xD4 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.svc(0);
        }
    }.f);
}

test "arm64 encoding: add x0, x1, #4" {
    // 0x91001020
    try assertEncoding(&.{ 0x20, 0x10, 0x00, 0x91 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.addRegImm(.x0, .x1, 4);
        }
    }.f);
}

test "arm64 encoding: sub x0, x1, #4" {
    // 0xD1001020
    try assertEncoding(&.{ 0x20, 0x10, 0x00, 0xD1 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.subRegImm(.x0, .x1, 4);
        }
    }.f);
}

test "arm64 encoding: cmp x0, #5" {
    // SUBS XZR, X0, #5 → 0xF100141F
    try assertEncoding(&.{ 0x1F, 0x14, 0x00, 0xF1 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.cmpRegImm(.x0, 5);
        }
    }.f);
}

test "arm64 encoding: neg x0, x1" {
    // SUB X0, XZR, X1 → 0xCB0103E0
    try assertEncoding(&.{ 0xE0, 0x03, 0x01, 0xCB }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.negReg(.x0, .x1);
        }
    }.f);
}

test "arm64 encoding: and x0, x1, x2" {
    // 0x8A020020
    try assertEncoding(&.{ 0x20, 0x00, 0x02, 0x8A }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.andRegReg(.x0, .x1, .x2);
        }
    }.f);
}

test "arm64 encoding: orr x0, x1, x2" {
    // 0xAA020020
    try assertEncoding(&.{ 0x20, 0x00, 0x02, 0xAA }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.orrRegReg(.x0, .x1, .x2);
        }
    }.f);
}

test "arm64 encoding: eor x0, x1, x2" {
    // 0xCA020020
    try assertEncoding(&.{ 0x20, 0x00, 0x02, 0xCA }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.eorRegReg(.x0, .x1, .x2);
        }
    }.f);
}

test "arm64 encoding: lsl x0, x1, #1" {
    // UBFM X0, X1, #63, #62 → 0xD37FF820
    try assertEncoding(&.{ 0x20, 0xF8, 0x7F, 0xD3 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.lslRegImm(.x0, .x1, 1);
        }
    }.f);
}

test "arm64 encoding: lsr x0, x1, #1" {
    // UBFM X0, X1, #1, #63 → 0xD341FC20
    try assertEncoding(&.{ 0x20, 0xFC, 0x41, 0xD3 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.lsrRegImm(.x0, .x1, 1);
        }
    }.f);
}

test "arm64 encoding: asr x0, x1, #1" {
    // SBFM X0, X1, #1, #63 → 0x9341FC20
    try assertEncoding(&.{ 0x20, 0xFC, 0x41, 0x93 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.asrRegImm(.x0, .x1, 1);
        }
    }.f);
}

test "arm64 encoding: push x0 (str x0, [sp, #-16]!)" {
    // 0xF81F0FE0
    try assertEncoding(&.{ 0xE0, 0x0F, 0x1F, 0xF8 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.pushReg(.x0);
        }
    }.f);
}

test "arm64 encoding: pop x0 (ldr x0, [sp], #16)" {
    // 0xF84107E0
    try assertEncoding(&.{ 0xE0, 0x07, 0x41, 0xF8 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.popReg(.x0);
        }
    }.f);
}

test "arm64 encoding: function prologue" {
    // stp x29,x30,[sp,#-16]!  → 0xA9BF7BFD
    // add x29,sp,#0           → 0x910003FD  (canonical "mov x29, sp")
    try assertEncoding(&.{
        0xFD, 0x7B, 0xBF, 0xA9,
        0xFD, 0x03, 0x00, 0x91,
    }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.functionPrologue();
        }
    }.f);
}

test "arm64 encoding: function epilogue" {
    // ldp x29,x30,[sp],#16    → 0xA8C17BFD
    // ret                      → 0xD65F03C0
    try assertEncoding(&.{
        0xFD, 0x7B, 0xC1, 0xA8,
        0xC0, 0x03, 0x5F, 0xD6,
    }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.functionEpilogue();
        }
    }.f);
}

fn assertBcond(cond: codegen.arm64.Assembler.Cond, expected: [4]u8) !void {
    const allocator = testing.allocator;
    var asm_ = codegen.arm64.Assembler.init(allocator);
    defer asm_.deinit();
    try asm_.bcond(cond, 0);
    try testing.expectEqualSlices(u8, expected[0..], asm_.code.items);
}

test "arm64 encoding: b.eq via bcond" {
    try assertBcond(.eq, .{ 0x00, 0x00, 0x00, 0x54 });
}
test "arm64 encoding: b.ne via bcond" {
    try assertBcond(.ne, .{ 0x01, 0x00, 0x00, 0x54 });
}
test "arm64 encoding: b.lt via bcond" {
    try assertBcond(.lt, .{ 0x0B, 0x00, 0x00, 0x54 });
}
test "arm64 encoding: b.gt via bcond" {
    try assertBcond(.gt, .{ 0x0C, 0x00, 0x00, 0x54 });
}
test "arm64 encoding: b.le via bcond" {
    try assertBcond(.le, .{ 0x0D, 0x00, 0x00, 0x54 });
}
test "arm64 encoding: b.ge via bcond" {
    try assertBcond(.ge, .{ 0x0A, 0x00, 0x00, 0x54 });
}

// ─── Encoders added during M3-M8 ────────────────────────────────────────────
// CSET (M3), patchBl (M5), ADR + patchAdr (M6), and the LDR/STR register-
// offset LSL #3 forms (M8) all landed in earlier milestones without
// byte-level tests. Backfilled here so the assembler's full surface is
// covered.

test "arm64 encoding: cset x0, eq" {
    // CSINC X0, XZR, XZR, ne  (CSET inverts the low bit of the condition).
    // 0x9A9F07E0 | (1 << 12) = 0x9A9F17E0
    try assertEncoding(&.{ 0xE0, 0x17, 0x9F, 0x9A }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.cset(.x0, .eq);
        }
    }.f);
}

test "arm64 encoding: cset x0, ne" {
    // CSINC X0, XZR, XZR, eq → 0x9A9F07E0
    try assertEncoding(&.{ 0xE0, 0x07, 0x9F, 0x9A }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.cset(.x0, .ne);
        }
    }.f);
}

test "arm64 encoding: cset x0, gt" {
    // CSINC X0, XZR, XZR, le → 0x9A9F07E0 | (0xD << 12) = 0x9A9FD7E0
    try assertEncoding(&.{ 0xE0, 0xD7, 0x9F, 0x9A }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.cset(.x0, .gt);
        }
    }.f);
}

test "arm64 encoding: cset x0, lt" {
    // CSINC X0, XZR, XZR, ge → 0x9A9F07E0 | (0xA << 12) = 0x9A9FA7E0
    try assertEncoding(&.{ 0xE0, 0xA7, 0x9F, 0x9A }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.cset(.x0, .lt);
        }
    }.f);
}

test "arm64 encoding: adr x1, +0" {
    // 0x10000001
    try assertEncoding(&.{ 0x01, 0x00, 0x00, 0x10 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.adr(.x1, 0);
        }
    }.f);
}

test "arm64 encoding: adr x1, +12" {
    // imm21=12 → immlo=0, immhi=3 → 0x10000000 | (3<<5) | 1 = 0x10000061
    try assertEncoding(&.{ 0x61, 0x00, 0x00, 0x10 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.adr(.x1, 12);
        }
    }.f);
}

test "arm64 encoding: adr x1, -4" {
    // imm21=-4 (21-bit two's complement = 0x1FFFFC) → immlo=0, immhi=0x7FFFF
    // 0x10000000 | (0x7FFFF << 5) | 1 = 0x10FFFFE1
    try assertEncoding(&.{ 0xE1, 0xFF, 0xFF, 0x10 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.adr(.x1, -4);
        }
    }.f);
}

test "arm64 encoding: ldr x0, [sp, x1, LSL #3]" {
    // 0xF8607800 | (1<<16) | (31<<5) | 0 = 0xF8617BE0
    try assertEncoding(&.{ 0xE0, 0x7B, 0x61, 0xF8 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.ldrRegRegLsl3(.x0, .sp, .x1);
        }
    }.f);
}

test "arm64 encoding: ldr x2, [x0, x1, LSL #3]" {
    // 0xF8607800 | (1<<16) | (0<<5) | 2 = 0xF8617802
    try assertEncoding(&.{ 0x02, 0x78, 0x61, 0xF8 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.ldrRegRegLsl3(.x2, .x0, .x1);
        }
    }.f);
}

test "arm64 encoding: str x0, [sp, x1, LSL #3]" {
    // 0xF8207800 | (1<<16) | (31<<5) | 0 = 0xF8217BE0
    try assertEncoding(&.{ 0xE0, 0x7B, 0x21, 0xF8 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.strRegRegLsl3(.x0, .sp, .x1);
        }
    }.f);
}

test "arm64 encoding: str x2, [x0, x1, LSL #3]" {
    // 0xF8207800 | (1<<16) | (0<<5) | 2 = 0xF8217802
    try assertEncoding(&.{ 0x02, 0x78, 0x21, 0xF8 }, struct {
        fn f(a: *codegen.arm64.Assembler) anyerror!void {
            try a.strRegRegLsl3(.x2, .x0, .x1);
        }
    }.f);
}

test "arm64 encoding: patchBl rewrites bl offset" {
    // Emit `bl 0`, then patchBl to retarget. Read back the rewritten 4 bytes.
    const allocator = testing.allocator;
    var asm_ = codegen.arm64.Assembler.init(allocator);
    defer asm_.deinit();

    try asm_.bl(0); // emits 0x94000000 → bytes 00 00 00 94
    // Patch position 0 → target 8: offset = 8 - 0 = 8, imm26 = 2
    // 0x94000000 | 2 = 0x94000002 → bytes 02 00 00 94
    try asm_.patchBl(0, 8);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x00, 0x00, 0x94 }, asm_.code.items);
}

test "arm64 encoding: patchAdr rewrites adr offset" {
    // Emit `adr x1, 0`, then patchAdr to retarget. Verify bytes update.
    const allocator = testing.allocator;
    var asm_ = codegen.arm64.Assembler.init(allocator);
    defer asm_.deinit();

    try asm_.adr(.x1, 0); // 0x10000001 → bytes 01 00 00 10
    // Patch position 0 → target 8 for x1: offset = 8 - 0 = 8
    // imm21=8 → immlo=0, immhi=2 → 0x10000000 | (2<<5) | 1 = 0x10000041
    try asm_.patchAdr(0, .x1, 8);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x00, 0x00, 0x10 }, asm_.code.items);
}

// ─── JIT smoke test (aarch64 host only) ─────────────────────────────────────
// Emits a tiny `fn () -> i64 { return 42; }` function, marks it executable,
// flushes the I-cache, and calls it. Confirms our encodings actually decode
// correctly on real silicon — not just match an offline byte table.
//
// macOS arm64 requires MAP_JIT + pthread_jit_write_protect_np to flip the
// JIT memory between writable and executable. Linux aarch64 just needs RWX
// pages plus an explicit I-cache flush.

const aarch64_macos = builtin.target.cpu.arch == .aarch64 and builtin.target.os.tag == .macos;
const aarch64_linux = builtin.target.cpu.arch == .aarch64 and builtin.target.os.tag == .linux;

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: ?*anyopaque, len: usize) void;

test "arm64 JIT: emit and run `return 42` on aarch64 host" {
    if (!aarch64_macos and !aarch64_linux) return error.SkipZigTest;

    const allocator = testing.allocator;
    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    // mov x0, #42  ;  ret
    try assembler.movRegImm64(.x0, 42);
    try assembler.ret();

    const code = assembler.code.items;
    try testing.expectEqual(@as(usize, 8), code.len);

    const page_size: usize = 16 * 1024; // arm64-macos uses 16 KiB pages

    if (aarch64_macos) {
        const mem = std.c.mmap(
            null,
            page_size,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true },
            -1,
            0,
        );
        if (@intFromPtr(mem) == @as(usize, @bitCast(@as(isize, -1)))) {
            return error.SkipZigTest; // MAP_JIT unavailable on this host config
        }
        defer _ = std.c.munmap(@ptrCast(@alignCast(mem)), page_size);

        pthread_jit_write_protect_np(0); // make writable
        @memcpy(@as([*]u8, @ptrCast(@alignCast(mem)))[0..code.len], code);
        pthread_jit_write_protect_np(1); // make executable
        sys_icache_invalidate(@ptrCast(@alignCast(mem)), code.len);

        const f: *const fn () callconv(.c) i64 = @ptrCast(@alignCast(mem));
        try testing.expectEqual(@as(i64, 42), f());
    } else if (aarch64_linux) {
        const mem = try std.posix.mmap(
            null,
            page_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        defer std.posix.munmap(mem);

        @memcpy(mem[0..code.len], code);
        // Flush I-cache so the CPU actually sees our freshly-written instructions.
        asm volatile ("dsb ish" ::: "memory");
        asm volatile ("isb" ::: "memory");

        const f: *const fn () callconv(.c) i64 = @ptrCast(@alignCast(mem.ptr));
        try testing.expectEqual(@as(i64, 42), f());
    }
}

test "arm64 JIT: add immediate then return on aarch64 host" {
    if (!aarch64_macos and !aarch64_linux) return error.SkipZigTest;

    const allocator = testing.allocator;
    var assembler = codegen.arm64.Assembler.init(allocator);
    defer assembler.deinit();

    // mov x0, #100  ;  add x0, x0, #23  ;  ret
    try assembler.movRegImm64(.x0, 100);
    try assembler.addRegImm(.x0, .x0, 23);
    try assembler.ret();

    const code = assembler.code.items;
    const page_size: usize = 16 * 1024;

    if (aarch64_macos) {
        const mem = std.c.mmap(
            null,
            page_size,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true },
            -1,
            0,
        );
        if (@intFromPtr(mem) == @as(usize, @bitCast(@as(isize, -1)))) {
            return error.SkipZigTest;
        }
        defer _ = std.c.munmap(@ptrCast(@alignCast(mem)), page_size);

        pthread_jit_write_protect_np(0);
        @memcpy(@as([*]u8, @ptrCast(@alignCast(mem)))[0..code.len], code);
        pthread_jit_write_protect_np(1);
        sys_icache_invalidate(@ptrCast(@alignCast(mem)), code.len);

        const f: *const fn () callconv(.c) i64 = @ptrCast(@alignCast(mem));
        try testing.expectEqual(@as(i64, 123), f());
    } else if (aarch64_linux) {
        const mem = try std.posix.mmap(
            null,
            page_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        defer std.posix.munmap(mem);

        @memcpy(mem[0..code.len], code);
        asm volatile ("dsb ish" ::: "memory");
        asm volatile ("isb" ::: "memory");

        const f: *const fn () callconv(.c) i64 = @ptrCast(@alignCast(mem.ptr));
        try testing.expectEqual(@as(i64, 123), f());
    }
}
