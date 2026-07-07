const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ast = @import("ast");
const arm64 = @import("arm64.zig");
const macho = @import("macho.zig");
const elf = @import("elf.zig");

/// AArch64 native codegen — Path B-lite of issue #5.
///
/// Mirrors the structure of `native_codegen.NativeCodegen` but emits arm64
/// machine code via `arm64.Assembler`. Currently supports the M9 subset:
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
///   - fixed-size i64 arrays via `[a, b, c]` literals, indexed read/write
///     (`arr[i]`, `arr[i] = v`)
///   - `match` expressions with integer-literal, boolean-literal, and
///     identifier (wildcard / unbound) arm patterns. Guards, struct/enum/
///     tuple destructuring, and identifier *binding* are M-later.
///
/// Other AST nodes (pointers, methods, struct args/returns, nested
/// structs, slices, dynamic-length arrays, ...) return
/// `error.NotImplemented`. The plan is to expand this milestone-by-milestone
/// per the B-lite roadmap rather than refactoring NativeCodegen itself.
pub const CodegenError = error{
    NotImplemented,
    UnsupportedPlatform,
    IntegerLiteralOutOfRange,
    UndefinedIdentifier,
    UndefinedFunction,
    UndefinedStruct,
    UndefinedField,
    NotAStructLocal,
    NotAnArrayLocal,
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
    /// Local name → array length (in elements). Locals listed here occupy
    /// `length * 8` consecutive bytes starting at their `locals` offset.
    /// Cleared between functions.
    local_array_lens: std.StringHashMap(u32),
    /// Local name → enum type name. Locals listed here are enum-typed.
    /// Bare-tag enums occupy 1 slot (8 bytes — just the tag); enums with
    /// any payload-bearing variant occupy 2 slots (tag at +0, payload at
    /// +8). Cleared between functions.
    local_enum_types: std.StringHashMap([]const u8),
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
    /// Enum name → AST node. Populated by the same pre-pass. M10a only
    /// supports bare-tag variants (no payload); the codegen lowers an enum
    /// value to a single i64 holding the variant's index.
    enum_layouts: std.StringHashMap(*const ast.EnumDecl),
    /// Function name → AST node. Populated in pass 0. Lets call sites
    /// introspect parameter types (M10c needs this to know which args
    /// take a register pair) and return types (so let-decl can spill
    /// returned 16-byte enums correctly).
    fn_decls: std.StringHashMap(*const ast.FnDecl),

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) Aarch64NativeCodegen {
        return .{
            .allocator = allocator,
            .program = program,
            .assembler = arm64.Assembler.init(allocator),
            .functions = std.StringHashMap(usize).init(allocator),
            .locals = std.StringHashMap(u32).init(allocator),
            .local_struct_types = std.StringHashMap([]const u8).init(allocator),
            .local_array_lens = std.StringHashMap(u32).init(allocator),
            .local_enum_types = std.StringHashMap([]const u8).init(allocator),
            .pending_calls = std.ArrayList(PendingCall).empty,
            .strings = std.ArrayList(StringLit).empty,
            .string_fixups = std.ArrayList(StringFixup).empty,
            .struct_layouts = std.StringHashMap(*const ast.StructDecl).init(allocator),
            .enum_layouts = std.StringHashMap(*const ast.EnumDecl).init(allocator),
            .fn_decls = std.StringHashMap(*const ast.FnDecl).init(allocator),
        };
    }

    pub fn deinit(self: *Aarch64NativeCodegen) void {
        self.assembler.deinit();
        self.functions.deinit();
        self.locals.deinit();
        self.local_struct_types.deinit();
        self.local_array_lens.deinit();
        self.local_enum_types.deinit();
        self.pending_calls.deinit(self.allocator);
        for (self.strings.items) |str| self.allocator.free(str.bytes);
        self.strings.deinit(self.allocator);
        self.string_fixups.deinit(self.allocator);
        self.struct_layouts.deinit();
        self.enum_layouts.deinit();
        self.fn_decls.deinit();
    }

    pub fn writeExecutable(self: *Aarch64NativeCodegen, path: []const u8) !void {
        // Pass 0: register every StructDecl so frame sizing and member
        // accesses inside function bodies can look layouts up.
        for (self.program.statements) |stmt| {
            switch (stmt) {
                .StructDecl => |decl| try self.struct_layouts.put(decl.name, decl),
                .EnumDecl => |decl| try self.enum_layouts.put(decl.name, decl),
                .FnDecl => |decl| {
                    // A forward declaration (issue #17) must not clobber a
                    // real definition already registered under the name.
                    if (!decl.is_forward_decl or !self.fn_decls.contains(decl.name)) {
                        try self.fn_decls.put(decl.name, decl);
                    }
                },
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
                var writer = elf.ElfWriter.initArm64(self.allocator, code, data);
                writer.io = self.io;
                writer.entry_point = 0x401000 + main_offset;
                try writer.write(path);
            },
            else => return error.UnsupportedPlatform,
        }
    }

    fn generateStmt(self: *Aarch64NativeCodegen, stmt: ast.Stmt) CodegenError!void {
        switch (stmt) {
            .FnDecl => |func| {
                // Forward declarations (issue #17) bind the name only —
                // emitting them would duplicate the later definition's symbol.
                if (!func.is_forward_decl) try self.generateFnDecl(func);
            },
            .StructDecl => {}, // registered in writeExecutable's pass 0
            .EnumDecl => {}, // registered in writeExecutable's pass 0
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
        //   loop_top:    eval cond → x0
        //                cmp x0, #0
        //                b.eq exit              ; placeholder, patched
        //                <body>
        //                <continue-expr>        ; only if present
        //                b loop_top             ; backward, computed inline
        //   exit:
        const loop_top = self.assembler.getPosition();

        try self.generateExpr(while_stmt.condition);
        try self.assembler.cmpRegImm(.x0, 0);

        const exit_branch_pos = self.assembler.getPosition();
        try self.assembler.bcond(.eq, 0); // placeholder

        for (while_stmt.body.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Zig-style continue-expression: `while (cond) : (cexpr) { body }`
        // runs `cexpr` after each iteration, immediately before the back-edge.
        if (while_stmt.continue_expr) |cexpr| {
            try self.generateExpr(cexpr);
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
        // Compute per-param register/slot counts up front so we can validate
        // the AAPCS64 budget (8 regs total) before emitting any code.
        var total_param_regs: u32 = 0;
        var total_param_slots: u32 = 0;
        for (func.params) |param| {
            const sc = self.paramSlotCount(param);
            total_param_regs += sc;
            total_param_slots += sc;
        }
        if (total_param_regs > 8) return error.TooManyArguments;

        const offset = self.assembler.getPosition();
        try self.functions.put(func.name, offset);

        const prev_name = self.current_function_name;
        self.current_function_name = func.name;
        defer self.current_function_name = prev_name;

        // Reset per-function state.
        self.locals.clearRetainingCapacity();
        self.local_struct_types.clearRetainingCapacity();
        self.local_array_lens.clearRetainingCapacity();
        self.local_enum_types.clearRetainingCapacity();
        self.stack_delta = 0;
        self.next_slot = 0;

        // Pre-pass: total slot count = parameter slots (scalars 1 each,
        // payload-bearing-enum params 2 each) + slots required by every
        // reachable `let` binding (1 for scalars, N for struct-typed,
        // 2 for payload enums). Over-allocates when if/else branches are
        // mutually exclusive; an optimal allocator can reuse slots later.
        const let_slot_count: u32 = countSlotsInBlock(func.body, &self.struct_layouts, &self.enum_layouts);
        const raw_frame: u32 = (total_param_slots + let_slot_count) * 8;
        self.frame_size = std.mem.alignForward(u32, raw_frame, 16);
        if (self.frame_size > 4095) return error.FrameTooLarge; // single ADD/SUB imm12

        // Prologue: save FP/LR (uniformly, even for `main` — exit syscall
        // never returns so nothing reads them, but it keeps the layout
        // consistent and lets us use SP-relative locals directly).
        try self.assembler.functionPrologue();
        if (self.frame_size > 0) {
            try self.assembler.subRegImm(.sp, .sp, @intCast(self.frame_size));
        }

        // Spill incoming argument registers into local slots so subsequent
        // expression eval (which clobbers x0/x1) doesn't lose them. Scalar
        // params occupy one slot; payload-bearing enum params occupy two
        // (tag at +0, payload at +8) and consume two consecutive arg regs.
        var reg_idx: u32 = 0;
        var slot_off: u32 = 0;
        for (func.params) |param| {
            const sc = self.paramSlotCount(param);
            try self.locals.put(param.name, slot_off);
            try self.assembler.strRegMem(argRegister(reg_idx), .sp, @intCast(slot_off));
            if (sc == 2) {
                try self.assembler.strRegMem(argRegister(reg_idx + 1), .sp, @intCast(slot_off + 8));
                if (self.enum_layouts.get(param.type_name)) |edecl| {
                    try self.local_enum_types.put(param.name, edecl.name);
                }
            } else if (self.enum_layouts.get(param.type_name)) |edecl| {
                // Bare-tag enum param — single-slot, but still record type
                // so match-on-Identifier can see it.
                try self.local_enum_types.put(param.name, edecl.name);
            }
            reg_idx += sc;
            slot_off += sc * 8;
            self.next_slot = slot_off;
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
            if (value.* == .ArrayLiteral) {
                return self.generateLetArray(decl.name, value.ArrayLiteral);
            }
            // Enum construction: `let o = Option.Some(42)` or `let c = Color.Red`.
            // Bare-tag enums fall through to the scalar path (M10a) — the
            // MemberExpr returns the tag in x0 and we store one slot. Payload-
            // bearing enums need two slots and a dedicated builder.
            if (matchEnumConstruction(value, &self.enum_layouts)) |edecl| {
                if (enumIsPayloadBearing(edecl)) {
                    return self.generateLetEnumPayload(decl.name, value, edecl);
                }
                // Bare-tag: still record the local as enum-typed so later
                // match-on-Identifier can dispatch correctly.
                try self.generateExpr(value); // tag → x0
                const slot = self.next_slot;
                self.next_slot += 8;
                try self.locals.put(decl.name, slot);
                try self.local_enum_types.put(decl.name, edecl.name);
                try self.assembler.strRegMem(.x0, .sp, @intCast(slot));
                return;
            }
            // Call to a function returning a payload-bearing enum
            // (`let r = divide(a, b)` where `divide` returns Result).
            if (value.* == .CallExpr) {
                const cn = switch (value.CallExpr.callee.*) {
                    .Identifier => |id| id.name,
                    else => null,
                };
                if (cn) |name| {
                    if (self.fn_decls.get(name)) |fdecl| {
                        if (self.fnReturnsPayloadEnum(fdecl)) {
                            const rt = fdecl.return_type.?;
                            const edecl = self.enum_layouts.get(rt).?;
                            const slot = self.next_slot;
                            self.next_slot += 16;
                            try self.locals.put(decl.name, slot);
                            try self.local_enum_types.put(decl.name, edecl.name);
                            try self.generateCallExpr(value.CallExpr); // x0=tag, x1=payload
                            try self.assembler.strRegMem(.x0, .sp, @intCast(slot));
                            try self.assembler.strRegMem(.x1, .sp, @intCast(slot + 8));
                            return;
                        }
                    }
                }
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

    /// Lay down a payload-bearing enum value into a fresh 16-byte local
    /// slot pair: `[tag][payload]`. `value` is either `EnumName.Variant`
    /// (no payload) or `EnumName.Variant(arg)` (one payload arg).
    fn generateLetEnumPayload(
        self: *Aarch64NativeCodegen,
        name: []const u8,
        value: *ast.Expr,
        edecl: *const ast.EnumDecl,
    ) CodegenError!void {
        const member: *ast.MemberExpr = switch (value.*) {
            .MemberExpr => |m| m,
            .CallExpr => |c| switch (c.callee.*) {
                .MemberExpr => |m| m,
                else => return error.InvalidCallTarget,
            },
            else => return error.InvalidCallTarget,
        };
        const tag = variantIndex(edecl, member.member) orelse return error.UndefinedField;

        // Reserve the slots up front; record the local. Slot order is
        // [base+0]=tag, [base+8]=payload.
        const slot = self.next_slot;
        self.next_slot += 16;
        try self.locals.put(name, slot);
        try self.local_enum_types.put(name, edecl.name);

        // Evaluate payload (if any) into x0 first — it might read other
        // locals. Then write tag and payload to their slots.
        var has_payload: bool = false;
        if (value.* == .CallExpr) {
            const call = value.CallExpr;
            if (call.args.len > 1 or call.named_args.len != 0) return error.NotImplemented;
            if (call.args.len == 1) {
                try self.generateExpr(call.args[0]);
                has_payload = true;
            }
        }

        if (has_payload) {
            // Stash payload while we materialize the tag. delta isn't
            // used (top-level stmt, delta=0), but be explicit.
            try self.assembler.strRegMem(.x0, .sp, @intCast(slot + 8));
        } else {
            try self.assembler.movRegImm64(.x0, 0);
            try self.assembler.strRegMem(.x0, .sp, @intCast(slot + 8));
        }

        try self.assembler.movRegImm64(.x1, tag);
        try self.assembler.strRegMem(.x1, .sp, @intCast(slot));
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

    fn generateLetArray(self: *Aarch64NativeCodegen, name: []const u8, lit: *const ast.ArrayLiteral) CodegenError!void {
        const len: u32 = @intCast(lit.elements.len);
        const base_slot = self.next_slot;
        self.next_slot += len * 8;
        try self.locals.put(name, base_slot);
        try self.local_array_lens.put(name, len);

        // Store each element at base + i*8.
        for (lit.elements, 0..) |elem, i| {
            try self.generateExpr(elem); // x0 = element value
            const off: u32 = base_slot + @as(u32, @intCast(i)) * 8;
            try self.assembler.strRegMem(.x0, .sp, @intCast(off));
        }
    }

    fn generateReturn(self: *Aarch64NativeCodegen, ret: *ast.ReturnStmt) CodegenError!void {
        // If the current function returns a payload-bearing enum, we must
        // produce tag in x0 *and* payload in x1 — generateExprEnumAware
        // does both. Scalar returns stay in x0.
        const returns_enum = blk: {
            const name = self.current_function_name orelse break :blk false;
            const fdecl = self.fn_decls.get(name) orelse break :blk false;
            break :blk self.fnReturnsPayloadEnum(fdecl);
        };

        if (ret.value) |value| {
            if (returns_enum) {
                _ = try self.generateExprEnumAware(value);
            } else {
                try self.generateExpr(value);
            }
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
            .IndexExpr => |idx| try self.generateIndexRead(idx),
            .MatchExpr => |match| try self.generateMatchExpr(match),
            else => return error.NotImplemented,
        }
    }

    fn generateMatchExpr(self: *Aarch64NativeCodegen, match: *ast.MatchExpr) CodegenError!void {
        // Detect a payload-bearing enum scrutinee — handled specially so
        // we can spill the payload alongside the tag and bind it inside
        // arms that match by `Variant(ident)`. Other scrutinees go through
        // the M9 single-slot path.
        var scrut_is_payload_enum = false;
        switch (match.value.*) {
            .Identifier => |id| {
                if (self.local_enum_types.get(id.name)) |ename| {
                    if (self.enum_layouts.get(ename)) |edecl| {
                        if (enumIsPayloadBearing(edecl)) scrut_is_payload_enum = true;
                    }
                }
            },
            else => {},
        }

        if (scrut_is_payload_enum) {
            return self.generateMatchExprEnum(match);
        }

        // Evaluate the matched value once and spill to the stack so each
        // arm can reload it (and so it survives any push/pop the arm bodies
        // emit). The value lives at `[sp + 0]` while delta == 16.
        try self.generateExpr(match.value);
        try self.assembler.pushReg(.x0);
        self.stack_delta += 16;

        var end_jumps = std.ArrayList(usize).empty;
        defer end_jumps.deinit(self.allocator);

        for (match.arms) |arm| {
            if (arm.guard != null) return error.NotImplemented;

            // Pattern check. Returns the position of the conditional skip
            // branch (`bne next_arm`) for literal patterns, or null when the
            // pattern always matches (identifier / wildcard).
            const skip_pos = try self.emitArmPatternCheck(arm.pattern);

            // Body — its result lands in x0.
            try self.generateExpr(arm.body);

            // After the body, branch unconditionally to the match's end so
            // we don't fall through into the next arm.
            const end_jump_pos = self.assembler.getPosition();
            try self.assembler.b(0); // placeholder
            try end_jumps.append(self.allocator, end_jump_pos);

            // Patch the skip-to-next-arm branch to land just past this arm.
            if (skip_pos) |pos| {
                try self.assembler.patchBcond(pos, .ne, self.assembler.getPosition());
            }
        }

        // Patch every `b end` placeholder to land here.
        const end_target = self.assembler.getPosition();
        for (end_jumps.items) |pos| {
            try self.assembler.patchB(pos, end_target);
        }

        // Drop the saved match value off the stack. x1 is a scratch
        // register; we just need somewhere to land the popReg.
        try self.assembler.popReg(.x1);
        self.stack_delta -= 16;
    }

    /// Match dispatch where the scrutinee is a payload-bearing enum local.
    /// Reads tag + payload directly from the local's slot pair (no spill
    /// needed — the local lives in the stable frame). Patterns supported:
    ///   - `EnumName.Bare`     → tag check only
    ///   - `EnumName.Some(_)`  → tag check, payload ignored
    ///   - `EnumName.Some(x)`  → tag check, payload bound to identifier `x`
    ///   - `_`                 → wildcard
    fn generateMatchExprEnum(self: *Aarch64NativeCodegen, match: *ast.MatchExpr) CodegenError!void {
        const scrut_name = match.value.Identifier.name;
        const scrut_slot = self.locals.get(scrut_name) orelse return error.UndefinedIdentifier;

        var end_jumps = std.ArrayList(usize).empty;
        defer end_jumps.deinit(self.allocator);

        for (match.arms) |arm| {
            if (arm.guard != null) return error.NotImplemented;

            const arm_info = try self.emitEnumArmCheck(arm.pattern, scrut_slot);

            // If the pattern binds an identifier to the payload, allocate
            // a fresh slot, copy payload there, and register the binding
            // in `locals` for the duration of the arm body.
            var bind_name: ?[]const u8 = null;
            if (arm_info.binding) |name| {
                const bslot = self.next_slot;
                self.next_slot += 8;
                // payload is at [sp + scrut_slot + 8 + delta].
                try self.assembler.ldrRegMem(.x1, .sp, @intCast(scrut_slot + 8 + self.stack_delta));
                try self.assembler.strRegMem(.x1, .sp, @intCast(bslot + self.stack_delta));
                try self.locals.put(name, bslot);
                bind_name = name;
            }

            // Body — result lands in x0.
            try self.generateExpr(arm.body);

            // Tear down the binding before the next arm so the binding
            // name doesn't leak into a sibling arm with a different shape.
            if (bind_name) |name| {
                _ = self.locals.remove(name);
            }

            const end_jump_pos = self.assembler.getPosition();
            try self.assembler.b(0);
            try end_jumps.append(self.allocator, end_jump_pos);

            if (arm_info.skip_pos) |pos| {
                try self.assembler.patchBcond(pos, .ne, self.assembler.getPosition());
            }
        }

        const end_target = self.assembler.getPosition();
        for (end_jumps.items) |pos| {
            try self.assembler.patchB(pos, end_target);
        }
    }

    const EnumArmInfo = struct {
        /// Position of the conditional skip branch to patch with the
        /// next-arm address; null when the pattern always matches.
        skip_pos: ?usize,
        /// Name of the payload identifier this pattern binds, or null.
        binding: ?[]const u8,
    };

    /// Emit a tag check against an enum local at `scrut_slot` (slot+0=tag,
    /// slot+8=payload). Handles `_` wildcard, bare `EnumName.Variant`, and
    /// `EnumName.Variant(ident)` (with optional payload binding).
    fn emitEnumArmCheck(
        self: *Aarch64NativeCodegen,
        pattern: *ast.Expr,
        scrut_slot: u32,
    ) CodegenError!EnumArmInfo {
        switch (pattern.*) {
            .Identifier => |id| {
                if (std.mem.eql(u8, id.name, "_")) {
                    return .{ .skip_pos = null, .binding = null };
                }
                // Identifier without binding semantics — treat as wildcard
                // for compatibility with M9.
                return .{ .skip_pos = null, .binding = null };
            },
            .MemberExpr => |member| {
                const tag = try self.lookupEnumPatternTag(member);
                try self.emitEnumTagCheck(scrut_slot, tag);
                const pos = self.assembler.getPosition() - 4; // bcond just emitted
                return .{ .skip_pos = pos, .binding = null };
            },
            .CallExpr => |call| {
                const member = switch (call.callee.*) {
                    .MemberExpr => |m| m,
                    else => return error.NotImplemented,
                };
                const tag = try self.lookupEnumPatternTag(member);
                try self.emitEnumTagCheck(scrut_slot, tag);
                const pos = self.assembler.getPosition() - 4;
                if (call.args.len != 1) return error.NotImplemented;
                const bind: ?[]const u8 = switch (call.args[0].*) {
                    .Identifier => |id| if (std.mem.eql(u8, id.name, "_")) null else id.name,
                    else => return error.NotImplemented,
                };
                return .{ .skip_pos = pos, .binding = bind };
            },
            else => return error.NotImplemented,
        }
    }

    fn lookupEnumPatternTag(
        self: *Aarch64NativeCodegen,
        member: *ast.MemberExpr,
    ) CodegenError!i64 {
        const obj_name = switch (member.object.*) {
            .Identifier => |id| id.name,
            else => return error.NotImplemented,
        };
        const edecl = self.enum_layouts.get(obj_name) orelse return error.NotImplemented;
        return variantIndex(edecl, member.member) orelse error.UndefinedField;
    }

    /// Number of register/slot units a parameter occupies in AAPCS64
    /// terms: 1 for scalar types and bare-tag enums, 2 for payload-
    /// bearing enums (tag in xN, payload in xN+1).
    fn paramSlotCount(self: *Aarch64NativeCodegen, param: ast.Parameter) u32 {
        if (self.enum_layouts.get(param.type_name)) |edecl| {
            return enumSlotCount(edecl);
        }
        return 1;
    }

    /// True if this function returns a payload-bearing enum (16-byte
    /// register pair x0/x1 result).
    fn fnReturnsPayloadEnum(self: *Aarch64NativeCodegen, decl: *const ast.FnDecl) bool {
        const rt = decl.return_type orelse return false;
        const edecl = self.enum_layouts.get(rt) orelse return false;
        return enumIsPayloadBearing(edecl);
    }

    /// Evaluate `expr` as a (potentially) enum-typed value. On return,
    /// x0 holds the tag and x1 holds the payload — or just x0 for scalar
    /// expressions, with x1 left untouched. Returns the enum decl if the
    /// result is an enum value, or null for a scalar.
    ///
    /// Supports: enum-typed Identifier, bare/payload enum construction,
    /// and CallExpr to a function whose return type is a payload enum.
    /// Other shapes fall back to plain `generateExpr` (scalar in x0).
    fn generateExprEnumAware(
        self: *Aarch64NativeCodegen,
        expr: *ast.Expr,
    ) CodegenError!?*const ast.EnumDecl {
        switch (expr.*) {
            .Identifier => |id| {
                if (self.local_enum_types.get(id.name)) |ename| {
                    if (self.enum_layouts.get(ename)) |edecl| {
                        const base = self.locals.get(id.name) orelse return error.UndefinedIdentifier;
                        const off = base + self.stack_delta;
                        try self.assembler.ldrRegMem(.x0, .sp, @intCast(off));
                        if (enumIsPayloadBearing(edecl)) {
                            try self.assembler.ldrRegMem(.x1, .sp, @intCast(off + 8));
                        }
                        return edecl;
                    }
                }
            },
            .MemberExpr => |member| {
                if (matchEnumConstruction(expr, &self.enum_layouts)) |edecl| {
                    const tag = variantIndex(edecl, member.member) orelse return error.UndefinedField;
                    try self.assembler.movRegImm64(.x0, tag);
                    if (enumIsPayloadBearing(edecl)) {
                        try self.assembler.movRegImm64(.x1, 0);
                    }
                    return edecl;
                }
            },
            .CallExpr => |call| {
                // Enum construction `EnumName.Variant(arg)`?
                if (matchEnumConstruction(expr, &self.enum_layouts)) |edecl| {
                    const member = call.callee.MemberExpr;
                    const tag = variantIndex(edecl, member.member) orelse return error.UndefinedField;
                    if (call.args.len > 1 or call.named_args.len != 0) return error.NotImplemented;
                    if (call.args.len == 1) {
                        // Evaluate payload, leave in x1 without clobbering x0.
                        try self.generateExpr(call.args[0]); // → x0
                        // Move x0 → x1, then load tag → x0.
                        try self.assembler.movRegReg(.x1, .x0);
                    } else if (enumIsPayloadBearing(edecl)) {
                        try self.assembler.movRegImm64(.x1, 0);
                    }
                    try self.assembler.movRegImm64(.x0, tag);
                    return edecl;
                }
                // Call to a function returning a payload enum?
                const callee_name = switch (call.callee.*) {
                    .Identifier => |i| i.name,
                    else => return null,
                };
                if (self.fn_decls.get(callee_name)) |fdecl| {
                    if (self.fnReturnsPayloadEnum(fdecl)) {
                        try self.generateCallExpr(call); // returns x0 (tag) + x1 (payload)
                        const rt = fdecl.return_type.?;
                        return self.enum_layouts.get(rt);
                    }
                }
            },
            else => {},
        }
        // Fallback: treat as scalar.
        try self.generateExpr(expr);
        return null;
    }

    /// Emit `ldr x1, [sp + scrut_slot + delta]; cmp x1, #tag; bcond ne, 0`.
    /// Caller patches the bcond once the next-arm address is known.
    fn emitEnumTagCheck(self: *Aarch64NativeCodegen, scrut_slot: u32, tag: i64) CodegenError!void {
        try self.assembler.ldrRegMem(.x1, .sp, @intCast(scrut_slot + self.stack_delta));
        if (tag >= 0 and tag <= 4095) {
            try self.assembler.cmpRegImm(.x1, @intCast(tag));
        } else {
            try self.assembler.movRegImm64(.x2, tag);
            try self.assembler.cmpRegReg(.x1, .x2);
        }
        try self.assembler.bcond(.ne, 0);
    }

    /// Emit the comparison + conditional skip for one arm. Returns the
    /// position of the `bne next_arm` instruction so the caller can patch
    /// it once it knows where the next arm starts; or `null` if the
    /// pattern always matches (no skip needed).
    fn emitArmPatternCheck(self: *Aarch64NativeCodegen, pattern: *ast.Expr) CodegenError!?usize {
        switch (pattern.*) {
            .IntegerLiteral => |lit| {
                if (lit.value > std.math.maxInt(i64) or lit.value < std.math.minInt(i64)) {
                    return error.IntegerLiteralOutOfRange;
                }
                // Reload the saved match value into x1.
                try self.assembler.ldrRegMem(.x1, .sp, 0);
                // Compare with the literal. Small unsigned values can use
                // the immediate form; everything else needs a temp register.
                if (lit.value >= 0 and lit.value <= 4095) {
                    try self.assembler.cmpRegImm(.x1, @intCast(lit.value));
                } else {
                    try self.assembler.movRegImm64(.x2, @intCast(lit.value));
                    try self.assembler.cmpRegReg(.x1, .x2);
                }
                const pos = self.assembler.getPosition();
                try self.assembler.bcond(.ne, 0); // placeholder
                return pos;
            },
            .BooleanLiteral => |lit| {
                try self.assembler.ldrRegMem(.x1, .sp, 0);
                try self.assembler.cmpRegImm(.x1, if (lit.value) 1 else 0);
                const pos = self.assembler.getPosition();
                try self.assembler.bcond(.ne, 0);
                return pos;
            },
            .Identifier => {
                // Wildcard / unbound name — always matches. We don't bind
                // the value to the identifier in M9; if the body references
                // the name and it isn't already a function-scope local, it
                // will fail with UndefinedIdentifier.
                return null;
            },
            .MemberExpr => |member| {
                // M10a: bare enum-variant pattern, e.g. `Color.Red` →
                // compare the spilled scrutinee against the variant's tag.
                const ident = switch (member.object.*) {
                    .Identifier => |id| id.name,
                    else => return error.NotImplemented,
                };
                const edecl = self.enum_layouts.get(ident) orelse return error.NotImplemented;
                const idx = variantIndex(edecl, member.member) orelse return error.UndefinedField;

                try self.assembler.ldrRegMem(.x1, .sp, 0);
                if (idx >= 0 and idx <= 4095) {
                    try self.assembler.cmpRegImm(.x1, @intCast(idx));
                } else {
                    try self.assembler.movRegImm64(.x2, idx);
                    try self.assembler.cmpRegReg(.x1, .x2);
                }
                const pos = self.assembler.getPosition();
                try self.assembler.bcond(.ne, 0);
                return pos;
            },
            else => return error.NotImplemented,
        }
    }

    fn generateIndexRead(self: *Aarch64NativeCodegen, idx: *ast.IndexExpr) CodegenError!void {
        // M8 only supports `local[expr]` where local is an array on the stack.
        const ident = switch (idx.array.*) {
            .Identifier => |id| id.name,
            else => return error.NotImplemented,
        };
        const base = self.locals.get(ident) orelse return error.UndefinedIdentifier;
        if (self.local_array_lens.get(ident) == null) return error.NotAnArrayLocal;

        // Evaluate the index → x0, then bias by (base + delta) / 8 so that
        // `[sp, x0, LSL #3]` lands on the right element.
        try self.generateExpr(idx.index);
        const bias: u32 = (base + self.stack_delta) / 8;
        try self.assembler.addRegImm(.x0, .x0, @intCast(bias));
        try self.assembler.ldrRegRegLsl3(.x0, .sp, .x0);
    }

    fn generateMemberRead(self: *Aarch64NativeCodegen, member: *ast.MemberExpr) CodegenError!void {
        // M7 only handles the `local.field` shape — `obj.method()` chains,
        // pointer dereference, etc. are M-later.
        const ident = switch (member.object.*) {
            .Identifier => |id| id.name,
            else => return error.NotImplemented,
        };

        // M10a: `EnumName.Variant` produces the variant's index (i64). Bare
        // variants only — payload-bearing variants (e.g. `Some(x)`) flow
        // through a CallExpr whose callee is this MemberExpr and are handled
        // separately.
        if (self.enum_layouts.get(ident)) |edecl| {
            const idx = variantIndex(edecl, member.member) orelse return error.UndefinedField;
            try self.assembler.movRegImm64(.x0, idx);
            return;
        }

        const base = self.locals.get(ident) orelse return error.UndefinedIdentifier;
        const struct_name = self.local_struct_types.get(ident) orelse return error.NotAStructLocal;
        const sdecl = self.struct_layouts.get(struct_name) orelse return error.UndefinedStruct;
        const off = fieldOffset(sdecl, member.member) orelse return error.UndefinedField;

        const total: u32 = base + off + self.stack_delta;
        try self.assembler.ldrRegMem(.x0, .sp, @intCast(total));
    }

    fn generateCallExpr(self: *Aarch64NativeCodegen, call: *ast.CallExpr) CodegenError!void {
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

        // If we know the callee's signature, walk its params to determine
        // each arg's register footprint (1 or 2 slots). Unknown callees
        // default to 1 slot per arg.
        const callee_params: []const ast.Parameter = if (self.fn_decls.get(callee_name)) |fd|
            fd.params
        else
            &[_]ast.Parameter{};

        var total_reg_slots: u32 = 0;
        for (call.args, 0..) |_, i| {
            total_reg_slots += if (i < callee_params.len)
                self.paramSlotCount(callee_params[i])
            else
                1;
        }
        if (total_reg_slots > 8) return error.TooManyArguments;

        // Fast path: single arg. Whether scalar or enum, produce in xN
        // registers directly — generateExprEnumAware lands tag in x0
        // and payload in x1 with no spill needed.
        if (call.args.len == 1) {
            const sc: u32 = if (callee_params.len >= 1) self.paramSlotCount(callee_params[0]) else 1;
            if (sc == 2) {
                _ = try self.generateExprEnumAware(call.args[0]);
            } else {
                try self.generateExpr(call.args[0]);
            }
        } else if (call.args.len > 1) {
            // General path: spill each arg's halves to the stack, then
            // pop into xN..x0 so register N holds the last arg's last
            // slot. Push a 2-slot enum arg as (tag, payload) — popping
            // in reverse register order gives the right placement.
            for (call.args, 0..) |arg, i| {
                const sc: u32 = if (i < callee_params.len) self.paramSlotCount(callee_params[i]) else 1;
                if (sc == 2) {
                    _ = try self.generateExprEnumAware(arg);
                    try self.assembler.pushReg(.x0);
                    self.stack_delta += 16;
                    try self.assembler.pushReg(.x1);
                    self.stack_delta += 16;
                } else {
                    try self.generateExpr(arg);
                    try self.assembler.pushReg(.x0);
                    self.stack_delta += 16;
                }
            }
            var ri: u32 = total_reg_slots;
            while (ri > 0) {
                ri -= 1;
                try self.assembler.popReg(argRegister(ri));
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
        // Result lives in x0 (and x1 for payload-enum returns); the caller
        // is responsible for knowing which.
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
            .IndexExpr => |idx| {
                // arr[i] = value. Value is already in x0; we need to compute
                // the slot address without losing it.
                const ident = switch (idx.array.*) {
                    .Identifier => |id| id.name,
                    else => return error.NotImplemented,
                };
                const base = self.locals.get(ident) orelse return error.UndefinedIdentifier;
                if (self.local_array_lens.get(ident) == null) return error.NotAnArrayLocal;

                // Spill value, evaluate index, restore value, store.
                try self.assembler.pushReg(.x0);
                self.stack_delta += 16;

                try self.generateExpr(idx.index); // x0 = i (with delta=16)

                try self.assembler.popReg(.x1);
                self.stack_delta -= 16;
                // Now x0 = i, x1 = value, delta back to its outer level.

                const bias: u32 = (base + self.stack_delta) / 8;
                try self.assembler.addRegImm(.x0, .x0, @intCast(bias));
                try self.assembler.strRegRegLsl3(.x1, .sp, .x0);
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
fn countSlotsInBlock(
    block: *const ast.BlockStmt,
    struct_layouts: *std.StringHashMap(*const ast.StructDecl),
    enum_layouts: *std.StringHashMap(*const ast.EnumDecl),
) u32 {
    var count: u32 = 0;
    for (block.statements) |stmt| {
        count += countSlotsInStmt(stmt, struct_layouts, enum_layouts);
    }
    return count;
}

fn countSlotsInStmt(
    stmt: ast.Stmt,
    struct_layouts: *std.StringHashMap(*const ast.StructDecl),
    enum_layouts: *std.StringHashMap(*const ast.EnumDecl),
) u32 {
    return switch (stmt) {
        .LetDecl => |decl| blk: {
            if (decl.value) |v| {
                // Struct-typed initializer? If we know the struct, claim
                // one slot per field; otherwise fall back to one slot.
                if (v.* == .StructLiteral) {
                    if (struct_layouts.get(v.StructLiteral.type_name)) |sdecl| {
                        break :blk @intCast(sdecl.fields.len);
                    }
                }
                // Array literal? Claim one slot per element.
                if (v.* == .ArrayLiteral) {
                    break :blk @intCast(v.ArrayLiteral.elements.len);
                }
                // Enum construction (`E.V` / `E.V(arg)`)? Slot count
                // depends on whether any variant carries a payload.
                if (matchEnumConstruction(v, enum_layouts)) |edecl| {
                    break :blk enumSlotCount(edecl);
                }
                // Match-RHS let: 1 slot for the let's own value, plus
                // one slot per arm with a single-Identifier binding
                // pattern (`Some(x) => ...`).
                if (v.* == .MatchExpr) {
                    var c: u32 = 1;
                    for (v.MatchExpr.arms) |arm| {
                        c += armBindingSlotCount(arm.pattern);
                    }
                    break :blk c;
                }
            }
            break :blk 1;
        },
        .IfStmt => |if_stmt| blk: {
            var c = countSlotsInBlock(if_stmt.then_block, struct_layouts, enum_layouts);
            if (if_stmt.else_block) |eb| c += countSlotsInBlock(eb, struct_layouts, enum_layouts);
            break :blk c;
        },
        .WhileStmt => |while_stmt| countSlotsInBlock(while_stmt.body, struct_layouts, enum_layouts),
        else => 0,
    };
}

/// Number of frame slots required to hold any payload bindings introduced
/// by a single match arm pattern. M10b only supports one binding (the
/// payload identifier of an enum variant), so the answer is 0 or 1.
fn armBindingSlotCount(pattern: *ast.Expr) u32 {
    return switch (pattern.*) {
        .CallExpr => |call| blk: {
            if (call.args.len != 1) break :blk 0;
            switch (call.args[0].*) {
                .Identifier => |id| {
                    // `_` is a wildcard, no binding needed.
                    if (std.mem.eql(u8, id.name, "_")) break :blk 0;
                    break :blk 1;
                },
                else => break :blk 0,
            }
        },
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

/// Look up a variant by name in an enum declaration; returns its 0-based
/// declaration index, used as the runtime tag value in M10a.
fn variantIndex(decl: *const ast.EnumDecl, name: []const u8) ?i64 {
    for (decl.variants, 0..) |v, i| {
        if (std.mem.eql(u8, v.name, name)) return @intCast(i);
    }
    return null;
}

/// True if any variant of this enum carries a payload (`Some(int)`,
/// `Err(string)`, etc.). Payload-bearing enums are stored as two
/// consecutive 8-byte slots (`[tag][payload]`), bare-tag enums as one.
fn enumIsPayloadBearing(decl: *const ast.EnumDecl) bool {
    for (decl.variants) |v| {
        if (v.data_type != null) return true;
    }
    return false;
}

/// Returns the local-slot footprint of an enum value of this declaration:
/// 1 slot (8 bytes) for bare-tag enums, 2 slots (16 bytes) for payload-
/// bearing ones. M-later: variants with payloads larger than 8 bytes.
fn enumSlotCount(decl: *const ast.EnumDecl) u32 {
    return if (enumIsPayloadBearing(decl)) 2 else 1;
}

/// True if this Expr is a syntactic enum-value construction:
/// either `EnumName.Variant` (MemberExpr whose object resolves to an
/// enum name in `enum_layouts`) or `EnumName.Variant(arg)` (CallExpr
/// whose callee is such a MemberExpr). Returns the matching enum decl
/// or null.
fn matchEnumConstruction(
    expr: *ast.Expr,
    enum_layouts: *std.StringHashMap(*const ast.EnumDecl),
) ?*const ast.EnumDecl {
    const member: *ast.MemberExpr = switch (expr.*) {
        .MemberExpr => |m| m,
        .CallExpr => |c| switch (c.callee.*) {
            .MemberExpr => |m| m,
            else => return null,
        },
        else => return null,
    };
    const obj_name = switch (member.object.*) {
        .Identifier => |id| id.name,
        else => return null,
    };
    return enum_layouts.get(obj_name);
}
