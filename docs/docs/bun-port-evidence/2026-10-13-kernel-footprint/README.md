# Kernel physical-footprint probe — 2026-10-13

The ordinary inspector baseline and corrected build each stopped with guard exit 125 after eight unavailable memory measurements. Three direct footprint(1) probes also exceeded the existing two-second deadline. These runs receive no inspector runtime/build pass credit.

The new helper queries macOS libproc `ri_phys_footprint` directly, avoiding VM-map traversal. The guard builds/caches it by source hash and retains footprint(1) where compilation is unavailable. The same probe deadline, failed-sample limit, process-tree/host memory thresholds, disk limits and cleanup remain enforced. Unavailable live processes invalidate a sample; exited children are tolerated. No RSS or invented zero substitutes for missing physical measurements.

Three kernel probes returned valid readings in 7–96 ms. A live 64 MiB random allocation raised physical footprint by 67,174,448 bytes. The guard enforced a 32 MB ceiling with exit 125. Existing parser, stalled-probe/deadline/cleanup and six disk/scanner controls passed. Initial test-invocation/assertion mistakes are preserved separately with their corrected results.

[The manifest](./manifest.json) records source hashes and every raw artifact. Inspector promise/accessor source remains recovery `bb57ac090` pending a normal rebuild and validation. [#888](https://github.com/home-lang/home/issues/888), [#428](https://github.com/home-lang/home/issues/428), and [#66](https://github.com/home-lang/home/issues/66) remain incomplete.
