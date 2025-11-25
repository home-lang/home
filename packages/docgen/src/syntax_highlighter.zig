const std = @import("std");

/// Syntax highlighter for code examples in documentation
///
/// Supports:
/// - Home language syntax
/// - Zig syntax
/// - Multiple output formats (HTML, ANSI, Markdown)
/// - Configurable color schemes
pub const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,
    language: Language,
    color_scheme: ColorScheme,

    pub const Language = enum {
        home,
        zig,
        c,
        javascript,
        markdown,
        plain,
    };

    pub const ColorScheme = enum {
        github_light,
        github_dark,
        monokai,
        solarized_light,
        solarized_dark,
    };

    pub const TokenType = enum {
        keyword,
        type,
        function_name,
        variable,
        number,
        string,
        comment,
        operator,
        punctuation,
        whitespace,
        unknown,
    };

    pub const Token = struct {
        type: TokenType,
        text: []const u8,
        start: usize,
        end: usize,
    };

    pub fn init(allocator: std.mem.Allocator, language: Language) SyntaxHighlighter {
        return .{
            .allocator = allocator,
            .language = language,
            .color_scheme = .github_light,
        };
    }

    /// Tokenize source code
    pub fn tokenize(self: *SyntaxHighlighter, source: []const u8) ![]Token {
        return switch (self.language) {
            .home, .zig => try self.tokenizeZigLike(source),
            .c => try self.tokenizeC(source),
            .javascript => try self.tokenizeJavaScript(source),
            .markdown => try self.tokenizeMarkdown(source),
            .plain => try self.tokenizePlain(source),
        };
    }

    fn tokenizeZigLike(self: *SyntaxHighlighter, source: []const u8) ![]Token {
        var tokens = std.ArrayList(Token).init(self.allocator);
        errdefer tokens.deinit();

        var i: usize = 0;
        while (i < source.len) {
            const start = i;

            // Whitespace
            if (std.ascii.isWhitespace(source[i])) {
                while (i < source.len and std.ascii.isWhitespace(source[i])) {
                    i += 1;
                }
                try tokens.append(.{
                    .type = .whitespace,
                    .text = source[start..i],
                    .start = start,
                    .end = i,
                });
                continue;
            }

            // Comments
            if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') {
                    i += 1;
                }
                try tokens.append(.{
                    .type = .comment,
                    .text = source[start..i],
                    .start = start,
                    .end = i,
                });
                continue;
            }

            // Strings
            if (source[i] == '"') {
                i += 1;
                while (i < source.len and source[i] != '"') {
                    if (source[i] == '\\' and i + 1 < source.len) {
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
                if (i < source.len) i += 1;
                try tokens.append(.{
                    .type = .string,
                    .text = source[start..i],
                    .start = start,
                    .end = i,
                });
                continue;
            }

            // Numbers
            if (std.ascii.isDigit(source[i])) {
                while (i < source.len and (std.ascii.isDigit(source[i]) or source[i] == '.' or source[i] == '_')) {
                    i += 1;
                }
                try tokens.append(.{
                    .type = .number,
                    .text = source[start..i],
                    .start = start,
                    .end = i,
                });
                continue;
            }

            // Identifiers and keywords
            if (std.ascii.isAlphabetic(source[i]) or source[i] == '_') {
                while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) {
                    i += 1;
                }
                const word = source[start..i];
                const token_type = self.classifyKeyword(word);
                try tokens.append(.{
                    .type = token_type,
                    .text = word,
                    .start = start,
                    .end = i,
                });
                continue;
            }

            // Operators and punctuation
            if (self.isOperatorChar(source[i])) {
                while (i < source.len and self.isOperatorChar(source[i])) {
                    i += 1;
                }
                try tokens.append(.{
                    .type = .operator,
                    .text = source[start..i],
                    .start = start,
                    .end = i,
                });
                continue;
            }

            // Everything else
            i += 1;
            try tokens.append(.{
                .type = .unknown,
                .text = source[start..i],
                .start = start,
                .end = i,
            });
        }

        return tokens.toOwnedSlice();
    }

    fn tokenizeC(self: *SyntaxHighlighter, source: []const u8) ![]Token {
        // Similar to Zig but with C keywords
        return try self.tokenizeZigLike(source);
    }

    fn tokenizeJavaScript(self: *SyntaxHighlighter, source: []const u8) ![]Token {
        // Similar to Zig but with JavaScript keywords
        return try self.tokenizeZigLike(source);
    }

    fn tokenizeMarkdown(self: *SyntaxHighlighter, source: []const u8) ![]Token {
        // Simplified markdown tokenization
        var tokens = std.ArrayList(Token).init(self.allocator);
        try tokens.append(.{
            .type = .unknown,
            .text = source,
            .start = 0,
            .end = source.len,
        });
        return tokens.toOwnedSlice();
    }

    fn tokenizePlain(self: *SyntaxHighlighter, source: []const u8) ![]Token {
        var tokens = std.ArrayList(Token).init(self.allocator);
        try tokens.append(.{
            .type = .unknown,
            .text = source,
            .start = 0,
            .end = source.len,
        });
        return tokens.toOwnedSlice();
    }

    fn classifyKeyword(self: *SyntaxHighlighter, word: []const u8) TokenType {
        _ = self;

        // Home/Zig keywords
        const keywords = [_][]const u8{
            "const",   "var",      "fn",       "pub",    "return",
            "if",      "else",     "while",    "for",    "break",
            "continue", "switch",  "case",     "defer",  "errdefer",
            "try",     "catch",    "struct",   "enum",   "union",
            "error",   "async",    "await",    "suspend", "resume",
            "import",  "export",   "comptime", "inline", "noinline",
            "let",     "mut",      "ref",      "move",   "borrow",
        };

        for (keywords) |kw| {
            if (std.mem.eql(u8, word, kw)) {
                return .keyword;
            }
        }

        // Types (uppercase start)
        if (word.len > 0 and std.ascii.isUpper(word[0])) {
            return .type;
        }

        return .variable;
    }

    fn isOperatorChar(self: *SyntaxHighlighter, c: u8) bool {
        _ = self;
        return switch (c) {
            '+', '-', '*', '/', '%', '=', '<', '>', '!',
            '&', '|', '^', '~', '?', ':', ';', ',', '.',
            '(', ')', '[', ']', '{', '}',
            => true,
            else => false,
        };
    }

    /// Convert tokens to HTML
    pub fn toHTML(self: *SyntaxHighlighter, tokens: []const Token) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        try buffer.appendSlice("<pre><code>");

        for (tokens) |token| {
            const css_class = self.getCSSClass(token.type);
            if (token.type != .whitespace) {
                try buffer.writer().print("<span class=\"{s}\">", .{css_class});
            }

            // Escape HTML
            for (token.text) |c| {
                switch (c) {
                    '<' => try buffer.appendSlice("&lt;"),
                    '>' => try buffer.appendSlice("&gt;"),
                    '&' => try buffer.appendSlice("&amp;"),
                    '"' => try buffer.appendSlice("&quot;"),
                    else => try buffer.append(c),
                }
            }

            if (token.type != .whitespace) {
                try buffer.appendSlice("</span>");
            }
        }

        try buffer.appendSlice("</code></pre>");

        return buffer.toOwnedSlice();
    }

    /// Convert tokens to ANSI colored text
    pub fn toANSI(self: *SyntaxHighlighter, tokens: []const Token) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        for (tokens) |token| {
            const ansi_code = self.getANSIColor(token.type);
            try buffer.writer().print("\x1b[{s}m", .{ansi_code});
            try buffer.appendSlice(token.text);
            try buffer.appendSlice("\x1b[0m");
        }

        return buffer.toOwnedSlice();
    }

    fn getCSSClass(self: *SyntaxHighlighter, token_type: TokenType) []const u8 {
        _ = self;
        return switch (token_type) {
            .keyword => "keyword",
            .type => "type",
            .function_name => "function",
            .variable => "variable",
            .number => "number",
            .string => "string",
            .comment => "comment",
            .operator => "operator",
            .punctuation => "punctuation",
            .whitespace => "whitespace",
            .unknown => "unknown",
        };
    }

    fn getANSIColor(self: *SyntaxHighlighter, token_type: TokenType) []const u8 {
        _ = self;
        return switch (token_type) {
            .keyword => "1;35", // Bold magenta
            .type => "1;36", // Bold cyan
            .function_name => "1;33", // Bold yellow
            .variable => "0;37", // White
            .number => "0;32", // Green
            .string => "0;31", // Red
            .comment => "2;37", // Dim white
            .operator => "1;37", // Bold white
            .punctuation => "0;37", // White
            .whitespace => "0;37", // White
            .unknown => "0;37", // White
        };
    }

    /// Generate CSS for syntax highlighting
    pub fn generateCSS(self: *SyntaxHighlighter) ![]u8 {
        const scheme = switch (self.color_scheme) {
            .github_light =>
                \\.keyword { color: #d73a49; font-weight: bold; }
                \\.type { color: #005cc5; }
                \\.function { color: #6f42c1; }
                \\.variable { color: #24292e; }
                \\.number { color: #005cc5; }
                \\.string { color: #032f62; }
                \\.comment { color: #6a737d; font-style: italic; }
                \\.operator { color: #d73a49; }
                \\.punctuation { color: #24292e; }
                \\
            ,
            .github_dark =>
                \\.keyword { color: #ff7b72; font-weight: bold; }
                \\.type { color: #79c0ff; }
                \\.function { color: #d2a8ff; }
                \\.variable { color: #c9d1d9; }
                \\.number { color: #79c0ff; }
                \\.string { color: #a5d6ff; }
                \\.comment { color: #8b949e; font-style: italic; }
                \\.operator { color: #ff7b72; }
                \\.punctuation { color: #c9d1d9; }
                \\
            ,
            .monokai =>
                \\.keyword { color: #f92672; font-weight: bold; }
                \\.type { color: #66d9ef; }
                \\.function { color: #a6e22e; }
                \\.variable { color: #f8f8f2; }
                \\.number { color: #ae81ff; }
                \\.string { color: #e6db74; }
                \\.comment { color: #75715e; font-style: italic; }
                \\.operator { color: #f92672; }
                \\.punctuation { color: #f8f8f2; }
                \\
            ,
            .solarized_light =>
                \\.keyword { color: #859900; font-weight: bold; }
                \\.type { color: #268bd2; }
                \\.function { color: #b58900; }
                \\.variable { color: #657b83; }
                \\.number { color: #2aa198; }
                \\.string { color: #2aa198; }
                \\.comment { color: #93a1a1; font-style: italic; }
                \\.operator { color: #859900; }
                \\.punctuation { color: #657b83; }
                \\
            ,
            .solarized_dark =>
                \\.keyword { color: #859900; font-weight: bold; }
                \\.type { color: #268bd2; }
                \\.function { color: #b58900; }
                \\.variable { color: #839496; }
                \\.number { color: #2aa198; }
                \\.string { color: #2aa198; }
                \\.comment { color: #586e75; font-style: italic; }
                \\.operator { color: #859900; }
                \\.punctuation { color: #839496; }
                \\
            ,
        };

        return try self.allocator.dupe(u8, scheme);
    }
};

/// Highlight code in place (for existing HTML)
pub const CodeBlockHighlighter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CodeBlockHighlighter {
        return .{ .allocator = allocator };
    }

    /// Process HTML and highlight all code blocks
    pub fn processHTML(self: *CodeBlockHighlighter, html: []const u8) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        var i: usize = 0;
        while (i < html.len) {
            // Look for <code> blocks
            if (std.mem.indexOf(u8, html[i..], "<code")) |offset| {
                // Copy everything before <code>
                try buffer.appendSlice(html[i .. i + offset]);
                i += offset;

                // Find closing </code>
                if (std.mem.indexOf(u8, html[i..], "</code>")) |end_offset| {
                    // Extract code content
                    const code_start = i;
                    const code_end = i + end_offset;

                    // Detect language from class attribute
                    const language = try self.detectLanguage(html[code_start..code_end]);

                    // Extract actual code (skip opening tag)
                    if (std.mem.indexOf(u8, html[code_start..code_end], ">")) |tag_end| {
                        const code = html[code_start + tag_end + 1 .. code_end];

                        // Highlight the code
                        var highlighter = SyntaxHighlighter.init(self.allocator, language);
                        const tokens = try highlighter.tokenize(code);
                        defer self.allocator.free(tokens);

                        const highlighted = try highlighter.toHTML(tokens);
                        defer self.allocator.free(highlighted);

                        try buffer.appendSlice(highlighted);
                    }

                    i = code_end + "</code>".len;
                } else {
                    try buffer.append(html[i]);
                    i += 1;
                }
            } else {
                // No more code blocks, copy rest
                try buffer.appendSlice(html[i..]);
                break;
            }
        }

        return buffer.toOwnedSlice();
    }

    fn detectLanguage(self: *CodeBlockHighlighter, tag: []const u8) !SyntaxHighlighter.Language {
        _ = self;

        if (std.mem.indexOf(u8, tag, "language-home")) |_| {
            return .home;
        }
        if (std.mem.indexOf(u8, tag, "language-zig")) |_| {
            return .zig;
        }
        if (std.mem.indexOf(u8, tag, "language-c")) |_| {
            return .c;
        }
        if (std.mem.indexOf(u8, tag, "language-javascript")) |_| {
            return .javascript;
        }

        return .plain;
    }
};
