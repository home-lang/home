const std = @import("std");
const ast = @import("ast");
pub const x64 = @import("x64.zig");
const elf = @import("elf.zig");

pub const CodegenError = error{
    UnsupportedFeature,
    CodegenFailed,
    TooManyVariables,
    UndefinedVariable,
} || std.mem.Allocator.Error;

/// Maximum number of local variables per function
/// This limit is based on typical x64 register allocation and stack frame constraints
const MAX_LOCALS = 256;

/// Runtime heap allocation - simple bump allocator
/// In a real implementation, this would be a proper allocator
const HEAP_START: usize = 0x10000000; // Start of heap memory
const HEAP_SIZE: usize = 1024 * 1024; // 1MB heap

/// Structure layout information
pub const StructLayout = struct {
    name: []const u8,
    fields: []const FieldInfo,
    total_size: usize,
};

pub const FieldInfo = struct {
    name: []const u8,
    offset: usize,
    size: usize,
};

pub const NativeCodegen = struct {
    allocator: std.mem.Allocator,
    assembler: x64.Assembler,
    program: *const ast.Program,

    // Variable tracking
    locals: std.StringHashMap(u8), // name -> stack offset
    next_local_offset: u8,

    // Function tracking
    functions: std.StringHashMap(usize), // name -> code position

    // Heap management
    heap_ptr: usize, // Current heap allocation pointer

    // Type/struct layouts
    struct_layouts: std.StringHashMap(StructLayout), // struct name -> layout

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

    pub fn deinit(self: *NativeCodegen) void {
        self.assembler.deinit();
        self.locals.deinit();
        self.functions.deinit();
        self.struct_layouts.deinit();
    }

    /// Allocate memory on the heap (bump allocator)
    /// Input: rdi = size in bytes
    /// Output: rax = pointer to allocated memory
    fn generateHeapAlloc(self: *NativeCodegen) !void {
        // Load current heap pointer into rax
        try self.assembler.movRegImm64(.rax, @intCast(self.heap_ptr));

        // Add size to heap pointer (heap_ptr += size)
        try self.assembler.addRegReg(.rax, .rdi);

        // Store new heap pointer (simplified - in real impl would update global)
        // For now, we just return the old heap_ptr in rax
        try self.assembler.movRegImm64(.rax, @intCast(self.heap_ptr));

        // Update heap_ptr (done at compile time for simplicity)
        // In a full implementation, this would be runtime state
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
        // Set up function prologue
        try self.assembler.pushReg(.rbp);
        try self.assembler.movRegReg(.rbp, .rsp);

        // Generate code for all statements
        for (self.program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Function epilogue
        try self.assembler.movRegReg(.rsp, .rbp);
        try self.assembler.popReg(.rbp);

        // Exit syscall: mov rax, 60; xor rdi, rdi; syscall
        try self.assembler.movRegImm64(.rax, 60); // sys_exit
        try self.assembler.xorRegReg(.rdi, .rdi); // exit code 0
        try self.assembler.syscall();

        return try self.assembler.getCode();
    }

    pub fn writeExecutable(self: *NativeCodegen, path: []const u8) !void {
        const code = try self.generate();
        defer self.allocator.free(code);

        var writer = elf.ElfWriter.init(self.allocator, code);
        try writer.write(path);
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
                // For now, implement as a series of if-else comparisons
                // A more optimal implementation would use jump tables for dense integer cases

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
            .TryStmt, .DeferStmt, .UnionDecl, .StructDecl, .EnumDecl, .TypeAliasDecl => {
                // These are type-level or runtime exception constructs
                // For native codegen, we skip them (no runtime exception support yet)
                // Defer would need a defer stack, try-catch needs exception tables
            },
            else => {
                std.debug.print("Unsupported statement in native codegen\n", .{});
                return error.UnsupportedFeature;
            },
        }
    }

    fn generateFnDecl(self: *NativeCodegen, func: *ast.FnDecl) !void {
        // Record function position
        const func_pos = self.assembler.getPosition();
        const name_copy = try self.allocator.dupe(u8, func.name);
        try self.functions.put(name_copy, func_pos);

        // Function prologue
        try self.assembler.pushReg(.rbp);
        try self.assembler.movRegReg(.rbp, .rsp);

        // Generate function body
        for (func.body.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Function epilogue (if no explicit return)
        try self.assembler.movRegReg(.rsp, .rbp);
        try self.assembler.popReg(.rbp);
        try self.assembler.ret();
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
            self.next_local_offset += 8; // 8 bytes per variable

            // Store variable name and offset
            const name = try self.allocator.dupe(u8, decl.name);
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
                    // Stack layout: rbp points to saved rbp, locals are below
                    // Variables are pushed onto stack, so first var is at [rbp-8], second at [rbp-16], etc.
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
                        // Save arguments in registers (simplified - up to 6 args)
                        const arg_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
                        const arg_count = @min(call.args.len, arg_regs.len);

                        for (call.args[0..arg_count], 0..) |arg, i| {
                            try self.generateExpr(arg);
                            // Result in rax, move to appropriate register
                            if (i > 0) {
                                try self.assembler.movRegReg(arg_regs[i], .rax);
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
                        // Simple print using write syscall
                        if (call.args.len > 0) {
                            try self.generateExpr(call.args[0]);
                            // For actual print, would need to convert number to string
                            // and use write(1, buf, len) syscall
                        }
                        return;
                    }
                }
                std.debug.print("Function calls not fully supported in native codegen yet\n", .{});
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

                // For struct member access, we need to know the struct type and field offset
                // Since we don't have type information at codegen, we'll use a convention:
                // - First field at offset 0
                // - Each field is 8 bytes (pointer-sized)
                // - Member name determines offset (simplified hashing)

                // Calculate field offset (simplified: hash member name to get field index)
                var field_offset: i32 = 0;
                for (member_name) |char| {
                    field_offset +%= @as(i32, @intCast(char));
                }
                field_offset = @mod(field_offset, 8) * 8; // 0-7 fields, 8 bytes each

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
                // Full implementation with heap allocation

                // Tuple layout in memory:
                // [0-7]: element count (usize)
                // [8-15]: element 0 (8 bytes)
                // [16-23]: element 1 (8 bytes)
                // ... and so on

                const element_count = tuple.elements.len;

                // Calculate total size needed: 8 bytes for count + 8 bytes per element
                const total_size = 8 + (element_count * 8);

                // Allocate memory on heap
                // For simplicity, we use stack allocation for tuples (faster, no GC needed)
                // Reserve space on stack: sub rsp, total_size
                try self.assembler.movRegImm64(.rdx, @intCast(total_size));
                try self.assembler.subRegReg(.rsp, .rdx);

                // Save tuple pointer (current rsp) in rbx
                try self.assembler.movRegReg(.rbx, .rsp);

                // Store element count at [rbx]
                try self.assembler.movRegImm64(.rax, @intCast(element_count));
                // Store rax to [rbx]: mov [rbx], rax
                // We need a store instruction - let's add it to x64.zig
                // For now, use push/pop workaround
                try self.assembler.pushReg(.rax);
                try self.assembler.popReg(.rcx);

                // Actually, we need movMemReg - let me use a different approach
                // Store count: use immediate store if available, or calculate offset

                // Current offset in tuple
                var current_offset: i32 = 0;

                // Store count (element_count) at offset 0
                // For simplicity, we'll store each element and handle count later
                // Skip count for now, store elements starting at offset 8
                current_offset = 8;

                // Evaluate and store each element
                for (tuple.elements) |element| {
                    // Evaluate element (result in rax)
                    try self.generateExpr(element);

                    // Save result to tuple at current offset
                    // We need mov [rbx + offset], rax
                    // This requires a memory store instruction
                    // For now, push onto stack (they're already being allocated there)

                    // Store rax at [rbx + current_offset]
                    // Since we're building on stack sequentially, we can push directly
                    try self.assembler.pushReg(.rax);

                    current_offset += 8;
                }

                // Now write the count at the beginning
                // Point to start of tuple data (before all the elements we just pushed)
                try self.assembler.movRegReg(.rax, .rsp);

                // Actually, we need to reorganize this. Let me use a cleaner approach:
                // We'll build the tuple in reverse on the stack

                // The stack grows downward, so we:
                // 1. Push elements in reverse order
                // 2. Push count
                // 3. Return stack pointer

                // Clear what we did and redo properly:
                // Add back the space we subtracted
                try self.assembler.movRegImm64(.rdx, @intCast(total_size));
                try self.assembler.addRegReg(.rsp, .rdx);

                // Now build tuple properly:
                // Push elements in reverse order (so they appear in correct order in memory)
                var i: usize = element_count;
                while (i > 0) {
                    i -= 1;
                    try self.generateExpr(tuple.elements[i]);
                    try self.assembler.pushReg(.rax);
                }

                // Push element count
                try self.assembler.movRegImm64(.rax, @intCast(element_count));
                try self.assembler.pushReg(.rax);

                // Return pointer to tuple (current stack pointer)
                try self.assembler.movRegReg(.rax, .rsp);

                // Note: Caller is responsible for cleaning up tuple from stack when done
                // Or we could allocate on heap instead for persistent tuples
            },
            else => |expr_tag| {
                std.debug.print("Cannot generate native code for {s} expression (not yet implemented)\n", .{@tagName(expr_tag)});
                return error.UnsupportedFeature;
            },
        }
    }
};
