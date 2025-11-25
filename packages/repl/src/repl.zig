const std = @import("std");
const lexer = @import("lexer");
const parser = @import("parser");
const interpreter = @import("interpreter");
const ast = @import("ast");

/// REPL (Read-Eval-Print Loop) for Home language
///
/// Features:
/// - Interactive expression evaluation
/// - Multi-line input support
/// - Command history
/// - Tab completion
/// - Variable persistence across evaluations
/// - Special commands (:help, :clear, :exit, etc.)
pub const REPL = struct {
    allocator: std.mem.Allocator,
    interpreter: *interpreter.Interpreter,
    history: History,
    completer: Completer,
    session: Session,
    config: Config,
    running: bool,

    pub const Config = struct {
        prompt: []const u8 = "home> ",
        continuation_prompt: []const u8 = "....> ",
        history_size: usize = 1000,
        enable_colors: bool = true,
        auto_indent: bool = true,
        show_types: bool = false,
    };

    pub const Session = struct {
        allocator: std.mem.Allocator,
        /// Variables defined in this session
        variables: std.StringHashMap(*interpreter.Value),
        /// Functions defined in this session
        functions: std.StringHashMap(ast.FunctionDecl),
        /// Evaluation count
        eval_count: usize,

        pub fn init(allocator: std.mem.Allocator) Session {
            return .{
                .allocator = allocator,
                .variables = std.StringHashMap(*interpreter.Value).init(allocator),
                .functions = std.StringHashMap(ast.FunctionDecl).init(allocator),
                .eval_count = 0,
            };
        }

        pub fn deinit(self: *Session) void {
            self.variables.deinit();
            self.functions.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !REPL {
        const interp = try allocator.create(interpreter.Interpreter);
        interp.* = interpreter.Interpreter.init(allocator);

        return .{
            .allocator = allocator,
            .interpreter = interp,
            .history = History.init(allocator, config.history_size),
            .completer = Completer.init(allocator),
            .session = Session.init(allocator),
            .config = config,
            .running = false,
        };
    }

    pub fn deinit(self: *REPL) void {
        self.interpreter.deinit();
        self.allocator.destroy(self.interpreter);
        self.history.deinit();
        self.completer.deinit();
        self.session.deinit();
    }

    /// Start the REPL loop
    pub fn run(self: *REPL) !void {
        self.running = true;

        try self.printWelcome();

        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();

        var line_buffer: [4096]u8 = undefined;
        var multi_line_buffer = std.ArrayList(u8).init(self.allocator);
        defer multi_line_buffer.deinit();

        var in_multi_line = false;

        while (self.running) {
            // Print prompt
            const prompt = if (in_multi_line) self.config.continuation_prompt else self.config.prompt;
            try stdout.print("{s}", .{prompt});

            // Read line
            const line = (try stdin.readUntilDelimiterOrEof(&line_buffer, '\n')) orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Check for special commands
            if (!in_multi_line and std.mem.startsWith(u8, trimmed, ":")) {
                try self.handleCommand(trimmed);
                continue;
            }

            // Handle multi-line input
            if (self.needsMoreInput(trimmed)) {
                try multi_line_buffer.appendSlice(trimmed);
                try multi_line_buffer.append('\n');
                in_multi_line = true;
                continue;
            }

            // Complete input
            const input = if (in_multi_line) blk: {
                try multi_line_buffer.appendSlice(trimmed);
                const result = try multi_line_buffer.toOwnedSlice();
                multi_line_buffer = std.ArrayList(u8).init(self.allocator);
                in_multi_line = false;
                break :blk result;
            } else try self.allocator.dupe(u8, trimmed);
            defer self.allocator.free(input);

            // Skip empty lines
            if (input.len == 0) continue;

            // Add to history
            try self.history.add(input);

            // Evaluate
            try self.evaluate(input);
        }

        try stdout.print("\nGoodbye!\n", .{});
    }

    fn evaluate(self: *REPL, input: []const u8) !void {
        const stdout = std.io.getStdOut().writer();

        // Parse input
        var lex = lexer.Lexer.init(self.allocator, input);
        defer lex.deinit();

        var tokens = try lex.tokenize();
        defer tokens.deinit();

        var parse = parser.Parser.init(self.allocator, tokens.items);
        defer parse.deinit();

        const program = parse.parseProgram() catch |err| {
            try stdout.print("Parse error: {}\n", .{err});
            return;
        };
        defer program.deinit();

        // Check for parse errors
        if (parse.errors.items.len > 0) {
            for (parse.errors.items) |parse_err| {
                try stdout.print("Error: {s}\n", .{parse_err});
            }
            return;
        }

        // Evaluate
        const result = self.interpreter.eval(program) catch |err| {
            try stdout.print("Runtime error: {}\n", .{err});
            return;
        };

        // Print result
        try self.printResult(result);

        self.session.eval_count += 1;
    }

    fn printResult(self: *REPL, value: *interpreter.Value) !void {
        const stdout = std.io.getStdOut().writer();

        const value_str = try value.toString(self.allocator);
        defer self.allocator.free(value_str);

        if (self.config.show_types) {
            try stdout.print("{s} : {s}\n", .{ value_str, @tagName(value.*) });
        } else {
            try stdout.print("{s}\n", .{value_str});
        }
    }

    fn needsMoreInput(self: *REPL, line: []const u8) bool {
        _ = self;
        // Simple heuristic: needs more input if line ends with {, [, or (
        if (line.len == 0) return false;

        const last_char = line[line.len - 1];
        return last_char == '{' or last_char == '[' or last_char == '(';
    }

    fn handleCommand(self: *REPL, cmd: []const u8) !void {
        const stdout = std.io.getStdOut().writer();

        if (std.mem.eql(u8, cmd, ":help") or std.mem.eql(u8, cmd, ":h")) {
            try self.printHelp();
        } else if (std.mem.eql(u8, cmd, ":exit") or std.mem.eql(u8, cmd, ":quit") or std.mem.eql(u8, cmd, ":q")) {
            self.running = false;
        } else if (std.mem.eql(u8, cmd, ":clear") or std.mem.eql(u8, cmd, ":c")) {
            try self.clearScreen();
        } else if (std.mem.eql(u8, cmd, ":reset")) {
            self.session.deinit();
            self.session = Session.init(self.allocator);
            self.interpreter.deinit();
            self.interpreter.* = interpreter.Interpreter.init(self.allocator);
            try stdout.print("Session reset\n", .{});
        } else if (std.mem.eql(u8, cmd, ":vars")) {
            try self.printVariables();
        } else if (std.mem.eql(u8, cmd, ":history")) {
            try self.history.print();
        } else if (std.mem.eql(u8, cmd, ":types")) {
            self.config.show_types = !self.config.show_types;
            try stdout.print("Type display: {s}\n", .{if (self.config.show_types) "on" else "off"});
        } else {
            try stdout.print("Unknown command: {s}. Type :help for help.\n", .{cmd});
        }
    }

    fn printWelcome(self: *REPL) !void {
        _ = self;
        const stdout = std.io.getStdOut().writer();
        try stdout.print(
            \\
            \\Home Language REPL v0.1.0
            \\Type :help for help, :exit to exit
            \\
            \\
        , .{});
    }

    fn printHelp(self: *REPL) !void {
        _ = self;
        const stdout = std.io.getStdOut().writer();
        try stdout.print(
            \\
            \\REPL Commands:
            \\  :help, :h       Show this help
            \\  :exit, :quit    Exit the REPL
            \\  :clear, :c      Clear the screen
            \\  :reset          Reset the session (clear all variables)
            \\  :vars           Show all variables
            \\  :history        Show command history
            \\  :types          Toggle type display
            \\
            \\You can enter any Home expression or statement.
            \\Multi-line input is supported (press Enter on incomplete lines).
            \\
            \\
        , .{});
    }

    fn clearScreen(self: *REPL) !void {
        _ = self;
        const stdout = std.io.getStdOut().writer();
        // ANSI escape code to clear screen
        try stdout.print("\x1B[2J\x1B[H", .{});
    }

    fn printVariables(self: *REPL) !void {
        const stdout = std.io.getStdOut().writer();

        if (self.session.variables.count() == 0) {
            try stdout.print("No variables defined\n", .{});
            return;
        }

        try stdout.print("\nVariables:\n", .{});
        var it = self.session.variables.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            const value_str = try value.toString(self.allocator);
            defer self.allocator.free(value_str);

            try stdout.print("  {s} = {s}\n", .{ name, value_str });
        }
        try stdout.print("\n", .{});
    }
};

/// Command history with persistence
pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]const u8),
    max_size: usize,
    current_index: usize,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) History {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList([]const u8).init(allocator),
            .max_size = max_size,
            .current_index = 0,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit();
    }

    pub fn add(self: *History, entry: []const u8) !void {
        // Don't add empty or duplicate entries
        if (entry.len == 0) return;
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, entry)) return;
        }

        const owned = try self.allocator.dupe(u8, entry);

        if (self.entries.items.len >= self.max_size) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old);
        }

        try self.entries.append(owned);
        self.current_index = self.entries.items.len;
    }

    pub fn previous(self: *History) ?[]const u8 {
        if (self.current_index == 0) return null;
        self.current_index -= 1;
        return self.entries.items[self.current_index];
    }

    pub fn next(self: *History) ?[]const u8 {
        if (self.current_index >= self.entries.items.len - 1) return null;
        self.current_index += 1;
        return self.entries.items[self.current_index];
    }

    pub fn print(self: *History) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("\nHistory:\n", .{});
        for (self.entries.items, 0..) |entry, i| {
            try stdout.print("  {d}: {s}\n", .{ i + 1, entry });
        }
        try stdout.print("\n", .{});
    }

    pub fn save(self: *History, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        for (self.entries.items) |entry| {
            try file.writeAll(entry);
            try file.writeAll("\n");
        }
    }

    pub fn load(self: *History, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                try self.add(line);
            }
        }
    }
};

/// Tab completion for REPL
pub const Completer = struct {
    allocator: std.mem.Allocator,
    keywords: std.StringHashSet,
    builtins: std.StringHashSet,

    pub fn init(allocator: std.mem.Allocator) Completer {
        var keywords = std.StringHashSet.init(allocator);
        var builtins = std.StringHashSet.init(allocator);

        // Add keywords
        const keyword_list = [_][]const u8{
            "fn",      "let",    "const",  "if",     "else",   "while",
            "for",     "return", "break",  "continue", "match", "type",
            "struct",  "enum",   "impl",   "trait",  "use",    "pub",
            "async",   "await",  "defer",  "errdefer",
        };

        for (keyword_list) |kw| {
            keywords.put(kw, {}) catch {};
        }

        // Add builtins
        const builtin_list = [_][]const u8{
            "println", "print", "assert", "panic", "todo",
        };

        for (builtin_list) |builtin| {
            builtins.put(builtin, {}) catch {};
        }

        return .{
            .allocator = allocator,
            .keywords = keywords,
            .builtins = builtins,
        };
    }

    pub fn deinit(self: *Completer) void {
        self.keywords.deinit();
        self.builtins.deinit();
    }

    pub fn complete(self: *Completer, prefix: []const u8) !std.ArrayList([]const u8) {
        var completions = std.ArrayList([]const u8).init(self.allocator);

        // Check keywords
        var kw_it = self.keywords.iterator();
        while (kw_it.next()) |entry| {
            const keyword = entry.key_ptr.*;
            if (std.mem.startsWith(u8, keyword, prefix)) {
                try completions.append(keyword);
            }
        }

        // Check builtins
        var builtin_it = self.builtins.iterator();
        while (builtin_it.next()) |entry| {
            const builtin = entry.key_ptr.*;
            if (std.mem.startsWith(u8, builtin, prefix)) {
                try completions.append(builtin);
            }
        }

        return completions;
    }
};
