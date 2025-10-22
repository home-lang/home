const std = @import("std");
const Lexer = @import("lexer/lexer.zig").Lexer;
const Parser = @import("parser/parser.zig").Parser;
const ast = @import("ast/ast.zig");
const Interpreter = @import("interpreter/interpreter.zig").Interpreter;
const NativeCodegen = @import("codegen/native_codegen.zig").NativeCodegen;

const Color = enum {
    Reset,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,

    fn code(self: Color) []const u8 {
        return switch (self) {
            .Reset => "\x1b[0m",
            .Red => "\x1b[31m",
            .Green => "\x1b[32m",
            .Yellow => "\x1b[33m",
            .Blue => "\x1b[34m",
            .Magenta => "\x1b[35m",
            .Cyan => "\x1b[36m",
        };
    }
};

fn printUsage() void {
    std.debug.print(
        \\{s}Ion Compiler{s} - The speed of Zig. The safety of Rust. The joy of TypeScript.
        \\
        \\{s}Usage:{s}
        \\  ion <command> [arguments]
        \\
        \\{s}Commands:{s}
        \\  parse <file>    Tokenize an Ion file and display tokens
        \\  ast <file>      Parse an Ion file and display the AST
        \\  run <file>      Execute an Ion file directly
        \\  build <file>    Compile an Ion file to a native binary
        \\  help            Display this help message
        \\
        \\{s}Examples:{s}
        \\  ion parse hello.ion
        \\  ion ast hello.ion
        \\  ion run hello.ion
        \\  ion build hello.ion -o hello
        \\  ion help
        \\
    , .{ Color.Blue.code(), Color.Reset.code(), Color.Green.code(), Color.Reset.code(), Color.Green.code(), Color.Reset.code(), Color.Green.code(), Color.Reset.code() });
}

fn parseCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    // Tokenize
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Print header
    std.debug.print("{s}Parsing:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    std.debug.print("{s}Tokens:{s} {d}\n\n", .{ Color.Blue.code(), Color.Reset.code(), tokens.items.len });

    // Print tokens with color
    for (tokens.items) |token| {
        const color = switch (token.type) {
            .Fn, .Let, .Const, .If, .Else, .Return, .Struct, .Enum, .Match, .For, .While, .Loop, .Import, .Async, .Await, .Comptime => Color.Magenta,
            .String => Color.Green,
            .Integer, .Float => Color.Yellow,
            .Identifier => Color.Cyan,
            .Eof => Color.Blue,
            else => Color.Reset,
        };

        std.debug.print("{s}{s:<16} '{s}' ({d}:{d}){s}\n", .{
            color.code(),
            @tagName(token.type),
            token.lexeme,
            token.line,
            token.column,
            Color.Reset.code(),
        });
    }

    std.debug.print("\n{s}Success:{s} Parsed {d} tokens\n", .{ Color.Green.code(), Color.Reset.code(), tokens.items.len });
}

fn printIndent(indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        std.debug.print("  ", .{});
    }
}

fn printExpr(expr: *const ast.Expr, indent: usize) void {
    switch (expr.*) {
        .IntegerLiteral => |lit| {
            std.debug.print("{s}{d}{s}", .{ Color.Yellow.code(), lit.value, Color.Reset.code() });
        },
        .FloatLiteral => |lit| {
            std.debug.print("{s}{d}{s}", .{ Color.Yellow.code(), lit.value, Color.Reset.code() });
        },
        .StringLiteral => |lit| {
            std.debug.print("{s}\"{s}\"{s}", .{ Color.Green.code(), lit.value, Color.Reset.code() });
        },
        .BooleanLiteral => |lit| {
            std.debug.print("{s}{}{s}", .{ Color.Yellow.code(), lit.value, Color.Reset.code() });
        },
        .Identifier => |id| {
            std.debug.print("{s}{s}{s}", .{ Color.Cyan.code(), id.name, Color.Reset.code() });
        },
        .BinaryExpr => |binary| {
            std.debug.print("({s}{s}{s} ", .{ Color.Magenta.code(), @tagName(binary.op), Color.Reset.code() });
            printExpr(binary.left, indent);
            std.debug.print(" ", .{});
            printExpr(binary.right, indent);
            std.debug.print(")", .{});
        },
        .UnaryExpr => |unary| {
            std.debug.print("({s}{s}{s} ", .{ Color.Magenta.code(), @tagName(unary.op), Color.Reset.code() });
            printExpr(unary.operand, indent);
            std.debug.print(")", .{});
        },
        .CallExpr => |call| {
            std.debug.print("(Call ", .{});
            printExpr(call.callee, indent);
            std.debug.print(" [", .{});
            for (call.args, 0..) |arg, i| {
                if (i > 0) std.debug.print(", ", .{});
                printExpr(arg, indent);
            }
            std.debug.print("])", .{});
        },
        else => {
            std.debug.print("<unknown-expr>", .{});
        },
    }
}

fn printStmt(stmt: ast.Stmt, indent: usize) void {
    printIndent(indent);
    switch (stmt) {
        .LetDecl => |decl| {
            std.debug.print("{s}let{s} {s}{s}{s}{s}", .{
                Color.Magenta.code(),
                Color.Reset.code(),
                if (decl.is_mutable) "mut " else "",
                Color.Cyan.code(),
                decl.name,
                Color.Reset.code(),
            });
            if (decl.type_name) |type_name| {
                std.debug.print(": {s}", .{type_name});
            }
            if (decl.value) |value| {
                std.debug.print(" = ", .{});
                printExpr(value, indent);
            }
            std.debug.print("\n", .{});
        },
        .FnDecl => |fn_decl| {
            std.debug.print("{s}fn{s} {s}{s}{s}(", .{
                Color.Magenta.code(),
                Color.Reset.code(),
                Color.Cyan.code(),
                fn_decl.name,
                Color.Reset.code(),
            });
            for (fn_decl.params, 0..) |param, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}: {s}", .{ param.name, param.type_name });
            }
            std.debug.print(")", .{});
            if (fn_decl.return_type) |ret_type| {
                std.debug.print(" -> {s}", .{ret_type});
            }
            std.debug.print(" {{\n", .{});
            for (fn_decl.body.statements) |body_stmt| {
                printStmt(body_stmt, indent + 1);
            }
            printIndent(indent);
            std.debug.print("}}\n", .{});
        },
        .ReturnStmt => |ret| {
            std.debug.print("{s}return{s}", .{ Color.Magenta.code(), Color.Reset.code() });
            if (ret.value) |value| {
                std.debug.print(" ", .{});
                printExpr(value, indent);
            }
            std.debug.print("\n", .{});
        },
        .IfStmt => |if_stmt| {
            std.debug.print("{s}if{s} ", .{ Color.Magenta.code(), Color.Reset.code() });
            printExpr(if_stmt.condition, indent);
            std.debug.print(" {{\n", .{});
            for (if_stmt.then_block.statements) |then_stmt| {
                printStmt(then_stmt, indent + 1);
            }
            printIndent(indent);
            std.debug.print("}}", .{});
            if (if_stmt.else_block) |else_block| {
                std.debug.print(" {s}else{s} {{\n", .{ Color.Magenta.code(), Color.Reset.code() });
                for (else_block.statements) |else_stmt| {
                    printStmt(else_stmt, indent + 1);
                }
                printIndent(indent);
                std.debug.print("}}", .{});
            }
            std.debug.print("\n", .{});
        },
        .BlockStmt => |block| {
            std.debug.print("{{\n", .{});
            for (block.statements) |block_stmt| {
                printStmt(block_stmt, indent + 1);
            }
            printIndent(indent);
            std.debug.print("}}\n", .{});
        },
        .ExprStmt => |expr| {
            printExpr(expr, indent);
            std.debug.print("\n", .{});
        },
        else => {
            std.debug.print("<unknown-stmt>\n", .{});
        },
    }
}

fn astCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    // Tokenize
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Parse
    var parser = Parser.init(allocator, tokens.items);
    const program = try parser.parse();
    defer program.deinit(allocator);

    // Print header
    std.debug.print("{s}AST for:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    std.debug.print("{s}Statements:{s} {d}\n\n", .{ Color.Blue.code(), Color.Reset.code(), program.statements.len });

    // Print AST
    for (program.statements) |stmt| {
        printStmt(stmt, 0);
    }

    std.debug.print("\n{s}Success:{s} Parsed {d} statements\n", .{ Color.Green.code(), Color.Reset.code(), program.statements.len });
}

fn runCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    // Tokenize
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Parse
    var parser = Parser.init(allocator, tokens.items);
    const program = try parser.parse();
    defer program.deinit(allocator);

    // Interpret
    var interpreter = Interpreter.init(allocator, program);
    defer interpreter.deinit();

    std.debug.print("{s}Running:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });

    interpreter.interpret() catch |err| {
        if (err == error.Return) {
            // Normal return from main, not an error
            std.debug.print("\n{s}Success:{s} Program completed\n", .{ Color.Green.code(), Color.Reset.code() });
            return;
        }
        std.debug.print("\n{s}Error:{s} Runtime error: {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
        return err;
    };

    std.debug.print("\n{s}Success:{s} Program completed\n", .{ Color.Green.code(), Color.Reset.code() });
}

fn buildCommand(allocator: std.mem.Allocator, file_path: []const u8, output_path: ?[]const u8) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    // Tokenize
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Parse
    var parser = Parser.init(allocator, tokens.items);
    const program = try parser.parse();
    defer program.deinit(allocator);

    std.debug.print("{s}Building:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });

    // Determine output path
    const out_path = output_path orelse blk: {
        // Default: remove .ion extension and use that as output name
        if (std.mem.endsWith(u8, file_path, ".ion")) {
            break :blk file_path[0 .. file_path.len - 4];
        }
        break :blk "a.out";
    };

    // Generate native machine code
    var codegen = NativeCodegen.init(allocator, program);
    defer codegen.deinit();

    std.debug.print("{s}Generating native x86-64 code...{s}\n", .{ Color.Green.code(), Color.Reset.code() });

    try codegen.writeExecutable(out_path);

    std.debug.print("\n{s}Success:{s} Built native executable {s}\n", .{ Color.Green.code(), Color.Reset.code(), out_path });
    std.debug.print("{s}Info:{s} Run with: ./{s}\n", .{ Color.Blue.code(), Color.Reset.code(), out_path });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "parse")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'parse' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try parseCommand(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "ast")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'ast' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try astCommand(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'run' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try runCommand(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "build")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'build' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        const output_path = if (args.len >= 5 and std.mem.eql(u8, args[3], "-o"))
            args[4]
        else
            null;

        try buildCommand(allocator, args[2], output_path);
        return;
    }

    std.debug.print("{s}Error:{s} Unknown command '{s}'\n\n", .{ Color.Red.code(), Color.Reset.code(), command });
    printUsage();
    std.process.exit(1);
}
