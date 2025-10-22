const std = @import("std");
const testing = std.testing;
const diagnostics = @import("diagnostics");

test "diagnostics: create reporter" {
    const allocator = testing.allocator;

    var reporter = diagnostics.DiagnosticReporter.init(allocator);
    defer reporter.deinit();

    try testing.expect(!reporter.hasErrors());
    try testing.expect(!reporter.hasWarnings());
}

test "diagnostics: add error" {
    const allocator = testing.allocator;

    var reporter = diagnostics.DiagnosticReporter.init(allocator);
    defer reporter.deinit();

    const loc = diagnostics.ast.SourceLocation{ .line = 1, .column = 5 };
    try reporter.addError("Unexpected token", loc, null);

    try testing.expect(reporter.hasErrors());
    try testing.expectEqual(@as(usize, 1), reporter.diagnostics.items.len);
}

test "diagnostics: add warning" {
    const allocator = testing.allocator;

    var reporter = diagnostics.DiagnosticReporter.init(allocator);
    defer reporter.deinit();

    const loc = diagnostics.ast.SourceLocation{ .line = 2, .column = 10 };
    try reporter.addWarning("Unused variable", loc, null);

    try testing.expect(reporter.hasWarnings());
    try testing.expectEqual(@as(usize, 1), reporter.diagnostics.items.len);
}

test "diagnostics: add error with suggestion" {
    const allocator = testing.allocator;

    var reporter = diagnostics.DiagnosticReporter.init(allocator);
    defer reporter.deinit();

    const loc = diagnostics.ast.SourceLocation{ .line = 1, .column = 5 };
    try reporter.addError("Missing semicolon", loc, "Add ';' at the end of the statement");

    try testing.expect(reporter.hasErrors());
    const diag = reporter.diagnostics.items[0];
    try testing.expect(diag.suggestion != null);
}

test "diagnostics: multiple errors" {
    const allocator = testing.allocator;

    var reporter = diagnostics.DiagnosticReporter.init(allocator);
    defer reporter.deinit();

    const loc1 = diagnostics.ast.SourceLocation{ .line = 1, .column = 1 };
    const loc2 = diagnostics.ast.SourceLocation{ .line = 2, .column = 1 };
    const loc3 = diagnostics.ast.SourceLocation{ .line = 3, .column = 1 };

    try reporter.addError("Error 1", loc1, null);
    try reporter.addError("Error 2", loc2, null);
    try reporter.addError("Error 3", loc3, null);

    try testing.expect(reporter.hasErrors());
    try testing.expectEqual(@as(usize, 3), reporter.diagnostics.items.len);
}

test "diagnostics: load source" {
    const allocator = testing.allocator;

    var reporter = diagnostics.DiagnosticReporter.init(allocator);
    defer reporter.deinit();

    const source =
        \\let x = 42;
        \\let y = 10;
        \\let z = x + y;
    ;

    try reporter.loadSource(source);

    try testing.expect(reporter.source_lines.count() > 0);
}

test "diagnostics: error with loaded source" {
    const allocator = testing.allocator;

    var reporter = diagnostics.DiagnosticReporter.init(allocator);
    defer reporter.deinit();

    const source = "let x = ;";
    try reporter.loadSource(source);

    const loc = diagnostics.ast.SourceLocation{ .line = 1, .column = 8 };
    try reporter.addError("Expected expression", loc, null);

    try testing.expect(reporter.hasErrors());
    const diag = reporter.diagnostics.items[0];
    try testing.expect(diag.source_line != null);
}

test "diagnostics: severity levels" {
    const allocator = testing.allocator;

    var reporter = diagnostics.DiagnosticReporter.init(allocator);
    defer reporter.deinit();

    const loc = diagnostics.ast.SourceLocation{ .line = 1, .column = 1 };

    try reporter.addError("Error message", loc, null);
    try reporter.addWarning("Warning message", loc, null);

    try testing.expect(reporter.hasErrors());
    try testing.expect(reporter.hasWarnings());
    try testing.expectEqual(@as(usize, 2), reporter.diagnostics.items.len);
}

test "diagnostics: severity color" {
    const error_color = diagnostics.Severity.Error.color();
    const warning_color = diagnostics.Severity.Warning.color();

    try testing.expectEqual(diagnostics.Color.Red, error_color);
    try testing.expectEqual(diagnostics.Color.Yellow, warning_color);
}

test "diagnostics: severity label" {
    try testing.expectEqualStrings("error", diagnostics.Severity.Error.label());
    try testing.expectEqualStrings("warning", diagnostics.Severity.Warning.label());
    try testing.expectEqualStrings("info", diagnostics.Severity.Info.label());
    try testing.expectEqualStrings("hint", diagnostics.Severity.Hint.label());
}
