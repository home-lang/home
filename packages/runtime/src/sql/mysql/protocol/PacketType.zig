// Copied verbatim from bun/src/sql/mysql/protocol/PacketType.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.

pub const PacketType = enum(u8) {
    // Server packets
    OK = 0x00,
    EOF = 0xfe,
    ERROR = 0xff,
    LOCAL_INFILE = 0xfb,

    // Client/server packets
    HANDSHAKE = 0x0a,
    MORE_DATA = 0x01,

    _,
    pub const AUTH_SWITCH = 0xfe;
};
