# Counted keyframe intent

`codecs/video/keyframe_requests.zig` supplies an allocation-free, caller-serialized
ledger for public keyframe requests. Repeated requests stay distinct: one intent
is consumed per accepted input, even when that input already begins a GOP. An
encoder may delay the corresponding output packet. Consume after input admission,
not after output delivery, and do not consume for an invalid/rejected input.

The default pending capacity is UINT32_MAX with monotonic 64-bit requested and
applied counters. Capacity/exhaustion errors leave state unchanged. `Ledger(n)`
allows a caller to choose a smaller bound. An independently constructed ledger
starts a new session; keep the old ledger if a session replacement rolls back.
The ledger does not invoke an encoder, cancel jobs, promise decoded random access,
provide thread safety or acknowledge sink delivery. Serialize commits/cancellation
in the owner's existing lock, and use native_encoder.Encoder.requestKeyframe for
the actual AVC/HEVC IDR operation. Internal split/recovery keyframes can remain
coalesced independently of counted public intent. MJPEG inputs are inherently key.
