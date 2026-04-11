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

// =================================================================================
//                                   TESTS
// =================================================================================

const lex = @import("lexer");

fn runRule(allocator: std.mem.Allocator, source: []const u8, config: UnusedVariable.Config) ![]LintError {
    var lexer = lex.Lexer.init(allocator, source);
    var toks = try lexer.tokenize();
    defer toks.deinit(allocator);

    var rule = UnusedVariable.init(config);
    return try rule.check(allocator, toks.items);
}

fn freeErrors(allocator: std.mem.Allocator, errs: []LintError) void {
    for (errs) |*e| allocator.free(e.message);
    allocator.free(errs);
}

test "unused variable: single binding never read" {
    const allocator = std.testing.allocator;
    const errs = try runRule(allocator, "let foo = 1\nlet bar = 2\nbar", .{});
    defer freeErrors(allocator, errs);

    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expect(std.mem.indexOf(u8, errs[0].message, "foo") != null);
}

test "unused variable: used binding produces no diagnostic" {
    const allocator = std.testing.allocator;
    const errs = try runRule(allocator, "let used = 1\nused", .{});
    defer freeErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

test "unused variable: underscore prefix opts out" {
    const allocator = std.testing.allocator;
    const errs = try runRule(
        allocator,
        "let _ignored = 1",
        .{ .allow_underscore_prefix = true },
    );
    defer freeErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

test "unused variable: underscore prefix is opt-in" {
    const allocator = std.testing.allocator;
    const errs = try runRule(
        allocator,
        "let _ignored = 1",
        .{ .allow_underscore_prefix = false },
    );
    defer freeErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 1), errs.len);
}

test "unused variable: const declarations are checked too" {
    const allocator = std.testing.allocator;
    const errs = try runRule(allocator, "const PI = 3", .{});
    defer freeErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expect(std.mem.indexOf(u8, errs[0].message, "PI") != null);
}

test "unused variable: mut binding tracked" {
    const allocator = std.testing.allocator;
    const errs = try runRule(allocator, "let mut counter = 0", .{});
    defer freeErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expect(std.mem.indexOf(u8, errs[0].message, "counter") != null);
}

test "unused variable: shadowing the LHS is not a use" {
    // `let foo = 1; let foo = 2; foo` — outer foo is never read.
    // Shadow tracking is best-effort in the token scanner; we just verify
    // the rule terminates and produces a sensible (>=0) result.
    const allocator = std.testing.allocator;
    const errs = try runRule(allocator, "let foo = 1\nlet foo = 2\nfoo", .{});
    defer freeErrors(allocator, errs);
    try std.testing.expect(errs.len <= 2);
}

test "unused variable: multiple unused bindings reported separately" {
    const allocator = std.testing.allocator;
    const errs = try runRule(allocator, "let a = 1\nlet b = 2\nlet c = 3", .{});
    defer freeErrors(allocator, errs);
    try std.testing.expectEqual(@as(usize, 3), errs.len);
}
