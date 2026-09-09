//! Pinned vendor discovery. Preparation and execution are separate operations;
//! discovering a file is never a passing test result.
const std = @import("std");
const home = @import("home_rt");
const corpus = @import("corpus.zig");
const selection = @import("corpus_selection.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Inspect an already prepared checkout without modifying it. The full CI
/// coordinator still owns clone/fetch/checkout/install/build operations.
pub fn preparedRevision(allocator: Allocator, io: Io, project_root: []const u8, vendor: Vendor) ![]u8 {
    const cwd = try std.fs.path.join(allocator, &.{ project_root, "vendor", vendor.package });
    defer allocator.free(cwd);
    const tag = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{vendor.tag});
    defer allocator.free(tag);
    const capture = @import("adapters/jsc_bootstrap.zig");
    var result = try capture.runToolCaptured(allocator, io, &.{ "git", "rev-parse", "--verify", "--end-of-options", "HEAD" }, cwd, 180_000);
    defer result.deinit(allocator);
    var expected = try capture.runToolCaptured(allocator, io, &.{ "git", "rev-parse", "--verify", "--end-of-options", tag }, cwd, 180_000);
    defer expected.deinit(allocator);
    if (!result.term.success() or !expected.term.success() or result.timed_out or expected.timed_out or !result.output_complete or !expected.output_complete) return error.VendorRevisionUnavailable;
    const revision = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (revision.len != 40 or !std.mem.eql(u8, revision, std.mem.trim(u8, expected.stdout, " \t\r\n"))) return error.VendorCheckoutDoesNotMatchTag;
    return allocator.dupe(u8, revision);
}

pub const Vendor = struct {
    package: []const u8,
    repository: []const u8,
    tag: []const u8,
    testPath: ?[]const u8 = null,
    testExtensions: ?[]const []const u8 = null,
    testRunner: ?[]const u8 = null,
    packageManager: ?[]const u8 = null,
    skipTests: std.json.Value = .null,

    pub fn testDirectory(self: Vendor) []const u8 {
        return nonempty(self.testPath) orelse "test";
    }
    pub fn runner(self: Vendor) []const u8 {
        return nonempty(self.testRunner) orelse "bun";
    }
    pub fn manager(self: Vendor) []const u8 {
        return nonempty(self.packageManager) orelse "bun";
    }
};

fn nonempty(value: ?[]const u8) ?[]const u8 {
    return if (value != null and value.?.len > 0) value else null;
}

pub const Decision = union(enum) {
    selected,
    not_test,
    extension,
    all_disabled,
    skip_rule: []const u8,
    positional_filter,
};

/// Upstream calls this a glob but only replaces '*' with '.*'. Other regular
/// expression syntax (including unescaped dots) remains active. Use Home's
/// actual ECMAScript regex engine, not filesystem glob semantics.
pub fn regexPattern(allocator: Allocator, pattern: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '^');
    for (pattern) |byte| {
        if (byte == '*') try out.appendSlice(allocator, ".*") else try out.append(allocator, byte);
    }
    try out.append(allocator, '$');
    return out.toOwnedSlice(allocator);
}

const SkipRule = struct { pattern: []const u8, regex: *home.jsc.RegularExpression, reason: std.json.Value };
pub const Filter = struct {
    vendor: Vendor,
    rules: []SkipRule,

    pub fn init(allocator: Allocator, vendor: Vendor) !Filter {
        var rules: std.ArrayList(SkipRule) = .empty;
        errdefer {
            for (rules.items) |rule| rule.regex.deinit();
            rules.deinit(allocator);
        }
        // Explicit extensions bypass BOTH JavaScript-test classification and
        // skipTests in the pinned runner, even when the extension list is empty.
        if (vendor.testExtensions == null and vendor.skipTests == .object) {
            // Yarr's interpreter uses JSC options and allocator limits even
            // without a JavaScript VM. Use the production once-guarded startup
            // before compiling or matching any pattern from a native caller.
            home.jsc.initialize(false);
            var entries = vendor.skipTests.object.iterator();
            while (entries.next()) |entry| {
                const pattern = try regexPattern(allocator, entry.key_ptr.*);
                defer allocator.free(pattern);
                const string = home.String.cloneUTF8(pattern);
                defer string.deref();
                const regex = try home.jsc.RegularExpression.init(string, .none);
                errdefer regex.deinit();
                try rules.append(allocator, .{ .pattern = entry.key_ptr.*, .regex = regex, .reason = entry.value_ptr.* });
            }
        }
        return .{ .vendor = vendor, .rules = try rules.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: Filter, allocator: Allocator) void {
        for (self.rules) |rule| rule.regex.deinit();
        allocator.free(self.rules);
    }

    /// relative is relative to testPath; full_path is the vendor project path
    /// joined with testPath and relative, as used by upstream positional filters.
    pub fn decide(self: Filter, relative: []const u8, full_path: []const u8, filters: []const []const u8) Decision {
        if (self.vendor.testExtensions) |extensions| {
            for (extensions) |extension| {
                if (relative.len > extension.len and std.mem.endsWith(u8, relative, extension) and relative[relative.len - extension.len - 1] == '.') break;
            } else return .extension;
        } else {
            if (!corpus.isTestStrictFile(relative)) return .not_test;
            if (self.vendor.skipTests == .bool and self.vendor.skipTests.bool) return .all_disabled;
            for (self.rules) |rule| {
                const string = home.String.cloneUTF8(relative);
                defer string.deref();
                if (rule.regex.matches(string) and truthy(rule.reason)) return .{ .skip_rule = rule.pattern };
            }
        }
        if (filters.len > 0) {
            for (filters) |filter| {
                if (selection.contains(full_path, filter)) break;
            } else return .positional_filter;
        }
        return .selected;
    }
};

fn truthy(value: std.json.Value) bool {
    return switch (value) {
        .null => false,
        .bool => |v| v,
        .integer => |v| v != 0,
        .float => |v| v != 0,
        .string, .number_string => |v| v.len != 0,
        .array, .object => true,
    };
}

/// Node's recursive readdir returns each directory's sorted entries, then
/// visits subdirectories in queue order. Keep directory entries too: upstream
/// applies filename predicates without checking the resulting entry's type.
pub fn collectEntries(allocator: Allocator, io: Io, root: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |path| allocator.free(path);
        result.deinit(allocator);
    }
    var pending: std.ArrayList([]const u8) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, "");
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        const prefix = pending.items[cursor];
        const directory = try std.fs.path.join(allocator, &.{ root, prefix });
        defer allocator.free(directory);
        var dir = try Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
        defer dir.close(io);
        const Entry = struct { path: []const u8, directory: bool };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(allocator);
        var transferred: usize = 0;
        defer for (entries.items[transferred..]) |entry| allocator.free(entry.path);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            const path = try std.fs.path.join(allocator, &.{ prefix, entry.name });
            errdefer allocator.free(path);
            try entries.append(allocator, .{ .path = path, .directory = entry.kind == .directory });
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.less);
        for (entries.items) |entry| {
            try result.append(allocator, entry.path);
            transferred += 1;
            if (entry.directory) try pending.append(allocator, entry.path);
        }
    }
    return result.toOwnedSlice(allocator);
}

test "native corpus vendor regex and extension precedence follow the pinned runner" {
    if (!@import("build_options").enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Vendor, allocator,
        \\{"package":"fixture","repository":"unused","tag":"1","skipTests":{"ws*connection.test.ts":"original reason","other*":""}}
    , .{});
    defer parsed.deinit();
    var filter = try Filter.init(allocator, parsed.value);
    defer filter.deinit(allocator);
    try std.testing.expect(filter.decide("ws/connection.test.ts", "/vendor/test/ws/connection.test.ts", &.{}) == .skip_rule);
    try std.testing.expect(filter.decide("ws\\connection.test.ts", "C:\\vendor\\test\\ws\\connection.test.ts", &.{}) == .skip_rule);
    // Dots are regex wildcards, not escaped glob literals.
    try std.testing.expect(filter.decide("ws-spec.connectionXtest.ts", "/v/test/a", &.{}) == .skip_rule);
    try std.testing.expect(filter.decide("other.test.ts", "/v/test/other.test.ts", &.{}) == .selected);
    try std.testing.expect(filter.decide("a.test.ts", "/v/test/a.test.ts", &.{"missing"}) == .positional_filter);
    var extended = parsed.value;
    extended.testExtensions = &.{"ts"};
    extended.skipTests = .{ .bool = true };
    var extension_filter = try Filter.init(allocator, extended);
    defer extension_filter.deinit(allocator);
    try std.testing.expect(extension_filter.decide("plain.ts", "/v/test/plain.ts", &.{}) == .selected);
    try std.testing.expect(extension_filter.decide("a.test.js", "/v/test/a.test.js", &.{}) == .extension);
}

test "native corpus vendor discovery retains pinned Elysia selection evidence" {
    if (!@import("build_options").enable_jsc) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const output = std.testing.environ.getAlloc(allocator, "HOME_CORPUS_VENDOR_PLAN_OUTPUT") catch return error.SkipZigTest;
    defer allocator.free(output);
    const io = std.testing.io;
    const root = try Io.Dir.cwd().realPathFileAlloc(io, "packages/runtime/test/vendor/elysia", allocator);
    defer allocator.free(root);
    const manifest = try Io.Dir.cwd().readFileAlloc(io, "packages/runtime/test/test/vendor.json", allocator, .limited(1024 * 1024));
    defer allocator.free(manifest);
    const parsed = try std.json.parseFromSlice([]Vendor, allocator, manifest, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("elysia", parsed.value[0].package);
    var filter = try Filter.init(allocator, parsed.value[0]);
    defer filter.deinit(allocator);
    const test_root = try std.fs.path.join(allocator, &.{ root, parsed.value[0].testDirectory() });
    defer allocator.free(test_root);
    const entries = try collectEntries(allocator, io, test_root);
    defer corpus.freeTestFiles(allocator, entries);
    var selected: std.ArrayList([]const u8) = .empty;
    defer selected.deinit(allocator);
    var excluded: std.ArrayList([]const u8) = .empty;
    defer excluded.deinit(allocator);
    for (entries) |path| {
        const full_path = try std.fs.path.join(allocator, &.{ test_root, path });
        defer allocator.free(full_path);
        switch (filter.decide(path, full_path, &.{})) {
            .selected => try selected.append(allocator, path),
            .skip_rule => try excluded.append(allocator, path),
            else => {},
        }
    }
    try std.testing.expect(selected.items.len > 0);
    try std.testing.expectEqual(@as(usize, 1), excluded.items.len);
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .kind = "vendor-selection-only",
        .vendor = parsed.value[0],
        .entries = entries,
        .selected = selected.items,
        .excluded = excluded.items,
    }, .{});
    defer allocator.free(json);
    const file = try Io.Dir.cwd().createFile(io, output, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, json);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
}
