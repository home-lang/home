# TypeScript static disabled-fixture accounting

This checkpoint ports the whole-fixture exclusion list from the pinned
`typescript-go` compiler runner for
[#841](https://github.com/home-lang/home/issues/841). The authoritative
`testrunner.skippedTests` table contains 45 exact, case-sensitive basenames:
ten compiler-API fixtures that depend on a built `typescript.d.ts`, and 35
fixtures containing compiler options removed from the pinned runner.

Upstream checks this list before `runTest`, so it never reads the fixture or
expands its configured option matrix. Home now makes that boundary visible
without changing its meaning: each disabled source contributes exactly one
explicit skipped result, is not read or compiled, and cannot contribute pass
credit. A disabled source with a two-target directive therefore remains one
skip rather than becoming two configured variants.

This table is separate from the runner's `skippedEmitTests` map. That map skips
only the JavaScript-output subtest while diagnostics and other checks still
run. Home's current conformance route is a no-emit diagnostic runner, so this
checkpoint deliberately does not turn those emit-only exceptions into
whole-case skips.

The source pins used for the port are:

- `typescript-go` `89d5d5b2849a0db0957065889ca58536fa6d2e4a`;
- nested TypeScript `5848bc5157b22ff7f4e3369f4645a514a433b15f`.

All 45 listed basenames occur exactly once in the pinned nested TypeScript
case tree.

## Guarded verification

Every substantial command ran serially through `scripts/run-bounded.pl` with
`HOME_RUN_MAX_MB=3840`.

- exact 45-entry map, case-sensitive negative controls, a disabled two-target
  fixture, and an active sibling: **2/2** Zig tests passed, yielding exactly
  one pass, one skip, and zero failures; peak 2,028 MB;
- real pinned `APILibCheck.ts` compiler survey: **2/2** Zig tests passed with
  total 1, passed 0, failed 0, skipped 1; peak 2,004 MB;
- real pinned `preserveUnusedImports.ts` compiler survey: **2/2** Zig tests
  passed with total 1, passed 0, failed 0, skipped 1; the cached compile used
  32 MB MaxRSS and the runner used 5 MB MaxRSS;
- dynamic unsupported-option regression: **2/2** Zig tests passed, retaining
  exactly one ES5 skip and one ES2015 pass; peak 2,169 MB;
- named local category regression: **87/87** configured cases passed with zero
  failures and zero skips; peak 2,164 MB.
- Pickier, Zig formatting, diff checks, portable documentation paths, metadata,
  and the **111-page** documentation build passed.

No fixture, expected diagnostic, baseline, or resource limit was changed.
This remains a focused harness-accounting checkpoint, not a complete-corpus
claim. Real default-library and compiler-API inputs remain open in #841; the
complete TypeScript corpus remains tracked in
[#832](https://github.com/home-lang/home/issues/832), and full Bun acceptance
remains tracked in [#66](https://github.com/home-lang/home/issues/66).
