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
//!   - textDocument/signatureHelp
//!   - textDocument/rename
//!   - textDocument/prepareRename
//!   - completionItem/resolve
//!   - textDocument/documentSymbol
//!   - workspace/symbol
//!   - textDocument/codeAction
//!   - textDocument/semanticTokens/full
//!   - textDocument/semanticTokens/range
//!   - textDocument/foldingRange
//!   - textDocument/inlayHint
//!   - textDocument/documentHighlight
//!   - textDocument/formatting
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
    text_document_signature_help,
    text_document_publish_diagnostics,
    text_document_rename,
    text_document_prepare_rename,
    completion_item_resolve,
    text_document_document_symbol,
    workspace_symbol,
    text_document_code_action,
    text_document_semantic_tokens_full,
    text_document_semantic_tokens_range,
    text_document_folding_range,
    text_document_inlay_hint,
    text_document_document_highlight,
    text_document_formatting,
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
            .{ "textDocument/signatureHelp", Method.text_document_signature_help },
            .{ "textDocument/publishDiagnostics", Method.text_document_publish_diagnostics },
            .{ "textDocument/rename", Method.text_document_rename },
            .{ "textDocument/prepareRename", Method.text_document_prepare_rename },
            .{ "completionItem/resolve", Method.completion_item_resolve },
            .{ "textDocument/documentSymbol", Method.text_document_document_symbol },
            .{ "workspace/symbol", Method.workspace_symbol },
            .{ "textDocument/codeAction", Method.text_document_code_action },
            .{ "textDocument/semanticTokens/full", Method.text_document_semantic_tokens_full },
            .{ "textDocument/semanticTokens/range", Method.text_document_semantic_tokens_range },
            .{ "textDocument/foldingRange", Method.text_document_folding_range },
            .{ "textDocument/inlayHint", Method.text_document_inlay_hint },
            .{ "textDocument/documentHighlight", Method.text_document_document_highlight },
            .{ "textDocument/formatting", Method.text_document_formatting },
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

/// Strip a `file://` prefix from a URI, returning the bare filesystem
/// path. Returns the input unchanged when no prefix is present.
pub fn uriToPath(uri: []const u8) []const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) return uri[prefix.len..];
    return uri;
}

/// Locate the JSON value associated with `key` inside `body`. Walks the
/// raw bytes looking for `"key":` and then returns the slice between
/// the opening and matching closing string quote (for string values),
/// taking JSON `\"` and `\\` escapes into account. Returns null when
/// the key isn't found or the value isn't a string. Caller does NOT
/// own the returned slice — it's a borrow into `body`.
fn findJsonStringField(body: []const u8, key: []const u8) ?[]const u8 {
    // Build a transient `"<key>":` needle on the stack.
    var needle_buf: [64]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    needle_buf[2 + key.len] = ':';
    const needle = needle_buf[0 .. 3 + key.len];

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, body, search_from, needle)) |pos| {
        // Skip whitespace after the colon.
        var i = pos + needle.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) : (i += 1) {}
        if (i >= body.len or body[i] != '"') {
            // Not a string value at this site — keep looking; another
            // occurrence of the same key might be a string.
            search_from = pos + needle.len;
            continue;
        }
        // i points at the opening quote. Walk forward looking for the
        // matching closing quote, honoring `\"` and `\\` escapes.
        const start = i + 1;
        var j = start;
        while (j < body.len) : (j += 1) {
            const c = body[j];
            if (c == '\\') {
                j += 1;
                continue;
            }
            if (c == '"') return body[start..j];
        }
        return null;
    }
    return null;
}

/// Decode a JSON-encoded string slice (no surrounding quotes) into a
/// freshly allocated buffer. Handles the standard escapes used by the
/// LSP wire format: `\"`, `\\`, `\/`, `\n`, `\r`, `\t`, `\b`, `\f`. A
/// `\uXXXX` escape is decoded into UTF-8. Caller owns the result.
pub fn decodeJsonString(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c != '\\') {
            try out.append(gpa, c);
            continue;
        }
        if (i + 1 >= raw.len) return error.InvalidEscape;
        const esc = raw[i + 1];
        switch (esc) {
            '"', '\\', '/' => try out.append(gpa, esc),
            'n' => try out.append(gpa, '\n'),
            'r' => try out.append(gpa, '\r'),
            't' => try out.append(gpa, '\t'),
            'b' => try out.append(gpa, 0x08),
            'f' => try out.append(gpa, 0x0c),
            'u' => {
                if (i + 5 >= raw.len) return error.InvalidEscape;
                const cp = try std.fmt.parseInt(u21, raw[i + 2 .. i + 6], 16);
                var ubuf: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(cp, &ubuf);
                try out.appendSlice(gpa, ubuf[0..n]);
                i += 4;
            },
            else => return error.InvalidEscape,
        }
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Handle a `textDocument/didChange` JSON-RPC notification: extract
/// the URI + new full-document text from `params_json`, route to
/// `service.didChangeFile`, then encode a `textDocument/publishDiagnostics`
/// notification body for the caller to write back.
///
/// `params_json` is the raw JSON body of the notification (the entire
/// `params` value's surroundings are accepted — we lift the fields by
/// name so the framing layer can pass either the whole request body
/// or just the `params` object). Caller owns the returned slice.
///
/// Today's implementation assumes full-document sync mode: the client
/// declares `textDocumentSync = 1` (Full) in the InitializeResult, so
/// `contentChanges[0].text` is the entire updated file.
pub fn handleDidChange(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    // The full-document text lives in `params.contentChanges[0].text`;
    // since we look up by key name, the field's nesting is irrelevant.
    const text_raw = findJsonStringField(params_json, "text") orelse return error.MissingText;

    const new_source = try decodeJsonString(gpa, text_raw);
    defer gpa.free(new_source);
    const path = uriToPath(uri);

    const rendered = try service.didChangeFile(gpa, path, new_source);
    defer gpa.free(rendered);

    return encodePublishDiagnostics(gpa, uri, rendered);
}

/// Handle a `textDocument/didOpen` notification: parse `uri` + `text`
/// from `params_json`, register the file with the program graph
/// (adding it if new, updating its source if already tracked), then
/// re-typecheck the program. No response is emitted (notifications
/// have no reply); diagnostics are surfaced via subsequent
/// `publishDiagnostics` notifications.
pub fn handleDidOpen(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    params_json: []const u8,
) !void {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const text_raw = findJsonStringField(params_json, "text") orelse return error.MissingText;

    const source = try decodeJsonString(gpa, text_raw);
    defer gpa.free(source);
    const path = uriToPath(uri);

    if (service.program.lookupPath(path) != null) {
        _ = try service.program.updateSource(path, source);
    } else {
        _ = try service.program.add(path, source);
    }
    try service.program.compileAll(.{});
}

/// Handle a `textDocument/didClose` notification: parse `uri` from
/// `params_json` and acknowledge. Today this is a no-op — the file
/// stays tracked in the program graph so subsequent requests still
/// resolve. A future enhancement would unload the file (drop its
/// compilation, remove from `Program.by_path`).
pub fn handleDidClose(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    params_json: []const u8,
) !void {
    _ = service;
    _ = gpa;
    _ = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
}

/// Locate an integer JSON field by `key` inside `body`. Walks the
/// raw bytes looking for `"key":` and parses a base-10 integer that
/// follows (skipping whitespace). Returns null when the key isn't
/// found or the value isn't a number.
fn findJsonIntField(body: []const u8, key: []const u8) ?i64 {
    var needle_buf: [64]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    needle_buf[2 + key.len] = ':';
    const needle = needle_buf[0 .. 3 + key.len];

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, body, search_from, needle)) |pos| {
        var i = pos + needle.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) : (i += 1) {}
        if (i >= body.len) return null;
        if (body[i] == '-' or (body[i] >= '0' and body[i] <= '9')) {
            const start = i;
            if (body[i] == '-') i += 1;
            while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
            if (i == start) {
                search_from = pos + needle.len;
                continue;
            }
            return std.fmt.parseInt(i64, body[start..i], 10) catch {
                search_from = pos + needle.len;
                continue;
            };
        }
        search_from = pos + needle.len;
    }
    return null;
}

/// Convert a 0-based `(line, character)` LSP position into a byte
/// offset within `source`. `character` is interpreted as a UTF-8
/// byte count (LSP technically uses UTF-16 code units, but ASCII
/// inputs match either way and this matches the rest of the
/// pipeline). When the position falls past the end of a line, the
/// offset clamps to the line's terminating newline. When `line` is
/// past EOF, the offset clamps to `source.len`.
pub fn lineColToByte(source: []const u8, line: u32, character: u32) u32 {
    var current_line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len and current_line < line) : (i += 1) {
        if (source[i] == '\n') {
            current_line += 1;
            line_start = i + 1;
        }
    }
    if (current_line < line) return @intCast(source.len);
    var col: u32 = 0;
    var j: usize = line_start;
    while (j < source.len and col < character and source[j] != '\n') : (j += 1) {
        col += 1;
    }
    return @intCast(j);
}

/// Handle a `textDocument/hover` JSON-RPC request: extract the URI +
/// `(line, character)` from `params_json`, convert to a byte offset
/// into the file's source, route to `service.hover`, and encode the
/// LSP `Hover` response (or `result: null` when no hover info is
/// available). Caller owns the returned slice.
pub fn handleHover(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse return error.MissingLine;
    const character = findJsonIntField(params_json, "character") orelse return error.MissingCharacter;
    const path = uriToPath(uri);

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "null");
    };
    const f = service.program.fileById(file_id);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    const byte_pos = lineColToByte(f.source, line_u, char_u);

    if (service.hover(path, byte_pos)) |hover| {
        // The service heap-allocates `hover.type_repr`; we own it.
        defer service.gpa.free(hover.type_repr);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.appendSlice(gpa, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
        try writeJsonStringContents(&buf, gpa, hover.type_repr);
        try buf.appendSlice(gpa, "\"},\"range\":");
        try writeRange(&buf, gpa, hover.span);
        try buf.append(gpa, '}');
        return encodeResponse(gpa, request_id, buf.items);
    }
    return encodeResponse(gpa, request_id, "null");
}

/// Handle a `textDocument/definition` JSON-RPC request: extract the
/// URI + `(line, character)` from `params_json`, convert to a byte
/// offset into the file's source, route to `service.gotoDefinition`,
/// and encode the LSP response. Per the LSP spec the result type is
/// `Location | Location[] | LocationLink[] | null`; we emit the
/// single `Location` form when a definition resolves and `null`
/// otherwise. Caller owns the returned slice.
pub fn handleDefinition(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse return error.MissingLine;
    const character = findJsonIntField(params_json, "character") orelse return error.MissingCharacter;
    const path = uriToPath(uri);

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "null");
    };
    const f = service.program.fileById(file_id);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    const byte_pos = lineColToByte(f.source, line_u, char_u);

    if (service.gotoDefinition(path, byte_pos)) |def| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.appendSlice(gpa, "{\"uri\":\"file://");
        try writeJsonStringContents(&buf, gpa, def.file);
        try buf.appendSlice(gpa, "\",\"range\":");
        try writeRange(&buf, gpa, def.span);
        try buf.append(gpa, '}');
        return encodeResponse(gpa, request_id, buf.items);
    }
    return encodeResponse(gpa, request_id, "null");
}

/// Handle a `textDocument/references` JSON-RPC request: extract the
/// URI + `(line, character)` from `params_json`, convert to a byte
/// offset into the file's source, route to `service.findReferences`,
/// and encode the LSP response as a `Location[]` array. Caller owns
/// the returned slice.
pub fn handleReferences(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse return error.MissingLine;
    const character = findJsonIntField(params_json, "character") orelse return error.MissingCharacter;
    const path = uriToPath(uri);

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "[]");
    };
    const f = service.program.fileById(file_id);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    const byte_pos = lineColToByte(f.source, line_u, char_u);

    const refs = try service.findReferences(gpa, path, byte_pos);
    defer gpa.free(refs);

    const result = try renderReferencesResult(gpa, refs);
    defer gpa.free(result);
    return encodeResponse(gpa, request_id, result);
}

/// Handle a `textDocument/completion` JSON-RPC request: extract the
/// URI + `(line, character)` from `params_json`, convert to a byte
/// offset into the file's source, route to `service.completions`,
/// and encode the LSP `CompletionList` response. Caller owns the
/// returned slice.
pub fn handleCompletion(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse return error.MissingLine;
    const character = findJsonIntField(params_json, "character") orelse return error.MissingCharacter;
    const path = uriToPath(uri);

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "{\"isIncomplete\":false,\"items\":[]}");
    };
    const f = service.program.fileById(file_id);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    const byte_pos = lineColToByte(f.source, line_u, char_u);

    const items = try service.completions(gpa, path, byte_pos);
    defer gpa.free(items);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"isIncomplete\":false,\"items\":[");
    for (items, 0..) |it, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"label\":\"");
        try writeJsonStringContents(&buf, gpa, it.label);
        try buf.appendSlice(gpa, "\",\"kind\":");
        var nbuf: [4]u8 = undefined;
        const kind_num = lspCompletionItemKind(it.kind);
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{kind_num}));
        if (it.detail.len > 0) {
            try buf.appendSlice(gpa, ",\"detail\":\"");
            try writeJsonStringContents(&buf, gpa, it.detail);
            try buf.append(gpa, '"');
        }
        if (it.auto_import_from.len > 0) {
            try buf.appendSlice(gpa, ",\"data\":{\"auto_import_from\":\"");
            try writeJsonStringContents(&buf, gpa, it.auto_import_from);
            try buf.appendSlice(gpa, "\"}");
        }
        try buf.append(gpa, '}');
    }
    try buf.appendSlice(gpa, "]}");
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/signatureHelp` JSON-RPC request: extract the
/// URI + `(line, character)` from `params_json`, convert to a byte
/// offset into the file's source, route to `service.signatureHelp`,
/// and encode the LSP `SignatureHelp` response (or `result: null` when
/// the cursor isn't inside a call expression). Caller owns the
/// returned slice.
pub fn handleSignatureHelp(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse return error.MissingLine;
    const character = findJsonIntField(params_json, "character") orelse return error.MissingCharacter;
    const path = uriToPath(uri);

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "null");
    };
    const f = service.program.fileById(file_id);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    const byte_pos = lineColToByte(f.source, line_u, char_u);

    const maybe_sig = service.signatureHelp(gpa, path, byte_pos) catch null;
    const sig = maybe_sig orelse return encodeResponse(gpa, request_id, "null");
    defer {
        gpa.free(sig.label);
        for (sig.parameters) |p| gpa.free(p);
        gpa.free(sig.parameters);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"signatures\":[{\"label\":\"");
    try writeJsonStringContents(&buf, gpa, sig.label);
    try buf.appendSlice(gpa, "\",\"parameters\":[");
    for (sig.parameters, 0..) |p, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"label\":\"");
        try writeJsonStringContents(&buf, gpa, p);
        try buf.appendSlice(gpa, "\"}");
    }
    try buf.appendSlice(gpa, "]}],\"activeSignature\":0,\"activeParameter\":");
    var nbuf: [16]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{sig.active_parameter}));
    try buf.append(gpa, '}');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Map a `ts_lsp.SymbolInfo.SymbolKind` to the LSP `SymbolKind`
/// integer constant from the spec.
fn lspSymbolKind(k: ts_lsp.SymbolInfo.SymbolKind) u8 {
    return switch (k) {
        .function => 12,
        .class => 5,
        .interface => 11,
        .variable => 13,
        .type_alias => 26, // TypeParameter — closest stock kind for a TS type alias.
        .enum_ => 10,
        .namespace => 3,
        .module => 2,
        .property => 7,
        .method => 6,
        .enum_member => 22,
    };
}

/// Map a `ts_lsp.CodeAction.Kind` to the LSP `CodeActionKind` string.
fn lspCodeActionKind(k: ts_lsp.CodeAction.Kind) []const u8 {
    return switch (k) {
        .organize_imports => "source.organizeImports",
        .sort_imports => "source.sortImports",
        .fix_all => "source.fixAll",
        .quick_fix => "quickfix",
    };
}

/// Map a `ts_lsp.FoldingRange.Kind` to the LSP `FoldingRangeKind` string.
fn lspFoldingRangeKind(k: ts_lsp.FoldingRange.Kind) []const u8 {
    return switch (k) {
        .region => "region",
        .comment => "comment",
        .imports => "imports",
    };
}

/// Map a `ts_lsp.InlayHint` `kind` field to the LSP `InlayHintKind`
/// integer constant (Type=1, Parameter=2). The kind is an anonymous
/// enum nested inside `ts_lsp.InlayHint`, so we reach through a sample
/// instance's field-type to keep the function signature in sync with
/// the upstream definition.
const InlayHintKind = @FieldType(ts_lsp.InlayHint, "kind");
fn lspInlayHintKind(k: InlayHintKind) u8 {
    return switch (k) {
        .type_annotation => 1,
        .parameter_name => 2,
    };
}

/// Map a `ts_lsp.Highlight.Kind` to the LSP `DocumentHighlightKind`
/// integer constant (Text=1, Read=2, Write=3).
fn lspHighlightKind(k: ts_lsp.Highlight.Kind) u8 {
    return switch (k) {
        .text => 1,
        .read => 2,
        .write => 3,
    };
}

/// Render a single `SymbolInfo` (recursively, with children) as an
/// LSP `DocumentSymbol` JSON object.
fn writeDocumentSymbol(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    sym: ts_lsp.SymbolInfo,
) !void {
    try buf.appendSlice(gpa, "{\"name\":\"");
    try writeJsonStringContents(buf, gpa, sym.name);
    try buf.appendSlice(gpa, "\",\"kind\":");
    var nbuf: [4]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{lspSymbolKind(sym.kind)}));
    try buf.appendSlice(gpa, ",\"range\":");
    try writeRange(buf, gpa, sym.span);
    try buf.appendSlice(gpa, ",\"selectionRange\":");
    try writeRange(buf, gpa, sym.span);
    if (sym.children.len > 0) {
        try buf.appendSlice(gpa, ",\"children\":[");
        for (sym.children, 0..) |child, i| {
            if (i > 0) try buf.append(gpa, ',');
            try writeDocumentSymbol(buf, gpa, child);
        }
        try buf.append(gpa, ']');
    }
    try buf.append(gpa, '}');
}

/// Render a `TextEdit` produced by `Service.rename` / `formatDocument`
/// / `codeActions` as an LSP `TextEdit` JSON object. The `TextEdit`
/// struct already carries 0-based line/col, so no adjustment is needed
/// (unlike `Span` which is 1-based and goes through `writeRange`).
fn writeTextEdit(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    edit: ts_lsp.TextEdit,
) !void {
    var nbuf: [128]u8 = undefined;
    const fmt = try std.fmt.bufPrint(
        &nbuf,
        "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":\"",
        .{ edit.start_line, edit.start_col, edit.end_line, edit.end_col },
    );
    try buf.appendSlice(gpa, fmt);
    try writeJsonStringContents(buf, gpa, edit.new_text);
    try buf.appendSlice(gpa, "\"}");
}

/// Handle a `textDocument/rename` JSON-RPC request. Extracts URI +
/// `(line, character)` + `newName`, routes to `Service.rename`, and
/// emits an LSP `WorkspaceEdit` whose `changes` map groups the
/// returned `[]TextEdit` by URI. Caller owns the returned slice.
pub fn handleRename(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse return error.MissingLine;
    const character = findJsonIntField(params_json, "character") orelse return error.MissingCharacter;
    const new_name_raw = findJsonStringField(params_json, "newName") orelse return error.MissingNewName;
    const new_name = try decodeJsonString(gpa, new_name_raw);
    defer gpa.free(new_name);
    const path = uriToPath(uri);

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "null");
    };
    const f = service.program.fileById(file_id);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    const byte_pos = lineColToByte(f.source, line_u, char_u);

    const edits = try service.rename(gpa, path, byte_pos, new_name);
    defer gpa.free(edits);

    // Group edits by file path so we can emit one `changes` entry per URI.
    var by_file: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
    defer {
        var it = by_file.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
        by_file.deinit(gpa);
    }
    for (edits, 0..) |e, idx| {
        const gop = try by_file.getOrPut(gpa, e.file);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.*.append(gpa, idx);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"changes\":{");
    var first = true;
    var it = by_file.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.append(gpa, ',');
        first = false;
        try buf.append(gpa, '"');
        try buf.appendSlice(gpa, "file://");
        try writeJsonStringContents(&buf, gpa, entry.key_ptr.*);
        try buf.appendSlice(gpa, "\":[");
        for (entry.value_ptr.*.items, 0..) |edit_idx, i| {
            if (i > 0) try buf.append(gpa, ',');
            try writeTextEdit(&buf, gpa, edits[edit_idx]);
        }
        try buf.append(gpa, ']');
    }
    try buf.appendSlice(gpa, "}}");
    return encodeResponse(gpa, request_id, buf.items);
}

/// True when `c` is a valid identifier-continuation byte (ASCII
/// letter, digit, underscore, or `$`). Mirrors the lexer's notion of
/// `isIdentPart`. Pure ASCII — non-ASCII bytes are conservatively
/// rejected, which is acceptable since the LSP layer only uses this
/// for word-boundary detection in `handlePrepareRename`.
fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '$';
}

/// True when `c` can start an identifier (excludes ASCII digits).
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        c == '_' or c == '$';
}

/// Handle a `textDocument/prepareRename` JSON-RPC request: parse
/// `uri` + `(line, character)`, find the identifier extents that
/// straddle `byte_pos`, and emit either a
/// `{ range, placeholder }` object or `null` when the cursor isn't on
/// a renamable identifier. Per the LSP spec the response shape may
/// also be a bare `Range`; we always return the richer
/// `{ range, placeholder }` form so clients pre-fill the rename
/// input. Caller owns the returned slice.
pub fn handlePrepareRename(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse return error.MissingLine;
    const character = findJsonIntField(params_json, "character") orelse return error.MissingCharacter;
    const path = uriToPath(uri);

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "null");
    };
    const f = service.program.fileById(file_id);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    const byte_pos = lineColToByte(f.source, line_u, char_u);

    // Walk left for the identifier start, right for the end. The
    // cursor may sit one byte past the last identifier character (a
    // common editor convention), so when `byte_pos` itself isn't an
    // identifier byte we also try `byte_pos - 1`.
    const src = f.source;
    var probe: usize = byte_pos;
    if (probe >= src.len or !isIdentChar(src[probe])) {
        if (probe == 0) return encodeResponse(gpa, request_id, "null");
        if (!isIdentChar(src[probe - 1])) return encodeResponse(gpa, request_id, "null");
        probe -= 1;
    }
    var start: usize = probe;
    while (start > 0 and isIdentChar(src[start - 1])) : (start -= 1) {}
    if (!isIdentStart(src[start])) return encodeResponse(gpa, request_id, "null");
    var end: usize = probe + 1;
    while (end < src.len and isIdentChar(src[end])) : (end += 1) {}

    const start_pos = byteToLineCol(src, @intCast(start));
    const end_pos = byteToLineCol(src, @intCast(end));
    const name = src[start..end];

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var nbuf: [128]u8 = undefined;
    const fmt = try std.fmt.bufPrint(
        &nbuf,
        "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"placeholder\":\"",
        .{ start_pos.line, start_pos.character, end_pos.line, end_pos.character },
    );
    try buf.appendSlice(gpa, fmt);
    try writeJsonStringContents(&buf, gpa, name);
    try buf.appendSlice(gpa, "\"}");
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `completionItem/resolve` JSON-RPC request. Per the LSP
/// spec the client sends back a CompletionItem from a prior
/// `textDocument/completion` response and expects the same shape
/// echoed back with optional fields (e.g. `documentation`,
/// `detail`) populated. Today this is a stub: we return the input
/// item verbatim. A future enhancement would resolve `data` /
/// `auto_import_from` payloads and attach symbol-level docs. Caller
/// owns the returned slice.
pub fn handleCompletionItemResolve(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    _ = service;
    // The CompletionItem itself is the entire `params` value (the
    // protocol passes the item as the request's `params`). Echo it
    // back unchanged; if we can't locate an object, fall through to
    // an empty `{}`.
    if (std.mem.indexOfScalar(u8, params_json, '{')) |obj_start| {
        // Find the matching closing brace by tracking depth so we
        // ignore braces inside strings.
        var depth: usize = 0;
        var in_str = false;
        var i: usize = obj_start;
        while (i < params_json.len) : (i += 1) {
            const ch = params_json[i];
            if (in_str) {
                if (ch == '\\') {
                    i += 1;
                    continue;
                }
                if (ch == '"') in_str = false;
                continue;
            }
            if (ch == '"') {
                in_str = true;
                continue;
            }
            if (ch == '{') depth += 1;
            if (ch == '}') {
                depth -= 1;
                if (depth == 0) {
                    return encodeResponse(gpa, request_id, params_json[obj_start .. i + 1]);
                }
            }
        }
    }
    return encodeResponse(gpa, request_id, "{}");
}

/// Handle a `textDocument/documentSymbol` JSON-RPC request: extract
/// the URI, route to `Service.documentSymbols`, and emit an LSP
/// `DocumentSymbol[]` array (with nested `children`). Caller owns
/// the returned slice.
pub fn handleDocumentSymbol(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const symbols = try service.documentSymbols(gpa, path);
    defer ts_lsp.freeSymbols(gpa, symbols);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (symbols, 0..) |sym, i| {
        if (i > 0) try buf.append(gpa, ',');
        try writeDocumentSymbol(&buf, gpa, sym);
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `workspace/symbol` JSON-RPC request: extract the `query`
/// string, route to `Service.workspaceSymbols`, and emit an LSP
/// `WorkspaceSymbol[]` array (each item carries `name`, `kind`, and a
/// `location` with the file URI + range). Caller owns the returned
/// slice.
pub fn handleWorkspaceSymbol(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const query_raw_opt = findJsonStringField(params_json, "query");
    const query: []const u8 = if (query_raw_opt) |q|
        try decodeJsonString(gpa, q)
    else
        try gpa.dupe(u8, "");
    defer gpa.free(query);

    const symbols = try service.workspaceSymbols(gpa, query);
    defer ts_lsp.freeSymbols(gpa, symbols);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (symbols, 0..) |sym, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"name\":\"");
        try writeJsonStringContents(&buf, gpa, sym.name);
        try buf.appendSlice(gpa, "\",\"kind\":");
        var nbuf: [4]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{lspSymbolKind(sym.kind)}));
        try buf.appendSlice(gpa, ",\"location\":{\"uri\":\"file://");
        try writeJsonStringContents(&buf, gpa, sym.span.file);
        try buf.appendSlice(gpa, "\",\"range\":");
        try writeRange(&buf, gpa, sym.span);
        try buf.appendSlice(gpa, "}}");
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/codeAction` JSON-RPC request: extract the
/// URI, route to `Service.codeActions`, and emit an LSP
/// `CodeAction[]` array (each item has `title`, `kind`, and an `edit`
/// `WorkspaceEdit`). Caller owns the returned slice.
pub fn handleCodeAction(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const actions = try service.codeActions(gpa, path);
    defer {
        for (actions) |a| {
            // `title` is sometimes static ("Organize Imports") and
            // sometimes heap-allocated ("Add explicit type to x").
            // We can't tell the two apart; mirror the test fixtures
            // which only free the heap-allocated quick_fix titles.
            if (a.kind == .quick_fix) gpa.free(a.title);
            for (a.edits) |e| gpa.free(e.new_text);
            gpa.free(a.edits);
        }
        gpa.free(actions);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (actions, 0..) |action, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"title\":\"");
        try writeJsonStringContents(&buf, gpa, action.title);
        try buf.appendSlice(gpa, "\",\"kind\":\"");
        try buf.appendSlice(gpa, lspCodeActionKind(action.kind));
        try buf.appendSlice(gpa, "\",\"edit\":{\"changes\":{");
        // All edits in a single CodeAction may target multiple files;
        // group them by file like rename does.
        var by_file: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
        defer {
            var it = by_file.iterator();
            while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
            by_file.deinit(gpa);
        }
        for (action.edits, 0..) |e, idx| {
            const gop = try by_file.getOrPut(gpa, e.file);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.*.append(gpa, idx);
        }
        var first = true;
        var it = by_file.iterator();
        while (it.next()) |entry| {
            if (!first) try buf.append(gpa, ',');
            first = false;
            try buf.append(gpa, '"');
            try buf.appendSlice(gpa, "file://");
            try writeJsonStringContents(&buf, gpa, entry.key_ptr.*);
            try buf.appendSlice(gpa, "\":[");
            for (entry.value_ptr.*.items, 0..) |edit_idx, j| {
                if (j > 0) try buf.append(gpa, ',');
                try writeTextEdit(&buf, gpa, action.edits[edit_idx]);
            }
            try buf.append(gpa, ']');
        }
        try buf.appendSlice(gpa, "}}}");
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Render a `[]u32` semantic-tokens wire array as an LSP
/// `SemanticTokens` `{ "data": [...] }` JSON object. Internal helper
/// for the `full` and `range` handlers.
fn renderSemanticTokensWire(
    gpa: std.mem.Allocator,
    data: []const u32,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"data\":[");
    for (data, 0..) |v, i| {
        if (i > 0) try buf.append(gpa, ',');
        var nbuf: [16]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{v}));
    }
    try buf.appendSlice(gpa, "]}");
    return buf.toOwnedSlice(gpa);
}

/// Handle a `textDocument/semanticTokens/full` JSON-RPC request:
/// extract the URI, route to `Service.semanticTokensWire`, and emit
/// an LSP `SemanticTokens` `{ data: u32[] }` response. Caller owns
/// the returned slice.
pub fn handleSemanticTokensFull(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const data = try service.semanticTokensWire(gpa, path);
    defer gpa.free(data);

    const result = try renderSemanticTokensWire(gpa, data);
    defer gpa.free(result);
    return encodeResponse(gpa, request_id, result);
}

/// Handle a `textDocument/semanticTokens/range` JSON-RPC request:
/// extract the URI + range start/end lines, route to
/// `Service.semanticTokensRange`, and emit an LSP `SemanticTokens`
/// `{ data: u32[] }` response. Caller owns the returned slice.
pub fn handleSemanticTokensRange(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    // The LSP spec wraps the range in a `range: { start: {...}, end: {...} }`
    // sub-object. Both `start.line` and `end.line` are reachable by
    // first-occurrence-wins lookups since they're both spelled `line`
    // — so we hand-walk to find the second `line`. Easiest approach:
    // locate the `"end":` substring and search for `line` after it.
    var start_line: i64 = 0;
    var end_line: i64 = std.math.maxInt(i64);
    if (std.mem.indexOf(u8, params_json, "\"start\":")) |sp| {
        start_line = findJsonIntField(params_json[sp..], "line") orelse 0;
    }
    if (std.mem.indexOf(u8, params_json, "\"end\":")) |ep| {
        end_line = findJsonIntField(params_json[ep..], "line") orelse std.math.maxInt(i64);
    }
    const sl_u: u32 = if (start_line < 0) 0 else @intCast(@min(start_line, std.math.maxInt(u32)));
    const el_u: u32 = if (end_line < 0) 0 else @intCast(@min(end_line, std.math.maxInt(u32)));

    const data = try service.semanticTokensRange(gpa, path, sl_u, el_u);
    defer gpa.free(data);

    const result = try renderSemanticTokensWire(gpa, data);
    defer gpa.free(result);
    return encodeResponse(gpa, request_id, result);
}

/// Handle a `textDocument/foldingRange` JSON-RPC request: extract the
/// URI, route to `Service.foldingRanges`, and emit an LSP
/// `FoldingRange[]` array. Caller owns the returned slice.
pub fn handleFoldingRange(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const ranges = try service.foldingRanges(gpa, path);
    defer gpa.free(ranges);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (ranges, 0..) |r, i| {
        if (i > 0) try buf.append(gpa, ',');
        var nbuf: [64]u8 = undefined;
        const fmt = try std.fmt.bufPrint(
            &nbuf,
            "{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"",
            .{ r.start_line, r.end_line },
        );
        try buf.appendSlice(gpa, fmt);
        try buf.appendSlice(gpa, lspFoldingRangeKind(r.kind));
        try buf.appendSlice(gpa, "\"}");
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Convert a 0-based byte offset into a 0-based `(line, character)`
/// LSP position. Walks `source` once. Used by `handleInlayHint` to
/// project `Service.inlayHints` byte positions back into LSP space.
fn byteToLineCol(source: []const u8, byte_pos: u32) struct { line: u32, character: u32 } {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: u32 = 0;
    while (i < byte_pos and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}

/// Handle a `textDocument/inlayHint` JSON-RPC request: extract the
/// URI, route to `Service.inlayHints`, and emit an LSP `InlayHint[]`
/// array. Each hint carries a `position` (line/character), a `label`,
/// and a numeric `kind`. Caller owns the returned slice.
pub fn handleInlayHint(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "[]");
    };
    const f = service.program.fileById(file_id);

    const hints = try service.inlayHints(gpa, path);
    defer {
        for (hints) |h| gpa.free(h.label);
        gpa.free(hints);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (hints, 0..) |h, i| {
        if (i > 0) try buf.append(gpa, ',');
        const pos = byteToLineCol(f.source, h.pos);
        var nbuf: [64]u8 = undefined;
        const fmt = try std.fmt.bufPrint(
            &nbuf,
            "{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\"",
            .{ pos.line, pos.character },
        );
        try buf.appendSlice(gpa, fmt);
        try writeJsonStringContents(&buf, gpa, h.label);
        try buf.appendSlice(gpa, "\",\"kind\":");
        var nbuf2: [4]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf2, "{d}", .{lspInlayHintKind(h.kind)}));
        try buf.append(gpa, '}');
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/documentHighlight` JSON-RPC request: extract
/// the URI + cursor position, route to `Service.documentHighlights`,
/// and emit an LSP `DocumentHighlight[]` array (each item has a
/// `range` and an integer `kind`). Caller owns the returned slice.
pub fn handleDocumentHighlight(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse return error.MissingLine;
    const character = findJsonIntField(params_json, "character") orelse return error.MissingCharacter;
    const path = uriToPath(uri);

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "[]");
    };
    const f = service.program.fileById(file_id);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    const byte_pos = lineColToByte(f.source, line_u, char_u);

    const hls = try service.documentHighlights(gpa, path, byte_pos);
    defer gpa.free(hls);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (hls, 0..) |h, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"range\":");
        try writeRange(&buf, gpa, h.span);
        try buf.appendSlice(gpa, ",\"kind\":");
        var nbuf: [4]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{lspHighlightKind(h.kind)}));
        try buf.append(gpa, '}');
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/formatting` JSON-RPC request: extract the
/// URI, route to `Service.formatDocument`, and emit an LSP
/// `TextEdit[]` array. Caller owns the returned slice.
pub fn handleFormatting(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const edits = try service.formatDocument(gpa, path);
    defer gpa.free(edits);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (edits, 0..) |e, i| {
        if (i > 0) try buf.append(gpa, ',');
        try writeTextEdit(&buf, gpa, e);
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Encode a `textDocument/publishDiagnostics` JSON-RPC notification
/// body. `rendered` is the `\n`-terminated tsc-style diagnostic
/// listing returned by `Service.diagnostics` / `Service.didChangeFile`.
/// Each non-empty line is wrapped in a minimal LSP `Diagnostic`
/// object with `range = (0,0)..(0,0)` and severity = Error (1).
/// Caller owns the returned slice.
pub fn encodePublishDiagnostics(
    gpa: std.mem.Allocator,
    uri: []const u8,
    rendered: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    try writeJsonStringContents(&buf, gpa, uri);
    try buf.appendSlice(gpa, "\",\"diagnostics\":[");
    var first = true;
    var it = std.mem.splitScalar(u8, rendered, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (!first) try buf.append(gpa, ',');
        first = false;
        try buf.appendSlice(gpa, "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"severity\":1,\"message\":\"");
        try writeJsonStringContents(&buf, gpa, line);
        try buf.appendSlice(gpa, "\"}");
    }
    try buf.appendSlice(gpa, "]}}");
    return buf.toOwnedSlice(gpa);
}

/// Render the InitializeResult body — declares capabilities for
/// every method we support.
pub fn renderInitializeResult(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8,
        \\{"capabilities":{"textDocumentSync":1,"hoverProvider":true,"definitionProvider":true,"referencesProvider":true,"completionProvider":{"triggerCharacters":[".","("]},"diagnosticProvider":{"interFileDependencies":true,"workspaceDiagnostics":true}},"serverInfo":{"name":"home-lsp","version":"0.1.0"}}
    );
}

/// Render the full InitializeResult capabilities response advertised
/// by `initialize`. This is the long-form descriptor used by the
/// lifecycle handler — the older `renderInitializeResult` remains for
/// the legacy stdio loop in `lsp_main.zig`.
pub fn renderInitializeCapabilities(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8,
        \\{"capabilities":{"textDocumentSync":1,"hoverProvider":true,"definitionProvider":true,"referencesProvider":true,"completionProvider":{"triggerCharacters":["."," "]},"documentSymbolProvider":true,"workspaceSymbolProvider":true,"renameProvider":true,"codeActionProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["variable","parameter","function","method","class","interface","type","enum","property","keyword","string","number","operator","comment"],"tokenModifiers":[]},"full":true,"range":true},"signatureHelpProvider":{"triggerCharacters":["(",","]},"documentHighlightProvider":false,"documentFormattingProvider":true,"foldingRangeProvider":true},"serverInfo":{"name":"home-lsp","version":"0.1.0"}}
    );
}

/// Handle an `initialize` JSON-RPC request. Returns a fully encoded
/// JSON-RPC response body advertising the server's capabilities. The
/// `params_json` is currently unused — once we honor client
/// `workspaceFolders` / `clientCapabilities`, that's where they'll be
/// extracted from. Caller owns the returned slice.
pub fn handleInitialize(
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    _ = params_json;
    const result = try renderInitializeCapabilities(gpa);
    defer gpa.free(result);
    return encodeResponse(gpa, request_id, result);
}

/// Handle a `shutdown` JSON-RPC request. Per the LSP spec the server
/// must respond with `result: null`; the actual process termination
/// is deferred to a subsequent `exit` notification. Caller owns the
/// returned slice.
pub fn handleShutdown(
    gpa: std.mem.Allocator,
    request_id: RequestId,
) ![]u8 {
    return encodeResponse(gpa, request_id, "null");
}

/// Handle the `initialized` notification — sent by the client once it
/// has processed `InitializeResult`. No-op acknowledgment; we don't
/// emit a response (notifications never have one).
pub fn handleInitialized(
    gpa: std.mem.Allocator,
    params_json: []const u8,
) !void {
    _ = gpa;
    _ = params_json;
}

/// Handle the `exit` notification — terminates the server with status
/// code 0. Per the LSP spec this fires after `shutdown`. Does not
/// return.
pub fn handleExit(gpa: std.mem.Allocator) !void {
    _ = gpa;
    std.process.exit(0);
}

/// Look up an LSP method name in the `Method` enum. Thin wrapper over
/// `Method.fromString` so the dispatch site reads naturally.
pub fn lspMethodFromString(s: []const u8) Method {
    return Method.fromString(s);
}

/// Locate the JSON-RPC `id` field inside `body` and return a
/// `RequestId` representation. Returns `null` when the field is
/// absent (i.e. a JSON-RPC notification).
fn findJsonRequestId(body: []const u8) ?RequestId {
    if (findJsonStringField(body, "id")) |s| return .{ .string = s };
    if (findJsonIntField(body, "id")) |n| return .{ .integer = n };
    return null;
}

/// Locate the raw JSON value associated with `key` inside `body`.
/// Returns the slice covering the value (object / array / scalar).
/// Caller does NOT own the returned slice — it borrows from `body`.
fn findJsonRawField(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    needle_buf[2 + key.len] = ':';
    const needle = needle_buf[0 .. 3 + key.len];

    const pos = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = pos + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) : (i += 1) {}
    if (i >= body.len) return null;
    const start = i;
    const c = body[i];
    if (c == '{' or c == '[') {
        const open = c;
        const close: u8 = if (open == '{') '}' else ']';
        var depth: usize = 0;
        var in_str = false;
        while (i < body.len) : (i += 1) {
            const ch = body[i];
            if (in_str) {
                if (ch == '\\') {
                    i += 1;
                    continue;
                }
                if (ch == '"') in_str = false;
                continue;
            }
            if (ch == '"') {
                in_str = true;
                continue;
            }
            if (ch == open) depth += 1;
            if (ch == close) {
                depth -= 1;
                if (depth == 0) return body[start .. i + 1];
            }
        }
        return null;
    }
    return null;
}

/// Parse a JSON-RPC frame from `frame_bytes` and route to the
/// appropriate `handle*` function. Returns the wire-encoded response
/// body bytes (caller owns) — or an empty slice for notifications
/// that have no response. Unknown methods produce a JSON-RPC
/// `Method not found` error response (-32601).
pub fn dispatchRequest(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    frame_bytes: []const u8,
) ![]u8 {
    // Minimal envelope extraction: id (optional), method, params.
    const maybe_id = findJsonRequestId(frame_bytes);
    const method_name = findJsonStringField(frame_bytes, "method") orelse "";
    const method = lspMethodFromString(method_name);
    const params = findJsonRawField(frame_bytes, "params") orelse frame_bytes;

    // Notifications carry no `id` — the server never replies to them.
    const is_notification = maybe_id == null;
    const id = maybe_id orelse RequestId{ .null_id = {} };

    switch (method) {
        .initialize => {
            if (is_notification) return &.{};
            return try handleInitialize(gpa, id, params);
        },
        .initialized => {
            try handleInitialized(gpa, params);
            return &.{};
        },
        .shutdown => {
            if (is_notification) return &.{};
            return try handleShutdown(gpa, id);
        },
        .exit => {
            // The handler terminates the process; never returns. We
            // never reach the `return &.{}` below in production, but
            // tests stub `handleExit` out by not calling dispatch on
            // `exit`.
            try handleExit(gpa);
            return &.{};
        },
        .text_document_did_change => {
            return try handleDidChange(service, gpa, params);
        },
        .text_document_did_open => {
            try handleDidOpen(service, gpa, params);
            return &.{};
        },
        .text_document_did_close => {
            try handleDidClose(service, gpa, params);
            return &.{};
        },
        .text_document_publish_diagnostics => {
            // Server-pushed notification we accept inbound but ignore.
            return &.{};
        },
        .text_document_hover => {
            if (is_notification) return &.{};
            return try handleHover(service, gpa, id, params);
        },
        .text_document_definition => {
            if (is_notification) return &.{};
            return try handleDefinition(service, gpa, id, params);
        },
        .text_document_references => {
            if (is_notification) return &.{};
            return try handleReferences(service, gpa, id, params);
        },
        .text_document_completion => {
            if (is_notification) return &.{};
            return try handleCompletion(service, gpa, id, params);
        },
        .text_document_signature_help => {
            if (is_notification) return &.{};
            return try handleSignatureHelp(service, gpa, id, params);
        },
        .text_document_rename => {
            if (is_notification) return &.{};
            return try handleRename(service, gpa, id, params);
        },
        .text_document_prepare_rename => {
            if (is_notification) return &.{};
            return try handlePrepareRename(service, gpa, id, params);
        },
        .completion_item_resolve => {
            if (is_notification) return &.{};
            return try handleCompletionItemResolve(service, gpa, id, params);
        },
        .text_document_document_symbol => {
            if (is_notification) return &.{};
            return try handleDocumentSymbol(service, gpa, id, params);
        },
        .workspace_symbol => {
            if (is_notification) return &.{};
            return try handleWorkspaceSymbol(service, gpa, id, params);
        },
        .text_document_code_action => {
            if (is_notification) return &.{};
            return try handleCodeAction(service, gpa, id, params);
        },
        .text_document_semantic_tokens_full => {
            if (is_notification) return &.{};
            return try handleSemanticTokensFull(service, gpa, id, params);
        },
        .text_document_semantic_tokens_range => {
            if (is_notification) return &.{};
            return try handleSemanticTokensRange(service, gpa, id, params);
        },
        .text_document_folding_range => {
            if (is_notification) return &.{};
            return try handleFoldingRange(service, gpa, id, params);
        },
        .text_document_inlay_hint => {
            if (is_notification) return &.{};
            return try handleInlayHint(service, gpa, id, params);
        },
        .text_document_document_highlight => {
            if (is_notification) return &.{};
            return try handleDocumentHighlight(service, gpa, id, params);
        },
        .text_document_formatting => {
            if (is_notification) return &.{};
            return try handleFormatting(service, gpa, id, params);
        },
        // Catch-all for unknown methods — fall through to standard
        // JSON-RPC `Method not found` error.
        .unknown => {
            return try encodeError(gpa, id, .{ .code = -32601, .message = "Method not found" });
        },
    }
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

test "handleInitialize: response advertises full capability set" {
    const r = try handleInitialize(T.allocator, .{ .integer = 1 }, "{}");
    defer T.allocator.free(r);
    // Envelope.
    try T.expect(std.mem.indexOf(u8, r, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"id\":1") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"result\":{\"capabilities\":") != null);
    // Required capability flags.
    try T.expect(std.mem.indexOf(u8, r, "\"textDocumentSync\":1") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"hoverProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"definitionProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"referencesProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"documentSymbolProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"workspaceSymbolProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"renameProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"codeActionProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"documentFormattingProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"foldingRangeProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"documentHighlightProvider\":false") != null);
    // Provider sub-objects.
    try T.expect(std.mem.indexOf(u8, r, "\"completionProvider\":{\"triggerCharacters\":[\".\",\" \"]}") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"semanticTokensProvider\"") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"tokenTypes\":[") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"full\":true") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"range\":true") != null);
}

test "handleShutdown: returns null result envelope" {
    const r = try handleShutdown(T.allocator, .{ .integer = 99 });
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"id\":99") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"result\":null") != null);
}

test "handleInitialized: notification is a no-op" {
    try handleInitialized(T.allocator, "{}");
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

test "uriToPath: strips file:// prefix" {
    try T.expectEqualStrings("/main.ts", uriToPath("file:///main.ts"));
    try T.expectEqualStrings("/main.ts", uriToPath("/main.ts"));
}

test "findJsonStringField: locates uri + text" {
    const body =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///main.ts","version":2},"contentChanges":[{"text":"let x = 1;"}]}}
    ;
    try T.expectEqualStrings("file:///main.ts", findJsonStringField(body, "uri").?);
    try T.expectEqualStrings("let x = 1;", findJsonStringField(body, "text").?);
}

test "decodeJsonString: handles common escapes" {
    const a = try decodeJsonString(T.allocator, "let s = \\\"hi\\\";\\nlet n = 1;");
    defer T.allocator.free(a);
    try T.expectEqualStrings("let s = \"hi\";\nlet n = 1;", a);
}

test "handleDidChange: routes notification to Service.didChangeFile" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Seed the file with a type error so the initial diagnostics
    // are non-empty.
    _ = try program.add("/main.ts", "let x: number = \"hi\";");
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Synthesize a JSON-RPC didChange notification body whose
    // `contentChanges[0].text` fixes the type error.
    const body =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///main.ts","version":2},"contentChanges":[{"text":"let x: number = 1;"}]}}
    ;
    const out = try handleDidChange(&svc, T.allocator, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"method\":\"textDocument/publishDiagnostics\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"uri\":\"file:///main.ts\"") != null);
    // The fixed source produces no diagnostics, so the array is empty.
    try T.expect(std.mem.indexOf(u8, out, "\"diagnostics\":[]") != null);

    // Re-issue with a broken edit and confirm a diagnostic surfaces.
    const broken =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///main.ts","version":3},"contentChanges":[{"text":"let x: number = \"oops\";"}]}}
    ;
    const out2 = try handleDidChange(&svc, T.allocator, broken);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"diagnostics\":[]") == null);
    try T.expect(std.mem.indexOf(u8, out2, "error TS") != null);
}

test "handleDidOpen: adds a new file to the program" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    var svc = ts_lsp.Service.init(T.allocator, &program);

    // File not yet tracked.
    try T.expect(program.lookupPath("/main.ts") == null);

    const body =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///main.ts","languageId":"typescript","version":1,"text":"let x: number = 1;"}}}
    ;
    const params = findJsonRawField(body, "params").?;
    try handleDidOpen(&svc, T.allocator, params);

    // After didOpen the file is tracked + has a compilation.
    const id = program.lookupPath("/main.ts") orelse return error.TestUnexpectedResult;
    const f = program.fileById(id);
    try T.expect(f.compilation != null);
    try T.expectEqualStrings("let x: number = 1;", f.source);
}

test "handleDidClose: accepts notification (no-op)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x = 1;");
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///main.ts"}}}
    ;
    const params = findJsonRawField(body, "params").?;
    try handleDidClose(&svc, T.allocator, params);

    // File remains tracked (no-op semantics today).
    try T.expect(program.lookupPath("/main.ts") != null);
}

test "lineColToByte: walks lines + columns" {
    const src = "let x = 1;\nlet yy = 22;\nlet z = 3;";
    try T.expectEqual(@as(u32, 0), lineColToByte(src, 0, 0));
    try T.expectEqual(@as(u32, 4), lineColToByte(src, 0, 4));
    try T.expectEqual(@as(u32, 11), lineColToByte(src, 1, 0));
    try T.expectEqual(@as(u32, 15), lineColToByte(src, 1, 4));
    const past_eol = lineColToByte(src, 0, 999);
    try T.expectEqual(@as(u8, '\n'), src[past_eol]);
}

test "findJsonIntField: locates line + character" {
    const body =
        \\{"params":{"position":{"line":2,"character":7}}}
    ;
    try T.expectEqual(@as(i64, 2), findJsonIntField(body, "line").?);
    try T.expectEqual(@as(i64, 7), findJsonIntField(body, "character").?);
    try T.expect(findJsonIntField(body, "missing") == null);
}

test "handleHover: routes request and returns Hover response" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x: number = 1;");
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":4}}}
    ;
    const out = try handleHover(&svc, T.allocator, .{ .integer = 7 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":7") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"contents\":{\"kind\":\"markdown\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);

    const oob =
        \\{"jsonrpc":"2.0","id":8,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":99,"character":0}}}
    ;
    const out2 = try handleHover(&svc, T.allocator, .{ .integer = 8 }, oob);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"result\":null") != null);
}

test "encodePublishDiagnostics: empty rendered -> empty array" {
    const r = try encodePublishDiagnostics(T.allocator, "file:///x.ts", "");
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"diagnostics\":[]") != null);
}

test "handleCompletion: routes request and returns CompletionList response" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let foo = 1; function bar() {}");
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":11,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":0}}}
    ;
    const out = try handleCompletion(&svc, T.allocator, .{ .integer = 11 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":11") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"isIncomplete\":false") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"items\":[") != null);
    // At least one of the module-level symbols should appear with the
    // mapped LSP CompletionItemKind constant.
    const has_foo = std.mem.indexOf(u8, out, "\"label\":\"foo\",\"kind\":6") != null;
    const has_bar = std.mem.indexOf(u8, out, "\"label\":\"bar\",\"kind\":3") != null;
    try T.expect(has_foo or has_bar);
}

test "handleCompletion: unknown file returns empty CompletionList" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":12,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///missing.ts"},"position":{"line":0,"character":0}}}
    ;
    const out = try handleCompletion(&svc, T.allocator, .{ .integer = 12 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"items\":[]") != null);
}

test "handleSignatureHelp: routes request and returns SignatureHelp response" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        \\function add(a: number, b: number): number { return a + b; }
        \\let r = add(1, 2);
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Position cursor inside the call's argument list. The call site
    // `add(1, 2)` lives on line 1; column 12 lands between the args.
    const body =
        \\{"jsonrpc":"2.0","id":21,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":1,"character":12}}}
    ;
    const out = try handleSignatureHelp(&svc, T.allocator, .{ .integer = 21 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":21") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"signatures\":[{") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"label\":\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"parameters\":[") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"activeSignature\":0") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"activeParameter\":") != null);

    // Cursor outside any call expression -> result: null.
    const oob =
        \\{"jsonrpc":"2.0","id":22,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":0}}}
    ;
    const out2 = try handleSignatureHelp(&svc, T.allocator, .{ .integer = 22 }, oob);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"result\":null") != null);
}

test "handleDefinition: routes request and returns Location response" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Source: `let foo = 1;\nlet bar = foo;` — cursor on the `foo`
    // reference (line 1) should resolve back to the declaration on
    // line 0.
    const src =
        \\let foo = 1;
        \\let bar = foo;
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":31,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":1,"character":10}}}
    ;
    const out = try handleDefinition(&svc, T.allocator, .{ .integer = 31 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":31") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":{\"uri\":\"file:///main.ts\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);

    // Cursor on a non-identifier (the `=` sign) -> result: null.
    const oob =
        \\{"jsonrpc":"2.0","id":32,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":99,"character":0}}}
    ;
    const out2 = try handleDefinition(&svc, T.allocator, .{ .integer = 32 }, oob);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"result\":null") != null);
}

test "handleReferences: routes request and returns Location[] response" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Two reference sites for `foo`: the declaration and the use.
    const src =
        \\let foo = 1;
        \\let bar = foo;
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Cursor on the declaration `foo` (line 0, char 4).
    const body =
        \\{"jsonrpc":"2.0","id":41,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":4}}}
    ;
    const out = try handleReferences(&svc, T.allocator, .{ .integer = 41 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":41") != null);
    // Result is a JSON array of Locations.
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"uri\":\"file:///main.ts\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);

    // Cursor not on any identifier -> empty array.
    const empty =
        \\{"jsonrpc":"2.0","id":42,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":99,"character":0}}}
    ;
    const out2 = try handleReferences(&svc, T.allocator, .{ .integer = 42 }, empty);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"result\":[]") != null);
}

test "dispatchRequest: routes textDocument/hover request" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x: number = 1;");
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const frame =
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":4}}}
    ;
    const out = try dispatchRequest(&svc, T.allocator, frame);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":7") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"contents\":{\"kind\":\"markdown\"") != null);
}

test "dispatchRequest: unknown method returns -32601" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const frame =
        \\{"jsonrpc":"2.0","id":99,"method":"textDocument/madeUp","params":{}}
    ;
    const out = try dispatchRequest(&svc, T.allocator, frame);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":99") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"code\":-32601") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"message\":\"Method not found\"") != null);
}

test "dispatchRequest: notification (no id) returns empty bytes" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const frame =
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    ;
    const out = try dispatchRequest(&svc, T.allocator, frame);
    defer T.allocator.free(out);
    try T.expectEqual(@as(usize, 0), out.len);
}

test "handleRename: returns WorkspaceEdit with changes object" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let count = 1; let total = count + count;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":51,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":4},"newName":"n"}}
    ;
    const out = try handleRename(&svc, T.allocator, .{ .integer = 51 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":51") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"changes\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"file:///main.ts\":[") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"newText\":\"n\"") != null);
}

test "handlePrepareRename: returns range + placeholder for identifier" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let count = 1;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Cursor on `count` (line 0, char 6 — middle of the identifier).
    const body =
        \\{"jsonrpc":"2.0","id":151,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":6}}}
    ;
    const out = try handlePrepareRename(&svc, T.allocator, .{ .integer = 151 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":151") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"placeholder\":\"count\"") != null);
    // Identifier `count` lives at chars 4..9 on line 0.
    try T.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":0,\"character\":4}") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"end\":{\"line\":0,\"character\":9}") != null);

    // Cursor on a non-identifier glyph (`=`, surrounded by spaces) -> result: null.
    const empty =
        \\{"jsonrpc":"2.0","id":152,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":10}}}
    ;
    const out2 = try handlePrepareRename(&svc, T.allocator, .{ .integer = 152 }, empty);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"result\":null") != null);
}

test "handleCompletionItemResolve: echoes input item back" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();
    var svc = ts_lsp.Service.init(T.allocator, &program);

    // The CompletionItem is passed as the `params` value.
    const body =
        \\{"jsonrpc":"2.0","id":161,"method":"completionItem/resolve","params":{"label":"foo","kind":6,"data":{"auto_import_from":"./bar"}}}
    ;
    const params = findJsonRawField(body, "params").?;
    const out = try handleCompletionItemResolve(&svc, T.allocator, .{ .integer = 161 }, params);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":161") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"label\":\"foo\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":6") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"auto_import_from\":\"./bar\"") != null);
}

test "handleDocumentSymbol: returns DocumentSymbol array" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "function add(a: number, b: number) { return a + b; }\nlet x = 1;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":61,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///main.ts"}}}
    ;
    const out = try handleDocumentSymbol(&svc, T.allocator, .{ .integer = 61 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":61") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"name\":\"add\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"selectionRange\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":12") != null); // function
}

test "handleWorkspaceSymbol: returns WorkspaceSymbol array with location" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/a.ts", "function helper() { }");
    _ = try program.add("/b.ts", "class Helper { }");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":71,"method":"workspace/symbol","params":{"query":"elper"}}
    ;
    const out = try handleWorkspaceSymbol(&svc, T.allocator, .{ .integer = 71 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":71") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"location\":{\"uri\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"name\":\"helper\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"name\":\"Helper\"") != null);
}

test "handleCodeAction: returns CodeAction array with title/kind/edit" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x = 42;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":81,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///main.ts"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}}
    ;
    const out = try handleCodeAction(&svc, T.allocator, .{ .integer = 81 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":81") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"title\":\"Add explicit type to x\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":\"quickfix\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"edit\":{\"changes\":") != null);
}

test "handleSemanticTokensFull: returns object with data array" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x = 1; function foo() { }");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":91,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///main.ts"}}}
    ;
    const out = try handleSemanticTokensFull(&svc, T.allocator, .{ .integer = 91 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":91") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"data\":[") != null);
}

test "handleSemanticTokensRange: returns object with data array" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x = 1;\nlet y = 2;\nlet z = 3;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":101,"method":"textDocument/semanticTokens/range","params":{"textDocument":{"uri":"file:///main.ts"},"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}}}}
    ;
    const out = try handleSemanticTokensRange(&svc, T.allocator, .{ .integer = 101 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":101") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"data\":[") != null);
}

test "handleFoldingRange: returns FoldingRange array" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        \\import { a } from "x";
        \\import { b } from "y";
        \\function foo() {
        \\    let q = 1;
        \\}
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":111,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///main.ts"}}}
    ;
    const out = try handleFoldingRange(&svc, T.allocator, .{ .integer = 111 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":111") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"startLine\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"endLine\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":\"") != null);
}

test "handleInlayHint: returns InlayHint array with position+label+kind" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x = 42;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":121,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///main.ts"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}}}}
    ;
    const out = try handleInlayHint(&svc, T.allocator, .{ .integer = 121 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":121") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"position\":{") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"label\":\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":1") != null);
}

test "handleDocumentHighlight: returns DocumentHighlight array with range+kind" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let count = 1; let total = count + count;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":131,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":4}}}
    ;
    const out = try handleDocumentHighlight(&svc, T.allocator, .{ .integer = 131 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":131") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":") != null);
}

test "handleFormatting: returns TextEdit array (no-op)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x = 1;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":141,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///main.ts"},"options":{"tabSize":2,"insertSpaces":true}}}
    ;
    const out = try handleFormatting(&svc, T.allocator, .{ .integer = 141 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":141") != null);
    // Service stub returns [] (already-formatted).
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[]") != null);
}
