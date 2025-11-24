const std = @import("std");

/// Teletext (World System Teletext - WST)
/// Used for closed captions, subtitles, and data services in PAL/SECAM broadcasts
pub const Teletext = struct {
    /// Teletext packet types
    pub const PacketType = enum(u8) {
        page_header = 0,
        data_row = 1, // 1-23 are data rows
        top_navigation = 24,
        fastext_links = 27,
        page_enhancement = 26,
        broadcast_service = 30,
        independent_data = 31,
        _,
    };

    /// Magazine numbers (0-7)
    pub const Magazine = u3;

    /// Page number (00-FF hex, displayed as 100-899)
    pub const PageNumber = u8;

    /// Teletext control bits
    pub const ControlBits = packed struct {
        erase_page: bool,
        newsflash: bool,
        subtitle: bool,
        suppress_header: bool,
        update_indicator: bool,
        interrupted_sequence: bool,
        inhibit_display: bool,
        magazine_serial: bool,
    };

    /// Teletext character attributes
    pub const Attributes = packed struct {
        foreground: Color,
        background: Color,
        double_height: bool,
        double_width: bool,
        flash: bool,
        concealed: bool,
        boxed: bool,
        separated: bool,
    };

    /// Teletext colors (3-bit)
    pub const Color = enum(u3) {
        black = 0,
        red = 1,
        green = 2,
        yellow = 3,
        blue = 4,
        magenta = 5,
        cyan = 6,
        white = 7,
    };

    /// Level 1 enhancement data
    pub const EnhancementData = struct {
        triplets: []Triplet,
    };

    /// Enhancement triplet
    pub const Triplet = struct {
        address: u6,
        mode: u5,
        data: u7,
    };

    /// Teletext page
    pub const Page = struct {
        magazine: Magazine,
        page: PageNumber,
        subpage: u16,
        control_bits: ControlBits,
        language: u3,
        rows: [25]Row,
        enhancement: ?EnhancementData,
    };

    /// Teletext row (40 characters)
    pub const Row = struct {
        data: [40]u8,
        attributes: [40]Attributes,
    };

    /// Teletext packet (one line of VBI data)
    pub const Packet = struct {
        magazine: Magazine,
        packet_number: u5,
        data: [40]u8,
    };
};

/// Teletext decoder
pub const TeletextDecoder = struct {
    allocator: std.mem.Allocator,
    current_page: ?Teletext.Page,
    page_buffer: std.AutoHashMap(u32, Teletext.Page),

    const HAMMING_8_4_DECODE: [256]i8 = blk: {
        var table: [256]i8 = undefined;
        for (&table, 0..) |*entry, i| {
            entry.* = hamming84Decode(@truncate(i));
        }
        break :blk table;
    };

    pub fn init(allocator: std.mem.Allocator) !TeletextDecoder {
        return .{
            .allocator = allocator,
            .current_page = null,
            .page_buffer = std.AutoHashMap(u32, Teletext.Page).init(allocator),
        };
    }

    pub fn deinit(self: *TeletextDecoder) void {
        self.page_buffer.deinit();
    }

    /// Decode a teletext packet from VBI line data (42 bytes)
    pub fn decodePacket(self: *TeletextDecoder, vbi_data: []const u8) !?Teletext.Packet {
        if (vbi_data.len < 42) return error.InvalidPacketSize;

        // Clock run-in and framing code are first 2 bytes, skip them
        const data = vbi_data[2..];

        // Decode magazine and packet address (Hamming 8/4)
        const mag_addr = try self.decodeHamming84Pair(data[0], data[1]);
        const magazine: Teletext.Magazine = @truncate(mag_addr & 0x07);
        const packet_number: u5 = @truncate((mag_addr >> 3) & 0x1F);

        // Remaining 40 bytes are data (odd parity encoded)
        var packet_data: [40]u8 = undefined;
        for (0..40) |i| {
            packet_data[i] = try self.decodeOddParity(data[2 + i]);
        }

        return Teletext.Packet{
            .magazine = magazine,
            .packet_number = packet_number,
            .data = packet_data,
        };
    }

    /// Process a decoded packet
    pub fn processPacket(self: *TeletextDecoder, packet: Teletext.Packet) !void {
        if (packet.packet_number == 0) {
            // Page header
            try self.processPageHeader(packet);
        } else if (packet.packet_number >= 1 and packet.packet_number <= 23) {
            // Data row
            try self.processDataRow(packet);
        } else if (packet.packet_number == 26) {
            // Page enhancement
            try self.processEnhancement(packet);
        }
        // Other packet types can be implemented as needed
    }

    fn processPageHeader(self: *TeletextDecoder, packet: Teletext.Packet) !void {
        // Decode page number (Hamming 8/4)
        const page_units = HAMMING_8_4_DECODE[packet.data[0]];
        const page_tens = HAMMING_8_4_DECODE[packet.data[1]];

        if (page_units < 0 or page_tens < 0) return error.HammingError;

        const page_number: u8 = @intCast(page_tens * 10 + page_units);

        // Decode subpage (Hamming 8/4)
        var subpage: u16 = 0;
        for (0..4) |i| {
            const nibble = HAMMING_8_4_DECODE[packet.data[2 + i]];
            if (nibble < 0) return error.HammingError;
            subpage |= @as(u16, @intCast(nibble)) << @intCast(i * 4);
        }

        // Control bits (Hamming 8/4)
        const c4 = HAMMING_8_4_DECODE[packet.data[5]];
        const c5_c6 = HAMMING_8_4_DECODE[packet.data[6]];
        const c7_c10 = HAMMING_8_4_DECODE[packet.data[7]];

        if (c4 < 0 or c5_c6 < 0 or c7_c10 < 0) return error.HammingError;

        const control_bits = Teletext.ControlBits{
            .erase_page = (c4 & 0x01) != 0,
            .newsflash = (c4 & 0x04) != 0,
            .subtitle = (c4 & 0x08) != 0,
            .suppress_header = (c5_c6 & 0x01) != 0,
            .update_indicator = (c5_c6 & 0x02) != 0,
            .interrupted_sequence = (c5_c6 & 0x04) != 0,
            .inhibit_display = (c5_c6 & 0x08) != 0,
            .magazine_serial = (c7_c10 & 0x01) != 0,
        };

        const language: u3 = @truncate((c7_c10 >> 1) & 0x07);

        // Create new page
        var page = Teletext.Page{
            .magazine = packet.magazine,
            .page = page_number,
            .subpage = subpage,
            .control_bits = control_bits,
            .language = language,
            .rows = undefined,
            .enhancement = null,
        };

        // Initialize rows
        for (&page.rows) |*row| {
            @memset(&row.data, 0x20); // Space character
            @memset(&row.attributes, Teletext.Attributes{
                .foreground = .white,
                .background = .black,
                .double_height = false,
                .double_width = false,
                .flash = false,
                .concealed = false,
                .boxed = false,
                .separated = false,
            });
        }

        // Copy header text (bytes 8-39)
        @memcpy(page.rows[0].data[0..32], packet.data[8..40]);

        self.current_page = page;

        // Store in page buffer
        const page_key = @as(u32, packet.magazine) << 8 | page_number;
        try self.page_buffer.put(page_key, page);
    }

    fn processDataRow(self: *TeletextDecoder, packet: Teletext.Packet) !void {
        if (self.current_page) |*page| {
            const row_number = packet.packet_number;
            if (row_number >= 1 and row_number <= 23) {
                // Copy data
                @memcpy(&page.rows[row_number].data, &packet.data);

                // Parse attributes from control codes
                try self.parseAttributes(&page.rows[row_number]);

                // Update stored page
                const page_key = @as(u32, page.magazine) << 8 | page.page;
                try self.page_buffer.put(page_key, page.*);
            }
        }
    }

    fn processEnhancement(self: *TeletextDecoder, packet: Teletext.Packet) !void {
        if (self.current_page) |*page| {
            // Parse enhancement triplets
            var triplets = std.ArrayList(Teletext.Triplet).init(self.allocator);

            var i: usize = 1; // Skip designation code
            while (i + 2 < packet.data.len) : (i += 3) {
                const triplet = Teletext.Triplet{
                    .address = @truncate(packet.data[i] & 0x3F),
                    .mode = @truncate(packet.data[i + 1] & 0x1F),
                    .data = @truncate(packet.data[i + 2] & 0x7F),
                };
                try triplets.append(triplet);
            }

            page.enhancement = .{ .triplets = try triplets.toOwnedSlice() };

            // Update stored page
            const page_key = @as(u32, page.magazine) << 8 | page.page;
            try self.page_buffer.put(page_key, page.*);
        }
    }

    fn parseAttributes(self: *TeletextDecoder, row: *Teletext.Row) !void {
        _ = self;
        var current_attr = Teletext.Attributes{
            .foreground = .white,
            .background = .black,
            .double_height = false,
            .double_width = false,
            .flash = false,
            .concealed = false,
            .boxed = false,
            .separated = false,
        };

        for (row.data, 0..) |char, i| {
            // Control codes (0x00-0x1F)
            if (char < 0x20) {
                switch (char) {
                    0x01...0x07 => current_attr.foreground = @enumFromInt(char), // Alpha color
                    0x08 => current_attr.flash = true,
                    0x09 => {
                        current_attr.flash = false;
                    }, // Steady
                    0x0C => current_attr.double_height = false,
                    0x0D => current_attr.double_height = true,
                    0x11...0x17 => current_attr.foreground = @enumFromInt(char - 0x10), // Graphics color
                    0x18 => current_attr.concealed = true,
                    0x19 => current_attr.boxed = true,
                    0x1A => current_attr.separated = true,
                    0x1C => {
                        current_attr.background = .black;
                    }, // Black background
                    0x1D => current_attr.background = current_attr.foreground, // New background
                    else => {},
                }
            }
            row.attributes[i] = current_attr;
        }
    }

    /// Decode Hamming 8/4 byte pair into single byte
    fn decodeHamming84Pair(self: *TeletextDecoder, byte1: u8, byte2: u8) !u8 {
        _ = self;
        const low = HAMMING_8_4_DECODE[byte1];
        const high = HAMMING_8_4_DECODE[byte2];

        if (low < 0 or high < 0) return error.HammingError;

        return @intCast((high << 4) | low);
    }

    /// Decode odd parity byte
    fn decodeOddParity(self: *TeletextDecoder, byte: u8) !u8 {
        _ = self;
        // Check parity
        const data = byte & 0x7F;
        var parity: u8 = 0;
        var temp = byte;
        while (temp > 0) : (temp >>= 1) {
            parity ^= temp & 1;
        }

        if (parity == 0) return error.ParityError;

        return data;
    }

    /// Hamming 8/4 decode lookup (returns -1 on error)
    fn hamming84Decode(byte: u8) i8 {
        // Hamming 8/4 syndrome table
        const SYNDROMES = [16]u8{
            0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
            0x0e, 0x0b, 0x0d, 0x07, 0x15, 0x16, 0x19, 0x1a,
        };

        // Calculate syndrome
        var syndrome: u8 = 0;
        var temp = byte;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            if ((temp & 1) != 0) {
                syndrome ^= SYNDROMES[bit];
            }
            temp >>= 1;
        }

        // No error
        if (syndrome == 0) {
            return @intCast((byte & 0x02) >> 1 |
                (byte & 0x08) >> 2 |
                (byte & 0x20) >> 3 |
                (byte & 0x80) >> 4);
        }

        // Single bit error - correct it
        for (SYNDROMES, 0..) |syn, i| {
            if (syndrome == syn) {
                const corrected = byte ^ (@as(u8, 1) << @intCast(i));
                return @intCast((corrected & 0x02) >> 1 |
                    (corrected & 0x08) >> 2 |
                    (corrected & 0x20) >> 3 |
                    (corrected & 0x80) >> 4);
            }
        }

        // Uncorrectable error
        return -1;
    }

    /// Get a specific page from buffer
    pub fn getPage(self: *TeletextDecoder, magazine: Teletext.Magazine, page: u8) ?Teletext.Page {
        const key = @as(u32, magazine) << 8 | page;
        return self.page_buffer.get(key);
    }

    /// Convert teletext page to plain text
    pub fn pageToText(self: *TeletextDecoder, page: *const Teletext.Page, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        var text = std.ArrayList(u8).init(allocator);

        for (page.rows, 0..) |row, i| {
            // Skip header row if suppressed
            if (i == 0 and page.control_bits.suppress_header) continue;

            // Copy non-control characters
            for (row.data) |char| {
                if (char >= 0x20 and char <= 0x7E) {
                    try text.append(char);
                }
            }
            try text.append('\n');
        }

        return text.toOwnedSlice();
    }
};
