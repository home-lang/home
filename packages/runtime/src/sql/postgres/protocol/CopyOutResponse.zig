// Copied from bun/src/sql/postgres/protocol/CopyOutResponse.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Imports rewritten: @import("bun") dropped — the upstream body's only
// reference is `bun.Output.panic("TODO: not implemented {s}", .{...
// typeBaseName...})`. Until `typeBaseName` lands in home_rt the panic
// falls through to `std.debug.panic` with `@typeName`. This mirrors
// the upstream "not yet implemented" sentinel: any caller that drives
// COPY OUT today trips a loud panic at the same call shape.

const CopyOutResponse = @This();

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    _ = reader;
    _ = this;
    std.debug.panic("TODO: not implemented {s}", .{@typeName(@This())});
}

pub const decode = DecoderWrap(CopyOutResponse, decodeInternal).decode;

test "CopyOutResponse is a stub struct" {
    const c: CopyOutResponse = .{};
    _ = c;
}

const std = @import("std");
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;
