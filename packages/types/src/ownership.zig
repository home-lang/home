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

/// A single borrow record
pub const BorrowRecord = struct {
    is_mutable: bool,
    location: ast.SourceLocation,
    scope_depth: usize,
};

/// Information about a variable's ownership
pub const OwnershipInfo = struct {
    name: []const u8,
    state: OwnershipState,
    type: Type,
    location: ast.SourceLocation,
    /// Track individual borrows (for better error messages and scope management)
    borrows: std.ArrayList(BorrowRecord),
    /// Track the current scope depth
    scope_depth: usize,
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
    /// Current scope depth (increments on entering blocks, decrements on exit)
    current_scope: usize,

    pub const OwnershipErrorInfo = struct {
        message: []const u8,
        loc: ast.SourceLocation,
    };

    pub fn init(allocator: std.mem.Allocator) OwnershipTracker {
        return .{
            .allocator = allocator,
            .variables = std.StringHashMap(OwnershipInfo).init(allocator),
            .errors = std.ArrayList(OwnershipErrorInfo){},
            .current_scope = 0,
        };
    }

    pub fn deinit(self: *OwnershipTracker) void {
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.borrows.deinit();
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
            .borrows = std.ArrayList(BorrowRecord).init(self.allocator),
            .scope_depth = self.current_scope,
        });
    }

    /// Enter a new scope (e.g., function, if block, loop)
    pub fn enterScope(self: *OwnershipTracker) void {
        self.current_scope += 1;
    }

    /// Exit a scope, releasing borrows from this scope
    pub fn exitScope(self: *OwnershipTracker) void {
        if (self.current_scope == 0) return;

        var it = self.variables.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr;

            // Remove borrows from the current scope
            var i: usize = 0;
            while (i < info.borrows.items.len) {
                if (info.borrows.items[i].scope_depth >= self.current_scope) {
                    _ = info.borrows.orderedRemove(i);
                } else {
                    i += 1;
                }
            }

            // Update ownership state based on remaining borrows
            if (info.borrows.items.len == 0) {
                info.state = .Owned;
            } else {
                // Check if any remaining borrow is mutable
                var has_mut = false;
                for (info.borrows.items) |b| {
                    if (b.is_mutable) {
                        has_mut = true;
                        break;
                    }
                }
                info.state = if (has_mut) .MutBorrowed else .Borrowed;
            }
        }

        self.current_scope -= 1;
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
                try info.borrows.append(.{
                    .is_mutable = false,
                    .location = loc,
                    .scope_depth = self.current_scope,
                });
                info.state = .Borrowed;
            },
            .MutBorrowed => {
                // Check if there's an active mutable borrow
                for (info.borrows.items) |b| {
                    if (b.is_mutable) {
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "Cannot borrow '{s}' as immutable while it is mutably borrowed at line {d}",
                            .{ name, b.location.line },
                        );
                        try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                        return error.BorrowWhileMutablyBorrowed;
                    }
                }
            },
            .Moved => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow moved value '{s}' (moved at line {d})",
                    .{ name, info.location.line },
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
                // No existing borrows, safe to mutably borrow
                try info.borrows.append(.{
                    .is_mutable = true,
                    .location = loc,
                    .scope_depth = self.current_scope,
                });
                info.state = .MutBorrowed;
            },
            .Borrowed => {
                // Report the first conflicting immutable borrow
                const first_borrow = info.borrows.items[0];
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow '{s}' as mutable while it is borrowed at line {d}",
                    .{ name, first_borrow.location.line },
                );
                try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                return error.MutBorrowWhileBorrowed;
            },
            .MutBorrowed => {
                // Report the existing mutable borrow
                for (info.borrows.items) |b| {
                    if (b.is_mutable) {
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "Cannot borrow '{s}' as mutable more than once (first mutable borrow at line {d})",
                            .{ name, b.location.line },
                        );
                        try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                        return error.MultipleMutableBorrows;
                    }
                }
            },
            .Moved => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow moved value '{s}' (moved at line {d})",
                    .{ name, info.location.line },
                );
                try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                return error.UseAfterMove;
            },
        }
    }

    pub fn hasErrors(self: *OwnershipTracker) bool {
        return self.errors.items.len > 0;
    }
};
