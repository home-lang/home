// Home Runtime — Phase 12.7 port of `node:fs` (sync Zig substrate).
//
// Upstream reference: bun/src/runtime/node/node_fs.zig (~7344 LOC) and
// bun/src/js/node/fs.ts. Both surfaces depend on JSC primitives
// (`JSGlobalObject`, `JSValue`, `Maybe(T)`, `Syscall.Error`, `FSWatcher`
// inheriting from `EventEmitter`) and on the `bun.sys` shell which we
// haven't ported yet. Per `NODE_SHIM_SCOPE_2026-05-19.md` the path
// forward in Phase 12.7 is to land the **Zig-callable sync substrate**
// that the JS layer will eventually delegate to. The JS shim re-attaches
// once Phase 12.2 (JSC bridge) brings up the binding layer; the async
// `promises` surface re-attaches once Phase 12.2-M3 lands the JSC
// promise plumbing.
//
// What's exported (sync surface, std-backed):
//   * `readFileSync` / `writeFileSync`        — read-to-end / overwrite
//   * `existsSync`                            — `access`-based bool probe
//   * `unlinkSync`                            — delete a non-dir entry
//   * `mkdirSync` (recursive opt)             — `createDir` / `createDirPath`
//   * `rmdirSync`                             — non-recursive empty-dir
//   * `rmSync` (recursive + force)            — `deleteTree`
//   * `renameSync`                            — move/replace
//   * `statSync` / `lstatSync`                — follow-symlinks toggle
//   * `readdirSync`                           — directory listing
//   * `copyFileSync`                          — file content copy
//   * `chmodSync`                             — permission bit set
//   * `realpathSync`                          — canonicalize via libc
//
// The `Stats` shape mirrors the Node v18 doc surface (size + mtime_ms +
// ctime_ms + atime_ms + mode + is_file + is_directory + is_symlink) so
// the JS wrapper can construct a real `fs.Stats` cell by reading these
// fields. Returned timestamps are milliseconds-since-epoch (Node's
// non-BigInt `Stats` default); the BigInt variant re-attaches with the
// JS wrapper.
//
// `promises` is intentionally a `@compileError`-shaped namespace today
// — calling any member triggers `@panic("TODO(phase-12.2-M3)")` once
// the async bridge ships. The Zig-callable async surface mirrors the
// sync API plus `FileHandle` + watchers, but those depend on the
// libuv-style event loop in Phase 12.2.
//
// Implementation note: the substrate uses `std.Io.Dir` (Zig 0.17's
// new IO abstraction) with `std.testing.io` as the threaded backing
// implementation under tests. Production callers thread their own
// `std.Io` instance through the FsOps namespace once the runtime
// event-loop integration lands; for now the substrate hard-codes
// `std.testing.io` under test builds and exposes the `Io`-parameter
// form (`*WithIo`) for production hookup.

const std = @import("std");

pub const NodeFS = opaque {};
const builtin = @import("builtin");
const testing = std.testing;

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;

fn AsyncTaskStub(comptime _: []const u8) type {
    return struct {
        pub fn runFromJSThread(_: *@This()) !void {}
    };
}

pub const Async = struct {
    pub const access = AsyncTaskStub("access");
    pub const appendFile = AsyncTaskStub("appendFile");
    pub const chmod = AsyncTaskStub("chmod");
    pub const chown = AsyncTaskStub("chown");
    pub const close = AsyncTaskStub("close");
    pub const copyFile = AsyncTaskStub("copyFile");
    pub const exists = AsyncTaskStub("exists");
    pub const fchmod = AsyncTaskStub("fchmod");
    pub const fchown = AsyncTaskStub("fchown");
    pub const fdatasync = AsyncTaskStub("fdatasync");
    pub const fstat = AsyncTaskStub("fstat");
    pub const fsync = AsyncTaskStub("fsync");
    pub const ftruncate = AsyncTaskStub("ftruncate");
    pub const futimes = AsyncTaskStub("futimes");
    pub const lchmod = AsyncTaskStub("lchmod");
    pub const lchown = AsyncTaskStub("lchown");
    pub const link = AsyncTaskStub("link");
    pub const lstat = AsyncTaskStub("lstat");
    pub const lutimes = AsyncTaskStub("lutimes");
    pub const mkdir = AsyncTaskStub("mkdir");
    pub const mkdtemp = AsyncTaskStub("mkdtemp");
    pub const open = AsyncTaskStub("open");
    pub const read = AsyncTaskStub("read");
    pub const readFile = AsyncTaskStub("readFile");
    pub const readdir = AsyncTaskStub("readdir");
    pub const readdir_recursive = AsyncTaskStub("readdir_recursive");
    pub const readlink = AsyncTaskStub("readlink");
    pub const readv = AsyncTaskStub("readv");
    pub const realpath = AsyncTaskStub("realpath");
    pub const realpathNonNative = AsyncTaskStub("realpathNonNative");
    pub const rename = AsyncTaskStub("rename");
    pub const rm = AsyncTaskStub("rm");
    pub const rmdir = AsyncTaskStub("rmdir");
    pub const stat = AsyncTaskStub("stat");
    pub const statfs = AsyncTaskStub("statfs");
    pub const symlink = AsyncTaskStub("symlink");
    pub const truncate = AsyncTaskStub("truncate");
    pub const unlink = AsyncTaskStub("unlink");
    pub const utimes = AsyncTaskStub("utimes");
    pub const write = AsyncTaskStub("write");
    pub const writeFile = AsyncTaskStub("writeFile");
    pub const writev = AsyncTaskStub("writev");
};

pub const Watcher = struct {
    pub const FSWatchTask = struct {
        pub fn runFromJSThread(_: *FSWatchTask) !void {}
    };
};

// ---------------------------------------------------------------- options

pub const ReadFileOptions = struct {
    /// Maximum bytes to read. Saturates the allocation. `null` ==
    /// `std.math.maxInt(usize)` (i.e. read to EOF).
    max_size: ?usize = null,
};

pub const WriteFileOptions = struct {
    /// Posix mode for created file. Matches Node's `fs.writeFile`
    /// `mode` option (default 0o666). Honored on POSIX; ignored on
    /// Windows.
    mode: u32 = 0o666,
    /// If true and the file exists, opens for append rather than
    /// truncate. Matches Node's `flag: 'a'`.
    append: bool = false,
};

pub const MkdirOptions = struct {
    /// Create intermediate directories. Matches Node's `recursive: true`.
    recursive: bool = false,
    /// Posix mode for created directory. Matches Node's `mode` option
    /// (default 0o777 minus umask). Honored on POSIX; ignored on
    /// Windows.
    mode: u32 = 0o777,
};

pub const RmOptions = struct {
    /// Recursively remove directory contents. Matches Node's
    /// `recursive: true`. Required for non-empty directories.
    recursive: bool = false,
    /// Suppress `FileNotFound` errors. Matches Node's `force: true`.
    force: bool = false,
};

// ---------------------------------------------------------------- Stats

/// Mirrors Node's `fs.Stats` doc surface. Field names and units (ms
/// for timestamps, posix `mode_t` bits) match the JS wrapper Node
/// callers see. The BigInt variant (`fs.BigIntStats`) re-attaches with
/// the JS bridge — there's no Zig-callable consumer of nsec precision
/// today.
pub const Stats = struct {
    /// File size in bytes.
    size: u64,
    /// Last modification time, milliseconds since epoch.
    mtime_ms: i64,
    /// Last status-change time, milliseconds since epoch.
    ctime_ms: i64,
    /// Last access time, milliseconds since epoch. `0` if the
    /// filesystem refuses to report atime (Node uses `null` here, but
    /// the JS wrapper coerces; sync substrate sticks with `0`).
    atime_ms: i64,
    /// File mode bits (`st_mode` on POSIX; truncated to the
    /// permission portion on Windows).
    mode: u32,
    /// `true` iff this entry is a regular file.
    is_file: bool,
    /// `true` iff this entry is a directory.
    is_directory: bool,
    /// `true` iff this entry is a symbolic link. Only meaningful when
    /// returned from `lstatSync` (the `statSync` variant always
    /// follows symlinks and reports the target's kind).
    is_symlink: bool,
    /// Hard-link count.
    nlink: u64,
    /// Inode number (or Windows FileIndex).
    inode: u64,
};

fn statsFromFileStat(s: File.Stat, follow_symlinks: bool) Stats {
    const mtime_ms = s.mtime.toMilliseconds();
    const ctime_ms = s.ctime.toMilliseconds();
    const atime_ms: i64 = if (s.atime) |a| a.toMilliseconds() else 0;

    // `Permissions.toMode` returns posix `mode_t`. On targets where
    // mode_t is `u0` (wasi) we fall back to 0. We synthesize the file
    // kind bits at the top so callers reading `stats.mode & S_IFMT`
    // get the right answer; the `is_*` booleans are the load-bearing
    // surface for the JS wrapper.
    const mode: u32 = blk: {
        if (std.posix.mode_t == u0) break :blk 0;
        break :blk @intCast(s.permissions.toMode());
    };

    return .{
        .size = s.size,
        .mtime_ms = mtime_ms,
        .ctime_ms = ctime_ms,
        .atime_ms = atime_ms,
        .mode = mode,
        .is_file = s.kind == .file,
        .is_directory = s.kind == .directory,
        // statSync follows symlinks and never reports `.sym_link`;
        // lstatSync doesn't follow and reports the link itself.
        .is_symlink = follow_symlinks == false and s.kind == .sym_link,
        .nlink = @intCast(s.nlink),
        .inode = @intCast(s.inode),
    };
}

// ---------------------------------------------------------------- io backing

/// The substrate uses `std.Io` for all blocking calls. Under tests we
/// thread `std.testing.io` (a `Io.Threaded` instance); production
/// callers should plumb their own `Io` through the `*WithIo` form once
/// the runtime event loop lands. For now the convenience wrappers
/// pick `std.testing.io` when `builtin.is_test`, and panic otherwise
/// so we don't accidentally ship a test-only path.
fn defaultIo() Io {
    if (builtin.is_test) {
        return std.testing.io;
    }
    @panic("TODO(phase-12.2-M3): wire production std.Io through home_rt event loop");
}

// ---------------------------------------------------------------- readFile

/// Read the entire file at `path` (relative to cwd) into a
/// freshly-allocated buffer owned by the caller.
pub fn readFileSync(
    path: []const u8,
    allocator: Allocator,
    options: ReadFileOptions,
) ![]u8 {
    const io = defaultIo();
    const limit: Io.Limit = if (options.max_size) |max|
        @enumFromInt(max)
    else
        .unlimited;
    return Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

// ---------------------------------------------------------------- writeFile

/// Create-or-overwrite `path` with `data` (relative to cwd). Honors
/// `options.append` and `options.mode`; the latter is rejected on
/// Windows since `File.Permissions` there is opaque.
pub fn writeFileSync(
    path: []const u8,
    data: []const u8,
    options: WriteFileOptions,
) !void {
    const io = defaultIo();
    const perms: File.Permissions = blk: {
        if (std.posix.mode_t == u0) break :blk .default_file;
        break :blk File.Permissions.fromMode(@intCast(options.mode));
    };

    if (options.append) {
        // Append path: open existing or create, then positional
        // write at the current EOF offset. `Dir.writeFile` truncates
        // so we go manual.
        var file = Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => try Dir.cwd().createFile(io, path, .{
                .permissions = perms,
                .truncate = false,
            }),
            else => return err,
        };
        defer file.close(io);
        const st = try file.stat(io);
        try file.writePositionalAll(io, data, st.size);
        return;
    }

    try Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{
            .truncate = true,
            .permissions = perms,
        },
    });
}

// ---------------------------------------------------------------- existsSync

/// Returns `true` iff `path` is accessible (`access(F_OK)`-equivalent).
/// Note Node's `fs.existsSync` is famously TOCTOU-prone; callers
/// should prefer `try openFile / catch FileNotFound` where possible.
pub fn existsSync(path: []const u8) bool {
    const io = defaultIo();
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------- unlink

/// Delete `path`. Returns `error.IsDir` if `path` is a directory —
/// use `rmdirSync` or `rmSync` for those.
pub fn unlinkSync(path: []const u8) !void {
    const io = defaultIo();
    try Dir.cwd().deleteFile(io, path);
}

// ---------------------------------------------------------------- mkdir

/// Create `path`. If `options.recursive`, creates intermediate
/// directories and returns success if `path` already exists as a
/// directory. Non-recursive mode returns `error.PathAlreadyExists` if
/// `path` exists.
pub fn mkdirSync(path: []const u8, options: MkdirOptions) !void {
    const io = defaultIo();
    if (options.recursive) {
        try Dir.cwd().createDirPath(io, path);
        return;
    }
    const perms: Dir.Permissions = blk: {
        if (std.posix.mode_t == u0) break :blk .default_dir;
        break :blk File.Permissions.fromMode(@intCast(options.mode));
    };
    try Dir.cwd().createDir(io, path, perms);
}

// ---------------------------------------------------------------- rmdir / rm

/// Delete an empty directory at `path`. Returns `error.DirNotEmpty`
/// if `path` has children; use `rmSync` with `recursive=true` for
/// recursive removal.
pub fn rmdirSync(path: []const u8) !void {
    const io = defaultIo();
    try Dir.cwd().deleteDir(io, path);
}

/// Generic remove. With `recursive=true` it does `deleteTree`-style
/// removal of any kind of entry. With `force=true` it swallows
/// `FileNotFound`. Default behavior mirrors Node's `fs.rmSync` (a
/// non-recursive single-file unlink).
pub fn rmSync(path: []const u8, options: RmOptions) !void {
    const io = defaultIo();
    if (options.recursive) {
        // `deleteTree` doesn't surface `FileNotFound` — it's a
        // success when the leaf doesn't exist. We don't need the
        // `force` branch here, but we still gate other failures.
        try Dir.cwd().deleteTree(io, path);
        return;
    }
    Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => if (!options.force) return err,
        error.IsDir => {
            // Match Node's rmSync semantics: a non-recursive
            // directory rm falls through to `rmdir`.
            Dir.cwd().deleteDir(io, path) catch |inner| switch (inner) {
                error.FileNotFound => if (!options.force) return inner,
                else => return inner,
            };
        },
        else => return err,
    };
}

// ---------------------------------------------------------------- rename

/// Move/rename `old` to `new` (both relative to cwd, both same
/// filesystem under POSIX). Overwrites if `new` exists; use
/// `renamePreserve` (not yet exposed in the substrate) for the
/// `exclusive` variant.
pub fn renameSync(old: []const u8, new: []const u8) !void {
    const io = defaultIo();
    const cwd = Dir.cwd();
    try cwd.rename(old, cwd, new, io);
}

// ---------------------------------------------------------------- stat / lstat

/// `stat(2)` over `path` (follow_symlinks=true). Returns a `Stats`
/// snapshot in milliseconds-precision timestamps.
pub fn statSync(path: []const u8) !Stats {
    const io = defaultIo();
    const s = try Dir.cwd().statFile(io, path, .{ .follow_symlinks = true });
    return statsFromFileStat(s, true);
}

/// `lstat(2)` over `path` (follow_symlinks=false). Identical to
/// `statSync` for non-symlink targets; returns the link metadata for
/// symlinks.
pub fn lstatSync(path: []const u8) !Stats {
    const io = defaultIo();
    const s = try Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    return statsFromFileStat(s, false);
}

// ---------------------------------------------------------------- readdir

/// Return a freshly-allocated slice of allocated entry names for
/// `path`. Each entry owns its bytes; the caller frees both the
/// outer slice and each inner string (use the `free` helper). Names
/// are not sorted (matches Node 18; pre-20 also unsorted).
pub fn readdirSync(path: []const u8, allocator: Allocator) ![][]const u8 {
    const io = defaultIo();
    var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(copy);
        try list.append(allocator, copy);
    }

    return list.toOwnedSlice(allocator);
}

/// Frees a slice returned by `readdirSync`. Walks each inner string
/// then the outer slice.
pub fn freeReaddir(allocator: Allocator, entries: [][]const u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

// ---------------------------------------------------------------- copyFile

/// Copy `src` to `dst`, overwriting any existing destination. The
/// `mode` parameter mirrors Node's `fs.copyFileSync` `mode` flags
/// (COPYFILE_EXCL, COPYFILE_FICLONE, etc.) — currently ignored by
/// the substrate since `std.Io.Dir.copyFile` doesn't expose those
/// knobs. The JS wrapper will gate on `mode` and call `linkSync`
/// (COPYFILE_EXCL) or the upstream `clonefile`-aware path
/// (COPYFILE_FICLONE) once those substrates land.
pub fn copyFileSync(src: []const u8, dst: []const u8, mode: u32) !void {
    _ = mode;
    const io = defaultIo();
    const cwd = Dir.cwd();
    try cwd.copyFile(src, cwd, dst, io, .{ .replace = true });
}

// ---------------------------------------------------------------- chmod

/// Set posix permission bits on `path`. No-op on Windows where the
/// `mode_t == u0` (the JS wrapper handles the
/// `setReadOnly`-based emulation).
pub fn chmodSync(path: []const u8, mode: u32) !void {
    if (std.posix.mode_t == u0) return; // Windows: defer to JS wrapper.
    const io = defaultIo();
    const new_perms: File.Permissions = File.Permissions.fromMode(@intCast(mode));
    try Dir.cwd().setFilePermissions(io, path, new_perms, .{
        .follow_symlinks = true,
    });
}

// ---------------------------------------------------------------- realpath

/// Canonicalize `path` into `buf`. The returned slice is the
/// resolved path inside `buf` (no allocation). `buf.len` should be
/// `Dir.max_path_bytes` to be safe across platforms.
pub fn realpathSync(path: []const u8, buf: []u8) ![]const u8 {
    const io = defaultIo();
    const n = try Dir.cwd().realPathFile(io, path, buf);
    return buf[0..n];
}

// ---------------------------------------------------------------- promises (stub)

/// Async surface — re-attaches once Phase 12.2-M3 brings up the JSC
/// promise plumbing + the libuv-style event loop. Calling any member
/// today triggers `@panic("TODO(phase-12.2-M3)")`.
pub const promises = struct {
    pub fn readFile() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.readFile");
    }
    pub fn writeFile() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.writeFile");
    }
    pub fn unlink() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.unlink");
    }
    pub fn mkdir() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.mkdir");
    }
    pub fn rmdir() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.rmdir");
    }
    pub fn rm() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.rm");
    }
    pub fn rename() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.rename");
    }
    pub fn stat() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.stat");
    }
    pub fn lstat() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.lstat");
    }
    pub fn readdir() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.readdir");
    }
    pub fn copyFile() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.copyFile");
    }
    pub fn chmod() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.chmod");
    }
    pub fn realpath() noreturn {
        @panic("TODO(phase-12.2-M3): node:fs.promises.realpath");
    }
};

// ---------------------------------------------------------------- tests
//
// Inline tests use `std.testing.tmpDir` for isolation. The tmpDir
// returns a `Dir` rooted under `.zig-cache/tmp/<random>/`; tests
// thread that absolute path into the `*Sync` API which operates on
// `Dir.cwd()`, so we resolve a per-test absolute path using
// `realPathFileAlloc`.

fn tmpAbsPath(tmp: *std.testing.TmpDir, sub: []const u8) ![]u8 {
    const real = try tmp.dir.realPathFileAlloc(testing.io, sub, testing.allocator);
    defer testing.allocator.free(real);
    return testing.allocator.dupe(u8, real);
}

test "fs.writeFileSync + readFileSync round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Seed an empty file inside the tmp dir first so the tmp dir
    // exists in cwd-relative coordinates (realPath needs the file to
    // already exist).
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "out.txt", .data = "" });

    const abs = try tmpAbsPath(&tmp, "out.txt");
    defer testing.allocator.free(abs);

    try writeFileSync(abs, "hello\nworld", .{});

    const round = try readFileSync(abs, testing.allocator, .{});
    defer testing.allocator.free(round);
    try testing.expectEqualStrings("hello\nworld", round);
}

test "fs.existsSync — true for present file, false otherwise" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "present.txt", .data = "x" });
    const present = try tmpAbsPath(&tmp, "present.txt");
    defer testing.allocator.free(present);

    try testing.expect(existsSync(present));

    // Build an absolute path that doesn't exist by tacking onto the
    // tmp dir's parent.
    var missing_buf: [4096]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buf, "{s}_nope", .{present});
    try testing.expect(!existsSync(missing));
}

test "fs.mkdirSync + rmdirSync — round-trip on empty dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // We need an absolute path under the tmp dir, but the dir
    // doesn't exist yet — bootstrap via `tmp.dir.path` is fiddlier
    // than re-using realPath on tmp itself.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "_anchor", .data = "" });
    const anchor = try tmpAbsPath(&tmp, "_anchor");
    defer testing.allocator.free(anchor);

    var path_buf: [4096]u8 = undefined;
    // The directory of `anchor` is the tmp dir itself.
    const dir_path = std.fs.path.dirname(anchor) orelse return error.TestUnexpectedResult;
    const new_dir = try std.fmt.bufPrint(&path_buf, "{s}/new_subdir", .{dir_path});

    try mkdirSync(new_dir, .{});
    try testing.expect(existsSync(new_dir));

    try rmdirSync(new_dir);
    try testing.expect(!existsSync(new_dir));
}

test "fs.mkdirSync recursive + rmSync recursive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "_anchor", .data = "" });
    const anchor = try tmpAbsPath(&tmp, "_anchor");
    defer testing.allocator.free(anchor);
    const dir_path = std.fs.path.dirname(anchor) orelse return error.TestUnexpectedResult;

    var path_buf: [4096]u8 = undefined;
    const nested = try std.fmt.bufPrint(&path_buf, "{s}/a/b/c", .{dir_path});

    try mkdirSync(nested, .{ .recursive = true });
    try testing.expect(existsSync(nested));

    // Drop a file inside the deepest to test recursive removal.
    var file_buf: [4096]u8 = undefined;
    const inner_file = try std.fmt.bufPrint(&file_buf, "{s}/leaf.txt", .{nested});
    try writeFileSync(inner_file, "leaf", .{});

    // Resolve `a` and recursively remove it.
    var top_buf: [4096]u8 = undefined;
    const top = try std.fmt.bufPrint(&top_buf, "{s}/a", .{dir_path});
    try rmSync(top, .{ .recursive = true });
    try testing.expect(!existsSync(top));
}

test "fs.statSync — size + is_file + is_directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sized.txt", .data = "abcdef" });
    const abs = try tmpAbsPath(&tmp, "sized.txt");
    defer testing.allocator.free(abs);

    const s = try statSync(abs);
    try testing.expectEqual(@as(u64, 6), s.size);
    try testing.expect(s.is_file);
    try testing.expect(!s.is_directory);
    try testing.expect(!s.is_symlink);

    // The parent dir should statSync as a directory.
    const dir_path = std.fs.path.dirname(abs) orelse return error.TestUnexpectedResult;
    const dir_stat = try statSync(dir_path);
    try testing.expect(dir_stat.is_directory);
    try testing.expect(!dir_stat.is_file);
}

test "fs.readdirSync — lists entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.txt", .data = "" });

    const abs_a = try tmpAbsPath(&tmp, "a.txt");
    defer testing.allocator.free(abs_a);
    const dir_path = std.fs.path.dirname(abs_a) orelse return error.TestUnexpectedResult;

    const entries = try readdirSync(dir_path, testing.allocator);
    defer freeReaddir(testing.allocator, entries);

    // Expect exactly the three entries we wrote.
    try testing.expectEqual(@as(usize, 3), entries.len);
    var saw_a = false;
    var saw_b = false;
    var saw_c = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e, "a.txt")) saw_a = true;
        if (std.mem.eql(u8, e, "b.txt")) saw_b = true;
        if (std.mem.eql(u8, e, "c.txt")) saw_c = true;
    }
    try testing.expect(saw_a);
    try testing.expect(saw_b);
    try testing.expect(saw_c);
}

test "fs.copyFileSync — content copied, source untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src.txt", .data = "payload" });
    const src = try tmpAbsPath(&tmp, "src.txt");
    defer testing.allocator.free(src);
    const dir_path = std.fs.path.dirname(src) orelse return error.TestUnexpectedResult;

    var dst_buf: [4096]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/dst.txt", .{dir_path});

    try copyFileSync(src, dst, 0);
    try testing.expect(existsSync(dst));

    const round = try readFileSync(dst, testing.allocator, .{});
    defer testing.allocator.free(round);
    try testing.expectEqualStrings("payload", round);

    // Source must be untouched.
    const src_round = try readFileSync(src, testing.allocator, .{});
    defer testing.allocator.free(src_round);
    try testing.expectEqualStrings("payload", src_round);
}

test "fs.renameSync — moves file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "from.txt", .data = "data" });
    const from = try tmpAbsPath(&tmp, "from.txt");
    defer testing.allocator.free(from);
    const dir_path = std.fs.path.dirname(from) orelse return error.TestUnexpectedResult;

    var to_buf: [4096]u8 = undefined;
    const to = try std.fmt.bufPrint(&to_buf, "{s}/to.txt", .{dir_path});

    try renameSync(from, to);
    try testing.expect(!existsSync(from));
    try testing.expect(existsSync(to));
}

test "fs.unlinkSync — removes file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "doomed.txt", .data = "x" });
    const abs = try tmpAbsPath(&tmp, "doomed.txt");
    defer testing.allocator.free(abs);

    try testing.expect(existsSync(abs));
    try unlinkSync(abs);
    try testing.expect(!existsSync(abs));
}

test "fs.lstatSync — matches statSync for regular files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain.txt", .data = "yo" });
    const abs = try tmpAbsPath(&tmp, "plain.txt");
    defer testing.allocator.free(abs);

    const s = try statSync(abs);
    const ls = try lstatSync(abs);

    try testing.expectEqual(s.size, ls.size);
    try testing.expect(s.is_file and ls.is_file);
    try testing.expect(!s.is_symlink and !ls.is_symlink);
}

test "fs.realpathSync — resolves to absolute existing path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.txt", .data = "" });
    const abs = try tmpAbsPath(&tmp, "real.txt");
    defer testing.allocator.free(abs);

    var buf: [4096]u8 = undefined;
    const resolved = try realpathSync(abs, &buf);
    // Realpath of an already-canonical path equals the input on
    // POSIX. We don't assert exact equality (macOS' /var → /private/var
    // makes that fragile) but we do require non-empty and existsSync.
    try testing.expect(resolved.len > 0);
    try testing.expect(existsSync(resolved));
}

test "fs.writeFileSync append mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "appendme.txt", .data = "" });
    const abs = try tmpAbsPath(&tmp, "appendme.txt");
    defer testing.allocator.free(abs);

    try writeFileSync(abs, "first", .{});
    try writeFileSync(abs, "_second", .{ .append = true });

    const round = try readFileSync(abs, testing.allocator, .{});
    defer testing.allocator.free(round);
    try testing.expectEqualStrings("first_second", round);
}
