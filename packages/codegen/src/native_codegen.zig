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

pub const NativeCodegen = struct {
    allocator: std.mem.Allocator,
    assembler: x64.Assembler,
    program: *const ast.Program,

    // Variable tracking
    locals: std.StringHashMap(u8), // name -> stack offset
    next_local_offset: u8,

    // Function tracking
    functions: std.StringHashMap(usize), // name -> code position

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) NativeCodegen {
        return .{
            .allocator = allocator,
            .assembler = x64.Assembler.init(allocator),
            .program = program,
            .locals = std.StringHashMap(u8).init(allocator),
            .next_local_offset = 0,
            .functions = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *NativeCodegen) void {
        self.assembler.deinit();
        self.locals.deinit();
        self.functions.deinit();
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
            else => |expr_tag| {
                std.debug.print("Cannot generate native code for {s} expression (not yet implemented)\n", .{@tagName(expr_tag)});
                return error.UnsupportedFeature;
            },
        }
    }
};
