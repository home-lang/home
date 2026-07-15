// Copied verbatim from bun/src/sql/mysql/protocol/LocalInfileRequest.zig
// at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// MySQL LOCAL INFILE request packet. Decoder body calls the wave-18
// NewReader stub method surface; `Data` is the wave-18 union stub from
// `sql/shared/Data.zig` (already tracked).

const LocalInfileRequest = @This();
filename: Data = .{ .empty = {} },
packet_size: u24,

pub fn deinit(this: *LocalInfileRequest) void {
    this.filename.deinit();
}

pub fn decodeInternal(this: *LocalInfileRequest, comptime Context: type, reader: NewReader(Context)) !void {
    const header = try reader.int(u8);
    if (header != 0xFB) {
        return error.InvalidLocalInfileRequest;
    }

    // `packet_size` counts the header byte we just consumed. A malformed packet
    // reporting size 0 would underflow the u24 to 0xFFFFFF and force a 16MB
    // over-read; reject it before subtracting.
    if (this.packet_size == 0) {
        return error.InvalidLocalInfileRequest;
    }
    this.filename = try reader.read(this.packet_size - 1);
}

pub const decode = decoderWrap(LocalInfileRequest, decodeInternal).decode;

test "LocalInfileRequest default has empty filename" {
    const std = @import("std");
    var p: LocalInfileRequest = .{ .packet_size = 0 };
    defer p.deinit();
    try std.testing.expectEqualStrings("", p.filename.slice());
}

const Data = @import("../../shared/Data.zig").Data;

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
