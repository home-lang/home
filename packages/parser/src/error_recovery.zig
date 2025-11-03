const std = @import("std");
const Token = @import("lexer").Token;
const TokenType = @import("lexer").TokenType;
const ast = @import("ast");

/// Error recovery strategies for the parser
///
/// When the parser encounters an error, it uses various recovery strategies
/// to continue parsing and find additional errors in the source code.
/// This provides a better developer experience by reporting multiple errors
/// at once instead of stopping at the first error.
pub const ErrorRecovery = struct {
    /// Recovery mode determines how aggressively the parser tries to recover
    pub const RecoveryMode = enum {
        /// Minimal recovery - stop at first error in statement
        Minimal,
        /// Moderate recovery - skip to next statement boundary
        Moderate,
        /// Aggressive recovery - try to recover within expressions
        Aggressive,
    };

    /// Synchronization points where the parser can safely resume
    pub const SyncPoint = enum {
        Statement,
        Expression,
        Declaration,
        Block,
        Function,
        Struct,
        Enum,
    };

    mode: RecoveryMode,
    errors_recovered: usize,
    max_errors: usize,

    pub fn init(mode: RecoveryMode, max_errors: usize) ErrorRecovery {
        return .{
            .mode = mode,
            .errors_recovered = 0,
            .max_errors = max_errors,
        };
    }

    /// Check if we should continue trying to recover
    pub fn shouldContinue(self: *ErrorRecovery) bool {
        return self.errors_recovered < self.max_errors;
    }

    /// Record that an error was recovered
    pub fn recordRecovery(self: *ErrorRecovery) void {
        self.errors_recovered += 1;
    }

    /// Synchronize to the next statement boundary
    ///
    /// Skips tokens until we find a statement-starting token or semicolon
    pub fn synchronizeToStatement(self: *ErrorRecovery, tokens: []const Token, current: *usize) void {
        _ = self;

        while (current.* < tokens.len) {
            const token = tokens[current.*];

            // Statement boundaries
            switch (token.type) {
                .Semicolon => {
                    current.* += 1; // Skip the semicolon
                    return;
                },
                // Statement-starting keywords
                .Let, .Const, .Fn, .If, .While, .For, .Return, .Struct, .Enum, .Impl, .Trait => {
                    return; // Don't skip, let the parser handle it
                },
                .RightBrace => {
                    // End of block, don't skip
                    return;
                },
                .Eof => {
                    return;
                },
                else => {
                    current.* += 1; // Skip this token
                },
            }
        }
    }

    /// Synchronize to the next expression boundary
    pub fn synchronizeToExpression(self: *ErrorRecovery, tokens: []const Token, current: *usize) void {
        _ = self;

        while (current.* < tokens.len) {
            const token = tokens[current.*];

            switch (token.type) {
                // Expression separators
                .Comma, .Semicolon, .RightParen, .RightBrace, .RightBracket => {
                    return; // Don't skip, let parser handle it
                },
                // Binary operators - potential expression continuation
                .Plus, .Minus, .Star, .Slash => {
                    return;
                },
                .Eof => {
                    return;
                },
                else => {
                    current.* += 1;
                },
            }
        }
    }

    /// Synchronize to the next declaration boundary
    pub fn synchronizeToDeclaration(self: *ErrorRecovery, tokens: []const Token, current: *usize) void {
        _ = self;

        while (current.* < tokens.len) {
            const token = tokens[current.*];

            switch (token.type) {
                // Declaration keywords
                .Fn, .Struct, .Enum, .Impl, .Trait, .Let, .Const => {
                    return;
                },
                .Eof => {
                    return;
                },
                else => {
                    current.* += 1;
                },
            }
        }
    }

    /// Synchronize to the end of a block
    pub fn synchronizeToBlockEnd(self: *ErrorRecovery, tokens: []const Token, current: *usize) void {
        _ = self;
        var brace_depth: usize = 1; // We're already inside one block

        while (current.* < tokens.len) {
            const token = tokens[current.*];

            switch (token.type) {
                .LeftBrace => {
                    brace_depth += 1;
                    current.* += 1;
                },
                .RightBrace => {
                    brace_depth -= 1;
                    if (brace_depth == 0) {
                        current.* += 1; // Skip the closing brace
                        return;
                    }
                    current.* += 1;
                },
                .Eof => {
                    return;
                },
                else => {
                    current.* += 1;
                },
            }
        }
    }

    /// Try to recover from a missing token by inserting a placeholder
    pub fn recoverMissingToken(
        self: *ErrorRecovery,
        expected: TokenType,
        current: *usize,
    ) ?Token {
        _ = current;

        if (!self.shouldContinue()) return null;

        // Create a synthetic token for the missing element
        const synthetic_token = Token{
            .type = expected,
            .lexeme = "", // Empty lexeme for synthetic token
            .line = 0,
            .column = 0,
        };

        self.recordRecovery();
        return synthetic_token;
    }

    /// Skip tokens until we find a matching closing delimiter
    pub fn skipToMatchingDelimiter(
        self: *ErrorRecovery,
        tokens: []const Token,
        current: *usize,
        opening: TokenType,
        closing: TokenType,
    ) void {
        _ = self;
        var depth: usize = 1;

        while (current.* < tokens.len) {
            const token = tokens[current.*];

            if (token.type == opening) {
                depth += 1;
            } else if (token.type == closing) {
                depth -= 1;
                if (depth == 0) {
                    current.* += 1; // Skip the closing delimiter
                    return;
                }
            } else if (token.type == .Eof) {
                return;
            }

            current.* += 1;
        }
    }
};

/// Panic mode recovery - skip to synchronization point
pub fn panicModeRecover(tokens: []const Token, current: *usize, sync_point: ErrorRecovery.SyncPoint) void {
    var recovery = ErrorRecovery.init(.Moderate, 100);

    switch (sync_point) {
        .Statement => recovery.synchronizeToStatement(tokens, current),
        .Expression => recovery.synchronizeToExpression(tokens, current),
        .Declaration => recovery.synchronizeToDeclaration(tokens, current),
        .Block => recovery.synchronizeToBlockEnd(tokens, current),
        .Function => recovery.synchronizeToDeclaration(tokens, current),
        .Struct => recovery.synchronizeToDeclaration(tokens, current),
        .Enum => recovery.synchronizeToDeclaration(tokens, current),
    }
}

/// Phrase-level recovery - try to fix common mistakes
pub const PhraseRecovery = struct {
    /// Common token substitutions
    pub const Substitution = struct {
        wrong: TokenType,
        correct: TokenType,
        message: []const u8,
    };

    /// Common typos and their corrections
    pub const common_substitutions = [_]Substitution{
        .{ .wrong = .Equal, .correct = .EqualEqual, .message = "use '==' for comparison, '=' is for assignment" },
        .{ .wrong = .Identifier, .correct = .Let, .message = "did you mean 'let'?" },
    };

    /// Try to find a substitution for a wrong token
    pub fn findSubstitution(wrong: TokenType) ?Substitution {
        for (common_substitutions) |sub| {
            if (sub.wrong == wrong) {
                return sub;
            }
        }
        return null;
    }
};

/// Error suggestions based on context
pub const ErrorSuggestions = struct {
    /// Suggest similar variable names using Levenshtein distance
    pub fn suggestSimilarName(
        allocator: std.mem.Allocator,
        typo: []const u8,
        available: []const []const u8,
    ) ?[]const u8 {
        var best_match: ?[]const u8 = null;
        var best_distance: usize = std.math.maxInt(usize);

        for (available) |name| {
            const distance = levenshteinDistance(typo, name);
            // Only suggest if distance is small (typo is close)
            if (distance < best_distance and distance <= 3) {
                best_distance = distance;
                best_match = name;
            }
        }

        if (best_match) |match| {
            return allocator.dupe(u8, match) catch null;
        }

        return null;
    }

    /// Calculate Levenshtein distance between two strings
    fn levenshteinDistance(s1: []const u8, s2: []const u8) usize {
        const len1 = s1.len;
        const len2 = s2.len;

        if (len1 == 0) return len2;
        if (len2 == 0) return len1;

        // Use stack allocation for small strings
        var matrix: [100][100]usize = undefined;

        if (len1 >= 100 or len2 >= 100) {
            // Fallback for very long strings
            return @max(len1, len2);
        }

        // Initialize first row and column
        for (0..len1 + 1) |i| {
            matrix[i][0] = i;
        }
        for (0..len2 + 1) |j| {
            matrix[0][j] = j;
        }

        // Fill the matrix
        for (1..len1 + 1) |i| {
            for (1..len2 + 1) |j| {
                const cost: usize = if (s1[i - 1] == s2[j - 1]) 0 else 1;

                matrix[i][j] = @min(
                    @min(
                        matrix[i - 1][j] + 1, // deletion
                        matrix[i][j - 1] + 1, // insertion
                    ),
                    matrix[i - 1][j - 1] + cost, // substitution
                );
            }
        }

        return matrix[len1][len2];
    }

    /// Suggest correct keyword based on partial input
    pub fn suggestKeyword(partial: []const u8) ?[]const u8 {
        const keywords = [_][]const u8{
            "let",     "const",  "fn",      "if",     "else",
            "while",   "for",    "return",  "struct", "enum",
            "impl",    "trait",  "match",   "true",   "false",
            "import",  "pub",    "mut",     "async",  "await",
            "break",   "continue", "defer", "do",     "in",
        };

        for (keywords) |keyword| {
            if (std.mem.startsWith(u8, keyword, partial)) {
                return keyword;
            }
        }

        return null;
    }

    /// Suggest closing delimiter
    pub fn suggestClosingDelimiter(opening: TokenType) ?TokenType {
        return switch (opening) {
            .LeftParen => .RightParen,
            .LeftBrace => .RightBrace,
            .LeftBracket => .RightBracket,
            else => null,
        };
    }
};

/// Minimum distance edit for fixing syntax errors
pub const MinimalEdit = struct {
    pub const Edit = union(enum) {
        Insert: Token,
        Delete: usize, // Index of token to delete
        Replace: struct { index: usize, new_token: Token },
    };

    /// Suggest minimal edit to fix syntax error
    pub fn suggestEdit(
        tokens: []const Token,
        error_index: usize,
        expected: ?TokenType,
    ) ?Edit {
        if (error_index >= tokens.len) return null;

        const error_token = tokens[error_index];

        // Try insertion if we expected something specific
        if (expected) |exp| {
            // Check if the next token is what we expected
            if (error_index + 1 < tokens.len and tokens[error_index + 1].type == exp) {
                // The expected token is coming next, just insert it
                return Edit{
                    .Insert = Token{
                        .type = exp,
                        .lexeme = "",
                        .line = error_token.line,
                        .column = error_token.column,
                    },
                };
            }

            // Try replacement
            return Edit{
                .Replace = .{
                    .index = error_index,
                    .new_token = Token{
                        .type = exp,
                        .lexeme = "",
                        .line = error_token.line,
                        .column = error_token.column,
                    },
                },
            };
        }

        // Try deletion if token seems out of place
        if (isLikelyExtraneous(error_token.type)) {
            return Edit{ .Delete = error_index };
        }

        return null;
    }

    fn isLikelyExtraneous(token_type: TokenType) bool {
        return switch (token_type) {
            .Comma, .Semicolon => true, // Extra punctuation
            else => false,
        };
    }
};
