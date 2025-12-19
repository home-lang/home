// Literal Types for Home Type System
//
// Literal types for exact value typing and template literals.

const std = @import("std");
const Type = @import("type_system.zig").Type;

// ============================================================================
// Literal Types
// ============================================================================

/// Literal types for exact value typing
pub const LiteralType = union(enum) {
    /// String literal type: "hello"
    string: []const u8,
    /// Integer literal type: 42
    integer: i64,
    /// Float literal type: 3.14
    float: f64,
    /// Boolean literal type: true/false
    boolean: bool,
    /// Null literal type
    null_type,
    /// Undefined literal type
    undefined_type,

    pub fn stringLiteral(value: []const u8) LiteralType {
        return .{ .string = value };
    }

    pub fn integerLiteral(value: i64) LiteralType {
        return .{ .integer = value };
    }

    pub fn floatLiteral(value: f64) LiteralType {
        return .{ .float = value };
    }

    pub fn booleanLiteral(value: bool) LiteralType {
        return .{ .boolean = value };
    }

    /// Check if two literal types are equal
    pub fn eql(self: LiteralType, other: LiteralType) bool {
        return switch (self) {
            .string => |s| if (other == .string) std.mem.eql(u8, s, other.string) else false,
            .integer => |i| if (other == .integer) i == other.integer else false,
            .float => |f| if (other == .float) f == other.float else false,
            .boolean => |b| if (other == .boolean) b == other.boolean else false,
            .null_type => other == .null_type,
            .undefined_type => other == .undefined_type,
        };
    }
};

// ============================================================================
// Template Literal Types
// ============================================================================

/// Template literal type: `hello ${string}`
pub const TemplateLiteralType = struct {
    /// Parts of the template (alternating literals and type placeholders)
    parts: []const Part,

    pub const Part = union(enum) {
        /// Literal string part
        literal: []const u8,
        /// Type placeholder
        type_placeholder: *const Type,
    };

    pub fn init(parts: []const Part) TemplateLiteralType {
        return .{ .parts = parts };
    }

    /// Check if a string matches this template
    pub fn matches(self: *const TemplateLiteralType, value: []const u8) bool {
        var pos: usize = 0;

        for (self.parts) |part| {
            switch (part) {
                .literal => |lit| {
                    if (!std.mem.startsWith(u8, value[pos..], lit)) {
                        return false;
                    }
                    pos += lit.len;
                },
                .type_placeholder => |ty| {
                    // For type placeholders, we need to find where the next literal starts
                    // and check if the substring is valid for the type
                    _ = ty; // Type checking would go here
                    // Simplified: accept any substring
                },
            }
        }

        return pos == value.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "literal type - string equality" {
    const lit1 = LiteralType{ .string = "hello" };
    const lit2 = LiteralType{ .string = "hello" };
    const lit3 = LiteralType{ .string = "world" };

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "literal type - integer equality" {
    const lit1 = LiteralType.integerLiteral(42);
    const lit2 = LiteralType.integerLiteral(42);
    const lit3 = LiteralType.integerLiteral(100);

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "literal type - float equality" {
    const lit1 = LiteralType.floatLiteral(3.14);
    const lit2 = LiteralType.floatLiteral(3.14);
    const lit3 = LiteralType.floatLiteral(2.71);

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "literal type - boolean equality" {
    const lit1 = LiteralType.booleanLiteral(true);
    const lit2 = LiteralType.booleanLiteral(true);
    const lit3 = LiteralType.booleanLiteral(false);

    try std.testing.expect(lit1.eql(lit2));
    try std.testing.expect(!lit1.eql(lit3));
}

test "literal type - null and undefined" {
    const null1 = LiteralType{ .null_type = {} };
    const null2 = LiteralType{ .null_type = {} };
    const undef = LiteralType{ .undefined_type = {} };

    try std.testing.expect(null1.eql(null2));
    try std.testing.expect(!null1.eql(undef));
}

test "literal type - cross-type inequality" {
    const str = LiteralType.stringLiteral("42");
    const int = LiteralType.integerLiteral(42);

    try std.testing.expect(!str.eql(int));
}

test "template literal type - init" {
    const allocator = std.testing.allocator;

    const str_type = try allocator.create(Type);
    defer allocator.destroy(str_type);
    str_type.* = Type.String;

    const parts = [_]TemplateLiteralType.Part{
        .{ .literal = "hello_" },
        .{ .type_placeholder = str_type },
    };
    const template = TemplateLiteralType.init(&parts);
    try std.testing.expectEqual(@as(usize, 2), template.parts.len);
}

test "edge case - literal type with empty string" {
    const lit1 = LiteralType.stringLiteral("");
    const lit2 = LiteralType.stringLiteral("");
    try std.testing.expect(lit1.eql(lit2));
}

test "edge case - literal type with max i64" {
    const lit1 = LiteralType.integerLiteral(std.math.maxInt(i64));
    const lit2 = LiteralType.integerLiteral(std.math.maxInt(i64));
    try std.testing.expect(lit1.eql(lit2));
}

test "edge case - literal type with min i64" {
    const lit1 = LiteralType.integerLiteral(std.math.minInt(i64));
    const lit2 = LiteralType.integerLiteral(std.math.minInt(i64));
    try std.testing.expect(lit1.eql(lit2));
}

test "edge case - literal type with infinity" {
    const lit1 = LiteralType.floatLiteral(std.math.inf(f64));
    const lit2 = LiteralType.floatLiteral(std.math.inf(f64));
    try std.testing.expect(lit1.eql(lit2));
}

test "edge case - literal type with negative infinity" {
    const lit1 = LiteralType.floatLiteral(-std.math.inf(f64));
    const lit2 = LiteralType.floatLiteral(-std.math.inf(f64));
    try std.testing.expect(lit1.eql(lit2));
}
