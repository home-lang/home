//! Source-preserving edits to explicitly authored TypeScript configuration.
//! Parsing belongs to Home's TypeScript front end; returned text remains owned
//! by the caller and this module performs no file IO or module evaluation.
const std = @import("std");
const parser_mod = @import("ts_parser.zig");
const lexer = @import("ts_lexer");
const hir_mod = @import("hir");
const strings = @import("string_interner");

const Tree = struct {
    hir: *const hir_mod.Hir,
    interner: *const strings.Interner,

    fn expression(self: Tree, input: hir_mod.NodeId) hir_mod.NodeId {
        var node = input;
        while (switch (self.hir.kindOf(node)) {
            .as_expr, .satisfies_expr, .type_assertion, .non_null_expr => true,
            else => false,
        }) node = hir_mod.asExpressionOf(self.hir, node).expr;
        return node;
    }

    fn exportedObject(self: Tree, root: hir_mod.NodeId) !hir_mod.NodeId {
        var found: ?hir_mod.NodeId = null;
        for (hir_mod.blockStmts(self.hir, root)) |statement| {
            if (self.hir.kindOf(statement) != .export_decl) continue;
            const exported = hir_mod.exportOf(self.hir, statement);
            if (!exported.is_default or exported.is_type_only) continue;
            if (found != null) return error.AmbiguousSourceExport;
            found = self.expression(exported.decl);
        }
        const object = found orelse return error.MissingDefaultExport;
        if (self.hir.kindOf(object) != .object_literal) return error.DynamicSourceExport;
        return object;
    }

    const Key = struct {
        text: []const u8,
        owned: bool = false,

        fn deinit(self: Key, allocator: std.mem.Allocator) void {
            if (self.owned) allocator.free(self.text);
        }
    };

    fn staticKey(self: Tree, allocator: std.mem.Allocator, node: hir_mod.NodeId) !Key {
        const raw = self.interner.get(switch (self.hir.kindOf(node)) {
            // Quoted noncomputed property names use identifier nodes too.
            // Their interned payload still contains the authored escapes.
            .identifier => hir_mod.identifierOf(self.hir, node).name,
            .literal_string => hir_mod.literalStringOf(self.hir, node).value,
            else => return error.DynamicSourceProperty,
        });
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return .{ .text = raw };
        var cooked: std.ArrayList(u8) = .empty;
        errdefer cooked.deinit(allocator);
        try lexer.appendCookedStringText(allocator, raw, &cooked);
        return .{ .text = try cooked.toOwnedSlice(allocator), .owned = true };
    }

    fn property(self: Tree, allocator: std.mem.Allocator, object: hir_mod.NodeId, key: []const u8) !?hir_mod.NodeId {
        if (self.hir.kindOf(object) != .object_literal) return error.DynamicSourceProperty;
        var found: ?hir_mod.NodeId = null;
        for (hir_mod.objectLiteralProps(self.hir, object)) |node| {
            // Unknown spreads/computed names can override an explicit field.
            // A source edit cannot erase that authored behavior to force a value.
            if (self.hir.kindOf(node) != .object_property) return error.DynamicSourceProperty;
            const field = hir_mod.objectPropertyOf(self.hir, node);
            if (field.is_computed and self.hir.kindOf(field.key) != .literal_string) return error.DynamicSourceProperty;
            const name = try self.staticKey(allocator, field.key);
            defer name.deinit(allocator);
            if (!std.mem.eql(u8, name.text, key)) continue;
            if (found != null) return error.AmbiguousSourceProperty;
            if (field.is_shorthand or field.is_method or field.is_accessor) return error.DynamicSourceProperty;
            if (!field.is_computed and std.mem.eql(u8, name.text, "__proto__")) return error.PrototypeSourceProperty;
            found = self.expression(field.value);
        }
        return found;
    }
};

fn quotedString(allocator: std.mem.Allocator, value: []const u8, quote: u8) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    if (quote != '\'') return json;
    defer allocator.free(json);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '\'');
    var index: usize = 1;
    while (index + 1 < json.len) : (index += 1) {
        if (json[index] == '\\') {
            index += 1;
            if (json[index] != '"') try output.append(allocator, '\\');
            try output.append(allocator, json[index]);
        } else {
            if (json[index] == '\'') try output.append(allocator, '\\');
            try output.append(allocator, json[index]);
        }
    }
    try output.append(allocator, '\'');
    return output.toOwnedSlice(allocator);
}

fn propertyKey(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const encoded = try quotedString(allocator, key, '"');
    if (!std.mem.eql(u8, key, "__proto__")) return encoded;
    defer allocator.free(encoded);
    // Quoting alone does not make this an own data property in JS literals.
    return std.fmt.allocPrint(allocator, "[{s}]", .{encoded});
}

fn nestedString(allocator: std.mem.Allocator, path: []const []const u8, value: []const u8) ![]const u8 {
    var output = try quotedString(allocator, value, '"');
    errdefer allocator.free(output);
    var index = path.len;
    while (index > 0) {
        index -= 1;
        const key = try propertyKey(allocator, path[index]);
        defer allocator.free(key);
        const next = try std.fmt.allocPrint(allocator, "{{{s}: {s}}}", .{ key, output });
        allocator.free(output);
        output = next;
    }
    return output;
}

/// Change an explicitly authored string under a literal default export, or add
/// a missing object path. Paths are decoded keys. Type assertions are transparent;
/// imports, expressions in other fields and every unrelated source byte survive.
/// Dynamic exports, target expressions, spreads, unresolved computed properties
/// and duplicate target keys or prototype initializers return errors instead of
/// changing their semantics.
/// The returned text is owned. No files or imports are executed or modified.
pub fn setExportedString(allocator: std.mem.Allocator, source: []const u8, path: []const []const u8, value: []const u8) ![]const u8 {
    if (path.len == 0) return error.EmptySourcePath;
    var interner = try strings.Interner.init(allocator);
    defer interner.deinit();
    var hir = try hir_mod.Hir.init(allocator);
    defer hir.deinit();
    var scanner = lexer.Scanner.init(allocator, source);
    defer scanner.deinit(allocator);
    var tokens = try scanner.tokenize(allocator);
    defer tokens.deinit(allocator);
    var parser = parser_mod.Parser.init(allocator, &hir, &interner, source, tokens.items);
    defer parser.deinit();
    const root = parser.parseSourceFile() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidSourceSyntax,
    };
    if (parser.diagnostics.items.len != 0) return error.InvalidSourceSyntax;
    for (scanner.diagnostics.items) |diagnostic| {
        const normalized = lexer.diagnostics.normalizeScannerDiagnostic(diagnostic.message);
        if (diagnostic.in_tagged_template and lexer.diagnostics.scannerDiagnosticIsInvalidStringTemplateEscape(normalized)) continue;
        if (parser.suppressesScannerDiagnostic(normalized.code, diagnostic.pos)) continue;
        return error.InvalidSourceSyntax;
    }
    const tree = Tree{ .hir = &hir, .interner = &interner };
    var object = try tree.exportedObject(root);
    for (path, 0..) |key, index| {
        if (try tree.property(allocator, object, key)) |node| {
            if (index + 1 != path.len) {
                object = node;
                continue;
            }
            if (hir.kindOf(node) != .literal_string) return error.DynamicSourceProperty;
            const span = hir.spanOf(node);
            if (span.start >= span.end or span.end > source.len or
                (source[span.start] != '\'' and source[span.start] != '"')) return error.UnsupportedSourceSpan;
            const encoded = try quotedString(allocator, value, source[span.start]);
            defer allocator.free(encoded);
            return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ source[0..span.start], encoded, source[span.end..] });
        }
        const fields = hir_mod.objectLiteralProps(&hir, object);
        const span = hir.spanOf(object);
        if (span.start >= span.end or span.end > source.len or source[span.start] != '{' or source[span.end - 1] != '}') return error.UnsupportedSourceSpan;
        const insertion = if (fields.len == 0) span.start + 1 else hir.spanOf(fields[fields.len - 1]).end;
        if (insertion < span.start or insertion >= span.end) return error.UnsupportedSourceSpan;
        const encoded_key = try propertyKey(allocator, key);
        defer allocator.free(encoded_key);
        const encoded_value = try nestedString(allocator, path[index + 1 ..], value);
        defer allocator.free(encoded_value);
        return std.fmt.allocPrint(allocator, "{s}{s}{s}: {s}{s}", .{ source[0..insertion], if (fields.len == 0) "" else ", ", encoded_key, encoded_value, source[insertion..] });
    }
    unreachable;
}

test "source edit: TypeScript imports types expressions comments and metadata retain their authored bytes" {
    const source = "import type { Config } from './types'\nimport { notes } from './notes'\nexport default {\n  // Keep native metadata.\n  dependencies: { redis: { version: '^7', global: false, custom: 'keep' } },\n  notes: notes<string, number>(),\n} satisfies Config\n";
    const output = try setExportedString(std.testing.allocator, source, &.{ "dependencies", "redis", "version" }, "^8.10.3");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("import type { Config } from './types'\nimport { notes } from './notes'\nexport default {\n  // Keep native metadata.\n  dependencies: { redis: { version: '^8.10.3', global: false, custom: 'keep' } },\n  notes: notes<string, number>(),\n} satisfies Config\n", output);
}

test "source edit: missing nested literal paths preserve comments expressions and trailing commas" {
    const allocator = std.testing.allocator;
    const source = "export default { dependencies: {}, notes: notes<string, number>(), // keep\n} as const";
    const output = try setExportedString(allocator, source, &.{ "dependencies", "registry.test", "version" }, "^8");
    defer allocator.free(output);
    try std.testing.expectEqualStrings("export default { dependencies: {\"registry.test\": {\"version\": \"^8\"}}, notes: notes<string, number>(), // keep\n} as const", output);
    const appended = try setExportedString(allocator, output, &.{"label"}, "keep");
    defer allocator.free(appended);
    try std.testing.expectEqualStrings("export default { dependencies: {\"registry.test\": {\"version\": \"^8\"}}, notes: notes<string, number>(), \"label\": \"keep\", // keep\n} as const", appended);
}

test "source edit: decoded static keys and single quote escaping are preserved" {
    const allocator = std.testing.allocator;
    const source = "export default { ['re\\u0064is']: { version: '^7' }, expression: `keep ${call({a: 1})}` }";
    const output = try setExportedString(allocator, source, &.{ "redis", "version" }, "next'\"\\\n");
    defer allocator.free(output);
    try std.testing.expectEqualStrings("export default { ['re\\u0064is']: { version: 'next\\'\"\\\\\\n' }, expression: `keep ${call({a: 1})}` }", output);
}

test "source edit: dynamic exports properties spreads and duplicate fields are explicit errors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.DynamicSourceExport, setExportedString(allocator, "export default buildConfig()", &.{"version"}, "8"));
    try std.testing.expectError(error.DynamicSourceProperty, setExportedString(allocator, "export default { version: readVersion() }", &.{"version"}, "8"));
    try std.testing.expectError(error.DynamicSourceProperty, setExportedString(allocator, "export default { version: '7', ...base }", &.{"version"}, "8"));
    try std.testing.expectError(error.DynamicSourceProperty, setExportedString(allocator, "export default { [name]: '7' }", &.{"version"}, "8"));
    try std.testing.expectError(error.AmbiguousSourceProperty, setExportedString(allocator, "export default { version: '7', version: '6' }", &.{"version"}, "8"));
    try std.testing.expectError(error.DynamicSourceProperty, setExportedString(allocator, "export default { get version() { return '7' } }", &.{"version"}, "8"));
    try std.testing.expectError(error.DynamicSourceProperty, setExportedString(allocator, "export default { version }", &.{"version"}, "8"));
    try std.testing.expectError(error.MissingDefaultExport, setExportedString(allocator, "const example = 'export default {}'", &.{"version"}, "8"));
    try std.testing.expectError(error.InvalidSourceSyntax, setExportedString(allocator, "export default { version: '7'", &.{"version"}, "8"));
    try std.testing.expectError(error.EmptySourcePath, setExportedString(allocator, "export default {}", &.{}, "8"));
}

fn sourceEditLifecycle(allocator: std.mem.Allocator) !void {
    const first = try setExportedString(allocator, "import type {Config} from './types'; export default {dependencies: {'re\\u0064is': {version: '^7', custom: true}}} satisfies Config", &.{ "dependencies", "redis", "version" }, "^8");
    defer allocator.free(first);
    const second = try setExportedString(allocator, first, &.{ "dependencies", "__proto__", "version" }, "^1\"\n");
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "custom: true") != null);
}

test "source edit: parser and editor allocations are cleaned up on every failure" {
    try sourceEditLifecycle(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sourceEditLifecycle, .{});
}

test "source edit: scanner syntax errors are rejected and tagged template escapes remain valid" {
    const allocator = std.testing.allocator;
    const valid = "export default { version: '7', note: tag`\\u{}` }";
    const edited = try setExportedString(allocator, valid, &.{"version"}, "8");
    defer allocator.free(edited);
    try std.testing.expectEqualStrings("export default { version: '8', note: tag`\\u{}` }", edited);
    const invalid = "export default { version: '7', note: '\\xG0' }";
    const result = setExportedString(allocator, invalid, &.{"version"}, "8") catch |err| {
        try std.testing.expectEqual(error.InvalidSourceSyntax, err);
        return;
    };
    defer allocator.free(result);
    return error.TestExpectedInvalidSourceSyntax;
}

fn expectSourceEditError(expected: anyerror, source: []const u8, path: []const []const u8) !void {
    const output = setExportedString(std.testing.allocator, source, path, "8") catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer std.testing.allocator.free(output);
    return error.TestExpectedSourceEditError;
}

test "source edit: quoted escaped keys select existing fields and retain duplicate protection" {
    const allocator = std.testing.allocator;
    const output = try setExportedString(allocator, "export default { 'ver\\u0073ion': '7' }", &.{"version"}, "8");
    defer allocator.free(output);
    try std.testing.expectEqualStrings("export default { 'ver\\u0073ion': '8' }", output);
    try expectSourceEditError(error.AmbiguousSourceProperty, "export default { version: '7', 'ver\\u0073ion': '6' }", &.{"version"});
}

test "source edit: inserted prototype names are explicit own data keys at every level" {
    const allocator = std.testing.allocator;
    const direct = try setExportedString(allocator, "export default {}", &.{"__proto__"}, "8");
    defer allocator.free(direct);
    try std.testing.expectEqualStrings("export default {[\"__proto__\"]: \"8\"}", direct);
    const nested = try setExportedString(allocator, "export default {}", &.{ "tools", "__proto__", "version" }, "8");
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("export default {\"tools\": {[\"__proto__\"]: {\"version\": \"8\"}}}", nested);
}

test "source edit: prototype initializers and computed own data properties stay distinct" {
    const allocator = std.testing.allocator;
    const computed = try setExportedString(allocator, "export default { ['__proto__']: { version: '7' } }", &.{ "__proto__", "version" }, "8");
    defer allocator.free(computed);
    try std.testing.expectEqualStrings("export default { ['__proto__']: { version: '8' } }", computed);
    try expectSourceEditError(error.PrototypeSourceProperty, "export default { __proto__: { version: '7' } }", &.{ "__proto__", "version" });
}
