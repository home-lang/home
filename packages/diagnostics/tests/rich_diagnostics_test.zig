const std = @import("std");
const testing = std.testing;
const diagnostics = @import("diagnostics");
const ast = @import("ast");
const RichDiagnostic = diagnostics.RichDiagnostic;
const DiagnosticBuilder = diagnostics.DiagnosticBuilder;
const CommonDiagnostics = diagnostics.CommonDiagnostics;
const Severity = diagnostics.Severity;

test "rich diagnostics: type mismatch" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 3, .column = 10 };
    const diag = try CommonDiagnostics.typeMismatch(allocator, location, "Int", "String");

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("T0001", diag.error_code);
    try testing.expect(std.mem.indexOf(u8, diag.title, "type mismatch") != null);
    try testing.expectEqual(location.line, diag.primary_label.location.line);
}

test "rich diagnostics: undefined variable" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 5, .column = 15 };
    const diag = try CommonDiagnostics.undefinedVariable(allocator, location, "variabel", "variable");

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("V0001", diag.error_code);
    try testing.expect(std.mem.indexOf(u8, diag.title, "variabel") != null);
    try testing.expect(diag.help != null);
    try testing.expect(std.mem.indexOf(u8, diag.help.?, "variable") != null);
}

test "rich diagnostics: cannot mutate" {
    const allocator = testing.allocator;

    const use_location = ast.SourceLocation{ .line = 10, .column = 5 };
    const def_location = ast.SourceLocation{ .line = 8, .column = 8 };
    const diag = try CommonDiagnostics.cannotMutate(allocator, use_location, "count", def_location);

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("M0001", diag.error_code);
    try testing.expect(std.mem.indexOf(u8, diag.title, "count") != null);
    try testing.expectEqual(@as(usize, 1), diag.secondary_labels.len);
    try testing.expectEqual(def_location.line, diag.secondary_labels[0].location.line);
}

test "rich diagnostics: argument count mismatch (too many)" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 12, .column = 20 };
    const diag = try CommonDiagnostics.argumentCountMismatch(allocator, location, 2, 3, "add");

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("F0001", diag.error_code);
    try testing.expect(std.mem.indexOf(u8, diag.title, "add") != null);
    try testing.expect(std.mem.indexOf(u8, diag.title, "2") != null);
    try testing.expect(std.mem.indexOf(u8, diag.title, "3") != null);
}

test "rich diagnostics: argument count mismatch (too few)" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 14, .column = 25 };
    const diag = try CommonDiagnostics.argumentCountMismatch(allocator, location, 3, 1, "process");

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expect(std.mem.indexOf(u8, diag.help.?, "add missing") != null);
}

test "rich diagnostics: missing return" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 20, .column = 1 };
    const diag = try CommonDiagnostics.missingReturn(allocator, location, "calculate", "Int");

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("R0001", diag.error_code);
    try testing.expect(std.mem.indexOf(u8, diag.title, "calculate") != null);
    try testing.expect(std.mem.indexOf(u8, diag.title, "Int") != null);
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
}

test "rich diagnostics: non-exhaustive match" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 25, .column = 5 };
    const missing = [_][]const u8{ "Some(T)", "None" };
    const diag = try CommonDiagnostics.nonExhaustiveMatch(allocator, location, &missing);

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("P0001", diag.error_code);
    try testing.expectEqual(@as(usize, 2), diag.notes.len);
    try testing.expect(std.mem.indexOf(u8, diag.notes[0], "Some(T)") != null);
    try testing.expect(std.mem.indexOf(u8, diag.notes[1], "None") != null);
}

test "rich diagnostics: division by zero" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 30, .column = 15 };
    const diag = try CommonDiagnostics.divisionByZero(allocator, location);

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("A0001", diag.error_code);
    try testing.expect(std.mem.indexOf(u8, diag.title, "divide by zero") != null);
}

test "rich diagnostics: index out of bounds" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 35, .column = 12 };
    const diag = try CommonDiagnostics.indexOutOfBounds(allocator, location, 5, 3);

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("A0002", diag.error_code);
    try testing.expect(std.mem.indexOf(u8, diag.title, "5") != null);
    try testing.expect(std.mem.indexOf(u8, diag.title, "3") != null);
}

test "rich diagnostics: unreachable code" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 40, .column = 8 };
    const diag = try CommonDiagnostics.unreachableCode(allocator, location, "after return statement");

    try testing.expectEqual(Severity.Warning, diag.severity);
    try testing.expectEqualStrings("W0001", diag.error_code);
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expect(std.mem.indexOf(u8, diag.notes[0], "after return") != null);
}

test "rich diagnostics: unused variable" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 45, .column = 8 };
    const diag = try CommonDiagnostics.unusedVariable(allocator, location, "temp");

    try testing.expectEqual(Severity.Warning, diag.severity);
    try testing.expectEqualStrings("W0002", diag.error_code);
    try testing.expect(std.mem.indexOf(u8, diag.title, "temp") != null);
    try testing.expect(std.mem.indexOf(u8, diag.help.?, "_temp") != null);
}

test "rich diagnostics: cannot infer type" {
    const allocator = testing.allocator;

    const location = ast.SourceLocation{ .line = 50, .column = 12 };
    const diag = try CommonDiagnostics.cannotInferType(allocator, location, "empty array literal");

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("T0002", diag.error_code);
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expect(std.mem.indexOf(u8, diag.notes[0], "empty array") != null);
}

test "diagnostic builder: custom error" {
    const allocator = testing.allocator;

    var builder = DiagnosticBuilder.init(
        allocator,
        .Error,
        "C0001",
        "custom error message",
    );

    const location = ast.SourceLocation{ .line = 55, .column = 10 };
    _ = builder.withPrimaryLabel(location, "this is wrong");
    _ = try builder.withNote("first note");
    _ = try builder.withNote("second note");
    _ = builder.withHelp("fix it like this");

    const diag = try builder.build();

    try testing.expectEqual(Severity.Error, diag.severity);
    try testing.expectEqualStrings("C0001", diag.error_code);
    try testing.expectEqualStrings("custom error message", diag.title);
    try testing.expectEqual(@as(usize, 2), diag.notes.len);
    try testing.expect(diag.help != null);
}

test "diagnostic builder: with suggestion" {
    const allocator = testing.allocator;

    var builder = DiagnosticBuilder.init(
        allocator,
        .Error,
        "S0001",
        "incorrect syntax",
    );

    const location = ast.SourceLocation{ .line = 60, .column = 5 };
    _ = builder.withPrimaryLabel(location, "unexpected token");
    _ = builder.withSuggestion(location, "use correct syntax", "let x = 42");

    const diag = try builder.build();

    try testing.expect(diag.suggestion != null);
    try testing.expectEqualStrings("let x = 42", diag.suggestion.?.replacement);
}

test "diagnostic builder: secondary labels" {
    const allocator = testing.allocator;

    var builder = DiagnosticBuilder.init(
        allocator,
        .Error,
        "L0001",
        "conflicting definitions",
    );

    const loc1 = ast.SourceLocation{ .line = 10, .column = 5 };
    const loc2 = ast.SourceLocation{ .line = 20, .column = 5 };

    _ = builder.withPrimaryLabel(loc1, "first definition");
    _ = try builder.withSecondaryLabel(loc2, "second definition");
    _ = try builder.withSecondaryLabel(loc2, "third definition");

    const diag = try builder.build();

    try testing.expectEqual(@as(usize, 2), diag.secondary_labels.len);
}

test "diagnostic builder: multiple notes" {
    const allocator = testing.allocator;

    var builder = DiagnosticBuilder.init(
        allocator,
        .Info,
        "I0001",
        "information message",
    );

    const location = ast.SourceLocation{ .line = 1, .column = 1 };
    _ = builder.withPrimaryLabel(location, "info here");

    _ = try builder.withNote("note 1");
    _ = try builder.withNote("note 2");
    _ = try builder.withNote("note 3");
    _ = try builder.withNote("note 4");

    const diag = try builder.build();

    try testing.expectEqual(@as(usize, 4), diag.notes.len);
}

test "diagnostic builder: error without primary label" {
    const allocator = testing.allocator;

    var builder = DiagnosticBuilder.init(
        allocator,
        .Error,
        "E0000",
        "error without label",
    );

    // Should fail because no primary label was set
    try testing.expectError(error.MissingPrimaryLabel, builder.build());
}
