//! `.tsbuildinfo` writer — Phase 4 §4.A.12.
//!
//! `tsc --incremental` writes a `.tsbuildinfo` JSON file recording
//! the program's state so the *next* invocation can skip files
//! whose source + dependencies haven't changed. The reader accepts
//! the indexed object emitted by Home and the parallel file-info array
//! emitted by TypeScript 5.7.3 and native 7.0.2.
//!
//! Home's current writer format (simplified; #1065 tracks diagnostic and
//! pending-emit serialization):
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
//! Do not treat the writer's present output as a complete upstream build
//! state: it does not yet retain diagnostic spans or pending output.

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
    /// Home's incremental state. When present it must describe the actual
    /// diagnostics and outputs withheld by this compilation.
    state: ?BuildState = null,
};

pub const DiagnosticChain = struct {
    message: []const u8,
    code: u32,
    category: u8 = 1,
    children: []const DiagnosticChain = &.{},
};

pub const RelatedDiagnostic = struct {
    file: ?[]const u8 = null,
    start: u32,
    length: u32,
    code: u32,
    category: u8 = 3,
    message: []const u8,
};

pub const SavedDiagnostic = struct {
    start: u32,
    length: u32,
    code: u32,
    category: u8 = 1,
    message: []const u8,
    chain: []const DiagnosticChain = &.{},
    related: []const RelatedDiagnostic = &.{},
};

pub const FileDiagnostics = struct {
    /// One-based index into `fileNames`, as in both official formats.
    file_id: usize,
    diagnostics: []const SavedDiagnostic,
};

pub const BuildState = struct {
    roots: []const usize = &.{},
    semantic_diagnostics: []const FileDiagnostics = &.{},
    affected_files_pending_emit: []const usize = &.{},
    emit_signatures: []const usize = &.{},
    /// For diagnostics without a source-file owner (e.g. config errors).
    errors: bool = false,
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
    if (options.state) |state| {
        for (state.roots) |id| if (id == 0 or id > file_names.len) return error.InvalidFileInfoIndex;
        for (state.semantic_diagnostics) |file| {
            if (file.file_id == 0 or file.file_id > file_names.len) return error.InvalidFileInfoIndex;
        }
        for (state.affected_files_pending_emit) |id| if (id == 0 or id > file_names.len) return error.InvalidFileInfoIndex;
        for (state.emit_signatures) |id| if (id == 0 or id > file_names.len) return error.InvalidFileInfoIndex;
    }
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
        const line = try std.fmt.allocPrint(gpa, "  \"options\": {s}{s}\n", .{ config_options_json, if (options.state != null) "," else "" });
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
    }
    if (options.state) |state| try appendBuildState(gpa, &buf, state);
    try buf.appendSlice(gpa, "}\n");
    return buf.toOwnedSlice(gpa);
}

fn appendBuildState(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), state: BuildState) !void {
    try buf.appendSlice(gpa, "  \"root\":");
    try appendIndexArray(gpa, buf, state.roots);
    try buf.appendSlice(gpa, ",\n  \"semanticDiagnosticsPerFile\":[");
    for (state.semantic_diagnostics, 0..) |file, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.append(gpa, '[');
        try appendIndex(gpa, buf, file.file_id);
        try buf.appendSlice(gpa, ",[");
        for (file.diagnostics, 0..) |diag, j| {
            if (j > 0) try buf.append(gpa, ',');
            try appendSavedDiagnostic(gpa, buf, diag);
        }
        try buf.appendSlice(gpa, "]]");
    }
    try buf.append(gpa, ']');
    if (state.affected_files_pending_emit.len > 0) {
        try buf.appendSlice(gpa, ",\n  \"affectedFilesPendingEmit\":");
        try appendIndexArray(gpa, buf, state.affected_files_pending_emit);
    }
    if (state.emit_signatures.len > 0) {
        try buf.appendSlice(gpa, ",\n  \"emitSignatures\":");
        try appendIndexArray(gpa, buf, state.emit_signatures);
    }
    if (state.errors) try buf.appendSlice(gpa, ",\n  \"errors\":true");
    try buf.append(gpa, '\n');
}

fn appendIndexArray(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), indices: []const usize) !void {
    try buf.append(gpa, '[');
    for (indices, 0..) |index, i| {
        if (i > 0) try buf.append(gpa, ',');
        try appendIndex(gpa, buf, index);
    }
    try buf.append(gpa, ']');
}

fn appendIndex(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), index: usize) !void {
    const text = try std.fmt.allocPrint(gpa, "{d}", .{index});
    defer gpa.free(text);
    try buf.appendSlice(gpa, text);
}

fn appendSavedDiagnostic(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), diag: SavedDiagnostic) !void {
    try buf.append(gpa, '{');
    try appendDiagnosticFields(gpa, buf, diag.start, diag.length, diag.code, diag.category);
    try buf.appendSlice(gpa, ",\"messageText\":");
    if (diag.chain.len == 0) {
        try appendQuoted(gpa, buf, diag.message);
    } else {
        try appendMessageChain(gpa, buf, diag.message, diag.code, diag.category, diag.chain);
    }
    if (diag.related.len > 0) {
        try buf.appendSlice(gpa, ",\"relatedInformation\":[");
        for (diag.related, 0..) |related, i| {
            if (i > 0) try buf.append(gpa, ',');
            try buf.append(gpa, '{');
            try appendDiagnosticFields(gpa, buf, related.start, related.length, related.code, related.category);
            if (related.file) |file| {
                try buf.appendSlice(gpa, ",\"file\":");
                try appendQuoted(gpa, buf, file);
            }
            try buf.appendSlice(gpa, ",\"messageText\":");
            try appendQuoted(gpa, buf, related.message);
            try buf.append(gpa, '}');
        }
        try buf.append(gpa, ']');
    }
    try buf.append(gpa, '}');
}

fn appendMessageChain(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), message: []const u8, code: u32, category: u8, children: []const DiagnosticChain) !void {
    try buf.appendSlice(gpa, "{\"messageText\":");
    try appendQuoted(gpa, buf, message);
    try buf.appendSlice(gpa, ",\"category\":");
    try appendIndex(gpa, buf, category);
    try buf.appendSlice(gpa, ",\"code\":");
    try appendIndex(gpa, buf, code);
    if (children.len > 0) {
        try buf.appendSlice(gpa, ",\"next\":[");
        for (children, 0..) |child, i| {
            if (i > 0) try buf.append(gpa, ',');
            try appendMessageChain(gpa, buf, child.message, child.code, child.category, child.children);
        }
        try buf.append(gpa, ']');
    }
    try buf.append(gpa, '}');
}

fn appendDiagnosticFields(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), start: u32, length: u32, code: u32, category: u8) !void {
    try buf.appendSlice(gpa, "\"start\":");
    try appendIndex(gpa, buf, start);
    try buf.appendSlice(gpa, ",\"length\":");
    try appendIndex(gpa, buf, length);
    try buf.appendSlice(gpa, ",\"code\":");
    try appendIndex(gpa, buf, code);
    try buf.appendSlice(gpa, ",\"category\":");
    try appendIndex(gpa, buf, category);
}

fn appendQuoted(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try buf.append(gpa, '"');
    try appendJsonString(gpa, buf, value);
    try buf.append(gpa, '"');
}

/// JSON-escape a string (writes the body, no surrounding quotes).
fn appendJsonString(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(gpa, "\\\""),
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        '\n' => try buf.appendSlice(gpa, "\\n"),
        '\r' => try buf.appendSlice(gpa, "\\r"),
        '\t' => try buf.appendSlice(gpa, "\\t"),
        else => {
            if (c < 0x20) {
                const hex = "0123456789abcdef";
                try buf.appendSlice(gpa, "\\u00");
                try buf.append(gpa, hex[c >> 4]);
                try buf.append(gpa, hex[c & 0x0f]);
            } else {
                try buf.append(gpa, c);
            }
        },
    };
}

/// Structured representation of a `.tsbuildinfo` document. `file_names[i]`
/// corresponds to `file_infos[i]`, mirroring tsc's index-keyed `fileInfos`
/// map. The reader normalises that map back into a parallel array.
///
/// Owns its allocations — callers must invoke `deinit` to release the
/// duplicated strings and slice spines.
pub const BuildInfo = struct {
    version: []const u8,
    file_names: [][]const u8,
    file_infos: []FileInfo,
    options_json: []const u8,
    has_pending_emit: bool = false,
    has_errors: bool = false,

    pub fn deinit(self: *BuildInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.version);
        for (self.file_names) |n| gpa.free(n);
        gpa.free(self.file_names);
        for (self.file_infos) |fi| gpa.free(fi.version);
        gpa.free(self.file_infos);
        gpa.free(self.options_json);
        self.* = undefined;
    }
};

pub const ReadError = error{
    InvalidJson,
    MissingVersion,
    MissingFileNames,
    MissingFileInfos,
    InvalidFileInfoIndex,
} || std.mem.Allocator.Error;

/// Parse a `.tsbuildinfo` JSON document back into a `BuildInfo`.
///
/// Round-trips with `emit` — index-keyed `"fileInfos"` entries are
/// re-aligned with `"fileNames"` so callers consume parallel arrays.
pub fn read(gpa: std.mem.Allocator, json_bytes: []const u8) ReadError!BuildInfo {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    const version_val = root.get("version") orelse return error.MissingVersion;
    if (version_val != .string) return error.MissingVersion;

    const names_val = root.get("fileNames") orelse return error.MissingFileNames;
    if (names_val != .array) return error.MissingFileNames;

    const infos_val = root.get("fileInfos") orelse return error.MissingFileInfos;
    if (infos_val != .object and infos_val != .array) return error.MissingFileInfos;

    const names_src = names_val.array.items;
    const file_names = try gpa.alloc([]const u8, names_src.len);
    var names_filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < names_filled) : (i += 1) gpa.free(file_names[i]);
        gpa.free(file_names);
    }
    for (names_src, 0..) |item, i| {
        if (item != .string) return error.InvalidJson;
        file_names[i] = try gpa.dupe(u8, item.string);
        names_filled = i + 1;
    }

    const file_infos = try gpa.alloc(FileInfo, names_src.len);
    // `seen` tracks which slots have been written so the errdefer can
    // free only those (and the BuildInfo's deinit can free a fully
    // populated slice on success).
    const seen = try gpa.alloc(bool, file_infos.len);
    defer gpa.free(seen);
    @memset(seen, false);
    errdefer {
        for (file_infos, seen) |fi, s| if (s) gpa.free(fi.version);
        gpa.free(file_infos);
    }

    switch (infos_val) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const idx = std.fmt.parseInt(usize, entry.key_ptr.*, 10) catch
                    return error.InvalidFileInfoIndex;
                if (idx >= file_infos.len) return error.InvalidFileInfoIndex;
                const info = try readFileInfo(gpa, entry.value_ptr.*);
                // Duplicate keys: free the prior allocation so we don't leak.
                if (seen[idx]) gpa.free(file_infos[idx].version);
                file_infos[idx] = info;
                seen[idx] = true;
            }
        },
        .array => |array| {
            // Official TypeScript 5.7 and native 7 use a parallel array.
            // Their root and diagnostic indices are one-based, but the
            // fileNames/fileInfos arrays themselves share zero-based slots.
            if (array.items.len != file_infos.len) return error.InvalidFileInfoIndex;
            for (array.items, 0..) |item, idx| {
                file_infos[idx] = try readFileInfo(gpa, item);
                seen[idx] = true;
            }
        },
        else => unreachable,
    }
    for (seen) |s| if (!s) return error.InvalidFileInfoIndex;

    const version_dup = try gpa.dupe(u8, version_val.string);
    errdefer gpa.free(version_dup);

    const options_json = if (root.get("options")) |options_val|
        try stringifyJsonValue(gpa, options_val)
    else
        try gpa.dupe(u8, "{}");
    errdefer gpa.free(options_json);

    return BuildInfo{
        .version = version_dup,
        .file_names = file_names,
        .file_infos = file_infos,
        .options_json = options_json,
        .has_pending_emit = buildInfoFieldIsPresent(root, "affectedFilesPendingEmit") or
            buildInfoFieldIsPresent(root, "pendingEmit") or
            buildInfoFieldIsPresent(root, "programEmitPending"),
        .has_errors = buildInfoFieldIsTrue(root, "errors") or
            buildInfoFieldIsTrue(root, "hasErrors") or
            buildInfoFieldIsTrue(root, "checkPending") or
            hasRecordedDiagnostics(root, "semanticDiagnosticsPerFile") or
            hasRecordedDiagnostics(root, "emitDiagnosticsPerFile"),
    };
}

fn readFileInfo(gpa: std.mem.Allocator, value: std.json.Value) ReadError!FileInfo {
    // Official compilers write a bare version string when no other file-info
    // field is needed; Home's earlier writer used only object entries.
    if (value == .string) return .{ .version = try gpa.dupe(u8, value.string) };
    if (value != .object) return error.InvalidJson;
    const object = value.object;
    const version = object.get("version") orelse return error.InvalidJson;
    if (version != .string) return error.InvalidJson;
    return .{
        .version = try gpa.dupe(u8, version.string),
        .affects_global_scope = if (object.get("affectsGlobalScope")) |v| v == .bool and v.bool else false,
        .is_declaration = if (object.get("isDeclaration")) |v| v == .bool and v.bool else false,
    };
}

fn hasRecordedDiagnostics(root: std.json.ObjectMap, field: []const u8) bool {
    const value = root.get(field) orelse return false;
    if (value != .array) return false;
    for (value.array.items) |entry| {
        // A bare file index means it was checked without errors. An entry
        // [fileIndex, diagnostics] retains errors in both reference formats.
        if (entry != .array or entry.array.items.len < 2) continue;
        const diagnostics = entry.array.items[1];
        if (diagnostics != .array) continue;
        for (diagnostics.array.items) |diagnostic| {
            if (diagnostic != .object) continue;
            const category = diagnostic.object.get("category") orelse continue;
            // DiagnosticCategory.Error is 1 in both TypeScript versions.
            // Warnings and suggestions do not block an up-to-date build.
            if (category == .integer and category.integer == 1) return true;
        }
    }
    return false;
}

fn buildInfoFieldIsTrue(root: std.json.ObjectMap, name: []const u8) bool {
    const value = root.get(name) orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

fn buildInfoFieldIsPresent(root: std.json.ObjectMap, name: []const u8) bool {
    const value = root.get(name) orelse return false;
    return switch (value) {
        .null => false,
        .bool => |b| b,
        .array => |items| items.items.len > 0,
        .object => |object| object.count() > 0,
        else => true,
    };
}

fn stringifyJsonValue(gpa: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try appendJsonValue(gpa, &buf, value);
    return buf.toOwnedSlice(gpa);
}

fn appendJsonValue(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buf.appendSlice(gpa, "null"),
        .bool => |b| try buf.appendSlice(gpa, if (b) "true" else "false"),
        .integer => |n| {
            const s = try std.fmt.allocPrint(gpa, "{d}", .{n});
            defer gpa.free(s);
            try buf.appendSlice(gpa, s);
        },
        .float => |n| {
            const s = try std.fmt.allocPrint(gpa, "{d}", .{n});
            defer gpa.free(s);
            try buf.appendSlice(gpa, s);
        },
        .number_string => |s| try buf.appendSlice(gpa, s),
        .string => |s| {
            try buf.append(gpa, '"');
            try appendJsonString(gpa, buf, s);
            try buf.append(gpa, '"');
        },
        .array => |array| {
            try buf.append(gpa, '[');
            for (array.items, 0..) |item, i| {
                if (i > 0) try buf.append(gpa, ',');
                try appendJsonValue(gpa, buf, item);
            }
            try buf.append(gpa, ']');
        },
        .object => |object| {
            try buf.append(gpa, '{');
            var it = object.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.append(gpa, ',');
                first = false;
                try buf.append(gpa, '"');
                try appendJsonString(gpa, buf, entry.key_ptr.*);
                try buf.appendSlice(gpa, "\":");
                try appendJsonValue(gpa, buf, entry.value_ptr.*);
            }
            try buf.append(gpa, '}');
        },
    }
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

test "tsbuildinfo: round-trip emit then read preserves fields" {
    const file_names = [_][]const u8{ "lib.es2024.d.ts", "src/main.ts", "src/util.ts" };
    const file_infos = [_]FileInfo{
        .{ .version = "lib-hash", .affects_global_scope = true, .is_declaration = true },
        .{ .version = "main-hash" },
        .{ .version = "util-hash", .is_declaration = true },
    };
    const out = try emit(T.allocator, &file_names, &file_infos, "{\"strict\": true}", .{});
    defer T.allocator.free(out);

    var info = try read(T.allocator, out);
    defer info.deinit(T.allocator);

    try T.expectEqualStrings("5.6.0", info.version);
    try T.expectEqual(@as(usize, 3), info.file_names.len);
    try T.expectEqualStrings("lib.es2024.d.ts", info.file_names[0]);
    try T.expectEqualStrings("src/main.ts", info.file_names[1]);
    try T.expectEqualStrings("src/util.ts", info.file_names[2]);

    try T.expectEqual(@as(usize, 3), info.file_infos.len);
    try T.expectEqualStrings("lib-hash", info.file_infos[0].version);
    try T.expectEqual(true, info.file_infos[0].affects_global_scope);
    try T.expectEqual(true, info.file_infos[0].is_declaration);

    try T.expectEqualStrings("main-hash", info.file_infos[1].version);
    try T.expectEqual(false, info.file_infos[1].affects_global_scope);
    try T.expectEqual(false, info.file_infos[1].is_declaration);

    try T.expectEqualStrings("util-hash", info.file_infos[2].version);
    try T.expectEqual(false, info.file_infos[2].affects_global_scope);
    try T.expectEqual(true, info.file_infos[2].is_declaration);
    try T.expectEqualStrings("{\"strict\":true}", info.options_json);
    try T.expectEqual(false, info.has_pending_emit);
    try T.expectEqual(false, info.has_errors);
}

test "tsbuildinfo: round-trip on empty inputs is a no-op" {
    const out = try emit(T.allocator, &.{}, &.{}, "{}", .{});
    defer T.allocator.free(out);
    var info = try read(T.allocator, out);
    defer info.deinit(T.allocator);
    try T.expectEqualStrings("5.6.0", info.version);
    try T.expectEqual(@as(usize, 0), info.file_names.len);
    try T.expectEqual(@as(usize, 0), info.file_infos.len);
}

test "tsbuildinfo: read parses a hand-written minimal document" {
    const json =
        \\{
        \\  "version": "5.4.2",
        \\  "fileNames": ["a.ts", "b.ts"],
        \\  "fileInfos": {
        \\    "0": { "version": "h0" },
        \\    "1": { "version": "h1", "affectsGlobalScope": true }
        \\  },
        \\  "options": { "target": 7 },
        \\  "affectedFilesPendingEmit": [0],
        \\  "errors": true
        \\}
    ;
    var info = try read(T.allocator, json);
    defer info.deinit(T.allocator);

    try T.expectEqualStrings("5.4.2", info.version);
    try T.expectEqual(@as(usize, 2), info.file_names.len);
    try T.expectEqualStrings("a.ts", info.file_names[0]);
    try T.expectEqualStrings("b.ts", info.file_names[1]);
    try T.expectEqualStrings("h0", info.file_infos[0].version);
    try T.expectEqual(false, info.file_infos[0].affects_global_scope);
    try T.expectEqualStrings("h1", info.file_infos[1].version);
    try T.expectEqual(true, info.file_infos[1].affects_global_scope);
    try T.expectEqualStrings("{\"target\":7}", info.options_json);
    try T.expectEqual(true, info.has_pending_emit);
    try T.expectEqual(true, info.has_errors);
}

test "tsbuildinfo: read official 5.7 and native 7 pending diagnostic state" {
    // Reduced from the actual composite/noEmitOnError outputs for TS2322.
    // Both compilers use one-based indices in root and diagnostic records.
    const reference_documents = [_][]const u8{
        \\{"version":"5.7.3","fileNames":["./lib.d.ts","./main.ts"],"fileInfos":[{"version":"lib","affectsGlobalScope":true},"main"],"root":[2],"options":{},"semanticDiagnosticsPerFile":[1,[2,[{"start":13,"length":1,"code":2322,"category":1,"messageText":"Type 'string' is not assignable to type 'number'."}]]],"affectedFilesPendingEmit":[2],"emitSignatures":[2]}
        ,
        \\{"version":"7.0.2","fileNames":["./lib.d.ts","./main.ts"],"fileInfos":[{"version":"lib","affectsGlobalScope":true,"impliedNodeFormat":1},"main"],"root":[2],"options":{},"semanticDiagnosticsPerFile":[1,[2,[{"pos":13,"end":14,"code":2322,"category":1,"messageKey":"Type_0_is_not_assignable_to_type_1_2322","messageArgs":["string","number"]}]]],"affectedFilesPendingEmit":[2],"emitSignatures":[2]}
    };
    for (reference_documents) |json| {
        var info = try read(T.allocator, json);
        defer info.deinit(T.allocator);
        try T.expectEqual(@as(usize, 2), info.file_infos.len);
        try T.expectEqualStrings("lib", info.file_infos[0].version);
        try T.expect(info.file_infos[0].affects_global_scope);
        try T.expectEqualStrings("main", info.file_infos[1].version);
        try T.expect(info.has_errors);
        try T.expect(info.has_pending_emit);
    }
}

test "tsbuildinfo: checked files without diagnostics remain clean" {
    const json =
        \\{"version":"5.7.3","fileNames":["main.ts"],"fileInfos":["version"],"root":[1],"options":{},"semanticDiagnosticsPerFile":[1]}
    ;
    var info = try read(T.allocator, json);
    defer info.deinit(T.allocator);
    try T.expect(!info.has_errors);
    try T.expect(!info.has_pending_emit);
}

test "tsbuildinfo: retained warnings do not mark a build as errored" {
    const json =
        \\{"version":"5.7.3","fileNames":["main.ts"],"fileInfos":["version"],"options":{},"semanticDiagnosticsPerFile":[[1,[{"start":0,"length":1,"code":9000,"category":0,"messageText":"warning"}]]]}
    ;
    var info = try read(T.allocator, json);
    defer info.deinit(T.allocator);
    try T.expect(!info.has_errors);
}

test "tsbuildinfo: retained declaration emit diagnostics require another build" {
    const json =
        \\{"version":"5.7.3","fileNames":["main.ts"],"fileInfos":["version"],"options":{},"emitDiagnosticsPerFile":[[1,[{"start":0,"length":1,"code":4025,"category":1,"messageText":"Exported variable has or is using private name."}]]]}
    ;
    var info = try read(T.allocator, json);
    defer info.deinit(T.allocator);
    try T.expect(info.has_errors);
}

test "tsbuildinfo: parallel file-info length must match file names" {
    const json =
        \\{"version":"5.7.3","fileNames":["main.ts"],"fileInfos":[],"options":{}}
    ;
    try T.expectError(error.InvalidFileInfoIndex, read(T.allocator, json));
}

test "tsbuildinfo: writes retained diagnostics and pending emit without dropping chains" {
    const chain = [_]DiagnosticChain{.{
        .message = "'T[\"value\"]' could be instantiated with an arbitrary type.",
        .code = 5082,
    }};
    const related = [_]RelatedDiagnostic{.{
        .start = 2,
        .length = 4,
        .code = 1377,
        .message = "Declared here.",
    }};
    const diagnostics = [_]SavedDiagnostic{.{
        .start = 90,
        .length = 6,
        .code = 2322,
        .message = "Type 'string' is not assignable to type 'T[\"value\"]'.",
        .chain = &chain,
        .related = &related,
    }};
    const per_file = [_]FileDiagnostics{.{ .file_id = 1, .diagnostics = &diagnostics }};
    const out = try emit(T.allocator, &.{"./main.ts"}, &.{.{ .version = "source-hash" }}, "{\"strict\":true}", .{
        .state = .{
            .roots = &.{1},
            .semantic_diagnostics = &per_file,
            .affected_files_pending_emit = &.{1},
            .emit_signatures = &.{1},
        },
    });
    defer T.allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, T.allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const saved = root.get("semanticDiagnosticsPerFile").?.array.items[0].array.items[1].array.items[0].object;
    try T.expectEqual(@as(i64, 90), saved.get("start").?.integer);
    try T.expectEqual(@as(i64, 6), saved.get("length").?.integer);
    try T.expectEqual(@as(i64, 2322), saved.get("code").?.integer);
    const message = saved.get("messageText").?.object;
    try T.expectEqualStrings("Type 'string' is not assignable to type 'T[\"value\"]'.", message.get("messageText").?.string);
    try T.expectEqualStrings("'T[\"value\"]' could be instantiated with an arbitrary type.", message.get("next").?.array.items[0].object.get("messageText").?.string);
    try T.expectEqualStrings("Declared here.", saved.get("relatedInformation").?.array.items[0].object.get("messageText").?.string);
    try T.expectEqual(@as(i64, 1), root.get("affectedFilesPendingEmit").?.array.items[0].integer);
    try T.expectEqual(@as(i64, 1), root.get("emitSignatures").?.array.items[0].integer);

    var read_back = try read(T.allocator, out);
    defer read_back.deinit(T.allocator);
    try T.expect(read_back.has_errors);
    try T.expect(read_back.has_pending_emit);
}

test "tsbuildinfo: rejects state indices outside fileNames" {
    const names = [_][]const u8{"main.ts"};
    const infos = [_]FileInfo{.{ .version = "hash" }};
    try T.expectError(error.InvalidFileInfoIndex, emit(T.allocator, &names, &infos, "{}", .{
        .state = .{ .affected_files_pending_emit = &.{2} },
    }));
}

test "tsbuildinfo: escapes control bytes in retained messages" {
    const diagnostics = [_]SavedDiagnostic{.{
        .start = 0,
        .length = 1,
        .code = 2322,
        .message = "bad\x00value",
    }};
    const files = [_]FileDiagnostics{.{ .file_id = 1, .diagnostics = &diagnostics }};
    const out = try emit(T.allocator, &.{"main.ts"}, &.{.{ .version = "hash" }}, "{}", .{
        .state = .{ .semantic_diagnostics = &files },
    });
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "bad\\u0000value") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, T.allocator, out, .{});
    defer parsed.deinit();
    const saved = parsed.value.object.get("semanticDiagnosticsPerFile").?.array.items[0].array.items[1].array.items[0].object;
    try T.expectEqualStrings("bad\x00value", saved.get("messageText").?.string);
}
