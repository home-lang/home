# Home Language - Implementation Roadmap

**Version:** 1.0 Draft
**Last Updated:** 2025-11-03
**Status:** Planning Phase

---

## Table of Contents

1. [Overview](#overview)
2. [Phase 0: Foundation & Critical Fixes](#phase-0-foundation--critical-fixes)
3. [Phase 1: Core Language (v0.1)](#phase-1-core-language-v01)
4. [Phase 2: Ergonomics & Developer Experience (v0.2)](#phase-2-ergonomics--developer-experience-v02)
5. [Phase 3: Advanced Features (v0.3)](#phase-3-advanced-features-v03)
6. [Phase 4: Optimization & Tooling (v0.4)](#phase-4-optimization--tooling-v04)
7. [Phase 5: Stabilization (v1.0)](#phase-5-stabilization-v10)
8. [Detailed Implementation Guides](#detailed-implementation-guides)
9. [Testing Strategy](#testing-strategy)
10. [Migration & Compatibility](#migration--compatibility)

---

## Overview

### Guiding Principles

1. **Incremental Development** - Each phase builds on previous phases
2. **Breaking Changes Early** - Make breaking changes before v1.0
3. **Test-Driven** - Write tests before implementation
4. **Documentation-First** - Document features as they're designed
5. **User Feedback** - Gather feedback at each phase

### Timeline Estimates

- **Phase 0:** 2-3 weeks (Critical fixes)
- **Phase 1:** 6-8 weeks (Core language)
- **Phase 2:** 4-6 weeks (Ergonomics)
- **Phase 3:** 8-10 weeks (Advanced features)
- **Phase 4:** 4-6 weeks (Optimization)
- **Phase 5:** 6-8 weeks (Stabilization)

**Total:** ~6-9 months to v1.0

---

## Phase 0: Foundation & Critical Fixes
**Target:** 2-3 weeks
**Goal:** Fix critical ambiguities and establish baseline

### 0.1 Semicolon Rules Definition & Implementation

#### Design Decision
```home
// Semicolons are OPTIONAL for:
// 1. End of statement before newline
let x = 42
let y = 100

// 2. Last statement in block
fn foo() {
    let x = 42
    return x  // No semicolon needed
}

// Semicolons are REQUIRED for:
// 1. Multiple statements on one line
let x = 5; let y = 10

// 2. Disambiguation (rare cases)
return  // Returns void
{       // Separate block statement
    foo()
}

vs

return {  // Returns object/struct literal
    foo: bar
}
```

#### Implementation Tasks

**Task 0.1.1: Update Parser** (3 days)
- File: `packages/parser/src/parser.zig`
- Changes:
  ```zig
  // Add semicolon optionality logic
  fn optionalSemicolon(self: *Parser) !void {
      // Semicolon optional if:
      // - At end of line (peek next token is on new line)
      // - Before closing brace
      // - At EOF
      if (self.check(.Semicolon)) {
          _ = self.advance();
      } else if (!self.isAtNewLine() and !self.check(.RightBrace) and !self.isAtEnd()) {
          try self.reportError("Expected semicolon or newline");
      }
  }

  fn isAtNewLine(self: *Parser) bool {
      if (self.current == 0) return false;
      const current_line = self.peek().line;
      const prev_line = self.previous().line;
      return current_line > prev_line;
  }
  ```

- Update all statement parsing functions:
  ```zig
  fn letDeclaration(self: *Parser, is_const: bool) !ast.Stmt {
      // ... existing code ...

      // OLD: _ = try self.expect(.Semicolon, "Expected ';' after declaration");
      // NEW:
      try self.optionalSemicolon();

      return ast.Stmt{ .LetDecl = decl };
  }
  ```

**Task 0.1.2: Update Lexer to Track Line Info** (1 day)
- File: `packages/lexer/src/lexer.zig`
- Ensure accurate line tracking for newline detection
- Already implemented ✓

**Task 0.1.3: Create Linter Rule** (2 days)
- Create new file: `packages/linter/src/rules/semicolon_style.zig`

```zig
const std = @import("std");
const ast = @import("ast");
const Token = @import("lexer").Token;

pub const SemicolonStyle = struct {
    name: []const u8 = "semicolon-style",
    severity: Severity = .Warning,

    pub const Severity = enum {
        Error,
        Warning,
        Info,
    };

    pub const Config = struct {
        // never: Semicolons should never be used (except required cases)
        // always: Semicolons must always be used
        // optional: Semicolons are optional (default)
        style: Style = .optional,

        pub const Style = enum {
            never,
            always,
            optional,
        };
    };

    config: Config,

    pub fn init(config: Config) SemicolonStyle {
        return .{ .config = config };
    }

    pub fn check(
        self: *SemicolonStyle,
        allocator: std.mem.Allocator,
        tokens: []const Token,
    ) ![]LintError {
        var errors = std.ArrayList(LintError).init(allocator);

        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];

            if (token.type != .Semicolon) continue;

            // Check if semicolon is required or optional
            const is_required = self.isSemicolonRequired(tokens, i);
            const next_on_same_line = self.isNextTokenOnSameLine(tokens, i);

            switch (self.config.style) {
                .never => {
                    if (!is_required) {
                        try errors.append(allocator, .{
                            .message = "Unnecessary semicolon",
                            .line = token.line,
                            .column = token.column,
                            .severity = self.severity,
                            .rule = self.name,
                            .fix = .{ .remove_semicolon = .{ .position = i } },
                        });
                    }
                },
                .always => {
                    // Check if semicolon is missing
                    if (self.shouldHaveSemicolon(tokens, i)) {
                        try errors.append(allocator, .{
                            .message = "Missing semicolon",
                            .line = token.line,
                            .column = token.column,
                            .severity = self.severity,
                            .rule = self.name,
                            .fix = .{ .add_semicolon = .{ .position = i } },
                        });
                    }
                },
                .optional => {
                    // No errors in optional mode, just ensure valid placement
                    if (is_required and token.type != .Semicolon) {
                        try errors.append(allocator, .{
                            .message = "Semicolon required here (multiple statements on one line)",
                            .line = token.line,
                            .column = token.column,
                            .severity = .Error,
                            .rule = self.name,
                            .fix = .{ .add_semicolon = .{ .position = i } },
                        });
                    }
                },
            }
        }

        return errors.toOwnedSlice();
    }

    fn isSemicolonRequired(self: *SemicolonStyle, tokens: []const Token, index: usize) bool {
        _ = self;

        if (index == 0) return false;

        // Required if next statement on same line
        if (index + 1 < tokens.len) {
            const current = tokens[index];
            const next = tokens[index + 1];

            // Same line AND next is a statement start
            if (current.line == next.line and self.isStatementStart(next)) {
                return true;
            }
        }

        return false;
    }

    fn isNextTokenOnSameLine(self: *SemicolonStyle, tokens: []const Token, index: usize) bool {
        _ = self;
        if (index + 1 >= tokens.len) return false;
        return tokens[index].line == tokens[index + 1].line;
    }

    fn isStatementStart(self: *SemicolonStyle, token: Token) bool {
        _ = self;
        return switch (token.type) {
            .Let, .Const, .Fn, .If, .While, .For, .Return, .Identifier => true,
            else => false,
        };
    }

    fn shouldHaveSemicolon(self: *SemicolonStyle, tokens: []const Token, index: usize) bool {
        _ = self;
        _ = tokens;
        _ = index;
        // Implementation for detecting missing semicolons
        // Check if statement end without semicolon
        return false;
    }
};

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
};
```

**Task 0.1.4: Integrate Linter Rule** (1 day)
- File: `packages/linter/src/linter.zig`

```zig
const semicolon_style = @import("rules/semicolon_style.zig");

pub const Linter = struct {
    allocator: std.mem.Allocator,
    rules: []Rule,

    pub fn init(allocator: std.mem.Allocator) !Linter {
        var rules = std.ArrayList(Rule).init(allocator);

        // Add semicolon style rule
        try rules.append(.{
            .semicolon_style = semicolon_style.SemicolonStyle.init(.{
                .style = .optional,  // Default: optional
            }),
        });

        // ... other rules ...

        return .{
            .allocator = allocator,
            .rules = try rules.toOwnedSlice(),
        };
    }

    pub fn lint(self: *Linter, tokens: []const Token) ![]LintError {
        var all_errors = std.ArrayList(LintError).init(self.allocator);

        for (self.rules) |*rule| {
            const errors = try rule.check(self.allocator, tokens);
            try all_errors.appendSlice(errors);
        }

        return all_errors.toOwnedSlice();
    }
};

pub const Rule = union(enum) {
    semicolon_style: semicolon_style.SemicolonStyle,
    // ... other rules ...

    pub fn check(self: *Rule, allocator: std.mem.Allocator, tokens: []const Token) ![]LintError {
        return switch (self.*) {
            .semicolon_style => |*rule| rule.check(allocator, tokens),
            // ... other rules ...
        };
    }
};
```

**Task 0.1.5: Add Configuration File Support** (2 days)
- Create: `.homelint.toml` configuration file format

```toml
[semicolon]
# Options: "optional", "always", "never"
style = "optional"
severity = "warning"  # or "error", "info"

[semicolon.exceptions]
# Allow semicolons in specific contexts
allow_single_line_multiple = true  # let x = 1; let y = 2
```

- File: `packages/linter/src/config.zig`

```zig
const std = @import("std");

pub const LintConfig = struct {
    semicolon: SemicolonConfig = .{},

    pub const SemicolonConfig = struct {
        style: []const u8 = "optional",
        severity: []const u8 = "warning",
        exceptions: Exceptions = .{},

        pub const Exceptions = struct {
            allow_single_line_multiple: bool = true,
        };
    };

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !LintConfig {
        // Parse .homelint.toml file
        // TODO: Implement TOML parsing
        _ = allocator;
        _ = path;
        return .{};
    }
};
```

**Task 0.1.6: Update Tests** (2 days)
- File: `packages/parser/tests/semicolon_test.zig`

```zig
const std = @import("std");
const testing = std.testing;
const Parser = @import("parser").Parser;
const Lexer = @import("lexer").Lexer;

test "optional semicolons - simple statements" {
    const source =
        \\let x = 42
        \\let y = 100
        \\return x + y
    ;

    var lexer = Lexer.init(testing.allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, tokens.items);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), program.statements.len);
}

test "required semicolons - multiple statements one line" {
    const source = "let x = 5; let y = 10";

    var lexer = Lexer.init(testing.allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, tokens.items);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), program.statements.len);
}

test "semicolon error - missing on same line" {
    const source = "let x = 5 let y = 10";  // Missing semicolon

    var lexer = Lexer.init(testing.allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, tokens.items);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expectError(error.UnexpectedToken, result);
}

test "linter - optional style allows both" {
    const with_semi = "let x = 42;";
    const without_semi = "let x = 42";

    // Both should pass with optional style
    // TODO: Implement linter tests
}

test "linter - never style rejects unnecessary semicolons" {
    const source = "let x = 42;";  // Unnecessary semicolon

    // Should produce warning/error with "never" style
    // TODO: Implement linter tests
}

test "linter - always style requires semicolons" {
    const source = "let x = 42";  // Missing semicolon

    // Should produce error with "always" style
    // TODO: Implement linter tests
}
```

**Task 0.1.7: Documentation** (1 day)
- Update: `docs/syntax/semicolons.md`

```markdown
# Semicolons in Home

## Overview

Semicolons in Home are **optional** in most cases. The language uses
newlines to determine statement boundaries.

## Rules

### Optional Cases

Semicolons are optional when:

1. Statement ends with a newline
2. Last statement in a block
3. Before a closing brace

```home
let x = 42          // OK
let y = 100         // OK

fn foo() {
    return x + y    // OK - last statement in block
}
```

### Required Cases

Semicolons are required when:

1. Multiple statements on the same line

```home
let x = 5; let y = 10  // Semicolon REQUIRED
```

2. Disambiguation (rare)

```home
return    // Returns void
{         // Start of new block
    foo()
}

vs

return {  // Returns struct literal
    foo: bar
}
```

## Linter Configuration

Configure semicolon style in `.homelint.toml`:

```toml
[semicolon]
style = "optional"  # or "always", "never"
severity = "warning"
```

### Styles

- `optional` (default): Semicolons allowed but not required
- `always`: Semicolons must be used everywhere
- `never`: Semicolons forbidden except where required
```

**Deliverables:**
- ✅ Parser updated with optional semicolon logic
- ✅ Linter rule implemented
- ✅ Configuration system for linter
- ✅ Comprehensive tests (parser + linter)
- ✅ Documentation

---

### 0.2 String Interpolation

**Task 0.2.1: Lexer Changes** (3 days)
- File: `packages/lexer/src/lexer.zig`

```zig
// Add new token types
pub const TokenType = enum {
    // ... existing tokens ...

    // String interpolation tokens
    StringInterpolationStart,  // "text {
    StringInterpolationMid,    // } text {
    StringInterpolationEnd,    // } text"
    StringInterpolationExpr,   // expression between {}
};

// Update string() method to handle interpolation
fn string(self: *Lexer) Token {
    var has_interpolation = false;
    var brace_depth: usize = 0;

    while (self.peek() != '"' and !self.isAtEnd()) {
        if (self.peek() == '{' and self.peekNext() != '{') {
            has_interpolation = true;
            // Start tracking interpolation
            break;
        }

        if (self.peek() == '\\') {
            // Handle escapes
            _ = self.advance();
            if (!self.isAtEnd()) _ = self.advance();
        } else {
            if (self.peek() == '\n') {
                self.line += 1;
                self.column = 0;
            }
            _ = self.advance();
        }
    }

    if (has_interpolation) {
        return self.stringInterpolation();
    }

    // Regular string...
}

fn stringInterpolation(self: *Lexer) Token {
    // Complex parsing for interpolated strings
    // Returns special token that parser will handle
    // TODO: Detailed implementation
}
```

**Task 0.2.2: Parser Changes** (4 days)
- File: `packages/parser/src/parser.zig`

```zig
fn parseInterpolatedString(self: *Parser) !*ast.Expr {
    var parts = std.ArrayList(*ast.Expr).init(self.allocator);
    defer parts.deinit();

    // Parse: "Hello, {name}! You are {age} years old."
    // Into: concat(["Hello, ", name, "! You are ", age, " years old."])

    while (!self.check(.StringInterpolationEnd)) {
        if (self.match(.StringLiteral)) {
            // String part
            const str_lit = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .StringLiteral = ast.StringLiteral.init(str_lit.lexeme, ast.SourceLocation.fromToken(str_lit)) };
            try parts.append(expr);
        } else if (self.match(.LeftBrace)) {
            // Expression part
            const expr = try self.expression();
            try parts.append(expr);
            _ = try self.expect(.RightBrace, "Expected '}' after interpolation expression");
        }
    }

    // Create string concatenation expression
    return self.createConcatExpr(try parts.toOwnedSlice());
}
```

**Task 0.2.3: Codegen Changes** (2 days)
- Update code generator to emit string concatenation code

**Task 0.2.4: Tests** (2 days)
```zig
test "string interpolation - basic" {
    const source =
        \\let name = "Alice"
        \\let msg = "Hello, {name}!"
    ;
    // Test parsing and evaluation
}

test "string interpolation - expressions" {
    const source =
        \\let x = 5
        \\let msg = "Result: {x * 2}"
    ;
    // Should produce "Result: 10"
}

test "string interpolation - nested" {
    const source =
        \\let msg = "Outer {inner("text")} end"
    ;
}
```

**Deliverables:**
- ✅ String interpolation syntax working
- ✅ Tests for various interpolation cases
- ✅ Documentation

---

### 0.3 Type System Clarification

**Task 0.3.1: Define Default Types** (2 days)
- File: `packages/types/src/types.zig`

```zig
pub const BuiltinType = enum {
    // Integer types
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,

    // Default integer (alias to i64)
    int,

    // Unsigned default (alias to u64)
    uint,

    // Float types
    f32, f64,

    // Default float (alias to f64)
    float,

    // ... other types

    pub fn resolveDefault(self: BuiltinType) BuiltinType {
        return switch (self) {
            .int => .i64,
            .uint => .u64,
            .float => .f64,
            else => self,
        };
    }
};
```

**Task 0.3.2: Update Type Inference** (3 days)
- Ensure integer literals default to i64
- Ensure float literals default to f64
- Add contextual inference

**Task 0.3.3: Documentation** (1 day)
- Document type inference rules
- Add examples

**Deliverables:**
- ✅ Clear default types
- ✅ Contextual inference
- ✅ Documentation

---

### 0.4 Numeric Literal Extensions

**Task 0.4.1: Lexer Updates** (3 days)
- File: `packages/lexer/src/lexer.zig`

```zig
fn number(self: *Lexer) Token {
    // Check for base prefix
    if (self.peek() == '0') {
        if (self.peekNext() == 'b' or self.peekNext() == 'B') {
            return self.binaryNumber();
        } else if (self.peekNext() == 'o' or self.peekNext() == 'O') {
            return self.octalNumber();
        } else if (self.peekNext() == 'x' or self.peekNext() == 'X') {
            return self.hexNumber();
        }
    }

    // Decimal number with underscores
    while (std.ascii.isDigit(self.peek()) or self.peek() == '_') {
        if (self.peek() == '_') {
            _ = self.advance();  // Skip underscore
            continue;
        }
        _ = self.advance();
    }

    // Check for type suffix
    if (self.checkTypeSuffix()) {
        return self.numberWithSuffix();
    }

    // ... rest of decimal/float logic
}

fn binaryNumber(self: *Lexer) Token {
    _ = self.advance();  // '0'
    _ = self.advance();  // 'b'

    while (self.peek() == '0' or self.peek() == '1' or self.peek() == '_') {
        if (self.peek() == '_') {
            _ = self.advance();
            continue;
        }
        _ = self.advance();
    }

    return self.makeToken(.Integer);
}

fn hexNumber(self: *Lexer) Token {
    _ = self.advance();  // '0'
    _ = self.advance();  // 'x'

    while (std.ascii.isHex(self.peek()) or self.peek() == '_') {
        if (self.peek() == '_') {
            _ = self.advance();
            continue;
        }
        _ = self.advance();
    }

    return self.makeToken(.Integer);
}
```

**Task 0.4.2: Parser Updates** (2 days)
- Parse binary, octal, hex literals
- Handle underscores in numbers
- Parse type suffixes

**Task 0.4.3: Tests** (2 days)
```zig
test "binary literals" {
    const source = "let x = 0b1010_1100";
    // Should parse to 172
}

test "hex literals" {
    const source = "let color = 0xFF_AA_00";
    // Should parse to 16755200
}

test "underscores for readability" {
    const source = "let million = 1_000_000";
    // Should parse to 1000000
}

test "type suffixes" {
    const source =
        \\let a = 42i32
        \\let b = 3.14f32
    ;
}
```

**Deliverables:**
- ✅ Binary, octal, hex literals
- ✅ Underscores in numbers
- ✅ Type suffixes
- ✅ Tests
- ✅ Documentation

---

### 0.5 Raw String Literals

**Task 0.5.1: Lexer Implementation** (2 days)
```zig
fn rawString(self: *Lexer) Token {
    // Consume 'r'
    _ = self.advance();

    // Count '#' characters
    var hash_count: usize = 0;
    while (self.peek() == '#') : (hash_count += 1) {
        _ = self.advance();
    }

    // Expect opening quote
    if (self.peek() != '"') {
        return self.makeToken(.Invalid);
    }
    _ = self.advance();

    // Scan until closing quote + matching #'s
    while (!self.isAtEnd()) {
        if (self.peek() == '"') {
            // Check if followed by correct number of #'s
            var found_hashes: usize = 0;
            var temp_pos = self.current + 1;

            while (temp_pos < self.source.len and self.source[temp_pos] == '#') {
                found_hashes += 1;
                temp_pos += 1;
            }

            if (found_hashes == hash_count) {
                // Found closing delimiter
                _ = self.advance();  // "
                for (0..hash_count) |_| {
                    _ = self.advance();  // #'s
                }
                return self.makeToken(.RawString);
            }
        }

        if (self.peek() == '\n') {
            self.line += 1;
            self.column = 0;
        }
        _ = self.advance();
    }

    return self.makeToken(.Invalid);
}
```

**Task 0.5.2: Tests** (1 day)
```zig
test "raw string - basic" {
    const source = r"let path = r"C:\Users\Alice"";
    // No escape processing
}

test "raw string - with quotes" {
    const source = r#"let json = r#"{"key": "value"}"#"#;
}
```

**Deliverables:**
- ✅ Raw string literal support
- ✅ Tests
- ✅ Documentation

---

## Phase 1: Core Language (v0.1)
**Target:** 6-8 weeks
**Goal:** Complete core language features

### 1.1 Module System with Visibility (Week 1-2)

**Task 1.1.1: Add pub Keyword** (3 days)
```zig
// Add to keywords
.{ "pub", .Pub },

// Parser support
fn declaration(self: *Parser) !ast.Stmt {
    // Check for pub modifier
    const is_public = self.match(&.{.Pub});

    if (self.match(&.{.Fn})) return self.functionDeclaration(is_public);
    if (self.match(&.{.Struct})) return self.structDeclaration(is_public);
    // ... etc
}
```

**Task 1.1.2: Visibility in AST** (2 days)
```zig
pub const FnDecl = struct {
    node: Node,
    name: []const u8,
    params: []const Parameter,
    return_type: ?[]const u8,
    body: *BlockStmt,
    is_async: bool,
    type_params: []const []const u8,
    is_test: bool,
    is_public: bool,  // NEW
    // ...
};
```

**Task 1.1.3: Symbol Table with Visibility** (4 days)
```zig
pub const Symbol = struct {
    name: []const u8,
    type: SymbolType,
    visibility: Visibility,
    location: SourceLocation,

    pub const Visibility = enum {
        private,         // Module-local only
        pub_crate,      // Crate-local (future)
        public,         // Fully public
    };
};
```

**Task 1.1.4: Import/Export System** (5 days)
- Implement re-exports: `pub import`
- Module resolution with visibility checks
- Import aliasing: `import foo as bar`

**Task 1.1.5: Tests** (2 days)
```zig
test "public functions visible across modules" {}
test "private functions hidden from imports" {}
test "pub(crate) visibility" {}
```

**Deliverables:**
- ✅ pub keyword working
- ✅ Visibility enforcement
- ✅ Import/export system
- ✅ Tests
- ✅ Documentation

---

### 1.2 Collection Literals (Week 3-4)

**Task 1.2.1: Map/Dictionary Syntax** (4 days)
```zig
// Lexer: Already have braces and colons

// Parser: New expression type
fn mapLiteral(self: *Parser) !*ast.Expr {
    _ = self.advance();  // {

    var entries = std.ArrayList(ast.MapEntry).init(self.allocator);

    while (!self.check(.RightBrace)) {
        const key = try self.expression();
        _ = try self.expect(.Colon, "Expected ':' after map key");
        const value = try self.expression();

        try entries.append(.{ .key = key, .value = value });

        if (!self.match(.Comma)) break;
    }

    _ = try self.expect(.RightBrace, "Expected '}'");

    return ast.MapLiteral.init(self.allocator, try entries.toOwnedSlice());
}
```

**Task 1.2.2: Set Syntax** (3 days)
```home
// Syntax: #{elements}
let set = #{1, 2, 3, 4, 5};
```

**Task 1.2.3: Runtime Support** (5 days)
- Implement HashMap and HashSet in stdlib
- Codegen for collection literals

**Task 1.2.4: Tests** (2 days)

**Deliverables:**
- ✅ Map literals
- ✅ Set literals
- ✅ Runtime collections
- ✅ Tests

---

### 1.3 Documentation Comments (Week 5)

**Task 1.3.1: Lexer Support** (2 days)
```zig
fn skipWhitespace(self: *Lexer) void {
    while (!self.isAtEnd()) {
        const c = self.peek();
        switch (c) {
            '/' => {
                if (self.peekNext() == '/' and self.peekNextNext() == '/') {
                    // Doc comment
                    return self.docComment();
                }
                // ... existing comment handling
            },
            // ...
        }
    }
}

fn docComment(self: *Lexer) Token {
    _ = self.advance();  // /
    _ = self.advance();  // /
    _ = self.advance();  // /

    const start = self.current;

    while (self.peek() != '\n' and !self.isAtEnd()) {
        _ = self.advance();
    }

    const content = self.source[start..self.current];
    return Token.init(.DocComment, content, self.line, self.start_column);
}
```

**Task 1.3.2: Parser Integration** (2 days)
- Attach doc comments to declarations
- Store in AST nodes

**Task 1.3.3: Doc Generator** (3 days)
- Create tool to extract docs
- Generate HTML/Markdown

**Deliverables:**
- ✅ Doc comment syntax
- ✅ Doc generation tool
- ✅ Documentation

---

### 1.4 Improved Type Conversions (Week 6)

**Task 1.4.1: as Operator** (3 days)
```zig
// Add 'as' keyword
// Parser: Binary expression with 'as'

fn parseAsExpr(self: *Parser) !*ast.Expr {
    var expr = try self.parsePrecedence(.Factor);

    while (self.match(&.{.As})) {
        const target_type = try self.expect(.Identifier, "Expected type after 'as'");
        expr = try ast.AsExpr.init(
            self.allocator,
            expr,
            target_type.lexeme,
            ast.SourceLocation.fromToken(target_type),
        );
    }

    return expr;
}
```

**Task 1.4.2: From/Into Traits** (4 days)
- Implement standard conversion traits
- Automatic Into implementation from From

**Task 1.4.3: Tests** (2 days)

**Deliverables:**
- ✅ as operator
- ✅ Conversion traits
- ✅ Tests

---

### 1.5 Attributes System (Week 7-8)

**Task 1.5.1: Attribute Parsing** (4 days)
```zig
pub const Attribute = struct {
    name: []const u8,
    args: []const AttributeArg,

    pub const AttributeArg = union(enum) {
        string: []const u8,
        int: i64,
        bool: bool,
        ident: []const u8,
    };
};

fn parseAttributes(self: *Parser) ![]Attribute {
    var attrs = std.ArrayList(Attribute).init(self.allocator);

    while (self.match(&.{.At})) {
        const name = try self.expect(.Identifier, "Expected attribute name");

        var args = std.ArrayList(AttributeArg).init(self.allocator);

        if (self.match(&.{.LeftParen})) {
            // Parse arguments
            while (!self.check(.RightParen)) {
                // Parse arg
            }
            _ = try self.expect(.RightParen, "Expected ')'");
        }

        try attrs.append(.{
            .name = name.lexeme,
            .args = try args.toOwnedSlice(),
        });
    }

    return attrs.toOwnedSlice();
}
```

**Task 1.5.2: Standard Attributes** (5 days)
- `@deprecated`
- `@inline`
- `@must_use`
- `@derive`

**Task 1.5.3: Attribute Validation** (3 days)

**Task 1.5.4: Tests** (2 days)

**Deliverables:**
- ✅ Attribute system
- ✅ Standard attributes
- ✅ Tests

---

## Phase 2: Ergonomics & Developer Experience (v0.2)
**Target:** 4-6 weeks
**Goal:** Improve developer experience

### 2.1 Import Aliasing (Week 1)

```zig
fn importDeclaration(self: *Parser) !ast.Stmt {
    // ... existing import parsing ...

    // Check for 'as' keyword
    var alias: ?[]const u8 = null;
    if (self.match(&.{.As})) {
        const alias_token = try self.expect(.Identifier, "Expected alias name");
        alias = alias_token.lexeme;
    }

    // ... create import with alias
}
```

**Deliverables:**
- ✅ Import aliasing
- ✅ Tests

---

### 2.2 Pattern Binding with @ (Week 2)

```zig
pub const Pattern = union(enum) {
    // ... existing patterns ...

    // New: Binding pattern (x @ Pattern)
    Binding: struct {
        name: []const u8,
        pattern: *Pattern,
    },
};

fn parsePattern(self: *Parser) !*Pattern {
    // ... existing pattern parsing ...

    // Check for @ binding
    if (self.match(&.{.At})) {
        const name = self.previous().lexeme;
        const inner_pattern = try self.parsePattern();

        return Pattern{ .Binding = .{
            .name = name,
            .pattern = inner_pattern,
        }};
    }

    // ... rest
}
```

**Deliverables:**
- ✅ @ pattern binding
- ✅ Tests

---

### 2.3 For Loop with Index (Week 3)

```home
// Syntax option 1: enumerate method
for index, value in array.enumerate() {
    println("[{index}] = {value}")
}

// Syntax option 2: built-in syntax
for index, value in array {
    println("[{index}] = {value}")
}
```

**Implementation:** Add enumerate method to iterables

**Deliverables:**
- ✅ Indexed for loops
- ✅ Tests

---

### 2.4 Labeled Break/Continue (Week 4)

```zig
// Add labels to loop statements
pub const WhileStmt = struct {
    node: Node,
    label: ?[]const u8,  // NEW
    condition: *Expr,
    body: *BlockStmt,
};

// Parse labels
fn whileStatement(self: *Parser) !ast.Stmt {
    // Check for label: 'label_name:
    var label: ?[]const u8 = null;
    if (self.check(.Identifier) and self.peekNext().type == .Colon) {
        label = self.advance().lexeme;
        _ = self.advance();  // :
    }

    _ = try self.expect(.While, "Expected 'while'");
    // ... rest
}
```

**Deliverables:**
- ✅ Loop labels
- ✅ Labeled break/continue
- ✅ Tests

---

### 2.5 Better Error Messages (Week 5-6)

**Task 2.5.1: Error Recovery Improvements** (5 days)
- Better panic mode recovery
- Suggest corrections for typos
- Context-aware error messages

**Task 2.5.2: Error Formatter Enhancements** (4 days)
```zig
pub const ErrorFormatter = struct {
    pub fn formatError(
        self: *ErrorFormatter,
        filename: []const u8,
        line: usize,
        column: usize,
        message: []const u8,
        source_line: ?[]const u8,
        error_code: []const u8,
        suggestion: ?[]const u8,
        note: ?[]const u8,  // NEW: Additional notes
    ) ![]const u8 {
        // Enhanced formatting with colors, suggestions, notes
    }
};
```

**Task 2.5.3: Common Error Patterns** (5 days)
- Detect common mistakes
- Provide fix suggestions
- "Did you mean X?" suggestions

**Deliverables:**
- ✅ Improved error messages
- ✅ Fix suggestions
- ✅ Better recovery

---

## Phase 3: Advanced Features (v0.3)
**Target:** 8-10 weeks
**Goal:** Implement advanced language features

### 3.1 Closures with Inferred Move (Week 1-2)

**Current Problem:**
```home
let data = vec![1, 2, 3];
let consume = move |x| { drop(data) };  // Explicit move
```

**Improved:**
```home
let data = vec![1, 2, 3];
let consume = |x| {
    drop(data)  // Compiler infers move needed
};
```

**Implementation:**
- Analyze closure body for captures
- Detect when value is consumed/moved
- Auto-promote to move closure

**Deliverables:**
- ✅ Move inference
- ✅ Tests

---

### 3.2 Trait System Completion (Week 3-5)

**Task 3.2.1: Associated Type Bounds** (4 days)
```home
fn process<T>(iter: T)
where
    T: Iterator<Item: Display>  // Inline associated type bound
{
    // ...
}
```

**Task 3.2.2: Default Trait Implementations** (5 days)
```home
trait Summary {
    fn summarize(&self) -> string {
        "Read more..."  // Default implementation
    }
}
```

**Task 3.2.3: Trait Objects (dyn)** (7 days)
```home
fn draw(shapes: &[dyn Drawable]) {
    for shape in shapes {
        shape.draw()
    }
}
```

**Deliverables:**
- ✅ Complete trait system
- ✅ Dynamic dispatch
- ✅ Tests

---

### 3.3 Async/Await Completion (Week 6-8)

**Task 3.3.1: Async Runtime** (10 days)
- Task scheduler
- Future implementation
- Async I/O integration

**Task 3.3.2: Error Propagation in Async** (4 days)
```home
async fn fetch() -> Result<Data, Error> {
    let response = await http.get(url)?;  // Both await and ?
    return Ok(response);
}
```

**Task 3.3.3: Async Trait Methods** (5 days)
```home
trait AsyncReader {
    async fn read(&mut self) -> Result<Vec<u8>, Error>;
}
```

**Deliverables:**
- ✅ Working async/await
- ✅ Async runtime
- ✅ Tests

---

### 3.4 Compile-Time Evaluation (Week 9-10)

**Task 3.4.1: Comptime Interpreter** (8 days)
- Evaluate expressions at compile time
- Constant folding
- Comptime function calls

**Task 3.4.2: Comptime Control Flow** (6 days)
```home
comptime {
    const values = generate_lookup_table();
}
```

**Task 3.4.3: Integration with Type System** (5 days)

**Deliverables:**
- ✅ Comptime evaluation
- ✅ Tests

---

## Phase 4: Optimization & Tooling (v0.4)
**Target:** 4-6 weeks
**Goal:** Performance and tooling

### 4.1 Language Server Protocol (Week 1-3)

**Features:**
- Auto-completion
- Go to definition
- Find references
- Hover information
- Code actions (quick fixes)

### 4.2 Formatter (Week 4-5)

**Features:**
- Consistent code formatting
- Configurable style
- Integration with editor

### 4.3 Optimizations (Week 6)

- Constant propagation
- Dead code elimination
- Inline small functions
- Loop unrolling

---

## Phase 5: Stabilization (v1.0)
**Target:** 6-8 weeks
**Goal:** Production ready

### 5.1 Comprehensive Testing

- Unit tests for all features
- Integration tests
- Stress tests
- Fuzzing

### 5.2 Documentation

- Language reference
- Standard library docs
- Tutorials
- Migration guides

### 5.3 Performance Benchmarks

- Compare with Rust, Zig, C
- Optimize hot paths
- Memory usage profiling

### 5.4 Security Audit

- Memory safety verification
- Security review
- CVE process

### 5.5 Ecosystem

- Package manager
- Registry
- Build system integration

---

## Detailed Implementation Guides

### Guide: Implementing a New Operator

**Example: Implementing the `as` operator**

1. **Add keyword to lexer**
```zig
// packages/lexer/src/token.zig
pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    // ... existing keywords ...
    .{ "as", .As },
});
```

2. **Add token type**
```zig
pub const TokenType = enum {
    // ... existing tokens ...
    As,
};
```

3. **Add AST node**
```zig
// packages/ast/src/ast.zig
pub const AsExpr = struct {
    node: Node,
    expr: *Expr,
    target_type: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        expr: *Expr,
        target_type: []const u8,
        loc: SourceLocation,
    ) !*AsExpr {
        const as_expr = try allocator.create(AsExpr);
        as_expr.* = .{
            .node = .{ .type = .AsExpr, .loc = loc },
            .expr = expr,
            .target_type = target_type,
        };
        return as_expr;
    }
};

// Add to Expr union
pub const Expr = union(NodeType) {
    // ... existing variants ...
    AsExpr: *AsExpr,
};
```

4. **Add parser logic**
```zig
// packages/parser/src/parser.zig
fn parsePrecedence(self: *Parser, precedence: Precedence) !*Expr {
    // ... existing code ...

    while (...) {
        // ... existing operators ...

        if (self.match(&.{.As})) {
            expr = try self.asExpr(expr);
        }

        // ...
    }
}

fn asExpr(self: *Parser, left: *Expr) !*Expr {
    const as_token = self.previous();
    const type_token = try self.expect(.Identifier, "Expected type after 'as'");

    const as_expr = try ast.AsExpr.init(
        self.allocator,
        left,
        type_token.lexeme,
        ast.SourceLocation.fromToken(as_token),
    );

    const result = try self.allocator.create(ast.Expr);
    result.* = ast.Expr{ .AsExpr = as_expr };
    return result;
}
```

5. **Add type checking**
```zig
// packages/type_checker/src/type_checker.zig
fn checkAsExpr(self: *TypeChecker, expr: *ast.AsExpr) !Type {
    const source_type = try self.checkExpr(expr.expr);
    const target_type = try self.resolveType(expr.target_type);

    // Verify cast is valid
    if (!self.canCast(source_type, target_type)) {
        try self.reportError("Cannot cast from {s} to {s}", .{
            source_type.name,
            target_type.name,
        });
        return error.TypeError;
    }

    return target_type;
}
```

6. **Add code generation**
```zig
// packages/codegen/src/codegen.zig
fn generateAsExpr(self: *CodeGen, expr: *ast.AsExpr) !void {
    // Generate cast instruction
    try self.generateExpr(expr.expr);
    try self.emit(.Cast, .{ .target = expr.target_type });
}
```

7. **Add tests**
```zig
test "as operator - basic cast" {
    const source =
        \\let x: i32 = 42
        \\let y = x as i64
    ;

    var parser = try setupParser(source);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(parser.allocator);

    // Verify AST structure
    // Run type checker
    // Test code generation
}
```

8. **Document**
```markdown
## The `as` Operator

The `as` operator performs type conversions.

### Syntax

```home
expression as Type
```

### Examples

```home
let x: i32 = 42;
let y = x as i64;  // Widening conversion

let pi = 3.14;
let truncated = pi as i32;  // Narrowing conversion
```

### Valid Conversions

- Integer widening (i32 → i64)
- Integer narrowing (i64 → i32, may truncate)
- Integer to float (i32 → f64)
- Float to integer (f64 → i32, truncates)
```

---

## Testing Strategy

### Unit Tests

Each module should have comprehensive unit tests:

```zig
// packages/parser/tests/parser_test.zig
test "parse let declaration" { }
test "parse function declaration" { }
test "parse if statement" { }
// ... etc
```

### Integration Tests

Test complete programs:

```zig
// tests/integration/features_test.zig
test "string interpolation in real program" {
    const source =
        \\fn main() {
        \\    let name = "Alice"
        \\    let greeting = "Hello, {name}!"
        \\    print(greeting)
        \\}
    ;

    const output = try runProgram(source);
    try testing.expectEqualStrings("Hello, Alice!", output);
}
```

### Linter Tests

```zig
// packages/linter/tests/semicolon_test.zig
test "optional style allows both" {
    const with = "let x = 42;";
    const without = "let x = 42";

    var linter = Linter.init(testing.allocator, .{ .semicolon_style = .optional });

    try testing.expectEqual(@as(usize, 0), (try linter.lint(with)).len);
    try testing.expectEqual(@as(usize, 0), (try linter.lint(without)).len);
}
```

### Regression Tests

Create tests for every bug fix:

```zig
test "regression: issue #123 - semicolon after return" {
    // Bug: Parser crashed on "return x;"
    const source = "fn foo() { return 42; }";

    var parser = try setupParser(source);
    defer parser.deinit();

    // Should not crash
    _ = try parser.parse();
}
```

---

## Migration & Compatibility

### Breaking Changes Log

Maintain a changelog for breaking changes:

```markdown
# Breaking Changes

## v0.1 → v0.2

### Semicolons Now Optional

**Before:**
```home
let x = 42;
return x;
```

**After:**
```home
let x = 42
return x
```

**Migration:** Run `home fmt --migrate-semicolons=optional` to automatically
remove unnecessary semicolons.

### String Interpolation Syntax

**Before:**
```home
let msg = format("Hello, {}", name)
```

**After:**
```home
let msg = "Hello, {name}"
```

**Migration:** Manual update required. The old `format` function is still
supported but deprecated.
```

### Version Migration Tool

```bash
# Migrate from v0.1 to v0.2
home migrate --from=0.1 --to=0.2 src/

# Preview changes
home migrate --from=0.1 --to=0.2 --dry-run src/
```

---

## Priority Matrix

### Critical Path Items (Cannot proceed without these)

1. ✅ Semicolon rules (Phase 0.1) - **Blocks:** Everything
2. ✅ Type system clarification (Phase 0.3) - **Blocks:** Type checker
3. ✅ Module system (Phase 1.1) - **Blocks:** Multi-file programs

### High Impact, Low Effort (Quick wins)

1. ✅ Raw strings (Phase 0.5) - 2 days
2. ✅ Numeric literals (Phase 0.4) - 3 days
3. ✅ Import aliasing (Phase 2.1) - 1 week

### High Impact, High Effort (Plan carefully)

1. ✅ String interpolation (Phase 0.2) - 2 weeks
2. ✅ Trait system (Phase 3.2) - 3 weeks
3. ✅ Async/await (Phase 3.3) - 4 weeks

### Nice to Have (Post v1.0)

1. Advanced optimizations
2. Incremental compilation
3. Hot reloading

---

## Success Metrics

### Phase 0 Success Criteria
- [ ] All critical ambiguities resolved
- [ ] Parser passes 100% of basic syntax tests
- [ ] Linter has configurable rules
- [ ] Documentation updated

### Phase 1 Success Criteria
- [ ] Can write multi-module programs
- [ ] Standard collections work
- [ ] Documentation generation works
- [ ] Type conversions are clear

### v1.0 Success Criteria
- [ ] Can compile real programs
- [ ] Performance within 2x of Rust
- [ ] Complete language reference
- [ ] Standard library documented
- [ ] LSP works with VS Code
- [ ] No known memory safety bugs
- [ ] At least 3 example projects

---

## Conclusion

This roadmap provides a structured path from the current state to a production-ready v1.0. Each phase builds on previous work and can be adjusted based on feedback and priorities.

**Next Steps:**
1. Review and approve roadmap
2. Set up project tracking (GitHub projects/issues)
3. Begin Phase 0 implementation
4. Establish weekly sync meetings
5. Create automated testing infrastructure

**Questions to resolve:**
- Team size and allocation?
- Any features to add/remove?
- Timeline constraints?
- Resource availability?
