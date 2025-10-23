const std = @import("std");
const Value = @import("value.zig").Value;

/// Lexical scope environment for variable bindings.
///
/// The Environment implements lexical scoping for Ion programs using a
/// chain of hash maps. Each Environment represents one scope level and
/// can have an optional parent scope. Variable lookup walks up the scope
/// chain until a binding is found.
///
/// Scope Hierarchy:
/// - Global scope (parent = null)
/// - Function scopes (one per function call)
/// - Block scopes (one per { } block)
///
/// Example scope chain:
/// ```
/// Global { x: 10 }
///   └─> Function { y: 20, param: 42 }
///         └─> Block { z: 30 }
/// ```
///
/// When looking up `z`, it's found immediately. When looking up `x`,
/// the search walks through Block -> Function -> Global.
pub const Environment = struct {
    /// Hash map of variable name -> value for this scope
    bindings: std.StringHashMap(Value),
    /// Optional parent environment (null for global scope)
    parent: ?*Environment,
    /// Allocator for variable names
    allocator: std.mem.Allocator,

    /// Create a new environment, optionally nested in a parent scope.
    ///
    /// Parameters:
    ///   - allocator: Allocator for the bindings map and name strings
    ///   - parent: Parent environment, or null for global scope
    ///
    /// Returns: Initialized Environment
    pub fn init(allocator: std.mem.Allocator, parent: ?*Environment) Environment {
        return .{
            .bindings = std.StringHashMap(Value).init(allocator),
            .parent = parent,
            .allocator = allocator,
        };
    }

    /// Clean up the environment's resources.
    ///
    /// Frees the hash map structure. Variable names and values are
    /// freed automatically by the arena allocator, so we only need
    /// to deinit the map itself.
    pub fn deinit(self: *Environment) void {
        // Arena allocator handles cleanup of keys and values
        // Just deinit the hash map structure itself
        self.bindings.deinit();
    }

    /// Define a new variable in this scope.
    ///
    /// Creates a new binding in the current environment. This does not
    /// check parent scopes and will shadow any variables with the same
    /// name in outer scopes. The name is duplicated for ownership.
    ///
    /// Parameters:
    ///   - name: Variable name (will be duplicated)
    ///   - value: Value to bind to the name
    ///
    /// Errors: OutOfMemory if allocation fails
    pub fn define(self: *Environment, name: []const u8, value: Value) !void {
        // Duplicate the name string for HashMap ownership
        const name_copy = try self.allocator.dupe(u8, name);
        try self.bindings.put(name_copy, value);
    }

    /// Look up a variable by name in this scope or parent scopes.
    ///
    /// Searches for the variable first in the current environment,
    /// then recursively in parent environments up to the global scope.
    /// This implements lexical scoping.
    ///
    /// Parameters:
    ///   - name: Variable name to look up
    ///
    /// Returns: The bound value if found, null if undefined
    pub fn get(self: *Environment, name: []const u8) ?Value {
        if (self.bindings.get(name)) |value| {
            return value;
        }
        if (self.parent) |parent| {
            return parent.get(name);
        }
        return null;
    }

    /// Update an existing variable's value.
    ///
    /// Searches for the variable in this scope and parent scopes,
    /// updating it where first found. This is used for assignment
    /// statements. Unlike `define`, this will error if the variable
    /// doesn't exist anywhere in the scope chain.
    ///
    /// Parameters:
    ///   - name: Variable name to update
    ///   - value: New value to assign
    ///
    /// Returns: error.UndefinedVariable if the name is not bound anywhere
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
