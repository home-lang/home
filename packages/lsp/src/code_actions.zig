const std = @import("std");
const ast = @import("ast");
const types = @import("types");
const Allocator = std.mem.Allocator;

/// Code actions and quick fixes provider
/// Provides refactoring, auto-fixes, and code improvements
pub const CodeActionProvider = struct {
    allocator: Allocator,

    pub const CodeAction = struct {
        title: []const u8,
        kind: CodeActionKind,
        edit: ?WorkspaceEdit,
        command: ?Command,
        is_preferred: bool,

        pub fn deinit(self: *CodeAction, allocator: Allocator) void {
            allocator.free(self.title);
            if (self.edit) |*edit| {
                edit.deinit(allocator);
            }
            if (self.command) |*cmd| {
                allocator.free(cmd.title);
                for (cmd.arguments) |arg| {
                    allocator.free(arg);
                }
                allocator.free(cmd.arguments);
            }
        }
    };

    pub const CodeActionKind = enum {
        QuickFix,
        Refactor,
        RefactorExtract,
        RefactorInline,
        RefactorRewrite,
        Source,
        SourceOrganizeImports,
        SourceFixAll,

        pub fn toString(self: CodeActionKind) []const u8 {
            return switch (self) {
                .QuickFix => "quickfix",
                .Refactor => "refactor",
                .RefactorExtract => "refactor.extract",
                .RefactorInline => "refactor.inline",
                .RefactorRewrite => "refactor.rewrite",
                .Source => "source",
                .SourceOrganizeImports => "source.organizeImports",
                .SourceFixAll => "source.fixAll",
            };
        }
    };

    pub const WorkspaceEdit = struct {
        changes: std.StringHashMap([]TextEdit),

        pub fn deinit(self: *WorkspaceEdit, allocator: Allocator) void {
            var it = self.changes.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.*) |*edit| {
                    allocator.free(edit.new_text);
                }
                allocator.free(entry.value_ptr.*);
            }
            self.changes.deinit();
        }
    };

    pub const TextEdit = struct {
        range: Range,
        new_text: []const u8,
    };

    pub const Range = struct {
        start: Position,
        end: Position,
    };

    pub const Position = struct {
        line: u32,
        character: u32,
    };

    pub const Command = struct {
        title: []const u8,
        command: []const u8,
        arguments: [][]const u8,
    };

    pub fn init(allocator: Allocator) CodeActionProvider {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CodeActionProvider) void {
        _ = self;
    }

    /// Get code actions for a range in a document
    pub fn getCodeActions(
        self: *CodeActionProvider,
        uri: []const u8,
        range: Range,
        program: ?*ast.Program,
        diagnostics: []const Diagnostic,
    ) ![]CodeAction {
        var actions = std.ArrayList(CodeAction).init(self.allocator);

        // Quick fixes for diagnostics
        for (diagnostics) |diagnostic| {
            if (self.rangesOverlap(range, diagnostic.range)) {
                try self.addQuickFixesForDiagnostic(&actions, uri, diagnostic, program);
            }
        }

        // Refactoring actions
        if (program) |prog| {
            try self.addRefactoringActions(&actions, uri, range, prog);
        }

        // Source actions
        try self.addSourceActions(&actions, uri, program);

        return try actions.toOwnedSlice();
    }

    pub const Diagnostic = struct {
        range: Range,
        message: []const u8,
        code: ?[]const u8,
    };

    /// Add quick fixes for a specific diagnostic
    fn addQuickFixesForDiagnostic(
        self: *CodeActionProvider,
        actions: *std.ArrayList(CodeAction),
        uri: []const u8,
        diagnostic: Diagnostic,
        program: ?*ast.Program,
    ) !void {
        _ = program;

        // Common quick fixes based on diagnostic message
        if (std.mem.indexOf(u8, diagnostic.message, "undefined variable")) |_| {
            // Suggest importing or declaring the variable
            const var_name = try self.extractUndefinedName(diagnostic.message);
            defer self.allocator.free(var_name);

            // Add import suggestion
            try actions.append(.{
                .title = try std.fmt.allocPrint(self.allocator, "Import '{s}'", .{var_name}),
                .kind = .QuickFix,
                .edit = try self.createImportEdit(uri, var_name),
                .command = null,
                .is_preferred = true,
            });

            // Add declaration suggestion
            try actions.append(.{
                .title = try std.fmt.allocPrint(self.allocator, "Declare variable '{s}'", .{var_name}),
                .kind = .QuickFix,
                .edit = try self.createVariableDeclEdit(uri, var_name, diagnostic.range),
                .command = null,
                .is_preferred = false,
            });
        } else if (std.mem.indexOf(u8, diagnostic.message, "missing return")) |_| {
            // Add return statement
            try actions.append(.{
                .title = try self.allocator.dupe(u8, "Add return statement"),
                .kind = .QuickFix,
                .edit = try self.createReturnEdit(uri, diagnostic.range),
                .command = null,
                .is_preferred = true,
            });
        } else if (std.mem.indexOf(u8, diagnostic.message, "unused variable")) |_| {
            // Prefix with underscore or remove
            const var_name = try self.extractUnusedName(diagnostic.message);
            defer self.allocator.free(var_name);

            try actions.append(.{
                .title = try std.fmt.allocPrint(self.allocator, "Prefix with _ ('{s}' -> '_{s}')", .{ var_name, var_name }),
                .kind = .QuickFix,
                .edit = try self.createUnderscorePrefixEdit(uri, var_name, diagnostic.range),
                .command = null,
                .is_preferred = true,
            });

            try actions.append(.{
                .title = try std.fmt.allocPrint(self.allocator, "Remove unused variable '{s}'", .{var_name}),
                .kind = .QuickFix,
                .edit = try self.createRemoveEdit(uri, diagnostic.range),
                .command = null,
                .is_preferred = false,
            });
        } else if (std.mem.indexOf(u8, diagnostic.message, "type mismatch")) |_| {
            // Add type conversion
            try actions.append(.{
                .title = try self.allocator.dupe(u8, "Add type cast"),
                .kind = .QuickFix,
                .edit = try self.createCastEdit(uri, diagnostic.range),
                .command = null,
                .is_preferred = true,
            });
        }
    }

    /// Add refactoring actions for a range
    fn addRefactoringActions(
        self: *CodeActionProvider,
        actions: *std.ArrayList(CodeAction),
        uri: []const u8,
        range: Range,
        program: *ast.Program,
    ) !void {
        _ = program;

        // Extract to variable
        if (!self.isEmptyRange(range)) {
            try actions.append(.{
                .title = try self.allocator.dupe(u8, "Extract to variable"),
                .kind = .RefactorExtract,
                .edit = try self.createExtractVariableEdit(uri, range),
                .command = null,
                .is_preferred = false,
            });

            // Extract to function
            try actions.append(.{
                .title = try self.allocator.dupe(u8, "Extract to function"),
                .kind = .RefactorExtract,
                .edit = try self.createExtractFunctionEdit(uri, range),
                .command = null,
                .is_preferred = false,
            });
        }

        // Inline variable (if cursor is on a variable)
        try actions.append(.{
            .title = try self.allocator.dupe(u8, "Inline variable"),
            .kind = .RefactorInline,
            .edit = null,
            .command = .{
                .title = try self.allocator.dupe(u8, "Inline variable"),
                .command = try self.allocator.dupe(u8, "home.refactor.inline"),
                .arguments = &[_][]const u8{},
            },
            .is_preferred = false,
        });

        // Convert to arrow function / traditional function
        try actions.append(.{
            .title = try self.allocator.dupe(u8, "Convert to arrow function"),
            .kind = .RefactorRewrite,
            .edit = try self.createConvertToArrowEdit(uri, range),
            .command = null,
            .is_preferred = false,
        });
    }

    /// Add source-level actions
    fn addSourceActions(
        self: *CodeActionProvider,
        actions: *std.ArrayList(CodeAction),
        uri: []const u8,
        program: ?*ast.Program,
    ) !void {
        _ = program;

        // Organize imports
        try actions.append(.{
            .title = try self.allocator.dupe(u8, "Organize imports"),
            .kind = .SourceOrganizeImports,
            .edit = try self.createOrganizeImportsEdit(uri),
            .command = null,
            .is_preferred = false,
        });

        // Fix all auto-fixable issues
        try actions.append(.{
            .title = try self.allocator.dupe(u8, "Fix all auto-fixable problems"),
            .kind = .SourceFixAll,
            .edit = null,
            .command = .{
                .title = try self.allocator.dupe(u8, "Fix all"),
                .command = try self.allocator.dupe(u8, "home.source.fixAll"),
                .arguments = &[_][]const u8{},
            },
            .is_preferred = false,
        });

        // Add missing imports
        try actions.append(.{
            .title = try self.allocator.dupe(u8, "Add all missing imports"),
            .kind = .QuickFix,
            .edit = null,
            .command = .{
                .title = try self.allocator.dupe(u8, "Add imports"),
                .command = try self.allocator.dupe(u8, "home.source.addMissingImports"),
                .arguments = &[_][]const u8{},
            },
            .is_preferred = false,
        });
    }

    // Helper functions to create edits

    fn createImportEdit(self: *CodeActionProvider, uri: []const u8, name: []const u8) !?WorkspaceEdit {
        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        const import_text = try std.fmt.allocPrint(self.allocator, "use {s};\n", .{name});

        var edits = try self.allocator.alloc(TextEdit, 1);
        edits[0] = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 0 },
            },
            .new_text = import_text,
        };

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    fn createVariableDeclEdit(self: *CodeActionProvider, uri: []const u8, name: []const u8, range: Range) !?WorkspaceEdit {
        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        const decl_text = try std.fmt.allocPrint(self.allocator, "let {s} = /* TODO */;\n", .{name});

        var edits = try self.allocator.alloc(TextEdit, 1);
        edits[0] = .{
            .range = .{
                .start = .{ .line = range.start.line, .character = 0 },
                .end = .{ .line = range.start.line, .character = 0 },
            },
            .new_text = decl_text,
        };

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    fn createReturnEdit(self: *CodeActionProvider, uri: []const u8, range: Range) !?WorkspaceEdit {
        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        var edits = try self.allocator.alloc(TextEdit, 1);
        edits[0] = .{
            .range = range,
            .new_text = try self.allocator.dupe(u8, "return /* TODO */;"),
        };

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    fn createUnderscorePrefixEdit(self: *CodeActionProvider, uri: []const u8, name: []const u8, range: Range) !?WorkspaceEdit {
        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        const new_name = try std.fmt.allocPrint(self.allocator, "_{s}", .{name});

        var edits = try self.allocator.alloc(TextEdit, 1);
        edits[0] = .{
            .range = range,
            .new_text = new_name,
        };

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    fn createRemoveEdit(self: *CodeActionProvider, uri: []const u8, range: Range) !?WorkspaceEdit {
        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        var edits = try self.allocator.alloc(TextEdit, 1);
        edits[0] = .{
            .range = .{
                .start = .{ .line = range.start.line, .character = 0 },
                .end = .{ .line = range.end.line + 1, .character = 0 },
            },
            .new_text = try self.allocator.dupe(u8, ""),
        };

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    fn createCastEdit(self: *CodeActionProvider, uri: []const u8, range: Range) !?WorkspaceEdit {
        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        var edits = try self.allocator.alloc(TextEdit, 1);
        edits[0] = .{
            .range = range,
            .new_text = try self.allocator.dupe(u8, "as /* type */"),
        };

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    fn createExtractVariableEdit(self: *CodeActionProvider, uri: []const u8, range: Range) !?WorkspaceEdit {
        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        var edits = try self.allocator.alloc(TextEdit, 2);

        // Insert variable declaration
        edits[0] = .{
            .range = .{
                .start = .{ .line = range.start.line, .character = 0 },
                .end = .{ .line = range.start.line, .character = 0 },
            },
            .new_text = try self.allocator.dupe(u8, "let extracted = /* expression */;\n"),
        };

        // Replace selected expression with variable reference
        edits[1] = .{
            .range = range,
            .new_text = try self.allocator.dupe(u8, "extracted"),
        };

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    fn createExtractFunctionEdit(self: *CodeActionProvider, uri: []const u8, range: Range) !?WorkspaceEdit {
        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        const function_text =
            \\
            \\fn extracted() {
            \\    // TODO: Move selected code here
            \\}
            \\
        ;

        var edits = try self.allocator.alloc(TextEdit, 2);

        // Insert function declaration
        edits[0] = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 0 },
            },
            .new_text = try self.allocator.dupe(u8, function_text),
        };

        // Replace selected code with function call
        edits[1] = .{
            .range = range,
            .new_text = try self.allocator.dupe(u8, "extracted()"),
        };

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    fn createConvertToArrowEdit(self: *CodeActionProvider, uri: []const u8, range: Range) !?WorkspaceEdit {
        _ = range;

        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        // Placeholder edit
        var edits = try self.allocator.alloc(TextEdit, 0);

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    fn createOrganizeImportsEdit(self: *CodeActionProvider, uri: []const u8) !?WorkspaceEdit {
        var changes = std.StringHashMap([]TextEdit).init(self.allocator);
        const uri_key = try self.allocator.dupe(u8, uri);

        // Placeholder - would sort and group imports
        var edits = try self.allocator.alloc(TextEdit, 0);

        try changes.put(uri_key, edits);

        return WorkspaceEdit{ .changes = changes };
    }

    // Helper methods

    fn extractUndefinedName(self: *CodeActionProvider, message: []const u8) ![]const u8 {
        // Extract variable name from "undefined variable 'foo'"
        if (std.mem.indexOf(u8, message, "'")) |start| {
            if (std.mem.indexOfPos(u8, message, start + 1, "'")) |end| {
                return try self.allocator.dupe(u8, message[start + 1 .. end]);
            }
        }
        return try self.allocator.dupe(u8, "unknown");
    }

    fn extractUnusedName(self: *CodeActionProvider, message: []const u8) ![]const u8 {
        // Extract variable name from "unused variable 'foo'"
        if (std.mem.indexOf(u8, message, "'")) |start| {
            if (std.mem.indexOfPos(u8, message, start + 1, "'")) |end| {
                return try self.allocator.dupe(u8, message[start + 1 .. end]);
            }
        }
        return try self.allocator.dupe(u8, "unknown");
    }

    fn rangesOverlap(self: *CodeActionProvider, a: Range, b: Range) bool {
        _ = self;
        // Check if ranges overlap
        if (a.end.line < b.start.line or b.end.line < a.start.line) {
            return false;
        }
        if (a.end.line == b.start.line and a.end.character < b.start.character) {
            return false;
        }
        if (b.end.line == a.start.line and b.end.character < a.start.character) {
            return false;
        }
        return true;
    }

    fn isEmptyRange(self: *CodeActionProvider, range: Range) bool {
        _ = self;
        return range.start.line == range.end.line and range.start.character == range.end.character;
    }
};

test "CodeActionProvider - basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = CodeActionProvider.init(allocator);
    defer provider.deinit();

    // Test undefined variable quick fix
    const diagnostic = CodeActionProvider.Diagnostic{
        .range = .{
            .start = .{ .line = 5, .character = 10 },
            .end = .{ .line = 5, .character = 13 },
        },
        .message = "undefined variable 'foo'",
        .code = null,
    };

    const actions = try provider.getCodeActions(
        "file:///test.home",
        diagnostic.range,
        null,
        &[_]CodeActionProvider.Diagnostic{diagnostic},
    );
    defer allocator.free(actions);

    try testing.expect(actions.len > 0);
    // Should have import and declare actions
}
