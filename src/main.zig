const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const lexer_mod = @import("lexer");
const Lexer = lexer_mod.Lexer;
const Token = lexer_mod.Token;
const Parser = @import("parser").Parser;
const ast = @import("ast");
const Interpreter = @import("interpreter").Interpreter;
const codegen_mod = @import("codegen");
const NativeCodegen = codegen_mod.NativeCodegen;
const Aarch64NativeCodegen = codegen_mod.Aarch64NativeCodegen;
const TypeRegistry = codegen_mod.TypeRegistry;
const HomeKernelCodegen = codegen_mod.HomeKernelCodegen;
const JSEntrypointLLVM = codegen_mod.JSEntrypointLLVM;
const TypeChecker = @import("types").TypeChecker;
const comptime_mod = @import("comptime");
const ComptimeValueStore = comptime_mod.integration.ComptimeValueStore;
const ComptimeExecutor = comptime_mod.ComptimeExecutor;
const Formatter = @import("formatter").Formatter;
const DiagnosticReporter = @import("diagnostics").DiagnosticReporter;
const EnhancedReporter = @import("diagnostics").enhanced_reporter.EnhancedReporter;
const BorrowCheckPass = @import("compiler").BorrowCheckPass;
const optimizer_mod = @import("optimizer");
const PassManager = optimizer_mod.PassManager;
const MacroSystem = @import("macros").MacroSystem;
const pkg_manager_mod = @import("pkg_manager");
const PackageManager = pkg_manager_mod.PackageManager;
const AuthManager = pkg_manager_mod.AuthManager;
const ir_cache_mod = @import("ir_cache");
const IRCache = ir_cache_mod.IRCache;
const IncrementalCompiler = ir_cache_mod.IncrementalCompiler;
const build_options = @import("build_options");
const profiler_mod = @import("profiler.zig");
const AllocationProfiler = profiler_mod.AllocationProfiler;
const repl = @import("repl.zig");
const lint_cmd = @import("lint_command.zig");
const package_cmd = @import("package_command.zig");
const home_test = @import("home_test");
const home_rt = @import("home_rt");

const Io = std.Io;
var g_io: Io = undefined;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Get monotonic timestamp in nanoseconds (Zig 0.17 compatible)
fn getMonotonicNs() u64 {
    if (comptime native_os == .windows) {
        const ntdll = std.os.windows.ntdll;
        var counter: i64 = undefined;
        var freq: i64 = undefined;
        _ = ntdll.RtlQueryPerformanceCounter(&counter);
        _ = ntdll.RtlQueryPerformanceFrequency(&freq);
        return @intCast(@divFloor(@as(i128, counter) * std.time.ns_per_s, @as(i128, freq)));
    } else if (comptime native_os == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    } else {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
}

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

const TomlScript = struct {
    name: []const u8,
    command: []const u8,
};

fn parseTomlScripts(allocator: std.mem.Allocator, toml_content: []const u8) !std.ArrayList(TomlScript) {
    var scripts = std.ArrayList(TomlScript).empty;
    errdefer scripts.deinit(allocator);

    var in_scripts_section = false;
    var lines = std.mem.splitScalar(u8, toml_content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Check for [scripts] section
        if (std.mem.eql(u8, trimmed, "[scripts]")) {
            in_scripts_section = true;
            continue;
        }

        // Check if we've left the scripts section
        if (in_scripts_section and trimmed.len > 0 and trimmed[0] == '[') {
            in_scripts_section = false;
            continue;
        }

        // Parse script entries in the scripts section
        if (in_scripts_section and trimmed.len > 0 and trimmed[0] != '#') {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const name = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                var command = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                // Remove quotes if present
                if (command.len >= 2 and command[0] == '"' and command[command.len - 1] == '"') {
                    command = command[1 .. command.len - 1];
                }

                const name_copy = try allocator.dupe(u8, name);
                errdefer allocator.free(name_copy);
                const command_copy = try allocator.dupe(u8, command);
                errdefer allocator.free(command_copy);

                try scripts.append(allocator, .{
                    .name = name_copy,
                    .command = command_copy,
                });
            }
        }
    }

    return scripts;
}

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
        \\  check <path>       Type check an Home file or directory
        \\  explain <code>     Explain a diagnostic code
        \\  lint <file>        Lint and show diagnostics
        \\  lint --fix <file>  Lint and auto-fix issues
        \\  fmt <file>         Format and auto-fix (alias for lint --fix)
        \\  fix [path]         Lint, auto-fix, and format Home files
        \\  dev [script|file]  Run the best local development workflow
        \\  lsp [--stdio]      Start or inspect the Home language server
        \\  symbols [path]     List public declarations in a file or directory
        \\  docs [path]        Generate Markdown API docs from declarations
        \\  completions <sh>   Print shell completions for bash, zsh, or fish
        \\  doctor             Check local Home development setup
        \\  clean              Remove Home/Zig build caches
        \\  ci [path]          Run doctor, check, and declaration generation
        \\  api-diff <old> <new>
        \\                     Compare two .d.hm declaration files
        \\  size [path]        Show package/build size report
        \\  run <file|script>  Execute an Home, JS, or TS file (or package.json script)
        \\  build <file>       Compile a Home, JS, or TS entrypoint to a native binary
        \\  watch <file>       Watch file for changes and auto-recompile (hot reload)
        \\  test / t [opts]    Run tests (auto-routes to JS runtime when package.json is present)
        \\  profile <file>     Profile memory allocations during compilation
        \\  package [opts]     Create distributable packages (--help for options)
        \\
        \\  add <pkg>          Add a dependency via Pantry
        \\  install            Install dependencies via Pantry
        \\  remove <pkg>       Remove a dependency via Pantry
        \\  update [pkg]       Update dependencies via Pantry
        \\  outdated           Show outdated dependencies via Pantry
        \\  audit              Audit dependencies via Pantry
        \\  x <pkg> [args]     Run a package binary without installing (homex)
        \\  exec <pkg> [args]  Alias for `home x`
        \\  create <template>  Bootstrap a new project from a template
        \\
        \\  {s}Package Management:{s}
        \\  pkg init           Initialize a new Home project with home.toml
        \\  pkg add <name>     Add a dependency (registry package)
        \\  pkg add <url>      Add from GitHub (user/repo) or URL
        \\  pkg remove <name>  Remove a dependency
        \\  pkg update         Update all dependencies to latest versions
        \\  pkg install        Install dependencies from home.toml
        \\  pkg tools          Install project tools with pantry
        \\  pkg search <query> Search packages through pantry
        \\  pkg info <name>    Show package metadata through pantry
        \\  pkg audit          Audit dependencies through pantry
        \\  pkg dedupe         Dedupe dependency installs through pantry
        \\  pkg publish        Publish package through pantry
        \\  pkg size           Show package/build size report
        \\  pkg docs           Generate Markdown API docs from .d.hm metadata
        \\  pkg tree           Show dependency tree
        \\  pkg why <name>     Explain why a dependency is present
        \\  pkg outdated       Show dependency update candidates
        \\  pkg declarations   Generate Home API declarations (.d.hm)
        \\  pkg declarations --check
        \\                     Verify generated declarations are current
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
        \\  home check src/
        \\  home explain T0001
        \\  home api-diff old.d.hm new.d.hm
        \\  home dev
        \\  home completions zsh
        \\  home docs src --out docs/API.md
        \\  home fix src/
        \\  home doctor
        \\  home ci
        \\  home run hello.home
        \\  home build hello.home -o hello
        \\  home build server.ts -o server
        \\  home test src/
        \\
        \\  home pkg init
        \\  home pkg add http-router@1.0.0
        \\  home pkg add home-lang/awesome-lib
        \\  home pkg install
        \\  home pkg tools
        \\  home pkg audit
        \\  home pkg publish --dry-run
        \\  home pkg declarations
        \\  home pkg docs
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
    const source = Io.Dir.cwd().readFileAlloc(g_io, file_path, allocator, std.Io.Limit.unlimited) catch |err| {
        std.debug.print("{s}Error:{s} Failed to read file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
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
        .MacroExpr => |macro| {
            std.debug.print("{s}{s}!{s}(", .{ Color.Magenta.code(), macro.name, Color.Reset.code() });
            for (macro.args, 0..) |arg, i| {
                if (i > 0) std.debug.print(", ", .{});
                printExpr(arg, indent);
            }
            std.debug.print(")", .{});
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
    const source = Io.Dir.cwd().readFileAlloc(g_io, file_path, allocator, std.Io.Limit.unlimited) catch |err| {
        std.debug.print("{s}Error:{s} Failed to read file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
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
    parser.source_text = source;
    parser.source_file = file_path;

    // Set source root for module resolution based on the file being compiled
    try parser.module_resolver.setSourceRoot(file_path);

    const program = try parser.parse();

    // Print header
    std.debug.print("{s}AST for:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    std.debug.print("{s}Statements:{s} {d}\n\n", .{ Color.Blue.code(), Color.Reset.code(), program.statements.len });

    // Print AST
    for (program.statements) |stmt| {
        printStmt(stmt, 0);
    }

    // Surface parse errors with the same shape `home check` does.
    // Previously `ast` printed `Success` even when `parser.errors` was
    // non-empty, which masked real parse failures from the audit and
    // led to ~52 home-os files being misclassified as "type-check
    // failures" when they actually fail at parse. (Issue #36.)
    //
    // The Parser already prints each error inline via `reportError` and
    // emits a `N parse error(s) found` summary at the end of `parse()`.
    // Here we just refuse to claim success and exit non-zero so the
    // audit and downstream tooling sees a parse failure.
    if (parser.errors.items.len > 0) {
        std.debug.print(
            "\n{s}Failure:{s} {d} parse error(s) — AST is partial\n",
            .{ Color.Red.code(), Color.Reset.code(), parser.errors.items.len },
        );
        std.process.exit(1);
    }

    std.debug.print("\n{s}Success:{s} Parsed {d} statements\n", .{ Color.Green.code(), Color.Reset.code(), program.statements.len });
}

fn checkFile(allocator: std.mem.Allocator, file_path: []const u8) !bool {
    // Read the file
    const source = Io.Dir.cwd().readFileAlloc(g_io, file_path, allocator, std.Io.Limit.unlimited) catch |err| {
        std.debug.print("{s}Error:{s} Failed to read file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
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
    parser.source_text = source;
    parser.source_file = file_path;

    // Set source root for module resolution based on the file being compiled
    try parser.module_resolver.setSourceRoot(file_path);

    const program = try parser.parse();

    // Parse errors are collected into parser.errors but `parse()`
    // returns a partial AST so the type checker can still run for
    // richer diagnostics. Setting HOME_STRICT=1 fails the command
    // on ANY parse error; the default keeps the older loose behavior
    // so existing regression sweeps don't fail on pre-existing quirks.
    const strict_env = std.c.getenv("HOME_STRICT");
    const strict = strict_env != null and strict_env.?[0] != 0;
    const had_parse_errors = parser.errors.items.len > 0;

    // Create comptime value store for compile-time evaluation
    var comptime_store = ComptimeValueStore.init(allocator);
    defer comptime_store.deinit();

    // Type check with source path for import resolution
    var type_checker = TypeChecker.initWithSourcePath(allocator, program, file_path);
    type_checker.comptime_store = &comptime_store;
    defer type_checker.deinit();

    std.debug.print("{s}Checking:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });

    const passed = try type_checker.check();

    if (!passed or (strict and had_parse_errors)) {
        // Display rich type errors with enhanced formatting
        for (type_checker.errors.items) |err_info| {
            try printEnhancedError(file_path, source, err_info);
        }
        return false;
    } else {
        std.debug.print("{s}Success:{s} Type checking passed ✓\n", .{ Color.Green.code(), Color.Reset.code() });
        return true;
    }
}

fn checkCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    if (!try checkFile(allocator, file_path)) {
        std.process.exit(1);
    }
}

fn checkPathCommand(allocator: std.mem.Allocator, path: []const u8) !void {
    const stat = Io.Dir.cwd().statFile(g_io, path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Cannot read '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), path, err });
        return err;
    };

    if (stat.kind == .file) {
        try checkCommand(allocator, path);
        return;
    }

    var files = std.ArrayList([]const u8).empty;
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    try collectHomeSourceFiles(allocator, path, &files);
    if (files.items.len == 0) {
        std.debug.print("{s}No Home source files found in {s}.{s}\n", .{ Color.Yellow.code(), path, Color.Reset.code() });
        return;
    }

    std.debug.print("{s}Checking {d} Home file(s)...{s}\n\n", .{ Color.Blue.code(), files.items.len, Color.Reset.code() });
    var failed: usize = 0;
    for (files.items) |file| {
        if (!try checkFile(allocator, file)) {
            failed += 1;
        }
    }

    if (failed > 0) {
        std.debug.print("\n{s}Error:{s} {d} of {d} file(s) failed checks\n", .{ Color.Red.code(), Color.Reset.code(), failed, files.items.len });
        std.process.exit(1);
    }

    std.debug.print("\n{s}Success:{s} Checked {d} file(s)\n", .{ Color.Green.code(), Color.Reset.code(), files.items.len });
}

const DiagnosticExplanation = struct {
    code: []const u8,
    title: []const u8,
    meaning: []const u8,
    fix: []const u8,
};

const diagnostic_explanations = [_]DiagnosticExplanation{
    .{ .code = "T0001", .title = "Type mismatch", .meaning = "A value does not match the type expected by an annotation, expression, or function signature.", .fix = "Check the expected and found types, then add an explicit conversion or change the value/source type." },
    .{ .code = "T0002", .title = "Cannot infer type", .meaning = "The checker needs more information to choose a concrete type.", .fix = "Add a type annotation or provide a non-empty literal/context that constrains the type." },
    .{ .code = "V0001", .title = "Undefined variable", .meaning = "A name is used before it is declared or imported.", .fix = "Check spelling, move the declaration earlier, or import the symbol." },
    .{ .code = "M0001", .title = "Cannot mutate immutable variable", .meaning = "A value declared immutable is assigned again or mutated.", .fix = "Use `let mut` when mutation is intentional, otherwise create a new value." },
    .{ .code = "F0001", .title = "Argument count mismatch", .meaning = "A function call supplied too few or too many arguments.", .fix = "Update the call or the function signature; prefer named/default parameters when they clarify intent." },
    .{ .code = "R0001", .title = "Missing return", .meaning = "A function promises a value but not every path returns one.", .fix = "Return the expected value from every branch or change the return type." },
    .{ .code = "P0001", .title = "Non-exhaustive match", .meaning = "A match expression does not cover every possible input shape.", .fix = "Add the missing patterns or an explicit wildcard branch." },
    .{ .code = "A0001", .title = "Division by zero", .meaning = "A compile-time constant expression divides by zero.", .fix = "Guard the divisor or change the constant expression." },
    .{ .code = "A0002", .title = "Index out of bounds", .meaning = "A known index is outside a known collection length.", .fix = "Use a valid index, check length first, or use safe indexing with `?[]`." },
    .{ .code = "W0001", .title = "Unreachable code", .meaning = "Code appears after a control-flow terminator like return or panic.", .fix = "Remove the dead code or move it before the terminating statement." },
    .{ .code = "W0002", .title = "Unused variable", .meaning = "A binding is declared but not read.", .fix = "Remove it, use it, or add an explicit lint-disable comment when intentional." },
    .{ .code = "C0001", .title = "Comptime error", .meaning = "Compile-time evaluation failed.", .fix = "Inspect the comptime expression and make sure it is deterministic and valid at compile time." },
};

fn explainCommand(code: []const u8) void {
    for (diagnostic_explanations) |entry| {
        if (std.mem.eql(u8, entry.code, code)) {
            std.debug.print("{s}{s}: {s}{s}\n\n", .{ Color.Blue.code(), entry.code, entry.title, Color.Reset.code() });
            std.debug.print("Meaning: {s}\n", .{entry.meaning});
            std.debug.print("Fix:     {s}\n", .{entry.fix});
            return;
        }
    }

    std.debug.print("{s}Unknown diagnostic code:{s} {s}\n", .{ Color.Yellow.code(), Color.Reset.code(), code });
    std.debug.print("Known codes:", .{});
    for (diagnostic_explanations) |entry| {
        std.debug.print(" {s}", .{entry.code});
    }
    std.debug.print("\n", .{});
}

/// Print an enhanced error message with colors, context, and suggestions
fn printEnhancedError(file_path: []const u8, source: []const u8, err_info: TypeChecker.TypeErrorInfo) !void {
    // Error header with red "error:"
    std.debug.print("{s}error{s}: {s}\n", .{
        Color.Red.code(),
        Color.Reset.code(),
        err_info.message,
    });

    // If we have expected/actual types, show them
    if (err_info.expected != null and err_info.actual != null) {
        std.debug.print("  {s}expected:{s} {s}{s}{s}\n", .{
            Color.Cyan.code(),
            Color.Reset.code(),
            Color.Green.code(),
            err_info.expected.?,
            Color.Reset.code(),
        });
        std.debug.print("  {s}   found:{s} {s}{s}{s}\n", .{
            Color.Cyan.code(),
            Color.Reset.code(),
            Color.Red.code(),
            err_info.actual.?,
            Color.Reset.code(),
        });
        std.debug.print("\n", .{});
    }

    // Location: --> file:line:column
    std.debug.print("  {s}-->{s} {s}:{d}:{d}\n", .{
        Color.Blue.code(),
        Color.Reset.code(),
        file_path,
        err_info.loc.line,
        err_info.loc.column,
    });

    // Extract and display source line
    const source_line = getSourceLine(source, err_info.loc.line);
    if (source_line) |line| {
        // Line gutter
        std.debug.print("   {s}|{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

        // Source line with line number
        std.debug.print(" {s}{d:3}{s} {s}|{s} {s}\n", .{
            Color.Blue.code(),
            err_info.loc.line,
            Color.Reset.code(),
            Color.Blue.code(),
            Color.Reset.code(),
            line,
        });

        // Caret pointing to error
        std.debug.print("   {s}|{s} ", .{ Color.Blue.code(), Color.Reset.code() });

        var i: usize = 0;
        while (i < err_info.loc.column) : (i += 1) {
            std.debug.print(" ", .{});
        }
        std.debug.print("{s}^{s}\n", .{ Color.Red.code(), Color.Reset.code() });
    }

    // Suggestion if available
    if (err_info.suggestion) |suggestion| {
        std.debug.print("   {s}|{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
        std.debug.print("   {s}={s} help:{s} {s}\n", .{
            Color.Cyan.code(),
            Color.Reset.code(),
            Color.Reset.code(),
            suggestion,
        });
    }

    std.debug.print("\n", .{});
}

/// Extract a specific line from source code
fn getSourceLine(source: []const u8, target_line: usize) ?[]const u8 {
    var line: usize = 1;
    var line_start: usize = 0;

    for (source, 0..) |c, i| {
        if (c == '\n') {
            if (line == target_line) {
                return source[line_start..i];
            }
            line += 1;
            line_start = i + 1;
        }
    }

    // Last line (no trailing newline)
    if (line == target_line) {
        return source[line_start..];
    }

    return null;
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

fn fmtCommand(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    // fmt is an alias for lint --fix
    // Build new args array with --fix flag
    var new_args = std.ArrayList([:0]const u8).empty;
    defer new_args.deinit(allocator);

    try new_args.append(allocator, try home_rt.dupeZ(allocator, u8, "--fix"));
    for (args) |arg| {
        try new_args.append(allocator, arg);
    }

    try lint_cmd.lintCommand(allocator, new_args.items, g_io);
}

fn collectHomeSourceFiles(allocator: std.mem.Allocator, path: []const u8, files: *std.ArrayList([]const u8)) !void {
    const stat = Io.Dir.cwd().statFile(g_io, path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Cannot read '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), path, err });
        return err;
    };

    if (stat.kind == .file) {
        if (std.mem.endsWith(u8, path, ".home") or std.mem.endsWith(u8, path, ".hm")) {
            try files.append(allocator, try allocator.dupe(u8, path));
        }
        return;
    }

    if (stat.kind != .directory) return;

    var dir = try Io.Dir.cwd().openDir(g_io, path, .{ .iterate = true });
    defer dir.close(g_io);

    var iter = dir.iterate();
    while (try iter.next(g_io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git") or
            std.mem.eql(u8, entry.name, ".home") or
            std.mem.eql(u8, entry.name, "zig-cache") or
            std.mem.eql(u8, entry.name, ".zig-cache") or
            std.mem.eql(u8, entry.name, "zig-out") or
            std.mem.eql(u8, entry.name, "node_modules") or
            std.mem.eql(u8, entry.name, "pantry_modules"))
        {
            continue;
        }

        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);

        if (entry.kind == .file) {
            if (std.mem.endsWith(u8, child, ".home") or std.mem.endsWith(u8, child, ".hm")) {
                try files.append(allocator, try allocator.dupe(u8, child));
            }
        } else if (entry.kind == .directory) {
            try collectHomeSourceFiles(allocator, child, files);
        }
    }
}

fn fixCommand(allocator: std.mem.Allocator, target: []const u8) !void {
    var files = std.ArrayList([]const u8).empty;
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    try collectHomeSourceFiles(allocator, target, &files);
    if (files.items.len == 0) {
        std.debug.print("{s}No Home source files found in {s}.{s}\n", .{ Color.Yellow.code(), target, Color.Reset.code() });
        return;
    }

    std.debug.print("{s}Fixing {d} Home file(s)...{s}\n\n", .{ Color.Blue.code(), files.items.len, Color.Reset.code() });
    for (files.items) |file| {
        const file_arg = try home_rt.dupeZ(allocator, u8, file);
        defer allocator.free(file_arg);
        try fmtCommand(allocator, &.{file_arg});
    }
}

fn runShellCommand(allocator: std.mem.Allocator, command: []const u8) !void {
    var child = try std.process.spawn(g_io, .{
        .argv = &[_][]const u8{ "sh", "-c", command },
    });
    _ = allocator;
    const term = try child.wait(g_io);
    switch (term) {
        .exited => |code| {
            if (code != 0) std.process.exit(code);
        },
        else => std.process.exit(1),
    }
}

fn findScriptCommand(allocator: std.mem.Allocator, script_name: []const u8) !?[]const u8 {
    const toml_content = Io.Dir.cwd().readFileAlloc(g_io, "home.toml", allocator, std.Io.Limit.limited(1024 * 1024)) catch return null;
    defer allocator.free(toml_content);

    var scripts = try parseTomlScripts(allocator, toml_content);
    defer {
        for (scripts.items) |script| {
            allocator.free(script.name);
            allocator.free(script.command);
        }
        scripts.deinit(allocator);
    }

    for (scripts.items) |script| {
        if (std.mem.eql(u8, script.name, script_name)) {
            return try allocator.dupe(u8, script.command);
        }
    }

    return null;
}

fn devCommand(allocator: std.mem.Allocator, target: ?[]const u8) !void {
    if (target) |value| {
        if (std.mem.endsWith(u8, value, ".home") or std.mem.endsWith(u8, value, ".hm")) {
            try watchCommand(allocator, value);
            return;
        }

        if (try findScriptCommand(allocator, value)) |script| {
            defer allocator.free(script);
            std.debug.print("{s}Running dev script:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), value });
            try runShellCommand(allocator, script);
            return;
        }

        std.debug.print("{s}Error:{s} no script or Home file named '{s}'\n", .{ Color.Red.code(), Color.Reset.code(), value });
        std.process.exit(1);
    }

    if (try findScriptCommand(allocator, "dev")) |script| {
        defer allocator.free(script);
        std.debug.print("{s}Running dev script:{s} dev\n\n", .{ Color.Blue.code(), Color.Reset.code() });
        try runShellCommand(allocator, script);
        return;
    }

    Io.Dir.cwd().access(g_io, "src/main.home", .{}) catch {
        Io.Dir.cwd().access(g_io, "src/main.hm", .{}) catch {
            std.debug.print("{s}Error:{s} no dev script or src/main.home found\n", .{ Color.Red.code(), Color.Reset.code() });
            std.debug.print("Create a [scripts] dev entry in home.toml or run `home dev <file>`.\n", .{});
            std.process.exit(1);
        };
        try watchCommand(allocator, "src/main.hm");
        return;
    };

    try watchCommand(allocator, "src/main.home");
}

fn lspCommand(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var stdio = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--stdio")) stdio = true;
    }

    if (!stdio) {
        std.debug.print(
            \\{s}Home LSP{s}
            \\
            \\Capabilities:
            \\  - text sync
            \\  - completion
            \\  - hover
            \\  - go to definition
            \\  - references
            \\  - formatting
            \\  - code actions
            \\  - rename
            \\  - signature help
            \\
            \\Run with: home lsp --stdio
            \\
        , .{ Color.Blue.code(), Color.Reset.code() });
        return;
    }

    try runLspStdio(allocator);
}

const LspRequest = struct {
    id_json: ?[]u8,
    method: []const u8,
};

fn readLspMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var content_length: usize = 0;

    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return null,
            error.StreamTooLong => return error.StreamTooLong,
        } orelse return null;

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) break;

        if (std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")) {
            const value = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }

    if (content_length == 0) return error.InvalidLspMessage;

    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);
    try reader.readSliceAll(body);
    return body;
}

fn jsonValueToOwnedText(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

fn parseLspRequest(allocator: std.mem.Allocator, message: []const u8) !LspRequest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, message, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidLspMessage,
    };

    const method_value = obj.get("method") orelse return error.InvalidLspMessage;
    const method = switch (method_value) {
        .string => |value| value,
        else => return error.InvalidLspMessage,
    };

    var id_json: ?[]u8 = null;
    if (obj.get("id")) |id_value| {
        id_json = try jsonValueToOwnedText(allocator, id_value);
    }
    errdefer if (id_json) |value| allocator.free(value);

    return .{
        .id_json = id_json,
        .method = try allocator.dupe(u8, method),
    };
}

fn deinitLspRequest(allocator: std.mem.Allocator, request: *LspRequest) void {
    if (request.id_json) |value| allocator.free(value);
    allocator.free(request.method);
}

fn lspResponse(allocator: std.mem.Allocator, id_json: []const u8, result_json: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"result":{s}}}
    , .{ id_json, result_json });
}

fn lspErrorResponse(allocator: std.mem.Allocator, id_json: []const u8, code: i32, message: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"error":{{"code":{d},"message":{f}}}}}
    , .{ id_json, code, std.json.fmt(message, .{}) });
}

fn writeLspMessage(writer: *std.Io.Writer, payload: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    try writer.flush();
}

fn handleLspRequest(allocator: std.mem.Allocator, request: LspRequest) !?[]u8 {
    const id_json = request.id_json orelse {
        return null;
    };

    if (std.mem.eql(u8, request.method, "initialize")) {
        return try lspResponse(allocator, id_json,
            \\{"serverInfo":{"name":"home-lsp","version":"0.1.0"},"capabilities":{"textDocumentSync":1,"completionProvider":{"triggerCharacters":[".",":","@"]},"hoverProvider":true,"definitionProvider":true,"referencesProvider":true,"documentFormattingProvider":true,"documentSymbolProvider":true,"workspaceSymbolProvider":true,"codeActionProvider":true,"renameProvider":{"prepareProvider":true},"signatureHelpProvider":{"triggerCharacters":["(",","]},"semanticTokensProvider":{"legend":{"tokenTypes":["namespace","type","class","enum","interface","struct","typeParameter","parameter","variable","property","function","method","keyword","comment","string","number","operator"],"tokenModifiers":["declaration","definition","readonly","static","deprecated","abstract","async","modification"]},"full":true,"range":true}}}
        );
    }

    if (std.mem.eql(u8, request.method, "shutdown")) {
        return try lspResponse(allocator, id_json, "null");
    }

    if (std.mem.eql(u8, request.method, "textDocument/completion")) {
        return try lspResponse(allocator, id_json,
            \\{"isIncomplete":false,"items":[{"label":"fn","kind":14,"detail":"function declaration","insertText":"fn ${1:name}(${2:args}) ${3:Return} {\\n\\t$0\\n}","insertTextFormat":2},{"label":"struct","kind":14,"detail":"struct declaration","insertText":"struct ${1:Name} {\\n\\t$0\\n}","insertTextFormat":2},{"label":"match","kind":14,"detail":"pattern match","insertText":"match ${1:value} {\\n\\t${2:pattern} => ${3:result},\\n\\t_ => $0,\\n}","insertTextFormat":2},{"label":"Result","kind":7,"detail":"Result<T, E>"},{"label":"Option","kind":7,"detail":"Option<T>"},{"label":"async","kind":14},{"label":"await","kind":14},{"label":"comptime","kind":14},{"label":"export","kind":14},{"label":"trait","kind":14}]}
        );
    }

    if (std.mem.eql(u8, request.method, "textDocument/hover")) {
        return try lspResponse(allocator, id_json,
            \\{"contents":{"kind":"markdown","value":"Home language server\\n\\nUse `home explain <code>` for detailed diagnostics and `home pkg declarations` to emit `.d.hm` API declarations."}}
        );
    }

    if (std.mem.eql(u8, request.method, "textDocument/definition") or
        std.mem.eql(u8, request.method, "textDocument/rename") or
        std.mem.eql(u8, request.method, "textDocument/prepareRename"))
    {
        return try lspResponse(allocator, id_json, "null");
    }

    if (std.mem.eql(u8, request.method, "textDocument/references") or
        std.mem.eql(u8, request.method, "textDocument/documentSymbol") or
        std.mem.eql(u8, request.method, "textDocument/formatting") or
        std.mem.eql(u8, request.method, "textDocument/codeAction") or
        std.mem.eql(u8, request.method, "textDocument/semanticTokens/full") or
        std.mem.eql(u8, request.method, "textDocument/semanticTokens/range") or
        std.mem.eql(u8, request.method, "workspace/symbol"))
    {
        return try lspResponse(allocator, id_json, "[]");
    }

    if (std.mem.eql(u8, request.method, "textDocument/signatureHelp")) {
        return try lspResponse(allocator, id_json,
            \\{"signatures":[{"label":"fn name(args) Return","documentation":"Home function signature","parameters":[{"label":"args"}]}],"activeSignature":0,"activeParameter":0}
        );
    }

    return try lspErrorResponse(allocator, id_json, -32601, "Home LSP method is not implemented yet");
}

fn runLspStdio(allocator: std.mem.Allocator) !void {
    const stdin_file = std.Io.File.stdin();
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader_impl = stdin_file.readerStreaming(g_io, &stdin_buffer);
    const reader = &stdin_reader_impl.interface;

    const stdout_file = std.Io.File.stdout();
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer_impl = stdout_file.writerStreaming(g_io, &stdout_buffer);
    const writer = &stdout_writer_impl.interface;
    defer writer.flush() catch {};

    while (true) {
        const message = try readLspMessage(allocator, reader) orelse break;
        defer allocator.free(message);

        var request = parseLspRequest(allocator, message) catch |err| {
            const response = try lspErrorResponse(allocator, "null", -32700, @errorName(err));
            defer allocator.free(response);
            try writeLspMessage(writer, response);
            continue;
        };
        defer deinitLspRequest(allocator, &request);

        if (std.mem.eql(u8, request.method, "exit")) {
            break;
        }

        const response = try handleLspRequest(allocator, request) orelse continue;
        defer allocator.free(response);
        try writeLspMessage(writer, response);
    }
}

fn commandAvailable(command: []const u8, arg: []const u8) bool {
    var child = std.process.spawn(g_io, .{
        .argv = &[_][]const u8{ command, arg },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;

    const term = child.wait(g_io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn doctorCheck(ok: bool, label: []const u8, detail: []const u8) void {
    if (ok) {
        std.debug.print("{s}✓{s} {s}\n", .{ Color.Green.code(), Color.Reset.code(), label });
    } else {
        std.debug.print("{s}✗{s} {s}: {s}\n", .{ Color.Red.code(), Color.Reset.code(), label, detail });
    }
}

fn fileExists(path: []const u8) bool {
    Io.Dir.cwd().access(g_io, path, .{}) catch return false;
    return true;
}

fn doctorCommand(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Home Doctor{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    doctorCheck(commandAvailable("zig", "version"), "zig is available", "install with Pantry or add zig to PATH");
    doctorCheck(commandAvailable("bun", "--version"), "bun is available", "install with Pantry or add bun to PATH");
    doctorCheck(commandAvailable("pantry", "--version"), "pantry is available", "install with: curl -fsSL https://pantry.dev | bash");
    doctorCheck(fileExists("bunfig.toml"), "bunfig.toml exists", "required when better-dx provides peer tooling");
    doctorCheck(fileExists("deps.yaml") or fileExists("dependencies.yaml") or fileExists("pantry.yaml"), "Pantry dependency file exists", "run `home pkg init` to create deps.yaml");

    const package_json = Io.Dir.cwd().readFileAlloc(g_io, "package.json", allocator, std.Io.Limit.limited(1024 * 1024)) catch null;
    if (package_json) |content| {
        defer allocator.free(content);
        const has_better_dx = std.mem.indexOf(u8, content, "\"better-dx\"") != null;
        const has_direct_typescript = std.mem.indexOf(u8, content, "\"typescript\"") != null;
        doctorCheck(!has_better_dx or !has_direct_typescript, "better-dx peer dependency hygiene", "remove direct typescript when better-dx is present");
    } else {
        doctorCheck(true, "package.json optional", "no package.json found");
    }

    std.debug.print("\nRun {s}home pkg tools{s} to install project tools through Pantry.\n", .{ Color.Cyan.code(), Color.Reset.code() });
}

fn collectDeclarationLines(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList([]const u8) {
    const content = try Io.Dir.cwd().readFileAlloc(g_io, path, allocator, std.Io.Limit.limited(16 * 1024 * 1024));
    defer allocator.free(content);

    var lines = std.ArrayList([]const u8).empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "export ")) {
            try lines.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    return lines;
}

fn containsDeclaration(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |line| {
        if (std.mem.eql(u8, line, needle)) return true;
    }
    return false;
}

fn apiDiffCommand(allocator: std.mem.Allocator, old_path: []const u8, new_path: []const u8) !void {
    var old_lines = try collectDeclarationLines(allocator, old_path);
    defer {
        for (old_lines.items) |line| allocator.free(line);
        old_lines.deinit(allocator);
    }

    var new_lines = try collectDeclarationLines(allocator, new_path);
    defer {
        for (new_lines.items) |line| allocator.free(line);
        new_lines.deinit(allocator);
    }

    var removed: usize = 0;
    var added: usize = 0;

    std.debug.print("{s}API diff:{s} {s} -> {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), old_path, new_path });

    for (old_lines.items) |line| {
        if (!containsDeclaration(new_lines.items, line)) {
            removed += 1;
            std.debug.print("{s}- {s}{s}\n", .{ Color.Red.code(), line, Color.Reset.code() });
        }
    }

    for (new_lines.items) |line| {
        if (!containsDeclaration(old_lines.items, line)) {
            added += 1;
            std.debug.print("{s}+ {s}{s}\n", .{ Color.Green.code(), line, Color.Reset.code() });
        }
    }

    if (removed == 0 and added == 0) {
        std.debug.print("{s}No public API changes found.{s}\n", .{ Color.Green.code(), Color.Reset.code() });
        return;
    }

    std.debug.print("\nSummary: {d} added, {d} removed\n", .{ added, removed });
    if (removed > 0) {
        std.debug.print("{s}Breaking-change candidate:{s} removed declarations need review.\n", .{ Color.Yellow.code(), Color.Reset.code() });
    }
}

fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    if (bytes >= 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)}) catch "unknown";
    }
    if (bytes >= 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.2} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "unknown";
    }
    if (bytes >= 1024) {
        return std.fmt.bufPrint(buf, "{d:.2} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch "unknown";
    }
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "unknown";
}

fn sizeWalk(allocator: std.mem.Allocator, path: []const u8, total: *u64, files: *usize) !void {
    const stat = Io.Dir.cwd().statFile(g_io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    if (stat.kind == .file) {
        total.* += stat.size;
        files.* += 1;
        return;
    }

    if (stat.kind != .directory) return;

    var dir = try Io.Dir.cwd().openDir(g_io, path, .{ .iterate = true });
    defer dir.close(g_io);

    var iter = dir.iterate();
    while (try iter.next(g_io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git") or
            std.mem.eql(u8, entry.name, "node_modules") or
            std.mem.eql(u8, entry.name, "pantry_modules") or
            std.mem.eql(u8, entry.name, ".zig-cache") or
            std.mem.eql(u8, entry.name, "zig-cache"))
        {
            continue;
        }

        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        try sizeWalk(allocator, child, total, files);
    }
}

fn sizeCommand(allocator: std.mem.Allocator, target: []const u8) !void {
    var total: u64 = 0;
    var files: usize = 0;
    try sizeWalk(allocator, target, &total, &files);

    var buf: [64]u8 = undefined;
    std.debug.print("{s}Size report:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), target });
    std.debug.print("  Files: {d}\n", .{files});
    std.debug.print("  Total: {s}\n", .{formatBytes(&buf, total)});

    const interesting = [_][]const u8{ "zig-out", "dist", ".home", ".home-cache" };
    for (interesting) |path| {
        if (!fileExists(path)) continue;
        var sub_total: u64 = 0;
        var sub_files: usize = 0;
        try sizeWalk(allocator, path, &sub_total, &sub_files);
        var sub_buf: [64]u8 = undefined;
        std.debug.print("  {s:<12} {s:>12} ({d} files)\n", .{ path, formatBytes(&sub_buf, sub_total), sub_files });
    }
}

fn ciCommand(allocator: std.mem.Allocator, target: []const u8) !void {
    std.debug.print("{s}Home CI{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    try doctorCommand(allocator);
    std.debug.print("\n{s}Checking sources{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
    try checkPathCommand(allocator, target);

    std.debug.print("\n{s}Generating declarations{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
    try pkgDeclarations(allocator, &.{});

    std.debug.print("\n{s}✓ CI checks completed{s}\n", .{ Color.Green.code(), Color.Reset.code() });
}

fn writeStdout(bytes: []const u8) !void {
    const stdout_file = std.Io.File.stdout();
    try stdout_file.writeStreamingAll(g_io, bytes);
}

fn cleanCommand() !void {
    const paths = [_][]const u8{
        ".home-cache",
        ".zig-cache",
        "zig-cache",
        "zig-out",
        ".test-cache",
    };

    var removed: usize = 0;
    for (paths) |path| {
        if (!fileExists(path)) continue;
        Io.Dir.cwd().deleteTree(g_io, path) catch |err| {
            std.debug.print("{s}Warning:{s} could not remove {s}: {}\n", .{ Color.Yellow.code(), Color.Reset.code(), path, err });
            continue;
        };
        removed += 1;
        std.debug.print("{s}✓{s} Removed {s}\n", .{ Color.Green.code(), Color.Reset.code(), path });
    }

    if (removed == 0) {
        std.debug.print("{s}Nothing to clean.{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
    }
}

fn completionsCommand(shell_name: []const u8) !void {
    if (std.mem.eql(u8, shell_name, "bash")) {
        try writeStdout(
            \\_home_complete() {
            \\  local cur prev commands pkg_commands
            \\  COMPREPLY=()
            \\  cur="${COMP_WORDS[COMP_CWORD]}"
            \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
            \\  commands="init parse ast check explain lint fmt fix dev lsp symbols docs completions doctor clean ci api-diff size run build watch test t profile package pkg help"
            \\  pkg_commands="init add remove update install tools toolchain search info audit dedupe link unlink publish pack version doctor clean size tree why outdated declarations types d.hm api-diff docs run scripts login logout whoami"
            \\  if [[ "${COMP_WORDS[1]}" == "pkg" && ${COMP_CWORD} -eq 2 ]]; then
            \\    COMPREPLY=($(compgen -W "$pkg_commands" -- "$cur"))
            \\    return 0
            \\  fi
            \\  if [[ ${COMP_CWORD} -eq 1 ]]; then
            \\    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            \\  fi
            \\}
            \\complete -F _home_complete home
            \\
        );
        return;
    }

    if (std.mem.eql(u8, shell_name, "zsh")) {
        try writeStdout(
            \\#compdef home
            \\_home() {
            \\  local -a commands pkg_commands
            \\  commands=(init parse ast check explain lint fmt fix dev lsp symbols docs completions doctor clean ci api-diff size run build watch test t profile package pkg help)
            \\  pkg_commands=(init add remove update install tools toolchain search info audit dedupe link unlink publish pack version doctor clean size tree why outdated declarations types d.hm api-diff docs run scripts login logout whoami)
            \\  if [[ $words[2] == pkg ]]; then
            \\    _describe 'pkg command' pkg_commands
            \\  else
            \\    _describe 'command' commands
            \\  fi
            \\}
            \\_home "$@"
            \\
        );
        return;
    }

    if (std.mem.eql(u8, shell_name, "fish")) {
        try writeStdout(
            \\complete -c home -f -n '__fish_use_subcommand' -a 'init parse ast check explain lint fmt fix dev lsp symbols docs completions doctor clean ci api-diff size run build watch test t profile package pkg help'
            \\complete -c home -f -n '__fish_seen_subcommand_from pkg' -a 'init add remove update install tools toolchain search info audit dedupe link unlink publish pack version doctor clean size tree why outdated declarations types d.hm api-diff docs run scripts login logout whoami'
            \\
        );
        return;
    }

    std.debug.print("{s}Error:{s} unknown shell '{s}' (expected bash, zsh, or fish)\n", .{ Color.Red.code(), Color.Reset.code(), shell_name });
    std.process.exit(1);
}

fn symbolsCommand(allocator: std.mem.Allocator, target: []const u8) !void {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    const stat = Io.Dir.cwd().statFile(g_io, target, .{}) catch |err| {
        std.debug.print("{s}Error:{s} failed to inspect '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), target, err });
        return err;
    };

    const count = if (stat.kind == .file) blk: {
        const source = try Io.Dir.cwd().readFileAlloc(g_io, target, allocator, std.Io.Limit.limited(4 * 1024 * 1024));
        defer allocator.free(source);
        break :blk try emitDeclarationsFromSource(allocator, target, source, &output);
    } else if (stat.kind == .directory)
        try collectDeclarationsFromDir(allocator, target, &output)
    else
        0;

    std.debug.print("{s}Symbols:{s} {s} ({d})\n", .{ Color.Blue.code(), Color.Reset.code(), target, count });
    var lines = std.mem.splitScalar(u8, output.items, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "export ")) {
            std.debug.print("  {s}\n", .{line["export ".len..]});
        }
    }
}

fn docsCommand(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var src_dir: []const u8 = "src";
    var out_path: []const u8 = "docs/API.md";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if ((std.mem.eql(u8, args[i], "--out") or std.mem.eql(u8, args[i], "-o")) and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if ((std.mem.eql(u8, args[i], "--src") or std.mem.eql(u8, args[i], "-s")) and i + 1 < args.len) {
            i += 1;
            src_dir = args[i];
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            src_dir = args[i];
        }
    }

    const package_name = try detectPackageName(allocator);
    defer allocator.free(package_name);

    const rendered = try renderPackageDeclarations(allocator, package_name, src_dir);
    defer rendered.deinit(allocator);

    var markdown = std.ArrayList(u8).empty;
    defer markdown.deinit(allocator);

    try appendFmt(&markdown, allocator,
        \\# {s} API
        \\
        \\Generated from Home `.d.hm` declaration metadata.
        \\
    , .{package_name});

    var lines = std.mem.splitScalar(u8, rendered.content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "// ")) {
            try appendFmt(&markdown, allocator, "\n## {s}\n\n", .{line[3..]});
        } else if (std.mem.startsWith(u8, line, "export ")) {
            try appendFmt(&markdown, allocator, "- `{s}`\n", .{line["export ".len..]});
        }
    }

    if (std.fs.path.dirname(out_path)) |parent| {
        try Io.Dir.cwd().createDirPath(g_io, parent);
    }

    const file = try Io.Dir.cwd().createFile(g_io, out_path, .{});
    defer file.close(g_io);
    try file.writeStreamingAll(g_io, markdown.items);

    std.debug.print("{s}✓{s} Wrote {s} ({d} declarations)\n", .{ Color.Green.code(), Color.Reset.code(), out_path, rendered.count });
}

// ---- Phase 12 runtime delegation shim ---------------------------------
// Until packages/runtime/ is fully populated with copied Bun source (see
// docs/TS_PARITY_PLAN.md §12), the home CLI exposes the Bun-compatible
// command surface (`home run app.ts`, `home test`, `home add`, `home x`,
// …) by spawning the system `bun` or the Pantry CLI. Every delegation
// site carries a TODO(phase-12-N) marker so progressive replacement is
// mechanical as native implementations land.
//
// Resolution order: pantry-managed binaries first, then standard system
// locations. PATH lookup is intentionally skipped to avoid pulling in
// versions the user didn't install through Home/Pantry.

fn spawnInteractive(argv: []const []const u8) !void {
    var child = try std.process.spawn(g_io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(g_io);
    switch (term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn findBunBinary() ![]const u8 {
    const candidates = [_][]const u8{
        "/Users/chrisbreuer/.local/share/pantry/global/bin/bun",
        "/usr/local/bin/bun",
        "/opt/homebrew/bin/bun",
    };
    for (candidates) |c| {
        Io.Dir.cwd().access(g_io, c, .{}) catch continue;
        return c;
    }
    return error.BunNotFound;
}

fn findPantryBinary() ![]const u8 {
    const candidates = [_][]const u8{
        "/Users/chris/Code/pantry/packages/zig/zig-out/bin/pantry",
        "/Users/chris/Code/pantry/packages/zig/packages/zig/bin/pantry",
        "/Users/chrisbreuer/.local/share/pantry/global/bin/pantry",
        "/usr/local/bin/pantry",
        "/opt/homebrew/bin/pantry",
    };
    for (candidates) |c| {
        Io.Dir.cwd().access(g_io, c, .{}) catch continue;
        return c;
    }
    return error.PantryNotFound;
}

fn fileExtIsJsLike(path: []const u8) bool {
    const exts = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts" };
    for (exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

fn looksLikePackageScriptName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c == '/' or c == '\\') return false;
    }
    return true;
}

fn runJsLikeFile(allocator: std.mem.Allocator, file_path: []const u8, extra_args: []const [:0]const u8) !void {
    // Full-VM native run (HOME_NATIVE_VM=1): boot Home's VirtualMachine and run
    // the file through JSC's native module loader (handles ESM). Uses
    // home_rt.jsc.VirtualMachine directly (no bun.js.zig CLI cone). Experimental,
    // isolated behind its own flag while validated against the standalone binary.
    if (build_options.enable_jsc and envFlagSet("HOME_NATIVE_VM")) {
        runFileViaVM(allocator, file_path, extra_args) catch |err| {
            std.debug.print("{s}error:{s} native VM run failed: {s}\n", .{ Color.Red.code(), Color.Reset.code(), @errorName(err) });
            std.process.exit(1);
        };
        return;
    }

    // Opt-in native path (Phase 2): `HOME_NATIVE_RUN=1 home run file.js` runs
    // through Home's OWN JSC runtime for plain `.js`/`.cjs` (script-mode; ESM
    // `.mjs` and TS still delegate). Gated so the default path is unchanged and
    // the bun-corpus spawn tests (which use `home run`) keep passing.
    // Native (CommonJS + TypeScript): plain .js/.cjs run as-is; .ts/.cts/.tsx
    // are type-stripped via the transpiler bridge. ESM (.mjs / import-export)
    // still delegates — it needs the bundler link stage / JSC module loader.
    // Best-effort native run: CommonJS + TypeScript run through Home's own JSC
    // realm; ESM (and anything the transpiler can't lower yet) returns false so
    // we transparently fall back to bun delegation below — so the flag is always
    // safe to set. ESM native execution awaits the VirtualMachine/link stage.
    if (build_options.enable_jsc and envFlagSet("HOME_NATIVE_RUN") and
        (std.mem.endsWith(u8, file_path, ".js") or std.mem.endsWith(u8, file_path, ".cjs") or
            std.mem.endsWith(u8, file_path, ".ts") or std.mem.endsWith(u8, file_path, ".cts") or
            std.mem.endsWith(u8, file_path, ".tsx")))
    {
        if (try runFileNative(allocator, file_path, extra_args)) return;
        // else: unsupported (ESM) — fall through to bun delegation.
    }

    // TODO(phase-12-2): Replace this delegation with the native Home runtime
    // once `packages/runtime/src/jsc/` is populated.
    const bun_path = findBunBinary() catch {
        // No system `bun` (the Phase-12 delegation crutch is unavailable).
        // Fall back to Home's OWN VirtualMachine, which now runs ESM + CJS +
        // TS via JSC's native module loader (same path as `HOME_NATIVE_VM=1`
        // and `home -e`). This is the native-first direction; the bun
        // delegation above remains only for environments that still have a
        // `bun` on PATH, so this fallback is a strict improvement (it never
        // changes behavior when bun is present).
        if (build_options.enable_jsc) {
            runFileViaVM(allocator, file_path, extra_args) catch |err| {
                std.debug.print("{s}error:{s} native VM run failed: {s}\n", .{ Color.Red.code(), Color.Reset.code(), @errorName(err) });
                std.process.exit(1);
            };
            return;
        }
        std.debug.print("{s}Error:{s} `home run {s}`: no native JS/TS runtime yet (Phase 12 in progress) and the system `bun` binary was not found in pantry/global paths.\n", .{ Color.Red.code(), Color.Reset.code(), file_path });
        std.process.exit(1);
    };

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bun_path);
    try argv.append(allocator, "run");
    try argv.append(allocator, file_path);
    for (extra_args) |a| try argv.append(allocator, a);

    try spawnInteractive(argv.items);
}

fn execBunCommand(allocator: std.mem.Allocator, bun_subcommand: []const u8, extra_args: []const [:0]const u8) !void {
    // TODO(phase-12-8/12-10): Replace with copied-from-Bun command surface.
    const bun_path = findBunBinary() catch {
        std.debug.print("{s}Error:{s} `home {s}` needs the system `bun` binary while Phase 12 is in progress.\n", .{ Color.Red.code(), Color.Reset.code(), bun_subcommand });
        std.process.exit(1);
    };

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bun_path);
    try argv.append(allocator, bun_subcommand);
    for (extra_args) |a| try argv.append(allocator, a);

    try spawnInteractive(argv.items);
}

fn execPantryCommand(allocator: std.mem.Allocator, pantry_subcommand: []const u8, extra_args: []const [:0]const u8) !void {
    const pantry_path = findPantryBinary() catch {
        std.debug.print("{s}Error:{s} `home {s}` requires the Pantry CLI (~/Code/pantry).\n", .{ Color.Red.code(), Color.Reset.code(), pantry_subcommand });
        std.process.exit(1);
    };

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, pantry_path);
    try argv.append(allocator, pantry_subcommand);
    for (extra_args) |a| try argv.append(allocator, a);

    try spawnInteractive(argv.items);
}

/// Install the full native realm surface (console/process/web/crypto/timers/
/// misc/url/webcore/fetch/Bun/require) into `ctx`'s global. Shared by
/// `home eval` and the native `home run` path. `argv` becomes `process.argv`.
fn installRealmGlobals(allocator: std.mem.Allocator, ctx: anytype, global: anytype, argv: []const []const u8) void {
    home_rt.jsc.console_global.install(allocator, ctx, global);
    home_rt.jsc.process_global.install(allocator, ctx, global, argv);
    home_rt.jsc.web_globals.install(allocator, ctx, global);
    home_rt.jsc.crypto_global.install(allocator, ctx, global);
    home_rt.jsc.timers_global.install(allocator, ctx, global);
    home_rt.jsc.misc_globals.install(allocator, ctx, global);
    home_rt.jsc.url_global.install(allocator, ctx, global);
    home_rt.jsc.webcore_globals.install(allocator, ctx, global);
    home_rt.jsc.fetch_global.install(allocator, ctx, global);
    home_rt.jsc.bun_global.install(allocator, ctx, global);
    home_rt.jsc.password_global.install(allocator, ctx, global);
    home_rt.jsc.peek_global.install(allocator, ctx, global);
    home_rt.jsc.node_modules.install(allocator, ctx, global);
    home_rt.jsc.spawn_global.install(allocator, ctx, global);
    home_rt.jsc.dollar_global.install(allocator, ctx, global);
    home_rt.jsc.semver_global.install(allocator, ctx, global);
    home_rt.jsc.cookie_global.install(allocator, ctx, global);
    home_rt.jsc.toml_global.install(allocator, ctx, global);
    home_rt.jsc.serve_global.install(allocator, ctx, global);
    home_rt.jsc.socket_global.install(allocator, ctx, global);
}

/// True when env var `name` is set to a non-empty value.
fn envFlagSet(name: [*:0]const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return value[0] != 0;
}

/// Holds the booted VM + entry path across the JSC API-lock callback boundary.
/// Faithful port of `Run.start` (bun.js.zig): the entrypoint load AND the whole
/// event-loop drain MUST run inside `holdAPILock` — JSC operations are undefined
/// behavior outside the API lock, which was the root cause of the earlier
/// non-deterministic rc=0/133 flips and lost stdout in the native VM path.
const VmRunState = struct {
    vm: *home_rt.jsc.VirtualMachine,
    entry_path: []const u8,

    var instance: VmRunState = undefined;

    /// Runs under the API lock (invoked via OpaqueWrap from holdAPILock). Mirrors
    /// the non-watch, non-eval branch of `Run.start` (bun.js.zig:310-560): load the
    /// entry point as a module, report a rejected top-level promise, then drain the
    /// event loop until no async work remains, and tear down. globalExit is noreturn.
    /// After a run that left an unhandled error (an uncaught throw, an unhandled
    /// rejection, or a `reportError`), Bun prints a `\nBun v<version> (<os>
    /// <arch>)` footer to stderr. The bun.js.zig `Run.start` does this via
    /// `any_unhandled`; the native runner mirrors it so the trailing two lines
    /// (blank + version) are present — Bun's tests strip exactly those two lines,
    /// so omitting them shifts real content into the stripped window.
    fn printUnhandledFooterIfNeeded(vm: *home_rt.jsc.VirtualMachine) void {
        if (vm.unhandled_error_counter == 0) return;
        vm.exit_handler.exit_code = 1;
        home_rt.jsc.SavedSourceMap.MissingSourceMapNoteInfo.print();
        home_rt.Output.prettyErrorln("<r>\n<d>{s}<r>", .{home_rt.Global.unhandled_error_bun_version_string});
        home_rt.Output.flush();
    }

    fn start(this: *VmRunState) void {
        const vm = this.vm;

        if (vm.loadEntryPoint(this.entry_path)) |promise| {
            if (promise.status() == .rejected) {
                _ = vm.uncaughtException(vm.global, promise.result(vm.global.vm()), true);
                promise.setHandled();
                vm.exit_handler.exit_code = 1;
                home_rt.Output.flush();
                printUnhandledFooterIfNeeded(vm);
                vm.onExit();
                vm.globalExit();
            }
            _ = promise.result(vm.global.vm());
        } else |err| {
            std.debug.print("{s}error:{s} loading '{s}': {s}\n", .{ Color.Red.code(), Color.Reset.code(), this.entry_path, @errorName(err) });
            vm.exit_handler.exit_code = 1;
            home_rt.Output.flush();
            vm.onExit();
            vm.globalExit();
        }

        // Drain async work (timers, pending microtasks, TLA) to completion.
        while (vm.isEventLoopAlive()) {
            vm.tick();
            vm.eventLoop().autoTickActive();
        }
        vm.onBeforeExit();

        vm.global.handleRejectedPromises();
        // Flush buffered stdout/stderr (console.log) before the noreturn exit.
        home_rt.Output.flush();
        printUnhandledFooterIfNeeded(vm);
        vm.onExit();
        vm.globalExit();
    }
};

/// Run a file through Home's full VirtualMachine, which uses JSC's native
/// module loader (so ESM `import`/`export` work). Faithful port of `Run.boot`
/// (bun.js.zig:158-303): create the AST node stores, build a Mimalloc arena for
/// the VM allocator, init the VM, configure the transpiler/resolver, load env +
/// the source-code printer, mark the main-thread VM, then hand control to JSC via
/// `holdAPILock` so the entrypoint load + event loop run under the API lock.
///
/// The earlier minimal init was undefined behavior: it skipped the AST stores,
/// `loadExtraEnvAndSourceCodePrinter`, the main-thread-VM flag, and — critically —
/// ran loadEntryPoint OUTSIDE the API lock. Doing all of Run.boot's setup makes it
/// deterministic. Gated behind HOME_NATIVE_VM=1 while validated end-to-end.
/// Handle Bun-style inline-eval CLI invocations through the full VM:
/// `home [runtime-flags] (--print|-p) <expr>` and `home [runtime-flags]
/// (-e|--eval) <code>`. Returns true if it handled the args (in which case the
/// VM globalExits, so this never actually returns true), false otherwise.
/// `--expose-gc` exposes `globalThis.gc` (aliased to `Bun.gc`). The code runs
/// through `runFileViaVM` (real Bun globals) via a temp module, matching
/// `bun --print` / `bun -e`.
fn tryEvalFlagRun(allocator: std.mem.Allocator, args: []const [:0]const u8) !bool {
    if (comptime !build_options.enable_jsc) return false;
    var code: ?[]const u8 = null;
    var print_mode = false;
    var expose_gc = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--print") or std.mem.eql(u8, a, "-p")) {
            print_mode = true;
            if (i + 1 < args.len) {
                code = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--eval")) {
            if (i + 1 < args.len) {
                code = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, a, "--expose-gc")) {
            expose_gc = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            // Other leading runtime flags are accepted and ignored.
        } else if (code == null) {
            // A bare positional before any eval flag isn't ours (let the file
            // path / command handlers deal with it).
            return false;
        }
    }
    if (code == null) return false;

    // Assemble the module source: optional gc alias, then either the raw code
    // (`-e`) or a `console.log(<expr>)` wrapper (`--print`).
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(allocator);
    if (expose_gc) try src.appendSlice(allocator, "try { globalThis.gc = Bun.gc; } catch {}\n");
    if (print_mode) {
        try src.appendSlice(allocator, "console.log(");
        try src.appendSlice(allocator, code.?);
        try src.appendSlice(allocator, ");\n");
    } else {
        try src.appendSlice(allocator, code.?);
        try src.appendSlice(allocator, "\n");
    }

    // Write to a temp module and run it through the full VM.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Bun parses inline eval as TypeScript even when runtime flags precede
    // `-e` (the security-scanner bootstrap relies on this for its type-only
    // declarations), so keep the temp module on the TypeScript loader path.
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "/tmp/home-eval-{d}.ts", .{std.c.getpid()}) catch
        return false;
    Io.Dir.cwd().writeFile(g_io, .{ .sub_path = tmp_path, .data = src.items }) catch return false;
    runFileViaVMOpts(allocator, tmp_path, &.{}, true) catch |err| {
        std.debug.print("{s}error:{s} eval failed: {s}\n", .{ Color.Red.code(), Color.Reset.code(), @errorName(err) });
        std.process.exit(1);
    };
    return true;
}

/// Run `home -e <code>` (no `--print`) through the FULL VirtualMachine — the
/// same faithful path as a `.ts`/`.js` file run — instead of the reduced
/// `evalCommand` shim engine. `bun -e` treats inline source as TypeScript by
/// default, so the code is written to a `.ts` temp and the VM's real transpiler
/// strips the types. This gives inline eval the complete Bun runtime (real
/// globals) and, crucially, the faithful uncaught-error printer (source preview
/// + stack + version footer, lone-surrogate-safe) rather than the shim's bare
/// `error: <message>` line. `extra_args` become `process.argv[2..]`.
/// globalExits on success (noreturn via runFileViaVM), so it never returns true.
fn runInlineEvalViaVM(allocator: std.mem.Allocator, code: []const u8, extra_args: []const [:0]const u8) !void {
    if (comptime !build_options.enable_jsc) return error.JscDisabled;

    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(allocator);
    try src.appendSlice(allocator, code);
    try src.appendSlice(allocator, "\n");

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "/tmp/home-eval-{d}.ts", .{std.c.getpid()}) catch
        return error.NameTooLong;
    try Io.Dir.cwd().writeFile(g_io, .{ .sub_path = tmp_path, .data = src.items });
    try runFileViaVMOpts(allocator, tmp_path, extra_args, true);
}

/// Preload modules named via `--require`/`-r`/`--preload` on the implicit-run
/// command line; consumed by runFileViaVMOpts (set into `vm.preload`).
var g_user_preloads: []const []const u8 = &.{};

/// Custom export/import conditions named via `--conditions=<name>` on the
/// implicit-run command line; appended to the resolver's ESM condition set in
/// runFileViaVMOpts so `package.json` "exports"/"imports" match them.
var g_user_conditions: []const []const u8 = &.{};

fn runFileViaVM(allocator: std.mem.Allocator, file_path: []const u8, extra_args: []const [:0]const u8) !void {
    return runFileViaVMOpts(allocator, file_path, extra_args, false);
}

fn runFileViaVMOpts(allocator: std.mem.Allocator, file_path: []const u8, extra_args: []const [:0]const u8, inject_node_globals: bool) !void {
    if (comptime !build_options.enable_jsc) return error.JscDisabled;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CwdUnavailable;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(p)));
    const abs_path: []const u8 = if (std.fs.path.isAbsolute(file_path))
        file_path
    else
        std.fs.path.join(allocator, &.{ cwd, file_path }) catch file_path;

    // Faithful to Run.boot: JSC (WTF + Options + heap size-class tables) must be
    // initialized exactly once before any VM is created. Skipping this makes
    // JSC::VM::tryCreate crash in MarkedSpace::sizeClasses().
    home_rt.jsc.initialize(false);

    // Faithful to Run.boot: the AST node stores must exist before the module
    // loader transpiles anything (the parser allocates Expr/Stmt data from them).
    home_rt.ast.Expr.Data.Store.create();
    home_rt.ast.Stmt.Data.Store.create();

    // The VM owns its memory through a Mimalloc arena (Run.boot: `Arena.init()`).
    // This frame never returns before globalExit, so a local arena stays valid.
    var arena = home_rt.MimallocArena.init();

    const log = try allocator.create(home_rt.logger.Log);
    log.* = home_rt.logger.Log.init(allocator);
    var args = std.mem.zeroes(home_rt.schema.api.TransformOptions);
    args.disable_hmr = true;
    args.target = home_rt.schema.api.Target.bun;
    args.absolute_working_dir = home_rt.dupeZ(allocator, u8, cwd) catch null;

    // Build the preload list and WRITE any temp preload file to disk BEFORE the
    // VM (and its resolver) is initialized. `bun -e`/`--eval` exposes the node
    // builtin modules as globals (Node-REPL style) via a PRELOAD module — it
    // runs in the entry's realm before the entry, so user error line/column
    // numbers are unaffected; file runs do NOT inject these. The temp MUST be on
    // disk before init: VM init enumerates and caches the cwd's directory
    // listing, and if the node-globals temp is written afterward while the cwd
    // is itself the temp's directory (e.g. `home -e` run from /tmp, which is
    // /private/tmp), the freshly-written file is absent from that cached listing
    // and the resolver reports "Cannot find module". The `vm.preload` assignment
    // (which needs `vm`) stays after init.
    var preload_list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (inject_node_globals) {
        const boot =
            \\const N=["assert","async_hooks","buffer","child_process","cluster","console","constants","crypto","dgram","diagnostics_channel","dns","domain","events","fs","http","http2","https","inspector","net","os","path","perf_hooks","process","punycode","querystring","readline","stream","string_decoder","sys","timers","tls","trace_events","tty","url","util","v8","vm","wasi","worker_threads","zlib"];
            \\for(const n of N){try{if(typeof globalThis[n]==="undefined")globalThis[n]=require("node:"+n);}catch{}}
        ;
        var pre_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pre_path = std.fmt.bufPrint(&pre_buf, "/tmp/home-eval-globals-{d}.js", .{std.c.getpid()}) catch
            return error.NameTooLong;
        try Io.Dir.cwd().writeFile(g_io, .{ .sub_path = pre_path, .data = boot });
        try preload_list.append(allocator, try allocator.dupe(u8, pre_path));
    }
    // User `--require`/`-r`/`--preload` modules (run before the entry).
    for (g_user_preloads) |user_preload| try preload_list.append(allocator, user_preload);

    // Engine code (e.g. ConsoleObject) reads the process-global Command.Context
    // via `Command.get()`. We boot the VM directly (not through Command.start),
    // so initialize that context with defaults first or those reads dereference
    // undefined memory.
    _ = home_rt.cli.Command.initDefaultContext(allocator, log);

    const vm = try home_rt.jsc.VirtualMachine.init(.{
        .allocator = arena.allocator(),
        .args = args,
        .log = log,
        .is_main_thread = true,
    });

    var b = &vm.transpiler;
    vm.arena = &arena;
    vm.allocator = arena.allocator();

    // `process.argv` is built as [execPath, scriptPath, ...vm.argv]; vm.argv holds
    // the user's script arguments. Without this, `home file.js a b c` (and the
    // Bun.spawn(cmd:[bunExe(),script,arg]) shape Bun's tests use) would see an
    // argv missing every trailing arg — e.g. `process.argv.at(-1)` returns the
    // script path, so `Bun.sleep(parseFloat(arg))` becomes `sleep(NaN)`. Copy
    // the [:0]const u8 args into the []const u8 slice vm.argv expects.
    if (extra_args.len > 0) {
        const argv_slice = try allocator.alloc([]const u8, extra_args.len);
        for (extra_args, argv_slice) |src, *dst| dst.* = src;
        vm.argv = argv_slice;
    }

    // Preloads were built and written to disk above (before VM init).
    // loadEntryPoint runs them when `vm.preload` is non-empty.
    if (preload_list.items.len > 0) vm.preload = try preload_list.toOwnedSlice(allocator);

    // Resolver/transpiler config mirrored from Run.boot (defaults for the install
    // knobs since there's no CLI context here).
    b.resolver.env_loader = b.env;
    b.options.env.behavior = .load_all_without_inlining;

    // Custom `--conditions=<name>` from the command line: append to the ESM
    // condition set so package.json "exports"/"imports" match them (mirrors
    // build_command appending "development"/"react-server").
    if (g_user_conditions.len > 0) {
        // The resolver carries its OWN copy of the options (b.resolver.opts is not
        // b.options), so the condition maps must be appended on the resolver's
        // copy — that's the set consulted during exports/imports matching.
        b.resolver.opts.conditions.appendSlice(g_user_conditions) catch {};
        b.options.conditions.appendSlice(g_user_conditions) catch {};
    }

    b.configureDefines() catch return error.ConfigureDefinesFailed;

    home_rt.http.AsyncHTTP.loadEnv(vm.allocator, vm.log, b.env);
    vm.loadExtraEnvAndSourceCodePrinter();
    vm.is_main_thread = true;
    home_rt.jsc.VirtualMachine.is_main_thread_vm = true;

    if (vm.transpiler.env.get("TZ")) |tz| {
        if (tz.len > 0) _ = vm.global.setTimeZone(&home_rt.jsc.ZigString.init(tz));
    }

    vm.main_is_html_entrypoint = false;

    // Hand control to JSC under the API lock; start() loads + runs the entry.
    VmRunState.instance = .{ .vm = vm, .entry_path = abs_path };
    const callback = home_rt.jsc.OpaqueWrap(VmRunState, VmRunState.start);
    vm.global.vm().holdAPILock(&VmRunState.instance, callback);
}

/// Run `home test` natively through Home's `TestCommand.exec` — the bun:test
/// runner (sets up the Jest runner + VM, scans for test files, runs + reports).
/// `args` are the raw `home test` args; non-flag entries become test
/// files/filters (positionals[1..]). Flag parsing is not wired yet, so test
/// flags are currently ignored. globalExit inside exec makes this noreturn on
/// success. Gated behind HOME_NATIVE_VM=1.
/// Minimal bunfig.toml `preload` extractor for the native test runner. Reads
/// the `preload = "<path>"` / `preload = ["a", "b"]` assignment(s) (top-level
/// and any `[test]` section) and returns the paths. Intentionally NOT a full
/// TOML/bunfig parse — Bunfig.parse pulls in unported install/process code.
fn readBunfigPreloads(allocator: std.mem.Allocator) []const []const u8 {
    const content = Io.Dir.cwd().readFileAlloc(g_io, "bunfig.toml", allocator, std.Io.Limit.limited(1 << 20)) catch return &.{};
    defer allocator.free(content);
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        if (!std.mem.startsWith(u8, line, "preload")) continue;
        var rest = std.mem.trim(u8, line["preload".len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t");
        if (rest.len == 0) continue;
        // Collect every quoted string on the value side (covers both the single
        // string and the inline-array forms).
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const q = rest[i];
            if (q != '"' and q != '\'') continue;
            i += 1;
            const start = i;
            while (i < rest.len and rest[i] != q) i += 1;
            if (i > start) {
                const dup = allocator.dupe(u8, rest[start..i]) catch continue;
                list.append(allocator, dup) catch {};
            }
        }
    }
    return list.toOwnedSlice(allocator) catch &.{};
}

fn runTestsViaVM(allocator_unused: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (comptime !build_options.enable_jsc) return error.JscDisabled;
    _ = allocator_unused;
    // `home test` IS a test context, so allow `bun:internal-for-testing` (Bun's
    // `bun test` enables it for the same reason). In debug builds
    // `Environment.isDebug` already bypasses the gate, but release builds return
    // null without this — which broke the test harness's
    // `String.prototype.isUTF16/isLatin1` (→ toBeUTF16String etc., ENOENT on
    // `bun:internal-for-testing`) across many tests. Set the real ModuleLoader
    // flag directly (the env-var route isn't honored from `home test`).
    home_rt.allowInternalForTestingAPIs();
    // Bun stamps `bun.start_time` at process entry (its own main.zig); the test
    // runner's "Ran N tests across M files. [Xms]" summary measures elapsed from
    // it. The Home binary has a different entry point, so that var is still 0
    // here — printStartEnd would then report the whole monotonic clock (~days).
    // Stamp it now so the summary reports the actual test-run duration. Use the
    // exact same clock source the runner's summary reads for `end`
    // (getRoughTickCount(.force_real_time), a monotonic tick) — nanoTimestamp()
    // here is CLOCK.REALTIME (epoch) and would make end-start wildly negative.
    home_rt.start_time = home_rt.getRoughTickCount(.force_real_time).ns();
    // Bun's test runner runs on `default_allocator` (mimalloc). Home's main
    // uses a leak-checking DebugAllocator, but the JSC string machinery
    // (ZigString.Slice.intoOwnedSlice) has a fast no-copy path gated on the
    // allocator being `default_allocator`; with any other allocator it takes
    // the slow copy+deinit path, which double-frees JSC-borrowed bytes. Match
    // Bun and run the VM test runner on default_allocator.
    const allocator = home_rt.default_allocator;

    const log = try allocator.create(home_rt.logger.Log);
    log.* = home_rt.logger.Log.init(allocator);

    // Build the process-global Command.Context (TestCommand.exec reads ctx.args,
    // ctx.positionals, ctx.test_options). Defaults are sane; set the cwd so test
    // discovery resolves relative to it.
    const ctx = home_rt.cli.Command.initDefaultContext(allocator, log);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |p| {
        const cwd = std.mem.span(@as([*:0]u8, @ptrCast(p)));
        ctx.args.absolute_working_dir = blk: {
            const buf = allocator.allocSentinel(u8, cwd.len, 0) catch break :blk null;
            @memcpy(buf, cwd);
            break :blk buf;
        };
    }

    // Honor bunfig.toml's `preload` the way `bun test` does: the runner sets
    // `vm.preload = ctx.preloads` (test_command.zig), but booting the Context
    // directly skips bunfig parsing, so a bunfig that preloads a setup module
    // (e.g. Bun's test harness, which registers custom matchers like `toRun`)
    // had no effect on test files that don't import it. The full Bunfig parser
    // drags in unported install/process subsystems, so extract just the
    // `preload` value here.
    const cfg_preloads = readBunfigPreloads(allocator);
    if (cfg_preloads.len > 0) ctx.preloads = cfg_preloads;

    // positionals[0] is the command name; [1..] are file/dir paths or filters.
    // `--conditions=<name>` (and `--conditions <name>`) add custom package.json
    // "exports"/"imports" conditions; the test transpiler reads ctx.args.conditions.
    var positionals: std.ArrayListUnmanaged([]const u8) = .empty;
    try positionals.append(allocator, "test");
    var conditions: std.ArrayListUnmanaged([]const u8) = .empty;
    var ai: usize = 0;
    while (ai < args.len) : (ai += 1) {
        const a = args[ai];
        if (std.mem.eql(u8, a, "--conditions")) {
            if (ai + 1 < args.len) {
                var it = std.mem.splitScalar(u8, args[ai + 1], ',');
                while (it.next()) |part| {
                    const t = std.mem.trim(u8, part, " \t");
                    if (t.len > 0) try conditions.append(allocator, t);
                }
                ai += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--conditions=")) {
            var it = std.mem.splitScalar(u8, a["--conditions=".len..], ',');
            while (it.next()) |part| {
                const t = std.mem.trim(u8, part, " \t");
                if (t.len > 0) try conditions.append(allocator, t);
            }
            continue;
        }
        if (a.len > 0 and a[0] == '-') continue; // skip other flags (not parsed yet)
        try positionals.append(allocator, a);
    }
    ctx.positionals = try positionals.toOwnedSlice(allocator);
    if (conditions.items.len > 0) ctx.args.conditions = try conditions.toOwnedSlice(allocator);

    try home_rt.cli.TestCommand.exec(ctx);
}

/// Execute a JS/TS file through Home's OWN native JSC runtime (not bun
/// delegation). Returns `true` if it ran natively, `false` if the entry isn't
/// supported yet (ESM / un-lowerable) so the caller can delegate to bun. A
/// genuine runtime error in the script still exits non-zero.
fn runFileNative(allocator: std.mem.Allocator, file_path: []const u8, extra_args: []const [:0]const u8) !bool {
    if (comptime !build_options.enable_jsc) {
        return false;
    } else {
        // Capability pre-check: if the entry can't be transpiled to CommonJS
        // (e.g. it's ESM), bail to the caller so it delegates to bun rather
        // than failing. (.json never reaches here.)
        {
            const probe = Io.Dir.cwd().readFileAlloc(g_io, file_path, allocator, std.Io.Limit.unlimited) catch return false;
            defer allocator.free(probe);
            const out = home_rt.jsc.transpiler_bridge.transpileToCjs(allocator, probe, file_path) catch return false;
            allocator.free(out);
        }
        // Resolve the entry to an absolute path so the CommonJS loader treats
        // it as a path (not a bare specifier) and binds the module's require()
        // to its own directory (so the entry's relative require()s resolve).
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        var abs_owned = false;
        const abs_path: []const u8 = if (std.fs.path.isAbsolute(file_path))
            file_path
        else blk: {
            const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse {
                std.debug.print("{s}error:{s} cannot resolve cwd\n", .{ Color.Red.code(), Color.Reset.code() });
                std.process.exit(1);
            };
            const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
            const joined = std.fs.path.join(allocator, &.{ cwd, file_path }) catch break :blk file_path;
            abs_owned = true;
            break :blk joined;
        };
        defer if (abs_owned) allocator.free(abs_path);

        // process.argv = [exe, file, ...extra_args]
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(allocator);
        argv.append(allocator, "home") catch {};
        argv.append(allocator, abs_path) catch {};
        for (extra_args) |a| argv.append(allocator, a) catch {};

        var engine = home_rt.jsc.engine.Engine.init(allocator) catch |err| {
            std.debug.print("{s}error:{s} failed to start JavaScriptCore: {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
            std.process.exit(1);
        };
        defer engine.deinit();
        const ctx = engine.currentContext();
        const global = engine.currentGlobalObject();
        installRealmGlobals(allocator, ctx, global, argv.items);

        // Run the entry through the CommonJS loader (transpiles TS, binds a
        // dir-scoped require, caches). Quote the path for a JS string literal,
        // escaping backslash then double-quote.
        const esc_bs: ?[]u8 = std.mem.replaceOwned(u8, allocator, abs_path, "\\", "\\\\") catch null;
        defer if (esc_bs) |e| allocator.free(e);
        const base_q = esc_bs orelse abs_path;
        const esc_q: ?[]u8 = std.mem.replaceOwned(u8, allocator, base_q, "\"", "\\\"") catch null;
        defer if (esc_q) |e| allocator.free(e);
        const quoted = esc_q orelse base_q;
        const bootstrap = std.fmt.allocPrint(allocator, "require(\"{s}\");", .{quoted}) catch {
            std.process.exit(1);
        };
        defer allocator.free(bootstrap);

        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(allocator, ctx, bootstrap, abs_path, 1);
        defer evaluation.deinit(allocator);
        if (evaluation.exception != null) {
            const message = evaluation.exception_message orelse "uncaught exception";
            std.debug.print("{s}error:{s} {s}\n", .{ Color.Red.code(), Color.Reset.code(), message });
            std.process.exit(1);
        }
        home_rt.jsc.timers_global.drain(ctx);
        // If the script called Bun.serve(), stay alive and serve requests
        // (blocks until the process is killed); no-op otherwise.
        home_rt.jsc.serve_global.runLoop(allocator, ctx);
        home_rt.jsc.socket_global.runLoop(allocator, ctx);
        return true;
    }
}

/// `home eval <code> [--print|-p]` — execute a JavaScript source string
/// through Home's OWN JavaScriptCore runtime (`home_rt.jsc`), NOT by
/// delegating to the system `bun` binary like `home run` currently does.
/// This is the Phase-1 JS-callable bridge surface.
///
/// Faithful to `bun eval` / `bun -e`: the result is not auto-printed. Pass
/// `--print`/`-p` (mirroring `bun --print`) to render the last value. A thrown
/// exception is reported to stderr and produces a non-zero exit code.
fn evalCommand(allocator: std.mem.Allocator, code: []const u8, print_result: bool, extra_args: []const []const u8) !void {
    if (comptime !build_options.enable_jsc) {
        std.debug.print("{s}error:{s} 'eval' requires a JSC-enabled build (build with -Denable_jsc=true)\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    } else {
        var engine = home_rt.jsc.engine.Engine.init(allocator) catch |err| {
            std.debug.print("{s}error:{s} failed to start JavaScriptCore: {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
            std.process.exit(1);
        };
        defer engine.deinit();

        const ctx = engine.currentContext();
        const global = engine.currentGlobalObject();
        // process.argv = [exe, ...extra_args] (bun -e parity: no script path).
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(allocator);
        argv.append(allocator, "home") catch {};
        for (extra_args) |a| argv.append(allocator, a) catch {};
        installRealmGlobals(allocator, ctx, global, argv.items);

        // `bun -e` treats inline source as TypeScript by default — strip types
        // through the real Bun parser so `home -e "const x: number = 1"` runs.
        // Fall back to the raw source on a parse error (preserves prior plain-JS
        // behavior for anything the transform can't handle).
        var eval_code: []const u8 = code;
        var stripped_owned: ?[]u8 = null;
        defer if (stripped_owned) |s| allocator.free(s);
        if (home_rt.transpileTypeScriptForEval(allocator, code, .ts)) |stripped| {
            stripped_owned = stripped;
            eval_code = stripped;
        } else |_| {}

        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(allocator, ctx, eval_code, "home:eval", 1);
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null) {
            const message = evaluation.exception_message orelse "uncaught exception";
            std.debug.print("{s}error:{s} {s}\n", .{ Color.Red.code(), Color.Reset.code(), message });
            std.process.exit(1);
        }

        if (print_result) {
            if (evaluation.value) |value| {
                const text = home_rt.jsc.evaluate.valueToUtf8(allocator, ctx, value) catch return;
                defer allocator.free(text);
                const stdout_file = std.Io.File.stdout();
                try stdout_file.writeStreamingAll(g_io, text);
                try stdout_file.writeStreamingAll(g_io, "\n");
            }
        }

        // Pump timers/async (setTimeout etc.) until the loop is empty, like a
        // real runtime continues after the synchronous script returns.
        home_rt.jsc.timers_global.drain(ctx);
        // If the eval'd code called Bun.serve(), stay alive serving requests.
        home_rt.jsc.serve_global.runLoop(allocator, ctx);
        home_rt.jsc.socket_global.runLoop(allocator, ctx);
    }
}

fn runCommand(allocator: std.mem.Allocator, file_path: []const u8, extra_args: []const [:0]const u8) !void {
    // Route JS / TS files through the runtime delegation shim (Phase 12).
    if (fileExtIsJsLike(file_path)) {
        return runJsLikeFile(allocator, file_path, extra_args);
    }

    // Bun-style `home run <script>` for package.json scripts: if the
    // arg doesn't resolve to a local file but looks like a bare name,
    // try the JS runtime path so script lookup happens there.
    Io.Dir.cwd().access(g_io, file_path, .{}) catch |access_err| {
        if (access_err == error.FileNotFound and looksLikePackageScriptName(file_path)) {
            return runJsLikeFile(allocator, file_path, extra_args);
        }
        std.debug.print("{s}Error:{s} Failed to access '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, access_err });
        return access_err;
    };

    // Read the file
    const source = Io.Dir.cwd().readFileAlloc(g_io, file_path, allocator, std.Io.Limit.unlimited) catch |err| {
        std.debug.print("{s}Error:{s} Failed to read file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
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
    parser.source_text = source;
    parser.source_file = file_path;

    // Set source root for module resolution based on the file being compiled
    try parser.module_resolver.setSourceRoot(file_path);

    const program = try parser.parse();

    // Interpret
    const interpreter = try Interpreter.init(allocator, program);
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

fn runNativeBuildTool(argv: []const []const u8, tool_name: []const u8) !void {
    var child = std.process.spawn(g_io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("{s}Error:{s} failed to start {s}: {s}\n", .{
            Color.Red.code(),
            Color.Reset.code(),
            tool_name,
            @errorName(err),
        });
        return err;
    };

    const term = try child.wait(g_io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("{s}Error:{s} {s} exited with status {d}\n", .{
                    Color.Red.code(),
                    Color.Reset.code(),
                    tool_name,
                    code,
                });
                return error.NativeBuildToolFailed;
            }
        },
        else => {
            std.debug.print("{s}Error:{s} {s} terminated unexpectedly\n", .{
                Color.Red.code(),
                Color.Reset.code(),
                tool_name,
            });
            return error.NativeBuildToolFailed;
        },
    }
}

fn buildJsLikeCommand(allocator: std.mem.Allocator, file_path: []const u8, output_path: ?[]const u8) !void {
    if (!build_options.enable_jsc) {
        std.debug.print(
            "{s}Error:{s} JS/TS binaries require a Home compiler built with JavaScriptCore (-Denable_jsc=true)\n",
            .{ Color.Red.code(), Color.Reset.code() },
        );
        return error.JavaScriptCoreDisabled;
    }

    if ((builtin.os.tag != .macos and builtin.os.tag != .linux) or
        (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64))
    {
        std.debug.print("{s}Error:{s} LLVM JS/TS binaries currently support macOS/Linux on arm64 or x86-64\n", .{
            Color.Red.code(),
            Color.Reset.code(),
        });
        return error.UnsupportedHost;
    }

    const source_path = try Io.Dir.cwd().realPathFileAlloc(g_io, file_path, allocator);
    defer allocator.free(source_path);

    var executable_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_path_len = try std.process.executablePath(g_io, &executable_path_buffer);
    const executable_path = executable_path_buffer[0..executable_path_len];

    var default_output: ?[]u8 = null;
    defer if (default_output) |path| allocator.free(path);
    const out_path = output_path orelse blk: {
        default_output = try JSEntrypointLLVM.defaultOutputPath(allocator, file_path);
        break :blk default_output.?;
    };

    if (std.fs.path.dirname(out_path)) |parent| {
        if (parent.len > 0) try Io.Dir.cwd().createDirPath(g_io, parent);
    }

    const build_dir = try std.fmt.allocPrint(allocator, ".home-cache/llvm-js-{x}", .{getMonotonicNs()});
    defer allocator.free(build_dir);
    Io.Dir.cwd().deleteTree(g_io, build_dir) catch {};
    try Io.Dir.cwd().createDirPath(g_io, build_dir);
    defer Io.Dir.cwd().deleteTree(g_io, build_dir) catch {};

    const ir_path = try std.fmt.allocPrint(allocator, "{s}/launcher.ll", .{build_dir});
    defer allocator.free(ir_path);
    const launcher_object_path = try std.fmt.allocPrint(allocator, "{s}/launcher.o", .{build_dir});
    defer allocator.free(launcher_object_path);
    const payload_assembly_path = try std.fmt.allocPrint(allocator, "{s}/payload.s", .{build_dir});
    defer allocator.free(payload_assembly_path);
    const payload_object_path = try std.fmt.allocPrint(allocator, "{s}/payload.o", .{build_dir});
    defer allocator.free(payload_object_path);

    const llvm_ir = try JSEntrypointLLVM.generateLauncherIR(allocator, file_path);
    defer allocator.free(llvm_ir);
    const payload_assembly = try JSEntrypointLLVM.generatePayloadAssembly(
        allocator,
        executable_path,
        source_path,
        builtin.os.tag,
    );
    defer allocator.free(payload_assembly);

    try Io.Dir.cwd().writeFile(g_io, .{ .sub_path = ir_path, .data = llvm_ir });
    try Io.Dir.cwd().writeFile(g_io, .{ .sub_path = payload_assembly_path, .data = payload_assembly });

    std.debug.print("{s}Building LLVM JS/TS executable:{s} {s}\n", .{
        Color.Blue.code(),
        Color.Reset.code(),
        file_path,
    });
    std.debug.print("{s}Generating LLVM launcher...{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });

    try runNativeBuildTool(
        &.{ "clang", "-O2", "-Wno-override-module", "-c", "-x", "ir", ir_path, "-o", launcher_object_path },
        "LLVM IR compiler",
    );
    try runNativeBuildTool(&.{ "clang", "-c", payload_assembly_path, "-o", payload_object_path }, "Clang assembler");

    std.debug.print("{s}Linking embedded Home runtime and entrypoint...{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
    runNativeBuildTool(&.{ "clang", launcher_object_path, payload_object_path, "-o", out_path }, "LLVM linker") catch |err| {
        Io.Dir.cwd().deleteFile(g_io, out_path) catch {};
        return err;
    };

    adhocCodesign(allocator, out_path) catch |err| {
        Io.Dir.cwd().deleteFile(g_io, out_path) catch {};
        std.debug.print("{s}Error:{s} failed to sign JS/TS executable: {s}\n", .{
            Color.Red.code(),
            Color.Reset.code(),
            @errorName(err),
        });
        return err;
    };

    std.debug.print("\n{s}Success:{s} Built LLVM executable {s}\n", .{
        Color.Green.code(),
        Color.Reset.code(),
        out_path,
    });
    std.debug.print("{s}Info:{s} Run with: ./{s}\n", .{ Color.Blue.code(), Color.Reset.code(), out_path });
}

fn buildCommand(allocator: std.mem.Allocator, file_path: []const u8, output_path: ?[]const u8, kernel_mode: bool) !void {
    if (JSEntrypointLLVM.isSupportedEntrypoint(file_path)) {
        if (kernel_mode) {
            std.debug.print("{s}Error:{s} --kernel is only supported for Home source files\n", .{
                Color.Red.code(),
                Color.Reset.code(),
            });
            return error.UnsupportedKernelEntrypoint;
        }
        return buildJsLikeCommand(allocator, file_path, output_path);
    }

    // Read the file
    const source = Io.Dir.cwd().readFileAlloc(g_io, file_path, allocator, std.Io.Limit.unlimited) catch |err| {
        std.debug.print("{s}Error:{s} Failed to read file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer allocator.free(source);

    if (kernel_mode) {
        std.debug.print("{s}Building kernel:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    } else {
        std.debug.print("{s}Building:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    }

    // Initialize incremental compilation cache (skip for kernel mode)
    var inc_compiler: ?IncrementalCompiler = null;
    var cache: ?IRCache = null;

    if (build_options.enable_ir_cache and !kernel_mode) {
        // Use new incremental compiler
        inc_compiler = try IncrementalCompiler.init(allocator, ".home-cache", true, g_io);
        std.debug.print("{s}Incremental compilation:{s} enabled\n", .{ Color.Cyan.code(), Color.Reset.code() });

        // Check if module needs recompilation
        const can_use_cached = try inc_compiler.?.canUseCached(file_path, source);
        if (can_use_cached) {
            std.debug.print("{s}Cache Hit:{s} Module is up-to-date, skipping compilation\n", .{ Color.Green.code(), Color.Reset.code() });

            // Get cached object
            if (try inc_compiler.?.getCachedObject(file_path)) |_| {
                std.debug.print("{s}Using cached object{s}\n", .{
                    Color.Cyan.code(),
                    Color.Reset.code(),
                });
            }
        } else {
            std.debug.print("{s}Cache Miss:{s} Recompiling module\n", .{ Color.Yellow.code(), Color.Reset.code() });
        }

        // Also init old cache for backward compatibility
        cache = try IRCache.init(allocator, ".home-cache", g_io);
    }

    defer {
        if (inc_compiler) |*ic| ic.deinit();
        if (cache) |*c| c.deinit();
    }

    // Use arena allocator for AST
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();

    // Parse
    var parser = try Parser.init(arena_allocator, tokens.items);
    parser.source_text = source;
    parser.source_file = file_path;

    // Set source root for module resolution based on the file being compiled
    try parser.module_resolver.setSourceRoot(file_path);

    const program = try parser.parse();

    // Check for parse errors - if there were errors, the AST may contain invalid data
    if (parser.errors.items.len > 0) {
        std.debug.print("{s}Parse Errors:{s} Found {d} error(s) - code generation may fail\n", .{
            Color.Yellow.code(),
            Color.Reset.code(),
            parser.errors.items.len,
        });
    }

    // Create comptime value store for compile-time evaluation
    var comptime_store = ComptimeValueStore.init(allocator);
    defer comptime_store.deinit();

    // Initialize enhanced diagnostics reporter
    var enhanced_reporter = EnhancedReporter.init(allocator, .{
        .use_color = true,
        .show_suggestions = true,
        .show_context = true,
        .context_lines = 2,
    });
    defer enhanced_reporter.deinit();

    // Register source file for better error reporting
    try enhanced_reporter.registerSource(file_path, source);

    // Compile-time evaluation pass (unless disabled or kernel mode)
    if (!kernel_mode) {
        std.debug.print("{s}Evaluating comptime blocks...{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });

        var comptime_executor = try ComptimeExecutor.init(allocator);
        defer comptime_executor.deinit();

        // Note: Comptime evaluation happens during type checking for now
        // The ComptimeExecutor is prepared and will be used by the type checker
        // to evaluate comptime blocks and expressions as needed

        std.debug.print("{s}Comptime executor initialized ✓{s}\n", .{ Color.Green.code(), Color.Reset.code() });
    }

    // Type check (unless disabled or kernel mode)
    if (!kernel_mode) {
        std.debug.print("{s}Type checking...{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });

        var type_checker = TypeChecker.initWithComptime(allocator, program, &comptime_store);
        defer type_checker.deinit();

        const type_check_passed = try type_checker.check();

        if (!type_check_passed) {
            // Type errors are warnings for now - multi-module type checking is not complete
            std.debug.print("{s}Type Warnings (continuing):{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
            const max_errors_to_show: usize = 5;
            for (type_checker.errors.items[0..@min(max_errors_to_show, type_checker.errors.items.len)]) |err_info| {
                std.debug.print("  {s}Warning:{s} {s} (line {d}, col {d})\n", .{
                    Color.Yellow.code(),
                    Color.Reset.code(),
                    err_info.message,
                    err_info.loc.line,
                    err_info.loc.column,
                });
            }
            if (type_checker.errors.items.len > max_errors_to_show) {
                std.debug.print("  ... and {d} more warnings\n", .{type_checker.errors.items.len - max_errors_to_show});
            }
        } else {
            std.debug.print("{s}Type check passed ✓{s}\n", .{ Color.Green.code(), Color.Reset.code() });
        }

        // Borrow checking pass
        std.debug.print("{s}Borrow checking...{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });

        var borrow_checker = BorrowCheckPass.init(allocator, &enhanced_reporter);
        defer borrow_checker.deinit();
        const borrow_check_passed = try borrow_checker.check(program);

        if (borrow_check_passed) {
            std.debug.print("{s}Borrow check passed ✓{s}\n", .{ Color.Green.code(), Color.Reset.code() });
        } else {
            std.debug.print("{s}Borrow check failed!{s}\n", .{ Color.Red.code(), Color.Reset.code() });
            std.process.exit(1);
        }

        // Optimization pass
        std.debug.print("{s}Running optimizations...{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });

        var pass_manager = PassManager.init(allocator, .O2); // Use O2 optimization level
        defer pass_manager.deinit();

        try pass_manager.configureForLevel();
        try pass_manager.runOnProgram(program);

        std.debug.print("{s}Optimization complete ✓{s}\n", .{ Color.Green.code(), Color.Reset.code() });
        // Optionally print optimization statistics
        // pass_manager.printStats();
    }

    if (kernel_mode) {
        // Kernel mode: generate assembly
        var out_path_owned: ?[]const u8 = null;
        defer if (out_path_owned) |p| allocator.free(p);

        const out_path = if (output_path) |p|
            p
        else if (std.mem.endsWith(u8, file_path, ".home")) blk: {
            out_path_owned = try std.fmt.allocPrint(allocator, "{s}.s", .{file_path[0 .. file_path.len - 5]});
            break :blk out_path_owned.?;
        } else "kernel.s";

        std.debug.print("{s}Generating kernel assembly...{s}\n", .{ Color.Green.code(), Color.Reset.code() });

        var codegen = HomeKernelCodegen.init(
            allocator,
            &parser.symbol_table,
            &parser.module_resolver,
        );
        defer codegen.deinit();

        const asm_code = try codegen.generate(program);

        // Write assembly to file
        try Io.Dir.cwd().writeFile(g_io, .{
            .sub_path = out_path,
            .data = asm_code,
        });

        std.debug.print("\n{s}Success:{s} Generated kernel assembly: {s}\n", .{ Color.Green.code(), Color.Reset.code(), out_path });
        std.debug.print("{s}Info:{s} Assemble with: as -o {s}.o {s}\n", .{ Color.Blue.code(), Color.Reset.code(), out_path[0 .. out_path.len - 2], out_path });
    } else {
        // Normal mode: generate executable
        const out_path = output_path orelse blk: {
            if (std.mem.endsWith(u8, file_path, ".home")) {
                break :blk file_path[0 .. file_path.len - 5];
            } else if (std.mem.endsWith(u8, file_path, ".hm")) {
                break :blk file_path[0 .. file_path.len - 3];
            }
            // Warn if the input file doesn't have a recognized extension.
            if (!std.mem.endsWith(u8, file_path, ".home") and
                !std.mem.endsWith(u8, file_path, ".hm"))
            {
                std.debug.print("{s}Warning:{s} input file '{s}' does not have a .home or .hm extension\n", .{
                    Color.Yellow.code(), Color.Reset.code(), file_path,
                });
            }
            break :blk "a.out";
        };

        // Pick backend by host arch. The aarch64 path implements Path B-lite
        // of issue #5 (M1–M9 — return literals through match expressions).
        // Fall through to the x64 backend for any other host (the existing
        // behaviour, which on Apple Silicon produces an x86_64 binary that
        // runs under Rosetta 2).
        if (builtin.target.cpu.arch == .aarch64 and
            (builtin.os.tag == .macos or builtin.os.tag == .linux))
        {
            std.debug.print("{s}Generating native arm64 code...{s}\n", .{ Color.Green.code(), Color.Reset.code() });

            var codegen = Aarch64NativeCodegen.init(allocator, program);
            defer codegen.deinit();
            codegen.io = g_io;

            codegen.writeExecutable(out_path) catch |err| {
                if (codegen.io) |cio| {
                    Io.Dir.cwd().deleteFile(cio, out_path) catch {};
                }
                return err;
            };

            // Apple Silicon refuses to execute unsigned arm64 binaries.
            // An ad-hoc signature (`codesign --sign - <path>`) is enough
            // to satisfy the kernel without requiring a developer cert.
            adhocCodesign(allocator, out_path) catch |err| {
                std.debug.print("{s}Warning:{s} codesign failed ({}); binary may not run\n", .{ Color.Yellow.code(), Color.Reset.code(), err });
            };

            std.debug.print("\n{s}Success:{s} Built native executable {s}\n", .{ Color.Green.code(), Color.Reset.code(), out_path });
            std.debug.print("{s}Info:{s} Run with: ./{s}\n", .{ Color.Blue.code(), Color.Reset.code(), out_path });

            // Skip the x64 path below (incremental cache is x64-only for now).
            return;
        }

        std.debug.print("{s}Generating native x86-64 code...{s}\n", .{ Color.Green.code(), Color.Reset.code() });

        // Create global type registry for cross-module type resolution
        var type_registry = TypeRegistry.init(allocator);
        defer type_registry.deinit();

        var codegen = NativeCodegen.init(allocator, program, &comptime_store, &type_registry);
        defer codegen.deinit();

        // Propagate I/O so the back end's MachOWriter / ElfWriter can open
        // the output file. Without this they default to no-io and return
        // FileSystemAccessDenied.
        codegen.io = g_io;

        // Module prefix wiring for mangleMethodName is not enabled here yet:
        // call sites and emission sites already route through the helper,
        // but enabling the prefix breaks the ImplDecl emission path because
        // the MachO/ELF writer resolves the generated methods to position 0
        // when the key length changes. Leaving `module_prefix` null keeps
        // the historical bare `Type$method` form so nothing regresses; the
        // helper is ready to be flipped on once the writer issue is traced.
        codegen.module_prefix = null;

        // Set source root for import resolution
        try codegen.setSourceRoot(file_path);

        codegen.writeExecutable(out_path) catch |err| {
            // Remove partial binary so a failed build doesn't leave a
            // corrupt executable on disk that could be accidentally run.
            if (codegen.io) |cio| {
                Io.Dir.cwd().deleteFile(cio, out_path) catch {};
            }
            return err;
        };

        std.debug.print("\n{s}Success:{s} Built native executable {s}\n", .{ Color.Green.code(), Color.Reset.code(), out_path });
        std.debug.print("{s}Info:{s} Run with: ./{s}\n", .{ Color.Blue.code(), Color.Reset.code(), out_path });

        // Register module with incremental compiler for future builds
        if (inc_compiler) |*ic| {
            ic.storeCompilation(
                file_path,
                source,
                &.{}, // AST data — not serialised in the current pipeline
                &.{}, // type info — not serialised in the current pipeline
                &.{}, // object data — binary is written directly to disk
                &.{}, // no tracked dependencies yet
            ) catch |cache_err| {
                std.debug.print("{s}Warning:{s} Failed to update incremental cache: {}\n", .{ Color.Yellow.code(), Color.Reset.code(), cache_err });
            };
            std.debug.print("{s}Cache updated:{s} Module registered for incremental compilation\n", .{ Color.Cyan.code(), Color.Reset.code() });
        }
    }
}

fn profileCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Read the file
    const source = Io.Dir.cwd().readFileAlloc(g_io, file_path, allocator, std.Io.Limit.unlimited) catch |err| {
        std.debug.print("{s}Error:{s} Failed to read file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
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
    const start_lex = getMonotonicNs();
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = try lexer.tokenize();
    const end_lex = getMonotonicNs();
    const lex_time = (end_lex - start_lex) / std.time.ns_per_ms;

    try prof.trackAllocation(tokens.items.len * @sizeOf(Token));

    // Parse
    const start_parse = getMonotonicNs();
    var parser = try Parser.init(arena_allocator, tokens.items);
    parser.source_text = source;
    parser.source_file = file_path;

    // Set source root for module resolution based on the file being compiled
    try parser.module_resolver.setSourceRoot(file_path);

    const program = try parser.parse();
    const end_parse = getMonotonicNs();
    const parse_time = (end_parse - start_parse) / std.time.ns_per_ms;

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
    const hotspot_rule: [60]u8 = @splat('-');
    std.debug.print("{s}\n", .{&hotspot_rule});
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

fn printTestUsage() void {
    std.debug.print(
        \\{s}Home Test Runner{s}
        \\
        \\{s}Usage:{s}
        \\  home test [options] [path]
        \\  home t [options] [path]         (shorthand)
        \\
        \\{s}Options:{s}
        \\  -v, --verbose           Show detailed test output
        \\  -b, --bail              Stop on first test failure
        \\  --timeout <ms>          Set test timeout in milliseconds (default: 5000)
        \\  -p, --package <name>    Run tests only for a specific package
        \\  --zig                   Run only Zig unit tests
        \\  --home                  Run only Home integration tests
        \\  --bun-corpus-native-subset <name>
        \\                          Run an explicit native Bun-corpus bootstrap subset
        \\  -h, --help              Show this help message
        \\
        \\{s}Examples:{s}
        \\  home test                       Run all tests (monorepo-aware)
        \\  home test tests/                Run tests in specific directory
        \\  home test src/math.test.home    Run specific test file
        \\  home test -p lexer              Run tests for lexer package only
        \\  home test --zig                 Run only Zig unit tests
        \\  home test --home -v             Run Home tests with verbose output
        \\  home test --bail                Stop on first failure
        \\
        \\{s}Monorepo Support:{s}
        \\  Automatically discovers tests in:
        \\    - tests/                       Integration tests (*.test.home)
        \\    - packages/*/tests/            Package unit tests
        \\    - src/                         Inline tests
        \\
        \\{s}Test File Patterns:{s}
        \\  *.test.home                     Home integration test files
        \\  *.test.hm                       Home test files (short ext)
        \\  *_test.zig                      Zig unit test files
        \\
        \\{s}Bun Corpus Bootstrap:{s}
        \\  home test packages/runtime/test/bun-corpus
        \\                                  Run the full native corpus gate; fails until 100% native parity
        \\  home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=minimal-js
        \\                                  Run the current allowlisted native JSC smoke subset
        \\
    , .{
        Color.Blue.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
        Color.Green.code(),
        Color.Reset.code(),
    });
}

/// Watch command for hot reloading
fn watchCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    std.debug.print("{s}Watching:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    std.debug.print("{s}Press Ctrl+C to stop{s}\n\n", .{ Color.Yellow.code(), Color.Reset.code() });

    // Initial run
    std.debug.print("{s}[Initial Run]{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
    runAndReportError(allocator, file_path);

    // Get initial modification time
    var last_mtime: std.Io.Timestamp = blk: {
        const stat = Io.Dir.cwd().statFile(g_io, file_path, .{}) catch |err| {
            std.debug.print("{s}Error:{s} Cannot watch file: {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
            return err;
        };
        break :blk stat.mtime;
    };

    // Polling loop
    var iteration: u32 = 0;
    while (true) {
        // Sleep for 500ms
        if (comptime native_os == .windows) {
            // 500ms in 100-nanosecond intervals, negative for relative time
            var delay: i64 = -5_000_000;
            _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &delay);
        } else if (comptime native_os == .linux) {
            const linux = std.os.linux;
            _ = linux.nanosleep(&.{ .sec = 0, .nsec = 500_000_000 }, null);
        } else {
            _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 500_000_000 }, null);
        }

        const stat = Io.Dir.cwd().statFile(g_io, file_path, .{}) catch continue;

        // Compare timestamps
        const mtime_changed = stat.mtime.nanoseconds != last_mtime.nanoseconds;
        if (mtime_changed) {
            last_mtime = stat.mtime;
            iteration += 1;

            std.debug.print("\n{s}[Hot Reload #{d}]{s} File changed, recompiling...\n", .{
                Color.Magenta.code(),
                iteration,
                Color.Reset.code(),
            });

            runAndReportError(allocator, file_path);
        }
    }
}

fn runAndReportError(allocator: std.mem.Allocator, file_path: []const u8) void {
    // Read the file
    const source = Io.Dir.cwd().readFileAlloc(g_io, file_path, allocator, std.Io.Limit.unlimited) catch |err| {
        std.debug.print("{s}Error:{s} Failed to read file: {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
        return;
    };
    defer allocator.free(source);

    // Use arena allocator for AST
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = lexer.tokenize() catch |err| {
        std.debug.print("{s}Lexer Error:{s} {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
        return;
    };

    // Parse
    var parser = Parser.init(arena_allocator, tokens.items) catch |err| {
        std.debug.print("{s}Parser Error:{s} {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
        return;
    };
    parser.source_text = source;
    parser.source_file = file_path;
    const program = parser.parse() catch |err| {
        std.debug.print("{s}Parse Error:{s} {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
        return;
    };

    // Interpret
    const interpreter = Interpreter.init(allocator, program) catch |err| {
        std.debug.print("{s}Interpreter init error:{s} {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
        return;
    };
    defer interpreter.deinit();

    interpreter.interpret() catch |err| {
        if (err == error.Return) {
            std.debug.print("{s}OK{s}\n", .{ Color.Green.code(), Color.Reset.code() });
            return;
        }
        std.debug.print("{s}Runtime Error:{s} {}\n", .{ Color.Red.code(), Color.Reset.code(), err });
        return;
    };

    std.debug.print("{s}OK{s}\n", .{ Color.Green.code(), Color.Reset.code() });
}

fn testDiscoverCommand(allocator: std.mem.Allocator, search_path: []const u8) !void {
    std.debug.print("{s}Discovering tests in:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), search_path });

    // Walk the directory and find test files
    var test_files = std.ArrayList([]const u8).empty;
    defer {
        for (test_files.items) |file| {
            allocator.free(file);
        }
        test_files.deinit(allocator);
    }

    try discoverTestFiles(allocator, search_path, &test_files);

    if (test_files.items.len == 0) {
        std.debug.print("{s}No test files found matching patterns:{s} *.test.home, *.test.hm\n", .{
            Color.Yellow.code(),
            Color.Reset.code(),
        });
        return;
    }

    std.debug.print("{s}Found {d} test file(s):{s}\n\n", .{
        Color.Green.code(),
        test_files.items.len,
        Color.Reset.code(),
    });

    for (test_files.items, 0..) |file, i| {
        std.debug.print("  {d}. {s}{s}{s}\n", .{
            i + 1,
            Color.Cyan.code(),
            file,
            Color.Reset.code(),
        });
    }
    std.debug.print("\n", .{});
}

fn discoverTestFiles(allocator: std.mem.Allocator, dir_path: []const u8, test_files: *std.ArrayList([]const u8)) !void {
    var dir = Io.Dir.cwd().openDir(g_io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("{s}Error:{s} Directory not found: {s}\n", .{
                Color.Red.code(),
                Color.Reset.code(),
                dir_path,
            });
        }
        return err;
    };
    defer dir.close(g_io);

    var iter = dir.iterate();

    while (try iter.next(g_io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (isTestFile(entry.name)) {
                    const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                    try test_files.append(allocator, full_path);
                }
            },
            .directory => {
                // Skip common non-test directories
                if (shouldSkipDirectory(entry.name)) {
                    continue;
                }

                const subdir_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(subdir_path);

                try discoverTestFiles(allocator, subdir_path, test_files);
            },
            else => {},
        }
    }
}

/// Discovers all test locations in a monorepo structure
/// Returns paths to: tests/, packages/*/tests/, and any .test.home files
fn discoverMonorepoTests(allocator: std.mem.Allocator, test_files: *std.ArrayList([]const u8), zig_test_dirs: *std.ArrayList([]const u8)) !void {
    // 1. Check for tests/ directory (Home integration tests)
    if (Io.Dir.cwd().statFile(g_io, "tests", .{})) |stat| {
        if (stat.kind == .directory) {
            discoverTestFiles(allocator, "tests", test_files) catch {};
        }
    } else |_| {}

    // 2. Check for packages/ directory (monorepo packages)
    var packages_dir = Io.Dir.cwd().openDir(g_io, "packages", .{ .iterate = true }) catch {
        return; // No packages directory
    };
    defer packages_dir.close(g_io);

    var pkg_iter = packages_dir.iterate();
    while (try pkg_iter.next(g_io)) |pkg_entry| {
        if (pkg_entry.kind == .directory) {
            // Check for tests/ subdirectory in each package
            const pkg_tests_path = try std.fs.path.join(allocator, &.{ "packages", pkg_entry.name, "tests" });

            if (Io.Dir.cwd().statFile(g_io, pkg_tests_path, .{})) |stat| {
                if (stat.kind == .directory) {
                    // Check if it has Zig tests or Home tests
                    var tests_dir = Io.Dir.cwd().openDir(g_io, pkg_tests_path, .{ .iterate = true }) catch continue;
                    defer tests_dir.close(g_io);

                    var has_zig_tests = false;
                    var has_home_tests = false;

                    var test_iter = tests_dir.iterate();
                    while (try test_iter.next(g_io)) |test_entry| {
                        if (test_entry.kind == .file) {
                            if (std.mem.endsWith(u8, test_entry.name, "_test.zig") or
                                std.mem.endsWith(u8, test_entry.name, "_tests.zig"))
                            {
                                has_zig_tests = true;
                            }
                            if (isTestFile(test_entry.name)) {
                                has_home_tests = true;
                            }
                        }
                    }

                    if (has_zig_tests) {
                        const path_copy = try allocator.dupe(u8, pkg_tests_path);
                        try zig_test_dirs.append(allocator, path_copy);
                    }

                    if (has_home_tests) {
                        discoverTestFiles(allocator, pkg_tests_path, test_files) catch {};
                    }
                }
            } else |_| {}

            allocator.free(pkg_tests_path);
        }
    }

    // 3. Also check src/ directory for inline tests
    if (Io.Dir.cwd().statFile(g_io, "src", .{})) |stat| {
        if (stat.kind == .directory) {
            discoverTestFiles(allocator, "src", test_files) catch {};
        }
    } else |_| {}
}

fn isTestFile(filename: []const u8) bool {
    return std.mem.endsWith(u8, filename, ".test.home") or
        std.mem.endsWith(u8, filename, ".test.hm");
}

fn shouldSkipDirectory(dirname: []const u8) bool {
    const skip_dirs = [_][]const u8{
        "node_modules", ".git",  ".zig-cache", "zig-out", ".home",
        "target",       "build", "dist",       ".vscode", ".idea",
        "pending",
    };

    for (skip_dirs) |skip_dir| {
        if (std.mem.eql(u8, dirname, skip_dir)) {
            return true;
        }
    }
    return false;
}

/// Runs tests across the entire monorepo
fn runMonorepoTests(allocator: std.mem.Allocator, options: TestOptions) !void {
    const start_time = getMonotonicNs();

    std.debug.print("\n{s}Home Monorepo Test Suite{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
    std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });

    // Discover all tests
    var home_test_files = std.ArrayList([]const u8).empty;
    defer {
        for (home_test_files.items) |file| {
            allocator.free(file);
        }
        home_test_files.deinit(allocator);
    }

    var zig_test_dirs = std.ArrayList([]const u8).empty;
    defer {
        for (zig_test_dirs.items) |dir| {
            allocator.free(dir);
        }
        zig_test_dirs.deinit(allocator);
    }

    try discoverMonorepoTests(allocator, &home_test_files, &zig_test_dirs);

    // Filter by package if specified
    if (options.package) |pkg_name| {
        std.debug.print("{s}Filtering:{s} package '{s}'\n\n", .{
            Color.Cyan.code(),
            Color.Reset.code(),
            pkg_name,
        });

        // Filter home tests
        var filtered_home = std.ArrayList([]const u8).empty;
        for (home_test_files.items) |file| {
            if (std.mem.indexOf(u8, file, pkg_name) != null) {
                try filtered_home.append(allocator, file);
            } else {
                allocator.free(file);
            }
        }
        home_test_files.deinit(allocator);
        home_test_files = filtered_home;

        // Filter zig test dirs
        var filtered_zig = std.ArrayList([]const u8).empty;
        for (zig_test_dirs.items) |dir| {
            if (std.mem.indexOf(u8, dir, pkg_name) != null) {
                try filtered_zig.append(allocator, dir);
            } else {
                allocator.free(dir);
            }
        }
        zig_test_dirs.deinit(allocator);
        zig_test_dirs = filtered_zig;
    }

    // Track results
    var total_home_tests: usize = 0;
    var passed_home_files: usize = 0;
    var failed_home_files: usize = 0;
    var zig_packages_passed: usize = 0;
    var zig_packages_failed: usize = 0;

    // Run Home integration tests (unless --zig only)
    if (!options.zig_only and home_test_files.items.len > 0) {
        std.debug.print("{s}Home Integration Tests{s}\n", .{ Color.Magenta.code(), Color.Reset.code() });
        std.debug.print("Found {d} test file(s)\n\n", .{home_test_files.items.len});

        for (home_test_files.items) |file_path| {
            const result = runTestFile(allocator, file_path, options.verbose);
            if (result) |test_count| {
                passed_home_files += 1;
                total_home_tests += test_count;
            } else |_| {
                failed_home_files += 1;
                if (options.bail) {
                    std.debug.print("\n{s}Bailed!{s} Stopping after first failure\n", .{
                        Color.Yellow.code(),
                        Color.Reset.code(),
                    });
                    break;
                }
            }
        }
        std.debug.print("\n", .{});
    }

    // Run Zig unit tests (unless --home only)
    if (!options.home_only and zig_test_dirs.items.len > 0 and !options.bail) {
        std.debug.print("{s}Zig Unit Tests{s}\n", .{ Color.Magenta.code(), Color.Reset.code() });
        std.debug.print("Found {d} package(s) with tests\n\n", .{zig_test_dirs.items.len});

        for (zig_test_dirs.items) |test_dir| {
            const result = runZigTests(allocator, test_dir, options.verbose);
            if (result) {
                zig_packages_passed += 1;
            } else |_| {
                zig_packages_failed += 1;
                if (options.bail) {
                    std.debug.print("\n{s}Bailed!{s} Stopping after first failure\n", .{
                        Color.Yellow.code(),
                        Color.Reset.code(),
                    });
                    break;
                }
            }
        }
        std.debug.print("\n", .{});
    }

    // Print summary
    std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("{s}Test Summary{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    const total_failed = failed_home_files + zig_packages_failed;
    if (total_failed == 0) {
        std.debug.print("{s}✓ All tests passed!{s}\n\n", .{ Color.Green.code(), Color.Reset.code() });
    } else {
        std.debug.print("{s}✗ Some tests failed{s}\n\n", .{ Color.Red.code(), Color.Reset.code() });
    }

    if (!options.zig_only) {
        std.debug.print("  {s}Home Tests:{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
        std.debug.print("    Files:  {s}{d} passed{s}", .{ Color.Green.code(), passed_home_files, Color.Reset.code() });
        if (failed_home_files > 0) {
            std.debug.print(", {s}{d} failed{s}", .{ Color.Red.code(), failed_home_files, Color.Reset.code() });
        }
        std.debug.print("\n    Tests:  {d} total\n", .{total_home_tests});
    }

    if (!options.home_only and zig_test_dirs.items.len > 0) {
        std.debug.print("  {s}Zig Tests:{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
        std.debug.print("    Packages:  {s}{d} passed{s}", .{ Color.Green.code(), zig_packages_passed, Color.Reset.code() });
        if (zig_packages_failed > 0) {
            std.debug.print(", {s}{d} failed{s}", .{ Color.Red.code(), zig_packages_failed, Color.Reset.code() });
        }
        std.debug.print("\n", .{});
    }

    // Print elapsed time
    {
        const elapsed_ns = getMonotonicNs() - start_time;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        std.debug.print("\n  Time:   {d:.2}s\n", .{elapsed_s});
    }
    std.debug.print("\n", .{});

    if (total_failed > 0) {
        std.process.exit(1);
    }
}

/// Runs Zig unit tests for a package
fn runZigTests(allocator: std.mem.Allocator, test_dir: []const u8, verbose: bool) !void {
    const pantry_zig_rel = if (comptime native_os == .windows) "pantry/.bin/zig.exe" else "pantry/.bin/zig";
    const pantry_zig = Io.Dir.cwd().realPathFileAlloc(g_io, pantry_zig_rel, allocator) catch |err| {
        std.debug.print("Pantry Zig not found at ./{s}; run `pantry install` first ({})\n", .{
            pantry_zig_rel,
            err,
        });
        return err;
    };
    defer allocator.free(pantry_zig);

    // Extract package name from path (packages/<name>/tests)
    var path_parts = std.mem.splitScalar(u8, test_dir, '/');
    var pkg_name: []const u8 = "unknown";
    while (path_parts.next()) |part| {
        if (std.mem.eql(u8, part, "packages")) {
            if (path_parts.next()) |name| {
                pkg_name = name;
                break;
            }
        }
    }

    // Try to run zig build test for the package
    const build_file_path = try std.fs.path.join(allocator, &.{ "packages", pkg_name, "build.zig" });
    defer allocator.free(build_file_path);

    // Check if package has its own build.zig
    if (Io.Dir.cwd().statFile(g_io, build_file_path, .{})) |_| {
        // Run zig build test from package directory
        const pkg_dir = try std.fs.path.join(allocator, &.{ "packages", pkg_name });
        defer allocator.free(pkg_dir);

        var child = std.process.spawn(g_io, .{
            .argv = &.{ pantry_zig, "build", "test" },
            .cwd = .{ .path = pkg_dir },
            .stdout = if (!verbose) .ignore else .inherit,
            .stderr = if (!verbose) .ignore else .inherit,
        }) catch |err| {
            std.debug.print("{s}FAIL{s} {s} (spawn failed: {})\n", .{
                Color.Red.code(),
                Color.Reset.code(),
                pkg_name,
                err,
            });
            return err;
        };

        const term = child.wait(g_io) catch |err| {
            std.debug.print("{s}FAIL{s} {s} (zig build test failed: {})\n", .{
                Color.Red.code(),
                Color.Reset.code(),
                pkg_name,
                err,
            });
            return err;
        };

        if (term.exited == 0) {
            std.debug.print("{s}PASS{s} {s}\n", .{
                Color.Green.code(),
                Color.Reset.code(),
                pkg_name,
            });
        } else {
            std.debug.print("{s}FAIL{s} {s}\n", .{
                Color.Red.code(),
                Color.Reset.code(),
                pkg_name,
            });
            return error.TestFailed;
        }
    } else |_| {
        // No build.zig, try running zig test directly on test files
        var tests_dir = Io.Dir.cwd().openDir(g_io, test_dir, .{ .iterate = true }) catch {
            std.debug.print("{s}SKIP{s} {s} (no tests directory)\n", .{
                Color.Yellow.code(),
                Color.Reset.code(),
                pkg_name,
            });
            return;
        };
        defer tests_dir.close(g_io);

        var any_failed = false;
        var iter = tests_dir.iterate();
        while (try iter.next(g_io)) |entry| {
            if (entry.kind == .file and
                (std.mem.endsWith(u8, entry.name, "_test.zig") or
                    std.mem.endsWith(u8, entry.name, "_tests.zig")))
            {
                const test_file = try std.fs.path.join(allocator, &.{ test_dir, entry.name });
                defer allocator.free(test_file);

                var child = std.process.spawn(g_io, .{
                    .argv = &.{ pantry_zig, "test", test_file },
                    .stdout = if (!verbose) .ignore else .inherit,
                    .stderr = if (!verbose) .ignore else .inherit,
                }) catch {
                    any_failed = true;
                    continue;
                };

                const term = child.wait(g_io) catch {
                    any_failed = true;
                    continue;
                };

                if (term.exited != 0) {
                    any_failed = true;
                }
            }
        }

        if (any_failed) {
            std.debug.print("{s}FAIL{s} {s}\n", .{
                Color.Red.code(),
                Color.Reset.code(),
                pkg_name,
            });
            return error.TestFailed;
        } else {
            std.debug.print("{s}PASS{s} {s}\n", .{
                Color.Green.code(),
                Color.Reset.code(),
                pkg_name,
            });
        }
    }
}

fn runTestSuite(allocator: std.mem.Allocator, dir_path: []const u8, options: TestOptions) !void {
    const start_time = getMonotonicNs();

    std.debug.print("\n{s}Home Test Suite{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
    std.debug.print("{s}━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });

    // Discover test files
    var test_files = std.ArrayList([]const u8).empty;
    defer {
        for (test_files.items) |file| {
            allocator.free(file);
        }
        test_files.deinit(allocator);
    }

    discoverTestFiles(allocator, dir_path, &test_files) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("{s}Error:{s} Tests directory not found: {s}\n", .{
                Color.Red.code(),
                Color.Reset.code(),
                dir_path,
            });
            std.debug.print("Create a 'tests/' directory with .test.home files to run tests.\n", .{});
            return;
        }
        return err;
    };

    if (test_files.items.len == 0) {
        std.debug.print("{s}No test files found{s} in {s}\n", .{
            Color.Yellow.code(),
            Color.Reset.code(),
            dir_path,
        });
        std.debug.print("Test files should match: *.test.home or *.test.hm\n", .{});
        return;
    }

    std.debug.print("Found {s}{d}{s} test file(s)\n\n", .{
        Color.Cyan.code(),
        test_files.items.len,
        Color.Reset.code(),
    });

    var passed_files: usize = 0;
    var failed_files: usize = 0;
    var total_tests: usize = 0;
    var failed_file_list = std.ArrayList([]const u8).empty;
    defer failed_file_list.deinit(allocator);
    var bailed = false;

    for (test_files.items) |file_path| {
        // Run each test file
        const result = runTestFile(allocator, file_path, options.verbose);
        if (result) |test_count| {
            passed_files += 1;
            total_tests += test_count;
        } else |_| {
            failed_files += 1;
            try failed_file_list.append(allocator, file_path);

            // If bail mode is enabled, stop on first failure
            if (options.bail) {
                std.debug.print("\n{s}Bailed!{s} Stopping after first failure (--bail)\n", .{
                    Color.Yellow.code(),
                    Color.Reset.code(),
                });
                bailed = true;
                break;
            }
        }
    }

    // Print summary
    std.debug.print("\n{s}━━━━━━━━━━━━━━━━{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("{s}Test Summary{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    if (failed_files == 0) {
        std.debug.print("{s}✓ All tests passed!{s}\n", .{ Color.Green.code(), Color.Reset.code() });
    } else {
        std.debug.print("{s}✗ Some tests failed{s}\n", .{ Color.Red.code(), Color.Reset.code() });
    }

    std.debug.print("\n  Files:  {s}{d} passed{s}", .{ Color.Green.code(), passed_files, Color.Reset.code() });
    if (failed_files > 0) {
        std.debug.print(", {s}{d} failed{s}", .{ Color.Red.code(), failed_files, Color.Reset.code() });
    }
    if (bailed) {
        const skipped = test_files.items.len - passed_files - failed_files;
        std.debug.print(", {s}{d} skipped{s}", .{ Color.Yellow.code(), skipped, Color.Reset.code() });
    }
    std.debug.print(" ({d} total)\n", .{test_files.items.len});
    std.debug.print("  Tests:  {d} total\n", .{total_tests});

    // Print elapsed time
    {
        const elapsed_ns = getMonotonicNs() - start_time;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        std.debug.print("  Time:   {d:.2}s\n", .{elapsed_s});
    }
    std.debug.print("\n", .{});

    if (failed_file_list.items.len > 0) {
        std.debug.print("{s}Failed files:{s}\n", .{ Color.Red.code(), Color.Reset.code() });
        for (failed_file_list.items) |file| {
            std.debug.print("  - {s}\n", .{file});
        }
        std.debug.print("\n", .{});
        std.process.exit(1);
    }
}

fn runTestFile(allocator: std.mem.Allocator, file_path: []const u8, verbose: bool) !usize {
    // Read the file
    const source = Io.Dir.cwd().readFileAlloc(g_io, file_path, allocator, std.Io.Limit.unlimited) catch |err| {
        std.debug.print("{s}FAIL{s} {s}\n", .{ Color.Red.code(), Color.Reset.code(), file_path });
        std.debug.print("  Error: Failed to read file: {}\n", .{err});
        return err;
    };
    defer allocator.free(source);

    // Use arena allocator for AST
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Tokenize
    var lexer = Lexer.init(arena_allocator, source);
    const tokens = lexer.tokenize() catch |err| {
        std.debug.print("{s}FAIL{s} {s}\n", .{ Color.Red.code(), Color.Reset.code(), file_path });
        std.debug.print("  Error: Lexer error: {}\n", .{err});
        return err;
    };

    // Parse
    var parser = Parser.init(arena_allocator, tokens.items) catch |err| {
        std.debug.print("{s}FAIL{s} {s}\n", .{ Color.Red.code(), Color.Reset.code(), file_path });
        std.debug.print("  Error: Parser init error: {}\n", .{err});
        return err;
    };
    parser.source_text = source;
    parser.source_file = file_path;

    // Set source root for module resolution
    try parser.module_resolver.setSourceRoot(file_path);

    const program = parser.parse() catch |err| {
        std.debug.print("{s}FAIL{s} {s}\n", .{ Color.Red.code(), Color.Reset.code(), file_path });
        std.debug.print("  Error: Parse error: {}\n", .{err});
        return err;
    };

    // Check for parse errors
    if (parser.errors.items.len > 0) {
        std.debug.print("{s}FAIL{s} {s}\n", .{ Color.Red.code(), Color.Reset.code(), file_path });
        for (parser.errors.items) |err_item| {
            std.debug.print("  {s}:{d}:{d}: {s}\n", .{
                file_path,
                err_item.line,
                err_item.column,
                err_item.message,
            });
        }
        return error.ParseError;
    }

    // Count test statements (it blocks)
    var test_count: usize = 0;
    for (program.statements) |stmt| {
        switch (stmt) {
            .ItTestDecl => test_count += 1,
            else => {},
        }
    }

    // Interpret
    const interpreter = Interpreter.init(allocator, program) catch |err| {
        std.debug.print("{s}FAIL{s} {s}\n", .{ Color.Red.code(), Color.Reset.code(), file_path });
        std.debug.print("  Error: Interpreter init error: {}\n", .{err});
        return err;
    };
    defer interpreter.deinit();

    // Set verbose mode for test output
    interpreter.setVerboseTests(verbose);

    interpreter.interpret() catch |err| {
        if (err != error.Return) {
            std.debug.print("{s}FAIL{s} {s}\n", .{ Color.Red.code(), Color.Reset.code(), file_path });
            return err;
        }
    };

    std.debug.print("{s}PASS{s} {s} ({d} tests)\n", .{
        Color.Green.code(),
        Color.Reset.code(),
        file_path,
        test_count,
    });

    return test_count;
}

/// Test options struct
const TestOptions = struct {
    verbose: bool = false,
    bail: bool = false,
    timeout_ms: u32 = 5000,
    zig_only: bool = false,
    home_only: bool = false,
    package: ?[]const u8 = null,
};

fn isJsLikeTestProject(args: []const [:0]const u8) bool {
    // Heuristic: presence of `package.json` in the cwd routes `home test`
    // through the JS runtime so existing Bun test suites keep working.
    // Home-native projects without package.json keep the Zig-backed runner.
    if (Io.Dir.cwd().access(g_io, "package.json", .{})) |_| {
        return true;
    } else |_| {}
    // Also route when an explicit JS/TS test file is named, even without a
    // package.json — e.g. a spawned `home test foo.test.js` in a temp dir
    // (Bun's own test fixtures do exactly this). `.js`/`.ts` belong to the
    // bun:test runner, not the Home-language (`.home`/`.hm`) runner, which
    // would otherwise try to parse the JS as Home source (EP0001 errors).
    for (args) |a| {
        if (a.len == 0 or a[0] == '-') continue;
        if (isJsLikeCorpusFile(a)) return true;
    }
    return false;
}

const bun_corpus_marker = "packages/runtime/test/bun-corpus";
const bun_corpus_marker_child = "packages/runtime/test/bun-corpus/";
const bun_corpus_marker_embedded_child = "/packages/runtime/test/bun-corpus/";

const BunCorpusTarget = union(enum) {
    root: []const u8,
    file: struct {
        corpus_path: []const u8,
        relative_path: []const u8,
    },
};

fn isJsLikeCorpusFile(path: []const u8) bool {
    const exts = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs" };
    for (exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

fn resolveBunCorpusTarget(path: []const u8) ?BunCorpusTarget {
    const without_dot = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    var end = without_dot.len;
    while (end > 0 and without_dot[end - 1] == '/') end -= 1;
    const normalized = without_dot[0..end];
    if (normalized.len == 0) return null;

    const root_match = std.mem.eql(u8, normalized, bun_corpus_marker) or
        std.mem.endsWith(u8, normalized, "/" ++ bun_corpus_marker);
    if (root_match) return .{ .root = normalized };

    if (std.mem.startsWith(u8, normalized, bun_corpus_marker_child)) {
        const relative = normalized[bun_corpus_marker_child.len..];
        if (relative.len != 0 and isJsLikeCorpusFile(relative)) {
            return .{ .file = .{
                .corpus_path = bun_corpus_marker,
                .relative_path = relative,
            } };
        }
    }

    if (std.mem.indexOf(u8, normalized, bun_corpus_marker_embedded_child)) |index| {
        const marker_start = index + 1;
        const corpus_end = marker_start + bun_corpus_marker.len;
        const relative = normalized[corpus_end + 1 ..];
        if (relative.len != 0 and isJsLikeCorpusFile(relative)) {
            return .{ .file = .{
                .corpus_path = normalized[0..corpus_end],
                .relative_path = relative,
            } };
        }
    }

    return null;
}

fn isBunCorpusSubsetFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--bun-corpus-native-subset") or
        std.mem.eql(u8, arg, "--bun-corpus-subset");
}

fn argTargetsBunCorpus(args: []const [:0]const u8) ?BunCorpusTarget {
    var skip_next = false;
    for (args) |arg| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (isBunCorpusSubsetFlag(arg)) {
            skip_next = true;
            continue;
        }
        if (arg.len == 0 or arg[0] == '-') continue;
        if (resolveBunCorpusTarget(arg)) |target| return target;
    }
    return null;
}

const BunCorpusSubsetArg = union(enum) {
    none,
    ok: home_test.corpus_runner.Subset,
    missing_value: []const u8,
    unknown_value: []const u8,
};

fn argBunCorpusSubset(args: []const [:0]const u8) BunCorpusSubsetArg {
    for (args, 0..) |arg, i| {
        if (isBunCorpusSubsetFlag(arg)) {
            if (i + 1 >= args.len or args[i + 1].len == 0 or args[i + 1][0] == '-') {
                return .{ .missing_value = arg };
            }
            const value = args[i + 1];
            if (home_test.corpus_runner.parseSubsetFlagValue(value)) |subset| {
                return .{ .ok = subset };
            }
            return .{ .unknown_value = value };
        }
        const prefixes = [_][]const u8{
            "--bun-corpus-native-subset=",
            "--bun-corpus-subset=",
        };
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, arg, prefix)) {
                const value = arg[prefix.len..];
                if (value.len == 0) return .{ .missing_value = arg };
                if (home_test.corpus_runner.parseSubsetFlagValue(value)) |subset| {
                    return .{ .ok = subset };
                }
                return .{ .unknown_value = value };
            }
        }
    }
    return .none;
}

fn failBunCorpusSubsetArg(reason: []const u8, value: []const u8) noreturn {
    std.debug.print("\n{s}Bun Corpus Native Subset: INVALID{s}\n", .{ Color.Red.code(), Color.Reset.code() });
    std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("reason: {s}\n", .{reason});
    if (value.len != 0) std.debug.print("value: {s}\n", .{value});
    std.debug.print("supported subsets: minimal-js, bundler-core-itbundled, bundler-transpiler-bootstrap\n\n", .{});
    std.process.exit(1);
}

test "bun corpus target parser skips subset flag values" {
    const args = [_][:0]const u8{ "--bun-corpus-native-subset", "packages/runtime/test/bun-corpus" };
    try std.testing.expect(argTargetsBunCorpus(&args) == null);
}

test "bun corpus target parser resolves roots and descendant files" {
    const relative_root = [_][:0]const u8{"packages/runtime/test/bun-corpus"};
    switch (argTargetsBunCorpus(&relative_root).?) {
        .root => |path| try std.testing.expectEqualStrings("packages/runtime/test/bun-corpus", path),
        else => return error.ExpectedBunCorpusRoot,
    }

    const absolute_root = [_][:0]const u8{"/tmp/home/packages/runtime/test/bun-corpus/"};
    switch (argTargetsBunCorpus(&absolute_root).?) {
        .root => |path| try std.testing.expectEqualStrings("/tmp/home/packages/runtime/test/bun-corpus", path),
        else => return error.ExpectedBunCorpusRoot,
    }

    const relative_file = [_][:0]const u8{"packages/runtime/test/bun-corpus/js/node/path/join.test.js"};
    switch (argTargetsBunCorpus(&relative_file).?) {
        .file => |target| {
            try std.testing.expectEqualStrings("packages/runtime/test/bun-corpus", target.corpus_path);
            try std.testing.expectEqualStrings("js/node/path/join.test.js", target.relative_path);
        },
        else => return error.ExpectedBunCorpusFile,
    }

    const absolute_file = [_][:0]const u8{"/tmp/home/packages/runtime/test/bun-corpus/bake/fixtures/deinitialization/test.ts"};
    switch (argTargetsBunCorpus(&absolute_file).?) {
        .file => |target| {
            try std.testing.expectEqualStrings("/tmp/home/packages/runtime/test/bun-corpus", target.corpus_path);
            try std.testing.expectEqualStrings("bake/fixtures/deinitialization/test.ts", target.relative_path);
        },
        else => return error.ExpectedBunCorpusFile,
    }

    const non_corpus = [_][:0]const u8{"packages/runtime/test/bun-corpus-old/foo.test.js"};
    try std.testing.expect(argTargetsBunCorpus(&non_corpus) == null);
}

test "bun corpus subset parser reports missing and unknown values" {
    const missing = [_][:0]const u8{"--bun-corpus-native-subset"};
    switch (argBunCorpusSubset(&missing)) {
        .missing_value => |flag| try std.testing.expectEqualStrings("--bun-corpus-native-subset", flag),
        else => return error.ExpectedMissingSubsetValue,
    }

    const unknown = [_][:0]const u8{"--bun-corpus-native-subset=all"};
    switch (argBunCorpusSubset(&unknown)) {
        .unknown_value => |value| try std.testing.expectEqualStrings("all", value),
        else => return error.ExpectedUnknownSubsetValue,
    }
}

test "bun corpus subset parser accepts minimal js" {
    const args = [_][:0]const u8{ "packages/runtime/test/bun-corpus", "--bun-corpus-native-subset=minimal-js" };
    switch (argBunCorpusSubset(&args)) {
        .ok => |subset| try std.testing.expectEqual(home_test.corpus_runner.Subset.minimal_js, subset),
        else => return error.ExpectedSubset,
    }
}

test "bun corpus subset parser accepts bundler core itBundled" {
    const args = [_][:0]const u8{ "packages/runtime/test/bun-corpus", "--bun-corpus-native-subset=bundler-core-itbundled" };
    switch (argBunCorpusSubset(&args)) {
        .ok => |subset| try std.testing.expectEqual(home_test.corpus_runner.Subset.bundler_core_itbundled, subset),
        else => return error.ExpectedSubset,
    }
}

test "bun corpus subset parser accepts bundler transpiler bootstrap" {
    const args = [_][:0]const u8{ "packages/runtime/test/bun-corpus", "--bun-corpus-native-subset=bundler-transpiler-bootstrap" };
    switch (argBunCorpusSubset(&args)) {
        .ok => |subset| try std.testing.expectEqual(home_test.corpus_runner.Subset.bundler_transpiler_bootstrap, subset),
        else => return error.ExpectedSubset,
    }
}

fn runBunCorpusNativeSubset(allocator: std.mem.Allocator, corpus_path: []const u8, subset: home_test.corpus_runner.Subset) !void {
    var summary = try home_test.corpus_runner.runSubset(g_io, allocator, corpus_path, subset);

    if (summary.blocked) {
        std.debug.print("\n{s}Bun Corpus Native Subset: BLOCKED{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
        std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });
        std.debug.print("path: {s}\n", .{corpus_path});
        std.debug.print("subset: {s}\n", .{subset.label()});
        std.debug.print("files selected: {d}\n", .{summary.files});
        std.debug.print("runner package: packages/home_test\n", .{});
        std.debug.print("reason: {s}\n\n", .{summary.reason});
        std.debug.print("Build `home` with `./pantry/.bin/zig build -Denable_jsc=true` to execute this native subset.\n", .{});
        std.debug.print("This bootstrap subset is not the full Bun corpus acceptance gate.\n\n", .{});
        std.process.exit(1);
    }

    const tests_observed = summary.passed + summary.failed + summary.todo;
    const no_tests = tests_observed == 0 and summary.allowed_empty_files == 0;
    const failed = summary.failed != 0 or summary.files == 0 or no_tests;
    std.debug.print("\n{s}Bun Corpus Native Subset: {s}{s}\n", .{
        if (!failed) Color.Green.code() else Color.Red.code(),
        if (!failed) "PASS" else "FAIL",
        Color.Reset.code(),
    });
    std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("path: {s}\n", .{corpus_path});
    std.debug.print("subset: {s}\n", .{subset.label()});
    std.debug.print("files executed: {d}\n", .{summary.files});
    std.debug.print("tests passed: {d}\n", .{summary.passed});
    std.debug.print("tests failed: {d}\n", .{summary.failed});
    std.debug.print("tests todo: {d}\n\n", .{summary.todo});
    if (summary.first_failure_file.len != 0) {
        std.debug.print("first failure: {s}\n", .{summary.first_failure_file});
        std.debug.print("message: {s}\n\n", .{summary.first_failure_message});
    }
    if (no_tests) {
        std.debug.print("reason: no-tests-observed\n\n", .{});
    }

    if (failed) {
        summary.deinit(allocator);
        std.process.exit(1);
    }
    summary.deinit(allocator);
}

fn runBunCorpusNativeGate(allocator: std.mem.Allocator, corpus_path: []const u8) !void {
    const counts = home_test.corpus.countPath(g_io, corpus_path) catch |err| switch (err) {
        error.FileNotFound => home_test.corpus.Counts{},
        else => return err,
    };

    const sha_path = try std.fs.path.join(allocator, &.{ corpus_path, "UPSTREAM_SHA.txt" });
    defer allocator.free(sha_path);
    const sha = Io.Dir.cwd().readFileAlloc(g_io, sha_path, allocator, std.Io.Limit.limited(256)) catch "unknown";
    defer if (!std.mem.eql(u8, sha, "unknown")) allocator.free(sha);

    var summary = try home_test.corpus_runner.runGate(g_io, allocator, corpus_path);
    defer summary.deinit(allocator);

    if (summary.blocked) {
        std.debug.print("\n{s}Bun Corpus Native Gate: BLOCKED{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
        std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });
        std.debug.print("path: {s}\n", .{corpus_path});
        std.debug.print("upstream: {s}\n", .{std.mem.trim(u8, sha, " \t\r\n")});
        std.debug.print("corpus files discovered: {d}\n", .{counts.files});
        std.debug.print("test files discovered: {d}\n", .{counts.tests});
        std.debug.print("runner package: packages/home_test\n", .{});
        std.debug.print("reason: {s}\n\n", .{summary.reason});
        std.debug.print("Build `home` with `./pantry/.bin/zig build -Denable_jsc=true` to execute the native Bun corpus gate.\n\n", .{});
        std.process.exit(1);
    }

    const tests_observed = summary.passed + summary.failed + summary.todo;
    const no_tests = tests_observed == 0 and summary.allowed_empty_files == 0;
    const failed = summary.failed != 0 or summary.files == 0 or no_tests;
    std.debug.print("\n{s}Bun Corpus Native Gate: {s}{s}\n", .{
        if (!failed) Color.Green.code() else Color.Red.code(),
        if (!failed) "PASS" else "FAIL",
        Color.Reset.code(),
    });
    std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("path: {s}\n", .{corpus_path});
    std.debug.print("upstream: {s}\n", .{std.mem.trim(u8, sha, " \t\r\n")});
    std.debug.print("corpus files discovered: {d}\n", .{counts.files});
    std.debug.print("test files discovered: {d}\n", .{counts.tests});
    std.debug.print("runner package: packages/home_test\n", .{});
    std.debug.print("files executed: {d}\n", .{summary.files});
    std.debug.print("tests passed: {d}\n", .{summary.passed});
    std.debug.print("tests failed: {d}\n", .{summary.failed});
    std.debug.print("tests unsupported: {d}\n", .{summary.unsupported});
    std.debug.print("tests todo: {d}\n\n", .{summary.todo});
    if (summary.first_failure_file.len != 0) {
        std.debug.print("first failure: {s}\n", .{summary.first_failure_file});
        std.debug.print("message: {s}\n\n", .{summary.first_failure_message});
    }
    if (no_tests) {
        std.debug.print("reason: no-tests-observed\n\n", .{});
    }
    std.debug.print("A delegated `bun test` result is not accepted as Home runtime parity.\n\n", .{});

    if (failed) std.process.exit(1);
}

fn runBunCorpusNativeFile(allocator: std.mem.Allocator, corpus_path: []const u8, relative_path: []const u8) !void {
    var summary = try home_test.corpus_runner.runFile(g_io, allocator, corpus_path, relative_path);
    defer summary.deinit(allocator);

    if (summary.blocked) {
        std.debug.print("\n{s}Bun Corpus Native File: BLOCKED{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
        std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });
        std.debug.print("path: {s}\n", .{corpus_path});
        std.debug.print("file: {s}\n", .{relative_path});
        std.debug.print("runner package: packages/home_test\n", .{});
        std.debug.print("reason: {s}\n\n", .{summary.reason});
        std.debug.print("Build `home` with `./pantry/.bin/zig build -Denable_jsc=true` to execute native Bun corpus files.\n\n", .{});
        std.process.exit(1);
    }

    const tests_observed = summary.passed + summary.failed + summary.todo;
    const no_tests = tests_observed == 0 and summary.allowed_empty_files == 0;
    const failed = summary.failed != 0 or summary.files == 0 or no_tests;
    std.debug.print("\n{s}Bun Corpus Native File: {s}{s}\n", .{
        if (!failed) Color.Green.code() else Color.Red.code(),
        if (!failed) "PASS" else "FAIL",
        Color.Reset.code(),
    });
    std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });
    std.debug.print("path: {s}\n", .{corpus_path});
    std.debug.print("file: {s}\n", .{relative_path});
    std.debug.print("runner package: packages/home_test\n", .{});
    std.debug.print("files executed: {d}\n", .{summary.files});
    std.debug.print("tests passed: {d}\n", .{summary.passed});
    std.debug.print("tests failed: {d}\n", .{summary.failed});
    std.debug.print("tests unsupported: {d}\n", .{summary.unsupported});
    std.debug.print("tests todo: {d}\n\n", .{summary.todo});
    if (summary.first_failure_file.len != 0) {
        std.debug.print("first failure: {s}\n", .{summary.first_failure_file});
        std.debug.print("message: {s}\n\n", .{summary.first_failure_message});
    }
    if (no_tests) {
        std.debug.print("reason: no-tests-observed\n\n", .{});
    }

    if (failed) std.process.exit(1);
}

fn testCommand(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    // Experimental: route bun-corpus files through the FULL native VM
    // (TestCommand.exec → real globals + module loader) instead of the
    // shim-based corpus runner, so corpus tests get Home's real Buffer/fs/etc.
    // Gated while validated against the corpus baseline.
    if (build_options.enable_jsc and envFlagSet("HOME_NATIVE_VM") and envFlagSet("HOME_CORPUS_FULL_VM")) {
        runTestsViaVM(allocator, args) catch |err| {
            std.debug.print("{s}error:{s} native test run failed: {s}\n", .{ Color.Red.code(), Color.Reset.code(), @errorName(err) });
            std.process.exit(1);
        };
        return;
    }
    const bun_corpus_subset_arg = argBunCorpusSubset(args);
    if (argTargetsBunCorpus(args)) |target| {
        switch (target) {
            .root => |corpus_path| switch (bun_corpus_subset_arg) {
                .none => return runBunCorpusNativeGate(allocator, corpus_path),
                .ok => |subset| return runBunCorpusNativeSubset(allocator, corpus_path, subset),
                .missing_value => |flag| failBunCorpusSubsetArg("missing-subset-value", flag),
                .unknown_value => |value| failBunCorpusSubsetArg("unknown-subset", value),
            },
            .file => |file| switch (bun_corpus_subset_arg) {
                .none => return runBunCorpusNativeFile(allocator, file.corpus_path, file.relative_path),
                .ok => failBunCorpusSubsetArg("subset-requires-bun-corpus-root", file.relative_path),
                .missing_value => |flag| failBunCorpusSubsetArg("missing-subset-value", flag),
                .unknown_value => |value| failBunCorpusSubsetArg("unknown-subset", value),
            },
        }
    } else switch (bun_corpus_subset_arg) {
        .none => {},
        .ok => |subset| failBunCorpusSubsetArg("subset-requires-bun-corpus-path", subset.label()),
        .missing_value => |flag| failBunCorpusSubsetArg("missing-subset-value", flag),
        .unknown_value => |value| failBunCorpusSubsetArg("unknown-subset", value),
    }

    // Phase 12 routing: if the cwd looks like a JS/TS project, delegate
    // `home test` to the bun-compatible runtime path. `--home` or `--zig`
    // overrides forces the native Home/Zig runner.
    if (isJsLikeTestProject(args)) {
        var force_native = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--home") or std.mem.eql(u8, a, "--zig")) {
                force_native = true;
                break;
            }
        }
        if (!force_native) {
            // Native bun:test runner: run through Home's own TestCommand.exec
            // (Jest runner + full VM + module loader: describe/test/expect/
            // lifecycle/snapshots all work). This is the default whenever JSC is
            // linked — it removes the dependency on a system `bun` and is the
            // native-first direction. `HOME_NATIVE_VM` is still honored for
            // back-compat but no longer required. Falls back to bun delegation
            // only when JSC is unavailable (non-enable_jsc builds).
            if (build_options.enable_jsc) {
                runTestsViaVM(allocator, args) catch |err| {
                    std.debug.print("{s}error:{s} native test run failed: {s}\n", .{ Color.Red.code(), Color.Reset.code(), @errorName(err) });
                    std.process.exit(1);
                };
                return;
            }
            return execBunCommand(allocator, "test", args);
        }
    }

    // Parse arguments
    var options = TestOptions{};
    var path_arg: ?[]const u8 = null;
    var i: usize = 0;
    var show_help = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bail")) {
            options.bail = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            if (i + 1 < args.len) {
                i += 1;
                options.timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch 5000;
            }
        } else if (std.mem.eql(u8, arg, "--zig")) {
            options.zig_only = true;
        } else if (std.mem.eql(u8, arg, "--home")) {
            options.home_only = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--package")) {
            if (i + 1 < args.len) {
                i += 1;
                options.package = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (arg[0] != '-') {
            path_arg = arg;
        }
    }

    if (show_help) {
        printTestUsage();
        return;
    }

    // If no args, auto-discover and run tests across the monorepo
    if (path_arg == null) {
        try runMonorepoTests(allocator, options);
        return;
    }

    const file_path = path_arg.?;

    // Check if the path is a directory
    const stat = Io.Dir.cwd().statFile(g_io, file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("{s}Error:{s} Path not found: {s}\n", .{
                Color.Red.code(),
                Color.Reset.code(),
                file_path,
            });
            std.process.exit(1);
        }
        return err;
    };

    // If it's a directory, run all test files in it
    if (stat.kind == .directory) {
        try runTestSuite(allocator, file_path, options);
        return;
    }

    // For single files, use runTestFile which properly handles it() blocks
    std.debug.print("\n{s}Home Test Suite{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
    std.debug.print("{s}━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.Cyan.code(), Color.Reset.code() });

    const result = runTestFile(allocator, file_path, options.verbose);
    if (result) |test_count| {
        std.debug.print("\n{s}━━━━━━━━━━━━━━━━{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
        std.debug.print("{s}✓ All tests passed!{s} ({d} tests)\n\n", .{ Color.Green.code(), Color.Reset.code(), test_count });
    } else |_| {
        std.debug.print("\n{s}━━━━━━━━━━━━━━━━{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
        std.debug.print("{s}✗ Tests failed{s}\n\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    }
}

/// Test options struct
pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    // Capture this (main/JS) thread's stack bounds so bun.StackCheck guards can
    // actually measure remaining stack; without this every isSafeToRecurse()
    // is a no-op and deep-nested input overflows the native stack instead of
    // throwing (mirrors Bun's src/main.zig).
    home_rt.StackCheck.configureThread();
    // Enable memory tracking in debug builds if configured
    var debug_allocator = std.heap.DebugAllocator(.{
        .enable_memory_limit = build_options.memory_tracking,
        .verbose_log = build_options.memory_tracking,
    }).init;
    defer {
        const leaked = debug_allocator.deinit();
        if (leaked == .leak and build_options.memory_tracking) {
            std.debug.print("\n{s}Warning:{s} Memory leaks detected!\n", .{ Color.Yellow.code(), Color.Reset.code() });
        }
    }
    const allocator = debug_allocator.allocator();

    var args_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());

    // Populate the runtime's process argv (empty by default). The native VM's
    // node:process reads `bun.argv[0]` (createArgv0) and would panic on an empty
    // slice; the eval/CJS realm paths pass argv explicitly and are unaffected.
    if (home_rt.argv.len == 0 and args.len > 0) home_rt.argv = @constCast(args);

    // `--experimental-http{2,3}-fetch` enable h2/h3 in fetch() TLS ALPN. Home's
    // command dispatch doesn't thread these runtime flags into the JS realm (the
    // vendored bun.js.zig/Arguments set-sites are dead in this exe), so bridge
    // them here — the earliest point with argv — into the equivalent
    // BUN_FEATURE_FLAG env var the ALPN gate (http.canOfferH2) reads live via
    // getenv. Setting the env var (vs a module global) is robust to the runtime's
    // split http.zig module instances and matches the flag's documented meaning
    // ("Same as BUN_FEATURE_FLAG_EXPERIMENTAL_HTTP2_CLIENT=1").
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--experimental-http2-fetch")) {
            _ = setenv("BUN_FEATURE_FLAG_EXPERIMENTAL_HTTP2_CLIENT", "1", 1);
        } else if (std.mem.eql(u8, arg, "--experimental-http3-fetch")) {
            _ = setenv("BUN_FEATURE_FLAG_EXPERIMENTAL_HTTP3_CLIENT", "1", 1);
        }
    }

    // Check if called as 'homecheck' - automatically run test mode
    const program_name = std.fs.path.basename(args[0]);
    if (std.mem.eql(u8, program_name, "homecheck")) {
        // Rebuild args to inject 'test' command
        var test_args: std.ArrayList([:0]const u8) = .empty;
        defer test_args.deinit(allocator);

        try test_args.append(allocator, args[0]); // Program name
        try test_args.append(allocator, blk: {
            const s = "test";
            const buf = try allocator.allocSentinel(u8, s.len, 0);
            @memcpy(buf, s);
            break :blk buf;
        }); // Inject 'test' command

        // Add remaining args (skip program name)
        if (args.len > 1) {
            for (args[1..]) |arg| {
                try test_args.append(allocator, arg);
            }
        } else {
            // No args provided - show help
            printTestUsage();
            return;
        }

        // Handle test subcommands
        const subcmd = args[1];

        if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
            printTestUsage();
            return;
        }

        if (std.mem.eql(u8, subcmd, "--discover") or std.mem.eql(u8, subcmd, "-d")) {
            const search_path = if (args.len > 2) args[2] else ".";
            try testDiscoverCommand(allocator, search_path);
            return;
        }

        // Otherwise treat as file path
        try testCommand(allocator, args[1..]);
        return;
    }

    // If no arguments provided, start REPL
    if (args.len < 2) {
        try repl.start(allocator);
        return;
    }

    const command = args[1];

    // `bun --version`/`-v` prints the version (e.g. "1.3.14") to stdout and exits;
    // `--revision` prints the version+sha. Tests and tooling spawn
    // `bunExe() --version`, so accept it at the top level (it previously errored
    // "Unknown command").
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        const stdout_file = std.Io.File.stdout();
        stdout_file.writeStreamingAll(g_io, home_rt.Global.package_json_version ++ "\n") catch {};
        return;
    }
    if (std.mem.eql(u8, command, "--revision")) {
        const stdout_file = std.Io.File.stdout();
        stdout_file.writeStreamingAll(g_io, home_rt.Global.package_json_version_with_revision ++ "\n") catch {};
        return;
    }

    // Faithful to `bun --eval <code>` / `bun -e <code>`: a top-level flag (not a
    // subcommand) that evaluates an inline source string. Many bun-corpus tests
    // re-spawn the runtime as `bunExe() --eval "..."`, so this must be accepted
    // at the top level the same way `home eval <code>` is. The result is not
    // auto-printed (matching bun); `--print`/`-p` opts into printing.
    if (std.mem.eql(u8, command, "--eval") or std.mem.eql(u8, command, "-e")) {
        var code: ?[]const u8 = null;
        var print_result = false;
        // Positional args AFTER the code become process.argv[1..], matching
        // `bun -e '<code>' a b` → process.argv = [exe, a, b]. Tests spawn
        // `bunExe() -e '...process.argv[1]...' <path>`, so dropping them left
        // process.argv missing the path (read as undefined).
        var extra: std.ArrayListUnmanaged([:0]const u8) = .empty;
        defer extra.deinit(allocator);
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--print") or std.mem.eql(u8, args[i], "-p")) {
                print_result = true;
            } else if (code == null) {
                code = args[i];
            } else {
                try extra.append(allocator, args[i]);
            }
        }
        if (code == null) {
            std.debug.print("{s}error:{s} '--eval' requires a code argument\n\n", .{ Color.Red.code(), Color.Reset.code() });
            std.debug.print("usage: home --eval <code> [--print|-p]\n", .{});
            std.process.exit(1);
        }
        // Without `--print`, run through the full VM (faithful globals + error
        // printer). `--print` stays on the eval shim, which formats the result
        // value. globalExits on success.
        if (build_options.enable_jsc and !print_result) {
            runInlineEvalViaVM(allocator, code.?, extra.items) catch |err| {
                std.debug.print("{s}error:{s} eval failed: {s}\n", .{ Color.Red.code(), Color.Reset.code(), @errorName(err) });
                std.process.exit(1);
            };
            return;
        }
        var extra8: std.ArrayListUnmanaged([]const u8) = .empty;
        defer extra8.deinit(allocator);
        for (extra.items) |a| try extra8.append(allocator, a);
        try evalCommand(allocator, code.?, print_result, extra8.items);
        return;
    }

    // `bun --print <code>` / `bun -p <code>`: evaluate and auto-print the result.
    if (std.mem.eql(u8, command, "--print") or std.mem.eql(u8, command, "-p")) {
        if (args.len < 3) {
            std.debug.print("{s}error:{s} '--print' requires a code argument\n\n", .{ Color.Red.code(), Color.Reset.code() });
            std.debug.print("usage: home --print <code>\n", .{});
            std.process.exit(1);
        }
        try evalCommand(allocator, args[2], true, &.{});
        return;
    }

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
            std.debug.print("{s}Error:{s} 'check' command requires a path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try checkPathCommand(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "explain")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'explain' command requires a diagnostic code\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        explainCommand(args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "lint")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'lint' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try lint_cmd.lintCommand(allocator, args[2..], g_io);
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

    if (std.mem.eql(u8, command, "fix")) {
        const target = if (args.len >= 3) args[2] else "src";
        try fixCommand(allocator, target);
        return;
    }

    if (std.mem.eql(u8, command, "dev")) {
        const target = if (args.len >= 3) args[2] else null;
        try devCommand(allocator, target);
        return;
    }

    if (std.mem.eql(u8, command, "lsp")) {
        try lspCommand(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "symbols")) {
        const target = if (args.len >= 3) args[2] else "src";
        try symbolsCommand(allocator, target);
        return;
    }

    if (std.mem.eql(u8, command, "docs")) {
        try docsCommand(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "completions")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'completions' requires bash, zsh, or fish\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try completionsCommand(args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "doctor")) {
        try doctorCommand(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "clean")) {
        try cleanCommand();
        return;
    }

    if (std.mem.eql(u8, command, "ci")) {
        const target = if (args.len >= 3) args[2] else "src";
        try ciCommand(allocator, target);
        return;
    }

    if (std.mem.eql(u8, command, "api-diff")) {
        if (args.len < 4) {
            std.debug.print("{s}Error:{s} 'api-diff' requires <old.d.hm> <new.d.hm>\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try apiDiffCommand(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, command, "size")) {
        const target = if (args.len >= 3) args[2] else ".";
        try sizeCommand(allocator, target);
        return;
    }

    if (std.mem.eql(u8, command, "eval")) {
        // Collect the code argument plus an optional --print/-p flag.
        var code: ?[]const u8 = null;
        var print_result = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--print") or std.mem.eql(u8, args[i], "-p")) {
                print_result = true;
            } else if (code == null) {
                code = args[i];
            }
        }
        if (code == null) {
            std.debug.print("{s}error:{s} 'eval' requires a code argument\n\n", .{ Color.Red.code(), Color.Reset.code() });
            std.debug.print("usage: home eval <code> [--print|-p]\n", .{});
            std.process.exit(1);
        }
        try evalCommand(allocator, code.?, print_result, &.{});
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            // No file provided, start REPL
            try repl.start(allocator);
            return;
        }

        try runCommand(allocator, args[2], args[3..]);
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

    if (std.mem.eql(u8, command, "watch")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'watch' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try watchCommand(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "test") or std.mem.eql(u8, command, "t")) {
        // Handle test subcommands
        if (args.len < 3) {
            // No arguments - auto-run test suite in tests/ directory
            try testCommand(allocator, &.{});
            return;
        }

        // Check for subcommands
        const subcmd = args[2];

        if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
            printTestUsage();
            return;
        }

        if (std.mem.eql(u8, subcmd, "--discover") or std.mem.eql(u8, subcmd, "-d")) {
            const search_path = if (args.len > 3) args[3] else ".";
            try testDiscoverCommand(allocator, search_path);
            return;
        }

        // Otherwise treat as file path or directory
        try testCommand(allocator, args[2..]);
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

    // ---- Bun-compatible CLI surface (Phase 12 in progress) ----
    // `home add`, `home install`, `home remove`, `home update` route to
    // Pantry (Home's package manager + registry, lives at ~/Code/pantry).
    if (std.mem.eql(u8, command, "add") or std.mem.eql(u8, command, "i")) {
        try execPantryCommand(allocator, "add", args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "install")) {
        try execPantryCommand(allocator, "install", args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "remove") or std.mem.eql(u8, command, "rm") or std.mem.eql(u8, command, "uninstall")) {
        try execPantryCommand(allocator, "remove", args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "update") or std.mem.eql(u8, command, "upgrade")) {
        try execPantryCommand(allocator, "update", args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "outdated")) {
        try execPantryCommand(allocator, "outdated", args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "audit")) {
        try execPantryCommand(allocator, "audit", args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "why")) {
        const runtime_allocator = home_rt.default_allocator;
        const log = try runtime_allocator.create(home_rt.logger.Log);
        log.* = home_rt.logger.Log.init(runtime_allocator);
        const ctx = home_rt.cli.Command.initDefaultContext(runtime_allocator, log);
        try home_rt.cli.WhyCommand.execStandalone(ctx, args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "whoami")) {
        const runtime_allocator = home_rt.default_allocator;
        const log = try runtime_allocator.create(home_rt.logger.Log);
        log.* = home_rt.logger.Log.init(runtime_allocator);
        const ctx = home_rt.cli.Command.initDefaultContext(runtime_allocator, log);
        try home_rt.cli.PackageManagerCommand.execUtilities(ctx);
        return;
    }
    // Bun-compatible package-manager utilities routed to their native runtime
    // ports. Commands with standalone ports stay above this shared dispatcher.
    if (std.mem.eql(u8, command, "pm")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} unsupported 'pm' subcommand\n", .{ Color.Red.code(), Color.Reset.code() });
            std.process.exit(1);
        }
        const runtime_allocator = home_rt.default_allocator;
        const log = try runtime_allocator.create(home_rt.logger.Log);
        log.* = home_rt.logger.Log.init(runtime_allocator);
        const ctx = home_rt.cli.Command.initDefaultContext(runtime_allocator, log);

        if (std.mem.eql(u8, args[2], "scan")) {
            try home_rt.cli.ScanCommand.execStandalone(ctx, args[3..]);
            return;
        }
        if (std.mem.eql(u8, args[2], "version")) {
            try home_rt.cli.PmVersionCommand.execStandalone(ctx, args[3..]);
            return;
        }
        if (std.mem.eql(u8, args[2], "why")) {
            try home_rt.cli.WhyCommand.execStandalone(ctx, args[3..]);
            return;
        }
        if (std.mem.eql(u8, args[2], "ls") or
            std.mem.eql(u8, args[2], "list") or
            std.mem.eql(u8, args[2], "cache") or
            std.mem.eql(u8, args[2], "bin") or
            std.mem.eql(u8, args[2], "migrate") or
            std.mem.eql(u8, args[2], "hash") or
            std.mem.eql(u8, args[2], "whoami"))
        {
            try home_rt.cli.PackageManagerCommand.execUtilities(ctx);
            return;
        }
        if (!std.mem.eql(u8, args[2], "pkg")) {
            std.debug.print("{s}Error:{s} unsupported 'pm' subcommand\n", .{ Color.Red.code(), Color.Reset.code() });
            std.process.exit(1);
        }
        var positionals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer positionals.deinit(runtime_allocator);
        try positionals.append(runtime_allocator, "pkg");
        for (args[3..]) |arg| try positionals.append(runtime_allocator, arg);

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CurrentWorkingDirectoryUnavailable;
        const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
        try home_rt.cli.PmPkgCommand.execStandalone(ctx, positionals.items, cwd);
        return;
    }
    // `home x` / `home exec` — bunx-equivalent.
    if (std.mem.eql(u8, command, "x") or std.mem.eql(u8, command, "exec")) {
        // TODO(phase-12-10): replace with native homex (copied from Bun's src/cli/).
        try execBunCommand(allocator, "x", args[2..]);
        return;
    }
    // `home create` — bun create / npm init equivalent.
    if (std.mem.eql(u8, command, "create")) {
        try execBunCommand(allocator, "create", args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "package")) {
        try package_cmd.packageCommand(allocator, args[2..], g_io);
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

    // `home [runtime-flags] (--print|-p) <expr>` / `(-e|--eval) <code>` —
    // Bun-style inline eval through the full VM (real globals). Handled before
    // the file-based implicit run since these take an expression, not a file.
    if (build_options.enable_jsc) {
        if (try tryEvalFlagRun(allocator, args)) return;
    }

    // Implicit run: `home [runtime-flags] <file.js|.ts|…> [script-args]`
    // (Bun's default — `bun --expose-gc x.js` runs x.js). Only engages when a
    // runnable JS/TS file is present, so bare flags like `--help` are
    // unaffected. Leading runtime flags (e.g. --expose-gc) are accepted and
    // skipped here; the native run path doesn't need them to execute.
    {
        var has_file = false;
        for (args[1..]) |a| {
            if (looksLikeRunnableFile(a)) {
                has_file = true;
                break;
            }
        }
        if (has_file and (std.mem.startsWith(u8, command, "-") or looksLikeRunnableFile(command))) {
            // `--require`/`-r`/`--preload <file>` (and `--require=<file>`) name
            // PRELOAD modules, not the entry. Collect them and skip them when
            // choosing the entry (otherwise the first one is picked as the file
            // to run and the real main never executes).
            var preloads: std.ArrayListUnmanaged([]const u8) = .empty;
            // `--conditions=<name>` (and `--conditions <name>`) add custom
            // package.json "exports"/"imports" conditions (comma-separated values
            // and repeated flags both accepted, matching Bun).
            var conditions: std.ArrayListUnmanaged([]const u8) = .empty;
            const addConditions = struct {
                fn call(list: *std.ArrayListUnmanaged([]const u8), alloc: std.mem.Allocator, csv: []const u8) void {
                    var it = std.mem.splitScalar(u8, csv, ',');
                    while (it.next()) |part| {
                        const trimmed = std.mem.trim(u8, part, " \t");
                        if (trimmed.len > 0) list.append(alloc, trimmed) catch {};
                    }
                }
            }.call;
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                const a = args[i];
                if (std.mem.eql(u8, a, "--require") or std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--preload")) {
                    if (i + 1 < args.len) {
                        preloads.append(allocator, args[i + 1]) catch {};
                        i += 1;
                    }
                    continue;
                }
                if (std.mem.startsWith(u8, a, "--require=")) {
                    preloads.append(allocator, a["--require=".len..]) catch {};
                    continue;
                }
                if (std.mem.startsWith(u8, a, "--preload=")) {
                    preloads.append(allocator, a["--preload=".len..]) catch {};
                    continue;
                }
                if (std.mem.eql(u8, a, "--conditions")) {
                    if (i + 1 < args.len) {
                        addConditions(&conditions, allocator, args[i + 1]);
                        i += 1;
                    }
                    continue;
                }
                if (std.mem.startsWith(u8, a, "--conditions=")) {
                    addConditions(&conditions, allocator, a["--conditions=".len..]);
                    continue;
                }
                if (looksLikeRunnableFile(a)) {
                    g_user_preloads = preloads.items;
                    g_user_conditions = conditions.items;
                    try runCommand(allocator, a, args[i + 1 ..]);
                    return;
                }
            }
        }
    }

    std.debug.print("{s}Error:{s} Unknown command '{s}'\n\n", .{ Color.Red.code(), Color.Reset.code(), command });
    printUsage();
    std.process.exit(1);
}

/// True if `s` names a JS/TS module by extension (used to recognize an
/// implicit `home <file>` run invocation).
fn looksLikeRunnableFile(s: []const u8) bool {
    const exts = [_][]const u8{ ".js", ".mjs", ".cjs", ".jsx", ".ts", ".mts", ".cts", ".tsx" };
    for (exts) |e| {
        if (std.mem.endsWith(u8, s, e)) return true;
    }
    return false;
}

fn pkgCommand(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
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

    if (std.mem.eql(u8, subcmd, "tools") or std.mem.eql(u8, subcmd, "toolchain")) {
        try pkgTools(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "search") or
        std.mem.eql(u8, subcmd, "info") or
        std.mem.eql(u8, subcmd, "audit") or
        std.mem.eql(u8, subcmd, "dedupe") or
        std.mem.eql(u8, subcmd, "link") or
        std.mem.eql(u8, subcmd, "unlink") or
        std.mem.eql(u8, subcmd, "publish") or
        std.mem.eql(u8, subcmd, "pack") or
        std.mem.eql(u8, subcmd, "version") or
        std.mem.eql(u8, subcmd, "doctor") or
        std.mem.eql(u8, subcmd, "clean"))
    {
        if (!try runPantryPassthrough(allocator, subcmd, args[1..])) {
            std.debug.print("{s}Error:{s} pantry is required for `home pkg {s}`.\n", .{ Color.Red.code(), Color.Reset.code(), subcmd });
            std.debug.print("Install it with: curl -fsSL https://pantry.dev | bash\n", .{});
            std.process.exit(1);
        }
        return;
    }

    // New Bun-inspired commands
    if (std.mem.eql(u8, subcmd, "tree")) {
        try pkgTree(allocator);
        return;
    }

    if (std.mem.eql(u8, subcmd, "why")) {
        if (args.len < 2) {
            std.debug.print("{s}Error:{s} 'pkg why' requires a package name\n", .{ Color.Red.code(), Color.Reset.code() });
            std.process.exit(1);
        }
        try pkgWhy(allocator, args[1]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "outdated")) {
        try pkgOutdated(allocator);
        return;
    }

    if (std.mem.eql(u8, subcmd, "size")) {
        const target = if (args.len >= 2) args[1] else ".";
        try sizeCommand(allocator, target);
        return;
    }

    if (std.mem.eql(u8, subcmd, "declarations") or std.mem.eql(u8, subcmd, "types") or std.mem.eql(u8, subcmd, "d.hm")) {
        try pkgDeclarations(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "docs")) {
        try docsCommand(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "api-diff")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'pkg api-diff' requires <old.d.hm> <new.d.hm>\n", .{ Color.Red.code(), Color.Reset.code() });
            std.process.exit(1);
        }
        try apiDiffCommand(allocator, args[1], args[2]);
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
        Io.Dir.cwd().createDir(g_io, name, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("{s}Error:{s} Failed to create directory '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), name, err });
                return err;
            }
            std.debug.print("{s}Warning:{s} Directory '{s}' already exists, initializing in place\n", .{ Color.Yellow.code(), Color.Reset.code(), name });
        };

        if (comptime native_os == .windows) {
            const windows = std.os.windows;
            var wide_buf: [256]u16 = undefined;
            const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, name) catch return error.BadPathName;
            const wide_path = windows.UNICODE_STRING{
                .Length = @intCast(wide_len * 2),
                .MaximumLength = @intCast(wide_len * 2),
                .Buffer = &wide_buf,
            };
            const status = windows.ntdll.RtlSetCurrentDirectory_U(&wide_path);
            if (status != .SUCCESS) return error.FileNotFound;
        } else {
            try std.Io.Threaded.chdir(name);
        }
    }

    // Create directories
    const dirs = [_][]const u8{ "src", "tests", ".home", ".home/declarations" };
    for (dirs) |dir| {
        Io.Dir.cwd().createDir(g_io, dir, .default_dir) catch |err| {
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
        const file = try Io.Dir.cwd().createFile(g_io, "package.jsonc", .{});
        defer file.close(g_io);
        try file.writeStreamingAll(g_io, package_content);
        std.debug.print("{s}✓{s} Created package.jsonc\n", .{ Color.Green.code(), Color.Reset.code() });
    }

    const deps_yaml =
        \\# Project toolchain managed by pantry.
        \\# Run: home pkg tools
        \\dependencies:
        \\  - ziglang.org@0.17.0-dev.1275+59a628c6d
        \\  - bun
        \\
    ;

    {
        const file = try Io.Dir.cwd().createFile(g_io, "deps.yaml", .{});
        defer file.close(g_io);
        try file.writeStreamingAll(g_io, deps_yaml);
        std.debug.print("{s}✓{s} Created deps.yaml\n", .{ Color.Green.code(), Color.Reset.code() });
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
        const file = try Io.Dir.cwd().createFile(g_io, "src/main.home", .{});
        defer file.close(g_io);
        try file.writeStreamingAll(g_io, main_home);
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
        const file = try Io.Dir.cwd().createFile(g_io, "tests/example.home", .{});
        defer file.close(g_io);
        try file.writeStreamingAll(g_io, test_file);
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
        \\├── deps.yaml           # Pantry-managed project toolchain
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
        const file = try Io.Dir.cwd().createFile(g_io, "README.md", .{});
        defer file.close(g_io);
        try file.writeStreamingAll(g_io, readme_content);
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
        const file = try Io.Dir.cwd().createFile(g_io, ".gitignore", .{});
        defer file.close(g_io);
        try file.writeStreamingAll(g_io, gitignore);
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
        \\declarations = ".home/declarations/my-home-project.d.hm"
        \\
        \\[toolchain]
        \\manager = "pantry"
        \\file = "deps.yaml"
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

    const file = try Io.Dir.cwd().createFile(g_io, "home.toml", .{});
    defer file.close(g_io);
    try file.writeStreamingAll(g_io, content);

    std.debug.print("{s}✓{s} Created home.toml\n", .{ Color.Green.code(), Color.Reset.code() });

    const deps_yaml =
        \\# Project toolchain managed by pantry.
        \\# Run: home pkg tools
        \\dependencies:
        \\  - ziglang.org@0.17.0-dev.1275+59a628c6d
        \\  - bun
        \\
    ;

    Io.Dir.cwd().access(g_io, "deps.yaml", .{}) catch {
        const deps_file = try Io.Dir.cwd().createFile(g_io, "deps.yaml", .{});
        defer deps_file.close(g_io);
        try deps_file.writeStreamingAll(g_io, deps_yaml);
        std.debug.print("{s}✓{s} Created deps.yaml\n", .{ Color.Green.code(), Color.Reset.code() });
    };

    std.debug.print("Edit home.toml to configure your project\n", .{});
}

fn pkgAdd(allocator: std.mem.Allocator, spec: []const u8) !void {
    std.debug.print("{s}Adding package:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), spec });

    var pm = PackageManager.init(allocator, g_io) catch {
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

    var pm = PackageManager.init(allocator, g_io) catch {
        std.debug.print("{s}Error:{s} No home.toml found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    };
    defer pm.deinit();

    try pm.removeDependency(name);
    std.debug.print("{s}✓{s} Removed {s}\n", .{ Color.Green.code(), Color.Reset.code(), name });
}

fn pkgUpdate(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Updating dependencies...{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    var pm = PackageManager.init(allocator, g_io) catch {
        std.debug.print("{s}Error:{s} No home.toml found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    };
    defer pm.deinit();

    try pm.update();
    std.debug.print("{s}✓{s} Dependencies updated\n", .{ Color.Green.code(), Color.Reset.code() });
}

fn pkgInstall(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Installing dependencies...{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    var pm = PackageManager.init(allocator, g_io) catch {
        std.debug.print("{s}Error:{s} No home.toml found. Run 'home pkg init' first.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    };
    defer pm.deinit();

    try pm.resolve();
    std.debug.print("{s}✓{s} All dependencies installed\n", .{ Color.Green.code(), Color.Reset.code() });
}

fn runPantryPassthrough(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !bool {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "pantry");
    try argv.append(allocator, subcmd);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.spawn(g_io, .{ .argv = argv.items }) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };

    const term = try child.wait(g_io);
    switch (term) {
        .exited => |code| {
            if (code != 0) std.process.exit(code);
        },
        else => std.process.exit(1),
    }

    return true;
}

fn pkgTools(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    const has_deps_file = blk: {
        Io.Dir.cwd().access(g_io, "deps.yaml", .{}) catch {
            Io.Dir.cwd().access(g_io, "dependencies.yaml", .{}) catch {
                Io.Dir.cwd().access(g_io, "pantry.yaml", .{}) catch {
                    break :blk false;
                };
            };
        };
        break :blk true;
    };

    if (!has_deps_file) {
        std.debug.print("{s}Error:{s} No Pantry dependency file found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.debug.print("Create deps.yaml or run {s}home pkg init{s}.\n", .{ Color.Cyan.code(), Color.Reset.code() });
        std.process.exit(1);
    }

    std.debug.print("{s}Installing project tools with pantry...{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
    if (!try runPantryPassthrough(allocator, "install", args)) {
        std.debug.print("{s}Error:{s} pantry is not installed or not on PATH.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.debug.print("Install it with: curl -fsSL https://pantry.dev | bash\n", .{});
        std.process.exit(1);
    }
}

const DependencyLine = struct {
    name: []const u8,
    spec: []const u8,
    source_file: []const u8,

    fn deinit(self: DependencyLine, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.spec);
        allocator.free(self.source_file);
    }
};

fn appendFmt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn stripInlineComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') in_string = !in_string;
        if (!in_string and c == '#') return line[0..i];
        if (!in_string and c == '/' and i + 1 < line.len and line[i + 1] == '/') return line[0..i];
    }
    return line;
}

fn trimQuotes(value: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, value, " \t\r\n,");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        trimmed = trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parseTomlDependencies(allocator: std.mem.Allocator, file_name: []const u8, content: []const u8, deps: *std.ArrayList(DependencyLine)) !void {
    var in_dependencies = false;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const no_comment = stripInlineComment(line);
        const trimmed = std.mem.trim(u8, no_comment, " \t\r");
        if (trimmed.len == 0) continue;

        if (trimmed[0] == '[') {
            in_dependencies = std.mem.eql(u8, trimmed, "[dependencies]");
            continue;
        }

        if (!in_dependencies) continue;
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const spec = trimQuotes(trimmed[eq_pos + 1 ..]);
        if (name.len == 0 or spec.len == 0) continue;

        try deps.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .spec = try allocator.dupe(u8, spec),
            .source_file = try allocator.dupe(u8, file_name),
        });
    }
}

fn parseJsonDependencies(allocator: std.mem.Allocator, file_name: []const u8, content: []const u8, deps: *std.ArrayList(DependencyLine)) !void {
    var in_dependencies = false;
    var brace_depth: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const no_comment = stripInlineComment(line);
        const trimmed = std.mem.trim(u8, no_comment, " \t\r");
        if (trimmed.len == 0) continue;

        if (!in_dependencies and std.mem.indexOf(u8, trimmed, "\"dependencies\"") != null and std.mem.indexOfScalar(u8, trimmed, '{') != null) {
            in_dependencies = true;
            brace_depth = 1;
            continue;
        }

        if (!in_dependencies) continue;

        for (trimmed) |c| {
            if (c == '{') brace_depth += 1;
            if (c == '}' and brace_depth > 0) brace_depth -= 1;
        }
        if (brace_depth == 0) {
            in_dependencies = false;
            continue;
        }

        const colon_pos = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const raw_name = trimQuotes(trimmed[0..colon_pos]);
        const raw_spec = trimQuotes(trimmed[colon_pos + 1 ..]);
        if (raw_name.len == 0 or raw_spec.len == 0 or raw_spec[0] == '{') continue;

        try deps.append(allocator, .{
            .name = try allocator.dupe(u8, raw_name),
            .spec = try allocator.dupe(u8, raw_spec),
            .source_file = try allocator.dupe(u8, file_name),
        });
    }
}

fn collectProjectDependencies(allocator: std.mem.Allocator) !std.ArrayList(DependencyLine) {
    var deps = std.ArrayList(DependencyLine).empty;
    errdefer {
        for (deps.items) |dep| dep.deinit(allocator);
        deps.deinit(allocator);
    }

    const files = [_][]const u8{
        "home.toml",
        "couch.toml",
        "couch.jsonc",
        "couch.json",
        "home.json",
        "package.jsonc",
        "package.json",
    };

    for (files) |file_name| {
        const content = Io.Dir.cwd().readFileAlloc(g_io, file_name, allocator, std.Io.Limit.limited(1024 * 1024)) catch continue;
        defer allocator.free(content);

        if (std.mem.endsWith(u8, file_name, ".toml")) {
            try parseTomlDependencies(allocator, file_name, content, &deps);
        } else {
            try parseJsonDependencies(allocator, file_name, content, &deps);
        }
    }

    return deps;
}

fn pkgWhy(allocator: std.mem.Allocator, name: []const u8) !void {
    const name_z = try home_rt.dupeZ(allocator, u8, name);
    defer allocator.free(name_z);
    if (try runPantryPassthrough(allocator, "why", &.{name_z})) return;

    var deps = try collectProjectDependencies(allocator);
    defer {
        for (deps.items) |dep| dep.deinit(allocator);
        deps.deinit(allocator);
    }

    for (deps.items) |dep| {
        if (std.mem.eql(u8, dep.name, name)) {
            std.debug.print("{s}{s}{s} is a direct dependency.\n", .{ Color.Green.code(), name, Color.Reset.code() });
            std.debug.print("  required: {s}\n", .{dep.spec});
            std.debug.print("  listed in: {s}\n", .{dep.source_file});
            return;
        }
    }

    std.debug.print("{s}{s}{s} is not listed as a direct dependency.\n", .{ Color.Yellow.code(), name, Color.Reset.code() });
    std.debug.print("Transitive tracing will use lockfile edges once the Pantry-backed resolver writes them.\n", .{});
}

fn specLooksPinned(spec: []const u8) bool {
    if (spec.len == 0) return false;
    if (std.mem.indexOf(u8, spec, "git") != null) return true;
    if (std.mem.indexOf(u8, spec, "url") != null) return true;
    if (std.mem.startsWith(u8, spec, "workspace:")) return true;
    if (std.mem.startsWith(u8, spec, "path:")) return true;
    if (std.mem.startsWith(u8, spec, "file:")) return true;
    if (spec[0] == '^' or spec[0] == '~' or spec[0] == '>' or spec[0] == '<') return false;
    var dots: usize = 0;
    for (spec) |c| {
        if (c == '.') dots += 1;
        if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+')) return false;
    }
    return dots >= 2;
}

fn pkgOutdated(allocator: std.mem.Allocator) !void {
    if (try runPantryPassthrough(allocator, "outdated", &.{})) return;

    var deps = try collectProjectDependencies(allocator);
    defer {
        for (deps.items) |dep| dep.deinit(allocator);
        deps.deinit(allocator);
    }

    if (deps.items.len == 0) {
        std.debug.print("{s}No dependencies found.{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
        return;
    }

    std.debug.print("{s}Dependency update candidates{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });
    std.debug.print("{s:<28} {s:<18} {s:<12} {s}\n", .{ "Package", "Current", "Status", "File" });
    std.debug.print("{s:<28} {s:<18} {s:<12} {s}\n", .{ "-------", "-------", "------", "----" });

    for (deps.items) |dep| {
        const status = if (specLooksPinned(dep.spec)) "pinned" else "range";
        std.debug.print("{s:<28} {s:<18} {s:<12} {s}\n", .{ dep.name, dep.spec, status, dep.source_file });
    }

    std.debug.print("\nRegistry-backed latest-version checks are the next resolver step; this command now gives the stable local view.\n", .{});
}

fn detectPackageName(allocator: std.mem.Allocator) ![]const u8 {
    const files = [_][]const u8{ "home.toml", "couch.toml", "package.jsonc", "package.json" };
    for (files) |file_name| {
        const content = Io.Dir.cwd().readFileAlloc(g_io, file_name, allocator, std.Io.Limit.limited(1024 * 1024)) catch continue;
        defer allocator.free(content);

        var in_package = std.mem.endsWith(u8, file_name, ".json") or std.mem.endsWith(u8, file_name, ".jsonc");
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, stripInlineComment(line), " \t\r,");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '[') {
                in_package = std.mem.eql(u8, trimmed, "[package]");
                continue;
            }
            if (!in_package) continue;

            if (std.mem.startsWith(u8, trimmed, "name")) {
                const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                return try allocator.dupe(u8, trimQuotes(trimmed[eq + 1 ..]));
            }
            if (std.mem.startsWith(u8, trimmed, "\"name\"")) {
                const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                return try allocator.dupe(u8, trimQuotes(trimmed[colon + 1 ..]));
            }
        }
    }

    return try allocator.dupe(u8, "home-package");
}

fn isHomeSourceFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".home") or std.mem.endsWith(u8, path, ".hm");
}

fn startsDeclaration(trimmed: []const u8) bool {
    const public = if (std.mem.startsWith(u8, trimmed, "pub ")) trimmed[4..] else trimmed;
    return std.mem.startsWith(u8, public, "fn ") or
        std.mem.startsWith(u8, public, "struct ") or
        std.mem.startsWith(u8, public, "enum ") or
        std.mem.startsWith(u8, public, "trait ") or
        std.mem.startsWith(u8, public, "type ") or
        std.mem.startsWith(u8, public, "const ");
}

fn normalizeDeclarationLine(line: []const u8) []const u8 {
    var text = std.mem.trim(u8, stripInlineComment(line), " \t\r");
    if (std.mem.startsWith(u8, text, "pub ")) text = text[4..];

    if (std.mem.indexOfScalar(u8, text, '{')) |brace| {
        text = std.mem.trim(u8, text[0..brace], " \t\r");
    } else if (std.mem.indexOfScalar(u8, text, '=')) |eq| {
        if (std.mem.startsWith(u8, text, "const ") or std.mem.startsWith(u8, text, "type ")) {
            text = std.mem.trim(u8, text[0..eq], " \t\r");
        }
    }

    return text;
}

fn emitDeclarationsFromSource(allocator: std.mem.Allocator, source_path: []const u8, source: []const u8, output: *std.ArrayList(u8)) !usize {
    var count: usize = 0;
    var wrote_source_header = false;
    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') continue;

        const decl = normalizeDeclarationLine(line);
        if (!startsDeclaration(decl)) continue;

        if (!wrote_source_header) {
            try appendFmt(output, allocator, "\n// {s}\n", .{source_path});
            wrote_source_header = true;
        }

        try appendFmt(output, allocator, "export {s}\n", .{decl});
        count += 1;
    }

    return count;
}

fn collectDeclarationsFromDir(allocator: std.mem.Allocator, dir_path: []const u8, output: *std.ArrayList(u8)) !usize {
    var count: usize = 0;
    var dir = Io.Dir.cwd().openDir(g_io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer dir.close(g_io);

    var iter = dir.iterate();
    while (try iter.next(g_io)) |entry| {
        if (entry.kind == .file) {
            if (!isHomeSourceFile(entry.name)) continue;
            const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(path);
            const source = try Io.Dir.cwd().readFileAlloc(g_io, path, allocator, std.Io.Limit.limited(4 * 1024 * 1024));
            defer allocator.free(source);
            count += try emitDeclarationsFromSource(allocator, path, source, output);
        } else if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, ".home") or std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, "zig-cache") or std.mem.eql(u8, entry.name, "zig-out")) {
                continue;
            }
            const subdir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(subdir);
            count += try collectDeclarationsFromDir(allocator, subdir, output);
        }
    }

    return count;
}

const DeclarationRender = struct {
    content: []u8,
    count: usize,

    fn deinit(self: DeclarationRender, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

fn renderPackageDeclarations(allocator: std.mem.Allocator, package_name: []const u8, src_dir: []const u8) !DeclarationRender {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try appendFmt(&output, allocator,
        \\// Generated by `home pkg declarations`.
        \\// This is Home API metadata, not a TypeScript .d.ts file.
        \\
        \\declare package "{s}"
        \\
    , .{package_name});

    const count = try collectDeclarationsFromDir(allocator, src_dir, &output);
    return .{
        .content = try output.toOwnedSlice(allocator),
        .count = count,
    };
}

fn pkgDeclarations(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var src_dir: []const u8 = "src";
    var out_path: ?[]const u8 = null;
    var check_only = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if ((std.mem.eql(u8, args[i], "--src") or std.mem.eql(u8, args[i], "-s")) and i + 1 < args.len) {
            i += 1;
            src_dir = args[i];
        } else if ((std.mem.eql(u8, args[i], "--out") or std.mem.eql(u8, args[i], "-o")) and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--check")) {
            check_only = true;
        }
    }

    const package_name = try detectPackageName(allocator);
    defer allocator.free(package_name);

    const generated_path = if (out_path) |path|
        try allocator.dupe(u8, path)
    else
        try std.fmt.allocPrint(allocator, ".home/declarations/{s}.d.hm", .{package_name});
    defer allocator.free(generated_path);

    Io.Dir.cwd().createDir(g_io, ".home", .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    Io.Dir.cwd().createDir(g_io, ".home/declarations", .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const rendered = try renderPackageDeclarations(allocator, package_name, src_dir);
    defer rendered.deinit(allocator);

    if (check_only) {
        const current = Io.Dir.cwd().readFileAlloc(g_io, generated_path, allocator, std.Io.Limit.limited(16 * 1024 * 1024)) catch |err| {
            std.debug.print("{s}Error:{s} declaration file is missing or unreadable: {s} ({})\n", .{ Color.Red.code(), Color.Reset.code(), generated_path, err });
            std.process.exit(1);
        };
        defer allocator.free(current);

        if (!std.mem.eql(u8, current, rendered.content)) {
            std.debug.print("{s}Error:{s} declarations are out of date: {s}\n", .{ Color.Red.code(), Color.Reset.code(), generated_path });
            std.debug.print("Run `home pkg declarations` to refresh them.\n", .{});
            std.process.exit(1);
        }

        std.debug.print("{s}✓{s} Declarations are current ({d} declarations)\n", .{ Color.Green.code(), Color.Reset.code(), rendered.count });
        return;
    }

    const file = try Io.Dir.cwd().createFile(g_io, generated_path, .{});
    defer file.close(g_io);
    try file.writeStreamingAll(g_io, rendered.content);

    std.debug.print("{s}✓{s} Wrote {s} ({d} declarations)\n", .{ Color.Green.code(), Color.Reset.code(), generated_path, rendered.count });
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
    if (try runPantryPassthrough(allocator, "tree", &.{})) return;

    std.debug.print("{s}Dependency Tree:{s}\n", .{ Color.Blue.code(), Color.Reset.code() });

    // Check for home.lock
    const lock_exists = blk: {
        Io.Dir.cwd().access(g_io, "home.lock", .{}) catch {
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
}

fn pkgRun(allocator: std.mem.Allocator, script_name: []const u8) !void {
    std.debug.print("{s}Running script:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), script_name });

    // Check for home.toml
    const toml_exists = blk: {
        Io.Dir.cwd().access(g_io, "home.toml", .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!toml_exists) {
        std.debug.print("{s}Error:{s} No home.toml found.\n", .{ Color.Red.code(), Color.Reset.code() });
        std.process.exit(1);
    }

    // Parse home.toml and look for [scripts] section
    const toml_content = try Io.Dir.cwd().readFileAlloc(g_io, "home.toml", allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(toml_content);

    var scripts = try parseTomlScripts(allocator, toml_content);
    defer {
        for (scripts.items) |script| {
            allocator.free(script.name);
            allocator.free(script.command);
        }
        scripts.deinit(allocator);
    }

    // Look for the requested script
    for (scripts.items) |script| {
        if (std.mem.eql(u8, script.name, script_name)) {
            std.debug.print("🚀 {s}\n", .{script.command});
            // Execute the command
            var child = try std.process.spawn(g_io, .{ .argv = &[_][]const u8{ "sh", "-c", script.command } });
            const term = try child.wait(g_io);
            switch (term) {
                .exited => |code| {
                    if (code != 0) {
                        std.process.exit(code);
                    }
                },
                else => std.process.exit(1),
            }
            return;
        }
    }

    // Script not found
    std.debug.print("{s}Error:{s} Script '{s}' not found in home.toml\n", .{ Color.Red.code(), Color.Reset.code(), script_name });
    std.debug.print("\nDefine it in home.toml:\n", .{});
    std.debug.print("[scripts]\n{s} = \"your command here\"\n", .{script_name});
    std.process.exit(1);
}

fn pkgScripts(allocator: std.mem.Allocator) !void {
    std.debug.print("{s}Available scripts:{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    // Check for home.toml
    const toml_exists = blk: {
        Io.Dir.cwd().access(g_io, "home.toml", .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!toml_exists) {
        std.debug.print("{s}No home.toml found.{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
        std.debug.print("\n{s}Tip:{s} Create a home.toml file with a [scripts] section\n", .{ Color.Cyan.code(), Color.Reset.code() });
        return;
    }

    // Parse home.toml for actual scripts
    const toml_content = try Io.Dir.cwd().readFileAlloc(g_io, "home.toml", allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(toml_content);

    var scripts = try parseTomlScripts(allocator, toml_content);
    defer {
        for (scripts.items) |script| {
            allocator.free(script.name);
            allocator.free(script.command);
        }
        scripts.deinit(allocator);
    }

    if (scripts.items.len == 0) {
        std.debug.print("{s}No scripts found in home.toml{s}\n", .{ Color.Yellow.code(), Color.Reset.code() });
        std.debug.print("\n{s}Tip:{s} Add scripts to home.toml:\n", .{ Color.Cyan.code(), Color.Reset.code() });
        std.debug.print("[scripts]\ndev = \"home run src/main.home --watch\"\n", .{});
    } else {
        for (scripts.items) |script| {
            std.debug.print("  {s}{s}{s}      {s}\n", .{ Color.Green.code(), script.name, Color.Reset.code(), script.command });
        }
    }
}

/// Login to package registry
fn pkgLogin(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
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
    if (token == null) {
        if (comptime native_os != .windows and native_os != .linux) {
            if (std.c.getenv("ION_TOKEN")) |env_ptr| {
                const env_token = std.mem.span(env_ptr);
                token = env_token;
                std.debug.print("{s}Using token from ION_TOKEN environment variable{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
            }
        }
    }

    var pm = PackageManager.init(allocator, g_io) catch {
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
fn pkgLogout(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    std.debug.print("{s}Logout from Home Package Registry{s}\n\n", .{ Color.Blue.code(), Color.Reset.code() });

    var registry: ?[]const u8 = null;

    if (args.len > 0 and std.mem.eql(u8, args[0], "--registry") and args.len > 1) {
        registry = args[1];
    }

    var pm = PackageManager.init(allocator, g_io) catch {
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
    var pm = PackageManager.init(allocator, g_io) catch {
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

/// Apply an ad-hoc code signature to a freshly-built macOS arm64 binary.
/// Apple Silicon's kernel refuses to execute unsigned arm64 binaries; an
/// ad-hoc signature (no developer cert) is enough to satisfy that check.
fn adhocCodesign(_: std.mem.Allocator, path: []const u8) !void {
    if (builtin.os.tag != .macos) return;

    var child = try std.process.spawn(g_io, .{
        .argv = &.{ "codesign", "--sign", "-", "--force", path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(g_io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CodesignFailed,
        else => return error.CodesignFailed,
    }
}
