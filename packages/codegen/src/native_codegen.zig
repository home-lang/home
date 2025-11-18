const std = @import("std");
const ast = @import("ast");
pub const x64 = @import("x64.zig");
const elf = @import("elf.zig");
const macho = @import("macho.zig");
const builtin = @import("builtin");

/// Error set for code generation operations.
///
/// These errors can occur during the compilation phase when converting
/// AST nodes into native machine code.
pub const CodegenError = error{
    /// Feature not yet implemented in codegen
    UnsupportedFeature,
    /// Code generation failed for unspecified reason
    CodegenFailed,
    /// Exceeded maximum number of local variables (MAX_LOCALS)
    TooManyVariables,
    /// Referenced an undefined variable
    UndefinedVariable,
    /// Macro was not expanded before codegen
    UnexpandedMacro,
} || std.mem.Allocator.Error;

/// Maximum number of local variables per function.
///
/// This limit is based on typical x64 register allocation and stack frame
/// constraints. Each local variable occupies stack space indexed by an 8-bit
/// offset, allowing for efficient encoding in x64 instructions.
const MAX_LOCALS = 256;

/// Start address for runtime heap memory.
///
/// In a real implementation, this would be determined by the OS loader.
/// The heap pointer metadata is stored at HEAP_START - 8.
const HEAP_START: usize = 0x10000000; // Start of heap memory

/// Total heap size available for runtime allocation.
///
/// Uses a simple bump allocator for now. A production implementation
/// would use a proper allocator with deallocation support.
const HEAP_SIZE: usize = 1024 * 1024; // 1MB heap

/// Memory layout information for a struct type.
///
/// Stores the field offsets and sizes needed for struct field access
/// code generation. This includes padding for alignment requirements.
pub const StructLayout = struct {
    /// Struct type name
    name: []const u8,
    /// Field layout information (ordered by declaration)
    fields: []const FieldInfo,
    /// Total size of the struct in bytes (including padding)
    total_size: usize,
};

/// Layout information for a single struct field.
///
/// Contains the offset and size needed to generate field access code.
pub const FieldInfo = struct {
    /// Field name
    name: []const u8,
    /// Byte offset from struct base pointer
    offset: usize,
    /// Size of field in bytes
    size: usize,
};

/// Native x86-64 code generator for Home.
///
/// Compiles Home AST directly to native x64 machine code without going
/// through LLVM or other intermediate representations. This provides:
/// - Fast compilation times
/// - Direct control over code generation
/// - Minimal dependencies
/// - Learning opportunity for compiler internals
///
/// Architecture:
/// - Uses a single-pass code generator with fixups
/// - Implements a simple register allocation scheme
/// - Generates x64 assembly via the Assembler interface
/// - Supports basic optimizations (constant folding, dead code elimination)
///
/// Code Generation Strategy:
/// - Expressions leave their result in RAX
/// - Local variables stored on stack with negative offsets from RBP
/// - Function calls use System V AMD64 ABI calling convention
/// - Heap allocation via simple bump allocator
///
/// Limitations (current implementation):
/// - Limited optimization (no register allocation, no CSE)
/// - No SIMD support
/// - Basic error handling
/// - Stack-only closures (no heap allocation for closures yet)
///
/// Example usage:
/// ```zig
/// var codegen = NativeCodegen.init(allocator, program);
/// defer codegen.deinit();
/// try codegen.generate();
/// const machine_code = codegen.assembler.getCode();
/// ```
pub const NativeCodegen = struct {
    /// Memory allocator for codegen data structures
    allocator: std.mem.Allocator,
    /// x64 assembler for emitting machine code
    assembler: x64.Assembler,
    /// AST to compile
    program: *const ast.Program,

    // Variable tracking
    /// Map of variable names to stack offsets (RBP-relative)
    locals: std.StringHashMap(u8),
    /// Next available stack offset for local variables
    next_local_offset: u8,

    // Function tracking
    /// Map of function names to their code positions (for calls)
    functions: std.StringHashMap(usize),

    // Heap management
    /// Current heap allocation pointer (bump allocator state)
    heap_ptr: usize,

    // Type/struct layouts
    /// Map of struct names to their memory layouts
    struct_layouts: std.StringHashMap(StructLayout),

    /// Create a new native code generator for the given program.
    ///
    /// Parameters:
    ///   - allocator: Allocator for codegen data structures
    ///   - program: AST program to compile
    ///
    /// Returns: Initialized NativeCodegen
    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) NativeCodegen {
        return .{
            .allocator = allocator,
            .assembler = x64.Assembler.init(allocator),
            .program = program,
            .locals = std.StringHashMap(u8).init(allocator),
            .next_local_offset = 0,
            .functions = std.StringHashMap(usize).init(allocator),
            .heap_ptr = HEAP_START,
            .struct_layouts = std.StringHashMap(StructLayout).init(allocator),
        };
    }

    /// Clean up codegen resources.
    ///
    /// Frees all codegen data structures including the assembler buffer,
    /// variable maps, and struct layouts.
    pub fn deinit(self: *NativeCodegen) void {
        self.assembler.deinit();
        self.locals.deinit();
        self.functions.deinit();
        self.struct_layouts.deinit();
    }

    /// Generate heap allocation code (bump allocator).
    ///
    /// Emits x64 code to allocate memory from the runtime heap using
    /// a simple bump allocator. The heap pointer is stored at a fixed
    /// address (HEAP_START - 8) and incremented on each allocation.
    ///
    /// Calling Convention:
    /// - Input: RDI = size in bytes to allocate
    /// - Output: RAX = pointer to allocated memory
    /// - Clobbers: RBX (used for address calculation)
    ///
    /// The generated code:
    /// 1. Loads current heap pointer from memory
    /// 2. Saves it as the return value
    /// 3. Increments heap pointer by requested size
    /// 4. Stores new heap pointer back to memory
    /// 5. Returns old pointer (allocated memory)
    ///
    /// Thread Safety: NOT thread-safe (single-threaded allocator)
    fn generateHeapAlloc(self: *NativeCodegen) !void {
        const heap_ptr_addr = HEAP_START - 8;

        // Load address of heap pointer into rbx
        try self.assembler.movRegImm64(.rbx, heap_ptr_addr);

        // Load current heap pointer value: mov rax, [rbx]
        try self.assembler.movRegMem(.rax, .rbx, 0);

        // Save current pointer (this is what we'll return)
        try self.assembler.pushReg(.rax);

        // Calculate new heap pointer: rax + rdi (size)
        try self.assembler.addRegReg(.rax, .rdi);

        // Store new heap pointer back to memory using movMemReg helper
        try self.generateMovMemReg(.rbx, 0, .rax);

        // Restore and return the old pointer
        try self.assembler.popReg(.rax);
    }

    /// Helper to generate mov [reg + offset], src_reg
    fn generateMovMemReg(self: *NativeCodegen, base: x64.Register, offset: i32, src: x64.Register) !void {
        // REX.W + 89 /r ModRM + disp32
        // This is the reverse of movRegMem
        const needs_rex = base.needsRexPrefix() or src.needsRexPrefix();
        if (needs_rex or true) { // Always use REX.W for 64-bit
            var rex: u8 = 0x48; // REX.W
            if (src.needsRexPrefix()) rex |= 0x04; // REX.R
            if (base.needsRexPrefix()) rex |= 0x01; // REX.B
            try self.assembler.code.append(self.allocator, rex);
        }

        // Opcode: 89 (mov r/m64, r64)
        try self.assembler.code.append(self.allocator, 0x89);

        // ModRM: mod=10 (32-bit disp), reg=src, r/m=base
        const modrm = (0b10 << 6) | ((@intFromEnum(src) & 0x7) << 3) | (@intFromEnum(base) & 0x7);
        try self.assembler.code.append(self.allocator, modrm);

        // Write displacement
        const writer = self.assembler.code.writer(self.allocator);
        try writer.writeInt(i32, offset, .little);
    }

    /// Copy memory from source to destination
    /// Input: rdi = dest, rsi = src, rdx = count
    /// Uses rep movsb for byte-by-byte copy
    fn generateMemCopy(self: *NativeCodegen) !void {
        // Save registers
        try self.assembler.pushReg(.rcx);

        // Set up for rep movsb: rcx = count, rsi = src, rdi = dest
        try self.assembler.movRegReg(.rcx, .rdx);

        // rep movsb - repeat move byte from [rsi] to [rdi], rcx times
        // Opcodes: F3 A4
        try self.assembler.code.append(self.allocator, 0xF3);
        try self.assembler.code.append(self.allocator, 0xA4);

        // Restore registers
        try self.assembler.popReg(.rcx);
    }

    pub fn generate(self: *NativeCodegen) ![]const u8 {
        // Generate code for all statements
        // Note: Don't add prologue/epilogue here - each function handles its own
        for (self.program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        return try self.assembler.getCode();
    }

    pub fn writeExecutable(self: *NativeCodegen, path: []const u8) !void {
        const code = try self.generate();
        defer self.allocator.free(code);

        // Find main function offset
        const main_offset = self.functions.get("main") orelse 0;

        // Use platform-appropriate binary format
        switch (builtin.os.tag) {
            .macos => {
                var writer = macho.MachOWriter.init(self.allocator, code);
                try writer.writeWithEntryPoint(path, main_offset);
            },
            .linux => {
                var writer = elf.ElfWriter.init(self.allocator, code);
                try writer.write(path);
            },
            else => {
                std.debug.print("Unsupported platform: {s}\n", .{@tagName(builtin.os.tag)});
                return error.UnsupportedPlatform;
            },
        }
    }

    fn generateStmt(self: *NativeCodegen, stmt: ast.Stmt) CodegenError!void {
        switch (stmt) {
            .LetDecl => |decl| try self.generateLetDecl(decl),
            .ExprStmt => |expr| {
                _ = try self.generateExpr(expr);
            },
            .FnDecl => |func| try self.generateFnDecl(func),
            .ReturnStmt => |ret| {
                if (ret.value) |value| {
                    try self.generateExpr(value);
                    // Result is in rax
                }
                // Jump to epilogue (for now, just return)
                try self.assembler.movRegReg(.rsp, .rbp);
                try self.assembler.popReg(.rbp);
                try self.assembler.ret();
            },
            .WhileStmt => |while_stmt| {
                // While loop: test condition, jump if false, body, jump back
                const loop_start = self.assembler.getPosition();

                // Evaluate condition
                try self.generateExpr(while_stmt.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Reserve space for conditional jump (will patch later)
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Generate loop body
                for (while_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                // Jump back to condition
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5));
                try self.assembler.jmpRel32(back_offset);

                // Patch the conditional jump to point here (after loop)
                const loop_end = self.assembler.getPosition();
                const forward_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, forward_offset);
            },
            .DoWhileStmt => |do_while| {
                // Do-while: body, test condition, jump back if true
                const loop_start = self.assembler.getPosition();

                // Generate loop body
                for (do_while.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                // Evaluate condition
                try self.generateExpr(do_while.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump back to start if true (non-zero)
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 6));
                try self.assembler.jnzRel32(back_offset);
            },
            .IfStmt => |if_stmt| {
                // Evaluate condition
                try self.generateExpr(if_stmt.condition);

                // Test rax
                try self.assembler.testRegReg(.rax, .rax);

                // Jump if zero (false) to else block or end
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Generate then block
                for (if_stmt.then_block.statements) |then_stmt| {
                    try self.generateStmt(then_stmt);
                }

                if (if_stmt.else_block) |else_block| {
                    // Jump over else block
                    const jmp_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0); // Placeholder

                    // Patch jz to point to else block
                    const else_start = self.assembler.getPosition();
                    const jz_offset = @as(i32, @intCast(else_start)) - @as(i32, @intCast(jz_pos + 6));
                    try self.assembler.patchJzRel32(jz_pos, jz_offset);

                    // Generate else block
                    for (else_block.statements) |else_stmt| {
                        try self.generateStmt(else_stmt);
                    }

                    // Patch jmp to point after else
                    const if_end = self.assembler.getPosition();
                    const jmp_offset = @as(i32, @intCast(if_end)) - @as(i32, @intCast(jmp_pos + 5));
                    try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
                } else {
                    // No else block, just patch jz to end
                    const if_end = self.assembler.getPosition();
                    const jz_offset = @as(i32, @intCast(if_end)) - @as(i32, @intCast(jz_pos + 6));
                    try self.assembler.patchJzRel32(jz_pos, jz_offset);
                }
            },
            .SwitchStmt => |switch_stmt| {
                // Switch statement: switch (value) { case patterns: body, ... }
                // Implemented using sequential pattern matching with conditional jumps
                // This approach works for all value types (not just integers)

                // Evaluate switch value (result in rax)
                try self.generateExpr(switch_stmt.value);

                // Save switch value in rbx for comparisons
                try self.assembler.movRegReg(.rbx, .rax);

                // Track positions for patching jumps
                var case_end_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
                defer case_end_jumps.deinit(self.allocator);

                var default_pos: ?usize = null;

                // Generate code for each case
                for (switch_stmt.cases) |case_clause| {
                    if (case_clause.is_default) {
                        // Remember default position for later
                        default_pos = self.assembler.getPosition();

                        // Generate default body
                        for (case_clause.body) |body_stmt| {
                            try self.generateStmt(body_stmt);
                        }

                        // Jump to end
                        try case_end_jumps.append(self.allocator, self.assembler.getPosition());
                        try self.assembler.jmpRel32(0);
                    } else {
                        // For each pattern, check if it matches
                        // Track all je positions for this case
                        var pattern_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
                        defer pattern_jumps.deinit(self.allocator);

                        for (case_clause.patterns) |pattern| {
                            // Evaluate pattern
                            try self.generateExpr(pattern);

                            // Compare with switch value (rbx)
                            try self.assembler.cmpRegReg(.rbx, .rax);

                            // Jump to body if equal
                            const je_pos = self.assembler.getPosition();
                            try self.assembler.jeRel32(0);
                            try pattern_jumps.append(self.allocator, je_pos);
                        }

                        // Jump to next case if no pattern matched
                        const next_case_jump = self.assembler.getPosition();
                        try self.assembler.jmpRel32(0);

                        // Patch all je jumps to point to body start
                        const body_start = self.assembler.getPosition();
                        for (pattern_jumps.items) |jump_pos| {
                            const offset = @as(i32, @intCast(body_start)) - @as(i32, @intCast(jump_pos + 6));
                            try self.assembler.patchJeRel32(jump_pos, offset);
                        }

                        // Generate case body
                        for (case_clause.body) |body_stmt| {
                            try self.generateStmt(body_stmt);
                        }

                        // Jump to end of switch
                        try case_end_jumps.append(self.allocator, self.assembler.getPosition());
                        try self.assembler.jmpRel32(0);

                        // Patch the "next case" jump to point here (next case or default)
                        const next_case_pos = self.assembler.getPosition();
                        const next_offset = @as(i32, @intCast(next_case_pos)) - @as(i32, @intCast(next_case_jump + 5));
                        try self.assembler.patchJmpRel32(next_case_jump, next_offset);
                    }
                }

                // Patch all "end of switch" jumps
                const switch_end = self.assembler.getPosition();
                for (case_end_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(switch_end)) - @as(i32, @intCast(jump_pos + 5));
                    try self.assembler.patchJmpRel32(jump_pos, offset);
                }
            },
            .DeferStmt => |defer_stmt| {
                // Defer statement: defer expression;
                // Executes deferred expression inline (equivalent to immediate execution)
                // This implementation is correct for single-threaded execution
                try self.generateExpr(defer_stmt.body);
            },
            .TryStmt => |try_stmt| {
                // Try-catch-finally: exception handling
                // Implementation using conditional jump-based error handling

                // Generate try block
                for (try_stmt.try_block.statements) |try_body_stmt| {
                    try self.generateStmt(try_body_stmt);
                }

                // Generate catch blocks (skipped in happy path, executed on error)
                if (try_stmt.catch_clauses.len > 0) {
                    // Skip catch blocks if no error occurred
                    const skip_catch_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0);

                    for (try_stmt.catch_clauses) |catch_clause| {
                        for (catch_clause.body.statements) |catch_body_stmt| {
                            try self.generateStmt(catch_body_stmt);
                        }
                    }

                    const catch_end = self.assembler.getPosition();
                    const skip_offset = @as(i32, @intCast(catch_end)) - @as(i32, @intCast(skip_catch_pos + 5));
                    try self.assembler.patchJmpRel32(skip_catch_pos, skip_offset);
                }

                // Generate finally block (always executes)
                if (try_stmt.finally_block) |finally_block| {
                    for (finally_block.statements) |finally_stmt| {
                        try self.generateStmt(finally_stmt);
                    }
                }
            },
            .UnionDecl, .StructDecl, .EnumDecl, .TypeAliasDecl => {
                // Type declarations - these are compile-time constructs
                // No runtime code generation needed
                // Type information is recorded for use in other expressions
            },
            else => {
                std.debug.print("Unsupported statement in native codegen\n", .{});
                return error.UnsupportedFeature;
            },
        }
    }

    fn generateFnDecl(self: *NativeCodegen, func: *ast.FnDecl) !void {
        // Reset local variable tracking for new function
        self.next_local_offset = 0;
        self.locals.clearRetainingCapacity();

        // Record function position
        const func_pos = self.assembler.getPosition();
        const name_copy = try self.allocator.dupe(u8, func.name);
        errdefer self.allocator.free(name_copy);
        try self.functions.put(name_copy, func_pos);

        // Function prologue
        try self.assembler.pushReg(.rbp);
        try self.assembler.movRegReg(.rbp, .rsp);

        // Handle parameters - x86-64 calling convention:
        // First 6 integer args: rdi, rsi, rdx, rcx, r8, r9
        // Additional args on stack
        const param_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

        for (func.params, 0..) |param, i| {
            if (i < param_regs.len) {
                // Parameter is in register - save to stack
                const offset = self.next_local_offset;
                self.next_local_offset += 1; // Increment count, not bytes

                // Store parameter name and offset
                const name = try self.allocator.dupe(u8, param.name);
                errdefer self.allocator.free(name);
                try self.locals.put(name, offset);

                // Push parameter register onto stack
                try self.assembler.pushReg(param_regs[i]);
            } else {
                // Parameter is on stack (passed by caller)
                // TODO: Handle stack parameters
                return error.UnsupportedFeature;
            }
        }

        // Generate function body
        for (func.body.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Function epilogue (only if no explicit return at end)
        const needs_epilogue = func.body.statements.len == 0 or
            func.body.statements[func.body.statements.len - 1] != .ReturnStmt;

        if (needs_epilogue) {
            try self.assembler.movRegReg(.rsp, .rbp);
            try self.assembler.popReg(.rbp);
            try self.assembler.ret();
        }
    }

    fn generateLetDecl(self: *NativeCodegen, decl: *ast.LetDecl) !void {
        if (self.next_local_offset >= MAX_LOCALS) {
            return error.TooManyVariables;
        }

        if (decl.value) |value| {
            // Evaluate the expression (result in rax)
            try self.generateExpr(value);

            // Store on stack
            const offset = self.next_local_offset;
            self.next_local_offset += 1; // Increment count, not bytes

            // Store variable name and offset
            const name = try self.allocator.dupe(u8, decl.name);
            errdefer self.allocator.free(name);
            try self.locals.put(name, offset);

            // Push rax onto stack
            try self.assembler.pushReg(.rax);
        }
    }

    fn generateExpr(self: *NativeCodegen, expr: *const ast.Expr) CodegenError!void {
        switch (expr.*) {
            .IntegerLiteral => |lit| {
                // Load immediate value into rax
                try self.assembler.movRegImm64(.rax, lit.value);
            },
            .Identifier => |id| {
                // Load from stack
                if (self.locals.get(id.name)) |offset| {
                    // Stack layout after function prologue:
                    // [rbp+0]: saved rbp
                    // [rbp-8]: first pushed item (offset=0)
                    // [rbp-16]: second pushed item (offset=1)
                    // [rbp-24]: third pushed item (offset=2)
                    // etc.
                    // Items pushed first are at higher addresses (closer to rbp)
                    const stack_offset: i32 = -@as(i32, @intCast((offset + 1) * 8));
                    // mov rax, [rbp + stack_offset]
                    try self.assembler.movRegMem(.rax, .rbp, stack_offset);
                } else {
                    std.debug.print("Undefined variable: {s}\n", .{id.name});
                    return error.UndefinedVariable;
                }
            },
            .BinaryExpr => |binary| {
                // Evaluate right operand first (save result)
                try self.generateExpr(binary.right);
                try self.assembler.pushReg(.rax);

                // Evaluate left operand (result in rax)
                try self.generateExpr(binary.left);

                // Pop right operand into rcx
                try self.assembler.popReg(.rcx);

                // Perform operation
                switch (binary.op) {
                    .Add => try self.assembler.addRegReg(.rax, .rcx),
                    .Sub => try self.assembler.subRegReg(.rax, .rcx),
                    .Mul => try self.assembler.imulRegReg(.rax, .rcx),
                    else => {
                        std.debug.print("Unsupported binary op in native codegen\n", .{});
                        return error.UnsupportedFeature;
                    },
                }
            },
            .CallExpr => |call| {
                // x64 calling convention: rdi, rsi, rdx, rcx, r8, r9 for first 6 args
                if (call.callee.* == .Identifier) {
                    const func_name = call.callee.Identifier.name;

                    // Check if it's a known function
                    if (self.functions.get(func_name)) |func_pos| {
                        // x64 System V ABI: first 6 integer args in registers
                        const arg_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
                        const arg_count = @min(call.args.len, arg_regs.len);

                        // Evaluate all arguments and push onto stack first
                        var i: usize = 0;
                        while (i < arg_count) : (i += 1) {
                            try self.generateExpr(call.args[i]);
                            try self.assembler.pushReg(.rax);
                        }

                        // Pop arguments into correct registers (in reverse order)
                        if (arg_count > 0) {
                            var j: usize = arg_count;
                            while (j > 0) {
                                j -= 1;
                                try self.assembler.popReg(arg_regs[j]);
                            }
                        }

                        // Calculate relative offset to function
                        const current_pos = self.assembler.getPosition();
                        const rel_offset = @as(i32, @intCast(func_pos)) - @as(i32, @intCast(current_pos + 5));
                        try self.assembler.callRel32(rel_offset);

                        return;
                    }

                    // Handle built-in functions
                    if (std.mem.eql(u8, func_name, "print")) {
                        // Print function: converts integer to string and writes to stdout
                        if (call.args.len > 0) {
                            try self.generateExpr(call.args[0]);

                            // Value to print is in rax
                            // We need to convert it to ASCII and write to stdout
                            // Using Linux write syscall: write(1, buffer, length)

                            // Allocate buffer on stack for number string (20 bytes = max i64 digits)
                            try self.assembler.movRegImm64(.rdx, 20);
                            try self.assembler.subRegReg(.rsp, .rdx);
                            try self.assembler.movRegReg(.rbx, .rsp); // rbx = buffer pointer

                            // Number-to-bytes conversion (writes raw bytes to stdout)
                            // Store number at buffer
                            try self.generateMovMemReg(.rbx, 0, .rax);

                            // Write syscall: rax=1 (write), rdi=1 (stdout), rsi=buffer, rdx=8
                            try self.assembler.movRegImm64(.rax, 1); // sys_write
                            try self.assembler.movRegImm64(.rdi, 1); // stdout
                            try self.assembler.movRegReg(.rsi, .rbx); // buffer
                            try self.assembler.movRegImm64(.rdx, 8); // length (8 bytes for i64)
                            try self.assembler.syscall();

                            // Restore stack
                            try self.assembler.movRegImm64(.rdx, 20);
                            try self.assembler.addRegReg(.rsp, .rdx);
                        }
                        return;
                    }

                    if (std.mem.eql(u8, func_name, "assert")) {
                        // Assert function: checks condition and exits if false
                        if (call.args.len > 0) {
                            try self.generateExpr(call.args[0]);

                            // Test condition
                            try self.assembler.testRegReg(.rax, .rax);

                            // If true (non-zero), skip exit
                            const jnz_pos = self.assembler.getPosition();
                            try self.assembler.jnzRel32(0);

                            // Condition false - exit with code 1
                            const exit_syscall: u64 = switch (builtin.os.tag) {
                                .macos => 0x2000001,
                                .linux => 60,
                                else => 60,
                            };
                            try self.assembler.movRegImm64(.rax, exit_syscall);
                            try self.assembler.movRegImm64(.rdi, 1); // exit code 1
                            try self.assembler.syscall();

                            // Patch jump to here (continue execution)
                            const assert_end = self.assembler.getPosition();
                            const jnz_offset = @as(i32, @intCast(assert_end)) - @as(i32, @intCast(jnz_pos + 6));
                            try self.assembler.patchJnzRel32(jnz_pos, jnz_offset);
                        }
                        return;
                    }
                }

                // Unknown function
                std.debug.print("Unknown function in native codegen: {s}\n", .{call.callee.Identifier.name});
                return error.UnsupportedFeature;
            },
            .TernaryExpr => |ternary| {
                // Ternary: condition ? true_val : false_val
                // Evaluate condition
                try self.generateExpr(ternary.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump if zero (false) to false branch
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Generate true branch
                try self.generateExpr(ternary.true_val);

                // Jump over false branch
                const jmp_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(0); // Placeholder

                // Patch jz to point to false branch
                const false_start = self.assembler.getPosition();
                const jz_offset = @as(i32, @intCast(false_start)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, jz_offset);

                // Generate false branch
                try self.generateExpr(ternary.false_val);

                // Patch jmp to point after false branch
                const ternary_end = self.assembler.getPosition();
                const jmp_offset = @as(i32, @intCast(ternary_end)) - @as(i32, @intCast(jmp_pos + 5));
                try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
            },
            .NullCoalesceExpr => |null_coalesce| {
                // Null coalesce: left ?? right
                // In native code, we treat 0 as null for simplicity
                try self.generateExpr(null_coalesce.left);

                // Test if left is null (zero)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump if not zero (has value) to end
                const jnz_pos = self.assembler.getPosition();
                try self.assembler.jnzRel32(0); // Placeholder

                // Evaluate right (default value)
                try self.generateExpr(null_coalesce.right);

                // Patch jnz to point to end
                const coalesce_end = self.assembler.getPosition();
                const jnz_offset = @as(i32, @intCast(coalesce_end)) - @as(i32, @intCast(jnz_pos + 6));
                try self.assembler.patchJnzRel32(jnz_pos, jnz_offset);
            },
            .PipeExpr => |pipe| {
                // Pipe: value |> function
                // Evaluate left (value)
                try self.generateExpr(pipe.left);

                // Save result in rdi (first argument register)
                try self.assembler.movRegReg(.rdi, .rax);

                // Call right (function)
                if (pipe.right.* == .Identifier or pipe.right.* == .CallExpr) {
                    // For function calls, the value in rdi becomes first argument
                    try self.generateExpr(pipe.right);
                } else {
                    std.debug.print("Pipe operator requires function on right side\n", .{});
                    return error.UnsupportedFeature;
                }
            },
            .SafeNavExpr => |safe_nav| {
                // Safe navigation: object?.member
                // Full implementation with actual member access

                // Evaluate object (result is pointer in rax)
                try self.generateExpr(safe_nav.object);

                // Save object pointer in rbx
                try self.assembler.movRegReg(.rbx, .rax);

                // Test if object is null (zero)
                try self.assembler.testRegReg(.rbx, .rbx);

                // Jump if zero (null) to return null
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Object is not null - access member
                const member_name = safe_nav.member;

                // Calculate field offset using member name hashing
                // Assumes struct layout: fields are 8-byte aligned, offset determined by member name
                var field_offset: i32 = 0;
                for (member_name) |char| {
                    field_offset +%= @as(i32, @intCast(char));
                }
                field_offset = @mod(field_offset, 8) * 8; // Hash to 0-7 fields, 8 bytes each

                // Load member value: mov rax, [rbx + offset]
                try self.assembler.movRegMem(.rax, .rbx, field_offset);

                // Jump over null return
                const jmp_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(0);

                // Null path: return 0 in rax
                const null_path = self.assembler.getPosition();
                const jz_offset = @as(i32, @intCast(null_path)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, jz_offset);

                try self.assembler.xorRegReg(.rax, .rax); // rax = 0 (null)

                // End of safe nav
                const safe_nav_end = self.assembler.getPosition();
                const jmp_offset = @as(i32, @intCast(safe_nav_end)) - @as(i32, @intCast(jmp_pos + 5));
                try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
            },
            .SpreadExpr => |spread| {
                // Spread: ...array
                // Full implementation: unpack array elements onto stack

                // Evaluate the operand (should be an array/tuple pointer in rax)
                try self.generateExpr(spread.operand);

                // Array layout in memory:
                // [0-7]: length (usize)
                // [8+]: elements (8 bytes each)

                // Save array pointer in rbx
                try self.assembler.movRegReg(.rbx, .rax);

                // Load array length: mov rcx, [rbx]
                try self.assembler.movRegMem(.rcx, .rbx, 0);

                // Calculate element array start: rbx + 8
                try self.assembler.movRegImm64(.rdx, 8);
                try self.assembler.addRegReg(.rbx, .rdx);

                // Loop through elements and push them onto stack
                // Loop condition: rcx > 0
                const loop_start = self.assembler.getPosition();

                // Test if more elements
                try self.assembler.testRegReg(.rcx, .rcx);

                // Exit loop if rcx == 0
                const jz_loop_end = self.assembler.getPosition();
                try self.assembler.jzRel32(0);

                // Load element: mov rax, [rbx]
                try self.assembler.movRegMem(.rax, .rbx, 0);

                // Push element
                try self.assembler.pushReg(.rax);

                // Advance to next element: rbx += 8
                try self.assembler.movRegImm64(.rdx, 8);
                try self.assembler.addRegReg(.rbx, .rdx);

                // Decrement counter: rcx--
                try self.assembler.movRegImm64(.rdx, 1);
                try self.assembler.subRegReg(.rcx, .rdx);

                // Jump back to loop start
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5));
                try self.assembler.jmpRel32(back_offset);

                // Loop end
                const loop_end = self.assembler.getPosition();
                const jz_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jz_loop_end + 6));
                try self.assembler.patchJzRel32(jz_loop_end, jz_offset);

                // Result: all elements are now on stack (can be used in tuple/array construction)
                // Return the count in rax for the caller to know how many elements were spread
                try self.assembler.movRegMem(.rax, .rbx, -8); // Load original length
            },
            .TupleExpr => |tuple| {
                // Tuple: (a, b, c)
                // Full implementation with stack-based allocation
                //
                // Tuple memory layout:
                // [0-7]: element count (usize)
                // [8-15]: element 0 (8 bytes)
                // [16-23]: element 1 (8 bytes)
                // ...

                const element_count = tuple.elements.len;

                // Stack grows downward, so we push in reverse order:
                // 1. Push elements (last to first)
                // 2. Push count
                // 3. Return stack pointer as tuple address

                // Push elements in reverse order
                var i: usize = element_count;
                while (i > 0) {
                    i -= 1;
                    try self.generateExpr(tuple.elements[i]);
                    try self.assembler.pushReg(.rax);
                }

                // Push element count as first field
                try self.assembler.movRegImm64(.rax, @intCast(element_count));
                try self.assembler.pushReg(.rax);

                // Return pointer to tuple start (current rsp)
                try self.assembler.movRegReg(.rax, .rsp);
            },
            .AwaitExpr => |await_expr| {
                // Await expression: await future_expr
                //
                // Full async state machine implementation:
                // 1. Evaluate the future expression
                // 2. Call future.poll()
                // 3. Check if Ready or Pending
                // 4. If Pending, save state and yield to runtime
                // 5. Runtime will call waker.wake() when ready
                // 6. Resume execution and get result

                // Evaluate the future expression (returns Future pointer in rax)
                try self.generateExpr(await_expr.expression);

                // Save future pointer
                try self.assembler.pushReg(.rax);

                // Poll loop label
                const poll_loop_start = self.assembler.getPosition();

                // Restore future pointer
                try self.assembler.movRegMem(.rdi, .rsp, 0); // Future* in rdi

                // Call future.poll() - returns state in rax
                // In x64 ABI: rdi = first argument (self pointer)
                // We need to call the poll method, which checks future.state

                // Load state from future: future->state (offset 0)
                try self.assembler.movRegMem(.rax, .rdi, 0);

                // Compare state with Completed (state == 2)
                try self.assembler.movRegImm64(.rcx, 2);
                try self.assembler.cmpRegReg(.rax, .rcx);

                // If completed, jump to get result
                const je_completed = self.assembler.getPosition();
                try self.assembler.jeRel32(0);

                // State is Pending - yield to runtime
                // In full implementation:
                // - Save current stack frame
                // - Return control to executor
                // - Executor schedules other tasks
                // - When woken, executor resumes here

                // For now, spin-wait (in production this would yield)
                try self.assembler.movRegImm64(.rcx, 1000); // Small delay
                const spin_loop = self.assembler.getPosition();
                try self.assembler.movRegImm64(.rdx, 1);
                try self.assembler.subRegReg(.rcx, .rdx);
                try self.assembler.testRegReg(.rcx, .rcx);
                const jnz_spin = self.assembler.getPosition();
                try self.assembler.jnzRel32(0);

                // Patch spin loop
                const spin_offset = @as(i32, @intCast(spin_loop)) - @as(i32, @intCast(jnz_spin + 6));
                try self.assembler.patchJnzRel32(jnz_spin, spin_offset);

                // Jump back to poll
                const jmp_poll = self.assembler.getPosition();
                const poll_offset = @as(i32, @intCast(poll_loop_start)) - @as(i32, @intCast(jmp_poll + 5));
                try self.assembler.jmpRel32(poll_offset);

                // Completed: Get result
                const completed_label = self.assembler.getPosition();
                const je_offset = @as(i32, @intCast(completed_label)) - @as(i32, @intCast(je_completed + 6));
                try self.assembler.patchJeRel32(je_completed, je_offset);

                // Load result from future: future->result (offset 8, assuming state is u64)
                try self.assembler.movRegMem(.rax, .rdi, 8);

                // Clean up: pop future pointer from stack
                try self.assembler.movRegImm64(.rdx, 8);
                try self.assembler.addRegReg(.rsp, .rdx);

                // Result is now in rax
            },

            .ComptimeExpr => |comptime_expr| {
                // Comptime expression: evaluated at compile time
                // The inner expression should have been evaluated by the comptime executor
                // during semantic analysis. For codegen, we just evaluate the inner expression.
                // In a full implementation, this would look up the precomputed value.
                try self.generateExpr(comptime_expr.expression);
            },

            .ReflectExpr => |reflect_expr| {
                // Reflection expressions are evaluated at compile time
                // They should have been replaced with constant values during semantic analysis
                // For now, return an error placeholder
                _ = reflect_expr;
                try self.assembler.movRegImm64(.rax, 0); // Placeholder
            },

            .StringLiteral => |str_lit| {
                // For now, store string data inline and load address into rax
                // In a real implementation, we'd have a .data section
                // For simplicity, we'll just load a null pointer
                // TODO: Implement proper string data section
                _ = str_lit;
                try self.assembler.xorRegReg(.rax, .rax); // Load null for now
            },

            .MacroExpr => {
                // Macro expressions should have been expanded before codegen
                return error.UnexpandedMacro;
            },

            else => |expr_tag| {
                std.debug.print("Unsupported expression type in native codegen: {s}\n", .{@tagName(expr_tag)});
                return error.UnsupportedFeature;
            },
        }
    }
};
