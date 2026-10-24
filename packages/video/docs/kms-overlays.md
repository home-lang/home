# Hosted Linux KMS overlays

The explicit Zig 0.15.2 `kms_host.zig` entry exposes `scanout.Device.openOverlay`
and `presentPair`. The primary must remain at a stable address until its child
finishes cleanup. One child borrows its DRM master/event FD and shares its cookie
sequence; closing the primary while borrowed is rejected. Close/detach the child
before the primary, retaining both owners on cleanup failure.

Selection requires an unused AR24 non-cursor plane on the same active CRTC,
proven strictly higher zpos and a named Coverage or Pre-multiplied blend mode.
Mutable properties are restored after detach. Missing or unsuitable properties
are unsupported rather than assumed. `premultipliedAlpha` tells the caller how
to populate pixels. Home image's `ops/rgba_view.zig::View.toBgra` validates both
padded spans, rejects overlap and performs exact rounded 8-bit premultiplication.

Use the existing two-slot driver CPU pool and finishCpu before submission.
`presentPair` validates both targets and runs one two-object TEST_ONLY request,
then one two-object actual update with a matching CRTC/cookie retirement event.
Rejected tests preserve confirmed gates. Unknown actual submits retain possible
owners in both planes until detach proves retirement. A successful callback is
not proof that the displayed buffers are reusable.

This hosted API does not set display modes, take occupied planes or implement
Home OS kernel hardware ownership. Physical Pi display/color acceptance is still
required; system-header independent Linux camera peers provide fault/lifetime
acceptance without claiming actual display hardware support.
