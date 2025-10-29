// Home Compiler - Compile .home files to native code
// Usage: home compile <input.home> -o <output.o>

const std = @import("std");
const Lexer = @import("lexer").Lexer;
const Parser = @import("parser").Parser;
const ast = @import("ast");
const codegen = @import("codegen");
const HomeKernelCodegen = codegen.home_kernel_codegen.HomeKernelCodegen;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(args[0]);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "compile")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing input file\n\n", .{});
            try printUsage(args[0]);
            std.process.exit(1);
        }

        try compileFile(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "build")) {
        try buildProject(allocator, args[2..]);
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        try printUsage(args[0]);
        std.process.exit(1);
    }
}

fn printUsage(program_name: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Home Programming Language Compiler
        \\
        \\Usage:
        \\  {s} compile <input.home> [options]
        \\  {s} build [options]
        \\
        \\Options:
        \\  -o <file>        Output file path
        \\  --kernel         Generate kernel-mode code
        \\  --asm            Generate assembly (.s) instead of object (.o)
        \\  --verbose        Print compilation details
        \\
        \\Examples:
        \\  {s} compile kernel.home -o kernel.o --kernel
        \\  {s} compile main.home -o main.s --asm
        \\  {s} build
        \\
    , .{program_name, program_name, program_name, program_name, program_name});
}

fn compileFile(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: No input file specified\n", .{});
        std.process.exit(1);
    }

    const input_path = args[0];

    // Parse options
    var output_path: ?[]const u8 = null;
    var kernel_mode = false;
    var asm_mode = false;
    var verbose = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: -o requires an argument\n", .{});
                std.process.exit(1);
            }
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--kernel")) {
            kernel_mode = true;
        } else if (std.mem.eql(u8, arg, "--asm")) {
            asm_mode = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    // Default output path
    if (output_path == null) {
        if (asm_mode) {
            output_path = "output.s";
        } else {
            output_path = "output.o";
        }
    }

    if (verbose) {
        std.debug.print("Compiling: {s}\n", .{input_path});
        std.debug.print("Output: {s}\n", .{output_path.?});
        std.debug.print("Kernel mode: {}\n", .{kernel_mode});
        std.debug.print("Assembly mode: {}\n\n", .{asm_mode});
    }

    // Read input file
    const source = try std.fs.cwd().readFileAlloc(allocator, input_path, 1024 * 1024);
    defer allocator.free(source);

    // Lex
    if (verbose) std.debug.print("Lexing...\n", .{});
    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    if (verbose) std.debug.print("Tokens: {d}\n", .{tokens.items.len});

    // Parse
    if (verbose) std.debug.print("Parsing...\n", .{});
    var parser = try Parser.init(allocator, tokens.items);
    const program = try parser.parse();

    if (verbose) std.debug.print("Statements: {d}\n", .{program.statements.len});

    // Code generation
    if (verbose) std.debug.print("Generating code...\n", .{});

    var output_code: []const u8 = undefined;

    if (kernel_mode) {
        // Use kernel codegen
        var kernel_codegen = HomeKernelCodegen.init(
            allocator,
            &parser.symbol_table,
            &parser.module_resolver,
        );
        defer kernel_codegen.deinit();

        output_code = try kernel_codegen.generate(program);
    } else {
        // Use regular codegen
        std.debug.print("Error: Only kernel mode is currently supported\n", .{});
        std.debug.print("Use --kernel flag\n", .{});
        std.process.exit(1);
    }

    if (verbose) {
        std.debug.print("Generated {d} bytes of assembly\n", .{output_code.len});
    }

    // Write output
    if (asm_mode) {
        // Write assembly file directly
        try std.fs.cwd().writeFile(.{
            .sub_path = output_path.?,
            .data = output_code,
        });

        if (verbose) {
            std.debug.print("Wrote assembly to: {s}\n", .{output_path.?});
        }
    } else {
        // Write assembly to temporary file, then assemble with `as`
        const asm_temp = try std.fmt.allocPrint(allocator, "{s}.s", .{output_path.?});
        defer allocator.free(asm_temp);

        try std.fs.cwd().writeFile(.{
            .sub_path = asm_temp,
            .data = output_code,
        });

        if (verbose) {
            std.debug.print("Assembling {s}...\n", .{asm_temp});
        }

        // Run assembler
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "as",
                asm_temp,
                "-o",
                output_path.?,
            },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("Assembler failed:\n{s}\n", .{result.stderr});
            std.process.exit(1);
        }

        // Clean up temp file
        try std.fs.cwd().deleteFile(asm_temp);

        if (verbose) {
            std.debug.print("Wrote object file to: {s}\n", .{output_path.?});
        }
    }

    std.debug.print("Compilation successful!\n", .{});
}

fn buildProject(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;
    _ = allocator;
    std.debug.print("Build command not yet implemented\n", .{});
    std.debug.print("Use 'compile' command for now\n", .{});
    std.process.exit(1);
}
