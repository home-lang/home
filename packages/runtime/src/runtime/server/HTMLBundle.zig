// Copied/adapted from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: src/runtime/server/HTMLBundle.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6.
// See ../../cli/LICENSE.bun.md for full license text.
//
//! Pure-data HTMLBundle substrate for `Bun.serve({ static: { "/*": html } })`.
//! Bun's full HTMLBundle owns a JSC object, refcounted server routes, pending
//! uWS responses, plugin resolution, and BundleV2 completion tasks. Home keeps
//! the faithful static-route inputs first: an imported HTML path, parsed
//! script/style references, and the `[serve.static].define` replacement pass
//! that feeds the client graph for the first Bake `dev-and-prod` case.

const std = @import("std");
const bake = @import("../bake/bake.zig");
const jsc = @import("home").jsc;

pub const HTMLBundle = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    ref_count: usize = 1,

    pub const Route = @import("HTMLBundle.zig").Route;
    pub const HTMLBundleRoute = @import("HTMLBundle.zig").Route;

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !HTMLBundle {
        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
        };
    }

    pub fn deinit(this: *HTMLBundle) void {
        this.allocator.free(this.path);
        this.* = undefined;
    }

    pub fn ref(this: *HTMLBundle) void {
        this.ref_count += 1;
    }

    pub fn deref(this: *HTMLBundle) void {
        if (this.ref_count > 0) this.ref_count -= 1;
    }

    pub fn getIndexForRoute(this: *const HTMLBundle) []const u8 {
        return this.path;
    }

    pub fn getIndex(_: *HTMLBundle, _: *jsc.JSGlobalObject) jsc.JSValue {
        return .zero;
    }

    pub fn finalize(this: *HTMLBundle) void {
        this.deinit();
    }

    pub fn route(this: *HTMLBundle) @import("HTMLBundle.zig").Route {
        this.ref();
        return .{
            .bundle = this,
            .state = .pending,
        };
    }
};

pub const HTMLBundleRoute = Route;

pub const Route = struct {
    bundle: *HTMLBundle,
    ref_count: usize = 1,
    server: ?*anyopaque = null,
    state: State = .pending,
    dev_server_id: bake.RouteBundle.Index.Optional = .none,
    active_viewers: usize = 0,

    pub const State = union(enum) {
        pending,
        html: StaticHTML,
        err: []const u8,

        pub fn deinit(this: *State, allocator: std.mem.Allocator) void {
            switch (this.*) {
                .html => |*html| html.deinit(allocator),
                .err => |message| allocator.free(message),
                .pending => {},
            }
            this.* = .pending;
        }
    };

    pub fn deinit(this: *Route, allocator: std.mem.Allocator) void {
        this.state.deinit(allocator);
        this.bundle.deref();
        this.* = undefined;
    }

    pub fn ref(this: *Route) void {
        this.ref_count += 1;
    }

    pub fn deref(this: *Route) void {
        if (this.ref_count > 0) this.ref_count -= 1;
    }

    pub fn setServer(this: *Route, server: ?*anyopaque) void {
        this.server = server;
    }

    pub fn memoryCost(this: *const Route) usize {
        return @sizeOf(Route) + switch (this.state) {
            .pending => 0,
            .err => |message| message.len,
            .html => |html| html.memoryCost(),
        };
    }

    pub fn markBuilt(this: *Route, allocator: std.mem.Allocator, html_source: []const u8) !void {
        this.state.deinit(allocator);
        this.state = .{ .html = try StaticHTML.init(allocator, html_source) };
    }

    pub fn markError(this: *Route, allocator: std.mem.Allocator, message: []const u8) !void {
        this.state.deinit(allocator);
        this.state = .{ .err = try allocator.dupe(u8, message) };
    }
};

pub const StaticHTML = struct {
    source: []const u8,
    refs: References,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !StaticHTML {
        return .{
            .source = try allocator.dupe(u8, source),
            .refs = try References.parse(allocator, source),
        };
    }

    pub fn deinit(this: *StaticHTML, allocator: std.mem.Allocator) void {
        allocator.free(this.source);
        this.refs.deinit(allocator);
        this.* = undefined;
    }

    pub fn memoryCost(this: *const StaticHTML) usize {
        var cost = this.source.len;
        for (this.refs.scripts.items) |script| cost += script.len;
        for (this.refs.styles.items) |style| cost += style.len;
        return cost;
    }
};

pub const References = struct {
    scripts: std.ArrayList([]const u8) = .empty,
    styles: std.ArrayList([]const u8) = .empty,

    pub fn deinit(this: *References, allocator: std.mem.Allocator) void {
        for (this.scripts.items) |script| allocator.free(script);
        for (this.styles.items) |style| allocator.free(style);
        this.scripts.deinit(allocator);
        this.styles.deinit(allocator);
        this.* = .{};
    }

    pub fn parse(allocator: std.mem.Allocator, html: []const u8) !References {
        var refs: References = .{};
        errdefer refs.deinit(allocator);

        try collectTagAttribute(allocator, html, "<script", "src", &refs.scripts);
        try collectStylesheetHrefs(allocator, html, &refs.styles);

        return refs;
    }
};

pub fn buildClientScript(
    allocator: std.mem.Allocator,
    refs: *const References,
    files: *const std.StringHashMap([]const u8),
    define: *const bake.DefineMap,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (refs.scripts.items) |script_path| {
        const source = files.get(script_path) orelse continue;
        const replaced = try applyDefineReplacements(allocator, source, define);
        defer allocator.free(replaced);
        try out.appendSlice(allocator, replaced);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

pub fn applyDefineReplacements(allocator: std.mem.Allocator, source: []const u8, define: *const bake.DefineMap) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        if (findDefineAt(source, i, define)) |entry| {
            try out.appendSlice(allocator, entry.value);
            i += entry.key.len;
            continue;
        }

        try out.append(allocator, source[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

const DefineEntry = struct {
    key: []const u8,
    value: []const u8,
};

fn findDefineAt(source: []const u8, index: usize, define: *const bake.DefineMap) ?DefineEntry {
    for (define.entries.keys(), define.entries.values()) |key, value| {
        if (key.len == 0 or index + key.len > source.len) continue;
        if (!std.mem.eql(u8, source[index .. index + key.len], key)) continue;
        if (isIdentifierLike(key) and (!isBoundary(source, index, -1) or !isBoundary(source, index + key.len, 1))) continue;
        return .{ .key = key, .value = value };
    }
    return null;
}

fn isIdentifierLike(text: []const u8) bool {
    for (text) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_' or char == '$')) return false;
    }
    return text.len > 0;
}

fn isBoundary(source: []const u8, index: usize, comptime direction: i2) bool {
    if (direction < 0 and index == 0) return true;
    if (direction > 0 and index >= source.len) return true;

    const char = if (direction < 0) source[index - 1] else source[index];
    return !(std.ascii.isAlphanumeric(char) or char == '_' or char == '$');
}

fn collectStylesheetHrefs(allocator: std.mem.Allocator, html: []const u8, out: *std.ArrayList([]const u8)) !void {
    var search_index: usize = 0;
    while (findAsciiInsensitive(html[search_index..], "<link")) |relative| {
        const tag_start = search_index + relative;
        const tag_end = findTagEnd(html, tag_start) orelse break;
        const tag = html[tag_start..tag_end];
        search_index = tag_end;

        const rel = attributeValue(tag, "rel") orelse continue;
        if (!std.ascii.eqlIgnoreCase(rel, "stylesheet")) continue;
        const href = attributeValue(tag, "href") orelse continue;
        try out.append(allocator, try allocator.dupe(u8, href));
    }
}

fn collectTagAttribute(
    allocator: std.mem.Allocator,
    html: []const u8,
    tag_name: []const u8,
    attr_name: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var search_index: usize = 0;
    while (findAsciiInsensitive(html[search_index..], tag_name)) |relative| {
        const tag_start = search_index + relative;
        const tag_end = findTagEnd(html, tag_start) orelse break;
        const tag = html[tag_start..tag_end];
        search_index = tag_end;

        const attr = attributeValue(tag, attr_name) orelse continue;
        try out.append(allocator, try allocator.dupe(u8, attr));
    }
}

fn findTagEnd(html: []const u8, tag_start: usize) ?usize {
    const relative = std.mem.indexOfScalar(u8, html[tag_start..], '>') orelse return null;
    return tag_start + relative + 1;
}

fn attributeValue(tag: []const u8, attr_name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (findAsciiInsensitive(tag[index..], attr_name)) |relative| {
        const name_start = index + relative;
        const name_end = name_start + attr_name.len;
        index = name_end;

        if (!isAttributeNameBoundary(tag, name_start, name_end)) continue;

        var cursor = name_end;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        if (cursor >= tag.len or tag[cursor] != '=') continue;
        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        if (cursor >= tag.len) return null;

        const quote = tag[cursor];
        if (quote == '"' or quote == '\'') {
            cursor += 1;
            const end = std.mem.indexOfScalar(u8, tag[cursor..], quote) orelse return null;
            return tag[cursor .. cursor + end];
        }

        const value_start = cursor;
        while (cursor < tag.len and !std.ascii.isWhitespace(tag[cursor]) and tag[cursor] != '>') cursor += 1;
        return tag[value_start..cursor];
    }

    return null;
}

fn isAttributeNameBoundary(tag: []const u8, start: usize, end: usize) bool {
    if (start > 0) {
        const before = tag[start - 1];
        if (std.ascii.isAlphanumeric(before) or before == '-' or before == '_' or before == ':') return false;
    }
    if (end < tag.len) {
        const after = tag[end];
        if (std.ascii.isAlphanumeric(after) or after == '-' or after == '_' or after == ':') return false;
    }
    return true;
}

fn findAsciiInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

test "HTMLBundle init owns the imported path" {
    var bundle = try HTMLBundle.init(std.testing.allocator, "index.html");
    defer bundle.deinit();

    try std.testing.expectEqualStrings("index.html", bundle.getIndexForRoute());
    try std.testing.expectEqual(@as(usize, 1), bundle.ref_count);
}

test "HTMLBundle Route owns built static HTML references" {
    var bundle = try HTMLBundle.init(std.testing.allocator, "index.html");
    defer bundle.deinit();

    var route = bundle.route();
    defer route.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), bundle.ref_count);

    try route.markBuilt(std.testing.allocator,
        \\<!DOCTYPE html>
        \\<html>
        \\  <head><link rel="stylesheet" href="style.css"></head>
        \\  <body><script type="module" src="index.ts"></script></body>
        \\</html>
    );

    try std.testing.expect(route.state == .html);
    try std.testing.expectEqualStrings("index.ts", route.state.html.refs.scripts.items[0]);
    try std.testing.expectEqualStrings("style.css", route.state.html.refs.styles.items[0]);
    try std.testing.expectEqual(@as(usize, 2), bundle.ref_count);
}

test "HTMLBundle Route ref and server hooks are stable carriers" {
    var bundle = try HTMLBundle.init(std.testing.allocator, "index.html");
    defer bundle.deinit();

    var route = bundle.route();
    defer route.deinit(std.testing.allocator);

    var server_marker: u8 = 1;
    route.setServer(&server_marker);
    route.ref();
    route.deref();

    try std.testing.expectEqual(@as(usize, 1), route.ref_count);
    try std.testing.expect(route.server != null);
}

test "HTMLBundle define replacements match first Bake static define shape" {
    var define: bake.DefineMap = .{};
    defer define.deinit(std.testing.allocator);
    try define.putCopy(std.testing.allocator, "DEFINE", "\"HELLO\"");

    const replaced = try applyDefineReplacements(std.testing.allocator, "console.log(\"a=\" + DEFINE);", &define);
    defer std.testing.allocator.free(replaced);

    try std.testing.expectEqualStrings("console.log(\"a=\" + \"HELLO\");", replaced);
}

test "HTMLBundle client script concatenates referenced scripts with serve defines" {
    var refs = try References.parse(std.testing.allocator,
        \\<script type="module" src="index.ts"></script>
        \\<script type="module" src="second.ts"></script>
    );
    defer refs.deinit(std.testing.allocator);

    var files = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer files.deinit();
    try files.put("index.ts", "console.log(\"a=\" + DEFINE);");
    try files.put("second.ts", "console.log(\"done\");");

    var define: bake.DefineMap = .{};
    defer define.deinit(std.testing.allocator);
    try define.putCopy(std.testing.allocator, "DEFINE", "\"HELLO\"");

    const output = try buildClientScript(std.testing.allocator, &refs, &files, &define);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(
        "console.log(\"a=\" + \"HELLO\");\nconsole.log(\"done\");\n",
        output,
    );
}
