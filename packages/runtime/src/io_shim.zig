// Forward-port shim: Home's pinned Zig (0.17-dev.263 Bun fork) removed the old
// `std.io.GenericWriter` (the `Context + writeFn` writer) in favor of the new
// vtable-based `std.Io.Writer`. Bun's pinned source still defines custom sinks
// via `std.io.GenericWriter(Context, Error, writeFn)` and bridges to the new API
// with `.adaptToNewApi(buffer).new_interface`. This restores both so the copied
// sinks (BlockList/Blob structured-clone serialize, ConsoleObject width counter)
// compile unchanged.

const std = @import("std");

/// Faithful re-implementation of the removed `std.io.GenericWriter`.
pub fn GenericWriter(
    comptime Context: type,
    comptime WriteError: type,
    comptime writeFn: fn (context: Context, bytes: []const u8) WriteError!usize,
) type {
    return struct {
        context: Context,

        const Self = @This();
        pub const Error = WriteError;

        pub fn write(self: Self, bytes: []const u8) Error!usize {
            return writeFn(self.context, bytes);
        }

        pub fn writeAll(self: Self, bytes: []const u8) Error!void {
            var index: usize = 0;
            while (index != bytes.len) {
                index += try writeFn(self.context, bytes[index..]);
            }
        }

        pub fn writeByte(self: Self, byte: u8) Error!void {
            const array = [1]u8{byte};
            return self.writeAll(&array);
        }

        pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Error!void {
            var bytes: [256]u8 = undefined;
            @memset(bytes[0..], byte);
            var remaining = n;
            while (remaining > 0) {
                const to_write = @min(remaining, bytes.len);
                try self.writeAll(bytes[0..to_write]);
                remaining -= to_write;
            }
        }

        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) Error!void {
            const text = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch @panic("out of memory");
            defer std.heap.smp_allocator.free(text);
            return self.writeAll(text);
        }

        pub fn writeBytesNTimes(self: Self, bytes: []const u8, n: usize) Error!void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try self.writeAll(bytes);
            }
        }

        pub fn writeInt(self: Self, comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
            var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, endian);
            return self.writeAll(&bytes);
        }

        pub fn writeStruct(self: Self, value: anytype) Error!void {
            return self.writeAll(std.mem.asBytes(&value));
        }

        /// Bridge to the new `std.Io.Writer` API. The returned `Adapter` owns a
        /// `new_interface: std.Io.Writer` whose drain forwards every byte to
        /// `writeFn` (mirrors the transitional `GenericWriter.adaptToNewApi`).
        pub fn adaptToNewApi(self: Self, buffer: []u8) Adapter {
            return .{
                .derp_writer = self,
                .new_interface = .{
                    .vtable = &.{ .drain = Adapter.drain },
                    .buffer = buffer,
                },
            };
        }

        pub const Adapter = struct {
            derp_writer: Self,
            new_interface: std.Io.Writer,

            fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                const a: *Adapter = @alignCast(@fieldParentPtr("new_interface", w));
                // Forward buffered bytes first, then reset the buffer.
                if (w.end != 0) {
                    a.derp_writer.writeAll(w.buffer[0..w.end]) catch return error.WriteFailed;
                    w.end = 0;
                }
                const slice = data[0 .. data.len - 1];
                const pattern = data[slice.len];
                var written: usize = 0;
                for (slice) |bytes| {
                    if (bytes.len != 0) a.derp_writer.writeAll(bytes) catch return error.WriteFailed;
                    written += bytes.len;
                }
                if (pattern.len != 0) {
                    var i: usize = 0;
                    while (i < splat) : (i += 1) {
                        a.derp_writer.writeAll(pattern) catch return error.WriteFailed;
                    }
                }
                written += pattern.len * splat;
                return written;
            }
        };
    };
}

test "GenericWriter forwards to writeFn (write/writeAll/writeInt)" {
    const Sink = struct {
        total: *usize,
        fn write(self: @This(), bytes: []const u8) error{}!usize {
            self.total.* += bytes.len;
            return bytes.len;
        }
    };
    var total: usize = 0;
    const W = GenericWriter(Sink, error{}, Sink.write);
    const w = W{ .context = .{ .total = &total } };
    try w.writeAll("hello");
    try w.writeInt(u32, 1, .little);
    try std.testing.expectEqual(@as(usize, 9), total);
}

test "adaptToNewApi bridges to std.Io.Writer" {
    const Sink = struct {
        total: *usize,
        fn write(self: @This(), bytes: []const u8) error{}!usize {
            self.total.* += bytes.len;
            return bytes.len;
        }
    };
    var total: usize = 0;
    const W = GenericWriter(Sink, error{}, Sink.write);
    const w = W{ .context = .{ .total = &total } };
    var buf: [8]u8 = undefined;
    var adapter = w.adaptToNewApi(&buf);
    try adapter.new_interface.writeAll("abcdefghij"); // larger than buffer → forces drain
    try adapter.new_interface.flush();
    try std.testing.expectEqual(@as(usize, 10), total);
}
