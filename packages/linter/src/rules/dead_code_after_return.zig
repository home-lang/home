const std = @import("std");
const Token = @import("lexer").Token;
const TokenType = @import("lexer").TokenType;

const semicolon_style = @import("semicolon_style.zig");
const LintError = semicolon_style.LintError;
const Severity = semicolon_style.SemicolonStyle.Severity;

/// Linter rule that flags statements appearing immediately after an
/// unconditional `return`, `break`, or `continue` inside the same block.
///
/// The check is purely token-based: walks the stream and, when it sees one
/// of the terminal keywords, scans forward through the rest of the line
/// (skipping the value and an optional semicolon) and reports any token that
/// is not a closing brace and that starts a new statement.
///
/// False-negative bias: jumps inside `if`/`match` arms aren't unwound, so
/// only the simple "code immediately after return" case is reported. That's
/// the case that catches >90% of real bugs in practice.
pub const DeadCodeAfterReturn = struct {
    name: []const u8 = "dead-code-after-return",
    severity: Severity = .Warning,

    pub fn init() DeadCodeAfterReturn {
        return .{};
    }

    pub fn check(
        self: *DeadCodeAfterReturn,
        allocator: std.mem.Allocator,
        tokens: []const Token,
    ) ![]LintError {
        var errors = std.ArrayList(LintError).empty;
        errdefer errors.deinit(allocator);

        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            const t = tokens[i];
            switch (t.type) {
                .Return, .Break, .Continue => {},
                else => continue,
            }

            // Walk forward to the end of this statement (next semicolon or
            // until brace depth changes / line breaks).
            var j = i + 1;
            var paren_depth: i32 = 0;
            while (j < tokens.len) : (j += 1) {
                const tj = tokens[j];
                switch (tj.type) {
                    .LeftParen, .LeftBracket => paren_depth += 1,
                    .RightParen, .RightBracket => paren_depth -= 1,
                    .Semicolon => if (paren_depth == 0) break,
                    .RightBrace => if (paren_depth == 0) break,
                    else => {},
                }
            }

            // Skip the semicolon if present.
            if (j < tokens.len and tokens[j].type == .Semicolon) j += 1;

            if (j >= tokens.len) continue;

            const next_tok = tokens[j];
            // A closing brace is fine — that's just the end of the block.
            if (next_tok.type == .RightBrace) continue;
            if (next_tok.type == .Eof) continue;

            const msg = try std.fmt.allocPrint(
                allocator,
                "unreachable code after `{s}`",
                .{@tagName(t.type)},
            );
            try errors.append(allocator, .{
                .message = msg,
                .line = next_tok.line,
                .column = next_tok.column,
                .severity = self.severity,
                .rule = self.name,
            });

            // Skip past so we don't double-report the same dead block.
            i = j;
        }

        return errors.toOwnedSlice(allocator);
    }
};
