const std = @import("std");
const linter_mod = @import("linter");
const Linter = linter_mod.Linter;
const LinterConfig = linter_mod.LinterConfig;
const LinterConfigLoader = linter_mod.LinterConfigLoader;
const Formatter = @import("formatter").Formatter;
const Lexer = @import("lexer").Lexer;
const Parser = @import("parser").Parser;

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

pub fn lintCommand(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var fix_mode = false;
    var file_path: ?[]const u8 = null;

    // Parse arguments
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--fix")) {
            fix_mode = true;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            file_path = arg;
        }
    }

    if (file_path == null) {
        std.debug.print("{s}Error:{s} 'lint' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
        return error.MissingFilePath;
    }

    const path = file_path.?;

    // Read the file
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    // Load config from project directory
    var config_loader = LinterConfigLoader.init(allocator);
    var config = try config_loader.loadConfig(null);
    defer config.deinit();

    var linter = Linter.init(allocator, config);
    defer linter.deinit();

    // Run linter
    if (fix_mode) {
        std.debug.print("{s}Linting & Fixing:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), path });
    } else {
        std.debug.print("{s}Linting:{s} {s}\n\n", .{ Color.Blue.code(), Color.Reset.code(), path });
    }

    const diagnostics = try linter.lint(source);

    if (diagnostics.len == 0) {
        std.debug.print("{s}✓{s} No issues found\n", .{ Color.Green.code(), Color.Reset.code() });
        return;
    }

    // Print diagnostics
    for (diagnostics) |diag| {
        const severity_color = switch (diag.severity) {
            .error_ => Color.Red,
            .warning => Color.Yellow,
            .info => Color.Cyan,
            .hint => Color.Reset,
        };

        std.debug.print(
            "{s}:{d}:{d} {s}{s}{s}: {s} [{s}]\n",
            .{
                path,
                diag.line,
                diag.column,
                severity_color.code(),
                diag.severity.toString(),
                Color.Reset.code(),
                diag.message,
                diag.rule_id,
            },
        );

        if (diag.fix) |fix| {
            std.debug.print("  {s}💡 {s}{s}\n", .{ Color.Cyan.code(), fix.message, Color.Reset.code() });
        }
    }

    // Count by severity
    var errors: usize = 0;
    var warnings: usize = 0;
    var info: usize = 0;
    var hints: usize = 0;

    for (diagnostics) |diag| {
        switch (diag.severity) {
            .error_ => errors += 1,
            .warning => warnings += 1,
            .info => info += 1,
            .hint => hints += 1,
        }
    }

    std.debug.print("\n{s}Summary:{s}\n", .{ Color.Blue.code(), Color.Reset.code() });
    if (errors > 0) {
        std.debug.print("  {s}✗ {d} error(s){s}\n", .{ Color.Red.code(), errors, Color.Reset.code() });
    }
    if (warnings > 0) {
        std.debug.print("  {s}⚠ {d} warning(s){s}\n", .{ Color.Yellow.code(), warnings, Color.Reset.code() });
    }
    if (info > 0) {
        std.debug.print("  {s}ℹ {d} info{s}\n", .{ Color.Cyan.code(), info, Color.Reset.code() });
    }
    if (hints > 0) {
        std.debug.print("  {s}💡 {d} hint(s){s}\n", .{ Color.Reset.code(), hints, Color.Reset.code() });
    }

    // Apply fixes if requested
    if (fix_mode) {
        std.debug.print("\n{s}Applying auto-fixes...{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });

        // Auto-fix linting issues
        const auto_fixed = try linter.autoFix();
        const fixed_source = if (auto_fixed.len > 0) auto_fixed else source;
        defer if (auto_fixed.len > 0) allocator.free(auto_fixed);

        // Format the code
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var lexer = Lexer.init(arena_allocator, fixed_source);
        const tokens = try lexer.tokenize();

        var parser = try Parser.init(arena_allocator, tokens.items);
        const program = try parser.parse();

        var formatter = Formatter.init(allocator, program);
        defer formatter.deinit();

        const formatted = try formatter.format(.{});
        defer allocator.free(formatted);

        // Write back to file
        const out_file = try std.fs.cwd().createFile(path, .{});
        defer out_file.close();
        try out_file.writeAll(formatted);

        std.debug.print("{s}✓{s} Fixed and formatted\n", .{ Color.Green.code(), Color.Reset.code() });
    } else if (errors > 0 or warnings > 0) {
        std.debug.print("\n{s}Tip:{s} Run with {s}--fix{s} to automatically fix issues\n", .{
            Color.Cyan.code(),
            Color.Reset.code(),
            Color.Green.code(),
            Color.Reset.code(),
        });
    }

    // Exit with error code if there are errors
    if (errors > 0) {
        std.process.exit(1);
    }
}
