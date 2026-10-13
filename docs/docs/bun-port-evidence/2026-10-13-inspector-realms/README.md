# Native inspector VM realms — 2026-10-13

Source `2d9025ce5` exposes actual VM contexts with their names/origins and native identities. Context-specific evaluation, separate remote handles, own properties and release use the owning JSC controller. Cross-world object arguments receive the Node inspector command error, while same-world arguments retain native identity. Request-method-aware translation maps JSC property arrays to the CDP response field. Missing metadata and missing object IDs are guarded before native value/map access.

A normal Debug rebuild completed 56/56 steps. Seven focused controls passed on both Node and Home. All 28 native groups, 14 ABI tests with 453 assertions, and 32 report-validator tests passed. The current-main integration build also completed 56/56 steps and retained the identical executable SHA-256 used for those tests. Lint and formatting checks passed.

Twenty byte-identical upstream files retain 53 passed cases, one failed inspector expectation and 17 passed process checks; zero skips, TODOs, filters or retries. The collector exits zero to collect all results; the separate audit preserves the exact failure (`unsupported method throws`) and gives it no pass credit. All 64 report outcomes match the previous expected counts, success states, validation exits and errors, including 12 negative outcomes.

This is an incremental port. [#888](https://github.com/home-lang/home/issues/888) retains controller roots, context retirement, backend/async schema and teardown work. [#428](https://github.com/home-lang/home/issues/428) retains complete inspector acceptance; [#886](https://github.com/home-lang/home/issues/886) records the unchanged original expectation conflict. Full Bun suite and all-platform acceptance remain open in [#66](https://github.com/home-lang/home/issues/66).

Earlier metadata/object aborts, the incorrect cross-world success expectation, and baseline property failure remain in [the previous checkpoint](../2026-10-13-inspector-null-key-controls/README.md) and earlier immutable evidence. Two queued commands later exited 127 after derived binaries/toolchains/caches disappeared. Source matched its pushed recovery snapshot; archived evidence and the exact pinned toolchain were recovered before rebuilding. Those exits receive no pass credit.

The [manifest](./manifest.json) records source and executable identities, all limitations, and uncompressed SHA-256/byte counts for each retained raw artifact.
