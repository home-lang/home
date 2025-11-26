const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast");

/// Test suggestion priority
pub const Priority = enum {
    critical,
    high,
    medium,
    low,

    pub fn toString(self: Priority) []const u8 {
        return switch (self) {
            .critical => "CRITICAL",
            .high => "HIGH",
            .medium => "MEDIUM",
            .low => "LOW",
        };
    }
};

/// Type of test suggestion
pub const SuggestionType = enum {
    uncovered_function,
    uncovered_branch,
    error_handling,
    edge_case,
    integration,
    performance,
    security,

    pub fn description(self: SuggestionType) []const u8 {
        return switch (self) {
            .uncovered_function => "Function has no test coverage",
            .uncovered_branch => "Branch condition not tested",
            .error_handling => "Error path not tested",
            .edge_case => "Edge case not covered",
            .integration => "Integration test needed",
            .performance => "Performance test recommended",
            .security => "Security test needed",
        };
    }
};

/// A single test suggestion
pub const Suggestion = struct {
    type: SuggestionType,
    priority: Priority,
    file: []const u8,
    line: usize,
    function_name: ?[]const u8,
    message: []const u8,
    example_test: ?[]const u8 = null,

    pub fn format(self: Suggestion, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        try writer.print("[{s}] {s}:{d}", .{
            self.priority.toString(),
            self.file,
            self.line,
        });

        if (self.function_name) |name| {
            try writer.print(" in {s}()", .{name});
        }

        try writer.print("\n  {s}\n", .{self.message});

        if (self.example_test) |example| {
            try writer.print("\n  Suggested test:\n{s}\n", .{example});
        }

        return buffer.toOwnedSlice();
    }
};

/// Test suggestion generator
pub const SuggestionGenerator = struct {
    allocator: Allocator,
    suggestions: std.ArrayList(Suggestion),
    analyzed_files: std.StringHashMap(FileAnalysis),

    pub const FileAnalysis = struct {
        total_functions: usize,
        tested_functions: usize,
        total_branches: usize,
        tested_branches: usize,
        error_handlers: usize,
        tested_error_handlers: usize,
    };

    pub fn init(allocator: Allocator) SuggestionGenerator {
        return .{
            .allocator = allocator,
            .suggestions = std.ArrayList(Suggestion).init(allocator),
            .analyzed_files = std.StringHashMap(FileAnalysis).init(allocator),
        };
    }

    pub fn deinit(self: *SuggestionGenerator) void {
        for (self.suggestions.items) |suggestion| {
            self.allocator.free(suggestion.file);
            if (suggestion.function_name) |name| {
                self.allocator.free(name);
            }
            self.allocator.free(suggestion.message);
            if (suggestion.example_test) |example| {
                self.allocator.free(example);
            }
        }
        self.suggestions.deinit();

        var it = self.analyzed_files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.analyzed_files.deinit();
    }

    /// Analyze a source file and generate suggestions
    pub fn analyzeFile(self: *SuggestionGenerator, file_path: []const u8, program: *ast.Program) !void {
        var analysis = FileAnalysis{
            .total_functions = 0,
            .tested_functions = 0,
            .total_branches = 0,
            .tested_branches = 0,
            .error_handlers = 0,
            .tested_error_handlers = 0,
        };

        // Walk AST and analyze
        for (program.statements) |stmt| {
            try self.analyzeStatement(stmt, file_path, &analysis);
        }

        // Store analysis
        const key = try self.allocator.dupe(u8, file_path);
        try self.analyzed_files.put(key, analysis);
    }

    fn analyzeStatement(self: *SuggestionGenerator, stmt: ast.Stmt, file: []const u8, analysis: *FileAnalysis) !void {
        switch (stmt) {
            .FunctionDecl => |func_decl| {
                analysis.total_functions += 1;

                // Check if function is tested
                const is_tested = try self.isFunctionTested(func_decl.name);

                if (!is_tested) {
                    const priority: Priority = if (func_decl.is_public) .high else .medium;

                    const message = try std.fmt.allocPrint(
                        self.allocator,
                        "Function '{s}' has no test coverage",
                        .{func_decl.name},
                    );

                    const example = try self.generateTestExample(func_decl.name, func_decl.params.len);

                    try self.suggestions.append(.{
                        .type = .uncovered_function,
                        .priority = priority,
                        .file = try self.allocator.dupe(u8, file),
                        .line = func_decl.node.loc.line,
                        .function_name = try self.allocator.dupe(u8, func_decl.name),
                        .message = message,
                        .example_test = example,
                    });
                } else {
                    analysis.tested_functions += 1;
                }

                // Analyze function body for error handling
                try self.analyzeFunctionBody(&func_decl.body, file, func_decl.name, analysis);
            },
            else => {},
        }
    }

    fn analyzeFunctionBody(self: *SuggestionGenerator, block: *const ast.BlockStmt, file: []const u8, func_name: []const u8, analysis: *FileAnalysis) !void {
        for (block.statements) |stmt| {
            switch (stmt) {
                .IfStmt => |if_stmt| {
                    analysis.total_branches += 1;

                    // Check if branch is error handling
                    if (self.isErrorHandling(if_stmt.condition)) {
                        analysis.error_handlers += 1;

                        const message = try std.fmt.allocPrint(
                            self.allocator,
                            "Error handling branch in '{s}' not tested",
                            .{func_name},
                        );

                        try self.suggestions.append(.{
                            .type = .error_handling,
                            .priority = .high,
                            .file = try self.allocator.dupe(u8, file),
                            .line = if_stmt.node.loc.line,
                            .function_name = try self.allocator.dupe(u8, func_name),
                            .message = message,
                            .example_test = null,
                        });
                    }

                    // Recursively analyze branches
                    try self.analyzeFunctionBody(&if_stmt.then_block, file, func_name, analysis);
                    if (if_stmt.else_block) |else_block| {
                        try self.analyzeFunctionBody(&else_block, file, func_name, analysis);
                    }
                },
                .WhileStmt => |while_stmt| {
                    analysis.total_branches += 1;
                    try self.analyzeFunctionBody(&while_stmt.body, file, func_name, analysis);
                },
                else => {},
            }
        }
    }

    fn isFunctionTested(self: *SuggestionGenerator, func_name: []const u8) !bool {
        // Simple heuristic: check if there's a test function named "test_{func_name}"
        // In a real implementation, this would parse test files or use coverage data
        _ = self;
        _ = func_name;
        return false; // For now, assume untested
    }

    fn isErrorHandling(self: *SuggestionGenerator, expr: *ast.Expr) bool {
        _ = self;
        // Check if expression involves error checking
        // e.g., checking for null, error results, etc.
        switch (expr.*) {
            .BinaryExpr => |bin| {
                // Check for comparisons with null/error
                if (bin.operator == .Equal or bin.operator == .NotEqual) {
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn generateTestExample(self: *SuggestionGenerator, func_name: []const u8, param_count: usize) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        try writer.print("  test \"{s} - basic test\" {{\n", .{func_name});
        try writer.writeAll("    const testing = std.testing;\n");
        try writer.writeAll("    const allocator = testing.allocator;\n\n");

        try writer.print("    // Call {s} with test inputs\n", .{func_name});
        try writer.print("    const result = {s}(", .{func_name});

        var i: usize = 0;
        while (i < param_count) : (i += 1) {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll("test_value");
        }

        try writer.writeAll(");\n\n");
        try writer.writeAll("    // Assert expected behavior\n");
        try writer.writeAll("    try testing.expect(result != null);\n");
        try writer.writeAll("  }");

        return buffer.toOwnedSlice();
    }

    /// Generate suggestions for edge cases
    pub fn suggestEdgeCases(self: *SuggestionGenerator, file: []const u8, func_name: []const u8, param_types: []const []const u8) !void {
        for (param_types, 0..) |param_type, i| {
            const edge_cases = getEdgeCasesForType(param_type);

            for (edge_cases) |edge_case| {
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "Test edge case for parameter {d} ({s}): {s}",
                    .{ i + 1, param_type, edge_case },
                );

                try self.suggestions.append(.{
                    .type = .edge_case,
                    .priority = .medium,
                    .file = try self.allocator.dupe(u8, file),
                    .line = 0,
                    .function_name = try self.allocator.dupe(u8, func_name),
                    .message = message,
                    .example_test = null,
                });
            }
        }
    }

    /// Get all suggestions sorted by priority
    pub fn getSuggestions(self: *const SuggestionGenerator) []const Suggestion {
        return self.suggestions.items;
    }

    /// Get suggestions for a specific file
    pub fn getSuggestionsForFile(self: *SuggestionGenerator, file: []const u8) ![]Suggestion {
        var result = std.ArrayList(Suggestion).init(self.allocator);

        for (self.suggestions.items) |suggestion| {
            if (std.mem.eql(u8, suggestion.file, file)) {
                try result.append(suggestion);
            }
        }

        return result.toOwnedSlice();
    }

    /// Print summary of suggestions
    pub fn printSummary(self: *const SuggestionGenerator) !void {
        var by_priority = [_]usize{0} ** 4;

        for (self.suggestions.items) |suggestion| {
            const idx = @intFromEnum(suggestion.priority);
            by_priority[idx] += 1;
        }

        std.debug.print("\n=== Test Suggestions Summary ===\n", .{});
        std.debug.print("Total suggestions: {d}\n", .{self.suggestions.items.len});
        std.debug.print("  Critical: {d}\n", .{by_priority[@intFromEnum(Priority.critical)]});
        std.debug.print("  High:     {d}\n", .{by_priority[@intFromEnum(Priority.high)]});
        std.debug.print("  Medium:   {d}\n", .{by_priority[@intFromEnum(Priority.medium)]});
        std.debug.print("  Low:      {d}\n", .{by_priority[@intFromEnum(Priority.low)]});
        std.debug.print("\n");
    }

    /// Export suggestions to JSON
    pub fn exportJSON(self: *const SuggestionGenerator, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        try writer.writeAll("{\n");
        try writer.writeAll("  \"suggestions\": [\n");

        for (self.suggestions.items, 0..) |suggestion, i| {
            if (i > 0) try writer.writeAll(",\n");

            try writer.writeAll("    {\n");
            try writer.print("      \"type\": \"{s}\",\n", .{@tagName(suggestion.type)});
            try writer.print("      \"priority\": \"{s}\",\n", .{@tagName(suggestion.priority)});
            try writer.print("      \"file\": \"{s}\",\n", .{suggestion.file});
            try writer.print("      \"line\": {d},\n", .{suggestion.line});

            if (suggestion.function_name) |name| {
                try writer.print("      \"function\": \"{s}\",\n", .{name});
            }

            try writer.print("      \"message\": \"{s}\"\n", .{suggestion.message});
            try writer.writeAll("    }");
        }

        try writer.writeAll("\n  ]\n");
        try writer.writeAll("}\n");

        return buffer.toOwnedSlice();
    }
};

/// Get edge cases for a given type
fn getEdgeCasesForType(type_name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, type_name, "int") or std.mem.eql(u8, type_name, "i32")) {
        return &[_][]const u8{ "zero", "negative", "INT_MIN", "INT_MAX", "overflow" };
    } else if (std.mem.eql(u8, type_name, "string") or std.mem.eql(u8, type_name, "[]const u8")) {
        return &[_][]const u8{ "empty string", "null", "very long string", "unicode", "special characters" };
    } else if (std.mem.eql(u8, type_name, "bool")) {
        return &[_][]const u8{ "true", "false" };
    } else if (std.mem.startsWith(u8, type_name, "[]")) {
        return &[_][]const u8{ "empty array", "null", "single element", "large array" };
    } else if (std.mem.startsWith(u8, type_name, "?")) {
        return &[_][]const u8{ "null", "valid value" };
    }

    return &[_][]const u8{"null"};
}

test "SuggestionGenerator - basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var generator = SuggestionGenerator.init(allocator);
    defer generator.deinit();

    // Would analyze real AST in actual test
    try testing.expect(generator.suggestions.items.len == 0);
}
