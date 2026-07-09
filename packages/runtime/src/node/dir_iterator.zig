// Copied from bun/src/runtime/node/dir_iterator.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// **Partial port (vocabulary types only — the iterator body parks).**
//
// Upstream `dir_iterator.zig` (565 lines) clones `std.fs.Dir.Iterator` with
// four behavior changes:
//   1. it returns errors in the bun-syscall `Maybe` format
//   2. doesn't mark `BADF` as unreachable
//   3. it uses `bun.PathString` instead of `[]const u8`
//   4. on Windows, callers can ask for `[]const u16` results instead of
//      transcoded UTF-8
//
// What's ported here:
//   * The `IteratorError` set (`AccessDenied | SystemResources |
//     UnexpectedError`) — load-bearing because callers across `node:fs`
//     match on its tags.
//   * `IteratorResult` and `IteratorResultW` shapes — pure data; the
//     `name`/`kind` pair every per-OS iterator yields.
//   * `PathType` enum (`.u8` vs `.u16`) — picks the encoding flavour of
//     `WrappedIterator`.
//
// What's omitted (re-attaches with the substrate):
//   * `NewIterator(use_windows_ospath)` — depends on `bun.FD` (cast()),
//     `bun.sys.Maybe.errnoSys`, `bun.sys.SystemErrno`, `bun.sys.syslog`,
//     `posix.system.__getdirentries64` (macOS), `linux.getdents64`,
//     `windows.NtQueryDirectoryFile`, plus per-OS dirent structs.
//   * `NewWrappedIterator` / `WrappedIterator{,W}` / `iterate` — thin
//     wrappers over the above.
//
// Once `home_rt.sys.maybe.Maybe` + a Home `FD` type + the per-OS
// `posix.system.dirent` shapes are reachable, the iterator body can re-land
// over these types without changing the public surface — that's why this
// file ports the shapes first.
//
// Imports rewritten: @import("bun") → @import("home").

const std = @import("std");
const posix = std.posix;

const home_rt = @import("home");

/// `PathString` payload Home doesn't yet expose at top-level. Upstream's
/// `bun.PathString` is a 16-byte SOA (path + length) used to thread
/// path-buffer pool entries through node:fs. Home's port hasn't reached
/// that file; for the dir-iterator vocabulary we only need an opaque shape
/// the caller can copy from. Swap to `home_rt.PathString` when it lands.
pub const PathString = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) PathString {
        return .{ .bytes = bytes };
    }

    pub fn slice(this: PathString) []const u8 {
        return this.bytes;
    }
};

/// Error set surfaced by the iterator. Carried verbatim from upstream so
/// callers' `error{ … } || posix.UnexpectedError` patterns match.
pub const IteratorError = error{ AccessDenied, SystemResources } || posix.UnexpectedError;

/// One directory entry, UTF-8 flavour. The `name` slice borrows from the
/// iterator's internal buffer and is invalidated by the next `next()`.
pub const IteratorResult = struct {
    name: PathString,
    kind: Entry.Kind,
};

/// Windows-only result with the on-disk UTF-16LE bytes preserved (no
/// transcode). The inner `name` mirrors `PathString`'s shape so downstream
/// code can stay generic with one fewer `if (Environment.isWindows)`.
pub const IteratorResultW = struct {
    name: struct {
        data: [:0]const u16,

        pub fn slice(this: @This()) []const u16 {
            return this.data;
        }

        pub fn sliceAssumeZ(this: @This()) [:0]const u16 {
            return this.data;
        }
    },
    kind: Entry.Kind,
};

/// Which character-encoding flavour `iterate()` should yield.
pub const PathType = enum { u8, u16 };

/// Local stand-in for `jsc.Node.Dirent.Kind`. Upstream re-exports
/// `std.Io.File.Kind` (a Zig 0.14 path that Zig 0.17 removed), so Home
/// reuses `home_rt.sys.maybe.FileKind` — a same-tags shim already shipped
/// for the Stat / lstat callers. The JSC bridge re-attaches against the
/// same tag set.
pub const Entry = struct {
    pub const Kind = home_rt.sys.maybe.FileKind;
};

test "dir_iterator: IteratorError includes the two named cases plus UnexpectedError" {
    // Compile-time membership check: if any of these were ever pruned out of
    // the error set, this file would fail to compile. Re-stating them here
    // keeps the load-bearing tags pinned.
    const access_denied: IteratorError = error.AccessDenied;
    const system_resources: IteratorError = error.SystemResources;
    try std.testing.expectEqual(IteratorError.AccessDenied, access_denied);
    try std.testing.expectEqual(IteratorError.SystemResources, system_resources);
}

test "dir_iterator: PathType has exactly the two variants iterate() switches on" {
    try std.testing.expectEqual(@as(u1, 0), @intFromEnum(PathType.u8));
    try std.testing.expectEqual(@as(u1, 1), @intFromEnum(PathType.u16));
    try std.testing.expectEqual(2, @typeInfo(PathType).@"enum".field_names.len);
}

test "dir_iterator: IteratorResult round-trips its name + kind payload" {
    const r = IteratorResult{
        .name = PathString.init("foo.txt"),
        .kind = .file,
    };
    try std.testing.expectEqualStrings("foo.txt", r.name.slice());
    try std.testing.expectEqual(Entry.Kind.file, r.kind);
}

test "dir_iterator: IteratorResultW wraps a zero-terminated UTF-16LE slice" {
    const name_buf = &[_:0]u16{ 'f', 'o', 'o' };
    const r = IteratorResultW{
        .name = .{ .data = name_buf },
        .kind = .directory,
    };
    try std.testing.expectEqual(@as(usize, 3), r.name.slice().len);
    try std.testing.expectEqual(@as(u16, 'o'), r.name.slice()[2]);
    // sliceAssumeZ preserves the sentinel.
    try std.testing.expectEqual(@as(u16, 0), r.name.sliceAssumeZ()[3]);
    try std.testing.expectEqual(Entry.Kind.directory, r.kind);
}

test "dir_iterator: Entry.Kind exposes the load-bearing dirent tag names" {
    // Spot-check the four kinds every per-OS dirent branch maps onto; if any
    // is renamed the iterator's switch arms break at the call site.
    const k_file: Entry.Kind = .file;
    const k_dir: Entry.Kind = .directory;
    const k_sym: Entry.Kind = .sym_link;
    const k_unk: Entry.Kind = .unknown;
    try std.testing.expectEqual(Entry.Kind.file, k_file);
    try std.testing.expectEqual(Entry.Kind.directory, k_dir);
    try std.testing.expectEqual(Entry.Kind.sym_link, k_sym);
    try std.testing.expectEqual(Entry.Kind.unknown, k_unk);
}
