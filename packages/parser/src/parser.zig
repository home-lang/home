const std = @import("std");
const lexer_mod = @import("lexer");
const Token = lexer_mod.Token;
const TokenType = lexer_mod.TokenType;
const ast = @import("ast");
const diagnostics = @import("diagnostics");
const errors = diagnostics.errors;
const module_resolver = @import("module_resolver.zig");
pub const ModuleResolver = module_resolver.ModuleResolver;
const symbol_table = @import("symbol_table.zig");
pub const SymbolTable = symbol_table.SymbolTable;
pub const Symbol = symbol_table.Symbol;
const compilation_unit = @import("compilation_unit.zig");
pub const CompilationUnit = compilation_unit.CompilationUnit;
pub const CompiledModule = compilation_unit.CompiledModule;
const trait_parser = @import("trait_parser.zig");
const closure_parser = @import("closure_parser.zig");
const macros_mod = @import("macros");
const MacroSystem = macros_mod.MacroSystem;

/// Error set for parsing operations.
///
/// These errors can occur during the parsing phase when converting
/// tokens into an Abstract Syntax Tree. The parser uses panic-mode
/// error recovery to collect multiple errors in one pass.
pub const ParseError = error{
    /// Encountered a token that doesn't match the expected syntax
    UnexpectedToken,
    /// Memory allocation failed during AST construction
    OutOfMemory,
    /// Invalid character encountered (should be caught by lexer)
    InvalidCharacter,
    /// Numeric overflow in general operations
    Overflow,
    /// Integer literal too large to represent
    IntegerOverflow,
    /// Float literal too large to represent
    FloatOverflow,
    /// Malformed floating-point literal
    InvalidFloat,
    /// Unknown reflection operation in @comptime expression
    UnknownReflection,
    /// Module not found during import resolution
    ModuleNotFound,
    /// Symbol not found in imported module
    SymbolNotFound,
    /// Expected array size (integer or identifier)
    ExpectedArraySize,
    /// Token type is not a valid binary operator
    InvalidBinaryOperator,
};

/// Operator precedence levels for expression parsing.
///
/// Used by the Pratt parser (precedence climbing algorithm) to correctly
/// parse expressions with mixed operators. Higher numeric values indicate
/// higher precedence (tighter binding).
///
/// The precedence hierarchy follows standard programming language conventions:
/// - Assignments bind loosest (evaluated last)
/// - Arithmetic operators follow mathematical precedence
/// - Function calls and member access bind tightest
// `Precedence` was extracted into `parsers/precedence.zig` per
// TS_PARITY_PLAN §0 Phase 0.7. The aliasing line below preserves the
// previous internal name so the rest of this file is unchanged.
const Precedence = @import("parsers/precedence.zig").Precedence;

/// Information about a parse error for error reporting.
///
/// Stores the error message along with source location to enable
/// helpful error messages with line and column numbers.
pub const ParseErrorInfo = struct {
    /// Human-readable error description
    message: []const u8,
    /// Line number where error occurred (1-indexed)
    line: usize,
    /// Column number where error occurred (1-indexed)
    column: usize,
};

/// Recursive descent parser for the Home programming language.
///
/// The Parser converts a stream of tokens (from the Lexer) into an Abstract
/// Syntax Tree (AST) representing the program structure. It implements:
///
/// Features:
/// - Recursive descent parsing for statements and declarations
/// - Pratt parser (precedence climbing) for expressions
/// - Panic-mode error recovery to collect multiple errors
/// - Recursion depth limiting to prevent stack overflow
/// - Support for generics, async functions, pattern matching
/// - Operator precedence handling for complex expressions
///
/// Error Recovery:
/// The parser uses "panic mode" error recovery. When an error occurs,
/// it enters panic mode and skips tokens until it finds a synchronization
/// point (statement boundary), then continues parsing. This allows
/// collecting multiple errors in one parse run.
///
/// Example:
/// ```zig
/// var parser = Parser.init(allocator, tokens);
/// defer parser.deinit();
/// const program = try parser.parse();
/// ```
pub const Parser = struct {
    /// Memory allocator for AST nodes and error messages
    allocator: std.mem.Allocator,
    /// Complete token stream from lexer (must include EOF)
    tokens: []const Token,
    /// Current position in token stream
    current: usize,
    /// List of accumulated parse errors
    errors: std.ArrayList(ParseErrorInfo),
    /// Whether we're in panic mode (suppressing cascading errors)
    panic_mode: bool,
    /// Current recursion depth (for stack overflow prevention)
    recursion_depth: usize,
    /// Formatter for error messages
    error_formatter: errors.ErrorFormatter,
    /// Optional source filename for error reporting
    source_file: ?[]const u8,
    /// Optional original source text for caret/snippet rendering in errors
    source_text: ?[]const u8,
    /// Module resolver for handling imports
    module_resolver: ModuleResolver,
    /// Symbol table for tracking imported modules and symbols
    symbol_table: SymbolTable,
    /// Count of pending > tokens from >> splits in nested generics (e.g. A<B<C>> splits >> into two >)
    pending_greater: u32,
    /// When > 0, primary() suppresses bare-identifier struct-literal
    /// parsing so that `while target { ... }` and `if cond { ... }`
    /// don't treat the body's `{` as part of a `target { ... }` struct
    /// literal in the condition expression. Stack depth lets nested
    /// expressions (e.g. `while f({}) {}`) restore the inner context.
    suppress_struct_literal: u32,
    /// When > 0, the expression parser stops at a top-level `else`
    /// instead of folding it into a `try ... else fallback` expression.
    /// Set while parsing the single-statement body of a brace-less
    /// `if (cond) <stmt>` so the `else` token belongs to the surrounding
    /// `if` (matching dangling-else convention) rather than being eaten
    /// by an expression like `return 0 else return 1`. The braced form
    /// is naturally protected by the closing `}` so this flag is not
    /// engaged there.
    suppress_else_in_expr: u32,
    /// When > 0, the expression parser does NOT consume `|` as bitwise-or.
    /// Set while parsing a `while`/`for` condition so the trailing Zig
    /// payload `|name|` (or `|*name|`) stays available for the statement
    /// parser to consume rather than getting eaten as `cond | name | ...`.
    suppress_pipe_or: u32,
    /// Macro system for expanding macro invocations
    macro_system: MacroSystem,

    /// Maximum allowed recursion depth to prevent stack overflow
    const MAX_RECURSION_DEPTH: usize = 256;

    /// Initialize a new parser with the given token stream
    ///
    /// Creates a parser that will convert tokens into an Abstract Syntax Tree (AST).
    /// The parser uses panic-mode error recovery to continue parsing after errors
    /// and tracks recursion depth to prevent stack overflow.
    ///
    /// Parameters:
    ///   - allocator: Memory allocator for AST nodes and error messages
    ///   - tokens: Token slice from the lexer (must include EOF token)
    ///
    /// Returns: Initialized Parser ready to parse tokens into AST
    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) !Parser {
        const macro_system = MacroSystem.init(allocator);

        return .{
            .allocator = allocator,
            .tokens = tokens,
            .current = 0,
            .errors = std.ArrayList(ParseErrorInfo).empty,
            .panic_mode = false,
            .recursion_depth = 0,
            .error_formatter = errors.ErrorFormatter.init(allocator),
            .source_file = null,
            .source_text = null,
            .module_resolver = try ModuleResolver.init(allocator, null),
            .symbol_table = SymbolTable.init(allocator),
            .pending_greater = 0,
            .suppress_struct_literal = 0,
            .suppress_else_in_expr = 0,
            .suppress_pipe_or = 0,
            .macro_system = macro_system,
        };
    }

    /// Clean up parser resources.
    ///
    /// Frees all allocated error messages and the error list. The AST
    /// itself must be freed separately by the caller.
    pub fn deinit(self: *Parser) void {
        // Free error messages
        for (self.errors.items) |err_info| {
            self.allocator.free(err_info.message);
        }
        self.errors.deinit(self.allocator);
        self.module_resolver.deinit();
        self.symbol_table.deinit();
        self.macro_system.deinit();
    }

    /// Check if we've reached the end of the token stream.
    ///
    /// Returns: true if current token is EOF, false otherwise
    pub fn isAtEnd(self: *Parser) bool {
        return self.peek().type == .Eof;
    }

    /// Return true if `s` contains any lowercase letter. Used to tell
    /// PascalCase type names apart from SCREAMING_SNAKE_CASE constants.
    fn hasLowercaseLetter(s: []const u8) bool {
        for (s) |c| {
            if (c >= 'a' and c <= 'z') return true;
        }
        return false;
    }

    /// Heuristic: starts with an uppercase ASCII letter — the convention
    /// used for type names (`Foo`, `BTreeNode`, `MAX_SIZE`). Used to
    /// decide whether `name { ... }` is plausibly a struct literal.
    fn startsUppercase(s: []const u8) bool {
        return s.len > 0 and s[0] >= 'A' and s[0] <= 'Z';
    }

    /// Does an expression look like a type name (suitable for module-
    /// qualified struct literal parsing)? Accepts:
    ///   * Identifier whose lexeme starts uppercase
    ///   * MemberExpr (`a.b.Type`) whose final field name starts
    ///     uppercase
    /// We keep the rule conservative: the trailing element must look
    /// like a type, otherwise an ordinary `obj.method { ... }` form
    /// could be misparsed as a struct literal.
    fn isTypeLikeExpr(expr: *const ast.Expr) bool {
        return switch (expr.*) {
            .Identifier => |id| startsUppercase(id.name),
            .MemberExpr => |m| startsUppercase(m.member),
            else => false,
        };
    }

    /// Flatten a chain of `Identifier` and `MemberExpr` nodes into a
    /// single dotted name string (e.g. `ns.inner.Type`). Returns a
    /// freshly-allocated owned slice. Caller frees on error.
    fn flattenDottedType(self: *Parser, expr: *const ast.Expr) ParseError![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.allocator);

        var cur: *const ast.Expr = expr;
        while (true) {
            switch (cur.*) {
                .MemberExpr => |m| {
                    try parts.append(self.allocator, m.member);
                    cur = m.object;
                },
                .Identifier => |id| {
                    try parts.append(self.allocator, id.name);
                    break;
                },
                else => {
                    // Should be unreachable when caller guards with
                    // isTypeLikeExpr, but bail out gracefully.
                    try self.reportError("Internal: expected identifier chain for struct literal type name");
                    return error.UnexpectedToken;
                },
            }
        }

        // Reverse: parts collected tail-first.
        var total: usize = parts.items.len; // for dots
        if (total > 0) total -= 1;
        for (parts.items) |p| total += p.len;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, total);

        var i: usize = parts.items.len;
        var first = true;
        while (i > 0) {
            i -= 1;
            if (!first) try out.append(self.allocator, '.');
            try out.appendSlice(self.allocator, parts.items[i]);
            first = false;
        }

        return out.toOwnedSlice(self.allocator);
    }

    /// Is `name` a built-in primitive type identifier
    /// (`u8`/`u16`/.../`i64`/`f32`/`bool`/`void`/...)?
    /// Also matches Zig-style arbitrary-width integers `u<N>` /
    /// `i<N>` (e.g. `u3`, `i7`) for use in `@truncate(x, u3)`.
    fn isPrimitiveTypeName(name: []const u8) bool {
        const primitives = [_][]const u8{
            "i8",     "i16", "i32",  "i64",   "i128",
            "u8",     "u16", "u32",  "u64",   "u128",
            "f32",    "f64", "int",  "float", "bool",
            "string", "str", "void", "usize", "isize",
            "char",
        };
        for (primitives) |p| {
            if (std.mem.eql(u8, name, p)) return true;
        }
        // Arbitrary-width int: `u3`, `i7`, `u128`, etc.
        if (name.len >= 2 and (name[0] == 'u' or name[0] == 'i')) {
            var all_digits = true;
            for (name[1..]) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) return true;
        }
        return false;
    }

    /// Heuristic: does the current token look like the start of a type
    /// name (primitive int/float/bool/string or `*`/`[`/`?` prefix)?
    /// Used to pick between type-first and expression-first cast forms
    /// in the @-builtin parser.
    fn isPrimitiveTypeStart(self: *Parser) bool {
        const t = self.peek();
        if (t.type == .Star or t.type == .LeftBracket or t.type == .Question) {
            return true;
        }
        if (t.type != .Identifier) return false;
        return isPrimitiveTypeName(t.lexeme);
    }

    /// True when the upcoming token can start a Zig-style return type in
    /// `fn(...) T` position (no `:`/`->` separator). Recognises primitive
    /// names, identifiers, and the prefix type forms (`?T`, `*T`, `&T`,
    /// `[T]`, `!T`, `?[T]`). Used by the function-type parser inside
    /// `parseTypeAnnotation` to decide whether to consume a return type.
    fn isReturnTypeStart(self: *Parser) bool {
        return switch (self.peek().type) {
            .Identifier,
            .Star,
            .StarStar,
            .Ampersand,
            .Question,
            .QuestionBracket,
            .LeftBracket,
            .Bang,
            .Fn,
            .Struct,
            => true,
            else => false,
        };
    }

    /// Same as `isReturnTypeStart` but at an arbitrary token index. Used by
    /// the postfix error-union path (`ErrorSet!Payload`) to decide whether
    /// the `!` after a type expression is followed by another type. Out-of-
    /// range indices return false.
    fn isReturnTypeStartAt(self: *Parser, idx: usize) bool {
        if (idx >= self.tokens.len) return false;
        return switch (self.tokens[idx].type) {
            .Identifier,
            .Star,
            .StarStar,
            .Ampersand,
            .Question,
            .QuestionBracket,
            .LeftBracket,
            .Bang,
            .Fn,
            .Struct,
            => true,
            else => false,
        };
    }

    /// Pure-lookahead scan to find where a type expression starting at
    /// `start_idx` ends. Returns the token index just past the type
    /// (or `start_idx` if no valid type prefix is found at that
    /// position). Mutates no parser state.
    ///
    /// Used by the typed-array-literal path (`[_]T{...}`) so we can
    /// commit only when the element type is followed by `{`. Supports
    /// the element-type forms that actually appear in this position:
    ///
    ///   - simple identifier (`u8`, `Foo`)
    ///   - dotted/qualified path (`usb.USBDeviceID`, `a.b.c.Foo`)
    ///   - slice/array prefixes (`[]T`, `[]const T`, `[N]T`, `[*]T`)
    ///   - pointer/reference prefixes (`*T`, `*const T`, `&T`, `&mut T`)
    ///   - optional prefix (`?T`)
    ///
    /// Generic type arguments (`Foo<T>`) are not handled here — the
    /// existing `[_]Foo<T>{...}` form is rare in practice and the
    /// `<` would be ambiguous with a less-than expression in the
    /// trailing element list. The fix targets the concrete forms
    /// that hit kernel code today.
    fn peekArrayElementTypeEnd(self: *Parser, start_idx: usize) usize {
        var i: usize = start_idx;
        // Walk through any number of stacked prefixes.
        while (i < self.tokens.len) {
            const t = self.tokens[i].type;
            switch (t) {
                .Question, .Ampersand => {
                    i += 1;
                    // `&mut T` — optional `mut` after `&`.
                    if (i < self.tokens.len and self.tokens[i].type == .Mut) i += 1;
                    continue;
                },
                .Star, .StarStar => {
                    i += 1;
                    // Optional `const` and/or `volatile` qualifier.
                    if (i < self.tokens.len and self.tokens[i].type == .Const) i += 1;
                    if (i < self.tokens.len and self.tokens[i].type == .Identifier and
                        std.mem.eql(u8, self.tokens[i].lexeme, "volatile"))
                    {
                        i += 1;
                    }
                    continue;
                },
                .LeftBracket => {
                    // Walk to the matching `]`. Element-type slice/array
                    // forms in this position are simple enough that a
                    // bracket-balance scan is sufficient.
                    var depth: i32 = 1;
                    i += 1;
                    while (i < self.tokens.len and depth > 0) : (i += 1) {
                        const tt = self.tokens[i].type;
                        if (tt == .LeftBracket) depth += 1;
                        if (tt == .RightBracket) depth -= 1;
                        if (depth == 0) break;
                    }
                    if (i >= self.tokens.len) return start_idx;
                    i += 1; // consume `]`
                    // Optional `const` / `volatile` qualifier on the pointee.
                    if (i < self.tokens.len and self.tokens[i].type == .Const) i += 1;
                    if (i < self.tokens.len and self.tokens[i].type == .Identifier and
                        std.mem.eql(u8, self.tokens[i].lexeme, "volatile"))
                    {
                        i += 1;
                    }
                    continue;
                },
                else => break,
            }
        }

        // After prefixes, we must see an identifier-rooted name (or a
        // primitive type name, which the lexer also tokenizes as an
        // Identifier). Walk a dotted path: `a`, `a.b`, `a.b.c`, ...
        if (i >= self.tokens.len or self.tokens[i].type != .Identifier) {
            return start_idx;
        }
        i += 1;
        while (i + 1 < self.tokens.len and
            self.tokens[i].type == .Dot and
            self.tokens[i + 1].type == .Identifier)
        {
            i += 2;
        }
        return i;
    }

    /// Check if the current token is on a new line compared to the previous token.
    ///
    /// Used to implement optional semicolons - statements can be separated by
    /// newlines instead of semicolons.
    ///
    /// Returns: true if current token is on a different line than previous
    fn isAtNewLine(self: *Parser) bool {
        if (self.current == 0) return false;
        const current_line = self.peek().line;
        const prev_line = self.previous().line;
        return current_line > prev_line;
    }

    /// Lookahead helper for Zig-style optional-unwrap capture in
    /// `if (cond) |x| { body }`. When the parser is at `(`, scan forward
    /// to find the matching `)` and check whether the next token begins a
    /// `|ident|` or `|_|` capture. Returns `false` if we hit EOF or an
    /// unbalanced paren run before finding a match. Pure lookahead: no
    /// tokens are consumed.
    fn afterMatchingParenLooksLikeCapturePipe(self: *Parser) bool {
        if (!self.check(.LeftParen)) return false;
        var i: usize = self.current + 1;
        var depth: usize = 1;
        while (i < self.tokens.len) : (i += 1) {
            const t = self.tokens[i].type;
            if (t == .LeftParen) {
                depth += 1;
            } else if (t == .RightParen) {
                depth -= 1;
                if (depth == 0) {
                    // Inspect token after the closing `)`.
                    const after = i + 1;
                    if (after >= self.tokens.len) return false;
                    if (self.tokens[after].type != .Pipe) return false;
                    const ident = after + 1;
                    if (ident >= self.tokens.len) return false;
                    if (self.tokens[ident].type != .Identifier) return false;
                    const close = ident + 1;
                    if (close >= self.tokens.len) return false;
                    return self.tokens[close].type == .Pipe;
                }
            } else if (t == .Eof) {
                return false;
            }
        }
        return false;
    }

    /// Lookahead helper for Zig-style `for (slice) |item|` loop syntax.
    /// When the parser is at `(`, scan forward to find the matching `)`
    /// and check whether the next token is `|`. This is looser than
    /// `afterMatchingParenLooksLikeCapturePipe` (no requirement that the
    /// capture be `|ident|` shape) so we can disambiguate the for-loop
    /// form before parsing the iterable expression — the actual capture
    /// list is validated when consumed. Pure lookahead: no tokens are
    /// consumed.
    fn forParenIsZigStyle(self: *Parser) bool {
        if (!self.check(.LeftParen)) return false;
        var i: usize = self.current + 1;
        var depth: usize = 1;
        while (i < self.tokens.len) : (i += 1) {
            const t = self.tokens[i].type;
            if (t == .LeftParen) {
                depth += 1;
            } else if (t == .RightParen) {
                depth -= 1;
                if (depth == 0) {
                    const after = i + 1;
                    if (after >= self.tokens.len) return false;
                    return self.tokens[after].type == .Pipe;
                }
            } else if (t == .Eof) {
                return false;
            }
        }
        return false;
    }

    /// Consume an optional semicolon.
    ///
    /// Semicolons are optional in Home if:
    /// - The statement ends with a newline
    /// - Before a closing brace
    /// - At end of file
    ///
    /// Semicolons are required when:
    /// - Multiple statements on the same line
    ///
    /// Errors: UnexpectedToken if semicolon is required but missing
    fn optionalSemicolon(self: *Parser) ParseError!void {
        // If there's a semicolon, consume it
        if (self.check(.Semicolon)) {
            _ = self.advance();
            return;
        }

        // Otherwise, semicolon is optional if:
        // 1. At a newline boundary
        // 2. Before closing brace
        // 3. At end of file
        if (self.isAtNewLine() or self.check(.RightBrace) or self.isAtEnd()) {
            return;
        }

        // If none of the above, semicolon is required (multiple statements on same line)
        try self.reportError("Expected semicolon or newline between statements");
        return error.UnexpectedToken;
    }

    /// Get current token without advancing the parser.
    ///
    /// Returns: The token at the current position
    pub fn peek(self: *Parser) Token {
        return self.tokens[self.current];
    }

    /// Look ahead one token without advancing the parser.
    ///
    /// Used for one-token lookahead to disambiguate grammar rules.
    ///
    /// Returns: The token after the current position, or EOF if at end
    fn peekNext(self: *Parser) Token {
        if (self.current + 1 >= self.tokens.len) {
            return self.tokens[self.tokens.len - 1]; // Return EOF token
        }
        return self.tokens[self.current + 1];
    }

    /// Check if a token type can start an expression.
    /// Used to disambiguate ternary (cond ? expr : expr) from try operator (expr?).
    fn canStartExpression(_: *Parser, token_type: TokenType) bool {
        return switch (token_type) {
            // Literals
            .Integer,
            .Float,
            .String,
            .Char,
            .True,
            .False,
            .Null,
            // Identifiers
            .Identifier,
            // Grouping and collection
            .LeftParen,
            .LeftBracket,
            .LeftBrace,
            // Prefix operators
            .Minus,
            .Bang,
            .Tilde,
            .Ampersand,
            .Star,
            .DotDot,
            .DotDotEqual,
            // Keywords that can start expressions
            .If,
            .Match,
            .Fn,
            .SelfValue,
            .Try,
            => true,
            else => false,
        };
    }

    /// Get the most recently consumed token.
    ///
    /// Returns: The token just before the current position
    pub fn previous(self: *Parser) Token {
        if (self.current == 0) return self.tokens[0];
        return self.tokens[self.current - 1];
    }

    /// Consume and return the current token, advancing to the next.
    ///
    /// Returns: The token that was current before advancing
    pub fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    /// Check if current token is of a specific type without consuming it.
    ///
    /// Parameters:
    ///   - token_type: The type to check for
    ///
    /// Returns: true if current token matches, false otherwise
    pub fn check(self: *Parser, token_type: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == token_type;
    }

    /// Try to match and consume current token against multiple types.
    ///
    /// Checks if the current token is any of the specified types. If a match
    /// is found, consumes the token and returns true. Used for implementing
    /// grammar alternatives (e.g., "if we see fn OR struct OR enum...").
    ///
    /// Parameters:
    ///   - types: Slice of token types to check against
    ///
    /// Returns: true and advances if match found, false otherwise
    pub fn match(self: *Parser, types: []const TokenType) bool {
        for (types) |t| {
            if (self.check(t)) {
                _ = self.advance();
                return true;
            }
        }
        return false;
    }

    /// Soft-keyword tokens accepted as plain identifiers in binding-name
    /// slots (let/var/const/struct-field/parameter names). These are
    /// reserved words that the lexer emits as their own token kinds, but
    /// which the language treats as *contextual* keywords — meaningful
    /// only in their grammatical position. Kernel and stdlib code use
    /// many of these as ordinary names.
    ///
    /// Notably:
    ///   * `is` is a keyword only in type-narrow position (`if x is T`).
    ///   * `test` is a keyword only at top level (`test "name" { }`).
    /// In binding-name slots they parse as identifiers.
    pub const binding_name_soft_keywords = [_]TokenType{
        .Default, .Type, .It,   .Match, .Union,
        .In,      .Is,   .Test, .As,    .Guard,
    };

    /// Returns true if `tok` can stand in for a plain `Identifier` in a
    /// binding-name slot (variable, parameter, field). Used by the
    /// helpers below and any future contextual-keyword sites.
    pub fn isIdentifierLikeToken(tok: TokenType) bool {
        if (tok == .Identifier) return true;
        for (binding_name_soft_keywords) |kw| {
            if (tok == kw) return true;
        }
        return false;
    }

    /// Match-and-consume an identifier-like token (Identifier or any of
    /// the contextual soft keywords). Returns the consumed token, or
    /// `null` if the current token is not identifier-like.
    pub fn matchIdentifierLike(self: *Parser) ?Token {
        if (isIdentifierLikeToken(self.peek().type)) {
            return self.advance();
        }
        return null;
    }

    /// Require a specific token type, consuming it or reporting an error.
    ///
    /// This is the primary way to enforce required syntax. If the expected
    /// token is present, it's consumed and returned. Otherwise, an error
    /// is reported with the provided message.
    ///
    /// Parameters:
    ///   - token_type: The required token type
    ///   - message: Error message if token is not found
    ///
    /// Returns: The expected token if found
    /// Errors: UnexpectedToken if current token doesn't match
    pub fn expect(self: *Parser, token_type: TokenType, message: []const u8) ParseError!Token {
        if (self.check(token_type)) return self.advance();
        try self.reportError(message);
        return error.UnexpectedToken;
    }

    /// Skip tokens until the matching `close` delimiter is consumed.
    /// Tracks nesting for all three delimiter pairs so that nested
    /// parens/brackets/braces inside the body don't terminate the scan
    /// prematurely. Used for opaque-body parsing (e.g. inline asm operand
    /// lists where the grammar doesn't fit Home expressions).
    /// Assumes the opening delimiter has already been consumed by the caller.
    fn consumeBalancedRaw(self: *Parser, close: TokenType) void {
        var paren_depth: i32 = 0;
        var bracket_depth: i32 = 0;
        var brace_depth: i32 = 0;
        // The caller already consumed one opener matching `close`, so start
        // its corresponding counter at 1.
        switch (close) {
            .RightParen => paren_depth = 1,
            .RightBracket => bracket_depth = 1,
            .RightBrace => brace_depth = 1,
            else => paren_depth = 1,
        }
        while (!self.isAtEnd()) {
            const t = self.advance();
            switch (t.type) {
                .LeftParen => paren_depth += 1,
                .RightParen => {
                    paren_depth -= 1;
                    if (close == .RightParen and paren_depth == 0 and
                        bracket_depth == 0 and brace_depth == 0) return;
                },
                .LeftBracket => bracket_depth += 1,
                .RightBracket => {
                    bracket_depth -= 1;
                    if (close == .RightBracket and paren_depth == 0 and
                        bracket_depth == 0 and brace_depth == 0) return;
                },
                .LeftBrace => brace_depth += 1,
                .RightBrace => {
                    brace_depth -= 1;
                    if (close == .RightBrace and paren_depth == 0 and
                        bracket_depth == 0 and brace_depth == 0) return;
                },
                else => {},
            }
        }
    }

    /// Report a parse error with location information.
    ///
    /// Records the error in the errors list and prints a formatted error
    /// message to stderr. Uses panic mode to suppress cascading errors.
    /// Implements a safety limit to prevent infinite loops (100 errors max).
    ///
    /// Parameters:
    ///   - message: Human-readable description of the error
    ///
    /// Errors: OutOfMemory if allocation fails, UnexpectedToken if too many errors
    /// Extract the 1-indexed source line containing the given line number.
    /// Returns null if source_text is not available or line is out of range.
    fn getSourceLine(self: *Parser, line: usize) ?[]const u8 {
        const text = self.source_text orelse return null;
        if (line == 0) return null;
        var current_line: usize = 1;
        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (current_line == line) {
                // Find end of this line
                var end = i;
                while (end < text.len and text[end] != '\n') : (end += 1) {}
                return text[start..end];
            }
            if (text[i] == '\n') {
                current_line += 1;
                start = i + 1;
            }
        }
        return null;
    }

    fn reportError(self: *Parser, message: []const u8) !void {
        if (self.panic_mode) return; // Don't report cascading errors

        const token = self.peek();
        const msg_copy = try self.allocator.dupe(u8, message);
        try self.errors.append(self.allocator, .{
            .message = msg_copy,
            .line = token.line,
            .column = token.column,
        });

        // Use centralized error formatter for consistent output
        const filename = self.source_file orelse "<input>";
        const source_line = self.getSourceLine(token.line);
        const formatted = try self.error_formatter.formatError(
            filename,
            token.line,
            token.column,
            message,
            source_line,
            errors.E_PARSER_UNEXPECTED_TOKEN,
            null, // suggestion
        );
        defer self.allocator.free(formatted);

        std.debug.print("{s}", .{formatted});

        self.panic_mode = true;

        // Safety limit: stop parsing if we have too many errors (prevents infinite loops)
        if (self.errors.items.len >= 100) {
            std.debug.print("\nToo many parse errors ({d}), stopping\n", .{self.errors.items.len});
            return error.UnexpectedToken;
        }
    }

    /// Recover from a parse error by finding a synchronization point.
    ///
    /// After encountering an error, the parser enters "panic mode" and
    /// skips tokens until it finds a likely statement boundary:
    /// - After a semicolon
    /// - Before a declaration keyword (fn, struct, let, etc.)
    /// - After a closing brace
    ///
    /// This allows the parser to continue and find more errors rather than
    /// stopping at the first one.
    fn synchronize(self: *Parser) void {
        self.panic_mode = false;

        while (!self.isAtEnd()) {
            // If we just passed a semicolon, we're at a statement boundary
            const prev = self.previous();
            if (prev.type == .Semicolon) {
                return;
            }

            // Check if we're at the start of a new statement/declaration
            switch (self.peek().type) {
                .Fn,
                .Struct,
                .Let,
                .Const,
                .If,
                .While,
                .For,
                .Return,
                .Enum,
                .Trait,
                .Impl,
                .Import,
                .Match,
                .Defer,
                .Try,
                => return,
                .RightBrace => {
                    // Stop before the brace — let the caller's block
                    // parser consume it. Consuming it here skips the
                    // block's closing brace and causes cascading errors.
                    return;
                },
                else => {},
            }

            _ = self.advance();
        }
    }

    /// Parse the entire token stream into an Abstract Syntax Tree
    ///
    /// This is the main entry point for parsing. It processes all tokens
    /// and constructs a complete AST representing the program structure.
    /// The parser uses error recovery to continue parsing after syntax errors,
    /// collecting all errors for comprehensive error reporting.
    ///
    /// Returns: Pointer to Program AST node containing all parsed statements
    /// Errors: ParseError if syntax errors prevent parsing (with detailed diagnostics)
    pub fn parse(self: *Parser) ParseError!*ast.Program {
        var statements = std.ArrayList(ast.Stmt).empty;
        defer statements.deinit(self.allocator);

        while (!self.isAtEnd()) {
            // Progress guard: every iteration of the top-level parse loop must
            // consume at least one token, otherwise we're caught in an infinite
            // recovery loop (issue #16). Snapshot the cursor before each
            // attempt and, on failure, ensure synchronize() actually advances.
            const before = self.current;
            if (self.declaration()) |stmt| {
                try statements.append(self.allocator, stmt);
                self.panic_mode = false; // Successfully parsed, exit panic mode
            } else |err| {
                // Out of memory is fatal — surface immediately.
                if (err == error.OutOfMemory) return err;

                // Error occurred, synchronize and continue parsing
                self.synchronize();

                // If synchronize() didn't advance past the offending token
                // (e.g. it stopped on a stray '}' or there was no sync point
                // after the error site), force-advance one token. This is the
                // last line of defence against parser hangs on malformed input.
                if (self.current == before and !self.isAtEnd()) {
                    _ = self.advance();
                }

                continue; // Try to parse next statement
            }
        }

        // If we collected any errors, report them but still return the AST
        // This allows partial parsing for better error messages
        if (self.errors.items.len > 0) {
            std.debug.print("\n{d} parse error(s) found\n", .{self.errors.items.len});
        }

        return ast.Program.init(self.allocator, try statements.toOwnedSlice(self.allocator));
    }

    /// Parse attributes (@test, @inline, @deprecated, etc.)
    fn parseAttributes(self: *Parser) ![]const ast.Attribute {
        var attrs = std.ArrayList(ast.Attribute).empty;
        defer attrs.deinit(self.allocator);

        while (self.check(.At)) {
            // Peek ahead to see if this is an attribute or a builtin function call
            // Attributes: @test, @inline
            // Builtins: @memset(...), @ptrCast(...), @TypeOf(...)
            const at_pos = self.current;
            _ = self.advance(); // consume @

            // Accept either an identifier (`@inline`) or a reserved keyword
            // that we use as an attribute name (`@test`, `@it`). Without the
            // keyword fallback `@test fn ...` would fail to parse because
            // `test` is lexed as a keyword token, not an identifier.
            const next = self.peek().type;
            const is_attr_name =
                next == .Identifier or next == .Test or next == .It;
            if (!is_attr_name) {
                // Not a recognized name after @, backtrack
                self.current = at_pos;
                break;
            }

            const name_token = self.advance();
            const name = name_token.lexeme;

            // Check if this looks like a builtin function call
            // Builtins are followed by '(' immediately
            if (self.check(.LeftParen)) {
                // This is a builtin call like @memset(...), not an attribute
                // Backtrack and stop parsing attributes
                self.current = at_pos;
                break;
            }

            var args = std.ArrayList(*ast.Expr).empty;
            defer args.deinit(self.allocator);

            // Parenthesised form: `@attribute(arg1, arg2)`.
            // Bare-string form: `@it "description"` (used by test files).
            //   Accepts a single string literal argument without parens,
            //   provided it's on the same line as the attribute name so we
            //   don't accidentally consume an unrelated string on the next
            //   statement.
            if (self.match(&.{.LeftParen})) {
                if (!self.check(.RightParen)) {
                    while (true) {
                        const arg = try self.expression();
                        try args.append(self.allocator, arg);
                        if (!self.match(&.{.Comma})) break;
                    }
                }
                _ = try self.expect(.RightParen, "Expected ')' after attribute arguments");
            } else if (self.check(.String) and self.peek().line == name_token.line) {
                // Bare-string shorthand: `@it "description"`. Consume a
                // single string literal on the same line as the attribute
                // name and use it as the attribute's sole argument.
                const str_tok = self.advance();
                const raw = str_tok.lexeme;
                const inner = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                const loc = ast.SourceLocation.fromToken(str_tok);
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .StringLiteral = ast.StringLiteral.init(inner, loc) };
                try args.append(self.allocator, expr);
            }

            const attr = ast.Attribute.init(name, try args.toOwnedSlice(self.allocator));
            try attrs.append(self.allocator, attr);
        }

        return try attrs.toOwnedSlice(self.allocator);
    }

    /// Optionally consume a Zig-style `callconv(<expr>)` suffix on a
    /// function declaration. Skips a balanced paren group; the expression
    /// is parsed and discarded for now (codegen will read this back from
    /// a future explicit annotation on FnDecl).
    fn consumeOptionalCallconvSuffix(self: *Parser) !void {
        if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "callconv")) {
            _ = self.advance();
            _ = try self.expect(.LeftParen, "Expected '(' after 'callconv'");
            var depth: i32 = 1;
            while (depth > 0 and !self.isAtEnd()) {
                const t = self.peek();
                if (t.type == .LeftParen) depth += 1;
                if (t.type == .RightParen) {
                    depth -= 1;
                    if (depth == 0) break;
                }
                _ = self.advance();
            }
            _ = try self.expect(.RightParen, "Expected ')' after callconv expression");
        }
    }

    /// Optionally consume an `align(N)` suffix on a let/var/field
    /// type annotation. The integer is parsed and discarded; codegen
    /// is expected to recover alignment requirements from attributes
    /// or layout directives in the future.
    fn consumeOptionalAlignSuffix(self: *Parser) !void {
        if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "align")) {
            _ = self.advance();
            _ = try self.expect(.LeftParen, "Expected '(' after 'align'");
            // Skip the alignment expression — we accept any constant
            // expression here and defer evaluation to a later pass.
            var depth: i32 = 1;
            while (depth > 0 and !self.isAtEnd()) {
                const t = self.peek();
                if (t.type == .LeftParen) depth += 1;
                if (t.type == .RightParen) {
                    depth -= 1;
                    if (depth == 0) break;
                }
                _ = self.advance();
            }
            _ = try self.expect(.RightParen, "Expected ')' after alignment value");
        }
    }

    /// Apply pub/doc/attributes to a declaration that may have been
    /// rewritten from `const Name = struct/enum/union { ... }` form.
    fn applyLetVisibility(
        self: *Parser,
        stmt: *ast.Stmt,
        is_pub: bool,
        doc_comment: ?[]const u8,
        attributes: []const ast.Attribute,
    ) void {
        _ = self;
        switch (stmt.*) {
            .LetDecl => {
                if (is_pub) stmt.LetDecl.is_public = true;
            },
            .StructDecl => {
                if (is_pub) stmt.StructDecl.is_public = true;
                if (doc_comment) |doc| stmt.StructDecl.doc_comment = doc;
                stmt.StructDecl.attributes = attributes;
            },
            .EnumDecl => {
                if (is_pub) stmt.EnumDecl.is_public = true;
                stmt.EnumDecl.attributes = attributes;
            },
            .UnionDecl => {
                if (is_pub) stmt.UnionDecl.is_public = true;
            },
            .TypeAliasDecl => {
                // `pub const Name = fn(...) Ret` and friends route through
                // letDeclaration but produce a TypeAliasDecl. Issue #51.
                if (is_pub) stmt.TypeAliasDecl.is_public = true;
                stmt.TypeAliasDecl.attributes = attributes;
            },
            else => {},
        }
    }

    /// Parse a top-level declaration or statement.
    ///
    /// Declarations include functions, structs, enums, unions, type aliases,
    /// and variable declarations (let/const). Falls through to statement
    /// parsing if no declaration keyword is found.
    ///
    /// Grammar:
    ///   declaration = structDecl | enumDecl | unionDecl | typeAlias
    ///               | fnDecl | letDecl | constDecl | statement
    ///
    /// Returns: Statement AST node (declarations are represented as statements)
    fn declaration(self: *Parser) ParseError!ast.Stmt {
        // Capture any doc comments (///) before the declaration
        var doc_comment: ?[]const u8 = null;
        if (self.check(.DocComment)) {
            const doc_token = self.advance();
            doc_comment = doc_token.lexeme;
        }

        // Parse any attributes first
        const attributes = try self.parseAttributes();

        // Check for pub or export modifier
        const is_pub = self.match(&.{.Pub});
        const is_export = self.match(&.{.Export});
        const is_extern = self.match(&.{.Extern});
        // `inline` is a function modifier hint. Accept it before `fn`
        // (both at top level and in front of `pub` was already absorbed).
        const is_inline = self.match(&.{.Inline});

        // Check if @test attribute exists for backward compatibility
        var is_test = false;
        for (attributes) |attr| {
            if (ast.Attribute.isNamed(attr, "test")) {
                is_test = true;
                break;
            }
        }

        // Check if @it "description" attribute exists
        var it_description: ?[]const u8 = null;
        for (attributes) |attr| {
            if (ast.Attribute.isNamed(attr, "it")) {
                // Get the description from the first argument
                if (attr.getStringArg(0)) |val| {
                    it_description = val;
                }
                break;
            }
        }

        if (self.match(&.{.Import})) return self.importDeclaration();

        if (self.match(&.{.Struct})) {
            var stmt = try self.structDeclaration();
            if (is_pub) stmt.StructDecl.is_public = true;
            if (doc_comment) |doc| stmt.StructDecl.doc_comment = doc;
            stmt.StructDecl.attributes = attributes;
            return stmt;
        }

        // `packed struct Name { ... }` — sets the layout bit on the
        // resulting decl. Mirrors the Zig-style anonymous form
        // (`const Name = packed struct { ... }`) handled in letDecl.
        if (self.match(&.{.Packed})) {
            _ = try self.expect(.Struct, "Expected 'struct' after 'packed'");
            var stmt = try self.structDeclaration();
            stmt.StructDecl.layout = .Packed;
            if (is_pub) stmt.StructDecl.is_public = true;
            if (doc_comment) |doc| stmt.StructDecl.doc_comment = doc;
            stmt.StructDecl.attributes = attributes;
            return stmt;
        }

        // `extern struct Name { ... }` — C-ABI compatible layout.
        // Note: bare `extern fn ...` is handled below via `is_extern`.
        if (is_extern and self.check(.Struct)) {
            _ = self.advance();
            var stmt = try self.structDeclaration();
            stmt.StructDecl.layout = .Extern;
            if (is_pub) stmt.StructDecl.is_public = true;
            if (doc_comment) |doc| stmt.StructDecl.doc_comment = doc;
            stmt.StructDecl.attributes = attributes;
            return stmt;
        }

        if (self.match(&.{.Enum})) {
            var stmt = try self.enumDeclaration();
            if (is_pub) stmt.EnumDecl.is_public = true;
            stmt.EnumDecl.attributes = attributes;
            return stmt;
        }

        if (self.match(&.{.Union})) {
            var stmt = try self.unionDeclaration();
            if (is_pub) stmt.UnionDecl.is_public = true;
            stmt.UnionDecl.attributes = attributes;
            return stmt;
        }

        if (self.match(&.{.Type})) {
            var stmt = try self.typeAliasDeclaration();
            if (is_pub) stmt.TypeAliasDecl.is_public = true;
            stmt.TypeAliasDecl.attributes = attributes;
            return stmt;
        }

        if (self.match(&.{.Trait})) {
            var stmt = try self.traitDeclaration();
            if (is_pub) stmt.TraitDecl.is_public = true;
            return stmt;
        }

        if (self.match(&.{.Impl})) return self.implDeclaration();
        if (self.match(&.{.Extend})) return self.extendDeclaration();

        // Handle async fn (async must come before fn)
        if (self.match(&.{.Async})) {
            _ = try self.expect(.Fn, "Expected 'fn' after 'async'");
            var stmt = try self.functionDeclarationWithAsync(is_test, is_extern, true);
            if (is_pub or is_export) stmt.FnDecl.is_public = true;
            if (is_export) stmt.FnDecl.is_exported = true;
            if (is_inline) stmt.FnDecl.is_inline = true;
            if (doc_comment) |doc| stmt.FnDecl.doc_comment = doc;
            stmt.FnDecl.attributes = attributes;
            return stmt;
        }

        if (self.match(&.{.Fn})) {
            var stmt = try self.functionDeclaration(is_test, is_extern);
            if (is_pub or is_export) stmt.FnDecl.is_public = true;
            if (is_export) stmt.FnDecl.is_exported = true;
            if (is_inline) stmt.FnDecl.is_inline = true;
            if (doc_comment) |doc| stmt.FnDecl.doc_comment = doc;
            stmt.FnDecl.attributes = attributes;
            return stmt;
        }

        if (self.match(&.{.Let})) {
            var stmt = try self.letDeclaration(false);
            self.applyLetVisibility(&stmt, is_pub, doc_comment, attributes);
            return stmt;
        }

        if (self.match(&.{.Const})) {
            var stmt = try self.letDeclaration(true);
            self.applyLetVisibility(&stmt, is_pub, doc_comment, attributes);
            return stmt;
        }

        // var at module level (mutable global variable)
        if (self.match(&.{.Var})) {
            var stmt = try self.varDeclaration();
            if (is_pub) stmt.LetDecl.is_public = true;
            return stmt;
        }

        // static binding: `static NAME = EXPR` (immutable) or
        // `static mut NAME = EXPR` (mutable global). Track the
        // distinction on the AST so downstream passes can reject writes
        // to non-mut statics (and the codegen can place them in
        // read-only vs mutable data sections).
        if (self.match(&.{.Static})) {
            const decl_is_mut = self.match(&.{.Mut});
            var stmt = try self.varDeclaration();
            if (is_pub) stmt.LetDecl.is_public = true;
            stmt.LetDecl.is_static = true;
            stmt.LetDecl.is_mutable = decl_is_mut;
            return stmt;
        }

        // Check for it('description') { body } test syntax
        if (self.match(&.{.It})) {
            return try self.itTestDeclaration();
        }

        // Check for test "description" { body } test syntax (Zig-style).
        // `test` is a *contextual* keyword: it only introduces a test
        // declaration when immediately followed by a string literal.
        // In any other position (`test.field = ...`, `test(...)`, `test +
        // 1`) it parses as a plain identifier — kernel code uses `test`
        // as a local variable name.
        if (self.check(.Test) and self.peekNext().type == .String) {
            _ = self.advance();
            return try self.testBlockDeclaration();
        }

        // Check for @it "description" { body } syntax (block without keyword)
        if (it_description != null and self.check(.LeftBrace)) {
            const body = try self.blockStatement();
            const it_decl = try ast.ItTestDecl.init(
                self.allocator,
                it_description.?,
                body,
                ast.SourceLocation.fromToken(self.peek()),
            );
            return ast.Stmt{ .ItTestDecl = it_decl };
        }

        // If attributes were provided but no valid declaration follows, error
        if (attributes.len > 0) {
            try self.reportError("Attributes can only be used with declarations");
            return error.UnexpectedToken;
        }

        if (is_pub) {
            try self.reportError("pub can only be used with declarations");
            return error.UnexpectedToken;
        }

        return self.statement();
    }

    /// Parse a function declaration with optional generics and async support.
    ///
    /// Grammar:
    ///   fnDecl = '@test'? 'async'? 'fn' IDENTIFIER typeParams? '(' params? ')' ('->' type)? block
    ///   typeParams = '<' IDENTIFIER (',' IDENTIFIER)* '>'
    ///   params = param (',' param)*
    ///   param = IDENTIFIER ':' type
    ///
    /// Examples:
    ///   fn add(x: i32, y: i32) -> i32 { return x + y; }
    ///   async fn fetch(url: string) -> Result { ... }
    ///   fn map<T, U>(arr: [T], f: fn(T) -> U) -> [U] { ... }
    ///   @test fn test_addition() { ... }
    ///
    /// Returns: Function declaration statement node
    pub fn functionDeclaration(self: *Parser, is_test: bool, is_extern: bool) !ast.Stmt {
        return self.functionDeclarationWithAsync(is_test, is_extern, false);
    }

    /// Function declaration with explicit async flag
    pub fn functionDeclarationWithAsync(self: *Parser, is_test: bool, is_extern: bool, already_async: bool) !ast.Stmt {
        // Check for async keyword before function name (or use already_async if async was parsed at top level)
        const is_async = already_async or self.match(&.{.Async});

        // Accept both Identifier and certain keywords as function names (e.g., 'default', 'type', 'match')
        const name_token = if (self.check(.Identifier))
            try self.expect(.Identifier, "Expected function name")
        else if (self.check(.Default))
            self.advance()
        else if (self.check(.Type))
            self.advance()
        else if (self.check(.Match))
            self.advance()
        else if (self.check(.Test))
            self.advance()
        else {
            try self.reportError("Expected function name");
            return error.UnexpectedToken;
        };
        const name = name_token.lexeme;

        // Parse generic type parameters if present: fn name<T, U>() or fn name<T: Trait>()
        var type_params = std.ArrayList(ast.GenericParam).empty;
        defer type_params.deinit(self.allocator);

        if (self.match(&.{.Less})) {
            while (!self.check(.Greater) and !self.isAtEnd()) {
                const type_param = try self.expect(.Identifier, "Expected type parameter name");
                const param_name = type_param.lexeme;

                // Parse optional trait bounds: <T: Trait> or <T: Trait1 + Trait2>
                var bounds = std.ArrayList([]const u8).empty;
                defer bounds.deinit(self.allocator);

                if (self.match(&.{.Colon})) {
                    // Parse first trait bound
                    const bound_token = try self.expect(.Identifier, "Expected trait name after ':'");
                    try bounds.append(self.allocator, bound_token.lexeme);

                    // Parse additional bounds with '+'
                    while (self.match(&.{.Plus})) {
                        const next_bound = try self.expect(.Identifier, "Expected trait name after '+'");
                        try bounds.append(self.allocator, next_bound.lexeme);
                    }
                }

                try type_params.append(self.allocator, ast.GenericParam{
                    .name = param_name,
                    .bounds = try bounds.toOwnedSlice(self.allocator),
                    .default_type = null,
                });

                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.expect(.Greater, "Expected '>' after type parameters");
        }

        _ = try self.expect(.LeftParen, "Expected '(' after function name");

        // Parse parameters
        var params = std.ArrayList(ast.Parameter).empty;
        defer params.deinit(self.allocator);

        if (!self.check(.RightParen)) {
            while (true) {
                // Handle shorthand self parameters: &self, mut self
                var is_ref_self = false;
                var is_mut_self = false;

                if (self.match(&.{.Ampersand})) {
                    is_ref_self = true;
                }
                if (self.match(&.{.Mut})) {
                    is_mut_self = true;
                }

                // Optional `comptime` modifier on a parameter:
                //   fn rcu_dereference(comptime T: type, ptr: *T) ?*T
                // We accept and discard it — the current Parameter AST has
                // no comptime flag, but parser-pass-rate audits only need
                // the shape to be recognized.
                if (self.check(.Comptime) and self.peekNext().type != .Colon and
                    self.peekNext().type != .Comma and self.peekNext().type != .RightParen)
                {
                    _ = self.advance();
                }

                // Accept Identifier and keywords as parameter names (to support C&C Generals codebase)
                const param_name = if (self.match(&.{
                    .Identifier, .SelfValue, .SelfType, .Type,     .Fn,      .Struct, .Enum,  .Trait,   .Impl,
                    .Let,        .Mut,       .Const,    .If,       .Else,    .Match,  .For,   .While,   .Loop,
                    .Do,         .Break,     .Continue, .Return,   .Import,  .Export, .Pub,   .Async,   .Await,
                    .Try,        .Catch,     .Defer,    .Comptime, .Static,  .Unsafe, .Var,   .Assert,  .True,
                    .False,      .Null,      .Test,     .It,       .Finally, .Guard,  .Union, .Default, .In,
                    .Is,         .As,        .Where,    .Switch,   .Case,    .Not,    .And,   .Or,      .Asm,
                    .Dyn,
                }))
                    self.previous()
                else {
                    try self.reportError("Expected parameter name");
                    return error.UnexpectedToken;
                };

                // For shorthand self (&self, mut self, or plain self), infer the type
                var param_type: []const u8 = undefined;
                var is_variadic_param = false;
                const is_self_param = std.mem.eql(u8, param_name.lexeme, "self");
                // Check if this is a shorthand self (no colon follows)
                const has_colon = self.check(.Colon);
                if (is_self_param and (is_ref_self or is_mut_self or !has_colon)) {
                    // Use "Self" as the type for shorthand self parameters
                    param_type = try self.allocator.dupe(u8, "Self");
                } else if (has_colon) {
                    _ = self.advance(); // consume the colon
                    // Variadic parameter shape: `name: ...` (C-style varargs).
                    // Used by printf-family forwarders like
                    //   fn kprintf(fmt: &str, args: ...)
                    // The `...` stands in as an opaque type marker; full
                    // va_args lowering is deferred to codegen, but the
                    // parameter name remains usable as an identifier so
                    // forwarders such as `vsnprintf(buf, n, fmt, args)`
                    // type-check.
                    if (self.check(.DotDotDot)) {
                        _ = self.advance(); // consume '...'
                        is_variadic_param = true;
                        param_type = try self.allocator.dupe(u8, "...");
                    } else {
                        param_type = try self.parseTypeAnnotation();
                    }
                } else {
                    // Allow untyped parameters - use "any" as default type
                    param_type = try self.allocator.dupe(u8, "any");
                }

                // Check for default value
                var default_value: ?*ast.Expr = null;
                if (self.match(&.{.Equal})) {
                    default_value = try self.expression();
                }

                try params.append(self.allocator, .{
                    .name = param_name.lexeme,
                    .type_name = param_type,
                    .default_value = default_value,
                    .loc = ast.SourceLocation.fromToken(param_name),
                    .is_variadic = is_variadic_param,
                });

                if (!self.match(&.{.Comma})) break;
                // Handle trailing comma: if next token is ), we're done
                if (self.check(.RightParen)) break;

                // A variadic parameter must be the last in the list.
                // Anything after `name: ...,` is a hard error so users
                // get a clear diagnostic instead of a confusing parse
                // cascade on the next parameter.
                if (is_variadic_param) {
                    try self.reportError("Variadic parameter 'name: ...' must be the last parameter");
                    return error.UnexpectedToken;
                }
            }
        }

        _ = try self.expect(.RightParen, "Expected ')' after parameters");

        // Optional Zig-style calling-convention attribute between the
        // parameter list and the return type:
        //   `fn name(args) callconv(.C) -> RetType { ... }`
        //   `fn name(args) callconv(.C) { ... }`            (no return)
        // The convention expression is parsed and discarded; codegen
        // will recover it from a future explicit annotation. Accept any
        // balanced paren expression so we don't constrain the form.
        try self.consumeOptionalCallconvSuffix();

        // Parse return type. Three styles are accepted:
        //   TypeScript-style: `fn foo(x: int): int { ... }`
        //   Rust-style:       `fn foo(x: int) -> int { ... }`
        //   Zig-style:        `fn foo(x: int) int { ... }`
        //
        // Zig-style detection delegates to `isReturnTypeStart` so the same
        // type-starter set is recognised here and inside the function-type
        // parser. That keeps fused tokens like `QuestionBracket` (`?[`),
        // `StarStar` (`**`), and keyword-led type forms (`fn(...) T`,
        // `struct { ... }`) working when parameters are present — the
        // earlier inline list omitted those and rejected signatures like
        // `fn foo(name: []const u8) ?[]const u8 { ... }`. (Issue #64.)
        var return_type: ?[]const u8 = null;
        if (self.match(&.{.Colon}) or self.match(&.{.Arrow})) {
            return_type = try self.parseTypeAnnotation();
        } else if (!self.check(.LeftBrace) and !self.check(.Requires) and !self.check(.Ensures) and
            // Issue #17 — the Zig-style (annotation-less) return type must sit
            // on the same line as the parameter list: otherwise a forward
            // declaration followed by the next item (`fn f(x: u8)\nfn f...`)
            // swallows that item as this signature's return type.
            self.previous().line == self.peek().line and
            self.isReturnTypeStart())
        {
            return_type = try self.parseTypeAnnotation();
        }

        // Also accept the calling-convention attribute *after* the
        // return type, mirroring Zig's grammar:
        //   `fn name(args) RetType callconv(.C) { ... }`.
        try self.consumeOptionalCallconvSuffix();

        // Parse contract clauses: requires and ensures
        var requires_clauses = std.ArrayList(ast.ContractClause).empty;
        defer requires_clauses.deinit(self.allocator);
        var ensures_clauses = std.ArrayList(ast.ContractClause).empty;
        defer ensures_clauses.deinit(self.allocator);

        // Parse requires clauses (preconditions)
        while (self.match(&.{.Requires})) {
            const condition = try self.expression();
            var message: ?[]const u8 = null;
            // Optional message: requires expr, "message"
            if (self.match(&.{.Comma})) {
                const msg_token = try self.expect(.String, "Expected string message after ','");
                // Remove quotes from string
                message = if (msg_token.lexeme.len >= 2)
                    msg_token.lexeme[1 .. msg_token.lexeme.len - 1]
                else
                    msg_token.lexeme;
            }
            try requires_clauses.append(self.allocator, .{
                .condition = condition,
                .message = message,
            });
        }

        // Parse ensures clauses (postconditions)
        // Syntax: ensures |result| condition or ensures condition
        while (self.match(&.{.Ensures})) {
            const condition = try self.expression();
            var message: ?[]const u8 = null;
            if (self.match(&.{.Comma})) {
                const msg_token = try self.expect(.String, "Expected string message after ','");
                message = if (msg_token.lexeme.len >= 2)
                    msg_token.lexeme[1 .. msg_token.lexeme.len - 1]
                else
                    msg_token.lexeme;
            }
            try ensures_clauses.append(self.allocator, .{
                .condition = condition,
                .message = message,
            });
        }

        // Parse optional where clause (skip it for now - just consume tokens until '{' or newline for extern)
        if (self.match(&.{.Where})) {
            // Consume where clause: TYPE: TRAIT (+ TRAIT)* (, TYPE: TRAIT (+ TRAIT)*)*
            while (!self.check(.LeftBrace) and !self.isAtEnd()) {
                // For extern functions, also break on newline since there's no body
                if (is_extern and (self.peek().type == .Eof or self.previous().line != self.peek().line)) break;
                _ = self.advance();
            }
        }

        // Issue #17 — a signature with no `{` on the same line is a FORWARD
        // DECLARATION (`fn pci_scan_bus(bus: u8)`): parse to an empty body
        // (like extern) and mark it so later passes bind the name without
        // emitting a duplicate definition. A stray same-line token still
        // falls through to blockStatement() and errors as before.
        const is_forward_decl = !is_extern and !self.check(.LeftBrace) and
            (self.isAtEnd() or self.previous().line != self.peek().line);
        // Parse body (only for non-extern functions)
        // For extern functions (and forward declarations), create an empty block
        const body = if (is_extern or is_forward_decl)
            try ast.BlockStmt.init(self.allocator, &.{}, ast.SourceLocation.fromToken(name_token))
        else
            try self.blockStatement();

        const params_slice = try params.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(params_slice);

        const type_params_slice = try type_params.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(type_params_slice);

        const fn_decl = try ast.FnDecl.init(
            self.allocator,
            name,
            params_slice,
            return_type,
            body,
            is_async,
            type_params_slice,
            is_test,
            ast.SourceLocation.fromToken(name_token),
        );

        // Set contract clauses
        fn_decl.requires_clauses = try requires_clauses.toOwnedSlice(self.allocator);
        fn_decl.ensures_clauses = try ensures_clauses.toOwnedSlice(self.allocator);
        fn_decl.is_forward_decl = is_forward_decl;

        return ast.Stmt{ .FnDecl = fn_decl };
    }

    /// Parse an inline test declaration: it('description') { body }
    ///
    /// Grammar:
    ///   itTest = 'it' '(' STRING ')' block
    ///
    /// Example:
    ///   it('can add two numbers') { ... }
    ///
    /// Returns: ItTestDecl statement node
    fn itTestDeclaration(self: *Parser) ParseError!ast.Stmt {
        const it_token = self.previous();

        // Expect opening parenthesis
        _ = try self.expect(.LeftParen, "Expected '(' after 'it'");

        // Expect string description
        const description_token = try self.expect(.String, "Expected test description string");
        const description = description_token.lexeme;

        // Expect closing parenthesis
        _ = try self.expect(.RightParen, "Expected ')' after test description");

        // Parse the test body block
        const body = try self.blockStatement();

        const it_decl = try ast.ItTestDecl.init(
            self.allocator,
            description,
            body,
            ast.SourceLocation.fromToken(it_token),
        );

        return ast.Stmt{ .ItTestDecl = it_decl };
    }

    /// Parse a test block declaration (Zig-style: test "name" { ... })
    fn testBlockDeclaration(self: *Parser) ParseError!ast.Stmt {
        const test_token = self.previous();

        // Expect string description
        const description_token = try self.expect(.String, "Expected test description string");
        const description = description_token.lexeme;

        // Parse the test body block
        const body = try self.blockStatement();

        // Reuse ItTestDecl for test blocks since they have the same structure
        const test_decl = try ast.ItTestDecl.init(
            self.allocator,
            description,
            body,
            ast.SourceLocation.fromToken(test_token),
        );

        return ast.Stmt{ .ItTestDecl = test_decl };
    }

    /// Parse a struct declaration. Top-level entry: requires a struct name.
    fn structDeclaration(self: *Parser) !ast.Stmt {
        return self.structDeclarationWithName(null);
    }

    /// Parse a struct declaration body, optionally with a pre-bound name.
    /// When `bound_name` is non-null, the parser does not consume an
    /// identifier (used for `const Name = struct { ... }` form).
    fn structDeclarationWithName(self: *Parser, bound_name: ?[]const u8) !ast.Stmt {
        const struct_token = self.previous();

        // Optional `alignas(N)` qualifier between `struct` and the name:
        //   `struct alignas(64) CPURunQueue { ... }`. The integer is parsed
        //   and stored on the StructDecl so codegen can recover the
        //   alignment requirement. Accept any constant expression in the
        //   parens for now and capture only literal integers; non-literal
        //   forms are silently kept as null until the constant evaluator
        //   can fold them.
        var explicit_alignment: ?u32 = null;
        var explicit_alignas: bool = false;
        if (bound_name == null and self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "alignas")) {
            _ = self.advance();
            _ = try self.expect(.LeftParen, "Expected '(' after 'alignas'");
            // Parse a single integer literal where possible; otherwise
            // skip the inner expression so we don't trip up on more
            // complex constant forms.
            if (self.check(.Integer)) {
                const tok = self.advance();
                explicit_alignment = std.fmt.parseInt(u32, tok.lexeme, 0) catch null;
            } else {
                var depth: i32 = 1;
                while (depth > 0 and !self.isAtEnd()) {
                    const t = self.peek();
                    if (t.type == .LeftParen) depth += 1;
                    if (t.type == .RightParen) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    _ = self.advance();
                }
            }
            _ = try self.expect(.RightParen, "Expected ')' after alignas value");
            explicit_alignas = true;
        }

        // Zig-style explicit backing type that comes *before* the name
        // and lives in the keyword position:
        //   `packed struct(u8) { ... }` (always anonymous — `bound_name`
        //   is non-null here because the outer form is
        //   `const Name = packed struct(u8) { ... }`).
        // Accept and discard the backing type for now — codegen will
        // recover the layout from field types and the `packed` attribute.
        if (bound_name != null and self.check(.LeftParen)) {
            _ = self.advance();
            _ = try self.parseTypeAnnotation();
            _ = try self.expect(.RightParen, "Expected ')' after struct backing type");
        }

        const name = if (bound_name) |bn| bn else blk: {
            const name_token = try self.expect(.Identifier, "Expected struct name");
            break :blk name_token.lexeme;
        };

        // Optional explicit backing type for fixed-layout structs:
        //   `packed struct IDTEntry: u128 { ... }`. Currently we accept
        //   the type and discard it — codegen will recover the layout
        //   from field types and the `packed` attribute. The token is
        //   consumed so it doesn't trip the `{`-after-name check.
        if (self.check(.Colon)) {
            _ = self.advance();
            _ = try self.parseTypeAnnotation();
        }

        // Parse generic type parameters if present: struct Name<T, U> or struct Name<T: Trait>
        var type_params = std.ArrayList(ast.GenericParam).empty;
        defer type_params.deinit(self.allocator);

        if (self.match(&.{.Less})) {
            while (!self.check(.Greater) and !self.isAtEnd()) {
                const type_param = try self.expect(.Identifier, "Expected type parameter name");
                const param_name = type_param.lexeme;

                // Parse optional trait bounds: <T: Trait> or <T: Trait1 + Trait2>
                var bounds = std.ArrayList([]const u8).empty;
                defer bounds.deinit(self.allocator);

                if (self.match(&.{.Colon})) {
                    // Parse first trait bound
                    const bound_token = try self.expect(.Identifier, "Expected trait name after ':'");
                    try bounds.append(self.allocator, bound_token.lexeme);

                    // Parse additional bounds with '+'
                    while (self.match(&.{.Plus})) {
                        const next_bound = try self.expect(.Identifier, "Expected trait name after '+'");
                        try bounds.append(self.allocator, next_bound.lexeme);
                    }
                }

                try type_params.append(self.allocator, ast.GenericParam{
                    .name = param_name,
                    .bounds = try bounds.toOwnedSlice(self.allocator),
                    .default_type = null,
                });

                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.expect(.Greater, "Expected '>' after type parameters");
        }

        _ = try self.expect(.LeftBrace, "Expected '{' after struct name");

        // Parse fields
        var fields = std.ArrayList(ast.StructField).empty;
        defer fields.deinit(self.allocator);

        // Also collect methods defined inside the struct
        var methods = std.ArrayList(*ast.FnDecl).empty;
        defer methods.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            // Progress guard — mirrors the top-level parse loop
            // protection added in #16. Each iteration MUST consume at
            // least one token (or `break`/`continue` to a path that
            // does). If a future change re-introduces a no-progress
            // path the loop would otherwise spin forever (issue #34
            // was exactly this — `type` as a struct-field name caused
            // the nested-type-decl skip routine to return without
            // advancing). Bailing with an error is preferable to a
            // wedged compiler.
            const iter_start = self.current;

            // Doc-comments (`///`) inside the body. Allowed before any
            // item: first field, between fields, before a method,
            // before nested const/type. We consume any contiguous run
            // of doc-comment tokens as no-ops and continue. Issue #55.
            // (Future work: attach the captured text to the next AST
            // item for documentation generation.)
            if (self.check(.DocComment)) {
                while (self.check(.DocComment)) : (_ = self.advance()) {}
                continue;
            }

            // Look-ahead for member modifiers: `pub fn`, `inline fn`,
            // `pub inline fn`, `inline pub fn`. Only consume them when
            // the next non-modifier token introduces a recognized
            // member kind (`fn`, or a nested type/const declaration —
            // see below). Otherwise leave the tokens for field-
            // declaration parsing so that names like `pub` aren't
            // mistakenly eaten.
            const member_checkpoint = self.current;
            var member_is_pub = false;
            var member_is_inline = false;
            // First-position modifier
            if (self.check(.Pub)) {
                member_is_pub = true;
                _ = self.advance();
            } else if (self.check(.Inline)) {
                member_is_inline = true;
                _ = self.advance();
            }
            // Second-position modifier (other order)
            if (member_is_pub and self.check(.Inline)) {
                member_is_inline = true;
                _ = self.advance();
            } else if (member_is_inline and self.check(.Pub)) {
                member_is_pub = true;
                _ = self.advance();
            }

            // After the optional `pub`/`inline` prefix, accept a nested
            // declaration: `const`, `fn`, `enum`, `struct`, `union`,
            // `trait`, `impl`, or `type`. This is how Zig-style
            // namespacing works — a struct body doubles as a module
            // for associated constants and types (e.g.
            // `kernel/src/fs/btree_dir.home` defines `BTreeNode` with
            // `pub fn` methods and `pub const NODE_TYPE_LEAF: u8 = ...`
            // siblings). For now, methods (`fn`) are the only kind
            // attached to the struct AST; other nested decls are
            // skip-parsed structurally so the rest of the body still
            // type-checks. A future change can promote them to first-
            // class struct members once the AST/typechecker grow the
            // notion of nested namespaced symbols.
            if (member_is_pub or member_is_inline) {
                if (!self.check(.Fn) and !self.check(.Const) and !self.check(.Enum) and
                    !self.check(.Struct) and !self.check(.Union) and !self.check(.Trait) and
                    !self.check(.Impl) and !self.check(.Type) and !self.check(.Packed) and
                    !self.check(.Extern))
                {
                    // Not a recognized prefixed member — rewind and let
                    // the field parser handle it (so a field literally
                    // named `pub` doesn't get misparsed).
                    self.current = member_checkpoint;
                    member_is_pub = false;
                    member_is_inline = false;
                }
            }

            // Nested const declaration. Accepts:
            //   `const NAME[: T] = expr`
            //   `const NAME = struct { ... }` / `enum { ... }` / `union { ... }`
            //   `pub const ...` (modifier already consumed above)
            // We skip-parse for now (see comment above), then continue
            // to the next member.
            if (self.match(&.{.Const})) {
                try self.skipNestedConstDecl();
                continue;
            }

            // Nested type-keyword declarations. We accept these so
            // home-os can sit `pub enum SomeKind { ... }` next to
            // fields, but skip-parse them for now.
            //
            // Disambiguation: a type-introducing keyword followed
            // immediately by `:` is a field name, not a nested decl
            // (e.g. `struct S { type: u32 }` — kernel code routinely
            // uses `type` as a field name). Without this guard the
            // skip-parser sees `type` at a newline boundary, decides
            // the previous decl ended, and bails without consuming a
            // token — which spins the outer loop forever. (Issue #34.)
            if ((self.check(.Enum) or self.check(.Struct) or self.check(.Union) or
                self.check(.Trait) or self.check(.Impl) or self.check(.Type) or
                self.check(.Packed) or self.check(.Extern)) and
                self.peekNext().type != .Colon)
            {
                const before = self.current;
                try self.skipNestedTypeDecl();
                // Defense-in-depth: if the skip routine somehow fails
                // to make progress (a future change re-introduces the
                // pre-#34 hang condition), advance one token so the
                // outer loop can terminate via the field path or end-
                // of-body check instead of spinning.
                if (self.current == before and !self.isAtEnd()) {
                    _ = self.advance();
                }
                continue;
            }

            // Check if this is a method definition (fn keyword)
            if (self.match(&.{.Fn})) {
                // Parse method and collect it
                if (self.functionDeclaration(false, false)) |method_stmt| {
                    switch (method_stmt) {
                        .FnDecl => |fn_decl| {
                            if (member_is_pub) fn_decl.is_public = true;
                            if (member_is_inline) fn_decl.is_inline = true;
                            try methods.append(self.allocator, fn_decl);
                        },
                        else => {
                            try self.reportError("Expected function declaration in struct");
                            return error.UnexpectedToken;
                        },
                    }
                } else |err| {
                    // Error parsing method - skip to next method or end of struct
                    if (err == error.OutOfMemory) return err;

                    // Synchronize: skip tokens until we find 'fn' (next method) or '}' (end of struct)
                    var brace_depth: i32 = 0;
                    while (!self.isAtEnd()) {
                        const tok = self.peek();
                        if (tok.type == .LeftBrace) {
                            brace_depth += 1;
                        } else if (tok.type == .RightBrace) {
                            if (brace_depth == 0) {
                                // Found struct closing brace
                                break;
                            }
                            brace_depth -= 1;
                        } else if (tok.type == .Fn and brace_depth == 0) {
                            // Found next method
                            break;
                        }
                        _ = self.advance();
                    }
                }
                continue;
            }

            // Check if we have a potential field name followed by a colon
            // This prevents mistaking statement keywords for field names
            const checkpoint = self.current;
            const field_token = blk: {
                // Try to match a potential field name
                if (self.match(&.{
                    .Identifier, .SelfValue, .SelfType, .Type,     .Fn,      .Struct, .Enum,  .Trait,   .Impl,
                    .Let,        .Mut,       .Const,    .If,       .Else,    .Match,  .For,   .While,   .Loop,
                    .Do,         .Break,     .Continue, .Return,   .Import,  .Export, .Pub,   .Async,   .Await,
                    .Try,        .Catch,     .Defer,    .Comptime, .Static,  .Unsafe, .Var,   .Assert,  .True,
                    .False,      .Null,      .Test,     .It,       .Finally, .Guard,  .Union, .Default, .In,
                    .Is,         .As,        .Where,    .Switch,   .Case,    .Not,    .And,   .Or,      .Asm,
                    .Dyn,
                })) {
                    const token = self.previous();
                    // Check if next token is a colon (indicating a field)
                    if (self.check(.Colon)) {
                        break :blk token; // Valid field, return the token
                    }
                }
                // Not a field, restore position
                self.current = checkpoint;
                break :blk null;
            };

            if (field_token == null) {
                // Not a field, must be end of struct or parse error
                break;
            }

            // Now we have the field name token (already consumed)
            const field_name = field_token.?;
            _ = try self.expect(.Colon, "Expected ':' after field name");
            const field_type_name = try self.parseTypeAnnotation();

            // Optional `align(N)` field attribute (e.g.
            // `entries: [512]u8 align(4096)`). Mirrors the
            // declaration-level handling — accepted and currently
            // discarded; codegen will recover the requirement from
            // attributes/layout in a later pass.
            try self.consumeOptionalAlignSuffix();

            // Check if this is a constant (has = value)
            if (self.match(&.{.Equal})) {
                // Skip the constant value expression
                _ = try self.expression();
                // Optional comma after constant
                _ = self.match(&.{.Comma});
                continue; // Don't add constants as fields
            }

            try fields.append(self.allocator, .{
                .name = field_name.lexeme,
                .type_name = field_type_name,
                .loc = ast.SourceLocation.fromToken(field_name),
            });

            // Optional comma between fields
            _ = self.match(&.{.Comma});

            // Progress guard (paired with the `iter_start` capture at
            // the top of the loop). If after a full iteration we are
            // still on the same token we were, none of the paths
            // above advanced — bail with an error rather than spin.
            if (self.current == iter_start) {
                try self.reportError("Parser made no progress in struct body");
                return error.UnexpectedToken;
            }
        }

        _ = try self.expect(.RightBrace, "Expected '}' after struct fields");

        const methods_slice = try methods.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(methods_slice);

        const fields_slice = try fields.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(fields_slice);

        const type_params_slice = try type_params.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(type_params_slice);

        // Use initWithMethods if there are any methods, otherwise use regular init
        const struct_decl = if (methods_slice.len > 0)
            try ast.StructDecl.initWithMethods(
                self.allocator,
                name,
                fields_slice,
                type_params_slice,
                methods_slice,
                ast.SourceLocation.fromToken(struct_token),
            )
        else
            try ast.StructDecl.init(
                self.allocator,
                name,
                fields_slice,
                type_params_slice,
                ast.SourceLocation.fromToken(struct_token),
            );

        // Propagate the optional `alignas(N)` qualifier consumed above.
        if (explicit_alignas) {
            struct_decl.layout = .Aligned;
            struct_decl.alignment = explicit_alignment;
        }

        return ast.Stmt{ .StructDecl = struct_decl };
    }

    /// Skip-parse a nested `const` declaration inside a struct body
    /// (the leading `const` keyword has already been consumed). Accepts
    /// `const NAME[: T] = <expr-or-type-decl>` followed by an optional
    /// comma or semicolon.
    ///
    /// We don't yet thread these through the AST as struct-namespaced
    /// constants; this is enough to keep the rest of the body parsable
    /// while the typechecker grows nested-symbol support.
    fn skipNestedConstDecl(self: *Parser) ParseError!void {
        // Name (allow soft-keywords as in letDeclaration)
        if (self.matchIdentifierLike() == null) {
            try self.reportError("Expected name after 'const'");
            return error.UnexpectedToken;
        }

        // Optional type annotation
        if (self.match(&.{.Colon})) {
            const type_annotation = try self.parseTypeAnnotation();
            self.allocator.free(type_annotation);
            try self.consumeOptionalAlignSuffix();
        }

        // Initializer
        if (self.match(&.{.Equal})) {
            // Detect anonymous type bindings (`= struct { ... }`,
            // `= enum { ... }`, etc.) and consume their bodies
            // structurally. Otherwise parse the value as an expression.
            if (self.check(.Struct) or self.check(.Enum) or self.check(.Union) or
                self.check(.Packed) or self.check(.Extern))
            {
                try self.skipNestedTypeDecl();
            } else if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "error")) {
                // `pub const E = error { ... }` — error-set declaration.
                // Skip-parse like the other type bindings.
                try self.skipNestedTypeDecl();
            } else {
                const value = try self.expression();
                ast.Program.deinitExpr(value, self.allocator);
            }
        }

        // Optional terminator
        _ = self.match(&.{.Comma});
        _ = self.match(&.{.Semicolon});
    }

    /// Skip-parse a nested type declaration that uses one of the
    /// type-introducing keywords (`struct`, `enum`, `union`, `trait`,
    /// `impl`, `type`, `packed struct`, `extern struct`, `error`).
    /// The leading keyword has NOT been consumed yet.
    fn skipNestedTypeDecl(self: *Parser) ParseError!void {
        // Discard tokens up to and including the body's matching `}`
        // (or the trailing terminator for keyword-only forms like
        // `type X = U;`). We rely on brace-depth tracking so that nested
        // bodies don't trip us up.
        //
        // Simpler than re-entering the full declaration parser: we
        // don't currently store the result, and the bodies we encounter
        // in home-os tend to use only basic syntax.
        var saw_brace = false;
        var depth: i32 = 0;
        while (!self.isAtEnd()) {
            const t = self.peek().type;
            if (t == .LeftBrace) {
                saw_brace = true;
                depth += 1;
                _ = self.advance();
                continue;
            }
            if (t == .RightBrace) {
                if (depth == 0) {
                    // We never opened a brace and we're at the outer
                    // struct body's closing brace — bail out so the
                    // outer parser sees it.
                    break;
                }
                depth -= 1;
                _ = self.advance();
                if (depth == 0 and saw_brace) {
                    // Closing the nested decl's body. Allow optional
                    // comma/semicolon and return.
                    _ = self.match(&.{.Comma});
                    _ = self.match(&.{.Semicolon});
                    return;
                }
                continue;
            }
            // For brace-less forms (`type X = U`), terminate at the
            // first newline-separated boundary outside any nested
            // structure. We approximate this by stopping when we'd be
            // about to consume the outer struct's `}`.
            if (depth == 0 and !saw_brace) {
                // If this is the start of the body (`{`), the next
                // iteration will catch it. Otherwise consume tokens
                // until a comma/semicolon at depth 0 or until we hit
                // the next member-introducing keyword.
                if (t == .Comma or t == .Semicolon) {
                    _ = self.advance();
                    return;
                }
                // Stop before the next statement/member if we recognize
                // a field-like or member-like start on a new line.
                if (self.isAtNewLine()) {
                    if (t == .Pub or t == .Inline or t == .Const or
                        t == .Fn or t == .Enum or t == .Struct or
                        t == .Union or t == .Trait or t == .Impl or
                        t == .Type or t == .Packed or t == .Extern or
                        t == .RightBrace)
                    {
                        return;
                    }
                }
            }
            _ = self.advance();
        }
    }

    /// Parse an enum declaration. Accepts:
    ///   enum Name { ... }           — untagged
    ///   enum Name: u8 { ... }       — TS-style explicit tag
    ///   enum Name(u8) { ... }       — Zig-style explicit tag
    ///   enum(u8) Name { ... }       — Zig-style explicit tag (alt order)
    ///   enum(u8) { ... }            — anonymous (caller supplies name)
    fn enumDeclaration(self: *Parser) !ast.Stmt {
        return self.enumDeclarationWithName(null);
    }

    /// Parse an enum declaration body, optionally with a pre-bound name.
    /// When `bound_name` is non-null, the parser does not consume an
    /// identifier (used for `const Name = enum(u8) { ... }` form).
    fn enumDeclarationWithName(self: *Parser, bound_name: ?[]const u8) !ast.Stmt {
        const enum_token = self.previous();

        // Optional Zig-style tag type immediately after `enum`: `enum(u8) ...`
        var tag_type: ?[]const u8 = null;
        if (self.match(&.{.LeftParen})) {
            tag_type = try self.parseTypeAnnotation();
            _ = try self.expect(.RightParen, "Expected ')' after enum tag type");
        }

        const name = if (bound_name) |bn| bn else blk: {
            const name_token = try self.expect(.Identifier, "Expected enum name");
            break :blk name_token.lexeme;
        };

        // TS-style explicit tag after the name: `enum Name: u8 { ... }`
        if (tag_type == null and self.match(&.{.Colon})) {
            tag_type = try self.parseTypeAnnotation();
        }

        // Also accept Zig-style tag in alt order: `enum Name(u8) { ... }`
        if (tag_type == null and self.match(&.{.LeftParen})) {
            tag_type = try self.parseTypeAnnotation();
            _ = try self.expect(.RightParen, "Expected ')' after enum tag type");
        }

        _ = try self.expect(.LeftBrace, "Expected '{' after enum name");

        // Parse variants and (optionally) associated declarations.
        //
        // Zig-style enum bodies double as a namespace: after (or
        // interleaved with) the variant list you may declare
        // `pub fn` / `fn` methods on the enum, plus `pub const` /
        // `const` associated constants. This mirrors the struct-body
        // grammar — we accept the same modifier prefixes here.
        //
        // Issue #52: previously the loop only accepted bare
        // identifiers (variant names) and bailed with
        // "Expected variant name" the moment it saw `pub` or `fn`.
        var variants = std.ArrayList(ast.EnumVariant).empty;
        defer variants.deinit(self.allocator);

        var methods = std.ArrayList(*ast.FnDecl).empty;
        defer methods.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            const iter_start = self.current;

            // Doc-comments (`///`) inside the body. Allowed before any
            // item: first variant, between variants, before a method,
            // before associated const. Consume contiguous runs as
            // no-ops and continue. Issue #55. Mirrors the struct-body
            // handling.
            if (self.check(.DocComment)) {
                while (self.check(.DocComment)) : (_ = self.advance()) {}
                continue;
            }

            // Look-ahead for member modifiers: `pub fn`, `inline fn`,
            // `pub inline fn`, `inline pub fn`, `pub const`. Only
            // commit to consuming them when the following token kicks
            // off a recognized member kind; otherwise rewind so the
            // variant-name path still works.
            const member_checkpoint = self.current;
            var member_is_pub = false;
            var member_is_inline = false;
            if (self.check(.Pub)) {
                member_is_pub = true;
                _ = self.advance();
            } else if (self.check(.Inline)) {
                member_is_inline = true;
                _ = self.advance();
            }
            if (member_is_pub and self.check(.Inline)) {
                member_is_inline = true;
                _ = self.advance();
            } else if (member_is_inline and self.check(.Pub)) {
                member_is_pub = true;
                _ = self.advance();
            }
            if (member_is_pub or member_is_inline) {
                if (!self.check(.Fn) and !self.check(.Const)) {
                    self.current = member_checkpoint;
                    member_is_pub = false;
                    member_is_inline = false;
                }
            }

            // Associated `const` declaration. We skip-parse for now —
            // mirrors the struct-body handling. The body still type-
            // checks; future work can promote these to first-class
            // enum-namespaced symbols.
            if (self.match(&.{.Const})) {
                try self.skipNestedConstDecl();
                continue;
            }

            // Method declaration.
            if (self.match(&.{.Fn})) {
                if (self.functionDeclaration(false, false)) |method_stmt| {
                    switch (method_stmt) {
                        .FnDecl => |fn_decl| {
                            if (member_is_pub) fn_decl.is_public = true;
                            if (member_is_inline) fn_decl.is_inline = true;
                            try methods.append(self.allocator, fn_decl);
                        },
                        else => {
                            try self.reportError("Expected function declaration in enum");
                            return error.UnexpectedToken;
                        },
                    }
                } else |err| {
                    if (err == error.OutOfMemory) return err;
                    // Synchronize: skip to next `fn` or to the closing
                    // brace of the enum body. Mirrors structDeclarationWithName.
                    var brace_depth: i32 = 0;
                    while (!self.isAtEnd()) {
                        const tok = self.peek();
                        if (tok.type == .LeftBrace) {
                            brace_depth += 1;
                        } else if (tok.type == .RightBrace) {
                            if (brace_depth == 0) break;
                            brace_depth -= 1;
                        } else if (tok.type == .Fn and brace_depth == 0) {
                            break;
                        }
                        _ = self.advance();
                    }
                }
                continue;
            }

            // Otherwise: a variant declaration.
            const variant_name = try self.expect(.Identifier, "Expected variant name");

            // Check for associated data type
            var data_type: ?[]const u8 = null;
            if (self.match(&.{.LeftParen})) {
                // Accept any type annotation, not just bare identifiers,
                // so `Some([u8])`, `Err(&str)`, etc. all work.
                const type_str = try self.parseTypeAnnotation();
                data_type = type_str;
                _ = try self.expect(.RightParen, "Expected ')' after variant data type");
            }

            // Check for explicit value assignment (e.g., RED = 0)
            var value: ?i64 = null;
            if (self.match(&.{.Equal})) {
                // Parse integer literal for value
                if (self.match(&.{.Integer})) {
                    const value_token = self.previous();
                    value = std.fmt.parseInt(i64, value_token.lexeme, 10) catch null;
                } else if (self.match(&.{.Minus})) {
                    // Handle negative values
                    if (self.match(&.{.Integer})) {
                        const value_token = self.previous();
                        if (std.fmt.parseInt(i64, value_token.lexeme, 10)) |v| {
                            value = -v;
                        } else |_| {}
                    }
                }
            }

            try variants.append(self.allocator, .{
                .name = variant_name.lexeme,
                .data_type = data_type,
                .value = value,
            });

            // Optional comma between variants
            _ = self.match(&.{.Comma});

            // Progress guard — every iteration must consume at least
            // one token. Mirrors the struct-body loop.
            if (self.current == iter_start) {
                try self.reportError("Parser made no progress in enum body");
                return error.UnexpectedToken;
            }
        }

        _ = try self.expect(.RightBrace, "Expected '}' after enum variants");

        const variants_slice = try variants.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(variants_slice);

        const methods_slice = try methods.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(methods_slice);

        const enum_decl = if (methods_slice.len > 0)
            try ast.EnumDecl.initWithMethods(
                self.allocator,
                name,
                variants_slice,
                methods_slice,
                ast.SourceLocation.fromToken(enum_token),
            )
        else
            try ast.EnumDecl.init(
                self.allocator,
                name,
                variants_slice,
                ast.SourceLocation.fromToken(enum_token),
            );
        enum_decl.tag_type = tag_type;

        return ast.Stmt{ .EnumDecl = enum_decl };
    }

    /// Parse a union declaration
    fn unionDeclaration(self: *Parser) !ast.Stmt {
        return self.unionDeclarationWithName(null);
    }

    fn unionDeclarationWithName(self: *Parser, bound_name: ?[]const u8) !ast.Stmt {
        const union_token = self.previous();
        const name = if (bound_name) |bn| bn else blk: {
            const name_token = try self.expect(.Identifier, "Expected union name");
            break :blk name_token.lexeme;
        };

        // Zig-style tagged union annotation: `union(enum)` or
        // `union(TagType)`. Currently consumed and discarded so the
        // parser stays unblocked; full tag-type information is not yet
        // threaded onto the AST.
        if (self.match(&.{.LeftParen})) {
            if (self.match(&.{.Enum})) {
                // `union(enum)` form
            } else {
                const tt = try self.parseTypeAnnotation();
                self.allocator.free(tt);
            }
            _ = try self.expect(.RightParen, "Expected ')' after union tag specifier");
        }

        _ = try self.expect(.LeftBrace, "Expected '{' after union name");

        var variants = std.ArrayList(ast.UnionVariant).empty;
        defer variants.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            // Skip doc comments inside union body.
            while (self.match(&.{.DocComment})) {}
            // Optional `pub` modifier — applies to the next variant or
            // method declaration.
            const had_pub = self.match(&.{.Pub});
            _ = had_pub;

            // Methods inside the union body — `fn name(...)` or
            // `comptime fn ...`. Skip the entire declaration so the
            // variant loop continues; methods are not yet threaded onto
            // the UnionDecl AST node.
            if (self.check(.Fn) or self.check(.Comptime)) {
                _ = self.match(&.{.Comptime});
                _ = try self.expect(.Fn, "Expected 'fn' for union method");
                _ = try self.expect(.Identifier, "Expected method name");
                // Walk paren-balanced signature.
                _ = try self.expect(.LeftParen, "Expected '(' after method name");
                var pdepth: i32 = 1;
                while (pdepth > 0 and !self.isAtEnd()) {
                    const tt = self.advance().type;
                    if (tt == .LeftParen) pdepth += 1 else if (tt == .RightParen) pdepth -= 1;
                }
                // Walk to opening `{` of the body, then balance braces.
                while (!self.check(.LeftBrace) and !self.isAtEnd()) _ = self.advance();
                if (self.match(&.{.LeftBrace})) {
                    var bdepth: i32 = 1;
                    while (bdepth > 0 and !self.isAtEnd()) {
                        const tt = self.advance().type;
                        if (tt == .LeftBrace) bdepth += 1 else if (tt == .RightBrace) bdepth -= 1;
                    }
                }
                _ = self.match(&.{.Comma});
                continue;
            }

            const variant_name = try self.expect(.Identifier, "Expected variant name");

            // Check for associated data type. Two forms accepted:
            //   `Variant(Type)`        — Rust-style tuple variant
            //   `field_name: Type`     — Zig-style named field
            var type_name: ?[]const u8 = null;
            if (self.match(&.{.LeftParen})) {
                const inner = try self.parseTypeAnnotation();
                type_name = inner;
                _ = try self.expect(.RightParen, "Expected ')' after variant data type");
            } else if (self.match(&.{.Colon})) {
                const inner = try self.parseTypeAnnotation();
                type_name = inner;
            }

            try variants.append(self.allocator, .{
                .name = variant_name.lexeme,
                .type_name = type_name,
            });

            // Optional comma between variants
            _ = self.match(&.{.Comma});
        }

        _ = try self.expect(.RightBrace, "Expected '}' after union variants");

        const variants_slice = try variants.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(variants_slice);

        const union_decl = try ast.UnionDecl.init(
            self.allocator,
            name,
            variants_slice,
            ast.SourceLocation.fromToken(union_token),
        );

        return ast.Stmt{ .UnionDecl = union_decl };
    }

    /// Parse a type alias declaration
    fn typeAliasDeclaration(self: *Parser) !ast.Stmt {
        const type_token = self.previous();
        const name_token = try self.expect(.Identifier, "Expected type alias name");
        const name = name_token.lexeme;

        _ = try self.expect(.Equal, "Expected '=' after type alias name");

        // Check if this is a function type alias: type Foo = fn(...)
        var target_type: []const u8 = undefined;
        // Tracks whether `target_type` is heap-owned (must be freed by the
        // AST deinit) vs. a token lexeme / string literal (lifetime owned
        // elsewhere). Mirrors the discriminator on TypeAliasDecl.
        var target_owned: bool = false;
        if (self.check(.Fn)) {
            // Parse function type: fn(params): return_type
            _ = self.advance(); // consume 'fn'
            _ = try self.expect(.LeftParen, "Expected '(' after 'fn' in function type");

            // Skip parameter list - we just need to get past this for now
            var paren_depth: usize = 1;
            while (paren_depth > 0 and !self.isAtEnd()) {
                if (self.check(.LeftParen)) {
                    paren_depth += 1;
                } else if (self.check(.RightParen)) {
                    paren_depth -= 1;
                }
                if (paren_depth > 0) _ = self.advance();
            }
            _ = try self.expect(.RightParen, "Expected ')' after function parameters");

            // Optional return type after ':'
            if (self.match(&.{.Colon})) {
                // Skip the return type
                _ = self.advance(); // consume return type identifier
            }

            // Store as "fn" to indicate function type - actual type will be handled by type system
            target_type = "fn";
        } else if (self.check(.LeftParen)) {
            // Parse tuple type: (T1, T2, ...)
            _ = self.advance(); // consume '('
            var tuple_str = std.ArrayList(u8).empty;
            defer tuple_str.deinit(self.allocator);
            try tuple_str.append(self.allocator, '(');

            var first = true;
            while (!self.check(.RightParen) and !self.isAtEnd()) {
                if (!first) {
                    try tuple_str.appendSlice(self.allocator, ", ");
                }
                first = false;

                // Parse type (could be identifier or nested tuple/array)
                const type_str = try self.parseTypeString();
                try tuple_str.appendSlice(self.allocator, type_str);

                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.expect(.RightParen, "Expected ')' after tuple type");
            try tuple_str.append(self.allocator, ')');
            target_type = try tuple_str.toOwnedSlice(self.allocator);
            target_owned = true;
        } else if (self.check(.LeftBracket)) {
            // Parse array type: [T] or [T; N]
            _ = self.advance(); // consume '['
            var arr_str = std.ArrayList(u8).empty;
            defer arr_str.deinit(self.allocator);
            try arr_str.append(self.allocator, '[');

            const elem_type = try self.parseTypeString();
            try arr_str.appendSlice(self.allocator, elem_type);

            // Check for fixed-size array [T; N]
            if (self.match(&.{.Semicolon})) {
                try arr_str.appendSlice(self.allocator, "; ");
                const size_token = try self.expect(.Integer, "Expected array size");
                try arr_str.appendSlice(self.allocator, size_token.lexeme);
            }

            _ = try self.expect(.RightBracket, "Expected ']' after array type");
            try arr_str.append(self.allocator, ']');
            target_type = try arr_str.toOwnedSlice(self.allocator);
            target_owned = true;
        } else {
            const target_type_token = try self.expect(.Identifier, "Expected target type");
            target_type = target_type_token.lexeme;
        }

        const type_alias_decl = if (target_owned)
            try ast.TypeAliasDecl.initOwned(
                self.allocator,
                name,
                target_type,
                ast.SourceLocation.fromToken(type_token),
            )
        else
            try ast.TypeAliasDecl.init(
                self.allocator,
                name,
                target_type,
                ast.SourceLocation.fromToken(type_token),
            );

        return ast.Stmt{ .TypeAliasDecl = type_alias_decl };
    }

    /// Parse a type string for type alias (handles identifiers, tuples, arrays)
    fn parseTypeString(self: *Parser) ![]const u8 {
        if (self.check(.LeftParen)) {
            // Tuple type
            _ = self.advance();
            var result = std.ArrayList(u8).empty;
            defer result.deinit(self.allocator);
            try result.append(self.allocator, '(');

            var first = true;
            while (!self.check(.RightParen) and !self.isAtEnd()) {
                if (!first) try result.appendSlice(self.allocator, ", ");
                first = false;
                const inner = try self.parseTypeString();
                try result.appendSlice(self.allocator, inner);
                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.expect(.RightParen, "Expected ')' in tuple type");
            try result.append(self.allocator, ')');
            return try result.toOwnedSlice(self.allocator);
        } else if (self.check(.LeftBracket)) {
            // Array type
            _ = self.advance();
            var result = std.ArrayList(u8).empty;
            defer result.deinit(self.allocator);
            try result.append(self.allocator, '[');
            const inner = try self.parseTypeString();
            try result.appendSlice(self.allocator, inner);
            if (self.match(&.{.Semicolon})) {
                try result.appendSlice(self.allocator, "; ");
                const size = try self.expect(.Integer, "Expected array size");
                try result.appendSlice(self.allocator, size.lexeme);
            }
            _ = try self.expect(.RightBracket, "Expected ']' in array type");
            try result.append(self.allocator, ']');
            return try result.toOwnedSlice(self.allocator);
        } else {
            // Simple identifier type
            const tok = try self.expect(.Identifier, "Expected type name");
            return tok.lexeme;
        }
    }

    /// Parse an import declaration
    /// Syntax:
    ///   import basics/os/serial                       (slash-path form)
    ///   import basics/os/serial { init, COM1 }        (selective)
    ///   import "relative/path/to/file.home" as alias  (string-path form)
    fn importDeclaration(self: *Parser) !ast.Stmt {
        const import_token = self.previous();

        // Parse module path (e.g., basics/os/serial)
        var path_segments = std.ArrayList([]const u8).empty;
        defer path_segments.deinit(self.allocator);

        // TS-style `from` alias: `import name from "path"`.
        // The leading identifier becomes the import alias and the
        // string literal supplies the path.
        var ts_alias: ?[]const u8 = null;

        // String-path form: `import "path/to/file.home" as alias`.
        // Path comes in as a single literal; subsequent `as` aliasing
        // is handled at the bottom of this function.
        if (self.check(.String)) {
            const str_tok = self.advance();
            // Strip surrounding quotes from the lexeme if present.
            var lex = str_tok.lexeme;
            if (lex.len >= 2 and lex[0] == '"' and lex[lex.len - 1] == '"') {
                lex = lex[1 .. lex.len - 1];
            }
            try path_segments.append(self.allocator, lex);
        } else {
            // First segment
            const first_token = try self.expect(.Identifier, "Expected module name after 'import'");

            // TS-style `import name from "path"` — when the next
            // identifier is the soft keyword `from` followed by a
            // string literal, treat the first identifier as the alias
            // and the string literal as the module path. This matches
            // the form used pervasively in home-os kernel code.
            if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "from")) {
                _ = self.advance(); // consume `from`
                if (self.check(.String)) {
                    const str_tok = self.advance();
                    var lex = str_tok.lexeme;
                    if (lex.len >= 2 and lex[0] == '"' and lex[lex.len - 1] == '"') {
                        lex = lex[1 .. lex.len - 1];
                    }
                    try path_segments.append(self.allocator, lex);
                    ts_alias = first_token.lexeme;
                } else {
                    try self.reportError("Expected string literal after 'from'");
                    try path_segments.append(self.allocator, first_token.lexeme);
                }
            } else {
                try path_segments.append(self.allocator, first_token.lexeme);

                // Additional segments separated by '/'
                while (self.match(&.{.Slash})) {
                    const segment_token = try self.expect(.Identifier, "Expected module name after '/'");
                    try path_segments.append(self.allocator, segment_token.lexeme);
                }
            }
        }

        const path = try path_segments.toOwnedSlice(self.allocator);

        // Resolve the module using the module resolver. If resolution
        // fails we still emit an ImportDecl (with alias) into the AST
        // so downstream type-checking can register the alias as an
        // opaque namespace. Previously a missing module would abort
        // parsing of the file and silently drop any uses of the
        // alias, leading to "Undefined variable" noise everywhere.
        var resolution_failed = false;
        const resolved_module = self.module_resolver.resolve(path) catch |err| blk: {
            resolution_failed = true;
            const path_str = try self.pathToString(path);
            defer self.allocator.free(path_str);

            const err_msg = switch (err) {
                error.ModuleNotFound => try std.fmt.allocPrint(
                    self.allocator,
                    "Module '{s}' not found",
                    .{path_str},
                ),
                error.InvalidModulePath => try std.fmt.allocPrint(
                    self.allocator,
                    "Invalid module path '{s}'",
                    .{path_str},
                ),
                error.CircularDependency => try std.fmt.allocPrint(
                    self.allocator,
                    "Circular dependency detected for module '{s}'",
                    .{path_str},
                ),
                else => try std.fmt.allocPrint(
                    self.allocator,
                    "Failed to resolve module '{s}': {s}",
                    .{ path_str, @errorName(err) },
                ),
            };
            defer self.allocator.free(err_msg);
            try self.reportError(err_msg);
            break :blk module_resolver.ResolvedModule{
                .path = path,
                .file_path = try self.allocator.dupe(u8, path_str),
                .name = if (path.len > 0) path[path.len - 1] else "unknown",
                .is_zig = false,
            };
        };

        // Register the module in the symbol table
        const module_path_str = try self.pathToString(path);
        defer self.allocator.free(module_path_str);

        if (!resolution_failed) {
            try self.symbol_table.registerModule(path, resolved_module.is_zig, null);
        }

        // Populate symbols based on module type
        if (!resolution_failed and resolved_module.is_zig) {
            // Zig module - use predefined symbols
            try self.symbol_table.populateZigModuleSymbols(module_path_str);
        }
        // Note: Home module symbol population disabled temporarily due to hashmap issue
        // Symbol validation will be done at type checking phase

        // Parse optional selective import list: { item1, item2, ... }
        var imports: ?[]const []const u8 = null;
        // Only support "import path { items }" - NOT Rust-style "import path::{ items }"
        if (self.match(&.{.LeftBrace})) {
            var import_list = std.ArrayList([]const u8).empty;
            defer import_list.deinit(self.allocator);

            // Parse first import
            if (!self.check(.RightBrace)) {
                const first_import = try self.expect(.Identifier, "Expected identifier in import list");
                try import_list.append(self.allocator, first_import.lexeme);

                // Parse remaining imports
                while (self.match(&.{.Comma})) {
                    // Allow trailing comma
                    if (self.check(.RightBrace)) break;

                    const import_name = try self.expect(.Identifier, "Expected identifier after ','");
                    try import_list.append(self.allocator, import_name.lexeme);
                }
            }

            _ = try self.expect(.RightBrace, "Expected '}' after import list");

            // Register selective imports (symbol validation is done at type checking phase)
            // Just record the imports without verifying they exist
            imports = try import_list.toOwnedSlice(self.allocator);
        }

        // Parse optional alias: `import path/to/module as Alias`. Already
        // captured for TS-style `import name from "path"` form above.
        var alias: ?[]const u8 = ts_alias;
        if (self.match(&.{.As})) {
            const alias_token = try self.expect(.Identifier, "Expected identifier after 'as'");
            alias = alias_token.lexeme;
        }

        const decl = try ast.ImportDecl.init(
            self.allocator,
            path,
            imports,
            alias,
            ast.SourceLocation.fromToken(import_token),
        );

        return ast.Stmt{ .ImportDecl = decl };
    }

    /// Parse a type annotation (supports arrays, generics, nullable, etc.)
    pub fn parseTypeAnnotation(self: *Parser) ![]const u8 {
        // Check for mut type modifier: mut T
        if (self.match(&.{.Mut})) {
            const inner_type = try self.parseTypeAnnotation();
            defer self.allocator.free(inner_type);
            return try std.fmt.allocPrint(self.allocator, "mut {s}", .{inner_type});
        }

        // `readonly T` — TS-style readonly modifier on object/array types.
        // Encoded as the textual prefix "readonly ", consumed by the type
        // checker via Readonly<T>-style transformations.
        if (self.match(&.{.Readonly})) {
            const inner_type = try self.parseTypeAnnotation();
            defer self.allocator.free(inner_type);
            return try std.fmt.allocPrint(self.allocator, "readonly {s}", .{inner_type});
        }

        // `keyof T` — yields the union of property names of T.
        if (self.match(&.{.Keyof})) {
            const inner_type = try self.parseTypeAnnotation();
            defer self.allocator.free(inner_type);
            return try std.fmt.allocPrint(self.allocator, "keyof {s}", .{inner_type});
        }

        // `typeof expr` — yields the static type of an expression / value.
        // Only an identifier expression is accepted in type position; complex
        // expressions remain available via the existing `@TypeOf(expr)` builtin.
        if (self.match(&.{.Typeof})) {
            const tok = try self.expect(.Identifier, "Expected identifier after 'typeof'");
            return try std.fmt.allocPrint(self.allocator, "typeof {s}", .{tok.lexeme});
        }

        // `infer U` — only meaningful inside a conditional type's `extends`
        // branch. We accept it here for forward compatibility so that types
        // like `T extends Promise<infer U> ? U : never` round-trip through
        // the parser today even though the type checker may not yet bind U.
        if (self.match(&.{.Infer})) {
            const tok = try self.expect(.Identifier, "Expected type variable name after 'infer'");
            return try std.fmt.allocPrint(self.allocator, "infer {s}", .{tok.lexeme});
        }

        // `async T` return-type modifier. Semantically this means "Future<T>".
        // An async fn already produces a Future header under the hood, so we
        // treat the annotation as transparent and return the inner type.
        // Bare `async` (no inner type) is a shorthand for `async void`.
        if (self.match(&.{.Async})) {
            // If the next token starts a block or end-of-declaration, the
            // user wrote just `async` — treat as `async void`.
            const next_t = self.peek().type;
            if (next_t == .LeftBrace or next_t == .Semicolon or
                next_t == .RightParen or next_t == .Comma)
            {
                return try self.allocator.dupe(u8, "void");
            }
            const inner = try self.parseTypeAnnotation();
            return inner;
        }

        // Check for unit type () or tuple type (T1, T2, ...)
        if (self.match(&.{.LeftParen})) {
            // Check for unit type ()
            if (self.check(.RightParen)) {
                _ = self.advance(); // consume )
                return try self.allocator.dupe(u8, "()");
            }

            // Parse tuple types (T1, T2, ...)
            var types = std.ArrayList([]const u8).empty;
            defer {
                for (types.items) |elem_type| self.allocator.free(elem_type);
                types.deinit(self.allocator);
            }

            while (!self.check(.RightParen) and !self.isAtEnd()) {
                const elem_type = try self.parseTypeAnnotation();
                try types.append(self.allocator, elem_type);

                if (!self.match(&.{.Comma})) break;
            }

            _ = try self.expect(.RightParen, "Expected ')' for tuple type");

            // Build tuple type string
            var result = std.ArrayList(u8).empty;
            defer result.deinit(self.allocator);
            try result.append(self.allocator, '(');
            for (types.items, 0..) |t, i| {
                if (i > 0) {
                    try result.appendSlice(self.allocator, ", ");
                }
                try result.appendSlice(self.allocator, t);
            }
            try result.append(self.allocator, ')');
            return try self.allocator.dupe(u8, result.items);
        }

        // Check for function type: fn(T1, T2) ReturnType.
        // Both unnamed (`fn(u64, u32) bool`) and named
        // (`fn(lba: u64, count: u32) bool`) parameter forms are accepted —
        // names are parsed and discarded since the type encoding only
        // needs parameter types.
        if (self.match(&.{.Fn})) {
            _ = try self.expect(.LeftParen, "Expected '(' after 'fn' in function type");

            var param_types = std.ArrayList([]const u8).empty;
            // Each param type is a heap-allocated slice from a recursive
            // `parseTypeAnnotation` — free them after the encoded
            // function-type string has been built so they don't leak.
            defer {
                for (param_types.items) |t| self.allocator.free(t);
                param_types.deinit(self.allocator);
            }

            while (!self.check(.RightParen) and !self.isAtEnd()) {
                // Optional parameter name: `name: T`. Detected by an
                // Identifier (or soft-keyword binding name) followed by
                // `:` — both must be present so a bare identifier in
                // type position (e.g. `fn(MyType) bool`) keeps parsing
                // as a type.
                if (self.check(.Identifier) and self.peekNext().type == .Colon) {
                    _ = self.advance(); // consume name
                    _ = self.advance(); // consume ':'
                }

                const param_type = try self.parseTypeAnnotation();
                try param_types.append(self.allocator, param_type);

                if (!self.match(&.{.Comma})) break;
            }

            _ = try self.expect(.RightParen, "Expected ')' in function type");

            // Parse optional return type. Accept `: T`, `-> T`, OR
            // Zig-style `fn(...) T` with no separator before the type.
            // The token-class probe also covers prefix-style type
            // starters (`?T`, `*T`, `&T`, `[T]`, `!T`) so kernel
            // signatures like `fn(...) ?*Foo` parse cleanly.
            var return_type: []const u8 = "()";
            var return_type_owned: bool = false;
            if (self.match(&.{.Colon}) or self.match(&.{.Arrow})) {
                return_type = try self.parseTypeAnnotation();
                return_type_owned = true;
            } else if (self.isReturnTypeStart()) {
                return_type = try self.parseTypeAnnotation();
                return_type_owned = true;
            }
            defer if (return_type_owned) self.allocator.free(return_type);

            // Build function type string: fn(T1, T2): ReturnType
            var result = std.ArrayList(u8).empty;
            defer result.deinit(self.allocator);
            try result.appendSlice(self.allocator, "fn(");
            for (param_types.items, 0..) |t, i| {
                if (i > 0) {
                    try result.appendSlice(self.allocator, ", ");
                }
                try result.appendSlice(self.allocator, t);
            }
            try result.appendSlice(self.allocator, "): ");
            try result.appendSlice(self.allocator, return_type);
            return try self.allocator.dupe(u8, result.items);
        }

        // Anonymous struct type in type position:
        //   `struct { f1: T1, f2: T2, ... }`
        // Surfaces in return-type slots (`fn getCursor(): struct { x: usize, y: usize } { ... }`)
        // and `let x: struct { ... } = .{...}` annotations. The fields are
        // collected and re-rendered as a textual encoding so the existing
        // string-based `return_type` slot on `FnDecl` keeps working without
        // an AST migration. The type checker currently falls through to
        // `Type.Void` for unknown struct{...} strings, which is enough for
        // the kernel `home check` path that just needs a clean parse. (#46)
        if (self.match(&.{.Struct})) {
            _ = try self.expect(.LeftBrace, "Expected '{' after 'struct' in type position");
            var fields = std.ArrayList(u8).empty;
            defer fields.deinit(self.allocator);
            var first = true;
            while (!self.check(.RightBrace) and !self.isAtEnd()) {
                const name_tok = try self.expect(.Identifier, "Expected field name in anonymous struct type");
                _ = try self.expect(.Colon, "Expected ':' after field name in anonymous struct type");
                const field_type = try self.parseTypeAnnotation();
                defer self.allocator.free(field_type);

                if (!first) try fields.appendSlice(self.allocator, ", ");
                first = false;
                try fields.appendSlice(self.allocator, name_tok.lexeme);
                try fields.appendSlice(self.allocator, ": ");
                try fields.appendSlice(self.allocator, field_type);

                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.expect(.RightBrace, "Expected '}' to close anonymous struct type");
            return try std.fmt.allocPrint(self.allocator, "struct {{ {s} }}", .{fields.items});
        }

        // Check for reference type: &T or &mut T
        if (self.match(&.{.Ampersand})) {
            const is_mut = self.match(&.{.Mut});
            const inner_type = try self.parseTypeAnnotation();
            defer self.allocator.free(inner_type);
            if (is_mut) {
                return try std.fmt.allocPrint(self.allocator, "&mut {s}", .{inner_type});
            } else {
                return try std.fmt.allocPrint(self.allocator, "&{s}", .{inner_type});
            }
        }

        // Check for nullable prefix: ?T. Recurses through the full
        // type-annotation grammar so any compound type expression is
        // accepted as the inner — slice (`?[]const u8`), fixed array
        // (`?[N]T`), pointer (`?*T`, `?*const T`), nested optional
        // (`?*?*T`), function pointer (`?fn(...) Ret`), etc. (Issue #57.)
        if (self.match(&.{.Question})) {
            const inner_type = try self.parseTypeAnnotation();
            defer self.allocator.free(inner_type);
            return try std.fmt.allocPrint(self.allocator, "?{s}", .{inner_type});
        }

        // `??T` — double optional. The lexer fuses two `?` characters into
        // a single `QuestionQuestion` token (used by null-coalescing in
        // expression position). In type position we re-split it into two
        // optional prefixes around an inner type. (Issue #57.)
        if (self.match(&.{.QuestionQuestion})) {
            const inner_type = try self.parseTypeAnnotation();
            defer self.allocator.free(inner_type);
            return try std.fmt.allocPrint(self.allocator, "??{s}", .{inner_type});
        }

        // Zig-style error-union sugar: `!T` desugars to `Result<T, AnyError>`.
        // The bang is treated as a type-position prefix only when it appears
        // here (i.e. where a type is expected); the unary `!` operator and
        // the macro-invocation `!` are parsed in expression position so this
        // does not conflict with either.
        if (self.match(&.{.Bang})) {
            const inner_type = try self.parseTypeAnnotation();
            defer self.allocator.free(inner_type);
            return try std.fmt.allocPrint(self.allocator, "Result<{s}, AnyError>", .{inner_type});
        }

        // Check for optional array type: ?[]T or ?[N]T (lexer combines ?[ into QuestionBracket).
        // Mirrors the `[]T` path below — accepts `const` / `volatile`
        // qualifiers on the pointee so `?[]const u8` and `?[]volatile u32`
        // parse cleanly. (Issue #57.)
        if (self.match(&.{.QuestionBracket})) {
            if (self.peek().type == .RightBracket) {
                // ?[]T - optional dynamic array (slice).
                _ = try self.expect(.RightBracket, "Expected ']'");
                _ = self.match(&.{.Const});
                if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "volatile")) {
                    _ = self.advance();
                }
                const elem_type = try self.parseTypeAnnotation();
                defer self.allocator.free(elem_type);
                return try std.fmt.allocPrint(self.allocator, "?[]{s}", .{elem_type});
            }

            // Check for ?[N]T syntax (optional fixed-size array). The element
            // type allows the same `const` / `volatile` qualifiers as `[N]T`.
            if (self.check(.Integer)) {
                const size_token = self.advance();
                _ = try self.expect(.RightBracket, "Expected ']' after array size");
                _ = self.match(&.{.Const});
                if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "volatile")) {
                    _ = self.advance();
                }
                const elem_type = try self.parseTypeAnnotation();
                defer self.allocator.free(elem_type);
                return try std.fmt.allocPrint(self.allocator, "?[{s}]{s}", .{ size_token.lexeme, elem_type });
            }

            // ?[T] - optional element type inside brackets
            const inner = try self.parseTypeAnnotation();
            defer self.allocator.free(inner);
            _ = try self.expect(.RightBracket, "Expected ']'");
            return try std.fmt.allocPrint(self.allocator, "?[{s}]", .{inner});
        }

        // `*?T` / `*?` chain — the lexer fuses `*?` into a single
        // `StarQuestion` token (used by saturating multiplication in
        // expression position). In type position we re-split it into a
        // pointer prefix followed by an optional. Surfaces in signatures
        // like `?*?*T` after the outer `?` is consumed: the recursive
        // call lands here on the next `*?`. (Issue #57.)
        if (self.match(&.{.StarQuestion})) {
            const inner_type = try self.parseTypeAnnotation();
            defer self.allocator.free(inner_type);
            return try std.fmt.allocPrint(self.allocator, "*?{s}", .{inner_type});
        }

        // Check for pointer type: *T, *const T, *volatile T, *const volatile T.
        // `volatile` qualifies the pointee the same way `const` does and is
        // required by kernel code that touches MMIO registers.
        //
        // Also handles `**T` (pointer-to-pointer) — the lexer collapses
        // two consecutive stars into a single StarStar token (for the
        // `a ** b` power operator), so in type position we treat
        // `StarStar` as two star prefixes before the inner type.
        if (self.match(&.{ .Star, .StarStar })) {
            const star_tok = self.previous();
            const is_double = star_tok.type == .StarStar;
            const is_const = self.match(&.{.Const});
            // `volatile` is a soft keyword here — accept either the reserved
            // token (if defined) or an Identifier with that lexeme.
            var is_volatile = false;
            if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "volatile")) {
                _ = self.advance();
                is_volatile = true;
            }
            // Reject `*volatile const` — the correct order is `*const volatile`.
            if (is_volatile and !is_const and self.check(.Const)) {
                try self.reportError("Invalid pointer qualifier order: use '*const volatile' instead of '*volatile const'");
                return error.UnexpectedToken;
            }
            const inner_type = try self.parseTypeAnnotation();
            defer self.allocator.free(inner_type);
            const base = if (is_const and is_volatile)
                try std.fmt.allocPrint(self.allocator, "*const volatile {s}", .{inner_type})
            else if (is_const)
                try std.fmt.allocPrint(self.allocator, "*const {s}", .{inner_type})
            else if (is_volatile)
                try std.fmt.allocPrint(self.allocator, "*volatile {s}", .{inner_type})
            else
                try std.fmt.allocPrint(self.allocator, "*{s}", .{inner_type});
            if (is_double) {
                defer self.allocator.free(base);
                return try std.fmt.allocPrint(self.allocator, "*{s}", .{base});
            }
            return base;
        }

        // Check for array type: [T], [T; N], [N]T, or []T.
        // Also handles `[*]T` — Zig-style many-item pointer used in
        // kernel FFI signatures (pointer to unknown-length array).
        if (self.match(&.{.LeftBracket})) {
            // Only treat `[*` as the start of a many-pointer when the
            // very next token is `]`. Otherwise the `*` belongs to a
            // pointer element type — e.g. `[*Entry; 512]` is an array
            // of 512 pointers to `Entry`, not a many-pointer.
            if (self.peek().type == .Star and self.peekNext().type == .RightBracket) {
                _ = self.advance(); // consume `*`
                _ = try self.expect(.RightBracket, "Expected ']' after [*");
                // Optional `const` / `volatile` qualifiers on the
                // pointee, matching the `[]T` form below. Kernel FFI
                // signatures routinely use `[*]const u8` for byte
                // strings and `[*]volatile T` for MMIO regions.
                _ = self.match(&.{.Const});
                if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "volatile")) {
                    _ = self.advance();
                }
                const elem_type = try self.parseTypeAnnotation();
                defer self.allocator.free(elem_type);
                return try std.fmt.allocPrint(self.allocator, "[*]{s}", .{elem_type});
            }
            if (self.peek().type == .RightBracket) {
                // Empty brackets: `[]T`, `[]const T`, or `[]volatile T`.
                _ = try self.expect(.RightBracket, "Expected ']'");
                _ = self.match(&.{.Const});
                if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "volatile")) {
                    _ = self.advance();
                }
                const elem_type = try self.parseTypeAnnotation();
                defer self.allocator.free(elem_type);
                const arr_type = try std.fmt.allocPrint(self.allocator, "[]{s}", .{elem_type});
                return arr_type;
            }

            // Check for [N]T syntax (size followed by ]T)
            if (self.check(.Integer)) {
                const size_token = self.advance();
                _ = try self.expect(.RightBracket, "Expected ']' after array size");
                const elem_type = try self.parseTypeAnnotation();
                defer self.allocator.free(elem_type);
                const arr_type = try std.fmt.allocPrint(self.allocator, "[{s}]{s}", .{ size_token.lexeme, elem_type });
                return arr_type;
            }

            // Check for [IDENT]T syntax where IDENT is a constant name,
            // e.g. `[MAX_QUEUES]RequestQueue`. Also handles dotted
            // qualifiers — `[mod.MAX]u64` and longer chains like
            // `[a.b.c.MAX]u64` — by walking `.` tokens between
            // identifiers. Falls back to the more general
            // "lex-and-collect" path below for compound size
            // expressions like `[MAX / 8]u8` or `[count * 2]T`.
            // Disambiguate from `[T]` by looking at the token
            // immediately past the `]`: if it could start a type,
            // treat as size-then-element form.
            if (self.check(.Identifier)) {
                const save = self.current;
                const head_tok = self.advance();
                var size_buf = std.ArrayList(u8).empty;
                defer size_buf.deinit(self.allocator);
                try size_buf.appendSlice(self.allocator, head_tok.lexeme);

                var path_ok = true;
                while (self.check(.Dot) or self.check(.ColonColon)) {
                    _ = self.advance();
                    if (!self.check(.Identifier)) {
                        path_ok = false;
                        break;
                    }
                    const next_tok = self.advance();
                    try size_buf.append(self.allocator, '.');
                    try size_buf.appendSlice(self.allocator, next_tok.lexeme);
                }

                if (path_ok and self.check(.RightBracket)) {
                    _ = self.advance();
                    const nt = self.peek().type;
                    const looks_like_type =
                        nt == .Identifier or nt == .Star or nt == .StarStar or
                        nt == .LeftBracket or nt == .Question or nt == .Ampersand;
                    if (looks_like_type) {
                        const elem_type = try self.parseTypeAnnotation();
                        defer self.allocator.free(elem_type);
                        return try std.fmt.allocPrint(self.allocator, "[{s}]{s}", .{ size_buf.items, elem_type });
                    }
                    // `[T]` form with T being the qualified identifier
                    // we consumed.
                    return try std.fmt.allocPrint(self.allocator, "[{s}]", .{size_buf.items});
                }
                // Not a simple identifier-or-qualified-path size — rewind
                // and try the lex-and-collect fallback for compound
                // expressions before giving up.
                self.current = save;
            }

            // Fallback for compound size expressions inside `[...]`,
            // e.g. `[N / 8]u8`, `[count * 2]T`, or `[base + 1]u32`.
            // Collect raw tokens until the matching `]`, then commit
            // only if the next token after `]` looks like the start
            // of a type. Otherwise rewind and let the `[T]` /
            // `[T; N]` generic path below handle it.
            //
            // Bail if we encounter a `;` before the matching `]` —
            // that means this is the Zig-style element-first form
            // `[T; N]`, which the dedicated code path below handles
            // correctly. Without this guard the fallback greedily
            // collects `T ; N` as the "size", producing nonsense
            // types and silently swallowing the next statement as
            // the element type. (Issue #35.)
            if (self.check(.Identifier) or self.check(.Integer) or self.check(.LeftParen)) {
                const save = self.current;
                var depth: i32 = 1;
                var saw_semicolon = false;
                var size_buf = std.ArrayList(u8).empty;
                defer size_buf.deinit(self.allocator);
                while (depth > 0 and !self.isAtEnd()) {
                    const tok = self.peek();
                    if (tok.type == .LeftBracket) depth += 1;
                    if (tok.type == .RightBracket) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    if (tok.type == .Semicolon and depth == 1) {
                        saw_semicolon = true;
                    }
                    if (size_buf.items.len > 0) {
                        try size_buf.append(self.allocator, ' ');
                    }
                    try size_buf.appendSlice(self.allocator, tok.lexeme);
                    _ = self.advance();
                }
                if (!saw_semicolon and depth == 0 and self.check(.RightBracket)) {
                    _ = self.advance();
                    const nt = self.peek().type;
                    // Reject the size-element interpretation when the
                    // next token is on a new line — it's the next
                    // statement, not the element type. Also reject
                    // `align` (a soft keyword that introduces an
                    // alignment qualifier on the var declaration).
                    // Both surfaced as silent-drop bugs in #35.
                    const next_is_align = nt == .Identifier and
                        std.mem.eql(u8, self.peek().lexeme, "align");
                    const looks_like_type = (nt == .Identifier or nt == .Star or nt == .StarStar or
                        nt == .LeftBracket or nt == .Question or nt == .Ampersand) and
                        !self.isAtNewLine() and !next_is_align;
                    if (looks_like_type and size_buf.items.len > 0) {
                        const elem_type = try self.parseTypeAnnotation();
                        defer self.allocator.free(elem_type);
                        return try std.fmt.allocPrint(self.allocator, "[{s}]{s}", .{ size_buf.items, elem_type });
                    }
                }
                self.current = save;
            }

            // Has something inside brackets - either [T] or [T; N]
            const inner = try self.parseTypeAnnotation();
            defer self.allocator.free(inner);

            // Check for semicolon (fixed-size array: [T; N])
            if (self.match(&.{.Semicolon})) {
                // Parse the size - can be any expression (constant, cast, etc.)
                // Collect tokens until we hit ]
                var size_tokens = std.ArrayList(u8).empty;
                defer size_tokens.deinit(self.allocator);

                while (!self.check(.RightBracket) and !self.isAtEnd()) {
                    const tok = self.advance();
                    if (size_tokens.items.len > 0) {
                        try size_tokens.append(self.allocator, ' ');
                    }
                    for (tok.lexeme) |c| {
                        try size_tokens.append(self.allocator, c);
                    }
                }

                _ = try self.expect(.RightBracket, "Expected ']'");

                if (size_tokens.items.len == 0) {
                    try self.reportError("Expected array size after ';' in fixed-size array type");
                    return error.UnexpectedToken;
                }

                const size_lexeme = try size_tokens.toOwnedSlice(self.allocator);
                defer self.allocator.free(size_lexeme);
                // Return [T; N] as string
                const arr_type = try std.fmt.allocPrint(self.allocator, "[{s}; {s}]", .{ inner, size_lexeme });
                return arr_type;
            }

            // Just [T] - element type inside brackets
            _ = try self.expect(.RightBracket, "Expected ']'");
            const arr_type = try std.fmt.allocPrint(self.allocator, "[{s}]", .{inner});
            return arr_type;
        }

        // Check for Self type (refers to the current impl type)
        if (self.match(&.{.SelfType})) {
            return try self.allocator.dupe(u8, "Self");
        }

        // The `type` keyword in type position — a Zig idiom for `comptime
        // T: type` parameters meaning "T is itself a type". Spelled with
        // the .Type token, which the lexer reserves as a keyword.
        if (self.match(&.{.Type})) {
            return try self.allocator.dupe(u8, "type");
        }

        // Regular type (identifier, possibly with module path like std.fs.File)
        const type_token = try self.expect(.Identifier, "Expected type name");
        var result = try self.allocator.dupe(u8, type_token.lexeme);
        errdefer self.allocator.free(result);

        // Handle module path: foo.bar.Type (also accepts Rust-style `foo::bar::Type`)
        while (self.match(&.{ .Dot, .ColonColon })) {
            const next = try self.expect(.Identifier, "Expected type name after '.'");
            const new_result = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ result, next.lexeme });
            self.allocator.free(result);
            result = new_result;
        }

        // Check for generic type arguments: Type<Arg1, Arg2, ...>
        if (self.match(&.{.Less})) {
            var args = std.ArrayList([]const u8).empty;
            defer {
                for (args.items) |arg| self.allocator.free(arg);
                args.deinit(self.allocator);
            }

            while (!self.check(.Greater) and !self.check(.RightShift) and self.pending_greater == 0 and !self.isAtEnd()) {
                // Check if this is a const generic parameter (integer literal or identifier constant)
                const arg_type = if (self.check(.Integer) or self.check(.Float)) blk: {
                    // Const generic parameter (e.g., Array<T, 16>)
                    const lit_token = self.advance();
                    break :blk try self.allocator.dupe(u8, lit_token.lexeme);
                } else blk: {
                    // Regular type parameter
                    break :blk try self.parseTypeAnnotation();
                };
                try args.append(self.allocator, arg_type);

                if (!self.match(&.{.Comma})) break;
            }

            // Handle >, >>, and pending > from previous >> splits.
            // Uses a counter so A<B<C<D>>> (>>> = >> + >) works at any depth.
            if (self.check(.RightShift)) {
                self.pending_greater += 1;
                _ = self.advance(); // consume >>
            } else if (self.pending_greater > 0) {
                self.pending_greater -= 1;
            } else {
                _ = try self.expect(.Greater, "Expected '>' after generic type arguments");
            }

            // Build the full generic type string: "Type<Arg1, Arg2>"
            var full_type = std.ArrayList(u8).empty;
            defer full_type.deinit(self.allocator);
            try full_type.appendSlice(self.allocator, result);
            try full_type.append(self.allocator, '<');
            for (args.items, 0..) |arg, i| {
                if (i > 0) try full_type.appendSlice(self.allocator, ", ");
                try full_type.appendSlice(self.allocator, arg);
            }
            try full_type.append(self.allocator, '>');
            self.allocator.free(result);
            result = try full_type.toOwnedSlice(self.allocator);
        }

        // Check for nullable suffix: Type?
        if (self.match(&.{.Question})) {
            const nullable_type = try std.fmt.allocPrint(self.allocator, "{s}?", .{result});
            self.allocator.free(result);
            result = nullable_type;
        }

        // Zig-style postfix error-union: `ErrorSet!Payload`. After parsing
        // a complete type expression, if a `!` follows that itself looks
        // like the start of a type, consume it and recurse for the payload.
        // Encoded as `Result<Payload, ErrorSet>` to match the prefix `!T`
        // convention above (which encodes as `Result<T, AnyError>`). This
        // is only reached in type position — `parseTypeAnnotation` is
        // never called from expression position — so it does not
        // conflict with the unary `!` boolean-not operator. (Issue #61.)
        if (self.check(.Bang) and self.isReturnTypeStartAt(self.current + 1)) {
            _ = self.advance(); // consume `!`
            const payload = try self.parseTypeAnnotation();
            defer self.allocator.free(payload);
            const wrapped = try std.fmt.allocPrint(self.allocator, "Result<{s}, {s}>", .{ payload, result });
            self.allocator.free(result);
            result = wrapped;
        }

        return result;
    }

    /// Parse a let/const declaration
    fn letDeclaration(self: *Parser, is_const: bool) !ast.Stmt {
        _ = is_const;
        const is_mutable = self.match(&.{.Mut});

        // Check for tuple destructuring: let (a, b) = expr
        if (self.match(&.{.LeftParen})) {
            const start_token = self.previous();
            var names = std.ArrayList([]const u8).empty;
            defer names.deinit(self.allocator);

            // Parse first name
            const first_name = try self.expect(.Identifier, "Expected variable name in tuple destructure");
            try names.append(self.allocator, first_name.lexeme);

            // Parse remaining names
            while (self.match(&.{.Comma})) {
                const name = try self.expect(.Identifier, "Expected variable name in tuple destructure");
                try names.append(self.allocator, name.lexeme);
            }

            _ = try self.expect(.RightParen, "Expected ')' after tuple destructure");
            _ = try self.expect(.Equal, "Expected '=' after tuple destructure");

            const value = try self.expression();

            const names_slice = try self.allocator.alloc([]const u8, names.items.len);
            @memcpy(names_slice, names.items);

            const decl = try ast.TupleDestructureDecl.init(
                self.allocator,
                names_slice,
                value,
                is_mutable,
                ast.SourceLocation.fromToken(start_token),
            );

            try self.optionalSemicolon();
            return ast.Stmt{ .TupleDestructureDecl = decl };
        }

        // Accept Identifier or any contextual soft-keyword token as the
        // binding name (`let is = 1`, `let test = ...`, `let match = ...`).
        // Kernel code uses `match`, `type`, `default`, `is`, `test` etc.
        // as field or local variable names in contexts where the parser
        // can unambiguously disambiguate from the keyword form.
        const name_token = self.matchIdentifierLike() orelse blk: {
            try self.reportError("Expected variable name");
            break :blk self.previous(); // Return something to satisfy type system
        };

        // Optional type annotation
        var type_name: ?[]const u8 = null;
        if (self.match(&.{.Colon})) {
            type_name = try self.parseTypeAnnotation();
            // Optional alignment qualifier: `let x: T align(N) = ...`.
            // Currently we accept and discard the alignment; codegen
            // will eventually thread this through to data placement.
            try self.consumeOptionalAlignSuffix();
        }

        // Detect Zig-style anonymous type bindings:
        //   const Name = struct { ... }
        //   const Name = enum(u8) { ... }
        //   const Name = union { ... }
        //   const Name = packed struct { ... }
        //   const Name = extern struct { ... }
        // Treat these as if the user wrote `struct Name { ... }` etc.,
        // so downstream passes see a normal type declaration.
        if (type_name == null and self.check(.Equal)) {
            if (self.peekTypeBindingAfterEquals()) |kind| {
                _ = self.advance(); // consume '='
                return try self.parseAnonymousTypeBinding(kind, name_token.lexeme);
            }
        }

        // Function-type alias: `const Name = fn(...) Ret` or
        // `const Name = ?fn(...) Ret`. Routed through the same
        // type-expression entry point used by struct-field types and
        // variable annotations so the four parse positions share grammar.
        // Issue #51.
        if (type_name == null and self.peekFnTypeAliasAfterEquals()) {
            _ = self.advance(); // consume '='
            const target_type = try self.parseTypeAnnotation();
            const type_alias_decl = try ast.TypeAliasDecl.initOwned(
                self.allocator,
                name_token.lexeme,
                target_type,
                ast.SourceLocation.fromToken(name_token),
            );
            try self.optionalSemicolon();
            return ast.Stmt{ .TypeAliasDecl = type_alias_decl };
        }

        // Optional initializer
        var value: ?*ast.Expr = null;
        if (self.match(&.{.Equal})) {
            value = try self.expression();
        }

        const decl = try ast.LetDecl.init(
            self.allocator,
            name_token.lexeme,
            type_name,
            value,
            is_mutable,
            ast.SourceLocation.fromToken(name_token),
        );

        // Consume optional semicolon
        try self.optionalSemicolon();

        return ast.Stmt{ .LetDecl = decl };
    }

    /// Anonymous type binding kinds for `const Name = <kind> { ... }`.
    const AnonTypeKind = enum {
        Struct,
        PackedStruct,
        ExternStruct,
        Enum,
        Union,
        ErrorSet,
    };

    /// Peek past `=` to see if the initializer is an anonymous type
    /// definition (struct/enum/union/packed struct/extern struct).
    /// Returns null if it's an ordinary expression.
    fn peekTypeBindingAfterEquals(self: *Parser) ?AnonTypeKind {
        // We expect to be looking at `=` right now.
        if (!self.check(.Equal)) return null;
        // Peek the token after `=`.
        const next_idx = self.current + 1;
        if (next_idx >= self.tokens.len) return null;
        const next = self.tokens[next_idx];
        // `error { ... }` — error-set declaration. `error` is a soft
        // keyword (lexed as Identifier) so we match by lexeme. Followed
        // by `{` to disambiguate from any other identifier named
        // "error" (the lookahead requires a brace before committing).
        if (next.type == .Identifier and std.mem.eql(u8, next.lexeme, "error")) {
            const after = next_idx + 1;
            if (after < self.tokens.len and self.tokens[after].type == .LeftBrace) {
                return .ErrorSet;
            }
        }
        return switch (next.type) {
            .Struct => .Struct,
            .Enum => .Enum,
            .Union => .Union,
            .Packed => blk: {
                const after = next_idx + 1;
                if (after >= self.tokens.len) break :blk null;
                if (self.tokens[after].type == .Struct) break :blk .PackedStruct;
                break :blk null;
            },
            .Extern => blk: {
                const after = next_idx + 1;
                if (after >= self.tokens.len) break :blk null;
                if (self.tokens[after].type == .Struct) break :blk .ExternStruct;
                break :blk null;
            },
            else => null,
        };
    }

    /// True when the current parser position is `=` followed by a
    /// function-type expression: `fn(...)` or `?fn(...)`. Stacked `?`
    /// prefixes (e.g. `??fn(...)`) are accepted for forward
    /// compatibility — `parseTypeAnnotation` handles arbitrary nesting.
    /// Used by `letDeclaration` to route `const Name = fn(...) Ret` into
    /// the type-alias path. Issue #51.
    fn peekFnTypeAliasAfterEquals(self: *Parser) bool {
        if (!self.check(.Equal)) return false;
        var i: usize = self.current + 1;
        // Skip any number of `?` prefixes (`?fn`, `??fn`, etc.).
        while (i < self.tokens.len and self.tokens[i].type == .Question) : (i += 1) {}
        if (i >= self.tokens.len) return false;
        if (self.tokens[i].type != .Fn) return false;
        const after_fn = i + 1;
        if (after_fn >= self.tokens.len) return false;
        if (self.tokens[after_fn].type != .LeftParen) return false;

        // Disambiguate `const f = fn(...) Ret { body }` (lambda expression)
        // from `const Alias = fn(...) Ret` (function-type alias) by scanning
        // past the matching `)` and any return-type tokens. If we land on
        // `{`, treat the RHS as a lambda — return false so the caller
        // routes through expression() and `primary()` parses the lambda.
        var depth: i32 = 1;
        var j: usize = after_fn + 1;
        while (j < self.tokens.len and depth > 0) : (j += 1) {
            switch (self.tokens[j].type) {
                .LeftParen => depth += 1,
                .RightParen => depth -= 1,
                else => {},
            }
        }
        // Walk a small window past `)` to find a `{` that opens a
        // lambda body. Stop on any token that clearly ends the current
        // declaration: a statement terminator, a top-level keyword
        // (which would begin the next decl), `=`, `:`, etc.
        const limit = @min(self.tokens.len, j + 12);
        var k: usize = j;
        while (k < limit) : (k += 1) {
            const tt = self.tokens[k].type;
            if (tt == .LeftBrace) return false; // lambda body
            if (tt == .Semicolon or tt == .Eof) break;
            // Tokens that can begin a new declaration / statement —
            // seeing them means we walked past the current `const X = fn(...)`
            // line without finding a brace, so it's a type alias.
            if (tt == .Pub or tt == .Const or tt == .Let or tt == .Var or
                tt == .Fn or tt == .Struct or tt == .Enum or tt == .Trait or
                tt == .Impl or tt == .Export or tt == .Extern or tt == .Type or
                tt == .Import or tt == .Equal)
            {
                break;
            }
        }
        return true;
    }

    /// Parse the right-hand side of `const Name = <kind> { ... }`.
    fn parseAnonymousTypeBinding(self: *Parser, kind: AnonTypeKind, name: []const u8) !ast.Stmt {
        switch (kind) {
            .Struct => {
                _ = self.advance(); // consume `struct`
                const stmt = try self.structDeclarationWithName(name);
                try self.optionalSemicolon();
                return stmt;
            },
            .PackedStruct => {
                _ = self.advance(); // consume `packed`
                _ = self.advance(); // consume `struct`
                var stmt = try self.structDeclarationWithName(name);
                stmt.StructDecl.layout = .Packed;
                try self.optionalSemicolon();
                return stmt;
            },
            .ExternStruct => {
                _ = self.advance(); // consume `extern`
                _ = self.advance(); // consume `struct`
                var stmt = try self.structDeclarationWithName(name);
                stmt.StructDecl.layout = .Extern;
                try self.optionalSemicolon();
                return stmt;
            },
            .Enum => {
                _ = self.advance(); // consume `enum`
                const stmt = try self.enumDeclarationWithName(name);
                try self.optionalSemicolon();
                return stmt;
            },
            .Union => {
                _ = self.advance(); // consume `union`
                const stmt = try self.unionDeclarationWithName(name);
                try self.optionalSemicolon();
                return stmt;
            },
            .ErrorSet => {
                _ = self.advance(); // consume `error` (Identifier)
                const stmt = try self.errorSetDeclarationWithName(name);
                try self.optionalSemicolon();
                return stmt;
            },
        }
    }

    /// Parse the body of an error-set declaration:
    ///   `{ Variant1, Variant2, ... }`
    /// The `error` keyword has already been consumed by the caller.
    /// We model the result as an enum with no payload — the underlying
    /// representation is identical (a tagged set of named alternatives)
    /// and the AST/typechecker already handle enums end-to-end.
    /// A future change can introduce a dedicated ErrorSetDecl node if
    /// we need to distinguish them (e.g. for error-union inference).
    fn errorSetDeclarationWithName(self: *Parser, name: []const u8) !ast.Stmt {
        const start_token = self.previous();
        _ = try self.expect(.LeftBrace, "Expected '{' after 'error'");

        var variants = std.ArrayList(ast.EnumVariant).empty;
        defer variants.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            const variant_token = try self.expect(.Identifier, "Expected error name");
            try variants.append(self.allocator, ast.EnumVariant{
                .name = variant_token.lexeme,
                .data_type = null,
            });
            // Comma is optional — newline-separated lists are accepted.
            _ = self.match(&.{.Comma});
            if (self.check(.RightBrace)) break;
        }

        _ = try self.expect(.RightBrace, "Expected '}' after error set");

        const variants_slice = try variants.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(variants_slice);

        const enum_decl = try ast.EnumDecl.init(
            self.allocator,
            name,
            variants_slice,
            ast.SourceLocation.fromToken(start_token),
        );
        return ast.Stmt{ .EnumDecl = enum_decl };
    }

    /// Parse a var declaration (module-level mutable variable)
    /// Syntax: var name: Type = value
    fn varDeclaration(self: *Parser) !ast.Stmt {
        // Accept Identifier or any contextual soft-keyword as variable
        // name (`var is: u32 = ...`, `var test: T = ...`, `var match`).
        // Kernel code uses `match`, `type`, `default`, `is`, `test` etc.
        // as plain identifiers in binding slots.
        const name_token = self.matchIdentifierLike() orelse blk: {
            try self.reportError("Expected variable name");
            break :blk self.previous();
        };

        // Type annotation is required for var
        var type_name: ?[]const u8 = null;
        if (self.match(&.{.Colon})) {
            type_name = try self.parseTypeAnnotation();
            try self.consumeOptionalAlignSuffix();
        }

        // Allow `var Name = struct { ... }` etc. like the let/const path.
        if (type_name == null and self.check(.Equal)) {
            if (self.peekTypeBindingAfterEquals()) |kind| {
                _ = self.advance(); // consume '='
                return try self.parseAnonymousTypeBinding(kind, name_token.lexeme);
            }
        }

        // Optional initializer
        var value: ?*ast.Expr = null;
        if (self.match(&.{.Equal})) {
            value = try self.expression();
        }

        const decl = try ast.LetDecl.init(
            self.allocator,
            name_token.lexeme,
            type_name,
            value,
            true, // var is always mutable
            ast.SourceLocation.fromToken(name_token),
        );

        // Consume optional semicolon
        try self.optionalSemicolon();

        return ast.Stmt{ .LetDecl = decl };
    }

    /// Parse a statement
    fn statement(self: *Parser) !ast.Stmt {
        // Check for labeled loop: 'label: while/for/loop
        if (self.check(.Identifier) and self.peek().lexeme.len > 0 and self.peek().lexeme[0] == '\'') {
            const label_token = self.advance();
            const label = label_token.lexeme[1..]; // Strip the leading '

            // Expect colon after label
            _ = try self.expect(.Colon, "Expected ':' after loop label");

            // Now parse the loop statement with the label
            if (self.match(&.{.While})) return self.whileStatementWithLabel(label);
            if (self.match(&.{.Loop})) return self.loopStatementWithLabel(label);
            if (self.match(&.{.For})) return self.forStatementWithLabel(label);

            try self.reportError("Expected 'while', 'for', or 'loop' after label");
            return error.UnexpectedToken;
        }

        if (self.match(&.{.Assert})) return self.assertStatement();
        if (self.match(&.{.Return})) return self.returnStatement();
        if (self.match(&.{.If})) return self.ifStatement();
        if (self.match(&.{.While})) return self.whileStatement();
        if (self.match(&.{.Loop})) return self.loopStatement();
        if (self.match(&.{.Do})) return self.doWhileStatement();
        if (self.match(&.{.For})) return self.forStatement();
        if (self.match(&.{.Switch})) return self.switchStatement();
        if (self.match(&.{.Match})) return self.matchStatement();
        if (self.match(&.{.Try})) return self.tryStatement();
        if (self.match(&.{.Defer})) return self.deferStatement();
        if (self.match(&.{.Break})) return self.breakStatement();
        if (self.match(&.{.Continue})) return self.continueStatement();
        if (self.match(&.{.LeftBrace})) {
            const block = try self.blockStatement();
            return ast.Stmt{ .BlockStmt = block };
        }
        // `unsafe { ... }` as a statement is treated as a no-op block
        // prefix — the inner block is parsed exactly like a regular
        // brace block. Issue #56: kernel code uses `unsafe { ... }`
        // pervasively (~234 sites) as a marker around raw-pointer
        // dereferences and pointer-cast loads/stores. The block may
        // also appear in expression position (`fn g(): u8 { unsafe {
        // *p } }` — see `primary()` for the expression form).
        //
        // We recognize the keyword only when followed by `{` so a bare
        // `unsafe` token in any other position (e.g. as a parameter
        // name via the contextual-keyword fallback) keeps its existing
        // behavior.
        if (self.check(.Unsafe) and self.peekNext().type == .LeftBrace) {
            _ = self.advance(); // consume `unsafe`
            _ = self.advance(); // consume `{`
            const block = try self.blockStatement();
            return ast.Stmt{ .BlockStmt = block };
        }
        return self.expressionStatement();
    }

    /// Parse an assert statement
    /// Grammar: assert condition
    /// Grammar: assert condition, message
    fn assertStatement(self: *Parser) !ast.Stmt {
        const assert_token = self.previous();

        // Parse the condition expression
        const condition = try self.expression();

        // Check for optional message
        var message: ?*ast.Expr = null;
        if (self.match(&.{.Comma})) {
            message = try self.expression();
        }

        const stmt = try ast.AssertStmt.init(
            self.allocator,
            condition,
            message,
            ast.SourceLocation.fromToken(assert_token),
        );

        // Consume optional semicolon
        try self.optionalSemicolon();

        return ast.Stmt{ .AssertStmt = stmt };
    }

    /// Parse a return statement
    fn returnStatement(self: *Parser) !ast.Stmt {
        const return_token = self.previous();
        var value: ?*ast.Expr = null;

        // A bare `return` ends at any obvious statement / arm boundary —
        // including `;`, `,`, `}`, and EOF — so we don't accidentally
        // pull the next match-arm or block tail in as the return value.
        // It also stops at a newline (no value on this line), so that
        //   if (cond) return
        //   if (cond2) { ... }
        // doesn't consume the second `if` as an if-as-expression value.
        if (!self.check(.RightBrace) and !self.check(.Semicolon) and
            !self.check(.Comma) and !self.isAtEnd() and !self.isAtNewLine())
        {
            value = try self.expression();
        }

        const stmt = try ast.ReturnStmt.init(
            self.allocator,
            value,
            ast.SourceLocation.fromToken(return_token),
        );

        // Consume optional semicolon
        try self.optionalSemicolon();

        return ast.Stmt{ .ReturnStmt = stmt };
    }

    /// Parse an if statement
    fn ifStatement(self: *Parser) !ast.Stmt {
        const if_token = self.previous();

        // Check for if-let pattern matching: if let Some(x) = expr { ... }
        if (self.match(&.{.Let})) {
            return self.ifLetStatement(if_token);
        }

        // Parse condition - let expression() handle all grouping naturally.
        // This supports both `if x > 0 {` and `if (x > 0) {` as well as
        // complex conditions like `if (a > b) != (c > d) && e {`.
        //
        // Special-case lookahead for Zig-style `if (cond) |x| { body }`:
        // when the condition begins with `(`, scan forward to find the
        // matching `)` and peek the token immediately after. If it is `|`
        // followed by an identifier (or `_`) and another `|`, parse the
        // condition as `(inner)` (consuming both parens here) so the
        // capture pipe is unambiguous. Otherwise fall through to the
        // normal expression parser, which handles `|` as bitwise-OR.
        //
        // Struct-literal parsing is suppressed for bare identifiers in the
        // condition so that `if cond { body }` doesn't treat `cond { ... }`
        // as a struct literal that swallows the body block.
        var condition: *ast.Expr = undefined;
        var did_capture_paren = false;
        self.suppress_struct_literal += 1;
        if (self.check(.LeftParen) and self.afterMatchingParenLooksLikeCapturePipe()) {
            _ = self.advance(); // consume `(`
            did_capture_paren = true;
            condition = try self.expression();
            _ = try self.expect(.RightParen, "Expected ')' after if condition");
        } else {
            condition = try self.expression();
        }
        self.suppress_struct_literal -= 1;
        errdefer ast.Program.deinitExpr(condition, self.allocator);

        // Zig-style optional unwrap: `if (cond) |x| { body }` or
        // `if (cond) |_| { body }`. Only valid when we recognized the
        // capture-pipe shape above and consumed the surrounding parens.
        // Desugar to an `if-let` with the sentinel pattern `<auto-unwrap>`,
        // which downstream consumers treat as "match any payload-bearing
        // variant" — i.e. `Option.Some` or `Result.Ok`. The discard form
        // `|_|` lowers to no binding.
        if (did_capture_paren and self.match(&.{.Pipe})) {
            var binding: ?[]const u8 = null;
            const bind_tok = try self.expect(.Identifier, "Expected identifier or '_' in '|...|' capture");
            if (!std.mem.eql(u8, bind_tok.lexeme, "_")) {
                binding = bind_tok.lexeme;
            }
            _ = try self.expect(.Pipe, "Expected '|' after capture binding");

            const then_block = try self.blockStatement();
            errdefer ast.Program.deinitBlockStmt(then_block, self.allocator);

            var else_block: ?*ast.BlockStmt = null;
            if (self.match(&.{.Else})) {
                else_block = try self.blockStatement();
            }
            errdefer if (else_block) |eb| ast.Program.deinitBlockStmt(eb, self.allocator);

            const stmt = try ast.IfLetStmt.init(
                self.allocator,
                "<auto-unwrap>",
                binding,
                condition,
                then_block,
                else_block,
                ast.SourceLocation.fromToken(if_token),
            );
            return ast.Stmt{ .IfLetStmt = stmt };
        }

        // Then-branch: brace block `{ ... }` OR a single statement (e.g.
        // `if (c) return 0;`). Single-statement form is wrapped in a synthetic
        // block so downstream code (typechecker, codegen) sees the same shape.
        const then_block = try self.braceOrSingleStatementBlock();
        errdefer ast.Program.deinitBlockStmt(then_block, self.allocator);

        // Else-branch: same shape options as the then-branch — brace block,
        // single statement, or chained `else if`.
        //
        // Dangling-else: the recursive descent here naturally binds `else` to
        // the innermost `if` (matches C/Zig/Rust convention). When parsing
        // `if (a) if (b) c() else d()`, the inner `ifStatement()` call eagerly
        // consumes the `else d()` before returning, so the outer `if` never
        // sees the `else` token.
        var else_block: ?*ast.BlockStmt = null;
        if (self.match(&.{.Else})) {
            // Handle else if as a nested if statement wrapped in a block
            if (self.check(.If)) {
                // Parse the else if as another if statement
                _ = self.advance(); // consume 'if'
                const else_if_stmt = try self.ifStatement();

                // Wrap the else-if in a block
                const else_block_ptr = try self.allocator.create(ast.BlockStmt);
                var stmts_list = std.ArrayList(ast.Stmt).empty;
                try stmts_list.append(self.allocator, else_if_stmt);
                else_block_ptr.* = ast.BlockStmt{
                    .node = .{ .type = .BlockStmt, .loc = ast.SourceLocation.fromToken(self.previous()) },
                    .statements = try stmts_list.toOwnedSlice(self.allocator),
                };
                else_block = else_block_ptr;
            } else {
                else_block = try self.braceOrSingleStatementBlock();
            }
        }
        errdefer if (else_block) |eb| ast.Program.deinitBlockStmt(eb, self.allocator);

        const stmt = try ast.IfStmt.init(
            self.allocator,
            condition,
            then_block,
            else_block,
            ast.SourceLocation.fromToken(if_token),
        );

        return ast.Stmt{ .IfStmt = stmt };
    }

    /// Parse an if-let statement: if let Some(x) = expr { ... }
    /// Also supports:
    ///   - Qualified patterns: `if let Option.Some(x) = expr { ... }`
    ///   - Rust `::` qualifier: `if let Option::Some(x) = expr { ... }`
    ///   - Dot-prefixed variants: `if let .Some(x) = expr { ... }`
    ///   - Rust-style binding modifiers: `if let Some(ref mut x) = expr { ... }`
    ///     (`ref` and `mut` are accepted and treated as a plain binding name —
    ///     borrow/mutability semantics are downstream future work, see #62.)
    ///   - Wildcard / discard binding: `if let Some(_) = expr { ... }`
    fn ifLetStatement(self: *Parser, if_token: Token) !ast.Stmt {
        // Parse pattern. A leading `.` allows dot-prefixed variants like
        // `.Some(x)` / `.Ok(v)` (Home's existing enum-variant-shorthand).
        // In that case the pattern lexeme is just the bare variant name —
        // codegen looks variants up by name across all enum layouts.
        var pattern: []const u8 = undefined;
        if (self.match(&.{.Dot})) {
            const variant_token = try self.expect(.Identifier, "Expected variant name after '.' in 'if let' pattern");
            pattern = variant_token.lexeme;
        } else {
            const first_token = try self.expect(.Identifier, "Expected pattern name after 'if let'");
            pattern = first_token.lexeme;

            // Handle qualified pattern like Option.Some or Result.Ok
            // Also accepts Rust-style Option::Some (treated identically).
            if (self.match(&.{ .Dot, .ColonColon })) {
                const variant_token = try self.expect(.Identifier, "Expected variant name after '.'");
                // Concatenate the pattern: "Option.Some"
                const full_pattern = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pattern, variant_token.lexeme });
                pattern = full_pattern;
            }
        }

        // Check for binding: Some(x) vs None.
        //
        // Inside the parens we accept Rust-style binding modifiers in any
        // combination: `x`, `mut x`, `ref x`, `ref mut x`. These modifiers
        // are parser-only for now — semantically the binding is the inner
        // identifier. (See issue #62: full borrow/mutability semantics are
        // downstream work; the kernel only needs the syntax to parse.)
        //
        // We also accept `_` as a discard binding (lowered to `null`).
        var binding: ?[]const u8 = null;
        if (self.match(&.{.LeftParen})) {
            // Skip optional `ref` (contextual keyword — arrives as Identifier).
            if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "ref")) {
                _ = self.advance();
            }
            // Skip optional `mut` (real keyword token).
            _ = self.match(&.{.Mut});

            const binding_token = try self.expect(.Identifier, "Expected binding name in pattern");
            if (!std.mem.eql(u8, binding_token.lexeme, "_")) {
                binding = binding_token.lexeme;
            }
            _ = try self.expect(.RightParen, "Expected ')' after binding name");
        }

        // Expect '=' followed by the expression to match
        _ = try self.expect(.Equal, "Expected '=' after pattern in 'if let'");

        // Parse the expression being matched. Suppress struct-literal
        // parsing on bare identifiers so the body's `{` is unambiguous.
        self.suppress_struct_literal += 1;
        const value = try self.expression();
        self.suppress_struct_literal -= 1;
        errdefer ast.Program.deinitExpr(value, self.allocator);

        // Parse the then block
        const then_block = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(then_block, self.allocator);

        // Parse optional else block (simple else only, not else if chains for if-let)
        var else_block: ?*ast.BlockStmt = null;
        if (self.match(&.{.Else})) {
            else_block = try self.blockStatement();
        }
        errdefer if (else_block) |eb| ast.Program.deinitBlockStmt(eb, self.allocator);

        const stmt = try ast.IfLetStmt.init(
            self.allocator,
            pattern,
            binding,
            value,
            then_block,
            else_block,
            ast.SourceLocation.fromToken(if_token),
        );

        return ast.Stmt{ .IfLetStmt = stmt };
    }

    /// Parse a while statement
    fn whileStatement(self: *Parser) !ast.Stmt {
        const while_token = self.previous();
        // Parse condition - let expression() handle all grouping naturally.
        // This supports both `while x > 0 {` and `while (x > 0) {` as well as
        // complex conditions like `while (a > b) != (c > d) && e {`.
        // Struct-literal parsing is suppressed for bare identifiers in the
        // condition so that `while timer() < target { ... }` doesn't slurp
        // the body's `{` into a `target { ... }` literal.
        // Pipe is also suppressed so that the optional Zig payload
        // `while (opt) |x| { body }` doesn't get consumed as bitwise-or.
        self.suppress_struct_literal += 1;
        self.suppress_pipe_or += 1;
        const condition = try self.expression();
        self.suppress_pipe_or -= 1;
        self.suppress_struct_literal -= 1;
        errdefer ast.Program.deinitExpr(condition, self.allocator);

        try self.parseOptionalWhilePayload();

        const continue_expr = try self.parseOptionalWhileContinueExpr();
        errdefer if (continue_expr) |ce| ast.Program.deinitExpr(ce, self.allocator);

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        const stmt = try ast.WhileStmt.initWithContinueExpr(
            self.allocator,
            condition,
            body,
            continue_expr,
            null,
            ast.SourceLocation.fromToken(while_token),
        );

        return ast.Stmt{ .WhileStmt = stmt };
    }

    /// Parse a while statement with a label
    fn whileStatementWithLabel(self: *Parser, label: []const u8) !ast.Stmt {
        const while_token = self.previous();
        self.suppress_struct_literal += 1;
        self.suppress_pipe_or += 1;
        const condition = try self.expression();
        self.suppress_pipe_or -= 1;
        self.suppress_struct_literal -= 1;
        errdefer ast.Program.deinitExpr(condition, self.allocator);

        try self.parseOptionalWhilePayload();

        const continue_expr = try self.parseOptionalWhileContinueExpr();
        errdefer if (continue_expr) |ce| ast.Program.deinitExpr(ce, self.allocator);

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        const stmt = try ast.WhileStmt.initWithContinueExpr(
            self.allocator,
            condition,
            body,
            continue_expr,
            label,
            ast.SourceLocation.fromToken(while_token),
        );

        return ast.Stmt{ .WhileStmt = stmt };
    }

    /// Parse the optional Zig-style payload that follows a while-loop
    /// condition: `while (opt) |unwrapped| { body }` or
    /// `while (opt) |*ptr| { body }`. The current `WhileStmt` AST has no
    /// dedicated payload field, so we consume and discard the binding —
    /// this keeps parsing unblocked for parser-pass-rate audits while
    /// codegen support is added separately.
    fn parseOptionalWhilePayload(self: *Parser) !void {
        if (!self.match(&.{.Pipe})) return;
        _ = self.match(&.{.Star});
        const tok = self.advance();
        if (tok.type != .Identifier) {
            try self.reportError("Expected identifier in while payload");
            return error.UnexpectedToken;
        }
        _ = try self.expect(.Pipe, "Expected '|' after while payload");
    }

    /// Parse the optional Zig-style continue-expression that follows a
    /// while-loop condition: `while (cond) : (cexpr) { body }`. Returns
    /// `null` when the next token is not `:` (the existing form).
    fn parseOptionalWhileContinueExpr(self: *Parser) !?*ast.Expr {
        if (!self.match(&.{.Colon})) return null;
        _ = try self.expect(.LeftParen, "Expected '(' after ':' in while-with-continue-expression");
        // Allow the continue expression to be any expression — typically an
        // assignment like `i += 1`. Suppress struct-literal parsing for the
        // same reason as the condition (so a trailing identifier doesn't
        // try to consume the body's `{`).
        self.suppress_struct_literal += 1;
        const cexpr = try self.expression();
        self.suppress_struct_literal -= 1;
        errdefer ast.Program.deinitExpr(cexpr, self.allocator);
        _ = try self.expect(.RightParen, "Expected ')' after while continue-expression");
        return cexpr;
    }

    /// Parse a loop statement (infinite loop, desugared to while(true))
    fn loopStatement(self: *Parser) !ast.Stmt {
        const loop_token = self.previous();

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        // Create a true boolean literal as the condition
        const true_lit = try self.allocator.create(ast.Expr);
        true_lit.* = ast.Expr{
            .BooleanLiteral = ast.BooleanLiteral.init(true, ast.SourceLocation.fromToken(loop_token)),
        };

        const stmt = try ast.WhileStmt.init(
            self.allocator,
            true_lit,
            body,
            ast.SourceLocation.fromToken(loop_token),
        );

        return ast.Stmt{ .WhileStmt = stmt };
    }

    /// Parse a loop statement with a label
    fn loopStatementWithLabel(self: *Parser, label: []const u8) !ast.Stmt {
        const loop_token = self.previous();

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        // Create a true boolean literal as the condition
        const true_lit = try self.allocator.create(ast.Expr);
        true_lit.* = ast.Expr{
            .BooleanLiteral = ast.BooleanLiteral.init(true, ast.SourceLocation.fromToken(loop_token)),
        };

        const stmt = try ast.WhileStmt.initWithLabel(
            self.allocator,
            true_lit,
            body,
            label,
            ast.SourceLocation.fromToken(loop_token),
        );

        return ast.Stmt{ .WhileStmt = stmt };
    }

    /// Parse a for statement
    fn forStatement(self: *Parser) !ast.Stmt {
        const for_token = self.previous();

        // Zig-style: `for (EXPR) |IDENT| { body }` or
        // `for (EXPR_A, EXPR_B) |a, b| { body }`. Disambiguated by
        // peeking past the matching `)` for a `|` capture pipe so we
        // don't mis-fire on Rust-style `for (x in items)` (which has no
        // pipe after `)`).
        if (self.forParenIsZigStyle()) {
            return self.forStatementZigStyle(for_token, null);
        }

        // Check for tuple destructuring: for (a, b, c) in items
        // or regular: for x in items / for (x in items)
        if (self.match(&.{.LeftParen})) {
            // Could be tuple destructuring or just grouping parens
            const first_token = try self.expect(.Identifier, "Expected iterator variable name");
            const first_name = first_token.lexeme;

            if (self.match(&.{.Comma})) {
                // This is tuple destructuring: for (a, b, ...) in items.
                // Nested patterns like `for (a, (b, c)) in pairs` are
                // not yet supported by the current AST — the bindings
                // slot is a flat `[][]const u8`. We flatten them here
                // if encountered, but emit a clear error pointing at
                // the nested paren so the user isn't left wondering
                // why `(b, c)` silently disappeared.
                var bindings = std.ArrayList([]const u8).empty;
                defer bindings.deinit(self.allocator);

                try bindings.append(self.allocator, first_name);

                while (true) {
                    if (self.check(.LeftParen)) {
                        try self.reportError(
                            "nested tuple destructuring in `for` is not yet supported; flatten the pattern (e.g. `for (a, b, c) in pairs`)",
                        );
                        return error.UnexpectedToken;
                    }
                    const binding_token = try self.expect(.Identifier, "Expected identifier in tuple pattern");
                    try bindings.append(self.allocator, binding_token.lexeme);

                    if (!self.match(&.{.Comma})) break;
                    // Check if next is RightParen (trailing comma)
                    if (self.check(.RightParen)) break;
                }

                _ = try self.expect(.RightParen, "Expected ')' after tuple pattern");
                _ = try self.expect(.In, "Expected 'in' after tuple pattern");

                const iterable = try self.expression();
                errdefer ast.Program.deinitExpr(iterable, self.allocator);

                const body = try self.blockStatement();
                errdefer ast.Program.deinitBlockStmt(body, self.allocator);

                const stmt = try ast.ForStmt.initWithTuple(
                    self.allocator,
                    try bindings.toOwnedSlice(self.allocator),
                    iterable,
                    body,
                    ast.SourceLocation.fromToken(for_token),
                );

                return ast.Stmt{ .ForStmt = stmt };
            } else {
                // Just grouping parens: for (x in items)
                _ = try self.expect(.In, "Expected 'in' after iterator variable");

                const iterable = try self.expression();
                errdefer ast.Program.deinitExpr(iterable, self.allocator);

                _ = try self.expect(.RightParen, "Expected ')' after for iteration clause");

                const body = try self.blockStatement();
                errdefer ast.Program.deinitBlockStmt(body, self.allocator);

                const stmt = try ast.ForStmt.init(
                    self.allocator,
                    first_name,
                    iterable,
                    body,
                    null,
                    ast.SourceLocation.fromToken(for_token),
                );

                return ast.Stmt{ .ForStmt = stmt };
            }
        }

        // No parens: for x in items or for i, x in items
        const first_token = try self.expect(.Identifier, "Expected iterator variable name");
        const first_name = first_token.lexeme;

        // Check for enumerate syntax: for index, item in items
        var index: ?[]const u8 = null;
        var iterator: []const u8 = first_name;

        if (self.match(&.{.Comma})) {
            // First identifier is the index, second is the iterator
            index = first_name;
            const iterator_token = try self.expect(.Identifier, "Expected iterator variable name after ','");
            iterator = iterator_token.lexeme;
        }

        _ = try self.expect(.In, "Expected 'in' after iterator variable");

        const iterable = try self.expression();
        errdefer ast.Program.deinitExpr(iterable, self.allocator);

        // Optional `step N` clause — only meaningful when the iterable
        // is a range. `step` is a soft keyword (not a reserved word) so
        // we match it as an identifier with lexeme "step" and only when
        // followed by something that could start an expression.
        if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "step")) {
            _ = self.advance();
            const step_expr = try self.expression();
            if (iterable.* == .RangeExpr) {
                iterable.RangeExpr.step = step_expr;
            } else {
                // Only ranges support step. Leak the step expr node for
                // now; the arena the parser runs on will clean up.
                try self.reportError("'step' is only valid for range expressions");
            }
        }

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        const stmt = try ast.ForStmt.init(
            self.allocator,
            iterator,
            iterable,
            body,
            index,
            ast.SourceLocation.fromToken(for_token),
        );

        return ast.Stmt{ .ForStmt = stmt };
    }

    /// Parse a for statement with a label
    fn forStatementWithLabel(self: *Parser, label: []const u8) !ast.Stmt {
        const for_token = self.previous();

        // Zig-style with label: `'outer: for (EXPR) |IDENT| { body }`
        if (self.forParenIsZigStyle()) {
            return self.forStatementZigStyle(for_token, label);
        }

        // Handle optional parentheses: for (x in items) or for x in items
        const has_paren = self.match(&.{.LeftParen});

        const first_token = try self.expect(.Identifier, "Expected iterator variable name");
        const first_name = first_token.lexeme;

        // Check for enumerate syntax: for index, item in items
        var index: ?[]const u8 = null;
        var iterator: []const u8 = first_name;

        if (self.match(&.{.Comma})) {
            // First identifier is the index, second is the iterator
            index = first_name;
            const iterator_token = try self.expect(.Identifier, "Expected iterator variable name after ','");
            iterator = iterator_token.lexeme;
        }

        _ = try self.expect(.In, "Expected 'in' after iterator variable");

        const iterable = try self.expression();
        errdefer ast.Program.deinitExpr(iterable, self.allocator);

        if (has_paren) {
            _ = try self.expect(.RightParen, "Expected ')' after for iteration clause");
        }

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        const stmt = try ast.ForStmt.initWithLabel(
            self.allocator,
            iterator,
            iterable,
            body,
            index,
            label,
            ast.SourceLocation.fromToken(for_token),
        );

        return ast.Stmt{ .ForStmt = stmt };
    }

    /// Parse a Zig-style for loop: `for (EXPR) |IDENT| { body }`.
    ///
    /// Also supports parallel iteration `for (A, B) |a, b|` and the
    /// indexed form `for (slice, 0..) |item, idx|` where an open-ended
    /// range `INT..` in the iterable list is treated as the index source
    /// (mapped onto the existing `index` field of `ForStmt`).
    ///
    /// Caller must verify Zig-style shape via `forParenIsZigStyle()`
    /// first (no rollback path on mismatch). On entry, the parser is
    /// positioned at the `(`.
    fn forStatementZigStyle(self: *Parser, for_token: Token, label: ?[]const u8) !ast.Stmt {
        _ = try self.expect(.LeftParen, "Expected '(' after 'for'");

        // Parse comma-separated iterable expressions. We track an
        // optional "index iterable" position when we see an open-ended
        // range like `0..` (lexed as `INT DotDot` followed by `,` or
        // `)`). The current AST has no node for an open-ended range, so
        // we capture the start as a synthetic index counter and bind
        // its capture name to the `index` field below.
        var iterables = std.ArrayList(*ast.Expr).empty;
        defer iterables.deinit(self.allocator);
        // Track whether each slot is an open-ended range (index source)
        // via parallel array. When set, the corresponding pointer is
        // a placeholder and the slot binds to `index` rather than
        // `iterator` in the resulting ForStmt.
        var slot_is_index = std.ArrayList(bool).empty;
        defer slot_is_index.deinit(self.allocator);

        while (true) {
            // Detect open-ended range form `INT..` at this slot. Pure
            // lookahead — only consume on a confirmed match.
            if (self.check(.Integer)) {
                const next = self.peekNext().type;
                if (next == .DotDot) {
                    const after = if (self.current + 2 < self.tokens.len)
                        self.tokens[self.current + 2].type
                    else
                        .Eof;
                    if (after == .Comma or after == .RightParen) {
                        // Consume `INT ..` and treat this slot as index.
                        _ = self.advance(); // INT
                        _ = self.advance(); // ..
                        // Sentinel placeholder so the parallel array
                        // stays homogeneous; the `slot_is_index` flag
                        // marks it so we don't read it as a real iter.
                        const placeholder = try self.allocator.create(ast.Expr);
                        placeholder.* = ast.Expr{ .IntegerLiteral = ast.IntegerLiteral.init(0, ast.SourceLocation.fromToken(for_token)) };
                        try iterables.append(self.allocator, placeholder);
                        try slot_is_index.append(self.allocator, true);
                        if (!self.match(&.{.Comma})) break;
                        continue;
                    }
                }
            }

            const expr = try self.expression();
            try iterables.append(self.allocator, expr);
            try slot_is_index.append(self.allocator, false);

            if (!self.match(&.{.Comma})) break;
            // Allow trailing comma before `)`.
            if (self.check(.RightParen)) break;
        }

        _ = try self.expect(.RightParen, "Expected ')' after for iteration clause");
        _ = try self.expect(.Pipe, "Expected '|' to begin capture list");

        // Parse capture identifiers `|a|` or `|a, b|`. `_` is allowed
        // as a discard binding (matches Zig).
        var captures = std.ArrayList([]const u8).empty;
        defer captures.deinit(self.allocator);

        while (true) {
            // Optional `*` prefix for pointer-capture: `for (&xs) |*p|`.
            // We accept and discard the marker — current ForStmt has no
            // dedicated by-ref field, so callers wanting mutable access
            // must already pass `&xs` (handled at the iterable site).
            _ = self.match(&.{.Star});
            const cap_tok = self.advance();
            if (cap_tok.type != .Identifier) {
                try self.reportError("Expected identifier or '_' in for capture list");
                return error.UnexpectedToken;
            }
            try captures.append(self.allocator, cap_tok.lexeme);
            if (!self.match(&.{.Comma})) break;
            if (self.check(.Pipe)) break;
        }

        _ = try self.expect(.Pipe, "Expected '|' after capture list");

        if (captures.items.len != iterables.items.len) {
            try self.reportError("Number of captures must match number of iterables in for loop");
            return error.UnexpectedToken;
        }

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        // Lower to existing ForStmt shape. Single iterable -> simple
        // form; one iterable + one open-ended range -> indexed form;
        // anything else is rejected as not yet representable.
        const n = iterables.items.len;
        if (n == 1) {
            if (slot_is_index.items[0]) {
                try self.reportError("for loop requires at least one non-range iterable");
                return error.UnexpectedToken;
            }
            const stmt = if (label) |lbl| try ast.ForStmt.initWithLabel(
                self.allocator,
                captures.items[0],
                iterables.items[0],
                body,
                null,
                lbl,
                ast.SourceLocation.fromToken(for_token),
            ) else try ast.ForStmt.init(
                self.allocator,
                captures.items[0],
                iterables.items[0],
                body,
                null,
                ast.SourceLocation.fromToken(for_token),
            );
            return ast.Stmt{ .ForStmt = stmt };
        }

        if (n == 2) {
            // Allowed shape: one real iterable + one index counter.
            const a_is_idx = slot_is_index.items[0];
            const b_is_idx = slot_is_index.items[1];
            if (a_is_idx and b_is_idx) {
                try self.reportError("for loop requires at least one non-range iterable");
                return error.UnexpectedToken;
            }
            if (!a_is_idx and !b_is_idx) {
                try self.reportError("parallel iteration over multiple slices is not yet supported; use a single slice with `0..` for an index");
                return error.UnexpectedToken;
            }
            const iter_idx: usize = if (a_is_idx) 1 else 0;
            const idx_pos: usize = if (a_is_idx) 0 else 1;
            // Free the placeholder we allocated for the index slot — it
            // never makes it into the AST since `index` is just a name.
            ast.Program.deinitExpr(iterables.items[idx_pos], self.allocator);
            const stmt = if (label) |lbl| try ast.ForStmt.initWithLabel(
                self.allocator,
                captures.items[iter_idx],
                iterables.items[iter_idx],
                body,
                captures.items[idx_pos],
                lbl,
                ast.SourceLocation.fromToken(for_token),
            ) else try ast.ForStmt.init(
                self.allocator,
                captures.items[iter_idx],
                iterables.items[iter_idx],
                body,
                captures.items[idx_pos],
                ast.SourceLocation.fromToken(for_token),
            );
            return ast.Stmt{ .ForStmt = stmt };
        }

        try self.reportError("for loops with more than two captures are not yet supported");
        return error.UnexpectedToken;
    }

    /// Parse a do-while statement
    fn doWhileStatement(self: *Parser) !ast.Stmt {
        const do_token = self.previous();

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        _ = try self.expect(.While, "Expected 'while' after do-while body");
        _ = try self.expect(.LeftParen, "Expected '(' after 'while'");

        const condition = try self.expression();
        _ = try self.expect(.RightParen, "Expected ')' after do-while condition");
        errdefer ast.Program.deinitExpr(condition, self.allocator);

        const stmt = try ast.DoWhileStmt.init(
            self.allocator,
            body,
            condition,
            ast.SourceLocation.fromToken(do_token),
        );

        // Consume optional semicolon after do-while
        try self.optionalSemicolon();

        return ast.Stmt{ .DoWhileStmt = stmt };
    }

    /// Parse a switch statement
    fn switchStatement(self: *Parser) ParseError!ast.Stmt {
        const switch_token = self.previous();

        const value = try self.expression();
        errdefer ast.Program.deinitExpr(value, self.allocator);

        _ = try self.expect(.LeftBrace, "Expected '{' after switch value");

        var cases = std.ArrayList(*ast.CaseClause).empty;
        defer cases.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            if (self.match(&.{.Case})) {
                // C-style: `case Pattern[, Pattern...]: <stmts>`
                // Kept as a deprecated alias of the `=>` form for back-compat.
                var patterns = std.ArrayList(*ast.Expr).empty;
                defer patterns.deinit(self.allocator);

                // Parse first pattern
                const first_pattern = try self.expression();
                try patterns.append(self.allocator, first_pattern);

                // Parse additional patterns separated by commas
                while (self.match(&.{.Comma})) {
                    const pattern = try self.expression();
                    try patterns.append(self.allocator, pattern);
                }

                _ = try self.expect(.Colon, "Expected ':' after case pattern(s)");

                // Parse case body (statements until next case/default/closing brace)
                var body_stmts = std.ArrayList(ast.Stmt).empty;
                defer body_stmts.deinit(self.allocator);

                while (!self.check(.Case) and !self.check(.Default) and !self.check(.RightBrace) and !self.isAtEnd()) {
                    const stmt = try self.declaration();
                    try body_stmts.append(self.allocator, stmt);
                }

                const case_clause = try ast.CaseClause.init(
                    self.allocator,
                    try patterns.toOwnedSlice(self.allocator),
                    try body_stmts.toOwnedSlice(self.allocator),
                    false,
                    ast.SourceLocation.fromToken(self.previous()),
                );

                try cases.append(self.allocator, case_clause);
            } else if (self.match(&.{.Default})) {
                // C-style default arm (deprecated alias of `else =>`).
                _ = try self.expect(.Colon, "Expected ':' after 'default'");

                // Parse default body
                var body_stmts = std.ArrayList(ast.Stmt).empty;
                defer body_stmts.deinit(self.allocator);

                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    const stmt = try self.declaration();
                    try body_stmts.append(self.allocator, stmt);
                }

                const default_clause = try ast.CaseClause.init(
                    self.allocator,
                    &.{},
                    try body_stmts.toOwnedSlice(self.allocator),
                    true,
                    ast.SourceLocation.fromToken(self.previous()),
                );

                try cases.append(self.allocator, default_clause);
                break; // Default must be last
            } else if (self.match(&.{.Else})) {
                // match-style default arm: `else => <body>`.
                const default_clause = try self.parseSwitchArrowArm(&.{}, true);
                try cases.append(self.allocator, default_clause);
                // `else` arm is the default — must be last.
                break;
            } else {
                // match-style: `Pattern[, Pattern...] => <body>` (issue #63).
                // Use `parseSwitchArmPattern` so the leading-dot enum-variant
                // shorthand (`.A`, `.B`) is accepted alongside bare names and
                // qualified `Type.Variant` paths. Comma-separated patterns
                // share a single body — emitted as multiple patterns on one
                // CaseClause (codegen iterates patterns per clause).
                var patterns = std.ArrayList(*ast.Expr).empty;
                defer patterns.deinit(self.allocator);

                const first_pattern = try self.parseSwitchArmPattern();
                try patterns.append(self.allocator, first_pattern);

                while (self.match(&.{.Comma}) and !self.check(.FatArrow)) {
                    const pattern = try self.parseSwitchArmPattern();
                    try patterns.append(self.allocator, pattern);
                }

                if (!self.check(.FatArrow)) {
                    try self.reportError("Expected 'case', 'default', 'else', or '=>' arm in switch statement");
                    return error.UnexpectedToken;
                }

                const owned_patterns = try patterns.toOwnedSlice(self.allocator);
                const arm = try self.parseSwitchArrowArm(owned_patterns, false);
                try cases.append(self.allocator, arm);
            }
        }

        _ = try self.expect(.RightBrace, "Expected '}' after switch cases");

        const stmt = try ast.SwitchStmt.init(
            self.allocator,
            value,
            try cases.toOwnedSlice(self.allocator),
            ast.SourceLocation.fromToken(switch_token),
        );

        return ast.Stmt{ .SwitchStmt = stmt };
    }

    /// Parse the body of a `=>` switch arm and build a CaseClause.
    /// `patterns` is moved into the resulting clause (caller must not free
    /// it on success). Body forms accepted (mirrors match-arm parsing):
    ///   * `=> { stmt; stmt; }`     — block body, statements inlined.
    ///   * `=> return [expr],`      — return statement.
    ///   * `=> expr,`               — single expression, wrapped as ExprStmt.
    /// A trailing comma is consumed if present; newline separation is fine.
    fn parseSwitchArrowArm(
        self: *Parser,
        patterns: []const *ast.Expr,
        is_default: bool,
    ) ParseError!*ast.CaseClause {
        const arrow_token = try self.expect(.FatArrow, "Expected '=>' in switch arm");

        var body_stmts = std.ArrayList(ast.Stmt).empty;
        defer body_stmts.deinit(self.allocator);

        if (self.match(&.{.LeftBrace})) {
            // Block body — inline its statements directly into the clause so
            // codegen/interpreter (which iterate `case_clause.body`) see them
            // as a flat statement list, matching the C-style `case ...:` form.
            // Use declaration() so `let` / `const` / `var` inside the arm
            // are recognized; statement() alone falls through to expression
            // parsing for those keywords.
            while (!self.check(.RightBrace) and !self.isAtEnd()) {
                const stmt = try self.declaration();
                try body_stmts.append(self.allocator, stmt);
            }
            _ = try self.expect(.RightBrace, "Expected '}' after switch arm block");
        } else if (self.match(&.{.Return})) {
            // Return statement — value is optional.
            const ret_token = self.previous();
            const ret_value: ?*ast.Expr = if (!self.check(.Comma) and !self.check(.RightBrace) and !self.check(.Semicolon))
                try self.expression()
            else
                null;
            const ret_stmt = try ast.ReturnStmt.init(
                self.allocator,
                ret_value,
                ast.SourceLocation.fromToken(ret_token),
            );
            try body_stmts.append(self.allocator, ast.Stmt{ .ReturnStmt = ret_stmt });
        } else {
            // Bare expression — wrap as ExprStmt so it lives in `body`.
            const body_expr = try self.expression();
            try body_stmts.append(self.allocator, ast.Stmt{ .ExprStmt = body_expr });
        }

        // Trailing comma is optional (newline-separated arms also work).
        _ = self.match(&.{.Comma});

        return ast.CaseClause.init(
            self.allocator,
            patterns,
            try body_stmts.toOwnedSlice(self.allocator),
            is_default,
            ast.SourceLocation.fromToken(arrow_token),
        );
    }

    /// Parse a match statement with pattern matching
    fn matchStatement(self: *Parser) !ast.Stmt {
        const match_token = self.previous();

        // Parse the value to match against
        const value = try self.expression();
        errdefer ast.Program.deinitExpr(value, self.allocator);

        _ = try self.expect(.LeftBrace, "Expected '{' after match value");

        var arms = std.ArrayList(*ast.MatchArm).empty;
        defer arms.deinit(self.allocator);

        // Parse match arms
        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            // Parse pattern
            var pattern = try self.parsePattern();

            // Check for OR patterns: pattern1 | pattern2 | ...
            if (self.match(&.{.Pipe})) {
                var patterns = std.ArrayList(*ast.Pattern).empty;
                defer patterns.deinit(self.allocator);

                try patterns.append(self.allocator, pattern);

                // Parse additional patterns separated by |
                while (true) {
                    const next_pattern = try self.parsePattern();
                    try patterns.append(self.allocator, next_pattern);

                    if (!self.match(&.{.Pipe})) break;
                }

                // Create OR pattern
                const or_pattern = try self.allocator.create(ast.Pattern);
                or_pattern.* = ast.Pattern{ .Or = try patterns.toOwnedSlice(self.allocator) };
                pattern = or_pattern;
            }

            // Check for @ binding: pattern @ identifier
            if (self.match(&.{.At})) {
                const bind_token = try self.expect(.Identifier, "Expected identifier after '@'");
                const as_pattern = try self.allocator.create(ast.Pattern);
                as_pattern.* = ast.Pattern{
                    .As = .{
                        .pattern = pattern,
                        .identifier = bind_token.lexeme,
                    },
                };
                pattern = as_pattern;
            }

            // Parse optional guard (if expression)
            var guard: ?*ast.Expr = null;
            if (self.match(&.{.If})) {
                guard = try self.expression();
            }

            // Expect => arrow
            _ = try self.expect(.FatArrow, "Expected '=>' after match pattern");

            // Parse arm body - can be expression, block, or return statement
            var body: *ast.Expr = undefined;
            if (self.check(.LeftBrace)) {
                // Parse block body - use blockExprParse which handles statements properly
                _ = self.advance(); // consume '{'
                body = try self.blockExprParse();
            } else if (self.check(.Return)) {
                // Parse return as an expression wrapper
                _ = self.advance(); // consume 'return'
                const return_value = if (!self.check(.Comma) and !self.check(.RightBrace))
                    try self.expression()
                else
                    null;
                // Wrap return in a special expression
                const return_expr = try ast.ReturnExpr.init(self.allocator, return_value, ast.SourceLocation.fromToken(self.previous()));
                body = try self.allocator.create(ast.Expr);
                body.* = ast.Expr{ .ReturnExpr = return_expr };
            } else {
                body = try self.expression();
            }

            errdefer ast.Program.deinitExpr(body, self.allocator);

            // Comma is optional - newline separation is allowed
            // Just consume any comma that's present
            _ = self.match(&.{.Comma});

            const arm = try ast.MatchArm.init(
                self.allocator,
                pattern,
                guard,
                body,
                ast.SourceLocation.fromToken(match_token),
            );

            try arms.append(self.allocator, arm);
        }

        _ = try self.expect(.RightBrace, "Expected '}' after match arms");

        const stmt = try ast.MatchStmt.init(
            self.allocator,
            value,
            try arms.toOwnedSlice(self.allocator),
            ast.SourceLocation.fromToken(match_token),
        );

        return ast.Stmt{ .MatchStmt = stmt };
    }

    /// Parse a pattern for match statements
    fn parsePattern(self: *Parser) !*ast.Pattern {
        const pattern = try self.allocator.create(ast.Pattern);
        errdefer self.allocator.destroy(pattern);

        // Negative integer pattern: -N
        if (self.match(&.{.Minus})) {
            if (self.match(&.{.Integer})) {
                const token = self.previous();
                const pos_value = try std.fmt.parseInt(i64, token.lexeme, 10);
                pattern.* = ast.Pattern{ .IntLiteral = -pos_value };
                return pattern;
            }
            // Not a negative integer — backtrack the minus
            self.current -= 1;
        }

        // Integer literal pattern (or range pattern)
        if (self.match(&.{.Integer})) {
            const token = self.previous();
            const start_value = try std.fmt.parseInt(i64, token.lexeme, 10);

            // Check for range pattern: N..M (exclusive) or N..=M (inclusive).
            // The lexer emits DotDotEqual as a single token, so we must
            // match both variants explicitly — DotDot followed by Equal
            // would not work because `Equal` is its own token after any
            // non-DotDotEqual DotDot.
            if (self.match(&.{ .DotDot, .DotDotEqual })) {
                const inclusive = self.previous().type == .DotDotEqual;
                const end_token = try self.expect(.Integer, "Expected end value in range pattern");
                const end_value = try std.fmt.parseInt(i64, end_token.lexeme, 10);

                if (start_value > end_value) {
                    std.debug.print(
                        "Warning: range pattern {d}..{d} has start > end — arm will never match\n",
                        .{ start_value, end_value },
                    );
                }

                // Create IntLiteral expressions for start and end
                const start_expr = try self.allocator.create(ast.Expr);
                start_expr.* = ast.Expr{ .IntegerLiteral = ast.IntegerLiteral.init(start_value, ast.SourceLocation.fromToken(token)) };

                const end_expr = try self.allocator.create(ast.Expr);
                end_expr.* = ast.Expr{ .IntegerLiteral = ast.IntegerLiteral.init(end_value, ast.SourceLocation.fromToken(end_token)) };

                pattern.* = ast.Pattern{ .Range = .{ .start = start_expr, .end = end_expr, .inclusive = inclusive } };
                return pattern;
            }

            pattern.* = ast.Pattern{ .IntLiteral = start_value };
            return pattern;
        }

        // Float literal pattern — reject infinity/NaN which would
        // silently never match any runtime value.
        if (self.match(&.{.Float})) {
            const token = self.previous();
            const value = try std.fmt.parseFloat(f64, token.lexeme);
            if (std.math.isInf(value) or std.math.isNan(value)) {
                try self.reportError("float pattern overflows to infinity or NaN and will never match");
                return error.UnexpectedToken;
            }
            pattern.* = ast.Pattern{ .FloatLiteral = value };
            return pattern;
        }

        // String literal pattern
        if (self.match(&.{.String})) {
            const token = self.previous();
            // Remove quotes from string
            const str_value = if (token.lexeme.len >= 2)
                token.lexeme[1 .. token.lexeme.len - 1]
            else
                token.lexeme;
            pattern.* = ast.Pattern{ .StringLiteral = try self.allocator.dupe(u8, str_value) };
            return pattern;
        }

        // Character literal pattern (treat as integer)
        if (self.match(&.{.Char})) {
            const token = self.previous();
            // Convert char to integer value
            var char_value: i64 = 0;
            const lexeme = token.lexeme;
            if (lexeme.len >= 3) {
                if (lexeme[1] == '\\' and lexeme.len >= 4) {
                    char_value = switch (lexeme[2]) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        'b' => 0x08,
                        '\\' => '\\',
                        '\'' => '\'',
                        '"' => '"',
                        '0' => 0,
                        else => lexeme[2],
                    };
                } else {
                    char_value = lexeme[1];
                }
            }
            pattern.* = ast.Pattern{ .IntLiteral = char_value };
            return pattern;
        }

        // Boolean literal pattern
        if (self.match(&.{.True})) {
            pattern.* = ast.Pattern{ .BoolLiteral = true };
            return pattern;
        }
        if (self.match(&.{.False})) {
            pattern.* = ast.Pattern{ .BoolLiteral = false };
            return pattern;
        }

        // Wildcard pattern '_'
        if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "_")) {
            _ = self.advance();
            pattern.* = ast.Pattern.Wildcard;
            return pattern;
        }

        // `else` as a default arm in match (mirrors switch-stmt semantics).
        // Treated as a wildcard so the AST stays unified.
        if (self.match(&.{.Else})) {
            pattern.* = ast.Pattern.Wildcard;
            return pattern;
        }

        // Tuple pattern: (pattern1, pattern2, ...)
        if (self.match(&.{.LeftParen})) {
            var elements = std.ArrayList(*ast.Pattern).empty;
            defer elements.deinit(self.allocator);

            if (!self.check(.RightParen)) {
                while (true) {
                    const elem = try self.parsePattern();
                    try elements.append(self.allocator, elem);

                    if (!self.match(&.{.Comma})) break;
                    if (self.check(.RightParen)) break; // Trailing comma
                }
            }

            _ = try self.expect(.RightParen, "Expected ')' after tuple pattern");
            pattern.* = ast.Pattern{ .Tuple = try elements.toOwnedSlice(self.allocator) };
            return pattern;
        }

        // Array pattern: [pattern1, pattern2, ..rest]
        if (self.match(&.{.LeftBracket})) {
            var elements = std.ArrayList(*ast.Pattern).empty;
            defer elements.deinit(self.allocator);
            var rest: ?[]const u8 = null;

            if (!self.check(.RightBracket)) {
                while (true) {
                    // Check for rest pattern ..name
                    if (self.match(&.{.DotDot})) {
                        const rest_name = try self.expect(.Identifier, "Expected identifier after '..'");
                        rest = rest_name.lexeme;
                        if (self.match(&.{.Comma})) {
                            // More patterns after rest (error in most languages, but we'll allow it)
                        }
                        break;
                    }

                    const elem = try self.parsePattern();
                    try elements.append(self.allocator, elem);

                    if (!self.match(&.{.Comma})) break;
                    if (self.check(.RightBracket)) break; // Trailing comma
                }
            }

            _ = try self.expect(.RightBracket, "Expected ']' after array pattern");
            pattern.* = ast.Pattern{
                .Array = .{
                    .elements = try elements.toOwnedSlice(self.allocator),
                    .rest = rest,
                },
            };
            return pattern;
        }

        // Zig-style leading-dot enum-tag pattern: `.Variant`, `.Variant(p)`,
        // or `.Variant{ .field = p }`. Treated as an enum-variant
        // pattern with a dotted qualifier — codegen lowers it the same
        // way as the namespaced form.
        if (self.check(.Dot) and self.peekNext().type == .Identifier) {
            _ = self.advance(); // consume '.'
            const variant_token = self.advance();
            const name = try std.fmt.allocPrint(self.allocator, ".{s}", .{variant_token.lexeme});
            // Optional payload: `.Variant(payload)`
            if (self.match(&.{.LeftParen})) {
                const payload = if (!self.check(.RightParen))
                    try self.parsePattern()
                else
                    null;
                _ = try self.expect(.RightParen, "Expected ')' after enum variant payload");
                pattern.* = ast.Pattern{
                    .EnumVariant = .{
                        .variant = name,
                        .payload = payload,
                    },
                };
                return pattern;
            }
            // Optional struct-shape payload: `.Variant{ .field = p }`
            if (self.match(&.{.LeftBrace})) {
                var fields = std.ArrayList(ast.Pattern.FieldPattern).empty;
                defer fields.deinit(self.allocator);
                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    _ = self.match(&.{.Dot});
                    const field_name_token = try self.expect(.Identifier, "Expected field name");
                    const field_name = field_name_token.lexeme;
                    var is_shorthand = false;
                    const field_pattern = if (self.match(&.{ .Colon, .Equal }))
                        try self.parsePattern()
                    else blk: {
                        is_shorthand = true;
                        const id_pattern = try self.allocator.create(ast.Pattern);
                        id_pattern.* = ast.Pattern{ .Identifier = field_name };
                        break :blk id_pattern;
                    };
                    try fields.append(self.allocator, .{
                        .name = field_name,
                        .pattern = field_pattern,
                        .shorthand = is_shorthand,
                    });
                    if (!self.match(&.{.Comma})) break;
                }
                _ = try self.expect(.RightBrace, "Expected '}' after struct fields");
                pattern.* = ast.Pattern{
                    .Struct = .{
                        .name = name,
                        .fields = try fields.toOwnedSlice(self.allocator),
                    },
                };
                return pattern;
            }
            pattern.* = ast.Pattern{ .EnumVariant = .{ .variant = name, .payload = null } };
            return pattern;
        }

        // Range pattern: start..end or start..=end
        // Check for identifier or number first
        if (self.check(.Integer) or self.check(.Identifier)) {
            const start_pos = self.current;

            // Try to parse as range
            const start_expr = try self.expression();

            if (self.match(&.{ .DotDot, .DotDotEqual })) {
                const is_inclusive = self.previous().type == .DotDotEqual;
                const end_expr = try self.expression();

                pattern.* = ast.Pattern{
                    .Range = .{
                        .start = start_expr,
                        .end = end_expr,
                        .inclusive = is_inclusive,
                    },
                };
                return pattern;
            }

            // Not a range, backtrack and parse as identifier or enum variant
            self.current = start_pos;
        }

        // Identifier, Struct pattern, or Enum variant pattern
        if (self.match(&.{.Identifier})) {
            const name_token = self.previous();
            var name = name_token.lexeme;

            // Check for qualified name: Type.Variant (or Rust-style Type::Variant)
            if (self.match(&.{ .Dot, .ColonColon })) {
                const variant_token = try self.expect(.Identifier, "Expected variant name after '.'");
                // Combine into qualified name
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, variant_token.lexeme });
                name = qualified;
            }

            // Check if it's a struct pattern: Name { field1, field2: pattern }
            if (self.match(&.{.LeftBrace})) {
                var fields = std.ArrayList(ast.Pattern.FieldPattern).empty;
                defer fields.deinit(self.allocator);

                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    const field_name_token = try self.expect(.Identifier, "Expected field name");
                    const field_name = field_name_token.lexeme;

                    // field: pattern or just field (shorthand)
                    var is_shorthand = false;
                    const field_pattern = if (self.match(&.{.Colon}))
                        try self.parsePattern()
                    else blk: {
                        // Shorthand: field is both the name and an identifier pattern
                        is_shorthand = true;
                        const id_pattern = try self.allocator.create(ast.Pattern);
                        id_pattern.* = ast.Pattern{ .Identifier = field_name };
                        break :blk id_pattern;
                    };

                    try fields.append(self.allocator, .{
                        .name = field_name,
                        .pattern = field_pattern,
                        .shorthand = is_shorthand,
                    });

                    if (!self.match(&.{.Comma})) break;
                }

                _ = try self.expect(.RightBrace, "Expected '}' after struct fields");
                pattern.* = ast.Pattern{
                    .Struct = .{
                        .name = name,
                        .fields = try fields.toOwnedSlice(self.allocator),
                    },
                };
                return pattern;
            }

            // Check if it's an enum variant: Variant(payload) or Variant
            if (self.match(&.{.LeftParen})) {
                const payload = if (!self.check(.RightParen))
                    try self.parsePattern()
                else
                    null;

                _ = try self.expect(.RightParen, "Expected ')' after enum variant");
                pattern.* = ast.Pattern{
                    .EnumVariant = .{
                        .variant = name,
                        .payload = payload,
                    },
                };
                return pattern;
            }

            // Just an identifier pattern (variable binding)
            pattern.* = ast.Pattern{ .Identifier = name };
            return pattern;
        }

        // Or pattern: pattern1 | pattern2 | pattern3
        // This is handled at a higher level by checking for '|' after parsing a pattern
        // For now, we just parse a single pattern

        try self.reportError("Expected pattern");
        return error.UnexpectedToken;
    }

    /// Parse a try-catch-finally statement, OR a Zig-style `try expr`
    /// error-propagation statement.
    ///
    /// Two forms share the leading `try` keyword:
    ///   1. `try { ... } catch { ... } finally { ... }` (JS/C++-style)
    ///      — produces a `TryStmt` with try/catch/finally blocks.
    ///   2. `try expr` (Zig-style error propagation, issue #60)
    ///      — produces an `ExprStmt` wrapping a `TryExpr` that the
    ///        type-checker / codegen lowers to `expr catch |err| return err`.
    ///
    /// Disambiguation: a `{` immediately after `try` selects form (1);
    /// any other follow-on token starts an expression and selects form (2).
    /// The expression form is also reachable via `primary()` for cases
    /// like `let x = try foo()`; see `tryElseExpr`.
    fn tryStatement(self: *Parser) !ast.Stmt {
        const try_token = self.previous();

        // Zig-style `try expr` propagation when not followed by `{`.
        // Reuse `tryElseExpr` so the optional `else default` tail and
        // any future expression-form extensions stay unified with the
        // existing expression-position parser.
        if (!self.check(.LeftBrace)) {
            const expr = try self.tryElseExpr();
            try self.optionalSemicolon();
            return ast.Stmt{ .ExprStmt = expr };
        }

        const try_block = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(try_block, self.allocator);

        var catch_clauses = std.ArrayList(*ast.CatchClause).empty;
        defer catch_clauses.deinit(self.allocator);

        // Parse catch clauses
        while (self.match(&.{.Catch})) {
            var error_name: ?[]const u8 = null;

            // Optional error name in parentheses
            if (self.match(&.{.LeftParen})) {
                if (self.check(.Identifier)) {
                    const error_token = self.advance();
                    error_name = error_token.lexeme;
                }
                _ = try self.expect(.RightParen, "Expected ')' after error name");
            }

            const catch_body = try self.blockStatement();

            const catch_clause = try ast.CatchClause.init(
                self.allocator,
                error_name,
                catch_body,
                ast.SourceLocation.fromToken(self.previous()),
            );

            try catch_clauses.append(self.allocator, catch_clause);
        }

        // Optional finally block
        var finally_block: ?*ast.BlockStmt = null;
        if (self.match(&.{.Finally})) {
            finally_block = try self.blockStatement();
        }

        const stmt = try ast.TryStmt.init(
            self.allocator,
            try_block,
            try catch_clauses.toOwnedSlice(self.allocator),
            finally_block,
            ast.SourceLocation.fromToken(try_token),
        );

        return ast.Stmt{ .TryStmt = stmt };
    }

    /// Parse a defer statement
    fn deferStatement(self: *Parser) !ast.Stmt {
        const defer_token = self.previous();

        const body = try self.expression();
        errdefer ast.Program.deinitExpr(body, self.allocator);

        const stmt = try ast.DeferStmt.init(
            self.allocator,
            body,
            ast.SourceLocation.fromToken(defer_token),
        );

        // Consume optional semicolon
        try self.optionalSemicolon();

        return ast.Stmt{ .DeferStmt = stmt };
    }

    /// Parse a break statement
    /// Syntax: break or break 'label
    fn breakStatement(self: *Parser) !ast.Stmt {
        const break_token = self.previous();

        // Check for optional label (starting with ')
        var label: ?[]const u8 = null;
        if (self.check(.Identifier) and self.peek().lexeme.len > 0 and self.peek().lexeme[0] == '\'') {
            const label_token = self.advance();
            label = label_token.lexeme[1..]; // Strip the leading '
        }

        const stmt = try ast.BreakStmt.init(
            self.allocator,
            label,
            ast.SourceLocation.fromToken(break_token),
        );

        // Consume optional semicolon
        try self.optionalSemicolon();

        return ast.Stmt{ .BreakStmt = stmt };
    }

    /// Parse a continue statement
    /// Syntax: continue or continue 'label
    fn continueStatement(self: *Parser) !ast.Stmt {
        const continue_token = self.previous();

        // Check for optional label (starting with ')
        var label: ?[]const u8 = null;
        if (self.check(.Identifier) and self.peek().lexeme.len > 0 and self.peek().lexeme[0] == '\'') {
            const label_token = self.advance();
            label = label_token.lexeme[1..]; // Strip the leading '
        }

        const stmt = try ast.ContinueStmt.init(
            self.allocator,
            label,
            ast.SourceLocation.fromToken(continue_token),
        );

        // Consume optional semicolon
        try self.optionalSemicolon();

        return ast.Stmt{ .ContinueStmt = stmt };
    }

    /// Parse either a `{ ... }` brace block or a single statement, and return
    /// it wrapped as a `BlockStmt`. Used for if/else branches so the body can
    /// be either form (e.g. `if (c) return 0;` vs `if (c) { return 0; }`).
    /// Downstream consumers always see a `BlockStmt`, matching the braced form.
    fn braceOrSingleStatementBlock(self: *Parser) ParseError!*ast.BlockStmt {
        if (self.check(.LeftBrace)) {
            return self.blockStatement();
        }

        // Single-statement form: parse one statement and wrap it in a block.
        // Suppress `expr else default` parsing inside the statement so a
        // trailing `else` belongs to the surrounding `if`. Without this,
        // `if (a) return 0 else return 1` parses `return 0 else return 1`
        // as a single Try-with-fallback expression and the outer `if` never
        // sees the `else`.
        const start_token = self.peek();
        self.suppress_else_in_expr += 1;
        const stmt = self.statement() catch |err| {
            self.suppress_else_in_expr -= 1;
            return err;
        };
        self.suppress_else_in_expr -= 1;

        const block = try self.allocator.create(ast.BlockStmt);
        var stmts_list = std.ArrayList(ast.Stmt).empty;
        errdefer {
            for (stmts_list.items) |s| ast.Program.deinitStmt(s, self.allocator);
            stmts_list.deinit(self.allocator);
            self.allocator.destroy(block);
        }
        try stmts_list.append(self.allocator, stmt);
        block.* = ast.BlockStmt{
            .node = .{ .type = .BlockStmt, .loc = ast.SourceLocation.fromToken(start_token) },
            .statements = try stmts_list.toOwnedSlice(self.allocator),
        };
        return block;
    }

    /// Parse a block statement
    pub fn blockStatement(self: *Parser) !*ast.BlockStmt {
        // Expect the opening brace (or use previous if already consumed)
        const start_token = if (self.previous().type == .LeftBrace)
            self.previous()
        else
            try self.expect(.LeftBrace, "Expected '{'");

        var statements = std.ArrayList(ast.Stmt).empty;
        defer statements.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            if (self.declaration()) |stmt| {
                try statements.append(self.allocator, stmt);
                self.panic_mode = false;
            } else |err| {
                // Error in block statement - synchronize but stay in block
                if (err == error.OutOfMemory) return err;

                // Skip tokens until we find a statement boundary or block end
                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    const current = self.peek();
                    if (current.type == .Let or current.type == .Const or
                        current.type == .If or current.type == .While or
                        current.type == .For or current.type == .Return)
                    {
                        break; // Found start of next statement
                    }
                    _ = self.advance();
                }
                self.panic_mode = false;
            }
        }

        _ = try self.expect(.RightBrace, "Expected '}' after block");

        const statements_slice = try statements.toOwnedSlice(self.allocator);
        errdefer {
            for (statements_slice) |stmt| {
                ast.Program.deinitStmt(stmt, self.allocator);
            }
            self.allocator.free(statements_slice);
        }

        return ast.BlockStmt.init(
            self.allocator,
            statements_slice,
            ast.SourceLocation.fromToken(start_token),
        );
    }

    /// Parse an expression statement
    fn expressionStatement(self: *Parser) !ast.Stmt {
        const expr = try self.expression();

        // Consume optional semicolon
        try self.optionalSemicolon();

        return ast.Stmt{ .ExprStmt = expr };
    }

    /// Parse an expression at assignment precedence level
    ///
    /// This is the main expression parsing entry point that handles all
    /// expressions starting from the lowest precedence level (assignments).
    ///
    /// Returns: Expression AST node
    /// Errors: ParseError if the expression is malformed
    pub fn expression(self: *Parser) !*ast.Expr {
        return self.parsePrecedence(.Assignment);
    }

    /// Parse expression using precedence climbing algorithm (Pratt parsing)
    ///
    /// Implements operator precedence parsing using the precedence climbing
    /// technique. This handles all binary, unary, and postfix operators with
    /// correct precedence and associativity. Tracks recursion depth to prevent
    /// stack overflow from deeply nested expressions.
    ///
    /// Parameters:
    ///   - precedence: Minimum precedence level to parse at
    ///
    /// Returns: Expression AST node
    /// Errors: ParseError on syntax errors, Overflow if expression is too deeply nested
    fn parsePrecedence(self: *Parser, precedence: Precedence) ParseError!*ast.Expr {
        // Check recursion depth to prevent stack overflow
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        if (self.recursion_depth > MAX_RECURSION_DEPTH) {
            try self.reportError("Expression is too deeply nested (maximum depth is 256)");
            return error.Overflow;
        }

        // Parse prefix expression
        var expr = try self.primary();

        // Parse postfix/infix expressions
        while (true) {
            // Module-qualified struct literal: after parsing `mod.Type`
            // (a MemberExpr), `{ . field = ... }` or `{ field : ... }`
            // becomes a struct literal whose type is the dotted path.
            // This complements the bare-identifier path inside `primary`
            // for literals like `Foo { .x = 1 }`.
            //
            // Only triggered when struct-literal parsing isn't suppressed
            // (e.g. inside an `if` / `while` condition) and the chained
            // expression resolves to a Member or Identifier whose
            // tail looks like a type name (PascalCase).
            if (self.suppress_struct_literal == 0 and
                self.check(.LeftBrace) and
                isTypeLikeExpr(expr))
            {
                const checkpoint = self.current;
                _ = self.advance(); // consume '{'
                if (self.isStructLiteralLookahead()) {
                    const dotted = try self.flattenDottedType(expr);
                    // Free the original expression tree — we adopted its
                    // identifier chain into `dotted`.
                    ast.Program.deinitExpr(expr, self.allocator);
                    expr = try self.finishStructLiteralOwned(dotted, expr.getLocation());
                    continue;
                }
                self.current = checkpoint;
            }

            const peek_prec = Precedence.fromToken(self.peek().type);
            if (@intFromEnum(precedence) > @intFromEnum(peek_prec)) break;
            // Newline-sensitive break: if the next token both starts a
            // new line AND could begin a fresh statement as a prefix
            // operator (`*x`, `&x`, `-x`, `+x`) or a parenthesized
            // expression (`(*p)[i] = ...`), treat the newline as a
            // statement terminator instead of continuing the current
            // expression. Without this:
            //   * `let x = 5\n(*p)[i] = ch` parses as `5(...)`, a
            //     function call, swallowing the next statement.
            //   * `let ns = &arr[i]\n*x = ns.field` parses as
            //     `&arr[i] * x = ns.field` — losing the binding.
            //   * `let v = denominator\n*p = block_num / v` similarly
            //     parses as multiplication.
            // We restrict this to operator tokens that have a
            // meaningful prefix form so ordinary infix continuation
            // (e.g. `a +\nb` or `cond &&\nrest`) still works.
            if (self.isAtNewLine()) {
                const t = self.peek().type;
                if (t == .Star or t == .Ampersand or t == .Minus or t == .Plus or
                    t == .LeftParen)
                {
                    break;
                }
                // Contextual soft keywords (`as`, `is`, `test`) at the
                // start of a new line are treated as the head of a fresh
                // statement, not as postfix operators on the prior
                // expression. Without this, `let x = null\n    as.foo = 1`
                // parses the second line as a type cast (`null as .foo`)
                // and emits a confusing "Expected type name" error.
                if (t == .As or t == .Is or t == .Test) {
                    break;
                }
            }
            if (self.match(&.{ .Plus, .Minus, .Star, .Slash, .Percent, .StarStar, .TildeSlash, .PlusBang, .MinusBang, .StarBang, .SlashBang, .PlusQuestion, .MinusQuestion, .StarQuestion, .SlashQuestion, .PlusPipe, .MinusPipe, .StarPipe })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{ .EqualEqual, .BangEqual, .Less, .LessEqual, .Greater, .GreaterEqual })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{.Is})) {
                expr = try self.isExpr(expr);
            } else if (self.match(&.{ .AmpersandAmpersand, .PipePipe, .And, .Or })) {
                expr = try self.binary(expr);
            } else if (self.check(.Pipe) and self.suppress_pipe_or == 0 and self.match(&.{.Pipe})) {
                expr = try self.binary(expr);
            } else if (self.match(&.{ .Ampersand, .Caret, .LeftShift, .RightShift })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{.As})) {
                expr = try self.typeCast(expr);
            } else if (self.match(&.{ .DotDot, .DotDotEqual })) {
                expr = try self.rangeExpr(expr);
            } else if (self.match(&.{.PipeGreater})) {
                expr = try self.pipeExpr(expr);
            } else if (self.match(&.{.Catch})) {
                // Zig-style `expr catch fallback` and
                // `expr catch |err| body` — the fallback expression
                // (or block) provides the value when expr is an error.
                // Optional `|err|` payload binds the error name; consumed
                // and discarded here since codegen reads the catch shape
                // off TryExpr.
                if (self.match(&.{.Pipe})) {
                    const tok = self.advance();
                    if (tok.type != .Identifier) {
                        try self.reportError("Expected error name in catch payload");
                        return error.UnexpectedToken;
                    }
                    _ = try self.expect(.Pipe, "Expected '|' after catch payload");
                }
                const catch_token = self.previous();
                const fallback = if (self.check(.LeftBrace)) blk: {
                    _ = self.advance();
                    break :blk try self.blockExprParse();
                } else try self.parsePrecedence(.Assignment);
                const try_expr = try ast.TryExpr.initWithElse(
                    self.allocator,
                    expr,
                    fallback,
                    ast.SourceLocation.fromToken(catch_token),
                );
                const result = try self.allocator.create(ast.Expr);
                result.* = ast.Expr{ .TryExpr = try_expr };
                expr = result;
            } else if (self.match(&.{.QuestionQuestion})) {
                expr = try self.nullCoalesceExpr(expr);
            } else if (self.match(&.{.QuestionColon})) {
                expr = try self.elvisExpr(expr);
            } else if (self.match(&.{.QuestionBracket})) {
                expr = try self.safeIndexExpr(expr);
            } else if (self.check(.Question) and self.canStartExpression(self.peekNext().type)) {
                // Ternary: cond ? true_val : false_val
                _ = self.advance(); // consume '?'
                expr = try self.ternaryExpr(expr);
            } else if (self.match(&.{.Equal})) {
                expr = try self.assignment(expr);
            } else if (self.match(&.{ .PlusEqual, .MinusEqual, .StarEqual, .SlashEqual, .PercentEqual, .PipeEqual, .AmpersandEqual, .CaretEqual, .LeftShiftEqual, .RightShiftEqual })) {
                expr = try self.compoundAssignment(expr);
            } else if (self.match(&.{.LeftParen})) {
                expr = try self.call(expr);
            } else if (self.match(&.{.LeftBracket})) {
                expr = try self.indexExpr(expr);
            } else if (self.match(&.{ .Dot, .ColonColon })) {
                // `::` is parsed identically to `.` (Rust-style path operator).
                expr = try self.memberExpr(expr);
            } else if (self.match(&.{.QuestionDot})) {
                expr = try self.safeNavExpr(expr);
            } else if (self.match(&.{.Question})) {
                expr = try self.tryExpr(expr);
            } else if (self.suppress_else_in_expr == 0 and self.match(&.{.Else})) {
                // expr else default - unwrap Result/Option with fallback.
                // Suppressed inside the body of a brace-less `if (cond) <stmt>`
                // so the `else` token is left for the surrounding `if`'s
                // dangling-else handling rather than being absorbed here.
                expr = try self.elseExpr(expr);
            } else if (self.match(&.{.OrElse})) {
                // expr orelse default - unwrap Optional with fallback
                // (semantically identical to `expr ?? default`). The
                // right-hand side accepts a control-flow expression
                // (`return`, `break`, `continue`) in addition to the
                // usual expression grammar.
                expr = try self.orelseExpr(expr);
            } else {
                break;
            }
        }

        return expr;
    }

    /// Parse a binary expression.
    /// Performs *early* constant folding for two integer literals — this
    /// turns `let SECONDS_PER_DAY = 60 * 60 * 24` into a single literal at
    /// parse time so the type checker, optimizer and codegen never even see
    /// the arithmetic. Folding bails out on overflow or division by zero so
    /// the user still sees a real diagnostic in those cases.
    fn binary(self: *Parser, left: *ast.Expr) !*ast.Expr {
        const op_token = self.previous();
        const op = try self.tokenToBinaryOp(op_token.type);
        const precedence = Precedence.fromToken(op_token.type);
        // Power (**) is right-associative: use same precedence so it binds right.
        const next_prec: u8 = if (op == .Power)
            @intFromEnum(precedence)
        else
            @intFromEnum(precedence) + 1;
        const right = try self.parsePrecedence(@enumFromInt(next_prec));

        if (foldIntegerBinary(op, left, right)) |folded| {
            // The IntegerLiteral operands are leaf nodes with no nested heap
            // data — free them so the folded result is the only allocation.
            self.allocator.destroy(left);
            self.allocator.destroy(right);
            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{
                .IntegerLiteral = ast.IntegerLiteral.init(
                    folded,
                    ast.SourceLocation.fromToken(op_token),
                ),
            };
            return result;
        }

        const binary_expr = try ast.BinaryExpr.init(
            self.allocator,
            op,
            left,
            right,
            ast.SourceLocation.fromToken(op_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .BinaryExpr = binary_expr };
        return result;
    }

    /// Try to fold a binary expression of two integer literals at parse time.
    /// Returns the folded value if both operands are IntegerLiterals AND the
    /// operation is total at runtime. Returns null otherwise; the caller
    /// falls back to constructing a BinaryExpr.
    pub fn foldIntegerBinary(op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) ?i128 {
        if (left.* != .IntegerLiteral) return null;
        if (right.* != .IntegerLiteral) return null;
        const a = left.IntegerLiteral.value;
        const b = right.IntegerLiteral.value;
        return switch (op) {
            .Add => std.math.add(i128, a, b) catch null,
            .Sub => std.math.sub(i128, a, b) catch null,
            .Mul => std.math.mul(i128, a, b) catch null,
            .Div => if (b == 0) null else @divTrunc(a, b),
            .Mod => if (b == 0) null else @rem(a, b),
            .BitAnd => a & b,
            .BitOr => a | b,
            .BitXor => a ^ b,
            .LeftShift => if (b < 0 or b >= 64) null else a << @as(u6, @intCast(b)),
            .RightShift => if (b < 0 or b >= 64) null else a >> @as(u6, @intCast(b)),
            else => null,
        };
    }

    /// Parse a range expression (e.g., 0..10, 1..=100)
    fn rangeExpr(self: *Parser, start: *ast.Expr) !*ast.Expr {
        const range_token = self.previous();
        const inclusive = range_token.type == .DotDotEqual;

        // Open-ended range: `start..` with no upper bound. Only valid
        // for `..` (exclusive) — `..=` requires an end. Detect by peek
        // at a token that clearly closes the surrounding context.
        const at_open_end = !inclusive and (self.check(.RightBracket) or
            self.check(.RightParen) or self.check(.Comma) or
            self.check(.RightBrace) or self.check(.Semicolon) or
            self.isAtNewLine());
        const end_expr = if (at_open_end) blk: {
            // Synthesize a placeholder integer literal as the end —
            // SliceExpr expects a non-null *Expr per the existing AST,
            // and downstream consumers treat the open-ended form via the
            // surrounding indexExpr path. The placeholder is harmless
            // because rangeExpr-as-stand-alone (outside `[]`) is rare.
            const placeholder = try self.allocator.create(ast.Expr);
            placeholder.* = ast.Expr{ .IntegerLiteral = ast.IntegerLiteral.init(0, ast.SourceLocation.fromToken(range_token)) };
            break :blk placeholder;
        } else blk: {
            const precedence = Precedence.fromToken(range_token.type);
            break :blk try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));
        };

        const range_expr = try ast.RangeExpr.init(
            self.allocator,
            start,
            end_expr,
            inclusive,
            ast.SourceLocation.fromToken(range_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .RangeExpr = range_expr };
        return result;
    }

    /// Parse a try-else expression (try expr else { default })
    /// Allows extracting values from Result/Option types with a fallback
    fn tryElseExpr(self: *Parser) !*ast.Expr {
        const try_token = self.previous();

        // Parse the expression to try
        const operand = try self.parsePrecedence(.Assignment);

        // Check for else branch
        var else_branch: ?*ast.Expr = null;
        if (self.match(&.{.Else})) {
            // Parse the else expression
            if (self.check(.LeftBrace)) {
                _ = self.advance();
                else_branch = try self.blockExprParse();
            } else {
                else_branch = try self.expression();
            }
        }

        // Create TryExpr with optional else branch
        const try_expr = if (else_branch) |eb|
            try ast.TryExpr.initWithElse(
                self.allocator,
                operand,
                eb,
                ast.SourceLocation.fromToken(try_token),
            )
        else
            try ast.TryExpr.init(
                self.allocator,
                operand,
                ast.SourceLocation.fromToken(try_token),
            );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .TryExpr = try_expr };
        return result;
    }

    /// Parse an else expression (expr else default) for unwrapping Result/Option with fallback
    /// This is syntactic sugar equivalent to: try expr else default
    fn elseExpr(self: *Parser, operand: *ast.Expr) !*ast.Expr {
        const else_token = self.previous();

        // Parse the else expression (default value)
        const else_branch = if (self.check(.LeftBrace)) blk: {
            _ = self.advance();
            break :blk try self.blockExprParse();
        } else try self.parsePrecedence(.Assignment);

        // Create TryExpr with else branch (same as 'try expr else default')
        const try_expr = try ast.TryExpr.initWithElse(
            self.allocator,
            operand,
            else_branch,
            ast.SourceLocation.fromToken(else_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .TryExpr = try_expr };
        return result;
    }

    /// Parse an orelse expression (expr orelse default) for unwrapping Optional
    /// with a fallback. Semantically identical to `expr ?? default` and to
    /// `expr else default`. Modeled on Zig's `orelse`, the right-hand side
    /// also accepts a control-flow expression — `return [value]`, `break`,
    /// or `continue` — so patterns like `let x = make() orelse return null`
    /// parse cleanly. Implementation reuses the existing TryExpr.initWithElse
    /// path so codegen and type-checking treat it the same as `??`.
    fn orelseExpr(self: *Parser, operand: *ast.Expr) !*ast.Expr {
        const orelse_token = self.previous();

        const else_branch = try self.parseControlFlowOrExpression();

        const try_expr = try ast.TryExpr.initWithElse(
            self.allocator,
            operand,
            else_branch,
            ast.SourceLocation.fromToken(orelse_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .TryExpr = try_expr };
        return result;
    }

    /// Parse the right-hand side of `orelse` / `catch`-style binary forms
    /// where `return [value]`, `break`, `continue`, or a `{ ... }` block
    /// are accepted in addition to the usual expression grammar.
    ///
    /// `break` and `continue` are wrapped in a `ReturnExpr` with a null
    /// value so existing code paths that walk the expression tree see a
    /// recognizable control-flow node; a future pass can introduce
    /// dedicated BreakExpr / ContinueExpr if/when the kernel needs to
    /// distinguish them.
    fn parseControlFlowOrExpression(self: *Parser) ParseError!*ast.Expr {
        if (self.check(.LeftBrace)) {
            _ = self.advance();
            return try self.blockExprParse();
        }
        if (self.match(&.{.Return})) {
            const ret_token = self.previous();
            const ret_value: ?*ast.Expr = if (self.check(.Comma) or
                self.check(.RightBrace) or self.check(.RightParen) or
                self.check(.RightBracket) or self.check(.Semicolon) or
                self.isAtEnd())
                null
            else
                try self.parsePrecedence(.Assignment);
            const return_expr = try ast.ReturnExpr.init(
                self.allocator,
                ret_value,
                ast.SourceLocation.fromToken(ret_token),
            );
            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .ReturnExpr = return_expr };
            return result;
        }
        if (self.match(&.{ .Break, .Continue })) {
            // No dedicated AST node for break/continue expressions yet —
            // wrap as a value-less ReturnExpr so the AST stays well-typed.
            // Callers that care about the distinction can inspect the
            // source token at the captured location.
            const cf_token = self.previous();
            const return_expr = try ast.ReturnExpr.init(
                self.allocator,
                null,
                ast.SourceLocation.fromToken(cf_token),
            );
            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .ReturnExpr = return_expr };
            return result;
        }
        return try self.parsePrecedence(.Assignment);
    }

    /// Parse an is expression for type narrowing (e.g., value is string, value is not null)
    fn isExpr(self: *Parser, value: *ast.Expr) !*ast.Expr {
        const is_token = self.previous();

        // Check for "is not" syntax
        const negated = self.match(&.{.Not});

        // Expect a type identifier after 'is' (or 'is not')
        const type_token = try self.expect(.Identifier, "Expected type name after 'is'");
        const type_name = type_token.lexeme;

        const is_expr = try ast.IsExpr.init(
            self.allocator,
            value,
            type_name,
            negated,
            ast.SourceLocation.fromToken(is_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .IsExpr = is_expr };
        return result;
    }

    /// Parse a type cast expression (e.g., value as i32, value as *u8).
    fn typeCast(self: *Parser, value: *ast.Expr) !*ast.Expr {
        const as_token = self.previous();

        // Delegate to the full type annotation parser so we accept the
        // same forms the rest of the grammar does: primitives, `*T`,
        // `[*]T`, `[N]T`, `&T`, `?T`, user struct names, etc.
        const target_type = try self.parseTypeAnnotation();

        const type_cast_expr = try ast.TypeCastExpr.init(
            self.allocator,
            value,
            target_type,
            ast.SourceLocation.fromToken(as_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .TypeCastExpr = type_cast_expr };
        return result;
    }

    /// Parse an assignment expression (e.g., x = 5)
    fn assignment(self: *Parser, target: *ast.Expr) !*ast.Expr {
        const assign_token = self.previous();

        // Validate that the target is a valid lvalue:
        //   - bare identifiers (`x = …`)
        //   - index expressions (`arr[i] = …`)
        //   - member access (`obj.field = …`)
        //   - unary expressions (`*ptr = …`)
        //   - tuple destructuring (`(a, b) = …`)
        //   - reflection expressions (`@ptrToInt(addr, T) = …`), which
        //     the kernel uses pervasively as a raw-memory store.
        //   - binary expressions (`*ptr + N = …`) — kernel often
        //     writes to computed addresses like `*(base + offset) = v`.
        switch (target.*) {
            .Identifier, .IndexExpr, .MemberExpr, .UnaryExpr, .TupleExpr, .ReflectExpr, .BinaryExpr => {},
            else => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Invalid assignment target ({s})",
                    .{@tagName(target.*)},
                );
                defer self.allocator.free(msg);
                try self.reportError(msg);
                return ParseError.UnexpectedToken;
            },
        }

        // Parse the right-hand side with assignment precedence
        const value = try self.parsePrecedence(.Assignment);

        const assign_expr = try ast.AssignmentExpr.init(
            self.allocator,
            target,
            value,
            ast.SourceLocation.fromToken(assign_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .AssignmentExpr = assign_expr };
        return result;
    }

    /// Parse a compound assignment expression (e.g., x += 5)
    /// Desugars to: x = x + 5
    fn compoundAssignment(self: *Parser, target: *ast.Expr) !*ast.Expr {
        const op_token = self.previous();
        const loc = ast.SourceLocation.fromToken(op_token);

        // Validate that the target is a valid lvalue (tuple not allowed for compound assignment)
        switch (target.*) {
            .Identifier, .IndexExpr, .MemberExpr, .UnaryExpr => {},
            else => {
                try self.reportError("Invalid assignment target");
                return ParseError.UnexpectedToken;
            },
        }

        // Parse the right-hand side
        const rhs = try self.parsePrecedence(.Assignment);

        // Determine the binary operator based on compound operator
        const bin_op: ast.BinaryOp = switch (op_token.type) {
            .PlusEqual => .Add,
            .MinusEqual => .Sub,
            .StarEqual => .Mul,
            .SlashEqual => .Div,
            .PercentEqual => .Mod,
            .PipeEqual => .BitOr,
            .AmpersandEqual => .BitAnd,
            .CaretEqual => .BitXor,
            .LeftShiftEqual => .LeftShift,
            .RightShiftEqual => .RightShift,
            else => unreachable,
        };

        // Clone the target for use in the binary expression
        // (we need target twice: once in the binary expr, once in the assignment)
        const target_copy = try self.allocator.create(ast.Expr);
        target_copy.* = target.*;

        // Create binary expression: target <op> rhs
        const bin_expr = try ast.BinaryExpr.init(
            self.allocator,
            bin_op,
            target_copy,
            rhs,
            loc,
        );
        const bin_expr_node = try self.allocator.create(ast.Expr);
        bin_expr_node.* = ast.Expr{ .BinaryExpr = bin_expr };

        // Create assignment: target = (target <op> rhs)
        const assign_expr = try ast.AssignmentExpr.init(
            self.allocator,
            target,
            bin_expr_node,
            loc,
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .AssignmentExpr = assign_expr };
        return result;
    }

    /// Parse a call expression (supports both positional and named arguments)
    fn call(self: *Parser, callee: *ast.Expr) !*ast.Expr {
        const lparen_token = self.previous();

        var args = std.ArrayList(*ast.Expr).empty;
        defer args.deinit(self.allocator);

        var named_args = std.ArrayList(ast.NamedArg).empty;
        defer named_args.deinit(self.allocator);

        var seen_named = false; // Track if we've seen a named argument

        // Inside `(...)` call-argument parsing, lift any outer
        // struct-literal suppression (used by while/if condition parsing).
        // The matching `)` is a hard boundary that an inner struct literal
        // cannot escape, so allowing literals here restores the natural
        // shape of e.g. `if check(Point { x: 1 }) { ... }`.
        const saved_suppress = self.suppress_struct_literal;
        self.suppress_struct_literal = 0;
        defer self.suppress_struct_literal = saved_suppress;

        if (!self.check(.RightParen)) {
            while (true) {
                // Check if this is a named argument: identifier followed by colon
                // We need to lookahead to distinguish between:
                //   - func(name: value)  -- named argument
                //   - func(expr)         -- positional argument
                if (self.check(.Identifier)) {
                    // Save position in case this isn't a named argument
                    const saved_pos = self.current;
                    const name_token = self.advance();

                    if (self.check(.Colon)) {
                        // This is a named argument
                        _ = self.advance(); // consume the colon
                        const value = try self.expression();
                        try named_args.append(self.allocator, .{
                            .name = name_token.lexeme,
                            .value = value,
                        });
                        seen_named = true;
                    } else {
                        // Not a named argument, backtrack and parse as expression
                        self.current = saved_pos;

                        if (seen_named) {
                            // Error: positional argument after named argument
                            try self.reportError("Positional arguments cannot follow named arguments");
                            return error.UnexpectedToken;
                        }

                        const arg = try self.expression();
                        try args.append(self.allocator, arg);
                    }
                } else {
                    // Not starting with identifier, must be positional
                    if (seen_named) {
                        // Error: positional argument after named argument
                        try self.reportError("Positional arguments cannot follow named arguments");
                        return error.UnexpectedToken;
                    }

                    const arg = try self.expression();
                    try args.append(self.allocator, arg);
                }

                if (!self.match(&.{.Comma})) break;
            }
        }

        _ = try self.expect(.RightParen, "Expected ')' after arguments");

        const call_expr = if (named_args.items.len > 0)
            try ast.CallExpr.initWithNamedArgs(
                self.allocator,
                callee,
                try args.toOwnedSlice(self.allocator),
                try named_args.toOwnedSlice(self.allocator),
                ast.SourceLocation.fromToken(lparen_token),
            )
        else
            try ast.CallExpr.init(
                self.allocator,
                callee,
                try args.toOwnedSlice(self.allocator),
                ast.SourceLocation.fromToken(lparen_token),
            );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .CallExpr = call_expr };
        return result;
    }

    /// Parse an index expression (array[index]) or slice expression (array[start..end])
    fn indexExpr(self: *Parser, array: *ast.Expr) !*ast.Expr {
        const bracket_token = self.previous();

        // Inside `[...]`, lift any outer struct-literal suppression — the
        // matching `]` bounds the index expression so a struct literal
        // here is unambiguous.
        const saved_suppress = self.suppress_struct_literal;
        self.suppress_struct_literal = 0;
        defer self.suppress_struct_literal = saved_suppress;

        // Check for slice starting from beginning: arr[..end] or arr[..=end]
        if (self.check(.DotDot) or self.check(.DotDotEqual)) {
            const inclusive = if (self.check(.DotDotEqual)) blk: {
                _ = self.advance(); // consume DotDotEqual
                break :blk true;
            } else blk: {
                _ = self.advance(); // consume DotDot
                break :blk false;
            };
            const end = try self.expression();
            _ = try self.expect(.RightBracket, "Expected ']' after slice");

            const slice_expr = try ast.SliceExpr.init(
                self.allocator,
                array,
                null, // start is null (beginning)
                end,
                inclusive,
                ast.SourceLocation.fromToken(bracket_token),
            );

            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .SliceExpr = slice_expr };
            return result;
        }

        // Parse first expression
        const first_expr = try self.expression();

        // Check if first_expr is already a RangeExpr (e.g., arr[1..3] parsed as arr[(1..3)])
        // In this case, convert it to a SliceExpr
        if (first_expr.* == .RangeExpr) {
            const range = first_expr.RangeExpr;
            _ = try self.expect(.RightBracket, "Expected ']' after slice");

            const slice_expr = try ast.SliceExpr.init(
                self.allocator,
                array,
                range.start,
                range.end,
                range.inclusive,
                ast.SourceLocation.fromToken(bracket_token),
            );

            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .SliceExpr = slice_expr };
            return result;
        }

        // Check if this is a slice: arr[start..end] or arr[start..=end] or arr[start..]
        if (self.check(.DotDot) or self.check(.DotDotEqual)) {
            const inclusive = if (self.check(.DotDotEqual)) blk: {
                _ = self.advance(); // consume DotDotEqual
                break :blk true;
            } else blk: {
                _ = self.advance(); // consume DotDot
                break :blk false;
            };

            // Check if there's an end expression or if it's arr[start..]
            var end: ?*ast.Expr = null;
            if (!self.check(.RightBracket)) {
                end = try self.expression();
            }

            _ = try self.expect(.RightBracket, "Expected ']' after slice");

            const slice_expr = try ast.SliceExpr.init(
                self.allocator,
                array,
                first_expr,
                end,
                inclusive,
                ast.SourceLocation.fromToken(bracket_token),
            );

            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .SliceExpr = slice_expr };
            return result;
        }

        // Not a slice, just a regular index expression
        _ = try self.expect(.RightBracket, "Expected ']' after index");

        const index_expr = try ast.IndexExpr.init(
            self.allocator,
            array,
            first_expr,
            ast.SourceLocation.fromToken(bracket_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .IndexExpr = index_expr };
        return result;
    }

    /// Parse a member access expression (struct.field) or optional unwrap (value.?)
    fn memberExpr(self: *Parser, object: *ast.Expr) !*ast.Expr {
        const dot_token = self.previous();

        // Check for .? optional unwrap syntax (? token follows the dot)
        if (self.match(&.{.Question})) {
            // Create a TryExpr for optional unwrap (reusing TryExpr semantics)
            const try_expr = try ast.TryExpr.init(
                self.allocator,
                object,
                ast.SourceLocation.fromToken(dot_token),
            );
            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .TryExpr = try_expr };
            return result;
        }

        // Lexer-fused `?[` after a dot (`.?[idx]`) — treat as optional
        // unwrap then index. Re-emits a synthetic LeftBracket so the
        // outer expression loop continues into indexExpr naturally.
        if (self.check(.QuestionBracket)) {
            _ = self.advance();
            const try_expr = try ast.TryExpr.init(
                self.allocator,
                object,
                ast.SourceLocation.fromToken(dot_token),
            );
            const unwrapped = try self.allocator.create(ast.Expr);
            unwrapped.* = ast.Expr{ .TryExpr = try_expr };
            // Inline an index expression here using the contents of the
            // brackets we just opened.
            const index = try self.expression();
            // Support range / open-ended ranges in index — already
            // covered by `expression`.
            _ = try self.expect(.RightBracket, "Expected ']' after index");
            const idx_expr = try ast.IndexExpr.init(
                self.allocator,
                unwrapped,
                index,
                unwrapped.getLocation(),
            );
            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .IndexExpr = idx_expr };
            return result;
        }

        // Check for .* pointer dereference syntax (* token follows the dot)
        if (self.match(&.{.Star})) {
            // Create a UnaryExpr for pointer dereference
            const unary_expr = try ast.UnaryExpr.init(
                self.allocator,
                .Deref,
                object,
                ast.SourceLocation.fromToken(dot_token),
            );
            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .UnaryExpr = unary_expr };
            return result;
        }

        // Check for .?. syntax: QuestionDot token follows the dot (lexer combined ?. into one token)
        // This handles the case where we have value.?.field (the ?. became QuestionDot)
        if (self.match(&.{.QuestionDot})) {
            // First create the unwrap (TryExpr) for the .? part
            const try_expr = try ast.TryExpr.init(
                self.allocator,
                object,
                ast.SourceLocation.fromToken(dot_token),
            );
            const unwrapped = try self.allocator.create(ast.Expr);
            unwrapped.* = ast.Expr{ .TryExpr = try_expr };

            // Now parse the member access that follows (the . part of ?.)
            return self.memberExpr(unwrapped);
        }

        // Accept Identifier, keywords, or integer literal as field name
        // Integer literals support tuple field access like .0, .1, .2
        // Keywords support allows fields named with reserved words (e.g., self.type, cell.match)
        const member_token = if (self.match(&.{.Identifier}))
            self.previous()
        else if (self.match(&.{.Type}))
            self.previous()
        else if (self.match(&.{.Default}))
            self.previous()
        else if (self.match(&.{.Integer}))
            self.previous()
        else if (self.match(&.{.Match}))
            self.previous()
        else if (self.match(&.{.And}))
            self.previous()
        else if (self.match(&.{.Or}))
            self.previous()
        else if (self.match(&.{.Not}))
            self.previous()
        else if (self.match(&.{.As}))
            self.previous()
        else if (self.match(&.{.In}))
            self.previous()
        else if (self.match(&.{.Const}))
            self.previous()
        else if (self.match(&.{.Static}))
            self.previous()
        else if (self.match(&.{.Mut}))
            self.previous()
        else if (self.match(&.{.Pub}))
            self.previous()
        else if (self.match(&.{.Async}))
            self.previous()
        else if (self.match(&.{.Await}))
            self.previous()
        else if (self.match(&.{.Try}))
            self.previous()
        else if (self.match(&.{.Catch}))
            self.previous()
        else if (self.match(&.{.If}))
            self.previous()
        else if (self.match(&.{.Else}))
            self.previous()
        else if (self.match(&.{.For}))
            self.previous()
        else if (self.match(&.{.While}))
            self.previous()
        else if (self.match(&.{.Loop}))
            self.previous()
        else if (self.match(&.{.Break}))
            self.previous()
        else if (self.match(&.{.Continue}))
            self.previous()
        else if (self.match(&.{.Return}))
            self.previous()
        else if (self.match(&.{.Fn}))
            self.previous()
        else if (self.match(&.{.Struct}))
            self.previous()
        else if (self.match(&.{.Enum}))
            self.previous()
        else if (self.match(&.{.Union}))
            self.previous()
        else if (self.match(&.{.Trait}))
            self.previous()
        else if (self.match(&.{.Impl}))
            self.previous()
        else if (self.match(&.{.Let}))
            self.previous()
        else if (self.match(&.{.Var}))
            self.previous()
        else if (self.match(&.{.True}))
            self.previous()
        else if (self.match(&.{.False}))
            self.previous()
        else if (self.match(&.{.Null}))
            self.previous()
        else if (self.match(&.{.Test}))
            self.previous()
        else if (self.match(&.{.Import}))
            self.previous()
        else if (self.match(&.{.It}))
            self.previous()
        else if (self.match(&.{.SelfValue}))
            self.previous()
        else blk: {
            try self.reportError("Expected field name after '.'");
            break :blk self.previous();
        };

        const member_expr = try ast.MemberExpr.init(
            self.allocator,
            object,
            member_token.lexeme,
            ast.SourceLocation.fromToken(dot_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .MemberExpr = member_expr };
        return result;
    }

    /// Parse a try expression (error propagation with ?)
    fn tryExpr(self: *Parser, operand: *ast.Expr) !*ast.Expr {
        const question_token = self.previous();

        const try_expr = try ast.TryExpr.init(
            self.allocator,
            operand,
            ast.SourceLocation.fromToken(question_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .TryExpr = try_expr };
        return result;
    }

    /// Parse a ternary expression (condition ? true_val : false_val)
    fn ternaryExpr(self: *Parser, condition: *ast.Expr) !*ast.Expr {
        const question_token = self.previous();

        // Both branches parse at Ternary precedence so nested
        // ternaries `a ? b ? c : d : e` associate correctly.
        const true_val = try self.parsePrecedence(.Ternary);
        _ = try self.expect(.Colon, "Expected ':' after true branch of ternary expression");
        const false_val = try self.parsePrecedence(.Ternary);

        const ternary_expr = try ast.TernaryExpr.init(
            self.allocator,
            condition,
            true_val,
            false_val,
            ast.SourceLocation.fromToken(question_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .TernaryExpr = ternary_expr };
        return result;
    }

    /// Parse a pipe expression (value |> function)
    fn pipeExpr(self: *Parser, left: *ast.Expr) !*ast.Expr {
        const pipe_token = self.previous();
        const precedence = Precedence.fromToken(pipe_token.type);
        const right = try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));

        const pipe_expr = try ast.PipeExpr.init(
            self.allocator,
            left,
            right,
            ast.SourceLocation.fromToken(pipe_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .PipeExpr = pipe_expr };
        return result;
    }

    /// Parse a null coalescing expression (value ?? default)
    fn nullCoalesceExpr(self: *Parser, left: *ast.Expr) !*ast.Expr {
        const null_token = self.previous();
        const precedence = Precedence.fromToken(null_token.type);
        const right = try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));

        const null_coalesce_expr = try ast.NullCoalesceExpr.init(
            self.allocator,
            left,
            right,
            ast.SourceLocation.fromToken(null_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .NullCoalesceExpr = null_coalesce_expr };
        return result;
    }

    /// Parse a safe navigation expression (object?.member)
    fn safeNavExpr(self: *Parser, object: *ast.Expr) !*ast.Expr {
        const safe_nav_token = self.previous();
        const member_token = try self.expect(.Identifier, "Expected member name after '?.'");

        const safe_nav_expr = try ast.SafeNavExpr.init(
            self.allocator,
            object,
            member_token.lexeme,
            ast.SourceLocation.fromToken(safe_nav_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .SafeNavExpr = safe_nav_expr };
        return result;
    }

    /// Parse an Elvis expression (value ?: default)
    fn elvisExpr(self: *Parser, left: *ast.Expr) !*ast.Expr {
        const elvis_token = self.previous();
        const precedence = Precedence.fromToken(elvis_token.type);
        const right = try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));

        const elvis_expr = try ast.ElvisExpr.init(
            self.allocator,
            left,
            right,
            ast.SourceLocation.fromToken(elvis_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .ElvisExpr = elvis_expr };
        return result;
    }

    /// Parse a safe index expression (array?[index])
    fn safeIndexExpr(self: *Parser, object: *ast.Expr) !*ast.Expr {
        const safe_index_token = self.previous();
        // The ?[ token already consumed the '[', so we just need the index and ']'
        const index = try self.expression();
        _ = try self.expect(.RightBracket, "Expected ']' after safe index expression");

        const safe_index_expr = try ast.SafeIndexExpr.init(
            self.allocator,
            object,
            index,
            ast.SourceLocation.fromToken(safe_index_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .SafeIndexExpr = safe_index_expr };
        return result;
    }

    /// Parse an if expression: if condition { expr } else { expr }
    /// Parentheses around the condition are optional
    ///
    /// Three body forms are supported in expression position:
    ///   1. Brace form:  `if cond { expr } else { expr }`
    ///   2. Then form:   `if cond then expr else expr`     (soft keyword)
    ///   3. Bare form:   `if (cond) expr else expr`        (issue #54 —
    ///      lets if-as-expression nest cleanly inside argument lists,
    ///      struct-field initializers, let initializers, etc.)
    ///
    /// In the bare form each arm is parsed at `.Or` precedence so the
    /// `else` token (which sits at NullCoalesce) reliably terminates the
    /// then-branch. `else` is mandatory; an if-without-else used as an
    /// expression is a type error caught downstream.
    fn ifExpr(self: *Parser) !*ast.Expr {
        const if_token = self.previous();
        // Parse condition - let expression() handle all grouping naturally.
        const condition = try self.expression();

        const uses_then =
            self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "then");
        const uses_brace = !uses_then and self.check(.LeftBrace);

        var then_branch: *ast.Expr = undefined;
        if (uses_then) {
            _ = self.advance();
            // Parse with Or-level precedence so `else` (which lives at
            // NullCoalesce) stops the expression parser and is picked
            // up as the branch separator below.
            then_branch = try self.parsePrecedence(.Or);
        } else if (uses_brace) {
            _ = self.advance(); // consume `{`
            then_branch = try self.expression();
            _ = try self.expect(.RightBrace, "Expected '}' after if expression body");
        } else {
            // Bare expression form (issue #54): the arm is just an
            // expression. Parse at Or-precedence so `else` terminates it.
            then_branch = try self.parsePrecedence(.Or);
        }

        _ = try self.expect(.Else, "If expression requires 'else' branch");

        // Handle else if as a nested if expression
        var else_branch: *ast.Expr = undefined;
        if (self.match(&.{.If})) {
            // Recursively parse else if as another if expression
            else_branch = try self.ifExpr();
        } else if (uses_brace and self.check(.LeftBrace)) {
            _ = self.advance();
            else_branch = try self.expression();
            _ = try self.expect(.RightBrace, "Expected '}' after else expression body");
        } else if (uses_then) {
            else_branch = try self.parsePrecedence(.Or);
        } else {
            // Bare expression else-branch — full expression precedence
            // since nothing follows that needs to be reserved.
            else_branch = try self.expression();
        }

        const if_expr = try ast.IfExpr.init(
            self.allocator,
            condition,
            then_branch,
            else_branch,
            ast.SourceLocation.fromToken(if_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .IfExpr = if_expr };
        return result;
    }

    /// Parse value expression for match - handles identifier, literals, member access
    /// but NOT struct literals (to avoid confusion with match body braces)
    fn parseMatchValue(self: *Parser) !*ast.Expr {
        // Use expression() with struct-literal suppression so the body's
        // `{` doesn't get folded into the value as `X { fields }`. This
        // keeps support for prefix `&`, `&mut`, `*`, binary ops in the
        // value (e.g. `match pin / 16 {`, `match &mut x {`) which the
        // previous restricted parser dropped.
        self.suppress_struct_literal += 1;
        const expr_full = self.expression() catch |err| {
            self.suppress_struct_literal -= 1;
            return err;
        };
        self.suppress_struct_literal -= 1;
        return expr_full;
    }

    fn parseMatchValueLegacy(self: *Parser) !*ast.Expr {
        // Parse the base expression (identifier, literal, parenthesized)
        var expr = try self.parseMatchValuePrimary();

        // Handle member access and calls, but NOT struct literals
        while (true) {
            if (self.match(&.{ .Dot, .ColonColon })) {
                const member_token = try self.expect(.Identifier, "Expected member name after '.'");
                const member_expr = try ast.MemberExpr.init(
                    self.allocator,
                    expr,
                    member_token.lexeme,
                    ast.SourceLocation.fromToken(member_token),
                );
                expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .MemberExpr = member_expr };
            } else if (self.match(&.{.LeftParen})) {
                // Function call
                var args = std.ArrayList(*ast.Expr).empty;
                defer args.deinit(self.allocator);

                if (!self.check(.RightParen)) {
                    while (true) {
                        const arg = try self.expression();
                        try args.append(self.allocator, arg);
                        if (!self.match(&.{.Comma})) break;
                    }
                }
                _ = try self.expect(.RightParen, "Expected ')' after arguments");

                const call_expr = try ast.CallExpr.init(
                    self.allocator,
                    expr,
                    try args.toOwnedSlice(self.allocator),
                    expr.getLocation(),
                );
                expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .CallExpr = call_expr };
            } else if (self.match(&.{.LeftBracket})) {
                // Index expression
                const index = try self.expression();
                _ = try self.expect(.RightBracket, "Expected ']' after index");
                const index_expr = try ast.IndexExpr.init(
                    self.allocator,
                    expr,
                    index,
                    expr.getLocation(),
                );
                expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .IndexExpr = index_expr };
            } else {
                break;
            }
        }
        return expr;
    }

    /// Parse primary expression for match value (no struct literals)
    fn parseMatchValuePrimary(self: *Parser) !*ast.Expr {
        if (self.match(&.{.Identifier})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Handle 'self' keyword
        if (self.match(&.{.SelfValue})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        if (self.match(&.{.Integer})) {
            const token = self.previous();
            const value = std.fmt.parseInt(i64, token.lexeme, 10) catch 0;
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .IntegerLiteral = ast.IntegerLiteral.init(value, ast.SourceLocation.fromToken(token)) };
            return expr;
        }

        if (self.match(&.{.String})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .StringLiteral = ast.StringLiteral.init(token.lexeme, ast.SourceLocation.fromToken(token)) };
            return expr;
        }

        if (self.match(&.{.Char})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .CharLiteral = ast.CharLiteral.init(token.lexeme, ast.SourceLocation.fromToken(token)) };
            return expr;
        }

        if (self.match(&.{.True})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .BooleanLiteral = ast.BooleanLiteral.init(true, ast.SourceLocation.fromToken(token)) };
            return expr;
        }

        if (self.match(&.{.False})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .BooleanLiteral = ast.BooleanLiteral.init(false, ast.SourceLocation.fromToken(token)) };
            return expr;
        }

        if (self.match(&.{.LeftParen})) {
            const expr = try self.expression();
            _ = try self.expect(.RightParen, "Expected ')' after expression");
            return expr;
        }

        try self.reportError("Expected expression for match value");
        return error.UnexpectedToken;
    }

    /// Parse a pattern for match expressions - handles struct patterns specially
    /// Struct pattern: Point { x, y } -> creates struct literal with field identifiers
    fn parseMatchExprPattern(self: *Parser) !*ast.Expr {
        // Check for identifier potentially followed by struct pattern
        if (self.check(.Identifier)) {
            const start_pos = self.current;
            const name_token = self.advance();
            const type_name = try self.allocator.dupe(u8, name_token.lexeme);
            errdefer self.allocator.free(type_name);

            // Check for struct pattern: Name { field1, field2 }
            if (self.match(&.{.LeftBrace})) {
                // Parse struct pattern fields
                var fields = std.ArrayList(ast.FieldInit).empty;
                defer fields.deinit(self.allocator);

                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    const field_token = try self.expect(.Identifier, "Expected field name");
                    const field_name = try self.allocator.dupe(u8, field_token.lexeme);
                    errdefer self.allocator.free(field_name);
                    const field_loc = ast.SourceLocation.fromToken(field_token);

                    // Check for explicit value: field: expr or shorthand: just field
                    var is_shorthand = false;
                    const field_value = if (self.match(&.{.Colon}))
                        try self.expression()
                    else blk: {
                        // Shorthand: field name is used as identifier expression
                        is_shorthand = true;
                        const id_expr = try self.allocator.create(ast.Expr);
                        id_expr.* = ast.Expr{
                            .Identifier = ast.Identifier.init(field_token.lexeme, field_loc),
                        };
                        break :blk id_expr;
                    };

                    try fields.append(self.allocator, ast.FieldInit.init(
                        field_name,
                        field_value,
                        is_shorthand,
                        field_loc,
                    ));

                    if (!self.match(&.{.Comma})) break;
                }

                _ = try self.expect(.RightBrace, "Expected '}' after struct pattern");

                // Create a struct literal expression for this pattern
                const struct_lit = ast.StructLiteralExpr.init(
                    type_name,
                    try fields.toOwnedSlice(self.allocator),
                    false, // not anonymous
                    ast.SourceLocation.fromToken(name_token),
                );
                const result = try self.allocator.create(ast.Expr);
                const struct_lit_ptr = try self.allocator.create(ast.StructLiteralExpr);
                struct_lit_ptr.* = struct_lit;
                result.* = ast.Expr{ .StructLiteral = struct_lit_ptr };
                return result;
            }

            // Not a struct pattern, backtrack and use normal expression
            self.allocator.free(type_name);
            self.current = start_pos;
        }

        // Fall back to normal expression parsing
        return try self.expression();
    }

    /// Parse a match expression: match value { pattern => expr, ... }
    fn matchExpr(self: *Parser) !*ast.Expr {
        const match_token = self.previous();
        // Parse value - use a simpler approach: just get the primary and handle
        // member/call chains manually to avoid struct literal confusion
        const value = try self.parseMatchValue();

        _ = try self.expect(.LeftBrace, "Expected '{' after match value");

        var arms = std.ArrayList(ast.MatchExprArm).empty;
        defer arms.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            // Parse pattern - use special pattern parser that handles struct patterns
            const pattern = try self.parseMatchExprPattern();

            // Parse optional guard: if condition
            var guard: ?*ast.Expr = null;
            if (self.match(&.{.If})) {
                guard = try self.expression();
            }

            _ = try self.expect(.FatArrow, "Expected '=>' after match pattern");

            // Parse body expression. Mirror match-statement behavior:
            // bare `return [expr]` is allowed (kernel uses arms like
            // `None => return -1` for early exits) — wrap into a
            // ReturnExpr so the AST stays a single Expr.
            const body = blk: {
                if (self.check(.Return)) {
                    _ = self.advance();
                    const ret_value = if (!self.check(.Comma) and !self.check(.RightBrace) and !self.check(.Semicolon))
                        try self.expression()
                    else
                        null;
                    const return_expr = try ast.ReturnExpr.init(
                        self.allocator,
                        ret_value,
                        ast.SourceLocation.fromToken(self.previous()),
                    );
                    const wrap = try self.allocator.create(ast.Expr);
                    wrap.* = ast.Expr{ .ReturnExpr = return_expr };
                    break :blk wrap;
                }
                break :blk try self.expression();
            };

            try arms.append(self.allocator, .{
                .pattern = pattern,
                .guard = guard,
                .body = body,
            });

            // Allow optional comma between arms
            _ = self.match(&.{.Comma});
        }

        _ = try self.expect(.RightBrace, "Expected '}' after match arms");

        // Copy arms to owned slice
        const arms_slice = try self.allocator.alloc(ast.MatchExprArm, arms.items.len);
        @memcpy(arms_slice, arms.items);

        const match_expr = try ast.MatchExpr.init(
            self.allocator,
            value,
            arms_slice,
            ast.SourceLocation.fromToken(match_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .MatchExpr = match_expr };
        return result;
    }

    /// Parse a single switch-arm pattern. Adds support for the leading-dot
    /// enum-literal shorthand (`.INFO`, `.WARNING` …) on top of the broader
    /// expression-pattern grammar `parseMatchExprPattern` already covers.
    /// The shorthand isn't a valid expression in primary position, so we
    /// must intercept it here before falling back to `expression()`.
    fn parseSwitchArmPattern(self: *Parser) ParseError!*ast.Expr {
        if (self.match(&.{.Dot})) {
            const dot_tok = self.previous();
            const ident_tok = if (self.check(.Identifier) or self.check(.Type))
                self.advance()
            else {
                try self.reportError("Expected identifier after '.' in switch pattern");
                return error.UnexpectedToken;
            };
            // Build `.IDENT` as a member access on a synthesized empty
            // base. The pattern engine doesn't actually use the base —
            // only the trailing identifier — so any consistent
            // placeholder works.
            const base_expr = try self.allocator.create(ast.Expr);
            base_expr.* = ast.Expr{
                .Identifier = ast.Identifier.init("", ast.SourceLocation.fromToken(dot_tok)),
            };
            const member_expr = try ast.MemberExpr.init(
                self.allocator,
                base_expr,
                ident_tok.lexeme,
                ast.SourceLocation.fromToken(ident_tok),
            );
            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .MemberExpr = member_expr };
            return result;
        }
        return try self.parseMatchExprPattern();
    }

    /// Parse a switch expression: `switch (value) { Pattern => body, ... }`.
    ///
    /// Lowered onto the existing `MatchExpr` AST node so the type checker,
    /// pattern engine and codegen don't need a parallel code path. Behaves
    /// like a match expression with a few syntactic differences:
    ///   * Subject is wrapped in parens (parens optional too).
    ///   * Default arm is spelled `else =>` (or `_ =>`).
    ///   * Body forms accepted: block (`{ ... }`), `return [expr]`, or a
    ///     bare expression — same set the statement-form switch accepts.
    fn switchExpr(self: *Parser) ParseError!*ast.Expr {
        const switch_token = self.previous();
        // Subject — accept parenthesized or bare. Use parseMatchValue so a
        // trailing `{` is reserved for the arm list, not slurped as a
        // struct literal.
        var value: *ast.Expr = undefined;
        if (self.match(&.{.LeftParen})) {
            value = try self.expression();
            _ = try self.expect(.RightParen, "Expected ')' after switch value");
        } else {
            value = try self.parseMatchValue();
        }

        _ = try self.expect(.LeftBrace, "Expected '{' after switch value");

        var arms = std.ArrayList(ast.MatchExprArm).empty;
        defer arms.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            // Pattern list: either `else` (default arm) or one-or-more
            // comma-separated patterns. Multi-pattern arms (issue #63) are
            // lowered into multiple `MatchExprArm` entries that share the
            // body and guard expression — downstream consumers iterate arms
            // independently so this preserves match-first-arm semantics with
            // zero changes to type checker / pattern engine / codegen.
            var patterns = std.ArrayList(*ast.Expr).empty;
            defer patterns.deinit(self.allocator);

            if (self.match(&.{.Else})) {
                const else_tok = self.previous();
                const wildcard = try self.allocator.create(ast.Expr);
                wildcard.* = ast.Expr{
                    .Identifier = ast.Identifier.init("_", ast.SourceLocation.fromToken(else_tok)),
                };
                try patterns.append(self.allocator, wildcard);
            } else {
                const first_pattern = try self.parseSwitchArmPattern();
                try patterns.append(self.allocator, first_pattern);

                while (self.match(&.{.Comma}) and !self.check(.FatArrow)) {
                    const next_pattern = try self.parseSwitchArmPattern();
                    try patterns.append(self.allocator, next_pattern);
                }
            }

            // Optional guard: `if cond`.
            var guard: ?*ast.Expr = null;
            if (self.match(&.{.If})) {
                guard = try self.expression();
            }

            _ = try self.expect(.FatArrow, "Expected '=>' after switch pattern");

            // Body — block / return / bare expression. Mirrors matchStatement.
            var body: *ast.Expr = undefined;
            if (self.check(.LeftBrace)) {
                _ = self.advance();
                body = try self.blockExprParse();
            } else if (self.check(.Return)) {
                _ = self.advance();
                const ret_value: ?*ast.Expr = if (!self.check(.Comma) and !self.check(.RightBrace) and !self.check(.Semicolon))
                    try self.expression()
                else
                    null;
                const ret_expr = try ast.ReturnExpr.init(
                    self.allocator,
                    ret_value,
                    ast.SourceLocation.fromToken(self.previous()),
                );
                body = try self.allocator.create(ast.Expr);
                body.* = ast.Expr{ .ReturnExpr = ret_expr };
            } else {
                body = try self.expression();
            }

            // Trailing comma (or newline) between arms.
            _ = self.match(&.{.Comma});

            // Emit one arm per pattern. body/guard pointers are shared
            // between siblings — this is safe because `MatchExpr` deinit
            // doesn't recurse into arm bodies, and downstream passes treat
            // arms as read-only.
            for (patterns.items) |pat| {
                try arms.append(self.allocator, .{
                    .pattern = pat,
                    .guard = guard,
                    .body = body,
                });
            }
        }

        _ = try self.expect(.RightBrace, "Expected '}' after switch arms");

        const arms_slice = try self.allocator.alloc(ast.MatchExprArm, arms.items.len);
        @memcpy(arms_slice, arms.items);

        const match_expr = try ast.MatchExpr.init(
            self.allocator,
            value,
            arms_slice,
            ast.SourceLocation.fromToken(switch_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .MatchExpr = match_expr };
        return result;
    }

    /// Parse a block expression: { stmt1; stmt2; ... }
    /// The opening brace should already be consumed
    fn blockExprParse(self: *Parser) !*ast.Expr {
        const brace_token = self.previous();

        var statements = std.ArrayList(ast.Stmt).empty;
        defer statements.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            if (self.declaration()) |stmt| {
                try statements.append(self.allocator, stmt);
                self.panic_mode = false;
            } else |err| {
                if (err == error.OutOfMemory) return err;

                // Skip tokens until we find a statement boundary or block end
                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    const current = self.peek();
                    if (current.type == .Let or current.type == .Const or
                        current.type == .If or current.type == .While or
                        current.type == .For or current.type == .Return)
                    {
                        break;
                    }
                    _ = self.advance();
                }
                self.panic_mode = false;
            }
        }

        _ = try self.expect(.RightBrace, "Expected '}' after block");

        const statements_slice = try statements.toOwnedSlice(self.allocator);

        const block_expr = try ast.BlockExpr.init(
            self.allocator,
            statements_slice,
            ast.SourceLocation.fromToken(brace_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .BlockExpr = block_expr };
        return result;
    }

    /// Lookahead helper: assuming the parser has just consumed `{` of a
    /// possible struct literal, decide whether the following tokens
    /// match a struct-literal field list.
    ///
    /// Recognizes:
    ///   1. `}` (empty struct literal)
    ///   2. `IDENT :` (TS-style: `Foo { x: 1 }`)
    ///   3. `. IDENT =` (Zig-style: `Foo { .x = 1 }`)
    ///   4. `. IDENT ,` or `. IDENT }` (Zig-style shorthand: `Foo { .x }`)
    ///   5. `IDENT , IDENT` or `IDENT } ` — error-set variant list
    ///      (`error { NotFound, PermissionDenied }`); treated as
    ///      struct-literal-shaped only when invoked from the error-set
    ///      path. Bare-identifier callers reject this so that an
    ///      ordinary block `{ name }` isn't mistaken for a literal.
    fn isStructLiteralLookahead(self: *Parser) bool {
        // Empty braces {} could be struct literal
        if (self.check(.RightBrace)) return true;

        // Zig-style `.field = value` or `.field` shorthand
        if (self.check(.Dot)) {
            const after_dot = self.current + 1;
            if (after_dot < self.tokens.len and
                (self.tokens[after_dot].type == .Identifier or self.tokens[after_dot].type == .Type))
            {
                const after_field = self.current + 2;
                if (after_field < self.tokens.len) {
                    const t = self.tokens[after_field].type;
                    if (t == .Equal or t == .Comma or t == .RightBrace) {
                        return true;
                    }
                }
            }
            return false;
        }

        // TS-style `field: value`
        if (self.check(.Identifier) or self.check(.Type)) {
            const after_ident_pos = self.current + 1;
            if (after_ident_pos < self.tokens.len) {
                if (self.tokens[after_ident_pos].type == .Colon) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Parse the body of a struct literal (the part between `{` and `}`),
    /// then consume the closing `}` and produce a StructLiteralExpr.
    /// `type_name_owned` is taken to be already heap-allocated and is
    /// adopted by the resulting AST node.
    fn finishStructLiteralOwned(
        self: *Parser,
        type_name_owned: []const u8,
        loc: ast.SourceLocation,
    ) ParseError!*ast.Expr {
        var fields = std.ArrayList(ast.FieldInit).empty;
        defer fields.deinit(self.allocator);

        var positional_index: usize = 0;
        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            // Disambiguate named vs. positional entries:
            //   `.IDENT =` / `.IDENT :` → named with leading dot
            //   `IDENT :`               → TS-style named
            //   otherwise               → positional (parse as expression)
            const start_loc = ast.SourceLocation.fromToken(self.peek());
            const is_named = blk: {
                if (self.check(.Dot)) {
                    const t1 = self.peekNext().type;
                    if (t1 != .Identifier and t1 != .Type) break :blk false;
                    const t2 = if (self.current + 2 < self.tokens.len)
                        self.tokens[self.current + 2].type
                    else
                        .Eof;
                    break :blk (t2 == .Equal or t2 == .Colon);
                }
                if (self.check(.Identifier) or self.check(.Type)) {
                    break :blk self.peekNext().type == .Colon;
                }
                break :blk false;
            };

            if (!is_named) {
                // Positional: parse one expression as the value, name it
                // by index so the AST stays homogeneous. is_shorthand is
                // false to mark it as positional rather than name-pun.
                const value = try self.expression();
                var idx_buf: [16]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&idx_buf, "{}", .{positional_index}) catch unreachable;
                positional_index += 1;
                const field_name = try self.allocator.dupe(u8, idx_str);
                errdefer self.allocator.free(field_name);
                try fields.append(self.allocator, ast.FieldInit{
                    .name = field_name,
                    .value = value,
                    .is_shorthand = false,
                    .loc = start_loc,
                });
                _ = self.match(&.{.Comma});
                if (self.check(.RightBrace)) break;
                continue;
            }

            // Optional leading `.` for Zig-style `.field = value` form.
            const had_leading_dot = self.match(&.{.Dot});

            // Allow 'type' keyword as field name
            const field_name_token = if (self.match(&.{ .Identifier, .Type }))
                self.previous()
            else {
                try self.reportError("Expected field name");
                return error.UnexpectedToken;
            };

            // Choose the value separator. With a leading dot, accept
            // `=` (canonical) or `:`; without a leading dot, accept `:`.
            var is_shorthand = false;
            const field_value = blk: {
                if (had_leading_dot) {
                    if (self.match(&.{ .Equal, .Colon })) {
                        break :blk try self.expression();
                    }
                } else {
                    if (self.match(&.{.Colon})) {
                        break :blk try self.expression();
                    }
                }
                // Shorthand: field name is also the variable name
                is_shorthand = true;
                const id_expr = try self.allocator.create(ast.Expr);
                id_expr.* = ast.Expr{
                    .Identifier = ast.Identifier.init(field_name_token.lexeme, ast.SourceLocation.fromToken(field_name_token)),
                };
                break :blk id_expr;
            };

            const field_name = try self.allocator.dupe(u8, field_name_token.lexeme);
            errdefer self.allocator.free(field_name);

            try fields.append(self.allocator, ast.FieldInit{
                .name = field_name,
                .value = field_value,
                .is_shorthand = is_shorthand,
                .loc = ast.SourceLocation.fromToken(field_name_token),
            });

            // Comma is optional - newline separation is allowed
            _ = self.match(&.{.Comma});
            // Allow trailing comma before }
            if (self.check(.RightBrace)) break;
        }

        _ = try self.expect(.RightBrace, "Expected '}' after struct fields");

        const struct_lit = try self.allocator.create(ast.StructLiteralExpr);
        struct_lit.* = ast.StructLiteralExpr.init(
            type_name_owned,
            try fields.toOwnedSlice(self.allocator),
            type_name_owned.len == 0,
            loc,
        );

        const expr = try self.allocator.create(ast.Expr);
        expr.* = ast.Expr{ .StructLiteral = struct_lit };
        return expr;
    }

    /// Same as finishStructLiteralOwned but for callers that have a
    /// borrowed type name slice (token lexeme). The slice is currently
    /// stored as-is on the AST node — the existing struct-literal path
    /// passes token.lexeme directly, so we preserve that contract.
    fn finishStructLiteral(
        self: *Parser,
        type_name: []const u8,
        loc: ast.SourceLocation,
    ) ParseError!*ast.Expr {
        const type_name_owned = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(type_name_owned);
        return self.finishStructLiteralOwned(type_name_owned, loc);
    }

    /// Parse a primary expression (literals, identifiers, grouping)
    fn primary(self: *Parser) ParseError!*ast.Expr {
        // Inline assembly. Forms supported:
        //   1. asm("string")                          — simple literal form
        //   2. asm volatile ( ... )                    — Zig-style operand
        //      form with output/input/clobber lists.
        //   3. asm volatile { ... }                    — Zig-style brace form
        //      (kernel debug code uses this for `cli`, `hlt` and stack-trace
        //      capture).
        //   4. asm!(...) / asm![...] / asm!{...}       — Rust-style macro
        //      form used pervasively by the arm64 / x86 power kernel code
        //      with `in(reg) val`, `out(reg) result`, `inout(...) v => r`
        //      operand grammar.
        //
        // The body (between the outer delimiters) is captured as an opaque
        // raw token sequence — operand lists are preserved but unparsed.
        // Codegen can interpret them later if/when we ship a real inline-asm
        // backend. For now we just need parser/typecheck to accept them so
        // downstream kernel files stop blocking on this.
        if (self.match(&.{.Asm})) {
            const asm_token = self.previous();

            // Rust-style `asm!` macro form. Accept any of `(`, `[`, `{` as
            // the opening delimiter — Rust allows all three for macro
            // invocations and kernel sources only use `(` today, but the
            // parser already permits all three for non-asm macros so we
            // mirror that here for consistency.
            if (self.match(&.{.Bang})) {
                const close_token: TokenType = if (self.match(&.{.LeftParen}))
                    .RightParen
                else if (self.match(&.{.LeftBracket}))
                    .RightBracket
                else if (self.match(&.{.LeftBrace}))
                    .RightBrace
                else blk: {
                    try self.reportError("Expected '(', '[', or '{' after 'asm!'");
                    break :blk .RightParen;
                };
                self.consumeBalancedRaw(close_token);
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .InlineAsm = ast.InlineAsm.init("", ast.SourceLocation.fromToken(asm_token)) };
                return expr;
            }

            // Optional `volatile` keyword (soft — matched as Identifier).
            if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "volatile")) {
                _ = self.advance();
            }

            // Brace-block form: `asm volatile { "instr" : "=r"(out) : ... }`.
            // Captured as an opaque raw token range — same shape as the
            // paren form, just with a different closing delimiter.
            if (self.match(&.{.LeftBrace})) {
                self.consumeBalancedRaw(.RightBrace);
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .InlineAsm = ast.InlineAsm.init("", ast.SourceLocation.fromToken(asm_token)) };
                return expr;
            }

            _ = try self.expect(.LeftParen, "Expected '(' after 'asm'");

            // If the body is a simple string literal followed by `)`, keep
            // the old behavior (captures just the instruction string).
            if (self.check(.String)) {
                const save_pos = self.current;
                const str_token = self.advance();
                if (self.check(.RightParen)) {
                    _ = self.advance();
                    const instruction = str_token.lexeme[1 .. str_token.lexeme.len - 1];
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = ast.Expr{ .InlineAsm = ast.InlineAsm.init(instruction, ast.SourceLocation.fromToken(asm_token)) };
                    return expr;
                }
                // Not a simple form — rewind and fall through to raw capture.
                self.current = save_pos;
            }

            // Raw-capture mode for the paren form.
            self.consumeBalancedRaw(.RightParen);
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .InlineAsm = ast.InlineAsm.init("", ast.SourceLocation.fromToken(asm_token)) };
            return expr;
        }

        // Await expression
        if (self.match(&.{.Await})) {
            const await_token = self.previous();
            const awaited_expr = try self.expression();
            const await_expr = try ast.AwaitExpr.init(
                self.allocator,
                awaited_expr,
                ast.SourceLocation.fromToken(await_token),
            );
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .AwaitExpr = await_expr };
            return expr;
        }

        // Comptime expression
        if (self.match(&.{.Comptime})) {
            const comptime_token = self.previous();
            const comptime_expr_inner = try self.expression();
            const comptime_expr = try ast.ComptimeExpr.init(
                self.allocator,
                comptime_expr_inner,
                ast.SourceLocation.fromToken(comptime_token),
            );
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .ComptimeExpr = comptime_expr };
            return expr;
        }

        // If expression: if (cond) { expr } else { expr }
        if (self.match(&.{.If})) {
            return try self.ifExpr();
        }

        // Switch expression: switch (value) { Pattern => expr, ... }.
        // Statement-form switch is handled by `statement()` before we ever
        // reach here, so encountering `Switch` in expression context means
        // it's used as an initializer / argument / return value (issue #45).
        if (self.match(&.{.Switch})) {
            return try self.switchExpr();
        }

        // Match expression: match value { pattern => expr, ... }.
        // Kernel code also uses `match` as a plain identifier, so only
        // enter the match-expression parser when the next token could
        // actually start a match subject (not `{` or a binary op).
        if (self.check(.Match)) {
            const save = self.current;
            _ = self.advance();
            const next = self.peek().type;
            const looks_like_identifier_use =
                next == .LeftBrace or next == .RightParen or next == .Semicolon or
                next == .Comma or next == .EqualEqual or next == .BangEqual or
                next == .Less or next == .Greater or next == .LessEqual or
                next == .GreaterEqual or next == .Plus or next == .Minus or
                next == .Star or next == .Slash or next == .Equal or
                next == .AmpersandAmpersand or next == .PipePipe or
                next == .And or next == .Or;
            if (looks_like_identifier_use) {
                // Rewind and emit as plain identifier expression.
                self.current = save;
                const tok = self.advance();
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{
                    .Identifier = ast.Identifier.init(tok.lexeme, ast.SourceLocation.fromToken(tok)),
                };
                return expr;
            }
            return try self.matchExpr();
        }

        // Try-else expression: try expr else { default }
        if (self.match(&.{.Try})) {
            return try self.tryElseExpr();
        }

        // Closure expression: |params| body or || body (zero params)
        if (self.check(.Pipe) or self.check(.PipePipe)) {
            return try self.parseClosureExpr();
        }

        // Lambda-as-expression: `fn(params) ReturnType { body }` — used
        // in kernel code as `const f = fn(...) T { ... };`. Parsed as a
        // synthetic closure so it shares downstream code paths.
        if (self.check(.Fn) and self.peekNext().type == .LeftParen) {
            const start_token = self.advance(); // consume 'fn'
            _ = try self.expect(.LeftParen, "Expected '(' after 'fn' in lambda");

            var params = std.ArrayList(ast.ClosureParam).empty;
            defer params.deinit(self.allocator);
            while (!self.check(.RightParen) and !self.isAtEnd()) {
                const param_token = try self.expect(.Identifier, "Expected parameter name");
                const param_name = try self.allocator.dupe(u8, param_token.lexeme);
                if (self.match(&.{.Colon})) {
                    // Consume the parameter type but don't bind it on the
                    // closure node — lambda type-checking is best-effort
                    // for now and the parsed type goes unused.
                    const ty = try self.parseTypeAnnotation();
                    self.allocator.free(ty);
                }
                try params.append(self.allocator, .{
                    .name = param_name,
                    .type_annotation = null,
                    .is_mut = false,
                });
                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.expect(.RightParen, "Expected ')' after lambda parameters");

            // Optional return type. Accept `: T`, `-> T`, or Zig-style
            // bare-type before the body brace.
            if (self.match(&.{ .Colon, .Arrow })) {
                const rt = try self.parseTypeAnnotation();
                self.allocator.free(rt);
            } else if (!self.check(.LeftBrace) and !self.isAtEnd()) {
                const rt = try self.parseTypeAnnotation();
                self.allocator.free(rt);
            }

            const block_stmt = try self.blockStatement();
            const captures = try self.allocator.alloc(ast.Capture, 0);
            const closure = try self.allocator.create(ast.ClosureExpr);
            closure.* = ast.ClosureExpr.init(
                try params.toOwnedSlice(self.allocator),
                null,
                .{ .Block = block_stmt },
                captures,
                false,
                false,
                ast.SourceLocation.fromToken(start_token),
            );
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .ClosureExpr = closure };
            return expr;
        }

        // `unsafe { ... }` as an expression is a no-op block prefix —
        // the inner block parses as an ordinary block expression and
        // may end with a tail-expression (issue #56). This is the
        // expression-position counterpart of the statement form added
        // in `statement()`. Used pervasively in kernel code for
        // `fn read_u8(addr: u64): u8 { unsafe { *(addr as *const u8) } }`
        // style implicit-return wrappers.
        //
        // Match only when followed by `{` so a bare `unsafe` token
        // used as an identifier elsewhere keeps its existing behavior.
        if (self.check(.Unsafe) and self.peekNext().type == .LeftBrace) {
            _ = self.advance(); // consume `unsafe`
            _ = self.advance(); // consume `{`
            return try self.blockExprParse();
        }

        // Block expression or Map literal: { stmt1; stmt2; expr } or { "key": value }
        // Only parse as block if it's a bare '{' not preceded by type name
        if (self.match(&.{.LeftBrace})) {
            const brace_token = self.previous();

            // Empty braces {} - treat as empty map
            if (self.check(.RightBrace)) {
                _ = self.advance();
                const map_literal = try ast.MapLiteral.init(
                    self.allocator,
                    &.{},
                    ast.SourceLocation.fromToken(brace_token),
                );
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .MapLiteral = map_literal };
                return expr;
            }

            // Check if this looks like a map literal: { key : value, ... }
            // Save position to backtrack if needed
            const checkpoint = self.current;

            // Try to parse as potential map - skip the first expression
            var looks_like_map = false;
            var paren_depth: usize = 0;
            var bracket_depth: usize = 0;
            var brace_depth: usize = 0;

            // Scan tokens to find if there's a colon at the top level (indicating map)
            while (!self.isAtEnd() and self.current < self.tokens.len) {
                const token = self.tokens[self.current];

                // Track nested structures
                if (token.type == .LeftParen) paren_depth += 1 else if (token.type == .RightParen) {
                    if (paren_depth > 0) paren_depth -= 1;
                } else if (token.type == .LeftBracket) bracket_depth += 1 else if (token.type == .RightBracket) {
                    if (bracket_depth > 0) bracket_depth -= 1;
                } else if (token.type == .LeftBrace) brace_depth += 1 else if (token.type == .RightBrace) {
                    if (brace_depth > 0) {
                        brace_depth -= 1;
                    } else {
                        // We've reached the end of our block/map without finding a colon
                        break;
                    }
                }
                // At top level (depth 0), colon indicates map literal
                else if (token.type == .Colon and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    looks_like_map = true;
                    break;
                }
                // At top level, semicolon or let/const/etc. indicates block
                else if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    if (token.type == .Semicolon or token.type == .Let or token.type == .Const or
                        token.type == .If or token.type == .While or token.type == .For or
                        token.type == .Return or token.type == .Fn)
                    {
                        // Definitely a block
                        break;
                    }
                }

                self.current += 1;
            }

            // Restore position
            self.current = checkpoint;

            if (looks_like_map) {
                // Parse as map literal
                var entries = std.ArrayList(ast.MapEntry).empty;
                defer entries.deinit(self.allocator);

                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    // For map keys, if it's an identifier followed by colon, treat as string literal key
                    var key: *ast.Expr = undefined;
                    if (self.check(.Identifier)) {
                        const key_pos = self.current;
                        const key_token = self.advance();
                        if (self.check(.Colon)) {
                            // This is a shorthand identifier key - convert to string literal
                            const str_lit = try self.allocator.create(ast.Expr);
                            str_lit.* = ast.Expr{
                                .StringLiteral = ast.StringLiteral.init(key_token.lexeme, ast.SourceLocation.fromToken(key_token)),
                            };
                            key = str_lit;
                        } else {
                            // Not followed by colon, parse as regular expression
                            self.current = key_pos;
                            key = try self.expression();
                        }
                    } else {
                        key = try self.expression();
                    }
                    _ = try self.expect(.Colon, "Expected ':' after map key");
                    const value = try self.expression();

                    try entries.append(self.allocator, .{ .key = key, .value = value });

                    if (!self.match(&.{.Comma})) break;
                }

                _ = try self.expect(.RightBrace, "Expected '}' after map entries");

                const map_literal = try ast.MapLiteral.init(
                    self.allocator,
                    try entries.toOwnedSlice(self.allocator),
                    ast.SourceLocation.fromToken(brace_token),
                );

                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .MapLiteral = map_literal };
                return expr;
            }

            // Otherwise parse as block expression
            return try self.blockExprParse();
        }

        // Reflection expression (@TypeOf, @sizeOf, etc.)
        if (self.match(&.{.At})) {
            const at_token = self.previous();
            // Several reserved keywords are also valid @-builtin names:
            // `@as(T, v)`, `@import("…")`, `@asm(...)`, etc. Accept any
            // of them so the reflection parser doesn't trip on the
            // reserved token. `@asm(...)` is treated as opaque and
            // routed through the builtin block below.
            const name_token = if (self.check(.As) or self.check(.Import) or
                self.check(.Return) or self.check(.Export) or self.check(.Asm))
                self.advance()
            else
                try self.expect(.Identifier, "Expected reflection function name after '@'");
            const name = name_token.lexeme;

            // `@addrOf(expr)` is a thin alias for `&expr` — the parser
            // lowers it directly into a `UnaryExpr(AddressOf, …)` so
            // the rest of the pipeline (typechecker, codegen) sees it
            // as a normal address-of and the result types as `*T`.
            if (std.mem.eql(u8, name, "addrOf")) {
                _ = try self.expect(.LeftParen, "Expected '(' after '@addrOf'");
                const target = try self.expression();
                _ = try self.expect(.RightParen, "Expected ')' after '@addrOf' argument");
                const unary = try ast.UnaryExpr.init(
                    self.allocator,
                    .AddressOf,
                    target,
                    ast.SourceLocation.fromToken(at_token),
                );
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .UnaryExpr = unary };
                return expr;
            }

            // `@ptrDeref(ptr)` is a thin alias for `*ptr` — the parser
            // lowers it directly into a `UnaryExpr(Deref, …)` so the
            // rest of the pipeline treats it identically to a regular
            // pointer dereference. Kernel code uses it as both an
            // r-value (`return @ptrDeref(p)`) and an l-value
            // (`@ptrDeref(out) = value`).
            if (std.mem.eql(u8, name, "ptrDeref")) {
                _ = try self.expect(.LeftParen, "Expected '(' after '@ptrDeref'");
                const target = try self.expression();
                _ = try self.expect(.RightParen, "Expected ')' after '@ptrDeref' argument");
                const unary = try ast.UnaryExpr.init(
                    self.allocator,
                    .Deref,
                    target,
                    ast.SourceLocation.fromToken(at_token),
                );
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .UnaryExpr = unary };
                return expr;
            }

            // Opaque builtins (parsed before the known-reflection kind
            // table so we never hit the "Unknown reflection" error for
            // these). Used by kernel code for raw memory, atomics, and
            // import intrinsics. Arguments are consumed as raw tokens
            // and the call lowers to a Void literal at parse time.
            if (std.mem.eql(u8, name, "import") or
                std.mem.eql(u8, name, "asm") or
                std.mem.eql(u8, name, "ptrFromString") or
                std.mem.eql(u8, name, "ptrLoad") or std.mem.eql(u8, name, "ptrStore") or
                std.mem.eql(u8, name, "atomicLoad") or std.mem.eql(u8, name, "atomicStore") or
                std.mem.eql(u8, name, "atomicRmw") or std.mem.eql(u8, name, "cmpxchg") or
                std.mem.eql(u8, name, "cmpxchgWeak") or std.mem.eql(u8, name, "cmpxchgStrong") or
                std.mem.eql(u8, name, "atomicCmpXchg") or
                std.mem.eql(u8, name, "atomicFetchAdd") or
                std.mem.eql(u8, name, "atomicFetchSub") or
                std.mem.eql(u8, name, "alignCast") or std.mem.eql(u8, name, "intToU64") or
                std.mem.eql(u8, name, "prefetch") or std.mem.eql(u8, name, "fence") or
                std.mem.eql(u8, name, "clz") or std.mem.eql(u8, name, "ctz") or
                std.mem.eql(u8, name, "popCount") or std.mem.eql(u8, name, "byteSwap") or
                std.mem.eql(u8, name, "bitReverse") or std.mem.eql(u8, name, "shlWithOverflow") or
                std.mem.eql(u8, name, "shrExact") or std.mem.eql(u8, name, "shlExact") or
                std.mem.eql(u8, name, "divExact") or std.mem.eql(u8, name, "divTrunc") or
                std.mem.eql(u8, name, "divFloor") or std.mem.eql(u8, name, "mod") or
                std.mem.eql(u8, name, "rem") or std.mem.eql(u8, name, "mulWithOverflow") or
                std.mem.eql(u8, name, "addWithOverflow") or std.mem.eql(u8, name, "subWithOverflow") or
                std.mem.eql(u8, name, "wasmMemorySize") or std.mem.eql(u8, name, "wasmMemoryGrow") or
                std.mem.eql(u8, name, "embedFile") or std.mem.eql(u8, name, "hasDecl") or
                std.mem.eql(u8, name, "hasField") or std.mem.eql(u8, name, "frameAddress") or
                std.mem.eql(u8, name, "returnAddress") or std.mem.eql(u8, name, "src") or
                std.mem.eql(u8, name, "tagName") or std.mem.eql(u8, name, "fieldParentPtr") or
                std.mem.eql(u8, name, "errorName") or std.mem.eql(u8, name, "errorReturnTrace") or
                std.mem.eql(u8, name, "panic") or std.mem.eql(u8, name, "compileLog") or
                std.mem.eql(u8, name, "compileError") or std.mem.eql(u8, name, "atomicRmwOp") or
                std.mem.eql(u8, name, "floatFromInt") or std.mem.eql(u8, name, "intFromFloat") or
                std.mem.eql(u8, name, "ptrFromAddress") or std.mem.eql(u8, name, "addressOf") or
                std.mem.eql(u8, name, "shrWithOverflow") or std.mem.eql(u8, name, "splat") or
                std.mem.eql(u8, name, "reduce") or std.mem.eql(u8, name, "shuffle") or
                std.mem.eql(u8, name, "select") or std.mem.eql(u8, name, "Vector"))
            {
                _ = try self.expect(.LeftParen, "Expected '(' after builtin");
                var depth: i32 = 1;
                while (depth > 0 and !self.isAtEnd()) {
                    const t = self.advance();
                    if (t.type == .LeftParen) depth += 1;
                    if (t.type == .RightParen) depth -= 1;
                }
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{
                    .NullLiteral = ast.NullLiteral.init(ast.SourceLocation.fromToken(at_token)),
                };
                return expr;
            }

            // Parse the reflection kind
            const kind: ast.ReflectExpr.ReflectKind = blk: {
                if (std.mem.eql(u8, name, "TypeOf")) break :blk .TypeOf;
                if (std.mem.eql(u8, name, "sizeOf")) break :blk .SizeOf;
                if (std.mem.eql(u8, name, "alignOf")) break :blk .AlignOf;
                if (std.mem.eql(u8, name, "offsetOf")) break :blk .OffsetOf;
                if (std.mem.eql(u8, name, "typeInfo")) break :blk .TypeInfo;
                if (std.mem.eql(u8, name, "fieldName")) break :blk .FieldName;
                if (std.mem.eql(u8, name, "fieldType")) break :blk .FieldType;
                if (std.mem.eql(u8, name, "intFromPtr")) break :blk .IntFromPtr;
                if (std.mem.eql(u8, name, "ptrFromInt")) break :blk .PtrFromInt;
                // Legacy alias for code that still uses @intToPtr.
                if (std.mem.eql(u8, name, "intToPtr")) break :blk .PtrFromInt;
                // Bit-extension intrinsics used in kernel SIMD / register
                // access. Modeled as IntCast since they have the same
                // `(expr, T)` shape.
                if (std.mem.eql(u8, name, "zext")) break :blk .IntCast;
                if (std.mem.eql(u8, name, "sext")) break :blk .IntCast;
                if (std.mem.eql(u8, name, "trunc")) break :blk .Truncate;
                if (std.mem.eql(u8, name, "truncate")) break :blk .Truncate;
                if (std.mem.eql(u8, name, "as")) break :blk .As;
                if (std.mem.eql(u8, name, "bitCast")) break :blk .BitCast;
                // Type casting builtins
                if (std.mem.eql(u8, name, "intCast")) break :blk .IntCast;
                if (std.mem.eql(u8, name, "floatCast")) break :blk .FloatCast;
                if (std.mem.eql(u8, name, "ptrCast")) break :blk .PtrCast;
                if (std.mem.eql(u8, name, "ptrToInt")) break :blk .PtrToInt;
                if (std.mem.eql(u8, name, "intToFloat")) break :blk .IntToFloat;
                if (std.mem.eql(u8, name, "floatToInt")) break :blk .FloatToInt;
                if (std.mem.eql(u8, name, "enumToInt")) break :blk .EnumToInt;
                // Zig-style alias: `@intFromEnum(variant)` returns the
                // underlying integer tag of an enum variant. Reuses the
                // EnumToInt kind so codegen and the rest of the
                // pipeline don't need a new variant.
                if (std.mem.eql(u8, name, "intFromEnum")) break :blk .EnumToInt;
                if (std.mem.eql(u8, name, "intToEnum")) break :blk .IntToEnum;
                // Memory builtins
                if (std.mem.eql(u8, name, "memset")) break :blk .MemSet;
                if (std.mem.eql(u8, name, "memcpy")) break :blk .MemCpy;
                // Math builtins
                if (std.mem.eql(u8, name, "sqrt")) break :blk .Sqrt;
                if (std.mem.eql(u8, name, "sin")) break :blk .Sin;
                if (std.mem.eql(u8, name, "cos")) break :blk .Cos;
                if (std.mem.eql(u8, name, "tan")) break :blk .Tan;
                if (std.mem.eql(u8, name, "acos")) break :blk .Acos;
                if (std.mem.eql(u8, name, "asin")) break :blk .Asin;
                if (std.mem.eql(u8, name, "atan")) break :blk .Atan;
                if (std.mem.eql(u8, name, "atan2")) break :blk .Atan2;
                if (std.mem.eql(u8, name, "abs")) break :blk .Abs;
                if (std.mem.eql(u8, name, "min")) break :blk .Min;
                if (std.mem.eql(u8, name, "max")) break :blk .Max;
                if (std.mem.eql(u8, name, "floor")) break :blk .Floor;
                if (std.mem.eql(u8, name, "ceil")) break :blk .Ceil;
                if (std.mem.eql(u8, name, "pow")) break :blk .Pow;
                if (std.mem.eql(u8, name, "exp")) break :blk .Exp;
                if (std.mem.eql(u8, name, "log")) break :blk .Log;

                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Unknown reflection function '@{s}'",
                    .{name},
                );
                defer self.allocator.free(msg);
                try self.reportError(msg);
                return error.UnknownReflection;
            };

            _ = try self.expect(.LeftParen, "Expected '(' after reflection function name");

            // Builtins with a type argument: Home accepts both orders
            // historically. The type may come first (`@intCast(T, v)`,
            // `@as(T, v)`) or second (`@intCast(v, T)` — kernel style).
            // We disambiguate by peeking: if the first token is a
            // primitive type name (i32, u64, …) and the NEXT token is
            // a comma, treat it as type-first; otherwise expression-first.
            //
            // For prefix forms (`*T`, `[*]T`, `[N]T`, `?T`) we always
            // treat as type-first since these tokens don't start a
            // valid first-position expression in this context. For a
            // bare primitive identifier (e.g. `str`, `int`), require
            // the next token to be `,` so we don't mis-classify a
            // local/parameter that happens to share a primitive name
            // (`@ptrFromInt(str)` where `str` is a `u64` parameter).
            var target_type: ?[]const u8 = null;
            var target: *ast.Expr = undefined;
            const has_type_arg =
                kind == .IntToFloat or kind == .FloatToInt or kind == .IntCast or
                kind == .FloatCast or kind == .PtrCast or kind == .IntToEnum or
                kind == .Truncate or kind == .BitCast or kind == .As or
                kind == .PtrFromInt or kind == .PtrToInt or kind == .IntFromPtr;
            // Type-only builtins: the single argument is a type
            // expression, not a value (`@sizeOf([16]u8)`,
            // `@alignOf(*u32)`, `@TypeOf(MyStruct)`). For these we
            // accept type-prefix tokens (`[`, `*`, `?`) directly and
            // store the result in `target_type`, leaving `target` as a
            // null-literal placeholder.
            const is_type_only =
                kind == .SizeOf or kind == .AlignOf or kind == .TypeOf or
                kind == .TypeInfo;
            if (has_type_arg) {
                const looks_type_first = blk: {
                    const t = self.peek().type;
                    // Prefix-only type starts unambiguously identify a
                    // type. (`&` is intentionally excluded — it also
                    // starts a reference expression like
                    // `&local_var`, which is the common case for
                    // builtins like `@intFromPtr(&x)`.)
                    if (t == .Star or t == .StarStar or t == .LeftBracket or
                        t == .Question or t == .QuestionBracket)
                    {
                        break :blk true;
                    }
                    // Identifier directly followed by `,` — generally
                    // treat as type-first to cover both primitive
                    // names (`@as(u64, length)`) and user-defined
                    // type aliases (`@intToFloat(AudioFloat, FFT_SIZE - 1)`).
                    // The single-arg case `@ptrFromInt(str)` where
                    // `str` is a value-position identifier is
                    // unaffected because it is not followed by `,`.
                    //
                    // Exception (issue #41): the kernel uses the
                    // expression-first shape `@intCast(value, u64)`
                    // — value first, primitive type last. When the
                    // first identifier is NOT a primitive but the
                    // trailing arg is a single primitive type closed
                    // by `)`, prefer expression-first so the
                    // primitive parses as a type, not a symbol-table
                    // lookup.
                    if (self.peek().type == .Identifier and
                        self.peekNext().type == .Comma)
                    {
                        const first_is_primitive =
                            isPrimitiveTypeName(self.peek().lexeme);
                        if (!first_is_primitive and
                            self.current + 3 < self.tokens.len)
                        {
                            const arg2 = self.tokens[self.current + 2];
                            const after_arg2 = self.tokens[self.current + 3].type;
                            if (arg2.type == .Identifier and
                                isPrimitiveTypeName(arg2.lexeme) and
                                after_arg2 == .RightParen)
                            {
                                // `IDENT, primitive)` — expression-first.
                                break :blk false;
                            }
                        }
                        break :blk true;
                    }
                    break :blk false;
                };
                if (looks_type_first) {
                    // Type-first: `@as(u64, length)` etc.
                    target_type = try self.parseTypeAnnotation();
                    _ = try self.expect(.Comma, "Expected ',' after type argument");
                    target = try self.expression();
                    // Optional trailing source-type hint:
                    // `@as(*u64, expr, *WifiTxDesc)` — kernel code uses
                    // this 3-arg form to record the source type for
                    // documentation / future codegen. We accept and
                    // discard it so the call parses.
                    if (self.check(.Comma) and self.peekNext().type != .RightParen) {
                        // Peek past the comma to see if it's a type.
                        const save = self.current;
                        _ = self.advance(); // consume comma
                        const next_t = self.peek().type;
                        const looks_like_type = next_t == .Star or
                            next_t == .StarStar or next_t == .LeftBracket or
                            next_t == .Question or next_t == .QuestionBracket or
                            next_t == .Ampersand or
                            (next_t == .Identifier and
                                (self.peekNext().type == .RightParen or
                                    self.peekNext().type == .Dot or
                                    self.peekNext().type == .ColonColon));
                        if (looks_like_type) {
                            _ = self.parseTypeAnnotation() catch {
                                self.current = save;
                            };
                        } else {
                            self.current = save;
                        }
                    }
                } else {
                    // Expression-first: `@intCast(value, i32)` kernel style.
                    target = try self.expression();
                    if (self.match(&.{.Comma})) {
                        target_type = try self.parseTypeAnnotation();
                    }
                }
            } else if (is_type_only) {
                // Type-only argument forms: accept type-prefix tokens
                // (`[N]T`, `*T`, `?T`) as the lone argument.
                const t = self.peek().type;
                if (t == .Star or t == .StarStar or t == .LeftBracket or
                    t == .Question or t == .QuestionBracket)
                {
                    target_type = try self.parseTypeAnnotation();
                    const placeholder = try self.allocator.create(ast.Expr);
                    placeholder.* = ast.Expr{
                        .NullLiteral = ast.NullLiteral.init(ast.SourceLocation.fromToken(at_token)),
                    };
                    target = placeholder;
                } else {
                    target = try self.expression();
                }
            } else {
                // Parse target expression (non-cast builtins)
                target = try self.expression();
            }

            // Parse second argument for two-arg builtins like @atan2, @min, @max, @pow
            var second_arg: ?*ast.Expr = null;
            if (kind == .Atan2 or kind == .Min or kind == .Max or kind == .Pow or kind == .MemCpy or kind == .MemSet) {
                _ = try self.expect(.Comma, "Expected ',' between arguments");
                second_arg = try self.expression();
            }

            // Parse third argument for three-arg builtins like @memcpy, @memset.
            //
            // Issue #58: Zig 0.11+ migrated `@memset(slice, byte)` and
            // `@memcpy(dst_slice, src_slice)` to a 2-arg slice form.
            // Accept BOTH the legacy 3-arg `(ptr, byte, len)` /
            // `(dst, src, len)` form AND the modern 2-arg slice form.
            // The typechecker validates the actual signature; the parser
            // just needs to accept either shape.
            var third_arg: ?*ast.Expr = null;
            if (kind == .MemCpy or kind == .MemSet) {
                if (self.match(&.{.Comma})) {
                    third_arg = try self.expression();
                }
            }

            // Parse optional field name for @offsetOf, @fieldType
            var field_name: ?[]const u8 = null;
            if (kind == .OffsetOf or kind == .FieldType) {
                _ = try self.expect(.Comma, "Expected ',' before field name");
                const field_token = try self.expect(.String, "Expected string literal for field name");
                // Remove quotes
                field_name = field_token.lexeme[1 .. field_token.lexeme.len - 1];
            }

            _ = try self.expect(.RightParen, "Expected ')' after reflection arguments");

            const reflect_expr = try ast.ReflectExpr.init(
                self.allocator,
                kind,
                target,
                second_arg,
                third_arg,
                field_name,
                target_type,
                ast.SourceLocation.fromToken(at_token),
            );
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .ReflectExpr = reflect_expr };
            return expr;
        }

        // Check for invalid tokens and report them clearly
        if (self.peek().type == .Invalid or self.peek().type == .UnterminatedString) {
            const token = self.advance();
            const msg = if (token.type == .UnterminatedString)
                try std.fmt.allocPrint(
                    self.allocator,
                    "Unterminated string literal starting with '{s}'",
                    .{token.lexeme},
                )
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "Invalid character '{s}' in source code",
                    .{token.lexeme},
                );
            defer self.allocator.free(msg);
            try self.reportError(msg);
            return error.InvalidCharacter;
        }

        // Boolean literals
        if (self.match(&.{.True})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .BooleanLiteral = ast.BooleanLiteral.init(true, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        if (self.match(&.{.False})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .BooleanLiteral = ast.BooleanLiteral.init(false, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Null literal
        if (self.match(&.{.Null})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .NullLiteral = ast.NullLiteral.init(ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // `undefined` — Zig-style typed undefined value. Represented as
        // a NullLiteral here so it assigns to any type without tripping
        // the "Undefined variable" type-checker rule.
        if (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "undefined")) {
            const token = self.advance();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .NullLiteral = ast.NullLiteral.init(ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Integer literals
        if (self.match(&.{.Integer})) {
            const token = self.previous();

            // Check for type suffix (i8, i16, i32, i64, i128, u8, u16, u32, u64, u128)
            var type_suffix: ?[]const u8 = null;
            var lexeme = token.lexeme;

            // Find where the type suffix starts (if any)
            for (lexeme, 0..) |c, i| {
                if ((c == 'i' or c == 'u') and i > 0) {
                    // Check if this looks like a type suffix
                    const remaining = lexeme[i..];
                    if (remaining.len > 1 and std.ascii.isDigit(remaining[1])) {
                        type_suffix = remaining;
                        lexeme = lexeme[0..i];
                        break;
                    }
                }
            }

            // Remove underscores for parsing
            var clean_lexeme = std.ArrayList(u8).empty;
            defer clean_lexeme.deinit(self.allocator);
            for (lexeme) |c| {
                if (c != '_') {
                    try clean_lexeme.append(self.allocator, c);
                }
            }

            // Determine the base (binary, hex, octal, decimal)
            const clean = clean_lexeme.items;
            const base: u8 = if (clean.len > 2 and clean[0] == '0')
                switch (clean[1]) {
                    'b', 'B' => 2,
                    'x', 'X' => 16,
                    'o', 'O' => 8,
                    else => 10,
                }
            else
                10;

            // Skip prefix for non-decimal bases
            const parse_str = if (base != 10) clean[2..] else clean;

            // Parse as i128 so the full unsigned 64-bit range fits as a
            // positive value. This preserves the user's intent for large
            // hex masks like `0xFFFFFFFFFFFFFFFF` and lets the
            // type-checker decide signedness against the destination
            // type. Anything beyond u64 is rejected here.
            const value: i128 = blk: {
                if (std.fmt.parseInt(i128, parse_str, base)) |v| {
                    if (v > std.math.maxInt(u64)) {
                        try self.reportError("Integer literal is too large (exceeds u64 range)");
                        return error.IntegerOverflow;
                    }
                    break :blk v;
                } else |err| {
                    if (err == error.Overflow) {
                        try self.reportError("Integer literal is too large (exceeds u64 range)");
                        return error.IntegerOverflow;
                    }
                    return err;
                }
            };

            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .IntegerLiteral = ast.IntegerLiteral.initWithType(value, type_suffix, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Float literals
        if (self.match(&.{.Float})) {
            const token = self.previous();

            // Check for type suffix (f32, f64)
            var type_suffix: ?[]const u8 = null;
            var lexeme = token.lexeme;

            // Find where the type suffix starts (if any)
            for (lexeme, 0..) |c, i| {
                if (c == 'f' and i > 0) {
                    // Check if this looks like a type suffix
                    const remaining = lexeme[i..];
                    if (remaining.len > 1 and std.ascii.isDigit(remaining[1])) {
                        type_suffix = remaining;
                        lexeme = lexeme[0..i];
                        break;
                    }
                }
            }

            // Remove underscores for parsing
            var clean_lexeme = std.ArrayList(u8).empty;
            defer clean_lexeme.deinit(self.allocator);
            for (lexeme) |c| {
                if (c != '_') {
                    try clean_lexeme.append(self.allocator, c);
                }
            }

            const value = std.fmt.parseFloat(f64, clean_lexeme.items) catch |err| {
                if (err == error.InvalidCharacter) {
                    try self.reportError("Invalid float literal format");
                    return error.InvalidFloat;
                }
                return err;
            };

            // Check for infinity (overflow)
            if (std.math.isInf(value)) {
                try self.reportError("Float literal is too large (exceeds f64 range)");
                return error.FloatOverflow;
            }

            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .FloatLiteral = ast.FloatLiteral.initWithType(value, type_suffix, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Interpolated string literals
        if (self.check(.StringInterpolationStart)) {
            return try self.interpolatedString();
        }

        // String literals
        if (self.match(&.{.String})) {
            const token = self.previous();
            // Remove quotes
            const value = token.lexeme[1 .. token.lexeme.len - 1];
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .StringLiteral = ast.StringLiteral.init(value, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Character literals
        if (self.match(&.{.Char})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .CharLiteral = ast.CharLiteral.init(token.lexeme, ast.SourceLocation.fromToken(token)) };
            return expr;
        }

        // Contextual soft keywords (`is`, `test`, `as`, `guard`) used as
        // plain identifier expressions. The keyword forms are recognised
        // only in their grammatical positions:
        //   * `is` is matched in postfix position (`if x is T`).
        //   * `as` is matched in postfix position (cast: `x as T`).
        //   * `test` introduces a unit-test decl only when followed by a
        //     string literal (`test "name" { }`).
        //   * `guard` is currently only a soft keyword (no special form).
        // Reaching this point means the token is being used as a name.
        // Emit a bare identifier expression — no macro/generic-args/
        // struct-literal disambiguation applies (those need a real
        // Identifier token).
        if (self.check(.Is) or self.check(.Test) or
            self.check(.As) or self.check(.Guard))
        {
            const token = self.advance();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Identifiers (and macro invocations)
        if (self.match(&.{.Identifier})) {
            const token = self.previous();

            // Check for macro invocation (identifier!)
            if (self.match(&.{.Bang})) {
                const bang_token = self.previous();

                // Parse macro arguments - support (), [], and {} delimiters (Rust-style)
                var args = std.ArrayList(*ast.Expr).empty;
                defer args.deinit(self.allocator);

                // Determine which delimiter is used
                var close_token: TokenType = undefined;
                if (self.match(&.{.LeftParen})) {
                    close_token = .RightParen;
                } else if (self.match(&.{.LeftBracket})) {
                    close_token = .RightBracket;
                } else if (self.match(&.{.LeftBrace})) {
                    close_token = .RightBrace;
                } else {
                    try self.reportError("Expected '(', '[', or '{' after '!' for macro invocation");
                    return error.UnexpectedToken;
                }

                if (!self.check(close_token)) {
                    while (true) {
                        const arg = try self.expression();
                        try args.append(self.allocator, arg);
                        if (!self.match(&.{.Comma})) break;
                        // Handle trailing comma - check if next token is close delimiter
                        if (self.check(close_token)) break;
                    }
                }

                // Expect closing delimiter
                if (!self.check(close_token)) {
                    try self.reportError("Expected closing delimiter after macro arguments");
                    return error.UnexpectedToken;
                }
                _ = self.advance();

                const macro_name = token.lexeme;
                const macro_args = try args.toOwnedSlice(self.allocator);
                const macro_loc = ast.SourceLocation.fromToken(bang_token);

                // Try to expand built-in macros during parsing
                if (try self.expandBuiltinMacro(macro_name, macro_args, macro_loc)) |expanded| {
                    return expanded;
                }

                // For non-builtin macros, create MacroExpr node for later expansion
                const macro_expr = try ast.MacroExpr.init(
                    self.allocator,
                    macro_name,
                    macro_args,
                    macro_loc,
                );

                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .MacroExpr = macro_expr };
                return expr;
            }

            // Check for generic type with struct literal: Type<T1, T2>{}.
            // Disambiguation from `CONST_NAME < expr` is tricky: the
            // identifier must look like a TYPE (PascalCase), NOT a
            // SCREAMING_SNAKE_CASE constant. `Vec` qualifies,
            // `MIN_GRANULARITY_NS` does not. We require at least one
            // lowercase letter anywhere in the name.
            if (self.check(.Less) and token.lexeme.len > 0 and
                token.lexeme[0] >= 'A' and token.lexeme[0] <= 'Z' and
                hasLowercaseLetter(token.lexeme))
            {
                // Look ahead to see if this looks like generic args (identifier after <)
                const checkpoint = self.current;
                _ = self.advance(); // consume <

                const looks_like_generics = self.check(.Identifier) or self.check(.Question) or
                    self.check(.Ampersand) or self.check(.Star) or self.check(.LeftBracket) or
                    self.check(.LeftParen) or self.check(.Fn);

                if (looks_like_generics) {
                    var type_name = try self.allocator.dupe(u8, token.lexeme);
                    errdefer self.allocator.free(type_name);

                    // Parse generic type arguments
                    var type_args = std.ArrayList([]const u8).empty;
                    defer {
                        for (type_args.items) |arg| self.allocator.free(arg);
                        type_args.deinit(self.allocator);
                    }

                    while (!self.check(.Greater) and !self.check(.RightShift) and self.pending_greater == 0 and !self.isAtEnd()) {
                        const arg_type = try self.parseTypeAnnotation();
                        try type_args.append(self.allocator, arg_type);

                        if (!self.match(&.{.Comma})) break;
                    }

                    // Handle closing > or >>
                    if (self.check(.RightShift)) {
                        self.pending_greater += 1;
                        _ = self.advance();
                    } else if (self.pending_greater > 0) {
                        self.pending_greater -= 1;
                    } else {
                        _ = try self.expect(.Greater, "Expected '>' after generic type arguments");
                    }

                    // Build full generic type name
                    var full_type = std.ArrayList(u8).empty;
                    defer full_type.deinit(self.allocator);
                    try full_type.appendSlice(self.allocator, type_name);
                    try full_type.append(self.allocator, '<');
                    for (type_args.items, 0..) |arg, i| {
                        if (i > 0) try full_type.appendSlice(self.allocator, ", ");
                        try full_type.appendSlice(self.allocator, arg);
                    }
                    try full_type.append(self.allocator, '>');
                    self.allocator.free(type_name);
                    type_name = try full_type.toOwnedSlice(self.allocator);

                    // Now check for struct literal {}
                    if (self.check(.LeftBrace)) {
                        const checkpoint2 = self.current;
                        _ = self.advance(); // consume '{'

                        if (self.isStructLiteralLookahead()) {
                            return try self.finishStructLiteralOwned(type_name, ast.SourceLocation.fromToken(token));
                        }

                        // Not a struct literal, restore position
                        self.current = checkpoint2;
                    }

                    // Return as a type identifier expression for generic type
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = ast.Expr{
                        .Identifier = ast.Identifier.init(type_name, ast.SourceLocation.fromToken(token)),
                    };
                    return expr;
                } else {
                    // Not generics, restore position (< is comparison operator)
                    self.current = checkpoint;
                }
            }

            // Check for struct literal: TypeName { field: value, ... }
            // Only treat as struct literal if we see { identifier : pattern
            // This avoids ambiguity with for loops: "for x in items { let..." is NOT a struct literal.
            //
            // While parsing a `while`/`if`/`do-while` condition, struct literals
            // on bare identifiers are suppressed so that the body's `{` is not
            // mistaken for the start of a `target {}` literal. Type-prefixed
            // generic-struct literals (`Vec<T>{...}`, handled above) and
            // explicit braced expressions (`(target {...})`) remain available.
            if (self.suppress_struct_literal == 0 and self.check(.LeftBrace)) {
                // Look ahead to see if this is actually a struct literal
                const checkpoint = self.current;
                _ = self.advance(); // consume '{'

                if (self.isStructLiteralLookahead()) {
                    return try self.finishStructLiteral(token.lexeme, ast.SourceLocation.fromToken(token));
                }

                // Restore position and return identifier
                self.current = checkpoint;
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{
                    .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
                };
                return expr;
            }

            // Regular identifier
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // 'self' keyword in expressions (for method bodies)
        if (self.match(&.{.SelfValue})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // 'it' keyword used as identifier
        if (self.match(&.{.It})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // 'type' keyword used as identifier
        if (self.match(&.{.Type})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Spread operator
        if (self.match(&.{.DotDotDot})) {
            const spread_token = self.previous();
            const operand = try self.parsePrecedence(.Unary);

            const spread_expr = try ast.SpreadExpr.init(
                self.allocator,
                operand,
                ast.SourceLocation.fromToken(spread_token),
            );

            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .SpreadExpr = spread_expr };
            return expr;
        }

        // Leading-dot enum literal shorthand in expression position (`.RED`).
        if (self.match(&.{.Dot})) {
            const dot_tok = self.previous();
            if (self.match(&.{.LeftBrace})) {
                const type_name = try self.allocator.dupe(u8, "");
                errdefer self.allocator.free(type_name);
                return try self.finishStructLiteralOwned(type_name, ast.SourceLocation.fromToken(dot_tok));
            }

            const ident_tok = if (self.check(.Identifier) or self.check(.Type))
                self.advance()
            else {
                try self.reportError("Expected identifier after '.'");
                return error.UnexpectedToken;
            };

            const base_expr = try self.allocator.create(ast.Expr);
            base_expr.* = ast.Expr{
                .Identifier = ast.Identifier.init("", ast.SourceLocation.fromToken(dot_tok)),
            };
            const member_expr = try ast.MemberExpr.init(
                self.allocator,
                base_expr,
                ident_tok.lexeme,
                ast.SourceLocation.fromToken(ident_tok),
            );
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .MemberExpr = member_expr };
            return expr;
        }

        // Unary expressions
        if (self.match(&.{ .Bang, .Not, .Minus, .Tilde, .Star, .Ampersand })) {
            const op_token = self.previous();
            const op: ast.UnaryOp = switch (op_token.type) {
                .Bang, .Not => .Not,
                .Minus => .Neg,
                .Tilde => .BitNot,
                .Star => .Deref,
                .Ampersand => if (self.match(&.{.Mut})) .BorrowMut else .AddressOf,
                else => unreachable,
            };
            const operand = try self.parsePrecedence(.Unary);

            const unary_expr = try ast.UnaryExpr.init(
                self.allocator,
                op,
                operand,
                ast.SourceLocation.fromToken(op_token),
            );

            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .UnaryExpr = unary_expr };
            return expr;
        }

        // Map/Dictionary literals
        if (self.match(&.{.LeftBrace})) {
            const brace_token = self.previous();

            // Empty map {}
            if (self.check(.RightBrace)) {
                _ = self.advance();
                const map_literal = try ast.MapLiteral.init(
                    self.allocator,
                    &.{},
                    ast.SourceLocation.fromToken(brace_token),
                );
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .MapLiteral = map_literal };
                return expr;
            }

            var entries = std.ArrayList(ast.MapEntry).empty;
            defer entries.deinit(self.allocator);

            while (!self.check(.RightBrace) and !self.isAtEnd()) {
                const key = try self.expression();
                _ = try self.expect(.Colon, "Expected ':' after map key");
                const value = try self.expression();

                try entries.append(self.allocator, .{ .key = key, .value = value });

                if (!self.match(&.{.Comma})) break;
            }

            _ = try self.expect(.RightBrace, "Expected '}' after map entries");

            const map_literal = try ast.MapLiteral.init(
                self.allocator,
                try entries.toOwnedSlice(self.allocator),
                ast.SourceLocation.fromToken(brace_token),
            );

            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .MapLiteral = map_literal };
            return expr;
        }

        // Array literals - includes typed array literals like [16]f32{ 1.0, 2.0, ... }
        if (self.match(&.{.LeftBracket})) {
            const bracket_token = self.previous();

            // Check for typed array literal:
            //   [N]Type{ values }       — explicit length
            //   [_]Type{ values }       — inferred length (Zig-style)
            // The element type can be a simple identifier (`u8`, `Foo`),
            // a namespaced path (`usb.USBDeviceID`, `a.b.c.Foo`), a slice
            // (`[]const u8`), an array, a pointer/ref, or an optional —
            // anything `parseTypeAnnotation` accepts.
            //
            // We use a peek-only scan to determine whether the position
            // after `]` holds `<element-type> {` so we only commit to the
            // typed-array-literal path when the trailing `{` is actually
            // present. Otherwise we fall back to the regular array
            // literal path (where `[_]` parses as a one-element array
            // with `_` as the sole element).
            const is_size_token = self.check(.Integer) or
                (self.check(.Identifier) and std.mem.eql(u8, self.peek().lexeme, "_"));
            if (is_size_token) {
                const checkpoint = self.current;
                const size_token = self.advance();
                if (self.match(&.{.RightBracket})) {
                    // We have [N] or [_] - peek ahead to see if the
                    // element type is followed by `{`.
                    const type_end_idx = self.peekArrayElementTypeEnd(self.current);
                    if (type_end_idx > self.current and
                        type_end_idx < self.tokens.len and
                        self.tokens[type_end_idx].type == .LeftBrace)
                    {
                        // Commit: parse the element type, then `{ ... }`.
                        const elem_type = try self.parseTypeAnnotation();
                        defer self.allocator.free(elem_type);
                        _ = try self.expect(.LeftBrace, "Expected '{' after typed array element type");

                        var elements = std.ArrayList(*ast.Expr).empty;
                        defer elements.deinit(self.allocator);

                        if (!self.check(.RightBrace)) {
                            while (true) {
                                const elem = try self.expression();
                                try elements.append(self.allocator, elem);

                                if (!self.match(&.{.Comma})) break;
                                // Allow trailing comma
                                if (self.check(.RightBrace)) break;
                            }
                        }

                        _ = try self.expect(.RightBrace, "Expected '}' after typed array elements");

                        // Create typed array literal with size and element type
                        const array_type = try std.fmt.allocPrint(self.allocator, "[{s}]{s}", .{ size_token.lexeme, elem_type });
                        const array_literal = try ast.ArrayLiteral.init(
                            self.allocator,
                            try elements.toOwnedSlice(self.allocator),
                            ast.SourceLocation.fromToken(bracket_token),
                        );
                        // Store the explicit type in the array literal
                        array_literal.explicit_type = array_type;

                        const expr = try self.allocator.create(ast.Expr);
                        expr.* = ast.Expr{ .ArrayLiteral = array_literal };
                        return expr;
                    }
                }
                // Not a typed array literal - restore position and parse as regular array
                self.current = checkpoint;
            }

            // Regular array literal: [a, b, c] or repeat syntax: [value; count]
            var elements = std.ArrayList(*ast.Expr).empty;
            defer elements.deinit(self.allocator);

            if (!self.check(.RightBracket)) {
                const first_elem = try self.expression();
                try elements.append(self.allocator, first_elem);

                // Check for repeat syntax: [value; count]
                if (self.match(&.{.Semicolon})) {
                    // Count can be an integer literal or a constant expression
                    const count_expr = try self.expression();
                    _ = try self.expect(.RightBracket, "Expected ']' after array repeat count");

                    // Create ArrayRepeat expression with expression-based count
                    const repeat_expr = try ast.ArrayRepeat.initWithExpr(
                        self.allocator,
                        first_elem,
                        count_expr,
                        ast.SourceLocation.fromToken(bracket_token),
                    );

                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = ast.Expr{ .ArrayRepeat = repeat_expr };
                    return expr;
                }

                // Check for list comprehension syntax: [expr for var in iterable if condition]
                if (self.match(&.{.For})) {
                    // Parse variable name
                    const var_token = try self.expect(.Identifier, "Expected identifier after 'for' in comprehension");
                    const variable = var_token.lexeme;

                    // Expect 'in'
                    _ = try self.expect(.In, "Expected 'in' after variable in comprehension");

                    // Parse iterable expression
                    const iterable = try self.expression();

                    // Check for optional condition
                    var condition: ?*ast.Expr = null;
                    if (self.match(&.{.If})) {
                        condition = try self.expression();
                    }

                    _ = try self.expect(.RightBracket, "Expected ']' after comprehension");

                    // Create ArrayComprehension
                    const comp = try self.allocator.create(ast.ArrayComprehension);
                    comp.* = ast.ArrayComprehension.init(
                        first_elem,
                        variable,
                        iterable,
                        condition,
                        false, // is_async
                        ast.SourceLocation.fromToken(bracket_token),
                    );

                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = ast.Expr{ .ArrayComprehension = comp };
                    return expr;
                }

                // Continue parsing remaining elements
                while (self.match(&.{.Comma})) {
                    // Allow trailing comma
                    if (self.check(.RightBracket)) break;
                    const elem = try self.expression();
                    try elements.append(self.allocator, elem);
                }
            }

            _ = try self.expect(.RightBracket, "Expected ']' after array elements");

            const array_literal = try ast.ArrayLiteral.init(
                self.allocator,
                try elements.toOwnedSlice(self.allocator),
                ast.SourceLocation.fromToken(bracket_token),
            );

            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .ArrayLiteral = array_literal };
            return expr;
        }

        // Grouping or tuple
        if (self.match(&.{.LeftParen})) {
            const paren_token = self.previous();

            // Empty tuple ()
            if (self.check(.RightParen)) {
                _ = self.advance();
                const tuple_expr = try ast.TupleExpr.init(
                    self.allocator,
                    &.{},
                    ast.SourceLocation.fromToken(paren_token),
                );
                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .TupleExpr = tuple_expr };
                return expr;
            }

            // Inside parens, struct-literal suppression (used by while/if
            // condition parsing) is lifted: the body's `{` cannot be reached
            // until we see the matching `)`, so a struct literal here is
            // unambiguous.
            const saved_suppress = self.suppress_struct_literal;
            self.suppress_struct_literal = 0;
            defer self.suppress_struct_literal = saved_suppress;

            const first_expr = try self.expression();

            // Check if it's a tuple (comma after first element)
            if (self.match(&.{.Comma})) {
                var elements = std.ArrayList(*ast.Expr).empty;
                defer elements.deinit(self.allocator);

                try elements.append(self.allocator, first_expr);

                // Parse remaining tuple elements
                if (!self.check(.RightParen)) {
                    while (true) {
                        const elem = try self.expression();
                        try elements.append(self.allocator, elem);
                        if (!self.match(&.{.Comma})) break;
                        // Allow trailing comma
                        if (self.check(.RightParen)) break;
                    }
                }

                _ = try self.expect(.RightParen, "Expected ')' after tuple elements");

                const tuple_expr = try ast.TupleExpr.init(
                    self.allocator,
                    try elements.toOwnedSlice(self.allocator),
                    ast.SourceLocation.fromToken(paren_token),
                );

                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .TupleExpr = tuple_expr };
                return expr;
            }

            // Just a grouped expression
            _ = try self.expect(.RightParen, "Expected ')' after expression");
            return first_expr;
        }

        // Note: Removed verbose debug print to avoid huge output when parsing fails
        return error.UnexpectedToken;
    }

    /// Parse interpolated string literal
    ///
    /// Interpolated strings use the syntax: "text {expr} more text {expr2}"
    /// The lexer produces: StringInterpolationStart, expr, StringInterpolationMid, expr, StringInterpolationEnd
    ///
    /// Returns: InterpolatedString expression
    fn interpolatedString(self: *Parser) ParseError!*ast.Expr {
        const start_token = try self.expect(.StringInterpolationStart, "Expected string interpolation start");
        const start_loc = ast.SourceLocation.fromToken(start_token);

        var parts_list = std.ArrayList([]const u8).empty;
        defer parts_list.deinit(self.allocator);

        var exprs_list = std.ArrayList(ast.Expr).empty;
        defer exprs_list.deinit(self.allocator);

        // Add first part (text before first ${)
        // Lexeme is: "text${ (starts with ", ends with ${)
        // We want just "text"
        const first_part = if (start_token.lexeme.len >= 3)
            start_token.lexeme[1 .. start_token.lexeme.len - 2] // Remove " and ${
        else
            "";
        try parts_list.append(self.allocator, first_part);

        // Parse expressions and middle parts
        while (true) {
            // Parse the expression inside {}
            const expr = try self.expression();
            try exprs_list.append(self.allocator, expr.*);

            // Skip format specifier if present (e.g., :30, :7.3, :.2f)
            // Format specifiers start with : and contain digits, dots, and format chars
            if (self.check(.Colon)) {
                _ = self.advance(); // consume :
                // Consume format specifier tokens (Integer, Float, Dot, Identifier for things like "f")
                while (self.check(.Integer) or self.check(.Float) or self.check(.Dot) or self.check(.Identifier)) {
                    _ = self.advance();
                }
            }

            // Check what comes next
            if (self.match(&.{.StringInterpolationMid})) {
                // More interpolation coming
                // Lexeme is: text${ (no leading }, ends with ${)
                const mid_token = self.previous();
                const mid_part = if (mid_token.lexeme.len >= 2)
                    mid_token.lexeme[0 .. mid_token.lexeme.len - 2] // Remove ${
                else
                    "";
                try parts_list.append(self.allocator, mid_part);
            } else if (self.match(&.{.StringInterpolationEnd})) {
                // End of interpolation
                // Lexeme is: text" (no leading }, ends with ")
                const end_token = self.previous();
                const end_part = if (end_token.lexeme.len >= 1)
                    end_token.lexeme[0 .. end_token.lexeme.len - 1] // Remove "
                else
                    "";
                try parts_list.append(self.allocator, end_part);
                break;
            } else {
                try self.reportError("Expected '}' in interpolated string");
                return error.UnexpectedToken;
            }
        }

        // Create InterpolatedString node
        const parts = try self.allocator.alloc([]const u8, parts_list.items.len);
        @memcpy(parts, parts_list.items);

        const exprs = try self.allocator.alloc(ast.Expr, exprs_list.items.len);
        @memcpy(exprs, exprs_list.items);

        const interp_string = try self.allocator.create(ast.InterpolatedString);
        interp_string.* = ast.InterpolatedString.init(parts, exprs, start_loc);

        const expr = try self.allocator.create(ast.Expr);
        expr.* = ast.Expr{ .InterpolatedString = interp_string };
        return expr;
    }

    /// Convert token type to binary operator.
    /// Returns InvalidBinaryOperator with a proper diagnostic instead of panicking.
    fn tokenToBinaryOp(self: *Parser, token_type: TokenType) ParseError!ast.BinaryOp {
        return switch (token_type) {
            .Plus => .Add,
            .Minus => .Sub,
            .Star => .Mul,
            .Slash => .Div,
            .TildeSlash => .IntDiv,
            .Percent => .Mod,
            .StarStar => .Power,
            // Checked arithmetic (panic on overflow)
            .PlusBang => .CheckedAdd,
            .MinusBang => .CheckedSub,
            .StarBang => .CheckedMul,
            .SlashBang => .CheckedDiv,
            // Checked arithmetic with Option (returns Option)
            .PlusQuestion => .SaturatingAdd,
            .MinusQuestion => .SaturatingSub,
            .StarQuestion => .SaturatingMul,
            .SlashQuestion => .SaturatingDiv,
            // Clamping/saturating arithmetic (clamps to bounds)
            .PlusPipe => .ClampAdd,
            .MinusPipe => .ClampSub,
            .StarPipe => .ClampMul,
            .EqualEqual => .Equal,
            .BangEqual => .NotEqual,
            .Less => .Less,
            .LessEqual => .LessEq,
            .Greater => .Greater,
            .GreaterEqual => .GreaterEq,
            .AmpersandAmpersand, .And => .And,
            .PipePipe, .Or => .Or,
            .Ampersand => .BitAnd,
            .Pipe => .BitOr,
            .Caret => .BitXor,
            .LeftShift => .LeftShift,
            .RightShift => .RightShift,
            .Equal => .Assign,
            else => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Invalid binary operator token: {s}",
                    .{@tagName(token_type)},
                );
                defer self.allocator.free(msg);
                try self.reportError(msg);
                return ParseError.InvalidBinaryOperator;
            },
        };
    }

    /// Convert path segments array to string representation
    /// Example: ["basics", "os", "serial"] -> "basics/os/serial"
    fn pathToString(self: *Parser, path: []const []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        for (path, 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '/');
            try buf.appendSlice(self.allocator, segment);
        }
        return buf.toOwnedSlice(self.allocator);
    }

    /// Expand built-in macros during parsing
    /// Returns null if the macro is not a built-in or expansion fails
    fn expandBuiltinMacro(
        self: *Parser,
        name: []const u8,
        args: []*ast.Expr,
        loc: ast.SourceLocation,
    ) !?*ast.Expr {
        // todo!("message") → panic("not yet implemented: message")
        // todo!() → panic("not yet implemented")
        if (std.mem.eql(u8, name, "todo") or std.mem.eql(u8, name, "unimplemented")) {
            const message = if (args.len > 0)
                try std.fmt.allocPrint(self.allocator, "not yet implemented: {s}", .{
                    // Extract string literal content if available
                    if (args[0].* == .StringLiteral) args[0].StringLiteral.value else "<<expr>>",
                })
            else
                try self.allocator.dupe(u8, "not yet implemented");

            return try self.createPanicCall(message, loc);
        }

        // unreachable!("message") → panic("unreachable code: message")
        if (std.mem.eql(u8, name, "unreachable")) {
            const message = if (args.len > 0)
                try std.fmt.allocPrint(self.allocator, "unreachable code: {s}", .{
                    if (args[0].* == .StringLiteral) args[0].StringLiteral.value else "<<expr>>",
                })
            else
                try self.allocator.dupe(u8, "unreachable code");

            return try self.createPanicCall(message, loc);
        }

        // assert!(condition, "message") → if (!(condition)) { panic("assertion failed: message"); }
        if (std.mem.eql(u8, name, "assert")) {
            if (args.len == 0) {
                try self.reportError("assert! macro requires at least a condition");
                return null;
            }

            const condition = args[0];

            // Extract or construct the message
            const message = if (args.len > 1 and args[1].* == .StringLiteral)
                try std.fmt.allocPrint(self.allocator, "assertion failed: {s}", .{args[1].StringLiteral.value})
            else
                try self.allocator.dupe(u8, "assertion failed");

            // Create !condition (negated condition)
            const negated_cond = try self.allocator.create(ast.Expr);
            const unary = try self.allocator.create(ast.UnaryExpr);
            unary.* = .{
                .node = .{ .type = .UnaryExpr, .loc = loc },
                .op = .Not,
                .operand = condition,
            };
            negated_cond.* = ast.Expr{ .UnaryExpr = unary };

            // Create panic call for then branch
            const panic_call = try self.createPanicCall(message, loc);

            // Create void expression for else branch
            const void_expr = try self.allocator.create(ast.Expr);
            void_expr.* = ast.Expr{ .NullLiteral = .{
                .node = .{ .type = .NullLiteral, .loc = loc },
            } };

            // Create if expression: if (!condition) panic(message) else void
            const if_expr = try ast.IfExpr.init(self.allocator, negated_cond, panic_call, void_expr, loc);
            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .IfExpr = if_expr };

            return result;
        }

        // debug_assert! - same as assert in debug builds, compiled out in release
        // For now, treat it the same as assert! (in the future, this could check build mode)
        if (std.mem.eql(u8, name, "debug_assert")) {
            if (args.len == 0) {
                try self.reportError("debug_assert! macro requires at least a condition");
                return null;
            }

            const condition = args[0];

            // Extract or construct the message
            const message = if (args.len > 1 and args[1].* == .StringLiteral)
                try std.fmt.allocPrint(self.allocator, "debug assertion failed: {s}", .{args[1].StringLiteral.value})
            else
                try self.allocator.dupe(u8, "debug assertion failed");

            // Create !condition (negated condition)
            const negated_cond = try self.allocator.create(ast.Expr);
            const unary = try self.allocator.create(ast.UnaryExpr);
            unary.* = .{
                .node = .{ .type = .UnaryExpr, .loc = loc },
                .op = .Not,
                .operand = condition,
            };
            negated_cond.* = ast.Expr{ .UnaryExpr = unary };

            // Create panic call for then branch
            const panic_call = try self.createPanicCall(message, loc);

            // Create void expression for else branch
            const void_expr = try self.allocator.create(ast.Expr);
            void_expr.* = ast.Expr{ .NullLiteral = .{
                .node = .{ .type = .NullLiteral, .loc = loc },
            } };

            // Create if expression: if (!condition) panic(message) else void
            const if_expr = try ast.IfExpr.init(self.allocator, negated_cond, panic_call, void_expr, loc);
            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .IfExpr = if_expr };

            return result;
        }

        // Not a built-in macro
        return null;
    }

    /// Create a panic("message") call expression
    fn createPanicCall(self: *Parser, message: []const u8, loc: ast.SourceLocation) !*ast.Expr {
        // Create string literal for message
        const str_lit = ast.StringLiteral{
            .node = .{ .type = .StringLiteral, .loc = loc },
            .value = message,
        };

        const str_expr = try self.allocator.create(ast.Expr);
        str_expr.* = ast.Expr{ .StringLiteral = str_lit };

        // Create args array
        const call_args = try self.allocator.alloc(*ast.Expr, 1);
        call_args[0] = str_expr;

        // Create call to panic function
        const panic_name = ast.Identifier{
            .node = .{ .type = .Identifier, .loc = loc },
            .name = "panic",
        };

        const panic_expr = try self.allocator.create(ast.Expr);
        panic_expr.* = ast.Expr{ .Identifier = panic_name };

        const call_expr = try ast.CallExpr.init(
            self.allocator,
            panic_expr,
            call_args,
            loc,
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .CallExpr = call_expr };
        return result;
    }

    /// Create: if (!(condition)) { panic(message); }
    fn createAssertExpansion(
        self: *Parser,
        condition: *ast.Expr,
        message: []const u8,
        loc: ast.SourceLocation,
    ) !*ast.Expr {
        // Create !(condition)
        const not_expr = try ast.UnaryExpr.init(
            self.allocator,
            .Not,
            condition,
            loc,
        );

        const not_expr_wrapped = try self.allocator.create(ast.Expr);
        not_expr_wrapped.* = ast.Expr{ .UnaryExpr = not_expr };

        // Create panic call
        const panic_call = try self.createPanicCall(message, loc);

        // Create statement from panic call expression (CallExpr can be used as a statement)
        const stmt = try self.allocator.create(ast.Stmt);
        stmt.* = panic_call.*;

        // Create block with panic statement
        const block_stmts = try self.allocator.alloc(ast.Stmt, 1);
        block_stmts[0] = stmt.*;

        const then_block = try ast.BlockStmt.init(self.allocator, block_stmts, loc);
        const then_stmt = try self.allocator.create(ast.Stmt);
        then_stmt.* = ast.Stmt{ .BlockStmt = then_block };

        // Create if expression: if (!(condition)) { panic(message); }
        const if_expr = try ast.IfExpr.init(
            self.allocator,
            not_expr_wrapped,
            then_stmt,
            null, // no else branch
            loc,
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .IfExpr = if_expr };
        return result;
    }

    // Trait parsing methods
    pub const traitDeclaration = trait_parser.parseTraitDeclaration;
    pub const implDeclaration = trait_parser.parseImplDeclaration;
    pub const extendDeclaration = trait_parser.parseExtendDeclaration;
    pub const parseWhereClause = trait_parser.parseWhereClause;
    pub const parseTypeExpr = trait_parser.parseTypeExpr;

    // Closure parsing methods
    pub const parseClosureExpr = closure_parser.parseClosureExpr;
};
