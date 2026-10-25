# Observed control transactions and IMX500 ROI

`video.observed_control.apply(T, io, requested, force)` validates, observes,
skips unchanged values unless explicitly forced, writes once and observes again.
The IO adapter supplies public `validate`, `read` and `write` methods. Outcomes
retain optional previous/current values, attempted/succeeded flags, the primary
failure and optional change. Failed writes are never retried, and the write
failure wins if readback also fails. Observation is not proof of physical
application. The boolean-control API delegates to this policy without forcing.

`video.imx500_roi` implements checked 4056×3040 active-array ROI encoding. It
reuses inference-region intersection with widened endpoints. Full sensor and an
explicit all-zero request use the kernel reset sentinel, needed because the
inspected driver's scalar maximum (4032) is narrower than the active array.
Empty/disjoint requests are rejected. Raw payloads validate runtime min/max/step;
invalid cached rectangles retain a distinct error. A zero width OR height in a
cached payload means full sensor, matching Raspberry Pi Linux
5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc. These helpers allocate no heap, require
no libc and own no OS/device descriptors. Hosted camera owns discovery, handles
and system IO. The freestanding probe retains the actual encoder and generic
array transaction policy. These checks do not establish physical sensor behavior.
