// Regex Engine for Home Language
// Basic regular expression matching with NFA-based implementation

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Regular expression error types
pub const RegexError = error{
    InvalidPattern,
    UnmatchedParenthesis,
    UnmatchedBracket,
    InvalidEscape,
    InvalidQuantifier,
    OutOfMemory,
};

/// Match result containing the matched text and position
pub const Match = struct {
    start: usize,
    end: usize,
    text: []const u8,

    pub fn length(self: Match) usize {
        return self.end - self.start;
    }
};

/// Capture group information
pub const Capture = struct {
    start: usize,
    end: usize,
    group_id: usize,
};

/// Compiled regex pattern
pub const Regex = struct {
    const Self = @This();

    allocator: Allocator,
    pattern: []const u8,
    nfa: NFA,

    /// Compile a regex pattern
    pub fn compile(allocator: Allocator, pattern: []const u8) !Self {
        const parser = try Parser.init(allocator, pattern);
        const ast = try parser.parse();
        const nfa = try NFA.fromAST(allocator, ast);

        return Self{
            .allocator = allocator,
            .pattern = try allocator.dupe(u8, pattern),
            .nfa = nfa,
        };
    }

    /// Clean up allocated memory
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.pattern);
        self.nfa.deinit();
    }

    /// Test if pattern matches the entire text
    pub fn match(self: *const Self, text: []const u8) bool {
        return self.nfa.matchFull(text);
    }

    /// Find the first match in text
    pub fn find(self: *const Self, text: []const u8) ?Match {
        return self.nfa.findFirst(text);
    }

    /// Find all matches in text (caller owns returned memory)
    pub fn findAll(self: *const Self, text: []const u8) ![]Match {
        return self.nfa.findAll(self.allocator, text);
    }

    /// Replace all matches with replacement text (caller owns returned memory)
    pub fn replace(self: *const Self, text: []const u8, replacement: []const u8) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < text.len) {
            if (self.nfa.findAt(text, pos)) |m| {
                // Add text before match
                try result.appendSlice(self.allocator, text[pos..m.start]);
                // Add replacement
                try result.appendSlice(self.allocator, replacement);
                pos = m.end;
            } else {
                // Add remaining text
                try result.appendSlice(self.allocator, text[pos..]);
                break;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Replace first match with replacement text (caller owns returned memory)
    pub fn replaceFirst(self: *const Self, text: []const u8, replacement: []const u8) ![]u8 {
        if (self.find(text)) |m| {
            var result: std.ArrayList(u8) = .empty;
            try result.appendSlice(self.allocator, text[0..m.start]);
            try result.appendSlice(self.allocator, replacement);
            try result.appendSlice(self.allocator, text[m.end..]);
            return result.toOwnedSlice(self.allocator);
        }
        return try self.allocator.dupe(u8, text);
    }
};

// =================================================================================
//                                   AST NODES
// =================================================================================

const ASTNode = union(enum) {
    literal: u8,
    any: void, // '.'
    concat: struct {
        left: *ASTNode,
        right: *ASTNode,
    },
    alternate: struct {
        left: *ASTNode,
        right: *ASTNode,
    },
    star: *ASTNode, // '*' zero or more
    plus: *ASTNode, // '+' one or more
    question: *ASTNode, // '?' zero or one
    char_class: CharClass,
    group: struct {
        id: usize,
        inner: *ASTNode,
    },
};

const CharClass = struct {
    ranges: []CharRange,
    negated: bool,
};

const CharRange = struct {
    start: u8,
    end: u8,
};

// =================================================================================
//                                   PARSER
// =================================================================================

const Parser = struct {
    allocator: Allocator,
    pattern: []const u8,
    pos: usize,
    group_count: usize,

    fn init(allocator: Allocator, pattern: []const u8) !Parser {
        return Parser{
            .allocator = allocator,
            .pattern = pattern,
            .pos = 0,
            .group_count = 0,
        };
    }

    fn parse(self: *Parser) !*ASTNode {
        return try self.parseAlternation();
    }

    fn parseAlternation(self: *Parser) RegexError!*ASTNode {
        var left = try self.parseConcat();

        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            self.pos += 1;
            const right = try self.parseConcat();

            const node = try self.allocator.create(ASTNode);
            node.* = ASTNode{
                .alternate = .{
                    .left = left,
                    .right = right,
                },
            };
            left = node;
        }

        return left;
    }

    fn parseConcat(self: *Parser) RegexError!*ASTNode {
        var nodes: std.ArrayList(*ASTNode) = .empty;
        defer nodes.deinit(self.allocator);

        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c == '|' or c == ')') break;

            const node = try self.parseQuantified();
            try nodes.append(self.allocator, node);
        }

        if (nodes.items.len == 0) {
            return RegexError.InvalidPattern;
        }

        var result = nodes.items[0];
        var i: usize = 1;
        while (i < nodes.items.len) : (i += 1) {
            const concat = try self.allocator.create(ASTNode);
            concat.* = ASTNode{
                .concat = .{
                    .left = result,
                    .right = nodes.items[i],
                },
            };
            result = concat;
        }

        return result;
    }

    fn parseQuantified(self: *Parser) RegexError!*ASTNode {
        var node = try self.parseAtom();

        if (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c == '*' or c == '+' or c == '?') {
                self.pos += 1;
                const quant = try self.allocator.create(ASTNode);
                quant.* = switch (c) {
                    '*' => ASTNode{ .star = node },
                    '+' => ASTNode{ .plus = node },
                    '?' => ASTNode{ .question = node },
                    else => unreachable,
                };
                return quant;
            }
        }

        return node;
    }

    fn parseAtom(self: *Parser) RegexError!*ASTNode {
        if (self.pos >= self.pattern.len) {
            return RegexError.InvalidPattern;
        }

        const c = self.pattern[self.pos];

        // Handle special characters
        if (c == '.') {
            self.pos += 1;
            const node = try self.allocator.create(ASTNode);
            node.* = ASTNode{ .any = {} };
            return node;
        }

        if (c == '[') {
            return try self.parseCharClass();
        }

        if (c == '(') {
            self.pos += 1;
            const group_id = self.group_count;
            self.group_count += 1;

            const inner = try self.parseAlternation();

            if (self.pos >= self.pattern.len or self.pattern[self.pos] != ')') {
                return RegexError.UnmatchedParenthesis;
            }
            self.pos += 1;

            const node = try self.allocator.create(ASTNode);
            node.* = ASTNode{
                .group = .{
                    .id = group_id,
                    .inner = inner,
                },
            };
            return node;
        }

        if (c == '\\') {
            return try self.parseEscape();
        }

        // Literal character
        self.pos += 1;
        const node = try self.allocator.create(ASTNode);
        node.* = ASTNode{ .literal = c };
        return node;
    }

    fn parseCharClass(self: *Parser) RegexError!*ASTNode {
        self.pos += 1; // skip '['

        if (self.pos >= self.pattern.len) {
            return RegexError.UnmatchedBracket;
        }

        var negated = false;
        if (self.pattern[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }

        var ranges: std.ArrayList(CharRange) = .empty;
        defer ranges.deinit(self.allocator);

        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            const start_char = self.pattern[self.pos];
            self.pos += 1;

            // Check for range
            if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '-' and self.pattern[self.pos + 1] != ']') {
                self.pos += 1; // skip '-'
                const end_char = self.pattern[self.pos];
                self.pos += 1;
                try ranges.append(self.allocator, CharRange{ .start = start_char, .end = end_char });
            } else {
                try ranges.append(self.allocator, CharRange{ .start = start_char, .end = start_char });
            }
        }

        if (self.pos >= self.pattern.len or self.pattern[self.pos] != ']') {
            return RegexError.UnmatchedBracket;
        }
        self.pos += 1;

        const ranges_copy = try self.allocator.alloc(CharRange, ranges.items.len);
        @memcpy(ranges_copy, ranges.items);

        const node = try self.allocator.create(ASTNode);
        node.* = ASTNode{
            .char_class = CharClass{
                .ranges = ranges_copy,
                .negated = negated,
            },
        };
        return node;
    }

    fn parseEscape(self: *Parser) RegexError!*ASTNode {
        self.pos += 1; // skip '\\'

        if (self.pos >= self.pattern.len) {
            return RegexError.InvalidEscape;
        }

        const c = self.pattern[self.pos];
        self.pos += 1;

        const node = try self.allocator.create(ASTNode);

        // Character classes
        switch (c) {
            'd' => {
                // \d = [0-9]
                const ranges = try self.allocator.alloc(CharRange, 1);
                ranges[0] = CharRange{ .start = '0', .end = '9' };
                node.* = ASTNode{
                    .char_class = CharClass{
                        .ranges = ranges,
                        .negated = false,
                    },
                };
            },
            'w' => {
                // \w = [a-zA-Z0-9_]
                const ranges = try self.allocator.alloc(CharRange, 4);
                ranges[0] = CharRange{ .start = 'a', .end = 'z' };
                ranges[1] = CharRange{ .start = 'A', .end = 'Z' };
                ranges[2] = CharRange{ .start = '0', .end = '9' };
                ranges[3] = CharRange{ .start = '_', .end = '_' };
                node.* = ASTNode{
                    .char_class = CharClass{
                        .ranges = ranges,
                        .negated = false,
                    },
                };
            },
            's' => {
                // \s = [ \t\n\r]
                const ranges = try self.allocator.alloc(CharRange, 4);
                ranges[0] = CharRange{ .start = ' ', .end = ' ' };
                ranges[1] = CharRange{ .start = '\t', .end = '\t' };
                ranges[2] = CharRange{ .start = '\n', .end = '\n' };
                ranges[3] = CharRange{ .start = '\r', .end = '\r' };
                node.* = ASTNode{
                    .char_class = CharClass{
                        .ranges = ranges,
                        .negated = false,
                    },
                };
            },
            'n' => node.* = ASTNode{ .literal = '\n' },
            't' => node.* = ASTNode{ .literal = '\t' },
            'r' => node.* = ASTNode{ .literal = '\r' },
            else => node.* = ASTNode{ .literal = c }, // Escaped literal
        }

        return node;
    }
};

// =================================================================================
//                                   NFA
// =================================================================================

const State = struct {
    id: usize,
    transitions: std.ArrayList(Transition),
    is_accept: bool,

    fn init(allocator: Allocator, id: usize) State {
        return State{
            .id = id,
            .transitions = std.ArrayList(Transition).init(allocator),
            .is_accept = false,
        };
    }

    fn deinit(self: *State) void {
        self.transitions.deinit();
    }
};

const Transition = struct {
    target: usize,
    condition: Condition,
};

const Condition = union(enum) {
    epsilon: void,
    char: u8,
    any: void,
    char_class: CharClass,
};

const NFA = struct {
    allocator: Allocator,
    states: []State,
    start: usize,
    accept: usize,

    fn fromAST(allocator: Allocator, ast: *ASTNode) !NFA {
        var builder = NFABuilder.init(allocator);
        const fragment = try builder.build(ast);
        return builder.toNFA(fragment);
    }

    fn deinit(self: *NFA) void {
        for (self.states) |*state| {
            state.deinit();
        }
        self.allocator.free(self.states);
    }

    fn matchFull(self: *const NFA, text: []const u8) bool {
        var current_states = std.ArrayList(usize).init(self.allocator);
        defer current_states.deinit();

        var next_states = std.ArrayList(usize).init(self.allocator);
        defer next_states.deinit();

        // Start with epsilon closure of start state
        self.epsilonClosure(self.start, &current_states) catch return false;

        // Process each character
        for (text) |c| {
            next_states.clearRetainingCapacity();

            for (current_states.items) |state_id| {
                const state = &self.states[state_id];
                for (state.transitions.items) |trans| {
                    if (self.matchesCondition(trans.condition, c)) {
                        self.epsilonClosure(trans.target, &next_states) catch return false;
                    }
                }
            }

            const temp = current_states;
            current_states = next_states;
            next_states = temp;

            if (current_states.items.len == 0) return false;
        }

        // Check if any current state is accept state
        for (current_states.items) |state_id| {
            if (self.states[state_id].is_accept) return true;
        }

        return false;
    }

    fn findFirst(self: *const NFA, text: []const u8) ?Match {
        var start_pos: usize = 0;
        while (start_pos < text.len) : (start_pos += 1) {
            if (self.findAt(text, start_pos)) |m| {
                return m;
            }
        }
        return null;
    }

    fn findAt(self: *const NFA, text: []const u8, start: usize) ?Match {
        var pos = start;
        while (pos <= text.len) : (pos += 1) {
            if (self.matchFull(text[start..pos])) {
                return Match{
                    .start = start,
                    .end = pos,
                    .text = text[start..pos],
                };
            }
        }
        return null;
    }

    fn findAll(self: *const NFA, allocator: Allocator, text: []const u8) ![]Match {
        var matches: std.ArrayList(Match) = .empty;
        errdefer matches.deinit(allocator);

        var pos: usize = 0;
        while (pos < text.len) {
            if (self.findAt(text, pos)) |m| {
                try matches.append(allocator, m);
                pos = m.end;
            } else {
                pos += 1;
            }
        }

        return matches.toOwnedSlice(allocator);
    }

    fn epsilonClosure(self: *const NFA, state_id: usize, visited: *std.ArrayList(usize)) !void {
        // Check if already visited
        for (visited.items) |id| {
            if (id == state_id) return;
        }

        try visited.append(state_id);

        const state = &self.states[state_id];
        for (state.transitions.items) |trans| {
            if (trans.condition == .epsilon) {
                try self.epsilonClosure(trans.target, visited);
            }
        }
    }

    fn matchesCondition(self: *const NFA, condition: Condition, c: u8) bool {
        _ = self;
        return switch (condition) {
            .epsilon => false,
            .char => |ch| ch == c,
            .any => true,
            .char_class => |cc| {
                var matches = false;
                for (cc.ranges) |range| {
                    if (c >= range.start and c <= range.end) {
                        matches = true;
                        break;
                    }
                }
                return if (cc.negated) !matches else matches;
            },
        };
    }
};

const Fragment = struct {
    start: usize,
    out: std.ArrayList(usize), // States with dangling transitions
};

const NFABuilder = struct {
    allocator: Allocator,
    states: std.ArrayList(State),
    next_id: usize,

    fn init(allocator: Allocator) NFABuilder {
        return NFABuilder{
            .allocator = allocator,
            .states = std.ArrayList(State).init(allocator),
            .next_id = 0,
        };
    }

    fn createState(self: *NFABuilder) !usize {
        const id = self.next_id;
        self.next_id += 1;
        try self.states.append(State.init(self.allocator, id));
        return id;
    }

    fn build(self: *NFABuilder, node: *ASTNode) anyerror!Fragment {
        return switch (node.*) {
            .literal => |c| try self.buildLiteral(c),
            .any => try self.buildAny(),
            .concat => |con| try self.buildConcat(con.left, con.right),
            .alternate => |alt| try self.buildAlternate(alt.left, alt.right),
            .star => |inner| try self.buildStar(inner),
            .plus => |inner| try self.buildPlus(inner),
            .question => |inner| try self.buildQuestion(inner),
            .char_class => |cc| try self.buildCharClass(cc),
            .group => |grp| try self.build(grp.inner),
        };
    }

    fn buildLiteral(self: *NFABuilder, c: u8) !Fragment {
        const start = try self.createState();
        const end = try self.createState();

        try self.states.items[start].transitions.append(Transition{
            .target = end,
            .condition = .{ .char = c },
        });

        var out = std.ArrayList(usize).init(self.allocator);
        try out.append(end);

        return Fragment{ .start = start, .out = out };
    }

    fn buildAny(self: *NFABuilder) !Fragment {
        const start = try self.createState();
        const end = try self.createState();

        try self.states.items[start].transitions.append(Transition{
            .target = end,
            .condition = .{ .any = {} },
        });

        var out = std.ArrayList(usize).init(self.allocator);
        try out.append(end);

        return Fragment{ .start = start, .out = out };
    }

    fn buildCharClass(self: *NFABuilder, cc: CharClass) !Fragment {
        const start = try self.createState();
        const end = try self.createState();

        try self.states.items[start].transitions.append(Transition{
            .target = end,
            .condition = .{ .char_class = cc },
        });

        var out = std.ArrayList(usize).init(self.allocator);
        try out.append(end);

        return Fragment{ .start = start, .out = out };
    }

    fn buildConcat(self: *NFABuilder, left: *ASTNode, right: *ASTNode) !Fragment {
        var frag1 = try self.build(left);
        const frag2 = try self.build(right);

        // Connect frag1 out states to frag2 start
        for (frag1.out.items) |state_id| {
            try self.states.items[state_id].transitions.append(Transition{
                .target = frag2.start,
                .condition = .{ .epsilon = {} },
            });
        }
        frag1.out.deinit();

        return Fragment{ .start = frag1.start, .out = frag2.out };
    }

    fn buildAlternate(self: *NFABuilder, left: *ASTNode, right: *ASTNode) !Fragment {
        const frag1 = try self.build(left);
        const frag2 = try self.build(right);

        const start = try self.createState();

        try self.states.items[start].transitions.append(Transition{
            .target = frag1.start,
            .condition = .{ .epsilon = {} },
        });
        try self.states.items[start].transitions.append(Transition{
            .target = frag2.start,
            .condition = .{ .epsilon = {} },
        });

        var out = std.ArrayList(usize).init(self.allocator);
        try out.appendSlice(frag1.out.items);
        try out.appendSlice(frag2.out.items);

        return Fragment{ .start = start, .out = out };
    }

    fn buildStar(self: *NFABuilder, inner: *ASTNode) !Fragment {
        const frag = try self.build(inner);
        const start = try self.createState();

        try self.states.items[start].transitions.append(Transition{
            .target = frag.start,
            .condition = .{ .epsilon = {} },
        });

        for (frag.out.items) |state_id| {
            try self.states.items[state_id].transitions.append(Transition{
                .target = frag.start,
                .condition = .{ .epsilon = {} },
            });
        }

        var out = std.ArrayList(usize).init(self.allocator);
        try out.append(start);
        try out.appendSlice(frag.out.items);

        return Fragment{ .start = start, .out = out };
    }

    fn buildPlus(self: *NFABuilder, inner: *ASTNode) !Fragment {
        const frag = try self.build(inner);

        for (frag.out.items) |state_id| {
            try self.states.items[state_id].transitions.append(Transition{
                .target = frag.start,
                .condition = .{ .epsilon = {} },
            });
        }

        return frag;
    }

    fn buildQuestion(self: *NFABuilder, inner: *ASTNode) !Fragment {
        const frag = try self.build(inner);
        const start = try self.createState();

        try self.states.items[start].transitions.append(Transition{
            .target = frag.start,
            .condition = .{ .epsilon = {} },
        });

        var out = std.ArrayList(usize).init(self.allocator);
        try out.append(start);
        try out.appendSlice(frag.out.items);

        return Fragment{ .start = start, .out = out };
    }

    fn toNFA(self: *NFABuilder, frag: Fragment) !NFA {
        const accept = try self.createState();
        self.states.items[accept].is_accept = true;

        for (frag.out.items) |state_id| {
            try self.states.items[state_id].transitions.append(Transition{
                .target = accept,
                .condition = .{ .epsilon = {} },
            });
        }

        return NFA{
            .allocator = self.allocator,
            .states = try self.states.toOwnedSlice(),
            .start = frag.start,
            .accept = accept,
        };
    }
};

// =================================================================================
//                                    TESTS
// =================================================================================

test "Regex - literal match" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "hello");
    defer regex.deinit();

    try testing.expect(regex.match("hello"));
    try testing.expect(!regex.match("world"));
    try testing.expect(!regex.match("hello world"));
}

test "Regex - any character (.)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "h.llo");
    defer regex.deinit();

    try testing.expect(regex.match("hello"));
    try testing.expect(regex.match("hallo"));
    try testing.expect(regex.match("h9llo"));
    try testing.expect(!regex.match("hllo"));
}

test "Regex - star quantifier (*)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "ab*c");
    defer regex.deinit();

    try testing.expect(regex.match("ac"));
    try testing.expect(regex.match("abc"));
    try testing.expect(regex.match("abbc"));
    try testing.expect(regex.match("abbbc"));
    try testing.expect(!regex.match("bc"));
}

test "Regex - plus quantifier (+)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "ab+c");
    defer regex.deinit();

    try testing.expect(!regex.match("ac"));
    try testing.expect(regex.match("abc"));
    try testing.expect(regex.match("abbc"));
    try testing.expect(!regex.match("bc"));
}

test "Regex - question quantifier (?)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "ab?c");
    defer regex.deinit();

    try testing.expect(regex.match("ac"));
    try testing.expect(regex.match("abc"));
    try testing.expect(!regex.match("abbc"));
}

test "Regex - alternation (|)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "cat|dog");
    defer regex.deinit();

    try testing.expect(regex.match("cat"));
    try testing.expect(regex.match("dog"));
    try testing.expect(!regex.match("bird"));
}

test "Regex - character class" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "[abc]");
    defer regex.deinit();

    try testing.expect(regex.match("a"));
    try testing.expect(regex.match("b"));
    try testing.expect(regex.match("c"));
    try testing.expect(!regex.match("d"));
}

test "Regex - character range" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "[a-z]");
    defer regex.deinit();

    try testing.expect(regex.match("a"));
    try testing.expect(regex.match("m"));
    try testing.expect(regex.match("z"));
    try testing.expect(!regex.match("A"));
    try testing.expect(!regex.match("0"));
}

test "Regex - negated character class" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "[^0-9]");
    defer regex.deinit();

    try testing.expect(regex.match("a"));
    try testing.expect(regex.match("Z"));
    try testing.expect(!regex.match("5"));
}

test "Regex - digit class (\\d)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "\\d");
    defer regex.deinit();

    try testing.expect(regex.match("0"));
    try testing.expect(regex.match("5"));
    try testing.expect(regex.match("9"));
    try testing.expect(!regex.match("a"));
}

test "Regex - word class (\\w)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "\\w");
    defer regex.deinit();

    try testing.expect(regex.match("a"));
    try testing.expect(regex.match("Z"));
    try testing.expect(regex.match("0"));
    try testing.expect(regex.match("_"));
    try testing.expect(!regex.match("-"));
}

test "Regex - whitespace class (\\s)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "\\s");
    defer regex.deinit();

    try testing.expect(regex.match(" "));
    try testing.expect(regex.match("\t"));
    try testing.expect(regex.match("\n"));
    try testing.expect(!regex.match("a"));
}

test "Regex - find first match" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "world");
    defer regex.deinit();

    const text = "hello world";
    const match = regex.find(text);
    try testing.expect(match != null);
    try testing.expectEqual(@as(usize, 6), match.?.start);
    try testing.expectEqual(@as(usize, 11), match.?.end);
}

test "Regex - replace" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "cat");
    defer regex.deinit();

    const result = try regex.replace("cat and cat", "dog");
    defer allocator.free(result);

    try testing.expectEqualStrings("dog and dog", result);
}

test "Regex - complex pattern" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "[a-z]+@[a-z]+\\.[a-z]+");
    defer regex.deinit();

    try testing.expect(regex.match("user@example.com"));
    try testing.expect(!regex.match("invalid.email"));
}
