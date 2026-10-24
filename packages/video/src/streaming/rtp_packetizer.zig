//! Allocation-free RTP send-side framing. Access units borrow immutable bytes.
//! AVC non-interleaved single NAL/FU-A; HEVC single NAL/FU without DONL;
//! AAC-hbr one raw AU (or its fragments), 13/3/3 AU headers. No retransmission.
const std = @import("std");
const wire = @import("rtp_wire.zig");
const Nal = @import("../core/nal_convert.zig").NalIterator;
pub const Codec = enum { h264, hevc, aac };
pub const Format = enum { annex_b, length4, raw };
pub const Limits = struct { max_bytes: usize = 16 * 1024 * 1024, max_nals: u32 = 4096, max_packets: u32 = 65536 };
pub const Config = struct { codec: Codec, format: Format, mtu: u16 = 1200, payload_type: u7 = 96, sequence: u16, timestamp: u32, ssrc: u32 };
pub fn timestamp(ns: u64, clock_rate: u32, origin: u32) !u32 {
    if (clock_rate == 0) return error.InvalidClock;
    const ticks: u128 = @as(u128, ns) * clock_rate / 1_000_000_000;
    return origin +% @as(u32, @truncate(ticks));
}
pub const Packetizer = struct {
    config: Config,
    iterator: Nal,
    current: ?[]const u8 = null,
    offset: usize = 0,
    total: u32,
    emitted: u32 = 0,
    sequence: u16,
    pub fn init(config: Config, data: []const u8, limits: Limits) !Packetizer {
        if (config.mtu < 64 or config.mtu > 65507 or limits.max_bytes == 0 or limits.max_nals == 0 or limits.max_packets == 0) return error.InvalidConfig;
        if (data.len == 0) return error.EmptyAccessUnit;
        if (data.len > limits.max_bytes) return error.LimitExceeded;
        if ((config.codec == .aac) != (config.format == .raw)) return error.InvalidFormat;
        const iterator = try Nal.init(if (config.codec == .aac) &.{} else data, if (config.format == .annex_b) .annex_b else .length_prefixed, 4);
        var scan = iterator;
        var count: usize = 0;
        var packets: usize = 0;
        if (config.codec == .aac) {
            if (data.len > 8191) return error.LimitExceeded;
            packets = std.math.divCeil(usize, data.len, config.mtu - 16) catch unreachable;
        } else while (try scan.next()) |nal| {
            count += 1;
            if (count > limits.max_nals) return error.LimitExceeded;
            if (nal[0] & 0x80 != 0) return error.InvalidNal;
            const header: usize = if (config.codec == .h264) 1 else 2;
            if (config.codec == .h264) {
                const kind = nal[0] & 31;
                if (kind == 0 or kind >= 24) return error.InvalidNal;
            } else {
                if (nal.len < 2 or nal[1] & 7 == 0 or (nal[0] >> 1) & 63 >= 48) return error.InvalidNal;
            }
            packets += if (nal.len <= config.mtu - 12) 1 else std.math.divCeil(usize, nal.len - header, config.mtu - 12 - header - 1) catch unreachable;
            if (packets > limits.max_packets) return error.LimitExceeded;
        }
        if (packets == 0) return error.EmptyAccessUnit;
        if (packets > limits.max_packets) return error.LimitExceeded;
        return .{ .config = config, .iterator = iterator, .current = if (config.codec == .aac) data else null, .total = @intCast(packets), .sequence = config.sequence };
    }
    fn load(self: *Packetizer) void {
        if (self.current == null) self.current = self.iterator.next() catch unreachable;
    }
    fn size(self: *Packetizer) usize {
        self.load();
        const nal = self.current.?;
        if (self.config.codec == .aac) return 16 + @min(nal.len - self.offset, self.config.mtu - 16);
        if (nal.len <= self.config.mtu - 12) return 12 + nal.len;
        const header: usize = if (self.config.codec == .h264) 1 else 2;
        return 12 + header + 1 + @min(nal.len - header - self.offset, self.config.mtu - 12 - header - 1);
    }
    /// Query never advances the cursor. A short destination never changes it or
    /// any output byte. Source must remain immutable until this cursor retires.
    pub fn nextSize(self: Packetizer) usize {
        if (self.emitted == self.total) return 0;
        var candidate = self;
        return candidate.size();
    }
    pub fn next(self: *Packetizer, out: []u8) !usize {
        const needed = self.nextSize();
        if (needed == 0) return 0;
        if (out.len < needed) return error.BufferTooSmall;
        var candidate = self.*;
        candidate.load();
        const nal = candidate.current.?;
        const header = wire.RtpHeader{ .payload_type = self.config.payload_type, .sequence_number = self.sequence, .timestamp = self.config.timestamp, .ssrc = self.config.ssrc, .marker = self.emitted + 1 == self.total };
        _ = try header.encode(out);
        if (self.config.codec == .aac) {
            std.mem.writeInt(u16, out[12..14], 16, .big);
            std.mem.writeInt(u16, out[14..16], @as(u16, @intCast(nal.len)) << 3, .big);
            const length = needed - 16;
            @memcpy(out[16..needed], nal[candidate.offset..][0..length]);
            candidate.offset += length;
            if (candidate.offset == nal.len) {
                candidate.current = null;
                candidate.offset = 0;
            }
        } else if (nal.len <= self.config.mtu - 12) {
            @memcpy(out[12..needed], nal);
            candidate.current = null;
        } else {
            const original: usize = if (self.config.codec == .h264) 1 else 2;
            const length = needed - 12 - original - 1;
            const first = candidate.offset == 0;
            const last = candidate.offset + length == nal.len - original;
            const flags: u8 = (if (first) @as(u8, 0x80) else 0) | (if (last) @as(u8, 0x40) else 0);
            if (self.config.codec == .h264) {
                out[12] = (nal[0] & 0xe0) | 28;
                out[13] = flags | (nal[0] & 31);
            } else {
                out[12] = (nal[0] & 0x81) | (49 << 1);
                out[13] = nal[1];
                out[14] = flags | ((nal[0] >> 1) & 63);
            }
            @memcpy(out[12 + original + 1 .. needed], nal[original + candidate.offset ..][0..length]);
            candidate.offset += length;
            if (last) {
                candidate.current = null;
                candidate.offset = 0;
            }
        }
        candidate.sequence +%= 1;
        candidate.emitted += 1;
        self.* = candidate;
        return needed;
    }
};
pub const SenderReport = struct { ssrc: u32, unix_ns: u64, rtp_timestamp: u32, packets: u32, octets: u32, cname: []const u8, bye: bool = false };
/// Compound SR + SDES CNAME, optionally BYE. NTP's seconds word wraps by era.
/// unix_ns and rtp_timestamp must describe the SAME sampling instant. Caller
/// supplies the shared clock correlation; this helper never reads a wall clock.
pub fn senderReportSize(report: SenderReport) !usize {
    if (report.cname.len == 0 or report.cname.len > 255 or !std.unicode.utf8ValidateSlice(report.cname) or std.mem.indexOfScalar(u8, report.cname, 0) != null) return error.InvalidCname;
    return 28 + std.mem.alignForward(usize, 11 + report.cname.len, 4) + @as(usize, if (report.bye) 8 else 0);
}
pub fn senderReport(out: []u8, report: SenderReport) !usize {
    const needed = try senderReportSize(report);
    const sdes = std.mem.alignForward(usize, 11 + report.cname.len, 4);
    if (out.len < needed) return error.BufferTooSmall;
    @memset(out[0..needed], 0);
    out[0] = 0x80;
    out[1] = 200;
    std.mem.writeInt(u16, out[2..4], 6, .big);
    std.mem.writeInt(u32, out[4..8], report.ssrc, .big);
    std.mem.writeInt(u32, out[8..12], @truncate(report.unix_ns / 1_000_000_000 + 2_208_988_800), .big);
    std.mem.writeInt(u32, out[12..16], @intCast((@as(u64, report.unix_ns % 1_000_000_000) << 32) / 1_000_000_000), .big);
    std.mem.writeInt(u32, out[16..20], report.rtp_timestamp, .big);
    std.mem.writeInt(u32, out[20..24], report.packets, .big);
    std.mem.writeInt(u32, out[24..28], report.octets, .big);
    out[28] = 0x81;
    out[29] = 202;
    std.mem.writeInt(u16, out[30..32], @intCast(sdes / 4 - 1), .big);
    std.mem.writeInt(u32, out[32..36], report.ssrc, .big);
    out[36] = 1;
    out[37] = @intCast(report.cname.len);
    @memcpy(out[38..][0..report.cname.len], report.cname);
    if (report.bye) {
        const at = 28 + sdes;
        out[at] = 0x81;
        out[at + 1] = 203;
        std.mem.writeInt(u16, out[at + 2 ..][0..2], 1, .big);
        std.mem.writeInt(u32, out[at + 4 ..][0..4], report.ssrc, .big);
    }
    return needed;
}

test "RTP clock scaling retains rational precision and wraps deliberately" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 3003), try timestamp(33_366_667, 90000, 0));
    try t.expectEqual(@as(u32, 2), try timestamp(1_000_000_000, 3, 0xffffffff));
    try t.expectEqual(@as(u32, @truncate(@as(u128, std.math.maxInt(u64)) * 90000 / 1_000_000_000)), try timestamp(std.math.maxInt(u64), 90000, 0));
    try t.expectError(error.InvalidClock, timestamp(0, 0, 0));
}
test "RTP packetizer validates whole AU before publication and short writes are atomic" {
    const t = std.testing;
    const cfg = Config{ .codec = .h264, .format = .length4, .mtu = 64, .sequence = 65535, .timestamp = 99, .ssrc = 123 };
    try t.expectError(error.TruncatedNal, Packetizer.init(cfg, &.{ 0, 0, 0, 1, 0x65, 9 }, .{}));
    try t.expectError(error.InvalidNal, Packetizer.init(cfg, &.{ 0, 0, 0, 1, 0x80 }, .{}));
    var p = try Packetizer.init(cfg, &.{ 0, 0, 0, 2, 0x67, 9, 0, 0, 0, 2, 0x65, 8 }, .{});
    var out: [128]u8 = @splat(0xa5);
    const before = p;
    try t.expectError(error.BufferTooSmall, p.next(out[0..13]));
    try t.expectEqualDeep(before, p);
    for (out) |v| try t.expectEqual(@as(u8, 0xa5), v);
    try t.expectEqual(@as(usize, 14), try p.next(&out));
    try t.expectEqual(@as(u8, 96), out[1]);
    try t.expectEqual(@as(u16, 65535), std.mem.readInt(u16, out[2..4], .big));
    try t.expectEqual(@as(usize, 14), try p.next(&out));
    try t.expectEqual(@as(u8, 224), out[1]);
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[2..4], .big));
    try t.expectEqual(@as(usize, 0), p.nextSize());
    try t.expectEqual(@as(usize, 0), try p.next(&out));
}
test "AVC HEVC and AAC fragments preserve every payload byte marker header and exact MTU" {
    const t = std.testing;
    for ([_]Codec{ .h264, .hevc, .aac }) |codec| for ([_]usize{ 1, 2, 49, 50, 51, 52, 53, 99, 150, 8191 }) |length| {
        if (codec == .hevc and length < 2) continue;
        var au: [8200]u8 = undefined;
        @memset(&au, 0x55);
        const head: usize = if (codec == .h264) 1 else 2;
        if (codec == .h264) au[4] = 0x65 else {
            au[4] = 0x27;
            au[5] = 0x15;
        }
        std.mem.writeInt(u32, au[0..4], @intCast(length), .big);
        var p = try Packetizer.init(.{ .codec = codec, .format = if (codec == .aac) .raw else .length4, .mtu = 64, .sequence = 65535, .timestamp = 0xfedcba98, .ssrc = 0x12345678 }, if (codec == .aac) au[4..][0..length] else au[0 .. 4 + length], .{});
        var rebuilt: std.ArrayList(u8) = .empty;
        defer rebuilt.deinit(t.allocator);
        var packet: [64]u8 = undefined;
        var index: usize = 0;
        while (true) {
            const size = try p.next(&packet);
            if (size == 0) break;
            const h = try wire.RtpHeader.decode(packet[0..size]);
            try t.expectEqual(@as(u16, @truncate(@as(usize, 65535) + index)), h.sequence_number);
            try t.expectEqual(index + 1 == p.total, h.marker);
            try t.expect(size <= 64);
            try t.expectEqual(@as(u32, 0xfedcba98), h.timestamp);
            try t.expectEqual(@as(u32, 0x12345678), h.ssrc);
            if (codec == .aac) {
                try t.expectEqual(@as(u16, 16), std.mem.readInt(u16, packet[12..14], .big));
                try t.expectEqual(length, std.mem.readInt(u16, packet[14..16], .big) >> 3);
                try rebuilt.appendSlice(t.allocator, packet[16..size]);
            } else if (length <= 52) try rebuilt.appendSlice(t.allocator, packet[12..size]) else {
                const flag = packet[12 + head];
                try t.expectEqual(index == 0, flag & 0x80 != 0);
                try t.expectEqual(index + 1 == p.total, flag & 0x40 != 0);
                if (index == 0) try rebuilt.appendSlice(t.allocator, au[4..][0..head]);
                if (codec == .h264) {
                    try t.expectEqual(@as(u8, 0x7c), packet[12]);
                    try t.expectEqual(@as(u8, 5), flag & 31);
                } else {
                    try t.expectEqual(@as(u8, 0x63), packet[12]);
                    try t.expectEqual(@as(u8, 0x15), packet[13]);
                    try t.expectEqual(@as(u8, 19), flag & 63);
                }
                try rebuilt.appendSlice(t.allocator, packet[13 + head .. size]);
            }
            index += 1;
        }
        try t.expectEqualSlices(u8, au[4..][0..length], rebuilt.items);
        try t.expectEqual(p.total, index);
    };
}
test "RTCP compound reports preflight CNAME and capacity and encode correlated NTP SR SDES BYE" {
    const t = std.testing;
    const report = SenderReport{ .ssrc = 0x01020304, .unix_ns = 1_500_000_000, .rtp_timestamp = 90000, .packets = 12, .octets = 345, .cname = "trail", .bye = true };
    var bytes: [80]u8 = @splat(0xa5);
    try t.expectError(error.BufferTooSmall, senderReport(bytes[0..51], report));
    for (bytes) |b| try t.expectEqual(@as(u8, 0xa5), b);
    try t.expectEqual(@as(usize, 52), try senderReport(&bytes, report));
    try t.expectEqual(@as(u32, 2_208_988_801), std.mem.readInt(u32, bytes[8..12], .big));
    try t.expectEqual(@as(u32, 0x80000000), std.mem.readInt(u32, bytes[12..16], .big));
    try t.expectEqual(@as(u8, 202), bytes[29]);
    try t.expectEqualSlices(u8, "trail", bytes[38..43]);
    try t.expectEqual(@as(u8, 203), bytes[45]);
    var bad = report;
    bad.cname = "";
    try t.expectError(error.InvalidCname, senderReport(&bytes, bad));
}

test "RTP admission validates MTU format NAL types and all byte NAL and packet caps" {
    const t = std.testing;
    const good = [_]u8{ 0, 0, 1, 0x65, 1 };
    var cfg = Config{ .codec = .h264, .format = .annex_b, .sequence = 0, .timestamp = 0, .ssrc = 1 };
    cfg.mtu = 63;
    try t.expectError(error.InvalidConfig, Packetizer.init(cfg, &good, .{}));
    cfg.mtu = 65508;
    try t.expectError(error.InvalidConfig, Packetizer.init(cfg, &good, .{}));
    cfg.mtu = 64;
    try t.expectError(error.EmptyAccessUnit, Packetizer.init(cfg, &.{}, .{}));
    try t.expectError(error.LimitExceeded, Packetizer.init(cfg, &good, .{ .max_bytes = 4 }));
    try t.expectError(error.LimitExceeded, Packetizer.init(cfg, &.{ 0, 0, 1, 0x65, 1, 0, 0, 1, 0x61, 1 }, .{ .max_nals = 1 }));
    try t.expectError(error.LimitExceeded, Packetizer.init(cfg, &.{ 0, 0, 1, 0x65, 1, 0, 0, 1, 0x61, 1 }, .{ .max_packets = 1 }));
    try t.expectError(error.InvalidConfig, Packetizer.init(cfg, &good, .{ .max_packets = 0 }));
    for ([_]u8{ 0, 24, 28, 31, 0xe5 }) |kind| try t.expectError(error.InvalidNal, Packetizer.init(cfg, &.{ 0, 0, 1, kind, 1 }, .{}));
    cfg.codec = .hevc;
    for ([_][]const u8{ &.{ 0, 0, 1, 0x26 }, &.{ 0, 0, 1, 0x26, 0 }, &.{ 0, 0, 1, 0x60, 1 }, &.{ 0, 0, 1, 0xe6, 1 } }) |bytes| try t.expectError(error.InvalidNal, Packetizer.init(cfg, bytes, .{}));
    cfg.format = .raw;
    try t.expectError(error.InvalidFormat, Packetizer.init(cfg, &good, .{}));
    cfg.codec = .aac;
    var too_big: [8192]u8 = @splat(1);
    try t.expectError(error.LimitExceeded, Packetizer.init(cfg, &too_big, .{}));
    cfg.format = .annex_b;
    try t.expectError(error.InvalidFormat, Packetizer.init(cfg, &good, .{}));
}

/// Signed presentation times retain encoder priming before a stream's zero.
/// Division rounds down, including negative values; RTP's wire clock wraps.
pub fn signedTimestamp(ns: i64, clock_rate: u32, origin: u32) !u32 {
    if (clock_rate == 0) return error.InvalidClock;
    const ticks = @divFloor(@as(i128, ns) * clock_rate, 1_000_000_000);
    const word: u32 = @truncate(@as(u128, @bitCast(ticks)));
    return origin +% word;
}
test "signed RTP clocks preserve negative codec priming and all integer endpoints" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0xfffff800), try signedTimestamp(-42_666_666, 48000, 0));
    try t.expectEqual(@as(u32, 0xffffffff), try signedTimestamp(-1, 48000, 0));
    try t.expectEqual(try timestamp(42_666_666, 48000, 0), try signedTimestamp(42_666_666, 48000, 0));
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |value| {
        const expected: i128 = @divFloor(@as(i128, value) * 90000, 1_000_000_000);
        try t.expectEqual(@as(u32, @truncate(@as(u128, @bitCast(expected)))), try signedTimestamp(value, 90000, 0));
    }
    try t.expectError(error.InvalidClock, signedTimestamp(0, 0, 0));
}

pub const HevcProfile = struct { space: u8, tier: u8, id: u8, level: u8, compatibility: u32, constraints: u64 };
/// Read only the general profile-tier-level prefix of an SPS NAL, excluding
/// framing. Bounded stack work; validates emulation prevention in this prefix.
/// This is not an SPS syntax/conformance validator and does not parse sublayers.
pub fn hevcProfile(nal: []const u8) !HevcProfile {
    if (nal.len < 2 or nal[0] & 0x80 != 0 or (nal[0] >> 1) & 63 != 33 or nal[1] & 7 == 0) return error.InvalidNal;
    var raw: [13]u8 = undefined;
    var at: usize = 2;
    var count: usize = 0;
    var zeros: usize = 0;
    while (count < raw.len) {
        if (at == nal.len) return error.TruncatedSps;
        const byte = nal[at];
        at += 1;
        if (zeros == 2) {
            if (byte <= 2) return error.InvalidEmulationPrevention;
            if (byte == 3) {
                if (at == nal.len or nal[at] > 3) return error.InvalidEmulationPrevention;
                zeros = 0;
                continue;
            }
        }
        raw[count] = byte;
        count += 1;
        zeros = if (byte == 0) zeros + 1 else 0;
    }
    if ((raw[0] >> 1) & 7 == 7 or (raw[0] & 15 == 0)) return error.InvalidSps;
    var constraints: u64 = 0;
    for (raw[6..12]) |byte| constraints = (constraints << 8) | byte;
    return .{ .space = raw[1] >> 6, .tier = (raw[1] >> 5) & 1, .id = raw[1] & 31, .level = raw[12], .compatibility = std.mem.readInt(u32, raw[2..6], .big), .constraints = constraints };
}
test "HEVC RTP signaling extracts actual general profile tier compatibility constraints and level" {
    const t = std.testing;
    const nal = [_]u8{ 0x42, 1, 1, 0xa2, 0, 0, 3, 0, 1, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 156 };
    const profile = try hevcProfile(&nal);
    try t.expectEqualDeep(HevcProfile{ .space = 2, .tier = 1, .id = 2, .level = 156, .compatibility = 1, .constraints = 0x123456789abc }, profile);
    for (0..nal.len) |length| try t.expectError(if (length < 2) error.InvalidNal else if (length == 7) error.InvalidEmulationPrevention else error.TruncatedSps, hevcProfile(nal[0..length]));
    var bad = nal;
    bad[6] = 0;
    try t.expectError(error.InvalidEmulationPrevention, hevcProfile(&bad));
    bad = nal;
    bad[7] = 4;
    try t.expectError(error.InvalidEmulationPrevention, hevcProfile(&bad));
}
