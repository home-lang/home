const std = @import("std");
const serialization = @import("serialization");

test "public package exposes working MessagePack and Protobuf codecs" {
    var message_pack = serialization.MessagePack.init(std.testing.allocator);
    const packed_bytes = try message_pack.serialize(.{ .string = "home" });
    defer std.testing.allocator.free(packed_bytes);

    var unpacked = try message_pack.deserialize(packed_bytes);
    defer unpacked.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("home", unpacked.string);

    var protobuf = serialization.Protobuf.init(std.testing.allocator);
    var message = serialization.ProtobufMessage.init(std.testing.allocator);
    defer message.deinit(std.testing.allocator);
    try message.addVarint(1, 42);

    const encoded = try protobuf.serialize(message);
    defer std.testing.allocator.free(encoded);
    var decoded = try protobuf.deserialize(encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 42), decoded.getVarint(1));
}

test "public package compiles every exported codec declaration" {
    std.testing.refAllDecls(serialization);
    _ = serialization.MessagePackError;
    _ = serialization.ProtobufError;
}
