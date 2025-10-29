// Home Kernel Code Generator
// Compiles Home language kernel code to native x86-64 assembly
// with FFI calls to Zig stdlib modules

const std = @import("std");
const ast = @import("ast");
const parser_mod = @import("parser");
const Parser = parser_mod.Parser;
const SymbolTable = parser_mod.SymbolTable;
const ModuleResolver = parser_mod.ModuleResolver;
const Symbol = parser_mod.Symbol;
const kernel_codegen = @import("kernel_codegen.zig");

/// Kernel code generator with Home language support
pub const HomeKernelCodegen = struct {
    allocator: std.mem.Allocator,
    /// Symbol table from parser (contains imported modules)
    symbol_table: *SymbolTable,
    /// Module resolver for finding imports
    module_resolver: *ModuleResolver,
    /// Output assembly code
    output: std.ArrayList(u8),
    /// Kernel codegen options
    kernel_opts: kernel_codegen.KernelCodegenOptions,

    pub fn init(
        allocator: std.mem.Allocator,
        symbol_table: *SymbolTable,
        module_resolver: *ModuleResolver,
    ) HomeKernelCodegen {
        var result: HomeKernelCodegen = undefined;
        result.allocator = allocator;
        result.symbol_table = symbol_table;
        result.module_resolver = module_resolver;
        result.output = .{ .items = &[_]u8{}, .capacity = 0 };
        result.kernel_opts = kernel_codegen.KernelCodegenOptions{};
        return result;
    }

    pub fn deinit(self: *HomeKernelCodegen) void {
        self.output.deinit(self.allocator);
    }

    /// Generate kernel code from Home AST
    pub fn generate(self: *HomeKernelCodegen, program: *const ast.Program) ![]const u8 {
        const writer = self.output.writer(self.allocator);

        // Emit assembly header
        try writer.writeAll(
            \\.section .text
            \\.global kernel_main
            \\
            \\
        );

        // Generate code for each statement
        for (program.statements) |stmt| {
            try self.generateStmt(writer, stmt);
        }

        return self.output.items;
    }

    fn generateStmt(self: *HomeKernelCodegen, writer: anytype, stmt: ast.Stmt) !void {
        switch (stmt) {
            .FnDecl => |func| {
                // Check if this is an exported function (like kernel_main)
                // For now, export functions that start with "kernel_" or are named "main"
                const is_export = std.mem.startsWith(u8, func.name, "kernel_") or
                    std.mem.eql(u8, func.name, "main");

                if (is_export) {
                    try writer.print(".global {s}\n", .{func.name});
                }

                try writer.print("{s}:\n", .{func.name});

                // Function prologue
                const attrs = kernel_codegen.FunctionAttributes{
                    .noreturn = if (func.return_type) |rt|
                        std.mem.eql(u8, rt, "never")
                    else
                        false,
                };

                try writer.writeAll("    pushq %rbp\n");
                try writer.writeAll("    movq %rsp, %rbp\n");

                // Generate function body
                for (func.body.statements) |body_stmt| {
                    try self.generateStmt(writer, body_stmt);
                }

                // Function epilogue (if not noreturn)
                if (!attrs.noreturn) {
                    try writer.writeAll("    movq %rbp, %rsp\n");
                    try writer.writeAll("    popq %rbp\n");
                    try writer.writeAll("    ret\n");
                }

                try writer.writeAll("\n");
            },
            .ExprStmt => |expr| {
                try self.generateExpr(writer, expr);
            },
            .LetDecl => |decl| {
                // Variable declaration
                if (decl.value) |value| {
                    try self.generateExpr(writer, value);
                    // TODO: Store in local variable on stack
                }
            },
            .IfStmt => |if_stmt| {
                // Generate if statement
                try self.generateExpr(writer, if_stmt.condition);

                // Test condition (result in %rax)
                try writer.writeAll("    testq %rax, %rax\n");

                // Generate unique labels
                const label_num = @intFromPtr(if_stmt);
                try writer.print("    jz .L_else_{d}\n", .{label_num});

                // Then block
                for (if_stmt.then_block.statements) |then_stmt| {
                    try self.generateStmt(writer, then_stmt);
                }

                if (if_stmt.else_block) |else_block| {
                    try writer.print("    jmp .L_endif_{d}\n", .{label_num});
                    try writer.print(".L_else_{d}:\n", .{label_num});

                    for (else_block.statements) |else_stmt| {
                        try self.generateStmt(writer, else_stmt);
                    }

                    try writer.print(".L_endif_{d}:\n", .{label_num});
                } else {
                    try writer.print(".L_else_{d}:\n", .{label_num});
                }
            },
            .WhileStmt => |while_stmt| {
                const label_num = @intFromPtr(while_stmt);

                try writer.print(".L_while_start_{d}:\n", .{label_num});

                // Condition
                try self.generateExpr(writer, while_stmt.condition);
                try writer.writeAll("    testq %rax, %rax\n");
                try writer.print("    jz .L_while_end_{d}\n", .{label_num});

                // Body
                for (while_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(writer, body_stmt);
                }

                try writer.print("    jmp .L_while_start_{d}\n", .{label_num});
                try writer.print(".L_while_end_{d}:\n", .{label_num});
            },
            .ReturnStmt => |return_stmt| {
                // Generate return statement
                // If there's a return value, evaluate it (result goes in %rax)
                if (return_stmt.value) |value| {
                    try self.generateExpr(writer, value);
                }

                // Restore stack frame and return
                try writer.writeAll("    movq %rbp, %rsp\n");
                try writer.writeAll("    popq %rbp\n");
                try writer.writeAll("    ret\n");
            },
            else => {
                // Unsupported statement type - skip for now
            },
        }
    }

    fn generateExpr(self: *HomeKernelCodegen, writer: anytype, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .IntegerLiteral => |lit| {
                // Load immediate value into %rax
                try writer.print("    movq ${d}, %rax\n", .{lit.value});
            },
            .BooleanLiteral => |lit| {
                // Load boolean as integer (0 or 1) into %rax
                try writer.print("    movq ${d}, %rax\n", .{if (lit.value) @as(i64, 1) else @as(i64, 0)});
            },
            .InlineAsm => |asm_node| {
                // Emit inline assembly instruction directly
                try writer.print("    {s}\n", .{asm_node.instruction});
            },
            .StringLiteral => |lit| {
                // Create string constant in .rodata
                const label_num = @intFromPtr(lit.value.ptr);
                try writer.print("    leaq .L_str_{d}(%rip), %rax\n", .{label_num});

                // We'll emit the string data at the end
                // TODO: Collect string literals and emit in .rodata section
            },
            .CallExpr => |call| {
                // Check if this is a module member call (e.g., serial.init())
                if (call.callee.* == .MemberExpr) {
                    const member = call.callee.MemberExpr;

                    // Get module name from object
                    if (member.object.* == .Identifier) {
                        const module_name = member.object.Identifier.name;
                        const func_name = member.member;

                        // Look up the symbol in the symbol table
                        if (self.symbol_table.lookupMemberSymbol(module_name, func_name)) |symbol| {
                            // Generate FFI call to Zig function
                            try self.generateFFICall(writer, symbol, call.args);
                        } else {
                            std.debug.print("Unknown symbol: {s}.{s}\n", .{module_name, func_name});
                        }
                    }
                } else if (call.callee.* == .Identifier) {
                    // Direct function call
                    const func_name = call.callee.Identifier.name;

                    // Check if it's a known symbol
                    if (self.symbol_table.lookupSymbol(func_name)) |symbol| {
                        try self.generateFFICall(writer, symbol, call.args);
                    } else {
                        // Local function call
                        // Evaluate arguments (System V AMD64 ABI: rdi, rsi, rdx, rcx, r8, r9)
                        const arg_regs = [_][]const u8{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" };

                        // To handle multiple arguments correctly, we need to save previous args
                        // Strategy: evaluate in reverse order and push to stack, then pop into registers
                        if (call.args.len > 0) {
                            // Evaluate all arguments and push them to stack in reverse order
                            var i: usize = call.args.len;
                            while (i > 0) {
                                i -= 1;
                                try self.generateExpr(writer, call.args[i]);
                                try writer.writeAll("    pushq %rax\n");
                            }

                            // Pop arguments into registers in correct order
                            for (0..call.args.len) |reg_idx| {
                                if (reg_idx < arg_regs.len) {
                                    try writer.print("    popq %{s}\n", .{arg_regs[reg_idx]});
                                } else {
                                    // Arguments beyond 6 stay on stack for the call
                                    break;
                                }
                            }
                        }

                        // Call function
                        try writer.print("    call {s}\n", .{func_name});
                    }
                }
            },
            .BinaryExpr => |binary| {
                // Evaluate right operand
                try self.generateExpr(writer, binary.right);
                try writer.writeAll("    pushq %rax\n");

                // Evaluate left operand
                try self.generateExpr(writer, binary.left);

                // Pop right operand
                try writer.writeAll("    popq %rcx\n");

                // Perform operation
                switch (binary.op) {
                    .Add => try writer.writeAll("    addq %rcx, %rax\n"),
                    .Sub => try writer.writeAll("    subq %rcx, %rax\n"),
                    .Equal => {
                        try writer.writeAll("    cmpq %rcx, %rax\n");
                        try writer.writeAll("    sete %al\n");
                        try writer.writeAll("    movzbq %al, %rax\n");
                    },
                    .NotEqual => {
                        try writer.writeAll("    cmpq %rcx, %rax\n");
                        try writer.writeAll("    setne %al\n");
                        try writer.writeAll("    movzbq %al, %rax\n");
                    },
                    else => {},
                }
            },
            .Identifier => |id| {
                // Load variable
                // TODO: Track variable offsets on stack
                try writer.print("    # Load variable {s}\n", .{id.name});
            },
            else => {
                // Unsupported expression - skip
            },
        }
    }

    /// Generate FFI call to a Zig function from imported module
    fn generateFFICall(
        self: *HomeKernelCodegen,
        writer: anytype,
        symbol: Symbol,
        args: []const *const ast.Expr,
    ) !void {
        // Build the full symbol name for FFI
        // e.g., "serial.init" becomes "basics_os_serial_init"
        var ffi_name: std.ArrayList(u8) = .{ .items = &[_]u8{}, .capacity = 0 };
        defer ffi_name.deinit(self.allocator);

        // Convert module path to C-compatible name
        for (symbol.module_path) |segment| {
            try ffi_name.appendSlice(self.allocator, segment);
            try ffi_name.append(self.allocator, '_');
        }
        try ffi_name.appendSlice(self.allocator, symbol.name);

        // Evaluate arguments according to System V AMD64 ABI
        // First 6 integer args: rdi, rsi, rdx, rcx, r8, r9
        const arg_regs = [_][]const u8{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" };

        // Save previous register values if needed
        for (args, 0..) |arg, i| {
            if (i < arg_regs.len) {
                // Evaluate argument (result in %rax)
                try self.generateExpr(writer, arg);

                // Move to appropriate argument register
                if (i == 0) {
                    try writer.print("    movq %rax, %{s}\n", .{arg_regs[i]});
                } else {
                    try writer.print("    movq %rax, %{s}\n", .{arg_regs[i]});
                }
            } else {
                // Push additional arguments onto stack
                try self.generateExpr(writer, arg);
                try writer.writeAll("    pushq %rax\n");
            }
        }

        // Call the external Zig function
        try writer.print("    call {s}\n", .{ffi_name.items});

        // Clean up stack if we pushed extra arguments
        if (args.len > arg_regs.len) {
            const stack_bytes = (args.len - arg_regs.len) * 8;
            try writer.print("    addq ${d}, %rsp\n", .{stack_bytes});
        }
    }
};

// Tests
test "home kernel codegen basics" {
    const allocator = std.testing.allocator;

    var symbol_table = SymbolTable.init(allocator);
    defer symbol_table.deinit();

    var module_resolver = try ModuleResolver.init(allocator);
    defer module_resolver.deinit();

    var codegen = HomeKernelCodegen.init(allocator, &symbol_table, &module_resolver);
    defer codegen.deinit();

    // Test basic initialization
    try std.testing.expect(codegen.output.items.len == 0);
}
