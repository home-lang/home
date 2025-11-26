const std = @import("std");
const ast = @import("ast");

/// Smart suggestion system for common programming errors
pub const SuggestionEngine = struct {
    allocator: std.mem.Allocator,
    known_symbols: std.StringHashMap(SymbolInfo),

    pub const SymbolInfo = struct {
        name: []const u8,
        kind: SymbolKind,
        location: ast.SourceLocation,

        pub const SymbolKind = enum {
            function,
            variable,
            constant,
            type_name,
            module,
            field,
            method,
        };
    };

    pub fn init(allocator: std.mem.Allocator) SuggestionEngine {
        return .{
            .allocator = allocator,
            .known_symbols = std.StringHashMap(SymbolInfo).init(allocator),
        };
    }

    pub fn deinit(self: *SuggestionEngine) void {
        var it = self.known_symbols.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.known_symbols.deinit();
    }

    /// Register a symbol for typo detection
    pub fn registerSymbol(self: *SuggestionEngine, info: SymbolInfo) !void {
        const name_copy = try self.allocator.dupe(u8, info.name);
        try self.known_symbols.put(name_copy, info);
    }

    /// Find similar symbols for "did you mean?" suggestions
    pub fn findSimilar(self: *SuggestionEngine, name: []const u8, max_results: usize) ![][]const u8 {
        var results = std.ArrayList(SimilarityResult).init(self.allocator);
        defer results.deinit();

        var it = self.known_symbols.iterator();
        while (it.next()) |entry| {
            const distance = levenshteinDistance(name, entry.key_ptr.*);
            const max_distance = @max(name.len, entry.key_ptr.*.len) / 3; // Allow 33% difference

            if (distance <= max_distance) {
                try results.append(.{
                    .name = entry.key_ptr.*,
                    .distance = distance,
                });
            }
        }

        // Sort by similarity (lower distance = more similar)
        std.mem.sort(SimilarityResult, results.items, {}, struct {
            fn lessThan(_: void, a: SimilarityResult, b: SimilarityResult) bool {
                return a.distance < b.distance;
            }
        }.lessThan);

        // Take top N results
        const count = @min(max_results, results.items.len);
        var suggestions = try std.ArrayList([]const u8).initCapacity(self.allocator, count);
        for (results.items[0..count]) |result| {
            try suggestions.append(try self.allocator.dupe(u8, result.name));
        }

        return try suggestions.toOwnedSlice();
    }

    const SimilarityResult = struct {
        name: []const u8,
        distance: usize,
    };

    /// Calculate Levenshtein distance (edit distance) between two strings
    fn levenshteinDistance(s1: []const u8, s2: []const u8) usize {
        const len1 = s1.len;
        const len2 = s2.len;

        if (len1 == 0) return len2;
        if (len2 == 0) return len1;

        // Use stack allocation for small strings
        if (len1 <= 64 and len2 <= 64) {
            var matrix: [65][65]usize = undefined;
            return levenshteinDistanceImpl(s1, s2, &matrix);
        }

        // For larger strings, we'd need heap allocation
        // For now, just return a large number
        return 999;
    }

    fn levenshteinDistanceImpl(s1: []const u8, s2: []const u8, matrix: *[65][65]usize) usize {
        const len1 = s1.len;
        const len2 = s2.len;

        // Initialize first column
        for (0..len1 + 1) |i| {
            matrix[i][0] = i;
        }

        // Initialize first row
        for (0..len2 + 1) |j| {
            matrix[0][j] = j;
        }

        // Fill matrix
        for (1..len1 + 1) |i| {
            for (1..len2 + 1) |j| {
                const cost: usize = if (s1[i - 1] == s2[j - 1]) 0 else 1;

                matrix[i][j] = @min(
                    @min(
                        matrix[i - 1][j] + 1, // deletion
                        matrix[i][j - 1] + 1, // insertion
                    ),
                    matrix[i - 1][j - 1] + cost, // substitution
                );
            }
        }

        return matrix[len1][len2];
    }

    /// Generate suggestion for undefined variable
    pub fn suggestForUndefinedVariable(self: *SuggestionEngine, var_name: []const u8) !?[]const u8 {
        const similar = try self.findSimilar(var_name, 3);
        defer {
            for (similar) |name| {
                self.allocator.free(name);
            }
            self.allocator.free(similar);
        }

        if (similar.len == 0) return null;

        if (similar.len == 1) {
            return try std.fmt.allocPrint(
                self.allocator,
                "did you mean `{s}`?",
                .{similar[0]},
            );
        } else {
            var buf = std.ArrayList(u8).init(self.allocator);
            errdefer buf.deinit();

            try buf.appendSlice("did you mean one of these?\n");
            for (similar) |name| {
                try buf.appendSlice("    - `");
                try buf.appendSlice(name);
                try buf.appendSlice("`\n");
            }

            return try buf.toOwnedSlice();
        }
    }

    /// Generate suggestion for type mismatch
    pub fn suggestForTypeMismatch(self: *SuggestionEngine, expected: []const u8, found: []const u8) !?[]const u8 {
        _ = self;

        // Common type conversion suggestions
        if (std.mem.eql(u8, expected, "string") and std.mem.eql(u8, found, "int")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "try converting the integer to a string with `.toString()` or `format!()`",
                .{},
            );
        }

        if (std.mem.eql(u8, expected, "int") and std.mem.eql(u8, found, "string")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "try parsing the string to an integer with `.parse()?`",
                .{},
            );
        }

        if (std.mem.eql(u8, expected, "bool") and (std.mem.eql(u8, found, "int") or std.mem.eql(u8, found, "i32"))) {
            return try std.fmt.allocPrint(
                self.allocator,
                "try comparing the value: `x != 0` or `x == 1`",
                .{},
            );
        }

        // Reference vs value suggestions
        if (std.mem.startsWith(u8, expected, "&") and !std.mem.startsWith(u8, found, "&")) {
            const inner = expected[1..];
            if (std.mem.eql(u8, inner, found)) {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "try borrowing the value with `&{s}`",
                    .{found},
                );
            }
        }

        if (!std.mem.startsWith(u8, expected, "&") and std.mem.startsWith(u8, found, "&")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "try dereferencing the value with `*`",
                .{},
            );
        }

        return null;
    }

    /// Generate suggestion for missing semicolon
    pub fn suggestForMissingSemicolon(self: *SuggestionEngine) ![]const u8 {
        _ = self;
        return "add a semicolon `;` at the end of the statement";
    }

    /// Generate suggestion for immutable assignment
    pub fn suggestForImmutableAssignment(self: *SuggestionEngine, var_name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "consider declaring `{s}` as mutable: `let mut {s} = ...`",
            .{ var_name, var_name },
        );
    }

    /// Generate suggestion for missing return
    pub fn suggestForMissingReturn(self: *SuggestionEngine, return_type: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "add a return statement at the end of the function: `return <{s}-value>;`",
            .{return_type},
        );
    }

    /// Generate suggestion for unused variable
    pub fn suggestForUnusedVariable(self: *SuggestionEngine, var_name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "if this is intentional, prefix the variable with underscore: `_{s}`",
            .{var_name},
        );
    }

    /// Generate suggestion for non-exhaustive match
    pub fn suggestForNonExhaustiveMatch(self: *SuggestionEngine, missing_patterns: []const []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        try buf.appendSlice("add missing patterns to the match:\n");
        for (missing_patterns) |pattern| {
            try buf.appendSlice("    ");
            try buf.appendSlice(pattern);
            try buf.appendSlice(" => { /* ... */ },\n");
        }

        return try buf.toOwnedSlice();
    }

    /// Generate suggestion for circular dependency
    pub fn suggestForCircularDependency(self: *SuggestionEngine, cycle: []const []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        try buf.appendSlice("break the circular dependency chain:\n    ");
        for (cycle, 0..) |module, i| {
            if (i > 0) try buf.appendSlice(" -> ");
            try buf.appendSlice(module);
        }

        return try buf.toOwnedSlice();
    }
};

test "levenshtein distance" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), SuggestionEngine.levenshteinDistance("hello", "hello"));
    try testing.expectEqual(@as(usize, 1), SuggestionEngine.levenshteinDistance("hello", "hallo"));
    try testing.expectEqual(@as(usize, 3), SuggestionEngine.levenshteinDistance("kitten", "sitting"));
    try testing.expectEqual(@as(usize, 3), SuggestionEngine.levenshteinDistance("Saturday", "Sunday"));
}

test "find similar symbols" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var engine = SuggestionEngine.init(allocator);
    defer engine.deinit();

    try engine.registerSymbol(.{
        .name = "println",
        .kind = .function,
        .location = .{ .line = 1, .column = 1 },
    });

    try engine.registerSymbol(.{
        .name = "print",
        .kind = .function,
        .location = .{ .line = 2, .column = 1 },
    });

    const similar = try engine.findSimilar("printl", 2);
    defer {
        for (similar) |name| {
            allocator.free(name);
        }
        allocator.free(similar);
    }

    try testing.expectEqual(@as(usize, 2), similar.len);
    try testing.expect(std.mem.eql(u8, similar[0], "println") or std.mem.eql(u8, similar[0], "print"));
}
