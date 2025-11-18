const std = @import("std");
const ast = @import("ast");
const lexer_mod = @import("lexer");
const Token = lexer_mod.Token;
const TokenType = lexer_mod.TokenType;
const Lexer = lexer_mod.Lexer;
const Parser = @import("parser").Parser;

pub const LinterConfigLoader = @import("config_loader.zig").LinterConfigLoader;

pub const Severity = enum {
    error_,
    warning,
    info,
    hint,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .error_ => "error",
            .warning => "warning",
            .info => "info",
            .hint => "hint",
        };
    }
};

pub const LintDiagnostic = struct {
    rule_id: []const u8,
    severity: Severity,
    message: []const u8,
    line: usize,
    column: usize,
    end_line: usize,
    end_column: usize,
    fix: ?Fix = null,

    pub const Fix = struct {
        message: []const u8,
        edits: []TextEdit,
    };

    pub const TextEdit = struct {
        start_line: usize,
        start_column: usize,
        end_line: usize,
        end_column: usize,
        new_text: []const u8,
    };
};

pub const RuleConfig = struct {
    enabled: bool = true,
    severity: Severity = .warning,
    auto_fix: bool = true,
};

pub const LinterConfig = struct {
    rules: std.StringHashMap(RuleConfig),
    max_line_length: usize = 100,
    indent_size: usize = 4,
    use_spaces: bool = true,
    trailing_comma: bool = true,
    semicolons: bool = false,
    quote_style: QuoteStyle = .double,

    pub const QuoteStyle = enum {
        single,
        double,
    };

    pub fn init(allocator: std.mem.Allocator) LinterConfig {
        return .{
            .rules = std.StringHashMap(RuleConfig).init(allocator),
        };
    }

    pub fn deinit(self: *LinterConfig) void {
        self.rules.deinit();
    }

    pub fn setRule(self: *LinterConfig, rule_id: []const u8, config: RuleConfig) !void {
        try self.rules.put(rule_id, config);
    }

    pub fn getRule(self: *const LinterConfig, rule_id: []const u8) ?RuleConfig {
        return self.rules.get(rule_id);
    }
};

pub const Linter = struct {
    allocator: std.mem.Allocator,
    config: LinterConfig,
    diagnostics: std.ArrayList(LintDiagnostic),
    source: []const u8,

    pub fn init(allocator: std.mem.Allocator, config: LinterConfig) Linter {
        return .{
            .allocator = allocator,
            .config = config,
            .diagnostics = std.ArrayList(LintDiagnostic){},
            .source = "",
        };
    }

    pub fn deinit(self: *Linter) void {
        for (self.diagnostics.items) |diag| {
            if (diag.fix) |fix| {
                self.allocator.free(fix.edits);
            }
        }
        self.diagnostics.deinit(self.allocator);
    }

    pub fn lint(self: *Linter, source: []const u8) ![]LintDiagnostic {
        self.source = source;
        self.diagnostics.clearRetainingCapacity();

        // Tokenize the source code first
        var lexer = Lexer.init(self.allocator, source);
        var tokens = try lexer.tokenize();
        defer tokens.deinit(self.allocator);

        // Parse the tokens
        var parser = try Parser.init(self.allocator, tokens.items);
        defer parser.deinit();

        const program = parser.parse() catch {
            // If parsing fails, return syntax errors
            return self.diagnostics.items;
        };
        defer program.deinit(self.allocator);

        // Run all enabled rules
        try self.checkNoUnusedVariables(program);
        try self.checkNoConsoleLog(program);
        try self.checkPreferConst(program);
        try self.checkNoVarKeyword(program);
        try self.checkCamelCase(program);
        try self.checkNoTrailingSpaces();
        try self.checkMaxLineLength();
        try self.checkConsistentIndentation();
        try self.checkNoMultipleEmptyLines();
        try self.checkEofNewline();
        try self.checkNoMixedSpacesAndTabs();
        try self.checkQuoteStyle(program);
        try self.checkSemicolons(program);
        try self.checkTrailingComma(program);
        try self.checkNoShadowedVariables(program);
        try self.checkExplicitReturnTypes(program);
        try self.checkNoMagicNumbers(program);
        try self.checkPreferTemplateStrings(program);
        try self.checkNoEmptyBlocks(program);
        try self.checkConsistentBraceStyle(program);
        try self.checkNoUnreachableCode(program);

        return self.diagnostics.items;
    }

    pub fn autoFix(self: *Linter) ![]const u8 {
        var fixed_source = std.ArrayList(u8){};
        defer fixed_source.deinit(self.allocator);

        try fixed_source.appendSlice(self.allocator, self.source);

        // Sort diagnostics by position (reverse order for safe editing)
        const Context = struct {};
        std.mem.sort(LintDiagnostic, self.diagnostics.items, Context{}, struct {
            fn lessThan(_: Context, a: LintDiagnostic, b: LintDiagnostic) bool {
                if (a.line != b.line) return a.line > b.line;
                return a.column > b.column;
            }
        }.lessThan);

        // Apply fixes
        for (self.diagnostics.items) |diag| {
            if (diag.fix) |fix| {
                const rule_config = self.config.getRule(diag.rule_id) orelse continue;
                if (!rule_config.auto_fix) continue;

                for (fix.edits) |edit| {
                    // Apply text edit
                    // This is simplified - a real implementation would need proper offset calculation
                    _ = edit;
                }
            }
        }

        return fixed_source.toOwnedSlice(self.allocator);
    }

    // Rule implementations

    fn checkNoUnusedVariables(self: *Linter, program: *ast.Program) !void {
        const rule_id = "no-unused-vars";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        // Track variable declarations and usages
        // var declared = std.StringHashMap(ast.Node).init(self.allocator);
        // defer declared.deinit();

        // var used = std.StringHashMap(bool).init(self.allocator);
        // defer used.deinit();

        // Simplified implementation - would need full AST traversal
        _ = program;
    }

    fn checkNoConsoleLog(self: *Linter, program: *ast.Program) !void {
        const rule_id = "no-console";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Implementation would traverse AST looking for console.log calls
    }

    fn checkPreferConst(self: *Linter, program: *ast.Program) !void {
        const rule_id = "prefer-const";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check for 'let' declarations that are never reassigned
    }

    fn checkNoVarKeyword(self: *Linter, program: *ast.Program) !void {
        const rule_id = "no-var";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check for 'var' keyword usage
    }

    fn checkCamelCase(self: *Linter, program: *ast.Program) !void {
        const rule_id = "camelcase";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check identifier naming conventions
    }

    fn checkNoTrailingSpaces(self: *Linter) !void {
        const rule_id = "no-trailing-spaces";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        var line_num: usize = 1;
        var line_start: usize = 0;

        for (self.source, 0..) |char, i| {
            if (char == '\n') {
                // Check if previous character is a space or tab
                if (i > 0 and (self.source[i - 1] == ' ' or self.source[i - 1] == '\t')) {
                    var end = i - 1;
                    while (end > line_start and (self.source[end] == ' ' or self.source[end] == '\t')) {
                        end -= 1;
                    }

                    const fix = LintDiagnostic.Fix{
                        .message = "Remove trailing whitespace",
                        .edits = try self.allocator.alloc(LintDiagnostic.TextEdit, 1),
                    };
                    fix.edits[0] = .{
                        .start_line = line_num,
                        .start_column = end + 1,
                        .end_line = line_num,
                        .end_column = i,
                        .new_text = "",
                    };

                    try self.diagnostics.append(self.allocator, .{
                        .rule_id = rule_id,
                        .severity = config.severity,
                        .message = "Trailing whitespace detected",
                        .line = line_num,
                        .column = end + 1,
                        .end_line = line_num,
                        .end_column = i,
                        .fix = fix,
                    });
                }

                line_num += 1;
                line_start = i + 1;
            }
        }
    }

    fn checkMaxLineLength(self: *Linter) !void {
        const rule_id = "max-line-length";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        var line_num: usize = 1;
        var line_start: usize = 0;

        for (self.source, 0..) |char, i| {
            if (char == '\n') {
                const line_length = i - line_start;
                if (line_length > self.config.max_line_length) {
                    try self.diagnostics.append(self.allocator, .{
                        .rule_id = rule_id,
                        .severity = config.severity,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Line exceeds maximum length of {d} characters (current: {d})",
                            .{ self.config.max_line_length, line_length },
                        ),
                        .line = line_num,
                        .column = 1,
                        .end_line = line_num,
                        .end_column = line_length,
                    });
                }
                line_num += 1;
                line_start = i + 1;
            }
        }
    }

    fn checkConsistentIndentation(self: *Linter) !void {
        const rule_id = "indent";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        var line_num: usize = 1;
        var line_start: usize = 0;

        for (self.source, 0..) |char, i| {
            if (char == '\n') {
                line_num += 1;
                line_start = i + 1;
            } else if (i == line_start) {
                // Check indentation at start of line
                var indent_spaces: usize = 0;
                var indent_tabs: usize = 0;
                var j = i;

                while (j < self.source.len and (self.source[j] == ' ' or self.source[j] == '\t')) : (j += 1) {
                    if (self.source[j] == ' ') {
                        indent_spaces += 1;
                    } else {
                        indent_tabs += 1;
                    }
                }

                if (self.config.use_spaces and indent_tabs > 0) {
                    const fix = LintDiagnostic.Fix{
                        .message = "Replace tabs with spaces",
                        .edits = try self.allocator.alloc(LintDiagnostic.TextEdit, 1),
                    };
                    const spaces = try self.allocator.alloc(u8, indent_tabs * self.config.indent_size);
                    @memset(spaces, ' ');

                    fix.edits[0] = .{
                        .start_line = line_num,
                        .start_column = 1,
                        .end_line = line_num,
                        .end_column = indent_tabs + 1,
                        .new_text = spaces,
                    };

                    try self.diagnostics.append(self.allocator, .{
                        .rule_id = rule_id,
                        .severity = config.severity,
                        .message = "Expected spaces for indentation",
                        .line = line_num,
                        .column = 1,
                        .end_line = line_num,
                        .end_column = indent_tabs + 1,
                        .fix = fix,
                    });
                }
            }
        }
    }

    fn checkNoMultipleEmptyLines(self: *Linter) !void {
        const rule_id = "no-multiple-empty-lines";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        var line_num: usize = 1;
        var empty_lines: usize = 0;
        var line_start: usize = 0;

        for (self.source, 0..) |char, i| {
            if (char == '\n') {
                const line_length = i - line_start;
                if (line_length == 0) {
                    empty_lines += 1;
                    if (empty_lines > 1) {
                        try self.diagnostics.append(self.allocator, .{
                            .rule_id = rule_id,
                            .severity = config.severity,
                            .message = "Multiple consecutive empty lines",
                            .line = line_num,
                            .column = 1,
                            .end_line = line_num,
                            .end_column = 1,
                        });
                    }
                } else {
                    empty_lines = 0;
                }
                line_num += 1;
                line_start = i + 1;
            }
        }
    }

    fn checkEofNewline(self: *Linter) !void {
        const rule_id = "eol-last";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        if (self.source.len > 0 and self.source[self.source.len - 1] != '\n') {
            const fix = LintDiagnostic.Fix{
                .message = "Add newline at end of file",
                .edits = try self.allocator.alloc(LintDiagnostic.TextEdit, 1),
            };
            fix.edits[0] = .{
                .start_line = 0,
                .start_column = self.source.len,
                .end_line = 0,
                .end_column = self.source.len,
                .new_text = "\n",
            };

            try self.diagnostics.append(self.allocator, .{
                .rule_id = rule_id,
                .severity = config.severity,
                .message = "Missing newline at end of file",
                .line = 0,
                .column = self.source.len,
                .end_line = 0,
                .end_column = self.source.len,
                .fix = fix,
            });
        }
    }

    fn checkNoMixedSpacesAndTabs(self: *Linter) !void {
        const rule_id = "no-mixed-spaces-and-tabs";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        var line_num: usize = 1;
        var line_start: usize = 0;

        for (self.source, 0..) |char, i| {
            if (char == '\n') {
                line_num += 1;
                line_start = i + 1;
            } else if (i == line_start) {
                var has_spaces = false;
                var has_tabs = false;
                var j = i;

                while (j < self.source.len and (self.source[j] == ' ' or self.source[j] == '\t')) : (j += 1) {
                    if (self.source[j] == ' ') has_spaces = true;
                    if (self.source[j] == '\t') has_tabs = true;
                }

                if (has_spaces and has_tabs) {
                    try self.diagnostics.append(self.allocator, .{
                        .rule_id = rule_id,
                        .severity = config.severity,
                        .message = "Mixed spaces and tabs in indentation",
                        .line = line_num,
                        .column = 1,
                        .end_line = line_num,
                        .end_column = j - line_start + 1,
                    });
                }
            }
        }
    }

    fn checkQuoteStyle(self: *Linter, program: *ast.Program) !void {
        const rule_id = "quotes";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check string literal quote style
    }

    fn checkSemicolons(self: *Linter, program: *ast.Program) !void {
        const rule_id = "semi";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;

        // Tokenize source to check semicolon usage
        var lex = @import("lexer").Lexer.init(self.allocator, self.source);

        var tokens = lex.tokenize() catch return;
        defer tokens.deinit(self.allocator);

        // Check for unnecessary/missing semicolons based on style
        const style: @import("rules/semicolon_style.zig").SemicolonStyle.Config.Style =
            if (self.config.semicolons) .always else .optional;

        var rule = @import("rules/semicolon_style.zig").SemicolonStyle.init(.{
            .style = style,
        });

        const errors = rule.check(self.allocator, tokens.items) catch return;
        defer {
            for (errors) |*err| {
                err.deinit(self.allocator);
            }
            self.allocator.free(errors);
        }

        // Convert semicolon errors to linter diagnostics
        for (errors) |err| {
            try self.diagnostics.append(self.allocator, .{
                .rule_id = rule_id,
                .severity = switch (err.severity) {
                    .Error => .error_,
                    .Warning => .warning,
                    .Info => .info,
                },
                .message = try self.allocator.dupe(u8, err.message),
                .line = err.line,
                .column = err.column,
                .end_line = err.line,
                .end_column = err.column + 1,
                .fix = null,
            });
        }
    }

    fn checkTrailingComma(self: *Linter, program: *ast.Program) !void {
        const rule_id = "comma-dangle";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check trailing commas in arrays/objects
    }

    fn checkNoShadowedVariables(self: *Linter, program: *ast.Program) !void {
        const rule_id = "no-shadow";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check for variable shadowing
    }

    fn checkExplicitReturnTypes(self: *Linter, program: *ast.Program) !void {
        const rule_id = "explicit-function-return-type";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check that functions have explicit return types
    }

    fn checkNoMagicNumbers(self: *Linter, program: *ast.Program) !void {
        const rule_id = "no-magic-numbers";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check for magic numbers (should be constants)
    }

    fn checkPreferTemplateStrings(self: *Linter, program: *ast.Program) !void {
        const rule_id = "prefer-template";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check for string concatenation that should use templates
    }

    fn checkNoEmptyBlocks(self: *Linter, program: *ast.Program) !void {
        const rule_id = "no-empty";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check for empty blocks
    }

    fn checkConsistentBraceStyle(self: *Linter, program: *ast.Program) !void {
        const rule_id = "brace-style";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check brace placement consistency
    }

    fn checkNoUnreachableCode(self: *Linter, program: *ast.Program) !void {
        const rule_id = "no-unreachable";
        const config = self.config.getRule(rule_id) orelse return;
        if (!config.enabled) return;

        _ = program;
        // Check for unreachable code after return/throw
    }
};

pub fn createDefaultConfig(allocator: std.mem.Allocator) !LinterConfig {
    var config = LinterConfig.init(allocator);

    // Enable all rules by default with auto-fix
    try config.setRule("no-unused-vars", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("no-console", .{ .enabled = false, .severity = .warning, .auto_fix = false });
    try config.setRule("prefer-const", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("no-var", .{ .enabled = true, .severity = .error_, .auto_fix = true });
    try config.setRule("camelcase", .{ .enabled = true, .severity = .warning, .auto_fix = false });
    try config.setRule("no-trailing-spaces", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("max-line-length", .{ .enabled = true, .severity = .warning, .auto_fix = false });
    try config.setRule("indent", .{ .enabled = true, .severity = .error_, .auto_fix = true });
    try config.setRule("no-multiple-empty-lines", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("eol-last", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("no-mixed-spaces-and-tabs", .{ .enabled = true, .severity = .error_, .auto_fix = true });
    try config.setRule("quotes", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("semi", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("comma-dangle", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("no-shadow", .{ .enabled = true, .severity = .warning, .auto_fix = false });
    try config.setRule("explicit-function-return-type", .{ .enabled = true, .severity = .warning, .auto_fix = false });
    try config.setRule("no-magic-numbers", .{ .enabled = false, .severity = .warning, .auto_fix = false });
    try config.setRule("prefer-template", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("no-empty", .{ .enabled = true, .severity = .warning, .auto_fix = false });
    try config.setRule("brace-style", .{ .enabled = true, .severity = .warning, .auto_fix = true });
    try config.setRule("no-unreachable", .{ .enabled = true, .severity = .error_, .auto_fix = false });

    return config;
}
