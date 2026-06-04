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
    if (infos_val != .object) return error.MissingFileInfos;

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

    var it = infos_val.object.iterator();
    while (it.next()) |entry| {
        const idx = std.fmt.parseInt(usize, entry.key_ptr.*, 10) catch
            return error.InvalidFileInfoIndex;
        if (idx >= file_infos.len) return error.InvalidFileInfoIndex;
        if (entry.value_ptr.* != .object) return error.InvalidJson;
        const fi_obj = entry.value_ptr.*.object;

        const ver_val = fi_obj.get("version") orelse return error.InvalidJson;
        if (ver_val != .string) return error.InvalidJson;
        const ver_dup = try gpa.dupe(u8, ver_val.string);

        var affects_global = false;
        if (fi_obj.get("affectsGlobalScope")) |v| {
            if (v == .bool) affects_global = v.bool;
        }
        var is_decl = false;
        if (fi_obj.get("isDeclaration")) |v| {
            if (v == .bool) is_decl = v.bool;
        }

        // Duplicate keys: free the prior allocation so we don't leak.
        if (seen[idx]) gpa.free(file_infos[idx].version);
        file_infos[idx] = .{
            .version = ver_dup,
            .affects_global_scope = affects_global,
            .is_declaration = is_decl,
        };
        seen[idx] = true;
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
            buildInfoFieldIsTrue(root, "checkPending"),
    };
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
