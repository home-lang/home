const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ast = @import("ast");
const arm64 = @import("arm64.zig");
const macho = @import("macho.zig");

/// AArch64 native codegen — M1 subset of issue #5 (Path B-lite).
///
/// Mirrors the structure of `native_codegen.NativeCodegen` but emits arm64
/// machine code via `arm64.Assembler`. Currently supports only:
///   - top-level `FnDecl` named `main`
///   - `ReturnStmt` with an integer literal value
///
/// Other AST nodes return `error.NotImplementedM1`. The plan is to expand
/// this milestone-by-milestone (M2 = arithmetic + locals, M3 = conditionals,
/// etc.) per the B-lite roadmap, rather than refactoring NativeCodegen
/// itself.
pub const CodegenError = error{
    NotImplementedM1,
    UnsupportedPlatform,
    IntegerLiteralOutOfRange,
    FileSystemAccessDenied,
} || std.mem.Allocator.Error;

pub const Aarch64NativeCodegen = struct {
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    assembler: arm64.Assembler,
    functions: std.StringHashMap(usize),
    current_function_name: ?[]const u8 = null,
    io: ?Io = null,

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) Aarch64NativeCodegen {
        return .{
            .allocator = allocator,
            .program = program,
            .assembler = arm64.Assembler.init(allocator),
            .functions = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Aarch64NativeCodegen) void {
        self.assembler.deinit();
        self.functions.deinit();
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
            .ReturnStmt => |ret| try self.generateReturn(ret),
            .ExprStmt => |expr| try self.generateExpr(expr),
            else => return error.NotImplementedM1,
        }
    }

    fn generateFnDecl(self: *Aarch64NativeCodegen, func: *ast.FnDecl) CodegenError!void {
        const offset = self.assembler.getPosition();
        try self.functions.put(func.name, offset);

        const prev_name = self.current_function_name;
        self.current_function_name = func.name;
        defer self.current_function_name = prev_name;

        // `main` doesn't return to a caller — its `return` lowers to an
        // exit syscall, so no prologue / epilogue. Other functions get the
        // standard AAPCS64 prologue (saving FP/LR) from the assembler.
        const is_main = std.mem.eql(u8, func.name, "main");
        if (!is_main) {
            try self.assembler.functionPrologue();
        }

        for (func.body.statements) |stmt| {
            try self.generateStmt(stmt);
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
            else => return error.NotImplementedM1,
        }
    }
};
