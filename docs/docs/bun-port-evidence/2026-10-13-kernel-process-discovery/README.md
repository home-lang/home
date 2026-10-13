# Kernel process discovery — 2026-10-13

After the physical-footprint probe repair, an inspector baseline was refused with disk-measurement stop 123 and its build stopped with unavailable-memory stop 125. Direct diagnostics found ps stalled while df and the kernel footprint query returned promptly afterward. Neither inspector run receives pass credit.

The guard now captures KERN_PROC_ALL process relationships and start times directly, avoiding command-argument inspection. Process trees still include parent descendants and the entire child process group. Remembered survivors use immutable start identity, which survives exec and protects against recycled PIDs. The original ps path remains available when native helper compilation is unavailable. Probe deadlines, failed-sample limits, host/memory/disk thresholds and cleanup remain unchanged.

Three final snapshots returned complete tables of 955 processes in 3.6–9.1 ms with stable identities. Tests verify parent/group relationships, identity across exec, and timeout cleanup of a child that starts a separate session. Cleanup checks actual terminal state. Memory ceiling, legacy stalled-probe/deadline/cleanup, parser and six disk/scanner checks passed.

The incomplete libproc prototype and unverified filesystem-helper draft are preserved as investigation only; neither is selected. The [manifest](./manifest.json) records source hashes, outcomes, limitations and raw artifact identities. Inspector promise/accessor source remains recovery bb57ac090. Full acceptance stays open in [#888](https://github.com/home-lang/home/issues/888), [#428](https://github.com/home-lang/home/issues/428), and [#66](https://github.com/home-lang/home/issues/66).
