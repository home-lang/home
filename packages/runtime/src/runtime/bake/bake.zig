// Copied/adapted from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original subtree: src/runtime/bake/
// See LICENSE.bun.md for full license text.
//
// This is the Home lifetime-only Bake nucleus. It intentionally does not
// expose the bundler, watcher, HTML route, uWS, or JSC-facing DevServer
// surface yet; it carries the deinit/HMR ownership invariants needed before
// wiring Bun.serve({ routes: html }) into Home.

const DevServerModule = @import("DevServer.zig");
const std = @import("std");

pub const DevServer = DevServerModule.DevServer;
pub const resetDevServerDeinitCountForTesting = DevServerModule.resetDeinitCountForTesting;
pub const getDevServerDeinitCountForTesting = DevServerModule.getDeinitCountForTesting;
pub const HmrSocket = @import("DevServer/HmrSocket.zig").HmrSocket;
pub const RouteBundle = @import("DevServer/RouteBundle.zig").RouteBundle;
pub const SourceMapStore = @import("DevServer/SourceMapStore.zig").SourceMapStore;

pub const Mode = enum {
    development,
    production_dynamic,
    production_static,
};

pub const Side = enum {
    client,
    server,
};

pub const DefineMap = struct {
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(this: *DefineMap, allocator: std.mem.Allocator) void {
        for (this.entries.keys()) |key| allocator.free(key);
        for (this.entries.values()) |value| allocator.free(value);
        this.entries.deinit(allocator);
        this.* = .{};
    }

    pub fn putCopy(this: *DefineMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        if (this.entries.getIndex(key)) |index| {
            const copied_value = try allocator.dupe(u8, value);
            allocator.free(this.entries.values()[index]);
            this.entries.values()[index] = copied_value;
            return;
        }

        const copied_key = try allocator.dupe(u8, key);
        errdefer allocator.free(copied_key);
        const copied_value = try allocator.dupe(u8, value);
        errdefer allocator.free(copied_value);
        try this.entries.put(allocator, copied_key, copied_value);
    }

    pub fn get(this: *const DefineMap, key: []const u8) ?[]const u8 {
        return this.entries.get(key);
    }

    pub fn count(this: *const DefineMap) usize {
        return this.entries.count();
    }
};

pub const BuildConfigSubset = struct {
    define: DefineMap = .{},

    pub fn deinit(this: *BuildConfigSubset, allocator: std.mem.Allocator) void {
        this.define.deinit(allocator);
    }
};

pub const SplitBundlerOptions = struct {
    client: BuildConfigSubset = .{},
    server: BuildConfigSubset = .{},
    ssr: BuildConfigSubset = .{},

    pub fn deinit(this: *SplitBundlerOptions, allocator: std.mem.Allocator) void {
        this.client.deinit(allocator);
        this.server.deinit(allocator);
        this.ssr.deinit(allocator);
    }
};

pub const UserOptions = struct {
    bundler_options: SplitBundlerOptions = .{},

    pub fn deinit(this: *UserOptions, allocator: std.mem.Allocator) void {
        this.bundler_options.deinit(allocator);
    }

    pub fn applyServeStaticOptions(this: *UserOptions, allocator: std.mem.Allocator, serve_static: *const ServeStaticOptions) !void {
        try serve_static.applyToBundlerOptions(allocator, &this.bundler_options);
    }
};

pub const ServeStaticOptions = struct {
    define: DefineMap = .{},

    pub fn deinit(this: *ServeStaticOptions, allocator: std.mem.Allocator) void {
        this.define.deinit(allocator);
    }

    pub fn putDefineCopy(this: *ServeStaticOptions, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try this.define.putCopy(allocator, key, value);
    }

    pub fn applyToBundlerOptions(this: *const ServeStaticOptions, allocator: std.mem.Allocator, bundler_options: *SplitBundlerOptions) !void {
        for (this.define.entries.keys(), this.define.entries.values()) |key, value| {
            try bundler_options.client.define.putCopy(allocator, key, value);
            try bundler_options.server.define.putCopy(allocator, key, value);
            try bundler_options.ssr.define.putCopy(allocator, key, value);
        }
    }
};

pub fn parseServeStaticDefineFromBunfig(allocator: std.mem.Allocator, bunfig: []const u8, define: *DefineMap) !void {
    const section = findTomlSection(bunfig, "serve.static") orelse return;
    const define_body = findInlineTableValue(section, "define") orelse return;
    try parseDefineInlineTable(allocator, define_body, define);
}

fn findTomlSection(toml: []const u8, name: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    var section_start: ?usize = null;
    while (line_start <= toml.len) {
        const line_end = std.mem.indexOfScalarPos(u8, toml, line_start, '\n') orelse toml.len;
        const raw_line = toml[line_start..line_end];
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len >= 2 and line[0] == '[') {
            if (section_start) |start| return toml[start..line_start];
            if (line.len == name.len + 2 and line[line.len - 1] == ']' and std.mem.eql(u8, line[1 .. line.len - 1], name)) {
                section_start = if (line_end < toml.len) line_end + 1 else line_end;
            }
        }
        if (line_end == toml.len) break;
        line_start = line_end + 1;
    }

    if (section_start) |start| return toml[start..toml.len];
    return null;
}

fn findInlineTableValue(section: []const u8, key_name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, section, cursor, key_name)) |key_start| {
        const key_end = key_start + key_name.len;
        if ((key_start == 0 or !isTomlBareKeyChar(section[key_start - 1])) and
            (key_end == section.len or !isTomlBareKeyChar(section[key_end])))
        {
            var after_key = key_end;
            while (after_key < section.len and std.ascii.isWhitespace(section[after_key])) after_key += 1;
            if (after_key < section.len and section[after_key] == '=') {
                after_key += 1;
                while (after_key < section.len and std.ascii.isWhitespace(section[after_key])) after_key += 1;
                if (after_key < section.len and section[after_key] == '{') {
                    return tableBody(section, after_key);
                }
            }
        }
        cursor = key_end;
    }
    return null;
}

fn tableBody(section: []const u8, open_brace: usize) ?[]const u8 {
    var i = open_brace + 1;
    var in_string = false;
    var escaped = false;
    while (i < section.len) : (i += 1) {
        const ch = section[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        if (ch == '"') {
            in_string = true;
        } else if (ch == '}') {
            return section[open_brace + 1 .. i];
        }
    }
    return null;
}

fn parseDefineInlineTable(allocator: std.mem.Allocator, body: []const u8, define: *DefineMap) !void {
    var cursor: usize = 0;
    while (cursor < body.len) {
        skipTomlSeparators(body, &cursor);
        if (cursor >= body.len) break;

        const key = try parseTomlKey(body, &cursor);
        skipTomlWhitespace(body, &cursor);
        if (cursor >= body.len or body[cursor] != '=') return error.InvalidServeStaticDefine;
        cursor += 1;
        skipTomlWhitespace(body, &cursor);

        const value = try parseTomlBasicString(allocator, body, &cursor);
        defer allocator.free(value);
        try define.putCopy(allocator, key, value);

        skipTomlWhitespace(body, &cursor);
        if (cursor < body.len and body[cursor] == ',') cursor += 1;
    }
}

fn parseTomlKey(body: []const u8, cursor: *usize) ![]const u8 {
    if (cursor.* >= body.len) return error.InvalidServeStaticDefine;
    if (body[cursor.*] == '"') {
        const start = cursor.* + 1;
        const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return error.InvalidServeStaticDefine;
        cursor.* = end + 1;
        return body[start..end];
    }

    const start = cursor.*;
    while (cursor.* < body.len and isTomlBareKeyChar(body[cursor.*])) cursor.* += 1;
    if (start == cursor.*) return error.InvalidServeStaticDefine;
    return body[start..cursor.*];
}

fn parseTomlBasicString(allocator: std.mem.Allocator, body: []const u8, cursor: *usize) ![]u8 {
    if (cursor.* >= body.len or body[cursor.*] != '"') return error.InvalidServeStaticDefine;
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(allocator);

    cursor.* += 1;
    while (cursor.* < body.len) : (cursor.* += 1) {
        const ch = body[cursor.*];
        if (ch == '"') {
            cursor.* += 1;
            return try value.toOwnedSlice(allocator);
        }
        if (ch == '\\') {
            cursor.* += 1;
            if (cursor.* >= body.len) return error.InvalidServeStaticDefine;
            try value.append(allocator, switch (body[cursor.*]) {
                'b' => 0x08,
                't' => '\t',
                'n' => '\n',
                'f' => 0x0c,
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                else => body[cursor.*],
            });
        } else {
            try value.append(allocator, ch);
        }
    }
    return error.InvalidServeStaticDefine;
}

fn skipTomlSeparators(body: []const u8, cursor: *usize) void {
    while (cursor.* < body.len and (std.ascii.isWhitespace(body[cursor.*]) or body[cursor.*] == ',')) cursor.* += 1;
}

fn skipTomlWhitespace(body: []const u8, cursor: *usize) void {
    while (cursor.* < body.len and std.ascii.isWhitespace(body[cursor.*])) cursor.* += 1;
}

fn isTomlBareKeyChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
}

pub fn addImportMetaDefineStrings(allocator: std.mem.Allocator, define: *DefineMap, mode: Mode, side: Side) !void {
    try define.putCopy(allocator, "import.meta.env.DEV", if (mode == .development) "true" else "false");
    try define.putCopy(allocator, "import.meta.env.PROD", if (mode == .development) "false" else "true");
    try define.putCopy(allocator, "import.meta.env.MODE", switch (mode) {
        .development => "\"development\"",
        .production_dynamic, .production_static => "\"production\"",
    });
    try define.putCopy(allocator, "import.meta.env.SSR", if (side == .server) "true" else "false");
    try define.putCopy(allocator, "import.meta.env.STATIC", if (mode == .production_static) "true" else "false");
}

test "Bake serve static define copies to all bundler graphs" {
    var serve: ServeStaticOptions = .{};
    defer serve.deinit(std.testing.allocator);

    try serve.putDefineCopy(std.testing.allocator, "DEFINE", "\"HELLO\"");
    try serve.putDefineCopy(std.testing.allocator, "process.env.FEATURE", "\"enabled\"");

    var bundler_options: SplitBundlerOptions = .{};
    defer bundler_options.deinit(std.testing.allocator);

    try serve.applyToBundlerOptions(std.testing.allocator, &bundler_options);

    try std.testing.expectEqualStrings("\"HELLO\"", bundler_options.client.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", bundler_options.server.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", bundler_options.ssr.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"enabled\"", bundler_options.client.define.get("process.env.FEATURE").?);
}

test "Bake UserOptions applies serve static define maps" {
    var serve: ServeStaticOptions = .{};
    defer serve.deinit(std.testing.allocator);
    try serve.putDefineCopy(std.testing.allocator, "DEFINE", "\"HELLO\"");

    var user_options: UserOptions = .{};
    defer user_options.deinit(std.testing.allocator);
    try user_options.applyServeStaticOptions(std.testing.allocator, &serve);

    try std.testing.expectEqualStrings("\"HELLO\"", user_options.bundler_options.client.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", user_options.bundler_options.server.define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"HELLO\"", user_options.bundler_options.ssr.define.get("DEFINE").?);
}

test "Bake serve static define replacement preserves latest value" {
    var serve: ServeStaticOptions = .{};
    defer serve.deinit(std.testing.allocator);

    try serve.putDefineCopy(std.testing.allocator, "DEFINE", "\"OLD\"");
    try serve.putDefineCopy(std.testing.allocator, "DEFINE", "\"HELLO\"");

    try std.testing.expectEqual(@as(usize, 1), serve.define.count());
    try std.testing.expectEqualStrings("\"HELLO\"", serve.define.get("DEFINE").?);
}

test "Bake parses serve.static define from bunfig" {
    var define: DefineMap = .{};
    defer define.deinit(std.testing.allocator);

    try parseServeStaticDefineFromBunfig(
        std.testing.allocator,
        \\
        \\[serve.static]
        \\define = {
        \\  "DEFINE" = "\"HELLO\"",
        \\  "process.env.FEATURE" = "\"enabled\""
        \\}
        \\
    ,
        &define,
    );

    try std.testing.expectEqual(@as(usize, 2), define.count());
    try std.testing.expectEqualStrings("\"HELLO\"", define.get("DEFINE").?);
    try std.testing.expectEqualStrings("\"enabled\"", define.get("process.env.FEATURE").?);
}

test "Bake bunfig define parser ignores other sections" {
    var define: DefineMap = .{};
    defer define.deinit(std.testing.allocator);

    try parseServeStaticDefineFromBunfig(
        std.testing.allocator,
        \\
        \\[build]
        \\define = {
        \\  "DEFINE" = "\"WRONG\""
        \\}
        \\
        \\[serve.static]
        \\define = {
        \\  "DEFINE" = "\"HELLO\""
        \\}
        \\
        \\[serve]
        \\define = {
        \\  "OTHER" = "\"ignored\""
        \\}
        \\
    ,
        &define,
    );

    try std.testing.expectEqual(@as(usize, 1), define.count());
    try std.testing.expectEqualStrings("\"HELLO\"", define.get("DEFINE").?);
    try std.testing.expect(define.get("OTHER") == null);
}

test "Bake import.meta define strings match Bun mode and side flags" {
    var define: DefineMap = .{};
    defer define.deinit(std.testing.allocator);

    try addImportMetaDefineStrings(std.testing.allocator, &define, .production_static, .server);

    try std.testing.expectEqualStrings("false", define.get("import.meta.env.DEV").?);
    try std.testing.expectEqualStrings("true", define.get("import.meta.env.PROD").?);
    try std.testing.expectEqualStrings("\"production\"", define.get("import.meta.env.MODE").?);
    try std.testing.expectEqualStrings("true", define.get("import.meta.env.SSR").?);
    try std.testing.expectEqualStrings("true", define.get("import.meta.env.STATIC").?);
}
