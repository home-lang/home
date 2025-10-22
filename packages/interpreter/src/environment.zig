const std = @import("std");
const Value = @import("value.zig").Value;

/// Environment for variable bindings
pub const Environment = struct {
    bindings: std.StringHashMap(Value),
    parent: ?*Environment,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Environment) Environment {
        return .{
            .bindings = std.StringHashMap(Value).init(allocator),
            .parent = parent,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Environment) void {
        // Arena allocator handles cleanup of keys and values
        // Just deinit the hash map structure itself
        self.bindings.deinit();
    }

    pub fn define(self: *Environment, name: []const u8, value: Value) !void {
        // Duplicate the name string for HashMap ownership
        const name_copy = try self.allocator.dupe(u8, name);
        try self.bindings.put(name_copy, value);
    }

    pub fn get(self: *Environment, name: []const u8) ?Value {
        if (self.bindings.get(name)) |value| {
            return value;
        }
        if (self.parent) |parent| {
            return parent.get(name);
        }
        return null;
    }

    pub fn set(self: *Environment, name: []const u8, value: Value) !void {
        if (self.bindings.contains(name)) {
            try self.bindings.put(name, value);
            return;
        }
        if (self.parent) |parent| {
            return parent.set(name, value);
        }
        return error.UndefinedVariable;
    }
};
