# Checked elementary packet and PTS output

`src/core/packet_output.zig` is a standalone, allocation-free boundary for
reusable streaming sinks. The broader sink graph includes decoded-frame and
accumulating packet collections; this module neither retains borrowed packets
nor imports that graph.

`annexB(input, output)` converts four-byte big-endian length-prefixed AVC/HEVC
NAL units to four-byte Annex B start codes. It checks every length before writing
any destination bytes, rejects empty/truncated/zero-length input, and checks
output capacity. Input/output must not overlap. Parameter sets can be converted
separately and prepended at the first key of a newly attached output.

`formatPts(timestamp_us, output)` formats integer microsecond PTS as milliseconds
with exactly three decimal digits and LF. Zero and all u64 timestamps are exact;
no floating-point rounding or locale formatting is used. Too-small buffers remain
unchanged. A 32-byte destination covers the complete u64 range.

`PtsWriter` wraps an explicit synchronous `Sink{context,write}`. Sink callbacks
must completely accept their borrowed data or return an error. Rejected
non-increasing timestamps do not touch the sink. A sink failure poisons the
writer; create a fresh writer for a new clip/epoch. The module does not own files,
threads or packet storage and does not depend on FFmpeg/Libav.

Focused tests on Zig 0.15.2 and the Home development toolchain:

```sh
zig test packages/video/src/core/packet_output.zig
```

Tests cover multi-NAL conversion, malformed/truncated input, exact maximum PTS,
small-buffer state preservation, monotonicity and sink-failure poisoning.
zig-camera uses the helpers at its native callback output boundary, with
independent video decoding and media/PTS timeline checks in its integration suite.

`Slots(T, capacity)` provides fixed-capacity attachment identities for serialized
packet fan-out owners. `add` returns a nonzero ID; `get` and `remove` reject stale
IDs even after a slot is reused. Capacity and ID exhaustion leave entries intact.
No allocation, sink callbacks or payload destruction occur inside the registry;
the caller retains ownership and synchronization. IDs never wrap or repeat.
This supports independent container/PTS lifetimes while sharing encoded packets.

`Slots.replace(id, value)` swaps a live payload while preserving its ID and the
registry count. It returns the old payload for caller-managed finalization.
A stale ID fails before mutation. Packet producers can therefore commit one
attachment's keyframe-aligned replacement without disturbing other attachments
or allowing an old detach request to affect a different logical sink.
