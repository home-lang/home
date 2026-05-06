const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ast = @import("ast");
const arm64 = @import("arm64.zig");
const macho = @import("macho.zig");

/// AArch64 native codegen — Path B-lite of issue #5.
///
/// Mirrors the structure of `native_codegen.NativeCodegen` but emits arm64
/// machine code via `arm64.Assembler`. Currently supports the M3 subset:
///   - top-level `FnDecl` named `main` (other functions still NotImplemented)
///   - `LetDecl` (immutable; `is_static` not supported)
///   - `IfStmt` with optional else
///   - `ReturnStmt`
///   - integer + boolean literals, identifier reads
///   - binary expressions: `+ - * /`, `== != < <= > >=`
///
/// Other AST nodes return `error.NotImplemented`. The plan is to expand
/// this milestone-by-milestone (M4 = loops, M5 = function calls, …) per
/// the B-lite roadmap rather than refactoring NativeCodegen itself.
pub const CodegenError = error{
    NotImplemented,
    UnsupportedPlatform,
    IntegerLiteralOutOfRange,
    UndefinedIdentifier,
    FrameTooLarge,
    InvalidOffset,
    FileSystemAccessDenied,
} || std.mem.Allocator.Error;

pub const Aarch64NativeCodegen = struct {
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    assembler: arm64.Assembler,
    functions: std.StringHashMap(usize),
    current_function_name: ?[]const u8 = null,
    io: ?Io = null,

    /// Locals → byte offset from SP at prologue end. All locals are 8 bytes
    /// (i64) for now. Cleared between functions.
    locals: std.StringHashMap(u32),
    /// Bytes pushed beyond the stable frame during expression evaluation.
    /// Used to fix up SP-relative local addresses while a binary expression
    /// has spilled an intermediate result. Always returns to 0 at statement
    /// boundaries.
    stack_delta: u32 = 0,
    /// Current function's local frame size (bytes, 16-aligned). 0 outside a
    /// function.
    frame_size: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) Aarch64NativeCodegen {
        return .{
            .allocator = allocator,
            .program = program,
            .assembler = arm64.Assembler.init(allocator),
            .functions = std.StringHashMap(usize).init(allocator),
            .locals = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *Aarch64NativeCodegen) void {
        self.assembler.deinit();
        self.functions.deinit();
        self.locals.deinit();
    }

    pub fn writeExecutable(self: *Aarch64NativeCodegen, path: []const u8) !void {
        for (self.program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        const code = self.assembler.code.items;
        const data: []const u8 = &.{};
        const main_offset = self.functions.get("main") orelse 0;

        switch (builtin.os.tag) {
            .macos => {
                var writer = macho.MachOWriter.initArm64(self.allocator, code, data);
                writer.io = self.io;
                try writer.writeWithEntryPoint(path, main_offset);
            },
            .linux => {
                // M1.5 — arm64 ELF (EM_AARCH64 = 0xB7) not yet wired.
                return error.UnsupportedPlatform;
            },
            else => return error.UnsupportedPlatform,
        }
    }

    fn generateStmt(self: *Aarch64NativeCodegen, stmt: ast.Stmt) CodegenError!void {
        switch (stmt) {
            .FnDecl => |func| try self.generateFnDecl(func),
            .LetDecl => |decl| try self.generateLetDecl(decl),
            .IfStmt => |if_stmt| try self.generateIfStmt(if_stmt),
            .ReturnStmt => |ret| try self.generateReturn(ret),
            .ExprStmt => |expr| try self.generateExpr(expr),
            else => return error.NotImplemented,
        }
    }

    fn generateIfStmt(self: *Aarch64NativeCodegen, if_stmt: *ast.IfStmt) CodegenError!void {
        // Evaluate condition into x0 (1 = true, 0 = false).
        try self.generateExpr(if_stmt.condition);
        // Compare against 0; B.EQ jumps to else / end if condition is false.
        try self.assembler.cmpRegImm(.x0, 0);

        const skip_then_pos = self.assembler.getPosition();
        try self.assembler.bcond(.eq, 0); // placeholder, patched below

        // Then block.
        for (if_stmt.then_block.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        if (if_stmt.else_block) |else_block| {
            // After the then block, branch unconditionally over the else block.
            const skip_else_pos = self.assembler.getPosition();
            try self.assembler.b(0); // placeholder

            // Patch the b.eq to land here (start of else).
            try self.assembler.patchBcond(skip_then_pos, .eq, self.assembler.getPosition());

            for (else_block.statements) |stmt| {
                try self.generateStmt(stmt);
            }

            // Patch the unconditional jump to land after the else block.
            try self.assembler.patchB(skip_else_pos, self.assembler.getPosition());
        } else {
            // No else: b.eq lands here (just past the then block).
            try self.assembler.patchBcond(skip_then_pos, .eq, self.assembler.getPosition());
        }
    }

    fn generateFnDecl(self: *Aarch64NativeCodegen, func: *ast.FnDecl) CodegenError!void {
        const offset = self.assembler.getPosition();
        try self.functions.put(func.name, offset);

        const prev_name = self.current_function_name;
        self.current_function_name = func.name;
        defer self.current_function_name = prev_name;

        // Reset per-function state.
        self.locals.clearRetainingCapacity();
        self.stack_delta = 0;

        // Pre-pass: count `let` bindings reachable from this function's body
        // (including those nested in if/else branches) to size the frame.
        // We over-allocate when branches are mutually exclusive — that's a
        // known limitation; an optimal allocator can reuse slots later.
        const local_count: u32 = countLetDeclsInBlock(func.body);
        const raw_frame: u32 = local_count * 8;
        self.frame_size = std.mem.alignForward(u32, raw_frame, 16);
        if (self.frame_size > 4095) return error.FrameTooLarge; // single ADD/SUB imm12

        // Prologue: save FP/LR (uniformly, even for `main` — exit syscall
        // never returns so nothing reads them, but it keeps the layout
        // consistent and lets us use SP-relative locals directly).
        try self.assembler.functionPrologue();
        if (self.frame_size > 0) {
            try self.assembler.subRegImm(.sp, .sp, @intCast(self.frame_size));
        }

        for (func.body.statements) |stmt| {
            try self.generateStmt(stmt);
        }
    }

    fn generateLetDecl(self: *Aarch64NativeCodegen, decl: *ast.LetDecl) CodegenError!void {
        if (decl.is_static) return error.NotImplemented;

        if (decl.value) |value| {
            try self.generateExpr(value);
        } else {
            try self.assembler.movRegImm64(.x0, 0);
        }

        const slot: u32 = @intCast(self.locals.count() * 8);
        try self.locals.put(decl.name, slot);

        // delta is 0 here — top-level statement, no expr in flight.
        try self.assembler.strRegMem(.x0, .sp, @intCast(slot));
    }

    fn generateReturn(self: *Aarch64NativeCodegen, ret: *ast.ReturnStmt) CodegenError!void {
        if (ret.value) |value| {
            try self.generateExpr(value); // result lands in x0
        } else {
            try self.assembler.movRegImm64(.x0, 0);
        }

        const is_main = if (self.current_function_name) |name|
            std.mem.eql(u8, name, "main")
        else
            false;

        if (is_main) {
            // x0 already holds the exit code; issue the OS-specific exit syscall.
            // No need to tear down the stack frame — the syscall doesn't return.
            switch (builtin.os.tag) {
                .macos => {
                    // macOS-arm64 BSD exit: x16 = 1 (SYS_exit), svc #0x80.
                    try self.assembler.movRegImm64(.x16, 1);
                    try self.assembler.svc(0x80);
                },
                .linux => {
                    // Linux-aarch64 exit: x8 = 93 (__NR_exit), svc #0.
                    try self.assembler.movRegImm64(.x8, 93);
                    try self.assembler.svc(0);
                },
                else => return error.UnsupportedPlatform,
            }
        } else {
            // Tear down locals frame, then standard epilogue.
            if (self.frame_size > 0) {
                try self.assembler.addRegImm(.sp, .sp, @intCast(self.frame_size));
            }
            try self.assembler.functionEpilogue();
        }
    }

    fn generateExpr(self: *Aarch64NativeCodegen, expr: *ast.Expr) CodegenError!void {
        switch (expr.*) {
            .IntegerLiteral => |lit| {
                if (lit.value > std.math.maxInt(i64) or lit.value < std.math.minInt(i64)) {
                    return error.IntegerLiteralOutOfRange;
                }
                const v: i64 = @intCast(lit.value);
                try self.assembler.movRegImm64(.x0, v);
            },
            .BooleanLiteral => |lit| {
                try self.assembler.movRegImm64(.x0, if (lit.value) 1 else 0);
            },
            .Identifier => |ident| {
                const base = self.locals.get(ident.name) orelse return error.UndefinedIdentifier;
                const offset: u32 = base + self.stack_delta;
                try self.assembler.ldrRegMem(.x0, .sp, @intCast(offset));
            },
            .BinaryExpr => |bin| try self.generateBinaryExpr(bin),
            else => return error.NotImplemented,
        }
    }

    fn generateBinaryExpr(self: *Aarch64NativeCodegen, bin: *ast.BinaryExpr) CodegenError!void {
        // Evaluate lhs, spill to stack, evaluate rhs, pop lhs into x1, op.
        try self.generateExpr(bin.left);
        try self.assembler.pushReg(.x0);
        self.stack_delta += 16;

        try self.generateExpr(bin.right);

        try self.assembler.popReg(.x1);
        self.stack_delta -= 16;

        // `op` is `dst, lhs, rhs` on arm64; lhs is in x1, rhs is in x0.
        switch (bin.op) {
            .Add => try self.assembler.addRegReg(.x0, .x1, .x0),
            .Sub => try self.assembler.subRegReg(.x0, .x1, .x0),
            .Mul => try self.assembler.mulRegReg(.x0, .x1, .x0),
            .Div, .IntDiv => try self.assembler.divRegReg(.x0, .x1, .x0),

            // Comparisons: cmp x1, x0  →  cset x0, <cond>.
            .Equal => try self.emitCompare(.eq),
            .NotEqual => try self.emitCompare(.ne),
            .Less => try self.emitCompare(.lt),
            .LessEq => try self.emitCompare(.le),
            .Greater => try self.emitCompare(.gt),
            .GreaterEq => try self.emitCompare(.ge),

            else => return error.NotImplemented,
        }
    }

    fn emitCompare(self: *Aarch64NativeCodegen, cond: arm64.Assembler.Cond) !void {
        try self.assembler.cmpRegReg(.x1, .x0);
        try self.assembler.cset(.x0, cond);
    }
};

/// Recursively count `let` bindings reachable from a block. Branches of an
/// if/else are summed (over-allocates when branches are mutually exclusive,
/// which is fine for now).
fn countLetDeclsInBlock(block: *const ast.BlockStmt) u32 {
    var count: u32 = 0;
    for (block.statements) |stmt| {
        count += countLetDeclsInStmt(stmt);
    }
    return count;
}

fn countLetDeclsInStmt(stmt: ast.Stmt) u32 {
    return switch (stmt) {
        .LetDecl => 1,
        .IfStmt => |if_stmt| blk: {
            var c = countLetDeclsInBlock(if_stmt.then_block);
            if (if_stmt.else_block) |eb| c += countLetDeclsInBlock(eb);
            break :blk c;
        },
        else => 0,
    };
}
