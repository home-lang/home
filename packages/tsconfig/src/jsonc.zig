//! JSONC parser — JSON with `//` line comments, `/* */` block comments,
//! and trailing commas. The format `tsconfig.json` actually uses (and
//! that VS Code calls "JSON with Comments").
//!
//! Per TS_PARITY_PLAN §2.2 ("JSON parsing with comments and trailing
//! commas (`tsconfig.json` is JSON-with-comments)").
//!
//! Self-contained: no dependency on the main `packages/json/`. The
//! tsconfig schema sits on top of this in `tsconfig.zig`.
//!
//! Behavior intentionally mirrors `tsc`'s permissive parser:
//!
//!   - Trailing commas in arrays and objects are accepted.
//!   - Single-line `//` and multi-line `/* */` comments are stripped.
//!   - Bare keys are *not* allowed (must be quoted strings, per JSON).
//!   - All standard JSON escape sequences in strings.
//!   - Numbers: leading minus, decimal, exponent — same as JSON proper.
//!     `tsconfig.json` doesn't use NaN / Infinity, so we don't either.

const std = @import("std");

pub const Value = union(enum) {
    null_,
    bool_: bool,
    number: f64,
    string: []const u8,
    array: []Value,
    object: Object,
    invalid: Invalid,

    pub const Object = struct {
        /// Keys and values held in parallel arrays. Order is preserved
        /// (matters for `extends` array order and for diagnostics).
        keys: [][]const u8,
        values: []Value,

        pub fn get(self: Object, key: []const u8) ?Value {
            for (self.keys, 0..) |k, i| {
                if (std.mem.eql(u8, k, key)) return self.values[i];
            }
            return null;
        }

        pub fn contains(self: Object, key: []const u8) bool {
            return self.get(key) != null;
        }
    };

    pub const Invalid = struct {
        pos: u32,
        line: u32,
        column: u32,
    };

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .bool_ => |b| b,
            else => null,
        };
    }

    pub fn asNumber(self: Value) ?f64 {
        return switch (self) {
            .number => |n| n,
            else => null,
        };
    }

    pub fn asArray(self: Value) ?[]Value {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asObject(self: Value) ?Object {
        return switch (self) {
            .object => |o| o,
            else => null,
        };
    }
};

pub const ParseError = error{
    UnexpectedCharacter,
    UnexpectedEof,
    UnterminatedString,
    InvalidNumber,
    InvalidEscape,
    DuplicateKey,
    OutOfMemory,
};

pub const Diagnostic = struct {
    pos: u32,
    line: u32,
    column: u32,
    message: []const u8,
};

const Parser = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    pos: u32,
    line: u32,
    line_start: u32,
    diags: *std.ArrayListUnmanaged(Diagnostic),
    diag_arena: std.mem.Allocator,
    gpa_for_diags: std.mem.Allocator,

    fn peek(self: *const Parser) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekAt(self: *const Parser, offset: u32) u8 {
        const p = self.pos + offset;
        if (p >= self.source.len) return 0;
        return self.source[p];
    }

    fn advance(self: *Parser) u8 {
        if (self.pos >= self.source.len) return 0;
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.line_start = self.pos;
        }
        return c;
    }

    fn report(self: *Parser, message: []const u8) void {
        const owned = self.diag_arena.dupe(u8, message) catch return;
        self.diags.append(self.gpa_for_diags, .{
            .pos = self.pos,
            .line = self.line,
            .column = self.pos - self.line_start,
            .message = owned,
        }) catch {};
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t', '\r', '\n' => _ = self.advance(),
                '/' => {
                    if (self.peekAt(1) == '/') {
                        // Line comment.
                        self.pos += 2;
                        while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
                    } else if (self.peekAt(1) == '*') {
                        // Block comment.
                        self.pos += 2;
                        while (self.pos + 1 < self.source.len) {
                            if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                                self.pos += 2;
                                break;
                            }
                            _ = self.advance();
                        }
                    } else return;
                },
                else => return,
            }
        }
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        if (self.pos >= self.source.len) {
            self.report("unexpected EOF");
            return error.UnexpectedEof;
        }
        const c = self.source[self.pos];
        return switch (c) {
            '{' => try self.parseObject(),
            '[' => try self.parseArray(),
            '"' => Value{ .string = try self.parseString() },
            't' => if (self.startsWith("true")) try self.parseBool() else Value{ .invalid = self.parseInvalidValue() },
            'f' => if (self.startsWith("false")) try self.parseBool() else Value{ .invalid = self.parseInvalidValue() },
            'n' => if (self.startsWith("null")) try self.parseNull() else Value{ .invalid = self.parseInvalidValue() },
            '-', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => Value{ .number = try self.parseNumber() },
            else => Value{ .invalid = self.parseInvalidValue() },
        };
    }

    fn startsWith(self: *const Parser, text: []const u8) bool {
        return self.pos + text.len <= self.source.len and
            std.mem.eql(u8, self.source[self.pos .. self.pos + text.len], text);
    }

    fn parseInvalidValue(self: *Parser) Value.Invalid {
        const start = Value.Invalid{
            .pos = self.pos,
            .line = self.line,
            .column = self.pos - self.line_start,
        };
        var depth: u32 = 0;
        var consumed_any = false;
        while (self.pos < self.source.len) {
            const c = self.peek();
            if (depth == 0 and (c == ',' or c == '}' or c == ']')) break;
            consumed_any = true;
            switch (c) {
                '"' => self.skipStringLiteral(),
                '\'' => self.skipSingleQuotedLiteral(),
                '/' => if (self.peekAt(1) == '/' or self.peekAt(1) == '*') {
                    self.skipWhitespace();
                } else {
                    _ = self.advance();
                },
                '(', '{', '[' => {
                    depth += 1;
                    _ = self.advance();
                },
                ')', '}', ']' => {
                    if (depth == 0) break;
                    depth -= 1;
                    _ = self.advance();
                },
                else => _ = self.advance(),
            }
        }
        if (!consumed_any and self.pos < self.source.len) _ = self.advance();
        return start;
    }

    fn skipStringLiteral(self: *Parser) void {
        if (self.peek() != '"') return;
        _ = self.advance();
        while (self.pos < self.source.len) {
            const c = self.advance();
            if (c == '\\') {
                _ = self.advance();
                continue;
            }
            if (c == '"') break;
        }
    }

    fn skipSingleQuotedLiteral(self: *Parser) void {
        if (self.peek() != '\'') return;
        _ = self.advance();
        while (self.pos < self.source.len) {
            const c = self.advance();
            if (c == '\\') {
                _ = self.advance();
                continue;
            }
            if (c == '\'') break;
        }
    }

    fn parseObject(self: *Parser) ParseError!Value {
        std.debug.assert(self.source[self.pos] == '{');
        self.pos += 1;

        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer keys.deinit(self.arena);
        var values: std.ArrayListUnmanaged(Value) = .empty;
        errdefer values.deinit(self.arena);

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) {
                self.report("unterminated object");
                return error.UnexpectedEof;
            }
            if (self.source[self.pos] == '}') {
                self.pos += 1;
                break;
            }

            const key = try self.parseString();
            // Duplicate-key check (last-writer-wins is also acceptable;
            // we error to match strict JSON).
            for (keys.items) |existing| {
                if (std.mem.eql(u8, existing, key)) {
                    self.report("duplicate object key");
                    return error.DuplicateKey;
                }
            }

            self.skipWhitespace();
            if (self.peek() != ':') {
                self.report("expected ':' after object key");
                return error.UnexpectedCharacter;
            }
            self.pos += 1;

            const v = try self.parseValue();
            try keys.append(self.arena, key);
            try values.append(self.arena, v);

            self.skipWhitespace();
            if (self.peek() == ',') {
                self.pos += 1;
                self.skipWhitespace();
                if (self.peek() == '}') {
                    // Trailing comma — accept per JSONC.
                    self.pos += 1;
                    break;
                }
                continue;
            }
            if (self.peek() == '}') {
                self.pos += 1;
                break;
            }
            self.report("expected ',' or '}' in object");
            return error.UnexpectedCharacter;
        }

        return Value{ .object = .{
            .keys = try keys.toOwnedSlice(self.arena),
            .values = try values.toOwnedSlice(self.arena),
        } };
    }

    fn parseArray(self: *Parser) ParseError!Value {
        std.debug.assert(self.source[self.pos] == '[');
        self.pos += 1;

        var items: std.ArrayListUnmanaged(Value) = .empty;
        errdefer items.deinit(self.arena);

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) {
                self.report("unterminated array");
                return error.UnexpectedEof;
            }
            if (self.source[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            const v = try self.parseValue();
            try items.append(self.arena, v);
            self.skipWhitespace();
            if (self.peek() == ',') {
                self.pos += 1;
                self.skipWhitespace();
                if (self.peek() == ']') {
                    self.pos += 1;
                    break;
                }
                continue;
            }
            if (self.peek() == ']') {
                self.pos += 1;
                break;
            }
            self.report("expected ',' or ']' in array");
            return error.UnexpectedCharacter;
        }
        return Value{ .array = try items.toOwnedSlice(self.arena) };
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        self.skipWhitespace();
        if (self.peek() != '"') {
            self.report("expected '\"'");
            return error.UnexpectedCharacter;
        }
        self.pos += 1;
        const start = self.pos;

        var has_escape = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                if (!has_escape) {
                    const slice = self.source[start..self.pos];
                    self.pos += 1;
                    // Borrow from source — JSONC strings without
                    // escapes alias the source.
                    return slice;
                }
                // Build the unescaped string.
                const slice = self.source[start..self.pos];
                self.pos += 1;
                return try unescape(self.arena, slice);
            }
            if (c == '\\') {
                has_escape = true;
                self.pos += 2;
                continue;
            }
            if (c == '\n' or c == '\r') {
                self.report("unterminated string");
                return error.UnterminatedString;
            }
            self.pos += 1;
        }
        self.report("unterminated string at EOF");
        return error.UnterminatedString;
    }

    fn parseBool(self: *Parser) ParseError!Value {
        if (self.pos + 4 <= self.source.len and std.mem.eql(u8, self.source[self.pos .. self.pos + 4], "true")) {
            self.pos += 4;
            return Value{ .bool_ = true };
        }
        if (self.pos + 5 <= self.source.len and std.mem.eql(u8, self.source[self.pos .. self.pos + 5], "false")) {
            self.pos += 5;
            return Value{ .bool_ = false };
        }
        self.report("invalid boolean");
        return error.UnexpectedCharacter;
    }

    fn parseNull(self: *Parser) ParseError!Value {
        if (self.pos + 4 <= self.source.len and std.mem.eql(u8, self.source[self.pos .. self.pos + 4], "null")) {
            self.pos += 4;
            return Value{ .null_ = {} };
        }
        self.report("invalid null");
        return error.UnexpectedCharacter;
    }

    fn parseNumber(self: *Parser) ParseError!f64 {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        // Integer part
        if (self.peek() == '0') {
            self.pos += 1;
        } else if (isDigit(self.peek())) {
            while (isDigit(self.peek())) self.pos += 1;
        } else {
            self.report("expected digit");
            return error.InvalidNumber;
        }
        // Fraction
        if (self.peek() == '.') {
            self.pos += 1;
            if (!isDigit(self.peek())) {
                self.report("digit expected after decimal point");
                return error.InvalidNumber;
            }
            while (isDigit(self.peek())) self.pos += 1;
        }
        // Exponent
        if (self.peek() == 'e' or self.peek() == 'E') {
            self.pos += 1;
            if (self.peek() == '+' or self.peek() == '-') self.pos += 1;
            if (!isDigit(self.peek())) {
                self.report("digit expected in exponent");
                return error.InvalidNumber;
            }
            while (isDigit(self.peek())) self.pos += 1;
        }
        const slice = self.source[start..self.pos];
        return std.fmt.parseFloat(f64, slice) catch error.InvalidNumber;
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn unescape(arena: std.mem.Allocator, raw: []const u8) ParseError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c != '\\') {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= raw.len) return error.InvalidEscape;
        const esc = raw[i];
        i += 1;
        switch (esc) {
            '"' => try out.append(arena, '"'),
            '\\' => try out.append(arena, '\\'),
            '/' => try out.append(arena, '/'),
            'n' => try out.append(arena, '\n'),
            't' => try out.append(arena, '\t'),
            'r' => try out.append(arena, '\r'),
            'b' => try out.append(arena, 0x08),
            'f' => try out.append(arena, 0x0C),
            'u' => {
                if (i + 4 > raw.len) return error.InvalidEscape;
                const hex = raw[i .. i + 4];
                i += 4;
                const cp = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidEscape;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEscape;
                try out.appendSlice(arena, buf[0..len]);
            },
            else => return error.InvalidEscape,
        }
    }
    return try out.toOwnedSlice(arena);
}

/// Result of a parse, holding the value tree plus any diagnostics
/// collected along the way. The arena owns all allocations; drop the
/// arena to free everything.
pub const ParseResult = struct {
    value: Value,
    diagnostics: []const Diagnostic,
};

/// Parse a JSONC document. Allocates into `arena`; the returned value
/// borrows from `source` for non-escaped strings, and from `arena` for
/// everything else.
pub fn parse(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
) ParseError!ParseResult {
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    errdefer diags.deinit(gpa);

    var p = Parser{
        .arena = arena,
        .source = source,
        .pos = 0,
        .line = 1,
        .line_start = 0,
        .diags = &diags,
        .diag_arena = arena,
        .gpa_for_diags = gpa,
    };

    p.skipWhitespace();
    const v = try p.parseValue();
    p.skipWhitespace();
    if (p.pos != source.len) {
        p.report("Unexpected token.");
        _ = p.parseInvalidValue();
        p.skipWhitespace();
    }
    return .{
        .value = v,
        .diagnostics = try diags.toOwnedSlice(gpa),
    };
}

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

fn parseString(source: []const u8, arena: std.mem.Allocator) !Value {
    const r = try parse(t.allocator, arena, source);
    defer t.allocator.free(r.diagnostics);
    return r.value;
}

test "jsonc: empty object" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString("{}", arena.allocator());
    try t.expectEqual(@as(usize, 0), v.asObject().?.keys.len);
}

test "jsonc: simple object with strings and numbers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{"name": "home", "version": 1.5}
    , arena.allocator());
    const o = v.asObject().?;
    try t.expectEqualStrings("home", o.get("name").?.asString().?);
    try t.expectApproxEqRel(@as(f64, 1.5), o.get("version").?.asNumber().?, 1e-9);
}

test "jsonc: line comments are skipped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\// header
        \\{ // intro
        \\  "a": 1, // trailing
        \\  "b": 2  // last
        \\}
    , arena.allocator());
    const o = v.asObject().?;
    try t.expectApproxEqRel(@as(f64, 1), o.get("a").?.asNumber().?, 1e-9);
    try t.expectApproxEqRel(@as(f64, 2), o.get("b").?.asNumber().?, 1e-9);
}

test "jsonc: block comments are skipped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{
        \\  /* multi
        \\     line */
        \\  "key": "value"
        \\}
    , arena.allocator());
    try t.expectEqualStrings("value", v.asObject().?.get("key").?.asString().?);
}

test "jsonc: trailing commas in objects and arrays" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{"a": 1, "b": [1, 2, 3,],}
    , arena.allocator());
    const arr = v.asObject().?.get("b").?.asArray().?;
    try t.expectEqual(@as(usize, 3), arr.len);
    try t.expectApproxEqRel(@as(f64, 1), arr[0].asNumber().?, 1e-9);
    try t.expectApproxEqRel(@as(f64, 3), arr[2].asNumber().?, 1e-9);
}

test "jsonc: trailing top-level content records TS1012-shaped diagnostic" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try parse(t.allocator, arena.allocator(), "{} {}");
    defer t.allocator.free(r.diagnostics);
    try t.expectEqual(@as(usize, 1), r.diagnostics.len);
    try t.expectEqual(@as(u32, 3), r.diagnostics[0].pos);
    try t.expectEqual(@as(u32, 1), r.diagnostics[0].line);
    try t.expectEqual(@as(u32, 3), r.diagnostics[0].column);
    try t.expectEqualStrings("Unexpected token.", r.diagnostics[0].message);
}

test "jsonc: nested objects" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{
        \\  "compilerOptions": { "strict": true, "target": "es2024" }
        \\}
    , arena.allocator());
    const co = v.asObject().?.get("compilerOptions").?.asObject().?;
    try t.expectEqual(@as(?bool, true), co.get("strict").?.asBool().?);
    try t.expectEqualStrings("es2024", co.get("target").?.asString().?);
}

test "jsonc: arrays of strings (e.g. include / exclude)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{ "include": ["src/**/*", "test/**/*"], "exclude": ["node_modules"] }
    , arena.allocator());
    const inc = v.asObject().?.get("include").?.asArray().?;
    try t.expectEqualStrings("src/**/*", inc[0].asString().?);
    try t.expectEqualStrings("test/**/*", inc[1].asString().?);
    const exc = v.asObject().?.get("exclude").?.asArray().?;
    try t.expectEqualStrings("node_modules", exc[0].asString().?);
}

test "jsonc: booleans and null" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{ "yes": true, "no": false, "nada": null }
    , arena.allocator());
    const o = v.asObject().?;
    try t.expectEqual(true, o.get("yes").?.asBool().?);
    try t.expectEqual(false, o.get("no").?.asBool().?);
    try t.expect(o.get("nada").? == .null_);
}

test "jsonc: string escapes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{ "msg": "line1\nline2\t\"quoted\"" }
    , arena.allocator());
    const s = v.asObject().?.get("msg").?.asString().?;
    try t.expectEqualStrings("line1\nline2\t\"quoted\"", s);
}

test "jsonc: unicode escapes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{ "u": "é" }
    , arena.allocator());
    try t.expectEqualStrings("é", v.asObject().?.get("u").?.asString().?);
}

test "jsonc: numbers — integer / decimal / exponent / negative" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{ "i": 42, "f": 3.14, "e": 1e10, "n": -5, "ne": -1.5e-2 }
    , arena.allocator());
    const o = v.asObject().?;
    try t.expectApproxEqRel(@as(f64, 42), o.get("i").?.asNumber().?, 1e-9);
    try t.expectApproxEqRel(@as(f64, 3.14), o.get("f").?.asNumber().?, 1e-9);
    try t.expectApproxEqRel(@as(f64, 1e10), o.get("e").?.asNumber().?, 1e-9);
    try t.expectApproxEqRel(@as(f64, -5), o.get("n").?.asNumber().?, 1e-9);
    try t.expectApproxEqRel(@as(f64, -1.5e-2), o.get("ne").?.asNumber().?, 1e-9);
}

test "jsonc: duplicate keys are rejected" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.DuplicateKey, parseString(
        \\{"a": 1, "a": 2}
    , arena.allocator()));
}

test "jsonc: unterminated string is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.UnterminatedString, parseString(
        \\{"k": "oops
    , arena.allocator()));
}

test "jsonc: trailing content is reported and recovered" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{} {}
    , arena.allocator());
    try t.expectEqual(@as(usize, 0), v.asObject().?.keys.len);
}

test "jsonc: invalid property values recover as sentinel values" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{"a": undefined, "b": [function() {}, 1]}
    , arena.allocator());
    const root = v.asObject().?;
    try t.expect(root.get("a").? == .invalid);
    const arr = root.get("b").?.asArray().?;
    try t.expect(arr[0] == .invalid);
    try t.expectApproxEqRel(@as(f64, 1), arr[1].asNumber().?, 1e-9);
}

test "jsonc: real tsconfig fragment" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parseString(
        \\{
        \\  // minimal home tsconfig
        \\  "compilerOptions": {
        \\    "target": "es2024",
        \\    "module": "esnext",
        \\    "strict": true,
        \\    "skipLibCheck": true,
        \\    "paths": {
        \\      "@/*": ["src/*"]
        \\    }
        \\  },
        \\  "include": ["src/**/*"],
        \\  "exclude": ["node_modules", "dist"],
        \\}
    , arena.allocator());
    const root = v.asObject().?;
    const co = root.get("compilerOptions").?.asObject().?;
    try t.expectEqualStrings("es2024", co.get("target").?.asString().?);
    try t.expectEqual(true, co.get("strict").?.asBool().?);
    const paths = co.get("paths").?.asObject().?;
    const at_slash = paths.get("@/*").?.asArray().?;
    try t.expectEqualStrings("src/*", at_slash[0].asString().?);
}
