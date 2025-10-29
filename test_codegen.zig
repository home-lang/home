// Quick test of Home kernel codegen
const std = @import("std");

// Import the components directly
const Lexer = @import("/Users/chrisbreuer/Code/home/packages/lexer/src/lexer.zig").Lexer;
const Parser = @import("/Users/chrisbreuer/Code/home/packages/parser/src/parser.zig").Parser;
const HomeKernelCodegen = @import("/Users/chrisbreuer/Code/home/packages/codegen/src/home_kernel_codegen.zig").HomeKernelCodegen;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simple Home test code
    const source =
        \\export fn kernel_main(magic: u32, boot_info: u32) -> never {
        \\  let x: u32 = 42
        \\  loop {
        \\    // halt
        \\  }
        \\}
    ;

    std.debug.print("Testing Home kernel codegen...\n", .{});
    std.debug.print("Source ({} bytes):\n{s}\n\n", .{ source.len, source });

    // Lex
    std.debug.print("Step 1: Lexing...\n", .{});
    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);
    std.debug.print("  ✓ Generated {} tokens\n\n", .{tokens.items.len});

    // Parse
    std.debug.print("Step 2: Parsing...\n", .{});
    var parser = try Parser.init(allocator, tokens.items);
    const program = try parser.parse();
    std.debug.print("  ✓ Parsed {} statements\n\n", .{program.statements.len});

    // Generate code
    std.debug.print("Step 3: Generating assembly...\n", .{});
    var codegen = HomeKernelCodegen.init(
        allocator,
        &parser.symbol_table,
        &parser.module_resolver,
    );
    defer codegen.deinit();

    const asm_code = try codegen.generate(program);
    std.debug.print("  ✓ Generated {} bytes of assembly\n\n", .{asm_code.len});

    std.debug.print("Generated Assembly:\n{s}\n", .{asm_code});

    std.debug.print("\n✅ Test passed!\n", .{});
}
