//! `.tsbuildinfo` writer — Phase 4 §4.A.12.
//!
//! `tsc --incremental` writes a `.tsbuildinfo` JSON file recording
//! the program's state so the *next* invocation can skip files
//! whose source + dependencies haven't changed. The format is a
//! ratified contract; downstream tools (Webpack's ts-loader,
//! Bazel's ts_project, etc.) parse it.
//!
//! tsc 5.x format (simplified — full schema includes affected-files
//! tracking, semantic diagnostics, etc., which we add as we need
//! them):
//!
//! ```json
//! {
//!   "version": "5.6.0",
//!   "fileNames": ["lib.es2024.d.ts", "src/main.ts", ...],
//!   "fileInfos": {
//!     "0": { "version": "<sha-of-lib>", "affectsGlobalScope": true, ... }
//!   },
//!   "options": { "strict": true, "target": 7, ... }
//! }
//! ```
//!
//! We emit a deterministic, byte-stable version so round-tripping
//! through tsc's reader works out-of-the-box.

const std = @import("std");

pub const FileInfo = struct {
    /// Hash of the source file's content (typically SHA-1, hex).
    version: []const u8,
    /// True for `lib.*.d.ts` and other globally-augmenting files.
    affects_global_scope: bool = false,
    /// True for `.d.ts` files imported as a type-only declaration.
    is_declaration: bool = false,
};

pub const Options = struct {
    /// Compiler version string written into the output. Should
    /// match the tsc version we're targeting (5.x compatible).
    compiler_version: []const u8 = "5.6.0",
};

/// Emit a `.tsbuildinfo`-shaped JSON document. Caller owns the
/// returned slice. `file_names` is in declaration order; `file_infos`
/// is keyed by index-as-string, matching tsc's emitter.
pub fn emit(
    gpa: std.mem.Allocator,
    file_names: []const []const u8,
    file_infos: []const FileInfo,
    config_options_json: []const u8,
    options: Options,
) ![]u8 {
    std.debug.assert(file_names.len == file_infos.len);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n");
    {
        const line = try std.fmt.allocPrint(gpa, "  \"version\": \"{s}\",\n", .{options.compiler_version});
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
    }
    try buf.appendSlice(gpa, "  \"fileNames\": [");
    for (file_names, 0..) |name, i| {
        if (i > 0) try buf.appendSlice(gpa, ", ");
        try buf.append(gpa, '"');
        try appendJsonString(gpa, &buf, name);
        try buf.append(gpa, '"');
    }
    try buf.appendSlice(gpa, "],\n");
    try buf.appendSlice(gpa, "  \"fileInfos\": {");
    for (file_infos, 0..) |fi, i| {
        if (i > 0) try buf.appendSlice(gpa, ", ");
        const idx_str = try std.fmt.allocPrint(gpa, "\"{d}\": {{ ", .{i});
        defer gpa.free(idx_str);
        try buf.appendSlice(gpa, idx_str);
        try buf.appendSlice(gpa, "\"version\": \"");
        try appendJsonString(gpa, &buf, fi.version);
        try buf.appendSlice(gpa, "\"");
        if (fi.affects_global_scope) try buf.appendSlice(gpa, ", \"affectsGlobalScope\": true");
        if (fi.is_declaration) try buf.appendSlice(gpa, ", \"isDeclaration\": true");
        try buf.appendSlice(gpa, " }");
    }
    try buf.appendSlice(gpa, "},\n");
    {
        const line = try std.fmt.allocPrint(gpa, "  \"options\": {s}\n", .{config_options_json});
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
    }
    try buf.appendSlice(gpa, "}\n");
    return buf.toOwnedSlice(gpa);
}

/// JSON-escape a string (writes the body, no surrounding quotes).
fn appendJsonString(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(gpa, "\\\""),
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        '\n' => try buf.appendSlice(gpa, "\\n"),
        '\r' => try buf.appendSlice(gpa, "\\r"),
        '\t' => try buf.appendSlice(gpa, "\\t"),
        else => try buf.append(gpa, c),
    };
}

const T = std.testing;

test "tsbuildinfo: emits the basic shape" {
    const file_names = [_][]const u8{ "lib.es2024.d.ts", "src/main.ts" };
    const file_infos = [_]FileInfo{
        .{ .version = "abc123", .affects_global_scope = true, .is_declaration = true },
        .{ .version = "def456" },
    };
    const out = try emit(T.allocator, &file_names, &file_infos, "{\"strict\": true}", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"version\": \"5.6.0\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "lib.es2024.d.ts") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"affectsGlobalScope\": true") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"isDeclaration\": true") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"strict\": true") != null);
}

test "tsbuildinfo: empty inputs produce well-formed JSON" {
    const out = try emit(T.allocator, &.{}, &.{}, "{}", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"fileNames\": []") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"fileInfos\": {}") != null);
}

test "tsbuildinfo: escapes special characters in paths" {
    const file_names = [_][]const u8{"path\\with\"quote"};
    const file_infos = [_]FileInfo{.{ .version = "v1" }};
    const out = try emit(T.allocator, &file_names, &file_infos, "{}", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\\\\") != null);
    try T.expect(std.mem.indexOf(u8, out, "\\\"") != null);
}
