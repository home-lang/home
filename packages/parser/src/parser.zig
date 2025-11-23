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
const Precedence = enum(u8) {
    None = 0,
    Assignment = 1,     // =
    Ternary = 2,        // ?:
    NullCoalesce = 3,   // ??
    Or = 4,             // ||
    And = 5,            // &&
    BitOr = 6,          // |
    BitXor = 7,         // ^
    BitAnd = 8,         // &
    Equality = 9,       // == !=
    Comparison = 10,    // < > <= >=
    TypeCast = 11,      // as
    Range = 12,         // .. ..=
    Pipe = 13,          // |> (function pipeline)
    Shift = 14,         // << >> (bitwise shifts)
    Term = 15,          // + -
    Factor = 16,        // * / % ~/
    Power = 17,         // ** (exponentiation, right-associative)
    Unary = 18,         // ! - ...
    Call = 20,          // . () [] ?.
    Primary = 21,

    /// Get the precedence level for a given token type.
    ///
    /// Maps operator tokens to their precedence levels. Non-operator
    /// tokens return None precedence.
    ///
    /// Parameters:
    ///   - token_type: The token to get precedence for
    ///
    /// Returns: Precedence level for this token
    fn fromToken(token_type: TokenType) Precedence {
        return switch (token_type) {
            .Equal, .PlusEqual, .MinusEqual, .StarEqual, .SlashEqual, .PercentEqual => .Assignment,
            .Question => .Ternary,
            .QuestionQuestion, .QuestionColon => .NullCoalesce,
            .QuestionBracket => .Call,
            .PipePipe, .Or => .Or,
            .AmpersandAmpersand, .And => .And,
            .Pipe => .BitOr,
            .PipeGreater => .Pipe,
            .Caret => .BitXor,
            .Ampersand => .BitAnd,
            .EqualEqual, .BangEqual => .Equality,
            .Less, .LessEqual, .Greater, .GreaterEqual => .Comparison,
            .As => .TypeCast,
            .DotDot, .DotDotEqual => .Range,
            .LeftShift, .RightShift => .Shift,
            .Plus, .Minus => .Term,
            .Star, .Slash, .Percent, .TildeSlash => .Factor,
            .StarStar => .Power,
            .LeftParen, .LeftBracket, .Dot, .QuestionDot => .Call,
            else => .None,
        };
    }
};

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
    /// Module resolver for handling imports
    module_resolver: ModuleResolver,
    /// Symbol table for tracking imported modules and symbols
    symbol_table: SymbolTable,

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
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .current = 0,
            .errors = std.ArrayList(ParseErrorInfo){ .items = &.{}, .capacity = 0 },
            .panic_mode = false,
            .recursion_depth = 0,
            .error_formatter = errors.ErrorFormatter.init(allocator),
            .source_file = null,
            .module_resolver = try ModuleResolver.init(allocator),
            .symbol_table = SymbolTable.init(allocator),
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
    }

    /// Check if we've reached the end of the token stream.
    ///
    /// Returns: true if current token is EOF, false otherwise
    pub fn isAtEnd(self: *Parser) bool {
        return self.peek().type == .Eof;
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
    fn peek(self: *Parser) Token {
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

    /// Get the most recently consumed token.
    ///
    /// Returns: The token just before the current position
    pub fn previous(self: *Parser) Token {
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
        const formatted = try self.error_formatter.formatError(
            filename,
            token.line,
            token.column,
            message,
            null, // source_line (would need access to source)
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
                .Fn, .Struct, .Let, .Const, .If, .While, .For, .Return => return,
                .RightBrace => {
                    // Consume the closing brace to avoid getting stuck
                    _ = self.advance();
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
        var statements = std.ArrayList(ast.Stmt){};
        defer statements.deinit(self.allocator);

        while (!self.isAtEnd()) {
            if (self.declaration()) |stmt| {
                try statements.append(self.allocator, stmt);
                self.panic_mode = false; // Successfully parsed, exit panic mode
            } else |err| {
                // Error occurred, synchronize and continue parsing
                self.synchronize();

                // If this was a real error (not just panic mode), keep going
                if (err != error.OutOfMemory) {
                    continue; // Try to parse next statement
                }
                return err; // Out of memory is fatal
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
        var attrs = std.ArrayList(ast.Attribute){ .items = &.{}, .capacity = 0 };
        defer attrs.deinit(self.allocator);

        while (self.match(&.{.At})) {
            const name_token = try self.expect(.Identifier, "Expected attribute name after '@'");
            const name = name_token.lexeme;

            var args = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
            defer args.deinit(self.allocator);

            // Parse optional arguments: @attribute(arg1, arg2)
            if (self.match(&.{.LeftParen})) {
                if (!self.check(.RightParen)) {
                    while (true) {
                        const arg = try self.expression();
                        try args.append(self.allocator, arg);
                        if (!self.match(&.{.Comma})) break;
                    }
                }
                _ = try self.expect(.RightParen, "Expected ')' after attribute arguments");
            }

            const attr = ast.Attribute.init(name, try args.toOwnedSlice(self.allocator));
            try attrs.append(self.allocator, attr);
        }

        return try attrs.toOwnedSlice(self.allocator);
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
        // Parse any attributes first
        const attributes = try self.parseAttributes();

        // Check for pub modifier
        const is_pub = self.match(&.{.Pub});

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

        if (self.match(&.{.Fn})) {
            var stmt = try self.functionDeclaration(is_test);
            if (is_pub) stmt.FnDecl.is_public = true;
            stmt.FnDecl.attributes = attributes;
            return stmt;
        }

        if (self.match(&.{.Let})) {
            var stmt = try self.letDeclaration(false);
            if (is_pub) stmt.LetDecl.is_public = true;
            return stmt;
        }

        if (self.match(&.{.Const})) {
            var stmt = try self.letDeclaration(true);
            if (is_pub) stmt.LetDecl.is_public = true;
            return stmt;
        }

        // Check for it('description') { body } test syntax
        if (self.match(&.{.It})) {
            return try self.itTestDeclaration();
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
    pub fn functionDeclaration(self: *Parser, is_test: bool) !ast.Stmt {
        // Check for async keyword before function name
        const is_async = self.match(&.{.Async});

        const name_token = try self.expect(.Identifier, "Expected function name");
        const name = name_token.lexeme;

        // Parse generic type parameters if present: fn name<T, U>()
        var type_params = std.ArrayList([]const u8){};
        defer type_params.deinit(self.allocator);

        if (self.match(&.{.Less})) {
            while (!self.check(.Greater) and !self.isAtEnd()) {
                const type_param = try self.expect(.Identifier, "Expected type parameter name");
                try type_params.append(self.allocator, type_param.lexeme);

                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.expect(.Greater, "Expected '>' after type parameters");
        }

        _ = try self.expect(.LeftParen, "Expected '(' after function name");

        // Parse parameters
        var params = std.ArrayList(ast.Parameter){};
        defer params.deinit(self.allocator);

        if (!self.check(.RightParen)) {
            while (true) {
                // Accept both Identifier and 'self' keyword as parameter names
                const param_name = if (self.check(.Identifier))
                    try self.expect(.Identifier, "Expected parameter name")
                else if (self.check(.SelfValue))
                    try self.expect(.SelfValue, "Expected parameter name")
                else {
                    try self.reportError("Expected parameter name");
                    return error.UnexpectedToken;
                };
                _ = try self.expect(.Colon, "Expected ':' after parameter name");
                const param_type = try self.parseTypeAnnotation();

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
                });

                if (!self.match(&.{.Comma})) break;
            }
        }

        _ = try self.expect(.RightParen, "Expected ')' after parameters");

        // Parse return type (TypeScript-style with colon)
        var return_type: ?[]const u8 = null;
        if (self.match(&.{.Colon})) {
            return_type = try self.parseTypeAnnotation();
        }

        // Parse body
        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

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

    /// Parse a struct declaration
    fn structDeclaration(self: *Parser) !ast.Stmt {
        const struct_token = self.previous();
        const name_token = try self.expect(.Identifier, "Expected struct name");
        const name = name_token.lexeme;

        // Parse generic type parameters if present: struct Name<T, U>
        var type_params = std.ArrayList([]const u8){};
        defer type_params.deinit(self.allocator);

        if (self.match(&.{.Less})) {
            while (!self.check(.Greater) and !self.isAtEnd()) {
                const type_param = try self.expect(.Identifier, "Expected type parameter name");
                try type_params.append(self.allocator, type_param.lexeme);

                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.expect(.Greater, "Expected '>' after type parameters");
        }

        _ = try self.expect(.LeftBrace, "Expected '{' after struct name");

        // Parse fields
        var fields = std.ArrayList(ast.StructField){};
        defer fields.deinit(self.allocator);

        // Also collect methods defined inside the struct
        var methods = std.ArrayList(*ast.FnDecl){};
        defer methods.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            // Check if this is a method definition (fn keyword)
            if (self.match(&.{.Fn})) {
                // Parse method and collect it
                const method_stmt = try self.functionDeclaration(false);
                switch (method_stmt) {
                    .FnDecl => |fn_decl| {
                        try methods.append(self.allocator, fn_decl);
                    },
                    else => {
                        try self.reportError("Expected function declaration in struct");
                        return error.UnexpectedToken;
                    },
                }
                continue;
            }

            const field_name = try self.expect(.Identifier, "Expected field name");
            _ = try self.expect(.Colon, "Expected ':' after field name");
            const field_type_name = try self.parseTypeAnnotation();

            try fields.append(self.allocator, .{
                .name = field_name.lexeme,
                .type_name = field_type_name,
                .loc = ast.SourceLocation.fromToken(field_name),
            });

            // Optional comma between fields
            _ = self.match(&.{.Comma});
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

        return ast.Stmt{ .StructDecl = struct_decl };
    }

    /// Parse an enum declaration
    fn enumDeclaration(self: *Parser) !ast.Stmt {
        const enum_token = self.previous();
        const name_token = try self.expect(.Identifier, "Expected enum name");
        const name = name_token.lexeme;

        _ = try self.expect(.LeftBrace, "Expected '{' after enum name");

        // Parse variants
        var variants = std.ArrayList(ast.EnumVariant){};
        defer variants.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            const variant_name = try self.expect(.Identifier, "Expected variant name");

            // Check for associated data type
            var data_type: ?[]const u8 = null;
            if (self.match(&.{.LeftParen})) {
                const type_token = try self.expect(.Identifier, "Expected type in variant data");
                data_type = type_token.lexeme;
                _ = try self.expect(.RightParen, "Expected ')' after variant data type");
            }

            try variants.append(self.allocator, .{
                .name = variant_name.lexeme,
                .data_type = data_type,
            });

            // Optional comma between variants
            _ = self.match(&.{.Comma});
        }

        _ = try self.expect(.RightBrace, "Expected '}' after enum variants");

        const variants_slice = try variants.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(variants_slice);

        const enum_decl = try ast.EnumDecl.init(
            self.allocator,
            name,
            variants_slice,
            ast.SourceLocation.fromToken(enum_token),
        );

        return ast.Stmt{ .EnumDecl = enum_decl };
    }

    /// Parse a union declaration
    fn unionDeclaration(self: *Parser) !ast.Stmt {
        const union_token = self.previous();
        const name_token = try self.expect(.Identifier, "Expected union name");
        const name = name_token.lexeme;

        _ = try self.expect(.LeftBrace, "Expected '{' after union name");

        var variants = std.ArrayList(ast.UnionVariant){};
        defer variants.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            const variant_name = try self.expect(.Identifier, "Expected variant name");

            // Check for associated data type
            var type_name: ?[]const u8 = null;
            if (self.match(&.{.LeftParen})) {
                const type_token = try self.expect(.Identifier, "Expected type in variant data");
                type_name = type_token.lexeme;
                _ = try self.expect(.RightParen, "Expected ')' after variant data type");
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

        const target_type_token = try self.expect(.Identifier, "Expected target type");
        const target_type = target_type_token.lexeme;

        const type_alias_decl = try ast.TypeAliasDecl.init(
            self.allocator,
            name,
            target_type,
            ast.SourceLocation.fromToken(type_token),
        );

        return ast.Stmt{ .TypeAliasDecl = type_alias_decl };
    }

    /// Parse an import declaration
    /// Syntax:
    ///   import basics/os/serial              (import everything)
    ///   import basics/os/serial { init, COM1 }  (selective import)
    fn importDeclaration(self: *Parser) !ast.Stmt {
        const import_token = self.previous();

        // Parse module path (e.g., basics/os/serial)
        var path_segments = std.ArrayList([]const u8){};
        defer path_segments.deinit(self.allocator);

        // First segment
        const first_token = try self.expect(.Identifier, "Expected module name after 'import'");
        try path_segments.append(self.allocator, first_token.lexeme);

        // Additional segments separated by '/'
        while (self.match(&.{.Slash})) {
            const segment_token = try self.expect(.Identifier, "Expected module name after '/'");
            try path_segments.append(self.allocator, segment_token.lexeme);
        }

        const path = try path_segments.toOwnedSlice(self.allocator);

        // Resolve the module using the module resolver
        const resolved_module = self.module_resolver.resolve(path) catch |err| {
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
            return error.UnexpectedToken;  // Return a parse error
        };

        // Log successful resolution (for debugging)
        // TODO: Remove or make conditional on debug flag
        std.debug.print("[Parser] Resolved {s} -> {s} (is_zig: {any})\n", .{
            try self.pathToString(path),
            resolved_module.file_path,
            resolved_module.is_zig,
        });

        // Register the module in the symbol table
        const module_path_str = try self.pathToString(path);
        defer self.allocator.free(module_path_str);

        try self.symbol_table.registerModule(path, resolved_module.is_zig, null);

        // Populate symbols based on module type
        if (resolved_module.is_zig) {
            // Zig module - use predefined symbols
            try self.symbol_table.populateZigModuleSymbols(module_path_str);
        }
        // Note: Home module symbol population disabled temporarily due to hashmap issue
        // Symbol validation will be done at type checking phase

        // Parse optional selective import list: { item1, item2, ... } or ::{item1, item2}
        var imports: ?[]const []const u8 = null;
        // Support both "import path { items }" and "import path::{ items }" (Rust-style)
        _ = self.match(&.{.ColonColon}); // Optional :: before brace
        if (self.match(&.{.LeftBrace})) {
            var import_list = std.ArrayList([]const u8){};
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

        // Parse optional alias: import path/to/module as Alias
        var alias: ?[]const u8 = null;
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
    fn parseTypeAnnotation(self: *Parser) ![]const u8 {
        // Check for array type: [T] or [size]T
        if (self.match(&.{.LeftBracket})) {
            // For now, skip size if present and just get element type
            if (self.peek().type != .RightBracket) {
                // Has size or element type inside brackets
                const inner = try self.expect(.Identifier, "Expected type in array");
                _ = try self.expect(.RightBracket, "Expected ']'");
                // Return [element_type] as string
                const arr_type = try std.fmt.allocPrint(self.allocator, "[{s}]", .{inner.lexeme});
                return arr_type;
            } else {
                _ = try self.expect(.RightBracket, "Expected ']'");
                const elem_type = try self.expect(.Identifier, "Expected element type after '[]'");
                const arr_type = try std.fmt.allocPrint(self.allocator, "[{s}]", .{elem_type.lexeme});
                return arr_type;
            }
        }

        // Regular type (identifier)
        const type_token = try self.expect(.Identifier, "Expected type name");
        var result = try self.allocator.dupe(u8, type_token.lexeme);

        // Check for generic type arguments: Type<Arg1, Arg2, ...>
        if (self.match(&.{.Less})) {
            var args = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
            defer args.deinit(self.allocator);

            while (!self.check(.Greater) and !self.isAtEnd()) {
                const arg_type = try self.parseTypeAnnotation();
                try args.append(self.allocator, arg_type);

                if (!self.match(&.{.Comma})) break;
            }

            _ = try self.expect(.Greater, "Expected '>' after generic type arguments");

            // Build the full generic type string: "Type<Arg1, Arg2>"
            var full_type = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
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

        return result;
    }

    /// Parse a let/const declaration
    fn letDeclaration(self: *Parser, is_const: bool) !ast.Stmt {
        _ = is_const;
        const is_mutable = self.match(&.{.Mut});
        const name_token = try self.expect(.Identifier, "Expected variable name");

        // Optional type annotation
        var type_name: ?[]const u8 = null;
        if (self.match(&.{.Colon})) {
            type_name = try self.parseTypeAnnotation();
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

    /// Parse a statement
    fn statement(self: *Parser) !ast.Stmt {
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
        return self.expressionStatement();
    }

    /// Parse a return statement
    fn returnStatement(self: *Parser) !ast.Stmt {
        const return_token = self.previous();
        var value: ?*ast.Expr = null;

        if (!self.check(.RightBrace) and !self.isAtEnd()) {
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
        // Parentheses are optional: both "if (cond)" and "if cond" work
        const has_paren = self.match(&.{.LeftParen});
        const condition = try self.expression();
        if (has_paren) {
            _ = try self.expect(.RightParen, "Expected ')' after if condition");
        }
        errdefer ast.Program.deinitExpr(condition, self.allocator);

        const then_block = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(then_block, self.allocator);

        var else_block: ?*ast.BlockStmt = null;
        if (self.match(&.{.Else})) {
            // Handle else if as a nested if statement wrapped in a block
            if (self.check(.If)) {
                // Parse the else if as another if statement
                _ = self.advance(); // consume 'if'
                const else_if_stmt = try self.ifStatement();

                // Wrap the else-if in a block
                const else_block_ptr = try self.allocator.create(ast.BlockStmt);
                var stmts_list = std.ArrayList(ast.Stmt){};
                try stmts_list.append(self.allocator, else_if_stmt);
                else_block_ptr.* = ast.BlockStmt{
                    .node = .{ .type = .BlockStmt, .loc = ast.SourceLocation.fromToken(self.previous()) },
                    .statements = try stmts_list.toOwnedSlice(self.allocator),
                };
                else_block = else_block_ptr;
            } else {
                else_block = try self.blockStatement();
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

    /// Parse a while statement
    fn whileStatement(self: *Parser) !ast.Stmt {
        const while_token = self.previous();
        // Parentheses are optional: both "while (cond)" and "while cond" work
        const has_paren = self.match(&.{.LeftParen});
        const condition = try self.expression();
        if (has_paren) {
            _ = try self.expect(.RightParen, "Expected ')' after while condition");
        }
        errdefer ast.Program.deinitExpr(condition, self.allocator);

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        const stmt = try ast.WhileStmt.init(
            self.allocator,
            condition,
            body,
            ast.SourceLocation.fromToken(while_token),
        );

        return ast.Stmt{ .WhileStmt = stmt };
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

    /// Parse a for statement
    fn forStatement(self: *Parser) !ast.Stmt {
        const for_token = self.previous();
        // Parentheses are optional: both "for (x in items)" and "for x in items" work
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

        return ast.Stmt{ .DoWhileStmt = stmt };
    }

    /// Parse a switch statement
    fn switchStatement(self: *Parser) ParseError!ast.Stmt {
        const switch_token = self.previous();

        const value = try self.expression();
        errdefer ast.Program.deinitExpr(value, self.allocator);

        _ = try self.expect(.LeftBrace, "Expected '{' after switch value");

        var cases = std.ArrayList(*ast.CaseClause){ .items = &.{}, .capacity = 0 };
        defer cases.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            if (self.match(&.{.Case})) {
                // Parse case patterns
                var patterns = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
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
                var body_stmts = std.ArrayList(ast.Stmt){ .items = &.{}, .capacity = 0 };
                defer body_stmts.deinit(self.allocator);

                while (!self.check(.Case) and !self.check(.Default) and !self.check(.RightBrace) and !self.isAtEnd()) {
                    const stmt = try self.statement();
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
                _ = try self.expect(.Colon, "Expected ':' after 'default'");

                // Parse default body
                var body_stmts = std.ArrayList(ast.Stmt){ .items = &.{}, .capacity = 0 };
                defer body_stmts.deinit(self.allocator);

                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    const stmt = try self.statement();
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
            } else {
                try self.reportError("Expected 'case' or 'default' in switch statement");
                return error.UnexpectedToken;
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

    /// Parse a match statement with pattern matching
    fn matchStatement(self: *Parser) !ast.Stmt {
        const match_token = self.previous();

        // Parse the value to match against
        const value = try self.expression();
        errdefer ast.Program.deinitExpr(value, self.allocator);

        _ = try self.expect(.LeftBrace, "Expected '{' after match value");

        var arms = std.ArrayList(*ast.MatchArm){ .items = &.{}, .capacity = 0 };
        defer arms.deinit(self.allocator);

        // Parse match arms
        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            // Parse pattern
            var pattern = try self.parsePattern();

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

            // Parse arm body (just parse as expression, blocks are expressions too)
            const body = try self.expression();

            errdefer ast.Program.deinitExpr(body, self.allocator);

            // Expect comma or closing brace
            if (!self.check(.RightBrace)) {
                _ = try self.expect(.Comma, "Expected ',' after match arm");
            }

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

        // Integer literal pattern
        if (self.match(&.{.Integer})) {
            const token = self.previous();
            const value = try std.fmt.parseInt(i64, token.lexeme, 10);
            pattern.* = ast.Pattern{ .IntLiteral = value };
            return pattern;
        }

        // Float literal pattern
        if (self.match(&.{.Float})) {
            const token = self.previous();
            const value = try std.fmt.parseFloat(f64, token.lexeme);
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

        // Tuple pattern: (pattern1, pattern2, ...)
        if (self.match(&.{.LeftParen})) {
            var elements = std.ArrayList(*ast.Pattern){ .items = &.{}, .capacity = 0 };
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
            var elements = std.ArrayList(*ast.Pattern){ .items = &.{}, .capacity = 0 };
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

        // Range pattern: start..end or start..=end
        // Check for identifier or number first
        if (self.check(.Integer) or self.check(.Identifier)) {
            const start_pos = self.current;

            // Try to parse as range
            const start_expr = try self.expression();

            if (self.match(&.{.DotDot, .DotDotEqual})) {
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

            // Check for qualified name: Type::Variant
            if (self.match(&.{.ColonColon})) {
                const variant_token = try self.expect(.Identifier, "Expected variant name after '::'");
                // Combine into qualified name
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ name, variant_token.lexeme });
                name = qualified;
            }

            // Check if it's a struct pattern: Name { field1, field2: pattern }
            if (self.match(&.{.LeftBrace})) {
                var fields = std.ArrayList(ast.Pattern.FieldPattern){ .items = &.{}, .capacity = 0 };
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

    /// Parse a try-catch-finally statement
    fn tryStatement(self: *Parser) !ast.Stmt {
        const try_token = self.previous();

        const try_block = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(try_block, self.allocator);

        var catch_clauses = std.ArrayList(*ast.CatchClause){ .items = &.{}, .capacity = 0 };
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

    /// Parse a block statement
    pub fn blockStatement(self: *Parser) !*ast.BlockStmt {
        // Expect the opening brace (or use previous if already consumed)
        const start_token = if (self.previous().type == .LeftBrace)
            self.previous()
        else
            try self.expect(.LeftBrace, "Expected '{'");

        var statements = std.ArrayList(ast.Stmt){ .items = &.{}, .capacity = 0 };
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
                        current.type == .For or current.type == .Return) {
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
    fn expression(self: *Parser) !*ast.Expr {
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
        while (@intFromEnum(precedence) <= @intFromEnum(Precedence.fromToken(self.peek().type))) {
            if (self.match(&.{ .Plus, .Minus, .Star, .Slash, .Percent, .StarStar, .TildeSlash })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{ .EqualEqual, .BangEqual, .Less, .LessEqual, .Greater, .GreaterEqual })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{ .AmpersandAmpersand, .PipePipe, .And, .Or })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{ .Ampersand, .Pipe, .Caret, .LeftShift, .RightShift })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{.As})) {
                expr = try self.typeCast(expr);
            } else if (self.match(&.{ .DotDot, .DotDotEqual })) {
                expr = try self.rangeExpr(expr);
            } else if (self.match(&.{.PipeGreater})) {
                expr = try self.pipeExpr(expr);
            } else if (self.match(&.{.QuestionQuestion})) {
                expr = try self.nullCoalesceExpr(expr);
            } else if (self.match(&.{.QuestionColon})) {
                expr = try self.elvisExpr(expr);
            } else if (self.match(&.{.QuestionBracket})) {
                expr = try self.safeIndexExpr(expr);
            } else if (self.check(.Question) and self.peekNext().type == .Colon) {
                _ = self.advance(); // consume '?'
                expr = try self.ternaryExpr(expr);
            } else if (self.match(&.{.Equal})) {
                expr = try self.assignment(expr);
            } else if (self.match(&.{ .PlusEqual, .MinusEqual, .StarEqual, .SlashEqual, .PercentEqual })) {
                expr = try self.compoundAssignment(expr);
            } else if (self.match(&.{.LeftParen})) {
                expr = try self.call(expr);
            } else if (self.match(&.{.LeftBracket})) {
                expr = try self.indexExpr(expr);
            } else if (self.match(&.{.Dot})) {
                expr = try self.memberExpr(expr);
            } else if (self.match(&.{.QuestionDot})) {
                expr = try self.safeNavExpr(expr);
            } else if (self.match(&.{.Question})) {
                expr = try self.tryExpr(expr);
            } else {
                break;
            }
        }

        return expr;
    }

    /// Parse a binary expression
    fn binary(self: *Parser, left: *ast.Expr) !*ast.Expr {
        const op_token = self.previous();
        const op = self.tokenToBinaryOp(op_token.type);
        const precedence = Precedence.fromToken(op_token.type);
        const right = try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));

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

    /// Parse a range expression (e.g., 0..10, 1..=100)
    fn rangeExpr(self: *Parser, start: *ast.Expr) !*ast.Expr {
        const range_token = self.previous();
        const inclusive = range_token.type == .DotDotEqual;

        const precedence = Precedence.fromToken(range_token.type);
        const end = try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));

        const range_expr = try ast.RangeExpr.init(
            self.allocator,
            start,
            end,
            inclusive,
            ast.SourceLocation.fromToken(range_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .RangeExpr = range_expr };
        return result;
    }

    /// Parse a type cast expression (e.g., value as i32)
    fn typeCast(self: *Parser, value: *ast.Expr) !*ast.Expr {
        const as_token = self.previous();

        // Expect a type identifier after 'as'
        const type_token = try self.expect(.Identifier, "Expected type name after 'as'");
        const target_type = type_token.lexeme;

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

        // Validate that the target is a valid lvalue (identifier, index, or member access)
        switch (target.*) {
            .Identifier, .IndexExpr, .MemberExpr => {},
            else => {
                try self.reportError("Invalid assignment target");
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

        // Validate that the target is a valid lvalue
        switch (target.*) {
            .Identifier, .IndexExpr, .MemberExpr => {},
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

        var args = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
        defer args.deinit(self.allocator);

        var named_args = std.ArrayList(ast.NamedArg){ .items = &.{}, .capacity = 0 };
        defer named_args.deinit(self.allocator);

        var seen_named = false; // Track if we've seen a named argument

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

    /// Parse a member access expression (struct.field)
    fn memberExpr(self: *Parser, object: *ast.Expr) !*ast.Expr {
        const dot_token = self.previous();
        const member_token = try self.expect(.Identifier, "Expected field name after '.'");

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

        const true_val = try self.expression();
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

    /// Parse an if expression: if (condition) { expr } else { expr }
    fn ifExpr(self: *Parser) !*ast.Expr {
        const if_token = self.previous();
        _ = try self.expect(.LeftParen, "Expected '(' after 'if'");
        const condition = try self.expression();
        _ = try self.expect(.RightParen, "Expected ')' after if condition");

        _ = try self.expect(.LeftBrace, "Expected '{' after if condition");
        const then_branch = try self.expression();
        _ = try self.expect(.RightBrace, "Expected '}' after if expression body");

        _ = try self.expect(.Else, "If expression requires 'else' branch");
        _ = try self.expect(.LeftBrace, "Expected '{' after 'else'");
        const else_branch = try self.expression();
        _ = try self.expect(.RightBrace, "Expected '}' after else expression body");

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
        // Parse the base expression (identifier, literal, parenthesized)
        var expr = try self.parseMatchValuePrimary();

        // Handle member access and calls, but NOT struct literals
        while (true) {
            if (self.match(&.{.Dot})) {
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
                var args = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
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

    /// Parse a match expression: match value { pattern => expr, ... }
    fn matchExpr(self: *Parser) !*ast.Expr {
        const match_token = self.previous();
        // Parse value - use a simpler approach: just get the primary and handle
        // member/call chains manually to avoid struct literal confusion
        const value = try self.parseMatchValue();

        _ = try self.expect(.LeftBrace, "Expected '{' after match value");

        var arms = std.ArrayList(ast.MatchExprArm){ .items = &.{}, .capacity = 0 };
        defer arms.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            // Parse pattern
            const pattern = try self.expression();

            // Parse optional guard: if condition
            var guard: ?*ast.Expr = null;
            if (self.match(&.{.If})) {
                guard = try self.expression();
            }

            _ = try self.expect(.FatArrow, "Expected '=>' after match pattern");

            // Parse body expression
            const body = try self.expression();

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

    /// Parse a primary expression (literals, identifiers, grouping)
    fn primary(self: *Parser) ParseError!*ast.Expr {
        // Inline assembly
        if (self.match(&.{.Asm})) {
            const asm_token = self.previous();
            _ = try self.expect(.LeftParen, "Expected '(' after 'asm'");
            const str_token = try self.expect(.String, "Expected string literal for assembly instruction");
            _ = try self.expect(.RightParen, "Expected ')' after assembly instruction");

            // Remove quotes from string literal
            const instruction = str_token.lexeme[1 .. str_token.lexeme.len - 1];

            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .InlineAsm = ast.InlineAsm.init(instruction, ast.SourceLocation.fromToken(asm_token)) };
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

        // Match expression: match value { pattern => expr, ... }
        if (self.match(&.{.Match})) {
            return try self.matchExpr();
        }

        // Reflection expression (@TypeOf, @sizeOf, etc.)
        if (self.match(&.{.At})) {
            const at_token = self.previous();
            const name_token = try self.expect(.Identifier, "Expected reflection function name after '@'");
            const name = name_token.lexeme;

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
                if (std.mem.eql(u8, name, "abs")) break :blk .Abs;

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

            // Parse target expression
            const target = try self.expression();

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
                field_name,
                ast.SourceLocation.fromToken(at_token),
            );
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .ReflectExpr = reflect_expr };
            return expr;
        }

        // Check for invalid tokens and report them clearly
        if (self.peek().type == .Invalid) {
            const token = self.advance();
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Invalid character '{s}' in source code",
                .{token.lexeme}
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
            var clean_lexeme = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
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

            const value = std.fmt.parseInt(i64, parse_str, base) catch |err| {
                if (err == error.Overflow) {
                    try self.reportError("Integer literal is too large (exceeds i64 range)");
                    return error.IntegerOverflow;
                }
                return err;
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
            var clean_lexeme = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
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

        // Identifiers (and macro invocations)
        if (self.match(&.{.Identifier})) {
            const token = self.previous();

            // Check for static method call (Type::method())
            if (self.match(&.{.ColonColon})) {
                const method_token = try self.expect(.Identifier, "Expected method name after '::'");

                // Parse arguments if followed by parentheses
                if (self.match(&.{.LeftParen})) {
                    var args = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
                    defer args.deinit(self.allocator);

                    if (!self.check(.RightParen)) {
                        while (true) {
                            const arg = try self.expression();
                            try args.append(self.allocator, arg);
                            if (!self.match(&.{.Comma})) break;
                        }
                    }

                    _ = try self.expect(.RightParen, "Expected ')' after arguments");

                    const static_call = try ast.StaticCallExpr.init(
                        self.allocator,
                        token.lexeme,
                        method_token.lexeme,
                        try args.toOwnedSlice(self.allocator),
                        ast.SourceLocation.fromToken(token),
                    );

                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = ast.Expr{ .StaticCallExpr = static_call };
                    return expr;
                } else {
                    // Static method reference without call (e.g., for passing as callback)
                    // Treat as member expression on type
                    const type_id = try self.allocator.create(ast.Expr);
                    type_id.* = ast.Expr{
                        .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
                    };

                    const member_expr = try ast.MemberExpr.init(
                        self.allocator,
                        type_id,
                        method_token.lexeme,
                        ast.SourceLocation.fromToken(method_token),
                    );

                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = ast.Expr{ .MemberExpr = member_expr };
                    return expr;
                }
            }

            // Check for macro invocation (identifier!)
            if (self.match(&.{.Bang})) {
                const bang_token = self.previous();

                // Parse macro arguments
                _ = try self.expect(.LeftParen, "Expected '(' after '!' for macro invocation");

                var args = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
                defer args.deinit(self.allocator);

                if (!self.check(.RightParen)) {
                    while (true) {
                        const arg = try self.expression();
                        try args.append(self.allocator, arg);
                        if (!self.match(&.{.Comma})) break;
                    }
                }

                _ = try self.expect(.RightParen, "Expected ')' after macro arguments");

                const macro_expr = try ast.MacroExpr.init(
                    self.allocator,
                    token.lexeme,
                    try args.toOwnedSlice(self.allocator),
                    ast.SourceLocation.fromToken(bang_token),
                );

                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .MacroExpr = macro_expr };
                return expr;
            }

            // Check for struct literal: TypeName { field: value, ... }
            // Only treat as struct literal if we see { identifier : pattern
            // This avoids ambiguity with for loops: "for x in items { let..." is NOT a struct literal
            if (self.check(.LeftBrace)) {
                // Look ahead to see if this is actually a struct literal
                const checkpoint = self.current;
                _ = self.advance(); // consume '{'

                const is_struct_literal = blk: {
                    // Empty braces {} could be struct literal
                    if (self.check(.RightBrace)) break :blk true;

                    // If next token is an identifier followed by :, it's a struct literal
                    if (self.check(.Identifier)) {
                        const after_ident_pos = self.current + 1;
                        if (after_ident_pos < self.tokens.len) {
                            if (self.tokens[after_ident_pos].type == .Colon) {
                                break :blk true;
                            }
                        }
                    }

                    // Otherwise it's not a struct literal (e.g., a block after for x in items)
                    break :blk false;
                };

                if (!is_struct_literal) {
                    // Restore position and return identifier
                    self.current = checkpoint;
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = ast.Expr{
                        .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
                    };
                    return expr;
                }

                var fields = std.ArrayList(ast.FieldInit){ .items = &.{}, .capacity = 0 };
                defer fields.deinit(self.allocator);

                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    const field_name_token = try self.expect(.Identifier, "Expected field name");
                    _ = try self.expect(.Colon, "Expected ':' after field name");
                    const field_value = try self.expression();

                    try fields.append(self.allocator, ast.FieldInit{
                        .name = field_name_token.lexeme,
                        .value = field_value,
                        .is_shorthand = false,
                        .loc = ast.SourceLocation.fromToken(field_name_token),
                    });

                    if (!self.match(&.{.Comma})) break;
                }

                _ = try self.expect(.RightBrace, "Expected '}' after struct fields");

                const struct_lit = try self.allocator.create(ast.StructLiteralExpr);
                struct_lit.* = ast.StructLiteralExpr.init(
                    token.lexeme,
                    try fields.toOwnedSlice(self.allocator),
                    false,
                    ast.SourceLocation.fromToken(token),
                );

                const expr = try self.allocator.create(ast.Expr);
                expr.* = ast.Expr{ .StructLiteral = struct_lit };
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

        // Unary expressions
        if (self.match(&.{ .Bang, .Minus, .Tilde })) {
            const op_token = self.previous();
            const op: ast.UnaryOp = switch (op_token.type) {
                .Bang => .Not,
                .Minus => .Neg,
                .Tilde => .BitNot,
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

            var entries = std.ArrayList(ast.MapEntry){ .items = &.{}, .capacity = 0 };
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

        // Array literals
        if (self.match(&.{.LeftBracket})) {
            const bracket_token = self.previous();
            var elements = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
            defer elements.deinit(self.allocator);

            if (!self.check(.RightBracket)) {
                while (true) {
                    const elem = try self.expression();
                    try elements.append(self.allocator, elem);

                    if (!self.match(&.{.Comma})) break;
                    // Allow trailing comma
                    if (self.check(.RightBracket)) break;
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

            const first_expr = try self.expression();

            // Check if it's a tuple (comma after first element)
            if (self.match(&.{.Comma})) {
                var elements = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
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

        std.debug.print("Parse error at line {d}: Unexpected token '{s}'\n", .{ self.peek().line, self.peek().lexeme });
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

        var parts_list = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer parts_list.deinit(self.allocator);

        var exprs_list = std.ArrayList(ast.Expr){ .items = &.{}, .capacity = 0 };
        defer exprs_list.deinit(self.allocator);

        // Add first part (text before first {)
        const first_part = start_token.lexeme[1 .. start_token.lexeme.len - 1]; // Remove " and {
        try parts_list.append(self.allocator, first_part);

        // Parse expressions and middle parts
        while (true) {
            // Parse the expression inside {}
            const expr = try self.expression();
            try exprs_list.append(self.allocator, expr.*);

            // Check what comes next
            if (self.match(&.{.StringInterpolationMid})) {
                // More interpolation coming
                const mid_token = self.previous();
                const mid_part = mid_token.lexeme[1 .. mid_token.lexeme.len - 1]; // Remove } and {
                try parts_list.append(self.allocator, mid_part);
            } else if (self.match(&.{.StringInterpolationEnd})) {
                // End of interpolation
                const end_token = self.previous();
                const end_part = end_token.lexeme[1 .. end_token.lexeme.len - 1]; // Remove } and "
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

    /// Convert token type to binary operator
    fn tokenToBinaryOp(self: *Parser, token_type: TokenType) ast.BinaryOp {
        _ = self;
        return switch (token_type) {
            .Plus => .Add,
            .Minus => .Sub,
            .Star => .Mul,
            .Slash => .Div,
            .TildeSlash => .IntDiv,
            .Percent => .Mod,
            .StarStar => .Power,
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
            else => std.debug.panic("Invalid binary operator token: {any}", .{token_type}),
        };
    }

    /// Convert path segments array to string representation
    /// Example: ["basics", "os", "serial"] -> "basics/os/serial"
    fn pathToString(self: *Parser, path: []const []const u8) ![]const u8 {
        var buf = std.ArrayList(u8){};
        for (path, 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '/');
            try buf.appendSlice(self.allocator, segment);
        }
        return buf.toOwnedSlice(self.allocator);
    }
    
    // Trait parsing methods
    pub const traitDeclaration = trait_parser.parseTraitDeclaration;
    pub const implDeclaration = trait_parser.parseImplDeclaration;
    pub const parseWhereClause = trait_parser.parseWhereClause;
    pub const parseTypeExpr = trait_parser.parseTypeExpr;
    
    // Closure parsing methods
    pub const parseClosureExpr = closure_parser.parseClosureExpr;
};
