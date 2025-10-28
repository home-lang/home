const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const ast = @import("ast");

/// JSON diagnostic output for editor integration
pub const JsonDiagnosticWriter = struct {
    allocator: std.mem.Allocator,
    writer: std.ArrayList(u8).Writer,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) JsonDiagnosticWriter {
        var buffer = std.ArrayList(u8).init(allocator);
        return .{
            .allocator = allocator,
            .writer = buffer.writer(),
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *JsonDiagnosticWriter) void {
        self.buffer.deinit();
    }

    /// Write diagnostics in JSON format (LSP-compatible)
    pub fn write(self: *JsonDiagnosticWriter, diags: []diagnostics.Diagnostic, file_path: []const u8) ![]const u8 {
        try self.writer.writeAll("{\n");
        try self.writer.writeAll("  \"diagnostics\": [\n");

        for (diags, 0..) |diag, i| {
            try self.writeDiagnostic(diag, file_path);
            if (i < diags.len - 1) {
                try self.writer.writeAll(",\n");
            } else {
                try self.writer.writeAll("\n");
            }
        }

        try self.writer.writeAll("  ]\n");
        try self.writer.writeAll("}\n");

        return try self.buffer.toOwnedSlice();
    }

    fn writeDiagnostic(self: *JsonDiagnosticWriter, diag: diagnostics.Diagnostic, file_path: []const u8) !void {
        try self.writer.writeAll("    {\n");

        // Severity
        try self.writer.writeAll("      \"severity\": ");
        try self.writer.print("{d},\n", .{@intFromEnum(diag.severity)});

        // Message
        try self.writer.writeAll("      \"message\": ");
        try self.writeJsonString(diag.message);
        try self.writer.writeAll(",\n");

        // Source
        try self.writer.writeAll("      \"source\": \"ion\",\n");

        // Location/Range
        try self.writer.writeAll("      \"range\": {\n");
        try self.writer.writeAll("        \"start\": {\n");
        try self.writer.print("          \"line\": {d},\n", .{diag.location.line});
        try self.writer.print("          \"character\": {d}\n", .{diag.location.column});
        try self.writer.writeAll("        },\n");
        try self.writer.writeAll("        \"end\": {\n");
        try self.writer.print("          \"line\": {d},\n", .{diag.location.line});
        try self.writer.print("          \"character\": {d}\n", .{diag.location.column + 1});
        try self.writer.writeAll("        }\n");
        try self.writer.writeAll("      }");

        // Code (if available)
        if (diag.code) |code| {
            try self.writer.writeAll(",\n");
            try self.writer.writeAll("      \"code\": ");
            try self.writeJsonString(code);
        }

        // Related information (source line)
        if (diag.source_line) |source_line| {
            try self.writer.writeAll(",\n");
            try self.writer.writeAll("      \"relatedInformation\": [{\n");
            try self.writer.writeAll("        \"location\": {\n");
            try self.writer.writeAll("          \"uri\": ");
            try self.writeJsonString(file_path);
            try self.writer.writeAll(",\n");
            try self.writer.writeAll("          \"range\": {\n");
            try self.writer.writeAll("            \"start\": { \"line\": ");
            try self.writer.print("{d}", .{diag.location.line});
            try self.writer.writeAll(", \"character\": 0 },\n");
            try self.writer.writeAll("            \"end\": { \"line\": ");
            try self.writer.print("{d}", .{diag.location.line});
            try self.writer.writeAll(", \"character\": ");
            try self.writer.print("{d}", .{source_line.len});
            try self.writer.writeAll(" }\n");
            try self.writer.writeAll("          }\n");
            try self.writer.writeAll("        },\n");
            try self.writer.writeAll("        \"message\": ");
            try self.writeJsonString(source_line);
            try self.writer.writeAll("\n");
            try self.writer.writeAll("      }]");
        }

        // Code actions (suggestions)
        if (diag.suggestion) |suggestion| {
            try self.writer.writeAll(",\n");
            try self.writer.writeAll("      \"codeActions\": [{\n");
            try self.writer.writeAll("        \"title\": ");
            try self.writeJsonString(suggestion);
            try self.writer.writeAll(",\n");
            try self.writer.writeAll("        \"kind\": \"quickfix\"\n");
            try self.writer.writeAll("      }]");
        }

        try self.writer.writeAll("\n    }");
    }

    fn writeJsonString(self: *JsonDiagnosticWriter, s: []const u8) !void {
        try self.writer.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.writer.writeAll("\\\""),
                '\\' => try self.writer.writeAll("\\\\"),
                '\n' => try self.writer.writeAll("\\n"),
                '\r' => try self.writer.writeAll("\\r"),
                '\t' => try self.writer.writeAll("\\t"),
                else => try self.writer.writeByte(c),
            }
        }
        try self.writer.writeByte('"');
    }
};

/// Compact JSON format (single line)
pub const CompactJsonWriter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompactJsonWriter {
        return .{ .allocator = allocator };
    }

    pub fn write(self: *CompactJsonWriter, diags: []diagnostics.Diagnostic) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        var writer = buffer.writer();

        try writer.writeAll("{\"diagnostics\":[");

        for (diags, 0..) |diag, i| {
            try writer.writeAll("{");

            // Severity
            try writer.print("\"severity\":{d},", .{@intFromEnum(diag.severity)});

            // Message
            try writer.writeAll("\"message\":\"");
            try self.writeEscaped(writer, diag.message);
            try writer.writeAll("\",");

            // Location
            try writer.print("\"line\":{d},", .{diag.location.line});
            try writer.print("\"column\":{d}", .{diag.location.column});

            // Suggestion
            if (diag.suggestion) |suggestion| {
                try writer.writeAll(",\"suggestion\":\"");
                try self.writeEscaped(writer, suggestion);
                try writer.writeAll("\"");
            }

            try writer.writeAll("}");

            if (i < diags.len - 1) {
                try writer.writeAll(",");
            }
        }

        try writer.writeAll("]}");

        return buffer.toOwnedSlice();
    }

    fn writeEscaped(self: *CompactJsonWriter, writer: anytype, s: []const u8) !void {
        _ = self;
        for (s) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
    }
};

/// SARIF format for static analysis tools
pub const SarifWriter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SarifWriter {
        return .{ .allocator = allocator };
    }

    pub fn write(self: *SarifWriter, diags: []diagnostics.Diagnostic, file_path: []const u8) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        var writer = buffer.writer();

        try writer.writeAll("{\n");
        try writer.writeAll("  \"version\": \"2.1.0\",\n");
        try writer.writeAll("  \"$schema\": \"https://json.schemastore.org/sarif-2.1.0.json\",\n");
        try writer.writeAll("  \"runs\": [{\n");
        try writer.writeAll("    \"tool\": {\n");
        try writer.writeAll("      \"driver\": {\n");
        try writer.writeAll("        \"name\": \"Home Compiler\",\n");
        try writer.writeAll("        \"version\": \"0.1.0\",\n");
        try writer.writeAll("        \"informationUri\": \"https://ion-lang.org\"\n");
        try writer.writeAll("      }\n");
        try writer.writeAll("    },\n");
        try writer.writeAll("    \"results\": [\n");

        for (diags, 0..) |diag, i| {
            try self.writeResult(writer, diag, file_path);
            if (i < diags.len - 1) {
                try writer.writeAll(",\n");
            } else {
                try writer.writeAll("\n");
            }
        }

        try writer.writeAll("    ]\n");
        try writer.writeAll("  }]\n");
        try writer.writeAll("}\n");

        return buffer.toOwnedSlice();
    }

    fn writeResult(self: *SarifWriter, writer: anytype, diag: diagnostics.Diagnostic, file_path: []const u8) !void {
        _ = self;

        try writer.writeAll("      {\n");

        // Rule ID
        if (diag.code) |code| {
            try writer.writeAll("        \"ruleId\": \"");
            try writer.writeAll(code);
            try writer.writeAll("\",\n");
        }

        // Level
        try writer.writeAll("        \"level\": \"");
        try writer.writeAll(switch (diag.severity) {
            .Error => "error",
            .Warning => "warning",
            .Info => "note",
            .Hint => "note",
        });
        try writer.writeAll("\",\n");

        // Message
        try writer.writeAll("        \"message\": {\n");
        try writer.writeAll("          \"text\": \"");
        for (diag.message) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeAll("\"\n");
        try writer.writeAll("        },\n");

        // Locations
        try writer.writeAll("        \"locations\": [{\n");
        try writer.writeAll("          \"physicalLocation\": {\n");
        try writer.writeAll("            \"artifactLocation\": {\n");
        try writer.writeAll("              \"uri\": \"");
        try writer.writeAll(file_path);
        try writer.writeAll("\"\n");
        try writer.writeAll("            },\n");
        try writer.writeAll("            \"region\": {\n");
        try writer.print("              \"startLine\": {d},\n", .{diag.location.line + 1});
        try writer.print("              \"startColumn\": {d}\n", .{diag.location.column + 1});
        try writer.writeAll("            }\n");
        try writer.writeAll("          }\n");
        try writer.writeAll("        }]\n");

        try writer.writeAll("      }");
    }
};

/// Diagnostic severity for JSON output (LSP-compatible)
pub const DiagnosticSeverity = enum(u8) {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4,
};
