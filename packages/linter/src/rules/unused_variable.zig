const std = @import("std");
const Token = @import("lexer").Token;
const TokenType = @import("lexer").TokenType;

const semicolon_style = @import("semicolon_style.zig");
const LintError = semicolon_style.LintError;
const Severity = semicolon_style.SemicolonStyle.Severity;

/// Linter rule that flags variable declarations whose binding is never read.
///
/// Operates on the token stream rather than the AST: walks `let`/`const`
/// declarations, records the binding name, and then scans the rest of the
/// token stream for any non-declaration use of that name. If no use is found
/// the binding is reported.
///
/// Limitations of the token-based approach (intentional, for simplicity):
///   - Shadowed names in nested scopes count as a use of the outer binding.
///   - Names that only appear in macro arguments still count as used.
///
/// Both limitations bias toward false negatives, never false positives —
/// which is the right tradeoff for a stylistic rule.
pub const UnusedVariable = struct {
    name: []const u8 = "unused-variable",
    severity: Severity = .Warning,
    config: Config = .{},

    pub const Config = struct {
        /// If true, names beginning with `_` are considered intentionally unused.
        allow_underscore_prefix: bool = true,
    };

    pub fn init(config: Config) UnusedVariable {
        return .{ .config = config };
    }

    pub fn check(
        self: *UnusedVariable,
        allocator: std.mem.Allocator,
        tokens: []const Token,
    ) ![]LintError {
        var errors = std.ArrayList(LintError).empty;
        errdefer errors.deinit(allocator);

        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            const tok = tokens[i];
            // Look for `let` / `const` followed (optionally by `mut`) by an identifier.
            if (tok.type != .Let and tok.type != .Const) continue;

            var name_idx = i + 1;
            if (name_idx < tokens.len and tokens[name_idx].type == .Mut) name_idx += 1;
            if (name_idx >= tokens.len) break;
            if (tokens[name_idx].type != .Identifier) continue;

            const name_tok = tokens[name_idx];
            const name = name_tok.lexeme;

            // Skip explicit-unused convention.
            if (self.config.allow_underscore_prefix and name.len > 0 and name[0] == '_') {
                continue;
            }

            // Scan the rest of the token stream for any use of `name` as an
            // identifier that isn't itself the LHS of a new binding.
            var used = false;
            var j: usize = name_idx + 1;
            while (j < tokens.len) : (j += 1) {
                const t = tokens[j];
                if (t.type != .Identifier) continue;
                if (!std.mem.eql(u8, t.lexeme, name)) continue;

                // Don't count `let name = ...` as a use of an outer `name`.
                // (Shadowing is not perfect; see doc-comment.)
                if (j >= 1) {
                    const prev = tokens[j - 1].type;
                    if (prev == .Let or prev == .Const) continue;
                    if (prev == .Mut and j >= 2) {
                        const prev2 = tokens[j - 2].type;
                        if (prev2 == .Let or prev2 == .Const) continue;
                    }
                }
                used = true;
                break;
            }

            if (!used) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "unused variable `{s}` (prefix with `_` to silence)",
                    .{name},
                );
                try errors.append(allocator, .{
                    .message = msg,
                    .line = name_tok.line,
                    .column = name_tok.column,
                    .severity = self.severity,
                    .rule = self.name,
                });
            }
        }

        return errors.toOwnedSlice(allocator);
    }
};

test "unused variable detected" {
    const lex = @import("lexer");
    const allocator = std.testing.allocator;
    var lexer = lex.Lexer.init(allocator, "let foo = 1\nlet bar = 2\nbar");
    var toks = try lexer.tokenize();
    defer toks.deinit(allocator);

    var rule = UnusedVariable.init(.{});
    const errs = try rule.check(allocator, toks.items);
    defer {
        for (errs) |*e| allocator.free(e.message);
        allocator.free(errs);
    }

    try std.testing.expectEqual(@as(usize, 1), errs.len);
}
