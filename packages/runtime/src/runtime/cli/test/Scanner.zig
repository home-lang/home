const Scanner = @This();

/// Memory is borrowed.
exclusion_names: []const []const u8 = &.{},
/// When this list is empty, no filters are applied.
/// "test" suffixes (e.g. .spec.*) are always applied when traversing directories.
filter_names: []const []const u8 = &.{},
/// Glob patterns for paths to ignore. Matched against the path relative to the
/// project root (top_level_dir). When a file matches any pattern, it is excluded.
path_ignore_patterns: []const []const u8 = &.{},
dirs_to_scan: Fifo,
/// Paths to test files found while scanning.
test_files: std.ArrayListUnmanaged(bun.PathString),
fs: *FileSystem,
open_dir_buf: bun.PathBuffer = undefined,
scan_dir_buf: bun.PathBuffer = undefined,
options: *BundleOptions,
has_iterated: bool = false,
search_count: usize = 0,

const log = bun.Output.scoped(.jest, .hidden);
const Fifo = bun.LinearFifo(ScanEntry, .Dynamic);
const ScanEntry = struct {
    dir_path: []const u8,
    name: StringOrTinyString,
};
const Error = error{
    /// Scan entrypoint file/directory does not exist. Not returned when
    /// a subdirectory is scanned but does not exist.
    DoesNotExist,
} || Allocator.Error;

pub fn init(
    alloc: Allocator,
    transpiler: *Transpiler,
    initial_results_capacity: usize,
) Allocator.Error!Scanner {
    const results = try std.ArrayListUnmanaged(bun.PathString).initCapacity(
        alloc,
        initial_results_capacity,
    );
    return Scanner{
        .dirs_to_scan = Fifo.init(alloc),
        .options = &transpiler.options,
        .fs = transpiler.fs,
        .test_files = results,
    };
}

pub fn deinit(this: *Scanner) void {
    this.test_files.deinit(this.allocator());
    this.dirs_to_scan.deinit();
    this.* = undefined;
}

/// Take the list of test files out of this scanner. Caller owns the returned
/// allocation.
pub fn takeFoundTestFiles(this: *Scanner) Allocator.Error![]bun.PathString {
    return this.test_files.toOwnedSlice(this.allocator());
}

pub fn scan(this: *Scanner, path_literal: []const u8) Error!void {
    const parts = &[_][]const u8{ this.fs.top_level_dir, path_literal };
    const path = this.fs.absBuf(parts, &this.scan_dir_buf);

    var root = try this.readDirWithName(path);

    if (root.* == .err) {
        switch (root.err.original_err) {
            error.NotDir, error.ENOTDIR => {
                if (this.isTestFile(path)) {
                    const rel_path = bun.PathString.init(bun.handleOom(this.fs.filename_store.append([]const u8, path)));
                    bun.handleOom(this.test_files.append(this.allocator(), rel_path));
                }
            },
            error.ENOENT => return error.DoesNotExist,
            else => log("Scanner.readDirWithName('{s}') -> {s}", .{ path, @errorName(root.err.original_err) }),
        }
    }

    // you typed "." and we already scanned it
    if (!this.has_iterated) {
        if (@as(FileSystem.RealFS.EntriesOption.Tag, root.*) == .entries) {
            var iter = root.entries.data.iterator();
            const fd = root.entries.fd;
            while (iter.next()) |entry| {
                this.next(entry.value_ptr.*, fd);
            }
        }
    }

    while (this.dirs_to_scan.readItem()) |entry| {
        const parts2 = &[_][]const u8{ entry.dir_path, entry.name.slice() };
        const path2 = try this.fs.dirname_store.append(
            []const u8,
            this.fs.absBuf(parts2, &this.open_dir_buf),
        );
        const child = this.readDirWithName(path2) catch return error.OutOfMemory;
        // Cache hits do not invoke the iterator. Visit their stored entries too.
        if (!this.has_iterated and child.* == .entries) {
            var iter = child.entries.data.iterator();
            while (iter.next()) |item| this.next(item.value_ptr.*, child.entries.fd);
        }
    }
}

fn readDirWithName(this: *Scanner, name: []const u8) !*FileSystem.RealFS.EntriesOption {
    this.has_iterated = false;
    // Queued entries own paths, so discovery does not need to retain directory
    // descriptors in the resolver cache after reading their entries.
    return try this.fs.fs.readDirectoryWithIterator(name, null, 0, false, *Scanner, this);
}

/// Package directories and hidden directories are excluded from discovery.
pub fn isExcludedDirName(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    return strings.eqlComptime(name, "node_modules") or
        strings.eqlComptime(name, "pantry");
}

pub const test_name_suffixes = [_][]const u8{
    ".test",
    "_test",
    ".spec",
    "_spec",
};

pub fn couldBeTestFile(this: *Scanner, name: []const u8, comptime needs_test_suffix: bool) bool {
    const extname = std.fs.path.extension(name);
    if (extname.len == 0 or !this.options.loader(extname).isJavaScriptLike()) return false;
    if (comptime !needs_test_suffix) return true;
    const name_without_extension = name[0 .. name.len - extname.len];
    inline for (test_name_suffixes) |suffix| {
        if (strings.endsWithComptime(name_without_extension, suffix)) return true;
    }

    return false;
}

pub fn doesAbsolutePathMatchFilter(this: *Scanner, name: []const u8) bool {
    if (this.filter_names.len == 0) return true;

    for (this.filter_names) |filter_name| {
        if (strings.startsWith(name, filter_name)) return true;
    }

    return false;
}

pub fn doesPathMatchFilter(this: *Scanner, name: []const u8) bool {
    if (this.filter_names.len == 0) return true;

    for (this.filter_names) |filter_name| {
        if (strings.contains(name, filter_name)) return true;
    }

    return false;
}

/// Returns true if the given path matches any of the path ignore patterns.
/// The path is matched as a relative path from the project root.
pub fn matchesPathIgnorePattern(this: *Scanner, abs_path: []const u8) bool {
    if (this.path_ignore_patterns.len == 0) return false;
    const rel_path = bun.path.relative(this.fs.top_level_dir, abs_path);

    // Build rel_path + '/' once. rel_path is a relative path from the project
    // root; 4096 bytes covers any sane test directory depth (POSIX PATH_MAX).
    var buf: [4096]u8 = undefined;
    const rel_with_slash: ?[]const u8 = if (rel_path.len > 0 and
        rel_path.len + 1 <= buf.len and
        rel_path[rel_path.len - 1] != '/')
    blk: {
        @memcpy(buf[0..rel_path.len], rel_path);
        buf[rel_path.len] = '/';
        break :blk buf[0 .. rel_path.len + 1];
    } else null;

    for (this.path_ignore_patterns) |pattern| {
        if (bun.glob.match(pattern, rel_path).matches()) return true;
        // Only try trailing separator for ** patterns (e.g. "vendor/**").
        // Single-star patterns like "vendor/*" must not prune entire
        // directories because * doesn't cross directory boundaries.
        if (rel_with_slash) |p| {
            if (strings.indexOf(pattern, "**") != null) {
                if (bun.glob.match(pattern, p).matches()) return true;
            }
        }
    }
    return false;
}

pub fn isTestFile(this: *Scanner, name: []const u8) bool {
    return this.couldBeTestFile(name, false) and this.doesPathMatchFilter(name) and !this.matchesPathIgnorePattern(name);
}

pub fn next(this: *Scanner, entry: *FileSystem.Entry, _: bun.FD) void {
    const name = entry.base_lowercase();
    this.has_iterated = true;
    switch (entry.kind(&this.fs.fs, false)) {
        .dir => {
            if (isExcludedDirName(name)) {
                return;
            }

            if (comptime bun.Environment.allow_assert)
                bun.assert(!strings.contains(name, std.fs.path.sep_str ++ "node_modules" ++ std.fs.path.sep_str));

            for (this.exclusion_names) |exclude_name| {
                if (strings.eql(exclude_name, name)) return;
            }

            // Prune ignored directory trees early so we never traverse them.
            if (this.path_ignore_patterns.len > 0) {
                const parts = &[_][]const u8{ entry.dir, entry.base() };
                const dir_path = this.fs.absBuf(parts, &this.open_dir_buf);
                if (this.matchesPathIgnorePattern(dir_path)) return;
            }

            this.search_count += 1;

            this.dirs_to_scan.writeItem(.{
                .name = entry.base_,
                .dir_path = entry.dir,
            }) catch unreachable;
        },
        .file => {
            // already seen it!
            if (!entry.abs_path.isEmpty()) return;

            this.search_count += 1;
            if (!this.couldBeTestFile(name, true)) return;

            const parts = &[_][]const u8{ entry.dir, entry.base() };
            const path = this.fs.absBuf(parts, &this.open_dir_buf);

            if (!this.doesAbsolutePathMatchFilter(path)) {
                const rel_path = bun.path.relative(this.fs.top_level_dir, path);
                if (!this.doesPathMatchFilter(rel_path)) return;
            }

            if (this.matchesPathIgnorePattern(path)) return;

            entry.abs_path = bun.PathString.init(this.fs.filename_store.append(@TypeOf(path), path) catch unreachable);
            this.test_files.append(this.allocator(), entry.abs_path) catch unreachable;
        },
    }
}

inline fn allocator(self: *const Scanner) Allocator {
    return self.dirs_to_scan.allocator;
}

const std = @import("std");
const BundleOptions = @import("../../../bundler/options.zig").BundleOptions;
const Allocator = std.mem.Allocator;

const bun = @import("home");
const Transpiler = bun.Transpiler;
const FileSystem = bun.fs.FileSystem;

const jsc = bun.jsc;
const jest = jsc.Jest;

const strings = bun.strings;
const StringOrTinyString = strings.StringOrTinyString;

test "isExcludedDirName: prunes dependency and dotfile trees" {
    const testing = std.testing;
    // Dependency directories: upstream node_modules + Home's pantry.
    try testing.expect(isExcludedDirName("node_modules"));
    try testing.expect(isExcludedDirName("pantry"));
    // Any dot-prefixed directory (.git, .zig-cache, .native, .hidden).
    try testing.expect(isExcludedDirName(".git"));
    try testing.expect(isExcludedDirName(".zig-cache"));
    try testing.expect(isExcludedDirName("."));
}

test "isExcludedDirName: keeps ordinary source directories" {
    const testing = std.testing;
    try testing.expect(!isExcludedDirName("packages"));
    try testing.expect(!isExcludedDirName("src"));
    try testing.expect(!isExcludedDirName("tests"));
    // Substring / prefix matches must not trigger exclusion — only exact names.
    try testing.expect(!isExcludedDirName("pantry-utils"));
    try testing.expect(!isExcludedDirName("my_node_modules"));
    try testing.expect(!isExcludedDirName("node_modules_old"));
    // A bare empty name is not a dotfile and not a dependency dir.
    try testing.expect(!isExcludedDirName(""));
}
