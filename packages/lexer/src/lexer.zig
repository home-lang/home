const std = @import("std");
pub const Token = @import("token.zig").Token;
pub const TokenType = @import("token.zig").TokenType;
const keywords = @import("token.zig").keywords;

/// Lexer for the Home programming language.
///
/// The Lexer performs lexical analysis (tokenization) of Home source code,
/// converting raw text into a stream of tokens. It uses a single-pass
/// scanning algorithm with lookahead for multi-character operators.
///
/// Features:
/// - Single and multi-line comment handling (// and /* */)
/// - String literals with escape sequences (\n, \t, \xNN, \u{NNNN})
/// - Integer and floating-point number recognition
/// - Keyword recognition via compile-time hash map
/// - Accurate line and column tracking for error reporting
/// - Maximal munch for operators (e.g., "==" not "=", "=")
///
/// Example:
/// ```zig
/// var lexer = Lexer.init(allocator, "let x = 42;");
/// var tokens = try lexer.tokenize();
/// defer tokens.deinit();
/// ```
pub const Lexer = struct {
    /// The complete source code being lexed
    source: []const u8,
    /// Start position of current token being scanned
    start: usize,
    /// Current scanning position in source
    current: usize,
    /// Current line number (1-indexed)
    line: usize,
    /// Current column number (1-indexed)
    column: usize,
    /// Column where current token started
    start_column: usize,
    /// Memory allocator for token list
    allocator: std.mem.Allocator,
    /// Track if we're inside an interpolated string
    in_interpolation: bool,
    /// Track brace depth inside interpolation expressions
    interpolation_brace_depth: usize,

    /// Initialize a new lexer for Home source code
    ///
    /// Creates a lexer that will tokenize the provided source string.
    /// The lexer tracks line and column positions for error reporting.
    ///
    /// Parameters:
    ///   - allocator: Memory allocator for token list
    ///   - source: Home source code to tokenize
    ///
    /// Returns: Initialized Lexer ready to scan tokens
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .start = 0,
            .current = 0,
            .line = 1,
            .column = 1,
            .start_column = 1,
            .allocator = allocator,
            .in_interpolation = false,
            .interpolation_brace_depth = 0,
        };
    }

    /// Check if we've reached the end of the source.
    ///
    /// Returns: true if no more characters to scan, false otherwise
    fn isAtEnd(self: *Lexer) bool {
        return self.current >= self.source.len;
    }

    /// Advance to the next character and return the current one.
    ///
    /// This consumes the current character, incrementing both the position
    /// and column counter. Line tracking is handled separately in skipWhitespace.
    ///
    /// Returns: The character at the current position before advancing
    fn advance(self: *Lexer) u8 {
        const c = self.source[self.current];
        self.current += 1;
        self.column += 1;
        return c;
    }

    /// Peek at the current character without advancing.
    ///
    /// Returns: Current character, or 0 if at end of source
    fn peek(self: *Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    /// Peek at the next character (one position ahead) without advancing.
    ///
    /// Used for two-character lookahead when recognizing multi-char operators
    /// like "==", "->", and "/*".
    ///
    /// Returns: Character at current + 1, or 0 if beyond end of source
    fn peekNext(self: *Lexer) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    /// Conditional advance: consume next character if it matches expected.
    ///
    /// This implements "maximal munch" for multi-character operators.
    /// For example, when scanning '=', we use match('=') to check if
    /// it should be '==' instead of just '='.
    ///
    /// Parameters:
    ///   - expected: Character to match against
    ///
    /// Returns: true and advances if match, false and doesn't advance otherwise
    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        self.column += 1;
        return true;
    }

    /// Create a token from the currently scanned lexeme.
    ///
    /// Constructs a Token using the span from `start` to `current`,
    /// preserving the exact source text as the lexeme. The token's
    /// location uses the start position of the lexeme.
    ///
    /// Parameters:
    ///   - token_type: The type of token to create
    ///
    /// Returns: New Token with current lexeme and position
    fn makeToken(self: *Lexer, token_type: TokenType) Token {
        const lexeme = self.source[self.start..self.current];
        return Token.init(token_type, lexeme, self.line, self.start_column);
    }

    /// Skip whitespace and comments.
    ///
    /// Advances the lexer position past all whitespace characters, single-line
    /// comments (//), and multi-line comments (/* */). Updates line and column
    /// counters appropriately. Nested comments are not supported.
    ///
    /// This is called before scanning each token to ensure tokens don't
    /// include leading whitespace or comments.
    fn skipWhitespace(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => {
                    _ = self.advance();
                },
                '\n' => {
                    self.line += 1;
                    self.column = 0;
                    _ = self.advance();
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        // Check for doc comment (///)
                        if (self.current + 2 < self.source.len and self.source[self.current + 2] == '/') {
                            // This is a doc comment - don't skip it, return to scanToken
                            return;
                        }
                        // Skip single-line comment //
                        while (self.peek() != '\n' and !self.isAtEnd()) {
                            _ = self.advance();
                        }
                    } else if (self.peekNext() == '*') {
                        // Skip multi-line comment /* */
                        _ = self.advance(); // consume /
                        _ = self.advance(); // consume *

                        while (!self.isAtEnd()) {
                            if (self.peek() == '*' and self.peekNext() == '/') {
                                _ = self.advance(); // consume *
                                _ = self.advance(); // consume /
                                break;
                            }
                            if (self.peek() == '\n') {
                                self.line += 1;
                                self.column = 0;
                            }
                            _ = self.advance();
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    /// Lex a string literal with escape sequence support and interpolation.
    ///
    /// Scans a double-quoted string literal, handling:
    /// - Escape sequences: \n \t \r \" \\ \' \0
    /// - Hex escapes: \xNN (two hex digits)
    /// - Unicode escapes: \u{NNNN} (1-6 hex digits in braces)
    /// - Interpolation: {expression} for embedding expressions
    ///
    /// String interpolation produces three token types:
    /// - StringInterpolationStart: "text{ (for the first part)
    /// - StringInterpolationMid: }text{ (for middle parts)
    /// - StringInterpolationEnd: }text" (for the final part)
    ///
    /// Returns: String token or interpolation token, or Invalid token on error
    fn string(self: *Lexer) Token {
        // Check for triple-quoted multi-line string (""")
        // At this point, we've already consumed the first quote, so check for two more
        if (self.peek() == '"' and self.peekNext() == '"') {
            // Consume the two additional quotes
            _ = self.advance();
            _ = self.advance();
            return self.tripleQuotedString();
        }

        var has_interpolation = false;

        // First pass: scan to detect if string has interpolation
        // Look for ${...} syntax
        var temp_pos = self.current;
        while (temp_pos < self.source.len) {
            const c = self.source[temp_pos];
            if (c == '"') break;
            if (c == '\\') {
                temp_pos += 1;
                if (temp_pos < self.source.len) {
                    temp_pos += 1;
                }
                continue;
            }
            // Check for ${ interpolation sequence
            if (c == '$' and temp_pos + 1 < self.source.len and self.source[temp_pos + 1] == '{') {
                has_interpolation = true;
                break;
            }
            temp_pos += 1;
        }

        // If no interpolation, use simple string parsing
        if (!has_interpolation) {
            return self.simpleString();
        }

        // Handle interpolated string
        return self.interpolatedString();
    }

    /// Lex a triple-quoted multi-line string (""" ... """)
    /// These strings preserve all content literally including newlines.
    /// No escape sequence processing is done.
    fn tripleQuotedString(self: *Lexer) Token {
        // Scan until we find closing """
        while (!self.isAtEnd()) {
            if (self.peek() == '"' and self.peekNext() == '"') {
                // Check for third quote
                if (self.current + 2 < self.source.len and self.source[self.current + 2] == '"') {
                    // Found closing """
                    _ = self.advance(); // first "
                    _ = self.advance(); // second "
                    _ = self.advance(); // third "
                    return self.makeToken(.String);
                }
            }
            if (self.peek() == '\n') {
                self.line += 1;
                self.column = 0;
            }
            _ = self.advance();
        }

        // Unterminated triple-quoted string
        return self.makeToken(.Invalid);
    }

    /// Lex a simple string without interpolation
    fn simpleString(self: *Lexer) Token {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\\') {
                _ = self.advance(); // consume backslash
                if (self.isAtEnd()) {
                    return self.makeToken(.Invalid);
                }

                const escape_char = self.peek();
                switch (escape_char) {
                    'n', 't', 'r', '"', '\\', '\'', '0', '{' => {
                        _ = self.advance();
                    },
                    'x' => {
                        _ = self.advance();
                        if (!std.ascii.isHex(self.peek())) {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();
                        if (!std.ascii.isHex(self.peek())) {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();
                    },
                    'u' => {
                        _ = self.advance();
                        if (self.peek() != '{') {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();

                        var hex_count: usize = 0;
                        while (std.ascii.isHex(self.peek()) and hex_count < 6) : (hex_count += 1) {
                            _ = self.advance();
                        }

                        if (hex_count == 0 or self.peek() != '}') {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();
                    },
                    else => {
                        return self.makeToken(.Invalid);
                    },
                }
            } else {
                if (self.peek() == '\n') {
                    self.line += 1;
                    self.column = 0;
                }
                _ = self.advance();
            }
        }

        if (self.isAtEnd()) {
            return self.makeToken(.Invalid);
        }

        _ = self.advance(); // closing quote
        return self.makeToken(.String);
    }

    /// Lex a character literal ('a', '\n', '\x41', etc.)
    fn charLiteral(self: *Lexer) Token {
        if (self.isAtEnd()) {
            return self.makeToken(.Invalid);
        }

        // Check for escape sequence
        if (self.peek() == '\\') {
            _ = self.advance(); // consume backslash
            if (self.isAtEnd()) {
                return self.makeToken(.Invalid);
            }

            const escape_char = self.peek();
            switch (escape_char) {
                'n', 't', 'r', '\'', '"', '\\', '0' => {
                    _ = self.advance();
                },
                'x' => {
                    _ = self.advance();
                    if (!std.ascii.isHex(self.peek())) {
                        return self.makeToken(.Invalid);
                    }
                    _ = self.advance();
                    if (!std.ascii.isHex(self.peek())) {
                        return self.makeToken(.Invalid);
                    }
                    _ = self.advance();
                },
                'u' => {
                    _ = self.advance();
                    if (self.peek() != '{') {
                        return self.makeToken(.Invalid);
                    }
                    _ = self.advance();

                    var hex_count: usize = 0;
                    while (std.ascii.isHex(self.peek()) and hex_count < 6) : (hex_count += 1) {
                        _ = self.advance();
                    }

                    if (hex_count == 0 or self.peek() != '}') {
                        return self.makeToken(.Invalid);
                    }
                    _ = self.advance();
                },
                else => {
                    return self.makeToken(.Invalid);
                },
            }
        } else {
            // Regular character
            _ = self.advance();
        }

        // Expect closing quote
        if (self.peek() != '\'') {
            return self.makeToken(.Invalid);
        }
        _ = self.advance(); // closing quote

        return self.makeToken(.Char);
    }

    /// Lex an interpolated string part
    /// Looks for ${...} syntax for interpolation
    fn interpolatedString(self: *Lexer) Token {
        // Scan until we hit ${ or "
        while (!self.isAtEnd()) {
            // Check for ${ interpolation
            if (self.peek() == '$' and self.peekNext() == '{') {
                break;
            }
            // Check for end of string
            if (self.peek() == '"') {
                break;
            }
            // Handle escape sequences
            if (self.peek() == '\\') {
                _ = self.advance(); // consume backslash
                if (self.isAtEnd()) {
                    return self.makeToken(.Invalid);
                }

                const escape_char = self.peek();
                switch (escape_char) {
                    'n', 't', 'r', '"', '\\', '\'', '0', '$' => {
                        _ = self.advance();
                    },
                    'x' => {
                        _ = self.advance();
                        if (!std.ascii.isHex(self.peek())) {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();
                        if (!std.ascii.isHex(self.peek())) {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();
                    },
                    'u' => {
                        _ = self.advance();
                        if (self.peek() != '{') {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();

                        var hex_count: usize = 0;
                        while (std.ascii.isHex(self.peek()) and hex_count < 6) : (hex_count += 1) {
                            _ = self.advance();
                        }

                        if (hex_count == 0 or self.peek() != '}') {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();
                    },
                    else => {
                        return self.makeToken(.Invalid);
                    },
                }
            } else {
                if (self.peek() == '\n') {
                    self.line += 1;
                    self.column = 0;
                }
                _ = self.advance();
            }
        }

        if (self.isAtEnd()) {
            return self.makeToken(.Invalid);
        }

        if (self.peek() == '$' and self.peekNext() == '{') {
            _ = self.advance(); // consume $
            _ = self.advance(); // consume {
            self.in_interpolation = true;
            self.interpolation_brace_depth = 1;
            return self.makeToken(.StringInterpolationStart);
        } else {
            // Must be closing "
            _ = self.advance();
            return self.makeToken(.String);
        }
    }

    /// Continue scanning an interpolated string after an expression
    /// Looks for ${...} syntax for interpolation
    fn continueInterpolatedString(self: *Lexer) Token {
        // The } that closes the interpolation expression was already consumed
        // Update start to skip the } for the token lexeme
        self.start = self.current;

        // Scan until next ${ or closing "
        while (!self.isAtEnd()) {
            // Check for ${ interpolation
            if (self.peek() == '$' and self.peekNext() == '{') {
                break;
            }
            // Check for end of string
            if (self.peek() == '"') {
                break;
            }
            // Handle escape sequences
            if (self.peek() == '\\') {
                _ = self.advance();
                if (self.isAtEnd()) {
                    return self.makeToken(.Invalid);
                }

                const escape_char = self.peek();
                switch (escape_char) {
                    'n', 't', 'r', '"', '\\', '\'', '0', '$' => {
                        _ = self.advance();
                    },
                    'x' => {
                        _ = self.advance();
                        if (!std.ascii.isHex(self.peek())) {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();
                        if (!std.ascii.isHex(self.peek())) {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();
                    },
                    'u' => {
                        _ = self.advance();
                        if (self.peek() != '{') {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();

                        var hex_count: usize = 0;
                        while (std.ascii.isHex(self.peek()) and hex_count < 6) : (hex_count += 1) {
                            _ = self.advance();
                        }

                        if (hex_count == 0 or self.peek() != '}') {
                            return self.makeToken(.Invalid);
                        }
                        _ = self.advance();
                    },
                    else => {
                        return self.makeToken(.Invalid);
                    },
                }
            } else {
                if (self.peek() == '\n') {
                    self.line += 1;
                    self.column = 0;
                }
                _ = self.advance();
            }
        }

        if (self.isAtEnd()) {
            return self.makeToken(.Invalid);
        }

        if (self.peek() == '$' and self.peekNext() == '{') {
            _ = self.advance(); // consume $
            _ = self.advance(); // consume {
            self.interpolation_brace_depth = 1;
            return self.makeToken(.StringInterpolationMid);
        } else {
            // Closing "
            _ = self.advance();
            self.in_interpolation = false;
            return self.makeToken(.StringInterpolationEnd);
        }
    }

    /// Lex a documentation comment (/// ...).
    ///
    /// Doc comments start with /// and continue to end of line.
    /// The lexeme includes the full /// prefix and content.
    ///
    /// Returns: DocComment token
    fn docComment(self: *Lexer) Token {
        // We're at the first / after /, so advance past // to get to third /
        _ = self.advance(); // second /
        _ = self.advance(); // third /

        // Scan to end of line - include everything in lexeme
        while (self.peek() != '\n' and !self.isAtEnd()) {
            _ = self.advance();
        }

        // makeToken will use self.source[self.start..self.current] which includes ///
        return self.makeToken(.DocComment);
    }

    /// Lex a raw string literal (r"..." or r#"..."#).
    ///
    /// Raw strings don't process escape sequences. The 'r' prefix has already
    /// been consumed. Supports r"string" and r#"string"# (with any number of #).
    ///
    /// Returns: String token (raw strings use same token type)
    fn rawString(self: *Lexer) Token {
        // Count '#' characters
        var hash_count: usize = 0;
        while (self.peek() == '#') : (hash_count += 1) {
            _ = self.advance();
        }

        // Expect opening quote
        if (self.peek() != '"') {
            return self.makeToken(.Invalid);
        }
        _ = self.advance(); // consume opening "

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
                    _ = self.advance(); // consume closing "
                    for (0..hash_count) |_| {
                        _ = self.advance(); // consume #'s
                    }
                    return self.makeToken(.String);
                }
            }

            if (self.peek() == '\n') {
                self.line += 1;
                self.column = 0;
            }
            _ = self.advance();
        }

        // Unterminated raw string
        return self.makeToken(.Invalid);
    }

    /// Check for and consume type suffix (i8, i16, i32, i64, i128, u8, u16, u32, u64, u128, f32, f64)
    fn parseTypeSuffix(self: *Lexer) void {
        // Check for type suffix starting with 'i', 'u', or 'f'
        const first = self.peek();
        if (first != 'i' and first != 'u' and first != 'f') return;

        // Look ahead to see if this looks like a type suffix (letter + digit)
        if (self.current + 1 >= self.source.len) return;
        const second = self.source[self.current + 1];
        if (!std.ascii.isDigit(second)) return;

        const saved_pos = self.current;
        const saved_col = self.column;

        _ = self.advance(); // consume 'i', 'u', or 'f'

        // Parse the size: 8, 16, 32, 64, 128
        var has_digits = false;
        while (std.ascii.isDigit(self.peek())) {
            has_digits = true;
            _ = self.advance();
        }

        // If we didn't find valid digits, or the next char is alphanumeric (part of identifier),
        // this isn't a type suffix - restore position
        if (!has_digits or std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
            self.current = saved_pos;
            self.column = saved_col;
        }
    }

    /// Lex a numeric literal (integer or float).
    ///
    /// Supports:
    /// - Decimal: 123, 3.14
    /// - Binary: 0b1010
    /// - Hexadecimal: 0xFF
    /// - Octal: 0o755
    /// - Underscores for readability: 1_000_000
    /// - Type suffixes: 42i32, 100u64, 3.14f32
    ///
    /// Returns: Integer or Float token
    fn number(self: *Lexer) Token {
        // Check for base prefix (binary, hex, octal)
        // Note: We're called after advance() consumed the first digit,
        // so check source[start] for the '0' prefix
        if (self.source[self.start] == '0') {
            const next = self.peek();
            if (next == 'b' or next == 'B') {
                return self.binaryNumber();
            } else if (next == 'x' or next == 'X') {
                return self.hexNumber();
            } else if (next == 'o' or next == 'O') {
                return self.octalNumber();
            }
        }

        // Decimal number (with optional underscores)
        while (std.ascii.isDigit(self.peek()) or self.peek() == '_') {
            if (self.peek() == '_') {
                _ = self.advance(); // Skip underscore
                continue;
            }
            _ = self.advance();
        }

        // Check for decimal point
        if (self.peek() == '.' and std.ascii.isDigit(self.peekNext())) {
            _ = self.advance(); // Consume '.'

            while (std.ascii.isDigit(self.peek()) or self.peek() == '_') {
                if (self.peek() == '_') {
                    _ = self.advance();
                    continue;
                }
                _ = self.advance();
            }

            // Check for exponent (scientific notation)
            if (self.peek() == 'e' or self.peek() == 'E') {
                _ = self.advance(); // Consume 'e' or 'E'

                // Optional +/- sign
                if (self.peek() == '+' or self.peek() == '-') {
                    _ = self.advance();
                }

                // Exponent digits (required)
                if (!std.ascii.isDigit(self.peek())) {
                    // Invalid scientific notation - but we already consumed the 'e',
                    // so just continue and let parser deal with it
                } else {
                    while (std.ascii.isDigit(self.peek()) or self.peek() == '_') {
                        if (self.peek() == '_') {
                            _ = self.advance();
                            continue;
                        }
                        _ = self.advance();
                    }
                }
            }

            // Check for float type suffix (f32, f64)
            self.parseTypeSuffix();

            return self.makeToken(.Float);
        }

        // Check for scientific notation in integer (e.g., 1e10)
        if (self.peek() == 'e' or self.peek() == 'E') {
            _ = self.advance(); // Consume 'e' or 'E'

            // Optional +/- sign
            if (self.peek() == '+' or self.peek() == '-') {
                _ = self.advance();
            }

            // Exponent digits (required)
            if (std.ascii.isDigit(self.peek())) {
                while (std.ascii.isDigit(self.peek()) or self.peek() == '_') {
                    if (self.peek() == '_') {
                        _ = self.advance();
                        continue;
                    }
                    _ = self.advance();
                }

                // Check for float type suffix (f32, f64)
                self.parseTypeSuffix();

                return self.makeToken(.Float);
            }
        }

        // Check for integer type suffix
        self.parseTypeSuffix();

        return self.makeToken(.Integer);
    }

    /// Lex a binary number literal (0b prefix).
    fn binaryNumber(self: *Lexer) Token {
        // Note: '0' was already consumed by scanToken() calling advance()
        _ = self.advance(); // 'b' or 'B'

        var has_digits = false;
        while (self.peek() == '0' or self.peek() == '1' or self.peek() == '_') {
            if (self.peek() == '_') {
                _ = self.advance();
                continue;
            }
            has_digits = true;
            _ = self.advance();
        }

        if (!has_digits) {
            return self.makeToken(.Invalid);
        }

        // Check for integer type suffix
        self.parseTypeSuffix();

        return self.makeToken(.Integer);
    }

    /// Lex a hexadecimal number literal (0x prefix).
    fn hexNumber(self: *Lexer) Token {
        // Note: '0' was already consumed by scanToken() calling advance()
        _ = self.advance(); // 'x' or 'X'

        var has_digits = false;
        while (true) {
            const c = self.peek();
            if (c == '_') {
                _ = self.advance();
                continue;
            }

            if (!std.ascii.isHex(c)) break;

            // Check if this might be a type suffix BEFORE consuming the char
            // (i,u,f are valid hex digits but might start a type suffix)
            if ((c == 'i' or c == 'u' or c == 'f') and self.current + 1 < self.source.len) {
                const next = self.source[self.current + 1];
                if (std.ascii.isDigit(next)) {
                    // This is likely a type suffix, stop parsing hex digits
                    break;
                }
            }

            has_digits = true;
            _ = self.advance();
        }

        if (!has_digits) {
            return self.makeToken(.Invalid);
        }

        // Check for integer type suffix
        self.parseTypeSuffix();

        return self.makeToken(.Integer);
    }

    /// Lex an octal number literal (0o prefix).
    fn octalNumber(self: *Lexer) Token {
        // Note: '0' was already consumed by scanToken() calling advance()
        _ = self.advance(); // 'o' or 'O'

        var has_digits = false;
        while (self.peek() >= '0' and self.peek() <= '7' or self.peek() == '_') {
            if (self.peek() == '_') {
                _ = self.advance();
                continue;
            }
            has_digits = true;
            _ = self.advance();
        }

        if (!has_digits) {
            return self.makeToken(.Invalid);
        }

        // Check for integer type suffix
        self.parseTypeSuffix();

        return self.makeToken(.Integer);
    }

    /// Lex an identifier or keyword.
    ///
    /// Scans a sequence of alphanumeric characters and underscores,
    /// then checks if the result is a reserved keyword. Identifiers
    /// must start with a letter or underscore (enforced by caller).
    ///
    /// Examples:
    /// - "foo" -> Identifier
    /// - "_test" -> Identifier
    /// - "variable123" -> Identifier
    /// - "fn" -> Fn (keyword)
    /// - "let" -> Let (keyword)
    ///
    /// Returns: Keyword token if matched, otherwise Identifier token
    fn identifier(self: *Lexer) Token {
        while (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
            _ = self.advance();
        }

        const text = self.source[self.start..self.current];
        const token_type = keywords.get(text) orelse .Identifier;

        return self.makeToken(token_type);
    }

    /// Scan a label identifier (e.g., 'outer for labeled loops)
    /// The leading ' has already been consumed
    fn labelIdentifier(self: *Lexer) Token {
        // Scan the rest of the identifier (after the ')
        while (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
            _ = self.advance();
        }

        // Return as an identifier token (including the leading ')
        return self.makeToken(.Identifier);
    }

    /// Scan and return the next token from the source
    ///
    /// This is the main lexing function that recognizes and returns
    /// one token at a time. It handles:
    /// - Keywords and identifiers
    /// - Literals (strings, numbers, booleans)
    /// - Operators and punctuation
    /// - Comments (skipped automatically)
    ///
    /// Returns: The next Token in the source, or EOF if at end
    pub fn scanToken(self: *Lexer) Token {
        self.skipWhitespace();

        self.start = self.current;
        self.start_column = self.column;

        if (self.isAtEnd()) {
            return self.makeToken(.Eof);
        }

        const c = self.advance();

        // Identifiers and keywords
        if (std.ascii.isAlphabetic(c) or c == '_') {
            // Check for raw string prefix 'r'
            if (c == 'r' and (self.peek() == '"' or self.peek() == '#')) {
                return self.rawString();
            }
            return self.identifier();
        }

        // Numbers
        if (std.ascii.isDigit(c)) {
            return self.number();
        }

        // String literals
        if (c == '"') {
            return self.string();
        }

        // Character literals or label identifiers (like 'outer for labeled loops)
        if (c == '\'') {
            // Check if this is a label (like 'outer) or char literal (like 'a')
            // Labels: ' followed by alphabetic/underscore, then more identifier chars
            // Char literals: ' followed by char (or escape), then '
            const next = self.peek();
            if (std.ascii.isAlphabetic(next) or next == '_') {
                // Could be label or char literal - check if char after next is '
                const after_next = self.peekNext();
                if (after_next != '\'') {
                    // It's a label like 'outer - scan as identifier (including the ')
                    return self.labelIdentifier();
                }
            }
            return self.charLiteral();
        }

        // Operators and punctuation
        return switch (c) {
            '(' => self.makeToken(.LeftParen),
            ')' => self.makeToken(.RightParen),
            '{' => blk: {
                if (self.in_interpolation) {
                    self.interpolation_brace_depth += 1;
                }
                break :blk self.makeToken(.LeftBrace);
            },
            '}' => blk: {
                if (self.in_interpolation) {
                    self.interpolation_brace_depth -= 1;
                    if (self.interpolation_brace_depth == 0) {
                        // End of interpolation expression, continue string
                        return self.continueInterpolatedString();
                    }
                }
                break :blk self.makeToken(.RightBrace);
            },
            '[' => self.makeToken(.LeftBracket),
            ']' => self.makeToken(.RightBracket),
            ',' => self.makeToken(.Comma),
            '.' => if (self.match('.'))
                (if (self.match('.'))
                    self.makeToken(.DotDotDot)
                else if (self.match('='))
                    self.makeToken(.DotDotEqual)
                else
                    self.makeToken(.DotDot))
            else self.makeToken(.Dot),
            ';' => self.makeToken(.Semicolon),
            ':' => if (self.match(':')) self.makeToken(.ColonColon) else self.makeToken(.Colon),
            '?' => if (self.match('.'))
                self.makeToken(.QuestionDot)
            else if (self.match('?'))
                self.makeToken(.QuestionQuestion)
            else if (self.match(':'))
                self.makeToken(.QuestionColon)
            else if (self.match('['))
                self.makeToken(.QuestionBracket)
            else
                self.makeToken(.Question),
            '@' => self.makeToken(.At),
            '+' => if (self.match('=')) self.makeToken(.PlusEqual) else if (self.match('!')) self.makeToken(.PlusBang) else if (self.match('?')) self.makeToken(.PlusQuestion) else if (self.match('|')) self.makeToken(.PlusPipe) else self.makeToken(.Plus),
            '-' => if (self.match('>')) self.makeToken(.Arrow) else if (self.match('=')) self.makeToken(.MinusEqual) else if (self.match('!')) self.makeToken(.MinusBang) else if (self.match('?')) self.makeToken(.MinusQuestion) else if (self.match('|')) self.makeToken(.MinusPipe) else self.makeToken(.Minus),
            '*' => if (self.match('*')) self.makeToken(.StarStar) else if (self.match('=')) self.makeToken(.StarEqual) else if (self.match('!')) self.makeToken(.StarBang) else if (self.match('?')) self.makeToken(.StarQuestion) else if (self.match('|')) self.makeToken(.StarPipe) else self.makeToken(.Star),
            '/' => blk: {
                // Check for doc comment ///
                if (self.peek() == '/' and self.peekNext() == '/') {
                    break :blk self.docComment();
                }
                if (self.match('=')) break :blk self.makeToken(.SlashEqual);
                if (self.match('!')) break :blk self.makeToken(.SlashBang);
                if (self.match('?')) break :blk self.makeToken(.SlashQuestion);
                break :blk self.makeToken(.Slash);
            },
            '%' => if (self.match('=')) self.makeToken(.PercentEqual) else self.makeToken(.Percent),
            '!' => if (self.match('=')) self.makeToken(.BangEqual) else self.makeToken(.Bang),
            '=' => if (self.match('=')) self.makeToken(.EqualEqual) else if (self.match('>')) self.makeToken(.FatArrow) else self.makeToken(.Equal),
            '>' => if (self.match('>')) self.makeToken(.RightShift) else if (self.match('=')) self.makeToken(.GreaterEqual) else self.makeToken(.Greater),
            '<' => if (self.match('<')) self.makeToken(.LeftShift) else if (self.match('=')) self.makeToken(.LessEqual) else self.makeToken(.Less),
            '&' => if (self.match('&')) self.makeToken(.AmpersandAmpersand) else self.makeToken(.Ampersand),
            '|' => if (self.match('>'))
                self.makeToken(.PipeGreater)
            else if (self.match('|'))
                self.makeToken(.PipePipe)
            else
                self.makeToken(.Pipe),
            '^' => self.makeToken(.Caret),
            '~' => if (self.match('/')) self.makeToken(.TildeSlash) else self.makeToken(.Tilde),
            else => self.makeToken(.Invalid),
        };
    }

    /// Tokenize the entire source code and return all tokens
    ///
    /// Scans the complete source string and returns an ArrayList
    /// containing all tokens including the final EOF token.
    ///
    /// This is the primary entry point for lexical analysis.
    /// Use this when you need all tokens at once (e.g., for parsing).
    ///
    /// Returns: ArrayList of all tokens found in the source
    /// Errors: OutOfMemory if allocation fails
    pub fn tokenize(self: *Lexer) !std.ArrayList(Token) {
        var tokens = std.ArrayList(Token){ .items = &.{}, .capacity = 0 };

        while (true) {
            const token = self.scanToken();
            try tokens.append(self.allocator, token);
            if (token.type == .Eof) break;
        }

        return tokens;
    }
};

test "lexer: single tokens" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "(){}[];,.");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 10), tokens.items.len); // 9 tokens + EOF
    try testing.expectEqual(TokenType.LeftParen, tokens.items[0].type);
    try testing.expectEqual(TokenType.RightParen, tokens.items[1].type);
    try testing.expectEqual(TokenType.LeftBrace, tokens.items[2].type);
    try testing.expectEqual(TokenType.RightBrace, tokens.items[3].type);
    try testing.expectEqual(TokenType.LeftBracket, tokens.items[4].type);
    try testing.expectEqual(TokenType.RightBracket, tokens.items[5].type);
    try testing.expectEqual(TokenType.Semicolon, tokens.items[6].type);
    try testing.expectEqual(TokenType.Comma, tokens.items[7].type);
    try testing.expectEqual(TokenType.Dot, tokens.items[8].type);
}

test "lexer: operators" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "+ += - -= * *= / /= == != < <= > >=");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.Plus, tokens.items[0].type);
    try testing.expectEqual(TokenType.PlusEqual, tokens.items[1].type);
    try testing.expectEqual(TokenType.Minus, tokens.items[2].type);
    try testing.expectEqual(TokenType.MinusEqual, tokens.items[3].type);
    try testing.expectEqual(TokenType.Star, tokens.items[4].type);
    try testing.expectEqual(TokenType.StarEqual, tokens.items[5].type);
}

test "lexer: integers" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "123 456 0");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("123", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Integer, tokens.items[1].type);
    try testing.expectEqualStrings("456", tokens.items[1].lexeme);
}

test "lexer: floats" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "3.14 0.5 99.99");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.Float, tokens.items[0].type);
    try testing.expectEqualStrings("3.14", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Float, tokens.items[1].type);
    try testing.expectEqualStrings("0.5", tokens.items[1].lexeme);
}

test "lexer: strings" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "\"hello\" \"world\"");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqualStrings("\"hello\"", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.String, tokens.items[1].type);
    try testing.expectEqualStrings("\"world\"", tokens.items[1].lexeme);
}

test "lexer: identifiers" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "foo bar _test variable123");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.Identifier, tokens.items[0].type);
    try testing.expectEqualStrings("foo", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqualStrings("bar", tokens.items[1].lexeme);
}

test "lexer: keywords" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "fn let const if else return");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.Fn, tokens.items[0].type);
    try testing.expectEqual(TokenType.Let, tokens.items[1].type);
    try testing.expectEqual(TokenType.Const, tokens.items[2].type);
    try testing.expectEqual(TokenType.If, tokens.items[3].type);
    try testing.expectEqual(TokenType.Else, tokens.items[4].type);
    try testing.expectEqual(TokenType.Return, tokens.items[5].type);
}

test "lexer: comments" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "foo // this is a comment\nbar");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), tokens.items.len); // foo, bar, EOF
    try testing.expectEqual(TokenType.Identifier, tokens.items[0].type);
    try testing.expectEqualStrings("foo", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqualStrings("bar", tokens.items[1].lexeme);
}

test "lexer: integer type suffixes" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "42i32 100u64 0xFFu8 0b1010i16");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("42i32", tokens.items[0].lexeme);

    try testing.expectEqual(TokenType.Integer, tokens.items[1].type);
    try testing.expectEqualStrings("100u64", tokens.items[1].lexeme);

    try testing.expectEqual(TokenType.Integer, tokens.items[2].type);
    try testing.expectEqualStrings("0xFFu8", tokens.items[2].lexeme);

    try testing.expectEqual(TokenType.Integer, tokens.items[3].type);
    try testing.expectEqualStrings("0b1010i16", tokens.items[3].lexeme);
}

test "lexer: float type suffixes" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "3.14f32 2.5f64");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.Float, tokens.items[0].type);
    try testing.expectEqualStrings("3.14f32", tokens.items[0].lexeme);

    try testing.expectEqual(TokenType.Float, tokens.items[1].type);
    try testing.expectEqualStrings("2.5f64", tokens.items[1].lexeme);
}

test "lexer: null keyword" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "null");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), tokens.items.len); // null, EOF
    try testing.expectEqual(TokenType.Null, tokens.items[0].type);
    try testing.expectEqualStrings("null", tokens.items[0].lexeme);
}

test "lexer: and/or keywords" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "and or");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), tokens.items.len); // and, or, EOF
    try testing.expectEqual(TokenType.And, tokens.items[0].type);
    try testing.expectEqual(TokenType.Or, tokens.items[1].type);
}

test "lexer: && and || operators" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "&& ||");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), tokens.items.len);
    try testing.expectEqual(TokenType.AmpersandAmpersand, tokens.items[0].type);
    try testing.expectEqual(TokenType.PipePipe, tokens.items[1].type);
}

test "lexer: :: token" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "::");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), tokens.items.len);
    try testing.expectEqual(TokenType.ColonColon, tokens.items[0].type);
}

test "lexer: range operators" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, ".. ..=");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), tokens.items.len);
    try testing.expectEqual(TokenType.DotDot, tokens.items[0].type);
    try testing.expectEqual(TokenType.DotDotEqual, tokens.items[1].type);
}

test "lexer: bitwise operators" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "& | ^ ~ << >>");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.Ampersand, tokens.items[0].type);
    try testing.expectEqual(TokenType.Pipe, tokens.items[1].type);
    try testing.expectEqual(TokenType.Caret, tokens.items[2].type);
    try testing.expectEqual(TokenType.Tilde, tokens.items[3].type);
    try testing.expectEqual(TokenType.LeftShift, tokens.items[4].type);
    try testing.expectEqual(TokenType.RightShift, tokens.items[5].type);
}

test "lexer: comparison operators" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "== != < <= > >=");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.EqualEqual, tokens.items[0].type);
    try testing.expectEqual(TokenType.BangEqual, tokens.items[1].type);
    try testing.expectEqual(TokenType.Less, tokens.items[2].type);
    try testing.expectEqual(TokenType.LessEqual, tokens.items[3].type);
    try testing.expectEqual(TokenType.Greater, tokens.items[4].type);
    try testing.expectEqual(TokenType.GreaterEqual, tokens.items[5].type);
}

test "lexer: compound assignment operators" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "+= -= *= /= %=");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.PlusEqual, tokens.items[0].type);
    try testing.expectEqual(TokenType.MinusEqual, tokens.items[1].type);
    try testing.expectEqual(TokenType.StarEqual, tokens.items[2].type);
    try testing.expectEqual(TokenType.SlashEqual, tokens.items[3].type);
    try testing.expectEqual(TokenType.PercentEqual, tokens.items[4].type);
}

test "lexer: fat arrow" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "=>");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), tokens.items.len);
    try testing.expectEqual(TokenType.FatArrow, tokens.items[0].type);
}

test "lexer: more keywords" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "struct enum impl trait match while for in");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.Struct, tokens.items[0].type);
    try testing.expectEqual(TokenType.Enum, tokens.items[1].type);
    try testing.expectEqual(TokenType.Impl, tokens.items[2].type);
    try testing.expectEqual(TokenType.Trait, tokens.items[3].type);
    try testing.expectEqual(TokenType.Match, tokens.items[4].type);
    try testing.expectEqual(TokenType.While, tokens.items[5].type);
    try testing.expectEqual(TokenType.For, tokens.items[6].type);
    try testing.expectEqual(TokenType.In, tokens.items[7].type);
}

test "lexer: boolean literals" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "true false");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(TokenType.True, tokens.items[0].type);
    try testing.expectEqual(TokenType.False, tokens.items[1].type);
}
