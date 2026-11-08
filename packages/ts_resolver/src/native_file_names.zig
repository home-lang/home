//! Process-wide native filename-host policy. Probe the executable, never the
//! current project's data volume, and retain the result for every compilation.
const std = @import("std");
const builtin = @import("builtin");
const filename_case = @import("filename_case");

var mutex: std.Io.Mutex = .init;
var cached: ?bool = null;

pub const Error = std.process.ExecutablePathError || std.Io.Dir.StatFileError || std.Io.Cancelable || error{BufferTooSmall};

const NativeProbe = struct {
    io: std.Io,

    fn exists(self: NativeProbe, path: []const u8) !bool {
        _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
};

fn detect(executable: []const u8, probe: anytype) !bool {
    // Even an invalid input byte expands to only three replacement bytes.
    // The executable path itself is bounded by std.fs.max_path_bytes.
    var swapped_buffer: [std.fs.max_path_bytes * 4]u8 = undefined;
    const swapped = try filename_case.swapCaseInto(executable, &swapped_buffer);
    return !try probe.exists(swapped);
}

pub fn caseSensitive(io: std.Io) Error!bool {
    if (builtin.os.tag == .windows) return false;
    if (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64) return true;
    try mutex.lock(io);
    defer mutex.unlock(io);
    if (cached) |value| return value;
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try std.process.executablePath(io, &executable_buffer);
    const result = try detect(executable_buffer[0..length], NativeProbe{ .io = io });
    cached = result;
    return result;
}

test "native host policy follows the swapped executable and propagates errors" {
    const Probe = struct {
        present: bool,
        failure: bool = false,

        fn exists(self: @This(), path: []const u8) !bool {
            try std.testing.expectEqualStrings("/HOST/tOOL", path);
            if (self.failure) return error.AccessDenied;
            return self.present;
        }
    };
    try std.testing.expect(!try detect("/host/Tool", Probe{ .present = true }));
    try std.testing.expect(try detect("/host/Tool", Probe{ .present = false }));
    try std.testing.expectError(error.AccessDenied, detect("/host/Tool", Probe{ .present = false, .failure = true }));
}
