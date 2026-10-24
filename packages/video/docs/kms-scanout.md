# Direct Linux atomic plane scanout

`kms_scanout` contains bounded linear buffer layout, PRIME handle reference and
frame-retirement policy. `kms_scanout_host.Device` uses the shared discovery
driver/UAPI adapter to import those buffers and operate one unused plane on a
connected, already active CRTC. Host code requires Zig 0.15.2 on Linux; portable
policy also supports development Zig. Both export through `video.zig`.

The caller owns source leases. Two resource slots carry opaque Gate tokens 1/2;
keep their source owners live while the gate names either slot. `prepare` imports
DMABUF FDs and creates a framebuffer, without copying pixels. `present` validates
the configuration with TEST_ONLY, submits NONBLOCK plus PAGE_FLIP_EVENT, then
joins the matching private-FD cookie/CRTC event. Only a matching event retires
the old source. An unconfirmed or failed submit preserves both possible owners
and stops further feed. `detach` restores original plane properties and joins its
completion before clearing both tokens. No mode setting or occupied-plane
takeover is performed. The private RW/CLOEXEC/nonblocking card FD acquires master;
sharing a card between multiple independent master FDs is not implemented.

The registry manually counts aliased PRIME handles, including aliases among
multiple plane imports and different active framebuffers. Kernel FD_TO_HANDLE
does not provide those extra user references. Unique handles close only after
their final slot releases them; failed GEM_CLOSE retains identity until cleanup.
Linear layout supports RGB/BGR24, RGBX/BGRX32, planar YUV/YVU420, NV12/21 and four
packed 422 orders, with checked independent or contiguous plane offsets/strides.
Nonlinear layouts, modifiers, additional formats and buffer allocation are outside
this helper. Caller-provided layouts and source FDs remain immutable during use.

Geometry uses explicit signed placement, scaling and DRM counter-clockwise
rotation/source-reflection bits. RGB planes are opaque. YUV requires advertised
COLOR_ENCODING/COLOR_RANGE values by enum name, rather than assumed numbers.
Available alpha is set opaque; original geometry/rotation/color/alpha properties
are restored at detach. This does not implement color management, HDR mode setting,
overlay-plane allocation or a desktop compositor/DRM lease integration.

Each event wait has a 1..60000 ms timeout and 64-event budget, with structural,
cookie and CRTC checks. The kernel ioctl itself is not a wall-clock-bounded
operation. A timeout/error retains ownership for explicit retry; closing a
private FD alone is not treated as proof that camera scanout has stopped.
After confirmed detach the caller retires source owners and calls `finishClose`.
Cleanup IO errors are reported even though `finishClose` consumes its private FD;
callers must distinguish `device.closed` and retain an acknowledgement owner if
their public handle contract requires retry. Never expose a dangling handle or
silently ignore a source/DMA cleanup error.

All operations are externally serialized. No callback, worker, queue or timer
thread is created. Portable tests cover lease quarantine, shared handle identity
and byte layout bounds. Linux protocol tests in zig-camera exercise actual UAPI
request/event/projection code with an independent C peer, including successful
formats, geometry, source ownership, mode switching and failures. These are
software/protocol tests, not evidence of Pi display scanout, color accuracy,
implicit driver copies or performance. Physical acceptance remains required.

See Linux's [PRIME handle contract](https://www.kernel.org/doc/html/latest/gpu/drm-uapi.html)
and [flip completion rules](https://www.kernel.org/doc/html/v6.17/gpu/drm-kms.html).
Home OS ADR-MC5 owns HVS/register drivers in the Home kernel. None of that kernel
code is copied here; this is hosted Linux display ownership in Home stdlib.
