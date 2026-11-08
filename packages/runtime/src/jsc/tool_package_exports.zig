//! Node-style package exports selection, independent of filesystem probing.
//! Active conditions are node + import/require + explicit CLI conditions; JSON key order wins.
const std = @import("std");
pub const Mode = enum { import, require };
const Selection = union(enum) { unmatched, blocked, target: []u8 };

pub fn code(err: anyerror) []const u8 {
    return switch (err) {
        error.PackagePathNotExported => "ERR_PACKAGE_PATH_NOT_EXPORTED",
        error.InvalidPackageTarget => "ERR_INVALID_PACKAGE_TARGET",
        error.InvalidPackageConfig => "ERR_INVALID_PACKAGE_CONFIG",
        error.InvalidModuleSpecifier => "ERR_INVALID_MODULE_SPECIFIER",
        error.UnsupportedPackageTarget => "ERR_HOME_PACKAGE_TARGET",
        error.ExportedFileNotFound => "MODULE_NOT_FOUND",
        else => "ERR_HOME_MODULE_RESOLUTION",
    };
}

// PACKAGE_TARGET_RESOLVE validates segments before star substitution. Encoded
// separators matter only if the selected file URL actually contains them: a
// pattern can legally map every subpath to a fixed target without a star.
fn validateSegments(allocator: std.mem.Allocator, source: []const u8, invalid: anyerror) !void {
    if (std.mem.findAny(u8, source, "\\?#") != null) return error.UnsupportedPackageTarget;
    var segments = std.mem.splitScalar(u8, source, '/');
    while (segments.next()) |segment| {
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(allocator);
        var i: usize = 0;
        while (i < segment.len) : (i += 1) {
            if (segment[i] == '%' and i + 2 < segment.len) {
                const hi = std.fmt.charToDigit(segment[i + 1], 16) catch {
                    try decoded.append(allocator, segment[i]);
                    continue;
                };
                const lo = std.fmt.charToDigit(segment[i + 2], 16) catch {
                    try decoded.append(allocator, segment[i]);
                    continue;
                };
                try decoded.append(allocator, hi * 16 + lo);
                i += 2;
            } else try decoded.append(allocator, segment[i]);
        }
        if (std.mem.eql(u8, decoded.items, ".") or std.mem.eql(u8, decoded.items, "..") or
            std.ascii.eqlIgnoreCase(decoded.items, "node_modules")) return invalid;
    }
}

fn decodePath(allocator: std.mem.Allocator, source: []const u8, invalid: anyerror) ![]u8 {
    try validateSegments(allocator, source, invalid);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        var byte = source[i];
        if (byte == '%') {
            if (i + 2 >= source.len) return error.InvalidModuleSpecifier;
            const hi = std.fmt.charToDigit(source[i + 1], 16) catch return error.InvalidModuleSpecifier;
            const lo = std.fmt.charToDigit(source[i + 2], 16) catch return error.InvalidModuleSpecifier;
            byte = hi * 16 + lo;
            if (byte == '/' or byte == '\\') return error.InvalidModuleSpecifier;
            i += 2;
        }
        if (byte == 0) return error.InvalidModuleSpecifier;
        try output.append(allocator, byte);
    }
    return output.toOwnedSlice(allocator);
}

fn active(key: []const u8, mode: Mode, conditions: []const []const u8) bool {
    if (std.mem.eql(u8, key, "default") or std.mem.eql(u8, key, "node") or
        std.mem.eql(u8, key, if (mode == .import) "import" else "require")) return true;
    for (conditions) |condition| if (std.mem.eql(u8, key, condition)) return true;
    return false;
}

fn select(allocator: std.mem.Allocator, value: std.json.Value, replacement: ?[]const u8, mode: Mode, conditions: []const []const u8, depth: usize) anyerror!Selection {
    if (depth > 128) return error.InvalidPackageConfig;
    switch (value) {
        .null => return .blocked,
        .string => |target| {
            if (!std.mem.startsWith(u8, target, "./")) return error.InvalidPackageTarget;
            // Validate before substitution, so a replacement cannot hide an
            // invalid target. '*' is a literal in an exact (non-pattern) map.
            const relative = try decodePath(allocator, target[2..], error.InvalidPackageTarget);
            defer allocator.free(relative);
            if (replacement) |subpath| {
                try validateSegments(allocator, subpath, error.InvalidModuleSpecifier);
                var output: std.ArrayList(u8) = .empty;
                defer output.deinit(allocator);
                for (target[2..]) |byte| {
                    if (byte == '*') try output.appendSlice(allocator, subpath) else try output.append(allocator, byte);
                }
                return .{ .target = try decodePath(allocator, output.items, error.InvalidPackageTarget) };
            }
            return .{ .target = try allocator.dupe(u8, relative) };
        },
        .array => |array| {
            var invalid_target = false;
            for (array.items) |item| {
                const result = select(allocator, item, replacement, mode, conditions, depth + 1) catch |err| {
                    if (err != error.InvalidPackageTarget) return err;
                    invalid_target = true;
                    continue;
                };
                switch (result) {
                    .target => return result,
                    .unmatched => {},
                    .blocked => invalid_target = false,
                }
            }
            if (invalid_target) return error.InvalidPackageTarget;
            return .blocked;
        },
        .object => |object| {
            // JS enumerates array-index keys ahead of insertion order, making
            // numeric condition keys invalid package configuration.
            for (object.keys()) |key| {
                const index = std.fmt.parseInt(u32, key, 10) catch continue;
                if (index != std.math.maxInt(u32) and key.len != 0 and
                    (key.len == 1 or key[0] != '0'))
                {
                    var digits = true;
                    for (key) |byte| {
                        if (byte < '0' or byte > '9') digits = false;
                    }
                    if (digits) return error.InvalidPackageConfig;
                }
            }
            for (object.keys(), object.values()) |key, item| {
                if (active(key, mode, conditions)) {
                    const result = try select(allocator, item, replacement, mode, conditions, depth + 1);
                    if (result != .unmatched) return result;
                }
            }
            return .unmatched;
        },
        else => return error.InvalidPackageTarget,
    }
}

// PACKAGE_EXPORTS_RESOLVE and PATTERN_KEY_COMPARE:
// https://nodejs.org/api/esm.html#resolution-algorithm-specification
pub fn resolve(allocator: std.mem.Allocator, exports: std.json.Value, subpath: []const u8, mode: Mode) ![]u8 {
    return resolveWithConditions(allocator, exports, subpath, mode, &.{});
}

pub fn resolveWithConditions(allocator: std.mem.Allocator, exports: std.json.Value, subpath: []const u8, mode: Mode, custom_conditions: []const []const u8) ![]u8 {
    var selected: std.json.Value = exports;
    var replacement: ?[]const u8 = null;
    if (exports == .object) {
        var dotted = false;
        var conditions = false;
        for (exports.object.keys()) |key| {
            if (std.mem.startsWith(u8, key, ".")) dotted = true else conditions = true;
        }
        if (dotted and conditions) return error.InvalidPackageConfig;
        if (dotted) {
            if (std.mem.findScalar(u8, subpath, '*') == null and !std.mem.endsWith(u8, subpath, "/") and exports.object.get(subpath) != null) {
                selected = exports.object.get(subpath).?;
            } else {
                var best: ?[]const u8 = null;
                var best_prefix: usize = 0;
                for (exports.object.keys(), exports.object.values()) |key, item| {
                    const star = std.mem.findScalar(u8, key, '*') orelse continue;
                    if (std.mem.findScalar(u8, key[star + 1 ..], '*') != null) continue;
                    const trailer = key[star + 1 ..];
                    if (subpath.len < key.len or !std.mem.startsWith(u8, subpath, key[0..star]) or !std.mem.endsWith(u8, subpath, trailer)) continue;
                    if (best == null or star > best_prefix or (star == best_prefix and key.len > best.?.len)) {
                        best = key;
                        best_prefix = star;
                        selected = item;
                        replacement = subpath[star .. subpath.len - trailer.len];
                    }
                }
                if (best == null) return error.PackagePathNotExported;
            }
        } else if (!std.mem.eql(u8, subpath, ".")) return error.PackagePathNotExported;
    } else if (!std.mem.eql(u8, subpath, ".")) return error.PackagePathNotExported;
    return switch (try select(allocator, selected, replacement, mode, custom_conditions, 0)) {
        .target => |path| path,
        else => error.PackagePathNotExported,
    };
}

test "exports selection preserves import require conditions and pattern specificity" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{".":{"import":"./i.js","require":"./r.cjs"},"./*":"./fallback/*.js","./feature/*":"./specific/*.js","./feature/*.json":"./json/*.js","./feature/exact":"./exact.js"}
    , .{});
    defer parsed.deinit();
    const cases = .{ .{ ".", Mode.import, "i.js" }, .{ ".", Mode.require, "r.cjs" }, .{ "./x/y", Mode.import, "fallback/x/y.js" }, .{ "./feature/a", Mode.import, "specific/a.js" }, .{ "./feature/a.json", Mode.require, "json/a.js" }, .{ "./feature/exact", Mode.import, "exact.js" } };
    inline for (cases) |case| {
        const result = try resolve(std.testing.allocator, parsed.value, case[0], case[1]);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case[2], result);
    }
}

fn expectTarget(source: []const u8, subpath: []const u8, mode: Mode, expected: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const result = try resolve(std.testing.allocator, parsed.value, subpath, mode);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

fn expectError(source: []const u8, subpath: []const u8, mode: Mode, expected: anyerror) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    try std.testing.expectError(expected, resolve(std.testing.allocator, parsed.value, subpath, mode));
}

test "exports condition order nested misses and null blocking" {
    try expectTarget("{\"default\":\"./default.js\",\"require\":\"./wrong.js\"}", ".", .require, "default.js");
    try expectTarget("{\"node\":{\"other\":\"./wrong.js\"},\"default\":\"./fallback.js\"}", ".", .import, "fallback.js");
    try expectTarget("{\"node\":{\"import\":\"./i.js\",\"require\":\"./r.js\"}}", ".", .require, "r.js");
    try expectError("{\"node\":null,\"default\":\"./wrong.js\"}", ".", .import, error.PackagePathNotExported);
    try expectError("{\"import\":\"./i.js\"}", ".", .require, error.PackagePathNotExported);
    try expectError("{\"development\":\"./d.js\",\"bun\":\"./b.js\",\"types\":\"./t.d.ts\"}", ".", .import, error.PackagePathNotExported);
}

test "exports array fallbacks select targets without probing file existence" {
    try expectTarget("[\"../bad.js\",null,{\"other\":\"./wrong.js\"},\"./valid.js\"]", ".", .import, "valid.js");
    try expectTarget("[\"./missing.js\",\"./exists.js\"]", ".", .require, "missing.js");
    try expectError("[\"../bad.js\"]", ".", .require, error.InvalidPackageTarget);
    try expectError("[\"../bad.js\",null]", ".", .require, error.PackagePathNotExported);
    try expectError("[null,\"../bad.js\"]", ".", .require, error.InvalidPackageTarget);
    try expectError("[]", ".", .import, error.PackagePathNotExported);
}

test "exports rejects invalid config and prohibited target segments" {
    try expectError("{\".\":\"./a.js\",\"import\":\"./b.js\"}", ".", .import, error.InvalidPackageConfig);
    try expectError("{\"0\":null,\"default\":\"./a.js\"}", ".", .require, error.InvalidPackageConfig);
    try expectTarget("{\"01\":null,\"default\":\"./a.js\"}", ".", .require, "a.js");
    inline for (.{ "../outside.js", "https://example.com/a.js", "./a/../b.js", "./%2e%2e/a.js", "./node_modules/a.js", "./%6eode_modules/a.js" }) |target| {
        try expectError("\"" ++ target ++ "\"", ".", .import, error.InvalidPackageTarget);
    }
    try expectError("\"./a%2fb.js\"", ".", .import, error.InvalidModuleSpecifier);
    try expectError("{\"./*\":\"./dist/*.js\"}", "./a/../b", .import, error.InvalidModuleSpecifier);
    try expectError("{\"./*\":\"./dist/*.js\"}", "./node_modules/b", .import, error.InvalidModuleSpecifier);
    try expectError("{\"./private/*\":null,\"./*\":\"./dist/*.js\"}", "./private/b", .import, error.PackagePathNotExported);
    try expectError("\"./a.js\"", "./a.js", .import, error.PackagePathNotExported);
    try expectError("\"./a.js?query\"", ".", .import, error.UnsupportedPackageTarget);
}

test "exports replaces all raw stars and preserves escaped literal stars" {
    try expectTarget("{\"./*\":\"./dist/*/copy-*.js\"}", "./a/b", .import, "dist/a/b/copy-a/b.js");
    try expectTarget("{\"./*\":\"./dist/%2A.js\"}", "./value", .import, "dist/*.js");
    try expectTarget("\"./file%20name.js\"", ".", .require, "file name.js");
}

test "exports fixed pattern target ignores unused encoded separator" {
    try expectTarget("{\"./*\":\"./fixed.js\"}", "./a%2fb", .import, "fixed.js");
    try expectError("{\"./*\":\"./*.js\"}", "./a%2fb", .import, error.InvalidModuleSpecifier);
}

test "custom conditions preserve JSON order nested misses and null blocking" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{".":{"second":"./second.js","first":"./first.js","default":"./default.js"},"./nested":{"first":{"missing":"./wrong.js"},"default":"./default.js"},"./blocked":{"first":null,"default":"./default.js"},"./literal":{"first,second":"./literal.js","default":"./default.js"}}
    , .{});
    defer parsed.deinit();
    const conditions = &.{ "first", "second" };
    for ([_][]const u8{ ".", "./nested", "./literal" }, [_][]const u8{ "second.js", "default.js", "default.js" }) |subpath, expected| {
        const result = try resolveWithConditions(std.testing.allocator, parsed.value, subpath, .import, conditions);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(expected, result);
    }
    try std.testing.expectError(error.PackagePathNotExported, resolveWithConditions(std.testing.allocator, parsed.value, "./blocked", .require, conditions));
    const literal = try resolveWithConditions(std.testing.allocator, parsed.value, "./literal", .require, &.{"first,second"});
    defer std.testing.allocator.free(literal);
    try std.testing.expectEqualStrings("literal.js", literal);
}
