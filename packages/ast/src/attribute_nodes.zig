const std = @import("std");
const ast = @import("ast.zig");
const Expr = ast.Expr;

/// Represents an attribute with optional arguments
/// Examples: @test, @inline, @deprecated("Use newFunc instead"), @export("c_name")
pub const Attribute = struct {
    name: []const u8,
    args: []const *Expr, // Attribute arguments (e.g., strings, numbers)

    pub fn init(name: []const u8, args: []const *Expr) Attribute {
        return .{
            .name = name,
            .args = args,
        };
    }

    pub fn deinit(self: *Attribute, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.args) |arg| {
            allocator.destroy(arg);
        }
        allocator.free(self.args);
    }

    /// Check if this is a specific attribute by name
    pub fn isNamed(self: Attribute, name: []const u8) bool {
        return std.mem.eql(u8, self.name, name);
    }

    /// Get the first argument as a string literal if it exists
    pub fn getStringArg(self: Attribute, index: usize) ?[]const u8 {
        if (index >= self.args.len) return null;
        const arg = self.args[index];
        return switch (arg.*) {
            .StringLiteral => |lit| lit.value,
            else => null,
        };
    }
};

/// Collection of attributes attached to a declaration
pub const AttributeList = struct {
    attributes: []const Attribute,

    pub fn init(attributes: []const Attribute) AttributeList {
        return .{ .attributes = attributes };
    }

    pub fn deinit(self: *AttributeList, allocator: std.mem.Allocator) void {
        for (self.attributes) |*attr| {
            // Note: we don't call deinit on individual attributes here
            // because they might be owned by the slice
            _ = attr;
        }
        allocator.free(self.attributes);
    }

    /// Check if any attribute has the given name
    pub fn has(self: AttributeList, name: []const u8) bool {
        for (self.attributes) |attr| {
            if (attr.isNamed(name)) return true;
        }
        return false;
    }

    /// Find an attribute by name
    pub fn find(self: AttributeList, name: []const u8) ?Attribute {
        for (self.attributes) |attr| {
            if (attr.isNamed(name)) return attr;
        }
        return null;
    }

    /// Count the number of attributes
    pub fn count(self: AttributeList) usize {
        return self.attributes.len;
    }
};

/// Common attribute names
pub const AttributeName = struct {
    pub const test_name = "test";
    pub const inline_name = "inline";
    pub const noinline_name = "noinline";
    pub const deprecated = "deprecated";
    pub const export_name = "export";
    pub const cold = "cold";
    pub const hot = "hot";
    pub const align_name = "align";
    pub const packed_name = "packed";
    pub const extern_name = "extern";
};
