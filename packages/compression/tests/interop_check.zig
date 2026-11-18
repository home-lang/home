//! `zig build interop`: compress the fixtures with this package and decode
//! the results with the reference tools (`zstd`, `lz4`, `brotli` on PATH).
//! A tool that is not installed is reported and skipped; any mismatch fails.

const std = @import("std");
const compression = @import("compression");

const inputs = .{
    .{ "text", @embedFile("fixtures/text.txt") },
    .{ "binary", @embedFile("fixtures/binary.bin") },
    .{ "empty", @embedFile("fixtures/empty.bin") },
    .{ "large", "" }, // generated below
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    // A 1.5 MiB input: several zstd blocks, a multi-block window, and many LZ4 blocks.
    const large = try gpa.alloc(u8, 1_500_000);
    defer gpa.free(large);
    var prng = std.Random.DefaultPrng.init(1051);
    for (large, 0..) |*b, i| b.* = if ((i / 4096) % 4 == 3) prng.random().int(u8) else @embedFile("fixtures/text.txt")[i % 13356];

    var failures: usize = 0;
    inline for (inputs) |input| {
        const name = input[0];
        const data: []const u8 = if (comptime std.mem.eql(u8, name, "large")) large else input[1];

        var zstd = compression.Zstd.init(gpa, .balanced);
        const z = try zstd.compress(data);
        defer gpa.free(z);
        failures += try check(gpa, io, "zstd", &.{ "zstd", "-d", "-c", "-q" }, z, data, name);

        var lz4 = compression.LZ4.init(gpa, 1);
        const l = try lz4.compress(data);
        defer gpa.free(l);
        failures += try check(gpa, io, "lz4", &.{ "lz4", "-d", "-c", "-q" }, l, data, name);

        var brotli = try compression.Brotli.init(gpa, 6, 22);
        const b = try brotli.compress(data);
        defer gpa.free(b);
        failures += try check(gpa, io, "brotli", &.{ "brotli", "-d", "-c" }, b, data, name);
    }
    if (failures > 0) {
        std.debug.print("{d} interop check(s) failed\n", .{failures});
        return 1;
    }
    return 0;
}

/// Feed `encoded` to `argv` on stdin and compare its stdout with `expected`.
fn check(gpa: std.mem.Allocator, io: std.Io, tool: []const u8, argv: []const []const u8, encoded: []const u8, expected: []const u8, name: []const u8) !usize {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("skip {s}: not installed\n", .{tool});
            return 0;
        },
        else => return err,
    };
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(gpa);
    {
        // Write and read concurrently so a large output cannot deadlock the pipes.
        const Feed = struct {
            fn run(io_: std.Io, file: std.Io.File, bytes: []const u8) void {
                file.writeStreamingAll(io_, bytes) catch {};
                file.close(io_);
            }
        };
        const stdin_file = child.stdin.?;
        child.stdin = null;
        var feeder = try io.concurrent(Feed.run, .{ io, stdin_file, encoded });
        var buf: [64 * 1024]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buf);
        while (true) {
            const n = reader.interface.readSliceShort(&buf) catch break;
            try stdout.appendSlice(gpa, buf[0..n]);
            if (n < buf.len) break;
        }
        feeder.await(io);
    }
    const term = try child.wait(io);
    const ok = term.success() and std.mem.eql(u8, stdout.items, expected);
    std.debug.print("{s} {s} -d {s} ({d} -> {d} bytes)\n", .{ if (ok) "ok  " else "FAIL", tool, name, expected.len, encoded.len });
    return @intFromBool(!ok);
}
