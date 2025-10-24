const std = @import("std");

/// Regular expression engine for Ion
pub const Regex = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    compiled: CompiledRegex,

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !*Regex {
        const regex = try allocator.create(Regex);

        const compiled = try compilePattern(allocator, pattern);

        regex.* = .{
            .allocator = allocator,
            .pattern = try allocator.dupe(u8, pattern),
            .compiled = compiled,
        };

        return regex;
    }

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.pattern);
        self.compiled.deinit();
        self.allocator.destroy(self);
    }

    /// Test if pattern matches the entire string
    pub fn isMatch(self: *Regex, text: []const u8) bool {
        var matcher = Matcher.init(self.allocator, &self.compiled, text);
        defer matcher.deinit();

        return matcher.matches() catch false;
    }

    /// Find first match in text
    pub fn find(self: *Regex, text: []const u8) ?Match {
        var matcher = Matcher.init(self.allocator, &self.compiled, text);
        defer matcher.deinit();

        return matcher.findNext() catch null;
    }

    /// Find all matches in text
    pub fn findAll(self: *Regex, text: []const u8) ![]Match {
        var matcher = Matcher.init(self.allocator, &self.compiled, text);
        defer matcher.deinit();

        var matches = std.ArrayList(Match).init(self.allocator);

        while (try matcher.findNext()) |match| {
            try matches.append(match);
        }

        return matches.toOwnedSlice();
    }

    /// Replace first match
    pub fn replace(self: *Regex, text: []const u8, replacement: []const u8) ![]u8 {
        if (self.find(text)) |match| {
            var result = std.ArrayList(u8).init(self.allocator);

            try result.appendSlice(text[0..match.start]);
            try result.appendSlice(replacement);
            try result.appendSlice(text[match.end..]);

            return result.toOwnedSlice();
        }

        return try self.allocator.dupe(u8, text);
    }

    /// Replace all matches
    pub fn replaceAll(self: *Regex, text: []const u8, replacement: []const u8) ![]u8 {
        const matches = try self.findAll(text);
        defer self.allocator.free(matches);

        if (matches.len == 0) {
            return try self.allocator.dupe(u8, text);
        }

        var result = std.ArrayList(u8).init(self.allocator);
        var last_end: usize = 0;

        for (matches) |match| {
            try result.appendSlice(text[last_end..match.start]);
            try result.appendSlice(replacement);
            last_end = match.end;
        }

        try result.appendSlice(text[last_end..]);

        return result.toOwnedSlice();
    }

    /// Split text by regex pattern
    pub fn split(self: *Regex, text: []const u8) ![][]const u8 {
        const matches = try self.findAll(text);
        defer self.allocator.free(matches);

        var parts = std.ArrayList([]const u8).init(self.allocator);
        var last_end: usize = 0;

        for (matches) |match| {
            try parts.append(text[last_end..match.start]);
            last_end = match.end;
        }

        try parts.append(text[last_end..]);

        return parts.toOwnedSlice();
    }
};

pub const Match = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

/// Compiled regular expression
const CompiledRegex = struct {
    allocator: std.mem.Allocator,
    instructions: []Instruction,

    pub fn deinit(self: *CompiledRegex) void {
        self.allocator.free(self.instructions);
    }
};

/// Regex instructions (simplified NFA)
const Instruction = union(enum) {
    Char: u8,
    AnyChar: void,
    Start: void,
    End: void,
    CharClass: CharClass,
    Repeat: RepeatInfo,
    Branch: BranchInfo,
    Capture: usize,
};

const CharClass = struct {
    chars: []const u8,
    negated: bool,
};

const RepeatInfo = struct {
    min: usize,
    max: ?usize, // null = unbounded
    instruction_index: usize,
};

const BranchInfo = struct {
    alternative: usize,
};

/// Pattern compiler
fn compilePattern(allocator: std.mem.Allocator, pattern: []const u8) !CompiledRegex {
    var instructions = std.ArrayList(Instruction).init(allocator);

    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];

        switch (c) {
            '.' => try instructions.append(.AnyChar),
            '^' => try instructions.append(.Start),
            '$' => try instructions.append(.End),
            '*' => {
                // Repeat previous 0 or more times
                try instructions.append(.{
                    .Repeat = .{
                        .min = 0,
                        .max = null,
                        .instruction_index = instructions.items.len - 1,
                    },
                });
            },
            '+' => {
                // Repeat previous 1 or more times
                try instructions.append(.{
                    .Repeat = .{
                        .min = 1,
                        .max = null,
                        .instruction_index = instructions.items.len - 1,
                    },
                });
            },
            '?' => {
                // Repeat previous 0 or 1 times
                try instructions.append(.{
                    .Repeat = .{
                        .min = 0,
                        .max = 1,
                        .instruction_index = instructions.items.len - 1,
                    },
                });
            },
            '[' => {
                // Character class
                i += 1;
                const class_start = i;
                while (i < pattern.len and pattern[i] != ']') : (i += 1) {}

                const negated = pattern[class_start] == '^';
                const chars_start = if (negated) class_start + 1 else class_start;

                try instructions.append(.{
                    .CharClass = .{
                        .chars = pattern[chars_start..i],
                        .negated = negated,
                    },
                });
            },
            '\\' => {
                // Escape sequence
                i += 1;
                if (i < pattern.len) {
                    const escaped = pattern[i];
                    try instructions.append(.{ .Char = escaped });
                }
            },
            else => {
                try instructions.append(.{ .Char = c });
            },
        }

        i += 1;
    }

    return CompiledRegex{
        .allocator = allocator,
        .instructions = try instructions.toOwnedSlice(),
    };
}

/// Pattern matcher
const Matcher = struct {
    allocator: std.mem.Allocator,
    regex: *const CompiledRegex,
    text: []const u8,
    position: usize,

    pub fn init(allocator: std.mem.Allocator, regex: *const CompiledRegex, text: []const u8) Matcher {
        return .{
            .allocator = allocator,
            .regex = regex,
            .text = text,
            .position = 0,
        };
    }

    pub fn deinit(self: *Matcher) void {
        _ = self;
    }

    pub fn matches(self: *Matcher) !bool {
        return self.matchAt(0) != null;
    }

    pub fn findNext(self: *Matcher) !?Match {
        while (self.position < self.text.len) {
            if (self.matchAt(self.position)) |end| {
                const match = Match{
                    .start = self.position,
                    .end = end,
                    .text = self.text[self.position..end],
                };
                self.position = end;
                return match;
            }
            self.position += 1;
        }
        return null;
    }

    fn matchAt(self: *Matcher, start: usize) ?usize {
        var pos = start;
        var inst_idx: usize = 0;

        while (inst_idx < self.regex.instructions.len) {
            const inst = self.regex.instructions[inst_idx];

            switch (inst) {
                .Char => |ch| {
                    if (pos >= self.text.len or self.text[pos] != ch) {
                        return null;
                    }
                    pos += 1;
                },
                .AnyChar => {
                    if (pos >= self.text.len) {
                        return null;
                    }
                    pos += 1;
                },
                .Start => {
                    if (pos != 0) {
                        return null;
                    }
                },
                .End => {
                    if (pos != self.text.len) {
                        return null;
                    }
                },
                .CharClass => |class| {
                    if (pos >= self.text.len) {
                        return null;
                    }

                    const ch = self.text[pos];
                    const found = std.mem.indexOfScalar(u8, class.chars, ch) != null;

                    if (found == class.negated) {
                        return null;
                    }

                    pos += 1;
                },
                .Repeat => |repeat| {
                    // Simplified repeat handling
                    var count: usize = 0;
                    const max = repeat.max orelse 999999;

                    while (count < max and pos < self.text.len) {
                        const old_pos = pos;
                        // Try to match the repeated instruction
                        const repeated_inst = self.regex.instructions[repeat.instruction_index];

                        if (!self.matchSingleInstruction(repeated_inst, &pos)) {
                            break;
                        }

                        count += 1;

                        if (pos == old_pos) break; // Prevent infinite loop
                    }

                    if (count < repeat.min) {
                        return null;
                    }
                },
                else => {},
            }

            inst_idx += 1;
        }

        return pos;
    }

    fn matchSingleInstruction(self: *Matcher, inst: Instruction, pos: *usize) bool {
        switch (inst) {
            .Char => |ch| {
                if (pos.* >= self.text.len or self.text[pos.*] != ch) {
                    return false;
                }
                pos.* += 1;
                return true;
            },
            .AnyChar => {
                if (pos.* >= self.text.len) {
                    return false;
                }
                pos.* += 1;
                return true;
            },
            .CharClass => |class| {
                if (pos.* >= self.text.len) {
                    return false;
                }

                const ch = self.text[pos.*];
                const found = std.mem.indexOfScalar(u8, class.chars, ch) != null;

                if (found == class.negated) {
                    return false;
                }

                pos.* += 1;
                return true;
            },
            else => return false,
        }
    }
};

/// Common regex patterns
pub const Patterns = struct {
    pub const EMAIL = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}";
    pub const URL = "https?://[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}(/[^\\s]*)?";
    pub const IPV4 = "\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}";
    pub const HEX_COLOR = "#[0-9a-fA-F]{6}";
    pub const DIGITS = "\\d+";
    pub const LETTERS = "[a-zA-Z]+";
    pub const ALPHANUMERIC = "[a-zA-Z0-9]+";
    pub const WHITESPACE = "\\s+";
};
