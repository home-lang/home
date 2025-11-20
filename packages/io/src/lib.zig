// I/O Library for Home Language
// Async file operations using Zig 0.16-dev features

pub const AsyncFile = @import("async_file.zig").AsyncFile;
pub const AsyncDir = @import("async_file.zig").AsyncDir;
pub const IniFile = @import("ini_parser.zig").IniFile;

// String utilities
pub const String = @import("string.zig");
pub const StringBuilder = String.StringBuilder;

// Convenience functions
pub const readFileAlloc = @import("async_file.zig").readFileAlloc;
pub const writeFile = @import("async_file.zig").writeFile;
pub const fileExists = @import("async_file.zig").fileExists;
pub const dirExists = @import("async_file.zig").dirExists;
pub const getFileSize = @import("async_file.zig").getFileSize;

pub const VERSION = "1.0.0";
