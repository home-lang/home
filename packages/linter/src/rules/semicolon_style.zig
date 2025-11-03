const std = @import("std");
const Token = @import("lexer").Token;
const TokenType = @import("lexer").TokenType;

/// Linter rule for enforcing semicolon style consistency.
///
/// Supports three styles:
/// - optional: Semicolons can be used or omitted (default)
/// - always: Semicolons must always be present
/// - never: Semicolons should not be used except where required
pub const SemicolonStyle = struct {
    name: []const u8 = "semicolon-style",
    severity: Severity = .Warning,
    config: Config,

    pub const Severity = enum {
        Error,
        Warning,
        Info,
    };

    pub const Config = struct {
        pub const Style = enum {
            /// Semicolons are optional
            optional,
            /// Semicolons must always be used
            always,
            /// Semicolons should never be used (except where required)
            never,

            pub fn fromString(s: []const u8) ?Style {
                if (std.mem.eql(u8, s, "optional")) return .optional;
                if (std.mem.eql(u8, s, "always")) return .always;
                if (std.mem.eql(u8, s, "never")) return .never;
                return null;
            }
        };

        /// Style for semicolon usage
        style: Style = .optional,
        /// Whether to allow multiple statements on one line with semicolons
        allow_single_line_multiple: bool = true,
    };

    pub fn init(config: Config) SemicolonStyle {
        return .{ .config = config };
    }

    /// Check tokens for semicolon style violations.
    ///
    /// Returns a list of lint errors found in the token stream.
    pub fn check(
        self: *SemicolonStyle,
        allocator: std.mem.Allocator,
        tokens: []const Token,
    ) ![]LintError {
        var errors = std.ArrayList(LintError).init(allocator);
        errdefer errors.deinit();

        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];

            // Check for unnecessary semicolons (never style)
            if (token.type == .Semicolon and self.config.style == .never) {
                const is_required = self.isSemicolonRequired(tokens, i);
                if (!is_required) {
                    try errors.append(.{
                        .message = try allocator.dupe(u8, "Unnecessary semicolon (style: never)"),
                        .line = token.line,
                        .column = token.column,
                        .severity = self.severity,
                        .rule = self.name,
                        .fix = .{ .remove_semicolon = .{ .position = i } },
                    });
                }
            }

            // Check for missing semicolons (always style)
            if (self.config.style == .always) {
                if (self.isStatementEnd(tokens, i) and !self.hasTrailingSemicolon(tokens, i)) {
                    // Check if next token is on same line
                    if (i + 1 < tokens.len) {
                        const next = tokens[i + 1];
                        if (token.line == next.line and self.isStatementStart(next)) {
                            try errors.append(.{
                                .message = try allocator.dupe(u8, "Missing semicolon (style: always)"),
                                .line = token.line,
                                .column = token.column + token.lexeme.len,
                                .severity = self.severity,
                                .rule = self.name,
                                .fix = .{ .add_semicolon = .{ .position = i + 1 } },
                            });
                        }
                    }
                }
            }

            // Check for required semicolons (all styles)
            if (self.isSemicolonRequired(tokens, i)) {
                if (token.type != .Semicolon and i + 1 < tokens.len) {
                    const next = tokens[i + 1];
                    if (token.line == next.line and self.isStatementStart(next)) {
                        try errors.append(.{
                            .message = try allocator.dupe(u8, "Semicolon required (multiple statements on same line)"),
                            .line = token.line,
                            .column = token.column + token.lexeme.len,
                            .severity = .Error,
                            .rule = self.name,
                            .fix = .{ .add_semicolon = .{ .position = i + 1 } },
                        });
                    }
                }
            }
        }

        return errors.toOwnedSlice();
    }

    /// Check if a semicolon is required at the given position.
    ///
    /// Semicolons are required when multiple statements appear on the same line.
    fn isSemicolonRequired(self: *SemicolonStyle, tokens: []const Token, index: usize) bool {
        if (index == 0 or index >= tokens.len) return false;

        if (!self.config.allow_single_line_multiple) return false;

        const current = tokens[index];

        // Check if this looks like a statement end
        if (!self.isStatementEnd(tokens, index)) return false;

        // Check if next token is on same line and starts a statement
        if (index + 1 < tokens.len) {
            const next = tokens[index + 1];
            if (current.line == next.line and self.isStatementStart(next)) {
                return true;
            }
        }

        return false;
    }

    /// Check if the token at the given position could end a statement.
    fn isStatementEnd(self: *SemicolonStyle, tokens: []const Token, index: usize) bool {
        _ = self;
        if (index >= tokens.len) return false;

        const token = tokens[index];
        return switch (token.type) {
            .Identifier,
            .Integer,
            .Float,
            .String,
            .True,
            .False,
            .RightParen,
            .RightBracket,
            .RightBrace,
            => true,
            else => false,
        };
    }

    /// Check if the token starts a statement.
    fn isStatementStart(self: *SemicolonStyle, token: Token) bool {
        _ = self;
        return switch (token.type) {
            .Let,
            .Const,
            .Fn,
            .If,
            .While,
            .For,
            .Loop,
            .Return,
            .Break,
            .Continue,
            .Match,
            .Switch,
            .Try,
            .Defer,
            .Identifier,
            => true,
            else => false,
        };
    }

    /// Check if there's a semicolon after the given position.
    fn hasTrailingSemicolon(self: *SemicolonStyle, tokens: []const Token, index: usize) bool {
        _ = self;
        if (index + 1 >= tokens.len) return false;
        return tokens[index + 1].type == .Semicolon;
    }
};

/// Represents a lint error with location and fix information.
pub const LintError = struct {
    message: []const u8,
    line: usize,
    column: usize,
    severity: SemicolonStyle.Severity,
    rule: []const u8,
    fix: ?Fix = null,

    pub const Fix = union(enum) {
        add_semicolon: struct { position: usize },
        remove_semicolon: struct { position: usize },
    };

    pub fn deinit(self: *LintError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};
