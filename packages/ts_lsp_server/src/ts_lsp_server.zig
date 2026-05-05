//! LSP JSON-RPC wire-protocol server — Phase 8 of TS_PARITY_PLAN.
//!
//! Translates Microsoft LSP requests into Service calls.
//! Phase 8 v0 ships the request-routing core + JSON-RPC framing
//! protocol parser. The actual stdio I/O loop lives in a separate
//! binary that calls into this library.
//!
//! Supported request methods today:
//!   - initialize
//!   - textDocument/didOpen
//!   - textDocument/didChange
//!   - textDocument/didClose
//!   - textDocument/hover
//!   - textDocument/definition
//!   - textDocument/references
//!   - textDocument/completion
//!   - textDocument/publishDiagnostics (server-pushed)
//!   - shutdown
//!   - exit

const std = @import("std");
const ts_lsp = @import("ts_lsp");
const ts_program = @import("ts_program");
const ts_resolver = @import("ts_resolver");

pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    null_id,
};

pub const ResponseError = struct {
    code: i64,
    message: []const u8,
};

pub const Method = enum {
    initialize,
    initialized,
    shutdown,
    exit,
    text_document_did_open,
    text_document_did_change,
    text_document_did_close,
    text_document_hover,
    text_document_definition,
    text_document_references,
    text_document_completion,
    text_document_publish_diagnostics,
    unknown,

    pub fn fromString(s: []const u8) Method {
        const map = .{
            .{ "initialize", Method.initialize },
            .{ "initialized", Method.initialized },
            .{ "shutdown", Method.shutdown },
            .{ "exit", Method.exit },
            .{ "textDocument/didOpen", Method.text_document_did_open },
            .{ "textDocument/didChange", Method.text_document_did_change },
            .{ "textDocument/didClose", Method.text_document_did_close },
            .{ "textDocument/hover", Method.text_document_hover },
            .{ "textDocument/definition", Method.text_document_definition },
            .{ "textDocument/references", Method.text_document_references },
            .{ "textDocument/completion", Method.text_document_completion },
            .{ "textDocument/publishDiagnostics", Method.text_document_publish_diagnostics },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// Parse the LSP framing protocol (Content-Length header followed
/// by `\r\n\r\n` and a JSON body). Returns the body slice from
/// `buffer` along with the total bytes consumed (header + body).
/// Returns null when `buffer` doesn't yet contain a complete frame.
pub fn parseFrame(buffer: []const u8) ?struct { body: []const u8, consumed: usize } {
    const header_end_marker = "\r\n\r\n";
    const header_end = std.mem.indexOf(u8, buffer, header_end_marker) orelse return null;
    const header = buffer[0..header_end];
    const cl_prefix = "Content-Length: ";
    const cl_pos = std.mem.indexOf(u8, header, cl_prefix) orelse return null;
    const cl_start = cl_pos + cl_prefix.len;
    const cl_end_rel = std.mem.indexOf(u8, header[cl_start..], "\r\n") orelse header.len - cl_start;
    const cl_str = header[cl_start .. cl_start + cl_end_rel];
    const content_length = std.fmt.parseInt(usize, cl_str, 10) catch return null;
    const body_start = header_end + header_end_marker.len;
    if (buffer.len < body_start + content_length) return null;
    return .{
        .body = buffer[body_start .. body_start + content_length],
        .consumed = body_start + content_length,
    };
}

/// Encode a JSON-RPC response as an LSP frame (header + body) into
/// the supplied buffer. Caller owns the returned slice.
pub fn encodeFrame(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var nbuf: [32]u8 = undefined;
    const cl = try std.fmt.bufPrint(&nbuf, "Content-Length: {d}\r\n\r\n", .{body.len});
    try out.appendSlice(gpa, cl);
    try out.appendSlice(gpa, body);
    return out.toOwnedSlice(gpa);
}

/// Build a JSON-RPC success response body for `id` with `result`
/// rendered as a JSON value string. Caller owns the returned slice.
pub fn encodeResponse(gpa: std.mem.Allocator, id: RequestId, result: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeRequestId(&buf, gpa, id);
    try buf.appendSlice(gpa, ",\"result\":");
    try buf.appendSlice(gpa, result);
    try buf.append(gpa, '}');
    return buf.toOwnedSlice(gpa);
}

/// Build a JSON-RPC error response body.
pub fn encodeError(gpa: std.mem.Allocator, id: RequestId, err: ResponseError) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeRequestId(&buf, gpa, id);
    try buf.appendSlice(gpa, ",\"error\":{\"code\":");
    var nbuf: [32]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{err.code}));
    try buf.appendSlice(gpa, ",\"message\":\"");
    try writeJsonStringContents(&buf, gpa, err.message);
    try buf.appendSlice(gpa, "\"}}");
    return buf.toOwnedSlice(gpa);
}

fn writeRequestId(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, id: RequestId) !void {
    switch (id) {
        .integer => |n| {
            var nbuf: [32]u8 = undefined;
            try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{n}));
        },
        .string => |s| {
            try buf.append(gpa, '"');
            try writeJsonStringContents(buf, gpa, s);
            try buf.append(gpa, '"');
        },
        .null_id => try buf.appendSlice(gpa, "null"),
    }
}

fn writeJsonStringContents(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => try buf.append(gpa, c),
        }
    }
}

/// Render the result JSON for a textDocument/hover response.
/// Format follows the LSP `Hover` interface.
pub fn renderHoverResult(gpa: std.mem.Allocator, hover: ts_lsp.HoverResult) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"contents\":{\"kind\":\"plaintext\",\"value\":\"");
    try writeJsonStringContents(&buf, gpa, hover.type_repr);
    try buf.appendSlice(gpa, "\"},\"range\":");
    try writeRange(&buf, gpa, hover.span);
    try buf.append(gpa, '}');
    return buf.toOwnedSlice(gpa);
}

/// Render the result JSON for a textDocument/definition response.
/// LSP returns an array of Locations; we always return one entry.
pub fn renderDefinitionResult(gpa: std.mem.Allocator, def: ts_lsp.Definition) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "[{\"uri\":\"file://");
    try writeJsonStringContents(&buf, gpa, def.file);
    try buf.appendSlice(gpa, "\",\"range\":");
    try writeRange(&buf, gpa, def.span);
    try buf.appendSlice(gpa, "}]");
    return buf.toOwnedSlice(gpa);
}

/// Render textDocument/references — array of Location objects.
pub fn renderReferencesResult(gpa: std.mem.Allocator, refs: []const ts_lsp.Span) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (refs, 0..) |s, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"uri\":\"file://");
        try writeJsonStringContents(&buf, gpa, s.file);
        try buf.appendSlice(gpa, "\",\"range\":");
        try writeRange(&buf, gpa, s);
        try buf.append(gpa, '}');
    }
    try buf.append(gpa, ']');
    return buf.toOwnedSlice(gpa);
}

/// Render textDocument/completion — array of CompletionItem.
pub fn renderCompletionResult(gpa: std.mem.Allocator, items: []const ts_lsp.CompletionItem) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (items, 0..) |it, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"label\":\"");
        try writeJsonStringContents(&buf, gpa, it.label);
        try buf.appendSlice(gpa, "\",\"kind\":");
        var nbuf: [4]u8 = undefined;
        const kind_num = lspCompletionItemKind(it.kind);
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{kind_num}));
        try buf.append(gpa, '}');
    }
    try buf.append(gpa, ']');
    return buf.toOwnedSlice(gpa);
}

fn writeRange(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, span: ts_lsp.Span) !void {
    var nbuf: [128]u8 = undefined;
    // LSP uses 0-based line/character; ts_lsp.Span uses 1-based.
    const start_line = if (span.start_line > 0) span.start_line - 1 else 0;
    const start_col = if (span.start_col > 0) span.start_col - 1 else 0;
    const end_line = if (span.end_line > 0) span.end_line - 1 else 0;
    const end_col = if (span.end_col > 0) span.end_col - 1 else 0;
    const fmt = try std.fmt.bufPrint(
        &nbuf,
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ start_line, start_col, end_line, end_col },
    );
    try buf.appendSlice(gpa, fmt);
}

/// Map `ts_lsp.CompletionItem.ItemKind` to the LSP CompletionItemKind
/// constant (per the protocol spec).
fn lspCompletionItemKind(k: ts_lsp.CompletionItem.ItemKind) u8 {
    return switch (k) {
        .variable => 6,
        .function => 3,
        .class => 7,
        .interface => 8,
        .type_alias => 25,
        .module => 9,
        .keyword => 14,
        .member => 5,
    };
}

/// Render the InitializeResult body — declares capabilities for
/// every method we support.
pub fn renderInitializeResult(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8,
        \\{"capabilities":{"textDocumentSync":1,"hoverProvider":true,"definitionProvider":true,"referencesProvider":true,"completionProvider":{"triggerCharacters":[".","("]},"diagnosticProvider":{"interFileDependencies":true,"workspaceDiagnostics":true}},"serverInfo":{"name":"home-lsp","version":"0.1.0"}}
    );
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "parseFrame: complete frame" {
    const input = "Content-Length: 17\r\n\r\n{\"hello\":\"world\"}";
    const r = parseFrame(input) orelse return error.NoFrame;
    try T.expectEqualStrings("{\"hello\":\"world\"}", r.body);
    try T.expectEqual(input.len, r.consumed);
}

test "parseFrame: incomplete frame returns null" {
    try T.expect(parseFrame("Content-Length: 100\r\n\r\n{") == null);
    try T.expect(parseFrame("Content-Length: 5\r\n") == null);
    try T.expect(parseFrame("") == null);
}

test "parseFrame: malformed Content-Length returns null" {
    const r = parseFrame("Content-Length: bogus\r\n\r\n{}");
    try T.expect(r == null);
}

test "encodeFrame: round-trip" {
    const body = "{\"jsonrpc\":\"2.0\"}";
    const frame = try encodeFrame(T.allocator, body);
    defer T.allocator.free(frame);
    const r = parseFrame(frame) orelse return error.RoundTripFailed;
    try T.expectEqualStrings(body, r.body);
}

test "Method.fromString: known methods" {
    try T.expectEqual(Method.initialize, Method.fromString("initialize"));
    try T.expectEqual(Method.text_document_hover, Method.fromString("textDocument/hover"));
    try T.expectEqual(Method.text_document_definition, Method.fromString("textDocument/definition"));
    try T.expectEqual(Method.text_document_references, Method.fromString("textDocument/references"));
    try T.expectEqual(Method.text_document_completion, Method.fromString("textDocument/completion"));
    try T.expectEqual(Method.unknown, Method.fromString("textDocument/madeUp"));
}

test "encodeResponse: id + result body" {
    const r = try encodeResponse(T.allocator, .{ .integer = 42 }, "{\"ok\":true}");
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"id\":42") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"result\":{\"ok\":true}") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"jsonrpc\":\"2.0\"") != null);
}

test "encodeResponse: string id" {
    const r = try encodeResponse(T.allocator, .{ .string = "abc" }, "null");
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"id\":\"abc\"") != null);
}

test "encodeResponse: null id" {
    const r = try encodeResponse(T.allocator, .null_id, "null");
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"id\":null") != null);
}

test "encodeError: code + message" {
    const r = try encodeError(T.allocator, .{ .integer = 1 }, .{ .code = -32601, .message = "Method not found" });
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"code\":-32601") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"message\":\"Method not found\"") != null);
}

test "renderInitializeResult: declares capabilities" {
    const r = try renderInitializeResult(T.allocator);
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "hoverProvider") != null);
    try T.expect(std.mem.indexOf(u8, r, "definitionProvider") != null);
    try T.expect(std.mem.indexOf(u8, r, "referencesProvider") != null);
    try T.expect(std.mem.indexOf(u8, r, "completionProvider") != null);
}

test "renderHoverResult: includes plaintext content + range" {
    const hover: ts_lsp.HoverResult = .{
        .type_repr = "number",
        .span = .{
            .file = "/main.ts",
            .start_line = 1,
            .start_col = 5,
            .end_line = 1,
            .end_col = 6,
        },
        .kind = .identifier,
    };
    const r = try renderHoverResult(T.allocator, hover);
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"value\":\"number\"") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"line\":0") != null);
}

test "renderDefinitionResult: file URI + range" {
    const def: ts_lsp.Definition = .{
        .file = "/main.ts",
        .span = .{
            .file = "/main.ts",
            .start_line = 1,
            .start_col = 1,
            .end_line = 1,
            .end_col = 2,
        },
    };
    const r = try renderDefinitionResult(T.allocator, def);
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"uri\":\"file:///main.ts\"") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"range\":") != null);
}

test "renderCompletionResult: kind mapping" {
    const items = [_]ts_lsp.CompletionItem{
        .{ .label = "foo", .kind = .variable, .detail = "" },
        .{ .label = "bar", .kind = .function, .detail = "" },
        .{ .label = "Baz", .kind = .class, .detail = "" },
    };
    const r = try renderCompletionResult(T.allocator, &items);
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"label\":\"foo\",\"kind\":6") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"label\":\"bar\",\"kind\":3") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"label\":\"Baz\",\"kind\":7") != null);
}

test "renderReferencesResult: empty array" {
    const refs: []const ts_lsp.Span = &.{};
    const r = try renderReferencesResult(T.allocator, refs);
    defer T.allocator.free(r);
    try T.expectEqualStrings("[]", r);
}
