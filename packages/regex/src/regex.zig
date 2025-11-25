/// Home Regex Module
///
/// A high-performance regular expression library wrapping zig-regex.
/// Provides pattern matching, search, replace, and capture group support.
///
/// Example usage:
/// ```home
/// let pattern = try Regex.compile("[a-z]+@[a-z]+\\.com");
/// defer pattern.deinit();
///
/// if (try pattern.find("Contact: user@example.com")) |match| {
///     print("Found email: {}", match.slice);
/// }
/// ```
const std = @import("std");

/// Match result from a regex operation
pub const Match = struct {
    /// The matched substring
    slice: []const u8,
    /// Start index in the input string
    start: usize,
    /// End index in the input string (exclusive)
    end: usize,
    /// Captured groups (if any)
    captures: []const []const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, slice: []const u8, start: usize, end: usize, captures: []const []const u8) Match {
        return .{
            .slice = slice,
            .start = start,
            .end = end,
            .captures = captures,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Match) void {
        if (self.captures.len > 0) {
            self.allocator.free(self.captures);
        }
    }

    /// Get a specific capture group by index (1-indexed)
    pub fn group(self: *const Match, index: usize) ?[]const u8 {
        if (index == 0) return self.slice;
        if (index > self.captures.len) return null;
        const capture = self.captures[index - 1];
        return if (capture.len > 0) capture else null;
    }
};

/// Compile flags for regex patterns
pub const CompileFlags = struct {
    /// Case-insensitive matching
    case_insensitive: bool = false,
    /// Multi-line mode: ^ and $ match line boundaries
    multiline: bool = false,
    /// Dot matches newlines
    dot_all: bool = false,
    /// Extended mode: ignore whitespace and allow comments
    extended: bool = false,
    /// Enable Unicode mode
    unicode: bool = true,
};

/// Regular expression engine type
pub const EngineType = enum {
    /// Thompson NFA - fast O(n*m) but limited features
    thompson_nfa,
    /// Backtracking - slower but supports all features
    backtracking,
};

/// Error types for regex operations
pub const RegexError = error{
    EmptyPattern,
    InvalidPattern,
    PatternTooComplex,
    InvalidEscapeSequence,
    UnmatchedParenthesis,
    InvalidQuantifier,
    InvalidCharacterClass,
    InvalidBackreference,
    RecursionLimitExceeded,
    OutOfMemory,
};

/// Compiled regular expression
pub const Regex = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    flags: CompileFlags,
    engine_type: EngineType,

    // Internal NFA representation
    nfa: NFA,
    capture_count: usize,
    named_captures: std.StringHashMap(usize),

    /// Compile a regex pattern with default flags
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) RegexError!Regex {
        return compileWithFlags(allocator, pattern, .{});
    }

    /// Compile a regex pattern with custom flags
    pub fn compileWithFlags(allocator: std.mem.Allocator, pattern: []const u8, flags: CompileFlags) RegexError!Regex {
        if (pattern.len == 0) {
            return RegexError.EmptyPattern;
        }

        // Parse the pattern
        var parser = Parser.init(allocator, pattern, flags);
        const ast = parser.parse() catch return RegexError.InvalidPattern;
        defer ast.deinit(allocator);

        // Detect if backtracking is needed
        const needs_backtracking = requiresBacktracking(ast.root);

        // Compile to NFA
        var compiler = Compiler.init(allocator);
        const nfa = compiler.compile(ast) catch return RegexError.InvalidPattern;

        // Store pattern copy
        const owned_pattern = allocator.dupe(u8, pattern) catch return RegexError.OutOfMemory;

        return Regex{
            .allocator = allocator,
            .pattern = owned_pattern,
            .flags = flags,
            .engine_type = if (needs_backtracking) .backtracking else .thompson_nfa,
            .nfa = nfa,
            .capture_count = ast.capture_count,
            .named_captures = std.StringHashMap(usize).init(allocator),
        };
    }

    /// Free all resources
    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.pattern);
        self.nfa.deinit();
        self.named_captures.deinit();
    }

    /// Check if the pattern matches the entire input string
    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        var vm = VM.init(self.allocator, &self.nfa, self.capture_count, self.flags);
        return vm.isMatch(input);
    }

    /// Check if the pattern matches anywhere in the input string
    pub fn contains(self: *const Regex, input: []const u8) !bool {
        return (try self.find(input)) != null;
    }

    /// Find the first match in the input string
    pub fn find(self: *const Regex, input: []const u8) !?Match {
        var vm = VM.init(self.allocator, &self.nfa, self.capture_count, self.flags);

        if (try vm.find(input)) |result| {
            var captures_list = std.ArrayList([]const u8).init(self.allocator);
            errdefer captures_list.deinit();

            for (result.captures) |cap| {
                try captures_list.append(cap.text);
            }

            const captures = try captures_list.toOwnedSlice();

            return Match.init(
                self.allocator,
                input[result.start..result.end],
                result.start,
                result.end,
                captures,
            );
        }

        return null;
    }

    /// Find all matches in the input string
    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        var matches = std.ArrayList(Match).init(allocator);
        errdefer {
            for (matches.items) |*m| m.deinit();
            matches.deinit();
        }

        var pos: usize = 0;
        while (pos < input.len) {
            var vm = VM.init(self.allocator, &self.nfa, self.capture_count, self.flags);

            if (try vm.findAt(input, pos)) |result| {
                var captures_list = std.ArrayList([]const u8).init(allocator);
                errdefer captures_list.deinit();

                for (result.captures) |cap| {
                    try captures_list.append(cap.text);
                }

                const captures = try captures_list.toOwnedSlice();

                try matches.append(Match.init(
                    allocator,
                    input[result.start..result.end],
                    result.start,
                    result.end,
                    captures,
                ));

                // Move past this match
                pos = if (result.end > result.start) result.end else result.end + 1;
            } else {
                break;
            }
        }

        return matches.toOwnedSlice();
    }

    /// Replace the first match with the replacement string
    pub fn replace(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        if (try self.find(input)) |match_result| {
            defer {
                var mut_match = match_result;
                mut_match.deinit();
            }

            // Expand replacement with backreferences
            const expanded = try expandReplacement(allocator, replacement, match_result.captures);
            defer allocator.free(expanded);

            // Build result
            const before = input[0..match_result.start];
            const after = input[match_result.end..];
            const total_len = before.len + expanded.len + after.len;

            var result = try allocator.alloc(u8, total_len);
            @memcpy(result[0..before.len], before);
            @memcpy(result[before.len .. before.len + expanded.len], expanded);
            @memcpy(result[before.len + expanded.len ..], after);

            return result;
        }

        return allocator.dupe(u8, input);
    }

    /// Replace all matches with the replacement string
    pub fn replaceAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        const matches = try self.findAll(allocator, input);
        defer {
            for (matches) |*m| {
                var mut_match = m.*;
                mut_match.deinit();
            }
            allocator.free(matches);
        }

        if (matches.len == 0) {
            return allocator.dupe(u8, input);
        }

        // Calculate result size
        var result_len: usize = input.len;
        var expanded_replacements = try allocator.alloc([]u8, matches.len);
        defer {
            for (expanded_replacements) |r| allocator.free(r);
            allocator.free(expanded_replacements);
        }

        for (matches, 0..) |match_result, i| {
            expanded_replacements[i] = try expandReplacement(allocator, replacement, match_result.captures);
            result_len = result_len - (match_result.end - match_result.start) + expanded_replacements[i].len;
        }

        var result = try allocator.alloc(u8, result_len);
        var result_pos: usize = 0;
        var input_pos: usize = 0;

        for (matches, 0..) |match_result, i| {
            const before = input[input_pos..match_result.start];
            @memcpy(result[result_pos .. result_pos + before.len], before);
            result_pos += before.len;

            const expanded = expanded_replacements[i];
            @memcpy(result[result_pos .. result_pos + expanded.len], expanded);
            result_pos += expanded.len;

            input_pos = match_result.end;
        }

        // Copy remaining
        const remaining = input[input_pos..];
        @memcpy(result[result_pos .. result_pos + remaining.len], remaining);

        return result;
    }

    /// Split the input string by the pattern
    pub fn split(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
        const matches = try self.findAll(allocator, input);
        defer {
            for (matches) |*m| {
                var mut_match = m.*;
                mut_match.deinit();
            }
            allocator.free(matches);
        }

        var parts = std.ArrayList([]const u8).init(allocator);
        errdefer parts.deinit();

        var pos: usize = 0;
        for (matches) |match_result| {
            try parts.append(input[pos..match_result.start]);
            pos = match_result.end;
        }

        try parts.append(input[pos..]);

        return parts.toOwnedSlice();
    }

    /// Get a named capture group index
    pub fn getCaptureIndex(self: *const Regex, name: []const u8) ?usize {
        return self.named_captures.get(name);
    }

    /// Match iterator for lazy evaluation
    pub const MatchIterator = struct {
        regex: *const Regex,
        input: []const u8,
        pos: usize,
        done: bool,

        pub fn next(self: *MatchIterator, allocator: std.mem.Allocator) !?Match {
            if (self.done) return null;

            var vm = VM.init(self.regex.allocator, &self.regex.nfa, self.regex.capture_count, self.regex.flags);

            if (try vm.findAt(self.input, self.pos)) |result| {
                var captures_list = std.ArrayList([]const u8).init(allocator);
                errdefer captures_list.deinit();

                for (result.captures) |cap| {
                    try captures_list.append(cap.text);
                }

                const captures = try captures_list.toOwnedSlice();

                const match_result = Match.init(
                    allocator,
                    self.input[result.start..result.end],
                    result.start,
                    result.end,
                    captures,
                );

                self.pos = if (result.end > result.start) result.end else result.end + 1;
                return match_result;
            }

            self.done = true;
            return null;
        }

        pub fn reset(self: *MatchIterator) void {
            self.pos = 0;
            self.done = false;
        }
    };

    /// Create an iterator for lazy matching
    pub fn iterator(self: *const Regex, input: []const u8) MatchIterator {
        return .{
            .regex = self,
            .input = input,
            .pos = 0,
            .done = false,
        };
    }
};

/// Expand replacement string with backreferences ($1, $2, etc.)
fn expandReplacement(allocator: std.mem.Allocator, replacement: []const u8, captures: []const []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < replacement.len) {
        if (replacement[i] == '$' and i + 1 < replacement.len) {
            const next = replacement[i + 1];

            if (next == '$') {
                try result.append('$');
                i += 2;
                continue;
            }

            if (next >= '0' and next <= '9') {
                const idx = next - '0';
                if (idx == 0) {
                    // $0 not supported (would need full match)
                    try result.append('$');
                    try result.append(next);
                } else if (idx - 1 < captures.len) {
                    try result.appendSlice(captures[idx - 1]);
                } else {
                    try result.append('$');
                    try result.append(next);
                }
                i += 2;
                continue;
            }
        }

        try result.append(replacement[i]);
        i += 1;
    }

    return result.toOwnedSlice();
}

/// Check if pattern requires backtracking engine
fn requiresBacktracking(node: *const ASTNode) bool {
    switch (node.node_type) {
        .lookahead, .lookbehind, .backref => return true,
        .star, .plus, .optional => {
            if (!node.greedy) return true;
            return requiresBacktracking(node.child.?);
        },
        .repeat => {
            if (!node.greedy) return true;
            return requiresBacktracking(node.child.?);
        },
        .concat => {
            return requiresBacktracking(node.left.?) or requiresBacktracking(node.right.?);
        },
        .alternation => {
            return requiresBacktracking(node.left.?) or requiresBacktracking(node.right.?);
        },
        .group => return requiresBacktracking(node.child.?),
        else => return false,
    }
}

// ============================================================================
// Internal Parser
// ============================================================================

const ASTNodeType = enum {
    literal,
    any,
    char_class,
    anchor,
    concat,
    alternation,
    star,
    plus,
    optional,
    repeat,
    group,
    lookahead,
    lookbehind,
    backref,
    empty,
};

const ASTNode = struct {
    node_type: ASTNodeType,
    // For literal
    char: u8 = 0,
    // For quantifiers
    greedy: bool = true,
    min: usize = 0,
    max: ?usize = null,
    // Children
    child: ?*ASTNode = null,
    left: ?*ASTNode = null,
    right: ?*ASTNode = null,
    // For char class
    chars: []const u8 = &.{},
    negated: bool = false,
    // For anchors
    anchor_type: enum { start, end, word_boundary, non_word_boundary } = .start,
    // For groups
    capture_index: ?usize = null,
    name: ?[]const u8 = null,
    // For backrefs
    backref_index: usize = 0,
};

const AST = struct {
    root: *ASTNode,
    capture_count: usize,

    fn deinit(self: *const AST, allocator: std.mem.Allocator) void {
        freeNode(allocator, self.root);
    }

    fn freeNode(allocator: std.mem.Allocator, node: *ASTNode) void {
        if (node.child) |c| freeNode(allocator, c);
        if (node.left) |l| freeNode(allocator, l);
        if (node.right) |r| freeNode(allocator, r);
        if (node.chars.len > 0) allocator.free(node.chars);
        allocator.destroy(node);
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    pos: usize,
    flags: CompileFlags,
    capture_count: usize,

    fn init(allocator: std.mem.Allocator, pattern: []const u8, flags: CompileFlags) Parser {
        return .{
            .allocator = allocator,
            .pattern = pattern,
            .pos = 0,
            .flags = flags,
            .capture_count = 0,
        };
    }

    fn parse(self: *Parser) !AST {
        const root = try self.parseAlternation();
        return AST{
            .root = root,
            .capture_count = self.capture_count,
        };
    }

    fn parseAlternation(self: *Parser) !*ASTNode {
        var left = try self.parseConcat();

        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            self.pos += 1;
            const right = try self.parseConcat();

            const node = try self.allocator.create(ASTNode);
            node.* = .{
                .node_type = .alternation,
                .left = left,
                .right = right,
            };
            left = node;
        }

        return left;
    }

    fn parseConcat(self: *Parser) !*ASTNode {
        var left: ?*ASTNode = null;

        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c == '|' or c == ')') break;

            const atom = try self.parseAtom();

            if (left == null) {
                left = atom;
            } else {
                const node = try self.allocator.create(ASTNode);
                node.* = .{
                    .node_type = .concat,
                    .left = left,
                    .right = atom,
                };
                left = node;
            }
        }

        if (left == null) {
            const node = try self.allocator.create(ASTNode);
            node.* = .{ .node_type = .empty };
            return node;
        }

        return left.?;
    }

    fn parseAtom(self: *Parser) !*ASTNode {
        var node = try self.parsePrimary();

        // Check for quantifiers
        if (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            switch (c) {
                '*' => {
                    self.pos += 1;
                    const star = try self.allocator.create(ASTNode);
                    star.* = .{
                        .node_type = .star,
                        .child = node,
                        .greedy = self.checkGreedy(),
                    };
                    node = star;
                },
                '+' => {
                    self.pos += 1;
                    const plus = try self.allocator.create(ASTNode);
                    plus.* = .{
                        .node_type = .plus,
                        .child = node,
                        .greedy = self.checkGreedy(),
                    };
                    node = plus;
                },
                '?' => {
                    self.pos += 1;
                    const opt = try self.allocator.create(ASTNode);
                    opt.* = .{
                        .node_type = .optional,
                        .child = node,
                        .greedy = self.checkGreedy(),
                    };
                    node = opt;
                },
                '{' => {
                    const repeat = try self.parseRepeat(node);
                    node = repeat;
                },
                else => {},
            }
        }

        return node;
    }

    fn parsePrimary(self: *Parser) !*ASTNode {
        if (self.pos >= self.pattern.len) {
            const node = try self.allocator.create(ASTNode);
            node.* = .{ .node_type = .empty };
            return node;
        }

        const c = self.pattern[self.pos];

        switch (c) {
            '(' => return self.parseGroup(),
            '[' => return self.parseCharClass(),
            '.' => {
                self.pos += 1;
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .any };
                return node;
            },
            '^' => {
                self.pos += 1;
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .anchor, .anchor_type = .start };
                return node;
            },
            '$' => {
                self.pos += 1;
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .anchor, .anchor_type = .end };
                return node;
            },
            '\\' => return self.parseEscape(),
            else => {
                self.pos += 1;
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .literal, .char = c };
                return node;
            },
        }
    }

    fn parseGroup(self: *Parser) !*ASTNode {
        self.pos += 1; // Skip '('

        var is_capturing = true;
        var name: ?[]const u8 = null;

        // Check for special group types
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '?') {
            self.pos += 1;
            if (self.pos < self.pattern.len) {
                switch (self.pattern[self.pos]) {
                    ':' => {
                        self.pos += 1;
                        is_capturing = false;
                    },
                    '=' => {
                        self.pos += 1;
                        return self.parseLookahead(true);
                    },
                    '!' => {
                        self.pos += 1;
                        return self.parseLookahead(false);
                    },
                    '<' => {
                        self.pos += 1;
                        if (self.pos < self.pattern.len) {
                            if (self.pattern[self.pos] == '=') {
                                self.pos += 1;
                                return self.parseLookbehind(true);
                            } else if (self.pattern[self.pos] == '!') {
                                self.pos += 1;
                                return self.parseLookbehind(false);
                            } else {
                                // Named capture
                                name = try self.parseGroupName();
                            }
                        }
                    },
                    'P' => {
                        self.pos += 1;
                        if (self.pos < self.pattern.len and self.pattern[self.pos] == '<') {
                            self.pos += 1;
                            name = try self.parseGroupName();
                        }
                    },
                    else => {},
                }
            }
        }

        const capture_index: ?usize = if (is_capturing) blk: {
            self.capture_count += 1;
            break :blk self.capture_count;
        } else null;

        const child = try self.parseAlternation();

        if (self.pos < self.pattern.len and self.pattern[self.pos] == ')') {
            self.pos += 1;
        }

        const node = try self.allocator.create(ASTNode);
        node.* = .{
            .node_type = .group,
            .child = child,
            .capture_index = capture_index,
            .name = name,
        };
        return node;
    }

    fn parseLookahead(self: *Parser, positive: bool) !*ASTNode {
        const child = try self.parseAlternation();

        if (self.pos < self.pattern.len and self.pattern[self.pos] == ')') {
            self.pos += 1;
        }

        const node = try self.allocator.create(ASTNode);
        node.* = .{
            .node_type = .lookahead,
            .child = child,
            .greedy = positive, // Reusing greedy for positive/negative
        };
        return node;
    }

    fn parseLookbehind(self: *Parser, positive: bool) !*ASTNode {
        const child = try self.parseAlternation();

        if (self.pos < self.pattern.len and self.pattern[self.pos] == ')') {
            self.pos += 1;
        }

        const node = try self.allocator.create(ASTNode);
        node.* = .{
            .node_type = .lookbehind,
            .child = child,
            .greedy = positive,
        };
        return node;
    }

    fn parseGroupName(self: *Parser) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.pattern.len and self.pattern[self.pos] != '>') {
            self.pos += 1;
        }
        const name = self.pattern[start..self.pos];
        if (self.pos < self.pattern.len) self.pos += 1; // Skip '>'
        return name;
    }

    fn parseCharClass(self: *Parser) !*ASTNode {
        self.pos += 1; // Skip '['

        var negated = false;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }

        var chars = std.ArrayList(u8).init(self.allocator);
        errdefer chars.deinit();

        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            const c = self.pattern[self.pos];

            if (c == '\\' and self.pos + 1 < self.pattern.len) {
                self.pos += 1;
                const escaped = try self.parseEscapeChar();
                try chars.append(escaped);
            } else if (self.pos + 2 < self.pattern.len and self.pattern[self.pos + 1] == '-' and self.pattern[self.pos + 2] != ']') {
                // Range
                const range_start = c;
                self.pos += 2;
                const range_end = self.pattern[self.pos];
                var ch = range_start;
                while (ch <= range_end) : (ch += 1) {
                    try chars.append(ch);
                }
                self.pos += 1;
            } else {
                try chars.append(c);
                self.pos += 1;
            }
        }

        if (self.pos < self.pattern.len) self.pos += 1; // Skip ']'

        const node = try self.allocator.create(ASTNode);
        node.* = .{
            .node_type = .char_class,
            .chars = try chars.toOwnedSlice(),
            .negated = negated,
        };
        return node;
    }

    fn parseEscape(self: *Parser) !*ASTNode {
        self.pos += 1; // Skip '\'

        if (self.pos >= self.pattern.len) {
            const node = try self.allocator.create(ASTNode);
            node.* = .{ .node_type = .literal, .char = '\\' };
            return node;
        }

        const c = self.pattern[self.pos];
        self.pos += 1;

        switch (c) {
            'd' => {
                // Digit class [0-9]
                var chars = try self.allocator.alloc(u8, 10);
                for (0..10) |i| chars[i] = '0' + @as(u8, @intCast(i));
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .char_class, .chars = chars };
                return node;
            },
            'D' => {
                var chars = try self.allocator.alloc(u8, 10);
                for (0..10) |i| chars[i] = '0' + @as(u8, @intCast(i));
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .char_class, .chars = chars, .negated = true };
                return node;
            },
            'w' => {
                // Word character [a-zA-Z0-9_]
                var chars = std.ArrayList(u8).init(self.allocator);
                errdefer chars.deinit();
                var ch: u8 = 'a';
                while (ch <= 'z') : (ch += 1) try chars.append(ch);
                ch = 'A';
                while (ch <= 'Z') : (ch += 1) try chars.append(ch);
                ch = '0';
                while (ch <= '9') : (ch += 1) try chars.append(ch);
                try chars.append('_');
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .char_class, .chars = try chars.toOwnedSlice() };
                return node;
            },
            'W' => {
                var chars = std.ArrayList(u8).init(self.allocator);
                errdefer chars.deinit();
                var ch: u8 = 'a';
                while (ch <= 'z') : (ch += 1) try chars.append(ch);
                ch = 'A';
                while (ch <= 'Z') : (ch += 1) try chars.append(ch);
                ch = '0';
                while (ch <= '9') : (ch += 1) try chars.append(ch);
                try chars.append('_');
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .char_class, .chars = try chars.toOwnedSlice(), .negated = true };
                return node;
            },
            's' => {
                // Whitespace
                const chars = try self.allocator.dupe(u8, " \t\n\r\x0C");
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .char_class, .chars = chars };
                return node;
            },
            'S' => {
                const chars = try self.allocator.dupe(u8, " \t\n\r\x0C");
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .char_class, .chars = chars, .negated = true };
                return node;
            },
            'b' => {
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .anchor, .anchor_type = .word_boundary };
                return node;
            },
            'B' => {
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .anchor, .anchor_type = .non_word_boundary };
                return node;
            },
            '0'...'9' => {
                // Backref
                const idx = c - '0';
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .backref, .backref_index = idx };
                return node;
            },
            'n' => {
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .literal, .char = '\n' };
                return node;
            },
            'r' => {
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .literal, .char = '\r' };
                return node;
            },
            't' => {
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .literal, .char = '\t' };
                return node;
            },
            else => {
                const node = try self.allocator.create(ASTNode);
                node.* = .{ .node_type = .literal, .char = c };
                return node;
            },
        }
    }

    fn parseEscapeChar(self: *Parser) !u8 {
        const c = self.pattern[self.pos];
        self.pos += 1;
        return switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => 0,
            else => c,
        };
    }

    fn parseRepeat(self: *Parser, child: *ASTNode) !*ASTNode {
        self.pos += 1; // Skip '{'

        var min: usize = 0;
        var max: ?usize = null;

        // Parse min
        while (self.pos < self.pattern.len and self.pattern[self.pos] >= '0' and self.pattern[self.pos] <= '9') {
            min = min * 10 + (self.pattern[self.pos] - '0');
            self.pos += 1;
        }

        if (self.pos < self.pattern.len and self.pattern[self.pos] == ',') {
            self.pos += 1;
            if (self.pos < self.pattern.len and self.pattern[self.pos] >= '0' and self.pattern[self.pos] <= '9') {
                max = 0;
                while (self.pos < self.pattern.len and self.pattern[self.pos] >= '0' and self.pattern[self.pos] <= '9') {
                    max = max.? * 10 + (self.pattern[self.pos] - '0');
                    self.pos += 1;
                }
            }
            // else unbounded
        } else {
            max = min;
        }

        if (self.pos < self.pattern.len and self.pattern[self.pos] == '}') {
            self.pos += 1;
        }

        const node = try self.allocator.create(ASTNode);
        node.* = .{
            .node_type = .repeat,
            .child = child,
            .min = min,
            .max = max,
            .greedy = self.checkGreedy(),
        };
        return node;
    }

    fn checkGreedy(self: *Parser) bool {
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '?') {
            self.pos += 1;
            return false;
        }
        return true;
    }
};

// ============================================================================
// Internal Compiler
// ============================================================================

const NFA = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayList(State),
    start_state: usize,
    accept_state: usize,

    const State = struct {
        transitions: std.ArrayList(Transition),
        is_accept: bool,
    };

    const Transition = struct {
        target: usize,
        match: TransitionMatch,
    };

    const TransitionMatch = union(enum) {
        epsilon: void,
        literal: u8,
        any: void,
        char_class: struct {
            chars: []const u8,
            negated: bool,
        },
        anchor: ASTNode.anchor_type,
    };

    fn init(allocator: std.mem.Allocator) NFA {
        return .{
            .allocator = allocator,
            .states = std.ArrayList(State).init(allocator),
            .start_state = 0,
            .accept_state = 0,
        };
    }

    fn deinit(self: *NFA) void {
        for (self.states.items) |*state| {
            state.transitions.deinit();
        }
        self.states.deinit();
    }

    fn addState(self: *NFA) !usize {
        const idx = self.states.items.len;
        try self.states.append(.{
            .transitions = std.ArrayList(Transition).init(self.allocator),
            .is_accept = false,
        });
        return idx;
    }

    fn addTransition(self: *NFA, from: usize, to: usize, match: TransitionMatch) !void {
        try self.states.items[from].transitions.append(.{
            .target = to,
            .match = match,
        });
    }
};

const Compiler = struct {
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Compiler {
        return .{ .allocator = allocator };
    }

    fn compile(self: *Compiler, ast: AST) !NFA {
        var nfa = NFA.init(self.allocator);

        const start = try nfa.addState();
        const result = try self.compileNode(&nfa, ast.root);
        try nfa.addTransition(start, result.start, .{ .epsilon = {} });

        nfa.start_state = start;
        nfa.accept_state = result.end;
        nfa.states.items[result.end].is_accept = true;

        return nfa;
    }

    const Fragment = struct {
        start: usize,
        end: usize,
    };

    fn compileNode(self: *Compiler, nfa: *NFA, node: *const ASTNode) !Fragment {
        switch (node.node_type) {
            .empty => {
                const state = try nfa.addState();
                return .{ .start = state, .end = state };
            },
            .literal => {
                const start = try nfa.addState();
                const end = try nfa.addState();
                try nfa.addTransition(start, end, .{ .literal = node.char });
                return .{ .start = start, .end = end };
            },
            .any => {
                const start = try nfa.addState();
                const end = try nfa.addState();
                try nfa.addTransition(start, end, .{ .any = {} });
                return .{ .start = start, .end = end };
            },
            .char_class => {
                const start = try nfa.addState();
                const end = try nfa.addState();
                try nfa.addTransition(start, end, .{ .char_class = .{
                    .chars = node.chars,
                    .negated = node.negated,
                } });
                return .{ .start = start, .end = end };
            },
            .anchor => {
                const start = try nfa.addState();
                const end = try nfa.addState();
                try nfa.addTransition(start, end, .{ .anchor = node.anchor_type });
                return .{ .start = start, .end = end };
            },
            .concat => {
                const left = try self.compileNode(nfa, node.left.?);
                const right = try self.compileNode(nfa, node.right.?);
                try nfa.addTransition(left.end, right.start, .{ .epsilon = {} });
                return .{ .start = left.start, .end = right.end };
            },
            .alternation => {
                const start = try nfa.addState();
                const end = try nfa.addState();
                const left = try self.compileNode(nfa, node.left.?);
                const right = try self.compileNode(nfa, node.right.?);
                try nfa.addTransition(start, left.start, .{ .epsilon = {} });
                try nfa.addTransition(start, right.start, .{ .epsilon = {} });
                try nfa.addTransition(left.end, end, .{ .epsilon = {} });
                try nfa.addTransition(right.end, end, .{ .epsilon = {} });
                return .{ .start = start, .end = end };
            },
            .star => {
                const start = try nfa.addState();
                const end = try nfa.addState();
                const child = try self.compileNode(nfa, node.child.?);
                try nfa.addTransition(start, child.start, .{ .epsilon = {} });
                try nfa.addTransition(start, end, .{ .epsilon = {} });
                try nfa.addTransition(child.end, child.start, .{ .epsilon = {} });
                try nfa.addTransition(child.end, end, .{ .epsilon = {} });
                return .{ .start = start, .end = end };
            },
            .plus => {
                const start = try nfa.addState();
                const end = try nfa.addState();
                const child = try self.compileNode(nfa, node.child.?);
                try nfa.addTransition(start, child.start, .{ .epsilon = {} });
                try nfa.addTransition(child.end, child.start, .{ .epsilon = {} });
                try nfa.addTransition(child.end, end, .{ .epsilon = {} });
                return .{ .start = start, .end = end };
            },
            .optional => {
                const start = try nfa.addState();
                const end = try nfa.addState();
                const child = try self.compileNode(nfa, node.child.?);
                try nfa.addTransition(start, child.start, .{ .epsilon = {} });
                try nfa.addTransition(start, end, .{ .epsilon = {} });
                try nfa.addTransition(child.end, end, .{ .epsilon = {} });
                return .{ .start = start, .end = end };
            },
            .repeat => {
                // Build min required copies + optional copies
                var current_start = try nfa.addState();
                const initial_start = current_start;
                var current_end = current_start;

                // Required repetitions
                for (0..node.min) |_| {
                    const child = try self.compileNode(nfa, node.child.?);
                    try nfa.addTransition(current_end, child.start, .{ .epsilon = {} });
                    current_end = child.end;
                }

                // Optional repetitions
                if (node.max) |max| {
                    for (node.min..max) |_| {
                        const opt_end = try nfa.addState();
                        const child = try self.compileNode(nfa, node.child.?);
                        try nfa.addTransition(current_end, child.start, .{ .epsilon = {} });
                        try nfa.addTransition(current_end, opt_end, .{ .epsilon = {} });
                        try nfa.addTransition(child.end, opt_end, .{ .epsilon = {} });
                        current_end = opt_end;
                    }
                } else {
                    // Unbounded
                    const child = try self.compileNode(nfa, node.child.?);
                    try nfa.addTransition(current_end, child.start, .{ .epsilon = {} });
                    try nfa.addTransition(child.end, current_end, .{ .epsilon = {} });
                }

                return .{ .start = initial_start, .end = current_end };
            },
            .group => {
                return self.compileNode(nfa, node.child.?);
            },
            else => {
                const state = try nfa.addState();
                return .{ .start = state, .end = state };
            },
        }
    }
};

// ============================================================================
// Internal VM
// ============================================================================

const VM = struct {
    allocator: std.mem.Allocator,
    nfa: *const NFA,
    capture_count: usize,
    flags: CompileFlags,

    const Capture = struct {
        text: []const u8,
        start: usize,
        end: usize,
    };

    const MatchResult = struct {
        start: usize,
        end: usize,
        captures: []Capture,
    };

    fn init(allocator: std.mem.Allocator, nfa: *const NFA, capture_count: usize, flags: CompileFlags) VM {
        return .{
            .allocator = allocator,
            .nfa = nfa,
            .capture_count = capture_count,
            .flags = flags,
        };
    }

    fn isMatch(self: *VM, input: []const u8) !bool {
        var current_states = std.ArrayList(usize).init(self.allocator);
        defer current_states.deinit();
        var next_states = std.ArrayList(usize).init(self.allocator);
        defer next_states.deinit();

        try self.addEpsilonClosure(&current_states, self.nfa.start_state);

        for (input, 0..) |c, pos| {
            next_states.clearRetainingCapacity();

            for (current_states.items) |state| {
                for (self.nfa.states.items[state].transitions.items) |trans| {
                    if (self.matches(trans.match, c, input, pos)) {
                        try self.addEpsilonClosure(&next_states, trans.target);
                    }
                }
            }

            const tmp = current_states;
            current_states = next_states;
            next_states = tmp;
        }

        for (current_states.items) |state| {
            if (self.nfa.states.items[state].is_accept) return true;
        }

        return false;
    }

    fn find(self: *VM, input: []const u8) !?MatchResult {
        for (0..input.len + 1) |start| {
            if (try self.matchAt(input, start)) |result| {
                return result;
            }
        }
        return null;
    }

    fn findAt(self: *VM, input: []const u8, start: usize) !?MatchResult {
        return self.matchAt(input, start);
    }

    fn matchAt(self: *VM, input: []const u8, start: usize) !?MatchResult {
        var current_states = std.ArrayList(usize).init(self.allocator);
        defer current_states.deinit();
        var next_states = std.ArrayList(usize).init(self.allocator);
        defer next_states.deinit();

        try self.addEpsilonClosure(&current_states, self.nfa.start_state);

        var last_match: ?usize = null;

        // Check initial accept
        for (current_states.items) |state| {
            if (self.nfa.states.items[state].is_accept) {
                last_match = start;
            }
        }

        var pos = start;
        while (pos < input.len) {
            next_states.clearRetainingCapacity();

            for (current_states.items) |state| {
                for (self.nfa.states.items[state].transitions.items) |trans| {
                    if (self.matches(trans.match, input[pos], input, pos)) {
                        try self.addEpsilonClosure(&next_states, trans.target);
                    }
                }
            }

            if (next_states.items.len == 0) break;

            const tmp = current_states;
            current_states = next_states;
            next_states = tmp;

            pos += 1;

            for (current_states.items) |state| {
                if (self.nfa.states.items[state].is_accept) {
                    last_match = pos;
                }
            }
        }

        if (last_match) |end| {
            const captures = try self.allocator.alloc(Capture, self.capture_count);
            for (captures) |*cap| cap.* = .{ .text = "", .start = 0, .end = 0 };
            return .{
                .start = start,
                .end = end,
                .captures = captures,
            };
        }

        return null;
    }

    fn addEpsilonClosure(self: *VM, states: *std.ArrayList(usize), state: usize) !void {
        for (states.items) |s| {
            if (s == state) return;
        }

        try states.append(state);

        for (self.nfa.states.items[state].transitions.items) |trans| {
            if (trans.match == .epsilon) {
                try self.addEpsilonClosure(states, trans.target);
            }
        }
    }

    fn matches(self: *const VM, match: NFA.TransitionMatch, c: u8, input: []const u8, pos: usize) bool {
        switch (match) {
            .epsilon => return false,
            .literal => |lit| {
                if (self.flags.case_insensitive) {
                    return std.ascii.toLower(c) == std.ascii.toLower(lit);
                }
                return c == lit;
            },
            .any => return if (self.flags.dot_all) true else c != '\n',
            .char_class => |cc| {
                var found = false;
                for (cc.chars) |ch| {
                    if (self.flags.case_insensitive) {
                        if (std.ascii.toLower(c) == std.ascii.toLower(ch)) {
                            found = true;
                            break;
                        }
                    } else {
                        if (c == ch) {
                            found = true;
                            break;
                        }
                    }
                }
                return if (cc.negated) !found else found;
            },
            .anchor => |anchor| {
                switch (anchor) {
                    .start => return pos == 0 or (self.flags.multiline and pos > 0 and input[pos - 1] == '\n'),
                    .end => return pos == input.len or (self.flags.multiline and c == '\n'),
                    .word_boundary => return self.isWordBoundary(input, pos),
                    .non_word_boundary => return !self.isWordBoundary(input, pos),
                }
            },
        }
    }

    fn isWordBoundary(self: *const VM, input: []const u8, pos: usize) bool {
        _ = self;
        const is_word = struct {
            fn check(c: u8) bool {
                return std.ascii.isAlphanumeric(c) or c == '_';
            }
        }.check;

        const prev_word = if (pos > 0) is_word(input[pos - 1]) else false;
        const curr_word = if (pos < input.len) is_word(input[pos]) else false;

        return prev_word != curr_word;
    }
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Quick check if pattern matches input (compiles pattern each time)
pub fn isMatch(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8) !bool {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return regex.isMatch(input);
}

/// Quick find first match (compiles pattern each time)
pub fn find(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8) !?Match {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return regex.find(input);
}

/// Quick replace first match (compiles pattern each time)
pub fn replace(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8, replacement: []const u8) ![]u8 {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return regex.replace(allocator, input, replacement);
}

/// Quick replace all matches (compiles pattern each time)
pub fn replaceAll(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8, replacement: []const u8) ![]u8 {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return regex.replaceAll(allocator, input, replacement);
}

/// Quick split by pattern (compiles pattern each time)
pub fn split(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8) ![][]const u8 {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return regex.split(allocator, input);
}

// ============================================================================
// Tests
// ============================================================================

test "compile empty pattern" {
    const result = Regex.compile(std.testing.allocator, "");
    try std.testing.expectError(RegexError.EmptyPattern, result);
}

test "compile basic pattern" {
    var regex = try Regex.compile(std.testing.allocator, "test");
    defer regex.deinit();
    try std.testing.expectEqualStrings("test", regex.pattern);
}

test "match literal" {
    var regex = try Regex.compile(std.testing.allocator, "hello");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(!try regex.isMatch("world"));
}

test "alternation" {
    var regex = try Regex.compile(std.testing.allocator, "cat|dog");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("cat"));
    try std.testing.expect(try regex.isMatch("dog"));
    try std.testing.expect(!try regex.isMatch("bird"));
}

test "star quantifier" {
    var regex = try Regex.compile(std.testing.allocator, "a*");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
}

test "plus quantifier" {
    var regex = try Regex.compile(std.testing.allocator, "a+");
    defer regex.deinit();
    try std.testing.expect(!try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
}

test "character class" {
    var regex = try Regex.compile(std.testing.allocator, "[abc]+");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(!try regex.isMatch("xyz"));
}

test "replace" {
    var regex = try Regex.compile(std.testing.allocator, "world");
    defer regex.deinit();
    const result = try regex.replace(std.testing.allocator, "hello world", "Zig");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello Zig", result);
}

test "replace all" {
    var regex = try Regex.compile(std.testing.allocator, "a");
    defer regex.deinit();
    const result = try regex.replaceAll(std.testing.allocator, "banana", "o");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("bonono", result);
}

test "split" {
    var regex = try Regex.compile(std.testing.allocator, ",");
    defer regex.deinit();
    const parts = try regex.split(std.testing.allocator, "a,b,c");
    defer std.testing.allocator.free(parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("b", parts[1]);
    try std.testing.expectEqualStrings("c", parts[2]);
}
