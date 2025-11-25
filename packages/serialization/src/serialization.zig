const std = @import("std");

/// Serialization package - provides various serialization formats
pub const MessagePack = @import("msgpack.zig").MessagePack;
pub const MsgPackValue = @import("msgpack.zig").MessagePack.Value;
pub const MsgPackBuilder = @import("msgpack.zig").Builder;

pub const Protobuf = @import("protobuf.zig").Protobuf;
pub const ProtobufMessage = @import("protobuf.zig").Protobuf.Message;
pub const ProtobufValue = @import("protobuf.zig").Protobuf.Value;
pub const CodeGen = @import("protobuf.zig").CodeGen;

test {
    @import("std").testing.refAllDecls(@This());
}
