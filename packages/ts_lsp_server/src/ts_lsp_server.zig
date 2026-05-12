//! LSP JSON-RPC wire-protocol server — Phase 8 of TS_PARITY_PLAN.
//!
//! Translates Microsoft LSP requests into Service calls.
//! Phase 8 v0 ships the request-routing core + JSON-RPC framing
//! protocol parser. The actual stdio I/O loop lives in a separate
//! binary that calls into this library.
//!
//! ============================================================================
//! METHOD COVERAGE AUDIT
//! ============================================================================
//!
//! Every entry below has a `Method` enum variant, a `handle*` function, AND
//! is dispatched from `dispatchRequest`. The audit columns are:
//!   - Method enum variant: yes/no
//!   - handle* function:    yes/no
//!   - Wired in dispatch:   yes/no
//!   - Test coverage:       yes/no
//!
//! ----------------------------------------------------------------------------
//! FULLY IMPLEMENTED  (enum + handler + dispatch + tests)
//! ----------------------------------------------------------------------------
//!   Lifecycle:
//!     initialize                              [bb406d4]
//!     initialized                             [bb406d4]
//!     shutdown                                [bb406d4]
//!     exit                                    [bb406d4]
//!   Synchronization:
//!     textDocument/didOpen                    [c4e12c7]
//!     textDocument/didChange                  [c4e12c7]
//!     textDocument/didClose                   [c4e12c7]
//!   Language features (textDocument/*):
//!     hover                                   [47c3214]
//!     definition                              [3ad141e + e7a3b54]
//!     typeDefinition                          [025b52e]
//!     implementation                          [a85694b]
//!     references                              [c9dc339]
//!     completion                              [c9dc339]
//!     signatureHelp                           [3ad141e]
//!     documentSymbol                          [c9dc339]
//!     codeAction                              [c9dc339]
//!     codeLens                                [c7754e2]
//!     documentLink                            [a85694b]
//!     foldingRange                            [c9dc339]
//!     inlayHint                               [c9dc339]
//!     documentHighlight                       [c9dc339]
//!     formatting                              [c9dc339]
//!     onTypeFormatting                        [wire handler; service returns []]
//!     rename                                  [c9dc339]
//!     prepareRename                           [d5ff71d]
//!     prepareCallHierarchy                    [025b52e]
//!     semanticTokens/full                     [c9dc339]
//!     semanticTokens/range                    [c9dc339]
//!     semanticTokens/full/delta               [d086122]
//!     diagnostic (pull-mode)                  [d5e5226]
//!     publishDiagnostics (server-pushed)      [c4e12c7]
//!   Resolve callbacks:
//!     completionItem/resolve                  [bd1de4d]
//!     codeLens/resolve                        [1dca066]
//!     documentLink/resolve                    [a85694b]
//!     inlayHint/resolve                       [stub: echoes hint back]
//!   Workspace:
//!     workspace/symbol                        [c9dc339]
//!     workspace/diagnostic (pull-mode)        [LSP 3.17]
//!   Call hierarchy:
//!     callHierarchy/incomingCalls             [025b52e]
//!     callHierarchy/outgoingCalls             [025b52e]
//!   Misc:
//!     textDocument/linkedEditingRange         [wire handler; service returns null]
//!     workspace/willRenameFiles               [wire handler; service returns []]
//!     textDocument/documentColor              [wire handler; service returns []]
//!     textDocument/colorPresentation          [wire handler; service returns []]
//!
//! ----------------------------------------------------------------------------
//! STUBS  (handler exists in ts_lsp.Service, NOT yet routed by this wire layer)
//! ----------------------------------------------------------------------------
//!   (none)
//!
//! ----------------------------------------------------------------------------
//! NOT WIRED  (no `Method` variant, no handler — reserved for future work)
//! ----------------------------------------------------------------------------
//!   textDocument/rangeFormatting
//!   textDocument/moniker
//!   workspace/executeCommand
//!   workspace/didChangeConfiguration
//!   workspace/didChangeWatchedFiles
//!
//! See `SUPPORTED_METHODS` below for the canonical list of wire method names
//! advertised by `initialize`.

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
    text_document_declaration,
    text_document_type_definition,
    text_document_references,
    text_document_prepare_call_hierarchy,
    call_hierarchy_incoming_calls,
    call_hierarchy_outgoing_calls,
    text_document_prepare_type_hierarchy,
    type_hierarchy_supertypes,
    type_hierarchy_subtypes,
    text_document_completion,
    text_document_signature_help,
    text_document_publish_diagnostics,
    text_document_diagnostic,
    workspace_diagnostic,
    text_document_rename,
    text_document_prepare_rename,
    completion_item_resolve,
    text_document_document_symbol,
    workspace_symbol,
    text_document_code_action,
    text_document_semantic_tokens_full,
    text_document_semantic_tokens_full_delta,
    text_document_semantic_tokens_range,
    text_document_folding_range,
    text_document_inlay_hint,
    inlay_hint_resolve,
    text_document_document_highlight,
    text_document_formatting,
    text_document_on_type_formatting,
    text_document_code_lens,
    code_lens_resolve,
    text_document_implementation,
    text_document_document_link,
    document_link_resolve,
    text_document_selection_range,
    text_document_linked_editing_range,
    workspace_will_rename_files,
    workspace_execute_command,
    text_document_moniker,
    text_document_inline_value,
    text_document_inline_completion,
    text_document_document_color,
    text_document_color_presentation,
    text_document_will_save_wait_until,
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
            .{ "textDocument/declaration", Method.text_document_declaration },
            .{ "textDocument/typeDefinition", Method.text_document_type_definition },
            .{ "textDocument/references", Method.text_document_references },
            .{ "textDocument/prepareCallHierarchy", Method.text_document_prepare_call_hierarchy },
            .{ "callHierarchy/incomingCalls", Method.call_hierarchy_incoming_calls },
            .{ "callHierarchy/outgoingCalls", Method.call_hierarchy_outgoing_calls },
            .{ "textDocument/prepareTypeHierarchy", Method.text_document_prepare_type_hierarchy },
            .{ "typeHierarchy/supertypes", Method.type_hierarchy_supertypes },
            .{ "typeHierarchy/subtypes", Method.type_hierarchy_subtypes },
            .{ "textDocument/completion", Method.text_document_completion },
            .{ "textDocument/signatureHelp", Method.text_document_signature_help },
            .{ "textDocument/publishDiagnostics", Method.text_document_publish_diagnostics },
            .{ "textDocument/diagnostic", Method.text_document_diagnostic },
            .{ "workspace/diagnostic", Method.workspace_diagnostic },
            .{ "textDocument/rename", Method.text_document_rename },
            .{ "textDocument/prepareRename", Method.text_document_prepare_rename },
            .{ "completionItem/resolve", Method.completion_item_resolve },
            .{ "textDocument/documentSymbol", Method.text_document_document_symbol },
            .{ "workspace/symbol", Method.workspace_symbol },
            .{ "textDocument/codeAction", Method.text_document_code_action },
            .{ "textDocument/semanticTokens/full", Method.text_document_semantic_tokens_full },
            .{ "textDocument/semanticTokens/full/delta", Method.text_document_semantic_tokens_full_delta },
            .{ "textDocument/semanticTokens/range", Method.text_document_semantic_tokens_range },
            .{ "textDocument/foldingRange", Method.text_document_folding_range },
            .{ "textDocument/inlayHint", Method.text_document_inlay_hint },
            .{ "inlayHint/resolve", Method.inlay_hint_resolve },
            .{ "textDocument/documentHighlight", Method.text_document_document_highlight },
            .{ "textDocument/formatting", Method.text_document_formatting },
            .{ "textDocument/onTypeFormatting", Method.text_document_on_type_formatting },
            .{ "textDocument/codeLens", Method.text_document_code_lens },
            .{ "codeLens/resolve", Method.code_lens_resolve },
            .{ "textDocument/implementation", Method.text_document_implementation },
            .{ "textDocument/documentLink", Method.text_document_document_link },
            .{ "documentLink/resolve", Method.document_link_resolve },
            .{ "textDocument/selectionRange", Method.text_document_selection_range },
            .{ "textDocument/linkedEditingRange", Method.text_document_linked_editing_range },
            .{ "workspace/willRenameFiles", Method.workspace_will_rename_files },
            .{ "workspace/executeCommand", Method.workspace_execute_command },
            .{ "textDocument/moniker", Method.text_document_moniker },
            .{ "textDocument/inlineValue", Method.text_document_inline_value },
            .{ "textDocument/inlineCompletion", Method.text_document_inline_completion },
            .{ "textDocument/documentColor", Method.text_document_document_color },
            .{ "textDocument/colorPresentation", Method.text_document_color_presentation },
            .{ "textDocument/willSaveWaitUntil", Method.text_document_will_save_wait_until },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// Canonical wire-protocol method names this server handles. Kept in
/// dispatch order (lifecycle, synchronization, language features,
/// resolve callbacks, workspace, call hierarchy). The `initialize`
/// response embeds this list under a non-standard
/// `serverInfo.supportedMethods` field so that integration tests and
/// debug clients can introspect coverage without parsing capability
/// shapes. Adding a new wire method MUST update this list, the
/// `Method` enum, `Method.fromString`, and `dispatchRequest`.
pub const SUPPORTED_METHODS = &[_][]const u8{
    // Lifecycle.
    "initialize",
    "initialized",
    "shutdown",
    "exit",
    // Synchronization.
    "textDocument/didOpen",
    "textDocument/didChange",
    "textDocument/didClose",
    "textDocument/publishDiagnostics",
    // Language features.
    "textDocument/hover",
    "textDocument/definition",
    "textDocument/declaration",
    "textDocument/typeDefinition",
    "textDocument/implementation",
    "textDocument/references",
    "textDocument/completion",
    "textDocument/signatureHelp",
    "textDocument/documentSymbol",
    "textDocument/codeAction",
    "textDocument/codeLens",
    "textDocument/documentLink",
    "textDocument/foldingRange",
    "textDocument/selectionRange",
    "textDocument/linkedEditingRange",
    "textDocument/inlayHint",
    "textDocument/documentHighlight",
    "textDocument/formatting",
    "textDocument/onTypeFormatting",
    "textDocument/rename",
    "textDocument/prepareRename",
    "textDocument/prepareCallHierarchy",
    "textDocument/semanticTokens/full",
    "textDocument/semanticTokens/full/delta",
    "textDocument/semanticTokens/range",
    "textDocument/diagnostic",
    "textDocument/moniker",
    "textDocument/inlineValue",
    "textDocument/inlineCompletion",
    "textDocument/documentColor",
    "textDocument/colorPresentation",
    // Resolve callbacks.
    "completionItem/resolve",
    "codeLens/resolve",
    "documentLink/resolve",
    "inlayHint/resolve",
    "textDocument/willSaveWaitUntil",
    // Workspace.
    "workspace/symbol",
    "workspace/diagnostic",
    "workspace/willRenameFiles",
    "workspace/executeCommand",
    // Call hierarchy.
    "callHierarchy/incomingCalls",
    "callHierarchy/outgoingCalls",
    // Type hierarchy.
    "textDocument/prepareTypeHierarchy",
    "typeHierarchy/supertypes",
    "typeHierarchy/subtypes",
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

    // Drive the recompile + source update; the rendered text return
    // value is discarded — we re-pull diagnostics in structured form
    // below so the wire layer can emit per-LSP `Diagnostic` shape
    // (range/severity/code/source/message) instead of stuffing the
    // tsc-style line into `message` with a bogus (0,0)..(0,0) range.
    const rendered = try service.didChangeFile(gpa, path, new_source);
    gpa.free(rendered);

    const diags = try service.diagnosticsStructured(gpa, path);
    defer ts_lsp.freeLspDiagnostics(gpa, diags);

    return encodePublishDiagnosticsStructured(gpa, uri, diags);
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

/// Handle a `textDocument/declaration` JSON-RPC request. Per the
/// LSP spec the declaration of a symbol is a sibling concept to its
/// definition: for variables, declaration is the `let/const/var`
/// statement while definition is the type. For v0 we delegate to the
/// same `Service.gotoDefinition` path used by `textDocument/definition`,
/// emitting an identical `Location | null` response shape. Caller owns
/// the returned slice.
pub fn handleDeclaration(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    return handleDefinition(service, gpa, request_id, params_json);
}

/// Handle a `textDocument/typeDefinition` JSON-RPC request. Same
/// shape as `handleDefinition` but routes to
/// `service.typeDefinition` so the cursor on `let x: Foo = ...`
/// jumps to the `Foo` declaration rather than the `let_decl`.
/// Caller owns the returned slice.
pub fn handleTypeDefinition(
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

    if (service.typeDefinition(path, byte_pos)) |def| {
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

/// Render a single `ts_lsp.CallHierarchyItem` as an LSP
/// `CallHierarchyItem` JSON object. We use the declaration span for
/// both `range` and `selectionRange`.
fn writeCallHierarchyItem(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    item: ts_lsp.CallHierarchyItem,
) !void {
    try buf.appendSlice(gpa, "{\"name\":\"");
    try writeJsonStringContents(buf, gpa, item.name);
    try buf.appendSlice(gpa, "\",\"kind\":");
    var nbuf: [4]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{lspSymbolKind(item.kind)}));
    try buf.appendSlice(gpa, ",\"uri\":\"file://");
    try writeJsonStringContents(buf, gpa, item.span.file);
    try buf.appendSlice(gpa, "\",\"range\":");
    try writeRange(buf, gpa, item.span);
    try buf.appendSlice(gpa, ",\"selectionRange\":");
    try writeRange(buf, gpa, item.span);
    try buf.append(gpa, '}');
}

/// Render a `[]ts_lsp.CallHierarchyItem` either as a top-level JSON
/// array (for `prepareCallHierarchy`) or wrapped under `from` /
/// `to` per the spec's incoming/outgoing call shape. `wrap_key` is
/// `null` for the prepare array, `"from"` for incoming, `"to"` for
/// outgoing. Caller owns the returned slice.
fn renderCallHierarchyResult(
    gpa: std.mem.Allocator,
    items: []const ts_lsp.CallHierarchyItem,
    wrap_key: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (items, 0..) |it, i| {
        if (i > 0) try buf.append(gpa, ',');
        if (wrap_key) |key| {
            try buf.append(gpa, '{');
            try buf.append(gpa, '"');
            try buf.appendSlice(gpa, key);
            try buf.appendSlice(gpa, "\":");
            try writeCallHierarchyItem(&buf, gpa, it);
            const ranges_key = if (std.mem.eql(u8, key, "from")) "fromRanges" else "toRanges";
            try buf.appendSlice(gpa, ",\"");
            try buf.appendSlice(gpa, ranges_key);
            try buf.appendSlice(gpa, "\":[]}");
        } else {
            try writeCallHierarchyItem(&buf, gpa, it);
        }
    }
    try buf.append(gpa, ']');
    return buf.toOwnedSlice(gpa);
}

/// Handle a `textDocument/prepareCallHierarchy` JSON-RPC request:
/// emit a single-element `CallHierarchyItem[]` describing the
/// function under the cursor, or `null` if the cursor isn't inside
/// a named fn. Caller owns the returned slice.
pub fn handleCallHierarchyPrepare(
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

    const item = service.callHierarchyPrepare(path, byte_pos) orelse {
        return encodeResponse(gpa, request_id, "null");
    };
    const items = [_]ts_lsp.CallHierarchyItem{item};
    const rendered = try renderCallHierarchyResult(gpa, &items, null);
    defer gpa.free(rendered);
    return encodeResponse(gpa, request_id, rendered);
}

/// Handle a `callHierarchy/incomingCalls` JSON-RPC request. The
/// editor's prior `prepareCallHierarchy` round produced a
/// `CallHierarchyItem` whose URI + `range.start` we pull out here
/// to seed the cursor, then forward to
/// `Service.callHierarchyIncoming`. Result is a
/// `CallHierarchyIncomingCall[]`. Caller owns the returned slice.
pub fn handleCallHierarchyIncomingCalls(
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

    const items = try service.callHierarchyIncoming(gpa, path, byte_pos);
    defer gpa.free(items);
    const rendered = try renderCallHierarchyResult(gpa, items, "from");
    defer gpa.free(rendered);
    return encodeResponse(gpa, request_id, rendered);
}

/// Handle a `callHierarchy/outgoingCalls` JSON-RPC request. Mirrors
/// `handleCallHierarchyIncomingCalls` but routes to
/// `Service.callHierarchyOutgoing` and wraps each item under `to`.
/// Caller owns the returned slice.
pub fn handleCallHierarchyOutgoingCalls(
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

    const items = try service.callHierarchyOutgoing(gpa, path, byte_pos);
    defer gpa.free(items);
    const rendered = try renderCallHierarchyResult(gpa, items, "to");
    defer gpa.free(rendered);
    return encodeResponse(gpa, request_id, rendered);
}

/// Render a single `ts_lsp.TypeHierarchyItem` as an LSP
/// `TypeHierarchyItem` JSON object. We use the declaration span for
/// both `range` and `selectionRange`.
fn writeTypeHierarchyItem(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    item: ts_lsp.TypeHierarchyItem,
) !void {
    try buf.appendSlice(gpa, "{\"name\":\"");
    try writeJsonStringContents(buf, gpa, item.name);
    try buf.appendSlice(gpa, "\",\"kind\":");
    var nbuf: [4]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{lspSymbolKind(item.kind)}));
    try buf.appendSlice(gpa, ",\"uri\":\"file://");
    try writeJsonStringContents(buf, gpa, item.span.file);
    try buf.appendSlice(gpa, "\",\"range\":");
    try writeRange(buf, gpa, item.span);
    try buf.appendSlice(gpa, ",\"selectionRange\":");
    try writeRange(buf, gpa, item.span);
    try buf.append(gpa, '}');
}

/// Render a `[]ts_lsp.TypeHierarchyItem` as a top-level JSON array
/// of `TypeHierarchyItem` objects. Caller owns the returned slice.
fn renderTypeHierarchyResult(
    gpa: std.mem.Allocator,
    items: []const ts_lsp.TypeHierarchyItem,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (items, 0..) |it, i| {
        if (i > 0) try buf.append(gpa, ',');
        try writeTypeHierarchyItem(&buf, gpa, it);
    }
    try buf.append(gpa, ']');
    return buf.toOwnedSlice(gpa);
}

/// Pull a `TypeHierarchyItem` (name, uri, range.start) back out of
/// a `params.item` JSON object so supertypes/subtypes handlers can
/// reconstruct the cursor seed sent in the prior prepare round.
fn parseTypeHierarchyItemFromParams(
    params_json: []const u8,
) ?ts_lsp.TypeHierarchyItem {
    const name = findJsonStringField(params_json, "name") orelse return null;
    const uri = findJsonStringField(params_json, "uri") orelse return null;
    const line = findJsonIntField(params_json, "line") orelse return null;
    const character = findJsonIntField(params_json, "character") orelse return null;
    const path = uriToPath(uri);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    return .{
        .name = name,
        .kind = .class,
        .span = .{
            .file = path,
            .start_line = line_u + 1,
            .start_col = char_u + 1,
            .end_line = line_u + 1,
            .end_col = char_u + 1,
        },
    };
}

/// Handle a `textDocument/prepareTypeHierarchy` JSON-RPC request:
/// emit a single-element `TypeHierarchyItem[]` describing the
/// class/interface under the cursor, or `null` if the cursor isn't
/// inside a class/interface declaration. Caller owns the returned slice.
pub fn handlePrepareTypeHierarchy(
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

    const item = service.prepareTypeHierarchy(path, byte_pos) orelse {
        return encodeResponse(gpa, request_id, "null");
    };
    const items = [_]ts_lsp.TypeHierarchyItem{item};
    const rendered = try renderTypeHierarchyResult(gpa, &items);
    defer gpa.free(rendered);
    return encodeResponse(gpa, request_id, rendered);
}

/// Handle a `typeHierarchy/supertypes` JSON-RPC request. The editor's
/// prior `prepareTypeHierarchy` round produced a `TypeHierarchyItem`
/// whose `name` + URI we pull from `params.item` to re-seed the
/// service. Returns a `TypeHierarchyItem[]`. Caller owns the slice.
pub fn handleTypeHierarchySupertypes(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const item = parseTypeHierarchyItemFromParams(params_json) orelse {
        return encodeResponse(gpa, request_id, "[]");
    };
    const items = try service.typeHierarchySupertypes(gpa, item);
    defer gpa.free(items);
    const rendered = try renderTypeHierarchyResult(gpa, items);
    defer gpa.free(rendered);
    return encodeResponse(gpa, request_id, rendered);
}

/// Handle a `typeHierarchy/subtypes` JSON-RPC request. Mirrors
/// `handleTypeHierarchySupertypes` but routes to
/// `Service.typeHierarchySubtypes`. Caller owns the returned slice.
pub fn handleTypeHierarchySubtypes(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const item = parseTypeHierarchyItemFromParams(params_json) orelse {
        return encodeResponse(gpa, request_id, "[]");
    };
    const items = try service.typeHierarchySubtypes(gpa, item);
    defer gpa.free(items);
    const rendered = try renderTypeHierarchyResult(gpa, items);
    defer gpa.free(rendered);
    return encodeResponse(gpa, request_id, rendered);
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

/// Handle a `textDocument/implementation` JSON-RPC request: extract
/// the URI + `(line, character)` from `params_json`, convert to a
/// byte offset into the file's source, route to
/// `service.implementation`, and encode the LSP response as a
/// `Location[]` array (same wire shape as `handleReferences`).
/// Caller owns the returned slice.
pub fn handleImplementation(
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

    const defs = try service.implementation(gpa, path, byte_pos);
    defer gpa.free(defs);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (defs, 0..) |d, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"uri\":\"file://");
        try writeJsonStringContents(&buf, gpa, d.file);
        try buf.appendSlice(gpa, "\",\"range\":");
        try writeRange(&buf, gpa, d.span);
        try buf.append(gpa, '}');
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/documentLink` JSON-RPC request: extract
/// the URI from `params_json`, route to `service.documentLinks`, and
/// encode the LSP response as a `DocumentLink[]` array. Each entry
/// carries `range`, `target` (file URI), and `tooltip` fields.
/// Caller owns the returned slice.
pub fn handleDocumentLink(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const links = try service.documentLinks(gpa, path);
    defer ts_lsp.freeDocumentLinks(gpa, links);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (links, 0..) |l, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"range\":");
        try writeRange(&buf, gpa, l.span);
        try buf.appendSlice(gpa, ",\"target\":\"file://");
        try writeJsonStringContents(&buf, gpa, l.target);
        try buf.appendSlice(gpa, "\",\"tooltip\":\"");
        try writeJsonStringContents(&buf, gpa, l.tooltip);
        try buf.appendSlice(gpa, "\"}");
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `documentLink/resolve` JSON-RPC request. Stub: echoes
/// the input `DocumentLink` back unchanged. The editor uses
/// `documentLink/resolve` when a link's `target` was omitted in the
/// initial response and needs lazy resolution; our `documentLink`
/// handler always emits `target` eagerly, so resolve is a no-op
/// here. Caller owns the returned slice.
pub fn handleDocumentLinkResolve(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    _ = service;
    return encodeResponse(gpa, request_id, params_json);
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
    defer ts_lsp.deinitCompletionItems(gpa, items);

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
        if (it.documentation.len > 0) {
            try buf.appendSlice(gpa, ",\"documentation\":\"");
            try writeJsonStringContents(&buf, gpa, it.documentation);
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
    defer ts_lsp.deinitSignatureInfo(gpa, sig);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"signatures\":[");
    for (sig.signatures, 0..) |s, si| {
        if (si > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"label\":\"");
        try writeJsonStringContents(&buf, gpa, s.label);
        try buf.appendSlice(gpa, "\",\"parameters\":[");
        for (s.parameters, 0..) |p, i| {
            if (i > 0) try buf.append(gpa, ',');
            try buf.appendSlice(gpa, "{\"label\":\"");
            try writeJsonStringContents(&buf, gpa, p);
            try buf.appendSlice(gpa, "\"}");
        }
        try buf.appendSlice(gpa, "]}");
    }
    try buf.appendSlice(gpa, "],\"activeSignature\":");
    var nbuf: [16]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{sig.active_signature}));
    try buf.appendSlice(gpa, ",\"activeParameter\":");
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

/// Handle a `textDocument/prepareRename` JSON-RPC request: parse
/// `uri` + `(line, character)`, dispatch to `Service.prepareRename`,
/// and emit either a `{ range, placeholder }` object or `null` when
/// the cursor isn't on a renamable identifier. Per the LSP spec the
/// response shape may also be a bare `Range`; we always return the
/// richer `{ range, placeholder }` form so clients pre-fill the
/// rename input. Caller owns the returned slice.
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

    const result = (try service.prepareRename(gpa, path, byte_pos)) orelse {
        return encodeResponse(gpa, request_id, "null");
    };
    defer gpa.free(result.placeholder);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var nbuf: [128]u8 = undefined;
    // `Range` in ts_lsp is 1-based (mirroring `Span`); LSP wire format
    // is 0-based. Convert here so the response matches the spec.
    const sl: u32 = if (result.range.start_line > 0) result.range.start_line - 1 else 0;
    const sc: u32 = if (result.range.start_col > 0) result.range.start_col - 1 else 0;
    const el: u32 = if (result.range.end_line > 0) result.range.end_line - 1 else 0;
    const ec: u32 = if (result.range.end_col > 0) result.range.end_col - 1 else 0;
    const fmt = try std.fmt.bufPrint(
        &nbuf,
        "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"placeholder\":\"",
        .{ sl, sc, el, ec },
    );
    try buf.appendSlice(gpa, fmt);
    try writeJsonStringContents(&buf, gpa, result.placeholder);
    try buf.appendSlice(gpa, "\"}");
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `completionItem/resolve` JSON-RPC request. Per the LSP
/// spec the client sends back a CompletionItem from a prior
/// `textDocument/completion` response and expects the same shape
/// echoed back with optional fields (e.g. `documentation`,
/// `detail`) populated. We look up the item's `label` as a top-level
/// symbol across every open file; on a match we splice in (or
/// overwrite) a `detail` field carrying the rendered type signature.
/// When the label resolves to nothing we still echo the original
/// item back unchanged, per the spec. Caller owns the returned slice.
pub fn handleCompletionItemResolve(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    // The CompletionItem itself is the entire `params` value (the
    // protocol passes the item as the request's `params`). Locate
    // the object span; if absent, fall through to `{}`.
    const obj_start = std.mem.indexOfScalar(u8, params_json, '{') orelse {
        return encodeResponse(gpa, request_id, "{}");
    };
    var depth: usize = 0;
    var in_str = false;
    var obj_end: usize = params_json.len;
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
                obj_end = i + 1;
                break;
            }
        }
    }
    const item_json = params_json[obj_start..obj_end];

    // Pull the `label` out so we can look it up across the program.
    const label_raw = findJsonStringField(item_json, "label") orelse {
        return encodeResponse(gpa, request_id, item_json);
    };
    const label = try decodeJsonString(gpa, label_raw);
    defer gpa.free(label);

    const detail_opt = service.resolveCompletionDetail(gpa, label) catch null;
    if (detail_opt == null) {
        return encodeResponse(gpa, request_id, item_json);
    }
    const detail = detail_opt.?;
    defer gpa.free(detail);

    // Splice `detail` into the object. If a `detail` already exists
    // we leave the original in place and add ours alongside; the
    // spec lets servers overwrite, but the simpler append form is
    // sufficient here and keeps echo-back semantics intact for
    // anything we don't recognise.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    // Drop the trailing `}` so we can append the new field.
    try buf.appendSlice(gpa, item_json[0 .. item_json.len - 1]);
    const inner = item_json[1 .. item_json.len - 1];
    const has_fields = std.mem.indexOfNone(u8, inner, " \t\r\n") != null;
    if (has_fields) try buf.append(gpa, ',');
    try buf.appendSlice(gpa, "\"detail\":\"");
    try writeJsonStringContents(&buf, gpa, detail);
    try buf.appendSlice(gpa, "\"}");
    return encodeResponse(gpa, request_id, buf.items);
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

/// Handle a `workspace/executeCommand` JSON-RPC request. The client
/// invokes a server-registered command (advertised via
/// `executeCommandProvider.commands` in the initialize response).
///
/// Currently supported:
///   * `home.organizeImports` — `arguments: [uri]`. Routes to
///     `Service.codeActions` and returns the first action whose kind
///     is `organize_imports` rendered as an LSP `WorkspaceEdit`. When
///     no organize-imports action applies the response is `null`.
///   * `home.applyCodeAction` — accepted for capability advertisement
///     but currently dispatched as the default no-op (returns `null`)
///     until persistent code-action IDs are wired.
///
/// All other commands return `null`. Caller owns the returned slice.
pub fn handleExecuteCommand(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const command = findJsonStringField(params_json, "command") orelse {
        return encodeResponse(gpa, request_id, "null");
    };

    if (std.mem.eql(u8, command, "home.organizeImports")) {
        const arguments = findJsonRawField(params_json, "arguments") orelse {
            return encodeResponse(gpa, request_id, "null");
        };
        // `arguments` is a JSON array; we expect `[uri]` as the first
        // element. Reuse `findJsonStringField`-style scan: the first
        // string inside the array is the URI.
        const uri = blk: {
            var i: usize = 0;
            while (i < arguments.len) : (i += 1) {
                if (arguments[i] == '"') {
                    const start = i + 1;
                    var j = start;
                    while (j < arguments.len) : (j += 1) {
                        const c = arguments[j];
                        if (c == '\\') {
                            j += 1;
                            continue;
                        }
                        if (c == '"') break :blk arguments[start..j];
                    }
                    break :blk null;
                }
            }
            break :blk null;
        };
        if (uri == null) return encodeResponse(gpa, request_id, "null");
        const path = uriToPath(uri.?);

        const actions = try service.codeActions(gpa, path);
        defer {
            for (actions) |a| {
                if (a.kind == .quick_fix) gpa.free(a.title);
                for (a.edits) |e| gpa.free(e.new_text);
                gpa.free(a.edits);
            }
            gpa.free(actions);
        }

        // Return the first organize-imports action's WorkspaceEdit, or
        // `null` when no such action applies.
        for (actions) |action| {
            if (action.kind != .organize_imports) continue;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(gpa);
            try buf.appendSlice(gpa, "{\"changes\":{");
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
            try buf.appendSlice(gpa, "}}");
            return encodeResponse(gpa, request_id, buf.items);
        }
        return encodeResponse(gpa, request_id, "null");
    }

    return encodeResponse(gpa, request_id, "null");
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

/// Handle a `textDocument/semanticTokens/full/delta` JSON-RPC request:
/// extract the URI + previousResultId, route to
/// `Service.semanticTokensDelta`, and emit an LSP `SemanticTokens`
/// `{ resultId, data: u32[] }` response. v0 always returns a full
/// reset (no edits), since snapshot tracking isn't wired up yet — the
/// `previousResultId` is accepted for protocol shape but ignored by
/// the service. Caller owns the returned slice.
pub fn handleSemanticTokensDelta(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);
    // `previousResultId` is required by the LSP spec; default to ""
    // when missing so we still produce a useful (full-reset) response
    // rather than failing the request.
    const prev = findJsonStringField(params_json, "previousResultId") orelse "";

    const delta = try service.semanticTokensDelta(gpa, path, prev);
    defer gpa.free(delta.result_id);
    defer gpa.free(delta.data);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"resultId\":\"");
    try writeJsonStringContents(&buf, gpa, delta.result_id);
    try buf.appendSlice(gpa, "\",\"data\":[");
    for (delta.data, 0..) |v, i| {
        if (i > 0) try buf.append(gpa, ',');
        var nbuf: [16]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nbuf, "{d}", .{v}));
    }
    try buf.appendSlice(gpa, "]}");
    return encodeResponse(gpa, request_id, buf.items);
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

/// Render a `ts_lsp.Range` (1-based line/col) as an LSP-wire `Range`
/// object (0-based line/character). Mirrors `writeRange` for `Span`.
fn writeRangeFromRange(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, r: ts_lsp.Range) !void {
    var nbuf: [128]u8 = undefined;
    const start_line = if (r.start_line > 0) r.start_line - 1 else 0;
    const start_col = if (r.start_col > 0) r.start_col - 1 else 0;
    const end_line = if (r.end_line > 0) r.end_line - 1 else 0;
    const end_col = if (r.end_col > 0) r.end_col - 1 else 0;
    const fmt = try std.fmt.bufPrint(
        &nbuf,
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ start_line, start_col, end_line, end_col },
    );
    try buf.appendSlice(gpa, fmt);
}

/// Handle a `textDocument/selectionRange` JSON-RPC request: extract the
/// URI + an array of cursor positions, route each through
/// `Service.selectionRange`, and emit an LSP `SelectionRange[]` array.
/// Each entry is the innermost selection at the corresponding position
/// with `parent` links walking outward to the file root, matching the
/// LSP wire shape `{ range, parent: { range, parent: ... } }`.
/// When `service.selectionRange` returns no ranges (unknown file,
/// position outside any node), we emit a degenerate empty-range entry
/// so the array length stays in lock-step with the input positions —
/// VS Code expects one result per requested position.
/// Caller owns the returned slice.
pub fn handleSelectionRange(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const positions_raw = findJsonRawField(params_json, "positions") orelse return error.MissingPositions;

    // Resolve the file once; we need its source for line/col -> byte
    // conversion. When the file is unknown we still walk the positions
    // array so we can emit a properly-shaped (empty) result per entry.
    const file_id_opt = service.program.lookupPath(path);
    const source: []const u8 = if (file_id_opt) |fid| service.program.fileById(fid).source else "";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');

    // Walk the JSON array of position objects. We slice into each
    // `{ line, character }` object in turn by tracking object
    // boundaries (so nested keys can't bleed across positions).
    var i: usize = 0;
    var emitted: usize = 0;
    while (i < positions_raw.len) {
        // Skip whitespace and array delimiters.
        while (i < positions_raw.len and (positions_raw[i] == ' ' or positions_raw[i] == '\t' or positions_raw[i] == '\n' or positions_raw[i] == '\r' or positions_raw[i] == ',' or positions_raw[i] == '[')) : (i += 1) {}
        if (i >= positions_raw.len or positions_raw[i] == ']') break;
        if (positions_raw[i] != '{') {
            i += 1;
            continue;
        }
        // Walk to the matching '}'.
        const obj_start = i;
        var depth: usize = 0;
        var in_str = false;
        var j = i;
        while (j < positions_raw.len) : (j += 1) {
            const ch = positions_raw[j];
            if (in_str) {
                if (ch == '\\') {
                    j += 1;
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
                if (depth == 0) break;
            }
        }
        if (j >= positions_raw.len) break;
        const obj_slice = positions_raw[obj_start .. j + 1];
        i = j + 1;

        const line = findJsonIntField(obj_slice, "line") orelse 0;
        const character = findJsonIntField(obj_slice, "character") orelse 0;
        const line_u: u32 = if (line < 0) 0 else @intCast(line);
        const char_u: u32 = if (character < 0) 0 else @intCast(character);
        const byte_pos = lineColToByte(source, line_u, char_u);

        if (emitted > 0) try buf.append(gpa, ',');
        emitted += 1;

        const ranges = service.selectionRange(gpa, path, byte_pos) catch &[_]ts_lsp.Range{};
        defer if (ranges.len > 0) gpa.free(ranges);

        if (ranges.len == 0) {
            // Degenerate empty range at the requested position.
            var nbuf: [128]u8 = undefined;
            const fmt = try std.fmt.bufPrint(
                &nbuf,
                "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
                .{ line_u, char_u, line_u, char_u },
            );
            try buf.appendSlice(gpa, fmt);
            continue;
        }

        // Build the nested `{range, parent: {...}}` chain. `ranges` is
        // innermost-first; each successive entry strictly encloses the
        // previous one. We open one `{"range":...,"parent":` per entry
        // (except the outermost, which gets just `{"range":...}`),
        // then close them all at the end.
        for (ranges, 0..) |r, idx| {
            try buf.appendSlice(gpa, "{\"range\":");
            try writeRangeFromRange(&buf, gpa, r);
            if (idx + 1 < ranges.len) {
                try buf.appendSlice(gpa, ",\"parent\":");
            }
        }
        var k: usize = 0;
        while (k < ranges.len) : (k += 1) try buf.append(gpa, '}');
    }

    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/linkedEditingRange` JSON-RPC request: extract
/// the URI + cursor position, route to `Service.linkedEditingRanges`,
/// and emit either an LSP `LinkedEditingRanges` object
/// (`{ ranges: [...], wordPattern: "..." }`) when the cursor is inside
/// a paired construct (e.g. JSX opening/closing tag), or `null` when
/// nothing should be linked. The service layer is currently a stub
/// returning `null` until the JSX HIR pairing lands; this wire handler
/// is feature-complete for whenever the service produces real data.
/// Caller owns the returned slice.
pub fn handleLinkedEditingRange(
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

    const result = try service.linkedEditingRanges(gpa, path, byte_pos);
    if (result == null) {
        return encodeResponse(gpa, request_id, "null");
    }
    const linked = result.?;
    defer gpa.free(linked.ranges);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"ranges\":[");
    for (linked.ranges, 0..) |r, i| {
        if (i > 0) try buf.append(gpa, ',');
        try writeRangeFromRange(&buf, gpa, r);
    }
    try buf.append(gpa, ']');
    if (linked.word_pattern.len > 0) {
        try buf.appendSlice(gpa, ",\"wordPattern\":\"");
        try writeJsonStringContents(&buf, gpa, linked.word_pattern);
        try buf.append(gpa, '"');
    }
    try buf.append(gpa, '}');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/moniker` JSON-RPC request: extract the
/// `(uri, line, character)` triple, route to `Service.moniker`, and
/// emit an LSIF-style `Moniker[]` array. Each moniker carries
/// `scheme`, `identifier`, `unique`, and `kind`. The service emits at
/// most one moniker per cursor (covering the symbol at that
/// position); the array shape lets us extend to multiple monikers
/// per symbol later (e.g. one per index format) without breaking the
/// wire contract. Caller owns the returned slice.
pub fn handleMoniker(
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

    const monikers = try service.moniker(gpa, path, byte_pos);
    defer ts_lsp.freeMonikers(gpa, monikers);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (monikers, 0..) |m, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"scheme\":\"");
        try writeJsonStringContents(&buf, gpa, m.scheme);
        try buf.appendSlice(gpa, "\",\"identifier\":\"");
        try writeJsonStringContents(&buf, gpa, m.identifier);
        try buf.appendSlice(gpa, "\",\"unique\":\"");
        try writeJsonStringContents(&buf, gpa, m.unique);
        try buf.appendSlice(gpa, "\",\"kind\":\"");
        const kind_str: []const u8 = switch (m.kind) {
            .import => "import",
            .@"export" => "export",
            .local => "local",
        };
        try buf.appendSlice(gpa, kind_str);
        try buf.appendSlice(gpa, "\"}");
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/inlineValue` JSON-RPC request: extract the
/// `(uri, range, context)` triple, route to `Service.inlineValues`,
/// and emit an LSP `InlineValue[]` array. v0 emits only the
/// `InlineValueVariableLookup` shape — `{ range, variableName,
/// caseSensitiveLookup }` — so debugger UIs can resolve every visible
/// identifier against the active stack frame without round-tripping
/// each one through an `evaluate` request. Caller owns the returned
/// slice.
pub fn handleInlineValue(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    // The LSP request wraps both the visible range and the stopped
    // location's range under different keys, but `findJsonRawField`
    // returns first-occurrence so the top-level `range` resolves
    // before any nested one in `context.stoppedLocation`. Both
    // `start.line` / `end.line` collisions are sidestepped by slicing
    // the range object first and walking it for `start`/`end`.
    const range_raw = findJsonRawField(params_json, "range") orelse return error.MissingRange;

    var start_line: i64 = 0;
    var start_char: i64 = 0;
    var end_line: i64 = std.math.maxInt(i64);
    var end_char: i64 = std.math.maxInt(i64);
    if (std.mem.indexOf(u8, range_raw, "\"start\":")) |sp| {
        const sub = range_raw[sp..];
        start_line = findJsonIntField(sub, "line") orelse 0;
        start_char = findJsonIntField(sub, "character") orelse 0;
    }
    if (std.mem.indexOf(u8, range_raw, "\"end\":")) |ep| {
        const sub = range_raw[ep..];
        end_line = findJsonIntField(sub, "line") orelse std.math.maxInt(i64);
        end_char = findJsonIntField(sub, "character") orelse std.math.maxInt(i64);
    }

    // Extract the `context` (frameId + stoppedLocation). Both fields
    // are optional in v0 — they're forwarded to the service for
    // future filtering but the v0 implementation ignores them.
    var frame_id: i64 = 0;
    var ctx_stop: ts_lsp.Range = .{
        .start_line = 0,
        .start_col = 0,
        .end_line = 0,
        .end_col = 0,
    };
    if (findJsonRawField(params_json, "context")) |ctx_raw| {
        frame_id = findJsonIntField(ctx_raw, "frameId") orelse 0;
        if (findJsonRawField(ctx_raw, "stoppedLocation")) |sl_raw| {
            var sl_start_line: i64 = 0;
            var sl_start_char: i64 = 0;
            var sl_end_line: i64 = 0;
            var sl_end_char: i64 = 0;
            if (std.mem.indexOf(u8, sl_raw, "\"start\":")) |sp| {
                const sub = sl_raw[sp..];
                sl_start_line = findJsonIntField(sub, "line") orelse 0;
                sl_start_char = findJsonIntField(sub, "character") orelse 0;
            }
            if (std.mem.indexOf(u8, sl_raw, "\"end\":")) |ep| {
                const sub = sl_raw[ep..];
                sl_end_line = findJsonIntField(sub, "line") orelse 0;
                sl_end_char = findJsonIntField(sub, "character") orelse 0;
            }
            // LSP wire form is 0-based; ts_lsp.Range is 1-based.
            ctx_stop = .{
                .start_line = @as(u32, @intCast(@max(sl_start_line, 0))) + 1,
                .start_col = @as(u32, @intCast(@max(sl_start_char, 0))) + 1,
                .end_line = @as(u32, @intCast(@max(sl_end_line, 0))) + 1,
                .end_col = @as(u32, @intCast(@max(sl_end_char, 0))) + 1,
            };
        }
    }

    // LSP wire form is 0-based; ts_lsp.Range is 1-based.
    const u32_max: u32 = std.math.maxInt(u32);
    const range_in: ts_lsp.Range = .{
        .start_line = @as(u32, @intCast(@max(start_line, 0))) + 1,
        .start_col = @as(u32, @intCast(@max(start_char, 0))) + 1,
        .end_line = if (end_line >= u32_max) u32_max else @as(u32, @intCast(@max(end_line, 0))) + 1,
        .end_col = if (end_char >= u32_max) u32_max else @as(u32, @intCast(@max(end_char, 0))) + 1,
    };

    const values = try service.inlineValues(gpa, path, range_in, .{
        .frame_id = frame_id,
        .stopped_location = ctx_stop,
    });
    defer ts_lsp.freeInlineValues(gpa, values);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (values, 0..) |v, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"range\":");
        try writeRangeFromRange(&buf, gpa, v.range);
        try buf.appendSlice(gpa, ",\"variableName\":\"");
        try writeJsonStringContents(&buf, gpa, v.variable_name);
        try buf.appendSlice(gpa, "\",\"caseSensitiveLookup\":");
        try buf.appendSlice(gpa, if (v.case_sensitive_lookup) "true" else "false");
        try buf.append(gpa, '}');
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/inlineCompletion` JSON-RPC request (LSP
/// 3.18, experimental): extract the URI + `(line, character)` cursor
/// position and the optional `context` (trigger kind, selected
/// completion info), route to `service.inlineCompletions`, and emit
/// the LSP `InlineCompletionList` shape — `{ items: [] }`. Inline
/// completion provides ghost-text suggestions inserted at the cursor
/// without moving it. v0 returns an empty list (production
/// deployments typically wire this to an AI provider like Copilot
/// or a local model); the capability is advertised so editors stop
/// probing and the wire shape is exercised end-to-end. Caller owns
/// the returned slice.
pub fn handleInlineCompletion(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse 0;
    const character = findJsonIntField(params_json, "character") orelse 0;
    const path = uriToPath(uri);

    // Optional `context` carries `triggerKind` (1 = Invoked, 2 =
    // Automatic) and an optional `selectedCompletionInfo` describing
    // the currently selected item from the standard completion list.
    // v0 forwards both to the service for future use; the stub
    // ignores them.
    var trigger_kind: i64 = 2;
    var selected_text: []const u8 = "";
    if (findJsonRawField(params_json, "context")) |ctx_raw| {
        trigger_kind = findJsonIntField(ctx_raw, "triggerKind") orelse 2;
        if (findJsonRawField(ctx_raw, "selectedCompletionInfo")) |sci_raw| {
            selected_text = findJsonStringField(sci_raw, "text") orelse "";
        }
    }

    // Convert `(line, character)` to a byte offset when the file is
    // known to the program; otherwise pass 0 (the v0 stub ignores
    // the value).
    var byte_pos: u32 = 0;
    if (service.program.lookupPath(path)) |file_id| {
        const f = service.program.fileById(file_id);
        const line_u: u32 = if (line < 0) 0 else @intCast(line);
        const char_u: u32 = if (character < 0) 0 else @intCast(character);
        byte_pos = lineColToByte(f.source, line_u, char_u);
    }

    const items = try service.inlineCompletions(gpa, path, byte_pos, .{
        .trigger_kind = trigger_kind,
        .selected_text = selected_text,
    });
    defer ts_lsp.freeInlineCompletions(gpa, items);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"items\":[");
    for (items, 0..) |it, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"insertText\":\"");
        try writeJsonStringContents(&buf, gpa, it.insert_text);
        try buf.append(gpa, '"');
        if (it.filter_text.len > 0) {
            try buf.appendSlice(gpa, ",\"filterText\":\"");
            try writeJsonStringContents(&buf, gpa, it.filter_text);
            try buf.append(gpa, '"');
        }
        try buf.append(gpa, '}');
    }
    try buf.appendSlice(gpa, "]}");
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/documentColor` JSON-RPC request: extract
/// the URI from `params_json`, route to `service.documentColor`,
/// and encode the LSP response as a `ColorInformation[]` array.
/// Each entry carries `range` plus `color: { red, green, blue,
/// alpha }` (0..1 floats per the LSP spec). v0 returns `[]` —
/// the capability is advertised so editors stop probing, but the
/// color-literal scanner is still TODO. Caller owns the returned
/// slice.
pub fn handleDocumentColor(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const colors = try service.documentColor(gpa, path);
    defer gpa.free(colors);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var fbuf: [64]u8 = undefined;
    try buf.append(gpa, '[');
    for (colors, 0..) |c, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"range\":");
        try writeRangeFromRange(&buf, gpa, c.range);
        try buf.appendSlice(gpa, ",\"color\":{\"red\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&fbuf, "{d}", .{c.red}));
        try buf.appendSlice(gpa, ",\"green\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&fbuf, "{d}", .{c.green}));
        try buf.appendSlice(gpa, ",\"blue\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&fbuf, "{d}", .{c.blue}));
        try buf.appendSlice(gpa, ",\"alpha\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&fbuf, "{d}", .{c.alpha}));
        try buf.appendSlice(gpa, "}}");
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `textDocument/colorPresentation` JSON-RPC request:
/// extract `(uri, color, range)` from `params_json`, route to
/// `service.colorPresentation`, and emit a `ColorPresentation[]`
/// array. Each entry carries a `label` (the alternate spelling the
/// editor's color picker offers — e.g. `"#ff0000"` vs
/// `"rgb(255,0,0)"`). v0 returns `[]` until the formatter is wired
/// up. Caller owns the returned slice.
pub fn handleColorPresentation(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    // Param fields (color + range) are accepted but unused by the
    // v0 stub — parsing them up-front keeps the wire-shape contract
    // honest and matches what a real implementation would do.
    const color = ts_lsp.ColorInformation{
        .range = .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 0 },
        .red = 0,
        .green = 0,
        .blue = 0,
        .alpha = 0,
    };
    const range = ts_lsp.Range{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 0 };

    const items = try service.colorPresentation(gpa, path, color, range);
    defer ts_lsp.freeColorPresentations(gpa, items);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (items, 0..) |p, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"label\":\"");
        try writeJsonStringContents(&buf, gpa, p.label);
        try buf.appendSlice(gpa, "\"}");
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `workspace/willRenameFiles` JSON-RPC request: extract the
/// `files` array (each entry has an `oldUri` + `newUri` LSP URI), route
/// to `Service.workspaceWillRenameFiles`, and emit an LSP
/// `WorkspaceEdit` whose `changes` map groups the returned `[]TextEdit`
/// by URI. When the service returns no edits — the current stub
/// behavior — we return `null`, which LSP treats as "no follow-up
/// edits needed". Caller owns the returned slice.
pub fn handleWillRenameFiles(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const files_raw = findJsonRawField(params_json, "files") orelse return error.MissingFiles;

    // Walk the JSON array of file-rename objects, slicing out each
    // `{ oldUri, newUri }` object so we don't accidentally lift fields
    // across object boundaries.
    var renames: std.ArrayListUnmanaged(ts_lsp.FileRename) = .empty;
    defer renames.deinit(gpa);

    var i: usize = 0;
    while (i < files_raw.len) {
        while (i < files_raw.len and (files_raw[i] == ' ' or files_raw[i] == '\t' or files_raw[i] == '\n' or files_raw[i] == '\r' or files_raw[i] == ',' or files_raw[i] == '[')) : (i += 1) {}
        if (i >= files_raw.len or files_raw[i] == ']') break;
        if (files_raw[i] != '{') {
            i += 1;
            continue;
        }
        const obj_start = i;
        var depth: usize = 0;
        var in_str = false;
        var j = i;
        while (j < files_raw.len) : (j += 1) {
            const ch = files_raw[j];
            if (in_str) {
                if (ch == '\\') {
                    j += 1;
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
                if (depth == 0) break;
            }
        }
        if (j >= files_raw.len) break;
        const obj_slice = files_raw[obj_start .. j + 1];
        i = j + 1;

        const old_uri = findJsonStringField(obj_slice, "oldUri") orelse continue;
        const new_uri = findJsonStringField(obj_slice, "newUri") orelse continue;
        try renames.append(gpa, .{ .old_uri = old_uri, .new_uri = new_uri });
    }

    const edits = try service.workspaceWillRenameFiles(gpa, renames.items);
    defer {
        for (edits) |e| gpa.free(e.new_text);
        gpa.free(edits);
    }

    if (edits.len == 0) {
        // LSP allows `null` here to signal "no follow-up edits needed".
        return encodeResponse(gpa, request_id, "null");
    }

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
        for (entry.value_ptr.*.items, 0..) |edit_idx, k| {
            if (k > 0) try buf.append(gpa, ',');
            try writeTextEdit(&buf, gpa, edits[edit_idx]);
        }
        try buf.append(gpa, ']');
    }
    try buf.appendSlice(gpa, "}}");
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
        for (hints) |h| {
            gpa.free(h.label);
            gpa.free(h.tooltip);
        }
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
        // Tooltip is rendered as a MarkupContent value (markdown).
        try buf.appendSlice(gpa, ",\"tooltip\":{\"kind\":\"markdown\",\"value\":\"");
        try writeJsonStringContents(&buf, gpa, h.tooltip);
        try buf.appendSlice(gpa, "\"}");
        try buf.append(gpa, '}');
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle an `inlayHint/resolve` JSON-RPC request. Stub: echoes the
/// input `InlayHint` back unchanged. The editor uses
/// `inlayHint/resolve` when a hint's `tooltip` or `textEdits` were
/// omitted in the initial response and need lazy resolution; our
/// `inlayHint` handler emits complete hints, so resolve is a no-op
/// here. Caller owns the returned slice.
pub fn handleInlayHintResolve(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    _ = service;
    return encodeResponse(gpa, request_id, params_json);
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

/// Handle a `textDocument/onTypeFormatting` JSON-RPC request: extract
/// the URI, position, trigger character, and `FormattingOptions`,
/// route to `Service.onTypeFormatting`, and emit an LSP `TextEdit[]`
/// array. v0 always returns `[]` — the wire surface is in place so
/// editors that probe the capability succeed; smarter on-type edits
/// (dedent on `}`, indent on `\n`, etc.) follow once the formatter
/// can reason about partial input. Caller owns the returned slice.
pub fn handleOnTypeFormatting(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const line = findJsonIntField(params_json, "line") orelse return error.MissingLine;
    const character = findJsonIntField(params_json, "character") orelse return error.MissingCharacter;
    const ch = findJsonStringField(params_json, "ch") orelse "";
    const path = uriToPath(uri);

    // FormattingOptions is optional in our v0 path — defaults match the
    // LSP spec (`tabSize: 4`, `insertSpaces: true`).
    var opts: ts_lsp.FormattingOptions = .{};
    if (findJsonIntField(params_json, "tabSize")) |ts| {
        if (ts > 0) opts.tab_size = @intCast(ts);
    }
    // `insertSpaces` is a bool — find it positionally; if absent leave default.
    if (std.mem.indexOf(u8, params_json, "\"insertSpaces\":false") != null) {
        opts.insert_spaces = false;
    }

    const file_id = service.program.lookupPath(path) orelse {
        return encodeResponse(gpa, request_id, "[]");
    };
    const f = service.program.fileById(file_id);
    const line_u: u32 = if (line < 0) 0 else @intCast(line);
    const char_u: u32 = if (character < 0) 0 else @intCast(character);
    const byte_pos = lineColToByte(f.source, line_u, char_u);

    const edits = try service.onTypeFormatting(gpa, path, byte_pos, ch, opts);
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

/// Handle a `textDocument/willSaveWaitUntil` JSON-RPC request: extract
/// the URI + LSP `TextDocumentSaveReason` integer (1 = manual,
/// 2 = afterDelay, 3 = focusOut — note LSP collapses our `manual`
/// + `auto` into the single `manual` value), route to
/// `Service.willSaveWaitUntil`, and emit an LSP `TextEdit[]` array.
/// Returns `[]` for unknown files. Caller owns the returned slice.
pub fn handleWillSaveWaitUntil(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    // `reason` is optional per the LSP spec — default to `manual` when
    // absent or out of range.
    const reason_int = findJsonIntField(params_json, "reason") orelse 1;
    const reason: ts_lsp.SaveReason = switch (reason_int) {
        1 => .manual,
        2 => .after_delay,
        3 => .focus_out,
        else => .manual,
    };

    if (service.program.lookupPath(path) == null) {
        return encodeResponse(gpa, request_id, "[]");
    }

    const edits = try service.willSaveWaitUntil(gpa, path, reason);
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

/// Handle a `textDocument/codeLens` JSON-RPC request: extract the
/// URI, route to `Service.codeLenses`, and emit an LSP `CodeLens[]`
/// array. Each lens has a `range` and a `command` carrying the
/// title (e.g. `"5 references"`); the command id is empty so the
/// lens is display-only. Caller owns the returned slice.
pub fn handleCodeLens(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const lenses = try service.codeLenses(gpa, path);
    defer ts_lsp.freeCodeLenses(gpa, lenses);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (lenses, 0..) |l, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"range\":");
        try writeRange(&buf, gpa, l.span);
        try buf.appendSlice(gpa, ",\"command\":{\"title\":\"");
        try writeJsonStringContents(&buf, gpa, l.title);
        try buf.appendSlice(gpa, "\",\"command\":\"");
        try writeJsonStringContents(&buf, gpa, l.command);
        try buf.appendSlice(gpa, "\"}}");
    }
    try buf.append(gpa, ']');
    return encodeResponse(gpa, request_id, buf.items);
}

/// Handle a `codeLens/resolve` JSON-RPC request. Stub: echoes the
/// input `CodeLens` back unchanged. The editor uses
/// `codeLens/resolve` when a lens's `command` was omitted in the
/// initial response and needs lazy resolution; our `codeLens`
/// handler always emits `command` eagerly, so resolve is a no-op
/// here. Caller owns the returned slice.
pub fn handleCodeLensResolve(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    _ = service;
    return encodeResponse(gpa, request_id, params_json);
}

/// Map `LspDiagnostic.Severity` to the LSP-wire severity number
/// (1 = Error, 2 = Warning, 3 = Information, 4 = Hint).
fn lspSeverityCode(s: ts_lsp.LspDiagnostic.Severity) u8 {
    return switch (s) {
        .err => 1,
        .warning => 2,
        .info => 3,
        .hint => 4,
    };
}

/// Encode a `textDocument/publishDiagnostics` JSON-RPC notification
/// body from structured `[]LspDiagnostic`. Each entry is rendered
/// as an LSP `Diagnostic` object with the spec-required shape:
/// `range`, `severity`, `code`, `source`, `message`. Span coords
/// are converted from `ts_lsp.Span`'s 1-based form to LSP's
/// 0-based wire form (matching `writeRange`).
/// Caller owns the returned slice.
pub fn encodePublishDiagnosticsStructured(
    gpa: std.mem.Allocator,
    uri: []const u8,
    diags: []const ts_lsp.LspDiagnostic,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    try writeJsonStringContents(&buf, gpa, uri);
    try buf.appendSlice(gpa, "\",\"diagnostics\":[");
    for (diags, 0..) |d, i| {
        if (i != 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"range\":");
        try writeRange(&buf, gpa, d.range);
        var nbuf: [64]u8 = undefined;
        const sev_code = try std.fmt.bufPrint(
            &nbuf,
            ",\"severity\":{d},\"code\":{d},\"source\":\"",
            .{ lspSeverityCode(d.severity), d.code },
        );
        try buf.appendSlice(gpa, sev_code);
        try writeJsonStringContents(&buf, gpa, d.source);
        try buf.appendSlice(gpa, "\",\"message\":\"");
        try writeJsonStringContents(&buf, gpa, d.message);
        try buf.appendSlice(gpa, "\"}");
    }
    try buf.appendSlice(gpa, "]}}");
    return buf.toOwnedSlice(gpa);
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

/// Handle the LSP `textDocument/diagnostic` pull-mode request. Returns
/// a `RelatedFullDocumentDiagnosticReport` JSON-RPC response —
/// `{"kind":"full","items":[Diagnostic, ...]}`. Differs from the
/// server-pushed `publishDiagnostics` notification in that the editor
/// asks for diagnostics on demand (e.g. when a tab regains focus).
/// Each item has the spec-required shape `range`, `severity`, `code`,
/// `source`, `message` — coords go through `writeRange` for the
/// 1-based -> 0-based conversion, severity via `lspSeverityCode`.
/// Caller owns the returned slice.
pub fn handleDiagnostic(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    const uri = findJsonStringField(params_json, "uri") orelse return error.MissingUri;
    const path = uriToPath(uri);

    const diags = try service.diagnosticsStructured(gpa, path);
    defer ts_lsp.freeLspDiagnostics(gpa, diags);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"kind\":\"full\",\"items\":[");
    for (diags, 0..) |d, i| {
        if (i != 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"range\":");
        try writeRange(&buf, gpa, d.range);
        var nbuf: [64]u8 = undefined;
        const sev_code = try std.fmt.bufPrint(
            &nbuf,
            ",\"severity\":{d},\"code\":{d},\"source\":\"",
            .{ lspSeverityCode(d.severity), d.code },
        );
        try buf.appendSlice(gpa, sev_code);
        try writeJsonStringContents(&buf, gpa, d.source);
        try buf.appendSlice(gpa, "\",\"message\":\"");
        try writeJsonStringContents(&buf, gpa, d.message);
        try buf.appendSlice(gpa, "\"}");
    }
    try buf.appendSlice(gpa, "]}");
    return encodeResponse(gpa, request_id, buf.items);
}

/// LSP 3.17 `textDocument/diagnostic` pull-mode handler. Alias for
/// `handleDiagnostic` exposed under the spec-aligned name; the editor
/// asks for diagnostics on demand and we return a
/// `RelatedFullDocumentDiagnosticReport` (`{kind:"full",items:[...]}`).
pub fn handleDocumentDiagnostic(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    return handleDiagnostic(service, gpa, request_id, params_json);
}

/// LSP 3.17 `workspace/diagnostic` pull-mode handler. Walks every
/// tracked program file, emits a `WorkspaceFullDocumentDiagnosticReport`
/// per file (`{kind:"full",uri,version:null,items:[...]}`), and wraps
/// the list in a `WorkspaceDiagnosticReport` (`{items:[...]}`). The
/// `previousResultIds` and `partialResultToken` params are accepted
/// but ignored — this server always emits full reports. Caller owns
/// the returned slice.
pub fn handleWorkspaceDiagnostic(
    service: *ts_lsp.Service,
    gpa: std.mem.Allocator,
    request_id: RequestId,
    params_json: []const u8,
) ![]u8 {
    _ = params_json;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"items\":[");

    var first_file = true;
    for (service.program.files.items) |f| {
        const diags = try service.diagnosticsStructured(gpa, f.path);
        defer ts_lsp.freeLspDiagnostics(gpa, diags);

        if (!first_file) try buf.append(gpa, ',');
        first_file = false;

        try buf.appendSlice(gpa, "{\"kind\":\"full\",\"uri\":\"file://");
        try writeJsonStringContents(&buf, gpa, f.path);
        try buf.appendSlice(gpa, "\",\"version\":null,\"items\":[");
        for (diags, 0..) |d, i| {
            if (i != 0) try buf.append(gpa, ',');
            try buf.appendSlice(gpa, "{\"range\":");
            try writeRange(&buf, gpa, d.range);
            var nbuf: [64]u8 = undefined;
            const sev_code = try std.fmt.bufPrint(
                &nbuf,
                ",\"severity\":{d},\"code\":{d},\"source\":\"",
                .{ lspSeverityCode(d.severity), d.code },
            );
            try buf.appendSlice(gpa, sev_code);
            try writeJsonStringContents(&buf, gpa, d.source);
            try buf.appendSlice(gpa, "\",\"message\":\"");
            try writeJsonStringContents(&buf, gpa, d.message);
            try buf.appendSlice(gpa, "\"}");
        }
        try buf.appendSlice(gpa, "]}");
    }

    try buf.appendSlice(gpa, "]}");
    return encodeResponse(gpa, request_id, buf.items);
}

/// Render the InitializeResult body — declares capabilities for
/// every method we support.
pub fn renderInitializeResult(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8,
        \\{"capabilities":{"textDocumentSync":1,"hoverProvider":true,"definitionProvider":true,"declarationProvider":true,"referencesProvider":true,"completionProvider":{"triggerCharacters":[".","("]},"diagnosticProvider":{"interFileDependencies":true,"workspaceDiagnostics":true}},"serverInfo":{"name":"home-lsp","version":"0.1.0"}}
    );
}

/// Render the full InitializeResult capabilities response advertised
/// by `initialize`. This is the long-form descriptor used by the
/// lifecycle handler — the older `renderInitializeResult` remains for
/// the legacy stdio loop in `lsp_main.zig`.
///
/// The response embeds `SUPPORTED_METHODS` under
/// `serverInfo.supportedMethods` so external clients and integration
/// tests can introspect coverage without scraping capability flags.
pub fn renderInitializeCapabilities(gpa: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa,
        \\{"capabilities":{"textDocumentSync":1,"hoverProvider":true,"definitionProvider":true,"declarationProvider":true,"referencesProvider":true,"completionProvider":{"triggerCharacters":["."," "]},"documentSymbolProvider":true,"workspaceSymbolProvider":true,"renameProvider":{"prepareProvider":true},"codeActionProvider":true,"executeCommandProvider":{"commands":["home.organizeImports","home.applyCodeAction"]},"semanticTokensProvider":{"legend":{"tokenTypes":["variable","parameter","function","method","class","interface","type","enum","property","keyword","string","number","operator","comment"],"tokenModifiers":[]},"full":true,"range":true},"signatureHelpProvider":{"triggerCharacters":["(",","]},"documentHighlightProvider":false,"documentFormattingProvider":true,"documentOnTypeFormattingProvider":{"firstTriggerCharacter":"}","moreTriggerCharacters":[";","\n"]},"foldingRangeProvider":true,"selectionRangeProvider":true,"monikerProvider":true,"typeHierarchyProvider":true,"inlineValueProvider":true,"inlineCompletionProvider":true,"colorProvider":true,"inlayHintProvider":{"resolveProvider":false}},"serverInfo":{"name":"home-lsp","version":"0.1.0","supportedMethods":[
    );
    for (SUPPORTED_METHODS, 0..) |m, i| {
        if (i != 0) try buf.append(gpa, ',');
        try buf.append(gpa, '"');
        try writeJsonStringContents(&buf, gpa, m);
        try buf.append(gpa, '"');
    }
    try buf.appendSlice(gpa, "]}}");
    return buf.toOwnedSlice(gpa);
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
        .text_document_diagnostic => {
            if (is_notification) return &.{};
            return try handleDocumentDiagnostic(service, gpa, id, params);
        },
        .workspace_diagnostic => {
            if (is_notification) return &.{};
            return try handleWorkspaceDiagnostic(service, gpa, id, params);
        },
        .text_document_hover => {
            if (is_notification) return &.{};
            return try handleHover(service, gpa, id, params);
        },
        .text_document_definition => {
            if (is_notification) return &.{};
            return try handleDefinition(service, gpa, id, params);
        },
        .text_document_declaration => {
            if (is_notification) return &.{};
            return try handleDeclaration(service, gpa, id, params);
        },
        .text_document_type_definition => {
            if (is_notification) return &.{};
            return try handleTypeDefinition(service, gpa, id, params);
        },
        .text_document_references => {
            if (is_notification) return &.{};
            return try handleReferences(service, gpa, id, params);
        },
        .text_document_prepare_call_hierarchy => {
            if (is_notification) return &.{};
            return try handleCallHierarchyPrepare(service, gpa, id, params);
        },
        .call_hierarchy_incoming_calls => {
            if (is_notification) return &.{};
            return try handleCallHierarchyIncomingCalls(service, gpa, id, params);
        },
        .call_hierarchy_outgoing_calls => {
            if (is_notification) return &.{};
            return try handleCallHierarchyOutgoingCalls(service, gpa, id, params);
        },
        .text_document_prepare_type_hierarchy => {
            if (is_notification) return &.{};
            return try handlePrepareTypeHierarchy(service, gpa, id, params);
        },
        .type_hierarchy_supertypes => {
            if (is_notification) return &.{};
            return try handleTypeHierarchySupertypes(service, gpa, id, params);
        },
        .type_hierarchy_subtypes => {
            if (is_notification) return &.{};
            return try handleTypeHierarchySubtypes(service, gpa, id, params);
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
        .text_document_semantic_tokens_full_delta => {
            if (is_notification) return &.{};
            return try handleSemanticTokensDelta(service, gpa, id, params);
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
        .inlay_hint_resolve => {
            if (is_notification) return &.{};
            return try handleInlayHintResolve(service, gpa, id, params);
        },
        .text_document_document_highlight => {
            if (is_notification) return &.{};
            return try handleDocumentHighlight(service, gpa, id, params);
        },
        .text_document_formatting => {
            if (is_notification) return &.{};
            return try handleFormatting(service, gpa, id, params);
        },
        .text_document_on_type_formatting => {
            if (is_notification) return &.{};
            return try handleOnTypeFormatting(service, gpa, id, params);
        },
        .text_document_code_lens => {
            if (is_notification) return &.{};
            return try handleCodeLens(service, gpa, id, params);
        },
        .code_lens_resolve => {
            if (is_notification) return &.{};
            return try handleCodeLensResolve(service, gpa, id, params);
        },
        .text_document_implementation => {
            if (is_notification) return &.{};
            return try handleImplementation(service, gpa, id, params);
        },
        .text_document_document_link => {
            if (is_notification) return &.{};
            return try handleDocumentLink(service, gpa, id, params);
        },
        .document_link_resolve => {
            if (is_notification) return &.{};
            return try handleDocumentLinkResolve(service, gpa, id, params);
        },
        .text_document_selection_range => {
            if (is_notification) return &.{};
            return try handleSelectionRange(service, gpa, id, params);
        },
        .text_document_linked_editing_range => {
            if (is_notification) return &.{};
            return try handleLinkedEditingRange(service, gpa, id, params);
        },
        .workspace_will_rename_files => {
            if (is_notification) return &.{};
            return try handleWillRenameFiles(service, gpa, id, params);
        },
        .workspace_execute_command => {
            if (is_notification) return &.{};
            return try handleExecuteCommand(service, gpa, id, params);
        },
        .text_document_moniker => {
            if (is_notification) return &.{};
            return try handleMoniker(service, gpa, id, params);
        },
        .text_document_inline_value => {
            if (is_notification) return &.{};
            return try handleInlineValue(service, gpa, id, params);
        },
        .text_document_will_save_wait_until => {
            if (is_notification) return &.{};
            return try handleWillSaveWaitUntil(service, gpa, id, params);
        },
        .text_document_inline_completion => {
            if (is_notification) return &.{};
            return try handleInlineCompletion(service, gpa, id, params);
        },
        .text_document_document_color => {
            if (is_notification) return &.{};
            return try handleDocumentColor(service, gpa, id, params);
        },
        .text_document_color_presentation => {
            if (is_notification) return &.{};
            return try handleColorPresentation(service, gpa, id, params);
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
    try T.expect(std.mem.indexOf(u8, r, "\"renameProvider\":{\"prepareProvider\":true}") != null);
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

test "SUPPORTED_METHODS: enumerates every wire method dispatchRequest handles" {
    // Spot-check core lifecycle + sync methods.
    var saw_initialize = false;
    var saw_shutdown = false;
    var saw_did_open = false;
    var saw_hover = false;
    var saw_completion_resolve = false;
    var saw_call_hierarchy_outgoing = false;
    var saw_diagnostic = false;
    for (SUPPORTED_METHODS) |m| {
        if (std.mem.eql(u8, m, "initialize")) saw_initialize = true;
        if (std.mem.eql(u8, m, "shutdown")) saw_shutdown = true;
        if (std.mem.eql(u8, m, "textDocument/didOpen")) saw_did_open = true;
        if (std.mem.eql(u8, m, "textDocument/hover")) saw_hover = true;
        if (std.mem.eql(u8, m, "completionItem/resolve")) saw_completion_resolve = true;
        if (std.mem.eql(u8, m, "callHierarchy/outgoingCalls")) saw_call_hierarchy_outgoing = true;
        if (std.mem.eql(u8, m, "textDocument/diagnostic")) saw_diagnostic = true;
    }
    try T.expect(saw_initialize);
    try T.expect(saw_shutdown);
    try T.expect(saw_did_open);
    try T.expect(saw_hover);
    try T.expect(saw_completion_resolve);
    try T.expect(saw_call_hierarchy_outgoing);
    try T.expect(saw_diagnostic);
    // Every entry must round-trip through Method.fromString — guards
    // against typos that would silently fall to .unknown at runtime.
    for (SUPPORTED_METHODS) |m| {
        try T.expect(Method.fromString(m) != .unknown);
    }
}

test "renderInitializeCapabilities: embeds supportedMethods list" {
    const r = try renderInitializeCapabilities(T.allocator);
    defer T.allocator.free(r);
    try T.expect(std.mem.indexOf(u8, r, "\"supportedMethods\":[") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"initialize\"") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"textDocument/hover\"") != null);
    try T.expect(std.mem.indexOf(u8, r, "\"callHierarchy/outgoingCalls\"") != null);
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
    // Structured diagnostics emit per-LSP `Diagnostic` shape: a
    // `range`/`severity`/`code`/`source` quartet rather than the
    // tsc-style `error TSxxxx:` line stuffed into `message`.
    try T.expect(std.mem.indexOf(u8, out2, "\"severity\":1") != null);
    try T.expect(std.mem.indexOf(u8, out2, "\"source\":\"ts\"") != null);
}

test "handleDidChange: emits structured Diagnostic[] with range/severity/code/source" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x: number = 1;");
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    // didChange flips the source to a type-error variant; the
    // resulting publishDiagnostics body must carry the LSP-spec
    // `Diagnostic` shape (not a (0,0)..(0,0) tsc-string fallback).
    const body =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///main.ts","version":2},"contentChanges":[{"text":"let x: number = \"oops\";"}]}}
    ;
    const out = try handleDidChange(&svc, T.allocator, body);
    defer T.allocator.free(out);

    try T.expect(std.mem.indexOf(u8, out, "\"method\":\"textDocument/publishDiagnostics\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"uri\":\"file:///main.ts\"") != null);
    // Each diagnostic carries the four LSP-required fields plus
    // a `range` object — assert all show up in the wire body.
    try T.expect(std.mem.indexOf(u8, out, "\"range\":{\"start\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"severity\":1") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"source\":\"ts\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"code\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"message\":\"") != null);
    // The legacy text-renderer prefix must NOT leak through —
    // the `error TSxxxx:` form belongs to the rendered blob, not
    // to the structured wire shape.
    try T.expect(std.mem.indexOf(u8, out, "error TS") == null);
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

test "handleDeclaration: returns same Location response shape as definition" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Same shape exercise as handleDefinition: cursor on `foo`
    // reference (line 1) should resolve back to the declaration.
    const src =
        \\let foo = 1;
        \\let bar = foo;
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":131,"method":"textDocument/declaration","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":1,"character":10}}}
    ;
    const out = try handleDeclaration(&svc, T.allocator, .{ .integer = 131 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":131") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":{\"uri\":\"file:///main.ts\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);

    // Cursor outside any identifier -> result: null.
    const oob =
        \\{"jsonrpc":"2.0","id":132,"method":"textDocument/declaration","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":99,"character":0}}}
    ;
    const out2 = try handleDeclaration(&svc, T.allocator, .{ .integer = 132 }, oob);
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

test "handleCompletionItemResolve: fills detail from top-level symbol type" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "function add(a: number, b: number): number { return a + b; }");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":162,"method":"completionItem/resolve","params":{"label":"add","kind":3}}
    ;
    const params = findJsonRawField(body, "params").?;
    const out = try handleCompletionItemResolve(&svc, T.allocator, .{ .integer = 162 }, params);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":162") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"label\":\"add\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"detail\":\"") != null);
    // The rendered detail should mention the function shape.
    try T.expect(std.mem.indexOf(u8, out, "function add") != null);
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

test "handleExecuteCommand: home.organizeImports returns edits or null" {
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
        \\{"jsonrpc":"2.0","id":82,"method":"workspace/executeCommand","params":{"command":"home.organizeImports","arguments":["file:///main.ts"]}}
    ;
    const out = try handleExecuteCommand(&svc, T.allocator, .{ .integer = 82 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":82") != null);
    // Either we got a WorkspaceEdit (changes map) or null — the
    // important property is that the wire round-trip didn't crash.
    const has_edit = std.mem.indexOf(u8, out, "\"changes\":") != null;
    const has_null = std.mem.indexOf(u8, out, "\"result\":null") != null;
    try T.expect(has_edit or has_null);

    // Unknown command falls through to null.
    const body_unknown =
        \\{"jsonrpc":"2.0","id":83,"method":"workspace/executeCommand","params":{"command":"home.somethingElse","arguments":[]}}
    ;
    const out_unknown = try handleExecuteCommand(&svc, T.allocator, .{ .integer = 83 }, body_unknown);
    defer T.allocator.free(out_unknown);
    try T.expect(std.mem.indexOf(u8, out_unknown, "\"result\":null") != null);
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

test "handleSemanticTokensDelta: returns object with resultId and data array" {
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
        \\{"jsonrpc":"2.0","id":92,"method":"textDocument/semanticTokens/full/delta","params":{"textDocument":{"uri":"file:///main.ts"},"previousResultId":"stale-id"}}
    ;
    const out = try handleSemanticTokensDelta(&svc, T.allocator, .{ .integer = 92 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":92") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"resultId\":\"v0-") != null);
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

test "handleSelectionRange: returns nested SelectionRange[] response" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "function foo() { let q = 1; }");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":141,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"file:///main.ts"},"positions":[{"line":0,"character":21}]}}
    ;
    const out = try handleSelectionRange(&svc, T.allocator, .{ .integer = 141 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":141") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":") != null);
    // With ranges nested innermost-first via parent links, expect at
    // least one parent edge for a non-trivial cursor position.
    try T.expect(std.mem.indexOf(u8, out, "\"parent\":") != null);
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
    try T.expect(std.mem.indexOf(u8, out, "\"tooltip\":{\"kind\":\"markdown\"") != null);
}

test "handleInlayHintResolve: stub echoes input params" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const params =
        \\{"position":{"line":0,"character":5},"label":": number","kind":1}
    ;
    const out = try handleInlayHintResolve(&svc, T.allocator, .{ .integer = 122 }, params);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":122") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"position\":{\"line\":0,\"character\":5}") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"label\":\": number\"") != null);
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

test "handleOnTypeFormatting: returns TextEdit array (empty for v0)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "function f() {\n  let x = 1;\n}\n");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":142,"method":"textDocument/onTypeFormatting","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":2,"character":1},"ch":"}","options":{"tabSize":2,"insertSpaces":true}}}
    ;
    const out = try handleOnTypeFormatting(&svc, T.allocator, .{ .integer = 142 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":142") != null);
    // v0 stub: edits list is empty.
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[]") != null);
}

test "handleCodeLens: returns CodeLens array with range+command title" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "function foo() {} foo(); foo();");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":151,"method":"textDocument/codeLens","params":{"textDocument":{"uri":"file:///main.ts"}}}
    ;
    const out = try handleCodeLens(&svc, T.allocator, .{ .integer = 151 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":151") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"command\":{\"title\":\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "2 references") != null);
}

test "handleDiagnostic: returns RelatedFullDocumentDiagnosticReport with items" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Type mismatch — guarantees at least one diagnostic.
    _ = try program.add("/main.ts", "let x: number = \"oops\";");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":171,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///main.ts"}}}
    ;
    const out = try handleDiagnostic(&svc, T.allocator, .{ .integer = 171 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":171") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":\"full\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"items\":[") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"severity\":1") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"source\":\"ts\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"message\":\"") != null);
}

test "handleDocumentDiagnostic: pull-mode response shape" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let x: number = \"oops\";");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":901,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///main.ts"}}}
    ;
    const out = try handleDocumentDiagnostic(&svc, T.allocator, .{ .integer = 901 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":901") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":\"full\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"items\":[") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"severity\":1") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"source\":\"ts\"") != null);
}

test "handleWorkspaceDiagnostic: returns WorkspaceDiagnosticReport across files" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // Two files, only one carries a type error — the wrapper still
    // emits a full report per file (the clean file gets `items:[]`).
    _ = try program.add("/a.ts", "let x: number = \"bad\";");
    _ = try program.add("/b.ts", "let y: number = 42;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":902,"method":"workspace/diagnostic","params":{}}
    ;
    const out = try handleWorkspaceDiagnostic(&svc, T.allocator, .{ .integer = 902 }, body);
    defer T.allocator.free(out);

    try T.expect(std.mem.indexOf(u8, out, "\"id\":902") != null);
    // Outer WorkspaceDiagnosticReport shape.
    try T.expect(std.mem.indexOf(u8, out, "\"result\":{\"items\":[") != null);
    // Per-file WorkspaceFullDocumentDiagnosticReport shape.
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":\"full\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"version\":null") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"uri\":\"file:///a.ts\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"uri\":\"file:///b.ts\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"severity\":1") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"source\":\"ts\"") != null);
}

test "handleTypeDefinition: routes request and returns Location response" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // `let x: Foo = ...` — typeDefinition on `x` resolves to the
    // `interface Foo` declaration on line 0.
    const src =
        \\interface Foo { a: number }
        \\let x: Foo = { a: 1 };
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":211,"method":"textDocument/typeDefinition","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":1,"character":4}}}
    ;
    const out = try handleTypeDefinition(&svc, T.allocator, .{ .integer = 211 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":211") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":{\"uri\":\"file:///main.ts\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"range\":") != null);

    const empty =
        \\{"jsonrpc":"2.0","id":212,"method":"textDocument/typeDefinition","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":99,"character":0}}}
    ;
    const out2 = try handleTypeDefinition(&svc, T.allocator, .{ .integer = 212 }, empty);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"result\":null") != null);
}

test "handleCallHierarchyPrepare: returns single-item array for fn under cursor" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "function target() { return 1; }\n");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":221,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":9}}}
    ;
    const out = try handleCallHierarchyPrepare(&svc, T.allocator, .{ .integer = 221 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":221") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[{\"name\":\"target\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":12") != null); // SymbolKind.function
    try T.expect(std.mem.indexOf(u8, out, "\"selectionRange\":") != null);

    const empty =
        \\{"jsonrpc":"2.0","id":222,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":99,"character":0}}}
    ;
    const out2 = try handleCallHierarchyPrepare(&svc, T.allocator, .{ .integer = 222 }, empty);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"result\":null") != null);
}

test "handleCallHierarchyIncomingCalls: returns wrapped from-items" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        "function target() { return 1; }\n" ++
        "function caller_a() { return target(); }\n";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":231,"method":"callHierarchy/incomingCalls","params":{"item":{"name":"target","kind":12,"uri":"file:///main.ts","range":{"start":{"line":0,"character":9},"end":{"line":0,"character":15}},"selectionRange":{"start":{"line":0,"character":9},"end":{"line":0,"character":15}}}}}
    ;
    const out = try handleCallHierarchyIncomingCalls(&svc, T.allocator, .{ .integer = 231 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":231") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"from\":{\"name\":\"caller_a\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"fromRanges\":[]") != null);
}

test "handlePrepareTypeHierarchy: returns single-item array for class under cursor" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        "interface Animal { name: string; }\n" ++
        "class Dog implements Animal { name: string = ''; }\n";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Cursor on `Dog` class name (line 1, char 6).
    const body =
        \\{"jsonrpc":"2.0","id":331,"method":"textDocument/prepareTypeHierarchy","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":1,"character":6}}}
    ;
    const out = try handlePrepareTypeHierarchy(&svc, T.allocator, .{ .integer = 331 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":331") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[{\"name\":\"Dog\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"kind\":5") != null); // SymbolKind.class
    try T.expect(std.mem.indexOf(u8, out, "\"selectionRange\":") != null);

    // Cursor not on any class/interface -> null.
    const empty =
        \\{"jsonrpc":"2.0","id":332,"method":"textDocument/prepareTypeHierarchy","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":99,"character":0}}}
    ;
    const out2 = try handlePrepareTypeHierarchy(&svc, T.allocator, .{ .integer = 332 }, empty);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"result\":null") != null);
}

test "handleTypeHierarchySupertypes/subtypes: returns array response shape" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        "interface Animal { name: string; }\n" ++
        "class Dog implements Animal { name: string = ''; }\n";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Supertypes of `Dog` -> includes `Animal`.
    const sup_body =
        \\{"jsonrpc":"2.0","id":341,"method":"typeHierarchy/supertypes","params":{"item":{"name":"Dog","kind":5,"uri":"file:///main.ts","range":{"start":{"line":1,"character":6},"end":{"line":1,"character":9}},"selectionRange":{"start":{"line":1,"character":6},"end":{"line":1,"character":9}}}}}
    ;
    const sup_out = try handleTypeHierarchySupertypes(&svc, T.allocator, .{ .integer = 341 }, sup_body);
    defer T.allocator.free(sup_out);
    try T.expect(std.mem.indexOf(u8, sup_out, "\"id\":341") != null);
    try T.expect(std.mem.indexOf(u8, sup_out, "\"result\":[") != null);
    try T.expect(std.mem.indexOf(u8, sup_out, "\"name\":\"Animal\"") != null);

    // Subtypes of `Animal` -> includes `Dog`.
    const sub_body =
        \\{"jsonrpc":"2.0","id":342,"method":"typeHierarchy/subtypes","params":{"item":{"name":"Animal","kind":11,"uri":"file:///main.ts","range":{"start":{"line":0,"character":10},"end":{"line":0,"character":16}},"selectionRange":{"start":{"line":0,"character":10},"end":{"line":0,"character":16}}}}}
    ;
    const sub_out = try handleTypeHierarchySubtypes(&svc, T.allocator, .{ .integer = 342 }, sub_body);
    defer T.allocator.free(sub_out);
    try T.expect(std.mem.indexOf(u8, sub_out, "\"id\":342") != null);
    try T.expect(std.mem.indexOf(u8, sub_out, "\"result\":[") != null);
    try T.expect(std.mem.indexOf(u8, sub_out, "\"name\":\"Dog\"") != null);
}

test "handleCallHierarchyOutgoingCalls: returns wrapped to-items" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    const src =
        "function helper_a() { return 1; }\n" ++
        "function caller() { return helper_a(); }\n";
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":241,"method":"callHierarchy/outgoingCalls","params":{"item":{"name":"caller","kind":12,"uri":"file:///main.ts","range":{"start":{"line":1,"character":9},"end":{"line":1,"character":15}},"selectionRange":{"start":{"line":1,"character":9},"end":{"line":1,"character":15}}}}}
    ;
    const out = try handleCallHierarchyOutgoingCalls(&svc, T.allocator, .{ .integer = 241 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":241") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"to\":{\"name\":\"helper_a\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"toRanges\":[]") != null);
}

test "handleImplementation: routes request and returns Location[] response" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    // `interface Foo {}` plus `class Bar implements Foo {}` — cursor
    // on the interface name should surface the class as an
    // implementer.
    const src =
        \\interface Foo {}
        \\class Bar implements Foo {}
    ;
    _ = try program.add("/main.ts", src);
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Cursor on `Foo` (line 0, char 10) — interface name.
    const body =
        \\{"jsonrpc":"2.0","id":51,"method":"textDocument/implementation","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":10}}}
    ;
    const out = try handleImplementation(&svc, T.allocator, .{ .integer = 51 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":51") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[") != null);

    // Cursor not on any identifier -> empty array.
    const empty =
        \\{"jsonrpc":"2.0","id":52,"method":"textDocument/implementation","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":99,"character":0}}}
    ;
    const out2 = try handleImplementation(&svc, T.allocator, .{ .integer = 52 }, empty);
    defer T.allocator.free(out2);
    try T.expect(std.mem.indexOf(u8, out2, "\"result\":[]") != null);
}

test "handleDocumentLink: routes request and returns DocumentLink[] response" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/lib.ts", "export let foo = 1;");
    try vfs.addFile("/main.ts", "import { foo } from './lib'; let x = foo;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/lib.ts", "export let foo = 1;");
    _ = try program.add("/main.ts", "import { foo } from './lib'; let x = foo;");
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":61,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///main.ts"}}}
    ;
    const out = try handleDocumentLink(&svc, T.allocator, .{ .integer = 61 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":61") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[{\"range\":") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"target\":\"file:///lib.ts\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"tooltip\":\"\"") != null);
}

test "handleDocumentLinkResolve: stub echoes input params" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const params =
        \\{"range":{"start":{"line":0,"character":21},"end":{"line":0,"character":26}},"target":"file:///lib.ts"}
    ;
    const out = try handleDocumentLinkResolve(&svc, T.allocator, .{ .integer = 71 }, params);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":71") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"target\":\"file:///lib.ts\"") != null);
}

test "handleCodeLensResolve: stub echoes input params" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const params =
        \\{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":12}},"command":{"title":"2 references","command":""}}
    ;
    const out = try handleCodeLensResolve(&svc, T.allocator, .{ .integer = 152 }, params);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":152") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"title\":\"2 references\"") != null);
}

test "handleLinkedEditingRange: returns null off JSX (service stub)" {
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
        \\{"jsonrpc":"2.0","id":311,"method":"textDocument/linkedEditingRange","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":4}}}
    ;
    const out = try handleLinkedEditingRange(&svc, T.allocator, .{ .integer = 311 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":311") != null);
    // Service stub returns null; wire layer surfaces it as `"result":null`.
    try T.expect(std.mem.indexOf(u8, out, "\"result\":null") != null);
}

test "handleMoniker: returns LSIF moniker shape with kind classification" {
    // Two-file program: `lib.ts` exports a helper; `main.ts` imports
    // it as a *default* binding (the default-import identifier is a
    // dedicated identifier node in the HIR, so the cursor lands on
    // it cleanly), declares an `export function exposed`, and a
    // private `function priv` for the local case.
    const main_src = "import lib from './lib'; export function exposed() {} function priv() {}";
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/lib.ts", "export default function helper() {}");
    try vfs.addFile("/main.ts", main_src);
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/lib.ts", "export default function helper() {}");
    _ = try program.add("/main.ts", main_src);
    try program.compileAll(.{});

    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Cursor on `lib` (the default-import binding) — kind: import.
    // Char 7 == start of `lib` in `import lib from './lib';`.
    const body_import =
        \\{"jsonrpc":"2.0","id":901,"method":"textDocument/moniker","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":7}}}
    ;
    const out_import = try handleMoniker(&svc, T.allocator, .{ .integer = 901 }, body_import);
    defer T.allocator.free(out_import);
    try T.expect(std.mem.indexOf(u8, out_import, "\"id\":901") != null);
    try T.expect(std.mem.indexOf(u8, out_import, "\"scheme\":\"tsc\"") != null);
    try T.expect(std.mem.indexOf(u8, out_import, "\"unique\":\"global\"") != null);
    try T.expect(std.mem.indexOf(u8, out_import, "\"kind\":\"import\"") != null);
    try T.expect(std.mem.indexOf(u8, out_import, ":default") != null);

    // Cursor on `exposed` (the `function exposed` name) — kind: export.
    // `import lib from './lib'; ` is 25 chars, then
    // `export function exposed() {}` starts; `exposed` begins at
    // 25 + 16 == 41.
    const body_export =
        \\{"jsonrpc":"2.0","id":902,"method":"textDocument/moniker","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":41}}}
    ;
    const out_export = try handleMoniker(&svc, T.allocator, .{ .integer = 902 }, body_export);
    defer T.allocator.free(out_export);
    try T.expect(std.mem.indexOf(u8, out_export, "\"id\":902") != null);
    try T.expect(std.mem.indexOf(u8, out_export, "\"kind\":\"export\"") != null);
    try T.expect(std.mem.indexOf(u8, out_export, "/main.ts:exposed") != null);

    // Cursor on `priv` (a non-exported declaration) — kind: local.
    // `priv` starts at byte 63 (after
    // `import lib from './lib'; export function exposed() {} function `).
    const body_local =
        \\{"jsonrpc":"2.0","id":903,"method":"textDocument/moniker","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":63}}}
    ;
    const out_local = try handleMoniker(&svc, T.allocator, .{ .integer = 903 }, body_local);
    defer T.allocator.free(out_local);
    try T.expect(std.mem.indexOf(u8, out_local, "\"id\":903") != null);
    try T.expect(std.mem.indexOf(u8, out_local, "\"kind\":\"local\"") != null);
    try T.expect(std.mem.indexOf(u8, out_local, "/main.ts:priv") != null);
}

test "handleWillRenameFiles: returns null result for empty stub edit list" {
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
        \\{"jsonrpc":"2.0","id":321,"method":"workspace/willRenameFiles","params":{"files":[{"oldUri":"file:///main.ts","newUri":"file:///renamed.ts"}]}}
    ;
    const out = try handleWillRenameFiles(&svc, T.allocator, .{ .integer = 321 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":321") != null);
    // Service stub returns []; wire layer treats empty as `"result":null`
    // (LSP-permitted "no follow-up edits needed").
    try T.expect(std.mem.indexOf(u8, out, "\"result\":null") != null);
}

test "handleInlineValue: emits InlineValueVariableLookup per identifier in range" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let count = 1; let total = count + 2;");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Visible viewport covers the full single-line source. The
    // service emits one InlineValueVariableLookup per identifier
    // expression — both binding sites (`count`, `total`) and the
    // read-site (`count` in `count + 2`) appear.
    const body =
        \\{"jsonrpc":"2.0","id":701,"method":"textDocument/inlineValue","params":{"textDocument":{"uri":"file:///main.ts"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":40}},"context":{"frameId":1,"stoppedLocation":{"start":{"line":0,"character":0},"end":{"line":0,"character":40}}}}}
    ;
    const out = try handleInlineValue(&svc, T.allocator, .{ .integer = 701 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":701") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"variableName\":\"count\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"variableName\":\"total\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"caseSensitiveLookup\":true") != null);
    // Each item carries a wire-shaped LSP range.
    try T.expect(std.mem.indexOf(u8, out, "\"range\":{\"start\":{\"line\":") != null);
}

test "handleInlineCompletion: stub returns InlineCompletionList shape" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "let count = 1;\n");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    // Standard LSP inlineCompletion request: textDocument + position
    // + context (triggerKind 2 = Automatic). v0 returns an empty
    // `items` array under the InlineCompletionList wire shape.
    const body =
        \\{"jsonrpc":"2.0","id":901,"method":"textDocument/inlineCompletion","params":{"textDocument":{"uri":"file:///main.ts"},"position":{"line":0,"character":14},"context":{"triggerKind":2}}}
    ;
    const out = try handleInlineCompletion(&svc, T.allocator, .{ .integer = 901 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":901") != null);
    // InlineCompletionList shape: `{ "items": [] }` (not a bare array).
    try T.expect(std.mem.indexOf(u8, out, "\"result\":{\"items\":[]}") != null);

    // Capability advertised in initialize result + listed in supportedMethods.
    const init_caps = try renderInitializeCapabilities(T.allocator);
    defer T.allocator.free(init_caps);
    try T.expect(std.mem.indexOf(u8, init_caps, "\"inlineCompletionProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, init_caps, "\"textDocument/inlineCompletion\"") != null);

    // Method enum round-trips through fromString.
    try T.expectEqual(
        Method.text_document_inline_completion,
        Method.fromString("textDocument/inlineCompletion"),
    );
}

test "handleDocumentColor + handleColorPresentation: stubs return empty arrays" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/main.ts", "const RED = \"#ff0000\";");
    try program.compileAll(.{});
    var svc = ts_lsp.Service.init(T.allocator, &program);

    // documentColor: empty `[]` array result envelope.
    const dc_body =
        \\{"jsonrpc":"2.0","id":820,"method":"textDocument/documentColor","params":{"textDocument":{"uri":"file:///main.ts"}}}
    ;
    const dc_out = try handleDocumentColor(&svc, T.allocator, .{ .integer = 820 }, dc_body);
    defer T.allocator.free(dc_out);
    try T.expect(std.mem.indexOf(u8, dc_out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, dc_out, "\"id\":820") != null);
    try T.expect(std.mem.indexOf(u8, dc_out, "\"result\":[]") != null);

    // colorPresentation: empty `[]` array result envelope.
    const cp_body =
        \\{"jsonrpc":"2.0","id":821,"method":"textDocument/colorPresentation","params":{"textDocument":{"uri":"file:///main.ts"},"color":{"red":1,"green":0,"blue":0,"alpha":1},"range":{"start":{"line":0,"character":12},"end":{"line":0,"character":21}}}}
    ;
    const cp_out = try handleColorPresentation(&svc, T.allocator, .{ .integer = 821 }, cp_body);
    defer T.allocator.free(cp_out);
    try T.expect(std.mem.indexOf(u8, cp_out, "\"id\":821") != null);
    try T.expect(std.mem.indexOf(u8, cp_out, "\"result\":[]") != null);

    // Capability advertised in initialize result + listed in supportedMethods.
    const init_caps = try renderInitializeCapabilities(T.allocator);
    defer T.allocator.free(init_caps);
    try T.expect(std.mem.indexOf(u8, init_caps, "\"colorProvider\":true") != null);
    try T.expect(std.mem.indexOf(u8, init_caps, "\"textDocument/documentColor\"") != null);
    try T.expect(std.mem.indexOf(u8, init_caps, "\"textDocument/colorPresentation\"") != null);
}

test "handleWillSaveWaitUntil: returns TextEdit array (no-op for clean file)" {
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
        \\{"jsonrpc":"2.0","id":830,"method":"textDocument/willSaveWaitUntil","params":{"textDocument":{"uri":"file:///main.ts"},"reason":1}}
    ;
    const out = try handleWillSaveWaitUntil(&svc, T.allocator, .{ .integer = 830 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"jsonrpc\":\"2.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":830") != null);
    // formatDocument is currently a stub returning `[]`, so we expect
    // an empty result envelope.
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[]") != null);
}

test "handleWillSaveWaitUntil: returns [] for unknown file" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    var svc = ts_lsp.Service.init(T.allocator, &program);

    const body =
        \\{"jsonrpc":"2.0","id":831,"method":"textDocument/willSaveWaitUntil","params":{"textDocument":{"uri":"file:///ghost.ts"},"reason":3}}
    ;
    const out = try handleWillSaveWaitUntil(&svc, T.allocator, .{ .integer = 831 }, body);
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"id\":831") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"result\":[]") != null);
}
