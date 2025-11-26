const std = @import("std");

/// Serialization package - provides various serialization formats
pub const MessagePack = @import("msgpack.zig").MessagePack;
pub const MsgPackValue = @import("msgpack.zig").MessagePack.Value;
pub const MsgPackBuilder = @import("msgpack.zig").Builder;

pub const Protobuf = @import("protobuf.zig").Protobuf;
pub const ProtobufMessage = @import("protobuf.zig").Protobuf.Message;
pub const ProtobufValue = @import("protobuf.zig").Protobuf.Value;
pub const CodeGen = @import("protobuf.zig").CodeGen;

pub const CBOR = @import("cbor.zig").CBOR;
pub const CBOREncoder = @import("cbor.zig").CBOREncoder;
pub const CBORDecoder = @import("cbor.zig").CBORDecoder;

pub const Avro = @import("avro.zig").Avro;
pub const AvroEncoder = @import("avro.zig").AvroEncoder;
pub const AvroDecoder = @import("avro.zig").AvroDecoder;

pub const CapnProto = @import("capnproto.zig").CapnProto;
pub const CapnProtoMessage = @import("capnproto.zig").CapnProto.Message;
pub const StructBuilder = @import("capnproto.zig").CapnProto.StructBuilder;
pub const StructReader = @import("capnproto.zig").CapnProto.StructReader;

test {
    @import("std").testing.refAllDecls(@This());
}
