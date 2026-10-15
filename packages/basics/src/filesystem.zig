// Home Language - Filesystem Module
// File and directory operations

const std = @import("std");
const compat = @import("compat.zig");
const Allocator = std.mem.Allocator;

pub const Io = std.Io;
pub const File = Io.File;
pub const Dir = Io.Dir;

/// Check if a file exists
pub fn exists(path: []const u8) bool {
    return existsWithIo(compat.io(), path);
}

pub fn existsWithIo(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Check if path is a directory
pub fn isDirectory(path: []const u8) bool {
    return isDirectoryWithIo(compat.io(), path);
}

pub fn isDirectoryWithIo(io: Io, path: []const u8) bool {
    const stat = Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// Check if path is a file
pub fn isFile(path: []const u8) bool {
    return isFileWithIo(compat.io(), path);
}

pub fn isFileWithIo(io: Io, path: []const u8) bool {
    const stat = Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

/// Read entire file into memory
pub fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    return readFileWithIo(compat.io(), allocator, path);
}

pub fn readFileWithIo(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    // Guard against u64 stat sizes that would not fit in the reader's usize
    // limit on 32-bit platforms.
    const max_size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_size)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
}

/// Write data to file
pub fn writeFile(path: []const u8, data: []const u8) !void {
    return writeFileWithIo(compat.io(), path, data);
}

pub fn writeFileWithIo(io: Io, path: []const u8, data: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Append data to file
pub fn appendFile(path: []const u8, data: []const u8) !void {
    return appendFileWithIo(compat.io(), path, data);
}

pub fn appendFileWithIo(io: Io, path: []const u8, data: []const u8) !void {
    const file = try Dir.cwd().openFile(io, path, .{ .mode = .write_only });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, data, stat.size);
}

/// Delete a file
pub fn deleteFile(path: []const u8) !void {
    return deleteFileWithIo(compat.io(), path);
}

pub fn deleteFileWithIo(io: Io, path: []const u8) !void {
    try Dir.cwd().deleteFile(io, path);
}

/// Create a directory
pub fn createDirectory(path: []const u8) !void {
    return createDirectoryWithIo(compat.io(), path);
}

pub fn createDirectoryWithIo(io: Io, path: []const u8) !void {
    try Dir.cwd().createDirPath(io, path);
}

/// Delete a directory
pub fn deleteDirectory(path: []const u8) !void {
    return deleteDirectoryWithIo(compat.io(), path);
}

pub fn deleteDirectoryWithIo(io: Io, path: []const u8) !void {
    try Dir.cwd().deleteTree(io, path);
}

/// Copy a file
pub fn copyFile(source: []const u8, dest: []const u8) !void {
    return copyFileWithIo(compat.io(), source, dest);
}

pub fn copyFileWithIo(io: Io, source: []const u8, dest: []const u8) !void {
    const cwd = Dir.cwd();
    try cwd.copyFile(source, cwd, dest, io, .{ .replace = true });
}

/// Move/rename a file
pub fn moveFile(source: []const u8, dest: []const u8) !void {
    return moveFileWithIo(compat.io(), source, dest);
}

pub fn moveFileWithIo(io: Io, source: []const u8, dest: []const u8) !void {
    const cwd = Dir.cwd();
    try cwd.rename(source, cwd, dest, io);
}

/// Get file size
pub fn fileSize(path: []const u8) !u64 {
    return fileSizeWithIo(compat.io(), path);
}

pub fn fileSizeWithIo(io: Io, path: []const u8) !u64 {
    const stat = try Dir.cwd().statFile(io, path, .{});
    return stat.size;
}

/// Get current working directory
pub fn getCurrentDirectory(allocator: Allocator) ![]u8 {
    return getCurrentDirectoryWithIo(compat.io(), allocator);
}

pub fn getCurrentDirectoryWithIo(io: Io, allocator: Allocator) ![]u8 {
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

/// Change current working directory
pub fn setCurrentDirectory(path: []const u8) !void {
    return setCurrentDirectoryWithIo(compat.io(), path);
}

pub fn setCurrentDirectoryWithIo(io: Io, path: []const u8) !void {
    try std.process.setCurrentPath(io, path);
}

/// Get absolute path
pub fn absolutePath(allocator: Allocator, path: []const u8) ![]u8 {
    return absolutePathWithIo(compat.io(), allocator, path);
}

pub fn absolutePathWithIo(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const len = try Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

/// Join path components
pub fn joinPath(allocator: Allocator, paths: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, paths);
}

/// Get directory name from path
pub fn dirname(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

/// Get base filename from path
pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// Get file extension
pub fn extension(path: []const u8) ?[]const u8 {
    return std.fs.path.extension(path);
}

/// Directory iterator
pub const DirectoryIterator = struct {
    io: Io,
    dir: Dir,
    iter: Dir.Iterator,

    pub fn next(self: *DirectoryIterator) !?Dir.Entry {
        return self.iter.next(self.io);
    }

    pub fn deinit(self: *DirectoryIterator) void {
        self.dir.close(self.io);
        self.* = undefined;
    }
};

/// List directory contents
pub fn listDirectory(path: []const u8) !DirectoryIterator {
    return listDirectoryWithIo(compat.io(), path);
}

pub fn listDirectoryWithIo(io: Io, path: []const u8) !DirectoryIterator {
    const dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    return DirectoryIterator{
        .io = io,
        .dir = dir,
        .iter = dir.iterateAssumeFirstIteration(),
    };
}
