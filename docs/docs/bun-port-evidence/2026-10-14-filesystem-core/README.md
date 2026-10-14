# Filesystem core, copy and full fs.test.ts baseline

The native Home executable at source `e9f65141f1386177e7cb26a81e48626bd395c771` ran 102 unchanged originals from Bun pin `4982b91e3702094330f3be3883354c52b8c01323` on Darwin arm64. All 102 commands and their independent corpus validators returned zero. The selection contains 350 passing registered cases and 94 passing process checks, zero failures, TODOs, filtering or retries, with 15 original case skips and two complete-file skips receiving no pass credit.

The core phase contains 21 access/stat/read/append/truncate originals (20 cases, 17 process checks). The copy phase includes all 77 parallel `test-fs-cp-*` originals plus three Bun-specific copy/promise files (68 cases, 77 process checks, eight case skips). The complete unchanged `fs.test.ts` contributes 262 cases and seven case skips, including its sparse 5 GB file coverage.

The complete-file skips are the Windows-specific ENOENT readFileSync case and the Temporal stat case. The pinned common harness lacks `hasTemporal`; the original Temporal test therefore skips even when the native engine's Temporal option is enabled. A native probe confirms Temporal.Instant exists with `BUN_JSC_useTemporal=1` while Stats Instant fields are missing. Feature work is tracked in [#894](https://github.com/home-lang/home/issues/894).

The manifest records exact original hashes, executable identity, phase counts and deterministic gzip artifacts with uncompressed hashes. These are baseline results before the Stats timestamp feature changes. They do not prove full Bun suite parity, resolve skipped cases or establish other platform support. The main acceptance tracker remains [#66](https://github.com/home-lang/home/issues/66).
