const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ast = @import("ast");
const arm64 = @import("arm64.zig");
const macho = @import("macho.zig");

/// AArch64 native codegen — Path B-lite of issue #5.
///
/// Mirrors the structure of `native_codegen.NativeCodegen` but emits arm64
/// machine code via `arm64.Assembler`. Currently supports the M5 subset:
///   - `FnDecl` (top-level functions, including non-`main`) with up to 8
///     i64 parameters delivered via x0..x7 per AAPCS64
///   - `LetDecl` (mutable or immutable; `is_static` not supported — note
///     mutability isn't enforced, just respected when the source asks for it)
///   - `IfStmt` with optional else
///   - `WhileStmt`
///   - `ReturnStmt`
///   - integer + boolean literals, identifier reads, assignment to identifiers
///   - binary expressions: `+ - * /`, `== != < <= > >=`
///   - call expressions: positional args only, callee must be a bare
///     identifier referencing a function in this program
///
/// Other AST nodes return `error.NotImplemented`. The plan is to expand
/// this milestone-by-milestone (M6 = strings + print, M7 = structs, …) per
/// the B-lite roadmap rather than refactoring NativeCodegen itself.
pub const CodegenError = error{
    NotImplemented,
    UnsupportedPlatform,
    IntegerLiteralOutOfRange,
    UndefinedIdentifier,
    UndefinedFunction,
    TooManyArguments,
    InvalidCallTarget,
    FrameTooLarge,
    InvalidOffset,
    FileSystemAccessDenied,
} || std.mem.Allocator.Error;

const PendingCall = struct {
    /// Byte offset in the assembler buffer where the BL instruction lives.
    pos: usize,
    /// Name of the callee. Borrowed from the AST (Identifier slice), valid
    /// for the lifetime of the program.
    callee: []const u8,
};

pub const Aarch64NativeCodegen = struct {
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    assembler: arm64.Assembler,
    functions: std.StringHashMap(usize),
    current_function_name: ?[]const u8 = null,
    io: ?Io = null,

    /// Locals → byte offset from SP at prologue end. All locals are 8 bytes
    /// (i64) for now. Cleared between functions. Includes function parameters
    /// (which occupy the lowest slots) followed by `let` bindings.
    locals: std.StringHashMap(u32),
    /// Bytes pushed beyond the stable frame during expression evaluation.
    /// Used to fix up SP-relative local addresses while a binary expression
    /// has spilled an intermediate result. Always returns to 0 at statement
    /// boundaries.
    stack_delta: u32 = 0,
    /// Current function's local frame size (bytes, 16-aligned). 0 outside a
    /// function.
    frame_size: u32 = 0,
    /// BL call sites awaiting backpatch once the callee's address is known.
    /// Resolved after every top-level FnDecl has been emitted.
    pending_calls: std.ArrayList(PendingCall),

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) Aarch64NativeCodegen {
        return .{
            .allocator = allocator,
            .program = program,
            .assembler = arm64.Assembler.init(allocator),
            .functions = std.StringHashMap(usize).init(allocator),
            .locals = std.StringHashMap(u32).init(allocator),
            .pending_calls = std.ArrayList(PendingCall).empty,
        };
    }

    pub fn deinit(self: *Aarch64NativeCodegen) void {
        self.assembler.deinit();
        self.functions.deinit();
        self.locals.deinit();
        self.pending_calls.deinit(self.allocator);
    }

    pub fn writeExecutable(self: *Aarch64NativeCodegen, path: []const u8) !void {
        // Two-pass emission to dodge forward-reference pain: first emit every
        // non-main function (so any `bl foo` from main lands on a known
        // address), then emit main last. Calls between non-main functions or
        // recursive calls still need backpatching, handled below.
        for (self.program.statements) |stmt| {
            switch (stmt) {
                .FnDecl => |func| {
                    if (!std.mem.eql(u8, func.name, "main")) {
                        try self.generateStmt(stmt);
                    }
                },
                else => try self.generateStmt(stmt),
            }
        }
        for (self.program.statements) |stmt| {
            switch (stmt) {
                .FnDecl => |func| {
                    if (std.mem.eql(u8, func.name, "main")) {
                        try self.generateStmt(stmt);
                    }
                },
                else => {},
            }
        }

        // Resolve any forward / recursive BL calls now that all addresses
        // are known.
        for (self.pending_calls.items) |pc| {
            const target = self.functions.get(pc.callee) orelse return error.UndefinedFunction;
            try self.assembler.patchBl(pc.pos, target);
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
            .WhileStmt => |while_stmt| try self.generateWhileStmt(while_stmt),
            .ReturnStmt => |ret| try self.generateReturn(ret),
            .ExprStmt => |expr| try self.generateExpr(expr),
            else => return error.NotImplemented,
        }
    }

    fn generateWhileStmt(self: *Aarch64NativeCodegen, while_stmt: *ast.WhileStmt) CodegenError!void {
        // Loop layout:
        //   loop_top:  eval cond → x0
        //              cmp x0, #0
        //              b.eq exit              ; placeholder, patched
        //              <body>
        //              b loop_top             ; backward, computed inline
        //   exit:
        const loop_top = self.assembler.getPosition();

        try self.generateExpr(while_stmt.condition);
        try self.assembler.cmpRegImm(.x0, 0);

        const exit_branch_pos = self.assembler.getPosition();
        try self.assembler.bcond(.eq, 0); // placeholder

        for (while_stmt.body.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Unconditional backward branch to the top of the loop.
        const branch_pos = self.assembler.getPosition();
        const back_offset: i32 = @as(i32, @intCast(loop_top)) - @as(i32, @intCast(branch_pos));
        try self.assembler.b(back_offset);

        // Patch the conditional exit to land just past the back-edge.
        try self.assembler.patchBcond(exit_branch_pos, .eq, self.assembler.getPosition());
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
        if (func.params.len > 8) return error.TooManyArguments; // 9th+ on stack: M-later

        const offset = self.assembler.getPosition();
        try self.functions.put(func.name, offset);

        const prev_name = self.current_function_name;
        self.current_function_name = func.name;
        defer self.current_function_name = prev_name;

        // Reset per-function state.
        self.locals.clearRetainingCapacity();
        self.stack_delta = 0;

        // Pre-pass: count `let` bindings reachable from this function's body
        // (including those nested in if/else and while branches) plus the
        // parameter slots. Over-allocates when if/else branches are mutually
        // exclusive; an optimal allocator can reuse slots later.
        const param_count: u32 = @intCast(func.params.len);
        const let_count: u32 = countLetDeclsInBlock(func.body);
        const raw_frame: u32 = (param_count + let_count) * 8;
        self.frame_size = std.mem.alignForward(u32, raw_frame, 16);
        if (self.frame_size > 4095) return error.FrameTooLarge; // single ADD/SUB imm12

        // Prologue: save FP/LR (uniformly, even for `main` — exit syscall
        // never returns so nothing reads them, but it keeps the layout
        // consistent and lets us use SP-relative locals directly).
        try self.assembler.functionPrologue();
        if (self.frame_size > 0) {
            try self.assembler.subRegImm(.sp, .sp, @intCast(self.frame_size));
        }

        // Spill incoming argument registers (x0..x7) into local slots so
        // subsequent expression eval (which clobbers x0/x1) doesn't lose
        // them. Each parameter occupies one 8-byte slot at the bottom of the
        // frame; the locals map lets identifier reads load them back.
        for (func.params, 0..) |param, i| {
            const slot: u32 = @intCast(i * 8);
            try self.locals.put(param.name, slot);
            try self.assembler.strRegMem(argRegister(i), .sp, @intCast(slot));
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

        // Allocate the next free slot. Since params are inserted first by
        // generateFnDecl, this naturally lands after them.
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
            .AssignmentExpr => |assign| try self.generateAssignment(assign),
            .CallExpr => |call| try self.generateCallExpr(call),
            else => return error.NotImplemented,
        }
    }

    fn generateCallExpr(self: *Aarch64NativeCodegen, call: *ast.CallExpr) CodegenError!void {
        if (call.args.len > 8) return error.TooManyArguments;
        if (call.named_args.len != 0) return error.NotImplemented;

        const callee_name: []const u8 = switch (call.callee.*) {
            .Identifier => |ident| ident.name,
            else => return error.InvalidCallTarget,
        };

        // Evaluate args in source order, spilling each to the stack so later
        // arg evaluation can freely clobber x0/x1. After all are evaluated,
        // pop them in reverse so x0..xN-1 hold args 0..N-1.
        if (call.args.len == 1) {
            // Fast path: only one arg, leave it in x0 directly.
            try self.generateExpr(call.args[0]);
        } else {
            for (call.args) |arg| {
                try self.generateExpr(arg);
                try self.assembler.pushReg(.x0);
                self.stack_delta += 16;
            }
            var i: usize = call.args.len;
            while (i > 0) {
                i -= 1;
                try self.assembler.popReg(argRegister(i));
                self.stack_delta -= 16;
            }
        }

        // Emit BL. If the callee's address is already known, encode it now;
        // otherwise record a pending fixup and emit a placeholder.
        const call_pos = self.assembler.getPosition();
        if (self.functions.get(callee_name)) |target| {
            const back: i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(call_pos));
            try self.assembler.bl(back);
        } else {
            try self.pending_calls.append(self.allocator, .{ .pos = call_pos, .callee = callee_name });
            try self.assembler.bl(0); // placeholder
        }
        // Result is now in x0; nothing more to do.
    }

    fn generateAssignment(self: *Aarch64NativeCodegen, assign: *ast.AssignmentExpr) CodegenError!void {
        // Evaluate value into x0, then store to the target's slot. Only
        // identifier targets are supported in M4 (no IndexExpr / MemberExpr
        // lvalues yet).
        try self.generateExpr(assign.value);

        switch (assign.target.*) {
            .Identifier => |ident| {
                const base = self.locals.get(ident.name) orelse return error.UndefinedIdentifier;
                const offset: u32 = base + self.stack_delta;
                try self.assembler.strRegMem(.x0, .sp, @intCast(offset));
            },
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

/// AAPCS64 argument register for the i-th positional argument (i in 0..7).
fn argRegister(i: usize) arm64.Assembler.Register {
    return switch (i) {
        0 => .x0,
        1 => .x1,
        2 => .x2,
        3 => .x3,
        4 => .x4,
        5 => .x5,
        6 => .x6,
        7 => .x7,
        else => unreachable,
    };
}

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
        .WhileStmt => |while_stmt| countLetDeclsInBlock(while_stmt.body),
        else => 0,
    };
}
