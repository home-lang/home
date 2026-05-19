// Copied from bun/src/sql/postgres/protocol/CopyInResponse.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Imports rewritten: @import("bun") dropped — the upstream body's only
// reference is `bun.Output.panic("TODO: not implemented {s}", .{...
// typeBaseName...})`. Home-rt's equivalent surface (`Output.panic`)
// only takes a comptime format + args, but `typeBaseName` isn't in
// home_rt yet. Until those land, the panic falls through to
// `std.debug.panic` with `@typeName` (slightly more verbose path) —
// the protocol stub still TODO-panics at the same shape upstream
// does, so the JS-visible behaviour is unchanged.

const CopyInResponse = @This();

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    _ = reader;
    _ = this;
    std.debug.panic("TODO: not implemented {s}", .{@typeName(@This())});
}

pub const decode = DecoderWrap(CopyInResponse, decodeInternal).decode;

test "CopyInResponse is a stub struct" {
    const c: CopyInResponse = .{};
    _ = c;
}

const std = @import("std");
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;
