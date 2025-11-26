const std = @import("std");
const ast = @import("ast");
const parser_mod = @import("parser");
const lexer_mod = @import("lexer");

/// Extracts and validates code examples from documentation
pub const ExampleExtractor = struct {
    allocator: std.mem.Allocator,
    examples: std.ArrayList(CodeExample),

    pub const CodeExample = struct {
        code: []const u8,
        location: Location,
        language: Language = .home,
        expected_output: ?[]const u8 = null,
        should_compile: bool = true,
        should_run: bool = false,

        pub const Language = enum {
            home,
            zig,
            rust,
            javascript,
            shell,
            other,
        };

        pub const Location = struct {
            file: []const u8,
            line: usize,
            doc_item: []const u8,
        };

        pub fn deinit(self: *CodeExample, allocator: std.mem.Allocator) void {
            allocator.free(self.code);
            allocator.free(self.location.file);
            allocator.free(self.location.doc_item);
            if (self.expected_output) |output| {
                allocator.free(output);
            }
        }
    };

    pub const ValidationResult = struct {
        total: usize,
        passed: usize,
        failed: usize,
        skipped: usize,
        failures: []ValidationFailure,

        pub const ValidationFailure = struct {
            example: CodeExample,
            error_message: []const u8,
        };
    };

    pub fn init(allocator: std.mem.Allocator) ExampleExtractor {
        return .{
            .allocator = allocator,
            .examples = std.ArrayList(CodeExample).init(allocator),
        };
    }

    pub fn deinit(self: *ExampleExtractor) void {
        for (self.examples.items) |*example| {
            example.deinit(self.allocator);
        }
        self.examples.deinit();
    }

    /// Extract code examples from documentation comment
    pub fn extractFromDocComment(self: *ExampleExtractor, doc_comment: []const u8, file: []const u8, line: usize, item_name: []const u8) !void {
        var in_code_block = false;
        var code_buffer = std.ArrayList(u8).init(self.allocator);
        defer code_buffer.deinit();

        var language: CodeExample.Language = .home;
        var current_line = line;

        var lines = std.mem.splitScalar(u8, doc_comment, '\n');
        while (lines.next()) |doc_line| : (current_line += 1) {
            const trimmed = std.mem.trim(u8, doc_line, " \t");

            if (std.mem.startsWith(u8, trimmed, "```")) {
                if (in_code_block) {
                    // End of code block - save example
                    const code = try self.allocator.dupe(u8, code_buffer.items);
                    try self.examples.append(.{
                        .code = code,
                        .location = .{
                            .file = try self.allocator.dupe(u8, file),
                            .line = current_line - @as(usize, @intCast(code_buffer.items.len)),
                            .doc_item = try self.allocator.dupe(u8, item_name),
                        },
                        .language = language,
                    });

                    code_buffer.clearRetainingCapacity();
                    in_code_block = false;
                } else {
                    // Start of code block
                    const lang_str = trimmed[3..];
                    language = parseLanguage(lang_str);
                    in_code_block = true;
                }
            } else if (in_code_block) {
                try code_buffer.appendSlice(doc_line);
                try code_buffer.append('\n');
            }
        }
    }

    /// Parse language identifier from code fence
    fn parseLanguage(lang_str: []const u8) CodeExample.Language {
        const trimmed = std.mem.trim(u8, lang_str, " \t");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "home")) {
            return .home;
        } else if (std.mem.eql(u8, trimmed, "zig")) {
            return .zig;
        } else if (std.mem.eql(u8, trimmed, "rust")) {
            return .rust;
        } else if (std.mem.eql(u8, trimmed, "javascript") or std.mem.eql(u8, trimmed, "js")) {
            return .javascript;
        } else if (std.mem.eql(u8, trimmed, "shell") or std.mem.eql(u8, trimmed, "bash") or std.mem.eql(u8, trimmed, "sh")) {
            return .shell;
        }
        return .other;
    }

    /// Validate all extracted examples
    pub fn validateAll(self: *ExampleExtractor) !ValidationResult {
        var result = ValidationResult{
            .total = self.examples.items.len,
            .passed = 0,
            .failed = 0,
            .skipped = 0,
            .failures = undefined,
        };

        var failures = std.ArrayList(ValidationResult.ValidationFailure).init(self.allocator);
        defer failures.deinit();

        for (self.examples.items) |example| {
            const validation = try self.validateExample(example);
            switch (validation) {
                .passed => result.passed += 1,
                .failed => |err_msg| {
                    result.failed += 1;
                    try failures.append(.{
                        .example = example,
                        .error_message = err_msg,
                    });
                },
                .skipped => result.skipped += 1,
            }
        }

        result.failures = try failures.toOwnedSlice();
        return result;
    }

    /// Validation result for a single example
    pub const ExampleValidation = union(enum) {
        passed,
        failed: []const u8,
        skipped,
    };

    /// Validate a single code example
    fn validateExample(self: *ExampleExtractor, example: CodeExample) !ExampleValidation {
        switch (example.language) {
            .home => {
                // Try to parse the example
                var lex = lexer_mod.Lexer.init(self.allocator, example.code);
                var tokens = std.ArrayList(lexer_mod.Token).init(self.allocator);
                defer tokens.deinit();

                // Lex all tokens
                while (true) {
                    const token = lex.nextToken() catch |err| {
                        const err_msg = try std.fmt.allocPrint(
                            self.allocator,
                            "Lexer error: {}",
                            .{err},
                        );
                        return ExampleValidation{ .failed = err_msg };
                    };
                    try tokens.append(token);
                    if (token.type == .Eof) break;
                }

                // Parse the tokens
                const tokens_slice = try tokens.toOwnedSlice();
                defer self.allocator.free(tokens_slice);

                var par = parser_mod.Parser.init(self.allocator, tokens_slice);
                defer par.deinit();

                _ = par.parse() catch |err| {
                    const err_msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Parse error: {}",
                        .{err},
                    );
                    return ExampleValidation{ .failed = err_msg };
                };

                return .passed;
            },
            .zig => {
                // For Zig code, we could invoke the Zig compiler
                // For now, just skip
                return .skipped;
            },
            else => {
                // Skip validation for other languages
                return .skipped;
            },
        }
    }

    /// Print validation results
    pub fn printValidationResults(result: ValidationResult) void {
        std.debug.print("\nCode Example Validation Results:\n", .{});
        std.debug.print("=================================\n", .{});
        std.debug.print("Total:   {d}\n", .{result.total});
        std.debug.print("Passed:  \x1b[32m{d}\x1b[0m\n", .{result.passed});
        std.debug.print("Failed:  \x1b[31m{d}\x1b[0m\n", .{result.failed});
        std.debug.print("Skipped: \x1b[33m{d}\x1b[0m\n", .{result.skipped});

        if (result.failed > 0) {
            std.debug.print("\nFailures:\n", .{});
            for (result.failures) |failure| {
                std.debug.print("\n  ❌ {s} (line {d})\n", .{
                    failure.example.location.file,
                    failure.example.location.line,
                });
                std.debug.print("     In: {s}\n", .{failure.example.location.doc_item});
                std.debug.print("     Error: {s}\n", .{failure.error_message});
            }
        }

        const success_rate = if (result.total > 0)
            (@as(f64, @floatFromInt(result.passed)) / @as(f64, @floatFromInt(result.total))) * 100.0
        else
            0.0;

        std.debug.print("\nSuccess rate: {d:.1}%\n", .{success_rate});
    }
};

/// Example usage and testing
pub const ExampleRunner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExampleRunner {
        return .{ .allocator = allocator };
    }

    /// Run an example and capture output
    pub fn runExample(self: *ExampleRunner, example: ExampleExtractor.CodeExample) ![]const u8 {
        // 1. Create a temporary directory
        var tmp_dir_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/home_example_{d}", .{std.time.timestamp()});

        try std.fs.cwd().makeDir(tmp_dir);
        defer std.fs.cwd().deleteTree(tmp_dir) catch {};

        // 2. Write code to temporary file
        var file_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/example.home", .{tmp_dir});

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(example.code);

        // 3. Compile the example (assuming home compiler is in PATH)
        var compile_result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "home", "build", file_path },
        });
        defer self.allocator.free(compile_result.stdout);
        defer self.allocator.free(compile_result.stderr);

        if (compile_result.term.Exited != 0) {
            return error.CompilationFailed;
        }

        // 4. Run the compiled executable
        var exe_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const exe_path = try std.fmt.bufPrint(&exe_path_buf, "{s}/example", .{tmp_dir});

        var run_result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{exe_path},
        });
        defer self.allocator.free(run_result.stderr);

        // Return captured stdout (ownership transferred to caller)
        return run_result.stdout;
    }

    /// Compare expected vs actual output
    pub fn compareOutput(expected: []const u8, actual: []const u8) bool {
        return std.mem.eql(u8, expected, actual);
    }
};

test "ExampleExtractor basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var extractor = ExampleExtractor.init(allocator);
    defer extractor.deinit();

    const doc_comment =
        \\/// Example function
        \\///
        \\/// ```home
        \\/// let x = 42;
        \\/// println(x);
        \\/// ```
    ;

    try extractor.extractFromDocComment(doc_comment, "test.home", 1, "testFunc");

    try testing.expectEqual(@as(usize, 1), extractor.examples.items.len);
    try testing.expect(std.mem.indexOf(u8, extractor.examples.items[0].code, "let x = 42") != null);
}
