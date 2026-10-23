// I/O Library for Home Language
// TypeScript-like async I/O using Zig 0.16.0-dev

pub const AsyncRuntime = @import("async_io.zig").AsyncRuntime;
pub const fs = @import("async_io.zig").fs;

// Utilities
pub const BinaryReader = @import("binary_reader.zig").BinaryReader;
pub const IniFile = @import("ini_parser.zig").IniFile;
pub const BufferedReader = @import("buffered.zig").BufferedReader;
pub const BufferedWriter = @import("buffered.zig").BufferedWriter;
pub const FileBufferedReader = @import("buffered.zig").FileBufferedReader;
pub const FileBufferedReaderWithIo = @import("buffered.zig").FileBufferedReaderWithIo;
pub const FileBufferedWriter = @import("buffered.zig").FileBufferedWriter;
pub const FileBufferedWriterWithIo = @import("buffered.zig").FileBufferedWriterWithIo;
pub const regex = @import("regex.zig");
pub const Regex = regex.Regex;
pub const RegexError = regex.RegexError;
pub const RegexMatch = regex.Match;

// String utilities
pub const String = @import("string.zig");
pub const StringBuilder = String.StringBuilder;

/// Hosted Linux/Darwin descriptor owners; use with libc and caller synchronization.
pub const PosixSharedMemory = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos) @import("posix_shared_memory.zig") else struct {};
pub const DescriptorChannel = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos) @import("descriptor_channel.zig") else struct {};
