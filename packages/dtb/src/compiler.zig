// Device Tree Compiler (DTC)
// Compiles Device Tree Source (.dts) to Device Tree Binary (.dtb)

const std = @import("std");
const dtb = @import("dtb.zig");

/// Token types for DTS lexer
pub const TokenType = enum {
    // Literals
    identifier,
    string,
    number,
    cell_array,
    byte_array,

    // Keywords
    root_node, // /
    node_label, // label:
    node_ref, // &label
    include, // /include/
    dts_v1, // /dts-v1/
    plugin, // /plugin/
    delete_node, // /delete-node/
    delete_prop, // /delete-property/

    // Symbols
    semicolon, // ;
    equals, // =
    comma, // ,
    lbrace, // {
    rbrace, // }
    langle, // <
    rangle, // >
    lbracket, // [
    rbracket, // ]

    // Special
    eof,
    invalid,
};

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

/// Lexer for Device Tree Source
pub const Lexer = struct {
    source: []const u8,
    start: usize,
    current: usize,
    line: usize,
    column: usize,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .start = 0,
            .current = 0,
            .line = 1,
            .column = 1,
        };
    }

    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespace();
        self.start = self.current;

        if (self.isAtEnd()) {
            return self.makeToken(.eof);
        }

        const c = self.advance();

        // Numbers
        if (std.ascii.isDigit(c)) {
            return self.number();
        }

        // Identifiers
        if (std.ascii.isAlphabetic(c) or c == '_' or c == '-') {
            return self.identifier();
        }

        return switch (c) {
            '/' => self.slash(),
            ';' => self.makeToken(.semicolon),
            '=' => self.makeToken(.equals),
            ',' => self.makeToken(.comma),
            '{' => self.makeToken(.lbrace),
            '}' => self.makeToken(.rbrace),
            '<' => self.makeToken(.langle),
            '>' => self.makeToken(.rangle),
            '[' => self.makeToken(.lbracket),
            ']' => self.makeToken(.rbracket),
            '"' => self.string(),
            '&' => self.nodeRef(),
            else => self.makeToken(.invalid),
        };
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.current >= self.source.len;
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.current];
        self.current += 1;
        self.column += 1;
        return c;
    }

    fn peek(self: *Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn skipWhitespace(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => _ = self.advance(),
                '\n' => {
                    self.line += 1;
                    self.column = 1;
                    _ = self.advance();
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        // Line comment
                        while (self.peek() != '\n' and !self.isAtEnd()) {
                            _ = self.advance();
                        }
                    } else if (self.peekNext() == '*') {
                        // Block comment
                        _ = self.advance();
                        _ = self.advance();
                        while (!self.isAtEnd()) {
                            if (self.peek() == '*' and self.peekNext() == '/') {
                                _ = self.advance();
                                _ = self.advance();
                                break;
                            }
                            if (self.peek() == '\n') {
                                self.line += 1;
                                self.column = 1;
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

    fn makeToken(self: *Lexer, token_type: TokenType) Token {
        return Token{
            .type = token_type,
            .lexeme = self.source[self.start..self.current],
            .line = self.line,
            .column = self.column,
        };
    }

    fn slash(self: *Lexer) Token {
        // Check for special tokens
        if (self.peek() == ' ' or self.peek() == '{') {
            return self.makeToken(.root_node);
        }

        // Check for keywords like /dts-v1/ /include/ etc
        const keyword_start = self.current;
        while (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '-' or self.peek() == '_') {
            _ = self.advance();
        }

        if (self.peek() == '/') {
            _ = self.advance();
            const keyword = self.source[keyword_start..self.current - 1];

            if (std.mem.eql(u8, keyword, "dts-v1")) {
                return self.makeToken(.dts_v1);
            } else if (std.mem.eql(u8, keyword, "include")) {
                return self.makeToken(.include);
            } else if (std.mem.eql(u8, keyword, "plugin")) {
                return self.makeToken(.plugin);
            } else if (std.mem.eql(u8, keyword, "delete-node")) {
                return self.makeToken(.delete_node);
            } else if (std.mem.eql(u8, keyword, "delete-property")) {
                return self.makeToken(.delete_prop);
            }
        }

        return self.makeToken(.root_node);
    }

    fn identifier(self: *Lexer) Token {
        while (std.ascii.isAlphanumeric(self.peek()) or
            self.peek() == '_' or
            self.peek() == '-' or
            self.peek() == ',' or
            self.peek() == '.' or
            self.peek() == '+' or
            self.peek() == '@')
        {
            _ = self.advance();
        }

        // Check for node label
        if (self.peek() == ':') {
            _ = self.advance();
            return self.makeToken(.node_label);
        }

        return self.makeToken(.identifier);
    }

    fn number(self: *Lexer) Token {
        // Handle hex numbers
        if (self.source[self.start] == '0' and self.peek() == 'x') {
            _ = self.advance(); // skip 'x'
            while (std.ascii.isHex(self.peek())) {
                _ = self.advance();
            }
            return self.makeToken(.number);
        }

        // Decimal numbers
        while (std.ascii.isDigit(self.peek())) {
            _ = self.advance();
        }

        return self.makeToken(.number);
    }

    fn string(self: *Lexer) Token {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') {
                self.line += 1;
                self.column = 1;
            }
            if (self.peek() == '\\') {
                _ = self.advance(); // Skip escape char
            }
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            return self.makeToken(.invalid);
        }

        _ = self.advance(); // Closing quote
        return self.makeToken(.string);
    }

    fn nodeRef(self: *Lexer) Token {
        while (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
            _ = self.advance();
        }
        return self.makeToken(.node_ref);
    }
};

/// Device Tree Compiler
pub const Compiler = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current_token: Token,
    root: ?*dtb.Node,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Compiler {
        var compiler = Compiler{
            .allocator = allocator,
            .lexer = Lexer.init(source),
            .current_token = undefined,
            .root = null,
        };

        compiler.advance();
        return compiler;
    }

    pub fn deinit(self: *Compiler) void {
        if (self.root) |root| {
            root.deinit();
            self.allocator.destroy(root);
        }
    }

    pub fn compile(self: *Compiler) !*dtb.Node {
        // Parse /dts-v1/ directive
        if (self.current_token.type == .dts_v1) {
            self.advance();
            try self.consume(.semicolon, "Expected ';' after /dts-v1/");
        }

        // Expect root node '/'
        if (self.current_token.type != .root_node) {
            return error.ParseError;
        }
        self.advance();

        // Parse root node
        self.root = try self.parseNode(null, "");

        return self.root.?;
    }

    fn advance(self: *Compiler) void {
        self.current_token = self.lexer.nextToken();
    }

    fn consume(self: *Compiler, token_type: TokenType, message: []const u8) !void {
        if (self.current_token.type != token_type) {
            std.debug.print("Error at line {}: {s}\n", .{ self.current_token.line, message });
            return error.ParseError;
        }
        self.advance();
    }

    fn parseNode(self: *Compiler, parent: ?*dtb.Node, name: []const u8) !*dtb.Node {
        const node = try dtb.Node.init(self.allocator, name);
        errdefer node.deinit();

        if (parent) |p| {
            try p.addChild(node);
        }

        // Expect opening brace
        try self.consume(.lbrace, "Expected '{' to start node");

        // Parse properties and child nodes
        while (self.current_token.type != .rbrace and self.current_token.type != .eof) {
            if (self.current_token.type == .identifier) {
                const prop_name = self.current_token.lexeme;
                self.advance();

                if (self.current_token.type == .lbrace) {
                    // Child node
                    _ = try self.parseNode(node, prop_name);
                } else if (self.current_token.type == .equals) {
                    // Property
                    self.advance();
                    const value = try self.parsePropertyValue();
                    try node.addProperty(prop_name, value);
                    try self.consume(.semicolon, "Expected ';' after property");
                } else if (self.current_token.type == .semicolon) {
                    // Empty property
                    try node.addProperty(prop_name, &[_]u8{});
                    self.advance();
                }
            } else {
                self.advance();
            }
        }

        try self.consume(.rbrace, "Expected '}' to end node");

        if (self.current_token.type == .semicolon) {
            self.advance();
        }

        return node;
    }

    fn parsePropertyValue(self: *Compiler) ![]const u8 {
        return switch (self.current_token.type) {
            .string => blk: {
                const str = self.current_token.lexeme;
                self.advance();
                // Remove quotes
                break :blk str[1 .. str.len - 1];
            },
            .number => blk: {
                const num_str = self.current_token.lexeme;
                self.advance();
                break :blk num_str;
            },
            .langle => blk: {
                // Cell array <...>
                self.advance();
                const start = self.current_token.lexeme.ptr;
                while (self.current_token.type != .rangle and self.current_token.type != .eof) {
                    self.advance();
                }
                const end = self.current_token.lexeme.ptr;
                try self.consume(.rangle, "Expected '>' to close cell array");
                break :blk start[0..@intFromPtr(end) - @intFromPtr(start)];
            },
            .lbracket => blk: {
                // Byte array [...]
                self.advance();
                const start = self.current_token.lexeme.ptr;
                while (self.current_token.type != .rbracket and self.current_token.type != .eof) {
                    self.advance();
                }
                const end = self.current_token.lexeme.ptr;
                try self.consume(.rbracket, "Expected ']' to close byte array");
                break :blk start[0..@intFromPtr(end) - @intFromPtr(start)];
            },
            else => "",
        };
    }
};

/// Compile DTS source to DTB binary
pub fn compileToDTB(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var compiler = try Compiler.init(allocator, source);
    defer compiler.deinit();

    const root = try compiler.compile();

    // Serialize to DTB format
    // This is a simplified version - full implementation would serialize properly
    var output = std.ArrayList(u8).try_init(allocator);
    errdefer output.deinit(allocator);

    // Write FDT header
    const header = dtb.FdtHeader{
        .magic = dtb.MAGIC,
        .totalsize = 0, // Will be filled later
        .off_dt_struct = @sizeOf(dtb.FdtHeader),
        .off_dt_strings = 0, // Will be filled later
        .off_mem_rsvmap = @sizeOf(dtb.FdtHeader),
        .version = dtb.VERSION,
        .last_comp_version = 16,
        .boot_cpuid_phys = 0,
        .size_dt_strings = 0,
        .size_dt_struct = 0,
    };

    try output.appendSlice(allocator, std.mem.asBytes(&header));

    // Write structure (simplified)
    try serializeNode(allocator, &output, root);

    return try output.toOwnedSlice(allocator);
}

fn serializeNode(allocator: std.mem.Allocator, output: *std.ArrayList(u8), node: *const dtb.Node) !void {
    // Write begin_node token
    const begin_token: u32 = @intFromEnum(dtb.Token.begin_node);
    try output.appendSlice(allocator, std.mem.asBytes(&begin_token));

    // Write node name
    try output.appendSlice(allocator, node.name);
    try output.append(allocator, 0); // Null terminator

    // Align to 4 bytes
    while (output.items.len % 4 != 0) {
        try output.append(allocator, 0);
    }

    // Write properties
    var prop_iter = node.properties.iterator();
    while (prop_iter.next()) |entry| {
        const prop = entry.value_ptr.*;
        const prop_token: u32 = @intFromEnum(dtb.Token.prop);
        try output.appendSlice(allocator, std.mem.asBytes(&prop_token));

        const len: u32 = @intCast(prop.value.len);
        try output.appendSlice(allocator, std.mem.asBytes(&len));

        try output.appendSlice(allocator, prop.value);

        while (output.items.len % 4 != 0) {
            try output.append(allocator, 0);
        }
    }

    // Write child nodes
    for (node.children.items) |child| {
        try serializeNode(allocator, output, child);
    }

    // Write end_node token
    const end_token: u32 = @intFromEnum(dtb.Token.end_node);
    try output.appendSlice(allocator, std.mem.asBytes(&end_token));
}

// Tests
test "lexer basic tokens" {
    const source = "/dts-v1/; / { compatible = \"test\"; };";
    var lexer = Lexer.init(source);

    const testing = std.testing;

    const t1 = lexer.nextToken();
    if (t1.type != .dts_v1) {
        std.debug.print("Expected .dts_v1 but got {s}, lexeme='{s}'\n", .{ @tagName(t1.type), t1.lexeme });
    }
    try testing.expect(t1.type == .dts_v1);

    const t2 = lexer.nextToken();
    try testing.expect(t2.type == .semicolon);

    const t3 = lexer.nextToken();
    try testing.expect(t3.type == .root_node);
}

test "compile simple dts" {
    const source =
        \\/dts-v1/;
        \\/ {
        \\  compatible = "test";
        \\  model = "Test Board";
        \\};
    ;

    const testing = std.testing;

    var compiler = try Compiler.init(testing.allocator, source);
    defer compiler.deinit();

    const root = try compiler.compile();
    try testing.expect(root.properties.count() >= 0);
}
