const std = @import("std");
const lexer_mod = @import("lexer");
const Lexer = lexer_mod.Lexer;
const Token = lexer_mod.Token;
const Parser = @import("parser").Parser;
const ast = @import("ast");
const Interpreter = @import("interpreter").Interpreter;
const NativeCodegen = @import("codegen").NativeCodegen;
const TypeChecker = @import("types").TypeChecker;
const Formatter = @import("formatter").Formatter;
const DiagnosticReporter = @import("diagnostics").DiagnosticReporter;
const pkg_manager_mod = @import("pkg_manager");
const PackageManager = pkg_manager_mod.PackageManager;
const AuthManager = pkg_manager_mod.AuthManager;
const IRCache = @import("ir_cache").IRCache;
const build_options = @import("build_options");
const profiler_mod = @import("profiler.zig");
const AllocationProfiler = profiler_mod.AllocationProfiler;

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
        \\  parse <file>       Tokenize an Home file and display tokens
        \\  ast <file>         Parse an Home file and display the AST
        \\  check <file>       Type check an Home file (fast, no execution)
        \\  fmt <file>         Format an Home file with consistent style
        \\  run <file>         Execute an Home file directly
        \\  build <file>       Compile an Home file to a native binary
        \\  profile <file>     Profile memory allocations during compilation
        \\
        \\  {s}Package Management:{s}
        \\  pkg init           Initialize a new Home project with ion.toml
        \\  pkg add <name>     Add a dependency (registry package)
        \\  pkg add <url>      Add from GitHub (user/repo) or URL
        \\  pkg remove <name>  Remove a dependency
        \\  pkg update         Update all dependencies to latest versions
        \\  pkg install        Install dependencies from ion.toml
        \\  pkg tree           Show dependency tree
        \\  pkg run <script>   Run a package script
        \\  pkg scripts        List all available scripts
        \\  pkg login          Login to package registry
        \\  pkg logout         Logout from package registry
        \\  pkg whoami         Show authenticated user
        \\
        \\  help               Display this help message
        \\
        \\{s}Examples:{s}
        \\  ion parse hello.home
        \\  ion check hello.home
        \\  ion run hello.home
        \\  ion build hello.home -o hello
        \\
        \\  ion pkg init
        \\  ion pkg add http-router@1.0.0
        \\  ion pkg add ion-lang/zyte
        \\  ion pkg install
        \\  ion pkg run dev
        \\  ion pkg tree
        \\
    , .{
        Color.Blue.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Cyan.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
    });
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

    // Use arena allocator for tokens
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();

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

    // Use arena allocator for AST to reduce allocation overhead
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();

    // Parse (AST allocated in arena)
    var parser = Parser.init(arena_allocator, tokens.items);
    const program = try parser.parse();

    // Print header
    std.debug.print("{s}AST for:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    std.debug.print("{s}Statements:{s} {d}\n\n", .{ Color.Blue.code(), Color.Reset.code(), program.statements.len });

    // Print AST
    for (program.statements) |stmt| {
        printStmt(stmt, 0);
    }

    std.debug.print("\n{s}Success:{s} Parsed {d} statements\n", .{ Color.Green.code(), Color.Reset.code(), program.statements.len });
}

fn checkCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    // Initialize diagnostic reporter
    var reporter = DiagnosticReporter.init(allocator);
    defer reporter.deinit();
    try reporter.loadSource(source);

    // Use arena allocator for AST
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();

    // Parse
    var parser = Parser.init(arena_allocator, tokens.items);
    const program = try parser.parse();

    // Type check
    var type_checker = TypeChecker.init(allocator, program);
    defer type_checker.deinit();

    std.debug.print("{s}Checking:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });

    const passed = try type_checker.check();

    if (!passed) {
        // Convert type checker errors to rich diagnostics
        for (type_checker.errors.items) |err_info| {
            const suggestion = getSuggestion(err_info.message);
            try reporter.addError(err_info.message, err_info.loc, suggestion);
        }
    }

    if (reporter.hasErrors()) {
        reporter.report(file_path);
        std.process.exit(1);
    } else {
        std.debug.print("{s}Success:{s} Type checking passed ✓\n", .{ Color.Green.code(), Color.Reset.code() });
    }
}

fn getSuggestion(error_message: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, error_message, "Type mismatch")) |_| {
        return "ensure the value type matches the declared type";
    } else if (std.mem.indexOf(u8, error_message, "Undefined variable")) |_| {
        return "check the variable name or declare it before use";
    } else if (std.mem.indexOf(u8, error_message, "Undefined function")) |_| {
        return "check the function name or import the required module";
    } else if (std.mem.indexOf(u8, error_message, "Wrong number of arguments")) |_| {
        return "check the function signature";
    } else if (std.mem.indexOf(u8, error_message, "Use of moved value")) |_| {
        return "the value was moved, consider cloning it or using a reference";
    } else if (std.mem.indexOf(u8, error_message, "Cannot borrow")) |_| {
        return "ensure no conflicting borrows exist";
    }
    return null;
}

fn fmtCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    // Use arena allocator for AST
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();

    // Parse
    var parser = Parser.init(arena_allocator, tokens.items);
    const program = try parser.parse();

    // Format
    var formatter = Formatter.init(allocator, program);
    defer formatter.deinit();

    std.debug.print("{s}Formatting:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });

    const formatted = try formatter.format(.{});
    defer allocator.free(formatted);

    // Write back to file
    const output_file = try std.fs.cwd().createFile(file_path, .{});
    defer output_file.close();

    try output_file.writeAll(formatted);

    std.debug.print("{s}Success:{s} File formatted ✓\n", .{ Color.Green.code(), Color.Reset.code() });
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

    // Use arena allocator for AST
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();

    // Parse
    var parser = Parser.init(arena_allocator, tokens.items);
    const program = try parser.parse();

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

    std.debug.print("{s}Building:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });

    // Initialize IR cache if enabled
    var cache: ?IRCache = null;
    if (build_options.enable_ir_cache) {
        cache = try IRCache.init(allocator, ".home-cache");
        std.debug.print("{s}IR Cache:{s} enabled\n", .{ Color.Cyan.code(), Color.Reset.code() });

        // Check if we have a valid cached result
        if (try cache.?.isCacheValid(file_path, source)) {
            std.debug.print("{s}Cache Hit:{s} Using cached compilation\n", .{ Color.Green.code(), Color.Reset.code() });
            // In a full implementation, we'd load the cached binary here
            // For now, we'll continue with normal compilation
        }
    }
    defer if (cache) |*c| c.deinit();

    // Use arena allocator for AST
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();

    // Parse
    var parser = Parser.init(arena_allocator, tokens.items);
    const program = try parser.parse();

    // Determine output path
    const out_path = output_path orelse blk: {
        // Default: remove .home or .hm extension and use that as output name
        if (std.mem.endsWith(u8, file_path, ".home")) {
            break :blk file_path[0 .. file_path.len - 5];
        } else if (std.mem.endsWith(u8, file_path, ".hm")) {
            break :blk file_path[0 .. file_path.len - 3];
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

fn profileCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    std.debug.print("{s}Profiling:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });

    // Initialize profiler
    var prof = AllocationProfiler.init(allocator);
    defer prof.deinit();

    // Use arena allocator and track its usage
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    const start_lex = std.time.milliTimestamp();
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();
    const lex_time = std.time.milliTimestamp() - start_lex;

    try prof.trackAllocation(tokens.items.len * @sizeOf(Token));

    // Parse
    const start_parse = std.time.milliTimestamp();
    var parser = Parser.init(arena_allocator, tokens.items);
    const program = try parser.parse();
    const parse_time = std.time.milliTimestamp() - start_parse;

    // Estimate AST size
    const ast_size = program.statements.len * 1000; // Rough estimate
    try prof.trackAllocation(ast_size);

    // Print timing
    std.debug.print("{s}Timing:{s}\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("  Lexing:  {d}ms\n", .{lex_time});
    std.debug.print("  Parsing: {d}ms\n", .{parse_time});
    std.debug.print("  Total:   {d}ms\n\n", .{lex_time + parse_time});

    // Print memory report
    prof.report();

    // Get and print hotspots
    const hotspots = try prof.getHotspots(allocator);
    defer allocator.free(hotspots);

    std.debug.print("{s}Top Allocation Hotspots:{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("-" ** 60 ++ "\n", .{});
    const max_hotspots = @min(10, hotspots.len);
    for (hotspots[0..max_hotspots], 0..) |hotspot, i| {
        std.debug.print("{d}. Size: {d} bytes × {d} allocations = {d} KB total\n", .{
            i + 1,
            hotspot.size,
            hotspot.count,
            hotspot.total_bytes / 1024,
        });
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    // Enable memory tracking in debug builds if configured
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = build_options.memory_tracking,
        .verbose_log = build_options.memory_tracking,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak and build_options.memory_tracking) {
            std.debug.print("\n{s}Warning:{s} Memory leaks detected!\n", .{ Color.Yellow.code(), Color.Reset.code() });
        }
    }
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

    if (std.mem.eql(u8, command, "check")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'check' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try checkCommand(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "fmt")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'fmt' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try fmtCommand(allocator, args[2]);
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

    if (std.mem.eql(u8, command, "profile")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'profile' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try profileCommand(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "pkg")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'pkg' command requires a subcommand\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try pkgCommand(allocator, args[2..]);
        return;
    }

    std.debug.print("{s}Error:{s} Unknown command '{s}'\n\n", .{ Color.Red.code(), Color.Reset.code(), command });
    printUsage();
    std.process.exit(1);
}

fn pkgCommand(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "init")) {
        try pkgInit(allocator);
        return;
    }

    if (std.mem.eql(u8, subcmd, "login")) {
        try pkgLogin(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "logout")) {
        try pkgLogout(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "whoami")) {
        try pkgWhoami(allocator);
        return;
    }

    if (std.mem.eql(u8, subcmd, "add")) {
        if (args.len < 2) {
            std.debug.print("{s}Error:{s} 'pkg add' requires a package specifier\n", .{ Color.Red.code(), Color.Reset.code() });
            std.process.exit(1);
        }
        try pkgAdd(allocator, args[1]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "remove")) {
        if (args.len < 2) {
            std.debug.print("{s}Error:{s} 'pkg remove' requires a package name\n", .{ Color.Red.code(), Color.Reset.code() });
            std.process.exit(1);
        }
        try pkgRemove(allocator, args[1]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "update")) {
        try pkgUpdate(allocator);
        return;
    }

    if (std.mem.eql(u8, subcmd, "install")) {
        try pkgInstall(allocator);
        return;
    }

    // New Bun-inspired commands
    if (std.mem.eql(u8, subcmd, "tree")) {
        try pkgTree(allocator);
        return;
    }

    if (std.mem.eql(u8, subcmd, "run")) {
        if (args.len < 2) {
            std.debug.print("{s}Error:{s} 'pkg run' requires a script name\n", .{ Color.Red.code(), Color.Reset.code() });
            std.process.exit(1);
        }
        try pkgRun(allocator, args[1]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "scripts")) {
        try pkgScripts(allocator);
        return;
    }

    std.debug.print("{s}Error:{s} Unknown pkg subcommand '{s}'\n", .{ Color.Red.code(), Color.Reset.code(), subcmd });
    std.process.exit(1);
}

fn pkgInit(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("{s}Initializing new Home project...{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    // Create ion.toml with default content
    const content =
        \\[package]
        \\name = "my-ion-project"
        \\version = "0.1.0"
        \\authors = []
        \\
        \\[dependencies]
        \\# Add your dependencies here
        \\# Example:
        \\# http-router = "1.0.0"
        \\# zyte = { git = "https://github.com/ion-lang/zyte" }
        \\# custom-lib = { url = "https://example.com/lib.tar.gz" }
        \\
        \\[scripts]
        \\# Bun-style package scripts
        \\dev = "ion run src/main.home --watch"
        \\build = "ion build src/main.home -o dist/app"
        \\test = "ion test tests/"
        \\bench = "ion bench bench/"
        \\format = "ion fmt src/"
        \\
    ;

    const file = try std.fs.cwd().createFile("ion.toml", .{});
    defer file.close();
    try file.writeAll(content);

    std.debug.print("{s}✓{s} Created ion.toml\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("Edit ion.toml to configure your project\n", .{});
}

fn pkgAdd(allocator: std.mem.Allocator, spec: []const u8) !void {
    std.debug.print("{s}Adding package:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), spec });

    var pm = PackageManager.init(allocator) catch {
        std.debug.print("{s}Error:{s} No ion.toml found. Run 'ion pkg init' first.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    };
    defer pm.deinit();

    // Parse spec to determine type
    // Format: name@version, user/repo, or https://...
    if (std.mem.indexOf(u8, spec, "://") != null) {
        // Full URL
        const name = extractNameFromUrl(spec);
        try pm.addUrlDependency(name, spec);
        std.debug.print("{s}✓{s} Added {s} from URL\n", .{ Color.Green.code(), Color.Reset.code(), name });
    } else if (std.mem.indexOf(u8, spec, "/") != null and std.mem.indexOf(u8, spec, "@") == null) {
        // GitHub shortcut: user/repo
        const name = extractRepoName(spec);
        try pm.addGitDependency(name, spec, null);
        std.debug.print("{s}✓{s} Added {s} from GitHub\n", .{ Color.Green.code(), Color.Reset.code(), name });
    } else {
        // Registry package: name or name@version
        var name: []const u8 = spec;
        var version: []const u8 = "latest";

        if (std.mem.indexOf(u8, spec, "@")) |at_idx| {
            name = spec[0..at_idx];
            version = spec[at_idx + 1 ..];
        }

        try pm.addDependency(name, version);
        std.debug.print("{s}✓{s} Added {s}@{s} from registry\n", .{ Color.Green.code(), Color.Reset.code(), name, version });
    }
}

fn pkgRemove(allocator: std.mem.Allocator, name: []const u8) !void {
    std.debug.print("{s}Removing package:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), name });

    var pm = PackageManager.init(allocator) catch {
        std.debug.print("{s}Error:{s} No ion.toml found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    };
    defer pm.deinit();

    try pm.removeDependency(name);
    std.debug.print("{s}✓{s} Removed {s}\n", .{ Color.Green.code(), Color.Reset.code(), name });
}

fn pkgUpdate(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Updating dependencies...{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    var pm = PackageManager.init(allocator) catch {
        std.debug.print("{s}Error:{s} No ion.toml found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    };
    defer pm.deinit();

    try pm.update();
    std.debug.print("{s}✓{s} Dependencies updated\n", .{ Color.Green.code(), Color.Reset.code() });
}

fn pkgInstall(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Installing dependencies...{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    var pm = PackageManager.init(allocator) catch {
        std.debug.print("{s}Error:{s} No ion.toml found. Run 'ion pkg init' first.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    };
    defer pm.deinit();

    try pm.resolve();
    std.debug.print("{s}✓{s} All dependencies installed\n", .{ Color.Green.code(), Color.Reset.code() });
}

fn extractNameFromUrl(url: []const u8) []const u8 {
    // Extract name from URL: https://example.com/package.tar.gz -> package
    var name = url;

    // Remove protocol
    if (std.mem.indexOf(u8, url, "://")) |idx| {
        name = url[idx + 3 ..];
    }

    // Get last path segment
    if (std.mem.lastIndexOf(u8, name, "/")) |idx| {
        name = name[idx + 1 ..];
    }

    // Remove file extension
    if (std.mem.lastIndexOf(u8, name, ".")) |idx| {
        name = name[0..idx];
    }

    return name;
}

fn extractRepoName(repo: []const u8) []const u8 {
    // Extract repo name from user/repo -> repo
    if (std.mem.lastIndexOf(u8, repo, "/")) |idx| {
        var name = repo[idx + 1 ..];

        // Remove .git suffix if present
        if (std.mem.endsWith(u8, name, ".git")) {
            name = name[0 .. name.len - 4];
        }

        return name;
    }

    return repo;
}

fn pkgTree(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Dependency Tree:{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    // Check for ion.lock
    const lock_exists = blk: {
        std.fs.cwd().access("ion.lock", .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!lock_exists) {
        std.debug.print("{s}Error:{s} No ion.lock found. Run 'ion pkg install' first.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    }

    // Simple tree display (full implementation would parse ion.lock)
    std.debug.print("\n📦 my-ion-project@0.1.0\n", .{});
    std.debug.print("└── (Use 'ion pkg install' to generate dependency tree)\n\n", .{});

    std.debug.print("{s}Tip:{s} Full tree visualization coming soon!\n", .{ Color.Cyan.code(), Color.Reset.code() });

    _ = allocator;
}

fn pkgRun(allocator: std.mem.Allocator, script_name: []const u8) !void {
    std.debug.print("{s}Running script:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), script_name });

    // Check for ion.toml
    const toml_exists = blk: {
        std.fs.cwd().access("ion.toml", .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!toml_exists) {
        std.debug.print("{s}Error:{s} No ion.toml found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    }

    // TODO: Parse ion.toml and look for [scripts] section
    // For now, show common scripts
    if (std.mem.eql(u8, script_name, "dev")) {
        std.debug.print("🚀 ion run src/main.home --watch\n", .{});
    } else if (std.mem.eql(u8, script_name, "build")) {
        std.debug.print("🔨 ion build src/main.home -o dist/app\n", .{});
    } else if (std.mem.eql(u8, script_name, "test")) {
        std.debug.print("🧪 ion test tests/\n", .{});
    } else {
        std.debug.print("{s}Error:{s} Script '{s}' not found in ion.toml\n", .{ Color.Red.code(), Color.Reset.code(), script_name });
        std.debug.print("\nDefine it in ion.toml:\n", .{});
        std.debug.print("[scripts]\n{s} = \"your command here\"\n", .{script_name});
        std.process.exit(1);
    }

    _ = allocator;
}

fn pkgScripts(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Available scripts:{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    // TODO: Parse ion.toml for actual scripts
    // For now, show example scripts
    std.debug.print("  {s}dev{s}      ion run src/main.home --watch\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("  {s}build{s}    ion build src/main.home -o dist/app\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("  {s}test{s}     ion test tests/\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("  {s}bench{s}    ion bench bench/\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("  {s}format{s}   ion fmt src/\n", .{ Color.Green.code(), Color.Reset.code() });

    std.debug.print("\n{s}Tip:{s} Define custom scripts in ion.toml [scripts] section\n", .{ Color.Cyan.code(), Color.Reset.code() });

    _ = allocator;
}

/// Login to package registry
fn pkgLogin(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    std.debug.print("{s}Login to Home Package Registry{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    // Parse optional arguments
    var registry: ?[]const u8 = null;
    var username: ?[]const u8 = null;
    var token: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--registry") and i + 1 < args.len) {
            registry = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--username") and i + 1 < args.len) {
            username = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--token") and i + 1 < args.len) {
            token = args[i + 1];
            i += 1;
        }
    }

    // Check for token in environment variable
    var env_token_allocated: ?[]const u8 = null;
    defer if (env_token_allocated) |t| allocator.free(t);

    if (token == null) {
        if (std.process.getEnvVarOwned(allocator, "ION_TOKEN")) |env_token| {
            env_token_allocated = env_token;
            token = env_token;
            std.debug.print("{s}Using token from ION_TOKEN environment variable{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
        } else |_| {}
    }

    var pm = PackageManager.init(allocator) catch {
        // If no project, still allow login (global auth)
        var auth_manager = try allocator.create(AuthManager);
        defer allocator.destroy(auth_manager);

        auth_manager.* = try AuthManager.init(allocator, PackageManager.DEFAULT_REGISTRY);
        defer auth_manager.deinit();

        try auth_manager.login(registry, username, token);
        return;
    };
    defer pm.deinit();

    try pm.login(registry, username, token);
}

/// Logout from package registry
fn pkgLogout(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    std.debug.print("{s}Logout from Home Package Registry{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    var registry: ?[]const u8 = null;

    if (args.len > 0 and std.mem.eql(u8, args[0], "--registry") and args.len > 1) {
        registry = args[1];
    }

    var pm = PackageManager.init(allocator) catch {
        // If no project, still allow logout (global auth)
        var auth_manager = try allocator.create(AuthManager);
        defer allocator.destroy(auth_manager);

        auth_manager.* = try AuthManager.init(allocator, PackageManager.DEFAULT_REGISTRY);
        defer auth_manager.deinit();

        try auth_manager.logout(registry);
        return;
    };
    defer pm.deinit();

    try pm.logout(registry);
}

/// Show authenticated user
fn pkgWhoami(allocator: std.mem.Allocator) !void {
    var pm = PackageManager.init(allocator) catch {
        // If no project, check global auth
        var auth_manager = try allocator.create(AuthManager);
        defer allocator.destroy(auth_manager);

        auth_manager.* = try AuthManager.init(allocator, PackageManager.DEFAULT_REGISTRY);
        defer auth_manager.deinit();

        const registries = try auth_manager.listAuthenticated();
        defer {
            for (registries) |reg| {
                allocator.free(reg);
            }
            allocator.free(registries);
        }

        if (registries.len == 0) {
            std.debug.print("{s}Not logged in to any registry{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
            std.debug.print("\nRun {s}ion pkg login{s} to authenticate\n", .{ Color.Cyan.code(), Color.Reset.code() });
            return;
        }

        std.debug.print("{s}Authenticated Registries:{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });
        for (registries) |reg| {
            if (auth_manager.getToken(reg)) |token| {
                const username_str = if (token.username) |u| u else "<token auth>";
                std.debug.print("  {s}●{s} {s}\n", .{ Color.Green.code(), Color.Reset.code(), reg });
                std.debug.print("    User: {s}\n", .{username_str});

                if (token.isExpired()) {
                    std.debug.print("    {s}Status: EXPIRED{s}\n", .{ Color.Red.code(), Color.Reset.code() });
                } else {
                    std.debug.print("    {s}Status: Active{s}\n", .{ Color.Green.code(), Color.Reset.code() });
                }
            }
        }

        return;
    };
    defer pm.deinit();

    // With project context
    const default_auth = pm.isAuthenticated(null);

    if (!default_auth) {
        std.debug.print("{s}Not logged in to default registry{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
        std.debug.print("Registry: {s}\n", .{pm.registry_url});
        std.debug.print("\nRun {s}ion pkg login{s} to authenticate\n", .{ Color.Cyan.code(), Color.Reset.code() });
        return;
    }

    const registries = try pm.listAuthenticatedRegistries();
    defer {
        for (registries) |reg| {
            allocator.free(reg);
        }
        allocator.free(registries);
    }

    std.debug.print("{s}Authenticated as:{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    for (registries) |reg| {
        if (pm.getAuthToken(reg)) |token| {
            const username_str = if (token.username) |u| u else "<token auth>";
            const is_default = std.mem.eql(u8, reg, pm.registry_url);

            if (is_default) {
                std.debug.print("  {s}●{s} {s} {s}(default){s}\n", .{ Color.Green.code(), Color.Reset.code(), reg, Color.Cyan.code(), Color.Reset.code() });
            } else {
                std.debug.print("  {s}●{s} {s}\n", .{ Color.Green.code(), Color.Reset.code(), reg });
            }

            std.debug.print("    User: {s}\n", .{username_str});

            if (token.isExpired()) {
                std.debug.print("    {s}Status: EXPIRED - please login again{s}\n", .{ Color.Red.code(), Color.Reset.code() });
            } else {
                std.debug.print("    {s}Status: Active{s}\n", .{ Color.Green.code(), Color.Reset.code() });
            }
        }
    }
}
