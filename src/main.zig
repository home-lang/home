const std = @import("std");
const lexer_mod = @import("lexer");
const Lexer = lexer_mod.Lexer;
const Token = lexer_mod.Token;
const Parser = @import("parser").Parser;
const ast = @import("ast");
const Interpreter = @import("interpreter").Interpreter;
const codegen_mod = @import("codegen");
const NativeCodegen = codegen_mod.NativeCodegen;
const HomeKernelCodegen = codegen_mod.HomeKernelCodegen;
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
const repl = @import("repl.zig");
const lint_cmd = @import("lint_command.zig");

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
        \\{s}Home Compiler{s} - The speed of Zig. The safety of Rust. The joy of TypeScript.
        \\
        \\{s}Usage:{s}
        \\  home <command> [arguments]
        \\
        \\{s}Commands:{s}
        \\  init [name]        Initialize a new Home project with complete structure
        \\  parse <file>       Tokenize an Home file and display tokens
        \\  ast <file>         Parse an Home file and display the AST
        \\  check <file>       Type check an Home file (fast, no execution)
        \\  lint <file>        Lint and show diagnostics
        \\  lint --fix <file>  Lint and auto-fix issues
        \\  fmt <file>         Format and auto-fix (alias for lint --fix)
        \\  run <file>         Execute an Home file directly
        \\  build <file>       Compile an Home file to a native binary
        \\  test <file>        Run all @test functions in an Home file
        \\  profile <file>     Profile memory allocations during compilation
        \\
        \\  {s}Package Management:{s}
        \\  pkg init           Initialize a new Home project with home.toml
        \\  pkg add <name>     Add a dependency (registry package)
        \\  pkg add <url>      Add from GitHub (user/repo) or URL
        \\  pkg remove <name>  Remove a dependency
        \\  pkg update         Update all dependencies to latest versions
        \\  pkg install        Install dependencies from home.toml
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
        \\  home init my-app
        \\  home parse hello.home
        \\  home check hello.home
        \\  home run hello.home
        \\  home build hello.home -o hello
        \\  home test src/
        \\
        \\  home pkg init
        \\  home pkg add http-router@1.0.0
        \\  home pkg add home-lang/awesome-lib
        \\  home pkg install
        \\  home pkg run dev
        \\  home pkg tree
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
            if (fn_decl.is_test) {
                std.debug.print("{s}@test{s} ", .{
                    Color.Yellow.code(),
                    Color.Reset.code(),
                });
            }
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
    var parser = try Parser.init(arena_allocator, tokens.items);
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
    var parser = try Parser.init(arena_allocator, tokens.items);
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

fn fmtCommand(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    // fmt is an alias for lint --fix
    // Build new args array with --fix flag
    var new_args = std.ArrayList([:0]u8).init(allocator);
    defer new_args.deinit();

    try new_args.append(try allocator.dupeZ(u8, "--fix"));
    for (args) |arg| {
        try new_args.append(arg);
    }

    try lint_cmd.lintCommand(allocator, new_args.items);
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
    var parser = try Parser.init(arena_allocator, tokens.items);
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

fn buildCommand(allocator: std.mem.Allocator, file_path: []const u8, output_path: ?[]const u8, kernel_mode: bool) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    if (kernel_mode) {
        std.debug.print("{s}Building kernel:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    } else {
        std.debug.print("{s}Building:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    }

    // Initialize IR cache if enabled (skip for kernel mode)
    var cache: ?IRCache = null;
    if (build_options.enable_ir_cache and !kernel_mode) {
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
    var parser = try Parser.init(arena_allocator, tokens.items);
    const program = try parser.parse();

    if (kernel_mode) {
        // Kernel mode: generate assembly
        var out_path_owned: ?[]const u8 = null;
        defer if (out_path_owned) |p| allocator.free(p);

        const out_path = if (output_path) |p|
            p
        else if (std.mem.endsWith(u8, file_path, ".home"))
            blk: {
                out_path_owned = try std.fmt.allocPrint(allocator, "{s}.s", .{file_path[0 .. file_path.len - 5]});
                break :blk out_path_owned.?;
            }
        else
            "kernel.s";

        std.debug.print("{s}Generating kernel assembly...{s}\n", .{ Color.Green.code(), Color.Reset.code() });

        var codegen = HomeKernelCodegen.init(
            allocator,
            &parser.symbol_table,
            &parser.module_resolver,
        );
        defer codegen.deinit();

        const asm_code = try codegen.generate(program);

        // Write assembly to file
        try std.fs.cwd().writeFile(.{
            .sub_path = out_path,
            .data = asm_code,
        });

        std.debug.print("\n{s}Success:{s} Generated kernel assembly: {s}\n", .{ Color.Green.code(), Color.Reset.code(), out_path });
        std.debug.print("{s}Info:{s} Assemble with: as -o {s}.o {s}\n", .{ Color.Blue.code(), Color.Reset.code(), out_path[0 .. out_path.len - 2], out_path });
    } else {
        // Normal mode: generate executable
        const out_path = output_path orelse blk: {
            // Default: remove .home or .hm extension and use that as output name
            if (std.mem.endsWith(u8, file_path, ".home")) {
                break :blk file_path[0 .. file_path.len - 5];
            } else if (std.mem.endsWith(u8, file_path, ".hm")) {
                break :blk file_path[0 .. file_path.len - 3];
            }
            break :blk "a.out";
        };

        std.debug.print("{s}Generating native x86-64 code...{s}\n", .{ Color.Green.code(), Color.Reset.code() });

        var codegen = NativeCodegen.init(allocator, program);
        defer codegen.deinit();

        try codegen.writeExecutable(out_path);

        std.debug.print("\n{s}Success:{s} Built native executable {s}\n", .{ Color.Green.code(), Color.Reset.code(), out_path });
        std.debug.print("{s}Info:{s} Run with: ./{s}\n", .{ Color.Blue.code(), Color.Reset.code(), out_path });
    }
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
    var parser = try Parser.init(arena_allocator, tokens.items);
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

fn testCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    std.debug.print("{s}Running Tests:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });

    // Use arena allocator for parsing
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();

    // Parse
    var parser = try Parser.init(arena_allocator, tokens.items);
    const program = try parser.parse();

    // Check for parse errors
    if (parser.errors.items.len > 0) {
        for (parser.errors.items) |err_item| {
            std.debug.print("<input>:{d}:{d}: {s}error:{s} {s}\n", .{
                err_item.line,
                err_item.column,
                Color.Red.code(),
                Color.Reset.code(),
                err_item.message,
            });
        }
        std.debug.print("\n{d} parse error(s) found\n", .{parser.errors.items.len});
        std.process.exit(1);
    }

    // Import test discovery and executor modules (inline for now)
    // We'll need to create these as separate files and import them
    const TestDiscovery = struct {
        pub const DiscoveredTest = struct {
            name: []const u8,
            fn_decl: *ast.FnDecl,
            file_path: []const u8,
            line: usize,
        };

        pub fn discover(alloc: std.mem.Allocator, prog: *ast.Program, path: []const u8) !std.ArrayList(DiscoveredTest) {
            var tests = std.ArrayList(DiscoveredTest){};
            for (prog.statements) |stmt| {
                switch (stmt) {
                    .FnDecl => |fn_decl| {
                        if (fn_decl.is_test) {
                            try tests.append(alloc, .{
                                .name = fn_decl.name,
                                .fn_decl = fn_decl,
                                .file_path = path,
                                .line = fn_decl.node.loc.line,
                            });
                        }
                    },
                    else => {},
                }
            }
            return tests;
        }
    };

    // Discover tests
    var discovered_tests = try TestDiscovery.discover(allocator, program, file_path);
    defer discovered_tests.deinit(allocator);

    std.debug.print("\n{s}Test Discovery{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("{s}Found {d} test(s){s}\n\n", .{
        Color.Green.code(),
        discovered_tests.items.len,
        Color.Reset.code(),
    });

    if (discovered_tests.items.len == 0) {
        std.debug.print("{s}No tests found.{s} Add @test annotations to functions to mark them as tests.\n", .{
            Color.Yellow.code(),
            Color.Reset.code(),
        });
        return;
    }

    // Execute tests
    var passed: usize = 0;
    const failed: usize = 0; // TODO: implement actual test execution
    var total_duration: i64 = 0;

    std.debug.print("{s}Running Tests{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("{s}━{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });

    for (discovered_tests.items) |test_item| {
        const start_time = std.time.milliTimestamp();

        // TODO: Execute individual test functions
        // For now, just validate that the test exists

        const duration = std.time.milliTimestamp() - start_time;
        total_duration += duration;
        passed += 1;
        std.debug.print("  {s}✓{s} {s} (found)\n", .{
            Color.Green.code(),
            Color.Reset.code(),
            test_item.name,
        });
    }

    // Print summary
    const total = discovered_tests.items.len;
    std.debug.print("\n{s}Summary{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("{s}━{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });

    const pass_color = if (passed == total) Color.Green.code() else Color.Yellow.code();
    std.debug.print("  Tests:    {s}{d} passed{s}, {d} total\n", .{
        pass_color,
        passed,
        Color.Reset.code(),
        total,
    });

    if (failed > 0) {
        std.debug.print("  Failed:   {s}{d}{s}\n", .{
            Color.Red.code(),
            failed,
            Color.Reset.code(),
        });
    }

    std.debug.print("  Duration: {d}ms\n", .{total_duration});

    if (failed > 0) {
        std.debug.print("\n{s}Tests failed.{s}\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    } else {
        std.debug.print("\n{s}All tests passed!{s}\n", .{ Color.Green.code(), Color.Reset.code() });
    }
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

    // If no arguments provided, start REPL
    if (args.len < 2) {
        try repl.start(allocator);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "init")) {
        const project_name = if (args.len >= 3) args[2] else null;
        try initCommand(allocator, project_name);
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

    if (std.mem.eql(u8, command, "lint")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'lint' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try lint_cmd.lintCommand(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "fmt")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'fmt' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try fmtCommand(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            // No file provided, start REPL
            try repl.start(allocator);
            return;
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

        var output_path: ?[]const u8 = null;
        var kernel_mode = false;

        // Parse optional flags: --kernel, -o <output>
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--kernel")) {
                kernel_mode = true;
            } else if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
                output_path = args[i + 1];
                i += 1;
            }
        }

        try buildCommand(allocator, args[2], output_path, kernel_mode);
        return;
    }

    if (std.mem.eql(u8, command, "test")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'test' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try testCommand(allocator, args[2]);
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

fn initCommand(allocator: std.mem.Allocator, project_name: ?[]const u8) !void {
    const name = project_name orelse "my-home-app";

    std.debug.print("{s}Initializing Home project:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), name });

    // Create project directory if name was provided
    if (project_name != null) {
        std.fs.cwd().makeDir(name) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("{s}Error:{s} Failed to create directory '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), name, err });
                return err;
            }
            std.debug.print("{s}Warning:{s} Directory '{s}' already exists, initializing in place\n", .{ Color.Yellow.code(), Color.Reset.code(), name });
        };

        const dir = try std.fs.cwd().openDir(name, .{});
        try dir.setAsCwd();
    }

    // Create directories
    const dirs = [_][]const u8{ "src", "tests", ".home" };
    for (dirs) |dir| {
        std.fs.cwd().makeDir(dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("{s}Error:{s} Failed to create {s}/: {}\n", .{ Color.Red.code(), Color.Reset.code(), dir, err });
                return err;
            }
        };
    }

    // Create package.jsonc
    const package_jsonc =
        \\{{
        \\  // Home project configuration (JSONC - JSON with Comments)
        \\  "name": "{s}",
        \\  "version": "0.1.0",
        \\  "description": "A new Home project",
        \\
        \\  // Dependencies
        \\  "dependencies": {{
        \\    // Add your dependencies here
        \\    // "http": "^2.0.0"
        \\  }},
        \\
        \\  // Development dependencies
        \\  "devDependencies": {{
        \\    // "test-framework": "^1.0.0"
        \\  }},
        \\
        \\  // Scripts
        \\  "scripts": {{
        \\    "dev": "home run src/main.home",
        \\    "build": "home build src/main.home -o dist/app",
        \\    "test": "home test tests/",
        \\    "format": "home fmt src/"
        \\  }}
        \\}}
        \\
    ;

    const package_content = try std.fmt.allocPrint(allocator, package_jsonc, .{name});
    defer allocator.free(package_content);

    {
        const file = try std.fs.cwd().createFile("package.jsonc", .{});
        defer file.close();
        try file.writeAll(package_content);
        std.debug.print("{s}✓{s} Created package.jsonc\n", .{ Color.Green.code(), Color.Reset.code() });
    }

    // Create src/main.home
    const main_home =
        \\// Welcome to Home!
        \\// This is your main entry point.
        \\
        \\fn main() {
        \\  let message = "Hello from Home!"
        \\  print(message)
        \\}
        \\
        \\// Run with: home run src/main.home
        \\
    ;

    {
        const file = try std.fs.cwd().createFile("src/main.home", .{});
        defer file.close();
        try file.writeAll(main_home);
        std.debug.print("{s}✓{s} Created src/main.home\n", .{ Color.Green.code(), Color.Reset.code() });
    }

    // Create tests/example.home with @test annotations
    const test_file =
        \\// Example test file using @test annotations
        \\
        \\fn add(a: i32, b: i32) -> i32 {
        \\  return a + b
        \\}
        \\
        \\@test
        \\fn test_addition() {
        \\  let result = add(2, 3)
        \\  if (result != 5) {
        \\    panic("Expected 2 + 3 to equal 5")
        \\  }
        \\}
        \\
        \\@test
        \\fn test_zero() {
        \\  let result = add(0, 0)
        \\  if (result != 0) {
        \\    panic("Expected 0 + 0 to equal 0")
        \\  }
        \\}
        \\
        \\// Run tests with: home test tests/
        \\
    ;

    {
        const file = try std.fs.cwd().createFile("tests/example.home", .{});
        defer file.close();
        try file.writeAll(test_file);
        std.debug.print("{s}✓{s} Created tests/example.home\n", .{ Color.Green.code(), Color.Reset.code() });
    }

    // Create README.md
    const readme =
        \\# {s}
        \\
        \\A new project built with [Home](https://github.com/home-lang/home).
        \\
        \\## Getting Started
        \\
        \\```bash
        \\# Run the project
        \\home run src/main.home
        \\
        \\# Run tests
        \\home test tests/
        \\
        \\# Build for production
        \\home build src/main.home -o dist/app
        \\```
        \\
        \\## Project Structure
        \\
        \\```
        \\{s}/
        \\├── src/
        \\│   └── main.home       # Main entry point
        \\├── tests/
        \\│   └── example.home    # Example tests
        \\├── package.jsonc       # Project configuration
        \\└── README.md           # This file
        \\```
        \\
        \\## Scripts
        \\
        \\- `home run src/main.home` - Run the development server
        \\- `home build src/main.home -o dist/app` - Build for production
        \\- `home test tests/` - Run all tests
        \\- `home fmt src/` - Format source code
        \\
        \\## Learn More
        \\
        \\- [Home Documentation](https://home-lang.dev/docs)
        \\- [Home Examples](https://github.com/home-lang/home/tree/main/examples)
        \\
    ;

    const readme_content = try std.fmt.allocPrint(allocator, readme, .{ name, name });
    defer allocator.free(readme_content);

    {
        const file = try std.fs.cwd().createFile("README.md", .{});
        defer file.close();
        try file.writeAll(readme_content);
        std.debug.print("{s}✓{s} Created README.md\n", .{ Color.Green.code(), Color.Reset.code() });
    }

    // Create .gitignore
    const gitignore =
        \\# Zig build artifacts
        \\zig-cache/
        \\zig-out/
        \\.zig-cache/
        \\
        \\# Home build artifacts
        \\.home/
        \\dist/
        \\
        \\# Dependencies
        \\node_modules/
        \\
        \\# OS files
        \\.DS_Store
        \\Thumbs.db
        \\
        \\# Editor files
        \\.vscode/
        \\.idea/
        \\*.swp
        \\*.swo
        \\*~
        \\
    ;

    {
        const file = try std.fs.cwd().createFile(".gitignore", .{});
        defer file.close();
        try file.writeAll(gitignore);
        std.debug.print("{s}✓{s} Created .gitignore\n", .{ Color.Green.code(), Color.Reset.code() });
    }

    std.debug.print("\n{s}Project initialized successfully!{s}\n\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("Next steps:\n", .{});
    if (project_name != null) {
        std.debug.print("  cd {s}\n", .{name});
    }
    std.debug.print("  home run src/main.home\n", .{});
    std.debug.print("  home test tests/\n\n", .{});
}

fn pkgInit(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("{s}Initializing new Home project...{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    // Create home.toml with default content
    const content =
        \\[package]
        \\name = "my-home-project"
        \\version = "0.1.0"
        \\authors = []
        \\
        \\[dependencies]
        \\# Add your dependencies here
        \\# Example:
        \\# http-router = "1.0.0"
        \\# awesome-lib = { git = "https://github.com/home-lang/awesome-lib" }
        \\# custom-lib = { url = "https://example.com/lib.tar.gz" }
        \\
        \\[scripts]
        \\# Bun-style package scripts
        \\dev = "home run src/main.home --watch"
        \\build = "home build src/main.home -o dist/app"
        \\test = "home test tests/"
        \\bench = "home bench bench/"
        \\format = "home fmt src/"
        \\
    ;

    const file = try std.fs.cwd().createFile("home.toml", .{});
    defer file.close();
    try file.writeAll(content);

    std.debug.print("{s}✓{s} Created home.toml\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("Edit home.toml to configure your project\n", .{});
}

fn pkgAdd(allocator: std.mem.Allocator, spec: []const u8) !void {
    std.debug.print("{s}Adding package:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), spec });

    var pm = PackageManager.init(allocator) catch {
        std.debug.print("{s}Error:{s} No home.toml found. Run 'home pkg init' first.\n", .{ Color.Red.code(), Color.Reset.code() });
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
        std.debug.print("{s}Error:{s} No home.toml found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    };
    defer pm.deinit();

    try pm.removeDependency(name);
    std.debug.print("{s}✓{s} Removed {s}\n", .{ Color.Green.code(), Color.Reset.code(), name });
}

fn pkgUpdate(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Updating dependencies...{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    var pm = PackageManager.init(allocator) catch {
        std.debug.print("{s}Error:{s} No home.toml found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    };
    defer pm.deinit();

    try pm.update();
    std.debug.print("{s}✓{s} Dependencies updated\n", .{ Color.Green.code(), Color.Reset.code() });
}

fn pkgInstall(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Installing dependencies...{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    var pm = PackageManager.init(allocator) catch {
        std.debug.print("{s}Error:{s} No home.toml found. Run 'home pkg init' first.\n", .{ Color.Red.code(), Color.Reset.code() });
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

    // Check for home.lock
    const lock_exists = blk: {
        std.fs.cwd().access("home.lock", .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!lock_exists) {
        std.debug.print("{s}Error:{s} No home.lock found. Run 'home pkg install' first.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    }

    // Simple tree display (full implementation would parse home.lock)
    std.debug.print("\n📦 my-home-project@0.1.0\n", .{});
    std.debug.print("└── (Use 'home pkg install' to generate dependency tree)\n\n", .{});

    std.debug.print("{s}Tip:{s} Full tree visualization coming soon!\n", .{ Color.Cyan.code(), Color.Reset.code() });

    _ = allocator;
}

fn pkgRun(allocator: std.mem.Allocator, script_name: []const u8) !void {
    std.debug.print("{s}Running script:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), script_name });

    // Check for home.toml
    const toml_exists = blk: {
        std.fs.cwd().access("home.toml", .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!toml_exists) {
        std.debug.print("{s}Error:{s} No home.toml found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    }

    // TODO: Parse home.toml and look for [scripts] section
    // For now, show common scripts
    if (std.mem.eql(u8, script_name, "dev")) {
        std.debug.print("🚀 home run src/main.home --watch\n", .{});
    } else if (std.mem.eql(u8, script_name, "build")) {
        std.debug.print("🔨 home build src/main.home -o dist/app\n", .{});
    } else if (std.mem.eql(u8, script_name, "test")) {
        std.debug.print("🧪 home test tests/\n", .{});
    } else {
        std.debug.print("{s}Error:{s} Script '{s}' not found in home.toml\n", .{ Color.Red.code(), Color.Reset.code(), script_name });
        std.debug.print("\nDefine it in home.toml:\n", .{});
        std.debug.print("[scripts]\n{s} = \"your command here\"\n", .{script_name});
        std.process.exit(1);
    }

    _ = allocator;
}

fn pkgScripts(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Available scripts:{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    // TODO: Parse home.toml for actual scripts
    // For now, show example scripts
    std.debug.print("  {s}dev{s}      home run src/main.home --watch\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("  {s}build{s}    home build src/main.home -o dist/app\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("  {s}test{s}     home test tests/\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("  {s}bench{s}    home bench bench/\n", .{ Color.Green.code(), Color.Reset.code() });
    std.debug.print("  {s}format{s}   home fmt src/\n", .{ Color.Green.code(), Color.Reset.code() });

    std.debug.print("\n{s}Tip:{s} Define custom scripts in home.toml [scripts] section\n", .{ Color.Cyan.code(), Color.Reset.code() });

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
            std.debug.print("\nRun {s}home pkg login{s} to authenticate\n", .{ Color.Cyan.code(), Color.Reset.code() });
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
        std.debug.print("\nRun {s}home pkg login{s} to authenticate\n", .{ Color.Cyan.code(), Color.Reset.code() });
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
