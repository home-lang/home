//! `home lsp` binary entry point.
//!
//! Wraps `ts_lsp_server`'s wire-protocol layer with a stdin/stdout
//! frame loop. Reads Content-Length-framed JSON-RPC requests off
//! stdin, dispatches via the `Method` enum, and writes encoded
//! responses to stdout. Editor integrations (VS Code, JetBrains,
//! neovim's nvim-lspconfig) speak this protocol over stdio.
//!
//! v0 ships a minimal dispatcher: initialize / shutdown / exit are
//! enough to handshake with most editors. textDocument/* requests
//! return placeholder results until the binary wires the
//! `ts_program.Program` + `ts_lsp.Service`.

const std = @import("std");
const ts_lsp_server = @import("ts_lsp_server");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    // Buffered read loop: accumulate bytes until parseFrame returns
    // a complete request, dispatch, write the response.
    var inbuf: std.ArrayListUnmanaged(u8) = .empty;
    defer inbuf.deinit(gpa);

    var read_chunk: [4096]u8 = undefined;
    while (true) {
        var bufs = [_][]u8{&read_chunk};
        const n = stdin.readStreaming(io, &bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try inbuf.appendSlice(gpa, read_chunk[0..n]);

        // Drain as many complete frames as we can.
        while (true) {
            const frame = ts_lsp_server.parseFrame(inbuf.items) orelse break;
            const body = try gpa.dupe(u8, frame.body);
            defer gpa.free(body);
            // Shift consumed bytes off the front.
            const remaining = inbuf.items[frame.consumed..];
            std.mem.copyForwards(u8, inbuf.items[0..remaining.len], remaining);
            inbuf.shrinkRetainingCapacity(remaining.len);

            try handleMessage(gpa, io, stdout, body);
        }
    }
}

fn handleMessage(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    body: []const u8,
) !void {
    // Minimal JSON parser: extract `"method": "..."` and `"id": N`.
    // The wire-protocol library is tested independently; this loop's
    // job is just to route to it.
    const method_name = extractJsonString(body, "method") orelse "unknown";
    const method = ts_lsp_server.Method.fromString(method_name);
    const id = extractJsonId(body);

    const response: ?[]u8 = switch (method) {
        .initialize => try ts_lsp_server.renderInitializeResult(gpa),
        .shutdown => try gpa.dupe(u8, "null"),
        .exit => null, // notification, no response
        .text_document_hover => try gpa.dupe(u8, "null"),
        .text_document_definition => try gpa.dupe(u8, "null"),
        .text_document_references => try gpa.dupe(u8, "[]"),
        .text_document_completion => try gpa.dupe(u8, "[]"),
        else => null,
    };
    if (response) |r| {
        defer gpa.free(r);
        const frame_body = try ts_lsp_server.encodeResponse(gpa, id, r);
        defer gpa.free(frame_body);
        const wire = try ts_lsp_server.encodeFrame(gpa, frame_body);
        defer gpa.free(wire);
        try stdout.writeStreamingAll(io, wire);
    }
    if (method == .exit) std.process.exit(0);
}

fn extractJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    // Naive scanner: find `"<key>"` followed by `:`, then a quoted
    // string. Adequate for routing; the wire layer parses fully.
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] != '"') {
            i += 1;
            continue;
        }
        const key_start = i + 1;
        const key_end = std.mem.indexOfScalarPos(u8, body, key_start, '"') orelse return null;
        if (std.mem.eql(u8, body[key_start..key_end], key)) {
            // Skip whitespace + ':' + whitespace.
            var j = key_end + 1;
            while (j < body.len and (body[j] == ' ' or body[j] == ':' or body[j] == '\t')) j += 1;
            if (j >= body.len or body[j] != '"') return null;
            const val_start = j + 1;
            const val_end = std.mem.indexOfScalarPos(u8, body, val_start, '"') orelse return null;
            return body[val_start..val_end];
        }
        i = key_end + 1;
    }
    return null;
}

fn extractJsonId(body: []const u8) ts_lsp_server.RequestId {
    // Look for "id": <number-or-string>.
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] == '"' and i + 4 < body.len and std.mem.eql(u8, body[i + 1 .. i + 3], "id") and body[i + 3] == '"') {
            var j = i + 4;
            while (j < body.len and (body[j] == ' ' or body[j] == ':' or body[j] == '\t')) j += 1;
            if (j >= body.len) break;
            if (body[j] == '"') {
                const val_start = j + 1;
                const val_end = std.mem.indexOfScalarPos(u8, body, val_start, '"') orelse break;
                return .{ .string = body[val_start..val_end] };
            } else {
                // Numeric id.
                var k = j;
                while (k < body.len and (body[k] >= '0' and body[k] <= '9')) k += 1;
                const num = std.fmt.parseInt(i64, body[j..k], 10) catch break;
                return .{ .integer = num };
            }
        }
        i += 1;
    }
    return .{ .integer = 0 };
}
