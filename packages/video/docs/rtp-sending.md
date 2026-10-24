# RTP sending primitives

`video.RtpPacketizer` borrows one immutable complete access unit and emits RTP
version 2 datagrams into caller buffers, without allocating. `init` validates the
whole input, including every NAL header and suffix, before any packet is visible.
Bounds cover AU bytes, NAL count and packet count. The MTU includes the 12-byte
RTP header and must be 64–65507 bytes. Defaults cap input at 16 MiB, 4096 NALs and
65536 packets. Short output buffers preserve all state and destination bytes;
`nextSize` never advances. The caller serializes access and keeps input immutable.

AVC implements RFC 6184 single NAL and FU-A in non-interleaved mode. HEVC implements
RFC 7798 single NAL and FU with preserved layer/temporal IDs and no DONL (signal
sprop-max-don-diff=0). Video inputs may use Annex B or four-byte big-endian lengths.
AAC uses RFC 3640 AAC-hbr: one raw AU or AU fragment per packet, 13-bit full AU size
and 3-bit zero index, at most 8191 AU bytes. AAC input excludes ADTS. All packets
for one AU share timestamp and SSRC; only the final packet has marker set. Sequence
numbers wrap as unsigned 16-bit values. No aggregation or interleaving is emitted.

`rtp_packetizer.timestamp` maps unsigned nanoseconds to a supplied RTP clock rate
and offset with exact wide integer arithmetic and intentional 32-bit wrap.
`senderReport` emits a compound RTCP SR + SDES CNAME and optional BYE. The supplied
Unix nanoseconds and RTP timestamp MUST describe the same sampling instant, using
a shared correlation for synchronized media. Packet/octet counters wrap at 32
bits; octets count RTP payload including codec framing, excluding RTP headers.
The NTP seconds word wraps by era. This helper does not read clocks or schedule
RTCP, handle receiver reports, congestion or SSRC collisions, open sockets, or
implement a complete RTP/RTSP/WebRTC session.

`nal_convert.NalIterator` is strict, borrowed and linear. Annex B rejects unrelated
prefixes and empty units and excludes framing zeros. Length-prefixed input accepts
1/2/4-byte sizes and rejects zero lengths or any incomplete suffix. Existing
allocated parse functions now use this iterator; malformed input is no longer
silently ignored. `RtpPacket.parse` now excludes validated extensions and padding,
and fixed-header encoding preflights the complete CSRC capacity before writing.

The explicit src/rtp_test.zig root and tests/rtp_packetizer.zig public API test cover
both pinned and development Zig. Standards: RFC 3550, RFC 6184, RFC 7798, RFC 3640.

`signedTimestamp` additionally accepts signed 64-bit nanoseconds for codec
priming before the presentation origin. It rounds down consistently for negative
samples and intentionally wraps on the RTP wire; timestamps must keep their sign
until clock conversion, rather than clamping priming to zero.

`hevcProfile` reads a bounded general profile-tier-level prefix from a borrowed
SPS NAL, including emulation-prevention handling, so SDP can carry the actual
profile, tier, level, compatibility and constraint bits. It does not validate the
remaining SPS or parse sublayer profiles.

The NAL parser uses the allocator-explicit `std.ArrayList` spelling supported by
Zig 0.15.2 and current development Zig. This replaces the removed development
`ArrayListUnmanaged` alias without changing list ownership or framing behavior.
