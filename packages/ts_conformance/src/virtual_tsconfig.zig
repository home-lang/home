//! Resolve the `tsconfig.json` graph embedded in a TypeScript harness fixture.
//!
//! The upstream runner mounts every `@filename:` section in a virtual file
//! system and asks the normal config parser to expand `extends`.  Keeping this
//! adapter separate from the conformance runner makes the input boundary
//! explicit: compiler options come from the mounted config graph, never from
//! expected diagnostics.

const std = @import("std");
const ts_resolver = @import("ts_resolver");
const config_graph = @import("ts_program").config_graph;

pub const File = struct {
    path: []const u8,
    source: []const u8,
};

pub const Failure = config_graph.Failure;
pub const Resolution = config_graph.Resolution;
pub const formatFailure = config_graph.formatFailure;

/// Resolve the first virtual file whose basename is `tsconfig.json`, matching
/// the compiler-runner fixture contract. Returned strings and config slices
/// borrow from `arena`.
pub fn resolveRoot(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    files: []const File,
) !Resolution {
    var root_path: ?[]const u8 = null;
    for (files) |file| {
        const canonical = try config_graph.canonicalPath(arena, file.path);
        if (std.ascii.eqlIgnoreCase(std.fs.path.basename(canonical), "tsconfig.json")) {
            root_path = canonical;
            break;
        }
    }
    if (root_path == null) return .{};

    var vfs = ts_resolver.VirtualFs.init(gpa);
    defer vfs.deinit();
    for (files) |file| {
        const canonical = try config_graph.canonicalPath(arena, file.path);
        try vfs.addFile(canonical, file.source);
    }
    return config_graph.resolve(gpa, arena, vfs.fs(), root_path.?);
}

const T = std.testing;

test "virtual tsconfig: extends arrays merge left to right before the child" {
    const files = [_]File{
        .{ .path = "/tsconfig1.json", .source = "{\"compilerOptions\":{\"strictNullChecks\":true,\"noImplicitAny\":false}}" },
        .{ .path = "/tsconfig2.json", .source = "{\"compilerOptions\":{\"noImplicitAny\":true}}" },
        .{ .path = "/tsconfig.json", .source = "{\"extends\":[\"./tsconfig1.json\",\"./tsconfig2.json\"]}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.strict_null_checks);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.no_implicit_any);
}

test "virtual tsconfig: explicit undefined options clear inherited values" {
    const files = [_]File{
        .{
            .path = "/base.json",
            .source =
            \\{
            \\  "compilerOptions": {
            \\    "allowJs": true,
            \\    "baseUrl": "./base",
            \\    "paths": { "pkg": ["src/pkg"] },
            \\    "types": ["node"],
            \\    "noImplicitAny": true
            \\  }
            \\}
            ,
        },
        .{
            .path = "/tsconfig.json",
            .source =
            \\{
            \\  "extends": "./base.json",
            \\  "compilerOptions": {
            \\    "allowJs": null,
            \\    "baseUrl": null,
            \\    "paths": null,
            \\    "types": null,
            \\    "noImplicitAny": null
            \\  }
            \\}
            ,
        },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    const options = resolved.config.?.compiler_options;
    try T.expectEqual(@as(?bool, null), options.allow_js);
    try T.expect(options.base_url == null);
    try T.expect(options.paths == null);
    try T.expect(options.types == null);
    try T.expectEqual(@as(?bool, null), options.no_implicit_any);
}

test "virtual tsconfig: inherited file specs stay relative to their declaring config" {
    const files = [_]File{
        .{ .path = "/base/tsconfig.base.json", .source = "{\"files\":[\"src/a.ts\"],\"include\":[\"generated/**/*\"]}" },
        .{ .path = "/project/tsconfig.json", .source = "{\"extends\":\"../base/tsconfig.base.json\"}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqualStrings("../base/src/a.ts", resolved.config.?.files.?[0]);
    try T.expectEqualStrings("../base/generated/**/*", resolved.config.?.include.?[0]);
}

test "virtual tsconfig: package exports wildcards resolve config bases" {
    const files = [_]File{
        .{ .path = "/node_modules/foo/package.json", .source = "{\"name\":\"foo\",\"exports\":{\"./*.json\":\"./configs/*.json\"}}" },
        .{ .path = "/node_modules/foo/configs/strict.json", .source = "{\"compilerOptions\":{\"strict\":true}}" },
        .{ .path = "/tsconfig.json", .source = "{\"extends\":\"foo/strict.json\"}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.strict);
}

test "virtual tsconfig: package tsconfig fields and defaults resolve config bases" {
    const files = [_]File{
        .{ .path = "/tsconfig.json", .source = "{\"extends\":[\"field\",\"default\"]}" },
        .{ .path = "/node_modules/field/package.json", .source = "{\"tsconfig\":\"./configs/base.json\"}" },
        .{ .path = "/node_modules/field/configs/base.json", .source = "{\"compilerOptions\":{\"strictNullChecks\":true}}" },
        .{ .path = "/node_modules/default/package.json", .source = "{\"name\":\"default\"}" },
        .{ .path = "/node_modules/default/tsconfig.json", .source = "{\"compilerOptions\":{\"noImplicitAny\":true}}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.strict_null_checks);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.no_implicit_any);
}

test "virtual tsconfig: missing and circular parents are retained failures" {
    const missing_files = [_]File{
        .{ .path = "/tsconfig.json", .source = "{\"extends\":\"./missing.json\"}" },
    };
    var missing_arena = std.heap.ArenaAllocator.init(T.allocator);
    defer missing_arena.deinit();
    const missing = try resolveRoot(T.allocator, missing_arena.allocator(), &missing_files);
    try T.expectEqual(Failure.Kind.missing, missing.failure.?.kind);

    const circular_files = [_]File{
        .{ .path = "/base.json", .source = "{\"extends\":\"./tsconfig.json\"}" },
        .{ .path = "/tsconfig.json", .source = "{\"extends\":\"./base.json\"}" },
    };
    var circular_arena = std.heap.ArenaAllocator.init(T.allocator);
    defer circular_arena.deinit();
    const circular = try resolveRoot(T.allocator, circular_arena.allocator(), &circular_files);
    try T.expectEqual(Failure.Kind.circular, circular.failure.?.kind);
}

test "virtual tsconfig: inherited paths retain the base config directory" {
    const files = [_]File{
        .{ .path = "/other/tsconfig.base.json", .source = "{\"compilerOptions\":{\"paths\":{\"p1\":[\"./lib/p1\"]}}}" },
        .{ .path = "/project/tsconfig.json", .source = "{\"extends\":\"../other/tsconfig.base.json\"}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqualStrings("/other", resolved.config.?.compiler_options.base_url.?);
    try T.expectEqualStrings("p1", resolved.config.?.compiler_options.paths.?.patterns[0]);
}
