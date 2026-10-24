//! Explicit discovery root keeps packetizer imports inside the public src tree.
comptime {
    _ = @import("streaming/rtp_packetizer.zig");
    _ = @import("streaming/rtp_wire.zig");
    _ = @import("core/nal_convert.zig");
}
