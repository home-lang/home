//! Selection contracts from Bun 4982b91e scripts/runner.node.mjs.
//! This module plans files; it never awards test-case or process-pass credit.
const std = @import("std");
const corpus = @import("corpus.zig");
const Allocator = std.mem.Allocator;

pub const Context = struct {
    executable: []const u8,
    os: []const u8,
    arch: []const u8,
    distro: ?[]const u8 = null,
    distro_version: ?[]const u8 = null,
    abi: ?[]const u8 = null,
    abi_version: ?[]const u8 = null,
    is_ci: bool = true,

    pub fn nodeTestsEnabled(self: Context) bool {
        return !(self.is_ci and std.mem.eql(u8, self.os, "darwin") and std.mem.eql(u8, self.arch, "x64"));
    }

    /// Includes executable suffixes, platform combinations, and distribution /
    /// ABI versions in upstream order. The caller owns every returned string.
    pub fn modifiers(self: Context, allocator: Allocator) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            freeStrings(allocator, result.items);
            result.deinit(allocator);
        }
        const basename = portableBasename(self.executable);
        // Node extname treats a leading dot alone as part of the basename.
        const extension = std.mem.lastIndexOfScalar(u8, basename, '.');
        const name = if (extension != null and extension.? > 0) basename[0..extension.?] else basename;
        var parts = std.mem.splitScalar(u8, name, '-');
        while (parts.next()) |part| {
            if (!std.mem.eql(u8, part, "bun")) try addModifier(allocator, &result, &.{part});
        }
        try addModifier(allocator, &result, &.{self.os});
        try addModifier(allocator, &result, &.{self.arch});
        try addModifier(allocator, &result, &.{ self.os, self.arch });
        inline for (.{ .{ self.distro, self.distro_version }, .{ self.abi, self.abi_version } }) |pair| {
            if (pair[0]) |kind| {
                if (kind.len > 0) {
                    try addModifier(allocator, &result, &.{kind});
                    try addModifier(allocator, &result, &.{ self.os, kind });
                    try addModifier(allocator, &result, &.{ self.os, self.arch, kind });
                    if (pair[1]) |version| {
                        if (version.len > 0) {
                            try addModifier(allocator, &result, &.{version});
                            try addModifier(allocator, &result, &.{ kind, version });
                            try addModifier(allocator, &result, &.{ self.os, kind, version });
                            try addModifier(allocator, &result, &.{ self.os, self.arch, kind, version });
                        }
                    }
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }
};

fn portableBasename(path: []const u8) []const u8 {
    return path[if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| i + 1 else 0..];
}

fn addModifier(allocator: Allocator, result: *std.ArrayList([]const u8), parts: []const []const u8) !void {
    const value = try std.mem.join(allocator, "-", parts);
    errdefer allocator.free(value);
    for (value) |*byte| byte.* = std.ascii.toUpper(byte.*);
    try result.append(allocator, value);
}

fn freeStrings(allocator: Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
}

pub fn freeModifiers(allocator: Allocator, strings: [][]const u8) void {
    freeStrings(allocator, strings);
    allocator.free(strings);
}

const whitespace = " \t\r\n\x0b\x0c";
fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, whitespace);
}

pub const Rule = struct {
    line: usize,
    filename: []const u8,
    /// null means no bracket; an empty bracket must NOT mean unconditional.
    modifiers: ?[]const u8,
    values: []const u8,
    comment: ?[]const u8,

    pub fn applies(self: Rule, modifiers: []const []const u8) bool {
        const source = self.modifiers orelse return true;
        if (source.len == 0) {
            for (modifiers) |modifier| if (modifier.len == 0) return true;
            return false;
        }
        var tokens = std.mem.tokenizeAny(u8, source, whitespace);
        while (tokens.next()) |token| {
            for (modifiers) |modifier| if (std.mem.eql(u8, token, modifier)) return true;
        }
        return false;
    }

    pub fn matches(self: Rule, path: []const u8) bool {
        // String.replace("test/", "") removes the FIRST occurrence, even in
        // the middle of a filename. Expectations use substring, not glob, matching.
        const removed = std.mem.indexOf(u8, self.filename, "test/");
        const first = if (removed) |index| self.filename[0..index] else self.filename;
        const second = if (removed) |index| self.filename[index + 5 ..] else "";
        if (first.len + second.len > path.len) return false;
        for (0..path.len - first.len - second.len + 1) |offset| {
            if (normalizedEqual(path[offset..][0..first.len], first) and
                normalizedEqual(path[offset + first.len ..][0..second.len], second)) return true;
        }
        return false;
    }
};

/// Rules borrow source bytes. Return order and physical line numbers are retained
/// so a selection report can identify the exact upstream exclusion and comment.
pub fn parseExpectations(allocator: Allocator, source: []const u8) ![]Rule {
    var result: std.ArrayList(Rule) = .empty;
    errdefer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        var text = trim(raw);
        if (text.len == 0 or text[0] == '#') continue;
        var comment: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, text, '#')) |index| {
            comment = trim(text[index + 1 ..]);
            text = trim(text[0..index]);
        }
        var modifiers: ?[]const u8 = null;
        if (text.len > 0 and text[0] == '[') {
            if (std.mem.indexOfScalar(u8, text, ']')) |end| {
                modifiers = trim(text[1..end]);
                text = trim(text[end + 1 ..]);
            }
        }
        var values: []const u8 = "Skip";
        if (std.mem.endsWith(u8, text, "]")) {
            if (std.mem.indexOfScalar(u8, text, '[')) |start| {
                values = trim(text[start + 1 .. text.len - 1]);
                text = trim(text[0..start]);
            }
        }
        if (text.len == 0) continue;
        try result.append(allocator, .{ .line = line_number, .filename = text, .modifiers = modifiers, .values = values, .comment = comment });
    }
    return result.toOwnedSlice(allocator);
}

fn normalizedEqual(path: []const u8, text: []const u8) bool {
    if (path.len != text.len) return false;
    for (path, text) |a, b| if ((if (a == '\\') @as(u8, '/') else a) != b) return false;
    return true;
}

pub fn contains(path: []const u8, filter: []const u8) bool {
    if (filter.len > path.len) return false;
    for (0..path.len - filter.len + 1) |offset| if (normalizedEqual(path[offset..][0..filter.len], filter)) return true;
    return false;
}

fn matchesFilters(path: []const u8, filters: []const []const u8, comma_separated: bool) bool {
    for (filters) |filter| {
        if (!comma_separated) {
            if (contains(path, filter)) return true;
        } else {
            var parts = std.mem.splitScalar(u8, filter, ',');
            while (parts.next()) |raw| {
                const part = trim(raw);
                if (part.len > 0 and contains(path, part)) return true;
            }
        }
    }
    return false;
}

fn hasFilters(filters: []const []const u8) bool {
    for (filters) |filter| {
        var parts = std.mem.splitScalar(u8, filter, ',');
        while (parts.next()) |part| if (trim(part).len > 0) return true;
    }
    return false;
}

pub const Options = struct {
    node_only: bool = false,
    includes: []const []const u8 = &.{},
    excludes: []const []const u8 = &.{},
    filters: []const []const u8 = &.{},
    shard: usize = 0,
    max_shards: usize = 1,
    /// Already classified upstream test-relative paths, preserving stable order.
    modified_tests: []const []const u8 = &.{},
};

pub const Reason = enum { node_platform, node_only, include_filter, exclude_filter, expectation, positional_filter, shard };
pub const Excluded = struct { index: usize, reason: Reason, rule: ?usize = null };
pub const Selection = struct {
    selected: []usize,
    excluded: []Excluded,
    pub fn deinit(self: Selection, allocator: Allocator) void {
        allocator.free(self.selected);
        allocator.free(self.excluded);
    }
};

pub fn matchingRule(path: []const u8, rules: []const Rule, modifiers: []const []const u8) ?usize {
    for (rules, 0..) |rule, index| if (rule.applies(modifiers) and rule.matches(path)) return index;
    return null;
}

/// Input is the complete, ordered pre-exclusion discovery inventory. Every
/// input is accounted for exactly once. No random sampling enters this gate.
pub fn select(allocator: Allocator, files: []const []const u8, context: Context, rules: []const Rule, options: Options) !Selection {
    if (options.max_shards > 1 and options.shard >= options.max_shards) return error.InvalidCorpusShard;
    const modifiers = try context.modifiers(allocator);
    defer freeModifiers(allocator, modifiers);
    var selected: std.ArrayList(usize) = .empty;
    errdefer selected.deinit(allocator);
    var excluded: std.ArrayList(Excluded) = .empty;
    errdefer excluded.deinit(allocator);
    var available_index: usize = 0;
    for (files, 0..) |path, index| {
        var rule_index: ?usize = null;
        const reason: ?Reason = reason: {
            const node = corpus.isNodeTestFile(path) and context.nodeTestsEnabled();
            // A strict *.test file remains discoverable even when the Node
            // parallel-file classifier is disabled on macOS x64 CI.
            if (!context.nodeTestsEnabled() and corpus.isNodeTestFile(path) and !corpus.isTestStrictFile(path)) break :reason .node_platform;
            if (options.node_only and !node) break :reason .node_only;
            if (hasFilters(options.includes) and !matchesFilters(path, options.includes, true)) break :reason .include_filter;
            if (matchesFilters(path, options.excludes, true)) break :reason .exclude_filter;
            rule_index = matchingRule(path, rules, modifiers);
            if (rule_index != null) break :reason .expectation;
            const position = available_index;
            available_index += 1;
            if (options.filters.len > 0) {
                if (!matchesFilters(path, options.filters, false)) break :reason .positional_filter;
            } else if (options.max_shards > 1 and position % options.max_shards != options.shard) break :reason .shard;
            break :reason null;
        };
        if (reason) |why| try excluded.append(allocator, .{ .index = index, .reason = why, .rule = rule_index }) else try selected.append(allocator, index);
    }
    if (options.modified_tests.len > 0) {
        const Sort = struct {
            files: []const []const u8,
            modified: []const []const u8,
            fn isModified(self: @This(), index: usize) bool {
                for (self.modified) |path| if (normalizedEqual(self.files[index], path)) return true;
                return false;
            }
            fn less(self: @This(), a: usize, b: usize) bool {
                return self.isModified(a) and !self.isModified(b);
            }
        };
        std.mem.sort(usize, selected.items, Sort{ .files = files, .modified = options.modified_tests }, Sort.less);
    }
    const owned_selected = try selected.toOwnedSlice(allocator);
    errdefer allocator.free(owned_selected);
    return .{ .selected = owned_selected, .excluded = try excluded.toOwnedSlice(allocator) };
}

/// Refuse extra Home exclusions against the pinned inventory. Removing an
/// upstream exclusion is allowed and must be reported as additional coverage.
pub fn validateHomeExpectations(files: []const []const u8, upstream: []const Rule, home: []const Rule, modifiers: []const []const u8) !void {
    for (files) |path| {
        if (matchingRule(path, home, modifiers) != null and matchingRule(path, upstream, modifiers) == null) return error.HomeOnlyCorpusExclusion;
    }
}

test "corpus selection parses comments, OR modifiers, empty brackets and substring rules" {
    const allocator = std.testing.allocator;
    const rules = try parseExpectations(allocator, "# comment\r\n[ LINUX ASAN ] test/a.js [ FAIL ] # why\r\n[] test/empty.js\n[ ASAN ] no-test/path [ LEAK CRASH ]\nplain [ SKIP ]\n");
    defer allocator.free(rules);
    try std.testing.expectEqual(@as(usize, 4), rules.len);
    try std.testing.expectEqual(@as(usize, 2), rules[0].line);
    try std.testing.expectEqualStrings("why", rules[0].comment.?);
    try std.testing.expect(rules[0].applies(&.{"ASAN"}));
    try std.testing.expect(!rules[0].applies(&.{"asan"}));
    try std.testing.expect(rules[0].matches("prefix\\a.js.backup"));
    try std.testing.expect(!rules[1].applies(&.{"DARWIN"}));
    try std.testing.expect(rules[1].applies(&.{""}));
    try std.testing.expect(rules[2].matches("no-path"));
    try std.testing.expectEqualStrings("Skip", rules[1].values);
}

test "corpus selection filters before sharding and positional filters override shards" {
    const allocator = std.testing.allocator;
    const files = [_][]const u8{ "a.test.js", "b.test.js", "c.test.js", "d.test.js", "e.test.js" };
    const context = Context{ .executable = "bun", .os = "linux", .arch = "x64" };
    const rules = try parseExpectations(allocator, "test/b.test.js [ FAIL ]");
    defer allocator.free(rules);
    const selection = try select(allocator, &files, context, rules, .{ .includes = &.{" , .test, "}, .excludes = &.{"d.test"}, .shard = 1, .max_shards = 2 });
    defer selection.deinit(allocator);
    try std.testing.expectEqualSlices(usize, &.{2}, selection.selected);
    try std.testing.expectEqual(@as(usize, 4), selection.excluded.len);
    const filtered = try select(allocator, &files, context, rules, .{ .filters = &.{".test"}, .shard = 1, .max_shards = 2, .modified_tests = &.{"e.test.js"} });
    defer filtered.deinit(allocator);
    try std.testing.expectEqualSlices(usize, &.{ 4, 0, 2, 3 }, filtered.selected);
    try std.testing.expectError(error.HomeOnlyCorpusExclusion, validateHomeExpectations(&files, &.{}, rules, &.{}));
    try validateHomeExpectations(&files, rules, &.{}, &.{});
}

test "corpus selection preserves strict tests on macOS x64 and builds version modifiers" {
    const allocator = std.testing.allocator;
    const context = Context{ .executable = "C:\\bin\\bun-asan.exe", .os = "darwin", .arch = "x64", .distro = "macOS", .distro_version = "15.6" };
    const modifiers = try context.modifiers(allocator);
    defer freeModifiers(allocator, modifiers);
    try std.testing.expectEqualStrings("ASAN", modifiers[0]);
    try std.testing.expectEqualStrings("DARWIN-X64-MACOS-15.6", modifiers[modifiers.len - 1]);
    const files = [_][]const u8{ "js/node/test/parallel/test-a.js", "js/node/test/parallel/a.test.js", "a.test.js" };
    const selection = try select(allocator, &files, context, &.{}, .{});
    defer selection.deinit(allocator);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, selection.selected);
    const node_only = try select(allocator, &files, context, &.{}, .{ .node_only = true });
    defer node_only.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), node_only.selected.len);
}
