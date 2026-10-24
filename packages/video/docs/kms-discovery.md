# Read-only hosted KMS catalogs

`display/kms_discovery_host.zig::scan(result, card)` fills a fixed-capacity
`kms_discovery.Result` on Linux. The video root also exports `kms_catalog`,
`kms_discovery` and `kms_discovery_host`. The hosted adapter requires pinned Zig
0.15.2/libc; the portable collector/catalog support development Zig as well.

With no exact card, scan tries `/dev/dri/card0` through `card63`. Missing nodes
are normal. Permission/query errors contribute explicit card issues with stage,
reason and original errno. An exact path must contain 1..63 non-NUL bytes.
Every temporary descriptor is opened read-only/nonblocking/CLOEXEC and closed
before scan returns. The adapter changes only its own client-capability query
visibility; it never acquires DRM master, modesets, imports buffers, maps memory
or accesses Home OS register drivers. No libdrm dependency is required.

Records retain raw connector/type/instance IDs, connection state, physical
dimensions, current CRTC and active mode, cached preferred/default mode,
compatible CRTC IDs and the union of advertised compatible-plane FOURCC values.
Unknown codes are retained. `kms_catalog.processedFormat` maps only recognized
camera stream formats; it does not infer byte order from a casual RGB label.
Atomic/universal flags describe client-capability acceptance, not available plane
ownership or proof a particular framebuffer can scan out.

Fixed limits: 64 cards, 256 returned displays, 64 connectors, 32 CRTCs, 128
encoders/planes/modes per card (modes per connector), and 256 union formats per
display. A failed/oversized card is rolled back completely and contributes one
issue. Resource/plane ID lists are re-read to detect obvious topology churn,
without retries. Multiple ioctls cannot provide an atomic hardware snapshot;
connection, mode or properties can still change during/after collection. A
consumer must revalidate all selected objects and use KMS test commits before
displaying. Cached modes do not force connector probing.

The core takes an injectable driver, enabling failure-at-every-stage and hotplug
race tests with explicit descriptor retirement. The Linux host test covers absent
paths and repeated `/dev/null` ENOTTY cleanup. These are catalog/protocol tests,
not hardware scanout, color/stride/modifier acceptance or performance evidence.

Home OS ADR-MC5 assigns HVS/device ownership to the Home kernel. Its framebuffer
register/compositor code is not a hosted Linux DRM resource owner. Home video's
existing `drm/drm.zig` is CENC/encryption metadata, unrelated to Linux KMS.
