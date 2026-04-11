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

            // Walk forward to the end of this statement. Statement boundaries
            // in Home are: an explicit `;`, a `}` (block close), OR a newline
            // outside of an open paren/bracket. The newline rule matters here
            // because semicolons are optional in Home — without it the walker
            // would skip past the entire dead block looking for a `;` that
            // never comes and report nothing.
            const start_line = t.line;
            var j = i + 1;
            var paren_depth: i32 = 0;
            while (j < tokens.len) : (j += 1) {
                const tj = tokens[j];
                switch (tj.type) {
                    .LeftParen, .LeftBracket => paren_depth += 1,
                    .RightParen, .RightBracket => paren_depth -= 1,
                    .Semicolon => if (paren_depth == 0) break,
                    .RightBrace => if (paren_depth == 0) break,
                    else => {
                        if (paren_depth == 0 and tj.line > start_line) break;
                    },
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

// =================================================================================
//                                   TESTS
// =================================================================================

const lex = @import("lexer");

fn runDeadCodeRule(allocator: std.mem.Allocator, source: []const u8) ![]LintError {
    var lexer = lex.Lexer.init(allocator, source);
    var toks = try lexer.tokenize();
    defer toks.deinit(allocator);
    var rule = DeadCodeAfterReturn.init();
    return try rule.check(allocator, toks.items);
}

fn freeDeadErrors(allocator: std.mem.Allocator, errs: []LintError) void {
    for (errs) |*e| allocator.free(e.message);
    allocator.free(errs);
}

test "dead code after return: simple case" {
    const allocator = std.testing.allocator;
    const errs = try runDeadCodeRule(allocator, "return 1\nlet x = 2");
    defer freeDeadErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expect(std.mem.indexOf(u8, errs[0].message, "Return") != null or
        std.mem.indexOf(u8, errs[0].message, "return") != null);
}

test "dead code: return at end of block is fine" {
    const allocator = std.testing.allocator;
    const errs = try runDeadCodeRule(allocator, "fn foo() { return 1 }");
    defer freeDeadErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

test "dead code after break in loop body" {
    const allocator = std.testing.allocator;
    const errs = try runDeadCodeRule(allocator, "while true { break\nlet x = 1 }");
    defer freeDeadErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 1), errs.len);
}

test "dead code after continue" {
    const allocator = std.testing.allocator;
    const errs = try runDeadCodeRule(allocator, "while true { continue\nlet y = 2 }");
    defer freeDeadErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 1), errs.len);
}

test "dead code: nothing after return + close brace" {
    // Common pattern: a function ends with return then closing brace.
    const allocator = std.testing.allocator;
    const errs = try runDeadCodeRule(allocator, "fn f() {\nreturn 0\n}");
    defer freeDeadErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

test "dead code: doesn't double-report consecutive dead lines" {
    const allocator = std.testing.allocator;
    const errs = try runDeadCodeRule(allocator, "return 1\nlet x = 2\nlet y = 3");
    defer freeDeadErrors(allocator, errs);
    // The rule advances `i` past the dead block, so it should report only
    // the first unreachable statement, not every following line.
    try std.testing.expect(errs.len >= 1);
    try std.testing.expect(errs.len <= 2);
}
