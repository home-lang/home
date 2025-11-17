// Home Language - Filesystem Module
// File and directory operations

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const File = std.fs.File;
pub const Dir = std.fs.Dir;

/// Check if a file exists
pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Check if path is a directory
pub fn isDirectory(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .directory;
}

/// Check if path is a file
pub fn isFile(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .file;
}

/// Read entire file into memory
pub fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return try file.readToEndAlloc(allocator, stat.size);
}

/// Write data to file
pub fn writeFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

/// Append data to file
pub fn appendFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(data);
}

/// Delete a file
pub fn deleteFile(path: []const u8) !void {
    try std.fs.cwd().deleteFile(path);
}

/// Create a directory
pub fn createDirectory(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

/// Delete a directory
pub fn deleteDirectory(path: []const u8) !void {
    try std.fs.cwd().deleteTree(path);
}

/// Copy a file
pub fn copyFile(source: []const u8, dest: []const u8) !void {
    try std.fs.cwd().copyFile(source, std.fs.cwd(), dest, .{});
}

/// Move/rename a file
pub fn moveFile(source: []const u8, dest: []const u8) !void {
    try std.fs.cwd().rename(source, dest);
}

/// Get file size
pub fn fileSize(path: []const u8) !u64 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.size;
}

/// Get current working directory
pub fn getCurrentDirectory(allocator: Allocator) ![]u8 {
    return try std.process.getCwdAlloc(allocator);
}

/// Change current working directory
pub fn setCurrentDirectory(path: []const u8) !void {
    try std.os.chdir(path);
}

/// Get absolute path
pub fn absolutePath(allocator: Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().realpathAlloc(allocator, path);
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
    iter: Dir.Iterator,

    pub fn next(self: *DirectoryIterator) !?Dir.Entry {
        return try self.iter.next();
    }
};

/// List directory contents
pub fn listDirectory(path: []const u8) !DirectoryIterator {
    var dir = try std.fs.cwd().openIterableDir(path, .{});
    return DirectoryIterator{
        .iter = dir.iterate(),
    };
}
