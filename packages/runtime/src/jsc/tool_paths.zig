//! Runtime tsconfig paths using Home's owned JSONC/extends implementation.
const std = @import("std");
const config_graph = @import("tool_config_graph");
const tsconfig = @import("tsconfig");
const resolver = @import("ts_resolver");
const io = std.Io.Threaded.global_single_threaded.io();

const Disk = struct {
    invalid_source: bool = false,
    fn fs(self: *Disk) resolver.FileSystem {
        return .{ .ptr = self, .vtable = &.{ .fileExists = fileExists, .directoryExists = directoryExists, .readFile = readFile, .readDir = readDir, .realpath = realpath } };
    }
    fn fileExists(_: *anyopaque, path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
        return stat.kind == .file;
    }
    fn directoryExists(_: *anyopaque, path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
        return stat.kind == .directory;
    }
    fn readFile(pointer: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *Disk = @ptrCast(@alignCast(pointer));
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
        errdefer allocator.free(source);
        // ConfigGraph's compiler-facing parser can recover malformed JSONC.
        // Runtime lookup must reject it, including malformed inherited configs,
        // instead of executing against silently recovered path defaults.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = try tsconfig.parseString(allocator, arena.allocator(), source);
        var invalid = parsed.root_not_object or parsed.json_parse_diagnostics.len != 0;
        for (parsed.option_parse_diagnostics) |diagnostic| {
            if (diagnostic.code == 5063 or diagnostic.code == 5064 or
                std.mem.eql(u8, diagnostic.option, "paths") or
                std.mem.eql(u8, diagnostic.option, "baseUrl") or
                std.mem.eql(u8, diagnostic.option, "extends") or
                std.mem.eql(u8, diagnostic.option, "compilerOptions")) invalid = true;
        }
        if (invalid) {
            self.invalid_source = true;
            std.debug.print("home-tool tsconfig: invalid JSONC or runtime path options: {s}\n", .{path});
            return error.InvalidConfigSource;
        }
        return source;
    }
    fn readDir(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]resolver.FileSystem.DirEntry {
        var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer directory.close(io);
        var entries: std.ArrayListUnmanaged(resolver.FileSystem.DirEntry) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry.name);
            entries.deinit(allocator);
        }
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            const name = try allocator.dupe(u8, entry.name);
            entries.append(allocator, .{ .name = name, .is_dir = entry.kind == .directory }) catch |err| {
                allocator.free(name);
                return err;
            };
        }
        return entries.toOwnedSlice(allocator);
    }
    fn realpath(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
        defer allocator.free(canonical);
        return allocator.dupe(u8, canonical);
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    specifier: []const u8,
    importer: []const u8,
    try_path: *const fn (std.mem.Allocator, []const u8) ?[]u8,
) !?[]u8 {
    if (specifier.len == 0 or specifier[0] == '#' or specifier[0] == '/' or
        std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../")) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const parent = if (importer.len == 0) "." else std.fs.path.dirname(importer) orelse ".";
    const cwd = try std.process.currentPathAlloc(io, temporary);
    var directory: []const u8 = try std.fs.path.resolvePosix(temporary, &.{ cwd, parent });
    var disk: Disk = .{};
    while (true) {
        // Bun runtime aliases use the nearest config even for dependencies;
        // an installed package may supply its own config or inherit the app's.
        const path = try std.fs.path.join(temporary, &.{ directory, "tsconfig.json" });
        if (Disk.fileExists(&disk, path)) {
            const result = try config_graph.resolve(allocator, temporary, disk.fs(), path);
            if (result.failure) |failure| {
                if (disk.invalid_source) return error.InvalidRuntimeConfig;
                const message = try config_graph.formatFailure(temporary, failure);
                std.debug.print("home-tool tsconfig: {s}\n", .{message});
                return error.InvalidRuntimeConfig;
            }
            const config = result.config orelse return error.InvalidRuntimeConfig;
            const paths = config.compiler_options.paths orelse return null;
            // Exact keys precede wildcard keys. Among wildcard matches, prefer
            // the longest prefix, then longest suffix; retain source order on ties.
            var best: ?usize = null;
            var prefix_length: usize = 0;
            var suffix_length: usize = 0;
            var substitution: []const u8 = "";
            for (paths.patterns, 0..) |pattern, index| {
                if (std.mem.count(u8, pattern, "*") > 1) return error.UnsupportedPathsWildcard;
                const matched = resolver.matchPattern(pattern, specifier) orelse continue;
                const star = std.mem.indexOfScalar(u8, pattern, '*');
                if (star == null) {
                    best = index;
                    substitution = matched;
                    break;
                }
                const suffix = pattern.len - star.? - 1;
                if (best == null or star.? > prefix_length or (star.? == prefix_length and suffix > suffix_length)) {
                    best = index;
                    prefix_length = star.?;
                    suffix_length = suffix;
                    substitution = matched;
                }
            }
            const index = best orelse return null;
            const base = config.compiler_options.base_url orelse directory;
            for (paths.substitutions[index]) |target| {
                if (std.mem.count(u8, target, "*") > 1) return error.UnsupportedPathsWildcard;
                const expanded = if (std.mem.indexOfScalar(u8, target, '*')) |star|
                    try std.mem.concat(temporary, u8, &.{ target[0..star], substitution, target[star + 1 ..] })
                else
                    target;
                const candidate = try std.fs.path.resolve(temporary, &.{ base, expanded });
                if (try_path(allocator, candidate)) |found| {
                    if (std.mem.endsWith(u8, found, ".d.ts") or std.mem.endsWith(u8, found, ".d.mts") or std.mem.endsWith(u8, found, ".d.cts")) {
                        allocator.free(found);
                        return error.UnsupportedDeclarationAlias;
                    }
                    return found;
                }
            }
            return null;
        }
        const next = std.fs.path.dirname(directory) orelse return null;
        if (std.mem.eql(u8, next, directory)) return null;
        directory = next;
    }
}
