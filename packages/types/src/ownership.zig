const std = @import("std");
const ast = @import("ast");
const Type = @import("type_system.zig").Type;

/// Ownership state of a value
pub const OwnershipState = enum {
    Owned,      // Variable owns the value
    Moved,      // Value has been moved out
    Borrowed,   // Value is borrowed (immutable)
    MutBorrowed, // Value is mutably borrowed
};

/// Information about a variable's ownership
pub const OwnershipInfo = struct {
    name: []const u8,
    state: OwnershipState,
    type: Type,
    location: ast.SourceLocation,
};

pub const OwnershipError = error{
    UseAfterMove,
    MultipleMutableBorrows,
    BorrowWhileMutablyBorrowed,
    MutBorrowWhileBorrowed,
} || std.mem.Allocator.Error;

/// Ownership tracker for borrow checking
pub const OwnershipTracker = struct {
    allocator: std.mem.Allocator,
    variables: std.StringHashMap(OwnershipInfo),
    errors: std.ArrayList(OwnershipErrorInfo),

    pub const OwnershipErrorInfo = struct {
        message: []const u8,
        loc: ast.SourceLocation,
    };

    pub fn init(allocator: std.mem.Allocator) OwnershipTracker {
        return .{
            .allocator = allocator,
            .variables = std.StringHashMap(OwnershipInfo).init(allocator),
            .errors = std.ArrayList(OwnershipErrorInfo){},
        };
    }

    pub fn deinit(self: *OwnershipTracker) void {
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.variables.deinit();

        for (self.errors.items) |err_info| {
            self.allocator.free(err_info.message);
        }
        self.errors.deinit(self.allocator);
    }

    /// Register a new variable as owned
    pub fn define(self: *OwnershipTracker, name: []const u8, typ: Type, loc: ast.SourceLocation) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.variables.put(name_copy, .{
            .name = name_copy,
            .state = .Owned,
            .type = typ,
            .location = loc,
        });
    }

    /// Check if a variable can be used (not moved)
    pub fn checkUse(self: *OwnershipTracker, name: []const u8, loc: ast.SourceLocation) !void {
        const info = self.variables.get(name) orelse return;

        if (info.state == .Moved) {
            const msg = try std.fmt.allocPrint(self.allocator, "Use of moved value '{s}'", .{name});
            try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
            return error.UseAfterMove;
        }
    }

    /// Mark a variable as moved
    pub fn markMoved(self: *OwnershipTracker, name: []const u8) !void {
        if (self.variables.getPtr(name)) |info| {
            // Only move types that are not Copy (for now, assume all are movable)
            if (self.isMovable(info.type)) {
                info.state = .Moved;
            }
        }
    }

    /// Check if a type is movable (not Copy)
    fn isMovable(self: *OwnershipTracker, typ: Type) bool {
        _ = self;
        return switch (typ) {
            // Primitive types are Copy, not moved
            .Int, .Float, .Bool => false,
            // Strings, structs, and complex types are moved
            .String, .Struct, .Function => true,
            // References are Copy (they're just pointers)
            .Reference, .MutableReference => false,
            else => false,
        };
    }

    /// Borrow a variable immutably
    pub fn borrow(self: *OwnershipTracker, name: []const u8, loc: ast.SourceLocation) !void {
        const info = self.variables.getPtr(name) orelse return;

        switch (info.state) {
            .Owned, .Borrowed => {
                // Can have multiple immutable borrows
                info.state = .Borrowed;
            },
            .MutBorrowed => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow '{s}' as immutable while it is mutably borrowed",
                    .{name},
                );
                try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                return error.BorrowWhileMutablyBorrowed;
            },
            .Moved => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow moved value '{s}'",
                    .{name},
                );
                try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                return error.UseAfterMove;
            },
        }
    }

    /// Borrow a variable mutably
    pub fn borrowMut(self: *OwnershipTracker, name: []const u8, loc: ast.SourceLocation) !void {
        const info = self.variables.getPtr(name) orelse return;

        switch (info.state) {
            .Owned => {
                info.state = .MutBorrowed;
            },
            .Borrowed => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow '{s}' as mutable while it is borrowed",
                    .{name},
                );
                try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                return error.MutBorrowWhileBorrowed;
            },
            .MutBorrowed => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow '{s}' as mutable more than once",
                    .{name},
                );
                try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                return error.MultipleMutableBorrows;
            },
            .Moved => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow moved value '{s}'",
                    .{name},
                );
                try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                return error.UseAfterMove;
            },
        }
    }

    /// End a scope, releasing borrows
    pub fn endScope(self: *OwnershipTracker) void {
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr;
            // Release borrows at end of scope
            if (info.state == .Borrowed or info.state == .MutBorrowed) {
                info.state = .Owned;
            }
        }
    }

    pub fn hasErrors(self: *OwnershipTracker) bool {
        return self.errors.items.len > 0;
    }
};
