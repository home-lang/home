const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ast = @import("ast");
const arm64 = @import("arm64.zig");
const macho = @import("macho.zig");

/// AArch64 native codegen — Path B-lite of issue #5.
///
/// Mirrors the structure of `native_codegen.NativeCodegen` but emits arm64
/// machine code via `arm64.Assembler`. Currently supports the M7 subset:
///   - `FnDecl` (top-level functions, including non-`main`) with up to 8
///     i64 parameters delivered via x0..x7 per AAPCS64
///   - `StructDecl` (registered into a layout table; emits no code)
///   - `LetDecl` (mutable or immutable; `is_static` not supported — note
///     mutability isn't enforced, just respected when the source asks for it).
///     Both scalar and struct-typed initializers are supported; struct
///     locals occupy N consecutive 8-byte slots.
///   - `IfStmt` with optional else
///   - `WhileStmt`
///   - `ReturnStmt`
///   - integer + boolean literals, identifier reads, assignment to
///     identifiers and struct field assignments
///   - binary expressions: `+ - * /`, `== != < <= > >=`
///   - call expressions: positional args only, callee must be a bare
///     identifier referencing a function in this program
///   - built-in `print(s)` / `println(s)` for string-literal arguments,
///     lowered to the BSD `write` syscall on macOS-arm64
///   - struct field reads (`p.x`) and writes (`p.x = ...`)
///
/// Other AST nodes (pointers, methods, struct args/returns, nested
/// structs, arrays, ...) return `error.NotImplemented`. The plan is to
/// expand this milestone-by-milestone per the B-lite roadmap rather than
/// refactoring NativeCodegen itself.
pub const CodegenError = error{
    NotImplemented,
    UnsupportedPlatform,
    IntegerLiteralOutOfRange,
    UndefinedIdentifier,
    UndefinedFunction,
    UndefinedStruct,
    UndefinedField,
    NotAStructLocal,
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

/// A string literal ready to be appended to the code buffer once function
/// emission is complete. `bytes` is owned by this codegen instance.
const StringLit = struct {
    bytes: []u8,
    /// Offset within the code buffer once appended (filled in just before
    /// patching).
    offset: usize = 0,
};

const StringFixup = struct {
    adr_pos: usize,
    string_index: usize,
};

pub const Aarch64NativeCodegen = struct {
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    assembler: arm64.Assembler,
    functions: std.StringHashMap(usize),
    current_function_name: ?[]const u8 = null,
    io: ?Io = null,

    /// Locals → byte offset from SP at prologue end. All locals are 8 bytes
    /// for scalars; struct locals occupy multiple consecutive slots and the
    /// map stores the offset of slot 0. Cleared between functions. Includes
    /// function parameters (which occupy the lowest slots) followed by `let`
    /// bindings.
    locals: std.StringHashMap(u32),
    /// Local name → struct type name, for locals whose value is a struct.
    /// Used by member expressions to look up field offsets. Cleared between
    /// functions.
    local_struct_types: std.StringHashMap([]const u8),
    /// Next free slot offset (bytes from SP) for the local being allocated.
    /// Reset in generateFnDecl.
    next_slot: u32 = 0,
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
    /// Interned string literals, appended to the code buffer just before
    /// finalising the binary (still inside the __TEXT segment).
    strings: std.ArrayList(StringLit),
    /// ADR instructions that need to be patched once string offsets are known.
    string_fixups: std.ArrayList(StringFixup),
    /// Struct name → AST node. Populated by a pre-pass over the program's
    /// top-level statements before any function body is emitted, so frame
    /// sizing and member expressions can look up sizes and field offsets.
    struct_layouts: std.StringHashMap(*const ast.StructDecl),

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) Aarch64NativeCodegen {
        return .{
            .allocator = allocator,
            .program = program,
            .assembler = arm64.Assembler.init(allocator),
            .functions = std.StringHashMap(usize).init(allocator),
            .locals = std.StringHashMap(u32).init(allocator),
            .local_struct_types = std.StringHashMap([]const u8).init(allocator),
            .pending_calls = std.ArrayList(PendingCall).empty,
            .strings = std.ArrayList(StringLit).empty,
            .string_fixups = std.ArrayList(StringFixup).empty,
            .struct_layouts = std.StringHashMap(*const ast.StructDecl).init(allocator),
        };
    }

    pub fn deinit(self: *Aarch64NativeCodegen) void {
        self.assembler.deinit();
        self.functions.deinit();
        self.locals.deinit();
        self.local_struct_types.deinit();
        self.pending_calls.deinit(self.allocator);
        for (self.strings.items) |str| self.allocator.free(str.bytes);
        self.strings.deinit(self.allocator);
        self.string_fixups.deinit(self.allocator);
        self.struct_layouts.deinit();
    }

    pub fn writeExecutable(self: *Aarch64NativeCodegen, path: []const u8) !void {
        // Pass 0: register every StructDecl so frame sizing and member
        // accesses inside function bodies can look layouts up.
        for (self.program.statements) |stmt| {
            switch (stmt) {
                .StructDecl => |decl| try self.struct_layouts.put(decl.name, decl),
                else => {},
            }
        }

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

        // Append string literals to the code buffer (still inside the
        // __TEXT segment) and patch each ADR fixup with the now-known
        // offset. ADR has a ±1 MiB range — easy reach for the modest
        // programs we currently compile.
        try self.appendStringsAndPatch();

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
            .StructDecl => {}, // registered in writeExecutable's pass 0
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
        self.local_struct_types.clearRetainingCapacity();
        self.stack_delta = 0;
        self.next_slot = 0;

        // Pre-pass: total slot count = parameter slots (1 each, scalar-only
        // for now) + slots required by every reachable `let` binding (1 for
        // scalars, N for struct-typed initializers). Over-allocates when
        // if/else branches are mutually exclusive; an optimal allocator can
        // reuse slots later.
        const param_count: u32 = @intCast(func.params.len);
        const let_slot_count: u32 = countSlotsInBlock(func.body, &self.struct_layouts);
        const raw_frame: u32 = (param_count + let_slot_count) * 8;
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
            self.next_slot = slot + 8;
        }

        for (func.body.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Implicit return-0 / fall-through-ret at the end of the function so
        // bodies that don't end in an explicit `return` still exit cleanly
        // (otherwise control would walk past the function into whatever
        // bytes follow — strings, the next function, etc.).
        const is_main = std.mem.eql(u8, func.name, "main");
        if (is_main) {
            try self.assembler.movRegImm64(.x0, 0);
            switch (builtin.os.tag) {
                .macos => {
                    try self.assembler.movRegImm64(.x16, 1);
                    try self.assembler.svc(0x80);
                },
                .linux => {
                    try self.assembler.movRegImm64(.x8, 93);
                    try self.assembler.svc(0);
                },
                else => return error.UnsupportedPlatform,
            }
        } else {
            if (self.frame_size > 0) {
                try self.assembler.addRegImm(.sp, .sp, @intCast(self.frame_size));
            }
            try self.assembler.functionEpilogue();
        }
    }

    fn generateLetDecl(self: *Aarch64NativeCodegen, decl: *ast.LetDecl) CodegenError!void {
        if (decl.is_static) return error.NotImplemented;

        // Struct-typed initializer: allocate N consecutive slots and write
        // each field into its own slot.
        if (decl.value) |value| {
            if (value.* == .StructLiteral) {
                return self.generateLetStruct(decl.name, value.StructLiteral);
            }
        }

        // Scalar path.
        if (decl.value) |value| {
            try self.generateExpr(value);
        } else {
            try self.assembler.movRegImm64(.x0, 0);
        }

        const slot = self.next_slot;
        self.next_slot += 8;
        try self.locals.put(decl.name, slot);

        // delta is 0 here — top-level statement, no expr in flight.
        try self.assembler.strRegMem(.x0, .sp, @intCast(slot));
    }

    fn generateLetStruct(self: *Aarch64NativeCodegen, name: []const u8, lit: *const ast.StructLiteralExpr) CodegenError!void {
        const sdecl = self.struct_layouts.get(lit.type_name) orelse return error.UndefinedStruct;

        const base_slot = self.next_slot;
        const field_count: u32 = @intCast(sdecl.fields.len);
        self.next_slot += field_count * 8;
        try self.locals.put(name, base_slot);
        try self.local_struct_types.put(name, lit.type_name);

        // Write each field. Each FieldInit's name has to map to one of the
        // declared fields; we look up the offset from the StructDecl and
        // emit a store. Order of evaluation follows source order.
        for (lit.fields) |field| {
            try self.generateExpr(field.value); // x0 = field value
            const offset = fieldOffset(sdecl, field.name) orelse return error.UndefinedField;
            try self.assembler.strRegMem(.x0, .sp, @intCast(base_slot + offset));
        }
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
            .MemberExpr => |member| try self.generateMemberRead(member),
            else => return error.NotImplemented,
        }
    }

    fn generateMemberRead(self: *Aarch64NativeCodegen, member: *ast.MemberExpr) CodegenError!void {
        // M7 only handles the `local.field` shape — `obj.method()` chains,
        // pointer dereference, etc. are M-later.
        const ident = switch (member.object.*) {
            .Identifier => |id| id.name,
            else => return error.NotImplemented,
        };
        const base = self.locals.get(ident) orelse return error.UndefinedIdentifier;
        const struct_name = self.local_struct_types.get(ident) orelse return error.NotAStructLocal;
        const sdecl = self.struct_layouts.get(struct_name) orelse return error.UndefinedStruct;
        const off = fieldOffset(sdecl, member.member) orelse return error.UndefinedField;

        const total: u32 = base + off + self.stack_delta;
        try self.assembler.ldrRegMem(.x0, .sp, @intCast(total));
    }

    fn generateCallExpr(self: *Aarch64NativeCodegen, call: *ast.CallExpr) CodegenError!void {
        if (call.args.len > 8) return error.TooManyArguments;
        if (call.named_args.len != 0) return error.NotImplemented;

        const callee_name: []const u8 = switch (call.callee.*) {
            .Identifier => |ident| ident.name,
            else => return error.InvalidCallTarget,
        };

        // Built-in print/println for string-literal arguments. Anything more
        // ambitious (interpolation, integer arguments, etc.) is M-later.
        if (std.mem.eql(u8, callee_name, "print") or
            std.mem.eql(u8, callee_name, "println"))
        {
            return self.emitPrintBuiltin(call, std.mem.eql(u8, callee_name, "println"));
        }

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
        // Evaluate value into x0, then store to the target's slot. Supports
        // identifier targets and `local.field` member targets.
        try self.generateExpr(assign.value);

        switch (assign.target.*) {
            .Identifier => |ident| {
                const base = self.locals.get(ident.name) orelse return error.UndefinedIdentifier;
                const offset: u32 = base + self.stack_delta;
                try self.assembler.strRegMem(.x0, .sp, @intCast(offset));
            },
            .MemberExpr => |member| {
                const ident = switch (member.object.*) {
                    .Identifier => |id| id.name,
                    else => return error.NotImplemented,
                };
                const base = self.locals.get(ident) orelse return error.UndefinedIdentifier;
                const struct_name = self.local_struct_types.get(ident) orelse return error.NotAStructLocal;
                const sdecl = self.struct_layouts.get(struct_name) orelse return error.UndefinedStruct;
                const off = fieldOffset(sdecl, member.member) orelse return error.UndefinedField;
                const total: u32 = base + off + self.stack_delta;
                try self.assembler.strRegMem(.x0, .sp, @intCast(total));
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

    fn emitPrintBuiltin(self: *Aarch64NativeCodegen, call: *ast.CallExpr, append_newline: bool) CodegenError!void {
        if (call.args.len != 1) return error.NotImplemented;
        const lit = switch (call.args[0].*) {
            .StringLiteral => |s| s,
            else => return error.NotImplemented, // M6 only supports string literals
        };

        // Build the final byte sequence (with optional trailing newline) and
        // intern it. Bytes are owned by this codegen instance and freed in
        // deinit.
        const len_with_nl: usize = lit.value.len + @as(usize, if (append_newline) 1 else 0);
        const owned = try self.allocator.alloc(u8, len_with_nl);
        @memcpy(owned[0..lit.value.len], lit.value);
        if (append_newline) owned[lit.value.len] = '\n';

        const string_index: usize = self.strings.items.len;
        try self.strings.append(self.allocator, .{ .bytes = owned });

        // Emit the syscall sequence:
        //   adr  x1, <string addr>      ; ptr   (patched after string layout)
        //   mov  x0, #1                  ; fd = stdout
        //   mov  x2, #<len>              ; count
        //   mov  x16, #4 / x8, #64       ; SYS_write (Darwin / Linux)
        //   svc  #0x80   / svc #0
        const adr_pos = self.assembler.getPosition();
        try self.assembler.adr(.x1, 0); // placeholder
        try self.string_fixups.append(self.allocator, .{ .adr_pos = adr_pos, .string_index = string_index });

        try self.assembler.movRegImm64(.x0, 1);
        try self.assembler.movRegImm64(.x2, @intCast(len_with_nl));
        switch (builtin.os.tag) {
            .macos => {
                try self.assembler.movRegImm64(.x16, 4);
                try self.assembler.svc(0x80);
            },
            .linux => {
                try self.assembler.movRegImm64(.x8, 64);
                try self.assembler.svc(0);
            },
            else => return error.UnsupportedPlatform,
        }
    }

    /// Append every interned string to the end of the code buffer (still
    /// inside the __TEXT segment) and patch each ADR fixup so callers point
    /// at the right offset.
    fn appendStringsAndPatch(self: *Aarch64NativeCodegen) CodegenError!void {
        if (self.strings.items.len == 0) return;

        // Pad code to 8-byte alignment before string data.
        while (self.assembler.code.items.len % 8 != 0) {
            try self.assembler.code.append(self.assembler.allocator, 0);
        }

        for (self.strings.items) |*str| {
            str.offset = self.assembler.code.items.len;
            try self.assembler.code.appendSlice(self.assembler.allocator, str.bytes);
        }

        for (self.string_fixups.items) |fixup| {
            const target = self.strings.items[fixup.string_index].offset;
            try self.assembler.patchAdr(fixup.adr_pos, .x1, target);
        }
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

/// Recursively count slot-equivalents for `let` bindings reachable from a
/// block. Scalars contribute 1 slot, struct-typed `let`s contribute N slots
/// (where N is the field count). Branches of an if/else are summed
/// (over-allocates when branches are mutually exclusive — fine for now).
fn countSlotsInBlock(block: *const ast.BlockStmt, struct_layouts: *std.StringHashMap(*const ast.StructDecl)) u32 {
    var count: u32 = 0;
    for (block.statements) |stmt| {
        count += countSlotsInStmt(stmt, struct_layouts);
    }
    return count;
}

fn countSlotsInStmt(stmt: ast.Stmt, struct_layouts: *std.StringHashMap(*const ast.StructDecl)) u32 {
    return switch (stmt) {
        .LetDecl => |decl| blk: {
            // Struct-typed initializer? If we know the struct, claim one
            // slot per field; otherwise fall back to one slot.
            if (decl.value) |v| {
                if (v.* == .StructLiteral) {
                    if (struct_layouts.get(v.StructLiteral.type_name)) |sdecl| {
                        break :blk @intCast(sdecl.fields.len);
                    }
                }
            }
            break :blk 1;
        },
        .IfStmt => |if_stmt| blk: {
            var c = countSlotsInBlock(if_stmt.then_block, struct_layouts);
            if (if_stmt.else_block) |eb| c += countSlotsInBlock(eb, struct_layouts);
            break :blk c;
        },
        .WhileStmt => |while_stmt| countSlotsInBlock(while_stmt.body, struct_layouts),
        else => 0,
    };
}

/// Linear search for a field by name; returns its byte offset within the
/// struct (each field is 8 bytes). All fields scalar for now.
fn fieldOffset(decl: *const ast.StructDecl, name: []const u8) ?u32 {
    var offset: u32 = 0;
    for (decl.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return offset;
        offset += 8;
    }
    return null;
}
