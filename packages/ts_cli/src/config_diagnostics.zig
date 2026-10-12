//! Rendering and summary metadata for diagnostics produced while resolving
//! compiler options from a tsconfig. TypeScript attaches these diagnostics to
//! the Program: they do not prevent root discovery or emit on their own.

const std = @import("std");
const ts_diagnostics = @import("ts_diagnostics");
const tsconfig = @import("tsconfig");

pub const Summary = struct {
    count: usize = 0,
    file_error_count: usize = 0,
    first_error_file: []const u8 = "",
    first_error_line: usize = 0,
    first_error_col: usize = 0,

    pub fn hasErrors(self: Summary) bool {
        return self.count != 0;
    }
};

pub fn summarize(cfg: tsconfig.TsConfig, diagnostics: []const tsconfig.ValidationDiagnostic) Summary {
    var summary: Summary = .{ .count = diagnostics.len };
    if (cfg.file_path.len == 0) return summary;

    for (diagnostics) |diagnostic| {
        const location = diagnostic.location orelse continue;
        summary.file_error_count += 1;
        if (summary.first_error_file.len == 0) {
            summary.first_error_file = cfg.file_path;
            summary.first_error_line = location.line;
            summary.first_error_col = location.column + 1;
        }
    }
    return summary;
}

pub fn format(
    gpa: std.mem.Allocator,
    cfg: tsconfig.TsConfig,
    source: []const u8,
    diagnostic: tsconfig.ValidationDiagnostic,
    pretty: bool,
    color: bool,
) ![]u8 {
    const location = diagnostic.location;
    const rendered: ts_diagnostics.Diagnostic = .{
        .file = if (location != null) cfg.file_path else "",
        .line = if (location) |loc| loc.line else 0,
        .col = if (location) |loc| loc.column + 1 else 0,
        .code = diagnostic.code,
        .code_prefix = .TS,
        .severity = .err,
        .message = diagnostic.message,
        .span_len = if (location) |loc| tokenSpanLength(source, loc.pos) else 0,
    };
    if (pretty) {
        return ts_diagnostics.formatPretty(
            gpa,
            rendered,
            if (location != null and source.len != 0) source else null,
            color,
        );
    }
    return ts_diagnostics.formatDefault(gpa, rendered);
}

fn tokenSpanLength(source: []const u8, start: u32) u32 {
    const offset: usize = @intCast(start);
    if (offset >= source.len) return 0;

    if (source[offset] == '"') {
        var i = offset + 1;
        var escaped = false;
        while (i < source.len) : (i += 1) {
            const byte = source[i];
            if (!escaped and byte == '"') return @intCast(i - offset + 1);
            if (!escaped and byte == '\\') {
                escaped = true;
            } else {
                escaped = false;
            }
        }
        return @intCast(source.len - offset);
    }

    var end = offset;
    while (end < source.len) : (end += 1) {
        switch (source[end]) {
            ' ', '\t', '\r', '\n', ',', '}', ']' => break,
            else => {},
        }
    }
    return @intCast(end - offset);
}

test "config diagnostics: pretty removed-option output underlines the option value" {
    const T = std.testing;
    const source =
        \\{
        \\  "compilerOptions": {
        \\    "target": "es5"
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    var cfg = try tsconfig.parseString(T.allocator, arena.allocator(), source);
    cfg.file_path = "/repo/tsconfig.json";
    const diagnostics = try cfg.validate(T.allocator);
    defer tsconfig.freeValidationDiagnostics(T.allocator, diagnostics);

    const summary = summarize(cfg, diagnostics);
    try T.expectEqual(@as(usize, 1), summary.count);
    try T.expectEqual(@as(usize, 1), summary.file_error_count);
    try T.expectEqualStrings(cfg.file_path, summary.first_error_file);
    try T.expectEqual(@as(usize, 3), summary.first_error_line);
    try T.expectEqual(@as(usize, 15), summary.first_error_col);

    const rendered = try format(T.allocator, cfg, source, diagnostics[0], true, false);
    defer T.allocator.free(rendered);
    try T.expect(std.mem.indexOf(u8, rendered, "/repo/tsconfig.json:3:15 - error TS5108") != null);
    try T.expect(std.mem.indexOf(u8, rendered, "\"target\": \"es5\"") != null);
    try T.expect(std.mem.indexOf(u8, rendered, "~~~~~") != null);
}

test "config diagnostics: unlocated diagnostics stay whole-program errors" {
    const T = std.testing;
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const diagnostic: tsconfig.ValidationDiagnostic = .{
        .code = 5023,
        .message = "Unknown compiler option 'wat'.",
    };
    const cfg = try tsconfig.parseString(T.allocator, arena.allocator(), "{}");
    const rendered = try format(T.allocator, cfg, "", diagnostic, false, false);
    defer T.allocator.free(rendered);
    try T.expectEqualStrings("error TS5023: Unknown compiler option 'wat'.", rendered);
}

test "config diagnostics: declaration dependencies point to the owning JSON key" {
    const source =
        \\{
        \\  "compilerOptions": {
        \\    "emitDeclarationOnly": true
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try tsconfig.parseString(std.testing.allocator, arena.allocator(), source);
    cfg.file_path = "tsconfig.json";
    const diagnostics = try cfg.validate(std.testing.allocator);
    defer tsconfig.freeValidationDiagnostics(std.testing.allocator, diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    const rendered = try format(std.testing.allocator, cfg, source, diagnostics[0], false, false);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("tsconfig.json(3,5): error TS5069: Option 'emitDeclarationOnly' cannot be specified without specifying option 'declaration' or option 'composite'.", rendered);

    // A command-line value has no corresponding source key in the config.
    var cli_cfg = try tsconfig.parseString(std.testing.allocator, arena.allocator(), "{}");
    cli_cfg.file_path = "tsconfig.json";
    cli_cfg.compiler_options.emit_declaration_only = true;
    const cli_diagnostics = try cli_cfg.validate(std.testing.allocator);
    defer tsconfig.freeValidationDiagnostics(std.testing.allocator, cli_diagnostics);
    try std.testing.expect(cli_diagnostics[0].location == null);

    const earlier_dependency =
        \\{
        \\  "compilerOptions": {
        \\    "declaration": false,
        \\    "emitDeclarationOnly": true
        \\  }
        \\}
    ;
    const ordered_cfg = try tsconfig.parseString(std.testing.allocator, arena.allocator(), earlier_dependency);
    const ordered_diags = try ordered_cfg.validate(std.testing.allocator);
    defer tsconfig.freeValidationDiagnostics(std.testing.allocator, ordered_diags);
    try std.testing.expectEqual(@as(u32, 3), ordered_diags[0].location.?.line);

    const root_source = "{\n  \"compilerOptions\": { \"module\": \"ESNext\" }\n}";
    var root_cfg = try tsconfig.parseString(std.testing.allocator, arena.allocator(), root_source);
    root_cfg.compiler_options.emit_declaration_only = true;
    const root_diags = try root_cfg.validate(std.testing.allocator);
    defer tsconfig.freeValidationDiagnostics(std.testing.allocator, root_diags);
    try std.testing.expectEqual(@as(u32, 2), root_diags[0].location.?.line);
    try std.testing.expectEqual(@as(u32, 2), root_diags[0].location.?.column);
}
