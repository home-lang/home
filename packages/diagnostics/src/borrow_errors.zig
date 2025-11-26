const std = @import("std");
const ast = @import("ast");
const enhanced_reporter = @import("enhanced_reporter.zig");
const EnhancedReporter = enhanced_reporter.EnhancedReporter;

/// Specialized error reporting for borrow checking violations
pub const BorrowErrorReporter = struct {
    allocator: std.mem.Allocator,
    reporter: *EnhancedReporter,

    pub fn init(allocator: std.mem.Allocator, reporter: *EnhancedReporter) BorrowErrorReporter {
        return .{
            .allocator = allocator,
            .reporter = reporter,
        };
    }

    /// Report use-after-move error
    pub fn reportUseAfterMove(
        self: *BorrowErrorReporter,
        var_name: []const u8,
        use_location: ast.SourceLocation,
        move_location: ast.SourceLocation,
        file_path: []const u8,
    ) !void {
        var labels = std.ArrayList(EnhancedReporter.EnhancedDiagnostic.Label).init(self.allocator);
        defer labels.deinit();

        try labels.append(.{
            .location = use_location,
            .message = try std.fmt.allocPrint(self.allocator, "value used here after move", .{}),
            .style = .primary,
        });

        try labels.append(.{
            .location = move_location,
            .message = try std.fmt.allocPrint(self.allocator, "value moved here", .{}),
            .style = .secondary,
        });

        const diagnostic = EnhancedReporter.EnhancedDiagnostic{
            .severity = .Error,
            .code = try self.allocator.dupe(u8, "E0382"),
            .message = try std.fmt.allocPrint(self.allocator, "use of moved value: `{s}`", .{var_name}),
            .location = use_location,
            .labels = try labels.toOwnedSlice(),
            .help = try std.fmt.allocPrint(
                self.allocator,
                "consider cloning the value before moving: `let clone = {s}.clone();`",
                .{var_name},
            ),
            .notes = &.{},
        };

        try self.reporter.report(diagnostic, file_path);
    }

    /// Report multiple mutable borrows error
    pub fn reportMultipleMutableBorrows(
        self: *BorrowErrorReporter,
        var_name: []const u8,
        first_borrow: ast.SourceLocation,
        second_borrow: ast.SourceLocation,
        file_path: []const u8,
    ) !void {
        var labels = std.ArrayList(EnhancedReporter.EnhancedDiagnostic.Label).init(self.allocator);
        defer labels.deinit();

        try labels.append(.{
            .location = first_borrow,
            .message = try self.allocator.dupe(u8, "first mutable borrow occurs here"),
            .style = .secondary,
        });

        try labels.append(.{
            .location = second_borrow,
            .message = try self.allocator.dupe(u8, "second mutable borrow occurs here"),
            .style = .primary,
        });

        const diagnostic = EnhancedReporter.EnhancedDiagnostic{
            .severity = .Error,
            .code = try self.allocator.dupe(u8, "E0499"),
            .message = try std.fmt.allocPrint(
                self.allocator,
                "cannot borrow `{s}` as mutable more than once at a time",
                .{var_name},
            ),
            .location = second_borrow,
            .labels = try labels.toOwnedSlice(),
            .help = try self.allocator.dupe(u8, "mutable references must be exclusive; consider restructuring to use only one mutable reference at a time"),
            .notes = &.{},
        };

        try self.reporter.report(diagnostic, file_path);
    }

    /// Report borrow while mutably borrowed error
    pub fn reportBorrowWhileMutablyBorrowed(
        self: *BorrowErrorReporter,
        var_name: []const u8,
        mut_borrow: ast.SourceLocation,
        immut_borrow: ast.SourceLocation,
        file_path: []const u8,
    ) !void {
        var labels = std.ArrayList(EnhancedReporter.EnhancedDiagnostic.Label).init(self.allocator);
        defer labels.deinit();

        try labels.append(.{
            .location = mut_borrow,
            .message = try self.allocator.dupe(u8, "mutable borrow occurs here"),
            .style = .secondary,
        });

        try labels.append(.{
            .location = immut_borrow,
            .message = try self.allocator.dupe(u8, "immutable borrow occurs here"),
            .style = .primary,
        });

        const diagnostic = EnhancedReporter.EnhancedDiagnostic{
            .severity = .Error,
            .code = try self.allocator.dupe(u8, "E0502"),
            .message = try std.fmt.allocPrint(
                self.allocator,
                "cannot borrow `{s}` as immutable because it is also borrowed as mutable",
                .{var_name},
            ),
            .location = immut_borrow,
            .labels = try labels.toOwnedSlice(),
            .help = try self.allocator.dupe(u8, "immutable and mutable references cannot coexist; end the mutable borrow before creating immutable borrows"),
            .notes = &.{},
        };

        try self.reporter.report(diagnostic, file_path);
    }

    /// Report move while borrowed error
    pub fn reportMoveWhileBorrowed(
        self: *BorrowErrorReporter,
        var_name: []const u8,
        borrow_location: ast.SourceLocation,
        move_location: ast.SourceLocation,
        file_path: []const u8,
    ) !void {
        var labels = std.ArrayList(EnhancedReporter.EnhancedDiagnostic.Label).init(self.allocator);
        defer labels.deinit();

        try labels.append(.{
            .location = borrow_location,
            .message = try self.allocator.dupe(u8, "borrow occurs here"),
            .style = .secondary,
        });

        try labels.append(.{
            .location = move_location,
            .message = try self.allocator.dupe(u8, "move out of borrowed value occurs here"),
            .style = .primary,
        });

        const diagnostic = EnhancedReporter.EnhancedDiagnostic{
            .severity = .Error,
            .code = try self.allocator.dupe(u8, "E0505"),
            .message = try std.fmt.allocPrint(
                self.allocator,
                "cannot move out of `{s}` because it is borrowed",
                .{var_name},
            ),
            .location = move_location,
            .labels = try labels.toOwnedSlice(),
            .help = try self.allocator.dupe(u8, "borrowed values cannot be moved; consider cloning the value or restructuring your code"),
            .notes = &.{},
        };

        try self.reporter.report(diagnostic, file_path);
    }

    /// Report lifetime error
    pub fn reportLifetimeError(
        self: *BorrowErrorReporter,
        var_name: []const u8,
        location: ast.SourceLocation,
        file_path: []const u8,
        details: []const u8,
    ) !void {
        var labels = std.ArrayList(EnhancedReporter.EnhancedDiagnostic.Label).init(self.allocator);
        defer labels.deinit();

        try labels.append(.{
            .location = location,
            .message = try self.allocator.dupe(u8, "borrowed value does not live long enough"),
            .style = .primary,
        });

        const diagnostic = EnhancedReporter.EnhancedDiagnostic{
            .severity = .Error,
            .code = try self.allocator.dupe(u8, "E0597"),
            .message = try std.fmt.allocPrint(
                self.allocator,
                "`{s}` does not live long enough",
                .{var_name},
            ),
            .location = location,
            .labels = try labels.toOwnedSlice(),
            .help = try self.allocator.dupe(u8, "ensure the borrowed value lives for the entire duration it is needed; consider moving the value to an outer scope"),
            .notes = &[_][]const u8{try self.allocator.dupe(u8, details)},
        };

        try self.reporter.report(diagnostic, file_path);
    }
};
